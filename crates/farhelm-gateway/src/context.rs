//! Pipeline stage 5 — retrieval, not dumping (C4).
//!
//! The single biggest source of wasted input tokens is pasting whole files into
//! a prompt so the model can read three lines of one of them. This stage walks
//! the repo, scores files against the terms the task actually mentions, and
//! emits a *skeleton* — declaration lines plus the matched line ranges with a
//! little context — under hard byte caps.
//!
//! The symbol extraction is heuristic (declaration-shaped line prefixes) rather
//! than a parse. That is a deliberate v1: it is language-agnostic, has no build
//! step, and never fails to load a grammar. Swapping in tree-sitter is a change
//! to [`declaration_prefixes`] and nothing else.
//!
//! Guard-rail from Appendix A: if trimming context raises the task retry rate,
//! loosen these caps before anything else. Savings that cause rework are fake.

use std::collections::BTreeSet;
use std::fmt::Write as _;
use std::path::Path;

use ignore::WalkBuilder;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContextBudget {
    pub max_files: usize,
    pub max_bytes_per_file: usize,
    pub max_total_bytes: usize,
    /// Lines of context kept either side of a match.
    pub context_lines: usize,
    /// Files larger than this are not read at all — a lockfile or a vendored
    /// bundle will match half the terms in the query and teach nothing.
    pub max_file_size_bytes: u64,
}

impl Default for ContextBudget {
    fn default() -> Self {
        Self {
            max_files: 12,
            max_bytes_per_file: 4_000,
            max_total_bytes: 24_000,
            context_lines: 3,
            max_file_size_bytes: 512 * 1024,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileSlice {
    /// Path relative to the repo root, so the excerpt is portable.
    pub path: String,
    pub excerpt: String,
    pub score: usize,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct RepoContext {
    pub files: Vec<FileSlice>,
    /// How many files were read and scored.
    pub scanned: usize,
    /// True when the byte cap cut the result short — the dashboard should show
    /// this, because a silently truncated context is how retries start.
    pub truncated: bool,
}

impl RepoContext {
    pub fn bytes(&self) -> usize {
        self.files.iter().map(|file| file.excerpt.len()).sum()
    }

    pub fn is_empty(&self) -> bool {
        self.files.is_empty()
    }

    /// The repo-map block, ready to drop into the prompt.
    pub fn render(&self) -> String {
        if self.files.is_empty() {
            return String::new();
        }
        let mut out = String::from("# Repository context\n\n");
        for file in &self.files {
            let _ = writeln!(
                out,
                "## {}\n```\n{}\n```\n",
                file.path,
                file.excerpt.trim_end()
            );
        }
        if self.truncated {
            out.push_str("_(context truncated at the byte cap)_\n");
        }
        out
    }
}

/// Line prefixes that look like a declaration in the languages this project
/// touches. Checked after trimming leading whitespace.
fn declaration_prefixes() -> &'static [&'static str] {
    &[
        "fn ",
        "pub fn",
        "pub async fn",
        "async fn",
        "struct ",
        "pub struct",
        "enum ",
        "pub enum",
        "trait ",
        "pub trait",
        "impl ",
        "type ",
        "pub type",
        "const ",
        "pub const",
        "static ",
        "def ",
        "class ",
        "async def",
        "function ",
        "export ",
        "interface ",
        "func ",
        "package ",
        "module ",
        "public ",
        "private ",
        "protected ",
    ]
}

fn is_declaration(line: &str) -> bool {
    let trimmed = line.trim_start();
    declaration_prefixes()
        .iter()
        .any(|prefix| trimmed.starts_with(prefix))
}

/// Function words that would match nearly every file. Scoring on these is the
/// same as scoring on nothing, but they cannot be dropped by length alone —
/// `fmt`, `api`, `sql` and `env` are all three letters and all meaningful.
const STOPWORDS: &[&str] = &[
    "the", "and", "for", "but", "not", "you", "all", "can", "its", "this", "that", "with", "from",
    "into", "then", "than", "when", "what", "which", "while", "should", "would", "could", "have",
    "has", "had", "does", "did", "was", "were", "are", "his", "her", "they", "them", "their",
    "there", "here", "make", "made", "also", "just", "only", "some", "any", "our", "out", "get",
    "let", "use", "using", "please", "need", "want",
];

/// Split a free-text query into search terms. Very short words, function words,
/// and duplicates are dropped.
pub fn terms_of(query: &str) -> Vec<String> {
    let mut seen = BTreeSet::new();
    query
        .split(|c: char| !c.is_alphanumeric() && c != '_')
        .filter(|word| word.len() >= 3)
        .map(|word| word.to_lowercase())
        .filter(|word| !STOPWORDS.contains(&word.as_str()))
        .filter(|word| seen.insert(word.clone()))
        .collect()
}

fn score_of(haystack_lower: &str, terms: &[String]) -> usize {
    terms
        .iter()
        .map(|term| haystack_lower.matches(term.as_str()).count())
        .sum()
}

/// Merge overlapping line ranges so the excerpt does not repeat itself.
fn merge(mut ranges: Vec<(usize, usize)>) -> Vec<(usize, usize)> {
    ranges.sort_unstable();
    let mut merged: Vec<(usize, usize)> = Vec::new();
    for (start, end) in ranges {
        match merged.last_mut() {
            Some(last) if start <= last.1 + 1 => last.1 = last.1.max(end),
            _ => merged.push((start, end)),
        }
    }
    merged
}

/// Build the excerpt for one file: declaration lines plus matched ranges.
fn excerpt_of(text: &str, terms: &[String], budget: &ContextBudget) -> String {
    let lines: Vec<&str> = text.lines().collect();
    let mut ranges: Vec<(usize, usize)> = Vec::new();

    for (index, line) in lines.iter().enumerate() {
        let lower = line.to_lowercase();
        let matched = terms.iter().any(|term| lower.contains(term.as_str()));
        if matched {
            let start = index.saturating_sub(budget.context_lines);
            let end = (index + budget.context_lines).min(lines.len().saturating_sub(1));
            ranges.push((start, end));
        } else if is_declaration(line) {
            // Declarations come in on their own so the model can see the shape
            // of the file even where nothing matched.
            ranges.push((index, index));
        }
    }

    let mut out = String::new();
    let mut previous_end: Option<usize> = None;
    for (start, end) in merge(ranges) {
        if out.len() >= budget.max_bytes_per_file {
            out.push_str("…\n");
            break;
        }
        if previous_end.is_some_and(|last| start > last + 1) {
            out.push_str("…\n");
        }
        for index in start..=end {
            let Some(line) = lines.get(index) else {
                continue;
            };
            // 1-based line numbers: the model quotes them back, and a developer
            // reading the transcript can jump straight there.
            let _ = writeln!(out, "{:>5} | {}", index + 1, line);
            if out.len() >= budget.max_bytes_per_file {
                break;
            }
        }
        previous_end = Some(end);
    }
    out
}

/// Walk `root`, score files against `query`, and return the best slices within
/// the budget.
pub fn build(root: &Path, query: &str, budget: &ContextBudget) -> RepoContext {
    let terms = terms_of(query);
    if terms.is_empty() {
        return RepoContext::default();
    }

    let mut candidates: Vec<FileSlice> = Vec::new();
    let mut scanned = 0usize;

    // `ignore` respects .gitignore and skips hidden files, so build artifacts
    // and vendored trees stay out without a hand-maintained deny list.
    //
    // `require_git(false)` is load-bearing: by default the ignore rules only
    // apply *inside* a git repository, so a worktree, a submodule checkout, or a
    // plain directory would silently walk straight into `secrets/` and paste it
    // into the prompt.
    let walker = WalkBuilder::new(root).require_git(false).build();

    for entry in walker.flatten() {
        if !entry.file_type().is_some_and(|kind| kind.is_file()) {
            continue;
        }
        if entry
            .metadata()
            .is_ok_and(|meta| meta.len() > budget.max_file_size_bytes)
        {
            continue;
        }
        // A non-UTF-8 read failing here is the binary-file filter.
        let Ok(text) = std::fs::read_to_string(entry.path()) else {
            continue;
        };
        scanned += 1;

        let score = score_of(&text.to_lowercase(), &terms);
        if score == 0 {
            continue;
        }

        let path = entry
            .path()
            .strip_prefix(root)
            .unwrap_or(entry.path())
            .to_string_lossy()
            .into_owned();

        let excerpt = excerpt_of(&text, &terms, budget);
        if excerpt.is_empty() {
            continue;
        }
        candidates.push(FileSlice {
            path,
            excerpt,
            score,
        });
    }

    // Highest score first; ties broken by path so the prompt prefix is stable
    // across runs — an unstable ordering would invalidate the cache every turn.
    candidates.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.path.cmp(&b.path)));

    let mut files = Vec::new();
    let mut total = 0usize;
    let mut truncated = false;
    for candidate in candidates {
        if files.len() >= budget.max_files {
            truncated = true;
            break;
        }
        if total + candidate.excerpt.len() > budget.max_total_bytes {
            truncated = true;
            break;
        }
        total += candidate.excerpt.len();
        files.push(candidate);
    }

    RepoContext {
        files,
        scanned,
        truncated,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    struct TempRepo(std::path::PathBuf);

    impl TempRepo {
        fn new(name: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "forge-ctx-{}-{name}-{:?}",
                std::process::id(),
                std::thread::current().id()
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn write(&self, relative: &str, contents: &str) -> &Self {
            let path = self.0.join(relative);
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).unwrap();
            }
            fs::write(path, contents).unwrap();
            self
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempRepo {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).ok();
        }
    }

    #[test]
    fn stopwords_and_duplicates_are_dropped() {
        assert_eq!(
            terms_of("Fix the retry_backoff in the retry_backoff helper"),
            vec!["fix", "retry_backoff", "helper"]
        );
    }

    #[test]
    fn short_but_meaningful_identifiers_survive() {
        // Dropping by length alone would lose all of these.
        assert_eq!(
            terms_of("fmt api sql env"),
            vec!["fmt", "api", "sql", "env"]
        );
    }

    #[test]
    fn an_empty_query_retrieves_nothing_rather_than_everything() {
        let repo = TempRepo::new("empty-query");
        repo.write("src/a.rs", "fn retry_backoff() {}");
        let context = build(repo.path(), "a b", &ContextBudget::default());
        assert!(context.is_empty());
    }

    #[test]
    fn only_matching_files_are_retrieved() {
        let repo = TempRepo::new("matching");
        repo.write(
            "src/retry.rs",
            "fn retry_backoff(attempts: u32) {\n    todo!()\n}",
        )
        .write("src/unrelated.rs", "fn greet() { println!(\"hi\"); }");

        let context = build(repo.path(), "retry_backoff", &ContextBudget::default());
        assert_eq!(context.files.len(), 1);
        assert!(context.files[0].path.ends_with("retry.rs"));
        assert!(context.files[0].excerpt.contains("retry_backoff"));
    }

    #[test]
    fn excerpts_carry_line_numbers() {
        let repo = TempRepo::new("line-numbers");
        repo.write("a.py", "import os\n\ndef retry_backoff():\n    return 5\n");

        let context = build(repo.path(), "retry_backoff", &ContextBudget::default());
        let excerpt = &context.files[0].excerpt;
        assert!(
            excerpt.contains("    3 | def retry_backoff():"),
            "{excerpt}"
        );
    }

    #[test]
    fn declarations_appear_even_where_nothing_matched() {
        let repo = TempRepo::new("skeleton");
        let body = format!(
            "def alpha():\n{}\ndef retry_backoff():\n    pass\n",
            "    x = 1\n".repeat(40)
        );
        repo.write("a.py", &body);

        let budget = ContextBudget::default();
        let excerpt = &build(repo.path(), "retry_backoff", &budget).files[0].excerpt;
        assert!(
            excerpt.contains("def alpha():"),
            "skeleton missing:\n{excerpt}"
        );

        // Filler only comes along as context around the match, never wholesale:
        // at most `context_lines` either side of the one matching line.
        let filler = excerpt.matches("x = 1").count();
        assert!(
            filler <= budget.context_lines,
            "dumped {filler} filler lines, expected at most {}:\n{excerpt}",
            budget.context_lines
        );
    }

    #[test]
    fn gaps_between_ranges_are_marked() {
        let repo = TempRepo::new("gaps");
        let body = format!(
            "retry_backoff one\n{}\nretry_backoff two\n",
            "filler\n".repeat(30)
        );
        repo.write("a.txt", &body);

        let excerpt =
            &build(repo.path(), "retry_backoff", &ContextBudget::default()).files[0].excerpt;
        assert!(excerpt.contains('…'), "elision marker missing:\n{excerpt}");
    }

    #[test]
    fn gitignored_files_are_never_read() {
        let repo = TempRepo::new("gitignore");
        repo.write(".gitignore", "secret/\n")
            .write("secret/keys.rs", "fn retry_backoff() {}")
            .write("src/ok.rs", "fn retry_backoff() {}");

        let context = build(repo.path(), "retry_backoff", &ContextBudget::default());
        assert!(
            context
                .files
                .iter()
                .all(|file| !file.path.contains("secret")),
            "gitignored path leaked into the prompt"
        );
    }

    #[test]
    fn the_file_cap_truncates_and_says_so() {
        let repo = TempRepo::new("file-cap");
        for index in 0..8 {
            repo.write(&format!("f{index}.rs"), "fn retry_backoff() {}");
        }

        let budget = ContextBudget {
            max_files: 3,
            ..ContextBudget::default()
        };
        let context = build(repo.path(), "retry_backoff", &budget);
        assert_eq!(context.files.len(), 3);
        assert!(context.truncated);
        assert!(context.render().contains("truncated"));
    }

    #[test]
    fn the_byte_cap_is_respected() {
        let repo = TempRepo::new("byte-cap");
        for index in 0..6 {
            repo.write(
                &format!("f{index}.rs"),
                &"fn retry_backoff() { /* padding padding padding */ }\n".repeat(50),
            );
        }

        let budget = ContextBudget {
            max_total_bytes: 2_000,
            ..ContextBudget::default()
        };
        let context = build(repo.path(), "retry_backoff", &budget);
        assert!(context.bytes() <= 2_000, "used {} bytes", context.bytes());
        assert!(context.truncated);
    }

    #[test]
    fn ordering_is_stable_so_the_cached_prefix_survives() {
        let repo = TempRepo::new("stable-order");
        repo.write("b.rs", "fn retry_backoff() {}")
            .write("a.rs", "fn retry_backoff() {}")
            .write("c.rs", "fn retry_backoff() {}");

        let first = build(repo.path(), "retry_backoff", &ContextBudget::default());
        let second = build(repo.path(), "retry_backoff", &ContextBudget::default());
        assert_eq!(first.render(), second.render());
    }

    #[test]
    fn higher_scoring_files_come_first() {
        let repo = TempRepo::new("scoring");
        repo.write("weak.rs", "fn retry_backoff() {}").write(
            "strong.rs",
            "fn retry_backoff() {}\n// retry_backoff retry_backoff\n",
        );

        let context = build(repo.path(), "retry_backoff", &ContextBudget::default());
        assert!(context.files[0].path.contains("strong"));
    }

    #[test]
    fn an_oversized_file_is_skipped_wholesale() {
        let repo = TempRepo::new("oversized");
        repo.write("huge.lock", &"retry_backoff\n".repeat(10_000));

        let budget = ContextBudget {
            max_file_size_bytes: 1_000,
            ..ContextBudget::default()
        };
        assert!(build(repo.path(), "retry_backoff", &budget).is_empty());
    }
}
