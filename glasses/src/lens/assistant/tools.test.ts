import { describe, expect, it, vi } from "vitest";
import type { ChatMessage, ChatReply, VideoItem } from "../../shared/api.ts";
import type { PlayerControls } from "../features/youtube/player.ts";
import { lensTools, registerLensTools, resultNumber, type ModelContext, type ModelContextTool, type ToolDeps } from "./tools.ts";

const video = (n: number): VideoItem => ({ id: `vid${String(n).padStart(8, "0")}`, title: `Video ${n}`, channel: "C", thumbnail: "", seconds: 60 * n });
const reply = (r: ChatReply): ChatMessage => ({ id: "m1", seq: 1, source: "glasses", text: "x", reply: r, createdAt: 0 });

function deps(over: Partial<ToolDeps> = {}): ToolDeps {
  return {
    send: vi.fn(async () => reply({ kind: "help" })),
    play: vi.fn(async (v: VideoItem) => reply({ kind: "play", video: v })),
    show: vi.fn(),
    results: () => [video(1), video(2), video(3)],
    player: () => null,
    status: () => ({ app: "YouTube" }),
    ...over,
  };
}

const tool = (d: ToolDeps, name: string): ModelContextTool => {
  const found = lensTools(() => d).find((t) => t.name === name);
  if (!found) throw new Error(`no tool ${name}`);
  return found;
};

describe("registration", () => {
  const names = lensTools(() => deps()).map((t) => t.name);

  it("uses short, distinct, unreserved names", () => {
    const reserved = ["openUrl", "goBack", "goForward", "reload", "getCurrentUrl", "getPageTitle", "getPageText"];
    expect(new Set(names.map((n) => n.slice(0, 57))).size).toBe(names.length);
    expect(names.filter((n) => reserved.includes(n))).toEqual([]);
    for (const n of names) expect(n).toMatch(/^[A-Za-z0-9_.-]{1,57}$/);
  });

  it("keeps descriptions within Meta's limits", () => {
    for (const t of lensTools(() => deps())) {
      expect(t.description.length).toBeLessThanOrEqual(1024);
      for (const p of Object.values(t.inputSchema.properties)) expect(p.description.length).toBeLessThanOrEqual(256);
    }
  });

  it("registers every tool whatever registerTool returns or throws", () => {
    const seen: string[] = [];
    const ctx: ModelContext = {
      registerTool(t) {
        seen.push(t.name);
        if (t.name === "lens_note") throw new Error("boom");
        if (t.name === "lens_play") return Promise.reject(new Error("later"));
        return t.name === "lens_open" ? { handle: 1 } : undefined;
      },
    };
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const count = registerLensTools(ctx, () => deps(), new AbortController().signal);
    expect(seen).toEqual(names);
    expect(count).toBe(names.length - 1);
    error.mockRestore();
  });
});

describe("tools", () => {
  it("searches through the chat on the YouTube screen and numbers the results", async () => {
    const d = deps({ send: vi.fn(async () => reply({ kind: "videos", query: "rain", videos: [video(1), video(2)], autoplay: false })) });
    const result = (await tool(d, "lens_search").execute({ query: " rain " })) as { top: string[]; next_action: string };
    expect(d.show).toHaveBeenCalledWith("youtube");
    expect(d.send).toHaveBeenCalledWith("rain", "videos", undefined);
    expect(result.top).toEqual(["1. Video 1 (C), 1:00", "2. Video 2 (C), 2:00"]);
    expect(result.next_action).toMatch(/Stop and talk/);
  });

  it("plays a result by number, or searches and plays", async () => {
    const d = deps();
    expect(await tool(d, "lens_play").execute({ what: "the second one" })).toMatchObject({ playing: "Video 2" });
    expect(d.play).toHaveBeenCalledWith(video(2), undefined);
    expect(await tool(d, "lens_play").execute({ what: "7" })).toMatchObject({ error: true });
    await tool(d, "lens_play").execute({ what: "rain sounds" });
    expect(d.send).toHaveBeenCalledWith("play rain sounds", "videos", undefined);
  });

  it("validates what the assistant sends", async () => {
    const d = deps();
    expect(await tool(d, "lens_timer").execute({ minutes: -2 })).toMatchObject({ error: true });
    expect(await tool(d, "lens_timer").execute({ minutes: "soon" })).toMatchObject({ error: true });
    expect(await tool(d, "lens_note").execute({})).toMatchObject({ error: true });
    expect(d.send).not.toHaveBeenCalled();
  });

  it("starts a timer and shows it", async () => {
    const d = deps({ send: vi.fn(async () => reply({ kind: "timer", durationMs: 600_000 })) });
    expect(await tool(d, "lens_timer").execute({ minutes: 10 })).toMatchObject({ timer: "10 min" });
    expect(d.send).toHaveBeenCalledWith("timer 10 minutes", "auto", undefined);
    expect(d.show).toHaveBeenCalledWith("timer");
  });

  it("controls the video only when one is open", async () => {
    expect(await tool(deps(), "lens_video").execute({ action: "pause" })).toMatchObject({ error: true });
    const player: PlayerControls = {
      play: vi.fn(),
      pause: vi.fn(),
      skip: vi.fn(),
      restart: vi.fn(),
      next: vi.fn(() => true),
      queue: () => [video(4)],
      state: () => ({ title: "Rain", playing: true, at: 70, total: 600 }),
    };
    const d = deps({ player: () => player });
    expect(await tool(d, "lens_video").execute({ action: "back", seconds: 30 })).toMatchObject({ position: "1:10 of 10:00" });
    expect(player.skip).toHaveBeenCalledWith(-30);
    await tool(d, "lens_video").execute({ action: "Pause" });
    expect(player.pause).toHaveBeenCalled();
    expect(await tool(d, "lens_video").execute({ action: "dance" })).toMatchObject({ error: true });
    expect(await tool(d, "lens_video").execute({ action: "next" })).toMatchObject({ playing: "Video 4" });
    expect(player.next).toHaveBeenCalled();
    expect(player.skip).toHaveBeenCalledTimes(1);
  });

  it("saves a note, then shows Notes", async () => {
    const d = deps({ send: vi.fn(async () => reply({ kind: "note", note: { id: "n1", text: "milk", createdAt: 0 } })) });
    expect(await tool(d, "lens_note").execute({ text: "milk" })).toMatchObject({ saved: "milk" });
    expect(d.send).toHaveBeenCalledWith("note milk", "auto", undefined);
    expect(d.show).toHaveBeenCalledWith("notes");
  });

  it("forwards the deadline signal", async () => {
    const d = deps();
    const signal = new AbortController().signal;
    await tool(d, "lens_open").execute({ name: "notes" }, { signal });
    expect(d.send).toHaveBeenCalledWith("open notes", "auto", signal);
  });
});

describe("resultNumber", () => {
  it.each([
    ["2", 2],
    ["number two", 2],
    ["the second one", 2],
    ["one", 1],
    ["the last one", 3],
    ["rain sounds", null],
    ["constructor", null],
  ])("%s", (text, n) => {
    expect(resultNumber(text, 3)).toBe(n);
  });
});
