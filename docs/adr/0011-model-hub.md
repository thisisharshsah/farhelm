# 0011: Farhelm as the model hub for every project

Status: accepted direction, 2026-10-28 (user direction). Steps 1 and 2 below
are implemented; the rest is the plan.

## Context

The owner runs several projects that use models: Farhelm itself, everest,
career, lacuna and fennec. Before this, each found its own way: a private
Python gateway for three of them, fennec its own fine-tuned model loaded
in-process with a fallback chain, and Claude directly where nothing local
was set up. Fine-tuning, benchmarks and graders were rebuilt per project
(fennec's `tools/bench/` is a complete example), and usage lived in several
ledgers or none.

## Decision

Farhelm is the one place that holds models, serves them, records their use
and improves them:

- **Hold:** base models (GGUF, hashed, versioned) and the adapters trained on
  them, in the engine's store (ADR 0009). A model is a deployment: base
  revision, adapter hash, template, quantization and runtime.
- **Serve:** every project calls through the front door with its own key
  (ADR 0010); specialists are registry entries (base model plus adapter).
  Nothing falls back to a cloud model under `local_only`.
- **Record:** every call lands in one ledger under the calling project.
- **Improve:** each project registers an evaluation set and a grader. A
  fine-tuned or distilled model is promoted for a project only when it beats
  what that project uses now on that evaluation, and the previous version
  stays for rollback.

Data rules, unchanged from AGENTS.md and applied per project: a project's
calls become training data only with its explicit permission, datasets record
source, revision, permission and teacher lineage, projects never share
training data or evaluation sets, and an evaluation set is never trained on.

## Order of work

1. Projects call through Farhelm (done: everest, career, lacuna and fennec
   have clients; the first three switch when their services restart).
2. A runner restart costs projects nothing (done: servers are adopted).
3. Host project models: fennec's tuned Qwen3.5-4B adapter as a specialist on
   the engine. Needs a Qwen3.5 GGUF base and the importer's tensor map for
   its hybrid (linear and full attention) layers, then a conformance check
   and fennec's own benchmark.
4. Evaluation as a Farhelm feature: a per-project evaluation set and grader,
   run against any registry model, results kept with the deployment record.
   fennec's `bench.py` is the template.
5. Datasets from use, with permission: a project opts in, and its prompts and
   accepted answers become a versioned dataset with recorded lineage.
6. Training and distillation as jobs: MLX LoRA on this machine (PEFT on a GPU
   host later), a teacher model labelling data for a smaller, faster student,
   each run producing an adapter, its evaluation and a deployment record.
   Promotion follows step 4.
7. Retire `local-assistant` once no project uses it.

## Consequences

- One ledger, one model store, one evaluation discipline.
- Farhelm is on the path of every project's model calls; its reliability is
  theirs (step 2 exists for this reason).
- Memory is shared: every loaded model counts against one machine. Loading
  and unloading models on demand will be needed as projects add their own.
