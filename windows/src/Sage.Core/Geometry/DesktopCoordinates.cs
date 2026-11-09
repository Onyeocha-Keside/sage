namespace Sage.Core.Geometry;

// The Mac app works in AppKit points with a bottom-left origin. Windows is different
// in ways that matter here, so this port uses one coordinate space everywhere:
// PHYSICAL desktop pixels, top-left origin, the space a per-monitor-DPI-aware process
// gets from GetCursorPos and EnumDisplayMonitors. A monitor to the left of or above
// the primary one has negative coordinates, so positions must never be assumed positive.

/// <summary>A position in physical desktop pixels. May be negative.</summary>
public readonly record struct DesktopPoint(double X, double Y);

/// <summary>A rectangle in physical desktop pixels. Right and Bottom are exclusive.</summary>
public readonly record struct DesktopRect(double Left, double Top, double Width, double Height)
{
    public double Right => Left + Width;
    public double Bottom => Top + Height;
    public bool IsEmpty => Width <= 0 || Height <= 0;

    public bool Contains(DesktopPoint point) =>
        point.X >= Left && point.X < Right && point.Y >= Top && point.Y < Bottom;
}

/// <summary>The geometry of one captured image, enough to map its pixels back to the desktop.</summary>
public sealed record ScreenshotFrame(
    DesktopRect MonitorBounds,
    int ImageWidth,
    int ImageHeight,
    bool IsCursorScreen,
    bool IsZoomedDetail = false);

public static class DesktopCoordinates
{
    /// <summary>Scales a monitor so its longest side is at most <paramref name="maximumDimension"/>.</summary>
    public static (int Width, int Height) ScaledImageSize(int sourceWidth, int sourceHeight, int maximumDimension)
    {
        if (sourceWidth <= 0 || sourceHeight <= 0) return (0, 0);
        double aspectRatio = (double)sourceWidth / sourceHeight;
        return sourceWidth >= sourceHeight
            ? (maximumDimension, Math.Max(1, (int)(maximumDimension / aspectRatio)))
            : (Math.Max(1, (int)(maximumDimension * aspectRatio)), maximumDimension);
    }

    /// <summary>
    /// Maps a position in a scaled screenshot to the physical desktop. Coordinates
    /// that overshoot the image are clamped, because Claude sometimes lands slightly
    /// past the edge. Null when the frame has no usable size.
    /// </summary>
    public static DesktopPoint? ScreenshotPixelToDesktop(double pixelX, double pixelY, ScreenshotFrame frame)
    {
        if (frame.ImageWidth <= 0 || frame.ImageHeight <= 0 || frame.MonitorBounds.IsEmpty
            || !double.IsFinite(pixelX) || !double.IsFinite(pixelY))
        {
            return null;
        }

        double clampedX = Math.Clamp(pixelX, 0, frame.ImageWidth);
        double clampedY = Math.Clamp(pixelY, 0, frame.ImageHeight);
        return new DesktopPoint(
            frame.MonitorBounds.Left + clampedX * (frame.MonitorBounds.Width / frame.ImageWidth),
            frame.MonitorBounds.Top + clampedY * (frame.MonitorBounds.Height / frame.ImageHeight));
    }

    /// <summary>The inverse mapping, used when marking a position on a screenshot.</summary>
    public static (double X, double Y) DesktopToScreenshotPixel(DesktopPoint point, ScreenshotFrame frame) =>
        ((point.X - frame.MonitorBounds.Left) * (frame.ImageWidth / frame.MonitorBounds.Width),
         (point.Y - frame.MonitorBounds.Top) * (frame.ImageHeight / frame.MonitorBounds.Height));
}
