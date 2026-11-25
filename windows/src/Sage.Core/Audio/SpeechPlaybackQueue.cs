namespace Sage.Core.Audio;

/// <summary>A voice that can start producing audio for a sentence before it's played.</summary>
public interface ISpeechVoice
{
    /// <summary>Starts preparing audio right away. Disposing the result abandons it.</summary>
    IPreparedSpeech Prepare(string text);
}

public interface IPreparedSpeech : IDisposable
{
    string Text { get; }

    /// <summary>
    /// Plays the sentence, calling <paramref name="onStarted"/> when sound actually begins.
    /// Completes when the audio ends; throws <see cref="OperationCanceledException"/> when cancelled.
    /// </summary>
    Task PlayAsync(Action onStarted, CancellationToken cancellationToken);
}

/// <summary>
/// Plays reply sentences one after another, in order, while Claude is still writing the
/// rest. Ported from the Mac app's SpeechPlaybackQueue. Events fire on a background thread.
/// </summary>
public sealed class SpeechPlaybackQueue
{
    private readonly Lock _gate = new();
    private readonly Queue<(Guid Id, IPreparedSpeech Speech)> _queued = new();
    private CancellationTokenSource _generation = new();
    private Task? _loop;

    /// <summary>Fires with a sentence's ID the moment it starts playing.</summary>
    public event Action<Guid>? SegmentStarted;

    /// <summary>Fires only after a sentence finishes playing, never for abandoned audio.</summary>
    public event Action<Guid>? SegmentCompleted;

    /// <summary>A sentence couldn't be spoken. Playback moves on to the next one.</summary>
    public event Action<Guid, Exception>? SegmentFailed;

    /// <summary>True while anything is playing or waiting to play.</summary>
    public bool IsPlaying
    {
        get
        {
            lock (_gate) return _loop is not null;
        }
    }

    /// <summary>Adds a sentence to the end of the queue. Its audio starts preparing immediately.</summary>
    public void Enqueue(string text, Guid segmentId, ISpeechVoice voice)
    {
        var prepared = voice.Prepare(text);
        lock (_gate)
        {
            _queued.Enqueue((segmentId, prepared));
            if (_loop is null)
            {
                var token = _generation.Token;
                _loop = Task.Run(() => PlayUntilEmptyAsync(token));
            }
        }
    }

    /// <summary>Stops the current sentence and throws away everything queued.</summary>
    public void StopAll()
    {
        lock (_gate)
        {
            _generation.Cancel();
            _generation = new CancellationTokenSource();
            while (_queued.TryDequeue(out var abandoned)) abandoned.Speech.Dispose();
            _loop = null;
        }
    }

    /// <summary>Waits until every queued sentence has played or been stopped.</summary>
    public async Task WaitUntilFinishedAsync(CancellationToken cancellationToken = default)
    {
        while (true)
        {
            Task? loop;
            lock (_gate) loop = _loop;
            if (loop is null) return;
            await loop.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
    }

    private async Task PlayUntilEmptyAsync(CancellationToken token)
    {
        while (true)
        {
            (Guid Id, IPreparedSpeech Speech) next;
            lock (_gate)
            {
                // A stopped loop may already have been replaced by a newer one, so only a
                // loop that's still current clears the handle.
                if (token.IsCancellationRequested) return;
                if (!_queued.TryDequeue(out next))
                {
                    _loop = null;
                    return;
                }
            }

            using (next.Speech)
            {
                try
                {
                    await next.Speech.PlayAsync(() =>
                    {
                        if (!token.IsCancellationRequested) SegmentStarted?.Invoke(next.Id);
                    }, token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (token.IsCancellationRequested)
                {
                    return;
                }
                catch (Exception exception)
                {
                    if (!token.IsCancellationRequested) SegmentFailed?.Invoke(next.Id, exception);
                    continue;
                }
            }

            if (token.IsCancellationRequested) return;
            SegmentCompleted?.Invoke(next.Id);
        }
    }
}
