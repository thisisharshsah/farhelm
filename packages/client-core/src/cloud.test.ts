/**
 * The control-plane client, against a stubbed `fetch`.
 *
 * The behaviour worth pinning down here is not "does it call the right URL" —
 * it is the token lifecycle, because that is where a client silently signs
 * somebody out or, worse, keeps using a credential it should have rotated.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  CloudClient,
  CloudError,
  CLOUD_SESSION_STORAGE_KEY,
  cloudSessionStore,
  DEVICE_KEY_STORAGE_KEY,
  deviceIdentity,
  describeLimit,
  formatPrice,
  isAtLimit,
  subscriptionNotice,
  UNLIMITED,
  type Subscription,
} from "./cloud.ts";
import { Identity } from "./crypto.ts";

type Handler = (url: string, init: RequestInit) => Response | Promise<Response>;

let handler: Handler;
const calls: Array<{ url: string; init: RequestInit }> = [];

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

beforeEach(() => {
  calls.length = 0;
  vi.stubGlobal("fetch", (url: string, init: RequestInit = {}) => {
    calls.push({ url, init });
    return handler(url, init);
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
});

function authBody(overrides: Record<string, unknown> = {}) {
  return {
    access_token: "access-1",
    access_expires_at: Date.now() + 3_600_000,
    refresh_token: "refresh-1",
    workspace: { org: { id: "org_1" } },
    ...overrides,
  };
}

describe("signing in", () => {
  it("keeps the tokens and reports the workspace", async () => {
    handler = () => json(authBody());
    const rotated: string[] = [];
    const client = new CloudClient("https://farhelm.aurovie.com", null, (token) =>
      rotated.push(token),
    );

    const workspace = await client.signIn({
      email: "harsh@example.com",
      password: "correct horse battery",
    });

    expect(workspace.org.id).toBe("org_1");
    expect(client.isSignedIn).toBe(true);
    // The refresh token is handed straight to the persistence callback, which
    // is the only place it is written down.
    expect(rotated).toEqual(["refresh-1"]);
  });

  it("sends the access token on subsequent calls and never the refresh token", async () => {
    handler = (url) => (url.endsWith("/v1/auth/login") ? json(authBody()) : json([]));
    const client = new CloudClient("https://farhelm.aurovie.com");
    await client.signIn({ email: "a@b.co", password: "correct horse battery" });
    await client.runners();

    const runnersCall = calls.at(-1)!;
    const headers = runnersCall.init.headers as Record<string, string>;
    expect(headers.authorization).toBe("Bearer access-1");
    expect(JSON.stringify(runnersCall)).not.toContain("refresh-1");
  });

  it("surfaces the server's wording rather than a status code", async () => {
    handler = () => json({ error: "that email and password do not match" }, 401);
    const client = new CloudClient("https://farhelm.aurovie.com");

    await expect(
      client.signIn({ email: "a@b.co", password: "wrong" }),
    ).rejects.toThrow("that email and password do not match");
  });

  it("carries the upgrade a plan limit suggests", async () => {
    // So the screen can offer the upgrade instead of rendering a dead end.
    handler = (url) =>
      url.endsWith("/v1/auth/login")
        ? json(authBody())
        : json({ error: "the Free plan allows 2 devices", upgrade_to: "pro" }, 402);

    const client = new CloudClient("https://farhelm.aurovie.com");
    await client.signIn({ email: "a@b.co", password: "correct horse battery" });

    const failure = await client
      .registerDevice({ kind: "phone", name: "iPhone", publicKey: "k" })
      .catch((error: unknown) => error as CloudError);

    expect(failure).toBeInstanceOf(CloudError);
    expect((failure as CloudError).upgradeTo).toBe("pro");
    expect((failure as CloudError).status).toBe(402);
  });
});

describe("token refresh", () => {
  it("refreshes an expired access token and retries the call once", async () => {
    let refreshed = 0;
    handler = (url) => {
      if (url.endsWith("/v1/auth/refresh")) {
        refreshed += 1;
        return json({
          access_token: "access-2",
          access_expires_at: Date.now() + 3_600_000,
          refresh_token: "refresh-2",
        });
      }
      return json([]);
    };

    const rotated: string[] = [];
    const client = new CloudClient("https://x", "refresh-1", (token) =>
      rotated.push(token),
    );
    await client.runners();

    expect(refreshed).toBe(1);
    // Rotation is the point: the old refresh token is now dead server-side, so
    // the client must have stored the new one.
    expect(rotated).toEqual(["refresh-2"]);
  });

  it("collapses concurrent refreshes into one", async () => {
    // Two refreshes in flight means one of them rotates a token the other is
    // about to present — and the loser gets signed out for no reason.
    let refreshed = 0;
    handler = async (url) => {
      if (url.endsWith("/v1/auth/refresh")) {
        refreshed += 1;
        await new Promise((resolve) => setTimeout(resolve, 5));
        return json({
          access_token: "access-2",
          access_expires_at: Date.now() + 3_600_000,
          refresh_token: `refresh-${refreshed + 1}`,
        });
      }
      return json([]);
    };

    const client = new CloudClient("https://x", "refresh-1");
    await Promise.all([client.runners(), client.devices(), client.members()]);

    expect(refreshed).toBe(1);
  });

  it("retries at most once, so a genuine 401 does not loop", async () => {
    let attempts = 0;
    handler = (url) => {
      if (url.endsWith("/v1/auth/refresh")) {
        return json({
          access_token: "access-2",
          access_expires_at: Date.now() + 3_600_000,
          refresh_token: "refresh-2",
        });
      }
      attempts += 1;
      return json({ error: "nope" }, 401);
    };

    const client = new CloudClient("https://x", "refresh-1");
    await expect(client.runners()).rejects.toThrow("nope");
    expect(attempts).toBe(2);
  });

  it("signs out locally when the refresh token is rejected", async () => {
    handler = () => json({ error: "that session has expired" }, 401);
    const client = new CloudClient("https://x", "refresh-stale");

    await expect(client.runners()).rejects.toThrow("that session has expired");
    expect(client.isSignedIn).toBe(false);
  });

  it("refuses to call an authenticated endpoint with no session at all", async () => {
    handler = () => json({});
    const client = new CloudClient("https://x");
    await expect(client.workspace()).rejects.toThrow("sign in");
    expect(calls).toHaveLength(0);
  });
});

describe("signing out", () => {
  it("revokes the refresh token server-side", async () => {
    handler = () => json({});
    const client = new CloudClient("https://x", "refresh-1");
    await client.signOut();

    expect(calls.at(-1)!.url).toContain("/v1/auth/logout");
    expect(client.isSignedIn).toBe(false);
  });

  it("still signs out locally when the network is gone", async () => {
    // The user pressed Sign out. Whatever the server thinks, this device is
    // done — the token expires on its own.
    handler = () => Promise.reject(new Error("offline"));
    const client = new CloudClient("https://x", "refresh-1");

    await expect(client.signOut()).resolves.toBeUndefined();
    expect(client.isSignedIn).toBe(false);
  });
});

describe("the session store", () => {
  function backend(initial: string | null = null) {
    let value = initial;
    return {
      get: async () => value,
      set: async (_key: string, next: string) => {
        value = next;
      },
      remove: async () => {
        value = null;
      },
      peek: () => value,
    };
  }

  it("round-trips a session", async () => {
    const memory = backend();
    const store = cloudSessionStore(memory);
    const session = {
      baseUrl: "https://farhelm.aurovie.com",
      refreshToken: "refresh-1",
      accountId: "acc_1",
      orgId: "org_1",
      deviceId: "dev_1",
      deviceSecret: Identity.generate().toSecret(),
    };

    await store.save(session);
    expect(await store.load()).toEqual(session);
  });

  it("drops a session whose device key is unusable", async () => {
    // A session that looks signed in and cannot decrypt anything is worse than
    // no session: it fails at the first approval, which is the worst moment.
    const memory = backend(
      JSON.stringify({
        baseUrl: "https://x",
        refreshToken: "refresh-1",
        accountId: "acc_1",
        orgId: "org_1",
        deviceId: "dev_1",
        deviceSecret: "not-a-key",
      }),
    );
    const store = cloudSessionStore(memory);

    expect(await store.load()).toBeNull();
    expect(memory.peek()).toBeNull();
  });

  it("drops a session with no refresh token", async () => {
    const memory = backend(
      JSON.stringify({
        baseUrl: "https://x",
        refreshToken: "",
        deviceSecret: Identity.generate().toSecret(),
      }),
    );
    expect(await cloudSessionStore(memory).load()).toBeNull();
  });

  it("treats unreadable storage as signed out", async () => {
    const memory = { ...backend("not json"), peek: () => null };
    expect(await cloudSessionStore(memory).load()).toBeNull();
  });
});

describe("presentation helpers", () => {
  it("spells the unlimited sentinel the way a person would", () => {
    expect(describeLimit(UNLIMITED)).toBe("Unlimited");
    expect(describeLimit(5)).toBe("5");
  });

  it("knows when an allowance has run out", () => {
    expect(isAtLimit(1, 1)).toBe(true);
    expect(isAtLimit(0, 1)).toBe(false);
    expect(isAtLimit(10_000, UNLIMITED)).toBe(false);
  });

  it("formats prices without trailing zeros on whole dollars", () => {
    expect(formatPrice(0)).toBe("Free");
    expect(formatPrice(900)).toBe("$9");
    expect(formatPrice(2900)).toBe("$29");
    expect(formatPrice(1250)).toBe("$12.50");
  });

  it("says nothing when a subscription is simply fine", () => {
    // A banner that is always there is a banner nobody reads.
    const subscription: Subscription = {
      org_id: "org_1",
      plan: "pro",
      status: "active",
      customer_id: "cus_1",
      subscription_id: "sub_1",
      current_period_end: Date.now() + 1_000_000,
      cancel_at_period_end: false,
      updated_at: 0,
    };
    expect(subscriptionNotice(subscription)).toBeNull();
  });

  it("reassures rather than threatens when a payment fails", () => {
    const subscription: Subscription = {
      org_id: "org_1",
      plan: "pro",
      status: "past_due",
      customer_id: "cus_1",
      subscription_id: "sub_1",
      current_period_end: null,
      cancel_at_period_end: false,
      updated_at: 0,
    };
    const notice = subscriptionNotice(subscription)!;
    expect(notice).toContain("keeps working");
  });

  it("names the date a cancelled plan runs out", () => {
    const end = Date.now() + 5 * 86_400_000;
    const subscription: Subscription = {
      org_id: "org_1",
      plan: "team",
      status: "active",
      customer_id: "cus_1",
      subscription_id: "sub_1",
      current_period_end: end,
      cancel_at_period_end: true,
      updated_at: 0,
    };
    expect(subscriptionNotice(subscription)).toContain(
      new Date(end).toLocaleDateString(),
    );
  });
});

/**
 * A device seat belongs to the device, not to the sign-in.
 *
 * These pin down the shape of a real lockout: `signIn` used to mint a fresh
 * keypair every time, so a seat was consumed per sign-in. On a two-seat plan,
 * signing out and back in twice exhausted the plan, the third registration was
 * refused, and — because registration was part of sign-in — the refusal locked
 * the account out of the one screen that could have freed a seat.
 */
describe("this device's key", () => {
  function memoryBackend(seed: Record<string, string> = {}) {
    const cells = new Map(Object.entries(seed));
    return {
      cells,
      get: (key: string) => Promise.resolve(cells.get(key) ?? null),
      set: (key: string, value: string) => {
        cells.set(key, value);
        return Promise.resolve();
      },
    };
  }

  it("is the same key on the next sign-in", async () => {
    const backend = memoryBackend();
    const first = await deviceIdentity(backend);
    const second = await deviceIdentity(backend);

    // Identical public half → the control plane recognises the seat it already
    // issued, and does not count a second one.
    expect(second.publicKey).toBe(first.publicKey);
    expect(second.toSecret()).toBe(first.toSecret());
  });

  it("is stored apart from the session, so signing out does not destroy it", async () => {
    const backend = memoryBackend();
    const before = await deviceIdentity(backend);

    // What signing out clears.
    backend.cells.delete(CLOUD_SESSION_STORAGE_KEY);

    expect((await deviceIdentity(backend)).publicKey).toBe(before.publicKey);
    expect(backend.cells.has(DEVICE_KEY_STORAGE_KEY)).toBe(true);
  });

  it("replaces a corrupt key rather than refusing to sign in", async () => {
    const backend = memoryBackend({ [DEVICE_KEY_STORAGE_KEY]: "not-a-key" });
    // Throwing here would strand the browser: nothing on screen can repair a
    // value the user cannot see. Costing a seat is the lesser failure.
    await expect(deviceIdentity(backend)).resolves.toBeDefined();
  });
});
