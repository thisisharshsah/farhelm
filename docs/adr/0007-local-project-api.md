# 0007: Local project metadata API

Status: implemented initial resource slice, 2026-10-24. This delivers create, list and detail for the project foundation in [ADR 0002](0002-unified-workspace-object-model.md). Hosted authorization, repository/task associations and the rest of that workspace model remain separate work.

## Context

Project DTOs and SQLite containment already exist, but the application needs usable project records before adding linked conversations, documents and tasks. Exposing the existing unscoped store lookups directly would let callers choose a workspace or retrieve another workspace's records. Deriving a local scope from a machine name or runner credential would also change ownership when those values change.

The first resource slice should preserve the current local application boundary and familiar REST/JSON conventions. It does not require a cloud service, another storage engine or a general authorization framework.

## Decision

Persist one server-owned local workspace identity in SQLite migration `0013_local_workspace.sql`. A constrained singleton receives `local:` followed by 32 random lowercase hexadecimal characters when the migration runs. Reopening or restoring that database retains its identity; a separately initialized database receives a new identity. Existing projects retain their original workspace IDs. The migration never adopts older rows by guessing ownership.

The `farhelm-app::Projects` use case resolves this identity from `WorkspaceStore` itself. Its public operations accept project content, project identity or pagination options, with time explicitly supplied for creation. They never accept a caller's workspace ID. Scoped retrieval and pagination perform their scope filtering in SQL. Creation uses an insert that fails on identity collision rather than the older upsert operation.

Expose three runner HTTP operations:

| Operation | Behavior |
| --- | --- |
| `POST /v1/projects` | Accept only `name` and optional `description`; return the persisted project with status 201. |
| `GET /v1/projects` | Return `ProjectPage`, ordered by ID descending; default limit 50, valid range 1–100. |
| `GET /v1/projects/{id}` | Return the local project; missing and foreign-scope identities return the same 404 response. |

List pagination uses an exclusive `after` cursor containing a canonical lowercase hyphenated UUID returned by the server. The SQL predicate is `id < after`; fetch one extra row to determine `next_cursor`. Migration 0013 adds a `(workspace_id, id DESC)` index. Cursor pagination avoids repeating already listed rows when a newer project is inserted; it is not a snapshot of every concurrent change.

Validate names as 1–120 Unicode scalar values, at most 480 UTF-8 bytes, without control characters or whitespace-only content. Trim surrounding whitespace when storing the name. Descriptions default to empty and permit at most 4,000 Unicode scalar values / 16,000 UTF-8 bytes; only newline and tab controls are allowed. The HTTP body limit is 24 KiB. Unknown fields are rejected. Semantic/query errors return 422, malformed JSON returns 400, oversized bodies return 413 and exhausted metadata capacity returns 429. Internal errors do not expose SQL or database paths.

Keep SQLite work off the async executor. Each `AppState` has four project-operation permits. Acquire an owned permit before scheduling `spawn_blocking` and move it into the blocking closure, retaining capacity if an HTTP client disconnects while database work continues. The shared store still serializes its connection; this bound limits queued project operations rather than making SQLite a multi-writer service.

The existing local token authentication and CORS policy wrap these routes. The shipped runner listener binds to loopback. The browser uses the active transport and validates project responses as untrusted data. Relay transport reports Projects unsupported and the UI explains local availability. No project command, relay payload, MCP capability or cloud plaintext copy is introduced. Project metadata is stored as plaintext in the existing local SQLite database, consistent with other local records; transport encryption is not at-rest encryption.

The UI supports actual empty/loading/error/refresh states, pagination, create and detail. Creation disables duplicate submissions and waits for a successful response before navigating. There is no automatic POST retry or backend idempotency key: after an uncertain outcome, refresh the list before manually creating again. Resource state belongs to the active runner/transport and route, and is cleared when that context changes.

## Consequences, migration and rollback

This is a useful local metadata boundary, not completion of [ADR 0005's hosted principal authorization](0005-scoped-principal-authorization.md). Cloud organizations, persisted workspace model policy, membership/grant resolution, project budgets, repository/task associations, linked documents/conversations, editing and deletion remain unimplemented by this slice. Existing repository/task workflows continue to operate separately. `budget_cap_usd` remains null on newly created projects.

Roll out through the normal append-only migration path with a database backup. Existing data in other scopes remains available to its existing internal storage consumers but is hidden from this local API. Do not change historical migrations, reassign those rows or select a workspace by request parameter to make them appear. Any import/adoption needs a separate verified ownership design.

Roll back application exposure by disabling/reverting the new feature while preserving the upgraded database. If a schema reversal becomes necessary, design a new migration and preserve local identities and records; do not lower `user_version`, delete migration 0013 data or run an older binary as a downgrade procedure. A future shared or remote implementation must establish verified caller scope and update the transport capability deliberately.

## Evidence and follow-up

Application/storage regressions cover validation, scoped lookup, bounded pages, insert collision behavior, stable scope across reopen and migration from version 12 without adopting existing projects. Runner HTTP integration tests cover persistence/restart, concurrent-insert pagination, scope isolation, invalid input/body limits and local-token enforcement. Client validation and rendered UI tests cover transport availability, real resource states, creation and stale context handling. See [the local Projects guide](../local-projects.md) for commands and the implemented API contract. Full browser/native verification is a separate check from these tests.
