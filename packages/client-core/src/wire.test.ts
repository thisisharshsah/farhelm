/**
 * The Rust wire contract, read by the TypeScript that claims to mirror it.
 *
 * `api.ts` declares these interfaces **by hand**. Nothing generates them, and
 * until this file nothing checked them, so a renamed field in Rust arrived here
 * as `undefined`: no error on either side, just a screen that quietly stopped
 * showing a number. That is the failure this exists to catch, and it is the same
 * reason `crypto.test.ts` opens a fixture Rust sealed.
 *
 * The fixture is generated from the Rust types
 * (`crates/farhelm-proto/tests/wire_fixture.rs`, run with `-- --ignored`). Rust
 * checks the committed copy still matches what its types produce; this file
 * checks that everything TypeScript expects is actually in it.
 *
 * ## Why the key lists
 *
 * TypeScript types are erased at runtime, so a test cannot ask an interface what
 * its fields are. Each list below is tied to its interface by a compile-time
 * assertion — `Exhaustive<...>` fails to compile if the list omits a key the
 * interface declares. So the list cannot drift from the type, and the runtime
 * check then proves the Rust side still sends every one of them.
 *
 * That gives the pairing teeth in both directions:
 *   - a field TypeScript reads but Rust stopped sending → runtime failure here
 *   - a field added to the interface but never listed    → compile failure here
 *
 * A field Rust adds that TypeScript ignores is deliberately *not* a failure:
 * that is how the wire is allowed to grow without breaking a shipped phone.
 */

import { describe, expect, it } from "vitest";

import fixture from "../../../crates/farhelm-proto/tests/fixtures/wire.json";
import type {
  ApprovalView,
  BudgetView,
  Conversation,
  CreateProjectRequest,
  DashboardView,
  Document,
  EntityKind,
  EntityLink,
  FleetView,
  OutputLine,
  PlanProgress,
  Project,
  ProjectPage,
  ProjectRepository,
  ProjectRepositoryPage,
  ProjectTaskPage,
  AttachProjectRepositoryRequest,
  StartProjectTaskRequest,
  RelationKind,
  SessionDetail,
  SessionView,
  TaskDetail,
  TaskView,
} from "./api.ts";

/**
 * Compiles only when `Listed` covers every key of `T`.
 *
 * `Exclude` leaves the keys the list forgot; requiring that to be `never` turns
 * "you added a field and did not list it" into a type error at this line.
 */
type Exhaustive<T, Listed extends keyof T> = [Exclude<keyof T, Listed>] extends [
  never,
]
  ? true
  : { error: "a key of this interface is missing from the list below"; missing: Exclude<keyof T, Listed> };

const BUDGET_KEYS = ["cap_usd", "spent_usd", "pct", "state"] as const;

const PLAN_PROGRESS_KEYS = [
  "settled",
  "total",
  "current_ordinal",
  "current_title",
] as const;

const SESSION_KEYS = [
  "id",
  "repo_name",
  "machine_name",
  "agent",
  "status",
  "is_live",
  "plan",
  "budget",
  "started_at",
  "ended_at",
  "awaiting_approval_id",
  "auto_approve",
  "repo_auto_approve",
  "repo_id",
] as const;

const APPROVAL_KEYS = [
  "id",
  "session_id",
  "tool",
  "payload",
  "risk",
  "decision",
  "decided_via",
  "requested_at",
  "decided_at",
  "repo_name",
  "allows_watch_decision",
  "budget",
] as const;

const OUTPUT_KEYS = ["seq", "text", "at_ms"] as const;

const FLEET_KEYS = [
  "sessions",
  "pending_approvals",
  "tasks_awaiting_review",
  "today_usd",
  "cache_hit_ratio",
] as const;

const PROJECT_KEYS = [
  "id", "workspace_id", "name", "description", "budget_cap_usd", "created_at", "updated_at",
] as const;
const CONVERSATION_KEYS = ["id", "project_id", "title", "created_at", "updated_at"] as const;
const DOCUMENT_KEYS = [
  "id", "project_id", "title", "content", "content_hash", "version", "created_at", "updated_at",
] as const;
const ENTITY_LINK_KEYS = [
  "id", "source_type", "source_id", "target_type", "target_id", "relation_kind", "created_at",
] as const;
const ENTITY_KINDS = [
  "project", "conversation", "task", "task_run", "document", "artifact", "repo",
] as const;
const RELATION_KINDS = [
  "mentions", "spawns", "blocks", "documents", "produces", "belongs_to",
] as const;

const WORKSPACE_LISTS_ARE_COMPLETE: [
  Exhaustive<Project, (typeof PROJECT_KEYS)[number]>,
  Exhaustive<Conversation, (typeof CONVERSATION_KEYS)[number]>,
  Exhaustive<Document, (typeof DOCUMENT_KEYS)[number]>,
  Exhaustive<EntityLink, (typeof ENTITY_LINK_KEYS)[number]>,
  Exhaustive<Record<EntityKind, unknown>, (typeof ENTITY_KINDS)[number]>,
  Exhaustive<Record<RelationKind, unknown>, (typeof RELATION_KINDS)[number]>,
] = [true, true, true, true, true, true];

/**
 * The compile-time half, collected so the assertions are *used* — an unread
 * `const` trips `noUnusedLocals`, and a check nobody reads is a check that gets
 * deleted. Each entry is `true` only if its list above covers every key of the
 * interface; otherwise this array stops type-checking and names the key that
 * was forgotten.
 */
const LISTS_ARE_COMPLETE: [
  Exhaustive<BudgetView, (typeof BUDGET_KEYS)[number]>,
  Exhaustive<PlanProgress, (typeof PLAN_PROGRESS_KEYS)[number]>,
  Exhaustive<SessionView, (typeof SESSION_KEYS)[number]>,
  Exhaustive<ApprovalView, (typeof APPROVAL_KEYS)[number]>,
  Exhaustive<OutputLine, (typeof OUTPUT_KEYS)[number]>,
  Exhaustive<FleetView, (typeof FLEET_KEYS)[number]>,
] = [true, true, true, true, true, true];

/**
 * First element, or a failure naming what was empty.
 *
 * `noUncheckedIndexedAccess` types `array[0]` as possibly undefined, which is
 * right: a fixture that stopped carrying any sessions should fail here saying
 * so, rather than at a property access three lines later.
 */
function first<T>(items: readonly T[], what: string): T {
  const head = items[0];
  if (head === undefined) {
    throw new Error(`the fixture carries no ${what}`);
  }
  return head;
}

/** Asserts every listed key is present on the object Rust produced. */
function hasEveryKey(
  actual: Record<string, unknown>,
  expected: readonly string[],
  what: string,
): void {
  const missing = expected.filter((key) => !(key in actual));
  expect(
    missing,
    `${what}: the Rust fixture is missing ${missing.join(", ")} — either the ` +
      `field was renamed or removed on the Rust side, or api.ts is describing ` +
      `a shape that no longer exists`,
  ).toEqual([]);
}

describe("the read models Rust sends", () => {
  const fleet = fixture.fleet_view as unknown as FleetView;

  it("lists every key of every interface it checks", () => {
    // Forces `LISTS_ARE_COMPLETE` to be read. The real assertion is the type
    // annotation on it, which fails to compile if a list is short.
    expect(LISTS_ARE_COMPLETE).toEqual([true, true, true, true, true, true]);
  });

  it("carries every field FleetView declares", () => {
    hasEveryKey(fleet as never, FLEET_KEYS, "FleetView");
  });

  it("carries every field SessionView declares", () => {
    const session = first(fleet.sessions, "sessions");
    hasEveryKey(session as never, SESSION_KEYS, "SessionView");
    hasEveryKey(session.budget as never, BUDGET_KEYS, "BudgetView");
    hasEveryKey(session.plan as never, PLAN_PROGRESS_KEYS, "PlanProgress");
  });

  it("carries every field ApprovalView declares, flattened", () => {
    // The Approval is `#[serde(flatten)]`ed into the view, so its own fields sit
    // at the top level rather than under an `approval` key. Losing that flatten
    // would be invisible to a Rust-only test.
    const approval = first(fleet.pending_approvals, "pending approvals");
    hasEveryKey(approval as never, APPROVAL_KEYS, "ApprovalView");
  });

  it("carries every field SessionDetail declares", () => {
    const detail = fixture.session_detail as unknown as SessionDetail;
    // SessionDetail flattens a SessionView, so those keys are top-level too.
    hasEveryKey(detail as never, SESSION_KEYS, "SessionDetail (flattened session)");
    for (const key of ["steps", "output", "pending_approval"]) {
      expect(detail, `SessionDetail is missing ${key}`).toHaveProperty(key);
    }
    hasEveryKey(first(detail.output, "output lines") as never, OUTPUT_KEYS, "OutputLine");
  });

  it("carries the diff a review screen renders", () => {
    const detail = fixture.task_detail as unknown as TaskDetail;
    for (const key of ["changes", "patch", "output"]) {
      expect(detail, `TaskDetail is missing ${key}`).toHaveProperty(key);
    }
    const file = first(detail.changes.files, "changed files");
    for (const key of ["path", "kind", "added", "removed", "hunks", "binary"]) {
      expect(file, `FileDiff is missing ${key}`).toHaveProperty(key);
    }
    const line = first(first(file.hunks, "hunks").lines, "diff lines");
    expect(line).toHaveProperty("tag");
    expect(line).toHaveProperty("text");
  });

  it("carries the dashboard's numbers", () => {
    const dashboard = fixture.dashboard_view as unknown as DashboardView;
    for (const key of [
      "session_id",
      "repo_name",
      "calls",
      "total_usd",
      "cache_hit_ratio",
      "by_tier",
      "avoided_calls",
      "spend_series",
      "budget",
    ]) {
      expect(dashboard, `DashboardView is missing ${key}`).toHaveProperty(key);
    }
  });

  it("carries the task fields a list and a card render", () => {
    const task = first(
      fixture.fleet_view.tasks_awaiting_review,
      "tasks awaiting review",
    ) as unknown as TaskView;
    for (const key of [
      "id",
      "status",
      "change_summary",
      "verify_grade",
      "repo_path",
      "review_note",
    ]) {
      expect(task, `TaskView is missing ${key}`).toHaveProperty(key);
    }
  });
});

describe("the workspace objects Rust sends", () => {
  it("preserves local creation input and pagination, including a terminal empty page", () => {
    const input: CreateProjectRequest = fixture.workspace.create_project;
    const page: ProjectPage = fixture.workspace.project_page;
    const empty: ProjectPage = fixture.workspace.empty_project_page;
    const inputKeys = ["name", "description"] as const;
    const pageKeys = ["projects", "next_cursor"] as const;
    const complete: [Exhaustive<CreateProjectRequest, typeof inputKeys[number]>, Exhaustive<ProjectPage, typeof pageKeys[number]>] = [true, true];
    expect(complete).toEqual([true, true]);
    hasEveryKey(input as never, inputKeys, "CreateProjectRequest");
    hasEveryKey(page as never, pageKeys, "ProjectPage");
    expect(input.name).toBe("Local pilot");
    expect(input.description).toBe("Synthetic local project metadata");
    expect(page.projects).toHaveLength(1);
    expect(page.projects[0]?.budget_cap_usd).toBeNull();
    expect(page.projects[0]?.workspace_id).toBe("local:0123456789abcdef0123456789abcdef");
    expect(page.next_cursor).toBe(page.projects[0]?.id);
    expect(empty).toEqual({ projects: [], next_cursor: null });
  });

  it("covers every DTO key and enum variant declared by TypeScript", () => {
    expect(WORKSPACE_LISTS_ARE_COMPLETE).toEqual([true, true, true, true, true, true]);
    expect(fixture.workspace.entity_kinds).toEqual(ENTITY_KINDS);
    expect(fixture.workspace.relation_kinds).toEqual(RELATION_KINDS);
  });

  it("preserves project fields, numeric budgets and explicit null budgets", () => {
    const project: Project = fixture.workspace.project;
    const uncapped: Project = fixture.workspace.project_without_budget;
    hasEveryKey(project as never, PROJECT_KEYS, "Project");
    hasEveryKey(uncapped as never, PROJECT_KEYS, "Project without a budget");
    expect(project.workspace_id).toBe("workspace-1");
    expect(project.budget_cap_usd).toBe(100);
    expect(uncapped.budget_cap_usd).toBeNull();
    expect(project.updated_at).toBeGreaterThan(project.created_at);
  });

  it("preserves conversation identity, project scope and title", () => {
    const conversation: Conversation = fixture.workspace.conversation;
    hasEveryKey(conversation as never, CONVERSATION_KEYS, "Conversation");
    expect(conversation.project_id).toBe(fixture.workspace.project.id);
    expect(conversation.title).toBe("Discuss retry limits");
    expect(conversation.updated_at).toBeGreaterThan(conversation.created_at);
  });

  it("preserves document content, revision and content hash", () => {
    const document: Document = fixture.workspace.document;
    hasEveryKey(document as never, DOCUMENT_KEYS, "Document");
    expect(document.project_id).toBe(fixture.workspace.project.id);
    expect(document.content).toBe("# Retry policy\nLimit retries to three attempts.");
    expect(document.content_hash).toBe("sha256:fixture-content-hash");
    expect(document.version).toBe(2);
    expect(document.updated_at).toBeGreaterThan(document.created_at);
  });

  it("preserves typed link endpoints and relation spellings", () => {
    // JSON imports infer enum fields as strings. Their complete spellings are
    // checked above; this assignment also checks all remaining field types.
    const link: Omit<EntityLink, "source_type" | "target_type" | "relation_kind"> =
      fixture.workspace.entity_link;
    hasEveryKey(link as never, ENTITY_LINK_KEYS, "EntityLink");
    expect(link.source_id).toBe(fixture.workspace.conversation.id);
    expect(link.target_id).toBe(fixture.workspace.document.id);
    expect(fixture.workspace.entity_link.source_type).toBe("conversation");
    expect(fixture.workspace.entity_link.target_type).toBe("document");
    expect(fixture.workspace.entity_link.relation_kind).toBe("documents");
    expect(link.created_at).toBe(fixture.workspace.document.updated_at);
  });
});

describe("project workflow contracts", () => {
  it("preserves scoped repository and run payloads without changing global tasks", () => {
    const repo: ProjectRepository = fixture.project_workflow.repository;
    const page: ProjectRepositoryPage = fixture.project_workflow.repository_page;
    const attach: AttachProjectRepositoryRequest = fixture.project_workflow.attach_repository;
    const start: StartProjectTaskRequest = fixture.project_workflow.start_task;
    const taskPage: Omit<ProjectTaskPage, "tasks"> = fixture.project_workflow.task_page;
    const repoKeys = ["id", "name", "path"] as const;
    const pageKeys = ["repositories", "next_cursor"] as const;
    const attachKeys = ["repo_id"] as const;
    const startKeys = ["repo_id", "prompt", "budget_usd", "max_steps", "retry_of"] as const;
    const taskPageKeys = ["tasks", "next_cursor"] as const;
    const exhaustive: [
      Exhaustive<ProjectRepository, typeof repoKeys[number]>,
      Exhaustive<ProjectRepositoryPage, typeof pageKeys[number]>,
      Exhaustive<AttachProjectRepositoryRequest, typeof attachKeys[number]>,
      Exhaustive<StartProjectTaskRequest, typeof startKeys[number]>,
      Exhaustive<ProjectTaskPage, typeof taskPageKeys[number]>,
    ] = [true, true, true, true, true];
    expect(exhaustive).toEqual([true, true, true, true, true]);
    hasEveryKey(repo as never, repoKeys, "ProjectRepository");
    hasEveryKey(page as never, pageKeys, "ProjectRepositoryPage");
    hasEveryKey(attach as never, attachKeys, "AttachProjectRepositoryRequest");
    hasEveryKey(start as never, startKeys, "StartProjectTaskRequest");
    hasEveryKey(taskPage as never, taskPageKeys, "ProjectTaskPage");
    expect(page.repositories[0]).toEqual(repo);
    expect(page.next_cursor).toBe(repo.id);
    expect(start.repo_id).toBe(repo.id);
    expect(start).not.toHaveProperty("repo_path");
    expect(fixture.task_detail).toMatchObject(fixture.project_workflow.task_page.tasks[0]!);
    expect(fixture.project_workflow.task_page.tasks[0]).not.toHaveProperty("project_id");
  });
});

describe("the events and commands", () => {
  /**
   * The tags a client switches on. `command_error` is in this list even though
   * no ServerEvent variant produces it: it arrives on the same socket, and a
   * client that does not handle it shows nothing when a command is refused —
   * which is the worst failure a remote control surface can have.
   */
  it("uses the tags the clients switch on", () => {
    const tags = fixture.events.map((event) => event.type);
    expect(tags).toEqual([
      "session_upsert",
      "output_chunk",
      "approval_request",
      "approval_decision",
      "budget_alert",
      "task_upsert",
    ]);
    expect(fixture.command_error.type).toBe("command_error");
    expect(tags).not.toContain("command_error");
  });

  it("flattens an output chunk's line to the top level", () => {
    // `seq`/`text`/`at_ms` sit beside `session_id`, not under a `line` key. The
    // Swift client depends on that and cannot be checked from here any other way.
    const chunk = fixture.events.find((event) => event.type === "output_chunk");
    expect(chunk).toBeDefined();
    hasEveryKey(chunk as never, OUTPUT_KEYS, "output_chunk");
    expect(chunk).not.toHaveProperty("line");
  });

  it("names every command the clients can send", () => {
    expect(fixture.commands.map((command) => command.type)).toEqual([
      "decide",
      "instruct",
      "plan_control",
      "session_snapshot",
      "dashboard_snapshot",
      "review_task",
      "task_snapshot",
      "task_list",
      "revert_task",
      "snapshot",
      "set_auto_approve",
      "set_repo_auto_approve",
    ]);
  });

  it("spells the enums the way api.ts spells them", () => {
    // The storage form and the JSON form are the same string by construction in
    // Rust (`text_enum!`). This is the check that api.ts's union types agree —
    // `claude-code` was once `claude_code` over the wire, and the API could not
    // parse the agent id its own endpoint advertised.
    const session = first(fixture.fleet_view.sessions, "sessions");
    expect(session.agent).toBe("claude-code");
    expect(session.status).toBe("awaiting_approval");
    expect(session.budget.state).toBe("warn");

    const approval = first(fixture.fleet_view.pending_approvals, "approvals");
    expect(approval.risk).toBe("destructive");
    expect(approval.decision).toBe("denied");
    expect(approval.decided_via).toBe("phone");

    expect(
      first(fixture.fleet_view.tasks_awaiting_review, "tasks").status,
    ).toBe("awaiting_review");
  });
});
