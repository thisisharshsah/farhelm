/**
 * The visualisation layer.
 *
 * Forms were chosen by the job each number does, not by variety:
 *  - spend / cache-hit / calls  → stat tiles. One number is not a chart.
 *  - spend over time            → sparkline, one series, so no legend box.
 *  - spend by tier              → bars on an *ordinal* ramp; tiers are an
 *                                 ordered category (cheap → expensive), so a
 *                                 single-hue light→dark ramp is the encoding,
 *                                 not categorical hues.
 *  - budget                     → a meter with a status colour, always paired
 *                                 with a word so hue is never the only signal.
 *
 * Every chart here is direct-labelled and has a table view, so no value is
 * reachable only by hovering.
 */

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { BudgetView, SpendBucket, TierSlice } from "@relayforge/client-core";
import { TIER_TOKEN, clockTime, pct, usd } from "@relayforge/client-core";

/* --------------------------------------------------------------- stat tile */

export function StatTile({
  label,
  value,
  note,
}: {
  label: string;
  value: string;
  note?: string;
}) {
  return (
    <div className="tile">
      <div className="tile-label">{label}</div>
      <div className="tile-value">{value}</div>
      {note ? <div className="tile-note">{note}</div> : null}
    </div>
  );
}

/* ------------------------------------------------------------------- meter */

const BUDGET_COPY: Record<BudgetView["state"], { glyph: string; word: string }> = {
  ok: { glyph: "●", word: "within budget" },
  warn: { glyph: "▲", word: "80% of cap" },
  stop: { glyph: "■", word: "cap reached" },
};

export function BudgetMeter({
  budget,
  compact = false,
}: {
  budget: BudgetView;
  compact?: boolean;
}) {
  if (budget.cap_usd == null) {
    return (
      <div className="meter-caption">
        <span className="muted">No cap</span>
        <span className="spacer" />
        <span>{usd(budget.spent_usd)} spent</span>
      </div>
    );
  }

  const fraction = Math.max(0, Math.min(1, budget.pct ?? 0));
  const copy = BUDGET_COPY[budget.state];

  return (
    <div>
      <div
        className="meter"
        role="meter"
        aria-valuenow={Math.round(fraction * 100)}
        aria-valuemin={0}
        aria-valuemax={100}
        aria-label={`Budget used: ${pct(fraction)} — ${copy.word}`}
      >
        <div
          className="meter-fill"
          data-state={budget.state}
          style={{ width: `${fraction * 100}%` }}
        />
      </div>
      <div className="meter-caption">
        <span aria-hidden="true">{copy.glyph}</span>
        <span>
          {usd(budget.spent_usd)} of {usd(budget.cap_usd)}
        </span>
        <span className="spacer" />
        <span>{compact ? pct(fraction) : `${pct(fraction)} · ${copy.word}`}</span>
      </div>
    </div>
  );
}

/* -------------------------------------------------------------- tier bars */

export function TierBars({ slices }: { slices: TierSlice[] }) {
  const [hovered, setHovered] = useState<string | null>(null);

  if (slices.length === 0) {
    return <p className="empty">No spend recorded yet.</p>;
  }

  const max = Math.max(...slices.map((slice) => slice.share), 0.0001);

  return (
    <div className="bars">
      {slices.map((slice) => (
        <div
          key={slice.tier}
          className="bar-row"
          onPointerEnter={() => setHovered(slice.tier)}
          onPointerLeave={() => setHovered(null)}
          onFocus={() => setHovered(slice.tier)}
          onBlur={() => setHovered(null)}
          tabIndex={0}
          title={`${slice.tier}: ${usd(slice.usd)} (${pct(slice.share)})`}
        >
          <span className="bar-label">{slice.tier}</span>
          <span className="bar-track">
            <span
              className="bar-fill"
              style={{
                width: `${(slice.share / max) * 100}%`,
                background: TIER_TOKEN[slice.tier] ?? "var(--tier-large)",
                opacity: hovered && hovered !== slice.tier ? 0.55 : 1,
              }}
            />
          </span>
          {/* Direct label: the value is never hover-only. */}
          <span className="bar-value">
            {pct(slice.share)} · {usd(slice.usd)}
          </span>
        </div>
      ))}
    </div>
  );
}

/* --------------------------------------------------------------- sparkline */

/** Container width in CSS pixels, so stroke widths stay honest under scaling. */
function useWidth<T extends HTMLElement>() {
  const ref = useRef<T | null>(null);
  const [width, setWidth] = useState(0);

  useLayoutEffect(() => {
    const node = ref.current;
    if (!node) return;
    const observer = new ResizeObserver(([entry]) => {
      if (entry) setWidth(entry.contentRect.width);
    });
    observer.observe(node);
    setWidth(node.getBoundingClientRect().width);
    return () => observer.disconnect();
  }, []);

  return [ref, width] as const;
}

const PLOT_HEIGHT = 64;
const AXIS_BAND = 18;
const PAD_X = 6;

export function Sparkline({ series }: { series: SpendBucket[] }) {
  const [wrapRef, width] = useWidth<HTMLDivElement>();
  const [active, setActive] = useState<number | null>(null);

  useEffect(() => {
    setActive(null);
  }, [series]);

  if (series.length === 0) {
    return <p className="empty">No spend in this window.</p>;
  }

  if (series.length === 1) {
    // A one-point line is not a chart — say the number instead.
    const only = series[0]!;
    return (
      <div className="tile-note">
        {usd(only.usd)} at {clockTime(only.at_ms)} — a single data point so far.
      </div>
    );
  }

  const innerWidth = Math.max(0, width - PAD_X * 2);
  const max = Math.max(...series.map((bucket) => bucket.usd));
  const scaleY = (usdValue: number) =>
    PLOT_HEIGHT - 4 - (max > 0 ? (usdValue / max) * (PLOT_HEIGHT - 12) : 0);
  const scaleX = (index: number) =>
    PAD_X + (innerWidth * index) / (series.length - 1);

  const points = series.map((bucket, index) => ({
    x: scaleX(index),
    y: scaleY(bucket.usd),
    bucket,
  }));
  const path = points
    .map((point, index) => `${index === 0 ? "M" : "L"}${point.x} ${point.y}`)
    .join(" ");

  const last = points[points.length - 1]!;
  const hovered = active == null ? null : points[active];

  const onPointerMove = (event: React.PointerEvent<SVGSVGElement>) => {
    const bounds = event.currentTarget.getBoundingClientRect();
    const x = event.clientX - bounds.left;
    // Nearest point rather than exact hit: the marks are 8px, the finger is not.
    let nearest = 0;
    let best = Infinity;
    points.forEach((point, index) => {
      const distance = Math.abs(point.x - x);
      if (distance < best) {
        best = distance;
        nearest = index;
      }
    });
    setActive(nearest);
  };

  return (
    <div className="chart-wrap" ref={wrapRef}>
      <svg
        className="sparkline"
        height={PLOT_HEIGHT + AXIS_BAND}
        width={width || undefined}
        viewBox={width ? `0 0 ${width} ${PLOT_HEIGHT + AXIS_BAND}` : undefined}
        role="img"
        aria-label={`Spend per hour, ${series.length} points, peak ${usd(max)}`}
        onPointerMove={onPointerMove}
        onPointerLeave={() => setActive(null)}
      >
        {/* Baseline: a solid hairline, one shade off the surface. */}
        <line
          x1={0}
          y1={PLOT_HEIGHT - 3}
          x2={width}
          y2={PLOT_HEIGHT - 3}
          stroke="var(--baseline)"
          strokeWidth={1}
        />
        <path
          d={path}
          fill="none"
          stroke="var(--series-1)"
          strokeWidth={2}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        {hovered ? (
          <>
            <line
              x1={hovered.x}
              y1={2}
              x2={hovered.x}
              y2={PLOT_HEIGHT - 3}
              stroke="var(--gridline)"
              strokeWidth={1}
            />
            <circle
              cx={hovered.x}
              cy={hovered.y}
              r={4}
              fill="var(--series-1)"
              stroke="var(--surface-1)"
              strokeWidth={2}
            />
          </>
        ) : null}
        {/* Endpoint marker + direct label: the latest value without hovering. */}
        <circle
          cx={last.x}
          cy={last.y}
          r={4}
          fill="var(--series-1)"
          stroke="var(--surface-1)"
          strokeWidth={2}
        />
        <text
          x={width - PAD_X}
          y={PLOT_HEIGHT + 12}
          textAnchor="end"
          fontSize={11}
          fill="var(--text-muted)"
        >
          {clockTime(last.bucket.at_ms)}
        </text>
        <text x={PAD_X} y={PLOT_HEIGHT + 12} fontSize={11} fill="var(--text-muted)">
          {clockTime(series[0]!.at_ms)}
        </text>
      </svg>

      {hovered ? (
        <div
          className="tooltip"
          style={{
            left: Math.min(Math.max(hovered.x - 40, 0), Math.max(width - 96, 0)),
            top: -6,
          }}
        >
          {usd(hovered.bucket.usd)} · {clockTime(hovered.bucket.at_ms)}
        </div>
      ) : null}
    </div>
  );
}

/* -------------------------------------------------------------- table view */

export function ValuesTable({
  caption,
  columns,
  rows,
}: {
  caption: string;
  columns: [string, string];
  rows: Array<[string, string]>;
}) {
  return (
    <table className="values">
      <caption className="tile-label" style={{ textAlign: "left", paddingBottom: 4 }}>
        {caption}
      </caption>
      <thead>
        <tr>
          <th scope="col">{columns[0]}</th>
          <th scope="col">{columns[1]}</th>
        </tr>
      </thead>
      <tbody>
        {rows.map(([label, value]) => (
          <tr key={label}>
            <td>{label}</td>
            <td>{value}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
