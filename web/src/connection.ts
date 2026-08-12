/**
 * How this browser ends up talking to a runner.
 *
 * Three ways in, and the app has to hold all three at once because they are
 * genuinely different deployments rather than steps of one flow:
 *
 * | Mode | What it is | Transport |
 * |---|---|---|
 * | `loopback` | The app served by the runner on your own machine | HTTP + `EventSource` |
 * | `cloud` | Signed in; the control plane says which machine and hands out a seat | relay WebSocket, sealed |
 * | `legacy` | A pairing from before accounts existed | relay WebSocket, sealed |
 *
 * `legacy` is not dead weight. Somebody with a working paired phone should not
 * have it stop working because a new sign-in flow shipped, and the migration is
 * "sign in when you feel like it" rather than a forced re-pair.
 *
 * # The seat is fetched on every connect
 *
 * A relay seat lives fifteen minutes. A phone reconnects for days. So the
 * transport is handed a *function* rather than a token, and calls it each time
 * it dials — which is also what makes removing a device take effect without
 * anything having to tell the relay.
 */

import { useCallback, useEffect, useRef, useState } from "react";
import {
  CloudClient,
  deviceIdentity,
  RelayTransport,
  type CloudSession,
  type ConnectionState,
  type Pairing,
  type ServerEvent,
  type Transport,
  type Workspace,
} from "@relayforge/client-core";
import { loopbackTransport, webPairingStore } from "./platform";
import { idbBackend } from "./idb";
import {
  CLOUD_URL,
  cloudClient,
  deviceKind,
  deviceName,
  webCloudSessionStore,
} from "./cloud";

export type Mode = "loading" | "welcome" | "loopback" | "cloud" | "legacy";

/** Which machine this browser is watching. Survives a reload. */
const ACTIVE_RUNNER_KEY = "forge-active-runner";
/** Set once the user has chosen loopback, so they are not asked again. */
const LOOPBACK_CHOICE_KEY = "forge-loopback-only";

export interface Connection {
  mode: Mode;
  transport: Transport | null;
  state: ConnectionState;
  /** Non-null in `cloud` mode. */
  cloud: CloudClient | null;
  workspace: Workspace | null;
  activeRunnerId: string | null;
  /** Set when the workspace could not be loaded — an expired session, usually. */
  error: string | null;
  /**
   * Set when this surface is signed in but holds no device seat. It can read
   * and manage the workspace; it cannot decrypt a machine's traffic until a
   * seat frees up.
   */
  deviceProblem: string | null;

  signIn: (input: {
    mode: "sign-in" | "sign-up";
    email: string;
    password: string;
    name: string;
  }) => Promise<void>;
  signOut: () => Promise<void>;
  chooseLoopback: () => void;
  /** Leave loopback-only and go back to the front door. */
  chooseCloud: () => void;
  pickRunner: (runnerId: string) => void;
  /**
   * Register this browser against a seat, using the key it already holds.
   *
   * The way back from `deviceProblem`: free a seat on the account screen, then
   * call this. Without it, removing a device leaves the session holding no
   * device id and nothing that would ever fill it in short of signing out.
   */
  claimDeviceSlot: () => Promise<void>;
  /** Re-read the workspace after a change made elsewhere on screen. */
  refresh: () => void;
}

export function useConnection(
  onEvent: (event: ServerEvent) => void,
): Connection {
  const [mode, setMode] = useState<Mode>("loading");
  const [state, setState] = useState<ConnectionState>("connecting");
  const [workspace, setWorkspace] = useState<Workspace | null>(null);
  const [activeRunnerId, setActiveRunnerId] = useState<string | null>(
    () => localStorage.getItem(ACTIVE_RUNNER_KEY),
  );
  const [error, setError] = useState<string | null>(null);
  /// Signed in, but this surface has no device seat — it can manage the
  /// workspace but cannot open an encrypted link to a machine.
  const [deviceProblem, setDeviceProblem] = useState<string | null>(null);
  const [revision, setRevision] = useState(0);

  const sessionRef = useRef<CloudSession | null>(null);
  const cloudRef = useRef<CloudClient | null>(null);
  const legacyRef = useRef<Pairing | null>(null);
  const transportRef = useRef<Transport | null>(null);
  const [transportRevision, setTransportRevision] = useState(0);

  // The listener is held in a ref so a re-render does not tear the transport
  // down — reconnecting on every keystroke in a text field is a real bug this
  // shape avoids.
  const onEventRef = useRef(onEvent);
  onEventRef.current = onEvent;

  const refresh = useCallback(() => setRevision((value) => value + 1), []);

  /* ------------------------------------------------------------ first read */

  useEffect(() => {
    let cancelled = false;

    void (async () => {
      const [session, pairing] = await Promise.all([
        webCloudSessionStore.load().catch(() => null),
        webPairingStore.load().catch(() => null),
      ]);
      if (cancelled) return;

      if (session) {
        sessionRef.current = session;
        cloudRef.current = cloudClient(session);
        // Checked on load and not only after signing in: a session saved by a
        // build that could not register a device is still on disk, and its
        // owner has no reason to sign out — so the screen has to say what is
        // wrong the next time the app opens, not the next time they log in.
        if (!session.deviceId) {
          setDeviceProblem("this browser holds no device slot.");
        }
        setMode("cloud");
        return;
      }
      if (pairing) {
        legacyRef.current = pairing;
        setMode("legacy");
        return;
      }
      setMode(
        localStorage.getItem(LOOPBACK_CHOICE_KEY) === "1" ? "loopback" : "welcome",
      );
    })();

    return () => {
      cancelled = true;
    };
  }, []);

  /* ------------------------------------------------------- the workspace */

  useEffect(() => {
    if (mode !== "cloud" || !cloudRef.current) return;
    let cancelled = false;

    cloudRef.current
      .workspace()
      .then((next) => {
        if (cancelled) return;
        setWorkspace(next);
        setError(null);

        // One machine is not a choice worth making anyone make.
        setActiveRunnerId((current) => {
          const stillThere = next.runners.some((runner) => runner.id === current);
          if (current && stillThere) return current;
          const only = next.runners.length === 1 ? next.runners[0]!.id : null;
          if (only) localStorage.setItem(ACTIVE_RUNNER_KEY, only);
          return only;
        });
      })
      .catch((cause: unknown) => {
        if (cancelled) return;
        const message = cause instanceof Error ? cause.message : String(cause);
        // A dead session is a sign-in problem, not an error banner over an
        // empty fleet. Drop it and show the front door.
        if (/sign in|expired/i.test(message)) {
          void webCloudSessionStore.clear();
          sessionRef.current = null;
          cloudRef.current = null;
          setWorkspace(null);
          setMode("welcome");
          return;
        }
        setError(message);
      });

    return () => {
      cancelled = true;
    };
  }, [mode, revision]);

  /* -------------------------------------------------------- the transport */

  useEffect(() => {
    if (mode === "loading" || mode === "welcome") return;

    let transport: Transport | null = null;

    if (mode === "loopback") {
      transport = loopbackTransport();
    } else if (mode === "legacy" && legacyRef.current) {
      transport = new RelayTransport(legacyRef.current);
    } else if (mode === "cloud") {
      const cloud = cloudRef.current;
      const session = sessionRef.current;
      const runner = workspace?.runners.find((item) => item.id === activeRunnerId);
      // No machine chosen yet, or none enrolled: there is nothing to dial, and
      // the screen shows the picker instead.
      // No device seat means no key the runner would seal to — the screen
      // says so rather than the transport retrying forever.
      if (!cloud || !session || !runner || !session.deviceId) return;

      const connection: Pairing = {
        relayUrl: workspace!.relay_url,
        channel: runner.channel,
        runnerPublicKey: runner.public_key,
        deviceId: session.deviceId,
        secret: session.deviceSecret,
      };

      transport = new RelayTransport(connection, async () => {
        const seat = await cloud.channelToken(runner.id, session.deviceId);
        return seat.token;
      });
    }

    if (!transport) return;
    transportRef.current = transport;
    setTransportRevision((value) => value + 1);

    const offState = transport.onConnectionChange(setState);
    const offEvent = transport.onEvent((event) => onEventRef.current(event));

    return () => {
      offState();
      offEvent();
      transport.close();
      transportRef.current = null;
    };
    // `workspace` is in the deps because the runner's channel and key come from
    // it; a key rotation approved elsewhere must rebuild the link.
  }, [mode, activeRunnerId, workspace]);

  /* ------------------------------------------------------------- actions */

  const signIn = useCallback<Connection["signIn"]>(async (input) => {
    // A fresh client with no stored token: signing in as somebody else must not
    // inherit the previous session's refresh token.
    let latestRefresh = "";
    const cloud = new CloudClient(CLOUD_URL, null, (token) => {
      latestRefresh = token;
    });

    const next =
      input.mode === "sign-up"
        ? await cloud.signUp({
            email: input.email,
            password: input.password,
            name: input.name,
            deviceLabel: deviceName(),
          })
        : await cloud.signIn({
            email: input.email,
            password: input.password,
            deviceLabel: deviceName(),
          });

    // This browser's long-term key, created once and reused. Only its public
    // half is ever sent — the control plane still cannot read anything.
    //
    // Reused rather than regenerated because a device seat belongs to the
    // device, not to the sign-in: generating a fresh key on every sign-in
    // consumed a new seat each time, and two sign-outs on a two-device plan was
    // enough to lock the account out of its own workspace.
    const identity = await deviceIdentity(idbBackend);

    // Registration failing must not fail the sign-in. Being over the device
    // limit is precisely when someone needs to get in — to remove a device they
    // no longer use — and refusing the whole sign-in makes that impossible from
    // every surface at once.
    let deviceId = "";
    let deviceProblem: string | null = null;
    try {
      deviceId = (
        await cloud.registerDevice({
          kind: deviceKind(),
          name: deviceName(),
          publicKey: identity.publicKey,
        })
      ).id;
    } catch (cause) {
      deviceProblem =
        cause instanceof Error ? cause.message : "this device could not be registered";
    }

    const session: CloudSession = {
      baseUrl: CLOUD_URL,
      refreshToken: latestRefresh,
      accountId: next.account.id,
      orgId: next.org.id,
      deviceId,
      deviceSecret: identity.toSecret(),
    };
    await webCloudSessionStore.save(session);

    sessionRef.current = session;
    // Re-created so its rotation callback writes to the session that now
    // exists; the one above only had a local variable to write to.
    cloudRef.current = cloudClient(session);
    localStorage.removeItem(LOOPBACK_CHOICE_KEY);
    setDeviceProblem(deviceProblem);
    setWorkspace(next);
    setActiveRunnerId(next.runners.length === 1 ? next.runners[0]!.id : null);
    setMode("cloud");
  }, []);

  const claimDeviceSlot = useCallback(async () => {
    const cloud = cloudRef.current;
    const session = sessionRef.current;
    if (!cloud || !session) return;

    // The same key as the failed attempt — this is a retry, not a new device.
    const identity = await deviceIdentity(idbBackend);
    const device = await cloud.registerDevice({
      kind: deviceKind(),
      name: deviceName(),
      publicKey: identity.publicKey,
    });

    const next = { ...session, deviceId: device.id, deviceSecret: identity.toSecret() };
    await webCloudSessionStore.save(next);
    sessionRef.current = next;
    setDeviceProblem(null);
    // The transport keys off `workspace`; re-reading it is what dials the link
    // that the missing seat had been suppressing.
    refresh();
  }, [refresh]);

  // Note this clears the *session* and not the device key: the key identifies
  // this browser to the seat it already holds, and destroying it on sign-out is
  // what made every sign-in cost a new seat.
  const signOut = useCallback(async () => {
    await cloudRef.current?.signOut();
    await webCloudSessionStore.clear();
    sessionRef.current = null;
    cloudRef.current = null;
    setWorkspace(null);
    setActiveRunnerId(null);
    localStorage.removeItem(ACTIVE_RUNNER_KEY);
    setMode("welcome");
  }, []);

  const chooseLoopback = useCallback(() => {
    localStorage.setItem(LOOPBACK_CHOICE_KEY, "1");
    setMode("loopback");
  }, []);

  const chooseCloud = useCallback(() => {
    localStorage.removeItem(LOOPBACK_CHOICE_KEY);
    setMode("welcome");
  }, []);

  const pickRunner = useCallback((runnerId: string) => {
    localStorage.setItem(ACTIVE_RUNNER_KEY, runnerId);
    setActiveRunnerId(runnerId);
  }, []);

  // `transportRevision` is never read for its value — bumping it is what makes
  // this hook re-render after the effect below swaps the transport, so that the
  // fresh `transportRef.current` is what a consumer sees. Named and referenced
  // here rather than left as a mystery `useState` nothing appears to use.
  void transportRevision;

  return {
    mode,
    transport: transportRef.current,
    state,
    cloud: cloudRef.current,
    workspace,
    activeRunnerId,
    error,
    deviceProblem,
    claimDeviceSlot,
    signIn,
    signOut,
    chooseLoopback,
    chooseCloud,
    pickRunner,
    refresh,
  };
}

/** Whether this page is being served by a runner, and so has a loopback API. */
export function loopbackAvailable(): boolean {
  // The runner serves the app from its own origin on port 7842. A page loaded
  // from the tunnel is not on a runner and should not offer the option.
  return location.port === "7842" || location.hostname === "localhost" || location.hostname === "127.0.0.1";
}
