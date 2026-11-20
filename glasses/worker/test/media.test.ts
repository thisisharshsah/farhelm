import { describe, expect, it } from "vitest";
import { createApp } from "../app.ts";
import { Client, fakeWebAuthn, signUpOwner } from "./helpers.ts";

const ok = (body: unknown) => new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } });

/** A fresh 11-character id per run: the edge cache outlives a test. */
const freshVideo = () => `v${crypto.randomUUID().replace(/-/g, "").slice(0, 10)}`;

/**
 * YouTube as these tests see it: every video is by Adele (Music) on a channel
 * named after it; searches, uploads and charts answer two pages of videos.
 */
function fakeYouTube() {
  const asked: URL[] = [];
  const whole = (id: string) => ({
    id,
    snippet: { title: `Song ${id}`, channelTitle: "AdeleVEVO", publishedAt: "2024-01-01T00:00:00Z" },
    contentDetails: { duration: "PT3M" },
    statistics: { viewCount: "100", likeCount: "5" },
    status: { embeddable: true },
  });
  const page = (url: URL, ids: string[]) => (url.searchParams.get("pageToken") === "PAGE2" ? { ids: ids.slice(0, 1), next: undefined } : { ids, next: "PAGE2" });
  const impl = async (input: URL | RequestInfo): Promise<Response> => {
    const url = new URL(String(input));
    asked.push(url);
    const part = url.searchParams.get("part");
    if (url.pathname.endsWith("/search")) {
      const p = page(url, ["ccccccccccc", "ddddddddddd"]);
      return ok({ items: p.ids.map((id) => ({ id: { videoId: id }, snippet: { title: `Song ${id}`, channelTitle: "Adele", thumbnails: {} } })), nextPageToken: p.next });
    }
    if (url.pathname.endsWith("/channels")) {
      return ok({ items: [{ snippet: { title: "AdeleVEVO" }, contentDetails: { relatedPlaylists: { uploads: `UU${url.searchParams.get("id")!.slice(2)}` } } }] });
    }
    if (url.pathname.endsWith("/playlistItems")) {
      const p = page(url, ["eeeeeeeeeee", "fffffffffff"]);
      return ok({ items: p.ids.map((videoId) => ({ contentDetails: { videoId } })), nextPageToken: p.next });
    }
    if (url.searchParams.get("chart") === "mostPopular") {
      const p = page(url, ["ggggggggggg", "hhhhhhhhhhh"]);
      return ok({ items: p.ids.map(whole), nextPageToken: p.next });
    }
    if (part === "snippet") {
      const id = url.searchParams.get("id")!;
      return ok({ items: [{ snippet: { title: "Adele - Hello", channelTitle: "AdeleVEVO", channelId: `UC${id}${"x".repeat(11)}`, categoryId: "10" } }] });
    }
    return ok({ items: (url.searchParams.get("id") ?? "").split(",").map(whole) });
  };
  return { asked, impl: impl as typeof fetch };
}

describe("Rows of videos", () => {
  it("answers the rows that follow a video: more like it, from its channel, popular in its category", async () => {
    const yt = fakeYouTube();
    const owner = new Client(createApp({ webauthn: fakeWebAuthn, fetch: yt.impl }));
    await signUpOwner(owner);
    const seed = freshVideo();
    const res = await owner.get(`/api/youtube/rows?seed=${seed}`);
    expect(res.status).toBe(200);
    const { rows } = (await res.json()) as { rows: { key: string; kind: string; subject: string; videos: { id: string }[]; next: string | null }[] };
    expect(rows.map((r) => [r.kind, r.subject])).toEqual([
      ["related", "Adele"],
      ["channel", "Adele"],
      ["popular", "Music"],
    ]);
    expect(rows[0]).toMatchObject({ key: `related:${seed}`, next: "PAGE2", videos: [{ id: "ccccccccccc" }, { id: "ddddddddddd" }] });
    expect(rows[1]?.key).toBe(`channel:UC${seed}${"x".repeat(11)}`);
    expect(rows[2]).toMatchObject({ key: "popular:10", videos: [{ id: "ggggggggggg" }, { id: "hhhhhhhhhhh" }] });
    // More like it searches in Music by the artist.
    const searched = yt.asked.find((u) => u.pathname.endsWith("/search"));
    expect(searched?.searchParams.get("q")).toBe("Adele");
    expect(searched?.searchParams.get("videoCategoryId")).toBe("10");

    // The second time, every page comes from the edge cache, through the same middleware.
    const calls = yt.asked.length;
    const again = await owner.get(`/api/youtube/rows?seed=${seed}`);
    expect(again.status).toBe(200);
    expect(again.headers.get("x-content-type-options")).toBe("nosniff");
    expect(yt.asked.length).toBe(calls);
  });

  it("grows a row a page at a time", async () => {
    const yt = fakeYouTube();
    const owner = new Client(createApp({ webauthn: fakeWebAuthn, fetch: yt.impl }));
    await signUpOwner(owner);
    const seed = freshVideo();
    const more = await owner.get(`/api/youtube/row?key=related:${seed}&page=PAGE2`);
    expect(more.status).toBe(200);
    expect(await more.json()).toMatchObject({ next: null, videos: [{ id: "ccccccccccc" }] });
    const channel = await owner.get(`/api/youtube/row?key=${encodeURIComponent(`channel:UC${seed}${"x".repeat(11)}`)}`);
    expect(await channel.json()).toMatchObject({ next: "PAGE2", videos: [{ id: "eeeeeeeeeee" }, { id: "fffffffffff" }] });
    const popular = await owner.get("/api/youtube/row?key=popular:all");
    expect(((await popular.json()) as { videos: unknown[] }).videos).toHaveLength(2);
    const results = await owner.get(`/api/youtube/row?key=${encodeURIComponent(`search:${seed} songs`)}`);
    expect(await results.json()).toMatchObject({ next: "PAGE2", videos: [{ id: "ccccccccccc" }, { id: "ddddddddddd" }] });
  });

  it("refuses rows, pages and videos it does not know", async () => {
    const owner = new Client(createApp({ webauthn: fakeWebAuthn, fetch: fakeYouTube().impl }));
    await signUpOwner(owner);
    expect((await owner.get("/api/youtube/rows?seed=nope")).status).toBe(400);
    expect((await owner.get("/api/youtube/row?key=watch:aaaaaaaaaaa")).status).toBe(400);
    expect((await owner.get("/api/youtube/row?key=channel:not-a-channel")).status).toBe(400);
    expect((await owner.get("/api/youtube/row?key=popular:all&page=../../x")).status).toBe(400);
  });

  it("is for signed-in accounts only", async () => {
    expect((await new Client().get("/api/youtube/rows?seed=aaaaaaaaaaa")).status).toBe(401);
    expect((await new Client().get("/api/youtube/row?key=popular:all")).status).toBe(401);
  });
});

describe("Video details", () => {
  /** A fresh id per run: the edge cache outlives a test. */
  const freshId = () => `v${crypto.randomUUID().replace(/-/g, "").slice(0, 10)}`;

  it("fills in videos by id, each cached so a later list asks YouTube only for the rest", async () => {
    const asked: string[][] = [];
    const known = new Set<string>();
    const fetchImpl = async (input: URL | RequestInfo) => {
      const ids = (new URL(String(input)).searchParams.get("id") ?? "").split(",");
      asked.push(ids);
      return ok({
        items: ids
          .filter((id) => known.has(id))
          .map((id) => ({ id, contentDetails: { duration: "PT4M5S" }, statistics: { viewCount: "1200", likeCount: "30" }, snippet: { publishedAt: "2024-03-01T00:00:00Z", description: `About ${id}` } })),
      });
    };
    const owner = new Client(createApp({ webauthn: fakeWebAuthn, fetch: fetchImpl as typeof fetch }));
    await signUpOwner(owner);
    const [a, b, gone] = [freshId(), freshId(), freshId()];
    known.add(a).add(b);

    const first = await owner.get(`/api/youtube/details?ids=${a},${gone}`);
    expect(first.status).toBe(200);
    expect(await first.json()).toEqual({
      videos: [{ id: a, seconds: 245, views: 1200, likes: 30, published: Date.parse("2024-03-01T00:00:00Z"), description: `About ${a}` }],
    });
    // The first video comes from the edge cache: only the others reach YouTube.
    const second = await owner.get(`/api/youtube/details?ids=${a},${b}`);
    expect(((await second.json()) as { videos: { id: string }[] }).videos.map((v) => v.id)).toEqual([a, b]);
    expect(asked).toEqual([[a, gone], [b]]);
  });

  it("refuses lists that are not 1 to 50 video ids", async () => {
    const owner = new Client(createApp({ webauthn: fakeWebAuthn, fetch: fakeYouTube().impl }));
    await signUpOwner(owner);
    expect((await owner.get("/api/youtube/details")).status).toBe(400);
    expect((await owner.get("/api/youtube/details?ids=nope")).status).toBe(400);
    const many = Array.from({ length: 51 }, () => freshId()).join(",");
    expect((await owner.get(`/api/youtube/details?ids=${many}`)).status).toBe(400);
  });

  it("is for signed-in accounts only", async () => {
    expect((await new Client().get("/api/youtube/details?ids=aaaaaaaaaaa")).status).toBe(401);
  });
});

describe("Website icons", () => {
  /** Every site has an apple-touch-icon. */
  async function fakeSite(input: URL | RequestInfo): Promise<Response> {
    const url = new URL(String(input));
    if (url.pathname === "/apple-touch-icon.png") return new Response(new Uint8Array(8), { headers: { "content-type": "image/png" } });
    return new Response("<html></html>", { headers: { "content-type": "text/html" } });
  }

  it("redirects to the icon, also when the answer is cached", async () => {
    const owner = new Client(createApp({ webauthn: fakeWebAuthn, fetch: fakeSite as typeof fetch }));
    await signUpOwner(owner);
    // A fresh site per run: the edge cache outlives a test.
    const site = `https://s${crypto.randomUUID().slice(0, 8)}.example.com`;
    for (let i = 0; i < 2; i++) {
      const res = await owner.get(`/api/icon?url=${encodeURIComponent(site)}`);
      expect(res.status).toBe(302);
      expect(res.headers.get("location")).toMatch(/^https:\/\//);
      expect(res.headers.get("x-content-type-options")).toBe("nosniff");
    }
  });
});
