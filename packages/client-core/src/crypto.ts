/**
 * The device half of RelayForge's end-to-end encryption.
 *
 * This has to interoperate byte-for-byte with `crates/forge-crypto`, which uses
 * NaCl `crypto_box` (X25519 + XSalsa20-Poly1305), and with the watch's Swift
 * implementation in `mobile/watch/`. TweetNaCl's `nacl.box` is the same
 * construction in the same combined form, so they speak to each other directly —
 * but "should interoperate" is not a thing to take on faith, which is why
 * `crypto.test.ts` decrypts a fixture the Rust side generated, and the Swift and
 * Rust suites do the same against their own halves of it.
 *
 * ## Why not WebCrypto
 *
 * WebCrypto can do X25519 in current browsers but has no XSalsa20-Poly1305, so
 * it cannot produce a `crypto_box`. Using it would mean changing the wire format
 * to something WebCrypto and RustCrypto both speak, for the sole benefit of
 * non-extractable keys — which a PWA cannot fully exploit anyway, since the
 * service worker and the page share an origin. React Native has no WebCrypto at
 * all, so the choice also keeps one implementation across three clients.
 *
 * ## Randomness
 *
 * TweetNaCl needs a CSPRNG. Browsers and Node have `crypto.getRandomValues`;
 * React Native does **not** until `react-native-get-random-values` is imported,
 * which `mobile/index.js` does as its very first line. Without it TweetNaCl
 * throws rather than silently producing predictable keys — the right failure.
 */

import nacl from "tweetnacl";
import { CryptoError } from "./errors.ts";
import { fromBase64Url, toBase64Url } from "./base64.ts";

/**
 * Copy into a `Uint8Array` this realm owns.
 *
 * TweetNaCl checks `instanceof Uint8Array`, which is false for a typed array
 * created in a different realm — `TextEncoder` under jsdom is one, and so is
 * anything arriving from a worker, an iframe, or React Native's bridge. The copy
 * is a few bytes and turns a baffling "unexpected type" into a non-issue.
 */
function local(bytes: Uint8Array): Uint8Array {
  return Uint8Array.from(bytes);
}

/* -------------------------------------------------------------------- envelope */

/** Exactly what crosses the relay. Mirrors `forge_crypto::Envelope`. */
export interface Envelope {
  channel: string;
  sender_id: string;
  /** base64url, 24 bytes. */
  nonce: string;
  /** base64url ciphertext including the Poly1305 tag. */
  ciphertext: string;
}

/* -------------------------------------------------------------------- identity */

export class Identity {
  private constructor(
    private readonly secret: Uint8Array,
    readonly publicKey: string,
  ) {}

  static generate(): Identity {
    const pair = nacl.box.keyPair();
    return new Identity(pair.secretKey, toBase64Url(pair.publicKey));
  }

  static fromSecret(secretBase64Url: string): Identity {
    const secret = local(fromBase64Url(secretBase64Url));
    if (secret.length !== nacl.box.secretKeyLength) {
      throw new CryptoError(
        `secret key must be ${nacl.box.secretKeyLength} bytes, got ${secret.length}`,
      );
    }
    const pair = nacl.box.keyPair.fromSecretKey(secret);
    return new Identity(pair.secretKey, toBase64Url(pair.publicKey));
  }

  /** For persistence only. */
  toSecret(): string {
    return toBase64Url(this.secret);
  }

  /** Encrypt for `recipientPublicKey`, authenticated as this device. */
  seal(
    channel: string,
    senderId: string,
    recipientPublicKey: string,
    plaintext: Uint8Array,
  ): Envelope {
    const nonce = nacl.randomBytes(nacl.box.nonceLength);
    const ciphertext = nacl.box(
      local(plaintext),
      nonce,
      fromBase64Url(recipientPublicKey),
      this.secret,
    );
    return {
      channel,
      sender_id: senderId,
      nonce: toBase64Url(nonce),
      ciphertext: toBase64Url(ciphertext),
    };
  }

  /**
   * Decrypt an envelope `senderPublicKey` sealed for this device.
   *
   * Requiring the sender's key is the authentication — an envelope from anyone
   * else fails even though it was correctly addressed.
   */
  open(senderPublicKey: string, envelope: Envelope): Uint8Array {
    const nonce = fromBase64Url(envelope.nonce);
    if (nonce.length !== nacl.box.nonceLength) {
      throw new CryptoError(`nonce must be ${nacl.box.nonceLength} bytes`);
    }
    const opened = nacl.box.open(
      fromBase64Url(envelope.ciphertext),
      nonce,
      fromBase64Url(senderPublicKey),
      this.secret,
    );
    if (!opened) {
      // Deliberately does not say whether the key or the bytes were wrong: a
      // decrypt oracle that distinguishes those is a real attack surface.
      throw new CryptoError("could not decrypt: wrong key or tampered payload");
    }
    return opened;
  }

  sealJson(
    channel: string,
    senderId: string,
    recipientPublicKey: string,
    value: unknown,
  ): Envelope {
    const bytes = new TextEncoder().encode(JSON.stringify(value));
    return this.seal(channel, senderId, recipientPublicKey, bytes);
  }

  openJson<T>(senderPublicKey: string, envelope: Envelope): T {
    const bytes = this.open(senderPublicKey, envelope);
    return JSON.parse(new TextDecoder().decode(bytes)) as T;
  }
}

/* --------------------------------------------------------------------- pairing */

/** What the pairing QR encodes. Mirrors `forge_crypto::PairingOffer`. */
export interface PairingOffer {
  relay_url: string;
  channel: string;
  runner_public_key: string;
  code: string;
  expires_at: number;
}

/** What a device remembers after pairing. */
export interface Pairing {
  relayUrl: string;
  channel: string;
  runnerPublicKey: string;
  /** Assigned by the runner; the `sender_id` on every envelope this device sends. */
  deviceId: string;
  secret: string;
}

/** What the runner calls this device. Drives the D3 rule server-side. */
export type DeviceKind = "phone" | "watch" | "web";

export function parseOffer(payload: string): PairingOffer {
  let parsed: unknown;
  try {
    parsed = JSON.parse(payload.trim());
  } catch {
    throw new CryptoError("that does not look like a pairing code");
  }

  const offer = parsed as Partial<PairingOffer>;
  if (
    typeof offer.channel !== "string" ||
    typeof offer.runner_public_key !== "string" ||
    typeof offer.code !== "string"
  ) {
    throw new CryptoError("pairing code is missing required fields");
  }
  if (
    fromBase64Url(offer.runner_public_key).length !== nacl.box.publicKeyLength
  ) {
    throw new CryptoError("pairing code carries a malformed runner key");
  }
  if (typeof offer.expires_at === "number" && offer.expires_at <= Date.now()) {
    throw new CryptoError("that pairing code has expired — generate a new one");
  }

  return {
    relay_url: offer.relay_url ?? "",
    channel: offer.channel,
    runner_public_key: offer.runner_public_key,
    code: offer.code,
    expires_at: offer.expires_at ?? 0,
  };
}

/**
 * Redeem a pairing code against the runner.
 *
 * This one call goes over plain HTTP, because pairing is by definition the
 * moment before there is a shared key — which is why the code is single-use,
 * short-lived, and only usable by someone who saw the QR. Do it while you can
 * still reach the runner directly; everything after it goes through the relay.
 *
 * `publicKey` is the *device's* — the secret half never leaves the device that
 * generated it, including when a phone claims a code on a watch's behalf.
 */
export async function claimPairing(
  runnerUrl: string,
  offer: PairingOffer,
  kind: DeviceKind,
  publicKey: string,
): Promise<Pairing> {
  if (!offer.relay_url) {
    throw new CryptoError(
      "this runner has no relay configured — start it with --relay to pair a remote device",
    );
  }

  const response = await fetch(`${runnerUrl.replace(/\/$/, "")}/v1/pair/claim`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ code: offer.code, kind, public_key: publicKey }),
  });

  if (!response.ok) {
    let message = response.statusText;
    try {
      const body = (await response.json()) as { error?: string };
      if (body.error) message = body.error;
    } catch {
      /* non-JSON error body */
    }
    throw new CryptoError(message);
  }

  const device = (await response.json()) as { id: string };
  return {
    relayUrl: offer.relay_url,
    channel: offer.channel,
    runnerPublicKey: offer.runner_public_key,
    deviceId: device.id,
    secret: "",
  };
}

/* --------------------------------------------------------------------- storage */

/**
 * Where a pairing is kept. Async because React Native's is: `localStorage` is
 * synchronous, Keychain and AsyncStorage are not, and an interface shaped for
 * the easy platform would have to be broken for the other one.
 *
 * **The web implementation stores the device secret in `localStorage`, in the
 * clear.** Any XSS on that origin steals it and can then approve things as that
 * device. That is real and worth naming rather than burying: the mitigations are
 * that the app loads no third-party script, the service worker caches only the
 * app shell, and a stolen device key is revoked by unpairing — without rotating
 * the runner's key or disturbing any other device. The React Native client does
 * better, keeping the secret in the platform keystore.
 */
export interface PairingStore {
  load(): Promise<Pairing | null>;
  save(pairing: Pairing): Promise<void>;
  forget(): Promise<void>;
}

/** The key both clients store under. */
export const PAIRING_STORAGE_KEY = "forge-device-identity";

/**
 * Build a [`PairingStore`] over any get/set/remove trio.
 *
 * Validates the stored secret on load, so a corrupt entry surfaces at startup
 * rather than on the first approval — and drops it, since a pairing that cannot
 * produce a key is not a pairing.
 */
export function pairingStore(backend: {
  get(key: string): Promise<string | null>;
  set(key: string, value: string): Promise<void>;
  remove(key: string): Promise<void>;
}): PairingStore {
  return {
    async load() {
      const raw = await backend.get(PAIRING_STORAGE_KEY);
      if (!raw) return null;
      try {
        const pairing = JSON.parse(raw) as Pairing;
        Identity.fromSecret(pairing.secret);
        return pairing;
      } catch {
        await backend.remove(PAIRING_STORAGE_KEY);
        return null;
      }
    },
    async save(pairing) {
      await backend.set(PAIRING_STORAGE_KEY, JSON.stringify(pairing));
    },
    async forget() {
      await backend.remove(PAIRING_STORAGE_KEY);
    },
  };
}
