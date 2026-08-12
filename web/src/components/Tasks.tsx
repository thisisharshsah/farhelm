/**
 * Tasks: starting the native agent, and reviewing the diff it proposes.
 *
 * This is the screen the rest of the product exists to make possible. Every
 * other view *supervises* — it shows you a command and asks yes or no. This one
 * shows you a change, which is the decision that actually matters, and it has to
 * be readable on a phone held one-handed.
 *
 * # Three decisions the review screen makes
 *
 * **The verdict is at the top and the bottom.** A long diff means scrolling, and
 * a reviewer who has read to the end should not have to scroll back up to act.
 *
 * **Rejecting asks why, approving does not.** The reason is handed to the next
 * attempt verbatim, so it is worth a sentence; an approval speaks for itself.
 *
 * **Line numbers come from the hunk header, not from a counter over all files.**
 * A diff renders the *changed* regions, and numbering them 1..n would be a
 * confident lie about where in the file you are looking.
 */

import { useState } from "react";
import {
  canRevert,
  changeMark,
  changeSummary,
  hunkHeader,
  intraline,
  numberedLines,
  pairedLines,
  since,
  usd,
  type ChangeSet,
  type FileDiff,
  type Hunk,
  type Segment,
  type TaskDetail,
  type TaskStatus,
  type TaskView,
  type Transport,
} from "@relayforge/client-core";

const STATUS_LABEL: Record<TaskStatus, string> = {
  running: "working",
  awaiting_review: "needs review",
  applied: "applied",
  rejected: "rejected",
  no_changes: "no changes",
  failed: "failed",
  reverted: "undone",
};

/** Maps to the same status tokens the session rows use, so colour is consistent. */
const STATUS_TOKEN: Record<TaskStatus, string> = {
  running: "good",
  awaiting_review: "warning",
  applied: "good",
  rejected: "muted",
  no_changes: "muted",
  failed: "critical",
  reverted: "muted",
};

/* --------------------------------------------------------------- diff view */

function HunkView({ hunk }: { hunk: Hunk }) {
  // Numbering and pairing live in `client-core`: both clients render diffs, and
  // neither should own the arithmetic that decides which line you are looking
  // at, or which two lines are versions of each other.
  const lines = numberedLines(hunk);
  const pairs = pairedLines(lines);

  /**
   * Word-level highlighting for a replaced line.
   *
   * Computed per line and memo-free: a hunk is tens of lines, the work is a
   * single pass over tokens, and caching it would cost more in complexity than
   * it saves. `null` — unpaired, or too dissimilar to compare — falls back to
   * the plain text, which is the honest rendering rather than a guess.
   */
  const segmentsFor = (index: number): Segment[] | null => {
    const partner =
      pairs.get(index) ??
      [...pairs].find(([, added]) => added === index)?.[0] ??
      null;
    if (partner === null) return null;

    const isRemoval = lines[index]?.tag === "remove";
    const before = (isRemoval ? lines[index] : lines[partner])?.text ?? "";
    const after = (isRemoval ? lines[partner] : lines[index])?.text ?? "";
    const split = intraline(before, after);
    return split ? (isRemoval ? split.before : split.after) : null;
  };

  return (
    <>
      <div className="diff-hunk-header">{hunkHeader(hunk)}</div>
      {lines.map((line, index) => {
        const segments =
          line.tag === "context" ? null : segmentsFor(index);
        return (
          <div className="diff-line" data-tag={line.tag} key={index}>
            <span className="diff-no" aria-hidden="true">
              {line.oldNo ?? ""}
            </span>
            <span className="diff-no" aria-hidden="true">
              {line.newNo ?? ""}
            </span>
            <span className="diff-mark" aria-hidden="true">
              {line.tag === "add" ? "+" : line.tag === "remove" ? "−" : " "}
            </span>
            <span className="diff-text">
              {segments ? (
                segments.map((segment, at) =>
                  segment.changed ? (
                    <mark className="diff-word" key={at}>
                      {segment.text}
                    </mark>
                  ) : (
                    <span key={at}>{segment.text}</span>
                  ),
                )
              ) : (
                // A blank line still needs height, hence the zero-width space.
                line.text || "\u200b"
              )}
            </span>
          </div>
        );
      })}
    </>
  );
}

/**
 * How many files open expanded before the rest arrive collapsed.
 *
 * A comment here used to promise this and the code opened everything: a
 * forty-file change set dumped thousands of lines into the page, and the
 * reviewer's first act was scrolling to find out how big it was. Collapsed
 * files still state their path and their counts, so the shape of the change is
 * readable in one screen and the detail is one click away.
 */
const EXPANDED_BY_DEFAULT = 3;

function FileDiffView({ file, index }: { file: FileDiff; index: number }) {
  const [open, setOpen] = useState(index < EXPANDED_BY_DEFAULT);

  return (
    <div className="diff-file">
      <button
        type="button"
        className="diff-file-head"
        aria-expanded={open}
        onClick={() => setOpen((value) => !value)}
      >
        <span className="diff-kind" data-kind={file.kind} aria-hidden="true">
          {changeMark(file.kind)}
        </span>
        <span className="diff-path">{file.path}</span>
        <span className="spacer" />
        <span className="diff-count diff-count-add">+{file.added}</span>
        <span className="diff-count diff-count-remove">−{file.removed}</span>
        <span className="diff-chevron" aria-hidden="true">
          {open ? "▾" : "▸"}
        </span>
      </button>

      {open ? (
        file.binary ? (
          <p className="tile-note diff-binary">
            Binary file — not shown. Nothing here can be reviewed on a screen,
            so it is reported rather than rendered.
          </p>
        ) : (
          <div className="diff-body">
            {file.hunks.map((hunk, index) => (
              <HunkView hunk={hunk} key={index} />
            ))}
          </div>
        )
      ) : null}
    </div>
  );
}

export function DiffView({ changes }: { changes: ChangeSet }) {
  if (changes.files.length === 0) {
    return <p className="empty">No files changed.</p>;
  }

  const added = changes.files.reduce((sum, file) => sum + file.added, 0);
  const removed = changes.files.reduce((sum, file) => sum + file.removed, 0);

  return (
    <div className="diff">
      {/* The size of the change, before any of it. A reviewer decides how much
          care this needs from the totals, and previously had to infer them by
          scrolling to the bottom. */}
      <div className="diff-summary">
        <span className="diff-summary-count">{changeSummary(changes)}</span>
        <span className="spacer" />
        <span className="diff-count diff-count-add">+{added}</span>
        <span className="diff-count diff-count-remove">−{removed}</span>
      </div>

      {changes.files.map((file, index) => (
        <FileDiffView file={file} index={index} key={file.path} />
      ))}
    </div>
  );
}

/* ------------------------------------------------------- the second opinion */

/**
 * C10's verdict, above the diff.
 *
 * Deliberately *above*: a reviewer who is going to read the patch anyway
 * benefits from knowing what to look for first, and one who is not should at
 * least see the warning before they tap Apply.
 *
 * A task with no verdict renders nothing at all rather than a reassuring
 * placeholder. "Not judged" and "judged and found fine" are different answers,
 * and a card that blurred them would be actively misleading — the one place in
 * this UI where being silent is the honest option.
 */
function SecondOpinion({ task }: { task: TaskDetail }) {
  if (!task.verify_grade) return null;

  const label =
    task.verify_grade === "pass"
      ? "No problems found"
      : task.verify_grade === "fail"
        ? "This looks wrong"
        : "Worth a closer look";

  return (
    <div className="second-opinion" data-grade={task.verify_grade}>
      <div className="second-opinion-head">
        <span aria-hidden="true">
          {task.verify_grade === "pass" ? "✓" : task.verify_grade === "fail" ? "✗" : "!"}
        </span>
        <b>{label}</b>
        {task.verify_model ? (
          <span className="muted"> · {task.verify_model} read the diff</span>
        ) : null}
      </div>
      {task.verify_notes ? (
        <p className="tile-note">{task.verify_notes}</p>
      ) : null}
    </div>
  );
}

/* ------------------------------------------------------------- review screen */

function Verdict({
  task,
  transport,
  onReviewed,
}: {
  task: TaskDetail;
  transport: Transport | null;
  onReviewed: () => void;
}) {
  const [note, setNote] = useState("");
  const [rejecting, setRejecting] = useState(false);
  const [busy, setBusy] = useState<"approve" | "reject" | null>(null);
  const [error, setError] = useState<string | null>(null);

  const submit = async (decision: "approve" | "reject") => {
    setBusy(decision);
    setError(null);
    try {
      if (!transport) throw new Error("not connected");
      await transport.reviewTask(task.id, decision, note.trim() || undefined);
      onReviewed();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(null);
    }
  };

  if (task.status !== "awaiting_review") return null;

  return (
    <div className="verdict">
      {rejecting ? (
        <>
          <label className="tile-label" htmlFor={`reject-note-${task.id}`}>
            What is wrong with it?
          </label>
          <input
            id={`reject-note-${task.id}`}
            className="pair-input"
            value={note}
            onChange={(event) => setNote(event.target.value)}
            placeholder="This breaks the retry cap…"
            autoFocus
          />
          <p className="tile-note">
            Handed to the next attempt verbatim. It is the only part of a
            rejection the agent gets to read.
          </p>
        </>
      ) : null}

      {error ? <p className="notice error-text">{error}</p> : null}

      <div className="approval-actions">
        {rejecting ? (
          <button className="btn" onClick={() => setRejecting(false)} disabled={!!busy}>
            Back
          </button>
        ) : null}
        <button
          className="btn btn-deny"
          onClick={() => (rejecting ? void submit("reject") : setRejecting(true))}
          disabled={!!busy}
        >
          {busy === "reject" ? "Rejecting…" : rejecting ? "Reject it" : "Reject"}
        </button>
        {!rejecting ? (
          <button
            className="btn btn-approve"
            onClick={() => void submit("approve")}
            disabled={!!busy}
          >
            {busy === "approve" ? "Applying…" : "Apply to disk"}
          </button>
        ) : null}
      </div>
    </div>
  );
}

/**
 * Offer another attempt at a rejected change set.
 *
 * The reason you gave is handed to the agent verbatim, which is the only thing
 * that makes a retry worth more than re-running the original prompt. Saying so
 * on the button matters: without it, "Try again" reads like "do the identical
 * thing and hope", and nobody would press it twice.
 */
function RetryButton({
  task,
  transport,
  onStarted,
}: {
  task: TaskDetail;
  transport: Transport | null;
  onStarted: (id: string) => void;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (task.status !== "rejected") return null;
  if (!transport?.supportsTaskControl) {
    return (
      <p className="tile-note">
        Retry it from the runner's own machine — starting an agent is not
        something a paired device does.
      </p>
    );
  }

  const retry = async () => {
    setBusy(true);
    setError(null);
    try {
      const next = await transport.startTask(
        task.repo_path,
        task.prompt,
        undefined,
        task.id,
      );
      onStarted(next.id);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="verdict">
      <p className="tile-note">
        {task.review_note
          ? "A new attempt gets your reason, what this one did, and the diff you turned down."
          : "A new attempt gets what this one did and the diff you turned down. It was rejected without a reason, so that is all it has to go on."}
      </p>
      {error ? <p className="notice error-text">{error}</p> : null}
      <div className="approval-actions">
        <button
          className="btn btn-approve"
          onClick={() => void retry()}
          disabled={busy}
        >
          {busy ? "Starting…" : "Try again"}
        </button>
      </div>
    </div>
  );
}

/**
 * Undo an applied change set.
 *
 * The one thing that makes "Apply to disk" a comfortable button to press. It is
 * offered plainly rather than buried, and it says what it will do — the runner
 * refuses if anything has moved since, so the promise is real.
 */
function UndoButton({
  task,
  transport,
  onUndone,
}: {
  task: TaskDetail;
  transport: Transport | null;
  onUndone: () => void;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (!canRevert(task.status)) return null;

  const undo = async () => {
    setBusy(true);
    setError(null);
    try {
      if (!transport) throw new Error("not connected");
      await transport.revertTask(task.id);
      onUndone();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="verdict">
      <p className="tile-note">
        Puts back exactly what these {task.files_changed} file
        {task.files_changed === 1 ? "" : "s"} held before. If anything has been
        edited since, nothing is touched and it says so.
      </p>
      {error ? <p className="notice error-text">{error}</p> : null}
      <div className="approval-actions">
        <button className="btn" onClick={() => void undo()} disabled={busy}>
          {busy ? "Undoing…" : "Undo this change"}
        </button>
      </div>
    </div>
  );
}

export function TaskReviewScreen({
  task,
  transport,
  onReviewed,
  onOpenTask,
}: {
  task: TaskDetail;
  transport: Transport | null;
  onReviewed: () => void;
  onOpenTask: (id: string) => void;
}) {
  const settled = task.status !== "running" && task.status !== "awaiting_review";

  return (
    <>
      <section className="card">
        <div className="chart-title">
          <span>{task.repo_name}</span>
          <span className="spacer" />
          <span className="status-chip" data-token={STATUS_TOKEN[task.status]}>
            {STATUS_LABEL[task.status]}
          </span>
        </div>

        <p className="task-prompt">{task.prompt}</p>

        {task.summary ? <p className="task-summary">{task.summary}</p> : null}

        {task.error ? (
          <p className="notice error-text">
            <span aria-hidden="true">■</span>
            <span>{task.error}</span>
          </p>
        ) : null}

        <div className="task-meta">
          <span>{task.change_summary}</span>
          <span>·</span>
          <span>
            {task.steps} step{task.steps === 1 ? "" : "s"}
          </span>
          <span>·</span>
          <span>{usd(task.cost_usd)}</span>
          <span>·</span>
          <span>{since(task.created_at)}</span>
        </div>

        {task.review_note ? (
          <p className="tile-note">Rejected: “{task.review_note}”</p>
        ) : null}

        <SecondOpinion task={task} />

        {/* The verdict sits at the top as well as the bottom: a short diff
            should not need a scroll to act on. */}
        <Verdict task={task} transport={transport} onReviewed={onReviewed} />
        <RetryButton task={task} transport={transport} onStarted={onOpenTask} />
        <UndoButton task={task} transport={transport} onUndone={onReviewed} />
      </section>

      {task.status === "running" ? (
        <section className="card">
          <div className="chart-title">Working</div>
          <div className="output">
            {task.output.map((line) => (
              <div className="output-line" key={line.seq}>
                {line.text}
              </div>
            ))}
          </div>
        </section>
      ) : null}

      {task.changes.files.length > 0 ? (
        <section className="card">
          <div className="chart-title">
            <span>Proposed change</span>
            <span className="spacer" />
            <span className="muted">{task.change_summary}</span>
          </div>
          <DiffView changes={task.changes} />
          {!settled ? (
            <Verdict task={task} transport={transport} onReviewed={onReviewed} />
          ) : null}
        </section>
      ) : null}
    </>
  );
}

/* --------------------------------------------------------------- task list */

export function TaskRow({
  task,
  onOpen,
}: {
  task: TaskView;
  onOpen: () => void;
}) {
  return (
    <button type="button" className="session task-row" onClick={onOpen}>
      <div className="session-head">
        <span className="session-name">{task.repo_name}</span>
        <span className="spacer" />
        <span className="status-chip" data-token={STATUS_TOKEN[task.status]}>
          {STATUS_LABEL[task.status]}
        </span>
      </div>
      <div className="task-row-prompt">{task.prompt}</div>
      <div className="session-line">
        <span>{task.change_summary}</span>
        <span>·</span>
        <span>{usd(task.cost_usd)}</span>
        <span>·</span>
        <span>{since(task.updated_at)}</span>
      </div>
    </button>
  );
}

export function TaskListScreen({
  tasks,
  onOpen,
  onNewTask,
  transport,
}: {
  tasks: TaskView[];
  onOpen: (id: string) => void;
  onNewTask: () => void;
  transport: Transport | null;
}) {
  const waiting = tasks.filter((task) => task.status === "awaiting_review");

  return (
    <>
      {waiting.length > 0 ? (
        <p className="tile-note">
          {waiting.length} change set{waiting.length === 1 ? "" : "s"} waiting on
          you.
        </p>
      ) : null}

      {tasks.length === 0 ? (
        <div className="empty-state">
          <p className="empty-title">No tasks yet.</p>
          {transport?.supportsTaskControl ? (
            <>
              <p className="tile-note">
                Describe a change and RelayForge works on it here, then hands you
                a diff to approve. Nothing reaches your files until you say so.
              </p>
              <button className="btn btn-approve" onClick={onNewTask}>
                New task
              </button>
            </>
          ) : (
            <p className="tile-note">
              Tasks start on the runner's own machine. Once one is running you
              can review its diff from anywhere.
            </p>
          )}
        </div>
      ) : (
        <>
          {transport?.supportsTaskControl ? (
            <div className="row-actions">
              <button className="btn btn-approve" onClick={onNewTask}>
                New task
              </button>
            </div>
          ) : null}
          {tasks.map((task) => (
            <TaskRow key={task.id} task={task} onOpen={() => onOpen(task.id)} />
          ))}
        </>
      )}
    </>
  );
}

/* ---------------------------------------------------------------- new task */

const RECENT_KEY = "forge-recent-repos";

function recentRepos(): string[] {
  try {
    const raw = JSON.parse(localStorage.getItem(RECENT_KEY) ?? "[]") as unknown;
    return Array.isArray(raw)
      ? raw.filter((value): value is string => typeof value === "string")
      : [];
  } catch {
    return [];
  }
}

function rememberRepo(path: string) {
  const next = [path, ...recentRepos().filter((p) => p !== path)].slice(0, 8);
  localStorage.setItem(RECENT_KEY, JSON.stringify(next));
}

export function NewTask({
  transport,
  onStarted,
  onCancel,
}: {
  transport: Transport | null;
  onStarted: (taskId: string) => void;
  onCancel: () => void;
}) {
  const [repo, setRepo] = useState(() => recentRepos()[0] ?? "");
  const [prompt, setPrompt] = useState("");
  const [budget, setBudget] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (!transport?.supportsTaskControl) {
    return (
      <section className="card" aria-label="New task">
        <div className="chart-title">New task</div>
        <p className="tile-note">
          Only from the machine the agent will run on. A paired device reviews
          the diff — which is the decision worth making from a phone — but
          pointing an agent at a directory is a different kind of permission.
        </p>
        <div className="approval-actions">
          <button className="btn" onClick={onCancel}>
            Close
          </button>
        </div>
      </section>
    );
  }

  const submit = async () => {
    const path = repo.trim();
    const text = prompt.trim();
    if (!path || !text) return;
    setBusy(true);
    setError(null);
    try {
      const parsed = Number.parseFloat(budget);
      const task = await transport.startTask(
        path,
        text,
        Number.isFinite(parsed) && parsed > 0 ? parsed : undefined,
      );
      rememberRepo(path);
      onStarted(task.id);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="card" aria-label="New task">
      <div className="chart-title">New task</div>

      <label className="tile-label" htmlFor="new-task-repo">
        Repository
      </label>
      <input
        id="new-task-repo"
        className="pair-input"
        value={repo}
        onChange={(event) => setRepo(event.target.value)}
        placeholder="/Users/you/code/payments-api"
        list="forge-known-repos"
        spellCheck={false}
        autoCapitalize="none"
        autoCorrect="off"
      />
      <datalist id="forge-known-repos">
        {recentRepos().map((path) => (
          <option key={path} value={path} />
        ))}
      </datalist>

      <label
        className="tile-label"
        htmlFor="new-task-prompt"
        style={{ marginTop: "0.75rem" }}
      >
        What should it do?
      </label>
      <textarea
        id="new-task-prompt"
        className="pair-input task-input"
        value={prompt}
        onChange={(event) => setPrompt(event.target.value)}
        placeholder="Bound the webhook retry backoff at 30 seconds and add a test for it."
        rows={4}
      />
      <p className="tile-note">
        The agent reads the repo, proposes edits, and stops. Nothing is written
        until you approve the diff.
      </p>

      <label
        className="tile-label"
        htmlFor="new-task-budget"
        style={{ marginTop: "0.75rem" }}
      >
        Cap (optional)
      </label>
      <input
        id="new-task-budget"
        className="pair-input"
        value={budget}
        onChange={(event) => setBudget(event.target.value)}
        placeholder="1.00"
        inputMode="decimal"
      />
      <p className="tile-note">
        Dollars. The task stops at the cap and hands you whatever it had — the
        repo's own cap still applies on top.
      </p>

      {error ? <p className="notice error-text">{error}</p> : null}

      <div className="approval-actions">
        <button className="btn" onClick={onCancel} disabled={busy}>
          Cancel
        </button>
        <button
          className="btn btn-approve"
          onClick={() => void submit()}
          disabled={busy || !repo.trim() || !prompt.trim()}
        >
          {busy ? "Starting…" : "Start"}
        </button>
      </div>
    </section>
  );
}
