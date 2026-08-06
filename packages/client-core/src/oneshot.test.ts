/**
 * One-shot relay calls.
 *
 * The thing that matters here is not the happy path — it is that **every call
 * settles**. These run inside a service worker's `waitUntil`, and a promise that
 * never resolves there is a worker the browser eventually kills with the socket
 * still open and the user's tap silently lost.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Identity, type Envelope, type Pairing } from "./index.ts";
import { fetchFleetOnce, sendCommandOnce } from "./oneshot.ts";

class FakeSocket {
  static instances: FakeSocket[] = [];
  static autoOpen = true;

  readyState = 0;
  sent: string[] = [];
  closed = false;
  onopen: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onmessage: ((event: { data: string }) => void) | null = null;

  constructor(readonly url: string) {
    FakeSocket.instances.push(this);
    if (FakeSocket.autoOpen) queueMicrotask(() => this.accept());
  }

  send(data: string) {
    this.sent.push(data);
  }
  close() {
    this.closed = true;
  }
  accept() {
    this.readyState = 1;
    this.onopen?.();
  }
  deliver(envelope: Envelope) {
    this.onmessage?.({ data: JSON.stringify(envelope) });
  }
}

const runner = Identity.generate();
const device = Identity.generate();

const pairing: Pairing = {
  relayUrl: "ws://relay.test",
  channel: "forge-test",
  runnerPublicKey: runner.publicKey,
  deviceId: "dev-1",
  secret: device.toSecret(),
};

const fromRunner = (payload: unknown): Envelope =>
  runner.sealJson(pairing.channel, "runner", device.publicKey, payload);

const readSent = (socket: FakeSocket, index = 0): unknown =>
  runner.openJson(
    device.publicKey,
    JSON.parse(socket.sent[index] ?? "{}") as Envelope,
  );

const fleet = {
  sessions: [],
  pending_approvals: [],
  today_usd: 0,
  cache_hit_ratio: 0,
};

const socket = () => FakeSocket.instances.at(-1)!;
/** Let the queued microtask that opens the socket run. */
const opened = () => new Promise((resolve) => setTimeout(resolve, 0));

beforeEach(() => {
  vi.stubGlobal("WebSocket", FakeSocket);
  FakeSocket.instances = [];
  FakeSocket.autoOpen = true;
});

afterEach(() => vi.unstubAllGlobals());

describe("fetching a fleet once", () => {
  it("asks the channel the pairing named", async () => {
    const pending = fetchFleetOnce(pairing);
    await opened();
    expect(socket().url).toBe("ws://relay.test/v1/channel/forge-test");
    expect(readSent(socket())).toEqual({ type: "snapshot" });

    socket().deliver(fromRunner(fleet));
    await expect(pending).resolves.toMatchObject({ sessions: [] });
  });

  it("closes the socket when it is done", async () => {
    const pending = fetchFleetOnce(pairing);
    await opened();
    socket().deliver(fromRunner(fleet));
    await pending;
    expect(socket().closed).toBe(true);
  });

  it("closes the socket when it gives up", async () => {
    const pending = fetchFleetOnce(pairing, 50);
    await opened();
    await expect(pending).rejects.toThrow(/did not answer/);
    expect(socket().closed).toBe(true);
  });

  it("ignores an envelope meant for another device", async () => {
    const other = Identity.generate();
    const pending = fetchFleetOnce(pairing, 60);
    await opened();

    socket().deliver(
      runner.sealJson(pairing.channel, "runner", other.publicKey, fleet),
    );
    // Undecryptable traffic is normal on a shared channel; it must not be
    // mistaken for an answer.
    await expect(pending).rejects.toThrow(/did not answer/);
  });

  it("rejects rather than hanging when the relay is unreachable", async () => {
    FakeSocket.autoOpen = false;
    const pending = fetchFleetOnce(pairing);
    await opened();
    socket().onerror?.();
    await expect(pending).rejects.toThrow(/could not reach/);
  });

  it("rejects rather than hanging when the relay drops the connection", async () => {
    FakeSocket.autoOpen = false;
    const pending = fetchFleetOnce(pairing);
    await opened();
    socket().onclose?.();
    await expect(pending).rejects.toThrow(/closed the connection/);
  });
});

describe("sending one command", () => {
  it("seals it so the relay cannot read it", async () => {
    const pending = sendCommandOnce(
      pairing,
      { type: "decide", approval_id: "a1", decision: "approved" },
      20,
    );
    await opened();

    expect(socket().sent[0]).not.toContain("a1");
    expect(readSent(socket())).toEqual({
      type: "decide",
      approval_id: "a1",
      decision: "approved",
    });
    await expect(pending).resolves.toEqual({ refused: null });
  });

  it("reports a refusal rather than claiming success", async () => {
    // From a notification the user has already dismissed, a silent refusal is
    // unrecoverable — there is nothing left on screen to show an error on.
    const pending = sendCommandOnce(
      pairing,
      { type: "decide", approval_id: "a1", decision: "approved" },
      500,
    );
    await opened();
    socket().deliver(
      fromRunner({
        type: "command_error",
        message: "destructive commands must be approved from the phone",
      }),
    );

    await expect(pending).resolves.toEqual({
      refused: "destructive commands must be approved from the phone",
    });
  });

  it("settles even when the runner says nothing at all", async () => {
    const pending = sendCommandOnce(
      pairing,
      { type: "instruct", session_id: "s1", text: "hi" },
      20,
    );
    await opened();
    await expect(pending).resolves.toEqual({ refused: null });
    expect(socket().closed).toBe(true);
  });
});
