import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { ChatDetail, ChatTurn, ProjectRepository, Transport } from "@farhelm/client-core";
import { ProjectChat } from "./ProjectChat";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
let host: HTMLDivElement;
let root: Root;
beforeEach(() => { vi.useFakeTimers(); host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(async () => { await act(async () => root.unmount()); host.remove(); vi.useRealTimers(); });

const repo: ProjectRepository = { id: "repo-1", name: "payments-api", path: "/srv/payments-api" } as ProjectRepository;
const conversation = { id: "chat-1", project_id: "p", repo_id: "repo-1", title: "Retry backoff", created_at: 1, updated_at: 1 };
const turn = (status: ChatTurn["status"], error?: string): ChatTurn => ({ request_id: "r1", status, created_at: 1, updated_at: 1, ...(error ? { error } : {}) });
const detail = (status: ChatTurn["status"] | null, extra: Partial<ChatDetail> = {}): ChatDetail => ({
  conversation,
  messages: [
    { id: "m1", conversation_id: "chat-1", role: "user", content: "Should the backoff cap at 30s?", created_at: 1 },
    ...(status === "completed" ? [{ id: "m2", conversation_id: "chat-1", role: "assistant" as const, content: "Cap it at 30 seconds and add a test.", created_at: 2 }] : []),
  ],
  ...(status ? { latest_turn: turn(status, status === "failed" ? "no model provider is configured on this runner" : undefined) } : {}),
  ...extra,
});

function runner(projectConversation: Transport["projectConversation"], overrides: Partial<Transport> = {}) {
  return {
    kind: "loopback", supportsProjectChat: true,
    projectConversations: vi.fn().mockResolvedValue({ conversations: [conversation], next_cursor: null }),
    createProjectConversation: vi.fn(), projectConversation,
    sendProjectMessage: vi.fn(), startProjectTask: vi.fn(),
    ...overrides,
  } as unknown as Transport;
}

async function render(transport: Transport, onTaskStarted = vi.fn()) {
  await act(async () => root.render(createElement(ProjectChat, { transport, projectId: "p", repositories: [repo], onTaskStarted })));
  await act(async () => { await vi.advanceTimersByTimeAsync(0); });
  return onTaskStarted;
}

function button(text: string) {
  return Array.from(host.querySelectorAll("button")).find((node) => node.textContent === text);
}

it("keeps reading a pending reply until it settles", async () => {
  const load = vi.fn()
    .mockResolvedValueOnce(detail("pending"))
    .mockResolvedValueOnce(detail("pending"))
    .mockResolvedValue(detail("completed"));
  await render(runner(load));
  expect(host.textContent).toContain("Thinking…");
  await act(async () => { await vi.advanceTimersByTimeAsync(3_000); });
  expect(load).toHaveBeenCalledTimes(3);
  expect(host.textContent).toContain("Cap it at 30 seconds");
  expect(host.textContent).not.toContain("Thinking…");
  await act(async () => { await vi.advanceTimersByTimeAsync(10_000); });
  expect(load).toHaveBeenCalledTimes(3);
});

it("shows why a reply failed instead of looking idle", async () => {
  await render(runner(vi.fn().mockResolvedValue(detail("failed"))));
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("no model provider is configured on this runner");
});

it("resends an interrupted message with a new request id", async () => {
  const sendProjectMessage = vi.fn().mockResolvedValue({ detail: detail("pending"), turn: turn("pending") });
  await render(runner(vi.fn().mockResolvedValue(detail("interrupted")), { sendProjectMessage }));
  await act(async () => { button("Send again")!.click(); });
  expect(sendProjectMessage).toHaveBeenCalledOnce();
  const [, , body] = sendProjectMessage.mock.calls[0]!;
  expect(body.content).toBe("Should the backoff cap at 30s?");
  expect(body.request_id).not.toBe("r1");
});

it("starts a task from a reply only after the prompt is confirmed", async () => {
  const task = { id: "task-9" };
  const startProjectTask = vi.fn().mockResolvedValue(task);
  const onTaskStarted = await render(runner(vi.fn().mockResolvedValue(detail("completed")), { startProjectTask }));
  await act(async () => button("Start as task")!.click());
  expect(startProjectTask).not.toHaveBeenCalled();
  const prompt = host.querySelector<HTMLTextAreaElement>('textarea[id^="task-from-"]')!;
  expect(prompt.value).toBe("Cap it at 30 seconds and add a test.");
  await act(async () => { host.querySelector<HTMLFormElement>(".chat-task-draft")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })); });
  expect(startProjectTask).toHaveBeenCalledExactlyOnceWith("p", { repo_id: "repo-1", prompt: "Cap it at 30 seconds and add a test." });
  expect(onTaskStarted).toHaveBeenCalledExactlyOnceWith(task);
});
