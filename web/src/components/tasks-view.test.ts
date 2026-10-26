import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { readTaskView, saveTaskView } from "./tasks-view";

const KEY = "farhelm-tasks-view";

beforeEach(() => localStorage.clear());
afterEach(() => vi.restoreAllMocks());

describe("task layout preference", () => {
  it("uses a validated layout and defaults missing or malformed values to list", () => {
    expect(readTaskView()).toBe("list");
    for (const value of ["list", "bad", "", '{"view":"board"}']) {
      localStorage.setItem(KEY, value);
      expect(readTaskView()).toBe("list");
    }
    localStorage.setItem(KEY, "board");
    expect(readTaskView()).toBe("board");
  });

  it("keeps task review available when browser storage reads are blocked", () => {
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new DOMException("blocked", "SecurityError");
    });
    expect(readTaskView()).toBe("list");
  });

  it("saves a valid layout", () => {
    saveTaskView("board");
    expect(localStorage.getItem(KEY)).toBe("board");
  });

  it("keeps layout toggling available when storage writes fail", () => {
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new DOMException("full", "QuotaExceededError");
    });
    expect(() => saveTaskView("board")).not.toThrow();
  });
});
