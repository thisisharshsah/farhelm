/**
 * Accounts and sign-in with passkeys (console only: the glasses cannot hold
 * a passkey, so they pair through /api/device instead).
 *
 * The first account is the owner and needs the SETUP_CODE secret; later
 * accounts need a single-use invite from the owner.
 */
import { Hono, type Context } from "hono";
import { z } from "zod";
import { CeremonyFinish, RegisterOptionsInput } from "../../src/shared/api.ts";
import { auditStatement } from "../audit.ts";
import { saveChallenge, takeChallenge } from "../challenges.ts";
import type { AppEnv } from "../env.ts";
import { fromBase64Url, randomBytes, safeEqual, sha256Hex, toBase64Url } from "../lib/crypto.ts";
import { ApiError, body } from "../lib/http.ts";
import { limit } from "../lib/rateLimit.ts";
import { clientIp, deviceLabel, relyingParty, userAgent } from "../lib/request.ts";
import { clearSessionCookie, prepareSession, setSessionCookie } from "../sessions.ts";
import type { WebAuthnPort } from "../webauthn.ts";

const RegisterData = z.object({
  name: z.string(),
  role: z.enum(["owner", "member"]),
  inviteId: z.string().nullable(),
  userHandle: z.string(),
});

const badInvite = () => new ApiError(403, "bad_invite", "That invite code is not valid, or it was already used.");

/** Decides what an invite code grants, without using it up yet. */
async function admitInvite(c: Context<AppEnv>, code: string): Promise<{ role: "owner" | "member"; inviteId: string | null }> {
  const users = await c.env.DB.prepare("SELECT COUNT(*) AS n FROM users").first<{ n: number }>();
  if ((users?.n ?? 0) === 0) {
    if (!c.env.SETUP_CODE) throw new ApiError(503, "not_set_up", "Lens is not set up yet. Set SETUP_CODE first.");
    if (!safeEqual(code, c.env.SETUP_CODE)) throw badInvite();
    return { role: "owner", inviteId: null };
  }
  const invite = await c.env.DB.prepare(
    "SELECT id FROM invites WHERE code_hash = ? AND used_at IS NULL AND revoked_at IS NULL AND expires_at > ?",
  )
    .bind(await sha256Hex(code), Date.now())
    .first<{ id: string }>();
  if (!invite) throw badInvite();
  return { role: "member", inviteId: invite.id };
}

export function authRoutes(webauthn: WebAuthnPort) {
  const r = new Hono<AppEnv>();

  r.post("/register/options", async (c) => {
    await limit(c, "AUTH_LIMITER", `auth:${clientIp(c)}`);
    const input = await body(c, RegisterOptionsInput);
    const { rpID } = relyingParty(c);
    const grant = await admitInvite(c, input.inviteCode);
    const userHandle = randomBytes(new Uint8Array(32));
    const { challenge, options } = await webauthn.registrationOptions({
      rpName: c.env.RP_NAME,
      rpID,
      userName: input.name,
      userHandle,
      exclude: [],
    });
    const challengeId = await saveChallenge(c, "register", challenge, null, {
      name: input.name,
      role: grant.role,
      inviteId: grant.inviteId,
      userHandle: toBase64Url(userHandle),
    });
    return c.json({ challengeId, options });
  });

  r.post("/register/verify", async (c) => {
    await limit(c, "AUTH_LIMITER", `auth:${clientIp(c)}`);
    const input = await body(c, CeremonyFinish);
    const ceremony = await takeChallenge(c, input.challengeId, "register");
    const data = RegisterData.parse(ceremony.data);
    const { rpID, origin } = relyingParty(c);
    const credential = await webauthn.verifyRegistration({
      response: input.response,
      challenge: ceremony.challenge,
      origin,
      rpID,
    });
    if (!credential) throw new ApiError(400, "passkey_failed", "The passkey could not be verified. Try again.");

    const db = c.env.DB;
    const now = Date.now();
    const userId = crypto.randomUUID();
    const label = deviceLabel(userAgent(c));
    // The user row is only written while its grant still holds: no account yet for
    // the owner, an unused invite for everyone else. If it is not written, the
    // passkey insert below fails its foreign key and the whole batch rolls back.
    const insertUser =
      data.role === "owner"
        ? db
            .prepare(
              `INSERT INTO users (id, name, role, webauthn_user_id, created_at)
               SELECT ?, ?, 'owner', ?, ? WHERE NOT EXISTS (SELECT 1 FROM users)`,
            )
            .bind(userId, data.name, data.userHandle, now)
        : db
            .prepare(
              `INSERT INTO users (id, name, role, webauthn_user_id, created_at)
               SELECT ?, ?, 'member', ?, ? WHERE EXISTS (
                 SELECT 1 FROM invites WHERE id = ? AND used_at IS NULL AND revoked_at IS NULL AND expires_at > ?)`,
            )
            .bind(userId, data.name, data.userHandle, now, data.inviteId, now);
    const claimInvite = data.inviteId
      ? [
          db
            .prepare("UPDATE invites SET used_by = ?, used_at = ? WHERE id = ? AND used_at IS NULL")
            .bind(userId, now, data.inviteId),
        ]
      : [];
    const session = await prepareSession(c, userId, "console", label);
    try {
      await db.batch([
        insertUser,
        ...claimInvite,
        db
          .prepare(
            `INSERT INTO passkeys (id, user_id, public_key, counter, transports, device_type, backed_up, name, created_at, last_used_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          )
          .bind(
            credential.id,
            userId,
            toBase64Url(credential.publicKey),
            credential.counter,
            JSON.stringify(credential.transports),
            credential.deviceType,
            credential.backedUp ? 1 : 0,
            label,
            now,
            now,
          ),
        session.statement,
        auditStatement(c, userId, "account_created", { role: data.role }),
      ]);
    } catch (e) {
      const message = String(e);
      if (/FOREIGN KEY/i.test(message)) throw badInvite();
      if (/UNIQUE/i.test(message)) throw new ApiError(409, "passkey_exists", "This passkey is already registered.");
      throw e;
    }
    setSessionCookie(c, session.token, "console");
    return c.json({ user: { id: userId, name: data.name, role: data.role } });
  });

  r.post("/sign-in/options", async (c) => {
    await limit(c, "AUTH_LIMITER", `auth:${clientIp(c)}`);
    const { rpID } = relyingParty(c);
    const { challenge, options } = await webauthn.authenticationOptions({ rpID });
    const challengeId = await saveChallenge(c, "sign_in", challenge, null);
    return c.json({ challengeId, options });
  });

  r.post("/sign-in/verify", async (c) => {
    await limit(c, "AUTH_LIMITER", `auth:${clientIp(c)}`);
    const input = await body(c, CeremonyFinish);
    const ceremony = await takeChallenge(c, input.challengeId, "sign_in");
    const { rpID, origin } = relyingParty(c);
    const row = await c.env.DB.prepare(
      `SELECT p.id, p.public_key, p.counter, p.transports, u.id AS user_id, u.name, u.role
       FROM passkeys p JOIN users u ON u.id = p.user_id WHERE p.id = ?`,
    )
      .bind(input.response.id)
      .first<{
        id: string;
        public_key: string;
        counter: number;
        transports: string;
        user_id: string;
        name: string;
        role: "owner" | "member";
      }>();
    if (!row) throw new ApiError(400, "unknown_passkey", "This passkey is not registered with Lens.");
    const verified = await webauthn.verifyAuthentication({
      response: input.response,
      challenge: ceremony.challenge,
      origin,
      rpID,
      credential: {
        id: row.id,
        publicKey: fromBase64Url(row.public_key),
        counter: row.counter,
        transports: JSON.parse(row.transports) as string[],
      },
    });
    if (!verified) throw new ApiError(400, "passkey_failed", "The passkey could not be verified. Try again.");

    const now = Date.now();
    const session = await prepareSession(c, row.user_id, "console", deviceLabel(userAgent(c)));
    await c.env.DB.batch([
      c.env.DB.prepare("UPDATE passkeys SET counter = ?, last_used_at = ? WHERE id = ?").bind(
        verified.newCounter,
        now,
        row.id,
      ),
      session.statement,
      auditStatement(c, row.user_id, "signed_in", { passkey: row.id.slice(0, 8) }),
    ]);
    setSessionCookie(c, session.token, "console");
    return c.json({ user: { id: row.user_id, name: row.name, role: row.role } });
  });

  r.post("/sign-out", async (c) => {
    const session = c.get("session");
    if (session) {
      await c.env.DB.batch([
        c.env.DB.prepare("UPDATE sessions SET revoked_at = ? WHERE id = ?").bind(Date.now(), session.id),
        auditStatement(c, session.userId, "signed_out", { kind: session.kind }),
      ]);
    }
    clearSessionCookie(c);
    return c.body(null, 204);
  });

  return r;
}

/** The WebAuthn user handle stored for an account, as bytes. */
export const userHandleBytes = (stored: string): Uint8Array => fromBase64Url(stored);
