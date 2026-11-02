/**
 * A project conversation: the discussion half of discussion → task → review.
 *
 * A conversation belongs to one of the project's attached repositories. A
 * message is claimed with a request id before it is answered: the reply is
 * composed on the runner after the request returns, so the pane polls the
 * conversation until the turn settles. While it waits it shows what the
 * reply is reading, from the session's output stream, so a slow answer is
 * visibly working rather than silent.
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
  type ChatDetail,
  type ChatMessage,
  type ModesView,
  type ProjectChat as Conversation,
  type ProjectRepository,
  type TaskView,
  type Transport,
  type WorkItemView,
  type WorkMode,
} from "@farhelm/client-core";
import { Icon } from "./Icon";
import { ModePicker, ModelPicker, ModeTag, useModes } from "./ModelChoice";
import { StatusPill, WORK_ITEM_STATUS } from "./status";
import { workItemPath } from "./WorkBoard";

/** A conversation answers in these; Agent and Review are task modes. */
const CHAT_MODES: readonly WorkMode[] = ["ask", "plan"];

export type ChatTransport = Transport & Required<Pick<Transport,
  "projectConversations" | "createProjectConversation" | "projectConversation" | "sendProjectMessage" | "startProjectTask"
  | "projectWorkItems" | "createProjectWorkItem" | "startWorkItemRun">>;

export function supportsProjectChat(transport: Transport | null): transport is ChatTransport {
  return transport?.kind === "loopback" && transport.supportsProjectChat === true
    && [transport.projectConversations, transport.createProjectConversation, transport.projectConversation,
      transport.sendProjectMessage, transport.startProjectTask, transport.projectWorkItems,
      transport.createProjectWorkItem, transport.startWorkItemRun].every((method) => typeof method === "function");
}

/** A task's title from a reply: its first line, cut to fit. */
function titleFrom(reply: string): string {
  const line = reply.split("\n").map((part) => part.replace(/^[#*\-\s]+|[*:]+$/g, "").trim()).find(Boolean) ?? "Task";
  return line.length > 120 ? `${line.slice(0, 117).trimEnd()}…` : line;
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

export function ConversationPane({ transport, projectId, conversation, repository, onTaskStarted, onNavigate }: {
  transport: ChatTransport;
  projectId: string;
  conversation: Conversation;
  repository: ProjectRepository | null;
  onTaskStarted: (task: TaskView) => void;
  onNavigate?: (path: string) => void;
}) {
  const [detail, setDetail] = useState<ChatDetail | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [text, setText] = useState("");
  const [sending, setSending] = useState(false);
  const [sendError, setSendError] = useState<string | null>(null);
  const [waitedOut, setWaitedOut] = useState(false);
  const [revision, setRevision] = useState(0);
  // How the next message is answered. Kept while the conversation is open:
  // a person planning wants every message planned, not just one.
  const [mode, setMode] = useState<WorkMode>("ask");
  const [model, setModel] = useState("");
  const modes = useModes(transport);
  // What the reply is doing right now, from the session it is narrated on.
  const [progress, setProgress] = useState<string[]>([]);
  useEffect(() => {
    const session = conversation.session_id;
    if (!session) return;
    const off = transport.onEvent((event) => {
      if (event.type !== "output_chunk" || event.session_id !== session) return;
      setProgress((lines) => [...lines, event.text].slice(-4));
    });
    return off;
  }, [transport, conversation.session_id]);
  // The tasks this discussion produced, with where each stands.
  const [tasks, setTasks] = useState<WorkItemView[]>([]);
  const [tasksRevision, setTasksRevision] = useState(0);
  useEffect(() => {
    let cancelled = false;
    transport.projectWorkItems(projectId, { conversation: conversation.id, limit: 50 })
      .then((page) => { if (!cancelled) setTasks(page.items); })
      .catch(() => { /* The strip is a convenience; the conversation still works. */ });
    return () => { cancelled = true; };
  }, [transport, projectId, conversation.id, tasksRevision]);
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | null = null;
    const off = transport.onEvent((event) => {
      if (event.type !== "task_upsert" || timer !== null) return;
      timer = setTimeout(() => { timer = null; setTasksRevision((value) => value + 1); }, 300);
    });
    return () => { off(); if (timer !== null) clearTimeout(timer); };
  }, [transport]);
  const inFlight = useRef(false);
  const alive = useRef(true);
  // The id of a send whose outcome is unknown. Retrying the same text reuses
  // it, so a send that timed out but landed is replayed by the runner rather
  // than posted twice.
  const unsettled = useRef<{ content: string; id: string } | null>(null);
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
  useEffect(() => { if (!pending) setProgress([]); }, [pending]);
  const lastUser = [...(detail?.messages ?? [])].reverse().find((item) => item.role === "user") ?? null;

  const send = async (content: string, fresh = false) => {
    const value = content.trim();
    if (!value || inFlight.current || pending) return;
    inFlight.current = true;
    setSending(true);
    setSendError(null);
    try {
      // A fresh id for every deliberate send, including a resend after an
      // interruption: the runner replays a reused id instead of answering it.
      // The one exception is retrying a send that may already have landed.
      const id = !fresh && unsettled.current?.content === value ? unsettled.current.id : requestId();
      unsettled.current = { content: value, id };
      const reply = await transport.sendProjectMessage(projectId, conversation.id,
        { content: value, request_id: id, mode, ...(model ? { model } : {}) });
      unsettled.current = null;
      if (!alive.current) return;
      setDetail(reply.detail);
      setText("");
      setRevision((current) => current + 1);
    } catch (cause) {
      if (!alive.current) return;
      setSendError(message(cause));
      // Read the conversation again: the message may be there after all.
      setRevision((current) => current + 1);
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
      {tasks.length > 0 ? (
        <div className="chat-tasks" aria-label="Tasks from this discussion">
          <span className="muted">Tasks:</span>
          {tasks.map((item) => (
            <span key={item.id}>
              {onNavigate ? (
                <button type="button" className="linkish" onClick={() => onNavigate(workItemPath(projectId, item.id))}>{item.title}</button>
              ) : <b>{item.title}</b>}
              {" "}
              <StatusPill look={WORK_ITEM_STATUS[item.status]} size="sm" />
            </span>
          ))}
        </div>
      ) : null}

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
            modes={modes}
            conversationId={conversation.id}
            onTaskStarted={onTaskStarted}
            onTaskCreated={() => setTasksRevision((value) => value + 1)}
          />
        ))}
        {pending && !waitedOut ? (
          <div className="working" role="status">
            <p><span className="working-dot" aria-hidden="true" />{progress.length > 0 ? "Working…" : "Thinking…"}</p>
            {progress.length > 0 ? (
              <ul className="working-steps">{progress.map((line, index) => <li key={index}>{line}</li>)}</ul>
            ) : null}
          </div>
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
              <button className="btn btn-small" disabled={sending} onClick={() => void send(lastUser.content, true)}>
                Send again
              </button>
            ) : null}
          </p>
        ) : null}
      </div>

      <form className="composer-box" onSubmit={(event) => { event.preventDefault(); void send(text); }}>
        <textarea
          rows={3}
          value={text}
          onChange={(event) => setText(event.target.value)}
          onKeyDown={(event) => {
            // Enter sends, as in the apps this follows; Shift+Enter is a new line.
            if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) {
              event.preventDefault();
              void send(text);
            }
          }}
          aria-label="Message"
          placeholder={pending ? "Waiting for the reply…" : "Ask about the project, or plan a change…"}
          disabled={sending}
        />
        <div className="composer-bar">
          <ModePicker value={mode} options={CHAT_MODES} modes={modes} onChange={setMode} disabled={sending} />
          <ModelPicker value={model} mode={mode} modes={modes} onChange={setModel} disabled={sending} />
          <span className="composer-hint">{pending ? "One reply at a time" : "Enter to send · Shift+Enter for a new line"}</span>
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

function ChatLine({ item, transport, projectId, repoId, canStart, modes, conversationId, onTaskStarted, onTaskCreated }: {
  item: ChatMessage;
  transport: ChatTransport;
  projectId: string;
  repoId: string;
  canStart: boolean;
  modes: ModesView | null;
  conversationId: string;
  onTaskStarted: (task: TaskView) => void;
  onTaskCreated: () => void;
}) {
  const [drafting, setDrafting] = useState(false);
  const [title, setTitle] = useState(() => titleFrom(item.content));
  const [prompt, setPrompt] = useState(item.content);
  const [runNow, setRunNow] = useState(true);
  const [model, setModel] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);

  if (item.role === "user") return <div className="msg-user">{item.content}</div>;

  // A task on the board first, linked to this discussion; then, if asked,
  // a run on it. The run's page opens; the board already shows the task.
  const start = async () => {
    const value = prompt.trim();
    if (!value || !title.trim() || inFlight.current) return;
    inFlight.current = true;
    setBusy(true);
    setError(null);
    try {
      const created = await transport.createProjectWorkItem(projectId, {
        title: title.trim(), description: value, repo_id: repoId, conversation_id: conversationId,
      });
      onTaskCreated();
      if (runNow) {
        const run = await transport.startWorkItemRun(projectId, created.id, { repo_id: repoId, ...(model ? { model } : {}) });
        onTaskStarted(run);
      } else {
        setDrafting(false);
      }
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
        <ModeTag mode={item.mode} model={item.model} />
        {canStart && !drafting ? (
          <button className="btn btn-quiet btn-small" onClick={() => setDrafting(true)}>Create task</button>
        ) : null}
      </div>
      {drafting ? (
        <form className="chat-task-draft" onSubmit={(event) => { event.preventDefault(); void start(); }}>
          <label className="tile-label" htmlFor={`task-title-${item.id}`}>Task</label>
          <input id={`task-title-${item.id}`} className="pair-input" value={title} onChange={(event) => setTitle(event.target.value)} disabled={busy} maxLength={200} />
          <label className="tile-label" htmlFor={`task-from-${item.id}`}>What should be done (the agent reads this)</label>
          <textarea id={`task-from-${item.id}`} className="pair-input" rows={4} value={prompt} onChange={(event) => setPrompt(event.target.value)} disabled={busy} />
          <p className="tile-note">The task goes on this project's board, linked to this discussion. A run drafts in a worktree and stops with a diff for you to review.</p>
          <div className="composer-bar">
            <label className="composer-hint"><input type="checkbox" checked={runNow} onChange={(event) => setRunNow(event.target.checked)} disabled={busy} /> Run the agent now</label>
            {runNow ? <ModelPicker id={`task-model-${item.id}`} value={model} mode="agent" modes={modes} onChange={setModel} disabled={busy} /> : null}
          </div>
          {error ? <p className="error" role="alert">{error}</p> : null}
          <div className="approval-actions">
            <button type="button" className="btn" onClick={() => setDrafting(false)} disabled={busy}>Cancel</button>
            <button type="submit" className="btn btn-primary" disabled={busy || !prompt.trim() || !title.trim()}>
              {busy ? (runNow ? "Starting…" : "Creating…") : runNow ? "Create and run" : "Create task"}
            </button>
          </div>
        </form>
      ) : null}
    </div>
  );
}
