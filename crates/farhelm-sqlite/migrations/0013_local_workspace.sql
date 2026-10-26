-- A local workspace belongs to this database, not to a mutable machine name,
-- runner credential, or caller-supplied identifier. Existing projects retain
-- their original scopes and are never silently adopted into the local scope.
CREATE TABLE local_workspace (
  singleton    INTEGER PRIMARY KEY CHECK (singleton = 1),
  workspace_id TEXT NOT NULL UNIQUE CHECK (
    length(workspace_id) = 38
    AND substr(workspace_id, 1, 6) = 'local:'
    AND substr(workspace_id, 7) NOT GLOB '*[^0-9a-f]*'
  )
);
INSERT INTO local_workspace (singleton, workspace_id)
  VALUES (1, 'local:' || lower(hex(randomblob(16))));

CREATE INDEX project_workspace_id ON project (workspace_id, id DESC);
