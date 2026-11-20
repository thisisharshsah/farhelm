import { describe, expect, it } from "vitest";
import { pickNext } from "./focus.ts";

// A 2x2 grid of 100x100 tiles.
const tiles = [
  { x: 0, y: 0, width: 100, height: 100 },
  { x: 110, y: 0, width: 100, height: 100 },
  { x: 0, y: 110, width: 100, height: 100 },
  { x: 110, y: 110, width: 100, height: 100 },
];

describe("pickNext", () => {
  it("moves within a grid", () => {
    const [topLeft, ...rest] = tiles;
    expect(pickNext(topLeft!, rest, "right")).toBe(0);
    expect(pickNext(topLeft!, rest, "down")).toBe(1);
  });
  it("prefers the aligned neighbour over the diagonal one", () => {
    expect(pickNext(tiles[0]!, [tiles[3]!, tiles[2]!], "down")).toBe(1);
  });
  it("returns -1 when nothing lies that way", () => {
    expect(pickNext(tiles[0]!, tiles.slice(1), "up")).toBe(-1);
  });
});
