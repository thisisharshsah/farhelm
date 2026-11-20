import type { Context } from "hono";
import type { AppEnv } from "./env.ts";
import { ApiError } from "./lib/http.ts";

/** A passkey ceremony has five minutes between options and verification, and each challenge works once. */
const CHALLENGE_TTL = 5 * 60_000;

export type ChallengePurpose = "register" | "add_passkey" | "sign_in";

export async function saveChallenge(
  c: Context<AppEnv>,
  purpose: ChallengePurpose,
  challenge: string,
  userId: string | null,
  data: Record<string, unknown> = {},
): Promise<string> {
  const id = crypto.randomUUID();
  await c.env.DB.prepare(
    "INSERT INTO auth_challenges (id, purpose, challenge, user_id, data, expires_at) VALUES (?, ?, ?, ?, ?, ?)",
  )
    .bind(id, purpose, challenge, userId, JSON.stringify(data), Date.now() + CHALLENGE_TTL)
    .run();
  return id;
}

/** Removes the challenge as it is read, so a response cannot be replayed. */
export async function takeChallenge(
  c: Context<AppEnv>,
  id: string,
  purpose: ChallengePurpose,
): Promise<{ challenge: string; userId: string | null; data: unknown }> {
  const row = await c.env.DB.prepare(
    "DELETE FROM auth_challenges WHERE id = ? AND purpose = ? RETURNING challenge, user_id, data, expires_at",
  )
    .bind(id, purpose)
    .first<{ challenge: string; user_id: string | null; data: string; expires_at: number }>();
  if (!row || row.expires_at < Date.now()) {
    throw new ApiError(400, "challenge_expired", "That took too long. Try again.");
  }
  return { challenge: row.challenge, userId: row.user_id, data: JSON.parse(row.data) as unknown };
}
