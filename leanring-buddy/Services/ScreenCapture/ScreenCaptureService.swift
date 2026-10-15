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
    /// Seconds since boot when the pixels were grabbed (the `NSEvent.timestamp`
    /// clock), so later scrolling can be matched against this screenshot.
    var captureUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    /// A close-up of the area the user circled, sent so Claude can read small
    /// text. It isn't a screen: it never counts as one for pointing.
    var isZoomedDetail = false
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
    /// With `circledArea`, only the screen holding the circle is captured. A
    /// red ring marks the circled area and everything outside it is dimmed,
    /// and a sharper close-up of the area goes first, so Claude focuses on
    /// exactly what the user meant.
    static func captureScreens(onlyCursorScreen: Bool = false, circledArea: CircledArea? = nil) async throws -> [CapturedScreen] {
        let shareableContent: SCShareableContent
        do {
            shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCaptureFailure(underlyingDescription: error.localizedDescription)
        }

        guard !shareableContent.displays.isEmpty else {
            throw ScreenCaptureFailure(underlyingDescription: "no displays available")
        }

        // The circle, when there is one, decides which screen matters most.
        let mouseLocation = circledArea?.center ?? NSEvent.mouseLocation
        let onlyCursorScreen = onlyCursorScreen || circledArea != nil
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

            var screenshotImage: CGImage
            let uptimeBeforeCapture = ProcessInfo.processInfo.systemUptime
            do {
                screenshotImage = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, excludingWindows: sageOwnWindows),
                    configuration: streamConfiguration
                )
            } catch {
                throw ScreenCaptureFailure(underlyingDescription: error.localizedDescription)
            }
            let uptimeAfterCapture = ProcessInfo.processInfo.systemUptime

            var circleDescription = ""
            if let circledArea, displayFrame.intersects(circledArea.focusRect) {
                screenshotImage = markFocusArea(circledArea.focusRect, on: screenshotImage, imageGlobalRect: displayFrame) ?? screenshotImage
                let pixelBounds = screenshotPixelRect(for: circledArea.focusRect, displayFrame: displayFrame,
                                                      screenshotWidth: streamConfiguration.width, screenshotHeight: streamConfiguration.height)
                circleDescription = " the user circled what they're asking about: it's inside the red ring, roughly x \(Int(pixelBounds.minX))–\(Int(pixelBounds.maxX)), y \(Int(pixelBounds.minY))–\(Int(pixelBounds.maxY)). the ring and the dimming outside it were added by sage to show their selection; they aren't part of the app."
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
                labelForClaude: "\(screenDescription) \(dimensionsDescription)\(circleDescription)",
                isCursorScreen: isCursorScreen,
                displayFrame: displayFrame,
                screenshotWidthInPixels: streamConfiguration.width,
                screenshotHeightInPixels: streamConfiguration.height,
                // The frame is grabbed somewhere during the call; the midpoint
                // keeps the error from scrolling mid-capture to half a call.
                captureUptime: (uptimeBeforeCapture + uptimeAfterCapture) / 2
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw ScreenCaptureFailure(underlyingDescription: "every display failed to capture")
        }
        if let circledArea, let circledScreen = capturedScreens.first, circledScreen.displayFrame.intersects(circledArea.focusRect),
           let circledDisplay = displaysWithCursorScreenFirst.first,
           let closeUp = try? await captureCloseUp(of: circledArea, display: circledDisplay, displayFrame: circledScreen.displayFrame,
                                                    excludingWindows: sageOwnWindows) {
            // First, so it's what Claude looks at before the wider context.
            capturedScreens.insert(closeUp, at: 0)
        }
        return capturedScreens
    }

    // MARK: - Circled Area

    /// Screenshot pixel rectangle (top-left origin) for an AppKit global rectangle.
    private static func screenshotPixelRect(for globalRect: CGRect, displayFrame: CGRect,
                                            screenshotWidth: Int, screenshotHeight: Int) -> CGRect {
        let horizontalScale = CGFloat(screenshotWidth) / displayFrame.width
        let verticalScale = CGFloat(screenshotHeight) / displayFrame.height
        return CGRect(x: (globalRect.minX - displayFrame.minX) * horizontalScale,
                      y: (displayFrame.maxY - globalRect.maxY) * verticalScale,
                      width: globalRect.width * horizontalScale,
                      height: globalRect.height * verticalScale)
    }

    /// Marks the user's selection on a captured image: everything outside the
    /// ring is dimmed and the ring is drawn in red. The on-screen overlay is
    /// excluded from capture, so Claude would otherwise never see the circle.
    /// `imageGlobalRect` is the part of the screen the image shows (AppKit coordinates).
    static func markFocusArea(_ focusRect: CGRect, on image: CGImage, imageGlobalRect: CGRect) -> CGImage? {
        guard let drawingContext = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        drawingContext.draw(image, in: imageRect)

        // CGContext has a bottom-left origin like AppKit, so only scaling and offset are needed.
        let horizontalScale = CGFloat(image.width) / imageGlobalRect.width
        let verticalScale = CGFloat(image.height) / imageGlobalRect.height
        let ringRect = CGRect(x: (focusRect.minX - imageGlobalRect.minX) * horizontalScale,
                              y: (focusRect.minY - imageGlobalRect.minY) * verticalScale,
                              width: focusRect.width * horizontalScale,
                              height: focusRect.height * verticalScale)

        // Dim around the ring (even-odd: the ellipse is cut out of the full rectangle).
        drawingContext.addRect(imageRect)
        drawingContext.addEllipse(in: ringRect)
        drawingContext.setFillColor(CGColor(gray: 0, alpha: 0.35))
        drawingContext.fillPath(using: .evenOdd)

        drawingContext.addEllipse(in: ringRect)
        drawingContext.setStrokeColor(CGColor(red: 1, green: 0.15, blue: 0.2, alpha: 0.95))
        drawingContext.setLineWidth(max(3, CGFloat(image.width) / 400))
        drawingContext.strokePath()
        return drawingContext.makeImage()
    }

    /// A sharper capture of just the circled area (with some margin), up to
    /// 1280 pixels on its longest side.
    private static func captureCloseUp(of circledArea: CircledArea, display: SCDisplay, displayFrame: CGRect,
                                       excludingWindows sageOwnWindows: [SCWindow]) async throws -> CapturedScreen? {
        let focusRect = circledArea.focusRect
        let margin = max(40, max(focusRect.width, focusRect.height) * 0.25)
        let globalCloseUpRect = focusRect.insetBy(dx: -margin, dy: -margin).intersection(displayFrame)
        guard !globalCloseUpRect.isEmpty else { return nil }

        // sourceRect is in display points with a top-left origin.
        let sourceRect = CGRect(x: globalCloseUpRect.minX - displayFrame.minX,
                                y: displayFrame.maxY - globalCloseUpRect.maxY,
                                width: globalCloseUpRect.width, height: globalCloseUpRect.height)
        // Retina detail where it helps, never bigger than a normal screenshot.
        let pixelScale = min(2, CGFloat(maximumScreenshotDimension) / max(sourceRect.width, sourceRect.height))
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.sourceRect = sourceRect
        streamConfiguration.width = max(1, Int(sourceRect.width * pixelScale))
        streamConfiguration.height = max(1, Int(sourceRect.height * pixelScale))

        let capturedCloseUpImage = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: sageOwnWindows),
            configuration: streamConfiguration
        )
        let closeUpImage = markFocusArea(focusRect, on: capturedCloseUpImage, imageGlobalRect: globalCloseUpRect) ?? capturedCloseUpImage
        guard let jpegData = NSBitmapImageRep(cgImage: closeUpImage)
            .representation(using: .jpeg, properties: [.compressionFactor: jpegCompressionFactor]) else { return nil }
        return CapturedScreen(
            jpegData: jpegData,
            labelForClaude: "close-up of exactly what the user circled (inside the red ring), so you can read it in detail (image dimensions: \(streamConfiguration.width)x\(streamConfiguration.height) pixels). never put point tags in this image's coordinates; always use the full screenshot's.",
            isCursorScreen: false,
            displayFrame: displayFrame,
            screenshotWidthInPixels: streamConfiguration.width,
            screenshotHeightInPixels: streamConfiguration.height,
            isZoomedDetail: true
        )
    }
}
