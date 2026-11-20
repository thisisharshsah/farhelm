/**
 * The short code the glasses show while pairing (OAuth device flow, RFC 8628
 * section 6.1): consonants only, so no words and no 0/O or 1/I confusion,
 * shown as two groups of four. 20^8 is about 2.6e10 codes, and each lives ten
 * minutes behind a rate limit.
 */
export const USER_CODE_ALPHABET = "BCDFGHJKLMNPQRSTVWXZ";
export const USER_CODE_LENGTH = 8;

/** "bcdf ghjk", "BCDF-GHJK" -> "BCDFGHJK", or null when it cannot be a code. */
export function normalizeUserCode(raw: string): string | null {
  const code = raw.toUpperCase().replace(/[^A-Z]/g, "");
  if (code.length !== USER_CODE_LENGTH) return null;
  for (const ch of code) if (!USER_CODE_ALPHABET.includes(ch)) return null;
  return code;
}

/** "BCDFGHJK" -> "BCDF-GHJK" */
export const formatUserCode = (code: string): string => `${code.slice(0, 4)}-${code.slice(4)}`;

/** A fresh code from a random source, without modulo bias. */
export function generateUserCode(random: (bytes: Uint8Array) => Uint8Array): string {
  let code = "";
  const limit = 256 - (256 % USER_CODE_ALPHABET.length); // 240
  while (code.length < USER_CODE_LENGTH) {
    for (const b of random(new Uint8Array(16))) {
      if (b < limit && code.length < USER_CODE_LENGTH) code += USER_CODE_ALPHABET[b % USER_CODE_ALPHABET.length];
    }
  }
  return code;
}
