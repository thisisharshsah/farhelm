/**
 * Finds the best icon a website publishes for itself, the way a browser
 * picks a bookmark icon: Apple touch icons and large declared sizes first,
 * then the conventional /apple-touch-icon.png, then Google's favicon
 * service. Answers with a redirect, so the glasses load the image straight
 * from its source and this function stays tiny and cacheable.
 *
 * Fetches only public https pages, reads at most the start of the HTML, and
 * follows standard Fetch semantics so it runs at the edge, in dev and in tests.
 * The host check cannot see where a name resolves or redirects: at the edge
 * Cloudflare does not reach private networks, but in `pnpm dev` it runs on the
 * Mac, so the dev server is for development only.
 */

const PAGE_TIMEOUT_MS = 5000;
const MAX_HTML_BYTES = 256 * 1024;
export const ICON_TTL_SECONDS = 86_400;

/** Public https sites only: no IP literals, localhost or single-label hosts. */
export function publicHttpsUrl(raw: string | null): URL | null {
  if (!raw) return null;
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  const host = url.hostname.toLowerCase();
  if (url.protocol !== "https:" || url.username || url.password) return null;
  if (!host.includes(".") || host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local")) return null;
  if (/^[\d.]+$/.test(host) || host.startsWith("[")) return null; // IPv4 or IPv6 literal
  return url;
}

interface Candidate {
  href: string;
  score: number;
}

const attr = (tag: string, name: string): string | null => {
  const m = new RegExp(`\\s${name}\\s*=\\s*("([^"]*)"|'([^']*)'|([^\\s>]+))`, "i").exec(tag);
  return m ? (m[2] ?? m[3] ?? m[4] ?? "") : null;
};

/**
 * What the icon will sit on. "tile" (the default) wants a full-bleed square
 * such as an Apple touch icon. "glyph" wants the brand's mark on transparency,
 * to centre on Lens's own dark tile, so touch icons, which bring their own
 * (often white) background, come last.
 */
export type IconFit = "tile" | "glyph";

/** Ranks the icons declared in a page's <head>. Returns absolute https URLs, best first. */
export function iconCandidates(html: string, base: URL, fit: IconFit = "tile"): string[] {
  const end = html.search(/<\/head>/i);
  const head = end >= 0 ? html.slice(0, end) : html;
  const found: Candidate[] = [];
  for (const [tag] of head.matchAll(/<link\b[^>]*>/gi)) {
    const rel = (attr(tag, "rel") ?? "").toLowerCase().split(/\s+/);
    if (!rel.some((r) => r === "icon" || r === "apple-touch-icon" || r === "apple-touch-icon-precomposed")) continue;
    const href = attr(tag, "href");
    if (!href) continue;
    let abs: URL;
    try {
      abs = new URL(href.replace(/&amp;/g, "&"), base);
    } catch {
      continue;
    }
    if (abs.protocol !== "https:") continue;
    const type = (attr(tag, "type") ?? "").toLowerCase();
    const sizes = (attr(tag, "sizes") ?? "").toLowerCase();
    const largest = Math.max(0, ...[...sizes.matchAll(/(\d+)x\d+/g)].map((m) => Number(m[1])));
    const svg = type.includes("svg") || abs.pathname.endsWith(".svg") || sizes === "any";
    const apple = rel.some((r) => r.startsWith("apple-touch-icon"));
    // Bigger is sharper on the card; Apple icons are made to sit in a rounded tile.
    let score = svg ? 400 : largest || (apple ? 180 : 32);
    if (apple) score += fit === "glyph" ? -1000 : 60;
    if (abs.pathname.endsWith(".ico")) score -= 20;
    found.push({ href: abs.href, score });
  }
  found.sort((a, b) => b.score - a.score);
  return [...new Set(found.map((c) => c.href))];
}

async function readStart(res: Response, limit: number): Promise<string> {
  if (!res.body) return "";
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let text = "";
  let bytes = 0;
  while (bytes < limit) {
    const { done, value } = await reader.read();
    if (done) break;
    bytes += value.byteLength;
    text += decoder.decode(value, { stream: true });
    if (/<\/head>/i.test(text)) break;
  }
  await reader.cancel().catch(() => {});
  return text;
}

export const googleFavicon = (host: string) =>
  `https://www.google.com/s2/favicons?domain=${encodeURIComponent(host)}&sz=256`;

/** Resolves the best icon URL for a site. Never throws: the last resort is Google's service. */
export async function resolveIcon(site: URL, fetchImpl: typeof fetch = fetch, fit: IconFit = "tile"): Promise<string> {
  const signal = AbortSignal.timeout(PAGE_TIMEOUT_MS);
  try {
    const page = await fetchImpl(site.origin + "/", {
      signal,
      redirect: "follow",
      headers: { accept: "text/html", "user-agent": "Mozilla/5.0 (compatible; GlassesIconBot/1.0)" },
    });
    if (page.ok && (page.headers.get("content-type") ?? "").includes("html")) {
      const base = new URL(page.url || site.origin);
      const best = iconCandidates(await readStart(page, MAX_HTML_BYTES), base, fit)[0];
      if (best) return best;
    }
  } catch {
    // Unreachable or slow: try the conventional location next.
  }
  // A touch icon brings its own background, which a glyph does not want.
  if (fit === "glyph") return googleFavicon(site.hostname);
  try {
    const touch = new URL("/apple-touch-icon.png", site.origin);
    const res = await fetchImpl(touch, { method: "HEAD", signal: AbortSignal.timeout(PAGE_TIMEOUT_MS) });
    if (res.ok && (res.headers.get("content-type") ?? "").startsWith("image/")) return touch.href;
  } catch {
    // Fall through.
  }
  return googleFavicon(site.hostname);
}

/** `fit=glyph` asks for the mark alone; anything else means a full tile. */
export const fitOf = (raw: string | null): IconFit => (raw === "glyph" ? "glyph" : "tile");

/** The whole request: validate, resolve, redirect. */
export async function iconResponse(request: Request, fetchImpl: typeof fetch = fetch): Promise<Response> {
  const params = new URL(request.url).searchParams;
  const site = publicHttpsUrl(params.get("url"));
  if (!site) return new Response("Give a public https address.", { status: 400 });
  const location = await resolveIcon(site, fetchImpl, fitOf(params.get("fit")));
  return new Response(null, {
    status: 302,
    headers: { location, "cache-control": `public, max-age=${ICON_TTL_SECONDS}` },
  });
}
