/**
 * Client for the runner's HTTP API, and the types every client shares.
 *
 * The types mirror the Rust DTOs in `crates/forge-runner/src/api.rs`. They are
 * hand-written rather than generated because there are a dozen of them and the
 * wire contract is in the design doc — worth revisiting with a schema generator
 * if the relay protocol grows.
 *
 * The HTTP path only works where the runner is directly reachable: the same
 * machine, or the same network. Off that network everything goes through the
 * relay instead — see `transport.ts`. Both are behind one interface so no screen
 * has to know which it is using.
 */

export type SessionStatus =
  | "running"
  | "awaiting_approval"
  | "paused"
  | "done"
  | "dead";

export type PlanStepStatus = "todo" | "active" | "done" | "skipped" | "failed";

export type Risk = "low" | "medium" | "destructive";
export type Decision = "approved" | "denied" | "timeout";
export type DecidedVia = "watch" | "phone" | "web" | "auto_policy";
export type BudgetState = "ok" | "warn" | "stop";

export interface BudgetView {
  cap_usd: number | null;
  spent_usd: number;
  pct: number | null;
  state: BudgetState;
}

export interface PlanProgress {
  settled: number;
  total: number;
  current_ordinal: number | null;
  current_title: string | null;
}

export interface SessionView {
  id: string;
  repo_name: string;
  machine_name: string;
  agent: string;
  status: SessionStatus;
  is_live: boolean;
  plan: PlanProgress | null;
  budget: BudgetView;
  started_at: number;
  ended_at: number | null;
  awaiting_approval_id: string | null;
}

export interface PlanStepView {
  ordinal: number;
  title: string;
  status: PlanStepStatus;
  checkpoint_sha: string | null;
}

export interface ApprovalView {
  id: string;
  session_id: string;
  tool: string;
  payload: string;
  risk: Risk;
  decision: Decision | null;
  decided_via: DecidedVia | null;
  requested_at: number;
  decided_at: number | null;
  repo_name: string;
  allows_watch_decision: boolean;
  budget: BudgetView;
}

export interface OutputLine {
  seq: number;
  text: string;
  at_ms: number;
}

/* ------------------------------------------------- native agent tasks */

export type TaskStatus =
  | "running"
  | "awaiting_review"
  | "applied"
  | "rejected"
  | "no_changes"
  | "failed"
  | "reverted";

/**
 * Whether an applied change set is still on disk and could be taken off again.
 *
 * Only `applied`. A rejected task never landed and a reverted one is already
 * undone — offering "undo" on either offers to do nothing, which reads as a bug
 * the first time somebody presses it.
 */
export function canRevert(status: TaskStatus): boolean {
  return status === "applied";
}

export type ChangeKind = "added" | "modified" | "deleted";
export type DiffTag = "context" | "add" | "remove";

export interface DiffLine {
  tag: DiffTag;
  text: string;
}

export interface Hunk {
  old_start: number;
  old_len: number;
  new_start: number;
  new_len: number;
  lines: DiffLine[];
}

export interface FileDiff {
  /** Repo-relative, forward slashes on every platform. */
  path: string;
  kind: ChangeKind;
  added: number;
  removed: number;
  hunks: Hunk[];
  /** True when the file is not text. `hunks` is empty. */
  binary: boolean;
}

export interface ChangeSet {
  files: FileDiff[];
}

/**
 * A task in a list. Mirrors `TaskView` in Rust, and deliberately carries no
 * diff — a list of twenty tasks would otherwise ship twenty change sets to a
 * phone showing one line each.
 */
export interface TaskView {
  id: string;
  session_id: string;
  repo_id: string;
  repo_name: string;
  /** Absolute path on the runner's machine. What a retry is started against. */
  repo_path: string;
  prompt: string;
  status: TaskStatus;
  /** The agent's closing message. */
  summary: string;
  files_changed: number;
  lines_added: number;
  lines_removed: number;
  /** `3 files, +42 −17`. */
  change_summary: string;
  steps: number;
  cost_usd: number;
  error: string | null;
  review_note: string | null;
  /**
   * C10's verdict on the diff. `null` means **not judged** — never render it as
   * a pass. A reassuring line with nothing behind it is worse than no line.
   */
  verify_grade: Grade | null;
  verify_notes: string | null;
  /** Which model judged it. "Opus says concerns" is worth more than "Haiku". */
  verify_model: string | null;
  decided_via: DecidedVia | null;
  created_at: number;
  updated_at: number;
  decided_at: number | null;
}

export type Grade = "pass" | "concerns" | "fail";

/** True when a grade should make a reviewer slow down. Not-judged counts. */
export function warrantsAttention(grade: Grade | null): boolean {
  return grade !== "pass";
}

/** One task with the diff a reviewer decides on. */
export interface TaskDetail extends TaskView {
  changes: ChangeSet;
  /** The patch as text, for copying out or piping to `git apply`. */
  patch: string;
  output: OutputLine[];
}

export type TaskReview = "approve" | "reject";

/** True when this status means the task is done changing on its own. */
export function isTaskSettled(status: TaskStatus): boolean {
  return status !== "running" && status !== "awaiting_review";
}

/** One agent this machine knows how to start. Mirrors `AgentView` in Rust. */
export interface AgentView {
  id: string;
  name: string;
  binary: string;
  /** Whether the binary is on this machine's PATH right now. */
  installed: boolean;
  /**
   * How a decision reaches it. `native` is RelayForge's own agent, which has no
   * bridge and no pane to parse — the loop calls the approval queue in-process.
   */
  approvals: "hook" | "prompt" | "native" | "none";
  /** False when nothing is gated — a plain shell, for instance. */
  supervised: boolean;
  /** True when the approval path has been checked against the real binary. */
  verified: boolean;
  note: string;
}

export interface SessionDetail extends SessionView {
  steps: PlanStepView[];
  output: OutputLine[];
  pending_approval: ApprovalView | null;
}

export interface FleetView {
  sessions: SessionView[];
  pending_approvals: ApprovalView[];
  /**
   * Change sets waiting on a human, oldest first. Carried here rather than
   * behind a second request so a phone that has just been woken can render the
   * thing it was woken for in one round trip. No diffs — those are fetched.
   */
  tasks_awaiting_review: TaskView[];
  today_usd: number;
  cache_hit_ratio: number | null;
}

export interface TierSlice {
  tier: string;
  usd: number;
  share: number;
}

export interface SpendBucket {
  at_ms: number;
  usd: number;
}

export interface DashboardView {
  session_id: string;
  repo_name: string;
  calls: number;
  total_usd: number;
  cache_hit_ratio: number | null;
  by_tier: TierSlice[];
  avoided_calls: number;
  spend_series: SpendBucket[];
  budget: BudgetView;
}

/** Server-sent events from `/v1/events`. */
export type ServerEvent =
  | { type: "session_upsert"; session_id: string }
  | ({ type: "output_chunk"; session_id: string } & OutputLine)
  | { type: "approval_request"; approval: Omit<ApprovalView, "repo_name" | "allows_watch_decision" | "budget"> }
  | {
      type: "approval_decision";
      approval_id: string;
      session_id: string;
      decision: Decision;
    }
  | { type: "budget_alert"; session_id: string; pct: number; hard_stop: boolean }
  /**
   * A native agent task changed state. `summary` is the headline — the diff
   * itself is fetched, because this goes to every connected device on every
   * state change and a change set can be megabytes.
   */
  | {
      type: "task_upsert";
      task_id: string;
      session_id: string;
      status: TaskStatus;
      summary: string;
    }
  /**
   * A command this device sent was refused. Relay-only: over loopback the same
   * failure comes back as an HTTP status on the call itself. Never broadcast —
   * the runner seals it to the device that sent the failing command.
   */
  | { type: "command_error"; message: string };

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

/**
 * How long to wait for the runner before giving up on a request.
 *
 * Every call here is a sub-millisecond read against a local SQLite file, so any
 * real answer arrives immediately. The wait is not for a slow runner, it is for
 * a runner that **is not there**: a TCP connect to an unreachable host on your
 * own subnet does not fail fast, it hangs for the better part of a minute, and
 * for all that time a screen shows a spinner and the user has no idea whether
 * the address is wrong or the daemon is down. Ten seconds is long enough to be
 * certain and short enough to say so.
 */
const REQUEST_TIMEOUT_MS = 10_000;

async function request<T>(
  baseUrl: string,
  path: string,
  init?: RequestInit,
): Promise<T> {
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), REQUEST_TIMEOUT_MS);

  let response: Response;
  try {
    response = await fetch(`${baseUrl}${path}`, {
      ...init,
      signal: abort.signal,
      headers: { "content-type": "application/json", ...init?.headers },
    });
  } catch (cause) {
    // Status 0 is "never reached the server", which the callers already render
    // as a connection problem rather than an API error.
    throw new ApiError(
      abort.signal.aborted
        ? `no answer from ${baseUrl || "the runner"} within ${
            REQUEST_TIMEOUT_MS / 1000
          }s — is it running, and is the address right?`
        : cause instanceof Error
          ? cause.message
          : String(cause),
      0,
    );
  } finally {
    clearTimeout(timer);
  }

  if (!response.ok) {
    // The API always answers with `{ error }`; fall back to the status text if
    // something upstream (a proxy) got there first.
    let message = response.statusText;
    try {
      const body = (await response.json()) as { error?: string };
      if (body.error) message = body.error;
    } catch {
      /* non-JSON error body */
    }
    throw new ApiError(message, response.status);
  }

  return (await response.json()) as T;
}

export type RunnerApi = ReturnType<typeof createRunnerApi>;

/**
 * Bind the API to a runner.
 *
 * `baseUrl` is empty for the PWA, which is served by the runner itself and can
 * use same-origin paths. React Native has no origin, so it always passes one.
 */
export function createRunnerApi(baseUrl = "") {
  const base = baseUrl.replace(/\/$/, "");
  return {
    baseUrl: base,
    fleet: () => request<FleetView>(base, "/v1/fleet"),
    session: (id: string) => request<SessionDetail>(base, `/v1/sessions/${id}`),
    dashboard: (id: string, sinceMs?: number) =>
      request<DashboardView>(
        base,
        `/v1/sessions/${id}/dashboard${sinceMs ? `?since_ms=${sinceMs}` : ""}`,
      ),
    instruct: (id: string, text: string) =>
      request<{ delivered: boolean }>(base, `/v1/sessions/${id}/instruction`, {
        method: "POST",
        body: JSON.stringify({ text }),
      }),
    planControl: (id: string, action: "pause" | "resume" | "skip") =>
      request<PlanStepView[]>(base, `/v1/sessions/${id}/plan`, {
        method: "POST",
        body: JSON.stringify({ action }),
      }),
    decide: (id: string, decision: Decision, via: DecidedVia) =>
      request<ApprovalView>(base, `/v1/approvals/${id}/decision`, {
        method: "POST",
        body: JSON.stringify({ decision, via }),
      }),
    /** Every native agent task, newest first. */
    tasks: () => request<TaskView[]>(base, "/v1/tasks"),
    task: (id: string) => request<TaskDetail>(base, `/v1/tasks/${id}`),
    /**
     * Start the native agent on a repo. Returns as soon as the row exists —
     * the loop runs detached, and progress arrives over the event stream.
     */
    startTask: (
      repoPath: string,
      prompt: string,
      budgetUsd?: number,
      retryOf?: string,
    ) =>
      request<TaskView>(base, "/v1/tasks", {
        method: "POST",
        body: JSON.stringify({
          repo_path: repoPath,
          prompt,
          budget_usd: budgetUsd ?? null,
          retry_of: retryOf ?? null,
        }),
      }),
    /** Approve a change set onto disk, or reject it with a reason. */
    reviewTask: (
      id: string,
      decision: TaskReview,
      via: DecidedVia,
      note?: string,
    ) =>
      request<TaskView>(base, `/v1/tasks/${id}/review`, {
        method: "POST",
        body: JSON.stringify({ decision, via, note: note ?? null }),
      }),
    /** Take an applied change set back off disk. */
    revertTask: (id: string, via: DecidedVia) =>
      request<TaskView>(base, `/v1/tasks/${id}/revert`, {
        method: "POST",
        body: JSON.stringify({ via }),
      }),
    /** What this machine can start, and what it has not got installed. */
    agents: () => request<AgentView[]>(base, "/v1/agents"),
    /** Start an agent in a repo. */
    startSession: (repoPath: string, agent: string) =>
      request<SessionView>(base, "/v1/sessions", {
        method: "POST",
        body: JSON.stringify({ repo_path: repoPath, agent }),
      }),
    stopSession: (id: string) =>
      request<SessionView>(base, `/v1/sessions/${id}/stop`, { method: "POST" }),
    /** Mint a pairing offer. The QR payload, fetched rather than photographed. */
    pairingOffer: () =>
      request<import("./crypto.ts").PairingOffer>(base, "/v1/pair/offer", {
        method: "POST",
      }),
  };
}
