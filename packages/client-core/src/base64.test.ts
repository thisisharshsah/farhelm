/**
 * The base64url codec, checked against Node's.
 *
 * This is hand-written because no single base64 API exists across the browser,
 * Node, and Hermes — which means it is also the one place in this package where
 * a subtle off-by-one would corrupt keys silently. Node's `Buffer` is the oracle
 * here; it is not available on the platforms this code exists for, but it is
 * available in the test runner, which is the whole point.
 */

import { describe, expect, it } from "vitest";
import { CryptoError } from "./errors.ts";
import { fromBase64Url, toBase64Url } from "./base64.ts";

const oracle = (bytes: Uint8Array) => Buffer.from(bytes).toString("base64url");

describe("encoding", () => {
  it("agrees with Node for every length up to 64", () => {
    for (let length = 0; length <= 64; length += 1) {
      // A deterministic but non-trivial pattern: every byte value appears, and
      // the three-byte grouping never lines up with a repeating period.
      const bytes = Uint8Array.from({ length }, (_, i) => (i * 37 + 11) & 0xff);
      expect(toBase64Url(bytes), `length ${length}`).toBe(oracle(bytes));
    }
  });

  it("agrees with Node on every single byte value", () => {
    for (let value = 0; value < 256; value += 1) {
      const bytes = new Uint8Array([value]);
      expect(toBase64Url(bytes), `byte ${value}`).toBe(oracle(bytes));
    }
  });

  it("emits the url-safe alphabet, unpadded", () => {
    // 0xff 0xfe 0xfd is exactly where the two alphabets disagree.
    const encoded = toBase64Url(new Uint8Array([255, 254, 253]));
    expect(encoded).toBe("__79");
    expect(encoded).not.toContain("=");
  });

  it("encodes nothing as nothing", () => {
    expect(toBase64Url(new Uint8Array(0))).toBe("");
  });
});

describe("decoding", () => {
  it("round-trips every length up to 64", () => {
    for (let length = 0; length <= 64; length += 1) {
      const bytes = Uint8Array.from({ length }, (_, i) => (i * 53 + 7) & 0xff);
      expect(fromBase64Url(toBase64Url(bytes)), `length ${length}`).toEqual(
        bytes,
      );
    }
  });

  it("reads what Node wrote", () => {
    const bytes = Uint8Array.from({ length: 32 }, (_, i) => (i * 7) & 0xff);
    expect(fromBase64Url(oracle(bytes))).toEqual(bytes);
  });

  it("accepts the padded standard alphabet too", () => {
    const bytes = new Uint8Array([255, 254, 253, 0, 1]);
    const standard = Buffer.from(bytes).toString("base64");
    expect(standard).toContain("=");
    expect(fromBase64Url(standard)).toEqual(bytes);
  });

  it("rejects a stray character rather than silently dropping it", () => {
    expect(() => fromBase64Url("abc*def")).toThrow(CryptoError);
    expect(() => fromBase64Url("abc def")).toThrow(CryptoError);
  });

  it("rejects a length that cannot be a whole number of bytes", () => {
    // A 4n+1 group carries 6 bits — not enough for a byte, so it is truncation.
    expect(() => fromBase64Url("AAAAA")).toThrow(/truncated/);
  });

  it("produces exactly the right length, not a padded buffer", () => {
    // The bug this catches: sizing the output by `length / 4 * 3` and leaving
    // trailing zeros, which would make a 32-byte key decode to 33 bytes.
    expect(fromBase64Url(toBase64Url(new Uint8Array(32)))).toHaveLength(32);
    expect(fromBase64Url(toBase64Url(new Uint8Array(31)))).toHaveLength(31);
    expect(fromBase64Url(toBase64Url(new Uint8Array(1)))).toHaveLength(1);
  });
});
