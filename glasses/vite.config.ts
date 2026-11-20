import { cloudflare } from "@cloudflare/vite-plugin";
import react from "@vitejs/plugin-react";
import { defineConfig, type Plugin } from "vite";

/**
 * Production serves glasses.html at /glasses (Workers static assets drop the
 * .html). The dev server does not, so map the same path here.
 */
function glassesPath(): Plugin {
  return {
    name: "lens-glasses-path",
    configureServer(server) {
      server.middlewares.use((req, _res, next) => {
        if (req.url === "/glasses" || req.url?.startsWith("/glasses?")) req.url = req.url.replace("/glasses", "/glasses.html");
        next();
      });
    },
  };
}

// `vite dev` runs the Worker in workerd with a local D1 (.wrangler/state), so
// the whole app, API included, behaves as it will on Cloudflare. Local secrets
// come from glasses/.env.local (Git ignores it).
export default defineConfig({
  plugins: [glassesPath(), react(), cloudflare()],
  build: { sourcemap: true },
  environments: {
    client: {
      build: {
        target: "es2022",
        rollupOptions: {
          // Two pages: the console (/) and the glasses app (/glasses), each with only its own code.
          input: { console: "index.html", glasses: "glasses.html" },
        },
      },
    },
  },
  server: {
    // host: true so the glasses, or the simulator on another machine, can open the dev server.
    host: true,
    port: 5180,
    // A Cloudflare quick tunnel gives the dev server an https address for testing on the glasses.
    allowedHosts: [".trycloudflare.com"],
  },
  preview: { port: 5181 },
});
