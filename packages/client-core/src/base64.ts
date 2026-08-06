/**
 * base64url, unpadded — the form `forge-crypto` emits and expects.
 *
 * Written out by hand rather than delegating to `atob`/`btoa` or `Buffer`.
 * `atob` is a DOM API and `Buffer` is Node's; this package runs in a browser, in
 * Node under vitest, and on Hermes in React Native, where neither is reliably
 * present. Twenty lines of table lookup is cheaper than a polyfill decision that
 * differs per platform — and it makes the failure mode explicit: a bad character
 * is a [`CryptoError`], not a DOMException from somewhere far away.
 */

import { CryptoError } from "./errors.ts";

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/** Reverse lookup, built once. 255 marks "not a base64url character". */
const REVERSE = (() => {
  const table = new Uint8Array(128).fill(255);
  for (let index = 0; index < ALPHABET.length; index += 1) {
    table[ALPHABET.charCodeAt(index)] = index;
  }
  // Accept the standard alphabet on input too. A runner is not the only thing
  // that might hand us a key, and `+`/`/` decode unambiguously.
  table["+".charCodeAt(0)] = 62;
  table["/".charCodeAt(0)] = 63;
  return table;
})();

export function toBase64Url(bytes: Uint8Array): string {
  let out = "";
  let index = 0;

  for (; index + 2 < bytes.length; index += 3) {
    const chunk = (bytes[index]! << 16) | (bytes[index + 1]! << 8) | bytes[index + 2]!;
    out +=
      ALPHABET[(chunk >> 18) & 63]! +
      ALPHABET[(chunk >> 12) & 63]! +
      ALPHABET[(chunk >> 6) & 63]! +
      ALPHABET[chunk & 63]!;
  }

  // The tail, unpadded: two leftover bytes make three characters, one makes two.
  const left = bytes.length - index;
  if (left === 1) {
    const chunk = bytes[index]! << 16;
    out += ALPHABET[(chunk >> 18) & 63]! + ALPHABET[(chunk >> 12) & 63]!;
  } else if (left === 2) {
    const chunk = (bytes[index]! << 16) | (bytes[index + 1]! << 8);
    out +=
      ALPHABET[(chunk >> 18) & 63]! +
      ALPHABET[(chunk >> 12) & 63]! +
      ALPHABET[(chunk >> 6) & 63]!;
  }

  return out;
}

export function fromBase64Url(encoded: string): Uint8Array {
  // Padding is optional on input; the standard alphabet is accepted above.
  let end = encoded.length;
  while (end > 0 && encoded[end - 1] === "=") end -= 1;

  const remainder = end % 4;
  if (remainder === 1) {
    throw new CryptoError("not valid base64url: truncated");
  }

  const out = new Uint8Array(
    Math.floor(end / 4) * 3 + (remainder === 2 ? 1 : remainder === 3 ? 2 : 0),
  );

  let written = 0;
  let accumulator = 0;
  let bits = 0;

  for (let index = 0; index < end; index += 1) {
    const code = encoded.charCodeAt(index);
    const value = code < 128 ? REVERSE[code]! : 255;
    if (value === 255) {
      throw new CryptoError("not valid base64url");
    }
    accumulator = (accumulator << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[written++] = (accumulator >> bits) & 0xff;
    }
  }

  return out;
}
