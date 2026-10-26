/**
 * One vocabulary for state across every screen.
 *
 * A task and a session have different lifecycles, but a reader scanning the
 * board, the sidebar and the overview should see the same six tones mean the
 * same six things. Each tone is a filled pill with its word inside, so colour
 * is never the only signal; the fills were checked for white-text contrast in
 * both themes (see `--fill-*` in `styles.css`).
 */

import type { SessionStatus, TaskStatus } from "@farhelm/client-core";

export type Tone = "working" | "review" | "done" | "stuck" | "paused" | "idle";

export interface StatusLook {
  label: string;
  tone: Tone;
}

export const TASK_STATUS: Record<TaskStatus, StatusLook> = {
  running: { label: "Working", tone: "working" },
  awaiting_review: { label: "Needs review", tone: "review" },
  applied: { label: "Applied", tone: "done" },
  failed: { label: "Failed", tone: "stuck" },
  rejected: { label: "Rejected", tone: "idle" },
  no_changes: { label: "No changes", tone: "idle" },
  reverted: { label: "Undone", tone: "idle" },
};

export const SESSION_STATUS: Record<SessionStatus, StatusLook> = {
  running: { label: "Working", tone: "working" },
  awaiting_approval: { label: "Needs approval", tone: "review" },
  paused: { label: "Paused", tone: "paused" },
  done: { label: "Complete", tone: "done" },
  dead: { label: "Offline", tone: "idle" },
};

/**
 * Board groups, attention first.
 *
 * The order is also the order of the status bar on the overview, which keeps
 * the red and green segments apart: those two hues are indistinguishable to a
 * deuteranope, so they must never touch.
 */
export const TASK_GROUPS: { id: string; title: string; tone: Tone; statuses: TaskStatus[] }[] = [
  { id: "review", title: "Needs review", tone: "review", statuses: ["awaiting_review"] },
  { id: "working", title: "Working", tone: "working", statuses: ["running"] },
  { id: "applied", title: "Applied", tone: "done", statuses: ["applied"] },
  { id: "closed", title: "Closed", tone: "idle", statuses: ["rejected", "no_changes", "reverted"] },
  { id: "failed", title: "Failed", tone: "stuck", statuses: ["failed"] },
];

export function StatusPill({ look, size = "md" }: { look: StatusLook; size?: "sm" | "md" }) {
  return (
    <span className="status-pill" data-tone={look.tone} data-size={size}>
      {look.label}
    </span>
  );
}

/** A dot for dense lists, always next to text that names the state. */
export function StatusDot({ tone, label }: { tone: Tone; label: string }) {
  return <span className="status-dot" data-tone={tone} role="img" aria-label={label} />;
}

/** "13m 34s", "2h 5m". For how long a task worked, not when. */
export function duration(ms: number): string {
  const seconds = Math.max(0, Math.round(ms / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ${seconds % 60}s`;
  const hours = Math.floor(minutes / 60);
  return `${hours}h ${minutes % 60}m`;
}
