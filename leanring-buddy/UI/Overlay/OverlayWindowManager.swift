//
//  OverlayWindowManager.swift
//  Sage
//
//  Sage's cursor lives in a transparent, click-through window that covers
//  each screen. One window per display lets the cursor follow you across
//  monitors and fly to elements on any of them.
//

import AppKit
import SwiftUI

/// A full-screen, transparent, click-through window that never takes focus.
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above menus and popups so the cursor is never hidden behind them.
        level = .screenSaver
        // Clicks pass straight through to the apps underneath.
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []

    /// Creates a fresh overlay on every screen. `isFirstAppearance` plays the
    /// "hey, i'm sage" intro on whichever screen the mouse is on.
    func showOverlay(onScreens screens: [NSScreen], isFirstAppearance: Bool, companionManager: CompanionManager) {
        hideOverlay()

        for screen in screens {
            let overlayWindow = OverlayWindow(screen: screen)
            let cursorHostingView = NSHostingView(rootView: SageCursorView(
                screenFrame: screen.frame,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager
            ))
            cursorHostingView.frame = screen.frame
            overlayWindow.contentView = cursorHostingView

            overlayWindows.append(overlayWindow)
            overlayWindow.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for overlayWindow in overlayWindows {
            overlayWindow.orderOut(nil)
            overlayWindow.contentView = nil
        }
        overlayWindows.removeAll()
    }
}
