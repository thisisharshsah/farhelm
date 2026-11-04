/**
 * A project's tasks: the board, and one task with its runs.
 *
 * A task is planned work (Backlog to Done); a run is one agent attempt on
 * it. You move a task yourself with its status control; a run moves it too
 * (starting: In progress; a proposed change set: Review; applied: Done;
 * rejected, failed or undone: back to To do). Tasks made from a discussion
 * keep the link, so the discussion shows where its work stands.
 */

import { useEffect, useRef, useState } from "react";
import {
  since,
  type ProjectRepository,
  type TaskView,
  type Transport,
  type WorkItemDetail,
  type WorkItemStatus,
  type WorkItemView,
  type UpdateWorkItemRequest,
  WORK_ITEM_STATUSES,
} from "@farhelm/client-core";
import { Icon } from "./Icon";
import { ModelPicker, useModes } from "./ModelChoice";
import { StatusPill, TASK_STATUS, WORK_ITEM_STATUS } from "./status";
import { TaskRow } from "./Tasks";

export type BoardTransport = Transport & Required<Pick<Transport,
  "projectWorkItems" | "createProjectWorkItem" | "projectWorkItem" | "updateProjectWorkItem" | "startWorkItemRun">>;

export function supportsBoard(transport: Transport | null): transport is BoardTransport {
  return transport?.kind === "loopback"
    && [transport.projectWorkItems, transport.createProjectWorkItem, transport.projectWorkItem,
      transport.updateProjectWorkItem, transport.startWorkItemRun].every((method) => typeof method === "function");
}

function message(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause);
}

export function workItemPath(projectId: string, itemId: string): string {
  return `/p/${encodeURIComponent(projectId)}/w/${encodeURIComponent(itemId)}`;
}

function runPath(projectId: string, runId: string): string {
  return `/p/${encodeURIComponent(projectId)}/t/${encodeURIComponent(runId)}`;
}

/** Re-read after runs change: a finished run has moved its task. */
function useRunChanges(transport: Transport, onChange: () => void) {
  const latest = useRef(onChange);
  latest.current = onChange;
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | null = null;
    const off = transport.onEvent((event) => {
      if (event.type !== "task_upsert" || timer !== null) return;
      timer = setTimeout(() => { timer = null; latest.current(); }, 300);
    });
    return () => { off(); if (timer !== null) clearTimeout(timer); };
  }, [transport]);
}

/** Remount forms and pending callbacks at an account/resource boundary. */
function useScopeKey(transport: Transport | null, projectId = "", itemId = "") {
  const [scope, setScope] = useState({ transport, projectId, itemId, key: 0 });
  if (scope.transport !== transport || scope.projectId !== projectId || scope.itemId !== itemId) {
    const next = { transport, projectId, itemId, key: scope.key + 1 };
    setScope(next);
    return next.key;
  }
  return scope.key;
}

function useActive() {
  const active = useRef(true);
  useEffect(() => { active.current = true; return () => { active.current = false; }; }, []);
  return active;
}

/** Keep cards in their confirmed column until the runner accepts a change. */
function useTaskMoves(
  transport: BoardTransport | null,
  onSaved: (projectId: string, item: WorkItemDetail) => void,
) {
  const active = useActive();
  const inFlight = useRef(new Set<string>());
  const version = useRef(0);
  const [pending, setPending] = useState<Set<string>>(() => new Set());
  const [error, setError] = useState<string | null>(null);
  const move = async (projectId: string, item: WorkItemView, status: WorkItemStatus) => {
    if (!transport || inFlight.current.has(item.id) || item.status === status) return;
    inFlight.current.add(item.id);
    version.current += 1;
    setPending(new Set(inFlight.current));
    setError(null);
    try {
      const saved = await transport.updateProjectWorkItem(projectId, item.id, { status });
      if (active.current) onSaved(projectId, saved);
    } catch (cause) {
      if (active.current) setError(message(cause));
    } finally {
      version.current += 1;
      inFlight.current.delete(item.id);
      if (active.current) setPending(new Set(inFlight.current));
    }
  };
  return { move, pending, error, version };
}

/* ------------------------------------------------------------------ board */

export function WorkBoard({ transport, projectId, repositories, onNavigate }: {
  transport: BoardTransport;
  projectId: string;
  repositories: ProjectRepository[];
  onNavigate: (path: string) => void;
}) {
  const key = useScopeKey(transport, projectId);
  return <WorkBoardContent key={key} transport={transport} projectId={projectId} repositories={repositories} onNavigate={onNavigate} />;
}

function WorkBoardContent({ transport, projectId, repositories, onNavigate }: {
  transport: BoardTransport;
  projectId: string;
  repositories: ProjectRepository[];
  onNavigate: (path: string) => void;
}) {
  const [items, setItems] = useState<WorkItemView[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [more, setMore] = useState(false);
  const moves = useTaskMoves(transport, (_project, saved) => {
    setItems((current) => current?.map((item) => item.id === saved.id ? saved : item) ?? null);
  });
  const [revision, setRevision] = useState(0);
  const refresh = () => setRevision((value) => value + 1);
  useRunChanges(transport, refresh);

  useEffect(() => {
    let cancelled = false;
    const version = moves.version.current;
    transport.projectWorkItems(projectId, { limit: 100 })
      .then((page) => { if (!cancelled && version === moves.version.current) { setItems(page.items); setMore(page.next_cursor !== null); setError(null); } })
      .catch((cause) => { if (!cancelled && version === moves.version.current) setError(message(cause)); });
    return () => { cancelled = true; };
  }, [transport, projectId, revision]);

  return (
    <section className="card work-board" aria-label="Tasks">
      <div className="chart-title">
        <h2>Tasks</h2>
        <button className="btn btn-small" onClick={refresh}>Refresh</button>
      </div>
      {error || moves.error ? <p className="error" role="alert">{moves.error ?? error}</p> : null}
      {more ? <p className="tile-note">Showing the first 100 tasks in this project.</p> : null}
      {items === null && !error ? <p role="status" className="tile-note">Loading tasks…</p> : null}
      {items?.length === 0 ? <p className="tile-note">No tasks yet. Add one below, or create one from a discussion.</p> : null}
      {items && items.length > 0 ? (
        <div className="kanban-board work-columns">
          {WORK_ITEM_STATUSES.map((status) => {
            const look = WORK_ITEM_STATUS[status];
            const column = items.filter((item) => item.status === status);
            return (
              <section className="kanban-column" key={status} data-tone={look.tone} aria-label={look.label}>
                <h3 className="kanban-column-head">{look.label} <span className="muted">{column.length}</span></h3>
                <div className="kanban-stack">
                  {column.map((item) => (
                    <article className="kanban-card work-card-item" key={item.id}>
                      <button type="button" className="work-item-title" onClick={() => onNavigate(workItemPath(projectId, item.id))}>
                        {item.title}
                      </button>
                      <div className="kanban-card-meta">
                        {item.latest_run ? <StatusPill look={TASK_STATUS[item.latest_run.status]} size="sm" /> : null}
                        {item.latest_run ? <span className="muted">run {since(item.latest_run.updated_at)}</span> : null}
                        {item.conversation_id ? <span className="muted" title="Made from a discussion"><Icon name="link" size={12} /></span> : null}
                      </div>
                      <select
                        className="board-select work-item-move"
                        aria-label={`Status of ${item.title}`}
                        value={item.status}
                        disabled={moves.pending.has(item.id)}
                        onChange={(event) => void moves.move(projectId, item, event.target.value as WorkItemStatus)}
                      >
                        {WORK_ITEM_STATUSES.map((option) => <option key={option} value={option}>{WORK_ITEM_STATUS[option].label}</option>)}
                      </select>
                      {moves.pending.has(item.id) ? <span className="muted" role="status">Saving status…</span> : null}
                    </article>
                  ))}
                </div>
              </section>
            );
          })}
        </div>
      ) : null}
      <NewWorkItem transport={transport} projectId={projectId} repositories={repositories} onCreated={refresh} />
    </section>
  );
}

export function NewWorkItem({ transport, projectId, repositories, onCreated }: {
  transport: BoardTransport;
  projectId: string;
  repositories: ProjectRepository[];
  onCreated: (item: WorkItemView) => void;
}) {
  const key = useScopeKey(transport, projectId);
  return <NewWorkItemContent key={key} transport={transport} projectId={projectId} repositories={repositories} onCreated={onCreated} />;
}

function NewWorkItemContent({ transport, projectId, repositories, onCreated }: {
  transport: BoardTransport;
  projectId: string;
  repositories: ProjectRepository[];
  onCreated: (item: WorkItemView) => void;
}) {
  const active = useActive();
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [repoId, setRepoId] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);
  const repo = repositories.some((item) => item.id === repoId) ? repoId : "";

  const submit = async () => {
    if (!title.trim() || inFlight.current) return;
    inFlight.current = true;
    setBusy(true);
    setError(null);
    try {
      const created = await transport.createProjectWorkItem(projectId, { title: title.trim(), description, repo_id: repo || null });
      setTitle("");
      setDescription("");
      if (active.current) onCreated(created);
    } catch (cause) {
      if (active.current) setError(message(cause));
    } finally {
      inFlight.current = false;
      if (active.current) setBusy(false);
    }
  };

  return (
    <form className="project-workflow-form" onSubmit={(event) => { event.preventDefault(); void submit(); }} aria-busy={busy}>
      <h3>Add a task</h3>
      <label htmlFor="work-item-title">Title</label>
      <input id="work-item-title" className="pair-input" value={title} onChange={(event) => setTitle(event.target.value)} disabled={busy} required maxLength={200} />
      <label htmlFor="work-item-description">What should be done (optional; the agent reads this)</label>
      <textarea id="work-item-description" className="pair-input" rows={3} value={description} onChange={(event) => setDescription(event.target.value)} disabled={busy} />
      {repositories.length > 0 ? (
        <>
          <label htmlFor="work-item-repo">Repository (optional)</label>
          <select id="work-item-repo" className="pair-input" value={repo} onChange={(event) => setRepoId(event.target.value)} disabled={busy}>
            <option value="">Choose later</option>
            {repositories.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}
          </select>
        </>
      ) : null}
      {error ? <p className="error" role="alert">{error}</p> : null}
      <div className="approval-actions">
        <button className="btn btn-primary" type="submit" disabled={busy || !title.trim()}>{busy ? "Adding…" : "Add task"}</button>
      </div>
    </form>
  );
}

/* ------------------------------------------------------------------- task */

export function WorkItemScreen({ transport, projectId, itemId, repositories, onNavigate }: {
  transport: BoardTransport;
  projectId: string;
  itemId: string;
  repositories: ProjectRepository[];
  onNavigate: (path: string) => void;
}) {
  const key = useScopeKey(transport, projectId, itemId);
  return <WorkItemScreenContent key={key} transport={transport} projectId={projectId} itemId={itemId} repositories={repositories} onNavigate={onNavigate} />;
}

function WorkItemScreenContent({ transport, projectId, itemId, repositories, onNavigate }: {
  transport: BoardTransport;
  projectId: string;
  itemId: string;
  repositories: ProjectRepository[];
  onNavigate: (path: string) => void;
}) {
  const reads = useRef(0);
  const [detail, setDetail] = useState<WorkItemDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [revision, setRevision] = useState(0);
  const refresh = () => setRevision((value) => value + 1);
  useRunChanges(transport, refresh);

  useEffect(() => {
    let cancelled = false;
    const read = ++reads.current;
    transport.projectWorkItem(projectId, itemId)
      .then((next) => { if (!cancelled && read === reads.current) { setDetail(next); setError(null); } })
      .catch((cause) => { if (!cancelled && read === reads.current) setError(message(cause)); });
    return () => { cancelled = true; };
  }, [transport, projectId, itemId, revision]);

  if (error && !detail) return <div><p className="error" role="alert">{error}</p><button className="btn" onClick={refresh}>Try again</button></div>;
  if (!detail) return <p role="status" className="tile-note">Loading task…</p>;
  const look = WORK_ITEM_STATUS[detail.status];
  const working = detail.runs.some((run) => run.status === "running");

  return (
    <div className="work-item-screen">
      <header className="view-head">
        <div>
          <span className="thread-crumb">Task</span>
          <h1 className="view-title">{detail.title}</h1>
        </div>
        <StatusPill look={look} />
        <span className="spacer" />
        <button className="btn btn-quiet btn-small" onClick={() => onNavigate(`/p/${encodeURIComponent(projectId)}`)}>Back to project</button>
      </header>
      {error ? <p className="error" role="alert">{error}</p> : null}

      <section className="card" aria-label="Task details">
        <EditWorkItem transport={transport} projectId={projectId} detail={detail} repositories={repositories} onSaved={(next) => { reads.current += 1; setDetail(next); }} />
        {detail.conversation_id ? <p className="tile-note">Made from a discussion in this project.</p> : null}
      </section>

      <section className="card" aria-label="Run the agent">
        <h2 className="chart-title">Run the agent</h2>
        {working ? (
          <p className="tile-note">A run is working on this task. It will move the task to Review when it proposes a change.</p>
        ) : (
          <RunWorkItem transport={transport} projectId={projectId} detail={detail} repositories={repositories}
            onStarted={(run) => onNavigate(runPath(projectId, run.id))} />
        )}
      </section>

      <section className="card" aria-label="Runs">
        <h2 className="chart-title">Runs</h2>
        {detail.runs.length === 0 ? <p className="tile-note">No runs yet.</p> : null}
        <div className="task-list">
          {detail.runs.map((run) => <TaskRow key={run.id} task={run} onOpen={() => onNavigate(runPath(projectId, run.id))} />)}
        </div>
      </section>
    </div>
  );
}

function EditWorkItem({ transport, projectId, detail, repositories, onSaved }: {
  transport: BoardTransport;
  projectId: string;
  detail: WorkItemDetail;
  repositories: ProjectRepository[];
  onSaved: (next: WorkItemDetail) => void;
}) {
  const active = useActive();
  const [draft, setDraft] = useState<UpdateWorkItemRequest>({});
  const title = draft.title ?? detail.title;
  const description = draft.description ?? detail.description;
  const status = draft.status ?? detail.status;
  const repoId = draft.repo_id ?? detail.repo_id ?? "";
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);
  const changed = title.trim() !== detail.title || description !== detail.description
    || status !== detail.status || (repoId || null) !== detail.repo_id;

  const save = async () => {
    if (inFlight.current || !title.trim()) return;
    inFlight.current = true;
    setBusy(true);
    setError(null);
    try {
      const next = await transport.updateProjectWorkItem(projectId, detail.id, {
        ...(title.trim() !== detail.title ? { title: title.trim() } : {}),
        ...(description !== detail.description ? { description } : {}),
        ...(status !== detail.status ? { status } : {}),
        ...(repoId && repoId !== detail.repo_id ? { repo_id: repoId } : {}),
      });
      if (active.current) { setDraft({}); onSaved(next); }
    } catch (cause) {
      if (active.current) setError(message(cause));
    } finally {
      inFlight.current = false;
      if (active.current) setBusy(false);
    }
  };

  return (
    <form className="project-workflow-form" onSubmit={(event) => { event.preventDefault(); void save(); }} aria-busy={busy}>
      <label htmlFor="edit-item-title">Title</label>
      <input id="edit-item-title" className="pair-input" value={title} onChange={(event) => setDraft((current) => ({ ...current, title: event.target.value }))} disabled={busy} required maxLength={200} />
      <label htmlFor="edit-item-status">Status</label>
      <select id="edit-item-status" className="pair-input" value={status} onChange={(event) => setDraft((current) => ({ ...current, status: event.target.value as WorkItemStatus }))} disabled={busy}>
        {WORK_ITEM_STATUSES.map((option) => <option key={option} value={option}>{WORK_ITEM_STATUS[option].label}</option>)}
      </select>
      <label htmlFor="edit-item-description">What should be done</label>
      <textarea id="edit-item-description" className="pair-input" rows={5} value={description} onChange={(event) => setDraft((current) => ({ ...current, description: event.target.value }))} disabled={busy} />
      {repositories.length > 0 ? (
        <>
          <label htmlFor="edit-item-repo">Repository</label>
          <select id="edit-item-repo" className="pair-input" value={repoId} onChange={(event) => setDraft((current) => ({ ...current, repo_id: event.target.value }))} disabled={busy}>
            {!detail.repo_id ? <option value="">Not chosen</option> : null}
            {repositories.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}
          </select>
        </>
      ) : null}
      {error ? <p className="error" role="alert">{error}</p> : null}
      <div className="approval-actions">
        <span className="muted">Updated {since(detail.updated_at)}</span>
        <span className="spacer" />
        <button className="btn btn-primary" type="submit" disabled={busy || !changed || !title.trim()}>{busy ? "Saving…" : "Save"}</button>
      </div>
    </form>
  );
}

function RunWorkItem({ transport, projectId, detail, repositories, onStarted }: {
  transport: BoardTransport;
  projectId: string;
  detail: WorkItemDetail;
  repositories: ProjectRepository[];
  onStarted: (run: TaskView) => void;
}) {
  const modes = useModes(transport);
  const active = useActive();
  const [prompt, setPrompt] = useState("");
  const [model, setModel] = useState("");
  const [repoId, setRepoId] = useState(detail.repo_id ?? "");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);
  const repo = repositories.some((item) => item.id === repoId) ? repoId : "";
  const fallback = detail.description.trim() ? `${detail.title}\n\n${detail.description.trim()}` : detail.title;

  const start = async () => {
    if (inFlight.current || !repo) return;
    inFlight.current = true;
    setBusy(true);
    setError(null);
    try {
      const run = await transport.startWorkItemRun(projectId, detail.id, {
        repo_id: repo,
        ...(prompt.trim() ? { prompt: prompt.trim() } : {}),
        ...(model ? { model } : {}),
      });
      if (active.current) onStarted(run);
    } catch (cause) {
      if (active.current) setError(message(cause));
    } finally {
      inFlight.current = false;
      if (active.current) setBusy(false);
    }
  };

  return (
    <form className="project-workflow-form" onSubmit={(event) => { event.preventDefault(); void start(); }} aria-busy={busy}>
      <p className="tile-note">The agent works in its own worktree and proposes a diff for review. The task moves to In progress, then Review.</p>
      <label htmlFor="run-item-repo">Repository</label>
      <select id="run-item-repo" className="pair-input" value={repo} onChange={(event) => setRepoId(event.target.value)} disabled={busy} required>
        <option value="">Choose a repository</option>
        {repositories.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}
      </select>
      <label htmlFor="run-item-prompt">Instruction (the task's text unless you change it)</label>
      <textarea id="run-item-prompt" className="pair-input" rows={4} value={prompt} placeholder={fallback} onChange={(event) => setPrompt(event.target.value)} disabled={busy} />
      {modes && modes.models.length > 0 ? (
        <>
          <label htmlFor="run-item-model">Model</label>
          <ModelPicker id="run-item-model" value={model} mode="agent" modes={modes} onChange={setModel} disabled={busy} />
        </>
      ) : null}
      {error ? <p className="error" role="alert">{error}</p> : null}
      <div className="approval-actions">
        <button className="btn btn-primary" type="submit" disabled={busy || !repo}>{busy ? "Starting…" : "Start run"}</button>
      </div>
    </form>
  );
}

/* --------------------------------------------------------------- overview */

interface ProjectTasks { projectId: string; projectName: string; items: WorkItemView[] }

/**
 * Every project's tasks on one board. Read project by project, because the
 * runner scopes tasks to a project; a workspace-wide list is a later route.
 */
export function WorkOverview({ transport, onNavigate }: {
  transport: Transport | null;
  onNavigate: (path: string) => void;
}) {
  const key = useScopeKey(transport);
  return <WorkOverviewContent key={key} transport={transport} onNavigate={onNavigate} />;
}

function WorkOverviewContent({ transport, onNavigate }: {
  transport: Transport | null;
  onNavigate: (path: string) => void;
}) {
  const [projects, setProjects] = useState<ProjectTasks[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [projectFilter, setProjectFilter] = useState("");
  const [limited, setLimited] = useState(false);
  const [loading, setLoading] = useState(true);
  // A refresh waits for the previous batch's in-flight reads to settle. Its
  // remaining queued projects are skipped, so repeated refreshes still use
  // at most two project reads on this runner.
  const readBatch = useRef<Promise<void>>(Promise.resolve());
  const [revision, setRevision] = useState(0);
  const refresh = () => setRevision((value) => value + 1);
  const board = supportsBoard(transport) ? transport : null;
  const moves = useTaskMoves(board, (projectId, saved) => {
    setProjects((current) => current?.map((project) => project.projectId !== projectId ? project
      : { ...project, items: project.items.map((item) => item.id === saved.id ? saved : item) }) ?? null);
  });
  useEffect(() => {
    if (!board) return;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const off = board.onEvent((event) => {
      if (event.type !== "task_upsert" || timer !== null) return;
      timer = setTimeout(() => { timer = null; setRevision((value) => value + 1); }, 300);
    });
    return () => { off(); if (timer !== null) clearTimeout(timer); };
  }, [board]);

  useEffect(() => {
    if (!board || typeof board.projects !== "function") return;
    let cancelled = false;
    const version = moves.version.current;
    const list = board.projects;
    setLoading(true);
    const load = async () => {
      if (cancelled) return;
      const page = await list({ limit: 50 });
      let hasMore = page.next_cursor !== null;
      let failed = 0;
      let next = 0;
      const loaded: Array<ProjectTasks | undefined> = new Array(page.projects.length);
      const worker = async () => {
        while (!cancelled) {
          const index = next++;
          const project = page.projects[index];
          if (!project) return;
          try {
            const tasks = await board.projectWorkItems(project.id, { limit: 100 });
            if (tasks.next_cursor !== null) hasMore = true;
            loaded[index] = { projectId: project.id, projectName: project.name, items: tasks.items };
          } catch {
            failed += 1;
          }
        }
      };
      await Promise.all([worker(), worker()]);
      if (!cancelled && version === moves.version.current) {
        setProjects(loaded.filter((project): project is ProjectTasks => project !== undefined));
        setLimited(hasMore);
        setError(failed > 0 ? `Could not load ${failed} project${failed === 1 ? "" : "s"}; showing available tasks. Refresh to try again.` : null);
      }
    };
    readBatch.current = readBatch.current.then(load)
      .catch((cause) => { if (!cancelled && version === moves.version.current) setError(message(cause)); })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [board, revision]);

  if (!board) return null;
  const all = (projects ?? []).flatMap((project) => project.items.map((item) => ({ item, project })));
  const activeProject = projects?.some((project) => project.projectId === projectFilter) ? projectFilter : "";
  const query = search.trim().toLowerCase();
  const filtered = all.filter(({ item, project }) =>
    (!activeProject || project.projectId === activeProject)
    && (!query || (item.title + " " + item.description + " " + project.projectName).toLowerCase().includes(query)));
  const clearFilters = () => { setSearch(""); setProjectFilter(""); };

  return (
    <section className="card work-board" aria-label="Tasks across projects">
      <div className="chart-title">
        <h2>Tasks</h2>
        <span className="muted">{projects ? `${all.length} across ${projects.length} loaded project${projects.length === 1 ? "" : "s"}` : ""}</span>
        <span className="spacer" />
        <button className="btn btn-small" onClick={refresh} disabled={loading}>{loading ? "Refreshing…" : "Refresh"}</button>
      </div>
      <div className="board-toolbar">
        <label className="board-search">
          <Icon name="search" size={14} />
          <span className="sr-only">Search tasks</span>
          <input type="search" placeholder="Search tasks" value={search} onChange={(event) => setSearch(event.target.value)} />
        </label>
        <select className="board-select" aria-label="Filter tasks by project" value={activeProject} onChange={(event) => setProjectFilter(event.target.value)}>
          <option value="">All projects</option>
          {projects?.map((project) => <option key={project.projectId} value={project.projectId}>{project.projectName}</option>)}
        </select>
        {search || activeProject ? <button className="btn btn-small" onClick={clearFilters}>Clear filters</button> : null}
        {projects ? <span className="muted" role="status">{filtered.length} of {all.length} loaded tasks</span> : null}
      </div>
      {limited ? <p className="tile-note">This view shows up to 50 projects and the first 100 tasks per project. Some tasks are not loaded.</p> : null}
      {error || moves.error ? <p className="error" role="alert">{moves.error ?? error}</p> : null}
      {projects === null && !error ? <p role="status" className="tile-note">Loading tasks…</p> : null}
      {projects && all.length === 0 && !error ? <p className="tile-note">No tasks in the loaded projects. Open a project to add one or create one from a discussion.</p> : null}
      {all.length > 0 && filtered.length === 0 ? (
        <div className="empty-state"><p className="empty-title">No matching tasks</p><p className="tile-note">Try a different search or project.</p><button className="btn" onClick={clearFilters}>Show all loaded tasks</button></div>
      ) : null}
      {filtered.length > 0 ? (
        <div className="kanban-board work-columns">
          {WORK_ITEM_STATUSES.map((status) => {
            const look = WORK_ITEM_STATUS[status];
            const column = filtered.filter(({ item }) => item.status === status);
            return (
              <section className="kanban-column" key={status} data-tone={look.tone} aria-label={look.label}>
                <h3 className="kanban-column-head">{look.label} <span className="muted">{column.length}</span></h3>
                <div className="kanban-stack">
                  {column.length === 0 ? <p className="kanban-empty">No tasks</p> : null}
                  {column.map(({ item, project }) => (
                    <article className="kanban-card work-card-item" key={item.id}>
                      <span className="thread-crumb">{project.projectName}</span>
                      <button type="button" className="work-item-title" onClick={() => onNavigate(workItemPath(project.projectId, item.id))}>
                        {item.title}
                      </button>
                      <div className="kanban-card-meta">
                        {item.latest_run ? <StatusPill look={TASK_STATUS[item.latest_run.status]} size="sm" /> : null}
                        {item.latest_run ? <span className="muted">run {since(item.latest_run.updated_at)}</span> : null}
                      </div>
                      <select
                        className="board-select work-item-move"
                        aria-label={`Status of ${item.title}`}
                        value={item.status}
                        disabled={moves.pending.has(item.id)}
                        onChange={(event) => void moves.move(project.projectId, item, event.target.value as WorkItemStatus)}
                      >
                        {WORK_ITEM_STATUSES.map((option) => <option key={option} value={option}>{WORK_ITEM_STATUS[option].label}</option>)}
                      </select>
                      {moves.pending.has(item.id) ? <span className="muted" role="status">Saving status…</span> : null}
                    </article>
                  ))}
                </div>
              </section>
            );
          })}
        </div>
      ) : null}
    </section>
  );
}
