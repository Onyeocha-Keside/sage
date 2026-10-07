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

    // MARK: - Private State

    private let logger = Logger(subsystem: "com.kesideonyeocha.sage", category: "companion")

    private static let hasCompletedOnboardingDefaultsKey = "hasCompletedOnboarding"
    private static let selectedVoiceDefaultsKey = "selectedVoice"
    private static var onboardingPromptMessage: String { "hold \(GlobalPushToTalkShortcutMonitor.shortcutDisplayText.lowercased()) and ask me anything" }

    /// Past exchanges replayed to Claude so it remembers the conversation.
    private var conversationMemory = ConversationMemory()
    private var currentReplyTask: Task<Void, Never>?
    private var currentReplyIdentifier = UUID()
    private var pendingRecordingStartTask: Task<Void, Never>?
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
        onboardingPromptTask?.cancel()
        onboardingPromptTask = nil
        cancellables.removeAll()
        stopFollowingAlong()
        shortcutMonitor.stop()
        dictationManager.cancel()
        interruptCurrentReply()
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
            // Talking over Sage interrupts it, like a real conversation, and a
            // new question ends any guided task that was in progress.
            stopFollowingAlong()
            interruptCurrentReply()
            dismissOnboardingPrompt()

            pendingRecordingStartTask?.cancel()
            pendingRecordingStartTask = Task { [weak self] in
                await self?.dictationManager.startRecording { [weak self] finalTranscript in
                    SoundEffectsPlayer.play(.questionSent)
                    self?.startNewQuestion(finalTranscript)
                }
                if let recordingErrorMessage = self?.dictationManager.lastErrorMessage {
                    self?.logger.error("Recording didn't start: \(recordingErrorMessage, privacy: .public)")
                }
            }

        case .released:
            // Cancel a start that hasn't finished yet, so a very quick tap
            // doesn't leave the microphone running.
            pendingRecordingStartTask?.cancel()
            pendingRecordingStartTask = nil
            dictationManager.stopRecordingAndTranscribe()
        }
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
        followAlongSession.begin(goal: questionText)
        startReply(mode: .companion, userText: questionText)
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
            onFirstActivity: { [weak self] in
                self?.acknowledgeUserActionImmediately()
            },
            onScreenSettled: { [weak self] in
                self?.lookAgainAfterUserAction()
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
    }

    /// The user clicked, typed, or scrolled and the screen has settled: take
    /// a fresh screenshot and let Claude continue from where they really are.
    /// The moment the user clicks, types, or scrolls: show and sound that Sage
    /// noticed, before the screen has even finished changing. A pause feels
    /// fine when you can see something is happening; silence feels broken.
    private func acknowledgeUserActionImmediately() {
        SoundEffectsPlayer.play(.lookingAgain)
        isFollowingAlong = false
        // They've acted on the element, so the cursor can stop pointing at it.
        currentPointingTarget = nil
        if !isReplyInProgress {
            voiceState = .processing
        }
    }

    private func lookAgainAfterUserAction() {
        guard let followUpText = followAlongSession.nextQuestion() else { return }
        logger.notice("Following along: looking again (step \(self.followAlongSession.stepCount, privacy: .public))")

        startReply(mode: .companion, userText: followUpText, isFollowAlongLook: true)
    }

    // MARK: - Reply Pipeline

    /// - `isFollowAlongLook`: a follow-along step. Only the screen the user is
    ///   working on is sent, which keeps uploads small on slow connections.
    private func startReply(mode: ConversationMode, userText: String, isFollowAlongLook: Bool = false) {
        interruptCurrentReply()

        isReplyInProgress = true
        voiceState = .processing

        let replyIdentifier = currentReplyIdentifier
        currentReplyTask = Task { [weak self] in
            await self?.runReply(mode: mode, userText: userText, isFollowAlongLook: isFollowAlongLook, replyIdentifier: replyIdentifier)
        }
    }

    /// Stops whatever Sage is saying or about to say.
    private func interruptCurrentReply() {
        currentReplyIdentifier = UUID()
        currentReplyTask?.cancel()
        currentReplyTask = nil
        slowConnectionNoticeTask?.cancel()
        slowConnectionNoticeTask = nil
        speechPlaybackQueue.stopAll()
        pointingTargetsBySentenceID.removeAll()
        currentPointingTarget = nil
        isReplyInProgress = false
    }

    private func runReply(mode: ConversationMode, userText: String, isFollowAlongLook: Bool, replyIdentifier: UUID) async {
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
                input: ReplyInput(mode: mode, userText: userText,
                                  conversationHistory: mode == .companion ? conversationMemory.turns : [],
                                  onlyCursorScreen: isFollowAlongLook)
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

    private func finishReply(mode: ConversationMode) {
        currentReplyTask = nil
        isReplyInProgress = false
        voiceState = .idle

        if mode == .onboarding {
            showOnboardingPrompt()
        }
    }

    private func handleReplyExecutionEvent(_ event: ReplyExecutionEvent) {
        switch event {
        case .textReceived:
            hasCurrentReplyStartedArriving = true
        case .sentence(let text, let target):
            let sentenceID = UUID()
            if let target { pointingTargetsBySentenceID[sentenceID] = target }
            speechPlaybackQueue.enqueue(text: text, segmentID: sentenceID, voice: activeVoice)
        case .pointing(let target):
            currentPointingTarget = target
        case .followAlong:
            startFollowingAlong()
        }
    }

    private func handleSentenceStartedPlaying(sentenceID: UUID) {
        if sentenceID == slowConnectionNoticeSentenceID {
            return
        }
        if voiceState == .processing {
            voiceState = .responding
        }
        if let pointingTarget = pointingTargetsBySentenceID.removeValue(forKey: sentenceID) {
            currentPointingTarget = pointingTarget
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
