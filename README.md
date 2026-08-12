# RelayForge

Supervise AI coding agents from your phone, your watch, or a browser — and cut
what they cost.

**New here? [QUICKSTART.md](QUICKSTART.md)** — fifteen minutes from nothing to a
supervised agent that buzzes your phone.

The design document is [Relay System Design Claude.md](Relay%20System%20Design%20Claude.md);
this file is the reference for what exists today.

## Layout

| Path | What it is |
|---|---|
| `crates/forge-proto` | The wire contract: types, events, commands, read models. Depends on serde and nothing else |
| `crates/forge-domain` | The rules: pricing, risk classification, the `PLAN.md` state machine, agent capabilities. No I/O, no clock, no async |
| `crates/forge-app` | Use cases and the storage ports they need |
| `crates/forge-sqlite` | Those ports, backed by SQLite in WAL mode |
| `crates/forge-cloud` | The control plane: accounts, organisations, roles, plans, and the machine/device registry. Holds no content — see below |
| `crates/forge-mcp` | RelayForge as a remote MCP server: the protocol, and the OAuth 2.1 server that guards it |
| `crates/forge-crypto` | End-to-end encryption: identities, envelopes, pairing, capability tokens, the runner keystore |
| `crates/forge-gateway` | The cost gateway: the eight-stage pipeline every model call passes through |
| `crates/forge-agent` | **RelayForge's own coding agent**: a tool loop that proposes a diff instead of applying one |
| `crates/forge-runner` | The daemon: SQLite store, cost ledger, budget guard, localhost HTTP API |
| `crates/forge-relay` | Stateless ciphertext fan-out, and WebPush wake-ups it cannot read the content of |
| `packages/client-core` | Everything the clients share: crypto, wire types, both transports |
| `web/` | The PWA: fleet view, session detail, cost dashboard |
| `mobile/` | The React Native phone app (iOS + Android) |
| `mobile/watch/` | The Apple Watch app — native SwiftUI, with its own NaCl implementation |
| `desktop/` | The desktop app (Tauri): the same runner, in a window, on any OS |
| `deploy/` | Cloudflare tunnel, systemd and launchd for `farhelm.aurovie.com` |

### Three clients, one wire format

The clients are separate codebases because they are separate platforms, not
because the logic differs. Everything that is not a screen lives in
`packages/client-core` and is imported by both JavaScript clients unchanged; the
watch reimplements the same wire format in Swift, because watchOS has no React
Native renderer and Apple ships no Salsa20.

That last part is the risky one, so it is the most heavily tested: a fixture in
`crates/forge-crypto/tests/fixtures/interop.json` is sealed by Rust and by
TweetNaCl, and **all three implementations assert against the same bytes**. See
[mobile/watch/README.md](mobile/watch/README.md) for the bug this caught.

## Which agents it drives

`GET /v1/agents` answers this for the machine you are on, and the startup banner
prints it. Today:

| Agent | How approvals reach it |
|---|---|
| **RelayForge** | **Native** — the runner *is* the agent. No bridge, nothing to parse. |
| Claude Code | **Hook bridge** — the agent calls the runner and blocks. Exact. |
| Codex CLI, OpenCode, Aider, Gemini CLI, Cursor CLI | **Terminal prompts** — the runner reads the question out of the pane and types the answer back |
| Shell | Nothing is gated; you are the one typing |

All channels end in the same approval queue: same destructive-command
classifier, same phone-only rule for `rm -rf`, same budget meter, same
notification. Adding an agent is a row in `crates/forge-domain/src/agent.rs`.

## Tasks: the agent that hands you a diff

Everything above supervises *somebody else's* agent. `POST /v1/tasks` is the
runner doing the work itself — and the reason it exists is that a shell command
is the wrong thing to review. A command is `Y/n` in a hurry. A **diff** is the
decision that actually matters, and it is the one thing worth reading on a
phone.

```sh
curl -XPOST localhost:7842/v1/tasks -H 'content-type: application/json' \
  -d '{"repo_path":"/srv/payments-api",
       "prompt":"Bound the webhook retry backoff at 30s and test it",
       "budget_usd": 1.00}'
```

It returns immediately with a row. The loop runs detached, because a task takes
minutes and the phone that started it may be in a tunnel by the time it lands.

```text
  prompt ─▶ loop ──▶ cost gateway ──▶ provider
             │  ▲      (budget, routing, cache, ledger)
             ▼  │
         tools ─┘   read · list · search · edit · write · delete · run
             │
             ▼
   staging overlay ──▶ unified diff ──▶ you ──▶ applied, or discarded
```

**Nothing touches your working tree until you approve it.** Every edit lands in
a staging overlay, which is what makes the diff renderable *before* anything is
committed to. Deny it and there is no partial state to clean up, because nothing
was ever written.

**Only `run` raises a card.** Approving twelve individual edits is a captcha,
not supervision — the edits are reviewed once, together, as a diff. A command is
gated one at a time by the same classifier every other agent goes through, so
`rm -rf build` is still destructive, still phone-only, still 403 from a watch.

**The change set cannot be approved from a watch either.** A diff you have not
read is not a diff you reviewed.

| Endpoint | What it does |
|---|---|
| `POST /v1/tasks` | Start. Returns a row; the loop runs detached |
| `GET /v1/tasks` | Every task, newest first |
| `GET /v1/tasks/{id}` | The review payload: structured diff, patch text, output tail |
| `POST /v1/tasks/{id}/review` | `approve` writes the files; `reject` takes a reason |
| `POST /v1/tasks/{id}/revert` | Takes an applied change set back off disk |

### Applying is not a one-way door

The overlay keeps **both** sides of every file it touched, so undoing is the
same walk with them swapped:

```sh
curl -XPOST localhost:7842/v1/tasks/<id>/revert
```

It refuses if any touched file has moved since — undoing over somebody's later
edit would throw away work that was never the agent's. That is the mirror of the
check on `apply`, and between them they mean the working tree only ever moves
between two states you have seen.

Only an `applied` task offers it. A rejected one never landed, and a reverted
one is already undone; offering "undo" on either would be offering to do
nothing.

### Two limits worth knowing

**Three tasks draft at once.** `start` does not block, so without a ceiling
fifty POSTs — or a stuck retry button on a phone — would be fifty agents on the
frontier of a budget in parallel. The fourth gets a `429`, and a refusal writes
no row. Three is deliberately small: a task is minutes of wall-clock and ends at
a human anyway.

**A change set is capped at 4 MB across all files.** Past that the diff is still
reviewable but the overlay is not stored, so it cannot be applied — the task
says so rather than putting megabytes in a row that the fleet query reads on
every refresh.

A task still marked `running` when the runner stops is settled to `failed` at
the next startup. The loop was a spawned future and did not survive; the row
did, and one that says "working…" forever is worse than one that admits it was
interrupted.

Over the relay a phone can list tasks, fetch one, and review it; **starting** one
is loopback-only, for the same reason starting a session is — pointing an agent
at a directory is a different permission from deciding about work that exists.

### Rejecting is half the loop

A rejection takes a reason, and the reason is the point. `POST /v1/tasks` with
`retry_of` composes the next attempt's instruction from the one it replaces: the
original ask, what that attempt did, **why you refused it**, and the patch you
turned down.

```sh
curl -XPOST localhost:7842/v1/tasks -H 'content-type: application/json' \
  -d '{"repo_path":"/srv/payments-api",
       "prompt":"Bound the webhook retry backoff at 30s and test it",
       "retry_of":"<the rejected task id>"}'
```

An agent told only "no" will usually produce the same change again. The original
row is never touched — a retry sits *beside* a rejection rather than replacing
it, so the audit trail keeps both the change set that was refused and the one
that took its place.

### A second opinion, before yours (C10)

The loop drafts on the large tier. That is where the tokens are: a dozen turns,
each carrying a repo map, a history and a growing pile of tool results — and
most of what they spend is on *looking things up*, which does not need the best
model in the world.

What does need it is the judgement at the end. So **exactly one frontier call
happens per task, and it sees only the diff** — no repo map, no history, no tool
results. Its verdict (`pass` / `concerns` / `fail`) sits above the patch on the
review card, so you know what to look for before you start reading.

```sh
cargo test -p forge-agent --test draft_then_verify -- --nocapture
```

```
verifier input 866 bytes vs final drafting turn 4716 bytes
frontier throughout $0.0650 (10 frontier calls) vs draft-then-verify $0.0325
  (10 large + 1 frontier) over 10 turns — 50.0% reduction
```

That is the same task both times — identical tool calls, identical edit. The
only difference is which model each turn was billed at.

**An unreadable verdict is never a pass.** The grade is parsed from a leading
`VERDICT:` line; a missing one, a malformed one, a refusal, or a failed call all
produce `concerns`. A verification that silently degraded to "looks fine" would
be worse than none at all, because it would put a reassuring line on a card with
nothing behind it. A task that was never judged stores `null` and the clients
render *nothing* — "not judged" and "judged and found fine" must not collapse
into each other.

### What wakes your phone

| Event | Buzzes? |
|---|---|
| An approval request | Yes — an agent is blocked until you answer |
| A budget alert | Yes — money is leaving |
| A task reaching `awaiting_review` | Yes — finished work nobody has read |
| A task starting, applying, failing | No |
| Output, session status, your own decisions | No |

A change set is the strongest case of the three: an approval stalls one tool
call, an unreviewed diff stalls a whole task that is already paid for. But only
when it is *waiting* — buzzing on `running` and again on `applied` would train
you to ignore the buzz that mattered.

**A diff never gets a one-tap action.** Destructive commands are refused from a
notification because a lock-screen tap is less deliberate than a wrist tap; a
diff is refused for a stronger reason still — the entire value of a change set
is that somebody *read* it. Tapping the notification opens the diff.

### Two properties worth knowing about

**Every model call goes through the cost gateway.** The loop is a *caller* of
`Gateway::complete`, not a second path to a provider — so budgets, tiered
routing, retrieval, cache-shaped prompts and the ledger all apply to it without
knowing tasks exist. An agent that could reach the API directly would make every
guarantee in this repo advisory.

**Retrieval and the pre-gate run on the first step only.** Stage 2 shells out to
a formatter, a linter and a test suite; stage 5 walks the repo. Both are worth
doing once and neither is worth doing twelve more times while the agent reads
files. It is also what makes the loop *cache*: the repo map is carried forward
verbatim, so the prompt prefix stays byte-identical and every later step reads
its breakpoints instead of rewriting them.

```sh
cargo test -p forge-agent                        # 79 tests
cargo test -p forge-runner --test agent_task     # the whole path, over real HTTP
```

That last one is the honest one: a stand-in provider answering with the
documented `tool_use` shape, driven through the real router, the real gateway,
the real approval queue, and the real write to disk.

### What has not been proven

**No real model has ever driven this loop.** Every test scripts the provider.
What is exercised is the wire format, the tool semantics, the staging overlay and
the review path; what is not is whether a real model uses these seven tools well,
how many steps a real task takes, or what it costs. Treat the first live task as
the proving run.

**The review screens have not been looked at.** Same gap as every other client
here — this machine has no browser and no simulator. The diff renderer's line
numbering is unit-tested in `client-core` precisely because it is the part that
fails silently; layout and contrast are not.

## Supervising somebody else's agent

**The prompt channel is a heuristic, and says so.** It is pattern matching on
terminal output; agents reword their prompts between releases. The failure
direction is deliberate — an unrecognised prompt means a session that sits
there, never one that proceeds unwatched. Nothing is ever answered
automatically. `/v1/agents` reports `verified: false` for every dialect that has
not been checked against the real binary, which is currently all of them except
the hook path.

## Requirements

- Rust 1.90+ (`rustup` default toolchain is fine — SQLite is vendored, nothing to install)
- Node 20+ and `pnpm`, for the web and phone clients
- Xcode 16+ and Swift 6, only for the watch
- `tmux` is **optional**. With it, agent sessions survive a runner restart and
  you can `tmux attach` and take over by hand — the right choice on a server.
  Without it the runner owns the pseudo-terminals itself (`--terminal pty`),
  which works everywhere including Windows but ties sessions to the process.
  `--terminal auto` is the default and prefers tmux when it is installed.

## Run it

The fastest way to see the whole thing is demo mode: an in-memory database
seeded with a realistic fleet, plus simulated agent output.

```sh
pnpm install
pnpm --filter @relayforge/web build
cargo run -p forge-runner -- serve --demo
# → http://127.0.0.1:7842
```

That serves the API *and* the built web app from one binary.

### Developing the web app

Run the runner and Vite side by side; Vite proxies `/v1` to the runner and gives
you hot reload:

```sh
cargo run -p forge-runner -- serve --demo        # terminal 1
pnpm --filter @relayforge/web dev                # terminal 2 → http://localhost:5173
```

`pnpm dev` binds to `0.0.0.0`, so you can open it on a phone on the same
network. The runner itself stays on loopback.

### The desktop app

```sh
pnpm --filter @relayforge/web build     # the window renders this
cargo run -p relayforge-desktop
```

The same runner, in a window, on macOS / Windows / Linux. It embeds the daemon
rather than talking to one: same library, same API, same approval rules, its own
database and key under a per-user directory (`~/Library/Application Support/RelayForge`,
`%APPDATA%\RelayForge`, or `~/.local/share/relayforge`). Sessions use the PTY
backend, so they end when you quit — the tray menu says so.

The window is a **browser pointed at the embedded server**, not Tauri's asset
protocol. That matters: the app fetches `/v1/fleet` same-origin because it is
written to be served by the runner, and under `tauri://localhost` those requests
never reach the server. Loading `http://127.0.0.1:7842` makes the desktop app the
same deployment the browser already uses — no Tauri-specific client code at all.
If that port is taken (usually by a `forge-runner serve`), it falls back to a
free one rather than refusing to open.

Point it at a relay from Settings and the machine becomes reachable from your
phone. **It is not a remote administration tool**: nothing accepts arbitrary
commands from the network. Everything a phone can ask for goes through the same
gated path the localhost API uses — approvals are *answered*, not issued;
instructions are typed into an agent's own terminal; destructive commands still
cannot be cleared from a wrist. A device must be paired, on your own network,
before it can say anything at all.

### Developing the phone app

```sh
cd mobile && npx expo start                      # Metro, for the dev client
cd mobile && npx expo prebuild && pnpm ios       # or: pnpm android
```

See [mobile/README.md](mobile/README.md). The watch is a separate target inside
the same Xcode project — [mobile/watch/README.md](mobile/watch/README.md).

**`mobile/` is pinned to TypeScript 5, and the rest of the workspace is on 7.**
That looks like an oversight and is not. TypeScript 7 is the native Go port: its
main entry exports `{ version, versionMajorMinor }` and nothing else, with the
classic compiler API moved behind `./unstable/*` in a different shape. `tsc`
still type-checks fine — which is why `web` and `client-core` stay on 7 — but
every tool that consumes the API *programmatically* breaks, and Expo CLI is one:

```
TypeError: Cannot read properties of undefined (reading 'getCurrentDirectory')
    at evaluateTsConfig (@expo/cli/src/utils/tsconfig/evaluateTsConfig.ts:7)
```

That is `resolveFrom(projectRoot, 'typescript')` finding TS 7 and then calling
`ts.sys`, which no longer exists. pnpm resolves per package, so pinning
`typescript` in `mobile/package.json` alone fixes Expo without moving anything
else off 7. Revisit when Expo supports the 7.x API.

`expo start` also rewrites `mobile/tsconfig.json` on first run to add
`extends: expo/tsconfig.base`. Harmless — the explicit `compilerOptions` still
win, and `pnpm -r typecheck` passes either way. `EXPO_NO_TYPESCRIPT_SETUP=1`
stops it if you would rather Expo left the file alone.

**`react-native` and `react` are pinned to what the SDK expects**, not to the
newest release. Expo Go and a prebuilt dev client have a fixed React Native
compiled into them; RN compares the JS and native versions on **major and minor
only** (`Libraries/Core/ReactNativeVersionCheck.js`) and refuses to boot when
they differ:

```
React Native version mismatch.
JavaScript version: 0.82.0
Native version: 0.81.4
```

A patch-level difference is fine — 0.81.5 against a 0.81.4 runtime boots. A
minor is not. `npx expo install --check` prints the versions the installed SDK
wants; keep the two in step and let the SDK bump drive the upgrade.

Metro's `serverRoot` is the **workspace** root here, not `mobile/`, so a bundle
is served from `/mobile/index.bundle`, not `/index.bundle`. The dev client works
that out on its own; a hand-written `curl` does not.

### Against a real database

```sh
cargo run -p forge-runner -- seed --db forge.db   # optional: write the demo fleet
cargo run -p forge-runner -- serve --db forge.db
cargo run -p forge-runner -- status --db forge.db
```

`forge-runner demo` prices a synthetic session and prints the ledger summary
without touching the network or a file.

## Checks

```sh
cargo test --workspace                              # 634 tests
cargo clippy --workspace --all-targets -- -D warnings
cargo fmt --all --check
pnpm -r typecheck && pnpm -r test                   # 161 tests across the three JS packages
pnpm --filter @relayforge/web build
swift test --package-path mobile/watch              # 37 tests; needs macOS, not a watch
```

## Supervising a real agent

Register the hook bridge in the repo you want supervised:

```sh
cargo run -p forge-runner -- install-hooks    # prints the settings block
```

Paste it into that repo's `.claude/settings.json`, then start the daemon. From
then on every tool call Claude Code makes waits for you.

**What happens when things go wrong is the important part:**

| Situation | What the agent gets | Why |
|---|---|---|
| You approve from the phone | `allow` | |
| You deny | `deny`, with your reason | |
| Nobody answers within 15 min | `deny`, recorded as `timeout` | An unanswered request must never become an allow |
| The runner is down | `defer` | Falls back to Claude Code's own prompt — RelayForge being down degrades to plain Claude Code, not to an unsupervised agent |
| The bridge itself errors | `defer` | A bug here must not block your agent |

Destructive commands (`rm -rf`, `git push --force`, `DROP TABLE`, `mkfs`,
`sudo`, `curl | sh`, `terraform destroy`, `kubectl delete`, publishing…) are
classified server-side and **cannot be approved from a watch or a notification
action** — the API returns 403. The classifier is a speed bump on the approval
UX, not a sandbox; see `crates/forge-domain/src/risk.rs`.

The built-in list can't know about your stack. Add your own rules:

```sh
forge-runner policy                              # what is in force
forge-runner policy flyctl apps destroy prod     # how would this be classified?
```

Rules live in `forge.policy.toml` beside the database:

```toml
destructive = ["flyctl apps destroy", "make reset-staging"]
allow = ["sudo"]          # retire a built-in you find routine
```

**Additive, with a deliberately narrow escape hatch.** The built-ins always
apply unless a pattern is *individually* named in `allow` — there is no blanket
off switch, because that's the setting someone flips at 2am debugging and never
puts back. A malformed policy file is a startup error, never a silent fallback:
if you wrote a rule expecting it to be enforced, starting without it is the
worst possible outcome.

Sessions the runner starts itself live in tmux (`forge:N.0`), so they survive a
closed lid. Sessions adopted from a hook callback have no pane the runner
controls — instructions to those are recorded and shown on the phone, and the
response says `delivered: false` rather than pretending.

## Going remote

Two ways, and the second replaced the first as the default.

### Sign in (accounts, several machines, plans)

```sh
cargo run -p forge-cloud                                   # the control plane
cargo run -p forge-relay -- --auth-from http://127.0.0.1:7844
```

Create an account in the web app, then **Workspace → Add a machine → Create
key** and start the runner with it:

```sh
FORGE_CLOUD_KEY=frg_… FORGE_CLOUD_URL=https://farhelm.aurovie.com \
  cargo run -p forge-runner -- serve
```

The machine appears in your fleet within thirty seconds. **There is no code to
type on either side, and no network you have to be on.** A device signed into
that workspace asks the control plane for a fifteen-minute seat on the machine's
channel and learns its public key from that call rather than from a photograph.

What the control plane is *not* is a middlebox. Devices still generate their own
keys, everything still travels sealed between a device and a machine, and it has
never held a key that opens any of it — see
[`crates/forge-cloud/src/lib.rs`](crates/forge-cloud/src/lib.rs). Compromising it
is an access problem, not a content one.

Three things pairing could not do, which fall out of having an identity that is
not a keypair:

| | |
|---|---|
| **Revocation that reaches the runner** | Removing a device stops it decrypting anything new within fifteen minutes. The runner reconciles its device list on every heartbeat, so nothing has to tell it. |
| **More than one machine** | A workspace owns a fleet. Pairing tied one device to one runner's keypair. |
| **More than one person** | Roles, and a plan that says how many. |

Deployment behind a Cloudflare tunnel is in [`deploy/`](deploy/README.md).

### Point at a relay directly (one machine, no account)

Still supported, and still the simplest thing that works:

```sh
cargo run -p forge-relay                                   # on a VPS, or locally
cargo run -p forge-runner -- serve --relay ws://your-relay:7843
```

The runner dials **outbound** and keeps the socket open — it never listens on a
public port. Pair a device:

```sh
cargo run -p forge-runner -- pair      # renders a QR in the terminal
```

The QR carries the relay URL, the channel, the runner's public key, and a
single-use code that expires in ten minutes. Scanning it a second time is
refused (403), so a photographed QR is not a standing invitation.

In the web or phone app, tap **⛓** and paste what `pair` printed alongside the
QR. There is no camera step: reading a QR in-browser needs `BarcodeDetector`,
which iOS Safari does not have, and one paste covers both clients. The app
generates its keypair locally, redeems the code against the runner over your own
network, and from then on talks through the relay — the secret key never leaves
the device. Tap **🔗** to see the pairing or drop it.

Do the pairing while you can still reach the runner directly; the claim call is
the one hop that happens before there is a shared key.

**The watch pairs through the phone**, because claiming a code needs to reach the
runner and a watch usually cannot. It generates its own keypair and sends only
the public half; the phone redeems a code on its behalf and sends back the relay
coordinates. From then on the watch talks to the relay itself, as its own paired
device — which is what makes `decided_via: watch` true and the
destructive-command rule enforceable. See
[mobile/watch/README.md](mobile/watch/README.md).

The runner's own keypair lives in `forge.key`, created `0600` and reused across
restarts — a new key would silently break every paired device. The runner
refuses to start from a group- or world-readable key file rather than carrying
on while its identity is readable by every user on the box.

## The relay, and why it cannot read your code

```sh
cargo run -p forge-relay          # → 0.0.0.0:7843
```

The relay fans encrypted envelopes out to the other members of a channel. It
holds no keys, keeps no messages, and drops a channel the moment its last member
leaves — so there is no history to subpoena, leak in a backup, or migrate.

Both directions use **authenticated** boxes (X25519 + XSalsa20-Poly1305), not
the sealed boxes §6 originally specified. A sealed box is anonymous, and the
runner's public key travels in a pairing QR: anyone who photographed that QR
could seal a valid-looking `approved` to the runner with no sender to check.
Authenticated boxes give identical confidentiality plus a sender to verify. The
reasoning is in `crates/forge-crypto/src/lib.rs`.

The security claim is a test, not a promise:

```sh
cargo test -p forge-relay --test end_to_end
```

It drives a real WebSocket through the real router and asserts that an approval
for `git push --force origin main` round-trips correctly while nothing the relay
handled contains any of those words — plus that a relay operator who forges an
`approved` is rejected, that a connection cannot cross-post into a channel it
did not join, and that the relay retains nothing once everyone disconnects.

The runner side has its own:

```sh
cargo test -p forge-runner --test remote_approval
```

A simulated phone with its own keypair approves through a real relay and the
runner records it with `decided_via: phone` — never touching the HTTP API. It
also asserts that a **watch cannot clear a destructive command over the relay
either**: the D3 guard lives in one shared command layer, so a new transport
cannot ship without it.

And the clients' half of the same wire format:

```sh
pnpm -r test                            # JavaScript
swift test --package-path mobile/watch  # Swift
```

`packages/client-core/src/crypto.test.ts` opens an envelope that `forge-crypto`
sealed, and Rust opens one that code sealed. The Swift suite opens **both**. The
fixture is checked in and all three implementations assert against it, so a drift
between RustCrypto's `crypto_box`, TweetNaCl, and the hand-written Swift fails in
CI rather than as "my watch can't approve anything".

`transport.test.ts` covers the correlation problem the relay creates: it is a
fan-out channel with no request/response, so a reply is matched to a waiting call
by its shape, and a refusal has to travel back or the tap silently does nothing.

There is also a live check that runs against a real runner and a real relay and
**skips itself** when neither is up. Its header says how to start them:

```sh
cargo run -p forge-relay &
cargo run -p forge-runner -- serve --demo --relay ws://127.0.0.1:7843 &
pnpm --filter @relayforge/client-core test
```

## Getting woken

Without this, RelayForge only works while you are already looking at it. Start
the relay with a VAPID key:

```sh
cargo run -p forge-relay -- --vapid-key vapid.key --push-subject mailto:you@example.com
```

The key file is created `0600` on first start and reused. **Do not delete it** —
every subscription a browser made is bound to the public half it saw, so a new
key silently stops waking every device that ever subscribed.

Then in the app: pair, and turn on notifications from the pairing card.

**The push carries nothing, and the notification still names the command.**
Those are not in tension. The relay cannot read the envelope that triggered the
wake-up, so it sends an encrypted but *contentless* push. The service worker then
opens the pairing from IndexedDB, connects to the relay itself, and decrypts a
fleet snapshot — on the device, with the device's own key. So the notification
reads `payments-api · pytest tests/billing -x` while the relay still knows
nothing. Putting that text in the payload would mean decrypting it on the relay,
which is the one property the whole design promises not to break.

**Approve and Deny are buttons on the notification** — one tap, no app launch.
Except for destructive commands, which get no buttons at all. A notification
action can be hit from a lock screen without the app ever coming to the front; it
is the least deliberate surface in the system, less so than the wrist tap D3
already refuses. The runner enforces its own rule server-side regardless — this
is the client declining to offer a button it should not.

**Only approvals and budget alerts wake you.** That decision lives in the runner,
not the relay — the relay sees ciphertext and cannot tell an approval from a line
of build output, so a relay that pushed on every publish would buzz your phone
for as long as an agent kept printing. On top of that the relay collapses a burst
to one wake-up per channel per ten seconds.

**On iOS the app must be installed to the Home Screen.** Safari resolves
`Notification.requestPermission()` to `"denied"` in a browser tab without ever
prompting — no dialog, no error. The app detects this and says so rather than
letting you hit it.

The crypto is checked against RFC 8291's own worked example — fixed keys, fixed
salt, fixed expected ciphertext:

```sh
cargo test -p forge-relay
```

## The cost gateway

`POST /v1/complete` is the only path to a model provider, which is what makes
cost policy enforceable rather than advisory. Eight stages:

| # | Stage | Saves by |
|---|---|---|
| 1 | Budget | refusing to spend past a session *or* repo cap (402) |
| 2 | Pre-gate | letting a formatter/linter/type-checker/test suite answer instead of a model — a green verify costs $0 |
| 4 | Router | triage on Haiku, edits on Sonnet, planning on Opus; `PLAN.md` can pin a step down a tier |
| 5 | Context | line ranges and declaration skeletons under byte caps, not whole files |
| 6 | Assembler | a byte-stable prompt prefix with `cache_control` breakpoints at each stable/volatile border |
| 5a | Compaction | summarising old conversation turns so a long session stops re-sending them (C7) |
| 3 | Response cache | not asking the same question twice |
| 7a | Batch queue | work marked `deferrable` is queued instead of dispatched, and billed at **half rates** (C6) |
| 7 | Dispatch | raw Messages API over HTTP |
| 8 | Ledger | priced once, at write time |

Stage 3 runs after 4–6 because an exact-prompt cache key needs the routed model
and the retrieved context to exist first. Both zero-cost exits still precede any
spend.

### Compacting history (C7)

A long session re-sends its whole history every turn. Once it passes a
threshold, the gateway summarises the oldest turns on the small tier and hands
the caller back a compacted history to store from then on. The summary call is
billed like any other, so a turn that compacted reports what it really cost.

Measured over 40 turns, from the ledger: **$1.53 → $0.89, 42% saved.**

```sh
cargo test -p forge-gateway --test compaction_savings -- --nocapture
```

**That benchmark corrected the design.** The original reasoning was that
compaction is expensive because it invalidates the prompt cache, so the policy
should be rare and large. Wrong: history sits *after* the stable breakpoints, so
only the history segment is invalidated — everything ahead of it still reads at
0.1×. Compacting harder is in fact **84% cheaper still**.

The defaults deliberately don't do that. The real cost of frequent compaction is
**fidelity**, not money: every pass re-summarises text that already went through
a summary, so detail decays geometrically and the agent stops knowing what it
already tried. That gap is asserted in the benchmark rather than hidden, and if
it ever closes the trade-off needs revisiting.

### Deferring work to the Batch API (C6)

A call marked `deferrable` is queued rather than sent. The runner flushes the
queue every minute, collects results every five, and bills them at half rates —
which stacks with prompt caching. `GET /v1/batch` shows what is waiting.

**A queued call returns an id, not an answer.** Most batches finish within an
hour and the ceiling is twenty-four, so nothing that blocks a human belongs
here. The response says `served: "queued"` with empty text and zero cost;
nothing is billed until the real token counts come back.

The queue is built around one rule: **being billed twice cannot be undone.**
Submitting moves a whole batch in one transaction, settling only acts on an item
still in flight, and `custom_id` is unique — each with a test named after the
failure it prevents. Wire shapes are exercised over real HTTP against a stand-in
provider (`cargo test -p forge-gateway --test batch_http`), but **no request has
been sent to the real endpoint**, so treat the first real flush as the proving
run.

Configure the provider with `ANTHROPIC_API_KEY`. Without it the runner still
starts and serves everything else; `/v1/complete` returns 503 with a clear
message. `ANTHROPIC_BASE_URL` redirects to any compatible endpoint — a local
vLLM/Ollama shim for the self-hosted small tier, or a test server.

| Variable | Effect |
|---|---|
| `ANTHROPIC_API_KEY` | Enables `/v1/complete` — a Console key, sent as `x-api-key`. Blank counts as unset. |
| `ANTHROPIC_AUTH_TOKEN` | Same, with a short-lived bearer token instead. Used only when `ANTHROPIC_API_KEY` is unset, and carries the `oauth-2025-04-20` beta the API requires for one. |
| `ANTHROPIC_BASE_URL` | Redirect to a compatible endpoint |
| `FORGE_RUNNER_URL` | Where `forge-runner hook` reaches the daemon (default `127.0.0.1:7842`) |
| `FORGE_MACHINE_NAME` | Overrides the hostname used to identify this machine |
| `FORGE_TMUX` | Path to the tmux binary |

The runner's own flags: `--relay <ws-url>` to go remote, `--key <path>` for the
identity file (default `forge.key`).

### The savings, measured

```sh
cargo test -p forge-gateway --test savings -- --nocapture
```

Replays 50 turns through the real pipeline and asserts the two numbers the
design document commits to. Current output:

```
cache-read ratio 99.7%  (169240 read / 583 fresh input)
gateway $0.1111 vs baseline $1.1885 over 50 turns — 90.7% reduction (42 live calls, 8 cache hits)
```

The gateway figure comes out of the append-only ledger; the baseline is the same
prompts priced unwrapped — frontier model, no cache, no routing. **The provider's
prefix caching is simulated** by a stub that models per-breakpoint hits, so this
measures the assembler doing its job, not production traffic.

## Where the money is counted

Every model call goes through `forge_core::ledger`, which prices it against
`forge_core::price::PRICES` **at write time** and adds the cost to the session's
spend in the same transaction. `usage_event` is append-only: editing the price
table changes what future calls cost, never what past calls cost.

Rates are dollars per million tokens as of 2026-07-30. Cache and batch rates are
derived from the base input rate rather than typed per model — one fewer place
for a transcription error. Sonnet 5's introductory pricing is encoded with its
expiry, so a ledger row written during the promo keeps that rate afterwards.

A call priced against a model that a server-side fallback replaced is billed at
the model that *ran*, not the one requested.

## Status

| Milestone | State |
|---|---|
| M0 — Foundations (schema, price table, ledger) | done |
| M1 — Runner controls an agent | done — hook bridge, session manager, plan executor, and **six agents** across two approval channels. **The tmux calls themselves are unverified** (see below); the PTY backend is verified against real processes |
| M2 — Cost Gateway `/v1/complete` | done — stages 1–8, exit criteria asserted in CI, plus **batch deferral (C6)** and **history compaction (C7)** |
| M3 — Relay + phone | done — web app, React Native app, localhost API, relay, E2E crypto, relay link, device pairing, both clients' own crypto, and **WebPush delivery** (VAPID + `aes128gcm`, verified against RFC 8291's worked example). Every read-only screen, the cost dashboard included, now works over the relay |
| M4 — Watch + budget UX | done in software — budget guard, destructive-command gating, stale-session GC, push wake-ups, and **one-tap Approve/Deny on the notification** (never for destructive commands). A **native watchOS app** is built, with its own paired identity and Swift NaCl implementation — scope the design doc deferred to P2, promoted on request. **The <5s golden path has never been timed**, and nothing has run on a watch (see below) |
| M5 — Dashboard + hardening | cost dashboard, **batch queue (C6)**, **history compaction (C7)**, **destructive-command policy file**, and the **quickstart + systemd units** done. **Desktop app** (Tauri, any OS) built — scope not in the original plan, added on request. Opt-in beta telemetry outstanding |
| M6 — Native agent + diff review | done in software — `forge-agent`, the staging overlay, the seven tools, unified diffs computed in-repo, `agent_task` table, five endpoints, four relay commands, reject-and-retry, **undo**, a concurrency ceiling, restart reconciliation, push wake-ups for waiting diffs, **draft-then-verify (C10)**, and review screens on web and phone. **No real model has driven the loop, and no screen has been rendered** (see below) |

### Known gap: tmux is unexercised

`crates/forge-runner/src/terminal.rs` was written on a machine with no tmux
installed. Its argv construction is tested exhaustively — that is where
shell-out bugs live — and the session manager is tested against an in-memory
fake. But **no line of it has run against a real tmux**. Treat the first
`forge-runner serve --terminal tmux` on a box with tmux as the real test.

This matters less than it did: the PTY backend (`--terminal pty`) *is* verified
against real processes — spawning, capturing, typing, dead-process detection —
and it is what the desktop app uses. tmux remains the default where installed
because sessions surviving a restart is worth more on a server.

### Known gap: no window has been looked at

The desktop app's *server* is verified — it was launched, and a full supervised
session was driven through it end to end: agent started, prompt read off a PTY,
approval raised and classified destructive, approved, agent proceeded, data
written to the right per-user directory. What has not been seen is the **window**.
This machine has no way to screenshot one, so layout, the tray menu, and window
behaviour on close are unverified by eye.

### Known gap: the prompt dialects are unverified

Every agent except Claude Code is supervised by reading its terminal, and none
of those dialects has been checked against the real binary — none of them is
installed here. They are written from documentation and released prompt text.

The end-to-end path *is* verified, against a stand-in agent driven through a
real PTY: prompt raised as an approval, classified destructive, refused from a
watch, approved from the phone, `y` typed into the agent's terminal, agent
proceeds, no duplicate approval. What is unproven is whether the real Aider says
exactly `Run shell command? (Y)es/(N)o`.

`/v1/agents` reports `verified: false` for all of them, and the failure mode is
a session that appears stalled rather than one that proceeds unwatched.

### Known gap: no client has been looked at

All three clients' logic is tested — 161 JavaScript tests and 37 Swift ones,
including the cross-language crypto — and everything typechecks and builds. But
this machine has no browser, no simulator, and no watch, so **no screen of any of
them has been rendered**. Layout, contrast in both themes, tap targets, and the
chart geometry are unverified by eye. The palette was checked with the validator
rather than by looking, which catches colour but not collisions.

The diff review screens are the newest and therefore the least seen. Their line
numbering is unit-tested in `client-core` rather than in a component, because
that is the part that fails *silently* — a diff with wrong line numbers looks
exactly like a diff with right ones. Everything about how it looks (the
horizontal scroll on long code lines, the tint on added and removed rows, the
collapsed-file behaviour on a five-file change set) is unverified by eye.

The watch is the least verified: the watchOS *SDK* is installed here but the
watchOS *platform* is not, so it could only be compiled for macOS. The
`WatchConnectivity` code is behind `#if canImport` and was therefore never
compiled at all.

### What a paired device can and cannot do

Everything a screen *reads* now travels over the relay. Five snapshot types do
it: the fleet, one session, one session's **cost dashboard**, the task list, and
a task's diff.

What stays loopback-only is *starting* things — a session, or an agent task.
Both point a process at a directory on somebody's machine, which is a different
permission from deciding about work that already exists. `Transport` exposes
that as `supportsSessionControl` / `supportsTaskControl`, and the screens hide
those buttons rather than offering one that always refuses.

The dashboard was the last read-only screen behind that line. It needed a third
snapshot type and now has one — `Command::DashboardSnapshot`, honouring the same
`since_ms` window as `GET /v1/sessions/{id}/dashboard`, and assembled by the
same `build_dashboard` so a phone and a browser render identical bytes.

### Known gap: no real model has driven the agent loop

`forge-agent` is exercised end to end — through the real router, the real cost
gateway, a real Messages-API client speaking to a stand-in provider, the real
approval queue, and a real write to disk. Every one of those halves is honest
except the model's: the provider is a script.

So what is proven is the *mechanism*: that a `tool_use` block becomes a staged
edit, that a staged edit becomes a diff, that a diff becomes a file on disk only
after somebody says yes, and that a denial leaves nothing behind. What is not
proven is the *behaviour*: whether a real model uses seven tools well, how many
steps a real task takes, and what one actually costs.

The failure direction is at least the safe one. A model that loops runs into the
step cap and hands back whatever it staged; a model that stages nonsense
produces a diff you reject in one tap; a model that asks to run something
destructive gets the same 403 from a watch that every other agent gets. Treat
the first live task as the proving run, and start it with `budget_usd` set.
