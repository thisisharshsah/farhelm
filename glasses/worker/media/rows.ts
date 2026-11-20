/**
 * Rows of videos, as YouTube on a TV lays them out, answered a page of 50 at
 * a time so each row keeps growing as the wearer moves along it. A row is
 * named by its key (see `rowKey`):
 *
 *   search:<query>      results                quota: 101 a page
 *   related:<video>     more like a video       101 a page, once 1 for its facts
 *   channel:<channel>   more from a channel       2 a page, once 1 for its uploads list
 *   popular:<category>  popular now in a region   1 a page ("popular:all": every category)
 *
 * Every page, a video's facts and a channel's uploads list are cached at the
 * edge, so each costs quota once per cache period whoever asks; only what
 * reaches YouTube counts against the person's limit.
 */
import type { Context } from "hono";
import type { ContentfulStatusCode } from "hono/utils/http-status";
import { z } from "zod";
import { ErrorBody, RowPage, type VideoRow } from "../../src/shared/api.ts";
import {
  CATEGORY_NAMES,
  RESULTS_PER_SEARCH,
  isChannelId,
  normalizeQuery,
  rowKey,
  type RowKind,
  type RowSource,
  type SearchResponse,
} from "../../src/shared/youtube.ts";
import type { AppEnv } from "../env.ts";
import { edgeCache } from "../lib/cache.ts";
import { ApiError } from "../lib/http.ts";
import { limit } from "../lib/rateLimit.ts";
import { MUSIC, cleanChannel, parseFacts, relatedQuery, type VideoFacts } from "./related.ts";
import { channelOf, error, json, playlistPage, popularPage, searchPage, snippetOf, type Page } from "./youtube.ts";

/** How long a page is reused, by the kind of row: results and charts move faster than a channel or an artist. */
const PAGE_TTL: Record<RowKind, number> = { search: 3600, related: 12 * 3600, channel: 3 * 3600, popular: 2 * 3600 };
const FACTS_TTL = 7 * 86_400;
const CHANNEL_TTL = 30 * 86_400;
/** The glasses may keep an answer this long; they keep rows in memory too. */
const BROWSER_TTL = 600;

const Facts = z.object({ title: z.string(), channel: z.string(), channelId: z.string(), tags: z.array(z.string()), categoryId: z.string() });
const Channel = z.object({ title: z.string(), uploads: z.string() });

/** Where the person is, for what is popular there (Cloudflare's country), else the US. */
export function regionOf(c: Context<AppEnv>): string {
  const country = (c.req.raw as { cf?: { country?: unknown } }).cf?.country;
  return typeof country === "string" && /^[A-Z]{2}$/.test(country) && country !== "XX" && country !== "T1" ? country : "US";
}

/**
 * A value from the edge cache, else from `load` (which may answer with an
 * error response), stored for `ttl` seconds. A cached value that no longer
 * reads as `schema` is loaded again.
 */
async function cached<T>(c: Context<AppEnv>, url: string, ttl: number, schema: z.ZodType<T>, load: () => Promise<T | Response>): Promise<T | Response> {
  const cache = await edgeCache("youtube-rows");
  const key = new Request(url);
  const hit = await cache?.match(key);
  if (hit) {
    try {
      const parsed = schema.safeParse(await hit.json());
      if (parsed.success) return parsed.data;
    } catch {
      // Load it again.
    }
  }
  const value = await load();
  if (cache && !(value instanceof Response)) {
    const stored = new Response(JSON.stringify(value), {
      headers: { "content-type": "application/json", "cache-control": `public, max-age=${ttl}` },
    });
    c.executionCtx.waitUntil(cache.put(key, stored));
  }
  return value;
}

const BASE = "https://lens-cache.invalid/youtube";

/** A video's facts (title, channel, tags, category), null when YouTube does not know it. */
async function factsOf(c: Context<AppEnv>, userId: string, id: string, apiKey: string, fetchImpl: typeof fetch): Promise<VideoFacts | null | Response> {
  return cached(c, `${BASE}/facts/v1?id=${id}`, FACTS_TTL, Facts.nullable(), async () => {
    await limit(c, "API_LIMITER", `browse:${userId}`);
    const found = await snippetOf(id, apiKey, fetchImpl);
    return found instanceof Response ? found : parseFacts(found.body);
  });
}

/** A page of a row. `pageToken` is null for the first. */
export async function rowPage(
  c: Context<AppEnv>,
  userId: string,
  source: RowSource,
  pageToken: string | null,
  apiKey: string,
  fetchImpl: typeof fetch,
): Promise<Page | Response> {
  const page = pageToken ?? undefined;
  const region = source.kind === "popular" ? regionOf(c) : "";
  // Case and spacing do not change results.
  const name = source.kind === "search" ? `search:${source.query.toLowerCase()}` : rowKey(source);
  const url = `${BASE}/row/v1?key=${encodeURIComponent(name)}&page=${pageToken ?? ""}&region=${region}`;
  return cached(c, url, PAGE_TTL[source.kind], RowPage, async () => {
    switch (source.kind) {
      case "search":
        await limit(c, "API_LIMITER", `search:${userId}`);
        return searchPage(source.query, apiKey, fetchImpl, { pageToken: page });
      case "related": {
        const facts = await factsOf(c, userId, source.id, apiKey, fetchImpl);
        if (facts instanceof Response) return facts;
        if (!facts) return error(404, "not_found", "That video is not available.");
        await limit(c, "API_LIMITER", `search:${userId}`);
        const found = await searchPage(relatedQuery(facts), apiKey, fetchImpl, {
          categoryId: facts.categoryId === MUSIC ? MUSIC : undefined,
          pageToken: page,
        });
        return found instanceof Response ? found : { videos: found.videos.filter((v) => v.id !== source.id), next: found.next };
      }
      case "channel": {
        const channel = await cached(c, `${BASE}/channel/v1?id=${source.id}`, CHANNEL_TTL, Channel.nullable(), async () => {
          await limit(c, "API_LIMITER", `browse:${userId}`);
          return channelOf(source.id, apiKey, fetchImpl);
        });
        if (channel instanceof Response) return channel;
        if (!channel) return { videos: [], next: null };
        await limit(c, "API_LIMITER", `browse:${userId}`);
        return playlistPage(channel.uploads, apiKey, fetchImpl, page);
      }
      case "popular":
        await limit(c, "API_LIMITER", `browse:${userId}`);
        return popularPage(apiKey, fetchImpl, { region, categoryId: source.category, pageToken: page });
    }
  });
}

/** A failure as the response to send, whether it came back or was thrown (the person's limit). */
async function settle<T>(work: Promise<T | Response>): Promise<T | Response> {
  try {
    return await work;
  } catch (e) {
    if (e instanceof ApiError) return error(e.status, e.code, e.message);
    throw e;
  }
}

/**
 * The rows that follow a video, first page each, in one answer: more like it
 * (Up next), more from its channel, and what is popular in its category.
 * Rows that fail or come back empty are left out; all failing is an error.
 */
export async function rowsFor(c: Context<AppEnv>, userId: string, seed: string, apiKey: string, fetchImpl: typeof fetch): Promise<Response> {
  const facts = await settle(factsOf(c, userId, seed, apiKey, fetchImpl));
  if (facts instanceof Response) return facts;
  if (!facts) return error(404, "not_found", "That video is not available.");

  const wanted: { source: RowSource; subject: string }[] = [{ source: { kind: "related", id: seed }, subject: relatedQuery(facts) }];
  if (isChannelId(facts.channelId)) wanted.push({ source: { kind: "channel", id: facts.channelId }, subject: cleanChannel(facts.channel) || facts.channel });
  const category = CATEGORY_NAMES[facts.categoryId];
  if (category) wanted.push({ source: { kind: "popular", category: facts.categoryId }, subject: category });

  const pages = await Promise.all(wanted.map(({ source }) => settle(rowPage(c, userId, source, null, apiKey, fetchImpl))));
  const rows: VideoRow[] = [];
  let failure: Response | null = null;
  pages.forEach((page, i) => {
    const { source, subject } = wanted[i]!;
    if (page instanceof Response) {
      failure ??= page;
      return;
    }
    const videos = page.videos.filter((v) => v.id !== seed);
    if (videos.length > 0) rows.push({ key: rowKey(source), kind: source.kind, subject, videos, next: page.next });
  });
  if (rows.length === 0 && failure) return failure;
  return json(200, { rows }, BROWSER_TTL);
}

/** One page of one row, as an HTTP response. */
export async function rowResponse(
  c: Context<AppEnv>,
  userId: string,
  source: RowSource,
  pageToken: string | null,
  apiKey: string,
  fetchImpl: typeof fetch,
): Promise<Response> {
  const page = await settle(rowPage(c, userId, source, pageToken, apiKey, fetchImpl));
  return page instanceof Response ? page : json(200, page, BROWSER_TTL);
}

/** Search for the chat: the first results of the row the glasses then grow. Failures throw a message safe to show. */
export async function findVideos(c: Context<AppEnv>, userId: string, rawQuery: string, fetchImpl: typeof fetch): Promise<SearchResponse> {
  const query = normalizeQuery(rawQuery);
  if (!query) throw new ApiError(400, "bad_query", "Search for 1 to 100 characters.");
  const apiKey = c.env.YOUTUBE_API_KEY;
  if (!apiKey) throw new ApiError(503, "not_configured", "Search is not set up yet.");
  const page = await rowPage(c, userId, { kind: "search", query }, null, apiKey, fetchImpl);
  if (page instanceof Response) {
    let body: unknown = null;
    try {
      body = await page.json();
    } catch {
      // Handled below.
    }
    const known = ErrorBody.safeParse(body);
    throw new ApiError(
      page.status as ContentfulStatusCode,
      known.success ? known.data.error.code : "upstream",
      known.success ? known.data.error.message : "YouTube search failed. Try again.",
    );
  }
  return { query, videos: page.videos.slice(0, RESULTS_PER_SEARCH) };
}
