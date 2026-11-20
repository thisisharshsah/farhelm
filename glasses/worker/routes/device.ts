/**
 * Pairing the glasses with an account, shaped like the OAuth 2.0 Device
 * Authorization Grant (RFC 8628). The glasses cannot type a password or hold
 * a passkey, and nobody else can see their display, so instead of a QR code:
 *
 *   1. The glasses ask for a pair of codes and show the short one.
 *   2. The person, signed in with a passkey on their phone or computer,
 *      enters it at /link and approves.
 *   3. The glasses, polling with the long secret code, receive a session.
 */
import { Hono } from "hono";
import { DeviceDecisionInput, DevicePollInput, DeviceStartInput, UserCodeInput } from "../../src/shared/api.ts";
import { formatUserCode, generateUserCode, normalizeUserCode } from "../../src/shared/deviceCode.ts";
import { auditStatement } from "../audit.ts";
import type { AppEnv } from "../env.ts";
import { randomBytes, randomToken, sha256Hex } from "../lib/crypto.ts";
import { ApiError, body } from "../lib/http.ts";
import { limit } from "../lib/rateLimit.ts";
import { clientIp, userAgent } from "../lib/request.ts";
import { prepareSession, requireConsole, setSessionCookie } from "../sessions.ts";

export const DEVICE_CODE_TTL_SECONDS = 600;
export const POLL_INTERVAL_SECONDS = 5;

const noCode = () =>
  new ApiError(404, "no_such_code", "No glasses are waiting with that code. Check the code on your glasses.");

export function deviceRoutes() {
  const r = new Hono<AppEnv>();

  r.post("/start", async (c) => {
    await limit(c, "AUTH_LIMITER", `device-start:${clientIp(c)}`);
    const input = await body(c, DeviceStartInput);
    const deviceCode = randomToken(32);
    const now = Date.now();
    // A collision with a live code is astronomically unlikely, but retry rather than fail.
    for (let attempt = 0; attempt < 3; attempt++) {
      const userCode = generateUserCode(randomBytes);
      try {
        await c.env.DB.prepare(
          `INSERT INTO device_codes (device_code_hash, user_code, status, client_name, user_agent, created_at, expires_at)
           VALUES (?, ?, 'pending', ?, ?, ?, ?)`,
        )
          .bind(
            await sha256Hex(deviceCode),
            userCode,
            input.clientName ?? "Glasses",
            userAgent(c),
            now,
            now + DEVICE_CODE_TTL_SECONDS * 1000,
          )
          .run();
        return c.json({
          deviceCode,
          userCode: formatUserCode(userCode),
          verificationUri: `${new URL(c.req.url).origin}/link`,
          expiresIn: DEVICE_CODE_TTL_SECONDS,
          interval: POLL_INTERVAL_SECONDS,
        });
      } catch (e) {
        if (!/UNIQUE/i.test(String(e))) throw e;
      }
    }
    throw new ApiError(503, "busy", "Could not make a code. Try again.");
  });

  r.post("/poll", async (c) => {
    const input = await body(c, DevicePollInput);
    const hash = await sha256Hex(input.deviceCode);
    const row = await c.env.DB.prepare(
      `SELECT d.status, d.client_name, d.expires_at, d.last_polled_at, d.user_id, u.name, u.role
       FROM device_codes d LEFT JOIN users u ON u.id = d.user_id WHERE d.device_code_hash = ?`,
    )
      .bind(hash)
      .first<{
        status: "pending" | "approved" | "denied" | "consumed";
        client_name: string;
        expires_at: number;
        last_polled_at: number;
        user_id: string | null;
        name: string | null;
        role: "owner" | "member" | null;
      }>();
    if (!row) throw new ApiError(400, "invalid_device_code", "Start linking again.");
    const now = Date.now();
    if (row.expires_at < now || row.status === "consumed") return c.json({ status: "expired" });
    if (row.status === "denied") return c.json({ status: "denied" });
    if (row.status === "pending") {
      // Allow a little jitter under the interval; anything faster is told to slow down.
      if (now - row.last_polled_at < POLL_INTERVAL_SECONDS * 1000 - 1000) return c.json({ status: "slow_down" });
      await c.env.DB.prepare("UPDATE device_codes SET last_polled_at = ? WHERE device_code_hash = ?")
        .bind(now, hash)
        .run();
      return c.json({ status: "pending" });
    }

    // Approved: hand out exactly one session for this code, even if two polls race.
    const consumed = await c.env.DB.prepare(
      "UPDATE device_codes SET status = 'consumed' WHERE device_code_hash = ? AND status = 'approved'",
    )
      .bind(hash)
      .run();
    if (!consumed.meta.changes || !row.user_id || !row.name || !row.role) return c.json({ status: "expired" });
    const session = await prepareSession(c, row.user_id, "glasses", row.client_name);
    await session.statement.run();
    setSessionCookie(c, session.token, "glasses");
    return c.json({ status: "approved", user: { id: row.user_id, name: row.name, role: row.role } });
  });

  r.post("/lookup", async (c) => {
    const s = requireConsole(c);
    await limit(c, "AUTH_LIMITER", `device-lookup:${s.userId}`);
    const input = await body(c, UserCodeInput);
    const code = normalizeUserCode(input.userCode);
    if (!code) throw noCode();
    const row = await c.env.DB.prepare(
      "SELECT client_name, created_at, expires_at FROM device_codes WHERE user_code = ? AND status = 'pending' AND expires_at > ?",
    )
      .bind(code, Date.now())
      .first<{ client_name: string; created_at: number; expires_at: number }>();
    if (!row) throw noCode();
    return c.json({ clientName: row.client_name, createdAt: row.created_at, expiresAt: row.expires_at });
  });

  r.post("/decide", async (c) => {
    const s = requireConsole(c);
    await limit(c, "AUTH_LIMITER", `device-lookup:${s.userId}`);
    const input = await body(c, DeviceDecisionInput);
    const code = normalizeUserCode(input.userCode);
    if (!code) throw noCode();
    const approve = input.decision === "approve";
    const now = Date.now();
    const pending = await c.env.DB.prepare(
      "SELECT client_name FROM device_codes WHERE user_code = ? AND status = 'pending' AND expires_at > ?",
    )
      .bind(code, now)
      .first<{ client_name: string }>();
    if (!pending) throw noCode();
    const [updated] = await c.env.DB.batch([
      c.env.DB.prepare(
        "UPDATE device_codes SET status = ?, user_id = ? WHERE user_code = ? AND status = 'pending' AND expires_at > ?",
      ).bind(approve ? "approved" : "denied", s.userId, code, now),
      auditStatement(c, s.userId, approve ? "glasses_linked" : "glasses_link_denied", { name: pending.client_name }),
    ]);
    if (!updated?.meta.changes) throw noCode();
    return c.body(null, 204);
  });

  return r;
}
