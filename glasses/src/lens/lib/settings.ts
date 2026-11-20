/**
 * Settings that belong to this pair of glasses (not the account), kept in
 * localStorage and managed from the profile.
 */
export interface Settings {
  /** 24-hour clock in the top bar. */
  clock24: boolean;
  /** No sliding or springing; changes appear at once. */
  reduceMotion: boolean;
  /** Numbers on results, for "Hey Meta, play number two". */
  numbers: boolean;
  /** Play the next video when one ends. */
  autoplay: boolean;
}

export const SETTINGS_KEY = "glasses.settings.v1";

export const DEFAULT_SETTINGS: Settings = { clock24: false, reduceMotion: false, numbers: true, autoplay: true };

export function isSettings(v: unknown): v is Settings {
  if (typeof v !== "object" || v === null) return false;
  const s = v as Record<string, unknown>;
  return (Object.keys(DEFAULT_SETTINGS) as (keyof Settings)[]).every((k) => typeof s[k] === "boolean");
}

/** "9:41" or "21:41", without AM or PM: the status bar style. */
export function clockText(at: Date, clock24: boolean): string {
  return at.toLocaleTimeString([], { hour: "numeric", minute: "2-digit", hour12: !clock24 }).replace(/\s?[AP]\.?M\.?/i, "");
}
