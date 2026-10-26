import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { Project, ProjectPage, Transport } from "@farhelm/client-core";
import { ProjectsList } from "./Projects";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

let host: HTMLDivElement;
let root: Root;

function project(id: string, name: string): Project {
  return { id, workspace_id: "synthetic-local", name, description: `Description for ${name}`,
    budget_cap_usd: null, created_at: 1_000, updated_at: 2_000 };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (cause: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function runner(overrides: Partial<Transport> = {}) {
  return {
    kind: "loopback", supportsProjects: true,
    projects: vi.fn().mockResolvedValue({ projects: [], next_cursor: null }),
    project: vi.fn().mockImplementation((id: string) => Promise.resolve(project(id, "Project details"))),
    createProject: vi.fn().mockResolvedValue(project("created", "New project")),
    ...overrides,
  } as unknown as Transport;
}

async function render(transport: Transport | null, projectId: string | null = null, onNavigate = vi.fn()) {
  await act(async () => root.render(createElement(ProjectsList, { transport, projectId, onNavigate })));
  return onNavigate;
}

function button(text: string): HTMLButtonElement {
  const match = Array.from(host.querySelectorAll("button")).find((node) => node.textContent === text);
  if (!match) throw new Error(`No button ${text}`);
  return match;
}

async function field(selector: string, value: string) {
  const node = host.querySelector<HTMLInputElement | HTMLTextAreaElement>(selector)!;
  const prototype = node instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  await act(async () => {
    Object.getOwnPropertyDescriptor(prototype, "value")!.set!.call(node, value);
    node.dispatchEvent(new Event("input", { bubbles: true }));
  });
}

async function submit(times = 1) {
  await act(async () => {
    for (let index = 0; index < times; index += 1) host.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  });
}

beforeEach(() => {
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});

afterEach(async () => {
  await act(async () => root.unmount());
  host.remove();
});

it("explains local project availability without invented records or sending relay requests", async () => {
  const projects = vi.fn();
  const onNavigate = await render(runner({ kind: "relay", supportsProjects: false, projects }));
  expect(host.textContent).toContain("Connect directly to a runner");
  expect(host.querySelector("input")).toBeNull();
  expect(host.querySelector(".project-card")).toBeNull();
  expect(host.textContent).not.toContain("Uncapped");
  expect(host.textContent).not.toContain("Active Tasks");
  expect(projects).not.toHaveBeenCalled();
  await act(async () => button("View Tasks").click());
  expect(onNavigate).toHaveBeenCalledExactlyOnceWith("/t");
  await render(null);
  expect(host.textContent).toContain("Projects are not available over the relay yet.");
});

it("renders loading, an actual empty response, and the local create form", async () => {
  const request = deferred<ProjectPage>();
  await render(runner({ projects: vi.fn().mockReturnValue(request.promise) }));
  expect(host.querySelector('[role="status"]')?.textContent).toBe("Loading projects…");
  await act(async () => request.resolve({ projects: [], next_cursor: null }));
  expect(host.textContent).toContain("No projects yet. Create a project on this runner.");
  expect(host.querySelector('label[for="project-name"]')?.textContent).toBe("Name");
  expect(host.querySelector("#project-description")).not.toBeNull();
});

it("surfaces errors and refreshes from the runner", async () => {
  const projects = vi.fn().mockRejectedValueOnce(new Error("Runner offline")).mockResolvedValueOnce({ projects: [project("real", "Actual record")], next_cursor: null });
  await render(runner({ projects }));
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("Runner offline");
  await act(async () => button("Refresh").click());
  expect(host.querySelector('[role="alert"]')).toBeNull();
  expect(host.querySelector(".project-card")?.textContent).toContain("Actual record");
  expect(projects).toHaveBeenCalledTimes(2);
});

it("renders real records, loads the next cursor once, and opens a detail route", async () => {
  const second = deferred<ProjectPage>();
  const projects = vi.fn().mockResolvedValueOnce({ projects: [project("newer", "First record")], next_cursor: "newer" }).mockReturnValueOnce(second.promise);
  const onNavigate = await render(runner({ projects }));
  expect(host.querySelectorAll(".project-card")).toHaveLength(1);
  await act(async () => { button("Load more").click(); });
  expect(button("Loading more…").disabled).toBe(true);
  expect(projects).toHaveBeenLastCalledWith({ after: "newer", limit: 50 });
  await act(async () => second.resolve({ projects: [project("older", "Second record")], next_cursor: null }));
  expect(host.querySelectorAll(".project-card")).toHaveLength(2);
  expect(host.textContent).not.toContain("Load more");
  await act(async () => host.querySelector<HTMLButtonElement>('[aria-label="Open Second record"]')!.click());
  expect(onNavigate).toHaveBeenCalledWith("/p/older");
});

it("shows project details and a way back without implying task links or budgets", async () => {
  const transport = runner();
  const onNavigate = await render(transport, "detail-id");
  expect(transport.project).toHaveBeenCalledExactlyOnceWith("detail-id");
  expect(transport.projects).not.toHaveBeenCalled();
  expect(host.querySelector("h1")?.textContent).toBe("Project details");
  expect(host.querySelector('[aria-label="Project details"]')?.textContent).toContain("Description for Project details");
  expect(host.querySelectorAll("time")).toHaveLength(2);
  expect(host.querySelector("form")).toBeNull();
  expect(host.textContent).not.toContain("budget");
  await act(async () => button("All projects").click());
  expect(onNavigate).toHaveBeenCalledWith("/p");
});

it("creates only after a successful response and guards duplicate submissions", async () => {
  const created = deferred<Project>();
  const createProject = vi.fn().mockReturnValue(created.promise);
  const onNavigate = await render(runner({ createProject }));
  await field("#project-name", "  New project  ");
  await field("#project-description", "Work together");
  await submit(2);
  expect(createProject).toHaveBeenCalledExactlyOnceWith({ name: "New project", description: "Work together" });
  expect(button("Creating…").disabled).toBe(true);
  expect(onNavigate).not.toHaveBeenCalled();
  await act(async () => created.resolve(project("created-id", "New project")));
  expect(onNavigate).toHaveBeenCalledExactlyOnceWith("/p/created-id");
  expect(host.querySelector<HTMLInputElement>("#project-name")?.value).toBe("");
});

it("retains inputs and reports a create failure without optimistic success or automatic retry", async () => {
  const createProject = vi.fn().mockRejectedValue(new Error("Project could not be stored"));
  const onNavigate = await render(runner({ createProject }));
  await field("#project-name", "Keep this name");
  await submit();
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("Project could not be stored");
  expect(host.querySelector<HTMLInputElement>("#project-name")?.value).toBe("Keep this name");
  expect(button("Create project").disabled).toBe(false);
  expect(onNavigate).not.toHaveBeenCalled();
  expect(createProject).toHaveBeenCalledTimes(1);
});

it("validates names and descriptions before submitting a mutation", async () => {
  const transport = runner();
  await render(transport);
  await field("#project-name", " ");
  await submit();
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("between 1 and 120");
  await field("#project-name", "Valid name");
  await field("#project-description", "x".repeat(4_001));
  await submit();
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("4,000 characters");
  expect(transport.createProject).not.toHaveBeenCalled();
});

it("clears records and drafts across runner identities and ignores late responses", async () => {
  const oldPage = deferred<ProjectPage>();
  const oldRunner = runner({ projects: vi.fn().mockResolvedValueOnce({ projects: [project("private", "Old runner record")], next_cursor: null }).mockReturnValueOnce(oldPage.promise) });
  await render(oldRunner);
  await field("#project-name", "Private draft");
  await act(async () => button("Refresh").click());
  const newPage = deferred<ProjectPage>();
  await render(runner({ projects: vi.fn().mockReturnValue(newPage.promise) }));
  expect(host.textContent).not.toContain("Old runner record");
  expect(host.querySelector<HTMLInputElement>("#project-name")?.value).toBe("");
  await act(async () => oldPage.resolve({ projects: [project("late", "Old late response")], next_cursor: null }));
  expect(host.textContent).not.toContain("Old late response");
  await act(async () => newPage.resolve({ projects: [project("new", "New runner record")], next_cursor: null }));
  expect(host.textContent).toContain("New runner record");
});

it("ignores a create response after switching runners", async () => {
  const created = deferred<Project>();
  const onNavigate = vi.fn();
  await render(runner({ createProject: vi.fn().mockReturnValue(created.promise) }), null, onNavigate);
  await field("#project-name", "Private draft");
  await submit();
  await render(runner(), null, onNavigate);
  await act(async () => created.resolve(project("old-created", "Private draft")));
  expect(onNavigate).not.toHaveBeenCalled();
  expect(host.querySelector<HTMLInputElement>("#project-name")?.value).toBe("");
});

it("keeps existing records and offers pagination retry after a failure", async () => {
  const projects = vi.fn()
    .mockResolvedValueOnce({ projects: [project("newer", "Existing record")], next_cursor: "newer" })
    .mockRejectedValueOnce(new Error("Runner disconnected"))
    .mockResolvedValueOnce({ projects: [project("older", "Older record")], next_cursor: null });
  await render(runner({ projects }));
  await act(async () => button("Load more").click());
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("Runner disconnected");
  expect(host.textContent).toContain("Existing record");
  await act(async () => button("Load more").click());
  expect(host.querySelector('[role="alert"]')).toBeNull();
  expect(host.querySelectorAll(".project-card")).toHaveLength(2);
});

it("reports a missing detail and never displays the previously selected project", async () => {
  const pending = deferred<Project>();
  const getProject = vi.fn().mockResolvedValueOnce(project("first", "First private project")).mockReturnValueOnce(pending.promise);
  const transport = runner({ project: getProject });
  await render(transport, "first");
  expect(host.querySelector("h1")?.textContent).toBe("First private project");
  await render(transport, "missing");
  expect(host.textContent).not.toContain("First private project");
  expect(host.querySelector('[role="status"]')?.textContent).toBe("Loading project…");
  await act(async () => pending.reject(new Error("Project not found")));
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("Project not found");
  expect(host.querySelector('[aria-label="Project details"]')).toBeNull();
  expect(button("Refresh").disabled).toBe(false);
});

it("identifies retained data as stale when refreshing the runner fails", async () => {
  const projects = vi.fn().mockResolvedValueOnce({ projects: [project("last", "Last loaded project")], next_cursor: null }).mockRejectedValueOnce(new Error("Connection interrupted"));
  await render(runner({ projects }));
  await act(async () => button("Refresh").click());
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("Could not refresh projects.");
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("Showing the last loaded projects from this runner.");
  expect(host.querySelector(".project-card")?.textContent).toContain("Last loaded project");
});

it("refuses to append a page from another local workspace", async () => {
  const projects = vi.fn().mockResolvedValueOnce({ projects: [project("last", "Current workspace")], next_cursor: "last" }).mockResolvedValueOnce({ projects: [{ ...project("foreign", "Other workspace"), workspace_id: "another-workspace" }], next_cursor: null });
  await render(runner({ projects }));
  await act(async () => button("Load more").click());
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("different workspace");
  expect(host.querySelectorAll(".project-card")).toHaveLength(1);
  expect(host.textContent).not.toContain("Other workspace");
});
