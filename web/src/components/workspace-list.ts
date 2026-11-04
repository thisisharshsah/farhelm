import { useEffect, useRef, useState } from "react";

interface Page<T> { items: T[]; next_cursor: string | null }

/** Small, paged navigation lists. The owner remounts on runner/project changes. */
export function useWorkspaceList<T extends { id: string }>(
  load: (after?: string) => Promise<Page<T>>,
  revision: number,
) {
  const [items, setItems] = useState<T[] | null>(null);
  const [cursor, setCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const generation = useRef(0);
  const busy = useRef(false);

  useEffect(() => {
    const owner = ++generation.current;
    busy.current = true;
    setLoading(true);
    setError(null);
    void load().then((page) => {
      if (generation.current !== owner) return;
      setItems(page.items);
      setCursor(page.next_cursor);
    }).catch((cause: unknown) => {
      if (generation.current === owner) setError(cause instanceof Error ? cause.message : String(cause));
    }).finally(() => {
      if (generation.current === owner) { busy.current = false; setLoading(false); }
    });
    return () => { generation.current += 1; };
  }, [load, revision]);

  const more = async () => {
    if (!cursor || busy.current) return;
    const owner = generation.current;
    busy.current = true;
    setLoading(true);
    setError(null);
    try {
      const page = await load(cursor);
      if (generation.current !== owner) return;
      if (page.next_cursor === cursor) throw new Error("The list did not advance. Refresh to try again.");
      setItems((current) => {
        const seen = new Set((current ?? []).map((item) => item.id));
        return [...(current ?? []), ...page.items.filter((item) => !seen.has(item.id))];
      });
      setCursor(page.next_cursor);
    } catch (cause) {
      if (generation.current === owner) setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      if (generation.current === owner) { busy.current = false; setLoading(false); }
    }
  };
  return { items, cursor, loading, error, more };
}
