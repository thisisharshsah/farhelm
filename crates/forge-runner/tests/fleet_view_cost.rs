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

use std::sync::Arc;

use forge_core::store::{SqliteStore, Store};
use forge_core::types::{
    Agent, Approval, Repo, Risk, Session, SessionStatus, TaskType, Tier, Usage,
};
use forge_crypto::Identity;
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
        forge_core::ledger::Ledger::new(&state.store)
            .record_at(
                forge_core::ledger::Call::new(
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
                forge_core::time::now_ms(),
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
