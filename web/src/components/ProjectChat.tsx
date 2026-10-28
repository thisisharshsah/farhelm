/**
 * Project conversations: the discussion half of discussion → task → review.
 *
 * A conversation belongs to one of the project's attached repositories. A
 * message is claimed with a request id before it is answered: the reply is
 * composed on the runner after the request returns, so the pane polls the
 * conversation until the turn settles. There is no chat event to wait on.
 *
 * Turn states are shown as they are, never smoothed over:
 * - pending: the runner has the message and is composing a reply;
 * - failed: the reason is shown inline (with no model provider configured,
 *   every turn fails, and the pane says so rather than looking idle);
 * - interrupted: the runner restarted mid-reply. Sending again uses a new
 *   request id; reusing the old one would replay, not retry.
 *
 * "Start as task" turns an assistant reply into a project task. It opens the
 * prompt for editing first, because starting an agent is a bigger step than
 * replying to one.
 */

import { useEffect, useRef, useState } from "react";
import {
  since,
  type ChatDetail,
  type ChatMessage,
  type ProjectChat as Conversation,
  type ProjectRepository,
  type TaskView,
  type Transport,
} from "@farhelm/client-core";
import { Icon } from "./Icon";

type ChatTransport = Transport & Required<Pick<Transport,
  "projectConversations" | "createProjectConversation" | "projectConversation" | "sendProjectMessage" | "startProjectTask">>;

export function supportsProjectChat(transport: Transport | null): transport is ChatTransport {
  return transport?.kind === "loopback" && transport.supportsProjectChat === true
    && [transport.projectConversations, transport.createProjectConversation, transport.projectConversation,
      transport.sendProjectMessage, transport.startProjectTask].every((method) => typeof method === "function");
}

function message(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause);
}

function requestId(): string {
  return typeof crypto !== "undefined" && "randomUUID" in crypto
    ? crypto.randomUUID()
    : `req-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
}

/** How often a pending reply is re-read, and when the pane stops waiting. */
const POLL_MS = 1_500;
const POLL_LIMIT_MS = 3 * 60_000;

export function ProjectChat({
  transport,
  projectId,
  repositories,
  onTaskStarted,
}: {
  transport: Transport | null;
  projectId: string;
  repositories: ProjectRepository[];
  onTaskStarted: (task: TaskView) => void;
}) {
  if (!supportsProjectChat(transport)) {
    return (
      <section className="card" aria-label="Project conversations">
        <div className="chart-title"><h2>Conversations</h2></div>
        <p className="tile-note">Conversations need a direct connection to a runner that supports them.</p>
      </section>
    );
  }
  return (
    <ChatScope transport={transport} projectId={projectId} repositories={repositories} onTaskStarted={onTaskStarted} />
  );
}

function ChatScope({ transport, projectId, repositories, onTaskStarted }: {
  transport: ChatTransport;
  projectId: string;
  repositories: ProjectRepository[];
  onTaskStarted: (task: TaskView) => void;
}) {
  const [list, setList] = useState<Conversation[] | null>(null);
  const [listError, setListError] = useState<string | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [revision, setRevision] = useState(0);

  useEffect(() => {
    let cancelled = false;
    transport.projectConversations(projectId, { limit: 50 })
      .then((page) => {
        if (cancelled) return;
        setList(page.conversations);
        setListError(null);
        setSelected((current) => current ?? page.conversations[0]?.id ?? null);
      })
      .catch((cause) => { if (!cancelled) setListError(message(cause)); });
    return () => { cancelled = true; };
  }, [transport, projectId, revision]);

  const current = list?.find((item) => item.id === selected) ?? null;

  return (
    <section className="card project-chat" aria-label="Project conversations">
      <div className="chart-title">
        <h2>Conversations</h2>
        <button className="btn btn-small" onClick={() => setRevision((value) => value + 1)}>Refresh</button>
      </div>
      {listError ? <p className="error" role="alert">{listError}</p> : null}
      <div className="project-chat-layout">
        <nav className="project-chat-list" aria-label="Conversations">
          {list === null && !listError ? <p role="status" className="tile-note">Loading conversations…</p> : null}
          {list?.length === 0 ? <p className="tile-note">No conversations yet.</p> : null}
          {list?.map((item) => (
            <button
              key={item.id}
              className={`side-thread${item.id === selected ? " is-current" : ""}`}
              aria-current={item.id === selected ? "page" : undefined}
              onClick={() => setSelected(item.id)}
            >
              <span className="side-item-label">{item.title}</span>
              <span className="muted">{since(item.updated_at)}</span>
            </button>
          ))}
          <NewConversation
            transport={transport}
            projectId={projectId}
            repositories={repositories}
            onCreated={(created) => {
              setList((items) => [created, ...(items ?? []).filter((item) => item.id !== created.id)]);
              setSelected(created.id);
            }}
          />
        </nav>
        {current ? (
          <ConversationPane
            key={current.id}
            transport={transport}
            projectId={projectId}
            conversation={current}
            repository={repositories.find((repo) => repo.id === current.repo_id) ?? null}
            onTaskStarted={onTaskStarted}
          />
        ) : (
          <p className="tile-note project-chat-empty">
            Start a conversation to talk a change through before handing it to an agent.
          </p>
        )}
      </div>
    </section>
  );
}

function NewConversation({ transport, projectId, repositories, onCreated }: {
  transport: ChatTransport;
  projectId: string;
  repositories: ProjectRepository[];
  onCreated: (conversation: Conversation) => void;
}) {
  const [title, setTitle] = useState("");
  const [repoId, setRepoId] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);
  const target = repositories.some((repo) => repo.id === repoId) ? repoId : repositories[0]?.id ?? "";

  if (repositories.length === 0) {
    return <p className="tile-note">Attach a repository to this project to start a conversation.</p>;
  }

  const create = async () => {
    const name = title.trim();
    if (!name || !target || inFlight.current) return;
    inFlight.current = true;
    setBusy(true);
    setError(null);
    try {
      const created = await transport.createProjectConversation(projectId, { repo_id: target, title: name });
      setTitle("");
      onCreated(created);
    } catch (cause) {
      setError(message(cause));
    } finally {
      inFlight.current = false;
      setBusy(false);
    }
  };

  return (
    <form className="project-chat-new" onSubmit={(event) => { event.preventDefault(); void create(); }}>
      <label htmlFor={`chat-title-${projectId}`} className="tile-label">New conversation</label>
      <input
        id={`chat-title-${projectId}`}
        className="pair-input"
        value={title}
        onChange={(event) => setTitle(event.target.value)}
        placeholder="What do you want to discuss?"
        disabled={busy}
      />
      {repositories.length > 1 ? (
        <select className="pair-input" aria-label="Conversation repository" value={target} onChange={(event) => setRepoId(event.target.value)} disabled={busy}>
          {repositories.map((repo) => <option key={repo.id} value={repo.id}>{repo.name}</option>)}
        </select>
      ) : null}
      <button className="btn btn-small" type="submit" disabled={busy || !title.trim()}>
        <Icon name="plus" size={14} /> {busy ? "Starting…" : "Start"}
      </button>
      {error ? <p className="error" role="alert">{error}</p> : null}
    </form>
  );
}

function ConversationPane({ transport, projectId, conversation, repository, onTaskStarted }: {
  transport: ChatTransport;
  projectId: string;
  conversation: Conversation;
  repository: ProjectRepository | null;
  onTaskStarted: (task: TaskView) => void;
}) {
  const [detail, setDetail] = useState<ChatDetail | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [text, setText] = useState("");
  const [sending, setSending] = useState(false);
  const [sendError, setSendError] = useState<string | null>(null);
  const [waitedOut, setWaitedOut] = useState(false);
  const [revision, setRevision] = useState(0);
  const inFlight = useRef(false);
  const alive = useRef(true);
  useEffect(() => () => { alive.current = false; }, []);

  // Load, then keep re-reading while a reply is pending. Bounded: a turn that
  // stays pending for minutes is reported, not polled for ever.
  useEffect(() => {
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const startedAt = Date.now();
    const load = () => {
      transport.projectConversation(projectId, conversation.id)
        .then((next) => {
          if (cancelled) return;
          setDetail(next);
          setLoadError(null);
          if (next.latest_turn?.status === "pending") {
            if (Date.now() - startedAt < POLL_LIMIT_MS) timer = setTimeout(load, POLL_MS);
            else setWaitedOut(true);
          }
        })
        .catch((cause) => { if (!cancelled) setLoadError(message(cause)); });
    };
    setWaitedOut(false);
    load();
    return () => { cancelled = true; if (timer !== null) clearTimeout(timer); };
  }, [transport, projectId, conversation.id, revision]);

  const turn = detail?.latest_turn;
  const pending = turn?.status === "pending";
  const lastUser = [...(detail?.messages ?? [])].reverse().find((item) => item.role === "user") ?? null;

  const send = async (content: string) => {
    const value = content.trim();
    if (!value || inFlight.current || pending) return;
    inFlight.current = true;
    setSending(true);
    setSendError(null);
    try {
      // A fresh id for every deliberate send, including a resend after an
      // interruption: the runner replays a reused id instead of answering it.
      const reply = await transport.sendProjectMessage(projectId, conversation.id, { content: value, request_id: requestId() });
      if (!alive.current) return;
      setDetail(reply.detail);
      setText("");
      setRevision((current) => current + 1);
    } catch (cause) {
      if (alive.current) setSendError(message(cause));
    } finally {
      inFlight.current = false;
      if (alive.current) setSending(false);
    }
  };

  return (
    <div className="project-chat-pane">
      <div className="project-chat-head">
        <b>{conversation.title}</b>
        <span className="muted">{repository?.name ?? "repository not attached"}</span>
      </div>

      <div className="project-chat-messages" aria-live="polite">
        {detail === null && !loadError ? <p role="status" className="tile-note">Loading…</p> : null}
        {loadError ? <p className="error" role="alert">{loadError}</p> : null}
        {detail?.messages.length === 0 ? <p className="tile-note">No messages yet.</p> : null}
        {detail?.messages.map((item) => (
          <ChatLine
            key={item.id}
            item={item}
            transport={transport}
            projectId={projectId}
            repoId={conversation.repo_id}
            canStart={repository !== null}
            onTaskStarted={onTaskStarted}
          />
        ))}
        {pending && !waitedOut ? (
          <p className="working" role="status"><span className="working-dot" aria-hidden="true" />Thinking…</p>
        ) : null}
        {pending && waitedOut ? (
          <p className="notice" role="status">
            The reply has been pending for several minutes. It may still arrive.
            <button className="btn btn-small" onClick={() => setRevision((value) => value + 1)}>Check again</button>
          </p>
        ) : null}
        {turn?.status === "failed" ? (
          <p className="notice error-text" role="alert">
            <span aria-hidden="true">■</span>
            <span>No reply: {turn.error ?? "the runner did not say why"}</span>
          </p>
        ) : null}
        {turn?.status === "interrupted" ? (
          <p className="notice" role="alert">
            The runner restarted before it replied.
            {lastUser ? (
              <button className="btn btn-small" disabled={sending} onClick={() => void send(lastUser.content)}>
                Send again
              </button>
            ) : null}
          </p>
        ) : null}
      </div>

      <form className="composer-box" onSubmit={(event) => { event.preventDefault(); void send(text); }}>
        <textarea
          rows={2}
          value={text}
          onChange={(event) => setText(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
              event.preventDefault();
              void send(text);
            }
          }}
          aria-label="Message"
          placeholder={pending ? "Waiting for the reply…" : "Discuss the change…"}
          disabled={sending}
        />
        <div className="composer-bar">
          <span className="composer-hint">{pending ? "One reply at a time" : "⌘⏎ to send"}</span>
          <span className="spacer" />
          <button className="send-button" type="submit" aria-label="Send message" disabled={sending || pending || !text.trim()}>
            <Icon name="send" size={16} />
          </button>
        </div>
      </form>
      {sendError ? <p className="notice" role="alert">{sendError}</p> : null}
    </div>
  );
}

function ChatLine({ item, transport, projectId, repoId, canStart, onTaskStarted }: {
  item: ChatMessage;
  transport: ChatTransport;
  projectId: string;
  repoId: string;
  canStart: boolean;
  onTaskStarted: (task: TaskView) => void;
}) {
  const [drafting, setDrafting] = useState(false);
  const [prompt, setPrompt] = useState(item.content);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);

  if (item.role === "user") return <div className="msg-user">{item.content}</div>;

  const start = async () => {
    const value = prompt.trim();
    if (!value || inFlight.current) return;
    inFlight.current = true;
    setBusy(true);
    setError(null);
    try {
      const task = await transport.startProjectTask(projectId, { repo_id: repoId, prompt: value });
      onTaskStarted(task);
    } catch (cause) {
      setError(message(cause));
    } finally {
      inFlight.current = false;
      setBusy(false);
    }
  };

  return (
    <div className="msg-agent">
      <p className="agent-text">{item.content}</p>
      <div className="chat-line-meta">
        {item.model ? <span className="muted">{item.model}</span> : null}
        {canStart && !drafting ? (
          <button className="btn btn-quiet btn-small" onClick={() => setDrafting(true)}>Start as task</button>
        ) : null}
      </div>
      {drafting ? (
        <form className="chat-task-draft" onSubmit={(event) => { event.preventDefault(); void start(); }}>
          <label className="tile-label" htmlFor={`task-from-${item.id}`}>Task for the agent</label>
          <textarea id={`task-from-${item.id}`} className="pair-input" rows={4} value={prompt} onChange={(event) => setPrompt(event.target.value)} disabled={busy} />
          <p className="tile-note">The agent drafts in a worktree and stops with a diff for you to review.</p>
          {error ? <p className="error" role="alert">{error}</p> : null}
          <div className="approval-actions">
            <button type="button" className="btn" onClick={() => setDrafting(false)} disabled={busy}>Cancel</button>
            <button type="submit" className="btn btn-primary" disabled={busy || !prompt.trim()}>{busy ? "Starting…" : "Start task"}</button>
          </div>
        </form>
      ) : null}
    </div>
  );
}
