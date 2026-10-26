import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { Workspace } from "@farhelm/client-core";
import { Sidebar } from "./Sidebar";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
let host: HTMLDivElement;
let root: Root;
type Props = Parameters<typeof Sidebar>[0];
async function render(extra: Partial<Props> = {}) {
  await act(async () => root.render(createElement(Sidebar, {
    workspace: null, activeRunnerId: null, route: { view: "fleet" }, connectionState: "open",
    theme: "system", onNavigate: vi.fn(), onPickRunner: vi.fn(), onCycleTheme: vi.fn(),
    onOpenPalette: vi.fn(), onSignOut: vi.fn(), ...extra,
  })));
}
beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(async () => { await act(async () => root.unmount()); host.remove(); });

it("does not claim a local engine is running for an account with no machine", async () => {
  await render({ workspace: { org: { name: "Synthetic workspace" }, subscription: { plan: "free" }, runners: [] } as unknown as Workspace });
  expect(host.querySelector('[role="status"]')?.textContent).toBe("No machine selected");
  expect(host.querySelector('.rail-status .is-online')).toBeNull();
});

it("distinguishes runner connectivity from model availability", async () => {
  await render({ transportKind: "loopback" });
  expect(host.querySelector('[role="status"]')?.textContent).toBe("Local runner connected");
  await render({ transportKind: "relay", connectionState: "connecting" });
  expect(host.querySelector('[role="status"]')?.textContent).toBe("Connecting…");
});

it("keeps project navigation selected for nested task review", async () => {
  await render({ route: { view: "project-task", projectId: "project", id: "run" } });
  expect(host.querySelector('[aria-current="page"]')?.textContent).toBe("Projects");
});
