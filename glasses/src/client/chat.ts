/**
 * Lens chat on one device: the conversation, sending with a placeholder that
 * shows at once, and live sync through the API's long poll. The glasses app
 * and the console both use it, so they behave the same.
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { ChatCleared, ChatMessage, ChatPage, type VideoItem } from "../shared/api.ts";
import { HttpError, api, messageOf } from "./http.ts";

/** How long the server may hold a sync request; it answers sooner when there is news. */
const WAIT_SECONDS = 20;
const MAX_PAGE = 100;
const MAX_BACKOFF_MS = 30_000;

export type Scope = "auto" | "videos";

/** A message on its way, shown until the server's copy replaces it. */
export interface Pending {
  clientId: string;
  text: string;
  scope: Scope;
  status: "sending" | "failed";
  error?: string;
  at: number;
}

export interface ChatState {
  /** Oldest first. */
  items: ChatMessage[];
  clearedThrough: number;
}

/** How messages reached this device: its own send, the first load, or live sync. */
export type Arrival = "sent" | "initial" | "synced";

const EMPTY: ChatState = { items: [], clearedThrough: 0 };

/** The last seq this device has seen, cleared ones included: where sync continues from. */
export const cursorOf = (s: ChatState): number => Math.max(s.items.at(-1)?.seq ?? 0, s.clearedThrough);

/** Adds a page: no duplicates, oldest first, cleared ones dropped, at most `keep`. Same object when nothing changed. */
export function mergePage(state: ChatState, page: ChatPage, keep: number): ChatState {
  const clearedThrough = Math.max(state.clearedThrough, page.clearedThrough);
  const known = new Set(state.items.map((m) => m.seq));
  const fresh = page.items.filter((m) => !known.has(m.seq) && m.seq > clearedThrough);
  if (fresh.length === 0 && clearedThrough === state.clearedThrough) return state;
  const items = [...state.items, ...fresh]
    .filter((m) => m.seq > clearedThrough)
    .sort((a, b) => a.seq - b.seq)
    .slice(-keep);
  return { items, clearedThrough };
}

function readCache(key: string): ChatState | null {
  try {
    const raw = localStorage.getItem(key);
    if (!raw) return null;
    const parsed = ChatPage.safeParse(JSON.parse(raw));
    return parsed.success ? parsed.data : null;
  } catch {
    return null;
  }
}

function writeCache(key: string, state: ChatState): void {
  try {
    localStorage.setItem(key, JSON.stringify(state));
  } catch {
    // Full or unavailable: the next start loads from the network.
  }
}

const newId = (): string =>
  typeof crypto.randomUUID === "function" ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(36).slice(2)}`;

const sleep = (ms: number, signal: AbortSignal) =>
  new Promise<void>((resolve) => {
    const id = setTimeout(resolve, ms);
    signal.addEventListener("abort", () => (clearTimeout(id), resolve()), { once: true });
  });

/** Resolves when the page is visible: a hidden tab does not hold a connection open. */
const whenVisible = (signal: AbortSignal) =>
  new Promise<void>((resolve) => {
    if (document.visibilityState === "visible" || signal.aborted) return resolve();
    const check = () => {
      if (document.visibilityState !== "visible" && !signal.aborted) return;
      document.removeEventListener("visibilitychange", check);
      resolve();
    };
    document.addEventListener("visibilitychange", check);
    signal.addEventListener("abort", check, { once: true });
  });

interface Options {
  /** localStorage key, scoped to the account. */
  cacheKey: string;
  /** Messages kept on this device. */
  keep: number;
  /** Called with every page that brought messages, for devices that act on them. */
  onArrive?: (messages: ChatMessage[], how: Arrival) => void;
}

export function useChat({ cacheKey, keep, onArrive }: Options) {
  const [state, setState] = useState<ChatState>(() => readCache(cacheKey) ?? EMPTY);
  const [pending, setPending] = useState<Pending[]>([]);
  const [synced, setSynced] = useState(false);
  const stateRef = useRef(state);
  stateRef.current = state;
  const onArriveRef = useRef(onArrive);
  onArriveRef.current = onArrive;

  const apply = useCallback(
    (page: ChatPage, how: Arrival) => {
      const next = mergePage(stateRef.current, page, keep);
      if (next !== stateRef.current) {
        stateRef.current = next;
        setState(next);
        writeCache(cacheKey, next);
      }
      if (page.items.length) onArriveRef.current?.(page.items, how);
    },
    [cacheKey, keep],
  );

  // Sync: catch up once, then hold a long poll open while the page is visible.
  useEffect(() => {
    const stop = new AbortController();
    void (async () => {
      let first = true;
      let failures = 0;
      while (!stop.signal.aborted) {
        await whenVisible(stop.signal);
        if (stop.signal.aborted) break;
        const s = stateRef.current;
        const cursor = cursorOf(s);
        const wait = first ? 0 : WAIT_SECONDS;
        const path =
          first && cursor === 0
            ? "/api/chat"
            : `/api/chat?after=${cursor}&cleared=${s.clearedThrough}&wait=${wait}`;
        try {
          const page = await api(path, { schema: ChatPage, signal: stop.signal, timeoutMs: (wait + 15) * 1000 });
          apply(page, first ? "initial" : "synced");
          setSynced(true);
          failures = 0;
          // A full page means more is waiting: keep catching up before waiting for news.
          if (page.items.length < MAX_PAGE) first = false;
        } catch (e) {
          if (stop.signal.aborted) break;
          // Signed out: the app leaves this screen; nothing to retry.
          if (e instanceof HttpError && e.status === 401) break;
          failures += 1;
          await sleep(Math.min(MAX_BACKOFF_MS, 1000 * 2 ** failures), stop.signal);
        }
      }
    })();
    return () => stop.abort();
  }, [apply]);

  const send = useCallback(
    async (text: string, scope: Scope = "auto", signal?: AbortSignal): Promise<ChatMessage | null> => {
      const clientId = newId();
      setPending((p) => [...p, { clientId, text, scope, status: "sending", at: Date.now() }]);
      try {
        const message = await api("/api/chat", { method: "POST", body: { text, scope }, schema: ChatMessage, signal, timeoutMs: 25_000 });
        setPending((p) => p.filter((x) => x.clientId !== clientId));
        apply({ items: [message], clearedThrough: 0 }, "sent");
        return message;
      } catch (e) {
        const error = signal?.aborted ? "Took too long. Try again." : messageOf(e);
        setPending((p) => p.map((x) => (x.clientId === clientId ? { ...x, status: "failed", error } : x)));
        return null;
      }
    },
    [apply],
  );

  const dismiss = useCallback((clientId: string) => setPending((p) => p.filter((x) => x.clientId !== clientId)), []);

  const retry = useCallback(
    (clientId: string) => {
      const failed = pending.find((x) => x.clientId === clientId);
      if (!failed) return;
      dismiss(clientId);
      void send(failed.text, failed.scope);
    },
    [pending, dismiss, send],
  );

  /** Plays a video on the glasses (from results seen on another device). */
  const play = useCallback(
    async (video: VideoItem, signal?: AbortSignal): Promise<ChatMessage> => {
      const { thumbnail: _, ...rest } = video;
      const message = await api("/api/chat/play", { method: "POST", body: { video: rest }, schema: ChatMessage, signal });
      apply({ items: [message], clearedThrough: 0 }, "sent");
      return message;
    },
    [apply],
  );

  /** Clears the conversation on every device. */
  const clear = useCallback(async () => {
    const { clearedThrough } = await api("/api/chat", { method: "DELETE", schema: ChatCleared });
    apply({ items: [], clearedThrough }, "sent");
  }, [apply]);

  return { items: state.items, pending, synced, send, retry, dismiss, play, clear };
}

export type Chat = ReturnType<typeof useChat>;
