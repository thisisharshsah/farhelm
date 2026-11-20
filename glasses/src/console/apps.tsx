/**
 * The glasses' app bar as the console shows it: the same apps, in the
 * same order, with the same colours.
 */
import { useState } from "react";
import type { WebApp } from "../shared/api.ts";
import { Link } from "./router.tsx";
import { Icon, Tile, type IconName } from "./ui.tsx";

/** Where YouTube publishes its own icon; Lens shows that, never a drawing of it. */
export const YOUTUBE_SITE = "https://www.youtube.com";

type BuiltIn = { id: string; name: string; detail: string; to?: string } & (
  | { site: string; icon?: never; tone?: never }
  | { site?: never; icon: IconName; tone: string }
);

export const BUILT_INS: BuiltIn[] = [
  { id: "youtube", name: "YouTube", detail: "What your glasses played, to play again", site: YOUTUBE_SITE, to: "/history" },
  { id: "companion", name: "Companion", detail: "The latest reply from your Mac", icon: "companion", tone: "purple" },
  { id: "notes", name: "Notes", detail: "Synced with this console", icon: "note", tone: "yellow", to: "/notes" },
  { id: "timer", name: "Timer", detail: "Kept on each pair of glasses", icon: "timer", tone: "orange" },
];

/** The icon address for a site; `glyph` asks for the mark alone, for a dark tile. */
export const iconFor = (url: string, fit: "tile" | "glyph" = "tile") =>
  `/api/icon?url=${encodeURIComponent(new URL(url).origin)}${fit === "glyph" ? "&fit=glyph" : ""}`;

/**
 * A website's own icon, or a globe when it publishes none. `brand` puts a
 * built-in's icon on a dark tile, like iOS dark icons, with a plain video
 * glyph as its fallback rather than a drawing of the logo.
 */
export function SiteTile({ url, size = "lg", brand }: { url: string; size?: "sm" | "md" | "lg"; brand?: boolean }) {
  const [failed, setFailed] = useState(false);
  if (failed) return brand ? <Tile tone="brand" icon="video" size={size} /> : <Tile tone="gray" icon="globe" size={size} />;
  return (
    <span className={`tile tile-${size} ${brand ? "tile-brand" : "tile-site"}`} aria-hidden="true">
      <img src={iconFor(url, brand ? "glyph" : "tile")} alt="" onError={() => setFailed(true)} onLoad={(e) => e.currentTarget.naturalWidth < 32 && setFailed(true)} />
    </span>
  );
}

/** A built-in screen's tile: its brand's own icon, or Lens's coloured glyph. */
export function BuiltInTile({ app, size = "lg" }: { app: BuiltIn; size?: "sm" | "md" | "lg" }) {
  return app.site ? <SiteTile url={app.site} size={size} brand /> : <Tile tone={app.tone ?? "gray"} icon={app.icon ?? "apps"} size={size} />;
}

export function AppTiles({ apps }: { apps: WebApp[] }) {
  return (
    <ul className="tiles">
      {BUILT_INS.map((b) => (
        <li key={b.id}>
          {b.to ? (
            <Link to={b.to} className="tile-item">
              <BuiltInTile app={b} />
              <span>{b.name}</span>
            </Link>
          ) : (
            <span className="tile-item">
              <BuiltInTile app={b} />
              <span>{b.name}</span>
            </span>
          )}
        </li>
      ))}
      {apps.map((a) => (
        <li key={a.id}>
          <a className="tile-item" href={a.url} target="_blank" rel="noreferrer">
            <SiteTile url={a.url} />
            <span>{a.name}</span>
          </a>
        </li>
      ))}
      <li>
        <Link to="/apps#add" className="tile-item">
          <span className="tile tile-lg tile-add" aria-hidden="true">
            <Icon name="plus" size={24} />
          </span>
          <span>Add</span>
        </Link>
      </li>
    </ul>
  );
}
