# 0002: Unified Workspace Object Model and Cross-Entity Graph

**Status**: DTO/storage foundation and initial local project create/list/detail API implemented; repository/run workflow implemented via ADR 0008; conversation/document APIs and broader graph pending. Updated October 25, 2026.  
**Consulted**: [AGENTS.md](../../AGENTS.md), [Engineering Stack](../engineering-stack.md), [Platform Review](../platform-review-2026-10-22.md)

---

## Context

Farhelm was initially constructed with specialized, semi-isolated entities:
- `Repo`: tracked local git paths and budgets.
- `Session`: managed terminal processes and hook callbacks.
- `AgentTask`: recorded prompt-diff proposals for code modification.
- `Plan` & `PlanStep`: tracked markdown plan checkboxes.
- `Note` & `Message`: provided inter-agent communication.

While effective for isolated task execution, this model lacks cohesion for a complete team workspace (such as Macro, Devin, Cursor, and monday.com). In a private team AI workspace:
1. Discussions in conversations frequently spawn tasks or cite documents.
2. Tasks must be organized into projects with shared goals, budgets, and repositories.
3. Documents (specs, architecture records, bug notes) must be linked to tasks and code artifacts.
4. Autonomous agent runs produce artifacts (diffs, test execution logs, coverage snapshots) that need immutable tracking.
5. Users need `@` mentions across entities to navigate context fluently.

---

## Decision

Adopt a unified, hierarchical relational entity model with a first-class cross-entity linking graph as the target. `farhelm-proto` defines project, conversation, document and typed-link DTOs, and `WorkspaceStore` plus SQLite migrations 0011/0012 provide their storage foundation. [ADR 0007](0007-local-project-api.md) adds migration 0013 and the first runner resource API: create/list/detail for projects in a stable database-owned local scope. [ADR 0008](0008-project-agent-workflow.md) implements registered repository attachment and explicit project-owned agent runs. Conversation/document endpoints and broader entity links remain pending. This does not replace existing cloud workspace and local repository/task/session behavior.

### 1. Hierarchical Containment Model

```text
Workspace (Tenant / Organization root, defines data policy)
  └── Project (Team focus, budget pool, repository associations)
       ├── Conversation (Multi-turn discussion, chat, agent dialogues)
       ├── Task (Tracked work item, status, priority, plan steps)
       ├── Document (Specifications, markdown docs, notes)
       └── Artifact (Immutable generated assets: diffs, logs, test reports)
```

The proposed migration maps existing primitives (`Repo`, `Session`, `AgentTask`):
- A `Project` can link one or more `Repo` records.
- An `AgentTask` is formalized as a `TaskRun` executing a parent `Task`.
- A `Session` is associated with a `Conversation` or `TaskRun`.

### 2. First-Class Entity Links Graph (`entity_links`)

Use a typed linking table for cross-entity relationships. This is a conceptual schema, not a migration ready for production:

```sql
CREATE TABLE IF NOT EXISTS entity_links (
    id TEXT PRIMARY KEY,
    source_type TEXT NOT NULL,  -- 'conversation', 'task', 'document', 'artifact', 'task_run'
    source_id TEXT NOT NULL,
    target_type TEXT NOT NULL,
    target_id TEXT NOT NULL,
    relation_kind TEXT NOT NULL, -- 'mentions', 'spawns', 'blocks', 'documents', 'produces'
    created_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_entity_links_unique 
    ON entity_links(source_type, source_id, target_type, target_id, relation_kind);
CREATE INDEX IF NOT EXISTS idx_entity_links_target 
    ON entity_links(target_type, target_id);
```

Migration 0012 enforces conversation/document containment with project foreign keys. Its `workspace_entity_scope` view and atomic link triggers require existing, same-workspace endpoints and known relation kinds; identity/tenant changes and linked-endpoint deletion are restricted. Scope is derived from containment rather than a separately mutable link workspace field. Only project, conversation and document links are accepted today. Repository/task associations and task-run/artifact records must establish verifiable workspace ownership before their link kinds can be enabled. These database constraints do not replace caller authentication or resource authorization.

### 3. Rust Proto Types and Serialization

The broader target will add or reconcile these core wire types in `farhelm-proto`; project, conversation, document and typed-link DTOs already exist:
- `Workspace`: `id`, `name`, `slug`, `data_policy`, `created_at`, `updated_at`.
- `Project`: `id`, `workspace_id`, `name`, `description`, `budget_cap_usd`, `created_at`, `updated_at`.
- `TaskItem`: `id`, `project_id`, `repo_id`, `title`, `description`, `status`, `priority`, `assignee`, `due_date`.
- `Document`: `id`, `project_id`, `title`, `content`, `content_hash`, `version`.
- `EntityLink`: `id`, `source_type`, `source_id`, `target_type`, `target_id`, `relation_kind`.

Prefer the established `text_enum!` convention for persisted string enums where appropriate. Generate or retain cross-language fixtures rather than assuming TypeScript types validate runtime responses. The gateway's initial data policy is operator configuration; persisted workspace policy needs a deliberate integration.

---

## Consequences and Limits

- **Storage**: Use append-only migrations and preserve durable user data. Audit existing local/cloud tables and name collisions before creating new ones; adding `IF NOT EXISTS` cannot upgrade an incompatible table. Shared Postgres remains future work and requires an explicit async storage design.
- **Client Impact**: The initial local Projects UI uses scoped create/list/detail over direct HTTP with loading/error/refresh states and validated responses. ADR 0008 adds scoped task history and review. Relay access and the remaining document/conversation queries need separate contracts and authorization; they do not exist merely because this ADR describes them.
- **Performance**: Start with bounded shallow traversals and indexes based on implemented queries; validate query plans and latency on representative tenant data before making performance claims.
- **Migration**: A default project per repository is a candidate backfill, not a selected automatic migration. Specify mapping, restart safety, rollback and behavior for shared repositories before applying it.
- **Invalid legacy data**: Migration 0012 fails and rolls back if v11 contains orphaned parents, unsupported/invalid links, cross-workspace links or invalid document versions. The original rows and schema version are retained. Back up the database, inspect the offending relationships and repair them with verified ownership before retrying; the application does not delete or reassign these rows automatically.
- **Link identity contract**: The store creates relationships idempotently by endpoint/relation tuple and returns the canonical stored `EntityLink`. A repeated write preserves the first ID and creation time; callers use that returned identity for later mutations. An ID already belonging to another edge fails rather than overwriting it. Resource APIs still need to expose this contract when implemented.

---

## Verification and Follow-Up

- Extend associations through additive migrations in `crates/farhelm-sqlite`; retain the implemented v11-upgrade, rollback, containment and link-integrity tests.
- Extend the remaining `farhelm-proto` DTOs while preserving current serialization round-trip tests.
- Retain the Rust-generated shared wire fixture and TypeScript DTO-key/enum coverage; extend them when adding the remaining entities. Existing Swift consumers keep using the same fixture without new workspace DTOs until their feature is implemented.
- Extend the initial local project REST endpoints in `crates/farhelm-runner` by feature, preserving verified scope and adding SSE only when its resource events are implemented. See [the local Projects guide](../local-projects.md) for current operations and limits.
