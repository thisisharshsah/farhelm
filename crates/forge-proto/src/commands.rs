//! What a *device* can ask the runner to do.
//!
//! Deliberately small: anything a device can make the runner do is on this list,
//! and adding to it is a decision rather than an accident.
//!
//! Both transports carry these. The localhost HTTP API turns a route and a body
//! into one; the relay link opens a sealed envelope and finds one already. They
//! meet at a single executor, which is what stops a new transport from shipping
//! without the rule that a destructive command cannot be cleared from a watch.

use serde::{Deserialize, Serialize};

use crate::types::Decision;

/// A command from a paired device.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Command {
    /// Approve or deny a pending permission request.
    Decide {
        approval_id: String,
        decision: Decision,
    },
    /// Send a short instruction to a running session (A4).
    Instruct { session_id: String, text: String },
    /// Pause, resume, or skip a plan step (B3).
    PlanControl {
        session_id: String,
        action: PlanAction,
    },
    /// Ask for one session's detail: plan, output tail, pending approval.
    SessionSnapshot { session_id: String },
    /// Ask for one session's cost dashboard — the third snapshot type.
    ///
    /// `since_ms` bounds the window the same way `?since_ms=` does on the HTTP
    /// endpoint. `None` means everything, which is what the screen opens with.
    /// The `default` is load-bearing: a shipped client that omits the field must
    /// keep parsing.
    DashboardSnapshot {
        session_id: String,
        #[serde(default)]
        since_ms: Option<i64>,
    },
    /// Approve or reject a native agent task's proposed change set.
    ///
    /// The diff equivalent of [`Command::Decide`], and the reason the review
    /// screen works from a phone at all. Approving *writes files*, which is why
    /// it goes through the same gated path as everything else here rather than
    /// being an HTTP-only endpoint.
    ReviewTask {
        task_id: String,
        decision: Review,
        #[serde(default)]
        note: Option<String>,
    },
    /// Ask for one task's detail, including the diff to review.
    TaskSnapshot { task_id: String },
    /// Ask for the task list. No diffs — see [`crate::views::TaskView`].
    TaskList,
    /// Take an applied change set back off the working tree.
    ///
    /// Available from a phone for the same reason approving is: the overlay kept
    /// both sides, so this writes back only what the agent replaced, and it
    /// refuses outright if anything has moved since.
    RevertTask { task_id: String },
    /// Ask for the current fleet.
    ///
    /// A device on the relay has no request/response channel — it receives
    /// events on one socket and sends on the same one — so "what is the state
    /// right now" has to be a message like any other. The HTTP client uses
    /// `GET /v1/fleet` instead and never sends this.
    Snapshot,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlanAction {
    Pause,
    Resume,
    Skip,
}

/// A reviewer's verdict on a proposed change set.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Review {
    Approve,
    Reject,
}
