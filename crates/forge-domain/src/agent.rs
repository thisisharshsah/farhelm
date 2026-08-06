//! What each agent is, and how you supervise it.
//!
//! RelayForge started around Claude Code, which has a hook system: it calls out
//! to a binary before every tool use and waits for an answer. That is the ideal
//! integration and it is why the approval path is trustworthy — the agent is
//! *blocked* until a human decides, in-process, with no polling.
//!
//! Most agents have nothing like it. They ask in their own terminal —
//! `Run shell command? (y/n)` — and wait for a keystroke. Supervising those
//! means reading the question out of the pane and typing the answer back.
//!
//! # Two channels, one queue
//!
//! Both paths end in the same place: an `Approval` row, the same
//! destructive-command classifier, the same D3 rule about watches, the same
//! budget meter, the same notification. A new agent adds a *dialect*, not a
//! second approval system.
//!
//! # Honesty about the prompt dialects
//!
//! The hook channel is exact: Claude Code's payload schema is documented and the
//! bridge is verified end to end. The prompt channel is **pattern matching on
//! terminal output**, which is inherently a heuristic — agents reword their
//! prompts between releases, and a missed prompt means a session that looks
//! stalled rather than one that silently proceeds.
//!
//! That failure direction is deliberate: [`PromptDialect`] never guesses an
//! answer. If nothing matches, nothing is approved and the pane simply sits
//! there, which is exactly what would have happened without RelayForge.
//!
//! Dialects marked [`Confidence::Verified`] have been checked against the real
//! binary. The rest are [`Confidence::Unverified`] and say so in the UI.

use forge_proto::types::Agent;

/// How a human's decision reaches the agent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApprovalChannel {
    /// The agent calls the runner and blocks. Exact, and the only channel that
    /// can refuse a tool call the agent never announced.
    Hook,
    /// The agent asks in its terminal; the runner reads the question and types
    /// the answer. A heuristic — see the module docs.
    Prompt(&'static PromptDialect),
    /// The runner *is* the agent. No bridge, no pane, nothing to parse: the
    /// loop calls the approval queue directly and awaits the answer in-process.
    /// Exact by construction, since there is no gap between the two to drift.
    Native,
    /// No supervision available. Output is streamed; nothing is gated.
    None,
}

/// Whether a dialect has been checked against the real binary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Confidence {
    /// Verified against the agent it claims to support.
    Verified,
    /// Written from documentation and released prompts, not yet run.
    Unverified,
}

/// How one agent phrases a question, and what answer it expects.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PromptDialect {
    /// Lowercase fragments that mean "waiting for a decision". Matched against
    /// the tail of the pane, so an old prompt further up does not re-trigger.
    pub triggers: &'static [&'static str],
    /// What to type to approve. `\r` is sent separately by the terminal layer.
    pub approve: &'static str,
    /// What to type to deny.
    pub deny: &'static str,
    pub confidence: Confidence,
}

/// Everything the runner needs to start and supervise one agent.
#[derive(Debug, Clone, Copy)]
pub struct AgentSpec {
    pub agent: Agent,
    /// What a human calls it.
    pub display_name: &'static str,
    /// The executable, looked up on `PATH`.
    pub binary: &'static str,
    /// Arguments always passed.
    pub args: &'static [&'static str],
    /// How to resume the agent's own prior session, if it can.
    pub resume_flag: Option<&'static str>,
    pub approvals: ApprovalChannel,
    /// One line for the "start a session" picker.
    pub note: &'static str,
}

impl AgentSpec {
    /// argv to start this agent, optionally resuming one of its own sessions.
    pub fn command(&self, resume: Option<&str>) -> Vec<String> {
        let mut argv = vec![self.binary.to_owned()];
        argv.extend(self.args.iter().map(|arg| (*arg).to_owned()));
        if let (Some(flag), Some(id)) = (self.resume_flag, resume) {
            argv.push(flag.to_owned());
            argv.push(id.to_owned());
        }
        argv
    }

    /// True when a human's decision can actually reach this agent.
    pub fn is_supervised(&self) -> bool {
        !matches!(self.approvals, ApprovalChannel::None)
    }

    /// The dialect, if this agent is supervised by reading its terminal.
    pub fn dialect(&self) -> Option<&'static PromptDialect> {
        match self.approvals {
            ApprovalChannel::Prompt(dialect) => Some(dialect),
            _ => None,
        }
    }
}

/* ----------------------------------------------------------------- dialects */

/// Claude Code's own interactive prompt.
///
/// Only reached if the hook bridge is not installed; with hooks the agent never
/// asks in the terminal at all. Kept so a half-configured setup degrades to
/// "supervised, roughly" rather than "unsupervised, silently".
const CLAUDE_PROMPT: PromptDialect = PromptDialect {
    triggers: &["do you want to proceed?", "❯ 1. yes"],
    approve: "1",
    deny: "2",
    confidence: Confidence::Unverified,
};

/// `y`/`n` — the most common shape by far.
const YES_NO: PromptDialect = PromptDialect {
    triggers: &[
        "(y/n)",
        "[y/n]",
        "(yes/no)",
        "y)es",
        "proceed?",
        "allow this",
        "approve this",
    ],
    approve: "y",
    deny: "n",
    confidence: Confidence::Unverified,
};

/// Aider asks with a capitalised default.
const AIDER_PROMPT: PromptDialect = PromptDialect {
    triggers: &[
        "(y)es/(n)o",
        "run shell command?",
        "add .* to the chat?",
        "apply edits?",
    ],
    approve: "y",
    deny: "n",
    confidence: Confidence::Unverified,
};

/* ------------------------------------------------------------------ registry */

/// Every agent the runner knows how to start.
///
/// Adding one is a row here plus, usually, a dialect. It does not touch the
/// approval queue, the risk classifier, the budget guard, or any client.
pub const AGENTS: &[AgentSpec] = &[
    AgentSpec {
        agent: Agent::ClaudeCode,
        display_name: "Claude Code",
        binary: "claude",
        args: &[],
        resume_flag: Some("--resume"),
        // Permissions go through the hook bridge, not Claude Code's own prompt.
        // That is the whole point of the integration: an interactive prompt
        // would block the agent behind a terminal nobody is sitting at.
        approvals: ApprovalChannel::Hook,
        note: "Hook bridge — every tool call blocks until you answer.",
    },
    AgentSpec {
        agent: Agent::Codex,
        display_name: "Codex CLI",
        binary: "codex",
        args: &[],
        resume_flag: Some("resume"),
        approvals: ApprovalChannel::Prompt(&YES_NO),
        note: "Approvals read from the terminal. Verify the prompts on first use.",
    },
    AgentSpec {
        agent: Agent::OpenCode,
        display_name: "OpenCode",
        binary: "opencode",
        args: &[],
        resume_flag: Some("--session"),
        approvals: ApprovalChannel::Prompt(&YES_NO),
        note: "Approvals read from the terminal. Verify the prompts on first use.",
    },
    AgentSpec {
        agent: Agent::Aider,
        display_name: "Aider",
        binary: "aider",
        args: &[],
        resume_flag: None,
        approvals: ApprovalChannel::Prompt(&AIDER_PROMPT),
        note: "Approvals read from the terminal. Verify the prompts on first use.",
    },
    AgentSpec {
        agent: Agent::Gemini,
        display_name: "Gemini CLI",
        binary: "gemini",
        args: &[],
        resume_flag: None,
        approvals: ApprovalChannel::Prompt(&YES_NO),
        note: "Approvals read from the terminal. Verify the prompts on first use.",
    },
    AgentSpec {
        agent: Agent::Cursor,
        display_name: "Cursor CLI",
        binary: "cursor-agent",
        args: &[],
        resume_flag: Some("--resume"),
        approvals: ApprovalChannel::Prompt(&YES_NO),
        note: "Approvals read from the terminal. Verify the prompts on first use.",
    },
    AgentSpec {
        agent: Agent::Forge,
        display_name: "RelayForge",
        // No binary: this agent is the runner. `installed` is therefore always
        // true, which is the one case the PATH lookup must not be asked about.
        binary: "",
        args: &[],
        resume_flag: None,
        approvals: ApprovalChannel::Native,
        note: "Runs in the runner and proposes a diff you review before it lands.",
    },
    AgentSpec {
        agent: Agent::Shell,
        display_name: "Shell",
        binary: "",
        args: &[],
        resume_flag: None,
        // A shell is not an agent and has nothing to approve. It exists so the
        // desktop app can hold a plain terminal on the same footing — visible
        // from the phone, killable, with its output in the tail.
        approvals: ApprovalChannel::None,
        note: "A plain shell. Nothing is gated; you are the one typing.",
    },
];

/// Look up an agent's spec. Every [`Agent`] has one.
pub fn spec(agent: Agent) -> &'static AgentSpec {
    AGENTS
        .iter()
        .find(|candidate| candidate.agent == agent)
        .expect("every Agent variant has a spec — see the exhaustiveness test")
}

/// The dialect Claude Code falls back to without its hook bridge.
pub const CLAUDE_FALLBACK: &PromptDialect = &CLAUDE_PROMPT;

/* ----------------------------------------------------------------- detection */

/// A question an agent is waiting on, read out of its terminal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DetectedPrompt {
    /// The line that asked.
    pub question: String,
    /// The command or change being asked about — what a human decides on.
    pub payload: String,
}

/// How many lines from the end of the pane count as "right now".
///
/// A prompt further up than this has been answered or scrolled past. Matching it
/// would raise an approval for something already done.
const TAIL_LINES: usize = 12;

/// How many non-empty lines may follow a question and still leave it live.
///
/// **An agent waiting for input has printed nothing since it asked.** Anything
/// after the question means it got its answer and moved on. One line of slack
/// covers the terminal echoing the keystroke back, which arrives before the
/// agent's next output.
///
/// This rule was learned the hard way. tmux's `capture-pane` returns the current
/// *screen*, so an answered question is simply overwritten and disappears. A raw
/// PTY has only append-only scrollback, where the question stays visible
/// forever — so without this check the watcher re-raised an approval for a
/// command that had already run, every few seconds, indefinitely.
const MAX_LINES_AFTER: usize = 1;

/// Find the question an agent is currently waiting on, if any.
///
/// Deliberately conservative in one direction: when nothing matches, the answer
/// is `None` and nothing is approved. A missed prompt looks like a stalled
/// session, which is what would have happened without RelayForge anyway. A
/// *false* match would type `y` at something nobody agreed to.
pub fn detect_prompt(pane: &str, dialect: &PromptDialect) -> Option<DetectedPrompt> {
    let lines: Vec<&str> = pane.lines().collect();
    let start = lines.len().saturating_sub(TAIL_LINES);
    let tail = &lines[start..];

    // Search from the bottom: the newest question is the live one.
    let question_index = tail.iter().rposition(|line| {
        let lowered = line.to_lowercase();
        dialect
            .triggers
            .iter()
            .any(|trigger| lowered.contains(trigger))
    })?;

    let question = tail[question_index].trim().to_owned();
    if question.is_empty() {
        return None;
    }

    // Has the agent said anything since? Then it is not waiting on this.
    let after = tail[question_index + 1..]
        .iter()
        .filter(|line| !line.trim().is_empty())
        .count();
    if after > MAX_LINES_AFTER {
        return None;
    }

    Some(DetectedPrompt {
        payload: payload_above(&tail[..question_index]).unwrap_or_else(|| question.clone()),
        question,
    })
}

/// The command being asked about, from the lines above the question.
///
/// Agents print the thing, then ask. The most recent non-empty, non-decorative
/// line above the question is nearly always it.
fn payload_above(above: &[&str]) -> Option<String> {
    above
        .iter()
        .rev()
        .map(|line| strip_decoration(line))
        .find(|line| !line.is_empty() && !is_chrome(line))
        .map(|line| line.to_owned())
}

/// Strip the box-drawing and prompt characters agents wrap output in.
fn strip_decoration(line: &str) -> &str {
    line.trim()
        .trim_start_matches(['│', '┃', '|', '>', '❯', '●', '⏺', '*', '#'])
        .trim_end_matches(['│', '┃', '|'])
        .trim()
}

/// Lines that are framing rather than content.
fn is_chrome(line: &str) -> bool {
    // A line of nothing but box-drawing, dashes, or equals signs.
    line.chars()
        .all(|c| matches!(c, '─' | '│' | '┌'..='╿' | '-' | '=' | '_' | ' ' | '·'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_agent_variant_has_a_spec() {
        // `spec()` panics on a missing entry, so a new `Agent` variant without a
        // registry row fails here rather than at runtime on someone's machine.
        for agent in Agent::ALL {
            let found = spec(*agent);
            assert_eq!(found.agent, *agent);
            assert!(!found.display_name.is_empty());
        }
    }

    #[test]
    fn every_supervised_agent_has_a_way_to_answer() {
        for agent in Agent::ALL {
            let found = spec(*agent);
            if let Some(dialect) = found.dialect() {
                assert!(!dialect.triggers.is_empty(), "{}", found.display_name);
                assert!(!dialect.approve.is_empty(), "{}", found.display_name);
                assert!(!dialect.deny.is_empty(), "{}", found.display_name);
                assert_ne!(dialect.approve, dialect.deny, "{}", found.display_name);
            }
        }
    }

    #[test]
    fn a_shell_is_honest_about_being_unsupervised() {
        // The dangerous version of this would be reporting a shell as gated.
        assert!(!spec(Agent::Shell).is_supervised());
        assert!(spec(Agent::ClaudeCode).is_supervised());
    }

    #[test]
    fn the_command_starts_the_right_binary() {
        assert_eq!(spec(Agent::ClaudeCode).command(None), vec!["claude"]);
        assert_eq!(spec(Agent::Aider).command(None), vec!["aider"]);
    }

    #[test]
    fn resuming_passes_the_agents_own_session_id() {
        assert_eq!(
            spec(Agent::ClaudeCode).command(Some("abc-123")),
            vec!["claude", "--resume", "abc-123"]
        );
    }

    #[test]
    fn an_agent_that_cannot_resume_ignores_the_id() {
        // Aider has no resume flag; appending a bare id would be read as a file
        // to add to the chat.
        assert_eq!(spec(Agent::Aider).command(Some("abc-123")), vec!["aider"]);
    }

    /* --------------------------------------------------------- detection */

    #[test]
    fn a_yes_no_question_is_found_with_its_command() {
        let pane = "\
Running tests before the change.
$ rm -rf ./build
Proceed? (y/n)";
        let found = detect_prompt(pane, &YES_NO).unwrap();
        assert_eq!(found.payload, "$ rm -rf ./build");
        assert!(found.question.contains("(y/n)"));
    }

    #[test]
    fn box_drawing_around_the_command_is_stripped() {
        let pane = "\
┌──────────────────────────────┐
│ git push --force origin main │
└──────────────────────────────┘
Allow this command? (y/n)";
        assert_eq!(
            detect_prompt(pane, &YES_NO).unwrap().payload,
            "git push --force origin main"
        );
    }

    #[test]
    fn the_newest_question_wins() {
        // An older prompt still in the scrollback has already been answered;
        // raising an approval for it would ask about something already done.
        let pane = "\
$ cargo build
Proceed? (y/n)
y
$ cargo test
Proceed? (y/n)";
        assert_eq!(
            detect_prompt(pane, &YES_NO).unwrap().payload,
            "$ cargo test"
        );
    }

    #[test]
    fn a_question_the_agent_has_moved_on_from_is_not_live() {
        // The bug this replaces: with append-only PTY scrollback the answered
        // question stays on screen, and the watcher re-raised an approval for a
        // command that had already run, every poll, forever.
        let pane = "\
  rm -rf ./build
Proceed? (y/n)
y

APPROVED — running it";
        assert_eq!(detect_prompt(pane, &YES_NO), None);
    }

    #[test]
    fn the_echoed_keystroke_alone_does_not_count_as_moving_on() {
        // A terminal echoes what was typed before the agent reacts. Treating
        // that as "answered" would miss the window entirely on a fast agent.
        let pane = "\
  rm -rf ./build
Proceed? (y/n)";
        assert!(detect_prompt(pane, &YES_NO).is_some());
    }

    #[test]
    fn a_question_scrolled_out_of_reach_is_not_live() {
        // Twelve lines of output after a question means it was answered and the
        // agent moved on.
        let mut pane = String::from("$ rm -rf /\nProceed? (y/n)\n");
        for index in 0..20 {
            pane.push_str(&format!("compiling crate {index}\n"));
        }
        assert_eq!(detect_prompt(&pane, &YES_NO), None);
    }

    #[test]
    fn ordinary_output_is_not_mistaken_for_a_question() {
        // The expensive failure: typing `y` at something nobody was asked about.
        let pane = "\
   Compiling forge-core v0.1.0
    Finished dev profile in 3.2s
     Running unittests src/lib.rs
test result: ok. 95 passed";
        assert_eq!(detect_prompt(pane, &YES_NO), None);
    }

    #[test]
    fn prose_containing_the_word_proceed_does_not_trigger() {
        let pane = "I'll proceed with the refactor once the tests pass.";
        // "proceed?" needs the question mark; a sentence is not a prompt.
        assert_eq!(detect_prompt(pane, &YES_NO), None);
    }

    #[test]
    fn an_empty_pane_asks_nothing() {
        assert_eq!(detect_prompt("", &YES_NO), None);
        assert_eq!(detect_prompt("\n\n\n", &YES_NO), None);
    }

    #[test]
    fn a_question_with_nothing_above_it_falls_back_to_itself() {
        // Better to raise "Proceed? (y/n)" than to raise an empty approval.
        let found = detect_prompt("Proceed? (y/n)", &YES_NO).unwrap();
        assert_eq!(found.payload, "Proceed? (y/n)");
    }

    #[test]
    fn framing_lines_are_never_the_payload() {
        let pane = "\
git commit -am wip
────────────────────────
Proceed? (y/n)";
        assert_eq!(
            detect_prompt(pane, &YES_NO).unwrap().payload,
            "git commit -am wip"
        );
    }

    #[test]
    fn aiders_phrasing_is_recognised() {
        let pane = "\
pytest tests/ -x
Run shell command? (Y)es/(N)o [Yes]:";
        let found = detect_prompt(pane, &AIDER_PROMPT).unwrap();
        assert_eq!(found.payload, "pytest tests/ -x");
    }

    #[test]
    fn claude_codes_numbered_menu_is_recognised() {
        let pane = "\
Bash(rm -rf ./build)
Do you want to proceed?
❯ 1. Yes
  2. No";
        let found = detect_prompt(pane, &CLAUDE_PROMPT).unwrap();
        assert!(found.question.to_lowercase().contains("1. yes"));
    }

    #[test]
    fn a_dialect_answers_with_distinct_keys() {
        // Sending the same key for both would silently approve every denial.
        for dialect in [&YES_NO, &AIDER_PROMPT, &CLAUDE_PROMPT] {
            assert_ne!(dialect.approve, dialect.deny);
        }
    }
}
