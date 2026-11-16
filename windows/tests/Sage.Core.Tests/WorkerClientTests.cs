using System.Net;
using System.Text;
using System.Text.Json;
using Sage.Core.Conversation;
using Sage.Core.Networking;

namespace Sage.Core.Tests;

public class WorkerClientTests
{
    private static readonly string Token = "sage_" + new string('a', 64);
    private static readonly Uri Worker = new("https://sage-api.example.workers.dev");

    private sealed class FakeHandler(Func<HttpRequestMessage, Task<HttpResponseMessage>> respond) : HttpMessageHandler
    {
        public List<(HttpRequestMessage Request, string Body)> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(cancellationToken);
            Requests.Add((request, body));
            return await respond(request);
        }
    }

    /// <summary>A stream that sends some bytes, then never sends another.</summary>
    private sealed class StallingStream(byte[] prefix) : Stream
    {
        private int _position;
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            if (_position < prefix.Length)
            {
                int count = Math.Min(buffer.Length, prefix.Length - _position);
                prefix.AsMemory(_position, count).CopyTo(buffer);
                _position += count;
                return count;
            }

            await Task.Delay(Timeout.Infinite, cancellationToken);
            return 0;
        }

        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    private static HttpResponseMessage Sse(string body) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(body, Encoding.UTF8, "text/event-stream"),
    };

    private static string Delta(string text) =>
        "data: " + JsonSerializer.Serialize(new { type = "content_block_delta", delta = new { type = "text_delta", text } }) + "\n\n";

    private const string Stop = "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n";

    private static async Task<List<ClaudeStreamEvent>> Collect(SageWorkerClient client, CancellationToken token = default)
    {
        var events = new List<ClaudeStreamEvent>();
        await foreach (var e in client.StreamReplyAsync(ConversationMode.Companion, [], [], "hi", token))
        {
            events.Add(e);
        }

        return events;
    }

    [Fact]
    public void BodyMatchesWorkerContract()
    {
        var history = new[] { new ConversationTurn("what's this", "that's your inbox.") };
        var screenshots = new[]
        {
            new ScreenshotForClaude([1, 2, 3], ChatRequest.ScreenLabel(0, 2, true, 1280, 720)),
            new ScreenshotForClaude([4, 5], ChatRequest.ScreenLabel(1, 2, false, 1280, 800)),
        };

        using var json = JsonDocument.Parse(ChatRequest.BuildBody(ConversationMode.Onboarding, history, screenshots, "and this?"));
        var root = json.RootElement;
        Assert.Equal("onboarding", root.GetProperty("mode").GetString());
        Assert.Equal("windows", root.GetProperty("platform").GetString());

        var messages = root.GetProperty("messages");
        Assert.Equal(3, messages.GetArrayLength());
        Assert.Equal("user", messages[0].GetProperty("role").GetString());
        Assert.Equal("what's this", messages[0].GetProperty("content").GetString());
        Assert.Equal("assistant", messages[1].GetProperty("role").GetString());

        var content = messages[2].GetProperty("content");
        Assert.Equal(5, content.GetArrayLength());
        var source = content[0].GetProperty("source");
        Assert.Equal("base64", source.GetProperty("type").GetString());
        Assert.Equal("image/jpeg", source.GetProperty("media_type").GetString());
        Assert.Equal("AQID", source.GetProperty("data").GetString());
        Assert.Equal("screen 1 of 2 — cursor is on this screen (primary focus) (image dimensions: 1280x720 pixels)",
            content[1].GetProperty("text").GetString());
        Assert.Equal("screen 2 of 2 — secondary screen (image dimensions: 1280x800 pixels)", content[3].GetProperty("text").GetString());
        Assert.Equal("and this?", content[4].GetProperty("text").GetString());
    }

    [Fact]
    public void SingleScreenLabelMatchesMac() =>
        Assert.Equal("user's screen (cursor is here) (image dimensions: 1280x800 pixels)", ChatRequest.ScreenLabel(0, 1, true, 1280, 800));

    [Theory]
    [InlineData("https://sage-api.example.workers.dev", "https://sage-api.example.workers.dev/")]
    [InlineData(" https://sage-api.example.workers.dev/ ", "https://sage-api.example.workers.dev/")]
    [InlineData("http://localhost:8787", "http://localhost:8787/")]
    [InlineData("http://127.0.0.1:8787", "http://127.0.0.1:8787/")]
    [InlineData("http://example.com", null)]
    [InlineData("http://localhost.example.com", null)]
    [InlineData("https://user:pass@example.com", null)]
    [InlineData("https://example.com?x=1", null)]
    [InlineData("ftp://example.com", null)]
    [InlineData("", null)]
    public void WorkerAddressesAreValidated(string raw, string? expected) =>
        Assert.Equal(expected, SageWorkerClient.ValidateBaseUri(raw)?.ToString());

    [Fact]
    public void RejectsMalformedTokens()
    {
        Assert.Throws<ArgumentException>(() => new SageWorkerClient(Worker, "sk-ant-api03-not-a-sage-token"));
        Assert.Throws<ArgumentException>(() => new SageWorkerClient(Worker, "sage_" + new string('A', 64)));
    }

    [Fact]
    public async Task StreamsTextAndSendsBearerToken()
    {
        var handler = new FakeHandler(_ => Task.FromResult(Sse(Delta("yep, ") + "event: ping\ndata: {\"type\":\"ping\"}\n\n" + Delta("it's up top.") + Stop)));
        using var client = new SageWorkerClient(Worker, Token, handler);

        var events = await Collect(client);

        Assert.Equal(["yep, ", "it's up top."], events.OfType<ClaudeStreamEvent.TextDelta>().Select(e => e.Text));
        var (request, body) = Assert.Single(handler.Requests);
        Assert.Equal(HttpMethod.Post, request.Method);
        Assert.Equal("https://sage-api.example.workers.dev/chat", request.RequestUri!.ToString());
        Assert.Equal("Bearer", request.Headers.Authorization!.Scheme);
        Assert.Equal(Token, request.Headers.Authorization.Parameter);
        Assert.Contains("\"platform\":\"windows\"", body);
    }

    [Fact]
    public async Task WorkerErrorsCarryStatusAndMessage()
    {
        var handler = new FakeHandler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.TooManyRequests)
        {
            Content = new StringContent("{\"error\":\"Too many requests, slow down a little\"}", Encoding.UTF8, "application/json"),
        }));
        using var client = new SageWorkerClient(Worker, Token, handler);

        var error = await Assert.ThrowsAsync<SageApiException>(() => Collect(client));
        Assert.Equal(429, error.HttpStatusCode);
        Assert.Equal("Worker error 429: Too many requests, slow down a little", error.Message);
    }

    [Fact]
    public async Task NonJsonErrorFallsBackToStatus()
    {
        var handler = new FakeHandler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.BadGateway)
        {
            Content = new StringContent("<html>bad gateway</html>"),
        }));
        using var client = new SageWorkerClient(Worker, Token, handler);

        var error = await Assert.ThrowsAsync<SageApiException>(() => Collect(client));
        Assert.Equal("Worker error 502", error.Message);
    }

    [Fact]
    public async Task RejectsNonStreamSuccess()
    {
        var handler = new FakeHandler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("{}", Encoding.UTF8, "application/json"),
        }));
        using var client = new SageWorkerClient(Worker, Token, handler);

        await Assert.ThrowsAsync<SageApiException>(() => Collect(client));
    }

    [Fact]
    public async Task ConnectionClosingEarlyIsAnError()
    {
        var handler = new FakeHandler(_ => Task.FromResult(Sse(Delta("half a sen"))));
        using var client = new SageWorkerClient(Worker, Token, handler);

        var error = await Assert.ThrowsAsync<SageApiException>(() => Collect(client));
        Assert.Contains("closed before the reply finished", error.Message);
    }

    [Fact]
    public async Task NetworkFailureBecomesFriendlyError()
    {
        var handler = new FakeHandler(_ => throw new HttpRequestException("private socket details"));
        using var client = new SageWorkerClient(Worker, Token, handler);

        var error = await Assert.ThrowsAsync<SageApiException>(() => Collect(client));
        Assert.DoesNotContain("private", error.Message);
    }

    [Fact]
    public async Task SilentServerTimesOut()
    {
        var handler = new FakeHandler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StreamContent(new StallingStream(Encoding.UTF8.GetBytes(Delta("hello")))) { Headers = { { "Content-Type", "text/event-stream" } } },
        }));
        using var client = new SageWorkerClient(Worker, Token, handler, idleTimeout: TimeSpan.FromMilliseconds(200));

        var error = await Assert.ThrowsAsync<SageApiException>(() => Collect(client));
        Assert.Contains("stopped hearing", error.Message);
    }

    [Fact]
    public async Task CallerCancellationIsNotAnError()
    {
        var handler = new FakeHandler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StreamContent(new StallingStream(Encoding.UTF8.GetBytes(Delta("hello")))) { Headers = { { "Content-Type", "text/event-stream" } } },
        }));
        using var client = new SageWorkerClient(Worker, Token, handler);
        using var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(200));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Collect(client, cancel.Token));
    }
}
