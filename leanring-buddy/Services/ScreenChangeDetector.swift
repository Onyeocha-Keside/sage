//
//  ScreenChangeDetector.swift
//  Sage
//
//  Tells when the screen has stopped changing, so follow-along can look
//  again the moment a menu has opened or a page has loaded, instead of
//  always waiting a fixed amount of time.
//
//  It works by grabbing tiny grayscale thumbnails (about 96 pixels wide) of
//  the screen under the mouse and comparing consecutive ones. Thumbnails
//  never leave the Mac and are thrown away immediately.
//

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A tiny grayscale snapshot of one display, one byte per pixel.
struct ScreenThumbnail {
    let grayscalePixels: [UInt8]

    /// Average per-pixel brightness difference (0 = identical, 255 = opposite).
    func averageDifference(from otherThumbnail: ScreenThumbnail) -> Double {
        guard grayscalePixels.count == otherThumbnail.grayscalePixels.count, !grayscalePixels.isEmpty else {
            return .greatestFiniteMagnitude
        }
        var totalDifference = 0
        for pixelIndex in grayscalePixels.indices {
            totalDifference += abs(Int(grayscalePixels[pixelIndex]) - Int(otherThumbnail.grayscalePixels[pixelIndex]))
        }
        return Double(totalDifference) / Double(grayscalePixels.count)
    }
}

enum ScreenChangeDetector {
    private static let thumbnailWidth = 96

    /// Below this average difference two thumbnails count as "the same".
    /// High enough to ignore a blinking text cursor or a ticking clock,
    /// low enough to notice a menu opening or a page swapping in.
    static let unchangedDifferenceThreshold = 1.5

    /// Captures a thumbnail of the display the mouse is on, leaving out
    /// Sage's own windows (its cursor animates, which would look like change).
    static func captureThumbnailOfDisplayUnderMouse() async -> ScreenThumbnail? {
        guard let shareableContent = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }

        let mouseLocation = NSEvent.mouseLocation
        let displayIDUnderMouse = NSScreen.screens
            .first(where: { $0.frame.contains(mouseLocation) })?
            .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID

        guard let displayToCapture = shareableContent.displays.first(where: { $0.displayID == displayIDUnderMouse })
                ?? shareableContent.displays.first else {
            return nil
        }

        let sageBundleIdentifier = Bundle.main.bundleIdentifier
        let sageOwnWindows = shareableContent.windows.filter { window in
            window.owningApplication?.bundleIdentifier == sageBundleIdentifier
        }

        let thumbnailHeight = max(1, Int(Double(thumbnailWidth) * Double(displayToCapture.height) / Double(displayToCapture.width)))
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = thumbnailWidth
        streamConfiguration.height = thumbnailHeight

        guard let thumbnailImage = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: displayToCapture, excludingWindows: sageOwnWindows),
            configuration: streamConfiguration
        ) else {
            return nil
        }

        return grayscaleThumbnail(from: thumbnailImage, width: thumbnailWidth, height: thumbnailHeight)
    }

    /// Redraws the capture into a small 8-bit grayscale buffer so comparing
    /// two thumbnails is a simple byte-by-byte difference.
    private static func grayscaleThumbnail(from image: CGImage, width: Int, height: Int) -> ScreenThumbnail? {
        var grayscalePixels = [UInt8](repeating: 0, count: width * height)
        let didDraw = grayscalePixels.withUnsafeMutableBytes { pixelBuffer -> Bool in
            guard let grayscaleContext = CGContext(
                data: pixelBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            grayscaleContext.interpolationQuality = .low
            grayscaleContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return didDraw ? ScreenThumbnail(grayscalePixels: grayscalePixels) : nil
    }
}
