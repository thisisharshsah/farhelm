import { defineConfig } from "vitest/config";

// Node, not jsdom: this package must not depend on a DOM to work, and running
// its tests without one is the cheapest way to keep that true.
export default defineConfig({
  test: { environment: "node", include: ["src/**/*.test.ts"] },
});
