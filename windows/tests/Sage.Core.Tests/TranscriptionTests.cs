using System.Net;
using Sage.Transcription;

namespace Sage.Core.Tests;

public class TranscriptionTests
{
    private sealed class FixedHandler(byte[] body) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(body) });
    }

    private static string TempFolder()
    {
        string folder = Path.Combine(Path.GetTempPath(), "sage-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        return folder;
    }

    [Fact]
    public void CleanCollapsesWhitespace() =>
        Assert.Equal("what is this button", StreamingTranscriber.Clean("  what  is\tthis button \n"));

    [Fact]
    public void FindRequiresEveryFile()
    {
        string models = TempFolder();
        string folder = Path.Combine(models, SpeechModel.Name);
        Directory.CreateDirectory(folder);
        foreach (var name in new[] { "encoder.onnx", "encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx" })
        {
            File.WriteAllText(Path.Combine(folder, name), "");
        }

        Assert.Null(SpeechModel.Find(models));
        File.WriteAllText(Path.Combine(folder, "tokens.txt"), "");

        var files = SpeechModel.Find(models);
        Assert.NotNull(files);
        Assert.EndsWith("encoder.int8.onnx", files.Encoder);
        Directory.Delete(models, recursive: true);
    }

    [Fact]
    public async Task TamperedDownloadIsRejectedAndRemoved()
    {
        string models = TempFolder();
        using var http = new HttpClient(new FixedHandler("not the model"u8.ToArray()));

        var error = await Assert.ThrowsAsync<InvalidDataException>(() =>
            SpeechModel.InstallAsync(models, "/usr/bin/tar", http));

        Assert.Contains("checksum", error.Message);
        Assert.Empty(Directory.EnumerateFileSystemEntries(models));
        Directory.Delete(models, recursive: true);
    }

    /// <summary>
    /// Installs the real model archive and runs it on a real recording. Set
    /// SAGE_TEST_SPEECH_ARCHIVE to the downloaded .tar.bz2 and SAGE_TEST_SPEECH_WAV to a
    /// 16 kHz mono 16-bit WAV of someone saying "what is this button". Skipped (passes
    /// trivially) otherwise, as on CI, because the model is 100 MB.
    /// </summary>
    [Fact]
    public async Task RealModelInstallsAndTranscribesSpeech()
    {
        string? archive = Environment.GetEnvironmentVariable("SAGE_TEST_SPEECH_ARCHIVE");
        string? wav = Environment.GetEnvironmentVariable("SAGE_TEST_SPEECH_WAV");
        if (archive is null || wav is null) return;

        string models = TempFolder();
        using var http = new HttpClient(new FixedHandler(await File.ReadAllBytesAsync(archive)));
        string tar = OperatingSystem.IsWindows() ? Path.Combine(Environment.SystemDirectory, "tar.exe") : "/usr/bin/tar";
        var files = await SpeechModel.InstallAsync(models, tar, http);
        Assert.Equal(files, SpeechModel.Find(models));
        Assert.Equal([SpeechModel.Name], Directory.EnumerateFileSystemEntries(models).Select(Path.GetFileName));
        using var transcriber = new StreamingTranscriber(files);
        float[] samples = ReadPcm16Wav(wav);

        using var session = transcriber.Begin();
        // Feed it the way the microphone does: 100 ms at a time.
        for (int offset = 0; offset < samples.Length; offset += 1600)
        {
            session.Accept(samples.AsSpan(offset, Math.Min(1600, samples.Length - offset)));
        }

        // Let decoding catch up the way it does while someone is still talking.
        await Task.Delay(samples.Length * 1000 / StreamingTranscriber.SampleRate);
        var releaseToText = System.Diagnostics.Stopwatch.StartNew();
        string text = (await session.FinishAsync()).ToLowerInvariant();
        Console.WriteLine($"transcript: {text} ({releaseToText.ElapsedMilliseconds} ms after release)");
        Assert.Contains("button", text);
        Assert.Contains("what", text);
        Directory.Delete(models, recursive: true);
    }

    private static float[] ReadPcm16Wav(string path)
    {
        byte[] bytes = File.ReadAllBytes(path);
        int offset = 12;
        while (offset + 8 <= bytes.Length)
        {
            string id = System.Text.Encoding.ASCII.GetString(bytes, offset, 4);
            int size = BitConverter.ToInt32(bytes, offset + 4);
            if (id == "data")
            {
                var samples = new float[size / 2];
                for (int i = 0; i < samples.Length; i++) samples[i] = BitConverter.ToInt16(bytes, offset + 8 + i * 2) / 32768f;
                return samples;
            }

            offset += 8 + size + (size & 1);
        }

        throw new InvalidDataException("No data chunk in WAV.");
    }
}
