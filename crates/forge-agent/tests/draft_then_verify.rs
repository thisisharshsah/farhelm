//! C10, measured: what draft-then-verify actually saves.
//!
//! The claim in Appendix B is "moves bulk generation to the cheap tier". This
//! replays the *same* task twice through the real pipeline and prices both from
//! the ledger:
//!
//!   A. **Frontier throughout** — every turn of the loop on the top model, which
//!      is what you get if you route a coding agent by "use the best one".
//!   B. **Draft-then-verify** — the loop on the large tier, then exactly one
//!      frontier call that sees only the diff.
//!
//! Both do identical work: the same tool calls, the same reads, the same edit.
//! The only difference is which model each turn was billed at, which is the
//! whole point — the saving is a routing decision, not a smaller task.
//!
//! Run it to see the numbers:
//!
//! ```sh
//! cargo test -p forge-agent --test draft_then_verify -- --nocapture
//! ```

use forge_agent::script::ScriptedClient;
use forge_agent::{TaskSpec, run};
use forge_core::store::{SqliteStore, TimeRange, prelude::*};
use forge_core::types::{Agent, Machine, Repo, Session, SessionStatus, Tier};
use forge_gateway::router::Models;
use forge_gateway::{Gateway, GatewayConfig};

const NOW: i64 = 1_800_000_000_000;
/// Turns of drafting. A real task is this order of magnitude; the ratio between
/// the two strategies is what matters, not the absolute figure.
const TURNS: usize = 10;

struct Yes;
impl forge_agent::Supervisor for Yes {
    async fn request(&self, _tool: &str, _payload: &str) -> forge_agent::Verdict {
        forge_agent::Verdict::Approved
    }
    fn note(&self, _text: &str) {}
}

fn store(session: &str) -> SqliteStore {
    let store = SqliteStore::open_in_memory().unwrap();
    store
        .upsert_machine(&Machine {
            id: "m".into(),
            name: "m".into(),
            pubkey: String::new(),
            last_seen_at: None,
            created_at: NOW,
        })
        .unwrap();
    store
        .upsert_repo(&Repo {
            id: "r".into(),
            machine_id: "m".into(),
            path: "/tmp".into(),
            name: "r".into(),
            budget_usd: None,
        })
        .unwrap();
    store
        .upsert_session(&Session {
            id: session.into(),
            repo_id: "r".into(),
            agent: Agent::Forge,
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

struct TempRepo(std::path::PathBuf);

impl TempRepo {
    fn new(name: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("forge-c10-{name}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("retry.rs"), "fn backoff() -> u64 {\n    1\n}\n").unwrap();
        Self(dir)
    }
}

impl Drop for TempRepo {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The identical script both strategies replay: reads, then one edit, then a
/// closing message, then the verifier's verdict if one is asked for.
fn script() -> ScriptedClient {
    let mut turns = Vec::new();
    for _ in 0..TURNS - 2 {
        turns.push(ScriptedClient::calls(vec![(
            "read_file",
            serde_json::json!({ "path": "retry.rs" }),
        )]));
    }
    turns.push(ScriptedClient::calls(vec![(
        "edit_file",
        serde_json::json!({
            "path": "retry.rs",
            "old_string": "    1\n",
            "new_string": "    1u64 << 4\n"
        }),
    )]));
    turns.push(ScriptedClient::text("Widened the backoff."));
    // The verifier's reply, if this strategy asks for one.
    turns.push(ScriptedClient::text(
        "VERDICT: pass\nThe shift is bounded and matches the ask.",
    ));
    ScriptedClient::new(turns)
}

struct Replay {
    usd: f64,
    frontier_calls: usize,
    large_calls: usize,
}

/// Run the task once and price it from the ledger.
///
/// `models` is what makes the two strategies differ: strategy A points every
/// slot at the frontier model, so "route to large" and "route to frontier" both
/// land on Opus.
async fn replay(models: Models, verify: bool, label: &str) -> Replay {
    let repo = TempRepo::new(label);
    let store = store("s");
    let gateway = Gateway::new(
        &store,
        script(),
        GatewayConfig {
            models,
            // Off: compaction is C7's saving, and mixing it in here would make
            // this benchmark measure two things at once.
            compaction: None,
            ..GatewayConfig::default()
        },
    );

    let mut spec = TaskSpec::new("s", &repo.0, "Widen the retry backoff");
    spec.verify = verify;
    let outcome = run(&gateway, &Yes, &spec).await;
    assert!(
        !outcome.changes.is_empty(),
        "{label} produced no change set"
    );

    let events = store.list_usage("s", TimeRange::ALL).unwrap();
    let frontier = forge_core::price::price_of("claude-opus-5").unwrap();

    Replay {
        usd: events.iter().map(|event| event.cost_usd).sum(),
        frontier_calls: events
            .iter()
            .filter(|event| event.model == frontier.model)
            .count(),
        large_calls: events
            .iter()
            .filter(|event| event.model != frontier.model && event.tier == Tier::Large)
            .count(),
    }
}

/// Everything on the frontier model, which is the naive "use the best one".
fn frontier_everywhere() -> Models {
    let frontier = Models::default().frontier;
    Models {
        small: frontier.clone(),
        large: frontier.clone(),
        frontier,
    }
}

#[tokio::test]
async fn drafting_cheap_and_verifying_expensive_beats_frontier_throughout() {
    let baseline = replay(frontier_everywhere(), false, "baseline").await;
    let c10 = replay(Models::default(), true, "c10").await;

    let reduction = 1.0 - c10.usd / baseline.usd;
    println!(
        "frontier throughout ${:.4} ({} frontier calls) vs \
         draft-then-verify ${:.4} ({} large + {} frontier) \
         over {TURNS} turns — {:.1}% reduction",
        baseline.usd,
        baseline.frontier_calls,
        c10.usd,
        c10.large_calls,
        c10.frontier_calls,
        reduction * 100.0
    );

    assert!(
        reduction > 0.0,
        "draft-then-verify cost more than drafting on the frontier model"
    );
    // Appendix B's claim is that this moves *bulk* generation off the top tier.
    // A third is a conservative floor for that; the measured figure is printed
    // above and is a good deal better.
    assert!(
        reduction >= 0.33,
        "only {:.1}% cheaper — C10 claims bulk generation moves tier",
        reduction * 100.0
    );
}

#[tokio::test]
async fn exactly_one_call_pays_frontier_rates() {
    // The shape of the saving, not its size: many cheap turns, one expensive
    // read. If verification ever crept inside the loop this would catch it.
    let c10 = replay(Models::default(), true, "shape").await;

    assert_eq!(
        c10.frontier_calls, 1,
        "verification is supposed to happen once, after the loop"
    );
    assert!(
        c10.large_calls >= TURNS - 1,
        "drafting did not stay on the large tier"
    );
}

#[tokio::test]
async fn the_verifier_reads_the_diff_and_not_the_session() {
    // The other half of the cost argument: the frontier call's input is a patch,
    // not a twelve-turn transcript with a repo map in it.
    let repo = TempRepo::new("input");
    let store = store("s");
    let client = script();
    let gateway = Gateway::new(
        &store,
        client.clone(),
        GatewayConfig {
            compaction: None,
            ..GatewayConfig::default()
        },
    );

    let spec = TaskSpec::new("s", &repo.0, "Widen the retry backoff");
    let outcome = run(&gateway, &Yes, &spec).await;
    assert_eq!(outcome.assessment.unwrap().grade, forge_agent::Grade::Pass);

    let requests = client.requests();
    let verifier = requests.last().expect("a verification call");
    let last_draft = &requests[requests.len() - 2];

    let verifier_input = verifier.plan.stable_prefix().len() + verifier.plan.dynamic_tail().len();
    let draft_input = last_draft.plan.stable_prefix().len() + last_draft.plan.dynamic_tail().len();

    println!("verifier input {verifier_input} bytes vs final drafting turn {draft_input} bytes");
    assert!(
        verifier_input < draft_input,
        "the frontier call read more than the drafting turns did — \
         the patch is supposed to be the small input"
    );

    // And it carries no history and no repo map at all.
    assert!(
        verifier.plan.messages.len() == 1,
        "the verifier was sent history"
    );
    assert!(
        !verifier.plan.stable_prefix().contains("Repository context"),
        "the verifier was sent a repo map"
    );
}
