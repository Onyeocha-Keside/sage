using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using Sage.Core.Geometry;
using Sage.Core.Reply;

namespace Sage.Windows;

/// <summary>
/// Prototype for the riskiest Windows pieces: capture, the overlay, hold-to-talk, and
/// pointing at the right pixel across monitors. It makes no network calls.
///
///   SagePrototype --diagnose   Runs automatic checks and prints PASS or FAIL.
///   SagePrototype              Hold Ctrl + Win to capture and tour every monitor. Ctrl + C quits.
/// </summary>
internal static class Program
{
    private const uint MessageShowTour = Native.WM_APP + 1;
    private const nuint FrameTimerId = 1;
    private const string WindowClassName = "SagePrototypeOverlay";
    private static readonly TimeSpan FlightDuration = TimeSpan.FromMilliseconds(450);
    private static readonly TimeSpan HoldAtTarget = TimeSpan.FromMilliseconds(1100);
    private static readonly (byte R, byte G, byte B) SageGreen = (43, 182, 115);
    // A color unlikely on a desktop, so the capture check can recognize the overlay.
    private static readonly (byte R, byte G, byte B) TestMagenta = (255, 0, 255);

    private static readonly ConcurrentQueue<PointingTarget> s_pendingTargets = new();
    private static CursorOverlay? s_overlay;
    private static HoldToTalkMonitor? s_holdToTalk;
    private static DesktopPoint s_tip;
    private static DesktopPoint s_flightStart;
    private static PointingTarget? s_currentTarget;
    private static readonly Stopwatch s_phaseClock = new();
    private static bool s_isHolding;

    private static int Main(string[] arguments)
    {
        if (RuntimeInformation.ProcessArchitecture is not (Architecture.X64 or Architecture.Arm64))
        {
            Console.Error.WriteLine("This prototype only supports 64-bit Windows.");
            return 2;
        }

        return arguments.Contains("--diagnose") ? Diagnose().GetAwaiter().GetResult() : RunInteractive();
    }

    // MARK: - Interactive

    private static int RunInteractive()
    {
        nint window = CreateOverlayWindow();
        s_overlay = new CursorOverlay(window, SageGreen);
        s_holdToTalk = new HoldToTalkMonitor(window, OnHoldStarted, static () => Console.WriteLine("released"));
        s_holdToTalk.Start();
        s_tip = OffsetFromMouse();
        Native.SetTimer(window, FrameTimerId, 16, 0);
        Console.WriteLine("Hold Ctrl + Win to capture and tour every monitor. Press Ctrl + C here to quit.");

        while (Native.GetMessageW(out var message, 0, 0, 0) > 0)
        {
            Native.TranslateMessage(message);
            Native.DispatchMessageW(message);
        }

        s_overlay.Dispose();
        return 0;
    }

    private static void OnHoldStarted()
    {
        Console.WriteLine("pressed: capturing...");
        nint window = s_overlay!.Window;
        _ = Task.Run(async () =>
        {
            try
            {
                var capturer = new ScreenCapturer();
                var monitors = Monitors.EnumerateCursorScreenFirst();
                var folder = OutputFolder();
                var frames = new List<ScreenshotFrame>();
                for (int i = 0; i < monitors.Count; i++)
                {
                    var capture = await capturer.CaptureAsync(monitors[i], isCursorScreen: i == 0);
                    await File.WriteAllBytesAsync(Path.Combine(folder, $"tour-screen{i + 1}.jpg"), capture.Jpeg);
                    frames.Add(capture.Frame);
                }

                // Runs a simulated reply through the real parser, so this exercises the
                // same route from tag to desktop position that a Claude reply will take.
                var segmenter = new StreamingResponseSegmenter();
                var segments = segmenter.Append(BuildTourReply(frames)).Concat(segmenter.Finish());
                foreach (var pointing in segments.OfType<ResponseSegment.Pointing>())
                {
                    if (pointing.Tag.Resolve(frames) is { } target) s_pendingTargets.Enqueue(target);
                }

                Native.PostMessageW(window, MessageShowTour, 0, 0);
            }
            catch (Exception exception) when (exception is not OutOfMemoryException)
            {
                Console.WriteLine($"capture failed: {exception.Message}");
            }
        });
    }

    private static string BuildTourReply(IReadOnlyList<ScreenshotFrame> frames)
    {
        var reply = new System.Text.StringBuilder();
        for (int i = 0; i < frames.Count; i++)
        {
            var frame = frames[i];
            foreach (var (name, xShare, yShare) in new[] { ("top left", 0.1, 0.1), ("center", 0.5, 0.5), ("bottom right", 0.9, 0.9) })
            {
                reply.Append(CultureInfo.InvariantCulture,
                    $"[POINT:{(int)(frame.ImageWidth * xShare)},{(int)(frame.ImageHeight * yShare)}:{name}:screen{i + 1}] looking at the {name}. ");
            }
        }

        return reply.ToString();
    }

    private static void OnFrame()
    {
        s_holdToTalk?.ResyncWithPhysicalKeys();

        if (s_currentTarget is { } target)
        {
            double elapsed = s_phaseClock.Elapsed.TotalMilliseconds;
            if (s_isHolding)
            {
                if (elapsed >= HoldAtTarget.TotalMilliseconds) s_currentTarget = null;
            }
            else
            {
                double progress = Math.Min(1, elapsed / FlightDuration.TotalMilliseconds);
                double eased = progress * progress * (3 - 2 * progress);
                s_tip = new DesktopPoint(
                    s_flightStart.X + (target.Location.X - s_flightStart.X) * eased,
                    s_flightStart.Y + (target.Location.Y - s_flightStart.Y) * eased);
                if (progress >= 1)
                {
                    s_isHolding = true;
                    s_phaseClock.Restart();
                    Console.WriteLine($"at '{target.Label}': desktop ({target.Location.X:F0}, {target.Location.Y:F0})");
                }
            }
        }

        if (s_currentTarget is null)
        {
            if (s_pendingTargets.TryDequeue(out var next))
            {
                s_currentTarget = next;
                s_flightStart = s_tip;
                s_isHolding = false;
                s_phaseClock.Restart();
            }
            else
            {
                s_tip = OffsetFromMouse();
            }
        }

        s_overlay?.MoveTipTo(s_tip);
    }

    private static DesktopPoint OffsetFromMouse()
    {
        var cursor = Monitors.Cursor();
        double scale = Monitors.DpiAt(cursor) / 96.0;
        return new DesktopPoint(cursor.X + 24 * scale, cursor.Y + 16 * scale);
    }

    private static unsafe nint CreateOverlayWindow()
    {
        fixed (char* className = WindowClassName)
        {
            var windowClass = new WindowClassEx
            {
                Size = (uint)sizeof(WindowClassEx),
                WindowProcedure = &WindowProcedure,
                Instance = Native.GetModuleHandleW(0),
                ClassName = className,
            };
            if (Native.RegisterClassExW(windowClass) == 0)
            {
                throw new InvalidOperationException($"Couldn't register the window class (error {Marshal.GetLastPInvokeError()}).");
            }
        }

        nint window = Native.CreateWindowExW(
            Native.WS_EX_LAYERED | Native.WS_EX_TRANSPARENT | Native.WS_EX_TOPMOST | Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE,
            WindowClassName, "Sage", Native.WS_POPUP, 0, 0, 1, 1, 0, 0, Native.GetModuleHandleW(0), 0);
        return window != 0
            ? window
            : throw new InvalidOperationException($"Couldn't create the overlay (error {Marshal.GetLastPInvokeError()}).");
    }

    [UnmanagedCallersOnly]
    private static nint WindowProcedure(nint window, uint message, nuint wParam, nint lParam)
    {
        try
        {
            switch (message)
            {
                case Native.WM_INPUT:
                    s_holdToTalk?.HandleRawInput(lParam);
                    break; // WM_INPUT must still reach DefWindowProc for cleanup.
                case Native.WM_TIMER when wParam == FrameTimerId:
                    OnFrame();
                    return 0;
                case MessageShowTour:
                    return 0; // The frame timer picks up the queued targets.
                case Native.WM_DESTROY:
                    Native.PostQuitMessage(0);
                    return 0;
            }
        }
        catch (Exception exception)
        {
            // An exception can't cross back into native code.
            Console.Error.WriteLine(exception);
        }

        return Native.DefWindowProcW(window, message, wParam, lParam);
    }

    private static string OutputFolder()
    {
        string folder = Path.Combine(Path.GetTempPath(), "SagePrototype");
        Directory.CreateDirectory(folder);
        return folder;
    }

    // MARK: - Automatic Checks

    private static async Task<int> Diagnose()
    {
        int failures = 0;
        void Check(string name, bool passed, string detail = "")
        {
            if (!passed) failures++;
            Console.WriteLine($"[{(passed ? "PASS" : "FAIL")}] {name}{(detail.Length > 0 ? $" ({detail})" : "")}");
        }

        Console.WriteLine($"Windows {Environment.OSVersion.Version}, {RuntimeInformation.ProcessArchitecture}");

        var monitors = Monitors.EnumerateCursorScreenFirst();
        Check("found at least one monitor", monitors.Count > 0, $"{monitors.Count}");
        foreach (var monitor in monitors)
        {
            Console.WriteLine($"  monitor: bounds ({monitor.Bounds.Left}, {monitor.Bounds.Top}) {monitor.Bounds.Width}x{monitor.Bounds.Height}, " +
                              $"{monitor.Dpi} dpi ({monitor.Dpi * 100 / 96}%){(monitor.IsPrimary ? ", primary" : "")}");
        }

        Check("process sees real DPI scaling", monitors.All(monitor => monitor.Dpi >= 96));

        nint window = CreateOverlayWindow();
        using var overlay = new CursorOverlay(window, TestMagenta);
        Check("overlay is excluded from capture (API reports it)", overlay.IsExcludedFromCapture);

        // The overlay's tip must land on the requested position on every monitor.
        var originalCursor = Monitors.Cursor();
        var frames = monitors.Select((monitor, index) =>
            new ScreenshotFrame(monitor.Bounds, 1280, 720, index == 0)).ToList();
        for (int i = 0; i < monitors.Count; i++)
        {
            foreach (var (name, xShare, yShare) in new[] { ("top left", 0.1, 0.1), ("center", 0.5, 0.5), ("bottom right", 0.9, 0.9) })
            {
                string label = $"screen {i + 1} {name}";
                var tag = PointingTag.Parse($"[POINT:{(int)(1280 * xShare)},{(int)(720 * yShare)}:{name}:screen{i + 1}]");
                var target = tag?.Resolve(frames);
                if (target is null)
                {
                    Check($"{label}: tag resolves", false);
                    continue;
                }

                var native = Monitors.ToNative(target.Location);
                Native.SetCursorPos(native.X, native.Y);
                var actual = Monitors.Cursor();
                Check($"{label}: mouse reaches the mapped position",
                    Math.Abs(actual.X - native.X) <= 1 && Math.Abs(actual.Y - native.Y) <= 1,
                    $"wanted ({native.X}, {native.Y}), got ({actual.X}, {actual.Y})");
                Check($"{label}: position is on the right monitor", Monitors.HandleAt(target.Location) == monitors[i].Handle);

                overlay.MoveTipTo(target.Location);
                Native.GetWindowRect(window, out var rect);
                int tipX = rect.Left + 2, tipY = rect.Top + 2; // 2 is the overlay's padding.
                Check($"{label}: overlay tip lands on target",
                    Math.Abs(tipX - native.X) <= 1 && Math.Abs(tipY - native.Y) <= 1,
                    $"wanted ({native.X}, {native.Y}), got ({tipX}, {tipY})");
            }
        }

        Native.SetCursorPos((int)originalCursor.X, (int)originalCursor.Y);

        if (!Windows_Graphics_Capture_IsSupported())
        {
            Check("Windows.Graphics.Capture is available", false);
            return failures;
        }

        string folder = OutputFolder();
        ScreenCapturer capturer;
        try
        {
            capturer = new ScreenCapturer();
        }
        catch (Exception exception) when (exception is COMException or DllNotFoundException or EntryPointNotFoundException)
        {
            Check("created a Direct3D device for capture", false, exception.Message);
            return failures;
        }

        for (int i = 0; i < monitors.Count; i++)
        {
            var monitor = monitors[i];
            // Parks the magenta cursor where the check can look for it in the screenshot.
            var center = new DesktopPoint(monitor.Bounds.Left + monitor.Bounds.Width / 2, monitor.Bounds.Top + monitor.Bounds.Height / 2);
            overlay.MoveTipTo(center);
            await Task.Delay(250);

            // 10 logical pixels down the diagonal from the tip is solidly inside the arrow.
            double scale = monitor.Dpi / 96.0;
            var inside = new DesktopPoint(center.X + 10 * scale, center.Y + 10 * scale);
            var clock = Stopwatch.StartNew();
            try
            {
                var capture = await capturer.CaptureAsync(monitor, i == 0, inside);
                string path = Path.Combine(folder, $"diagnose-screen{i + 1}.jpg");
                await File.WriteAllBytesAsync(path, capture.Jpeg);
                Check($"screen {i + 1}: captured", capture.Jpeg.Length > 0, $"{clock.ElapsedMilliseconds} ms, {capture.Jpeg.Length / 1024} KB, {path}");
                Check($"screen {i + 1}: capture size matches physical bounds",
                    capture.SourceWidth == (int)monitor.Bounds.Width && capture.SourceHeight == (int)monitor.Bounds.Height,
                    $"captured {capture.SourceWidth}x{capture.SourceHeight}");

                bool looksMagenta = capture.SampledPixel is { R: > 220, G: < 40, B: > 220 };
                Check($"screen {i + 1}: overlay is really absent from the screenshot",
                    capture.SampledPixel is not null && !looksMagenta, $"pixel under overlay: {capture.SampledPixel}");
            }
            catch (Exception exception) when (exception is COMException or TimeoutException or UnauthorizedAccessException or ArgumentException)
            {
                Check($"screen {i + 1}: captured", false, exception.Message);
            }
        }

        Console.WriteLine($"Capture border hidden: {capturer.BorderlessGranted?.ToString() ?? "unknown"} (informational; False means a yellow border shows during capture)");
        Native.DestroyWindow(window);
        Console.WriteLine(failures == 0 ? "All checks passed." : $"{failures} check(s) failed.");
        Console.WriteLine("Hold-to-talk needs a person. Run without --diagnose and hold Ctrl + Win to try it.");
        return failures == 0 ? 0 : 1;
    }

    private static bool Windows_Graphics_Capture_IsSupported() =>
        global::Windows.Graphics.Capture.GraphicsCaptureSession.IsSupported();
}
