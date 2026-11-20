import { CircleUserRoundIcon, FlameIcon, ListVideoIcon, LoaderCircleIcon, SparklesIcon } from "lucide-react";
import type { FocusEvent, ReactNode } from "react";
import type { VideoItem } from "../../../shared/api.ts";
import type { Feed as FeedState, FeedEntry } from "./rows.ts";
import { RowShelf } from "./Shelf.tsx";

/** How near the last row, in rows, the next ones are asked for. */
const AHEAD = 2;

interface FeedProps {
  feed: FeedState;
  /** On YouTube the first row is "For you"; in the player it is "Up next". */
  place: "youtube" | "player";
  skip?: ReadonlySet<string>;
  card: (video: VideoItem, index: number, entry: FeedEntry) => ReactNode;
}

function labelOf({ row, source, from }: FeedEntry, place: FeedProps["place"]): { label: string; icon: ReactNode; note?: string } {
  const watched = "seed" in source ? source.title : "";
  switch (row.kind) {
    case "related":
      if (from > 0) return { label: `Because you watched ${watched}`, icon: <SparklesIcon size={18} /> };
      return place === "player"
        ? { label: "Up next", icon: <ListVideoIcon size={18} />, note: `More like ${row.subject}` }
        : { label: "For you", icon: <SparklesIcon size={18} />, note: watched ? `After ${watched}` : undefined };
    case "channel":
      return { label: `More from ${row.subject}`, icon: <CircleUserRoundIcon size={18} /> };
    case "popular":
      return { label: row.subject === "all" ? "Popular now" : `Popular in ${row.subject}`, icon: <FlameIcon size={18} /> };
    case "search":
      return { label: row.subject, icon: <SparklesIcon size={18} /> };
  }
}

/**
 * Recommendations as YouTube on a TV lays them out: rows that each grow as
 * the wearer moves along them, and more rows (because you watched, more from
 * a channel, popular now) as the wearer nears the last ones.
 */
export function Feed({ feed, place, skip, card }: FeedProps) {
  const onFocus = (event: FocusEvent<HTMLDivElement>) => {
    const shelves = [...event.currentTarget.querySelectorAll(":scope > .shelf")];
    const at = shelves.indexOf((event.target as Element).closest(".shelf") as Element);
    if (at >= 0 && at >= shelves.length - AHEAD) feed.more();
  };
  return (
    <div className="feed" onFocus={onFocus}>
      {feed.entries.map((entry) => (
        <RowShelf key={entry.row.key} row={entry.row} skip={skip} card={(v, i) => card(v, i, entry)} {...labelOf(entry, place)} />
      ))}
      {feed.loading ? (
        <p className="working" role="status">
          <LoaderCircleIcon size={20} className="spin" /> {feed.entries.length ? "Finding more for you…" : "Finding videos for you…"}
        </p>
      ) : null}
    </div>
  );
}
