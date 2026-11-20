/**
 * The Lens API: one Hono app under /api. Static pages (console at /, glasses
 * at /glasses) are served by Workers static assets and never reach it.
 */
import { Hono } from "hono";
import { secureHeaders } from "hono/secure-headers";
import type { AppEnv } from "./env.ts";
import { ApiError } from "./lib/http.ts";
import { accountRoutes } from "./routes/account.ts";
import { authRoutes } from "./routes/auth.ts";
import { chatRoutes } from "./routes/chat.ts";
import { dataRoutes } from "./routes/data.ts";
import { deviceRoutes } from "./routes/device.ts";
import { historyRoutes } from "./routes/history.ts";
import { mediaRoutes } from "./routes/media.ts";
import { loadSession } from "./sessions.ts";
import { simpleWebAuthn, type WebAuthnPort } from "./webauthn.ts";

export interface AppDeps {
  webauthn: WebAuthnPort;
  /** Outbound fetch for YouTube and icons; replaceable in tests. */
  fetch: typeof fetch;
}

const SAFE_METHODS = new Set(["GET", "HEAD", "OPTIONS"]);

export function createApp(deps: Partial<AppDeps> = {}) {
  const webauthn = deps.webauthn ?? simpleWebAuthn;
  const app = new Hono<AppEnv>();

  // One structured log line per request, joined by its Cloudflare ray ID.
  app.use("*", async (c, next) => {
    const started = Date.now();
    c.set("requestId", c.req.header("cf-ray") ?? crypto.randomUUID());
    await next();
    console.log(
      JSON.stringify({
        level: c.res.status >= 500 ? "error" : "info",
        msg: "request",
        requestId: c.get("requestId"),
        method: c.req.method,
        path: new URL(c.req.url).pathname,
        status: c.res.status,
        ms: Date.now() - started,
        user: c.get("session")?.userId ?? null,
      }),
    );
  });

  app.use("*", secureHeaders({ crossOriginResourcePolicy: "same-origin" }));

  // Same-origin writes only: browsers always send Origin on cross-site
  // requests, and JSON bodies (required by `body()`) cannot come from a form.
  app.use("*", async (c, next) => {
    if (!SAFE_METHODS.has(c.req.method)) {
      const origin = c.req.header("origin");
      if (origin && origin !== new URL(c.req.url).origin) {
        throw new ApiError(403, "cross_origin", "Requests must come from Lens itself.");
      }
    }
    await next();
  });

  app.use("*", async (c, next) => {
    await next();
    // API answers are per account: never let a shared cache keep them,
    // except where a route chose otherwise.
    if (!c.res.headers.has("cache-control")) c.res.headers.set("cache-control", "no-store");
  });

  app.use("*", loadSession);

  app.get("/api/health", (c) => c.json({ ok: true }));
  app.route("/api/auth", authRoutes(webauthn));
  app.route("/api/device", deviceRoutes());
  app.route("/api", accountRoutes(webauthn));
  app.route("/api", dataRoutes());
  app.route("/api", mediaRoutes(deps.fetch ?? fetch));
  app.route("/api/chat", chatRoutes(deps.fetch ?? fetch));
  app.route("/api/history", historyRoutes());

  app.notFound((c) => c.json({ error: { code: "not_found", message: "No such endpoint." } }, 404));

  app.onError((err, c) => {
    if (err instanceof ApiError) {
      return c.json({ error: { code: err.code, message: err.message } }, err.status);
    }
    console.error(
      JSON.stringify({
        level: "error",
        msg: "unhandled",
        requestId: c.get("requestId"),
        error: err instanceof Error ? `${err.name}: ${err.message}` : String(err),
      }),
    );
    return c.json({ error: { code: "internal", message: "Something went wrong. Try again." } }, 500);
  });

  return app;
}
