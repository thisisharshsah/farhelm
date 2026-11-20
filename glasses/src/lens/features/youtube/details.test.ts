import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { VideoItem } from "../../../shared/api.ts";

const video = (id: string, extra: Partial<VideoItem> = {}): VideoItem => ({
  id,
  title: `Video ${id}`,
  channel: "Channel",
  thumbnail: "",
  seconds: null,
  ...extra,
});

const answer = (ids: string[]) =>
  new Response(
    JSON.stringify({ videos: ids.map((id) => ({ id, seconds: 61, views: 900, likes: 12, published: 1_700_000_000_000, description: `About ${id}` })) }),
    { status: 200, headers: { "content-type": "application/json" } },
  );

/** The module afresh for each test: it keeps answers for the session. */
const load = () => import("./details.ts");
const askedIds = (fetchMock: ReturnType<typeof vi.fn>) =>
  fetchMock.mock.calls.map(([url]) => new URL(String(url), "https://lens.test").searchParams.get("ids"));

describe("video details on the glasses", () => {
  beforeEach(() => {
    vi.resetModules();
    vi.useFakeTimers({ toFake: ["setTimeout", "Date"] });
  });
  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it("asks once for what every list lacks, then fills it in", async () => {
    const fetchMock = vi.fn(async () => answer(["aaaaaaaaaaa", "bbbbbbbbbbb"]));
    vi.stubGlobal("fetch", fetchMock);
    const { want, withDetails, lacksDetails } = await load();
    const history = video("aaaaaaaaaaa");
    expect(lacksDetails(history)).toBe(true);
    expect(lacksDetails(video("ccccccccccc", { views: 5 }))).toBe(false);

    want(["aaaaaaaaaaa"]);
    want(["bbbbbbbbbbb", "aaaaaaaaaaa"]);
    await vi.advanceTimersByTimeAsync(50);
    expect(askedIds(fetchMock)).toEqual(["aaaaaaaaaaa,bbbbbbbbbbb"]);
    expect(withDetails(history)).toMatchObject({ seconds: 61, views: 900, likes: 12, published: 1_700_000_000_000, description: "About aaaaaaaaaaa" });
    // What a video already has wins.
    expect(withDetails(video("aaaaaaaaaaa", { seconds: 300 })).seconds).toBe(300);

    want(["aaaaaaaaaaa"]);
    await vi.advanceTimersByTimeAsync(50);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("remembers videos YouTube does not know, so they are not asked for again", async () => {
    const fetchMock = vi.fn(async () => answer([]));
    vi.stubGlobal("fetch", fetchMock);
    const { want, withDetails } = await load();
    want(["ddddddddddd"]);
    await vi.advanceTimersByTimeAsync(50);
    want(["ddddddddddd"]);
    await vi.advanceTimersByTimeAsync(50);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(withDetails(video("ddddddddddd")).views).toBeUndefined();
  });

  it("asks again after a failure only once the wait is over", async () => {
    const fetchMock = vi.fn(async () => new Response("{}", { status: 503 }));
    vi.stubGlobal("fetch", fetchMock);
    const { want } = await load();
    want(["eeeeeeeeeee"]);
    await vi.advanceTimersByTimeAsync(50);
    want(["eeeeeeeeeee"]);
    await vi.advanceTimersByTimeAsync(50);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(30_000);
    want(["eeeeeeeeeee"]);
    await vi.advanceTimersByTimeAsync(50);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("splits long lists into requests of 50", async () => {
    const fetchMock = vi.fn(async (url: string) => answer((new URL(url, "https://lens.test").searchParams.get("ids") ?? "").split(",")));
    vi.stubGlobal("fetch", fetchMock);
    const { want } = await load();
    want(Array.from({ length: 120 }, (_, i) => `v${String(i).padStart(10, "0")}`));
    await vi.advanceTimersByTimeAsync(50);
    expect(askedIds(fetchMock).map((ids) => ids?.split(",").length)).toEqual([50, 50, 20]);
  });
});
