/**
 * What the glasses do when a request arrives through Lens (from the phone,
 * Meta AI or this pair of glasses): play the video, start the timer, show the
 * app, or say what went wrong. There is no chat on the glasses; the request
 * shows as its result. Pure, so the rules are tested apart from the UI.
 */
import type { Arrival } from "../../../client/chat.ts";
import type { ChatMessage, OpenView, VideoItem } from "../../../shared/api.ts";

/** A message is acted on only while fresh, so opening Lens later never replays an old request. */
export const FRESH_MS = 2 * 60_000;

/** An app a request can bring forward; "home" only closes the player or the profile. */
export type ShowTab = "youtube" | "notes" | "timer" | "companion" | "add" | "home";

export type Effect =
  | { type: "watch"; video: VideoItem }
  | { type: "tab"; tab: ShowTab }
  | { type: "url"; url: string }
  | { type: "timer"; durationMs: number }
  | { type: "notice"; text: string };

const TAB_OF: Record<OpenView, ShowTab> = {
  home: "home",
  youtube: "youtube",
  notes: "notes",
  timer: "timer",
  companion: "companion",
  apps: "add",
};

export function effectOf(message: ChatMessage, how: Arrival, now: number): Effect | null {
  if (now - message.createdAt > FRESH_MS) return null;
  // What these glasses asked for is already on screen; a request from elsewhere is brought forward.
  const elsewhere = how !== "sent";
  const reply = message.reply;
  switch (reply.kind) {
    case "videos": {
      const top = reply.videos[0];
      if (reply.autoplay && top) return { type: "watch", video: top };
      return elsewhere ? { type: "tab", tab: "youtube" } : null;
    }
    case "play":
      return { type: "watch", video: reply.video };
    case "timer":
      return { type: "timer", durationMs: reply.durationMs };
    case "note":
      return elsewhere ? { type: "tab", tab: "notes" } : null;
    case "open":
      if (reply.url) return { type: "url", url: reply.url };
      return reply.view ? { type: "tab", tab: TAB_OF[reply.view] } : null;
    case "error":
      // With no chat to show it in, a problem is a short notice, wherever it was asked.
      return { type: "notice", text: reply.message };
    case "help":
      return null;
  }
}

/**
 * Picks the one message to act on from what just arrived, and whether to
 * act at all. `acted` is the last seq acted on, or -1 on a new install,
 * which only records where history ends rather than replaying it.
 */
export function nextToAct(messages: ChatMessage[], how: Arrival, acted: number): { message: ChatMessage | null; acted: number } {
  const newest = messages.reduce<ChatMessage | null>((a, m) => (a === null || m.seq > a.seq ? m : a), null);
  if (!newest || newest.seq <= acted) return { message: null, acted };
  if (acted < 0 && how === "initial") return { message: null, acted: newest.seq };
  return { message: newest, acted: newest.seq };
}
