/**
 * The relay transport, driven against a fake socket and a real runner identity.
 *
 * The interesting behaviour is not the crypto — `crypto.test.ts` covers that —
 * but the correlation: the relay is a fan-out channel with no request/response,
 * so a reply is matched to a waiting call by its *shape*. Getting that wrong is
 * silent: the fleet promise resolves with a session detail, or a live event gets
 * swallowed by a pending request and the screen never updates.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  Identity,
  RelayTransport,
  type ConnectionState,
  type Envelope,
  type Pairing,
} from "./index.ts";

/* A WebSocket stand-in that records what was sent and lets tests push frames. */
class FakeSocket {
  static instances: FakeSocket[] = [];
  static readonly OPEN = 1;
  static readonly CLOSED = 3;

  readyState = 0;
  sent: string[] = [];
  onopen: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onmessage: ((event: { data: string }) => void) | null = null;

  constructor(readonly url: string) {
    FakeSocket.instances.push(this);
  }

  send(data: string) {
    this.sent.push(data);
  }

  close() {
    this.readyState = FakeSocket.CLOSED;
    this.onclose?.();
  }

  /** Simulate the relay accepting the connection. */
  accept() {
    this.readyState = FakeSocket.OPEN;
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

/** What the runner would put on the wire for this device. */
const fromRunner = (payload: unknown): Envelope =>
  runner.sealJson(pairing.channel, "runner", device.publicKey, payload);

/** What the device sent, as the runner would read it. */
const readSent = (socket: FakeSocket, index = 0): unknown =>
  runner.openJson(
    device.publicKey,
    JSON.parse(socket.sent[index] ?? "{}") as Envelope,
  );

const fleetPayload = {
  sessions: [],
  pending_approvals: [],
  today_usd: 1.5,
  cache_hit_ratio: 0.8,
};

const sessionPayload = (id: string) => ({
  id,
  repo_name: "forge",
  machine_name: "laptop",
  steps: [],
  output: [],
});

let transport: RelayTransport;

beforeEach(() => {
  vi.stubGlobal("WebSocket", FakeSocket);
  FakeSocket.instances = [];
  vi.useFakeTimers();
  transport = new RelayTransport(pairing);
});

afterEach(() => {
  transport.close();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

const socket = () => FakeSocket.instances.at(-1)!;

describe("connecting", () => {
  it("opens the channel the pairing named", () => {
    expect(socket().url).toBe("ws://relay.test/v1/channel/forge-test");
  });

  it("reports open and closed to a listener", () => {
    const states: ConnectionState[] = [];
    transport.onConnectionChange((state) => states.push(state));

    socket().accept();
    expect(states).toContain("open");

    socket().close();
    expect(states.at(-1)).toBe("closed");
  });

  it("reconnects after a drop, backing off", () => {
    socket().accept();
    socket().close();
    expect(FakeSocket.instances).toHaveLength(1);

    vi.advanceTimersByTime(1_000);
    expect(FakeSocket.instances).toHaveLength(2);

    // Second failure waits longer than the first.
    socket().close();
    vi.advanceTimersByTime(1_000);
    expect(FakeSocket.instances).toHaveLength(2);
    vi.advanceTimersByTime(1_000);
    expect(FakeSocket.instances).toHaveLength(3);
  });

  it("stops reconnecting once closed deliberately", () => {
    socket().accept();
    transport.close();
    vi.advanceTimersByTime(60_000);
    expect(FakeSocket.instances).toHaveLength(1);
  });
});

describe("commands", () => {
  beforeEach(() => socket().accept());

  it("seals a decision so the relay cannot read it", async () => {
    await transport.decide("appr-1", "approved");

    const raw = socket().sent[0]!;
    expect(raw).not.toContain("appr-1");
    expect(raw).not.toContain("approved");
    expect(readSent(socket())).toEqual({
      type: "decide",
      approval_id: "appr-1",
      decision: "approved",
    });
  });

  it("names the device as the sender so the runner can check its kind", () => {
    void transport.fleet();
    const envelope = JSON.parse(socket().sent[0]!) as Envelope;
    expect(envelope.sender_id).toBe("dev-1");
    expect(envelope.channel).toBe("forge-test");
  });

  it("refuses to send while the socket is down", async () => {
    socket().close();
    await expect(transport.instruct("s1", "hello")).rejects.toThrow(
      /not connected/,
    );
  });
});

describe("snapshot correlation", () => {
  beforeEach(() => socket().accept());

  it("resolves a fleet request from the runner's reply", async () => {
    const pending = transport.fleet();
    socket().deliver(fromRunner(fleetPayload));
    await expect(pending).resolves.toMatchObject({ today_usd: 1.5 });
  });

  it("does not hand a session detail to a waiting fleet request", async () => {
    const pending = transport.fleet();
    socket().deliver(fromRunner(sessionPayload("s1")));
    socket().deliver(fromRunner(fleetPayload));
    await expect(pending).resolves.toMatchObject({ today_usd: 1.5 });
  });

  it("matches a session reply by id, not merely by shape", async () => {
    const pending = transport.session("s2");
    socket().deliver(fromRunner(sessionPayload("s1")));
    socket().deliver(fromRunner(sessionPayload("s2")));
    await expect(pending).resolves.toMatchObject({ id: "s2" });
  });

  it("gives up rather than hanging when the runner never answers", async () => {
    const pending = transport.fleet();
    const assertion = expect(pending).rejects.toThrow(/did not answer/);
    vi.advanceTimersByTime(10_000);
    await assertion;
  });

  it("delivers a live event to listeners, not to a pending request", async () => {
    const events: unknown[] = [];
    transport.onEvent((event) => events.push(event));

    const pending = transport.fleet();
    socket().deliver(
      fromRunner({
        type: "output_chunk",
        session_id: "s1",
        seq: 1,
        text: "hi",
        at_ms: 0,
      }),
    );
    expect(events).toHaveLength(1);

    socket().deliver(fromRunner(fleetPayload));
    await pending;
    // The snapshot was claimed by the request, not leaked to the event stream.
    expect(events).toHaveLength(1);
  });

  it("surfaces a refusal rather than letting the command vanish", () => {
    const events: unknown[] = [];
    transport.onEvent((event) => events.push(event));

    void transport.decide("appr-1", "approved");
    socket().deliver(
      fromRunner({
        type: "command_error",
        message: "destructive commands must be approved from the phone",
      }),
    );

    expect(events).toEqual([
      {
        type: "command_error",
        message: "destructive commands must be approved from the phone",
      },
    ]);
  });

  it("ignores an envelope meant for a different paired device", async () => {
    const events: unknown[] = [];
    transport.onEvent((event) => events.push(event));

    const other = Identity.generate();
    socket().deliver(
      runner.sealJson(pairing.channel, "runner", other.publicKey, fleetPayload),
    );

    expect(events).toHaveLength(0);
  });

  it("ignores a frame that is not an envelope at all", () => {
    const events: unknown[] = [];
    transport.onEvent((event) => events.push(event));
    socket().onmessage?.({ data: "not json" });
    expect(events).toHaveLength(0);
  });
});

describe("the cost dashboard", () => {
  const dashboardPayload = (sessionId: string) => ({
    session_id: sessionId,
    repo_name: "forge",
    calls: 12,
    total_usd: 0.41,
    cache_hit_ratio: 0.93,
    by_tier: [{ tier: "large", usd: 0.41, share: 1 }],
    avoided_calls: 3,
    spend_series: [{ at_ms: 0, usd: 0.41 }],
    budget: { cap_usd: 5, spent_usd: 0.41, pct: 0.08, state: "ok" },
  });

  beforeEach(() => socket().accept());

  it("is available over the relay", async () => {
    expect(transport.supportsDashboard).toBe(true);

    const pending = transport.dashboard("s1");
    socket().deliver(fromRunner(dashboardPayload("s1")));
    await expect(pending).resolves.toMatchObject({ total_usd: 0.41 });
  });

  it("asks for the window the caller wanted", async () => {
    void transport.dashboard("s1", 1_700_000_000_000);
    expect(readSent(socket())).toEqual({
      type: "dashboard_snapshot",
      session_id: "s1",
      since_ms: 1_700_000_000_000,
    });
  });

  it("sends a null window rather than omitting the field", async () => {
    void transport.dashboard("s1");
    expect(readSent(socket())).toMatchObject({ since_ms: null });
  });

  it("matches by session id, not merely by shape", async () => {
    const pending = transport.dashboard("s2");
    socket().deliver(fromRunner(dashboardPayload("s1")));
    socket().deliver(fromRunner(dashboardPayload("s2")));
    await expect(pending).resolves.toMatchObject({ session_id: "s2" });
  });

  it("does not hand a dashboard to a waiting session request", async () => {
    // Both describe the same session, so a matcher that stopped at the id
    // would resolve the session promise with a pile of cost numbers.
    const pending = transport.session("s1");
    socket().deliver(fromRunner(dashboardPayload("s1")));
    socket().deliver(fromRunner(sessionPayload("s1")));
    await expect(pending).resolves.toMatchObject({ steps: [] });
  });

  it("does not hand a session detail to a waiting dashboard request", async () => {
    const pending = transport.dashboard("s1");
    socket().deliver(fromRunner(sessionPayload("s1")));
    socket().deliver(fromRunner(dashboardPayload("s1")));
    await expect(pending).resolves.toMatchObject({ calls: 12 });
  });
});

describe("reviewing a change set", () => {
  const taskPayload = (id: string) => ({
    id,
    repo_name: "forge",
    status: "awaiting_review",
    changes: { files: [] },
    patch: "",
    output: [],
  });

  beforeEach(() => socket().accept());

  it("matches a task reply by id, not merely by shape", async () => {
    const pending = transport.task("t2");
    socket().deliver(fromRunner(taskPayload("t1")));
    socket().deliver(fromRunner(taskPayload("t2")));
    await expect(pending).resolves.toMatchObject({ id: "t2" });
  });

  it("does not hand a task detail to a waiting session request", async () => {
    // Both carry an `id`; only one carries `steps`. A shape matcher that gave
    // up at `id` would resolve the session promise with a diff.
    const pending = transport.session("s2");
    socket().deliver(fromRunner(taskPayload("s2")));
    socket().deliver(fromRunner(sessionPayload("s2")));
    await expect(pending).resolves.toMatchObject({ steps: [] });
  });

  it("sends a review as a command the runner will act on", async () => {
    await transport.reviewTask("t1", "reject", "this breaks the retry cap");

    expect(readSent(socket())).toEqual({
      type: "review_task",
      task_id: "t1",
      decision: "reject",
      note: "this breaks the retry cap",
    });
  });

  it("sends a null note rather than omitting the field", async () => {
    await transport.reviewTask("t1", "approve");
    expect(readSent(socket())).toMatchObject({ note: null });
  });

  it("surfaces a refusal to review from a watch", async () => {
    const events: unknown[] = [];
    transport.onEvent((event) => events.push(event));

    await transport.reviewTask("t1", "approve");
    socket().deliver(
      fromRunner({
        type: "command_error",
        message: "a change set cannot be approved from a watch",
      }),
    );

    expect(events).toHaveLength(1);
  });

  it("starts a task over the relay and waits for the row", async () => {
    // This used to be refused. Once a device belongs to a named account rather
    // than to whoever photographed a QR code, "who started this process" has an
    // answer, and the fleet can be driven from a phone.
    expect(transport.supportsTaskControl).toBe(true);

    const pending = transport.startTask("/srv/api", "bound the retry backoff", 1);
    expect(readSent(socket(), socket().sent.length - 1)).toMatchObject({
      type: "start_task",
      repo_path: "/srv/api",
      prompt: "bound the retry backoff",
      budget_usd: 1,
      retry_of: null,
    });

    socket().deliver(
      fromRunner({ id: "t9", change_summary: "one file", status: "running" }),
    );
    await expect(pending).resolves.toMatchObject({ id: "t9" });
  });

  it("starts and stops a session over the relay", async () => {
    expect(transport.supportsSessionControl).toBe(true);

    const started = transport.startSession("/srv/api", "claude-code");
    expect(readSent(socket(), socket().sent.length - 1)).toMatchObject({
      type: "start_session",
      repo_path: "/srv/api",
      agent: "claude-code",
    });
    socket().deliver(
      fromRunner({ id: "s9", repo_name: "api", status: "running" }),
    );
    await expect(started).resolves.toMatchObject({ id: "s9" });

    const stopped = transport.stopSession("s9");
    expect(readSent(socket(), socket().sent.length - 1)).toMatchObject({
      type: "stop_session",
      session_id: "s9",
    });
    socket().deliver(fromRunner({ id: "s9", repo_name: "api", status: "done" }));
    await expect(stopped).resolves.toBeUndefined();
  });

  it("does not hand a session reply to a waiting session-detail request", async () => {
    // Both carry `repo_name` and `status`; only the detail has `steps`. Getting
    // this wrong resolves one promise with the other's payload, which is the
    // failure mode this whole shape-matching scheme has to avoid.
    const detail = transport.session("s1");
    socket().deliver(
      fromRunner({ id: "s1", repo_name: "api", status: "running" }),
    );

    let settled = false;
    void detail.then(() => (settled = true)).catch(() => (settled = true));
    await Promise.resolve();
    expect(settled).toBe(false);

    socket().deliver(
      fromRunner({ id: "s1", repo_name: "api", status: "running", steps: [] }),
    );
    await expect(detail).resolves.toMatchObject({ id: "s1" });
  });

  it("asks the runner which agents it can drive", async () => {
    const pending = transport.agents();
    expect(readSent(socket(), socket().sent.length - 1)).toMatchObject({
      type: "agent_list",
    });
    socket().deliver(fromRunner({ agents: [{ id: "claude-code" }] }));
    await expect(pending).resolves.toHaveLength(1);
  });

  it("fetches the task list over the relay", async () => {
    const pending = transport.tasks();
    socket().deliver(fromRunner({ tasks: [{ id: "t1" }, { id: "t2" }] }));
    await expect(pending).resolves.toHaveLength(2);
  });

  it("does not mistake another reply for a task list", async () => {
    // The reply is wrapped in `{ tasks }` rather than sent as a bare array for
    // exactly this reason: a bare array is the one shape that cannot be told
    // apart from any other bare array.
    const pending = transport.tasks();
    socket().deliver(fromRunner(fleetPayload));
    socket().deliver(fromRunner(taskPayload("t1")));
    socket().deliver(fromRunner({ tasks: [{ id: "t9" }] }));
    await expect(pending).resolves.toMatchObject([{ id: "t9" }]);
  });
});
