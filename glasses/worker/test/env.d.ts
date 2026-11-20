import type { D1Migration } from "cloudflare:test";
import type { Env as LensEnv } from "../env.ts";

declare global {
  namespace Cloudflare {
    interface Env extends LensEnv {
      TEST_MIGRATIONS: D1Migration[];
    }
  }
}
