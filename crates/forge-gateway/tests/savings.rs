//! Milestone 2's exit criteria, as tests.
//!
//! The design document commits to two numbers, and both are the kind of claim
//! that quietly stops being true:
//!
//!  - cache-read ratio ≥ 70% on a stable workload (Appendix A)
//!  - ≥ 50% cost reduction against direct agent calls, *from the ledger*
//!
//! So they are measured here rather than estimated. Fifty turns are replayed
//! through the real pipeline against a stub provider that simulates the API's
//! per-breakpoint prefix caching; the gateway's cost comes out of the append-only
//! ledger, and the baseline is priced with the same price table.
//!
//! The baseline is what an unwrapped agent does: every turn on the frontier
//! model, whole context re-sent as fresh input, no cache, no routing, no reuse.

use forge_app::store::{TimeRange, prelude::*};
use forge_domain::price::{QuoteContext, quote};
use forge_gateway::prompt::{StableContext, Turn, approx_tokens, assemble};
use forge_gateway::{CompleteRequest, Gateway, GatewayConfig, StubClient};
use forge_proto::types::{
    Agent, Avoided, Machine, Repo, Session, SessionStatus, TaskType, Tier, Usage,
};
use forge_sqlite::SqliteStore;

const NOW: i64 = 1_785_369_600_000;
const TURNS: usize = 50;
/// Every turn that is not one of the repeated questions is an edit.
const REPEATED_QUESTIONS: usize = 10;

/// What an unwrapped agent would be routed to for everything.
const BASELINE_MODEL: &str = "claude-opus-5";

const REPLY: &str = "Patched the retry ceiling and re-ran the affected tests.";

fn store() -> SqliteStore {
    let store = SqliteStore::open_in_memory().unwrap();
    store
        .upsert_machine(&Machine {
            id: "m1".into(),
            name: "hetzner-1".into(),
            pubkey: "pk".into(),
            last_seen_at: Some(NOW),
            created_at: NOW,
        })
        .unwrap();
    store
        .upsert_repo(&Repo {
            id: "r1".into(),
            machine_id: "m1".into(),
            path: "/srv/payments-api".into(),
            name: "payments-api".into(),
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

/// A realistically sized stable half: a system prompt, repo conventions, and a
/// retrieval result.
fn base_context() -> StableContext {
    StableContext {
        tools: vec![
            serde_json::json!({ "name": "bash", "description": "Run a shell command." }),
            serde_json::json!({ "name": "edit", "description": "Replace a string in a file." }),
        ],
        system: "You are a coding agent working in a Python billing service. ".repeat(120),
        conventions: "Use 4-space indent. Never edit generated migrations. ".repeat(20),
        repo_map: "src/billing/retry.py:12 def retry_backoff(attempts): ...\n".repeat(150),
        history: Vec::new(),
    }
}

/// The two questions asked over and over — C8's motivating case.
fn repeated_question(index: usize) -> &'static str {
    if index.is_multiple_of(2) {
        "Explain what retry_backoff does."
    } else {
        "What does the FAILED test_retry_after_500 assertion mean?"
    }
}

struct Replay {
    gateway_usd: f64,
    baseline_usd: f64,
    cache_reads: u64,
    fresh_input: u64,
    cache_hits: usize,
    live_calls: usize,
}

async fn replay() -> Replay {
    let store = store();
    // `&SqliteStore` is a `Store`, so the gateway can borrow it and the test
    // keeps its own handle to read the ledger afterwards.
    let gateway = Gateway::new(&store, StubClient::new(REPLY), GatewayConfig::default());

    let base = base_context();
    let mut history: Vec<Turn> = Vec::new();
    let mut baseline_usd = 0.0;
    let mut cache_hits = 0usize;
    let mut live_calls = 0usize;

    for turn in 0..TURNS {
        // The repeated questions are asked without conversation history, the way
        // a standalone "explain this" would be — which is what lets them hit the
        // exact-response cache.
        let repeat = turn.is_multiple_of(TURNS / REPEATED_QUESTIONS);

        let (task, instruction, stable) = if repeat {
            (
                TaskType::Summarize,
                repeated_question(turn).to_owned(),
                StableContext {
                    history: Vec::new(),
                    ..base.clone()
                },
            )
        } else {
            (
                TaskType::Edit,
                format!("Turn {turn}: tighten the retry ceiling in the billing path."),
                StableContext {
                    history: history.clone(),
                    ..base.clone()
                },
            )
        };

        let mut request = CompleteRequest::new("s1", task, instruction.clone());
        request.stable = stable.clone();
        let response = gateway.complete(request).await.unwrap();

        if response.avoided == Some(Avoided::ResponseCache) {
            cache_hits += 1;
        } else {
            live_calls += 1;
        }

        // Baseline: the same prompt, unwrapped. Everything the gateway would have
        // cached is re-sent as fresh input, and it all goes to the frontier model.
        let baseline_price = forge_domain::price::price_of(BASELINE_MODEL).unwrap();
        let baseline_plan = assemble(&stable, &instruction, &baseline_price);
        let baseline_usage = Usage {
            input_tokens: (approx_tokens(&baseline_plan.stable_prefix())
                + approx_tokens(baseline_plan.dynamic_tail())) as u32,
            output_tokens: approx_tokens(REPLY) as u32,
            cache_write_tokens: 0,
            cache_read_tokens: 0,
        };
        baseline_usd += quote(
            BASELINE_MODEL,
            &baseline_usage,
            QuoteContext::interactive(NOW),
        )
        .unwrap()
        .total_usd();

        if !repeat {
            history.push(Turn::user(instruction));
            history.push(Turn::assistant(REPLY));
        }
    }

    // The gateway's own number, read back out of the append-only ledger rather
    // than accumulated in the test.
    let events = store.list_usage("s1", TimeRange::ALL).unwrap();
    let gateway_usd = events.iter().map(|event| event.cost_usd).sum();
    let cache_reads = events
        .iter()
        .map(|event| u64::from(event.usage.cache_read_tokens))
        .sum();
    let fresh_input = events
        .iter()
        .map(|event| u64::from(event.usage.input_tokens))
        .sum();

    assert_eq!(events.len(), TURNS, "every turn must reach the ledger");

    Replay {
        gateway_usd,
        baseline_usd,
        cache_reads,
        fresh_input,
        cache_hits,
        live_calls,
    }
}

#[tokio::test]
async fn cache_read_ratio_clears_the_seventy_percent_target() {
    let replay = replay().await;

    let denominator = replay.cache_reads + replay.fresh_input;
    assert!(denominator > 0, "no input tokens were recorded at all");
    let ratio = replay.cache_reads as f64 / denominator as f64;

    println!(
        "cache-read ratio {:.1}%  ({} read / {} fresh input)",
        ratio * 100.0,
        replay.cache_reads,
        replay.fresh_input
    );
    assert!(
        ratio >= 0.70,
        "cache-read ratio {:.1}% is below the 70% target",
        ratio * 100.0
    );
}

#[tokio::test]
async fn cost_per_turn_beats_direct_calls_by_at_least_half() {
    let replay = replay().await;

    let reduction = 1.0 - replay.gateway_usd / replay.baseline_usd;
    println!(
        "gateway ${:.4} vs baseline ${:.4} over {TURNS} turns — {:.1}% reduction \
         ({} live calls, {} cache hits)",
        replay.gateway_usd,
        replay.baseline_usd,
        reduction * 100.0,
        replay.live_calls,
        replay.cache_hits
    );

    assert!(
        reduction >= 0.50,
        "only {:.1}% cheaper than direct calls; the milestone commits to 50%",
        reduction * 100.0
    );
}

#[tokio::test]
async fn repeated_questions_are_answered_without_calling_the_model() {
    let replay = replay().await;
    assert!(
        replay.cache_hits > 0,
        "the repeated questions never hit the response cache"
    );
    assert_eq!(
        replay.cache_hits + replay.live_calls,
        TURNS,
        "every turn is either served live or from cache"
    );
}

#[tokio::test]
async fn routing_keeps_cheap_work_off_the_frontier_model() {
    let store = store();
    let gateway = Gateway::new(&store, StubClient::new(REPLY), GatewayConfig::default());
    let base = base_context();

    for task in [
        TaskType::Triage,
        TaskType::SelectFiles,
        TaskType::Summarize,
        TaskType::Edit,
        TaskType::Plan,
    ] {
        let mut request = CompleteRequest::new("s1", task, format!("do the {task} work"));
        request.stable = base.clone();
        gateway.complete(request).await.unwrap();
    }

    let events = store.list_usage("s1", TimeRange::ALL).unwrap();
    let small = events.iter().filter(|e| e.tier == Tier::Small).count();
    let frontier = events.iter().filter(|e| e.model == "claude-opus-5").count();

    assert_eq!(
        small, 3,
        "triage, selection and summarising belong on the small tier"
    );
    assert_eq!(frontier, 1, "only planning should reach the frontier model");
}
