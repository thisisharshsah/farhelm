# 0008 — Project-owned local agent runs

Status: implemented initial local workflow, 2026-10-25. This extends
[ADR 0007](0007-local-project-api.md) with registered repository attachment and
project-owned execution attempts. Conversations, planning work items, hosted
permissions and resumable execution remain separate work.

## Context and decision

Projects initially stored metadata; agent tasks already ran against local
repositories and produced reviewed diffs. Connecting these features requires
explicit ownership: a repository can belong to several projects, so repository
membership cannot determine which project owns a particular run.

Migration 0014 adds `project_repo` as a many-to-many association and
`project_task` as immutable per-run provenance. It does not backfill or adopt
existing tasks. `AgentTask` continues to mean one execution attempt; it is not
renamed or treated as the future planning `TaskItem`. The migration adds foreign
keys, pagination indexes and triggers preventing reassignment of linked
task/session/repository identity. Existing task lifecycle/status writes remain
supported. There is no detach/delete/reassignment API in this slice.

The `farhelm-app::ProjectWorkflow` use case builds its trusted scope from the
database-owned local workspace and the runner's machine identity. It lists only
registered repositories on that machine. Attachment is idempotent and starts no
process. A new task accepts a registered repository ID, and the runner resolves
its filesystem path from storage. No new API accepts an execution path from the
project form.

Validate scope, repository attachment and retry ownership before reading prior
prompts, rejection notes or diffs. Retrying requires a rejected run in the same
project and repository. The SQLite adapter rechecks these facts in an immediate
transaction, then inserts the session, task and project association together.
Failure rolls back all three writes. Execution starts after commit and uses the
existing gateway, worktree, command approvals, ledger, verification and diff
review. No transaction stays open during inference or command execution.

Synchronous storage/filesystem composition runs on bounded blocking workers.
The owned capacity permit stays inside the closure after an HTTP disconnect.
The captured Tokio runtime schedules a committed run before that closure
returns. A process crash between persistence and dispatch is still an
interrupted run: the existing restart reconciliation marks it failed. This is
not a persistent job queue, lease or exactly-once execution guarantee.

## HTTP and client boundary

All routes remain under the existing local authentication/CORS policy:

| Request | Result |
| --- | --- |
| `GET /v1/projects/{id}/repo-candidates` | Bounded registered repository page. |
| `GET /v1/projects/{id}/repos` | Bounded attached repository page. |
| `POST /v1/projects/{id}/repos` | Attach `{ "repo_id": "…" }`; return repository. |
| `GET /v1/projects/{id}/tasks` | Bounded task page for this project. |
| `POST /v1/projects/{id}/tasks` | Start from `repo_id`, instruction and task options. |
| `GET /v1/projects/{id}/tasks/{task_id}` | Scoped task detail, output and diff. |
| `POST …/tasks/{task_id}/review` | Existing approve/reject operation after scope resolution. |
| `POST …/tasks/{task_id}/revert` | Existing guarded revert after scope resolution. |

Pages use descending IDs, an exclusive opaque `after` cursor and a default
limit of 50 (1–100). Cursors support older registered repository identities;
they do not grant access. Repository page rows carry `id`, `name` and `path`.
Task pages reuse the existing `TaskView` fields without adding project metadata
to the global/relay schema.

New task bodies reject unknown fields, require a nonblank instruction of at
most 64 KiB UTF-8, permit a finite positive task budget and a step limit of
1–256. The workflow body limit is 128 KiB; project metadata retains its separate
24 KiB limit. Resource IDs/cursors are bounded to 128 bytes without controls.
Internal storage failures are redacted. Unknown/foreign resources return 404;
invalid input returns 422, incompatible retry state 409 and exhausted metadata
capacity 429. Existing provider/task errors retain their status conventions.

The shared client validates untrusted repository/task/detail responses. The UI
offers registered repository selection, task start and bounded live history;
`/p/{project}/t/{task}` keeps review, retry and revert in project context. Its
action adapter exposes only scoped task methods. Runner/project changes clear
forms/resources and ignore late responses. Mutations prevent duplicate submits
and do not automatically retry uncertain outcomes. Task output is bounded and
merged by sequence number across refreshes.

The capability is direct-only. Relay/MCP protocols and global task payloads are
unchanged. Legacy tasks remain usable; legacy retry cannot import context from
a project-owned run. Global local-owner task reads and existing execution
surfaces retain their prior local trust boundary; this is not tenant isolation
or a new hosted authorization system. Shared repository notes and execution
credentials likewise remain runner-owned, rather than project-private stores.

## Migration, evidence and remaining work

Back up durable databases and use the normal append-only upgrade path. Keep
provenance and workspace identities during rollback; do not lower
`user_version` or delete association rows to run an older binary. A schema
reversal needs a separate planned migration. No new framework, server or
runtime dependency is introduced.

Storage regressions cover scope filtering, shared repositories, idempotent
attachment, rejected retry checks, transactional rollback and immutable
provenance. HTTP tests cover scoped APIs and local authentication. The
configured-model integration fixture exercises actual worktrees, tools,
approval, review/apply and revert; its provider is synthetic and does not
certify local model quality. Client validation/rendered tests cover resource
lifetimes and scoped actions. See [Local Projects](../local-projects.md) and
[model evaluation](../model-evaluation.md).

Repository registration/discovery beyond existing records, conversations,
planning tasks, project budget enforcement, hosted membership, isolation and
runtime checkpoint recovery remain separate milestones.
