import { describe, expect, it } from "vitest";
import { formatClock, initialTimer, isDone, isRunning, isTimerState, remaining, reset, toggle } from "./timer.ts";

describe("timer", () => {
  it("runs, pauses and resumes from an end time", () => {
    let t = initialTimer(1);
    t = toggle(t, 1_000);
    expect(isRunning(t, 1_000)).toBe(true);
    expect(remaining(t, 31_000)).toBe(30_000);
    t = toggle(t, 31_000);
    expect(t.endsAt).toBeNull();
    expect(remaining(t, 99_000)).toBe(30_000);
    t = toggle(t, 100_000);
    expect(remaining(t, 130_000)).toBe(0);
    expect(isDone(t, 130_000)).toBe(true);
  });
  it("resets when toggled after finishing", () => {
    const t = toggle(initialTimer(1), 0);
    expect(toggle(t, 61_000)).toEqual(initialTimer(1));
  });
  it("resets to a new duration", () => {
    expect(reset(initialTimer(5), 600_000).remainingMs).toBe(600_000);
  });
  it("formats rounding up", () => {
    expect(formatClock(125_000)).toBe("02:05");
    expect(formatClock(1)).toBe("00:01");
    expect(formatClock(0)).toBe("00:00");
  });
  it("validates stored state", () => {
    expect(isTimerState(initialTimer())).toBe(true);
    expect(isTimerState({ durationMs: 1, remainingMs: -1, endsAt: null })).toBe(false);
    expect(isTimerState("x")).toBe(false);
  });
});
