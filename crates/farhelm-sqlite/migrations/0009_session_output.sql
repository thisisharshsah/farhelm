-- Keeping what was said.
--
-- Session output lived in a 200-line ring buffer in memory, keyed by session id
-- and lost on restart. Two consequences, both felt rather than reported:
--
--   * restarting the runner — a deploy, a crash, a laptop lid — emptied every
--     session's transcript, and the screen you steer from came back blank; and
--   * a session busier than 200 lines dropped its own beginning, so the
--     instruction that started the work scrolled out of existence while the
--     work was still running.
--
-- The ring buffer stays: it is the live tail, and reading the last few lines of
-- a running session should not touch the disk. This is the record behind it.
--
-- `seq` is per session and assigned by the writer, so ordering survives a
-- restart rather than depending on rowid or on a clock that can step backwards.
-- The pair is the primary key, which also makes re-appending the same line
-- idempotent instead of duplicating it.

-- No foreign key to `session`, deliberately.
--
-- Output is a log, and a log must never be the thing that fails. Lines are
-- pushed by whatever is producing them — a hook callback, a pane watcher, the
-- agent loop — and some of those run before or alongside the write that creates
-- the session row. Under a foreign key that ordering becomes a constraint
-- violation, and because a failed write here is logged rather than propagated
-- (refusing to show somebody the line already on their screen would be worse),
-- the result would be history silently going missing in exactly the case where
-- the session is newest.
--
-- The cost is orphaned rows if a session is ever deleted. That is bounded by
-- the per-session trim, and a stray transcript is a smaller problem than a
-- missing one.
CREATE TABLE session_output (
  session_id TEXT NOT NULL,
  seq        INTEGER NOT NULL,
  text       TEXT NOT NULL,
  at_ms      INTEGER NOT NULL,
  PRIMARY KEY (session_id, seq)
) WITHOUT ROWID;

-- Reading a transcript is always "the newest N lines of one session", and
-- pruning is always "everything below a sequence number for one session". The
-- primary key already orders by (session_id, seq), which serves both — so there
-- is no second index to keep current.
