import Foundation

/// Owns the goal and step budget separately from event monitors and reply tasks.
struct FollowAlongSession {
    private(set) var goal: String?
    private(set) var stepCount = 0
    private let maximumSteps: Int

    init(maximumSteps: Int = 8) {
        precondition(maximumSteps > 0)
        self.maximumSteps = maximumSteps
    }

    var canContinue: Bool { goal != nil && stepCount < maximumSteps }

    mutating func begin(goal: String) {
        self.goal = goal
        stepCount = 0
    }

    mutating func end() {
        goal = nil
        stepCount = 0
    }

    mutating func nextQuestion() -> String? {
        guard canContinue, let goal else { return nil }
        stepCount += 1
        return """
        (i did that step. this screenshot is my screen right now. keep guiding me toward my goal: "\(goal)". \
        if my screen isn't what you expected, adjust from what you actually see. \
        if the goal is done, say so in one short sentence and don't add [FOLLOW].)
        """
    }
}
