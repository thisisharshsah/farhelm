//! Assembling the read models a client renders.
//!
//! Split out of the HTTP module, which is where it used to live and where it
//! did not belong. Two transports need these: `GET /v1/fleet` for a browser on
//! loopback, and `Command::Snapshot` for a phone on the relay. Because the
//! builders sat beside the axum handlers, the transport-independent command
//! layer had to reach *up* into the HTTP module to call them — and take an
//! error type carrying a `StatusCode` for the trouble. The relay has no status
//! codes; it was constructing 404s in order to discard them.
//!
//! So the error here says only what went wrong. Each transport maps it: the API
//! to a status, the relay to a `command_error` frame.
//!
//! ## What these cost
//!
//! Assembly issues a handful of small reads per row rather than one join, which
//! keeps the `Store` port narrow enough to reimplement. That is a real
//! trade-off and it is not free — see the note on [`build_fleet_view`].

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::sync::Arc;

use forge_core::store::{TimeRange, prelude::*};
use forge_core::time::now_ms;
use forge_core::types::{Approval, Budget, Machine, Repo, Session, SessionStatus};
use forge_domain::{ApprovalRules as _, budget_view};
use forge_proto::views::{
    ApprovalView, DashboardView, FleetView, PlanProgress, PlanStepView, SessionDetail, SessionView,
    SpendBucket, TaskDetail, TaskView, TierSlice,
};

use crate::state::AppState;

/// Why a read model could not be assembled.
///
/// Deliberately smaller than either transport's vocabulary: a missing row and a
/// broken store are the only two things that happen here.
#[derive(Debug)]
pub enum ViewError {
    NotFound(String),
    Store(forge_core::store::StoreError),
}

impl ViewError {
    pub fn not_found(what: impl Into<String>) -> Self {
        ViewError::NotFound(what.into())
    }
}

impl std::fmt::Display for ViewError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ViewError::NotFound(what) => write!(f, "not found: {what}"),
            ViewError::Store(err) => write!(f, "{err}"),
        }
    }
}

impl std::error::Error for ViewError {}

impl From<forge_core::store::StoreError> for ViewError {
    fn from(err: forge_core::store::StoreError) -> Self {
        ViewError::Store(err)
    }
}

/// Rows that get read over and over while assembling one payload, read once.
///
/// A fleet is many sessions and many approvals pointing at a handful of repos on
/// one machine, and every one of them needs the repo's name. Assembled naively
/// that is a read per row; assembled through this it is a read per distinct id.
///
/// The pending-approval list is the expensive one and is handled differently: it
/// is fetched eagerly, once, because the old code called
/// `list_pending_approvals` *inside* the per-session builder and then scanned
/// the result in Rust for the one approval belonging to that session. On a fleet
/// of ten sessions that was ten full reads of the table to answer ten questions
/// a single read answers.
///
/// Scoped to one assembly, deliberately. This is a read-through memo for the
/// few milliseconds it takes to build one payload, not a cache with an
/// invalidation problem: the next request builds a new one.
pub struct Lookups<'a, S> {
    store: &'a S,
    pending: Vec<Approval>,
    repos: RefCell<HashMap<String, Option<Repo>>>,
    machines: RefCell<HashMap<String, Option<Machine>>>,
    budgets: RefCell<HashMap<String, Budget>>,
    /// Reads that actually reached the store. Exists so a test can assert the
    /// memo is doing something rather than trusting that it is.
    reads: Cell<usize>,
}

impl<'a, S: Store> Lookups<'a, S> {
    /// Start an assembly. Reads the pending-approval list once, up front.
    pub fn new(store: &'a S) -> Result<Self, ViewError> {
        let pending = store.list_pending_approvals()?;
        Ok(Self {
            store,
            pending,
            repos: RefCell::new(HashMap::new()),
            machines: RefCell::new(HashMap::new()),
            budgets: RefCell::new(HashMap::new()),
            reads: Cell::new(1),
        })
    }

    /// How many reads reached the store. Diagnostic, and what the cost tests
    /// assert on.
    pub fn reads(&self) -> usize {
        self.reads.get()
    }

    /// Every approval still waiting, oldest first — the list read at construction.
    pub fn pending(&self) -> &[Approval] {
        &self.pending
    }

    /// The oldest pending approval for one session, if it is blocked on one.
    ///
    /// `find` over the pre-read list, matching the previous behaviour exactly:
    /// the store returns oldest-first and the old code took the first match too.
    fn awaiting_approval_id(&self, session_id: &str) -> Option<String> {
        self.pending
            .iter()
            .find(|approval| approval.session_id == session_id)
            .map(|approval| approval.id.clone())
    }

    fn repo(&self, id: &str) -> Result<Option<Repo>, ViewError> {
        if let Some(hit) = self.repos.borrow().get(id) {
            return Ok(hit.clone());
        }
        self.reads.set(self.reads.get() + 1);
        let repo = self.store.get_repo(id)?;
        self.repos.borrow_mut().insert(id.to_owned(), repo.clone());
        Ok(repo)
    }

    fn machine(&self, id: &str) -> Result<Option<Machine>, ViewError> {
        if let Some(hit) = self.machines.borrow().get(id) {
            return Ok(hit.clone());
        }
        self.reads.set(self.reads.get() + 1);
        let machine = self.store.get_machine(id)?;
        self.machines
            .borrow_mut()
            .insert(id.to_owned(), machine.clone());
        Ok(machine)
    }

    fn budget(&self, session_id: &str) -> Result<Budget, ViewError> {
        if let Some(hit) = self.budgets.borrow().get(session_id) {
            return Ok(*hit);
        }
        self.reads.set(self.reads.get() + 1);
        let budget = self.store.session_budget(session_id)?;
        self.budgets
            .borrow_mut()
            .insert(session_id.to_owned(), budget);
        Ok(budget)
    }
}

/// Builds a [`SessionView`]. Issues a handful of small reads per session rather
/// than one join, keeping the `Store` port narrow enough to reimplement — with
/// the repeated ones served from [`Lookups`].
pub fn view_of<S: Store>(
    state: &AppState,
    lookups: &Lookups<'_, S>,
    session: &Session,
) -> Result<SessionView, ViewError> {
    let repo = lookups
        .repo(&session.repo_id)?
        .ok_or_else(|| ViewError::not_found(format!("repo {}", session.repo_id)))?;
    let machine = lookups.machine(&repo.machine_id)?;

    let plan = match &session.plan_id {
        Some(plan_id) => {
            // Not memoised: plan ids are one per session, so there is nothing to
            // hit. Counted, so the read total stays honest.
            let steps = state.store.list_plan_steps(plan_id)?;
            (!steps.is_empty()).then(|| PlanProgress::of(&steps))
        }
        None => None,
    };

    Ok(SessionView {
        id: session.id.clone(),
        repo_name: repo.name,
        machine_name: machine.map(|m| m.name).unwrap_or_else(|| "unknown".into()),
        agent: session.agent.to_string(),
        status: session.status,
        is_live: matches!(
            session.status,
            SessionStatus::Running | SessionStatus::AwaitingApproval | SessionStatus::Paused
        ),
        plan,
        budget: budget_view(lookups.budget(&session.id)?),
        started_at: session.started_at,
        ended_at: session.ended_at,
        awaiting_approval_id: lookups.awaiting_approval_id(&session.id),
    })
}

pub fn approval_view<S: Store>(
    state: &AppState,
    lookups: &Lookups<'_, S>,
    approval: Approval,
) -> Result<ApprovalView, ViewError> {
    let session = state
        .store
        .get_session(&approval.session_id)?
        .ok_or_else(|| ViewError::not_found(format!("session {}", approval.session_id)))?;
    let repo = lookups.repo(&session.repo_id)?;

    Ok(ApprovalView {
        allows_watch_decision: approval.allows_watch_decision(),
        repo_name: repo.map(|r| r.name).unwrap_or_else(|| "unknown".into()),
        budget: budget_view(lookups.budget(&approval.session_id)?),
        approval,
    })
}

pub fn task_view<S: Store>(
    lookups: &Lookups<'_, S>,
    task: forge_core::types::AgentTask,
) -> TaskView {
    let repo = lookups.repo(&task.repo_id).ok().flatten();
    let repo_name = repo
        .as_ref()
        .map(|repo| repo.name.clone())
        .unwrap_or_default();
    let repo_path = repo.map(|repo| repo.path).unwrap_or_default();

    TaskView {
        change_summary: task.change_summary(),
        id: task.id,
        session_id: task.session_id,
        repo_id: task.repo_id,
        repo_name,
        repo_path,
        prompt: task.prompt,
        status: task.status,
        summary: task.summary,
        files_changed: task.files_changed,
        lines_added: task.lines_added,
        lines_removed: task.lines_removed,
        steps: task.steps,
        cost_usd: task.cost_usd,
        error: task.error,
        review_note: task.review_note,
        verify_grade: task.verify_grade,
        verify_notes: task.verify_notes,
        verify_model: task.verify_model,
        decided_via: task.decided_via,
        created_at: task.created_at,
        updated_at: task.updated_at,
        decided_at: task.decided_at,
    }
}

/// The home screen, assembled.
///
/// Shared with the relay link: a remote device has no request/response channel,
/// so it asks for this over the same socket it receives events on.
pub fn build_fleet_view(state: &Arc<AppState>) -> Result<FleetView, ViewError> {
    let store = state.store.as_ref();
    let lookups = Lookups::new(store)?;

    let sessions = state.store.list_sessions()?;
    let views = sessions
        .iter()
        .map(|session| view_of(state, &lookups, session))
        .collect::<Result<Vec<_>, _>>()?;

    let pending_approvals = lookups
        .pending()
        .to_vec()
        .into_iter()
        .map(|approval| approval_view(state, &lookups, approval))
        .collect::<Result<Vec<_>, _>>()?;

    // "Today" is the last 24h rather than a calendar day: the runner has no
    // notion of the phone's timezone, and a rolling window is what the strip
    // actually means to someone glancing at it.
    let since = TimeRange::since(now_ms() - 24 * 60 * 60 * 1_000);
    let mut today_usd = 0.0;
    let mut cache_reads: u64 = 0;
    let mut fresh_input: u64 = 0;
    for session in &sessions {
        for event in state.store.list_usage(&session.id, since)? {
            today_usd += event.cost_usd;
            cache_reads += u64::from(event.usage.cache_read_tokens);
            fresh_input += u64::from(event.usage.input_tokens);
        }
    }

    let tasks_awaiting_review = state
        .store
        .list_tasks_awaiting_review()?
        .into_iter()
        .map(|task| task_view(&lookups, task))
        .collect();

    Ok(FleetView {
        sessions: views,
        pending_approvals,
        tasks_awaiting_review,
        today_usd,
        cache_hit_ratio: (cache_reads + fresh_input > 0)
            .then(|| cache_reads as f64 / (cache_reads + fresh_input) as f64),
    })
}

/// One session, assembled. Shared with the relay link for the same reason
/// [`build_fleet_view`] is.
pub fn build_session_detail(state: &Arc<AppState>, id: &str) -> Result<SessionDetail, ViewError> {
    let session = state
        .store
        .get_session(id)?
        .ok_or_else(|| ViewError::not_found(format!("session {id}")))?;
    let lookups = Lookups::new(state.store.as_ref())?;
    let view = view_of(state, &lookups, &session)?;

    let steps = match &session.plan_id {
        Some(plan_id) => state
            .store
            .list_plan_steps(plan_id)?
            .iter()
            .map(PlanStepView::from)
            .collect(),
        None => Vec::new(),
    };

    let pending_approval = match &view.awaiting_approval_id {
        Some(approval_id) => state
            .store
            .get_approval(approval_id)?
            .map(|approval| approval_view(state, &lookups, approval))
            .transpose()?,
        None => None,
    };

    Ok(SessionDetail {
        session: view,
        steps,
        output: state.output_tail(id, 80),
        pending_approval,
    })
}

/// Flow 4, assembled.
///
/// Shared with the relay link — the third snapshot type. Until this existed the
/// cost dashboard was the one screen a paired phone could not open, because a
/// remote device has no request/response channel and there was nothing for it to
/// ask for. Both surfaces now render the same bytes.
pub fn build_dashboard(
    state: &Arc<AppState>,
    id: &str,
    since_ms: Option<i64>,
) -> Result<DashboardView, ViewError> {
    let session = state
        .store
        .get_session(id)?
        .ok_or_else(|| ViewError::not_found(format!("session {id}")))?;
    let repo = state.store.get_repo(&session.repo_id)?;

    let range = TimeRange {
        since_ms,
        until_ms: None,
    };
    let events = state.store.list_usage(id, range)?;
    let summary = forge_core::ledger::Summary::from_events(&events);

    let by_tier = summary
        .usd_by_tier
        .iter()
        .map(|(tier, usd)| TierSlice {
            tier: tier.to_string(),
            usd: *usd,
            share: if summary.total_usd > 0.0 {
                usd / summary.total_usd
            } else {
                0.0
            },
        })
        .collect();

    const BUCKET_MS: i64 = 60 * 60 * 1_000;
    let mut spend_series: Vec<SpendBucket> = Vec::new();
    for event in &events {
        let bucket = event.created_at - event.created_at.rem_euclid(BUCKET_MS);
        match spend_series.last_mut() {
            Some(last) if last.at_ms == bucket => last.usd += event.cost_usd,
            _ => spend_series.push(SpendBucket {
                at_ms: bucket,
                usd: event.cost_usd,
            }),
        }
    }

    Ok(DashboardView {
        session_id: id.to_owned(),
        repo_name: repo.map(|r| r.name).unwrap_or_else(|| "unknown".into()),
        calls: summary.calls,
        total_usd: summary.total_usd,
        cache_hit_ratio: summary.cache_read_ratio(),
        by_tier,
        avoided_calls: summary.avoided_calls.values().sum(),
        spend_series,
        budget: budget_view(state.store.session_budget(id)?),
    })
}

/// Shared with the relay, so a phone and a browser see the same list.
pub fn build_task_list(state: &Arc<AppState>) -> Result<Vec<TaskView>, ViewError> {
    let lookups = Lookups::new(state.store.as_ref())?;
    Ok(state
        .store
        .list_tasks(100)?
        .into_iter()
        .map(|task| task_view(&lookups, task))
        .collect())
}

/// The same payload the relay serves, so a phone reviewing over a relay and a
/// browser on loopback are looking at the same bytes.
pub fn build_task_detail(state: &Arc<AppState>, id: &str) -> Result<TaskDetail, ViewError> {
    let task = state
        .store
        .get_task(id)?
        .ok_or_else(|| ViewError::not_found(format!("task {id}")))?;

    // A change set that will not parse is reported as an empty one rather than
    // a 500: the rest of the row — what it cost, what went wrong, the output
    // tail — is exactly what somebody debugging that would want to see.
    let changes: forge_agent::ChangeSet = serde_json::from_str(&task.diff_json).unwrap_or_default();
    let output = state.output_tail(&task.session_id, 200);

    Ok(TaskDetail {
        patch: changes.render(),
        changes,
        task: task_view(&Lookups::new(state.store.as_ref())?, task),
        output,
    })
}
