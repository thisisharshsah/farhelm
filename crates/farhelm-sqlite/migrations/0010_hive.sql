-- Letting two agents work on one problem without a person relaying between them.
--
-- Until now the only channel between two sessions was you: read what one said,
-- retype it into the other. That is fine for two and impossible for four, and
-- it means the useful half of a long session — what it *learned* — dies with
-- the pane.
--
-- Two tables, because agents need to say two different kinds of thing.
--
-- `hive_message` is "you specifically, now": a handoff, a question, an answer.
-- It is addressed, it is read once, and it is done.
--
-- `hive_note` is "whoever works on this next": the migration is half applied,
-- that test is flaky for this reason, do not touch that file. Nobody is
-- addressed and nothing is consumed by reading it.
--
-- The design this borrows from keeps both as files in a git repository, with a
-- single-committer router so that two agents writing at once cannot conflict.
-- That router does not exist here and does not need to: this store is
-- transactional, so the insert *is* the delivery. There is no second process
-- that has to be running for a message to arrive, and no partially written
-- mailbox to reconcile after a crash.

CREATE TABLE hive_message (
  id              TEXT PRIMARY KEY,
  -- The recipient. Indexed below, because "what is waiting for me" is the only
  -- question this table is ever asked on the hot path.
  session_id      TEXT NOT NULL,
  from_session_id TEXT NOT NULL,
  body            TEXT NOT NULL,
  created_at      INTEGER NOT NULL,
  -- NULL while unread. A column rather than a delete: a handoff somebody acted
  -- on is exactly the thing you want to be able to read back when the result is
  -- wrong, and deleting it would leave the transcript saying an agent did
  -- something for no reason.
  read_at         INTEGER
);

-- No foreign key to `session`, for the same reason `session_output` has none:
-- a message may be posted by or to a session whose row is still being written,
-- and a constraint violation there would drop the handoff rather than delay it.
-- The cost is orphaned rows if a session is deleted, which is a smaller problem
-- than a message that silently never arrived.

-- The inbox query, and the only index this table needs: unread first, oldest
-- first, for one recipient. `read_at` leads so that a session with a long
-- history of read messages does not pay for them on every poll.
CREATE INDEX hive_message_inbox
  ON hive_message (session_id, read_at, created_at);

CREATE TABLE hive_note (
  repo_id    TEXT NOT NULL,
  key        TEXT NOT NULL,
  value      TEXT NOT NULL,
  -- Which session last wrote it. A note that turns out to be wrong is worth
  -- being able to trace back to the agent that believed it.
  written_by TEXT NOT NULL,
  written_at INTEGER NOT NULL,
  -- Keyed, so a later answer replaces an earlier one rather than both being
  -- true at once. An append-only blackboard reads as a conversation nobody
  -- summarised, which is the thing this exists to avoid.
  PRIMARY KEY (repo_id, key)
) WITHOUT ROWID;
