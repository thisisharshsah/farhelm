import { useEffect, useMemo, useRef, useState } from "react";
import type { ProjectListOptions, ProjectRepository, TaskDetail, TaskView, Transport } from "@farhelm/client-core";
import { TaskReviewScreen, TaskRow } from "./Tasks";

type WorkflowTransport = Transport & Required<Pick<Transport,
  "projectRepoCandidates" | "projectRepositories" | "attachProjectRepository" | "projectTasks"
  | "startProjectTask" | "projectTask" | "reviewProjectTask" | "revertProjectTask">>;

function supportsWorkflow(transport: Transport | null): transport is WorkflowTransport {
  return transport?.kind === "loopback" && transport.supportsProjectWorkflow === true
    && [transport.projectRepoCandidates, transport.projectRepositories, transport.attachProjectRepository,
      transport.projectTasks, transport.startProjectTask, transport.projectTask,
      transport.reviewProjectTask, transport.revertProjectTask].every((method) => typeof method === "function");
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause);
}

function WorkflowUnavailable() {
  return <p className="tile-note">Connect directly to a compatible runner to manage project repositories and tasks.</p>;
}

/** Remount forms and request lifetimes when the runner or project changes. */
export function ProjectWorkflow({ transport, projectId, onNavigate }: {
  transport: Transport | null;
  projectId: string;
  onNavigate: (path: string) => void;
}) {
  const [scope, setScope] = useState({ transport, projectId, generation: 0 });
  if (scope.transport !== transport || scope.projectId !== projectId) {
    setScope({ transport, projectId, generation: scope.generation + 1 });
    return null;
  }
  if (!supportsWorkflow(transport)) return <WorkflowUnavailable />;
  return <WorkflowScope key={scope.generation} transport={transport} projectId={projectId} onNavigate={onNavigate} />;
}

interface Page<T> { items: T[]; next: string | null }
const PAGE_SIZE = 50;
const RETAINED_ROWS = 200;

/** Keep only a bounded window; cursor loading can still reach older rows. */
function useProjectPage<T extends { id: string }>(load: (options: ProjectListOptions) => Promise<Page<T>>) {
  const loader = useRef(load);
  loader.current = load;
  const [data, setData] = useState<Page<T> | null>(null);
  const [pending, setPending] = useState(true);
  const [morePending, setMorePending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [revision, setRevision] = useState(0);
  const sequence = useRef(0);
  const moreInFlight = useRef(false);
  const alive = useRef(true);

  useEffect(() => {
    alive.current = true;
    const request = ++sequence.current;
    moreInFlight.current = false;
    setPending(true);
    setMorePending(false);
    setError(null);
    void loader.current({ limit: PAGE_SIZE }).then((page) => {
      if (alive.current && sequence.current === request) setData(page);
    }).catch((cause: unknown) => {
      if (alive.current && sequence.current === request) setError(errorMessage(cause));
    }).finally(() => {
      if (alive.current && sequence.current === request) setPending(false);
    });
    return () => { alive.current = false; sequence.current += 1; };
  }, [revision]);

  async function more() {
    if (!data?.next || pending || moreInFlight.current) return;
    moreInFlight.current = true;
    const request = sequence.current;
    const cursor = data.next;
    setMorePending(true);
    setError(null);
    try {
      const page = await loader.current({ after: cursor, limit: PAGE_SIZE });
      if (!alive.current || request !== sequence.current) return;
      if (page.next === cursor) throw new Error("The runner returned the same cursor. Refresh to continue.");
      setData((current) => {
        const seen = new Set(current?.items.map((item) => item.id));
        return { items: [...(current?.items ?? []), ...page.items.filter((item) => !seen.has(item.id))].slice(-RETAINED_ROWS), next: page.next };
      });
    } catch (cause) {
      if (alive.current && request === sequence.current) setError(errorMessage(cause));
    } finally {
      if (alive.current && request === sequence.current) {
        moreInFlight.current = false;
        setMorePending(false);
      }
    }
  }
  return { data, pending, morePending, error, more, refresh: () => setRevision((value) => value + 1) };
}

function CollectionStatus<T>({ resource, noun }: {
  resource: { data: Page<T> | null; pending: boolean; error: string | null };
  noun: string;
}) {
  return <>
    {resource.pending ? <p role="status">{resource.data ? `Refreshing ${noun}…` : `Loading ${noun}…`}</p> : null}
    {resource.error ? <div className="error" role="alert"><p>{resource.error}</p>
      {resource.data ? <p>Showing previously loaded {noun}. Refresh to check current state.</p> : null}</div> : null}
  </>;
}

function WorkflowScope({ transport, projectId, onNavigate }: {
  transport: WorkflowTransport;
  projectId: string;
  onNavigate: (path: string) => void;
}) {
  const attached = useProjectPage(async (options) => {
    const page = await transport.projectRepositories(projectId, options);
    return { items: page.repositories, next: page.next_cursor };
  });
  const candidates = useProjectPage(async (options) => {
    const page = await transport.projectRepoCandidates(projectId, options);
    return { items: page.repositories, next: page.next_cursor };
  });
  const tasks = useProjectPage(async (options) => {
    const page = await transport.projectTasks(projectId, options);
    return { items: page.tasks, next: page.next_cursor };
  });
  const [repoId, setRepoId] = useState("");
  const [attaching, setAttaching] = useState(false);
  const [attachError, setAttachError] = useState<string | null>(null);
  const attachmentInFlight = useRef(false);
  const active = useRef(true);
  const refreshTasks = useRef(tasks.refresh);
  refreshTasks.current = tasks.refresh;

  useEffect(() => {
    active.current = true;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const off = transport.onEvent((event) => {
      if (event.type !== "task_upsert" || timer !== null) return;
      timer = setTimeout(() => { timer = null; refreshTasks.current(); }, 250);
    });
    return () => { active.current = false; off(); if (timer !== null) clearTimeout(timer); };
  }, [transport]);

  const repos = attached.data?.items ?? [];
  const available = (candidates.data?.items ?? []).filter((candidate) => !repos.some((repo) => repo.id === candidate.id));
  const selectedCandidate = available.some((repo) => repo.id === repoId) ? repoId : "";

  async function attach() {
    if (attachmentInFlight.current || !selectedCandidate) return;
    attachmentInFlight.current = true;
    setAttaching(true);
    setAttachError(null);
    try {
      await transport.attachProjectRepository(projectId, selectedCandidate);
      if (!active.current) return;
      setRepoId("");
      attached.refresh();
      candidates.refresh();
    } catch (cause) {
      if (active.current) setAttachError(errorMessage(cause));
    } finally {
      attachmentInFlight.current = false;
      if (active.current) setAttaching(false);
    }
  }

  return <div className="project-workflow">
    <section className="card" aria-label="Project repositories">
      <div className="chart-title"><h2>Repositories</h2><button className="btn" disabled={attached.pending || attaching} onClick={attached.refresh}>Refresh repositories</button></div>
      <CollectionStatus resource={attached} noun="repositories" />
      {attached.data?.items.length === 0 ? <p>No repositories attached to this project.</p> : null}
      {repos.length > 0 ? <ul className="project-repositories">{repos.map((repo) => <li key={repo.id}><b>{repo.name}</b><span>{repo.path}</span></li>)}</ul> : null}
      {attached.data?.next ? <button className="btn" disabled={attached.pending || attached.morePending} onClick={() => void attached.more()}>{attached.morePending ? "Loading repositories…" : "Load more repositories"}</button> : null}
      <form className="project-workflow-form" onSubmit={(event) => { event.preventDefault(); void attach(); }} aria-busy={attaching}>
        <h3>Attach a registered repository</h3>
        <p className="tile-note">Choose a repository already registered on this runner. Attaching it does not start code.</p>
        <CollectionStatus resource={candidates} noun="registered repositories" />
        <label htmlFor="project-attach-repo">Registered repository</label>
        <select id="project-attach-repo" className="pair-input" value={selectedCandidate} onChange={(event) => setRepoId(event.target.value)} disabled={attaching || candidates.pending} required>
          <option value="">Choose a repository</option>
          {available.map((repo) => <option key={repo.id} value={repo.id}>{repo.name} — {repo.path}</option>)}
        </select>
        {candidates.data && available.length === 0 ? <p className="tile-note">No unattached repositories are loaded. Register a repository on this runner first, or load another page.</p> : null}
        <div className="approval-actions">
          <button className="btn" type="button" disabled={candidates.pending || attaching} onClick={candidates.refresh}>Refresh registered repositories</button>
          {candidates.data?.next ? <button className="btn" type="button" disabled={candidates.pending || candidates.morePending || attaching} onClick={() => void candidates.more()}>Load more registered repositories</button> : null}
          <button className="btn btn-primary" type="submit" disabled={attaching || !selectedCandidate || candidates.pending}>{attaching ? "Attaching…" : "Attach repository"}</button>
        </div>
        {attachError ? <p className="error" role="alert">{attachError}</p> : null}
      </form>
    </section>
    <StartProjectTask transport={transport} projectId={projectId} repositories={repos} disabled={attached.pending || !!attached.error}
      onStarted={(task) => { tasks.refresh(); onNavigate(projectTaskPath(projectId, task.id)); }} />
    <section className="card" aria-label="Project task history">
      <div className="chart-title"><h2>Task history</h2><button className="btn" disabled={tasks.pending || tasks.morePending} onClick={tasks.refresh}>Refresh tasks</button></div>
      <p className="tile-note">Up to 200 loaded tasks are retained here. Refresh returns to the newest tasks.</p>
      <CollectionStatus resource={tasks} noun="tasks" />
      {tasks.data?.items.length === 0 ? <p>No tasks have started in this project.</p> : null}
      <div className="task-list">{tasks.data?.items.map((task) => <TaskRow key={task.id} task={task} onOpen={() => onNavigate(projectTaskPath(projectId, task.id))} />)}</div>
      {tasks.data?.next ? <button className="btn" disabled={tasks.pending || tasks.morePending} onClick={() => void tasks.more()}>{tasks.morePending ? "Loading tasks…" : "Load older tasks"}</button> : null}
    </section>
  </div>;
}

export function projectTaskPath(projectId: string, taskId: string): string {
  return `/p/${encodeURIComponent(projectId)}/t/${encodeURIComponent(taskId)}`;
}

function StartProjectTask({ transport, projectId, repositories, disabled, onStarted }: {
  transport: WorkflowTransport;
  projectId: string;
  repositories: ProjectRepository[];
  disabled: boolean;
  onStarted: (task: TaskView) => void;
}) {
  const [repoId, setRepoId] = useState("");
  const [prompt, setPrompt] = useState("");
  const [budget, setBudget] = useState("");
  const [maxSteps, setMaxSteps] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);
  const active = useRef(true);
  useEffect(() => { active.current = true; return () => { active.current = false; }; }, []);
  const selectedRepo = repositories.some((repo) => repo.id === repoId) ? repoId : "";

  async function start() {
    if (inFlight.current || disabled) return;
    if (!selectedRepo || !prompt.trim() || new TextEncoder().encode(prompt).length > 65_536) {
      setError("Choose an attached repository and enter an instruction within 64 KiB."); return;
    }
    const parsedBudget = budget.trim() ? Number(budget) : undefined;
    const steps = maxSteps.trim() ? Number(maxSteps) : undefined;
    if (parsedBudget !== undefined && (!Number.isFinite(parsedBudget) || parsedBudget <= 0)) {
      setError("The task budget must be a positive amount."); return;
    }
    if (steps !== undefined && (!Number.isInteger(steps) || steps < 1 || steps > 256)) {
      setError("The step limit must be between 1 and 256."); return;
    }
    inFlight.current = true; setPending(true); setError(null);
    try {
      const task = await transport.startProjectTask(projectId, { repo_id: selectedRepo, prompt: prompt.trim(), budget_usd: parsedBudget, max_steps: steps });
      if (active.current) { setPrompt(""); onStarted(task); }
    } catch (cause) {
      if (active.current) setError(errorMessage(cause));
    } finally {
      inFlight.current = false; if (active.current) setPending(false);
    }
  }

  return <section className="card" aria-label="Start a project task">
    <h2 className="chart-title">Start a task</h2>
    <p className="tile-note">The agent works in the selected repository and proposes a diff for review. Commands still require the runner’s approval policy.</p>
    <form className="project-workflow-form" onSubmit={(event) => { event.preventDefault(); void start(); }} aria-busy={pending}>
      <fieldset disabled={pending || disabled || repositories.length === 0}>
        <label htmlFor="project-task-repo">Attached repository</label>
        <select id="project-task-repo" className="pair-input" value={selectedRepo} onChange={(event) => setRepoId(event.target.value)} required>
          <option value="">Choose an attached repository</option>
          {repositories.map((repo) => <option key={repo.id} value={repo.id}>{repo.name} — {repo.path}</option>)}
        </select>
        <label htmlFor="project-task-prompt">Task instruction</label>
        <textarea id="project-task-prompt" className="pair-input" rows={4} value={prompt} onChange={(event) => setPrompt(event.target.value)} required />
        <label htmlFor="project-task-budget">Task budget in USD (optional)</label>
        <input id="project-task-budget" className="pair-input" type="number" min="0" step="any" value={budget} onChange={(event) => setBudget(event.target.value)} />
        <label htmlFor="project-task-steps">Maximum steps (optional)</label>
        <input id="project-task-steps" className="pair-input" type="number" min="1" max="256" step="1" value={maxSteps} onChange={(event) => setMaxSteps(event.target.value)} />
        <button className="btn btn-primary" type="submit">{pending ? "Starting task…" : "Start task"}</button>
      </fieldset>
      {repositories.length === 0 ? <p className="tile-note">Attach a repository before starting a task.</p> : null}
      {error ? <p className="error" role="alert">{error}</p> : null}
    </form>
  </section>;
}

export function ProjectTaskScreen({ transport, projectId, taskId, onNavigate }: {
  transport: Transport | null; projectId: string; taskId: string; onNavigate: (path: string) => void;
}) {
  const [scope, setScope] = useState({ transport, projectId, taskId, generation: 0 });
  if (scope.transport !== transport || scope.projectId !== projectId || scope.taskId !== taskId) {
    setScope({ transport, projectId, taskId, generation: scope.generation + 1 }); return null;
  }
  if (!supportsWorkflow(transport)) return <WorkflowUnavailable />;
  return <ProjectTaskScope key={scope.generation} transport={transport} projectId={projectId} taskId={taskId} onNavigate={onNavigate} />;
}

function ProjectTaskScope({ transport, projectId, taskId, onNavigate }: {
  transport: WorkflowTransport; projectId: string; taskId: string; onNavigate: (path: string) => void;
}) {
  const [task, setTask] = useState<TaskDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState(true);
  const [revision, setRevision] = useState(0);
  const active = useRef(true);
  const inFlight = useRef<Promise<unknown> | null>(null);
  const taskRef = useRef(task);
  taskRef.current = task;
  const reload = () => { if (active.current) setRevision((value) => value + 1); };

  useEffect(() => {
    active.current = true;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const off = transport.onEvent((event) => {
      if (event.type === "task_upsert" && event.task_id === taskId && timer === null) {
        timer = setTimeout(() => { timer = null; reload(); }, 250);
      }
      if (event.type === "output_chunk" && event.session_id === taskRef.current?.session_id
        && typeof event.text === "string" && event.text.length <= 1_048_576
        && Number.isSafeInteger(event.seq) && event.seq >= 0 && Number.isSafeInteger(event.at_ms) && event.at_ms >= 0) {
        setTask((current) => !current || current.output.some((line) => line.seq === event.seq) ? current : {
          ...current, output: [...current.output, { seq: event.seq, text: event.text, at_ms: event.at_ms }].sort((a, b) => a.seq - b.seq).slice(-200),
        });
      }
    });
    return () => { active.current = false; off(); if (timer !== null) clearTimeout(timer); };
  }, [transport, taskId]);

  useEffect(() => {
    let cancelled = false;
    setPending(true); setError(null);
    void transport.projectTask(projectId, taskId).then((value) => {
      if (!cancelled) setTask((current) => {
        if (!current || current.session_id !== value.session_id) return value;
        const output = new Map(value.output.map((line) => [line.seq, line]));
        for (const line of current.output) if (!output.has(line.seq)) output.set(line.seq, line);
        return { ...value, output: [...output.values()].sort((a, b) => a.seq - b.seq).slice(-200) };
      });
    }).catch((cause: unknown) => { if (!cancelled) setError(errorMessage(cause)); })
      .finally(() => { if (!cancelled) setPending(false); });
    return () => { cancelled = true; };
  }, [transport, projectId, taskId, revision]);

  const actions = useMemo(() => {
    async function mutate<T>(operation: () => Promise<T>): Promise<T> {
      if (inFlight.current) throw new Error("A task action is already pending.");
      const request = operation();
      inFlight.current = request;
      try { return await request; } finally { if (inFlight.current === request) inFlight.current = null; }
    }
    return {
      supportsTaskControl: true,
      reviewTask: async (id: string, decision: "approve" | "reject", note?: string) => {
        if (id !== taskId) throw new Error("Task identity changed. Refresh before reviewing.");
        await mutate(() => transport.reviewProjectTask(projectId, id, decision, note));
      },
      revertTask: async (id: string) => {
        if (id !== taskId) throw new Error("Task identity changed. Refresh before reverting.");
        await mutate(() => transport.revertProjectTask(projectId, id));
      },
      startTask: async (_path: string, prompt: string, budget?: number, retryOf?: string) => {
        const previous = taskRef.current;
        if (!previous || retryOf !== taskId || previous.status !== "rejected") throw new Error("Only this rejected project task can be retried.");
        return mutate(() => transport.startProjectTask(projectId, { repo_id: previous.repo_id, prompt, budget_usd: budget, retry_of: retryOf }));
      },
    };
  }, [transport, projectId, taskId]);

  return <div className="view project-task-review">
    <header className="view-head"><h1 className="view-title">Project task</h1><div className="approval-actions">
      <button className="btn" onClick={() => onNavigate(`/p/${encodeURIComponent(projectId)}`)}>Back to project</button>
      <button className="btn" disabled={pending} onClick={reload}>Refresh task</button>
    </div></header>
    {error ? <div className="card error" role="alert"><p>{error}</p>{task ? <p>Showing the last loaded task. Refresh before taking an action.</p> : null}</div> : null}
    {pending ? <p role="status">{task ? "Refreshing task…" : "Loading project task…"}</p> : null}
    {task?.status === "running" ? <section className="card" aria-label="Command approval location">
      <p>Commands awaiting your approval appear in Workspace. The task keeps its project context while you review them.</p>
      <button className="btn" onClick={() => onNavigate("/")}>Open Workspace approvals</button>
    </section> : null}
    {task ? <fieldset className="project-review-content" disabled={pending || !!error}>
      <TaskReviewScreen key={task.id} task={task} transport={actions} onReviewed={reload}
        onOpenTask={(id) => { if (active.current) onNavigate(projectTaskPath(projectId, id)); }} />
    </fieldset> : null}
  </div>;
}
