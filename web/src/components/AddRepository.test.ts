import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { ProjectRepository, Transport } from "@farhelm/client-core";
import { AddRepository, addable } from "./AddRepository";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
let host: HTMLDivElement;
let root: Root;
beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(async () => { await act(async () => root.unmount()); host.remove(); });

const attached: ProjectRepository = { id: "r1", name: "farhelm", path: "/work/farhelm" };
const found = [{ name: "lacuna", path: "/work/lacuna" }, { name: "farhelm", path: "/work/farhelm" }];

function transport(overrides: Partial<Transport> = {}) {
  return {
    discoverProjectRepositories: vi.fn().mockResolvedValue({ searched: ["/work"], repositories: found, truncated: false }),
    projectRepoCandidates: vi.fn().mockResolvedValue({ repositories: [], next_cursor: null }),
    addProjectRepository: vi.fn().mockResolvedValue({ id: "r2", name: "lacuna", path: "/work/lacuna" }),
    ...overrides,
  } as unknown as Transport;
}

async function render(runner: Transport, onAdded = vi.fn()) {
  await act(async () => root.render(createElement(AddRepository, { transport: runner, projectId: "p", attached: [attached], onAdded })));
  return onAdded;
}

it("offers what it found and what is registered, minus what is attached", () => {
  expect(addable(found, [{ id: "r3", name: "adforge", path: "/x/adforge" }], [attached]).map((repo) => repo.name))
    .toEqual(["adforge", "lacuna"]);
});

it("adds a found repository with one click", async () => {
  const runner = transport();
  const onAdded = await render(runner);
  expect(host.textContent).toContain("lacuna");
  expect(host.querySelector('[aria-label="Add farhelm"]')).toBeNull();
  await act(async () => host.querySelector<HTMLButtonElement>('[aria-label="Add lacuna"]')!.click());
  expect(runner.addProjectRepository).toHaveBeenCalledExactlyOnceWith("p", "/work/lacuna");
  expect(onAdded).toHaveBeenCalledOnce();
});

it("shows why a folder was refused and keeps what was typed", async () => {
  const runner = transport({ addProjectRepository: vi.fn().mockRejectedValue(new Error("/tmp/x is not the top of a Git repository")) });
  const onAdded = await render(runner);
  const input = host.querySelector<HTMLInputElement>("input")!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, "/tmp/x");
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
  await act(async () => host.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })));
  expect(host.textContent).toContain("not the top of a Git repository");
  expect(host.querySelector<HTMLInputElement>("input")!.value).toBe("/tmp/x");
  expect(onAdded).not.toHaveBeenCalled();
});

it("says so when a look fails instead of showing an empty list", async () => {
  await render(transport({ discoverProjectRepositories: vi.fn().mockRejectedValue(new Error("the runner did not answer")) }));
  expect(host.textContent).toContain("the runner did not answer");
  expect(host.textContent).not.toContain("No other repositories");
});
