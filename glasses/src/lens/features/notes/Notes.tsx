import { PlusIcon, Trash2Icon } from "lucide-react";
import { useRef, useState } from "react";
import { api, messageOf } from "../../../client/http.ts";
import { Note } from "../../../shared/api.ts";
import { MAX_NOTE_LENGTH } from "../../../shared/intents.ts";
import { shortAgo } from "../../../shared/time.ts";
import { useNow } from "../../lib/useNow.ts";
import { AskBar } from "../../ui/AskBar.tsx";

interface NotesProps {
  notes: Note[];
  /** Applies a change the server confirmed. */
  update: (change: (prev: Note[]) => Note[]) => void;
}

/**
 * Notes live on the account, so the console and the chat see the same ones.
 * Deleting takes two pinches: the first asks, the second deletes.
 */
export function Notes({ notes, update }: NotesProps) {
  const bar = useRef<HTMLInputElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const [message, setMessage] = useState("");
  const [armed, setArmed] = useState<string | null>(null);
  const now = useNow(30_000);

  const save = async (text: string) => {
    setMessage("Saving…");
    try {
      const note = await api("/api/notes", { method: "POST", body: { text }, schema: Note });
      update((prev) => [note, ...prev]);
      setMessage("Saved");
    } catch (e) {
      setMessage(`${messageOf(e)} Say it again to retry.`);
    }
  };

  const remove = async (note: Note, index: number) => {
    if (armed !== note.id) {
      setArmed(note.id);
      return;
    }
    setArmed(null);
    try {
      await api(`/api/notes/${encodeURIComponent(note.id)}`, { method: "DELETE" });
      update((prev) => prev.filter((n) => n.id !== note.id));
      setMessage("Deleted");
      // Keep focus in the list after the item disappears.
      requestAnimationFrame(() => {
        const items = list.current?.querySelectorAll<HTMLButtonElement>("button");
        (items?.[Math.min(index, (items?.length ?? 1) - 1)] ?? bar.current)?.focus();
      });
    } catch (e) {
      setMessage(messageOf(e));
    }
  };

  return (
    <section className="app-page" aria-label="Notes">
      <AskBar
        ref={bar}
        label="New note"
        placeholder="New note"
        icon={<PlusIcon size={26} />}
        maxLength={MAX_NOTE_LENGTH}
        onSubmit={(text) => void save(text)}
      />
      {message ? (
        <p className="page-note" aria-live="polite">
          {message}
        </p>
      ) : null}
      <div className="list" ref={list}>
        {notes.length === 0 ? <p className="welcome">Nothing saved yet. Notes from your phone and Meta AI show here too.</p> : null}
        {notes.map((n, i) => (
          <button
            key={n.id}
            data-primary={i === 0 || undefined}
            className={`note${armed === n.id ? " armed" : ""}`}
            onClick={() => void remove(n, i)}
            onBlur={() => setArmed((a) => (a === n.id ? null : a))}
          >
            <span className="note-text">{n.text}</span>
            <span className="note-meta">
              {armed === n.id ? (
                <>
                  <Trash2Icon size={20} /> Pinch again to delete
                </>
              ) : (
                shortAgo(n.createdAt, now)
              )}
            </span>
          </button>
        ))}
      </div>
    </section>
  );
}
