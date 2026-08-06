-- Native agent tasks: a prompt in, a reviewable diff out.
--
-- Every other table here describes somebody else's agent being supervised. This
-- one describes the runner doing the work itself: the loop proposes a change
-- set, a human approves or rejects it from a phone, and only then does anything
-- reach the working tree.
--
-- Two columns carry JSON, for the same reason `batch_item.request_json` does —
-- keeping the domain crate free of a JSON dependency, and storing the exact
-- bytes that were decided on rather than something rebuilt later:
--
--   diff_json    the ChangeSet the reviewer was shown
--   staged_json  the Workspace overlay `apply` writes from
--
-- They are stored *separately* on purpose. A review card only needs the diff,
-- and a phone should not be shipped the full contents of every touched file to
-- render one.

CREATE TABLE agent_task (
  id             TEXT PRIMARY KEY,
  -- Spend is billed to a session like every other model call, so the ledger,
  -- the budget guard and the cost dashboard all work without knowing tasks
  -- exist.
  session_id     TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  repo_id        TEXT NOT NULL REFERENCES repo(id),
  prompt         TEXT NOT NULL,
  -- running | awaiting_review | applied | rejected | no_changes | failed
  status         TEXT NOT NULL DEFAULT 'running',
  -- The agent's closing message: the first thing a reviewer reads.
  summary        TEXT NOT NULL DEFAULT '',
  diff_json      TEXT NOT NULL DEFAULT '',
  staged_json    TEXT NOT NULL DEFAULT '',
  -- Denormalised so the fleet view can render a card without parsing the diff.
  files_changed  INTEGER NOT NULL DEFAULT 0,
  lines_added    INTEGER NOT NULL DEFAULT 0,
  lines_removed  INTEGER NOT NULL DEFAULT 0,
  steps          INTEGER NOT NULL DEFAULT 0,
  cost_usd       REAL NOT NULL DEFAULT 0,
  error          TEXT,
  -- Why a reviewer said no. Fed back to the agent verbatim on a retry, so it
  -- is the one field here the model reads.
  review_note    TEXT,
  -- watch | phone | web | auto_policy
  decided_via    TEXT,
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL,
  decided_at     INTEGER
);

-- The fleet view's query: what is waiting on a human, oldest first.
CREATE INDEX agent_task_status ON agent_task(status, created_at);
CREATE INDEX agent_task_session ON agent_task(session_id, created_at);
