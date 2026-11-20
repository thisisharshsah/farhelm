import type { Context, MiddlewareHandler } from "hono";
import { deleteCookie, getCookie, setCookie } from "hono/cookie";
import type { AppEnv, SessionContext } from "./env.ts";
import { randomToken, sha256Hex } from "./lib/crypto.ts";
import { forbidden, unauthorized } from "./lib/http.ts";
import { userAgent } from "./lib/request.ts";

/**
 * Sessions are opaque random tokens in an HttpOnly, Secure, SameSite=Lax
 * `__Host-` cookie; the database keeps only their SHA-256. Expiry slides with
 * use: a month for the console, three months for glasses (signing in again
 * there means pairing again). Any session can be revoked from the console.
 */
const COOKIE = "lens_session";
const DAY = 86_400_000;
export const SESSION_TTL = { console: 30 * DAY, glasses: 90 * DAY } as const;
/** Last-seen is written at most this often, so reads stay reads. */
const TOUCH_EVERY = 5 * 60_000;

export interface NewSession {
  id: string;
  token: string;
  statement: D1PreparedStatement;
}

/** Prepares a session insert, so it can join the batch that justifies it. */
export async function prepareSession(
  c: Context<AppEnv>,
  userId: string,
  kind: SessionContext["kind"],
  name: string,
): Promise<NewSession> {
  const id = crypto.randomUUID();
  const token = randomToken();
  const now = Date.now();
  const statement = c.env.DB.prepare(
    `INSERT INTO sessions (id, token_hash, user_id, kind, name, user_agent, created_at, last_seen_at, expires_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind(id, await sha256Hex(token), userId, kind, name, userAgent(c), now, now, now + SESSION_TTL[kind]);
  return { id, token, statement };
}

export function setSessionCookie(c: Context<AppEnv>, token: string, kind: SessionContext["kind"]): void {
  setCookie(c, COOKIE, token, {
    prefix: "host",
    path: "/",
    secure: true,
    httpOnly: true,
    sameSite: "Lax",
    maxAge: SESSION_TTL[kind] / 1000,
  });
}

export function clearSessionCookie(c: Context<AppEnv>): void {
  deleteCookie(c, COOKIE, { prefix: "host", path: "/", secure: true });
}

interface SessionRow {
  id: string;
  user_id: string;
  kind: SessionContext["kind"];
  last_seen_at: number;
  user_name: string;
  role: SessionContext["role"];
}

/** Loads the session for every API request; routes that need one call `requireSession`. */
export const loadSession: MiddlewareHandler<AppEnv> = async (c, next) => {
  c.set("session", null);
  const token = getCookie(c, COOKIE, "host");
  if (token && token.length <= 100) {
    const now = Date.now();
    const row = await c.env.DB.prepare(
      `SELECT s.id, s.user_id, s.kind, s.last_seen_at, u.name AS user_name, u.role
       FROM sessions s JOIN users u ON u.id = s.user_id
       WHERE s.token_hash = ? AND s.revoked_at IS NULL AND s.expires_at > ?`,
    )
      .bind(await sha256Hex(token), now)
      .first<SessionRow>();
    if (row) {
      c.set("session", { id: row.id, userId: row.user_id, userName: row.user_name, role: row.role, kind: row.kind });
      if (now - row.last_seen_at > TOUCH_EVERY) {
        const touch = c.env.DB.prepare("UPDATE sessions SET last_seen_at = ?, expires_at = ? WHERE id = ?")
          .bind(now, now + SESSION_TTL[row.kind], row.id)
          .run();
        c.executionCtx.waitUntil(touch);
        // Keep the cookie's own lifetime in step with the sliding expiry.
        setSessionCookie(c, token, row.kind);
      }
    }
  }
  await next();
};

export function requireSession(c: Context<AppEnv>): SessionContext {
  const session = c.get("session");
  if (!session) throw unauthorized();
  return session;
}

/** Account management happens in the console, where the person has a passkey at hand. */
export function requireConsole(c: Context<AppEnv>): SessionContext {
  const session = requireSession(c);
  if (session.kind !== "console") throw forbidden("Do this from lens.aurovie.com on your phone or computer.");
  return session;
}

export function requireOwner(c: Context<AppEnv>): SessionContext {
  const session = requireConsole(c);
  if (session.role !== "owner") throw forbidden("Only the owner can do this.");
  return session;
}
