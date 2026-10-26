import { getMigratingSync } from "@farhelm/client-core";
import { useCallback, useEffect, useMemo, useState } from "react";
import type { OutputLine, ServerEvent } from "@farhelm/client-core";
import { sessionIdOf, useResource, useRoute } from "./hooks";
import { migratePairing, webPairingStore } from "./platform";
import { loopbackAvailable, useConnection } from "./connection";
import { AuthScreen, MachinePicker, WelcomeScreen, readableError } from "./components/Auth";
import { Connect } from "./components/Connect";
import { AddMachine } from "./components/AddMachine";
import { DeviceSlotNotice } from "./components/DeviceSlot";
import { AccountScreen, BillingScreen } from "./components/Account";
import { PushSettings } from "./components/PushSettings";
import { NewSession } from "./components/NewSession";
import { TaskBoard } from "./components/Board";
import { Overview } from "./components/Overview";
import { NewTaskComposer, TaskThread } from "./components/TaskThread";
import { ProjectsList } from "./components/Projects";
import { ProjectTaskScreen } from "./components/ProjectWorkflow";
import { DashboardScreen, SessionScreen, useScrollReset } from "./components/views";
import { Sidebar, sectionOf, type Section } from "./components/Sidebar";
import { Palette, type Action } from "./components/Palette";
import { Icon } from "./components/Icon";
import { CLOUD_URL } from "./cloud";

type Theme = "system" | "light" | "dark";

const THEME_KEY = "farhelm-theme";

function useTheme(): [Theme, () => void] {
  const [theme, setTheme] = useState<Theme>(
    () => (getMigratingSync(THEME_KEY, "forge-theme") as Theme | null) ?? "system",
  );

  useEffect(() => {
    const root = document.documentElement;
    if (theme === "system") root.removeAttribute("data-theme");
    else root.setAttribute("data-theme", theme);
    localStorage.setItem(THEME_KEY, theme);
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
  const [authServiceUrl, setAuthServiceUrl] = useState(CLOUD_URL);
  const [authOpen, setAuthOpen] = useState(false);
  const [accountError, setAccountError] = useState<string | null>(null);

  const submitAuth = useCallback(
    (input: Parameters<typeof connection.signIn>[0]) => {
      setAuthBusy(true);
      setAuthError(null);
      return connection
        .signIn({ ...input, baseUrl: authServiceUrl })
        .then(() => {
          setAuthOpen(false);
          navigate("/");
        })
        .catch((cause: unknown) => setAuthError(readableError(cause)))
        .finally(() => setAuthBusy(false));
    },
    [connection, navigate, authServiceUrl],
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
    [transport],
  );
  const sessionId = sessionIdOf(route);
  const session = useResource(
    () => (sessionId && transport ? transport.session(sessionId) : Promise.resolve(null)),
    [sessionId, transport, ...deps],
    [transport, sessionId],
  );
  const dashboard = useResource(
    () =>
      route.view === "cost" && transport
        ? transport.dashboard(route.id)
        : Promise.resolve(null),
    [route.view === "cost" ? route.id : null, transport, ...deps],
    [transport, route.view === "cost" ? route.id : null],
  );

  const taskId = route.view === "task" ? route.id : null;
  // Always loaded once there is a runner: the sidebar lists tasks under their
  // repositories on every screen, not only on the board.
  const tasks = useResource(
    () => (transport ? transport.tasks() : Promise.resolve(null)),
    [transport, ...deps],
    [transport],
  );
  const task = useResource(
    () => (taskId && transport ? transport.task(taskId) : Promise.resolve(null)),
    [taskId, transport, ...deps],
    [transport, taskId],
  );

  const billing = useResource(
    () =>
      route.view === "billing" && connection.cloud
        ? connection.cloud.billing()
        : Promise.resolve(null),
    [route.view === "billing", connection.cloud, revision],
    [connection.cloud, route.view === "billing"],
  );

  useScrollReset(`${route.view}:${sessionId ?? taskId ?? (route.view === "project" || route.view === "project-task" ? route.id : "")}`);

  /**
   * What ⌘K can reach.
   *
   * Built from the fleet snapshot rather than a separate fetch: everything the
   * palette offers is already on screen somewhere, and a palette that shows
   * staler data than the page behind it is worse than no palette.
   */
  const actions = useMemo<Action[]>(() => {
    const list: Action[] = [
      { id: "go-home", group: "Go to", icon: "fleet", label: "Home",
        hint: "Approvals, reviews and live sessions", run: () => navigate("/") },
      { id: "go-board", group: "Go to", icon: "board", label: "Board",
        hint: "Every task, grouped by status", run: () => navigate("/t") },
      { id: "go-projects", group: "Go to", icon: "folder", label: "Projects",
        run: () => navigate("/p") },
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

  // The task thread gets the same streamed tail as a session, keyed by the
  // session the task runs in.
  const mergedTask = useMemo(() => {
    if (!task.data) return null;
    const streamed = liveOutput[task.data.session_id] ?? [];
    if (streamed.length === 0) return task.data;
    const bySeq = new Map<number, OutputLine>();
    for (const line of [...task.data.output, ...streamed]) bySeq.set(line.seq, line);
    return { ...task.data, output: [...bySeq.values()].sort((a, b) => a.seq - b.seq).slice(-200) };
  }, [task.data, liveOutput]);

  const activeRunner =
    connection.workspace?.runners.find(
      (runner) => runner.id === connection.activeRunnerId,
    ) ?? null;

  const title =
    route.view === "fleet"
      ? "Home"
      : route.view === "projects" || route.view === "project" || route.view === "project-task"
        ? "Projects"
        : route.view === "tasks"
          ? "Board"
          : route.view === "new-task"
            ? "New task"
            : route.view === "new-session"
              ? "New session"
              : route.view === "account"
                ? "Settings"
                : route.view === "billing"
                  ? "Plan"
                  : route.view === "connect"
                    ? "Connect a machine"
                    : route.view === "task"
                      ? (task.data?.repo_name ?? "Task")
                      : (mergedSession?.repo_name ?? "Session");

  /** Where "← Back" goes from here. */
  const backTo =
    route.view === "cost"
      ? `/s/${route.id}`
      : route.view === "task" || route.view === "new-task"
        ? "/t"
        : route.view === "project-task"
          ? `/p/${encodeURIComponent(route.projectId)}`
        : route.view === "project"
          ? "/p"
          : route.view === "billing"
            ? "/account"
            : "/";
  const topLevel = route.view === "fleet" || route.view === "tasks" || route.view === "projects" || route.view === "account";
  const section: Section = sectionOf(route);
  const needsYou = (fleet.data?.pending_approvals.length ?? 0) + (fleet.data?.tasks_awaiting_review.length ?? 0);

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
              serviceUrl={authServiceUrl}
              onServiceUrlChange={setAuthServiceUrl}
              onModeChange={() => setAuthError(null)}
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

  const tab = (key: Section, to: string, icon: "fleet" | "board" | "folder" | "account", label: string) => (
    <button
      className={`tab${section === key ? " is-current" : ""}`}
      onClick={() => navigate(to)}
      aria-current={section === key ? "page" : undefined}
    >
      <Icon name={icon} size={20} />
      <span>{label}</span>
      {key === "home" && needsYou > 0 ? <span className="side-badge">{needsYou}</span> : null}
    </button>
  );

  return (
    <div className="app">
      {paletteOpen ? (
        <Palette actions={actions} onClose={() => setPaletteOpen(false)} />
      ) : null}

      <Sidebar
        workspace={connection.workspace}
        route={route}
        activeRunnerId={connection.activeRunnerId}
        connectionState={connection.state}
        transportKind={transport?.kind ?? null}
        theme={theme}
        tasks={tasks.data}
        sessions={fleet.data?.sessions ?? []}
        needsYou={needsYou}
        canStartTask={transport?.supportsTaskControl === true}
        onNavigate={navigate}
        onPickRunner={connection.pickRunner}
        onCycleTheme={cycleTheme}
        onOpenPalette={() => setPaletteOpen(true)}
        onSignOut={() => {
          if (connection.mode === "cloud") void connection.signOut();
          else connection.chooseCloud();
        }}
      />

      <div className="app-main">
      {/* Narrow screens only: the sidebar's job, folded into a bar. */}
      <header className="mobile-bar">
        {!topLevel ? (
          <button className="back" onClick={() => navigate(backTo)}>← Back</button>
        ) : null}
        {/* Top-level pages carry their own heading; repeating it here read
            "Home Home" on a phone. */}
        {!topLevel ? <h1>{title}</h1> : null}
        <span className="spacer" />
        {connection.state !== "open" && !needsMachine ? (
          <span className="reconnecting">reconnecting…</span>
        ) : null}
        <button className="icon-button" onClick={() => setPaletteOpen(true)} aria-label="Search and commands">
          <Icon name="search" />
        </button>
        {connection.mode !== "cloud" ? (
          <button
            className="icon-button"
            onClick={connection.chooseCloud}
            aria-label="Sign in to reach this machine from anywhere"
          >
            <Icon name="link" />
          </button>
        ) : null}
        <button
          className="icon-button"
          onClick={cycleTheme}
          aria-label={`Theme: ${theme}. Tap to change.`}
        >
          <Icon name={theme === "light" ? "sun" : theme === "dark" ? "moon" : "auto"} />
        </button>
      </header>

      <main className="app-content" data-view={route.view}>
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
          <DeviceSlotNotice
            problem={connection.deviceProblem}
            devices={connection.workspace?.devices ?? []}
            onReplace={connection.replaceDevice}
            onRetry={connection.claimDeviceSlot}
            onPlans={() => navigate("/billing")}
          />
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

        {/* A machine has to be chosen before there is anything to render.
            With none enrolled there is nothing to choose *between*, so the
            question is not "which machine" — it is "how do I get one", and the
            answer is a command to run rather than a screen to navigate to. */}
        {needsMachine && route.view === "fleet" ? (
          (connection.workspace?.runners ?? []).length === 0 && connection.cloud ? (
            <section className="card" aria-label="No machines yet">
              <div className="chart-title">No machines yet</div>
              <AddMachine cloud={connection.cloud} onError={setAccountError} variant="bare" />
            </section>
          ) : (
            <MachinePicker
              runners={connection.workspace?.runners ?? []}
              onPick={connection.pickRunner}
              onAddMachine={() => navigate("/account")}
              busy={false}
            />
          )
        ) : null}

        {route.view === "connect" ? (
          connection.mode === "cloud" && connection.cloud ? (
            <Connect
              cloud={connection.cloud}
              initialCode={route.code}
              onDone={() => navigate("/")}
            />
          ) : (
            // Signing in is the prerequisite, not an error. Say what to do
            // rather than rendering an empty screen next to a live code.
            <section className="card" aria-label="Connect a machine">
              <h2 className="chart-title">Connect a machine</h2>
              <p className="tile-note">
                Sign in to this workspace first — approving a machine is a
                decision only a member of it can make. The code stays valid for
                fifteen minutes.
              </p>
            </section>
          )
        ) : null}

        {route.view === "account" ? (
          connection.mode === "cloud" && connection.workspace && connection.cloud ? (
            <AccountScreen
              workspace={connection.workspace}
              cloud={connection.cloud}
              onChanged={connection.refresh}
              onBilling={() => navigate("/billing")}
              onSignOut={() => void connection.signOut()}
              thisDeviceId={connection.deviceId}
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
              <Overview
                fleet={fleet.data}
                tasks={tasks.data}
                transport={transport}
                machineName={activeRunner?.name ?? (transport?.kind === "loopback" ? "Local runner" : null)}
                onNavigate={navigate}
                onChanged={bump}
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

        {route.view === "projects" || route.view === "project" ? (
          <ProjectsList
            transport={transport}
            projectId={route.view === "project" ? route.id : null}
            onNavigate={navigate}
          />
        ) : null}

        {route.view === "project-task" ? (
          <ProjectTaskScreen transport={transport} projectId={route.projectId} taskId={route.id} onNavigate={navigate} />
        ) : null}

        {route.view === "tasks" ? (
          tasks.error ? (
            <div className="card error">
              <b>Tasks unavailable.</b>
              <p className="tile-note">{tasks.error}</p>
            </div>
          ) : tasks.data ? (
            <div className={staleClass(tasks.stale)}>
              <TaskBoard
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
          <NewTaskComposer
            transport={transport}
            tasks={tasks.data}
            onStarted={(id) => navigate(`/t/${id}`)}
          />
        ) : null}

        {route.view === "task" ? (
          task.error ? (
            <div className="card error">
              <b>Task unavailable.</b>
              <p className="tile-note">{task.error}</p>
            </div>
          ) : mergedTask ? (
            <div className={`thread-pane ${staleClass(task.stale) ?? ""}`}>
              <TaskThread
                task={mergedTask}
                fleet={fleet.data}
                transport={transport}
                onChanged={bump}
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
            // `thread-pane` is not decoration: the refetch wrapper sits
            // between `main` and the screen, and a plain block there stops the
            // full-height column reaching the flex parent that sizes it.
            <div className={`thread-pane ${staleClass(session.stale) ?? ""}`}>
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
      </div>

      <nav className="tabbar" aria-label="Main">
        {tab("home", "/", "fleet", "Home")}
        {tab("board", "/t", "board", "Board")}
        {tab("projects", "/p", "folder", "Projects")}
        {tab("account", "/account", "account", "Settings")}
      </nav>
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
