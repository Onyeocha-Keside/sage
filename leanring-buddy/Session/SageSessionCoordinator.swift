//
//  SageSessionCoordinator.swift
//  Sage
//
//  The conductor. Runs the full loop:
//
//    hold shortcut → record voice → release → transcript
//      → screenshot every display → stream Claude's reply
//      → speak each sentence as it arrives
//      → fly the cursor to each element right as Sage starts talking about it
//
//  Also owns the first-run onboarding and the user's voice choice.
//

import AppKit
import Combine
import Foundation
import os
import SwiftUI

@MainActor
final class SageSessionCoordinator: ObservableObject {
    // MARK: - Published State

    @Published private(set) var voiceState: SessionVoiceState = .idle
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var isOverlayVisible = false

    /// Where the cursor should be pointing right now. Each new value makes the
    /// overlay fly there; it's cleared once the cursor flies home.
    @Published private(set) var currentPointingTarget: PointingTarget?

    /// True from the moment a question is sent until Sage stops talking. The
    /// cursor keeps pointing while this is true instead of flying home early.
    @Published private(set) var isReplyInProgress = false

    @Published private(set) var selectedVoice: SageVoiceOption

    /// True while Sage is waiting for you to do the step it just described.
    /// The cursor pulses gently during this time.
    @Published private(set) var isFollowingAlong = false

    @Published private(set) var areSoundEffectsEnabled = SoundEffectsPlayer.areSoundEffectsEnabled

    /// The cursor's color, or invisible for voice-only use.
    @Published private(set) var cursorColorOption: CursorColorOption

    /// The fading pen trail drawn while the shortcut is held (AppKit global points).
    @Published private(set) var gestureTrailPoints: [CGPoint] = []
    /// The clean circle (or ellipse) around what the user circled, in AppKit
    /// global coordinates. Shown until Sage finishes answering.
    @Published private(set) var circledAreaFocusRect: CGRect?

    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Self.hasCompletedOnboardingDefaultsKey) }
    }

    /// The "hold your shortcut and ask me anything" hint typed out next
    /// to the cursor after the onboarding demo.
    @Published private(set) var onboardingPromptText = ""
    @Published private(set) var onboardingPromptOpacity: Double = 0

    // MARK: - Collaborators

    let permissions = PermissionsCoordinator()
    let dictationManager = PushToTalkDictationManager()
    private let shortcutMonitor = GlobalPushToTalkShortcutMonitor()
    private let overlayWindowManager = OverlayWindowManager()
    private let apiClient = SageAPIClient()
    private lazy var replyExecutor = ReplyExecutor(client: apiClient)
    private let macVoice = AppleSpeechVoice()
    private let elevenLabsVoice = ElevenLabsSpeechVoice()
    private lazy var speechPlaybackQueue = SpeechPlaybackQueue(fallbackVoice: macVoice)
    private let userActivityWatcher = UserActivityWatcher()
    private let pointingTargetTracker = PointingTargetTracker()
    private let circleGestureRecorder = CircleGestureRecorder()

    // MARK: - Private State

    private let logger = Logger(subsystem: "com.kesideonyeocha.sage", category: "companion")
    private let latencyLogger = Logger(subsystem: "com.kesideonyeocha.sage", category: "latency")

    private static let hasCompletedOnboardingDefaultsKey = "hasCompletedOnboarding"
    private static let selectedVoiceDefaultsKey = "selectedVoice"
    private static let cursorColorDefaultsKey = "cursorColor"
    /// Asked on the user's behalf when they circle something without speaking.
    private static let circledAreaDefaultQuestion = "what's this that i circled?"
    /// Added to a circled question's message (not to memory), so the answer
    /// stays on the circled thing instead of drifting to the whole screen.
    private static let circledAreaFocusNote = "(i circled something on screen. it's inside the red ring, and the first image is a close-up of it. focus your answer on exactly that thing: say what it is, what it means here, and if something's wrong with it, how to fix it. only bring in the rest of the screen if it matters for that.)"
    /// Added to the message (not to memory) while the cursor is invisible.
    private static let cursorHiddenNote = "(sage's on-screen pointer is hidden right now, so don't use point tags. describe where things are in words, like \"top right, next to share\".)"
    private static var onboardingPromptMessage: String { "hold \(GlobalPushToTalkShortcutMonitor.shortcutDisplayText.lowercased()) and ask me anything" }

    /// Past exchanges replayed to Claude so it remembers the conversation.
    private var conversationMemory = ConversationMemory()
    private var currentReplyTask: Task<Void, Never>?
    private var currentReplyIdentifier = UUID()
    private var pendingRecordingStartTask: Task<Void, Never>?
    /// Screenshots started at key release, so capturing overlaps with the
    /// transcript finishing instead of running after it.
    private var pendingQuestionScreenCapture: Task<[CapturedScreen], Error>?
    /// What the user circled during the current recording, if anything.
    private var pendingCircledArea: CircledArea?
    /// Stage timings for the reply being prepared, logged at its first sound.
    private var latencyTimeline: ReplyLatencyTimeline?
    /// Claude's guess (from a [NEXT:...] tag) at the label of the control the
    /// user will need on the next screen. Used by the next follow-along look.
    private var pendingNextStepHint: String?
    /// The hint the current reply is using to point early, if any.
    private var currentReplyNextStepHint: String?
    private var nextStepPredictionTask: Task<Void, Never>?
    /// The early point shown before Claude's answer, so it can be withdrawn
    /// if Claude's first sentence doesn't point at anything.
    private var predictedPointingTargetID: UUID?
    /// Watches for a page that was still loading when Sage looked.
    private var lateScreenChangeTask: Task<Void, Never>?
    /// At most one extra look per step, so an animated page can't loop.
    private var hasRelookedThisStep = false
    /// Average thumbnail difference that means the screen really changed
    /// after Sage looked (a new page), not a spinner or a blinking caret.
    private static let lateScreenChangeDifferenceThreshold = 4.0
    /// After this long, or once words arrive, a late change no longer restarts the look.
    private static let lateScreenChangeWatchSeconds: Double = 3
    private var onboardingPromptTask: Task<Void, Never>?
    /// Pointing targets waiting for their sentence to start playing, keyed by sentence ID.
    private var pointingTargetsBySentenceID: [UUID: PointingTarget] = [:]
    /// What the user originally asked for, kept while following along so each
    /// fresh screenshot can be judged against the real goal.
    private var followAlongSession = FollowAlongSession()
    /// Set once the current reply's first words arrive, so the slow-connection
    /// notice knows whether it's still needed.
    private var hasCurrentReplyStartedArriving = false
    private var slowConnectionNoticeTask: Task<Void, Never>?
    /// The notice is filler, not the answer, so it shouldn't end the "thinking" state.
    private var slowConnectionNoticeSentenceID: UUID?
    /// If no words have arrived after this long, Sage says it's still working.
    private static let slowConnectionNoticeDelaySeconds: Double = 6
    private var cancellables = Set<AnyCancellable>()
    private var hasStarted = false

    // MARK: - Lifecycle

    init() {
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Self.hasCompletedOnboardingDefaultsKey)
        selectedVoice = UserDefaults.standard.string(forKey: Self.selectedVoiceDefaultsKey)
            .flatMap(SageVoiceOption.init(rawValue:)) ?? .mac
        cursorColorOption = UserDefaults.standard.string(forKey: Self.cursorColorDefaultsKey)
            .flatMap(CursorColorOption.init(rawValue:)) ?? .sage
    }

    /// True when the menu bar panel should open on launch to finish setup.
    var needsSetup: Bool {
        !AppConfiguration.isConfigured || !permissions.allPermissionsGranted || !hasCompletedOnboarding
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isOverlayVisible else { return }
                self.currentPointingTarget = nil
                self.showOverlay(isFirstAppearance: false)
            }
            .store(in: &cancellables)
        speechPlaybackQueue.onSegmentStartedPlaying = { [weak self] sentenceID in
            self?.handleSentenceStartedPlaying(sentenceID: sentenceID)
        }
        pointingTargetTracker.onContentScrolled = { [weak self] in
            self?.refreshCurrentPointingTarget()
        }
        circleGestureRecorder.onTrailChanged = { [weak self] trailPoints in
            self?.gestureTrailPoints = trailPoints
        }
        pointingTargetTracker.start()

        permissions.onPermissionsChanged = { [weak self] in
            self?.handlePermissionsChanged()
        }
        permissions.onPermissionsChecked = { [weak self] in
            self?.retryShortcutMonitorIfNeeded()
        }
        permissions.startMonitoring()

        bindDictationStateToVoiceState()
        bindShortcutTransitions()
        handlePermissionsChanged()

        apiClient.warmUpConnection()
    }

    func stop() {
        hasStarted = false
        pendingRecordingStartTask?.cancel()
        pendingRecordingStartTask = nil
        discardPendingQuestionScreenCapture()
        onboardingPromptTask?.cancel()
        onboardingPromptTask = nil
        cancellables.removeAll()
        stopFollowingAlong()
        shortcutMonitor.stop()
        dictationManager.cancel()
        _ = circleGestureRecorder.stop()
        interruptCurrentReply()
        pointingTargetTracker.stop()
        overlayWindowManager.hideOverlay()
        isOverlayVisible = false
        voiceState = .idle
        permissions.stopMonitoring()
    }

    // MARK: - Settings

    func accessCredentialsDidChange() {
        stop()
        conversationMemory = ConversationMemory()
        start()
    }

    func selectShortcut(_ shortcut: PushToTalkShortcut) {
        pendingRecordingStartTask?.cancel()
        pendingRecordingStartTask = nil
        dictationManager.cancel()
        shortcutMonitor.selectShortcut(shortcut)
        dismissOnboardingPrompt()
    }

    func selectVoice(_ voiceOption: SageVoiceOption) {
        selectedVoice = voiceOption
        UserDefaults.standard.set(voiceOption.rawValue, forKey: Self.selectedVoiceDefaultsKey)
    }

    func selectCursorColor(_ colorOption: CursorColorOption) {
        cursorColorOption = colorOption
        UserDefaults.standard.set(colorOption.rawValue, forKey: Self.cursorColorDefaultsKey)
        if colorOption.isInvisible {
            currentPointingTarget = nil
        }
    }

    func setSoundEffectsEnabled(_ isEnabled: Bool) {
        areSoundEffectsEnabled = isEnabled
        SoundEffectsPlayer.areSoundEffectsEnabled = isEnabled
    }

    private var activeVoice: SpeechVoice {
        selectedVoice == .elevenLabs ? elevenLabsVoice : macVoice
    }

    // MARK: - Onboarding

    /// The "Start" button: show the cursor for the first time and run the intro.
    func startOnboarding() {
        guard permissions.allPermissionsGranted, AppConfiguration.isConfigured else { return }
        NotificationCenter.default.post(name: .sageDismissMenu, object: nil)
        hasCompletedOnboarding = true
        showOverlay(isFirstAppearance: true)
    }

    /// Replays the intro (handy when recording a demo video).
    func replayIntro() {
        NotificationCenter.default.post(name: .sageDismissMenu, object: nil)
        stopFollowingAlong()
        interruptCurrentReply()
        showOverlay(isFirstAppearance: true)
    }

    /// Called by the cursor overlay once the "hey, i'm sage" bubble fades.
    /// Sage then looks at the screen and points at something to show off.
    func welcomeAnimationDidFinish() {
        startReply(mode: .onboarding, userText: "look around my screen and point at something interesting")
    }

    private func showOnboardingPrompt() {
        onboardingPromptTask?.cancel()
        onboardingPromptTask = Task { [weak self] in
            guard let self else { return }

            self.onboardingPromptText = ""
            self.onboardingPromptOpacity = 1

            for character in Self.onboardingPromptMessage {
                try? await Task.sleep(for: .milliseconds(30))
                if Task.isCancelled { return }
                self.onboardingPromptText.append(character)
            }

            try? await Task.sleep(for: .seconds(10))
            if Task.isCancelled { return }
            self.dismissOnboardingPrompt()
        }
    }

    private func dismissOnboardingPrompt() {
        onboardingPromptTask?.cancel()
        onboardingPromptTask = nil
        onboardingPromptOpacity = 0
    }

    // MARK: - Overlay

    private func showOverlay(isFirstAppearance: Bool) {
        overlayWindowManager.showOverlay(
            onScreens: NSScreen.screens,
            isFirstAppearance: isFirstAppearance,
            sessionCoordinator: self
        )
        isOverlayVisible = true
    }

    /// Called by the overlay once the cursor has flown home after pointing.
    /// Only clears the target if a newer one hasn't replaced it in the meantime.
    func clearPointingTarget(ifStillTargetID targetID: UUID) {
        if currentPointingTarget?.id == targetID {
            currentPointingTarget = nil
        }
    }

    // MARK: - Permissions

    private func handlePermissionsChanged() {
        if !permissions.allPermissionsGranted {
            pendingRecordingStartTask?.cancel()
            pendingRecordingStartTask = nil
            discardPendingQuestionScreenCapture()
            dictationManager.cancel()
            stopFollowingAlong()
            interruptCurrentReply()
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
            voiceState = .idle
        }
        if permissions.hasAccessibilityPermission {
            shortcutMonitor.start()
        } else {
            shortcutMonitor.stop()
        }

        if permissions.hasMicrophonePermission {
            dictationManager.prewarmIfNeeded()
        }

        // Returning user with everything granted: bring the cursor straight back.
        if hasCompletedOnboarding && permissions.allPermissionsGranted && !isOverlayVisible {
            showOverlay(isFirstAppearance: false)
        }
    }

    /// macOS can refuse the hotkey's event tap even after Accessibility is
    /// granted (it often needs a moment). Keep trying until it sticks.
    private func retryShortcutMonitorIfNeeded() {
        guard permissions.hasAccessibilityPermission, !shortcutMonitor.isEventTapRunning else { return }
        shortcutMonitor.start()
    }

    // MARK: - Push To Talk

    private func bindShortcutTransitions() {
        shortcutMonitor.shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shortcutTransition in
                self?.handleShortcutTransition(shortcutTransition)
            }
            .store(in: &cancellables)
    }

    private func handleShortcutTransition(_ shortcutTransition: PushToTalkShortcutTransition) {
        switch shortcutTransition {
        case .pressed:
            guard permissions.allPermissionsGranted, AppConfiguration.isConfigured else {
                logger.notice("Shortcut ignored: setup or permissions are incomplete")
                return
            }
            guard isOverlayVisible else {
                logger.notice("Shortcut ignored: the cursor overlay isn't showing yet")
                return
            }
            guard !dictationManager.isDictationInProgress else {
                logger.notice("Shortcut ignored: a recording is already in progress")
                return
            }
            logger.notice("Starting push-to-talk recording")
            SoundEffectsPlayer.play(.listeningStarted)

            NotificationCenter.default.post(name: .sageDismissMenu, object: nil)
            // The connection may have gone idle since the last question.
            // Reopening it while the user talks keeps the TLS handshake off
            // the critical path.
            apiClient.warmUpConnection()
            discardPendingQuestionScreenCapture()
            // While the shortcut is held the mouse works like a pen, so the
            // user can circle what they're asking about.
            pendingCircledArea = nil
            circledAreaFocusRect = nil
            circleGestureRecorder.start()
            // Talking over Sage interrupts it, like a real conversation, and a
            // new question ends any guided task that was in progress.
            stopFollowingAlong()
            interruptCurrentReply()
            dismissOnboardingPrompt()

            pendingRecordingStartTask?.cancel()
            pendingRecordingStartTask = Task { [weak self] in
                await self?.dictationManager.startRecording(onFinalTranscript: { [weak self] finalTranscript in
                    SoundEffectsPlayer.play(.questionSent)
                    self?.startNewQuestion(finalTranscript)
                }, onNoSpeech: { [weak self] in
                    self?.handleRecordingWithoutSpeech()
                })
                if let recordingErrorMessage = self?.dictationManager.lastErrorMessage {
                    self?.logger.error("Recording didn't start: \(recordingErrorMessage, privacy: .public)")
                }
            }

        case .released:
            // Cancel a start that hasn't finished yet, so a very quick tap
            // doesn't leave the microphone running.
            pendingRecordingStartTask?.cancel()
            pendingRecordingStartTask = nil
            let drawnPath = circleGestureRecorder.stop()
            if dictationManager.isRecording {
                latencyTimeline = ReplyLatencyTimeline(startingPoint: "key release")
                let circledArea = CircleGestureDetector.detectCircle(in: drawnPath)
                if let circledArea {
                    logger.notice("The user circled an area while asking")
                    pendingCircledArea = circledArea
                    circledAreaFocusRect = circledArea.focusRect
                }
                // The user is looking at the screen they're asking about right
                // now, so capture it while the transcript is still finishing.
                pendingQuestionScreenCapture = Task {
                    try await ScreenCaptureService.captureScreens(onlyCursorScreen: false, circledArea: circledArea)
                }
            }
            dictationManager.stopRecordingAndTranscribe()
        }
    }

    /// Holding the shortcut and circling something without a word still asks about it.
    private func handleRecordingWithoutSpeech() {
        guard pendingCircledArea != nil else {
            circledAreaFocusRect = nil
            discardPendingQuestionScreenCapture()
            return
        }
        SoundEffectsPlayer.play(.questionSent)
        startNewQuestion(Self.circledAreaDefaultQuestion)
    }

    private func discardPendingQuestionScreenCapture() {
        pendingQuestionScreenCapture?.cancel()
        pendingQuestionScreenCapture = nil
    }

    private func bindDictationStateToVoiceState() {
        dictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] audioPowerLevel in
                self?.currentAudioPowerLevel = audioPowerLevel
            }
            .store(in: &cancellables)

        dictationManager.$isRecording
            .combineLatest(dictationManager.$isFinalizingTranscript, dictationManager.$isPreparingToRecord)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizingTranscript, isPreparingToRecord in
                guard let self else { return }
                // While a reply is running, the reply pipeline owns voiceState.
                guard self.currentReplyTask == nil else { return }

                if isRecording {
                    self.voiceState = .listening
                } else if isFinalizingTranscript || isPreparingToRecord {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Follow Along

    /// A fresh spoken question. It also becomes the goal if Sage ends up
    /// guiding the user through several screens.
    private func startNewQuestion(_ questionText: String) {
        latencyTimeline?.mark(.transcriptReady)
        followAlongSession.begin(goal: questionText)
        let prefetchedScreens = pendingQuestionScreenCapture
        pendingQuestionScreenCapture = nil
        let noteForClaude = pendingCircledArea == nil ? nil : Self.circledAreaFocusNote
        pendingCircledArea = nil
        startReply(mode: .companion, userText: questionText, prefetchedScreens: prefetchedScreens, noteForClaude: noteForClaude)
    }

    /// Watches for the user to do the step Sage just described. Called as soon
    /// as Claude's [FOLLOW] tag arrives, so a quick click isn't missed even if
    /// Sage is still finishing its sentence.
    private func startFollowingAlong() {
        guard followAlongSession.canContinue else {
            stopFollowingAlong()
            return
        }
        guard !userActivityWatcher.isWatching else { return }

        isFollowingAlong = true
        logger.notice("Following along: waiting for the user's next action")
        userActivityWatcher.startWatching(
            onFirstActivity: { [weak self] wasScrolling in
                self?.acknowledgeUserActionImmediately(wasScrolling: wasScrolling)
            },
            onScreenSettled: { [weak self] settledThumbnail in
                self?.lookAgainAfterUserAction(settledThumbnail: settledThumbnail)
            },
            onIdleTimeout: { [weak self] in
                self?.logger.notice("Following along ended: no activity")
                self?.stopFollowingAlong()
            }
        )
    }

    private func stopFollowingAlong() {
        userActivityWatcher.stopWatching()
        isFollowingAlong = false
        followAlongSession.end()
        pendingNextStepHint = nil
    }

    /// The user clicked, typed, or scrolled and the screen has settled: take
    /// a fresh screenshot and let Claude continue from where they really are.
    /// The moment the user clicks, types, or scrolls: show and sound that Sage
    /// noticed, before the screen has even finished changing. A pause feels
    /// fine when you can see something is happening; silence feels broken.
    private func acknowledgeUserActionImmediately(wasScrolling: Bool) {
        SoundEffectsPlayer.play(.lookingAgain)
        isFollowingAlong = false
        // A click or key means they've acted on the element, so the cursor can
        // stop pointing. Scrolling doesn't: the cursor rides along with the
        // content until Sage's next look replaces the target.
        if !wasScrolling {
            currentPointingTarget = nil
        }
        if !isReplyInProgress {
            voiceState = .processing
        }
    }

    private func lookAgainAfterUserAction(settledThumbnail: ScreenThumbnail?) {
        guard let followUpText = followAlongSession.nextQuestion() else { return }
        logger.notice("Following along: looking again (step \(self.followAlongSession.stepCount, privacy: .public))")
        hasRelookedThisStep = false
        let nextStepHint = pendingNextStepHint
        pendingNextStepHint = nil
        lookAgain(followUpText: followUpText, nextStepHint: nextStepHint, settledThumbnail: settledThumbnail)
    }

    private func lookAgain(followUpText: String, nextStepHint: String?, settledThumbnail: ScreenThumbnail?) {
        latencyTimeline = ReplyLatencyTimeline(startingPoint: "screen settled")
        startReply(mode: .companion, userText: followUpText, isFollowAlongLook: true, nextStepHint: nextStepHint)
        watchForLateScreenChange(followUpText: followUpText, nextStepHint: nextStepHint, settledThumbnail: settledThumbnail)
    }

    /// Settling is quick, so occasionally Sage looks while a page is still
    /// loading. Until Claude's first words arrive, keep comparing the screen
    /// with what Sage looked at; if it changes a lot, the look was premature:
    /// cancel it quietly, wait for the screen to finish, and look once more.
    private func watchForLateScreenChange(followUpText: String, nextStepHint: String?, settledThumbnail: ScreenThumbnail?) {
        guard !hasRelookedThisStep, let settledThumbnail else { return }
        let replyIdentifier = currentReplyIdentifier
        lateScreenChangeTask = Task { [weak self] in
            guard let thumbnailCapturer = await ScreenChangeDetector.makeThumbnailCapturerForDisplayUnderMouse() else { return }
            let watchStartInstant = ContinuousClock.now
            while ContinuousClock.now - watchStartInstant < .seconds(Self.lateScreenChangeWatchSeconds) {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled, self.currentReplyIdentifier == replyIdentifier,
                      !self.hasCurrentReplyStartedArriving else { return }
                guard let currentThumbnail = await thumbnailCapturer.capture() else { continue }
                guard !Task.isCancelled, self.currentReplyIdentifier == replyIdentifier,
                      !self.hasCurrentReplyStartedArriving else { return }
                if currentThumbnail.averageDifference(from: settledThumbnail) >= Self.lateScreenChangeDifferenceThreshold {
                    self.relookAfterLateScreenChange(followUpText: followUpText, nextStepHint: nextStepHint,
                                                     alreadySeenThumbnail: settledThumbnail)
                    return
                }
            }
        }
    }

    private func relookAfterLateScreenChange(followUpText: String, nextStepHint: String?, alreadySeenThumbnail: ScreenThumbnail) {
        logger.notice("Following along: the screen kept changing after Sage looked, looking again")
        hasRelookedThisStep = true
        interruptCurrentReply()
        voiceState = .processing
        userActivityWatcher.restartSettleCheck(
            comparedWith: alreadySeenThumbnail,
            onScreenSettled: { [weak self] settledThumbnail in
                self?.lookAgain(followUpText: followUpText, nextStepHint: nextStepHint, settledThumbnail: settledThumbnail)
            },
            onIdleTimeout: { [weak self] in
                self?.stopFollowingAlong()
            }
        )
    }

    /// Points at the control Claude predicted, found by its text on the new
    /// screenshot, while Claude is still preparing its answer. Only shown if
    /// Sage hasn't started talking or pointing yet.
    private func pointAtPredictedNextStep(_ nextStepHint: String, screens: [CapturedScreen]) {
        guard let screen = screens.first(where: { $0.isCursorScreen }) ?? screens.first else { return }
        let replyIdentifier = currentReplyIdentifier
        nextStepPredictionTask = Task { [weak self] in
            let pixelLocation = await OnScreenTextLocator.locate(nextStepHint, inJPEG: screen.jpegData)
            guard let self, !Task.isCancelled, self.currentReplyIdentifier == replyIdentifier else { return }
            guard let pixelLocation else {
                self.logger.notice("Early point skipped: the predicted label isn't on screen exactly once")
                return
            }
            guard self.voiceState == .processing, self.currentPointingTarget == nil,
                  let predictedTarget = PointingTag(screenshotPixelCoordinate: pixelLocation, label: nextStepHint, screenNumber: nil)
                    .resolve(against: [screen]) else { return }
            self.latencyTimeline?.mark(.predictedPointShown)
            self.pointingTargetTracker.beginTracking(predictedTarget)
            self.predictedPointingTargetID = predictedTarget.id
            self.showPointingTarget(predictedTarget)
        }
    }

    // MARK: - Reply Pipeline

    /// - `isFollowAlongLook`: a follow-along step. Only the screen the user is
    ///   working on is sent, which keeps uploads small on slow connections.
    /// - `prefetchedScreens`: screenshots already being captured, used instead
    ///   of capturing again.
    /// - `nextStepHint`: the label Claude predicted for this screen, to point at early.
    private func startReply(mode: ConversationMode, userText: String, isFollowAlongLook: Bool = false,
                            prefetchedScreens: Task<[CapturedScreen], Error>? = nil, nextStepHint: String? = nil,
                            noteForClaude: String? = nil) {
        interruptCurrentReply()
        currentReplyNextStepHint = nextStepHint

        isReplyInProgress = true
        voiceState = .processing

        let replyIdentifier = currentReplyIdentifier
        currentReplyTask = Task { [weak self] in
            await self?.runReply(mode: mode, userText: userText, isFollowAlongLook: isFollowAlongLook,
                                 prefetchedScreens: prefetchedScreens, noteForClaude: noteForClaude, replyIdentifier: replyIdentifier)
        }
    }

    /// Stops whatever Sage is saying or about to say.
    private func interruptCurrentReply() {
        currentReplyIdentifier = UUID()
        currentReplyTask?.cancel()
        currentReplyTask = nil
        slowConnectionNoticeTask?.cancel()
        slowConnectionNoticeTask = nil
        nextStepPredictionTask?.cancel()
        nextStepPredictionTask = nil
        lateScreenChangeTask?.cancel()
        lateScreenChangeTask = nil
        currentReplyNextStepHint = nil
        predictedPointingTargetID = nil
        speechPlaybackQueue.stopAll()
        pointingTargetsBySentenceID.removeAll()
        pointingTargetTracker.forgetAllTargets()
        currentPointingTarget = nil
        isReplyInProgress = false
    }

    private func runReply(mode: ConversationMode, userText: String, isFollowAlongLook: Bool,
                          prefetchedScreens: Task<[CapturedScreen], Error>?, noteForClaude: String?, replyIdentifier: UUID) async {
        hasCurrentReplyStartedArriving = false
        startSlowConnectionNotice()
        defer {
            if currentReplyIdentifier == replyIdentifier {
                slowConnectionNoticeTask?.cancel()
                slowConnectionNoticeTask = nil
            }
        }

        do {
            let result = try await replyExecutor.execute(
                input: ReplyInput(mode: mode, userText: messageTextForClaude(userText: userText, noteForClaude: noteForClaude),
                                  conversationHistory: mode == .companion ? conversationMemory.turns : [],
                                  onlyCursorScreen: isFollowAlongLook,
                                  prefetchedScreens: prefetchedScreens)
            ) { [weak self] event in
                guard let self, !Task.isCancelled, self.currentReplyIdentifier == replyIdentifier else { return }
                self.handleReplyExecutionEvent(event)
            }
            try Task.checkCancellation()
            guard currentReplyIdentifier == replyIdentifier else { return }
            if mode == .companion && result.hasAnswer {
                conversationMemory.remember(userText: userText, assistantText: result.spokenText)
            }

            await speechPlaybackQueue.waitUntilFinishedPlaying()

            if mode == .companion && !result.wantsToFollowAlong {
                // Claude didn't ask the user to do anything, so the guided task is over.
                stopFollowingAlong()
            }
        } catch {
            guard !Task.isCancelled, !ReplyFailureExplanation.isCancellation(error) else { return }
            stopFollowingAlong()
            print("⚠️ Reply failed: \(error)")
            logger.error("Reply failed: \(String(describing: error), privacy: .public)")
            // Always explain errors with the free Mac voice, so an ElevenLabs
            // problem can't hide the explanation.
            speechPlaybackQueue.enqueue(
                text: ReplyFailureExplanation.spokenExplanation(for: error),
                segmentID: UUID(),
                voice: macVoice
            )
            await speechPlaybackQueue.waitUntilFinishedPlaying()
        }

        guard !Task.isCancelled, currentReplyIdentifier == replyIdentifier else { return }
        finishReply(mode: mode)
    }

    /// The question as sent to Claude: the user's words plus any situational
    /// notes. Memory keeps only the user's words.
    private func messageTextForClaude(userText: String, noteForClaude: String?) -> String {
        var notes = [noteForClaude].compactMap { $0 }
        if cursorColorOption.isInvisible {
            notes.append(Self.cursorHiddenNote)
        }
        return ([userText] + notes).joined(separator: "\n\n")
    }

    private func finishReply(mode: ConversationMode) {
        currentReplyTask = nil
        isReplyInProgress = false
        voiceState = .idle
        circledAreaFocusRect = nil

        if mode == .onboarding {
            showOnboardingPrompt()
        }
    }

    private func handleReplyExecutionEvent(_ event: ReplyExecutionEvent) {
        switch event {
        case .screensCaptured(let screens):
            latencyTimeline?.mark(.screensCaptured)
            if let currentReplyNextStepHint {
                pointAtPredictedNextStep(currentReplyNextStepHint, screens: screens)
            }
        case .textReceived:
            hasCurrentReplyStartedArriving = true
            latencyTimeline?.mark(.firstTextReceived)
        case .sentence(let text, let target):
            latencyTimeline?.mark(.firstChunkReady)
            let sentenceID = UUID()
            if let target {
                pointingTargetTracker.beginTracking(target)
                pointingTargetsBySentenceID[sentenceID] = target
            }
            speechPlaybackQueue.enqueue(text: text, segmentID: sentenceID, voice: activeVoice)
        case .pointing(let target):
            pointingTargetTracker.beginTracking(target)
            showPointingTarget(target)
        case .followAlong:
            startFollowingAlong()
        case .nextStepHint(let hintText):
            pendingNextStepHint = hintText
        }
    }

    private func handleSentenceStartedPlaying(sentenceID: UUID) {
        if sentenceID == slowConnectionNoticeSentenceID {
            return
        }
        if voiceState == .processing {
            voiceState = .responding
        }
        if var finishedTimeline = latencyTimeline {
            finishedTimeline.mark(.firstAudioStarted)
            latencyLogger.notice("\(finishedTimeline.summary, privacy: .public)")
            latencyTimeline = nil
        }
        if let pointingTarget = pointingTargetsBySentenceID.removeValue(forKey: sentenceID) {
            showPointingTarget(pointingTarget)
        } else if let predictedPointingTargetID, currentPointingTarget?.id == predictedPointingTargetID {
            // Claude's answer doesn't point where Sage guessed, so withdraw the guess.
            currentPointingTarget = nil
        }
        predictedPointingTargetID = nil
    }

    /// Points at a target where it is now, which may differ from the
    /// screenshot if the user scrolled while Sage was answering.
    private func showPointingTarget(_ pointingTarget: PointingTarget) {
        // Voice-only mode draws nothing, so nothing to fly to.
        guard !cursorColorOption.isInvisible else { return }
        guard let placedTarget = pointingTargetTracker.currentPlacement(of: pointingTarget) else {
            logger.notice("Skipped pointing: the content scrolled and the new position is uncertain")
            return
        }
        currentPointingTarget = placedTarget
    }

    /// The user is scrolling while Sage points: keep the cursor on the content.
    private func refreshCurrentPointingTarget() {
        guard let shownTarget = currentPointingTarget else { return }
        guard let placedTarget = pointingTargetTracker.currentPlacement(of: shownTarget) else {
            logger.notice("Stopped pointing: the content scrolled and the new position is uncertain")
            currentPointingTarget = nil
            return
        }
        let distanceMoved = hypot(placedTarget.globalScreenLocation.x - shownTarget.globalScreenLocation.x,
                                  placedTarget.globalScreenLocation.y - shownTarget.globalScreenLocation.y)
        if distanceMoved >= 0.5 || placedTarget.offScreenEdge != shownTarget.offScreenEdge {
            currentPointingTarget = placedTarget
        }
    }

    /// On a slow connection the wait can stretch out. If no words have arrived
    /// after a few seconds, say so (with the local Mac voice, which needs no
    /// network) instead of leaving the user wondering if Sage froze.
    private func startSlowConnectionNotice() {
        slowConnectionNoticeTask?.cancel()
        slowConnectionNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.slowConnectionNoticeDelaySeconds))
            guard let self, !Task.isCancelled, self.isReplyInProgress, !self.hasCurrentReplyStartedArriving else { return }
            self.logger.notice("No reply yet after \(Self.slowConnectionNoticeDelaySeconds, privacy: .public)s, telling the user")
            let noticeSentenceID = UUID()
            self.slowConnectionNoticeSentenceID = noticeSentenceID
            self.speechPlaybackQueue.enqueue(
                text: "one sec, my connection's a little slow.",
                segmentID: noticeSentenceID,
                voice: self.macVoice
            )
        }
    }


}
