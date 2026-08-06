-- RelayForge schema v1.
--
-- Ships every table from the design doc, including the ones whose features are
-- P1 (response_cache, approval.risk). Adding columns later is easy; adding new
-- *write paths* later is not, so they are born here.

-- Machines the runner daemon is installed on
CREATE TABLE machine (
  id            TEXT PRIMARY KEY,        -- uuid
  name          TEXT NOT NULL,           -- "hetzner-1"
  pubkey        TEXT NOT NULL,           -- device pairing key
  last_seen_at  INTEGER,                 -- unix ms
  created_at    INTEGER NOT NULL
);

-- A git repository known to a machine
CREATE TABLE repo (
  id            TEXT PRIMARY KEY,
  machine_id    TEXT NOT NULL REFERENCES machine(id),
  path          TEXT NOT NULL,           -- absolute path on machine
  name          TEXT NOT NULL,
  budget_usd    REAL,                    -- NULL = no repo cap
  UNIQUE(machine_id, path)
);

-- File-backed plans (source of truth is PLAN.md; DB mirrors for UI)
CREATE TABLE plan (
  id            TEXT PRIMARY KEY,
  repo_id       TEXT NOT NULL REFERENCES repo(id),
  file_path     TEXT NOT NULL,           -- 'PLAN.md'
  content_hash  TEXT NOT NULL,           -- detect drift from file
  created_at    INTEGER NOT NULL
);

-- One agent process lifecycle
CREATE TABLE session (
  id            TEXT PRIMARY KEY,
  repo_id       TEXT NOT NULL REFERENCES repo(id),
  agent         TEXT NOT NULL,           -- 'claude-code' | 'opencode'
  tmux_target   TEXT,                    -- 'forge:3.1'
  status        TEXT NOT NULL,           -- running|awaiting_approval|paused|done|dead
  plan_id       TEXT REFERENCES plan(id),
  budget_usd    REAL,                    -- session cap
  spent_usd     REAL NOT NULL DEFAULT 0,
  started_at    INTEGER NOT NULL,
  ended_at      INTEGER
);

CREATE TABLE plan_step (
  id             TEXT PRIMARY KEY,
  plan_id        TEXT NOT NULL REFERENCES plan(id),
  ordinal        INTEGER NOT NULL,
  title          TEXT NOT NULL,
  status         TEXT NOT NULL,          -- todo|active|done|skipped|failed
  checkpoint_sha TEXT,                   -- commit created on completion
  UNIQUE(plan_id, ordinal)
);

-- Every approval decision, forever (audit + policy learning)
CREATE TABLE approval (
  id            TEXT PRIMARY KEY,
  session_id    TEXT NOT NULL REFERENCES session(id),
  tool          TEXT NOT NULL,           -- 'bash', 'write_file', ...
  payload       TEXT NOT NULL,           -- the command / file summary shown
  risk          TEXT NOT NULL,           -- low|medium|destructive
  decision      TEXT,                    -- approved|denied|timeout
  decided_via   TEXT,                    -- watch|phone|web|auto_policy
  requested_at  INTEGER NOT NULL,
  decided_at    INTEGER
);

-- The cost ledger: one row per model call (append-only)
CREATE TABLE usage_event (
  id                 TEXT PRIMARY KEY,
  session_id         TEXT NOT NULL REFERENCES session(id),
  model              TEXT NOT NULL,
  tier               TEXT NOT NULL,      -- small|large|batch
  task_type          TEXT NOT NULL,      -- triage|select_files|summarize|commit_msg|title|edit|refactor|plan|hard_debug
  input_tokens       INTEGER NOT NULL,
  output_tokens      INTEGER NOT NULL,
  cache_write_tokens INTEGER NOT NULL DEFAULT 0,
  cache_read_tokens  INTEGER NOT NULL DEFAULT 0,
  cost_usd           REAL NOT NULL,      -- computed from the price table at write time
  avoided            TEXT,               -- NULL | 'pre_gate' | 'response_cache'
  created_at         INTEGER NOT NULL
);
CREATE INDEX ix_usage_session_time ON usage_event(session_id, created_at);

-- Response cache (C8, post-MVP; table ships in v1 to avoid a migration)
CREATE TABLE response_cache (
  key_hash      TEXT PRIMARY KEY,        -- sha256(model + normalized prompt)
  response      TEXT NOT NULL,
  hit_count     INTEGER NOT NULL DEFAULT 0,
  created_at    INTEGER NOT NULL,
  expires_at    INTEGER NOT NULL
);

-- Paired client devices
CREATE TABLE device (
  id            TEXT PRIMARY KEY,
  kind          TEXT NOT NULL,           -- phone|watch|web
  pubkey        TEXT NOT NULL,
  push_token    TEXT,
  paired_at     INTEGER NOT NULL
);
