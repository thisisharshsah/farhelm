/**
 * What a chat message asks for. Lens chat understands a few phrasings (notes,
 * timers, opening apps, playing) and searches YouTube for everything else.
 *
 * Matching is deterministic on purpose: a phrase fits a pattern or it is a
 * search, so the result is predictable and testable. Shared by the API, which
 * acts on the intent, and the clients, which show the same examples.
 */
import { MAX_QUERY_LENGTH } from "./youtube.ts";

export type Intent =
  | { kind: "videos"; query: string; autoplay: boolean }
  | { kind: "note"; text: string }
  | { kind: "timer"; durationMs: number }
  | { kind: "open"; target: string }
  | { kind: "help" }
  | { kind: "unclear"; message: string };

/** "videos" is the YouTube screen's bar: everything there is a search or a play. */
export type IntentScope = "auto" | "videos";

export const MAX_TIMER_MS = 24 * 3_600_000;
export const MAX_NOTE_LENGTH = 500;

/** Example phrasings, shown by the clients as help and suggestions. */
export const EXAMPLES = [
  { text: "lofi beats", hint: "Search YouTube" },
  { text: "play rain sounds", hint: "Play the top video" },
  { text: "note call mom at 6", hint: "Save a note" },
  { text: "timer 10 minutes", hint: "Start a timer" },
  { text: "open notes", hint: "Open an app or website" },
] as const;

/** Dictation adds a full stop and sometimes quotes; neither changes what was meant. */
export function cleanUtterance(raw: string): string {
  return raw
    .replace(/\s+/g, " ")
    .trim()
    .replace(/^["'“”‘’«»]+|["'“”‘’«»]+$/gu, "")
    .replace(/[\s.!?,;:…。！？]+$/u, "")
    .trim();
}

const SMALL: Record<string, number> = {
  zero: 0, one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10,
  eleven: 11, twelve: 12, thirteen: 13, fourteen: 14, fifteen: 15, sixteen: 16, seventeen: 17, eighteen: 18, nineteen: 19,
};
const TENS: Record<string, number> = {
  twenty: 20, thirty: 30, forty: 40, fifty: 50, sixty: 60, seventy: 70, eighty: 80, ninety: 90,
};
const SMALL_WORDS = Object.keys(SMALL).join("|");
const TENS_WORDS = Object.keys(TENS).join("|");

/** Dictation spells small numbers out: "twenty five minutes" -> "25 minutes", "an hour" -> "1 hour". */
export function wordsToNumbers(text: string): string {
  return text
    .toLowerCase()
    .replace(/\b(?:an?\s+|one\s+)?hour\s+and\s+a\s+half\b/g, "90 minutes")
    .replace(/\b(?:one|1)\s+and\s+a\s+half\s+hours?\b/g, "90 minutes")
    .replace(/\bhalf\s+(?:an\s+)?hour\b/g, "30 minutes")
    .replace(new RegExp(`\\b(${TENS_WORDS})[\\s-](${SMALL_WORDS})\\b`, "g"), (_, t: string, o: string) =>
      String(TENS[t]! + SMALL[o]!),
    )
    .replace(new RegExp(`\\b(${SMALL_WORDS}|${TENS_WORDS})\\b`, "g"), (w: string) => String(SMALL[w] ?? TENS[w]))
    .replace(/\ban?\s+(second|minute|hour)\b/g, "1 $1");
}

const UNIT = /(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b/g;

/** "1 hour 30 minutes", "90s", "5:30" or a bare "5" (minutes). Null when there is no duration. */
export function parseDuration(text: string): number | null {
  const t = wordsToNumbers(text);
  let total = 0;
  let found = false;
  for (const m of t.matchAll(UNIT)) {
    const unit = m[2]!;
    total += Number(m[1]) * (unit.startsWith("h") ? 3_600_000 : unit.startsWith("m") ? 60_000 : 1000);
    found = true;
  }
  if (found) return Math.round(total);
  const clock = /\b(\d{1,3}):([0-5]\d)\b/.exec(t);
  if (clock) return (Number(clock[1]) * 60 + Number(clock[2])) * 1000;
  const bare = /\b(\d+(?:\.\d+)?)\b/.exec(t);
  return bare ? Math.round(Number(bare[1]) * 60_000) : null;
}

/** Search text for YouTube: no "on YouTube" tail, at most the API's length, cut at a word. */
export function toQuery(text: string): string {
  const q = text.replace(/\s+on\s+youtube$/i, "").replace(/\s+/g, " ").trim();
  if (q.length <= MAX_QUERY_LENGTH) return q;
  const cut = q.slice(0, MAX_QUERY_LENGTH);
  const space = cut.lastIndexOf(" ");
  return (space > 40 ? cut.slice(0, space) : cut).trim();
}

const HELP = /^(?:help|\?|commands|what can (?:you|i) (?:do|say)|how does (?:this|it) work)$/i;
const TIMER_WORD = /\b(?:timer|countdown)\b/i;
const NOTE =
  /^(?:(?:take|make|add|create|write|new)\s+(?:a\s+)?note|note\s+to\s+self|notes?|write\s+down|jot\s+down|remember\s+(?:that|to))\b[\s:,.-]*/i;
const OPEN = /^(?:open|launch|go\s+to|switch\s+to|show\s+my)\s+(?:the\s+|my\s+)?(.+?)(?:\s+app)?$/i;
const ALONE = /^(?:go\s+)?(home|youtube|companion)$/i;
const PLAY = /^(?:play|watch|put\s+on|stream)\b\s*(.*)$/i;
const SEARCH = /^(?:search(?:\s+youtube)?(?:\s+for)?|find|look\s+up|show\s+me|videos?\s+(?:of|about|on))\b\s*(.*)$/i;

function videos(text: string): Intent {
  const play = PLAY.exec(text);
  if (play) {
    const query = toQuery(play[1] ?? "");
    return query ? { kind: "videos", query, autoplay: true } : { kind: "unclear", message: "Say what to play, like play lofi beats." };
  }
  const search = SEARCH.exec(text);
  const query = toQuery(search ? (search[1] ?? "") : text);
  return query ? { kind: "videos", query, autoplay: false } : { kind: "unclear", message: "Say what to search for." };
}

export function parseIntent(raw: string, scope: IntentScope = "auto"): Intent {
  const text = cleanUtterance(raw);
  if (!text) return { kind: "unclear", message: "Say or write something first." };
  if (scope === "videos") return videos(text);

  if (HELP.test(text)) return { kind: "help" };

  if (TIMER_WORD.test(text)) {
    const ms = parseDuration(text.replace(new RegExp(TIMER_WORD, "gi"), " "));
    if (ms === null) return { kind: "open", target: "timer" };
    if (ms < 1000 || ms > MAX_TIMER_MS) return { kind: "unclear", message: "Timers run from 1 second to 24 hours." };
    return { kind: "timer", durationMs: ms };
  }

  const note = NOTE.exec(text);
  if (note) {
    const body = text.slice(note[0].length).trim();
    return body ? { kind: "note", text: body.slice(0, MAX_NOTE_LENGTH) } : { kind: "open", target: "notes" };
  }

  const alone = ALONE.exec(text);
  if (alone) return { kind: "open", target: alone[1]!.toLowerCase() };
  const open = OPEN.exec(text);
  if (open) return { kind: "open", target: open[1]!.trim() };

  return videos(text);
}
