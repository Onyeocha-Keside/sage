using System.Runtime.InteropServices;
using Sage.Core.Geometry;

namespace Sage.Windows;

internal sealed record MonitorDescription(nint Handle, DesktopRect Bounds, uint Dpi, bool IsPrimary);

internal static unsafe class Monitors
{
    [ThreadStatic] private static List<nint>? t_handles;

    /// <summary>All connected monitors, with the one holding the mouse cursor first.</summary>
    public static List<MonitorDescription> EnumerateCursorScreenFirst()
    {
        t_handles = [];
        Native.EnumDisplayMonitors(0, 0, &CollectMonitor, 0);
        var monitors = t_handles.Select(Describe).ToList();
        t_handles = null;

        var cursor = Cursor();
        return [.. monitors.OrderByDescending(monitor => monitor.Bounds.Contains(cursor))];
    }

    public static DesktopPoint Cursor()
    {
        Native.GetCursorPos(out var point);
        return new DesktopPoint(point.X, point.Y);
    }

    public static uint DpiAt(DesktopPoint point)
    {
        var monitor = Native.MonitorFromPoint(ToNative(point), Native.MONITOR_DEFAULTTONEAREST);
        return Native.GetDpiForMonitor(monitor, 0, out uint dpi, out _) == 0 ? dpi : 96;
    }

    public static nint HandleAt(DesktopPoint point) =>
        Native.MonitorFromPoint(ToNative(point), Native.MONITOR_DEFAULTTONEAREST);

    public static NativePoint ToNative(DesktopPoint point) =>
        new() { X = (int)Math.Round(point.X), Y = (int)Math.Round(point.Y) };

    private static MonitorDescription Describe(nint handle)
    {
        var info = new MonitorInfo { Size = (uint)Marshal.SizeOf<MonitorInfo>() };
        Native.GetMonitorInfo(handle, ref info);
        uint dpi = Native.GetDpiForMonitor(handle, 0, out uint dpiX, out _) == 0 ? dpiX : 96;
        return new MonitorDescription(handle, info.Bounds.ToDesktopRect(), dpi,
            (info.Flags & Native.MONITORINFOF_PRIMARY) != 0);
    }

    [UnmanagedCallersOnly]
    private static int CollectMonitor(nint monitor, nint context, NativeRect* rect, nint data)
    {
        t_handles?.Add(monitor);
        return 1;
    }
}
