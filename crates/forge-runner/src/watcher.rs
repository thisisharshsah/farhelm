//! Supervising an agent that has no hook system.
//!
//! Claude Code calls the runner and blocks. Everything else asks in its own
//! terminal and waits for a keystroke — which nobody is there to press. This
//! module closes that loop: it reads the question out of the pane, raises an
//! ordinary [`Approval`], and types the answer back when a human decides.
//!
//! # It goes through the same queue as everything else
//!
//! An approval raised here is indistinguishable downstream from one Claude Code
//! blocked on: the same destructive-command classifier, the same D3 rule about
//! watches, the same budget meter, the same push notification. That is the point
//! — supporting a new agent must not mean a second, weaker approval path.
//!
//! # The one thing it will not do is guess
//!
//! Detection is pattern matching on terminal output, which is a heuristic. The
//! failure this is tuned against is **typing `y` at something nobody agreed
//! to**. So:
//!
//! - Nothing is ever answered automatically. A prompt raises an approval and
//!   waits, exactly as the hook path does.
//! - A prompt that does not match any dialect is simply not seen, and the
//!   session sits there — which is what would have happened without RelayForge.
//! - The same question is raised once. Re-detecting it while it is still on
//!   screen must not produce a second approval, or one decision would leave the
//!   other pending forever.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use forge_core::agent::{self, DetectedPrompt};
use forge_core::risk;
use forge_core::types::{Approval, Decision, Session, SessionStatus};

use crate::session::ManagerError;
use crate::state::{AppState, ServerEvent};
use crate::terminal::Terminal;
use forge_core::id::new_id;
use forge_core::store::prelude::*;
use forge_core::time::now_ms;

/// What the watcher remembers between polls, per session.
///
/// Only the question it last raised. Anything more would be state to keep in
/// sync with the database for no gain.
#[derive(Default)]
pub struct SeenPrompts {
    last: Mutex<HashMap<String, String>>,
}

impl SeenPrompts {
    /// True if this is a question we have not already raised for this session.
    fn is_new(&self, session_id: &str, question: &str) -> bool {
        let mut last = self.last.lock().expect("seen prompts poisoned");
        match last.get(session_id) {
            Some(previous) if previous == question => false,
            _ => {
                last.insert(session_id.to_owned(), question.to_owned());
                true
            }
        }
    }

    /// Forget a session's question, so the *same* prompt can be raised again
    /// after it has been answered and re-asked.
    pub fn clear(&self, session_id: &str) {
        self.last
            .lock()
            .expect("seen prompts poisoned")
            .remove(session_id);
    }
}

/// Scan one session's pane and raise an approval if it is waiting on one.
///
/// Returns the approval id if one was raised. `None` covers every ordinary
/// case: not a prompt-supervised agent, no question on screen, or a question
/// already raised.
pub async fn scan_session<T: Terminal>(
    state: &Arc<AppState>,
    terminal: &T,
    seen: &SeenPrompts,
    session: &Session,
    pane: &str,
) -> Result<Option<String>, ManagerError> {
    let spec = agent::spec(session.agent);
    let Some(dialect) = spec.dialect() else {
        return Ok(None);
    };

    let Some(prompt) = agent::detect_prompt(pane, dialect) else {
        // The question is gone: either answered, or scrolled away. Forget it so
        // the identical question can be raised if the agent asks again.
        seen.clear(&session.id);
        return Ok(None);
    };

    if !seen.is_new(&session.id, &prompt.question) {
        return Ok(None);
    }

    // An approval already pending for this session means the previous question
    // is still unanswered. Raising another would leave one orphaned.
    if pending_for(state, &session.id)?.is_some() {
        return Ok(None);
    }

    let approval = raise(state, session, &prompt)?;
    let id = approval.id.clone();

    let _ = terminal; // The answer is typed on decision, not here.
    Ok(Some(id))
}

/// The approval this session is currently blocked on, if any.
fn pending_for(state: &Arc<AppState>, session_id: &str) -> Result<Option<Approval>, ManagerError> {
    Ok(state
        .store
        .list_pending_approvals()?
        .into_iter()
        .find(|approval| approval.session_id == session_id))
}

/// Turn a detected question into an approval row and tell every client.
fn raise(
    state: &Arc<AppState>,
    session: &Session,
    prompt: &DetectedPrompt,
) -> Result<Approval, ManagerError> {
    // The same classifier the hook path uses. A `rm -rf` read off a terminal is
    // exactly as destructive as one announced through a hook, and gets the same
    // phone-only treatment.
    let risk = risk::classify_with(&state.policy, "Bash", &prompt.payload);

    let approval = Approval {
        id: new_id(),
        session_id: session.id.clone(),
        tool: "Bash".into(),
        payload: prompt.payload.clone(),
        risk,
        decision: None,
        decided_via: None,
        requested_at: now_ms(),
        decided_at: None,
    };
    state.store.create_approval(&approval)?;

    let mut waiting = session.clone();
    waiting.status = SessionStatus::AwaitingApproval;
    state.store.upsert_session(&waiting)?;

    state.push_output(
        &session.id,
        format!("⏳ awaiting approval — {}", prompt.payload),
        now_ms(),
    );
    state.publish(ServerEvent::ApprovalRequest {
        approval: approval.clone(),
    });
    state.publish(ServerEvent::SessionUpsert {
        session_id: session.id.clone(),
    });

    Ok(approval)
}

/// Type a decision into the agent's terminal.
///
/// Called after a decision is recorded, for prompt-supervised agents only —
/// Claude Code's hook is already blocked on the answer and needs nothing typed.
/// Returns `false` when there was nothing to type into, which is not an error:
/// a session adopted from a hook callback has no pane the runner owns.
pub async fn answer<T: Terminal>(
    state: &Arc<AppState>,
    terminal: &T,
    seen: &SeenPrompts,
    session: &Session,
    decision: Decision,
) -> Result<bool, ManagerError> {
    let Some(dialect) = agent::spec(session.agent).dialect() else {
        return Ok(false);
    };
    let Some(target) = session.tmux_target.as_deref() else {
        return Ok(false);
    };

    // A timeout is not an answer. Typing the deny key would be a decision
    // nobody made; leaving it lets the agent's own timeout handling run.
    let keys = match decision {
        Decision::Approved => dialect.approve,
        Decision::Denied => dialect.deny,
        Decision::Timeout => return Ok(false),
    };

    terminal.send_line(target, keys).await?;

    // The question is answered, so the next identical one is a new question.
    seen.clear(&session.id);

    let mut running = session.clone();
    if running.status == SessionStatus::AwaitingApproval {
        running.status = SessionStatus::Running;
        state.store.upsert_session(&running)?;
        state.publish(ServerEvent::SessionUpsert {
            session_id: session.id.clone(),
        });
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal::FakeTerminal;
    use forge_core::store::SqliteStore;
    use forge_core::types::{Agent, DecidedVia, Repo, Risk};
    use forge_domain::ApprovalRules as _;

    const NOW: i64 = 1_785_369_600_000;

    fn fixture(agent: Agent) -> (Arc<AppState>, Session, FakeTerminal, SeenPrompts) {
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

        let session = Session {
            id: "s1".into(),
            repo_id: "r1".into(),
            agent,
            tmux_target: Some("forge:1.0".into()),
            status: SessionStatus::Running,
            plan_id: None,
            budget_usd: None,
            spent_usd: 0.0,
            started_at: NOW,
            ended_at: None,
            agent_session_id: None,
        };
        state.store.upsert_session(&session).unwrap();

        (
            state,
            session,
            FakeTerminal::default(),
            SeenPrompts::default(),
        )
    }

    const WAITING: &str = "\
$ rm -rf ./build
Proceed? (y/n)";

    #[tokio::test]
    async fn a_terminal_prompt_becomes_an_ordinary_approval() {
        let (state, session, terminal, seen) = fixture(Agent::OpenCode);

        let id = scan_session(&state, &terminal, &seen, &session, WAITING)
            .await
            .unwrap()
            .expect("the prompt should have been seen");

        let approval = state.store.get_approval(&id).unwrap().unwrap();
        assert_eq!(approval.payload, "$ rm -rf ./build");
        assert_eq!(approval.session_id, "s1");
        // And the session says why it is not moving.
        assert_eq!(
            state.store.get_session("s1").unwrap().unwrap().status,
            SessionStatus::AwaitingApproval
        );
    }

    #[tokio::test]
    async fn it_is_classified_by_the_same_rules_as_a_hook_approval() {
        // A `rm -rf` read off a terminal is exactly as destructive as one
        // announced through a hook, and must get the same phone-only handling.
        let (state, session, terminal, seen) = fixture(Agent::OpenCode);
        let id = scan_session(&state, &terminal, &seen, &session, WAITING)
            .await
            .unwrap()
            .unwrap();

        let approval = state.store.get_approval(&id).unwrap().unwrap();
        assert_eq!(approval.risk, Risk::Destructive);
        assert!(!approval.allows_watch_decision());
    }

    #[tokio::test]
    async fn the_same_question_is_only_raised_once() {
        // The poller runs every few seconds and the question stays on screen
        // the whole time. A second approval would leave one pending forever.
        let (state, session, terminal, seen) = fixture(Agent::OpenCode);

        assert!(
            scan_session(&state, &terminal, &seen, &session, WAITING)
                .await
                .unwrap()
                .is_some()
        );
        for _ in 0..5 {
            assert!(
                scan_session(&state, &terminal, &seen, &session, WAITING)
                    .await
                    .unwrap()
                    .is_none()
            );
        }
    }

    #[tokio::test]
    async fn an_agent_with_a_hook_is_left_alone() {
        // Claude Code's approvals arrive through the bridge. Reading its
        // terminal as well would double every request.
        let (state, session, terminal, seen) = fixture(Agent::ClaudeCode);
        let pane = "Do you want to proceed?\n❯ 1. Yes";
        assert_eq!(
            scan_session(&state, &terminal, &seen, &session, pane)
                .await
                .unwrap(),
            None
        );
    }

    #[tokio::test]
    async fn a_plain_shell_raises_nothing() {
        let (state, session, terminal, seen) = fixture(Agent::Shell);
        assert_eq!(
            scan_session(&state, &terminal, &seen, &session, WAITING)
                .await
                .unwrap(),
            None
        );
    }

    #[tokio::test]
    async fn ordinary_output_raises_nothing() {
        let (state, session, terminal, seen) = fixture(Agent::OpenCode);
        let pane = "   Compiling forge-core\n    Finished in 3.2s";
        assert_eq!(
            scan_session(&state, &terminal, &seen, &session, pane)
                .await
                .unwrap(),
            None
        );
        assert_eq!(
            state.store.get_session("s1").unwrap().unwrap().status,
            SessionStatus::Running
        );
    }

    #[tokio::test]
    async fn a_second_question_waits_for_the_first_to_be_answered() {
        let (state, session, terminal, seen) = fixture(Agent::OpenCode);
        scan_session(&state, &terminal, &seen, &session, WAITING)
            .await
            .unwrap()
            .unwrap();

        // A different question, but the first is still pending.
        let next = "$ git push --force\nProceed? (y/n)";
        assert_eq!(
            scan_session(&state, &terminal, &seen, &session, next)
                .await
                .unwrap(),
            None
        );
    }

    /* ------------------------------------------------------------ answer */

    #[tokio::test]
    async fn approving_types_the_agents_yes_key() {
        let (state, session, terminal, seen) = fixture(Agent::OpenCode);
        assert!(
            answer(&state, &terminal, &seen, &session, Decision::Approved)
                .await
                .unwrap()
        );
        assert_eq!(
            terminal.sent(),
            vec![("forge:1.0".to_owned(), "y".to_owned())]
        );
    }

    #[tokio::test]
    async fn denying_types_the_agents_no_key() {
        let (state, session, terminal, seen) = fixture(Agent::OpenCode);
        answer(&state, &terminal, &seen, &session, Decision::Denied)
            .await
            .unwrap();
        assert_eq!(
            terminal.sent(),
            vec![("forge:1.0".to_owned(), "n".to_owned())]
        );
    }

    #[tokio::test]
    async fn a_timeout_types_nothing_at_all() {
        // A timeout is the absence of a decision. Typing the deny key would be
        // a choice nobody made; leaving it lets the agent's own handling run.
        let (state, session, terminal, seen) = fixture(Agent::OpenCode);
        assert!(
            !answer(&state, &terminal, &seen, &session, Decision::Timeout)
                .await
                .unwrap()
        );
        assert!(terminal.sent().is_empty());
    }

    #[tokio::test]
    async fn a_hook_agent_has_nothing_typed_at_it() {
        // Claude Code's hook is already blocked on the answer; typing `y` into
        // its pane would land in whatever it does next.
        let (state, session, terminal, seen) = fixture(Agent::ClaudeCode);
        assert!(
            !answer(&state, &terminal, &seen, &session, Decision::Approved)
                .await
                .unwrap()
        );
        assert!(terminal.sent().is_empty());
    }

    #[tokio::test]
    async fn answering_puts_the_session_back_to_running() {
        let (state, session, terminal, seen) = fixture(Agent::OpenCode);
        scan_session(&state, &terminal, &seen, &session, WAITING)
            .await
            .unwrap();

        let waiting = state.store.get_session("s1").unwrap().unwrap();
        assert_eq!(waiting.status, SessionStatus::AwaitingApproval);

        answer(&state, &terminal, &seen, &waiting, Decision::Approved)
            .await
            .unwrap();
        assert_eq!(
            state.store.get_session("s1").unwrap().unwrap().status,
            SessionStatus::Running
        );
    }

    #[tokio::test]
    async fn the_same_question_can_be_asked_again_after_it_is_answered() {
        // An agent that asks "Proceed?" for every file would otherwise be
        // supervised exactly once.
        let (state, session, terminal, seen) = fixture(Agent::OpenCode);
        scan_session(&state, &terminal, &seen, &session, WAITING)
            .await
            .unwrap()
            .unwrap();

        let id = pending_for(&state, "s1").unwrap().unwrap().id;
        state
            .store
            .decide_approval(&id, Decision::Approved, DecidedVia::Phone, NOW)
            .unwrap();
        answer(&state, &terminal, &seen, &session, Decision::Approved)
            .await
            .unwrap();

        assert!(
            scan_session(&state, &terminal, &seen, &session, WAITING)
                .await
                .unwrap()
                .is_some()
        );
    }

    #[tokio::test]
    async fn a_prompt_that_scrolls_away_is_forgotten() {
        let (state, session, terminal, seen) = fixture(Agent::OpenCode);
        scan_session(&state, &terminal, &seen, &session, WAITING)
            .await
            .unwrap();

        // The agent moved on without us — the question is gone.
        let moved_on = "compiling\ncompiling\ncompiling\ndone";
        scan_session(&state, &terminal, &seen, &session, moved_on)
            .await
            .unwrap();

        // Which means the identical question later is a genuinely new one.
        assert!(seen.is_new("s1", "Proceed? (y/n)"));
    }
}
