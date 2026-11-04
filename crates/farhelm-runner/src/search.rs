//! `GET /v1/search`: find projects, tasks, runs and conversations across the
//! local workspace. On the same local trust boundary as the project routes,
//! and like them absent from the relay command set.

use std::sync::Arc;

use axum::{
    Json, Router,
    extract::{Query, State},
    http::StatusCode,
    routing::get,
};
use farhelm_app::search::{Search, SearchError};
use farhelm_proto::WorkspaceSearch;
use serde::Deserialize;

use crate::{api::ApiError, state::AppState};

pub(crate) fn routes() -> Router<Arc<AppState>> {
    Router::new().route("/v1/search", get(search))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SearchQuery {
    q: String,
    limit: Option<usize>,
}

async fn search(
    State(state): State<Arc<AppState>>,
    query: Result<Query<SearchQuery>, axum::extract::rejection::QueryRejection>,
) -> Result<Json<WorkspaceSearch>, ApiError> {
    let Query(query) = query.map_err(|_| {
        ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "a search needs `q`, and optionally `limit`",
        )
    })?;
    let permit = Arc::clone(&state.project_requests)
        .try_acquire_owned()
        .map_err(|_| {
            ApiError::new(
                StatusCode::TOO_MANY_REQUESTS,
                "project requests are busy; try again",
            )
        })?;
    // A scan of every project's text: keep it off the executor.
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        Search::new(Arc::clone(&state.store), &state.machine_id)
            .and_then(|search| search.run(&query.q, query.limit))
    })
    .await
    .map_err(|_| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "the search stopped"))?
    .map(Json)
    .map_err(|error| match error {
        SearchError::Validation(message) => {
            ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, message)
        }
        SearchError::Store(_) => ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "the workspace could not be searched",
        ),
    })
}
