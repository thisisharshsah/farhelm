//! RelayForge's own coding agent.
//!
//! Everything else in this workspace supervises *somebody else's* agent: the
//! hook bridge answers Claude Code's permission prompts, the terminal watcher
//! reads Aider's questions off a pane. This crate is the other half — the
//! runner doing the work itself, so that a task can be started from a phone and
//! come back as a diff rather than as a pane full of scrollback.
//!
//! ```text
//!   prompt ─▶ loop ──▶ gateway ──▶ provider
//!              │  ▲       (budget, routing, cache, ledger)
//!              ▼  │
//!          tools ─┘        read · list · search · edit · write · delete · run
//!              │
//!              ▼
//!        staging overlay ──▶ unified diff ──▶ a human ──▶ applied, or discarded
//! ```
//!
//! Three properties hold it together, and each has tests named after the
//! failure it prevents:
//!
//! 1. **Edits are staged, never written.** Nothing reaches the working tree
//!    until somebody approves the whole change set. See [`workspace`].
//! 2. **Only `run` needs a card.** Approving twelve edits one at a time is a
//!    captcha, not supervision; the edits are reviewed together, as a diff.
//!    Commands go through the classifier every other agent already uses. See
//!    [`tools`].
//! 3. **Every model call goes through the cost gateway.** The loop is a caller
//!    of the pipeline, not a second route to a provider — otherwise budgets,
//!    routing and the ledger would all become advisory. See [`task`].
//!
//! And one cost decision that shapes the rest: the loop **drafts on the large
//! tier and verifies once on the frontier one** (C10). Drafting is where the
//! tokens are — a dozen turns each carrying a repo map and a growing pile of
//! tool results — and most of it is looking things up. The judgement at the end
//! is what deserves the best model, and it only needs to see the diff. See
//! [`verify`].

pub mod diff;
pub mod git;
pub mod script;
pub mod task;
pub mod tools;
pub mod verify;
pub mod workspace;

pub use diff::{ChangeKind, ChangeSet, DiffLine, FileDiff, Hunk, Tag};
pub use task::{Outcome, TaskRun, TaskSpec, run};
pub use tools::{Supervisor, ToolCall, Verdict};
pub use verify::{Assessment, Grade};
pub use workspace::{Staged, Workspace, WorkspaceError};
