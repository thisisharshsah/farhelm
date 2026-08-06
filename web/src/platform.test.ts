/**
 * The browser-specific layer.
 *
 * Everything portable is tested in `@relayforge/client-core` under Node. What is
 * left here is the three things a browser does differently — `localStorage`,
 * `EventSource`, and `matchMedia` — and the failure modes that only exist
 * because of them.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Identity, PAIRING_STORAGE_KEY, type Pairing } from "@relayforge/client-core";
import { idbBackend } from "./idb";
import {
  decisionSurface,
  eventSourceStream,
  migratePairing,
  webPairingStore,
} from "./platform";

const pairing = (): Pairing => ({
  relayUrl: "wss://relay.test",
  channel: "forge-abc",
  runnerPublicKey: Identity.generate().publicKey,
  deviceId: "dev-1",
  secret: Identity.generate().toSecret(),
});

/* ------------------------------------------------------------------ storage */

/** Start each test from an empty database as well as an empty localStorage. */
async function freshStorage() {
  localStorage.clear();
  await webPairingStore.forget();
}

describe("the pairing store", () => {
  beforeEach(freshStorage);

  it("round-trips a pairing", async () => {
    const saved = pairing();
    await webPairingStore.save(saved);
    expect(await webPairingStore.load()).toEqual(saved);
  });

  it("has nothing to load before pairing", async () => {
    expect(await webPairingStore.load()).toBeNull();
  });

  it("forgets on request", async () => {
    await webPairingStore.save(pairing());
    await webPairingStore.forget();
    expect(await webPairingStore.load()).toBeNull();
    expect(localStorage.getItem(PAIRING_STORAGE_KEY)).toBeNull();
  });

  it("drops a corrupt entry rather than returning it", async () => {
    // A pairing whose key will not load is not a pairing. Surfacing it at
    // startup beats discovering it on the first approval, at the moment it is
    // least welcome.
    await idbBackend.set(PAIRING_STORAGE_KEY, "{ not json");
    expect(await webPairingStore.load()).toBeNull();
    expect(await idbBackend.get(PAIRING_STORAGE_KEY)).toBeNull();
  });

  it("drops an entry whose secret is unusable", async () => {
    await idbBackend.set(
      PAIRING_STORAGE_KEY,
      JSON.stringify({ ...pairing(), secret: "far-too-short" }),
    );
    expect(await webPairingStore.load()).toBeNull();
    expect(await idbBackend.get(PAIRING_STORAGE_KEY)).toBeNull();
  });

  it("is readable by a service worker, which localStorage is not", async () => {
    // The whole reason for IndexedDB here. A worker has no `localStorage`, so a
    // pairing kept there means a push it cannot decrypt — no command in the
    // notification, and no Approve button.
    const saved = pairing();
    await webPairingStore.save(saved);
    // Read through the raw backend, the way `sw.ts` does.
    expect(JSON.parse(String(await idbBackend.get(PAIRING_STORAGE_KEY)))).toEqual(
      saved,
    );
  });
});

/* ---------------------------------------------------------------- migration */

describe("upgrading from a localStorage build", () => {
  beforeEach(freshStorage);

  it("moves an existing pairing across", async () => {
    // Without this, upgrading silently unpairs every device: the app finds
    // nothing, falls back to loopback, and asks you to pair again from a
    // network you are probably not on.
    const saved = pairing();
    localStorage.setItem(PAIRING_STORAGE_KEY, JSON.stringify(saved));

    await migratePairing();

    expect(await webPairingStore.load()).toEqual(saved);
    expect(localStorage.getItem(PAIRING_STORAGE_KEY)).toBeNull();
  });

  it("does nothing when there is nothing to move", async () => {
    await migratePairing();
    expect(await webPairingStore.load()).toBeNull();
  });

  it("does not overwrite a pairing that is already there", async () => {
    // A stale localStorage entry from an older device key must not clobber the
    // one currently in use.
    const current = pairing();
    await webPairingStore.save(current);
    localStorage.setItem(PAIRING_STORAGE_KEY, JSON.stringify(pairing()));

    await migratePairing();

    expect(await webPairingStore.load()).toEqual(current);
    expect(localStorage.getItem(PAIRING_STORAGE_KEY)).toBeNull();
  });

  it("is safe to run more than once", async () => {
    const saved = pairing();
    localStorage.setItem(PAIRING_STORAGE_KEY, JSON.stringify(saved));
    await migratePairing();
    await migratePairing();
    expect(await webPairingStore.load()).toEqual(saved);
  });
});

/* ------------------------------------------------------------------- stream */

class FakeEventSource {
  static last: FakeEventSource | null = null;
  closed = false;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onmessage: ((event: { data: string }) => void) | null = null;

  constructor(readonly url: string) {
    FakeEventSource.last = this;
  }

  close() {
    this.closed = true;
  }
}

describe("the event stream", () => {
  beforeEach(() => vi.stubGlobal("EventSource", FakeEventSource));
  afterEach(() => vi.unstubAllGlobals());

  it("subscribes to the runner's stream", () => {
    eventSourceStream({ onEvent: () => {}, onState: () => {} });
    expect(FakeEventSource.last?.url).toBe("/v1/events");
  });

  it("reports connection state", () => {
    const states: string[] = [];
    eventSourceStream({ onEvent: () => {}, onState: (s) => states.push(s) });

    expect(states).toContain("connecting");
    FakeEventSource.last!.onopen!();
    expect(states.at(-1)).toBe("open");
    FakeEventSource.last!.onerror!();
    expect(states.at(-1)).toBe("closed");
  });

  it("delivers parsed events", () => {
    const seen: unknown[] = [];
    eventSourceStream({ onEvent: (e) => seen.push(e), onState: () => {} });

    FakeEventSource.last!.onmessage!({
      data: JSON.stringify({ type: "session_upsert", session_id: "s1" }),
    });
    expect(seen).toEqual([{ type: "session_upsert", session_id: "s1" }]);
  });

  it("survives a frame it cannot parse", () => {
    const seen: unknown[] = [];
    eventSourceStream({ onEvent: (e) => seen.push(e), onState: () => {} });

    // One bad frame must not take the stream down — the next one still lands.
    expect(() =>
      FakeEventSource.last!.onmessage!({ data: "not json" }),
    ).not.toThrow();
    FakeEventSource.last!.onmessage!({
      data: JSON.stringify({ type: "approval_request" }),
    });
    expect(seen).toHaveLength(1);
  });

  it("closes the source when torn down", () => {
    const stop = eventSourceStream({ onEvent: () => {}, onState: () => {} });
    stop();
    expect(FakeEventSource.last?.closed).toBe(true);
  });
});

/* ------------------------------------------------------------------ surface */

describe("the decision surface", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("calls a narrow viewport a phone", () => {
    vi.stubGlobal("matchMedia", () => ({ matches: true }));
    expect(decisionSurface()).toBe("phone");
  });

  it("calls a wide one web", () => {
    vi.stubGlobal("matchMedia", () => ({ matches: false }));
    expect(decisionSurface()).toBe("web");
  });

  it("never claims to be a watch", () => {
    // Only a device the runner registered as `kind: watch` may be one, and this
    // client cannot be that. If it could name itself a watch, the D3 rule would
    // be a client-side suggestion.
    for (const matches of [true, false]) {
      vi.stubGlobal("matchMedia", () => ({ matches }));
      expect(decisionSurface()).not.toBe("watch");
    }
  });
});
