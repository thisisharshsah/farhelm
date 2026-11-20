/**
 * Watch history, per account: what was played on any device, newest first,
 * with where it was left so any device can resume it.
 */
import { Hono } from "hono";
import { HistoryInput, type HistoryItem } from "../../src/shared/api.ts";
import { isVideoId, thumbnailOf } from "../../src/shared/youtube.ts";
import type { AppEnv } from "../env.ts";
import { ApiError, body, items, notFound } from "../lib/http.ts";
import { limit } from "../lib/rateLimit.ts";
import { requireSession } from "../sessions.ts";

/** Videos kept per account; older ones drop off as new ones are watched. */
export const MAX_HISTORY = 200;
const PAGE = 50;

interface Row {
  video_id: string;
  title: string;
  channel: string;
  seconds: number | null;
  position: number;
  watched_at: number;
}

const toItem = (r: Row): HistoryItem => ({
  id: r.video_id,
  title: r.title,
  channel: r.channel,
  // From the id, never stored from a request.
  thumbnail: thumbnailOf(r.video_id),
  seconds: r.seconds,
  position: r.position,
  watchedAt: r.watched_at,
});

export function historyRoutes() {
  const r = new Hono<AppEnv>();

  r.get("/", async (c) => {
    const s = requireSession(c);
    const { results } = await c.env.DB.prepare(
      "SELECT video_id, title, channel, seconds, position, watched_at FROM watch_history WHERE user_id = ? ORDER BY watched_at DESC LIMIT ?",
    )
      .bind(s.userId, PAGE)
      .all<Row>();
    return items(c, results.map(toItem));
  });

  // Recorded when a video starts and again as it plays, so the position follows.
  r.put("/:id", async (c) => {
    const s = requireSession(c);
    const id = c.req.param("id");
    const { video, position } = await body(c, HistoryInput);
    if (!isVideoId(id) || video.id !== id) throw new ApiError(400, "bad_video", "Not a YouTube video.");
    await limit(c, "API_LIMITER", `history:${s.userId}`);
    const now = Date.now();
    const at = video.seconds ? Math.min(position, video.seconds) : position;
    await c.env.DB.batch([
      c.env.DB.prepare(
        `INSERT INTO watch_history (user_id, video_id, title, channel, seconds, position, watched_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT (user_id, video_id) DO UPDATE SET
           title = excluded.title, channel = excluded.channel,
           seconds = COALESCE(excluded.seconds, watch_history.seconds),
           position = excluded.position, watched_at = excluded.watched_at`,
      ).bind(s.userId, id, video.title, video.channel, video.seconds, at, now),
      // Keep the newest MAX_HISTORY.
      c.env.DB.prepare(
        `DELETE FROM watch_history WHERE user_id = ? AND watched_at < (
           SELECT watched_at FROM watch_history WHERE user_id = ? ORDER BY watched_at DESC LIMIT 1 OFFSET ?)`,
      ).bind(s.userId, s.userId, MAX_HISTORY - 1),
    ]);
    return c.json(toItem({ video_id: id, title: video.title, channel: video.channel, seconds: video.seconds, position: at, watched_at: now }));
  });

  r.delete("/:id", async (c) => {
    const s = requireSession(c);
    const result = await c.env.DB.prepare("DELETE FROM watch_history WHERE user_id = ? AND video_id = ?")
      .bind(s.userId, c.req.param("id"))
      .run();
    if (!result.meta.changes) throw notFound("That video is not in your history.");
    return c.body(null, 204);
  });

  r.delete("/", async (c) => {
    const s = requireSession(c);
    await c.env.DB.prepare("DELETE FROM watch_history WHERE user_id = ?").bind(s.userId).run();
    return c.body(null, 204);
  });

  return r;
}
