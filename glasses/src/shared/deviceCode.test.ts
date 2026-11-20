import { describe, expect, it } from "vitest";
import { USER_CODE_ALPHABET, formatUserCode, generateUserCode, normalizeUserCode } from "./deviceCode.ts";

describe("user codes", () => {
  it("normalizes what a person types", () => {
    expect(normalizeUserCode("bcdf ghjk")).toBe("BCDFGHJK");
    expect(normalizeUserCode("BCDF-GHJK")).toBe("BCDFGHJK");
  });
  it("rejects vowels, digits and the wrong length", () => {
    expect(normalizeUserCode("ABCD-EFGH")).toBeNull();
    expect(normalizeUserCode("BCDF-GHJ")).toBeNull();
    expect(normalizeUserCode("BCDF-GHJ1")).toBeNull();
  });
  it("generates valid codes even from a biased source", () => {
    // Bytes at or above 240 must be skipped, never folded into the alphabet.
    let n = 0;
    const source = (b: Uint8Array) => b.map(() => (n++ % 2 === 0 ? 255 : 7));
    const code = generateUserCode(source);
    expect(code).toHaveLength(8);
    expect(normalizeUserCode(code)).toBe(code);
    expect(code).toBe(USER_CODE_ALPHABET[7]!.repeat(8));
  });
  it("formats in two groups", () => {
    expect(formatUserCode("BCDFGHJK")).toBe("BCDF-GHJK");
  });
});
