/**
 * A countdown kept as an end time rather than a ticking counter, so it stays
 * right while the app is in the background and across reloads.
 */
export interface TimerState {
  durationMs: number;
  /** Time left while paused. */
  remainingMs: number;
  /** Epoch ms the countdown reaches zero, or null when paused. */
  endsAt: number | null;
}

export const PRESET_MINUTES = [1, 5, 10, 25] as const;

export const initialTimer = (minutes = 5): TimerState => ({
  durationMs: minutes * 60_000,
  remainingMs: minutes * 60_000,
  endsAt: null,
});

export const remaining = (t: TimerState, now: number): number =>
  Math.max(0, t.endsAt === null ? t.remainingMs : t.endsAt - now);

export const isRunning = (t: TimerState, now: number): boolean => t.endsAt !== null && t.endsAt > now;

export const isDone = (t: TimerState, now: number): boolean => remaining(t, now) === 0;

export function toggle(t: TimerState, now: number): TimerState {
  if (isDone(t, now)) return reset(t);
  if (t.endsAt !== null) return { ...t, remainingMs: remaining(t, now), endsAt: null };
  return { ...t, endsAt: now + t.remainingMs };
}

/** A timer already running, as one started from the chat. */
export const started = (durationMs: number, now: number): TimerState => ({
  durationMs,
  remainingMs: durationMs,
  endsAt: now + durationMs,
});

export const reset = (t: TimerState, durationMs = t.durationMs): TimerState => ({
  durationMs,
  remainingMs: durationMs,
  endsAt: null,
});

/** 125000 -> "02:05". Rounds up so it shows 00:01 until it is truly done. */
export function formatClock(ms: number): string {
  const s = Math.max(0, Math.ceil(ms / 1000));
  return `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
}

export function isTimerState(v: unknown): v is TimerState {
  if (typeof v !== "object" || v === null) return false;
  const t = v as Record<string, unknown>;
  const ms = (x: unknown) => typeof x === "number" && Number.isFinite(x) && x >= 0;
  return ms(t.durationMs) && ms(t.remainingMs) && (t.endsAt === null || ms(t.endsAt));
}
