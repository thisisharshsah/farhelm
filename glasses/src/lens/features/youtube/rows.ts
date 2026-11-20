/**
 * Rows of videos on the glasses, as YouTube on a TV shows them: each row
 * grows a page at a time as the wearer moves along it, and a feed adds rows
 * as the wearer moves down it. The rows come from the API (see
 * worker/media/rows.ts) and are kept for the session, so leaving a screen and
 * coming back keeps everything loaded.
 */
import { useCallback, useEffect, useState, useSyncExternalStore } from "react";
import { api } from "../../../client/http.ts";
import { RowPage, VideoRows, type VideoItem, type VideoRow } from "../../../shared/api.ts";

export interface Row {
  key: string;
  kind: VideoRow["kind"];
  /** What it is about: the query, the artist or topic followed, the channel, the category ("all": every one). */
  subject: string;
  videos: VideoItem[];
  /** The next page to ask for: "" for the first, null at the end. */
  next: string | null;
  loading: boolean;
  failed: boolean;
}

/** Where a feed's rows come from: the rows that follow a video, or one row by key. */
export type FeedSource = { seed: string; title: string } | { row: string };

export interface FeedEntry {
  row: Row;
  source: FeedSource;
  /** Which source it came from, 0 for the first. */
  from: number;
}

/** After a failure, ask again only after this long. */
const RETRY_MS = 30_000;
/** The rows that follow a video are asked for again after this long, for what is new. */
const SEED_TTL_MS = 60 * 60_000;
/** Pages that add nothing new (every video already in the row) are skipped, up to this many in a row. */
const MAX_SKIPS = 3;
/** A feed loads sources until it shows at least this many rows. */
const MIN_ROWS = 3;

const rows = new Map<string, Row>();
const seeds = new Map<string, { status: "loading" | "ready" | "failed"; keys: string[]; at: number }>();
const failedAt = new Map<string, number>();
/** For rows that start from videos already shown: which answer they started from. */
const origins = new Map<string, string>();

let version = 0;
const listeners = new Set<() => void>();
function changed() {
  version++;
  for (const listener of listeners) listener();
}
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const currentVersion = () => version;

function update(key: string, change: (row: Row) => Row) {
  const row = rows.get(key);
  if (!row) return;
  rows.set(key, change(row));
  changed();
}

/** Asks for the next page of a row, unless it is at its end, on its way, or failed just now. */
export function loadMore(key: string, skips = 0) {
  const row = rows.get(key);
  if (!row || row.loading || row.next === null) return;
  if (row.failed && Date.now() - (failedAt.get(key) ?? 0) < RETRY_MS) return;
  update(key, (r) => ({ ...r, loading: true }));
  const page = row.next ? `&page=${encodeURIComponent(row.next)}` : "";
  api(`/api/youtube/row?key=${encodeURIComponent(key)}${page}`, { schema: RowPage }).then(
    (answer) => {
      let added = 0;
      update(key, (r) => {
        const have = new Set(r.videos.map((v) => v.id));
        const fresh = answer.videos.filter((v) => !have.has(v.id) && have.add(v.id));
        added = fresh.length;
        return { ...r, videos: [...r.videos, ...fresh], next: answer.next, loading: false, failed: false };
      });
      if (added === 0 && answer.next !== null && skips < MAX_SKIPS) loadMore(key, skips + 1);
    },
    () => {
      failedAt.set(key, Date.now());
      update(key, (r) => ({ ...r, loading: false, failed: true }));
    },
  );
}

/** Loads the rows that follow a video, once (again after an hour, or after a failure). */
function loadSeed(id: string) {
  const known = seeds.get(id);
  const age = Date.now() - (known?.at ?? 0);
  if (known && (known.status === "loading" || (known.status === "ready" && age < SEED_TTL_MS) || (known.status === "failed" && age < RETRY_MS))) return;
  seeds.set(id, { status: "loading", keys: known?.keys ?? [], at: Date.now() });
  changed();
  api(`/api/youtube/rows?seed=${encodeURIComponent(id)}`, { schema: VideoRows }).then(
    (answer) => {
      for (const r of answer.rows) {
        // A row already grown keeps its pages.
        const have = rows.get(r.key);
        if (!have || have.videos.length <= r.videos.length) rows.set(r.key, { ...r, loading: false, failed: false });
      }
      seeds.set(id, { status: "ready", keys: answer.rows.map((r) => r.key), at: Date.now() });
      changed();
    },
    () => {
      seeds.set(id, { status: "failed", keys: known?.keys ?? [], at: Date.now() });
      changed();
    },
  );
}

/** Loads a row that follows no video (what is popular), from its first page. */
function loadRow(key: string) {
  if (!rows.has(key)) {
    const kind = key.slice(0, key.indexOf(":")) as Row["kind"];
    rows.set(key, { key, kind, subject: key.slice(key.indexOf(":") + 1), videos: [], next: "", loading: false, failed: false });
  }
  loadMore(key);
}

/** The videos a row holds now, for what the display numbers (Meta AI's "play number 14"). */
export const rowVideos = (key: string): VideoItem[] | undefined => rows.get(key)?.videos;

/**
 * A row that starts from videos already shown (a search answer: its first
 * results), then grows from the API. A new answer for the same row starts it
 * again. Null for no row.
 */
export function useRow(start: (Omit<Row, "loading" | "failed"> & { origin: string }) | null): Row | null {
  useSyncExternalStore(subscribe, currentVersion);
  const key = start?.key ?? "";
  const origin = start?.origin ?? "";
  useEffect(() => {
    if (!start || (origins.get(key) === origin && rows.has(key))) return;
    origins.set(key, origin);
    rows.set(key, { key, kind: start.kind, subject: start.subject, videos: start.videos, next: start.next, loading: false, failed: false });
    changed();
    // One origin is one answer: its videos do not change.
  }, [key, origin]);
  if (!start) return null;
  const stored = origins.get(key) === origin ? rows.get(key) : undefined;
  return stored ?? { key, kind: start.kind, subject: start.subject, videos: start.videos, next: start.next, loading: false, failed: false };
}

/** Videos played lately that recommendations follow, at most this many. */
const MAX_SEEDS = 8;

/**
 * Where recommendations come from, in order: the video playing, if any, then
 * those watched last, then what is popular now.
 */
export function feedSources(history: readonly { id: string; title: string }[], playing?: { id: string; title: string }): FeedSource[] {
  const seeds = playing ? [playing, ...history.filter((h) => h.id !== playing.id)] : [...history];
  return [...seeds.slice(0, MAX_SEEDS).map((v): FeedSource => ({ seed: v.id, title: v.title })), { row: "popular:all" }];
}

const sourceId = (s: FeedSource) => ("seed" in s ? `seed:${s.seed}` : `row:${s.row}`);

/**
 * A feed: rows from each source in turn, the first source's at once, the
 * next ones as `more` is called (the wearer nearing the last rows). A row
 * two sources share shows once. Starts again when the first source changes.
 */
export function useFeed(sources: readonly FeedSource[]) {
  useSyncExternalStore(subscribe, currentVersion);
  const first = sources[0] ? sourceId(sources[0]) : "";
  const [depth, setDepth] = useState({ first, count: 1 });
  if (depth.first !== first) setDepth({ first, count: 1 });
  const count = depth.first === first ? depth.count : 1;
  const active = sources.slice(0, count);
  const activeIds = active.map(sourceId).join("\n");

  useEffect(() => {
    for (const s of active) {
      if ("seed" in s) loadSeed(s.seed);
      else loadRow(s.row);
    }
    // Runs again as answers come, to retry what failed once the wait is over.
  }, [activeIds, version]);

  const entries: FeedEntry[] = [];
  const seen = new Set<string>();
  active.forEach((source, from) => {
    const keys = "seed" in source ? (seeds.get(source.seed)?.keys ?? []) : [source.row];
    for (const key of keys) {
      const row = rows.get(key);
      if (seen.has(key) || !row || row.videos.length === 0) continue;
      seen.add(key);
      entries.push({ row, source, from });
    }
  });
  // A source not asked for yet counts as on its way: the first render comes before its request.
  const loading = active.some((s) => {
    if ("seed" in s) return (seeds.get(s.seed)?.status ?? "loading") === "loading";
    const row = rows.get(s.row);
    return !row || row.loading || (row.next === "" && !row.failed);
  });
  const done = count >= sources.length;

  const more = useCallback(() => {
    setDepth((d) => (d.first === first && d.count < sources.length ? { first, count: d.count + 1 } : d));
  }, [first, sources.length]);

  // Keep a few rows on screen: a source that brings none moves on to the next.
  useEffect(() => {
    if (!loading && !done && entries.length < MIN_ROWS) more();
  }, [loading, done, entries.length, more]);

  return { entries, more, loading, done };
}

export type Feed = ReturnType<typeof useFeed>;
