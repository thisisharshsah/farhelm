/**
 * Lens chat. Anything said on the glasses or typed in the console is one
 * message; Lens replies in the same row and every device of the account sees
 * both. Clients sync with a long poll: GET waits up to `wait` seconds for
 * something newer than `after`, so a message typed on the phone reaches the
 * glasses within about a second without a request every second.
 */
import { Hono } from "hono";
import { ChatInput, PlayInput } from "../../src/shared/api.ts";
import { cleanUtterance, parseIntent } from "../../src/shared/intents.ts";
import { thumbnailOf } from "../../src/shared/youtube.ts";
import { respond } from "../chat/respond.ts";
import { MAX_PAGE, PAGE_SIZE, clearChat, insertMessage, marks, readPage } from "../chat/store.ts";
import type { AppEnv } from "../env.ts";
import { body } from "../lib/http.ts";
import { limit } from "../lib/rateLimit.ts";
import { requireSession } from "../sessions.ts";

/**
 * Longest a sync request is held open, and how often it looks for news
 * meanwhile. One check is one D1 query, and a Worker invocation may make at
 * most 50 on the Free plan: 21 checks plus the session and the page stay
 * well under it.
 */
export const MAX_WAIT_SECONDS = 20;
const CHECK_EVERY_MS = 1000;

/** A non-negative integer query parameter, or null. */
function int(raw: string | undefined): number | null {
  if (raw === undefined || !/^\d{1,15}$/.test(raw)) return null;
  return Number(raw);
}

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/** Returns once there is a message after `after`, the chat was cleared, or time runs out. */
async function waitForNews(
  db: D1Database,
  userId: string,
  after: number,
  knownCleared: number | null,
  ms: number,
  signal: AbortSignal,
): Promise<void> {
  const deadline = Date.now() + ms;
  let cleared = knownCleared;
  for (;;) {
    const now = await marks(db, userId);
    // A client that did not say what it knows is only woken by new messages.
    cleared ??= now.cleared;
    if (now.latest > after || now.cleared > cleared) return;
    const left = deadline - Date.now();
    if (left <= 0 || signal.aborted) return;
    await sleep(Math.min(CHECK_EVERY_MS, left));
  }
}

export function chatRoutes(fetchImpl: typeof fetch = fetch) {
  const r = new Hono<AppEnv>();

  r.get("/", async (c) => {
    const s = requireSession(c);
    const after = int(c.req.query("after"));
    const wait = Math.min(int(c.req.query("wait")) ?? 0, MAX_WAIT_SECONDS);
    const size = Math.min(Math.max(int(c.req.query("limit")) ?? (after === null ? PAGE_SIZE : MAX_PAGE), 1), MAX_PAGE);
    if (after !== null && wait > 0) {
      await waitForNews(c.env.DB, s.userId, after, int(c.req.query("cleared")), wait * 1000, c.req.raw.signal);
    }
    return c.json(await readPage(c.env.DB, s.userId, after, size));
  });

  r.post("/", async (c) => {
    const s = requireSession(c);
    const input = await body(c, ChatInput);
    await limit(c, "API_LIMITER", `chat:${s.userId}`);
    const reply = await respond(c, s.userId, parseIntent(input.text, input.scope), fetchImpl);
    const message = await insertMessage(c.env.DB, s.userId, s.kind, cleanUtterance(input.text) || input.text, reply);
    return c.json(message, 201);
  });

  r.post("/play", async (c) => {
    const s = requireSession(c);
    const { video } = await body(c, PlayInput);
    await limit(c, "API_LIMITER", `chat:${s.userId}`);
    // The thumbnail comes from the id, never from the request.
    const full = { ...video, thumbnail: thumbnailOf(video.id) };
    // Stored as if it had been said, so every device reads the same request.
    const message = await insertMessage(c.env.DB, s.userId, s.kind, `Play ${video.title || "this video"}`, { kind: "play", video: full });
    return c.json(message, 201);
  });

  r.delete("/", async (c) => {
    const s = requireSession(c);
    return c.json({ clearedThrough: await clearChat(c.env.DB, s.userId) });
  });

  return r;
}
