/// <reference lib="webworker" />

/**
 * The service worker: app-shell cache, and the wrist path.
 *
 * ## What the notification knows, and how
 *
 * The push carries **no payload** — the relay cannot read the envelope that
 * triggered it, so anything it put in a body would be a guess. But the *device*
 * can read it. So on a wake-up this worker opens the pairing from IndexedDB,
 * connects to the relay itself, decrypts a fleet snapshot, and only then writes
 * the notification.
 *
 * That is why the notification can say `git push --force origin main —
 * payments-api` while the relay still knows nothing. The decryption happens
 * here, on the device, with the device's own key.
 *
 * ## Why approving from the notification is the whole point
 *
 * The product's claim is a permission prompt cleared in under five seconds. A
 * wake-up that only says "something happened" costs an unlock, an app launch, a
 * scroll, and a tap. Approve and Deny as notification actions cost one tap.
 *
 * ## Except for destructive commands
 *
 * `rm -rf`, `git push --force`, `DROP TABLE` and friends get no action buttons —
 * only "Open". This is the same reasoning as D3 refusing them from a watch:
 * convenience must not become catastrophe, and a notification action is *less*
 * deliberate than a wrist tap, not more. The runner enforces its own rule
 * server-side regardless; this is the client declining to offer a button it
 * should not.
 */

import {
  Identity,
  PAIRING_STORAGE_KEY,
  fetchFleetOnce,
  sendCommandOnce,
  type Pairing,
} from "@relayforge/client-core";
import {
  decidedNotification,
  refusalNotification,
  unreachableNotification,
  wakeUpNotification,
  type Notification as Composed,
  type WakeUpContext,
} from "./notification";

declare const self: ServiceWorkerGlobalScope;

const SHELL = "relayforge-shell-v2";

/**
 * Show what `notification.ts` composed.
 *
 * The cast is because TypeScript's `lib.dom` models the *page's*
 * `new Notification()`, which cannot take `actions` or `renotify` — they are
 * meaningful only through `ServiceWorkerRegistration.showNotification`, which
 * is the one this file uses.
 */
function show(composed: Composed): Promise<void> {
  return self.registration.showNotification(
    composed.title,
    composed.options as NotificationOptions,
  );
}

/* ------------------------------------------------------------------ shell */

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(SHELL)
      .then((cache) => cache.addAll(["/", "/manifest.webmanifest", "/icon.svg"]))
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys.filter((key) => key !== SHELL).map((key) => caches.delete(key)),
        ),
      )
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== "GET") return;
  if (url.origin !== location.origin) return;
  // Live data and the event stream always go to the network: a stale session
  // list would show an approval that has already been decided.
  if (url.pathname.startsWith("/v1/")) return;

  event.respondWith(
    fetch(event.request)
      .then((response) => {
        const copy = response.clone();
        void caches.open(SHELL).then((cache) => cache.put(event.request, copy));
        return response;
      })
      .catch(() =>
        caches
          .match(event.request)
          .then((hit) => hit ?? caches.match("/"))
          .then((hit) => hit ?? Response.error()),
      ),
  );
});

/* -------------------------------------------------------------- the pairing */

/**
 * Read the pairing straight from IndexedDB.
 *
 * Duplicated rather than imported from `idb.ts` because that module is written
 * for the page and this bundle must stay small — the worker is fetched on every
 * update check. It is twenty lines and one key.
 */
function readPairing(): Promise<Pairing | null> {
  return new Promise((resolve) => {
    const request = indexedDB.open("relayforge", 1);
    request.onerror = () => resolve(null);
    // If the page has never run, there is no store and nothing to read.
    request.onupgradeneeded = () => request.transaction?.abort();
    request.onsuccess = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains("kv")) {
        db.close();
        resolve(null);
        return;
      }
      const get = db
        .transaction("kv", "readonly")
        .objectStore("kv")
        .get(PAIRING_STORAGE_KEY);
      get.onerror = () => {
        db.close();
        resolve(null);
      };
      get.onsuccess = () => {
        db.close();
        try {
          const pairing = JSON.parse(String(get.result)) as Pairing;
          // Round-trip the key: a pairing whose secret will not load is not a
          // pairing, and finding that out here beats finding out mid-approval.
          Identity.fromSecret(pairing.secret);
          resolve(pairing);
        } catch {
          resolve(null);
        }
      };
    };
  });
}

/* --------------------------------------------------------------------- push */

/** Whether any window is open and in front of the user right now. */
async function hasFocusedWindow(): Promise<boolean> {
  const clients = await self.clients.matchAll({
    type: "window",
    includeUncontrolled: true,
  });
  return clients.some((client) => client.focused);
}

async function tellPages(message: unknown): Promise<void> {
  const clients = await self.clients.matchAll({
    type: "window",
    includeUncontrolled: true,
  });
  for (const client of clients) client.postMessage(message);
}

self.addEventListener("push", (event) => {
  event.waitUntil(wakeUp());
});

async function wakeUp(): Promise<void> {
  // A window in front of the user has the WebSocket and the real screen.
  if (await hasFocusedWindow()) {
    await tellPages({ type: "push-wake" });
    return show(wakeUpNotification({ kind: "focused" }));
  }

  const pairing = await readPairing();
  if (!pairing) return show(wakeUpNotification({ kind: "unpaired" }));

  // The push carried nothing. This is where the notification earns its detail:
  // connect, decrypt with this device's own key, and only then write a body.
  let context: WakeUpContext;
  try {
    context = { kind: "fleet", fleet: await fetchFleetOnce(pairing) };
  } catch {
    // Cellular, a relay restart, a runner that went away between the push and
    // now. The wake-up is still worth showing — just without the detail.
    context = { kind: "unreachable" };
  }
  return show(wakeUpNotification(context));
}

/* ------------------------------------------------------------ acting on it */

self.addEventListener("notificationclick", (event) => {
  const action = event.action;
  const data = event.notification.data as {
    approvalId?: string;
    taskId?: string;
  } | null;
  event.notification.close();

  if ((action === "approve" || action === "deny") && data?.approvalId) {
    event.waitUntil(decide(data.approvalId, action));
    return;
  }
  // A task notification carries no actions, so any tap on it means "show me".
  // Landing on the home screen instead of the diff would make the person you
  // just woke do the navigation you already knew the answer to.
  event.waitUntil(openApp(data?.taskId ? `/#/t/${data.taskId}` : "/"));
});

async function decide(
  approvalId: string,
  action: "approve" | "deny",
): Promise<void> {
  const pairing = await readPairing();
  if (!pairing) return openApp();

  try {
    const { refused } = await sendCommandOnce(pairing, {
      type: "decide",
      approval_id: approvalId,
      decision: action === "approve" ? "approved" : "denied",
    });

    if (refused) {
      // The notification that prompted the tap is already dismissed, so there
      // is nowhere else to put this. A tap that silently did nothing is the
      // worst outcome available.
      await show(refusalNotification(refused));
      return;
    }

    await tellPages({ type: "push-wake" });
    await show(decidedNotification(action));
  } catch {
    await show(unreachableNotification());
  }
}

/** Focus the app rather than opening a second copy of it. */
async function openApp(url = "/"): Promise<void> {
  const clients = await self.clients.matchAll({
    type: "window",
    includeUncontrolled: true,
  });
  for (const client of clients) {
    if ("focus" in client) {
      // An open tab is focused *and* pointed at the right screen. `navigate` is
      // not implemented everywhere, so a failure falls back to plain focus
      // rather than losing the tap.
      if (url !== "/" && "navigate" in client) {
        await client.navigate(url).catch(() => undefined);
      }
      await client.focus();
      return;
    }
  }
  await self.clients.openWindow(url);
}
