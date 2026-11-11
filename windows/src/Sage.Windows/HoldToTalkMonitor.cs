using System.Runtime.InteropServices;

namespace Sage.Windows;

/// <summary>
/// Watches for a held Ctrl + Win, system-wide, through Raw Input. It only listens, so
/// keys still reach the focused app, like the listen-only event tap in the Mac app.
///
/// RegisterHotKey can't do this: it reports a key combination being pressed, never
/// released. Low-level keyboard hooks can, but Windows silently removes a hook that
/// responds too slowly, with no way for the app to find out.
///
/// The default differs from the Mac's Control + Shift, because Ctrl + Shift and
/// Alt + Shift can switch keyboard layouts on Windows.
/// </summary>
internal sealed unsafe class HoldToTalkMonitor(nint window, Action onPressed, Action onReleased)
{
    private const ushort VkControl = 0x11, VkShift = 0x10, VkMenu = 0x12, VkLeftWin = 0x5B, VkRightWin = 0x5C;
    private const int RawInputHeaderSize64Bit = 24;

    private readonly HashSet<ushort> _keysDown = [];
    private bool _isPressed;

    public bool IsPressed => _isPressed;

    public void Start()
    {
        // Generic desktop page, keyboard usage. INPUTSINK delivers keys while another app is focused.
        var device = new RawInputDevice { UsagePage = 0x01, Usage = 0x06, Flags = Native.RIDEV_INPUTSINK, Target = window };
        if (!Native.RegisterRawInputDevices(device, 1, (uint)sizeof(RawInputDevice)))
        {
            throw new InvalidOperationException($"Couldn't watch the keyboard (error {Marshal.GetLastPInvokeError()}).");
        }
    }

    public void HandleRawInput(nint rawInputHandle)
    {
        byte* buffer = stackalloc byte[64];
        uint size = 64;
        uint read = Native.GetRawInputData(rawInputHandle, Native.RID_INPUT, buffer, ref size, RawInputHeaderSize64Bit);
        if (read == uint.MaxValue || read < RawInputHeaderSize64Bit + 16) return;
        if (*(uint*)buffer != 1) return; // 1 is RIM_TYPEKEYBOARD.

        byte* keyboard = buffer + RawInputHeaderSize64Bit;
        ushort virtualKey = *(ushort*)(keyboard + 6);
        uint message = *(uint*)(keyboard + 8);

        if (message is Native.WM_KEYDOWN or Native.WM_SYSKEYDOWN) _keysDown.Add(virtualKey);
        else if (message is Native.WM_KEYUP or Native.WM_SYSKEYUP) _keysDown.Remove(virtualKey);
        Update();
    }

    /// <summary>
    /// Call periodically. A key-up can be lost (the lock screen, a UAC prompt), and a
    /// stuck key would otherwise leave Sage listening forever.
    /// </summary>
    public void ResyncWithPhysicalKeys()
    {
        if (_keysDown.Count == 0) return;
        _keysDown.RemoveWhere(key => Native.GetAsyncKeyState(key) >= 0);
        Update();
    }

    private void Update()
    {
        bool hasWin = _keysDown.Contains(VkLeftWin) || _keysDown.Contains(VkRightWin);
        // Any other key means a Windows shortcut such as Ctrl + Win + Left, not hold-to-talk.
        bool isOnlyThisCombination = _keysDown.Contains(VkControl) && hasWin
            && _keysDown.All(key => key is VkControl or VkLeftWin or VkRightWin);

        if (isOnlyThisCombination && !_isPressed)
        {
            _isPressed = true;
            onPressed();
        }
        else if (!isOnlyThisCombination && _isPressed)
        {
            _isPressed = false;
            onReleased();
        }
    }
}
