# RelayForge — System Design Document

**A remote control surface + cost-optimization gateway for AI coding agents**

Version 0.1 · July 2026

---

## 1. Project Goals and Scope

### Core objective (one sentence)

> Let a developer supervise and drive AI coding agents running on their own machines from a phone, watch, or glasses — while a gateway between the clients and the model cuts AI credit consumption by 60–85% through caching, routing, retrieval, and deterministic pre-checks.

### Why this exists

Coding agents (Claude Code, Codex, OpenCode) stall the moment you walk away from the terminal: a permission prompt sits unanswered, a plan finishes and nothing starts the next step. Existing remote-control options are fragmented (official Remote Control is phone-only and flaky, watch bridges are third-party, glasses are vaporware) and none of them address the second problem: unsupervised agents burn tokens indiscriminately — re-sending the same system prompt every turn, dumping whole files into context, and using a frontier model for work a small model can do.

RelayForge solves both in one system because they share an architecture: **everything flows through one gateway**, which is simultaneously the relay point for remote clients and the enforcement point for cost policy.

### What problem it solves, precisely

1. **Reach:** control any agent session on any of your machines from any device, including glanceable/one-tap surfaces (watch) and voice-first surfaces (glasses via phone).
2. **Cost:** reduce AI credit usage per *completed task* (not per call) via six enforcement mechanisms in the gateway, measurable per session.
3. **Continuity:** plans and sessions survive laptop sleep by living on an always-on runner, with file-backed plans (`PLAN.md`) as the durable unit of work.

### Out of scope (v1)

- Writing code on the wearable. The watch/glasses are control surfaces: approve, deny, redirect, dictate short instructions.
- Hosting the model. We call model APIs (or a self-hosted vLLM/Ollama endpoint); we never run inference in-process.
- Team/multi-tenant features, RBAC, audit exports. Single-user first.
- A custom agent. We wrap existing agents (Claude Code, OpenCode) via their hooks/CLI, we do not build one.

### Target audience and personas

| Persona | Description | Primary need |
|---|---|---|
| **Solo agent-driven developer** ("Harsh") | Grad student / indie builder running 1–3 agents on a home server or VPS; pays for API credits personally | Unblock agents from anywhere; make a fixed credit budget last 5–10× longer |
| **Consultant / freelancer** | Runs agents against client repos; bills clients, so cost-per-task is a line item | Per-project cost reports; hard budget caps per repo |
| **Startup tech lead** | Small team, shared always-on runner, multiple concurrent agent sessions | Fleet view of all sessions; approval delegation; team-wide model-routing policy |

Primary persona for MVP: the **solo agent-driven developer**. Every MVP decision is judged against them.

### Methodology

**Agile (Scrum-lite):** one-week sprints, a single living backlog, demo-driven ("every sprint ends with something you can tap on a phone"). Waterfall is wrong here because the wearable-UX and cost-policy spaces both need experimentation; we expect to throw away at least one approval-UI iteration and one routing heuristic.

Two fixed ceremonies only: Monday planning (30 min), Friday demo + retro (30 min). Everything else async on the project board.

---

## 2. User Stories

Format: *As a ⟨persona⟩, I want ⟨capability⟩ so that ⟨outcome⟩.* Ordered as a hierarchical backlog: **P0** = MVP-blocking, **P1** = fast-follow, **P2** = later.

### Epic A — Remote session control (P0)

- A1 (P0): As a developer, I want to see all my active agent sessions across machines in one list, so that I know what's running without SSH-ing anywhere.
- A2 (P0): As a developer, I want to receive a push notification when an agent needs approval, so that the agent never idles waiting for me.
- A3 (P0): As a developer, I want to approve/deny a tool call with one tap from my phone or watch, so that I can unblock work in under 5 seconds.
- A4 (P0): As a developer, I want to send a short text or dictated instruction to a running session, so that I can redirect the agent mid-task.
- A5 (P1): As a developer, I want to view the diff an agent produced before approving, so that I approve informed, not blind.
- A6 (P1): As a developer, I want to start a *new* session on a chosen repo from my phone, so that I can kick off work while commuting.
- A7 (P2): As a developer, I want a glasses-friendly voice loop (hear summary → speak decision), so that I can supervise hands-free.

### Epic B — Plan execution (P0)

- B1 (P0): As a developer, I want the agent to execute an existing `PLAN.md` in a repo step-by-step, so that expensive planning happens once and execution is repeatable.
- B2 (P0): As a developer, I want plan progress (step 3/7, current step title) visible on the watch, so that a glance tells me where things stand.
- B3 (P1): As a developer, I want to pause, skip, or reorder plan steps remotely, so that I can adapt without rewriting the plan.
- B4 (P2): As a developer, I want a completed step to auto-trigger the next one after tests pass, so that plans run overnight unattended (within budget caps).

### Epic C — Cost reduction (P0) ★ *the credit-saving feature set*

- C1 (P0): As a budget-conscious developer, I want every model call routed through a gateway that assembles a cache-friendly prompt prefix, so that repeated context bills at ~10% of the input rate instead of 100%.
- C2 (P0): As a budget-conscious developer, I want small/cheap models automatically used for triage, summarization, and file selection, so that the frontier model is only paid for edits and hard reasoning.
- C3 (P0): As a budget-conscious developer, I want lint/typecheck/tests run *before* any model call, so that I never spend tokens on errors a compiler finds for free.
- C4 (P0): As a budget-conscious developer, I want retrieval-based context (symbols + relevant line ranges) instead of whole-file dumps, so that input tokens per turn drop by an order of magnitude.
- C5 (P0): As a budget-conscious developer, I want a per-session and per-repo credit budget with a hard stop and a watch alert at 80%, so that a runaway loop can't drain my account.
- C6 (P1): As a budget-conscious developer, I want non-urgent work (test generation, doc sweeps, lint fixes) queued to the Batch API overnight at 50% off, so that background work costs half.
- C7 (P1): As a budget-conscious developer, I want conversation history auto-compacted into a rolling summary + pinned facts, so that turn 40 doesn't carry turns 1–39 verbatim.
- C8 (P1): As a budget-conscious developer, I want an exact/semantic response cache for repeated queries (same lint error, same "explain this function"), so that identical questions cost zero.
- C9 (P1): As a budget-conscious developer, I want a live dashboard of cache-hit ratio, cost per completed task, and per-model spend, so that I can see which policies pay off.
- C10 (P2): As a budget-conscious developer, I want draft-then-verify generation (cheap model drafts, strong model reviews only the diff), so that bulk code generation shifts to the cheap tier.

### Epic D — Reliability & security (P0/P1)

- D1 (P0): As a developer, I want the runner to survive laptop sleep by living on an always-on box in tmux, so that sessions don't die when I close the lid.
- D2 (P0): As a security-conscious developer, I want end-to-end encryption between my devices and the runner with keys that never touch the relay, so that the relay operator (even me-hosted) can't read my code.
- D3 (P1): As a developer, I want destructive commands (`rm -rf`, force-push, DB drops) to always require explicit approval regardless of auto-approve settings, so that convenience never becomes catastrophe.
- D4 (P1): As a developer, I want stale/dead sessions garbage-collected from the app list, so that the fleet view stays truthful.

---

## 3. Minimum Viable Product

### Ruthless cut line

**In the MVP (4 features + 4 cost mechanisms):**

1. **Runner daemon** wrapping Claude Code / OpenCode on one always-on Linux box (hooks for PermissionRequest / Stop / Notification), sessions in tmux.
2. **Phone app (PWA first)**: session list, live output tail, one-tap approve/deny, send instruction, plan progress.
3. **Watch surface**: push notification with Approve / Deny / "Open on phone" actions. *(Originally "notification actions only — no native watch app in MVP". Both were built; see M4. The notification-action path turned out to need the client to decrypt for itself, because the push deliberately carries nothing.)*
4. **Plan executor**: run `PLAN.md` step-by-step with a checkpoint commit per step.

**Cost mechanisms shipped in MVP (these are not optional add-ons — they're the product):**

- **M1. Cache-shaped prompt assembly** (story C1) — gateway owns prompt order: tools → system → repo conventions → compacted history → dynamic tail; `cache_control` breakpoints at each boundary.
- **M2. Two-tier model routing** (C2) — a static task-type → model table (no ML router in MVP): triage/summarize/select-files → small model; edit/debug/plan → large model.
- **M3. Deterministic pre-gate** (C3) — formatter, linter, typecheck, test runner execute first; only *failures* enter the prompt.
- **M4. Budget guard** (C5) — token meter per session/repo, 80% watch alert, 100% hard stop.

**Explicitly deferred (nice-to-have, not launch-necessary):**

- Native watch app with terminal preview → *notification actions suffice*
- Glasses support → *voice via phone assistant covers the interim*
- Batch API queue (C6), semantic response cache (C8), draft-then-verify (C10) → *each is additive; M1–M4 deliver the bulk of savings*. C6 and C7 have since been built — see M5.
- History compaction (C7) → *MVP uses the agent's built-in compaction*
- Multi-user, delegation, per-client reports
- Session start from phone (A6) → *MVP: sessions start at the runner; phone controls existing ones (matches "run the existing plan in the existing repository")*
- iOS/Android native apps → *PWA + push first; native only if push reliability demands it*

### Why this MVP holds together

The gateway (M1–M4) is on the critical path of every request anyway — the relay and the cost layer are the same process. So the MVP isn't "remote control, plus cost stuff later"; the first request that flows through the system is already cache-shaped, routed, pre-gated, and budgeted.

---

## 4. Wireframes and UX Flows

Text wireframes; translate to Figma before implementation.

### Flow 1 — Approval (the golden path, target < 5 s)

```
[Agent hits PermissionRequest hook]
        │
        ▼
┌─ WATCH NOTIFICATION ─────────────┐
│ 🤖 payments-api                  │
│ Wants to run:                    │
│ `pytest tests/billing -x`        │
│ Budget: ▓▓▓▓▓▓░░░░ 61%           │
│ [ ✓ Approve ] [ ✗ Deny ]         │
│ [ 📱 Open on phone ]             │
└──────────────────────────────────┘
   Tap ✓ → hook returns allow → agent continues
```

### Flow 2 — Phone: session list (home screen)

```
┌──────────────────────────────────┐
│ RelayForge          ⚙  📊        │
├──────────────────────────────────┤
│ ● payments-api      hetzner-1    │
│   Step 3/7 · Fix webhook retry   │
│   ⏳ awaiting approval  · 61% 💰 │
├──────────────────────────────────┤
│ ● portfolio-site    home-server  │
│   Idle · plan complete ✅        │
├──────────────────────────────────┤
│ ○ ml-experiments    hetzner-1    │
│   Offline · last seen 2h ago     │
├──────────────────────────────────┤
│ 📊 Today: $1.84 · cache hit 78%  │
└──────────────────────────────────┘
```

Design rules: status dot (● live / ○ dead) is the first glyph; budget bar is always visible; the cost strip at the bottom makes savings a *felt* feature, not a buried report.

### Flow 3 — Phone: session detail

```
┌──────────────────────────────────┐
│ ← payments-api        hetzner-1  │
├──────────────────────────────────┤
│ PLAN  ▸ 3/7  Fix webhook retry   │
│  ✅ 1. Reproduce failing case    │
│  ✅ 2. Add regression test       │
│  🔵 3. Patch retry backoff  ←    │
│  ⬜ 4. Update docs …             │
├──────────────────────────────────┤
│ ── live output (tail) ────────── │
│ Running pytest tests/billing…    │
│ 2 passed, 1 failed               │
│ FAILED test_retry_after_500 …    │
├──────────────────────────────────┤
│ [View diff] [Pause] [Skip step]  │
│ ┌──────────────────────────────┐ │
│ │ 🎤  Tell the agent…          │ │
│ └──────────────────────────────┘ │
└──────────────────────────────────┘
```

### Flow 4 — Cost dashboard

```
┌──────────────────────────────────┐
│ 📊 Usage — payments-api          │
├──────────────────────────────────┤
│ Cost per completed task          │
│  this week ▂▃▂▁▁  $0.42 avg ↓63% │
│ Cache-hit ratio      78% ✅      │
│ Tokens by tier                   │
│  small model  ████████ 71%       │
│  large model  ███ 29%            │
│ Saved by pre-gate: 41 calls      │
│ Budget: $6.10 / $10.00 (repo)    │
└──────────────────────────────────┘
```

### Decisions taken when these were built

- **Tiers are an *ordered* category, not a nominal one.** The "tokens by tier" bar
  therefore uses a single-hue ordinal ramp (light→dark = cheap→expensive) rather
  than categorical hues, which would have burned the identity channel on
  information the bar length already carries. Ramp validated in light and dark.
- **Flow 4's "cost per completed task" needs a task boundary the ledger does not
  have yet.** Until the plan executor attributes spend to steps, the sparkline
  shows **spend per hour** — a real number from the ledger rather than a
  plausible-looking one. Cost-per-task arrives with the step attribution.
- **Every chart is direct-labelled and has a values view.** No number on the
  dashboard is reachable only by hovering, which also covers the watch and
  screen-reader cases.
- **"Today" in the cost strip is a rolling 24 hours**, not a calendar day: the
  runner has no idea what timezone the phone is in.

### UX issues caught at wireframe stage (why we wireframe first)

- Approve buttons must render **inside the notification** — requiring an app-open kills the < 5 s target.
- The budget bar belongs on the *approval card itself*: the moment of approval is the moment of spend.
- Diff view on a watch is useless → watch gets command + summary only; diff is phone-tier.
- Voice input must confirm transcription before sending (dictation errors into a live agent are destructive).

---

## 5. Data Models and Database Schema

Store: **SQLite (WAL mode)** on the runner for MVP — single-writer, zero-ops, trivially backed up; a `STORE` interface keeps a Postgres swap non-breaking for the team tier. Time-series usage events append-only.

```sql
-- Machines the runner daemon is installed on
CREATE TABLE machine (
  id            TEXT PRIMARY KEY,        -- uuid
  name          TEXT NOT NULL,           -- "hetzner-1"
  pubkey        TEXT NOT NULL,           -- device pairing key
  last_seen_at  INTEGER,                 -- unix ms
  created_at    INTEGER NOT NULL
);

-- A git repository known to a machine
CREATE TABLE repo (
  id            TEXT PRIMARY KEY,
  machine_id    TEXT NOT NULL REFERENCES machine(id),
  path          TEXT NOT NULL,           -- absolute path on machine
  name          TEXT NOT NULL,
  budget_usd    REAL,                    -- NULL = no repo cap
  UNIQUE(machine_id, path)
);

-- One agent process lifecycle
CREATE TABLE session (
  id            TEXT PRIMARY KEY,
  repo_id       TEXT NOT NULL REFERENCES repo(id),
  agent         TEXT NOT NULL,           -- 'claude-code' | 'opencode'
  tmux_target   TEXT,                    -- 'forge:3.1'
  status        TEXT NOT NULL,           -- running|awaiting_approval|paused|done|dead
  plan_id       TEXT REFERENCES plan(id),
  budget_usd    REAL,                    -- session cap
  spent_usd     REAL NOT NULL DEFAULT 0,
  started_at    INTEGER NOT NULL,
  ended_at      INTEGER
);

-- File-backed plans (source of truth is PLAN.md; DB mirrors for UI)
CREATE TABLE plan (
  id            TEXT PRIMARY KEY,
  repo_id       TEXT NOT NULL REFERENCES repo(id),
  file_path     TEXT NOT NULL,           -- 'PLAN.md'
  content_hash  TEXT NOT NULL,           -- detect drift from file
  created_at    INTEGER NOT NULL
);

CREATE TABLE plan_step (
  id            TEXT PRIMARY KEY,
  plan_id       TEXT NOT NULL REFERENCES plan(id),
  ordinal       INTEGER NOT NULL,
  title         TEXT NOT NULL,
  status        TEXT NOT NULL,           -- todo|active|done|skipped|failed
  checkpoint_sha TEXT,                   -- commit created on completion
  UNIQUE(plan_id, ordinal)
);

-- Every approval decision, forever (audit + policy learning)
CREATE TABLE approval (
  id            TEXT PRIMARY KEY,
  session_id    TEXT NOT NULL REFERENCES session(id),
  tool          TEXT NOT NULL,           -- 'bash', 'write_file', …
  payload       TEXT NOT NULL,           -- the command / file summary shown
  risk          TEXT NOT NULL,           -- low|medium|destructive
  decision      TEXT,                    -- approved|denied|timeout
  decided_via   TEXT,                    -- watch|phone|web|auto_policy
  requested_at  INTEGER NOT NULL,
  decided_at    INTEGER
);

-- ★ The cost ledger: one row per model call (append-only)
CREATE TABLE usage_event (
  id            TEXT PRIMARY KEY,
  session_id    TEXT NOT NULL REFERENCES session(id),
  model         TEXT NOT NULL,
  tier          TEXT NOT NULL,           -- small|large|batch
  task_type     TEXT NOT NULL,           -- triage|select|summarize|edit|plan|debug
  input_tokens          INTEGER NOT NULL,
  output_tokens         INTEGER NOT NULL,
  cache_write_tokens    INTEGER NOT NULL DEFAULT 0,
  cache_read_tokens     INTEGER NOT NULL DEFAULT 0,
  cost_usd      REAL NOT NULL,           -- computed from a price table
  avoided       TEXT,                    -- NULL | 'pre_gate' | 'response_cache'
  created_at    INTEGER NOT NULL
);
CREATE INDEX ix_usage_session_time ON usage_event(session_id, created_at);

-- Response cache (C8, post-MVP; table ships in v1 schema to avoid migration)
CREATE TABLE response_cache (
  key_hash      TEXT PRIMARY KEY,        -- sha256(model + normalized prompt)
  response      TEXT NOT NULL,
  hit_count     INTEGER NOT NULL DEFAULT 0,
  created_at    INTEGER NOT NULL,
  expires_at    INTEGER NOT NULL
);

-- Paired client devices
CREATE TABLE device (
  id            TEXT PRIMARY KEY,
  kind          TEXT NOT NULL,           -- phone|watch|web
  pubkey        TEXT NOT NULL,
  push_token    TEXT,
  paired_at     INTEGER NOT NULL
);
```

### Migration-safety decisions made now

- `usage_event` is append-only with a computed `cost_usd` — price-table changes never rewrite history.
- `plan.content_hash` lets the file stay authoritative; DB is a mirror, so schema and file can't fight.
- `response_cache` and `approval.risk` ship in v1 even though their features are P1 — adding columns later is easy, but these are new *write paths* better born early.
- Everything keyed by TEXT uuid: merging two runners' databases later (team tier) needs no renumbering.

---

## 6. Software Architecture

```
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│  Watch      │  │  Phone PWA  │  │  Web        │      CLIENTS
│ (notif      │  │ (approve,   │  │ (dashboard, │
│  actions)   │  │  steer,     │  │  full diff) │
└──────┬──────┘  │  dictate)   │  └──────┬──────┘
       │         └──────┬──────┘         │
       └───── E2E-encrypted payloads ────┘
                        │
              ┌─────────▼─────────┐
              │   RELAY (dumb)    │   ─ WebSocket fan-out + push
              │  sees ciphertext  │   ─ APNs/FCM/WebPush trigger
              │  only             │   ─ stateless, self-hostable
              └─────────┬─────────┘
                        │ outbound WSS only (no inbound ports on runner)
      ══════════════════╪══════════════════════════════
                        │        YOUR MACHINE(S)
              ┌─────────▼─────────┐
              │   RUNNER DAEMON   │
              │  ┌─────────────┐  │
              │  │ Session Mgr │──┼── tmux ── Claude Code / OpenCode
              │  │ (hooks:     │  │             │ (existing repos,
              │  │  Permission,│  │             │  PLAN.md files)
              │  │  Stop, Noti)│  │             │
              │  ├─────────────┤  │             │
              │  │ Plan Exec   │──┼── git checkpoints per step
              │  ├─────────────┤  │
              │  │ ★ COST      │  │   every model call passes here:
              │  │   GATEWAY   │──┼──────────┐
              │  ├─────────────┤  │          │
              │  │ SQLite      │  │          │
              │  └─────────────┘  │          │
              └───────────────────┘          │
                                   ┌─────────▼──────────┐
                                   │  MODEL PROVIDERS   │
                                   │  Anthropic API /   │
                                   │  self-hosted vLLM  │
                                   │  / Batch endpoint  │
                                   └────────────────────┘
```

### The Cost Gateway — request pipeline (the credit-saving core)

Every model-bound request runs this pipeline, in order:

```
request(task_type, session, dynamic_content)
  │
  1️⃣ BUDGET CHECK        spent ≥ cap? → hard stop, notify watch
  │                       spent ≥ 80%? → warn once per session
  │
  2️⃣ PRE-GATE            task involves code just written/edited?
  │                       → run fmt / lint / typecheck / affected tests
  │                       → all green & task was "verify"? RETURN, $0
  │                       → failures only become the dynamic tail
  │
  3️⃣ RESPONSE CACHE      hash(model+normalized prompt) in cache & fresh?
  │                       → RETURN cached, $0, log avoided='response_cache'
  │
  4️⃣ ROUTER              task_type → tier table:
  │                         triage, select_files, summarize,
  │                         commit_msg, title      → SMALL model
  │                         edit, refactor         → LARGE model
  │                         plan, hard_debug       → LARGE (top) model
  │                       (override: plan file may pin a tier per step)
  │
  5️⃣ CONTEXT BUILDER     retrieval, not dumping:
  │                         repo symbol index (ripgrep + tree-sitter)
  │                         → file skeletons + relevant line ranges
  │                         → hard cap: N bytes per file, M files total
  │
  6️⃣ PROMPT ASSEMBLER    stable→volatile order, cache breakpoints:
  │                         [tools]⟂[system+conventions]⟂[repo map]
  │                         ⟂[compacted history] | dynamic tail
  │                         (⟂ = cache_control breakpoint; nothing
  │                          dynamic ever precedes a breakpoint)
  │
  7️⃣ DISPATCH            interactive → live API
  │                       flagged deferrable (tests-gen, docs, lint-fix)
  │                       → Batch queue, flushed nightly at 50% rates
  │
  8️⃣ LEDGER              write usage_event with all four token counts
                          + task_type + tier; update session.spent_usd
```

Stages 2, 3 (zero-cost exits) and 4, 5, 6 (cost-shrinking) are independent multipliers — that's why combined savings land in the 60–85% range rather than any single mechanism's number.

### Contracts (defined now, before code)

**Runner ↔ Relay (WSS, msgpack, E2E-encrypted payload):**

```
runner→relay: session_upsert {session, status, plan_progress, spent_pct}
runner→relay: approval_request {approval_id, tool, payload_summary, risk, spent_pct}
runner→relay: output_chunk {session_id, seq, text}          (tail, throttled)
client→relay→runner: approval_decision {approval_id, decision, device_id}
client→relay→runner: instruction {session_id, text}
client→relay→runner: plan_control {session_id, action: pause|resume|skip}
```

**Runner internal — Gateway API (HTTP on localhost):**

```
POST /v1/complete   {task_type, session_id, messages, deferrable?}
                    → {response, usage:{in,out,cache_w,cache_r}, tier, cost_usd}
GET  /v1/usage      ?session_id=…&since=…   → ledger rows
GET  /v1/budget     ?session_id=…           → {cap, spent, pct}
```

Agents integrate two ways: (a) Claude Code hooks call the runner for approvals while Claude Code talks to Anthropic directly — gateway savings then come from pre-gate, budget, and routing of *auxiliary* calls; or (b) full-gateway mode for OpenCode/custom agents where `ANTHROPIC_BASE_URL`-style redirection sends every call through `/v1/complete`, unlocking the complete pipeline. Ship (a) first — zero agent modification — and (b) as the flagship mode.

**Third-party services touched:** Anthropic API (+ Batch), optional local vLLM/Ollama endpoint, APNs/FCM/WebPush, git (local), tailnet or Cloudflare Tunnel if the user wants relay self-hosted at home.

### Security posture

- Runner makes **outbound connections only**; no listening ports exposed beyond localhost.
- E2E encryption (libsodium sealed boxes) between devices and runner; relay stores/forwards ciphertext and push triggers only — a compromised relay learns session *existence*, not content.
- Destructive-command classifier (regex + allowlist tier) forces `risk='destructive'` approvals to phone (not watch one-tap) — deliberate friction.
- Device pairing via QR containing runner pubkey + one-time code; keys in platform keystores.

---

## 7. Technology Stack

Principle applied: **simplest stack that one person can build, deploy, and debug** — not the most scalable.

| Layer | Choice | Why (and why not the alternative) |
|---|---|---|
| Runner daemon | **Rust 2024 / tokio** | The daemon is long-lived, holds E2E key material, and juggles four concurrent I/O sources (WSS to relay, localhost HTTP, tmux child processes, SQLite). Memory safety is not optional in a process that holds the user's private keys, and `tokio` covers all four sources on one runtime. Ships as a single static binary (`musl` cross-compile) — the packaging win previously credited to Go. Claude Code hooks are process invocations reading JSON on stdin, so they are language-agnostic; nothing about them requires Node. |
| Gateway | Same Rust process, module boundary (`forge-core`) | It's on every request's critical path; IPC to a separate process buys nothing at single-user scale. |
| Repo indexing | `grep`/`ignore` crates + tree-sitter (native bindings) | ripgrep *is* Rust, so stage 5 searches in-process instead of shelling out, and tree-sitter binds natively rather than through WASM. |
| DB | **SQLite (WAL)** via `rusqlite` (bundled) | Zero-ops, single file, perfect for one runner. No system SQLite dependency to install on the VPS. Postgres only when team tier exists. |
| Relay | Rust + `axum`/`tokio-tungstenite` on **Fly.io** (or self-hosted on the same box over Tailscale) | Stateless ciphertext fan-out; ~50 lines of logic; Fly gives cheap global anycast. |
| Phone client | **React Native (Expo)** for iOS/Android + a **PWA** (React + Vite) for the browser | Originally PWA-only, "native only if iOS push reliability forces it" — split on request. The PWA keeps the no-app-store path and owns the cost dashboard; the native app gets the platform keystore and a route to APNs. Everything except the screens is shared in `packages/client-core`, so the split costs one package, not two implementations. |
| Watch | **Native watchOS app** (SwiftUI) + notification actions | Originally "zero watch code in MVP", reversed on request — see M4. Its own paired identity, so `decided_via: watch` is true and D3 is enforceable. Notification actions are still outstanding. |
| Voice | Phone-side dictation (platform STT) | Free, offline-capable, no audio pipeline to build. |
| Models | Anthropic API (small tier: Haiku-class; large tier: Sonnet/Opus-class) + optional **vLLM/Ollama** endpoint for the "my own model" small tier | Router treats every tier as an OpenAI/Anthropic-compatible endpoint URL — self-hosted small models drop the small-tier cost to electricity. |
| Batch | Anthropic Batch API | 50% discount; stacks with caching. |
| Hosting (runner) | User's box: home server, Hetzner/DO VPS, in tmux under systemd | The whole point: your machine, your repos, your credits. |
| CI | GitHub Actions | Free tier suffices. |

Rejected up front: Kubernetes (one daemon ≠ cluster), Redis (SQLite covers queues at this scale), GraphQL (six endpoints don't need it), React Native for MVP (store review cadence would dominate sprint time), C++ for the runner (its only edges — raw compute and existing C++ libraries — are irrelevant here, since §1 rules out in-process inference; what it costs is manual lifetime management in the one process holding private keys).

**Cost of the Rust choice, stated plainly:** the runner and the clients are now two languages. Contracts are msgpack/JSON over the wire either way, so the seam is a serialization boundary rather than a shared type system — worth re-checking at Milestone 3 when the relay protocol solidifies.

---

## 8. Timeline and Task Breakdown

Solo-developer plan, part-time (~15–20 h/week). 10 weeks to public MVP. Board columns: Backlog → This Sprint → In Progress → Review → Done.

### Milestone 0 — Foundations (Week 1) ✅
- [x] Repo scaffold: cargo workspace (`crates/forge-core`, `crates/forge-runner`, `crates/forge-relay`; `app/` joins at M3), CI, `rustfmt` + `clippy -D warnings`
- [x] SQLite schema v1 migration (all tables from §5, including deferred-feature tables), versioned by `PRAGMA user_version` and applied transactionally
- [x] Price table module + `usage_event` writer (the ledger exists before the first model call)
- **Exit criterion:** ✅ `cargo test` green (36 tests); `cargo run -p forge-runner -- demo` renders a cost number.

### Milestone 1 — Runner controls an agent (Weeks 2–3) ✅
- [x] tmux session manager: spawn/attach/kill Claude Code & OpenCode
      *(argv construction tested exhaustively; the tmux calls themselves are
      unexercised — no tmux on the development machine)*
- [x] Hook bridge: PreToolUse/PermissionRequest block on the runner's decision;
      Stop/Notification captured. Verified end to end against real payloads.
- [x] Plan executor v0: parse `PLAN.md` checklist, drive steps, checkpoint commit per step
      *(parser + step state machine + `plan_step` mirror shipped; the git checkpoint
      write lands with the tmux bridge)*
- [x] CLI smoke client (approve from a second terminal) — superseded by the HTTP API:
      `POST /v1/approvals/{id}/decision` is curl-able, and the app is the real client
- **Dependency:** none external. **Risk:** hook API drift → the adapter is built as designed: every field is `#[serde(default)]`, unknown events become no-ops, and the documented payloads are pinned as test fixtures so drift fails a test rather than production.
- **Exit criterion:** ⚠️ partially met. Approvals round-trip end to end against real hook payloads (approve, deny, timeout, and runner-down fallback all verified). Driving a plan through a *live agent in tmux* is still unproven for want of tmux.

**The failure modes, decided deliberately.** The hook bridge sits between an
agent and its next action, so its behaviour when something breaks matters more
than its happy path:

| Situation | Decision returned | Reasoning |
|---|---|---|
| Runner unreachable | `defer` | Falls back to Claude Code's own prompt. RelayForge being down degrades to plain Claude Code, never to an unsupervised agent. |
| Nobody answers in time | `deny`, recorded as `timeout` | D3's principle: convenience must never become catastrophe. |
| Bug in the bridge | `defer`, exit 0 | Exit 2 would make stderr a *blocking* reason, turning our bug into the user's blocked agent. |

**One schema change.** Migration 0002 adds `session.agent_session_id`: the hook
is handed Claude Code's session id, and without somewhere to record it every
tool call would create a fresh session.

### Milestone 2 — Cost Gateway v1 ★ (Weeks 3–5, overlaps M1) ✅
- [x] `/v1/complete` with pipeline stages 1→8 — stage 3 is the real response cache, not a pass-through
- [x] Prompt assembler with cache breakpoints; **cache-hit-ratio test harness** (`crates/forge-gateway/tests/savings.rs`)
- [x] Static router table + per-step tier pinning from `PLAN.md`
- [x] Pre-gate adapters: prettier/eslint/tsc, ruff/mypy/pytest, cargo fmt/clippy/test, gofmt/vet/test
- [x] Budget guard + 80%/100% events — per-session *and* per-repo caps
- **Dependency:** Anthropic API key. Verified against a local compatible endpoint via `ANTHROPIC_BASE_URL`. The Batch API path (C6) is now built — see M5 — so a deferrable call is queued and billed at half rates. With batching switched off it is still dispatched live and `batch_downgraded` says so, rather than claiming a discount it did not get.
- **Exit criterion:** ✅ measured, from the ledger — **90.7% cost reduction** over 50 replayed turns and a **99.7% cache-read ratio**, both asserted in CI. Caveat: the provider's caching is simulated per-breakpoint by a stub, so these are the harness's numbers, not production telemetry. The first real-traffic measurement belongs in M5.

**Stage ordering, corrected in implementation.** §6 lists the response cache as stage 3, ahead of routing and assembly. It cannot run there: an exact-prompt cache key has to include the routed model and the retrieved context, or it collides across genuinely different calls. The built order is 1 → 2 → 4 → 5 → 6 → 3 → 7 → 8. The property that mattered is preserved — both zero-cost exits still happen before any spend.

**Deliberate scope call on the response cache.** Only read-only task types are cacheable (triage, select, summarise, commit message, title). An edit, refactor, plan, or hard-debug response is a proposed *mutation*; replaying one against a repo that has moved on is how a patch gets applied twice. Those always reach the model even when the prompt bytes match.

### Milestone 3 — Relay + Phone (Weeks 5–7)
- [x] Relay: WS fan-out, **forward-only** (see below), push trigger
- [x] E2E crypto: pairing QR, authenticated-box envelopes, key storage
- [x] Runner-side relay client: dials outbound, seals events per paired device, opens and dispatches device commands
- [x] Device pairing: single-use code, terminal QR, `device` table
- [x] WebPush delivery: VAPID signing + `aes128gcm` payloads — see below
- [x] The PWA's own crypto — device keypair, envelope seal/open, pairing screen, and a relay transport the views cannot tell apart from the HTTP one
- [x] PWA: session list, session detail (plan + output tail), approve/deny, instruction box with dictation
      *(built against the runner's localhost API over SSE; the relay swaps in
      underneath without the client changing)*
- **Dependency:** WebPush on iOS requires the PWA installed to home screen (iOS 16.4+). This turned out to be worse than "document it": Safari resolves `Notification.requestPermission()` to `"denied"` in a browser tab **without prompting** — no dialog, no error, nothing in the console. A user who hits it concludes the feature is broken. The app detects the case before attempting anything and says what to do instead. The Expo contingency this dependency existed to trigger has since been taken for other reasons — there is now a React Native client too.
- **Exit criterion:** ⚠️ met in software, not on cellular. `crates/forge-runner/tests/remote_approval.rs` runs the whole path — a device with its own keypair approves through a real relay and the runner records the decision with the right `decided_via` — but over loopback, with a simulated phone. The app now holds up its half: `packages/client-core/src/crypto.test.ts` opens envelopes Rust sealed (and vice versa, against a checked-in fixture), and `transport.test.ts` beside it drives the relay client against a fake socket and a real runner identity. What is left is not code but a measurement — nobody has approved anything from a phone on a train.

**One structural consequence worth recording.** There are now two ways for a device to reach the runner: the localhost HTTP API and the relay link. They must not be able to diverge on policy — a transport that forgot the D3 destructive-approval rule would be a silent hole. So every device-initiated action goes through one `commands` module that owns the rule, and both transports are thin adapters over it. The relay test asserts a watch is refused over the relay specifically, so the shared path is verified rather than assumed.

The same symmetry had to be built on the client. `packages/client-core/src/transport.ts` defines one interface with two implementations, so no view knows which one it is talking to — which is the only reason the screens written in M3 against loopback HTTP work unchanged over the relay.

**WebPush, and the one thing it forced a change to.** Delivery is VAPID (RFC 8292) plus `aes128gcm` payload encryption (RFC 8291), hand-rolled from RustCrypto primitives the workspace already depends on. That is only defensible because RFC 8291 §5 publishes a complete worked example — fixed keys, fixed salt, fixed expected ciphertext — and the implementation reproduces it byte for byte. It was also opened by Node's OpenSSL in a live run, which is the foreign-implementation check the `mobile/watch` Poly1305 bug taught us not to skip.

The payload is empty and encrypted. Empty because the relay cannot read the envelope that triggered the wake-up and so has nothing truthful to say; encrypted anyway because an unencrypted push is one whose shape the push service reads plainly.

**The change: the relay does not decide who gets woken.** The first version pushed whenever any envelope was published on a channel, which is the obvious place to put it — the relay is where the wake-up is sent from. It is also wrong, and badly. The relay sees ciphertext, so it cannot distinguish an approval request from a line of build output; an agent running `cargo build` would have buzzed every paired phone every ten seconds for the length of the build. The rate limit does not save you, it just sets the buzzing interval.

So the decision moved to the runner, which is the only party that knows what happened: it publishes the sealed event, then explicitly asks for a wake-up via `POST /v1/push/{channel}` if — and only if — the event was an approval request or a budget alert. The relay stays dumb, which is the whole point of the relay. `deserves_a_wake_up` in `crates/forge-runner/src/relay.rs` is four lines and is the most consequential four lines in the push path.

**Three things the relay's shape forced, which §6 does not mention.**

**1. A query needs an answer, and fan-out has none.** Events push one-to-many, which is all the relay was specified to do — but a phone opening cold needs to *ask* for the fleet. Adding a request/response layer to the relay would give it state and correlation metadata, which is what it exists not to have. Instead the runner accepts `snapshot`/`session_snapshot` commands and seals the answer **to the asking device only**, and the client matches replies to waiting calls by their shape. Same channel, same envelopes, no new relay concepts.

**2. A refusal has to travel back.** Over loopback a rejected command is an HTTP status on the call itself. Over the relay the first implementation logged it on the runner and told the device nothing — so a watch tapping a destructive approval, or an instruction to a session that had ended, simply evaporated. "I tapped it and nothing happened" is the worst possible failure for a remote control surface. Refusals are now sealed back to the sender as a `command_error`, addressed rather than broadcast, so one device's refusal is not another device's business.

**3. No camera.** The QR was going to be scanned in-browser. Reading one needs `BarcodeDetector`, which iOS Safari does not implement — the same platform every other decision here bends around. The runner prints the payload as text beside the QR and the app takes a paste. A native client can scan it later; nothing about the protocol changes.

**Deliberately not built: the cost dashboard over the relay.** It needs a third snapshot type. It is also the one screen with no live urgency — nothing about last week's cache-hit ratio needs answering from a train. `RelayTransport.supportsDashboard` is `false` and the session screen says `cost: local only`, which is better than an empty chart that looks broken.

**Scope change, requested after M3 was built: separate web and native clients.** The milestone shipped one PWA. It is now three clients — `web/` (the PWA), `mobile/` (React Native, iOS + Android), and `mobile/watch/` (native SwiftUI). What did *not* change is the wire format or the policy.

The split is along the only line that survives contact with the platforms: everything that is not a screen moved to `packages/client-core`, which touches no DOM, no `localStorage`, no React, and no React Native. That constraint is enforced rather than stated — the package's tests run in a Node environment with no jsdom, so a DOM dependency fails the build instead of failing on a phone.

Three things had to be lifted out of the original PWA code to make that true, and each one is a real platform difference rather than a refactor:

1. **Storage became an interface.** `localStorage` is synchronous; Keychain and AsyncStorage are not. `PairingStore` is async, which is slightly awkward on the web and correct everywhere. The phone stores its device secret in the platform keystore, which is the one place a native client is meaningfully safer than the PWA — there is no origin for an injected script to run on.
2. **`atob`/`btoa` had to go.** Hermes has neither, and `Buffer` is Node's. The base64url codec is now twenty lines of table lookup, checked against Node's `Buffer` for every length up to 64 and every byte value.
3. **SSE is web-only.** React Native has `fetch` and `WebSocket` but no `EventSource`. On the runner's own network the phone polls; over the relay the WebSocket is already there. The `Transport` interface takes the stream as a parameter rather than assuming one exists.

**Two corrections to this milestone's design, made while building it.**

**1. Authenticated boxes, not sealed boxes.** A sealed box is anonymous — it encrypts to a recipient's public key with a throwaway keypair, so the recipient learns nothing about the sender. The runner's public key travels in the pairing QR, which means anyone who photographs that QR could seal a perfectly valid `approval_decision` to the runner, and the runner would have no way to distinguish it from the paired phone's. It would also make `approval.decided_via` meaningless. Both directions now use authenticated `crypto_box`: identical confidentiality, plus a sender the receiver verifies. The cost is that a device must be paired before it can speak, which was the intent anyway.

**2. Store-and-forward → forward-only.** §6 said "ciphertext store-and-forward". The relay stores nothing: a channel exists only while it has members and is dropped when the last one leaves. A device that was offline re-fetches state from the runner on reconnect, which it must do regardless. Keeping a spool would create exactly the durable record of who-talks-to-whom that the security posture is trying not to accumulate, in exchange for a fallback nobody needs.

**Residual, stated plainly.** The relay still learns that *someone* is connected to a channel and roughly how many bytes they sent. That is the documented, accepted metadata leak — it is what makes routing possible at all.

### Milestone 4 — Watch + Budget UX (Week 8)
- [x] Wake-ups for approvals and budget alerts (WebPush) — see M3
- [x] Notification *actions* — Approve/Deny on the notification itself, and **no buttons at all for destructive commands**
- [x] Budget bar on approval cards, on every client — the moment of approval is the moment of spend
- [x] Session GC (dead-session sweep) — a session whose pane has gone is marked
      `dead`; one that finished cleanly stays `done`, and one adopted from a hook
      (no pane the runner owns) is never swept
- [x] **Native watchOS app** — scope change, see below. Own keypair, own relay
      connection, approvals and plan progress on the wrist
- [x] 80% wrist alert — the budget guard's event is one of the two that wakes a device
- **Exit criterion:** ⚠️ not measured. The golden path now exists end to end —
  push wakes the device, the notification names the actual command, and one tap
  decides it — and every piece is tested, but nothing has been timed on video and
  no build has run on a watch.

**The notification had to become a client, not a message.** §3 assumed the wrist
tier was "notification actions" and nothing else: a push arrives carrying the
approval, you tap Approve, done. That cannot work here, and the reason is the
security posture. The relay cannot read the envelope that triggered the wake-up,
so the push carries **no payload** — which means the notification has nothing to
name and the action button has no approval id to act on.

The resolution is that the service worker does the decrypting. On a wake-up it
reads the pairing, opens its own connection to the relay, pulls a fleet snapshot,
and decrypts it locally before writing the notification. So the body says
`payments-api · pytest tests/billing -x` while the relay still knows nothing.
Both properties hold at once; they just cost a round trip the naive design did
not have.

Two consequences worth recording:

1. **The pairing had to move from `localStorage` to IndexedDB.** A service worker
   cannot read `localStorage` — the API is synchronous and simply is not exposed
   to workers. Without a store both can reach, the worker has no key, and the
   whole feature collapses back to "something happened". The async `PairingStore`
   interface introduced for React Native's keystore absorbed this without a
   change to its shape, which is the first time that abstraction paid for itself.
2. **Destructive commands get no action buttons.** This extends D3 rather than
   restating it. A notification action can be hit from a lock screen without the
   app ever coming to the front — it is a *less* deliberate surface than the
   wrist tap D3 already refuses, so applying the same rule is the only consistent
   answer. The runner still enforces its own rule server-side; the client simply
   declines to offer the button.

**Scope change: the native watch app was promoted from P2.** §7 says "Zero watch code in MVP; actions cover approve/deny. Native watchOS app is a P2 epic," and §3 agrees. That was the right call for a notification-only wrist tier. It was reversed on request, and building it surfaced one design question the deferred version never had to answer.

**The watch is a device, not a remote control.** The obvious implementation is for the watch to send taps to the phone and let the phone act. That is wrong here for a specific reason: the runner enforces D3 — destructive commands cannot be cleared from a wrist — against *the registered kind of the device whose key sealed the envelope*. A watch acting through the phone arrives as `phone`. The rule would quietly stop applying, and `decided_via` would record something untrue.

So the watch is a first-class paired device: its own keypair, its own row in `device` with `kind = 'watch'`, its own WebSocket to the relay. The phone's entire role is carrying the watch's **public** key to the runner during pairing, because claiming a code needs an HTTP request on the runner's own network and a watch usually is not on one. The secret half never leaves the wrist, including into a backup — the Keychain item is `AfterFirstUnlockThisDeviceOnly`, so a restore to new hardware cannot resurrect a revoked watch.

**React Native does not run on watchOS, and this is not a limitation to work around.** There is no `UIView` hierarchy to bridge to; every "React Native watch app" is a native watchOS target talking over WatchConnectivity. So the watch is SwiftUI, and it needs NaCl `crypto_box` — which Apple does not ship. CryptoKit has X25519 but no XSalsa20-Poly1305, so Salsa20, HSalsa20, and Poly1305 are hand-written.

**That produced the most instructive bug in the project.** The first `Poly1305` read its top 26-bit limb from byte 13 instead of byte 12 — off by one byte. *Every Swift-only test passed*: round-trips, tamper detection, a sweep across every block boundary. Seal and open shared the same wrong arithmetic, so the implementation was perfectly self-consistent. It was wrong only when talking to something else, and only for messages of 13 bytes or more, because below that the dropped byte is zero padding.

Hand-written crypto that only talks to itself is indistinguishable from correct. The interop fixture caught it in the first run; the permanent guard is now two-layered — the fixture, which all three implementations open, plus byte-for-byte TweetNaCl vectors at every length where the padding rules change. **The general lesson is worth more than the bug: a test that exercises both sides of your own code proves consistency, not correctness. Only a foreign implementation proves correctness.**

**C6, the batch queue.** Deferrable work — test generation, doc sweeps, lint fixes — is queued rather than dispatched, submitted to the Batches API, and billed at **half rates**. The discount stacks with prompt caching, so this is the cheapest the gateway can buy tokens.

The interesting part is not the discount, it is what the queue must never do. Every other failure here is recoverable: a batch that errors can be resubmitted, one that expires can be rebuilt. **Being billed twice for the same work cannot be undone**, and it is the one thing a cost gateway must not do. So three separate guards, each with a test named after the failure it prevents:

- Submitting moves the whole batch in one transaction, so a crash partway cannot leave half the items looking queued — the queued half would go out in the next batch and be paid for twice.
- `settle_batch_item` only acts on an item still marked `submitted`, so fetching results twice (a poll overlapping a retry) writes one ledger row, not two.
- `custom_id` is unique in the database, so a result can never be attributed — or billed — to the wrong session.

Ordering matters too, and the obvious order is wrong. The flusher **submits first and records second**. The other way round marks items sent that a failed submit never sent, and they sit `submitted` forever waiting for results from a batch that does not exist. This order can duplicate at most one batch if the process dies between the two steps, which is recoverable by hand; the other is not recoverable at all.

**A queued call returns an id, not text**, and says so — `served: "queued"`, empty text, zero cost. Nothing is billed until the real token counts come back. Pretending to have an answer would be the easy thing and the wrong one.

The Messages params are built by the *same function* a live dispatch uses, so a batched call cannot be assembled — or priced — differently from the live one it replaces. Two copies of that would drift, and the way you would find out is a surprising bill.

**C7, history compaction — and the measurement that corrected it.** A long session re-sends its whole history every turn. Past a threshold the gateway summarises the oldest turns on the small tier, bills that call like any other, and hands the caller back a compacted history to store. Over 40 replayed turns it saves **42%**, from the ledger.

The design was wrong on first pass, in a way worth recording. The module was written around this argument: *compaction invalidates the prompt cache, because the assembler's value is a byte-stable prefix; so compaction is expensive and the policy must be rare and large.* The benchmark contradicted it. History sits **after** the stable breakpoints — tools and system, then conventions, then the repo map, then history — so rewriting it invalidates only the history segment. Everything ahead still reads at 0.1×. Compacting *harder* turned out to be 84% cheaper again.

So the justification for the conservative defaults is not the one that was written down. It is **fidelity**: every compaction pass re-summarises text that already contains a summary, and detail decays geometrically. After a dozen passes, what survives from turn 3 has been through a dozen lossy rewrites, and an agent that has forgotten what it already tried costs far more than the tokens saved — in a currency the ledger cannot see.

The benchmark now asserts that gap explicitly rather than hiding it, with a comment saying that if the assertion ever flips, the trade-off needs revisiting. **The general lesson: a cost argument that has not been measured is a hypothesis, and this one survived being written into a module doc without ever being true.**

**The destructive-command policy file.** §7 lists this as an M5 doc deliverable; it turned out to be a feature. The built-in classifier is broad — around forty patterns — but it structurally cannot know that `make reset-staging` drops your staging database, and a rule that only exists in someone's head is not a rule.

Two design decisions carry the weight:

1. **Additive, never replacing.** Local rules are layered *on top of* the built-ins. Somebody adding one `flyctl` pattern must not silently lose `rm -rf`, and a test asserts exactly that.
2. **The escape hatch is per-pattern.** `allow` retires named built-ins; there is no `enabled = false`. A blanket off switch is the setting somebody flips while debugging at 2am and never restores, and D3 is the only thing between a half-awake wrist tap and a force-push. Retiring `sudo` leaves `DROP TABLE` alone, and that is tested too.

A malformed policy file is a **startup error**, not a fallback to the built-ins. The failure it prevents: somebody writes a rule expecting it to be enforced, makes a typo, and the runner comes up looking healthy while the rule does nothing.

`forge-runner policy <command>` answers "would this be gated?" without asking an agent to run something destructive — which is the only other way to find out.

**The quickstart, and the bug it found.** Writing it was supposed to be documentation. Walking it from an empty directory — the way it tells you to, `mkdir ~/.relayforge && cd ~/.relayforge && forge-runner serve` — produced a runner that served the API happily and **404'd the app itself**.

`--app-dir` defaulted to the literal relative path `web/dist`, which resolves against the working directory. That works only when the runner is started from the repository root, which is exactly what a state directory is not. The banner also still said `pnpm --dir app build`, a path that stopped existing at the web/mobile split.

Both are the kind of thing no test catches and no amount of re-reading finds, because the code is correct in the situation its author was in. The fix is a search with explicit precedence — working directory, then beside and above the binary, then `/usr/local/share` — and an explicit `--app-dir` is still taken at face value, because silently searching elsewhere after somebody named a directory is worse than serving nothing.

**`forge-runner install-service` prints a systemd unit with this machine's paths already substituted.** A quickstart that says "create a unit, substitute your paths, set your user, mind the working directory" has four places to get it wrong, and the failure mode of most of them is a service that starts, looks healthy, and silently uses the wrong database. It prints rather than writes: installing a system service is privileged and system-wide, and a tool that did it silently on a machine somebody was only trying out would deserve the reputation it got.

The unit reads the API key from an `EnvironmentFile` rather than inlining it — a key written into a unit is in `systemctl cat`, in journald, and in shell history. The runner's unit is deliberately *less* hardened than the relay's: the relay keeps nothing across a restart so it gets `ProtectSystem=strict` and `ProtectHome`, while the runner's whole job is running agents in your repositories, and a unit that sandboxed those away is one nobody would keep.

### Scope added after the plan: multiple agents, and a desktop app

Both requested after M4. Neither changes the architecture; both were absorbed by
seams that already existed, which is the useful thing to record.

**Multiple agents.** The `Agent` enum had two variants and one of them —
OpenCode — was startable but *unsupervised*: approvals only ever arrived through
Claude Code's hook bridge, so an OpenCode session would ask in its terminal and
wait forever. That was a latent lie in the schema, and closing it is what the
work actually was.

Agents now come in two supervision channels:

- **Hook.** The agent calls the runner and blocks. Exact, and the only channel
  that can refuse a tool call the agent never announced. Claude Code only.
- **Prompt.** The agent asks in its own terminal and waits for a keystroke; the
  runner reads the question out of the pane, raises an ordinary approval, and
  types the answer back when a human decides. Everything else.

The important property is that both end in the *same* queue — same
destructive-command classifier, same D3 phone-only rule, same budget meter, same
push notification. Supporting a new agent adds a dialect, not a second and
weaker approval path. `crates/forge-core/src/agent.rs` is the whole registry.

**The prompt channel is a heuristic and the design says so.** It is pattern
matching on terminal output. The failure it is tuned against is typing `y` at
something nobody agreed to, so it never guesses: an unmatched prompt is simply
not seen, and the session sits there — which is what would have happened without
RelayForge at all. `/v1/agents` reports `verified: false` for every dialect not
checked against the real binary.

**Two bugs worth recording, both found by running it rather than reading it.**

1. *One enum, two wire formats.* `text_enum!` derived `rename_all = "snake_case"`
   for serde while `as_str` was explicit. Every variant agreed by coincidence
   except `Agent`: `claude-code` in SQLite, `claude_code` over JSON. So
   `/v1/agents` advertised `opencode` and `POST /v1/sessions` answered *unknown
   variant `opencode`*. Fixed by renaming each variant to its own storage
   string, with a test that asserts the two forms agree for every text enum.
2. *An answered question that never went away.* tmux's `capture-pane` returns the
   current screen, so an answered prompt is overwritten and vanishes. A raw PTY
   has only append-only scrollback, where it stays visible forever — so the
   watcher re-raised an approval for a command that had already run, every poll,
   indefinitely. The fix is a rule that is correct on both backends and obvious
   in hindsight: **an agent waiting for input has printed nothing since it
   asked.**

**A desktop app.** `forge-runner serve` assumes a box you administer — a shell,
tmux, a systemd unit, a spare terminal for the banner. That is right for a VPS
and wrong for the laptop you write code on, and impossible on Windows. The
desktop app is the same library in a window: same API, same approval rules, its
own per-user database and key.

It needed exactly one new thing, and that thing was worth having anyway: a
terminal backend that does not need tmux. `crates/forge-runner/src/pty.rs` owns
its pseudo-terminals, works on Windows via ConPTY, and is *verified against real
processes* — which tmux, on this machine, still is not.

**One defect worth recording, because it would have shipped.** The first version
loaded the window from Tauri's asset protocol, which is the documented default
and looks right. It could not work: the client fetches `/v1/fleet` *same-origin*,
because it is written to be served by the runner, and under `tauri://localhost`
every one of those requests resolves against the asset protocol and never reaches
the embedded axum server. The app compiled, the binary ran, and every screen
would have read "cannot reach the runner".

The fix inverts the assumption — point the window at `http://127.0.0.1:<port>`
and the desktop app becomes the same deployment the browser already uses. Same
origin, same SSE stream, zero Tauri-specific client code. Desktop-only controls
(`/v1/desktop/status`, `/v1/desktop/relay`) are HTTP routes merged onto the same
router rather than IPC commands, for the same reason: one path, not two. It was
found by asking "what origin does this actually run on", not by the compiler.

**What the desktop app deliberately is not.** "Control any computer from your
phone" is only worth having if it cannot become "control any computer from
anyone's phone". So it accepts no arbitrary commands from the network. Every
remote action goes through `forge_runner::commands` — the same gated path the
localhost API uses. Approvals are *answered*, not issued; instructions are typed
into an agent's own terminal; destructive commands still cannot be cleared from
a wrist; a device must be paired on your own network first, and unpairing
revokes it. The capability that was added is *hosting*, not *shell access*.

### Milestone 5 — Dashboard + Hardening + Beta (Weeks 9–10)
- [x] Cost dashboard (cost/task, cache-hit, tier split, pre-gate saves) — **and over the relay**: `Command::DashboardSnapshot` is the third snapshot type, assembled by the same `build_dashboard` the HTTP endpoint uses so both surfaces render identical bytes
- [x] Batch queue for deferrable tasks (C6) — see below
- [x] Destructive-command policy file — see below
- [x] Docs: 15-minute VPS quickstart ([QUICKSTART.md](QUICKSTART.md)) + generated systemd units
- [ ] 5-user private beta; instrument crash + cache-ratio telemetry (opt-in)
- **Exit criterion:** two consecutive beta days with zero manual runner restarts; median beta cache-hit ≥ 60%.

### Critical-path dependencies (front-loaded checks)

1. **Anthropic account features** (caching TTLs, Batch) — verify Week 1.
2. **Claude Code hook stability** — pin version, adapter layer, Week 2.
3. **iOS WebPush reliability** — decision gate end of Week 6 (PWA stays vs. Expo contingency).
4. **APNs notification-action limits on watch** — spike in Week 7 before Milestone 4 planning.

### Post-MVP roadmap (sequenced by savings-per-effort)

1. ~~Response cache C8~~ → 2. ~~History compaction C7~~ → 3. ~~Batch queue C6~~ → 4. ~~Draft-then-verify C10~~ → 5. Session-start-from-phone A6 → 6. ~~Native watch app~~ → 7. Glasses voice loop A7 → 8. Team tier (Postgres, delegation, per-client reports).

C10 landed as part of M6 rather than on its own, because the native agent is
what gave it something to verify. "Strong model reviews the diff only" needs a
diff, and before M6 nothing in the system produced one.

### Scope added after the plan: a native agent, and diff review (M6)

Not in the original plan at all, and the largest single addition since it: the
runner grew **its own coding agent**, and with it the screen the rest of the
product was implicitly aiming at.

The plan's whole frame was *supervision* — RelayForge watches an agent somebody
else wrote and relays its questions to a phone. That frame has a ceiling built
into it: the thing you get asked about is a **tool call**, and a tool call is a
bad unit of review. `Bash: pytest -x` tells you nothing about whether the work
is right. It is a yes/no you answer in a hurry to unblock a process.

The unit worth reviewing is a **diff**. So `forge-agent` runs a tool loop
through the existing cost gateway, stages every edit in an overlay instead of
writing it, and hands back a unified diff for a human to approve or reject. That
is the Cursor-shaped half of the product — except the review happens on a phone,
against a budget, with the same destructive-command classifier in the path.

Three decisions worth recording, because each one had a plausible alternative:

- **Edits are staged; only `run` raises a card.** The alternative — approving
  each edit as the agent makes it — is not supervision, it is a captcha, and it
  would have made a twelve-edit task unusable from a phone. Commands still go
  through the queue one at a time because a command is what cannot be undone by
  doing nothing.
- **The loop calls `Gateway::complete` rather than a provider.** Anything else
  would have made the budget guard, the router, the ledger and the prompt cache
  advisory for the system's own agent — the one caller most able to run up a
  bill.
- **Tool turns are recorded in history as text, not as content blocks.** The
  structured form would have meant reworking the assembler and the compaction
  pass, which are the most heavily tested code in the repo and the reason the
  cache-read ratio is 99% rather than 0%. The trade is written down in
  `crates/forge-agent/src/task.rs` rather than discovered later.

The security posture is unchanged, and deliberately so: a change set cannot be
approved from a watch, `run` is classified by the same rules with the same
policy file, starting a task is loopback-only exactly as starting a session is,
and applying a change set whose files moved underneath it fails loudly rather
than clobbering. What was added is *authorship*, not new authority.

Four things followed from the review screen existing, and all are part of M6:

- **Reject-and-retry.** A rejection stores a reason; `retry_of` composes the next
  attempt from it. Without this the review screen was half a loop — a "no" with
  nowhere to go. The original row is never edited, so the trail keeps both the
  refused change set and its replacement.
- **C10, draft-then-verify.** The loop drafts on the large tier and one frontier
  call reads the finished patch. Measured at **50% against frontier-throughout**
  on an identical task; the verifier's input was 866 bytes against 4,716 for the
  final drafting turn, which is the whole argument in two numbers.
- **Undo.** The overlay was already keeping both sides of every file so it could
  render a diff, which means reverting is `apply` with the two swapped. Without
  it, "applied" was the only irreversible step in a system whose entire design
  is that nothing is — a denial leaves no state, a rejection leaves no state,
  and then approving quietly overwrote the working tree for good. Guarded in the
  mirror direction: undoing over a later human edit is refused, so the tree only
  moves between two states somebody has seen.
- **A ceiling on concurrent tasks.** `start` is non-blocking by design, which
  made it unbounded by accident: fifty POSTs were fifty agents drafting in
  parallel against a repo that has no cap by default. Three at once, `429`
  after that, and a refusal writes no row. The repo budget would have caught it
  eventually, but "eventually" is denominated in dollars.

The last two are worth recording as a pattern rather than two fixes. Both are
the same mistake — a property the design *relies* on (nothing is irreversible;
spend is bounded) that the new code did not actually provide, in a place where
the old code never had to. Adding a first-class *actor* to a system built for
supervising other people's actors is where those gaps live.

**Unproven:** no real model has driven the loop. See the README's known gaps.

---

## Appendix A — Success Metrics

| Metric | Target (MVP) | Source |
|---|---|---|
| Cost per completed task vs. baseline | ≥ 50% reduction | `usage_event` ledger, benchmark tasks |
| Cache-read ratio (stable workloads) | ≥ 70% | cache_read / (cache_read + input) |
| Approval latency (notification → decision) | median < 5 s | `approval.requested_at → decided_at` |
| Agent idle-waiting time | ≥ 90% reduction vs. no-notify | session status timeline |
| Runaway-spend incidents past cap | 0 | budget guard logs |
| Runner uptime (beta fortnight) | zero manual restarts | telemetry |

Guard-rail metric: **task retry rate** must not rise as context is trimmed — savings that cause rework are fake savings. If retries climb, loosen stage-5 caps before anything else.

## Appendix B — Credit-Reduction Feature Index

| # | Feature | Mechanism | MVP? | Expected effect |
|---|---|---|---|---|
| M1/C1 | Cache-shaped prompts | Stable-prefix ordering + breakpoints; reads bill ~10% of input | ✅ | Largest single lever on repeated context |
| M2/C2 | Tiered routing | Cheap model for triage/select/summarize | ✅ | Shifts majority of calls off frontier pricing |
| M3/C3 | Deterministic pre-gate | Compiler/linter/tests before any model call | ✅ | Eliminates whole call classes ($0) |
| M4/C5 | Budget guard | Per-session/repo caps, wrist alerts, hard stop | ✅ | Caps worst case; makes cost visible at approval time |
| C4 | Retrieval context | Symbols + line ranges, byte caps | ✅ (in stage 5) | Order-of-magnitude input reduction vs. file dumps |
| C6 | Batch deferral | Nightly queue at 50% rates | ⏳ | Halves all background work |
| C7 | History compaction | Rolling summary + pinned facts | ⏳ | Prevents linear context growth per turn |
| C8 | Response cache | Exact/semantic hit = $0 | ⏳ | Kills repeated identical questions |
| C10 | Draft-then-verify | Cheap drafts, strong model reviews diff only | ✅ | **Measured: 50% vs frontier-throughout** (`forge-agent --test draft_then_verify`) |
| B1 | Plan-once/execute-cheap | Expensive planning amortized across cheap steps | ✅ | Frontier model pays once per plan, not per step |
