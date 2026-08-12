/**
 * How a client reaches the runner.
 *
 * Two shapes, one interface:
 *
 * - **Loopback** — plain HTTP to the runner, with a live stream on top. What you
 *   get on the same machine or the same network. No pairing, no crypto, because
 *   there is no untrusted hop. The stream is platform-specific (`EventSource` on
 *   the web, polling in React Native), so [`HttpTransport`] takes it as a
 *   parameter rather than assuming one exists.
 * - **Relay** — a WebSocket to the relay, everything sealed to the runner's
 *   public key. What you get on cellular.
 *
 * The relay has no request/response: a client sends a `snapshot` command and the
 * answer arrives as another envelope. [`RelayTransport`] hides that behind the
 * same promise-shaped calls the HTTP client offers, so no screen has to know
 * which one it is talking to. That symmetry is the only reason the web app's
 * views, written against loopback HTTP, work unchanged over the relay.
 *
 * Three snapshot types travel that way — the fleet, one session, and one
 * session's cost dashboard — plus a task list and a task's diff. What stays
 * loopback-only is *starting* things: a session, or an agent task. Deciding
 * about work that already exists is what a paired device is for.
 */

import type {
  AgentView,
  DashboardView,
  Decision,
  SessionView,
  FleetView,
  PlanStepView,
  RunnerApi,
  ServerEvent,
  SessionDetail,
  TaskDetail,
  TaskReview,
  TaskView,
} from "./api.ts";
import { ApiError } from "./api.ts";
import { Identity, type Envelope, type Pairing } from "./crypto.ts";

export type ConnectionState = "connecting" | "open" | "closed";

export interface Transport {
  readonly kind: "loopback" | "relay";
  /**
   * True when the cost dashboard can be fetched.
   *
   * Both transports now support it. Kept as a capability rather than deleted
   * because a future transport (a read-only share link, say) may not, and a
   * screen that assumes it would render an empty chart rather than saying why.
   */
  readonly supportsDashboard: boolean;
  /**
   * True when sessions can be started and stopped.
   *
   * Loopback only, deliberately. Starting an agent is a bigger capability than
   * answering one: it picks a directory on someone's machine and runs a process
   * in it. The design deferred "start a session from the phone" (A6) for exactly
   * that reason, and nothing has changed — a paired device supervises work that
   * already exists.
   */
  readonly supportsSessionControl: boolean;

  /**
   * True when a native agent task can be *started* here.
   *
   * Loopback only, for the same reason as `supportsSessionControl`: starting a
   * task points an agent at a directory on someone's machine. **Reviewing** one
   * is available everywhere, and is the point — a diff is exactly the thing
   * worth deciding on from a phone.
   */
  readonly supportsTaskControl: boolean;

  fleet(): Promise<FleetView>;
  session(id: string): Promise<SessionDetail>;
  agents(): Promise<AgentView[]>;
  startSession(repoPath: string, agent: string): Promise<SessionView>;
  stopSession(id: string): Promise<void>;
  /** `sinceMs` bounds the window; omit for everything. */
  dashboard(id: string, sinceMs?: number): Promise<DashboardView>;
  decide(approvalId: string, decision: Decision): Promise<void>;
  instruct(sessionId: string, text: string): Promise<void>;
  planControl(
    sessionId: string,
    action: "pause" | "resume" | "skip",
  ): Promise<PlanStepView[] | void>;

  tasks(): Promise<TaskView[]>;
  task(id: string): Promise<TaskDetail>;
  startTask(
    repoPath: string,
    prompt: string,
    budgetUsd?: number,
    /** A rejected task to try again, with its reason handed to the agent. */
    retryOf?: string,
  ): Promise<TaskView>;
  reviewTask(id: string, decision: TaskReview, note?: string): Promise<void>;
  /** Take an applied change set back off disk. Refuses if anything moved. */
  revertTask(id: string): Promise<void>;

  /** Subscribe to live events. Returns an unsubscribe function. */
  onEvent(listener: (event: ServerEvent) => void): () => void;
  onConnectionChange(listener: (state: ConnectionState) => void): () => void;
  close(): void;
}

/* ------------------------------------------------------------------- loopback */

/**
 * A live stream of runner events, however this platform gets one.
 *
 * Returns a teardown function. `onState` reports the stream's health, which is
 * what the "reconnecting…" indicator reads.
 */
export type EventStream = (handlers: {
  onEvent: (event: ServerEvent) => void;
  onState: (state: ConnectionState) => void;
}) => () => void;

/** The runner over plain HTTP. */
export class HttpTransport implements Transport {
  readonly kind = "loopback" as const;
  readonly supportsDashboard = true;
  readonly supportsSessionControl = true;
  readonly supportsTaskControl = true;

  private stop: (() => void) | null = null;
  private readonly eventListeners = new Set<(event: ServerEvent) => void>();
  private readonly stateListeners = new Set<(state: ConnectionState) => void>();

  constructor(
    private readonly api: RunnerApi,
    stream: EventStream,
    /**
     * The surface a decision came from. The runner cannot infer it here — there
     * is no paired device to look up — so an unpaired client asserts it. This is
     * exactly why the D3 rule is *also* enforced per registered device kind over
     * the relay, where a client cannot choose its own answer.
     */
    private readonly via: "phone" | "web" = "web",
  ) {
    this.stop = stream({
      onEvent: (event) => {
        for (const listener of this.eventListeners) listener(event);
      },
      onState: (state) => {
        for (const listener of this.stateListeners) listener(state);
      },
    });
  }

  fleet = () => this.api.fleet();
  session = (id: string) => this.api.session(id);
  dashboard = (id: string, sinceMs?: number) =>
    this.api.dashboard(id, sinceMs);
  agents = () => this.api.agents();
  startSession = (repoPath: string, agent: string) =>
    this.api.startSession(repoPath, agent);
  stopSession = async (id: string) => {
    await this.api.stopSession(id);
  };
  decide = async (approvalId: string, decision: Decision) => {
    await this.api.decide(approvalId, decision, this.via);
  };
  instruct = async (sessionId: string, text: string) => {
    await this.api.instruct(sessionId, text);
  };
  planControl = (sessionId: string, action: "pause" | "resume" | "skip") =>
    this.api.planControl(sessionId, action);

  tasks = () => this.api.tasks();
  task = (id: string) => this.api.task(id);
  startTask = (
    repoPath: string,
    prompt: string,
    budgetUsd?: number,
    retryOf?: string,
  ) => this.api.startTask(repoPath, prompt, budgetUsd, retryOf);
  reviewTask = async (id: string, decision: TaskReview, note?: string) => {
    await this.api.reviewTask(id, decision, this.via, note);
  };
  revertTask = async (id: string) => {
    await this.api.revertTask(id, this.via);
  };

  onEvent(listener: (event: ServerEvent) => void) {
    this.eventListeners.add(listener);
    return () => {
      this.eventListeners.delete(listener);
    };
  }

  onConnectionChange(listener: (state: ConnectionState) => void) {
    this.stateListeners.add(listener);
    return () => {
      this.stateListeners.delete(listener);
    };
  }

  close() {
    this.stop?.();
    this.stop = null;
  }
}

/* ---------------------------------------------------------------------- relay */

/** Commands the runner accepts. Mirrors `forge_runner::commands::Command`. */
export type Command =
  | { type: "snapshot" }
  | { type: "session_snapshot"; session_id: string }
  | {
      type: "dashboard_snapshot";
      session_id: string;
      since_ms: number | null;
    }
  | { type: "decide"; approval_id: string; decision: Decision }
  | { type: "instruct"; session_id: string; text: string }
  | {
      type: "plan_control";
      session_id: string;
      action: "pause" | "resume" | "skip";
    }
  | { type: "task_snapshot"; task_id: string }
  | { type: "task_list" }
  | { type: "revert_task"; task_id: string }
  | {
      type: "review_task";
      task_id: string;
      decision: TaskReview;
      note: string | null;
    }
  | { type: "start_session"; repo_path: string; agent: string | null }
  | { type: "stop_session"; session_id: string }
  | {
      type: "start_task";
      repo_path: string;
      prompt: string;
      budget_usd: number | null;
      retry_of: string | null;
    }
  | { type: "agent_list" };

/**
 * Does this reply look like a session?
 *
 * The relay has no request/response pairing, so a waiting promise claims a
 * reply by *shape*. `repo_name` plus `status` is the narrowest pair that a
 * session has and no other reply on this socket does — a session detail adds
 * `steps`, which is why this deliberately does not check for it.
 */
function isSessionView(value: unknown): boolean {
  return (
    typeof value === "object" &&
    value !== null &&
    "repo_name" in value &&
    "status" in value &&
    !("steps" in value)
  );
}

/** How long to wait for a snapshot before giving up on it. */
const REQUEST_TIMEOUT_MS = 10_000;
const MIN_BACKOFF_MS = 1_000;
const MAX_BACKOFF_MS = 30_000;

export class RelayTransport implements Transport {
  readonly kind = "relay" as const;
  readonly supportsDashboard = true;
  /**
   * Starting work from a signed-in device is supported (A6).
   *
   * This was `false`, and the reason was sound at the time: a device on the
   * relay was whoever held a keypair photographed from a QR code, and starting
   * an agent picks a directory on someone's machine and runs a process in it.
   *
   * With accounts, the asker is a registered device belonging to a named person
   * in an organisation, revocable from the web app within fifteen minutes. That
   * is a strong enough answer to "who started this" to drive a fleet from a
   * phone. The destructive-command rule is untouched — `rm -rf` still raises an
   * approval and that approval is still phone-only.
   */
  readonly supportsSessionControl = true;
  readonly supportsTaskControl = true;

  private socket: WebSocket | null = null;
  private identity: Identity;
  private backoff = MIN_BACKOFF_MS;
  private closed = false;

  private readonly eventListeners = new Set<(event: ServerEvent) => void>();
  private readonly stateListeners = new Set<(state: ConnectionState) => void>();
  /** Snapshot requests waiting for their answer. */
  private pending: Array<{
    match: (value: unknown) => boolean;
    resolve: (value: never) => void;
    reject: (reason: Error) => void;
  }> = [];

  constructor(
    private readonly pairing: Pairing,
    /**
     * Fetches a fresh relay seat, when this deployment has a control plane.
     *
     * Called on **every** connect, not once at construction: a seat lives
     * fifteen minutes and a phone in a pocket reconnects for days. Absent on an
     * ungated relay, which is still how a single-user self-hosted deployment
     * works.
     */
    private readonly seat?: () => Promise<string>,
  ) {
    this.identity = Identity.fromSecret(pairing.secret);
    void this.connect();
  }

  private async connect() {
    if (this.closed) return;
    this.emitState("connecting");

    let query = "";
    if (this.seat) {
      try {
        const token = await this.seat();
        query = token ? `?token=${encodeURIComponent(token)}` : "";
      } catch {
        // No seat, no point dialling: the relay would refuse and the retry
        // would look like a network problem rather than an expired session.
        this.emitState("closed");
        this.scheduleReconnect();
        return;
      }
      if (this.closed) return;
    }

    const url = `${this.pairing.relayUrl.replace(/\/$/, "")}/v1/channel/${this.pairing.channel}${query}`;
    const socket = new WebSocket(url);
    this.socket = socket;

    socket.onopen = () => {
      this.backoff = MIN_BACKOFF_MS;
      this.emitState("open");
    };
    socket.onclose = () => {
      this.emitState("closed");
      this.scheduleReconnect();
    };
    socket.onerror = () => socket.close();
    socket.onmessage = (message) => this.receive(message.data as string);
  }

  private scheduleReconnect() {
    if (this.closed) return;
    const delay = this.backoff;
    this.backoff = Math.min(this.backoff * 2, MAX_BACKOFF_MS);
    setTimeout(() => void this.connect(), delay);
  }

  private emitState(state: ConnectionState) {
    for (const listener of this.stateListeners) listener(state);
  }

  private receive(raw: string) {
    let envelope: Envelope;
    try {
      envelope = JSON.parse(raw) as Envelope;
    } catch {
      return;
    }

    let payload: unknown;
    try {
      payload = this.identity.openJson(this.pairing.runnerPublicKey, envelope);
    } catch {
      // Envelopes for *other* paired devices ride the same channel and simply
      // do not open. That is the isolation working, not an error.
      return;
    }

    // A pending snapshot claims it first; anything else is a live event.
    const index = this.pending.findIndex((request) => request.match(payload));
    if (index >= 0) {
      const [request] = this.pending.splice(index, 1);
      request!.resolve(payload as never);
      return;
    }

    for (const listener of this.eventListeners) {
      listener(payload as ServerEvent);
    }
  }

  private send(command: Command) {
    if (this.socket?.readyState !== 1 /* OPEN */) {
      throw new ApiError("not connected to the relay", 0);
    }
    const envelope = this.identity.sealJson(
      this.pairing.channel,
      this.pairing.deviceId,
      this.pairing.runnerPublicKey,
      command,
    );
    this.socket.send(JSON.stringify(envelope));
  }

  /** Send a command and wait for the reply that matches `match`. */
  private request<T>(
    command: Command,
    match: (value: unknown) => boolean,
  ): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending = this.pending.filter((entry) => entry.reject !== settle);
        reject(new ApiError("the runner did not answer", 504));
      }, REQUEST_TIMEOUT_MS);

      const settle = (reason: Error) => {
        clearTimeout(timer);
        reject(reason);
      };

      this.pending.push({
        match,
        resolve: ((value: T) => {
          clearTimeout(timer);
          resolve(value);
        }) as (value: never) => void,
        reject: settle,
      });

      try {
        this.send(command);
      } catch (cause) {
        settle(cause as Error);
      }
    });
  }

  fleet(): Promise<FleetView> {
    return this.request<FleetView>(
      { type: "snapshot" },
      (value) =>
        typeof value === "object" &&
        value !== null &&
        "sessions" in value &&
        "pending_approvals" in value,
    );
  }

  session(id: string): Promise<SessionDetail> {
    return this.request<SessionDetail>(
      { type: "session_snapshot", session_id: id },
      (value) =>
        typeof value === "object" &&
        value !== null &&
        "steps" in value &&
        (value as SessionDetail).id === id,
    );
  }

  /**
   * The third snapshot type.
   *
   * Matched on `session_id` **and** a dashboard-only field, for the same reason
   * `session()` is: a session detail and a dashboard both carry `session_id`,
   * and a matcher that stopped there would hand one promise the other's payload.
   */
  dashboard(id: string, sinceMs?: number): Promise<DashboardView> {
    return this.request<DashboardView>(
      {
        type: "dashboard_snapshot",
        session_id: id,
        since_ms: sinceMs ?? null,
      },
      (value) =>
        typeof value === "object" &&
        value !== null &&
        "by_tier" in value &&
        "spend_series" in value &&
        (value as DashboardView).session_id === id,
    );
  }

  /**
   * Which agents the *runner* can drive.
   *
   * Answered by the runner, not assumed here: "installed" is a property of that
   * machine, and two runners in one fleet legitimately differ.
   */
  agents(): Promise<AgentView[]> {
    return this.request<{ agents: AgentView[] }>(
      { type: "agent_list" },
      (value) =>
        typeof value === "object" &&
        value !== null &&
        "agents" in value &&
        Array.isArray((value as { agents: unknown }).agents),
    ).then((reply) => reply.agents);
  }

  startSession(repoPath: string, agent: string): Promise<SessionView> {
    return this.request<SessionView>(
      { type: "start_session", repo_path: repoPath, agent: agent || null },
      isSessionView,
    );
  }

  async stopSession(id: string): Promise<void> {
    // Awaited rather than fire-and-forget: stopping is the one control action
    // whose *failure* the user needs to see immediately — a session that is
    // still running after you pressed Stop is worth knowing about now.
    await this.request<SessionView>(
      { type: "stop_session", session_id: id },
      (value) => isSessionView(value) && (value as SessionView).id === id,
    );
  }

  /**
   * Mutating commands are fire-and-forget: the relay has no acknowledgement, and
   * the change comes back as the event it produced. A *refusal* does come back,
   * as a `command_error` event — see `onEvent`.
   */
  async decide(approvalId: string, decision: Decision) {
    this.send({ type: "decide", approval_id: approvalId, decision });
  }

  async instruct(sessionId: string, text: string) {
    this.send({ type: "instruct", session_id: sessionId, text });
  }

  async planControl(sessionId: string, action: "pause" | "resume" | "skip") {
    this.send({ type: "plan_control", session_id: sessionId, action });
  }

  tasks(): Promise<TaskView[]> {
    return this.request<{ tasks: TaskView[] }>(
      { type: "task_list" },
      (value) =>
        typeof value === "object" &&
        value !== null &&
        "tasks" in value &&
        Array.isArray((value as { tasks: unknown }).tasks),
    ).then((reply) => reply.tasks);
  }

  task(id: string): Promise<TaskDetail> {
    return this.request<TaskDetail>(
      { type: "task_snapshot", task_id: id },
      (value) =>
        typeof value === "object" &&
        value !== null &&
        "changes" in value &&
        (value as TaskDetail).id === id,
    );
  }

  startTask(
    repoPath: string,
    prompt: string,
    budgetUsd?: number,
    retryOf?: string,
  ): Promise<TaskView> {
    return this.request<TaskView>(
      {
        type: "start_task",
        repo_path: repoPath,
        prompt,
        budget_usd: budgetUsd ?? null,
        retry_of: retryOf ?? null,
      },
      (value) =>
        typeof value === "object" &&
        value !== null &&
        "change_summary" in value &&
        "status" in value,
    );
  }

  /**
   * Reviewing *is* available over the relay — it is the whole reason the review
   * screen exists. Fire-and-forget like every other mutating command; a refusal
   * (a watch, an already-decided task) comes back as a `command_error` event.
   */
  async reviewTask(id: string, decision: TaskReview, note?: string) {
    this.send({
      type: "review_task",
      task_id: id,
      decision,
      note: note ?? null,
    });
  }

  /**
   * Undoing works from a phone for the same reason approving does: the runner
   * kept both sides of every file, so this writes back only what the agent
   * replaced — and refuses outright if anything has moved since.
   */
  async revertTask(id: string) {
    this.send({ type: "revert_task", task_id: id });
  }

  onEvent(listener: (event: ServerEvent) => void) {
    this.eventListeners.add(listener);
    return () => {
      this.eventListeners.delete(listener);
    };
  }

  onConnectionChange(listener: (state: ConnectionState) => void) {
    this.stateListeners.add(listener);
    return () => {
      this.stateListeners.delete(listener);
    };
  }

  close() {
    this.closed = true;
    this.socket?.close();
    this.socket = null;
  }
}
