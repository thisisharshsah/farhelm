//! Local project metadata. The existing local API authentication/origin policy
//! wraps these routes; workspace scope is resolved from this runner's database.

use std::sync::Arc;

use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Path, Query, State},
    http::StatusCode,
    routing::get,
};
use farhelm_app::{
    projects::{DEFAULT_PROJECT_PAGE_SIZE, ProjectError, Projects},
    time::now_ms,
};
use farhelm_proto::types::{CreateProjectRequest, Project, ProjectPage};
use farhelm_sqlite::SqliteStore;
use serde::Deserialize;

use crate::{api::ApiError, state::AppState};

pub(crate) fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/v1/projects", get(list).post(create))
        .route("/v1/projects/{id}", get(detail))
        .layer(DefaultBodyLimit::max(24 * 1024))
        .merge(crate::project_workflow::routes())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ListQuery {
    after: Option<String>,
    limit: Option<usize>,
}

async fn list(
    State(state): State<Arc<AppState>>,
    query: Result<Query<ListQuery>, axum::extract::rejection::QueryRejection>,
) -> Result<Json<ProjectPage>, ApiError> {
    let Query(query) = query.map_err(|_| {
        ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "invalid project pagination query",
        )
    })?;
    operate(state, move |projects| {
        projects.list(
            query.after.as_deref(),
            query.limit.unwrap_or(DEFAULT_PROJECT_PAGE_SIZE),
        )
    })
    .await
    .map(Json)
}

async fn detail(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<Project>, ApiError> {
    if id.len() > 128 || id.chars().any(char::is_control) {
        return Err(project_error(ProjectError::NotFound));
    }
    operate(state, move |projects| projects.get(&id))
        .await
        .map(Json)
}

async fn create(
    State(state): State<Arc<AppState>>,
    Json(input): Json<CreateProjectRequest>,
) -> Result<(StatusCode, Json<Project>), ApiError> {
    let at_ms = now_ms();
    operate(state, move |projects| projects.create(input, at_ms))
        .await
        .map(|project| (StatusCode::CREATED, Json(project)))
}

async fn operate<T: Send + 'static>(
    state: Arc<AppState>,
    operation: impl FnOnce(Projects<Arc<SqliteStore>>) -> Result<T, ProjectError> + Send + 'static,
) -> Result<T, ApiError> {
    let permit = Arc::clone(&state.project_requests)
        .try_acquire_owned()
        .map_err(|_| {
            ApiError::new(
                StatusCode::TOO_MANY_REQUESTS,
                "project requests are busy; try again",
            )
        })?;
    let store = Arc::clone(&state.store);
    tokio::task::spawn_blocking(move || {
        // Keep capacity reserved if an HTTP client disappears while SQLite is
        // still running. Cancelling the await does not cancel blocking work.
        let _permit = permit;
        operation(Projects::new(store)?)
    })
    .await
    .map_err(|_| {
        ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "project operation could not complete",
        )
    })?
    .map_err(project_error)
}

fn project_error(error: ProjectError) -> ApiError {
    match error {
        ProjectError::Validation(message) => {
            ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, message)
        }
        ProjectError::NotFound => ApiError::new(StatusCode::NOT_FOUND, "project not found"),
        // Do not send SQL, database paths or stored metadata to API callers.
        ProjectError::Store(_) => ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "project storage is unavailable",
        ),
    }
}
