//
//  PermissionsCoordinator.swift
//  Sage
//
//  Tracks and requests the five macOS permissions Sage needs:
//  microphone, speech recognition, accessibility (for the global hotkey),
//  screen recording, and screen content (ScreenCaptureKit's own prompt).
//
//  Permissions are polled because macOS doesn't notify apps when the user
//  flips a switch in System Settings.
//

import AppKit
import ApplicationServices
import AVFoundation
import Combine
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Speech

@MainActor
final class PermissionsCoordinator: ObservableObject {
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasSpeechRecognitionPermission = false
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasScreenContentPermission = false
    @Published private(set) var isRequestingScreenContentPermission = false

    var allPermissionsGranted: Bool {
        hasMicrophonePermission
            && hasSpeechRecognitionPermission
            && hasAccessibilityPermission
            && hasScreenRecordingPermission
            && hasScreenContentPermission
    }

    /// Called whenever any permission flips, so the companion can react
    /// (start the hotkey monitor, show the cursor, and so on).
    var onPermissionsChanged: (() -> Void)?

    /// Called after every poll, changed or not. Used to retry things that
    /// can fail even with permission granted (like installing the hotkey tap).
    var onPermissionsChecked: (() -> Void)?

    private static let pollingIntervalSeconds: TimeInterval = 1.5
    private static let hasScreenContentPermissionDefaultsKey = "hasScreenContentPermission"

    private var permissionPollingTimer: Timer?

    // macOS only shows the accessibility and screen recording prompts once per
    // launch. After that, tapping "Grant" should open System Settings instead.
    private var hasShownAccessibilitySystemPrompt = false
    private var hasShownScreenRecordingSystemPrompt = false

    // MARK: - Monitoring

    func startMonitoring() {
        refreshAllPermissions()
        permissionPollingTimer?.invalidate()
        permissionPollingTimer = Timer.scheduledTimer(
            withTimeInterval: Self.pollingIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    func stopMonitoring() {
        permissionPollingTimer?.invalidate()
        permissionPollingTimer = nil
    }

    func refreshAllPermissions() {
        var didAnyPermissionChange = false

        // Only assign when the value actually changes, so SwiftUI doesn't
        // re-render the panel on every poll.
        func update(_ keyPath: ReferenceWritableKeyPath<PermissionsCoordinator, Bool>, to newValue: Bool) {
            guard self[keyPath: keyPath] != newValue else { return }
            self[keyPath: keyPath] = newValue
            didAnyPermissionChange = true
        }

        update(\.hasMicrophonePermission, to: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        update(\.hasSpeechRecognitionPermission, to: SFSpeechRecognizer.authorizationStatus() == .authorized)
        update(\.hasAccessibilityPermission, to: AXIsProcessTrusted())
        update(\.hasScreenRecordingPermission, to: CGPreflightScreenCaptureAccess())
        // Screen content approval can't be queried, so it's remembered once granted.
        update(\.hasScreenContentPermission, to: UserDefaults.standard.bool(forKey: Self.hasScreenContentPermissionDefaultsKey))

        if didAnyPermissionChange {
            print("🔑 Permissions — mic: \(hasMicrophonePermission), speech: \(hasSpeechRecognitionPermission), accessibility: \(hasAccessibilityPermission), screen recording: \(hasScreenRecordingPermission), screen content: \(hasScreenContentPermission)")
            onPermissionsChanged?()
        }
        onPermissionsChecked?()
    }

    // MARK: - Requests

    func requestMicrophonePermission() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            openPrivacySettings(paneIdentifier: "Privacy_Microphone")
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    func requestSpeechRecognitionPermission() {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else {
            openPrivacySettings(paneIdentifier: "Privacy_SpeechRecognition")
            return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    func requestAccessibilityPermission() {
        guard !hasShownAccessibilitySystemPrompt else {
            openPrivacySettings(paneIdentifier: "Privacy_Accessibility")
            return
        }
        hasShownAccessibilitySystemPrompt = true
        let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(promptOptions)
    }

    /// Dev builds sometimes don't show up in the Accessibility list on their own.
    /// Revealing the app in Finder lets the user drag it into the list manually.
    func revealAppInFinderForAccessibility() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        openPrivacySettings(paneIdentifier: "Privacy_Accessibility")
    }

    func requestScreenRecordingPermission() {
        guard !hasShownScreenRecordingSystemPrompt else {
            openPrivacySettings(paneIdentifier: "Privacy_ScreenCapture")
            return
        }
        hasShownScreenRecordingSystemPrompt = true
        _ = CGRequestScreenCaptureAccess()
    }

    /// Triggers ScreenCaptureKit's own approval prompt by taking a tiny throwaway
    /// screenshot. If a real image comes back, the user approved it.
    func requestScreenContentPermission() {
        guard !isRequestingScreenContentPermission else { return }
        isRequestingScreenContentPermission = true

        Task {
            defer { isRequestingScreenContentPermission = false }
            do {
                let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let firstDisplay = shareableContent.displays.first else { return }

                let contentFilter = SCContentFilter(display: firstDisplay, excludingWindows: [])
                let streamConfiguration = SCStreamConfiguration()
                streamConfiguration.width = 320
                streamConfiguration.height = 240

                let testScreenshot = try await SCScreenshotManager.captureImage(
                    contentFilter: contentFilter,
                    configuration: streamConfiguration
                )
                guard testScreenshot.width > 0 && testScreenshot.height > 0 else { return }

                UserDefaults.standard.set(true, forKey: Self.hasScreenContentPermissionDefaultsKey)
                refreshAllPermissions()
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
            }
        }
    }

    private func openPrivacySettings(paneIdentifier: String) {
        guard let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(paneIdentifier)") else {
            return
        }
        NSWorkspace.shared.open(settingsURL)
    }
}
