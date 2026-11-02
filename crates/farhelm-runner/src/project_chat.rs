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
use farhelm_agent::tools::{self, Supervisor, Verdict};
use farhelm_agent::{ToolCall, Workspace};
use farhelm_app::{
    chat::{CHAT_DEFAULT_BUDGET_USD, ChatAnswer, ChatError, PreparedChatTurn, ProjectChats},
    id::new_id,
    time::now_ms,
};
use farhelm_gateway::prompt::{Role, StableContext, ToolResult, Turn};
use farhelm_gateway::{CompleteRequest, GatewayError};
use farhelm_proto::{
    ChatDetail, ChatReply, ChatRole, CreateProjectChatRequest, ProjectChatPage,
    SendChatMessageRequest, WorkMode,
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
        if let Some(model) = &input.model
            && !state
                .gateway
                .as_ref()
                .is_some_and(|gateway| gateway.client().declares(model))
        {
            return Err(ApiError::new(
                StatusCode::UNPROCESSABLE_ENTITY,
                format!("model `{model}` is not in the model registry"),
            ));
        }
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

/// How many model turns a reply may take while it reads the repository.
/// Ask and Plan read; they never edit or run, so the only cost of a turn is
/// time, and a question that needs more reading than this is a task.
const CHAT_MAX_STEPS: usize = 8;

/// The read-only tools a conversation may use (ADR 0009: Ask and Plan read,
/// Agent edits and runs).
fn reading_tools() -> Vec<serde_json::Value> {
    tools::definitions()
        .into_iter()
        .filter(|tool| {
            matches!(
                tool["name"].as_str(),
                Some(tools::READ_FILE | tools::LIST_FILES | tools::SEARCH)
            )
        })
        .collect()
}

/// A conversation's supervisor: nothing to approve, since no tool here can
/// change anything; what the model reads is narrated to the session so the
/// transcript shows where an answer came from.
struct Reading<'a> {
    state: &'a AppState,
    session_id: &'a str,
}

impl Supervisor for Reading<'_> {
    async fn request(&self, tool: &str, _payload: &str) -> Verdict {
        Verdict::Denied(format!(
            "a conversation can read the repository but not {tool}; make it a task"
        ))
    }

    fn note(&self, text: &str) {
        self.state.push_output(self.session_id, text, now_ms());
    }
}

/// What the model is told about every conversation. Stable on purpose: no
/// dates, no ids, nothing that would make two turns' prefixes differ. Plan
/// mode asks for steps a person can accept one by one (ADR 0009).
fn system_prompt(repo_name: &str, repo_path: &str, mode: WorkMode) -> String {
    let shape = match mode {
        WorkMode::Plan => {
            "Answer with a plan: a short statement of the goal, then numbered steps, each one \
             thing an agent can do and check, with the files it touches. Note anything that \
             needs a decision from the developer before the work starts."
        }
        _ => "Answer in plain, specific prose.",
    };
    format!(
        "You are Farhelm, the assistant for a software project. This conversation is about \
         the repository `{repo_name}` at `{repo_path}` on the developer's machine. You can \
         read its files, list its directories and search it with the tools; use them when \
         the answer depends on what the code says, and read only what the question needs. \
         {shape} When something should be changed in the repository, describe it as an \
         instruction the developer can hand to an agent as a task; you cannot edit files or \
         run commands from this conversation."
    )
}

fn tool_result(call: &ToolCall, body: String, is_error: bool) -> ToolResult {
    ToolResult {
        tool_use_id: call.id.clone(),
        content: body,
        is_error,
    }
}

async fn answer(state: Arc<AppState>, project_id: String, chat_id: String, turn: PreparedChatTurn) {
    let outcome = match &state.gateway {
        None => Err("no model provider is configured on this runner".to_owned()),
        Some(gateway) => {
            // Reading needs the repository on disk; without it the model
            // answers from the retrieved context alone, as it always did.
            let mut workspace = Workspace::open(&turn.repo.path).ok();
            let mut stable = StableContext {
                tools: if workspace.is_some() {
                    reading_tools()
                } else {
                    Vec::new()
                },
                system: system_prompt(&turn.repo.name, &turn.repo.path, turn.mode),
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
            // The named model, else the mode's. Checked against the registry
            // when the message was accepted.
            let model = turn
                .model
                .clone()
                .or_else(|| gateway.client().mode_model(turn.mode));
            let supervisor = Reading {
                state: &state,
                session_id: &turn.session_id,
            };
            let mut remembered = Vec::new();
            let mut pending_results: Vec<ToolResult> = Vec::new();
            let mut outcome = Err("the reply did not finish".to_owned());
            for step in 0..CHAT_MAX_STEPS {
                let mut request =
                    CompleteRequest::new(&turn.session_id, TaskType::Plan, &turn.instruction);
                request.model = model.clone();
                request.stable = stable.clone();
                request.tool_results = pending_results.clone();
                // Retrieval once, on the first turn, as the agent does.
                request.repo_path = (step == 0).then(|| PathBuf::from(&turn.repo.path));
                let response = match gateway.complete(request).await {
                    Ok(response) => response,
                    Err(GatewayError::BudgetExhausted { .. }) => {
                        outcome = Err("this conversation's budget is spent; start a new one with a larger cap".into());
                        break;
                    }
                    Err(err) => {
                        outcome = Err(failure_text(&err.to_string()));
                        break;
                    }
                };
                if let Some(compacted) = response.compacted_history {
                    stable.history = compacted;
                }
                if response.tool_calls.is_empty() || step + 1 == CHAT_MAX_STEPS {
                    // The answer, or the most the model said before its
                    // reading allowance ran out; a reply that says what it
                    // found so far beats a failed turn.
                    let text = if response.text.trim().is_empty() {
                        "I read the repository but did not reach an answer within this \
                         conversation's reading limit. Ask something narrower, or make it a task."
                            .to_owned()
                    } else {
                        response.text
                    };
                    outcome = Ok((text, response.model));
                    break;
                }
                stable.history.push(Turn::user_with_results(
                    response.submitted_instruction,
                    std::mem::take(&mut pending_results),
                ));
                stable.history.push(
                    Turn::assistant_with_tools(response.text, response.tool_calls.clone())
                        .with_reasoning(response.reasoning.clone()),
                );
                for call in &response.tool_calls {
                    supervisor.note(&format!("▸ {}", tools::summary(call)));
                    let result = match workspace.as_mut() {
                        Some(workspace) => {
                            tools::execute(call, workspace, &supervisor, &mut remembered).await
                        }
                        None => Err(farhelm_agent::tools::ToolError::Unknown(call.name.clone())),
                    };
                    pending_results.push(match result {
                        Ok(body) => tool_result(call, body, false),
                        Err(err) => tool_result(call, err.to_string(), true),
                    });
                }
            }
            outcome
        }
    };

    let session_id = turn.session_id.clone();
    let request_id = turn.request_id.clone();
    let mode = turn.mode;
    let settled = tokio::task::spawn_blocking(move || {
        let chats = chats(&state)?;
        let now = now_ms();
        match outcome {
            Ok((text, model)) => chats
                .complete(
                    &project_id,
                    &chat_id,
                    &request_id,
                    ChatAnswer {
                        text: &text,
                        model: &model,
                        mode,
                    },
                    now,
                )
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
