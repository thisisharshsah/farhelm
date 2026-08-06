import { defineConfig } from "vite";

/**
 * The service worker, built separately from the app.
 *
 * Separate because it must be a **classic script**, not an ES module. Module
 * service workers (`{ type: "module" }`) are still not in Safari or Firefox
 * stable, and Safari is the platform this whole design bends around — a module
 * worker there simply fails to register, taking push with it.
 *
 * So: one IIFE bundle, emitted to `dist/sw.js` at the root, because a service
 * worker's scope is its own directory and one served from `/assets/` could only
 * control `/assets/`.
 */
export default defineConfig({
  build: {
    outDir: "dist",
    // The app is built first; this must not delete it.
    emptyOutDir: false,
    sourcemap: true,
    // The worker is fetched on every update check, so it stays small — no
    // code-splitting, no shared chunks with the app.
    rollupOptions: {
      input: "src/sw.ts",
      output: { format: "iife", entryFileNames: "sw.js" },
    },
  },
});
