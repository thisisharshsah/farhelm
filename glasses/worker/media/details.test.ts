import { describe, expect, it } from "vitest";
import { parseIds } from "./details.ts";

describe("parseIds", () => {
  it("reads 1 to 50 video ids, each once", () => {
    expect(parseIds("aaaaaaaaaaa, bbbbbbbbbbb,aaaaaaaaaaa")).toEqual(["aaaaaaaaaaa", "bbbbbbbbbbb"]);
    expect(parseIds(Array.from({ length: 50 }, (_, i) => `video${String(i).padStart(6, "0")}`).join(","))).toHaveLength(50);
  });
  it("refuses none, too many, and anything that is not a video id", () => {
    expect(parseIds(undefined)).toBeNull();
    expect(parseIds(" , ")).toBeNull();
    expect(parseIds(Array.from({ length: 51 }, (_, i) => `video${String(i).padStart(6, "0")}`).join(","))).toBeNull();
    expect(parseIds("aaaaaaaaaaa,../etc/pass")).toBeNull();
  });
});
