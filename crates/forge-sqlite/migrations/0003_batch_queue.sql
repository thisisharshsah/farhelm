-- C6: the Batch API queue.
--
-- Deferrable work (test generation, doc sweeps, lint fixes) is queued here
-- instead of being dispatched live, then submitted in one batch and billed at
-- half rates. Until this table existed the gateway dispatched such calls live
-- and set `batch_downgraded` so the trace did not claim a discount it had not
-- earned; that flag now only fires when batching is switched off.

CREATE TABLE batch_item (
  id            TEXT PRIMARY KEY,
  session_id    TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  -- What the provider echoes back on each result, and the only thing tying a
  -- result to the row that asked for it. Unique because a collision would
  -- attribute one answer — and its cost — to the wrong session.
  custom_id     TEXT NOT NULL UNIQUE,
  task_type     TEXT NOT NULL,
  model         TEXT NOT NULL,
  -- The assembled Messages params, verbatim. Stored rather than rebuilt so a
  -- flush hours later sends exactly what was priced and approved, even if the
  -- repo has moved on.
  request_json  TEXT NOT NULL,
  -- Assigned by the provider at submit time; null while queued.
  batch_id      TEXT,
  -- queued | submitted | succeeded | errored | expired | canceled
  status        TEXT NOT NULL DEFAULT 'queued',
  response_text TEXT,
  error         TEXT,
  queued_at     INTEGER NOT NULL,
  submitted_at  INTEGER,
  settled_at    INTEGER
);

-- The flusher's query: everything still waiting to go out.
CREATE INDEX batch_item_queued ON batch_item(status, queued_at);
-- The poller's query: everything belonging to a batch in flight.
CREATE INDEX batch_item_batch ON batch_item(batch_id) WHERE batch_id IS NOT NULL;
CREATE INDEX batch_item_session ON batch_item(session_id);
