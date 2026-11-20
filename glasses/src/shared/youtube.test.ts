import { describe, expect, it } from "vitest";
import {
  ageOf,
  compactCount,
  decodeEntities,
  formatDuration,
  isChannelId,
  isPageToken,
  nextPageOf,
  normalizeQuery,
  parseDetails,
  parseIsoDuration,
  parseRowKey,
  parseSearchList,
  parseVideoList,
  rowKey,
  shortDescription,
} from "./youtube.ts";

describe("normalizeQuery", () => {
  it("trims and collapses whitespace", () => {
    expect(normalizeQuery("  lofi   beats \n")).toBe("lofi beats");
  });
  it("rejects empty and over-long queries", () => {
    expect(normalizeQuery("   ")).toBeNull();
    expect(normalizeQuery(null)).toBeNull();
    expect(normalizeQuery("x".repeat(101))).toBeNull();
  });
});

describe("durations", () => {
  it("parses ISO 8601", () => {
    expect(parseIsoDuration("PT1H2M3S")).toBe(3723);
    expect(parseIsoDuration("PT45S")).toBe(45);
    expect(parseIsoDuration("P1DT1S")).toBe(86401);
    expect(parseIsoDuration("P0D")).toBe(0);
  });
  it("rejects malformed values", () => {
    expect(parseIsoDuration("PT")).toBeNull();
    expect(parseIsoDuration("1:00")).toBeNull();
    expect(parseIsoDuration(42)).toBeNull();
  });
  it("formats", () => {
    expect(formatDuration(75)).toBe("1:15");
    expect(formatDuration(3723)).toBe("1:02:03");
    expect(formatDuration(-5)).toBe("0:00");
  });
});

describe("parseSearchList", () => {
  it("keeps well-formed videos and skips the rest", () => {
    const body = {
      items: [
        {
          id: { kind: "youtube#video", videoId: "dQw4w9WgXcQ" },
          snippet: {
            title: "Rock &amp; Roll &#39;87",
            channelTitle: "Chan",
            publishedAt: "2009-10-25T06:57:33Z",
            description: "Official video https://example.com #rick",
            thumbnails: { medium: { url: "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg" } },
          },
        },
        { id: { kind: "youtube#channel", channelId: "UC123" }, snippet: {} },
        { id: { videoId: "bad id" }, snippet: {} },
        "junk",
      ],
    };
    expect(parseSearchList(body)).toEqual([
      {
        id: "dQw4w9WgXcQ",
        title: "Rock & Roll '87",
        channel: "Chan",
        thumbnail: "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg",
        published: Date.parse("2009-10-25T06:57:33Z"),
        description: "Official video",
      },
    ]);
  });
  it("builds the thumbnail from the id unless YouTube's own is given", () => {
    const [v] = parseSearchList({ items: [{ id: { videoId: "abcdefghijk" }, snippet: { thumbnails: { medium: { url: "https://evil.example/x.jpg" } } } }] });
    expect(v?.thumbnail).toBe("https://i.ytimg.com/vi/abcdefghijk/mqdefault.jpg");
  });
  it("tolerates a missing or wrong body", () => {
    expect(parseSearchList(null)).toEqual([]);
    expect(parseSearchList({ items: "no" })).toEqual([]);
  });
});

describe("parseDetails", () => {
  it("reads length, views, likes, age and description, tolerating what is missing", () => {
    const map = parseDetails({
      items: [
        {
          id: "abcdefghijk",
          contentDetails: { duration: "PT3M" },
          statistics: { viewCount: "1234567", likeCount: "8900" },
          snippet: { description: "Line one\n\nLine two https://x.y", publishedAt: "2024-05-01T10:00:00Z" },
        },
        { id: "zyxwvutsrqp", contentDetails: { duration: "P0D" }, statistics: { viewCount: "oops" } },
      ],
    });
    expect(map.get("abcdefghijk")).toEqual({
      seconds: 180,
      views: 1234567,
      likes: 8900,
      published: Date.parse("2024-05-01T10:00:00Z"),
      description: "Line one Line two",
    });
    expect(map.get("zyxwvutsrqp")).toEqual({ seconds: null, views: null, likes: null, published: null, description: "" });
  });
});

describe("rows", () => {
  it("reads and writes row keys", () => {
    expect(parseRowKey("related:abcdefghijk")).toEqual({ kind: "related", id: "abcdefghijk" });
    expect(parseRowKey("channel:UCxxxxxxxxxxxxxxxxxxxxxx")).toEqual({ kind: "channel", id: "UCxxxxxxxxxxxxxxxxxxxxxx" });
    expect(parseRowKey("popular:all")).toEqual({ kind: "popular", category: null });
    expect(parseRowKey("popular:10")).toEqual({ kind: "popular", category: "10" });
    // A query may hold colons; it is normalized like any search.
    expect(parseRowKey("search:  lofi:  beats ")).toEqual({ kind: "search", query: "lofi: beats" });
    for (const key of ["search:lofi", "related:abcdefghijk", "channel:UCxxxxxxxxxxxxxxxxxxxxxx", "popular:all", "popular:10"]) {
      expect(rowKey(parseRowKey(key)!)).toBe(key);
    }
  });

  it("refuses anything else", () => {
    for (const key of [null, "", "related", "related:short", "channel:UCshort", "popular:music", "search:", "watch:abcdefghijk"]) {
      expect(parseRowKey(key)).toBeNull();
    }
    expect(isChannelId("UCxxxxxxxxxxxxxxxxxxxxxx")).toBe(true);
    expect(isChannelId("UUxxxxxxxxxxxxxxxxxxxxxx")).toBe(false);
    expect(isPageToken("CDIQAA")).toBe(true);
    expect(isPageToken("../x")).toBe(false);
    expect(nextPageOf({ nextPageToken: "CDIQAA" })).toBe("CDIQAA");
    expect(nextPageOf({ nextPageToken: "a b" })).toBeNull();
  });
});

describe("parseVideoList", () => {
  it("reads whole videos, keeping only what plays embedded", () => {
    const item = (id: string, extra: Record<string, unknown> = {}) => ({
      id,
      snippet: { title: "Tom & Jerry", channelTitle: "C", publishedAt: "2024-05-01T10:00:00Z", description: "Hi" },
      contentDetails: { duration: "PT1M" },
      statistics: { viewCount: "7" },
      status: { embeddable: true },
      ...extra,
    });
    const videos = parseVideoList({
      items: [item("abcdefghijk"), item("bbbbbbbbbbb", { status: { embeddable: false } }), item("ccccccccccc", { status: { privacyStatus: "private" } }), { id: "bad" }],
    });
    expect(videos).toEqual([
      {
        id: "abcdefghijk",
        title: "Tom & Jerry",
        channel: "C",
        thumbnail: "https://i.ytimg.com/vi/abcdefghijk/mqdefault.jpg",
        seconds: 60,
        views: 7,
        likes: null,
        published: Date.parse("2024-05-01T10:00:00Z"),
        description: "Hi",
      },
    ]);
    expect(parseVideoList(null)).toEqual([]);
  });
});

describe("details on the glasses", () => {
  it("counts the way YouTube does", () => {
    expect(compactCount(950)).toBe("950");
    expect(compactCount(1234)).toBe("1.2K");
    expect(compactCount(1_234_567)).toBe("1.2M");
    expect(compactCount(250_000_000)).toBe("250M");
    expect(compactCount(2_100_000_000)).toBe("2.1B");
  });
  it("says how long ago", () => {
    const now = Date.parse("2026-11-18T12:00:00Z");
    expect(ageOf(now - 3_600_000, now)).toBe("today");
    expect(ageOf(now - 3 * 86_400_000, now)).toBe("3 days ago");
    expect(ageOf(now - 15 * 86_400_000, now)).toBe("2 weeks ago");
    expect(ageOf(now - 40 * 86_400_000, now)).toBe("1 month ago");
    expect(ageOf(now - 3 * 365 * 86_400_000, now)).toBe("3 years ago");
  });
  it("keeps a description short and cut at a word", () => {
    const long = shortDescription("word ".repeat(100));
    expect(long.length).toBeLessThanOrEqual(281);
    expect(long.endsWith("word…")).toBe(true);
  });
});

describe("decodeEntities", () => {
  it("decodes numeric entities", () => {
    expect(decodeEntities("&#9733; A &lt;b&gt;")).toBe("★ A <b>");
  });
});
