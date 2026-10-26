//! Project conversations: scoped reads, durable claims and settled replies.
//!
//! Every write is one immediate transaction that re-checks the project scope
//! first, so a conversation in another workspace or on another machine is a
//! `None`, never a row touched by accident. Inference never happens in here:
//! the runner claims a turn, composes the reply outside the lock, and settles
//! it afterwards.

use super::*;
use farhelm_app::chat::{CHAT_MAX_BYTES, CHAT_MAX_MESSAGES, ChatStoreBegin, ChatStoreFinish};
use farhelm_app::store::{ChatStore, ProjectScope};
use farhelm_proto::{
    ChatDetail, ChatMessage, ChatReply, ChatRole, ChatTurn, ChatTurnStatus, ProjectChat,
    SendChatMessageRequest,
};

/// A conversation inside its scope, plus the session it is charged to.
struct ScopedChat {
    chat: ProjectChat,
    session_id: String,
}

const CHAT_COLUMNS: &str =
    "c.id, c.project_id, cs.repo_id, c.title, c.created_at, c.updated_at, cs.session_id";

/// The scope check every read and write starts from: the project is in the
/// workspace and the repository is on this machine.
const SCOPED_FROM: &str = "FROM conversation c
     JOIN chat_session cs ON cs.conversation_id = c.id
     JOIN project p ON p.id = c.project_id
     JOIN repo r ON r.id = cs.repo_id
     WHERE p.id = ?1 AND p.workspace_id = ?2 AND r.machine_id = ?3";

fn read_scoped_chat(row: &Row<'_>) -> rusqlite::Result<ScopedChat> {
    Ok(ScopedChat {
        chat: ProjectChat {
            id: row.get(0)?,
            project_id: row.get(1)?,
            repo_id: row.get(2)?,
            title: row.get(3)?,
            created_at: row.get(4)?,
            updated_at: row.get(5)?,
        },
        session_id: row.get(6)?,
    })
}

fn scoped_chat(
    conn: &Connection,
    scope: ProjectScope<'_>,
    chat_id: &str,
) -> Result<Option<ScopedChat>> {
    conn.query_row(
        &format!("SELECT {CHAT_COLUMNS} {SCOPED_FROM} AND c.id = ?4"),
        params![
            scope.project_id,
            scope.workspace_id,
            scope.machine_id,
            chat_id
        ],
        read_scoped_chat,
    )
    .optional()
    .map_err(backend)
}

fn role_from(text: &str) -> Result<ChatRole> {
    match text {
        "user" => Ok(ChatRole::User),
        "assistant" => Ok(ChatRole::Assistant),
        other => Err(StoreError::Corrupt(format!("unknown chat role {other:?}"))),
    }
}

fn status_from(text: &str) -> Result<ChatTurnStatus> {
    match text {
        "pending" => Ok(ChatTurnStatus::Pending),
        "completed" => Ok(ChatTurnStatus::Completed),
        "failed" => Ok(ChatTurnStatus::Failed),
        "interrupted" => Ok(ChatTurnStatus::Interrupted),
        other => Err(StoreError::Corrupt(format!(
            "unknown chat turn status {other:?}"
        ))),
    }
}

struct RawMessage {
    id: String,
    conversation_id: String,
    role: String,
    content: String,
    created_at: i64,
    model: Option<String>,
}

fn read_message(row: &Row<'_>) -> rusqlite::Result<RawMessage> {
    Ok(RawMessage {
        id: row.get(0)?,
        conversation_id: row.get(1)?,
        role: row.get(2)?,
        content: row.get(3)?,
        created_at: row.get(4)?,
        model: row.get(5)?,
    })
}

fn message_from(raw: RawMessage) -> Result<ChatMessage> {
    Ok(ChatMessage {
        id: raw.id,
        conversation_id: raw.conversation_id,
        role: role_from(&raw.role)?,
        content: raw.content,
        created_at: raw.created_at,
        model: raw.model,
    })
}

const MESSAGE_COLUMNS: &str = "m.id, m.conversation_id, m.role, m.content, m.created_at, m.model";

fn messages(conn: &Connection, chat_id: &str) -> Result<Vec<ChatMessage>> {
    let mut stmt = conn
        .prepare(&format!(
            "SELECT {MESSAGE_COLUMNS} FROM chat_message m
             WHERE m.conversation_id = ?1 ORDER BY m.created_at, m.id"
        ))
        .map_err(backend)?;
    let rows = stmt
        .query_map(params![chat_id], read_message)
        .map_err(backend)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(backend)?;
    rows.into_iter().map(message_from).collect()
}

/// Messages of completed turns only, in order: what the model is shown.
fn completed_history(conn: &Connection, chat_id: &str) -> Result<Vec<ChatMessage>> {
    let mut stmt = conn
        .prepare(&format!(
            "SELECT {MESSAGE_COLUMNS} FROM chat_message m
             JOIN chat_turn t ON t.conversation_id = m.conversation_id
                             AND t.request_id = m.request_id
             WHERE m.conversation_id = ?1 AND t.status = 'completed'
             ORDER BY m.created_at, m.id"
        ))
        .map_err(backend)?;
    let rows = stmt
        .query_map(params![chat_id], read_message)
        .map_err(backend)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(backend)?;
    rows.into_iter().map(message_from).collect()
}

struct RawTurn {
    request_id: String,
    status: String,
    error: Option<String>,
    created_at: i64,
    updated_at: i64,
}

fn read_turn(row: &Row<'_>) -> rusqlite::Result<RawTurn> {
    Ok(RawTurn {
        request_id: row.get(0)?,
        status: row.get(1)?,
        error: row.get(2)?,
        created_at: row.get(3)?,
        updated_at: row.get(4)?,
    })
}

fn turn_from(raw: RawTurn) -> Result<ChatTurn> {
    Ok(ChatTurn {
        request_id: raw.request_id,
        status: status_from(&raw.status)?,
        error: raw.error,
        created_at: raw.created_at,
        updated_at: raw.updated_at,
    })
}

const TURN_COLUMNS: &str = "request_id, status, error, created_at, updated_at";

fn turn(conn: &Connection, chat_id: &str, request_id: &str) -> Result<Option<ChatTurn>> {
    conn.query_row(
        &format!(
            "SELECT {TURN_COLUMNS} FROM chat_turn
             WHERE conversation_id = ?1 AND request_id = ?2"
        ),
        params![chat_id, request_id],
        read_turn,
    )
    .optional()
    .map_err(backend)?
    .map(turn_from)
    .transpose()
}

fn latest_turn(conn: &Connection, chat_id: &str) -> Result<Option<ChatTurn>> {
    conn.query_row(
        &format!(
            "SELECT {TURN_COLUMNS} FROM chat_turn WHERE conversation_id = ?1
             ORDER BY created_at DESC, rowid DESC LIMIT 1"
        ),
        params![chat_id],
        read_turn,
    )
    .optional()
    .map_err(backend)?
    .map(turn_from)
    .transpose()
}

fn detail(conn: &Connection, chat: ProjectChat) -> Result<ChatDetail> {
    let messages = messages(conn, &chat.id)?;
    let latest_turn = latest_turn(conn, &chat.id)?;
    Ok(ChatDetail {
        conversation: chat,
        messages,
        latest_turn,
    })
}

fn reply(conn: &Connection, chat: ProjectChat, request_id: &str) -> Result<ChatReply> {
    let turn = turn(conn, &chat.id, request_id)?.ok_or_else(|| {
        StoreError::Corrupt(format!("conversation {} has no turn {request_id}", chat.id))
    })?;
    Ok(ChatReply {
        detail: detail(conn, chat)?,
        turn,
    })
}

fn repo(conn: &Connection, repo_id: &str) -> Result<Repo> {
    conn.query_row(
        "SELECT id, machine_id, path, name, budget_usd FROM repo WHERE id = ?1",
        params![repo_id],
        |row| {
            Ok(Repo {
                id: row.get(0)?,
                machine_id: row.get(1)?,
                path: row.get(2)?,
                name: row.get(3)?,
                budget_usd: row.get(4)?,
            })
        },
    )
    .map_err(backend)
}

/// How a pending turn ends: with an answer, or with a reason there is none.
enum Settlement<'a> {
    Completed(&'a ChatMessage),
    Failed(&'a str),
}

impl Settlement<'_> {
    fn status(&self) -> &'static str {
        match self {
            Settlement::Completed(_) => "completed",
            Settlement::Failed(_) => "failed",
        }
    }
}

/// Settle a pending turn. Shared by complete and fail: the only difference is
/// whether a message lands and which status the row ends in.
fn settle(
    store: &SqliteStore,
    scope: ProjectScope<'_>,
    chat_id: &str,
    request_id: &str,
    settlement: Settlement<'_>,
    at_ms: i64,
) -> Result<ChatStoreFinish> {
    let (message, status, error) = match settlement {
        Settlement::Completed(message) => (Some(message), settlement.status(), None),
        Settlement::Failed(error) => (None, settlement.status(), Some(error)),
    };
    let mut conn = store.lock()?;
    let tx = conn
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(backend)?;
    let Some(scoped) = scoped_chat(&tx, scope, chat_id)? else {
        return Ok(ChatStoreFinish::NotFound);
    };
    let current: Option<String> = tx
        .query_row(
            "SELECT status FROM chat_turn WHERE conversation_id = ?1 AND request_id = ?2",
            params![chat_id, request_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(backend)?;
    if current.as_deref() != Some("pending") {
        return Ok(ChatStoreFinish::NotPending);
    }
    if let Some(message) = message {
        tx.execute(
            "INSERT INTO chat_message (id, conversation_id, request_id, role, content, model, created_at)
             VALUES (?1, ?2, ?3, 'assistant', ?4, ?5, ?6)",
            params![
                message.id,
                chat_id,
                request_id,
                message.content,
                message.model,
                message.created_at
            ],
        )
        .map_err(backend)?;
    }
    tx.execute(
        "UPDATE chat_turn SET status = ?3, error = ?4, updated_at = ?5
         WHERE conversation_id = ?1 AND request_id = ?2",
        params![chat_id, request_id, status, error, at_ms],
    )
    .map_err(backend)?;
    tx.execute(
        "UPDATE conversation SET updated_at = ?2 WHERE id = ?1",
        params![chat_id, at_ms],
    )
    .map_err(backend)?;
    let mut chat = scoped.chat;
    chat.updated_at = at_ms;
    let reply = reply(&tx, chat, request_id)?;
    tx.commit().map_err(backend)?;
    Ok(ChatStoreFinish::Finished(reply))
}

impl ChatStore for SqliteStore {
    fn chat_list(
        &self,
        scope: ProjectScope<'_>,
        after: Option<&str>,
        limit: usize,
    ) -> Result<Vec<ProjectChat>> {
        let conn = self.lock()?;
        let limit = i64::try_from(limit).map_err(|error| StoreError::Backend(Box::new(error)))?;
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {CHAT_COLUMNS} {SCOPED_FROM}
                 AND (?4 IS NULL OR c.id < ?4) ORDER BY c.id DESC LIMIT ?5"
            ))
            .map_err(backend)?;
        let rows = stmt
            .query_map(
                params![
                    scope.project_id,
                    scope.workspace_id,
                    scope.machine_id,
                    after,
                    limit
                ],
                read_scoped_chat,
            )
            .map_err(backend)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(backend)?;
        Ok(rows.into_iter().map(|scoped| scoped.chat).collect())
    }

    fn chat_detail(&self, scope: ProjectScope<'_>, chat_id: &str) -> Result<Option<ChatDetail>> {
        let conn = self.lock()?;
        scoped_chat(&conn, scope, chat_id)?
            .map(|scoped| detail(&conn, scoped.chat))
            .transpose()
    }

    fn chat_create(
        &self,
        scope: ProjectScope<'_>,
        chat: &ProjectChat,
        session: &Session,
    ) -> Result<bool> {
        if chat.project_id != scope.project_id || chat.repo_id != session.repo_id {
            return Ok(false);
        }
        let mut conn = self.lock()?;
        let tx = conn
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(backend)?;
        // The repository must be attached to this project and live on this
        // machine. Checked inside the transaction so an attachment removed a
        // moment ago cannot slip through.
        let attached: Option<i64> = tx
            .query_row(
                "SELECT 1 FROM project p
                 JOIN project_repo pr ON pr.project_id = p.id
                 JOIN repo r ON r.id = pr.repo_id
                 WHERE p.id = ?1 AND p.workspace_id = ?2 AND r.machine_id = ?3 AND r.id = ?4",
                params![
                    scope.project_id,
                    scope.workspace_id,
                    scope.machine_id,
                    chat.repo_id
                ],
                |row| row.get(0),
            )
            .optional()
            .map_err(backend)?;
        if attached.is_none() {
            return Ok(false);
        }
        tx.execute(
            "INSERT INTO session (id, repo_id, agent, tmux_target, status, plan_id, budget_usd,
                                  spent_usd, started_at, ended_at, agent_session_id)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
            params![
                session.id,
                session.repo_id,
                session.agent.as_str(),
                session.tmux_target,
                session.status.as_str(),
                session.plan_id,
                session.budget_usd,
                session.spent_usd,
                session.started_at,
                session.ended_at,
                session.agent_session_id,
            ],
        )
        .map_err(backend)?;
        tx.execute(
            "INSERT INTO conversation (id, project_id, title, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                chat.id,
                chat.project_id,
                chat.title,
                chat.created_at,
                chat.updated_at
            ],
        )
        .map_err(backend)?;
        tx.execute(
            "INSERT INTO chat_session (conversation_id, repo_id, session_id) VALUES (?1, ?2, ?3)",
            params![chat.id, chat.repo_id, session.id],
        )
        .map_err(backend)?;
        tx.commit().map_err(backend)?;
        Ok(true)
    }

    fn chat_begin(
        &self,
        scope: ProjectScope<'_>,
        chat_id: &str,
        request: &SendChatMessageRequest,
        message_id: &str,
        at_ms: i64,
    ) -> Result<ChatStoreBegin> {
        let mut conn = self.lock()?;
        let tx = conn
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(backend)?;
        let Some(scoped) = scoped_chat(&tx, scope, chat_id)? else {
            return Ok(ChatStoreBegin::NotFound);
        };

        // A request id seen before is a resend. The same text replays the
        // recorded outcome; different text under the same id is a client bug
        // worth refusing, because silently answering a different question
        // under an old receipt is worse than an error.
        if turn(&tx, chat_id, &request.request_id)?.is_some() {
            let asked: Option<String> = tx
                .query_row(
                    "SELECT content FROM chat_message
                     WHERE conversation_id = ?1 AND request_id = ?2 AND role = 'user'",
                    params![chat_id, request.request_id],
                    |row| row.get(0),
                )
                .optional()
                .map_err(backend)?;
            return Ok(if asked.as_deref() == Some(request.content.as_str()) {
                ChatStoreBegin::Replay(reply(&tx, scoped.chat, &request.request_id)?)
            } else {
                ChatStoreBegin::RequestMismatch
            });
        }

        let pending: Option<i64> = tx
            .query_row(
                "SELECT 1 FROM chat_turn WHERE conversation_id = ?1 AND status = 'pending'",
                params![chat_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(backend)?;
        if pending.is_some() {
            return Ok(ChatStoreBegin::Busy);
        }

        // Room for this question and its answer, in messages and in bytes.
        let (count, bytes): (i64, i64) = tx
            .query_row(
                "SELECT COUNT(*), COALESCE(SUM(LENGTH(CAST(content AS BLOB))), 0)
                 FROM chat_message WHERE conversation_id = ?1",
                params![chat_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(backend)?;
        let count = usize::try_from(count).unwrap_or(usize::MAX);
        let bytes = usize::try_from(bytes).unwrap_or(usize::MAX);
        if count.saturating_add(2) > CHAT_MAX_MESSAGES
            || bytes.saturating_add(request.content.len()) > CHAT_MAX_BYTES
        {
            return Ok(ChatStoreBegin::Full);
        }

        tx.execute(
            "INSERT INTO chat_message (id, conversation_id, request_id, role, content, model, created_at)
             VALUES (?1, ?2, ?3, 'user', ?4, NULL, ?5)",
            params![message_id, chat_id, request.request_id, request.content, at_ms],
        )
        .map_err(backend)?;
        tx.execute(
            "INSERT INTO chat_turn (conversation_id, request_id, status, error, created_at, updated_at)
             VALUES (?1, ?2, 'pending', NULL, ?3, ?3)",
            params![chat_id, request.request_id, at_ms],
        )
        .map_err(backend)?;
        tx.execute(
            "UPDATE conversation SET updated_at = ?2 WHERE id = ?1",
            params![chat_id, at_ms],
        )
        .map_err(backend)?;

        let history = completed_history(&tx, chat_id)?;
        let repo = repo(&tx, &scoped.chat.repo_id)?;
        let mut chat = scoped.chat;
        chat.updated_at = at_ms;
        let reply = reply(&tx, chat, &request.request_id)?;
        tx.commit().map_err(backend)?;
        Ok(ChatStoreBegin::Started {
            reply,
            session_id: scoped.session_id,
            repo,
            history,
        })
    }

    fn chat_complete(
        &self,
        scope: ProjectScope<'_>,
        chat_id: &str,
        request_id: &str,
        message: &ChatMessage,
        at_ms: i64,
    ) -> Result<ChatStoreFinish> {
        settle(
            self,
            scope,
            chat_id,
            request_id,
            Settlement::Completed(message),
            at_ms,
        )
    }

    fn chat_fail(
        &self,
        scope: ProjectScope<'_>,
        chat_id: &str,
        request_id: &str,
        error: &str,
        at_ms: i64,
    ) -> Result<ChatStoreFinish> {
        settle(
            self,
            scope,
            chat_id,
            request_id,
            Settlement::Failed(error),
            at_ms,
        )
    }

    fn chat_interrupt_pending(
        &self,
        workspace_id: &str,
        machine_id: &str,
        at_ms: i64,
    ) -> Result<usize> {
        // Scoped to this workspace and machine like every other write here:
        // a restored backup of another machine's database must not have its
        // history rewritten by this process.
        let conn = self.lock()?;
        conn.execute(
            "UPDATE chat_turn
             SET status = 'interrupted',
                 error = 'the runner restarted before this reply finished',
                 updated_at = ?3
             WHERE status = 'pending' AND conversation_id IN (
                 SELECT c.id FROM conversation c
                 JOIN chat_session cs ON cs.conversation_id = c.id
                 JOIN project p ON p.id = c.project_id
                 JOIN repo r ON r.id = cs.repo_id
                 WHERE p.workspace_id = ?1 AND r.machine_id = ?2)",
            params![workspace_id, machine_id, at_ms],
        )
        .map_err(backend)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use farhelm_app::chat::{ChatError, ProjectChats};
    use farhelm_app::store::{ProjectWorkflowStore, WorkspaceStore};
    use farhelm_proto::{CreateProjectChatRequest, Machine, Project};

    const NOW: i64 = 1_785_369_600_000;

    fn setup() -> SqliteStore {
        let store = SqliteStore::open_in_memory().unwrap();
        for id in ["machine", "foreign-machine"] {
            store
                .upsert_machine(&Machine {
                    id: id.into(),
                    name: id.into(),
                    pubkey: id.into(),
                    last_seen_at: None,
                    created_at: 1,
                })
                .unwrap();
        }
        for (id, machine) in [("repo-a", "machine"), ("repo-z", "foreign-machine")] {
            store
                .upsert_repo(&Repo {
                    id: id.into(),
                    machine_id: machine.into(),
                    path: format!("/synthetic/{id}"),
                    name: id.into(),
                    budget_usd: None,
                })
                .unwrap();
        }
        let workspace = store.local_workspace_id().unwrap();
        for (id, workspace) in [("project-a", workspace.as_str()), ("foreign", "elsewhere")] {
            store
                .insert_project(&Project {
                    id: id.into(),
                    workspace_id: workspace.into(),
                    name: id.into(),
                    description: String::new(),
                    budget_cap_usd: None,
                    created_at: 1,
                    updated_at: 1,
                })
                .unwrap();
        }
        store
            .attach_project_repository(
                ProjectScope {
                    workspace_id: &workspace,
                    machine_id: "machine",
                    project_id: "project-a",
                },
                "repo-a",
                1,
            )
            .unwrap()
            .expect("repo-a attaches to project-a");
        store
    }

    fn session(id: &str, repo: &str) -> Session {
        Session {
            id: id.into(),
            repo_id: repo.into(),
            agent: Agent::Farhelm,
            tmux_target: None,
            status: SessionStatus::Running,
            plan_id: None,
            budget_usd: Some(1.0),
            spent_usd: 0.0,
            started_at: NOW,
            ended_at: None,
            agent_session_id: None,
        }
    }

    fn create(chats: &ProjectChats<&SqliteStore>, session_id: &str) -> ChatDetail {
        chats
            .create(
                "project-a",
                &CreateProjectChatRequest {
                    repo_id: "repo-a".into(),
                    title: "Retry policy".into(),
                    budget_usd: None,
                },
                &session(session_id, "repo-a"),
                NOW,
            )
            .unwrap()
    }

    fn ask(
        chats: &ProjectChats<&SqliteStore>,
        chat_id: &str,
        request_id: &str,
        text: &str,
        at: i64,
    ) -> farhelm_app::chat::BeginChatResult {
        chats
            .begin(
                "project-a",
                chat_id,
                &SendChatMessageRequest {
                    content: text.into(),
                    request_id: request_id.into(),
                },
                at,
            )
            .unwrap()
    }

    #[test]
    fn a_conversation_is_created_with_its_own_budgeted_session_and_scoped_reads() {
        let store = setup();
        let chats = ProjectChats::new(&store, "machine").unwrap();
        let detail = create(&chats, "s-1");
        assert_eq!(detail.conversation.repo_id, "repo-a");
        assert!(detail.messages.is_empty());
        assert!(detail.latest_turn.is_none());
        assert_eq!(
            store.get_session("s-1").unwrap().unwrap().budget_usd,
            Some(1.0)
        );

        let page = chats.list("project-a", None, 10).unwrap();
        assert_eq!(page.conversations.len(), 1);
        assert!(page.next_cursor.is_none());

        // Another workspace or machine sees nothing, and cannot create either.
        assert!(matches!(
            chats.list("foreign", None, 10),
            Err(ChatError::NotFound)
        ));
        assert!(matches!(
            chats.detail("foreign", &detail.conversation.id),
            Err(ChatError::NotFound)
        ));
        let elsewhere = ProjectChats::new(&store, "foreign-machine").unwrap();
        assert!(matches!(
            elsewhere.detail("project-a", &detail.conversation.id),
            Err(ChatError::NotFound)
        ));
        assert!(matches!(
            chats.create(
                "project-a",
                &CreateProjectChatRequest {
                    repo_id: "repo-z".into(),
                    title: "Wrong machine".into(),
                    budget_usd: None,
                },
                &session("s-2", "repo-z"),
                NOW,
            ),
            Err(ChatError::NotFound)
        ));
        // The refused create wrote nothing, session included.
        assert!(store.get_session("s-2").unwrap().is_none());
    }

    #[test]
    fn a_turn_is_claimed_once_and_settled_once() {
        let store = setup();
        let chats = ProjectChats::new(&store, "machine").unwrap();
        let chat = create(&chats, "s-1").conversation;

        let begun = ask(
            &chats,
            &chat.id,
            "req-1",
            "Why does the retry loop spin?",
            NOW + 1,
        );
        let dispatch = begun.dispatch.expect("a fresh request dispatches");
        assert_eq!(dispatch.session_id, "s-1");
        assert_eq!(dispatch.repo.path, "/synthetic/repo-a");
        assert!(dispatch.history.is_empty());
        assert_eq!(begun.reply.turn.status, ChatTurnStatus::Pending);
        assert_eq!(begun.reply.detail.messages.len(), 1);

        // While it is pending: a second question waits, a resend replays, and a
        // reused id with other words is refused.
        assert!(matches!(
            chats.begin(
                "project-a",
                &chat.id,
                &SendChatMessageRequest {
                    content: "Another".into(),
                    request_id: "req-2".into()
                },
                NOW + 2
            ),
            Err(ChatError::Conflict(_))
        ));
        let replay = ask(
            &chats,
            &chat.id,
            "req-1",
            "Why does the retry loop spin?",
            NOW + 3,
        );
        assert!(replay.dispatch.is_none());
        assert_eq!(replay.reply.turn.status, ChatTurnStatus::Pending);
        assert!(matches!(
            chats.begin(
                "project-a",
                &chat.id,
                &SendChatMessageRequest {
                    content: "Different".into(),
                    request_id: "req-1".into()
                },
                NOW + 4
            ),
            Err(ChatError::Conflict(_))
        ));

        let reply = chats
            .complete(
                "project-a",
                &chat.id,
                "req-1",
                "It never backs off.",
                "synthetic-model",
                NOW + 5,
            )
            .unwrap();
        assert_eq!(reply.turn.status, ChatTurnStatus::Completed);
        assert_eq!(reply.detail.messages.len(), 2);
        assert_eq!(reply.detail.messages[1].role, ChatRole::Assistant);
        assert_eq!(
            reply.detail.messages[1].model.as_deref(),
            Some("synthetic-model")
        );
        assert_eq!(reply.detail.conversation.updated_at, NOW + 5);

        // Settling twice is a conflict, not a second message.
        assert!(matches!(
            chats.complete("project-a", &chat.id, "req-1", "Again", "m", NOW + 6),
            Err(ChatError::Conflict(_))
        ));
        assert!(matches!(
            chats.fail("project-a", &chat.id, "req-1", "late failure", NOW + 6),
            Err(ChatError::Conflict(_))
        ));

        // The next question carries only completed turns as history.
        let failed = ask(&chats, &chat.id, "req-2", "And the timeout?", NOW + 7);
        chats
            .fail(
                "project-a",
                &chat.id,
                "req-2",
                "provider unavailable",
                NOW + 8,
            )
            .unwrap();
        assert_eq!(failed.dispatch.unwrap().history.len(), 2);
        let third = ask(&chats, &chat.id, "req-3", "Try again please", NOW + 9);
        let history = third.dispatch.unwrap().history;
        assert_eq!(history.len(), 2, "the failed question is not history");
        assert!(
            history
                .iter()
                .all(|message| message.content != "And the timeout?")
        );
        let detail = chats.detail("project-a", &chat.id).unwrap();
        assert_eq!(detail.messages.len(), 4, "but it stays in the transcript");
        assert_eq!(detail.latest_turn.unwrap().request_id, "req-3");
    }

    #[test]
    fn a_restart_marks_pending_replies_interrupted_within_scope_only() {
        let store = setup();
        let chats = ProjectChats::new(&store, "machine").unwrap();
        let chat = create(&chats, "s-1").conversation;
        ask(
            &chats,
            &chat.id,
            "req-1",
            "Pending when the process died",
            NOW + 1,
        );

        let elsewhere = ProjectChats::new(&store, "foreign-machine").unwrap();
        assert_eq!(elsewhere.interrupt_pending(NOW + 2).unwrap(), 0);
        assert_eq!(chats.interrupt_pending(NOW + 2).unwrap(), 1);
        assert_eq!(chats.interrupt_pending(NOW + 3).unwrap(), 0);

        let detail = chats.detail("project-a", &chat.id).unwrap();
        let turn = detail.latest_turn.unwrap();
        assert_eq!(turn.status, ChatTurnStatus::Interrupted);
        assert!(turn.error.unwrap().contains("restarted"));
        // A resend of the interrupted request replays the interruption rather
        // than quietly asking again; the client starts a new request.
        let replay = ask(
            &chats,
            &chat.id,
            "req-1",
            "Pending when the process died",
            NOW + 4,
        );
        assert!(replay.dispatch.is_none());
        assert_eq!(replay.reply.turn.status, ChatTurnStatus::Interrupted);
        assert!(
            ask(&chats, &chat.id, "req-2", "Once more", NOW + 5)
                .dispatch
                .is_some()
        );
    }
}
