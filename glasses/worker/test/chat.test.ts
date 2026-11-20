import { describe, expect, it } from "vitest";
import type { ChatMessage, ChatPage } from "../../src/shared/api.ts";
import { createApp } from "../app.ts";
import { cleanup } from "../index.ts";
import { env } from "cloudflare:test";
import { Client, fakeWebAuthn, pairGlasses, signUpOwner, signUpWithInvite } from "./helpers.ts";

/** YouTube as the tests see it: every query finds two videos named after it. */
let quotaExceeded = false;
async function fakeYouTube(input: URL | RequestInfo): Promise<Response> {
  const url = new URL(String(input));
  const json = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
  if (quotaExceeded) return json(403, { error: { errors: [{ reason: "quotaExceeded" }] } });
  if (url.pathname.endsWith("/search")) {
    const q = url.searchParams.get("q") ?? "";
    return json(200, {
      items: ["aaaaaaaaaaa", "bbbbbbbbbbb"].map((id, i) => ({
        id: { videoId: id },
        snippet: { title: `${q} ${i + 1}`, channelTitle: "Channel", thumbnails: {} },
      })),
    });
  }
  return json(200, { items: [{ id: "aaaaaaaaaaa", contentDetails: { duration: "PT3M" } }] });
}

const app = () => createApp({ webauthn: fakeWebAuthn, fetch: fakeYouTube as typeof fetch });

async function setup() {
  quotaExceeded = false;
  const owner = new Client(app());
  await signUpOwner(owner);
  const glasses = await pairGlasses(owner, new Client(app()));
  return { owner, glasses };
}

/** Queries are unique per test: the edge cache outlives a test. */
const unique = (q: string) => `${q} ${crypto.randomUUID().slice(0, 8)}`;

async function say(client: Client, text: string, scope?: "videos"): Promise<ChatMessage> {
  const res = await client.post("/api/chat", scope ? { text, scope } : { text });
  expect(res.status, await res.clone().text()).toBe(201);
  return (await res.json()) as ChatMessage;
}

async function page(client: Client, query = ""): Promise<ChatPage> {
  const res = await client.get(`/api/chat${query}`);
  expect(res.status).toBe(200);
  return (await res.json()) as ChatPage;
}

describe("Lens chat", () => {
  it("searches YouTube from the glasses and shows the answer on the console", async () => {
    const { owner, glasses } = await setup();
    const query = unique("lofi beats");
    const sent = await say(glasses, `${query}.`);
    expect(sent).toMatchObject({ source: "glasses", text: query, reply: { kind: "videos", query, autoplay: false } });
    if (sent.reply.kind !== "videos") throw new Error("expected videos");
    expect(sent.reply.videos.map((v) => v.title)).toEqual([`${query} 1`, `${query} 2`]);
    expect(sent.reply.videos[0]?.seconds).toBe(180);

    const seen = await page(owner);
    expect(seen.items.map((m) => m.id)).toEqual([sent.id]);
  });

  it("plays the top result when asked to play", async () => {
    const { owner } = await setup();
    const sent = await say(owner, `play ${unique("rain sounds")}`);
    expect(sent).toMatchObject({ source: "console", reply: { kind: "videos", autoplay: true } });
  });

  it("keeps everything a search on the YouTube screen", async () => {
    const { glasses } = await setup();
    const sent = await say(glasses, "timer 5 minutes", "videos");
    expect(sent.reply).toMatchObject({ kind: "videos", query: "timer 5 minutes" });
  });

  it("saves notes, starts timers, opens apps and answers help", async () => {
    const { owner, glasses } = await setup();
    const note = await say(glasses, "Note: buy milk.");
    expect(note.reply).toMatchObject({ kind: "note", note: { text: "buy milk" } });
    const notes = (await (await owner.get("/api/notes")).json()) as { items: { text: string }[] };
    expect(notes.items.map((n) => n.text)).toEqual(["buy milk"]);

    expect((await say(owner, "set a timer for five minutes")).reply).toEqual({ kind: "timer", durationMs: 300_000 });
    expect((await say(glasses, "open notes")).reply).toEqual({ kind: "open", name: "Notes", view: "notes" });

    await owner.post("/api/apps", { url: "github.com" });
    expect((await say(glasses, "open GitHub")).reply).toEqual({ kind: "open", name: "Github", url: "https://github.com/" });
    expect((await say(glasses, "go to news.ycombinator.com")).reply).toEqual({
      kind: "open",
      name: "news.ycombinator.com",
      url: "https://news.ycombinator.com/",
    });
    expect((await say(glasses, "open the weather app")).reply).toMatchObject({ kind: "error" });
    expect((await say(glasses, "help")).reply).toEqual({ kind: "help" });
  });

  it("stores search problems as replies everyone can see", async () => {
    const { owner, glasses } = await setup();
    quotaExceeded = true;
    const sent = await say(glasses, unique("cats"));
    expect(sent.reply).toEqual({ kind: "error", message: "Today's search limit is used up. It resets at midnight Pacific." });
    expect((await page(owner)).items).toHaveLength(1);
  });

  it("syncs from a cursor and holds the request until there is news", async () => {
    const { owner, glasses } = await setup();
    const first = await say(glasses, "help");

    // Nothing new: the request is held for the wait, then answers empty.
    const started = Date.now();
    const idle = await page(owner, `?after=${first.seq}&wait=1&cleared=0`);
    expect(idle.items).toEqual([]);
    expect(Date.now() - started).toBeGreaterThanOrEqual(900);

    // Something arrives while the console waits: it is answered at once.
    const waiting = page(owner, `?after=${first.seq}&wait=10&cleared=0`);
    const second = await say(glasses, "timer 1 minute");
    const woke = await waiting;
    expect(woke.items.map((m) => m.id)).toEqual([second.id]);
  });

  it("clears the chat on every device", async () => {
    const { owner, glasses } = await setup();
    await say(glasses, "help");
    const last = await say(owner, "timer 2");
    const cleared = await owner.delete("/api/chat");
    expect(await cleared.json()).toEqual({ clearedThrough: last.seq });

    const after = await page(glasses, `?after=0&wait=0`);
    expect(after).toEqual({ items: [], clearedThrough: last.seq });
    const next = await say(glasses, "help");
    expect(next.seq).toBeGreaterThan(last.seq);
    expect((await page(owner)).items.map((m) => m.id)).toEqual([next.id]);
  });

  it("plays a video on the glasses picked on the console", async () => {
    const { owner } = await setup();
    const video = { id: "aaaaaaaaaaa", title: "Rain", channel: "Nature", seconds: 600 };
    const res = await owner.post("/api/chat/play", { video });
    expect(res.status).toBe(201);
    expect(((await res.json()) as ChatMessage).reply).toEqual({
      kind: "play",
      video: { ...video, thumbnail: "https://i.ytimg.com/vi/aaaaaaaaaaa/mqdefault.jpg" },
    });
    expect((await owner.post("/api/chat/play", { video: { ...video, id: "../../evil" } })).status).toBe(400);
  });

  it("validates input and keeps each account's chat to itself", async () => {
    const { owner } = await setup();
    expect((await owner.post("/api/chat", { text: "   " })).status).toBe(400);
    expect((await owner.post("/api/chat", { text: "x".repeat(501) })).status).toBe(400);
    await say(owner, "help");

    const { code } = (await (await owner.post("/api/invites")).json()) as { code: string };
    const guest = new Client(app());
    await signUpWithInvite(guest, code, "guest-key");
    expect((await page(guest)).items).toEqual([]);
    expect((await new Client(app()).get("/api/chat")).status).toBe(401);
  });

  it("forgets messages after 90 days", async () => {
    const { owner } = await setup();
    await say(owner, "help");
    const count = async () => (await env.DB.prepare("SELECT COUNT(*) AS n FROM messages").first<{ n: number }>())?.n;
    await cleanup(env.DB, Date.now() + 89 * 86_400_000);
    expect(await count()).toBe(1);
    await cleanup(env.DB, Date.now() + 91 * 86_400_000);
    expect(await count()).toBe(0);
  });
});
