# 0003: Provider-Neutral Inference Layer and Model Registry

**Status**: Accepted direction; initial subset implemented in [ADR 0006](0006-configurable-model-providers.md), October 23, 2026.  
**Consulted**: [AGENTS.md](../../AGENTS.md), [Engineering Stack](../engineering-stack.md), [Platform Review](../platform-review-2026-10-22.md)

---

## Context

Farhelm's gateway (`crates/farhelm-gateway`) initially interfaced exclusively with an Anthropic Messages-compatible wire API (`AnthropicClient` targeting `/v1/messages`). While functional with Conscious and Anthropic, this creates critical architectural constraints:
1. **Local Model Incompatibility**: Leading local inference servers (Ollama, llama.cpp, vLLM) primarily expose OpenAI-compatible `/v1/chat/completions` endpoints with specialized tool calling schemas.
2. **Data Policy**: The legacy environment configuration did not supply a persisted workspace data policy. A provider's name or a loopback URL alone cannot prove inference stays local.
3. **Inaccurate Economics**: Token costs for local models were hardcoded to `$0.00`, obscuring real hardware utilization, compute seconds, and GPU memory footprints.
4. **Tool Call Fragmentation**: Different runtimes stream tool arguments and tool calls differently (e.g. Anthropic `tool_use` blocks vs OpenAI `tool_calls` chunks).

---

## Decision

Retain the existing `dispatch::ModelClient` port and normalize text/tool conversations in the gateway, then add provider registry policy and adapters behind that boundary. [ADR 0006](0006-configurable-model-providers.md) records the implemented initial subset and [model provider setup](../model-providers.md) documents its configuration. The broader multimodal, streaming, per-workspace and compute-metering design below remains future work.

### 1. Provider-Neutral Protocol

Current `prompt.rs` contains `Turn`, `ContentBlock` and `ToolResult`; `dispatch.rs` contains `ModelRequest`, `ModelResponse` and `ToolCall`. These preserve typed tool call identities, JSON inputs, matching results and error status. There is no `farhelm-proto/src/model.rs` module today. The following richer public types are conceptual candidates when implemented consumers need them:
- `ChatMessage`: `role` (`System`, `User`, `Assistant`, `Tool`), `content: Vec<ContentPart>`.
- `ContentPart`: `Text`, `Image`, `ToolCall`, `ToolResult`.
- `ToolCall`: `id`, `name`, `arguments_json`.
- `ToolResult`: `tool_call_id`, `content`, `is_error`.
- `ModelUsageReport`: records `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `provider_cost_usd`, and `compute_duration_ms`.

### 2. Multi-Backend Adapter Architecture

The implemented boundary remains `ModelClient`, not a second `ModelProvider` trait. The initial configured client supports non-streaming Chat Completions and retains the legacy Messages client when no registry is selected. Longer-term adapter responsibilities are:
1. **`OpenAICompatibleAdapter`**:
   - Targets **Ollama** (`http://127.0.0.1:11434/v1`), **llama.cpp `server`**, and **vLLM** (`http://127.0.0.1:8000/v1`).
   - Initial `OpenAiClient` translates typed tool calls/results into Chat Completions, requires complete JSON arguments and rejects unsupported media/reasoning replay. Streaming accumulation is future work.
   - A configured vLLM model ID can identify a pre-served adapter. Dynamic adapter loading/administration, parser selection and deployment evaluation are not implemented Farhelm features.
2. **`AnthropicAdapter`**:
   - Existing `AnthropicClient` supports the legacy Anthropic and Conscious Messages-compatible paths without changing their existing environment setup.
   - Formats requests to `/v1/messages`, handling cache breakpoints and system prompt blocks.
3. **`OpenRouterAdapter`**:
   - Initial `OpenAiClient` targets OpenRouter with an explicit model, `allow_fallbacks=false` and `require_parameters=true`; it never silently substitutes a remote route for a local one.
   - Explicit configured token rates feed the gateway ledger. Free tiers need authorization and are not guaranteed capacity. Provider pinning, persisted workspace budgets and broader routing controls require their own implemented semantics.

### 3. Data Sovereignty Enforcement

A future persisted workspace policy must be checked before selecting a provider. The initial registry has a gateway-wide operator policy (`local_only` or `cloud_allowed`), applied to gateway inference paths including summarization. It does not implement the complete three-mode workspace model below:
- **`local_only`**:
  Rejects configured cloud routes and fails closed when a selected model/provider is unavailable or incapable. Local URL validation and redirect/proxy restrictions support that decision, but runtime locality still depends on the operator's trusted deployment. A local server can itself proxy to cloud inference; configuration validation is not an egress sandbox.
- **`hybrid`**:
  Future option: prefers local models and allows explicitly authorized cloud tasks under a defined redaction policy. Redaction is not currently implemented and cannot be assumed to remove all sensitive content.
- **`cloud_permitted`**:
  Future workspace option: permits configured cloud models within resource authorization and budget. The initial config calls its operator-wide opt-in `cloud_allowed`.

### 4. Split Cost Accounting

The initial ledger records actual token counts and a token cost estimate using configured rates (zero API token fees for local inference), with provider-qualified actual model identity. This is not a provider invoice. It does not yet record `compute_duration_ms`, GPU allocation or a separate `active_adapter` hash. Add those metrics as distinct measurements, with base model/adapter/runtime provenance rather than confusing request wall time with GPU compute consumed.

---

## Consequences and Limits

- **Tool Protocol Conformance**: Different open-weight models vary in reliability. The new Chat Completions adapter rejects malformed tool arguments/identities before execution; it does not implement automatic repair prompts. Test each deployed model/runtime/parser/template combination. Tool-bearing history currently bypasses compaction rather than risk splitting a call/result exchange.
- **Context Limits**: Local models often have shorter effective context windows than commercial frontier models. The gateway's existing compaction and caching stages become essential for local models.
- **Stream Buffering**: Streaming tool calls require complete accumulation of argument chunks before tool execution begins.

---

## Verification and Follow-Up

- Keep deterministic transport, policy and accounting regression tests for the initial `ModelClient` adapters; real model conformance remains opt-in.
- Pin and test Ollama/vLLM model/parser/template combinations before declaring deployment support.
- Add persisted workspace policy and verify all inference entry points; separately test hosted egress containment before claiming network isolation.
- Add streaming/multimodal or reasoning replay only with full content preservation and validated tool accumulation.
- Add separate compute/capacity telemetry and versioned adapter provenance; do not report missing fields as measured data.
