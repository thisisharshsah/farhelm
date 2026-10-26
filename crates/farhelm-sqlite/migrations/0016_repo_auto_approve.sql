-- A standing delegation per repository: the auto-approve level a session in it
-- starts with. A session's own row in `session_policy` overrides it, so a
-- person can still tighten (or widen) one session without touching the rest.
-- Same ceiling as the session row: destructive commands are never covered,
-- and that rule lives in farhelm-domain, not here.
CREATE TABLE repo_policy (
  repo_id       TEXT PRIMARY KEY REFERENCES repo(id),
  auto_approve  TEXT NOT NULL DEFAULT 'off',   -- off | low | medium
  updated_at    INTEGER NOT NULL
);
