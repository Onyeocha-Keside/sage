using Sage.Transcription;

namespace Sage.Windows;

/// <summary>
/// Push-to-talk: holding the shortcut stops any reply and opens the microphone; letting go
/// closes it, finishes the on-device transcript and asks Claude. Audio never leaves the PC.
/// </summary>
internal sealed class VoiceSession(StreamingTranscriber transcriber, AskSession ask) : IDisposable
{
    private static readonly TimeSpan MinimumHold = TimeSpan.FromMilliseconds(250);

    private readonly Lock _gate = new();
    private MicrophoneCapture? _microphone;
    private StreamingTranscriber.TranscriptionSession? _transcription;

    public void Pressed()
    {
        ask.Interrupt();
        lock (_gate)
        {
            if (_microphone is not null) return;
            var transcription = transcriber.Begin();
            var microphone = new MicrophoneCapture(samples => transcription.Accept(samples));
            try
            {
                microphone.Start();
            }
            catch (InvalidOperationException exception)
            {
                microphone.Dispose();
                transcription.Dispose();
                Console.WriteLine($"microphone: {exception.Message}");
                return;
            }

            _transcription = transcription;
            _microphone = microphone;
        }

        Console.WriteLine("listening...");
    }

    public void Released()
    {
        MicrophoneCapture? microphone;
        StreamingTranscriber.TranscriptionSession? transcription;
        lock (_gate)
        {
            microphone = _microphone;
            transcription = _transcription;
            _microphone = null;
            _transcription = null;
        }

        if (microphone is null || transcription is null) return;
        // Closing the device flushes the last partial buffer into the transcriber.
        microphone.Stop();
        float peak = microphone.PeakLevel;
        microphone.Dispose();

        _ = Task.Run(async () =>
        {
            using (transcription)
            {
                var heard = transcription.AudioDuration;
                string text = await transcription.FinishAsync();
                if (heard < MinimumHold) return;
                if (text.Length == 0)
                {
                    Console.WriteLine(peak < 0.01f
                        ? "(no sound from the microphone. Check it's not muted, and Settings > Privacy & security > Microphone.)"
                        : "(didn't catch that)");
                    return;
                }

                ask.Start(text);
            }
        });
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _microphone?.Dispose();
            _transcription?.Dispose();
            _microphone = null;
            _transcription = null;
        }
    }
}
