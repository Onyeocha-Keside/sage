import Foundation
import Testing
@testable import Sage

@MainActor
struct SessionStateTests {
    @Test func retainsOnlyNewestHistory() {
        var memory = ConversationMemory(maximumTurns: 2)
        for number in 1...3 { memory.remember(userText: "question \(number)", assistantText: "answer") }
        #expect(memory.turns.count == 2)
        #expect(memory.turns.first?.userText == "question 2")
    }
    @Test func limitsAndResetsFollowAlong() {
        var session = FollowAlongSession(maximumSteps: 1)
        session.begin(goal: "export")
        #expect(session.nextQuestion()?.contains("export") == true)
        #expect(session.nextQuestion() == nil)
        session.end()
        #expect(session.goal == nil)
        #expect(session.stepCount == 0)
    }
}
