import { MessageSquareTextIcon, NotebookPenIcon, PlusIcon, TimerIcon, TvMinimalPlayIcon, type LucideIcon } from "lucide-react";
import { useState, type ReactNode } from "react";
import { iconUrl, type Tab } from "./tabs.ts";

/*
 * App icons for an additive display: black is see-through and every lit
 * pixel glares, so Lens's own apps are tinted glyphs with no tile behind
 * them, and a brand shows its own mark. Only websites keep a light tile:
 * many favicons are dark on transparent and would vanish on black.
 */

/** Lens's own apps, from the same icon set as the console. */
const GLYPHS: Record<string, LucideIcon> = {
  companion: MessageSquareTextIcon,
  notes: NotebookPenIcon,
  timer: TimerIcon,
};

/** First letter in an outline: the fallback when a site's icon cannot load. */
function Letter({ name }: { name: string }) {
  return (
    <span className="icon icon-letter" aria-hidden="true">
      {name.charAt(0).toUpperCase()}
    </span>
  );
}

/** The site's own icon, or its letter if it fails or is too small to look sharp. */
function SiteIcon({ site, name }: { site: string; name: string }) {
  const [failed, setFailed] = useState(false);
  if (failed) return <Letter name={name} />;
  return (
    <span className="icon icon-site" aria-hidden="true">
      <img
        src={iconUrl(site)}
        alt=""
        decoding="async"
        onLoad={(e) => e.currentTarget.naturalWidth < 32 && setFailed(true)}
        onError={() => setFailed(true)}
      />
    </span>
  );
}

/** A brand's own mark, as the brand draws it; a plain glyph if it cannot load, never a drawing of the logo. */
export function BrandIcon({ site, fallback, className = "" }: { site: string; fallback: ReactNode; className?: string }) {
  const [failed, setFailed] = useState(false);
  return (
    <span className={`icon icon-brand ${className}`} aria-hidden="true">
      {failed ? (
        fallback
      ) : (
        <img
          src={iconUrl(site, "glyph")}
          alt=""
          decoding="async"
          onLoad={(e) => e.currentTarget.naturalWidth < 32 && setFailed(true)}
          onError={() => setFailed(true)}
        />
      )}
    </span>
  );
}

export function AppIcon({ tab }: { tab: Tab }) {
  if (tab.kind === "add") {
    return (
      <span className="icon icon-add" aria-hidden="true">
        <PlusIcon strokeWidth={2.2} />
      </span>
    );
  }
  if (tab.kind === "web") return <SiteIcon site={tab.url} name={tab.name} />;
  if (tab.iconSite) return <BrandIcon site={tab.iconSite} fallback={<TvMinimalPlayIcon className="tint-youtube" />} />;
  const Glyph = GLYPHS[tab.id] ?? PlusIcon;
  return (
    <span className={`icon icon-glyph tint-${tab.id}`} aria-hidden="true">
      <Glyph />
    </span>
  );
}
