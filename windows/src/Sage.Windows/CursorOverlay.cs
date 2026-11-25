using Sage.Core.Geometry;

namespace Sage.Windows;

/// <summary>
/// Sage's cursor: a small, click-through, always-on-top window that never takes focus
/// and is hidden from screen capture. The Mac app stretches a transparent window over
/// each screen; moving one small layered window avoids redrawing whole monitors.
/// </summary>
internal sealed unsafe class CursorOverlay : IDisposable
{
    private const int BaseSizeAt96Dpi = 30;
    private const int Padding = 2;

    private readonly nint _window;
    private readonly nint _memoryContext;
    private readonly (byte R, byte G, byte B) _color;
    private nint _bitmap;
    private byte* _pixels;
    private uint _renderedDpi;
    private int _renderedSize;

    public nint Window => _window;

    /// <summary>The result of asking Windows to hide this window from capture.</summary>
    public bool IsExcludedFromCapture { get; }

    public CursorOverlay(nint window, (byte R, byte G, byte B) color)
    {
        _window = window;
        _color = color;
        _memoryContext = Native.CreateCompatibleDC(0);
        Native.SetWindowDisplayAffinity(window, Native.WDA_EXCLUDEFROMCAPTURE);
        IsExcludedFromCapture = Native.GetWindowDisplayAffinity(window, out uint affinity)
            && affinity == Native.WDA_EXCLUDEFROMCAPTURE;
    }

    /// <summary>Puts the cursor's tip exactly on a physical desktop position.</summary>
    public void MoveTipTo(DesktopPoint tip)
    {
        uint dpi = Monitors.DpiAt(tip);
        if (dpi != _renderedDpi) Render(dpi);

        var destination = new NativePoint
        {
            X = (int)Math.Round(tip.X) - Padding,
            Y = (int)Math.Round(tip.Y) - Padding,
        };
        var size = new NativeSize { Width = _renderedSize, Height = _renderedSize };
        var source = default(NativePoint);
        var blend = new BlendFunction { Op = 0, Flags = 0, SourceConstantAlpha = 255, AlphaFormat = 1 };
        Native.UpdateLayeredWindow(_window, 0, destination, size, _memoryContext, source, 0, blend, Native.ULW_ALPHA);
        Native.ShowWindow(_window, Native.SW_SHOWNOACTIVATE);
    }

    /// <summary>Scaled to the monitor's DPI so the cursor looks the same size on each screen.</summary>
    private void Render(uint dpi)
    {
        int triangleSize = (int)Math.Ceiling(BaseSizeAt96Dpi * dpi / 96.0);
        int size = triangleSize + Padding * 2;
        var header = new BitmapInfoHeader
        {
            Size = (uint)sizeof(BitmapInfoHeader),
            Width = size,
            Height = -size, // Negative means rows run top-down.
            Planes = 1,
            BitCount = 32,
        };
        var bitmap = Native.CreateDIBSection(_memoryContext, header, Native.DIB_RGB_COLORS, out byte* pixels, 0, 0);
        if (bitmap == 0 || pixels is null) throw new InvalidOperationException("Couldn't create the cursor bitmap.");

        Native.SelectObject(_memoryContext, bitmap);
        if (_bitmap != 0) Native.DeleteObject(_bitmap);
        _bitmap = bitmap;
        _pixels = pixels;
        _renderedDpi = dpi;
        _renderedSize = size;

        // An arrow with its tip at the top-left, antialiased with 4x4 supersampling.
        var (ax, ay) = (0.0, 0.0);
        var (bx, by) = ((double)triangleSize, triangleSize * 0.38);
        var (cx, cy) = (triangleSize * 0.38, (double)triangleSize);
        for (int y = 0; y < size; y++)
        {
            for (int x = 0; x < size; x++)
            {
                int covered = 0;
                for (int sy = 0; sy < 4; sy++)
                {
                    for (int sx = 0; sx < 4; sx++)
                    {
                        double px = x - Padding + (sx + 0.5) / 4;
                        double py = y - Padding + (sy + 0.5) / 4;
                        if (IsInsideTriangle(px, py, ax, ay, bx, by, cx, cy)) covered++;
                    }
                }

                // UpdateLayeredWindow expects premultiplied BGRA.
                byte* pixel = _pixels + (y * size + x) * 4;
                pixel[0] = (byte)(_color.B * covered / 16);
                pixel[1] = (byte)(_color.G * covered / 16);
                pixel[2] = (byte)(_color.R * covered / 16);
                pixel[3] = (byte)(255 * covered / 16);
            }
        }
    }

    private static bool IsInsideTriangle(double px, double py, double ax, double ay, double bx, double by, double cx, double cy)
    {
        double first = Cross(px, py, ax, ay, bx, by);
        double second = Cross(px, py, bx, by, cx, cy);
        double third = Cross(px, py, cx, cy, ax, ay);
        return (first >= 0 && second >= 0 && third >= 0) || (first <= 0 && second <= 0 && third <= 0);
    }

    private static double Cross(double px, double py, double ax, double ay, double bx, double by) =>
        (px - bx) * (ay - by) - (ax - bx) * (py - by);

    public void Dispose()
    {
        if (_bitmap != 0) Native.DeleteObject(_bitmap);
        Native.DeleteDC(_memoryContext);
    }
}
