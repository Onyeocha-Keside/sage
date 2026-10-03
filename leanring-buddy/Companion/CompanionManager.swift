//
//  CompanionManager.swift
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

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

/// Which voice Sage speaks with. Persisted across launches.
enum SageVoiceOption: String, CaseIterable, Identifiable {
    /// macOS's built-in voice. Free.
    case mac
    /// ElevenLabs through the Worker. Sounds great, costs credits.
    case elevenLabs

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mac: return "Mac"
        case .elevenLabs: return "ElevenLabs"
        }
    }
}

@MainActor
final class CompanionManager: ObservableObject {
    // MARK: - Published State

    @Published private(set) var voiceState: CompanionVoiceState = .idle
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

    /// The "hold control + option and ask me anything" hint typed out next
    /// to the cursor after the onboarding demo.
    @Published private(set) var onboardingPromptText = ""
    @Published private(set) var onboardingPromptOpacity: Double = 0

    // MARK: - Collaborators

    let permissions = PermissionsCoordinator()
    let dictationManager = PushToTalkDictationManager()
    private let shortcutMonitor = GlobalPushToTalkShortcutMonitor()
    private let overlayWindowManager = OverlayWindowManager()
    private let claudeClient = ClaudeClient()
    private let macVoice = AppleSpeechVoice()
    private let elevenLabsVoice = ElevenLabsSpeechVoice()
    private lazy var speechPlaybackQueue = SpeechPlaybackQueue(fallbackVoice: macVoice)
    private let userActivityWatcher = UserActivityWatcher()

    // MARK: - Private State

    private let logger = Logger(subsystem: "com.kesideonyeocha.sage", category: "companion")

    private static let hasCompletedOnboardingDefaultsKey = "hasCompletedOnboarding"
    private static let selectedVoiceDefaultsKey = "selectedVoice"
    private static let maximumRememberedTurns = 10
    private static let onboardingPromptMessage = "hold control + option and ask me anything"
    /// A guided task stops after this many look-again steps, as a safety net.
    private static let maximumFollowAlongSteps = 8

    /// Past exchanges replayed to Claude so it remembers the conversation.
    private var conversationHistory: [ConversationTurn] = []
    private var currentReplyTask: Task<Void, Never>?
    private var pendingRecordingStartTask: Task<Void, Never>?
    private var onboardingPromptTask: Task<Void, Never>?
    /// Pointing targets waiting for their sentence to start playing, keyed by sentence ID.
    private var pointingTargetsBySentenceID: [UUID: PointingTarget] = [:]
    /// What the user originally asked for, kept while following along so each
    /// fresh screenshot can be judged against the real goal.
    private var followAlongGoal: String?
    private var followAlongStepCount = 0
    /// Set once the current reply's first words arrive, so the slow-connection
    /// notice knows whether it's still needed.
    private var hasCurrentReplyStartedArriving = false
    private var slowConnectionNoticeTask: Task<Void, Never>?
    /// The notice is filler, not the answer, so it shouldn't end the "thinking" state.
    private var slowConnectionNoticeSentenceID: UUID?
    /// If no words have arrived after this long, Sage says it's still working.
    private static let slowConnectionNoticeDelaySeconds: Double = 6
    private var cancellables = Set<AnyCancellable>()

    /// Everything gathered about the reply currently being streamed.
    private struct ReplyInProgress {
        let capturedScreens: [CapturedScreen]
        var spokenText = ""
        /// A tag Claude wrote whose sentence hasn't arrived yet.
        var pointingTargetForNextSentence: PointingTarget?
        var wasRefused = false
        /// Claude ended with [FOLLOW]: it's waiting for the user to act.
        var wantsToFollowAlong = false
    }

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

        claudeClient.warmUpConnection()
    }

    func stop() {
        stopFollowingAlong()
        shortcutMonitor.stop()
        dictationManager.cancel()
        interruptCurrentReply()
        overlayWindowManager.hideOverlay()
        permissions.stopMonitoring()
    }

    // MARK: - Settings

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
            companionManager: self
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
        followAlongGoal = questionText
        followAlongStepCount = 0
        startReply(mode: .companion, userText: questionText)
    }

    /// Watches for the user to do the step Sage just described. Called as soon
    /// as Claude's [FOLLOW] tag arrives, so a quick click isn't missed even if
    /// Sage is still finishing its sentence.
    private func startFollowingAlong() {
        guard followAlongGoal != nil, followAlongStepCount < Self.maximumFollowAlongSteps else {
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
        followAlongGoal = nil
        followAlongStepCount = 0
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
        guard let followAlongGoal else { return }
        followAlongStepCount += 1
        logger.notice("Following along: looking again (step \(self.followAlongStepCount, privacy: .public))")

        let followUpText = """
        (i did that step. this screenshot is my screen right now. keep guiding me toward my goal: "\(followAlongGoal)". \
        if my screen isn't what you expected, adjust from what you actually see. \
        if the goal is done, say so in one short sentence and don't add [FOLLOW].)
        """
        startReply(mode: .companion, userText: followUpText, isFollowAlongLook: true)
    }

    // MARK: - Reply Pipeline

    /// - `isFollowAlongLook`: a follow-along step. Only the screen the user is
    ///   working on is sent, which keeps uploads small on slow connections.
    private func startReply(mode: ConversationMode, userText: String, isFollowAlongLook: Bool = false) {
        interruptCurrentReply()

        isReplyInProgress = true
        voiceState = .processing

        currentReplyTask = Task { [weak self] in
            await self?.runReply(mode: mode, userText: userText, isFollowAlongLook: isFollowAlongLook)
        }
    }

    /// Stops whatever Sage is saying or about to say.
    private func interruptCurrentReply() {
        currentReplyTask?.cancel()
        currentReplyTask = nil
        slowConnectionNoticeTask?.cancel()
        slowConnectionNoticeTask = nil
        speechPlaybackQueue.stopAll()
        pointingTargetsBySentenceID.removeAll()
        currentPointingTarget = nil
        isReplyInProgress = false
    }

    private func runReply(mode: ConversationMode, userText: String, isFollowAlongLook: Bool) async {
        hasCurrentReplyStartedArriving = false
        startSlowConnectionNotice()
        defer {
            slowConnectionNoticeTask?.cancel()
            slowConnectionNoticeTask = nil
        }

        do {
            let allCapturedScreens = try await ScreenCaptureService.captureAllScreens()
            let capturedScreens = isFollowAlongLook
                ? Array(allCapturedScreens.filter { $0.isCursorScreen }.prefix(1)).ifEmpty(allCapturedScreens)
                : allCapturedScreens
            try Task.checkCancellation()

            var replyInProgress = ReplyInProgress(capturedScreens: capturedScreens)
            var responseSegmenter = StreamingResponseSegmenter()

            // A server hiccup before any words arrive is retried once, quietly.
            // Once Sage has started talking, a retry would repeat itself, so
            // later failures are reported instead.
            var hasReceivedAnyReplyText = false
            for attemptNumber in 1...2 {
                do {
                    try await claudeClient.streamReply(
                        mode: mode,
                        conversationHistory: mode == .companion ? conversationHistory : [],
                        capturedScreens: capturedScreens,
                        userText: userText
                    ) { streamEvent in
                        switch streamEvent {
                        case .textDelta(let newText):
                            hasReceivedAnyReplyText = true
                            hasCurrentReplyStartedArriving = true
                            queueSegmentsForPlayback(responseSegmenter.append(newText), replyInProgress: &replyInProgress)
                        case .refusal:
                            replyInProgress.wasRefused = true
                        }
                    }
                    break
                } catch let claudeClientError as ClaudeClientError {
                    let isServerError = (claudeClientError.httpStatusCode ?? 0) >= 500
                    guard attemptNumber == 1, isServerError, !hasReceivedAnyReplyText else { throw claudeClientError }
                    logger.notice("Server error before any reply text, retrying once: \(claudeClientError.message, privacy: .public)")
                    try await Task.sleep(for: .milliseconds(600))
                }
            }
            try Task.checkCancellation()

            queueSegmentsForPlayback(responseSegmenter.finish(), replyInProgress: &replyInProgress)

            // A tag at the very end with no sentence after it: point right away.
            if let leftoverPointingTarget = replyInProgress.pointingTargetForNextSentence {
                currentPointingTarget = leftoverPointingTarget
            }

            if replyInProgress.spokenText.isEmpty {
                let emptyReplyMessage = replyInProgress.wasRefused
                    ? "i can't help with that one, but ask me something else."
                    : "hmm, i blanked on that. try asking again."
                queueSegmentsForPlayback([.speech(emptyReplyMessage)], replyInProgress: &replyInProgress)
            } else if mode == .companion {
                rememberExchange(userText: userText, assistantText: replyInProgress.spokenText)
            }

            await speechPlaybackQueue.waitUntilFinishedPlaying()

            if mode == .companion && !replyInProgress.wantsToFollowAlong {
                // Claude didn't ask the user to do anything, so the guided task is over.
                stopFollowingAlong()
            }
        } catch {
            guard !Task.isCancelled, !Self.isCancellation(error) else { return }
            stopFollowingAlong()
            print("⚠️ Reply failed: \(error)")
            logger.error("Reply failed: \(String(describing: error), privacy: .public)")
            // Always explain errors with the free Mac voice, so an ElevenLabs
            // problem can't hide the explanation.
            speechPlaybackQueue.enqueue(
                text: Self.spokenExplanation(for: error),
                segmentID: UUID(),
                voice: macVoice
            )
            await speechPlaybackQueue.waitUntilFinishedPlaying()
        }

        guard !Task.isCancelled else { return }
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

    /// Speaks each finished sentence and lines pointing tags up with the
    /// sentence that follows them.
    private func queueSegmentsForPlayback(_ responseSegments: [ResponseSegment], replyInProgress: inout ReplyInProgress) {
        for responseSegment in responseSegments {
            switch responseSegment {
            case .pointing(let pointingTag):
                replyInProgress.pointingTargetForNextSentence = pointingTag.resolve(against: replyInProgress.capturedScreens)

            case .speech(let sentence):
                let sentenceID = UUID()
                if let pointingTarget = replyInProgress.pointingTargetForNextSentence {
                    pointingTargetsBySentenceID[sentenceID] = pointingTarget
                    replyInProgress.pointingTargetForNextSentence = nil
                }
                replyInProgress.spokenText += replyInProgress.spokenText.isEmpty ? sentence : " " + sentence
                speechPlaybackQueue.enqueue(text: sentence, segmentID: sentenceID, voice: activeVoice)

            case .followAlong:
                replyInProgress.wantsToFollowAlong = true
                startFollowingAlong()
            }
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

    private func rememberExchange(userText: String, assistantText: String) {
        conversationHistory.append(ConversationTurn(userText: userText, assistantText: assistantText))
        if conversationHistory.count > Self.maximumRememberedTurns {
            conversationHistory.removeFirst(conversationHistory.count - Self.maximumRememberedTurns)
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

    // MARK: - Error Messages

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// Turns an error into one short sentence Sage can say out loud.
    private static func spokenExplanation(for error: Error) -> String {
        if error is SageConfigurationError {
            return "i'm not set up yet. add the worker address and app key to sage secrets, then restart me."
        }
        if error is ScreenCaptureFailure {
            return "i couldn't see your screen. make sure screen recording is turned on for sage."
        }
        if let claudeClientError = error as? ClaudeClientError, let httpStatusCode = claudeClientError.httpStatusCode {
            switch httpStatusCode {
            case 401:
                return "my app key doesn't match the server. check that it's the same in both places."
            case 429:
                return "i'm getting a lot of requests right now. give me a minute."
            case 500...599:
                return "my brain is having a moment on the server side. try again in a few seconds."
            default:
                break
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed:
                return "looks like you're offline. check your wifi, then ask me again."
            case .timedOut:
                return "my connection timed out. your internet might be slow right now, try asking again."
            default:
                return "i can't reach my server. check your internet, or make sure the worker is running."
            }
        }
        return "something went wrong on my end. try that again."
    }
}


private extension Array {
    /// Returns `fallback` when this array is empty.
    func ifEmpty(_ fallback: [Element]) -> [Element] {
        isEmpty ? fallback : self
    }
}
