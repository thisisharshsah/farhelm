-- The hook bridge is handed Claude Code's own session id, which is not ours.
-- Without somewhere to record it, every hook event would create a new session.
--
-- Nullable: sessions started by the runner itself (M1's tmux manager) have no
-- agent-side id until the agent first calls back.
ALTER TABLE session ADD COLUMN agent_session_id TEXT;

-- Partial unique index rather than a UNIQUE column: many sessions legitimately
-- have no agent id, and SQLite treats every NULL as distinct in a plain UNIQUE
-- constraint, which would work but says less about the intent.
CREATE UNIQUE INDEX ux_session_agent_id
  ON session(agent_session_id)
  WHERE agent_session_id IS NOT NULL;
