//! The agent's tools: their schemas, and what happens when one is called.
//!
//! Six of the seven only touch the task's own checkout, so they need no
//! permission and raise no card — reading a file and editing one inside a
//! throwaway branch are both reversible by throwing the branch away. The
//! seventh, `run`, executes a real command, and it is the only one that goes
//! through the approval queue.
//!
//! `run` executes **in that same checkout**, which is the whole reason the
//! overlay was replaced: under staging it ran against a working tree that by
//! construction did not contain the agent's own edits, so an agent could not
//! test its own work.
//!
//! That asymmetry is the design. Approving twelve individual edits is not
//! supervision, it is a captcha; the edits are reviewed *once*, together, as a
//! diff. What genuinely cannot be un-done — a command — is gated one at a time,
//! by the same classifier and the same phone-only rule that already govern
//! every other agent the runner supervises.
//!
//! ## Tool order is part of the cache contract
//!
//! [`definitions`] returns a fixed slice in a fixed order. Tool definitions
//! render ahead of the system prompt, so reordering them — or generating them
//! from a `HashMap` — moves every byte of the cached prefix and silently costs
//! full input rates on every call from then on.

use std::time::Duration;

pub use forge_gateway::ToolCall;

use crate::workspace::{Workspace, WorkspaceError};

/// Cap on what one tool result may contribute to the next prompt.
///
/// A `run` that dumps a 4 MB test log would blow the context budget and bill
/// for the privilege. Truncation is announced in the result text so the model
/// knows it is looking at a fragment and can narrow its next call.
pub const MAX_RESULT_BYTES: usize = 16 * 1024;

/// Lines returned by `read_file` when the caller does not ask for a range.
pub const DEFAULT_READ_LINES: usize = 400;

/// How long a `run` may take before it is killed and reported as timed out.
pub const RUN_TIMEOUT: Duration = Duration::from_secs(120);

/// [`ToolCall`] is the provider's wire shape and lives in the gateway, so these
/// are free functions rather than methods.
fn str_arg<'a>(call: &'a ToolCall, key: &str) -> Result<&'a str, ToolError> {
    call.input
        .get(key)
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| ToolError::BadArguments {
            tool: call.name.clone(),
            detail: format!("missing required string argument `{key}`"),
        })
}

fn usize_arg(call: &ToolCall, key: &str) -> Option<usize> {
    call.input
        .get(key)
        .and_then(serde_json::Value::as_u64)
        .map(|value| value as usize)
}

/// The one line a human sees on an approval card, or in the session tail.
pub fn summary(call: &ToolCall) -> String {
    let field = |key: &str| call.input.get(key).and_then(serde_json::Value::as_str);
    match call.name.as_str() {
        RUN => field("command").unwrap_or_default().to_owned(),
        READ_FILE | WRITE_FILE | EDIT_FILE | DELETE_FILE => {
            format!("{} {}", call.name, field("path").unwrap_or("?"))
        }
        SEARCH => format!("search {}", field("query").unwrap_or("?")),
        LIST_FILES => format!("list {}", field("path").unwrap_or(".")),
        other => format!("{other} {}", call.input),
    }
}

pub const READ_FILE: &str = "read_file";
pub const LIST_FILES: &str = "list_files";
pub const SEARCH: &str = "search";
pub const WRITE_FILE: &str = "write_file";
pub const EDIT_FILE: &str = "edit_file";
pub const DELETE_FILE: &str = "delete_file";
pub const RUN: &str = "run";

/// True when a tool changes the world outside the staging overlay.
///
/// Exactly one does. Kept as a function rather than a match at the call site so
/// that adding a tool forces a decision here about whether it needs a card.
pub const fn needs_approval(tool: &str) -> bool {
    matches!(tool.as_bytes(), b"run")
}

#[derive(Debug)]
pub enum ToolError {
    Unknown(String),
    BadArguments {
        tool: String,
        detail: String,
    },
    Workspace(WorkspaceError),
    /// The human said no. Carries their reason, which the model gets to read.
    Denied(String),
    Run(String),
}

impl std::fmt::Display for ToolError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ToolError::Unknown(name) => write!(f, "no such tool: {name}"),
            ToolError::BadArguments { tool, detail } => write!(f, "{tool}: {detail}"),
            ToolError::Workspace(err) => write!(f, "{err}"),
            ToolError::Denied(reason) => write!(f, "denied: {reason}"),
            ToolError::Run(message) => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for ToolError {}

impl From<WorkspaceError> for ToolError {
    fn from(err: WorkspaceError) -> Self {
        ToolError::Workspace(err)
    }
}

/// What a human said about one gated action.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    Approved,
    Denied(String),
}

/// The runner, seen from inside the loop.
///
/// The agent crate knows nothing about approval rows, push notifications, or
/// WebSockets — it knows that some actions have to be asked about and that
/// progress is worth narrating. Tests implement this with a struct that always
/// says yes, or always says no, and get the whole loop under test without a
/// database.
pub trait Supervisor: Send + Sync {
    /// Raise a card and block until somebody answers it.
    fn request(
        &self,
        tool: &str,
        payload: &str,
    ) -> impl std::future::Future<Output = Verdict> + Send;

    /// Narrate. Reaches the session tail and, through it, every open client.
    fn note(&self, text: &str);
}

/// Trim a tool result to the context budget, saying so when it does.
fn cap(text: String) -> String {
    if text.len() <= MAX_RESULT_BYTES {
        return text;
    }
    // Cut on a char boundary — a tool result sliced through a multi-byte
    // sequence would panic here rather than at the provider.
    let mut end = MAX_RESULT_BYTES;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    format!(
        "{}\n\n[truncated at {MAX_RESULT_BYTES} bytes of {} — narrow the request]",
        &text[..end],
        text.len()
    )
}

/// The tool list, in the order the provider will render it.
///
/// `path` is documented as repo-relative in every schema, because a model that
/// guesses absolute paths burns a turn on an error it did not need to hit.
pub fn definitions() -> Vec<serde_json::Value> {
    vec![
        serde_json::json!({
            "name": READ_FILE,
            "description": "Read a text file from the repository. Returns numbered lines. \
                Defaults to the first 400 lines; pass offset/limit for a specific range.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "Repo-relative path." },
                    "offset": { "type": "integer", "description": "1-based first line." },
                    "limit": { "type": "integer", "description": "How many lines to return." }
                },
                "required": ["path"]
            }
        }),
        serde_json::json!({
            "name": LIST_FILES,
            "description": "List files in the repository, honouring .gitignore.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Repo-relative directory. Omit for the repo root."
                    }
                }
            }
        }),
        serde_json::json!({
            "name": SEARCH,
            "description": "Case-insensitive literal substring search across the repository. \
                Returns path:line: text. Not a regular expression.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "query": { "type": "string", "description": "Literal text to find." },
                    "path": { "type": "string", "description": "Repo-relative subtree to search." }
                },
                "required": ["query"]
            }
        }),
        serde_json::json!({
            "name": EDIT_FILE,
            "description": "Replace an exact string in a file. old_string must appear exactly \
                once — include surrounding lines to make it unique. You are working on your own \
                branch, so this writes immediately; the whole change set is reviewed at the end.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "Repo-relative path." },
                    "old_string": { "type": "string", "description": "Exact text to replace." },
                    "new_string": { "type": "string", "description": "What to replace it with." }
                },
                "required": ["path", "old_string", "new_string"]
            }
        }),
        serde_json::json!({
            "name": WRITE_FILE,
            "description": "Write a whole file, creating it if needed. Writes immediately, to \
                your own branch. Prefer edit_file for changes to existing files.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "Repo-relative path." },
                    "content": { "type": "string", "description": "The complete new contents." }
                },
                "required": ["path", "content"]
            }
        }),
        serde_json::json!({
            "name": DELETE_FILE,
            "description": "Delete a file from your branch.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "Repo-relative path." }
                },
                "required": ["path"]
            }
        }),
        serde_json::json!({
            "name": RUN,
            "description": "Run a shell command — tests, a build, a linter. This one needs \
                human approval before it executes. It runs in your own checkout, so it sees \
                every edit you have made: run the tests before you finish.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "command": { "type": "string", "description": "The command to run." }
                },
                "required": ["command"]
            }
        }),
    ]
}

/// Execute one call against the workspace.
///
/// Errors come back as `Err`; the loop turns them into a tool result the model
/// reads and retries from. A tool error is not a task failure — an agent that
/// guessed a filename wrong should get told so and try again, which is exactly
/// what a human would do.
pub async fn execute<S: Supervisor>(
    call: &ToolCall,
    workspace: &mut Workspace,
    supervisor: &S,
) -> Result<String, ToolError> {
    match call.name.as_str() {
        READ_FILE => {
            let path = str_arg(call, "path")?;
            let text = workspace.read(path)?;
            let offset = usize_arg(call, "offset").unwrap_or(1).max(1);
            let limit = usize_arg(call, "limit").unwrap_or(DEFAULT_READ_LINES);

            let lines: Vec<String> = text
                .lines()
                .enumerate()
                .skip(offset - 1)
                .take(limit)
                .map(|(index, line)| format!("{:>6}\t{line}", index + 1))
                .collect();

            if lines.is_empty() {
                return Ok(format!("{path} has no lines at offset {offset}"));
            }
            Ok(cap(lines.join("\n")))
        }

        LIST_FILES => {
            let listed = workspace.list(str_arg(call, "path").ok(), 2_000)?;
            if listed.is_empty() {
                return Ok("no files".into());
            }
            Ok(cap(listed.join("\n")))
        }

        SEARCH => {
            let query = str_arg(call, "query")?;
            let hits = workspace.search(query, str_arg(call, "path").ok(), 200)?;
            if hits.is_empty() {
                return Ok(format!("no matches for {query:?}"));
            }
            Ok(cap(hits.join("\n")))
        }

        EDIT_FILE => {
            let path = str_arg(call, "path")?.to_owned();
            let old = str_arg(call, "old_string")?.to_owned();
            let new = str_arg(call, "new_string")?.to_owned();
            workspace.edit(&path, &old, &new)?;
            supervisor.note(&format!("✎ edited {path}"));
            Ok(format!("edited {path}"))
        }

        WRITE_FILE => {
            let path = str_arg(call, "path")?.to_owned();
            let content = str_arg(call, "content")?.to_owned();
            let existed = workspace.exists(&path);
            workspace.write(&path, content)?;
            supervisor.note(&format!(
                "✎ {} {path}",
                if existed { "rewrote" } else { "created" }
            ));
            Ok(format!("wrote {path}"))
        }

        DELETE_FILE => {
            let path = str_arg(call, "path")?.to_owned();
            workspace.delete(&path)?;
            supervisor.note(&format!("✎ deleted {path}"));
            Ok(format!("deleted {path}"))
        }

        RUN => {
            let command = str_arg(call, "command")?.to_owned();
            match supervisor.request(RUN, &command).await {
                Verdict::Denied(reason) => Err(ToolError::Denied(reason)),
                Verdict::Approved => run_command(&command, workspace.root()).await,
            }
        }

        other => Err(ToolError::Unknown(other.to_owned())),
    }
}

/// Run an approved command, with a timeout and a combined output cap.
async fn run_command(command: &str, root: &std::path::Path) -> Result<String, ToolError> {
    #[cfg(windows)]
    let mut process = tokio::process::Command::new("cmd");
    #[cfg(windows)]
    process.arg("/C").arg(command);

    #[cfg(not(windows))]
    let mut process = tokio::process::Command::new("sh");
    #[cfg(not(windows))]
    process.arg("-c").arg(command);

    let output = tokio::time::timeout(RUN_TIMEOUT, process.current_dir(root).output()).await;

    let output = match output {
        Err(_) => {
            return Err(ToolError::Run(format!(
                "`{command}` was still running after {}s and was killed",
                RUN_TIMEOUT.as_secs()
            )));
        }
        Ok(Err(err)) => return Err(ToolError::Run(format!("could not run `{command}`: {err}"))),
        Ok(Ok(output)) => output,
    };

    let mut text = String::new();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    if !stdout.trim().is_empty() {
        text.push_str(stdout.trim_end());
    }
    if !stderr.trim().is_empty() {
        if !text.is_empty() {
            text.push('\n');
        }
        text.push_str(stderr.trim_end());
    }
    if text.is_empty() {
        text.push_str("(no output)");
    }

    // The exit code goes first: a model skimming a truncated result must not
    // have to reach the bottom to learn whether the command succeeded.
    Ok(cap(format!(
        "exit {}\n{text}",
        output.status.code().unwrap_or(-1)
    )))
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Yes;
    impl Supervisor for Yes {
        async fn request(&self, _tool: &str, _payload: &str) -> Verdict {
            Verdict::Approved
        }
        fn note(&self, _text: &str) {}
    }

    struct No;
    impl Supervisor for No {
        async fn request(&self, _tool: &str, _payload: &str) -> Verdict {
            Verdict::Denied("not on my machine".into())
        }
        fn note(&self, _text: &str) {}
    }

    fn temp_repo(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("forge-tools-{name}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn call(name: &str, input: serde_json::Value) -> ToolCall {
        ToolCall {
            id: "toolu_1".into(),
            name: name.into(),
            input,
        }
    }

    #[test]
    fn every_tool_definition_has_a_schema_and_a_description() {
        for tool in definitions() {
            assert!(tool["name"].is_string());
            assert!(!tool["description"].as_str().unwrap().is_empty());
            assert_eq!(tool["input_schema"]["type"], "object");
        }
    }

    #[test]
    fn the_tool_order_is_fixed_because_the_prompt_cache_depends_on_it() {
        let names: Vec<String> = definitions()
            .iter()
            .map(|tool| tool["name"].as_str().unwrap().to_owned())
            .collect();
        assert_eq!(
            names,
            vec![
                READ_FILE,
                LIST_FILES,
                SEARCH,
                EDIT_FILE,
                WRITE_FILE,
                DELETE_FILE,
                RUN
            ]
        );
        // Twice, to catch anyone who reaches for a HashMap here.
        assert_eq!(definitions(), definitions());
    }

    #[test]
    fn only_run_needs_a_human() {
        assert!(needs_approval(RUN));
        for tool in [
            READ_FILE,
            LIST_FILES,
            SEARCH,
            EDIT_FILE,
            WRITE_FILE,
            DELETE_FILE,
        ] {
            assert!(!needs_approval(tool), "{tool} should not raise a card");
        }
    }

    #[tokio::test]
    async fn read_file_returns_numbered_lines() {
        let dir = temp_repo("read");
        std::fs::write(dir.join("a.txt"), "one\ntwo\nthree\n").unwrap();
        let mut workspace = Workspace::open(&dir).unwrap();

        let result = execute(
            &call(READ_FILE, serde_json::json!({"path": "a.txt"})),
            &mut workspace,
            &Yes,
        )
        .await
        .unwrap();
        assert!(result.contains("     1\tone"));
        assert!(result.contains("     3\tthree"));
    }

    #[tokio::test]
    async fn read_file_honours_an_offset_and_limit() {
        let dir = temp_repo("range");
        std::fs::write(dir.join("a.txt"), "one\ntwo\nthree\nfour\n").unwrap();
        let mut workspace = Workspace::open(&dir).unwrap();

        let result = execute(
            &call(
                READ_FILE,
                serde_json::json!({"path": "a.txt", "offset": 2, "limit": 2}),
            ),
            &mut workspace,
            &Yes,
        )
        .await
        .unwrap();
        assert!(result.contains("two"));
        assert!(result.contains("three"));
        assert!(!result.contains("four"));
    }

    #[tokio::test]
    async fn an_edit_is_written_so_the_agents_own_tests_can_see_it() {
        let dir = temp_repo("edit");
        std::fs::write(dir.join("a.txt"), "before\n").unwrap();
        let mut workspace = Workspace::open(&dir).unwrap();

        execute(
            &call(
                EDIT_FILE,
                serde_json::json!({"path": "a.txt", "old_string": "before", "new_string": "after"}),
            ),
            &mut workspace,
            &Yes,
        )
        .await
        .unwrap();

        // The assertion this test used to make was the opposite: that the file
        // on disk was untouched. Under the overlay that was the safety
        // property; it also meant `run` executed against a tree without the
        // agent's edits in it, so `cargo test` tested the code as it was before
        // the task started.
        //
        // Isolation now comes from the checkout being a branch of its own, so
        // writing immediately is safe *and* is what makes an agent able to
        // check its own work.
        assert_eq!(
            std::fs::read_to_string(dir.join("a.txt")).unwrap(),
            "after\n",
            "the edit must be on disk, or the agent cannot test what it wrote"
        );
        assert_eq!(workspace.read("a.txt").unwrap(), "after\n");
    }

    #[tokio::test]
    async fn a_missing_argument_is_a_tool_error_not_a_panic() {
        let dir = temp_repo("badargs");
        let mut workspace = Workspace::open(&dir).unwrap();

        let err = execute(
            &call(EDIT_FILE, serde_json::json!({"path": "a.txt"})),
            &mut workspace,
            &Yes,
        )
        .await
        .unwrap_err();
        assert!(matches!(err, ToolError::BadArguments { .. }));
    }

    #[tokio::test]
    async fn an_unknown_tool_is_reported_rather_than_ignored() {
        let dir = temp_repo("unknown");
        let mut workspace = Workspace::open(&dir).unwrap();
        let err = execute(
            &call("teleport", serde_json::json!({})),
            &mut workspace,
            &Yes,
        )
        .await
        .unwrap_err();
        assert!(matches!(err, ToolError::Unknown(_)));
    }

    #[tokio::test]
    async fn a_denied_run_does_not_execute() {
        let dir = temp_repo("denied");
        let mut workspace = Workspace::open(&dir).unwrap();

        let err = execute(
            &call(
                RUN,
                serde_json::json!({"command": "touch should-not-exist"}),
            ),
            &mut workspace,
            &No,
        )
        .await
        .unwrap_err();

        assert!(matches!(err, ToolError::Denied(_)));
        assert!(!dir.join("should-not-exist").exists());
    }

    #[tokio::test]
    #[cfg(not(windows))]
    async fn an_approved_run_executes_in_the_repo_and_reports_its_exit_code() {
        let dir = temp_repo("run");
        let mut workspace = Workspace::open(&dir).unwrap();

        let result = execute(
            &call(RUN, serde_json::json!({"command": "echo hello && exit 3"})),
            &mut workspace,
            &Yes,
        )
        .await
        .unwrap();

        assert!(result.starts_with("exit 3"));
        assert!(result.contains("hello"));
    }

    #[test]
    fn a_result_over_the_cap_is_truncated_and_says_so() {
        let capped = cap("x".repeat(MAX_RESULT_BYTES * 2));
        assert!(capped.len() < MAX_RESULT_BYTES * 2);
        assert!(capped.contains("truncated"));
    }

    #[test]
    fn truncation_does_not_split_a_multi_byte_character() {
        // A string of 3-byte characters guarantees the cut lands mid-character.
        let text = "€".repeat(MAX_RESULT_BYTES);
        let capped = cap(text);
        assert!(capped.contains("truncated"));
    }

    #[test]
    fn a_run_call_summarises_as_its_command() {
        let call = call(
            RUN,
            serde_json::json!({"command": "cargo test -p forge-core"}),
        );
        assert_eq!(summary(&call), "cargo test -p forge-core");
    }

    #[test]
    fn a_file_call_summarises_as_its_path() {
        let call = call(EDIT_FILE, serde_json::json!({"path": "src/x.rs"}));
        assert_eq!(summary(&call), "edit_file src/x.rs");
    }
}
