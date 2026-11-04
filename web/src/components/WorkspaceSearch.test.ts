import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { SearchHit, Transport, WorkspaceSearch } from "@farhelm/client-core";
import { hitPath, SEARCH_DEBOUNCE_MS, supportsSearch, WorkspaceSearchResults } from "./WorkspaceSearch";
import { workItemPath } from "./WorkBoard";
import { chatPath } from "./ProjectWorkspace";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
let host: HTMLDivElement;
let root: Root;
beforeEach(() => {
  vi.useFakeTimers();
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});
afterEach(() => {
  act(() => root.unmount());
  host.remove();
  vi.useRealTimers();
});

function hit(kind: SearchHit["kind"], id: string, extra: Partial<SearchHit> = {}): SearchHit {
  return { kind, id, project_id: "p 1", project_name: "Payments", title: `${kind} ${id}`, snippet: null,
    status: null, updated_at: 1, ...extra };
}
function result(query: string, hits: SearchHit[], truncated = false): WorkspaceSearch {
  return { query, hits, truncated };
}
function transport(searchWorkspace: Transport["searchWorkspace"]) {
  return { kind: "loopback", searchWorkspace } as unknown as Transport & Required<Pick<Transport, "searchWorkspace">>;
}
async function render(search: ReturnType<typeof transport>, query: string, onNavigate = vi.fn()) {
  await act(async () => root.render(createElement(WorkspaceSearchResults, { transport: search, query, onNavigate })));
  return onNavigate;
}
async function settle() {
  await act(async () => { await vi.advanceTimersByTimeAsync(SEARCH_DEBOUNCE_MS); });
}

it("links every kind of hit where the app routes it", () => {
  expect(hitPath(hit("task", "w1"))).toBe(workItemPath("p 1", "w1"));
  expect(hitPath(hit("conversation", "c1"))).toBe(chatPath("p 1", "c1"));
  expect(hitPath(hit("run", "r1"))).toBe("/p/p%201/t/r1");
  expect(hitPath(hit("project", "p 1"))).toBe("/p/p%201");
});

it("only offers search on a direct runner that has it", () => {
  expect(supportsSearch(transport(vi.fn()))).toBe(true);
  expect(supportsSearch({ kind: "relay", searchWorkspace: vi.fn() } as unknown as Transport)).toBe(false);
  expect(supportsSearch({ kind: "loopback" } as unknown as Transport)).toBe(false);
});

it("asks once after typing stops, shows hits with their snippet, and navigates", async () => {
  const searchWorkspace = vi.fn().mockResolvedValue(result("retry", [
    hit("run", "r1", { snippet: "…capped the retry delay…", status: "applied" }),
    hit("task", "w1", { status: "todo" }),
  ], true));
  const search = transport(searchWorkspace);
  const onNavigate = await render(search, "re");
  await render(search, "retr", onNavigate);
  await render(search, "retry", onNavigate);
  expect(searchWorkspace).not.toHaveBeenCalled();
  await settle();
  expect(searchWorkspace).toHaveBeenCalledExactlyOnceWith("retry");
  expect(host.textContent).toContain("capped the retry delay");
  expect(host.textContent).toContain("Applied");
  expect(host.textContent).toContain("Showing the newest 2");
  const title = [...host.querySelectorAll("button")].find((item) => item.textContent === "task w1")!;
  await act(async () => title.click());
  expect(onNavigate).toHaveBeenCalledWith(workItemPath("p 1", "w1"));
});

it("drops an earlier answer that arrives after a newer one", async () => {
  let answerFirst!: (value: WorkspaceSearch) => void;
  const searchWorkspace = vi.fn()
    .mockReturnValueOnce(new Promise<WorkspaceSearch>((resolve) => { answerFirst = resolve; }))
    .mockResolvedValueOnce(result("webhook", [hit("task", "new")]));
  const search = transport(searchWorkspace);
  const onNavigate = await render(search, "retry");
  await settle();
  await render(search, "webhook", onNavigate);
  await settle();
  await act(async () => answerFirst(result("retry", [hit("task", "old")])));
  expect(host.textContent).toContain("task new");
  expect(host.textContent).not.toContain("task old");
});

it("does not search for fewer than two characters, and reports failures", async () => {
  const searchWorkspace = vi.fn().mockRejectedValue(new Error("project requests are busy; try again"));
  const search = transport(searchWorkspace);
  const onNavigate = await render(search, " x ");
  await settle();
  expect(searchWorkspace).not.toHaveBeenCalled();
  expect(host.textContent).toBe("");
  await render(search, "xy", onNavigate);
  await settle();
  expect(host.querySelector('[role="alert"]')?.textContent).toBe("project requests are busy; try again");
});
