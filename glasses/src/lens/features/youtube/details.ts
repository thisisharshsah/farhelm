/**
 * Details (length, views, likes, age, description) for videos that reach the
 * glasses without them: watch history, and answers saved before videos
 * carried details. Every list asks for what it lacks; the asks of one render
 * go out together, 50 videos a request, and answers are kept for the session,
 * so each card on every screen shows the same details.
 */
import { useEffect, useSyncExternalStore } from "react";
import { api } from "../../../client/http.ts";
import { MAX_DETAILS_IDS, VideoDetailsList, type VideoDetailsItem, type VideoItem } from "../../../shared/api.ts";

/** Asks made within this long go out as one request. */
const BATCH_MS = 30;
/** After a failed ask, wait this long before asking again, doubling up to the cap. */
const RETRY_MS = 30_000;
const RETRY_CAP_MS = 15 * 60_000;
/** Videos remembered; the oldest go first. */
const KEEP = 500;

/** Answers by id; null when YouTube has none (a private or removed video). */
const known = new Map<string, VideoDetailsItem | null>();
const asking = new Set<string>();
const failed = new Map<string, { until: number; tries: number }>();
let queue = new Set<string>();
let timer: ReturnType<typeof setTimeout> | undefined;

let version = 0;
const listeners = new Set<() => void>();
const changed = () => {
  version++;
  for (const listener of listeners) listener();
};
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const currentVersion = () => version;

/** Whether a video came without its details: neither views nor likes. */
export const lacksDetails = (v: VideoItem) => v.views == null && v.likes == null;

/** A video with what is known of it filled in; what it already has wins. */
export function withDetails<T extends VideoItem>(v: T): T {
  const d = known.get(v.id);
  if (!d) return v;
  return {
    ...v,
    seconds: v.seconds ?? d.seconds,
    views: v.views ?? d.views,
    likes: v.likes ?? d.likes,
    published: v.published ?? d.published,
    description: v.description || d.description,
  };
}

function remember(id: string, item: VideoDetailsItem | null) {
  known.delete(id);
  known.set(id, item);
  if (known.size > KEEP) known.delete(known.keys().next().value!);
}

async function ask(ids: string[]) {
  for (const id of ids) asking.add(id);
  try {
    const { videos } = await api(`/api/youtube/details?ids=${ids.join(",")}`, { schema: VideoDetailsList });
    const answers = new Map(videos.map((v) => [v.id, v]));
    for (const id of ids) {
      remember(id, answers.get(id) ?? null);
      failed.delete(id);
    }
    changed();
  } catch {
    let wait = RETRY_MS;
    for (const id of ids) {
      const tries = (failed.get(id)?.tries ?? 0) + 1;
      wait = Math.min(RETRY_MS * 2 ** (tries - 1), RETRY_CAP_MS);
      failed.set(id, { until: Date.now() + wait, tries });
    }
    // Lists still showing these ask again once the wait is over.
    setTimeout(changed, wait);
  } finally {
    for (const id of ids) asking.delete(id);
  }
}

function flush() {
  timer = undefined;
  const ids = [...queue];
  queue = new Set();
  for (let i = 0; i < ids.length; i += MAX_DETAILS_IDS) void ask(ids.slice(i, i + MAX_DETAILS_IDS));
}

/** Queues ids for the next request, skipping what is known, on its way, or waiting after a failure. */
export function want(ids: readonly string[]) {
  const now = Date.now();
  for (const id of ids) {
    if (known.has(id) || asking.has(id) || (failed.get(id)?.until ?? 0) > now) continue;
    queue.add(id);
  }
  if (queue.size > 0 && timer === undefined) timer = setTimeout(flush, BATCH_MS);
}

/** The videos with their details filled in, asking for any that lack them; renders again as answers come. */
export function useDetails<T extends VideoItem>(videos: readonly T[]): T[] {
  const at = useSyncExternalStore(subscribe, currentVersion);
  const lacking = videos
    .filter((v) => lacksDetails(v) && !known.has(v.id))
    .map((v) => v.id)
    .join(",");
  useEffect(() => {
    if (lacking) want(lacking.split(","));
  }, [lacking, at]);
  return videos.map(withDetails);
}
