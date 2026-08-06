/**
 * The parts of the client that only exist on a phone.
 *
 * Three things differ from the browser:
 *
 * 1. **Storage.** The device secret goes in the platform keystore (Keychain on
 *    iOS, EncryptedSharedPreferences on Android) rather than `localStorage`.
 *    This is the one place the React Native client is meaningfully safer than
 *    the PWA: there is no origin for a script to run on and steal it.
 * 2. **No `EventSource`.** React Native has `fetch` and `WebSocket` but not SSE.
 *    On the runner's own network the app polls; over the relay the WebSocket is
 *    already there and no polling is needed.
 * 3. **No `matchMedia`.** This is a phone. It says so.
 */

import * as SecureStore from "expo-secure-store";
import {
  HttpTransport,
  createRunnerApi,
  pairingStore,
  type EventStream,
  type ServerEvent,
} from "@relayforge/client-core";

/**
 * The pairing, in the platform keystore.
 *
 * `SecureStore` rejects keys with characters outside `[A-Za-z0-9._-]`, which the
 * shared `PAIRING_STORAGE_KEY` satisfies. It also caps values at 2 KB on iOS;
 * a pairing is a few hundred bytes, well inside that.
 */
export const securePairingStore = pairingStore({
  get: (key) => SecureStore.getItemAsync(key),
  set: (key, value) => SecureStore.setItemAsync(key, value),
  remove: (key) => SecureStore.deleteItemAsync(key),
});

/** How often to re-read the fleet when there is no push stream to listen to. */
const POLL_INTERVAL_MS = 3_000;

/**
 * A stand-in for SSE: ask again on a timer.
 *
 * Only used on the runner's own network, where a request costs nothing and the
 * alternative is adding an SSE library for a path the relay replaces anyway. It
 * emits `session_upsert` rather than real events, which is enough — every screen
 * re-reads state on any event; the events only ever say *that* something moved.
 *
 * The cost is that the output tail updates on the poll rather than line by line.
 * Over the relay, where output actually matters at a distance, it streams.
 */
export const pollingStream =
  (api: ReturnType<typeof createRunnerApi>): EventStream =>
  ({ onEvent, onState }) => {
    let stopped = false;
    let timer: ReturnType<typeof setTimeout> | null = null;

    const tick = async () => {
      if (stopped) return;
      try {
        const fleet = await api.fleet();
        onState("open");
        for (const session of fleet.sessions) {
          onEvent({
            type: "session_upsert",
            session_id: session.id,
          } satisfies ServerEvent);
        }
      } catch {
        onState("closed");
      }
      if (!stopped) timer = setTimeout(() => void tick(), POLL_INTERVAL_MS);
    };

    onState("connecting");
    void tick();

    return () => {
      stopped = true;
      if (timer) clearTimeout(timer);
    };
  };

/** The runner over HTTP, for when the phone is on the runner's own network. */
export function loopbackTransport(runnerUrl: string): HttpTransport {
  const api = createRunnerApi(runnerUrl);
  return new HttpTransport(api, pollingStream(api), "phone");
}
