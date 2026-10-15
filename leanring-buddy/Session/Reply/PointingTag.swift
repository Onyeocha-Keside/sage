//
//  PointingTag.swift
//  Sage
//
//  Claude points at things by embedding tags like [POINT:640,410:save button]
//  or [POINT:400,300:terminal:screen2] in its reply. This file parses those
//  tags and converts screenshot pixels into real screen coordinates.
//
//  The tag format is defined in worker/src/prompts.ts. Keep them in sync.
//

import CoreGraphics
import Foundation

/// A pointing instruction exactly as Claude wrote it, in screenshot pixels.
struct PointingTag: Equatable {
    /// Pixel position inside the screenshot (top-left origin).
    let screenshotPixelCoordinate: CGPoint
    /// Short name for the element, shown in the bubble next to the cursor.
    let label: String?
    /// 1-based screen number from the image labels. Nil means "the cursor's screen".
    let screenNumber: Int?

    private static let tagRegularExpression = try? NSRegularExpression(
        pattern: #"^\[POINT:\s*(\d+)\s*,\s*(\d+)\s*(?::([^\]:]*?))?\s*(?::\s*screen\s*(\d+))?\s*\]$"#,
        options: [.caseInsensitive]
    )

    /// Parses one complete tag, like "[POINT:12,34:label]". Returns nil for
    /// "[POINT:none]" and for anything that isn't a valid tag.
    static func parse(_ tagText: String) -> PointingTag? {
        let trimmedTagText = tagText.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullRange = NSRange(trimmedTagText.startIndex..., in: trimmedTagText)

        guard let tagRegularExpression,
              let match = tagRegularExpression.firstMatch(in: trimmedTagText, range: fullRange),
              let xRange = Range(match.range(at: 1), in: trimmedTagText),
              let yRange = Range(match.range(at: 2), in: trimmedTagText),
              let xPixel = Double(trimmedTagText[xRange]),
              let yPixel = Double(trimmedTagText[yRange]) else {
            return nil
        }

        var label: String?
        if let labelRange = Range(match.range(at: 3), in: trimmedTagText) {
            let trimmedLabel = trimmedTagText[labelRange].trimmingCharacters(in: .whitespaces)
            label = trimmedLabel.isEmpty ? nil : trimmedLabel
        }

        var screenNumber: Int?
        if let screenRange = Range(match.range(at: 4), in: trimmedTagText) {
            screenNumber = Int(trimmedTagText[screenRange])
        }

        // "[POINT:1,2:screen2]" (screen without a label) gets read as a label
        // called "screen2". Treat it as the screen number instead.
        if screenNumber == nil, let possibleScreenLabel = label?.lowercased(),
           possibleScreenLabel.hasPrefix("screen"),
           let screenNumberFromLabel = Int(possibleScreenLabel.dropFirst("screen".count)) {
            screenNumber = screenNumberFromLabel
            label = nil
        }

        return PointingTag(
            screenshotPixelCoordinate: CGPoint(x: xPixel, y: yPixel),
            label: label,
            screenNumber: screenNumber
        )
    }
}

/// A pointing tag converted into a real location on a real screen,
/// ready for the cursor overlay to fly to.
struct PointingTarget: Equatable, Identifiable {
    let id: UUID
    /// AppKit global coordinates (bottom-left origin), same space as NSEvent.mouseLocation.
    let globalScreenLocation: CGPoint
    /// Frame of the display the target is on, used to pick which overlay animates.
    let displayFrame: CGRect
    let label: String?
    /// When the screenshot this target came from was taken (seconds since
    /// boot), so scrolling after that moment can be accounted for.
    var screenshotCaptureUptime: TimeInterval = 0
    /// Set when the target has scrolled out of view: the location is then a
    /// stand-in just inside the visible edge, and the bubble says which way to scroll.
    var offScreenEdge: OffScreenEdge? = nil

    /// The same target (same ID, so the cursor follows instead of re-flying)
    /// at a new place.
    func moved(to newLocation: CGPoint, offScreenEdge newOffScreenEdge: OffScreenEdge?) -> PointingTarget {
        PointingTarget(id: id, globalScreenLocation: newLocation, displayFrame: displayFrame, label: label,
                       screenshotCaptureUptime: screenshotCaptureUptime, offScreenEdge: newOffScreenEdge)
    }
}

extension PointingTag {
    /// Maps this tag's screenshot pixels onto the screen it refers to.
    /// Returns nil if there are no screenshots to map against.
    func resolve(against allCapturedImages: [CapturedScreen]) -> PointingTarget? {
        // A circled-area close-up isn't a screen, so it never takes a screen number.
        let capturedScreens = allCapturedImages.filter { !$0.isZoomedDetail }
        let targetScreen: CapturedScreen?
        if let screenNumber {
            guard screenNumber >= 1, screenNumber <= capturedScreens.count else { return nil }
            targetScreen = capturedScreens[screenNumber - 1]
        } else {
            targetScreen = capturedScreens.first(where: { $0.isCursorScreen }) ?? capturedScreens.first
        }
        guard let targetScreen else { return nil }

        let screenshotWidth = CGFloat(targetScreen.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(targetScreen.screenshotHeightInPixels)
        let displayFrame = targetScreen.displayFrame
        guard screenshotWidth > 0, screenshotHeight > 0,
              screenshotPixelCoordinate.x.isFinite, screenshotPixelCoordinate.y.isFinite else { return nil }

        // Claude sometimes overshoots the image edges slightly; keep it on screen.
        let clampedPixelX = max(0, min(screenshotPixelCoordinate.x, screenshotWidth))
        let clampedPixelY = max(0, min(screenshotPixelCoordinate.y, screenshotHeight))

        // Screenshot pixels → display points (the screenshot was scaled down).
        let displayLocalX = clampedPixelX * (displayFrame.width / screenshotWidth)
        let displayLocalYFromTop = clampedPixelY * (displayFrame.height / screenshotHeight)

        // Top-left origin (screenshot) → bottom-left origin (AppKit), then → global.
        let globalScreenLocation = CGPoint(
            x: displayFrame.origin.x + displayLocalX,
            y: displayFrame.origin.y + (displayFrame.height - displayLocalYFromTop)
        )

        return PointingTarget(
            id: UUID(),
            globalScreenLocation: globalScreenLocation,
            displayFrame: displayFrame,
            label: label,
            screenshotCaptureUptime: targetScreen.captureUptime
        )
    }
}
