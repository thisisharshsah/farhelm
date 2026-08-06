/**
 * The browser's push state machine.
 *
 * Almost all of the value here is in one case. On iOS, Safari resolves
 * `Notification.requestPermission()` to `"denied"` in a browser tab **without
 * ever prompting** — no dialog, no error, nothing in the console. A user who
 * hits that concludes the feature is broken. So "you have to install it to the
 * Home Screen first" has to be detected and said before the attempt, and these
 * tests pin that down.
 */

import { afterEach, describe, expect, it, vi } from "vitest";
import type { Pairing } from "@relayforge/client-core";
import { disablePush, enablePush, isInstalled, pushState } from "./push";

const IOS_UA =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1";
const DESKTOP_UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36";

const pairing: Pairing = {
  relayUrl: "wss://relay.example",
  channel: "forge-abc",
  runnerPublicKey: "k",
  deviceId: "dev-1",
  secret: "s",
};

/** Set up the browser globals `push.ts` reads. */
function browser(options: {
  userAgent?: string;
  standalone?: boolean;
  permission?: NotificationPermission;
  hasPushManager?: boolean;
  subscription?: unknown;
  requestPermission?: () => Promise<NotificationPermission>;
  subscribe?: () => Promise<unknown>;
}) {
  const {
    userAgent = DESKTOP_UA,
    standalone = false,
    permission = "default",
    hasPushManager = true,
    subscription = null,
  } = options;

  vi.stubGlobal("navigator", {
    userAgent,
    platform: userAgent === IOS_UA ? "iPhone" : "MacIntel",
    maxTouchPoints: 0,
    ...(standalone ? { standalone: true } : {}),
    serviceWorker: {
      ready: Promise.resolve({
        pushManager: {
          getSubscription: async () => subscription,
          subscribe: options.subscribe ?? (async () => subscription),
        },
      }),
    },
  });

  vi.stubGlobal("matchMedia", (query: string) => ({
    matches: standalone && query.includes("standalone"),
  }));

  if (hasPushManager) {
    vi.stubGlobal("PushManager", class {});
  } else {
    vi.stubGlobal("PushManager", undefined);
  }

  vi.stubGlobal("Notification", {
    permission,
    requestPermission:
      options.requestPermission ?? (async () => permission),
  });

  // `push.ts` checks `"PushManager" in window`.
  vi.stubGlobal(
    "window",
    hasPushManager ? { PushManager: class {} } : {},
  );
}

/** A subscription shaped like the one a browser hands back. */
const fakeSubscription = (endpoint = "https://push.example/x") => ({
  endpoint,
  toJSON: () => ({
    endpoint,
    keys: { p256dh: "p256dh-value", auth: "auth-value" },
  }),
  unsubscribe: async () => true,
});

afterEach(() => vi.unstubAllGlobals());

describe("detecting a home-screen install", () => {
  it("recognises standalone display mode", () => {
    browser({ standalone: true });
    expect(isInstalled()).toBe(true);
  });

  it("knows a browser tab is not an install", () => {
    browser({});
    expect(isInstalled()).toBe(false);
  });
});

describe("the state before anything is attempted", () => {
  it("tells an iOS user to install before it asks for anything", async () => {
    // The whole point. Asking here would be denied silently and the user would
    // conclude the feature is broken.
    browser({ userAgent: IOS_UA });
    expect(await pushState()).toEqual({ status: "needs-install" });
  });

  it("is happy on iOS once installed", async () => {
    browser({ userAgent: IOS_UA, standalone: true });
    expect(await pushState()).toEqual({ status: "off" });
  });

  it("does not demand an install on desktop", async () => {
    browser({});
    expect(await pushState()).toEqual({ status: "off" });
  });

  it("reports a browser with no Push API as unsupported", async () => {
    browser({ hasPushManager: false });
    expect((await pushState()).status).toBe("unsupported");
  });

  it("still says needs-install for an old iOS with no Push API", async () => {
    // iOS below 16.4 has no PushManager at all. "Install it" is more useful
    // than "unsupported", and is what actually fixes it on 16.4+.
    browser({ userAgent: IOS_UA, hasPushManager: false });
    expect(await pushState()).toEqual({ status: "needs-install" });
  });

  it("reports a blocked site as denied", async () => {
    browser({ permission: "denied" });
    expect(await pushState()).toEqual({ status: "denied" });
  });

  it("reports an existing subscription as on", async () => {
    browser({ permission: "granted", subscription: fakeSubscription() });
    expect(await pushState()).toEqual({ status: "on" });
  });
});

describe("turning it on", () => {
  it("refuses to try on an uninstalled iOS", async () => {
    browser({ userAgent: IOS_UA });
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    expect(await enablePush(pairing)).toEqual({ status: "needs-install" });
    // And it did not bother the relay on the way to finding that out.
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("says so when the relay has no push key", async () => {
    browser({ permission: "granted" });
    vi.stubGlobal("fetch", async () => new Response("{}", { status: 503 }));

    const state = await enablePush(pairing);
    expect(state.status).toBe("unsupported");
    expect(state.status === "unsupported" && state.reason).toMatch(/--vapid-key/);
  });

  it("subscribes and registers when everything lines up", async () => {
    const subscription = fakeSubscription();
    browser({
      permission: "granted",
      subscribe: async () => subscription,
    });

    const calls: string[] = [];
    vi.stubGlobal("fetch", async (url: string) => {
      calls.push(url);
      return url.endsWith("/vapid")
        ? new Response(
            JSON.stringify({
              publicKey:
                "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8",
            }),
          )
        : new Response("{}", { status: 200 });
    });

    expect(await enablePush(pairing)).toEqual({ status: "on" });
    expect(calls).toEqual([
      "https://relay.example/v1/push/vapid",
      "https://relay.example/v1/push/forge-abc/subscribe",
    ]);
  });

  it("treats a refused prompt as a choice, not an error", async () => {
    browser({
      permission: "default",
      requestPermission: async () => "denied" as NotificationPermission,
    });
    vi.stubGlobal(
      "fetch",
      async () =>
        new Response(
          JSON.stringify({
            publicKey:
              "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8",
          }),
        ),
    );

    expect(await enablePush(pairing)).toEqual({ status: "denied" });
  });
});

describe("turning it off", () => {
  it("unsubscribes locally", async () => {
    let unsubscribed = false;
    const subscription = {
      ...fakeSubscription(),
      unsubscribe: async () => {
        unsubscribed = true;
        return true;
      },
    };
    browser({ permission: "granted", subscription });

    expect(await disablePush()).toEqual({ status: "off" });
    expect(unsubscribed).toBe(true);
  });

  it("is harmless when there was nothing to unsubscribe", async () => {
    browser({ permission: "granted" });
    expect(await disablePush()).toEqual({ status: "off" });
  });
});
