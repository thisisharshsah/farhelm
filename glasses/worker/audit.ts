import type { Context } from "hono";
import type { AppEnv } from "./env.ts";
import { clientIp, userAgent } from "./lib/request.ts";

/** Security-relevant events a person can review in the console. */
export type AuditType =
  | "account_created"
  | "signed_in"
  | "signed_out"
  | "passkey_added"
  | "passkey_removed"
  | "session_revoked"
  | "glasses_linked"
  | "glasses_link_denied"
  | "invite_created"
  | "invite_revoked";

/** A prepared insert, so callers can put it in the same batch (transaction) as the change it records. */
export function auditStatement(
  c: Context<AppEnv>,
  userId: string,
  type: AuditType,
  detail: Record<string, unknown> = {},
): D1PreparedStatement {
  return c.env.DB.prepare(
    "INSERT INTO audit_events (id, user_id, type, detail, ip, user_agent, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
  ).bind(crypto.randomUUID(), userId, type, JSON.stringify(detail), clientIp(c), userAgent(c), Date.now());
}
