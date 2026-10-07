import Foundation
import Testing
@testable import Sage

@MainActor
struct ClaudeStreamDecoderTests {
    @Test func rejectsPrematureEndOfStream() {
        let decoder = ClaudeStreamDecoder()
        #expect(throws: SageAPIError.self) { try decoder.finish() }
    }
    @Test func acceptsExplicitCompletion() throws {
        var decoder = ClaudeStreamDecoder()
        _ = try decoder.consume(line: #"data:{"type":"message_stop"}"#)
        try decoder.finish()
        #expect(decoder.hasCompleted)
    }
    @Test func rejectsMalformedData() {
        var decoder = ClaudeStreamDecoder()
        #expect(throws: SageAPIError.self) { _ = try decoder.consume(line: "data: {broken") }
    }
    @Test func rejectsOutputTruncation() throws {
        var decoder = ClaudeStreamDecoder()
        _ = try decoder.consume(line: #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#)
        #expect(throws: SageAPIError.self) { _ = try decoder.consume(line: #"data: {"type":"message_stop"}"#) }
    }
}
