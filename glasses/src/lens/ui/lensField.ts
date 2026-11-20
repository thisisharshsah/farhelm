/*
 * Water at the edge of the glass, as QuantNepal's liquid glass draws it
 * (frontend/src/components/ui/liquidDrop.ts there): a displacement field for
 * an SVG filter on the backdrop. For each pixel, how far to move the point
 * it reads what is behind from.
 *
 * The middle reads straight through. Across the rim, a band `rim` of the
 * radius wide, the read point sweeps outward to `reach` px past the edge, so
 * whatever is just outside shows inside the rim, squeezed, the way the edge
 * of a drop of water bends the light. The sweep only moves outward, so the
 * picture squeezes at the edge but never folds.
 *
 * Capsules and circles (fully round ends), which is every floating control
 * on the glasses.
 */

export interface LensShape {
  /** How much of the radius the bending rim takes, 0 to 1. */
  rim: number;
  /** How far past the edge the rim reads, in px. */
  reach: number;
}

/** The app bar and other wide floating glass. */
export const BAR_LENS: LensShape = { rim: 0.6, reach: 14 };
/** Round controls over the video: a smaller reach for their smaller size. */
export const BUTTON_LENS: LensShape = { rim: 0.55, reach: 9 };

/** How far the field reaches past the shape: enough to read `reach` px out, and a pixel to spare. */
export const lensMargin = (lens: LensShape) => lens.reach + 2;

export interface LensField {
  width: number;
  height: number;
  dx: Float32Array;
  dy: Float32Array;
  /** The largest move, for feDisplacementMap's scale. */
  scale: number;
}

export function lensField(w: number, h: number, lens: LensShape): LensField {
  const margin = lensMargin(lens);
  const width = Math.max(1, Math.round(w + 2 * margin));
  const height = Math.max(1, Math.round(h + 2 * margin));
  const radius = Math.min(w, h) / 2;
  const across = w >= h;
  // Half the capsule's spine: the straight line its round ends are centred on.
  const spine = (across ? w : h) / 2 - radius;
  const band = Math.max(1, lens.rim * radius);
  const inner = radius - band;
  const dx = new Float32Array(width * height);
  const dy = new Float32Array(width * height);
  let peak = 0;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const px = x + 0.5 - width / 2;
      const py = y + 0.5 - height / 2;
      const sx = across ? Math.max(-spine, Math.min(spine, px)) : 0;
      const sy = across ? 0 : Math.max(-spine, Math.min(spine, py));
      const out = Math.hypot(px - sx, py - sy);
      if (out >= radius || out <= inner) continue;
      const t = (out - inner) / band;
      const nx = (px - sx) / out;
      const ny = (py - sy) / out;
      // From the rim's inner edge, reading out to `reach` past the shape.
      const along = inner + (radius + lens.reach - inner) * t;
      const i = y * width + x;
      dx[i] = sx + nx * along - px;
      dy[i] = sy + ny * along - py;
      peak = Math.max(peak, Math.abs(dx[i]!), Math.abs(dy[i]!));
    }
  }
  return { width, height, dx, dy, scale: 2 * peak || 1 };
}

/** The field as RGBA pixels for feDisplacementMap: red the x move, green the y move, 128 for none. */
export function lensPixels(f: LensField): Uint8ClampedArray<ArrayBuffer> {
  const px = new Uint8ClampedArray(f.width * f.height * 4);
  for (let i = 0; i < f.width * f.height; i++) {
    px[i * 4] = 127.5 + (255 * f.dx[i]!) / f.scale;
    px[i * 4 + 1] = 127.5 + (255 * f.dy[i]!) / f.scale;
    px[i * 4 + 2] = 128;
    px[i * 4 + 3] = 255;
  }
  return px;
}
