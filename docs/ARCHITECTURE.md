# Sage architecture and ownership

Sage has three independently deployed surfaces: a native Mac app, a Cloudflare API Worker, and a static waitlist website. The pitch deck is a separate document, not a public website route.

## Native app

The legacy `leanring-buddy` directory, project, and scheme remain intact. Xcode uses filesystem-synchronized groups, so files added or moved under the app and test roots are discovered automatically.

| Directory | Owns |
|---|---|
| `App/` | App lifecycle, validated Worker URL, and individual Keychain credentials |
| `Session/` | Observable presentation state and coordination of a question/reply |
| `Session/Conversation/` | Bounded, in-memory text history |
| `Session/FollowAlong/` | Original goal, step budget, and follow-up instructions |
| `Session/Reply/` | Stream-to-speech segmentation, pointing geometry, reply state, latency timeline, and user-facing failures |
| `Session/Pointing/` | Keeping pointing targets on their content through scrolling: scroll-shift and visibility math, live tracking |
| `Services/Networking/` | Worker transport, conversation wire models, and independently testable stream decoding |
| `Services/ScreenCapture/` | Screen geometry, JPEG capture, and local settle thumbnails |
| `Services/Permissions/` | Permission requests and polling |
| `Services/Input/` | Shortcut and user-activity monitoring |
| `Services/Transcription/` | Recording, Apple Speech recognition, and when a released transcript counts as done |
| `Services/Pointing/` | Recent scroll movements and Accessibility anchors to the controls Claude points at |
| `Services/Speech/` | Voice implementations and ordered sentence playback |
| `Services/Audio/` | Short system sound cues |
| `UI/` | Native menu and cursor rendering |

`SageSessionCoordinator` owns session lifecycle, recording/settings, playback and presentation reactions, and follow-along scheduling. `ReplyExecutor` owns capture, stream assembly, pointing resolution, and retry policy, accepting injected capture/streaming collaborators and emitting explicit events. Playback remains a separate service owned by the coordinator; it is not hidden inside the executor.

Cancellation ownership matters: a superseded reply cannot clear the current reply's notice; a cancelled playback loop cannot clear a replacement voice handle; late recognition callbacks cannot update a new recording. These rules are enforced with per-operation identities.

Screenshots are captured cursor-screen first, at most four to match the Worker contract. Follow-along captures one display before encoding, not every display followed by filtering. Invalid requested monitor numbers resolve to no pointing target. Monitor changes recreate the overlays; permission revocation stops active work. Initial multi-display capture still needs user-selectable scope before public release.

## Latency and pointing freshness

The time from key release to first sound is the product's main quality bar. Screens are captured at key release, overlapping with transcript finalization. The transcript is treated as done once Apple's live partial result has been unchanged for 0.35s (no sooner than 0.25s and no later than 1.2s after release). Only a reply's first chunk may end at a comma. The Worker bounds input size locally instead of calling the count endpoint. `ReplyLatencyTimeline` logs per-stage timings (log category `latency`) once per reply, so changes can be measured.

A pointing target comes from a screenshot that can be seconds old. `PointingTargetTracker` anchors each target as soon as its tag arrives. It uses the Accessibility element at that spot when one exists, a specific control rather than a whole page. Otherwise it shifts the target by the trackpad scrolling over its window since the screenshot. Before a target is shown, and while the user scrolls during pointing, its live position is re-read and the cursor glides with it. A target scrolled out of view parks the cursor at the nearest edge, aimed toward it, with a "scroll up/down" bubble. If the only estimate comes from a line-based mouse wheel (a guess), the target is dropped rather than shown in the wrong place. Chromium and Electron apps are asked once for their accessibility tree (`AXManualAccessibility`).

In follow-along, `ScreenSettleTracker` decides when the screen has finished reacting. It samples 96px thumbnails every 0.1s, listing displays and windows once per wait. Sage looks once the screen has visibly changed from the thumbnail taken just before the action and has then held still for 0.25s. With no visible change, it looks after 1.2s, and it never waits past 4s. Scrolling during follow-along keeps the cursor pointing (it rides with the content) instead of clearing it.

Two follow-along refinements build on that:

- **Early point.** With a step, Claude may add `[NEXT:label]` after `[FOLLOW]`: the exact visible text of the control the user will likely need on the next screen. When that screen's screenshot is captured, `OnScreenTextLocator` (Vision, on-device) looks for that text. If it appears exactly once, Sage points there before Claude answers. If Claude's first sentence then doesn't point, the guess is withdrawn.
- **Late re-look.** Until Claude's first words arrive, the coordinator keeps comparing the screen with the thumbnail Sage looked at. A large change (average difference of 4 or more) means the page was still loading. The reply is cancelled, the settle check restarts, and Sage looks once more (at most once per step, and the step isn't counted twice).

Deployment order: `[NEXT:...]` must ship in the app before the Worker prompt that emits it. Older app builds read unknown bracketed text aloud.

## Cursor color and circling

The **Cursor** menu picks the overlay color through `CursorColorOption`, stored in UserDefaults. The color reaches every indicator through the SwiftUI environment (`sageCursorColor`, `sageCursorTextColor`). **Invisible (Voice Only)** hides the overlay entirely and skips pointing. It also adds a note to the outgoing message, but not to memory, asking Claude to describe locations in words instead of using point tags.

While the shortcut is held, `CircleGestureRecorder` samples the mouse and the overlay draws a short fading trail. At release, `CircleGestureDetector` looks for the most recent closed loop: the path returns near its start, the pen's direction turns at least about 300°, and the loop is at least 24pt with a sensible aspect ratio. Turning uses prefix sums, so the search is about a millisecond. When a loop is found:

- The rough loop is replaced by a clean shape, `CircledArea.focusRect`: a perfect circle when the loop was roughly round (aspect ratio at least 0.75), otherwise a smooth ellipse, padded slightly. It draws itself in on screen and stays until the reply finishes.
- Only that screen is captured. Outside the ring it is dimmed (35% black) and the ring is drawn in red, described in the image label.
- A sharper close-up of the area, with the same marking, goes first. It is marked `isZoomedDetail` so it never counts as a screen for pointing.
- A focus note is added to the message, but not to memory, asking Claude to answer about exactly the circled thing: what it is, what it means here, and how to fix it if something's wrong.
- If nothing was said, the question defaults to "what's this that i circled?".

## Naming conventions

Name files after their primary type or responsibility. `SageSessionCoordinator` owns session orchestration; `SageAPIClient` talks to the Worker; `ClaudeStreamDecoder` stays provider-specific. `ChatProtocol` holds transport models, `ReplyAssembly` holds a streamed reply's accumulated state, and `CursorAppearance` defines overlay styling. Route filenames identify their handlers; standard entry points such as `index.ts` stay conventional.

The app coordination folder is now `Session/`. The legacy Xcode project, scheme, and root folder remain unchanged. Wire values such as `companion`, HTTP routes, and pointing tags remain unchanged by naming work.

## Worker

| Module | Owns |
|---|---|
| `src/index.ts` | Route dispatch and common error boundary |
| `src/bindings.ts`, `src/api-limits.ts` | Binding contracts and server-owned model/limits |
| `src/http/` | Bounded JSON decoding and responses |
| `src/security/` | Admin-key comparison and IP rate-limit policy |
| `src/routes/` | Chat, voice, and public waitlist use cases |
| `src/chat/` | Conversation validation, field allowlisting, history cache markers |
| `src/access/` | Individual accounts, token hashes, atomic request and budget allowances |
| `src/chat/input-token-limit.ts` | Local upper bound on input tokens (text bytes plus image header dimensions) before paid inference, with no extra provider round trip |
| `src/prompts.ts` | Server-owned instructions and pointing/follow-along tag contract |

No provider keys go into the website or app sources. Individual tokens identify invite-only accounts. Hashes and atomic account/global usage reservations live in a SQLite-backed Durable Object; the Mac token lives in Keychain. There is no bundled shared credential. See [access and budgets](ACCESS_AND_BUDGETS.md) for policy, provisioning, and migration.

Public requests fail closed if the rate limiter is missing or throws; binding-free localhost development is allowed. Limits apply to actual streamed bytes, independently of Content-Length. Waitlist/voice bodies are limited to 16 KiB; chat bodies to 15 MiB. Provider operations have deadlines and request cancellation signals. Upstream response content is not echoed into error diagnostics.

## Website and documents

The website remains static HTML/CSS/JavaScript. The two demo scripts intentionally share globals and depend on script order. The next substantive demo change should introduce an explicit controller/scenario interface and separate waitlist code; introducing a bundler now is not required. Remove obsolete style rules only with desktop/mobile visual checks.

`docs/pitch/` contains its own editable deck, PDF, and speaker notes. Keep strategic hypotheses separate from implemented product claims.

## Verification

- `cd worker && npm ci && npm run typecheck && npm test`: local provider-mocked regression tests, with no API credits or production KV writes.
- `bash scripts/check-swift.sh`: app and Swift Testing source type-checking plus executable logic regression checks. It creates no app bundle and does not modify TCC permissions.
- Xcode Cmd+U: the full Swift Testing suites in their intended app-host environment.
- `wrangler deploy --dry-run`: bundle validation only; not a deployment.

GitHub checks validate the Worker and JavaScript syntax. Worker deployments run type checking and regression tests before publishing. Native permission/audio/UI behavior still requires real-device testing in Xcode.
