import { Fragment, useId, useLayoutEffect, useRef, useState, type CSSProperties } from "react";
import { lensField, lensMargin, lensPixels, type LensShape } from "./lensField.ts";

/*
 * LIQUID GLASS, as Companion and QuantNepal draw it: mostly clear, a faint
 * sheen on top, a thin rim that catches the light top left and bottom right,
 * and water at the edge. Where the browser can filter the backdrop through
 * SVG (the glasses' Chromium can), a lens bends whatever passes behind the
 * glass into its rim. Elsewhere it is the same glass without the bend.
 *
 * Put it first inside a positioned, round host:
 *
 *   <nav className="dock liquid"><Glass lens={BAR_LENS} />…</nav>
 */

type LensMap = { href: string; scale: number };

/** Drawn once per size and shape: five buttons of one size share one picture. */
const maps = new Map<string, LensMap | null>();

function lensMap(w: number, h: number, lens: LensShape): LensMap | null {
  const key = `${w}x${h}:${lens.rim}:${lens.reach}`;
  if (maps.has(key)) return maps.get(key) ?? null;
  const field = lensField(w, h, lens);
  const canvas = document.createElement("canvas");
  canvas.width = field.width;
  canvas.height = field.height;
  const ctx = canvas.getContext("2d");
  const map = ctx
    ? (ctx.putImageData(new ImageData(lensPixels(field), field.width, field.height), 0, 0),
      { href: canvas.toDataURL(), scale: field.scale })
    : null;
  maps.set(key, map);
  return map;
}

/** Whether the backdrop can go through an SVG filter here. */
const canBend = () => typeof CSS !== "undefined" && CSS.supports("backdrop-filter", "url(#lens)");

/**
 * How far the lens moves each colour, as water splits light: red the whole
 * way, green and blue a little less, so the rim picks up a faint rainbow.
 */
const DISPERSION = [
  { channel: "r", scale: 1, keep: "1 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 1 0" },
  { channel: "g", scale: 0.92, keep: "0 0 0 0 0  0 1 0 0 0  0 0 0 0 0  0 0 0 1 0" },
  { channel: "b", scale: 0.84, keep: "0 0 0 0 0  0 0 0 0 0  0 0 1 0 0  0 0 0 1 0" },
] as const;

function LensFilter({ id, map, dispersion }: { id: string; map: LensMap; dispersion: boolean }) {
  return (
    <filter id={id} x="0" y="0" width="100%" height="100%" colorInterpolationFilters="sRGB">
      <feImage href={map.href} preserveAspectRatio="none" result="lens" />
      {dispersion ? (
        <>
          {DISPERSION.map(({ channel, scale, keep }) => (
            <Fragment key={channel}>
              <feDisplacementMap
                in="SourceGraphic"
                in2="lens"
                scale={map.scale * scale}
                xChannelSelector="R"
                yChannelSelector="G"
                result={`${channel}-moved`}
              />
              <feColorMatrix in={`${channel}-moved`} type="matrix" values={keep} result={channel} />
            </Fragment>
          ))}
          {/* Each layer holds one colour, so screening them puts the picture back together. */}
          <feBlend in="r" in2="g" mode="screen" result="rg" />
          <feBlend in="rg" in2="b" mode="screen" />
        </>
      ) : (
        <feDisplacementMap in="SourceGraphic" in2="lens" scale={map.scale} xChannelSelector="R" yChannelSelector="G" />
      )}
    </filter>
  );
}

interface GlassProps {
  /** The water at the edge, or none for glass over nothing (the lens would bend black). */
  lens?: LensShape | null;
  /** Split the colours at the rim: costs three passes, so for one big piece of glass. */
  dispersion?: boolean;
  /**
   * What else goes into the backdrop filter: a light frost so words on the glass stay readable. Blur
   * only: Chromium does not clip colour filters on a backdrop to a round shape.
   */
  frost?: string;
}

export function Glass({ lens = null, dispersion = false, frost = "blur(6px)" }: GlassProps) {
  const pane = useRef<HTMLSpanElement>(null);
  const id = `lens-${useId().replace(/[^\w-]/g, "")}`;
  const [map, setMap] = useState<LensMap | null>(null);

  useLayoutEffect(() => {
    const host = pane.current?.parentElement;
    if (!host || !lens || !canBend()) return;
    let drawn = "";
    const draw = () => {
      const w = Math.round(host.clientWidth);
      const h = Math.round(host.clientHeight);
      if (!w || !h || `${w}x${h}` === drawn) return;
      drawn = `${w}x${h}`;
      setMap(lensMap(w, h, lens));
    };
    draw();
    const resize = new ResizeObserver(draw);
    resize.observe(host);
    return () => resize.disconnect();
  }, [lens]);

  const margin = lens ? lensMargin(lens) : 0;
  return (
    <>
      <span
        ref={pane}
        aria-hidden="true"
        className="glass-pane"
        style={
          {
            "--gm": `${margin}px`,
            backdropFilter: map ? `url(#${id}) ${frost}` : frost,
          } as CSSProperties
        }
      />
      <span aria-hidden="true" className="glass-rim" />
      {map && lens ? (
        <svg aria-hidden="true" width="0" height="0" className="glass-svg">
          <LensFilter id={id} map={map} dispersion={dispersion} />
        </svg>
      ) : null}
    </>
  );
}
