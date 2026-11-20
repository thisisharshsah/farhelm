import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { HOLD_STEP_MS, seekSeconds, useHold } from "./hold.ts";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

function mount() {
  const steps: number[] = [];
  const ends = { count: 0 };
  const host = document.createElement("div");
  document.body.append(host);
  function Probe() {
    const hold = useHold(
      (held) => steps.push(Math.round(held)),
      () => (ends.count += 1),
    );
    return createElement("button", hold, "Forward");
  }
  const root = createRoot(host);
  act(() => root.render(createElement(Probe)));
  const button = host.querySelector("button")!;
  const fire = (event: Event) => act(() => void button.dispatchEvent(event));
  return { steps, ends, button, fire, unmount: () => act(() => root.unmount()) };
}

const key = (type: "keydown" | "keyup", repeat = false) => new KeyboardEvent(type, { key: "Enter", repeat, bubbles: true, cancelable: true });
const pointer = (type: string) => new MouseEvent(type, { bubbles: true, cancelable: true, button: 0 });

describe("useHold", () => {
  beforeEach(() => vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "setInterval", "clearInterval", "performance", "Date"] }));
  afterEach(() => vi.useRealTimers());

  it("steps once for a press", () => {
    const t = mount();
    t.fire(key("keydown"));
    t.fire(key("keyup"));
    expect(t.steps).toEqual([0]);
    expect(t.ends.count).toBe(0);
    t.unmount();
  });

  it("keeps stepping on a held key, paced, and ends on release", () => {
    const t = mount();
    t.fire(key("keydown"));
    for (let i = 0; i < 12; i++) {
      vi.advanceTimersByTime(60);
      t.fire(key("keydown", true));
    }
    t.fire(key("keyup"));
    // 720 ms of repeats at most one step per HOLD_STEP_MS: the press, then two more.
    expect(t.steps.length).toBe(3);
    expect(t.steps[0]).toBe(0);
    expect(t.steps[1]).toBeGreaterThanOrEqual(HOLD_STEP_MS);
    expect(t.ends.count).toBe(1);
    t.unmount();
  });

  it("never runs away when a key up never comes", () => {
    const t = mount();
    t.fire(key("keydown"));
    vi.advanceTimersByTime(5000);
    expect(t.steps).toEqual([0]);
    t.unmount();
  });

  it("keeps stepping on a held pointer, without a click after", () => {
    const t = mount();
    t.fire(pointer("pointerdown"));
    vi.advanceTimersByTime(450 + 2 * HOLD_STEP_MS);
    t.fire(pointer("pointerup"));
    t.fire(pointer("click"));
    expect(t.steps.length).toBe(4);
    expect(t.ends.count).toBe(1);
    t.unmount();
  });

  it("treats a click with no press as one step", () => {
    const t = mount();
    t.fire(pointer("click"));
    expect(t.steps).toEqual([0]);
    t.unmount();
  });
});

describe("seekSeconds", () => {
  it("skips 10 seconds on a press and speeds up while held", () => {
    expect(seekSeconds(0, 245)).toBe(10);
    expect(seekSeconds(500, 245)).toBe(10);
    expect(seekSeconds(2000, 245)).toBe(20);
    expect(seekSeconds(3000, 245)).toBe(40);
    // A three-hour stream moves a minute per step, and faster.
    expect(seekSeconds(500, 10_800)).toBe(60);
    expect(seekSeconds(3000, 10_800)).toBe(240);
  });
});
