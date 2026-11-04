-- Leased, fenced runs and per-step checkpoints (ADR 0004, second form).
--
-- A run is owned by exactly one live loop. The owner holds a renewable lease
-- (`lease_holder`, `lease_expires_at`) and every claim bumps
-- `lease_generation`, the fencing token: a loop that lost its lease cannot
-- write its result over a takeover, because its generation no longer matches.
-- A row with no holder is not running anywhere.
--
-- `interrupted_at` marks a run settled by recovery rather than by its own
-- loop. It is what makes a run eligible to resume, and it is cleared when the
-- run resumes or finishes normally.
--
-- `task_step.checkpoint` is the commit id of a snapshot of the checkout taken
-- after a step that could change it. The snapshot is a commit nobody's branch
-- points at, kept alive by a ref under refs/farhelm/checkpoints/ until the
-- run's checkout is removed.
ALTER TABLE agent_task ADD COLUMN lease_holder TEXT;
ALTER TABLE agent_task ADD COLUMN lease_expires_at INTEGER;
ALTER TABLE agent_task ADD COLUMN lease_generation INTEGER NOT NULL DEFAULT 0;
ALTER TABLE agent_task ADD COLUMN interrupted_at INTEGER;
ALTER TABLE task_step ADD COLUMN checkpoint TEXT;
