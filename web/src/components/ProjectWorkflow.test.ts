import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { ProjectTaskPage, ServerEvent, TaskDetail, Transport } from "@farhelm/client-core";
import { ProjectTaskScreen, ProjectWorkflow } from "./ProjectWorkflow";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
let host: HTMLDivElement;
let root: Root;
const repo = { id: "registered-repo", name: "Workspace", path: "/synthetic/workspace" };
function task(id = "task-one", status: TaskDetail["status"] = "running"): TaskDetail {
  return { id, session_id: `session-${id}`, repo_id: repo.id, repo_name: repo.name, repo_path: repo.path,
    prompt: "Implement synthetic change", status, summary: "Synthetic summary", files_changed: 1, lines_added: 1, lines_removed: 0,
    change_summary: "1 file, +1", steps: 1, cost_usd: 0, error: null, review_note: null, verify_grade: null,
    verify_notes: null, verify_model: null, decided_via: null, created_at: 1, updated_at: 2, decided_at: null,
    changes: { files: [] }, patch: "", output: [] };
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (cause: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function runner(overrides: Partial<Transport> = {}) {
  const listeners = new Set<(event: ServerEvent) => void>();
  const transport = {
    kind: "loopback", supportsProjectWorkflow: true,
    projectRepositories: vi.fn().mockResolvedValue({ repositories: [repo], next_cursor: null }),
    projectRepoCandidates: vi.fn().mockResolvedValue({ repositories: [{ ...repo, id: "candidate", name: "Candidate" }], next_cursor: null }),
    attachProjectRepository: vi.fn().mockResolvedValue({ ...repo, id: "candidate" }),
    projectTasks: vi.fn().mockResolvedValue({ tasks: [], next_cursor: null }),
    startProjectTask: vi.fn().mockResolvedValue(task("started")),
    projectTask: vi.fn().mockResolvedValue(task()),
    reviewProjectTask: vi.fn().mockResolvedValue(task("task-one", "applied")),
    revertProjectTask: vi.fn().mockResolvedValue(task("task-one", "reverted")),
    onEvent: (listener: (event: ServerEvent) => void) => { listeners.add(listener); return () => { listeners.delete(listener); }; },
    startTask: vi.fn(), reviewTask: vi.fn(), revertTask: vi.fn(), task: vi.fn(),
    ...overrides,
  } as unknown as Transport;
  return { transport, emit: (event: ServerEvent) => { for (const listener of listeners) listener(event); } };
}
async function render(transport: Transport | null, projectId = "project-one", taskId: string | null = null, onNavigate = vi.fn()) {
  await act(async () => root.render(taskId === null
    ? createElement(ProjectWorkflow, { transport, projectId, onNavigate })
    : createElement(ProjectTaskScreen, { transport, projectId, taskId, onNavigate })));
  return onNavigate;
}
it("makes the command approval queue reachable while a project task is running", async () => {
  const { transport } = runner();
  const navigate = await render(transport, "project-one", "task-one");
  expect(host.querySelector('[aria-label="Command approval location"]')?.textContent).toContain("project context");
  await act(async () => button("Open Workspace approvals").click());
  expect(navigate).toHaveBeenCalledExactlyOnceWith("/");
});

function button(text: string, index = 0): HTMLButtonElement {
  const found = Array.from(host.querySelectorAll("button")).filter((node) => node.textContent === text)[index];
  if (!found) throw new Error(`No button ${text}`);
  return found;
}
async function field(selector: string, value: string) {
  const node = host.querySelector<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>(selector)!;
  await act(async () => {
    if (node instanceof HTMLSelectElement) { node.value = value; node.dispatchEvent(new Event("change", { bubbles: true })); }
    else {
      const prototype = node instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(prototype, "value")!.set!.call(node, value);
      node.dispatchEvent(new Event("input", { bubbles: true }));
    }
  });
}
async function submit(label: string, times = 1) {
  const section = host.querySelector(`[aria-label="${label}"]`)!;
  await act(async () => {
    for (let index = 0; index < times; index++) section.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  });
}
beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(async () => { await act(async () => root.unmount()); host.remove(); vi.useRealTimers(); });

it("keeps project workflow unavailable over relay without global route fallback", async () => {
  const { transport } = runner({ kind: "relay", supportsProjectWorkflow: false });
  await render(transport);
  expect(host.textContent).toContain("Connect directly to a compatible runner");
  expect(transport.projectRepositories).not.toHaveBeenCalled();
  expect(transport.startTask).not.toHaveBeenCalled();
});

it("shows actual attached and candidate repositories and guards duplicate attachment", async () => {
  const attach = deferred<typeof repo>();
  const attachProjectRepository = vi.fn().mockReturnValue(attach.promise);
  const { transport } = runner({ attachProjectRepository });
  await render(transport);
  expect(host.textContent).toContain(repo.path);
  expect(transport.projectRepositories).toHaveBeenCalledWith("project-one", { limit: 50 });
  await field("#project-attach-repo", "candidate");
  await submit("Project repositories", 2);
  expect(attachProjectRepository).toHaveBeenCalledExactlyOnceWith("project-one", "candidate");
  expect(button("Attaching…").disabled).toBe(true);
  await act(async () => attach.resolve({ ...repo, id: "candidate" }));
  expect(transport.projectRepositories).toHaveBeenCalledTimes(2);
  expect(transport.projectRepoCandidates).toHaveBeenCalledTimes(2);
});

it("starts by attached repository ID, preserves project review route and prevents duplicate submits", async () => {
  const started = deferred<TaskDetail>();
  const startProjectTask = vi.fn().mockReturnValue(started.promise);
  const { transport } = runner({ startProjectTask });
  const onNavigate = await render(transport);
  await field("#project-task-repo", repo.id);
  await field("#project-task-prompt", "  Implement this change  ");
  await field("#project-task-budget", "1.5");
  await field("#project-task-steps", "4");
  await submit("Start a project task", 2);
  expect(startProjectTask).toHaveBeenCalledExactlyOnceWith("project-one", { repo_id: repo.id, prompt: "Implement this change", budget_usd: 1.5, max_steps: 4 });
  expect(host.querySelector<HTMLFieldSetElement>("[aria-label='Start a project task'] fieldset")?.disabled).toBe(true);
  expect(onNavigate).not.toHaveBeenCalled();
  await act(async () => started.resolve(task("created")));
  expect(onNavigate).toHaveBeenCalledExactlyOnceWith("/p/project-one/t/created");
  expect(transport.startTask).not.toHaveBeenCalled();
});

it("reports start errors, retains the instruction, and does not retry automatically", async () => {
  const startProjectTask = vi.fn().mockRejectedValue(new Error("Provider is not configured"));
  const { transport } = runner({ startProjectTask });
  const navigate = await render(transport);
  await field("#project-task-repo", repo.id); await field("#project-task-prompt", "Keep this instruction");
  await submit("Start a project task");
  expect(host.querySelector<HTMLInputElement>("#project-task-prompt")?.value).toBe("Keep this instruction");
  expect(host.textContent).toContain("Provider is not configured");
  expect(startProjectTask).toHaveBeenCalledTimes(1); expect(navigate).not.toHaveBeenCalled();
});

it("does not carry drafts, late list data or late start navigation into another project or runner", async () => {
  const pendingTasks = deferred<ProjectTaskPage>();
  const started = deferred<TaskDetail>();
  const first = runner({ projectTasks: vi.fn().mockReturnValue(pendingTasks.promise), startProjectTask: vi.fn().mockReturnValue(started.promise) });
  const navigate = await render(first.transport);
  await field("#project-task-repo", repo.id); await field("#project-task-prompt", "Private project instruction");
  await submit("Start a project task");
  const second = runner();
  await render(second.transport, "project-two", null, navigate);
  expect(host.querySelector<HTMLTextAreaElement>("#project-task-prompt")?.value).toBe("");
  await act(async () => { pendingTasks.resolve({ tasks: [task("private")], next_cursor: null }); started.resolve(task("old-start")); });
  expect(host.textContent).not.toContain("Private project instruction"); expect(navigate).not.toHaveBeenCalled();
  expect(second.transport.projectTasks).toHaveBeenCalledWith("project-two", { limit: 50 });
});

it("loads project task history with scoped cursors and keeps failures explicit", async () => {
  const projectTasks = vi.fn().mockResolvedValueOnce({ tasks: [task("newer")], next_cursor: "newer" })
    .mockRejectedValueOnce(new Error("History unavailable"))
    .mockResolvedValueOnce({ tasks: [task("older")], next_cursor: null });
  const { transport } = runner({ projectTasks });
  const navigate = await render(transport);
  await act(async () => button("Load older tasks").click());
  expect(host.textContent).toContain("History unavailable");
  expect(host.textContent).toContain("Showing previously loaded tasks");
  await act(async () => button("Load older tasks").click());
  expect(projectTasks).toHaveBeenLastCalledWith("project-one", { after: "newer", limit: 50 });
  expect(host.querySelectorAll(".task-row")).toHaveLength(2);
  await act(async () => host.querySelector<HTMLButtonElement>(".task-row")!.click());
  expect(navigate).toHaveBeenCalledWith("/p/project-one/t/newer");
});

it("reviews and reverts only through nested project endpoints", async () => {
  const review = deferred<TaskDetail>();
  const reviewProjectTask = vi.fn().mockReturnValue(review.promise);
  const { transport } = runner({ projectTask: vi.fn().mockResolvedValue(task("task-one", "awaiting_review")), reviewProjectTask });
  await render(transport, "project-one", "task-one");
  await act(async () => { button("Apply to disk").click(); button("Apply to disk").click(); });
  expect(reviewProjectTask).toHaveBeenCalledExactlyOnceWith("project-one", "task-one", "approve", undefined);
  await act(async () => review.resolve(task("task-one", "applied")));
  expect(transport.reviewTask).not.toHaveBeenCalled();
  const applied = runner({ projectTask: vi.fn().mockResolvedValue(task("applied", "applied")) });
  await render(applied.transport, "project-one", "applied");
  await act(async () => button("Undo this change").click());
  expect(applied.transport.revertProjectTask).toHaveBeenCalledExactlyOnceWith("project-one", "applied");
  expect(applied.transport.revertTask).not.toHaveBeenCalled();
});

it("retries rejected tasks by registered repo ID and retains project context", async () => {
  const { transport } = runner({ projectTask: vi.fn().mockResolvedValue(task("rejected", "rejected")) });
  const navigate = await render(transport, "project-one", "rejected");
  await act(async () => button("Try again").click());
  expect(transport.startProjectTask).toHaveBeenCalledExactlyOnceWith("project-one", {
    repo_id: repo.id, prompt: "Implement synthetic change", budget_usd: undefined, retry_of: "rejected",
  });
  expect(navigate).toHaveBeenCalledExactlyOnceWith("/p/project-one/t/started");
  expect(transport.startTask).not.toHaveBeenCalled();
});

it("retains SSE output arriving during an HTTP detail refresh and bounds the tail to 200", async () => {
  const refresh = deferred<TaskDetail>();
  const projectTask = vi.fn().mockResolvedValueOnce(task()).mockReturnValueOnce(refresh.promise);
  const connection = runner({ projectTask });
  await render(connection.transport, "project-one", "task-one");
  await act(async () => button("Refresh task").click());
  await act(async () => {
    for (let seq = 0; seq < 205; seq++) connection.emit({ type: "output_chunk", session_id: "session-task-one", seq, text: `live-${seq}`, at_ms: seq });
    connection.emit({ type: "output_chunk", session_id: "another-session", seq: 999, text: "Foreign output", at_ms: 1 });
  });
  await act(async () => refresh.resolve({ ...task(), output: [{ seq: 0, text: "older HTTP output", at_ms: 0 }] }));
  expect(host.querySelectorAll(".output-line")).toHaveLength(200);
  expect(host.textContent).toContain("live-204"); expect(host.textContent).not.toContain("live-4live-5");
  expect(host.textContent).not.toContain("Foreign output"); expect(host.textContent).not.toContain("older HTTP output");
});

it("ignores old detail after switching the task scope", async () => {
  const pending = deferred<TaskDetail>();
  const first = runner({ projectTask: vi.fn().mockReturnValue(pending.promise) });
  await render(first.transport, "project-one", "private");
  const second = runner({ projectTask: vi.fn().mockResolvedValue(task("second")) });
  await render(second.transport, "project-two", "second");
  await act(async () => pending.resolve({ ...task("private"), prompt: "Private old task" }));
  expect(host.textContent).not.toContain("Private old task"); expect(host.textContent).toContain("Implement synthetic change");
});

it("ignores late retry navigation after changing the task on the same runner and project", async () => {
  const retry = deferred<TaskDetail>();
  const connection = runner({
    projectTask: vi.fn().mockResolvedValueOnce(task("rejected", "rejected")).mockResolvedValueOnce(task("second")),
    startProjectTask: vi.fn().mockReturnValue(retry.promise),
  });
  const navigate = await render(connection.transport, "project-one", "rejected");
  await act(async () => button("Try again").click());
  await render(connection.transport, "project-one", "second", navigate);
  await act(async () => retry.resolve(task("old-retry")));
  expect(navigate).not.toHaveBeenCalled();
  expect(connection.transport.projectTask).toHaveBeenLastCalledWith("project-one", "second");
});

it("clears drafts when only the runner changes and when only the project changes", async () => {
  const first = runner();
  await render(first.transport);
  await field("#project-task-prompt", "Runner private draft");
  const second = runner();
  await render(second.transport);
  expect(host.querySelector<HTMLTextAreaElement>("#project-task-prompt")?.value).toBe("");
  await field("#project-task-prompt", "Project private draft");
  await render(second.transport, "other-project");
  expect(host.querySelector<HTMLTextAreaElement>("#project-task-prompt")?.value).toBe("");
});

it("keeps attachment errors truthful and retains the selected registered repository", async () => {
  const attachment = vi.fn().mockRejectedValue(new Error("Repository is no longer registered"));
  const { transport } = runner({ attachProjectRepository: attachment });
  await render(transport);
  await field("#project-attach-repo", "candidate");
  await submit("Project repositories");
  expect(host.textContent).toContain("Repository is no longer registered");
  expect(host.querySelector<HTMLSelectElement>("#project-attach-repo")?.value).toBe("candidate");
  expect(attachment).toHaveBeenCalledTimes(1);
  expect(transport.projectRepositories).toHaveBeenCalledTimes(1);
});

it("validates explicit execution limits before starting a task", async () => {
  const { transport } = runner();
  await render(transport);
  await field("#project-task-repo", repo.id); await field("#project-task-prompt", "Synthetic instruction");
  await field("#project-task-budget", "-1");
  await submit("Start a project task");
  expect(host.textContent).toContain("budget must be a positive amount");
  await field("#project-task-budget", ""); await field("#project-task-steps", "257");
  await submit("Start a project task");
  expect(host.textContent).toContain("step limit must be between 1 and 256");
  expect(transport.startProjectTask).not.toHaveBeenCalled();
});

it("coalesces task events into a bounded scoped history refresh", async () => {
  vi.useFakeTimers();
  const connection = runner();
  await render(connection.transport);
  await act(async () => {
    for (let index = 0; index < 30; index++) connection.emit({ type: "task_upsert", task_id: `task-${index}`, session_id: "synthetic", status: "running", summary: "" });
    await vi.advanceTimersByTimeAsync(249);
  });
  expect(connection.transport.projectTasks).toHaveBeenCalledTimes(1);
  await act(async () => vi.advanceTimersByTimeAsync(1));
  expect(connection.transport.projectTasks).toHaveBeenCalledTimes(2);
  expect(connection.transport.projectTasks).toHaveBeenLastCalledWith("project-one", { limit: 50 });
});

it("bounds retained task rows while allowing the cursor to reach older tasks", async () => {
  let page = 0;
  const projectTasks = vi.fn().mockImplementation(() => {
    const start = page++ * 50;
    const tasks = Array.from({ length: 50 }, (_, index) => ({ ...task(`task-${start + index}`), prompt: `Instruction number ${start + index}.` }));
    return Promise.resolve({ tasks, next_cursor: tasks.at(-1)!.id });
  });
  const { transport } = runner({ projectTasks });
  await render(transport);
  for (let index = 0; index < 4; index++) await act(async () => button("Load older tasks").click());
  expect(host.querySelectorAll(".task-row")).toHaveLength(200);
  expect(host.textContent).not.toContain("Instruction number 0.");
  expect(host.textContent).toContain("Instruction number 249.");
  expect(button("Load older tasks").disabled).toBe(false);
});
