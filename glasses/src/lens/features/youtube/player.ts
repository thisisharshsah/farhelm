/**
 * The video on screen, for control that does not come from its own buttons
 * (Meta AI). The player registers itself while it is ready.
 */
import type { VideoItem } from "../../../shared/api.ts";

export interface PlayerControls {
  play(): void;
  pause(): void;
  /** Moves by this many seconds, within the video. */
  skip(seconds: number): void;
  restart(): void;
  /** Plays the first video in Up next; false when there is none. */
  next(): boolean;
  /** Up next, numbered on the display from 1 when numbers are on. */
  queue(): VideoItem[];
  state(): { title: string; playing: boolean; at: number; total: number };
}

let active: PlayerControls | null = null;

export function setActivePlayer(controls: PlayerControls | null): void {
  active = controls;
}

export const activePlayer = (): PlayerControls | null => active;
