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

import { useCallback, useEffect, useId, useRef, useState } from "react";
import {
  since,
  type Project,
  type ProjectChat as Conversation,
  type ProjectRepository,
  type TaskView,
  type Transport,
} from "@farhelm/client-core";
import { useWorkspaceList } from "./workspace-list";
import { Icon } from "./Icon";
import { ModePicker, ModelPicker, useModes } from "./ModelChoice";
import { ConversationPane, supportsProjectChat, type ChatTransport } from "./ProjectChat";
import { AddRepository } from "./AddRepository";
import { ProjectTaskScreen, projectTaskPath } from "./ProjectWorkflow";
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

type WorkspaceProps = {
  transport: WorkspaceTransport;
  project: Project;
  focus: WorkspaceFocus;
  onNavigate: (path: string) => void;
};

export function ProjectWorkspace(props: WorkspaceProps) {
  const [owner, setOwner] = useState({ transport: props.transport, project: props.project.id, version: 0 });
  if (owner.transport !== props.transport || owner.project !== props.project.id) {
    setOwner({ transport: props.transport, project: props.project.id, version: owner.version + 1 });
  }
  return <WorkspaceContent key={owner.version} {...props} />;
}

function WorkspaceContent({ transport, project, focus, onNavigate }: WorkspaceProps) {
  const projectId = project.id;
  const [revision, setRevision] = useState(0);
  const [navigationOpen, setNavigationOpen] = useState(false);
  const [search, setSearch] = useState("");
  const navigationId = useId();
  const navigationToggle = useRef<HTMLButtonElement>(null);
  const refresh = () => setRevision((value) => value + 1);
  const navigate = (path: string) => {
    setNavigationOpen(false);
    onNavigate(path);
    // The mobile disclosure closes after selection; keep focus on its trigger.
    if (navigationOpen) navigationToggle.current?.focus();
  };
  const repoPage = useWorkspaceList(useCallback(async (after?: string) => {
    const page = await transport.projectRepositories(projectId, { limit: 50, after });
    return { items: page.repositories, next_cursor: page.next_cursor };
  }, [transport, projectId]), revision);
  const chatPage = useWorkspaceList(useCallback(async (after?: string) => {
    const page = await transport.projectConversations(projectId, { limit: 50, after });
    return { items: page.conversations, next_cursor: page.next_cursor };
  }, [transport, projectId]), revision);
  const taskPage = useWorkspaceList(useCallback(async (after?: string) => {
    const page = await transport.projectWorkItems(projectId, { limit: 50, after });
    return { items: page.items, next_cursor: page.next_cursor };
  }, [transport, projectId]), revision);
  const runPage = useWorkspaceList(useCallback(async (after?: string) => {
    const page = await transport.projectTasks(projectId, { limit: 10, after });
    return { items: page.tasks, next_cursor: page.next_cursor };
  }, [transport, projectId]), revision);
  const repos = repoPage.items ?? [];
  const conversations = chatPage.items;
  const query = search.trim().toLowerCase();
  const matches = (text: string) => text.toLowerCase().includes(query);
  const visibleChats = conversations?.filter((item) => matches(item.title));
  const visibleTasks = taskPage.items?.filter((item) => matches(item.title));
  const visibleRuns = runPage.items?.filter((run) => matches(run.prompt));
  const selectedId = focus.kind === "chat" && focus.id !== "new" ? focus.id : null;
  const [selected, setSelected] = useState<{ id: string; conversation: Conversation | null; error: string | null } | null>(null);
  useEffect(() => {
    if (!selectedId) return;
    let cancelled = false;
    setSelected((previous) => previous?.id === selectedId ? { ...previous, error: null } : { id: selectedId, conversation: null, error: null });
    void transport.projectConversation(projectId, selectedId).then((detail) => {
      if (!cancelled) setSelected({ id: selectedId, conversation: detail.conversation, error: null });
    }).catch((cause: unknown) => {
      // A failed background refresh must not unmount the current composer.
      if (!cancelled) setSelected((previous) => ({
        id: selectedId,
        conversation: previous?.id === selectedId ? previous.conversation : null,
        error: message(cause),
      }));
    });
    return () => { cancelled = true; };
  }, [transport, projectId, selectedId, revision]);

  // Runs change tasks and the run list; one refresh covers both.
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | null = null;
    const off = transport.onEvent((event) => {
      if (event.type !== "task_upsert" || timer !== null) return;
      timer = setTimeout(() => { timer = null; refresh(); }, 300);
    });
    return () => { off(); if (timer !== null) clearTimeout(timer); };
  }, [transport]);

  // Direct links resolve independently of the paged navigation list.
  const current = selected?.id === selectedId ? selected.conversation : null;
  const selectedError = selected?.id === selectedId ? selected.error : null;
  const home = focus.kind === "home" ? conversations?.[0] ?? null : null;
  const open = current ?? home;
  const openRuns = (run: TaskView) => { refresh(); navigate(projectTaskPath(projectId, run.id)); };

  return (
    <div className="workspace">
      <aside className="ws-side" aria-label="Project">
        <div className="ws-side-head">
          <button type="button" className="ws-crumb" onClick={() => navigate("/p")}>Projects</button>
          <h1 className="ws-title" title={project.name}>{project.name}</h1>
          <button ref={navigationToggle} type="button" className="btn btn-small ws-nav-toggle"
            aria-expanded={navigationOpen} aria-controls={navigationId}
            onClick={() => setNavigationOpen((value) => !value)}>
            <Icon name="list" size={14} /> {navigationOpen ? "Close project navigation" : "Browse project"}
          </button>
          <button
            type="button"
            className="btn btn-quiet btn-small"
            aria-current={focus.kind === "settings" ? "page" : undefined}
            onClick={() => navigate(`/p/${encodeURIComponent(projectId)}/settings`)}
          >
            Settings
          </button>
        </div>
        <div id={navigationId} className={`ws-navigation${navigationOpen ? " is-open" : ""}`}>
        <div className="ws-actions">
          <button type="button" className="btn btn-primary btn-small" onClick={() => navigate(chatPath(projectId, "new"))} disabled={repos.length === 0}>
            <Icon name="plus" size={14} /> Conversation
          </button>
          <button type="button" className="btn btn-small" onClick={() => navigate(workItemPath(projectId, "new"))}>
            <Icon name="plus" size={14} /> Task
          </button>
        </div>
        {repoPage.items?.length === 0 ? (
          <p className="tile-note">Attach a repository in Settings to start talking.</p>
        ) : null}
        {repoPage.error ? <p className="error" role="alert">Repositories: {repoPage.error}</p> : null}
        {repoPage.loading && !repoPage.items ? <p className="tile-note" role="status">Loading repositories…</p> : null}
        {repoPage.cursor ? <button className="btn btn-small" disabled={repoPage.loading} onClick={() => void repoPage.more()}>Load more repositories</button> : null}
        <label className="board-search ws-search">
          <Icon name="search" size={14} /><span className="sr-only">Search loaded project items</span>
          <input type="search" placeholder="Find in project" value={search} onChange={(event) => setSearch(event.target.value)} />
        </label>
        <button className="btn btn-quiet btn-small" onClick={refresh}
          disabled={[repoPage, chatPage, taskPage, runPage].some((page) => page.loading)}>Refresh project lists</button>
        {query ? <p className="tile-note">Searching loaded items. Load more below to search older work.</p> : null}

        <SideSection title="Conversations" page={chatPage} retry={refresh}>
          {visibleChats?.map((item) => (
            <button
              key={item.id}
              className={`side-thread${open?.id === item.id ? " is-current" : ""}`}
              aria-current={open?.id === item.id ? "page" : undefined}
              onClick={() => navigate(chatPath(projectId, item.id))}
            >
              <span className="side-item-label">{item.title}</span>
              <span className="muted">{since(item.updated_at)}</span>
            </button>
          ))}
          {visibleChats?.length === 0 && !chatPage.error ? <p className="tile-note">{query ? "No matching conversations." : "No conversations yet."}</p> : null}
        </SideSection>

        <SideSection title="Tasks" page={taskPage} retry={refresh}>
          {visibleTasks?.map((item) => (
            <button
              key={item.id}
              className={`side-thread${focus.kind === "work" && focus.id === item.id ? " is-current" : ""}`}
              aria-current={focus.kind === "work" && focus.id === item.id ? "page" : undefined}
              onClick={() => navigate(workItemPath(projectId, item.id))}
            >
              <span className="side-item-label">{item.title}</span>
              <StatusPill look={WORK_ITEM_STATUS[item.status]} size="sm" />
            </button>
          ))}
          {visibleTasks?.length === 0 && !taskPage.error ? <p className="tile-note">{query ? "No matching tasks." : "No tasks yet."}</p> : null}
        </SideSection>

        <SideSection title="Recent runs" page={runPage} retry={refresh}>
          {visibleRuns?.map((run) => (
            <button
              key={run.id}
              className={`side-thread${focus.kind === "run" && focus.id === run.id ? " is-current" : ""}`}
              aria-current={focus.kind === "run" && focus.id === run.id ? "page" : undefined}
              onClick={() => navigate(projectTaskPath(projectId, run.id))}
            >
              <span className="side-item-label">{run.prompt}</span>
              <StatusPill look={TASK_STATUS[run.status]} size="sm" />
            </button>
          ))}
          {visibleRuns?.length === 0 && !runPage.error ? <p className="tile-note">{query ? "No matching runs." : "No runs yet."}</p> : null}
        </SideSection>
        </div>
      </aside>

      <main className="ws-main">
        {current && selectedError ? <div className="notice" role="alert"><p>Could not refresh this conversation. {selectedError}</p>
          <button className="btn btn-small" onClick={refresh}>Retry conversation</button></div> : null}
        {focus.kind === "chat" && focus.id === "new" ? (
          <NewConversation transport={transport} projectId={projectId} repositories={repos}
            onCreated={(created) => { refresh(); onNavigate(chatPath(projectId, created.id)); }} />
        ) : selectedId && !current ? (
          selectedError ? <div className="notice" role="alert"><p>Could not open this conversation. {selectedError}</p>
            <button className="btn btn-small" onClick={refresh}>Retry conversation</button></div>
            : <p role="status" className="tile-note">Loading conversation…</p>
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
        ) : focus.kind === "home" && chatPage.error && !conversations ? (
          <div className="notice" role="alert"><p>Could not load conversations. {chatPage.error}</p>
            <button className="btn" onClick={refresh}>Retry conversations</button></div>
        ) : focus.kind === "home" && conversations ? (
          <div className="ws-empty">
            <h2>Talk a change through, then hand it to the agent.</h2>
            <p className="tile-note">
              Start a conversation about one of this project's repositories. Ask what the code does, plan a change,
              then turn a reply into a task and let a run do the work.
            </p>
            {repos.length > 0 ? (
              <button type="button" className="btn btn-primary" onClick={() => navigate(chatPath(projectId, "new"))}>
                <Icon name="plus" size={14} /> New conversation
              </button>
            ) : (
              <AddRepository transport={transport} projectId={projectId} attached={repos} onAdded={refresh} />
            )}
          </div>
        ) : focus.kind === "work" && focus.id === "new" ? (
          <section className="card" aria-label="New task">
            <NewWorkItem transport={transport} projectId={projectId} repositories={repos}
              onCreated={(item) => { refresh(); onNavigate(workItemPath(projectId, item.id)); }} />
          </section>
        ) : focus.kind === "work" ? (
          <WorkItemScreen key={focus.id} transport={transport} projectId={projectId} itemId={focus.id} repositories={repos} onNavigate={onNavigate} />
        ) : focus.kind === "run" ? (
          <ProjectTaskScreen key={focus.id} transport={transport} projectId={projectId} taskId={focus.id} onNavigate={onNavigate} />
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
            <section className="card" aria-label="Project repositories">
              <h2 className="chart-title">Repositories</h2>
              {repos.length > 0 ? (
                <ul className="project-repositories">{repos.map((repo) => <li key={repo.id}><b>{repo.name}</b><span>{repo.path}</span></li>)}</ul>
              ) : <p className="tile-note">No repositories yet. Add one to start talking.</p>}
              <AddRepository transport={transport} projectId={projectId} attached={repos} onAdded={refresh} />
            </section>
          </div>
        ) : (
          <p role="status" className="tile-note">Loading…</p>
        )}
      </main>
    </div>
  );
}

function SideSection({ title, page, retry, children }: {
  title: string;
  page: { items: { id: string }[] | null; cursor: string | null; loading: boolean; error: string | null; more: () => Promise<void> };
  retry: () => void;
  children: React.ReactNode;
}) {
  return (
    <section className="ws-section" aria-label={title} aria-busy={page.loading}>
      <h2 className="ws-section-title">{title}{page.items ? <span className="count-pill">{page.items.length}{page.cursor ? "+" : ""}</span> : null}</h2>
      <div className="ws-list">{children}</div>
      {page.loading ? <p className="tile-note" role="status">Loading {title.toLowerCase()}…</p> : null}
      {page.error ? <div className="error" role="alert"><p>{page.error}</p><button className="btn btn-small" onClick={retry}>Retry {title.toLowerCase()}</button></div> : null}
      {page.cursor ? <button className="btn btn-quiet btn-small" disabled={page.loading} onClick={() => void page.more()}>Load more {title.toLowerCase()}</button> : null}
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
  const alive = useRef(true);
  const [created, setCreated] = useState<Conversation | null>(null);
  const createdRef = useRef<Conversation | null>(null);
  useEffect(() => { alive.current = true; return () => { alive.current = false; }; }, []);
  const target = repositories.some((repo) => repo.id === repoId) ? repoId : repositories[0]?.id ?? "";

  const start = async () => {
    const value = text.trim();
    if (!value || !target || inFlight.current || createdRef.current) return;
    inFlight.current = true;
    setBusy(true);
    setError(null);
    try {
      const created = await transport.createProjectConversation(projectId, { repo_id: target, title: titleOf(value) });
      createdRef.current = created;
      if (!alive.current) return;
      setCreated(created);
      const id = typeof crypto !== "undefined" && "randomUUID" in crypto ? crypto.randomUUID() : `req-${Date.now()}`;
      await transport.sendProjectMessage(projectId, created.id, { content: value, request_id: id, mode, ...(model ? { model } : {}) });
      if (alive.current) onCreated(created);
    } catch (cause) {
      if (alive.current) setError(message(cause));
    } finally {
      inFlight.current = false;
      if (alive.current) setBusy(false);
    }
  };

  return (
    <div className="project-chat-pane ws-new-chat">
      <div className="project-chat-head">
        <b>New conversation</b>
        {repositories.length > 1 ? (
          <select className="composer-field" aria-label="Repository" value={target} onChange={(event) => setRepoId(event.target.value)} disabled={busy || created !== null}>
            {repositories.map((repo) => <option key={repo.id} value={repo.id}>{repo.name}</option>)}
          </select>
        ) : <span className="muted">{repositories[0]?.name ?? "no repository"}</span>}
      </div>
      <div className="project-chat-messages">
        <p className="tile-note">Ask what the code does, or plan a change. The model can read the repository.</p>
      </div>
      {created && error ? <div className="notice" role="alert">
        <p>Conversation created. The message's outcome could not be confirmed: {error}</p>
        <button type="button" className="btn" onClick={() => onCreated(created)}>Open conversation to check</button>
      </div> : null}
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
          disabled={busy || created !== null}
        />
        <div className="composer-bar">
          <ModePicker value={mode} options={["ask", "plan"]} modes={modes} onChange={(next) => setMode(next === "plan" ? "plan" : "ask")} disabled={busy || created !== null} />
          <ModelPicker value={model} mode={mode} modes={modes} onChange={setModel} disabled={busy || created !== null} />
          <span className="composer-hint">Enter to send</span>
          <span className="spacer" />
          <button className="send-button" type="submit" aria-label="Send message" disabled={busy || created !== null || !text.trim() || !target}>
            <Icon name="send" size={16} />
          </button>
        </div>
      </form>
      {error && !created ? <p className="notice" role="alert">{error}</p> : null}
    </div>
  );
}
