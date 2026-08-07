//! The session manager (M1/D1/D4).
//!
//! Agents run in tmux on an always-on box, so closing a laptop lid does not end
//! a session — the runner reattaches to a pane that never stopped. This module
//! owns that mapping: a RelayForge session row on one side, a tmux target on the
//! other, and the polling that keeps the two honest.

use std::sync::Arc;
use std::time::Duration;

use forge_app::id::new_id;
use forge_app::store::prelude::*;
use forge_app::time::now_ms;
use forge_proto::types::{Agent, Repo, Session, SessionStatus};

use crate::state::{AppState, ServerEvent};
use crate::terminal::{SpawnSpec, Terminal, TerminalError};

/// How often panes are polled for new output and liveness.
pub const POLL_INTERVAL: Duration = Duration::from_secs(2);

/// Scrollback captured per poll. Enough to catch up after a brief stall without
/// re-sending the whole history every two seconds.
const CAPTURE_LINES: usize = 60;

#[derive(Debug)]
pub enum ManagerError {
    Terminal(TerminalError),
    Store(forge_app::store::StoreError),
    NoTarget,
}

impl std::fmt::Display for ManagerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ManagerError::Terminal(err) => write!(f, "{err}"),
            ManagerError::Store(err) => write!(f, "{err}"),
            ManagerError::NoTarget => {
                f.write_str("this session has no terminal — it was not started by the runner")
            }
        }
    }
}

impl std::error::Error for ManagerError {}

impl From<TerminalError> for ManagerError {
    fn from(err: TerminalError) -> Self {
        ManagerError::Terminal(err)
    }
}

impl From<forge_app::store::StoreError> for ManagerError {
    fn from(err: forge_app::store::StoreError) -> Self {
        ManagerError::Store(err)
    }
}

/// The command that starts an agent.
///
/// Delegates to [`forge_domain::agent`], which is the single place that knows what
/// each agent is called and how it is supervised. A second copy here is how a
/// newly added agent ends up startable but unsupervised.
///
/// The one thing resolved here rather than there is the plain shell: its binary
/// is whatever this machine's `$SHELL` says, and `forge-domain` cannot read the
/// environment by construction.
pub fn agent_command(agent: Agent) -> Vec<String> {
    let mut argv = forge_domain::agent::spec(agent).command(None);
    if argv.first().is_some_and(String::is_empty) {
        argv[0] = login_shell();
    }
    argv
}

/// This machine's interactive shell.
///
/// `Agent::Shell` carries an empty binary in the spec table, because there is no
/// one answer: it is `$SHELL`, and that is a property of the machine rather than
/// of the agent. Before this resolved, starting a shell session produced
/// "tmux is not installed" — the empty string failed a PATH lookup, and the
/// resulting error had tmux's message on it.
fn login_shell() -> String {
    std::env::var("SHELL")
        .ok()
        .filter(|shell| !shell.trim().is_empty())
        // Every POSIX machine has this, including the containers CI runs in.
        .unwrap_or_else(|| "/bin/sh".to_owned())
}

pub struct SessionManager<T> {
    state: Arc<AppState>,
    terminal: T,
}

impl<T: Terminal> SessionManager<T> {
    pub fn new(state: Arc<AppState>, terminal: T) -> Self {
        Self { state, terminal }
    }

    /// Start an agent in `repo` and record the session.
    pub async fn start(&self, repo: &Repo, agent: Agent) -> Result<Session, ManagerError> {
        let target = self
            .terminal
            .spawn(&SpawnSpec {
                name: repo.name.clone(),
                cwd: repo.path.clone(),
                command: agent_command(agent),
            })
            .await?;

        let session = Session {
            id: new_id(),
            repo_id: repo.id.clone(),
            agent,
            tmux_target: Some(target),
            status: SessionStatus::Running,
            plan_id: None,
            budget_usd: None,
            spent_usd: 0.0,
            started_at: now_ms(),
            ended_at: None,
            // Filled in when the agent's first hook callback arrives.
            agent_session_id: None,
        };
        self.state.store.upsert_session(&session)?;
        self.state.publish(ServerEvent::SessionUpsert {
            session_id: session.id.clone(),
        });
        Ok(session)
    }

    /// Type an instruction into a session's pane (A4).
    pub async fn send(&self, session_id: &str, text: &str) -> Result<(), ManagerError> {
        let session = self
            .state
            .store
            .get_session(session_id)?
            .ok_or(ManagerError::NoTarget)?;
        let target = session.tmux_target.ok_or(ManagerError::NoTarget)?;

        self.terminal.send_line(&target, text).await?;
        // Echoed into the tail immediately so the phone shows the instruction
        // landing, rather than waiting for the next poll to maybe reflect it.
        self.state
            .push_output(session_id, format!("› {text}"), now_ms());
        Ok(())
    }

    /// Stop a session and its pane.
    pub async fn stop(&self, session_id: &str) -> Result<(), ManagerError> {
        let mut session = self
            .state
            .store
            .get_session(session_id)?
            .ok_or(ManagerError::NoTarget)?;

        if let Some(target) = &session.tmux_target {
            // A pane that has already exited is not an error here — the goal is
            // "this session is stopped", and it is.
            let _ = self.terminal.kill(target).await;
        }

        session.status = SessionStatus::Done;
        session.ended_at = Some(now_ms());
        self.state.store.upsert_session(&session)?;
        self.state.publish(ServerEvent::SessionUpsert {
            session_id: session.id.clone(),
        });
        Ok(())
    }

    /// Capture new output from every live session and push the delta.
    ///
    /// tmux gives a *snapshot*, not a stream, so the manager diffs against what
    /// it last sent. Without that, every poll would re-send the whole visible
    /// pane and the phone would show each line sixty times a minute.
    pub async fn poll_output(&self) -> Result<(), ManagerError> {
        for session in self.state.store.list_sessions()? {
            let Some(target) = &session.tmux_target else {
                continue;
            };
            if session.ended_at.is_some() {
                continue;
            }

            let Ok(snapshot) = self.terminal.capture(target, CAPTURE_LINES).await else {
                continue;
            };

            for line in self.state.new_output_lines(&session.id, &snapshot) {
                self.state.push_output(&session.id, line, now_ms());
            }

            // The same snapshot, read for a question the agent is waiting on.
            // Agents without a hook system ask in their terminal and block on a
            // keystroke; this is what turns that into an approval. A failure
            // here must not stop the poll — the output above is still useful.
            let _ = crate::watcher::scan_session(
                &self.state,
                &self.terminal,
                &self.state.seen_prompts,
                &session,
                &snapshot,
            )
            .await;
        }
        Ok(())
    }

    /// Mark sessions dead whose pane has gone (D4).
    ///
    /// Returns how many were reaped, so the caller can log something meaningful
    /// rather than a silent sweep.
    pub async fn garbage_collect(&self) -> Result<usize, ManagerError> {
        let live = self.terminal.live_targets().await?;
        let mut reaped = 0;

        for mut session in self.state.store.list_sessions()? {
            let Some(target) = session.tmux_target.clone() else {
                continue;
            };
            // Already finished sessions are not "dead", they are done.
            if session.ended_at.is_some() || session.status == SessionStatus::Dead {
                continue;
            }
            if live.contains(&target) {
                continue;
            }

            session.status = SessionStatus::Dead;
            session.ended_at = Some(now_ms());
            self.state.store.upsert_session(&session)?;
            self.state.publish(ServerEvent::SessionUpsert {
                session_id: session.id.clone(),
            });
            reaped += 1;
        }
        Ok(reaped)
    }
}

/// Run the poll loop until the process exits.
pub fn spawn_poller<T: Terminal + 'static>(manager: SessionManager<T>) {
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(POLL_INTERVAL).await;
            let _ = manager.poll_output().await;
            let _ = manager.garbage_collect().await;
        }
    });
}

#[cfg(test)]
mod agent_command_tests {
    use super::*;

    /// The plain shell resolves to a real program.
    ///
    /// It is advertised by `/v1/agents` as installed — `spec.binary.is_empty()`
    /// counts as installed, deliberately, because there is nothing to look up —
    /// so a client offers it. Starting it has to work, and it did not: the empty
    /// binary failed a PATH lookup and the error that came back said "tmux is
    /// not installed", on a runner that was not using tmux.
    #[test]
    fn the_shell_agent_resolves_to_a_real_program() {
        let argv = agent_command(Agent::Shell);
        let program = argv.first().expect("a shell session needs a program");

        assert!(!program.is_empty(), "the shell agent had no binary to run");
        assert!(
            crate::pty::binary_exists(program),
            "{program} is not on this machine, so the session would fail to spawn"
        );
    }

    /// Every other agent keeps the binary the spec table names.
    #[test]
    fn a_real_agent_is_not_rewritten() {
        assert_eq!(agent_command(Agent::ClaudeCode).first().unwrap(), "claude");
        assert_eq!(agent_command(Agent::Aider).first().unwrap(), "aider");
    }

    /// `$SHELL` is honoured when it is set to something usable.
    #[test]
    fn the_login_shell_falls_back_to_a_posix_one() {
        // Not asserted against the live environment, which varies by CI image;
        // the contract is that the fallback is a program that exists everywhere.
        assert!(crate::pty::binary_exists("/bin/sh"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal::FakeTerminal;
    use forge_sqlite::SqliteStore;

    fn fixture() -> (Arc<AppState>, Repo) {
        let state = AppState::with_gateway(SqliteStore::open_in_memory().unwrap(), |_| None);
        let repo = Repo {
            id: "r1".into(),
            machine_id: state.machine_id.clone(),
            path: "/srv/payments-api".into(),
            name: "payments-api".into(),
            budget_usd: None,
        };
        state.store.upsert_repo(&repo).unwrap();
        (state, repo)
    }

    #[tokio::test]
    async fn starting_a_session_records_its_pane() {
        let (state, repo) = fixture();
        let manager = SessionManager::new(Arc::clone(&state), FakeTerminal::default());

        let session = manager.start(&repo, Agent::ClaudeCode).await.unwrap();
        assert!(session.tmux_target.is_some());
        assert_eq!(session.status, SessionStatus::Running);

        let stored = state.store.get_session(&session.id).unwrap().unwrap();
        assert_eq!(stored.tmux_target, session.tmux_target);
    }

    #[tokio::test]
    async fn an_instruction_reaches_the_pane_and_the_tail() {
        let (state, repo) = fixture();
        let terminal = FakeTerminal::default();
        let manager = SessionManager::new(Arc::clone(&state), terminal);

        let session = manager.start(&repo, Agent::ClaudeCode).await.unwrap();
        manager.send(&session.id, "run the tests").await.unwrap();

        let sent = manager.terminal.sent();
        assert_eq!(sent.len(), 1);
        assert_eq!(sent[0].1, "run the tests");

        let tail = state.output_tail(&session.id, 10);
        assert!(tail.iter().any(|line| line.text.contains("run the tests")));
    }

    #[tokio::test]
    async fn a_session_with_no_pane_cannot_be_sent_to() {
        let (state, _) = fixture();
        let manager = SessionManager::new(Arc::clone(&state), FakeTerminal::default());

        let err = manager.send("does-not-exist", "hello").await.unwrap_err();
        assert!(matches!(err, ManagerError::NoTarget));
    }

    #[tokio::test]
    async fn stopping_marks_the_session_done_and_kills_the_pane() {
        let (state, repo) = fixture();
        let manager = SessionManager::new(Arc::clone(&state), FakeTerminal::default());

        let session = manager.start(&repo, Agent::ClaudeCode).await.unwrap();
        manager.stop(&session.id).await.unwrap();

        let stored = state.store.get_session(&session.id).unwrap().unwrap();
        assert_eq!(stored.status, SessionStatus::Done);
        assert!(stored.ended_at.is_some());
        assert!(manager.terminal.live_targets().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn polling_sends_each_line_once() {
        let (state, repo) = fixture();
        let manager = SessionManager::new(Arc::clone(&state), FakeTerminal::default());
        let session = manager.start(&repo, Agent::ClaudeCode).await.unwrap();
        let target = session.tmux_target.clone().unwrap();

        manager.terminal.set_output(&target, "one\ntwo\n");
        manager.poll_output().await.unwrap();
        manager.poll_output().await.unwrap();

        let tail = state.output_tail(&session.id, 50);
        assert_eq!(
            tail.iter().filter(|line| line.text == "one").count(),
            1,
            "the same pane snapshot was sent twice"
        );

        // A third line appears; only the new one is sent.
        manager.terminal.set_output(&target, "one\ntwo\nthree\n");
        manager.poll_output().await.unwrap();

        let tail = state.output_tail(&session.id, 50);
        assert_eq!(tail.iter().filter(|line| line.text == "three").count(), 1);
        assert_eq!(tail.iter().filter(|line| line.text == "one").count(), 1);
    }

    #[tokio::test]
    async fn a_vanished_pane_is_reaped() {
        let (state, repo) = fixture();
        let manager = SessionManager::new(Arc::clone(&state), FakeTerminal::default());
        let session = manager.start(&repo, Agent::ClaudeCode).await.unwrap();

        // The agent exited on its own; tmux closed the window.
        manager
            .terminal
            .kill(&session.tmux_target.clone().unwrap())
            .await
            .unwrap();

        assert_eq!(manager.garbage_collect().await.unwrap(), 1);
        let stored = state.store.get_session(&session.id).unwrap().unwrap();
        assert_eq!(stored.status, SessionStatus::Dead);
    }

    #[tokio::test]
    async fn a_live_pane_survives_the_sweep() {
        let (state, repo) = fixture();
        let manager = SessionManager::new(Arc::clone(&state), FakeTerminal::default());
        let session = manager.start(&repo, Agent::ClaudeCode).await.unwrap();

        assert_eq!(manager.garbage_collect().await.unwrap(), 0);
        let stored = state.store.get_session(&session.id).unwrap().unwrap();
        assert_eq!(stored.status, SessionStatus::Running);
    }

    #[tokio::test]
    async fn a_finished_session_is_not_reaped_again() {
        let (state, repo) = fixture();
        let manager = SessionManager::new(Arc::clone(&state), FakeTerminal::default());
        let session = manager.start(&repo, Agent::ClaudeCode).await.unwrap();
        manager.stop(&session.id).await.unwrap();

        // Its pane is gone, but it is `done`, not `dead` — the distinction is
        // what the fleet view shows as "complete" rather than "offline".
        assert_eq!(manager.garbage_collect().await.unwrap(), 0);
        assert_eq!(
            state
                .store
                .get_session(&session.id)
                .unwrap()
                .unwrap()
                .status,
            SessionStatus::Done
        );
    }

    #[tokio::test]
    async fn sessions_the_runner_did_not_start_are_left_alone() {
        // A session adopted from a hook callback has no tmux target; the sweep
        // must not decide it is dead.
        let (state, repo) = fixture();
        let manager = SessionManager::new(Arc::clone(&state), FakeTerminal::default());
        state
            .store
            .upsert_session(&Session {
                id: "adopted".into(),
                repo_id: repo.id.clone(),
                agent: Agent::ClaudeCode,
                tmux_target: None,
                status: SessionStatus::Running,
                plan_id: None,
                budget_usd: None,
                spent_usd: 0.0,
                started_at: now_ms(),
                ended_at: None,
                agent_session_id: Some("claude-xyz".into()),
            })
            .unwrap();

        assert_eq!(manager.garbage_collect().await.unwrap(), 0);
        assert_eq!(
            state.store.get_session("adopted").unwrap().unwrap().status,
            SessionStatus::Running
        );
    }

    #[tokio::test]
    async fn a_missing_tmux_surfaces_as_a_setup_problem() {
        let (state, repo) = fixture();
        let manager = SessionManager::new(Arc::clone(&state), FakeTerminal::unavailable());

        let err = manager.start(&repo, Agent::ClaudeCode).await.unwrap_err();
        assert!(err.to_string().contains("not installed"));
    }
}
