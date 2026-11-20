/**
 * What the glasses show, kept per account so the console and every pair of
 * glasses see the same notes, apps and preferences.
 */
import { Hono } from "hono";
import {
  DEFAULT_PREFERENCES,
  NoteInput,
  Preferences,
  PreferencesPatch,
  WebAppInput,
} from "../../src/shared/api.ts";
import { MAX_WEB_APPS, appKey, builtInFor, nameFromUrl, normalizeAppUrl } from "../../src/shared/apps.ts";
import type { AppEnv } from "../env.ts";
import { ApiError, body, items, notFound } from "../lib/http.ts";
import { createNote } from "../notes.ts";
import { requireSession } from "../sessions.ts";

export function dataRoutes() {
  const r = new Hono<AppEnv>();

  // ---------- notes ----------

  r.get("/notes", async (c) => {
    const s = requireSession(c);
    const { results } = await c.env.DB.prepare(
      "SELECT id, text, created_at FROM notes WHERE user_id = ? ORDER BY created_at DESC LIMIT 100",
    )
      .bind(s.userId)
      .all<{ id: string; text: string; created_at: number }>();
    return items(
      c,
      results.map((n) => ({ id: n.id, text: n.text, createdAt: n.created_at })),
    );
  });

  r.post("/notes", async (c) => {
    const s = requireSession(c);
    const input = await body(c, NoteInput);
    return c.json(await createNote(c.env.DB, s.userId, input.text), 201);
  });

  r.delete("/notes/:id", async (c) => {
    const s = requireSession(c);
    const result = await c.env.DB.prepare("DELETE FROM notes WHERE id = ? AND user_id = ?")
      .bind(c.req.param("id"), s.userId)
      .run();
    if (!result.meta.changes) throw notFound("That note is already gone.");
    return c.body(null, 204);
  });

  // ---------- website apps ----------

  r.get("/apps", async (c) => {
    const s = requireSession(c);
    const { results } = await c.env.DB.prepare(
      "SELECT id, name, url, position FROM web_apps WHERE user_id = ? ORDER BY position, created_at",
    )
      .bind(s.userId)
      .all<{ id: string; name: string; url: string; position: number }>();
    return items(c, results);
  });

  r.post("/apps", async (c) => {
    const s = requireSession(c);
    const input = await body(c, WebAppInput);
    const url = normalizeAppUrl(input.url);
    if (!url) throw new ApiError(400, "invalid", "Use a web address, like example.com");
    if (builtInFor(url)) throw new ApiError(409, "built_in", "That one is already on your glasses.");
    const stats = await c.env.DB.prepare(
      "SELECT COUNT(*) AS n, COALESCE(MAX(position), -1) AS last FROM web_apps WHERE user_id = ?",
    )
      .bind(s.userId)
      .first<{ n: number; last: number }>();
    if ((stats?.n ?? 0) >= MAX_WEB_APPS) throw new ApiError(409, "too_many", `Up to ${MAX_WEB_APPS} apps.`);
    const app = {
      id: crypto.randomUUID(),
      name: input.name ?? nameFromUrl(url),
      url: url.href,
      position: (stats?.last ?? -1) + 1,
    };
    try {
      await c.env.DB.prepare(
        "INSERT INTO web_apps (id, user_id, name, url, url_key, position, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      )
        .bind(app.id, s.userId, app.name, app.url, appKey(url), app.position, Date.now())
        .run();
    } catch (e) {
      if (/UNIQUE/i.test(String(e))) throw new ApiError(409, "exists", "Already added.");
      throw e;
    }
    return c.json(app, 201);
  });

  r.delete("/apps/:id", async (c) => {
    const s = requireSession(c);
    const result = await c.env.DB.prepare("DELETE FROM web_apps WHERE id = ? AND user_id = ?")
      .bind(c.req.param("id"), s.userId)
      .run();
    if (!result.meta.changes) throw notFound("That app is already gone.");
    return c.body(null, 204);
  });

  // ---------- preferences ----------

  async function readPreferences(db: D1Database, userId: string): Promise<Preferences> {
    const row = await db.prepare("SELECT data FROM preferences WHERE user_id = ?").bind(userId).first<{ data: string }>();
    if (!row) return DEFAULT_PREFERENCES;
    // Stored data is re-validated: a field that no longer passes falls back to its default.
    const merged = { ...DEFAULT_PREFERENCES, ...(JSON.parse(row.data) as object) };
    const parsed = Preferences.safeParse(merged);
    return parsed.success ? parsed.data : DEFAULT_PREFERENCES;
  }

  r.get("/preferences", async (c) => {
    const s = requireSession(c);
    return c.json(await readPreferences(c.env.DB, s.userId));
  });

  r.patch("/preferences", async (c) => {
    const s = requireSession(c);
    const patch = await body(c, PreferencesPatch);
    const next = { ...(await readPreferences(c.env.DB, s.userId)), ...patch };
    await c.env.DB.prepare(
      `INSERT INTO preferences (user_id, data, updated_at) VALUES (?, ?, ?)
       ON CONFLICT (user_id) DO UPDATE SET data = excluded.data, updated_at = excluded.updated_at`,
    )
      .bind(s.userId, JSON.stringify(next), Date.now())
      .run();
    return c.json(next);
  });

  return r;
}
