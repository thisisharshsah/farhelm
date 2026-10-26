import { afterEach, expect, it, vi } from "vitest";
import { loopbackAvailable } from "./connection";

afterEach(() => vi.unstubAllGlobals());

it("never offers the account service as a runner just because it is local", () => {
  for (const hostname of ["localhost", "127.0.0.1", "[::1]"]) {
    vi.stubGlobal("location", { hostname, port: "7844" });
    expect(loopbackAvailable()).toBe(false);
  }
});

it("retains the explicit account-free choice on runner and dev origins", () => {
  for (const port of ["7842", "5173", "49152"]) {
    vi.stubGlobal("location", { hostname: "127.0.0.1", port });
    expect(loopbackAvailable()).toBe(true);
  }
  vi.stubGlobal("location", { hostname: "workspace.example.com", port: "7842" });
  expect(loopbackAvailable()).toBe(false);
});
