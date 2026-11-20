import { describe, expect, it } from "vitest";
import { lensField, lensMargin, lensPixels } from "./lensField.ts";

describe("lensField", () => {
  const lens = { rim: 0.6, reach: 10 };
  const field = lensField(200, 60, lens);
  const at = (x: number, y: number) => {
    // x and y from the capsule's centre, in px.
    const i = Math.round(y + field.height / 2 - 0.5) * field.width + Math.round(x + field.width / 2 - 0.5);
    return { dx: field.dx[i]!, dy: field.dy[i]! };
  };

  it("covers the shape and a margin to read past its edge", () => {
    expect(field.width).toBe(200 + 2 * lensMargin(lens));
    expect(field.height).toBe(60 + 2 * lensMargin(lens));
  });

  it("reads straight through the middle and outside the shape", () => {
    expect(at(0, 0)).toEqual({ dx: 0, dy: 0 });
    expect(at(0, 40)).toEqual({ dx: 0, dy: 0 });
  });

  it("bends the rim outward, like the edge of a drop of water", () => {
    // Near the right end and near the top edge, the rim reads from further out.
    expect(at(95, 0).dx).toBeGreaterThan(0);
    expect(at(0, -27).dy).toBeLessThan(0);
    expect(at(-95, 0).dx).toBeLessThan(0);
  });

  it("encodes moves around grey for feDisplacementMap", () => {
    const px = lensPixels(field);
    const mid = (Math.floor(field.height / 2) * field.width + Math.floor(field.width / 2)) * 4;
    expect([px[mid], px[mid + 1], px[mid + 3]]).toEqual([128, 128, 255]);
  });
});
