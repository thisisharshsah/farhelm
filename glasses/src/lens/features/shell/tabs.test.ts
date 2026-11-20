import { describe, expect, it } from "vitest";
import { BUILT_INS, iconUrl, siteTabId, tabsFor } from "./tabs.ts";

describe("tabsFor", () => {
  it("puts Lens's apps first, then the account's websites in order, then Add", () => {
    const tabs = tabsFor([
      { id: "a", name: "Github", url: "https://github.com/", position: 0 },
      { id: "b", name: "Wikipedia", url: "https://en.wikipedia.org/", position: 1 },
    ]);
    expect(tabs.slice(0, BUILT_INS.length)).toEqual(BUILT_INS);
    expect(tabs.slice(BUILT_INS.length).map((t) => t.id)).toEqual([siteTabId("a"), siteTabId("b"), "add"]);
  });
});

describe("iconUrl", () => {
  it("asks for the site's origin only", () => {
    expect(iconUrl("https://en.wikipedia.org/wiki/Glasses")).toBe("/api/icon?url=https%3A%2F%2Fen.wikipedia.org");
    expect(iconUrl("https://www.youtube.com", "glyph")).toBe("/api/icon?url=https%3A%2F%2Fwww.youtube.com&fit=glyph");
  });
});
