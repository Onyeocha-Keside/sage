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
    /// After a click or scroll, wait at least this long before checking
    /// whether the screen has settled.
    private static let minimumQuietAfterClickSeconds: TimeInterval = 0.35
    /// Typing gets a longer pause so Sage doesn't look mid-word.
    private static let minimumQuietAfterTypingSeconds: TimeInterval = 1.2
    /// How often to compare thumbnails while waiting for the screen to settle.
    private static let settleCheckIntervalSeconds: TimeInterval = 0.25
    /// Pages with spinners or videos never fully stop changing. Look anyway after this.
    private static let maximumSettleWaitSeconds: TimeInterval = 4.0
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
    private var onFirstActivity: (() -> Void)?
    private var onScreenSettled: (() -> Void)?
    private var onIdleTimeout: (() -> Void)?

    var isWatching: Bool { globalActivityMonitor != nil }

    /// Starts watching.
    /// - `onFirstActivity`: the instant the user first clicks, types, or scrolls.
    /// - `onScreenSettled`: once, after that activity has finished changing the screen.
    /// - `onIdleTimeout`: if the user does nothing at all for two minutes.
    func startWatching(
        onFirstActivity: @escaping () -> Void,
        onScreenSettled: @escaping () -> Void,
        onIdleTimeout: @escaping () -> Void
    ) {
        stopWatching()
        self.onFirstActivity = onFirstActivity
        self.onScreenSettled = onScreenSettled
        self.onIdleTimeout = onIdleTimeout

        globalActivityMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.watchedEvents) { [weak self] activityEvent in
            let wasTyping = activityEvent.type == .keyDown
            Task { @MainActor [weak self] in
                self?.handleUserActivity(wasTyping: wasTyping)
            }
        }
        // Global monitors skip events aimed at Sage itself, so watch those too.
        localActivityMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.watchedEvents) { [weak self] activityEvent in
            let wasTyping = activityEvent.type == .keyDown
            Task { @MainActor [weak self] in
                self?.handleUserActivity(wasTyping: wasTyping)
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
        hasSeenFirstActivity = false
        onFirstActivity = nil
        onScreenSettled = nil
        onIdleTimeout = nil
    }

    /// Every click, key, or scroll restarts the settle check, so typing a
    /// search term or clicking through a menu counts as one action.
    private func handleUserActivity(wasTyping: Bool) {
        guard isWatching else { return }

        idleTimeoutTimer?.invalidate()
        idleTimeoutTimer = nil

        if !hasSeenFirstActivity {
            hasSeenFirstActivity = true
            onFirstActivity?()
        }

        let minimumQuietSeconds = wasTyping ? Self.minimumQuietAfterTypingSeconds : Self.minimumQuietAfterClickSeconds
        settleDetectionTask?.cancel()
        settleDetectionTask = Task { [weak self] in
            let didSettle = await Self.waitForScreenToSettle(minimumQuietSeconds: minimumQuietSeconds)
            guard didSettle, !Task.isCancelled, let self else { return }
            let screenSettledCallback = self.onScreenSettled
            self.stopWatching()
            screenSettledCallback?()
        }
    }

    /// Waits for the minimum quiet time, then compares thumbnails until two in
    /// a row match (or the maximum wait passes). Returns false if cancelled
    /// because the user did something else in the meantime.
    private static func waitForScreenToSettle(minimumQuietSeconds: TimeInterval) async -> Bool {
        let settleStartDate = Date()

        do {
            try await Task.sleep(for: .seconds(minimumQuietSeconds))
        } catch {
            return false
        }

        var previousThumbnail: ScreenThumbnail?
        while !Task.isCancelled {
            let currentThumbnail = await ScreenChangeDetector.captureThumbnailOfDisplayUnderMouse()

            if let previousThumbnail, let currentThumbnail,
               currentThumbnail.averageDifference(from: previousThumbnail) < ScreenChangeDetector.unchangedDifferenceThreshold {
                return true
            }
            // Without thumbnails (capture failed) fall back to the time limit.
            if Date().timeIntervalSince(settleStartDate) >= maximumSettleWaitSeconds {
                return true
            }
            previousThumbnail = currentThumbnail

            do {
                try await Task.sleep(for: .seconds(settleCheckIntervalSeconds))
            } catch {
                return false
            }
        }
        return false
    }
}
