# Individual beta access and budget controls

Implemented locally on 7 October 2026. This is invite-only access, not a full login, subscription billing, or enterprise account system. No production deployment or token issuance has been performed.

## What changed

The Mac sends `Authorization: Bearer sage_<64 hex characters>` to `/chat` and `/tts`. The legacy `x-sage-app-key` is not accepted. Each token identifies one operator-managed account. The server stores only its SHA-256 hash; the Mac stores the token in Keychain, entered via **Sage → Enter Access Token…**. Removing or replacing it cancels active work and clears conversation memory. Tokens remain bearer credentials: anyone possessing one can use its allowance until it is rotated or revoked.

A single SQLite-backed Cloudflare Durable Object owns account policies, per-account request counters, and global/account budget reservations. Account creation, rotation, revocation, and reservations use storage transactions. KV is deliberately not used for counters because simultaneous requests must see consistent state. See [Cloudflare's storage documentation](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/).

Each account allows 20 authenticated requests per UTC minute, alongside the existing per-IP abuse limiter. Each account has an operator-set monthly allowance. The service also has shared daily and monthly limits. Account usage follows the account ID, so rotating a token does not reset its allowance. Revocation blocks future authentication and future reservations; it cannot undo an already dispatched provider request.

## Budget policy

Amounts are integer millionths of USD: `1000000` represents $1. These are **conservative reservations, not measured provider charges or customer prices**. The checked-in beta settings are:

| Setting | Value | Meaning |
|---|---:|---|
| `CHAT_RESERVATION_MICRO_USD` | 1000000 | Reserve $1 before each paid chat attempt |
| `TTS_RESERVATION_MICRO_USD` | 100000 | Reserve $0.10 before each voice request |
| `GLOBAL_DAILY_BUDGET_MICRO_USD` | 10000000 | Stop admitting paid calls after $10 reserved per UTC day |
| `GLOBAL_MONTHLY_BUDGET_MICRO_USD` | 100000000 | Stop admitting paid calls after $100 reserved per UTC month |

Before chat inference, the Worker calls the [free token-counting endpoint](https://platform.claude.com/docs/en/build-with-claude/token-counting) with the same model, system prompt, and conversation, including images. It rejects counts above 100,000 and fails closed if counting is unavailable or malformed. Counting adds a network round trip and counts are estimates. Output remains capped at 2,048 tokens (512 for onboarding).

The reservation floor is $0.35 for chat and $0.10 for speech; smaller/missing/invalid policies fail closed. The chat floor includes headroom over 100,000 input tokens at the current Sonnet 5.5 cache-write rate plus maximum output. Prices were checked against [Anthropic's pricing](https://platform.claude.com/docs/en/about-claude/pricing) and [ElevenLabs' API pricing](https://elevenlabs.io/pricing/api) on 7 October 2026. Recheck the floors against your actual contract, voice, and model before deployment and whenever these change. Provider-controlled fallbacks are disabled because they could change the model price.

Reservations are never refunded automatically: an interrupted or ambiguous request may still be charged upstream. Each transport retry reserves again before dispatch; follow-along and onboarding also consume allowances, as does every ElevenLabs sentence preparation. Consequently allowances run out sooner than actual invoice spend. This is intentional for a bounded beta; later billing can reconcile measured usage without weakening admission control.

Missing/unavailable storage or policy blocks paid calls. Monthly allowance exhaustion returns 429; shared-budget exhaustion returns 503. Account request limits also return 429. These guards bound admitted reservations, not taxes, subscription fees, requests from other applications using the same provider key, or future pricing changes. Set provider-side limits/prepaid balances too. A dedicated provider project/key makes this meaningful.

## Local setup and migration

1. Add an independently generated `SAGE_ADMIN_KEY` to the ignored `worker/.dev.vars`. Keep `ANTHROPIC_API_KEY` and optional `ELEVENLABS_API_KEY`. The old `SAGE_APP_KEY` is unused. Do not distribute the admin key.
2. Run `cd worker && npx wrangler dev`. The checked-in configuration creates local Durable Object storage automatically.
3. In another terminal, set `SAGE_ADMIN_KEY` in your shell environment to the same local value, then run from `worker/`:

   ```bash
   node scripts/manage-access.mjs provision YOUR_ACCOUNT_ID 10000000
   ```

   This grants a $10 monthly **reservation allowance** and prints a newly generated token once. Treat that output as a credential. Running provision for an existing ID rotates its token and updates its allowance while preserving usage.
4. In Xcode, run the app normally. The plist needs only `WorkerBaseURL`; enter the issued token from the leaf menu. Previously bundled `AppKey` values are ignored.
5. To revoke access:

   ```bash
   node scripts/manage-access.mjs revoke YOUR_ACCOUNT_ID
   ```

Admin endpoints are `POST /admin/accounts/provision` with `{ accountID, monthlyLimitMicroUSD }` and `POST /admin/accounts/revoke` with `{ accountID }`. They require a separate `x-sage-admin-key` and the IP rate limiter. Tokens are returned with `Cache-Control: no-store`. There is no public issuance endpoint.

## Production activation — still required

Review the conservative limits and actual provider pricing first. Configure the `SAGE_ADMIN_KEY` Cloudflare secret, deploy the Worker with its Durable Object migration, then issue individual tokens. Set `SAGE_WORKER_URL` in the admin script's environment to the deployed HTTPS URL. Deliver tokens securely to intended beta users; do not place them in a distributed plist, website, repository, or shared build.

Deploy the client and server migration together: the updated app requires bearer tokens and an old Worker expects the retired shared-key header. No compatibility bypass is included. Existing developers also need a new individual token. Neither production configuration nor deployment was performed by this code change.

## Shortcut and execution structure

The default shortcut is **Control + Shift**. **Sage → Shortcut** offers Control + Shift, Option + Shift, and Command + Shift; the choice is persisted, and the menu/onboarding prompt read it dynamically. Exact matching excludes extra Control/Option/Command/Shift/Fn modifiers. Control + Option is not offered. The monitor remains listen-only, so the foreground application still receives key events; users may select another preset if their apps use a chosen modifier pair. Real keyboard and VoiceOver coexistence checks remain necessary in Xcode.

`ReplyExecutor` accepts injected capture and streaming collaborators and emits explicit text/sentence/point/follow-along events. It owns capture, provider retry, segment assembly, and pointing resolution. `SageSessionCoordinator` owns lifecycle, recording, settings, playback/UI reactions, and follow-along scheduling. Cancellation and current-reply identity remain with the coordinator so stale replies cannot publish into replacements.
