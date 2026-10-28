import { describe, expect, it } from "vitest";
import { pct } from "./format.ts";

describe("pct", () => {
  it("returns 'n/a' for null input", () => {
    expect(pct(null)).toBe("n/a");
  });

  it("returns 'n/a' for undefined input", () => {
    expect(pct(undefined)).toBe("n/a");
  });

  it("returns 'n/a' for NaN input", () => {
    expect(pct(NaN)).toBe("n/a");
  });

  it("formats regular numbers correctly", () => {
    expect(pct(0.5)).toBe("50%");
    expect(pct(0.1234, 2)).toBe("12.34%");
    expect(pct(0)).toBe("0%");
  });
});
