import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { Project, ProjectChat, Transport } from "@farhelm/client-core";
import { ProjectWorkspace } from "./ProjectWorkspace";

vi.mock("./ProjectChat", () => ({
  supportsProjectChat: () => true,
  ConversationPane: ({ conversation }: { conversation: ProjectChat }) => createElement("section", { "aria-label": "Conversation content" },
    createElement("h2", null, conversation.title), createElement("textarea", { "aria-label": "Draft" })),
}));
(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
let host: HTMLDivElement;
let root: Root;
const project: Project = { id: "p", name: "Example project", description: "", workspace_id: "local", budget_cap_usd: null, created_at: 1, updated_at: 1 };
const chat = (id: string): ProjectChat => ({ id, project_id: "p", repo_id: "repo", title: `Conversation ${id}`, created_at: 1, updated_at: 1 });
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((yes) => { resolve = yes; });
  return { promise, resolve };
}
function runner(overrides: Partial<Transport> = {}) {
  return {
    kind: "loopback", supportsProjectChat: true,
    projectRepositories: vi.fn().mockResolvedValue({ repositories: [{ id: "repo", name: "Repository", path: "/synthetic/repo" }], next_cursor: null }),
    projectConversations: vi.fn().mockResolvedValue({ conversations: [chat("recent")], next_cursor: null }),
    projectWorkItems: vi.fn().mockResolvedValue({ items: [], next_cursor: null }),
    projectTasks: vi.fn().mockResolvedValue({ tasks: [], next_cursor: null }),
    projectConversation: vi.fn().mockImplementation((_p: string, id: string) => Promise.resolve({ conversation: chat(id), messages: [] })),
    onEvent: vi.fn().mockReturnValue(() => {}),
    ...overrides,
  } as unknown as Parameters<typeof ProjectWorkspace>[0]["transport"];
}
async function render(transport: ReturnType<typeof runner>, focus: Parameters<typeof ProjectWorkspace>[0]["focus"] = { kind: "home" }, onNavigate = vi.fn()) {
  await act(async () => root.render(createElement(ProjectWorkspace, { project, transport, focus, onNavigate })));
  return onNavigate;
}
function button(text: string) {
  const node = Array.from(host.querySelectorAll("button")).find((item) => item.textContent?.trim() === text);
  if (!node) throw new Error(`Missing button ${text}`);
  return node;
}
beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(async () => { await act(async () => root.unmount()); host.remove(); });

it("opens a linked conversation outside the first navigation page", async () => {
  const transport = runner();
  await render(transport, { kind: "chat", id: "older" });
  expect(transport.projectConversation).toHaveBeenCalledWith("p", "older");
  expect(host.querySelector('[aria-label="Conversation content"]')?.textContent).toBe("Conversation older");
  expect(host.textContent).not.toContain("not in this project");
});

it("paginates navigation and keeps completed tasks reachable", async () => {
  const list = vi.fn().mockResolvedValueOnce({ conversations: [chat("recent")], next_cursor: "recent" })
    .mockResolvedValueOnce({ conversations: [chat("older")], next_cursor: null });
  const transport = runner({ projectConversations: list, projectWorkItems: vi.fn().mockResolvedValue({ items: [{ id: "done", title: "Completed task", status: "done" }], next_cursor: null }) });
  await render(transport);
  await act(async () => button("Load more conversations").click());
  expect(list).toHaveBeenLastCalledWith("p", { limit: 50, after: "recent" });
  expect(host.querySelector('[aria-label="Conversations"]')?.textContent).toContain("Conversation older");
  expect(host.querySelector('[aria-label="Tasks"]')?.textContent).toContain("Completed task");
});

it("closes project navigation and restores trigger focus after selecting a thread", async () => {
  const navigate = await render(runner());
  const toggle = button("Browse project");
  await act(async () => toggle.click());
  expect(toggle.getAttribute("aria-expanded")).toBe("true");
  await act(async () => host.querySelector<HTMLButtonElement>(".side-thread")!.click());
  expect(toggle.getAttribute("aria-expanded")).toBe("false");
  expect(document.activeElement).toBe(toggle);
  expect(navigate).toHaveBeenCalledWith("/p/p/c/recent");
});

it("recovers list failure without showing an empty project or a stale error", async () => {
  const list = vi.fn().mockRejectedValueOnce(new Error("Offline"))
    .mockResolvedValue({ conversations: [chat("loaded")], next_cursor: null });
  await render(runner({ projectConversations: list }));
  expect(host.querySelector(".ws-main")?.textContent).toContain("Could not load conversations");
  await act(async () => button("Retry conversations").click());
  expect(host.textContent).not.toContain("Offline");
  expect(host.querySelector(".ws-main")?.textContent).toContain("Conversation loaded");
});

it("keeps an open draft mounted while refreshing navigation lists", async () => {
  const transport = runner();
  await render(transport, { kind: "chat", id: "recent" });
  const field = host.querySelector<HTMLTextAreaElement>('textarea[aria-label="Draft"]')!;
  field.value = "Unsent draft";
  await act(async () => button("Refresh project lists").click());
  expect(host.querySelector('textarea[aria-label="Draft"]')).toBe(field);
  expect(field.value).toBe("Unsent draft");
});

it("preserves an unsent draft after a failed conversation refresh and retry", async () => {
  const read = vi.fn().mockResolvedValueOnce({ conversation: chat("recent"), messages: [] })
    .mockRejectedValueOnce(new Error("Offline"))
    .mockResolvedValue({ conversation: chat("recent"), messages: [] });
  await render(runner({ projectConversation: read }), { kind: "chat", id: "recent" });
  const field = host.querySelector<HTMLTextAreaElement>('textarea[aria-label="Draft"]')!;
  field.value = "Unsent draft";
  await act(async () => button("Refresh project lists").click());
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("Could not refresh this conversation. Offline");
  expect(host.querySelector('textarea[aria-label="Draft"]')).toBe(field);
  expect(field.value).toBe("Unsent draft");
  await act(async () => button("Retry conversation").click());
  expect(host.querySelector('[role="alert"]')).toBeNull();
  expect(host.querySelector('textarea[aria-label="Draft"]')).toBe(field);
  expect(field.value).toBe("Unsent draft");
});

it("shows an initial conversation failure without retaining another conversation", async () => {
  const read = vi.fn().mockResolvedValueOnce({ conversation: chat("recent"), messages: [] })
    .mockRejectedValueOnce(new Error("Unavailable"))
    .mockResolvedValue({ conversation: chat("older"), messages: [] });
  const transport = runner({ projectConversation: read });
  await render(transport, { kind: "chat", id: "recent" });
  await render(transport, { kind: "chat", id: "older" });
  expect(host.querySelector('[aria-label="Conversation content"]')).toBeNull();
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("Could not open this conversation. Unavailable");
  await act(async () => button("Retry conversation").click());
  expect(host.querySelector('[aria-label="Conversation content"]')?.textContent).toBe("Conversation older");
  expect(host.querySelector('[role="alert"]')).toBeNull();
});

it("clears old runner data and ignores its late responses", async () => {
  const old = deferred<{ conversations: ProjectChat[]; next_cursor: null }>();
  await render(runner({ projectConversations: vi.fn().mockReturnValue(old.promise) }));
  await render(runner({ projectConversations: vi.fn().mockResolvedValue({ conversations: [chat("new-runner")], next_cursor: null }) }));
  await act(async () => old.resolve({ conversations: [chat("private-old")], next_cursor: null }));
  expect(host.textContent).not.toContain("private-old");
  expect(host.textContent).toContain("new-runner");
});

it("preserves a created conversation when its first message has an uncertain outcome", async () => {
  const create = vi.fn().mockResolvedValue(chat("created"));
  const send = vi.fn().mockRejectedValue(new Error("Connection lost"));
  const transport = runner({ createProjectConversation: create, sendProjectMessage: send });
  const navigate = await render(transport, { kind: "chat", id: "new" });
  const field = host.querySelector<HTMLTextAreaElement>('textarea[aria-label="First message"]')!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(field, "Plan a change");
    field.dispatchEvent(new Event("input", { bubbles: true }));
  });
  await act(async () => host.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })));
  expect(host.textContent).toContain("Conversation created.");
  await act(async () => host.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })));
  expect(create).toHaveBeenCalledTimes(1);
  expect(send).toHaveBeenCalledTimes(1);
  await act(async () => button("Open conversation to check").click());
  expect(navigate).toHaveBeenCalledWith("/p/p/c/created");
});
