import Foundation

struct ReplyInput {
    let mode: ConversationMode
    let userText: String
    let conversationHistory: [ConversationTurn]
    let onlyCursorScreen: Bool
    /// A capture already started by the caller (at key release, while the
    /// transcript was still finishing). Used instead of capturing again.
    var prefetchedScreens: Task<[CapturedScreen], Error>? = nil
}

enum ReplyExecutionEvent {
    case screensCaptured([CapturedScreen])
    case textReceived
    case sentence(text: String, target: PointingTarget?)
    case pointing(PointingTarget)
    case followAlong
    case nextStepHint(String)
}

struct ReplyResult {
    let spokenText: String
    let hasAnswer: Bool
    let wantsToFollowAlong: Bool
}

/// Owns capture, provider retry, and stream assembly. The coordinator consumes
/// explicit events; UI state and playback stay outside this executor.
@MainActor
final class ReplyExecutor {
    typealias CaptureScreens = (Bool) async throws -> [CapturedScreen]
    private let client: any ReplyStreamingClient
    private let captureScreens: CaptureScreens

    init(client: any ReplyStreamingClient,
         captureScreens: @escaping CaptureScreens = { onlyCursorScreen in
             try await ScreenCaptureService.captureScreens(onlyCursorScreen: onlyCursorScreen)
         }) {
        self.client = client
        self.captureScreens = captureScreens
    }

    func execute(input: ReplyInput, onEvent: (ReplyExecutionEvent) -> Void) async throws -> ReplyResult {
        let screens: [CapturedScreen]
        if let prefetchedScreens = input.prefetchedScreens {
            screens = try await withTaskCancellationHandler {
                try await prefetchedScreens.value
            } onCancel: {
                prefetchedScreens.cancel()
            }
        } else {
            screens = try await captureScreens(input.onlyCursorScreen)
        }
        try Task.checkCancellation()
        onEvent(.screensCaptured(screens))
        var assembly = ReplyAssembly(capturedScreens: screens)
        var segmenter = StreamingResponseSegmenter()
        var receivedText = false

        for attempt in 1...2 {
            do {
                try await client.streamReply(mode: input.mode, conversationHistory: input.conversationHistory,
                                             capturedScreens: screens, userText: input.userText) { event in
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .textDelta(let text):
                        receivedText = true
                        onEvent(.textReceived)
                        emit(segmenter.append(text), assembly: &assembly, onEvent: onEvent)
                    case .refusal:
                        assembly.wasRefused = true
                    }
                }
                break
            } catch let error as SageAPIError {
                // Budget/service-unavailable responses must not cause repeated
                // attempts. A genuine 500/502/504 may retry before any text.
                guard attempt == 1, [500, 502, 504].contains(error.httpStatusCode ?? 0), !receivedText else { throw error }
                try await Task.sleep(for: .milliseconds(600))
            }
        }
        try Task.checkCancellation()
        emit(segmenter.finish(), assembly: &assembly, onEvent: onEvent)
        if let target = assembly.pointingTargetForNextSentence { onEvent(.pointing(target)) }
        let hasAnswer = !assembly.spokenText.isEmpty
        if !hasAnswer {
            let message = assembly.wasRefused ? "i can't help with that one, but ask me something else." : "hmm, i blanked on that. try asking again."
            emit([.speech(message)], assembly: &assembly, onEvent: onEvent)
        }
        return ReplyResult(spokenText: assembly.spokenText, hasAnswer: hasAnswer, wantsToFollowAlong: assembly.wantsToFollowAlong)
    }

    private func emit(_ segments: [ResponseSegment], assembly: inout ReplyAssembly,
                      onEvent: (ReplyExecutionEvent) -> Void) {
        for segment in segments {
            switch segment {
            case .pointing(let tag):
                assembly.pointingTargetForNextSentence = tag.resolve(against: assembly.capturedScreens)
            case .speech(let sentence):
                onEvent(.sentence(text: sentence, target: assembly.pointingTargetForNextSentence))
                assembly.pointingTargetForNextSentence = nil
                assembly.spokenText += assembly.spokenText.isEmpty ? sentence : " " + sentence
            case .followAlong:
                assembly.wantsToFollowAlong = true
                onEvent(.followAlong)
            case .nextStepHint(let hintText):
                onEvent(.nextStepHint(hintText))
            }
        }
    }
}
