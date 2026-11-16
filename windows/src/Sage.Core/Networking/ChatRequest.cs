using System.Text.Json;
using Sage.Core.Conversation;

namespace Sage.Core.Networking;

/// <summary>Which system prompt the Worker should use.</summary>
public enum ConversationMode
{
    /// <summary>Normal push-to-talk conversation.</summary>
    Companion,

    /// <summary>The first-run demo, where Sage points at something on screen to show off.</summary>
    Onboarding,
}

/// <summary>One JPEG screenshot plus the text label Claude reads right after it.</summary>
public sealed record ScreenshotForClaude(byte[] JpegData, string Label);

/// <summary>Builds the /chat request body, matching the Mac app's SageAPIClient.</summary>
public static class ChatRequest
{
    public const string Platform = "windows";

    /// <summary>
    /// The text placed after each screenshot. Same wording as the Mac app, because the
    /// Worker's prompt refers to "primary focus" and the image dimensions.
    /// </summary>
    public static string ScreenLabel(int screenIndex, int screenCount, bool isCursorScreen, int imageWidth, int imageHeight)
    {
        string description = screenCount == 1
            ? "user's screen (cursor is here)"
            : isCursorScreen
                ? $"screen {screenIndex + 1} of {screenCount} — cursor is on this screen (primary focus)"
                : $"screen {screenIndex + 1} of {screenCount} — secondary screen";
        return $"{description} (image dimensions: {imageWidth}x{imageHeight} pixels)";
    }

    /// <summary>
    /// Past turns go as plain text (no old screenshots, to keep requests small), then the
    /// new question with a labeled screenshot of each monitor.
    /// </summary>
    public static byte[] BuildBody(ConversationMode mode, IEnumerable<ConversationTurn> history,
        IReadOnlyList<ScreenshotForClaude> screenshots, string userText)
    {
        using var buffer = new MemoryStream();
        using (var json = new Utf8JsonWriter(buffer))
        {
            json.WriteStartObject();
            json.WriteString("mode", mode == ConversationMode.Onboarding ? "onboarding" : "companion");
            json.WriteString("platform", Platform);
            json.WriteStartArray("messages");

            foreach (var turn in history)
            {
                WriteTextMessage(json, "user", turn.UserText);
                WriteTextMessage(json, "assistant", turn.AssistantText);
            }

            json.WriteStartObject();
            json.WriteString("role", "user");
            json.WriteStartArray("content");
            foreach (var screenshot in screenshots)
            {
                json.WriteStartObject();
                json.WriteString("type", "image");
                json.WriteStartObject("source");
                json.WriteString("type", "base64");
                json.WriteString("media_type", "image/jpeg");
                json.WriteBase64String("data", screenshot.JpegData);
                json.WriteEndObject();
                json.WriteEndObject();
                WriteTextBlock(json, screenshot.Label);
            }

            WriteTextBlock(json, userText);
            json.WriteEndArray();
            json.WriteEndObject();

            json.WriteEndArray();
            json.WriteEndObject();
        }

        return buffer.ToArray();
    }

    private static void WriteTextMessage(Utf8JsonWriter json, string role, string text)
    {
        json.WriteStartObject();
        json.WriteString("role", role);
        json.WriteString("content", text);
        json.WriteEndObject();
    }

    private static void WriteTextBlock(Utf8JsonWriter json, string text)
    {
        json.WriteStartObject();
        json.WriteString("type", "text");
        json.WriteString("text", text);
        json.WriteEndObject();
    }
}
