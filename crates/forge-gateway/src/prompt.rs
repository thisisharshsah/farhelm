//! Pipeline stage 6 — cache-shaped prompt assembly (C1/M1).
//!
//! Prompt caching is a **prefix match**: one changed byte anywhere invalidates
//! everything after it. So the gateway, not the agent, owns prompt order, and
//! the order is strictly stable → volatile:
//!
//! ```text
//! [tools] ⟂ [system + conventions] ⟂ [repo map] ⟂ [compacted history] | dynamic tail
//! ```
//!
//! `⟂` is a `cache_control` breakpoint. Nothing dynamic ever precedes one —
//! that single rule is what makes the difference between a 78% cache-read ratio
//! and 0%, and it is the property the tests below pin down.
//!
//! Two details that are easy to get wrong and expensive to miss:
//!  - The API renders `tools` → `system` → `messages`, so a breakpoint on the
//!    last *system* block also caches the tools ahead of it. There is no need
//!    to spend one of the four breakpoints on tools.
//!  - A prefix shorter than the model's minimum silently does not cache at all.
//!    Placing a breakpoint there is not an error, it just achieves nothing — so
//!    the assembler skips it and says why, rather than reporting a cache that
//!    was never created.

use std::fmt::Write as _;

use forge_domain::price::ModelPrice;
use serde::{Deserialize, Serialize};

/// The API's ceiling. Four is plenty for this layout, which uses three.
pub const MAX_BREAKPOINTS: usize = 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    User,
    Assistant,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Turn {
    pub role: Role,
    pub text: String,
}

impl Turn {
    pub fn user(text: impl Into<String>) -> Self {
        Self {
            role: Role::User,
            text: text.into(),
        }
    }

    pub fn assistant(text: impl Into<String>) -> Self {
        Self {
            role: Role::Assistant,
            text: text.into(),
        }
    }
}

/// Everything that must be byte-identical between turns for caching to pay.
///
/// The type is the contract: a caller physically cannot interleave a timestamp
/// into the stable half, because the dynamic half is a separate argument.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct StableContext {
    /// Tool definitions, already serialised. Must be in a deterministic order —
    /// reordering the tool list invalidates every cache tier.
    pub tools: Vec<serde_json::Value>,
    /// The frozen system prompt. No dates, no session ids, no user names.
    pub system: String,
    /// Repo conventions (`CLAUDE.md` and friends).
    pub conventions: String,
    /// Stage 5's retrieval output.
    pub repo_map: String,
    /// Rolling summary + pinned facts (C7). Older turns, already compacted.
    pub history: Vec<Turn>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CacheControl {
    #[serde(rename = "type")]
    pub kind: &'static str,
}

impl CacheControl {
    pub const EPHEMERAL: CacheControl = CacheControl { kind: "ephemeral" };
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TextBlock {
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_control: Option<CacheControl>,
}

impl TextBlock {
    fn new(text: String) -> Self {
        Self {
            kind: "text",
            text,
            cache_control: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Message {
    pub role: Role,
    pub content: Vec<TextBlock>,
}

/// Why a breakpoint was or was not placed. Surfaced so a disappointing
/// cache-read ratio can be explained without guesswork.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BreakpointNote {
    pub segment: &'static str,
    pub placed: bool,
    pub approx_prefix_tokens: usize,
    pub reason: &'static str,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PromptPlan {
    pub tools: Vec<serde_json::Value>,
    pub system: Vec<TextBlock>,
    pub messages: Vec<Message>,
    #[serde(skip)]
    pub notes: Vec<BreakpointNote>,
}

impl PromptPlan {
    pub fn breakpoints(&self) -> usize {
        self.system
            .iter()
            .filter(|block| block.cache_control.is_some())
            .count()
            + self
                .messages
                .iter()
                .flat_map(|message| &message.content)
                .filter(|block| block.cache_control.is_some())
                .count()
    }

    /// Every byte the API will hash ahead of the dynamic tail.
    ///
    /// Exposed for tests and for the cache key: if this string differs between
    /// two turns that should have shared a cache, something leaked into the
    /// stable half.
    pub fn stable_prefix(&self) -> String {
        let mut out = String::new();
        for tool in &self.tools {
            let _ = writeln!(out, "{tool}");
        }
        for block in &self.system {
            out.push_str(&block.text);
            out.push('\n');
        }
        // Every message except the last, which is the dynamic tail.
        for message in self.messages.iter().rev().skip(1).rev() {
            for block in &message.content {
                out.push_str(&block.text);
                out.push('\n');
            }
        }
        out
    }

    /// The cumulative prefix at each breakpoint, in the order the API renders
    /// them (tools → system → messages), shortest first.
    ///
    /// This is what the provider actually keys its cache on: a request reads
    /// from the longest of these it has seen before and writes the remainder.
    /// Exposed so caching can be *simulated* faithfully in tests rather than
    /// assumed.
    pub fn cache_prefixes(&self) -> Vec<String> {
        let mut prefixes = Vec::new();
        let mut running = String::new();

        for tool in &self.tools {
            let _ = writeln!(running, "{tool}");
        }
        for block in &self.system {
            running.push_str(&block.text);
            running.push('\n');
            if block.cache_control.is_some() {
                prefixes.push(running.clone());
            }
        }
        for message in &self.messages {
            for block in &message.content {
                running.push_str(&block.text);
                running.push('\n');
                if block.cache_control.is_some() {
                    prefixes.push(running.clone());
                }
            }
        }
        prefixes
    }

    /// The dynamic tail — the only part that legitimately changes per turn.
    pub fn dynamic_tail(&self) -> &str {
        self.messages
            .last()
            .and_then(|message| message.content.last())
            .map(|block| block.text.as_str())
            .unwrap_or_default()
    }
}

/// Rough token estimate, used only to decide whether a prefix clears the
/// model's minimum cacheable length. Four characters per token is the usual
/// English/code approximation; the authoritative number comes from the
/// `count_tokens` endpoint, which costs a round trip this stage will not spend.
pub fn approx_tokens(text: &str) -> usize {
    text.len().div_ceil(4)
}

/// Assemble a cache-shaped prompt.
///
/// `dynamic` is everything that changes this turn: the new instruction, the
/// pre-gate digest, tool results. It is appended last and never cached.
pub fn assemble(stable: &StableContext, dynamic: &str, price: &ModelPrice) -> PromptPlan {
    let mut notes = Vec::new();
    let minimum = price.min_cacheable_tokens as usize;

    // --- system tier: tools + system + conventions -------------------------
    let mut system_text = stable.system.trim().to_owned();
    if !stable.conventions.trim().is_empty() {
        if !system_text.is_empty() {
            system_text.push_str("\n\n");
        }
        system_text.push_str(stable.conventions.trim());
    }

    let mut system_blocks: Vec<TextBlock> = Vec::new();
    let mut running = stable
        .tools
        .iter()
        .map(|tool| approx_tokens(&tool.to_string()))
        .sum::<usize>();

    if !system_text.is_empty() {
        running += approx_tokens(&system_text);
        let mut block = TextBlock::new(system_text);
        // This breakpoint covers the tools too — they render ahead of system.
        let placed = running >= minimum;
        if placed {
            block.cache_control = Some(CacheControl::EPHEMERAL);
        }
        notes.push(BreakpointNote {
            segment: "system+conventions",
            placed,
            approx_prefix_tokens: running,
            reason: if placed {
                "covers tools, system prompt and repo conventions"
            } else {
                "prefix below the model's minimum cacheable length"
            },
        });
        system_blocks.push(block);
    }

    // --- repo map ----------------------------------------------------------
    if !stable.repo_map.trim().is_empty() {
        let text = stable.repo_map.trim().to_owned();
        running += approx_tokens(&text);
        let mut block = TextBlock::new(text);
        let placed = running >= minimum;
        if placed {
            block.cache_control = Some(CacheControl::EPHEMERAL);
        }
        notes.push(BreakpointNote {
            segment: "repo map",
            placed,
            approx_prefix_tokens: running,
            reason: if placed {
                "retrieval output changes only when the repo does"
            } else {
                "prefix below the model's minimum cacheable length"
            },
        });
        system_blocks.push(block);
    }

    // --- compacted history -------------------------------------------------
    let mut messages: Vec<Message> = stable
        .history
        .iter()
        .map(|turn| Message {
            role: turn.role,
            content: vec![TextBlock::new(turn.text.clone())],
        })
        .collect();

    if let Some(last) = messages.last_mut() {
        running += stable
            .history
            .iter()
            .map(|turn| approx_tokens(&turn.text))
            .sum::<usize>();
        let placed = running >= minimum;
        if placed && let Some(block) = last.content.last_mut() {
            block.cache_control = Some(CacheControl::EPHEMERAL);
        }
        notes.push(BreakpointNote {
            segment: "compacted history",
            placed,
            approx_prefix_tokens: running,
            reason: if placed {
                "history grows only by appending"
            } else {
                "prefix below the model's minimum cacheable length"
            },
        });
    }

    // --- dynamic tail: never cached ---------------------------------------
    messages.push(Message {
        role: Role::User,
        content: vec![TextBlock::new(dynamic.to_owned())],
    });

    let plan = PromptPlan {
        tools: stable.tools.clone(),
        system: system_blocks,
        messages,
        notes,
    };

    debug_assert!(
        plan.breakpoints() <= MAX_BREAKPOINTS,
        "assembled {} breakpoints, API allows {MAX_BREAKPOINTS}",
        plan.breakpoints()
    );
    plan
}

#[cfg(test)]
mod tests {
    use super::*;
    use forge_domain::price::price_of;

    fn opus() -> ModelPrice {
        price_of("claude-opus-5").unwrap()
    }

    fn haiku() -> ModelPrice {
        price_of("claude-haiku-4-5").unwrap()
    }

    /// Long enough to clear every model's minimum cacheable prefix.
    fn bulky(label: &str) -> String {
        format!("{label} ").repeat(3_000)
    }

    fn stable() -> StableContext {
        StableContext {
            tools: vec![serde_json::json!({ "name": "bash", "description": "run a command" })],
            system: bulky("You are a coding agent."),
            conventions: "Use tabs. Never touch generated files.".into(),
            repo_map: bulky("src/retry.rs"),
            history: vec![
                Turn::user("Fix the webhook retry"),
                Turn::assistant("I reproduced the failure."),
            ],
        }
    }

    #[test]
    fn the_stable_prefix_is_byte_identical_across_different_tails() {
        let stable = stable();
        let first = assemble(&stable, "Now patch the backoff ceiling.", &opus());
        let second = assemble(&stable, "Actually, revert that.", &opus());

        assert_eq!(
            first.stable_prefix(),
            second.stable_prefix(),
            "the cached prefix moved between turns — caching would be worthless"
        );
        assert_ne!(first.dynamic_tail(), second.dynamic_tail());
    }

    #[test]
    fn the_dynamic_tail_is_the_last_message_and_carries_no_breakpoint() {
        let plan = assemble(&stable(), "the new instruction", &opus());
        let last = plan.messages.last().unwrap();
        assert_eq!(last.role, Role::User);
        assert_eq!(plan.dynamic_tail(), "the new instruction");
        assert!(
            last.content
                .iter()
                .all(|block| block.cache_control.is_none()),
            "a breakpoint on the tail would cache a value that changes every turn"
        );
    }

    #[test]
    fn segments_are_ordered_stable_to_volatile() {
        let plan = assemble(&stable(), "tail", &opus());
        // System carries the frozen prompt then the repo map; history and the
        // tail follow in messages.
        assert_eq!(plan.system.len(), 2);
        assert!(plan.system[0].text.contains("coding agent"));
        assert!(plan.system[1].text.contains("src/retry.rs"));
        assert_eq!(plan.messages.len(), 3); // 2 history + tail
    }

    #[test]
    fn breakpoint_count_stays_within_the_api_limit() {
        let plan = assemble(&stable(), "tail", &opus());
        assert_eq!(plan.breakpoints(), 3);
        assert!(plan.breakpoints() <= MAX_BREAKPOINTS);
    }

    #[test]
    fn a_changed_repo_map_leaves_the_system_prefix_intact() {
        // The first breakpoint must still hit when only retrieval changed —
        // that is the whole reason the repo map sits after the system prompt.
        let mut a = stable();
        let mut b = stable();
        b.repo_map = bulky("src/other.rs");

        a.repo_map = bulky("src/retry.rs");
        let first = assemble(&a, "tail", &opus());
        let second = assemble(&b, "tail", &opus());

        assert_eq!(first.system[0].text, second.system[0].text);
        assert_ne!(first.system[1].text, second.system[1].text);
    }

    #[test]
    fn tools_do_not_need_their_own_breakpoint() {
        let plan = assemble(&stable(), "tail", &opus());
        // Tools render ahead of system, so the system breakpoint covers them.
        assert!(plan.stable_prefix().contains("bash"));
        assert_eq!(plan.tools.len(), 1);
    }

    #[test]
    fn a_short_prompt_gets_no_breakpoints_and_says_why() {
        let short = StableContext {
            system: "Be brief.".into(),
            ..StableContext::default()
        };
        let plan = assemble(&short, "hello", &opus());

        assert_eq!(plan.breakpoints(), 0);
        let note = &plan.notes[0];
        assert!(!note.placed);
        assert!(note.reason.contains("minimum cacheable"));
    }

    #[test]
    fn the_minimum_is_read_from_the_model_not_hardcoded() {
        // ~700 tokens: over Opus 5's 512 minimum, under Haiku 4.5's 4096.
        let medium = StableContext {
            system: "x".repeat(2_800),
            ..StableContext::default()
        };

        assert_eq!(assemble(&medium, "t", &opus()).breakpoints(), 1);
        assert_eq!(assemble(&medium, "t", &haiku()).breakpoints(), 0);
    }

    #[test]
    fn empty_segments_are_omitted_rather_than_sent_blank() {
        let sparse = StableContext {
            system: bulky("system"),
            ..StableContext::default()
        };
        let plan = assemble(&sparse, "tail", &opus());

        assert_eq!(plan.system.len(), 1, "no empty repo-map block");
        assert_eq!(plan.messages.len(), 1, "no empty history turns");
        assert!(plan.notes.iter().all(|note| note.segment != "repo map"));
    }

    #[test]
    fn history_grows_by_appending_so_the_earlier_prefix_survives() {
        let base = stable();
        let mut grown = base.clone();
        grown.history.push(Turn::user("And now the docs"));

        let before = assemble(&base, "tail", &opus());
        let after = assemble(&grown, "tail", &opus());

        assert!(
            after.stable_prefix().starts_with(&before.stable_prefix()),
            "history was rewritten rather than appended to"
        );
    }

    #[test]
    fn serialised_blocks_carry_the_wire_shape_the_api_expects() {
        let plan = assemble(&stable(), "tail", &opus());
        let json = serde_json::to_value(&plan.system[0]).unwrap();
        assert_eq!(json["type"], "text");
        assert_eq!(json["cache_control"]["type"], "ephemeral");

        // A block without a breakpoint must omit the key entirely, not send null.
        let tail = &plan.messages.last().unwrap().content[0];
        let json = serde_json::to_value(tail).unwrap();
        assert!(json.get("cache_control").is_none());
    }

    #[test]
    fn approx_tokens_rounds_up_so_a_short_prefix_is_never_over_counted() {
        assert_eq!(approx_tokens(""), 0);
        assert_eq!(approx_tokens("abc"), 1);
        assert_eq!(approx_tokens("abcd"), 1);
        assert_eq!(approx_tokens("abcde"), 2);
    }
}
