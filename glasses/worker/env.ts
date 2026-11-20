/**
 * Bindings and settings the Worker runs with. Values come from
 * wrangler.jsonc (vars, bindings) and from secrets (`wrangler secret put`,
 * or glasses/.env.local in development). Never log a secret.
 */
export interface Env {
  DB: D1Database;
  /** Relying party ID for passkeys: the production host name. */
  RP_ID: string;
  /** Shown by the passkey prompt. */
  RP_NAME: string;
  /** Secret. Without it, YouTube search answers 503. */
  YOUTUBE_API_KEY?: string;
  /** Secret. Lets the first account be created; ignored once an account exists. */
  SETUP_CODE?: string;
  /** Rate limits per Cloudflare location. Missing in some local setups, then not enforced. */
  AUTH_LIMITER?: RateLimit;
  API_LIMITER?: RateLimit;
}

export interface SessionContext {
  id: string;
  userId: string;
  userName: string;
  role: "owner" | "member";
  kind: "console" | "glasses";
}

export interface AppEnv {
  Bindings: Env;
  Variables: {
    requestId: string;
    session: SessionContext | null;
  };
}
