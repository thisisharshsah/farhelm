//! The agent loop: a prompt goes in, a reviewable diff comes out.
//!
//! Every model call goes through [`Gateway::complete`], which is the point. The
//! loop gets budget enforcement, tiered routing, retrieval, cache-shaped prompts
//! and ledger accounting for free, because it is a *caller* of the cost gateway
//! rather than a second path to a provider. An agent that could reach the API
//! directly would make every guarantee in this repo advisory.
//!
//! ## Retrieval and the pre-gate run once, on the first step
//!
//! Stage 2 shells out to a formatter, a linter, a type-checker and a test suite;
//! stage 5 walks the repo. Both are worth doing when a task starts and neither
//! is worth doing twelve more times while the agent reads files.
//!
//! So the first call passes `repo_path` and the rest do not, carrying the repo
//! map forward verbatim. That is not only cheaper, it is *what makes the loop
//! cache*: a repo map recomputed from a changing instruction would move bytes
//! that sit ahead of a `cache_control` breakpoint, and every step after the
//! first would pay full input rates on the whole prefix.
//!
//! ## Tool turns are recorded as text
//!
//! The provider is sent real `tools` and answers with real `tool_use` blocks.
//! What goes back into *history* is a rendered transcript of those calls rather
//! than structured content blocks.
//!
//! The reason is the cache contract. History is assembled by
//! [`forge_gateway::prompt`] as plain [`Turn`]s, and the compaction pass (C7)
//! summarises them as text. Threading content blocks through both would mean
//! reworking the most heavily tested code in the repo — the part that turns a
//! 0% cache-read ratio into a 99% one — to buy fidelity the model does not
//! appear to need. The trade is written down here rather than discovered later.

use std::path::{Path, PathBuf};

use forge_app::store::prelude::*;
use forge_gateway::prompt::{StableContext, Turn};
use forge_gateway::{CompleteRequest, Gateway, GatewayError, ModelClient, ToolCall};
use forge_proto::types::TaskType;

use crate::diff::ChangeSet;
use crate::git::Worktree;
use crate::tools::{self, Supervisor};
use crate::workspace::Workspace;

/// Frozen. Nothing in here may vary between calls — a date, a session id, or a
/// repo name would move the first cache breakpoint on every single turn.
pub const SYSTEM_PROMPT: &str = "\
You are RelayForge's coding agent. You work in one repository and produce a \
change set that a human reviews as a diff before anything is written to disk.

How to work:
- Find out what is really there before changing it. Search and read; do not \
guess at filenames or APIs.
- Make the smallest change that does the job, and match the surrounding code's \
style, naming and comment density.
- Prefer edit_file over write_file for files that already exist.
- Your edits are staged, not applied. Nobody sees them until you stop, so leave \
the change set in a state you would defend.
- The run tool needs a human to approve each command and executes against the \
working tree WITHOUT your staged edits, so a test run will not see your work.
- When you are done, stop calling tools and reply with a short summary of what \
you changed and why. That summary is what the reviewer reads first.
- If the task cannot be done, say so plainly instead of changing something else.";

/// Steps before the loop gives up. High enough for real work, low enough that a
/// model stuck in a read-search-read cycle stops costing money by lunchtime.
pub const DEFAULT_MAX_STEPS: usize = 24;

/// Files read into the stable half as repo conventions, in priority order.
const CONVENTION_FILES: &[&str] = &["CLAUDE.md", "AGENTS.md", ".cursorrules"];

/// Cap on conventions pulled into every prompt. They sit ahead of a breakpoint,
/// so they are cached — but a 200 KB house-style document is still 200 KB the
/// first call pays for.
const MAX_CONVENTION_BYTES: usize = 8 * 1024;

#[derive(Debug, Clone)]
pub struct TaskSpec {
    /// The session this task's spend is billed to.
    pub session_id: String,
    /// Names this task's branch and its checkout. Distinct from `session_id`
    /// because a retry is a new task on the same session, and two tasks sharing
    /// a branch would have one silently inherit the other's work.
    pub task_id: String,
    pub repo_path: PathBuf,
    /// What the human asked for.
    pub prompt: String,
    pub max_steps: usize,
    /// Have the frontier model read the finished diff (C10).
    ///
    /// On by default. It is one call on a few kilobytes, and the alternative it
    /// replaces — drafting on the frontier tier throughout — costs far more.
    /// See [`crate::verify`].
    pub verify: bool,
}

impl TaskSpec {
    pub fn new(
        session_id: impl Into<String>,
        repo_path: impl Into<PathBuf>,
        prompt: impl Into<String>,
    ) -> Self {
        let session_id = session_id.into();
        Self {
            // Callers that have a real task id set it; the default keeps the
            // branch tied to something rather than to a constant every task
            // would collide on.
            task_id: session_id.clone(),
            session_id,
            repo_path: repo_path.into(),
            prompt: prompt.into(),
            max_steps: DEFAULT_MAX_STEPS,
            verify: true,
        }
    }

    /// Name this task's branch after `id`.
    pub fn with_task_id(mut self, id: impl Into<String>) -> Self {
        self.task_id = id.into();
        self
    }
}

/// How a run ended.
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    /// The agent stopped on its own with files changed. The normal ending.
    Proposed,
    /// It stopped with nothing staged — a question answered, or a task that
    /// turned out to need no change. Not a failure, and not something to put a
    /// review card in front of somebody for.
    NoChanges,
    /// It ran out of steps. Whatever is staged is still reviewable: a
    /// half-finished change set a human can look at beats throwing the work
    /// away and billing for it anyway.
    StepLimit,
    /// The model declined the task.
    Refused(String),
    /// A budget cap stopped it. Named separately from [`Outcome::Failed`]
    /// because it is the one failure that is working as intended.
    BudgetExhausted(String),
    Failed(String),
}

impl Outcome {
    /// Whether this ending should put a card in front of a human.
    pub fn needs_review(&self) -> bool {
        matches!(self, Outcome::Proposed | Outcome::StepLimit)
    }
}

/// Everything one run produced.
#[derive(Debug)]
pub struct TaskRun {
    pub outcome: Outcome,
    /// The branch and checkout the work is on. `None` only when the task never
    /// got one — an unusable repository — in which case there is nothing to
    /// review, merge or discard.
    ///
    /// Serialisable, so a task can wait for review across a runner restart. The
    /// overlay this replaced had to serialise both sides of every file it
    /// touched; this is four strings, because the work itself is in git.
    pub worktree: Option<Worktree>,
    pub changes: ChangeSet,
    /// The agent's closing message — the first thing a reviewer reads.
    pub summary: String,
    /// The full conversation, for the session detail screen.
    pub transcript: Vec<Turn>,
    /// The frontier model's read of the diff (C10). `None` when verification
    /// was switched off, or when there was no change set to judge.
    pub assessment: Option<crate::verify::Assessment>,
    /// Everything this task cost, drafting and verification together.
    pub cost_usd: f64,
    pub steps: usize,
}

/// Repo conventions, if the repo states any.
fn conventions(root: &Path) -> String {
    for name in CONVENTION_FILES {
        let path = root.join(name);
        if let Ok(text) = std::fs::read_to_string(&path)
            && !text.trim().is_empty()
        {
            let mut text = text.trim().to_owned();
            if text.len() > MAX_CONVENTION_BYTES {
                // Truncate on a char boundary; conventions files are prose and
                // may well be full of typography.
                let mut end = MAX_CONVENTION_BYTES;
                while end > 0 && !text.is_char_boundary(end) {
                    end -= 1;
                }
                text.truncate(end);
            }
            return text;
        }
    }
    String::new()
}

/// Render the assistant's turn — its prose plus the calls it made — for history.
fn render_assistant(text: &str, calls: &[ToolCall]) -> String {
    let mut out = String::new();
    if !text.trim().is_empty() {
        out.push_str(text.trim());
    }
    for call in calls {
        if !out.is_empty() {
            out.push('\n');
        }
        out.push_str(&format!(
            "[tool_use:{}] {} {}",
            call.id, call.name, call.input
        ));
    }
    out
}

/// Render one tool result for the next turn's dynamic tail.
fn render_result(call: &ToolCall, body: &str, failed: bool) -> String {
    format!(
        "[tool_{}:{}]\n{body}",
        if failed { "error" } else { "result" },
        call.id
    )
}

/// Run a task to completion.
///
/// Never returns `Err`: every ending — refusal, budget stop, step limit, a tool
/// that could not run — is a [`TaskRun`] carrying whatever was staged before it
/// happened. A task that spent money and then returned an error type would have
/// nothing to show for the spend, which is the one outcome the ledger cannot
/// justify.
pub async fn run<S: Store, C: ModelClient, Sup: Supervisor>(
    gateway: &Gateway<S, C>,
    supervisor: &Sup,
    spec: &TaskSpec,
) -> TaskRun {
    /// A run that ended before it had anywhere to work.
    fn failed(why: String) -> TaskRun {
        TaskRun {
            outcome: Outcome::Failed(why),
            worktree: None,
            changes: ChangeSet::default(),
            summary: String::new(),
            transcript: Vec::new(),
            assessment: None,
            cost_usd: 0.0,
            steps: 0,
        }
    }

    // Cut the branch before anything else. A task with nowhere isolated to work
    // must not start: the alternative is an agent editing the tree somebody is
    // sitting in, which is precisely what this crate exists to prevent.
    //
    // Git is required, and the two ways it can be missing are reported apart
    // because they have different fixes — one is "this is not a repository",
    // the other is "commit once first".
    let worktree = match Worktree::create(&spec.repo_path, &spec.task_id) {
        Ok(worktree) => worktree,
        Err(err) => return failed(err.to_string()),
    };

    // The agent reads and writes through the checkout, never the repository.
    let mut workspace = match Workspace::open(worktree.path()) {
        Ok(workspace) => workspace,
        Err(err) => {
            // The branch exists but is unusable. Take it back out rather than
            // leaving a checkout nobody will ever look at.
            let message = err.to_string();
            let _ = worktree.discard();
            return failed(message);
        }
    };

    let mut stable = StableContext {
        tools: tools::definitions(),
        system: SYSTEM_PROMPT.to_owned(),
        conventions: conventions(&spec.repo_path),
        repo_map: String::new(),
        history: Vec::new(),
    };

    let mut pending = spec.prompt.clone();
    let mut cost_usd = 0.0;
    let mut summary = String::new();
    let mut steps = 0;
    let mut outcome = Outcome::StepLimit;

    while steps < spec.max_steps {
        steps += 1;

        let mut request = CompleteRequest::new(&spec.session_id, TaskType::Edit, &pending);
        request.stable = stable.clone();
        // Only the first step pays for retrieval and the pre-gate. See the
        // module docs: this is a caching decision as much as a cost one.
        request.repo_path = (steps == 1).then(|| spec.repo_path.clone());

        let response = match gateway.complete(request).await {
            Ok(response) => response,
            Err(GatewayError::BudgetExhausted { scope, budget }) => {
                outcome = Outcome::BudgetExhausted(format!(
                    "the {scope} budget is spent (${:.4} of ${:.2})",
                    budget.spent_usd,
                    budget.cap_usd.unwrap_or(0.0)
                ));
                break;
            }
            Err(err) => {
                outcome = Outcome::Failed(err.to_string());
                break;
            }
        };

        cost_usd += response.cost_usd;

        // The gateway holds no session state, so a compacted history has to be
        // adopted here or the next turn re-summarises the same turns and throws
        // away the prompt cache doing it.
        if let Some(compacted) = response.compacted_history {
            stable.history = compacted;
        }
        if stable.repo_map.is_empty() && !response.trace.context.is_empty() {
            stable.repo_map = response.trace.context.render();
        }

        if let Some(refusal) = &response.refusal {
            outcome = Outcome::Refused(
                refusal
                    .explanation
                    .clone()
                    .unwrap_or_else(|| "the model declined this task".into()),
            );
            break;
        }

        if response.tool_calls.is_empty() {
            summary = response.text.trim().to_owned();
            // Asking git rather than an in-memory map: one `git diff`, once,
            // at the point the model says it is finished.
            outcome = if worktree.change_set().is_ok_and(|set| set.is_empty()) {
                Outcome::NoChanges
            } else {
                Outcome::Proposed
            };
            break;
        }

        // History grows by appending, which is what keeps the earlier
        // breakpoints readable on the next turn.
        stable
            .history
            .push(Turn::user(std::mem::take(&mut pending)));
        stable.history.push(Turn::assistant(render_assistant(
            &response.text,
            &response.tool_calls,
        )));

        let mut results = Vec::with_capacity(response.tool_calls.len());
        for call in &response.tool_calls {
            supervisor.note(&format!("▸ {}", tools::summary(call)));
            let rendered = match tools::execute(call, &mut workspace, supervisor).await {
                Ok(body) => render_result(call, &body, false),
                // A tool error is not a task failure. The model gets told what
                // went wrong and takes another turn, which is what a person at
                // a terminal would do with a typo'd filename.
                Err(err) => render_result(call, &err.to_string(), true),
            };
            results.push(rendered);
        }
        pending = results.join("\n\n");
    }

    if outcome == Outcome::StepLimit {
        summary = format!(
            "Stopped after {steps} steps without finishing. \
             What follows is the change set as it stood."
        );
    }

    // Close the transcript out. Whatever is in `pending` was produced but never
    // sent — on a normal ending it is the tool results the model replied to, on
    // a denial it is the reason it was given. Dropping it would leave the
    // session detail screen showing a conversation with its last exchange
    // missing, which reads as a bug in the runner rather than the end of a task.
    if !pending.trim().is_empty() {
        stable.history.push(Turn::user(pending));
    }
    if !summary.trim().is_empty() {
        stable.history.push(Turn::assistant(summary.clone()));
    }

    // Presentation still belongs to `crate::diff`, so the bytes that reach a
    // phone are produced by the same differ with the same line numbering the
    // clients have unit tests for. Git decides isolation and lifecycle; the
    // change set is unchanged, which is the only reason this swap does not
    // touch three clients.
    let changes = worktree.change_set().unwrap_or_default();

    // ---- C10: one frontier call, on the diff alone --------------------------
    //
    // After the loop, never inside it. A verifier that ran per step would be
    // judging half-finished work at the tier that costs the most to be wrong
    // about, and would fire a dozen times for one answer.
    let assessment = if spec.verify && outcome.needs_review() {
        let assessment =
            crate::verify::assess(gateway, &spec.session_id, &spec.prompt, &changes).await;
        if let Some(assessment) = &assessment {
            cost_usd += assessment.cost_usd;
            supervisor.note(&format!(
                "◆ reviewed by {}: {}",
                if assessment.model.is_empty() {
                    "nothing"
                } else {
                    &assessment.model
                },
                assessment.grade.as_str()
            ));
        }
        assessment
    } else {
        None
    };

    TaskRun {
        outcome,
        worktree: Some(worktree),
        changes,
        summary,
        transcript: stable.history,
        assessment,
        cost_usd,
        steps,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::script::ScriptedClient;
    use crate::tools::{RUN, Verdict};
    use forge_gateway::GatewayConfig;
    use forge_proto::types::{Agent, Machine, Repo, Session, SessionStatus};
    use forge_sqlite::SqliteStore;
    use std::sync::Mutex;

    struct Yes {
        notes: Mutex<Vec<String>>,
    }

    impl Yes {
        fn new() -> Self {
            Self {
                notes: Mutex::new(Vec::new()),
            }
        }
    }

    impl Supervisor for Yes {
        async fn request(&self, _tool: &str, _payload: &str) -> Verdict {
            Verdict::Approved
        }
        fn note(&self, text: &str) {
            self.notes.lock().unwrap().push(text.to_owned());
        }
    }

    struct No;
    impl Supervisor for No {
        async fn request(&self, _tool: &str, _payload: &str) -> Verdict {
            Verdict::Denied("not from a train".into())
        }
        fn note(&self, _text: &str) {}
    }

    const NOW: i64 = 1_800_000_000_000;

    fn store(budget: Option<f64>) -> SqliteStore {
        store_with(budget, 0.0)
    }

    fn store_with(budget: Option<f64>, spent: f64) -> SqliteStore {
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
                id: "s".into(),
                repo_id: "r".into(),
                agent: Agent::ClaudeCode,
                tmux_target: None,
                status: SessionStatus::Running,
                plan_id: None,
                budget_usd: budget,
                spent_usd: spent,
                started_at: NOW,
                ended_at: None,
                agent_session_id: None,
            })
            .unwrap();
        store
    }

    /// A real repository with one commit.
    ///
    /// A task cuts a branch before it does anything, so there is no such thing
    /// as running one outside git any more. These fixtures are therefore real
    /// repositories rather than bare directories — which also means what they
    /// assert is what actually happens on somebody's machine.
    struct TempRepo(PathBuf);

    impl TempRepo {
        fn new(name: &str) -> Self {
            let dir = std::env::temp_dir().join(format!("forge-task-{name}"));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            let repo = Self(dir);
            repo.git(&["init", "-q", "-b", "main"]);
            repo
        }

        fn git(&self, args: &[&str]) {
            let status = std::process::Command::new("git")
                .arg("-C")
                .arg(&self.0)
                .args(args)
                .status()
                .expect("git should be installed");
            assert!(status.success(), "git {args:?} failed");
        }

        /// Commit whatever has been written, so there is a base to branch from.
        fn commit(&self) -> &Self {
            self.git(&["add", "-A"]);
            self.git(&[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "commit",
                "-q",
                "-m",
                "base",
            ]);
            self
        }

        fn write(&self, relative: &str, content: &str) {
            let path = self.0.join(relative);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, content).unwrap();
        }
        fn read(&self, relative: &str) -> String {
            std::fs::read_to_string(self.0.join(relative)).unwrap()
        }
    }

    impl Drop for TempRepo {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[tokio::test]
    async fn an_edit_becomes_a_proposed_diff_and_the_tree_is_untouched() {
        let repo = TempRepo::new("propose");
        repo.write("src/main.rs", "fn main() {\n    println!(\"old\");\n}\n");
        repo.commit();

        let client = ScriptedClient::new(vec![
            ScriptedClient::calls(vec![(
                "edit_file",
                serde_json::json!({
                    "path": "src/main.rs",
                    "old_string": "\"old\"",
                    "new_string": "\"new\"",
                }),
            )]),
            ScriptedClient::text("Changed the greeting."),
        ]);

        let store = store(None);
        let gateway = Gateway::new(&store, client, GatewayConfig::default());
        let run = run(
            &gateway,
            &Yes::new(),
            &TaskSpec::new("s", &repo.0, "Change the greeting"),
        )
        .await;

        assert_eq!(run.outcome, Outcome::Proposed);
        assert_eq!(run.summary, "Changed the greeting.");
        assert_eq!(run.changes.files.len(), 1);
        assert_eq!(run.changes.summary(), "1 file, +1 −1");
        assert_eq!(
            repo.read("src/main.rs"),
            "fn main() {\n    println!(\"old\");\n}\n",
            "the working tree was written to before anybody approved anything"
        );
        assert_eq!(run.steps, 2);
    }

    #[tokio::test]
    async fn applying_the_run_writes_exactly_what_was_reviewed() {
        let repo = TempRepo::new("apply");
        repo.write("a.txt", "before\n");
        repo.commit();

        let client = ScriptedClient::new(vec![
            ScriptedClient::calls(vec![(
                "write_file",
                serde_json::json!({"path": "a.txt", "content": "after\n"}),
            )]),
            ScriptedClient::text("done"),
        ]);
        let store = store(None);
        let gateway = Gateway::new(&store, client, GatewayConfig::default());
        let run = run(&gateway, &Yes::new(), &TaskSpec::new("s", &repo.0, "x")).await;

        let reviewed = run.changes.render();

        // Nothing has reached the branch the human is on yet.
        assert_eq!(repo.read("a.txt"), "before\n");

        // Approving is a merge, and the merge is what moves their tree.
        let worktree = run.worktree.unwrap();
        worktree.commit("agent task").unwrap();
        assert!(matches!(
            worktree.merge_into_base().unwrap(),
            crate::git::Merge::FastForwarded { .. }
        ));
        assert_eq!(repo.read("a.txt"), "after\n");
        assert!(reviewed.contains("+after"));
        worktree.release().unwrap();
    }

    #[tokio::test]
    async fn the_agent_can_run_its_own_tests_against_its_own_edits() {
        // The reason the staging overlay was replaced, asserted directly.
        //
        // Under staging, `run` executed against the repository's working tree,
        // which by construction did not contain the agent's edits — so the
        // agent wrote a file in step one and `cat` in step two printed the old
        // contents. An agent could not check its own work, which is most of
        // what makes a coding agent worth supervising.
        let repo = TempRepo::new("selftest");
        repo.write("a.txt", "before\n");
        repo.commit();

        let client = ScriptedClient::new(vec![
            ScriptedClient::calls(vec![(
                crate::tools::WRITE_FILE,
                serde_json::json!({"path": "a.txt", "content": "after\n"}),
            )]),
            // Upper-cased deliberately: "after" also appears in the write
            // call's own arguments, which are rendered into the transcript, so
            // asserting on it would pass even if the command saw nothing.
            // "AFTER" can only come from the command having read the file.
            ScriptedClient::calls(vec![(
                RUN,
                serde_json::json!({"command": "tr a-z A-Z < a.txt"}),
            )]),
            ScriptedClient::text("confirmed"),
        ]);
        let store = store(None);
        let gateway = Gateway::new(&store, client, GatewayConfig::default());
        let run = run(&gateway, &Yes::new(), &TaskSpec::new("s", &repo.0, "x")).await;

        let transcript = run
            .transcript
            .iter()
            .map(|turn| turn.text.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(
            transcript.contains("AFTER"),
            "the command must see the agent's own edit; transcript was:\n{transcript}"
        );

        // And the repository the human is sitting in still has not moved.
        assert_eq!(repo.read("a.txt"), "before\n");

        if let Some(worktree) = run.worktree {
            worktree.discard().unwrap();
        }
    }

    #[tokio::test]
    async fn a_task_that_changes_nothing_does_not_ask_for_a_review() {
        let repo = TempRepo::new("nochanges");
        repo.write("a.txt", "unchanged\n");
        repo.commit();

        let client = ScriptedClient::new(vec![
            ScriptedClient::calls(vec![("read_file", serde_json::json!({"path": "a.txt"}))]),
            ScriptedClient::text("Nothing needed changing."),
        ]);
        let store = store(None);
        let gateway = Gateway::new(&store, client, GatewayConfig::default());
        let run = run(&gateway, &Yes::new(), &TaskSpec::new("s", &repo.0, "look")).await;

        assert_eq!(run.outcome, Outcome::NoChanges);
        assert!(!run.outcome.needs_review());
        assert!(run.changes.is_empty());
    }

    #[tokio::test]
    async fn a_tool_error_is_reported_back_and_the_agent_carries_on() {
        let repo = TempRepo::new("toolerror");
        repo.write("real.txt", "content\n");
        repo.commit();

        let client = ScriptedClient::new(vec![
            ScriptedClient::calls(vec![(
                "read_file",
                serde_json::json!({"path": "imaginary.txt"}),
            )]),
            ScriptedClient::calls(vec![(
                "edit_file",
                serde_json::json!({
                    "path": "real.txt", "old_string": "content", "new_string": "fixed"
                }),
            )]),
            ScriptedClient::text("Recovered."),
        ]);
        let store = store(None);
        let gateway = Gateway::new(&store, client, GatewayConfig::default());
        let run = run(&gateway, &Yes::new(), &TaskSpec::new("s", &repo.0, "x")).await;

        assert_eq!(run.outcome, Outcome::Proposed);
        assert!(
            run.transcript
                .iter()
                .any(|turn| turn.text.contains("does not exist")),
            "the error never reached the model"
        );
    }

    #[tokio::test]
    async fn a_denied_command_does_not_run_and_the_agent_is_told_why() {
        let repo = TempRepo::new("denied");
        repo.write("a.txt", "x\n");
        repo.commit();

        let client = ScriptedClient::new(vec![
            ScriptedClient::calls(vec![(
                RUN,
                serde_json::json!({"command": "touch should-not-exist"}),
            )]),
            ScriptedClient::text("Understood, I will not run that."),
        ]);
        let store = store(None);
        let gateway = Gateway::new(&store, client, GatewayConfig::default());
        let run = run(&gateway, &No, &TaskSpec::new("s", &repo.0, "x")).await;

        assert!(!repo.0.join("should-not-exist").exists());
        assert!(
            run.transcript
                .iter()
                .any(|turn| turn.text.contains("not from a train"))
        );
    }

    #[tokio::test]
    async fn the_step_limit_still_hands_back_what_was_staged() {
        let repo = TempRepo::new("steplimit");
        repo.write("a.txt", "0\n");
        repo.commit();

        // A model that reads forever and never stops.
        let client = ScriptedClient::looping(ScriptedClient::calls(vec![(
            "read_file",
            serde_json::json!({"path": "a.txt"}),
        )]));
        let store = store(None);
        let gateway = Gateway::new(&store, client, GatewayConfig::default());

        let mut spec = TaskSpec::new("s", &repo.0, "loop forever");
        spec.max_steps = 3;
        let run = run(&gateway, &Yes::new(), &spec).await;

        assert_eq!(run.outcome, Outcome::StepLimit);
        assert!(run.outcome.needs_review());
        assert_eq!(run.steps, 3);
        assert!(run.summary.contains("without finishing"));
    }

    #[tokio::test]
    async fn an_exhausted_budget_stops_the_loop_and_says_which_cap() {
        let repo = TempRepo::new("budget");
        repo.write("a.txt", "x\n");
        repo.commit();

        let client = ScriptedClient::looping(ScriptedClient::calls(vec![(
            "read_file",
            serde_json::json!({"path": "a.txt"}),
        )]));
        // Already over its cap when the task starts. A cap of *zero* would not
        // do: `Budget::pct` reads a zero cap as "uncapped", so a test written
        // that way passes for the wrong reason.
        let store = store_with(Some(0.50), 0.75);
        let gateway = Gateway::new(&store, client, GatewayConfig::default());
        let run = run(&gateway, &Yes::new(), &TaskSpec::new("s", &repo.0, "x")).await;

        match &run.outcome {
            Outcome::BudgetExhausted(message) => assert!(message.contains("session")),
            other => panic!("expected a budget stop, got {other:?}"),
        }
        assert_eq!(run.cost_usd, 0.0);
    }

    #[tokio::test]
    async fn history_only_ever_grows_by_appending() {
        // The prompt cache is a prefix match: if turn N's history is not a
        // prefix of turn N+1's, every breakpoint ahead of the change is lost.
        let repo = TempRepo::new("append");
        repo.write("a.txt", "x\n");
        repo.commit();

        let client = ScriptedClient::new(vec![
            ScriptedClient::calls(vec![("read_file", serde_json::json!({"path": "a.txt"}))]),
            ScriptedClient::calls(vec![("list_files", serde_json::json!({}))]),
            ScriptedClient::text("done"),
        ]);
        let store = store(None);
        let gateway = Gateway::new(&store, client.clone(), GatewayConfig::default());
        run(&gateway, &Yes::new(), &TaskSpec::new("s", &repo.0, "x")).await;

        let prefixes: Vec<String> = client
            .requests()
            .iter()
            .map(|request| request.plan.stable_prefix())
            .collect();
        for pair in prefixes.windows(2) {
            assert!(
                pair[1].starts_with(&pair[0]),
                "the stable prefix was rewritten between steps, not appended to"
            );
        }
    }

    #[tokio::test]
    async fn retrieval_and_the_pre_gate_run_on_the_first_step_only() {
        let repo = TempRepo::new("firststep");
        repo.write("a.txt", "x\n");
        repo.commit();

        let client = ScriptedClient::new(vec![
            ScriptedClient::calls(vec![("read_file", serde_json::json!({"path": "a.txt"}))]),
            ScriptedClient::calls(vec![("list_files", serde_json::json!({}))]),
            ScriptedClient::text("done"),
        ]);
        let store = store(None);
        let gateway = Gateway::new(&store, client.clone(), GatewayConfig::default());
        run(&gateway, &Yes::new(), &TaskSpec::new("s", &repo.0, "x")).await;

        assert_eq!(client.requests().len(), 3);
    }

    #[tokio::test]
    async fn repo_conventions_reach_the_stable_half_of_the_prompt() {
        let repo = TempRepo::new("conventions");
        repo.write("CLAUDE.md", "Never touch generated files.");
        repo.write("a.txt", "x\n");
        repo.commit();

        let client = ScriptedClient::new(vec![ScriptedClient::text("nothing to do")]);
        let store = store(None);
        let gateway = Gateway::new(&store, client.clone(), GatewayConfig::default());
        run(&gateway, &Yes::new(), &TaskSpec::new("s", &repo.0, "x")).await;

        assert!(
            client.requests()[0]
                .plan
                .stable_prefix()
                .contains("Never touch generated files.")
        );
    }

    #[tokio::test]
    async fn a_repo_that_does_not_exist_fails_rather_than_panicking() {
        let store = store(None);
        let gateway = Gateway::new(
            &store,
            ScriptedClient::new(vec![ScriptedClient::text("hi")]),
            GatewayConfig::default(),
        );

        let run = run(
            &gateway,
            &Yes::new(),
            &TaskSpec::new("s", "/nowhere/at/all", "x"),
        )
        .await;

        assert!(matches!(run.outcome, Outcome::Failed(_)));
        assert!(run.changes.is_empty());
        assert_eq!(run.cost_usd, 0.0);
        // No branch, because there was nowhere to cut one from. Nothing to
        // merge and nothing to discard, which is what `None` says.
        assert!(run.worktree.is_none());
    }

    #[test]
    fn the_system_prompt_carries_nothing_that_changes_between_calls() {
        // A date, a session id or a repo name here would move the first cache
        // breakpoint on every turn of every task.
        for volatile in ["2026", "session", "http", "/Users", "/home"] {
            assert!(
                !SYSTEM_PROMPT.contains(volatile),
                "{volatile:?} in the frozen system prompt"
            );
        }
    }

    #[test]
    fn an_assistant_turn_renders_its_prose_and_its_calls() {
        let rendered = render_assistant(
            "Looking at the retry path.",
            &[ToolCall {
                id: "toolu_1".into(),
                name: "read_file".into(),
                input: serde_json::json!({"path": "a.rs"}),
            }],
        );
        assert!(rendered.starts_with("Looking at the retry path."));
        assert!(rendered.contains("[tool_use:toolu_1] read_file"));
    }
}
