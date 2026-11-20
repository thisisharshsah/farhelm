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

/**
 * What a session clears without asking. Mirrors `AutoApprove` in Rust.
 *
 * The runner enforces the ceiling: a destructive command is never cleared on
 * its own whatever this says, and only the phone or web app may change it.
 */
export type AutoApprove = "off" | "low" | "medium";

/**
 * `agent` is supervised work. `conversation` and `api` are the budget accounts
 * of a project conversation and of direct gateway calls: real spend, not a
 * live agent.
 */
export type SessionKind = "agent" | "conversation" | "api";

/** Whether a session is agent work, which is what session lists show. */
export function isAgentSession(session: { kind?: SessionKind }): boolean {
  return (session.kind ?? "agent") === "agent";
}

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
  /** Addresses repository-wide settings such as `setRepoAutoApprove`. */
  repo_id: string;
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
  /** The level in force, from the session itself or its repository. */
  auto_approve: AutoApprove;
  /** The repository's default, so the UI can say where the level came from. */
  repo_auto_approve: AutoApprove;
  /**
   * What the session is for. Optional because a runner from before the field
   * sends none, and every session it had was agent work as far as a list goes.
   */
  kind?: SessionKind;
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
 * undone; offering "undo" on either offers to do nothing, which reads as a bug
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
 * diff: a list of twenty tasks would otherwise ship twenty change sets to a
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
   * C10's verdict on the diff. `null` means **not judged**; never render it as
   * a pass. A reassuring line with nothing behind it is worse than no line.
   */
  verify_grade: Grade | null;
  verify_notes: string | null;
  /** Which model judged it. "Opus says concerns" is worth more than "Haiku". */
  verify_model: string | null;
  /** The mode the task was started in (`agent` today). */
  mode: WorkMode;
  /** The model it was asked to use, as named; `null` is the mode's default. */
  model: string | null;
  /** The task on the board this run is an attempt on, if any. */
  work_item_id: string | null;
  decided_via: DecidedVia | null;
  created_at: number;
  updated_at: number;
  decided_at: number | null;
}

export type Grade = "pass" | "concerns" | "fail";

/**
 * What a request asks the model for (ADR 0009). A conversation answers in
 * `ask` or `plan`; a task runs in `agent`, and `review` judges its diff.
 */
export type WorkMode = "ask" | "plan" | "agent" | "review";
export const WORK_MODES: readonly WorkMode[] = ["ask", "plan", "agent", "review"];

/** One mode and the model that answers it unless a request names another. */
export interface ModeView {
  mode: WorkMode;
  /** What people call it: "Ask", "Plan", "Agent", "Review". */
  label: string;
  /** The registry name the mode uses (`think`). */
  model: string;
  /** The exact model behind that name (`gpt-oss-20b`). */
  deployment: string;
}

/** A model a request may name instead of the mode's default. */
export interface ModelChoiceView {
  name: string;
  deployment: string;
  /** A purpose name (`think`) rather than a model's own. */
  alias: boolean;
}

/** `GET /v1/modes`. Both lists are empty on a runner without a registry. */
export interface ModesView {
  modes: ModeView[];
  models: ModelChoiceView[];
}

/**
 * Where a task on the board stands. A person moves it; a run moves it too:
 * starting puts it in progress, a proposed change set puts it in review, an
 * applied one marks it done, and a rejected, failed or undone one sends it
 * back to to do.
 */
export type WorkItemStatus = "backlog" | "todo" | "in_progress" | "review" | "done";
export const WORK_ITEM_STATUSES: readonly WorkItemStatus[] = ["backlog", "todo", "in_progress", "review", "done"];

/** A task on a project's board: planned work that agent runs are attempts on. */
export interface WorkItem {
  id: string;
  project_id: string;
  title: string;
  description: string;
  status: WorkItemStatus;
  /** Where its runs happen; null until chosen. */
  repo_id: string | null;
  /** The discussion it came from, if any. */
  conversation_id: string | null;
  created_at: number;
  updated_at: number;
}

/** A task with its newest run, as a card shows it. */
export interface WorkItemView extends WorkItem {
  latest_run: TaskView | null;
}

export interface WorkItemPage {
  items: WorkItemView[];
  next_cursor: string | null;
}

/** One task with every run made on it, newest first. */
export interface WorkItemDetail extends WorkItemView {
  runs: TaskView[];
}

export interface CreateWorkItemRequest {
  title: string;
  description?: string;
  /** `todo` when absent. */
  status?: WorkItemStatus;
  repo_id?: string | null;
  conversation_id?: string | null;
}

/** Fields left out stay as they are. */
export interface UpdateWorkItemRequest {
  title?: string;
  description?: string;
  status?: WorkItemStatus;
  repo_id?: string;
}

/**
 * Start a run on a task. Everything may be left out: the repository is the
 * task's, the prompt its title and description, the model the Agent default.
 */
export interface StartWorkItemRunRequest {
  repo_id?: string;
  prompt?: string;
  budget_usd?: number;
  max_steps?: number;
  model?: string;
}

export interface WorkItemListOptions extends ProjectListOptions {
  /** Only tasks made from this conversation. */
  conversation?: string;
}

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

export const SEARCH_HIT_KINDS = ["project", "task", "run", "conversation"] as const;
export type SearchHitKind = typeof SEARCH_HIT_KINDS[number];

/** One thing in the local workspace whose text matched a search. */
export interface SearchHit {
  kind: SearchHitKind;
  id: string;
  project_id: string;
  project_name: string;
  /** The name, title or prompt. */
  title: string;
  /** The passage that matched, when the match was not in the title. */
  snippet: string | null;
  /** The task's or run's status word; null for projects and conversations. */
  status: string | null;
  updated_at: number;
}

/** `GET /v1/search`: newest first across every project in the local workspace. */
export interface WorkspaceSearch {
  query: string;
  hits: SearchHit[];
  /** More matched than were returned. */
  truncated: boolean;
}

/** Whether an interrupted run can continue where it stopped (ADR 0004). */
export interface TaskRecovery {
  resumable: boolean;
  /** Why not, in a sentence a reviewer can act on. Null when resumable. */
  reason: string | null;
  /** When recovery settled the run; null for a run that ended on its own. */
  interrupted_at: number | null;
  /** The step a resume continues from; 0 is the branch's base. */
  checkpoint_step: number | null;
}

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
   * How a decision reaches it. `native` is Farhelm's own agent, which has no
   * bridge and no pane to parse: the loop calls the approval queue in-process.
   */
  approvals: "hook" | "prompt" | "native" | "none";
  /** False when nothing is gated, a plain shell, for instance. */
  supervised: boolean;
  /** True when the approval path has been checked against the real binary. */
  verified: boolean;
  note: string;
}

export type RepositoryView = ProjectRepository;

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
   * thing it was woken for in one round trip. No diffs; those are fetched.
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
   * A native agent task changed state. `summary` is the headline; the diff
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
   * failure comes back as an HTTP status on the call itself. Never broadcast:
   * the runner seals it to the device that sent the failing command.
   */
  | { type: "command_error"; message: string };

/* ------------------------------------------------- unified workspace (ADR 0002) */

export type EntityKind =
  | "project"
  | "conversation"
  | "task"
  | "task_run"
  | "document"
  | "artifact"
  | "repo";

export type RelationKind =
  | "mentions"
  | "spawns"
  | "blocks"
  | "documents"
  | "produces"
  | "belongs_to";

export interface Project {
  id: string;
  workspace_id: string;
  name: string;
  description: string;
  budget_cap_usd: number | null;
  created_at: number;
  updated_at: number;
}

/** The runner chooses the local workspace; callers never supply its ID. */
export interface CreateProjectRequest {
  name: string;
  description?: string;
}

export interface ProjectPage {
  projects: Project[];
  next_cursor: string | null;
}

export interface ProjectListOptions {
  after?: string;
  limit?: number;
}

export interface ProjectRepository {
  id: string;
  name: string;
  path: string;
}

export interface ProjectRepositoryPage {
  repositories: ProjectRepository[];
  next_cursor: string | null;
}

export interface AttachProjectRepositoryRequest {
  repo_id: string;
}

/** A Git checkout found on the runner's machine. */
export interface DiscoveredRepository {
  name: string;
  path: string;
}

/** What a look for checkouts found, and where it looked. */
export interface RepositoryDiscovery {
  searched: string[];
  repositories: DiscoveredRepository[];
  /** The bound was reached; more may exist. */
  truncated: boolean;
}

export interface StartProjectTaskRequest {
  repo_id: string;
  prompt: string;
  budget_usd?: number | null;
  max_steps?: number | null;
  retry_of?: string | null;
  /** A registry model or alias for the agent; the Agent mode's default when absent. */
  model?: string | null;
  /** The task this run is an attempt on; the run moves it to in progress. */
  work_item_id?: string | null;
}

export interface ProjectTaskPage {
  tasks: TaskView[];
  next_cursor: string | null;
}

export interface Conversation {
  id: string;
  project_id: string;
  title: string;
  created_at: number;
  updated_at: number;
}

export interface Document {
  id: string;
  project_id: string;
  title: string;
  content: string;
  content_hash: string;
  version: number;
  created_at: number;
  updated_at: number;
}

export interface EntityLink {
  id: string;
  source_type: EntityKind;
  source_id: string;
  target_type: EntityKind;
  target_id: string;
  relation_kind: RelationKind;
  created_at: number;
}
