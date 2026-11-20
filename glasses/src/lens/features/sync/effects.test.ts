import { describe, expect, it } from "vitest";
import type { ChatMessage, ChatReply } from "../../../shared/api.ts";
import { FRESH_MS, effectOf, nextToAct } from "./effects.ts";

const video = { id: "aaaaaaaaaaa", title: "Rain", channel: "C", thumbnail: "", seconds: 60 };
const NOW = 1_000_000;
const msg = (seq: number, reply: ChatReply, source: "console" | "glasses" = "console", createdAt = NOW): ChatMessage => ({
  id: `m${seq}`,
  seq,
  source,
  text: "x",
  reply,
  createdAt,
});

describe("effectOf", () => {
  it("plays what was asked for, from anywhere", () => {
    expect(effectOf(msg(1, { kind: "videos", query: "rain", videos: [video], autoplay: true }), "sent", NOW)).toEqual({ type: "watch", video });
    expect(effectOf(msg(1, { kind: "play", video }), "synced", NOW)).toEqual({ type: "watch", video });
  });

  it("brings results from the phone forward, but not the glasses' own", () => {
    const reply: ChatReply = { kind: "videos", query: "rain", videos: [video], autoplay: false };
    expect(effectOf(msg(1, reply), "synced", NOW)).toEqual({ type: "tab", tab: "youtube" });
    expect(effectOf(msg(1, reply, "glasses"), "sent", NOW)).toBeNull();
  });

  it("starts timers and opens apps", () => {
    expect(effectOf(msg(1, { kind: "timer", durationMs: 60_000 }), "synced", NOW)).toEqual({ type: "timer", durationMs: 60_000 });
    expect(effectOf(msg(1, { kind: "open", name: "Notes", view: "notes" }), "sent", NOW)).toEqual({ type: "tab", tab: "notes" });
    expect(effectOf(msg(1, { kind: "open", name: "Apps", view: "apps" }), "synced", NOW)).toEqual({ type: "tab", tab: "add" });
    expect(effectOf(msg(1, { kind: "open", name: "Github", url: "https://github.com/" }), "sent", NOW)).toEqual({
      type: "url",
      url: "https://github.com/",
    });
  });

  it("shows a note from the phone, and problems as a notice", () => {
    const note: ChatReply = { kind: "note", note: { id: "n1", text: "milk", createdAt: NOW } };
    expect(effectOf(msg(1, note), "synced", NOW)).toEqual({ type: "tab", tab: "notes" });
    expect(effectOf(msg(1, note, "glasses"), "sent", NOW)).toBeNull();
    expect(effectOf(msg(1, { kind: "error", message: "No app called xyz." }), "sent", NOW)).toEqual({ type: "notice", text: "No app called xyz." });
    expect(effectOf(msg(1, { kind: "help" }), "synced", NOW)).toBeNull();
  });

  it("never replays an old request", () => {
    expect(effectOf(msg(1, { kind: "play", video }, "console", NOW - FRESH_MS - 1), "initial", NOW)).toBeNull();
  });
});

describe("nextToAct", () => {
  const help: ChatReply = { kind: "help" };
  it("acts once, on the newest", () => {
    const r = nextToAct([msg(3, help), msg(5, help), msg(4, help)], "synced", 2);
    expect(r).toEqual({ message: msg(5, help), acted: 5 });
    expect(nextToAct([msg(5, help)], "synced", 5)).toEqual({ message: null, acted: 5 });
  });

  it("only records history on a new install", () => {
    expect(nextToAct([msg(9, help)], "initial", -1)).toEqual({ message: null, acted: 9 });
    expect(nextToAct([msg(9, help)], "sent", -1)).toEqual({ message: msg(9, help), acted: 9 });
  });
});
