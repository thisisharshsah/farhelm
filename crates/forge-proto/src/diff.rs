//! The shape of a proposed change, as a reviewer receives it.
//!
//! The review screen is the product: a task's whole output is a patch a human
//! reads on a phone and says yes or no to. That makes the diff part of the wire
//! contract — the clients need per-file counts and per-line tags to render it,
//! and a phone should not be parsing `@@` headers.
//!
//! `packages/client-core/src/diff.ts` mirrors these shapes by hand, which is why
//! they live here rather than in `forge-agent` beside the algorithm that
//! produces them. Computing a diff is domain work; *describing* one is the
//! contract, and a client should not have to link an LCS implementation to name
//! the thing it is rendering.
//!
//! The `render` methods stay with the shapes because the text they produce is
//! itself a wire field: `TaskDetail::patch` is this output verbatim, so that a
//! reviewer can copy it out or pipe it to `git apply`.

use std::fmt::Write as _;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Tag {
    Context,
    Add,
    Remove,
}

impl Tag {
    /// The character a unified diff prefixes this line with.
    pub const fn marker(self) -> char {
        match self {
            Tag::Context => ' ',
            Tag::Add => '+',
            Tag::Remove => '-',
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiffLine {
    pub tag: Tag,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Hunk {
    pub old_start: usize,
    pub old_len: usize,
    pub new_start: usize,
    pub new_len: usize,
    pub lines: Vec<DiffLine>,
}

impl Hunk {
    /// The `@@ -a,b +c,d @@` header.
    pub fn header(&self) -> String {
        format!(
            "@@ -{},{} +{},{} @@",
            self.old_start, self.old_len, self.new_start, self.new_len
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ChangeKind {
    Added,
    Modified,
    Deleted,
}

/// One file's worth of proposed change.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileDiff {
    /// Repo-relative, forward slashes, on every platform.
    pub path: String,
    pub kind: ChangeKind,
    pub added: usize,
    pub removed: usize,
    pub hunks: Vec<Hunk>,
    /// True when the file could not be read as text. `hunks` is empty; a binary
    /// file is reported rather than rendered, because a phone cannot review one
    /// and a truncated hex dump would only pretend otherwise.
    pub binary: bool,
}

impl FileDiff {
    /// This file's patch, in the format `git apply` reads.
    pub fn render(&self) -> String {
        let mut out = String::new();
        if self.binary {
            let _ = writeln!(out, "Binary file {} differs", self.path);
            return out;
        }

        let (old_label, new_label) = match self.kind {
            ChangeKind::Added => ("/dev/null".to_owned(), format!("b/{}", self.path)),
            ChangeKind::Deleted => (format!("a/{}", self.path), "/dev/null".to_owned()),
            ChangeKind::Modified => (format!("a/{}", self.path), format!("b/{}", self.path)),
        };

        let _ = writeln!(out, "--- {old_label}");
        let _ = writeln!(out, "+++ {new_label}");
        for hunk in &self.hunks {
            let _ = writeln!(out, "{}", hunk.header());
            for line in &hunk.lines {
                let _ = writeln!(out, "{}{}", line.tag.marker(), line.text);
            }
        }
        out
    }
}

/// Every file a change set touches, plus the totals a review card leads with.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChangeSet {
    pub files: Vec<FileDiff>,
}

impl ChangeSet {
    pub fn is_empty(&self) -> bool {
        self.files.is_empty()
    }

    pub fn added(&self) -> usize {
        self.files.iter().map(|file| file.added).sum()
    }

    pub fn removed(&self) -> usize {
        self.files.iter().map(|file| file.removed).sum()
    }

    /// `3 files, +42 −17`. What the notification says, and the one line that has
    /// to survive being read on a watch.
    pub fn summary(&self) -> String {
        let files = self.files.len();
        format!(
            "{files} file{}, +{} −{}",
            if files == 1 { "" } else { "s" },
            self.added(),
            self.removed()
        )
    }

    pub fn render(&self) -> String {
        self.files
            .iter()
            .map(FileDiff::render)
            .collect::<Vec<_>>()
            .join("")
    }
}
