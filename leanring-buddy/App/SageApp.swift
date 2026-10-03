//
//  SageApp.swift
//  Sage
//
//  Menu bar-only app entry point. No dock icon and no main window: Sage lives
//  in the menu bar (LSUIElement = true) and in a transparent overlay that
//  floats its cursor next to yours.
//

import AppKit
import SwiftUI

@main
struct SageApp: App {
    @NSApplicationDelegateAdaptor(SageAppDelegate.self) var appDelegate

    var body: some Scene {
        // SwiftUI requires at least one scene. This one is never shown because
        // LSUIElement removes the app menu; everything lives in the menu bar panel.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class SageAppDelegate: NSObject, NSApplicationDelegate {
    private let companionManager = CompanionManager()
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        print("🌿 Sage \(appVersion) starting")

        quitOlderCopiesOfSage()

        menuBarController = MenuBarController(companionManager: companionManager)
        companionManager.start()

        // Open the menu right away if there's setup left to do, so first-time
        // users immediately see what to grant instead of a silent menu bar icon.
        if companionManager.needsSetup {
            menuBarController?.showMenuOnLaunch()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Two copies of Sage fight over the microphone and the hotkey (both end
    /// up hearing nothing). This happens easily while developing, when an old
    /// copy is still running and Xcode launches a new one, so the newest
    /// copy always wins and asks the others to quit.
    private func quitOlderCopiesOfSage() {
        guard let sageBundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier

        let olderSageCopies = NSRunningApplication.runningApplications(withBundleIdentifier: sageBundleIdentifier)
            .filter { runningCopy in runningCopy.processIdentifier != currentProcessIdentifier }

        for olderSageCopy in olderSageCopies {
            print("🌿 Sage: quitting an older running copy (pid \(olderSageCopy.processIdentifier))")
            olderSageCopy.terminate()
        }
    }
}
