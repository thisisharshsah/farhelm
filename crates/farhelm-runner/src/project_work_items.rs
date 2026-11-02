//! Tasks on a project's board (work items) and the runs made on them. Direct
//! HTTP only, like the rest of the project workflow.

use std::sync::Arc;

use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Path, Query, State},
    http::StatusCode,
    routing::{get, post},
};
use farhelm_app::{
    time::now_ms,
    work_items::{WorkItemError, WorkItems},
};
use farhelm_proto::{
    CreateWorkItemRequest, StartWorkItemRunRequest, UpdateWorkItemRequest, WorkItem,
    WorkItemDetail, WorkItemPage, WorkItemView, views::TaskView,
};
use farhelm_sqlite::SqliteStore;
use serde::Deserialize;

use crate::{
    api::ApiError,
    project_workflow::{operate, storage_error},
    state::AppState,
    task::{self, ProjectTaskError},
    views::{Lookups, task_view},
};

pub(crate) fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/v1/projects/{id}/work-items", get(list).post(create))
        .route(
            "/v1/projects/{id}/work-items/{item_id}",
            get(detail).patch(update),
        )
        .route(
            "/v1/projects/{id}/work-items/{item_id}/runs",
            post(start_run),
        )
        .layer(DefaultBodyLimit::max(128 * 1024))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ListQuery {
    conversation: Option<String>,
    after: Option<String>,
    limit: Option<usize>,
}

type PageQuery = Result<Query<ListQuery>, axum::extract::rejection::QueryRejection>;

fn items(state: &AppState) -> Result<WorkItems<Arc<SqliteStore>>, ApiError> {
    WorkItems::new(Arc::clone(&state.store), &state.machine_id).map_err(item_error)
}

fn item_error(error: WorkItemError) -> ApiError {
    match error {
        WorkItemError::Validation(message) => {
            ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, message)
        }
        WorkItemError::NotFound => ApiError::new(StatusCode::NOT_FOUND, "task not found"),
        WorkItemError::Conflict(message) => ApiError::new(StatusCode::CONFLICT, message),
        WorkItemError::Store(_) => storage_error(),
    }
}

/// A task with its newest run, as a card shows it.
fn view(
    state: &AppState,
    lookups: &Lookups<'_, SqliteStore>,
    item: WorkItem,
) -> Result<WorkItemView, ApiError> {
    use farhelm_app::store::WorkItemStore;
    let latest_run = state
        .store
        .work_item_runs(&item.id)
        .map_err(|_| storage_error())?
        .into_iter()
        .next()
        .map(|run| task_view(lookups, run));
    Ok(WorkItemView { item, latest_run })
}

async fn list(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    query: PageQuery,
) -> Result<Json<WorkItemPage>, ApiError> {
    let query = query
        .map(|Query(query)| query)
        .map_err(|_| ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, "invalid task list query"))?;
    operate(state, move |state| {
        let rows = items(&state)?
            .list(
                &id,
                query.conversation.as_deref(),
                query.after.as_deref(),
                query.limit.unwrap_or(100),
            )
            .map_err(item_error)?;
        let lookups = Lookups::new(state.store.as_ref()).map_err(|_| storage_error())?;
        let items = rows
            .items
            .into_iter()
            .map(|item| view(&state, &lookups, item))
            .collect::<Result<Vec<_>, _>>()?;
        Ok(WorkItemPage {
            items,
            next_cursor: rows.next_cursor,
        })
    })
    .await
    .map(Json)
}

async fn create(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(input): Json<CreateWorkItemRequest>,
) -> Result<(StatusCode, Json<WorkItemView>), ApiError> {
    operate(state, move |state| {
        let item = items(&state)?
            .create(&id, &input, now_ms())
            .map_err(item_error)?;
        Ok(WorkItemView {
            item,
            latest_run: None,
        })
    })
    .await
    .map(|item| (StatusCode::CREATED, Json(item)))
}

async fn detail(
    State(state): State<Arc<AppState>>,
    Path((id, item_id)): Path<(String, String)>,
) -> Result<Json<WorkItemDetail>, ApiError> {
    operate(state, move |state| detail_of(&state, &id, &item_id))
        .await
        .map(Json)
}

fn detail_of(
    state: &AppState,
    project_id: &str,
    item_id: &str,
) -> Result<WorkItemDetail, ApiError> {
    let items = items(state)?;
    let item = items.get(project_id, item_id).map_err(item_error)?;
    let lookups = Lookups::new(state.store.as_ref()).map_err(|_| storage_error())?;
    let runs: Vec<TaskView> = items
        .runs(project_id, item_id)
        .map_err(item_error)?
        .into_iter()
        .map(|run| task_view(&lookups, run))
        .collect();
    Ok(WorkItemDetail {
        item: WorkItemView {
            item,
            latest_run: runs.first().cloned(),
        },
        runs,
    })
}

async fn update(
    State(state): State<Arc<AppState>>,
    Path((id, item_id)): Path<(String, String)>,
    Json(input): Json<UpdateWorkItemRequest>,
) -> Result<Json<WorkItemDetail>, ApiError> {
    operate(state, move |state| {
        items(&state)?
            .update(&id, &item_id, &input, now_ms())
            .map_err(item_error)?;
        detail_of(&state, &id, &item_id)
    })
    .await
    .map(Json)
}

/// Start a run on a task: the agent works on the task's repository with the
/// task's text, unless the request says otherwise. The run moves the task to
/// in progress.
async fn start_run(
    State(state): State<Arc<AppState>>,
    Path((id, item_id)): Path<(String, String)>,
    Json(input): Json<StartWorkItemRunRequest>,
) -> Result<(StatusCode, Json<TaskView>), ApiError> {
    let runtime = tokio::runtime::Handle::current();
    operate(state, move |state| {
        let request = items(&state)?
            .run_request(&id, &item_id, &input)
            .map_err(item_error)?;
        let lookups = Lookups::new(state.store.as_ref()).map_err(|_| storage_error())?;
        let run =
            task::start_project(&state, &id, request, &runtime).map_err(|error| match error {
                ProjectTaskError::Workflow(error) => crate::project_workflow::workflow_error(error),
                ProjectTaskError::Task(error) => error.into(),
            })?;
        Ok(task_view(&lookups, run))
    })
    .await
    .map(|run| (StatusCode::CREATED, Json(run)))
}
