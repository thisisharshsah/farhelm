/**
 * The signed-in person's account: who they are, their passkeys, their
 * signed-in devices, their activity, and (for the owner) invites.
 */
import { Hono } from "hono";
import { CeremonyFinish } from "../../src/shared/api.ts";
import { auditStatement } from "../audit.ts";
import { saveChallenge, takeChallenge } from "../challenges.ts";
import type { AppEnv } from "../env.ts";
import { fromBase64Url, randomToken, sha256Hex, toBase64Url } from "../lib/crypto.ts";
import { ApiError, items, notFound } from "../lib/http.ts";
import { body } from "../lib/http.ts";
import { deviceLabel, relyingParty, userAgent } from "../lib/request.ts";
import { requireConsole, requireOwner, requireSession } from "../sessions.ts";
import type { WebAuthnPort } from "../webauthn.ts";

const INVITE_TTL = 7 * 86_400_000;

export function accountRoutes(webauthn: WebAuthnPort) {
  const r = new Hono<AppEnv>();

  r.get("/me", (c) => {
    const s = requireSession(c);
    return c.json({ user: { id: s.userId, name: s.userName, role: s.role }, session: { id: s.id, kind: s.kind } });
  });

  // ---------- passkeys ----------

  r.get("/passkeys", async (c) => {
    const s = requireConsole(c);
    const { results } = await c.env.DB.prepare(
      "SELECT id, name, backed_up, created_at, last_used_at FROM passkeys WHERE user_id = ? ORDER BY created_at",
    )
      .bind(s.userId)
      .all<{ id: string; name: string; backed_up: number; created_at: number; last_used_at: number | null }>();
    return items(
      c,
      results.map((p) => ({
        id: p.id,
        name: p.name,
        backedUp: p.backed_up === 1,
        createdAt: p.created_at,
        lastUsedAt: p.last_used_at,
      })),
    );
  });

  r.post("/passkeys/options", async (c) => {
    const s = requireConsole(c);
    const { rpID } = relyingParty(c);
    const user = await c.env.DB.prepare("SELECT webauthn_user_id FROM users WHERE id = ?")
      .bind(s.userId)
      .first<{ webauthn_user_id: string }>();
    if (!user) throw notFound();
    const { results } = await c.env.DB.prepare("SELECT id, transports FROM passkeys WHERE user_id = ?")
      .bind(s.userId)
      .all<{ id: string; transports: string }>();
    const { challenge, options } = await webauthn.registrationOptions({
      rpName: c.env.RP_NAME,
      rpID,
      userName: s.userName,
      userHandle: fromBase64Url(user.webauthn_user_id),
      exclude: results.map((p) => ({ id: p.id, transports: JSON.parse(p.transports) as string[] })),
    });
    const challengeId = await saveChallenge(c, "add_passkey", challenge, s.userId);
    return c.json({ challengeId, options });
  });

  r.post("/passkeys/verify", async (c) => {
    const s = requireConsole(c);
    const input = await body(c, CeremonyFinish);
    const ceremony = await takeChallenge(c, input.challengeId, "add_passkey");
    if (ceremony.userId !== s.userId) throw new ApiError(400, "challenge_expired", "That took too long. Try again.");
    const { rpID, origin } = relyingParty(c);
    const credential = await webauthn.verifyRegistration({
      response: input.response,
      challenge: ceremony.challenge,
      origin,
      rpID,
    });
    if (!credential) throw new ApiError(400, "passkey_failed", "The passkey could not be verified. Try again.");
    const now = Date.now();
    const name = deviceLabel(userAgent(c));
    try {
      await c.env.DB.batch([
        c.env.DB.prepare(
          `INSERT INTO passkeys (id, user_id, public_key, counter, transports, device_type, backed_up, name, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        ).bind(
          credential.id,
          s.userId,
          toBase64Url(credential.publicKey),
          credential.counter,
          JSON.stringify(credential.transports),
          credential.deviceType,
          credential.backedUp ? 1 : 0,
          name,
          now,
        ),
        auditStatement(c, s.userId, "passkey_added", { name }),
      ]);
    } catch (e) {
      if (/UNIQUE/i.test(String(e))) throw new ApiError(409, "passkey_exists", "This passkey is already registered.");
      throw e;
    }
    return c.json({ id: credential.id, name, backedUp: credential.backedUp, createdAt: now, lastUsedAt: null }, 201);
  });

  r.delete("/passkeys/:id", async (c) => {
    const s = requireConsole(c);
    const count = await c.env.DB.prepare("SELECT COUNT(*) AS n FROM passkeys WHERE user_id = ?")
      .bind(s.userId)
      .first<{ n: number }>();
    if ((count?.n ?? 0) <= 1) {
      throw new ApiError(409, "last_passkey", "Keep at least one passkey, or you will not be able to sign in.");
    }
    const id = c.req.param("id");
    const [deleted] = await c.env.DB.batch([
      c.env.DB.prepare("DELETE FROM passkeys WHERE id = ? AND user_id = ?").bind(id, s.userId),
      auditStatement(c, s.userId, "passkey_removed", { passkey: id.slice(0, 8) }),
    ]);
    if (!deleted?.meta.changes) throw notFound("That passkey is not on your account.");
    return c.body(null, 204);
  });

  // ---------- signed-in devices ----------

  r.get("/sessions", async (c) => {
    const s = requireConsole(c);
    const { results } = await c.env.DB.prepare(
      `SELECT id, kind, name, created_at, last_seen_at FROM sessions
       WHERE user_id = ? AND revoked_at IS NULL AND expires_at > ? ORDER BY last_seen_at DESC`,
    )
      .bind(s.userId, Date.now())
      .all<{ id: string; kind: "console" | "glasses"; name: string; created_at: number; last_seen_at: number }>();
    return items(
      c,
      results.map((row) => ({
        id: row.id,
        kind: row.kind,
        name: row.name,
        createdAt: row.created_at,
        lastSeenAt: row.last_seen_at,
        current: row.id === s.id,
      })),
    );
  });

  r.delete("/sessions/:id", async (c) => {
    const s = requireConsole(c);
    const id = c.req.param("id");
    const target = await c.env.DB.prepare(
      "SELECT name, kind FROM sessions WHERE id = ? AND user_id = ? AND revoked_at IS NULL",
    )
      .bind(id, s.userId)
      .first<{ name: string; kind: string }>();
    if (!target) throw notFound("That device is not signed in.");
    await c.env.DB.batch([
      c.env.DB.prepare("UPDATE sessions SET revoked_at = ? WHERE id = ?").bind(Date.now(), id),
      auditStatement(c, s.userId, "session_revoked", { name: target.name, kind: target.kind }),
    ]);
    return c.body(null, 204);
  });

  // ---------- activity ----------

  r.get("/activity", async (c) => {
    const s = requireConsole(c);
    const { results } = await c.env.DB.prepare(
      "SELECT id, type, detail, ip, created_at FROM audit_events WHERE user_id = ? ORDER BY created_at DESC LIMIT 50",
    )
      .bind(s.userId)
      .all<{ id: string; type: string; detail: string; ip: string; created_at: number }>();
    return items(
      c,
      results.map((e) => ({
        id: e.id,
        type: e.type,
        detail: JSON.parse(e.detail) as Record<string, unknown>,
        ip: e.ip,
        createdAt: e.created_at,
      })),
    );
  });

  // ---------- invites (owner) ----------

  r.get("/invites", async (c) => {
    const s = requireOwner(c);
    const { results } = await c.env.DB.prepare(
      `SELECT i.id, i.created_at, i.expires_at, u.name AS used_by, i.used_at, i.revoked_at
       FROM invites i LEFT JOIN users u ON u.id = i.used_by
       WHERE i.created_by = ? ORDER BY i.created_at DESC LIMIT 50`,
    )
      .bind(s.userId)
      .all<{
        id: string;
        created_at: number;
        expires_at: number;
        used_by: string | null;
        used_at: number | null;
        revoked_at: number | null;
      }>();
    return items(
      c,
      results.map((i) => ({
        id: i.id,
        createdAt: i.created_at,
        expiresAt: i.expires_at,
        usedBy: i.used_by,
        usedAt: i.used_at,
        revokedAt: i.revoked_at,
      })),
    );
  });

  r.post("/invites", async (c) => {
    const s = requireOwner(c);
    const code = randomToken(12);
    const now = Date.now();
    const invite = { id: crypto.randomUUID(), createdAt: now, expiresAt: now + INVITE_TTL };
    await c.env.DB.batch([
      c.env.DB.prepare(
        "INSERT INTO invites (id, code_hash, created_by, created_at, expires_at) VALUES (?, ?, ?, ?, ?)",
      ).bind(invite.id, await sha256Hex(code), s.userId, now, invite.expiresAt),
      auditStatement(c, s.userId, "invite_created", { invite: invite.id.slice(0, 8) }),
    ]);
    // The code is shown once; only its hash is kept.
    return c.json({ invite: { ...invite, usedBy: null, usedAt: null, revokedAt: null }, code }, 201);
  });

  r.delete("/invites/:id", async (c) => {
    const s = requireOwner(c);
    const id = c.req.param("id");
    const [updated] = await c.env.DB.batch([
      c.env.DB.prepare(
        "UPDATE invites SET revoked_at = ? WHERE id = ? AND created_by = ? AND used_at IS NULL AND revoked_at IS NULL",
      ).bind(Date.now(), id, s.userId),
      auditStatement(c, s.userId, "invite_revoked", { invite: id.slice(0, 8) }),
    ]);
    if (!updated?.meta.changes) throw notFound("That invite is already used or revoked.");
    return c.body(null, 204);
  });

  return r;
}
