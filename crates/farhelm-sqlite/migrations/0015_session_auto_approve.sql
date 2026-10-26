-- A standing delegation per session: what the runner clears without asking.
--
-- Its own table rather than a column on `session`, so a session that predates
-- the setting reads as 'off' by absence and the session upsert (which must
-- never roll `spent_usd` back) stays untouched. Destructive commands are never
-- covered, whatever this says — that ceiling lives in farhelm-domain, not here.
CREATE TABLE session_policy (
  session_id    TEXT PRIMARY KEY REFERENCES session(id),
  auto_approve  TEXT NOT NULL DEFAULT 'off',   -- off | low | medium
  updated_at    INTEGER NOT NULL
);
