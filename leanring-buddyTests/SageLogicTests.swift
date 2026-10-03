//
//  SageLogicTests.swift
//  SageTests
//
//  Tests for the pure logic that turns Claude's streamed reply into speech
//  and cursor movements. Run with Cmd+U in Xcode.
//

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

@MainActor
struct StreamingResponseSegmenterTests {

    /// Feeds text in small chunks, like the real stream, and collects every segment.
    private func segments(fromStreamedText fullText: String, chunkSize: Int = 3) -> [ResponseSegment] {
        var responseSegmenter = StreamingResponseSegmenter()
        var collectedSegments: [ResponseSegment] = []
        var remainingText = Substring(fullText)
        while !remainingText.isEmpty {
            let nextChunk = remainingText.prefix(chunkSize)
            remainingText = remainingText.dropFirst(chunkSize)
            collectedSegments += responseSegmenter.append(String(nextChunk))
        }
        collectedSegments += responseSegmenter.finish()
        return collectedSegments
    }

    @Test func splitsPlainReplyIntoSentences() {
        let collectedSegments = segments(fromStreamedText: "html is the skeleton of a page. css makes it pretty.")
        #expect(collectedSegments == [
            .speech("html is the skeleton of a page."),
            .speech("css makes it pretty.")
        ])
    }

    @Test func linesTagsUpWithTheSentenceAfterThem() {
        let collectedSegments = segments(fromStreamedText: "[POINT:42,12:file menu] open the file menu. [POINT:300,200:export] then hit export.")
        #expect(collectedSegments == [
            .pointing(PointingTag(screenshotPixelCoordinate: CGPoint(x: 42, y: 12), label: "file menu", screenNumber: nil)),
            .speech("open the file menu."),
            .pointing(PointingTag(screenshotPixelCoordinate: CGPoint(x: 300, y: 200), label: "export", screenNumber: nil)),
            .speech("then hit export.")
        ])
    }

    @Test func speaksSentencesBeforeTheReplyFinishes() {
        var responseSegmenter = StreamingResponseSegmenter()
        #expect(responseSegmenter.append("first sentence. second sen") == [.speech("first sentence.")])
        #expect(responseSegmenter.append("tence") == [])
        #expect(responseSegmenter.finish() == [.speech("second sentence")])
    }

    @Test func neverSpeaksAHalfWrittenTag() {
        var responseSegmenter = StreamingResponseSegmenter()
        #expect(responseSegmenter.append("look here. [POINT:12,3") == [.speech("look here.")])
        #expect(responseSegmenter.finish() == [])
    }

    @Test func dropsPointNoneTags() {
        let collectedSegments = segments(fromStreamedText: "just a fact. [POINT:none]")
        #expect(collectedSegments == [.speech("just a fact.")])
    }

    @Test func doesNotSplitDecimalsOrFilenames() {
        let collectedSegments = segments(fromStreamedText: "open index.html in version 3.5 now. done.")
        #expect(collectedSegments == [
            .speech("open index.html in version 3.5 now."),
            .speech("done.")
        ])
    }

    @Test func recognizesTheFollowAlongTag() {
        let collectedSegments = segments(fromStreamedText: "[POINT:420,64:search bar] type ecr in this search bar. [FOLLOW]")
        #expect(collectedSegments == [
            .pointing(PointingTag(screenshotPixelCoordinate: CGPoint(x: 420, y: 64), label: "search bar", screenNumber: nil)),
            .speech("type ecr in this search bar."),
            .followAlong
        ])
    }

    @Test func neverSpeaksAHalfWrittenFollowTag() {
        var responseSegmenter = StreamingResponseSegmenter()
        #expect(responseSegmenter.append("click it. [FOLL") == [.speech("click it.")])
        #expect(responseSegmenter.finish() == [])
    }

    @Test func keepsWordsFromOrdinaryBrackets() {
        let collectedSegments = segments(fromStreamedText: "press the [enter] key.")
        #expect(collectedSegments == [
            .speech("press the"),
            .speech("enter"),
            .speech("key.")
        ])
    }
}

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
