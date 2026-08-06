//! The staging overlay — where the agent's edits live until a human says yes.
//!
//! Every write the agent makes lands here, not on disk. That single decision is
//! what turns "an agent with filesystem access" into "a proposal you review":
//! there is no window in which half a change set exists in the working tree, no
//! partial state to clean up after a denial, and the diff can be rendered and
//! sent to a phone *before* anything is committed to.
//!
//! ## Two invariants
//!
//! 1. **Nothing escapes the repo root.** Paths are resolved lexically — no `..`
//!    component survives — and every path that resolves to an existing file is
//!    re-checked after canonicalisation, which is what catches a symlink
//!    pointing at `/etc`.
//! 2. **The original is captured on first touch, not at review time.** The diff
//!    a human approves is the diff they were shown. If the file moved underneath
//!    the task in between, [`Workspace::apply`] refuses rather than silently
//!    resolving it in the agent's favour.

use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::diff::{ChangeKind, ChangeSet, FileDiff, binary_diff, file_diff};

/// Refuse to read or stage anything larger than this. A source file is
/// kilobytes; a megabyte means a lockfile, a vendored bundle, or a mistake, and
/// none of the three belong in a prompt or on a review card.
pub const MAX_FILE_BYTES: u64 = 512 * 1024;

#[derive(Debug)]
pub enum WorkspaceError {
    /// The path left the repo, or tried to.
    Escapes(String),
    NotFound(String),
    TooLarge {
        path: String,
        bytes: u64,
    },
    /// Not valid UTF-8. The agent edits text; it does not get to touch binaries.
    Binary(String),
    /// `old_string` matched zero times, or more than once.
    NoUniqueMatch {
        path: String,
        matches: usize,
    },
    /// The file changed on disk between staging and applying.
    Stale(String),
    Io {
        path: String,
        message: String,
    },
}

impl std::fmt::Display for WorkspaceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            WorkspaceError::Escapes(path) => {
                write!(f, "{path} is outside the repository")
            }
            WorkspaceError::NotFound(path) => write!(f, "{path} does not exist"),
            WorkspaceError::TooLarge { path, bytes } => write!(
                f,
                "{path} is {bytes} bytes, over the {MAX_FILE_BYTES}-byte limit"
            ),
            WorkspaceError::Binary(path) => write!(f, "{path} is not a text file"),
            WorkspaceError::NoUniqueMatch { path, matches } => match matches {
                0 => write!(f, "old_string was not found in {path}"),
                n => write!(
                    f,
                    "old_string matches {n} times in {path}; include enough surrounding \
                     lines to make it unique"
                ),
            },
            WorkspaceError::Stale(path) => write!(
                f,
                "{path} changed on disk after the agent read it — the diff you \
                 reviewed no longer applies"
            ),
            WorkspaceError::Io { path, message } => write!(f, "{path}: {message}"),
        }
    }
}

impl std::error::Error for WorkspaceError {}

type Result<T> = std::result::Result<T, WorkspaceError>;

/// One staged file: what it was, and what the agent proposes it becomes.
///
/// `None` content is a deletion. `None` original is a file that did not exist.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Staged {
    pub original: Option<String>,
    pub content: Option<String>,
}

/// A repo root plus everything the agent wants to change about it.
///
/// Serialisable in full: a task awaiting review has to survive a runner
/// restart, and a review card whose diff evaporated on restart would be worse
/// than no review card.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Workspace {
    root: PathBuf,
    staged: BTreeMap<String, Staged>,
    /// Paths the agent touched that turned out to be binary, so the change set
    /// can say so without re-reading them.
    binaries: BTreeMap<String, ChangeKind>,
}

impl Workspace {
    /// Open a repo root. Canonicalised once here so every later containment
    /// check compares against a real path rather than whatever the caller typed.
    pub fn open(root: impl AsRef<Path>) -> Result<Self> {
        let root = root.as_ref();
        let canonical = root.canonicalize().map_err(|err| WorkspaceError::Io {
            path: root.display().to_string(),
            message: err.to_string(),
        })?;
        Ok(Self {
            root: canonical,
            staged: BTreeMap::new(),
            binaries: BTreeMap::new(),
        })
    }

    /// A workspace that has never been checked against the filesystem.
    ///
    /// Only for the failure path: when [`Workspace::open`] cannot resolve a root
    /// there is still a task run to hand back, and it needs a workspace-shaped
    /// hole in it. Nothing is ever staged into one of these, so `changes` is
    /// empty and `apply` writes nothing — which is why it is safe for it to hold
    /// a path that may not exist.
    ///
    /// It exists so that branch does not have to `unwrap` a second
    /// `canonicalize` that can fail for exactly the same reason as the first.
    pub fn detached(root: impl Into<PathBuf>) -> Self {
        Self {
            root: root.into(),
            staged: BTreeMap::new(),
            binaries: BTreeMap::new(),
        }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn staged(&self) -> &BTreeMap<String, Staged> {
        &self.staged
    }

    /// Resolve a repo-relative path to an absolute one inside the root.
    ///
    /// Lexical, deliberately: this has to work for files that do not exist yet,
    /// so it cannot lean on `canonicalize`. Any `..` at all is refused rather
    /// than resolved — `src/../../etc/passwd` normalises to something outside
    /// the root, and a rule of "no parent components" is one a reader can check
    /// by eye.
    pub fn resolve(&self, relative: &str) -> Result<PathBuf> {
        let candidate = Path::new(relative);
        if candidate.is_absolute() {
            return Err(WorkspaceError::Escapes(relative.to_owned()));
        }

        let mut out = self.root.clone();
        for component in candidate.components() {
            match component {
                Component::Normal(part) => out.push(part),
                Component::CurDir => {}
                Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                    return Err(WorkspaceError::Escapes(relative.to_owned()));
                }
            }
        }

        // A symlink can point anywhere, and lexical checks cannot see it. If the
        // path exists, the resolved form has to still be under the root.
        if let Ok(real) = out.canonicalize()
            && !real.starts_with(&self.root)
        {
            return Err(WorkspaceError::Escapes(relative.to_owned()));
        }
        Ok(out)
    }

    /// Normalise a path for use as a staging key: forward slashes, no `./`.
    fn key(&self, relative: &str) -> String {
        relative.trim_start_matches("./").replace('\\', "/")
    }

    /// Read a file's on-disk content. `None` when it does not exist.
    fn on_disk(&self, relative: &str) -> Result<Option<String>> {
        let path = self.resolve(relative)?;
        let metadata = match std::fs::metadata(&path) {
            Ok(metadata) => metadata,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(err) => {
                return Err(WorkspaceError::Io {
                    path: relative.to_owned(),
                    message: err.to_string(),
                });
            }
        };

        if metadata.is_dir() {
            return Err(WorkspaceError::Io {
                path: relative.to_owned(),
                message: "is a directory".into(),
            });
        }
        if metadata.len() > MAX_FILE_BYTES {
            return Err(WorkspaceError::TooLarge {
                path: relative.to_owned(),
                bytes: metadata.len(),
            });
        }

        match std::fs::read(&path) {
            Ok(bytes) => match String::from_utf8(bytes) {
                Ok(text) => Ok(Some(text)),
                Err(_) => Err(WorkspaceError::Binary(relative.to_owned())),
            },
            Err(err) => Err(WorkspaceError::Io {
                path: relative.to_owned(),
                message: err.to_string(),
            }),
        }
    }

    /// What the agent would see if it read this file now: its own staged edit if
    /// it has made one, the working tree otherwise.
    pub fn read(&self, relative: &str) -> Result<String> {
        let key = self.key(relative);
        if let Some(staged) = self.staged.get(&key) {
            return staged.content.clone().ok_or(WorkspaceError::NotFound(key));
        }
        self.on_disk(&key)?.ok_or(WorkspaceError::NotFound(key))
    }

    pub fn exists(&self, relative: &str) -> bool {
        let key = self.key(relative);
        match self.staged.get(&key) {
            Some(staged) => staged.content.is_some(),
            None => self
                .resolve(&key)
                .map(|path| path.is_file())
                .unwrap_or(false),
        }
    }

    /// Capture the original once, on first touch. Later edits to the same file
    /// diff against what was there when the task started, not against the
    /// agent's own previous edit — otherwise a file rewritten twice would show
    /// only the second rewrite.
    fn entry(&mut self, key: &str) -> Result<&mut Staged> {
        if !self.staged.contains_key(key) {
            let original = match self.on_disk(key) {
                Ok(original) => original,
                Err(WorkspaceError::Binary(path)) => {
                    self.binaries.insert(path.clone(), ChangeKind::Modified);
                    return Err(WorkspaceError::Binary(path));
                }
                Err(err) => return Err(err),
            };
            self.staged.insert(
                key.to_owned(),
                Staged {
                    content: original.clone(),
                    original,
                },
            );
        }
        Ok(self.staged.get_mut(key).expect("just inserted"))
    }

    /// Stage a whole-file write. Creates the file if it did not exist.
    pub fn stage_write(&mut self, relative: &str, content: impl Into<String>) -> Result<()> {
        let key = self.key(relative);
        // Refuse up front rather than staging something that cannot be applied.
        self.resolve(&key)?;
        let content = content.into();
        if content.len() as u64 > MAX_FILE_BYTES {
            return Err(WorkspaceError::TooLarge {
                path: key,
                bytes: content.len() as u64,
            });
        }
        self.entry(&key)?.content = Some(content);
        Ok(())
    }

    /// Stage a single exact replacement.
    ///
    /// Uniqueness is required, like every editing tool that has learned the
    /// lesson: an `old_string` that matches twice means the model was thinking
    /// about one of them and would have silently changed the other.
    pub fn stage_edit(&mut self, relative: &str, old: &str, new: &str) -> Result<()> {
        let key = self.key(relative);
        let current = self.read(&key)?;

        let matches = if old.is_empty() {
            0
        } else {
            current.matches(old).count()
        };
        if matches != 1 {
            return Err(WorkspaceError::NoUniqueMatch { path: key, matches });
        }

        let updated = current.replacen(old, new, 1);
        self.entry(&key)?.content = Some(updated);
        Ok(())
    }

    /// Stage a deletion.
    pub fn stage_delete(&mut self, relative: &str) -> Result<()> {
        let key = self.key(relative);
        if !self.exists(&key) {
            return Err(WorkspaceError::NotFound(key));
        }
        self.entry(&key)?.content = None;
        Ok(())
    }

    /// Everything staged, as a reviewable change set.
    ///
    /// Files edited back to their original content drop out — an agent that
    /// wrote a line and then removed it again has proposed nothing, and a review
    /// card listing an empty file is a card that wastes a decision.
    pub fn changes(&self) -> ChangeSet {
        let mut files: Vec<FileDiff> = self
            .staged
            .iter()
            .filter_map(|(path, staged)| {
                file_diff(path, staged.original.as_deref(), staged.content.as_deref())
            })
            .collect();

        files.extend(
            self.binaries
                .iter()
                .map(|(path, kind)| binary_diff(path, *kind)),
        );
        files.sort_by(|left, right| left.path.cmp(&right.path));
        ChangeSet { files }
    }

    /// Write the staged content to disk.
    ///
    /// Checked against the originals first: if any file moved since the agent
    /// read it, nothing is written. A partially applied change set is the one
    /// outcome worse than a rejected one, and "the diff you approved is the diff
    /// that landed" is the promise the review screen makes.
    pub fn apply(&self) -> Result<Vec<String>> {
        self.write_side(|staged| &staged.original, |staged| &staged.content)
    }

    /// Put back what was there before this change set landed.
    ///
    /// The exact mirror of [`Workspace::apply`] — the overlay holds both sides,
    /// so undoing is the same walk with the two swapped. That symmetry is the
    /// point: it means "applied" is not a one-way door in a system where every
    /// other step is reversible by doing nothing.
    ///
    /// Guarded the same way, in the other direction: if a file no longer matches
    /// what the agent wrote, somebody has edited it since and reverting would
    /// throw *their* work away. Nothing is written in that case.
    pub fn revert(&self) -> Result<Vec<String>> {
        self.write_side(|staged| &staged.content, |staged| &staged.original)
    }

    /// Write one side of every staged file, having checked the other is intact.
    ///
    /// `expected` is what the working tree must currently hold; `wanted` is what
    /// it should hold afterwards. Every path is checked *before* any is written,
    /// so a change set is all-or-nothing — a half-applied one is the single
    /// worst outcome available here, worse than either direction failing.
    fn write_side(
        &self,
        expected: fn(&Staged) -> &Option<String>,
        wanted: fn(&Staged) -> &Option<String>,
    ) -> Result<Vec<String>> {
        for (path, staged) in &self.staged {
            let current = self.on_disk(path).unwrap_or(None);
            if &current != expected(staged) {
                return Err(WorkspaceError::Stale(path.clone()));
            }
        }

        let mut written = Vec::new();
        for (path, staged) in &self.staged {
            if wanted(staged) == expected(staged) {
                continue;
            }
            let target = self.resolve(path)?;
            match wanted(staged) {
                Some(content) => {
                    if let Some(parent) = target.parent() {
                        std::fs::create_dir_all(parent).map_err(|err| WorkspaceError::Io {
                            path: path.clone(),
                            message: err.to_string(),
                        })?;
                    }
                    std::fs::write(&target, content).map_err(|err| WorkspaceError::Io {
                        path: path.clone(),
                        message: err.to_string(),
                    })?;
                }
                None => {
                    std::fs::remove_file(&target).map_err(|err| WorkspaceError::Io {
                        path: path.clone(),
                        message: err.to_string(),
                    })?;
                }
            }
            written.push(path.clone());
        }
        Ok(written)
    }

    /// Bytes this overlay would occupy if serialised: both sides of every file.
    ///
    /// The caller stores this in a database row, so it is the caller's business
    /// how big it is allowed to get.
    pub fn staged_bytes(&self) -> usize {
        self.staged
            .values()
            .map(|staged| {
                staged.original.as_ref().map_or(0, String::len)
                    + staged.content.as_ref().map_or(0, String::len)
            })
            .sum()
    }

    /// Files under `relative`, repo-relative, respecting `.gitignore`.
    ///
    /// The same walker the retrieval stage uses, for the same reason: an agent
    /// that can see `target/` and `node_modules/` will read them, and reading
    /// them is what a context budget is for.
    pub fn list(&self, relative: Option<&str>, limit: usize) -> Result<Vec<String>> {
        let start = match relative.filter(|path| !path.is_empty() && *path != ".") {
            Some(path) => self.resolve(path)?,
            None => self.root.clone(),
        };
        if !start.exists() {
            return Err(WorkspaceError::NotFound(relative.unwrap_or(".").to_owned()));
        }

        let mut out = Vec::new();
        for entry in ignore::WalkBuilder::new(&start)
            .hidden(false)
            .git_ignore(true)
            // Without this the walker only applies `.gitignore` inside a real
            // git repository — so a worktree, a fresh `cargo new`, or a test
            // fixture silently hands the agent `target/` and `node_modules/`.
            .require_git(false)
            .build()
            .flatten()
        {
            if !entry.file_type().is_some_and(|kind| kind.is_file()) {
                continue;
            }
            if let Ok(rel) = entry.path().strip_prefix(&self.root) {
                let display = rel.to_string_lossy().replace('\\', "/");
                if display.starts_with(".git/") {
                    continue;
                }
                out.push(display);
            }
            if out.len() >= limit {
                break;
            }
        }
        out.sort();
        Ok(out)
    }

    /// Literal, case-insensitive substring search. Returns `path:line: text`.
    ///
    /// Not a regex engine: the agent asks for identifiers, and a bad regex from
    /// a model is a tool error it then has to spend a turn recovering from.
    pub fn search(&self, query: &str, relative: Option<&str>, limit: usize) -> Result<Vec<String>> {
        let needle = query.to_lowercase();
        if needle.is_empty() {
            return Ok(Vec::new());
        }

        let mut hits = Vec::new();
        for path in self.list(relative, 20_000)? {
            // Staged content, so a search after an edit sees the edit.
            let Ok(text) = self.read(&path) else { continue };
            for (index, line) in text.lines().enumerate() {
                if line.to_lowercase().contains(&needle) {
                    hits.push(format!("{path}:{}: {}", index + 1, line.trim_end()));
                    if hits.len() >= limit {
                        return Ok(hits);
                    }
                }
            }
        }
        Ok(hits)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TempRepo(PathBuf);

    impl TempRepo {
        fn new(name: &str) -> Self {
            let dir = std::env::temp_dir().join(format!(
                "forge-agent-{name}-{}",
                std::process::id() as u64 + name.len() as u64
            ));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }

        fn write(&self, relative: &str, content: &str) {
            let path = self.0.join(relative);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, content).unwrap();
        }

        fn read(&self, relative: &str) -> String {
            std::fs::read_to_string(self.0.join(relative)).unwrap()
        }

        fn workspace(&self) -> Workspace {
            Workspace::open(&self.0).unwrap()
        }
    }

    impl Drop for TempRepo {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn an_edit_is_staged_and_the_working_tree_is_untouched() {
        let repo = TempRepo::new("stage");
        repo.write("src/main.rs", "fn main() {\n    old();\n}\n");

        let mut workspace = repo.workspace();
        workspace
            .stage_edit("src/main.rs", "old()", "new()")
            .unwrap();

        assert_eq!(repo.read("src/main.rs"), "fn main() {\n    old();\n}\n");
        assert!(workspace.read("src/main.rs").unwrap().contains("new()"));
        assert_eq!(workspace.changes().files.len(), 1);
    }

    #[test]
    fn applying_writes_what_was_staged() {
        let repo = TempRepo::new("apply");
        repo.write("a.txt", "before\n");

        let mut workspace = repo.workspace();
        workspace.stage_write("a.txt", "after\n").unwrap();
        assert_eq!(workspace.apply().unwrap(), vec!["a.txt".to_owned()]);
        assert_eq!(repo.read("a.txt"), "after\n");
    }

    #[test]
    fn applying_creates_parent_directories_for_a_new_file() {
        let repo = TempRepo::new("mkdir");
        let mut workspace = repo.workspace();
        workspace
            .stage_write("src/deep/nested.rs", "fn x() {}\n")
            .unwrap();
        workspace.apply().unwrap();
        assert_eq!(repo.read("src/deep/nested.rs"), "fn x() {}\n");
    }

    #[test]
    fn a_file_edited_back_to_its_original_is_not_a_change() {
        let repo = TempRepo::new("noop");
        repo.write("a.txt", "same\n");

        let mut workspace = repo.workspace();
        workspace.stage_write("a.txt", "different\n").unwrap();
        workspace.stage_write("a.txt", "same\n").unwrap();
        assert!(workspace.changes().is_empty());
    }

    #[test]
    fn two_edits_to_one_file_diff_against_the_original_not_each_other() {
        let repo = TempRepo::new("twice");
        repo.write("a.txt", "one\ntwo\nthree\n");

        let mut workspace = repo.workspace();
        workspace.stage_edit("a.txt", "one", "ONE").unwrap();
        workspace.stage_edit("a.txt", "three", "THREE").unwrap();

        let changes = workspace.changes();
        assert_eq!(changes.files.len(), 1);
        assert_eq!(changes.added(), 2, "both edits must appear in the diff");
    }

    #[test]
    fn an_absolute_path_is_refused() {
        let repo = TempRepo::new("abs");
        let workspace = repo.workspace();
        assert!(matches!(
            workspace.resolve("/etc/passwd"),
            Err(WorkspaceError::Escapes(_))
        ));
    }

    #[test]
    fn a_parent_component_is_refused_even_when_it_would_stay_inside() {
        let repo = TempRepo::new("dotdot");
        let workspace = repo.workspace();
        // `src/../a.txt` stays in the repo, but allowing any `..` at all means
        // the reader has to simulate path arithmetic to audit the rule.
        assert!(matches!(
            workspace.resolve("src/../a.txt"),
            Err(WorkspaceError::Escapes(_))
        ));
        assert!(matches!(
            workspace.resolve("../outside.txt"),
            Err(WorkspaceError::Escapes(_))
        ));
    }

    #[test]
    fn an_edit_that_matches_twice_is_refused() {
        let repo = TempRepo::new("ambiguous");
        repo.write("a.txt", "x = 1\ny = 1\n");

        let mut workspace = repo.workspace();
        match workspace.stage_edit("a.txt", "= 1", "= 2") {
            Err(WorkspaceError::NoUniqueMatch { matches, .. }) => assert_eq!(matches, 2),
            other => panic!("expected an ambiguity error, got {other:?}"),
        }
        assert!(workspace.changes().is_empty());
    }

    #[test]
    fn an_edit_that_matches_nothing_is_refused() {
        let repo = TempRepo::new("missing-match");
        repo.write("a.txt", "hello\n");

        let mut workspace = repo.workspace();
        match workspace.stage_edit("a.txt", "goodbye", "hi") {
            Err(WorkspaceError::NoUniqueMatch { matches, .. }) => assert_eq!(matches, 0),
            other => panic!("expected a no-match error, got {other:?}"),
        }
    }

    #[test]
    fn reverting_puts_back_exactly_what_was_there() {
        let repo = TempRepo::new("revert");
        repo.write("a.txt", "before\n");

        let mut workspace = repo.workspace();
        workspace.stage_write("a.txt", "after\n").unwrap();
        workspace.apply().unwrap();
        assert_eq!(repo.read("a.txt"), "after\n");

        assert_eq!(workspace.revert().unwrap(), vec!["a.txt".to_owned()]);
        assert_eq!(repo.read("a.txt"), "before\n");
    }

    #[test]
    fn reverting_a_created_file_removes_it_again() {
        let repo = TempRepo::new("revert-new");
        let mut workspace = repo.workspace();
        workspace.stage_write("new.txt", "hello\n").unwrap();
        workspace.apply().unwrap();
        assert!(repo.0.join("new.txt").exists());

        workspace.revert().unwrap();
        assert!(
            !repo.0.join("new.txt").exists(),
            "reverting left the file the task created"
        );
    }

    #[test]
    fn reverting_a_deletion_brings_the_file_back() {
        let repo = TempRepo::new("revert-delete");
        repo.write("gone.txt", "content\n");

        let mut workspace = repo.workspace();
        workspace.stage_delete("gone.txt").unwrap();
        workspace.apply().unwrap();
        assert!(!repo.0.join("gone.txt").exists());

        workspace.revert().unwrap();
        assert_eq!(repo.read("gone.txt"), "content\n");
    }

    #[test]
    fn reverting_refuses_when_somebody_edited_the_file_afterwards() {
        // The mirror of the stale check on `apply`, and just as important:
        // reverting over a human's later edit would throw *their* work away.
        let repo = TempRepo::new("revert-stale");
        repo.write("a.txt", "before\n");

        let mut workspace = repo.workspace();
        workspace.stage_write("a.txt", "after\n").unwrap();
        workspace.apply().unwrap();

        repo.write("a.txt", "a human improved this\n");
        assert!(matches!(workspace.revert(), Err(WorkspaceError::Stale(_))));
        assert_eq!(repo.read("a.txt"), "a human improved this\n");
    }

    #[test]
    fn apply_and_revert_round_trip_a_multi_file_change_set() {
        let repo = TempRepo::new("revert-many");
        repo.write("keep.txt", "one\n");
        repo.write("edit.txt", "two\n");
        repo.write("drop.txt", "three\n");

        let mut workspace = repo.workspace();
        workspace.stage_edit("edit.txt", "two", "TWO").unwrap();
        workspace.stage_delete("drop.txt").unwrap();
        workspace.stage_write("add.txt", "four\n").unwrap();

        workspace.apply().unwrap();
        workspace.revert().unwrap();

        assert_eq!(repo.read("keep.txt"), "one\n");
        assert_eq!(repo.read("edit.txt"), "two\n");
        assert_eq!(repo.read("drop.txt"), "three\n");
        assert!(!repo.0.join("add.txt").exists());
    }

    #[test]
    fn staged_bytes_counts_both_sides_of_every_file() {
        let repo = TempRepo::new("bytes");
        repo.write("a.txt", "12345");

        let mut workspace = repo.workspace();
        assert_eq!(workspace.staged_bytes(), 0);

        workspace.stage_write("a.txt", "678").unwrap();
        // 5 bytes of original plus 3 of proposed content.
        assert_eq!(workspace.staged_bytes(), 8);
    }

    #[test]
    fn applying_refuses_when_the_file_moved_underneath_the_task() {
        let repo = TempRepo::new("stale");
        repo.write("a.txt", "original\n");

        let mut workspace = repo.workspace();
        workspace.stage_edit("a.txt", "original", "agent").unwrap();

        // Somebody else edits the file while the review card sits on a phone.
        repo.write("a.txt", "human was here\n");

        assert!(matches!(workspace.apply(), Err(WorkspaceError::Stale(_))));
        assert_eq!(repo.read("a.txt"), "human was here\n");
    }

    #[test]
    fn a_deletion_stages_and_applies() {
        let repo = TempRepo::new("delete");
        repo.write("gone.txt", "bye\n");

        let mut workspace = repo.workspace();
        workspace.stage_delete("gone.txt").unwrap();
        assert_eq!(workspace.changes().files[0].kind, ChangeKind::Deleted);

        workspace.apply().unwrap();
        assert!(!repo.0.join("gone.txt").exists());
    }

    #[test]
    fn listing_skips_gitignored_files() {
        let repo = TempRepo::new("ignore");
        repo.write(".gitignore", "target/\n");
        repo.write("src/main.rs", "fn main() {}\n");
        repo.write("target/debug/huge.bin", "junk\n");

        let listed = repo.workspace().list(None, 100).unwrap();
        assert!(listed.contains(&"src/main.rs".to_owned()));
        assert!(
            !listed.iter().any(|path| path.starts_with("target/")),
            "gitignored paths leaked into the listing: {listed:?}"
        );
    }

    #[test]
    fn search_sees_staged_edits_not_just_the_working_tree() {
        let repo = TempRepo::new("search");
        repo.write("src/a.rs", "let needle = 1;\n");

        let mut workspace = repo.workspace();
        assert_eq!(workspace.search("needle", None, 10).unwrap().len(), 1);

        workspace
            .stage_edit("src/a.rs", "needle", "haystack")
            .unwrap();
        assert!(workspace.search("needle", None, 10).unwrap().is_empty());
        assert_eq!(workspace.search("haystack", None, 10).unwrap().len(), 1);
    }

    #[test]
    fn an_oversized_file_is_refused_rather_than_loaded() {
        let repo = TempRepo::new("huge");
        repo.write("big.txt", &"x".repeat(MAX_FILE_BYTES as usize + 1));

        let workspace = repo.workspace();
        assert!(matches!(
            workspace.read("big.txt"),
            Err(WorkspaceError::TooLarge { .. })
        ));
    }

    #[test]
    fn a_binary_file_is_refused_rather_than_mangled() {
        let repo = TempRepo::new("binary");
        std::fs::write(repo.0.join("logo.png"), [0x89, b'P', 0xff, 0xfe]).unwrap();

        let workspace = repo.workspace();
        assert!(matches!(
            workspace.read("logo.png"),
            Err(WorkspaceError::Binary(_))
        ));
    }

    #[test]
    fn a_staged_workspace_round_trips_through_json() {
        // A task awaiting review has to survive a runner restart.
        let repo = TempRepo::new("persist");
        repo.write("a.txt", "before\n");

        let mut workspace = repo.workspace();
        workspace.stage_write("a.txt", "after\n").unwrap();

        let json = serde_json::to_string(&workspace).unwrap();
        let restored: Workspace = serde_json::from_str(&json).unwrap();
        assert_eq!(restored.changes(), workspace.changes());
        restored.apply().unwrap();
        assert_eq!(repo.read("a.txt"), "after\n");
    }
}
