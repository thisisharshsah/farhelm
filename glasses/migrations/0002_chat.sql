-- Lens chat: one conversation per account, shared by the console and every
-- pair of glasses. A row is one thing the person said or typed together with
-- Lens's reply, so both always arrive together.
-- Append new migrations; never edit this one after it has been applied.

CREATE TABLE messages (
  -- The sync cursor: clients ask for everything after the last seq they have.
  -- AUTOINCREMENT, so a seq is never reused, even after a clear.
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  -- Which kind of device it was sent from: console or glasses.
  source TEXT NOT NULL CHECK (source IN ('console', 'glasses')),
  text TEXT NOT NULL,
  -- The reply as JSON (ChatReply in src/shared/api.ts), re-validated on read.
  reply TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX messages_user_seq ON messages (user_id, seq);
CREATE INDEX messages_time ON messages (created_at);

-- Clearing the chat on one device clears it everywhere: clients drop what
-- they hold at or below this seq.
CREATE TABLE chat_state (
  user_id TEXT PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
  cleared_through INTEGER NOT NULL DEFAULT 0
);
