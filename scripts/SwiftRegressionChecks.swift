import CoreGraphics
import Foundation

@MainActor
private func verify(_ condition: @autoclosure () -> Bool, _ description: String) {
    precondition(condition(), description)
}

@MainActor
private final class ControlledVoice: SpeechVoice {
    var playbackStarts = 0
    var playbackStops = 0
    var continuation: CheckedContinuation<Void, Error>?
    func prepare(_ text: String) -> PreparedSpeech { PreparedSpeech(text: text, audioDownloadTask: nil) }
    func play(_ speech: PreparedSpeech, onPlaybackStarted: () -> Void) async throws {
        playbackStarts += 1
        onPlaybackStarted()
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func stopPlayback() {
        playbackStops += 1
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

@MainActor
private final class ScriptedReplyClient: ReplyStreamingClient {
    var attempts = 0
    var failBeforeText = false
    var failAfterText = false
    var failureStatus = 500
    var text = "[POINT:640,200:save]Click Save. [FOLLOW]"
    func streamReply(mode: ConversationMode, conversationHistory: [ConversationTurn],
                     capturedScreens: [CapturedScreen], userText: String,
                     onEvent: (ClaudeStreamEvent) -> Void) async throws {
        attempts += 1
        if failBeforeText && attempts == 1 { throw SageAPIError(httpStatusCode: failureStatus, message: "test") }
        onEvent(.textDelta(text))
        if failAfterText { throw SageAPIError(httpStatusCode: 500, message: "test") }
    }
}

@main
private struct SwiftRegressionChecks {
    @MainActor
    static func main() async throws {
        verify(AppConfiguration.validatedWorkerURL("https://worker.test") != nil, "HTTPS configuration rejected")
        verify(AppConfiguration.validatedWorkerURL("http://localhost:8787") != nil, "Local development rejected")
        verify(AppConfiguration.validatedWorkerURL("http://worker.test") == nil, "Remote HTTP could leak credentials")
        verify(AppConfiguration.validatedWorkerURL("relative/path") == nil, "Relative Worker address accepted")
        verify(AppConfiguration.validatedWorkerURL("https://user:secret@worker.test") == nil, "Embedded credentials accepted")
        var decoder = ClaudeStreamDecoder()
        let deltaEvents = try decoder.consume(line: #"data:{"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}"#)
        verify(deltaEvents.count == 1, "Text delta should be delivered")
        if case .textDelta(let text) = deltaEvents[0] { verify(text == "hello", "Text changed") }
        else { preconditionFailure("Expected text") }
        do { try decoder.finish(); preconditionFailure("Premature EOF must fail") } catch is SageAPIError {}
        _ = try decoder.consume(line: #"data: {"type":"message_stop"}"#)
        try decoder.finish()
        verify(decoder.hasCompleted, "Completion marker ignored")
        var invalidDecoder = ClaudeStreamDecoder()
        do { _ = try invalidDecoder.consume(line: "data: {broken"); preconditionFailure("Invalid JSON must fail") } catch is SageAPIError {}
        var limitDecoder = ClaudeStreamDecoder()
        _ = try limitDecoder.consume(line: #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#)
        do { _ = try limitDecoder.consume(line: #"data: {"type":"message_stop"}"#); preconditionFailure("Output truncation must fail") } catch is SageAPIError {}
        var thinkingDecoder = ClaudeStreamDecoder()
        let thinkingEvents = try thinkingDecoder.consume(line: #"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"private"}}"#)
        verify(thinkingEvents.isEmpty, "Thinking must not be spoken")
        var refusalDecoder = ClaudeStreamDecoder()
        let refusals = try refusalDecoder.consume(line: #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#)
        verify(refusals.count == 1, "Refusal ignored")
        var errorDecoder = ClaudeStreamDecoder()
        do { _ = try errorDecoder.consume(line: #"data: {"type":"error","error":{"message":"sensitive user data"}}"#); preconditionFailure("Provider error must fail") }
        catch let error as SageAPIError { verify(!error.message.contains("sensitive"), "Provider content leaked") }

        let screen = CapturedScreen(jpegData: Data(), labelForClaude: "test", isCursorScreen: true, displayFrame: CGRect(x: -1440, y: 0, width: 1440, height: 900), screenshotWidthInPixels: 1280, screenshotHeightInPixels: 800)
        for shortcut in PushToTalkShortcut.allCases {
            verify(shortcut.matches(shortcut.flags), "Selected shortcut didn't match")
            verify(!shortcut.matches([.maskControl, .maskAlternate]), "VoiceOver modifier started Sage")
            let otherModifier: CGEventFlags = shortcut == .commandShift ? .maskControl : .maskCommand
            verify(!shortcut.matches(shortcut.flags.union(otherModifier)), "Extra modifiers started Sage")
        }
        let client = ScriptedReplyClient()
        var capturedOnlyCursor = false
        let executor = ReplyExecutor(client: client, captureScreens: { onlyCursor in
            capturedOnlyCursor = onlyCursor
            return [screen]
        })
        let input = ReplyInput(mode: .companion, userText: "save", conversationHistory: [], onlyCursorScreen: true)
        var sentences = 0
        var followEvents = 0
        let result = try await executor.execute(input: input) { event in
            switch event {
            case .sentence(let text, let target):
                verify(text == "Click Save.", "Reply sentence changed")
                verify(target?.globalScreenLocation == CGPoint(x: -720, y: 675), "Reply lost its pointing target")
                sentences += 1
            case .followAlong: followEvents += 1
            default: break
            }
        }
        verify(capturedOnlyCursor && sentences == 1 && followEvents == 1 && result.wantsToFollowAlong, "Executor lost capture scope or follow-along")
        let retryClient = ScriptedReplyClient()
        retryClient.failBeforeText = true
        _ = try await ReplyExecutor(client: retryClient, captureScreens: { _ in [screen] }).execute(input: input) { _ in }
        verify(retryClient.attempts == 2, "Pre-text server error wasn't retried")
        let partialClient = ScriptedReplyClient()
        partialClient.failAfterText = true
        do {
            _ = try await ReplyExecutor(client: partialClient, captureScreens: { _ in [screen] }).execute(input: input) { _ in }
            preconditionFailure("Partial answer failure was swallowed")
        } catch is SageAPIError {}
        verify(partialClient.attempts == 1, "Partial answer was repeated")
        let budgetClient = ScriptedReplyClient()
        budgetClient.failBeforeText = true
        budgetClient.failureStatus = 503
        do {
            _ = try await ReplyExecutor(client: budgetClient, captureScreens: { _ in [screen] }).execute(input: input) { _ in }
            preconditionFailure("Budget failure was swallowed")
        } catch is SageAPIError {}
        verify(budgetClient.attempts == 1, "Budget rejection was retried")
        let cancelledClient = ScriptedReplyClient()
        let cancelledTask = Task {
            try await ReplyExecutor(client: cancelledClient, captureScreens: { _ in
                try await Task.sleep(for: .seconds(10))
                return [screen]
            }).execute(input: input) { _ in preconditionFailure("Cancelled reply emitted an event") }
        }
        cancelledTask.cancel()
        do { _ = try await cancelledTask.value; preconditionFailure("Cancelled executor finished") } catch is CancellationError {}
        verify(cancelledClient.attempts == 0, "Cancelled capture reached the provider")

        let pointingTag = PointingTag.parse("[POINT:640,200:save]")!
        verify(pointingTag.resolve(against: [screen])?.globalScreenLocation == CGPoint(x: -720, y: 675), "Negative-origin screen mapping failed")
        verify(PointingTag.parse("[POINT:640,200:save:screen2]")!.resolve(against: [screen]) == nil, "Unknown monitor must not point at another monitor")
        let invalidScreen = CapturedScreen(jpegData: Data(), labelForClaude: "test", isCursorScreen: true, displayFrame: screen.displayFrame, screenshotWidthInPixels: 0, screenshotHeightInPixels: 0)
        verify(pointingTag.resolve(against: [invalidScreen]) == nil, "Invalid image geometry must be rejected")

        for chunkSize in 1...12 {
            var segmenter = StreamingResponseSegmenter()
            let reply = "[POINT:42,12:file] open the file menu. [FOLLOW]"
            var remaining = Substring(reply)
            var segments: [ResponseSegment] = []
            while !remaining.isEmpty {
                segments += segmenter.append(String(remaining.prefix(chunkSize)))
                remaining = remaining.dropFirst(min(chunkSize, remaining.count))
            }
            segments += segmenter.finish()
            verify(segments == [.pointing(PointingTag.parse("[POINT:42,12:file]")!), .speech("open the file menu."), .followAlong], "Chunk boundaries changed control tags")
        }
        for chunkSize in 1...12 {
            var segmenter = StreamingResponseSegmenter()
            var remaining = Substring("sure, [POINT:42,12:file] open the file menu, then export.")
            var segments: [ResponseSegment] = []
            while !remaining.isEmpty {
                segments += segmenter.append(String(remaining.prefix(chunkSize)))
                remaining = remaining.dropFirst(min(chunkSize, remaining.count))
            }
            segments += segmenter.finish()
            verify(segments == [.speech("sure,"), .pointing(PointingTag.parse("[POINT:42,12:file]")!), .speech("open the file menu, then export.")], "Chunk boundaries changed the early opening clause")
        }
        for chunkSize in 1...12 {
            var segmenter = StreamingResponseSegmenter()
            var remaining = Substring("click save. [FOLLOW] [NEXT:Save As] ")
            var segments: [ResponseSegment] = []
            while !remaining.isEmpty {
                segments += segmenter.append(String(remaining.prefix(chunkSize)))
                remaining = remaining.dropFirst(min(chunkSize, remaining.count))
            }
            segments += segmenter.finish()
            verify(segments == [.speech("click save."), .followAlong, .nextStepHint("Save As")], "Chunk boundaries leaked or lost the next-step hint")
        }
        // Scroll compensation: only scrolling after the screenshot, over the
        // target's window, moves it; content moving down lowers AppKit Y.
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let scrolls = [
            ScrollMovement(uptime: 9, mouseLocation: CGPoint(x: 100, y: 100), deltaX: 0, deltaY: 500, hasPreciseDeltas: true),
            ScrollMovement(uptime: 11, mouseLocation: CGPoint(x: 100, y: 100), deltaX: 0, deltaY: -120, hasPreciseDeltas: true),
            ScrollMovement(uptime: 12, mouseLocation: CGPoint(x: 900, y: 100), deltaX: 0, deltaY: -999, hasPreciseDeltas: false)
        ]
        let compensation = PointingTargetGeometry.contentShift(from: scrolls, after: 10, within: window)
        verify(compensation.shift == CGVector(dx: 0, dy: 120) && !compensation.hasImpreciseMovement, "Scroll shift used the wrong events or sign")
        verify(PointingTargetGeometry.placement(of: CGPoint(x: 400, y: 300), within: window).offScreenEdge == nil, "Visible target marked off-screen")
        let scrolledAway = PointingTargetGeometry.placement(of: CGPoint(x: 400, y: 900), within: window)
        verify(scrolledAway.offScreenEdge == .above && scrolledAway.location == CGPoint(x: 400, y: 572), "Off-screen target not parked at the top edge")
        verify(PointingTargetGeometry.placement(of: CGPoint(x: 400, y: -50), within: window).offScreenEdge == .below, "Target below the view not detected")
        verify(PointingTargetGeometry.flipBetweenTopLeftAndAppKit(CGRect(x: 10, y: 20, width: 30, height: 40), primaryDisplayHeight: 1000)
            == CGRect(x: 10, y: 940, width: 30, height: 40), "Accessibility frame conversion is wrong")
        let shownTarget = pointingTag.resolve(against: [screen])!
        let movedTarget = shownTarget.moved(to: .zero, offScreenEdge: .below)
        verify(movedTarget.id == shownTarget.id && movedTarget.label == shownTarget.label, "Moving a target must keep its identity")

        // Settling: a still screen only counts after a visible change, unless
        // nothing changes for a while; there's always a hard maximum.
        var slowPage = ScreenSettleTracker(hasBaseline: true)
        verify(!slowPage.observe(secondsSinceActivity: 0.1, differenceFromPrevious: nil, differenceFromBaseline: 0.2), "Settled before any sample pair")
        verify(!slowPage.observe(secondsSinceActivity: 0.4, differenceFromPrevious: 0.1, differenceFromBaseline: 0.2), "Old page counted as settled")
        verify(!slowPage.observe(secondsSinceActivity: 0.5, differenceFromPrevious: 30, differenceFromBaseline: 30), "Settled mid-change")
        verify(!slowPage.observe(secondsSinceActivity: 0.6, differenceFromPrevious: 0.3, differenceFromBaseline: 30), "Settled too soon after change")
        verify(slowPage.observe(secondsSinceActivity: 0.85, differenceFromPrevious: 0.2, differenceFromBaseline: 30), "New page didn't settle")
        var subtleClick = ScreenSettleTracker(hasBaseline: true)
        _ = subtleClick.observe(secondsSinceActivity: 0.1, differenceFromPrevious: nil, differenceFromBaseline: 0)
        verify(!subtleClick.observe(secondsSinceActivity: 1.0, differenceFromPrevious: 0, differenceFromBaseline: 0), "Gave up on a visible change too early")
        verify(subtleClick.observe(secondsSinceActivity: 1.2, differenceFromPrevious: 0, differenceFromBaseline: 0), "Never looked after a subtle click")
        var noThumbnails = ScreenSettleTracker(hasBaseline: false)
        verify(!noThumbnails.observe(secondsSinceActivity: 3.9, differenceFromPrevious: nil, differenceFromBaseline: nil), "Settled without evidence")
        verify(noThumbnails.observe(secondsSinceActivity: 4.0, differenceFromPrevious: nil, differenceFromBaseline: nil), "Missed the maximum wait")

        // Circling: a closed loop in either direction counts; lines, zigzags and half circles don't.
        func loop(sweep: CGFloat) -> [CGPoint] {
            (0...80).map { step in
                let angle = sweep * CGFloat(step) / 80
                return CGPoint(x: 600 + 50 * cos(angle), y: 300 + 50 * sin(angle))
            }
        }
        let approachPath = (0..<60).map { CGPoint(x: CGFloat($0) * 8, y: 100) }
        let circled = CircleGestureDetector.detectCircle(in: approachPath + loop(sweep: 1.85 * .pi))
        verify(circled.map { abs($0.center.x - 600) < 15 && abs($0.center.y - 300) < 15 } == true, "Circle around a target not found")
        verify(CircleGestureDetector.detectCircle(in: loop(sweep: -2 * .pi)) != nil, "Clockwise circle not found")
        verify(CircleGestureDetector.detectCircle(in: approachPath) == nil, "A straight line counted as a circle")
        verify(CircleGestureDetector.detectCircle(in: (0..<200).map { CGPoint(x: CGFloat($0) * 5, y: $0 % 2 == 0 ? 0 : 40) }) == nil, "A zigzag counted as a circle")
        verify(CircleGestureDetector.detectCircle(in: loop(sweep: .pi)) == nil, "Half a circle counted")
        let roundFocus = CircledArea(outline: [], bounds: CGRect(x: 0, y: 0, width: 100, height: 90)).focusRect
        verify(roundFocus.width == roundFocus.height && roundFocus.width > 100, "A roughly round loop didn't snap to a padded circle")
        let wideFocus = CircledArea(outline: [], bounds: CGRect(x: 0, y: 0, width: 400, height: 80)).focusRect
        verify(wideFocus.width > wideFocus.height && wideFocus.contains(CGRect(x: 0, y: 0, width: 400, height: 80)), "A wide loop lost its ellipse or clipped the item")
        var closeUp = screen
        closeUp.isZoomedDetail = true
        verify(PointingTag.parse("[POINT:640,200:save:screen2]")!.resolve(against: [screen, closeUp]) == nil, "A close-up was treated as a second screen")

        var memory = ConversationMemory(maximumTurns: 2)
        for number in 1...3 { memory.remember(userText: "question \(number)", assistantText: "answer") }
        verify(memory.turns.count == 2 && memory.turns[0].userText == "question 2", "History did not evict oldest turn")
        var followAlong = FollowAlongSession(maximumSteps: 2)
        followAlong.begin(goal: "export")
        verify(followAlong.nextQuestion()?.contains("export") == true, "Follow-along lost original goal")
        verify(followAlong.nextQuestion() != nil, "Follow-along stopped early")
        verify(followAlong.nextQuestion() == nil && !followAlong.canContinue, "Follow-along exceeded step budget")
        followAlong.end()
        verify(followAlong.goal == nil && followAlong.stepCount == 0, "Follow-along state did not reset")
        let voice = ControlledVoice()
        let queue = SpeechPlaybackQueue(fallbackVoice: voice)
        queue.enqueue(text: "first", segmentID: UUID(), voice: voice)
        for _ in 0..<20 { await Task.yield() }
        verify(voice.playbackStarts == 1, "Queue did not start")
        queue.stopAll()
        queue.enqueue(text: "second", segmentID: UUID(), voice: voice)
        for _ in 0..<20 { await Task.yield() }
        verify(voice.playbackStarts == 2, "Replacement playback did not start")
        let stopsBefore = voice.playbackStops
        queue.stopAll()
        verify(voice.playbackStops == stopsBefore + 1, "Cancelled loop cleared the replacement voice handle")
        verify(!queue.isPlaying, "Stopped queue still marked playing")
        print("Swift regression checks passed: stream errors/completion, pointing geometry, chunked tags, shortcuts, reply execution/retry/cancellation, and interrupted speech ownership.")
    }
}
