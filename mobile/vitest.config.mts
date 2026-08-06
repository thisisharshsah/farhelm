import { defineConfig } from "vitest/config";

// Only the platform-free logic in `src/` is unit-tested here — the screens need
// a React Native renderer, which is a device or a simulator, not this runner.
export default defineConfig({
  test: { environment: "node", include: ["src/**/*.test.ts"] },
});
