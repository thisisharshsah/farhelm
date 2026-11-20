-- Watch history: the videos each account played, on any device. One row per
-- video, so watching it again moves it to the top, and the position lets any
-- device resume where it was left.
-- Append new migrations; never edit this one after it has been applied.

CREATE TABLE watch_history (
  user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  video_id TEXT NOT NULL,
  title TEXT NOT NULL,
  channel TEXT NOT NULL,
  -- Length in seconds, when YouTube gave one.
  seconds INTEGER,
  -- Where it was left, in seconds.
  position INTEGER NOT NULL DEFAULT 0,
  watched_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, video_id)
);
CREATE INDEX watch_history_recent ON watch_history (user_id, watched_at DESC);
CREATE INDEX watch_history_time ON watch_history (watched_at);
