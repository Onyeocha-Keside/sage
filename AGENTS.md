# Sage - Agent Instructions

## Overview

Sage is a macOS menu bar companion. It lives entirely in the status bar (no dock icon, no main window). Holding **Control + Option** records your voice and transcribes it on-device with Apple Speech. On release, Sage screenshots every display and streams a reply from Claude through a Cloudflare Worker. It speaks each sentence as soon as it's complete (free Mac voice or ElevenLabs). A green cursor overlay flies to each UI element Claude tags, timed to the sentence that talks about it.

All API keys live on the Worker. The app only knows the Worker URL and a shared app key, both read from a git-ignored `SageSecrets.plist`.

Sage started as a fork of Clicky (MIT). The Xcode project and folder are still named `leanring-buddy`. Don't rename them.

## Architecture

- **App type**: menu bar only (`LSUIElement=true`)
- **UI**: a native `NSMenu` from the leaf status item (system styling, automatic light and dark mode, rebuilt on every open via `menuNeedsUpdate`), plus a SwiftUI cursor overlay hosted in one transparent `NSWindow` per screen
- **Concurrency**: the target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so every type is main-actor by default. Delegate callbacks are `nonisolated` and hop back with `Task { @MainActor in ... }`
- **AI**: Claude Sonnet 5.5 (`claude-sonnet-5-5`, effort `low`, `fallbacks: "default"`) via the Worker's `/chat`, streamed over SSE
- **Speech-to-text**: Apple Speech framework (`SFSpeechRecognizer`), on-device when supported. Free
- **Text-to-speech**: `SpeechVoice` protocol with two implementations, `AppleSpeechVoice` (free, `AVSpeechSynthesizer`) and `ElevenLabsSpeechVoice` (Worker `/tts`). `SpeechPlaybackQueue` plays sentences in order, prefetches audio, and falls back to the Mac voice per sentence on failure
- **Streaming speech**: `StreamingResponseSegmenter` splits the SSE text into sentences and `[POINT:...]` tags as they complete, so speech starts before Claude finishes
- **Pointing**: Claude writes `[POINT:x,y:label]` or `[POINT:x,y:label:screenN]` *before* the sentence about that element. `CompanionManager` attaches each tag to the next sentence. When that sentence starts playing, it publishes a `PointingTarget`, and `SageCursorView` flies there along a bezier arc. Multiple tags make a walkthrough: the cursor hops between targets, holds while Sage is still talking, then flies home
- **Screen capture**: ScreenCaptureKit, all displays, cursor screen first, Sage's own windows excluded, max 1280px JPEG
- **Follow-along mode**: for tasks that span screens, Claude gives one step and ends with `[FOLLOW]`. `UserActivityWatcher` then waits for a click, key or scroll. The first action gets instant feedback (sound, spinner, cursor stops pointing). `ScreenChangeDetector` compares tiny 96px grayscale thumbnails every 0.25s until the screen stops changing (min 0.35s after a click, 1.2s after typing, max 4s). Then Sage re-screenshots only the cursor's screen and asks Claude to continue toward the original goal. It ends when Claude omits `[FOLLOW]`, on a new question, after 8 steps, or after 2 minutes idle. The cursor pulses while watching
- **Sound cues**: macOS system sounds via `SoundEffectsPlayer` (Tink = listening, Pop = sent, Bottle = looking again). Toggle in the panel
- **Hotkey**: listen-only `CGEvent` tap on `flagsChanged`, plus AppKit global/local `flagsChanged` monitors as a backup, sharing one pressed state. Retried on every permission poll until the tap installs
- **Slow networks**: one quiet retry on a 5xx before any words arrive, a spoken "one sec, my connection's a little slow" (Mac voice) after 6s of silence, a 30s request timeout, distinct offline and timeout messages, and JPEG quality 0.72
- **Prompt caching**: the Worker marks the system prompt and the end of the conversation history with `cache_control`, so follow-along steps reuse them (verified: about 1.7k tokens read from cache, first words 3.4s → 2.0s)
- **Diagnostics**: key steps log via `os.Logger` (subsystem `com.kesideonyeocha.sage`). Watch live with `/usr/bin/log stream --predicate 'subsystem == "com.kesideonyeocha.sage"'`
- **Signing**: Automatic, Personal Team `VMNRHNCYZK`. A stable identity keeps macOS permissions across rebuilds (ad-hoc signing made them reset on every build)
- **Analytics**: none

### Worker (`worker/`)

| Route | Purpose |
|-------|---------|
| `GET /health` | Shows whether the keys are configured |
| `POST /chat` | Body `{ mode: "companion" \| "onboarding", messages }`. The Worker adds the model, `max_tokens`, effort, fallbacks and the system prompt (`src/prompts.ts`) and validates the message shape (alternating roles, text/JPEG/PNG only, ≤4 images, ≤41 messages) |
| `POST /tts` | Body `{ text }` (≤1000 chars) → ElevenLabs `eleven_flash_v2_5` MP3 |
| `POST /waitlist` | Public (no app key). Body `{ email, platform }`. Allowed origins only, honeypot `website` field, per-IP rate limit, stored in the `WAITLIST` KV namespace as `signup:<email>` |

Deployed at `https://sage-api.sage-api.workers.dev` (Cloudflare account onyeocha.keside@gmail.com). Redeploy with `cd worker && npx wrangler deploy`.

The landing page is a separate classic Cloudflare Pages project, `sage-landing`, served at `https://sage.kesideonyeocha.com` (GoDaddy CNAME `sage` → `sage-landing-4zo.pages.dev`). Deploy steps are in `website/README.md`. Never run `wrangler pages ...` from inside `worker/`: wrangler picks up that folder's config and deploys the API under the wrong name.

Every POST needs the `x-sage-app-key` header, which must equal the `SAGE_APP_KEY` secret (compared in constant time). Requests are rate-limited per IP (20/min, `[[ratelimits]]` binding in `wrangler.toml`).

Secrets: `ANTHROPIC_API_KEY`, `SAGE_APP_KEY`, optional `ELEVENLABS_API_KEY`. Var: `ELEVENLABS_VOICE_ID`. Local dev reads them from `worker/.dev.vars` (git-ignored).

**The prompt and the app's parser must agree.** If you change the tag format in `prompts.ts`, update `PointingTag.swift` and its tests.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `App/SageApp.swift` | ~50 | `@main` entry and app delegate. Creates the menu bar manager, starts the companion, and opens the panel if setup is incomplete |
| `App/AppConfiguration.swift` | ~80 | Reads `WorkerBaseURL` / `AppKey` from `SageSecrets.plist` and builds authenticated Worker requests |
| `App/SageSecrets.plist` | — | **Git-ignored.** Copied from `config/SageSecrets.example.plist` |
| `Companion/CompanionManager.swift` | ~540 | The conductor: hotkey → dictation → screenshot → Claude stream → sentence queue → pointing. Also owns onboarding, voice choice, conversation history (last 10 turns, text only) and spoken error messages |
| `Companion/PermissionsCoordinator.swift` | ~190 | Polls and requests mic, speech recognition, accessibility, screen recording and screen content permissions |
| `Companion/PointingTag.swift` | ~140 | Parses `[POINT:...]` tags and maps screenshot pixels to AppKit global coordinates (`PointingTarget`) |
| `Companion/StreamingResponseSegmenter.swift` | ~160 | Turns streamed text into `.speech` / `.pointing` / `.followAlong` segments. Never speaks a half-written tag |
| `Services/ClaudeClient.swift` | ~190 | Builds the messages, POSTs to `/chat` and parses SSE (`text_delta`, refusal, error) |
| `Services/ScreenCaptureService.swift` | ~140 | Multi-monitor JPEG capture with labels and geometry |
| `Services/Speech/SpeechVoice.swift` | ~45 | `SpeechVoice` protocol and `PreparedSpeech` |
| `Services/Speech/AppleSpeechVoice.swift` | ~130 | Free Mac voice. Picks the highest-quality English voice installed |
| `Services/Speech/ElevenLabsSpeechVoice.swift` | ~150 | ElevenLabs via the Worker, played with `AVAudioPlayer` |
| `Services/Speech/SpeechPlaybackQueue.swift` | ~120 | Ordered sentence playback, start callbacks, per-sentence Mac-voice fallback |
| `Services/Transcription/AppleSpeechTranscriber.swift` | ~150 | `SFSpeechRecognizer` session for one push-to-talk recording |
| `Services/Transcription/PushToTalkDictationManager.swift` | ~250 | `AVAudioEngine` mic capture, transcript finalization, audio level for the waveform |
| `Services/Input/GlobalPushToTalkShortcutMonitor.swift` | ~200 | Control + Option detection: `CGEvent` tap plus AppKit monitor backup, Input Monitoring request, logging |
| `Services/Input/UserActivityWatcher.swift` | ~110 | Follow-along: waits for a click, key or scroll, then a settle delay, with an idle timeout |
| `Services/ScreenChangeDetector.swift` | ~110 | Tiny grayscale thumbnails of the display under the mouse, used to detect when the screen has settled |
| `Services/SoundEffects.swift` | ~65 | System-sound cues and their on/off preference |
| `UI/MenuBar/MenuBarController.swift` | ~330 | Leaf status item and the native menu: status line with colored dot, setup and permission rows, Start, Voice submenu, Sounds, Replay Intro, About, Quit |
| `UI/Overlay/OverlayWindowManager.swift` | ~75 | One transparent click-through `OverlayWindow` per screen |
| `UI/Overlay/SageCursorView.swift` | ~430 | Cursor following, welcome bubble, flight animation, pointing hold and return |
| `UI/Overlay/CursorIndicatorViews.swift` | ~115 | Triangle, waveform, spinner, speech bubble |
| `UI/DesignSystem.swift` | ~40 | Cursor overlay colors and `Color(hex:)`. The menu uses system styling |
| `leanring-buddyTests/SageLogicTests.swift` | ~170 | Swift Testing: tag parsing, segmenter, coordinate mapping |
| `worker/src/index.ts` | ~420 | Worker routes, auth, rate limit, validation, prompt caching, and the public `/waitlist` route (CORS-restricted, honeypot, stored in KV) |
| `website/sage/index.html` | ~310 | Short waitlist landing page: hero, illustrated landscape, animated Canva/Excel demos, and footer |
| `website/sage/privacy.html` | ~30 | Separate privacy and waitlist data details linked from the landing page |
| `website/sage/styles.css` | ~611 | Cream and sage design tokens, Instrument Serif and Inter, Mac mock styling, responsive and reduced-motion rules. No `backdrop-filter` inside the scaled mock (Chrome stops painting its children) |
| `website/sage/script.js` | ~487 | Scales/crops the Canva demo, loops the animated walkthrough with pause/replay and optional prerecorded Mac voice narration, posts signups with timeout handling |
| `website/sage/excel-demo.js` | ~117 | Excel scenario, app selector, Dock app switches, and invoice filtering |
| `website/sage/excel-demo.css` | ~66 | Excel for Mac ribbon, worksheet, filter panel, and scenario selector styling |
| `website/sage/mobile.css` | ~100 | Compact phone layouts for the animated Canva/Excel demos and playback controls |
| `website/sage/assets/dock/` | — | Native macOS app/system icon PNG exports for the illustrated Dock |
| `website/sage/assets/voice/` | — | Thirteen prerecorded Mac voice WAV clips for reliable demo narration |
| `worker/src/prompts.ts` | ~70 | Companion and onboarding system prompts |

## Build & Run

```bash
# Worker (local)
cd worker && npm install && npx wrangler dev     # needs worker/.dev.vars

# App
open leanring-buddy.xcodeproj                     # scheme: leanring-buddy, Cmd+R; tests: Cmd+U
```

**Do NOT run `xcodebuild` from the terminal.** It invalidates TCC permissions (screen recording, accessibility, and so on). Type-checking with `swiftc -typecheck` is fine because it produces no app bundle.

Known non-blocking warnings: Swift 6 concurrency warnings. Don't try to fix them.

## Code Style & Conventions

### Naming

- Be as clear and specific as possible. Optimize for clarity over brevity: someone with zero context should understand a name on sight
- No single-character names
- Keep argument names the same as the variables passed in

### Clarity

- Clear beats clever. Use more lines if it reads better
- Comments explain *why*, especially for AppKit bridging and timing tricks

### Swift / SwiftUI

- SwiftUI for UI unless only AppKit can do it (`NSPanel`, overlay windows)
- UI state on the main actor; async/await for asynchronous work
- Menu bar UI stays a native `NSMenu`: system font, SF Symbols as template images, no custom colors. The user prefers it simple and light on the eyes, like other menu bar apps
- Each file imports every module it uses members from (`MemberImportVisibility` is on)

### Do NOT

- Add features or refactors beyond what was asked
- Rename the `leanring-buddy` folder, project, or scheme
- Commit `SageSecrets.plist` or `worker/.dev.vars`
- Run `xcodebuild` from the terminal

## Git Workflow

- Branches: `feature/description` or `fix/description`
- Commit messages: imperative mood, explain the why
- Don't force-push to main

## Self-Update Instructions

When a change affects this file (new or deleted files, architecture, build steps, conventions, or a line count drifting by more than 50), update it. Don't update it for small edits.
