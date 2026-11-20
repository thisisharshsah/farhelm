import { useState, type FormEvent } from "react";
import { api } from "../../client/http.ts";
import { useResource } from "../../client/resource.ts";
import { Note, list } from "../../shared/api.ts";
import { MAX_NOTE_LENGTH } from "../../shared/intents.ts";
import type { PageProps } from "../App.tsx";
import { timeAgo } from "../format.ts";
import { Button, Empty, ErrorNote, Group, Loading, PageHeader, Row, useAction } from "../ui.tsx";

const Notes = list(Note);

export function NotesPage(_: PageProps) {
  const notes = useResource("/api/notes", Notes);
  const [text, setText] = useState("");

  const add = useAction(async () => {
    const note = await api("/api/notes", { method: "POST", body: { text }, schema: Note });
    notes.set((prev) => ({ items: [note, ...(prev?.items ?? [])] }));
    setText("");
  });
  const remove = useAction(async (id: string) => {
    await api(`/api/notes/${encodeURIComponent(id)}`, { method: "DELETE" });
    notes.set((prev) => ({ items: (prev?.items ?? []).filter((n) => n.id !== id) }));
  });

  const submit = (e: FormEvent) => {
    e.preventDefault();
    void add.run();
  };

  const items = notes.data?.items ?? [];

  return (
    <>
      <PageHeader title="Notes" description="Write here, on your glasses, or say “note …” in the chat." back={{ to: "/apps", label: "Apps" }} />
      <form className="note-compose glass" onSubmit={submit}>
        <label className="sr-only" htmlFor="note">
          New note
        </label>
        <textarea
          id="note"
          rows={3}
          maxLength={MAX_NOTE_LENGTH}
          value={text}
          onChange={(e) => setText(e.target.value)}
          placeholder="Something to see on your glasses"
        />
        <div className="note-compose-foot">
          <span className="muted small">
            {text.length}/{MAX_NOTE_LENGTH}
          </span>
          <Button type="submit" variant="primary" busy={add.busy} disabled={!text.trim()}>
            Save note
          </Button>
        </div>
      </form>
      <ErrorNote message={add.error} />

      <ErrorNote message={notes.error ?? remove.error} onRetry={notes.error ? () => void notes.reload() : undefined} />
      {notes.loading && !notes.data ? (
        <Loading />
      ) : items.length ? (
        <Group title="Saved">
          {items.map((n) => (
            <Row
              key={n.id}
              title={<span className="note-text">{n.text}</span>}
              detail={timeAgo(n.createdAt)}
              trailing={<Button variant="ghost" icon="trash" onClick={() => void remove.run(n.id)} aria-label="Delete note" />}
            />
          ))}
        </Group>
      ) : (
        <div className="glass card">
          <Empty icon="note" title="No notes yet">
            Notes you write on your glasses appear here too.
          </Empty>
        </div>
      )}
    </>
  );
}
