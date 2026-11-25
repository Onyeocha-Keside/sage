using System.Globalization;
using Sage.Core.Audio;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Media.SpeechSynthesis;

namespace Sage.Windows;

/// <summary>
/// Speaks with the voices built into Windows, so no second paid API is involved and the
/// text never leaves the PC. Prefers a voice in the user's display language.
/// </summary>
internal sealed class WindowsSpeechVoice : ISpeechVoice, IDisposable
{
    private readonly SpeechSynthesizer _synthesizer = new();
    // SpeechSynthesizer isn't documented as safe for overlapping calls.
    private readonly SemaphoreSlim _synthesisGate = new(1, 1);

    public WindowsSpeechVoice()
    {
        var culture = CultureInfo.CurrentUICulture;
        var voices = SpeechSynthesizer.AllVoices;
        _synthesizer.Voice =
            voices.FirstOrDefault(v => v.Language.Equals(culture.Name, StringComparison.OrdinalIgnoreCase))
            ?? voices.FirstOrDefault(v => v.Language.StartsWith(culture.TwoLetterISOLanguageName + "-", StringComparison.OrdinalIgnoreCase))
            ?? SpeechSynthesizer.DefaultVoice;
    }

    public string VoiceName => _synthesizer.Voice.DisplayName;

    public IPreparedSpeech Prepare(string text) => new PreparedSpeech(this, text);

    public void Dispose()
    {
        _synthesizer.Dispose();
        _synthesisGate.Dispose();
    }

    private async Task<SpeechSynthesisStream> SynthesizeAsync(string text, CancellationToken cancellationToken)
    {
        await _synthesisGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await _synthesizer.SynthesizeTextToStreamAsync(text).AsTask(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _synthesisGate.Release();
        }
    }

    private sealed class PreparedSpeech : IPreparedSpeech
    {
        private readonly CancellationTokenSource _preparation = new();
        private readonly Task<SpeechSynthesisStream> _audio;

        public PreparedSpeech(WindowsSpeechVoice voice, string text)
        {
            Text = text;
            _audio = voice.SynthesizeAsync(text, _preparation.Token);
        }

        public string Text { get; }

        public async Task PlayAsync(Action onStarted, CancellationToken cancellationToken)
        {
            var stream = await _audio.WaitAsync(cancellationToken).ConfigureAwait(false);
            using var player = new MediaPlayer
            {
                AudioCategory = MediaPlayerAudioCategory.Speech,
                AutoPlay = false,
            };
            var finished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            int started = 0;
            player.MediaEnded += (_, _) => finished.TrySetResult();
            player.MediaFailed += (_, failure) =>
                finished.TrySetException(new InvalidOperationException($"Windows couldn't play speech: {failure.Error}"));
            player.PlaybackSession.PlaybackStateChanged += (session, _) =>
            {
                if (session.PlaybackState == MediaPlaybackState.Playing && Interlocked.Exchange(ref started, 1) == 0)
                {
                    onStarted();
                }
            };

            player.Source = MediaSource.CreateFromStream(stream, stream.ContentType);
            using (cancellationToken.Register(() =>
                   {
                       player.Pause();
                       finished.TrySetCanceled(cancellationToken);
                   }))
            {
                player.Play();
                await finished.Task.ConfigureAwait(false);
            }
        }

        public void Dispose()
        {
            _preparation.Cancel();
            // Release the audio once synthesis settles, whether or not it was played.
            _audio.ContinueWith(static task =>
            {
                if (task.IsCompletedSuccessfully) task.Result.Dispose();
            }, TaskScheduler.Default);
            _preparation.Dispose();
        }
    }
}
