import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { Project, Transport, WorkItemDetail, WorkItemPage } from "@farhelm/client-core";
import { WorkBoard, WorkItemScreen, WorkOverview, type BoardTransport } from "./WorkBoard";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

let host: HTMLDivElement;
let root: Root;
const repositories = [{ id: "repo", name: "Synthetic repository", path: "/synthetic/repo" }];

function task(id: string, title = id, projectId = "project"): WorkItemDetail {
  return {
    id, project_id: projectId, title, description: `Description for ${title}`, status: "todo",
    repo_id: "repo", conversation_id: null, created_at: 1000, updated_at: 2000,
    latest_run: null, runs: [],
  };
}

function project(id: string, name: string): Project {
  return { id, name, workspace_id: "synthetic", description: "", budget_cap_usd: null, created_at: 1000, updated_at: 2000 };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (cause: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function runner(overrides: Partial<Transport> = {}): BoardTransport {
  return {
    kind: "loopback", onEvent: vi.fn(() => vi.fn()),
    projects: vi.fn().mockResolvedValue({ projects: [project("project", "Synthetic project")], next_cursor: null }),
    projectWorkItems: vi.fn().mockResolvedValue({ items: [task("a", "Task A")], next_cursor: null }),
    projectWorkItem: vi.fn().mockImplementation((_project: string, id: string) => Promise.resolve(task(id, `Task ${id.toUpperCase()}`))),
    updateProjectWorkItem: vi.fn().mockResolvedValue(task("a", "Saved task")),
    createProjectWorkItem: vi.fn(), startWorkItemRun: vi.fn(),
    ...overrides,
  } as unknown as BoardTransport;
}

function button(text: string): HTMLButtonElement {
  const found = Array.from(host.querySelectorAll("button")).find((node) => node.textContent?.trim() === text);
  if (!found) throw new Error(`Missing button: ${text}`);
  return found;
}

async function input(selector: string, value: string) {
  const node = host.querySelector<HTMLInputElement>(selector)!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(node, value);
    node.dispatchEvent(new Event("input", { bubbles: true }));
  });
}

async function select(selector: string, value: string, count = 1) {
  const node = host.querySelector<HTMLSelectElement>(selector)!;
  await act(async () => {
    for (let i = 0; i < count; i += 1) {
      node.value = value;
      node.dispatchEvent(new Event("change", { bubbles: true }));
    }
  });
}

async function detail(transport: BoardTransport, itemId: string) {
  await act(async () => root.render(createElement(WorkItemScreen, {
    transport, projectId: "project", itemId, repositories, onNavigate: vi.fn(),
  })));
}

async function board(transport: BoardTransport) {
  await act(async () => root.render(createElement(WorkBoard, {
    transport, projectId: "project", repositories, onNavigate: vi.fn(),
  })));
}

async function overview(transport: BoardTransport) {
  await act(async () => root.render(createElement(WorkOverview, { transport, onNavigate: vi.fn() })));
}

function columnOf(title: string) {
  const node = Array.from(host.querySelectorAll(".work-item-title")).find((node) => node.textContent === title);
  return node?.closest(".kanban-column")?.getAttribute("aria-label");
}

beforeEach(() => {
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});

afterEach(async () => {
  await act(async () => root.unmount());
  host.remove();
  vi.restoreAllMocks();
});

it("drops the previous task draft while the next task is loading", async () => {
  const next = deferred<WorkItemDetail>();
  const transport = runner({ projectWorkItem: vi.fn().mockResolvedValueOnce(task("a", "Task A")).mockReturnValueOnce(next.promise) });
  await detail(transport, "a");
  await input("#edit-item-title", "Unsaved A draft");
  await detail(transport, "b");
  expect(host.querySelector("#edit-item-title")).toBeNull();
  expect(host.textContent).toContain("Loading task");
  await act(async () => next.resolve(task("b", "Task B")));
  expect(host.querySelector<HTMLInputElement>("#edit-item-title")?.value).toBe("Task B");
  expect(host.querySelector<HTMLTextAreaElement>("#edit-item-description")?.value).toBe("Description for Task B");
  expect(transport.updateProjectWorkItem).not.toHaveBeenCalled();
});

it("ignores an old task fetch and an old save after navigation", async () => {
  const oldRead = deferred<WorkItemDetail>();
  const oldSave = deferred<WorkItemDetail>();
  const transport = runner({
    projectWorkItem: vi.fn().mockReturnValueOnce(oldRead.promise).mockResolvedValueOnce(task("b", "Task B")).mockResolvedValueOnce(task("a", "Task A")),
    updateProjectWorkItem: vi.fn().mockReturnValue(oldSave.promise),
  });
  await detail(transport, "a");
  await detail(transport, "b");
  await act(async () => oldRead.resolve(task("a", "Late A")));
  expect(host.querySelector<HTMLInputElement>("#edit-item-title")?.value).toBe("Task B");
  await input("#edit-item-title", "Saved B");
  await act(async () => button("Save").click());
  await detail(transport, "a");
  await act(async () => oldSave.resolve(task("b", "Saved B")));
  expect(host.querySelector<HTMLInputElement>("#edit-item-title")?.value).toBe("Task A");
});

it("resets a task editor when the runner changes even for identical resource IDs", async () => {
  const first = runner();
  const second = runner({ projectWorkItem: vi.fn().mockResolvedValue(task("a", "Other runner task")) });
  await detail(first, "a");
  await input("#edit-item-title", "Private first runner draft");
  await detail(second, "a");
  expect(host.querySelector<HTMLInputElement>("#edit-item-title")?.value).toBe("Other runner task");
  expect(host.textContent).not.toContain("Private first runner draft");
});

it("keeps a status move pending in its confirmed column and suppresses duplicate submissions", async () => {
  const saved = deferred<WorkItemDetail>();
  const transport = runner({ updateProjectWorkItem: vi.fn().mockReturnValue(saved.promise) });
  await board(transport);
  await select('select[aria-label="Status of Task A"]', "done", 2);
  expect(transport.updateProjectWorkItem).toHaveBeenCalledExactlyOnceWith("project", "a", { status: "done" });
  expect(columnOf("Task A")).toBe("To do");
  expect(host.querySelector<HTMLSelectElement>('[aria-label="Status of Task A"]')?.disabled).toBe(true);
  expect(host.textContent).toContain("Saving status");
  // A server-authoritative transition may differ from the requested status.
  await act(async () => saved.resolve({ ...task("a", "Task A"), status: "review" }));
  expect(columnOf("Task A")).toBe("Review");
  expect(host.querySelector<HTMLSelectElement>('[aria-label="Status of Task A"]')?.disabled).toBe(false);
});

it("preserves the confirmed status and surfaces rejected moves", async () => {
  const saved = deferred<WorkItemDetail>();
  await board(runner({ updateProjectWorkItem: vi.fn().mockReturnValue(saved.promise) }));
  await select('select[aria-label="Status of Task A"]', "done");
  await act(async () => saved.reject(new Error("A run is still active")));
  expect(columnOf("Task A")).toBe("To do");
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("A run is still active");
  expect(host.querySelector<HTMLSelectElement>('[aria-label="Status of Task A"]')?.value).toBe("todo");
});

it("does not let an older refresh overwrite a confirmed move", async () => {
  const refresh = deferred<WorkItemPage>();
  const saved = deferred<WorkItemDetail>();
  const transport = runner({
    projectWorkItems: vi.fn().mockResolvedValueOnce({ items: [task("a", "Task A")], next_cursor: null }).mockReturnValueOnce(refresh.promise),
    updateProjectWorkItem: vi.fn().mockReturnValueOnce(saved.promise),
  });
  await board(transport);
  await act(async () => button("Refresh").click());
  await select('select[aria-label="Status of Task A"]', "done");
  await act(async () => saved.resolve({ ...task("a", "Task A"), status: "done" }));
  await act(async () => refresh.resolve({ items: [task("a", "Task A")], next_cursor: null }));
  expect(columnOf("Task A")).toBe("Done");
});

it("filters tasks by search and project, then restores results when filters clear", async () => {
  const transport = runner({
    projects: vi.fn().mockResolvedValue({ projects: [project("one", "First project"), project("two", "Second project")], next_cursor: "more-projects" }),
    projectWorkItems: vi.fn().mockImplementation((id: string) => Promise.resolve({ items: [task(id, id === "one" ? "Fix search" : "Update filters", id)], next_cursor: null })),
  });
  await overview(transport);
  expect(host.querySelectorAll(".work-item-title")).toHaveLength(2);
  expect(host.textContent).toContain("Some tasks are not loaded");
  await input('input[type="search"]', "Fix search");
  expect(host.querySelectorAll(".work-item-title")).toHaveLength(1);
  await select('[aria-label="Filter tasks by project"]', "two");
  expect(host.querySelectorAll(".work-item-title")).toHaveLength(0);
  expect(host.textContent).toContain("No matching tasks");
  await act(async () => button("Clear filters").click());
  expect(host.querySelectorAll(".work-item-title")).toHaveLength(2);
  expect(host.querySelector<HTMLInputElement>('input[type="search"]')?.value).toBe("");
});

it("clears overview data and filters on runner changes and ignores late old mutations", async () => {
  const saved = deferred<WorkItemDetail>();
  const next = deferred<WorkItemPage>();
  const first = runner({ updateProjectWorkItem: vi.fn().mockReturnValue(saved.promise) });
  const second = runner({ projectWorkItems: vi.fn().mockReturnValue(next.promise) });
  await overview(first);
  await input('input[type="search"]', "Task A");
  await select('select[aria-label="Status of Task A"]', "done");
  await overview(second);
  expect(host.querySelectorAll(".work-item-title")).toHaveLength(0);
  expect(host.querySelector<HTMLInputElement>('input[type="search"]')?.value).toBe("");
  await act(async () => saved.resolve({ ...task("a", "Late old runner task"), status: "done" }));
  expect(host.textContent).not.toContain("Late old runner task");
  await act(async () => next.resolve({ items: [task("a", "Other runner task")], next_cursor: null }));
  expect(columnOf("Other runner task")).toBe("To do");
});

it("preserves successful projects when another fails and recovers on refresh", async () => {
  const fetchTasks = vi.fn().mockImplementation((id: string) => id === "one"
    ? Promise.resolve({ items: [task("one", "Available task", "one")], next_cursor: null })
    : Promise.reject(new Error("Unavailable project")));
  const transport = runner({
    projects: vi.fn().mockResolvedValue({ projects: [project("one", "Available"), project("two", "Unavailable")], next_cursor: null }),
    projectWorkItems: fetchTasks,
  });
  await overview(transport);
  expect(columnOf("Available task")).toBe("To do");
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("Could not load 1 project; showing available tasks");
  expect(host.textContent).not.toContain("No tasks in");
  expect(Array.from(host.querySelector<HTMLSelectElement>('[aria-label="Filter tasks by project"]')!.options).map((option) => option.value)).toEqual(["", "one"]);
  fetchTasks.mockResolvedValue({ items: [], next_cursor: null });
  await act(async () => button("Refresh").click());
  expect(host.querySelector('[role="alert"]')).toBeNull();
  expect(host.textContent).toContain("No tasks in the loaded projects");
});

it("loads project tasks with at most two concurrent requests", async () => {
  const requests = Array.from({ length: 5 }, () => deferred<WorkItemPage>());
  let active = 0;
  let peak = 0;
  const fetchTasks = vi.fn().mockImplementation((id: string) => {
    active += 1;
    peak = Math.max(peak, active);
    return requests[Number(id)]!.promise.finally(() => { active -= 1; });
  });
  const transport = runner({
    projects: vi.fn().mockResolvedValue({ projects: requests.map((_request, index) => project(String(index), `Project ${index}`)), next_cursor: null }),
    projectWorkItems: fetchTasks,
  });
  await overview(transport);
  expect(fetchTasks).toHaveBeenCalledTimes(2);
  expect(button("Refreshing…").disabled).toBe(true);
  await act(async () => requests[1]!.resolve({ items: [], next_cursor: null }));
  expect(fetchTasks).toHaveBeenCalledTimes(3);
  await act(async () => requests[0]!.resolve({ items: [], next_cursor: null }));
  expect(fetchTasks).toHaveBeenCalledTimes(4);
  await act(async () => requests[2]!.resolve({ items: [], next_cursor: null }));
  expect(fetchTasks).toHaveBeenCalledTimes(5);
  await act(async () => {
    requests[3]!.resolve({ items: [], next_cursor: null });
    requests[4]!.resolve({ items: [], next_cursor: null });
  });
  expect(peak).toBe(2);
  expect(active).toBe(0);
  expect(button("Refresh").disabled).toBe(false);
  expect(host.textContent).toContain("5 loaded projects");
});
