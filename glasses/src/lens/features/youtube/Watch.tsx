import {
  FastForwardIcon,
  GaugeIcon,
  LoaderCircleIcon,
  PauseIcon,
  PlayIcon,
  RewindIcon,
  RotateCcwIcon,
  RotateCwIcon,
  SkipForwardIcon,
  Undo2Icon,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { HistoryItem, VideoItem } from "../../../shared/api.ts";
import { formatDuration } from "../../../shared/youtube.ts";
import { seekSeconds, useHold } from "./hold.ts";
import { loadIframeApi, playerErrorMessage, type YTPlayer } from "./iframeApi.ts";
import { setActivePlayer } from "./player.ts";
import { useNow } from "../../lib/useNow.ts";
import { Glass } from "../../ui/Glass.tsx";
import { BUTTON_LENS } from "../../ui/lensField.ts";
import { Details } from "./Details.tsx";
import { useDetails } from "./details.ts";
import { Feed } from "./Feed.tsx";
import { watchedPart } from "./history.ts";
import { feedSources, useFeed } from "./rows.ts";
import { VideoCard } from "./VideoCard.tsx";

/** Controls fade away while playing after this long without a swipe or pinch. */
const HIDE_AFTER_MS = 3500;
/** When a video ends, the next one starts after this, unless the wearer acts. */
const COUNTDOWN_SECONDS = 8;
const RATES = [1, 1.25, 1.5, 2, 0.75];
/** While playing, where the video is gets saved to history this often. */
const SAVE_EVERY_MS = 30_000;
/**
 * Over a moving picture, the controls' glass is frosted so their icons read (its tint, in CSS, darkens it).
 * Blur only: Chromium leaves colour filters on the backdrop unclipped, a square around a round button.
 */
const FROST = "blur(10px)";

type PlayerStatus = { kind: "loading" } | { kind: "ready"; playing: boolean } | { kind: "ended" } | { kind: "error"; message: string };

interface WatchProps {
  video: VideoItem;
  /** Where to start: where it was left last time, or 0. */
  resumeAt: number;
  back: () => void;
  /** Opens another video in place of this one. */
  open: (video: VideoItem) => void;
  /** Saves the video to watch history, up to a position. */
  saveProgress: (video: VideoItem, position: number, options?: { leaving?: boolean }) => void;
  /** Play the next video when one ends (a setting). */
  autoplay: boolean;
  /** Numbers on Up next, for "Hey Meta, play number two". */
  numbers: boolean;
  /** Watch history, newest first: what recommendations follow after this video. */
  history: HistoryItem[];
}

/**
 * Plays one video full screen in YouTube's embedded player, with Lens's own
 * controls floating over the picture as liquid glass: replay, back 10, play
 * or pause, forward 10, next, and speed. Back and forward keep seeking while
 * held. The controls fade while it plays and come back on any swipe. Below
 * the picture, as on a TV: the video's details, then Up next, a row of more
 * by the same artist or on the same topic. Where the video is gets saved to
 * watch history, so it resumes there on any device.
 *
 * The player frame is `inert`: if focus could enter it, arrow keys would go to
 * YouTube and the glasses could get stuck inside the frame.
 */
export function Watch({ video, resumeAt, back, open, saveProgress, autoplay, numbers, history }: WatchProps) {
  const root = useRef<HTMLElement>(null);
  const frame = useRef<HTMLDivElement>(null);
  const overlay = useRef<HTMLDivElement>(null);
  const player = useRef<YTPlayer | null>(null);
  const playButton = useRef<HTMLButtonElement>(null);
  // Fixed for this video: history changes while it plays.
  const [startAt] = useState(() => Math.floor(resumeAt));
  const [status, setStatus] = useState<PlayerStatus>({ kind: "loading" });
  const [time, setTime] = useState({ at: startAt, total: video.seconds ?? 0 });
  const [shown, setShown] = useState(true);
  const [rate, setRate] = useState(1);
  const [countdown, setCountdown] = useState<number | null>(null);
  const [note, setNote] = useState<string | null>(startAt ? `Resumed at ${formatDuration(startAt)}` : null);
  const now = useNow(60_000);
  // A video from history arrives without views, likes or age: they are filled in.
  const [about] = useDetails([video]);
  // Up next, then more rows of recommendations as the wearer moves down.
  const feed = useFeed(feedSources(history, video));
  const upNext = feed.entries.find((e) => e.from === 0 && e.row.kind === "related")?.row;
  const following = useMemo(() => (upNext?.videos ?? []).filter((v) => v.id !== video.id), [upNext, video.id]);
  const watched = useMemo(() => new Map(history.map((h) => [h.id, h])), [history]);
  const thisVideo = useMemo(() => new Set([video.id]), [video.id]);
  const followingRef = useRef(following);
  followingRef.current = following;
  const save = useRef(saveProgress);
  save.current = saveProgress;
  const scrubbing = useRef<{ dir: 1 | -1; from: number; at: number } | null>(null);
  const [scrub, setScrub] = useState<{ dir: 1 | -1; from: number; at: number } | null>(null);

  // ---------- the player ----------

  useEffect(() => {
    const host = frame.current;
    if (!host) return;
    let disposed = false;
    let started = false;
    // The API replaces the element it is given, so give it one React does not own.
    const target = document.createElement("div");
    host.append(target);
    const position = () => player.current?.getCurrentTime() || 0;

    loadIframeApi().then(
      (YT) => {
        if (disposed) return;
        player.current = new YT.Player(target, {
          videoId: video.id,
          // No cookies until the video plays.
          host: "https://www.youtube-nocookie.com",
          width: "100%",
          height: "100%",
          playerVars: {
            autoplay: 1,
            controls: 0,
            playsinline: 1,
            rel: 0,
            iv_load_policy: 3,
            disablekb: 1,
            origin: location.origin,
            ...(startAt ? { start: startAt } : {}),
          },
          events: {
            onReady: (e) => {
              if (disposed) return;
              const iframe = e.target.getIframe();
              iframe.inert = true;
              iframe.tabIndex = -1;
              iframe.setAttribute("allow", "autoplay; encrypted-media");
              // History can be off about the length: never resume at the very end.
              const length = e.target.getDuration();
              if (startAt && length && startAt >= length - 20) e.target.seekTo(0, true);
              setStatus({ kind: "ready", playing: e.target.getPlayerState() === YT.PlayerState.PLAYING });
            },
            onStateChange: (e) => {
              if (disposed) return;
              if (e.data === YT.PlayerState.ENDED) {
                const total = e.target.getDuration() || video.seconds || 0;
                setTime({ at: total, total });
                setStatus({ kind: "ended" });
                save.current(video, total);
              } else if (e.data === YT.PlayerState.PLAYING) {
                setStatus({ kind: "ready", playing: true });
                // In history from the moment it really plays.
                if (!started) save.current(video, Math.max(startAt, position()));
                started = true;
              } else if (e.data === YT.PlayerState.PAUSED) {
                setStatus({ kind: "ready", playing: false });
                save.current(video, position());
              }
            },
            onError: (e) => !disposed && setStatus({ kind: "error", message: playerErrorMessage(e.data) }),
          },
        });
      },
      (e: unknown) => !disposed && setStatus({ kind: "error", message: e instanceof Error ? e.message : "Player failed." }),
    );

    // Lens closing or hidden: save where it was.
    const onHide = () => {
      if (started && document.visibilityState === "hidden") save.current(video, position(), { leaving: true });
    };
    document.addEventListener("visibilitychange", onHide);

    return () => {
      disposed = true;
      document.removeEventListener("visibilitychange", onHide);
      const p = player.current;
      if (started && p && p.getPlayerState() !== 0) save.current(video, p.getCurrentTime() || 0, { leaving: true });
      p?.destroy();
      player.current = null;
      host.replaceChildren();
    };
  }, [video, startAt]);

  // Progress, read from the player twice a second while it plays (not while seeking by hand).
  useEffect(() => {
    if (status.kind !== "ready") return;
    const id = setInterval(() => {
      const p = player.current;
      if (p && !scrubbing.current) setTime({ at: p.getCurrentTime() || 0, total: p.getDuration() || video.seconds || 0 });
    }, 500);
    return () => clearInterval(id);
  }, [status.kind, video.seconds]);

  const ready = status.kind === "ready" || status.kind === "ended";
  const playing = status.kind === "ready" && status.playing;

  // Saved to history now and then while it plays, so another device resumes close to here.
  useEffect(() => {
    if (!playing) return;
    const id = setInterval(() => save.current(video, player.current?.getCurrentTime() || 0), SAVE_EVERY_MS);
    return () => clearInterval(id);
  }, [playing, video]);

  const togglePlay = () => {
    const p = player.current;
    if (!p) return;
    if (status.kind === "ended") {
      p.seekTo(0, true);
      p.playVideo();
    } else if (playing) p.pauseVideo();
    else p.playVideo();
  };
  const skip = useCallback((delta: number) => {
    const p = player.current;
    if (!p) return;
    const total = p.getDuration() || Infinity;
    p.seekTo(Math.min(Math.max(0, p.getCurrentTime() + delta), total), true);
  }, []);
  const restart = useCallback(() => {
    player.current?.seekTo(0, true);
    player.current?.playVideo();
  }, []);
  const playNext = useCallback(() => {
    const first = followingRef.current[0];
    if (first) open(first);
    return Boolean(first);
  }, [open]);
  const cycleRate = () => {
    const nextRate = RATES[(RATES.indexOf(rate) + 1) % RATES.length] ?? 1;
    player.current?.setPlaybackRate(nextRate);
    setRate(nextRate);
  };

  // ---------- controls that float over the picture ----------

  const shownRef = useRef(shown);
  shownRef.current = shown;
  const playingRef = useRef(playing);
  playingRef.current = playing;
  const hideTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const wake = useCallback(() => {
    setShown(true);
    if (hideTimer.current) clearTimeout(hideTimer.current);
    hideTimer.current = setTimeout(() => setShown(false), HIDE_AFTER_MS);
  }, []);
  // Always visible while paused, ended, loading or failed; they fade only while playing.
  useEffect(() => {
    if (playing) wake();
    else {
      if (hideTimer.current) clearTimeout(hideTimer.current);
      setShown(true);
    }
    return () => {
      if (hideTimer.current) clearTimeout(hideTimer.current);
    };
  }, [playing, wake]);

  // A swipe or pinch while the controls are hidden only brings them back.
  useEffect(() => {
    const el = root.current;
    if (!el) return;
    const onKey = (e: KeyboardEvent) => {
      setCountdown(null);
      const inControls = overlay.current?.contains(document.activeElement) || document.activeElement === document.body;
      if (!shownRef.current && inControls && !e.repeat) {
        e.preventDefault();
        e.stopPropagation();
      }
      if (playingRef.current) wake();
      else setShown(true);
    };
    el.addEventListener("keydown", onKey, true);
    return () => el.removeEventListener("keydown", onKey, true);
  }, [wake]);

  // Focus Play once the player can take it (a disabled button cannot).
  useEffect(() => {
    if (ready && (document.activeElement === document.body || document.activeElement === null)) playButton.current?.focus();
  }, [ready]);

  // A note in the overlay ("Resumed at 2:10") goes after a few seconds.
  useEffect(() => {
    if (!note) return;
    const id = setTimeout(() => setNote(null), 4000);
    return () => clearTimeout(id);
  }, [note]);

  // ---------- back and forward: a press skips 10 seconds, holding keeps seeking ----------

  const seekStep = (dir: 1 | -1) => (heldMs: number) => {
    const p = player.current;
    if (!p) return;
    const total = p.getDuration() || video.seconds || 0;
    const from = scrubbing.current?.at ?? (p.getCurrentTime() || 0);
    const at = Math.min(Math.max(0, from + dir * seekSeconds(heldMs, total)), total || Infinity);
    p.seekTo(at, true);
    setTime({ at, total });
    if (heldMs > 0) {
      scrubbing.current = { dir, from: scrubbing.current?.from ?? from, at };
      setScrub(scrubbing.current);
    }
    wake();
  };
  const seekEnd = () => {
    scrubbing.current = null;
    setTimeout(() => !scrubbing.current && setScrub(null), 700);
  };
  const holdBack = useHold(seekStep(-1), seekEnd);
  const holdForward = useHold(seekStep(1), seekEnd);

  // ---------- the end: count down to the next video ----------

  // Also when Up next arrives after the video ended.
  const hasNext = following.length > 0;
  useEffect(() => {
    if (status.kind === "ended" && autoplay && hasNext) setCountdown(COUNTDOWN_SECONDS);
    else setCountdown(null);
  }, [status.kind, autoplay, hasNext]);
  useEffect(() => {
    if (countdown === null) return;
    if (countdown <= 0) {
      playNext();
      return;
    }
    const id = setTimeout(() => setCountdown((c) => (c === null ? null : c - 1)), 1000);
    return () => clearTimeout(id);
  }, [countdown, playNext]);

  // ---------- Meta AI: "Hey Meta, pause", "next", "go back 30 seconds" ----------

  useEffect(() => {
    if (!ready) return;
    setActivePlayer({
      play: () => {
        const p = player.current;
        if (!p) return;
        if (p.getCurrentTime() >= (p.getDuration() || Infinity) - 0.5) p.seekTo(0, true);
        p.playVideo();
      },
      pause: () => player.current?.pauseVideo(),
      skip,
      restart,
      next: playNext,
      queue: () => followingRef.current,
      state: () => {
        const p = player.current;
        return {
          title: video.title,
          playing: p?.getPlayerState() === 1,
          at: p?.getCurrentTime() || 0,
          total: p?.getDuration() || video.seconds || 0,
        };
      },
    });
    return () => setActivePlayer(null);
  }, [ready, video, skip, restart, playNext]);

  const failed = status.kind === "error";
  const progress = time.total > 0 ? Math.min(1, time.at / time.total) : 0;
  const playLabel = status.kind === "ended" ? "Replay" : playing ? "Pause" : "Play";
  const nextTitle = following[0]?.title;
  const scrubText = scrub
    ? `${formatDuration(scrub.at)}  (${scrub.dir > 0 ? "+" : "−"}${formatDuration(Math.abs(scrub.at - scrub.from))})`
    : null;

  return (
    <section className="view watch" aria-label={video.title} ref={root}>
      <div className="video">
        {/* The player's own element: React never renders into it, because the
            YouTube API replaces what is inside and React would lose track. */}
        <div className="video-frame" ref={frame} />
        {status.kind === "loading" ? (
          <p className="video-note">
            <LoaderCircleIcon size={34} className="spin" />
          </p>
        ) : null}
        {failed ? <p className="video-note">{status.message}</p> : null}

        <div
          className={`overlay${shown ? " shown" : ""}${status.kind === "ended" ? " ended" : ""}`}
          ref={overlay}
          onClickCapture={(e) => {
            if (shownRef.current) return;
            e.preventDefault();
            e.stopPropagation();
            wake();
          }}
        >
          <div className="overlay-top">
            <p className="overlay-title">{video.title}</p>
            <button className="glass-chip liquid" disabled={!ready} onClick={cycleRate} aria-label={`Speed ${rate} times`}>
              <Glass lens={BUTTON_LENS} frost={FROST} />
              <GaugeIcon size={18} />
              {rate}×
            </button>
          </div>
          <div className="overlay-controls">
            <button className="glass-btn liquid" disabled={!ready} onClick={restart} aria-label="Replay from the start">
              <Glass lens={BUTTON_LENS} frost={FROST} />
              <Undo2Icon size={24} />
            </button>
            <button className="glass-btn liquid" disabled={!ready} aria-label="Back 10 seconds, hold to rewind" {...holdBack}>
              <Glass lens={BUTTON_LENS} frost={FROST} />
              {scrub?.dir === -1 ? (
                <RewindIcon size={24} fill="currentColor" />
              ) : (
                <>
                  <RotateCcwIcon size={24} />
                  <span className="glass-btn-num">10</span>
                </>
              )}
            </button>
            <button
              ref={playButton}
              className="glass-btn glass-btn-main liquid"
              disabled={!ready}
              onClick={togglePlay}
              aria-label={playLabel}
            >
              <Glass lens={BUTTON_LENS} frost={FROST} />
              {status.kind === "ended" ? (
                <RotateCcwIcon size={34} />
              ) : playing ? (
                <PauseIcon size={34} fill="currentColor" />
              ) : (
                <PlayIcon size={34} fill="currentColor" />
              )}
            </button>
            <button className="glass-btn liquid" disabled={!ready} aria-label="Forward 10 seconds, hold to fast forward" {...holdForward}>
              <Glass lens={BUTTON_LENS} frost={FROST} />
              {scrub?.dir === 1 ? (
                <FastForwardIcon size={24} fill="currentColor" />
              ) : (
                <>
                  <RotateCwIcon size={24} />
                  <span className="glass-btn-num">10</span>
                </>
              )}
            </button>
            <button
              className={`glass-btn liquid${countdown !== null ? " counting" : ""}`}
              disabled={!nextTitle}
              onClick={() => playNext()}
              aria-label={nextTitle ? `Next: ${nextTitle}` : "Next"}
              style={countdown !== null ? { ["--left" as string]: countdown / COUNTDOWN_SECONDS } : undefined}
            >
              <Glass lens={BUTTON_LENS} frost={FROST} />
              <SkipForwardIcon size={24} fill="currentColor" />
            </button>
          </div>
          <div className="overlay-bottom">
            <span className="overlay-time">{formatDuration(time.at)}</span>
            <span className="overlay-bar" aria-hidden="true">
              <span style={{ width: `${progress * 100}%` }} />
            </span>
            <span className="overlay-time">{time.total ? formatDuration(time.total) : "--:--"}</span>
          </div>
          {scrubText ? (
            <p className="overlay-next scrub" role="status">
              {scrubText}
            </p>
          ) : countdown !== null && nextTitle ? (
            <p className="overlay-next" role="status">
              Next in {countdown}: {nextTitle}
            </p>
          ) : note ? (
            <p className="overlay-next" role="status">
              {note}
            </p>
          ) : null}
        </div>
      </div>

      <Details video={about ?? video} now={now} />

      <Feed
        feed={feed}
        place="player"
        skip={thisVideo}
        card={(v, i, entry) => {
          const seen = watched.get(v.id);
          const numbered = numbers && entry.from === 0 && entry.row.kind === "related";
          return (
            <VideoCard video={v} now={now} index={numbered ? i + 1 : undefined} watched={seen ? watchedPart(seen) : undefined} onClick={() => open(v)} />
          );
        }}
      />
      {!feed.entries.length && !feed.loading ? (
        <button className="btn" onClick={back}>
          Back to YouTube
        </button>
      ) : null}
    </section>
  );
}
