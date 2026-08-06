/**
 * The phone's side of watch pairing, without a watch.
 *
 * What matters here is a security property, not a feature: the phone is a
 * courier for the watch's *public* key and must never be in a position to know
 * or invent the secret half. These tests assert that the only key material
 * crossing the bridge is public, and that the device is claimed as `watch` — if
 * it were ever claimed as `phone`, the D3 destructive-command rule would silently
 * stop applying to the wrist.
 */

import { describe, expect, it, vi } from "vitest";
import { Identity, createRunnerApi } from "@relayforge/client-core";
import { handlePairRequest, servePairing, type WatchSession } from "./bridge.ts";

/** A watch session that records what the phone sent it. */
function fakeSession() {
  const sent: object[] = [];
  let listener: ((message: Record<string, unknown>) => void) | null = null;
  const session: WatchSession = {
    sendMessage: (message) => sent.push(message),
    subscribeToMessages: (next) => {
      listener = next;
      return () => {
        listener = null;
      };
    },
    getReachability: async () => true,
  };
  return {
    session,
    sent,
    deliver: (message: Record<string, unknown>) => listener?.(message),
    get listening() {
      return listener !== null;
    },
  };
}

const RUNNER = "http://runner.test";

/** A runner that answers the two calls pairing makes. */
function fakeRunner(options: { claimStatus?: number; error?: string } = {}) {
  const claims: Array<Record<string, unknown>> = [];
  const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
    if (url.endsWith("/v1/pair/offer")) {
      return new Response(
        JSON.stringify({
          relay_url: "wss://relay.test",
          channel: "forge-abc",
          runner_public_key: Identity.generate().publicKey,
          code: "one-time",
          expires_at: Date.now() + 60_000,
        }),
        { status: 200 },
      );
    }
    if (url.endsWith("/v1/pair/claim")) {
      claims.push(JSON.parse(String(init?.body)) as Record<string, unknown>);
      if (options.claimStatus && options.claimStatus !== 200) {
        return new Response(JSON.stringify({ error: options.error }), {
          status: options.claimStatus,
        });
      }
      return new Response(JSON.stringify({ id: "watch-device-1" }), {
        status: 200,
      });
    }
    throw new Error(`unexpected fetch: ${url}`);
  });
  vi.stubGlobal("fetch", fetchMock);
  return { claims };
}

describe("claiming a code for the watch", () => {
  it("registers it as a watch, not a phone", async () => {
    const { claims } = fakeRunner();
    const { session } = fakeSession();
    const watchKey = Identity.generate().publicKey;

    await handlePairRequest(session, createRunnerApi(RUNNER), {
      kind: "pair-request",
      public_key: watchKey,
    });

    // If this ever said "phone", the runner would let the wrist approve
    // destructive commands and the audit trail would be wrong too.
    expect(claims[0]).toMatchObject({ kind: "watch", public_key: watchKey });
    vi.unstubAllGlobals();
  });

  it("sends back only public information", async () => {
    fakeRunner();
    const { session, sent } = fakeSession();

    await handlePairRequest(session, createRunnerApi(RUNNER), {
      kind: "pair-request",
      public_key: Identity.generate().publicKey,
    });

    const reply = sent[0] as Record<string, unknown>;
    expect(reply["kind"]).toBe("pair-response");
    expect(reply["device_id"]).toBe("watch-device-1");
    // The phone never held the watch's secret and cannot have leaked it.
    expect(Object.keys(reply)).not.toContain("secret");
    expect(JSON.stringify(reply)).not.toContain("secret");
    vi.unstubAllGlobals();
  });

  it("tells the wrist why it failed instead of going quiet", async () => {
    fakeRunner({ claimStatus: 403, error: "pairing code already used" });
    const { session, sent } = fakeSession();

    const result = await handlePairRequest(session, createRunnerApi(RUNNER), {
      kind: "pair-request",
      public_key: Identity.generate().publicKey,
    });

    expect(result).toMatchObject({
      kind: "pair-failed",
      message: "pairing code already used",
    });
    expect(sent[0]).toMatchObject({ kind: "pair-failed" });
    vi.unstubAllGlobals();
  });
});

describe("serving requests from the wrist", () => {
  it("ignores messages that are not pairing requests", () => {
    fakeRunner();
    const fake = fakeSession();
    servePairing(fake.session, () => createRunnerApi(RUNNER));

    fake.deliver({ kind: "something-else" });
    fake.deliver({ kind: "pair-request" }); // no key
    fake.deliver({ kind: "pair-request", public_key: 42 }); // not a string

    expect(fake.sent).toHaveLength(0);
    vi.unstubAllGlobals();
  });

  it("says so when the runner address is not set", () => {
    const fake = fakeSession();
    servePairing(fake.session, () => null);

    fake.deliver({
      kind: "pair-request",
      public_key: Identity.generate().publicKey,
    });

    expect(fake.sent[0]).toMatchObject({ kind: "pair-failed" });
    expect(String((fake.sent[0] as { message: string }).message)).toMatch(
      /runner address/,
    );
  });

  it("stops listening when torn down", () => {
    const fake = fakeSession();
    const stop = servePairing(fake.session, () => null);
    expect(fake.listening).toBe(true);
    stop();
    expect(fake.listening).toBe(false);
  });
});
