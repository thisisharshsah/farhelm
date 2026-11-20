import { describe, expect, it } from "vitest";
import { isAllowedCompanionLink } from "./companion.ts";

describe("isAllowedCompanionLink", () => {
  it("accepts https and private-network http", () => {
    expect(isAllowedCompanionLink("https://example.com/glass#tok")).toBe(true);
    expect(isAllowedCompanionLink("http://192.168.1.20:8787/glass#tok")).toBe(true);
    expect(isAllowedCompanionLink("http://100.101.1.2:8787/glass")).toBe(true);
    expect(isAllowedCompanionLink("http://harshs-mbp.local:8787/glass")).toBe(true);
  });
  it("rejects public http, credentials and other schemes", () => {
    expect(isAllowedCompanionLink("http://example.com/glass")).toBe(false);
    expect(isAllowedCompanionLink("https://u:p@example.com/glass")).toBe(false);
    expect(isAllowedCompanionLink("javascript:alert(1)")).toBe(false);
    expect(isAllowedCompanionLink("not a url")).toBe(false);
  });
});
