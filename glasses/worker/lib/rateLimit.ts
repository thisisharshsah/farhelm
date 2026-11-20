import type { Context } from "hono";
import type { AppEnv } from "../env.ts";
import { ApiError } from "./http.ts";

/**
 * Applies a Workers rate limit. Limits are approximate and per Cloudflare
 * location, which is right for slowing guessing and quota abuse, not for
 * billing. Without the binding (some local setups) nothing is enforced.
 */
export async function limit(
  c: Context<AppEnv>,
  which: "AUTH_LIMITER" | "API_LIMITER",
  key: string,
): Promise<void> {
  const limiter = c.env[which];
  if (!limiter) return;
  const { success } = await limiter.limit({ key });
  if (!success) throw new ApiError(429, "rate_limited", "Too many requests. Wait a minute and try again.");
}
