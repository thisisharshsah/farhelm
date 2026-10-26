# Account sign-in and local use

The runner serves execution APIs, while `farhelm cloud` serves account sign-in,
workspaces and device enrollment. A local runner or development server is not
an account server. A hosted control plane can serve both the app and its own API
on one origin.

The sign-in screen shows the selected **Workspace server**. Locally served apps
default to `http://127.0.0.1:7844`, the documented local control-plane port.
Hosted apps default to their own origin. `VITE_CLOUD_URL` sets a build-time
default; a successful explicit server choice is remembered in this browser.
Existing signed-in sessions retain their original server address.

Use the address of the deployment where the account was created. Accounts are
not copied between local and hosted databases. On another computer or phone,
`127.0.0.1` refers to that device; select the intended HTTPS workspace server.
Remote addresses must use HTTPS. HTTP is accepted only for loopback services.
Addresses containing credentials, query parameters or fragments are rejected
before credentials are submitted. There is no automatic server fallback, and
account requests refuse redirects.

For local account development, start a control plane separately with explicit
database and signing-key paths:

```sh
cargo run --locked -p farhelm-runner -- cloud \
  --port 7844 \
  --db /absolute/path/to/farhelm-cloud.db \
  --key /absolute/path/to/farhelm-cloud.key
```

Use the existing deployment's paths when restarting it. Starting with a new
database creates a separate account service; replacing its signing key
invalidates existing sessions. Keep keys and databases outside Git. To use just
the local runner, choose **Use this machine only**; no account is required.

## Diagnosing failures

| Symptom | Meaning and next check |
| --- | --- |
| 401 with an email/password mismatch | The account service received the request and rejected the credentials. Confirm the account belongs to the selected deployment. |
| 502 / 503 / 504 | The proxy or service is unavailable. Check the account service and the proxy's upstream destination. This is not evidence of an incorrect password. |
| Missing sign-in API or HTML response | The address may point at the runner or a static app host. Select the account server. |
| Connection failure / timeout | Check the address, service availability, TLS and connectivity. The client bounds each exchange to 20 seconds, including reading its body. |

`GET /v1/health` checks process availability without sending credentials. The
current control-plane response includes `schema` and `relay`; a runner's simple
`{"ok":true}` health response alone does not establish account API availability.
Health is diagnostic and does not authorize sign-in or execution.

The client keeps a refresh session during transient upstream outages and clears
it when the refresh endpoint rejects it with 401/403. Account mutations are not
automatically retried after gateway or network failures. After an uncertain
account-creation result, try signing in before creating the account again.

Ordinary client tests use deterministic fixtures. The relay integration suite
is opt-in because it pairs devices and can decide approvals on its target:

```sh
# Only with a disposable runner/relay on the documented test ports:
FARHELM_LIVE_TESTS=1 pnpm --filter @farhelm/client-core test
```

Tests for gateway failures, malformed responses, deadlines and refresh recovery
live in `packages/client-core/src/cloud.test.ts`; rendered auth tests live in
`web/src/components/Auth.test.ts`. Browser checks use isolated synthetic accounts
and a separate temporary database and signing key.

## Sessions, refresh tokens and devices

**Refresh tokens rotate on every use, with a 30-second grace window.** Strict
single use signed people out whenever a refresh committed on the server but
its reply never arrived (a dropped tunnel connection), or a second tab
refreshed with the token the first had just replaced. Now:

- The token a session held just before its last rotation is accepted for
  `REFRESH_REUSE_GRACE_MS` (30 s) after that rotation, on the same session row
  only, and rotated again. Retries do not extend the window.
- The same previous token presented after the window is treated as reuse by a
  second holder: the whole session is revoked and the person signs in again.
- The web client reads the stored token before every refresh, so another tab's
  rotation is picked up instead of replayed. It ignores a stored token it has
  itself retired, because persisting a rotation is asynchronous. After a
  network failure or a 5xx it retries once, two seconds later, inside the
  window.

Do not return to strict single use without solving the lost-reply case
another way. Do not lengthen the window to minutes: it is the period in which
a copied token still works.

**A device is a key in one browser's storage, at one address.** The same
computer in two browsers, or at `localhost` and at `farhelm.aurovie.com`, is
two devices and needs two seats. When registration is refused for the plan's
device limit, the app lists the devices holding the seats and offers "Use this
browser instead", which removes that device and registers this browser.
Re-registering an existing key is idempotent and never consumes a seat.
