# Configuring model providers

Farhelm can route the small, large and frontier slots to explicitly configured local or cloud models. The initial registry supports non-streaming text Chat Completions and function tools through Ollama, compatible llama.cpp/vLLM deployments, and OpenRouter. Compatibility and tool quality must be evaluated for the deployed model, parser and template. This does not add vision/audio, fine-tuning, automatic provider discovery, runtime installation or live-model certification.

## Local development

Install and run your chosen serving runtime separately. Make sure the model in your configuration is available there. Copy [the example configuration](../config/models.local.example.toml) into your operator configuration directory, update the model identifier and limits, and point the runner at its absolute path:

```sh
export FARHELM_MODELS_CONFIG="/absolute/path/models.toml"
cargo run -p farhelm-runner -- serve
```

Launch desktop with the same environment when using the packaged desktop host. A GUI process launched separately may not inherit your shell exports; configure its launch environment explicitly. Configuration is loaded at startup; restart after changing it. The registry fails closed when the selected file is missing, malformed, has an unsupported version or references missing credentials. It does not switch back to an older environment configuration on errors.

Without `FARHELM_MODELS_CONFIG`, the Anthropic environment and stored-credential paths remain available with their existing behavior. The configuration-file policy described here applies to the explicitly selected registry, not to an unconfigured legacy client.

## The Farhelm engine

The runner can own its model servers instead of relying on one installed by hand. `farhelm engine install` installs a pinned llama.cpp server build after checking the SHA-256 GitHub publishes for it; `add-model` links a GGUF model into `models/`, hashes it and gives it its own port; `engine.toml` beside the runner's other state records all of it:

```sh
farhelm engine install --model /path/to/coder.gguf --alias qwen3-coder-30b
farhelm engine add-model --model /path/to/gpt-oss-20b.gguf --alias gpt-oss-20b --ctx-size 16384
farhelm engine status
```

`--from <archive>` installs from an archive you already downloaded; it is checked against the same pin. `serve` starts one server per model (the first on `127.0.0.1:7846`, then the next free ports) with the model's own chat template (`--jinja`), waits for `/health`, restarts each with backoff (2 s doubling to a minute) when it exits, and stops them all on Ctrl-C. A service restart (SIGTERM from launchd or systemd) leaves them serving instead: each `engine-<alias>.pid` records the server's pid and a fingerprint of its exact command, and the next runner adopts a server whose fingerprint matches and that answers, so projects calling the models see no gap. A server with another fingerprint, or one that stops answering, is replaced; another process on a model's port is refused rather than mistaken for it. `farhelm engine stop` stops servers a runner left behind. Output goes to `logs/engine-<alias>.log`, cut at 16 MiB. Every configured model starts with the runner; nothing unloads an idle model yet, so the models must fit in memory together.

Requests still go through the gateway: point a registry provider at each model's port like any other local endpoint (`kind = "openai_compatible"`, `data_location = "local"`, and the model's alias). Only Apple Silicon has a pinned build so far (`b11624`); a new build is a new deployment and passes the conformance probe before it is pinned. A model file is checked by size on every start; its install-time hash is the deployment record.

### Adapters trained with MLX

`farhelm engine import-adapter --from <mlx-adapter-dir> --name <name>` converts an MLX-LM LoRA adapter (`adapter_config.json` and `adapters.safetensors`, F32) into the engine's GGUF adapter format under `adapters/`. Linear matrices are transposed, per-expert matrices are kept, and `alpha = scale * rank` so llama.cpp applies the same strength. gpt-oss and Qwen3.5 (`--arch qwen35`) are mapped; an adapter tensor with no counterpart in the base model is an error rather than being dropped. A Qwen3.5 import also needs `--base <the GGUF it will run on>`: llama.cpp's converter stores the linear-attention value heads tiled where MLX groups them by key head, so the adapter's value-head rows (`attn_qkv`'s value block, `attn_gate`, `ssm_alpha`, `ssm_beta`) and `ssm_out`'s inputs are reordered to match, using the head counts in the base model's metadata. The order was measured on Qwen3.5-4B: dequantized rows matched at 0.995 correlation under it and not without it. `farhelm engine add-adapter --to <model> --adapter <name>` loads it with that model's server, switched off, and prints its id.

### Models, adapters and aliases

A registry model keeps its maker's name and lists the adapters trained for it. A request selects one as `model:adapter`, which serves the adapter's current version; `model:adapter@vN` pins a version. The model's name alone uses no adapter:

```toml
[models.gpt-oss-20b]
provider = "engine-gpt-oss-20b"
model = "gpt-oss-20b"
tools = true
max_output_tokens = 8192

[models.gpt-oss-20b.adapters.fast]
current = 1
purpose = "reasoning with short thinking"
versions = [{ version = 1, lora_id = 0, evaluation = "..." }]

[aliases]
think = "gpt-oss-20b"
quick = "gpt-oss-20b:fast"
```

`lora_id` is the adapter's position among those the model's server loaded (`farhelm engine status` lists them); the gateway sends llama.cpp's `lora` field with it, and a request without an adapter sends none, so every adapter stays at scale 0. Lora ids are used once per model, scales run from 0 to 4, and only `openai_compatible` providers may declare adapters. An adapter may carry its own `chat_template_kwargs`, merged over the model's: Qwen3.5's `enable_thinking = false` for an adapter trained without thinking.

Aliases are purpose names projects ask for. Each points at a model, `model:adapter` or a pinned version, never at another alias, and never takes a model's name. Moving an alias changes what serves a purpose without any project changing its setting. The ledger records exactly what ran (`local/engine-gpt-oss-20b/gpt-oss-20b:fast@v1`), an alias shares the response cache of what it points at, and the front door reports a request made by alias as `... (as quick)`. `farhelm models` lists every model with its card, adapters, versions, aliases and routes. Names are the owner's to choose (AGENTS.md).

Quote a table name that contains a dot (`[models."qwen3.5-4b"]`, `[providers."engine-qwen3.5-4b"]`); unquoted, it is a nested table and the registry is invalid.

### Reasoning models and tool calls

Reasoning models such as gpt-oss write their analysis before a tool call and need it back on the next request. The OpenAI-compatible adapter keeps a plain `reasoning_content` string that comes with tool calls and returns it on the assistant message of the following request, where llama.cpp renders it into the model's analysis channel. A successful tool result is sent as the tool's plain output; a failed one as `{"content": ..., "is_error": true}`, since Chat Completions has no error flag. Structured reasoning (`reasoning_details`, OpenRouter's `reasoning`) still fails the request, since it needs exact replay this adapter does not do. Reasoning is not sent to Anthropic, whose thinking blocks need Anthropic's own signature.

## Other projects through Farhelm

Projects that call models directly can go through the runner instead, each as an API client with its own key ([ADR 0010](adr/0010-api-clients-front-door.md)):

```sh
farhelm clients add everest --default-model think --models think,quick --daily-tokens 2000000
```

`--default-effort low` keeps a reasoning model at the effort a request does not set, and `farhelm clients set <name>` changes any of these. The key is printed once. Point the project at `http://127.0.0.1:7842/p/everest/v1` (OpenAI style) or `http://127.0.0.1:7842/p/everest` (Anthropic style) and send the key as `Authorization: Bearer` or `x-api-key`. Restart the runner after adding, rotating or removing a client.

## Configuration contract

The TOML file has `version = 1`, a required `policy`, `routes`, `providers` and `models`. Unknown fields fail validation. Provider/model aliases use ASCII letters, digits, underscores, hyphens or periods; upstream model identifiers may include runtime-specific syntax such as `qwen3-coder:30b` or a deployed LoRA alias. No adapter upload/activation endpoint is exposed.

| Field | Meaning |
| --- | --- |
| `policy` | `local_only` permits local entries; `cloud_allowed` also permits explicitly selected cloud entries. Neither mode automatically falls back. |
| `routes.small`, `.large`, `.frontier` | Configured model aliases for the existing task router. Multiple slots can use one model. |
| `providers.<alias>.kind` | `openai_compatible` or `openrouter`. |
| `base_url` | Endpoint prefix ending in `/v1`; the adapter appends `/chat/completions`. OpenRouter uses `https://openrouter.ai/api/v1`. |
| `data_location` | Required operator declaration, `local` or `cloud`. OpenRouter requires `cloud`. |
| `api_key_env` | Optional environment variable name containing the bearer credential. Required for OpenRouter; if supplied anywhere, it must resolve to a nonblank valid HTTP credential. Keys themselves do not belong in TOML or Git. |
| `models.<alias>.provider`, `.model` | Provider alias and upstream model identifier. Requests cannot use undeclared aliases. |
| `tools` | Required capability declaration. False rejects tools and structured tool history before contacting the provider. |
| `max_output_tokens` | Required positive output ceiling; the requested output limit is clamped to this value. It does not establish tokenizer/context-window compatibility. |
| `pricing` | Required for cloud models, optional zero-only for local models. Rates are dollars per million tokens; see accounting below. |

Files are bounded to 1 MiB, provider/model counts to 256 each and aliases to 128 bytes. Explicit credentials are resolved once at startup. Rotating an environment value requires a restart. The provider alias `local` is reserved against use by cloud entries so cloud ledger IDs cannot look like self-hosted IDs.

## Data policy and endpoint trust

`local_only` checks the selected model before dispatch, including direct Messages requests and compaction calls. Startup rejects cloud aliases in active routes; undeclared or cloud aliases requested directly are rejected as well. There is no local-to-cloud fallback. A file may declare an inactive cloud model for a later deliberate policy change, but referenced credentials and prices must still validate.

Local entries must use `localhost` or a numeric loopback/private address. HTTPS is required except for loopback HTTP. URLs containing embedded credentials, query strings or fragments are rejected. Redirects and ambient HTTP proxies are disabled for configured clients. Known cloud tags (`:cloud`, `-cloud`, `cloud/…`) are rejected for local entries.

A private endpoint is a trust declaration, not proof of local execution. A local server can forward requests elsewhere. In particular, Ollama supports signed-in cloud execution through its local server; for a local-only deployment, disable that runtime's cloud features and restrict runtime network egress as required. Ollama documents `OLLAMA_NO_CLOUD=1` or `disable_ollama_cloud` in its server configuration, followed by a restart. See [Ollama's local compatibility behavior](https://docs.ollama.com/api/openai-compatibility), [cloud behavior](https://docs.ollama.com/cloud), and [cloud disablement instructions](https://docs.ollama.com/faq#how-do-i-disable-ollamas-cloud-features).

The current policy is runner configuration, not a complete per-workspace authorization/egress system. Do not offer shared hosted customer execution on that assumption. Hybrid per-task approval, authenticated serving endpoints, provider/region allowlists, and network isolation remain separate work.

## Usage and costs

Live responses preserve the actual upstream model, stop reason, tool identities and token usage. Live ledger model IDs are qualified as `local/<provider>/<actual-model>` for local execution and `<provider>/<actual-model>` for cloud execution. Avoided calls use the route alias and zero usage; the text-only response cache does not retain the original upstream snapshot. OpenAI-compatible cached prompt tokens are separated from ordinary input tokens to avoid counting them twice.

Local provider token charges are zero. This does not measure hardware cost, electricity, GPU utilization or compute time; those need a separate meter. Cloud pricing requires explicit `input_per_mtok` and `output_per_mtok`; `cache_write_per_mtok` and `cache_read_per_mtok` default to the input rate unless supplied. Every rate must be finite and nonnegative. Explicit zero pricing supports an authorized free tier, without promising continuing availability.

Configured rates are operator estimates, applied once when recording the call. They do not import a provider invoice or discover changing prices. Provider rate/usage differences and OpenRouter upstream endpoint selection can affect actual charges. Keep rates current and reconcile against provider billing. Anthropic cache/batch multipliers are not applied to unrelated providers.

A timeout, transport interruption or malformed response may still incur upstream charges even when Farhelm cannot settle a successful local usage row. Provider invoice reconciliation and reservation settlement for these uncertain outcomes are not implemented. An error is not evidence of a free call.

Response-cache identity includes configuration and a digest of credential identity. Changing the model, endpoint, capability, prices, data policy or API account invalidates prior configured answers; secret values are not printed or written to cache keys. This is not a substitute for tenant-scoped application authorization. Configured providers run deferred work live, with the existing batch-downgraded trace; the legacy Anthropic batch flusher is disabled while the registry is selected.

OpenRouter receives one selected model, `provider.allow_fallbacks = false` and `provider.require_parameters = true`. Farhelm does not automatically select a second model/provider when a request fails. OpenRouter still performs initial upstream endpoint selection; request-level upstream allowlists, regional constraints and retention policy configuration are not implemented here. Review account controls before submitting private data. These flags follow [OpenRouter's provider routing documentation](https://openrouter.ai/docs/guides/routing/provider-selection).

## Conformance and limits

Ordinary tests use local HTTP fixtures and never contact a paid/live provider. Fixtures cover normalized tool messages, malformed responses, missing usage, actual model identities, policy rejection before network access and configured cost accounting. Run targeted checks with `cargo test -p farhelm-gateway` and the relevant runner/agent tests.

Before promoting a deployment, run the [opt-in model smoke probe and deployment evaluation](model-evaluation.md) using its pinned base/adapter, tokenizer/template, parser, quantization and runtime. The synthetic probe covers exact text plus successful and failed tool-result replay through the gateway; context capacity, latency under load and held-out workflow quality need separate evaluation. See [vLLM tool-calling requirements](https://docs.vllm.ai/en/stable/features/tool_calling/). Models that require replaying reasoning fields are unsupported until the normalized contract can preserve them. Tool-bearing histories currently skip compaction to preserve call/result pairing, which can reach context limits sooner. Streaming, multimodal parts, automatic cost discovery and compute metering remain future work.

Truncated or empty native-agent responses fail the task instead of marking partial work complete. Incomplete tool calls are not executed. Earlier edits remain in its task worktree; failed tasks do not yet have the normal proposed-diff review flow. Incomplete automatic reviews produce `concerns`. Incomplete/refused summaries preserve the old history while retaining their recorded charges; a summary that exhausts a budget prevents the following model dispatch.
