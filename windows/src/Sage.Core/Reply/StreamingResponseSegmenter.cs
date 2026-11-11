namespace Sage.Core.Reply;

/// <summary>
/// Claude's reply arrives a few characters at a time. Waiting for the whole reply
/// before speaking adds seconds of dead air, so this splits the stream into speakable
/// sentences and pointing tags as soon as each one is complete.
/// Behavior matches StreamingResponseSegmenter.swift in the Mac app.
/// </summary>
public sealed class StreamingResponseSegmenter
{
    /// <summary>A "[" that isn't closed within this many characters isn't a tag.</summary>
    private const int MaximumTagLength = 120;
    /// <summary>A first clause shorter than this ("so,") is too small for its own chunk.</summary>
    private const int MinimumFirstClauseLetterCount = 3;
    private const string FollowAlongTag = "[FOLLOW]";
    private const string NextStepHintPrefix = "[NEXT:";
    /// <summary>A hint is the text of one control, so anything longer isn't one.</summary>
    private const int MaximumNextStepHintLength = 60;

    private static readonly string[] ControlTagStarts = ["[POINT", "[FOLLOW", "[NEXT"];

    private string _bufferedText = "";
    private bool _hasEmittedSpeech;

    /// <summary>Feeds newly streamed text in and returns every segment now complete.</summary>
    public IReadOnlyList<ResponseSegment> Append(string newlyStreamedText)
    {
        _bufferedText += newlyStreamedText;
        return ExtractCompletedSegments(isEndOfStream: false);
    }

    /// <summary>Call once the stream ends to flush whatever is left.</summary>
    public IReadOnlyList<ResponseSegment> Finish() => ExtractCompletedSegments(isEndOfStream: true);

    private List<ResponseSegment> ExtractCompletedSegments(bool isEndOfStream)
    {
        var completed = new List<ResponseSegment>();

        while (true)
        {
            int bracketStart = _bufferedText.IndexOf('[');
            if (bracketStart < 0)
            {
                // No tag in sight. Speak every complete sentence and keep the unfinished tail.
                int end = isEndOfStream ? _bufferedText.Length : SpeakableEndIndex(_bufferedText);
                AppendSpeechIfMeaningful(_bufferedText[..end], completed);
                _bufferedText = _bufferedText[end..];
                return completed;
            }

            int bracketEnd = _bufferedText.IndexOf(']', bracketStart);
            if (bracketEnd >= 0)
            {
                // Text before the tag is its own speech segment, so the tag lines up
                // with the sentence that follows it.
                AppendSpeechIfMeaningful(_bufferedText[..bracketStart], completed);

                string bracketed = _bufferedText[bracketStart..(bracketEnd + 1)];
                if (PointingTag.Parse(bracketed) is { } tag)
                {
                    completed.Add(new ResponseSegment.Pointing(tag));
                }
                else if (bracketed.ToUpperInvariant().Replace(" ", "") == FollowAlongTag)
                {
                    completed.Add(new ResponseSegment.FollowAlong());
                }
                else if (ParseNextStepHint(bracketed) is { } hint)
                {
                    completed.Add(new ResponseSegment.NextStepHint(hint));
                }
                else if (!LooksLikeSageControlTag(bracketed))
                {
                    // Ordinary bracketed words: keep the words, drop the brackets.
                    AppendSpeechIfMeaningful(bracketed[1..^1], completed);
                }
                // Anything else that looks like ours (such as [POINT:none]) is dropped.

                _bufferedText = _bufferedText[(bracketEnd + 1)..];
                continue;
            }

            // A "[" with no closing "]" yet.
            string unclosed = _bufferedText[bracketStart..];
            string beforeBracket = _bufferedText[..bracketStart];
            if (isEndOfStream)
            {
                // The reply ended mid-tag. Never speak a half-written tag out loud.
                _bufferedText = LooksLikeSageControlTag(unclosed) ? beforeBracket : beforeBracket + unclosed[1..];
                continue;
            }

            if (unclosed.Length > MaximumTagLength)
            {
                // Too long to be a tag. Treat the bracket as ordinary text.
                _bufferedText = _bufferedText.Remove(bracketStart, 1);
                continue;
            }

            // Wait for the tag to finish, but speak complete sentences before it now.
            int beforeEnd = SpeakableEndIndex(beforeBracket);
            AppendSpeechIfMeaningful(beforeBracket[..beforeEnd], completed);
            _bufferedText = beforeBracket[beforeEnd..] + unclosed;
            return completed;
        }
    }

    /// <summary>"[NEXT:download]" becomes "download". Null otherwise or for an empty hint.</summary>
    private static string? ParseNextStepHint(string bracketed)
    {
        if (!bracketed.StartsWith(NextStepHintPrefix, StringComparison.OrdinalIgnoreCase)) return null;
        string hint = bracketed[NextStepHintPrefix.Length..^1].Trim();
        return hint.Length is > 0 and <= MaximumNextStepHintLength ? hint : null;
    }

    /// <summary>
    /// True for text that is, or could be the start of, one of Sage's tags. Those must
    /// never be read aloud, even when malformed or cut off mid-word like "[FOLL".
    /// </summary>
    private static bool LooksLikeSageControlTag(string bracketed)
    {
        string upper = bracketed.ToUpperInvariant();
        return ControlTagStarts.Any(start =>
            upper.StartsWith(start, StringComparison.Ordinal) || start.StartsWith(upper, StringComparison.Ordinal));
    }

    private void AppendSpeechIfMeaningful(string candidate, List<ResponseSegment> segments)
    {
        string trimmed = candidate.Trim();
        // Skip fragments with nothing to say, like a lone "." between two tags.
        if (!trimmed.Any(char.IsLetterOrDigit)) return;
        segments.Add(new ResponseSegment.Speech(trimmed));
        _hasEmittedSpeech = true;
    }

    /// <summary>Complete sentences are always speakable; before any speech, an opening clause is too.</summary>
    private int SpeakableEndIndex(string text)
    {
        int sentenceEnd = EndIndexOfLastCompleteSentence(text);
        if (_hasEmittedSpeech || sentenceEnd != 0) return sentenceEnd;
        return EndIndexOfFirstClause(text) ?? sentenceEnd;
    }

    /// <summary>
    /// The index just past the first clause mark that's followed by whitespace and has
    /// enough letters before it. The whitespace rule keeps "1,000" and "10:30" whole.
    /// </summary>
    internal static int? EndIndexOfFirstClause(string text)
    {
        int letterCount = 0;
        for (int i = 0; i < text.Length; i++)
        {
            char current = text[i];
            if (char.IsLetterOrDigit(current))
            {
                letterCount++;
            }
            else if (current is ',' or ';' or ':' or '—'
                     && letterCount >= MinimumFirstClauseLetterCount
                     && i + 1 < text.Length
                     && char.IsWhiteSpace(text[i + 1]))
            {
                return i + 1;
            }
        }

        return null;
    }

    /// <summary>
    /// The index just past the last sentence boundary: ".", "!" or "?" followed by
    /// whitespace, or a newline. The whitespace rule keeps "3.5" and "index.html" whole.
    /// </summary>
    internal static int EndIndexOfLastCompleteSentence(string text)
    {
        int lastBoundary = 0;
        for (int i = 0; i < text.Length; i++)
        {
            char current = text[i];
            if (current is '\n' or '\r')
            {
                lastBoundary = i + 1;
            }
            else if (current is '.' or '!' or '?' && i + 1 < text.Length && char.IsWhiteSpace(text[i + 1]))
            {
                lastBoundary = i + 1;
            }
        }

        return lastBoundary;
    }
}
