//! What assembling the home screen costs, in store reads.
//!
//! `build_fleet_view` is the most-called assembly in the system: every
//! `GET /v1/fleet`, and every `Command::Snapshot` from a phone that has just
//! been woken and has one round trip's patience.
//!
//! These tests count reads rather than measuring time. A wall-clock assertion
//! against an in-memory SQLite database would be noise; the read count is the
//! thing that actually grows with the fleet, and it is deterministic.
//!
//! The number they pin is a *shape*, not a constant: reads must not scale with
//! the number of sessions when every session points at the same repo.

use forge_sqlite::SqliteStore;
use std::sync::Arc;

use forge_app::store::{TimeRange, prelude::*};
use forge_crypto::Identity;
use forge_proto::types::{
    Agent, Approval, Repo, Risk, Session, SessionStatus, TaskType, Tier, Usage,
};
use forge_runner::state::AppState;
use forge_runner::test_support;
use forge_runner::views::{Lookups, build_fleet_view, view_of};

const NOW: i64 = 1_785_369_600_000;

fn fixture(sessions: usize, approvals: usize) -> Arc<AppState> {
    let identity = Arc::new(Identity::generate());
    let state = test_support::state(SqliteStore::open_in_memory().unwrap(), identity);

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

    for i in 0..sessions {
        state
            .store
            .upsert_session(&Session {
                id: format!("s{i}"),
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

        // One billed call per session, so the 24h cost strip has something to
        // sum. Recorded at the real clock, not at NOW: the fleet's cost strip
        // is a rolling 24-hour window off `now_ms()`, and NOW is a fixed
        // timestamp that drifts into the past as the calendar moves.
        forge_app::ledger::Ledger::new(&state.store)
            .record_at(
                forge_app::ledger::Call::new(
                    &format!("s{i}"),
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

    for i in 0..approvals {
        state
            .store
            .create_approval(&Approval {
                id: format!("a{i}"),
                session_id: format!("s{}", i % sessions.max(1)),
                tool: "Bash".into(),
                payload: "git push --force".into(),
                risk: Risk::Low,
                decision: None,
                decided_via: None,
                requested_at: NOW,
                decided_at: None,
            })
            .unwrap();
    }

    state
}

/// The memo must collapse repeated reads of the same row.
///
/// Every session and every approval in this fixture names one repo on one
/// machine, so the repo, the machine and the pending list should each be read
/// once no matter how many rows reference them.
#[test]
fn repeated_rows_are_read_once_per_assembly() {
    let state = fixture(20, 10);
    let lookups = Lookups::new(state.store.as_ref()).unwrap();

    let sessions = state.store.list_sessions().unwrap();
    for session in &sessions {
        view_of(&state, &lookups, session).unwrap();
    }

    // 1 pending-approval list + 1 repo + 1 machine + one budget per session.
    // The budgets are genuinely distinct rows; the first three are not.
    let expected = 3 + sessions.len();
    assert_eq!(
        lookups.reads(),
        expected,
        "assembling {} sessions should read the shared rows once each, not once per session",
        sessions.len()
    );
}

/// Reads that are not per-session must not grow when the fleet does.
///
/// This is the regression that matters. Before the memo, `view_of` called
/// `list_pending_approvals` — a read of the whole pending table — *inside* the
/// per-session builder, and then scanned the result in Rust for the one approval
/// belonging to that session. Twenty sessions meant twenty full reads of the
/// table to answer twenty questions that one read answers.
#[test]
fn shared_reads_do_not_grow_with_the_fleet() {
    let shared_reads = |sessions: usize| {
        let state = fixture(sessions, 8);
        let lookups = Lookups::new(state.store.as_ref()).unwrap();
        for session in &state.store.list_sessions().unwrap() {
            view_of(&state, &lookups, session).unwrap();
        }
        // Subtract the one genuinely per-session read.
        lookups.reads() - sessions
    };

    assert_eq!(
        shared_reads(2),
        shared_reads(40),
        "the reads that are not per-session must be constant in the fleet size"
    );
}

/// The numbers the cost strip shows, unchanged by the memo.
///
/// Nine thousand cache reads against one thousand fresh input tokens is a 90%
/// cache-read ratio, and the fleet-wide figure is the same because every session
/// here is identical.
#[test]
fn the_cost_strip_totals_are_unchanged() {
    let state = fixture(3, 0);
    let fleet = build_fleet_view(&state).unwrap();

    assert_eq!(fleet.sessions.len(), 3);
    assert!(
        fleet.today_usd > 0.0,
        "three billed calls should cost something"
    );
    let ratio = fleet.cache_hit_ratio.expect("there was billable input");
    assert!(
        (ratio - 0.9).abs() < 1e-9,
        "9000 cache reads against 1000 fresh input is 90%, got {ratio}"
    );
}

/// The approval a session is blocked on is still the oldest one, which is what
/// the memo's `find` over a pre-read list has to preserve.
#[test]
fn a_session_still_reports_its_oldest_pending_approval() {
    let state = fixture(1, 3);
    let fleet = build_fleet_view(&state).unwrap();

    assert_eq!(fleet.pending_approvals.len(), 3);
    assert_eq!(
        fleet.sessions[0].awaiting_approval_id.as_deref(),
        Some("a0"),
        "the oldest pending approval is the one the session reports"
    );
}

/// A session with nothing pending reports nothing, rather than the first
/// approval belonging to somebody else.
#[test]
fn a_session_with_no_approval_reports_none() {
    let state = fixture(2, 1); // a0 belongs to s0 only
    let fleet = build_fleet_view(&state).unwrap();

    let s1 = fleet
        .sessions
        .iter()
        .find(|session| session.id == "s1")
        .unwrap();
    assert_eq!(s1.awaiting_approval_id, None);
}

/// The store's aggregate must equal the per-session fold it replaced.
///
/// The cost strip used to be `list_usage` for every session, summed in Rust.
/// That is now one `SUM` in SQL, and this is the equivalence check: the same
/// numbers, computed both ways, over a fleet with several sessions and events
/// on both sides of the window boundary.
///
/// Worth being careful about because the two are not obviously the same query.
/// The fold iterated `list_sessions()` and summed each session's rows; the
/// aggregate sums the whole table in the window and never mentions a session.
/// They agree only because `list_sessions` is unbounded and the schema's foreign
/// key means no usage row can belong to a session that is not in it.
#[test]
fn the_aggregate_matches_the_per_session_fold_it_replaced() {
    let state = fixture(5, 0);
    let now = forge_app::time::now_ms();

    // Something inside the window, something outside it, on two sessions.
    for (session, at) in [
        ("s0", now - 60_000),
        ("s1", now - 2 * 60 * 60 * 1_000),
        ("s2", now - 48 * 60 * 60 * 1_000),
    ] {
        forge_app::ledger::Ledger::new(&state.store)
            .record_at(
                forge_app::ledger::Call::new(
                    session,
                    "claude-opus-5",
                    Tier::Large,
                    TaskType::Refactor,
                    Usage {
                        input_tokens: 3_000,
                        output_tokens: 700,
                        cache_write_tokens: 0,
                        cache_read_tokens: 17_000,
                    },
                ),
                at,
            )
            .unwrap();
    }

    let window = TimeRange::since(now - 24 * 60 * 60 * 1_000);

    // The old shape, recomputed here.
    let mut folded_usd = 0.0;
    let mut folded_reads: u64 = 0;
    let mut folded_input: u64 = 0;
    for session in state.store.list_sessions().unwrap() {
        for event in state.store.list_usage(&session.id, window).unwrap() {
            folded_usd += event.cost_usd;
            folded_reads += u64::from(event.usage.cache_read_tokens);
            folded_input += u64::from(event.usage.input_tokens);
        }
    }

    let totals = state.store.usage_totals(window).unwrap();

    assert!(
        (totals.cost_usd - folded_usd).abs() < 1e-12,
        "aggregate {} vs fold {folded_usd}",
        totals.cost_usd
    );
    assert_eq!(totals.cache_read_tokens, folded_reads);
    assert_eq!(totals.input_tokens, folded_input);
    assert!(folded_usd > 0.0, "the fixture must actually bill something");

    // And the event outside the window is genuinely excluded by both.
    assert_eq!(
        totals.calls, 7,
        "5 fixture calls + 2 inside the window; the 48h-old one is out"
    );
}

/// An empty ledger is zero, not an error and not a NULL.
#[test]
fn totals_over_an_empty_window_are_zero() {
    let state = fixture(2, 0);
    let ancient = TimeRange {
        since_ms: Some(0),
        until_ms: Some(1),
    };
    let totals = state.store.usage_totals(ancient).unwrap();

    assert_eq!(totals.calls, 0);
    assert_eq!(totals.cost_usd, 0.0);
    // `None`, not `Some(0.0)`: an idle fleet has no ratio, and rendering it as
    // 0% would drag a dashboard average down with data that does not exist.
    assert_eq!(totals.cache_read_ratio(), None);
}

/// The schema will not let a session point at a repo that does not exist.
///
/// Worth pinning because `view_of` has a `not_found` branch for exactly that
/// case, and this is why it has never fired: the foreign key refuses the write
/// first. The branch is a belt-and-braces guard for a store that does not
/// enforce referential integrity — a Postgres backend for the team tier would,
/// but an in-memory test double might not — so it stays.
#[test]
fn the_schema_refuses_a_session_whose_repo_is_gone() {
    let state = fixture(1, 0);
    let mut session = state.store.get_session("s0").unwrap().unwrap();
    session.repo_id = "gone".into();

    assert!(
        state.store.upsert_session(&session).is_err(),
        "a dangling repo_id must be refused at the boundary"
    );
}
