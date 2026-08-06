//! Does compacting history actually pay for itself?
//!
//! This file changed the design. The first version asserted that frequent
//! compaction would cost *more*, on the reasoning that rewriting the history
//! invalidates the prompt cache. The measurement said otherwise, and the
//! measurement was right: history sits after the stable breakpoints, so only the
//! history segment is invalidated — everything ahead of it still reads at 0.1×,
//! and the saving on the routed call's input dwarfs the penalty.
//!
//! So the tests below record what is true rather than what was assumed:
//! compaction saves money, and compacting *harder* saves more. The defaults
//! deliberately leave some of that on the table, because the real cost of
//! frequent compaction is fidelity — each pass re-summarises text that already
//! went through a summary — and that is a currency this ledger cannot see.

use forge_core::store::{SqliteStore, Store, TimeRange};
use forge_core::types::{Agent, Machine, Repo, Session, SessionStatus, TaskType};
use forge_gateway::compaction::CompactionPolicy;
use forge_gateway::prompt::{StableContext, Turn};
use forge_gateway::{CompleteRequest, Gateway, GatewayConfig, StubClient};

const NOW: i64 = 1_785_369_600_000;
/// Long enough that the history dominates the prompt, which is when compaction
/// is supposed to help. A short session is covered by the unit tests.
const TURNS: usize = 40;

fn store() -> SqliteStore {
    let store = SqliteStore::open_in_memory().unwrap();
    store
        .upsert_machine(&Machine {
            id: "m1".into(),
            name: "laptop".into(),
            pubkey: "k".into(),
            last_seen_at: Some(NOW),
            created_at: NOW,
        })
        .unwrap();
    store
        .upsert_repo(&Repo {
            id: "r1".into(),
            machine_id: "m1".into(),
            path: "/srv/api".into(),
            name: "api".into(),
            budget_usd: None,
        })
        .unwrap();
    store
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
    store
}

fn base_context() -> StableContext {
    StableContext {
        system: "You are a coding agent working in a Rust repository.".repeat(40),
        conventions: "Prefer explicit error types. No unwrap in library code.".repeat(40),
        repo_map: "src/lib.rs: pub fn run()\nsrc/retry.rs: pub fn backoff()".repeat(60),
        history: Vec::new(),
        tools: Vec::new(),
    }
}

/// A realistic turn: the agent says something substantial each time.
fn reply(index: usize) -> String {
    format!(
        "Turn {index}: adjusted the retry ceiling, re-ran the affected tests, \
         and recorded what changed in the plan. "
    )
    .repeat(30)
}

struct Outcome {
    total_usd: f64,
    calls: usize,
    /// How large the history had grown by the end.
    final_history_bytes: usize,
}

/// Replay a session, optionally compacting.
async fn replay(compaction: Option<CompactionPolicy>) -> Outcome {
    let store = store();
    // `&SqliteStore` is a `Store`, so the gateway borrows it and the test keeps
    // its own handle to read the ledger afterwards.
    let gateway = Gateway::new(
        &store,
        StubClient::new("Earlier: chose exponential backoff; retry test still failing."),
        GatewayConfig {
            compaction,
            ..GatewayConfig::default()
        },
    );

    let mut history: Vec<Turn> = Vec::new();

    for index in 0..TURNS {
        let mut request = CompleteRequest::new("s1", TaskType::Edit, format!("step {index}"));
        request.stable = StableContext {
            history: history.clone(),
            ..base_context()
        };

        let response = gateway
            .complete(request)
            .await
            .expect("turn should succeed");

        // The caller owns the history — including whatever compaction handed
        // back. Not storing it is the mistake that makes compaction a pure loss.
        if let Some(compacted) = response.compacted_history {
            history = compacted;
        }
        history.push(Turn::user(format!("step {index}")));
        history.push(Turn::assistant(reply(index)));
    }

    let events = store
        .list_usage("s1", TimeRange::ALL)
        .expect("ledger readable");

    Outcome {
        total_usd: events.iter().map(|event| event.cost_usd).sum(),
        calls: events.len(),
        final_history_bytes: history.iter().map(|turn| turn.text.len()).sum(),
    }
}

#[tokio::test]
async fn compaction_pays_for_itself_over_a_long_session() {
    let uncompacted = replay(None).await;
    let compacted = replay(Some(CompactionPolicy::default())).await;

    let saved = uncompacted.total_usd - compacted.total_usd;
    let pct = saved / uncompacted.total_usd * 100.0;

    println!(
        "over {TURNS} turns: ${:.4} uncompacted ({} calls) vs ${:.4} compacted ({} calls) \
         — {pct:.1}% saved",
        uncompacted.total_usd, uncompacted.calls, compacted.total_usd, compacted.calls
    );
    println!(
        "history at the end: {} bytes → {} bytes",
        uncompacted.final_history_bytes, compacted.final_history_bytes
    );

    // The summary calls are real and are in the ledger, so this is net of them.
    assert!(
        compacted.calls > uncompacted.calls,
        "compaction should have made extra summary calls, and they should be billed"
    );
    assert!(
        compacted.total_usd < uncompacted.total_usd,
        "compaction cost more than it saved: ${:.4} vs ${:.4}",
        compacted.total_usd,
        uncompacted.total_usd
    );
}

#[tokio::test]
async fn compaction_keeps_the_history_bounded() {
    // The other reason C7 exists, and the one that does not show up in dollars:
    // an uncompacted session eventually will not fit in the context window at
    // all, however cheap the cache reads are.
    let uncompacted = replay(None).await;
    let compacted = replay(Some(CompactionPolicy::default())).await;

    let ratio = compacted.final_history_bytes as f64 / uncompacted.final_history_bytes as f64;
    println!(
        "history after {TURNS} turns: {} bytes → {} bytes ({:.0}% of uncompacted)",
        uncompacted.final_history_bytes,
        compacted.final_history_bytes,
        ratio * 100.0
    );
    assert!(
        ratio < 0.75,
        "compaction should meaningfully bound the history, got {ratio:.2}"
    );
}

#[tokio::test]
async fn the_defaults_leave_money_on_the_table_on_purpose() {
    // The finding that corrected the design. Compacting every turn and keeping
    // one is *cheaper* than the defaults — the routed call ends up with almost
    // no input to pay for, and the cache penalty is confined to the history
    // segment.
    //
    // The defaults do not do that, and the gap measured here is the price of
    // fidelity: every pass re-summarises text that already went through a
    // summary, so an aggressive policy has rewritten turn 3 a dozen times by the
    // end of a session. An agent that has forgotten what it already tried costs
    // far more than the tokens saved — in a currency this ledger cannot see.
    //
    // If this assertion ever flips, the defaults have become the cost-minimising
    // setting, and the fidelity argument for them no longer holds.
    let sensible = replay(Some(CompactionPolicy::default())).await;
    let frantic = replay(Some(CompactionPolicy {
        trigger_bytes: 1,
        keep_recent: 1,
        min_turns: 1,
    }))
    .await;

    let gap = (sensible.total_usd - frantic.total_usd) / sensible.total_usd * 100.0;
    println!(
        "defaults ${:.4} ({} calls) vs aggressive ${:.4} ({} calls) —          {gap:.0}% given up for fidelity",
        sensible.total_usd, sensible.calls, frantic.total_usd, frantic.calls
    );

    assert!(
        frantic.total_usd < sensible.total_usd,
        "aggressive compaction is expected to be cheaper; if it is not, the \
         fidelity trade-off documented in compaction.rs needs revisiting"
    );
    // And it really is doing more work, which is where the fidelity goes.
    assert!(frantic.calls > sensible.calls);
}
