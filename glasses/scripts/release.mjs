#!/usr/bin/env node
/**
 * Puts Lens live at https://lens.aurovie.com on Cloudflare.
 *
 *   pnpm --filter @farhelm/glasses release
 *
 * Safe to run again: every step checks before it changes anything.
 *   1. Checks you are signed in to Cloudflare (`wrangler login` once).
 *   2. Creates the D1 database "lens" if it does not exist.
 *   3. Applies database migrations (asks before changing the remote database).
 *   4. Typechecks and builds.
 *   5. Deploys the Worker and its custom domain.
 *   6. Sets missing secrets: YOUTUBE_API_KEY from glasses/.env.local, and a
 *      fresh SETUP_CODE for creating the first account (shown once).
 */
import { spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const DB = "lens";
const CONFIG = join(root, "wrangler.jsonc");

function run(cmd, args, { input, capture = false } = {}) {
  const result = spawnSync(cmd, args, {
    cwd: root,
    encoding: "utf8",
    input,
    stdio: capture || input !== undefined ? ["pipe", "pipe", "pipe"] : "inherit",
  });
  return { ok: result.status === 0, out: `${result.stdout ?? ""}${result.stderr ?? ""}`, stdout: result.stdout ?? "" };
}

const wrangler = (args, options) => run("pnpm", ["exec", "wrangler", ...args], options);

function step(text) {
  console.log(`\n\u001b[1m${text}\u001b[0m`);
}

function fail(text) {
  console.error(`\n\u001b[31m${text}\u001b[0m`);
  process.exit(1);
}

/** Reads KEY=value lines from glasses/.env.local without printing them. */
function localSecret(name) {
  const file = join(root, ".env.local");
  if (!existsSync(file)) return null;
  for (const line of readFileSync(file, "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && m[1] === name) return m[2].replace(/^(['"])(.*)\1$/, "$2") || null;
  }
  return null;
}

step("1/6  Cloudflare sign-in");
const who = wrangler(["whoami"], { capture: true });
if (!who.ok || /not authenticated/i.test(who.out)) {
  fail("Not signed in to Cloudflare. Run this once, then try again:\n  pnpm --filter @farhelm/glasses exec wrangler login");
}
console.log("Signed in.");

step("2/6  Database");
const list = wrangler(["d1", "list", "--json", "-c", CONFIG], { capture: true });
if (!list.ok) fail(`Could not list D1 databases:\n${list.out}`);
const databases = JSON.parse(list.stdout.slice(list.stdout.indexOf("[")));
if (databases.some((d) => d.name === DB)) {
  console.log(`D1 database "${DB}" exists.`);
} else if (!wrangler(["d1", "create", DB, "-c", CONFIG]).ok) {
  fail(`Could not create the D1 database "${DB}".`);
}

step("3/6  Migrations");
if (!wrangler(["d1", "migrations", "apply", DB, "--remote", "-c", CONFIG]).ok) fail("Migrations failed; nothing was deployed.");

step("4/6  Typecheck and build");
if (!run("pnpm", ["run", "build"]).ok) fail("The build failed; nothing was deployed.");

step("5/6  Deploy to lens.aurovie.com");
// No -c: the Vite build left a redirect to its generated config in .wrangler/deploy.
if (!wrangler(["deploy"]).ok) fail("Deploy failed.");

step("6/6  Secrets");
const secrets = wrangler(["secret", "list", "--format", "json"], { capture: true });
const have = new Set(secrets.ok ? JSON.parse(secrets.stdout.slice(secrets.stdout.indexOf("["))).map((s) => s.name) : []);

if (have.has("YOUTUBE_API_KEY")) {
  console.log("YOUTUBE_API_KEY is set.");
} else {
  const key = localSecret("YOUTUBE_API_KEY");
  if (!key) console.log("YOUTUBE_API_KEY is not set and not in glasses/.env.local: YouTube search will answer 503.");
  else if (wrangler(["secret", "put", "YOUTUBE_API_KEY"], { input: key }).ok) console.log("YOUTUBE_API_KEY set from .env.local.");
  else fail("Could not set YOUTUBE_API_KEY.");
}

if (have.has("SETUP_CODE")) {
  console.log("SETUP_CODE is set (it only matters until the first account exists).");
} else {
  const code = randomBytes(12).toString("base64url");
  if (!wrangler(["secret", "put", "SETUP_CODE"], { input: code }).ok) fail("Could not set SETUP_CODE.");
  console.log(
    `\n  Setup code (shown once): \u001b[1m${code}\u001b[0m\n` +
      "  Open https://lens.aurovie.com, choose Create an account, and enter it.\n" +
      "  It works only for the first account; invite everyone else from Team.",
  );
}

console.log("\n\u001b[32mLens is live at https://lens.aurovie.com\u001b[0m (glasses: https://lens.aurovie.com/glasses)\n");
