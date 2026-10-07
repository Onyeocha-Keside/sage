import Foundation

/// Which system prompt the Worker should use.
enum ConversationMode: String {
    /// Normal push-to-talk conversation.
    case companion
    /// The first-run demo, where Sage points at something on screen to show off.
    case onboarding
}

/// One earlier exchange, replayed as text so Claude remembers the conversation.
struct ConversationTurn {
    let userText: String
    let assistantText: String
}

enum ClaudeStreamEvent {
    /// More reply text arrived.
    case textDelta(String)
    /// Claude declined to answer (a safety classifier refusal).
    case refusal
}

struct SageAPIError: LocalizedError {
    /// HTTP status from the Worker, or nil when the failure came mid-stream.
    let httpStatusCode: Int?
    let message: String

    var errorDescription: String? { message }
}

