//! The localhost API and the relay link must answer identically.
//!
//! `commands.rs` opens with the claim that "there are two ways in — the
//! localhost HTTP API and the relay link — and they must not be able to
//! diverge". Until now nothing checked it. Every test drove one path or the
//! other, so a change that made a browser and a phone see different things
//! would have passed the suite.
//!
//! That matters more than it sounds. The two paths exist because a device on a
//! relay has no request/response channel — it receives events on one socket and
//! sends on the same one — so "what is the state right now" has to be a message
//! rather than a GET. The same read model has to come back either way, or the
//! phone and the browser disagree about a fleet somebody is making decisions
//! from.
//!
//! It is also the invariant a refactor is most likely to break silently: the
//! view builders were moved out of the HTTP module precisely so the command
//! layer could stop depending on axum, and nothing about that move would have
//! failed loudly if the two had started producing different bytes.
//!
//! So this compares them as **bytes**, not as structs. A struct comparison
//! would pass while `#[serde(flatten)]` was lost, or a field renamed on one
//! side of a re-export, which is exactly the class of thing that reaches a
//! client as `undefined`.

use std::net::SocketAddr;
use std::sync::Arc;

use forge_app::store::prelude::*;
use forge_crypto::Identity;
use forge_proto::types::{
    Agent, Approval, DecidedVia, Decision, Repo, Risk, Session, SessionStatus, TaskType, Tier,
    Usage,
};
use forge_runner::commands::{self, Command};
use forge_runner::state::AppState;
use forge_runner::{api, test_support};
use forge_sqlite::SqliteStore;

const NOW: i64 = 1_785_369_600_000;

/// A fleet with enough in it that a difference would show: two sessions, a
/// pending approval, and billed usage inside the cost strip's window.
fn fixture() -> Arc<AppState> {
    let state = test_support::state(
        SqliteStore::open_in_memory().unwrap(),
        Arc::new(Identity::generate()),
    );

    state
        .store
        .upsert_repo(&Repo {
            id: "r1".into(),
            machine_id: state.machine_id.clone(),
            path: "/srv/payments-api".into(),
            name: "payments-api".into(),
            budget_usd: Some(20.0),
        })
        .unwrap();

    for (id, status) in [
        ("s1", SessionStatus::AwaitingApproval),
        ("s2", SessionStatus::Running),
    ] {
        state
            .store
            .upsert_session(&Session {
                id: id.into(),
                repo_id: "r1".into(),
                agent: Agent::ClaudeCode,
                tmux_target: None,
                status,
                plan_id: None,
                budget_usd: Some(5.0),
                spent_usd: 0.0,
                started_at: NOW,
                ended_at: None,
                agent_session_id: None,
            })
            .unwrap();

        forge_app::ledger::Ledger::new(&state.store)
            .record_at(
                forge_app::ledger::Call::new(
                    id,
                    "claude-sonnet-5",
                    Tier::Large,
                    TaskType::Edit,
                    Usage {
                        input_tokens: 1_000,
                        output_tokens: 500,
                        cache_write_tokens: 0,
                        cache_read_tokens: 9_000,
                    },
                ),
                forge_app::time::now_ms(),
            )
            .unwrap();
    }

    state
        .store
        .create_approval(&Approval {
            id: "a1".into(),
            session_id: "s1".into(),
            tool: "Bash".into(),
            payload: "pytest tests/billing -x".into(),
            risk: Risk::Medium,
            decision: None,
            decided_via: None,
            requested_at: NOW,
            decided_at: None,
        })
        .unwrap();

    state.push_output("s1", "compiling…", NOW);
    state
}

/// Serve the real router on loopback and return its address.
async fn serve(state: Arc<AppState>) -> SocketAddr {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = axum::serve(listener, api::router(state)).await;
    });
    addr
}

async fn get(addr: SocketAddr, path: &str) -> serde_json::Value {
    reqwest::get(format!("http://{addr}{path}"))
        .await
        .unwrap()
        .json()
        .await
        .unwrap()
}

/// Run a command the way the relay link does, and return its reply as JSON.
async fn over_relay(state: &Arc<AppState>, command: Command) -> serde_json::Value {
    match commands::execute(state, command, DecidedVia::Phone)
        .await
        .expect("the command layer answered")
    {
        commands::Outcome::Snapshot(fleet) => serde_json::to_value(&*fleet).unwrap(),
        commands::Outcome::SessionSnapshot(detail) => serde_json::to_value(&*detail).unwrap(),
        commands::Outcome::DashboardSnapshot(dash) => serde_json::to_value(&*dash).unwrap(),
        commands::Outcome::TaskList { tasks } => serde_json::to_value(&tasks).unwrap(),
        other => panic!("expected a snapshot, got {other:?}"),
    }
}

/// `GET /v1/fleet` and `Command::Snapshot` are the same bytes.
#[tokio::test]
async fn the_fleet_is_identical_over_both_transports() {
    let state = fixture();
    let addr = serve(Arc::clone(&state)).await;

    let http = get(addr, "/v1/fleet").await;
    let relay = over_relay(&state, Command::Snapshot).await;

    assert_eq!(
        http, relay,
        "a browser and a phone are looking at different fleets"
    );
    // And the payload is actually populated, so an empty-vs-empty match cannot
    // pass this test vacuously.
    assert_eq!(http["sessions"].as_array().unwrap().len(), 2);
    assert_eq!(http["pending_approvals"].as_array().unwrap().len(), 1);
    assert!(http["today_usd"].as_f64().unwrap() > 0.0);
}

/// `GET /v1/sessions/{id}` and `Command::SessionSnapshot` likewise.
#[tokio::test]
async fn a_session_detail_is_identical_over_both_transports() {
    let state = fixture();
    let addr = serve(Arc::clone(&state)).await;

    let http = get(addr, "/v1/sessions/s1").await;
    let relay = over_relay(
        &state,
        Command::SessionSnapshot {
            session_id: "s1".into(),
        },
    )
    .await;

    assert_eq!(http, relay);
    // The flattened SessionView, the output tail and the pending approval are
    // all present — the three things that would differ if a re-export lost a
    // `#[serde(flatten)]`.
    assert_eq!(http["id"], "s1");
    assert_eq!(http["output"].as_array().unwrap().len(), 1);
    assert_eq!(http["pending_approval"]["id"], "a1");
}

/// `GET /v1/sessions/{id}/dashboard` and `Command::DashboardSnapshot`.
#[tokio::test]
async fn a_dashboard_is_identical_over_both_transports() {
    let state = fixture();
    let addr = serve(Arc::clone(&state)).await;

    let http = get(addr, "/v1/sessions/s1/dashboard").await;
    let relay = over_relay(
        &state,
        Command::DashboardSnapshot {
            session_id: "s1".into(),
            since_ms: None,
        },
    )
    .await;

    assert_eq!(http, relay);
    assert_eq!(http["calls"], 1);
}

/// `GET /v1/tasks` and `Command::TaskList`.
#[tokio::test]
async fn the_task_list_is_identical_over_both_transports() {
    let state = fixture();
    let addr = serve(Arc::clone(&state)).await;

    assert_eq!(
        get(addr, "/v1/tasks").await,
        over_relay(&state, Command::TaskList).await
    );
}

/// The D3 rule is the same rule on both paths.
///
/// The HTTP handler maps it to 403 and the relay to a `command_error`, but the
/// decision itself is made once. A transport that could approve a destructive
/// command from a watch would be a hole in the only defence there is.
#[tokio::test]
async fn a_watch_is_refused_a_destructive_command_on_both_transports() {
    let state = fixture();
    state
        .store
        .create_approval(&Approval {
            id: "destructive".into(),
            session_id: "s1".into(),
            tool: "Bash".into(),
            payload: "rm -rf /".into(),
            risk: Risk::Destructive,
            decision: None,
            decided_via: None,
            requested_at: NOW,
            decided_at: None,
        })
        .unwrap();
    let addr = serve(Arc::clone(&state)).await;

    // Over the relay.
    let refused = commands::execute(
        &state,
        Command::Decide {
            approval_id: "destructive".into(),
            decision: Decision::Approved,
        },
        DecidedVia::Watch,
    )
    .await
    .unwrap_err();
    assert!(matches!(refused, commands::CommandError::Forbidden(_)));

    // Over HTTP, same rule, expressed as a status.
    let response = reqwest::Client::new()
        .post(format!("http://{addr}/v1/approvals/destructive/decision"))
        .json(&serde_json::json!({ "decision": "approved", "via": "watch" }))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 403);

    // And on neither path did it land.
    assert!(
        state
            .store
            .get_approval("destructive")
            .unwrap()
            .unwrap()
            .is_pending()
    );
}

/// A not-found is a not-found on both paths.
#[tokio::test]
async fn an_unknown_session_is_refused_on_both_transports() {
    let state = fixture();
    let addr = serve(Arc::clone(&state)).await;

    let http = reqwest::get(format!("http://{addr}/v1/sessions/ghost"))
        .await
        .unwrap();
    assert_eq!(http.status(), 404);

    let relay = commands::execute(
        &state,
        Command::SessionSnapshot {
            session_id: "ghost".into(),
        },
        DecidedVia::Phone,
    )
    .await
    .unwrap_err();
    assert!(matches!(relay, commands::CommandError::NotFound(_)));
}

/* --------------------------------------------------- the channel, everywhere */

/// A pairing offer must name the channel the runner actually publishes on.
///
/// Three places derive it: `forge-runner`'s binary, the Tauri app, and this
/// endpoint's no-relay fallback. The first two were unified earlier; this one
/// was missed, and used `machine_id` — `machine-<hostname>`, not
/// `forge-<key prefix>`. An offer minted before `--relay` was configured
/// therefore named a channel the runner would never publish on.
///
/// It was not reachable: `claimPairing` refuses an offer with an empty
/// `relay_url` before storing anything. But "the bug is unreachable because a
/// client in another language happens to check first" is not a property worth
/// resting on, and the endpoint is what `forge-runner pair` renders as a QR
/// code.
#[tokio::test]
async fn a_pairing_offer_names_the_channel_the_runner_publishes_on() {
    let state = fixture();
    let addr = serve(Arc::clone(&state)).await;

    let offer: serde_json::Value = reqwest::Client::new()
        .post(format!("http://{addr}/v1/pair/offer"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    let expected = forge_proto::channel_for(state.identity.public_key().as_str());
    assert_eq!(
        offer["channel"], expected,
        "the offer names a channel the runner will never publish on"
    );
    assert!(
        expected.starts_with("forge-"),
        "and it is the derived channel, not the machine id"
    );
    assert_ne!(
        offer["channel"], state.machine_id,
        "machine_id is not a relay channel"
    );

    // The runner's own public key travels with it, so a device knows what to
    // encrypt to.
    assert_eq!(
        offer["runner_public_key"],
        state.identity.public_key().as_str()
    );
    // No relay configured: the URL is empty and a client will refuse the claim
    // rather than pair a device that has nowhere to connect.
    assert_eq!(offer["relay_url"], "");
}

/// With a relay configured, the offer carries that relay's channel verbatim.
#[tokio::test]
async fn a_configured_relay_channel_is_used_as_is() {
    let state = forge_runner::state::AppState::build(
        SqliteStore::open_in_memory().unwrap(),
        |_| None,
        Arc::new(Identity::generate()),
        Some(forge_runner::state::RelayInfo {
            url: "wss://relay.example".into(),
            channel: "forge-configured".into(),
        }),
    );
    let addr = serve(Arc::clone(&state)).await;

    let offer: serde_json::Value = reqwest::Client::new()
        .post(format!("http://{addr}/v1/pair/offer"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();

    assert_eq!(offer["channel"], "forge-configured");
    assert_eq!(offer["relay_url"], "wss://relay.example");
}
