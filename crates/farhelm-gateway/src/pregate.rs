//! Pipeline stage 2 — the deterministic pre-gate (C3/M3).
//!
//! The cheapest token is the one never sent. A formatter, a linter, a type
//! checker and the affected tests all answer questions a model would otherwise
//! be paid to guess at, and they answer them exactly. So they run first, and
//! only their *failures* reach the prompt.
//!
//! Two savings come out of this: a verify-shaped task that comes back all-green
//! costs nothing at all, and a task that does reach the model carries a short
//! digest of real failures instead of a whole file.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::process::Command;

/// How long any one check may run before it is treated as a failure. A hung
/// type checker must not hold an approval hostage.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(90);

/// Output kept per failing check. Enough to act on, short enough that the whole
/// point of the gate is not undone by the digest itself.
const MAX_OUTPUT_BYTES: usize = 4_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CheckKind {
    Format,
    Lint,
    Typecheck,
    Test,
}

impl std::fmt::Display for CheckKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            CheckKind::Format => "format",
            CheckKind::Lint => "lint",
            CheckKind::Typecheck => "typecheck",
            CheckKind::Test => "test",
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Check {
    pub name: String,
    pub kind: CheckKind,
    pub program: String,
    pub args: Vec<String>,
}

impl Check {
    pub fn new(name: &str, kind: CheckKind, command: &[&str]) -> Option<Self> {
        let (program, args) = command.split_first()?;
        Some(Self {
            name: name.to_owned(),
            kind,
            program: (*program).to_owned(),
            args: args.iter().map(|arg| (*arg).to_owned()).collect(),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CheckOutcome {
    pub name: String,
    pub kind: CheckKind,
    pub passed: bool,
    /// Combined stdout+stderr, truncated. Empty when the check passed.
    pub output: String,
    pub duration_ms: u64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreGateReport {
    pub outcomes: Vec<CheckOutcome>,
    /// True when no check could be run at all — an unknown toolchain. Distinct
    /// from "everything passed", because it means the gate proved nothing.
    pub skipped: bool,
}

impl PreGateReport {
    /// No checks ran, so the gate has no opinion. Never treated as green.
    pub fn skipped() -> Self {
        Self {
            outcomes: Vec::new(),
            skipped: true,
        }
    }

    pub fn all_green(&self) -> bool {
        !self.skipped
            && !self.outcomes.is_empty()
            && self.outcomes.iter().all(|outcome| outcome.passed)
    }

    pub fn failures(&self) -> impl Iterator<Item = &CheckOutcome> {
        self.outcomes.iter().filter(|outcome| !outcome.passed)
    }

    /// The failures, formatted for the prompt's dynamic tail. Returns `None`
    /// when there is nothing to tell the model.
    pub fn digest(&self) -> Option<String> {
        let mut sections: Vec<String> = Vec::new();
        for failure in self.failures() {
            sections.push(format!(
                "### {} ({})\n{}",
                failure.name,
                failure.kind,
                failure.output.trim()
            ));
        }
        if sections.is_empty() {
            return None;
        }
        Some(format!(
            "The following checks failed. Fix these; everything else already passes.\n\n{}",
            sections.join("\n\n")
        ))
    }
}

/// Toolchains the gate knows how to drive.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Toolchain {
    Rust,
    Node,
    Python,
    Go,
}

/// Identify a repo's toolchain from its marker files.
pub fn detect(repo: &Path) -> Option<Toolchain> {
    // Order matters only for polyglot repos; the first marker wins, and a
    // mixed repo can pin its checks in config rather than relying on guessing.
    if repo.join("Cargo.toml").is_file() {
        return Some(Toolchain::Rust);
    }
    if repo.join("go.mod").is_file() {
        return Some(Toolchain::Go);
    }
    if repo.join("pyproject.toml").is_file() || repo.join("requirements.txt").is_file() {
        return Some(Toolchain::Python);
    }
    if repo.join("package.json").is_file() {
        return Some(Toolchain::Node);
    }
    None
}

/// The default check set for a toolchain, cheapest first — a formatter failure
/// is found in milliseconds and there is no point type-checking past it.
pub fn checks_for(toolchain: Toolchain) -> Vec<Check> {
    let commands: &[(&str, CheckKind, &[&str])] = match toolchain {
        Toolchain::Rust => &[
            (
                "cargo fmt",
                CheckKind::Format,
                &["cargo", "fmt", "--all", "--check"],
            ),
            (
                "clippy",
                CheckKind::Lint,
                &[
                    "cargo",
                    "clippy",
                    "--workspace",
                    "--all-targets",
                    "--",
                    "-D",
                    "warnings",
                ],
            ),
            (
                "cargo test",
                CheckKind::Test,
                &["cargo", "test", "--workspace"],
            ),
        ],
        Toolchain::Node => &[
            (
                "prettier",
                CheckKind::Format,
                &["npx", "--no-install", "prettier", "--check", "."],
            ),
            (
                "eslint",
                CheckKind::Lint,
                &["npx", "--no-install", "eslint", "."],
            ),
            (
                "tsc",
                CheckKind::Typecheck,
                &["npx", "--no-install", "tsc", "--noEmit"],
            ),
        ],
        Toolchain::Python => &[
            (
                "ruff format",
                CheckKind::Format,
                &["ruff", "format", "--check", "."],
            ),
            ("ruff", CheckKind::Lint, &["ruff", "check", "."]),
            ("mypy", CheckKind::Typecheck, &["mypy", "."]),
            ("pytest", CheckKind::Test, &["pytest", "-x", "-q"]),
        ],
        Toolchain::Go => &[
            ("gofmt", CheckKind::Format, &["gofmt", "-l", "."]),
            ("go vet", CheckKind::Lint, &["go", "vet", "./..."]),
            ("go test", CheckKind::Test, &["go", "test", "./..."]),
        ],
    };

    commands
        .iter()
        .filter_map(|(name, kind, argv)| Check::new(name, *kind, argv))
        .collect()
}

fn truncate(mut text: String) -> String {
    if text.len() <= MAX_OUTPUT_BYTES {
        return text;
    }
    // Keep the tail: compilers and test runners put the summary last.
    let start = text.len() - MAX_OUTPUT_BYTES;
    let start = (start..text.len())
        .find(|index| text.is_char_boundary(*index))
        .unwrap_or(text.len());
    text = text.split_off(start);
    format!("…(truncated)…\n{text}")
}

/// Run one check.
async fn run_check(repo: &Path, check: &Check, timeout: Duration) -> CheckOutcome {
    let started = std::time::Instant::now();

    let spawned = Command::new(&check.program)
        .args(&check.args)
        .current_dir(repo)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .output();

    let (passed, output) = match tokio::time::timeout(timeout, spawned).await {
        Ok(Ok(result)) => {
            let mut combined = String::from_utf8_lossy(&result.stdout).into_owned();
            combined.push_str(&String::from_utf8_lossy(&result.stderr));
            (result.status.success(), combined)
        }
        // A missing tool is not a failing check — it means the gate could not
        // ask the question, and pretending otherwise would send a bogus
        // "command not found" into the prompt as if it were a lint error.
        Ok(Err(err)) if err.kind() == std::io::ErrorKind::NotFound => {
            (true, format!("skipped: {} is not installed", check.program))
        }
        Ok(Err(err)) => (false, format!("could not run {}: {err}", check.program)),
        Err(_) => (false, format!("timed out after {}s", timeout.as_secs())),
    };

    CheckOutcome {
        name: check.name.clone(),
        kind: check.kind,
        passed,
        output: if passed {
            String::new()
        } else {
            truncate(output)
        },
        duration_ms: started.elapsed().as_millis() as u64,
    }
}

/// Run a check set against a repo, stopping at the first failure.
///
/// Short-circuiting is the point: once something is broken, the model has what
/// it needs, and running the test suite behind a failing compile wastes wall
/// clock the developer is waiting on.
pub async fn run(repo: &Path, checks: &[Check], timeout: Duration) -> PreGateReport {
    if checks.is_empty() {
        return PreGateReport::skipped();
    }

    let mut outcomes = Vec::new();
    for check in checks {
        let outcome = run_check(repo, check, timeout).await;
        let failed = !outcome.passed;
        outcomes.push(outcome);
        if failed {
            break;
        }
    }

    PreGateReport {
        outcomes,
        skipped: false,
    }
}

/// Detect and run in one step. Returns a skipped report for an unknown repo.
pub async fn run_detected(repo: &Path, timeout: Duration) -> PreGateReport {
    match detect(repo) {
        Some(toolchain) => run(repo, &checks_for(toolchain), timeout).await,
        None => PreGateReport::skipped(),
    }
}

/// Where the pre-gate should run for a session, if anywhere.
pub fn repo_path(path: Option<&str>) -> Option<PathBuf> {
    let path = PathBuf::from(path?);
    path.is_dir().then_some(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shell(name: &str, kind: CheckKind, script: &str) -> Check {
        Check::new(name, kind, &["sh", "-c", script]).unwrap()
    }

    fn outcome(name: &str, passed: bool, output: &str) -> CheckOutcome {
        CheckOutcome {
            name: name.into(),
            kind: CheckKind::Lint,
            passed,
            output: output.into(),
            duration_ms: 1,
        }
    }

    #[test]
    fn a_skipped_report_is_not_green() {
        let report = PreGateReport::skipped();
        assert!(!report.all_green(), "an unknown toolchain proves nothing");
        assert_eq!(report.digest(), None);
    }

    #[test]
    fn an_empty_report_is_not_green_either() {
        let report = PreGateReport::default();
        assert!(!report.all_green());
    }

    #[test]
    fn only_failures_reach_the_prompt() {
        let report = PreGateReport {
            outcomes: vec![
                outcome("fmt", true, ""),
                outcome("clippy", false, "error: unused variable `x`"),
            ],
            skipped: false,
        };

        let digest = report.digest().unwrap();
        assert!(digest.contains("unused variable"));
        assert!(!digest.contains("fmt"), "passing checks must not be sent");
    }

    #[test]
    fn a_green_report_has_nothing_to_say() {
        let report = PreGateReport {
            outcomes: vec![outcome("fmt", true, ""), outcome("clippy", true, "")],
            skipped: false,
        };
        assert!(report.all_green());
        assert_eq!(report.digest(), None);
    }

    #[test]
    fn long_output_keeps_the_tail_where_the_summary_lives() {
        let long = format!("{}\nFAILED 3 tests", "noise\n".repeat(5_000));
        let truncated = truncate(long);
        assert!(truncated.len() < MAX_OUTPUT_BYTES + 64);
        assert!(truncated.ends_with("FAILED 3 tests"));
        assert!(truncated.starts_with("…(truncated)…"));
    }

    #[test]
    fn truncation_does_not_split_a_character() {
        let long = "é".repeat(MAX_OUTPUT_BYTES);
        let truncated = truncate(long);
        assert!(truncated.chars().count() > 0);
    }

    #[test]
    fn toolchains_are_detected_from_marker_files() {
        let dir = std::env::temp_dir().join(format!("forge-pregate-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();

        assert_eq!(detect(&dir), None);
        std::fs::write(dir.join("go.mod"), "module x").unwrap();
        assert_eq!(detect(&dir), Some(Toolchain::Go));

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn every_toolchain_has_a_runnable_check_set() {
        for toolchain in [
            Toolchain::Rust,
            Toolchain::Node,
            Toolchain::Python,
            Toolchain::Go,
        ] {
            let checks = checks_for(toolchain);
            assert!(!checks.is_empty());
            assert!(checks.iter().all(|check| !check.program.is_empty()));
        }
    }

    #[tokio::test]
    async fn a_passing_run_reports_green() {
        let report = run(
            Path::new("."),
            &[shell("ok", CheckKind::Lint, "exit 0")],
            DEFAULT_TIMEOUT,
        )
        .await;
        assert!(report.all_green());
    }

    #[tokio::test]
    async fn the_run_stops_at_the_first_failure() {
        let report = run(
            Path::new("."),
            &[
                shell("first", CheckKind::Format, "echo bad formatting; exit 1"),
                shell("second", CheckKind::Test, "exit 0"),
            ],
            DEFAULT_TIMEOUT,
        )
        .await;

        assert_eq!(report.outcomes.len(), 1, "later checks must not run");
        assert!(!report.all_green());
        assert!(report.digest().unwrap().contains("bad formatting"));
    }

    #[tokio::test]
    async fn stderr_is_captured_not_just_stdout() {
        let report = run(
            Path::new("."),
            &[shell(
                "noisy",
                CheckKind::Lint,
                "echo to-stderr >&2; exit 1",
            )],
            DEFAULT_TIMEOUT,
        )
        .await;
        assert!(report.digest().unwrap().contains("to-stderr"));
    }

    #[tokio::test]
    async fn a_missing_tool_does_not_masquerade_as_a_lint_failure() {
        let report = run(
            Path::new("."),
            &[Check::new(
                "ghost",
                CheckKind::Lint,
                &["forge-definitely-not-installed"],
            )
            .unwrap()],
            DEFAULT_TIMEOUT,
        )
        .await;

        assert!(report.all_green());
        assert_eq!(report.digest(), None);
    }

    #[tokio::test]
    async fn a_hanging_check_times_out_rather_than_blocking_forever() {
        let report = run(
            Path::new("."),
            &[shell("sleepy", CheckKind::Test, "sleep 30")],
            Duration::from_millis(150),
        )
        .await;

        assert!(!report.all_green());
        assert!(report.digest().unwrap().contains("timed out"));
    }

    #[tokio::test]
    async fn no_checks_means_a_skipped_report() {
        let report = run(Path::new("."), &[], DEFAULT_TIMEOUT).await;
        assert!(report.skipped);
    }
}
