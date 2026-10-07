import Foundation

/// Session-only text history. Screenshots and audio are never retained here.
struct ConversationMemory {
    private(set) var turns: [ConversationTurn] = []
    private let maximumTurns: Int

    init(maximumTurns: Int = 10) {
        precondition(maximumTurns > 0)
        self.maximumTurns = maximumTurns
    }

    mutating func remember(userText: String, assistantText: String) {
        turns.append(ConversationTurn(userText: userText, assistantText: assistantText))
        if turns.count > maximumTurns { turns.removeFirst(turns.count - maximumTurns) }
    }
}
