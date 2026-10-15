import Foundation
import Testing
@testable import Sage

@MainActor
struct TranscriptFinalizationPolicyTests {
    private let policy = TranscriptFinalizationPolicy()

    @Test func finishesOnceAStableTranscriptHasSettled() {
        // Speech stopped well before release: done right after the minimum wait.
        #expect(policy.shouldFinish(secondsSinceRelease: 0.3, secondsSinceTranscriptLastChanged: 1.0, hasTranscriptText: true))
    }

    @Test func waitsForWordsSpokenRightBeforeRelease() {
        #expect(!policy.shouldFinish(secondsSinceRelease: 0.1, secondsSinceTranscriptLastChanged: 2.0, hasTranscriptText: true))
        #expect(!policy.shouldFinish(secondsSinceRelease: 0.5, secondsSinceTranscriptLastChanged: 0.1, hasTranscriptText: true))
    }

    @Test func givesUpAtTheMaximumWait() {
        #expect(!policy.shouldFinish(secondsSinceRelease: 1.0, secondsSinceTranscriptLastChanged: 1.0, hasTranscriptText: false))
        #expect(policy.shouldFinish(secondsSinceRelease: 1.2, secondsSinceTranscriptLastChanged: 0, hasTranscriptText: false))
    }
}
