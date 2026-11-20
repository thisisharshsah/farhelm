/**
 * The YouTube search contract, shared by the edge function that calls the
 * YouTube Data API and the glasses client that shows its answer.
 *
 * Everything that arrives from the network is `unknown` until it has been
 * through a parser here: TypeScript types alone do not check runtime data.
 */

/** One video as the glasses show it: enough for a card and its details, still a few hundred bytes. */
export interface Video {
  id: string;
  title: string;
  channel: string;
  /** 320x180 thumbnail (mqdefault): sharp on a card, about 15 KB. */
  thumbnail: string;
  /** Length in seconds, or null when YouTube did not say (live streams). */
  seconds: number | null;
  /** Views and likes, when YouTube shows them. */
  views?: number | null;
  likes?: number | null;
  /** When it was published, in ms since 1970. */
  published?: number | null;
  /** The start of its description, links taken out. */
  description?: string;
}

/** How much of a description is kept: two or three lines on the glasses. */
export const DESCRIPTION_LENGTH = 280;

/** A thumbnail from the video id alone: never from a request. */
export function thumbnailOf(id: string, size: "small" | "medium" | "large" = "medium"): string {
  const file = size === "small" ? "default" : size === "large" ? "hqdefault" : "mqdefault";
  return `https://i.ytimg.com/vi/${id}/${file}.jpg`;
}

/** 950 -> "950", 1234 -> "1.2K", 1_234_567 -> "1.2M", 2_100_000_000 -> "2.1B". */
export function compactCount(n: number): string {
  const units: [number, string][] = [
    [1e9, "B"],
    [1e6, "M"],
    [1e3, "K"],
  ];
  for (const [size, unit] of units) {
    if (n >= size) {
      const v = n / size;
      return `${v >= 100 ? Math.round(v) : Math.round(v * 10) / 10}${unit}`;
    }
  }
  return String(Math.max(0, Math.round(n)));
}

/** "today", "3 days ago", "2 weeks ago", "5 months ago", "3 years ago". */
export function ageOf(at: number, now: number): string {
  const days = Math.floor((now - at) / 86_400_000);
  const ago = (n: number, unit: string) => `${n} ${unit}${n === 1 ? "" : "s"} ago`;
  if (days < 1) return "today";
  if (days < 7) return ago(days, "day");
  if (days < 30) return ago(Math.floor(days / 7), "week");
  if (days < 365) return ago(Math.floor(days / 30), "month");
  return ago(Math.floor(days / 365), "year");
}

/** A description's opening, one paragraph: links and hashtags out, spaces collapsed, cut at a word. */
export function shortDescription(text: string): string {
  const clean = decodeEntities(text)
    .replace(/https?:\/\/\S+/g, " ")
    .replace(/(^|\s)#\S+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (clean.length <= DESCRIPTION_LENGTH) return clean;
  const cut = clean.slice(0, DESCRIPTION_LENGTH);
  return `${cut.slice(0, Math.max(cut.lastIndexOf(" "), DESCRIPTION_LENGTH - 40)).trim()}…`;
}

export interface SearchResponse {
  query: string;
  videos: Video[];
}

export const MAX_QUERY_LENGTH = 100;
/** Results kept in a chat answer; its row loads the rest when reached. */
export const RESULTS_PER_SEARCH = 12;
/** Videos asked of YouTube at a time: 50 cost the same quota as 1. */
export const PAGE_SIZE = 50;

/** Trims and collapses whitespace. Returns null for an empty or too long query. */
export function normalizeQuery(raw: string | null | undefined): string | null {
  const q = (raw ?? "").replace(/\s+/g, " ").trim();
  if (q.length === 0 || q.length > MAX_QUERY_LENGTH) return null;
  return q;
}

/** YouTube's video ids are 11 characters of [A-Za-z0-9_-]. */
export function isVideoId(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9_-]{11}$/.test(value);
}

/** YouTube's channel ids: "UC" and 22 characters of [A-Za-z0-9_-]. */
export function isChannelId(value: unknown): value is string {
  return typeof value === "string" && /^UC[A-Za-z0-9_-]{22}$/.test(value);
}

/** YouTube's page tokens, as `nextPageToken` gives them: short and URL-safe. */
export function isPageToken(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(value);
}

/**
 * Where a row of videos comes from. As a key ("related:<video id>") it names
 * the row to the API, which answers it a page at a time.
 */
export type RowSource =
  | { kind: "search"; query: string }
  | { kind: "related"; id: string }
  | { kind: "channel"; id: string }
  | { kind: "popular"; category: string | null };

export type RowKind = RowSource["kind"];

export function rowKey(source: RowSource): string {
  switch (source.kind) {
    case "search":
      return `search:${source.query}`;
    case "related":
    case "channel":
      return `${source.kind}:${source.id}`;
    case "popular":
      return `popular:${source.category ?? "all"}`;
  }
}

/** Reads a row key; null for anything that is not one. */
export function parseRowKey(raw: string | null | undefined): RowSource | null {
  const key = raw ?? "";
  const at = key.indexOf(":");
  const value = key.slice(at + 1);
  switch (at < 0 ? "" : key.slice(0, at)) {
    case "search": {
      const query = normalizeQuery(value);
      return query ? { kind: "search", query } : null;
    }
    case "related":
      return isVideoId(value) ? { kind: "related", id: value } : null;
    case "channel":
      return isChannelId(value) ? { kind: "channel", id: value } : null;
    case "popular":
      return value === "all" ? { kind: "popular", category: null } : /^\d{1,3}$/.test(value) ? { kind: "popular", category: value } : null;
    default:
      return null;
  }
}

/** YouTube's video categories that have a popular chart, by their stable ids (videoCategories.list). */
export const CATEGORY_NAMES: Readonly<Record<string, string>> = {
  "1": "Film & Animation",
  "2": "Autos & Vehicles",
  "10": "Music",
  "15": "Pets & Animals",
  "17": "Sports",
  "20": "Gaming",
  "23": "Comedy",
  "24": "Entertainment",
  "25": "News & Politics",
  "26": "Howto & Style",
  "27": "Education",
  "28": "Science & Technology",
};

/** Parses an ISO 8601 duration such as "PT1H2M3S" into seconds. */
export function parseIsoDuration(value: unknown): number | null {
  if (typeof value !== "string") return null;
  const m = /^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/.exec(value);
  if (!m || value === "P" || value === "PT") return null;
  const [, d = "0", h = "0", min = "0", s = "0"] = m;
  return Number(d) * 86400 + Number(h) * 3600 + Number(min) * 60 + Number(s);
}

/** 75 -> "1:15", 3723 -> "1:02:03". */
export function formatDuration(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const ss = String(s).padStart(2, "0");
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${ss}` : `${m}:${ss}`;
}

/** YouTube's titles arrive HTML-escaped. Only the entities it uses. */
export function decodeEntities(text: string): string {
  return text
    .replace(/&#(\d+);/g, (_, n: string) => String.fromCodePoint(Number(n)))
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

const isRecord = (v: unknown): v is Record<string, unknown> =>
  typeof v === "object" && v !== null && !Array.isArray(v);

const str = (v: unknown): string => (typeof v === "string" ? v : "");

const count = (v: unknown): number | null => {
  const n = typeof v === "string" ? Number(v) : typeof v === "number" ? v : NaN;
  return Number.isFinite(n) && n >= 0 ? Math.floor(n) : null;
};

const when = (v: unknown): number | null => {
  const t = typeof v === "string" ? Date.parse(v) : NaN;
  return Number.isFinite(t) && t > 0 ? t : null;
};

/**
 * Reads a YouTube Data API `search.list` response. Items that are not
 * well-formed videos are skipped rather than failing the whole search.
 */
export function parseSearchList(body: unknown): Omit<Video, "seconds">[] {
  if (!isRecord(body) || !Array.isArray(body.items)) return [];
  const out: Omit<Video, "seconds">[] = [];
  for (const item of body.items) {
    if (!isRecord(item) || !isRecord(item.id) || !isRecord(item.snippet)) continue;
    const id = item.id.videoId;
    if (!isVideoId(id)) continue;
    const thumbs = isRecord(item.snippet.thumbnails) ? item.snippet.thumbnails : {};
    const medium = isRecord(thumbs.medium) ? str(thumbs.medium.url) : "";
    out.push({
      id,
      title: decodeEntities(str(item.snippet.title)) || "Untitled",
      channel: decodeEntities(str(item.snippet.channelTitle)),
      thumbnail: medium.startsWith("https://i.ytimg.com/") ? medium : thumbnailOf(id),
      published: when(item.snippet.publishedAt),
      description: shortDescription(str(item.snippet.description)),
    });
  }
  return out;
}

/** What `videos.list?part=contentDetails,statistics,snippet` knows of a video beyond its title. */
export interface VideoDetails {
  seconds: number | null;
  views: number | null;
  likes: number | null;
  published: number | null;
  /** The full description's opening, when there is one. */
  description: string;
}

/** Reads a `videos.list` response into id -> details. */
export function parseDetails(body: unknown): Map<string, VideoDetails> {
  const out = new Map<string, VideoDetails>();
  if (!isRecord(body) || !Array.isArray(body.items)) return out;
  for (const item of body.items) {
    if (!isRecord(item) || !isVideoId(item.id)) continue;
    const seconds = isRecord(item.contentDetails) ? parseIsoDuration(item.contentDetails.duration) : null;
    const stats = isRecord(item.statistics) ? item.statistics : {};
    out.set(item.id, {
      // Zero is a live stream: no length to show.
      seconds: seconds !== null && seconds > 0 ? seconds : null,
      views: count(stats.viewCount),
      likes: count(stats.likeCount),
      published: isRecord(item.snippet) ? when(item.snippet.publishedAt) : null,
      description: isRecord(item.snippet) ? shortDescription(str(item.snippet.description)) : "",
    });
  }
  return out;
}

/** The token for the next page of a YouTube list, or null at its end. */
export function nextPageOf(body: unknown): string | null {
  return isRecord(body) && isPageToken(body.nextPageToken) ? body.nextPageToken : null;
}

/**
 * Reads a `videos.list` response with snippet, contentDetails, statistics
 * and status into whole videos, in order, keeping only what the embedded
 * player can play (no private, non-embeddable or upcoming videos). Titles
 * here are plain text; search.list's are escaped.
 */
export function parseVideoList(body: unknown): Video[] {
  if (!isRecord(body) || !Array.isArray(body.items)) return [];
  const out: Video[] = [];
  for (const item of body.items) {
    if (!isRecord(item) || !isVideoId(item.id) || !isRecord(item.snippet)) continue;
    const status = isRecord(item.status) ? item.status : {};
    if (status.embeddable === false || status.privacyStatus === "private" || item.snippet.liveBroadcastContent === "upcoming") continue;
    const seconds = isRecord(item.contentDetails) ? parseIsoDuration(item.contentDetails.duration) : null;
    const stats = isRecord(item.statistics) ? item.statistics : {};
    out.push({
      id: item.id,
      title: str(item.snippet.title) || "Untitled",
      channel: str(item.snippet.channelTitle),
      thumbnail: thumbnailOf(item.id),
      seconds: seconds !== null && seconds > 0 ? seconds : null,
      views: count(stats.viewCount),
      likes: count(stats.likeCount),
      published: when(item.snippet.publishedAt),
      description: shortDescription(str(item.snippet.description)),
    });
  }
  return out;
}
