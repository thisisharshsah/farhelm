import { describe, expect, it } from "vitest";
import { Client, pairGlasses, signUpOwner, signUpWithInvite } from "./helpers.ts";

async function setup() {
  const owner = new Client();
  await signUpOwner(owner);
  const glasses = await pairGlasses(owner);
  return { owner, glasses };
}

describe("data synced to the glasses", () => {
  it("shares notes between the console and the glasses", async () => {
    const { owner, glasses } = await setup();
    const created = await glasses.post("/api/notes", { text: "  Buy milk " });
    expect(created.status).toBe(201);
    const note = (await created.json()) as { id: string; text: string };
    expect(note.text).toBe("Buy milk");

    const list = (await (await owner.get("/api/notes")).json()) as { items: { id: string }[] };
    expect(list.items.map((n) => n.id)).toEqual([note.id]);
    expect((await owner.delete(`/api/notes/${note.id}`)).status).toBe(204);
    expect((await glasses.delete(`/api/notes/${note.id}`)).status).toBe(404);
  });

  it("validates notes", async () => {
    const { glasses } = await setup();
    expect((await glasses.post("/api/notes", { text: "   " })).status).toBe(400);
    expect((await glasses.post("/api/notes", { text: "x".repeat(501) })).status).toBe(400);
  });

  it("adds website apps in order and rejects duplicates and built-ins", async () => {
    const { glasses } = await setup();
    const a = (await (await glasses.post("/api/apps", { url: "github.com" })).json()) as { name: string; position: number };
    const b = (await (await glasses.post("/api/apps", { url: "https://en.wikipedia.org/" })).json()) as { position: number };
    expect(a).toMatchObject({ name: "Github", position: 0 });
    expect(b.position).toBe(1);
    expect((await glasses.post("/api/apps", { url: "https://github.com" })).status).toBe(409);
    expect((await glasses.post("/api/apps", { url: "m.youtube.com" })).status).toBe(409);
    expect((await glasses.post("/api/apps", { url: "http://insecure.com" })).status).toBe(400);
  });

  it("merges preference updates and validates the Companion link", async () => {
    const { owner, glasses } = await setup();
    expect(await (await glasses.get("/api/preferences")).json()).toEqual({ recentSearches: [], companionLink: null });
    await glasses.patch("/api/preferences", { recentSearches: ["lofi beats"] });
    const set = await owner.patch("/api/preferences", { companionLink: "http://192.168.1.5:8787/glass#tok" });
    expect(await set.json()).toEqual({ recentSearches: ["lofi beats"], companionLink: "http://192.168.1.5:8787/glass#tok" });
    expect((await owner.patch("/api/preferences", { companionLink: "http://evil.example/x" })).status).toBe(400);
  });

  it("keeps each account's data to itself", async () => {
    const { owner } = await setup();
    const note = (await (await owner.post("/api/notes", { text: "private" })).json()) as { id: string };
    const { code } = (await (await owner.post("/api/invites")).json()) as { code: string };
    const guest = new Client();
    await signUpWithInvite(guest, code, "guest-key");
    expect(((await (await guest.get("/api/notes")).json()) as { items: unknown[] }).items).toEqual([]);
    expect((await guest.delete(`/api/notes/${note.id}`)).status).toBe(404);
    expect((await guest.get("/api/invites")).status).toBe(403);
  });

  it("requires a session for data and media", async () => {
    const stranger = new Client();
    for (const path of ["/api/notes", "/api/apps", "/api/preferences", "/api/youtube/search?q=x", "/api/icon?url=https://x.com"]) {
      expect((await stranger.get(path)).status, path).toBe(401);
    }
  });
});

describe("request hardening", () => {
  it("rejects cross-origin writes and non-JSON bodies", async () => {
    const { owner } = await setup();
    const cross = await owner.request("POST", "/api/notes", { text: "x" }, { origin: "https://evil.example" });
    expect(cross.status).toBe(403);
    const form = await owner.request("POST", "/api/notes", undefined, { "content-type": "text/plain" });
    expect(form.status).toBe(415);
  });

  it("never lets shared caches keep account data", async () => {
    const { owner } = await setup();
    const res = await owner.get("/api/notes");
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(res.headers.get("x-content-type-options")).toBe("nosniff");
  });

  it("answers unknown endpoints with JSON", async () => {
    const res = await new Client().get("/api/nope");
    expect(res.status).toBe(404);
    expect(await res.json()).toMatchObject({ error: { code: "not_found" } });
  });
});
