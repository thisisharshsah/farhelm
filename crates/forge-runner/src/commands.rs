//! Everything a *device* can ask the runner to do.
//!
//! There are two ways in — the localhost HTTP API and the relay link — and they
//! must not be able to diverge. The D3 rule that a destructive command cannot be
//! cleared from a watch is enforced here, once, so a new transport cannot
//! accidentally ship without it.
//!
//! Nothing in this module knows about HTTP status codes or WebSocket frames.
//! Each caller maps [`CommandError`] onto its own vocabulary.

use std::sync::Arc;

use forge_core::plan::{self};
use forge_core::store::{DecisionOutcome, prelude::*};
use forge_core::time::now_ms;
use forge_core::types::{DecidedVia, Decision, PlanStepStatus};
use forge_domain::ApprovalRules as _;
use serde::Serialize;

use crate::session::SessionManager;
use crate::state::{AppState, ServerEvent};

/// The command contract moved to `forge-proto`: it is what a device sends, and
/// both transports plus three client implementations agree on it. Re-exported so
/// `commands::Command` keeps resolving.
pub use forge_proto::commands::{Command, PlanAction};

#[derive(Debug)]
pub enum CommandError {
    NotFound(String),
    /// The device is not allowed to do this — the destructive-approval rule.
    Forbidden(String),
    /// Valid request, wrong state.
    Conflict(String),
    Store(forge_core::store::StoreError),
    Terminal(String),
    /// The runner failed to assemble a reply. Not the device's fault.
    Internal(String),
}

impl std::fmt::Display for CommandError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CommandError::NotFound(what) => write!(f, "not found: {what}"),
            CommandError::Forbidden(why) => f.write_str(why),
            CommandError::Conflict(why) => f.write_str(why),
            CommandError::Store(err) => write!(f, "{err}"),
            CommandError::Terminal(err) => f.write_str(err),
            CommandError::Internal(err) => f.write_str(err),
        }
    }
}

impl std::error::Error for CommandError {}

impl From<forge_core::store::StoreError> for CommandError {
    fn from(err: forge_core::store::StoreError) -> Self {
        CommandError::Store(err)
    }
}

/// What happened, in enough detail for a caller to render a response.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Outcome {
    Decided {
        approval_id: String,
        decision: Decision,
        /// False when another device got there first.
        recorded: bool,
    },
    Instructed {
        session_id: String,
        /// False when the runner has no pane to type into.
        delivered: bool,
    },
    PlanChanged {
        session_id: String,
        steps: Vec<forge_core::types::PlanStep>,
    },
    /// The answer to [`Command::Snapshot`]. Goes back to the asking device only,
    /// not to every paired device — nobody else asked.
    Snapshot(Box<forge_proto::views::FleetView>),
    /// The answer to [`Command::SessionSnapshot`], likewise addressed.
    SessionSnapshot(Box<forge_proto::views::SessionDetail>),
    /// The answer to [`Command::DashboardSnapshot`], likewise addressed.
    DashboardSnapshot(Box<forge_proto::views::DashboardView>),
    TaskReviewed {
        task_id: String,
        status: forge_core::types::TaskStatus,
        /// False when another device got there first.
        recorded: bool,
    },
    /// The answer to [`Command::TaskSnapshot`], likewise addressed.
    TaskSnapshot(Box<forge_proto::views::TaskDetail>),
    /// The answer to [`Command::TaskList`].
    ///
    /// Wrapped in a struct rather than sent as a bare array: the relay matches
    /// replies to waiting requests by *shape*, and a bare array is the one shape
    /// that cannot be told apart from any other bare array.
    TaskList {
        tasks: Vec<forge_proto::views::TaskView>,
    },
}

/// Run a device command. `via` records which surface it arrived from.
pub async fn execute(
    state: &Arc<AppState>,
    command: Command,
    via: DecidedVia,
) -> Result<Outcome, CommandError> {
    match command {
        Command::Decide {
            approval_id,
            decision,
        } => decide(state, &approval_id, decision, via).await,
        Command::Instruct { session_id, text } => instruct(state, &session_id, &text).await,
        Command::PlanControl { session_id, action } => {
            plan_control(state, &session_id, action).await
        }
        Command::SessionSnapshot { session_id } => Ok(Outcome::SessionSnapshot(Box::new(
            crate::views::build_session_detail(state, &session_id)
                .map_err(|err| CommandError::NotFound(err.to_string()))?,
        ))),
        Command::DashboardSnapshot {
            session_id,
            since_ms,
        } => Ok(Outcome::DashboardSnapshot(Box::new(
            crate::views::build_dashboard(state, &session_id, since_ms)
                .map_err(|err| CommandError::NotFound(err.to_string()))?,
        ))),
        Command::ReviewTask {
            task_id,
            decision,
            note,
        } => review_task(state, &task_id, decision, note.as_deref(), via),
        Command::TaskSnapshot { task_id } => Ok(Outcome::TaskSnapshot(Box::new(
            crate::views::build_task_detail(state, &task_id)
                .map_err(|err| CommandError::NotFound(err.to_string()))?,
        ))),
        Command::TaskList => Ok(Outcome::TaskList {
            tasks: crate::views::build_task_list(state)
                .map_err(|err| CommandError::Internal(err.to_string()))?,
        }),
        Command::RevertTask { task_id } => {
            let task = crate::task::revert(state, &task_id, via).map_err(task_error)?;
            Ok(Outcome::TaskReviewed {
                task_id: task.id.clone(),
                status: task.status,
                recorded: true,
            })
        }
        Command::Snapshot => Ok(Outcome::Snapshot(Box::new(
            crate::views::build_fleet_view(state)
                .map_err(|err| CommandError::Internal(err.to_string()))?,
        ))),
    }
}

/// Map a task failure onto this layer's vocabulary.
///
/// `Conflict` becomes `Forbidden` rather than `Conflict` on purpose: over the
/// relay these all come back as one `command_error`, and "you cannot do that"
/// is the honest summary of every conflict a device can hit here — a watch, an
/// already-decided task, a change set that never landed.
fn task_error(err: crate::task::TaskError) -> CommandError {
    use crate::task::TaskError;
    match err {
        TaskError::NotFound(what) => CommandError::NotFound(what),
        TaskError::Conflict(why) => CommandError::Forbidden(why),
        TaskError::Store(err) => CommandError::Store(err),
        other => CommandError::Internal(other.to_string()),
    }
}

/// Approve or reject a change set from a device.
///
/// Thin on purpose: every rule — the watch refusal, the two-devices race, the
/// stale-file check, the write itself — lives in [`crate::task::review`], so the
/// relay and the localhost API cannot enforce different ones.
fn review_task(
    state: &Arc<AppState>,
    task_id: &str,
    decision: crate::task::Review,
    note: Option<&str>,
    via: DecidedVia,
) -> Result<Outcome, CommandError> {
    let before = state
        .store
        .get_task(task_id)?
        .ok_or_else(|| CommandError::NotFound(format!("task {task_id}")))?;

    let task = crate::task::review(state, task_id, decision, note, via).map_err(task_error)?;

    Ok(Outcome::TaskReviewed {
        task_id: task.id.clone(),
        status: task.status,
        // `before` was awaiting review, so a decided task with a *different*
        // decider means somebody else's tap landed first.
        recorded: before.decided_at.is_none() && task.decided_at.is_some(),
    })
}

async fn decide(
    state: &Arc<AppState>,
    approval_id: &str,
    decision: Decision,
    via: DecidedVia,
) -> Result<Outcome, CommandError> {
    let existing = state
        .store
        .get_approval(approval_id)?
        .ok_or_else(|| CommandError::NotFound(format!("approval {approval_id}")))?;

    // D3: convenience must never become catastrophe. Checked server-side, on
    // every transport, because a client that skipped it would otherwise be the
    // whole defence.
    if via == DecidedVia::Watch && !existing.allows_watch_decision() {
        return Err(CommandError::Forbidden(
            "destructive commands must be approved from the phone".into(),
        ));
    }

    let outcome = state
        .store
        .decide_approval(approval_id, decision, via, now_ms())?;

    let recorded = matches!(outcome, DecisionOutcome::Recorded(_));
    if recorded {
        let approval = outcome.approval();

        // For an agent with a hook, the bridge is already blocked on this and
        // picks the decision up itself. For one that asked in its terminal,
        // nothing happens until somebody types the answer — so type it.
        if let Ok(Some(session)) = state.store.get_session(&approval.session_id) {
            let _ = crate::watcher::answer(
                state,
                &Arc::clone(&state.terminal),
                &state.seen_prompts,
                &session,
                decision,
            )
            .await;
        }

        state.publish(ServerEvent::ApprovalDecision {
            approval_id: approval.id.clone(),
            session_id: approval.session_id.clone(),
            decision,
        });
        state.publish(ServerEvent::SessionUpsert {
            session_id: approval.session_id.clone(),
        });
    }

    Ok(Outcome::Decided {
        approval_id: outcome.approval().id.clone(),
        decision: outcome.approval().decision.unwrap_or(decision),
        recorded,
    })
}

async fn instruct(
    state: &Arc<AppState>,
    session_id: &str,
    text: &str,
) -> Result<Outcome, CommandError> {
    let text = text.trim();
    if text.is_empty() {
        return Err(CommandError::Conflict("instruction is empty".into()));
    }
    state
        .store
        .get_session(session_id)?
        .ok_or_else(|| CommandError::NotFound(format!("session {session_id}")))?;

    let manager = SessionManager::new(Arc::clone(state), Arc::clone(&state.terminal));
    match manager.send(session_id, text).await {
        Ok(()) => Ok(Outcome::Instructed {
            session_id: session_id.to_owned(),
            delivered: true,
        }),
        // A session adopted from a hook callback has no pane the runner owns.
        // The instruction is still recorded so it shows on the phone, but the
        // response says plainly that nothing was typed anywhere.
        Err(crate::session::ManagerError::NoTarget) => {
            state.push_output(session_id, format!("› {text}"), now_ms());
            Ok(Outcome::Instructed {
                session_id: session_id.to_owned(),
                delivered: false,
            })
        }
        Err(err) => Err(CommandError::Terminal(err.to_string())),
    }
}

async fn plan_control(
    state: &Arc<AppState>,
    session_id: &str,
    action: PlanAction,
) -> Result<Outcome, CommandError> {
    let session = state
        .store
        .get_session(session_id)?
        .ok_or_else(|| CommandError::NotFound(format!("session {session_id}")))?;
    let plan_id = session
        .plan_id
        .ok_or_else(|| CommandError::Conflict("session has no plan".into()))?;

    let mut steps = state.store.list_plan_steps(&plan_id)?;
    let before = steps.clone();

    match action {
        PlanAction::Pause => {
            plan::pause(&mut steps);
        }
        PlanAction::Resume => {
            if let Some(ordinal) = plan::next_todo(&steps).map(|step| step.ordinal) {
                plan::start(&mut steps, ordinal)
                    .map_err(|err| CommandError::Conflict(err.to_string()))?;
            }
        }
        PlanAction::Skip => {
            let ordinal = steps
                .iter()
                .find(|step| step.status == PlanStepStatus::Active)
                .or_else(|| plan::next_todo(&steps))
                .map(|step| step.ordinal)
                .ok_or_else(|| CommandError::Conflict("no step left to skip".into()))?;
            plan::skip(&mut steps, ordinal)
                .map_err(|err| CommandError::Conflict(err.to_string()))?;
        }
    }

    // Only what actually moved is written back.
    for (step, previous) in steps.iter().zip(&before) {
        if step != previous {
            state.store.update_plan_step(step)?;
        }
    }
    state.publish(ServerEvent::SessionUpsert {
        session_id: session_id.to_owned(),
    });

    Ok(Outcome::PlanChanged {
        session_id: session_id.to_owned(),
        steps,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use forge_core::store::SqliteStore;
    use forge_core::types::{Agent, Approval, Repo, Risk, Session, SessionStatus};

    const NOW: i64 = 1_785_369_600_000;

    fn fixture() -> Arc<AppState> {
        let state = AppState::with_gateway(SqliteStore::open_in_memory().unwrap(), |_| None);
        state
            .store
            .upsert_repo(&Repo {
                id: "r1".into(),
                machine_id: state.machine_id.clone(),
                path: "/srv/payments-api".into(),
                name: "payments-api".into(),
                budget_usd: None,
            })
            .unwrap();
        state
            .store
            .upsert_session(&Session {
                id: "s1".into(),
                repo_id: "r1".into(),
                agent: Agent::ClaudeCode,
                tmux_target: None,
                status: SessionStatus::Running,
                plan_id: None,
                budget_usd: None,
                spent_usd: 0.0,
                started_at: NOW,
                ended_at: None,
                agent_session_id: None,
            })
            .unwrap();
        state
    }

    fn approval(state: &Arc<AppState>, id: &str, risk: Risk) {
        state
            .store
            .create_approval(&Approval {
                id: id.into(),
                session_id: "s1".into(),
                tool: "Bash".into(),
                payload: "whatever".into(),
                risk,
                decision: None,
                decided_via: None,
                requested_at: NOW,
                decided_at: None,
            })
            .unwrap();
    }

    /// Bill one call to the fixture's session so the dashboard has numbers.
    fn spend(state: &Arc<AppState>, usd_model: &str, at_ms: i64) {
        use forge_core::ledger::{Call, Ledger};
        use forge_core::types::{TaskType, Tier, Usage};

        Ledger::new(&state.store)
            .record_at(
                Call::new(
                    "s1",
                    usd_model,
                    Tier::Large,
                    TaskType::Edit,
                    Usage {
                        input_tokens: 1_000,
                        output_tokens: 500,
                        cache_write_tokens: 0,
                        cache_read_tokens: 9_000,
                    },
                ),
                at_ms,
            )
            .unwrap();
    }

    #[tokio::test]
    async fn a_phone_can_open_the_cost_dashboard() {
        // The third snapshot type. Until this existed the dashboard was the one
        // screen a paired device could not reach, because the relay has no
        // request/response channel and there was nothing to ask for.
        let state = fixture();
        spend(&state, "claude-sonnet-5", NOW);

        let outcome = execute(
            &state,
            Command::DashboardSnapshot {
                session_id: "s1".into(),
                since_ms: None,
            },
            DecidedVia::Phone,
        )
        .await
        .unwrap();

        match outcome {
            Outcome::DashboardSnapshot(dashboard) => {
                assert_eq!(dashboard.session_id, "s1");
                assert_eq!(dashboard.repo_name, "payments-api");
                assert_eq!(dashboard.calls, 1);
                assert!(dashboard.total_usd > 0.0);
                assert!(!dashboard.by_tier.is_empty());
                assert!(!dashboard.spend_series.is_empty());
                // The cache-read ratio is the headline number on that screen.
                assert!(dashboard.cache_hit_ratio.unwrap() > 0.8);
            }
            other => panic!("expected a dashboard, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn the_dashboard_window_is_honoured_over_the_relay() {
        let state = fixture();
        let hour = 60 * 60 * 1_000;
        spend(&state, "claude-sonnet-5", NOW - 4 * hour);
        spend(&state, "claude-sonnet-5", NOW);

        async fn calls_since(state: &Arc<AppState>, since_ms: Option<i64>) -> usize {
            match execute(
                state,
                Command::DashboardSnapshot {
                    session_id: "s1".into(),
                    since_ms,
                },
                DecidedVia::Phone,
            )
            .await
            .unwrap()
            {
                Outcome::DashboardSnapshot(dashboard) => dashboard.calls,
                other => panic!("expected a dashboard, got {other:?}"),
            }
        }

        assert_eq!(
            calls_since(&state, None).await,
            2,
            "the default window is everything"
        );
        assert_eq!(
            calls_since(&state, Some(NOW - hour)).await,
            1,
            "the window was ignored — a phone asking for the last hour got all of history"
        );
    }

    #[tokio::test]
    async fn a_dashboard_for_a_session_that_does_not_exist_is_not_found() {
        assert!(matches!(
            execute(
                &fixture(),
                Command::DashboardSnapshot {
                    session_id: "nope".into(),
                    since_ms: None,
                },
                DecidedVia::Phone,
            )
            .await,
            Err(CommandError::NotFound(_))
        ));
    }

    #[tokio::test]
    async fn a_phone_can_approve() {
        let state = fixture();
        approval(&state, "a1", Risk::Medium);

        let outcome = execute(
            &state,
            Command::Decide {
                approval_id: "a1".into(),
                decision: Decision::Approved,
            },
            DecidedVia::Phone,
        )
        .await
        .unwrap();

        assert!(matches!(outcome, Outcome::Decided { recorded: true, .. }));
    }

    #[tokio::test]
    async fn a_watch_cannot_clear_a_destructive_command() {
        let state = fixture();
        approval(&state, "a1", Risk::Destructive);

        let err = execute(
            &state,
            Command::Decide {
                approval_id: "a1".into(),
                decision: Decision::Approved,
            },
            DecidedVia::Watch,
        )
        .await
        .unwrap_err();

        assert!(matches!(err, CommandError::Forbidden(_)));
        // ...and nothing was recorded.
        assert!(
            state
                .store
                .get_approval("a1")
                .unwrap()
                .unwrap()
                .is_pending()
        );
    }

    #[tokio::test]
    async fn a_watch_can_still_clear_an_ordinary_one() {
        let state = fixture();
        approval(&state, "a1", Risk::Low);

        assert!(
            execute(
                &state,
                Command::Decide {
                    approval_id: "a1".into(),
                    decision: Decision::Approved,
                },
                DecidedVia::Watch,
            )
            .await
            .is_ok()
        );
    }

    #[tokio::test]
    async fn the_second_device_to_decide_is_told_it_lost() {
        let state = fixture();
        approval(&state, "a1", Risk::Low);

        execute(
            &state,
            Command::Decide {
                approval_id: "a1".into(),
                decision: Decision::Approved,
            },
            DecidedVia::Watch,
        )
        .await
        .unwrap();

        let second = execute(
            &state,
            Command::Decide {
                approval_id: "a1".into(),
                decision: Decision::Denied,
            },
            DecidedVia::Phone,
        )
        .await
        .unwrap();

        match second {
            Outcome::Decided {
                decision, recorded, ..
            } => {
                assert!(!recorded);
                assert_eq!(decision, Decision::Approved, "the first decision stands");
            }
            other => panic!("expected a decision, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn deciding_an_unknown_approval_is_not_found() {
        let state = fixture();
        assert!(matches!(
            execute(
                &state,
                Command::Decide {
                    approval_id: "ghost".into(),
                    decision: Decision::Approved,
                },
                DecidedVia::Phone,
            )
            .await
            .unwrap_err(),
            CommandError::NotFound(_)
        ));
    }

    #[tokio::test]
    async fn an_empty_instruction_is_refused() {
        let state = fixture();
        assert!(matches!(
            execute(
                &state,
                Command::Instruct {
                    session_id: "s1".into(),
                    text: "   ".into(),
                },
                DecidedVia::Phone,
            )
            .await
            .unwrap_err(),
            CommandError::Conflict(_)
        ));
    }

    #[tokio::test]
    async fn an_instruction_to_a_pane_less_session_is_recorded_but_not_claimed() {
        let state = fixture();
        let outcome = execute(
            &state,
            Command::Instruct {
                session_id: "s1".into(),
                text: "focus on the retry path".into(),
            },
            DecidedVia::Phone,
        )
        .await
        .unwrap();

        assert!(matches!(
            outcome,
            Outcome::Instructed {
                delivered: false,
                ..
            }
        ));
        assert!(
            state
                .output_tail("s1", 10)
                .iter()
                .any(|line| line.text.contains("retry path"))
        );
    }

    #[tokio::test]
    async fn plan_control_on_a_session_without_a_plan_is_a_conflict() {
        let state = fixture();
        assert!(matches!(
            execute(
                &state,
                Command::PlanControl {
                    session_id: "s1".into(),
                    action: PlanAction::Skip,
                },
                DecidedVia::Phone,
            )
            .await
            .unwrap_err(),
            CommandError::Conflict(_)
        ));
    }

    #[test]
    fn commands_round_trip_through_their_wire_form() {
        let command = Command::Decide {
            approval_id: "a1".into(),
            decision: Decision::Denied,
        };
        let json = serde_json::to_string(&command).unwrap();
        assert!(json.contains(r#""type":"decide""#));
        assert_eq!(serde_json::from_str::<Command>(&json).unwrap(), command);
    }

    #[tokio::test]
    async fn a_snapshot_returns_the_current_fleet() {
        let state = fixture();
        approval(&state, "a1", Risk::Low);

        match execute(&state, Command::Snapshot, DecidedVia::Phone)
            .await
            .unwrap()
        {
            Outcome::Snapshot(fleet) => {
                assert_eq!(fleet.sessions.len(), 1);
                assert_eq!(fleet.pending_approvals.len(), 1);
            }
            other => panic!("expected a snapshot, got {other:?}"),
        }
    }

    #[test]
    fn an_unknown_command_type_is_rejected_rather_than_guessed() {
        // A future client sending something this runner does not understand must
        // fail loudly, not silently match the closest variant.
        assert!(serde_json::from_str::<Command>(r#"{"type":"self_destruct"}"#).is_err());
    }
}
