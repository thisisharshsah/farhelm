import { BatteryChargingIcon, BatteryFullIcon, BatteryLowIcon, BatteryMediumIcon, MicIcon } from "lucide-react";
import { useEffect, useLayoutEffect, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import { clockText } from "../../lib/settings.ts";
import { useBattery, useNow } from "../../lib/useNow.ts";
import { Glass } from "../../ui/Glass.tsx";
import { BAR_LENS } from "../../ui/lensField.ts";
import { AppIcon } from "./AppIcon.tsx";
import type { Tab } from "./tabs.ts";

/*
 * The frame that stays put around every app: a top bar (profile, clock,
 * status) and a bar of apps, floating over the app, which runs full screen
 * and scrolls under them. Both are liquid glass: clear, with a sheen and a
 * rim, and the app bar bends what passes under it like water.
 */

interface TopBarProps {
  name: string;
  clock24: boolean;
  /** Meta AI can control Lens ("Hey Meta, …"). */
  voice: boolean;
  profileOpen: boolean;
  onProfile: () => void;
}

export function TopBar({ name, clock24, voice, profileOpen, onProfile }: TopBarProps) {
  const now = useNow(5_000);
  const battery = useBattery();
  const Battery = !battery
    ? null
    : battery.charging
      ? BatteryChargingIcon
      : battery.level > 70
        ? BatteryFullIcon
        : battery.level > 25
          ? BatteryMediumIcon
          : BatteryLowIcon;

  return (
    <header className="topbar">
      <button
        className={`avatar gl${profileOpen ? " on" : ""}`}
        data-profile
        aria-label="Profile and settings"
        aria-expanded={profileOpen}
        onClick={onProfile}
      >
        {name.trim().charAt(0).toUpperCase() || "L"}
      </button>
      <span className="topbar-clock">{clockText(new Date(now), clock24)}</span>
      {voice || battery ? (
        <span className="status gl">
          {voice ? <MicIcon size={20} aria-label="Meta AI voice on" /> : null}
          {battery && Battery ? (
            <span className={`battery${battery.level <= 15 && !battery.charging ? " low" : ""}`}>
              <Battery size={20} aria-hidden="true" />
              {battery.level}%
            </span>
          ) : null}
        </span>
      ) : null}
    </header>
  );
}

interface AppBarProps {
  tabs: Tab[];
  selected: string;
  onSelect: (id: string) => void;
  /** A pinch on the selected app: go into it. */
  onEnter: (tab: Tab) => void;
  /** A swipe up: back into the app, where the wearer was in it. */
  onUp: () => void;
  still: boolean;
}

/** A swipe on the bar keeps focus on it for this long, unless another key comes first. */
const HOLD_FOCUS_MS = 700;

/**
 * The apps, one row of liquid glass. Swipe left or right on the bar to change
 * app; the selected one becomes a drop with its name. A pinch goes into the
 * app; a swipe up goes back to where the wearer was in it, else its main item,
 * rather than to whatever happens to sit just above the bar.
 *
 * Only the selected app is focusable (roving tabindex), so focus coming down
 * from the page always lands on it, never on a neighbour that would switch
 * the app by accident. Left and right are handled here, and focus is held on
 * the bar after them: if anything else takes it before the next key (the
 * glasses' own focus moving too, an app taking focus as it opens), it comes
 * back, so changing app never moves you off the bar.
 */
export function AppBar({ tabs, selected, onSelect, onEnter, onUp, still }: AppBarProps) {
  const bar = useRef<HTMLDivElement>(null);
  const keys = useRef(0);
  const hold = useRef<{ key: number; until: number } | null>(null);

  const selectedEl = () => bar.current?.querySelector<HTMLElement>(".dock-item.on") ?? null;

  // Gives focus back to the bar when it was taken right after a swipe on it.
  const reclaim = useRef(() => {});
  reclaim.current = () => {
    const h = hold.current;
    if (!h || h.key !== keys.current || performance.now() > h.until) return;
    if (bar.current?.contains(document.activeElement)) return;
    selectedEl()?.focus({ preventScroll: true });
  };

  useEffect(() => {
    // Every key press or pointer press, wherever it lands, ends the hold: after it, focus goes where the wearer sent it.
    const count = () => (keys.current += 1);
    const taken = () => reclaim.current();
    document.addEventListener("keydown", count, true);
    document.addEventListener("pointerdown", count, true);
    document.addEventListener("focusin", taken);
    return () => {
      document.removeEventListener("keydown", count, true);
      document.removeEventListener("pointerdown", count, true);
      document.removeEventListener("focusin", taken);
    };
  }, []);

  // Focus follows the selection while it is on the bar, and the drop stays in view.
  useLayoutEffect(() => {
    const el = selectedEl();
    if (!el) return;
    const held = hold.current && hold.current.key === keys.current;
    if ((held || bar.current?.contains(document.activeElement)) && document.activeElement !== el) el.focus({ preventScroll: true });
    el.scrollIntoView({ block: "nearest", inline: "center", behavior: still ? "auto" : "smooth" });
  }, [selected, still]);

  const onKeyDown = (e: KeyboardEvent<HTMLDivElement>) => {
    const step = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0;
    if (!step) {
      hold.current = null;
      if (e.key === "ArrowUp") {
        e.preventDefault();
        onUp();
      }
      return;
    }
    // Handled here: the glasses' own focus must not also move.
    e.preventDefault();
    hold.current = { key: keys.current, until: performance.now() + HOLD_FOCUS_MS };
    const next = tabs[tabs.findIndex((t) => t.id === selected) + step];
    if (next) onSelect(next.id);
    else bump(step);
    // Also after the event and the next frames: some focus moves come late.
    const check = () => reclaim.current();
    requestAnimationFrame(check);
    setTimeout(check, 150);
    setTimeout(check, 450);
  };

  // At either end the bar gives a little, like a rubber band, instead of nothing.
  const bump = (step: number) => {
    const el = bar.current;
    if (!el || still) return;
    el.classList.remove("bump-left", "bump-right");
    void el.offsetWidth;
    el.classList.add(step > 0 ? "bump-right" : "bump-left");
  };

  return (
    <nav className="dock-wrap" aria-label="Apps">
      <div
        ref={bar}
        className="dock liquid"
        role="tablist"
        aria-orientation="horizontal"
        onKeyDown={onKeyDown}
        onAnimationEnd={(e) => e.currentTarget.classList.remove("bump-left", "bump-right")}
      >
        <Glass lens={BAR_LENS} dispersion />
        <div className="dock-track">
          {tabs.map((t) => {
            const on = t.id === selected;
            return (
              <button
                key={t.id}
                data-tab={t.id}
                role="tab"
                aria-selected={on}
                aria-label={t.name}
                tabIndex={on ? 0 : -1}
                className={`dock-item${on ? " on" : ""}${t.kind === "add" ? " add" : ""}`}
                onClick={() => (on ? onEnter(t) : onSelect(t.id))}
              >
                <AppIcon tab={t} />
                <span className="dock-label" aria-hidden="true">
                  {t.kind === "add" ? "Add" : t.name}
                </span>
              </button>
            );
          })}
        </div>
      </div>
    </nav>
  );
}

type From = "none" | "left" | "right" | "top" | "fade";

/**
 * The app in the middle. A new app slides in from the side it was swiped
 * from; the profile drops in from the top bar where it opened.
 */
export function Page({ id, index, children }: { id: string; index: number; children: ReactNode }) {
  const [shown, setShown] = useState<{ id: string; index: number; from: From }>({ id, index, from: "none" });
  if (shown.id !== id) {
    const from: From = id === "profile" ? "top" : shown.id === "profile" ? "fade" : index > shown.index ? "right" : "left";
    setShown({ id, index, from });
  }
  return (
    <div key={id} className={`page from-${shown.from}`}>
      {children}
    </div>
  );
}

/** A short notice above the bar: something went wrong with a request. */
export function Toast({ text, at }: { text: string; at: number }) {
  return (
    <p key={at} className="toast liquid" role="status">
      <Glass lens={BAR_LENS} frost="blur(14px)" />
      <span className="toast-text">{text}</span>
    </p>
  );
}
