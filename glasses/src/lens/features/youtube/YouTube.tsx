import { CircleAlertIcon, ClockIcon, HistoryIcon, LoaderCircleIcon, RotateCwIcon, SearchIcon } from "lucide-react";
import { useEffect, useMemo, useRef } from "react";
import type { Chat } from "../../../client/chat.ts";
import type { ChatMessage, HistoryItem, VideoItem } from "../../../shared/api.ts";
import { rowKey } from "../../../shared/youtube.ts";
import { useNow } from "../../lib/useNow.ts";
import { AskBar } from "../../ui/AskBar.tsx";
import { FRESH_MS } from "../sync/effects.ts";
import { Feed } from "./Feed.tsx";
import { watchedPart } from "./history.ts";
import { feedSources, useFeed, useRow } from "./rows.ts";
import { EndlessShelf, RowShelf } from "./Shelf.tsx";
import { VideoCard } from "./VideoCard.tsx";

interface YouTubeProps {
  chat: Chat;
  watch: (video: VideoItem) => void;
  /** Watch history, newest first. */
  history: HistoryItem[];
  voice: boolean;
  numbers: boolean;
}

/** The video last opened from this page, so Back from the player lands on it. */
let lastOpened = "";
/**
 * The newest results this page has shown, across visits: results asked for
 * just now (on the phone) take focus when they arrive, so one pinch plays
 * the first. Undefined until the first visit, which never takes focus.
 */
let seenResults: string | null | undefined;

const latestSearch = (items: ChatMessage[]) => {
  for (let i = items.length - 1; i >= 0; i--) {
    const m = items[i]!;
    if (m.reply.kind === "videos") return { id: m.id, at: m.createdAt, query: m.reply.query, videos: m.reply.videos };
  }
  return null;
};

/** Earlier searches, newest first, for picking again without writing. */
function recentQueries(items: ChatMessage[], skip: string | undefined, max = 8): string[] {
  const seen = new Set(skip ? [skip.toLowerCase()] : []);
  const out: string[] = [];
  for (let i = items.length - 1; i >= 0 && out.length < max; i--) {
    const r = items[i]!.reply;
    if (r.kind !== "videos" || seen.has(r.query.toLowerCase())) continue;
    seen.add(r.query.toLowerCase());
    out.push(r.query);
  }
  return out;
}

/** Whether focus is on the app bar or the top bar: then nothing on the page takes it. */
const onBars = () => Boolean(document.activeElement?.closest(".dock, .topbar"));

/**
 * YouTube on the glasses, laid out as YouTube on a TV: the search bar, the
 * searches made before as a row of words under it, then rows of videos side
 * by side: the latest results, what was watched (each resumes where it was
 * left), and recommendations: For you from the video played last, then more
 * rows (more from its channel, popular in its kind, because you watched
 * others) as the wearer moves down. Every row grows as the wearer moves
 * along it, and every card carries its own details.
 */
export function YouTube({ chat, watch, history, voice, numbers }: YouTubeProps) {
  const rows = useRef<HTMLDivElement>(null);
  const now = useNow(60_000);
  const latest = latestSearch(chat.items);
  const pending = chat.pending.filter((p) => p.scope === "videos").at(-1);
  const recent = recentQueries(chat.items, latest?.query);
  const results = useRow(
    latest
      ? { key: rowKey({ kind: "search", query: latest.query }), kind: "search", subject: latest.query, videos: latest.videos, next: "", origin: latest.id }
      : null,
  );
  const watched = useMemo(() => new Map(history.map((h) => [h.id, h])), [history]);
  const feed = useFeed(feedSources(history));
  // What the rows above already show stays out of the recommendations.
  const shownAbove = useMemo(() => new Set([...(latest?.videos ?? []).map((v) => v.id), ...watched.keys()]), [latest, watched]);

  const search = (text: string) => void chat.send(text, "videos");
  const open = (video: VideoItem) => {
    lastOpened = video.id;
    watch(video);
  };

  // Results asked for just now take focus when they arrive, unless the wearer is on a bar;
  // else Back from a video lands on it.
  const latestId = latest?.id ?? null;
  const latestAt = latest?.at ?? 0;
  useEffect(() => {
    const first = seenResults === undefined;
    const fresh = !first && latestId !== null && latestId !== seenResults && Date.now() - latestAt < FRESH_MS;
    seenResults = latestId;
    const card = fresh
      ? rows.current?.querySelector<HTMLElement>("[data-video]")
      : lastOpened
        ? rows.current?.querySelector<HTMLElement>(`[data-video="${lastOpened}"]`)
        : null;
    lastOpened = "";
    if (!card || onBars()) return;
    card.focus();
    card.scrollIntoView({ block: "nearest", inline: "nearest" });
  }, [latestId, latestAt]);

  const firstRow = results?.videos.length ? "results" : history.length ? "watched" : "feed";
  const card = (v: VideoItem, extra: { index?: number; primary?: boolean } = {}) => {
    const seen = watched.get(v.id);
    return <VideoCard video={v} now={now} watched={seen ? watchedPart(seen) : undefined} {...extra} onClick={() => open(v)} />;
  };

  return (
    <section className="app-page youtube" aria-label="YouTube">
      <AskBar label="Search YouTube" placeholder="Search YouTube" icon={<SearchIcon size={24} />} onSubmit={search} />
      <div className="rows" ref={rows}>
        {recent.length ? (
          <section className="shelf searched" aria-label="Searched">
            <div className="shelf-row">
              {recent.map((q) => (
                <button key={q} className="chip" onClick={() => search(q)}>
                  <HistoryIcon size={16} aria-hidden="true" />
                  {q}
                </button>
              ))}
            </div>
          </section>
        ) : null}

        {pending?.status === "sending" ? (
          <p className="working" role="status">
            <LoaderCircleIcon size={22} className="spin" /> Searching for “{pending.text}”…
          </p>
        ) : pending?.status === "failed" ? (
          <div className="card card-error" role="alert">
            <CircleAlertIcon size={24} className="card-icon" />
            <span className="card-text">
              <strong>{pending.error ?? "Search failed."}</strong>
            </span>
            <button className="chip" onClick={() => chat.retry(pending.clientId)}>
              <RotateCwIcon size={18} /> Retry
            </button>
          </div>
        ) : null}

        {latest && results ? (
          results.videos.length ? (
            <RowShelf
              key={`${results.key}\n${latest.id}`}
              row={results}
              label={latest.query}
              icon={<SearchIcon size={18} />}
              card={(v, i) => card(v, { index: voice && numbers ? i + 1 : undefined, primary: firstRow === "results" && i === 0 })}
            />
          ) : (
            <p className="welcome">No videos for “{latest.query}”. Try other words.</p>
          )
        ) : !pending && !history.length ? (
          <p className="welcome">
            {voice
              ? "Say “Hey Meta, search lofi beats”, select the bar to write it, or type it on your phone."
              : "Select the bar and say or write what to watch, or type it on your phone."}
          </p>
        ) : null}

        {history.length ? (
          <EndlessShelf
            label="Watched"
            icon={<ClockIcon size={18} />}
            note="Resumes where you left off"
            videos={history}
            card={(v, i) => card(v, { primary: firstRow === "watched" && i === 0 })}
          />
        ) : null}

        <Feed
          feed={feed}
          place="youtube"
          skip={shownAbove}
          card={(v, i, entry) => card(v, { primary: firstRow === "feed" && entry === feed.entries[0] && i === 0 })}
        />
      </div>
    </section>
  );
}
