import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { FleetView, TaskDetail, Transport } from "@farhelm/client-core";
import fixture from "../../../crates/farhelm-proto/tests/fixtures/wire.json";
import { NewTaskComposer, TaskThread } from "./TaskThread";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
let host: HTMLDivElement;
let root: Root;
beforeEach(() => { localStorage.clear(); host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(async () => { await act(async () => root.unmount()); host.remove(); });

function runner(overrides: Partial<Transport> = {}) {
  return {
    kind: "loopback", supportsTaskControl: true, repositories: vi.fn().mockResolvedValue([]),
    startTask: vi.fn(), decide: vi.fn().mockResolvedValue(undefined), reviewTask: vi.fn().mockResolvedValue(undefined),
    ...overrides,
  } as unknown as Transport;
}

async function fill(selector: string, value: string) {
  const node = host.querySelector<HTMLInputElement | HTMLTextAreaElement>(selector)!;
  const prototype = node instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  await act(async () => {
    Object.getOwnPropertyDescriptor(prototype, "value")!.set!.call(node, value);
    node.dispatchEvent(new Event("input", { bubbles: true }));
  });
}

async function composer(transport: Transport, onStarted = vi.fn()) {
  await act(async () => root.render(createElement(NewTaskComposer, { transport, tasks: [], onStarted })));
  return onStarted;
}

it("drops unscoped repository caches and ends drafts when the runner changes", async () => {
  localStorage.setItem("farhelm-known-repos", JSON.stringify([{ path: "/private/old" }]));
  localStorage.setItem("farhelm-recent-repos", JSON.stringify(["/private/older"]));
  await composer(runner());
  expect(localStorage.getItem("farhelm-known-repos")).toBeNull();
  expect(localStorage.getItem("farhelm-recent-repos")).toBeNull();
  expect(host.textContent).not.toContain("/private/old");
  await fill('[aria-label="Task instruction"]', "Private task A");
  await fill('[aria-label="Repository path"]', "/synthetic/repo-a");
  await composer(runner());
  expect(host.querySelector<HTMLTextAreaElement>('[aria-label="Task instruction"]')?.value).toBe("");
  expect(host.querySelector<HTMLInputElement>('[aria-label="Repository path"]')?.value).toBe("");
});

it("starts once and ignores a start that completes after a runner switch", async () => {
  let resolve!: (value: TaskDetail) => void;
  const transport = runner({ startTask: vi.fn(() => new Promise<TaskDetail>((yes) => { resolve = yes; })) });
  const onStarted = await composer(transport);
  await fill('[aria-label="Task instruction"]', "Synthetic change");
  await fill('[aria-label="Repository path"]', "/synthetic/repo-a");
  await act(async () => {
    const form = host.querySelector("form")!;
    for (let i = 0; i < 2; i += 1) form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  });
  expect(transport.startTask).toHaveBeenCalledTimes(1);
  await composer(runner(), onStarted);
  await act(async () => resolve(fixture.task_detail as TaskDetail));
  expect(onStarted).not.toHaveBeenCalled();
});

it("refuses a malformed spend cap before starting anything", async () => {
  const transport = runner();
  await composer(transport);
  await fill('[aria-label="Task instruction"]', "Synthetic change");
  await fill('[aria-label="Repository path"]', "/synthetic/repo-a");
  await fill('[aria-label="Spend cap in dollars"]', "-2");
  await act(async () => host.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })));
  expect(transport.startTask).not.toHaveBeenCalled();
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("positive spend cap");
});

async function thread(transport: Transport, task = fixture.task_detail as TaskDetail) {
  const props = {
    task, transport, fleet: fixture.fleet_view as FleetView, onChanged: vi.fn(), onOpenTask: vi.fn(),
  };
  await act(async () => root.render(createElement(TaskThread, props)));
  return props;
}

it("keeps this task's command approvals in its thread", async () => {
  const decide = vi.fn(() => new Promise<void>(() => {}));
  await thread(runner({ decide }));
  const approval = host.querySelector('[aria-label="Approval request"]');
  expect(approval?.textContent).toContain(fixture.fleet_view.pending_approvals[0]!.payload);
  const approve = Array.from(approval!.querySelectorAll("button")).find((node) => node.textContent === "Approve")!;
  await act(async () => { approve.click(); approve.click(); });
  expect(decide).toHaveBeenCalledExactlyOnceWith(fixture.fleet_view.pending_approvals[0]!.id, "approved");
});

it("applies a reviewed diff and asks for the authoritative state afterwards", async () => {
  const transport = runner();
  const props = await thread(transport, { ...fixture.task_detail, status: "awaiting_review" } as TaskDetail);
  expect(host.querySelector('[aria-label="Edited files"]')?.textContent).toContain(fixture.task_detail.changes.files[0]!.path);
  const apply = Array.from(host.querySelectorAll("button")).find((node) => node.textContent === "Apply to disk")!;
  await act(async () => apply.click());
  expect(transport.reviewTask).toHaveBeenCalledExactlyOnceWith(fixture.task_detail.id, "approve", undefined);
  expect(props.onChanged).toHaveBeenCalledOnce();
});

it("offers the access level only while the task's session is live", async () => {
  await thread(runner());
  expect(host.querySelector('select[id^="auto-approve-"]')).not.toBeNull();
  const ended = { ...fixture.fleet_view, sessions: fixture.fleet_view.sessions.map((s) => ({ ...s, is_live: false })) };
  await act(async () => root.render(createElement(TaskThread, {
    task: fixture.task_detail as TaskDetail, transport: runner(), fleet: ended as FleetView, onChanged: vi.fn(), onOpenTask: vi.fn(),
  })));
  expect(host.querySelector('select[id^="auto-approve-"]')).toBeNull();
  expect(host.querySelector('[aria-label="Follow-up task"]')).not.toBeNull();
});
