import { describe, expect, it, vi } from "vitest";
import { googleFavicon, iconCandidates, iconResponse, publicHttpsUrl, resolveIcon } from "./icon.ts";

describe("publicHttpsUrl", () => {
  it("accepts public https sites", () => {
    expect(publicHttpsUrl("https://www.youtube.com/watch?v=1")?.hostname).toBe("www.youtube.com");
  });
  it("rejects anything that could reach a private network", () => {
    for (const bad of [
      "http://example.com",
      "https://localhost",
      "https://127.0.0.1",
      "https://[::1]",
      "https://intranet",
      "https://mac.local",
      "https://user:pw@example.com",
      "nope",
      null,
    ]) {
      expect(publicHttpsUrl(bad)).toBeNull();
    }
  });
});

describe("iconCandidates", () => {
  const base = new URL("https://www.example.com/");
  it("prefers apple touch icons and large sizes over small favicons", () => {
    const html = `<html><head>
      <link rel="shortcut icon" href="/favicon.ico">
      <link rel="icon" sizes="32x32" href="/f32.png">
      <link rel="icon" sizes="192x192" href="/f192.png">
      <link rel=apple-touch-icon href="https://cdn.example.com/apple.png">
    </head><body><link rel="icon" href="/ignored.png"></body></html>`;
    expect(iconCandidates(html, base)).toEqual([
      "https://cdn.example.com/apple.png",
      "https://www.example.com/f192.png",
      "https://www.example.com/f32.png",
      "https://www.example.com/favicon.ico",
    ]);
  });
  it("puts touch icons last when only the mark is wanted", () => {
    const html = `<head>
      <link rel="apple-touch-icon" href="/apple.png">
      <link rel="icon" sizes="144x144" href="/f144.png">
      <link rel="icon" sizes="32x32" href="/f32.png">
    </head>`;
    expect(iconCandidates(html, base, "glyph")).toEqual([
      "https://www.example.com/f144.png",
      "https://www.example.com/f32.png",
      "https://www.example.com/apple.png",
    ]);
  });
  it("ranks an SVG icon first and skips insecure links", () => {
    const html = `<head><link rel="icon" type="image/svg+xml" href="/logo.svg"><link rel="icon" href="http://x.com/a.png"></head>`;
    expect(iconCandidates(html, base)).toEqual(["https://www.example.com/logo.svg"]);
  });
});

describe("resolveIcon", () => {
  const site = new URL("https://www.example.com");
  it("goes straight to Google's service for a mark when the page names none", async () => {
    const fetchImpl = vi.fn(async () => new Response("<head></head>", { headers: { "content-type": "text/html" } }));
    expect(await resolveIcon(site, fetchImpl as typeof fetch, "glyph")).toBe(googleFavicon("www.example.com"));
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });
  it("uses the page's best icon", async () => {
    const fetchImpl = vi.fn(async () =>
      new Response(`<head><link rel="apple-touch-icon" href="/t.png"></head>`, {
        headers: { "content-type": "text/html" },
      }),
    );
    expect(await resolveIcon(site, fetchImpl as typeof fetch)).toBe("https://www.example.com/t.png");
  });
  it("falls back to /apple-touch-icon.png, then to Google's service", async () => {
    const withTouch = vi.fn(async (_u: URL | RequestInfo, init?: RequestInit) =>
      init?.method === "HEAD"
        ? new Response(null, { headers: { "content-type": "image/png" } })
        : new Response("<head></head>", { headers: { "content-type": "text/html" } }),
    );
    expect(await resolveIcon(site, withTouch as typeof fetch)).toBe("https://www.example.com/apple-touch-icon.png");

    const nothing = vi.fn(async () => {
      throw new Error("offline");
    });
    expect(await resolveIcon(site, nothing as typeof fetch)).toBe(googleFavicon("www.example.com"));
  });
});

describe("iconResponse", () => {
  it("redirects with a day-long cache", async () => {
    const fetchImpl = vi.fn(async () => {
      throw new Error("offline");
    });
    const res = await iconResponse(
      new Request("https://g.test/api/icon?url=https%3A%2F%2Fexample.org"),
      fetchImpl as typeof fetch,
    );
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe(googleFavicon("example.org"));
    expect(res.headers.get("cache-control")).toContain("max-age=86400");
  });
  it("rejects a bad address", async () => {
    expect((await iconResponse(new Request("https://g.test/api/icon?url=http%3A%2F%2F10.0.0.1"))).status).toBe(400);
  });
});
