# 0004: Durable Task Execution, Leased State Machine, and Step-Level Recovery

**Status**: First form implemented October 26, 2026 — the branch is recorded before the first model call, every tool exchange is a `task_step` row (intent before effect, settled after), and restart recovery turns surviving edits into a change set awaiting review instead of a bare failure. Leases, fencing, Git checkpoint-per-step and automatic resumption remain pending; nothing is re-executed on restart.  
**Consulted**: [AGENTS.md](../../AGENTS.md), [Engineering Stack](../engineering-stack.md), [Platform Review](../platform-review-2026-10-22.md)

---

## Context

In Farhelm's current implementation, native agent tasks run inside detached `tokio::spawn` asynchronous futures (`crates/farhelm-runner/src/task.rs`). Task rows persist, but there is no leased step ledger or resume protocol.

This architecture introduces failure modes:
1. **Runner Restarts Cause Immediate Task Death**:
   On restart, `reconcile_after_restart` scans all tasks in `TaskStatus::Running` and abruptly marks them `TaskStatus::Failed` with the message: *"the runner stopped while this task was working"*.
2. **Orphaned Git Worktrees**:
   A checkout may survive process death, while enough intermediate execution state to resume safely is missing. Recovery must inspect persisted task metadata and Git state rather than assume all work is gone or all surviving checkouts are disposable.
3. **No Step Checkpointing**:
   Multi-step execution has no durable, replayable checkpoint of complete tool exchanges and side-effect outcomes. Existing task rows and filesystem edits may survive, but they are not sufficient to reconstruct a safe continuation.
4. **Non-Idempotent Side-Effects**:
   Without a persistent execution ledger, retrying an interrupted task requires starting from scratch, potentially re-executing non-idempotent shell commands or conflicting file writes.

---

## Decision

The target is a durable, leased state machine with a transactional step ledger and explicit recovery semantics. `farhelm-domain::recovery` now provides pure lease-expiration/renewal and recovery-decision helpers. They do not claim leases in storage or resume execution: the current runner restart behavior remains unchanged. The helper only accepts the latest recorded step's committed, idempotent checkpoint; it refuses to skip a later uncertain step in favor of an older commit.

### 1. Leased State Machine

Proposed tasks will be driven by explicit transitions; lease/heartbeat intervals need measurement rather than a fixed undocumented constant:

```text
[Queued] 
   │ (Worker atomically claims a bounded renewable lease)
   ▼
[Leased] 
   │ (Worktree validated, checkout initialized)
   ▼
[Running] <─────────────────────────────┐
   │                                     │
   ├── (Tool requires human review) ──> [AwaitingApproval]
   │                                     │ (Approved)
   │ <───────────────────────────────────┘
   ▼ (Agent loop concludes)
[Verifying] 
   │ (Pregate / diff checks complete)
   ▼
[AwaitingReview] 
   │
   ├── (Human applies)  ──> [Applied] (Terminal, can_revert = true)
   ├── (Human rejects)  ──> [Rejected] (Terminal)
   └── (Human reverts)  ──> [Reverted] (Terminal)
```

If a worker encounters an error or cancellation:
- An explicit cancellation transitions the state to `Cancelled`.
- Unhandled process death causes the lease to expire; pass the observation time into deterministic transition rules.
- Claims/renewals need owner and fencing-generation checks so a stale worker cannot commit results after takeover. A lease alone cannot fence an arbitrary external API or process.

### 2. Transactional Step Ledger (`task_steps`)

Persist the authorized action's intent before execution, then record its result or uncertain outcome afterward. Do not hold a database transaction across inference or a command. The following conceptual table still needs attempt/state, lease-generation and idempotency fields, bounds and tenant/resource constraints before becoming a migration:

```sql
CREATE TABLE IF NOT EXISTS task_steps (
    id TEXT PRIMARY KEY,
    task_run_id TEXT NOT NULL REFERENCES task_runs(id) ON DELETE CASCADE,
    step_ordinal INTEGER NOT NULL,
    stage TEXT NOT NULL, -- 'model_call', 'tool_call', 'tool_result', 'verify'
    model_name TEXT,
    tool_name TEXT,
    input_payload_json TEXT,
    output_payload_json TEXT,
    checkpoint_commit_sha TEXT,
    step_cost_usd REAL NOT NULL DEFAULT 0.0,
    step_duration_ms INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_task_steps_ordinal 
    ON task_steps(task_run_id, step_ordinal);
```

### 3. Git Checkpoint-per-Step

Evaluate task-owned snapshot commits at safe mutation boundaries, with checkpoint references stored in the step ledger. Git hooks, signing configuration, untracked/ignored files, large artifacts and user changes need explicit handling. A checkpoint cannot capture or roll back arbitrary shell/network effects; do not automatically stage secrets or unrelated files. Persist only the bounded context required for recovery, with retention/redaction rules; private model reasoning is not a default ledger payload.

### 4. Resumption and Recovery Protocol on Startup

Proposed startup recovery:
1. `reconcile_after_restart` identifies all `task_runs` where `status = 'running'` or `'leased'`.
2. For each task:
   - Check if the worktree on disk matches `task_runs.worktree_path` and `task_runs.base_commit_sha`.
   - Query the last committed `task_step` with a valid `checkpoint_commit_sha`.
   - Preserve surviving files. Reconcile worktree identity, diffs and ledger state before resuming a proven safe step; do not automatically hard-reset unknown edits.
   - Reconcile external operations using their idempotency keys or receipts where available. An interrupted operation with an unknown outcome becomes `Interrupted`/needs-attention rather than being retried as though it never ran.
3. Remove a terminal task's checkout only after confirming ownership and preserving reviewable work/artifacts under the retention policy. No automatic destructive cleanup of unknown user edits.

---

## Consequences and Limits

- **Disk Space**: Checkpoints consume repository and artifact space. Removing a worktree does not remove branch references or guarantee Git object collection; define retention and cleanup explicitly.
- **Latency Overhead**: Measure ledger and snapshot costs on representative repositories and hardware. No benchmark has established a per-step latency bound.
- **External Side Effects**: Shell commands executing arbitrary scripts (`npm install`, external API calls) cannot be automatically rolled back by git. Such commands are tracked in `task_steps` with explicit `tool_name = 'bash'` to inform resumption logic.

---

## Verification and Follow-Up

- Implement `task_runs` and `task_steps` schema migrations in `crates/farhelm-sqlite`.
- Update `farhelm-runner/src/task.rs` to write steps transactional before tool calls.
- Add an integration test that simulates runner process termination mid-task and verifies clean resumption from the last step checkpoint.
- Test duplicate claims, stale-worker writes, cancellation during a command, partial external outcomes and uncertain-outcome review. Preserve the current failed-on-restart behavior until the replacement is verified.
