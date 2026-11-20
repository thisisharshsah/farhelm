# 0016: Lens as a hosted product: Cloudflare Worker, D1, passkeys and device pairing

Status: accepted, 2026-11-17. User direction the same day: make the glasses app more advanced, reachable at its own address through DNS, enterprise grade and premium looking; the address is `lens.aurovie.com` and sign-in uses passkeys. Supersedes the deployment and access parts of [ADR 0015](0015-glasses-web-app.md) (Pages Functions and the shared access key). **Checked locally only**: the API tests run in workerd with a real local D1, and the whole flow (passkey sign-up and sign-in, pairing, synced notes and apps, revocation) passes in Chrome with a virtual authenticator against the built app. Deployed to `lens.aurovie.com` the same day. The chat and the redesigned console are in [ADR 0017](0017-lens-chat.md).

## Context

Meta's Web Apps have no camera, microphone or notifications, and the glasses cannot hold a passkey or show a QR code anyone else can see. Meta already ships widgets (calendar, reminders, weather, stocks), captions, translation, navigation and a teleprompter, so Lens adds what Meta does not: the owner's own apps and data, Companion, and later an assistant through Farhelm. It must work when the Mac is off, so it cannot run on the Mac behind the Farhelm tunnel.

## Decision

- **Hosting.** One Cloudflare Worker with static assets: the console at `/`, the glasses app at `/glasses` (separate bundles), and the API at `/api/*` (`run_worker_first`). Workers rather than Pages, since Cloudflare now builds new full-stack features on Workers. Custom domain only; `workers.dev` and preview hosts are off, so the only host names are `lens.aurovie.com` and `localhost` in development.
- **API.** Hono with thin routes, zod contracts in `src/shared/api.ts` shared with both clients, typed errors, one structured log line per request, Workers observability on.
- **Data.** D1 (SQLite) with append-only migrations. This is Lens's own store, separate from Farhelm's; the repository's hosted-Postgres direction is for Farhelm's control plane and is unchanged.
- **Accounts.** Passkeys via SimpleWebAuthn behind a narrow port (`worker/webauthn.ts`). First account by the `SETUP_CODE` secret, the rest by single-use owner invites; the account row is only written while its grant still holds, so racing sign-ups cannot both win. Account management requires a console session.
- **Glasses.** OAuth 2.0 device authorization grant (RFC 8628) shape: consonant-only 8-letter user code, a long secret device code, polling with `slow_down`, single-use consumption. The glasses get their own `glasses` session.
- **Sessions.** Opaque random tokens in `__Host-` cookies (HttpOnly, Secure, SameSite=Lax), stored as SHA-256, sliding expiry (30 days console, 90 glasses), revocable per device, audited.
- **Hardening.** Same-origin check on writes, JSON-only bodies, Workers rate limiting on sign-in, pairing and uncached searches, `no-store` on account data, CSP and other headers through `_headers`, daily cleanup by cron.
- **Tooling.** `@cloudflare/vite-plugin` runs the Worker and D1 in workerd during `vite dev` and builds both; `@cloudflare/vitest-plugin` runs API tests in workerd. `scripts/release.mjs` deploys idempotently and sets missing secrets.

## Consequences

- New dependencies in `glasses/` only: hono, zod, @simplewebauthn/server and /browser, wrangler, the Cloudflare Vite and Vitest plugins, workers types. `pnpm -r typecheck`, `test` and `build` cover the package; the Worker tests need workerd, which pnpm installs.
- Deploying needs a Cloudflare login with access to the `aurovie.com` zone (`wrangler login`), and creates the `lens` Worker, the `lens` D1 database and the `lens.aurovie.com` DNS record.
- Names that others see (Lens, the `lens` Worker and database) follow the owner's choice of `lens.aurovie.com`; rename before the first release if needed.
- Not done: no assistant, Companion relay, widgets, reader mode or head gestures yet (later phases); no account recovery beyond adding a second passkey; no email; rate limits are per location; cookies on the glasses' browser are assumed to work like Chromium's and need checking on the device.
