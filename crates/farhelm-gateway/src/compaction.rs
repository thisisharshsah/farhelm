//! C7: compacting conversation history.
//!
//! A long session re-sends its whole history every turn. Prompt caching makes
//! that cheap — a cache read is a tenth of the input rate — but "cheap" is not
//! "free", and the context window is finite. Eventually the history has to be
//! summarised.
//!
//! # What compaction costs, corrected by measurement
//!
//! The first version of this comment argued that compaction is expensive because
//! it invalidates the prompt cache, and that the policy should therefore be
//! "rare and large". **The benchmark disagreed, and it was right.**
//!
//! History sits *after* the stable breakpoints in the assembled prefix — tools
//! and system, then conventions, then the repo map, then history. So rewriting
//! the history invalidates only the **history segment**, not the whole prefix.
//! Everything ahead of it still reads from cache at 0.1×. The cache penalty is
//! real but small, and it is dwarfed by the saving on the routed call's input.
//!
//! `tests/compaction_savings.rs` measures it: over 40 turns the default policy
//! saves **42%**, and a deliberately aggressive policy — compact every turn, keep
//! one — is cheaper still, by a further **84%**, because the expensive routed
//! call ends up with almost no input to pay for.
//!
//! # So why not compact constantly?
//!
//! Not cost. **Fidelity.** Compacting every turn means each summary is a summary
//! of a transcript that already contains a summary, and detail decays
//! geometrically: after ten passes what survives from turn 3 has been through ten
//! lossy rewrites. The agent stops knowing what it already tried, and starts
//! repeating work — which costs far more than the tokens saved, in a currency
//! this ledger cannot see.
//!
//! That is the actual justification for [`CompactionPolicy::min_turns`] and a
//! large `trigger_bytes`: **keep the number of rewrites any given fact has been
//! through as low as possible.** The defaults are deliberately not the
//! cost-minimising setting, and the benchmark asserts that gap rather than hiding
//! it.
//!
//! # What is kept verbatim
//!
//! The most recent turns. Recency is where the detail matters — what the agent
//! just tried and what just failed — and a summary of "we discussed the retry
//! backoff" is useless for the next edit. Older turns compress well because what
//! survives from them is decisions, not transcript.

use crate::prompt::{Role, Turn};

/// When to compact, and how much.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CompactionPolicy {
    /// Compact once the history is at least this many bytes.
    ///
    /// Deliberately large — larger than the cost-minimising value. Every pass
    /// re-summarises text that already went through a summary, so this bounds
    /// how many lossy rewrites any given fact accumulates.
    pub trigger_bytes: usize,
    /// How many recent turns to keep verbatim.
    pub keep_recent: usize,
    /// Never compact fewer turns than this.
    ///
    /// The guard against death by a thousand compactions. Not a cost guard —
    /// measurement showed frequent compaction is *cheaper* — but a fidelity one:
    /// cutting two turns at a time means everything older has been rewritten
    /// dozens of times by the end of a session.
    pub min_turns: usize,
}

impl Default for CompactionPolicy {
    fn default() -> Self {
        Self {
            // ~16k tokens of history before it is worth touching.
            trigger_bytes: 64 * 1024,
            keep_recent: 6,
            min_turns: 8,
        }
    }
}

/// What a compaction pass would do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompactionPlan {
    /// Turns to be replaced by a summary, oldest first.
    pub compact: Vec<Turn>,
    /// Turns to keep verbatim, in order.
    pub keep: Vec<Turn>,
}

impl CompactionPlan {
    /// Bytes the compacted turns currently occupy.
    pub fn bytes_removed(&self) -> usize {
        self.compact.iter().map(|turn| turn.text.len()).sum()
    }

    /// The transcript handed to the summariser.
    ///
    /// Roles are spelled out because a summary that loses track of who proposed
    /// what is worse than no summary — the next turn would attribute the agent's
    /// rejected idea to the human.
    pub fn transcript(&self) -> String {
        self.compact
            .iter()
            .map(|turn| {
                let role = match turn.role {
                    Role::User => "User",
                    Role::Assistant => "Assistant",
                };
                format!("{role}: {}", turn.text)
            })
            .collect::<Vec<_>>()
            .join("\n\n")
    }
}

/// Decide whether to compact, and what.
///
/// `None` means leave it alone, which is the answer most of the time. The bar is
/// not "would this save money" — it usually would — but "is this history long
/// enough that summarising it loses less than carrying it costs".
pub fn plan(history: &[Turn], policy: &CompactionPolicy) -> Option<CompactionPlan> {
    let total: usize = history.iter().map(|turn| turn.text.len()).sum();
    if total < policy.trigger_bytes {
        return None;
    }

    let cut = history.len().checked_sub(policy.keep_recent)?;
    if cut < policy.min_turns {
        // Big history, but almost all of it is in the turns we would keep. There
        // is nothing worth throwing the cache away for.
        return None;
    }

    let (compact, keep) = history.split_at(cut);
    Some(CompactionPlan {
        compact: compact.to_vec(),
        keep: keep.to_vec(),
    })
}

/// The instruction given to the summariser.
///
/// Asks for decisions and state rather than narrative. What the next turn needs
/// from twenty turns ago is "we chose exponential backoff and the retry test is
/// still failing", not a retelling.
pub fn summarise_instruction(transcript: &str) -> String {
    format!(
        "Summarise this portion of a coding session so that work can continue \
         without it. Keep, in this order: decisions made and why; files and \
         functions changed; what is still failing or unresolved; anything the \
         user asked for that has not been done. Drop pleasantries, restated \
         code, and anything superseded later in the transcript. Be terse and \
         concrete — this replaces the transcript, it does not describe it.\n\n\
         {transcript}"
    )
}

/// The history to use after compaction.
///
/// The summary becomes a single user turn, because a fabricated *assistant* turn
/// would be a statement the model never made — and later turns would treat it as
/// its own prior reasoning.
pub fn apply(summary: &str, plan: CompactionPlan) -> Vec<Turn> {
    let mut history = Vec::with_capacity(plan.keep.len() + 1);
    history.push(Turn::user(format!(
        "[Earlier in this session, summarised]\n{}",
        summary.trim()
    )));
    history.extend(plan.keep);
    history
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A turn of roughly `bytes` length.
    fn turn(index: usize, bytes: usize) -> Turn {
        let text = format!("turn {index} ").repeat(bytes / 8 + 1);
        if index.is_multiple_of(2) {
            Turn::user(text)
        } else {
            Turn::assistant(text)
        }
    }

    fn history(count: usize, bytes_each: usize) -> Vec<Turn> {
        (0..count).map(|index| turn(index, bytes_each)).collect()
    }

    #[test]
    fn a_short_history_is_left_alone() {
        // The common case. Not because it would cost more — it would not — but
        // because summarising four turns loses detail for no meaningful gain.
        assert_eq!(plan(&history(4, 100), &CompactionPolicy::default()), None);
    }

    #[test]
    fn an_empty_history_is_left_alone() {
        assert_eq!(plan(&[], &CompactionPolicy::default()), None);
    }

    #[test]
    fn a_long_history_is_compacted_down_to_the_recent_turns() {
        let policy = CompactionPolicy::default();
        let plan = plan(&history(30, 4_000), &policy).expect("should compact");

        assert_eq!(plan.keep.len(), policy.keep_recent);
        assert_eq!(plan.compact.len(), 30 - policy.keep_recent);
        // The kept turns are the *latest* ones: recency is where the detail
        // matters, and a summary of "we discussed the backoff" does not help the
        // next edit.
        assert_eq!(plan.keep.first().unwrap().text, history(30, 4_000)[24].text);
    }

    #[test]
    fn a_big_history_in_few_turns_is_not_worth_compacting() {
        // Over the byte trigger, but almost all of it is in turns we would keep.
        // Nothing meaningful would be removed, and the recent turns are exactly
        // the ones worth keeping verbatim.
        let policy = CompactionPolicy::default();
        assert_eq!(plan(&history(8, 20_000), &policy), None);
    }

    #[test]
    fn cutting_a_small_tail_is_refused() {
        // The fidelity guard: small frequent cuts mean older facts get rewritten
        // dozens of times over a session, and detail decays geometrically.
        let policy = CompactionPolicy {
            keep_recent: 6,
            min_turns: 8,
            ..CompactionPolicy::default()
        };
        // 12 turns → would cut 6, which is under `min_turns`.
        assert_eq!(plan(&history(12, 8_000), &policy), None);
        // 14 turns → cuts 8, which is worth it.
        assert!(plan(&history(14, 8_000), &policy).is_some());
    }

    #[test]
    fn a_history_shorter_than_the_keep_window_is_left_alone() {
        let policy = CompactionPolicy {
            keep_recent: 10,
            ..CompactionPolicy::default()
        };
        assert_eq!(plan(&history(3, 40_000), &policy), None);
    }

    #[test]
    fn the_transcript_says_who_said_what() {
        // A summary that loses attribution is worse than none: the next turn
        // would credit the agent's rejected idea to the user.
        let plan = plan(&history(20, 4_000), &CompactionPolicy::default()).unwrap();
        let transcript = plan.transcript();
        assert!(transcript.contains("User: "));
        assert!(transcript.contains("Assistant: "));
    }

    #[test]
    fn compaction_reports_what_it_removed() {
        let plan = plan(&history(20, 4_000), &CompactionPolicy::default()).unwrap();
        let removed = plan.bytes_removed();
        assert!(removed > 0);
        assert_eq!(
            removed,
            plan.compact.iter().map(|t| t.text.len()).sum::<usize>()
        );
    }

    #[test]
    fn the_summary_replaces_the_old_turns_and_keeps_the_new() {
        let plan = plan(&history(20, 4_000), &CompactionPolicy::default()).unwrap();
        let kept = plan.keep.clone();
        let after = apply("we chose exponential backoff", plan);

        assert_eq!(after.len(), kept.len() + 1);
        assert!(after[0].text.contains("exponential backoff"));
        assert_eq!(after[1..], kept[..]);
    }

    #[test]
    fn the_summary_is_a_user_turn_not_a_fabricated_assistant_one() {
        // A synthetic assistant turn is a statement the model never made, and
        // later turns would treat it as their own prior reasoning.
        let plan = plan(&history(20, 4_000), &CompactionPolicy::default()).unwrap();
        assert_eq!(apply("x", plan)[0].role, Role::User);
    }

    #[test]
    fn the_summary_is_marked_as_one() {
        // So the model does not read it as something the user actually typed.
        let plan = plan(&history(20, 4_000), &CompactionPolicy::default()).unwrap();
        assert!(
            apply("x", plan)[0]
                .text
                .starts_with("[Earlier in this session")
        );
    }

    #[test]
    fn compaction_actually_shrinks_the_history() {
        // The whole point. If this ever failed, every compaction would be pure
        // cost: a summary call, a thrown-away cache, and a bigger prompt.
        let before = history(30, 4_000);
        let before_bytes: usize = before.iter().map(|t| t.text.len()).sum();

        let plan = plan(&before, &CompactionPolicy::default()).unwrap();
        let after = apply("a short summary of everything", plan);
        let after_bytes: usize = after.iter().map(|t| t.text.len()).sum();

        assert!(
            after_bytes < before_bytes / 2,
            "compaction should be a large cut, not a trim: {before_bytes} → {after_bytes}"
        );
    }

    #[test]
    fn the_instruction_asks_for_decisions_not_narrative() {
        let instruction = summarise_instruction("User: hello");
        assert!(instruction.contains("decisions"));
        assert!(instruction.contains("still failing"));
        // And it carries the transcript it is summarising.
        assert!(instruction.contains("User: hello"));
    }

    #[test]
    fn a_policy_that_keeps_nothing_still_keeps_the_summary() {
        // Degenerate but reachable through configuration; it must not panic or
        // produce an empty history the assembler cannot work with.
        let policy = CompactionPolicy {
            keep_recent: 0,
            min_turns: 1,
            ..CompactionPolicy::default()
        };
        let plan = plan(&history(20, 4_000), &policy).unwrap();
        assert!(plan.keep.is_empty());
        assert_eq!(apply("everything", plan).len(), 1);
    }
}
