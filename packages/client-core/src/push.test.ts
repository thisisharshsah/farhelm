/**
 * Registering for wake-ups.
 *
 * The property worth asserting is the negative one: nothing about *what*
 * happened may reach the relay, because the relay is the one party that must
 * not learn it.
 */

import { describe, expect, it, vi, afterEach } from "vitest";
import { ApiError, Identity, type Pairing } from "./index.ts";
import {
  applicationServerKey,
  httpFrom,
  registerPush,
  vapidPublicKey,
} from "./push.ts";

const pairing = (relayUrl: string): Pairing => ({
  relayUrl,
  channel: "forge-abc",
  runnerPublicKey: Identity.generate().publicKey,
  deviceId: "dev-1",
  secret: Identity.generate().toSecret(),
});

afterEach(() => vi.unstubAllGlobals());

describe("reaching the relay", () => {
  it("turns a websocket URL into an http one", () => {
    expect(httpFrom("wss://relay.example")).toBe("https://relay.example");
    expect(httpFrom("ws://127.0.0.1:7843/")).toBe("http://127.0.0.1:7843");
  });
});

describe("the relay's push key", () => {
  it("is fetched from the relay, not the runner", async () => {
    const fetchMock = vi.fn(
      async (_url: string) => new Response(JSON.stringify({ publicKey: "abc" })),
    );
    vi.stubGlobal("fetch", fetchMock);

    expect(await vapidPublicKey("wss://relay.example")).toBe("abc");
    expect(fetchMock.mock.calls[0]![0]).toBe(
      "https://relay.example/v1/push/vapid",
    );
  });

  it("reports a relay without push as absent, not broken", async () => {
    // Running a relay without a VAPID key is supported; the UI says so rather
    // than showing an error.
    vi.stubGlobal("fetch", async () => new Response("{}", { status: 503 }));
    expect(await vapidPublicKey("wss://relay.example")).toBeNull();
  });

  it("does not treat a real failure as absent", async () => {
    vi.stubGlobal("fetch", async () => new Response("{}", { status: 500 }));
    await expect(vapidPublicKey("wss://relay.example")).rejects.toThrow(ApiError);
  });

  it("rejects a relay that answers without a key", async () => {
    vi.stubGlobal("fetch", async () => new Response("{}", { status: 200 }));
    await expect(vapidPublicKey("wss://relay.example")).rejects.toThrow(ApiError);
  });
});

describe("registering a subscription", () => {
  const subscription = {
    endpoint: "https://push.example/device-1",
    p256dh: "p256dh-value",
    auth: "auth-value",
  };

  it("posts to the pairing's channel", async () => {
    const fetchMock = vi.fn(
      async (_url: string, _init?: RequestInit) =>
        new Response("{}", { status: 200 }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await registerPush(pairing("wss://relay.example"), subscription);
    expect(fetchMock.mock.calls[0]![0]).toBe(
      "https://relay.example/v1/push/forge-abc/subscribe",
    );
  });

  it("sends the endpoint and keys and nothing else", async () => {
    // The relay must not learn the device id, the runner's key, or anything
    // about what the channel is for. It gets what a push service needs.
    const fetchMock = vi.fn(
      async (_url: string, _init?: RequestInit) =>
        new Response("{}", { status: 200 }),
    );
    vi.stubGlobal("fetch", fetchMock);

    const paired = pairing("wss://relay.example");
    await registerPush(paired, subscription);

    const body = JSON.parse(
      String(fetchMock.mock.calls[0]![1]?.body),
    ) as Record<string, unknown>;
    expect(Object.keys(body).sort()).toEqual(["auth", "endpoint", "p256dh"]);
    expect(JSON.stringify(body)).not.toContain(paired.deviceId);
    expect(JSON.stringify(body)).not.toContain(paired.secret);
    expect(JSON.stringify(body)).not.toContain(paired.runnerPublicKey);
  });

  it("escapes a channel that would otherwise change the path", async () => {
    const fetchMock = vi.fn(
      async (_url: string, _init?: RequestInit) =>
        new Response("{}", { status: 200 }),
    );
    vi.stubGlobal("fetch", fetchMock);

    await registerPush(
      { ...pairing("wss://relay.example"), channel: "a/../b" },
      subscription,
    );
    expect(fetchMock.mock.calls[0]![0]).toContain("a%2F..%2Fb");
  });

  it("surfaces a refusal", async () => {
    vi.stubGlobal("fetch", async () => new Response("{}", { status: 400 }));
    await expect(
      registerPush(pairing("wss://relay.example"), subscription),
    ).rejects.toThrow(ApiError);
  });
});

describe("the application server key", () => {
  it("is bytes, not the string the relay serves", () => {
    // `pushManager.subscribe` takes a BufferSource. Handing it the base64url
    // string produces an InvalidCharacterError from deep inside the Push API.
    const key = applicationServerKey("BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8");
    expect(key).toBeInstanceOf(ArrayBuffer);
    expect(key.byteLength).toBe(65);
    expect(new Uint8Array(key)[0]).toBe(0x04);
  });
});
