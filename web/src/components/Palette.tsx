/**
 * ⌘K — jump anywhere, do anything.
 *
 * The reason to build one is not that Cursor and Linear have one. It is that
 * this app's navigation is a *tree* — fleet → session → cost, tasks → task —
 * and a tree costs a click per level in each direction. Someone watching four
 * sessions spends most of their clicks going back up. A palette flattens that:
 * every session, every change set and every screen is two keystrokes away from
 * anywhere, including from inside each other.
 *
 * # Matching
 *
 * Subsequence, not substring: `bgt` finds "Billing → budget" the way an editor
 * finds files. Ranking prefers matches that start on a word boundary, so typing
 * `co` puts **co**st above dis**co**nnect, and the run is scored tighter when
 * the matched characters sit close together — the difference between a palette
 * that feels like it read your mind and one you fight.
 *
 * # What it does not do
 *
 * Decide approvals. A palette is a place for fast, reversible motion, and every
 * fast interface eventually gets a stray Enter. Approving a command an agent
 * wants to run on a real machine is neither fast nor reversible, so it stays on
 * a card with its diff visible — the same reason the destructive rule keeps
 * `DecidedVia::Connector` out. Navigating *to* the approval is offered; the
 * decision is made where it can be read.
 */

import { useEffect, useMemo, useRef, useState } from "react";
import { Icon, type IconName } from "./Icon";

export interface Action {
  id: string;
  label: string;
  /** Groups the list and gives each row its second line. */
  hint?: string;
  group: string;
  icon: IconName;
  run: () => void;
}

/* ------------------------------------------------------------------ matching */

interface Scored {
  action: Action;
  score: number;
}

/**
 * Score `query` against `text`, or return null if the characters are not all
 * present in order.
 *
 * Higher is better. The weights matter less than their ordering: a boundary hit
 * must outrank a mid-word hit, and a tight run must outrank a scattered one,
 * because those two rules are what make the first result usually right.
 */
function score(query: string, text: string): number | null {
  const haystack = text.toLowerCase();
  let at = 0;
  let total = 0;
  let previous = -1;

  for (const character of query.toLowerCase()) {
    const found = haystack.indexOf(character, at);
    if (found === -1) return null;

    const boundary =
      found === 0 || /[\s\-–—/·:]/.test(haystack[found - 1] ?? "");
    total += boundary ? 12 : 3;
    // Adjacent characters score better than a match spread across the string.
    if (previous >= 0) total += found === previous + 1 ? 6 : -Math.min(found - previous, 6);

    previous = found;
    at = found + 1;
  }

  // A short label matching everything is a better answer than a long one that
  // happens to contain the same letters.
  return total - text.length * 0.08;
}

export function rank(query: string, actions: Action[]): Action[] {
  const trimmed = query.trim();
  if (!trimmed) return actions;

  const hits: Scored[] = [];
  for (const action of actions) {
    // The hint is searchable too — a repository name is often what someone
    // actually remembers about a session, not the words in its title.
    const direct = score(trimmed, action.label);
    const viaHint = action.hint ? score(trimmed, `${action.label} ${action.hint}`) : null;
    const best =
      direct === null ? viaHint : viaHint === null ? direct : Math.max(direct, viaHint);
    if (best !== null) hits.push({ action, score: best });
  }
  return hits.sort((a, b) => b.score - a.score).map((hit) => hit.action);
}

/* -------------------------------------------------------------------- screen */

export function Palette({
  actions,
  onClose,
}: {
  actions: Action[];
  onClose: () => void;
}) {
  const [query, setQuery] = useState("");
  const [cursor, setCursor] = useState(0);
  const listRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  const results = useMemo(() => rank(query, actions), [query, actions]);
  // Clamped rather than reset, so refining a query keeps the selection near
  // where the eye already is instead of snapping to the top on every keystroke.
  const selected = Math.min(cursor, Math.max(results.length - 1, 0));

  useEffect(() => inputRef.current?.focus(), []);

  // Keep the highlighted row on screen when arrowing past the fold.
  useEffect(() => {
    listRef.current
      ?.querySelector('[aria-selected="true"]')
      ?.scrollIntoView({ block: "nearest" });
  }, [selected, results.length]);

  const onKeyDown = (event: React.KeyboardEvent) => {
    if (event.key === "Escape") {
      event.preventDefault();
      onClose();
      return;
    }
    if (event.key === "ArrowDown" || (event.key === "n" && event.ctrlKey)) {
      event.preventDefault();
      setCursor((value) => (results.length ? (Math.min(value, results.length - 1) + 1) % results.length : 0));
      return;
    }
    if (event.key === "ArrowUp" || (event.key === "p" && event.ctrlKey)) {
      event.preventDefault();
      setCursor((value) =>
        results.length ? (Math.min(value, results.length - 1) + results.length - 1) % results.length : 0,
      );
      return;
    }
    if (event.key === "Enter") {
      event.preventDefault();
      const action = results[selected];
      if (action) {
        // Closed before running: an action that navigates would otherwise
        // unmount this component mid-call and React would warn about it.
        onClose();
        action.run();
      }
    }
  };

  let lastGroup = "";

  return (
    <div
      className="palette-backdrop"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <div
        className="palette"
        role="dialog"
        aria-modal="true"
        aria-label="Search and commands"
        onKeyDown={onKeyDown}
      >
        <div className="palette-field">
          <Icon name="search" size={18} />
          <input
            ref={inputRef}
            value={query}
            placeholder="Search sessions, tasks and commands…"
            onChange={(event) => {
              setQuery(event.target.value);
              setCursor(0);
            }}
            aria-label="Search"
            autoComplete="off"
            spellCheck={false}
          />
          <kbd>esc</kbd>
        </div>

        <div className="palette-results" ref={listRef} role="listbox">
          {results.length === 0 ? (
            <p className="empty">Nothing matches “{query.trim()}”.</p>
          ) : (
            results.map((action, index) => {
              const heading = action.group !== lastGroup ? action.group : null;
              lastGroup = action.group;
              return (
                <div key={action.id}>
                  {heading ? <h3 className="palette-group">{heading}</h3> : null}
                  <div
                    className={`palette-row${index === selected ? " is-selected" : ""}`}
                    role="option"
                    aria-selected={index === selected}
                    // Pointer-down rather than click: the input holds focus, and
                    // a click would blur it first and fight the keyboard path.
                    onMouseDown={(event) => {
                      event.preventDefault();
                      onClose();
                      action.run();
                    }}
                    onMouseMove={() => setCursor(index)}
                  >
                    <Icon name={action.icon} size={16} />
                    <span className="palette-label">{action.label}</span>
                    {action.hint ? (
                      <span className="palette-hint">{action.hint}</span>
                    ) : null}
                  </div>
                </div>
              );
            })
          )}
        </div>
      </div>
    </div>
  );
}
