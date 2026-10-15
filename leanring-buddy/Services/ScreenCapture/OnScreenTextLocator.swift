//
//  OnScreenTextLocator.swift
//  Sage
//
//  Finds a short piece of text (a button or link label) in a screenshot with
//  Apple's on-device text recognition. Follow-along uses it to point at the
//  next control the moment a new screen appears, a second or two before
//  Claude's own answer arrives. Runs entirely on the Mac.
//

import CoreGraphics
import Foundation
import ImageIO
import Vision

enum OnScreenTextLocator {
    /// Finds `searchText` in the screenshot and returns its center in
    /// screenshot pixels (top-left origin). Returns nil when it isn't there,
    /// or appears more than once: an ambiguous early point is worse than none.
    nonisolated static func locate(_ searchText: String, inJPEG jpegData: Data) async -> CGPoint? {
        let normalizedSearchText = normalize(searchText)
        guard !normalizedSearchText.isEmpty,
              let imageSource = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let screenshotImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }

        return await Task.detached(priority: .userInitiated) {
            let textRequest = VNRecognizeTextRequest()
            // UI labels are short and often not dictionary words, so accuracy
            // matters more than language correction.
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = false
            do {
                try VNImageRequestHandler(cgImage: screenshotImage).perform([textRequest])
            } catch {
                return nil
            }

            var exactMatchBoxes: [CGRect] = []
            var containingMatchBoxes: [CGRect] = []
            for observation in textRequest.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let normalizedCandidate = normalize(candidate.string)
                if normalizedCandidate == normalizedSearchText {
                    exactMatchBoxes.append(observation.boundingBox)
                } else if let matchRange = wholeWordRange(of: searchText, in: candidate.string),
                          let matchBox = try? candidate.boundingBox(for: matchRange)?.boundingBox {
                    containingMatchBoxes.append(matchBox)
                }
            }

            // A label that is the whole text line beats a phrase inside a sentence.
            let matchBoxes = exactMatchBoxes.isEmpty ? containingMatchBoxes : exactMatchBoxes
            guard matchBoxes.count == 1, let matchBox = matchBoxes.first else { return nil }
            // Vision boxes are normalized with a bottom-left origin.
            return CGPoint(x: matchBox.midX * CGFloat(screenshotImage.width),
                           y: (1 - matchBox.midY) * CGFloat(screenshotImage.height))
        }.value
    }

    /// Lowercased letters, numbers and single spaces, so "Sign In" matches "sign in".
    nonisolated static func normalize(_ text: String) -> String {
        let lettersNumbersAndSpaces = text.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(lettersNumbersAndSpaces).split(separator: " ").joined(separator: " ")
    }

    /// The range of `searchText` inside `line` when it appears as whole words
    /// ("save" in "save as", not in "unsaved"), ignoring case.
    nonisolated static func wholeWordRange(of searchText: String, in line: String) -> Range<String.Index>? {
        var searchStart = line.startIndex
        while let foundRange = line.range(of: searchText, options: [.caseInsensitive], range: searchStart..<line.endIndex) {
            let startsAtWordBoundary = foundRange.lowerBound == line.startIndex
                || !isWordCharacter(line[line.index(before: foundRange.lowerBound)])
            let endsAtWordBoundary = foundRange.upperBound == line.endIndex
                || !isWordCharacter(line[foundRange.upperBound])
            if startsAtWordBoundary && endsAtWordBoundary { return foundRange }
            searchStart = line.index(after: foundRange.lowerBound)
        }
        return nil
    }

    nonisolated private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
