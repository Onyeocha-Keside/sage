# Sage for Windows

A native Windows client for Sage, in progress. It will use the same Cloudflare Worker as the Mac app. The Anthropic API key stays on the Worker and never goes in this app.

```
src/Sage.Core/         Logic ported from the Mac app, with no Windows APIs. Builds and tests anywhere.
src/Sage.Transcription/ On-device speech-to-text with sherpa-onnx. Builds and tests anywhere.
src/Sage.Windows/      Prototype of the Windows-only parts.
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
.\SagePrototype.exe --tour
```

Check each of these:

- A green arrow follows the mouse, and clicks pass straight through it.
- Holding **Ctrl + Win** prints `pressed`, including while another app is focused. Letting go prints `released`.
- Letting go does **not** open the Start menu.
- The arrow visits the top left, center and bottom right of every monitor, and its tip lands in the right place.
- The saved `tour-screen*.jpg` images don't contain the arrow.
- A yellow capture border doesn't appear. `--diagnose` reports whether Windows hid it.

Press Ctrl + C in the terminal to quit.

**3. A real question, without the microphone.** This needs a Worker that's deployed and a Sage access token (`sage_` followed by 64 hex characters). Never use an Anthropic key here.

```powershell
.\SagePrototype.exe --setup
.\SagePrototype.exe --ask "what am i looking at?"
```

`--setup` saves the Worker address to `%LOCALAPPDATA%\Sage\settings.json`. The token goes in Windows Credential Manager under `Sage/AccessToken`. `--ask` captures every monitor and sends the screenshots and your question to the Worker. The reply prints as it arrives and is spoken with a built-in Windows voice. The arrow flies to each thing Claude points at as that sentence starts. Hold **Ctrl + Win** to ask the same question again with a fresh screenshot. This interrupts any reply still playing.

Until the updated Worker that accepts `platform` is deployed, replies may say "mac".

**4. Talk to it.**

```powershell
.\SagePrototype.exe
```

The first run downloads the speech model, about 100 MB, from the sherpa-onnx GitHub releases. It's checked against a pinned SHA-256 and unpacked to `C:\ProgramData\Sage\models`. To download it ahead of time, run `--install-speech`. Then hold **Ctrl + Win**, ask your question out loud and let go. The audio is transcribed on the PC and never uploaded. Only the text and the screenshots go to the Worker. Holding the shortcut again stops the reply that's playing.

If nothing is heard, check that Windows lets desktop apps use the microphone (Settings > Privacy & security > Microphone). In a VM, also check that the microphone is passed through.

To test the speech model on any machine, set `SAGE_TEST_SPEECH_ARCHIVE` to the downloaded `.tar.bz2` and `SAGE_TEST_SPEECH_WAV` to a 16 kHz mono recording of "what is this button", then run `dotnet test`.

## What a VM can't prove

Test on a real PC before trusting these:

- Different scaling on two physical monitors
- Normal GPU behavior, since a VM may fall back to Direct3D software rendering
- x64 builds, if the VM is Windows on Arm
