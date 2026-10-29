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
3. Host project models (done for fennec, 2026-10-28): fennec's tuned
   Qwen3.5-4B adapter is `qwen3.5-4b:conscious`, which fennec asks for as
   the alias `companion`, with thinking off as it was trained. The importer
   maps Qwen3.5's hybrid layers and reorders its value heads to llama.cpp's
   layout. On fennec's own benchmark it matched or beat the MLX original on
   six of seven measures (judge "fit" 3.42 against 3.75; the engine's base is
   Q8 where training used a 4-bit base).

   Naming, confirmed by the owner: models keep their makers' names; each
   model lists its adapters, selected as `model:adapter` (`@vN` pins a
   version); aliases name purposes (`code`, `think`, `quick`,
   `companion`).
4. Evaluation as a Farhelm feature: a per-project evaluation set and grader,
   run against any registry model, results kept with the deployment record.
   fennec's `bench.py` is the template.

   First run (2026-10-28), lacuna's `e030-audit`, the one lacuna task with
   enough human labels (54 blind grades by the author), graded with lacuna's
   own harness on a copy of its database under the `eval` client. Cohen's
   kappa against the author: `code` 0.19, `quick` 0.17, `think` 0.11; the same
   gpt-oss-20b on the earlier MLX server scored 0.34 (ranges overlap at this
   size). None reaches lacuna's 0.6 floor, so a task adapter has room to earn
   promotion. `qwen3.5-4b` exhausted its token allowance thinking on 43 of 54
   items; with thinking off (`enable_thinking: false`, which the front door
   now passes) it answered all 54 and scored 0.07.

   One run is not a score. A second identical `think` run, same prompts and
   temperature 0, changed 6 of 54 labels and moved kappa from 0.11 to 0.21;
   the October and current runs differ by about as much. Evaluation therefore
   repeats runs and reports the spread. The other lacuna tasks have
   1 to 4 human labels against a target of 40; until labelled, they can only
   measure a student's agreement with its teacher.

   The run found two gateway faults, both fixed: the front door dropped
   `response_format`, and gpt-oss asked for JSON in prose labels its answer in
   a way llama.cpp's parser rejects (about one call in six failed); and the
   agent loop breaker applied to front-door clients, so ten failures in a row
   refused every later request from the project until a restart.
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
