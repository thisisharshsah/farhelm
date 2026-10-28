# 0009: Local specialists and work modes

Status: proposed, 2026-10-28. User direction: no Claude subscription; run on
local models, with several fine-tuned specialists for different work, chosen
through Ask, Plan, Agent and Review modes. Extends
[ADR 0003](0003-provider-neutral-inference-layer.md) and
[ADR 0006](0006-configurable-model-providers.md).

## Context

The gateway already routes every request by task type to a `small`, `large`
or `frontier` slot, and the model registry (`FARHELM_MODELS_CONFIG`) maps a
slot to a configured model under a `local_only` policy. On the development
Mac (M5 Pro, 64 GB) Ollama serves `qwen3-coder:30b` for code and `qwen3:8b`
for short work. One general model per slot is the whole of today's
specialization.

The product needs two further ideas. A **mode** is what the person asks for:
answer a question, propose a plan, change the code, or judge a change. A
**specialist** is how a request is answered well: a base model with a
task-specific adapter, prompt and tool set, measured on its own evaluation.

## Decision

### Modes

Four modes, named as Codex and Cursor name theirs, each fixing what the model
may do. The mode, not the model, decides the tools; a specialist can never
widen them.

| Mode | Tools | Output | Today's nearest feature |
| --- | --- | --- | --- |
| Ask | none, or read-only (`Read`, `Grep`, `Glob`) | an answer | project conversation |
| Plan | read-only | numbered steps a person accepts before work | plan steps on a session |
| Agent | edit and run, under the approval policy and a worktree | a diff for review | native agent task |
| Review | read the diff and its test results | a verdict with reasons | second opinion on a task |

A mode is an explicit parameter of a conversation turn or a task, recorded
with the request, and shown in the UI wherever the work is shown. Approval
rules are unchanged: Agent commands still go through `AppState::raise_approval`,
and no mode auto-approves destructive commands or change-set review.

### Specialists

A specialist is a versioned deployment, as AGENTS.md already requires of any
model change: base model and revision, adapter hash, tokenizer and template,
tool-call parser, quantization and runtime. It also names its prompt, the
modes and task types it serves, and its evaluation suite and last score.

Specialists are declared in the operator registry file next to the models
they use (a `specialists` table in a later registry version), not in the
database: they are deployment configuration, rolled back by restoring the
previous file. Routing becomes mode and task type to specialist, then to the
existing slot when no specialist is active. The `local_only` check stays
before dispatch; a specialist never falls back to a cloud model.

A specialist is promoted from candidate to active only when it beats the base
model on its held-out workflow evaluation, and the previous configuration is
kept for rollback.

### Serving

Farhelm owns its model server (user direction, 2026-10-28): no Ollama or
second gateway to install. The runner installs a pinned llama.cpp server build,
verified against its published SHA-256, and supervises it as a separate
process on loopback (`farhelm engine install`, then `serve`). The arithmetic
(Metal and CUDA kernels, quantized formats, templates and tool-call parsing)
stays in llama.cpp; routing, accounting, policy and deployment records stay in
Farhelm. A separate process keeps a server crash or GPU out-of-memory away
from approvals and sessions, and lets the runner restart without reloading
weights.

llama.cpp was chosen over Ollama because it switches LoRA adapters per request
on one loaded base model (`/lora-adapters` and the request's `lora` field),
which many specialists on a 64 GB machine need; Ollama loads each adapter as a
separate model. Build `b11624` with `qwen3-coder:30b` passed the conformance
probe (all three cases, about 0.7 s for the text case). Ollama remains usable
as a registry provider until nothing depends on it.

The first specialist made the trip on 2026-10-28: the C2 "shortest reasoning"
adapter, trained with MLX on gpt-oss-20b, was converted with
`farhelm engine import-adapter` and served on the pinned gpt-oss-20b GGUF.
On eight questions with known answers at medium effort it cut output tokens
by 34% (MLX original: 38%) with unchanged accuracy (7 of 8 both ways). That
is a smoke comparison, not the held-out evaluation promotion requires.

Implemented the same day: the engine runs one supervised server per base model
(`farhelm engine add-model`), loads adapters switched off
(`farhelm engine add-adapter`), and a registry model with `adapters` is a
specialist whose requests switch them on. qwen3-coder 30B, gpt-oss-20b and the
C2 specialist (now the `fast` adapter, `gpt-oss-20b:fast`) each passed the conformance probe through the
registry. Every model starts with the runner; unloading idle models to fit
memory is not built yet.

### Training

Training lives in its own Python project (`pyproject.toml`, uv lockfile,
Ruff, pytest), separate from the Rust application. On Apple Silicon, MLX-LM
LoRA is the trainer; PEFT with Axolotl remains the path on CUDA hosts. Each
dataset records source, revision, license or permission, teacher lineage and
preprocessing. Customer traces are used only with explicit permission, are
segregated per tenant, and never appear in an evaluation set they trained on.

### Order of work

1. Run the existing gateway on local models (done on this machine) and pass
   the conformance probe for each model.
2. Add the mode parameter to conversations and tasks, with Ask and Agent
   mapped to today's features.
3. Build the evaluation harness per mode, starting with Review: accepted and
   rejected diffs in task history give labelled examples.
4. Train the first specialist (Review on the small base), promote it only on
   its evaluation, then Plan, then the small utility tasks (titles, commit
   messages). Agent coding comes last; it is the hardest to evaluate and the
   base coder is already strong.

## Consequences

- No feature may depend on the Anthropic path; it stays optional code.
- Quality claims are per specialist and per evaluation, never "frontier
  parity".
- Local token cost is zero in the ledger; compute cost needs its own meter.
- The registry gains a new version for specialists; version 1 files keep
  working.
