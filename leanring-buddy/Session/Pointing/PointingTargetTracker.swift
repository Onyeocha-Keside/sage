//
//  PointingTargetTracker.swift
//  Sage
//
//  Keeps pointing targets on the content they belong to. Claude's
//  coordinates come from a screenshot that can be several seconds old by the
//  time the sentence about that element plays, and the user may have
//  scrolled in between, or keep scrolling while Sage points. In order of
//  trust, a target's live position comes from:
//
//    1. the control itself, through Accessibility (exact, even mid-scroll)
//    2. the original position shifted by the scrolling over its window
//       (exact for trackpads, a guess for line-based mouse wheels)
//
//  When the only answer is a guess, the target is dropped: not pointing is
//  better than confidently pointing at the wrong thing.
//

import AppKit
import Foundation

@MainActor
final class PointingTargetTracker {
    private struct TrackedTarget {
        /// Where the screenshot showed it. Updates are always computed from
        /// here, never from an already-moved copy, so shifts can't add up twice.
        let screenshotLocation: CGPoint
        let anchor: AccessibilityElementAnchor?
        /// Where scrolling moves this target's content: its window, if any.
        let scrollRegion: CGRect?
        /// Where the target counts as visible when there's no live scroll area.
        let fallbackVisibleRegion: CGRect
    }

    /// While scrolling, refresh at most this often. Accessibility reads are
    /// quick but not free, and the eye can't tell the difference past this.
    private static let liveRefreshIntervalSeconds: TimeInterval = 1.0 / 30.0
    /// Browsers update control positions after layout, so check once more
    /// shortly after scrolling stops.
    private static let trailingRefreshDelaySeconds: TimeInterval = 0.15

    private let scrollActivityLog = ScrollActivityLog()
    private var trackedTargetsByID: [UUID: TrackedTarget] = [:]
    private var pendingLiveRefresh: DispatchWorkItem?
    private var pendingTrailingRefresh: DispatchWorkItem?
    private var lastLiveRefreshUptime: TimeInterval = 0

    /// Called (throttled) while content under the screen is scrolling, so the
    /// owner can move whatever target is currently shown.
    var onContentScrolled: (() -> Void)?

    func start() {
        scrollActivityLog.onScroll = { [weak self] in self?.scheduleRefresh() }
        scrollActivityLog.start()
    }

    func stop() {
        scrollActivityLog.stop()
        forgetAllTargets()
    }

    /// Starts tracking a freshly resolved target. Call as soon as Claude's
    /// tag arrives: the sooner it's anchored, the less can have changed.
    func beginTracking(_ target: PointingTarget) {
        let window = WindowUnderPoint.topmostWindow(at: target.globalScreenLocation)
        let scrollRegion = window?.bounds
        var anchoringLocation = target.globalScreenLocation
        var canAnchorToControl = true

        // If the content already scrolled since the screenshot, the control
        // now at the original spot is a different one. Look where the
        // original content moved to instead, and only if that's exact.
        if let scrollRegion {
            let (shift, hasImpreciseMovement) = PointingTargetGeometry.contentShift(
                from: scrollActivityLog.movements, after: target.screenshotCaptureUptime, within: scrollRegion)
            anchoringLocation.x += shift.dx
            anchoringLocation.y += shift.dy
            canAnchorToControl = !hasImpreciseMovement && scrollRegion.contains(anchoringLocation)
        }

        let anchor = (canAnchorToControl ? window : nil).flatMap { AccessibilityElementAnchor.make(at: anchoringLocation, in: $0) }
        trackedTargetsByID[target.id] = TrackedTarget(
            screenshotLocation: target.globalScreenLocation,
            anchor: anchor,
            scrollRegion: scrollRegion,
            fallbackVisibleRegion: scrollRegion.map { $0.intersection(target.displayFrame) } ?? target.displayFrame
        )
    }

    /// Where `target` is right now. Returns the same target (same ID) at its
    /// live position, marked off-screen if it scrolled out of view, or nil if
    /// Sage can no longer tell where it is.
    func currentPlacement(of target: PointingTarget) -> PointingTarget? {
        guard let trackedTarget = trackedTargetsByID[target.id] else { return target }

        if let anchor = trackedTarget.anchor, let liveLocation = anchor.currentLocation() {
            let visibleRegion = (anchor.currentVisibleRegion() ?? trackedTarget.fallbackVisibleRegion).intersection(target.displayFrame)
            let placement = PointingTargetGeometry.placement(of: liveLocation, within: visibleRegion)
            return target.moved(to: placement.location, offScreenEdge: placement.offScreenEdge)
        }

        // No live control: shift the original screenshot position by the scrolling since.
        guard let scrollRegion = trackedTarget.scrollRegion else { return target }
        let (shift, hasImpreciseMovement) = PointingTargetGeometry.contentShift(
            from: scrollActivityLog.movements, after: target.screenshotCaptureUptime, within: scrollRegion)
        if shift == .zero { return target.moved(to: trackedTarget.screenshotLocation, offScreenEdge: nil) }
        if hasImpreciseMovement { return nil }
        let shiftedLocation = CGPoint(x: trackedTarget.screenshotLocation.x + shift.dx, y: trackedTarget.screenshotLocation.y + shift.dy)
        let placement = PointingTargetGeometry.placement(of: shiftedLocation, within: trackedTarget.fallbackVisibleRegion)
        return target.moved(to: placement.location, offScreenEdge: placement.offScreenEdge)
    }

    func forgetAllTargets() {
        trackedTargetsByID.removeAll()
        pendingLiveRefresh?.cancel()
        pendingLiveRefresh = nil
        pendingTrailingRefresh?.cancel()
        pendingTrailingRefresh = nil
    }

    // MARK: - Live Refresh

    private func scheduleRefresh() {
        guard !trackedTargetsByID.isEmpty else { return }

        if pendingLiveRefresh == nil {
            let secondsSinceLastRefresh = ProcessInfo.processInfo.systemUptime - lastLiveRefreshUptime
            let delaySeconds = max(0, Self.liveRefreshIntervalSeconds - secondsSinceLastRefresh)
            let liveRefresh = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingLiveRefresh = nil
                self.lastLiveRefreshUptime = ProcessInfo.processInfo.systemUptime
                self.onContentScrolled?()
            }
            pendingLiveRefresh = liveRefresh
            DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds, execute: liveRefresh)
        }

        pendingTrailingRefresh?.cancel()
        let trailingRefresh = DispatchWorkItem { [weak self] in
            self?.pendingTrailingRefresh = nil
            self?.onContentScrolled?()
        }
        pendingTrailingRefresh = trailingRefresh
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.trailingRefreshDelaySeconds, execute: trailingRefresh)
    }
}
