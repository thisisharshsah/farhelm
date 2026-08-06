/**
 * The pairing, in IndexedDB.
 *
 * It used to be in `localStorage`, which was fine while only the page needed
 * it. The service worker changed that: **a service worker cannot read
 * `localStorage`** — the API is synchronous and simply is not exposed to
 * workers. Without a store both can reach, the worker handling a push has no
 * key, so it cannot decrypt anything, so the notification can only say
 * "something happened" and the Approve button cannot exist.
 *
 * IndexedDB is available in both. That is the entire reason for this file.
 *
 * The security posture is unchanged and still worth stating plainly: this is
 * origin-scoped storage in the clear. Any XSS on this origin steals the device
 * key and can approve as this device. The mitigations are that the app loads no
 * third-party script, the service worker caches only the app shell, and a stolen
 * key is revoked by unpairing — without rotating the runner's key or disturbing
 * any other device. The React Native client does better, using the platform
 * keystore; a browser has no equivalent a PWA can actually benefit from.
 */

const DB_NAME = "relayforge";
const DB_VERSION = 1;
const STORE = "kv";

function open(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(STORE)) db.createObjectStore(STORE);
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("indexedDB"));
  });
}

function transact<T>(
  mode: IDBTransactionMode,
  run: (store: IDBObjectStore) => IDBRequest<T>,
): Promise<T> {
  return open().then(
    (db) =>
      new Promise<T>((resolve, reject) => {
        const transaction = db.transaction(STORE, mode);
        const request = run(transaction.objectStore(STORE));
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error ?? new Error("indexedDB"));
        transaction.oncomplete = () => db.close();
      }),
  );
}

/** A get/set/remove backend for `pairingStore`, usable from page or worker. */
export const idbBackend = {
  async get(key: string): Promise<string | null> {
    const value = await transact<unknown>("readonly", (store) =>
      store.get(key) as IDBRequest<unknown>,
    );
    return typeof value === "string" ? value : null;
  },
  async set(key: string, value: string): Promise<void> {
    await transact("readwrite", (store) => store.put(value, key));
  },
  async remove(key: string): Promise<void> {
    await transact("readwrite", (store) => store.delete(key));
  },
};

/**
 * Move a pairing left in `localStorage` by an earlier version.
 *
 * Runs once, from the page — the worker never sees `localStorage` at all, which
 * is the whole problem. Without this, upgrading would silently unpair every
 * device: the app would find nothing, fall back to loopback, and ask you to pair
 * again from a network you are probably not on.
 *
 * Deliberately does not delete the old entry until the new one is confirmed
 * written. Losing a device key to a half-finished migration is not recoverable
 * without physical access to the runner.
 */
export async function migrateFromLocalStorage(key: string): Promise<void> {
  if (typeof localStorage === "undefined") return;
  const legacy = localStorage.getItem(key);
  if (legacy === null) return;

  try {
    if ((await idbBackend.get(key)) === null) {
      await idbBackend.set(key, legacy);
      if ((await idbBackend.get(key)) !== legacy) return;
    }
    localStorage.removeItem(key);
  } catch {
    // Keep the legacy copy. An app that still works from `localStorage` beats
    // one that lost its key to a storage error.
  }
}
