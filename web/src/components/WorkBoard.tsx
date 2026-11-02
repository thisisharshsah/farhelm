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

/* ------------------------------------------------------------------ board */

export function WorkBoard({ transport, projectId, repositories, onNavigate }: {
  transport: BoardTransport;
  projectId: string;
  repositories: ProjectRepository[];
  onNavigate: (path: string) => void;
}) {
  const [items, setItems] = useState<WorkItemView[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [revision, setRevision] = useState(0);
  const refresh = () => setRevision((value) => value + 1);
  useRunChanges(transport, refresh);

  useEffect(() => {
    let cancelled = false;
    transport.projectWorkItems(projectId, { limit: 100 })
      .then((page) => { if (!cancelled) { setItems(page.items); setError(null); } })
      .catch((cause) => { if (!cancelled) setError(message(cause)); });
    return () => { cancelled = true; };
  }, [transport, projectId, revision]);

  const move = async (item: WorkItemView, status: WorkItemStatus) => {
    // Shown at once, then confirmed by the runner's answer; a refusal puts it back.
    setItems((current) => current?.map((row) => (row.id === item.id ? { ...row, status } : row)) ?? null);
    try {
      await transport.updateProjectWorkItem(projectId, item.id, { status });
    } catch (cause) {
      setError(message(cause));
    }
    refresh();
  };

  return (
    <section className="card work-board" aria-label="Tasks">
      <div className="chart-title">
        <h2>Tasks</h2>
        <button className="btn btn-small" onClick={refresh}>Refresh</button>
      </div>
      {error ? <p className="error" role="alert">{error}</p> : null}
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
                        onChange={(event) => void move(item, event.target.value as WorkItemStatus)}
                      >
                        {WORK_ITEM_STATUSES.map((option) => <option key={option} value={option}>{WORK_ITEM_STATUS[option].label}</option>)}
                      </select>
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

function NewWorkItem({ transport, projectId, repositories, onCreated }: {
  transport: BoardTransport;
  projectId: string;
  repositories: ProjectRepository[];
  onCreated: () => void;
}) {
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
      await transport.createProjectWorkItem(projectId, { title: title.trim(), description, repo_id: repo || null });
      setTitle("");
      setDescription("");
      onCreated();
    } catch (cause) {
      setError(message(cause));
    } finally {
      inFlight.current = false;
      setBusy(false);
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
  const [detail, setDetail] = useState<WorkItemDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [revision, setRevision] = useState(0);
  const refresh = () => setRevision((value) => value + 1);
  useRunChanges(transport, refresh);

  useEffect(() => {
    let cancelled = false;
    transport.projectWorkItem(projectId, itemId)
      .then((next) => { if (!cancelled) { setDetail(next); setError(null); } })
      .catch((cause) => { if (!cancelled) setError(message(cause)); });
    return () => { cancelled = true; };
  }, [transport, projectId, itemId, revision]);

  if (error && !detail) return <p className="error" role="alert">{error}</p>;
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
        <EditWorkItem transport={transport} projectId={projectId} detail={detail} repositories={repositories} onSaved={(next) => setDetail(next)} />
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
  const [title, setTitle] = useState(detail.title);
  const [description, setDescription] = useState(detail.description);
  const [status, setStatus] = useState<WorkItemStatus>(detail.status);
  const [repoId, setRepoId] = useState(detail.repo_id ?? "");
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
      onSaved(next);
    } catch (cause) {
      setError(message(cause));
    } finally {
      inFlight.current = false;
      setBusy(false);
    }
  };

  return (
    <form className="project-workflow-form" onSubmit={(event) => { event.preventDefault(); void save(); }} aria-busy={busy}>
      <label htmlFor="edit-item-title">Title</label>
      <input id="edit-item-title" className="pair-input" value={title} onChange={(event) => setTitle(event.target.value)} disabled={busy} required maxLength={200} />
      <label htmlFor="edit-item-status">Status</label>
      <select id="edit-item-status" className="pair-input" value={status} onChange={(event) => setStatus(event.target.value as WorkItemStatus)} disabled={busy}>
        {WORK_ITEM_STATUSES.map((option) => <option key={option} value={option}>{WORK_ITEM_STATUS[option].label}</option>)}
      </select>
      <label htmlFor="edit-item-description">What should be done</label>
      <textarea id="edit-item-description" className="pair-input" rows={5} value={description} onChange={(event) => setDescription(event.target.value)} disabled={busy} />
      {repositories.length > 0 ? (
        <>
          <label htmlFor="edit-item-repo">Repository</label>
          <select id="edit-item-repo" className="pair-input" value={repoId} onChange={(event) => setRepoId(event.target.value)} disabled={busy}>
            <option value="">Not chosen</option>
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
      onStarted(run);
    } catch (cause) {
      setError(message(cause));
    } finally {
      inFlight.current = false;
      setBusy(false);
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
