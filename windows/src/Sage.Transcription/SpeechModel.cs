using System.Diagnostics;
using System.Security.Cryptography;

namespace Sage.Transcription;

public sealed record SpeechModelFiles(string Encoder, string Decoder, string Joiner, string Tokens);

/// <summary>
/// The speech model Sage downloads on first use: NVIDIA's streaming FastConformer
/// transducer for English (480 ms chunks, int8), packaged by sherpa-onnx. About 100 MB.
/// The archive is checked against a pinned SHA-256 before anything is unpacked.
/// </summary>
public static class SpeechModel
{
    public const string Name = "sherpa-onnx-nemo-streaming-fast-conformer-transducer-en-480ms-int8";

    public static readonly Uri DownloadUri =
        new($"https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/{Name}.tar.bz2");

    public const string Sha256 = "da93061cbf7b708b6b65976f70b29f519be29df750d8cdcabf98c65645930f13";

    /// <summary>The model's files inside <paramref name="modelsFolder"/>, or null if it isn't installed.</summary>
    public static SpeechModelFiles? Find(string modelsFolder)
    {
        string folder = Path.Combine(modelsFolder, Name);
        if (!Directory.Exists(folder)) return null;

        string? Pick(string prefix) => Directory.EnumerateFiles(folder, prefix + "*.onnx")
            .OrderBy(path => path.Contains(".int8.", StringComparison.Ordinal) ? 0 : 1)
            .FirstOrDefault();

        string tokens = Path.Combine(folder, "tokens.txt");
        return Pick("encoder") is { } encoder && Pick("decoder") is { } decoder && Pick("joiner") is { } joiner && File.Exists(tokens)
            ? new SpeechModelFiles(encoder, decoder, joiner, tokens)
            : null;
    }

    /// <summary>
    /// Downloads, verifies and unpacks the model into <paramref name="modelsFolder"/>.
    /// <paramref name="tarExecutable"/> must handle .tar.bz2; Windows 10 and later include one
    /// at %SystemRoot%\System32\tar.exe.
    /// </summary>
    public static async Task<SpeechModelFiles> InstallAsync(string modelsFolder, string tarExecutable, HttpClient http,
        IProgress<double>? progress = null, CancellationToken cancellationToken = default)
    {
        if (Find(modelsFolder) is { } existing) return existing;

        Directory.CreateDirectory(modelsFolder);
        string archive = Path.Combine(modelsFolder, Name + ".tar.bz2.download");
        string staging = Path.Combine(modelsFolder, Name + ".unpacking");
        try
        {
            await DownloadAsync(http, archive, progress, cancellationToken).ConfigureAwait(false);
            await VerifyAsync(archive, cancellationToken).ConfigureAwait(false);

            if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
            Directory.CreateDirectory(staging);
            await ExtractAsync(tarExecutable, archive, staging, cancellationToken).ConfigureAwait(false);

            string unpacked = Path.Combine(staging, Name);
            if (!Directory.Exists(unpacked)) throw new InvalidDataException("The speech model archive had an unexpected layout.");
            Directory.Move(unpacked, Path.Combine(modelsFolder, Name));
        }
        finally
        {
            if (File.Exists(archive)) File.Delete(archive);
            if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
        }

        return Find(modelsFolder) ?? throw new InvalidDataException("The speech model is missing files after unpacking.");
    }

    private static async Task DownloadAsync(HttpClient http, string destination, IProgress<double>? progress, CancellationToken cancellationToken)
    {
        using var response = await http.GetAsync(DownloadUri, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        long? total = response.Content.Headers.ContentLength;
        await using var source = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        await using var file = File.Create(destination);
        var buffer = new byte[81920];
        long written = 0;
        int read;
        while ((read = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
        {
            await file.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
            written += read;
            if (total > 0) progress?.Report((double)written / total.Value);
        }
    }

    private static async Task VerifyAsync(string archive, CancellationToken cancellationToken)
    {
        await using var file = File.OpenRead(archive);
        string actual = Convert.ToHexStringLower(await SHA256.HashDataAsync(file, cancellationToken).ConfigureAwait(false));
        if (actual != Sha256)
        {
            throw new InvalidDataException("The downloaded speech model didn't match its expected checksum, so it wasn't used.");
        }
    }

    private static async Task ExtractAsync(string tarExecutable, string archive, string destination, CancellationToken cancellationToken)
    {
        var start = new ProcessStartInfo(tarExecutable)
        {
            UseShellExecute = false,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (string argument in new[] { "-xjf", archive, "-C", destination }) start.ArgumentList.Add(argument);

        using var process = Process.Start(start) ?? throw new InvalidOperationException("Couldn't start tar to unpack the speech model.");
        string errors = await process.StandardError.ReadToEndAsync(cancellationToken).ConfigureAwait(false);
        await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        if (process.ExitCode != 0) throw new InvalidDataException($"Unpacking the speech model failed: {errors.Trim()}");
    }
}
