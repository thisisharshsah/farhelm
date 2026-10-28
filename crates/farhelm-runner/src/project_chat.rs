//! Project conversations over the local HTTP boundary.
//!
//! Text only, budgeted, and composed through the gateway: a message is
//! claimed as a durable turn first, the reply is produced outside any lock,
//! and the turn is settled afterwards as completed or failed. A reply that
//! never settles because the process died is marked interrupted at the next
//! start (`reconcile_after_restart`). Absent from the relay command set, like
//! the rest of the project workflow.

use std::path::PathBuf;
use std::sync::Arc;

use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Path, Query, State},
    http::StatusCode,
    routing::{get, post},
};
use farhelm_app::{
    chat::{CHAT_DEFAULT_BUDGET_USD, ChatError, PreparedChatTurn, ProjectChats},
    id::new_id,
    time::now_ms,
};
use farhelm_gateway::prompt::{Role, StableContext, Turn};
use farhelm_gateway::{CompleteRequest, GatewayError};
use farhelm_proto::{
    ChatDetail, ChatReply, ChatRole, CreateProjectChatRequest, ProjectChatPage,
    SendChatMessageRequest,
    types::{Agent, Session, SessionStatus, TaskType},
};
use farhelm_sqlite::SqliteStore;
use serde::Deserialize;

use crate::{
    api::ApiError,
    project_workflow::{operate, storage_error},
    state::{AppState, ServerEvent},
};

pub(crate) fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/v1/projects/{id}/conversations", get(list).post(create))
        .route("/v1/projects/{id}/conversations/{chat_id}", get(detail))
        .route(
            "/v1/projects/{id}/conversations/{chat_id}/messages",
            post(send),
        )
        .layer(DefaultBodyLimit::max(128 * 1024))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ListQuery {
    after: Option<String>,
    limit: Option<usize>,
}

type PageQuery = Result<Query<ListQuery>, axum::extract::rejection::QueryRejection>;

fn chats(state: &AppState) -> Result<ProjectChats<Arc<SqliteStore>>, ApiError> {
    ProjectChats::new(Arc::clone(&state.store), &state.machine_id).map_err(chat_error)
}

fn chat_error(error: ChatError) -> ApiError {
    match error {
        ChatError::Validation(message) => ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, message),
        ChatError::NotFound => ApiError::new(StatusCode::NOT_FOUND, "conversation not found"),
        ChatError::Conflict(message) => ApiError::new(StatusCode::CONFLICT, message),
        ChatError::Store(_) => storage_error(),
    }
}

async fn list(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    query: PageQuery,
) -> Result<Json<ProjectChatPage>, ApiError> {
    let query = query.map(|Query(query)| query).map_err(|_| {
        ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "invalid conversation pagination query",
        )
    })?;
    operate(state, move |state| {
        chats(&state)?
            .list(&id, query.after.as_deref(), query.limit.unwrap_or(50))
            .map_err(chat_error)
    })
    .await
    .map(Json)
}

async fn create(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(input): Json<CreateProjectChatRequest>,
) -> Result<(StatusCode, Json<ChatDetail>), ApiError> {
    operate(state, move |state| {
        let now = now_ms();
        // The conversation's own budgeted session: every reply is charged to
        // it through the gateway, so the cap is enforced where the money moves.
        let session = Session {
            id: new_id(),
            repo_id: input.repo_id.clone(),
            agent: Agent::Farhelm,
            tmux_target: None,
            status: SessionStatus::Running,
            plan_id: None,
            budget_usd: Some(input.budget_usd.unwrap_or(CHAT_DEFAULT_BUDGET_USD)),
            spent_usd: 0.0,
            started_at: now,
            ended_at: None,
            agent_session_id: None,
        };
        chats(&state)?
            .create(&id, &input, &session, now)
            .map_err(chat_error)
    })
    .await
    .map(|detail| (StatusCode::CREATED, Json(detail)))
}

async fn detail(
    State(state): State<Arc<AppState>>,
    Path((id, chat_id)): Path<(String, String)>,
) -> Result<Json<ChatDetail>, ApiError> {
    operate(state, move |state| {
        chats(&state)?.detail(&id, &chat_id).map_err(chat_error)
    })
    .await
    .map(Json)
}

/// Claim the turn, answer `200` with it pending, and compose the reply
/// detached. The client reads the conversation again to see it settle; a
/// resend with the same request id replays whatever was recorded.
async fn send(
    State(state): State<Arc<AppState>>,
    Path((id, chat_id)): Path<(String, String)>,
    Json(input): Json<SendChatMessageRequest>,
) -> Result<Json<ChatReply>, ApiError> {
    let runtime = tokio::runtime::Handle::current();
    operate(state, move |state| {
        let begun = chats(&state)?
            .begin(&id, &chat_id, &input, now_ms())
            .map_err(chat_error)?;
        if let Some(turn) = begun.dispatch {
            // Spawned from inside the blocking closure, after the claim has
            // committed, so an abandoned HTTP request cannot strand the turn.
            runtime.spawn(answer(
                Arc::clone(&state),
                id.clone(),
                chat_id.clone(),
                turn,
            ));
        }
        Ok(begun.reply)
    })
    .await
    .map(Json)
}

/// What the model is told about every conversation. Stable on purpose: no
/// dates, no ids, nothing that would make two turns' prefixes differ.
fn system_prompt(repo_name: &str, repo_path: &str) -> String {
    format!(
        "You are Farhelm, the assistant for a software project. This conversation is about \
         the repository `{repo_name}` at `{repo_path}` on the developer's machine. Answer in \
         plain, specific prose. When something should be changed in the repository, describe \
         it as an instruction the developer can hand to an agent as a task; you cannot edit \
         files or run commands from this conversation."
    )
}

async fn answer(state: Arc<AppState>, project_id: String, chat_id: String, turn: PreparedChatTurn) {
    let outcome = match &state.gateway {
        None => Err("no model provider is configured on this runner".to_owned()),
        Some(gateway) => {
            let mut request =
                CompleteRequest::new(&turn.session_id, TaskType::Plan, &turn.instruction);
            request.stable = StableContext {
                tools: Vec::new(),
                system: system_prompt(&turn.repo.name, &turn.repo.path),
                conventions: String::new(),
                repo_map: String::new(),
                history: turn
                    .history
                    .iter()
                    .map(|message| Turn {
                        role: match message.role {
                            ChatRole::User => Role::User,
                            ChatRole::Assistant => Role::Assistant,
                        },
                        text: message.content.clone(),
                        tool_calls: Vec::new(),
                        tool_results: Vec::new(),
                        reasoning: None,
                    })
                    .collect(),
            };
            request.repo_path = Some(PathBuf::from(&turn.repo.path));
            match gateway.complete(request).await {
                Ok(response) => Ok((response.text, response.model)),
                Err(GatewayError::BudgetExhausted { .. }) => Err(
                    "this conversation's budget is spent; start a new one with a larger cap".into(),
                ),
                Err(err) => Err(failure_text(&err.to_string())),
            }
        }
    };

    let session_id = turn.session_id.clone();
    let request_id = turn.request_id.clone();
    let settled = tokio::task::spawn_blocking(move || {
        let chats = chats(&state)?;
        let now = now_ms();
        match outcome {
            Ok((text, model)) => chats
                .complete(&project_id, &chat_id, &request_id, &text, &model, now)
                .or_else(|err| match err {
                    // An empty or oversized answer is a failed attempt, not a
                    // crash: record why so the conversation can move on.
                    ChatError::Validation(message) => chats
                        .fail(&project_id, &chat_id, &request_id, message, now)
                        .map_err(chat_error),
                    other => Err(chat_error(other)),
                }),
            Err(reason) => chats
                .fail(&project_id, &chat_id, &request_id, &reason, now)
                .map_err(chat_error),
        }
        .map(|_| state)
    })
    .await;

    match settled {
        Ok(Ok(state)) => state.publish(ServerEvent::SessionUpsert { session_id }),
        Ok(Err(err)) => eprintln!("conversation reply could not be recorded: {err:?}"),
        Err(err) => eprintln!("conversation reply task failed: {err}"),
    }
}

/// A provider error as a conversation can show it: one line, bounded, and
/// free of control characters the validator would reject.
fn failure_text(raw: &str) -> String {
    let cleaned: String = raw
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let mut text = String::with_capacity(cleaned.len().min(512));
    for c in cleaned.chars() {
        if text.len() + c.len_utf8() > 480 {
            text.push('…');
            break;
        }
        text.push(c);
    }
    let text = text.trim().to_owned();
    if text.is_empty() {
        "the model provider failed without a message".into()
    } else {
        text
    }
}

/// Mark replies that were pending when the process last stopped. Called once
/// at startup before the API accepts work; never retries them.
pub fn reconcile_after_restart(state: &AppState) -> Result<usize, ChatError> {
    ProjectChats::new(Arc::clone(&state.store), &state.machine_id)?.interrupt_pending(now_ms())
}
