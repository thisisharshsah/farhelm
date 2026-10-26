import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { CloudDevice } from "@farhelm/client-core";
import { DeviceSlotNotice } from "./DeviceSlot";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
let host: HTMLDivElement;
let root: Root;
beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(async () => { await act(async () => root.unmount()); host.remove(); });

const device = (id: string, name: string, lastSeen: number): CloudDevice => ({
  id, name, org_id: "org", account_id: "acct", kind: "web", public_key: "k", created_at: 1, last_seen_at: lastSeen,
});

it("names the devices holding the seats and moves one to this browser once", async () => {
  const onReplace = vi.fn(() => new Promise<void>(() => {}));
  await act(async () => root.render(createElement(DeviceSlotNotice, {
    problem: "your plan allows 2 devices",
    devices: [device("old", "Chrome on macOS", 1), device("phone", "Safari on iOS", 2)],
    onReplace, onRetry: vi.fn(), onPlans: vi.fn(),
  })));
  const names = Array.from(host.querySelectorAll(".device-slot-name")).map((node) => node.textContent);
  expect(names).toEqual(["Safari on iOS", "Chrome on macOS"]);
  expect(host.textContent).toContain("each web address");
  const replace = Array.from(host.querySelectorAll("button")).filter((node) => node.textContent === "Use this browser instead")[1]!;
  await act(async () => { replace.click(); replace.click(); });
  expect(onReplace).toHaveBeenCalledExactlyOnceWith("old");
});

it("shows a failed move and lets the person try again", async () => {
  const onReplace = vi.fn().mockRejectedValue(new Error("only an owner can remove devices"));
  await act(async () => root.render(createElement(DeviceSlotNotice, {
    problem: "no slot", devices: [device("old", "Chrome on macOS", 1)],
    onReplace, onRetry: vi.fn(), onPlans: vi.fn(),
  })));
  const replace = Array.from(host.querySelectorAll("button")).find((node) => node.textContent === "Use this browser instead")!;
  await act(async () => replace.click());
  expect(host.querySelector('[role="alert"]')?.textContent).toBe("only an owner can remove devices");
  expect(replace.disabled).toBe(false);
});
