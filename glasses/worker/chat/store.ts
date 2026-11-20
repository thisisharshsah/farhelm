/**
 * Chat storage. A row holds what was said and Lens's reply; `seq` orders the
 * conversation and is the cursor clients sync from.
 */
import { ChatReply, type ChatMessage, type ChatPage } from "../../src/shared/api.ts";
import type { SessionContext } from "../env.ts";

interface Row {
  seq: number;
  id: string;
  source: SessionContext["kind"];
  text: string;
  reply: string;
  created_at: number;
}

const COLUMNS = "seq, id, source, text, reply, created_at";

/** First load: the latest messages. Sync: up to this many after the cursor. */
export const PAGE_SIZE = 30;
export const MAX_PAGE = 100;

/** Replies are re-validated on read, so one stored by another version never breaks a client. */
const UNREADABLE: ChatReply = { kind: "error", message: "This reply can't be shown by this version of Lens." };

function toMessage(row: Row): ChatMessage {
  let reply = UNREADABLE;
  try {
    const parsed = ChatReply.safeParse(JSON.parse(row.reply));
    if (parsed.success) reply = parsed.data;
  } catch {
    // Keep the placeholder.
  }
  return { id: row.id, seq: row.seq, source: row.source, text: row.text, reply, createdAt: row.created_at };
}

export async function insertMessage(
  db: D1Database,
  userId: string,
  source: SessionContext["kind"],
  text: string,
  reply: ChatReply,
): Promise<ChatMessage> {
  const id = crypto.randomUUID();
  const createdAt = Date.now();
  const row = await db
    .prepare("INSERT INTO messages (id, user_id, source, text, reply, created_at) VALUES (?, ?, ?, ?, ?, ?) RETURNING seq")
    .bind(id, userId, source, text, JSON.stringify(reply), createdAt)
    .first<{ seq: number }>();
  if (!row) throw new Error("insert returned no seq");
  return { id, seq: row.seq, source, text, reply, createdAt };
}

/** The newest seq and the clear mark, in one cheap read: what the long poll watches. */
export async function marks(db: D1Database, userId: string): Promise<{ latest: number; cleared: number }> {
  const row = await db
    .prepare(
      `SELECT (SELECT COALESCE(MAX(seq), 0) FROM messages WHERE user_id = ?) AS latest,
              (SELECT COALESCE(MAX(cleared_through), 0) FROM chat_state WHERE user_id = ?) AS cleared`,
    )
    .bind(userId, userId)
    .first<{ latest: number; cleared: number }>();
  return { latest: row?.latest ?? 0, cleared: row?.cleared ?? 0 };
}

/** The latest page when `after` is null, otherwise what came after it, oldest first. */
export async function readPage(db: D1Database, userId: string, after: number | null, limit: number): Promise<ChatPage> {
  const { cleared } = await marks(db, userId);
  let rows: Row[];
  if (after === null) {
    const { results } = await db
      .prepare(`SELECT ${COLUMNS} FROM messages WHERE user_id = ? ORDER BY seq DESC LIMIT ?`)
      .bind(userId, limit)
      .all<Row>();
    rows = results.reverse();
  } else {
    const { results } = await db
      .prepare(`SELECT ${COLUMNS} FROM messages WHERE user_id = ? AND seq > ? ORDER BY seq LIMIT ?`)
      .bind(userId, after, limit)
      .all<Row>();
    rows = results;
  }
  return { items: rows.map(toMessage), clearedThrough: cleared };
}

/** Clears the conversation on every device. Returns the new clear mark. */
export async function clearChat(db: D1Database, userId: string): Promise<number> {
  const { latest, cleared } = await marks(db, userId);
  const through = Math.max(latest, cleared);
  await db.batch([
    db
      .prepare(
        `INSERT INTO chat_state (user_id, cleared_through) VALUES (?, ?)
         ON CONFLICT (user_id) DO UPDATE SET cleared_through = MAX(cleared_through, excluded.cleared_through)`,
      )
      .bind(userId, through),
    db.prepare("DELETE FROM messages WHERE user_id = ? AND seq <= ?").bind(userId, through),
  ]);
  return through;
}
