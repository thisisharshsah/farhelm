import { LucideProvider } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { CACHE_PREFIX, useAccount } from "../client/account.ts";
import { useChat, type Arrival } from "../client/chat.ts";
import { useResource } from "../client/resource.ts";
import { DEFAULT_PREFERENCES, Note, Preferences, WebApp, list, type ChatMessage, type Me, type VideoItem } from "../shared/api.ts";
import { formatDuration, rowKey } from "../shared/youtube.ts";
import { modelContext, numberedResults, registerLensTools, type ToolDeps } from "./assistant/tools.ts";
import { AddApps } from "./features/apps/AddApps.tsx";
import { Companion } from "./features/companion/Companion.tsx";
import { Notes } from "./features/notes/Notes.tsx";
import { Pairing } from "./features/pairing/Pairing.tsx";
import { Profile } from "./features/profile/Profile.tsx";
import { AppBar, Page, Toast, TopBar } from "./features/shell/Shell.tsx";
import { tabsFor, type Tab } from "./features/shell/tabs.ts";
import { Site } from "./features/site/Site.tsx";
import { effectOf, nextToAct, type Effect } from "./features/sync/effects.ts";
import { Timer } from "./features/timer/Timer.tsx";
import { formatClock, initialTimer, isDone, isRunning, isTimerState, remaining, started } from "./features/timer/timer.ts";
import { resumeFrom, useWatchHistory } from "./features/youtube/history.ts";
import { activePlayer } from "./features/youtube/player.ts";
import { rowVideos } from "./features/youtube/rows.ts";
import { Watch } from "./features/youtube/Watch.tsx";
import { YouTube } from "./features/youtube/YouTube.tsx";
import { installFocusFallback } from "./lib/focus.ts";
import { DEFAULT_TAB, useRouter } from "./lib/router.ts";
import { DEFAULT_SETTINGS, SETTINGS_KEY, isSettings } from "./lib/settings.ts";
import { readStored, useStoredState, writeStored } from "./lib/storage.ts";
import { Mark } from "./ui/Mark.tsx";

/** The timer belongs to this pair of glasses, not the account. */
const TIMER_KEY = "glasses.timer.v1";
/** Requests kept on the glasses: enough for results and recent searches, small for their storage. */
const CHAT_KEEP = 40;
/** How long a notice stays above the bar. */
const NOTICE_MS = 4000;

const NoteList = list(Note);
const AppList = list(WebApp);
const isNumber = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);

export function App() {
  const stage = useRef<HTMLElement>(null);
  const { state, refresh, signOut } = useAccount();
  const onLinked = useCallback(() => void refresh(), [refresh]);

  useEffect(() => (stage.current ? installFocusFallback(stage.current) : undefined), []);

  let content;
  if (state.status === "loading") {
    content = <Message text="" />;
  } else if (state.status === "signed_out") {
    content = <Pairing onLinked={onLinked} />;
  } else if (state.status === "error") {
    content = <Message text={state.message} action="Try again" onAction={() => void refresh()} />;
  } else {
    content = <SignedIn me={state.me} signOut={signOut} />;
  }
  return (
    <LucideProvider strokeWidth={1.9}>
      <main id="stage" ref={stage}>
        {content}
      </main>
    </LucideProvider>
  );
}

function Message({ text, action, onAction }: { text: string; action?: string; onAction?: () => void }) {
  return (
    <section className="view" aria-live="polite">
      <div className="center">
        <Mark size={64} />
        {text ? <p>{text}</p> : null}
      </div>
      {action ? (
        <button className="btn primary" autoFocus onClick={onAction}>
          {action}
        </button>
      ) : null}
    </section>
  );
}

const latestSearch = (items: ChatMessage[]): { query: string; videos: VideoItem[] } | null => {
  for (let i = items.length - 1; i >= 0; i--) {
    const r = items[i]!.reply;
    if (r.kind === "videos") return { query: r.query, videos: r.videos };
  }
  return null;
};

/** Focus moves into an app: its main item, else its first control. */
function focusPage() {
  const page = document.querySelector(".page");
  const target =
    page?.querySelector<HTMLElement>("[data-primary]") ??
    page?.querySelector<HTMLElement>("button:not([disabled]):not([tabindex='-1']), input:not([disabled])");
  target?.focus();
}

function SignedIn({ me, signOut }: { me: Me; signOut: () => Promise<void> }) {
  const { route, tab, select, go, back } = useRouter();
  const routeRef = useRef(route);
  routeRef.current = route;

  // Cached per account, so the apps show at once on a slow connection.
  const cache = (name: string) => `${CACHE_PREFIX}${me.user.id}:${name}`;
  const notes = useResource("/api/notes", NoteList, { cacheKey: cache("notes") });
  const apps = useResource("/api/apps", AppList, { cacheKey: cache("apps") });
  const prefs = useResource("/api/preferences", Preferences, { cacheKey: cache("preferences") });
  const [timer, setTimer] = useStoredState(TIMER_KEY, initialTimer(), isTimerState);
  const [settings, setSettings] = useStoredState(SETTINGS_KEY, DEFAULT_SETTINGS, isSettings);
  const history = useWatchHistory(cache("history"));
  const [notice, setNotice] = useState<{ text: string; at: number } | null>(null);

  const noteItems = notes.data?.items ?? [];
  const appItems = useMemo(() => apps.data?.items ?? [], [apps.data]);
  const preferences = prefs.data ?? DEFAULT_PREFERENCES;
  const tabs = useMemo(() => tabsFor(appItems), [appItems]);
  const current = tabs.find((t) => t.id === tab) ?? tabs[0]!;

  // A website removed on another device: show the first app instead.
  useEffect(() => {
    if (apps.data && !tabs.some((t) => t.id === tab)) select(DEFAULT_TAB);
  }, [apps.data, tabs, tab, select]);

  const updateNotes = useCallback(
    (change: (prev: Note[]) => Note[]) => notes.set((prev) => ({ items: change(prev?.items ?? []) })),
    [notes.set],
  );
  const updateApps = useCallback(
    (change: (prev: WebApp[]) => WebApp[]) => apps.set((prev) => ({ items: change(prev?.items ?? []) })),
    [apps.set],
  );

  const notify = useCallback((text: string) => setNotice({ text, at: Date.now() }), []);
  useEffect(() => {
    if (!notice) return;
    const id = setTimeout(() => setNotice(null), NOTICE_MS);
    return () => clearTimeout(id);
  }, [notice]);

  const watch = useCallback(
    (video: VideoItem) => {
      const r = routeRef.current;
      if (r.view === "watch") {
        // The next video takes this one's place, so Back still returns to the app.
        go({ view: "watch", video }, { replace: true });
        return;
      }
      // Over YouTube, so Back from the video lands on the results. Over the profile, Back returns to it.
      if (r.view === "tab" && r.tab !== "youtube") select("youtube");
      go({ view: "watch", video });
    },
    [go, select],
  );

  // ---------- requests from the phone, Meta AI or these glasses show up as their result ----------

  const run = useCallback(
    (effect: Effect) => {
      const watching = routeRef.current.view === "watch";
      switch (effect.type) {
        case "watch":
          watch(effect.video);
          break;
        case "tab":
          // Never interrupt a video.
          if (watching) break;
          if (effect.tab === "home") {
            if (routeRef.current.view === "profile") back();
          } else select(effect.tab);
          break;
        case "url":
          // A moment later, so a voice request can still get its answer before Lens leaves.
          setTimeout(() => location.assign(effect.url), 300);
          break;
        case "timer":
          setTimer(started(effect.durationMs, Date.now()));
          if (!watching) select("timer");
          break;
        case "notice":
          notify(effect.text);
          break;
      }
    },
    [watch, back, select, setTimer, notify],
  );

  const actedKey = `glasses.chat.acted.v1:${me.user.id}`;
  const acted = useRef(readStored(actedKey, -1, isNumber));
  const onArrive = useCallback(
    (messages: ChatMessage[], how: Arrival) => {
      // Notes saved through Lens join the list, wherever they were said.
      const saved = messages.flatMap((m) => (m.reply.kind === "note" ? [m.reply.note] : []));
      if (saved.length) {
        updateNotes((prev) => [...saved.filter((n) => !prev.some((p) => p.id === n.id)).reverse(), ...prev]);
      }
      const next = nextToAct(messages, how, acted.current);
      if (next.acted !== acted.current) {
        acted.current = next.acted;
        writeStored(actedKey, next.acted);
      }
      const effect = next.message ? effectOf(next.message, how, Date.now()) : null;
      if (effect) run(effect);
    },
    [actedKey, updateNotes, run],
  );

  const chat = useChat({ cacheKey: cache("chat"), keep: CHAT_KEEP, onArrive });

  // ---------- Meta AI: "Hey Meta, play lofi beats" works while Lens is open ----------

  // Tools read the latest state through this, so they never act on a stale screen.
  const live = useRef({ items: chat.items, timer, notes: noteItems, route, current, tabs, watched: history.items });
  live.current = { items: chat.items, timer, notes: noteItems, route, current, tabs, watched: history.items };
  const toolDeps = useRef<ToolDeps | null>(null);
  toolDeps.current = {
    send: chat.send,
    play: chat.play,
    show: (app) => {
      const { route: r, current: c } = live.current;
      // A video keeps playing, unless the wearer asked to search.
      if (r.view === "watch" && app !== "youtube") return;
      if (r.view !== "tab" || c.id !== app) select(app);
    },
    results: () => {
      const latest = latestSearch(live.current.items);
      // The results row may have grown past the answer: numbers go on along it.
      return activePlayer()?.queue() ?? (latest ? (rowVideos(rowKey({ kind: "search", query: latest.query })) ?? latest.videos) : []);
    },
    player: activePlayer,
    status: () => {
      const { items, timer: t, notes: n, route: r, current: c, tabs: all, watched } = live.current;
      const at = Date.now();
      const results = latestSearch(items);
      const player = activePlayer();
      const video = player?.state();
      return {
        app: r.view === "watch" ? "Video player" : r.view === "profile" ? "Profile and settings" : c.name,
        apps: all.filter((x) => x.kind !== "add").map((x) => x.name),
        results: results ? { query: results.query, top: numberedResults(results.videos) } : null,
        video:
          player && video
            ? {
                title: video.title,
                playing: video.playing,
                position: `${formatDuration(video.at)} of ${formatDuration(video.total)}`,
                up_next: numberedResults(player.queue()),
              }
            : null,
        watched_recently: numberedResults(watched),
        timer: isRunning(t, at) ? `${formatClock(remaining(t, at))} left` : isDone(t, at) ? "finished" : "not running",
        notes: n.length,
      };
    },
  };

  const [voice, setVoice] = useState(false);
  useEffect(() => {
    const ctx = modelContext();
    if (!ctx) return;
    const registration = new AbortController();
    setVoice(registerLensTools(ctx, () => toolDeps.current as ToolDeps, registration.signal) > 0);
    return () => registration.abort();
  }, []);

  // ---------- focus: something always has it, so a swipe always does something ----------

  const view = route.view;
  const lastView = useRef(view);
  useEffect(() => {
    const from = lastView.current;
    lastView.current = view;
    const id = requestAnimationFrame(() => {
      const active = document.activeElement;
      if (active && active !== document.body && document.contains(active)) return;
      // Back from the profile lands on the avatar that opened it; otherwise on the bar.
      document.querySelector<HTMLElement>(from === "profile" && view === "tab" ? "[data-profile]" : ".dock-item.on")?.focus();
    });
    return () => cancelAnimationFrame(id);
  }, [view, tab]);

  useEffect(() => {
    document.documentElement.classList.toggle("still", settings.reduceMotion);
  }, [settings.reduceMotion]);

  const enter = (t: Tab) => {
    if (route.view !== "tab") select(t.id);
    else if (t.kind === "web") location.assign(t.url);
    else focusPage();
  };

  // Where the wearer was in the app, so a swipe up from the bar returns there; a new app starts from its main item.
  const lastInPage = useRef<HTMLElement | null>(null);
  useEffect(() => {
    const remember = (e: FocusEvent) => {
      if (e.target instanceof HTMLElement && e.target.closest(".page")) lastInPage.current = e.target;
    };
    document.addEventListener("focusin", remember);
    return () => document.removeEventListener("focusin", remember);
  }, []);
  useEffect(() => {
    lastInPage.current = null;
  }, [route.view, tab]);
  const up = () => {
    const last = lastInPage.current;
    if (last?.isConnected && last.closest(".page")) last.focus();
    else focusPage();
  };

  if (route.view === "watch") {
    return (
      <div className="screen watching" key={`watch-${route.video.id}`}>
        <Watch
          video={route.video}
          resumeAt={resumeFrom(history.items.find((h) => h.id === route.video.id))}
          back={back}
          open={watch}
          saveProgress={history.record}
          autoplay={settings.autoplay}
          numbers={voice && settings.numbers}
          history={history.items}
        />
      </div>
    );
  }

  let page;
  if (route.view === "profile") {
    page = (
      <Profile
        me={me}
        settings={settings}
        setSettings={setSettings}
        voice={voice}
        companionLinked={Boolean(preferences.companionLink)}
        websites={appItems.length}
        manageApps={() => select("add")}
        clearSearches={chat.clear}
        clearWatched={history.clear}
        signOut={signOut}
      />
    );
  } else if (current.kind === "web") {
    page = <Site tab={current} />;
  } else if (current.kind === "add") {
    page = <AddApps apps={appItems} update={updateApps} />;
  } else {
    switch (current.id) {
      case "youtube":
        page = <YouTube chat={chat} watch={watch} history={history.items} voice={voice} numbers={settings.numbers} />;
        break;
      case "notes":
        page = <Notes notes={noteItems} update={updateNotes} />;
        break;
      case "timer":
        page = <Timer timer={timer} setTimer={setTimer} />;
        break;
      case "companion":
        page = <Companion link={preferences.companionLink ?? ""} />;
        break;
    }
  }

  const profileOpen = route.view === "profile";
  return (
    <div className="screen shell">
      <TopBar
        name={me.user.name}
        clock24={settings.clock24}
        voice={voice}
        profileOpen={profileOpen}
        onProfile={() => (profileOpen ? back() : go({ view: "profile" }))}
      />
      <Page id={profileOpen ? "profile" : current.id} index={profileOpen ? -1 : tabs.indexOf(current)}>
        {page}
      </Page>
      {notice ? <Toast text={notice.text} at={notice.at} /> : null}
      <AppBar tabs={tabs} selected={current.id} onSelect={select} onEnter={enter} onUp={up} still={settings.reduceMotion} />
    </div>
  );
}
