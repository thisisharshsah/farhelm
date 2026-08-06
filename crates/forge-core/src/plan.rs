//! `PLAN.md` parsing and the plan-step state machine (B1, B3).
//!
//! The file is the source of truth; the database is a mirror. That is why
//! [`ParsedPlan::content_hash`] exists — if the hash on disk stops matching the
//! hash in `plan.content_hash`, someone edited the file behind the executor's
//! back and the mirror must be rebuilt rather than trusted.
//!
//! Format:
//!
//! ```markdown
//! ---
//! tier: large
//! ---
//! # Fix webhook retry
//!
//! - [x] Reproduce failing case
//! - [x] Add regression test
//! - [>] Patch retry backoff {tier=large}
//! - [ ] Update docs
//! ```
//!
//! Prose and headings are ignored; only checklist lines become steps.

use std::collections::BTreeMap;
use std::fmt;

use sha2::{Digest, Sha256};

use crate::types::{PlanStep, PlanStepStatus, Tier};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanParseError {
    pub line: usize,
    pub message: String,
}

impl fmt::Display for PlanParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "PLAN.md line {}: {}", self.line, self.message)
    }
}

impl std::error::Error for PlanParseError {}

/// One checklist line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedStep {
    /// 1-based position, matching `plan_step.ordinal`.
    pub ordinal: i64,
    pub title: String,
    pub status: PlanStepStatus,
    /// Per-step tier pin from `{tier=...}` (M2 stage 4 override).
    pub tier: Option<Tier>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ParsedPlan {
    /// Flat `key: value` front matter. `tier` here is the plan-wide default.
    pub front_matter: BTreeMap<String, String>,
    pub steps: Vec<ParsedStep>,
    /// sha256 of the file as parsed, for drift detection.
    pub content_hash: String,
}

impl ParsedPlan {
    /// Plan-wide tier default, if the front matter pins one.
    pub fn default_tier(&self) -> Option<Tier> {
        self.front_matter.get("tier")?.parse().ok()
    }

    /// The tier this step should run at: its own pin, else the plan default.
    pub fn tier_for(&self, step: &ParsedStep) -> Option<Tier> {
        step.tier.or_else(|| self.default_tier())
    }
}

fn status_from_marker(marker: char) -> Option<PlanStepStatus> {
    match marker {
        ' ' => Some(PlanStepStatus::Todo),
        'x' | 'X' => Some(PlanStepStatus::Done),
        '>' => Some(PlanStepStatus::Active),
        '-' => Some(PlanStepStatus::Skipped),
        '!' => Some(PlanStepStatus::Failed),
        _ => None,
    }
}

/// Marker character for a status, so a round-trip through [`render`] is stable.
pub const fn marker_for(status: PlanStepStatus) -> char {
    match status {
        PlanStepStatus::Todo => ' ',
        PlanStepStatus::Done => 'x',
        PlanStepStatus::Active => '>',
        PlanStepStatus::Skipped => '-',
        PlanStepStatus::Failed => '!',
    }
}

/// Splits a trailing `{k=v, k=v}` attribute block off a step title.
fn split_attributes(title: &str) -> (String, BTreeMap<String, String>) {
    let trimmed = title.trim_end();
    let Some(open) = trimmed.rfind('{') else {
        return (trimmed.to_owned(), BTreeMap::new());
    };
    if !trimmed.ends_with('}') {
        return (trimmed.to_owned(), BTreeMap::new());
    }

    let body = &trimmed[open + 1..trimmed.len() - 1];
    let mut attributes = BTreeMap::new();
    for pair in body.split(',') {
        let Some((key, value)) = pair.split_once('=') else {
            // Not an attribute block after all — a title may legitimately end
            // in braces. Leave it alone.
            return (trimmed.to_owned(), BTreeMap::new());
        };
        attributes.insert(key.trim().to_owned(), value.trim().to_owned());
    }
    (trimmed[..open].trim_end().to_owned(), attributes)
}

/// Parses a checklist line, returning `None` for anything that is not one.
fn parse_step_line(line: &str) -> Option<(char, &str)> {
    let rest = line.trim_start();
    let rest = rest
        .strip_prefix("- ")
        .or_else(|| rest.strip_prefix("* "))
        .or_else(|| rest.strip_prefix('-'))?;
    let rest = rest.trim_start();
    let rest = rest.strip_prefix('[')?;
    let mut chars = rest.chars();
    let marker = chars.next()?;
    let rest = chars.as_str().strip_prefix(']')?;
    Some((marker, rest.trim()))
}

/// Parse a `PLAN.md`.
pub fn parse(source: &str) -> Result<ParsedPlan, PlanParseError> {
    let mut front_matter = BTreeMap::new();
    let mut steps: Vec<ParsedStep> = Vec::new();

    let mut lines = source.lines().enumerate().peekable();

    // Front matter, if the file opens with a `---` fence.
    if source.trim_start().starts_with("---") {
        // Consume the opening fence.
        lines.next();
        let mut closed = false;
        for (index, line) in lines.by_ref() {
            if line.trim() == "---" {
                closed = true;
                break;
            }
            if line.trim().is_empty() {
                continue;
            }
            let Some((key, value)) = line.split_once(':') else {
                return Err(PlanParseError {
                    line: index + 1,
                    message: format!("front matter needs `key: value`, got {line:?}"),
                });
            };
            front_matter.insert(key.trim().to_owned(), value.trim().to_owned());
        }
        if !closed {
            return Err(PlanParseError {
                line: 1,
                message: "front matter opened with `---` but never closed".into(),
            });
        }
    }

    for (index, line) in lines {
        let Some((marker, rest)) = parse_step_line(line) else {
            continue;
        };
        let Some(status) = status_from_marker(marker) else {
            return Err(PlanParseError {
                line: index + 1,
                message: format!(
                    "unknown checklist marker {marker:?} — expected one of ' ', 'x', '>', '-', '!'"
                ),
            });
        };
        if rest.is_empty() {
            return Err(PlanParseError {
                line: index + 1,
                message: "checklist item has no title".into(),
            });
        }

        let (title, attributes) = split_attributes(rest);
        let tier = match attributes.get("tier") {
            Some(raw) => Some(raw.parse().map_err(|_| PlanParseError {
                line: index + 1,
                message: format!("unknown tier {raw:?} — expected small, large, or batch"),
            })?),
            None => None,
        };

        steps.push(ParsedStep {
            ordinal: steps.len() as i64 + 1,
            title,
            status,
            tier,
        });
    }

    Ok(ParsedPlan {
        front_matter,
        steps,
        content_hash: hash(source),
    })
}

/// sha256, hex-encoded. Used for `plan.content_hash`.
pub fn hash(source: &str) -> String {
    let digest = Sha256::digest(source.as_bytes());
    let mut hex = String::with_capacity(digest.len() * 2);
    for byte in digest {
        use fmt::Write as _;
        let _ = write!(hex, "{byte:02x}");
    }
    hex
}

/// Render steps back to checklist lines, so the executor can write progress
/// back to `PLAN.md` and keep the file authoritative.
pub fn render(steps: &[PlanStep]) -> String {
    let mut out = String::new();
    for step in steps {
        use fmt::Write as _;
        let _ = writeln!(out, "- [{}] {}", marker_for(step.status), step.title);
    }
    out
}

/// Where a plan stands, for the watch glance and the session list (B2).
#[derive(Debug, Clone, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
pub struct PlanProgress {
    /// Steps that reached a terminal state (done or skipped).
    pub settled: usize,
    pub total: usize,
    /// 1-based ordinal of the step in flight, if any.
    pub current_ordinal: Option<i64>,
    pub current_title: Option<String>,
}

impl PlanProgress {
    pub fn of(steps: &[PlanStep]) -> Self {
        let current = steps
            .iter()
            .find(|step| step.status == PlanStepStatus::Active);
        Self {
            settled: steps
                .iter()
                .filter(|step| {
                    matches!(step.status, PlanStepStatus::Done | PlanStepStatus::Skipped)
                })
                .count(),
            total: steps.len(),
            current_ordinal: current.map(|step| step.ordinal),
            current_title: current.map(|step| step.title.clone()),
        }
    }

    /// True when no step remains that could still run.
    pub fn is_complete(&self) -> bool {
        self.total > 0 && self.settled == self.total
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlanError {
    NoSuchStep(i64),
    /// Another step is already in flight — one active step at a time.
    AlreadyActive(i64),
    /// The transition does not make sense from the step's current status.
    BadTransition {
        ordinal: i64,
        from: PlanStepStatus,
        action: &'static str,
    },
}

impl fmt::Display for PlanError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PlanError::NoSuchStep(ordinal) => write!(f, "no step at ordinal {ordinal}"),
            PlanError::AlreadyActive(ordinal) => {
                write!(f, "step {ordinal} is already running")
            }
            PlanError::BadTransition {
                ordinal,
                from,
                action,
            } => write!(f, "cannot {action} step {ordinal} while it is {from}"),
        }
    }
}

impl std::error::Error for PlanError {}

/// The next step the executor would pick up.
pub fn next_todo(steps: &[PlanStep]) -> Option<&PlanStep> {
    steps
        .iter()
        .find(|step| step.status == PlanStepStatus::Todo)
}

fn step_mut(steps: &mut [PlanStep], ordinal: i64) -> Result<&mut PlanStep, PlanError> {
    steps
        .iter_mut()
        .find(|step| step.ordinal == ordinal)
        .ok_or(PlanError::NoSuchStep(ordinal))
}

/// Move a step to `Active`. Fails if any other step is already running, so a
/// remote "skip" racing the executor cannot leave two steps in flight.
pub fn start(steps: &mut [PlanStep], ordinal: i64) -> Result<(), PlanError> {
    // Checks run narrowest-first: whether this step exists, then whether *this*
    // step can start, then the plan-wide invariant. Reporting "step 3 is already
    // running" when the caller asked for a step that is already done would send
    // them after the wrong problem.
    let index = steps
        .iter()
        .position(|step| step.ordinal == ordinal)
        .ok_or(PlanError::NoSuchStep(ordinal))?;

    match steps[index].status {
        PlanStepStatus::Todo | PlanStepStatus::Failed | PlanStepStatus::Active => {}
        from => {
            return Err(PlanError::BadTransition {
                ordinal,
                from,
                action: "start",
            });
        }
    }

    if let Some(active) = steps
        .iter()
        .find(|step| step.status == PlanStepStatus::Active && step.ordinal != ordinal)
    {
        return Err(PlanError::AlreadyActive(active.ordinal));
    }

    steps[index].status = PlanStepStatus::Active;
    Ok(())
}

/// Mark the running step done and attach its checkpoint commit (B1).
pub fn complete(
    steps: &mut [PlanStep],
    ordinal: i64,
    checkpoint_sha: Option<String>,
) -> Result<(), PlanError> {
    let step = step_mut(steps, ordinal)?;
    match step.status {
        PlanStepStatus::Active => {
            step.status = PlanStepStatus::Done;
            step.checkpoint_sha = checkpoint_sha;
            Ok(())
        }
        from => Err(PlanError::BadTransition {
            ordinal,
            from,
            action: "complete",
        }),
    }
}

/// Skip a step remotely (B3). Allowed from any non-terminal state.
pub fn skip(steps: &mut [PlanStep], ordinal: i64) -> Result<(), PlanError> {
    let step = step_mut(steps, ordinal)?;
    match step.status {
        PlanStepStatus::Done => Err(PlanError::BadTransition {
            ordinal,
            from: PlanStepStatus::Done,
            action: "skip",
        }),
        _ => {
            step.status = PlanStepStatus::Skipped;
            Ok(())
        }
    }
}

/// Mark the running step failed. Stays re-runnable: `start` accepts `Failed`.
pub fn fail(steps: &mut [PlanStep], ordinal: i64) -> Result<(), PlanError> {
    let step = step_mut(steps, ordinal)?;
    match step.status {
        PlanStepStatus::Active => {
            step.status = PlanStepStatus::Failed;
            Ok(())
        }
        from => Err(PlanError::BadTransition {
            ordinal,
            from,
            action: "fail",
        }),
    }
}

/// Return the running step to `Todo` — what a remote pause does, so the step is
/// picked up cleanly on resume rather than resuming mid-flight.
pub fn pause(steps: &mut [PlanStep]) -> Option<i64> {
    let active = steps
        .iter_mut()
        .find(|step| step.status == PlanStepStatus::Active)?;
    active.status = PlanStepStatus::Todo;
    Some(active.ordinal)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "\
---
tier: large
agent: claude-code
---
# Fix webhook retry

Some prose the parser should ignore, including a stray - dash.

- [x] Reproduce failing case
- [x] Add regression test
- [>] Patch retry backoff {tier=small}
- [ ] Update docs
";

    fn steps_from(source: &str) -> Vec<PlanStep> {
        parse(source)
            .unwrap()
            .steps
            .into_iter()
            .map(|parsed| PlanStep {
                id: format!("step-{}", parsed.ordinal),
                plan_id: "plan-1".into(),
                ordinal: parsed.ordinal,
                title: parsed.title,
                status: parsed.status,
                checkpoint_sha: None,
            })
            .collect()
    }

    #[test]
    fn parses_front_matter_and_checklist_and_ignores_prose() {
        let plan = parse(SAMPLE).unwrap();
        assert_eq!(plan.front_matter["tier"], "large");
        assert_eq!(plan.front_matter["agent"], "claude-code");
        assert_eq!(plan.steps.len(), 4);
        assert_eq!(plan.steps[0].title, "Reproduce failing case");
        assert_eq!(plan.steps[0].status, PlanStepStatus::Done);
        assert_eq!(plan.steps[2].status, PlanStepStatus::Active);
        assert_eq!(plan.steps[3].status, PlanStepStatus::Todo);
    }

    #[test]
    fn ordinals_are_one_based_and_dense() {
        let plan = parse(SAMPLE).unwrap();
        let ordinals: Vec<i64> = plan.steps.iter().map(|s| s.ordinal).collect();
        assert_eq!(ordinals, vec![1, 2, 3, 4]);
    }

    #[test]
    fn a_step_tier_pin_overrides_the_plan_default() {
        let plan = parse(SAMPLE).unwrap();
        assert_eq!(plan.default_tier(), Some(Tier::Large));
        assert_eq!(plan.tier_for(&plan.steps[2]), Some(Tier::Small));
        assert_eq!(plan.tier_for(&plan.steps[3]), Some(Tier::Large));
    }

    #[test]
    fn attributes_are_stripped_from_the_title() {
        let plan = parse("- [ ] Patch retry backoff {tier=large}").unwrap();
        assert_eq!(plan.steps[0].title, "Patch retry backoff");
    }

    #[test]
    fn a_title_that_merely_ends_in_braces_is_left_alone() {
        let plan = parse("- [ ] Handle the empty object {}").unwrap();
        assert_eq!(plan.steps[0].title, "Handle the empty object {}");
    }

    #[test]
    fn an_unknown_marker_names_the_line() {
        let err = parse("- [x] fine\n- [?] what is this").unwrap_err();
        assert_eq!(err.line, 2);
    }

    #[test]
    fn an_unknown_tier_pin_is_rejected_rather_than_silently_dropped() {
        let err = parse("- [ ] Do a thing {tier=enormous}").unwrap_err();
        assert!(err.message.contains("enormous"), "{}", err.message);
    }

    #[test]
    fn unterminated_front_matter_is_an_error() {
        let err = parse("---\ntier: large\n").unwrap_err();
        assert!(err.message.contains("never closed"), "{}", err.message);
    }

    #[test]
    fn a_malformed_front_matter_line_names_the_line() {
        let err = parse("---\nthis is not a pair\n---\n- [ ] step").unwrap_err();
        assert_eq!(err.line, 2);
        assert!(err.message.contains("key: value"), "{}", err.message);
    }

    #[test]
    fn a_plan_with_no_checklist_parses_to_no_steps() {
        let plan = parse("# Just a heading\n\nSome prose.").unwrap();
        assert!(plan.steps.is_empty());
    }

    #[test]
    fn the_hash_changes_when_the_file_does() {
        let before = parse(SAMPLE).unwrap().content_hash;
        let after = parse(&SAMPLE.replace("Update docs", "Update the docs"))
            .unwrap()
            .content_hash;
        assert_ne!(before, after);
    }

    #[test]
    fn rendering_round_trips_through_the_parser() {
        let steps = steps_from(SAMPLE);
        let reparsed = parse(&render(&steps)).unwrap();
        assert_eq!(reparsed.steps.len(), steps.len());
        for (parsed, original) in reparsed.steps.iter().zip(&steps) {
            assert_eq!(parsed.title, original.title);
            assert_eq!(parsed.status, original.status);
        }
    }

    #[test]
    fn progress_reports_the_step_in_flight() {
        let progress = PlanProgress::of(&steps_from(SAMPLE));
        assert_eq!(progress.settled, 2);
        assert_eq!(progress.total, 4);
        assert_eq!(progress.current_ordinal, Some(3));
        assert_eq!(
            progress.current_title.as_deref(),
            Some("Patch retry backoff")
        );
        assert!(!progress.is_complete());
    }

    #[test]
    fn an_empty_plan_is_not_reported_complete() {
        assert!(!PlanProgress::of(&[]).is_complete());
    }

    #[test]
    fn completing_a_step_attaches_its_checkpoint() {
        let mut steps = steps_from(SAMPLE);
        complete(&mut steps, 3, Some("abc123".into())).unwrap();
        assert_eq!(steps[2].status, PlanStepStatus::Done);
        assert_eq!(steps[2].checkpoint_sha.as_deref(), Some("abc123"));
    }

    #[test]
    fn only_one_step_runs_at_a_time() {
        let mut steps = steps_from(SAMPLE);
        // Step 3 is already active.
        let err = start(&mut steps, 4).unwrap_err();
        assert_eq!(err, PlanError::AlreadyActive(3));
    }

    #[test]
    fn a_finished_step_cannot_be_restarted_or_skipped() {
        let mut steps = steps_from(SAMPLE);
        assert!(matches!(
            start(&mut steps, 1),
            Err(PlanError::BadTransition { .. })
        ));
        assert!(matches!(
            skip(&mut steps, 1),
            Err(PlanError::BadTransition { .. })
        ));
    }

    #[test]
    fn a_failed_step_can_be_retried() {
        let mut steps = steps_from(SAMPLE);
        fail(&mut steps, 3).unwrap();
        assert_eq!(steps[2].status, PlanStepStatus::Failed);
        start(&mut steps, 3).unwrap();
        assert_eq!(steps[2].status, PlanStepStatus::Active);
    }

    #[test]
    fn pausing_returns_the_running_step_to_the_queue() {
        let mut steps = steps_from(SAMPLE);
        assert_eq!(pause(&mut steps), Some(3));
        assert_eq!(steps[2].status, PlanStepStatus::Todo);
        // ...and it is the next thing the executor picks up.
        assert_eq!(next_todo(&steps).unwrap().ordinal, 3);
    }

    #[test]
    fn pausing_an_idle_plan_does_nothing() {
        let mut steps = steps_from("- [ ] one\n- [ ] two");
        assert_eq!(pause(&mut steps), None);
    }

    #[test]
    fn a_plan_run_to_the_end_reports_complete() {
        let mut steps = steps_from("- [ ] one\n- [ ] two");
        while let Some(next) = next_todo(&steps).map(|step| step.ordinal) {
            start(&mut steps, next).unwrap();
            complete(&mut steps, next, Some(format!("sha-{next}"))).unwrap();
        }
        assert!(PlanProgress::of(&steps).is_complete());
    }

    #[test]
    fn skipping_counts_toward_completion() {
        let mut steps = steps_from("- [ ] one\n- [ ] two");
        start(&mut steps, 1).unwrap();
        complete(&mut steps, 1, None).unwrap();
        skip(&mut steps, 2).unwrap();
        assert!(PlanProgress::of(&steps).is_complete());
    }

    #[test]
    fn acting_on_a_missing_step_names_the_ordinal() {
        let mut steps = steps_from(SAMPLE);
        assert_eq!(start(&mut steps, 99), Err(PlanError::NoSuchStep(99)));
    }
}
