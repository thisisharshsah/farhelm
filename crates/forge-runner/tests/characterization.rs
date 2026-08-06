//! Characterization tests: what the system does *today*, pinned.
//!
//! These exist to make a refactor safe, not to argue that the current behaviour
//! is right. Each one records an observable that something outside this
//! workspace already depends on — a byte on the wire, a field a phone reads, a
//! rule a device relies on — so that moving the code that produces it cannot
//! change it silently.
//!
//! Three kinds of observable are pinned here:
//!
//! 1. **Wire JSON.** `ServerEvent`, `Command`, and the `command_error` reply are
//!    parsed by three clients this workspace does not compile: the web PWA, the
//!    React Native app, and a hand-written Swift implementation on the watch.
//!    A renamed field is a broken phone, and `cargo test` is the only place that
//!    can notice.
//!
//! 2. **Read-model shape.** `FleetView` and friends are mirrored by hand in
//!    `packages/client-core/src/api.ts`. Nothing generates that file, so these
//!    tests are the closest thing to a contract between the two.
//!
//! 3. **The relay channel rule.** Derived independently in two binaries. Both
//!    must keep producing the same string from the same key or paired devices
//!    silently stop receiving.

use std::sync::Arc;

use forge_core::store::{SqliteStore, Store};
use forge_core::types::{
    Agent, Approval, Budget, DecidedVia, Decision, Repo, Risk, Session, SessionStatus, TaskStatus,
};
use forge_crypto::Identity;
use forge_runner::commands::{self, Command, PlanAction};
use forge_runner::state::{AppState, OutputLine, ServerEvent};
use forge_runner::test_support;

const NOW: i64 = 1_785_369_600_000;

/// A fixed keypair, so the derived channel is a constant a test can assert.
/// Generated once with `Identity::generate`; it guards nothing real.
const TEST_SECRET: &str = "tapeuo2KzNeIV8FIWkWZ4JtK39yyr83NmVW2pBYYkaU";
const TEST_PUBLIC: &str = "kFLWAF8DqRIvUm8gghrfSuEm16Imi1ZSMnZW3kO9pkI";

/// What both binaries must derive from [`TEST_PUBLIC`].
///
/// `forge-` followed by the first 16 characters of the base64url public key.
/// See `channel_derivation_agrees_across_binaries` below.
const TEST_CHANNEL: &str = "forge-kFLWAF8DqRIvUm8g";

fn fixture() -> Arc<AppState> {
    let identity = Arc::new(Identity::from_secret_base64(TEST_SECRET).unwrap());
    let state = test_support::state(SqliteStore::open_in_memory().unwrap(), identity);

    state
        .store
        .upsert_repo(&Repo {
            id: "r1".into(),
            machine_id: state.machine_id.clone(),
            path: "/srv/payments-api".into(),
            name: "payments-api".into(),
            budget_usd: Some(10.0),
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
            budget_usd: Some(5.0),
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
            payload: "git push --force".into(),
            risk,
            decision: None,
            decided_via: None,
            requested_at: NOW,
            decided_at: None,
        })
        .unwrap();
}

/* ------------------------------------------------------- 1. wire JSON */

/// Every `ServerEvent` variant, as the bytes a client actually parses.
///
/// Externally tagged on `type`, snake_case. `OutputChunk` flattens its line, so
/// `seq`/`text`/`at_ms` sit at the top level rather than under `line` — that
/// flattening is load-bearing for the Swift client and is easy to lose in a
/// move.
#[test]
fn server_event_wire_format_is_stable() {
    let cases: Vec<(ServerEvent, serde_json::Value)> = vec![
        (
            ServerEvent::SessionUpsert {
                session_id: "s1".into(),
            },
            serde_json::json!({"type": "session_upsert", "session_id": "s1"}),
        ),
        (
            ServerEvent::OutputChunk {
                session_id: "s1".into(),
                line: OutputLine {
                    seq: 7,
                    text: "compiling…".into(),
                    at_ms: NOW,
                },
            },
            serde_json::json!({
                "type": "output_chunk",
                "session_id": "s1",
                "seq": 7,
                "text": "compiling…",
                "at_ms": NOW,
            }),
        ),
        (
            ServerEvent::ApprovalDecision {
                approval_id: "a1".into(),
                session_id: "s1".into(),
                decision: Decision::Approved,
            },
            serde_json::json!({
                "type": "approval_decision",
                "approval_id": "a1",
                "session_id": "s1",
                "decision": "approved",
            }),
        ),
        (
            ServerEvent::BudgetAlert {
                session_id: "s1".into(),
                pct: 0.8,
                hard_stop: false,
            },
            serde_json::json!({
                "type": "budget_alert",
                "session_id": "s1",
                "pct": 0.8,
                "hard_stop": false,
            }),
        ),
        (
            ServerEvent::TaskUpsert {
                task_id: "t1".into(),
                session_id: "s1".into(),
                status: TaskStatus::AwaitingReview,
                summary: "3 files, +42 −17".into(),
            },
            serde_json::json!({
                "type": "task_upsert",
                "task_id": "t1",
                "session_id": "s1",
                "status": "awaiting_review",
                "summary": "3 files, +42 −17",
            }),
        ),
    ];

    for (event, expected) in cases {
        let actual = serde_json::to_value(&event).unwrap();
        assert_eq!(actual, expected, "wire format changed for {event:?}");
        // And a client's bytes still parse back into the same event.
        let parsed: ServerEvent = serde_json::from_value(expected).unwrap();
        assert_eq!(
            serde_json::to_value(parsed).unwrap(),
            serde_json::to_value(&event).unwrap()
        );
    }
}

/// The `ApprovalRequest` event embeds a whole `Approval`, so the domain struct's
/// field names are wire-visible too.
#[test]
fn approval_request_embeds_the_approval_verbatim() {
    let event = ServerEvent::ApprovalRequest {
        approval: Approval {
            id: "a1".into(),
            session_id: "s1".into(),
            tool: "Bash".into(),
            payload: "rm -rf /".into(),
            risk: Risk::Destructive,
            decision: None,
            decided_via: None,
            requested_at: NOW,
            decided_at: None,
        },
    };

    assert_eq!(
        serde_json::to_value(&event).unwrap(),
        serde_json::json!({
            "type": "approval_request",
            "approval": {
                "id": "a1",
                "session_id": "s1",
                "tool": "Bash",
                "payload": "rm -rf /",
                "risk": "destructive",
                "decision": null,
                "decided_via": null,
                "requested_at": NOW,
                "decided_at": null,
            }
        })
    );
}

/// Every `Command` a device can send, as the bytes it sends.
#[test]
fn command_wire_format_is_stable() {
    let cases: Vec<(Command, serde_json::Value)> = vec![
        (
            Command::Decide {
                approval_id: "a1".into(),
                decision: Decision::Denied,
            },
            serde_json::json!({"type": "decide", "approval_id": "a1", "decision": "denied"}),
        ),
        (
            Command::Instruct {
                session_id: "s1".into(),
                text: "focus on the retry path".into(),
            },
            serde_json::json!({
                "type": "instruct",
                "session_id": "s1",
                "text": "focus on the retry path",
            }),
        ),
        (
            Command::PlanControl {
                session_id: "s1".into(),
                action: PlanAction::Skip,
            },
            serde_json::json!({"type": "plan_control", "session_id": "s1", "action": "skip"}),
        ),
        (
            Command::SessionSnapshot {
                session_id: "s1".into(),
            },
            serde_json::json!({"type": "session_snapshot", "session_id": "s1"}),
        ),
        (
            Command::DashboardSnapshot {
                session_id: "s1".into(),
                since_ms: Some(NOW),
            },
            serde_json::json!({
                "type": "dashboard_snapshot",
                "session_id": "s1",
                "since_ms": NOW,
            }),
        ),
        (
            Command::TaskSnapshot {
                task_id: "t1".into(),
            },
            serde_json::json!({"type": "task_snapshot", "task_id": "t1"}),
        ),
        (Command::TaskList, serde_json::json!({"type": "task_list"})),
        (
            Command::RevertTask {
                task_id: "t1".into(),
            },
            serde_json::json!({"type": "revert_task", "task_id": "t1"}),
        ),
        (Command::Snapshot, serde_json::json!({"type": "snapshot"})),
    ];

    for (command, expected) in cases {
        assert_eq!(
            serde_json::to_value(&command).unwrap(),
            expected,
            "wire format changed for {command:?}"
        );
        assert_eq!(
            serde_json::from_value::<Command>(expected).unwrap(),
            command
        );
    }
}

/// `since_ms` is `#[serde(default)]`, so an older client that omits it still
/// parses. Dropping that default would break every shipped phone.
#[test]
fn dashboard_snapshot_tolerates_a_missing_window() {
    let parsed: Command =
        serde_json::from_str(r#"{"type":"dashboard_snapshot","session_id":"s1"}"#).unwrap();
    assert_eq!(
        parsed,
        Command::DashboardSnapshot {
            session_id: "s1".into(),
            since_ms: None,
        }
    );
}

/// An unknown command must fail rather than match the nearest variant.
#[test]
fn an_unknown_command_is_refused_not_guessed() {
    assert!(serde_json::from_str::<Command>(r#"{"type":"self_destruct"}"#).is_err());
}

/* ------------------------------------------- 2. read-model shape */

/// The fleet as the relay serves it, reached the way a device reaches it.
///
/// Goes through `Command::Snapshot` rather than calling the builder directly:
/// that is the path a paired phone actually uses, and it is the one the
/// `commands` → `api` dependency runs along.
async fn fleet_json(state: &Arc<AppState>) -> serde_json::Value {
    match commands::execute(state, Command::Snapshot, DecidedVia::Phone)
        .await
        .unwrap()
    {
        commands::Outcome::Snapshot(fleet) => serde_json::to_value(&*fleet).unwrap(),
        other => panic!("expected a fleet snapshot, got {other:?}"),
    }
}

/// `FleetView`'s JSON keys, which `packages/client-core/src/api.ts` mirrors by
/// hand. This is the only automated check that the two agree.
#[tokio::test]
async fn fleet_view_shape_is_stable() {
    let state = fixture();
    approval(&state, "a1", Risk::Low);

    let json = fleet_json(&state).await;

    let mut keys: Vec<&str> = json
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    keys.sort_unstable();
    assert_eq!(
        keys,
        [
            "cache_hit_ratio",
            "pending_approvals",
            "sessions",
            "tasks_awaiting_review",
            "today_usd",
        ]
    );

    let session = &json["sessions"][0];
    let mut session_keys: Vec<&str> = session
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    session_keys.sort_unstable();
    assert_eq!(
        session_keys,
        [
            "agent",
            "awaiting_approval_id",
            "budget",
            "ended_at",
            "id",
            "is_live",
            "machine_name",
            "plan",
            "repo_name",
            "started_at",
            "status",
        ]
    );

    // The approval a session is blocked on is surfaced on the session itself,
    // so the home screen can show a badge without cross-referencing the list.
    assert_eq!(session["awaiting_approval_id"], "a1");
    assert_eq!(session["agent"], "claude-code");
    assert_eq!(session["is_live"], true);

    // `budget.state` is computed server-side. The clients render it and must
    // never have to re-derive the 80%/100% thresholds.
    assert_eq!(session["budget"]["state"], "ok");
    assert_eq!(session["budget"]["cap_usd"], 5.0);
}

/// The budget thresholds, as the string a client switches on.
///
/// Asserted against the `Budget` → `BudgetView` mapping rather than by moving a
/// session's spend, because `upsert_session` deliberately refuses to overwrite
/// `spent_usd` — that column is owned by `record_usage`, so that a stale
/// in-memory copy can never roll the ledger back. Writing this test the obvious
/// way silently measured nothing.
#[test]
fn budget_state_thresholds_are_stable() {
    for (spent, expected_state, expected_pct) in [
        (0.0, "ok", 0.0),
        (3.9, "ok", 0.78),
        // 80% exactly is already a warning, not the last safe value.
        (4.0, "warn", 0.8),
        (4.9, "warn", 0.98),
        // ...and 100% exactly is a hard stop.
        (5.0, "stop", 1.0),
        (7.5, "stop", 1.5),
    ] {
        let view = forge_domain::budget_view(Budget {
            cap_usd: Some(5.0),
            spent_usd: spent,
        });
        let json = serde_json::to_value(&view).unwrap();
        assert_eq!(
            json["state"], expected_state,
            "cap 5.0, spent {spent} should read {expected_state}"
        );
        assert!(
            (json["pct"].as_f64().unwrap() - expected_pct).abs() < 1e-9,
            "cap 5.0, spent {spent} should be {expected_pct} of cap, got {}",
            json["pct"]
        );
    }
}

/// An uncapped session reports `ok` with a null percentage — never `stop`,
/// however much it has spent.
#[test]
fn an_uncapped_budget_never_stops() {
    let json = serde_json::to_value(forge_domain::budget_view(Budget {
        cap_usd: None,
        spent_usd: 999.0,
    }))
    .unwrap();
    assert_eq!(json["state"], "ok");
    assert_eq!(json["pct"], serde_json::Value::Null);
    assert_eq!(json["cap_usd"], serde_json::Value::Null);
}

/* --------------------------------------------- 3. the channel rule */

/// The relay channel is `forge-` plus the first 16 characters of the runner's
/// base64url public key.
///
/// Derived independently in `forge-runner`'s binary and in the Tauri app. Each
/// has its own copy of this assertion; if they ever disagree, one of the two
/// fails. A drift here does not error anywhere — the runner simply publishes on
/// a channel no paired device is listening to.
#[test]
fn channel_derivation_agrees_across_binaries() {
    let identity = Identity::from_secret_base64(TEST_SECRET).unwrap();
    assert_eq!(identity.public_key().as_str(), TEST_PUBLIC);

    let derived = format!(
        "forge-{}",
        identity
            .public_key()
            .as_str()
            .chars()
            .take(16)
            .collect::<String>()
    );
    assert_eq!(derived, TEST_CHANNEL);
}

/* ------------------------------------------------ 4. transport parity */

/// The D3 rule is enforced in the command layer, not per transport.
///
/// This is the invariant that makes "the relay and the HTTP API cannot diverge"
/// true, and it is the one a refactor that splits those paths would break.
#[tokio::test]
async fn a_watch_cannot_clear_a_destructive_command_on_any_transport() {
    let state = fixture();
    approval(&state, "a1", Risk::Destructive);

    let err = commands::execute(
        &state,
        Command::Decide {
            approval_id: "a1".into(),
            decision: Decision::Approved,
        },
        DecidedVia::Watch,
    )
    .await
    .unwrap_err();

    assert!(matches!(err, commands::CommandError::Forbidden(_)));
    assert!(
        state
            .store
            .get_approval("a1")
            .unwrap()
            .unwrap()
            .is_pending(),
        "the approval must be untouched"
    );
}

/// ...and the same command from a phone succeeds, so the rule is about the
/// surface rather than the command.
#[tokio::test]
async fn a_phone_can_clear_the_same_destructive_command() {
    let state = fixture();
    approval(&state, "a1", Risk::Destructive);

    commands::execute(
        &state,
        Command::Decide {
            approval_id: "a1".into(),
            decision: Decision::Approved,
        },
        DecidedVia::Phone,
    )
    .await
    .unwrap();

    assert_eq!(
        state.store.get_approval("a1").unwrap().unwrap().decided_via,
        Some(DecidedVia::Phone)
    );
}

/// The first decision wins; the second device is told it lost rather than
/// overwriting.
#[tokio::test]
async fn the_second_device_to_decide_loses() {
    let state = fixture();
    approval(&state, "a1", Risk::Low);

    async fn decide(
        state: &Arc<AppState>,
        via: DecidedVia,
        decision: Decision,
    ) -> commands::Outcome {
        commands::execute(
            state,
            Command::Decide {
                approval_id: "a1".into(),
                decision,
            },
            via,
        )
        .await
        .unwrap()
    }

    decide(&state, DecidedVia::Watch, Decision::Approved).await;
    match decide(&state, DecidedVia::Phone, Decision::Denied).await {
        commands::Outcome::Decided {
            decision, recorded, ..
        } => {
            assert!(!recorded);
            assert_eq!(decision, Decision::Approved, "the first decision stands");
        }
        other => panic!("expected a decision, got {other:?}"),
    }
}
