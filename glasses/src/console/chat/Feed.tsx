import { useState } from "react";
import type { Pending } from "../../client/chat.ts";
import { messageOf } from "../../client/http.ts";
import { useNow } from "../../client/useNow.ts";
import type { ChatMessage, OpenView, VideoItem } from "../../shared/api.ts";
import { EXAMPLES } from "../../shared/intents.ts";
import { spokenDuration } from "../../shared/time.ts";
import { formatDuration } from "../../shared/youtube.ts";
import { SiteTile, YOUTUBE_SITE } from "../apps.tsx";
import { timeAgo } from "../format.ts";
import { Link } from "../router.tsx";
import { Icon, Spinner, Tile, type IconName } from "../ui.tsx";
import { useLensChat } from "./ChatContext.tsx";

const SHOWN_VIDEOS = 4;

const VIEW_ICONS: Record<Exclude<OpenView, "youtube">, { icon: IconName; tone: string }> = {
  home: { icon: "home", tone: "purple" },
  notes: { icon: "note", tone: "yellow" },
  timer: { icon: "timer", tone: "orange" },
  companion: { icon: "companion", tone: "purple" },
  apps: { icon: "apps", tone: "blue" },
};

/** The conversation, newest first: what was said on either device and what Lens did. */
export function Feed({ limit }: { limit?: number }) {
  const chat = useLensChat();
  const now = useNow(30_000);
  const messages = [...chat.items].reverse().slice(0, limit ?? Infinity);
  return (
    <div className="feed" aria-live="polite">
      {[...chat.pending].reverse().map((p) => (
        <PendingCard key={p.clientId} pending={p} />
      ))}
      {messages.map((m) => (
        <MessageCard key={m.id} message={m} now={now} />
      ))}
    </div>
  );
}

function Source({ source, at, now }: { source: ChatMessage["source"]; at: number; now: number }) {
  return (
    <header className="msg-head">
      <span className="msg-src">
        <Icon name={source === "console" ? "phone" : "glasses"} size={14} />
        {source === "console" ? "From your phone" : "From your glasses"}
      </span>
      <time dateTime={new Date(at).toISOString()}>{timeAgo(at, now)}</time>
    </header>
  );
}

function PendingCard({ pending }: { pending: Pending }) {
  const chat = useLensChat();
  return (
    <article className="msg glass">
      <header className="msg-head">
        <span className="msg-src">
          <Icon name="phone" size={14} />
          From your phone
        </span>
      </header>
      <p className="msg-text">{pending.text}</p>
      {pending.status === "sending" ? (
        <p className="reply-working" role="status">
          <Spinner /> Sending to your glasses…
        </p>
      ) : (
        <div className="reply-row reply-error" role="alert">
          <Tile tone="red" icon="alert" size="sm" />
          <span className="row-main">
            <span className="row-title">{pending.error ?? "Not sent."}</span>
          </span>
          <button className="pill" onClick={() => chat.retry(pending.clientId)}>
            <Icon name="retry" size={15} /> Retry
          </button>
          <button className="pill pill-icon" aria-label="Dismiss" onClick={() => chat.dismiss(pending.clientId)}>
            <Icon name="x" size={15} />
          </button>
        </div>
      )}
    </article>
  );
}

function MessageCard({ message, now }: { message: ChatMessage; now: number }) {
  return (
    <article className="msg glass">
      <Source source={message.source} at={message.createdAt} now={now} />
      <p className="msg-text">{message.text}</p>
      <Reply message={message} />
    </article>
  );
}

function Reply({ message }: { message: ChatMessage }) {
  const chat = useLensChat();
  const reply = message.reply;
  switch (reply.kind) {
    case "videos":
      return reply.videos.length ? (
        <Videos videos={reply.videos} playing={reply.autoplay ? reply.videos[0]?.id : undefined} />
      ) : (
        <ReplyRow tone="gray" icon="play" title="No videos found" />
      );
    case "play":
      return (
        <div className="reply-row">
          <Thumb video={reply.video} />
          <span className="row-main">
            <span className="row-title">Playing on your glasses</span>
            <small>{reply.video.title}</small>
          </span>
        </div>
      );
    case "note":
      return <ReplyRow tone="yellow" icon="note" title="Saved to Notes" detail={reply.note.text} to="/notes" />;
    case "timer": {
      const ends = new Date(message.createdAt + reply.durationMs).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
      return <ReplyRow tone="orange" icon="timer" title={`Timer for ${spokenDuration(reply.durationMs)}`} detail={`On your glasses, ends ${ends}`} />;
    }
    case "open": {
      const title = `Opened ${reply.name} on your glasses`;
      if (reply.view === "youtube") {
        return (
          <div className="reply-row">
            <SiteTile url={YOUTUBE_SITE} size="sm" brand />
            <span className="row-main">
              <span className="row-title">{title}</span>
            </span>
          </div>
        );
      }
      const look = reply.view ? VIEW_ICONS[reply.view] : { icon: "globe" as const, tone: "blue" };
      return <ReplyRow tone={look.tone} icon={look.icon} title={title} detail={reply.url ? new URL(reply.url).hostname : undefined} />;
    }
    case "help":
      return (
        <div className="reply-help">
          <p>Here is what Lens understands. Tap one to try it.</p>
          <div className="suggestions wrap">
            {EXAMPLES.map((e) => (
              <button key={e.text} className="suggestion" onClick={() => void chat.send(e.text)}>
                {e.text}
                <small>{e.hint}</small>
              </button>
            ))}
          </div>
        </div>
      );
    case "error":
      return (
        <div className="reply-row reply-error">
          <Tile tone="red" icon="alert" size="sm" />
          <span className="row-main">
            <span className="row-title">{reply.message}</span>
          </span>
          <button className="pill" onClick={() => void chat.send(message.text)}>
            <Icon name="retry" size={15} /> Retry
          </button>
        </div>
      );
  }
}

function ReplyRow({ tone, icon, title, detail, to }: { tone: string; icon: IconName; title: string; detail?: string; to?: string }) {
  const body = (
    <>
      <Tile tone={tone} icon={icon} size="sm" />
      <span className="row-main">
        <span className="row-title">{title}</span>
        {detail ? <small>{detail}</small> : null}
      </span>
      {to ? <Icon name="chevron" size={16} /> : null}
    </>
  );
  return to ? (
    <Link to={to} className="reply-row reply-link">
      {body}
    </Link>
  ) : (
    <div className="reply-row">{body}</div>
  );
}

function Thumb({ video }: { video: VideoItem }) {
  return (
    <span className="thumb">
      {video.thumbnail ? <img src={video.thumbnail} alt="" loading="lazy" decoding="async" /> : null}
      {video.seconds ? <span className="length">{formatDuration(video.seconds)}</span> : null}
    </span>
  );
}

function Videos({ videos, playing }: { videos: VideoItem[]; playing?: string }) {
  const chat = useLensChat();
  const [all, setAll] = useState(false);
  const [state, setState] = useState<{ id: string; status: "sending" | "sent" | "failed"; error?: string } | null>(null);

  const play = async (video: VideoItem) => {
    setState({ id: video.id, status: "sending" });
    try {
      await chat.play(video);
      setState({ id: video.id, status: "sent" });
    } catch (e) {
      setState({ id: video.id, status: "failed", error: messageOf(e) });
    }
  };

  const shown = all ? videos : videos.slice(0, SHOWN_VIDEOS);
  return (
    <>
      <ul className="videos">
        {shown.map((v) => {
          const mine = state?.id === v.id ? state : null;
          return (
            <li key={v.id} className="video">
              <Thumb video={v} />
              <span className="row-main">
                {v.id === playing ? <span className="playing">Playing on your glasses</span> : null}
                <span className="video-title">{v.title}</span>
                <small>{mine?.status === "failed" ? mine.error : v.channel}</small>
              </span>
              <button
                className={`play-on${mine?.status === "sent" ? " sent" : ""}`}
                aria-label={`Play ${v.title} on your glasses`}
                title="Play on your glasses"
                disabled={mine?.status === "sending"}
                onClick={() => void play(v)}
              >
                {mine?.status === "sending" ? <Spinner /> : <Icon name={mine?.status === "sent" ? "check" : "play"} size={16} fill={mine?.status === "sent" ? undefined : "currentColor"} />}
              </button>
            </li>
          );
        })}
      </ul>
      {videos.length > SHOWN_VIDEOS ? (
        <button className="link-button more" onClick={() => setAll((a) => !a)}>
          {all ? "Show fewer" : `Show all ${videos.length}`}
        </button>
      ) : null}
    </>
  );
}
