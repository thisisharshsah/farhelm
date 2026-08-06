/**
 * Registering for wake-ups.
 *
 * A paired device only sees what the runner says while it is connected. The
 * relay is the only always-reachable party, so it is what wakes a sleeping
 * phone — but it cannot read the envelope that triggered the wake-up, so the
 * push carries **no payload**. The device wakes, connects, decrypts locally, and
 * only then knows what happened.
 *
 * That is why there is no `title` or `body` anywhere in this file. There is
 * nothing truthful to put in one until the device has opened an envelope.
 *
 * This module is the platform-free half: fetching the relay's VAPID key and
 * registering a subscription. Getting the subscription itself is per-platform —
 * `PushManager` on the web, APNs/FCM on React Native — so it is passed in.
 */

import { ApiError } from "./api.ts";
import { fromBase64Url } from "./base64.ts";
import type { Pairing } from "./crypto.ts";

/** What a push service gives a device, in the shape the relay stores. */
export interface PushSubscription {
  endpoint: string;
  /** The device's public key for payload encryption, base64url, 65 bytes. */
  p256dh: string;
  /** The device's auth secret, base64url, 16 bytes. */
  auth: string;
}

/**
 * Fetch the relay's `applicationServerKey`.
 *
 * Public by definition — a browser cannot subscribe without it — and it
 * authenticates the *relay* to the push service, not the other way round.
 * Returns `null` when the relay was started without push configured, which is a
 * supported way to run one rather than an error.
 */
export async function vapidPublicKey(relayUrl: string): Promise<string | null> {
  const response = await fetch(`${httpFrom(relayUrl)}/v1/push/vapid`);
  if (response.status === 503) return null;
  if (!response.ok) {
    throw new ApiError("could not read the relay's push key", response.status);
  }
  const body = (await response.json()) as { publicKey?: string };
  if (!body.publicKey) {
    throw new ApiError("the relay returned no push key", 502);
  }
  return body.publicKey;
}

/** Register a subscription against the pairing's channel. */
export async function registerPush(
  pairing: Pairing,
  subscription: PushSubscription,
): Promise<void> {
  const response = await fetch(
    `${httpFrom(pairing.relayUrl)}/v1/push/${encodeURIComponent(pairing.channel)}/subscribe`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(subscription),
    },
  );
  if (!response.ok) {
    throw new ApiError("the relay refused the push subscription", response.status);
  }
}

/**
 * The relay is reached over `ws(s)://` for channels and `http(s)://` for
 * everything else. One stored URL, two schemes.
 */
export function httpFrom(relayUrl: string): string {
  return relayUrl.replace(/^ws/, "http").replace(/\/$/, "");
}

/**
 * The `applicationServerKey` as `pushManager.subscribe` wants it.
 *
 * It takes raw bytes, not the base64url string the relay serves — passing the
 * string produces an `InvalidCharacterError` from deep inside the Push API with
 * nothing pointing at the cause.
 *
 * Returned as an `ArrayBuffer` rather than a `Uint8Array`: the Push API's type
 * is `BufferSource` narrowed to a non-shared buffer, and a `Uint8Array` from a
 * generic context does not satisfy it. Handing over the buffer sidesteps the
 * question entirely.
 */
export function applicationServerKey(vapidPublicKeyBase64Url: string): ArrayBuffer {
  const bytes = fromBase64Url(vapidPublicKeyBase64Url);
  const buffer = new ArrayBuffer(bytes.length);
  new Uint8Array(buffer).set(bytes);
  return buffer;
}
