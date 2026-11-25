using System.Threading.Channels;
using SherpaOnnx;

namespace Sage.Transcription;

/// <summary>
/// Streaming speech recognizer. Audio is decoded while the user is still holding the
/// shortcut, so the transcript is ready almost as soon as they let go.
/// Load it once at startup; loading the model takes about a second.
/// </summary>
public sealed class StreamingTranscriber : IDisposable
{
    public const int SampleRate = 16000;

    // A streaming encoder drops the first word if speech starts on the very first frame,
    // which push-to-talk makes common, and a transducer emits its last words only after it
    // sees some audio past them. Silence on both ends fixes both.
    private static readonly float[] LeadingSilence = new float[SampleRate * 3 / 10];
    private static readonly float[] TrailingSilence = new float[SampleRate * 12 / 10];

    private readonly OnlineRecognizer _recognizer;

    public StreamingTranscriber(SpeechModelFiles model, int threads = 2)
    {
        var config = new OnlineRecognizerConfig();
        config.FeatConfig.SampleRate = SampleRate;
        config.FeatConfig.FeatureDim = 80;
        config.ModelConfig.Transducer.Encoder = model.Encoder;
        config.ModelConfig.Transducer.Decoder = model.Decoder;
        config.ModelConfig.Transducer.Joiner = model.Joiner;
        config.ModelConfig.Tokens = model.Tokens;
        config.ModelConfig.NumThreads = threads;
        config.ModelConfig.Provider = "cpu";
        config.DecodingMethod = "greedy_search";
        // Push-to-talk decides when a turn ends, not silence detection.
        config.EnableEndpoint = 0;
        _recognizer = new OnlineRecognizer(config);
    }

    public TranscriptionSession Begin() => new(_recognizer);

    public void Dispose() => _recognizer.Dispose();

    /// <summary>
    /// One hold of the shortcut. <see cref="Accept"/> may be called from the audio thread;
    /// decoding happens on a background task so audio capture never waits on the model.
    /// </summary>
    public sealed class TranscriptionSession : IDisposable
    {
        private readonly OnlineRecognizer _recognizer;
        private readonly OnlineStream _stream;
        private readonly Channel<float[]> _audio = Channel.CreateUnbounded<float[]>(new() { SingleReader = true });
        private readonly Task _decoding;
        private volatile string _partial = "";
        private long _samples;

        internal TranscriptionSession(OnlineRecognizer recognizer)
        {
            _recognizer = recognizer;
            _stream = recognizer.CreateStream();
            _audio.Writer.TryWrite(LeadingSilence);
            _decoding = Task.Run(DecodeAsync);
        }

        /// <summary>The words recognized so far.</summary>
        public string Partial => _partial;

        public TimeSpan AudioDuration => TimeSpan.FromSeconds(Interlocked.Read(ref _samples) / (double)SampleRate);

        /// <summary>Adds 16 kHz mono samples in the range -1 to 1.</summary>
        public void Accept(ReadOnlySpan<float> samples)
        {
            if (samples.IsEmpty) return;
            Interlocked.Add(ref _samples, samples.Length);
            _audio.Writer.TryWrite(samples.ToArray());
        }

        /// <summary>Call after the shortcut is released. Returns the final transcript, trimmed.</summary>
        public async Task<string> FinishAsync()
        {
            _audio.Writer.TryWrite(TrailingSilence);
            _audio.Writer.TryComplete();
            await _decoding.ConfigureAwait(false);
            _stream.InputFinished();
            DecodeReady();
            return Clean(_recognizer.GetResult(_stream).Text);
        }

        public void Dispose()
        {
            _audio.Writer.TryComplete();
            // Don't free the native stream while the decoder might still be using it.
            _decoding.ContinueWith(_ => _stream.Dispose(), TaskScheduler.Default);
        }

        private async Task DecodeAsync()
        {
            await foreach (var chunk in _audio.Reader.ReadAllAsync().ConfigureAwait(false))
            {
                _stream.AcceptWaveform(SampleRate, chunk);
                DecodeReady();
                _partial = Clean(_recognizer.GetResult(_stream).Text);
            }
        }

        private void DecodeReady()
        {
            while (_recognizer.IsReady(_stream)) _recognizer.Decode(_stream);
        }
    }

    /// <summary>Collapses spacing. Some models emit all caps; Claude reads either fine.</summary>
    public static string Clean(string text) =>
        string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
}
