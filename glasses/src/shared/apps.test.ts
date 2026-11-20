import { describe, expect, it } from "vitest";
import { appKey, builtInFor, nameFromUrl, normalizeAppUrl } from "./apps.ts";

describe("normalizeAppUrl", () => {
  it("adds https to a bare domain and drops the fragment", () => {
    expect(normalizeAppUrl(" nytimes.com ")?.href).toBe("https://nytimes.com/");
    expect(normalizeAppUrl("https://x.com/a#b")?.href).toBe("https://x.com/a");
  });
  it("rejects http, credentials, other schemes and junk", () => {
    expect(normalizeAppUrl("http://x.com")).toBeNull();
    expect(normalizeAppUrl("https://user:pw@x.com")).toBeNull();
    expect(normalizeAppUrl("javascript:alert(1)")).toBeNull();
    expect(normalizeAppUrl("hello")).toBeNull();
    expect(normalizeAppUrl("")).toBeNull();
  });
});

describe("nameFromUrl", () => {
  it("uses the main part of the domain", () => {
    expect(nameFromUrl(new URL("https://www.nytimes.com"))).toBe("Nytimes");
    expect(nameFromUrl(new URL("https://news.ycombinator.com"))).toBe("Ycombinator");
    expect(nameFromUrl(new URL("https://github.com"))).toBe("Github");
  });
});

describe("builtInFor and appKey", () => {
  it("recognises YouTube addresses", () => {
    expect(builtInFor(new URL("https://youtu.be/x"))).toBe("youtube");
    expect(builtInFor(new URL("https://m.youtube.com"))).toBe("youtube");
    expect(builtInFor(new URL("https://example.com"))).toBeNull();
  });
  it("ignores a trailing slash", () => {
    expect(appKey(new URL("https://github.com/"))).toBe(appKey(new URL("https://github.com")));
  });
});
