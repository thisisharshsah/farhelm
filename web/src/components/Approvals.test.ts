import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { ApprovalView, SessionView, Transport } from "@farhelm/client-core";
import fixture from "../../../crates/farhelm-proto/tests/fixtures/wire.json";
import { ApprovalCard, AutoApproveControl } from "./Approvals";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
let host: HTMLDivElement;
let root: Root;
beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(async () => { await act(async () => root.unmount()); host.remove(); });

const base = fixture.fleet_view.pending_approvals[0] as ApprovalView;
const session = fixture.fleet_view.sessions[0] as SessionView;

function button(text: string): HTMLButtonElement | undefined {
  return Array.from(host.querySelectorAll("button")).find((node) => node.textContent === text);
}

async function card(approval: ApprovalView, transport: Partial<Transport>) {
  const onDecided = vi.fn();
  await act(async () => root.render(createElement(ApprovalCard, {
    approval, transport: transport as Transport, onDecided,
  })));
  return onDecided;
}

it("decides once, then delegates the level that covers this card's risk", async () => {
  const calls: string[] = [];
  const transport = {
    decide: vi.fn(async () => { calls.push("decide"); }),
    setAutoApprove: vi.fn(async (_id: string, level: SessionView["auto_approve"]) => {
      calls.push(`set:${level}`);
      return { ...session, auto_approve: level };
    }),
  };
  const onDecided = await card({ ...base, risk: "medium" }, transport);
  const delegate = button("Approve and stop asking for commands like this")!;
  await act(async () => { delegate.click(); delegate.click(); });
  expect(calls).toEqual(["decide", "set:medium"]);
  expect(transport.decide).toHaveBeenCalledExactlyOnceWith(base.id, "approved");
  expect(transport.setAutoApprove).toHaveBeenCalledExactlyOnceWith(base.session_id, "medium");
  expect(onDecided).toHaveBeenCalledOnce();
});

it("never offers to stop asking for a destructive command", async () => {
  await card(base, { decide: vi.fn(), setAutoApprove: vi.fn() });
  expect(base.risk).toBe("destructive");
  expect(button("Approve")).toBeDefined();
  expect(Array.from(host.querySelectorAll("button")).some((node) => node.textContent?.includes("auto-approve"))).toBe(false);
  expect(host.textContent).toContain("always needs a person");
});

it("says which half failed when the approval stood but delegation did not", async () => {
  const transport = {
    decide: vi.fn().mockResolvedValue(undefined),
    setAutoApprove: vi.fn().mockRejectedValue(new Error("auto-approve can only be changed from the phone or the web app")),
  };
  const onDecided = await card({ ...base, risk: "low" }, transport);
  await act(async () => button("Approve and auto-approve read-only tools")!.click());
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("Approved, but auto-approve was not turned on");
  expect(onDecided).toHaveBeenCalledOnce();
});

async function control(transport: Partial<Transport>, view: SessionView = session) {
  const onChanged = vi.fn();
  await act(async () => root.render(createElement(AutoApproveControl, {
    session: view, transport: transport as Transport, onChanged,
  })));
  return { onChanged, select: host.querySelector<HTMLSelectElement>("select")! };
}

async function choose(select: HTMLSelectElement, value: string) {
  await act(async () => {
    select.value = value;
    select.dispatchEvent(new Event("change", { bubbles: true }));
  });
}

it("shows the level the runner reported, not the one requested", async () => {
  // The runner answers with its own view; a client that displayed its request
  // would claim a delegation the runner never granted.
  const setAutoApprove = vi.fn().mockResolvedValue({ ...session, auto_approve: "low" });
  const { onChanged, select } = await control({ setAutoApprove });
  await choose(select, "medium");
  expect(setAutoApprove).toHaveBeenCalledExactlyOnceWith(session.id, "medium");
  expect(select.value).toBe("low");
  expect(onChanged).toHaveBeenCalledOnce();
});

it("returns to the reported level and explains a refusal", async () => {
  const { select } = await control({ setAutoApprove: vi.fn().mockRejectedValue(new Error("refused")) });
  await choose(select, "medium");
  expect(select.value).toBe("off");
  expect(host.querySelector('[role="status"]')?.textContent).toBe("Not changed: refused");
});

it("cannot change the level of a session that has ended", async () => {
  const { select } = await control({ setAutoApprove: vi.fn() }, { ...session, is_live: false });
  expect(select.disabled).toBe(true);
});
