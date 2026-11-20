import { describe, expect, it, vi } from "vitest";
import { admit, channelOf, playlistPage, popularPage, searchPage, videoDetails, videosById } from "./youtube.ts";

const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

describe("admit", () => {
  it("rejects a bad query before checking configuration", () => {
    const r = admit("   ", undefined);
    expect("response" in r && r.response.status).toBe(400);
  });
  it("reports a missing API key as not configured", () => {
    const r = admit("cats", undefined);
    expect("response" in r && r.response.status).toBe(503);
  });
  it("passes a normalized query", () => {
    expect(admit("  lofi   beats ", "k")).toEqual({ query: "lofi beats" });
  });
});

describe("searchPage", () => {
  const searchBody = {
    items: [{ id: { videoId: "abcdefghijk" }, snippet: { title: "One", channelTitle: "C", thumbnails: {} } }],
  };

  it("merges lengths and details into the results, asks for 50, and never leaks the key", async () => {
    const fetchImpl = vi.fn(async (url: URL | RequestInfo) => {
      const u = new URL(String(url));
      expect(u.searchParams.get("key")).toBe("API");
      return u.pathname.endsWith("/search")
        ? (expect(u.searchParams.get("maxResults")).toBe("50"), reply(200, searchBody))
        : (expect(u.searchParams.get("part")).toBe("contentDetails,statistics,snippet"),
          reply(200, {
            items: [
              {
                id: "abcdefghijk",
                contentDetails: { duration: "PT2M5S" },
                statistics: { viewCount: "42", likeCount: "7" },
                snippet: { description: "All about one" },
              },
            ],
          }));
    });
    const page = await searchPage("one", "API", fetchImpl as typeof fetch);
    expect(page instanceof Response).toBe(false);
    const text = JSON.stringify(page);
    expect(text).not.toContain("API");
    expect(JSON.parse(text)).toEqual({
      next: null,
      videos: [
        {
          id: "abcdefghijk",
          title: "One",
          channel: "C",
          thumbnail: "https://i.ytimg.com/vi/abcdefghijk/mqdefault.jpg",
          seconds: 125,
          views: 42,
          likes: 7,
          published: null,
          description: "All about one",
        },
      ],
    });
  });

  it("takes the age from the details when the search has none", async () => {
    const fetchImpl = vi.fn(async (url: URL | RequestInfo) =>
      new URL(String(url)).pathname.endsWith("/search")
        ? reply(200, searchBody)
        : reply(200, { items: [{ id: "abcdefghijk", snippet: { publishedAt: "2025-01-02T03:04:05Z" } }] }),
    );
    const page = await searchPage("one", "API", fetchImpl as typeof fetch);
    expect(!(page instanceof Response) && page.videos[0]?.published).toBe(Date.parse("2025-01-02T03:04:05Z"));
  });

  it("keeps results when the lengths call fails", async () => {
    const fetchImpl = vi.fn(async (url: URL | RequestInfo) =>
      new URL(String(url)).pathname.endsWith("/search") ? reply(200, searchBody) : reply(500, {}),
    );
    const page = await searchPage("one", "API", fetchImpl as typeof fetch);
    expect(!(page instanceof Response) && page.videos[0]?.seconds).toBeNull();
  });

  it("maps an exhausted quota to 429", async () => {
    const fetchImpl = vi.fn(async () => reply(403, { error: { errors: [{ reason: "quotaExceeded" }] } }));
    const page = await searchPage("x", "API", fetchImpl as typeof fetch);
    expect(page instanceof Response && page.status).toBe(429);
  });

  it("hides other upstream errors behind 502", async () => {
    const fetchImpl = vi.fn(async () => reply(400, { error: { message: "key=API invalid" } }));
    const res = await searchPage("x", "API", fetchImpl as typeof fetch);
    expect(res instanceof Response && res.status).toBe(502);
    expect(res instanceof Response && (await res.text()).includes("API")).toBe(false);
  });

  it("maps a network failure to 504", async () => {
    const fetchImpl = vi.fn(async () => {
      throw new Error("timeout");
    });
    const page = await searchPage("x", "API", fetchImpl as typeof fetch);
    expect(page instanceof Response && page.status).toBe(504);
  });
});

describe("videoDetails", () => {
  it("asks once for every id and leaves out what YouTube does not know", async () => {
    const fetchImpl = vi.fn(async (url: URL | RequestInfo) => {
      const u = new URL(String(url));
      expect(u.pathname.endsWith("/videos")).toBe(true);
      expect(u.searchParams.get("id")).toBe("aaaaaaaaaaa,bbbbbbbbbbb");
      expect(u.searchParams.get("part")).toBe("contentDetails,statistics,snippet");
      return reply(200, {
        items: [{ id: "aaaaaaaaaaa", contentDetails: { duration: "PT1M" }, statistics: { viewCount: "5" }, snippet: { publishedAt: "2024-01-01T00:00:00Z" } }],
      });
    });
    const found = await videoDetails(["aaaaaaaaaaa", "bbbbbbbbbbb"], "API", fetchImpl as typeof fetch);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    expect(found instanceof Map && [...found.keys()]).toEqual(["aaaaaaaaaaa"]);
    expect(found instanceof Map && found.get("aaaaaaaaaaa")).toMatchObject({ seconds: 60, views: 5, likes: null, published: Date.parse("2024-01-01T00:00:00Z") });
  });

  it("answers failures as responses that never carry the key", async () => {
    const quota = await videoDetails(["aaaaaaaaaaa"], "API", (async () => reply(403, { error: { errors: [{ reason: "quotaExceeded" }] } })) as typeof fetch);
    expect(quota instanceof Response && quota.status).toBe(429);
    const other = await videoDetails(["aaaaaaaaaaa"], "API", (async () => reply(400, { error: { message: "key=API bad" } })) as typeof fetch);
    expect(other instanceof Response && other.status).toBe(502);
    expect(other instanceof Response && (await other.text()).includes("API")).toBe(false);
    const down = await videoDetails(["aaaaaaaaaaa"], "API", (async () => {
      throw new Error("timeout");
    }) as typeof fetch);
    expect(down instanceof Response && down.status).toBe(504);
  });
});

const whole = (id: string, extra: Record<string, unknown> = {}) => ({
  id,
  snippet: { title: `Title & ${id}`, channelTitle: "Chan", publishedAt: "2024-02-02T00:00:00Z", description: "About" },
  contentDetails: { duration: "PT3M" },
  statistics: { viewCount: "10", likeCount: "2" },
  status: { embeddable: true, privacyStatus: "public" },
  ...extra,
});

describe("whole videos", () => {
  it("keeps the order asked and only what the embedded player can play", async () => {
    const fetchImpl = vi.fn(async () =>
      reply(200, {
        items: [
          whole("bbbbbbbbbbb"),
          whole("aaaaaaaaaaa"),
          whole("ccccccccccc", { status: { embeddable: false } }),
          whole("ddddddddddd", { snippet: { title: "Soon", liveBroadcastContent: "upcoming" } }),
        ],
      }),
    );
    const videos = await videosById(["aaaaaaaaaaa", "bbbbbbbbbbb", "ccccccccccc", "ddddddddddd"], "API", fetchImpl as typeof fetch);
    expect(Array.isArray(videos) && videos.map((v) => v.id)).toEqual(["aaaaaaaaaaa", "bbbbbbbbbbb"]);
    // Plain text: videos.list does not escape titles.
    expect(Array.isArray(videos) && videos[0]).toMatchObject({ title: "Title & aaaaaaaaaaa", seconds: 180, views: 10, likes: 2 });
  });

  it("reads popular videos a page at a time, in the region and category asked", async () => {
    const fetchImpl = vi.fn(async (url: URL | RequestInfo) => {
      const u = new URL(String(url));
      expect(u.searchParams.get("chart")).toBe("mostPopular");
      expect(u.searchParams.get("regionCode")).toBe("GB");
      expect(u.searchParams.get("videoCategoryId")).toBe("10");
      expect(u.searchParams.get("maxResults")).toBe("50");
      expect(u.searchParams.get("pageToken")).toBe("CDIQAA");
      return reply(200, { items: [whole("aaaaaaaaaaa")], nextPageToken: "CGQQAA" });
    });
    const page = await popularPage("API", fetchImpl as typeof fetch, { region: "GB", categoryId: "10", pageToken: "CDIQAA" });
    expect(!(page instanceof Response) && page).toMatchObject({ next: "CGQQAA", videos: [{ id: "aaaaaaaaaaa" }] });
  });

  it("reads a channel's uploads through its playlist", async () => {
    const fetchImpl = vi.fn(async (url: URL | RequestInfo) => {
      const u = new URL(String(url));
      if (u.pathname.endsWith("/channels")) return reply(200, { items: [{ snippet: { title: "Chan" }, contentDetails: { relatedPlaylists: { uploads: "UUxxxxxxxxxxxxxxxxxxxxxx" } } }] });
      if (u.pathname.endsWith("/playlistItems")) {
        expect(u.searchParams.get("playlistId")).toBe("UUxxxxxxxxxxxxxxxxxxxxxx");
        return reply(200, { items: [{ contentDetails: { videoId: "aaaaaaaaaaa" } }, { contentDetails: { videoId: "../bad" } }], nextPageToken: "EAAa" });
      }
      return reply(200, { items: [whole("aaaaaaaaaaa")] });
    });
    const channel = await channelOf("UCxxxxxxxxxxxxxxxxxxxxxx", "API", fetchImpl as typeof fetch);
    expect(channel).toEqual({ title: "Chan", uploads: "UUxxxxxxxxxxxxxxxxxxxxxx" });
    const page = await playlistPage("UUxxxxxxxxxxxxxxxxxxxxxx", "API", fetchImpl as typeof fetch);
    expect(!(page instanceof Response) && page).toMatchObject({ next: "EAAa", videos: [{ id: "aaaaaaaaaaa" }] });
    expect(await channelOf("UCxxxxxxxxxxxxxxxxxxxxxx", "API", (async () => reply(200, { items: [] })) as typeof fetch)).toBeNull();
  });
});
