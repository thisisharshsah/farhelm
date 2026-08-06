/**
 * One-shot relay calls, for contexts that are not a running app.
 *
 * A service worker handling a push is awake for seconds, not minutes. It cannot
 * use [`RelayTransport`], which is built to stay connected and reconnect
 * forever — in a worker that is a socket the browser kills mid-retry, and a
 * `waitUntil` that never settles.
 *
 * These open a connection, do exactly one thing, and close. Every one of them
 * settles or rejects within its timeout, which is what makes them safe to hand
 * to `event.waitUntil`.
 *
 * Same envelopes, same channel, same runner-side command handling as the
 * long-lived transport — the difference is entirely lifecycle.
 */

import { ApiError, type FleetView } from "./api.ts";
import { Identity, type Envelope, type Pairing } from "./crypto.ts";
import type { Command } from "./transport.ts";

/** Long enough for a cellular handshake, short enough for a `waitUntil`. */
const DEFAULT_TIMEOUT_MS = 8_000;

function channelUrl(pairing: Pairing): string {
  return `${pairing.relayUrl.replace(/\/$/, "")}/v1/channel/${pairing.channel}`;
}

/**
 * Open a socket, run `exchange`, and close — whatever happens.
 *
 * The socket is closed in a `finally`, including on timeout. A service worker
 * that leaks sockets gets killed with them still open, which on some browsers
 * counts against the origin.
 */
async function withSocket<T>(
  pairing: Pairing,
  timeoutMs: number,
  exchange: (context: {
    identity: Identity;
    send: (command: Command) => void;
    onMessage: (handler: (payload: unknown) => void) => void;
    settle: (value: T) => void;
    fail: (error: Error) => void;
  }) => void,
): Promise<T> {
  const identity = Identity.fromSecret(pairing.secret);
  const socket = new WebSocket(channelUrl(pairing));

  let handler: ((payload: unknown) => void) | null = null;
  let done = false;

  try {
    return await new Promise<T>((resolve, reject) => {
      const finish = (run: () => void) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        run();
      };
      const settle = (value: T) => finish(() => resolve(value));
      const fail = (error: Error) => finish(() => reject(error));

      const timer = setTimeout(
        () => fail(new ApiError("the runner did not answer", 504)),
        timeoutMs,
      );

      socket.onerror = () => fail(new ApiError("could not reach the relay", 0));
      socket.onclose = () =>
        fail(new ApiError("the relay closed the connection", 0));

      socket.onmessage = (message) => {
        let envelope: Envelope;
        try {
          envelope = JSON.parse(message.data as string) as Envelope;
        } catch {
          return;
        }
        let payload: unknown;
        try {
          payload = identity.openJson(pairing.runnerPublicKey, envelope);
        } catch {
          // Traffic for another paired device. Not an error — the isolation
          // working.
          return;
        }
        handler?.(payload);
      };

      socket.onopen = () =>
        exchange({
          identity,
          send: (command) =>
            socket.send(
              JSON.stringify(
                identity.sealJson(
                  pairing.channel,
                  pairing.deviceId,
                  pairing.runnerPublicKey,
                  command,
                ),
              ),
            ),
          onMessage: (next) => {
            handler = next;
          },
          settle,
          fail,
        });
    });
  } finally {
    done = true;
    socket.close();
  }
}

/**
 * Ask the runner for the current fleet, once.
 *
 * This is what makes a wake-up specific. The push itself carries nothing — the
 * relay cannot read what triggered it — so the only way to say *which* approval
 * is waiting is to go and decrypt it. Locally, in the worker, with the device's
 * own key.
 */
export function fetchFleetOnce(
  pairing: Pairing,
  timeoutMs = DEFAULT_TIMEOUT_MS,
): Promise<FleetView> {
  return withSocket<FleetView>(pairing, timeoutMs, (context) => {
    context.onMessage((payload) => {
      // Matched by shape, exactly as the long-lived transport does: the relay
      // is a fan-out channel with no request/response.
      if (
        typeof payload === "object" &&
        payload !== null &&
        "sessions" in payload &&
        "pending_approvals" in payload
      ) {
        context.settle(payload as FleetView);
      }
    });
    context.send({ type: "snapshot" });
  });
}

/**
 * Send one command and wait long enough to hear a refusal.
 *
 * The relay has no acknowledgement, so a successful command produces silence.
 * Waiting `graceMs` for a `command_error` is the difference between "approved"
 * and "the runner said no and you never found out" — which, from a notification
 * the user has already dismissed, is unrecoverable.
 */
export function sendCommandOnce(
  pairing: Pairing,
  command: Command,
  graceMs = 1_500,
  timeoutMs = DEFAULT_TIMEOUT_MS,
): Promise<{ refused: string | null }> {
  return withSocket<{ refused: string | null }>(pairing, timeoutMs, (context) => {
    context.onMessage((payload) => {
      if (
        typeof payload === "object" &&
        payload !== null &&
        (payload as { type?: string }).type === "command_error"
      ) {
        context.settle({ refused: (payload as { message: string }).message });
      }
    });

    context.send(command);
    // No news is good news, after a moment.
    setTimeout(() => context.settle({ refused: null }), graceMs);
  });
}
