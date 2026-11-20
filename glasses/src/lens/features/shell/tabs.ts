/**
 * The apps on the bottom bar: Lens's own, then the websites the account
 * added (stored by the API, so every pair of glasses shows the same), then
 * the add button. A tab's id is what the router remembers.
 */
import type { WebApp } from "../../../shared/api.ts";

export type BuiltInId = "youtube" | "companion" | "notes" | "timer";

export type Tab =
  | { kind: "builtin"; id: BuiltInId; name: string; iconSite?: string }
  | { kind: "web"; id: string; name: string; url: string; appId: string }
  | { kind: "add"; id: "add"; name: string };

/** Where YouTube publishes its own icon; Lens shows that, never a drawing of it. */
export const YOUTUBE_SITE = "https://www.youtube.com";

export const BUILT_INS: Tab[] = [
  { kind: "builtin", id: "youtube", name: "YouTube", iconSite: YOUTUBE_SITE },
  { kind: "builtin", id: "companion", name: "Companion" },
  { kind: "builtin", id: "notes", name: "Notes" },
  { kind: "builtin", id: "timer", name: "Timer" },
];

export const ADD_TAB: Tab = { kind: "add", id: "add", name: "Add app" };

export const siteTabId = (appId: string) => `site:${appId}`;

export function tabsFor(web: WebApp[]): Tab[] {
  return [
    ...BUILT_INS,
    ...web.map((w): Tab => ({ kind: "web", id: siteTabId(w.id), name: w.name, url: w.url, appId: w.id })),
    ADD_TAB,
  ];
}

/** The icon address for a site, through our resolver; `glyph` asks for the mark alone, for a dark tile. */
export const iconUrl = (site: string, fit: "tile" | "glyph" = "tile"): string =>
  `/api/icon?url=${encodeURIComponent(new URL(site).origin)}${fit === "glyph" ? "&fit=glyph" : ""}`;
