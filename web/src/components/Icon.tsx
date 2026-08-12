/**
 * The icon set, as inline SVG.
 *
 * This replaces a row of Unicode glyphs — `⌥ ◈ ☾ ⛓` — that were doing duty as
 * buttons. They were never icons: each one renders in whatever the platform's
 * emoji or symbol font decides, so the same button was a different weight,
 * colour and optical size on macOS, Windows and Android, and two of them fell
 * back to a box on some Linux browsers. Nothing else in an interface gives away
 * that it was assembled quickly quite as fast as inconsistent glyph buttons.
 *
 * Stroked rather than filled, on a 24-unit grid at 1.5 weight, so they sit with
 * text at the same optical density as the type around them. `currentColor`
 * throughout: an icon inherits its colour from whatever it is inside, which is
 * what makes hover, active and disabled states work without a variant per icon.
 *
 * They are deliberately hand-written rather than pulled from a library. There
 * are fourteen, the whole set is under 100 lines, and a dependency here would
 * ship a few thousand paths to render the dozen we use — while also being the
 * one runtime dependency that the strict CSP could not fetch anyway.
 */

export type IconName =
  | "fleet"
  | "tasks"
  | "account"
  | "billing"
  | "machine"
  | "search"
  | "plus"
  | "sun"
  | "moon"
  | "auto"
  | "check"
  | "chevron"
  | "close"
  | "signout"
  | "link";

/** Path data only — the wrapper below supplies every shared attribute. */
const PATHS: Record<IconName, string> = {
  // A stack of running things.
  fleet: "M4 6h16M4 12h16M4 18h10",
  // A change set: a document with a diff mark.
  tasks: "M6 3h8l4 4v14H6zM14 3v4h4M9 13h6M9 17h4",
  account: "M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8M5 20a7 7 0 0 1 14 0",
  billing: "M3 7h18v11H3zM3 11h18M7 15h3",
  machine: "M4 5h16v10H4zM9 19h6M12 15v4",
  search: "M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14M16.5 16.5 21 21",
  plus: "M12 5v14M5 12h14",
  sun: "M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4",
  moon: "M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5",
  // "Follow the system": a display with a half-lit face.
  auto: "M4 5h16v11H4zM8 20h8M12 5v11",
  check: "M5 12.5 10 17.5 19 7",
  chevron: "M9 6l6 6-6 6",
  close: "M6 6l12 12M18 6L6 18",
  signout: "M14 4h4a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1h-4M10 12h9M13 8l-4 4 4 4",
  link: "M10 14a4 4 0 0 0 6 .5l2-2a4 4 0 0 0-6-6l-1 1M14 10a4 4 0 0 0-6-.5l-2 2a4 4 0 0 0 6 6l1-1",
};

export function Icon({
  name,
  size = 18,
  className,
}: {
  name: IconName;
  size?: number;
  className?: string;
}) {
  return (
    <svg
      className={className}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      // The icon is never the accessible name — every caller pairs it with a
      // label or an `aria-label`, so announcing it again would read the same
      // control twice.
      aria-hidden="true"
      focusable="false"
    >
      <path d={PATHS[name]} />
    </svg>
  );
}
