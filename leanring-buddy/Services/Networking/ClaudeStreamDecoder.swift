import Foundation

/// Interprets the provider's JSON data lines independently of the network transport.
/// A socket closing is not proof that the model finished its answer.
struct ClaudeStreamDecoder {
    private(set) var hasCompleted = false
    private var stopReason: String?

    mutating func consume(line: String) throws -> [ClaudeStreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventType = event["type"] as? String else {
            throw SageAPIError(httpStatusCode: nil, message: "The reply stream contained invalid data.")
        }
        switch eventType {
        case "content_block_delta":
            if let delta = event["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                return [.textDelta(text)]
            }
        case "message_delta":
            if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                stopReason = reason
                if reason == "refusal" { return [.refusal] }
            }
        case "error":
            // Provider messages may include user content; don't expose them in diagnostics.
            throw SageAPIError(httpStatusCode: nil, message: "The provider reported a reply-stream error.")
        case "message_stop":
            if stopReason == "max_tokens" {
                throw SageAPIError(httpStatusCode: nil, message: "The reply was cut off at the output limit.")
            }
            hasCompleted = true
        default:
            break // Providers can add event types; thinking and ping events aren't spoken.
        }
        return []
    }

    func finish() throws {
        guard hasCompleted else {
            throw SageAPIError(httpStatusCode: nil, message: "The connection closed before the reply finished.")
        }
    }
}
