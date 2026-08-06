//! One sample of every wire shape, checked in, read by both languages.
//!
//! `packages/client-core/src/api.ts` declares TypeScript interfaces mirroring
//! these types **by hand**. Nothing generates that file and, until this fixture,
//! nothing checked it. A renamed field in Rust reached the phone as `undefined`
//! — no error on either side, just a screen that stopped showing a number.
//!
//! This is the same trick `forge-crypto`'s `interop.rs` plays with envelopes,
//! for the same reason: the failure is silent, in the field, and cheap to catch
//! here. Rust writes the fixture from its own types; `wire.test.ts` reads it and
//! asserts that every key the TypeScript side declares is actually present.
//!
//! Regenerate with `cargo test -p forge-proto --test wire_fixture -- --ignored`
//! after changing any wire type, then re-run `pnpm -r test`. A change that
//! renames a field will regenerate happily and fail on the TypeScript side,
//! which is exactly the intent — the fixture is not the contract, the two
//! independent readings of it are.

use std::path::PathBuf;

use forge_proto::commands::{Command, PlanAction, Review};
use forge_proto::diff::{ChangeKind, ChangeSet, DiffLine, FileDiff, Hunk, Tag};
use forge_proto::events::{CommandRejected, ServerEvent};
use forge_proto::types::{
    Agent, Approval, BatchItem, BatchStatus, DecidedVia, Decision, Risk, TaskStatus, TaskType, Tier,
};
use forge_proto::views::{
    ApprovalView, BudgetView, DashboardView, FleetView, OutputLine, PlanProgress, PlanStepView,
    SessionDetail, SessionView, SpendBucket, TaskDetail, TaskView, TierSlice,
};

const AT: i64 = 1_785_369_600_000;

fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/wire.json")
}

/// Every shape a client parses, with every optional field populated.
///
/// Populated rather than `null` on purpose: a `null` tells the TypeScript side
/// the key exists but not what it carries, and a key that is present-but-null in
/// the fixture would still pass a presence check after Rust changed its type.
fn build() -> serde_json::Value {
    let approval = Approval {
        id: "approval-1".into(),
        session_id: "session-1".into(),
        tool: "Bash".into(),
        payload: "git push --force".into(),
        risk: Risk::Destructive,
        decision: Some(Decision::Denied),
        decided_via: Some(DecidedVia::Phone),
        requested_at: AT,
        decided_at: Some(AT + 3_200),
    };

    let budget = BudgetView {
        cap_usd: Some(10.0),
        spent_usd: 8.5,
        pct: Some(0.85),
        state: "warn",
    };

    let session = SessionView {
        id: "session-1".into(),
        repo_name: "payments-api".into(),
        machine_name: "hetzner-1".into(),
        agent: Agent::ClaudeCode.as_str().to_owned(),
        status: forge_proto::types::SessionStatus::AwaitingApproval,
        is_live: true,
        plan: Some(PlanProgress {
            settled: 2,
            total: 5,
            current_ordinal: Some(3),
            current_title: Some("Wire the retry path".into()),
        }),
        budget: budget.clone(),
        started_at: AT,
        ended_at: Some(AT + 60_000),
        awaiting_approval_id: Some("approval-1".into()),
    };

    let task = TaskView {
        id: "task-1".into(),
        session_id: "session-1".into(),
        repo_id: "repo-1".into(),
        repo_name: "payments-api".into(),
        repo_path: "/srv/payments-api".into(),
        prompt: "Make the retry path give up".into(),
        status: TaskStatus::AwaitingReview,
        summary: "Bounded the retry loop".into(),
        files_changed: 3,
        lines_added: 42,
        lines_removed: 17,
        change_summary: "3 files, +42 −17".into(),
        steps: 9,
        cost_usd: 0.42,
        error: Some("a tool call failed once".into()),
        review_note: Some("too broad, try again".into()),
        verify_grade: Some("concerns".into()),
        verify_notes: Some("the timeout is not covered".into()),
        verify_model: Some("claude-opus-5".into()),
        decided_via: Some(DecidedVia::Web),
        created_at: AT,
        updated_at: AT + 1_000,
        decided_at: Some(AT + 2_000),
    };

    let approval_view = ApprovalView {
        approval: approval.clone(),
        repo_name: "payments-api".into(),
        allows_watch_decision: false,
        budget: budget.clone(),
    };

    let changes = ChangeSet {
        files: vec![FileDiff {
            path: "src/retry.rs".into(),
            kind: ChangeKind::Modified,
            added: 2,
            removed: 1,
            hunks: vec![Hunk {
                old_start: 10,
                old_len: 3,
                new_start: 10,
                new_len: 4,
                lines: vec![
                    DiffLine {
                        tag: Tag::Context,
                        text: "fn retry() {".into(),
                    },
                    DiffLine {
                        tag: Tag::Remove,
                        text: "    loop {}".into(),
                    },
                    DiffLine {
                        tag: Tag::Add,
                        text: "    for _ in 0..3 {}".into(),
                    },
                ],
            }],
            binary: false,
        }],
    };

    let output = vec![OutputLine {
        seq: 7,
        text: "compiling…".into(),
        at_ms: AT,
    }];

    serde_json::json!({
        "events": [
            ServerEvent::SessionUpsert { session_id: "session-1".into() },
            ServerEvent::OutputChunk {
                session_id: "session-1".into(),
                line: output[0].clone(),
            },
            ServerEvent::ApprovalRequest { approval: approval.clone() },
            ServerEvent::ApprovalDecision {
                approval_id: "approval-1".into(),
                session_id: "session-1".into(),
                decision: Decision::Approved,
            },
            ServerEvent::BudgetAlert {
                session_id: "session-1".into(),
                pct: 0.85,
                hard_stop: false,
            },
            ServerEvent::TaskUpsert {
                task_id: "task-1".into(),
                session_id: "session-1".into(),
                status: TaskStatus::AwaitingReview,
                summary: "3 files, +42 −17".into(),
            },
        ],
        "command_error": CommandRejected::new("destructive commands must be approved from the phone"),
        "commands": [
            Command::Decide { approval_id: "approval-1".into(), decision: Decision::Approved },
            Command::Instruct { session_id: "session-1".into(), text: "focus on retries".into() },
            Command::PlanControl { session_id: "session-1".into(), action: PlanAction::Skip },
            Command::SessionSnapshot { session_id: "session-1".into() },
            Command::DashboardSnapshot { session_id: "session-1".into(), since_ms: Some(AT) },
            Command::ReviewTask {
                task_id: "task-1".into(),
                decision: Review::Approve,
                note: Some("looks right".into()),
            },
            Command::TaskSnapshot { task_id: "task-1".into() },
            Command::TaskList,
            Command::RevertTask { task_id: "task-1".into() },
            Command::Snapshot,
        ],
        "fleet_view": FleetView {
            sessions: vec![session.clone()],
            pending_approvals: vec![approval_view.clone()],
            tasks_awaiting_review: vec![task.clone()],
            today_usd: 12.34,
            cache_hit_ratio: Some(0.91),
        },
        "session_detail": SessionDetail {
            session: session.clone(),
            steps: vec![PlanStepView {
                ordinal: 3,
                title: "Wire the retry path".into(),
                status: forge_proto::types::PlanStepStatus::Active,
                checkpoint_sha: Some("a1b2c3d".into()),
            }],
            output: output.clone(),
            pending_approval: Some(approval_view),
        },
        "task_detail": TaskDetail {
            task,
            patch: changes.render(),
            changes,
            output,
        },
        "dashboard_view": DashboardView {
            session_id: "session-1".into(),
            repo_name: "payments-api".into(),
            calls: 12,
            total_usd: 1.23,
            cache_hit_ratio: Some(0.91),
            by_tier: vec![TierSlice {
                tier: Tier::Large.as_str().to_owned(),
                usd: 1.0,
                share: 0.81,
            }],
            avoided_calls: 3,
            spend_series: vec![SpendBucket { at_ms: AT, usd: 0.5 }],
            budget,
        },
        "batch_item": BatchItem {
            id: "batch-item-1".into(),
            session_id: "session-1".into(),
            custom_id: "custom-1".into(),
            task_type: TaskType::Summarize,
            model: "claude-haiku-4-5".into(),
            tier: Tier::Small,
            request_json: "{}".into(),
            batch_id: Some("msgbatch_1".into()),
            status: BatchStatus::Submitted,
            response_text: Some("done".into()),
            error: Some("none".into()),
            queued_at: AT,
            submitted_at: Some(AT + 1),
            settled_at: Some(AT + 2),
        },
    })
}

/// The committed fixture must match what the current types produce.
///
/// Fails when a wire type changes without the fixture being regenerated, which
/// is the prompt to re-run the TypeScript half and find out whether the clients
/// still agree.
#[test]
fn the_committed_fixture_matches_the_current_types() {
    let raw = std::fs::read_to_string(fixture_path()).expect(
        "tests/fixtures/wire.json is missing — regenerate with \
         `cargo test -p forge-proto --test wire_fixture -- --ignored`",
    );
    let committed: serde_json::Value =
        serde_json::from_str(&raw).expect("the fixture is not valid JSON");

    assert_eq!(
        committed,
        build(),
        "a wire type changed. Regenerate with \
         `cargo test -p forge-proto --test wire_fixture -- --ignored`, then run \
         `pnpm -r test` — the TypeScript half is what decides whether the \
         clients still parse it."
    );
}

/// Every `ServerEvent` and `Command` variant appears, so the fixture cannot
/// silently stop covering one that was added later.
#[test]
fn the_fixture_covers_every_variant() {
    let fixture = build();

    let event_tags: Vec<&str> = fixture["events"]
        .as_array()
        .unwrap()
        .iter()
        .map(|event| event["type"].as_str().unwrap())
        .collect();
    assert_eq!(
        event_tags,
        [
            "session_upsert",
            "output_chunk",
            "approval_request",
            "approval_decision",
            "budget_alert",
            "task_upsert",
        ],
        "every ServerEvent variant must be in the fixture"
    );

    let command_tags: Vec<&str> = fixture["commands"]
        .as_array()
        .unwrap()
        .iter()
        .map(|command| command["type"].as_str().unwrap())
        .collect();
    assert_eq!(
        command_tags,
        [
            "decide",
            "instruct",
            "plan_control",
            "session_snapshot",
            "dashboard_snapshot",
            "review_task",
            "task_snapshot",
            "task_list",
            "revert_task",
            "snapshot",
        ],
        "every Command variant must be in the fixture"
    );
}

/// Not a test — the generator. Run with `-- --ignored`.
#[test]
#[ignore = "regenerates the checked-in fixture"]
fn regenerate() {
    let path = fixture_path();
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let json = serde_json::to_string_pretty(&build()).unwrap();
    std::fs::write(&path, format!("{json}\n")).unwrap();
    println!("wrote {}", path.display());
}
