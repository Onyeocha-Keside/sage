using Sage.Core.Conversation;
using Sage.Core.Geometry;
using Sage.Core.Networking;
using Sage.Core.Reply;
using static Sage.Core.Reply.ResponseSegment;

namespace Sage.Core.Tests;

/// <summary>Ported from leanring-buddyTests, so both apps treat a reply the same way.</summary>
public class StreamingResponseSegmenterTests
{
    /// <summary>Feeds text in small chunks, like the real stream, and collects every segment.</summary>
    private static List<ResponseSegment> Segments(string fullText, int chunkSize = 3)
    {
        var segmenter = new StreamingResponseSegmenter();
        var collected = new List<ResponseSegment>();
        for (int i = 0; i < fullText.Length; i += chunkSize)
        {
            collected.AddRange(segmenter.Append(fullText.Substring(i, Math.Min(chunkSize, fullText.Length - i))));
        }

        collected.AddRange(segmenter.Finish());
        return collected;
    }

    private static Pointing Point(double x, double y, string? label) => new(new PointingTag(x, y, label, null));

    [Fact]
    public void SplitsPlainReplyIntoSentences() => Assert.Equal(
        [new Speech("html is the skeleton of a page."), new Speech("css makes it pretty.")],
        Segments("html is the skeleton of a page. css makes it pretty."));

    [Fact]
    public void LinesTagsUpWithTheSentenceAfterThem() => Assert.Equal(
        [Point(42, 12, "file menu"), new Speech("open the file menu."), Point(300, 200, "export"), new Speech("then hit export.")],
        Segments("[POINT:42,12:file menu] open the file menu. [POINT:300,200:export] then hit export."));

    [Fact]
    public void SpeaksSentencesBeforeTheReplyFinishes()
    {
        var segmenter = new StreamingResponseSegmenter();
        Assert.Equal([new Speech("first sentence.")], segmenter.Append("first sentence. second sen"));
        Assert.Empty(segmenter.Append("tence"));
        Assert.Equal([new Speech("second sentence")], segmenter.Finish());
    }

    [Fact]
    public void NeverSpeaksAHalfWrittenTag()
    {
        var segmenter = new StreamingResponseSegmenter();
        Assert.Equal([new Speech("look here.")], segmenter.Append("look here. [POINT:12,3"));
        Assert.Empty(segmenter.Finish());
    }

    [Fact]
    public void DropsPointNoneTags() =>
        Assert.Equal([new Speech("just a fact.")], Segments("just a fact. [POINT:none]"));

    [Fact]
    public void DoesNotSplitDecimalsOrFilenames() => Assert.Equal(
        [new Speech("open index.html in version 3.5 now."), new Speech("done.")],
        Segments("open index.html in version 3.5 now. done."));

    [Fact]
    public void RecognizesTheFollowAlongTag() => Assert.Equal(
        [Point(420, 64, "search bar"), new Speech("type ecr in this search bar."), new FollowAlong()],
        Segments("[POINT:420,64:search bar] type ecr in this search bar. [FOLLOW]"));

    [Fact]
    public void NeverSpeaksAHalfWrittenFollowTag()
    {
        var segmenter = new StreamingResponseSegmenter();
        Assert.Equal([new Speech("click it.")], segmenter.Append("click it. [FOLL"));
        Assert.Empty(segmenter.Finish());
    }

    [Fact]
    public void KeepsWordsFromOrdinaryBrackets() => Assert.Equal(
        [new Speech("press the"), new Speech("enter"), new Speech("key.")],
        Segments("press the [enter] key."));

    [Fact]
    public void SpeaksTheOpeningClauseEarly()
    {
        var segmenter = new StreamingResponseSegmenter();
        Assert.Equal([new Speech("sure,")], segmenter.Append("sure, it's the blue"));
        Assert.Equal([new Speech("it's the blue button, top right.")], segmenter.Append(" button, top right. then, hit save."));
        Assert.Equal([new Speech("then, hit save.")], segmenter.Finish());
    }

    [Fact]
    public void OpensWithAClauseBeforeAPointingTag() => Assert.Equal(
        [new Speech("okay,"), Point(42, 12, "file menu"), new Speech("open the file menu.")],
        Segments("okay, [POINT:42,12:file menu] open the file menu."));

    [Fact]
    public void KeepsNumbersAndTinyOpenersWhole()
    {
        Assert.Equal([new Speech("about 1,000 rows at 10:30 today.")], Segments("about 1,000 rows at 10:30 today."));
        Assert.Empty(new StreamingResponseSegmenter().Append("so, the"));
    }

    [Fact]
    public void ReadsTheNextStepHintWithoutSpeakingIt() => Assert.Equal(
        [Point(420, 64, "search bar"), new Speech("type ecr up here."), new FollowAlong(), new NextStepHint("Elastic Container Registry")],
        Segments("[POINT:420,64:search bar] type ecr up here. [FOLLOW] [NEXT:Elastic Container Registry]"));

    [Fact]
    public void NeverSpeaksAHalfWrittenOrEmptyHint()
    {
        var segmenter = new StreamingResponseSegmenter();
        Assert.Equal([new Speech("click it."), new FollowAlong()], segmenter.Append("click it. [FOLLOW] [NEX"));
        Assert.Empty(segmenter.Finish());
        Assert.Equal([new Speech("done.")], Segments("done. [NEXT: ]"));
    }
}

public class PointingTagParsingTests
{
    [Fact]
    public void ParsesCoordinatesAndLabel() =>
        Assert.Equal(new PointingTag(640, 410, "save button", null), PointingTag.Parse("[POINT:640,410:save button]"));

    [Fact]
    public void ParsesScreenNumber() =>
        Assert.Equal(new PointingTag(400, 300, "terminal", 2), PointingTag.Parse("[POINT:400,300:terminal:screen2]"));

    [Fact]
    public void TreatsScreenWithoutLabelAsScreenNumber() =>
        Assert.Equal(new PointingTag(10, 20, null, 3), PointingTag.Parse("[POINT:10,20:screen3]"));

    [Fact]
    public void ParsesTagWithoutLabel() =>
        Assert.Equal(new PointingTag(5, 6, null, null), PointingTag.Parse("[POINT:5, 6]"));

    [Theory]
    [InlineData("[POINT:none]")]
    [InlineData("[not a tag]")]
    [InlineData("POINT:1,2")]
    public void RejectsNoneAndGarbage(string text) => Assert.Null(PointingTag.Parse(text));
}

/// <summary>
/// Windows-specific: these replace the Mac's bottom-left tests with the cases that can
/// go wrong here, which are negative coordinates and monitors with different resolutions.
/// </summary>
public class PointingTargetResolutionTests
{
    private static ScreenshotFrame Frame(double left, double top, double width, double height, bool isCursorScreen = true, int imageWidth = 1280, int imageHeight = 800) =>
        new(new DesktopRect(left, top, width, height), imageWidth, imageHeight, isCursorScreen);

    [Fact]
    public void MapsScaledScreenshotPixelsToTheDesktop()
    {
        // x: 640 * (1440 / 1280) = 720. y: 200 * (900 / 800) = 225, with no flip on Windows.
        var target = new PointingTag(640, 200, "middle", null).Resolve([Frame(0, 0, 1440, 900)]);
        Assert.Equal(new DesktopPoint(720, 225), target?.Location);
        Assert.Equal("middle", target?.Label);
    }

    [Fact]
    public void HandlesAMonitorLeftOfAndAboveThePrimary()
    {
        var target = new PointingTag(640, 400, null, null).Resolve([Frame(-1920, -300, 1920, 1200)]);
        Assert.Equal(new DesktopPoint(-1920 + 960, -300 + 600), target?.Location);
    }

    [Fact]
    public void HandlesAHighResolutionSecondMonitor()
    {
        // A 4K monitor beside a 1080p one: the scale differs per monitor.
        var primary = Frame(0, 0, 1920, 1080, imageHeight: 720);
        var fourK = Frame(1920, 0, 3840, 2160, isCursorScreen: false, imageHeight: 720);
        var target = new PointingTag(640, 360, null, 2).Resolve([primary, fourK]);
        Assert.Equal(new DesktopPoint(1920 + 1920, 1080), target?.Location);
        Assert.Equal(fourK.MonitorBounds, target?.MonitorBounds);
    }

    [Fact]
    public void ClampsCoordinatesThatOvershootTheImage()
    {
        var target = new PointingTag(5000, 5000, null, null).Resolve([Frame(0, 0, 1280, 800)]);
        Assert.Equal(new DesktopPoint(1280, 800), target?.Location);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(3)]
    public void RejectsAScreenNumberThatDoesNotExist(int screenNumber) =>
        Assert.Null(new PointingTag(1, 1, null, screenNumber).Resolve([Frame(0, 0, 1280, 800), Frame(1280, 0, 1280, 800, false)]));

    [Fact]
    public void AZoomedDetailIsNeverAScreen()
    {
        var closeUp = new ScreenshotFrame(new DesktopRect(0, 0, 100, 100), 500, 500, IsCursorScreen: false, IsZoomedDetail: true);
        var screen = Frame(0, 0, 1280, 800);
        Assert.Equal(new DesktopPoint(10, 20), new PointingTag(10, 20, null, 1).Resolve([closeUp, screen])?.Location);
        Assert.Null(new PointingTag(10, 20, null, 2).Resolve([closeUp, screen]));
    }

    [Fact]
    public void TheInverseMappingRoundTrips()
    {
        var frame = Frame(-2560, 100, 2560, 1440, imageHeight: 720);
        var desktop = DesktopCoordinates.ScreenshotPixelToDesktop(333, 444, frame)!.Value;
        var (x, y) = DesktopCoordinates.DesktopToScreenshotPixel(desktop, frame);
        Assert.Equal(333, x, 6);
        Assert.Equal(444, y, 6);
    }

    [Theory]
    [InlineData(3840, 2160, 1280, 720)]
    [InlineData(1440, 2560, 720, 1280)]
    public void ScalesTheLongestSideToTheLimit(int sourceWidth, int sourceHeight, int width, int height) =>
        Assert.Equal((width, height), DesktopCoordinates.ScaledImageSize(sourceWidth, sourceHeight, 1280));
}

public class ClaudeStreamDecoderTests
{
    [Fact]
    public void RejectsPrematureEndOfStream() =>
        Assert.Throws<SageApiException>(() => new ClaudeStreamDecoder().Finish());

    [Fact]
    public void AcceptsExplicitCompletion()
    {
        var decoder = new ClaudeStreamDecoder();
        decoder.Consume("""data:{"type":"message_stop"}""");
        decoder.Finish();
        Assert.True(decoder.HasCompleted);
    }

    [Fact]
    public void RejectsMalformedData() =>
        Assert.Throws<SageApiException>(() => new ClaudeStreamDecoder().Consume("data: {broken"));

    [Fact]
    public void RejectsOutputTruncation()
    {
        var decoder = new ClaudeStreamDecoder();
        decoder.Consume("""data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}""");
        Assert.Throws<SageApiException>(() => decoder.Consume("""data: {"type":"message_stop"}"""));
    }

    [Fact]
    public void ReadsTextAndIgnoresOtherLines()
    {
        var decoder = new ClaudeStreamDecoder();
        Assert.Empty(decoder.Consume("event: content_block_delta"));
        Assert.Equal<ClaudeStreamEvent>(
            [new ClaudeStreamEvent.TextDelta("hi")],
            decoder.Consume("""data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}"""));
    }

    [Fact]
    public void ReportsARefusal() => Assert.Equal<ClaudeStreamEvent>(
        [new ClaudeStreamEvent.Refusal()],
        new ClaudeStreamDecoder().Consume("""data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"""));

    [Fact]
    public void DoesNotExposeProviderErrorText()
    {
        var error = Assert.Throws<SageApiException>(() =>
            new ClaudeStreamDecoder().Consume("""data: {"type":"error","error":{"message":"private user content"}}"""));
        Assert.DoesNotContain("private", error.Message);
    }
}

public class ConversationMemoryTests
{
    [Fact]
    public void KeepsOnlyTheMostRecentTurns()
    {
        var memory = new ConversationMemory(maximumTurns: 2);
        memory.Remember("1", "a");
        memory.Remember("2", "b");
        memory.Remember("3", "c");
        Assert.Equal(["2", "3"], memory.Turns.Select(turn => turn.UserText));
    }

    [Fact]
    public void RemembersACompletelySpokenReply()
    {
        var memory = new ConversationMemory();
        Guid reply = Guid.NewGuid(), sentence = Guid.NewGuid();
        memory.BeginReply(reply, "question");
        memory.RegisterSentence(reply, sentence, "answer.");
        memory.CompletedSentence(sentence);
        memory.FinishReply(reply, interrupted: false);
        Assert.Equal(new ConversationTurn("question", "answer."), Assert.Single(memory.Turns));
    }

    [Fact]
    public void NeverRecordsUnspokenSentencesAsHeard()
    {
        var memory = new ConversationMemory();
        Guid reply = Guid.NewGuid(), spoken = Guid.NewGuid(), unspoken = Guid.NewGuid();
        memory.BeginReply(reply, "question");
        memory.RegisterSentence(reply, spoken, "heard.");
        memory.RegisterSentence(reply, unspoken, "never played.");
        memory.CompletedSentence(spoken);
        memory.FinishReply(reply, interrupted: true);
        string text = Assert.Single(memory.Turns).AssistantText;
        Assert.Contains("heard.", text);
        Assert.DoesNotContain("never played.", text);
        Assert.Contains("interrupted", text);
    }

    [Fact]
    public void IgnoresASupersededReply()
    {
        var memory = new ConversationMemory();
        memory.BeginReply(Guid.NewGuid(), "new question");
        memory.FinishReply(Guid.NewGuid(), interrupted: false);
        Assert.Empty(memory.Turns);
    }
}
