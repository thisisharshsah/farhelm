//! Storage boundary.
//!
//! Everything above this line talks to the [`Store`] trait, never to SQLite.
//! That keeps the Postgres swap for the team tier a new impl rather than a
//! rewrite — and lets the gateway be tested against an in-memory database.
//!
//! The trait is synchronous. SQLite is a single-writer embedded engine, so
//! there is nothing to await; async callers wrap these in `spawn_blocking`.

pub mod sqlite;

use crate::types::{
    AgentTask, Approval, BatchItem, BatchStatus, Budget, DecidedVia, Decision, Device, Machine,
    Plan, PlanStep, Repo, Session, TaskStatus, UsageEvent,
};

pub use sqlite::SqliteStore;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Risk;

    fn decided(decision: Decision) -> Approval {
        Approval {
            id: "a".into(),
            session_id: "s".into(),
            tool: "bash".into(),
            payload: "rm -rf /".into(),
            risk: Risk::Destructive,
            decision: Some(decision),
            decided_via: Some(DecidedVia::Phone),
            requested_at: 0,
            decided_at: Some(1),
        }
    }

    #[test]
    fn both_decision_outcomes_expose_the_stored_approval() {
        let approval = decided(Decision::Denied);
        assert_eq!(
            DecisionOutcome::Recorded(approval.clone())
                .approval()
                .decision,
            Some(Decision::Denied)
        );
        assert_eq!(
            DecisionOutcome::AlreadyDecided(approval)
                .approval()
                .decision,
            Some(Decision::Denied)
        );
    }
}

#[derive(Debug)]
pub enum StoreError {
    /// The row exists but a `TEXT` column held a value no enum variant matches.
    Corrupt(String),
    NotFound(String),
    Backend(Box<dyn std::error::Error + Send + Sync>),
}

impl std::fmt::Display for StoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StoreError::Corrupt(msg) => write!(f, "corrupt row: {msg}"),
            StoreError::NotFound(what) => write!(f, "not found: {what}"),
            StoreError::Backend(err) => write!(f, "storage backend: {err}"),
        }
    }
}

impl std::error::Error for StoreError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            StoreError::Backend(err) => Some(err.as_ref()),
            _ => None,
        }
    }
}

pub type Result<T> = std::result::Result<T, StoreError>;

/// A half-open time range for ledger queries, unix ms.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TimeRange {
    /// Inclusive lower bound. `None` = since the beginning.
    pub since_ms: Option<i64>,
    /// Exclusive upper bound. `None` = up to now.
    pub until_ms: Option<i64>,
}

impl TimeRange {
    pub const ALL: TimeRange = TimeRange {
        since_ms: None,
        until_ms: None,
    };

    pub const fn since(since_ms: i64) -> Self {
        Self {
            since_ms: Some(since_ms),
            until_ms: None,
        }
    }
}

/// Declares the [`Store`] port once, and derives every forwarding impl from it.
///
/// The trait has forty-odd methods and three implementations that are pure
/// delegation: `Arc<S>`, `&S`, and — in tests — decorators that wrap a real
/// store to observe it. Those were written out by hand, which made adding a
/// method a four-place edit and made a *typo* in one of them a silent bug: a
/// forwarding impl that called the wrong method still compiles, because every
/// one of them has a plausible-looking sibling with the same shape.
///
/// Now there is one list, and the two delegating impls are generated from it.
///
/// Only `Arc<S>` and `&S` are generated: both are used here, where the `Result`
/// alias and the type imports resolve. Exporting a general forwarding macro for
/// decorators in other crates would mean spelling every type in every signature
/// as an absolute path, which costs more legibility than the decorators are
/// worth.
macro_rules! store_port {
    (
        $(
            $(#[$meta:meta])*
            fn $name:ident(&self $(, $arg:ident : $ty:ty)* $(,)?) -> $ret:ty;
        )*
    ) => {
        /// Everything above this line talks to `Store`, never to SQLite.
        ///
        /// Synchronous on purpose: SQLite is a single-writer embedded engine, so
        /// there is nothing to await.
        pub trait Store {
            $(
                $(#[$meta])*
                fn $name(&self $(, $arg: $ty)*) -> $ret;
            )*
        }

        /// Shared stores are stores, so a long-lived component can hold an `Arc`
        /// of one without the trait needing to know.
        impl<S: Store + ?Sized> Store for std::sync::Arc<S> {
            $( fn $name(&self $(, $arg: $ty)*) -> $ret { (**self).$name($($arg),*) } )*
        }

        /// Borrowed stores are stores. Lets a caller hand a `&SqliteStore` to
        /// anything generic over `S: Store` — notably [`crate::ledger::Ledger`],
        /// which takes ownership — without giving up the original handle.
        impl<S: Store + ?Sized> Store for &S {
            $( fn $name(&self $(, $arg: $ty)*) -> $ret { (**self).$name($($arg),*) } )*
        }

    };
}

store_port! {
    fn upsert_machine(&self, machine: &Machine) -> Result<()>;
    fn get_machine(&self, id: &str) -> Result<Option<Machine>>;

    fn upsert_repo(&self, repo: &Repo) -> Result<()>;
    fn get_repo(&self, id: &str) -> Result<Option<Repo>>;

    fn upsert_session(&self, session: &Session) -> Result<()>;
    fn get_session(&self, id: &str) -> Result<Option<Session>>;
    fn list_sessions(&self) -> Result<Vec<Session>>;

    /// Find a session by the *agent's* session id. This is how a hook callback
    /// re-attaches to the session it belongs to instead of creating a new one
    /// on every tool call.
    fn find_session_by_agent_id(&self, agent_session_id: &str) -> Result<Option<Session>>;

    /// Repos are unique per (machine, path), which is how a hook's `cwd`
    /// resolves to the repo it is working in.
    fn find_repo_by_path(&self, machine_id: &str, path: &str) -> Result<Option<Repo>>;

    /// Append one ledger row and add its cost to `session.spent_usd`.
    ///
    /// Both writes happen in one transaction: a recorded call that did not move
    /// the budget would let a runaway loop slip past the stage-1 hard stop.
    fn record_usage(&self, event: &UsageEvent) -> Result<()>;

    fn list_usage(&self, session_id: &str, range: TimeRange) -> Result<Vec<UsageEvent>>;

    /// Budget for one session: its own cap and its own spend.
    fn session_budget(&self, session_id: &str) -> Result<Budget>;

    /// Budget for a repo: the repo cap against the summed spend of every
    /// session in it.
    fn repo_budget(&self, repo_id: &str) -> Result<Budget>;

    fn upsert_plan(&self, plan: &Plan) -> Result<()>;
    fn get_plan(&self, id: &str) -> Result<Option<Plan>>;

    /// Replace a plan's steps wholesale, in one transaction.
    ///
    /// Rebuilding rather than diffing is deliberate: `PLAN.md` is the source of
    /// truth, so when the file changes the mirror is regenerated from it. Any
    /// `checkpoint_sha` the caller wants to keep must be carried in `steps`.
    fn replace_plan_steps(&self, plan_id: &str, steps: &[PlanStep]) -> Result<()>;

    fn list_plan_steps(&self, plan_id: &str) -> Result<Vec<PlanStep>>;

    /// Persist one step's status/checkpoint after a state-machine transition.
    fn update_plan_step(&self, step: &PlanStep) -> Result<()>;

    fn create_approval(&self, approval: &Approval) -> Result<()>;
    fn get_approval(&self, id: &str) -> Result<Option<Approval>>;

    /// Every approval still waiting on a human, oldest first — what the fleet
    /// view and the push trigger read.
    fn list_pending_approvals(&self) -> Result<Vec<Approval>>;

    /* ------------------------------------------------- batch queue (C6) */

    /// Queue a deferrable call instead of dispatching it live.
    fn enqueue_batch_item(&self, item: &BatchItem) -> Result<()>;

    /// Everything still waiting to be submitted, oldest first.
    fn list_queued_batch_items(&self, limit: usize) -> Result<Vec<BatchItem>>;

    /// Every item belonging to a batch that is in flight.
    fn list_submitted_batch_items(&self) -> Result<Vec<BatchItem>>;

    fn get_batch_item(&self, id: &str) -> Result<Option<BatchItem>>;

    /// Items for one session, newest first — what the UI shows.
    fn list_batch_items_for_session(&self, session_id: &str) -> Result<Vec<BatchItem>>;

    /// Mark items as sent, recording the provider's batch id.
    ///
    /// One statement per call rather than per item so a crash mid-flush cannot
    /// leave half a batch looking queued and half looking submitted — which
    /// would resubmit the queued half and pay for it twice.
    fn mark_batch_submitted(
        &self,
        item_ids: &[String],
        batch_id: &str,
        submitted_at: i64,
    ) -> Result<()>;

    /// Record what came back for one item.
    fn settle_batch_item(
        &self,
        custom_id: &str,
        status: BatchStatus,
        response_text: Option<&str>,
        error: Option<&str>,
        settled_at: i64,
    ) -> Result<()>;

    /* --------------------------------------------- native agent tasks */

    /// Create or update a task row.
    fn upsert_task(&self, task: &AgentTask) -> Result<()>;

    fn get_task(&self, id: &str) -> Result<Option<AgentTask>>;

    /// Tasks newest first — what the task list renders.
    fn list_tasks(&self, limit: usize) -> Result<Vec<AgentTask>>;

    /// Every task still waiting on a human, oldest first. The diff-review
    /// counterpart of [`Store::list_pending_approvals`], and read by the same
    /// push trigger.
    fn list_tasks_awaiting_review(&self) -> Result<Vec<AgentTask>>;

    /// Settle a task, resolving the race between two devices reviewing the same
    /// diff. Returns what was stored, and whether this caller's decision is the
    /// one that stuck — the same contract as [`Store::decide_approval`],
    /// because applying a change set twice is exactly as bad as approving a
    /// command twice.
    fn decide_task(
        &self,
        id: &str,
        status: TaskStatus,
        via: DecidedVia,
        note: Option<&str>,
        decided_at: i64,
    ) -> Result<TaskOutcome>;

    /// Record a decision. Two devices can see the same notification, so this
    /// resolves the race explicitly rather than letting the last tap win.
    fn decide_approval(
        &self,
        id: &str,
        decision: Decision,
        via: DecidedVia,
        decided_at: i64,
    ) -> Result<DecisionOutcome>;

    /// Pipeline stage 3. Returns the cached response only if it has not
    /// expired, and counts the hit — a cache nobody reads from is a bug worth
    /// seeing in the dashboard.
    fn cache_get(&self, key_hash: &str, now_ms: i64) -> Result<Option<String>>;

    /// Store a response under its key. Overwrites any existing entry, so a
    /// re-run after a prompt change refreshes rather than accumulating.
    fn cache_put(&self, key_hash: &str, response: &str, now_ms: i64, ttl_ms: i64) -> Result<()>;

    /// Drop expired entries. Returns how many went.
    fn cache_purge_expired(&self, now_ms: i64) -> Result<usize>;

    /// Register a paired device, or update one that re-paired.
    fn upsert_device(&self, device: &Device) -> Result<()>;

    /// Every device allowed to send this runner commands. The relay link
    /// verifies incoming envelopes against exactly this list.
    fn list_devices(&self) -> Result<Vec<Device>>;

    fn get_device(&self, id: &str) -> Result<Option<Device>>;
}

/// The result of racing a task review against another device.
#[derive(Debug, Clone, PartialEq)]
pub enum TaskOutcome {
    /// This caller's decision is the one that stuck.
    Recorded(AgentTask),
    /// Someone else got there first; the returned task is what was stored.
    AlreadyDecided(AgentTask),
}

impl TaskOutcome {
    pub fn task(&self) -> &AgentTask {
        match self {
            TaskOutcome::Recorded(task) | TaskOutcome::AlreadyDecided(task) => task,
        }
    }

    pub fn was_recorded(&self) -> bool {
        matches!(self, TaskOutcome::Recorded(_))
    }
}

/// The result of racing a decision against another device.
#[derive(Debug, Clone, PartialEq)]
pub enum DecisionOutcome {
    /// This caller's decision is the one that stuck.
    Recorded(Approval),
    /// Someone else got there first; the returned approval is what was stored.
    AlreadyDecided(Approval),
}

impl DecisionOutcome {
    pub fn approval(&self) -> &Approval {
        match self {
            DecisionOutcome::Recorded(approval) | DecisionOutcome::AlreadyDecided(approval) => {
                approval
            }
        }
    }
}
