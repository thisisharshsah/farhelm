-- Project conversations: the execution identity behind a `conversation` row,
-- the messages in it, and every reply attempt.
--
-- `conversation` (migration 0011) holds the title and timestamps; this adds
-- what a reply needs and what a retry must be able to see. A turn is claimed
-- before inference and settled after it, so a lost response is a visible
-- `failed` or `interrupted` row rather than a silent gap.

-- Which repository the conversation is about, and the budgeted session its
-- replies are charged to. One session per conversation, never shared.
CREATE TABLE chat_session (
  conversation_id TEXT PRIMARY KEY REFERENCES conversation(id),
  repo_id         TEXT NOT NULL REFERENCES repo(id),
  session_id      TEXT NOT NULL UNIQUE REFERENCES session(id)
);

-- One row per reply attempt, keyed by the client's request id so a resend
-- after a lost response replays the recorded outcome instead of asking twice.
CREATE TABLE chat_turn (
  conversation_id TEXT NOT NULL REFERENCES conversation(id),
  request_id      TEXT NOT NULL,
  status          TEXT NOT NULL,          -- pending | completed | failed | interrupted
  error           TEXT,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,
  PRIMARY KEY (conversation_id, request_id)
);

CREATE INDEX chat_turn_latest
  ON chat_turn (conversation_id, created_at DESC);

-- The transcript. A message belongs to the turn that produced it, which is how
-- the history handed to the model excludes the question of a failed attempt.
CREATE TABLE chat_message (
  id              TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversation(id),
  request_id      TEXT NOT NULL,
  role            TEXT NOT NULL,          -- user | assistant
  content         TEXT NOT NULL,
  model           TEXT,
  created_at      INTEGER NOT NULL
);

CREATE INDEX chat_message_order
  ON chat_message (conversation_id, created_at, id);
