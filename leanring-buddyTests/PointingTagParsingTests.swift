import CoreGraphics
import Foundation
import Testing
@testable import Sage

@MainActor
struct PointingTagParsingTests {

    @Test func parsesCoordinatesAndLabel() {
        let pointingTag = PointingTag.parse("[POINT:640,410:save button]")
        #expect(pointingTag == PointingTag(screenshotPixelCoordinate: CGPoint(x: 640, y: 410), label: "save button", screenNumber: nil))
    }

    @Test func parsesScreenNumber() {
        let pointingTag = PointingTag.parse("[POINT:400,300:terminal:screen2]")
        #expect(pointingTag?.label == "terminal")
        #expect(pointingTag?.screenNumber == 2)
    }

    @Test func treatsScreenWithoutLabelAsScreenNumber() {
        let pointingTag = PointingTag.parse("[POINT:10,20:screen3]")
        #expect(pointingTag?.label == nil)
        #expect(pointingTag?.screenNumber == 3)
    }

    @Test func parsesTagWithoutLabel() {
        let pointingTag = PointingTag.parse("[POINT:5, 6]")
        #expect(pointingTag?.screenshotPixelCoordinate == CGPoint(x: 5, y: 6))
        #expect(pointingTag?.label == nil)
    }

    @Test func rejectsNoneAndGarbage() {
        #expect(PointingTag.parse("[POINT:none]") == nil)
        #expect(PointingTag.parse("[not a tag]") == nil)
        #expect(PointingTag.parse("POINT:1,2") == nil)
    }
}

