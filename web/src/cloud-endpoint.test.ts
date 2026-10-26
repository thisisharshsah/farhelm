import { beforeEach, describe, expect, it } from "vitest";
import { defaultCloudUrl, preferredCloudUrl, rememberCloudUrl, validateCloudUrl } from "./cloud-endpoint";

beforeEach(() => localStorage.clear());

describe("workspace account service selection", () => {
  it("keeps local runner and dev login separate from runner API routes", () => {
    for (const origin of ["http://localhost:5173", "http://127.0.0.1:7842", "http://127.0.0.1:49152"]) {
      expect(defaultCloudUrl(origin)).toBe("http://127.0.0.1:7844");
    }
    expect(defaultCloudUrl("http://localhost:7844")).toBe("http://localhost:7844");
  });

  it("preserves hosted same-origin and explicit deployment choices", () => {
    expect(defaultCloudUrl("https://app.example.com")).toBe("https://app.example.com");
    expect(defaultCloudUrl("http://localhost:5173", "https://accounts.example.com/api/")).toBe("https://accounts.example.com/api");
    expect(defaultCloudUrl("http://localhost:5173", "bad-setting")).toBe("bad-setting");
  });

  it("rejects insecure remote destinations and credentials in addresses", () => {
    for (const value of ["", "example.com", "http://accounts.example.com", "http://192.168.1.1", "https://user:secret@example.com", "https://example.com?key=secret", "https://example.com#auth", "javascript:alert(1)"]) {
      expect(() => validateCloudUrl(value)).toThrow();
    }
    expect(validateCloudUrl(" http://[::1]:7844/ ")).toBe("http://[::1]:7844");
  });

  it("remembers only a validated explicit server choice", () => {
    rememberCloudUrl("https://accounts.example.com/");
    expect(preferredCloudUrl("https://default.example.com")).toBe("https://accounts.example.com");
    localStorage.setItem("farhelm-cloud-url", "http://remote.example.com");
    expect(preferredCloudUrl("https://default.example.com")).toBe("https://default.example.com");
  });
});
