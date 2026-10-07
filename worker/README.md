# Sage API Worker

The API dispatches `/chat`, `/tts`, `/waitlist`, and `/health` from `src/index.ts`. Provider credentials belong in Cloudflare secrets or the ignored local `.dev.vars`; never add them to source or test fixtures.

## Checks

```bash
npm ci
npm run typecheck
npm test
npx wrangler deploy --dry-run
```

Tests mock provider fetches and KV storage. They make no real provider requests, consume no credits, and write no production waitlist entries. GitHub runs these tests before Worker deployments.

## Module boundaries

- `http/`: actual-byte body limits, JSON object decoding, and responses.
- `security/`: admin-key validation and public fail-closed rate limiting.
- `routes/`: chat, voice, and waitlist behavior.
- `chat/`: validated/allowlisted messages and nonmutating history-cache markers.
- `config.ts`, `env.ts`, `prompts.ts`: limits, bindings, and model instructions.

See `../docs/PRODUCTION_REVIEW.md` for remaining release blockers and `../docs/ARCHITECTURE.md` for app/API ownership.

Wrangler is pinned. The `sharp` override pins its optional development image dependency to 0.35.5 to address the reported advisories. Recheck npm audit and Wrangler bundling when updating the toolchain; do not use a force downgrade as an audit workaround.

## Individual beta access

Shared app keys are retired. `/chat` and `/tts` require individually issued bearer tokens. `ACCESS_LEDGER` stores hashed credentials and atomically reserves account/global allowances; admin routes require the separate `SAGE_ADMIN_KEY`. No production migration has been performed. Read [setup, budget assumptions, and migration](../docs/ACCESS_AND_BUDGETS.md) before deploying. The native menu stores individual tokens in Keychain.
