import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { TaskView } from "@farhelm/client-core";
import { TaskBoard } from "./Board";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

let host: HTMLDivElement;
let root: Root;

function task(id: string, repoId: string, path: string): TaskView {
  return {
    id, session_id: "synthetic-session", repo_id: repoId, repo_name: "app", repo_path: path,
    prompt: `Review ${id}`, status: "awaiting_review", summary: "Synthetic fixture",
    files_changed: 1, lines_added: 3, lines_removed: 1, change_summary: "1 file, +3 −1",
    steps: 2, cost_usd: 0.04, error: null, review_note: null, verify_grade: null,
    verify_notes: null, verify_model: null, decided_via: null, created_at: 1, updated_at: 1, decided_at: null,
  };
}

async function render(tasks: TaskView[]) {
  await act(async () => root.render(createElement(TaskBoard, {
    tasks, transport: null, onOpen: vi.fn(), onNewTask: vi.fn(),
  })));
}

beforeEach(() => {
  localStorage.clear();
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});

afterEach(async () => {
  await act(async () => root.unmount());
  host.remove();
  vi.restoreAllMocks();
});

it("mounts and toggles layout when optional browser storage is blocked", async () => {
  vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
    throw new DOMException("blocked", "SecurityError");
  });
  vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
    throw new DOMException("blocked", "SecurityError");
  });
  await render([task("one", "repo-a", "/synthetic/a")]);
  const boardButton = Array.from(host.querySelectorAll("button")).find((button) => button.textContent?.trim() === "Kanban")!;
  await act(async () => boardButton.click());
  expect(boardButton.getAttribute("aria-pressed")).toBe("true");
  expect(host.querySelector(".kanban-board")).not.toBeNull();
  expect(host.textContent).toContain("Review one");
});

it("filters distinct repositories with the same name and recovers a removed selection", async () => {
  const first = task("one", "repo-a", "/synthetic/a");
  const second = task("two", "repo-b", "/synthetic/b");
  await render([first, second]);
  const select = host.querySelector<HTMLSelectElement>('select[aria-label="Filter by repository"]')!;
  expect(Array.from(select.options).map((option) => option.value)).toEqual(["all", "repo-a", "repo-b"]);
  expect(select.textContent).toContain("app: /synthetic/a");
  expect(select.textContent).toContain("app: /synthetic/b");
  await act(async () => {
    select.value = "repo-a";
    select.dispatchEvent(new Event("change", { bubbles: true }));
  });
  expect(host.querySelector(".task-list")?.textContent).toContain("Review one");
  expect(host.querySelector(".task-list")?.textContent).not.toContain("Review two");

  await render([second]);
  expect(host.querySelector("select")).toBeNull();
  expect(host.querySelector(".task-list")?.textContent).toContain("Review two");
  expect(host.textContent).not.toContain("No matching tasks");
});
