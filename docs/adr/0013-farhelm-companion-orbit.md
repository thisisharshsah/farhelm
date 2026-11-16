# 0013: Farhelm and Companion, two products that work alone and together

Status: proposed, 2026-11-14, revised the same day. User direction: Companion
must work without Farhelm, because some people want only the app; Farhelm
provides models; Orbit is not needed as a separate project; and one app
replaces the separate interfaces. The stack, rules and order below are a
recommendation for the owner to confirm. Nothing is removed without the
owner's approval; the candidates and the reasons are listed near the end.

## Context

Three projects grew side by side, and each built its own copy of the same
pieces.

- **Farhelm** (this repository): the runner, the gateway with its model
  registry and ledger, the front door for other projects (ADR 0010), the model
  hub (ADR 0011), tasks and runs (ADR 0012), an encrypted relay with paired
  devices, the web app, a Tauri desktop app, an Expo phone app and a SwiftUI
  watch app.
- **Companion** (`apple/` in this repository since 2026-11-15, before that
  `~/Project/companion`): a native macOS app (overlay, chat and
  code modes, a Chromium browser, computer use) with iPhone, iPad and Watch
  apps. It has its own model engines (Anthropic, OpenAI, Ollama, subscription
  command-line tools, and Farhelm), its own usage records, its own phone link
  (QR pairing; Bonjour on the Wi-Fi, and since 2026-11-15 the relay elsewhere,
  sealed end to end), and its own agent loop and approvals.
- **Orbit** (`~/Project/_archive/orbit`, last commit 2026-10-02): a Rust
  computer-use core. A closed set of screen actions with no way to run a
  command, leases that expire when the screen changes under them, redaction
  before a frame leaves the machine, a kill switch and an append-only history.
  Also a web overlay prototype and a blueprint for a cloud planner. Nothing in
  Farhelm or Companion uses its code.

Companion already does what Orbit was for. `DeviceControl` types, presses keys,
and presses buttons, menu items, checkboxes and links found by their label in
the app in front. The agent shows its steps for a yes or no, Escape cancels,
and typing stops if the app in front changes. `UI/Orbit.swift` shows on screen
where the agent acts. Three Orbit ideas are missing from Companion: hiding
secret fields before a screenshot reaches a model, a permanent record of every
action (today the steps live only in the chat), and a check right before each
action that the same field still has focus (today only the app is checked).

| Piece | Farhelm | Companion | Orbit |
|---|---|---|---|
| Model access and usage | gateway, registry, one ledger | five engines, `Usage.swift` | cloud planner (design only) |
| Phone and watch link | relay, end-to-end encrypted, a key per device | `RemoteServer` on the Wi-Fi; the same relay elsewhere, a key per pairing | none |
| Agent loop and approvals | runs; phone and web approve; rule D3 | `AgentJob`, `AgentShell`; only the Mac approves | lease validator; irreversible actions wait for a person |
| Computer use | none yet | `DeviceControl` (Swift) | `orbit-macos` and the daemon's rules |
| Clients | web, Tauri, Expo phone, Swift watch | macOS, iPhone, iPad, Watch | web overlay prototype |

Two rules conflict today:

- **Approvals.** Companion lets only the Mac approve. Farhelm lets the phone
  and the web approve, records which device did, and refuses destructive
  approvals from a wrist (D3, `mobile/watch/README.md`).
- **Running commands.** Orbit never runs one. Farhelm's and Companion's agents
  run commands after approval.

### What leading AI companies do

1. **Check every computer-use action outside the model.** Google runs a
   per-step safety service on each action Gemini proposes and lets developers
   require confirmation for high-stakes actions. OpenAI's Operator asks before
   actions that change something (a purchase, an email), pauses on sensitive
   sites when the user is not watching, and a separate monitor pauses it on
   suspected prompt injection. Anthropic advises approval for anything hard to
   undo and blocking sensitive apps such as banking.
2. **Give the agent its own identity and the least access.** Windows runs
   agents under separate agent accounts in their own workspace, with access
   granted explicitly, revocable at any time, and approval for sensitive
   actions.
3. **Keep "what a command can do" apart from "when to ask".** Codex has a
   sandbox (writes only in the workspace, network off by default) and a
   separate approval policy.
4. **Make computer use a mode of the assistant, not a product.** OpenAI folded
   Operator into ChatGPT as agent mode on 2025-07-17 and announced the end of
   the separate Operator site.
5. **Let the app work with any model.** Apple's Foundation Models framework
   (WWDC 2026) works with Apple's own models, Claude, Gemini or any provider
   that conforms to its Language Model protocol, behind one API in the app.
6. **Prefer structured actions to driving the screen.** Apple's App Intents
   expose an app's actions to Siri and Apple Intelligence. MCP is the open
   standard for tools, with the user's consent before any tool runs; its
   2026-07-28 revision lets a tool stop mid-call for the user's answer.
7. **Meter use through a gateway with a key per client.** LiteLLM's virtual
   keys carry budgets, rate limits and allowed models, with spend recorded per
   key. Farhelm's front door (ADR 0010) already works this way.
8. **Meet at a published contract.** Apple's Swift OpenAPI Generator builds a
   Swift client from an OpenAPI document at build time, so an app and a
   service can change separately as long as the document holds.
9. **Keep one source of truth.** Google's single repository makes changes
   atomic and code easy to share, at the cost of tooling and code-health work.

## Decision

### Two products

- **Companion is the app** on Mac, iPhone, iPad and Watch, and the only
  interface. It works with no Farhelm installed: its own model connections,
  data, device pairing, agent and approvals.
- **Farhelm is the engine** and has no app of its own. Alone, developers use it
  through its OpenAI-compatible API, a command line and its config files, and
  other projects keep using the front door (ADR 0010). When Companion finds a
  Farhelm on the same Mac, or is given the address of one elsewhere, Companion
  becomes its interface.
- **Orbit is retired** as a project once its three missing ideas are in
  Companion (step 2). Its code stays in the archive. The word "orbit" stays
  for Companion's on-screen indicator and mark.

| | Companion alone | With Farhelm too |
|---|---|---|
| Models | The person's API keys (Anthropic, OpenAI, Gemini, OpenRouter), Apple's on-device model, Ollama or LM Studio, subscription command-line tools | Adds Farhelm's managed local models (llama.cpp, MLX) and its shared limits |
| Data | On each device, synced through the person's iCloud | The same; Farhelm keeps only engine data: models, keys for other clients, runs, usage |
| Devices | Mac, iPhone and Watch pair directly by QR code | Can also reach a Farhelm on another machine |
| Agent | Acts and asks for approval on the Mac | Long runs keep going after the app closes |

### Stack

**Companion (Swift)**

| Layer | Choice |
|---|---|
| Language and UI | Swift 6 language mode; SwiftUI with AppKit where needed; Observation for app state, so views redraw only for what they read. Minimums stay macOS 14, iOS 17 and watchOS 10; newer features sit behind availability checks |
| Models | One provider protocol, grown from today's `LLMConfig`: Anthropic; one OpenAI-compatible adapter for OpenAI, Gemini, OpenRouter, Ollama, LM Studio and Farhelm; Apple's on-device model (macOS and iOS 26 and later); subscription command-line tools, read-only. `Usage.swift` keeps the records for the person's own keys |
| Keys | The Keychain, optionally synced with iCloud Keychain; never in files or logs |
| Data | SQLite through GRDB in place of today's JSON files; settings stay in UserDefaults; sync with CloudKit's `CKSyncEngine`, which needs macOS 14, iOS 17 and watchOS 10 (Companion's minimums today). Developer ID apps can use CloudKit |
| Device link | QR pairing. On the same Wi-Fi the app reaches the Mac directly; elsewhere both meet on a relay (`Shared/CompanionLink`, built 2026-11-15): the Mac dials out, every frame is sealed with a key that only travels in the QR code (ChaCha20-Poly1305 under HKDF keys, one per direction, channel and sender bound in, repeats refused), and the relay opens the channel with a seat derived from the same key, so it reads nothing. iroh 1.0 stays the candidate for direct device-to-device paths later, behind the same requests |
| Agent | Accessibility first, then ScreenCaptureKit, with keyboard and mouse events; the three Orbit ideas; App Intents (intent and entity schemas, View Annotations) so Siri, Spotlight and Shortcuts can use Companion; code runs in Apple's Containerization (a small virtual machine per run, macOS 26 on Apple silicon), with today's limits as the fallback |
| Speech | FluidAudio (Parakeet, speaker labels) plus Apple's SpeechAnalyzer on macOS 26 and later, chosen per language on our own recordings |
| Quality | `os.Logger`, MetricKit, Swift Testing, Apple's Evaluations framework |
| Shipping | Mac: direct download, Developer ID, notarized, Sparkle updates (the App Store sandbox limits the terminal and control of other apps). iPhone, iPad and Watch: the App Store |

**Farhelm (Rust)**

| Layer | Choice |
|---|---|
| Core | Rust 2024, Tokio, Axum and SQLite, as today |
| Models | llama.cpp and MLX side by side, chosen by model format (MLX generates faster on Apple silicon; llama.cpp stays for long inputs); the gateway for cloud providers; vLLM when a GPU server is used |
| Interfaces | The OpenAI-compatible API and front door (ADR 0010); an OpenAPI document for its own API; a command line; MCP at the 2026-07-28 revision |
| Running | A launchd agent on a Mac, registered by Companion with `SMAppService` or installed by hand; systemd on Linux |
| Code runs | Apple's Containerization on macOS 26 and later; cap-std and process-wrap as the fallback |
| Quality | `tracing` with OpenTelemetry's generative AI spans (still a draft standard, so the version is pinned); model and agent checks in CI |

### The contract between them

- Farhelm publishes an OpenAPI document for its own API, derived from the Rust
  types with utoipa. Companion generates its Farhelm client from it with Swift
  OpenAPI Generator.
- Companion connects as the `companion` client (ADR 0010).
- A capabilities call tells Companion what this Farhelm supports, and Companion
  shows only those features, so the two release on their own schedules.
- Shared request and response fixtures run in both test suites and catch
  drift.
- No shared library is linked into Companion, so UniFFI is not adopted. It
  comes back only if native Android or Windows apps are built.

### Shared rules (owner to confirm)

1. **One approval policy**, written once here and checked by shared test
   cases; each product enforces it for the actions it takes. Recommended:
   payments, sending messages, deleting and anything destructive are approved
   only on the Mac; a phone or the Watch can approve routine steps; nothing
   destructive is ever approved automatically or from a wrist (D3).
2. **Two capabilities, two policies.** Screen actions can never run a command.
   Code runs execute approved commands in a sandbox, with writes limited to the
   workspace and the network off unless approved.
3. **Nothing sensitive leaves the device unasked.** Secret fields are hidden
   from every screenshot and transcript before any model sees it, local or
   cloud. Farhelm's `local_only` (ADR 0006) gets a matching switch in
   Companion.
4. **The person at the keyboard owns the record.** Transcripts and the action
   history are theirs; there is no view for anyone else.
5. **Content is never a command.** Screens, pages, files and tool descriptions
   are data. A monitor pauses a run on suspected prompt injection.

### One repository, by operating system

- Companion came into this repository whole, as `apple/`, with every one of
  its commits rewritten to that path so log and blame work on its files
  (owner decision, 2026-11-15). Nothing inside it moved, so its build is
  unchanged. Orbit stays in the archive.
- Folders follow the operating system (user direction, 2026-11-14), reached in
  checked steps rather than one big move. Farhelm's Rust workspace stays at
  the root: it runs on every OS, and moving a working workspace buys nothing.
  `apple/` splits by OS next, each split built on a Mac before the next one.
  Proposed, names for the owner to confirm:

  ```
  Cargo.toml, crates/   Farhelm, the engine (Rust)                     (macOS, Linux)
  apple/shared/         Swift packages the Apple apps share            (macOS, iOS, watchOS)
  apple/macos/          Companion for Mac, and Farhelm's launchd setup
  apple/ios/            Companion for iPhone and iPad
  apple/watchos/        Companion for Watch
  deploy/               Farhelm's server setup (systemd, launchd)
  web/                  only if a non-Apple version is kept (open decision 1)
  ```

  The iPhone and Watch apps keep one Xcode project, because Apple ships the
  Watch app inside the iPhone app; only their source folders are split. Each
  move updates paths, scripts, CI and docs in the same step, as AGENTS.md
  requires for directory moves.
- The root `AGENTS.md` holds the shared rules; each app root keeps its own file
  only for what differs.

### Open decisions

1. **A web version for people without Apple devices, or Apple only.** If kept,
   Farhelm's web app becomes that version and keeps its client package. If
   not, it joins the removal candidates.
2. **The approval split** in rule 1.
3. **The device link:** decided 2026-11-15 (user direction: the apps must work
   away from the home network too): QR pairing, directly on the Wi-Fi and through the
   relay elsewhere, with nothing to install and no account (see Device link
   above). Farhelm's relay serves both products: Companion's channels are seat
   channels (`c1-…`, `farhelm-relay`'s `auth.rs`), Farhelm's keep their control
   plane tokens. Tailscale still works as one more direct address. iroh is
   evaluated later only for direct paths.
4. **Names:** the product name, the folder names, and the clash between the
   model alias `companion` (fennec's tuned model, ADR 0011) and the API client
   `companion`.

## Order of work

Each step leaves everything working.

1. **This ADR.** The owner confirms the two products, the rules and the open
   decisions.
2. **Orbit's three ideas in Companion:** secret fields hidden before any
   screenshot reaches a model, a permanent action record, and the focus check
   before each action. Orbit then stays in the archive.
3. **Merge the repositories** (mechanical only, Companion's history kept).
   Done 2026-11-15 as `apple/`; the split by OS follows in checked steps.
4. **One provider layer in Companion**, with keys in the Keychain.
5. **The contract:** Farhelm's OpenAPI document and capabilities call,
   Companion's generated client, shared fixtures in CI.
6. **Companion's data in SQLite with iCloud sync**, moving today's JSON files
   once.
7. **Farhelm as a service:** the launchd agent, the command line, and
   Companion's screens for Farhelm's models, keys, runs and approvals, shown
   when a Farhelm is connected.
8. **Retire the duplicates:** freeze each one (fixes only), then remove it once
   Companion covers it, one at a time, each with the owner's approval.

Farhelm's engine work (MLX beside llama.cpp, the 2026-07-28 MCP revision,
OpenTelemetry spans) does not depend on these steps and can go in at any time.

## Removal candidates (nothing removed; each needs the owner's OK)

| Candidate | Why it may not be needed | After step | Instead |
|---|---|---|---|
| Orbit (`~/Project/_archive/orbit`) | Companion already does computer use and shows where it acts | 2 | Companion, with Orbit's three ideas |
| Farhelm's phone app (`mobile/`, Expo) | A second iPhone app | 7 | Companion's iPhone and iPad apps; Android follows open decision 1 |
| Farhelm's watch screens (`mobile/watch/Sources/FarhelmWatchUI`) | A second Watch app | 7 | Companion's Watch app, keeping rule D3 |
| Farhelm's desktop app (`desktop/`, Tauri) | Farhelm needs no window: Companion is its interface on a Mac, and Linux runs it as a service | 7 | Companion, or the web version if kept |
| Farhelm's web app (`web/`) and `packages/client-core` | Needed only for people without Apple devices | 7 | Follows open decision 1 |
| Companion's separate Ollama client (`OllamaClient.swift`) | Ollama speaks the OpenAI-compatible API | 4 | The OpenAI-compatible adapter |

No longer candidates: Companion's model engines, usage records, pairing and
agent loop. They are what lets Companion work alone.

Review later, not proposed for removal yet:

- Farhelm's device pairing (`FarhelmCrypto`, `FarhelmWatchKit`), once open
  decision 1 is made. The relay itself stays: Companion reaches the Mac
  through it.
- Chromium (CEF), Companion's heaviest dependency; WebKit already works as the
  fallback.
- The Python runtime bundled in Companion, used only for iCloud Passwords.

## Consequences

- Anyone can use Companion with just the app; Farhelm is an upgrade, not a
  requirement.
- Two provider layers exist, Swift in Companion and Rust in Farhelm's gateway.
  They do different jobs (one app calling providers, one gateway serving many
  clients), and the shared fixtures keep their behavior aligned.
- Farhelm's API becomes a public contract. It needs versions, a capabilities
  call and a notice period before anything breaks.
- One interface to maintain on Apple devices, two if the web version is kept.
- The person's data lives on their devices and in their iCloud, not on a
  server this project runs.
- Orbit's code is not reused; its ideas are.

## Sources

- Google: [Introducing the Gemini 2.5 Computer Use model](https://blog.google/technology/google-deepmind/gemini-computer-use-model/)
- OpenAI: [Operator system card](https://openai.com/index/operator-system-card)
- OpenAI: [Introducing Operator](https://openai.com/index/introducing-operator/), with the 2025-07-17 update on ChatGPT agent
- Anthropic: [Keeping your use of Cowork safe](https://support.claude.com/en/articles/13364135-keeping-your-use-of-cowork-safe)
- Microsoft: [Securing AI agents on Windows](https://learn.microsoft.com/en-us/windows/security/book/operating-system-agentic-security)
- OpenAI: [Codex agent approvals and security](https://learn.chatgpt.com/docs/agent-approvals-security.md)
- Apple: [WWDC26 guide for macOS](https://developer.apple.com/wwdc26/guides/macos/) (Foundation Models, App Intents, Evaluations)
- Apple: [App Intents](https://developer.apple.com/documentation/appintents)
- Apple: [CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5)
- Michael Tsai: [CloudKit and Map Kit for Gatekeeper apps](https://mjtsai.com/blog/?p=14844), 2016, on Developer ID apps using CloudKit
- Apple: [Swift OpenAPI Generator](https://github.com/apple/swift-openapi-generator)
- Apple: [Containerization](https://github.com/apple/containerization)
- [GRDB](https://github.com/groue/GRDB.swift) and [Sparkle](https://sparkle-project.org)
- Google: [Gemini OpenAI compatibility](https://ai.google.dev/gemini-api/docs/openai)
- n0: [iroh 1.0](https://iroh.computer/blog/v1)
- [Model Context Protocol specification](https://modelcontextprotocol.io/specification/latest) and [the 2026-07-28 revision](https://blog.modelcontextprotocol.io/posts/2026-07-28/)
- [MLX and llama.cpp on Apple silicon](https://yage.ai/share/mlx-apple-silicon-en-20260331.html), 2026-03-31
- [SpeechAnalyzer, Whisper and Parakeet compared](https://rohitraj.tech/en/notes/apple-speechanalyzer-vs-whisper-on-device-stt-2026), 2026-07-17
- [OpenTelemetry generative AI conventions, status](https://www.dash0.com/knowledge/opentelemetry-genai-semantic-conventions-explained), 2026-09
- LiteLLM: [Virtual keys](https://docs.litellm.ai/docs/proxy/virtual_keys)
- Mozilla: [Developing shared Rust components](https://firefox-source-docs.mozilla.org/rust-components/developing-rust-components/index.html) (UniFFI, considered and not adopted)
- Potvin and Levenberg, [Why Google stores billions of lines of code in a single repository](https://research.google/pubs/why-google-stores-billions-of-lines-of-code-in-a-single-repository/), Communications of the ACM, 2016
