import type {
  Project, ProjectPage, ProjectRepository, ProjectRepositoryPage, ProjectTaskPage,
  TaskView, TaskDetail,
} from "./api.ts";

const MAX_DESCRIPTION_BYTES = 16_000;
const MAX_PAGE_SIZE = 100;

function object(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function identifier(value: unknown): value is string {
  return typeof value === "string" && value.length > 0
    && new TextEncoder().encode(value).length <= 128 && !/\p{Cc}/u.test(value);
}

function timestamp(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

/** Validate only fields this client uses; additional server fields stay compatible. */
export function isProject(value: unknown): value is Project {
  if (!object(value)) return false;
  return identifier(value.id) && identifier(value.workspace_id)
    && typeof value.name === "string" && value.name.trim().length > 0
    && Array.from(value.name).length <= 120
    && typeof value.description === "string"
    && Array.from(value.description).length <= 4_000
    && new TextEncoder().encode(value.description).length <= MAX_DESCRIPTION_BYTES
    && (value.budget_cap_usd === null || (typeof value.budget_cap_usd === "number"
      && Number.isFinite(value.budget_cap_usd) && value.budget_cap_usd >= 0))
    && timestamp(value.created_at) && timestamp(value.updated_at);
}

export function parseProject(value: unknown): Project {
  if (!isProject(value)) throw new Error("The runner returned an invalid project.");
  return value;
}

export function parseProjectPage(value: unknown): ProjectPage {
  if (!object(value) || !Array.isArray(value.projects)) {
    throw new Error("The runner returned an invalid project list.");
  }
  const projects = value.projects;
  if (projects.length > MAX_PAGE_SIZE || !projects.every(isProject)) {
    throw new Error("The runner returned an invalid project list.");
  }
  const cursor = value.next_cursor;
  if (!(cursor === null || identifier(cursor))
    || (cursor !== null && cursor !== projects.at(-1)?.id)
    || projects.some((project) => project.workspace_id !== projects[0]?.workspace_id)
    || new Set(projects.map((project) => project.id)).size !== projects.length) {
    throw new Error("The runner returned an invalid project list.");
  }
  return { projects, next_cursor: cursor };
}

function text(value: unknown, max = 1_048_576): value is string {
  return typeof value === "string" && value.length <= max;
}

function nullableText(value: unknown): value is string | null {
  return value === null || text(value);
}

function nonnegative(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0;
}

function oneOf(value: unknown, values: readonly string[]): boolean {
  return typeof value === "string" && values.includes(value);
}

function nullableTimestamp(value: unknown): boolean {
  return value === null || timestamp(value);
}

export function parseProjectRepository(value: unknown): ProjectRepository {
  if (!object(value) || !identifier(value.id) || !text(value.name, 4_096) || !value.name
    || !text(value.path, 32_768) || !value.path || /\p{Cc}/u.test(value.path)) {
    throw new Error("The runner returned an invalid project repository.");
  }
  return { id: value.id, name: value.name, path: value.path };
}

function pageCursor<T extends { id: string }>(items: T[], cursor: unknown): string | null {
  if (!(cursor === null || identifier(cursor))
    || (cursor !== null && cursor !== items.at(-1)?.id)
    || new Set(items.map((item) => item.id)).size !== items.length) {
    throw new Error("The runner returned an invalid project page cursor.");
  }
  return cursor;
}

export function parseProjectRepositoryPage(value: unknown): ProjectRepositoryPage {
  if (!object(value) || !Array.isArray(value.repositories) || value.repositories.length > MAX_PAGE_SIZE) {
    throw new Error("The runner returned an invalid project repository list.");
  }
  const repositories = value.repositories.map(parseProjectRepository);
  return { repositories, next_cursor: pageCursor(repositories, value.next_cursor) };
}

export function isTaskView(value: unknown): value is TaskView {
  if (!object(value)) return false;
  return identifier(value.id) && identifier(value.session_id) && identifier(value.repo_id)
    && text(value.repo_name, 4_096) && text(value.repo_path, 32_768)
    && text(value.prompt, 65_536) && text(value.summary) && text(value.change_summary, 4_096)
    && oneOf(value.status, ["running", "awaiting_review", "applied", "rejected", "no_changes", "failed", "reverted"])
    && timestamp(value.files_changed) && timestamp(value.lines_added) && timestamp(value.lines_removed)
    && timestamp(value.steps) && nonnegative(value.cost_usd)
    && nullableText(value.error) && nullableText(value.review_note)
    && (value.verify_grade === null || oneOf(value.verify_grade, ["pass", "concerns", "fail"]))
    && nullableText(value.verify_notes) && nullableText(value.verify_model)
    && (value.decided_via === null || oneOf(value.decided_via, ["watch", "phone", "web", "auto_policy"]))
    && timestamp(value.created_at) && timestamp(value.updated_at) && nullableTimestamp(value.decided_at);
}

export function parseTaskView(value: unknown): TaskView {
  if (!isTaskView(value)) throw new Error("The runner returned an invalid project task.");
  return value;
}

export function parseProjectTaskPage(value: unknown): ProjectTaskPage {
  if (!object(value) || !Array.isArray(value.tasks) || value.tasks.length > MAX_PAGE_SIZE) {
    throw new Error("The runner returned an invalid project task list.");
  }
  const tasks = value.tasks.map(parseTaskView);
  return { tasks, next_cursor: pageCursor(tasks, value.next_cursor) };
}

/** Bound the diff and output before a review screen iterates untrusted JSON. */
export function parseTaskDetail(value: unknown): TaskDetail {
  if (!isTaskView(value) || !object(value)) throw new Error("The runner returned an invalid project task detail.");
  const detail = value as TaskView & Record<string, unknown>;
  if (!text(detail.patch, 16 * 1_048_576) || !object(detail.changes) || !Array.isArray(detail.changes.files)
    || detail.changes.files.length > 2_000 || !Array.isArray(detail.output) || detail.output.length > 200) {
    throw new Error("The runner returned an invalid project task detail.");
  }
  let lines = 0;
  let hunks = 0;
  let characters = detail.patch.length;
  for (const file of detail.changes.files as unknown[]) {
    if (!object(file) || !text(file.path, 32_768) || !oneOf(file.kind, ["added", "modified", "deleted"])
      || !timestamp(file.added) || !timestamp(file.removed) || typeof file.binary !== "boolean"
      || !Array.isArray(file.hunks)) throw new Error("The runner returned an invalid project diff.");
    hunks += file.hunks.length;
    if (hunks > 10_000) throw new Error("The project diff is too large to display.");
    for (const hunk of file.hunks as unknown[]) {
      if (!object(hunk) || !timestamp(hunk.old_start) || !timestamp(hunk.old_len)
        || !timestamp(hunk.new_start) || !timestamp(hunk.new_len) || !Array.isArray(hunk.lines)) {
        throw new Error("The runner returned an invalid project diff.");
      }
      lines += hunk.lines.length;
      if (lines > 50_000) throw new Error("The project diff is too large to display.");
      for (const line of hunk.lines as unknown[]) {
        if (!object(line) || !oneOf(line.tag, ["context", "add", "remove"]) || !text(line.text, 1_048_576)) {
          throw new Error("The runner returned an invalid project diff.");
        }
        characters += line.text.length;
      }
    }
  }
  if (characters > 32 * 1_048_576) throw new Error("The project diff is too large to display.");
  const sequences = new Set<number>();
  for (const line of detail.output as unknown[]) {
    if (!object(line) || !timestamp(line.seq) || !timestamp(line.at_ms) || !text(line.text)
      || sequences.has(line.seq)) throw new Error("The runner returned invalid project task output.");
    sequences.add(line.seq);
  }
  return detail as unknown as TaskDetail;
}
