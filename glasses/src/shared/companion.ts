/**
 * Companion's glasses page is served by the Companion app on the Mac, so its
 * link is https or plain http on a private network (LAN, .local, Tailscale).
 * Anything else is refused, so a stored link cannot point the glasses at an
 * arbitrary site.
 */
export function isAllowedCompanionLink(raw: string): boolean {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return false;
  }
  if (url.username || url.password) return false;
  if (url.protocol === "https:") return true;
  if (url.protocol !== "http:") return false;
  const h = url.hostname;
  return (
    /^10\./.test(h) ||
    /^192\.168\./.test(h) ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(h) ||
    /^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./.test(h) || // Tailscale
    h.endsWith(".local") ||
    h.endsWith(".ts.net")
  );
}
