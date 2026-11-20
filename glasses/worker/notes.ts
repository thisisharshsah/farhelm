import type { Note } from "../src/shared/api.ts";
import { ApiError } from "./lib/http.ts";

export const MAX_NOTES = 500;

/** Saves a note for the account. Used by the notes API and by the chat. */
export async function createNote(db: D1Database, userId: string, text: string): Promise<Note> {
  const count = await db.prepare("SELECT COUNT(*) AS n FROM notes WHERE user_id = ?").bind(userId).first<{ n: number }>();
  if ((count?.n ?? 0) >= MAX_NOTES) throw new ApiError(409, "too_many", `Up to ${MAX_NOTES} notes. Clear some first.`);
  const note: Note = { id: crypto.randomUUID(), text, createdAt: Date.now() };
  await db
    .prepare("INSERT INTO notes (id, user_id, text, created_at) VALUES (?, ?, ?, ?)")
    .bind(note.id, userId, note.text, note.createdAt)
    .run();
  return note;
}
