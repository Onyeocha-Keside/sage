using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using Sage.Core.Geometry;
using Windows.Foundation;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using WinRT;

namespace Sage.Windows;

/// <summary>One monitor's screenshot, plus what's needed to map its pixels back to the desktop.</summary>
internal sealed record CapturedMonitor(byte[] Jpeg, ScreenshotFrame Frame, int SourceWidth, int SourceHeight, (byte B, byte G, byte R)? SampledPixel);

/// <summary>Takes single screenshots of a monitor with Windows.Graphics.Capture.</summary>
internal sealed class ScreenCapturer
{
    // Same values as ScreenCaptureService.swift in the Mac app.
    private const int MaximumScreenshotDimension = 1280;
    private const float JpegQuality = 0.72f;
    private static readonly TimeSpan FrameTimeout = TimeSpan.FromSeconds(3);

    private readonly IDirect3DDevice _device = Direct3DInterop.CreateDevice();
    private bool _hasRequestedBorderless;

    /// <summary>Set after the first capture attempt: whether Windows agreed to hide the capture border.</summary>
    public bool? BorderlessGranted { get; private set; }

    /// <param name="monitor">The monitor to capture.</param>
    /// <param name="isCursorScreen">Recorded on the frame, so untargeted tags resolve to this screen.</param>
    /// <param name="sampleAt">Optional desktop position to read one raw pixel from, for self-checks.</param>
    public async Task<CapturedMonitor> CaptureAsync(MonitorDescription monitor, bool isCursorScreen, DesktopPoint? sampleAt = null)
    {
        await RequestBorderlessOnceAsync();

        var item = Direct3DInterop.CreateItemForMonitor(monitor.Handle);
        using var pool = Direct3D11CaptureFramePool.CreateFreeThreaded(
            _device, DirectXPixelFormat.B8G8R8A8UIntNormalized, 1, item.Size);
        using var session = pool.CreateCaptureSession(item);
        session.IsCursorCaptureEnabled = false; // Sage draws its own cursor; the real one only adds noise.
        if (BorderlessGranted == true)
        {
            session.IsBorderRequired = false;
        }

        var frameArrived = new TaskCompletionSource<Direct3D11CaptureFrame>(TaskCreationOptions.RunContinuationsAsynchronously);
        TypedEventHandler<Direct3D11CaptureFramePool, object> onFrame = (sender, _) =>
        {
            var frame = sender.TryGetNextFrame();
            if (frame is not null && !frameArrived.TrySetResult(frame)) frame.Dispose();
        };
        pool.FrameArrived += onFrame;
        session.StartCapture();

        using var capturedFrame = await frameArrived.Task.WaitAsync(FrameTimeout);
        pool.FrameArrived -= onFrame;

        using var bitmap = await SoftwareBitmap.CreateCopyFromSurfaceAsync(capturedFrame.Surface, BitmapAlphaMode.Premultiplied);
        var (imageWidth, imageHeight) = DesktopCoordinates.ScaledImageSize(
            bitmap.PixelWidth, bitmap.PixelHeight, MaximumScreenshotDimension);
        var frameGeometry = new ScreenshotFrame(monitor.Bounds, imageWidth, imageHeight, isCursorScreen);

        return new CapturedMonitor(
            await EncodeJpegAsync(bitmap, imageWidth, imageHeight),
            frameGeometry,
            bitmap.PixelWidth,
            bitmap.PixelHeight,
            sampleAt is { } point ? ReadPixel(bitmap, monitor.Bounds, point) : null);
    }

    private async Task RequestBorderlessOnceAsync()
    {
        if (_hasRequestedBorderless) return;
        _hasRequestedBorderless = true;
        try
        {
            var status = await GraphicsCaptureAccess.RequestAccessAsync(GraphicsCaptureAccessKind.Borderless);
            BorderlessGranted = status == global::Windows.Security.Authorization.AppCapabilityAccess.AppCapabilityAccessStatus.Allowed;
        }
        catch (Exception exception) when (exception is COMException or UnauthorizedAccessException or InvalidOperationException)
        {
            // Unpackaged apps may be refused. A yellow border is ugly but not fatal,
            // and whether it happens is exactly what the prototype needs to find out.
            BorderlessGranted = false;
        }
    }

    private static async Task<byte[]> EncodeJpegAsync(SoftwareBitmap bitmap, int width, int height)
    {
        using var stream = new InMemoryRandomAccessStream();
        var options = new BitmapPropertySet
        {
            ["ImageQuality"] = new BitmapTypedValue(JpegQuality, PropertyType.Single),
        };
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, stream, options);
        encoder.SetSoftwareBitmap(bitmap);
        encoder.BitmapTransform.ScaledWidth = (uint)width;
        encoder.BitmapTransform.ScaledHeight = (uint)height;
        encoder.BitmapTransform.InterpolationMode = BitmapInterpolationMode.Fant;
        await encoder.FlushAsync();

        var jpeg = new byte[stream.Size];
        using var reader = new DataReader(stream.GetInputStreamAt(0));
        await reader.LoadAsync((uint)stream.Size);
        reader.ReadBytes(jpeg);
        return jpeg;
    }

    private static (byte B, byte G, byte R)? ReadPixel(SoftwareBitmap bitmap, DesktopRect bounds, DesktopPoint point)
    {
        int x = (int)((point.X - bounds.Left) * bitmap.PixelWidth / bounds.Width);
        int y = (int)((point.Y - bounds.Top) * bitmap.PixelHeight / bounds.Height);
        if (x < 0 || y < 0 || x >= bitmap.PixelWidth || y >= bitmap.PixelHeight) return null;

        var pixels = new byte[bitmap.PixelWidth * bitmap.PixelHeight * 4];
        bitmap.CopyToBuffer(pixels.AsBuffer());
        int offset = (y * bitmap.PixelWidth + x) * 4;
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2]);
    }
}

/// <summary>The COM and WinRT plumbing Windows.Graphics.Capture needs from a desktop app.</summary>
internal static class Direct3DInterop
{
    private const int DriverTypeHardware = 1, DriverTypeWarp = 5;
    private const uint CreateDeviceBgraSupport = 0x20, D3D11SdkVersion = 7;
    private static readonly Guid IidDxgiDevice = new("54EC77FA-1377-44E6-8C32-88FD5F44C84C");
    private static readonly Guid IidGraphicsCaptureItem = new("79C3F95B-31F7-4EC2-A464-632EF5D30760");
    private static readonly Guid IidCaptureItemInterop = new("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356");

    [ComImport, Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IGraphicsCaptureItemInterop
    {
        nint CreateForWindow(nint window, in Guid iid);
        nint CreateForMonitor(nint monitor, in Guid iid);
    }

    [DllImport("d3d11.dll")]
    private static extern int D3D11CreateDevice(nint adapter, int driverType, nint software, uint flags, nint levels,
        uint levelCount, uint sdkVersion, out nint device, out int featureLevel, out nint context);

    [DllImport("d3d11.dll")]
    private static extern int CreateDirect3D11DeviceFromDXGIDevice(nint dxgiDevice, out nint inspectable);

    [DllImport("combase.dll", PreserveSig = false)]
    private static extern void RoGetActivationFactory([MarshalAs(UnmanagedType.HString)] string classId, in Guid iid, out nint factory);

    public static IDirect3DDevice CreateDevice()
    {
        // WARP is the software renderer. VMs often have no usable Direct3D 11 GPU.
        int result = D3D11CreateDevice(0, DriverTypeHardware, 0, CreateDeviceBgraSupport, 0, 0, D3D11SdkVersion, out nint device, out _, out nint context);
        if (result < 0)
        {
            result = D3D11CreateDevice(0, DriverTypeWarp, 0, CreateDeviceBgraSupport, 0, 0, D3D11SdkVersion, out device, out _, out context);
        }

        Marshal.ThrowExceptionForHR(result);
        Marshal.Release(context);
        try
        {
            Guid iid = IidDxgiDevice;
            Marshal.ThrowExceptionForHR(Marshal.QueryInterface(device, in iid, out nint dxgiDevice));
            try
            {
                Marshal.ThrowExceptionForHR(CreateDirect3D11DeviceFromDXGIDevice(dxgiDevice, out nint inspectable));
                try
                {
                    return MarshalInterface<IDirect3DDevice>.FromAbi(inspectable);
                }
                finally
                {
                    Marshal.Release(inspectable);
                }
            }
            finally
            {
                Marshal.Release(dxgiDevice);
            }
        }
        finally
        {
            Marshal.Release(device);
        }
    }

    public static GraphicsCaptureItem CreateItemForMonitor(nint monitor)
    {
        RoGetActivationFactory("Windows.Graphics.Capture.GraphicsCaptureItem", in IidCaptureItemInterop, out nint factory);
        try
        {
            var interop = (IGraphicsCaptureItemInterop)Marshal.GetObjectForIUnknown(factory);
            nint item = interop.CreateForMonitor(monitor, in IidGraphicsCaptureItem);
            try
            {
                return MarshalInterface<GraphicsCaptureItem>.FromAbi(item);
            }
            finally
            {
                Marshal.Release(item);
            }
        }
        finally
        {
            Marshal.Release(factory);
        }
    }
}
