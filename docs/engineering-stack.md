# Engineering stack and implementation guide

Stack research reviewed October 22, 2026; implementation status updated October 25, 2026. [AGENTS.md](../AGENTS.md) contains the operative project instructions. This document explains the stack choices, ownership and migration patterns. The [earlier platform review](platform-review-2026-10-22.md) contains the product roadmap and code findings; it is a dated assessment, not proof those issues are fixed.

## Decision and evidence

Use the working Rust core and a familiar React/TypeScript interface, with Python at the model/training boundary and Postgres for future shared hosted data. Prefer an incremental modular application over a framework rewrite. This is the active engineering baseline; it does not mean every planned library has been installed.

The user authorizes architecture/directory improvements for long-term maintainability. Selection criteria are developer familiarity, clear ownership, maintenance/license health, runtime compatibility, testability and operational cost. Popularity supports an ecosystem decision but cannot prove suitability.

The [2026 Stack Overflow survey](https://survey.stackoverflow.co/2026/technology) documents broad use of TypeScript, Python, React and Postgres, alongside a smaller Rust ecosystem. Its [methodology](https://survey.stackoverflow.co/2026/methodology) describes respondent recruitment and coverage; it is not a census or a hiring-market forecast. Retaining Farhelm's working Rust code is a project-specific decision, not a claim Rust is the most popular backend language.

## Stack by status

| Responsibility | Current implementation | Preferred next choice / adoption trigger |
|---|---|---|
| Core/server | Rust 2024, Tokio, Axum, tower-http, Serde, reqwest | Retain. Use current lockfiles/MSRV; isolate provider and storage details behind existing boundaries. |
| Local file/process boundaries | cap-std/cap-fs-ext directory capabilities; shared farhelm-process using process-wrap | Adopted for no-follow file tools and bounded command lifetimes. Separate hosted sandbox work is still required. |
| Local persistence | rusqlite/SQLite; local runner and current cloud persistence | Retain locally. Add Postgres + compatible SQLx for shared hosted entities when implementing that service. |
| Projects | Scoped metadata, registered repository attachment, atomic project-owned task creation/history and review/apply/retry/revert; direct runner HTTP and web UI | [Local workflow](local-projects.md) implemented. Relay access, hosted principal authorization, project budgets and conversation/document APIs remain pending. |
| Web | React, strict TypeScript, Vite, plain CSS tokens, static PWA | Retain. No need for Next.js/SSR solely to add an AI workspace. |
| Desktop/mobile | Tauri 2; Expo/React Native; Swift watch | Retain. Keep web/desktop primary and native companions functional as the product expands. |
| Client transport | Shared client-core; HTTP/events and encrypted WebSocket relay | Retain one transport abstraction; fix capability/enrollment mismatches rather than bypassing it. |
| Server-state UI | Custom resource hooks and event invalidation | TanStack Query is preferred when cross-view cache, pagination or selective invalidation justify it; migrate by feature. Not installed. |
| Runtime validation | Serde on Rust boundaries; TypeScript contracts and wire fixtures | Add generated/derived boundary validation. Zod is a candidate for client/config validation, not a second independent contract. Not installed. |
| Contract generation | Rust DTOs plus manually mirrored TS and committed fixtures | Start with ts-rs for Rust↔TS DTO generation; evaluate utoipa for HTTP/OpenAPI and schemars for tool/config schema needs. Not installed as direct project tooling. |
| Local model development | Existing Conscious Messages integration plus configured non-streaming Chat Completions for local endpoints and optional OpenRouter | Ollama is the initial convenience default; llama.cpp/vLLM need deployment conformance testing. See [model provider setup](model-providers.md); no model server is a bundled application dependency. |
| Shared inference | No native shared GPU serving layer in this repository | vLLM first candidate, with pinned deployment/conformance tests. SGLang is an alternative if measured workloads justify it. |
| Training/data | No Python training service | Python + uv + PEFT/QLoRA + Axolotl; Ruff/pytest. Introduce only with a concrete experiment. |
| Observability | Existing ad hoc process output and gateway traces | Direct `tracing`/subscriber instrumentation first; opt-in OpenTelemetry export and self-hosted model tracing when useful. A transitive lockfile entry is not an adopted telemetry stack. |
| Tests | Rust tests; Vitest; cross-language wire/crypto fixtures; Swift package tests | Add Testing Library/user-event for components and Playwright for critical seeded browser flows. Not installed. |
| Formatting/linting | Rustfmt/Clippy and strict TypeScript checks; no direct client ESLint/Prettier setup | Add compatible ESLint + React Hooks rules and Prettier in a focused tooling change. Do not combine mass formatting with a feature. |
| Jobs/workflows | Detached native-agent tasks; persisted task/review rows | Explicit database run/step state and leases first. Temporal remains an evaluated option, not a mandatory initial service. |
| Deployment | Existing service scripts, systemd/launchd, Cloudflare configuration | Preserve until changed deliberately. Add reproducible container builds for hosted workloads; no Kubernetes requirement for the first pilot. |

Status must be updated when implementation changes. Evaluate a dependency's actual released version, features and license before adoption. The Rust manifest currently declares MSRV 1.90; upstream SQLx main currently requires a newer compiler. Select a compatible released version or make the toolchain upgrade an explicit change, rather than copying a “latest” install command. See [SQLx](https://github.com/launchbadge/sqlx) and the [Rust manifest MSRV reference](https://doc.rust-lang.org/cargo/reference/rust-version.html).

## Current directory contract

```text
farhelm/
  AGENTS.md                 living instructions
  Cargo.toml / Cargo.lock   Rust workspace and locked graph
  package.json              shared client commands
  pnpm-workspace.yaml       JavaScript workspace membership
  pnpm-lock.yaml             locked client dependencies
  crates/
    farhelm-proto/          shared wire shapes and compatibility
    farhelm-domain/         pure rules/state transitions
    farhelm-app/            use cases and narrow ports
    farhelm-sqlite/         local persistence and migrations
    farhelm-gateway/        inference policy and provider adapters
    farhelm-agent/          agent planning/tool execution behavior
    farhelm-runner/         machine-level composition and API
    farhelm-cloud/          current account/workspace control plane
    farhelm-relay/          encrypted transport fan-out
    farhelm-crypto/         identities/envelopes/security primitives
    farhelm-mcp/            MCP protocol/OAuth integration
  packages/client-core/     cross-platform client logic
  web/                      PWA and browser adapters
  desktop/src-tauri/         native desktop host
  mobile/                   Expo client and native adapters
    watch/                  Swift watch implementation
  deploy/                   deployment configuration/scripts
  docs/                     architecture, research and decisions
```

Do not rename working roots just to make the diagram more conventional. If more applications make grouping valuable, a coordinated migration to `apps/{web,mobile,desktop}` is allowed. Keep Cargo libraries in `crates/`, shared JavaScript in `packages/`, and introduce a `services/` directory only for independently runnable components that actually exist. Python training could then live in `services/training/` with `pyproject.toml`, `uv.lock`, a `src/` package and tests. A configured vLLM deployment does not need a new custom model-server application.

Inside an expanding web client, prefer feature ownership:

```text
web/src/
  app/                      composition, route/session providers
  features/<feature>/       feature screens, actions, data hooks, tests
  components/ui/            genuinely shared presentation primitives
  platform/                 browser storage/events/notification adapters
```

This is a target pattern when extracting/changing code, not a list of folders to create now. Features can include chat, projects, tasks or models as they are implemented. Share platform-neutral transformations through client-core; do not force browser and native visual components into a shared UI package.

A move is complete only when workspace paths, Rust path dependencies, imports, Tauri build/assets, Metro/Expo/native configuration, service-worker paths, CI/scripts and developer docs agree. Test from a clean checkout/build and, for packaged desktop changes, outside the repository working directory. Remove the old path or document a short-lived compatibility boundary and removal condition.

## Backend patterns

Use ports and adapters at real boundaries. Keep deterministic policy in domain functions, operations in application use cases, SQL in storage adapters, provider wire formats in the gateway, and composition at executable/service boundaries. Shared process lifecycle belongs in `farhelm-process`. Avoid abstract factories, one-class-per-operation boilerplate or a generic repository wrapper that hides important queries.

A new operation should make this sequence visible:

1. Decode and validate bounded input.
2. Resolve the authenticated principal and project/resource capabilities.
3. Execute the use case with narrow dependencies.
4. Persist atomic changes and the durable work reference where needed.
5. Return a typed result and publish/invalidate the relevant view.

Use consistent machine-readable error codes, safe user messages and a request/run identifier. Do not return raw secrets/provider request bodies. Keep service errors separate from transport-specific status mapping. Typed enums are appropriate for behavior clients must handle; a general-purpose error wrapper belongs only at boundaries where callers cannot recover by variant.

[Axum](https://docs.rs/axum/latest/axum/) supplies handlers/extractors/middleware and integrates with the [Tokio](https://tokio.rs/tokio/tutorial) runtime. Keep blocking operations off Tokio worker threads with bounded blocking work. A timeout must include an explicit process lifecycle for shell workers; it is not enough to stop awaiting a result.

Current Store traits are synchronous. Preserve that fact when designing Postgres support: async network storage needs an explicit async application/storage boundary or another reviewed design. Do not hide network waits inside synchronous methods with nested runtimes or `block_on`.

Use parameterized SQL, indexes for real access patterns, transactions and uniqueness constraints for invariants, and additive migrations. For a multi-step operation, commit its state/intent before a worker performs external work; use an outbox when durable event delivery is required. This is not an instruction to add an event bus now.

For jobs, persist run/step IDs, ownership lease and expiry, state, attempt, input/artifact references and cancellation. A crashed worker must not leave an eternal “running” task. External calls can have uncertain outcomes: use idempotency keys when supported and reconciliation otherwise. Avoid pretending a database lease guarantees exactly-once actions. Start with database coordination; [Temporal](https://docs.temporal.io/) becomes useful when durable waits, scheduling and orchestration outgrow that design.

Add [tracing](https://docs.rs/tracing/latest/tracing/) spans for request/run/step/provider and useful duration/result fields. Avoid high-cardinality customer content in metrics. Keep prompt/code/body capture disabled unless explicitly configured with a suitable data policy. [OpenTelemetry](https://opentelemetry.io/docs/concepts/semantic-conventions/) provides a vendor-neutral naming/export direction; it does not require running another hosted product.

## Contracts and interfaces

Rust wire types are the current authority. Address existing TypeScript duplication incrementally with [ts-rs](https://docs.rs/ts-rs/latest/ts_rs/). Keep generation concerns optional/build-time where appropriate so protocol and domain crates remain free of HTTP/storage implementation dependencies. Generated code should have a documented command and a CI drift check once generation is implemented.

[utoipa](https://docs.rs/utoipa/latest/utoipa/) can describe HTTP/OpenAPI surfaces, while [schemars](https://docs.rs/schemars/latest/schemars/) can derive JSON Schemas for typed tool/config arguments. Adopt only the tool needed for the current boundary. Do not create three manually maintained definitions of the same shape, and do not introduce multiple TypeScript generators for the same DTOs. Preserve serde names, enum tagging and optional/null semantics in generated contracts.

Generated types are not runtime validation. Validate external HTTP, relay, configuration and tool payloads once at their entry boundary; clients may use [Zod](https://zod.dev/basics) or a generated-schema validator. Preserve the cross-language fixtures and compatibility/version tests. Keep deprecated fields/protocol behavior compatible until a documented migration removes them.

Continue REST/JSON for ordinary operations, event streaming for incremental output and the existing encrypted relay transport. Add sequence/run/resource IDs and bounded replay where necessary. Do not introduce GraphQL/gRPC merely to expand the feature set.

## Frontend patterns

Use the [React component/data-flow model](https://react.dev/learn/thinking-in-react), the current [Vite build](https://vite.dev/guide/) and [strict TypeScript](https://www.typescriptlang.org/tsconfig/strict.html). Treat props/state as snapshots, avoid duplicate derived state, and use effects for external synchronization with cleanup. Components should not instantiate their own independent auth/provider/transport layer.

When standardizing client tooling, use a compatible [ESLint configuration](https://eslint.org/docs/latest/use/configure/configuration-files) and [React Hooks rules](https://react.dev/reference/eslint-plugin-react-hooks) for correctness, with [Prettier](https://prettier.io/docs/integrating-with-linters) owning formatting. Disable conflicting stylistic rules. Check parser/TypeScript/Expo compatibility before adoption, document package scripts and editor use, and keep the initial mechanical reformat in a separate change.

Local fields and disclosures belong in component state; focused shared preferences can use context; remote data belongs in resource/query code. Introduce [TanStack Query](https://tanstack.com/query/latest/docs/framework/react/guides/important-defaults) when its caching/invalidation benefits are real. Configure freshness, refocus and retry intentionally: defaults are not Farhelm's product policy. Resource keys include tenant/runner/resource identity. Do not persist decrypted caches by default.

Transport events should update/invalidate the relevant resource rather than refetch all screens on every token. Streaming text/tool output needs sequence-aware accumulation and bounded retention. Approval/start/apply/revert/payment actions require duplicate-submit protection and explicit result states; automatic mutation retries need deliberate backend idempotency.

Keep token CSS and platform themes. Use native buttons/links/inputs first and test keyboard/focus behavior for custom controls. [W3C's ARIA guidance](https://www.w3.org/WAI/ARIA/apg/practices/read-me-first/) explains that custom roles require the corresponding behavior; adding an attribute is not an accessibility implementation.

Extract feature code when ownership becomes unclear, not at an arbitrary line count. Keep web and native dependency versions compatible with their own platforms; Expo's supported React version need not match the web app.

## Model and connector patterns

The initial provider increment keeps Conscious and Anthropic environment configuration working, adds typed text/tool history in gateway `prompt.rs`/`dispatch.rs`, and introduces an explicit configured registry with non-streaming Chat Completions transport. [Model provider setup](model-providers.md) documents the current operator-wide `local_only`/`cloud_allowed` policy, model aliases, output limits and token rates. The configured route never silently falls back to a legacy/cloud provider. Persisted workspace policy, streaming, multimodal content, opaque reasoning replay, compute telemetry and training administration remain future work.

Preserve tool IDs, matching results, content parts and actual provider/model/adapter usage when extending the contract. Assemble and validate complete streamed calls before any action when streaming is implemented. Operator-declared local endpoints are trusted deployments, not proof of network isolation; a local server can proxy to remote inference. No-follow file tools and bounded process groups likewise do not sandbox commands.

[Ollama documents partial OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility). [vLLM tool calling](https://docs.vllm.ai/en/stable/features/tool_calling/) depends on model/parser/template support. Maintain conformance fixtures for each pinned deployment rather than keeping a permanent “latest” CLI recipe in AGENTS.md. The [model evaluation guide](model-evaluation.md) separates deterministic fixtures, the explicit opt-in synthetic smoke probe and held-out release evaluation, with deployment identity records and operational limits. Unsupported capabilities must fail clearly or follow an explicitly allowed compatible route.

Farhelm owns permissions, privacy policy, budgets and workflow semantics. Serving engines and MCP do not replace those controls. Use a supported [MCP protocol](https://modelcontextprotocol.io/specification/2025-11-25/server/tools) and maintain the existing transport/auth guarantees; server-provided annotations/descriptions cannot grant privileges.

[PEFT checkpoints](https://huggingface.co/docs/peft/developer_guides/checkpoint) reference a base model; version the base, adapter, tokenizer, parser, quantization and runtime together. Train separately using reproducible [Axolotl configurations](https://docs.axolotl.ai/docs/getting-started.html), and protect [vLLM adapter administration](https://docs.vllm.ai/en/stable/features/lora/) from untrusted inputs. Record dataset permissions/provenance and compare base/prompt/RAG/tuned variants on held-out tasks before promotion. Large datasets and weights belong in artifact storage, not the repository.

## Verification and delivery conventions

Use risk-based verification: pure rules and transformations in fast unit tests, storage/transport/provider boundaries in integration tests, and critical user journeys in rendered/browser/package tests. Mock external services as appropriate, but do not mock away every boundary the feature depends on.

Keep Vitest; add [Testing Library](https://testing-library.com/docs/guiding-principles/) when implementing a meaningful rendered component test, including `.test.tsx` discovery. Use [Playwright](https://playwright.dev/docs/best-practices) for seeded real-runner flows with role-based locators, isolated data and useful failure traces. Simulator/native package checks are separate from browser tests. Run live-model evaluation separately from deterministic CI.

Use the root commands in AGENTS.md. Check a minimal supported toolchain and locked dependencies in CI before accepting upgrades. A clean static web build must include the service worker; a desktop build must contain and serve its assets without relying on source-tree CWD. Document tooling failures/skips rather than calling the result “all green.”

When adding hosted containers, follow [Docker's build guidance](https://docs.docker.com/build/building/best-practices/): small multi-stage runtime images, appropriate non-root execution, pinned/reproducible inputs and no build secrets in images. Containers alone are not a proven security boundary for untrusted customer code; choose/test the hosted isolation mechanism separately. [uv](https://docs.astral.sh/uv/concepts/projects/layout/) and [Ruff](https://docs.astral.sh/ruff/) are the preferred project/dependency and lint/format conventions if Python work is introduced.

## How this guide evolves

Record a material decision with: context/problem, status, chosen approach, alternatives, compatibility/data/security consequences, rollout/rollback, and evidence that would justify revisiting it. Link focused ADRs here as they are created. Do not turn old research into an immutable requirement or update a document to claim work that has not happened.

Initial decisions recorded 2026-10-22:

- Retain the existing Rust/React/platform foundation and package managers.
- Permit directory redesign; keep working roots until a coordinated move has a concrete benefit.
- Use feature ownership, ports/adapters and a modular application as the implementation pattern.
- Mark new libraries/services as planned until their integration and verification exist.
- Keep the broad AI/workflow vision while delivering measurable complete workflows incrementally.

Implemented decision: [0001: local execution boundaries](adr/0001-local-execution-boundaries.md), 2026-10-23. Automatic gateway prechecks now default to disabled; file tools reject symlinks; command capture/cleanup is shared; desktop serves compiled frontend assets. Hosted sandboxing and scoped shared-runner authorization remain future release gates.

Architecture direction and implementation status reviewed October 25, 2026; acceptance of a design does not mean it is implemented:

- [Farhelm System Architecture Specification](system-architecture.md): target commercial AI workspace, with current-versus-planned boundaries called out.
- [0002: unified workspace object model](adr/0002-unified-workspace-object-model.md): project/conversation/document DTOs, SQLite containment and same-workspace links implemented. ADRs 0007/0008 deliver local project resources and registered repository/run associations; conversation/document APIs and hosted workspace scope remain pending.
- [0003: provider-neutral inference layer](adr/0003-provider-neutral-inference-layer.md): broader model protocol, deployment policy and separate compute economics; the first subset is ADR 0006.
- [0004: durable task execution and recovery](adr/0004-durable-task-execution-and-recovery.md): first form implemented; the task's branch is persisted before the loop starts, tool exchanges are recorded in a `task_step` ledger (`GET /v1/tasks/{id}/steps`), and a restart preserves interrupted edits as a change set awaiting review. Leases, fencing, per-step Git checkpoints and automatic resumption remain pending; nothing is re-executed on restart.
- [0005: scoped principal authorization](adr/0005-scoped-principal-authorization.md): pure resource-grant and role checks implemented; verified grant resolution and enforcement across execution surfaces remain pending. Hosted command isolation is a separate unimplemented boundary.
- [0006: configurable model providers](adr/0006-configurable-model-providers.md): implemented initial registry, text/tool Chat Completions adapter, explicit local/cloud routing policy and configured token cost estimates. [Provider setup](model-providers.md) records operational limits and examples.
- [0007: local project metadata API](adr/0007-local-project-api.md): implemented stable database-owned local scope, scoped create/list/detail, bounded blocking execution and local web transport. Existing workspace rows retain their scopes; ADR 0008 extends it with repository/task associations; shared-runner authorization remains pending. [Local Projects](local-projects.md) documents the contract and rollout.


- [0008: project-owned local agent runs](adr/0008-project-agent-workflow.md): implemented many-to-many repository attachment, immutable run ownership, atomic session/task/provenance writes and scoped task controls. Existing legacy tasks remain unassigned. [Account sign-in](account-sign-in.md) also documents distinct local runner/account service endpoints and recoverable upstream failures.
- [0009: local specialists and work modes](adr/0009-specialists-and-modes.md): proposed. Ask, Plan, Agent and Review modes fix the tools; versioned specialists (base model plus adapter, prompt and evaluation) are chosen by mode and task type, promoted only on held-out evaluation, and never fall back to cloud under `local_only`.
- [0010: API clients through the runner's front door](adr/0010-api-clients-front-door.md): implemented. Other projects call models at `/p/<client>/v1` with their own key, allowed models and daily token limit; every call goes through the gateway, is recorded under `client-<name>` and caches separately per client.
- [0011: Farhelm as the model hub for every project](adr/0011-model-hub.md): accepted direction. Farhelm holds, serves, records and improves the models of all the owner's projects; promotion is per project and evaluation-gated, and training data needs each project's permission.
