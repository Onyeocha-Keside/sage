using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Sage.Core.Conversation;

namespace Sage.Core.Networking;

/// <summary>
/// Streams Claude's reply from the Sage Worker over Server-Sent Events. The Worker holds
/// the Anthropic key and decides the model, limits and system prompt; this client only
/// carries the user's individual Sage access token.
/// </summary>
public sealed partial class SageWorkerClient : IDisposable
{
    /// <summary>Give up after this long without a byte from the server, like the Mac app.</summary>
    public static readonly TimeSpan IdleTimeout = TimeSpan.FromSeconds(30);

    /// <summary>Upper bound for a whole reply.</summary>
    public static readonly TimeSpan TotalTimeout = TimeSpan.FromSeconds(120);

    private const int MaxErrorBodyBytes = 4096;

    private readonly HttpClient _http;
    private readonly Uri _baseUri;
    private readonly string _accessToken;
    private readonly TimeSpan _idleTimeout;

    public SageWorkerClient(Uri baseUri, string accessToken, HttpMessageHandler? handler = null, TimeSpan? idleTimeout = null)
    {
        _baseUri = ValidateBaseUri(baseUri.ToString())
            ?? throw new ArgumentException("The Worker address must be https, or http on localhost.", nameof(baseUri));
        if (!IsAccessTokenFormat(accessToken))
        {
            throw new ArgumentException("That doesn't look like a Sage access token.", nameof(accessToken));
        }

        _accessToken = accessToken;
        _idleTimeout = idleTimeout ?? IdleTimeout;
        // No cookies or caching: screenshots and replies are never kept on disk.
        _http = new HttpClient(handler ?? new SocketsHttpHandler { UseCookies = false }, disposeHandler: true)
        {
            Timeout = Timeout.InfiniteTimeSpan,
        };
    }

    /// <summary>
    /// The base address with no trailing slash. Credentials may travel over plain HTTP only
    /// to an explicit local development host. Returns null when the address is unsafe.
    /// </summary>
    public static Uri? ValidateBaseUri(string? rawValue)
    {
        var trimmed = rawValue?.Trim().TrimEnd('/');
        if (string.IsNullOrEmpty(trimmed) || !Uri.TryCreate(trimmed, UriKind.Absolute, out var uri)) return null;
        if (!string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment)) return null;
        if (string.IsNullOrEmpty(uri.Host)) return null;

        bool isLocalHost = uri.IsLoopback && uri.Host is "localhost" or "127.0.0.1" or "[::1]" or "::1";
        bool allowed = uri.Scheme == Uri.UriSchemeHttps || (uri.Scheme == Uri.UriSchemeHttp && isLocalHost);
        return allowed ? new Uri(trimmed + "/") : null;
    }

    public static bool IsAccessTokenFormat(string? token) => token is not null && AccessTokenPattern().IsMatch(token);

    /// <summary>Opens a connection early so the request carrying screenshots skips the TLS handshake.</summary>
    public async Task WarmUpAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(10));
            using var response = await _http.GetAsync(new Uri(_baseUri, "health"), timeout.Token).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is HttpRequestException or OperationCanceledException)
        {
            // The response doesn't matter. The open connection is the point.
        }
    }

    /// <summary>
    /// Sends the question and yields each piece of the reply as it streams in.
    /// Throws <see cref="SageApiException"/> on HTTP, timeout or stream errors, and
    /// <see cref="OperationCanceledException"/> only when the caller cancels.
    /// </summary>
    public async IAsyncEnumerable<ClaudeStreamEvent> StreamReplyAsync(
        ConversationMode mode,
        IEnumerable<ConversationTurn> history,
        IReadOnlyList<ScreenshotForClaude> screenshots,
        string userText,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        using var total = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        total.CancelAfter(TotalTimeout);
        using var idle = CancellationTokenSource.CreateLinkedTokenSource(total.Token);
        idle.CancelAfter(_idleTimeout);

        using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(_baseUri, "chat"))
        {
            Content = new ByteArrayContent(ChatRequest.BuildBody(mode, history, screenshots, userText)),
        };
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _accessToken);
        request.Headers.Accept.ParseAdd("text/event-stream");

        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, idle.Token).ConfigureAwait(false);
        }
        catch (Exception exception) when (TranslateFailure(exception, cancellationToken) is { } failure)
        {
            throw failure;
        }

        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                throw new SageApiException(await DescribeErrorAsync(response, idle.Token).ConfigureAwait(false),
                    (int)response.StatusCode);
            }

            if (response.Content.Headers.ContentType?.MediaType?.Equals("text/event-stream", StringComparison.OrdinalIgnoreCase) != true)
            {
                throw new SageApiException("The Worker did not return a reply stream.");
            }

            var decoder = new ClaudeStreamDecoder();
            using var reader = new StreamReader(
                await response.Content.ReadAsStreamAsync(idle.Token).ConfigureAwait(false), Encoding.UTF8);

            while (true)
            {
                idle.CancelAfter(_idleTimeout);
                string? line;
                try
                {
                    line = await reader.ReadLineAsync(idle.Token).ConfigureAwait(false);
                }
                catch (Exception exception) when (TranslateFailure(exception, cancellationToken) is { } failure)
                {
                    throw failure;
                }

                if (line is null) break;
                foreach (var streamEvent in decoder.Consume(line))
                {
                    yield return streamEvent;
                }

                if (decoder.HasCompleted) yield break;
            }

            cancellationToken.ThrowIfCancellationRequested();
            decoder.Finish();
        }
    }

    public void Dispose() => _http.Dispose();

    /// <summary>Caller cancellation passes through; everything else becomes a plain-language error.</summary>
    private static Exception? TranslateFailure(Exception exception, CancellationToken callerToken)
    {
        if (callerToken.IsCancellationRequested) return null;
        return exception switch
        {
            OperationCanceledException => new SageApiException("Sage stopped hearing from the server. Try again."),
            HttpRequestException or IOException => new SageApiException("Sage couldn't reach the server. Check your connection."),
            _ => null,
        };
    }

    private static async Task<string> DescribeErrorAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        int status = (int)response.StatusCode;
        string? detail = null;
        try
        {
            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            var buffer = new byte[MaxErrorBodyBytes];
            int length = 0, read;
            while (length < buffer.Length && (read = await stream.ReadAsync(buffer.AsMemory(length), cancellationToken).ConfigureAwait(false)) > 0)
            {
                length += read;
            }

            using var document = JsonDocument.Parse(buffer.AsMemory(0, length));
            if (document.RootElement.ValueKind == JsonValueKind.Object
                && document.RootElement.TryGetProperty("error", out var error)
                && error.ValueKind == JsonValueKind.String)
            {
                detail = error.GetString();
            }
        }
        catch (Exception exception) when (exception is JsonException or IOException or HttpRequestException or OperationCanceledException)
        {
            // Fall back to the status code alone.
        }

        return string.IsNullOrWhiteSpace(detail) ? $"Worker error {status}" : $"Worker error {status}: {detail}";
    }

    [GeneratedRegex("^sage_[a-f0-9]{64}$")]
    private static partial Regex AccessTokenPattern();
}
