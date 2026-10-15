//
//  TranscriptFinalizationPolicy.swift
//  Sage
//
//  Decides when a push-to-talk transcript is done after the shortcut is
//  released. Apple's recognizer can take well over a second to send its
//  "final" result, but the live partial transcript is usually already right.
//  Once that partial has stopped changing for a moment, waiting longer only
//  adds silence before Sage answers.
//

import Foundation

struct TranscriptFinalizationPolicy {
    /// Audio spoken just before release is still being recognized for a
    /// moment, so never finish sooner than this after release.
    var minimumWaitAfterReleaseSeconds: TimeInterval = 0.25
    /// How long the partial transcript must stay unchanged to count as done.
    var requiredStableDurationSeconds: TimeInterval = 0.35
    /// Never wait longer than this for the recognizer.
    var maximumWaitAfterReleaseSeconds: TimeInterval = 1.2

    func shouldFinish(secondsSinceRelease: TimeInterval,
                      secondsSinceTranscriptLastChanged: TimeInterval,
                      hasTranscriptText: Bool) -> Bool {
        if secondsSinceRelease >= maximumWaitAfterReleaseSeconds { return true }
        guard hasTranscriptText, secondsSinceRelease >= minimumWaitAfterReleaseSeconds else { return false }
        return secondsSinceTranscriptLastChanged >= requiredStableDurationSeconds
    }
}
