import { createApp } from "./app.ts";
import type { Env } from "./env.ts";

const app = createApp();

/**
 * Daily housekeeping: drop expired ceremonies, pairing codes and sessions,
 * keep the activity log to a year and the chat to 90 days.
 */
export async function cleanup(db: D1Database, now = Date.now()): Promise<void> {
  const DAY = 86_400_000;
  await db.batch([
    db.prepare("DELETE FROM auth_challenges WHERE expires_at < ?").bind(now),
    db.prepare("DELETE FROM device_codes WHERE expires_at < ?").bind(now - DAY),
    db.prepare("DELETE FROM sessions WHERE expires_at < ? OR revoked_at < ?").bind(now - 30 * DAY, now - 30 * DAY),
    db.prepare("DELETE FROM audit_events WHERE created_at < ?").bind(now - 365 * DAY),
    db.prepare("DELETE FROM messages WHERE created_at < ?").bind(now - 90 * DAY),
    db.prepare("DELETE FROM watch_history WHERE watched_at < ?").bind(now - 365 * DAY),
  ]);
}

export default {
  fetch: app.fetch,
  async scheduled(_controller, env, ctx) {
    ctx.waitUntil(cleanup(env.DB));
  },
} satisfies ExportedHandler<Env>;
