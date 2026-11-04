//! Search across the local workspace: one query over projects, tasks, runs and
//! conversation titles, so a person can find work without opening every
//! project's lists in turn.
//!
//! The rules live here: what a query may be, how many hits come back, and how
//! a long text is cut to the passage that matched. Matching itself is a plain
//! case-insensitive substring in storage. That is deliberately simple: a local
//! workspace is small enough to scan, and a ranking or index is worth adding
//! only once it is measured to be needed.

use std::fmt;

use farhelm_proto::{SearchHit, WorkspaceSearch};

use crate::store::{SearchRow, SearchStore, StoreError, WorkspaceStore};

pub const QUERY_MIN_CHARS: usize = 2;
pub const QUERY_MAX_CHARS: usize = 200;
pub const DEFAULT_LIMIT: usize = 20;
pub const MAX_LIMIT: usize = 50;
/// Characters of context either side of a match in a snippet.
const SNIPPET_CONTEXT_CHARS: usize = 60;
/// A title longer than this is cut; titles are prompts as often as names.
const TITLE_MAX_CHARS: usize = 200;

#[derive(Debug)]
pub enum SearchError {
    Validation(&'static str),
    Store(StoreError),
}

impl fmt::Display for SearchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Validation(message) => f.write_str(message),
            Self::Store(error) => write!(f, "{error}"),
        }
    }
}

impl std::error::Error for SearchError {}

impl From<StoreError> for SearchError {
    fn from(value: StoreError) -> Self {
        Self::Store(value)
    }
}

pub struct Search<S> {
    store: S,
    workspace_id: String,
    machine_id: String,
}

impl<S: SearchStore + WorkspaceStore> Search<S> {
    pub fn new(store: S, machine_id: &str) -> Result<Self, SearchError> {
        let workspace_id = store.local_workspace_id()?;
        Ok(Self {
            store,
            workspace_id,
            machine_id: machine_id.into(),
        })
    }

    /// Search for `query`, returning at most `limit` hits, newest first.
    pub fn run(&self, query: &str, limit: Option<usize>) -> Result<WorkspaceSearch, SearchError> {
        let query = validate_query(query)?;
        let limit = limit.unwrap_or(DEFAULT_LIMIT);
        if !(1..=MAX_LIMIT).contains(&limit) {
            return Err(SearchError::Validation("limit must be between 1 and 50"));
        }
        // One more than asked for, so "there is more" is a fact, not a guess.
        let mut rows =
            self.store
                .search_workspace(&self.workspace_id, &self.machine_id, &query, limit + 1)?;
        let truncated = rows.len() > limit;
        rows.truncate(limit);
        let hits = rows.into_iter().map(|row| hit(row, &query)).collect();
        Ok(WorkspaceSearch {
            query,
            hits,
            truncated,
        })
    }
}

fn validate_query(query: &str) -> Result<String, SearchError> {
    let query = query.trim();
    let chars = query.chars().count();
    if chars < QUERY_MIN_CHARS {
        return Err(SearchError::Validation(
            "search for at least two characters",
        ));
    }
    if chars > QUERY_MAX_CHARS {
        return Err(SearchError::Validation(
            "a search can be at most 200 characters",
        ));
    }
    if query.chars().any(char::is_control) {
        return Err(SearchError::Validation(
            "a search cannot contain control characters",
        ));
    }
    Ok(query.to_owned())
}

fn hit(row: SearchRow, query: &str) -> SearchHit {
    // The snippet is for a match the title does not already show.
    let snippet = if contains_ignoring_case(&row.title, query) {
        None
    } else {
        snippet(&row.body, query)
    };
    SearchHit {
        kind: row.kind,
        id: row.id,
        project_id: row.project_id,
        project_name: row.project_name,
        title: cut(&one_line(&row.title), TITLE_MAX_CHARS),
        snippet,
        status: row.status,
        updated_at: row.updated_at,
    }
}

fn one_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn cut(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        text.to_owned()
    } else {
        format!("{}…", text.chars().take(max).collect::<String>())
    }
}

/// ASCII case folding, matching what storage's `LIKE` does.
fn contains_ignoring_case(haystack: &str, needle: &str) -> bool {
    find_ignoring_case(haystack, needle).is_some()
}

/// The character index of the first match, folding ASCII case only.
fn find_ignoring_case(haystack: &str, needle: &str) -> Option<usize> {
    let haystack: Vec<char> = haystack.chars().map(|c| c.to_ascii_lowercase()).collect();
    let needle: Vec<char> = needle.chars().map(|c| c.to_ascii_lowercase()).collect();
    if needle.is_empty() || needle.len() > haystack.len() {
        return None;
    }
    (0..=haystack.len() - needle.len())
        .find(|&start| haystack[start..start + needle.len()] == needle[..])
}

/// The passage of `body` around the first match, on one line, with an
/// ellipsis where it was cut. `None` when the body does not contain it.
fn snippet(body: &str, query: &str) -> Option<String> {
    let flat = one_line(body);
    let start = find_ignoring_case(&flat, query)?;
    let chars: Vec<char> = flat.chars().collect();
    let from = start.saturating_sub(SNIPPET_CONTEXT_CHARS);
    let to = (start + query.chars().count() + SNIPPET_CONTEXT_CHARS).min(chars.len());
    let mut passage: String = chars[from..to].iter().collect();
    if from > 0 {
        passage.insert(0, '…');
    }
    if to < chars.len() {
        passage.push('…');
    }
    Some(passage)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queries_are_trimmed_and_bounded() {
        assert_eq!(validate_query("  retry  ").unwrap(), "retry");
        assert!(validate_query(" a ").is_err());
        assert!(validate_query(&"x".repeat(201)).is_err());
        assert!(validate_query("bad\u{7}").is_err());
        assert_eq!(
            validate_query(&"é".repeat(200)).unwrap().chars().count(),
            200
        );
    }

    #[test]
    fn a_snippet_is_the_passage_around_the_match_on_one_line() {
        let body = format!(
            "{}\nThe retry\tbackoff is unbounded. {}",
            "a".repeat(100),
            "b".repeat(100)
        );
        let found = snippet(&body, "BACKOFF").unwrap();
        assert!(found.starts_with('…') && found.ends_with('…'), "{found}");
        assert!(found.contains("The retry backoff is unbounded."), "{found}");
        assert!(snippet("nothing here", "backoff").is_none());
        // Multi-byte text is cut on characters, never inside one.
        let wide = format!("{}backoff{}", "日".repeat(80), "本".repeat(80));
        assert!(snippet(&wide, "backoff").unwrap().contains("backoff"));
    }

    #[test]
    fn a_title_match_needs_no_snippet() {
        let row = SearchRow {
            kind: farhelm_proto::SearchHitKind::Task,
            id: "t".into(),
            project_id: "p".into(),
            project_name: "Payments".into(),
            title: "Bound the Retry backoff".into(),
            body: "the retry loop".into(),
            status: Some("todo".into()),
            updated_at: 1,
        };
        assert!(hit(row, "retry").snippet.is_none());
    }
}
