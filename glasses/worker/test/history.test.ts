import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { MAX_HISTORY } from "../routes/history.ts";
import { Client, pairGlasses, signUpOwner, signUpWithInvite } from "./helpers.ts";

type Item = { id: string; title: string; thumbnail: string; position: number; seconds: number | null; watchedAt: number };
const video = (n: number) => ({ id: `video${String(n).padStart(6, "0")}`, title: `Song ${n}`, channel: "Adele", seconds: 240 });

async function setup() {
  const owner = new Client();
  await signUpOwner(owner);
  const glasses = await pairGlasses(owner);
  return { owner, glasses };
}

const list = async (c: Client) => ((await (await c.get("/api/history")).json()) as { items: Item[] }).items;

describe("watch history", () => {
  it("records what the glasses play, for every device, newest first", async () => {
    const { owner, glasses } = await setup();
    expect((await glasses.put(`/api/history/${video(1).id}`, { video: video(1), position: 0 })).status).toBe(200);
    await glasses.put(`/api/history/${video(2).id}`, { video: video(2), position: 0 });
    const items = await list(owner);
    expect(items.map((i) => i.title)).toEqual(["Song 2", "Song 1"]);
    // The thumbnail comes from the id, never from the request.
    expect(items[0]!.thumbnail).toBe(`https://i.ytimg.com/vi/${video(2).id}/mqdefault.jpg`);
  });

  it("keeps one row per video: watching again moves it up and keeps the position", async () => {
    const { glasses } = await setup();
    await glasses.put(`/api/history/${video(1).id}`, { video: video(1), position: 0 });
    await glasses.put(`/api/history/${video(2).id}`, { video: video(2), position: 0 });
    const saved = (await (await glasses.put(`/api/history/${video(1).id}`, { video: video(1), position: 95 })).json()) as Item;
    expect(saved.position).toBe(95);
    const items = await list(glasses);
    expect(items.map((i) => [i.title, i.position])).toEqual([
      ["Song 1", 95],
      ["Song 2", 0],
    ]);
    // Never past the end.
    await glasses.put(`/api/history/${video(1).id}`, { video: video(1), position: 9999 });
    expect((await list(glasses))[0]!.position).toBe(240);
  });

  it("validates the video", async () => {
    const { glasses } = await setup();
    expect((await glasses.put("/api/history/nope", { video: { ...video(1), id: "nope" }, position: 0 })).status).toBe(400);
    expect((await glasses.put(`/api/history/${video(1).id}`, { video: video(2), position: 0 })).status).toBe(400);
    expect((await glasses.put(`/api/history/${video(1).id}`, { video: video(1), position: -1 })).status).toBe(400);
  });

  it("removes one or clears all", async () => {
    const { owner, glasses } = await setup();
    await glasses.put(`/api/history/${video(1).id}`, { video: video(1), position: 0 });
    await glasses.put(`/api/history/${video(2).id}`, { video: video(2), position: 0 });
    expect((await owner.delete(`/api/history/${video(1).id}`)).status).toBe(204);
    expect((await owner.delete(`/api/history/${video(1).id}`)).status).toBe(404);
    expect((await list(glasses)).map((i) => i.title)).toEqual(["Song 2"]);
    expect((await glasses.delete("/api/history")).status).toBe(204);
    expect(await list(owner)).toEqual([]);
  });

  it("keeps only the newest videos", async () => {
    const { glasses } = await setup();
    const me = (await (await glasses.get("/api/me")).json()) as { user: { id: string } };
    // Fill to the cap directly, then add one more through the API.
    const insert = env.DB.prepare(
      "INSERT INTO watch_history (user_id, video_id, title, channel, seconds, position, watched_at) VALUES (?, ?, ?, 'Adele', 240, 0, ?)",
    );
    await env.DB.batch(Array.from({ length: MAX_HISTORY }, (_, i) => insert.bind(me.user.id, video(i).id, `Song ${i}`, 1000 + i)));
    await glasses.put(`/api/history/${video(9999).id}`, { video: video(9999), position: 0 });
    const { count } = (await env.DB.prepare("SELECT COUNT(*) AS count FROM watch_history WHERE user_id = ?").bind(me.user.id).first<{ count: number }>())!;
    expect(count).toBe(MAX_HISTORY);
    const oldest = await env.DB.prepare("SELECT 1 FROM watch_history WHERE user_id = ? AND video_id = ?").bind(me.user.id, video(0).id).first();
    expect(oldest).toBeNull();
  });

  it("is per account and for signed-in accounts only", async () => {
    const { owner } = await setup();
    await owner.put(`/api/history/${video(1).id}`, { video: video(1), position: 0 });
    const { code } = (await (await owner.post("/api/invites")).json()) as { code: string };
    const guest = new Client();
    await signUpWithInvite(guest, code, "guest-key");
    expect(await list(guest)).toEqual([]);
    expect((await guest.delete(`/api/history/${video(1).id}`)).status).toBe(404);
    expect((await new Client().get("/api/history")).status).toBe(401);
  });
});
