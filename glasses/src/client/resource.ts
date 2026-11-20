import { useCallback, useEffect, useRef, useState } from "react";
import type { z } from "zod";
import { api, messageOf } from "./http.ts";

export interface Resource<T> {
  data: T | undefined;
  error: string | null;
  loading: boolean;
  reload: () => Promise<void>;
  /** Replaces the data with what the server confirmed after a change. */
  set: (update: (prev: T | undefined) => T | undefined) => void;
}

interface Options {
  /**
   * Keeps the last answer in localStorage under this key and shows it at
   * once on the next start, then refreshes. Scope the key to the account so
   * one person never sees another's data.
   */
  cacheKey?: string;
}

function readCache<T>(key: string | undefined, schema: z.ZodType<T>): T | undefined {
  if (!key) return undefined;
  try {
    const raw = localStorage.getItem(key);
    if (raw === null) return undefined;
    const parsed = schema.safeParse(JSON.parse(raw));
    return parsed.success ? parsed.data : undefined;
  } catch {
    return undefined;
  }
}

function writeCache(key: string | undefined, value: unknown): void {
  if (!key) return;
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // Full or unavailable: the next start just loads from the network.
  }
}

/** Removes every cached answer, on sign-out or when the session ends. */
export function clearCaches(prefix: string): void {
  try {
    for (const key of Object.keys(localStorage)) if (key.startsWith(prefix)) localStorage.removeItem(key);
  } catch {
    // Nothing to clear.
  }
}

/** Loads one GET endpoint, with loading, error, reload and cache. */
export function useResource<T>(path: string, schema: z.ZodType<T>, { cacheKey }: Options = {}): Resource<T> {
  const [data, setData] = useState<T | undefined>(() => readCache(cacheKey, schema));
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const live = useRef<AbortController | null>(null);

  const reload = useCallback(async () => {
    live.current?.abort();
    const controller = new AbortController();
    live.current = controller;
    setLoading(true);
    try {
      const next = await api(path, { schema, signal: controller.signal });
      if (controller.signal.aborted) return;
      setData(next as T);
      setError(null);
      writeCache(cacheKey, next);
    } catch (e) {
      if (controller.signal.aborted) return;
      setError(messageOf(e));
    } finally {
      if (!controller.signal.aborted) setLoading(false);
    }
  }, [path, schema, cacheKey]);

  useEffect(() => {
    void reload();
    return () => live.current?.abort();
  }, [reload]);

  const set = useCallback(
    (update: (prev: T | undefined) => T | undefined) => {
      setData((prev) => {
        const next = update(prev);
        writeCache(cacheKey, next);
        return next;
      });
    },
    [cacheKey],
  );

  return { data, error, loading, reload, set };
}
