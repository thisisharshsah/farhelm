import {
  parseModesView, parseProject, parseProjectPage, parseProjectRepository,
  parseProjectRepositoryPage, parseProjectTaskPage, parseTaskDetail, parseTaskRecovery, parseTaskView, parseWorkspaceSearch,
  parseRepositoryDiscovery, parseWorkItemDetail, parseWorkItemPage, parseWorkItemView,
} from "./projects.ts";
import {
  parseChatDetail, parseChatReply, parseProjectChatPage,
  type CreateProjectChatRequest, type SendChatMessageRequest,
} from "./chat.ts";

/**
 * Client for the runner's HTTP API, and the types every client shares.
 *
 * The types mirror the Rust DTOs in `crates/farhelm-runner/src/api.rs`. They are
 * hand-written rather than generated because there are a dozen of them and the
 * wire contract is in the design doc; worth revisiting with a schema generator
 * if the relay protocol grows.
 *
 * The HTTP path only works where the runner is directly reachable: the same
 * machine, or the same network. Off that network everything goes through the
 * relay instead (see `transport.ts`). Both are behind one interface so no screen
 * has to know which it is using.
 */

import type {
  AgentView, ApprovalView, AutoApprove, CreateProjectRequest, CreateWorkItemRequest, DashboardView, DecidedVia,
  Decision, FleetView, PlanStepView, ProjectListOptions, SessionDetail, SessionView,
  StartProjectTaskRequest, StartWorkItemRunRequest, TaskDetail, TaskReview, TaskView,
  UpdateWorkItemRequest, WorkItemListOptions,
} from "./contracts.ts";

export * from "./contracts.ts";


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

/**
 * How a request reaches a runner with no HTTP route to it: a signed-in device
 * sends it as a message over the relay and gets the answer back.
 */
export type RunnerCall = (method: string, path: string, body?: unknown) => Promise<unknown>;

async function request<T>(
  baseUrl: string | RunnerCall,
  path: string,
  init?: RequestInit,
): Promise<T> {
  if (typeof baseUrl === "function") {
    const body = typeof init?.body === "string" ? (JSON.parse(init.body) as unknown) : undefined;
    return (await baseUrl(init?.method ?? "GET", path, body)) as T;
  }

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
    // A change that timed out may still have been applied: the runner can be
    // slow (a machine deep in swap) rather than gone. Saying it failed invites
    // a second submit of something that already happened.
    const changes = (init?.method ?? "GET").toUpperCase() !== "GET";
    throw new ApiError(
      abort.signal.aborted
        ? changes
          ? `no answer from ${baseUrl || "the runner"} within ${
              REQUEST_TIMEOUT_MS / 1000
            }s. It may still have done this; refresh to check before trying again.`
          : `no answer from ${baseUrl || "the runner"} within ${
              REQUEST_TIMEOUT_MS / 1000
            }s. Is it running, and is the address right?`
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
export function createRunnerApi(baseUrl: string | RunnerCall = "") {
  const base = typeof baseUrl === "string" ? baseUrl.replace(/\/$/, "") : baseUrl;
  const projectPath = (id: string) => `/v1/projects/${encodeURIComponent(id)}`;
  const pageQuery = ({ after, limit }: ProjectListOptions = {}) => {
    const query = new URLSearchParams();
    if (after !== undefined) query.set("after", after);
    if (limit !== undefined) query.set("limit", String(limit));
    const encoded = query.toString();
    return encoded ? `?${encoded}` : "";
  };
  return {
    baseUrl: typeof base === "string" ? base : "",
    /** Local runner metadata, newest IDs first. */
    projects: async ({ after, limit }: ProjectListOptions = {}) => {
      const query = new URLSearchParams();
      if (after !== undefined) query.set("after", after);
      if (limit !== undefined) query.set("limit", String(limit));
      const encodedQuery = query.toString();
      const suffix = encodedQuery ? `?${encodedQuery}` : "";
      return parseProjectPage(await request<unknown>(base, `/v1/projects${suffix}`));
    },
    project: async (id: string) => {
      const project = parseProject(await request<unknown>(base, `/v1/projects/${encodeURIComponent(id)}`));
      if (project.id !== id) throw new Error("The runner returned a different project.");
      return project;
    },
    createProject: async (input: CreateProjectRequest) =>
      parseProject(await request<unknown>(base, "/v1/projects", {
        method: "POST",
        body: JSON.stringify({
          name: input.name,
          ...(input.description !== undefined ? { description: input.description } : {}),
        }),
      })),
    projectConversations: async (id: string, options?: ProjectListOptions) => {
      const page = parseProjectChatPage(await request<unknown>(base, `${projectPath(id)}/conversations${pageQuery(options)}`));
      if (page.conversations.some((chat) => chat.project_id !== id)) throw new Error("The runner returned conversations from a different project.");
      return page;
    },
    createProjectConversation: async (id: string, input: CreateProjectChatRequest) => {
      // The runner answers 201 with the new conversation's detail (no messages
      // yet), not the bare conversation.
      const chat = parseChatDetail(await request<unknown>(base, `${projectPath(id)}/conversations`, {
        method: "POST", body: JSON.stringify({ repo_id: input.repo_id, title: input.title,
          ...(input.budget_usd !== undefined ? { budget_usd: input.budget_usd } : {}) }),
      })).conversation;
      if (chat.project_id !== id || chat.repo_id !== input.repo_id) throw new Error("The runner returned a conversation for a different project or repository.");
      return chat;
    },
    projectConversation: async (id: string, conversationId: string) => {
      const detail = parseChatDetail(await request<unknown>(base, `${projectPath(id)}/conversations/${encodeURIComponent(conversationId)}`));
      if (detail.conversation.project_id !== id || detail.conversation.id !== conversationId) throw new Error("The runner returned a different conversation.");
      return detail;
    },
    sendProjectMessage: async (id: string, conversationId: string, input: SendChatMessageRequest) => {
      const reply = parseChatReply(await request<unknown>(base, `${projectPath(id)}/conversations/${encodeURIComponent(conversationId)}/messages`, {
        method: "POST", body: JSON.stringify({ content: input.content, request_id: input.request_id,
          ...(input.mode ? { mode: input.mode } : {}), ...(input.model ? { model: input.model } : {}) }),
      }));
      if (reply.detail.conversation.project_id !== id || reply.detail.conversation.id !== conversationId
        || reply.turn.request_id !== input.request_id) throw new Error("The runner returned a different conversation or message request.");
      return reply;
    },
    projectWorkItems: async (id: string, options?: WorkItemListOptions) => {
      const query = pageQuery(options);
      const filter = options?.conversation ? `${query ? "&" : "?"}conversation=${encodeURIComponent(options.conversation)}` : "";
      const page = parseWorkItemPage(await request<unknown>(base, `${projectPath(id)}/work-items${query}${filter}`));
      if (page.items.some((item) => item.project_id !== id)) throw new Error("The runner returned tasks from a different project.");
      return page;
    },
    createProjectWorkItem: async (id: string, input: CreateWorkItemRequest) => {
      const item = parseWorkItemView(await request<unknown>(base, `${projectPath(id)}/work-items`, {
        method: "POST", body: JSON.stringify({ title: input.title, description: input.description ?? "",
          ...(input.status ? { status: input.status } : {}), repo_id: input.repo_id ?? null,
          conversation_id: input.conversation_id ?? null }),
      }));
      if (item.project_id !== id) throw new Error("The runner returned a task for a different project.");
      return item;
    },
    projectWorkItem: async (id: string, itemId: string) => {
      const item = parseWorkItemDetail(await request<unknown>(base, `${projectPath(id)}/work-items/${encodeURIComponent(itemId)}`));
      if (item.project_id !== id || item.id !== itemId) throw new Error("The runner returned a different task.");
      return item;
    },
    updateProjectWorkItem: async (id: string, itemId: string, input: UpdateWorkItemRequest) => {
      const item = parseWorkItemDetail(await request<unknown>(base, `${projectPath(id)}/work-items/${encodeURIComponent(itemId)}`, {
        method: "PATCH", body: JSON.stringify(input),
      }));
      if (item.project_id !== id || item.id !== itemId) throw new Error("The runner returned a different task.");
      return item;
    },
    startWorkItemRun: async (id: string, itemId: string, input: StartWorkItemRunRequest) => {
      const run = parseTaskView(await request<unknown>(base, `${projectPath(id)}/work-items/${encodeURIComponent(itemId)}/runs`, {
        method: "POST", body: JSON.stringify(input),
      }));
      if (run.work_item_id !== itemId) throw new Error("The runner returned a run for a different task.");
      return run;
    },
    /** An explicit look for checkouts on the runner's machine; registers nothing. */
    discoverProjectRepositories: async (id: string, directory?: string) => {
      const query = directory ? `?directory=${encodeURIComponent(directory)}` : "";
      return parseRepositoryDiscovery(await request<unknown>(base, `${projectPath(id)}/repo-discovery${query}`));
    },
    /** Add a checkout by its folder, registering it on the runner if needed. */
    addProjectRepository: async (id: string, path: string) =>
      parseProjectRepository(await request<unknown>(base, `${projectPath(id)}/repos/add`, {
        method: "POST", body: JSON.stringify({ path }),
      })),
    projectRepoCandidates: async (id: string, options?: ProjectListOptions) =>
      parseProjectRepositoryPage(await request<unknown>(base, `${projectPath(id)}/repo-candidates${pageQuery(options)}`)),
    projectRepositories: async (id: string, options?: ProjectListOptions) =>
      parseProjectRepositoryPage(await request<unknown>(base, `${projectPath(id)}/repos${pageQuery(options)}`)),
    attachProjectRepository: async (id: string, repoId: string) => {
      const repo = parseProjectRepository(await request<unknown>(base, `${projectPath(id)}/repos`, {
        method: "POST", body: JSON.stringify({ repo_id: repoId }),
      }));
      if (repo.id !== repoId) throw new Error("The runner returned a different repository.");
      return repo;
    },
    projectTasks: async (id: string, options?: ProjectListOptions) =>
      parseProjectTaskPage(await request<unknown>(base, `${projectPath(id)}/tasks${pageQuery(options)}`)),
    startProjectTask: async (id: string, input: StartProjectTaskRequest) => {
      const task = parseTaskView(await request<unknown>(base, `${projectPath(id)}/tasks`, {
        method: "POST",
        body: JSON.stringify({ repo_id: input.repo_id, prompt: input.prompt,
          budget_usd: input.budget_usd ?? null, max_steps: input.max_steps ?? null, retry_of: input.retry_of ?? null,
          ...(input.model ? { model: input.model } : {}),
          ...(input.work_item_id ? { work_item_id: input.work_item_id } : {}) }),
      }));
      if (task.repo_id !== input.repo_id) throw new Error("The runner returned a task for a different repository.");
      return task;
    },
    projectTask: async (id: string, taskId: string) => {
      const task = parseTaskDetail(await request<unknown>(base, `${projectPath(id)}/tasks/${encodeURIComponent(taskId)}`));
      if (task.id !== taskId) throw new Error("The runner returned a different task.");
      return task;
    },
    reviewProjectTask: async (id: string, taskId: string, decision: TaskReview, via: DecidedVia, note?: string) => {
      const task = parseTaskView(await request<unknown>(base, `${projectPath(id)}/tasks/${encodeURIComponent(taskId)}/review`, {
        method: "POST", body: JSON.stringify({ decision, via, note: note ?? null }),
      }));
      if (task.id !== taskId) throw new Error("The runner returned a different task.");
      return task;
    },
    searchWorkspace: async (query: string, limit?: number) => {
      const params = new URLSearchParams({ q: query });
      if (limit !== undefined) params.set("limit", String(limit));
      return parseWorkspaceSearch(await request<unknown>(base, `/v1/search?${params.toString()}`));
    },
    projectTaskRecovery: async (id: string, taskId: string) =>
      parseTaskRecovery(await request<unknown>(base, `${projectPath(id)}/tasks/${encodeURIComponent(taskId)}/recovery`)),
    resumeProjectTask: async (id: string, taskId: string) => {
      const task = parseTaskView(await request<unknown>(base, `${projectPath(id)}/tasks/${encodeURIComponent(taskId)}/resume`, {
        method: "POST",
      }));
      if (task.id !== taskId) throw new Error("The runner returned a different task.");
      return task;
    },
    revertProjectTask: async (id: string, taskId: string, via: DecidedVia) => {
      const task = parseTaskView(await request<unknown>(base, `${projectPath(id)}/tasks/${encodeURIComponent(taskId)}/revert`, {
        method: "POST", body: JSON.stringify({ via }),
      }));
      if (task.id !== taskId) throw new Error("The runner returned a different task.");
      return task;
    },
    fleet: () => request<FleetView>(base, "/v1/fleet"),
    repositories: async () => parseProjectRepositoryPage({
      repositories: await request<unknown>(base, "/v1/repos"), next_cursor: null,
    }).repositories,
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
    setAutoApprove: (id: string, level: AutoApprove) =>
      request<SessionView>(base, `/v1/sessions/${id}/auto-approve`, {
        method: "POST",
        body: JSON.stringify({ level }),
      }),
    /** The default every new session in a repository starts with. */
    setRepoAutoApprove: (repoId: string, level: AutoApprove) =>
      request<{ repo_id: string; auto_approve: AutoApprove }>(
        base,
        `/v1/repos/${repoId}/auto-approve`,
        { method: "POST", body: JSON.stringify({ level }) },
      ),
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
     * Start the native agent on a repo. Returns as soon as the row exists:
     * the loop runs detached, and progress arrives over the event stream.
     */
    startTask: (
      repoPath: string,
      prompt: string,
      budgetUsd?: number,
      retryOf?: string,
      model?: string,
    ) =>
      request<TaskView>(base, "/v1/tasks", {
        method: "POST",
        body: JSON.stringify({
          repo_path: repoPath,
          prompt,
          budget_usd: budgetUsd ?? null,
          retry_of: retryOf ?? null,
          model: model ?? null,
        }),
      }),
    /** Each work mode's default model, and every name a request may choose. */
    modes: async () => parseModesView(await request<unknown>(base, "/v1/modes")),
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
