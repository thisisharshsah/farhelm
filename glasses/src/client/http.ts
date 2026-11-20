/**
 * The one way the browser apps talk to the Lens API: same-origin cookies,
 * JSON in and out, every answer validated against its schema, and one error
 * type carrying a message that is safe to show.
 */
import type { z } from "zod";
import { ErrorBody } from "../shared/api.ts";

export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

/** Fired when the session is gone, so the app can return to sign-in or pairing. */
export const UNAUTHORIZED_EVENT = "lens:unauthorized";

const TIMEOUT_MS = 15_000;

interface Options<T extends z.ZodType | undefined> {
  method?: "GET" | "POST" | "PUT" | "PATCH" | "DELETE";
  body?: unknown;
  schema?: T;
  signal?: AbortSignal;
  /** For requests the server may hold open (the chat's long poll). */
  timeoutMs?: number;
  /** Finish even if the page is closing (a last save as the app is left). */
  keepalive?: boolean;
}

export async function api<T extends z.ZodType | undefined = undefined>(
  path: string,
  { method = "GET", body, schema, signal, timeoutMs = TIMEOUT_MS, keepalive }: Options<T> = {},
): Promise<T extends z.ZodType ? z.infer<T> : void> {
  const hasBody = body !== undefined || (method !== "GET" && method !== "DELETE");
  let res: Response;
  try {
    res = await fetch(path, {
      method,
      credentials: "same-origin",
      headers: hasBody ? { "content-type": "application/json", accept: "application/json" } : { accept: "application/json" },
      body: hasBody ? JSON.stringify(body ?? {}) : undefined,
      keepalive,
      signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(timeoutMs)]) : AbortSignal.timeout(timeoutMs),
    });
  } catch (e) {
    if (e instanceof DOMException && e.name === "AbortError" && signal?.aborted) throw e;
    if (e instanceof DOMException && e.name === "TimeoutError") {
      throw new HttpError(0, "timeout", "Lens took too long to answer. Try again.");
    }
    throw new HttpError(0, "offline", "No connection. Check your network.");
  }

  if (res.status === 401) dispatchEvent(new Event(UNAUTHORIZED_EVENT));
  if (!res.ok) {
    let parsed: ErrorBody | null = null;
    try {
      const result = ErrorBody.safeParse(await res.json());
      parsed = result.success ? result.data : null;
    } catch {
      // Not JSON (a proxy error page, say).
    }
    throw new HttpError(
      res.status,
      parsed?.error.code ?? "http_error",
      parsed?.error.message ?? (res.status >= 500 ? "Lens is having trouble. Try again." : "That did not work."),
    );
  }
  if (!schema || res.status === 204) return undefined as never;
  const result = schema.safeParse(await res.json());
  if (!result.success) throw new HttpError(res.status, "bad_response", "Lens sent an answer this app does not understand.");
  return result.data as never;
}

/** A message for any thrown value, for display. */
export function messageOf(e: unknown): string {
  if (e instanceof HttpError) return e.message;
  if (e instanceof Error && e.message) return e.message;
  return "Something went wrong.";
}
