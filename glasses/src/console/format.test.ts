import { describe, expect, it } from "vitest";
import { greeting, timeAgo } from "./format.ts";

describe("timeAgo", () => {
  const now = Date.UTC(2026, 10, 17, 12);
  it("rounds to the nearest sensible unit", () => {
    expect(timeAgo(now - 10_000, now)).toBe("just now");
    expect(timeAgo(now - 5 * 60_000, now)).toBe("5 minutes ago");
    expect(timeAgo(now - 3 * 3600_000, now)).toBe("3 hours ago");
    expect(timeAgo(now - 86_400_000, now)).toBe("yesterday");
    expect(timeAgo(now + 4 * 86_400_000, now)).toBe("in 4 days");
  });
});

describe("greeting", () => {
  it("follows the time of day", () => {
    expect(greeting(new Date(2026, 10, 17, 9))).toBe("Good morning");
    expect(greeting(new Date(2026, 10, 17, 14))).toBe("Good afternoon");
    expect(greeting(new Date(2026, 10, 17, 21))).toBe("Good evening");
  });
});
