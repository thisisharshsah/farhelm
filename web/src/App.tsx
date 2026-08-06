import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  RelayTransport,
  type ConnectionState,
  type OutputLine,
  type Pairing,
  type ServerEvent,
  type Transport,
} from "@relayforge/client-core";
import { sessionIdOf, useResource, useRoute } from "./hooks";
import { loopbackTransport, migratePairing, webPairingStore } from "./platform";
import { PairingScreen } from "./components/Pairing";
import { PushSettings } from "./components/PushSettings";
import { NewSession } from "./components/NewSession";
import { NewTask, TaskListScreen, TaskReviewScreen } from "./components/Tasks";
import {
  CostStrip,
  DashboardScreen,
  FleetScreen,
  SessionScreen,
  useScrollReset,
} from "./components/views";

type Theme = "system" | "light" | "dark";

function useTheme(): [Theme, () => void] {
  const [theme, setTheme] = useState<Theme>(
    () => (localStorage.getItem("forge-theme") as Theme | null) ?? "system",
  );

  useEffect(() => {
    const root = document.documentElement;
    if (theme === "system") root.removeAttribute("data-theme");
    else root.setAttribute("data-theme", theme);
    localStorage.setItem("forge-theme", theme);
  }, [theme]);

  const cycle = useCallback(
    () =>
      setTheme((current) =>
        current === "system" ? "light" : current === "light" ? "dark" : "system",
      ),
    [],
  );

  return [theme, cycle];
}

const THEME_GLYPH: Record<Theme, string> = {
  system: "◐",
  light: "☀",
  dark: "☾",
};

export default function App() {
  const [route, navigate] = useRoute();
  const [theme, cycleTheme] = useTheme();

  /**
   * One counter drives every refetch. The SSE stream tells us *that* something
   * changed; the client re-reads the authoritative state rather than trying to
   * patch its own copy — far fewer ways to drift out of sync.
   */
  const [revision, setRevision] = useState(0);
  const bump = useCallback(() => setRevision((value) => value + 1), []);

  /**
   * Which transport is live. A stored pairing means this device has been taken
   * off the runner's network at least once, so the relay is the right default —
   * it works from anywhere, including at home.
   *
   * `undefined` means "not read yet". The store is async because React Native's
   * is; on the web it settles in a microtask, but starting a loopback transport
   * and immediately replacing it with a relay one would flash an error on a
   * paired phone that is off the network.
   */
  const [pairing, setPairing] = useState<Pairing | null | undefined>(undefined);
  const [pairingOpen, setPairingOpen] = useState(false);
  const [connection, setConnection] = useState<ConnectionState>("connecting");

  useEffect(() => {
    // The migration runs first and only matters once: a pairing written by a
    // `localStorage` build would otherwise look like no pairing at all, and the
    // app would quietly ask you to pair again from a network you are not on.
    // The `.catch` is load-bearing: `pairing` stays `undefined` until this
    // settles, and every screen renders a spinner in that state. Without it a
    // failed IndexedDB open — private browsing, a quota error, a corrupt store —
    // leaves the app loading forever with nothing on screen explaining why.
    // Unreadable means "not paired", which is a working app on loopback.
    void migratePairing()
      .then(() => webPairingStore.load())
      .then(setPairing)
      .catch(() => setPairing(null));
  }, []);

  // The service worker pings the page when a wake-up lands while it is open.
  // The WebSocket usually got there first; this covers the case where it was
  // asleep and is still reconnecting.
  useEffect(() => {
    if (!("serviceWorker" in navigator)) return;
    const onMessage = (event: MessageEvent) => {
      if ((event.data as { type?: string })?.type === "push-wake") bump();
    };
    navigator.serviceWorker.addEventListener("message", onMessage);
    return () => navigator.serviceWorker.removeEventListener("message", onMessage);
  }, [bump]);

  const transportRef = useRef<Transport | null>(null);
  const [transportRevision, setTransportRevision] = useState(0);

  useEffect(() => {
    if (pairing === undefined) return;
    const transport: Transport = pairing
      ? new RelayTransport(pairing)
      : loopbackTransport();
    transportRef.current = transport;
    setTransportRevision((value) => value + 1);

    const offState = transport.onConnectionChange(setConnection);
    const offEvent = transport.onEvent((event) => onEventRef.current(event));

    return () => {
      offState();
      offEvent();
      transport.close();
      transportRef.current = null;
    };
  }, [pairing]);

  /** Output arrives line by line, so it is appended rather than refetched. */
  const [liveOutput, setLiveOutput] = useState<Record<string, OutputLine[]>>({});
  /** A refusal the runner sent back over the relay. */
  const [refusal, setRefusal] = useState<string | null>(null);

  const onEventRef = useRef<(event: ServerEvent) => void>(() => {});
  const onEvent = useCallback((event: ServerEvent) => {
    switch (event.type) {
      case "output_chunk":
        setLiveOutput((current) => {
          const existing = current[event.session_id] ?? [];
          if (existing.some((line) => line.seq === event.seq)) return current;
          return {
            ...current,
            [event.session_id]: [
              ...existing,
              { seq: event.seq, text: event.text, at_ms: event.at_ms },
            ].slice(-200),
          };
        });
        break;
      case "command_error":
        setRefusal(event.message);
        break;
      default:
        setRevision((value) => value + 1);
    }
  }, []);

  onEventRef.current = onEvent;

  const transport = transportRef.current;
  const deps = [revision, transportRevision] as const;

  const fleet = useResource(
    () =>
      transportRef.current?.fleet() ??
      // Before the stored pairing has been read there is nothing to ask. An
      // empty fleet renders as "loading", which is what is actually happening.
      new Promise<never>(() => {}),
    deps,
  );
  const sessionId = sessionIdOf(route);
  const session = useResource(
    () =>
      sessionId && transportRef.current
        ? transportRef.current.session(sessionId)
        : Promise.resolve(null),
    [sessionId, ...deps],
  );
  const dashboard = useResource(
    () =>
      route.view === "cost" && transportRef.current
        ? transportRef.current.dashboard(route.id)
        : Promise.resolve(null),
    [route.view === "cost" ? route.id : null, ...deps],
  );

  const taskId = route.view === "task" ? route.id : null;
  const tasks = useResource(
    () =>
      route.view === "tasks" && transportRef.current
        ? transportRef.current.tasks()
        : Promise.resolve(null),
    [route.view === "tasks", ...deps],
  );
  const task = useResource(
    () =>
      taskId && transportRef.current
        ? transportRef.current.task(taskId)
        : Promise.resolve(null),
    [taskId, ...deps],
  );

  useScrollReset(`${route.view}:${sessionId ?? taskId ?? ""}`);

  // Merge the streamed tail onto the snapshot the API returned, de-duplicated
  // by sequence number so a reconnect cannot double-print.
  const mergedSession = useMemo(() => {
    if (!session.data) return null;
    const streamed = liveOutput[session.data.id] ?? [];
    if (streamed.length === 0) return session.data;

    const bySeq = new Map<number, OutputLine>();
    for (const line of [...session.data.output, ...streamed]) {
      bySeq.set(line.seq, line);
    }
    return {
      ...session.data,
      output: [...bySeq.values()].sort((a, b) => a.seq - b.seq).slice(-200),
    };
  }, [session.data, liveOutput]);

  const title =
    route.view === "fleet"
      ? "RelayForge"
      : route.view === "tasks"
        ? "Tasks"
        : route.view === "new-task"
          ? "New task"
          : route.view === "new-session"
            ? "New session"
            : route.view === "task"
              ? (task.data?.repo_name ?? "Task")
              : (mergedSession?.repo_name ?? "Session");

  /** Where "← Back" goes from here. */
  const backTo =
    route.view === "cost"
      ? `/s/${route.id}`
      : route.view === "task" || route.view === "new-task"
        ? "/t"
        : "/";

  const staleClass = (stale: boolean) => (stale ? "stale" : undefined);

  return (
    <div className="shell">
      <header className="topbar">
        {route.view !== "fleet" ? (
          <button className="back" onClick={() => navigate(backTo)}>
            ← Back
          </button>
        ) : null}
        <h1>{title}</h1>
        {route.view === "session" && mergedSession ? (
          <span className="session-machine">{mergedSession.machine_name}</span>
        ) : null}
        <span className="spacer" />
        {route.view === "fleet" ? (
          <button
            className="icon-button"
            onClick={() => navigate("/t")}
            aria-label="Tasks"
            title="Tasks — the agent's proposed changes"
          >
            ⌥
          </button>
        ) : null}
        {connection !== "open" ? (
          <span className="muted" style={{ fontSize: "0.75rem" }}>
            reconnecting…
          </span>
        ) : null}
        <button
          className="icon-button"
          onClick={() => setPairingOpen((open) => !open)}
          aria-label={
            pairing ? "Paired over the relay. Tap to manage." : "Pair this device"
          }
          title={pairing ? "Paired (relay)" : "Not paired (loopback)"}
        >
          {pairing ? "🔗" : "⛓"}
        </button>
        <button
          className="icon-button"
          onClick={cycleTheme}
          aria-label={`Theme: ${theme}. Tap to change.`}
          title={`Theme: ${theme}`}
        >
          {THEME_GLYPH[theme]}
        </button>
      </header>

      <main>
        {refusal ? (
          <div className="card error" role="alert">
            <b>The runner refused that.</b>
            <p className="tile-note">{refusal}</p>
            <button
              className="btn"
              onClick={() => setRefusal(null)}
              style={{ marginTop: 8 }}
            >
              Dismiss
            </button>
          </div>
        ) : null}

        {pairingOpen ? (
          pairing ? (
            <section className="card">
              <div className="chart-title">Paired</div>
              <p className="tile-note">
                This device talks to the runner through{" "}
                <code>{pairing.relayUrl}</code>, end-to-end encrypted — the relay
                carries ciphertext it cannot read. Starting a session or a task
                still happens on the runner's own machine; everything else,
                including the cost dashboard, works from here.
              </p>

              <PushSettings pairing={pairing} />

              <div className="approval-actions">
                <button className="btn" onClick={() => setPairingOpen(false)}>
                  Close
                </button>
                <button
                  className="btn btn-deny"
                  onClick={() => {
                    void webPairingStore.forget().then(() => {
                      setPairing(null);
                      setPairingOpen(false);
                    });
                  }}
                >
                  Unpair
                </button>
              </div>
            </section>
          ) : (
            <PairingScreen
              onPaired={(next) => {
                setPairing(next);
                setPairingOpen(false);
              }}
              onCancel={() => setPairingOpen(false)}
            />
          )
        ) : null}

        {route.view === "fleet" ? (
          fleet.error ? (
            <div className="card error">
              <b>Cannot reach the runner.</b>
              <p className="tile-note">{fleet.error}</p>
              <button className="btn" onClick={fleet.reload} style={{ marginTop: 8 }}>
                Retry
              </button>
            </div>
          ) : fleet.loading ? (
            <p className="empty">Loading fleet…</p>
          ) : fleet.data ? (
            <div className={staleClass(fleet.stale)}>
              <FleetScreen
                fleet={fleet.data}
                onOpen={(id) => navigate(`/s/${id}`)}
                onOpenTask={(id) => navigate(`/t/${id}`)}
                onChanged={bump}
                onNewSession={() => navigate("/new")}
                transport={transport}
              />
            </div>
          ) : null
        ) : null}

        {route.view === "new-session" ? (
          <NewSession
            transport={transport}
            fleet={fleet.data}
            onStarted={(id) => navigate(`/s/${id}`)}
            onCancel={() => navigate("/")}
          />
        ) : null}

        {route.view === "tasks" ? (
          tasks.error ? (
            <div className="card error">
              <b>Tasks unavailable.</b>
              <p className="tile-note">{tasks.error}</p>
            </div>
          ) : tasks.data ? (
            <div className={staleClass(tasks.stale)}>
              <TaskListScreen
                tasks={tasks.data}
                onOpen={(id) => navigate(`/t/${id}`)}
                onNewTask={() => navigate("/t/new")}
                transport={transport}
              />
            </div>
          ) : (
            <p className="empty">Loading tasks…</p>
          )
        ) : null}

        {route.view === "new-task" ? (
          <NewTask
            transport={transport}
            onStarted={(id) => navigate(`/t/${id}`)}
            onCancel={() => navigate("/t")}
          />
        ) : null}

        {route.view === "task" ? (
          task.error ? (
            <div className="card error">
              <b>Task unavailable.</b>
              <p className="tile-note">{task.error}</p>
            </div>
          ) : task.data ? (
            <div className={staleClass(task.stale)}>
              <TaskReviewScreen
                task={task.data}
                transport={transport}
                onReviewed={bump}
                onOpenTask={(id) => navigate(`/t/${id}`)}
              />
            </div>
          ) : (
            <p className="empty">Loading task…</p>
          )
        ) : null}

        {route.view === "session" ? (
          session.error ? (
            <div className="card error">
              <b>Session unavailable.</b>
              <p className="tile-note">{session.error}</p>
            </div>
          ) : mergedSession ? (
            <div className={staleClass(session.stale)}>
              <SessionScreen
                session={mergedSession}
                onChanged={bump}
                transport={transport}
                onCost={() => navigate(`/s/${route.id}/cost`)}
                onStopped={() => navigate("/")}
              />
            </div>
          ) : (
            <p className="empty">Loading session…</p>
          )
        ) : null}

        {route.view === "cost" ? (
          dashboard.error ? (
            <div className="card error">
              <b>Dashboard unavailable.</b>
              <p className="tile-note">{dashboard.error}</p>
            </div>
          ) : dashboard.data ? (
            <div className={staleClass(dashboard.stale)}>
              <DashboardScreen dashboard={dashboard.data} />
            </div>
          ) : (
            <p className="empty">Loading cost…</p>
          )
        ) : null}
      </main>

      {fleet.data ? <CostStrip fleet={fleet.data} /> : null}
    </div>
  );
}
