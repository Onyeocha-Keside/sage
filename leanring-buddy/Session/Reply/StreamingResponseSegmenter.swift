//
//  StreamingResponseSegmenter.swift
//  Sage
//
//  Claude's reply arrives a few characters at a time. Waiting for the whole
//  reply before speaking adds seconds of dead air, so this splits the stream
//  into speakable sentences and pointing tags as soon as each one is complete.
//
//  Example stream:  "[POINT:42,12:file menu] open the file menu. [POINT:..."
//  Segments out:    .pointing(file menu), .speech("open the file menu."), ...
//

import Foundation

/// One piece of Claude's reply, in the order Sage should act on it.
enum ResponseSegment: Equatable {
    /// Text that's ready to be spoken aloud.
    case speech(String)
    /// A pointing tag. It applies to the speech segment that comes right after it.
    case pointing(PointingTag)
    /// Claude asked the user to do something on screen and wants to see the
    /// result: Sage should watch for the user's next action, then look again.
    case followAlong
    /// Claude's guess at the visible text of the control the user will need
    /// on the next screen, so Sage can point there before Claude answers.
    case nextStepHint(String)
}

struct StreamingResponseSegmenter {
    /// A "[" that isn't closed within this many characters isn't a tag.
    private static let maximumTagLength = 120
    private static let sentenceEndingCharacters: Set<Character> = [".", "!", "?"]
    /// Where the very first chunk may break early ("sure, it's up here.").
    private static let clauseEndingCharacters: Set<Character> = [",", ";", ":", "—"]
    /// A first clause shorter than this ("so,") is too small to be worth its own chunk.
    private static let minimumFirstClauseLetterCount = 3
    private static let followAlongTag = "[FOLLOW]"
    private static let nextStepHintPrefix = "[NEXT:"
    /// A hint is the text of one control, so anything longer isn't one.
    private static let maximumNextStepHintLength = 60

    private var bufferedText = ""
    /// The first chunk is what the user waits for, so until something has been
    /// spoken it may end at a comma instead of a full stop. Later chunks stay
    /// whole sentences, because every chunk boundary adds a small pause.
    private var hasEmittedSpeech = false

    /// Feeds newly streamed text in and returns every segment that's now complete.
    mutating func append(_ newlyStreamedText: String) -> [ResponseSegment] {
        bufferedText += newlyStreamedText
        return extractCompletedSegments(isEndOfStream: false)
    }

    /// Call once the stream ends to flush whatever is left.
    mutating func finish() -> [ResponseSegment] {
        extractCompletedSegments(isEndOfStream: true)
    }

    private mutating func extractCompletedSegments(isEndOfStream: Bool) -> [ResponseSegment] {
        var completedSegments: [ResponseSegment] = []

        while true {
            guard let bracketStartIndex = bufferedText.firstIndex(of: "[") else {
                // No tag in sight. Speak every complete sentence and keep the unfinished tail.
                let speakableEndIndex = isEndOfStream
                    ? bufferedText.endIndex
                    : speakableEndIndex(in: bufferedText)
                appendSpeechIfMeaningful(String(bufferedText[..<speakableEndIndex]), to: &completedSegments)
                bufferedText = String(bufferedText[speakableEndIndex...])
                return completedSegments
            }

            if let bracketEndIndex = bufferedText[bracketStartIndex...].firstIndex(of: "]") {
                // A complete bracketed chunk. Text before it is its own speech segment,
                // so the tag lines up with the sentence that follows it.
                appendSpeechIfMeaningful(String(bufferedText[..<bracketStartIndex]), to: &completedSegments)

                let bracketedText = String(bufferedText[bracketStartIndex...bracketEndIndex])
                if let pointingTag = PointingTag.parse(bracketedText) {
                    completedSegments.append(.pointing(pointingTag))
                } else if bracketedText.uppercased().replacingOccurrences(of: " ", with: "") == Self.followAlongTag {
                    completedSegments.append(.followAlong)
                } else if let nextStepHint = Self.parseNextStepHint(bracketedText) {
                    completedSegments.append(.nextStepHint(nextStepHint))
                } else if !Self.looksLikeSageControlTag(bracketedText) {
                    // Ordinary bracketed words: keep the words, drop the brackets.
                    appendSpeechIfMeaningful(String(bracketedText.dropFirst().dropLast()), to: &completedSegments)
                }
                // Anything else that looks like ours (like "[POINT:none]") is silently dropped.

                bufferedText = String(bufferedText[bufferedText.index(after: bracketEndIndex)...])
                continue
            }

            // A "[" with no closing "]" yet.
            let unclosedText = bufferedText[bracketStartIndex...]
            if isEndOfStream {
                // The reply ended mid-tag. Never speak a half-written tag out loud.
                let textBeforeBracket = String(bufferedText[..<bracketStartIndex])
                bufferedText = Self.looksLikeSageControlTag(String(unclosedText))
                    ? textBeforeBracket
                    : textBeforeBracket + unclosedText.dropFirst()
                continue
            }
            if unclosedText.count > Self.maximumTagLength {
                // Too long to be a tag. Treat the bracket as ordinary text.
                bufferedText.remove(at: bracketStartIndex)
                continue
            }

            // Wait for the tag to finish, but speak complete sentences before it now.
            let textBeforeBracket = String(bufferedText[..<bracketStartIndex])
            let textBeforeBracketEndIndex = speakableEndIndex(in: textBeforeBracket)
            appendSpeechIfMeaningful(String(textBeforeBracket[..<textBeforeBracketEndIndex]), to: &completedSegments)
            bufferedText = String(textBeforeBracket[textBeforeBracketEndIndex...]) + unclosedText
            return completedSegments
        }
    }

    /// "[NEXT:download]" → "download". Nil for anything else or an empty hint.
    private static func parseNextStepHint(_ bracketedText: String) -> String? {
        guard bracketedText.uppercased().hasPrefix(nextStepHintPrefix) else { return nil }
        let hintText = bracketedText.dropFirst(nextStepHintPrefix.count).dropLast()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hintText.isEmpty, hintText.count <= maximumNextStepHintLength else { return nil }
        return hintText
    }

    /// True for text that is, or could be the start of, one of Sage's tags
    /// ([POINT…], [FOLLOW…] or [NEXT…]). Those must never be read aloud, even
    /// when malformed or cut off mid-word like "[FOLL".
    private static func looksLikeSageControlTag(_ bracketedText: String) -> Bool {
        let uppercasedText = bracketedText.uppercased()
        return ["[POINT", "[FOLLOW", "[NEXT"].contains { tagStart in
            uppercasedText.hasPrefix(tagStart) || tagStart.hasPrefix(uppercasedText)
        }
    }

    private mutating func appendSpeechIfMeaningful(_ candidateText: String, to segments: inout [ResponseSegment]) {
        let trimmedText = candidateText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Skip fragments with nothing to say, like a lone "." between two tags.
        guard trimmedText.rangeOfCharacter(from: .alphanumerics) != nil else { return }
        segments.append(.speech(trimmedText))
        hasEmittedSpeech = true
    }

    /// Complete sentences are always speakable. Before anything has been
    /// spoken, a finished opening clause is too.
    private func speakableEndIndex(in text: String) -> String.Index {
        let sentenceEndIndex = Self.endIndexOfLastCompleteSentence(in: text)
        guard !hasEmittedSpeech, sentenceEndIndex == text.startIndex else { return sentenceEndIndex }
        return Self.endIndexOfFirstClause(in: text) ?? sentenceEndIndex
    }

    /// The index just past the first ",", ";", ":" or "—" that's followed by
    /// whitespace and has enough words before it. The whitespace rule keeps
    /// "1,000" and "10:30" whole.
    static func endIndexOfFirstClause(in text: String) -> String.Index? {
        var letterCount = 0
        var currentIndex = text.startIndex
        while currentIndex < text.endIndex {
            let currentCharacter = text[currentIndex]
            let nextIndex = text.index(after: currentIndex)
            if currentCharacter.isLetter || currentCharacter.isNumber {
                letterCount += 1
            } else if clauseEndingCharacters.contains(currentCharacter),
                      letterCount >= minimumFirstClauseLetterCount,
                      nextIndex < text.endIndex,
                      text[nextIndex].isWhitespace {
                return nextIndex
            }
            currentIndex = nextIndex
        }
        return nil
    }

    /// The index just past the last sentence boundary: ".", "!" or "?" followed
    /// by whitespace, or a newline. Requiring the whitespace avoids splitting
    /// "3.5" or "index.html" in half.
    static func endIndexOfLastCompleteSentence(in text: String) -> String.Index {
        var lastBoundaryIndex = text.startIndex
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            let currentCharacter = text[currentIndex]
            let nextIndex = text.index(after: currentIndex)

            if currentCharacter.isNewline {
                lastBoundaryIndex = nextIndex
            } else if sentenceEndingCharacters.contains(currentCharacter),
                      nextIndex < text.endIndex,
                      text[nextIndex].isWhitespace {
                lastBoundaryIndex = nextIndex
            }
            currentIndex = nextIndex
        }

        return lastBoundaryIndex
    }
}
