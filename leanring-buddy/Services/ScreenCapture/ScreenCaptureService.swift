//
//  ScreenCaptureService.swift
//  Sage
//
//  Captures every connected display as a JPEG with ScreenCaptureKit,
//  labeled so Claude knows which screen the user's cursor is on.
//

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// One display's screenshot plus the geometry needed to map Claude's
/// pixel coordinates back onto the real screen.
struct CapturedScreen {
    let jpegData: Data
    /// Text sent to Claude alongside the image, including its pixel size.
    let labelForClaude: String
    let isCursorScreen: Bool
    /// The display's frame in AppKit global coordinates (bottom-left origin).
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

struct ScreenCaptureFailure: LocalizedError {
    let underlyingDescription: String
    var errorDescription: String? { "Couldn't capture the screen: \(underlyingDescription)" }
}

enum ScreenCaptureService {
    /// Screenshots are scaled so their longest side is this many pixels. Big
    /// enough for Claude to read UI text, small enough to upload quickly.
    private static let maximumScreenshotDimension = 1280
    /// Slightly compressed to keep uploads quick on slow Wi-Fi. UI text stays readable.
    private static let jpegCompressionFactor = 0.72

    /// Captures all displays, cursor screen first. Sage's own windows (the
    /// overlay and the menu bar panel) are excluded so Claude sees only the
    /// user's content.
    static func captureScreens(onlyCursorScreen: Bool = false) async throws -> [CapturedScreen] {
        let shareableContent: SCShareableContent
        do {
            shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCaptureFailure(underlyingDescription: error.localizedDescription)
        }

        guard !shareableContent.displays.isEmpty else {
            throw ScreenCaptureFailure(underlyingDescription: "no displays available")
        }

        let mouseLocation = NSEvent.mouseLocation
        let sageBundleIdentifier = Bundle.main.bundleIdentifier
        let sageOwnWindows = shareableContent.windows.filter { window in
            window.owningApplication?.bundleIdentifier == sageBundleIdentifier
        }

        // SCDisplay.frame uses top-left-origin coordinates, but the mouse location and
        // the overlay windows use AppKit's bottom-left origin. Look up each display's
        // NSScreen so every frame we hand out is in AppKit coordinates.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[displayID] = screen
            }
        }

        func appKitFrame(for display: SCDisplay) -> CGRect {
            nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
        }

        let orderedDisplays = shareableContent.displays.filter { nsScreenByDisplayID[$0.displayID] != nil }.sorted { firstDisplay, secondDisplay in
            let firstContainsCursor = appKitFrame(for: firstDisplay).contains(mouseLocation)
            let secondContainsCursor = appKitFrame(for: secondDisplay).contains(mouseLocation)
            return firstContainsCursor && !secondContainsCursor
        }

        // Match the Worker image limit before doing expensive capture work.
        let displaysWithCursorScreenFirst = Array(orderedDisplays.prefix(onlyCursorScreen ? 1 : 4))
        var capturedScreens: [CapturedScreen] = []

        for (displayIndex, display) in displaysWithCursorScreenFirst.enumerated() {
            try Task.checkCancellation()
            let displayFrame = appKitFrame(for: display)
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let streamConfiguration = SCStreamConfiguration()
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                streamConfiguration.width = maximumScreenshotDimension
                streamConfiguration.height = max(1, Int(CGFloat(maximumScreenshotDimension) / aspectRatio))
            } else {
                streamConfiguration.height = maximumScreenshotDimension
                streamConfiguration.width = max(1, Int(CGFloat(maximumScreenshotDimension) * aspectRatio))
            }

            let screenshotImage: CGImage
            do {
                screenshotImage = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, excludingWindows: sageOwnWindows),
                    configuration: streamConfiguration
                )
            } catch {
                throw ScreenCaptureFailure(underlyingDescription: error.localizedDescription)
            }

            guard let jpegData = NSBitmapImageRep(cgImage: screenshotImage)
                .representation(using: .jpeg, properties: [.compressionFactor: jpegCompressionFactor]) else {
                throw ScreenCaptureFailure(underlyingDescription: "could not encode display screenshot")
            }

            let screenDescription: String
            if displaysWithCursorScreenFirst.count == 1 {
                screenDescription = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenDescription = "screen \(displayIndex + 1) of \(displaysWithCursorScreenFirst.count) — cursor is on this screen (primary focus)"
            } else {
                screenDescription = "screen \(displayIndex + 1) of \(displaysWithCursorScreenFirst.count) — secondary screen"
            }
            let dimensionsDescription = "(image dimensions: \(streamConfiguration.width)x\(streamConfiguration.height) pixels)"

            capturedScreens.append(CapturedScreen(
                jpegData: jpegData,
                labelForClaude: "\(screenDescription) \(dimensionsDescription)",
                isCursorScreen: isCursorScreen,
                displayFrame: displayFrame,
                screenshotWidthInPixels: streamConfiguration.width,
                screenshotHeightInPixels: streamConfiguration.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw ScreenCaptureFailure(underlyingDescription: "every display failed to capture")
        }
        return capturedScreens
    }
}
