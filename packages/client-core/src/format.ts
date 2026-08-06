/** Money, always in dollars. Sub-dollar spend needs the extra digits to move. */
export function usd(value: number, precise = false): string {
  if (precise || Math.abs(value) < 1) return `$${value.toFixed(4)}`;
  return `$${value.toFixed(2)}`;
}

export function pct(value: number | null | undefined, digits = 0): string {
  if (value == null || Number.isNaN(value)) return "—";
  return `${(value * 100).toFixed(digits)}%`;
}

/** Compact relative time — "2h ago", "just now". */
export function since(atMs: number, now = Date.now()): string {
  const seconds = Math.max(0, Math.round((now - atMs) / 1000));
  if (seconds < 45) return "just now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.round(hours / 24)}d ago`;
}

export function clockTime(atMs: number): string {
  return new Date(atMs).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
  });
}

const STATUS_LABEL: Record<string, string> = {
  running: "Running",
  awaiting_approval: "Awaiting approval",
  paused: "Paused",
  done: "Complete",
  dead: "Offline",
};

export function statusLabel(status: string): string {
  return STATUS_LABEL[status] ?? status;
}

/**
 * Status colour token for a session dot. Always rendered alongside the status
 * word — hue never carries the meaning by itself.
 */
export function statusToken(status: string): string {
  switch (status) {
    case "running":
      return "var(--status-good)";
    case "awaiting_approval":
      return "var(--status-warning)";
    case "paused":
      return "var(--status-serious)";
    case "done":
      return "var(--text-muted)";
    default:
      return "var(--text-muted)";
  }
}

export const TIER_TOKEN: Record<string, string> = {
  small: "var(--tier-small)",
  large: "var(--tier-large)",
  batch: "var(--tier-batch)",
};
