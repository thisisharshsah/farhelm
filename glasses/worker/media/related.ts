/**
 * What follows a video. YouTube removed related-video search from its Data
 * API in 2023 (search.list relatedToVideoId), so Lens works it out from the
 * video's own snippet: for music, more by the same artist in Music;
 * otherwise more on the same topic, from its tags or title.
 */

/** The parts of a video's snippet that say what is like it. */
export interface VideoFacts {
  title: string;
  channel: string;
  channelId: string;
  tags: string[];
  categoryId: string;
}

export const MUSIC = "10";

/** The snippet of the one video asked for, or null. */
export function parseFacts(body: unknown): VideoFacts | null {
  const item = (body as { items?: unknown[] } | null)?.items?.[0] as
    | { snippet?: { title?: unknown; channelTitle?: unknown; channelId?: unknown; tags?: unknown; categoryId?: unknown } }
    | undefined;
  const s = item?.snippet;
  if (!s || typeof s.title !== "string") return null;
  return {
    title: s.title,
    channel: typeof s.channelTitle === "string" ? s.channelTitle : "",
    channelId: typeof s.channelId === "string" ? s.channelId : "",
    tags: Array.isArray(s.tags) ? s.tags.filter((t): t is string => typeof t === "string").slice(0, 30) : [],
    categoryId: typeof s.categoryId === "string" ? s.categoryId : "",
  };
}

/** Bracketed notes and labels that say nothing about the song itself. */
const NOISE =
  /\s*[([{【][^)\]}】]*[)\]}】]|\s*\|.*$|\b(official\s+(music\s+)?video|official\s+audio|lyrics?(\s+video)?|visuali[sz]er|remaster(ed)?(\s+\d{4})?|4k|hd)\b/gi;

export function cleanTitle(title: string): string {
  return title.replace(NOISE, " ").replace(/\s+/g, " ").trim();
}

/** "TaylorSwiftVEVO" -> "TaylorSwift", "Adele - Topic" -> "Adele". */
export const cleanChannel = (channel: string) => channel.replace(/\s*-\s*topic$/i, "").replace(/vevo$/i, "").trim();

/**
 * What to search for: for music, the artist ("Artist - Song" titles, else the
 * channel); otherwise the video's own tags, else its title's first words.
 */
export function relatedQuery(f: Pick<VideoFacts, "title" | "channel" | "tags" | "categoryId">): string {
  const title = cleanTitle(f.title);
  if (f.categoryId === MUSIC) {
    const parts = title.split(/\s+[-\u2013\u2014]\s+/);
    const artist = parts.length >= 2 ? parts[0]!.replace(/\s+(ft|feat|featuring)\b.*$/i, "").trim() : "";
    return (artist || cleanChannel(f.channel) || title).slice(0, 100);
  }
  const tags = f.tags.filter((t) => t.length >= 3 && t.length <= 30).slice(0, 3);
  if (tags.length) return tags.join(" ").slice(0, 100);
  return (title.split(" ").slice(0, 5).join(" ") || cleanChannel(f.channel)).slice(0, 100);
}
