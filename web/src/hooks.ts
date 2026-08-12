import { useCallback, useEffect, useRef, useState } from "react";
import type { ServerEvent } from "@relayforge/client-core";

/* ------------------------------------------------------------------ routing */

export type Route =
  | { view: "fleet" }
  | { view: "session"; id: string }
  | { view: "cost"; id: string }
  | { view: "new-session" }
  | { view: "tasks" }
  | { view: "task"; id: string }
  | { view: "new-task" }
  /** The workspace: machines, devices, people, enrolment keys. */
  | { view: "account" }
  | { view: "billing" };

function parseHash(hash: string): Route {
  const parts = hash.replace(/^#\/?/, "").split("/").filter(Boolean);
  if (parts[0] === "s" && parts[1]) {
    return parts[2] === "cost"
      ? { view: "cost", id: parts[1] }
      : { view: "session", id: parts[1] };
  }
  if (parts[0] === "t") {
    if (parts[1] === "new") return { view: "new-task" };
    if (parts[1]) return { view: "task", id: parts[1] };
    return { view: "tasks" };
  }
  if (parts[0] === "new") return { view: "new-session" };
  if (parts[0] === "account") return { view: "account" };
  // Stripe returns here with `?checkout=done`, which lands in the hash.
  if (parts[0]?.startsWith("billing")) return { view: "billing" };
  return { view: "fleet" };
}

/** The session id a route is about, if any. */
export function sessionIdOf(route: Route): string | null {
  return route.view === "session" || route.view === "cost" ? route.id : null;
}

/**
 * Hash routing rather than a router library, and the hash keeps the phone's
 * back gesture working inside an installed PWA for free.
 */
export function useRoute(): [Route, (to: string) => void] {
  const [route, setRoute] = useState<Route>(() => parseHash(location.hash));

  useEffect(() => {
    const onChange = () => setRoute(parseHash(location.hash));
    addEventListener("hashchange", onChange);
    return () => removeEventListener("hashchange", onChange);
  }, []);

  const navigate = useCallback((to: string) => {
    location.hash = to;
  }, []);

  return [route, navigate];
}

/* ------------------------------------------------------------- server events */

type Listener = (event: ServerEvent) => void;

const listeners = new Set<Listener>();
let source: EventSource | null = null;
let statusListeners = new Set<(status: ConnectionStatus) => void>();

export type ConnectionStatus = "connecting" | "open" | "closed";

function broadcastStatus(status: ConnectionStatus) {
  for (const listener of statusListeners) listener(status);
}

function ensureSource() {
  if (source) return;
  source = new EventSource("/v1/events");
  broadcastStatus("connecting");
  source.onopen = () => broadcastStatus("open");
  // EventSource reconnects on its own; surface the gap rather than tearing down.
  source.onerror = () => broadcastStatus("closed");
  source.onmessage = (message) => {
    let event: ServerEvent;
    try {
      event = JSON.parse(message.data) as ServerEvent;
    } catch {
      return;
    }
    for (const listener of listeners) listener(event);
  };
}

function releaseSource() {
  if (listeners.size === 0 && source) {
    source.close();
    source = null;
  }
}

/** Subscribe to the runner's event stream. One connection is shared app-wide. */
export function useServerEvents(onEvent: Listener): ConnectionStatus {
  const [status, setStatus] = useState<ConnectionStatus>("connecting");
  const handler = useRef(onEvent);
  handler.current = onEvent;

  useEffect(() => {
    const listener: Listener = (event) => handler.current(event);
    listeners.add(listener);
    statusListeners.add(setStatus);
    ensureSource();

    return () => {
      listeners.delete(listener);
      statusListeners.delete(setStatus);
      releaseSource();
    };
  }, []);

  return status;
}

/* ----------------------------------------------------------------- resources */

export interface Resource<T> {
  data: T | null;
  error: string | null;
  /** True only on the very first load, when there is nothing to show yet. */
  loading: boolean;
  /** True while refetching over data already on screen. */
  stale: boolean;
  reload: () => void;
}

/**
 * Fetch-and-hold. Refetches keep the previous render on screen at reduced
 * opacity instead of flashing a skeleton and jumping the layout.
 */
export function useResource<T>(
  load: () => Promise<T>,
  deps: readonly unknown[],
): Resource<T> {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState(true);
  const [nonce, setNonce] = useState(0);
  const loader = useRef(load);
  loader.current = load;

  useEffect(() => {
    let cancelled = false;
    setPending(true);
    loader
      .current()
      .then((next) => {
        if (cancelled) return;
        setData(next);
        setError(null);
      })
      .catch((cause: unknown) => {
        if (cancelled) return;
        setError(cause instanceof Error ? cause.message : String(cause));
      })
      .finally(() => {
        if (!cancelled) setPending(false);
      });

    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, nonce]);

  const reload = useCallback(() => setNonce((n) => n + 1), []);

  return {
    data,
    error,
    loading: pending && data === null,
    stale: pending && data !== null,
    reload,
  };
}
