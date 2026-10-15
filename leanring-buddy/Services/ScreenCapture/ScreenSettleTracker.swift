//
//  ScreenSettleTracker.swift
//  Sage
//
//  Decides when the screen has finished reacting to the user's action, from
//  a stream of thumbnail comparisons. Two things must be true before Sage
//  looks again:
//
//    1. Something visibly changed compared with just before the action.
//       Without this, a page that takes half a second to start loading looks
//       "settled" on the old page and Sage describes the wrong screen.
//    2. The screen has then held still for a moment.
//
//  If nothing visible changes at all (the click did something subtle), Sage
//  looks anyway after a short wait, and never waits past a hard maximum
//  (spinners and videos never hold still).
//

import Foundation

struct ScreenSettleTracker {
    struct Policy {
        /// How long consecutive thumbnails must match to count as settled.
        var requiredStableDurationSeconds: TimeInterval = 0.25
        /// With no visible change by now, the action did nothing big; look anyway.
        var maximumWaitForVisibleChangeSeconds: TimeInterval = 1.2
        var maximumWaitSeconds: TimeInterval = 4.0
        /// Below this average difference (0–255 per pixel) two thumbnails
        /// count as the same. High enough to ignore a blinking text cursor or
        /// a ticking clock, low enough to notice a menu opening.
        var unchangedDifferenceThreshold: Double = 1.5
    }

    let policy: Policy
    private(set) var hasSeenVisibleChange: Bool
    private var stableSinceSeconds: TimeInterval?
    private var previousSampleSeconds: TimeInterval?

    /// - `hasBaseline`: false when there's no "before" thumbnail to compare
    ///   against; then any stable screen counts, as before this tracker existed.
    init(policy: Policy = Policy(), hasBaseline: Bool) {
        self.policy = policy
        self.hasSeenVisibleChange = !hasBaseline
    }

    /// Feeds one sample. Differences are nil when a thumbnail couldn't be
    /// captured. Returns true once Sage should look again.
    mutating func observe(secondsSinceActivity: TimeInterval,
                          differenceFromPrevious: Double?,
                          differenceFromBaseline: Double?) -> Bool {
        defer { previousSampleSeconds = secondsSinceActivity }

        if let differenceFromBaseline, differenceFromBaseline >= policy.unchangedDifferenceThreshold {
            hasSeenVisibleChange = true
        }
        if let differenceFromPrevious, differenceFromPrevious < policy.unchangedDifferenceThreshold {
            stableSinceSeconds = stableSinceSeconds ?? previousSampleSeconds ?? secondsSinceActivity
        } else {
            stableSinceSeconds = nil
        }

        if secondsSinceActivity >= policy.maximumWaitSeconds { return true }
        guard let stableSinceSeconds,
              secondsSinceActivity - stableSinceSeconds >= policy.requiredStableDurationSeconds else { return false }
        return hasSeenVisibleChange || secondsSinceActivity >= policy.maximumWaitForVisibleChangeSeconds
    }
}
