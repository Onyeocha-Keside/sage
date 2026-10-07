import CoreGraphics
import Foundation
import Testing
@testable import Sage

@MainActor
struct ScreenThumbnailComparisonTests {

    @Test func identicalThumbnailsHaveNoDifference() {
        let thumbnail = ScreenThumbnail(grayscalePixels: [10, 200, 30, 40])
        #expect(thumbnail.averageDifference(from: thumbnail) == 0)
    }

    @Test func tinyChangeCountsAsUnchanged() {
        // One pixel out of 96 nudged slightly, like a blinking text cursor.
        let before = ScreenThumbnail(grayscalePixels: [UInt8](repeating: 120, count: 96))
        var nudgedPixels = before.grayscalePixels
        nudgedPixels[10] = 200
        let after = ScreenThumbnail(grayscalePixels: nudgedPixels)
        #expect(after.averageDifference(from: before) < ScreenChangeDetector.unchangedDifferenceThreshold)
    }

    @Test func bigChangeCountsAsChanged() {
        // A third of the screen goes from dark to light, like a menu opening.
        let before = ScreenThumbnail(grayscalePixels: [UInt8](repeating: 20, count: 96))
        let after = ScreenThumbnail(grayscalePixels: [UInt8](repeating: 20, count: 64) + [UInt8](repeating: 230, count: 32))
        #expect(after.averageDifference(from: before) > ScreenChangeDetector.unchangedDifferenceThreshold)
    }

    @Test func mismatchedSizesNeverCountAsUnchanged() {
        let small = ScreenThumbnail(grayscalePixels: [1, 2])
        let large = ScreenThumbnail(grayscalePixels: [1, 2, 3])
        #expect(small.averageDifference(from: large) > ScreenChangeDetector.unchangedDifferenceThreshold)
    }
}
