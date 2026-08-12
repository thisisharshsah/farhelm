//! Storage boundary.
//!
//! Everything above this line talks to the [`Store`] trait, never to SQLite.
//! That keeps the Postgres swap for the team tier a new impl rather than a
//! rewrite — and lets the gateway be tested against an in-memory database.
//!
//! The trait is synchronous. SQLite is a single-writer embedded engine, so
//! there is nothing to await; async callers wrap these in `spawn_blocking`.

use forge_proto::types::{
    AgentTask, Approval, BatchItem, BatchStatus, Budget, DecidedVia, Decision, Device, Machine,
    Plan, PlanStep, Repo, Session, TaskStatus, UsageEvent,
};

#[cfg(test)]
mod tests {
    use super::*;
    use forge_proto::types::Risk;

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

/// Spend and cache behaviour over a window, summed by the store.
///
/// Exists so the fleet's cost strip does not have to load every ledger row to
/// add up three numbers. `SUM` in SQL is the store's job; the previous shape —
/// `list_usage` per session, folded in Rust — moved the whole 24-hour ledger
/// across the boundary on every home-screen fetch, and every phone that woke up
/// asked for it again.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct UsageTotals {
    pub cost_usd: f64,
    /// Tokens served from the provider's prefix cache.
    pub cache_read_tokens: u64,
    /// Tokens billed as fresh input. The cache-read ratio is
    /// `cache_read / (cache_read + input)` — see [`UsageTotals::cache_read_ratio`].
    pub input_tokens: u64,
    pub calls: usize,
}

impl UsageTotals {
    /// Appendix A's headline metric. `None` when nothing billable flowed, so an
    /// idle fleet reads as "no data" rather than 0% and drags an average down.
    pub fn cache_read_ratio(&self) -> Option<f64> {
        let denominator = self.cache_read_tokens + self.input_tokens;
        (denominator > 0).then(|| self.cache_read_tokens as f64 / denominator as f64)
    }
}

/// Declares one role port, and derives its forwarding impls.
///
/// Every port here has three implementations that are pure delegation: the real
/// store, `Arc<S>`, and `&S`. Those were written out by hand — 294 lines whose
/// entire content was `(**self).method(args)` — which made adding a method a
/// multi-place edit, and made a *typo* in one of them a silent bug: a forwarding
/// impl that delegates to the wrong method still compiles, because every method
/// in this file has a plausible-looking sibling with the same shape.
///
/// Only `Arc<S>` and `&S` are generated: both are used here, where the `Result`
/// alias and the type imports resolve. Exporting a general forwarding macro for
/// decorators in other crates would mean spelling every type in every signature
/// as an absolute path, which costs more legibility than the decorators are
/// worth.
macro_rules! store_port {
    (
        $(#[$trait_meta:meta])*
        $port:ident {
            $(
                $(#[$meta:meta])*
                fn $name:ident(&self $(, $arg:ident : $ty:ty)* $(,)?) -> $ret:ty;
            )*
        }
    ) => {
        $(#[$trait_meta])*
        pub trait $port {
            $(
                $(#[$meta])*
                fn $name(&self $(, $arg: $ty)*) -> $ret;
            )*
        }

        /// Shared stores are stores, so a long-lived component can hold an `Arc`
        /// of one without the trait needing to know.
        impl<S: $port + ?Sized> $port for std::sync::Arc<S> {
            $( fn $name(&self $(, $arg: $ty)*) -> $ret { (**self).$name($($arg),*) } )*
        }

        /// Borrowed stores are stores. Lets a caller hand a `&SqliteStore` to
        /// anything generic over the port — notably [`crate::ledger::Ledger`],
        /// which takes ownership — without giving up the original handle.
        impl<S: $port + ?Sized> $port for &S {
            $( fn $name(&self $(, $arg: $ty)*) -> $ret { (**self).$name($($arg),*) } )*
        }
    };
}

store_port! {
    /// Machines and the repositories on them — the topology a session hangs off.
    FleetStore {
    fn upsert_machine(&self, machine: &Machine) -> Result<()>;

    fn get_machine(&self, id: &str) -> Result<Option<Machine>>;

    fn upsert_repo(&self, repo: &Repo) -> Result<()>;

    fn get_repo(&self, id: &str) -> Result<Option<Repo>>;

    /// Repos are unique per (machine, path), which is how a hook's `cwd`
    /// resolves to the repo it is working in.
    fn find_repo_by_path(&self, machine_id: &str, path: &str) -> Result<Option<Repo>>;
    }
}

store_port! {
    /// Agent process lifecycles.
    SessionStore {
    fn upsert_session(&self, session: &Session) -> Result<()>;

    fn get_session(&self, id: &str) -> Result<Option<Session>>;

    fn list_sessions(&self) -> Result<Vec<Session>>;

    /// Find a session by the *agent's* session id. This is how a hook callback
    /// re-attaches to the session it belongs to instead of creating a new one
    /// on every tool call.
    fn find_session_by_agent_id(&self, agent_session_id: &str) -> Result<Option<Session>>;
    }
}

store_port! {
    /// The append-only cost record, and the budgets read off it.
///
/// The narrowest port and the most widely used: the gateway consults it on
/// every model call and needs nothing else from storage.
    LedgerStore {
    /// Append one ledger row and add its cost to `session.spent_usd`.
    ///
    /// Both writes happen in one transaction: a recorded call that did not move
    /// the budget would let a runaway loop slip past the stage-1 hard stop.
    fn record_usage(&self, event: &UsageEvent) -> Result<()>;

    fn list_usage(&self, session_id: &str, range: TimeRange) -> Result<Vec<UsageEvent>>;

    /// Spend and cache behaviour across *every* session in a window.
    ///
    /// The fleet-wide counterpart of [`LedgerStore::list_usage`], and the reason
    /// it exists separately: the home screen needs three totals, not the rows.
    fn usage_totals(&self, range: TimeRange) -> Result<UsageTotals>;

    /// Budget for one session: its own cap and its own spend.
    fn session_budget(&self, session_id: &str) -> Result<Budget>;

    /// Budget for a repo: the repo cap against the summed spend of every
    /// session in it.
    fn repo_budget(&self, repo_id: &str) -> Result<Budget>;
    }
}

store_port! {
    /// `PLAN.md`, mirrored.
    PlanStore {
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
    }
}

store_port! {
    /// Permission requests and their outcomes. Kept forever: both the audit
/// trail and the training data for auto-approve policy.
    ApprovalStore {
    fn create_approval(&self, approval: &Approval) -> Result<()>;

    fn get_approval(&self, id: &str) -> Result<Option<Approval>>;

    /// Every approval still waiting on a human, oldest first — what the fleet
    /// view and the push trigger read.
    fn list_pending_approvals(&self) -> Result<Vec<Approval>>;

    /// Record a decision. Two devices can see the same notification, so this
    /// resolves the race explicitly rather than letting the last tap win.
    fn decide_approval(
        &self,
        id: &str,
        decision: Decision,
        via: DecidedVia,
        decided_at: i64,
    ) -> Result<DecisionOutcome>;
    }
}

store_port! {
    /// The deferred-work queue (C6).
    BatchStore {
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
    }
}

store_port! {
    /// Native agent tasks and the change sets awaiting review.
    TaskStore {
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
    }
}

store_port! {
    /// Pipeline stage 3.
    ResponseCache {
    /// Pipeline stage 3. Returns the cached response only if it has not
    /// expired, and counts the hit — a cache nobody reads from is a bug worth
    /// seeing in the dashboard.
    fn cache_get(&self, key_hash: &str, now_ms: i64) -> Result<Option<String>>;

    /// Store a response under its key. Overwrites any existing entry, so a
    /// re-run after a prompt change refreshes rather than accumulating.
    fn cache_put(&self, key_hash: &str, response: &str, now_ms: i64, ttl_ms: i64) -> Result<()>;

    /// Drop expired entries. Returns how many went.
    fn cache_purge_expired(&self, now_ms: i64) -> Result<usize>;
    }
}

store_port! {
    /// Paired devices. The relay link verifies every incoming envelope
/// against exactly this list.
    DeviceStore {
    /// Register a paired device, or update one that re-paired.
    fn upsert_device(&self, device: &Device) -> Result<()>;

    /// Every device allowed to send this runner commands. The relay link
    /// verifies incoming envelopes against exactly this list.
    fn list_devices(&self) -> Result<Vec<Device>>;

    fn get_device(&self, id: &str) -> Result<Option<Device>>;

    /// Forget a device. Returns whether there was one to forget.
    ///
    /// Revocation, and the reason it exists as a port rather than as a delete
    /// somebody writes inline: once a runner is enrolled with a control plane,
    /// the authoritative device list lives there, and the runner reconciles to
    /// it on every heartbeat. Without this, removing a phone in the web app
    /// would leave the runner still sealing events to its key.
    fn remove_device(&self, id: &str) -> Result<bool>;
    }
}

/// Everything, for a caller that genuinely needs everything.
///
/// The runner's `AppState` holds one store and its handlers touch all of it, so
/// a single bound stays the honest signature there. Narrower callers name only
/// the ports they use — `Ledger` takes a [`LedgerStore`], and the gateway's four
/// ports are the reason a test double for it is now a few methods rather than
/// forty.
///
/// No methods of its own: it is an alias, and the blanket impl means anything
/// implementing the parts implements the whole without saying so.
pub trait Store:
    FleetStore
    + SessionStore
    + LedgerStore
    + PlanStore
    + ApprovalStore
    + BatchStore
    + TaskStore
    + ResponseCache
    + DeviceStore
{
}

/// Every port at once, for a caller that wants the whole surface in scope.
///
/// Rust resolves a method through the trait that declares it, not through a
/// supertrait, so `use store::Store` alone brings in the *bound* and none of the
/// methods. That is the one ergonomic cost of splitting the port, and this is
/// the answer to it: callers that genuinely want everything glob this, and
/// callers that want four ports name four ports.
pub mod prelude {
    pub use super::{
        ApprovalStore, BatchStore, DeviceStore, FleetStore, LedgerStore, PlanStore, ResponseCache,
        SessionStore, Store, TaskStore,
    };
}

impl<T> Store for T where
    T: FleetStore
        + SessionStore
        + LedgerStore
        + PlanStore
        + ApprovalStore
        + BatchStore
        + TaskStore
        + ResponseCache
        + DeviceStore
{
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
