using System.Collections.Concurrent;
using Sage.Core.Conversation;
using Sage.Core.Reply;
using Sage.Core.Audio;

namespace Sage.Core.Tests;

public class SpeechTests
{
    /// <summary>Records what happened. Sentences containing "hang" play until cancelled; "fail" throws.</summary>
    private sealed class FakeVoice : ISpeechVoice
    {
        public ConcurrentQueue<string> Log { get; } = new();

        public IPreparedSpeech Prepare(string text)
        {
            Log.Enqueue($"prepare {text}");
            return new Prepared(this, text);
        }

        private sealed class Prepared(FakeVoice voice, string text) : IPreparedSpeech
        {
            public string Text => text;

            public async Task PlayAsync(Action onStarted, CancellationToken cancellationToken)
            {
                if (text.Contains("fail")) throw new InvalidOperationException("no audio device");
                onStarted();
                voice.Log.Enqueue($"play {text}");
                await Task.Delay(text.Contains("hang") ? Timeout.Infinite : 5, cancellationToken);
                voice.Log.Enqueue($"done {text}");
            }

            public void Dispose() => voice.Log.Enqueue($"dispose {text}");
        }
    }

    private static readonly TimeSpan Patience = TimeSpan.FromSeconds(5);

    [Fact]
    public async Task PlaysInOrderAndReportsEachSentence()
    {
        var voice = new FakeVoice();
        var queue = new SpeechPlaybackQueue();
        var started = new ConcurrentQueue<Guid>();
        var completed = new ConcurrentQueue<Guid>();
        queue.SegmentStarted += started.Enqueue;
        queue.SegmentCompleted += completed.Enqueue;

        Guid[] ids = [Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid()];
        queue.Enqueue("one", ids[0], voice);
        queue.Enqueue("two", ids[1], voice);
        queue.Enqueue("three", ids[2], voice);
        await queue.WaitUntilFinishedAsync().WaitAsync(Patience);

        Assert.False(queue.IsPlaying);
        Assert.Equal(ids, started);
        Assert.Equal(ids, completed);
        Assert.Equal(["play one", "play two", "play three"], voice.Log.Where(l => l.StartsWith("play")));
        // Audio for later sentences is prepared before earlier ones finish playing.
        var log = voice.Log.ToList();
        Assert.True(log.IndexOf("prepare three") < log.IndexOf("done one"));
    }

    [Fact]
    public async Task FailedSentenceIsSkippedNotCompleted()
    {
        var voice = new FakeVoice();
        var queue = new SpeechPlaybackQueue();
        var completed = new ConcurrentQueue<Guid>();
        var failed = new ConcurrentQueue<Guid>();
        queue.SegmentCompleted += completed.Enqueue;
        queue.SegmentFailed += (id, _) => failed.Enqueue(id);

        Guid bad = Guid.NewGuid(), good = Guid.NewGuid();
        queue.Enqueue("fail here", bad, voice);
        queue.Enqueue("fine", good, voice);
        await queue.WaitUntilFinishedAsync().WaitAsync(Patience);

        Assert.Equal([bad], failed);
        Assert.Equal([good], completed);
    }

    [Fact]
    public async Task StopAllAbandonsCurrentAndQueued()
    {
        var voice = new FakeVoice();
        var queue = new SpeechPlaybackQueue();
        var completed = new ConcurrentQueue<Guid>();
        var startedHang = new TaskCompletionSource();
        queue.SegmentStarted += _ => startedHang.TrySetResult();
        queue.SegmentCompleted += completed.Enqueue;

        queue.Enqueue("hang forever", Guid.NewGuid(), voice);
        queue.Enqueue("never played", Guid.NewGuid(), voice);
        await startedHang.Task.WaitAsync(Patience);

        queue.StopAll();
        Assert.False(queue.IsPlaying);
        await queue.WaitUntilFinishedAsync().WaitAsync(Patience);
        await Task.Delay(50);

        Assert.Empty(completed);
        Assert.Contains("dispose never played", voice.Log);
        Assert.DoesNotContain("play never played", voice.Log);

        // The queue is usable again after a stop.
        var after = Guid.NewGuid();
        queue.Enqueue("after", after, voice);
        await queue.WaitUntilFinishedAsync().WaitAsync(Patience);
        Assert.Equal([after], completed);
    }

    [Fact]
    public async Task CursorFliesAsItsSentenceStarts()
    {
        var voice = new FakeVoice();
        var queue = new SpeechPlaybackQueue();
        var memory = new ConversationMemory();
        var replyId = Guid.NewGuid();
        memory.BeginReply(replyId, "what's this?");
        var events = new ConcurrentQueue<string>();
        queue.SegmentStarted += _ => events.Enqueue("sentence");

        using (var choreographer = new ReplyChoreographer(queue, voice, memory, replyId, tag => events.Enqueue($"point {tag.Label}")))
        {
            var segmenter = new StreamingResponseSegmenter();
            foreach (var chunk in new[] { "this is vs code. [POINT:120,300:file explorer] over here are your files. ",
                                         "[POINT:700,780:terminal] and down here is the terminal. [FOLLOW] [NEXT:run]" })
            {
                foreach (var segment in segmenter.Append(chunk)) choreographer.Handle(segment);
            }

            foreach (var segment in segmenter.Finish()) choreographer.Handle(segment);
            choreographer.Finish();
            await queue.WaitUntilFinishedAsync().WaitAsync(Patience);

            Assert.True(choreographer.WantsFollowAlong);
            Assert.Equal("run", choreographer.NextStepHint);
            Assert.Equal(3, choreographer.SpokenText.Count);
        }

        // The "sentence" handler subscribed first, so each point follows its own sentence's start.
        Assert.Equal(["sentence", "sentence", "point file explorer", "sentence", "point terminal"], events);

        memory.FinishReply(replyId, interrupted: false);
        var turn = Assert.Single(memory.Turns);
        Assert.DoesNotContain("interrupted", turn.AssistantText);
        Assert.DoesNotContain("POINT", turn.AssistantText);
    }

    [Fact]
    public async Task UnheardSentencesAreNotRemembered()
    {
        var voice = new FakeVoice();
        var queue = new SpeechPlaybackQueue();
        var memory = new ConversationMemory();
        var replyId = Guid.NewGuid();
        memory.BeginReply(replyId, "explain");
        var started = new TaskCompletionSource();
        queue.SegmentStarted += _ => started.TrySetResult();

        using (var choreographer = new ReplyChoreographer(queue, voice, memory, replyId, _ => { }))
        {
            choreographer.Handle(new ResponseSegment.Speech("this will hang."));
            choreographer.Handle(new ResponseSegment.Speech("this is never heard."));
            await started.Task.WaitAsync(Patience);
            queue.StopAll();
        }

        memory.FinishReply(replyId, interrupted: true);
        var turn = Assert.Single(memory.Turns);
        Assert.DoesNotContain("never heard", turn.AssistantText);
        Assert.Contains("interrupted", turn.AssistantText);
    }

    [Fact]
    public void TrailingAndBackToBackTagsStillPoint()
    {
        var voice = new FakeVoice();
        var queue = new SpeechPlaybackQueue();
        var pointed = new List<string?>();
        using var choreographer = new ReplyChoreographer(queue, voice, new ConversationMemory(), Guid.NewGuid(), tag => pointed.Add(tag.Label));

        choreographer.Handle(new ResponseSegment.Pointing(new PointingTag(1, 1, "first", null)));
        choreographer.Handle(new ResponseSegment.Pointing(new PointingTag(2, 2, "second", null)));
        Assert.Equal(["first"], pointed);

        choreographer.Finish();
        Assert.Equal(["first", "second"], pointed);
        queue.StopAll();
    }
}
