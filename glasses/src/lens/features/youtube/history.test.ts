import { describe, expect, it } from "vitest";
import type { HistoryItem } from "../../../shared/api.ts";
import { resumeFrom, watchedPart } from "./history.ts";

const item = (position: number, seconds: number | null = 600): HistoryItem => ({
  id: "aaaaaaaaaaa",
  title: "Song",
  channel: "Adele",
  thumbnail: "",
  seconds,
  position,
  watchedAt: 0,
});

describe("watch history", () => {
  it("resumes where a video was left, but not from the very start or the end", () => {
    expect(resumeFrom(undefined)).toBe(0);
    expect(resumeFrom(item(8))).toBe(0);
    expect(resumeFrom(item(130))).toBe(130);
    expect(resumeFrom(item(590))).toBe(0);
    expect(resumeFrom(item(130, null))).toBe(130);
  });

  it("shows how much was watched only once it really started", () => {
    expect(watchedPart(item(8))).toBeUndefined();
    expect(watchedPart(item(150))).toBe(0.25);
    expect(watchedPart(item(900))).toBe(1);
    expect(watchedPart(item(150, null))).toBeUndefined();
  });
});
