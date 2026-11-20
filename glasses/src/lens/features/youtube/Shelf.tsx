import { LoaderCircleIcon } from "lucide-react";
import { Fragment, useState, type FocusEvent, type ReactNode } from "react";
import type { VideoItem } from "../../../shared/api.ts";
import { useDetails } from "./details.ts";
import { loadMore, type Row } from "./rows.ts";

interface ShelfProps {
  label: string;
  icon?: ReactNode;
  note?: string;
  onFocus?: (event: FocusEvent<HTMLElement>) => void;
  /** The row: cards, or the words of searches. */
  children: ReactNode;
}

/**
 * A row of the YouTube app, as on a TV: a label, then its videos side by side.
 * Left and right move along the row, up and down between rows, all through
 * the glasses' own focus; the row scrolls to keep the focused card in view.
 */
export function Shelf({ label, icon, note, onFocus, children }: ShelfProps) {
  return (
    <section className="shelf" aria-label={label} onFocus={onFocus}>
      <p className="section-label">
        {icon}
        <span className="section-name">{label}</span>
        {note ? <span className="section-note">{note}</span> : null}
      </p>
      <div className="shelf-row">{children}</div>
    </section>
  );
}

/** Cards shown at first, and added each time the wearer nears the end of what shows. */
const STEP = 12;
/** How near the end, in cards, more are added and the next page asked for. */
const AHEAD = 4;

interface EndlessShelfProps extends Omit<ShelfProps, "children" | "onFocus"> {
  videos: readonly VideoItem[];
  /** Asks for more as the wearer nears the end of what there is; absent when there is no more. */
  more?: () => void;
  /** More is on its way. */
  loading?: boolean;
  /** Videos to leave out: the one playing, or those another row already shows. */
  skip?: ReadonlySet<string>;
  card: (video: VideoItem, index: number) => ReactNode;
}

/**
 * A row that never runs out while there is more: cards are added as the
 * wearer nears the end of what shows, and more is asked for before they get
 * there. Videos that came without details get them.
 */
export function EndlessShelf({ videos, more, loading, skip, card, ...label }: EndlessShelfProps) {
  const [shown, setShown] = useState(STEP);
  const all = skip?.size ? videos.filter((v) => !skip.has(v.id)) : videos;
  const visible = useDetails(all.slice(0, shown));

  const onFocus = (event: FocusEvent<HTMLElement>) => {
    const cards = [...event.currentTarget.querySelectorAll("[data-video]")];
    const at = cards.indexOf((event.target as Element).closest("[data-video]") as Element);
    if (at < 0 || at < cards.length - AHEAD) return;
    if (shown < all.length) setShown(shown + STEP);
    if (more && all.length - (shown + STEP) < STEP) more();
  };

  return (
    <Shelf {...label} onFocus={onFocus}>
      {visible.map((v, i) => (
        <Fragment key={v.id}>{card(v, i)}</Fragment>
      ))}
      {loading ? (
        <span className="row-more" role="status" aria-label="Loading more videos">
          <LoaderCircleIcon size={26} className="spin" />
        </span>
      ) : null}
    </Shelf>
  );
}

/** A row from the API (see rows.ts), growing a page at a time. */
export function RowShelf({ row, ...rest }: Omit<EndlessShelfProps, "videos" | "more" | "loading"> & { row: Row }) {
  return <EndlessShelf {...rest} videos={row.videos} loading={row.loading} more={row.next !== null ? () => loadMore(row.key) : undefined} />;
}
