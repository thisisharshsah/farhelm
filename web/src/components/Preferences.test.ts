import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { Preferences } from "./Preferences";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
let host: HTMLDivElement;
let root: Root;
beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(async () => { await act(async () => root.unmount()); host.remove(); });

it("shows the chosen theme as pressed and reports a new choice", async () => {
  const onTheme = vi.fn();
  await act(async () => root.render(createElement(Preferences, {
    theme: "system", onTheme, connection: "On this machine only", machineName: "Local runner", sessions: 2,
  })));
  const pressed = Array.from(host.querySelectorAll('[aria-pressed="true"]')).map((node) => node.textContent);
  expect(pressed).toEqual(["System"]);
  const dark = Array.from(host.querySelectorAll("button")).find((node) => node.textContent === "Dark")!;
  await act(async () => dark.click());
  expect(onTheme).toHaveBeenCalledExactlyOnceWith("dark");
  expect(host.textContent).toContain("On this machine only");
});
