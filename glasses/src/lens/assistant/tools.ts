/**
 * Lens for Meta AI (WebMCP). While Lens is open, the wearer can say "Hey Meta,
 * play lofi beats" and Meta AI calls these tools, so nothing has to be written
 * in the glasses' composer. Every tool goes through the same chat as the bar,
 * so the phone sees it too, and Lens stays fully usable without them.
 *
 * Platform rules followed here (Meta's agent-tools guide and its WebMCP skill):
 * register on `document.modelContext` with no polyfill; registration must never
 * break the app; only scalar parameters, validated in `execute`; forward the
 * signal (10 second deadline); a fulfilled result counts as success, so handled
 * problems are ordinary results with `next_action`; speech ends the turn, so
 * results ask for one short sentence and leave the detail on the display.
 */
import type { ChatMessage, VideoItem } from "../../shared/api.ts";
import { spokenDuration } from "../../shared/time.ts";
import { formatDuration } from "../../shared/youtube.ts";
import type { PlayerControls } from "../features/youtube/player.ts";

type Scalar = "string" | "number" | "integer" | "boolean";

export interface ModelContextTool {
  name: string;
  description: string;
  inputSchema: {
    type: "object";
    properties: Record<string, { type: Scalar; description: string }>;
    required?: string[];
  };
  annotations?: { readOnlyHint?: boolean; untrustedContentHint?: boolean };
  execute: (input: Record<string, unknown>, options?: { signal?: AbortSignal }) => Promise<unknown>;
}

export interface ModelContext {
  registerTool(tool: ModelContextTool, options?: { signal?: AbortSignal }): unknown;
}

/** The browser's model context, where the glasses provide one. */
export function modelContext(): ModelContext | null {
  const ctx = (document as Document & { modelContext?: Partial<ModelContext> }).modelContext;
  return ctx && typeof ctx.registerTool === "function" ? (ctx as ModelContext) : null;
}

/** What the tools act through: the same chat, apps and player the buttons use. */
export interface ToolDeps {
  send(text: string, scope: "auto" | "videos", signal?: AbortSignal): Promise<ChatMessage | null>;
  play(video: VideoItem, signal?: AbortSignal): Promise<ChatMessage>;
  /** Brings an app forward on the bar. */
  show(app: "youtube" | "notes" | "timer"): void;
  /** The videos numbered on the display from 1: Up next while one plays, else the newest results. */
  results(): VideoItem[];
  player(): PlayerControls | null;
  status(): Record<string, unknown>;
}

const SAY_DONE = "Confirm in one short sentence; the details are on the display. Stop and talk.";

const problem = (message: string, next_action: string) => ({ error: true, message, next_action });

function str(input: Record<string, unknown> | undefined, key: string): string {
  const v = input?.[key];
  return typeof v === "string" ? v.trim() : typeof v === "number" && Number.isFinite(v) ? String(v) : "";
}

const ORDINALS: Record<string, number> = {
  first: 1, one: 1, second: 2, two: 2, third: 3, three: 3, fourth: 4, four: 4, fifth: 5, five: 5,
  sixth: 6, six: 6, seventh: 7, seven: 7, eighth: 8, eight: 8, ninth: 9, nine: 9, tenth: 10, ten: 10,
  eleventh: 11, eleven: 11, twelfth: 12, twelve: 12,
};

/** "2", "number two", "the second one" -> 2; "the last one" -> the count; null when it names no result. */
export function resultNumber(raw: string, count: number): number | null {
  let t = raw
    .toLowerCase()
    .replace(/[^a-z0-9 ]/g, " ")
    .replace(/\b(the|number|no|video|result|please|play|it)\b/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (/^\d{1,2}$/.test(t)) return Number(t);
  if (t !== "one") t = t.replace(/ one$/, "");
  if (t === "last") return count || null;
  return Object.prototype.hasOwnProperty.call(ORDINALS, t) ? ORDINALS[t]! : null;
}

const numbered = (videos: VideoItem[]) =>
  videos.slice(0, 5).map((v, i) => `${i + 1}. ${v.title}${v.channel ? ` (${v.channel})` : ""}${v.seconds ? `, ${formatDuration(v.seconds)}` : ""}`);

/** Turns Lens's reply into what Meta AI needs for its next step. */
export function describe(message: ChatMessage | null): Record<string, unknown> {
  if (!message) return problem("Lens could not reach its server.", "Say Lens is offline right now, then stop.");
  const r = message.reply;
  switch (r.kind) {
    case "videos":
      if (r.videos.length === 0) return problem(`No videos found for "${r.query}".`, "Say nothing was found and offer a different search. Stop and talk.");
      return r.autoplay
        ? { playing: r.videos[0]!.title, next_action: SAY_DONE }
        : {
            query: r.query,
            shown: r.videos.length,
            top: numbered(r.videos),
            next_action: "Say in one short sentence that the videos are on the display and the wearer can ask to play one by its number. Stop and talk.",
          };
    case "play":
      return { playing: r.video.title, next_action: SAY_DONE };
    case "note":
      return { saved: r.note.text, next_action: SAY_DONE };
    case "timer":
      return { timer: spokenDuration(r.durationMs), next_action: SAY_DONE };
    case "open":
      return { opened: r.name, next_action: SAY_DONE };
    case "help":
      return { next_action: "Say Lens can search and play YouTube, save notes, set timers and open apps. Stop and talk." };
    case "error":
      return problem(r.message, "Tell the wearer in one short sentence, then stop.");
  }
}

export function lensTools(deps: () => ToolDeps): ModelContextTool[] {
  return [
    {
      name: "lens_search",
      description: "Search YouTube in Lens and show the results on the glasses. Use for search, find, look up or show me videos.",
      inputSchema: {
        type: "object",
        properties: { query: { type: "string", description: 'What to search for, in the wearer\'s words, e.g. "lofi beats".' } },
        required: ["query"],
      },
      annotations: { untrustedContentHint: true },
      execute: async (input, options) => {
        const query = str(input, "query");
        if (!query) return problem("No search words.", "Ask what to search for. Stop and talk.");
        const d = deps();
        d.show("youtube");
        return describe(await d.send(query, "videos", options?.signal));
      },
    },
    {
      name: "lens_play",
      description:
        'Play a video on the glasses: a result number from the display ("play 2", "play the first one"), or anything to search and play at once ("play rain sounds").',
      inputSchema: {
        type: "object",
        properties: {
          what: { type: "string", description: 'A result number on the display, e.g. "2", or what to play, e.g. "rain sounds".' },
        },
        required: ["what"],
      },
      annotations: { untrustedContentHint: true },
      execute: async (input, options) => {
        const what = str(input, "what");
        if (!what) return problem("Nothing to play.", "Ask what to play. Stop and talk.");
        const d = deps();
        const results = d.results();
        const n = resultNumber(what, results.length);
        if (n !== null) {
          const video = results[n - 1];
          if (!video) {
            return problem(
              results.length ? `There are only ${results.length} results on the display.` : "There are no results on the display.",
              results.length ? "Say how many results there are. Stop and talk." : "Offer to search first. Stop and talk.",
            );
          }
          await d.play(video, options?.signal);
          return { playing: video.title, next_action: SAY_DONE };
        }
        d.show("youtube");
        return describe(await d.send(`play ${what}`, "videos", options?.signal));
      },
    },
    {
      name: "lens_note",
      description: "Save a note in Lens. It shows on the glasses and the phone.",
      inputSchema: {
        type: "object",
        properties: { text: { type: "string", description: "The note, in the wearer's words." } },
        required: ["text"],
      },
      execute: async (input, options) => {
        const text = str(input, "text");
        if (!text) return problem("The note is empty.", "Ask what to write down. Stop and talk.");
        const d = deps();
        const result = describe(await d.send(`note ${text}`, "auto", options?.signal));
        if (!("error" in result)) d.show("notes");
        return result;
      },
    },
    {
      name: "lens_timer",
      description: "Start a countdown timer on the glasses.",
      inputSchema: {
        type: "object",
        properties: {
          minutes: { type: "number", description: "Length in minutes, up to 1440. Decimals allowed, e.g. 0.5 for 30 seconds." },
        },
        required: ["minutes"],
      },
      execute: async (input, options) => {
        const minutes = Number(input?.minutes);
        if (!Number.isFinite(minutes) || minutes <= 0 || minutes > 1440) {
          return problem("Timers run from a few seconds to 24 hours.", "Ask for a length in that range. Stop and talk.");
        }
        const d = deps();
        const result = describe(await d.send(`timer ${minutes} minutes`, "auto", options?.signal));
        if (!("error" in result)) d.show("timer");
        return result;
      },
    },
    {
      name: "lens_open",
      description: "Open an app in Lens on the glasses: YouTube, Notes, Timer, Companion, or a website the wearer added.",
      inputSchema: {
        type: "object",
        properties: { name: { type: "string", description: 'The app or website, e.g. "notes" or "github".' } },
        required: ["name"],
      },
      execute: async (input, options) => {
        const name = str(input, "name");
        if (!name) return problem("No app named.", "Ask which app to open. Stop and talk.");
        return describe(await deps().send(`open ${name}`, "auto", options?.signal));
      },
    },
    {
      name: "lens_video",
      description: "Control the video playing in Lens: pause, resume, forward, back, restart, or next (the first video in Up next).",
      inputSchema: {
        type: "object",
        properties: {
          action: { type: "string", description: "One of: pause, resume, forward, back, restart, next." },
          seconds: { type: "number", description: "For forward or back: how many seconds. 10 if not given." },
        },
        required: ["action"],
      },
      execute: async (input) => {
        const player = deps().player();
        if (!player) return problem("No video is open.", "Offer to play something. Stop and talk.");
        const action = str(input, "action").toLowerCase();
        const seconds = Math.min(Math.max(Math.abs(Number(input?.seconds) || 10), 1), 3600);
        if (/^(next|skip (to )?(the )?next|another)/.test(action)) {
          const upcoming = player.queue()[0];
          if (!upcoming || !player.next()) return problem("Nothing is up next yet.", "Say so in a few words. Stop and talk.");
          return { playing: upcoming.title, next_action: SAY_DONE };
        }
        if (/^(pause|stop|hold)/.test(action)) player.pause();
        else if (/^(resume|play|continue|unpause|go)/.test(action)) player.play();
        else if (/^(forward|skip|ahead|fast)/.test(action)) player.skip(seconds);
        else if (/^(back|rewind|backward|behind)/.test(action)) player.skip(-seconds);
        else if (/^(restart|start over|beginning|replay)/.test(action)) player.restart();
        else return problem(`"${action}" is not a video control.`, "Offer pause, resume, forward, back, restart or next. Stop and talk.");
        const s = player.state();
        return {
          video: s.title,
          state: /^(pause|stop|hold)/.test(action) ? "paused" : "playing",
          position: `${formatDuration(s.at)} of ${s.total ? formatDuration(s.total) : "unknown"}`,
          next_action: "Confirm in a few words at most. Stop and talk.",
        };
      },
    },
    {
      name: "lens_status",
      description:
        "What Lens shows right now: the app, the numbered videos on the display, the video playing and its Up next, the timer and notes. Read this before acting when unsure.",
      inputSchema: { type: "object", properties: {} },
      annotations: { readOnlyHint: true, untrustedContentHint: true },
      execute: async () => ({ ...deps().status(), next_action: "Use this to decide the next tool, or answer in one short sentence." }),
    },
  ];
}

/** Registers one tool so that no failure, thrown or rejected, can stop the others or the app. */
function safeRegister(ctx: ModelContext, tool: ModelContextTool, signal: AbortSignal): boolean {
  try {
    const result = ctx.registerTool(tool, { signal });
    // A promise on some builds, a handle or nothing on others.
    if (typeof (result as PromiseLike<unknown> | undefined)?.then === "function") {
      (result as PromiseLike<unknown>).then(undefined, (err: unknown) => console.error(`${tool.name} registration failed`, err));
    }
    return true;
  } catch (err) {
    console.error(`${tool.name} registration failed`, err);
    return false;
  }
}

/** Registers every Lens tool; aborting the signal unregisters them. Returns how many registered. */
export function registerLensTools(ctx: ModelContext, deps: () => ToolDeps, signal: AbortSignal): number {
  return lensTools(deps).filter((tool) => safeRegister(ctx, tool, signal)).length;
}

export { numbered as numberedResults };
