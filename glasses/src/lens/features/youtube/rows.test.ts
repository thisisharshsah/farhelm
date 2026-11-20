import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { VideoItem } from "../../../shared/api.ts";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const video = (id: string): VideoItem => ({ id, title: `Video ${id}`, channel: "C", thumbnail: "", seconds: 60, views: 1, likes: 1 });
const ids = (videos: readonly VideoItem[]) => videos.map((v) => v.id);
const json = (body: unknown) => new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } });
const CHANNEL = "UCxxxxxxxxxxxxxxxxxxxxxx";
/** The nth video like a seed: "aaaaar00001". */
const like = (seed: string, n: number) => `${seed.slice(0, 5)}r${String(n).padStart(5, "0")}`;

/** The API as these tests see it: two seeds that share a channel, and rows two pages long. */
function fakeApi() {
  const asked: string[] = [];
  const impl = vi.fn(async (input: string | URL) => {
    const url = new URL(String(input), "https://lens.test");
    asked.push(`${url.pathname}?${url.searchParams}`);
    const seed = url.searchParams.get("seed");
    if (url.pathname === "/api/youtube/rows") {
      return json({
        rows: [
          { key: `related:${seed}`, kind: "related", subject: `Like ${seed}`, videos: [video(like(seed!, 1)), video(like(seed!, 2))], next: "P2" },
          { key: `channel:${CHANNEL}`, kind: "channel", subject: "Chan", videos: [video("chan0000001")], next: null },
          { key: "popular:10", kind: "popular", subject: "Music", videos: [video("popu0000001")], next: null },
        ],
      });
    }
    const key = url.searchParams.get("key");
    const page = url.searchParams.get("page");
    if (key === "popular:all") return json({ videos: [video("hot00000001")], next: null });
    const a = "aaaaaaaaaaa";
    if (key === `related:${a}` && page === "P2") return json({ videos: [video(like(a, 2)), video(like(a, 3))], next: "P3" });
    if (key === `related:${a}` && page === "P3") return json({ videos: [video(like(a, 3))], next: "P4" });
    if (key === `related:${a}` && page === "P4") return json({ videos: [video(like(a, 4))], next: null });
    if (key === "search:lofi" && !page) return json({ videos: [video("lofi0000001"), video("lofi0000002"), video("lofi0000003")], next: null });
    return new Response("{}", { status: 404 });
  });
  return { asked, impl };
}

/** Runs a hook in a component, as the app does. */
function renderHook<T>(hook: () => T) {
  const result = { current: undefined as T };
  function Probe() {
    result.current = hook();
    return null;
  }
  const root = createRoot(document.createElement("div"));
  act(() => root.render(createElement(Probe)));
  return { result, unmount: () => act(() => root.unmount()) };
}

const settle = () =>
  act(async () => {
    for (let i = 0; i < 5; i++) await new Promise((r) => setTimeout(r, 0));
  });

describe("rows on the glasses", () => {
  beforeEach(() => vi.resetModules());
  afterEach(() => vi.unstubAllGlobals());

  it("takes recommendations from the video playing, then those watched, then what is popular", async () => {
    const { feedSources } = await import("./rows.ts");
    const history = Array.from({ length: 12 }, (_, i) => ({ id: `h${String(i).padStart(10, "0")}`, title: `H${i}` }));
    const sources = feedSources([{ id: "playing0001", title: "P" }, ...history], { id: "playing0001", title: "P" });
    expect(sources[0]).toEqual({ seed: "playing0001", title: "P" });
    expect(sources.filter((s) => "seed" in s)).toHaveLength(8);
    expect(sources.at(-1)).toEqual({ row: "popular:all" });
    expect(feedSources([])).toEqual([{ row: "popular:all" }]);
  });

  it("adds the next video's rows when asked, showing a row two videos share once", async () => {
    const api = fakeApi();
    vi.stubGlobal("fetch", api.impl);
    const { feedSources, useFeed } = await import("./rows.ts");
    const sources = feedSources([
      { id: "aaaaaaaaaaa", title: "A" },
      { id: "bbbbbbbbbbb", title: "B" },
    ]);
    const { result, unmount } = renderHook(() => useFeed(sources));
    await settle();
    expect(result.current.entries.map((e) => [e.row.key, e.from])).toEqual([
      ["related:aaaaaaaaaaa", 0],
      [`channel:${CHANNEL}`, 0],
      ["popular:10", 0],
    ]);
    act(() => result.current.more());
    await settle();
    expect(result.current.entries.map((e) => e.row.key)).toEqual(["related:aaaaaaaaaaa", `channel:${CHANNEL}`, "popular:10", "related:bbbbbbbbbbb"]);
    act(() => result.current.more());
    await settle();
    expect(result.current.entries.at(-1)?.row.key).toBe("popular:all");
    expect(result.current.done).toBe(true);
    unmount();
  });

  it("grows a row a page at a time, skipping pages with nothing new, to its end", async () => {
    const api = fakeApi();
    vi.stubGlobal("fetch", api.impl);
    const { feedSources, loadMore, useFeed } = await import("./rows.ts");
    const { result, unmount } = renderHook(() => useFeed(feedSources([{ id: "aaaaaaaaaaa", title: "A" }])));
    await settle();
    act(() => loadMore("related:aaaaaaaaaaa"));
    await settle();
    expect(result.current.entries[0]!.row.next).toBe("P3");
    act(() => loadMore("related:aaaaaaaaaaa"));
    await settle();
    // Repeats stay out; P3 adds nothing new, so P4 is asked for at once.
    expect(ids(result.current.entries[0]!.row.videos)).toEqual([1, 2, 3, 4].map((n) => like("aaaaaaaaaaa", n)));
    expect(result.current.entries[0]!.row.next).toBeNull();
    const asked = api.asked.length;
    act(() => loadMore("related:aaaaaaaaaaa"));
    await settle();
    expect(api.asked.length).toBe(asked);
    unmount();
  });

  it("starts a results row from the answer, grows it, and starts again for a new answer", async () => {
    const api = fakeApi();
    vi.stubGlobal("fetch", api.impl);
    const { loadMore, rowVideos, useRow } = await import("./rows.ts");
    let origin = "m1";
    const { result, unmount } = renderHook(() =>
      useRow({ key: "search:lofi", kind: "search", subject: "lofi", videos: [video("lofi0000001")], next: "", origin }),
    );
    expect(ids(result.current!.videos)).toEqual(["lofi0000001"]);
    await settle();
    act(() => loadMore("search:lofi"));
    await settle();
    expect(ids(result.current!.videos)).toEqual(["lofi0000001", "lofi0000002", "lofi0000003"]);
    expect(ids(rowVideos("search:lofi")!)).toHaveLength(3);
    origin = "m2";
    unmount();
    const again = renderHook(() => useRow({ key: "search:lofi", kind: "search", subject: "lofi", videos: [video("lofi0000009")], next: "", origin }));
    await settle();
    expect(ids(again.result.current!.videos)).toEqual(["lofi0000009"]);
    again.unmount();
  });
});
