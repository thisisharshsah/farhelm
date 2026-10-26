//! Project-owned repository and task composition over the existing local trust
//! boundary. These routes are intentionally absent from the relay command set.

use std::sync::Arc;

use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Path, Query, State},
    http::StatusCode,
    routing::{get, post},
};
use farhelm_app::{
    project_workflow::{ProjectWorkflow, ProjectWorkflowError},
    time::now_ms,
};
use farhelm_proto::{
    types::{
        AttachProjectRepositoryRequest, DecidedVia, ProjectRepository, ProjectRepositoryPage,
        StartProjectTaskRequest,
    },
    views::{ProjectTaskPage, TaskDetail, TaskView},
};
use farhelm_sqlite::SqliteStore;
use serde::Deserialize;

use crate::{
    api::{ApiError, RevertBody, ReviewBody},
    state::AppState,
    task::{self, ProjectTaskError},
    views::{Lookups, detail_for_task, task_view},
};

pub(crate) fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route(
            "/v1/projects/{id}/repo-candidates",
            get(repository_candidates),
        )
        .route(
            "/v1/projects/{id}/repos",
            get(repositories).post(attach_repository),
        )
        .route("/v1/projects/{id}/tasks", get(tasks).post(start_task))
        .route("/v1/projects/{id}/tasks/{task_id}", get(task_detail))
        .route(
            "/v1/projects/{id}/tasks/{task_id}/review",
            post(review_task),
        )
        .route(
            "/v1/projects/{id}/tasks/{task_id}/revert",
            post(revert_task),
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

fn page_query(query: PageQuery) -> Result<ListQuery, ApiError> {
    query.map(|Query(query)| query).map_err(|_| {
        ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "invalid project pagination query",
        )
    })
}

fn workflow(state: &AppState) -> Result<ProjectWorkflow<Arc<SqliteStore>>, ApiError> {
    ProjectWorkflow::new(Arc::clone(&state.store), &state.machine_id).map_err(workflow_error)
}

async fn repository_candidates(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    query: PageQuery,
) -> Result<Json<ProjectRepositoryPage>, ApiError> {
    let query = page_query(query)?;
    operate(state, move |state| {
        workflow(&state)?
            .repository_candidates(&id, query.after.as_deref(), query.limit.unwrap_or(50))
            .map_err(workflow_error)
    })
    .await
    .map(Json)
}

async fn repositories(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    query: PageQuery,
) -> Result<Json<ProjectRepositoryPage>, ApiError> {
    let query = page_query(query)?;
    operate(state, move |state| {
        workflow(&state)?
            .repositories(&id, query.after.as_deref(), query.limit.unwrap_or(50))
            .map_err(workflow_error)
    })
    .await
    .map(Json)
}

async fn attach_repository(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(input): Json<AttachProjectRepositoryRequest>,
) -> Result<(StatusCode, Json<ProjectRepository>), ApiError> {
    operate(state, move |state| {
        workflow(&state)?
            .attach_repository(&id, &input.repo_id, now_ms())
            .map_err(workflow_error)
    })
    .await
    .map(|repo| (StatusCode::CREATED, Json(repo)))
}

async fn tasks(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    query: PageQuery,
) -> Result<Json<ProjectTaskPage>, ApiError> {
    let query = page_query(query)?;
    operate(state, move |state| {
        let rows = workflow(&state)?
            .tasks(&id, query.after.as_deref(), query.limit.unwrap_or(50))
            .map_err(workflow_error)?;
        let lookups = Lookups::new(state.store.as_ref()).map_err(|_| storage_error())?;
        Ok(ProjectTaskPage {
            tasks: rows
                .tasks
                .into_iter()
                .map(|task| task_view(&lookups, task))
                .collect(),
            next_cursor: rows.next_cursor,
        })
    })
    .await
    .map(Json)
}

async fn start_task(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(input): Json<StartProjectTaskRequest>,
) -> Result<(StatusCode, Json<TaskView>), ApiError> {
    let runtime = tokio::runtime::Handle::current();
    operate(state, move |state| {
        let lookups = Lookups::new(state.store.as_ref()).map_err(|_| storage_error())?;
        let task =
            task::start_project(&state, &id, input, &runtime).map_err(|error| match error {
                ProjectTaskError::Workflow(error) => workflow_error(error),
                ProjectTaskError::Task(error) => task_error(error),
            })?;
        Ok(task_view(&lookups, task))
    })
    .await
    .map(|task| (StatusCode::CREATED, Json(task)))
}

async fn task_detail(
    State(state): State<Arc<AppState>>,
    Path((id, task_id)): Path<(String, String)>,
) -> Result<Json<TaskDetail>, ApiError> {
    operate(state, move |state| {
        let task = workflow(&state)?
            .task(&id, &task_id)
            .map_err(workflow_error)?;
        detail_for_task(&state, task).map_err(|_| storage_error())
    })
    .await
    .map(Json)
}

async fn review_task(
    State(state): State<Arc<AppState>>,
    Path((id, task_id)): Path<(String, String)>,
    Json(body): Json<ReviewBody>,
) -> Result<Json<TaskView>, ApiError> {
    operate(state, move |state| {
        workflow(&state)?
            .task(&id, &task_id)
            .map_err(workflow_error)?;
        let lookups = Lookups::new(state.store.as_ref()).map_err(|_| storage_error())?;
        let task = task::review(
            &state,
            &task_id,
            body.decision,
            body.note.as_deref().filter(|note| !note.trim().is_empty()),
            body.via.unwrap_or(DecidedVia::Web),
        )
        .map_err(task_error)?;
        Ok(task_view(&lookups, task))
    })
    .await
    .map(Json)
}

async fn revert_task(
    State(state): State<Arc<AppState>>,
    Path((id, task_id)): Path<(String, String)>,
    body: Option<Json<RevertBody>>,
) -> Result<Json<TaskView>, ApiError> {
    let via = body
        .and_then(|Json(body)| body.via)
        .unwrap_or(DecidedVia::Web);
    operate(state, move |state| {
        workflow(&state)?
            .task(&id, &task_id)
            .map_err(workflow_error)?;
        let lookups = Lookups::new(state.store.as_ref()).map_err(|_| storage_error())?;
        let task = task::revert(&state, &task_id, via).map_err(task_error)?;
        Ok(task_view(&lookups, task))
    })
    .await
    .map(Json)
}

pub(crate) async fn operate<T: Send + 'static>(
    state: Arc<AppState>,
    operation: impl FnOnce(Arc<AppState>) -> Result<T, ApiError> + Send + 'static,
) -> Result<T, ApiError> {
    let permit = Arc::clone(&state.project_requests)
        .try_acquire_owned()
        .map_err(|_| {
            ApiError::new(
                StatusCode::TOO_MANY_REQUESTS,
                "project requests are busy; try again",
            )
        })?;
    tokio::task::spawn_blocking(move || {
        // An abandoned HTTP request must not release the SQLite slot early or
        // cancel the dispatch after its durable task row has committed.
        let _permit = permit;
        operation(state)
    })
    .await
    .map_err(|_| {
        ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "project operation could not complete",
        )
    })?
}

fn workflow_error(error: ProjectWorkflowError) -> ApiError {
    match error {
        ProjectWorkflowError::Validation(message) => {
            ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, message)
        }
        ProjectWorkflowError::NotFound => {
            ApiError::new(StatusCode::NOT_FOUND, "project resource not found")
        }
        ProjectWorkflowError::Conflict(message) => ApiError::new(StatusCode::CONFLICT, message),
        ProjectWorkflowError::Store(_) => storage_error(),
    }
}

fn task_error(error: task::TaskError) -> ApiError {
    match error {
        task::TaskError::Store(_) => storage_error(),
        error => error.into(),
    }
}

pub(crate) fn storage_error() -> ApiError {
    ApiError::new(
        StatusCode::INTERNAL_SERVER_ERROR,
        "project storage is unavailable",
    )
}
