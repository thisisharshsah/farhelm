/**
 * WebPush, on the browser side.
 *
 * Three things have to line up before a phone can be woken, and all three fail
 * quietly if you let them:
 *
 * 1. **The app must be installed to the home screen on iOS.** Safari refuses
 *    `Notification.requestPermission()` from a browser tab — it does not prompt
 *    and does not throw, it just resolves `"denied"`. That is the single most
 *    common reason push "doesn't work", so it is detected and named.
 * 2. **Permission must be granted from a user gesture.** Asking on load is both
 *    rude and, in some browsers, automatically denied.
 * 3. **The relay must have a VAPID key.** One started without `--vapid-key`
 *    answers 503, which is a supported way to run one.
 */

import {
  applicationServerKey,
  registerPush,
  vapidPublicKey,
  type Pairing,
} from "@relayforge/client-core";

export type PushState =
  | { status: "unsupported"; reason: string }
  | { status: "needs-install" }
  | { status: "denied" }
  | { status: "off" }
  | { status: "on" };

/** Is this a home-screen install rather than a browser tab? */
export function isInstalled(): boolean {
  return (
    matchMedia("(display-mode: standalone)").matches ||
    // The iOS-only legacy signal, which is still the reliable one there.
    ("standalone" in navigator && navigator.standalone === true)
  );
}

const isIOS = () =>
  /iPad|iPhone|iPod/.test(navigator.userAgent) ||
  // iPadOS reports as a Mac; the touch points give it away.
  (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);

export async function pushState(): Promise<PushState> {
  if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
    // iOS below 16.4 lands here, as does anything without a service worker.
    return isIOS() && !isInstalled()
      ? { status: "needs-install" }
      : { status: "unsupported", reason: "this browser has no Push API" };
  }
  if (isIOS() && !isInstalled()) return { status: "needs-install" };
  if (Notification.permission === "denied") return { status: "denied" };

  const registration = await navigator.serviceWorker.ready;
  const existing = await registration.pushManager.getSubscription();
  return existing ? { status: "on" } : { status: "off" };
}

/**
 * Ask for permission and register. Call this from a click, never on load.
 *
 * Returns the state afterwards rather than throwing for the ordinary refusals —
 * a denied prompt is a choice, not an error.
 */
export async function enablePush(pairing: Pairing): Promise<PushState> {
  const before = await pushState();
  if (before.status === "unsupported" || before.status === "needs-install") {
    return before;
  }

  const key = await vapidPublicKey(pairing.relayUrl);
  if (!key) {
    return {
      status: "unsupported",
      reason: "this relay was started without --vapid-key, so it cannot wake devices",
    };
  }

  if (Notification.permission !== "granted") {
    if ((await Notification.requestPermission()) !== "granted") {
      return { status: "denied" };
    }
  }

  const registration = await navigator.serviceWorker.ready;
  const subscription =
    (await registration.pushManager.getSubscription()) ??
    (await registration.pushManager.subscribe({
      // Required by every browser. A push nobody sees is a push that gets the
      // permission revoked.
      userVisibleOnly: true,
      applicationServerKey: applicationServerKey(key),
    }));

  const json = subscription.toJSON();
  if (!json.keys?.p256dh || !json.keys.auth) {
    return { status: "unsupported", reason: "the browser gave no encryption keys" };
  }

  await registerPush(pairing, {
    endpoint: subscription.endpoint,
    p256dh: json.keys.p256dh,
    auth: json.keys.auth,
  });
  return { status: "on" };
}

/**
 * Stop being woken.
 *
 * Only unsubscribes locally. The relay keeps subscriptions in memory and drops
 * them on the push service's first 410, so there is nothing durable to clean up
 * — which is the same reason it has no endpoint to ask.
 */
export async function disablePush(): Promise<PushState> {
  const registration = await navigator.serviceWorker.ready;
  const subscription = await registration.pushManager.getSubscription();
  await subscription?.unsubscribe();
  return { status: "off" };
}
