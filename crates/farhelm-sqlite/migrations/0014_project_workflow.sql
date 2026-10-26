-- Explicit project membership; legacy repositories/tasks are not adopted.
CREATE TABLE project_repo (
  project_id TEXT NOT NULL REFERENCES project(id),
  repo_id TEXT NOT NULL REFERENCES repo(id),
  attached_at INTEGER NOT NULL,
  PRIMARY KEY (project_id, repo_id)
);

CREATE TABLE project_task (
  task_id TEXT NOT NULL PRIMARY KEY REFERENCES agent_task(id),
  project_id TEXT NOT NULL,
  repo_id TEXT NOT NULL,
  retry_of TEXT REFERENCES project_task(task_id),
  created_at INTEGER NOT NULL,
  FOREIGN KEY (project_id, repo_id) REFERENCES project_repo(project_id, repo_id)
);
CREATE INDEX project_task_page ON project_task(project_id, task_id DESC);
CREATE INDEX repo_machine_page ON repo(machine_id, id DESC);

CREATE TRIGGER project_task_valid BEFORE INSERT ON project_task
BEGIN
  SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM agent_task t JOIN session s ON s.id = t.session_id
    WHERE t.id = NEW.task_id AND t.repo_id = NEW.repo_id AND s.repo_id = NEW.repo_id
  ) THEN RAISE(ABORT, 'project task must match task/session repository') END;
  SELECT CASE WHEN NEW.retry_of IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM project_task p JOIN agent_task t ON t.id = p.task_id
    WHERE p.task_id = NEW.retry_of AND p.project_id = NEW.project_id
      AND p.repo_id = NEW.repo_id AND t.status = 'rejected'
  ) THEN RAISE(ABORT, 'retry must reference a rejected task in the same project and repository') END;
END;

CREATE TRIGGER project_repo_immutable BEFORE UPDATE ON project_repo
BEGIN SELECT RAISE(ABORT, 'project repository membership is immutable'); END;
CREATE TRIGGER project_task_immutable BEFORE UPDATE ON project_task
BEGIN SELECT RAISE(ABORT, 'project task provenance is immutable'); END;
CREATE TRIGGER project_task_restrict_delete BEFORE DELETE ON project_task
BEGIN SELECT RAISE(ABORT, 'project task provenance cannot be removed'); END;
CREATE TRIGGER project_task_identity BEFORE UPDATE OF session_id, repo_id ON agent_task
WHEN (OLD.session_id != NEW.session_id OR OLD.repo_id != NEW.repo_id)
  AND EXISTS (SELECT 1 FROM project_task WHERE task_id = OLD.id)
BEGIN SELECT RAISE(ABORT, 'project task session/repository cannot change'); END;
CREATE TRIGGER project_session_repo BEFORE UPDATE OF repo_id ON session
WHEN OLD.repo_id != NEW.repo_id AND EXISTS (
  SELECT 1 FROM agent_task t JOIN project_task p ON p.task_id = t.id WHERE t.session_id = OLD.id
)
BEGIN SELECT RAISE(ABORT, 'project task session repository cannot change'); END;
CREATE TRIGGER project_repo_machine BEFORE UPDATE OF machine_id ON repo
WHEN OLD.machine_id != NEW.machine_id AND EXISTS (SELECT 1 FROM project_repo WHERE repo_id = OLD.id)
BEGIN SELECT RAISE(ABORT, 'attached repository machine cannot change'); END;
