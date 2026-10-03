//
//  GlobalPushToTalkShortcutMonitor.swift
//  Sage
//
//  Watches for the push-to-talk shortcut (control + option) system-wide,
//  even while another app is focused.
//
//  Two detectors feed the same pressed/released state:
//    1. A listen-only CGEvent tap. Most reliable for modifier-only shortcuts
//       while the app is in the background.
//    2. An AppKit global + local flagsChanged monitor, as a backup in case
//       macOS refuses the event tap (for example right after a rebuild,
//       before permissions have caught up).
//  Because both update one shared state, a key change seen by both is only
//  reported once.
//
//  Requires Accessibility (and on some macOS versions, Input Monitoring).
//

import AppKit
import Combine
import CoreGraphics
import Foundation
import os

enum PushToTalkShortcutTransition {
    case pressed
    case released
}

@MainActor
final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    /// Shown in the UI wherever the shortcut is mentioned.
    static let shortcutDisplayText = "Control + Option"

    /// Modifier-only so holding it never types a character into the focused app.
    private static let shortcutEventTapFlags: CGEventFlags = [.maskControl, .maskAlternate]
    private static let shortcutAppKitFlags: NSEvent.ModifierFlags = [.control, .option]

    let shortcutTransitionPublisher = PassthroughSubject<PushToTalkShortcutTransition, Never>()

    /// True once the CGEvent tap is installed and listening.
    var isEventTapRunning: Bool { globalEventTap != nil }

    private let logger = Logger(subsystem: "com.kesideonyeocha.sage", category: "shortcut")

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    private var appKitGlobalFlagsMonitor: Any?
    private var appKitLocalFlagsMonitor: Any?
    private var hasRequestedInputMonitoringAccess = false
    /// Shared by both detectors so each press is reported exactly once.
    private var isShortcutCurrentlyPressed = false

    /// Installs whichever detectors aren't running yet. Safe to call repeatedly;
    /// the companion calls it on every permission check until the tap succeeds.
    func start() {
        installAppKitMonitorsIfNeeded()
        installEventTapIfNeeded()
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }
        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
        if let appKitGlobalFlagsMonitor {
            NSEvent.removeMonitor(appKitGlobalFlagsMonitor)
            self.appKitGlobalFlagsMonitor = nil
        }
        if let appKitLocalFlagsMonitor {
            NSEvent.removeMonitor(appKitLocalFlagsMonitor)
            self.appKitLocalFlagsMonitor = nil
        }
    }

    // MARK: - Detector 1: CGEvent Tap

    private func installEventTapIfNeeded() {
        guard globalEventTap == nil else { return }

        let eventMask = CGEventMask(1) << CGEventType.flagsChanged.rawValue

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let shortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return shortcutMonitor.handleGlobalEventTap(eventType: eventType, event: event)
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            let hasInputMonitoringAccess = CGPreflightListenEventAccess()
            logger.error("Event tap refused. accessibility=\(AXIsProcessTrusted(), privacy: .public) inputMonitoring=\(hasInputMonitoringAccess, privacy: .public)")

            // Some macOS versions want Input Monitoring for keyboard taps.
            // Ask once per launch; the system shows its own prompt.
            if !hasInputMonitoringAccess && !hasRequestedInputMonitoringAccess {
                hasRequestedInputMonitoringAccess = true
                _ = CGRequestListenEventAccess()
            }
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, globalEventTap, 0) else {
            CFMachPortInvalidate(globalEventTap)
            logger.error("Couldn't create the event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
        logger.notice("Event tap installed")
    }

    private func handleGlobalEventTap(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables slow taps. Turn it straight back on.
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            logger.notice("Event tap was disabled by macOS, re-enabling")
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if eventType == .flagsChanged {
            updateShortcutState(isShortcutPressedNow: event.flags.contains(Self.shortcutEventTapFlags), detectorName: "event tap")
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Detector 2: AppKit Monitors

    private func installAppKitMonitorsIfNeeded() {
        if appKitGlobalFlagsMonitor == nil {
            // Sees modifier changes while other apps are focused.
            appKitGlobalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] flagsChangedEvent in
                let isShortcutPressedNow = flagsChangedEvent.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .contains(Self.shortcutAppKitFlags)
                Task { @MainActor [weak self] in
                    self?.updateShortcutState(isShortcutPressedNow: isShortcutPressedNow, detectorName: "appkit global")
                }
            }
        }

        if appKitLocalFlagsMonitor == nil {
            // Global monitors skip events sent to Sage itself (for example
            // while the menu bar panel is focused), so watch those too.
            appKitLocalFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] flagsChangedEvent in
                let isShortcutPressedNow = flagsChangedEvent.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .contains(Self.shortcutAppKitFlags)
                Task { @MainActor [weak self] in
                    self?.updateShortcutState(isShortcutPressedNow: isShortcutPressedNow, detectorName: "appkit local")
                }
                return flagsChangedEvent
            }
        }
    }

    // MARK: - Shared State

    private func updateShortcutState(isShortcutPressedNow: Bool, detectorName: String) {
        // The AppKit monitors are only a fallback. Their events arrive a beat
        // later than the event tap's, so if both were used, a late "pressed"
        // could land after the tap's "released" and flip the state back on,
        // cutting a recording short. Once the tap is running, it alone decides.
        let isFromAppKitBackup = detectorName.hasPrefix("appkit")
        if isFromAppKitBackup && isEventTapRunning {
            return
        }

        if isShortcutPressedNow && !isShortcutCurrentlyPressed {
            isShortcutCurrentlyPressed = true
            logger.notice("Shortcut pressed (via \(detectorName, privacy: .public))")
            shortcutTransitionPublisher.send(.pressed)
        } else if !isShortcutPressedNow && isShortcutCurrentlyPressed {
            isShortcutCurrentlyPressed = false
            logger.notice("Shortcut released (via \(detectorName, privacy: .public))")
            shortcutTransitionPublisher.send(.released)
        }
    }
}
