import { useState } from "react";
import { api, messageOf } from "../../client/http.ts";
import { useResource } from "../../client/resource.ts";
import { HistoryItem, list } from "../../shared/api.ts";
import { formatDuration } from "../../shared/youtube.ts";
import type { PageProps } from "../App.tsx";
import { useLensChat } from "../chat/ChatContext.tsx";
import { timeAgo } from "../format.ts";
import { Button, Empty, ErrorNote, Group, Icon, Loading, PageHeader, Spinner, useAction } from "../ui.tsx";

const HistoryList = list(HistoryItem);

/** "3:20 of 4:05", "Watched", or "Started": the same rule the glasses resume by. */
function progressText(v: HistoryItem): string {
  if (v.position < 15) return "Started";
  if (v.seconds && v.position >= v.seconds - 20) return "Watched";
  return v.seconds ? `${formatDuration(v.position)} of ${formatDuration(v.seconds)}` : `At ${formatDuration(v.position)}`;
}

/**
 * What the glasses played, newest first, for the whole account. A video
 * plays again on the glasses from where it was left.
 */
export function HistoryPage(_: PageProps) {
  const history = useResource("/api/history", HistoryList);
  const chat = useLensChat();
  const [sent, setSent] = useState<{ id: string; status: "sending" | "sent" | "failed"; error?: string } | null>(null);
  // Clearing removes it on every device, so it takes two taps.
  const [armed, setArmed] = useState(false);

  const clear = useAction(async () => {
    await api("/api/history", { method: "DELETE" });
    history.set(() => ({ items: [] }));
    setArmed(false);
  });
  const remove = useAction(async (id: string) => {
    await api(`/api/history/${encodeURIComponent(id)}`, { method: "DELETE" });
    history.set((prev) => ({ items: (prev?.items ?? []).filter((v) => v.id !== id) }));
  });
  const play = async (video: HistoryItem) => {
    setSent({ id: video.id, status: "sending" });
    try {
      await chat.play(video);
      setSent({ id: video.id, status: "sent" });
    } catch (e) {
      setSent({ id: video.id, status: "failed", error: messageOf(e) });
    }
  };

  const items = history.data?.items ?? [];

  return (
    <>
      <PageHeader title="Watch history" description="What your glasses played. Each video resumes where you left off." back={{ to: "/apps", label: "Apps" }} />
      <ErrorNote message={history.error ?? remove.error} onRetry={history.error ? () => void history.reload() : undefined} />
      {history.loading && !history.data ? (
        <Loading />
      ) : items.length ? (
        <Group title="Watched">
          {items.map((v) => {
            const mine = sent?.id === v.id ? sent : null;
            const part = v.seconds && v.position >= 15 ? Math.min(1, v.position / v.seconds) : 0;
            return (
              <li key={v.id}>
                <div className="row history-row">
                  <span className="thumb">
                    <img src={v.thumbnail} alt="" loading="lazy" decoding="async" />
                    {v.seconds ? <span className="length">{formatDuration(v.seconds)}</span> : null}
                    {part > 0 ? (
                      <span className="watched" aria-hidden="true">
                        <span style={{ width: `${part * 100}%` }} />
                      </span>
                    ) : null}
                  </span>
                  <span className="row-main">
                    <span className="video-title">{v.title}</span>
                    <small className="one-line">{mine?.status === "failed" ? mine.error : `${progressText(v)} · ${timeAgo(v.watchedAt)}`}</small>
                  </span>
                  <button
                    className={`play-on${mine?.status === "sent" ? " sent" : ""}`}
                    aria-label={`Play ${v.title} on your glasses`}
                    title="Play on your glasses"
                    disabled={mine?.status === "sending"}
                    onClick={() => void play(v)}
                  >
                    {mine?.status === "sending" ? (
                      <Spinner />
                    ) : (
                      <Icon name={mine?.status === "sent" ? "check" : "play"} size={16} fill={mine?.status === "sent" ? undefined : "currentColor"} />
                    )}
                  </button>
                  <Button variant="ghost" icon="trash" onClick={() => void remove.run(v.id)} aria-label={`Remove ${v.title} from history`} />
                </div>
              </li>
            );
          })}
        </Group>
      ) : (
        <div className="glass card">
          <Empty icon="history" title="Nothing watched yet">
            Videos you play on your glasses show here, from any device.
          </Empty>
        </div>
      )}
      {items.length ? (
        <div className="center-row">
          <Button
            variant={armed ? "danger" : "ghost"}
            icon="trash"
            busy={clear.busy}
            onClick={() => (armed ? void clear.run() : setArmed(true))}
            onBlur={() => setArmed(false)}
          >
            {armed ? "Clear on every device" : "Clear watch history"}
          </Button>
        </div>
      ) : null}
      <ErrorNote message={clear.error} />
    </>
  );
}
