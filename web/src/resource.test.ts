import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { useResource } from "./hooks";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
let host: HTMLDivElement;
let root: Root;
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((yes) => { resolve = yes; });
  return { promise, resolve };
}
function Screen({ identity, revision, load }: { identity: string; revision: number; load: () => Promise<string> }) {
  const resource = useResource(load, [identity, revision], [identity]);
  return createElement("div", null,
    createElement("span", { "data-value": true }, resource.data),
    createElement("span", { role: "status" }, resource.loading ? "Loading" : resource.stale ? "Refreshing" : "Ready"),
    resource.error ? createElement("p", { role: "alert" }, resource.error) : null);
}
async function render(identity: string, revision: number, load: () => Promise<string>) {
  await act(async () => root.render(createElement(Screen, { identity, revision, load })));
}
beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(async () => { await act(async () => root.unmount()); host.remove(); });

it("clears the old runner immediately and ignores its late response", async () => {
  await render("runner-a", 0, async () => "Private A");
  const old = deferred<string>();
  await render("runner-a", 1, () => old.promise);
  const next = deferred<string>();
  await render("runner-b", 0, () => next.promise);
  expect(host.textContent).not.toContain("Private A");
  expect(host.textContent).toContain("Loading");
  await act(async () => old.resolve("Late A"));
  expect(host.textContent).not.toContain("Late A");
  await act(async () => next.resolve("Private B"));
  expect(host.textContent).toBe("Private BReady");
});

it("retains refresh data only within the same identity and exposes failure", async () => {
  await render("runner-a", 0, async () => "Current A");
  const pending = deferred<string>();
  await render("runner-a", 1, () => pending.promise);
  expect(host.textContent).toBe("Current ARefreshing");
  await act(async () => pending.resolve("Fresh A"));
  await render("runner-a", 2, vi.fn().mockRejectedValue(new Error("offline")));
  expect(host.textContent).toBe("Fresh AReadyoffline");
  await render("runner-b", 0, vi.fn().mockRejectedValue(new Error("unavailable B")));
  expect(host.textContent).not.toContain("Fresh A");
  expect(host.textContent).not.toContain("offline");
  expect(host.querySelector('[role="alert"]')?.textContent).toBe("unavailable B");
});
