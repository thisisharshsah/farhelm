/**
 * A task as a thread: what you asked, what the agent did, what it changed,
 * and the decision still owed.
 *
 * The layout follows the coding-agent apps people already use: the request as
 * a message, the work collapsed behind "Worked for…", edited files as a card
 * with per-file counts, and the composer pinned at the bottom. A right rail
 * holds the facts a reviewer checks while reading (cost, steps, the second
 * opinion, where the work happened).
 *
 * Applying a diff stays a human decision whatever the session's auto-approve
 * level says. That level only governs commands while the agent is working.
 */

import { useEffect, useMemo, useRef, useState } from "react";
import {
  agentName,
  since,
  usd,
  type FleetView,
  type RepositoryView,
  type TaskDetail,
  type TaskView,
  type Transport,
} from "@farhelm/client-core";
import { ApprovalCard, AutoApproveControl } from "./Approvals";
import { Icon } from "./Icon";
import { DiffView, RetryButton, SecondOpinion, UndoButton, Verdict } from "./Tasks";
import { OutputTail } from "./views";
import { duration, StatusPill, TASK_STATUS } from "./status";

function message(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause);
}

const FILES_SHOWN = 4;

/* ------------------------------------------------------------- the thread */

export function TaskThread({
  task,
  fleet,
  transport,
  onChanged,
  onOpenTask,
}: {
  task: TaskDetail;
  fleet: FleetView | null;
  transport: Transport | null;
  onChanged: () => void;
  onOpenTask: (id: string) => void;
}) {
  const [showWork, setShowWork] = useState(task.status === "running");
  const [showDiff, setShowDiff] = useState(false);
  const [allFiles, setAllFiles] = useState(false);
  const look = TASK_STATUS[task.status];

  const session = fleet?.sessions.find((item) => item.id === task.session_id) ?? null;
  const approvals = fleet?.pending_approvals.filter((item) => item.session_id === task.session_id) ?? [];
  const live = session?.is_live === true;
  const worked = task.status === "running"
    ? `Working for ${duration(Date.now() - task.created_at)}`
    : `Worked for ${duration(task.updated_at - task.created_at)}`;
  const files = allFiles ? task.changes.files : task.changes.files.slice(0, FILES_SHOWN);

  return (
    <div className="thread-layout">
      <section className="thread" aria-label="Task">
        <header className="thread-head">
          <div className="thread-head-title">
            <span className="thread-crumb">{task.repo_name}</span>
            <h1 title={task.prompt}>{task.prompt}</h1>
          </div>
          <StatusPill look={look} />
          <span className="spacer" />
          {task.changes.files.length > 0 ? (
            <button className="btn btn-small" onClick={() => setShowDiff((open) => !open)} aria-expanded={showDiff}>
              {showDiff ? "Hide changes" : "Review changes"}
            </button>
          ) : null}
        </header>

        <div className="thread-scroll">
          <div className="msg-user">{task.prompt}</div>

          <div className="msg-agent">
            <button
              type="button"
              className="worked-toggle"
              aria-expanded={showWork}
              onClick={() => setShowWork((open) => !open)}
            >
              {worked} · {task.steps} step{task.steps === 1 ? "" : "s"}
              <Icon name="chevron" size={12} className={showWork ? "is-open" : undefined} />
            </button>
            {showWork ? (
              <div className="thread-transcript">
                <OutputTail lines={task.output} agent={session ? agentName(session.agent) : "Agent"} />
              </div>
            ) : null}

            {task.summary ? <p className="agent-text">{task.summary}</p> : null}

            {task.error ? (
              <p className="notice error-text" role="alert">
                <span aria-hidden="true">■</span>
                <span>{task.error}</span>
              </p>
            ) : null}

            {approvals.map((approval) => (
              <ApprovalCard key={approval.id} approval={approval} transport={transport} onDecided={onChanged} />
            ))}

            {task.changes.files.length > 0 ? (
              <section className="work-card" aria-label="Edited files">
                <div className="work-card-head">
                  <Icon name="tasks" size={16} />
                  <b>
                    Edited {task.files_changed} file{task.files_changed === 1 ? "" : "s"}
                  </b>
                  <span className="diff-count-add">+{task.lines_added}</span>
                  <span className="diff-count-remove">−{task.lines_removed}</span>
                  <span className="spacer" />
                  <button className="btn btn-small" onClick={() => setShowDiff((open) => !open)} aria-expanded={showDiff}>
                    {showDiff ? "Hide changes" : "View changes"}
                  </button>
                </div>
                {showDiff ? (
                  <DiffView changes={task.changes} />
                ) : (
                  <ul className="work-files">
                    {files.map((file) => (
                      <li key={file.path}>
                        <span className="work-file-path">{file.path}</span>
                        <span className="diff-count-add">+{file.added}</span>
                        <span className="diff-count-remove">−{file.removed}</span>
                      </li>
                    ))}
                    {task.changes.files.length > FILES_SHOWN && !allFiles ? (
                      <li>
                        <button type="button" className="linkish" onClick={() => setAllFiles(true)}>
                          Show {task.changes.files.length - FILES_SHOWN} more files
                        </button>
                      </li>
                    ) : null}
                  </ul>
                )}
              </section>
            ) : task.status !== "running" ? (
              <p className="tile-note">No files were changed.</p>
            ) : null}

            <SecondOpinion task={task} />
            {task.review_note ? <p className="tile-note">Rejected: “{task.review_note}”</p> : null}

            <div className="review-bar">
              <Verdict task={task} transport={transport} onReviewed={onChanged} />
              <RetryButton task={task} transport={transport} onStarted={onOpenTask} />
              <UndoButton task={task} transport={transport} onUndone={onChanged} />
            </div>
          </div>
        </div>

        <TaskComposer
          key={`${task.id}:${live ? "live" : "settled"}`}
          task={task}
          sessionId={live ? task.session_id : null}
          transport={transport}
          onChanged={onChanged}
          onOpenTask={onOpenTask}
          autoApprove={live && session ? (
            <AutoApproveControl key={session.id} session={session} transport={transport} onChanged={onChanged} compact />
          ) : null}
        />
      </section>

      <aside className="thread-rail" aria-label="Task details">
        <section className="rail-panel">
          <h2>Outputs</h2>
          <ul className="rail-list">
            <li>
              <Icon name="tasks" size={14} />
              <span>Change set</span>
              <span className="spacer" />
              <span className="muted">{task.change_summary || "none"}</span>
            </li>
            <li>
              <Icon name="check" size={14} />
              <span>Second opinion</span>
              <span className="spacer" />
              <span className="muted">
                {task.verify_grade === "pass" ? "no problems" : task.verify_grade ?? "not judged"}
              </span>
            </li>
          </ul>
        </section>

        <section className="rail-panel">
          <h2>Run</h2>
          <div className="mini-tiles">
            <div><span className="mini-label">Cost</span><span className="mini-value">{usd(task.cost_usd)}</span></div>
            <div><span className="mini-label">Steps</span><span className="mini-value">{task.steps}</span></div>
          </div>
          <dl className="facts">
            <dt>Started</dt><dd>{since(task.created_at)}</dd>
            <dt>Updated</dt><dd>{since(task.updated_at)}</dd>
            {task.decided_via ? (<><dt>Decided from</dt><dd>{task.decided_via.replace("_", " ")}</dd></>) : null}
            {session ? (<><dt>Agent</dt><dd>{agentName(session.agent)} on {session.machine_name}</dd></>) : null}
          </dl>
        </section>

        <section className="rail-panel">
          <h2>Source</h2>
          <p className="rail-path" title={task.repo_path}>
            <Icon name="folder" size={14} /> {task.repo_path}
          </p>
        </section>
      </aside>
    </div>
  );
}

/**
 * The bottom box: talk to the running agent, or start the next task here.
 *
 * Keyed by task and liveness at the call site, so a draft never follows you to
 * another task or survives the agent stopping underneath it.
 */
function TaskComposer({
  task,
  sessionId,
  transport,
  onChanged,
  onOpenTask,
  autoApprove,
}: {
  task: TaskDetail;
  sessionId: string | null;
  transport: Transport | null;
  onChanged: () => void;
  onOpenTask: (id: string) => void;
  autoApprove: React.ReactNode;
}) {
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);
  const mounted = useRef(true);
  useEffect(() => () => { mounted.current = false; }, []);

  const followUp = sessionId === null;
  if (followUp && !transport?.supportsTaskControl) return null;

  const submit = async () => {
    const value = text.trim();
    if (!value || inFlight.current || !transport) return;
    inFlight.current = true;
    setBusy(true);
    setError(null);
    try {
      if (sessionId) {
        await transport.instruct(sessionId, value);
        if (!mounted.current) return;
        setText("");
        onChanged();
      } else {
        const next = await transport.startTask(task.repo_path, value);
        if (!mounted.current) return;
        onOpenTask(next.id);
      }
    } catch (cause) {
      if (mounted.current) setError(message(cause));
    } finally {
      inFlight.current = false;
      if (mounted.current) setBusy(false);
    }
  };

  return (
    <form className="composer-dock" onSubmit={(event) => { event.preventDefault(); void submit(); }}>
      <div className="composer-box">
        <textarea
          rows={2}
          value={text}
          onChange={(event) => setText(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
              event.preventDefault();
              void submit();
            }
          }}
          aria-label={followUp ? "Follow-up task" : "Instruction for the agent"}
          placeholder={followUp ? `Start a follow-up task in ${task.repo_name}…` : "Tell the agent…"}
          disabled={busy}
        />
        <div className="composer-bar">
          {autoApprove}
          <span className="spacer" />
          <span className="composer-hint">{followUp ? "Starts a new task · ⌘⏎" : "⌘⏎ to send"}</span>
          <button className="send-button" type="submit" disabled={busy || !text.trim()} aria-label={followUp ? "Start follow-up task" : "Send instruction"}>
            <Icon name="send" size={16} />
          </button>
        </div>
      </div>
      {error ? <p className="notice" role="alert">{error}</p> : null}
    </form>
  );
}

/* --------------------------------------------------------- new task composer */

/** The pre-workspace caches held absolute paths with no runner scope. */
const UNSCOPED_REPO_CACHES = ["farhelm-known-repos", "farhelm-recent-repos", "forge-recent-repos"];

/**
 * "What should we build?": the start of every task.
 *
 * Repositories come from the runner (its registered repos plus the ones its
 * tasks ran in), never from browser storage: a list of paths remembered by
 * this browser is not scoped to a runner and showed one machine's paths while
 * connected to another. A transport change remounts this, which ends any
 * draft and drops a start that completes after the switch.
 */
export function NewTaskComposer(props: {
  transport: Transport | null;
  tasks: TaskView[] | null;
  onStarted: (id: string) => void;
  variant?: "hero" | "page";
}) {
  const [scope, setScope] = useState({ transport: props.transport, generation: 0 });
  if (scope.transport !== props.transport) {
    setScope({ transport: props.transport, generation: scope.generation + 1 });
    return null;
  }
  return <NewTaskForm key={scope.generation} {...props} />;
}

function NewTaskForm({
  transport,
  tasks,
  onStarted,
  variant = "page",
}: {
  transport: Transport | null;
  tasks: TaskView[] | null;
  onStarted: (id: string) => void;
  variant?: "hero" | "page";
}) {
  const [registered, setRegistered] = useState<RepositoryView[]>([]);
  const [repo, setRepo] = useState("");
  const [custom, setCustom] = useState(false);
  const [prompt, setPrompt] = useState("");
  const [budget, setBudget] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);
  const mounted = useRef(true);

  useEffect(() => {
    mounted.current = true;
    for (const key of UNSCOPED_REPO_CACHES) {
      try { localStorage.removeItem(key); }
      catch { /* Restricted storage must not block starting a task. */ }
    }
    return () => { mounted.current = false; };
  }, []);

  useEffect(() => {
    if (!transport || typeof transport.repositories !== "function") return;
    let cancelled = false;
    transport.repositories()
      .then((list) => { if (!cancelled) setRegistered(list); })
      .catch(() => { /* The task history still offers its repositories. */ });
    return () => { cancelled = true; };
  }, [transport]);

  const repos = useMemo(() => {
    const byPath = new Map<string, { name: string; path: string }>();
    for (const item of registered) byPath.set(item.path, { name: item.name, path: item.path });
    for (const task of tasks ?? []) {
      if (!byPath.has(task.repo_path)) byPath.set(task.repo_path, { name: task.repo_name, path: task.repo_path });
    }
    return Array.from(byPath.values());
  }, [registered, tasks]);

  const typing = custom || repos.length === 0;
  const target = typing ? repo : (repos.some((item) => item.path === repo) ? repo : repos[0]?.path ?? "");

  if (!transport?.supportsTaskControl) {
    return (
      <section className="new-task" data-variant={variant} aria-label="New task">
        <h1 className="new-task-title">New task</h1>
        <p className="tile-note">
          Tasks start only from the machine the agent will run on. A paired device
          reviews the diff, which is the decision worth making from a phone, but
          pointing an agent at a directory is a different kind of permission.
        </p>
      </section>
    );
  }

  const submit = async () => {
    const path = target.trim();
    const text = prompt.trim();
    if (!path || !text || inFlight.current) return;
    const cap = budget.trim() ? Number(budget) : undefined;
    if (cap !== undefined && (!Number.isFinite(cap) || cap <= 0)) {
      setError("Enter a positive spend cap in dollars, or leave it empty.");
      return;
    }
    inFlight.current = true;
    setBusy(true);
    setError(null);
    try {
      const started = await transport.startTask(path, text, cap);
      if (!mounted.current) return;
      setPrompt("");
      onStarted(started.id);
    } catch (cause) {
      if (mounted.current) setError(message(cause));
    } finally {
      inFlight.current = false;
      if (mounted.current) setBusy(false);
    }
  };

  return (
    <section className="new-task" data-variant={variant} aria-label="New task">
      <h1 className="new-task-title">What should we build?</h1>
      <p className="new-task-sub">
        The agent drafts in a separate worktree and stops with a diff. Nothing
        reaches your files until you approve it.
      </p>
      <form
        className="composer-box new-task-box"
        onSubmit={(event) => { event.preventDefault(); void submit(); }}
      >
        <textarea
          rows={4}
          value={prompt}
          onChange={(event) => setPrompt(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
              event.preventDefault();
              void submit();
            }
          }}
          aria-label="Task instruction"
          placeholder="Bound the webhook retry backoff at 30 seconds and add a test for it."
          disabled={busy}
        />
        <div className="composer-bar">
          <Icon name="folder" size={14} />
          {typing ? (
            <input
              className="composer-field composer-path"
              aria-label="Repository path"
              value={repo}
              onChange={(event) => setRepo(event.target.value)}
              placeholder="/path/to/repository"
              spellCheck={false}
              autoCapitalize="none"
              autoCorrect="off"
            />
          ) : (
            <select
              className="composer-field"
              aria-label="Repository"
              value={target}
              onChange={(event) => {
                if (event.target.value === "__custom__") { setCustom(true); setRepo(""); }
                else setRepo(event.target.value);
              }}
            >
              {repos.map((item) => <option key={item.path} value={item.path}>{item.name}</option>)}
              <option value="__custom__">Another path…</option>
            </select>
          )}
          {custom && repos.length > 0 ? (
            <button type="button" className="btn btn-quiet btn-small" onClick={() => { setCustom(false); setRepo(""); }}>
              Use a known repository
            </button>
          ) : null}
          <input
            className="composer-field composer-cap"
            aria-label="Spend cap in dollars"
            value={budget}
            onChange={(event) => setBudget(event.target.value)}
            placeholder="Cap $"
            inputMode="decimal"
          />
          <span className="spacer" />
          <button className="btn btn-primary" type="submit" disabled={busy || !prompt.trim() || !target.trim()}>
            {busy ? "Starting…" : "Start task"}
          </button>
        </div>
      </form>
      {error ? <p className="notice" role="alert">{error}</p> : null}
    </section>
  );
}
