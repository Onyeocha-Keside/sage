using System.Runtime.InteropServices;
using Sage.Core.Geometry;

namespace Sage.Windows;

[StructLayout(LayoutKind.Sequential)]
internal struct NativePoint { public int X, Y; }

[StructLayout(LayoutKind.Sequential)]
internal struct NativeSize { public int Width, Height; }

[StructLayout(LayoutKind.Sequential)]
internal struct NativeRect
{
    public int Left, Top, Right, Bottom;
    public readonly DesktopRect ToDesktopRect() => new(Left, Top, Right - Left, Bottom - Top);
}

[StructLayout(LayoutKind.Sequential)]
internal struct NativeMessage
{
    public nint Window;
    public uint Message;
    public nuint WParam;
    public nint LParam;
    public uint Time;
    public NativePoint Point;
    public uint Private;
}

[StructLayout(LayoutKind.Sequential)]
internal unsafe struct WindowClassEx
{
    public uint Size;
    public uint Style;
    public delegate* unmanaged<nint, uint, nuint, nint, nint> WindowProcedure;
    public int ClassExtra, WindowExtra;
    public nint Instance, Icon, Cursor, Background;
    public char* MenuName;
    public char* ClassName;
    public nint SmallIcon;
}

[StructLayout(LayoutKind.Sequential)]
internal struct MonitorInfo
{
    public uint Size;
    public NativeRect Bounds, WorkArea;
    public uint Flags;
}

[StructLayout(LayoutKind.Sequential)]
internal struct RawInputDevice
{
    public ushort UsagePage, Usage;
    public uint Flags;
    public nint Target;
}

[StructLayout(LayoutKind.Sequential)]
internal struct BitmapInfoHeader
{
    public uint Size;
    public int Width, Height;
    public ushort Planes, BitCount;
    public uint Compression, SizeImage;
    public int XPelsPerMeter, YPelsPerMeter;
    public uint ColorsUsed, ColorsImportant;
}

[StructLayout(LayoutKind.Sequential)]
internal struct BlendFunction
{
    public byte Op, Flags, SourceConstantAlpha, AlphaFormat;
}

internal static unsafe partial class Native
{
    public const uint WM_DESTROY = 0x0002, WM_TIMER = 0x0113, WM_INPUT = 0x00FF, WM_APP = 0x8000;
    public const uint WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101, WM_SYSKEYDOWN = 0x0104, WM_SYSKEYUP = 0x0105;
    public const uint WS_POPUP = 0x80000000;
    public const uint WS_EX_TOPMOST = 0x8, WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80;
    public const uint WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x8000000;
    public const int SW_SHOWNOACTIVATE = 4;
    public const uint ULW_ALPHA = 2;
    public const uint WDA_EXCLUDEFROMCAPTURE = 0x11;
    public const uint RIDEV_INPUTSINK = 0x100, RID_INPUT = 0x10000003;
    public const uint MONITORINFOF_PRIMARY = 1, MONITOR_DEFAULTTONEAREST = 2;
    public const uint DIB_RGB_COLORS = 0;

    [LibraryImport("kernel32.dll")] public static partial nint GetModuleHandleW(nint name);
    [LibraryImport("user32.dll", SetLastError = true)] public static partial ushort RegisterClassExW(in WindowClassEx windowClass);
    [LibraryImport("user32.dll", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    public static partial nint CreateWindowExW(uint exStyle, string className, string title, uint style,
        int x, int y, int width, int height, nint parent, nint menu, nint instance, nint parameter);
    [LibraryImport("user32.dll")] public static partial nint DefWindowProcW(nint window, uint message, nuint wParam, nint lParam);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static partial bool ShowWindow(nint window, int command);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static partial bool DestroyWindow(nint window);
    [LibraryImport("user32.dll")] public static partial int GetMessageW(out NativeMessage message, nint window, uint min, uint max);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static partial bool TranslateMessage(in NativeMessage message);
    [LibraryImport("user32.dll")] public static partial nint DispatchMessageW(in NativeMessage message);
    [LibraryImport("user32.dll")] public static partial void PostQuitMessage(int exitCode);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static partial bool PostMessageW(nint window, uint message, nuint wParam, nint lParam);
    [LibraryImport("user32.dll")] public static partial nuint SetTimer(nint window, nuint id, uint milliseconds, nint callback);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static partial bool GetCursorPos(out NativePoint point);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static partial bool SetCursorPos(int x, int y);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static partial bool GetWindowRect(nint window, out NativeRect rect);
    [LibraryImport("user32.dll")] public static partial short GetAsyncKeyState(int virtualKey);

    [LibraryImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetWindowDisplayAffinity(nint window, uint affinity);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetWindowDisplayAffinity(nint window, out uint affinity);

    [LibraryImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool UpdateLayeredWindow(nint window, nint screenContext, in NativePoint destination, in NativeSize size,
        nint sourceContext, in NativePoint source, uint colorKey, in BlendFunction blend, uint flags);

    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool EnumDisplayMonitors(nint context, nint clip,
        delegate* unmanaged<nint, nint, NativeRect*, nint, int> callback, nint data);
    [LibraryImport("user32.dll", EntryPoint = "GetMonitorInfoW")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetMonitorInfo(nint monitor, ref MonitorInfo info);
    [LibraryImport("user32.dll")] public static partial nint MonitorFromPoint(NativePoint point, uint flags);
    [LibraryImport("shcore.dll")] public static partial int GetDpiForMonitor(nint monitor, int type, out uint dpiX, out uint dpiY);

    [LibraryImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool RegisterRawInputDevices(in RawInputDevice device, uint count, uint size);
    [LibraryImport("user32.dll")]
    public static partial uint GetRawInputData(nint input, uint command, byte* data, ref uint size, uint headerSize);

    [LibraryImport("gdi32.dll")] public static partial nint CreateCompatibleDC(nint context);
    [LibraryImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static partial bool DeleteDC(nint context);
    [LibraryImport("gdi32.dll")] public static partial nint SelectObject(nint context, nint item);
    [LibraryImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static partial bool DeleteObject(nint item);
    [LibraryImport("gdi32.dll")]
    public static partial nint CreateDIBSection(nint context, in BitmapInfoHeader header, uint usage, out byte* bits, nint section, uint offset);
}
