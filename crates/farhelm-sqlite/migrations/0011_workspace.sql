-- Unified Workspace Object Model and Cross-Entity Linking (ADR 0002).
--
-- Adds project, conversation, document, and entity_link tables to support
-- structured workspace navigation, discussions, documentation, and typed
-- relationship graphs.

CREATE TABLE project (
  id             TEXT PRIMARY KEY,
  workspace_id   TEXT NOT NULL,
  name           TEXT NOT NULL,
  description    TEXT NOT NULL DEFAULT '',
  budget_cap_usd REAL,
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL
);

CREATE INDEX project_workspace
  ON project (workspace_id, updated_at DESC);

CREATE TABLE conversation (
  id         TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  title      TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE INDEX conversation_project
  ON conversation (project_id, updated_at DESC);

CREATE TABLE document (
  id           TEXT PRIMARY KEY,
  project_id   TEXT NOT NULL,
  title        TEXT NOT NULL,
  content      TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  version      INTEGER NOT NULL DEFAULT 1,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL
);

CREATE INDEX document_project
  ON document (project_id, updated_at DESC);

CREATE TABLE entity_link (
  id            TEXT PRIMARY KEY,
  source_type   TEXT NOT NULL,
  source_id     TEXT NOT NULL,
  target_type   TEXT NOT NULL,
  target_id     TEXT NOT NULL,
  relation_kind TEXT NOT NULL,
  created_at    INTEGER NOT NULL
);

CREATE UNIQUE INDEX entity_link_unique
  ON entity_link (source_type, source_id, target_type, target_id, relation_kind);

CREATE INDEX entity_link_source
  ON entity_link (source_type, source_id);

CREATE INDEX entity_link_target
  ON entity_link (target_type, target_id);
