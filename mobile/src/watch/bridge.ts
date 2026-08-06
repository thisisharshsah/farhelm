/**
 * Getting the watch its own identity.
 *
 * ## Why the watch is a device, not a remote control
 *
 * The obvious design is for the watch to send taps to the phone and let the
 * phone act on them. That would be wrong here, for one specific reason: the
 * runner records `decided_via` on every approval, and the D3 rule — destructive
 * commands cannot be cleared from a wrist — is enforced against the *registered
 * kind of the device that sent the envelope*. A watch proxying through a phone
 * would arrive as `phone`, and the whole rule would quietly evaporate. It would
 * also make the audit trail a lie.
 *
 * So the watch is a first-class paired device: its own keypair, its own row in
 * the runner's `device` table with `kind = 'watch'`, its own WebSocket to the
 * relay. The runner refuses its destructive approvals server-side, and the watch
 * app shows why rather than pretending the tap did nothing.
 *
 * ## What the phone is for, then
 *
 * Exactly one thing: pairing. Claiming a code needs an HTTP request to the
 * runner on its own network, and a watch is often not on that network — it is on
 * the phone. So the flow is:
 *
 * 1. The watch generates a keypair and sends the **public half** over.
 * 2. The phone mints a pairing offer and claims it as `kind: "watch"` with that
 *    public key.
 * 3. The phone sends back the relay coordinates and the assigned device id.
 *
 * The watch's secret never leaves the watch — not over WatchConnectivity, not
 * through the phone's memory. The phone is a courier for public data.
 *
 * ## Availability
 *
 * `react-native-watch-connectivity` is iOS-only and a no-op in a simulator with
 * no paired watch. Everything here degrades to "no watch" rather than throwing,
 * because that is the common case: most users do not have one.
 */

import {
  claimPairing,
  type PairingOffer,
  type RunnerApi,
} from "@relayforge/client-core";

/** What the watch sends when it wants in. */
export interface WatchPairRequest {
  kind: "pair-request";
  /** base64url X25519 public key, generated on the watch. */
  public_key: string;
}

/** What the phone sends back. No secret in it — the watch already has its own. */
export interface WatchPairResponse {
  kind: "pair-response";
  relay_url: string;
  channel: string;
  runner_public_key: string;
  device_id: string;
}

/** What the phone sends when pairing failed, so the wrist can say why. */
export interface WatchPairFailure {
  kind: "pair-failed";
  message: string;
}

export type WatchMessage =
  | WatchPairRequest
  | WatchPairResponse
  | WatchPairFailure;

/**
 * The slice of `react-native-watch-connectivity` this module uses.
 *
 * Declared rather than imported so the logic below can be tested without a
 * simulator, and so the module is optional at runtime — an Android build never
 * loads it.
 */
export interface WatchSession {
  sendMessage(message: object): void;
  subscribeToMessages(
    listener: (message: Record<string, unknown>) => void,
  ): () => void;
  getReachability(): Promise<boolean>;
}

/**
 * Load the native watch session, or `null` where there isn't one.
 *
 * Android and the simulator both land on `null`, as does a phone with no watch
 * paired. Callers treat that as "no watch tab", not as an error.
 */
export async function loadWatchSession(): Promise<WatchSession | null> {
  try {
    const native = (await import("react-native-watch-connectivity")) as {
      sendMessage: (message: object) => void;
      watchEvents: {
        addListener: (
          event: "message",
          listener: (message: Record<string, unknown>) => void,
        ) => () => void;
      };
      getReachability: () => Promise<boolean>;
    };

    return {
      sendMessage: (message) => native.sendMessage(message),
      subscribeToMessages: (listener) =>
        native.watchEvents.addListener("message", listener),
      getReachability: () => native.getReachability(),
    };
  } catch {
    return null;
  }
}

/**
 * Answer a watch's pairing request.
 *
 * `runnerApi` must be pointed at a runner this phone can currently reach — the
 * claim is plain HTTP on the local network, the same hop the phone's own pairing
 * uses. Failures come back to the watch as a message rather than a silence.
 */
export async function handlePairRequest(
  session: WatchSession,
  runnerApi: RunnerApi,
  request: WatchPairRequest,
): Promise<WatchPairResponse | WatchPairFailure> {
  let reply: WatchPairResponse | WatchPairFailure;
  try {
    const offer: PairingOffer = await runnerApi.pairingOffer();
    const pairing = await claimPairing(
      runnerApi.baseUrl,
      offer,
      "watch",
      request.public_key,
    );
    reply = {
      kind: "pair-response",
      relay_url: pairing.relayUrl,
      channel: pairing.channel,
      runner_public_key: pairing.runnerPublicKey,
      device_id: pairing.deviceId,
    };
  } catch (cause) {
    reply = {
      kind: "pair-failed",
      message: cause instanceof Error ? cause.message : String(cause),
    };
  }

  session.sendMessage(reply);
  return reply;
}

/**
 * Listen for pairing requests from the wrist for as long as the app is up.
 *
 * Returns a teardown. Messages that are not pairing requests are ignored — the
 * watch talks to the relay directly for everything else, so there is nothing
 * else for the phone to forward.
 */
export function servePairing(
  session: WatchSession,
  runnerApi: () => RunnerApi | null,
  onResult?: (result: WatchPairResponse | WatchPairFailure) => void,
): () => void {
  return session.subscribeToMessages((message) => {
    if (message["kind"] !== "pair-request") return;
    const publicKey = message["public_key"];
    if (typeof publicKey !== "string") return;

    const api = runnerApi();
    if (!api) {
      const failure: WatchPairFailure = {
        kind: "pair-failed",
        message:
          "set the runner address on the phone first — pairing the watch needs to reach it directly",
      };
      session.sendMessage(failure);
      onResult?.(failure);
      return;
    }

    void handlePairRequest(session, api, {
      kind: "pair-request",
      public_key: publicKey,
    }).then((result) => onResult?.(result));
  });
}
