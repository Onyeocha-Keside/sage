using Sage.Core.Audio;
using Sage.Core.Conversation;
using Sage.Core.Geometry;
using Sage.Core.Networking;
using Sage.Core.Reply;

namespace Sage.Windows;

/// <summary>
/// One full turn without the microphone: capture every monitor, send the question to
/// the Worker, then speak the reply and fly the cursor as each sentence starts.
/// Starting a new turn interrupts the one still playing.
/// </summary>
internal sealed class AskSession(SageWorkerClient client, ISpeechVoice voice, Action<PointingTarget> flyTo) : IDisposable
{
    private readonly ScreenCapturer _capturer = new();
    private readonly SpeechPlaybackQueue _queue = new();
    private readonly ConversationMemory _memory = new();
    private readonly Lock _gate = new();
    private CancellationTokenSource? _current;

    public void Start(string question)
    {
        CancellationTokenSource turn;
        lock (_gate)
        {
            _current?.Cancel();
            _queue.StopAll();
            _current = turn = new CancellationTokenSource();
        }

        _ = Task.Run(() => RunTurnAsync(question, turn.Token));
    }

    public void Dispose()
    {
        lock (_gate) _current?.Cancel();
        _queue.StopAll();
        client.Dispose();
    }

    private async Task RunTurnAsync(string question, CancellationToken cancellationToken)
    {
        var replyId = Guid.NewGuid();
        bool interrupted = true;
        try
        {
            var monitors = Monitors.EnumerateCursorScreenFirst();
            var frames = new List<ScreenshotFrame>();
            var screenshots = new List<ScreenshotForClaude>();
            for (int i = 0; i < monitors.Count; i++)
            {
                var capture = await _capturer.CaptureAsync(monitors[i], isCursorScreen: i == 0);
                frames.Add(capture.Frame);
                screenshots.Add(new ScreenshotForClaude(capture.Jpeg,
                    ChatRequest.ScreenLabel(i, monitors.Count, i == 0, capture.Frame.ImageWidth, capture.Frame.ImageHeight)));
            }

            cancellationToken.ThrowIfCancellationRequested();
            List<ConversationTurn> history;
            lock (_memory)
            {
                history = [.. _memory.Turns];
                _memory.BeginReply(replyId, question);
            }

            Console.WriteLine($"you: {question}");
            Console.Write("sage: ");
            using var choreographer = new ReplyChoreographer(_queue, voice, _memory, replyId, tag =>
            {
                if (tag.Resolve(frames) is { } target) flyTo(target);
            });
            var segmenter = new StreamingResponseSegmenter();
            bool refused = false;
            await foreach (var streamEvent in client.StreamReplyAsync(ConversationMode.Companion, history, screenshots, question, cancellationToken))
            {
                switch (streamEvent)
                {
                    case ClaudeStreamEvent.TextDelta delta:
                        Console.Write(delta.Text);
                        foreach (var segment in segmenter.Append(delta.Text)) choreographer.Handle(segment);
                        break;
                    case ClaudeStreamEvent.Refusal:
                        refused = true;
                        break;
                }
            }

            foreach (var segment in segmenter.Finish()) choreographer.Handle(segment);
            choreographer.Finish();
            Console.WriteLine();
            if (refused) Console.WriteLine("(Claude declined to answer that one.)");
            if (choreographer.WantsFollowAlong)
            {
                Console.WriteLine($"(Claude wants to follow along{(choreographer.NextStepHint is { } hint ? $", next: {hint}" : "")}. Hold Ctrl + Win to continue.)");
            }

            await _queue.WaitUntilFinishedAsync(cancellationToken);
            interrupted = cancellationToken.IsCancellationRequested;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            Console.WriteLine();
            Console.WriteLine("(interrupted)");
        }
        catch (SageApiException exception)
        {
            Console.WriteLine();
            Console.WriteLine($"error: {exception.Message}");
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            Console.WriteLine();
            Console.WriteLine($"error: {exception.GetType().Name}: {exception.Message}");
        }
        finally
        {
            lock (_memory) _memory.FinishReply(replyId, interrupted);
        }
    }
}
