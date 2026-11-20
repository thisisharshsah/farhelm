/**
 * Details of videos by id (length, views, likes, age, description), for the
 * videos that reach the glasses without them: watch history, and answers
 * saved before videos carried details. The glasses ask for what a screen
 * lacks in one request; one `videos.list` call (1 unit) answers up to 50.
 *
 * Each video is cached at the edge on its own, so any later list that holds
 * it (history, results, Up next) reuses it whatever else it asks for.
 */
import type { Context } from "hono";
import { MAX_DETAILS_IDS, VideoDetailsItem } from "../../src/shared/api.ts";
import { isVideoId } from "../../src/shared/youtube.ts";
import type { AppEnv } from "../env.ts";
import { edgeCache } from "../lib/cache.ts";
import { limit } from "../lib/rateLimit.ts";
import { json, videoDetails } from "./youtube.ts";

/** How long a video's details are reused: views and likes move, but slowly. */
export const DETAILS_TTL_SECONDS = 6 * 3600;
/** How long the glasses may keep an answer; they also keep it in memory. */
const BROWSER_TTL_SECONDS = 600;

/** The ids asked for: 1 to 50 YouTube ids, comma-separated, each once; null when unusable. */
export function parseIds(raw: string | null | undefined): string[] | null {
  const ids = [...new Set((raw ?? "").split(",").map((id) => id.trim()).filter(Boolean))];
  if (ids.length === 0 || ids.length > MAX_DETAILS_IDS || !ids.every(isVideoId)) return null;
  return ids;
}

const keyFor = (id: string) => new Request(`https://lens-cache.invalid/youtube/video/v1?id=${id}`);

async function cachedItem(cache: Cache | null, id: string): Promise<VideoDetailsItem | null> {
  const hit = await cache?.match(keyFor(id));
  if (!hit) return null;
  try {
    const parsed = VideoDetailsItem.safeParse(await hit.json());
    return parsed.success && parsed.data.id === id ? parsed.data : null;
  } catch {
    return null;
  }
}

/**
 * The details of `ids` as an HTTP response: the edge cache first, then the
 * person's limit and one YouTube call for the rest. Assumes the ids were
 * parsed and the key is set.
 */
export async function cachedDetails(
  c: Context<AppEnv>,
  userId: string,
  ids: readonly string[],
  apiKey: string,
  fetchImpl: typeof fetch,
): Promise<Response> {
  const cache = await edgeCache("youtube-details");
  const found = new Map<string, VideoDetailsItem>();
  const hits = await Promise.all(ids.map((id) => cachedItem(cache, id)));
  hits.forEach((hit) => hit && found.set(hit.id, hit));

  const missing = ids.filter((id) => !found.has(id));
  if (missing.length > 0) {
    // Only what reaches YouTube spends quota, so only that counts against the person.
    await limit(c, "API_LIMITER", `details:${userId}`);
    const fetched = await videoDetails(missing, apiKey, fetchImpl);
    if (fetched instanceof Response) return fetched;
    for (const [id, d] of fetched) {
      const item: VideoDetailsItem = { id, ...d };
      found.set(id, item);
      if (cache) {
        const stored = new Response(JSON.stringify(item), {
          headers: { "content-type": "application/json", "cache-control": `public, max-age=${DETAILS_TTL_SECONDS}` },
        });
        c.executionCtx.waitUntil(cache.put(keyFor(id), stored));
      }
    }
  }
  return json(200, { videos: ids.flatMap((id) => found.get(id) ?? []) }, BROWSER_TTL_SECONDS);
}
