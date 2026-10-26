# Evaluating a model deployment

Reviewed October 24, 2026. A serving API accepting a request does not establish that a model can complete a Farhelm workflow. Evaluate the exact base model, adapter, tokenizer, template, parser, quantization and runtime together. [Provider configuration](model-providers.md) describes the currently supported non-streaming text and function-tool interface.

## Evidence levels

Keep three results separate:

1. **Deterministic integration tests:** synthetic HTTP servers verify Farhelm's request translation, policy, error handling and ledger. They do not run model weights.
2. **Live conformance probe:** a deliberately selected deployment handles synthetic prompts and tool results through the real gateway. It tests a small protocol/workflow slice, without granting a model filesystem or command access.
3. **Held-out workflow evaluation:** representative tasks establish useful quality, reliability, latency, capacity and cost for a defined release. A passing probe does not replace this evaluation.

No runtime or model is certified by the presence of this guide. Record measured results and failures; a missing runtime, unavailable endpoint or incomplete manifest is unavailable evidence.

## Run the opt-in probe

Ordinary CI remains offline with respect to model providers:

```sh
cargo test --locked -p farhelm-gateway
cargo test --locked -p farhelm-runner --test model_providers
cargo test --locked -p farhelm-runner --test local_model_workflow
cargo test --locked -p farhelm-gateway --example model_conformance
```

The live example requires an explicit operator configuration file and model alias. Start the chosen runtime separately, using an already installed model. For Ollama, `ollama list` lists available models; `ollama ps` reports loaded models and their allocated context. These commands do not install a model. Configure local-only runtime settings as described in [provider setup](model-providers.md#data-policy-and-endpoint-trust).

Run the example with absolute operator paths and a new report filename:

```sh
cargo run --locked -p farhelm-gateway --example model_conformance -- \
  --config /absolute/path/models.toml \
  --model local-code \
  --deployment-id pilot-local-code-001 \
  --report /absolute/path/new-model-smoke.json \
  --run
```

`--run` explicitly enables inference; omitting it does not dispatch a model request. A configured cloud model additionally requires `--allow-cloud`; this flag does not override a `local_only` policy. The selected model must declare `tools = true`. Optional `--timeout-seconds 90` bounds each request. Credentials continue to come from the environment names in the operator configuration, never CLI arguments. The example does not install a runtime, download weights or discover another provider.

The `farhelm-model-smoke-v1` suite sends at most five requests:

| Case | Passing behavior |
| --- | --- |
| `exact_text` | Return the specified synthetic text with a complete finish reason and reported usage. |
| `tool_success` | Request only `lookup_fixture` with the expected `{ "key": "alpha" }` object, preserve its call identity, then use the synthetic successful result in a final answer. |
| `tool_error` | Request the same synthetic tool and handle its explicit failed result in the final answer. |

The program validates the returned tool call and generates its result from an in-memory fixture. It never runs a tool name or program supplied by the model. This evaluates the configured gateway, adapter, tool history and usage ledger without giving the model OS tools. A separate deterministic runner integration test covers the approved-command boundary.

The version 1 JSON report records the suite, operator-provided `deployment_id`, configured alias/provider/model metadata and configuration digest, timestamps, duration, overall result, case results and each completed call's model, finish reason, latency, usage and configured cost. It excludes endpoint URLs, credentials and raw prompts/replies. Stable reason codes identify failed cases. A failed case exits nonzero; a report is evidence of the recorded outcomes rather than a certification. A report is created as a new file with private Unix permissions and will not overwrite an existing path. Use a fresh name for every run.

Retain the report alongside the deployment manifest below, using the same `deployment_id`. The example does not parse that manifest or independently attest its hashes. It also does not measure token-stream latency, exact context capacity or local compute consumption.

Do not use production conversations, credentials in command arguments, repository contents or customer documents as probe data. An explicitly configured cloud alias sends synthetic requests to that provider and can incur charges. Local zero token pricing does not measure compute cost. Failed or interrupted requests can still incur upstream charges.

## Record deployment identity

Keep a deployment manifest with each evaluation report and retain the previous deployable configuration for rollback. The example below is an operator record, not a new runner configuration format or a schema currently validated by Farhelm. Replace every placeholder with a measured or pinned value; use `null` for an unavailable fact and explain it. Empty `adapters` means no adapter, rather than an unknown adapter.

```json
{
  "manifest_version": 1,
  "deployment_id": "REPLACE_WITH_RELEASE_ID",
  "model_alias": "local-code",
  "base_model": {
    "source": "REPLACE_WITH_MODEL_SOURCE",
    "revision": "REPLACE_WITH_IMMUTABLE_REVISION",
    "artifact_sha256": "REPLACE_WITH_ARTIFACT_DIGEST",
    "license_record": "REPLACE_WITH_LICENSE_OR_PERMISSION_RECORD"
  },
  "adapters": [],
  "tokenizer": {
    "revision": "REPLACE_WITH_TOKENIZER_REVISION",
    "artifact_sha256": "REPLACE_WITH_TOKENIZER_DIGEST"
  },
  "chat_template": {
    "name": "REPLACE_WITH_EFFECTIVE_TEMPLATE",
    "sha256": "REPLACE_WITH_EFFECTIVE_TEMPLATE_DIGEST"
  },
  "tool_parser": {
    "name": "REPLACE_WITH_EFFECTIVE_PARSER",
    "revision": "REPLACE_WITH_PARSER_REVISION"
  },
  "quantization": {
    "format": "REPLACE_WITH_WEIGHT_FORMAT",
    "kv_cache_dtype": "REPLACE_WITH_KV_CACHE_FORMAT"
  },
  "runtime": {
    "name": "REPLACE_WITH_RUNTIME",
    "version": "REPLACE_WITH_INSTALLED_VERSION",
    "source_revision": "REPLACE_WITH_RUNTIME_REVISION",
    "container_digest": null,
    "nonsecret_launch_arguments": []
  },
  "hardware": {
    "accelerator": "REPLACE_WITH_DEVICE_AND_COUNT",
    "accelerator_memory_gib": null,
    "system_memory_gib": null,
    "driver_version": null
  },
  "serving": {
    "data_location": "local",
    "context_tokens": null,
    "max_output_tokens": null,
    "parallel_requests": null,
    "cloud_forwarding_disabled": null
  },
  "evaluation": {
    "farhelm_revision": "REPLACE_WITH_GIT_REVISION",
    "working_tree_diff_sha256": null,
    "suite_revision": "REPLACE_WITH_SUITE_REVISION",
    "held_out_dataset_revision": null,
    "report_artifact": "REPLACE_WITH_REPORT_REFERENCE"
  }
}
```

For each active adapter, record its immutable base revision, adapter artifact hash, training/configuration revision and dataset provenance record. Record the ordered set of active adapters and any merge operation. A mutable model tag or an API's model name alone does not identify the deployed weights. For a cloud service that withholds a weight revision, record the returned identity and the missing reproducibility guarantee explicitly.

Do not put API keys, authorization headers or secret launch arguments in a manifest. Model weights, datasets and private traces belong in controlled artifact storage rather than Git. Hash the exact manifest and retain that digest with results so later edits cannot silently change what was tested.

## Runtime-specific setup checks

| Runtime | Check before evaluating |
| --- | --- |
| Ollama | Pin the model artifact and effective template. Set the actual context window in the runtime, not only Farhelm's output limit. The compatible API does not expose `num_ctx`; Ollama documents a derived Modelfile or runtime context configuration. Confirm loaded allocation with `ollama ps`. Disable cloud execution for local-only deployments. |
| vLLM | Use a model-compatible tool parser and template, with automatic tool choice enabled. Test the template's handling of assistant tool calls and tool-role results, not only the first generated call. Preserve IDs; Mistral's Transformers templates need specific compatibility handling. Record reasoning parser and generation configuration too. |
| llama.cpp | Enable the documented Jinja tool path and verify the selected native/generic handler and template. Record the server build and GGUF hashes. Multiple tool calls depend on model/request configuration and are not a baseline guarantee. Check context allocation per serving slot. |

These checks follow [Ollama compatibility](https://docs.ollama.com/api/openai-compatibility), [Ollama context configuration](https://docs.ollama.com/context-length), [vLLM tool calling](https://docs.vllm.ai/en/stable/features/tool_calling/), [llama.cpp function calling](https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md) and [llama.cpp server configuration](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md). Flags and parser names must match the pinned runtime release; these links track upstream documentation rather than a fixed deployment. Ollama's [prompt assembly source](https://github.com/ollama/ollama/blob/main/server/prompt.go) can discard old messages when truncation is enabled, so an apparently successful response is insufficient evidence that the complete history reached the model.

Reasoning is a separate compatibility constraint. Ollama's [tool guide](https://docs.ollama.com/capabilities/tool-calling) replays thinking together with tool calls; its [compatibility adapter source](https://github.com/ollama/ollama/blob/main/openai/openai.go) maps a `reasoning` field. llama.cpp also documents `reasoning_content` and template-dependent history support. Farhelm does not preserve these reasoning fields as conversation state. A deployment requiring their replay is unsupported until the contract carries them; successful text output alone cannot establish tool-loop compatibility. Do not expose internal reasoning as user-facing answer text to work around this boundary.

## Promotion checklist beyond the probe

Use these as evaluation cases with recorded outcomes, rather than claims that every case is automated today:

| Boundary | Evidence to retain |
| --- | --- |
| Text and termination | Nonempty usable answers, actual model identity, truthful refusal, recognized finish reasons and no success after output/context truncation. Include a tiny output limit and an empty/reasoning-only completion. |
| Tool loop | Correct declared tool, complete JSON object, schema-valid arguments, unique call identity, matching result replay and a grounded final response. Include a failed tool result, two sequential calls and, only if advertised, multiple calls in one response. |
| Usage | Input/output counts are present and nonnegative; cached input is a subset of total input. Check warm/cold requests against runtime telemetry and the gateway ledger. Count reasoning output according to the serving runtime's reported usage; never substitute visible character counts. |
| Context | Check comfortably within, near and beyond the configured runtime window. Retain an early synthetic sentinel to detect silent history loss. A character estimate is not a tokenizer count; record actual input tokens and output headroom. Tool histories currently skip compaction. |
| Failure and cancellation | Unavailable model, malformed response, transport failure, deadline and cancellation produce truthful failures. Check the runtime's active work/telemetry after cancellation; dropping a client request does not establish that GPU work stopped. |
| Data policy | Local-only refuses remote aliases before dispatch and runtime cloud forwarding is disabled. Validate deployment network controls separately; an accepted private URL does not prove local execution. |
| Capacity | Cold-start and warm latency, sustained concurrency, peak memory, queue behavior and overload failures on the intended hardware. Report sample count, distributions and workload sizes. |

The initial API adapter is non-streaming. Do not claim time-to-first-token measurements, partial tool-argument handling, vision/audio or structured reasoning replay from its completion timings. Synthetic checks do not execute the native agent's OS tools, test a hosted sandbox, validate task recovery or establish tenant isolation.

## Compare improvements on held-out workflows

Start with the existing base deployment, improve the prompt/tool definitions, then compare retrieval and any adapter against that baseline. Keep a held-out task set outside training and prompt selection. For code work, use disposable repositories with independently checked tests and a diff review; measure completed tasks and unintended edits alongside exact tool validity. For documents and workflow tasks, check cited context, correct task transitions and permission boundaries. Add adversarial retrieved text that attempts to redirect tools.

Run repeated trials with the same recorded deployment and workload settings. Report successes, failures and unavailable results separately, with numerator and denominator; keep p50/p95 completion latency, total usage, configured provider charges and independently metered local compute. A single pass is a smoke test. A LoRA is useful only when it improves the chosen held-out workflows without unacceptable regressions. Release thresholds depend on the pilot's task and latency requirements and must be declared before comparing candidates.

Before promotion, retain the manifest, evaluation report, relevant redacted failure artifacts, model/data license records and rollback configuration. Re-run affected cases whenever base/adapter weights, tokenizer, template, parser, quantization or runtime changes. Broader capability claims require corresponding evaluations.
