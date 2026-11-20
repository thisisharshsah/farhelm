import { describe, expect, it } from "vitest";
import type { ChatMessage } from "../shared/api.ts";
import { cursorOf, mergePage, type ChatState } from "./chat.ts";

const msg = (seq: number): ChatMessage => ({
  id: `m${seq}`,
  seq,
  source: "glasses",
  text: `t${seq}`,
  reply: { kind: "help" },
  createdAt: seq,
});

describe("mergePage", () => {
  const start: ChatState = { items: [msg(1), msg(2)], clearedThrough: 0 };

  it("adds new messages in order without duplicates", () => {
    const next = mergePage(start, { items: [msg(4), msg(2), msg(3)], clearedThrough: 0 }, 50);
    expect(next.items.map((m) => m.seq)).toEqual([1, 2, 3, 4]);
  });

  it("returns the same state when nothing changed", () => {
    expect(mergePage(start, { items: [msg(2)], clearedThrough: 0 }, 50)).toBe(start);
  });

  it("drops what another device cleared", () => {
    const next = mergePage(start, { items: [msg(5)], clearedThrough: 2 }, 50);
    expect(next).toEqual({ items: [msg(5)], clearedThrough: 2 });
    expect(cursorOf({ items: [], clearedThrough: 7 })).toBe(7);
  });

  it("keeps only the newest", () => {
    const next = mergePage(start, { items: [msg(3), msg(4)], clearedThrough: 0 }, 3);
    expect(next.items.map((m) => m.seq)).toEqual([2, 3, 4]);
  });
});
