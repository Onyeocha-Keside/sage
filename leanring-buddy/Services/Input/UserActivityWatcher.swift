//
//  UserActivityWatcher.swift
//  Sage
//
//  Powers follow-along mode. After Sage tells you to click something, this
//  watches for you to actually do it (a click, typing, or scrolling) anywhere
//  on the Mac. It reports the very first action instantly, so Sage can react
//  right away, then reports again once the screen has finished changing
//  (a menu opened, a page loaded), so Sage looks at the finished result.
//
//  Only the fact that you clicked, typed, or scrolled is noticed. Nothing
//  about what you typed or where you clicked is recorded.
//

import AppKit
import Foundation

@MainActor
final class UserActivityWatcher {
    /// After a click or scroll, start sampling almost at once. The settle
    /// tracker waits for a visible change, so looking early is safe.
    private static let minimumQuietAfterClickSeconds: TimeInterval = 0.1
    /// Typing gets a longer pause so Sage doesn't look mid-word.
    private static let minimumQuietAfterTypingSeconds: TimeInterval = 1.2
    /// How often to compare thumbnails while waiting for the screen to settle.
    private static let settleCheckIntervalSeconds: TimeInterval = 0.1
    /// Follow-along ends quietly if you don't do anything for this long.
    private static let idleTimeoutSeconds: TimeInterval = 120

    private static let watchedEvents: NSEvent.EventTypeMask = [
        .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel
    ]

    private var globalActivityMonitor: Any?
    private var localActivityMonitor: Any?
    private var idleTimeoutTimer: Timer?
    private var settleDetectionTask: Task<Void, Never>?
    private var hasSeenFirstActivity = false
    /// The most recent thumbnail: taken when watching starts, then updated by
    /// every settle check. It's the "before" picture for the next action.
    private var latestThumbnail: ScreenThumbnail?
    private var baselineCaptureTask: Task<Void, Never>?
    private var onFirstActivity: ((_ wasScrolling: Bool) -> Void)?
    private var onScreenSettled: ((_ settledThumbnail: ScreenThumbnail?) -> Void)?
    private var onIdleTimeout: (() -> Void)?

    var isWatching: Bool { globalActivityMonitor != nil }

    /// Starts watching.
    /// - `onFirstActivity`: the instant the user first clicks, types, or scrolls,
    ///   and whether it was a scroll (the pointed-at element may still be there).
    /// - `onScreenSettled`: once, after that activity has finished changing the
    ///   screen, with the last thumbnail (what the settled screen looks like).
    /// - `onIdleTimeout`: if the user does nothing at all for two minutes.
    func startWatching(
        onFirstActivity: @escaping (_ wasScrolling: Bool) -> Void,
        onScreenSettled: @escaping (_ settledThumbnail: ScreenThumbnail?) -> Void,
        onIdleTimeout: @escaping () -> Void
    ) {
        stopWatching()
        self.onFirstActivity = onFirstActivity
        self.onScreenSettled = onScreenSettled
        self.onIdleTimeout = onIdleTimeout

        baselineCaptureTask = Task { [weak self] in
            let baselineThumbnail = await ScreenChangeDetector.captureThumbnailOfDisplayUnderMouse()
            guard let self, !Task.isCancelled, self.latestThumbnail == nil else { return }
            self.latestThumbnail = baselineThumbnail
        }

        globalActivityMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.watchedEvents) { [weak self] activityEvent in
            let wasTyping = activityEvent.type == .keyDown
            let wasScrolling = activityEvent.type == .scrollWheel
            Task { @MainActor [weak self] in
                self?.handleUserActivity(wasTyping: wasTyping, wasScrolling: wasScrolling)
            }
        }
        // Global monitors skip events aimed at Sage itself, so watch those too.
        localActivityMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.watchedEvents) { [weak self] activityEvent in
            let wasTyping = activityEvent.type == .keyDown
            let wasScrolling = activityEvent.type == .scrollWheel
            Task { @MainActor [weak self] in
                self?.handleUserActivity(wasTyping: wasTyping, wasScrolling: wasScrolling)
            }
            return activityEvent
        }

        idleTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Self.idleTimeoutSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let idleTimeoutCallback = self.onIdleTimeout
                self.stopWatching()
                idleTimeoutCallback?()
            }
        }
    }

    /// Sage looked too early: the screen kept changing afterwards. Watches
    /// again as if the user had just clicked, with the screen Sage already
    /// looked at as the "before" picture, so it waits for the change to finish.
    func restartSettleCheck(
        comparedWith alreadySeenThumbnail: ScreenThumbnail?,
        onScreenSettled: @escaping (_ settledThumbnail: ScreenThumbnail?) -> Void,
        onIdleTimeout: @escaping () -> Void
    ) {
        startWatching(onFirstActivity: { _ in }, onScreenSettled: onScreenSettled, onIdleTimeout: onIdleTimeout)
        baselineCaptureTask?.cancel()
        baselineCaptureTask = nil
        latestThumbnail = alreadySeenThumbnail
        hasSeenFirstActivity = true
        handleUserActivity(wasTyping: false, wasScrolling: false)
    }

    func stopWatching() {
        if let globalActivityMonitor {
            NSEvent.removeMonitor(globalActivityMonitor)
            self.globalActivityMonitor = nil
        }
        if let localActivityMonitor {
            NSEvent.removeMonitor(localActivityMonitor)
            self.localActivityMonitor = nil
        }
        idleTimeoutTimer?.invalidate()
        idleTimeoutTimer = nil
        settleDetectionTask?.cancel()
        settleDetectionTask = nil
        baselineCaptureTask?.cancel()
        baselineCaptureTask = nil
        latestThumbnail = nil
        hasSeenFirstActivity = false
        onFirstActivity = nil
        onScreenSettled = nil
        onIdleTimeout = nil
    }

    /// Every click, key, or scroll restarts the settle check, so typing a
    /// search term or clicking through a menu counts as one action.
    private func handleUserActivity(wasTyping: Bool, wasScrolling: Bool) {
        guard isWatching else { return }

        idleTimeoutTimer?.invalidate()
        idleTimeoutTimer = nil

        if !hasSeenFirstActivity {
            hasSeenFirstActivity = true
            onFirstActivity?(wasScrolling)
        }

        let minimumQuietSeconds = wasTyping ? Self.minimumQuietAfterTypingSeconds : Self.minimumQuietAfterClickSeconds
        let baselineThumbnail = latestThumbnail
        settleDetectionTask?.cancel()
        settleDetectionTask = Task { [weak self] in
            guard let didSettle = await self?.waitForScreenToSettle(minimumQuietSeconds: minimumQuietSeconds,
                                                                    baselineThumbnail: baselineThumbnail),
                  didSettle, !Task.isCancelled, let self else { return }
            let screenSettledCallback = self.onScreenSettled
            let settledThumbnail = self.latestThumbnail
            self.stopWatching()
            screenSettledCallback?(settledThumbnail)
        }
    }

    /// Waits for the minimum quiet time, then samples thumbnails until the
    /// settle tracker says the screen has visibly changed and held still (or
    /// the maximum wait passes). Returns false if cancelled because the user
    /// did something else in the meantime.
    private func waitForScreenToSettle(minimumQuietSeconds: TimeInterval, baselineThumbnail: ScreenThumbnail?) async -> Bool {
        let activityInstant = ContinuousClock.now

        do {
            try await Task.sleep(for: .seconds(minimumQuietSeconds))
        } catch {
            return false
        }

        let thumbnailCapturer = await ScreenChangeDetector.makeThumbnailCapturerForDisplayUnderMouse()
        var settleTracker = ScreenSettleTracker(hasBaseline: baselineThumbnail != nil)
        var previousThumbnail: ScreenThumbnail?
        while !Task.isCancelled {
            let currentThumbnail = await thumbnailCapturer?.capture()
            if let currentThumbnail {
                latestThumbnail = currentThumbnail
            }
            let elapsed = ContinuousClock.now - activityInstant
            let hasSettled = settleTracker.observe(
                secondsSinceActivity: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                differenceFromPrevious: currentThumbnail.flatMap { current in previousThumbnail.map { current.averageDifference(from: $0) } },
                differenceFromBaseline: currentThumbnail.flatMap { current in baselineThumbnail.map { current.averageDifference(from: $0) } }
            )
            if hasSettled {
                return true
            }
            previousThumbnail = currentThumbnail

            do {
                try await Task.sleep(for: .seconds(Self.settleCheckIntervalSeconds))
            } catch {
                return false
            }
        }
        return false
    }
}
