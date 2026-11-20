import { useCallback, useEffect, useRef, type KeyboardEvent, type MouseEvent, type PointerEvent } from "react";

/** One press seeks this far. */
export const SKIP_SECONDS = 10;

/**
 * How far one step seeks: 10 seconds for a press; while held, a longer video
 * moves further per step, and the longer the hold, the faster it goes.
 */
export function seekSeconds(heldMs: number, total: number): number {
  if (heldMs === 0) return SKIP_SECONDS;
  const base = Math.min(60, Math.max(SKIP_SECONDS, total / 80));
  return base * (heldMs < 1200 ? 1 : heldMs < 2500 ? 2 : 4);
}

/** A step every this often while held. */
export const HOLD_STEP_MS = 250;
/** A pointer held this long starts repeating. */
const POINTER_HOLD_MS = 450;

/**
 * Press for one step; hold to keep stepping (seeking through a video).
 * `onStep` gets how long the press has lasted, 0 for the first step, so the
 * caller can speed up. Works with a held key (its repeats drive the steps,
 * so a platform that never sends repeats or a key up still gets one clean
 * step and never a runaway hold) and with a held pointer.
 */
export function useHold(onStep: (heldMs: number) => void, onEnd: () => void) {
  const step = useRef(onStep);
  step.current = onStep;
  const end = useRef(onEnd);
  end.current = onEnd;
  const press = useRef<{ since: number; last: number; held: boolean } | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const skipClick = useRef(false);

  const stopTimer = () => {
    if (timer.current) clearInterval(timer.current);
    timer.current = null;
  };

  const begin = () => {
    const now = performance.now();
    press.current = { since: now, last: now, held: false };
    step.current(0);
  };

  const repeat = () => {
    const p = press.current;
    if (!p) return;
    const now = performance.now();
    if (now - p.last < HOLD_STEP_MS) return;
    p.last = now;
    p.held = true;
    step.current(now - p.since);
  };

  const finish = useCallback(() => {
    stopTimer();
    const p = press.current;
    press.current = null;
    if (p?.held) end.current();
  }, []);

  useEffect(() => finish, [finish]);

  const isPress = (e: KeyboardEvent) => e.key === "Enter" || e.key === " ";

  return {
    onKeyDown: (e: KeyboardEvent<HTMLButtonElement>) => {
      if (!isPress(e)) return;
      // Handled here instead of as a click, which could not tell a hold.
      e.preventDefault();
      if (e.repeat && press.current) repeat();
      else if (!e.repeat) {
        finish();
        begin();
      }
    },
    onKeyUp: (e: KeyboardEvent<HTMLButtonElement>) => {
      if (isPress(e)) finish();
    },
    onPointerDown: (e: PointerEvent<HTMLButtonElement>) => {
      if (e.button !== 0) return;
      e.currentTarget.setPointerCapture?.(e.pointerId);
      skipClick.current = true;
      finish();
      begin();
      timer.current = setTimeout(() => {
        timer.current = setInterval(repeat, HOLD_STEP_MS);
        repeat();
      }, POINTER_HOLD_MS);
    },
    onPointerUp: finish,
    onPointerCancel: finish,
    onLostPointerCapture: finish,
    onBlur: finish,
    // A click with no press before it (assistive technology): one step.
    onClick: (e: MouseEvent<HTMLButtonElement>) => {
      if (skipClick.current) {
        skipClick.current = false;
        e.preventDefault();
        return;
      }
      step.current(0);
    },
  };
}
