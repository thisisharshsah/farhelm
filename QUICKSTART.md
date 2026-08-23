# Getting started

From nothing to an agent on your own machine that waits for you before it does
anything, and buzzes your phone when it needs an answer.

This used to be fifteen minutes of building two binaries, making a directory,
picking between two routes, exporting a credential and pasting a settings block.
It is two commands now, because every one of those steps was something the
program already knew how to do.

```sh
curl -fsSL https://farhelm.aurovie.com/install.sh | bash
farhelm setup
```

The first installs Farhelm and asks to join your workspace — you approve it in
the app, and the machine appears in your fleet. The second walks everything
still undone, one question at a time, explaining what each one costs to skip.

> **Just want to look first?** `farhelm serve --demo` and open
> <http://127.0.0.1:7842>. In-memory database, a seeded fleet, nothing written
> to disk.

---

## What `setup` actually does

Nothing it does is hidden, and every step has a command of its own if you would
rather type it. Running `farhelm` on its own shows the same list at any time,
with whatever is still outstanding:

```
  farhelm 0.1.0 — supervise your coding agents from anywhere

  ✓ model        a credential is stored
  ✗ supervision  not installed — an agent's tool calls reach nothing
  ✓ fleet        enrolled
  ✗ at login     no — supervision stops at the next reboot

  2 things left. farhelm setup walks them, or do this one:
    farhelm install-hooks --global
```

| Step | Command | Skipping it means |
|---|---|---|
| A model credential | `farhelm auth` | Agent tasks cannot run at all |
| Supervision | `farhelm install-hooks --global` | An agent's tool calls reach nothing |
| Your fleet | `farhelm login --cloud <url>` | Reachable from this browser and nowhere else |
| Run at login | `farhelm install-service` | Supervision stops at the next reboot |

`setup` is safe to re-run: it does what is missing and skips what is not. Under
a pipe or a service manager — anywhere there is nobody to ask — it prints the
commands it would have run rather than guessing on your behalf.

### Building it yourself

```sh
git clone https://github.com/thisisharshsah/farhelm && cd farhelm
cargo build --release -p farhelm-runner    # the binary is called `farhelm`
pnpm install && pnpm --filter @farhelm/web build
```

You need **Rust 1.90+** (SQLite is vendored) and **Node 20+ with pnpm** for the
web app. `tmux` is optional: with it, sessions survive a restart of the daemon;
without it the daemon owns the terminals and they end when it does.

---

## Supervising an agent

Once hooks are installed, start your agent as you normally would and ask it to
do something. The moment it wants to run a command, the app shows an approval
card and the agent blocks until you answer.

**Try denying one.** The agent gets your refusal as a reason, not a crash.

### What happens when things go wrong

This is the part worth knowing before you rely on it:

| Situation | The agent gets | Why |
|---|---|---|
| You approve | `allow` | |
| You deny | `deny`, with your reason | |
| Nobody answers in 15 min | `deny`, recorded as `timeout` | An unanswered request must never become an allow |
| The daemon is down | `defer` | Falls back to Claude Code's own prompt — Farhelm being down degrades to plain Claude Code, not to an unsupervised agent |
| The bridge itself errors | `defer` | A bug here must not block your work |

### Rules for your own stack

The built-in destructive list is broad — `rm -rf`, force pushes, `DROP TABLE`,
`mkfs`, `sudo`, `curl | sh`, `terraform destroy`, `kubectl delete` — but it
cannot know that `make reset-staging` drops your staging database.

```sh
farhelm policy                                # what is in force
farhelm policy make reset-staging             # how would this be classified?
```

Write `~/.farhelm/farhelm.policy.toml`:

```toml
destructive = ["make reset-staging", "flyctl apps destroy"]
```

Anything destructive can only be cleared **from a phone** — never a watch, never
a notification button. Check your rule fires before you rely on it; `policy
<command>` exists so you don't have to find out by asking an agent to run
something drastic.

---

## Reaching it from your phone

The daemon never listens on a public port. It dials **out** to a relay, and the
relay forwards ciphertext it cannot read.

`farhelm login --cloud <url>` — which `setup` runs for you — is the whole of it.
It prints a short code, waits while you approve it in the app, and stores what
it is given. Nothing is copied by hand, and it works over SSH on a box whose
browser belongs to somebody else.

Enrolling does not weaken the encryption. Devices still generate their own keys
and everything still travels sealed between a device and your machine; what the
control plane provides is a directory and a permission, not a way in.

> **Running your own?** `farhelm cloud` is the control plane and `farhelm relay`
> is the fan-out — both subcommands of the same binary. See
> [deploy/README.md](deploy/README.md).

### Without an account at all

One machine, one phone, no control plane: run a relay, point the daemon at it
with `--relay`, and pair the phone from a QR code with `farhelm pair`. It is
more to hold, which is why it is not the default, but nothing about it is
second-class — the encryption is identical.

---

## Keeping it running

```sh
farhelm install-service
```

Writes the definition your machine's own service manager understands — a launchd
agent on macOS, a systemd unit on Linux — with this machine's paths filled in,
and prints the one line that loads it. It writes the file but does not start it:
starting a background service that executes agents is worth typing yourself.

---

## Which agents actually work

`farhelm policy` tells you about rules; `GET /v1/agents` tells you about agents,
and so does the startup banner.

| Agent | How approvals reach it | Confidence |
|---|---|---|
| Farhelm's own agent | Native — the daemon *is* the agent, and hands you a diff | Verified end to end |
| Claude Code | Hook bridge — the agent calls the daemon and **blocks** | Verified end to end |
| Codex, OpenCode, Aider, Gemini, Cursor | The daemon reads the question out of the terminal and types the answer | **Unverified** |

The terminal path is pattern matching on output. It is tuned so that an
unrecognised prompt means a session that **sits there**, never one that proceeds
unwatched — but the patterns for those five agents were written from
documentation and have not been checked against the real binaries.
`/v1/agents` reports `verified: false` for all of them.

If a prompt is missed, the fix is a one-line dialect in
`crates/farhelm-domain/src/agent.rs`.

---

## When something is wrong

**Start here:**

```sh
farhelm doctor
```

It checks the whole setup and names the command that fixes each problem it
finds, in the order they block you. `farhelm` on its own answers the different
question of what was never set up in the first place.

Past that, in rough order of likelihood:

**The app says "cannot reach the daemon".** It is served by the daemon itself,
so this means it is down or on another port. `curl 127.0.0.1:7842/v1/health`.

**An agent starts and immediately dies.** Usually the binary is not installed —
the banner's `agents` line says which ones it found. Starting a session for a
missing agent returns a 503 that names it.

**Approvals never appear.** For Claude Code, the hook block is not in that
repo's `.claude/settings.json` — `farhelm install-hooks --global` covers every
repo at once. For the others, the prompt was not recognised; see above.

**Push never arrives.** In order of likelihood: the app is not installed to the
Home Screen (iOS), the relay was started without `--vapid-key`, or the relay is
not behind TLS. The pairing card reports the first two.

**A paired device stopped working after a restart.** `farhelm.key` was deleted
or regenerated. Every device is paired against its public half; there is no
recovery but re-pairing.

**Something says `forge` rather than `farhelm`.** That is the old name, and it
still works — files, environment variables and settings under either spelling
are read, and the one being used says so once. `deploy/migrate-to-farhelm.sh`
moves a deployment across when you want it tidy.

---

## What is not proven

Stated plainly, because a quickstart that oversells is worse than one that
doesn't exist:

- **No prompt dialect has been checked against a real agent binary.** Claude
  Code's hook path is verified end to end; the other five are not.
- **The wrist path has never been timed on real hardware.** Every piece is
  tested and the whole chain exists, but nobody has actually been woken by this
  and tapped Approve.
- **No request has hit a real Anthropic endpoint** from the batch queue. Its
  wire shapes are exercised against a stand-in that speaks the documented
  protocol.
- **tmux is unexercised.** Its argv construction is tested exhaustively but has
  never run against a real tmux. The PTY backend (`--terminal pty`) has.

The [README](README.md) keeps the full list.
