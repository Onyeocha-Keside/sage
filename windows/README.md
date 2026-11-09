# Sage for Windows

A native Windows client for Sage, in progress. It will use the same Cloudflare Worker as the Mac app. The Anthropic API key stays on the Worker and never goes in this app.

```
src/Sage.Core/         Logic ported from the Mac app, with no Windows APIs. Builds and tests anywhere.
src/Sage.Windows/      Prototype of the Windows-only parts. Makes no network calls yet.
tests/Sage.Core.Tests/ Unit tests, ported from leanring-buddyTests where the behavior is shared.
```

All positions are **physical desktop pixels with a top-left origin**. A monitor left of or above the primary one has negative coordinates. The Mac app's bottom-left flips must not be copied here.

## Build

Works on a Mac or on Windows. A Mac can compile the app but can't run it.

```bash
cd windows
dotnet test tests/Sage.Core.Tests

# Use win-arm64 for a Windows VM on Apple Silicon, win-x64 for most PCs.
dotnet publish src/Sage.Windows -c Release -r win-arm64 --self-contained \
  -p:PublishSingleFile=true -o publish/win-arm64
```

## Try it on Windows 11

Copy `SagePrototype.exe` to the VM or PC and open a terminal in that folder.

**1. Automatic checks.** These briefly move your mouse and show a magenta arrow.

```powershell
.\SagePrototype.exe --diagnose
```

They cover monitor detection, mapping screenshot positions to the desktop, overlay placement, capture, and whether the overlay stays out of screenshots. Screenshots are saved to `%TEMP%\SagePrototype`.

**2. By hand.**

```powershell
.\SagePrototype.exe
```

Check each of these:

- A green arrow follows the mouse, and clicks pass straight through it.
- Holding **Ctrl + Win** prints `pressed`, including while another app is focused. Letting go prints `released`.
- Letting go does **not** open the Start menu.
- The arrow visits the top left, center and bottom right of every monitor, and its tip lands in the right place.
- The saved `tour-screen*.jpg` images don't contain the arrow.
- A yellow capture border doesn't appear. `--diagnose` reports whether Windows hid it.

Press Ctrl + C in the terminal to quit.

## What a VM can't prove

Test on a real PC before trusting these:

- Different scaling on two physical monitors
- Normal GPU behavior, since a VM may fall back to Direct3D software rendering
- x64 builds, if the VM is Windows on Arm
