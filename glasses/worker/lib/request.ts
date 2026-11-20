import type { Context } from "hono";
import type { AppEnv } from "../env.ts";
import { ApiError } from "./http.ts";

export const clientIp = (c: Context<AppEnv>): string => c.req.header("cf-connecting-ip") ?? "";

export const userAgent = (c: Context<AppEnv>): string => (c.req.header("user-agent") ?? "").slice(0, 300);

/** A short device label from the user agent, for session and passkey lists. */
export function deviceLabel(ua: string): string {
  if (/iPhone/.test(ua)) return "iPhone";
  if (/iPad/.test(ua)) return "iPad";
  if (/Android/.test(ua)) return "Android";
  if (/Macintosh|Mac OS X/.test(ua)) return "Mac";
  if (/Windows/.test(ua)) return "Windows";
  if (/Linux/.test(ua)) return "Linux";
  return "Browser";
}

/**
 * The passkey relying party for this request. Production answers only on the
 * configured host; `localhost` is accepted for development, which a request
 * through Cloudflare can never claim to be.
 */
export function relyingParty(c: Context<AppEnv>): { rpID: string; origin: string } {
  const url = new URL(c.req.url);
  const host = url.hostname;
  if (host === c.env.RP_ID || host === "localhost") return { rpID: host, origin: url.origin };
  throw new ApiError(400, "wrong_host", `Passkeys work on ${c.env.RP_ID} only.`);
}
