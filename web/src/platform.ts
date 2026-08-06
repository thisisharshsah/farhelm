/**
 * The parts of the client that only exist in a browser.
 *
 * Everything else lives in `@relayforge/client-core`, which the React Native app
 * shares. What is left here is the three things a browser does differently:
 * `EventSource` for the live stream, `localStorage` for the pairing, and
 * `matchMedia` for guessing whether this is a phone-sized surface.
 */

import {
  HttpTransport,
  PAIRING_STORAGE_KEY,
  createRunnerApi,
  pairingStore,
  type EventStream,
  type ServerEvent,
} from "@relayforge/client-core";
import { idbBackend, migrateFromLocalStorage } from "./idb";

/**
 * Which surface a loopback decision came from.
 *
 * Only a hint: over loopback nobody is paired, so the client asserts its own
 * kind and the runner takes its word. That is fine for a device already inside
 * the trust boundary, and it is why D3 is *also* enforced per registered device
 * kind over the relay, where a client cannot choose its own answer.
 */
export function decisionSurface(): "phone" | "web" {
  return matchMedia("(max-width: 640px)").matches ? "phone" : "web";
}

/** Server-sent events from the runner, with the browser's own reconnection. */
export const eventSourceStream: EventStream = ({ onEvent, onState }) => {
  const source = new EventSource("/v1/events");
  onState("connecting");

  source.onopen = () => onState("open");
  source.onerror = () => onState("closed");
  source.onmessage = (message) => {
    try {
      onEvent(JSON.parse(message.data) as ServerEvent);
    } catch {
      /* a frame we cannot parse is not worth tearing the stream down for */
    }
  };

  return () => source.close();
};

/** The runner over same-origin HTTP — the PWA is served by the runner itself. */
export function loopbackTransport(): HttpTransport {
  return new HttpTransport(
    createRunnerApi(),
    eventSourceStream,
    decisionSurface(),
  );
}

/**
 * The pairing, in IndexedDB.
 *
 * IndexedDB rather than `localStorage` because the **service worker** needs the
 * same key: it is what decrypts the fleet when a push arrives, which is what
 * lets the notification name the actual command and offer Approve. A worker
 * cannot read `localStorage`. See `idb.ts`.
 */
export const webPairingStore = pairingStore(idbBackend);

/** One-time move of a pairing written by a `localStorage` build. */
export const migratePairing = () => migrateFromLocalStorage(PAIRING_STORAGE_KEY);
