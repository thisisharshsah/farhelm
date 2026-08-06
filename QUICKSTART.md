# Fifteen minutes to a supervised agent

From nothing to an agent on your own box that waits for you before it does
anything, and buzzes your phone when it needs an answer.

Three stages, each useful on its own. Stop after any of them.

1. [Supervise an agent locally](#1-supervise-an-agent-locally) — 5 minutes
2. [Reach it from your phone](#2-reach-it-from-your-phone) — 5 minutes
3. [Keep it running](#3-keep-it-running) — 5 minutes

> If you just want to look at it first, `cargo run -p forge-runner -- serve --demo`
> and open <http://127.0.0.1:7842>. In-memory database, a seeded fleet, nothing
> written to disk. Come back here when you want it real.

---

## Before you start

- **Rust 1.90+.** `rustup` default is fine — SQLite is vendored.
- **Node 20+ and pnpm**, to build the web app.
- **An agent.** Claude Code gets the best integration (its hook system blocks
  until you answer). Codex, OpenCode, Aider, Gemini CLI and Cursor work through
  their terminal prompts — see [the caveat](#which-agents-actually-work).
- **tmux is optional.** With it, sessions survive a runner restart. Without it,
  the runner owns the terminals itself and they end when it does.

```sh
git clone <this repo> relayforge && cd relayforge
cargo build --release -p forge-runner -p forge-relay
pnpm install && pnpm --filter @relayforge/web build
```

Everything below assumes `target/release` is on your `PATH`, or that you type the
full path.

---

## 1. Supervise an agent locally

Pick a directory to keep state in. Everything lives together, so "where is my
data" and "how do I start over" have one answer.

```sh
mkdir -p ~/.relayforge && cd ~/.relayforge
forge-runner serve
```

The banner tells you what it found:

```
forge-runner listening on http://127.0.0.1:7842
  database   forge.db
  gateway    none (set ANTHROPIC_API_KEY to enable /v1/complete)
  terminal   tmux · sessions survive a runner restart
  agents     Claude Code  ·  not installed: Codex CLI, Aider, Gemini CLI, Cursor CLI
  policy     built-in rules only (`forge-runner policy` to add your own)
  identity   Ff3k…  (forge.key)
```

Open <http://127.0.0.1:7842>. Empty, because nothing is running yet.

### Put the agent under supervision

In **another terminal**, in the repository you want worked on:

```sh
forge-runner install-hooks        # prints a settings block
```

Paste it into that repo's `.claude/settings.json`. From now on, every tool call
Claude Code makes in that repo waits for you.

Start the agent as you normally would and ask it to do something. The moment it
wants to run a command, the browser tab shows an approval card and the agent
blocks until you answer.

**Try denying one.** The agent gets your refusal as a reason, not a crash.

### What happens when things go wrong

This is the part worth knowing before you rely on it:

| Situation | The agent gets | Why |
|---|---|---|
| You approve | `allow` | |
| You deny | `deny`, with your reason | |
| Nobody answers in 15 min | `deny`, recorded as `timeout` | An unanswered request must never become an allow |
| The runner is down | `defer` | Falls back to Claude Code's own prompt — RelayForge being down degrades to plain Claude Code, not to an unsupervised agent |
| The bridge itself errors | `defer` | A bug here must not block your work |

### Add rules for your own stack

The built-in destructive list is broad — `rm -rf`, force pushes, `DROP TABLE`,
`mkfs`, `sudo`, `curl | sh`, `terraform destroy`, `kubectl delete` — but it
cannot know that `make reset-staging` drops your staging database.

```sh
forge-runner policy                                # what is in force
forge-runner policy make reset-staging             # how would this be classified?
```

Write `~/.relayforge/forge.policy.toml`:

```toml
destructive = ["make reset-staging", "flyctl apps destroy"]
```

Anything destructive can only be cleared **from a phone** — never a watch, never
a notification button. Check your rule fires before you rely on it; `policy
<command>` exists so you don't have to find out by asking an agent to run
something drastic.

### Turn on the cost gateway (optional)

```sh
echo 'ANTHROPIC_API_KEY=sk-…' > forge.env && chmod 600 forge.env
set -a && . ./forge.env && set +a
forge-runner serve
```

`POST /v1/complete` is now the only path to a model provider, which is what makes
cost policy enforceable rather than advisory. The cost screen in the app shows
where the money went.

---

## 2. Reach it from your phone

The runner never listens on a public port. It dials **out** to a relay, and the
relay forwards ciphertext it cannot read.

### Put a relay somewhere reachable

Any VPS. It holds no keys and keeps nothing across a restart, so it is the
cheapest box you own.

```sh
forge-relay --vapid-key vapid.key --push-subject mailto:you@example.com
```

Put it behind TLS — a reverse proxy is fine — so devices reach it at
`wss://relay.example.com`. Without TLS, iOS will refuse to connect.

> **Do not delete `vapid.key`.** Every push subscription a browser makes is bound
> to the public half it saw. A new key silently stops waking every device that
> ever subscribed.

### Point the runner at it

```sh
forge-runner serve --relay wss://relay.example.com
```

### Pair your phone

```sh
forge-runner pair          # QR, plus the same payload as text
```

On the phone, open the app **on your own network** (the runner's LAN address),
tap **⛓**, and paste the payload. Confirm the runner address is reachable *right
now* — that claim is the one hop that happens before there is a shared key.

Then tap **Turn on notifications** in the pairing card.

**On iOS you must add the app to your Home Screen first.** Safari resolves the
permission prompt to "denied" in a browser tab without ever showing it. The app
detects this and says so, but it is the single most common reason push appears
broken.

Now walk out of the building. The next approval buzzes your pocket, and the
notification names the actual command — decrypted on your phone, not by the
relay.

---

## 3. Keep it running

```sh
cd ~/.relayforge
forge-runner install-service --relay wss://relay.example.com
```

That prints a systemd unit with **this machine's paths already in it** — binary,
user, working directory. Save it, then:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now relayforge
journalctl -u relayforge -f
```

The unit reads your API key from `forge.env` rather than inlining it, because a
key written into a unit file ends up in `systemctl cat`, in journald, and in your
shell history.

For the relay box, the same command on that machine gives you its unit.

### macOS

Use [the desktop app](desktop/) instead — same runner, in a window, with a tray
icon. It keeps its own database under `~/Library/Application Support/RelayForge`.

---

## Which agents actually work

`forge-runner policy` tells you about rules; `GET /v1/agents` tells you about
agents, and so does the startup banner.

| Agent | How approvals reach it | Confidence |
|---|---|---|
| Claude Code | Hook bridge — the agent calls the runner and **blocks** | Verified end to end |
| Codex, OpenCode, Aider, Gemini, Cursor | The runner reads the question out of the terminal and types the answer | **Unverified** |

The terminal path is pattern matching on output. It is tuned so that an
unrecognised prompt means a session that **sits there**, never one that proceeds
unwatched — but the patterns for those five agents were written from
documentation and have not been checked against the real binaries.
`/v1/agents` reports `verified: false` for all of them.

If a prompt is missed, the fix is a one-line dialect in
`crates/forge-domain/src/agent.rs`.

---

## When something is wrong

**The app says "cannot reach the runner".** It is served by the runner itself, so
this means the daemon is down or on another port. `curl 127.0.0.1:7842/v1/health`.

**An agent starts and immediately dies.** Usually the binary is not installed —
the banner's `agents` line says which ones it found. Starting a session for a
missing agent returns a 503 that names it.

**Approvals never appear.** For Claude Code, the hook block is not in that repo's
`.claude/settings.json`. For the others, the prompt was not recognised — see
above.

**Push never arrives.** In order of likelihood: the app is not installed to the
Home Screen (iOS), the relay was started without `--vapid-key`, or the relay is
not behind TLS. The pairing card reports the first two.

**A paired device stopped working after a restart.** `forge.key` was deleted or
regenerated. Every device is paired against its public half; there is no recovery
but re-pairing.

---

## What is not proven

Stated plainly, because a quickstart that oversells is worse than one that
doesn't exist:

- **No prompt dialect has been checked against a real agent binary.** Claude Code's
  hook path is verified end to end; the other five are not.
- **The wrist path has never been timed on real hardware.** Every piece is tested
  and the whole chain exists, but nobody has actually been woken by this and
  tapped Approve.
- **No request has hit a real Anthropic endpoint** from the batch queue. Its wire
  shapes are exercised against a stand-in that speaks the documented protocol.
- **tmux is unexercised.** Its argv construction is tested exhaustively but has
  never run against a real tmux. The PTY backend (`--terminal pty`) has.

The [README](README.md) keeps the full list.
