using System.Globalization;
using System.Text.RegularExpressions;
using Sage.Core.Geometry;

namespace Sage.Core.Reply;

/// <summary>
/// A pointing instruction exactly as Claude wrote it, in screenshot pixels, such as
/// [POINT:640,410:save button] or [POINT:400,300:terminal:screen2].
/// The format is defined by the prompts in worker/src/sage/prompts.py.
/// </summary>
public sealed partial record PointingTag(double X, double Y, string? Label, int? ScreenNumber)
{
    [GeneratedRegex(@"^\[POINT:\s*(\d+)\s*,\s*(\d+)\s*(?::([^\]:]*?))?\s*(?::\s*screen\s*(\d+))?\s*\]$",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex TagExpression();

    /// <summary>Parses one complete tag. Null for [POINT:none] and anything invalid.</summary>
    public static PointingTag? Parse(string tagText)
    {
        var match = TagExpression().Match(tagText.Trim());
        if (!match.Success
            || !double.TryParse(match.Groups[1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var x)
            || !double.TryParse(match.Groups[2].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var y))
        {
            return null;
        }

        string? label = match.Groups[3].Success ? match.Groups[3].Value.Trim() : null;
        if (string.IsNullOrEmpty(label)) label = null;

        int? screenNumber = null;
        if (match.Groups[4].Success
            && int.TryParse(match.Groups[4].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var parsedScreen))
        {
            screenNumber = parsedScreen;
        }

        // "[POINT:1,2:screen2]" (screen without a label) reads as a label called
        // "screen2". Treat it as the screen number instead.
        if (screenNumber is null && label is not null
            && label.StartsWith("screen", StringComparison.OrdinalIgnoreCase)
            && int.TryParse(label.AsSpan("screen".Length), NumberStyles.None, CultureInfo.InvariantCulture, out var labelScreen))
        {
            screenNumber = labelScreen;
            label = null;
        }

        return new PointingTag(x, y, label, screenNumber);
    }

    /// <summary>
    /// Maps this tag's screenshot pixels to a physical desktop position.
    /// Null when there's no screenshot to map against or the screen number is invalid.
    /// </summary>
    public PointingTarget? Resolve(IReadOnlyList<ScreenshotFrame> allFrames)
    {
        // A circled-area close-up isn't a screen, so it never takes a screen number.
        var screens = allFrames.Where(frame => !frame.IsZoomedDetail).ToList();
        ScreenshotFrame? target;
        if (ScreenNumber is int number)
        {
            if (number < 1 || number > screens.Count) return null;
            target = screens[number - 1];
        }
        else
        {
            target = screens.FirstOrDefault(frame => frame.IsCursorScreen) ?? screens.FirstOrDefault();
        }

        if (target is null) return null;
        var location = DesktopCoordinates.ScreenshotPixelToDesktop(X, Y, target);
        return location is null ? null : new PointingTarget(location.Value, target.MonitorBounds, Label);
    }
}

/// <summary>A pointing tag converted to a real place on a real monitor.</summary>
public sealed record PointingTarget(DesktopPoint Location, DesktopRect MonitorBounds, string? Label);
