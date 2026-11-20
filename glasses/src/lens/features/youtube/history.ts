/**
 * Watch history on the glasses: the account's list (cached, so it shows at
 * once and offline), saving as videos play, and where to resume one. The
 * list is the account's, so the phone and other glasses see it too.
 */
import { useCallback } from "react";
import { api } from "../../../client/http.ts";
import { useResource } from "../../../client/resource.ts";
import { HistoryItem, list, type VideoItem } from "../../../shared/api.ts";

const HistoryList = list(HistoryItem);
/** Kept on the glasses; the API keeps more. */
const KEEP = 50;

/** Where to start a video again: where it was left, unless that was near the start or the end. */
export function resumeFrom(item: HistoryItem | undefined): number {
  if (!item || item.position < 15) return 0;
  if (item.seconds && item.position > item.seconds - 20) return 0;
  return item.position;
}

/** How much was watched, from 0 to 1, for the bar under a thumbnail; nothing when unknown. */
export function watchedPart(item: HistoryItem): number | undefined {
  if (!item.seconds || item.position < 15) return undefined;
  return Math.min(1, item.position / item.seconds);
}

export interface WatchHistory {
  items: HistoryItem[];
  /** Saves a video as watched up to `position`; `leaving` lets the save finish as the app closes. */
  record: (video: VideoItem, position: number, options?: { leaving?: boolean }) => void;
  clear: () => Promise<void>;
}

export function useWatchHistory(cacheKey: string): WatchHistory {
  const history = useResource("/api/history", HistoryList, { cacheKey });
  const { set } = history;

  const record = useCallback(
    (video: VideoItem, position: number, options?: { leaving?: boolean }) => {
      const at = Math.max(0, Math.floor(position));
      set((prev) => ({
        items: [{ ...video, position: at, watchedAt: Date.now() }, ...(prev?.items ?? []).filter((i) => i.id !== video.id)].slice(0, KEEP),
      }));
      const { thumbnail: _, ...rest } = video;
      void api(`/api/history/${encodeURIComponent(video.id)}`, {
        method: "PUT",
        body: { video: rest, position: at },
        keepalive: options?.leaving,
      }).catch(() => {
        // Best effort: the next save records it.
      });
    },
    [set],
  );

  const clear = useCallback(async () => {
    await api("/api/history", { method: "DELETE" });
    set(() => ({ items: [] }));
  }, [set]);

  return { items: history.data?.items ?? [], record, clear };
}
