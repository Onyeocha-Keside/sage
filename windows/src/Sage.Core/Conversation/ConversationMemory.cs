namespace Sage.Core.Conversation;

/// <summary>One earlier exchange, replayed as text so Claude remembers the conversation.</summary>
public sealed record ConversationTurn(string UserText, string AssistantText);

/// <summary>Session-only text history. Screenshots and audio are never retained here.</summary>
public sealed class ConversationMemory
{
    private sealed class PendingReply(Guid id, string userText)
    {
        public Guid Id { get; } = id;
        public string UserText { get; } = userText;
        public List<(Guid Id, string Text)> Sentences { get; } = [];
        public HashSet<Guid> Completed { get; } = [];
    }

    private readonly List<ConversationTurn> _turns = [];
    private readonly int _maximumTurns;
    private PendingReply? _pending;

    public ConversationMemory(int maximumTurns = 10)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maximumTurns);
        _maximumTurns = maximumTurns;
    }

    public IReadOnlyList<ConversationTurn> Turns => _turns;

    public void BeginReply(Guid id, string userText) => _pending = new PendingReply(id, userText);

    public void RegisterSentence(Guid replyId, Guid sentenceId, string text)
    {
        if (_pending?.Id == replyId) _pending.Sentences.Add((sentenceId, text));
    }

    public void CompletedSentence(Guid sentenceId)
    {
        if (_pending is { } reply && reply.Sentences.Any(sentence => sentence.Id == sentenceId))
        {
            reply.Completed.Add(sentenceId);
        }
    }

    /// <summary>Only successful playback counts. Unfinished audio is never replayed as heard text.</summary>
    public void FinishReply(Guid id, bool interrupted)
    {
        if (_pending is not { } reply || reply.Id != id) return;
        _pending = null;

        var delivered = reply.Sentences.Where(s => reply.Completed.Contains(s.Id)).Select(s => s.Text).ToList();
        if (interrupted || delivered.Count != reply.Sentences.Count)
        {
            delivered.Add("[Reply interrupted or audio incomplete; only completed speech is retained.]");
        }

        string text = string.Join(' ', delivered);
        if (text.Length > 0) Remember(reply.UserText, text);
    }

    public void Remember(string userText, string assistantText)
    {
        _turns.Add(new ConversationTurn(userText, assistantText));
        if (_turns.Count > _maximumTurns) _turns.RemoveRange(0, _turns.Count - _maximumTurns);
    }
}
