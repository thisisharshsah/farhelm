/**
 * Website apps on the glasses' app bar: how an address typed by a person becomes
 * a stored app. Shared so the API enforces exactly what the screens accept.
 */

export const MAX_WEB_APPS = 24;

/** Accepts "example.com" or a full https address. Returns null for anything else. */
export function normalizeAppUrl(raw: string): URL | null {
  let text = raw.trim().replace(/\s+/g, "");
  if (!text || text.length > 2048) return null;
  if (!/^[a-z][a-z0-9+.-]*:/i.test(text)) text = `https://${text}`;
  let url: URL;
  try {
    url = new URL(text);
  } catch {
    return null;
  }
  if (url.protocol !== "https:" || url.username || url.password || !url.hostname.includes(".")) return null;
  url.hash = "";
  return url;
}

/** "www.nytimes.com" -> "Nytimes"; "news.ycombinator.com" -> "Ycombinator". */
export function nameFromUrl(url: URL): string {
  const parts = url.hostname.replace(/^www\./, "").split(".");
  const core = parts.length > 2 ? parts[parts.length - 2]! : parts[0]!;
  return core.charAt(0).toUpperCase() + core.slice(1);
}

/** Addresses with a faster built-in screen open that screen instead of the site. */
export function builtInFor(url: URL): "youtube" | null {
  const host = url.hostname.replace(/^(www|m)\./, "");
  return host === "youtube.com" || host === "youtu.be" ? "youtube" : null;
}

/** The stored form of an address: origin and path, without a trailing slash. */
export const appKey = (url: URL): string => url.origin + url.pathname.replace(/\/$/, "");
