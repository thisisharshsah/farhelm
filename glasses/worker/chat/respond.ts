/**
 * Turns an intent into Lens's reply: runs the search, saves the note or
 * finds the app. Anything that goes wrong becomes an error reply, so the
 * person sees what happened on every device instead of a silent failure.
 */
import type { Context } from "hono";
import type { ChatReply, OpenView } from "../../src/shared/api.ts";
import { builtInFor, normalizeAppUrl } from "../../src/shared/apps.ts";
import type { Intent } from "../../src/shared/intents.ts";
import type { AppEnv } from "../env.ts";
import { ApiError } from "../lib/http.ts";
import { findVideos } from "../media/rows.ts";
import { createNote } from "../notes.ts";

const SCREENS: Record<string, { view: OpenView; name: string }> = {
  home: { view: "home", name: "Home" },
  lens: { view: "home", name: "Home" },
  youtube: { view: "youtube", name: "YouTube" },
  notes: { view: "notes", name: "Notes" },
  note: { view: "notes", name: "Notes" },
  timer: { view: "timer", name: "Timer" },
  timers: { view: "timer", name: "Timer" },
  companion: { view: "companion", name: "Companion" },
  apps: { view: "apps", name: "Apps" },
};

const compact = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, "");
const host = (url: string) => new URL(url).hostname.replace(/^www\./, "");

/** A built-in screen, one of the account's websites, or any https address. */
async function resolveOpen(db: D1Database, userId: string, target: string): Promise<ChatReply> {
  const screen = SCREENS[target.toLowerCase().trim()];
  if (screen) return { kind: "open", name: screen.name, view: screen.view };

  const want = compact(target);
  if (want) {
    const { results } = await db
      .prepare("SELECT name, url FROM web_apps WHERE user_id = ? ORDER BY position, created_at")
      .bind(userId)
      .all<{ name: string; url: string }>();
    const match =
      results.find((a) => compact(a.name) === want) ??
      results.find((a) => compact(host(a.url)).startsWith(want)) ??
      results.find((a) => compact(a.name).startsWith(want));
    if (match) return { kind: "open", name: match.name, url: match.url };
  }

  // Not one of the apps: an address still opens, without being added.
  if (/^\S+\.\S+$/.test(target.trim())) {
    const url = normalizeAppUrl(target);
    if (url) {
      return builtInFor(url)
        ? { kind: "open", name: "YouTube", view: "youtube" }
        : { kind: "open", name: host(url.href), url: url.href };
    }
  }
  return { kind: "error", message: `"${target}" is not one of your apps. Add it under Apps on your phone.` };
}

export async function respond(c: Context<AppEnv>, userId: string, intent: Intent, fetchImpl: typeof fetch): Promise<ChatReply> {
  try {
    switch (intent.kind) {
      case "videos": {
        const found = await findVideos(c, userId, intent.query, fetchImpl);
        return { kind: "videos", query: found.query, videos: found.videos, autoplay: intent.autoplay && found.videos.length > 0 };
      }
      case "note":
        return { kind: "note", note: await createNote(c.env.DB, userId, intent.text) };
      case "timer":
        return { kind: "timer", durationMs: intent.durationMs };
      case "open":
        return await resolveOpen(c.env.DB, userId, intent.target);
      case "help":
        return { kind: "help" };
      case "unclear":
        return { kind: "error", message: intent.message };
    }
  } catch (e) {
    if (e instanceof ApiError) return { kind: "error", message: e.message };
    throw e;
  }
}
