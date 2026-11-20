/**
 * Directional focus.
 *
 * The glasses' browser moves focus between controls itself when the Neural
 * Band or the touchpad sends an arrow key. Desktop Chrome does not, so this
 * fallback moves focus only when an arrow key left it where it was. On the
 * glasses it should never have to act.
 */

export type Direction = "up" | "down" | "left" | "right";

export interface Box {
  x: number;
  y: number;
  width: number;
  height: number;
}

const VECTORS: Record<Direction, [number, number]> = {
  up: [0, -1],
  down: [0, 1],
  left: [-1, 0],
  right: [1, 0],
};

/** Picks the candidate closest in the given direction, favouring alignment. */
export function pickNext(from: Box, candidates: Box[], dir: Direction): number {
  const [dx, dy] = VECTORS[dir];
  const ax = from.x + from.width / 2;
  const ay = from.y + from.height / 2;
  let best = -1;
  let bestScore = Infinity;
  candidates.forEach((c, i) => {
    const vx = c.x + c.width / 2 - ax;
    const vy = c.y + c.height / 2 - ay;
    const along = vx * dx + vy * dy;
    if (along <= 4) return;
    const across = Math.abs(vx * dy) + Math.abs(vy * dx);
    const score = along + across * 2.5;
    if (score < bestScore) {
      bestScore = score;
      best = i;
    }
  });
  return best;
}

const KEYS: Record<string, Direction> = {
  ArrowUp: "up",
  ArrowDown: "down",
  ArrowLeft: "left",
  ArrowRight: "right",
};

const FOCUSABLE = "button:not([disabled]):not([tabindex='-1']), input:not([disabled]), [tabindex='0']";

export function installFocusFallback(root: HTMLElement): () => void {
  const onKey = (e: KeyboardEvent) => {
    const dir = KEYS[e.key];
    // A screen that handles the key itself prevents its default.
    if (!dir || e.defaultPrevented) return;
    const before = document.activeElement;
    // Left and right move the caret inside a text field that has text.
    if (before instanceof HTMLInputElement && (dir === "left" || dir === "right") && before.value) return;
    setTimeout(() => {
      if (document.activeElement !== before) return;
      const pool = [...root.querySelectorAll<HTMLElement>(FOCUSABLE)].filter(
        (el) => el !== before && el.offsetParent !== null,
      );
      if (!(before instanceof HTMLElement) || before === document.body) {
        pool[0]?.focus();
        return;
      }
      const rect = (el: Element): Box => {
        const r = el.getBoundingClientRect();
        return { x: r.left, y: r.top, width: r.width, height: r.height };
      };
      const i = pickNext(rect(before), pool.map(rect), dir);
      const next = pool[i];
      if (next) {
        next.focus();
        next.scrollIntoView({ block: "nearest" });
      }
    }, 0);
  };
  addEventListener("keydown", onKey);
  return () => removeEventListener("keydown", onKey);
}
