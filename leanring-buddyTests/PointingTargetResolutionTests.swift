import CoreGraphics
import Foundation
import Testing
@testable import Sage

@MainActor
struct PointingTargetResolutionTests {

    private func capturedScreen(displayFrame: CGRect, isCursorScreen: Bool) -> CapturedScreen {
        CapturedScreen(
            jpegData: Data(),
            labelForClaude: "test screen",
            isCursorScreen: isCursorScreen,
            displayFrame: displayFrame,
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800
        )
    }

    @Test func mapsScreenshotPixelsToAppKitCoordinates() {
        // A 1440x900 display; the screenshot was scaled down to 1280x800.
        let mainScreen = capturedScreen(displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), isCursorScreen: true)
        let pointingTag = PointingTag(screenshotPixelCoordinate: CGPoint(x: 640, y: 200), label: "middle", screenNumber: nil)

        let pointingTarget = pointingTag.resolve(against: [mainScreen])

        // x: 640 * (1440/1280) = 720. y from top: 200 * (900/800) = 225, so from bottom: 900 - 225 = 675.
        #expect(pointingTarget?.globalScreenLocation == CGPoint(x: 720, y: 675))
        #expect(pointingTarget?.label == "middle")
    }

    @Test func usesTheRequestedScreen() {
        let cursorScreen = capturedScreen(displayFrame: CGRect(x: 0, y: 0, width: 1280, height: 800), isCursorScreen: true)
        let secondScreen = capturedScreen(displayFrame: CGRect(x: 1280, y: 0, width: 1280, height: 800), isCursorScreen: false)
        let pointingTag = PointingTag(screenshotPixelCoordinate: CGPoint(x: 0, y: 800), label: nil, screenNumber: 2)

        let pointingTarget = pointingTag.resolve(against: [cursorScreen, secondScreen])

        #expect(pointingTarget?.globalScreenLocation == CGPoint(x: 1280, y: 0))
        #expect(pointingTarget?.displayFrame == secondScreen.displayFrame)
    }

    @Test func clampsCoordinatesThatOvershootTheImage() {
        let mainScreen = capturedScreen(displayFrame: CGRect(x: 0, y: 0, width: 1280, height: 800), isCursorScreen: true)
        let pointingTag = PointingTag(screenshotPixelCoordinate: CGPoint(x: 5000, y: 5000), label: nil, screenNumber: nil)

        let pointingTarget = pointingTag.resolve(against: [mainScreen])

        #expect(pointingTarget?.globalScreenLocation == CGPoint(x: 1280, y: 0))
    }
}

