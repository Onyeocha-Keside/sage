using System.Collections.Concurrent;
using Sage.Core.Conversation;
using Sage.Core.Audio;

namespace Sage.Core.Reply;

/// <summary>
/// Turns one reply's segments into speech and pointing. A pointing tag applies to the
/// sentence right after it, so the cursor flies there as that sentence starts playing.
/// Only sentences that finish playing count as heard in <see cref="ConversationMemory"/>;
/// callers must lock on the memory object while they use it during a reply.
/// </summary>
public sealed class ReplyChoreographer : IDisposable
{
    private readonly SpeechPlaybackQueue _queue;
    private readonly ISpeechVoice _voice;
    private readonly ConversationMemory _memory;
    private readonly Guid _replyId;
    private readonly Action<PointingTag> _pointAt;
    private readonly ConcurrentDictionary<Guid, PointingTag> _tagsBySentence = new();
    private PointingTag? _pendingTag;

    public ReplyChoreographer(SpeechPlaybackQueue queue, ISpeechVoice voice, ConversationMemory memory,
        Guid replyId, Action<PointingTag> pointAt)
    {
        _queue = queue;
        _voice = voice;
        _memory = memory;
        _replyId = replyId;
        _pointAt = pointAt;
        _queue.SegmentStarted += OnSegmentStarted;
        _queue.SegmentCompleted += OnSegmentCompleted;
    }

    /// <summary>Claude asked to see the result of the user's next action.</summary>
    public bool WantsFollowAlong { get; private set; }

    /// <summary>Visible text of the control Claude expects the user to need next.</summary>
    public string? NextStepHint { get; private set; }

    /// <summary>Everything that was sent to the voice, in order.</summary>
    public List<string> SpokenText { get; } = [];

    public void Handle(ResponseSegment segment)
    {
        switch (segment)
        {
            case ResponseSegment.Speech speech:
                var sentenceId = Guid.NewGuid();
                lock (_memory) _memory.RegisterSentence(_replyId, sentenceId, speech.Text);
                if (_pendingTag is { } tag)
                {
                    _tagsBySentence[sentenceId] = tag;
                    _pendingTag = null;
                }

                SpokenText.Add(speech.Text);
                _queue.Enqueue(speech.Text, sentenceId, _voice);
                break;
            case ResponseSegment.Pointing pointing:
                // Two tags in a row: the first has no sentence of its own, so go there now.
                if (_pendingTag is { } skipped) _pointAt(skipped);
                _pendingTag = pointing.Tag;
                break;
            case ResponseSegment.FollowAlong:
                WantsFollowAlong = true;
                break;
            case ResponseSegment.NextStepHint hint:
                NextStepHint = hint.Text;
                break;
        }
    }

    /// <summary>Call when the stream ends. A trailing tag with no sentence after it points right away.</summary>
    public void Finish()
    {
        if (_pendingTag is { } tag) _pointAt(tag);
        _pendingTag = null;
    }

    public void Dispose()
    {
        _queue.SegmentStarted -= OnSegmentStarted;
        _queue.SegmentCompleted -= OnSegmentCompleted;
    }

    private void OnSegmentStarted(Guid sentenceId)
    {
        if (_tagsBySentence.TryRemove(sentenceId, out var tag)) _pointAt(tag);
    }

    private void OnSegmentCompleted(Guid sentenceId)
    {
        lock (_memory) _memory.CompletedSentence(sentenceId);
    }
}
