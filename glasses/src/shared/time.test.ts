import { describe, expect, it } from "vitest";
import { shortAgo, spokenDuration } from "./time.ts";

describe("shortAgo", () => {
  const now = Date.UTC(2026, 10, 17, 12);
  it("keeps it short", () => {
    expect(shortAgo(now - 10_000, now)).toBe("now");
    expect(shortAgo(now - 4 * 60_000, now)).toBe("4m");
    expect(shortAgo(now - 2 * 3_600_000, now)).toBe("2h");
  });
});

describe("spokenDuration", () => {
  it("reads like a person would say it", () => {
    expect(spokenDuration(300_000)).toBe("5 min");
    expect(spokenDuration(5_400_000)).toBe("1 h 30 min");
    expect(spokenDuration(90_000)).toBe("1 min 30 s");
  });
});
