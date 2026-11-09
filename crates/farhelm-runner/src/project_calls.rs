//! Project operations for a signed-in device.
//!
//! A device reaches this runner through the relay: an authenticated, encrypted
//! message channel with no route to the loopback HTTP API. Everything the app
//! does in a project is an HTTP handler, so a call runs those same handlers,
//! in-process, through a router holding only [`crate::api::project_routes`].
//! Validation, scoping and errors are therefore the HTTP API's by construction;
//! nothing here decides what a project operation means, and a path outside
//! those routes is a 404.
//!
//! It adds no power a device lacked: [`crate::relay`] has verified the sender
//! before a call gets here, and such a device can already start runs on any path
//! and read their diffs. Commands the agent runs still raise approvals and a
//! change set still waits for review.
//!
//! Two things differ from a local caller. Who decided comes from the verified
//! device and never from the request, and a watch is refused: it has no project
//! screens, and a change set must not be approved from one.

use std::sync::Arc;

use axum::{
    body::Body,
    http::{Method, Request, StatusCode, header},
};
use farhelm_proto::{ProjectCallReply, types::DecidedVia};
use serde_json::{Value, json};
use tower::ServiceExt as _;

use crate::state::AppState;

/// The most a reply may hold. Well above any project page, and a task's diff is
/// capped below this when it is stored.
const MAX_REPLY_BYTES: usize = 32 * 1024 * 1024;

pub async fn dispatch(
    state: &Arc<AppState>,
    call_id: String,
    method: &str,
    path: &str,
    body: Option<Value>,
    via: DecidedVia,
) -> ProjectCallReply {
    let (status, reply) = respond(state, method, path, body, via).await;
    ProjectCallReply {
        project_call: call_id,
        call_status: status.as_u16(),
        call_body: reply,
    }
}

/// A local request says who decided; here the verified device does, whatever
/// the request claims.
fn decided_by_device(
    method: &Method,
    path: &str,
    body: Option<Value>,
    via: DecidedVia,
) -> Option<Value> {
    let route = path.split('?').next().unwrap_or_default();
    if *method != Method::POST || !(route.ends_with("/review") || route.ends_with("/revert")) {
        return body;
    }
    let mut body = body.unwrap_or_else(|| json!({}));
    if let Some(fields) = body.as_object_mut() {
        fields.insert("via".to_owned(), json!(via.as_str()));
    }
    Some(body)
}

async fn respond(
    state: &Arc<AppState>,
    method: &str,
    path: &str,
    body: Option<Value>,
    via: DecidedVia,
) -> (StatusCode, Value) {
    let refuse = |status, message: &str| (status, json!({ "error": message }));
    if !matches!(via, DecidedVia::Phone | DecidedVia::Web) {
        return refuse(
            StatusCode::FORBIDDEN,
            "projects are not available from this device",
        );
    }
    let method = match method {
        "GET" => Method::GET,
        "POST" => Method::POST,
        "PATCH" => Method::PATCH,
        _ => return refuse(StatusCode::METHOD_NOT_ALLOWED, "unsupported method"),
    };
    let body = decided_by_device(&method, path, body, via);

    let mut request = Request::builder().method(method).uri(path);
    let payload = match body {
        Some(body) => {
            request = request.header(header::CONTENT_TYPE, "application/json");
            Body::from(body.to_string())
        }
        None => Body::empty(),
    };
    let Ok(request) = request.body(payload) else {
        return refuse(StatusCode::BAD_REQUEST, "invalid request path");
    };

    let router = crate::api::project_routes().with_state(Arc::clone(state));
    let response = match router.oneshot(request).await {
        Ok(response) => response,
        Err(never) => match never {},
    };
    let status = response.status();
    match axum::body::to_bytes(response.into_body(), MAX_REPLY_BYTES).await {
        Ok(bytes) if bytes.is_empty() => (status, Value::Null),
        // An extractor's refusal is plain text; the client reads `{ error }`.
        Ok(bytes) => (
            status,
            serde_json::from_slice(&bytes)
                .unwrap_or_else(|_| json!({ "error": String::from_utf8_lossy(&bytes) })),
        ),
        Err(_) => refuse(StatusCode::BAD_GATEWAY, "the reply was too large to send"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn who_decided_comes_from_the_device_not_the_request() {
        let claim = json!({ "decision": "approve", "via": "watch" });
        for path in [
            "/v1/projects/p/tasks/t/review",
            "/v1/projects/p/tasks/t/revert?x=1",
        ] {
            let body =
                decided_by_device(&Method::POST, path, Some(claim.clone()), DecidedVia::Phone)
                    .unwrap();
            assert_eq!(body["via"], "phone", "{path}");
            assert_eq!(body["decision"], "approve");
        }
        // A revert may have no body at all, and must still say who.
        let none = decided_by_device(
            &Method::POST,
            "/v1/projects/p/tasks/t/revert",
            None,
            DecidedVia::Web,
        );
        assert_eq!(none.unwrap()["via"], "web");
        // Everything else is left as sent.
        let other = json!({ "title": "A task about /review" });
        assert_eq!(
            decided_by_device(
                &Method::POST,
                "/v1/projects/p/work-items",
                Some(other.clone()),
                DecidedVia::Phone
            ),
            Some(other)
        );
    }
}
