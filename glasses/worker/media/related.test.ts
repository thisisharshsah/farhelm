import { describe, expect, it } from "vitest";
import { cleanChannel, cleanTitle, parseFacts, relatedQuery } from "./related.ts";

const facts = (over: Partial<Parameters<typeof relatedQuery>[0]>) => ({ title: "", channel: "", tags: [], categoryId: "", ...over });

describe("relatedQuery", () => {
  it("follows the artist for music", () => {
    expect(relatedQuery(facts({ title: "Adele - Hello (Official Music Video)", categoryId: "10" }))).toBe("Adele");
    expect(relatedQuery(facts({ title: "Drake - One Dance ft. Wizkid & Kyla", categoryId: "10" }))).toBe("Drake");
    expect(relatedQuery(facts({ title: "Shake It Off", channel: "TaylorSwiftVEVO", categoryId: "10" }))).toBe("TaylorSwift");
    expect(relatedQuery(facts({ title: "Hello", channel: "Adele - Topic", categoryId: "10" }))).toBe("Adele");
  });

  it("uses the video's tags, then its title, for everything else", () => {
    expect(relatedQuery(facts({ title: "How engines work", tags: ["engines", "cars", "a", "physics explained"] }))).toBe(
      "engines cars physics explained",
    );
    expect(relatedQuery(facts({ title: "[4K] Rainy night walk in Tokyo | ASMR city sounds" }))).toBe("Rainy night walk in Tokyo");
  });

  it("drops labels that say nothing about the song or the artist", () => {
    expect(cleanTitle("Coldplay - Yellow (Official Video) [4K Remaster]")).toBe("Coldplay - Yellow");
    expect(cleanChannel("AdeleVEVO")).toBe("Adele");
    expect(cleanChannel("Daft Punk - Topic")).toBe("Daft Punk");
  });
});

describe("parseFacts", () => {
  it("reads the snippet defensively, channel id included", () => {
    expect(parseFacts({ items: [] })).toBeNull();
    expect(parseFacts({ items: [{ snippet: { title: "T", tags: ["a", 3] } }] })).toEqual({ title: "T", channel: "", channelId: "", tags: ["a"], categoryId: "" });
    expect(parseFacts({ items: [{ snippet: { title: "T", channelTitle: "C", channelId: "UCxxxxxxxxxxxxxxxxxxxxxx", categoryId: "10" } }] })).toMatchObject({
      channel: "C",
      channelId: "UCxxxxxxxxxxxxxxxxxxxxxx",
      categoryId: "10",
    });
  });
});
