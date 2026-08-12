import { useCallback, useEffect, useMemo, useState } from "react";
import type { OutputLine, ServerEvent } from "@relayforge/client-core";
import { sessionIdOf, useResource, useRoute } from "./hooks";
import { migratePairing, webPairingStore } from "./platform";
import { loopbackAvailable, useConnection } from "./connection";
import { AuthScreen, MachinePicker, WelcomeScreen, readableError } from "./components/Auth";
import { AccountScreen, BillingScreen } from "./components/Account";
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
import { Sidebar } from "./components/Sidebar";
import { Palette, type Action } from "./components/Palette";
import { Icon } from "./components/Icon";

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

export default function App() {
  const [route, navigate] = useRoute();
  const [theme, cycleTheme] = useTheme();
  const [paletteOpen, setPaletteOpen] = useState(false);

  // ⌘K on a Mac, Ctrl-K elsewhere, and `/` when the caret is not already in a
  // field — the three bindings people try without being told.
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      const typing =
        target?.tagName === "INPUT" ||
        target?.tagName === "TEXTAREA" ||
        target?.isContentEditable === true;

      if (event.key.toLowerCase() === "k" && (event.metaKey || event.ctrlKey)) {
        event.preventDefault();
        setPaletteOpen((open) => !open);
      } else if (event.key === "/" && !typing && !paletteOpen) {
        event.preventDefault();
        setPaletteOpen(true);
      }
    };
    addEventListener("keydown", onKey);
    return () => removeEventListener("keydown", onKey);
  }, [paletteOpen]);

  /**
   * One counter drives every refetch. The SSE stream tells us *that* something
   * changed; the client re-reads the authoritative state rather than trying to
   * patch its own copy — far fewer ways to drift out of sync.
   */
  const [revision, setRevision] = useState(0);
  const bump = useCallback(() => setRevision((value) => value + 1), []);

  /** Output arrives line by line, so it is appended rather than refetched. */
  const [liveOutput, setLiveOutput] = useState<Record<string, OutputLine[]>>({});
  /** A refusal the runner sent back over the relay. */
  const [refusal, setRefusal] = useState<string | null>(null);

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

  const connection = useConnection(onEvent);
  const transport = connection.transport;

  useEffect(() => {
    // Runs once and only matters once: a pairing written by a `localStorage`
    // build would otherwise look like no pairing at all, and the app would ask
    // for a sign-in that the user does not need yet.
    void migratePairing().catch(() => {});
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

  const [authError, setAuthError] = useState<string | null>(null);
  const [authBusy, setAuthBusy] = useState(false);
  const [authOpen, setAuthOpen] = useState(false);
  const [accountError, setAccountError] = useState<string | null>(null);

  const submitAuth = useCallback(
    (input: Parameters<typeof connection.signIn>[0]) => {
      setAuthBusy(true);
      setAuthError(null);
      connection
        .signIn(input)
        .then(() => {
          setAuthOpen(false);
          navigate("/");
        })
        .catch((cause: unknown) => setAuthError(readableError(cause)))
        .finally(() => setAuthBusy(false));
    },
    [connection, navigate],
  );

  /**
   * Nothing to fetch until there is a transport.
   *
   * A never-resolving promise renders as "loading", which is what is actually
   * happening — an empty fleet would render as "no sessions", which is a lie.
   */
  const idle = <T,>() => new Promise<T>(() => {});
  const deps = [revision, connection.mode, connection.activeRunnerId] as const;

  const fleet = useResource(
    () => transport?.fleet() ?? idle<never>(),
    [transport, ...deps],
  );
  const sessionId = sessionIdOf(route);
  const session = useResource(
    () => (sessionId && transport ? transport.session(sessionId) : Promise.resolve(null)),
    [sessionId, transport, ...deps],
  );
  const dashboard = useResource(
    () =>
      route.view === "cost" && transport
        ? transport.dashboard(route.id)
        : Promise.resolve(null),
    [route.view === "cost" ? route.id : null, transport, ...deps],
  );

  const taskId = route.view === "task" ? route.id : null;
  const tasks = useResource(
    () =>
      route.view === "tasks" && transport ? transport.tasks() : Promise.resolve(null),
    [route.view === "tasks", transport, ...deps],
  );
  const task = useResource(
    () => (taskId && transport ? transport.task(taskId) : Promise.resolve(null)),
    [taskId, transport, ...deps],
  );

  const billing = useResource(
    () =>
      route.view === "billing" && connection.cloud
        ? connection.cloud.billing()
        : Promise.resolve(null),
    [route.view === "billing", connection.cloud, revision],
  );

  useScrollReset(`${route.view}:${sessionId ?? taskId ?? ""}`);

  /**
   * What ⌘K can reach.
   *
   * Built from the fleet snapshot rather than a separate fetch: everything the
   * palette offers is already on screen somewhere, and a palette that shows
   * staler data than the page behind it is worse than no palette.
   */
  const actions = useMemo<Action[]>(() => {
    const list: Action[] = [
      { id: "go-fleet", group: "Go to", icon: "fleet", label: "Fleet",
        hint: "Running sessions and approvals", run: () => navigate("/") },
      { id: "go-tasks", group: "Go to", icon: "tasks", label: "Tasks",
        hint: "Proposed change sets", run: () => navigate("/t") },
      { id: "go-account", group: "Go to", icon: "account", label: "Workspace",
        hint: "Machines, devices, people", run: () => navigate("/account") },
      { id: "go-billing", group: "Go to", icon: "billing", label: "Plan and billing",
        run: () => navigate("/billing") },
    ];

    for (const item of fleet.data?.sessions ?? []) {
      list.push({
        id: `session-${item.id}`,
        group: "Sessions",
        icon: "fleet",
        label: item.repo_name,
        hint: item.machine_name,
        run: () => navigate(`/s/${item.id}`),
      });
    }

    for (const item of fleet.data?.tasks_awaiting_review ?? []) {
      list.push({
        id: `task-${item.id}`,
        group: "Awaiting review",
        icon: "tasks",
        label: item.repo_name,
        hint: "Change set to review",
        run: () => navigate(`/t/${item.id}`),
      });
    }

    if (transport?.supportsTaskControl) {
      list.push({ id: "new-task", group: "Start", icon: "plus", label: "Start a task",
        hint: "Point an agent at a repository", run: () => navigate("/t/new") });
    }
    if (transport?.supportsSessionControl) {
      list.push({ id: "new-session", group: "Start", icon: "plus", label: "Start a session",
        run: () => navigate("/new") });
    }

    for (const runner of connection.workspace?.runners ?? []) {
      if (runner.id === connection.activeRunnerId) continue;
      list.push({
        id: `runner-${runner.id}`,
        group: "Switch machine",
        icon: "machine",
        label: runner.name,
        hint: runner.online ? "Online" : "Offline",
        run: () => connection.pickRunner(runner.id),
      });
    }

    list.push({ id: "theme", group: "Settings", icon: "auto", label: "Change theme",
      hint: theme, run: cycleTheme });
    if (connection.mode === "cloud") {
      list.push({ id: "signout", group: "Settings", icon: "signout", label: "Sign out",
        run: () => void connection.signOut() });
    }
    return list;
  }, [fleet.data, transport, connection, navigate, theme, cycleTheme]);

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

  const activeRunner =
    connection.workspace?.runners.find(
      (runner) => runner.id === connection.activeRunnerId,
    ) ?? null;

  const title =
    route.view === "fleet"
      ? (activeRunner?.name ?? "RelayForge")
      : route.view === "tasks"
        ? "Tasks"
        : route.view === "new-task"
          ? "New task"
          : route.view === "new-session"
            ? "New session"
            : route.view === "account"
              ? "Workspace"
              : route.view === "billing"
                ? "Plan"
                : route.view === "task"
                  ? (task.data?.repo_name ?? "Task")
                  : (mergedSession?.repo_name ?? "Session");

  /** Where "← Back" goes from here. */
  const backTo =
    route.view === "cost"
      ? `/s/${route.id}`
      : route.view === "task" || route.view === "new-task"
        ? "/t"
        : route.view === "billing"
          ? "/account"
          : "/";

  const staleClass = (stale: boolean) => (stale ? "stale" : undefined);

  /* ------------------------------------------------------------ front door */

  if (connection.mode === "loading") {
    return (
      <div className="shell">
        <main>
          <div className="skeleton" aria-busy="true" aria-label="Loading">
            <div className="skeleton-card" />
            <div className="skeleton-card" />
            <div className="skeleton-card" />
          </div>
        </main>
      </div>
    );
  }

  if (connection.mode === "welcome") {
    return (
      <div className="shell">
        <main className="front-door">
          {authOpen ? (
            <AuthScreen
              onSubmit={submitAuth}
              onCancel={() => setAuthOpen(false)}
              busy={authBusy}
              error={authError}
            />
          ) : (
            <WelcomeScreen
              loopbackAvailable={loopbackAvailable()}
              onChoose={(choice) => {
                if (choice === "cloud") setAuthOpen(true);
                else connection.chooseLoopback();
              }}
            />
          )}
        </main>
      </div>
    );
  }

  /* ------------------------------------------------------------- the app */

  const needsMachine = connection.mode === "cloud" && !activeRunner;

  return (
    <div className="shell">
      {paletteOpen ? (
        <Palette actions={actions} onClose={() => setPaletteOpen(false)} />
      ) : null}

      {connection.mode === "cloud" ? (
        <Sidebar
          workspace={connection.workspace}
          route={route}
          activeRunnerId={connection.activeRunnerId}
          connectionState={connection.state}
          theme={theme}
          onNavigate={navigate}
          onPickRunner={connection.pickRunner}
          onCycleTheme={cycleTheme}
          onOpenPalette={() => setPaletteOpen(true)}
          onSignOut={() => void connection.signOut()}
        />
      ) : null}

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
            className="icon-button rail-duplicate"
            onClick={() => navigate("/t")}
            aria-label="Tasks"
            title="Tasks — the agent's proposed changes"
          >
            <Icon name="tasks" />
          </button>
        ) : null}
        {connection.state !== "open" && !needsMachine ? (
          <span className="reconnecting rail-duplicate">reconnecting…</span>
        ) : null}
        {connection.mode === "cloud" ? (
          <button
            className="icon-button rail-duplicate"
            onClick={() => navigate("/account")}
            aria-label="Workspace, machines and plan"
            title={connection.workspace?.org.name ?? "Workspace"}
          >
            <Icon name="account" />
          </button>
        ) : (
          <button
            className="icon-button"
            onClick={connection.chooseCloud}
            aria-label="Sign in to reach this machine from anywhere"
            title="Sign in"
          >
            <Icon name="link" />
          </button>
        )}
        <button
          className="icon-button rail-duplicate"
          onClick={cycleTheme}
          aria-label={`Theme: ${theme}. Tap to change.`}
          title={`Theme: ${theme}`}
        >
          <Icon name={theme === "light" ? "sun" : theme === "dark" ? "moon" : "auto"} />
        </button>
      </header>

      <main>
        {refusal ? (
          <div className="card error" role="alert">
            <b>The runner refused that.</b>
            <p className="tile-note">{refusal}</p>
            <button className="btn" onClick={() => setRefusal(null)} style={{ marginTop: 8 }}>
              Dismiss
            </button>
          </div>
        ) : null}

        {/* Signed in, but this surface holds no device seat. Actionable rather
            than fatal: the workspace screen is exactly where a seat is freed. */}
        {connection.deviceProblem ? (
          <div className="card notice-card" role="status">
            <b>This browser has no device slot.</b>
            {/* Punctuated here rather than trusting the server's wording to
                end in a full stop — it does not, and the two sentences ran
                together into "…Pro allows more You are signed in and…". */}
            <p className="tile-note">
              {connection.deviceProblem.replace(/[.\s]*$/, "")}. You are signed in
              and can manage the workspace — but until a slot frees up, this
              browser cannot open an encrypted link to a machine.
            </p>
            <div className="approval-actions">
              <button className="btn btn-primary" onClick={() => navigate("/account")}>
                Remove a device
              </button>
              <button
                className="btn"
                onClick={() => {
                  void connection.claimDeviceSlot();
                }}
              >
                Try again
              </button>
              <button className="btn" onClick={() => navigate("/billing")}>
                See plans
              </button>
            </div>
          </div>
        ) : null}

        {connection.error ? (
          <div className="card error" role="alert">
            <b>Cannot reach the workspace.</b>
            <p className="tile-note">{connection.error}</p>
            <button className="btn" onClick={connection.refresh} style={{ marginTop: 8 }}>
              Retry
            </button>
          </div>
        ) : null}

        {accountError ? (
          <div className="card error" role="alert">
            <p className="tile-note">{accountError}</p>
          </div>
        ) : null}

        {/* A machine has to be chosen before there is anything to render. */}
        {needsMachine && route.view === "fleet" ? (
          <MachinePicker
            runners={connection.workspace?.runners ?? []}
            onPick={connection.pickRunner}
            onAddMachine={() => navigate("/account")}
            busy={false}
          />
        ) : null}

        {route.view === "account" ? (
          connection.mode === "cloud" && connection.workspace && connection.cloud ? (
            <AccountScreen
              workspace={connection.workspace}
              cloud={connection.cloud}
              onChanged={connection.refresh}
              onBilling={() => navigate("/billing")}
              onSignOut={() => void connection.signOut()}
              activeRunnerId={connection.activeRunnerId}
              onPickRunner={connection.pickRunner}
            />
          ) : (
            <section className="card">
              <div className="chart-title">Not signed in</div>
              <p className="tile-note">
                This browser is talking to a runner on this machine directly.
                Sign in to reach it from your phone as well.
              </p>
              <button className="btn btn-primary" onClick={connection.chooseCloud}>
                Sign in
              </button>
            </section>
          )
        ) : null}

        {route.view === "billing" ? (
          billing.data && connection.cloud && connection.workspace ? (
            <div className={staleClass(billing.stale)}>
              <BillingScreen
                billing={billing.data}
                cloud={connection.cloud}
                role={connection.workspace.role}
                onError={setAccountError}
              />
            </div>
          ) : billing.error ? (
            <div className="card error">
              <b>Plans unavailable.</b>
              <p className="tile-note">{billing.error}</p>
            </div>
          ) : (
            <p className="empty">Loading plans…</p>
          )
        ) : null}

        {route.view === "fleet" && !needsMachine ? (
          fleet.error ? (
            <div className="card error">
              <b>Cannot reach the runner.</b>
              <p className="tile-note">{fleet.error}</p>
              <button className="btn" onClick={fleet.reload} style={{ marginTop: 8 }}>
                Retry
              </button>
            </div>
          ) : connection.deviceProblem && !transport ? (
            // Nothing is being fetched, so a loading skeleton would pulse for
            // ever under a banner that has already explained why. The banner is
            // the whole answer here.
            null
          ) : fleet.loading ? (
            <div className="skeleton" aria-busy="true" aria-label="Loading the fleet">
              <div className="skeleton-card" />
              <div className="skeleton-card" />
              <div className="skeleton-card" />
            </div>
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

        {/* Push needs a channel to subscribe to, which only the relay modes have. */}
        {route.view === "account" && connection.mode === "legacy" ? (
          <LegacyPairing onUnpair={() => void webPairingStore.forget().then(() => location.reload())} />
        ) : null}
      </main>

      {fleet.data ? <CostStrip fleet={fleet.data} /> : null}
    </div>
  );
}

/**
 * The old pairing, still working, with a way out.
 *
 * Kept because a phone that was paired before accounts existed should not stop
 * working the day this ships. Unpairing here sends it to the front door.
 */
function LegacyPairing({ onUnpair }: { onUnpair: () => void }) {
  return (
    <section className="card">
      <div className="chart-title">Paired device</div>
      <p className="tile-note">
        This device was paired before workspaces existed. It still works. Signing
        in instead lets it reach every machine you own rather than the one it was
        paired with.
      </p>
      <button className="btn btn-deny" onClick={onUnpair}>
        Unpair
      </button>
    </section>
  );
}

/** Re-exported so the push settings panel keeps its home. */
export { PushSettings };
