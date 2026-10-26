//! Local project conversations. Inference is composed by the runner after a
//! durable claim; this module neither invokes models nor authorizes tools.

use std::fmt;

use farhelm_proto::{
    Agent, ChatDetail, ChatMessage, ChatReply, ChatRole, CreateProjectChatRequest, ProjectChat,
    ProjectChatPage, Repo, SendChatMessageRequest, Session, SessionStatus,
};

use crate::store::{ChatStore, ProjectScope, StoreError, WorkspaceStore};

pub const CHAT_MAX_MESSAGES: usize = 100;
pub const CHAT_MAX_BYTES: usize = 256 * 1024;
pub const CHAT_MAX_USER_BYTES: usize = 16 * 1024;
pub const CHAT_MAX_ASSISTANT_BYTES: usize = 64 * 1024;
pub const CHAT_DEFAULT_BUDGET_USD: f64 = 1.0;

#[derive(Debug)]
pub enum ChatError {
    Validation(&'static str),
    NotFound,
    Conflict(&'static str),
    Store(StoreError),
}

impl fmt::Display for ChatError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Validation(message) | Self::Conflict(message) => f.write_str(message),
            Self::NotFound => f.write_str("project conversation not found"),
            Self::Store(error) => write!(f, "{error}"),
        }
    }
}

impl std::error::Error for ChatError {}
impl From<StoreError> for ChatError {
    fn from(value: StoreError) -> Self {
        Self::Store(value)
    }
}

pub struct PreparedChatTurn {
    pub session_id: String,
    pub repo: Repo,
    pub request_id: String,
    pub instruction: String,
    /// Only successful prior turns, excluding the newly submitted instruction.
    pub history: Vec<ChatMessage>,
}

pub struct BeginChatResult {
    pub reply: ChatReply,
    /// `None` for every replay, including a previously interrupted request.
    pub dispatch: Option<PreparedChatTurn>,
}

pub enum ChatStoreBegin {
    Started {
        reply: ChatReply,
        session_id: String,
        repo: Repo,
        history: Vec<ChatMessage>,
    },
    Replay(ChatReply),
    NotFound,
    Busy,
    RequestMismatch,
    Full,
}

#[allow(clippy::large_enum_variant)]
pub enum ChatStoreFinish {
    Finished(ChatReply),
    NotFound,
    NotPending,
}

pub struct ProjectChats<S> {
    store: S,
    workspace_id: String,
    machine_id: String,
}

impl<S: ChatStore + WorkspaceStore> ProjectChats<S> {
    pub fn new(store: S, machine_id: &str) -> Result<Self, ChatError> {
        let workspace_id = store.local_workspace_id()?;
        Ok(Self {
            store,
            workspace_id,
            machine_id: machine_id.into(),
        })
    }

    fn scope<'a>(&'a self, project_id: &'a str) -> ProjectScope<'a> {
        ProjectScope {
            workspace_id: &self.workspace_id,
            machine_id: &self.machine_id,
            project_id,
        }
    }

    pub fn list(
        &self,
        project_id: &str,
        after: Option<&str>,
        limit: usize,
    ) -> Result<ProjectChatPage, ChatError> {
        validate_id(project_id)?;
        if let Some(id) = after {
            validate_id(id)?;
        }
        if !(1..=100).contains(&limit) {
            return Err(ChatError::Validation(
                "page limit must be between 1 and 100",
            ));
        }
        if self
            .store
            .get_project_in_workspace(&self.workspace_id, project_id)?
            .is_none()
        {
            return Err(ChatError::NotFound);
        }
        let mut conversations = self
            .store
            .chat_list(self.scope(project_id), after, limit + 1)?;
        let more = conversations.len() > limit;
        conversations.truncate(limit);
        let next_cursor = more.then(|| conversations.last().unwrap().id.clone());
        Ok(ProjectChatPage {
            conversations,
            next_cursor,
        })
    }

    pub fn detail(&self, project_id: &str, chat_id: &str) -> Result<ChatDetail, ChatError> {
        validate_id(project_id)?;
        validate_id(chat_id)?;
        self.store
            .chat_detail(self.scope(project_id), chat_id)?
            .ok_or(ChatError::NotFound)
    }

    pub fn create(
        &self,
        project_id: &str,
        request: &CreateProjectChatRequest,
        session: &Session,
        at_ms: i64,
    ) -> Result<ChatDetail, ChatError> {
        validate_id(project_id)?;
        validate_create(request)?;
        let budget = request.budget_usd.unwrap_or(CHAT_DEFAULT_BUDGET_USD);
        if session.repo_id != request.repo_id
            || session.agent != Agent::Farhelm
            || session.status != SessionStatus::Running
            || session.spent_usd != 0.0
            || session.budget_usd != Some(budget)
            || session.agent_session_id.is_some()
            || session.plan_id.is_some()
            || session.ended_at.is_some()
        {
            return Err(ChatError::Validation(
                "conversation requires a new matching budgeted session",
            ));
        }
        let conversation = ProjectChat {
            id: crate::id::new_id(),
            project_id: project_id.into(),
            repo_id: request.repo_id.clone(),
            title: request.title.trim().into(),
            created_at: at_ms,
            updated_at: at_ms,
        };
        if !self
            .store
            .chat_create(self.scope(project_id), &conversation, session)?
        {
            return Err(ChatError::NotFound);
        }
        self.detail(project_id, &conversation.id)
    }

    pub fn begin(
        &self,
        project_id: &str,
        chat_id: &str,
        request: &SendChatMessageRequest,
        at_ms: i64,
    ) -> Result<BeginChatResult, ChatError> {
        validate_id(project_id)?;
        validate_id(chat_id)?;
        validate_id(&request.request_id)?;
        validate_text(
            &request.content,
            CHAT_MAX_USER_BYTES,
            "message must contain text and fit within 16 KiB",
        )?;
        match self.store.chat_begin(
            self.scope(project_id),
            chat_id,
            request,
            &crate::id::new_id(),
            at_ms,
        )? {
            ChatStoreBegin::Started {
                reply,
                session_id,
                repo,
                history,
            } => Ok(BeginChatResult {
                reply,
                dispatch: Some(PreparedChatTurn {
                    session_id,
                    repo,
                    request_id: request.request_id.clone(),
                    instruction: request.content.clone(),
                    history,
                }),
            }),
            ChatStoreBegin::Replay(reply) => Ok(BeginChatResult {
                reply,
                dispatch: None,
            }),
            ChatStoreBegin::NotFound => Err(ChatError::NotFound),
            ChatStoreBegin::Busy => Err(ChatError::Conflict(
                "a reply is already pending in this conversation",
            )),
            ChatStoreBegin::RequestMismatch => Err(ChatError::Conflict(
                "request identity was already used with different content",
            )),
            ChatStoreBegin::Full => Err(ChatError::Conflict(
                "conversation history is full; start a new conversation",
            )),
        }
    }

    pub fn complete(
        &self,
        project_id: &str,
        chat_id: &str,
        request_id: &str,
        text: &str,
        model: &str,
        at_ms: i64,
    ) -> Result<ChatReply, ChatError> {
        validate_text(
            text,
            CHAT_MAX_ASSISTANT_BYTES,
            "reply must contain text and fit within 64 KiB",
        )?;
        validate_text(model, 256, "reply model identity is invalid")?;
        let message = ChatMessage {
            id: crate::id::new_id(),
            conversation_id: chat_id.into(),
            role: ChatRole::Assistant,
            content: text.into(),
            created_at: at_ms,
            model: Some(model.into()),
        };
        self.finish_result(self.store.chat_complete(
            self.scope(project_id),
            chat_id,
            request_id,
            &message,
            at_ms,
        )?)
    }

    pub fn fail(
        &self,
        project_id: &str,
        chat_id: &str,
        request_id: &str,
        error: &str,
        at_ms: i64,
    ) -> Result<ChatReply, ChatError> {
        validate_text(error, 512, "failure message is invalid")?;
        self.finish_result(self.store.chat_fail(
            self.scope(project_id),
            chat_id,
            request_id,
            error,
            at_ms,
        )?)
    }

    fn finish_result(&self, result: ChatStoreFinish) -> Result<ChatReply, ChatError> {
        match result {
            ChatStoreFinish::Finished(reply) => Ok(reply),
            ChatStoreFinish::NotFound => Err(ChatError::NotFound),
            ChatStoreFinish::NotPending => Err(ChatError::Conflict(
                "this reply attempt is no longer pending",
            )),
        }
    }

    /// Call once at runner startup, before accepting new chat work. This never
    /// retries uncertain inference or changes completed/failed attempts.
    pub fn interrupt_pending(&self, at_ms: i64) -> Result<usize, ChatError> {
        Ok(self
            .store
            .chat_interrupt_pending(&self.workspace_id, &self.machine_id, at_ms)?)
    }
}

pub fn validate_create(request: &CreateProjectChatRequest) -> Result<(), ChatError> {
    validate_id(&request.repo_id)?;
    if request.title.trim().is_empty()
        || request.title.trim().chars().count() > 120
        || request.title.len() > 480
        || request.title.chars().any(char::is_control)
    {
        return Err(ChatError::Validation(
            "title must contain 1 to 120 characters without control characters",
        ));
    }
    let budget = request.budget_usd.unwrap_or(CHAT_DEFAULT_BUDGET_USD);
    if !budget.is_finite() || budget <= 0.0 || budget > 10_000.0 {
        return Err(ChatError::Validation(
            "conversation budget must be positive and at most 10000 USD",
        ));
    }
    Ok(())
}

fn validate_id(id: &str) -> Result<(), ChatError> {
    if id.is_empty() || id.len() > 128 || id.chars().any(char::is_control) {
        return Err(ChatError::Validation("invalid resource identity"));
    }
    Ok(())
}

fn validate_text(text: &str, max: usize, error: &'static str) -> Result<(), ChatError> {
    if text.trim().is_empty()
        || text.len() > max
        || text
            .chars()
            .any(|c| c.is_control() && c != '\n' && c != '\r' && c != '\t')
    {
        return Err(ChatError::Validation(error));
    }
    Ok(())
}
