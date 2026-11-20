/**
 * The YouTube Data API, called at the edge so the API key never reaches the
 * device and the glasses download a few kilobytes of JSON instead of
 * youtube.com. Only signed-in accounts reach it (see routes/media.ts).
 *
 * Written against the standard Fetch API so it runs in the Worker and in
 * tests; caching and limits live in rows.ts and the routes.
 *
 * Quota, against YouTube's default 10,000 units a day: search.list costs
 * 100; videos.list, playlistItems.list and channels.list cost 1 each, for up
 * to 50 items. Every call asks for 50, which costs the same as asking for 1.
 */
import {
  PAGE_SIZE,
  nextPageOf,
  normalizeQuery,
  parseDetails,
  parseSearchList,
  parseVideoList,
  type Video,
  type VideoDetails,
} from "../../src/shared/youtube.ts";

export const API = "https://www.googleapis.com/youtube/v3";
const UPSTREAM_TIMEOUT_MS = 8000;

/** How long a search may be reused: by the edge cache and by the browser. */
export const SEARCH_TTL_SECONDS = 3600;

/** A page of videos and the token for the next, null at the end. */
export interface Page {
  videos: Video[];
  next: string | null;
}

export function json(status: number, body: unknown, cacheSeconds = 0): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      // Private: answers are for signed-in accounts.
      "cache-control": cacheSeconds > 0 ? `private, max-age=${cacheSeconds}` : "no-store",
    },
  });
}

export const error = (status: number, code: string, message: string) => json(status, { error: { code, message } });

/** The query, or an error response when it is unusable or search is not configured. */
export function admit(rawQuery: string | null | undefined, apiKey: string | undefined): { query: string } | { response: Response } {
  const query = normalizeQuery(rawQuery);
  if (!query) return { response: error(400, "bad_query", "Search for 1 to 100 characters.") };
  if (!apiKey) return { response: error(503, "not_configured", "Search is not set up yet.") };
  return { query };
}

export async function getJSON(url: URL, fetchImpl: typeof fetch): Promise<{ ok: boolean; status: number; body: unknown }> {
  const res = await fetchImpl(url, { signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS) });
  let body: unknown = null;
  try {
    body = await res.json();
  } catch {
    body = null;
  }
  return { ok: res.ok, status: res.status, body };
}

/** Reads Google's error reason, for example `quotaExceeded`. */
function upstreamReason(body: unknown): string {
  const errors = (body as { error?: { errors?: { reason?: unknown }[] } } | null)?.error?.errors;
  const reason = Array.isArray(errors) ? errors[0]?.reason : undefined;
  return typeof reason === "string" ? reason : "";
}

/** The answer for a failed YouTube call: the quota, or a message that never echoes Google's (it can include the key). */
function upstreamError(found: { status: number; body: unknown }, message: string): Response {
  const reason = upstreamReason(found.body);
  if (reason === "quotaExceeded" || reason === "dailyLimitExceeded" || found.status === 429) {
    return error(429, "quota", "Today's search limit is used up. It resets at midnight Pacific.");
  }
  return error(502, "upstream", message);
}

/** One YouTube call: its body, or the response to send instead. */
async function call(
  path: string,
  params: Record<string, string | undefined>,
  apiKey: string,
  fetchImpl: typeof fetch,
  failure: string,
): Promise<{ body: unknown } | Response> {
  const url = new URL(`${API}/${path}`);
  for (const [name, value] of Object.entries(params)) if (value !== undefined) url.searchParams.set(name, value);
  url.searchParams.set("key", apiKey);
  let found;
  try {
    found = await getJSON(url, fetchImpl);
  } catch {
    return error(504, "upstream_timeout", "YouTube took too long. Try again.");
  }
  return found.ok ? { body: found.body } : upstreamError(found, failure);
}

/**
 * Length, views, likes, age and description of up to 50 videos, in one
 * `videos.list` call (1 unit whatever the parts). Ids YouTube does not know
 * (private, removed) are absent.
 */
export async function videoDetails(
  ids: readonly string[],
  apiKey: string,
  fetchImpl: typeof fetch = fetch,
): Promise<Map<string, VideoDetails> | Response> {
  const found = await call("videos", { part: "contentDetails,statistics,snippet", id: ids.join(",") }, apiKey, fetchImpl, "YouTube did not answer. Try again.");
  return found instanceof Response ? found : parseDetails(found.body);
}

export interface SearchOptions {
  /** YouTube's category, e.g. "10" for Music, to keep results of the same kind. */
  categoryId?: string;
  pageToken?: string;
}

/**
 * A page of search results, with their details (search.list, 100 units,
 * then videos.list, 1). Only videos that play in the embedded player.
 */
export async function searchPage(query: string, apiKey: string, fetchImpl: typeof fetch = fetch, options: SearchOptions = {}): Promise<Page | Response> {
  const found = await call(
    "search",
    {
      part: "snippet",
      type: "video",
      videoEmbeddable: "true",
      safeSearch: "moderate",
      maxResults: String(PAGE_SIZE),
      q: query,
      videoCategoryId: options.categoryId && /^\d{1,3}$/.test(options.categoryId) ? options.categoryId : undefined,
      pageToken: options.pageToken,
    },
    apiKey,
    fetchImpl,
    "YouTube search failed. Try again.",
  );
  if (found instanceof Response) return found;
  const videos = parseSearchList(found.body);

  // Lengths, views, likes and the full description are a nice-to-have: a
  // failure here still returns the results (the glasses ask again later).
  const fetched = videos.length > 0 ? await videoDetails(videos.map((v) => v.id), apiKey, fetchImpl) : null;
  const details = fetched instanceof Map ? fetched : new Map<string, VideoDetails>();
  return {
    videos: videos.map((v) => {
      const d = details.get(v.id);
      return {
        ...v,
        seconds: d?.seconds ?? null,
        views: d?.views ?? null,
        likes: d?.likes ?? null,
        published: v.published ?? d?.published ?? null,
        description: d?.description || v.description || "",
      };
    }),
    next: nextPageOf(found.body),
  };
}

const WHOLE_VIDEO = "snippet,contentDetails,statistics,status";

/** Whole videos by id, in the order asked (videos.list, 1 unit). */
export async function videosById(ids: readonly string[], apiKey: string, fetchImpl: typeof fetch = fetch): Promise<Video[] | Response> {
  if (ids.length === 0) return [];
  const found = await call("videos", { part: WHOLE_VIDEO, id: ids.join(",") }, apiKey, fetchImpl, "YouTube did not answer. Try again.");
  if (found instanceof Response) return found;
  const byId = new Map(parseVideoList(found.body).map((v) => [v.id, v]));
  return ids.flatMap((id) => byId.get(id) ?? []);
}

/** What is popular now, in a region and optionally a category (videos.list chart, 1 unit a page). */
export async function popularPage(
  apiKey: string,
  fetchImpl: typeof fetch,
  options: { region: string; categoryId: string | null; pageToken?: string },
): Promise<Page | Response> {
  const found = await call(
    "videos",
    {
      part: WHOLE_VIDEO,
      chart: "mostPopular",
      regionCode: options.region,
      videoCategoryId: options.categoryId ?? undefined,
      maxResults: String(PAGE_SIZE),
      pageToken: options.pageToken,
    },
    apiKey,
    fetchImpl,
    "YouTube did not answer. Try again.",
  );
  if (found instanceof Response) return found;
  return { videos: parseVideoList(found.body), next: nextPageOf(found.body) };
}

/** A channel's name and the playlist of its uploads (channels.list, 1 unit); null when it is gone. */
export async function channelOf(
  channelId: string,
  apiKey: string,
  fetchImpl: typeof fetch = fetch,
): Promise<{ title: string; uploads: string } | null | Response> {
  const found = await call("channels", { part: "snippet,contentDetails", id: channelId }, apiKey, fetchImpl, "YouTube did not answer. Try again.");
  if (found instanceof Response) return found;
  const item = (found.body as { items?: { snippet?: { title?: unknown }; contentDetails?: { relatedPlaylists?: { uploads?: unknown } } }[] } | null)
    ?.items?.[0];
  const uploads = item?.contentDetails?.relatedPlaylists?.uploads;
  if (typeof uploads !== "string" || !/^[A-Za-z0-9_-]{10,64}$/.test(uploads)) return null;
  return { title: typeof item?.snippet?.title === "string" ? item.snippet.title : "", uploads };
}

/** A page of a playlist, newest first for uploads (playlistItems.list, then videos.list: 2 units). */
export async function playlistPage(playlistId: string, apiKey: string, fetchImpl: typeof fetch, pageToken?: string): Promise<Page | Response> {
  const found = await call(
    "playlistItems",
    { part: "contentDetails", playlistId, maxResults: String(PAGE_SIZE), pageToken },
    apiKey,
    fetchImpl,
    "YouTube did not answer. Try again.",
  );
  if (found instanceof Response) return found;
  const items = (found.body as { items?: { contentDetails?: { videoId?: unknown } }[] } | null)?.items ?? [];
  const ids = items.map((i) => i.contentDetails?.videoId).filter((id): id is string => typeof id === "string" && /^[A-Za-z0-9_-]{11}$/.test(id));
  const videos = await videosById(ids, apiKey, fetchImpl);
  if (videos instanceof Response) return videos;
  return { videos, next: nextPageOf(found.body) };
}

/** A video's snippet, to work out what follows it (videos.list, 1 unit). */
export async function snippetOf(id: string, apiKey: string, fetchImpl: typeof fetch = fetch): Promise<{ body: unknown } | Response> {
  return call("videos", { part: "snippet", id }, apiKey, fetchImpl, "YouTube did not answer. Try again.");
}
