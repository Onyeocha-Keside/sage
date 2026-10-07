import CoreGraphics
import Foundation
import Testing
@testable import Sage

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

