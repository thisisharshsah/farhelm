/** Compact times for a small display: "now", "4m", "2h", "Tue", "Nov 3". */
export function shortAgo(at: number, now: number): string {
  const s = Math.max(0, Math.round((now - at) / 1000));
  if (s < 45) return "now";
  const m = Math.round(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h}h`;
  const date = new Date(at);
  return h < 24 * 6
    ? date.toLocaleDateString([], { weekday: "short" })
    : date.toLocaleDateString([], { month: "short", day: "numeric" });
}

/** 300000 -> "5 min", 5400000 -> "1 h 30 min", 90000 -> "1 min 30 s". */
export function spokenDuration(ms: number): string {
  const total = Math.round(ms / 1000);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return [h ? `${h} h` : "", m ? `${m} min` : "", s ? `${s} s` : ""].filter(Boolean).join(" ") || "0 s";
}
