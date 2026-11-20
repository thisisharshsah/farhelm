import { useEffect, useState } from "react";

export { useNow } from "../../client/useNow.ts";

/** Battery level in percent, or null where the API is missing (only some browsers have it). */
export function useBattery(): { level: number; charging: boolean } | null {
  const [state, setState] = useState<{ level: number; charging: boolean } | null>(null);
  useEffect(() => {
    const nav = navigator as Navigator & {
      getBattery?: () => Promise<EventTarget & { level: number; charging: boolean }>;
    };
    if (!nav.getBattery) return;
    let battery: (EventTarget & { level: number; charging: boolean }) | null = null;
    let live = true;
    const paint = () => battery && setState({ level: Math.round(battery.level * 100), charging: battery.charging });
    nav
      .getBattery()
      .then((b) => {
        if (!live) return;
        battery = b;
        paint();
        b.addEventListener("levelchange", paint);
        b.addEventListener("chargingchange", paint);
      })
      .catch(() => {});
    return () => {
      live = false;
      battery?.removeEventListener("levelchange", paint);
      battery?.removeEventListener("chargingchange", paint);
    };
  }, []);
  return state;
}
