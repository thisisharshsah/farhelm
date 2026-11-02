/**
 * One project, one screen: what the coding-agent apps settle on.
 *
 * A narrow list on the left (conversations, tasks, recent runs), one thing
 * open in the middle (a conversation with its composer, a task, a run), and
 * every "new" or "attach" action behind a button. Repositories and the
 * project's own details live under Settings, out of the way once set.
 *
 * Nothing here is new behaviour: the pieces (the conversation pane, the
 * task page, the run thread, the repository forms) exist and are tested;
 * this arranges them and keeps the selection in the route so links work.
 */

import { useEffect, useRef, useState } from "react";
import {
  since,
  type Project,
  type ProjectChat as Conversation,
  type ProjectRepository,
  type TaskView,
  type Transport,
  type WorkItemView,
} from "@farhelm/client-core";
import { Icon } from "./Icon";
import { ModePicker, ModelPicker, useModes } from "./ModelChoice";
import { ConversationPane, supportsProjectChat, type ChatTransport } from "./ProjectChat";
import { ProjectTaskScreen, ProjectWorkflow, projectTaskPath } from "./ProjectWorkflow";
import { StatusPill, TASK_STATUS, WORK_ITEM_STATUS } from "./status";
import { NewWorkItem, WorkItemScreen, supportsBoard, workItemPath, type BoardTransport } from "./WorkBoard";

export type WorkspaceFocus =
  | { kind: "home" }
  | { kind: "chat"; id: string }
  | { kind: "work"; id: string }
  | { kind: "run"; id: string }
  | { kind: "settings" };

type WorkspaceTransport = ChatTransport & BoardTransport & Required<Pick<Transport, "projectRepositories" | "projectTasks">>;

export function supportsWorkspace(transport: Transport | null): transport is WorkspaceTransport {
  return supportsProjectChat(transport) && supportsBoard(transport)
    && typeof transport.projectRepositories === "function" && typeof transport.projectTasks === "function";
}

function message(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause);
}

export function chatPath(projectId: string, chatId: string): string {
  return `/p/${encodeURIComponent(projectId)}/c/${encodeURIComponent(chatId)}`;
}

/** A title for a conversation from its first message. */
function titleOf(text: string): string {
  const line = text.split("\n").map((part) => part.trim()).find(Boolean) ?? "Conversation";
  return line.length > 80 ? `${line.slice(0, 77).trimEnd()}…` : line;
}

export function ProjectWorkspace({ transport, project, focus, onNavigate }: {
  transport: WorkspaceTransport;
  project: Project;
  focus: WorkspaceFocus;
  onNavigate: (path: string) => void;
}) {
  const projectId = project.id;
  const [repos, setRepos] = useState<ProjectRepository[]>([]);
  const [conversations, setConversations] = useState<Conversation[] | null>(null);
  const [items, setItems] = useState<WorkItemView[] | null>(null);
  const [runs, setRuns] = useState<TaskView[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [revision, setRevision] = useState(0);
  const refresh = () => setRevision((value) => value + 1);

  useEffect(() => {
    let cancelled = false;
    const keep = <T,>(set: (value: T) => void) => (value: T) => { if (!cancelled) set(value); };
    transport.projectRepositories(projectId, { limit: 50 }).then((page) => keep(setRepos)(page.repositories)).catch((cause) => keep(setError)(message(cause)));
    transport.projectConversations(projectId, { limit: 50 }).then((page) => keep(setConversations)(page.conversations)).catch((cause) => keep(setError)(message(cause)));
    transport.projectWorkItems(projectId, { limit: 100 }).then((page) => keep(setItems)(page.items)).catch((cause) => keep(setError)(message(cause)));
    transport.projectTasks(projectId, { limit: 10 }).then((page) => keep(setRuns)(page.tasks)).catch((cause) => keep(setError)(message(cause)));
    return () => { cancelled = true; };
  }, [transport, projectId, revision]);

  // Runs change tasks and the run list; one refresh covers both.
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | null = null;
    const off = transport.onEvent((event) => {
      if (event.type !== "task_upsert" || timer !== null) return;
      timer = setTimeout(() => { timer = null; refresh(); }, 300);
    });
    return () => { off(); if (timer !== null) clearTimeout(timer); };
  }, [transport]);

  const current = focus.kind === "chat" ? conversations?.find((item) => item.id === focus.id) ?? null : null;
  // The project's home is its newest conversation; with none, an invitation.
  const home = focus.kind === "home" ? conversations?.[0] ?? null : null;
  const open = current ?? home;
  const openRuns = (run: TaskView) => { refresh(); onNavigate(projectTaskPath(projectId, run.id)); };

  return (
    <div className="workspace">
      <aside className="ws-side" aria-label="Project">
        <div className="ws-side-head">
          <button type="button" className="ws-crumb" onClick={() => onNavigate("/p")}>Projects</button>
          <h1 className="ws-title" title={project.name}>{project.name}</h1>
          <button
            type="button"
            className="btn btn-quiet btn-small"
            aria-current={focus.kind === "settings" ? "page" : undefined}
            onClick={() => onNavigate(`/p/${encodeURIComponent(projectId)}/settings`)}
          >
            Settings
          </button>
        </div>
        <div className="ws-actions">
          <button type="button" className="btn btn-primary btn-small" onClick={() => onNavigate(chatPath(projectId, "new"))} disabled={repos.length === 0}>
            <Icon name="plus" size={14} /> Conversation
          </button>
          <button type="button" className="btn btn-small" onClick={() => onNavigate(workItemPath(projectId, "new"))}>
            <Icon name="plus" size={14} /> Task
          </button>
        </div>
        {repos.length === 0 ? (
          <p className="tile-note">Attach a repository in Settings to start talking.</p>
        ) : null}
        {error ? <p className="error" role="alert">{error}</p> : null}

        <SideSection title="Conversations" count={conversations?.length}>
          {conversations?.map((item) => (
            <button
              key={item.id}
              className={`side-thread${open?.id === item.id ? " is-current" : ""}`}
              aria-current={open?.id === item.id ? "page" : undefined}
              onClick={() => onNavigate(chatPath(projectId, item.id))}
            >
              <span className="side-item-label">{item.title}</span>
              <span className="muted">{since(item.updated_at)}</span>
            </button>
          ))}
          {conversations?.length === 0 ? <p className="tile-note">None yet.</p> : null}
        </SideSection>

        <SideSection title="Tasks" count={items?.filter((item) => item.status !== "done").length}>
          {items?.filter((item) => item.status !== "done").map((item) => (
            <button
              key={item.id}
              className={`side-thread${focus.kind === "work" && focus.id === item.id ? " is-current" : ""}`}
              aria-current={focus.kind === "work" && focus.id === item.id ? "page" : undefined}
              onClick={() => onNavigate(workItemPath(projectId, item.id))}
            >
              <span className="side-item-label">{item.title}</span>
              <StatusPill look={WORK_ITEM_STATUS[item.status]} size="sm" />
            </button>
          ))}
          {items?.length === 0 ? <p className="tile-note">None yet.</p> : null}
        </SideSection>

        <SideSection title="Recent runs" count={runs?.length}>
          {runs?.map((run) => (
            <button
              key={run.id}
              className={`side-thread${focus.kind === "run" && focus.id === run.id ? " is-current" : ""}`}
              aria-current={focus.kind === "run" && focus.id === run.id ? "page" : undefined}
              onClick={() => onNavigate(projectTaskPath(projectId, run.id))}
            >
              <span className="side-item-label">{run.prompt}</span>
              <StatusPill look={TASK_STATUS[run.status]} size="sm" />
            </button>
          ))}
          {runs?.length === 0 ? <p className="tile-note">None yet.</p> : null}
        </SideSection>
      </aside>

      <main className="ws-main">
        {focus.kind === "chat" && focus.id === "new" ? (
          <NewConversation transport={transport} projectId={projectId} repositories={repos}
            onCreated={(created) => { refresh(); onNavigate(chatPath(projectId, created.id)); }} />
        ) : focus.kind === "chat" && !current && conversations ? (
          <p className="tile-note">That conversation is not in this project.</p>
        ) : open ? (
          <ConversationPane
            key={open.id}
            transport={transport}
            projectId={projectId}
            conversation={open}
            repository={repos.find((repo) => repo.id === open.repo_id) ?? null}
            onTaskStarted={openRuns}
            onNavigate={onNavigate}
          />
        ) : focus.kind === "home" && conversations ? (
          <div className="ws-empty">
            <h2>Talk a change through, then hand it to the agent.</h2>
            <p className="tile-note">
              Start a conversation about one of this project's repositories. Ask what the code does, plan a change,
              then turn a reply into a task and let a run do the work.
            </p>
            {repos.length > 0 ? (
              <button type="button" className="btn btn-primary" onClick={() => onNavigate(chatPath(projectId, "new"))}>
                <Icon name="plus" size={14} /> New conversation
              </button>
            ) : (
              <button type="button" className="btn btn-primary" onClick={() => onNavigate(`/p/${encodeURIComponent(projectId)}/settings`)}>
                Attach a repository
              </button>
            )}
          </div>
        ) : focus.kind === "work" && focus.id === "new" ? (
          <section className="card" aria-label="New task">
            <NewWorkItem transport={transport} projectId={projectId} repositories={repos}
              onCreated={(item) => { refresh(); onNavigate(workItemPath(projectId, item.id)); }} />
          </section>
        ) : focus.kind === "work" ? (
          <WorkItemScreen transport={transport} projectId={projectId} itemId={focus.id} repositories={repos} onNavigate={onNavigate} />
        ) : focus.kind === "run" ? (
          <ProjectTaskScreen transport={transport} projectId={projectId} taskId={focus.id} onNavigate={onNavigate} />
        ) : focus.kind === "settings" ? (
          <div className="ws-settings">
            <section className="card" aria-label="Project details">
              <h2 className="chart-title">{project.name}</h2>
              <p className="project-description">{project.description || "No description."}</p>
              <dl className="project-dates">
                <div><dt>Created</dt><dd>{since(project.created_at)}</dd></div>
                <div><dt>Updated</dt><dd>{since(project.updated_at)}</dd></div>
              </dl>
            </section>
            <ProjectWorkflow transport={transport} projectId={projectId} onNavigate={onNavigate} />
          </div>
        ) : (
          <p role="status" className="tile-note">Loading…</p>
        )}
      </main>
    </div>
  );
}

function SideSection({ title, count, children }: { title: string; count?: number; children: React.ReactNode }) {
  return (
    <section className="ws-section" aria-label={title}>
      <h2 className="ws-section-title">{title}{count !== undefined ? <span className="muted"> {count}</span> : null}</h2>
      <div className="ws-list">{children}</div>
    </section>
  );
}

/**
 * A conversation starts with its first message, as a thread does elsewhere:
 * the title comes from the message, the repository from the one chosen (or
 * the only one). Created, then sent, then opened; a failure on either step
 * is shown and the text kept.
 */
function NewConversation({ transport, projectId, repositories, onCreated }: {
  transport: WorkspaceTransport;
  projectId: string;
  repositories: ProjectRepository[];
  onCreated: (conversation: Conversation) => void;
}) {
  const [text, setText] = useState("");
  const [repoId, setRepoId] = useState("");
  const [mode, setMode] = useState<"ask" | "plan">("ask");
  const [model, setModel] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const modes = useModes(transport);
  const inFlight = useRef(false);
  const target = repositories.some((repo) => repo.id === repoId) ? repoId : repositories[0]?.id ?? "";

  const start = async () => {
    const value = text.trim();
    if (!value || !target || inFlight.current) return;
    inFlight.current = true;
    setBusy(true);
    setError(null);
    try {
      const created = await transport.createProjectConversation(projectId, { repo_id: target, title: titleOf(value) });
      const id = typeof crypto !== "undefined" && "randomUUID" in crypto ? crypto.randomUUID() : `req-${Date.now()}`;
      await transport.sendProjectMessage(projectId, created.id, { content: value, request_id: id, mode, ...(model ? { model } : {}) });
      onCreated(created);
    } catch (cause) {
      setError(message(cause));
      inFlight.current = false;
      setBusy(false);
    }
  };

  return (
    <div className="project-chat-pane ws-new-chat">
      <div className="project-chat-head">
        <b>New conversation</b>
        {repositories.length > 1 ? (
          <select className="composer-field" aria-label="Repository" value={target} onChange={(event) => setRepoId(event.target.value)} disabled={busy}>
            {repositories.map((repo) => <option key={repo.id} value={repo.id}>{repo.name}</option>)}
          </select>
        ) : <span className="muted">{repositories[0]?.name ?? "no repository"}</span>}
      </div>
      <div className="project-chat-messages">
        <p className="tile-note">Ask what the code does, or plan a change. The model can read the repository.</p>
      </div>
      <form className="composer-box" onSubmit={(event) => { event.preventDefault(); void start(); }}>
        <textarea
          rows={3}
          autoFocus
          value={text}
          onChange={(event) => setText(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) { event.preventDefault(); void start(); }
          }}
          aria-label="First message"
          placeholder="What do you want to talk through?"
          disabled={busy}
        />
        <div className="composer-bar">
          <ModePicker value={mode} options={["ask", "plan"]} modes={modes} onChange={(next) => setMode(next === "plan" ? "plan" : "ask")} disabled={busy} />
          <ModelPicker value={model} mode={mode} modes={modes} onChange={setModel} disabled={busy} />
          <span className="composer-hint">Enter to send</span>
          <span className="spacer" />
          <button className="send-button" type="submit" aria-label="Send message" disabled={busy || !text.trim() || !target}>
            <Icon name="send" size={16} />
          </button>
        </div>
      </form>
      {error ? <p className="notice" role="alert">{error}</p> : null}
    </div>
  );
}
