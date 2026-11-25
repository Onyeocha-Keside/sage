using System.Text.Json;

namespace Sage.Core.Networking;

public abstract record ClaudeStreamEvent
{
    /// <summary>More reply text arrived.</summary>
    public sealed record TextDelta(string Text) : ClaudeStreamEvent;

    /// <summary>Claude declined to answer (a safety classifier refusal).</summary>
    public sealed record Refusal : ClaudeStreamEvent;
}

public sealed class SageApiException(string message, int? httpStatusCode = null) : Exception(message)
{
    /// <summary>HTTP status from the Worker, or null when the failure came mid-stream.</summary>
    public int? HttpStatusCode { get; } = httpStatusCode;
}

/// <summary>
/// Interprets the provider's JSON data lines independently of the network transport.
/// A socket closing is not proof that the model finished its answer.
/// </summary>
public sealed class ClaudeStreamDecoder
{
    private string? _stopReason;

    public bool HasCompleted { get; private set; }

    public IReadOnlyList<ClaudeStreamEvent> Consume(string line)
    {
        if (!line.StartsWith("data:", StringComparison.Ordinal)) return [];

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(line.AsMemory(5));
        }
        catch (JsonException)
        {
            throw new SageApiException("The reply stream contained invalid data.");
        }

        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("type", out var typeElement)
                || typeElement.ValueKind != JsonValueKind.String)
            {
                throw new SageApiException("The reply stream contained invalid data.");
            }

            switch (typeElement.GetString())
            {
                case "content_block_delta":
                    if (TryGetString(root, "delta", "type") == "text_delta"
                        && TryGetString(root, "delta", "text") is { } text)
                    {
                        return [new ClaudeStreamEvent.TextDelta(text)];
                    }

                    break;
                case "message_delta":
                    if (TryGetString(root, "delta", "stop_reason") is { } reason)
                    {
                        _stopReason = reason;
                        if (reason == "refusal") return [new ClaudeStreamEvent.Refusal()];
                    }

                    break;
                case "error":
                    // Provider messages may include user content; don't expose them in diagnostics.
                    throw new SageApiException("The provider reported a reply-stream error.");
                case "message_stop":
                    if (_stopReason == "max_tokens")
                    {
                        throw new SageApiException("The reply was cut off at the output limit.");
                    }

                    HasCompleted = true;
                    break;
                // Providers can add event types; thinking and ping events aren't spoken.
            }

            return [];
        }
    }

    public void Finish()
    {
        if (!HasCompleted) throw new SageApiException("The connection closed before the reply finished.");
    }

    private static string? TryGetString(JsonElement root, string objectName, string propertyName) =>
        root.TryGetProperty(objectName, out var parent)
        && parent.ValueKind == JsonValueKind.Object
        && parent.TryGetProperty(propertyName, out var value)
        && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;
}
