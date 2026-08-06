//! Pipeline stage 3 — the exact response cache (C8).
//!
//! Distinct from *prompt* caching, which makes a call cheaper. This makes a call
//! not happen: the same question, asked again, costs nothing.
//!
//! The key is a hash of the model plus the whole assembled prompt, so any change
//! to the repo map, the history, or the instruction produces a different key.
//! That is what makes it safe to cache retrieval and summarisation — if the
//! inputs moved, the key moved.

use forge_proto::types::TaskType;
use sha2::{Digest, Sha256};

use crate::prompt::PromptPlan;

/// A day. Long enough that a repeated lint question inside one session is free,
/// short enough that a stale answer cannot outlive the branch it was about.
pub const DEFAULT_TTL_MS: i64 = 24 * 60 * 60 * 1_000;

/// Whether a task's answer may be replayed from cache.
///
/// The line is *does the response act on the world*. Analysis and selection are
/// pure functions of the prompt, and the prompt captures the repo state that
/// produced them. An edit, refactor, or plan is a proposed mutation: replaying
/// one against a repo that has moved on is how you get a patch applied twice,
/// so those always go to the model even when the bytes match.
pub const fn is_cacheable(task: TaskType) -> bool {
    match task {
        TaskType::Triage
        | TaskType::SelectFiles
        | TaskType::Summarize
        | TaskType::CommitMsg
        | TaskType::Title => true,
        TaskType::Edit | TaskType::Refactor | TaskType::Plan | TaskType::HardDebug => false,
    }
}

/// Hash the material that determines a response.
///
/// `cache_control` markers are deliberately excluded — they change how the
/// provider bills the call, never what it answers, so two prompts that differ
/// only in breakpoint placement should share a cached response.
pub fn key(model: &str, plan: &PromptPlan) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"forge-response-cache-v1\0");
    hasher.update(model.as_bytes());
    hasher.update(b"\0");
    hasher.update(plan.stable_prefix().as_bytes());
    hasher.update(b"\0");
    hasher.update(plan.dynamic_tail().as_bytes());

    let digest = hasher.finalize();
    let mut hex = String::with_capacity(digest.len() * 2);
    for byte in digest {
        use std::fmt::Write as _;
        let _ = write!(hex, "{byte:02x}");
    }
    hex
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prompt::{StableContext, Turn, assemble};
    use forge_domain::price::price_of;

    fn plan(system: &str, tail: &str) -> PromptPlan {
        let stable = StableContext {
            system: system.to_owned(),
            history: vec![Turn::user("earlier")],
            ..StableContext::default()
        };
        assemble(&stable, tail, &price_of("claude-opus-5").unwrap())
    }

    #[test]
    fn the_same_prompt_and_model_hash_the_same() {
        assert_eq!(
            key("claude-opus-5", &plan("be brief", "explain retry_backoff")),
            key("claude-opus-5", &plan("be brief", "explain retry_backoff"))
        );
    }

    #[test]
    fn a_changed_instruction_changes_the_key() {
        assert_ne!(
            key("claude-opus-5", &plan("be brief", "explain retry_backoff")),
            key("claude-opus-5", &plan("be brief", "explain send_webhook"))
        );
    }

    #[test]
    fn a_changed_system_prompt_changes_the_key() {
        assert_ne!(
            key("claude-opus-5", &plan("be brief", "same question")),
            key("claude-opus-5", &plan("be thorough", "same question"))
        );
    }

    #[test]
    fn the_same_prompt_on_a_different_model_is_a_different_key() {
        let plan = plan("be brief", "explain retry_backoff");
        assert_ne!(key("claude-opus-5", &plan), key("claude-haiku-4-5", &plan));
    }

    #[test]
    fn breakpoint_placement_does_not_affect_the_key() {
        // Same content, but long enough to earn breakpoints in one case and not
        // the other. The answer is identical, so the key must be too.
        let stable = StableContext {
            system: "x".repeat(4_000),
            ..StableContext::default()
        };
        let with = assemble(&stable, "q", &price_of("claude-opus-5").unwrap());
        let without = assemble(&stable, "q", &price_of("claude-haiku-4-5").unwrap());

        assert_ne!(with.breakpoints(), without.breakpoints());
        assert_eq!(key("claude-opus-5", &with), key("claude-opus-5", &without));
    }

    #[test]
    fn mutating_tasks_are_never_replayed_from_cache() {
        for task in [
            TaskType::Edit,
            TaskType::Refactor,
            TaskType::Plan,
            TaskType::HardDebug,
        ] {
            assert!(!is_cacheable(task), "{task} must not be cached");
        }
    }

    #[test]
    fn read_only_tasks_are_cacheable() {
        for task in [
            TaskType::Triage,
            TaskType::SelectFiles,
            TaskType::Summarize,
            TaskType::CommitMsg,
            TaskType::Title,
        ] {
            assert!(is_cacheable(task), "{task} should be cacheable");
        }
    }

    #[test]
    fn keys_are_hex_and_fixed_width() {
        let hash = key("claude-opus-5", &plan("s", "t"));
        assert_eq!(hash.len(), 64);
        assert!(hash.chars().all(|c| c.is_ascii_hexdigit()));
    }
}
