-- Enforce containment and same-workspace links without changing migration 11.
-- Invalid legacy rows abort this migration transaction; they are never deleted.

CREATE TABLE project_checked (
  id             TEXT NOT NULL PRIMARY KEY,
  workspace_id   TEXT NOT NULL CHECK (length(trim(workspace_id)) > 0),
  name           TEXT NOT NULL,
  description    TEXT NOT NULL DEFAULT '',
  budget_cap_usd REAL,
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL
);
INSERT INTO project_checked SELECT * FROM project;
DROP TABLE project;
ALTER TABLE project_checked RENAME TO project;
CREATE INDEX project_workspace ON project (workspace_id, updated_at DESC);

CREATE TABLE conversation_checked (
  id         TEXT NOT NULL PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES project(id),
  title      TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
INSERT INTO conversation_checked SELECT * FROM conversation;
DROP TABLE conversation;
ALTER TABLE conversation_checked RENAME TO conversation;
CREATE INDEX conversation_project ON conversation (project_id, updated_at DESC);

CREATE TABLE document_checked (
  id           TEXT NOT NULL PRIMARY KEY,
  project_id   TEXT NOT NULL REFERENCES project(id),
  title        TEXT NOT NULL,
  content      TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  version      INTEGER NOT NULL DEFAULT 1 CHECK (version > 0),
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL
);
INSERT INTO document_checked SELECT * FROM document;
DROP TABLE document;
ALTER TABLE document_checked RENAME TO document;
CREATE INDEX document_project ON document (project_id, updated_at DESC);

-- Legacy tasks/repositories have no project association, and task runs/artifacts
-- are not implemented. Their tenant scope cannot be guessed from an ID. Add
-- them to this projection only with a verified containment migration.
CREATE VIEW workspace_entity_scope (kind, id, workspace_id) AS
  SELECT 'project', id, workspace_id FROM project
  UNION ALL
  SELECT 'conversation', c.id, p.workspace_id
    FROM conversation c JOIN project p ON p.id = c.project_id
  UNION ALL
  SELECT 'document', d.id, p.workspace_id
    FROM document d JOIN project p ON p.id = d.project_id;

CREATE TRIGGER entity_link_scope_insert BEFORE INSERT ON entity_link
BEGIN
  SELECT CASE
    WHEN NEW.source_type NOT IN ('project', 'conversation', 'document')
      OR NEW.target_type NOT IN ('project', 'conversation', 'document')
      THEN RAISE(ABORT, 'entity link kind has no implemented workspace scope')
    WHEN NEW.relation_kind NOT IN ('mentions', 'spawns', 'blocks', 'documents', 'produces', 'belongs_to')
      THEN RAISE(ABORT, 'invalid entity link relation kind')
    WHEN NOT EXISTS (SELECT 1 FROM workspace_entity_scope
      WHERE kind = NEW.source_type AND id = NEW.source_id)
      OR NOT EXISTS (SELECT 1 FROM workspace_entity_scope
      WHERE kind = NEW.target_type AND id = NEW.target_id)
      THEN RAISE(ABORT, 'entity link endpoint does not exist')
    WHEN NOT EXISTS (
      SELECT 1 FROM workspace_entity_scope s JOIN workspace_entity_scope t
        ON s.workspace_id = t.workspace_id
      WHERE s.kind = NEW.source_type AND s.id = NEW.source_id
        AND t.kind = NEW.target_type AND t.id = NEW.target_id)
      THEN RAISE(ABORT, 'entity link endpoints must share a workspace')
  END;
END;

CREATE TRIGGER entity_link_scope_update BEFORE UPDATE ON entity_link
BEGIN
  SELECT CASE
    WHEN NEW.source_type NOT IN ('project', 'conversation', 'document')
      OR NEW.target_type NOT IN ('project', 'conversation', 'document')
      THEN RAISE(ABORT, 'entity link kind has no implemented workspace scope')
    WHEN NEW.relation_kind NOT IN ('mentions', 'spawns', 'blocks', 'documents', 'produces', 'belongs_to')
      THEN RAISE(ABORT, 'invalid entity link relation kind')
    WHEN NOT EXISTS (SELECT 1 FROM workspace_entity_scope
      WHERE kind = NEW.source_type AND id = NEW.source_id)
      OR NOT EXISTS (SELECT 1 FROM workspace_entity_scope
      WHERE kind = NEW.target_type AND id = NEW.target_id)
      THEN RAISE(ABORT, 'entity link endpoint does not exist')
    WHEN NOT EXISTS (
      SELECT 1 FROM workspace_entity_scope s JOIN workspace_entity_scope t
        ON s.workspace_id = t.workspace_id
      WHERE s.kind = NEW.source_type AND s.id = NEW.source_id
        AND t.kind = NEW.target_type AND t.id = NEW.target_id)
      THEN RAISE(ABORT, 'entity link endpoints must share a workspace')
  END;
END;

-- Re-check existing v11 links in the same migration transaction. A bad row
-- leaves the original database and version intact when the transaction rolls back.
UPDATE entity_link SET source_id = source_id;

CREATE TRIGGER project_scope_immutable BEFORE UPDATE OF workspace_id ON project
WHEN OLD.workspace_id != NEW.workspace_id
BEGIN
  SELECT RAISE(ABORT, 'project workspace cannot change');
END;

CREATE TRIGGER conversation_scope_immutable BEFORE UPDATE OF project_id ON conversation
WHEN (SELECT workspace_id FROM project WHERE id = OLD.project_id)
  != (SELECT workspace_id FROM project WHERE id = NEW.project_id)
BEGIN
  SELECT RAISE(ABORT, 'conversation cannot move between workspaces');
END;

CREATE TRIGGER document_scope_immutable BEFORE UPDATE OF project_id ON document
WHEN (SELECT workspace_id FROM project WHERE id = OLD.project_id)
  != (SELECT workspace_id FROM project WHERE id = NEW.project_id)
BEGIN
  SELECT RAISE(ABORT, 'document cannot move between workspaces');
END;

-- Polymorphic links cannot declare ordinary endpoint foreign keys. Restrict
-- identity changes/deletion atomically so valid links cannot become dangling.
CREATE TRIGGER project_id_immutable BEFORE UPDATE OF id ON project
WHEN OLD.id != NEW.id
BEGIN
  SELECT RAISE(ABORT, 'project identity cannot change');
END;
CREATE TRIGGER conversation_id_immutable BEFORE UPDATE OF id ON conversation
WHEN OLD.id != NEW.id
BEGIN
  SELECT RAISE(ABORT, 'conversation identity cannot change');
END;
CREATE TRIGGER document_id_immutable BEFORE UPDATE OF id ON document
WHEN OLD.id != NEW.id
BEGIN
  SELECT RAISE(ABORT, 'document identity cannot change');
END;

CREATE TRIGGER project_link_restrict BEFORE DELETE ON project
WHEN EXISTS (SELECT 1 FROM entity_link
  WHERE (source_type = 'project' AND source_id = OLD.id)
     OR (target_type = 'project' AND target_id = OLD.id))
BEGIN
  SELECT RAISE(ABORT, 'remove entity links before deleting project');
END;
CREATE TRIGGER conversation_link_restrict BEFORE DELETE ON conversation
WHEN EXISTS (SELECT 1 FROM entity_link
  WHERE (source_type = 'conversation' AND source_id = OLD.id)
     OR (target_type = 'conversation' AND target_id = OLD.id))
BEGIN
  SELECT RAISE(ABORT, 'remove entity links before deleting conversation');
END;
CREATE TRIGGER document_link_restrict BEFORE DELETE ON document
WHEN EXISTS (SELECT 1 FROM entity_link
  WHERE (source_type = 'document' AND source_id = OLD.id)
     OR (target_type = 'document' AND target_id = OLD.id))
BEGIN
  SELECT RAISE(ABORT, 'remove entity links before deleting document');
END;
