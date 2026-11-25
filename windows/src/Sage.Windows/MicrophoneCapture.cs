using System.Runtime.InteropServices;

namespace Sage.Windows;

/// <summary>
/// Records the default microphone as 16 kHz mono through the waveIn API; Windows converts
/// from the device's own format. Samples go to the callback on a dedicated thread, about
/// every 100 ms. The microphone is only open between <see cref="Start"/> and <see cref="Stop"/>,
/// so the Windows privacy indicator shows only while the user holds the shortcut.
/// </summary>
internal sealed unsafe class MicrophoneCapture : IDisposable
{
    private const int SampleRate = 16000;
    private const int BufferCount = 4;
    private const int BufferBytes = SampleRate * 2 / 10; // 100 ms of 16-bit mono

    private readonly Action<float[]> _onSamples;
    private readonly AutoResetEvent _bufferDone = new(false);
    private nint _device;
    private WaveHeader* _headers;
    private Thread? _thread;
    private volatile bool _running;

    public MicrophoneCapture(Action<float[]> onSamples) => _onSamples = onSamples;

    /// <summary>The loudest sample seen since <see cref="Start"/>, from 0 to 1.</summary>
    public float PeakLevel { get; private set; }

    public void Start()
    {
        if (_running) return;
        var format = new WaveFormat
        {
            FormatTag = 1, // PCM
            Channels = 1,
            SamplesPerSecond = SampleRate,
            AverageBytesPerSecond = SampleRate * 2,
            BlockAlign = 2,
            BitsPerSample = 16,
        };
        uint result = waveInOpen(out _device, WaveMapper, format, _bufferDone.SafeWaitHandle.DangerousGetHandle(), 0, CallbackEvent);
        if (result != 0)
        {
            _device = 0;
            throw new InvalidOperationException(result switch
            {
                2 => "No microphone was found.",            // MMSYSERR_BADDEVICEID
                4 => "The microphone is in use by another app.", // MMSYSERR_ALLOCATED
                _ => $"Couldn't open the microphone (error {result}). Check Settings > Privacy & security > Microphone.",
            });
        }

        _headers = (WaveHeader*)NativeMemory.AllocZeroed((nuint)(sizeof(WaveHeader) * BufferCount));
        for (int i = 0; i < BufferCount; i++)
        {
            _headers[i].Data = (nint)NativeMemory.AllocZeroed(BufferBytes);
            _headers[i].BufferLength = BufferBytes;
            Check(waveInPrepareHeader(_device, &_headers[i], (uint)sizeof(WaveHeader)));
            Check(waveInAddBuffer(_device, &_headers[i], (uint)sizeof(WaveHeader)));
        }

        PeakLevel = 0;
        _running = true;
        _thread = new Thread(Pump) { IsBackground = true, Name = "Sage microphone", Priority = ThreadPriority.AboveNormal };
        _thread.Start();
        Check(waveInStart(_device));
    }

    public void Stop()
    {
        if (!_running) return;
        _running = false;
        // Reset marks every queued buffer done, so the pump hands over the last partial chunk.
        waveInReset(_device);
        _bufferDone.Set();
        _thread?.Join();
        _thread = null;
        // The pump may have queued one more buffer just before it saw the stop.
        waveInReset(_device);

        for (int i = 0; i < BufferCount; i++)
        {
            waveInUnprepareHeader(_device, &_headers[i], (uint)sizeof(WaveHeader));
            NativeMemory.Free((void*)_headers[i].Data);
        }

        NativeMemory.Free(_headers);
        _headers = null;
        waveInClose(_device);
        _device = 0;
    }

    public void Dispose()
    {
        Stop();
        _bufferDone.Dispose();
    }

    private void Pump()
    {
        int next = 0;
        while (true)
        {
            bool running = _running;
            // Buffers complete in the order they were queued.
            while ((Volatile.Read(ref _headers[next].Flags) & HeaderDone) != 0)
            {
                ref var header = ref _headers[next];
                int count = (int)header.BytesRecorded / 2;
                if (count > 0)
                {
                    var samples = new float[count];
                    var source = new ReadOnlySpan<short>((void*)header.Data, count);
                    float peak = PeakLevel;
                    for (int i = 0; i < count; i++)
                    {
                        samples[i] = source[i] / 32768f;
                        peak = Math.Max(peak, Math.Abs(samples[i]));
                    }

                    PeakLevel = peak;
                    _onSamples(samples);
                }

                header.Flags &= ~HeaderDone;
                header.BytesRecorded = 0;
                if (running) waveInAddBuffer(_device, &_headers[next], (uint)sizeof(WaveHeader));
                next = (next + 1) % BufferCount;
                if (!running && AllIdle()) return;
            }

            if (!running) return;
            _bufferDone.WaitOne(200);
        }
    }

    private bool AllIdle()
    {
        for (int i = 0; i < BufferCount; i++)
        {
            if ((_headers[i].Flags & HeaderDone) != 0) return false;
        }

        return true;
    }

    private static void Check(uint result)
    {
        if (result != 0) throw new InvalidOperationException($"The microphone stopped working (error {result}).");
    }

    // MARK: - waveIn

    private const uint WaveMapper = 0xFFFFFFFF;
    private const uint CallbackEvent = 0x00050000;
    private const uint HeaderDone = 0x00000001;

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    private struct WaveFormat
    {
        public ushort FormatTag;
        public ushort Channels;
        public uint SamplesPerSecond;
        public uint AverageBytesPerSecond;
        public ushort BlockAlign;
        public ushort BitsPerSample;
        public ushort ExtraSize;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WaveHeader
    {
        public nint Data;
        public uint BufferLength;
        public uint BytesRecorded;
        public nint User;
        public uint Flags;
        public uint Loops;
        public nint Next;
        public nint Reserved;
    }

    [DllImport("winmm.dll")]
    private static extern uint waveInOpen(out nint device, uint deviceId, in WaveFormat format, nint callback, nint instance, uint flags);

    [DllImport("winmm.dll")]
    private static extern uint waveInPrepareHeader(nint device, WaveHeader* header, uint size);

    [DllImport("winmm.dll")]
    private static extern uint waveInUnprepareHeader(nint device, WaveHeader* header, uint size);

    [DllImport("winmm.dll")]
    private static extern uint waveInAddBuffer(nint device, WaveHeader* header, uint size);

    [DllImport("winmm.dll")]
    private static extern uint waveInStart(nint device);

    [DllImport("winmm.dll")]
    private static extern uint waveInReset(nint device);

    [DllImport("winmm.dll")]
    private static extern uint waveInClose(nint device);
}
