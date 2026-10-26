# Local Projects

Projects now supports creating, listing and opening metadata stored on the active local runner. Open **Projects** while connected directly to that runner, create a name and optional description, and open a project to read its description and timestamps. Use **Load more** for additional pages and **Refresh** to reload the runner's current records.

Open a project to attach registered repositories, start agent tasks and read its task history. Opening a task retains project context for diff review, rejection, retry and guarded revert. Relay connections display an availability explanation instead of invented records. Text conversations are available directly on the runner (below); documents, project budgets, editing and deletion remain pending. See [ADR 0007](adr/0007-local-project-api.md) for metadata and [ADR 0008](adr/0008-project-agent-workflow.md) for the implemented agent workflow.

## Work in a project

1. Connect directly to a compatible local runner and open or create a project.
2. Under **Repositories**, choose an existing registered repository and attach it. Registration currently comes from existing runner session/task/hook workflows; this feature does not scan the host or register paths automatically. If the list is empty, register the intended repository through an existing explicit workflow and refresh.
3. Under **Start a task**, select an attached repository, enter an instruction and optionally set a task budget or step limit. A model provider must already be [configured](model-providers.md).
4. Open the task to inspect output and the proposed diff. Command approval remains required by the runner's execution policy; pending commands are available in the main workspace. Review/apply, reject, retry or revert through the project's task screen.
5. Return to the project to see its persisted task history. Refresh returns to the newest tasks; **Load older tasks** continues the cursor. The UI retains a bounded window of 200 loaded tasks and 200 output lines.

One repository may be attached to several projects. Each new run belongs to one explicit project; a rejected run can be retried only within that project and repository. Older tasks stay unassigned. Project ownership is saved with the task and session in one transaction before execution starts. It survives restart, but an interrupted running task is marked failed by existing reconciliation rather than resumed automatically.

Attachment starts no process and preserves its original attachment timestamp when repeated. Task creation has no idempotency key or automatic retry. After a lost response, refresh history before submitting again. The new scoped workflow does not create hosted project membership, project-private repository notes or an execution sandbox.

## Conversations

A project can hold text-only conversations about one attached repository. Each conversation owns a budgeted Farhelm session (default cap 1 USD, settable at creation) and every reply is charged to it through the gateway, so the cap is enforced where the money moves. The assistant answers in prose and cannot edit files or run commands from a conversation; it is told to phrase proposed work as an instruction you can start as a task.

| Request | Result |
| --- | --- |
| `GET /v1/projects/{id}/chats?limit=50&after=<cursor>` | Bounded conversation page, newest first. |
| `POST /v1/projects/{id}/chats` | `{"repo_id","title","budget_usd"?}` → 201 with the conversation detail. The repository must be attached. |
| `GET /v1/projects/{id}/chats/{chat_id}` | Conversation, messages and the latest reply attempt. |
| `POST /v1/projects/{id}/chats/{chat_id}/messages` | `{"content","request_id"}` → 200 with the turn `pending`; the reply is composed detached. Read the conversation again to see it settle. |

Sending a message claims a durable turn before any inference runs. A resend with the same `request_id` and text replays the recorded outcome instead of asking twice; the same id with different text is a 409. Only one reply can be pending per conversation. A reply that fails records why (`failed` with an error), and one that was pending when the runner stopped is marked `interrupted` at the next start and never retried on its own: send a new request. History handed to the model contains completed turns only; the transcript keeps everything. A conversation holds at most 100 messages or 256 KiB; start another when it fills. Without a configured model provider every reply fails with that reason rather than hanging.

## Storage and access

Project names/descriptions remain in the runner's local SQLite database as plaintext, like its existing local metadata. This feature does not copy them into the cloud control plane or add a relay/MCP command. A model call or training job is not part of creating a project.

Migration 0013 initializes one stable local workspace ID: `local:` plus 32 random lowercase hexadecimal characters. Restarting the runner, renaming a machine or rotating a runner credential does not change that scope. The API resolves it from the database and does not accept `workspace_id` from a caller. A separately initialized database starts with a different scope; restoring a backup retains that backup's identity.

Older records in other workspace scopes remain unchanged and are hidden from this API. An apparently empty local Projects page after upgrade does not mean those rows were deleted. Adopting/importing them requires an explicit ownership migration rather than changing their scope manually.

The endpoints use the existing local API token and CORS policy. The shipped runner listens on loopback. These local checks do not implement hosted workspace membership or shared-runner resource authorization. Keep the current listener/security configuration when testing this feature.

## HTTP contract

| Request | Success |
| --- | --- |
| `POST /v1/projects` | 201 with `Project`. Body: `{"name":"Model research","description":"Evaluate local models"}`. `description` may be omitted. |
| `GET /v1/projects?limit=50` | 200 with `{"projects":[...],"next_cursor":null}` or a cursor when more rows exist. |
| `GET /v1/projects?limit=50&after=<cursor>` | 200 with the next page, exclusive of the cursor. |
| `GET /v1/projects/<id>` | 200 with `Project`; 404 for a missing project or an identity belonging to another workspace. |

Creation accepts only `name` and `description`. The runner generates the UUIDv7 ID, local workspace ID and Unix millisecond timestamps. `created_at` and `updated_at` match at creation; `budget_cap_usd` is null. Supplying server-owned fields such as `id`, `workspace_id`, timestamps or budget is rejected.

Names contain 1–120 Unicode scalar values and at most 480 UTF-8 bytes. Whitespace-only names and control characters are rejected; surrounding whitespace is trimmed when saved. Descriptions default to empty, permit at most 4,000 Unicode scalar values / 16,000 UTF-8 bytes, and allow newline and tab while rejecting other controls. Raw HTTP JSON bodies are limited to 24 KiB, including JSON encoding overhead.

List requests accept only `after` and `limit`. Limit defaults to 50 and must be 1–100. Projects are ordered by ID descending, independently of later metadata edits. Treat the returned cursor as opaque: send its exact canonical lowercase hyphenated UUID value. `next_cursor: null` means the page is complete. A project inserted ahead of a cursor appears on refresh; continuing an existing cursor does not repeat it. The query is not a transactionally frozen snapshot.

| Status | Meaning |
| --- | --- |
| 400 | Malformed JSON. |
| 401 | The configured local API token is missing or invalid. |
| 404 | The project is missing or outside the local workspace. |
| 413 | The request body exceeds 24 KiB. |
| 415 | The JSON endpoint received an unsupported content type. |
| 422 | Invalid content, unknown fields or malformed/out-of-range pagination. |
| 429 | All four project-operation slots are in use; try again after existing operations finish. |
| 500 | The project operation or storage failed; internal storage details are withheld. |

Project operations run through bounded blocking execution, separate from async request handling. A cancelled HTTP request does not stop an already scheduled SQLite operation. POST has no idempotency key and is never automatically retried: if a connection fails after submission, refresh Projects and look for the result before creating again. Two deliberate POSTs create two distinct projects even when their names match.

The [workflow HTTP contract](adr/0008-project-agent-workflow.md#http-and-client-boundary) adds repository/task pages and scoped task actions with a separate 128 KiB request-body limit.

## Verification and rollout

From the repository root:

```sh
cargo test --locked -p farhelm-app -p farhelm-sqlite
cargo test --locked -p farhelm-runner --test projects
cargo test --locked -p farhelm-runner --test project_workflow --test local_model_workflow
pnpm --filter @farhelm/client-core test
pnpm --filter @farhelm/web test
```

The Rust checks exercise application/storage rules and real loopback HTTP, including restart persistence and scope isolation. Client tests validate untrusted response shapes; rendered component tests exercise loading, errors, pagination and creation. Browser/native verification remains separate from these checks.

Back up durable databases before upgrading through the normal migration path. Preserve migration history and scope identities during a feature rollback. Schema rollback requires a new planned migration; lowering `user_version`, deleting local workspace rows or running an old binary is not a supported downgrade procedure. See [ADR 0007](adr/0007-local-project-api.md) for the migration rationale and remaining authorization boundaries.
