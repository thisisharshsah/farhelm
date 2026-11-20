/**
 * YouTube search, rows of videos (Up next, more from a channel, popular),
 * video details and website icons, for signed-in accounts only, cached at
 * the edge so repeats cost neither quota nor latency.
 */
import { Hono } from "hono";
import { MAX_DETAILS_IDS } from "../../src/shared/api.ts";
import { isPageToken, isVideoId, parseRowKey } from "../../src/shared/youtube.ts";
import type { AppEnv } from "../env.ts";
import { cachedCopy, edgeCache } from "../lib/cache.ts";
import { ApiError } from "../lib/http.ts";
import { cachedDetails, parseIds } from "../media/details.ts";
import { fitOf, iconResponse, publicHttpsUrl } from "../media/icon.ts";
import { rowPage, rowResponse, rowsFor } from "../media/rows.ts";
import { admit } from "../media/youtube.ts";
import { requireSession } from "../sessions.ts";

/** The YouTube key, or the answer that search is not set up. */
function youtubeKey(env: AppEnv["Bindings"]): string {
  if (!env.YOUTUBE_API_KEY) throw new ApiError(503, "not_configured", "Search is not set up yet.");
  return env.YOUTUBE_API_KEY;
}

export function mediaRoutes(fetchImpl: typeof fetch = fetch) {
  const r = new Hono<AppEnv>();

  // The first page of results for a query, and where the next starts.
  r.get("/youtube/search", async (c) => {
    const s = requireSession(c);
    const admitted = admit(c.req.query("q"), c.env.YOUTUBE_API_KEY);
    if ("response" in admitted) return admitted.response;
    const page = await rowPage(c, s.userId, { kind: "search", query: admitted.query }, null, youtubeKey(c.env), fetchImpl);
    if (page instanceof Response) return page;
    return c.json({ query: admitted.query, videos: page.videos, next: page.next });
  });

  // The rows that follow a video: more like it, more from its channel, popular in its category (see media/rows.ts).
  r.get("/youtube/rows", async (c) => {
    const s = requireSession(c);
    const seed = c.req.query("seed") ?? "";
    if (!isVideoId(seed)) throw new ApiError(400, "bad_video", "Not a YouTube video.");
    return rowsFor(c, s.userId, seed, youtubeKey(c.env), fetchImpl);
  });

  // One more page of a row, as the wearer reaches its end.
  r.get("/youtube/row", async (c) => {
    const s = requireSession(c);
    const source = parseRowKey(c.req.query("key"));
    if (!source) throw new ApiError(400, "bad_row", "Not a row of videos.");
    const page = c.req.query("page") || null;
    if (page !== null && !isPageToken(page)) throw new ApiError(400, "bad_page", "Not a page of that row.");
    return rowResponse(c, s.userId, source, page, youtubeKey(c.env), fetchImpl);
  });

  // Details of videos that arrived without them (watch history, older answers), by id.
  r.get("/youtube/details", async (c) => {
    const s = requireSession(c);
    const ids = parseIds(c.req.query("ids"));
    if (!ids) throw new ApiError(400, "bad_videos", `Ask for 1 to ${MAX_DETAILS_IDS} YouTube videos.`);
    return cachedDetails(c, s.userId, ids, youtubeKey(c.env), fetchImpl);
  });

  r.get("/icon", async (c) => {
    requireSession(c);
    const site = publicHttpsUrl(c.req.query("url") ?? null);
    const fit = fitOf(c.req.query("fit") ?? null);
    const cache = site ? await edgeCache("site-icons") : null;
    const key = site ? new Request(`https://lens-cache.invalid/icon?origin=${encodeURIComponent(site.origin)}&fit=${fit}`) : null;
    const hit = key ? await cachedCopy(cache, key) : null;
    if (hit) return hit;
    const response = await iconResponse(c.req.raw, fetchImpl);
    if (cache && key && response.status === 302) c.executionCtx.waitUntil(cache.put(key, response.clone()));
    return response;
  });

  return r;
}
