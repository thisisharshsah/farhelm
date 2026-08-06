//! Draft-then-verify (C10) — the cheap model writes, the expensive one reads.
//!
//! The loop drafts on the large tier. That is where the tokens are: a dozen
//! turns, each carrying a repo map, a history and a growing pile of tool
//! results. Running that on a frontier model is how a task gets expensive, and
//! most of what it spends those tokens on is *looking things up*, which is not
//! the part that needs the best model in the world.
//!
//! What does need it is the judgement at the end. So exactly one frontier call
//! happens per task, and it sees **only the diff** — no repo map, no history, no
//! tool results. A patch is a few kilobytes; a twelve-turn session is not.
//!
//! ```text
//!   drafting   N turns × large tier × full context
//!   verifying  1 turn  × frontier   × the patch alone
//! ```
//!
//! `tests/draft_then_verify.rs` measures that against the alternative — running
//! the same task on the frontier model throughout — rather than asserting it.
//!
//! ## An unreadable answer is never a pass
//!
//! The verdict is parsed out of a leading `VERDICT:` line. When that line is
//! missing, malformed, or the call fails outright, the result is
//! [`Grade::Concerns`] and never [`Grade::Pass`]. A verification that silently
//! degraded to "looks fine" would be worse than no verification: it would put a
//! reassuring line on a review card that nothing stood behind.

use forge_app::store::prelude::*;
use forge_gateway::prompt::StableContext;
use forge_gateway::{CompleteRequest, Gateway, ModelClient};
use forge_proto::types::TaskType;
use serde::{Deserialize, Serialize};

use crate::diff::ChangeSet;

/// Frozen, like the agent's own system prompt — this call caches too.
const VERIFY_SYSTEM: &str = "\
You review proposed code changes. You are given the task that was asked for and \
a unified diff, and nothing else: no repository, no conversation, no ability to \
run anything. Judge only what is visible in the patch.

Reply with a single line:

VERDICT: pass | concerns | fail

then at most three short sentences saying why. Use `pass` when the change does \
what was asked and you can see nothing wrong with it. Use `concerns` when it \
probably works but something needs a human's attention. Use `fail` when it does \
not do what was asked, or is wrong.

Do not restate the diff. Do not suggest unrelated improvements. If the patch is \
too small a window to judge from, say `concerns` and say that.";

/// Cap on the patch handed to the verifier.
///
/// The point of this stage is that it reads something small. A 200 KB change
/// set costs frontier rates to read and would not be reviewable by a human on a
/// phone either, so both problems are answered the same way.
pub const MAX_PATCH_BYTES: usize = 32 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Grade {
    Pass,
    Concerns,
    Fail,
}

impl Grade {
    pub const fn as_str(self) -> &'static str {
        match self {
            Grade::Pass => "pass",
            Grade::Concerns => "concerns",
            Grade::Fail => "fail",
        }
    }

    /// Whether this grade should make a reviewer slow down.
    pub const fn warrants_attention(self) -> bool {
        !matches!(self, Grade::Pass)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Assessment {
    pub grade: Grade,
    /// The model's reasoning, trimmed. Shown under the verdict on the card.
    pub notes: String,
    pub cost_usd: f64,
    /// The model that actually judged it, for the ledger's benefit and the
    /// reviewer's — "Opus 5 says concerns" reads differently from "Haiku says".
    pub model: String,
}

/// Pull the verdict out of the model's reply.
///
/// Deliberately forgiving about *form* and strict about *meaning*: a missing or
/// unrecognised verdict is `Concerns`, never `Pass`.
pub fn parse(text: &str) -> (Grade, String) {
    let mut grade = None;
    let mut notes: Vec<&str> = Vec::new();

    for line in text.lines() {
        let trimmed = line.trim();
        if grade.is_none()
            && let Some(rest) = trimmed
                .strip_prefix("VERDICT:")
                .or_else(|| trimmed.strip_prefix("verdict:"))
        {
            grade = match rest.trim().to_lowercase().as_str() {
                value if value.starts_with("pass") => Some(Grade::Pass),
                value if value.starts_with("fail") => Some(Grade::Fail),
                value if value.starts_with("concern") => Some(Grade::Concerns),
                // A verdict line that says something else is exactly the case
                // that must not read as a pass.
                _ => Some(Grade::Concerns),
            };
            continue;
        }
        if !trimmed.is_empty() {
            notes.push(trimmed);
        }
    }

    (
        grade.unwrap_or(Grade::Concerns),
        notes.join(" ").trim().to_owned(),
    )
}

/// The instruction: the ask, then the patch. Nothing else.
fn instruction(prompt: &str, changes: &ChangeSet) -> String {
    let mut patch = changes.render();
    if patch.len() > MAX_PATCH_BYTES {
        let mut end = MAX_PATCH_BYTES;
        while end > 0 && !patch.is_char_boundary(end) {
            end -= 1;
        }
        patch.truncate(end);
        patch.push_str("\n[patch truncated — judge what is visible]\n");
    }

    format!(
        "The task was:\n\n{prompt}\n\nThe proposed change ({}):\n\n{patch}",
        changes.summary()
    )
}

/// Have the frontier model read the diff.
///
/// `None` when there is nothing to judge. Never `Err`: a verification that
/// failed is reported as [`Grade::Concerns`] with the reason, because a task
/// whose *change set is fine* should not be marked failed because a second
/// opinion could not be obtained.
pub async fn assess<S: Store, C: ModelClient>(
    gateway: &Gateway<S, C>,
    session_id: &str,
    prompt: &str,
    changes: &ChangeSet,
) -> Option<Assessment> {
    if changes.is_empty() {
        return None;
    }

    let stable = StableContext {
        system: VERIFY_SYSTEM.to_owned(),
        ..StableContext::default()
    };

    // `HardDebug` is what routes this to the frontier slot. It is also honest
    // about what the call is: the hardest judgement in the task, made once.
    let mut request = CompleteRequest::new(
        session_id,
        TaskType::HardDebug,
        instruction(prompt, changes),
    );
    request.stable = stable;
    // No `repo_path`: no retrieval, no pre-gate. The patch is the whole input,
    // and that is the entire cost argument for this stage.

    match gateway.complete(request).await {
        Ok(response) => {
            if let Some(refusal) = &response.refusal {
                return Some(Assessment {
                    grade: Grade::Concerns,
                    notes: refusal
                        .explanation
                        .clone()
                        .unwrap_or_else(|| "the reviewer declined to judge this change".into()),
                    cost_usd: response.cost_usd,
                    model: response.model,
                });
            }
            let (grade, notes) = parse(&response.text);
            Some(Assessment {
                grade,
                notes,
                cost_usd: response.cost_usd,
                model: response.model,
            })
        }
        // Budget stops and transport failures land here. The change set is
        // still perfectly reviewable by the human it was always going to.
        Err(err) => Some(Assessment {
            grade: Grade::Concerns,
            notes: format!("the change could not be reviewed automatically: {err}"),
            cost_usd: 0.0,
            model: String::new(),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diff::file_diff;

    fn changes() -> ChangeSet {
        ChangeSet {
            files: vec![file_diff("a.rs", Some("old\n"), Some("new\n")).unwrap()],
        }
    }

    #[test]
    fn a_clean_verdict_parses() {
        let (grade, notes) = parse("VERDICT: pass\nThe cap is applied where it was asked for.");
        assert_eq!(grade, Grade::Pass);
        assert_eq!(notes, "The cap is applied where it was asked for.");
    }

    #[test]
    fn every_grade_is_recognised_in_either_case() {
        assert_eq!(parse("VERDICT: fail").0, Grade::Fail);
        assert_eq!(parse("verdict: Fail").0, Grade::Fail);
        assert_eq!(parse("VERDICT: concerns").0, Grade::Concerns);
        assert_eq!(parse("VERDICT: concern").0, Grade::Concerns);
        assert_eq!(parse("VERDICT: PASS — looks right").0, Grade::Pass);
    }

    #[test]
    fn a_missing_verdict_is_concerns_and_never_a_pass() {
        // The failure this prevents: a malformed reply putting "reviewed, fine"
        // on a card with nothing behind it.
        let (grade, notes) = parse("I think this looks completely fine to me.");
        assert_eq!(grade, Grade::Concerns);
        assert!(notes.contains("completely fine"));
    }

    #[test]
    fn an_unrecognised_verdict_is_concerns_too() {
        assert_eq!(parse("VERDICT: probably ok").0, Grade::Concerns);
        assert_eq!(parse("VERDICT:").0, Grade::Concerns);
    }

    #[test]
    fn an_empty_reply_is_concerns() {
        assert_eq!(parse("").0, Grade::Concerns);
        assert_eq!(parse("   \n  \n").0, Grade::Concerns);
    }

    #[test]
    fn only_the_first_verdict_line_counts() {
        // A model that restates the format in its prose must not flip the grade.
        let (grade, _) = parse("VERDICT: fail\nUse VERDICT: pass when it is fine.");
        assert_eq!(grade, Grade::Fail);
    }

    #[test]
    fn only_a_pass_stays_quiet() {
        assert!(!Grade::Pass.warrants_attention());
        assert!(Grade::Concerns.warrants_attention());
        assert!(Grade::Fail.warrants_attention());
    }

    #[test]
    fn the_instruction_carries_the_ask_and_the_patch_and_nothing_else() {
        let text = instruction("Bound the retry backoff", &changes());
        assert!(text.contains("Bound the retry backoff"));
        assert!(text.contains("+new"));
        assert!(text.contains("1 file, +1 −1"));
    }

    #[test]
    fn an_oversized_patch_is_truncated_rather_than_billed_at_frontier_rates() {
        let huge: String = (0..50_000).map(|i| format!("line {i}\n")).collect();
        let set = ChangeSet {
            files: vec![file_diff("big.txt", Some(""), Some(&huge)).unwrap()],
        };

        let text = instruction("x", &set);
        assert!(text.contains("[patch truncated"));
        assert!(text.len() < MAX_PATCH_BYTES * 2);
    }

    #[test]
    fn the_verify_prompt_is_frozen() {
        // It sits ahead of a cache breakpoint on every task in the system.
        for volatile in ["2026", "session", "/Users", "/home"] {
            assert!(
                !VERIFY_SYSTEM.contains(volatile),
                "{volatile:?} in the prompt"
            );
        }
    }
}
