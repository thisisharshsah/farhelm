import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// Two projects:
//   web    - client and shared logic, in jsdom.
//   worker - the API, inside the Workers runtime (workerd via Miniflare) with
//            a real local D1 that has the migrations applied.
export default defineConfig({
  test: {
    projects: [
      {
        test: {
          name: "web",
          environment: "jsdom",
          include: ["src/**/*.test.ts"],
        },
      },
      {
        plugins: [
          cloudflareTest(async () => ({
            wrangler: { configPath: "./wrangler.jsonc" },
            miniflare: {
              bindings: {
                TEST_MIGRATIONS: await readD1Migrations("./migrations"),
                SETUP_CODE: "test-setup-code",
                YOUTUBE_API_KEY: "test-youtube-key",
              },
            },
          })),
        ],
        test: {
          name: "worker",
          include: ["worker/**/*.test.ts"],
          setupFiles: ["./worker/test/setup.ts"],
        },
      },
    ],
  },
});
