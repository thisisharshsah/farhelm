# 0006 — Configurable model providers: initial implementation

Status: implemented increment, 2026-10-23. This narrows the rollout of [0003 — provider-neutral inference](0003-provider-neutral-inference-layer.md); it does not claim that ADR's full hosted registry, multimodal, streaming or compute-metering target exists.

## Context

The working Conscious/Anthropic adapter uses Messages requests. Ollama, vLLM and llama.cpp deployments commonly expose Chat Completions with different tool history and usage shapes. Sending those requests through a Messages-only client loses interoperability. Pricing every response through the Anthropic table also cannot account for explicitly configured third-party rates. A local-only deployment must reject cloud selection before network activity.

## Decision

Keep the gateway's narrow `ModelClient` boundary and existing legacy adapter. Add an explicit startup TOML registry selected by `FARHELM_MODELS_CONFIG`, with named providers, upstream models, output/tool capabilities, three task routes and a runner-wide local/cloud policy. Unknown fields, invalid references, missing credentials and invalid prices are errors. Selecting a bad file never activates the legacy provider instead.

Normalize structured tool calls/results in the gateway conversation types and preserve existing text-only behavior. The Chat Completions adapter handles complete non-streaming responses, validates usage and arguments, and does not parse executable tool calls from prose. Streaming/multimodal and opaque reasoning state need later contract work; existing wire DTOs are not migrated solely to meet a target directory diagram.

Enforce policy through the registry on model lookup and dispatch, including direct Messages/compaction calls. Configured clients disable redirects and ambient proxies. Local entries require loopback/private-address endpoints; non-loopback connections require HTTPS. Locality is an operator trust declaration: the server must also be configured against cloud forwarding. Known cloud model tags are rejected. Hosted network isolation remains independent.

Separate configured per-category token rates from Anthropic's pricing table and cache multipliers. Local token charges remain zero with compute costs explicitly unmeasured. The ledger records qualified actual upstream identities and the applicable configured estimate at call time. Fingerprint configuration plus credential digests for response-cache separation. Configured providers do not use the Anthropic batch queue or flusher.

OpenRouter is an explicit cloud provider, with required credential source and prices (including explicit zeros for free tiers). Send one model with provider fallbacks disabled and parameter support required. No automatic cross-model/provider fallback is introduced. OpenRouter's initial upstream selection, account privacy and billing remain operator responsibilities until more controls are implemented.

## Consequences and migration

Existing `CONSCIOUS_*` and Anthropic configuration keeps working when no file is selected. Operators opt into the registry, restart, and can roll back by unsetting the variable and restarting with the legacy configuration. No schema migration changes historical usage rows. No Python/backend framework, serving binary, training service or new queue is added. The new direct dependency is the already-used TOML 0.9 parser with parse/serde features.

The initial file is administrator-owned configuration, not a public model administration API. It is not hot-reloaded and does not expose adapter loading. Tool history preservation takes precedence over compaction: tool-bearing turns conservatively skip summarization for now. This reduces context headroom until pair-aware compaction is implemented.

Deterministic tests verify serialization, bounded responses, usage accounting, route resolution, capability limits, cache separation and local-only rejection with local HTTP fixtures. Live model/runtime certification and hosted tenant/egress controls remain release gates. See [operator instructions](../model-providers.md) for configuration and supported behavior, and [Ollama compatibility](https://docs.ollama.com/api/openai-compatibility), [Ollama cloud controls](https://docs.ollama.com/faq#how-do-i-disable-ollamas-cloud-features), [vLLM tool calling](https://docs.vllm.ai/en/stable/features/tool_calling/) and [OpenRouter routing](https://openrouter.ai/docs/guides/routing/provider-selection) for upstream constraints.
