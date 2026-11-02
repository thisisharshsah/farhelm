-- Work items: what the app calls a Task on a project's board. A task is
-- planned work (backlog, todo, in_progress, review, done), made from a
-- discussion or by hand; an agent's attempt on it is a Run, the agent_task
-- row that already exists. A task may exist with no run at all, which is the
-- difference from project_task (which is run provenance).
CREATE TABLE work_item (
  id              TEXT PRIMARY KEY,
  project_id      TEXT NOT NULL REFERENCES project(id),
  title           TEXT NOT NULL,
  description     TEXT NOT NULL DEFAULT '',
  status          TEXT NOT NULL,            -- backlog | todo | in_progress | review | done
  -- Where its runs happen; NULL until chosen.
  repo_id         TEXT REFERENCES repo(id),
  -- The discussion it came from, so the result is visible there.
  conversation_id TEXT REFERENCES conversation(id),
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);

CREATE INDEX work_item_board ON work_item (project_id, id DESC);
CREATE INDEX work_item_conversation ON work_item (conversation_id, id DESC);

-- A run started from a task belongs to it. Set when the run is inserted and
-- never changed: a run is one attempt on one task.
ALTER TABLE agent_task ADD COLUMN work_item_id TEXT REFERENCES work_item(id);
CREATE INDEX agent_task_work_item ON agent_task (work_item_id, id DESC);
