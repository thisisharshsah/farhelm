# Farhelm project instructions

This is the canonical, living instruction file for work in this repository. Last reviewed: 2026-10-25. Use `AGENTS.md`, not a parallel `agent.md` with competing rules.

## Product direction and instruction maintenance

- Build a commercial, local-first AI service/workspace combining chat and multimodal assistance, coding tools, supervised agents, linked documents/context, project management and workflow automation. References include Cursor, ChatGPT, Claude, Gemini, Devin, Macro at macro.com, and monday.com.
- Local/open-weight models, retrieval, tools and measured LoRA/other specialization are central. OpenRouter and authorized free API tiers may supplement local inference. Do not claim universal frontier-model parity or treat free remote capacity as a production guarantee.
- Keep an end-to-end workflow working while expanding scope. The initial proposed slice is discussion → task → agent implementation/tests → diff review → task update. Developer teams are an initial working audience, not a permanent restriction on the broader goal.
- Treat usable onboarding and a coherent responsive interface as part of working functionality. Verify account sign-in end to end, surface unavailable account services truthfully, and retain account-free local use.
- Favor widely supported tools, clear ownership, familiar conventions and maintainability. The user explicitly permits directory and architecture changes when they improve these outcomes; preserve working behavior through an incremental migration.
- Follow current explicit user instructions within applicable system/developer rules. Repository guidance must not become a reason to request repeated approval for routine, already-authorized work.
- Other agents may work in this checkout concurrently. Inspect and incorporate compatible changes, reconcile conflicts against the product goal, and preserve unrelated work. Coordinate ownership where possible; do not overwrite changes merely because another agent made them.
- When the user supplies a durable goal, constraint or preference, update this file in the same task. Capture the operative rule, not a transcript. Do not persist secrets, temporary debugging details or unconfirmed assumptions as user requirements.
- When guidance conflicts with an updated goal or implementation, reconcile it, update affected documentation and remove obsolete rules. Distinguish a user-directed change from an agent recommendation. Explain material changes briefly in the completion report.
- Read [the engineering guide](docs/engineering-stack.md) before structural work. Record substantial stack, contract, storage, trust-boundary or directory decisions with rationale and migration consequences; add a focused ADR under `docs/adr/` when needed. Routine implementation choices do not need an approval ceremony.
- Keep this root file short enough to use. Put detailed research/examples in `docs/`; use scoped nested `AGENTS.md` files only when a subtree needs genuinely different instructions. Maintain one source of truth for each rule.

## Stack baseline and dependency policy

- Retain the working Rust 2024 / Tokio / Axum / Serde / reqwest backend, SQLite via rusqlite, React + strict TypeScript + Vite clients, Tauri desktop, Expo/React Native mobile, and Swift watch implementation unless a concrete migration improves the product.
- Use Cargo and pnpm workspaces and their committed lockfiles. Respect the repository's Rust MSRV and each platform's supported dependency versions. Do not upgrade dependencies to “latest” or align web/mobile React versions merely for uniformity.
- Preferred additions, when their feature is implemented: Postgres + a compatible SQLx release for hosted data, generated Rust/TypeScript contracts, boundary validation, structured tracing, TanStack Query for complex server state, React Testing Library and Playwright for meaningful UI flows. These are not all installed today.
- Use Ollama as the initial developer-serving default; llama.cpp is an alternative for deployment needs. Use vLLM for the shared GPU-serving path after conformance and workload testing. Keep training separate with Python/PEFT and a reproducible training tool such as Axolotl.
- Introduce Python only for concrete model/data/training work; use `pyproject.toml`, a uv lockfile, Ruff and pytest there. Do not replace the working Rust application backend with a second Python application backend by default.
- Add dependencies for an identified problem. Check maintenance, license, platform/runtime compatibility, transitive impact and operational cost. Prefer one primary library per responsibility. Keep optional evaluation candidates separate from adopted dependencies.
- Use rustfmt/Clippy for Rust. For future client tooling, prefer a compatible ESLint configuration with React Hooks rules and Prettier for formatting; these are not configured today. Introduce tooling and any mechanical formatting separately from feature changes.

## Architecture and directory ownership

- Keep a modular application with explicit boundaries; do not introduce a microservice, queue, framework or generic abstraction without a concrete need.
- `crates/farhelm-proto`: wire DTOs, events, commands and compatibility. Keep transport/storage implementation and business policy out.
- `crates/farhelm-domain`: deterministic rules and state transitions. No filesystem, network, database, process execution, async runtime or ambient clock access; pass external facts/time as arguments.
- `crates/farhelm-app`: application use cases and narrow ports. Keep HTTP handlers, SQL and provider wire formats outside these use cases. Preserve the existing explicit-time approach; do not invent traits for every dependency.
- `crates/farhelm-sqlite`: local storage implementation and append-only migrations. Cloud persistence currently also uses SQLite; hosted Postgres is a future change, not an existing capability.
- `crates/farhelm-process`: bounded subprocess capture and process-group/job lifetime management shared by approved commands and trusted prechecks. This is not a sandbox. File tools use no-follow directory capabilities and deliberately reject internal as well as external symlinks.
- Gateway, agent, runner, cloud, relay, crypto and MCP crates retain their respective model policy, execution, composition, control-plane, transport and security roles. Model requests must use the gateway's policy/accounting path.
- `packages/client-core`: platform-neutral transport, contracts, validation, crypto and shared transformations. Keep React UI, DOM/native storage and application state in platform clients.
- `web/`, `mobile/`, `desktop/`: existing application roots. Group new substantial client features by responsibility; extract existing code as it is changed. Do not scaffold empty modules for every future feature.
- Directory moves are allowed. Update imports, workspace manifests, scripts, CI, service workers, Tauri assets, native configuration and docs together. Keep mechanical moves separate from behavior changes where practical. Never leave two active implementations or compatibility shims without a removal condition.

## Coding patterns

- Follow nearby conventions. Use descriptive names, small cohesive modules and explicit data flow. Explain invariants and non-obvious decisions in comments; avoid narrating the code or speculative extension frameworks.
- Keep handlers thin: validate/decode → authenticate/authorize → application operation → typed response/error. Apply the same authorization rules across HTTP, relay, MCP and background execution.
- Use typed errors/results and explicit state transitions. Reserve panics/unchecked assertions for established invariants or tests. Do not swallow user-relevant failures or turn skipped work into success.
- Keep blocking SQLite/filesystem work out of async executor hot paths. Use appropriate bounded blocking execution. Current Store ports are synchronous: a future async Postgres adapter needs a deliberate boundary design, not hidden `block_on` calls.
- Parameterize SQL; use transactions and database constraints for atomic invariants. Do not hold a database transaction across inference, network calls or a long command. Do not rewrite a migration already applied to durable user data; add a new one.
- Repository list reads return registered metadata without scanning the host or creating registrations. Any future host discovery must be an explicit, bounded operation with its own documented scope. Offer local use deliberately; an account server on localhost is not a runner.
- Bound retries, deadlines, concurrency, buffers and logs. Cancellation must stop/clean up child processes and release resources; dropping a future is not proof that the OS process ended.
- Keep external JSON as `unknown`/untrusted until validated. Derive wire types, schemas and tool arguments from their designated source when practical; retain cross-language fixtures. TypeScript types alone do not validate runtime data.
- Use React components/hooks with one clear responsibility. Keep local UI state local, derived values derived, remote resource state in its resource layer, and route identity in routing. Clean up subscriptions, timers and pending work.
- Scope resource/cache keys to the relevant account/workspace, runner and resource. Clear identity-scoped data on sign-out or context change. Do not silently persist decrypted customer content or display another resource's stale data.
- Provide loading, empty, refresh, offline, authorization and error states. Consequential mutations need duplicate-submission protection and truthful pending/result feedback; no automatic retry or optimistic success without backend semantics to support it.
- Web UI direction (user direction, 2026-10-26): Codex/coding-agent apps are the primary reference for the shell and task/session threads, and monday.com for the overview and board. Linear, Vercel, Cursor and Devin are secondary references. Research comparable products before substantial UI changes; a user screenshot is one input, not the spec. New workspace styles live in `web/src/app.css`; status is a filled pill with its word, never colour alone.
- Preserve design tokens and native semantic controls. Deliver keyboard operation, visible focus, labels and meaningful status text. Custom dialogs/listboxes require complete focus and keyboard behavior. Do not add another styling system for a single feature.

## Model, execution and data invariants

- Keep provider-specific payloads behind adapters. Preserve structured messages/content, tool-call identities, matching tool results, finish reasons and actual usage. Do not execute tool requests parsed from arbitrary prose.
- Assemble complete streamed tool arguments before schema validation and execution. Test each deployed model/runtime/parser/template combination; “OpenAI-compatible” does not mean every field or capability is supported.
- Enforce workspace data policy before model selection. `local-only` cannot silently fall back to OpenRouter or other cloud inference. Separate customer-owned execution from managed inference and document where plaintext is processed.
- Model output, repository files, retrieved documents and MCP descriptions are untrusted inputs, not authorization. Validate tools, enforce principal/project/repository scope, and apply the authorized action policy.
- Git worktrees isolate edits, not host execution. Apply the execution/trust policy to prechecks as well as agent commands. Untrusted hosted code needs a tested isolation boundary, bounded resources and scoped credentials.
- Automatic gateway prechecks default to disabled (`GatewayConfig::pregate_enabled = false`). Supplying a repository path does not authorize code execution. Keep checks on the supervisor-approved `run` path unless an embedding explicitly enables prechecks for a trusted execution environment.
- Preserve human review where the product requires it. Do not expand execution privileges or expose the loopback API merely to make a test/onboarding flow pass.
- Command approvals may be delegated through the `AutoApprove` level (`off` default, `low`, `medium`) per session or as a repository default (the session's own row wins), set only from a phone or the web app and recorded as `decided_via = auto_policy`. Destructive commands and change-set review are never auto-approved, and no setting may add that. Every path that raises an approval goes through `AppState::raise_approval` so the level applies uniformly (user direction, 2026-10-26).
- Make long-running work resumable through persisted transitions/checkpoints, leases and idempotency when implemented. Do not promise exactly-once external side effects; handle retries/reconciliation explicitly.
- Treat model/base revision, adapter hash, tokenizer/template, parser, quantization and runtime as a versioned deployment. Promote changes only with held-out workflow evaluation and a rollback path.
- Track dataset source, revision, license/permission, teacher lineage where known and preprocessing. Customer data needs explicit permission before shared training; segregate tenants and prevent evaluation leakage.
- Keep secrets, model weights, customer databases, private traces and datasets out of Git and routine logs. Use synthetic/redacted fixtures. Record provider spend separately from local compute and capacity costs.
- Preserve existing crypto/interoperability guarantees; prefer maintained cryptographic primitives and libraries. Do not invent new crypto or weaken transport security for convenience.

## Verification and completion

Run checks appropriate to the changed behavior. Add regression coverage for bugs and important boundaries, not tests that mirror implementation. Docs-only changes need link/command consistency checks, not an automatic full application test run.

Existing commands, run from the repository root:

```sh
pnpm install --frozen-lockfile
pnpm -r typecheck
pnpm -r test
pnpm --filter @farhelm/web build
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

- Start with the affected package/crate. Examples: `pnpm --filter @farhelm/web test`, `pnpm --filter @farhelm/client-core test`, `cargo test -p farhelm-agent`, or `cargo test -p farhelm-runner --test agent_task`.
- Build the web frontend before full desktop/workspace verification. `./check.sh` is the current broad local check entry point; it also invokes tooling through `npx` and may need network/toolchain access. Inspect its commands when changing tooling.
- Wire/crypto changes require Rust/TypeScript fixtures and the Swift fixture checks where affected: `cargo test -p farhelm-proto --test wire_fixture`, `cargo test -p farhelm-crypto --test interop`, and `swift test --package-path mobile/watch`.
- Browser/native/package behavior needs the relevant rendered, packaged, simulator or device evidence. Current web Vitest discovery matches `.test.ts`; include `.test.tsx` when introducing component tests. Typechecking is not a native build or visual test.
- Keep paid/live-provider tests opt-in; use deterministic fixtures for ordinary CI and a separate real-model conformance/evaluation path. Report skipped or unavailable checks clearly.
- Model smoke checks use `cargo test -p farhelm-gateway --example model_conformance` for offline fixtures. Live probes require explicit configuration and `--run` (also `--allow-cloud` for cloud entries); follow [the evaluation guide](docs/model-evaluation.md). A smoke-test pass is not held-out workflow certification.
- The live site (`farhelm.aurovie.com`) serves this checkout's `web/dist` directly. While working on the web app, keep `./deploy/live-web.sh` running so each passing build goes live as you go (user direction, 2026-10-26). It swaps a build in only after typecheck and both builds pass. Never build straight into `web/dist` while the site is serving it.
- Before finishing, inspect the diff for unintended changes, generated artifacts and secrets. Report what changed, why, verification and remaining limitations. Do not claim a proposed dependency, benchmark or missing release gate has been implemented.

## Durable user direction recorded 2026-10-22

1. Build the combined AI/workflow/workspace platform around local models and specialization, with optional OpenRouter/free-provider support.
2. Research developer-familiar technologies and establish consistent implementation patterns; keep these instructions current as the user directs the work or the goals evolve.
3. Redesign directory/architecture boundaries when needed for future developer maintainability; the current layout is not immutable.
