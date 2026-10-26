-- The step ledger for native agent tasks (ADR 0004, first form).
--
-- One row per tool exchange, inserted before the tool runs and settled after
-- it. A row with no finished_at belongs to a tool that was running when the
-- process stopped — the one fact a restart could not otherwise recover.
-- Payloads are bounded by the writer.
CREATE TABLE task_step (
  task_id     TEXT NOT NULL REFERENCES agent_task(id),
  ordinal     INTEGER NOT NULL,
  tool        TEXT NOT NULL,
  input       TEXT NOT NULL,
  output      TEXT,
  is_error    INTEGER NOT NULL DEFAULT 0,
  started_at  INTEGER NOT NULL,
  finished_at INTEGER,
  PRIMARY KEY (task_id, ordinal)
);
