import type { Context } from "hono";
import type { ContentfulStatusCode } from "hono/utils/http-status";
import type { z } from "zod";
import type { AppEnv } from "../env.ts";

/** An error whose message is safe to show to the person. */
export class ApiError extends Error {
  constructor(
    readonly status: ContentfulStatusCode,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

export const unauthorized = () => new ApiError(401, "unauthorized", "Sign in again.");
export const forbidden = (message = "You do not have access to this.") => new ApiError(403, "forbidden", message);
export const notFound = (message = "Not found.") => new ApiError(404, "not_found", message);

/** Reads and validates a JSON body. Bodies must be JSON, which also keeps cross-site form posts out. */
export async function body<T extends z.ZodType>(c: Context<AppEnv>, schema: T): Promise<z.infer<T>> {
  const type = c.req.header("content-type") ?? "";
  if (!type.toLowerCase().startsWith("application/json")) {
    throw new ApiError(415, "unsupported_media_type", "Send JSON.");
  }
  let raw: unknown;
  try {
    raw = await c.req.json();
  } catch {
    throw new ApiError(400, "bad_json", "The request body is not valid JSON.");
  }
  const parsed = schema.safeParse(raw);
  if (!parsed.success) {
    const first = parsed.error.issues[0];
    throw new ApiError(400, "invalid", first?.message ?? "The request is not valid.");
  }
  return parsed.data;
}

/** Wraps a list the same way everywhere: `{ items: [...] }`. */
export const items = <T>(c: Context<AppEnv>, list: T[]) => c.json({ items: list });
