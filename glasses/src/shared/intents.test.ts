import { describe, expect, it } from "vitest";
import { cleanUtterance, parseDuration, parseIntent, toQuery, wordsToNumbers } from "./intents.ts";

const MIN = 60_000;

describe("cleanUtterance", () => {
  it("drops the full stop and quotes dictation adds", () => {
    expect(cleanUtterance("  “Lofi   beats.” ")).toBe("Lofi beats");
    expect(cleanUtterance("what is love?")).toBe("what is love");
  });
});

describe("wordsToNumbers", () => {
  it("turns spelled numbers into digits", () => {
    expect(wordsToNumbers("twenty five minutes")).toBe("25 minutes");
    expect(wordsToNumbers("an hour")).toBe("1 hour");
    expect(wordsToNumbers("half an hour")).toBe("30 minutes");
    expect(wordsToNumbers("an hour and a half")).toBe("90 minutes");
    expect(wordsToNumbers("someone often")).toBe("someone often");
  });
});

describe("parseDuration", () => {
  it.each([
    ["5 minutes", 5 * MIN],
    ["90s", 90_000],
    ["1 hour 30 min", 90 * MIN],
    ["1.5 hours", 90 * MIN],
    ["5:30", 330_000],
    ["25", 25 * MIN],
    ["a minute", MIN],
    ["ten seconds", 10_000],
  ])("%s", (text, ms) => {
    expect(parseDuration(text)).toBe(ms);
  });
  it("is null without a number", () => {
    expect(parseDuration("set a")).toBeNull();
  });
});

describe("parseIntent", () => {
  it("searches YouTube by default", () => {
    expect(parseIntent("Lofi beats.")).toEqual({ kind: "videos", query: "Lofi beats", autoplay: false });
    expect(parseIntent("search for cat videos on YouTube")).toEqual({ kind: "videos", query: "cat videos", autoplay: false });
    expect(parseIntent("notebook reviews")).toEqual({ kind: "videos", query: "notebook reviews", autoplay: false });
    expect(parseIntent("playlist ideas")).toEqual({ kind: "videos", query: "playlist ideas", autoplay: false });
  });

  it("plays the top result when asked to play", () => {
    expect(parseIntent("Play rain sounds")).toEqual({ kind: "videos", query: "rain sounds", autoplay: true });
    expect(parseIntent("watch the keynote on youtube")).toEqual({ kind: "videos", query: "the keynote", autoplay: true });
    expect(parseIntent("play")).toMatchObject({ kind: "unclear" });
  });

  it("saves notes", () => {
    expect(parseIntent("Note: buy milk.")).toEqual({ kind: "note", text: "buy milk" });
    expect(parseIntent("take a note call mom at 6")).toEqual({ kind: "note", text: "call mom at 6" });
    expect(parseIntent("remember that the code is 4417")).toEqual({ kind: "note", text: "the code is 4417" });
    expect(parseIntent("notes")).toEqual({ kind: "open", target: "notes" });
  });

  it("starts timers", () => {
    expect(parseIntent("Set a timer for five minutes.")).toEqual({ kind: "timer", durationMs: 5 * MIN });
    expect(parseIntent("25 minute timer")).toEqual({ kind: "timer", durationMs: 25 * MIN });
    expect(parseIntent("timer 10")).toEqual({ kind: "timer", durationMs: 10 * MIN });
    expect(parseIntent("countdown 90 seconds")).toEqual({ kind: "timer", durationMs: 90_000 });
    expect(parseIntent("timer")).toEqual({ kind: "open", target: "timer" });
    expect(parseIntent("timer 30 hours")).toMatchObject({ kind: "unclear" });
  });

  it("opens apps", () => {
    expect(parseIntent("open YouTube")).toEqual({ kind: "open", target: "YouTube" });
    expect(parseIntent("go to github.com")).toEqual({ kind: "open", target: "github.com" });
    expect(parseIntent("launch the weather app")).toEqual({ kind: "open", target: "weather" });
    expect(parseIntent("go home")).toEqual({ kind: "open", target: "home" });
    expect(parseIntent("Companion")).toEqual({ kind: "open", target: "companion" });
  });

  it("answers help", () => {
    expect(parseIntent("Help")).toEqual({ kind: "help" });
    expect(parseIntent("what can you do?")).toEqual({ kind: "help" });
  });

  it("treats everything as a search on the YouTube screen", () => {
    expect(parseIntent("timer 5 minutes", "videos")).toEqual({ kind: "videos", query: "timer 5 minutes", autoplay: false });
    expect(parseIntent("play jazz", "videos")).toEqual({ kind: "videos", query: "jazz", autoplay: true });
  });

  it("rejects nothing", () => {
    expect(parseIntent(" . ")).toMatchObject({ kind: "unclear" });
  });
});

describe("toQuery", () => {
  it("keeps queries within the API limit, cut at a word", () => {
    const q = toQuery(`${"word ".repeat(40)}end`);
    expect(q.length).toBeLessThanOrEqual(100);
    expect(q.endsWith("word")).toBe(true);
  });
});
