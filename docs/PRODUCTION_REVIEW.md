# Production review — 6 October 2026

Assessment: a useful prototype with sensible app/service separation, but not ready for an unrestricted public paid release. This review changes architecture and fixes reproduced failure paths; it is not a certification or a complete security audit.

## Fixed in this pass

| Failure | Previous behavior | Correction and evidence |
|---|---|---|
| Untrusted request size | Only Content-Length checked; absent or understated headers bypassed the 15 MiB guard; public waitlist had no guard | Bounded stream reader, route-specific byte limits; tests cover streamed chunks and dishonest headers |
| JSON schema | `null` caused property access failures and 500s | Require a JSON object; test null, primitives, arrays, malformed JSON across all POST routes |
| Empty/foreign chat content | Empty block arrays and client-controlled provider fields could reach Anthropic | Reject empty content, malformed base64 shape, assistant images, and unknown modes; allowlist forwarded fields |
| Premature stream EOF | A disconnected stream was treated as a finished answer | Separate decoder requires message_stop; malformed JSON and max_tokens truncation fail clearly |
| Diagnostic privacy | Final spoken questions were printed and logged publicly | Transcript text removed; provider error bodies/details no longer forwarded or logged |
| Cancellation ownership | Old speech cleanup/cancellation or recognizer callbacks could affect replacements; old reply cleanup could cancel a new notice | Identity guards in reply, playback, voice cancellation, and recognition; interrupted playback regression check |
| Capture scope/limits | Follow-along captured every display before discarding extras; >4 displays exceeded the Worker limit | Select before capture; cursor-first maximum four; invalid monitor/geometry targets rejected |
| Monitor lifecycle | Overlays retained old monitor geometry | Rebuild overlays on screen-parameter changes |
| Permissions/lifecycle | Overlay/hotkey could continue after permissions changed; stop left pending work/state | Stop active work on revocation; guard recording/setup; cancel pending lifecycle work and reset state |
| Misconfigured transport | Relative addresses and remote HTTP accepted as configured | Require HTTPS except explicit local development hosts |
| Billing guard failure | Rate limiter failures silently allowed public traffic | Fail closed with 503; unit tests verify chat, voice, and waitlist |
| Verification gap | Worker had no automated tests or type-check; deployments published without checks | Strict TS, provider-mocked tests, PR checks, and deploy prerequisites |

Provider streaming completion contract: https://platform.claude.com/docs/en/build-with-claude/streaming . Unknown event types remain ignored; only text deltas are spoken. The decoder follows the provider's single-JSON-data-line format, not a general-purpose multi-line SSE parser.

## Follow-up implemented — 7 October 2026

- Individual invite-only bearer tokens replace bundled shared keys. Tokens are entered through the menu, stored in Keychain, hashed server-side, rotatable, and revocable. An atomic Durable Object enforces account minute/month allowances and global daily/monthly reservations. Token-count preflight bounds chat input; retries reserve again; provider-controlled fallbacks are disabled. These are conservative admission reservations, not reconciled invoice spending. Production provisioning, deployment, pricing review, and provider-side caps remain required. See [access and budget setup](ACCESS_AND_BUDGETS.md).
- Shortcut presets are saved in the native menu, default to Control + Shift, and use exact modifier matching. Control + Option is not offered. Menu and onboarding follow the selection. Live VoiceOver/keyboard testing remains required.
- `ReplyExecutor` now owns capture, stream assembly, pointing resolution, and pre-text retry policy behind injected collaborators and explicit events. The coordinator retains lifecycle, UI/playback, and follow-along scheduling. Executable regression checks cover these boundaries and cancellation.

## Before a public paid release

1. **Activate and validate access controls.** The invite-only implementation needs the new admin secret and Durable Object migration deployed together with the client, plus individually issued tokens. Validate actual provider pricing against reservation floors and configure provider-side caps. Subscription billing, recovery, self-service login, organization isolation, and invoice reconciliation remain future product work.
2. **Live shortcut accessibility checks.** Configurable exact-matching presets are implemented; test with VoiceOver, common app shortcuts, both modifier sides, menu selection during recording, and rapid press/release on hardware. Modifier-only pairs can still overlap foreground app shortcuts.
3. **Capture consent and scope.** Initial questions still send up to four displays. Add a visible active-session indicator and a user-controlled screen/window scope. Define retention, deletion, and provider processing using the actual provider account settings; “not saved by the app” does not describe upstream retention.
4. **Signed release lifecycle.** Verify Developer ID signing, hardened runtime, notarization, first-run permissions, upgrades, and crash behavior on clean Macs. Personal-team developer builds and local type-checking are not distribution evidence.
5. **Live accuracy and recovery.** Build a representative workflow benchmark. Measure wrong targets and task outcomes, including Retina scaling, disconnected displays, menus, changing layouts, interrupted speech, noisy audio, slow/offline networks, and partial answers. Coordinate validity does not establish semantic pointing correctness.
6. **Provider/load failures.** Local tests mock upstream services. Verify streaming deadlines, disconnect cancellation, capacity, quota exhaustion, and actual provider payload acceptance in staging with controlled budgets.

## Structural follow-ups

- Reply execution is extracted with capture/stream injection and explicit events. Add hardware playback/lifecycle integration coverage before further session features; the coordinator still owns several lifecycle concerns.
- Apple Speech audio-tap callbacks touch main-actor-default state from an audio callback. This deserves a dedicated thread-ownership design and hardware testing; existing Swift concurrency warnings were intentionally left alone per repository instructions.
- The activity watcher notices any click/key/scroll, not whether the indicated task was performed. Never claim it verifies completion; the next screenshot only gives the model another chance to assess it.
- Screen-content approval is remembered in UserDefaults, not authoritative live ScreenCaptureKit state. Permission revocation is handled through polled microphone/speech/accessibility/screen-recording flags, but screen-content-specific recovery still needs testing.
- UI bubble edge placement, screen-update energy cost, large speech-preparation queues, and an explicit maximum recording duration deserve follow-up real-device checks.
- Extract waitlist/controller/scenario modules before growing the website demo further. The current global script coupling and obsolete CSS are maintenance liabilities rather than release-level API security issues.
- Add test coverage for transport cancellation, real voice continuations, recording generation changes, display selection, and permission changes. Logic regression checks do not exercise macOS permission dialogs or real audio hardware.

## Business readiness

Accounts, billing, team administration, approved company procedure ingestion, organization isolation, and contractual data handling are not implemented. Those are product milestones for a B2B offer, not reasons to fabricate enterprise readiness in the deck.

## Verification record

Local Worker tests, Swift logic checks and type-checks, JavaScript syntax checks, and Worker dry-run bundling are required for this change. No app bundle was rebuilt, production service deployed, keys rotated, waitlist read/exported, or customer data used. The dependency audit reported zero vulnerabilities after pinning Wrangler and overriding its optional sharp dependency to patched 0.35.5; bundle validation passed with that override. A force downgrade of Wrangler was not used.


Follow-up verification (7 October): 18 provider-mocked Worker regressions, strict TypeScript checking, Swift app/test type-checks and executable shortcut/executor regression checks passed. An isolated real local Cloudflare runtime with dummy credentials verified Durable Object provisioning, individual authentication, legacy-key rejection, and revocation without paid provider calls. Worker dry-run bundling passed. No production service was changed. Keychain UI, actual audio/keyboard events, and VoiceOver coexistence still need an Xcode hardware run.
