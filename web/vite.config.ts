import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

/** The runner's default localhost port (see `forge-runner serve --port`). */
const RUNNER = process.env.FORGE_RUNNER ?? "http://127.0.0.1:7842";

export default defineConfig({
  plugins: [react()],
  server: {
    // Bound to 0.0.0.0 so the PWA can be opened from a phone on the same
    // network during development. The runner itself stays on loopback.
    host: true,
    port: 5173,
    proxy: {
      "/v1": { target: RUNNER, changeOrigin: true },
    },
  },
  build: { outDir: "dist", sourcemap: true },
});
