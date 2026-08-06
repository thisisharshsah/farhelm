import { defineConfig } from "vitest/config";

// jsdom, because what is left in this package is all DOM: the loopback
// transport's EventSource, the pairing store, and the service worker's
// notification policy. The logic that must work without a DOM lives in
// `@relayforge/client-core` and is tested there, under Node.
//
// jsdom has no IndexedDB, which the pairing store now needs — `fake-indexeddb`
// supplies a real implementation rather than a stub, so the migration path is
// exercised against something that behaves like the browser's.
export default defineConfig({
  test: {
    environment: "jsdom",
    include: ["src/**/*.test.ts"],
    setupFiles: ["./vitest.setup.ts"],
  },
});
