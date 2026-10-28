/**
 * The desktop sidebar: where am I, what else is there, and what is the work.
 *
 * Modelled on coding-agent apps rather than a settings menu. Above the fold
 * are the destinations and a count of what needs you; below them, the tasks
 * themselves grouped under their repositories, each with its state, so the
 * work is navigable without opening the board first. The machine being
 * supervised and the health of the link to it are stated permanently at the
 * bottom.
 *
 * It renders only above the narrow breakpoint. Below it, the tab bar in
 * `App.tsx` carries the same destinations.
 */

import { useMemo, useState } from "react";
import { agentName, isAgentSession, since, type SessionView, type TaskView, type Workspace } from "@farhelm/client-core";
import type { Route } from "../hooks";
import { Icon, type IconName } from "./Icon";
import { SESSION_STATUS, StatusDot, TASK_STATUS } from "./status";

export type Theme = "system" | "light" | "dark";

const THEME_ICON: Record<Theme, IconName> = { system: "auto", light: "sun", dark: "moon" };
const THEME_LABEL: Record<Theme, string> = { system: "Match the system", light: "Light", dark: "Dark" };

export type Section = "home" | "board" | "projects" | "account";

/** Which destination a route belongs under. */
export function sectionOf(route: Route): Section {
  switch (route.view) {
    case "projects":
    case "project":
    case "project-task":
      return "projects";
    case "tasks":
    case "task":
    case "new-task":
      return "board";
    case "account":
    case "billing":
    case "connect":
      return "account";
    default:
      // Sessions and their cost views are opened from Home, so Home stays lit.
      return "home";
  }
}

const TASKS_PER_REPO = 5;

export function Sidebar({
  workspace,
  route,
  activeRunnerId,
  connectionState,
  transportKind = null,
  theme,
  tasks = null,
  sessions = [],
  needsYou = 0,
  canStartTask = false,
  onNavigate,
  onPickRunner,
  onCycleTheme,
  onOpenPalette,
  onSignOut,
}: {
  workspace: Workspace | null;
  route: Route;
  activeRunnerId: string | null;
  connectionState: string;
  transportKind?: "loopback" | "relay" | null;
  theme: Theme;
  tasks?: TaskView[] | null;
  sessions?: SessionView[];
  needsYou?: number;
  canStartTask?: boolean;
  onNavigate: (to: string) => void;
  onPickRunner: (id: string) => void;
  onCycleTheme: () => void;
  onOpenPalette: () => void;
  onSignOut: () => void;
}) {
  const section = sectionOf(route);
  const runners = workspace?.runners ?? [];
  const active = runners.find((runner) => runner.id === activeRunnerId) ?? null;
  const hasMachine = active !== null || transportKind !== null;
  const [closed, setClosed] = useState<Set<string>>(() => new Set());

  const repos = useMemo(() => {
    const byRepo = new Map<string, { id: string; name: string; path: string; tasks: TaskView[] }>();
    for (const task of tasks ?? []) {
      const entry = byRepo.get(task.repo_id) ?? { id: task.repo_id, name: task.repo_name, path: task.repo_path, tasks: [] };
      entry.tasks.push(task);
      byRepo.set(task.repo_id, entry);
    }
    return Array.from(byRepo.values())
      .map((repo) => ({ ...repo, tasks: repo.tasks.sort((a, b) => b.updated_at - a.updated_at) }))
      .sort((a, b) => (b.tasks[0]?.updated_at ?? 0) - (a.tasks[0]?.updated_at ?? 0));
  }, [tasks]);

  // Agent work only: conversations and direct API calls keep sessions as
  // budget accounts, and are not something to open from here.
  const liveSessions = sessions.filter((session) => session.is_live && isAgentSession(session));
  const currentTask = route.view === "task" ? route.id : null;
  const currentSession = route.view === "session" || route.view === "cost" ? route.id : null;

  const entry = (key: Section, to: string, icon: IconName, label: string, badge = 0) => (
    <button
      className={`side-link${section === key ? " is-current" : ""}`}
      onClick={() => onNavigate(to)}
      // Marks the destination for a screen reader the same way the tint marks
      // it visually, rather than leaving the current page identifiable only by
      // colour.
      aria-current={section === key ? "page" : undefined}
    >
      <Icon name={icon} size={16} />
      <span className="side-link-label">{label}</span>
      {badge > 0 ? <span className="side-badge" aria-label={`${badge} need you`}>{badge}</span> : null}
    </button>
  );

  const toggleRepo = (id: string) =>
    setClosed((current) => {
      const next = new Set(current);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  return (
    <nav className="side" aria-label="Main">
      <div className="side-org">
        <span className="side-mark" aria-hidden="true" />
        <span className="side-org-name">{workspace?.org.name ?? "Farhelm"}</span>
        {workspace ? <span className="plan-chip">{workspace.subscription.plan}</span> : null}
        <span className="spacer" />
        <button className="side-icon" onClick={onOpenPalette} aria-label="Search and commands" title="Search (⌘K)">
          <Icon name="search" size={16} />
        </button>
      </div>

      {canStartTask ? (
        <button className="side-new" onClick={() => onNavigate("/t/new")}>
          <Icon name="plus" size={16} />
          <span>New task</span>
        </button>
      ) : null}

      <div className="side-group">
        {entry("home", "/", "fleet", "Home", needsYou)}
        {entry("board", "/t", "board", "Board")}
        {entry("projects", "/p", "folder", "Projects")}
        {entry("account", "/account", "account", "Settings")}
      </div>

      <div className="side-scroll">
        {repos.length > 0 ? (
          <div className="side-group">
            <h2 className="side-heading">Repositories</h2>
            {repos.map((repo) => {
              const open = !closed.has(repo.id);
              return (
                <div key={repo.id} className="side-repo">
                  <button
                    className="side-repo-head"
                    aria-expanded={open}
                    onClick={() => toggleRepo(repo.id)}
                    title={repo.path}
                  >
                    <Icon name="chevron" size={12} className={open ? "is-open" : undefined} />
                    <Icon name="folder" size={15} />
                    <span className="side-item-label">{repo.name}</span>
                  </button>
                  {open ? repo.tasks.slice(0, TASKS_PER_REPO).map((task) => {
                    const look = TASK_STATUS[task.status];
                    return (
                      <button
                        key={task.id}
                        className={`side-thread${currentTask === task.id ? " is-current" : ""}`}
                        aria-current={currentTask === task.id ? "page" : undefined}
                        onClick={() => onNavigate(`/t/${task.id}`)}
                        title={task.prompt}
                      >
                        <span className="side-item-label">{task.prompt}</span>
                        <StatusDot tone={look.tone} label={look.label} />
                      </button>
                    );
                  }) : null}
                  {open && repo.tasks.length > TASKS_PER_REPO ? (
                    <button className="side-thread side-more" onClick={() => onNavigate("/t")}>
                      {repo.tasks.length - TASKS_PER_REPO} more on the board
                    </button>
                  ) : null}
                </div>
              );
            })}
          </div>
        ) : null}

        {liveSessions.length > 0 ? (
          <div className="side-group">
            <h2 className="side-heading">Live sessions</h2>
            {liveSessions.map((session) => {
              const look = SESSION_STATUS[session.status];
              return (
                <button
                  key={session.id}
                  className={`side-thread side-session${currentSession === session.id ? " is-current" : ""}`}
                  aria-current={currentSession === session.id ? "page" : undefined}
                  onClick={() => onNavigate(`/s/${session.id}`)}
                >
                  {/* Two sessions in one repository share a name, so each
                      carries its agent and age to tell them apart. */}
                  <span className="side-item-label side-item-stack">
                    <span>{session.repo_name}</span>
                    <span className="side-item-sub">{agentName(session.agent)} · {since(session.started_at)}</span>
                  </span>
                  <StatusDot tone={look.tone} label={look.label} />
                </button>
              );
            })}
          </div>
        ) : null}

        {runners.length > 0 ? (
          <div className="side-group">
            <h2 className="side-heading">Machines</h2>
            {runners.map((runner) => (
              <button
                key={runner.id}
                className={`side-thread${runner.id === activeRunnerId ? " is-current" : ""}`}
                onClick={() => onPickRunner(runner.id)}
                title={runner.online ? "Online" : "Offline"}
              >
                <span className={`dot ${runner.online ? "is-online" : "is-offline"}`} aria-hidden="true" />
                <span className="side-item-label">{runner.name}</span>
                {runner.id === activeRunnerId ? <Icon name="check" size={14} /> : null}
              </button>
            ))}
          </div>
        ) : null}
      </div>

      <div className="side-foot">
        {/* The link's health, stated plainly and always: a healthy link and a
            missing one must never look the same. */}
        <div className="rail-status" role="status">
          <span
            className={`dot ${
              hasMachine && connectionState === "open"
                ? "is-online"
                : hasMachine && connectionState === "connecting"
                  ? "is-pending"
                  : "is-offline"
            }`}
            aria-hidden="true"
          />
          {hasMachine
            ? connectionState === "open"
              ? transportKind === "loopback" ? "Local runner connected" : "Connected"
              : connectionState === "connecting"
                ? "Connecting…"
                : "Reconnecting…"
            : "No machine selected"}
        </div>
        <span className="spacer" />
        <button
          className="side-icon"
          onClick={onCycleTheme}
          aria-label={`Theme: ${THEME_LABEL[theme]}. Change it.`}
          title={`Theme: ${THEME_LABEL[theme]}`}
        >
          <Icon name={THEME_ICON[theme]} size={16} />
        </button>
        <button
          className="side-icon"
          onClick={onSignOut}
          aria-label={workspace ? "Sign out" : "Sign in"}
          title={workspace ? "Sign out" : "Sign in"}
        >
          <Icon name={workspace ? "signout" : "link"} size={16} />
        </button>
      </div>
    </nav>
  );
}
