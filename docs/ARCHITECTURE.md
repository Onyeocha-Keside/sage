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
| `Session/Reply/` | Stream-to-speech segmentation, pointing geometry, reply state, and user-facing failures |
| `Services/Networking/` | Worker transport, conversation wire models, and independently testable stream decoding |
| `Services/ScreenCapture/` | Screen geometry, JPEG capture, and local settle thumbnails |
| `Services/Permissions/` | Permission requests and polling |
| `Services/Input/` | Shortcut and user-activity monitoring |
| `Services/Transcription/` | Recording and Apple Speech recognition |
| `Services/Speech/` | Voice implementations and ordered sentence playback |
| `Services/Audio/` | Short system sound cues |
| `UI/` | Native menu and cursor rendering |

`SageSessionCoordinator` owns session lifecycle, recording/settings, playback and presentation reactions, and follow-along scheduling. `ReplyExecutor` owns capture, stream assembly, pointing resolution, and retry policy, accepting injected capture/streaming collaborators and emitting explicit events. Playback remains a separate service owned by the coordinator; it is not hidden inside the executor.

Cancellation ownership matters: a superseded reply cannot clear the current reply's notice; a cancelled playback loop cannot clear a replacement voice handle; late recognition callbacks cannot update a new recording. These rules are enforced with per-operation identities.

Screenshots are captured cursor-screen first, at most four to match the Worker contract. Follow-along captures one display before encoding, not every display followed by filtering. Invalid requested monitor numbers resolve to no pointing target. Monitor changes recreate the overlays; permission revocation stops active work. Initial multi-display capture still needs user-selectable scope before public release.

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
| `src/chat/input-token-limit.ts` | Free preflight counting before paid inference |
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
