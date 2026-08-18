//! The files a task can see and change, inside its own checkout.
//!
//! This used to be a staging overlay: every write the agent made was held in
//! memory and flushed to the working tree only once somebody approved. That got
//! the review property right — nothing reaches your files until you say yes —
//! and paid for it three times over. [`crate::git`] has the full account; the
//! expensive one was that the `run` tool executed against a working tree which
//! by construction did not contain the agent's own edits, so an agent could not
//! test its own work.
//!
//! Isolation now comes from [`crate::git::Worktree`]: the task gets its own
//! branch and its own checkout, so writing a file is just writing a file. What
//! is left here is the part that was never about staging — resolving a path
//! safely, reading, listing and searching — with the write methods doing what
//! they say.
//!
//! ## The invariant that survived
//!
//! **Nothing escapes the root.** Paths are resolved lexically — no `..`
//! component survives — and every path that resolves to an existing file is
//! re-checked after canonicalisation, which is what catches a symlink pointing
//! at `/etc`. That mattered when the root was your repository and it matters
//! just as much now that it is a checkout: an agent that can write through a
//! symlink is not sandboxed by having its own branch.

use std::path::{Component, Path, PathBuf};

/// Refuse to read or write anything larger than this. A source file is
/// kilobytes; a megabyte means a lockfile, a vendored bundle, or a mistake, and
/// none of the three belong in a prompt or on a review card.
pub const MAX_FILE_BYTES: u64 = 512 * 1024;

#[derive(Debug)]
pub enum WorkspaceError {
    /// The path left the root, or tried to.
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
            WorkspaceError::Io { path, message } => write!(f, "{path}: {message}"),
        }
    }
}

impl std::error::Error for WorkspaceError {}

type Result<T> = std::result::Result<T, WorkspaceError>;

/// A directory tree the agent may read and write, and nothing outside it.
///
/// Not serialisable, and deliberately so. When this held staged edits it had to
/// survive a runner restart, because the edits existed nowhere else. They are
/// now committed to a branch, so there is nothing here worth writing down — a
/// `Workspace` is reconstructed from a path whenever one is needed.
#[derive(Debug, Clone)]
pub struct Workspace {
    root: PathBuf,
}

impl Workspace {
    /// Open a root. Canonicalised once here so every later containment check
    /// compares against a real path rather than whatever the caller typed.
    pub fn open(root: impl AsRef<Path>) -> Result<Self> {
        let root = root.as_ref();
        let canonical = root.canonicalize().map_err(|err| WorkspaceError::Io {
            path: root.display().to_string(),
            message: err.to_string(),
        })?;
        Ok(Self { root: canonical })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Resolve a root-relative path to an absolute one inside the root.
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

    /// Normalise a path for display and lookup: forward slashes, no `./`.
    fn key(&self, relative: &str) -> String {
        relative.trim_start_matches("./").replace('\\', "/")
    }

    /// Read a file's content. `None` when it does not exist.
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

    /// What the agent sees if it reads this file.
    ///
    /// Under the overlay this had to consult the staged map first, so that an
    /// agent reading back its own edit saw the edit rather than the original.
    /// Writes land on disk now, so reading from disk *is* reading its own work.
    pub fn read(&self, relative: &str) -> Result<String> {
        let key = self.key(relative);
        self.on_disk(&key)?.ok_or(WorkspaceError::NotFound(key))
    }

    pub fn exists(&self, relative: &str) -> bool {
        let key = self.key(relative);
        self.resolve(&key)
            .map(|path| path.is_file())
            .unwrap_or(false)
    }

    /// Write a whole file, creating it and any missing parents.
    pub fn write(&mut self, relative: &str, content: impl Into<String>) -> Result<()> {
        let key = self.key(relative);
        let target = self.resolve(&key)?;
        let content = content.into();
        if content.len() as u64 > MAX_FILE_BYTES {
            return Err(WorkspaceError::TooLarge {
                path: key,
                bytes: content.len() as u64,
            });
        }

        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent).map_err(|err| WorkspaceError::Io {
                path: key.clone(),
                message: err.to_string(),
            })?;
        }
        std::fs::write(&target, content).map_err(|err| WorkspaceError::Io {
            path: key,
            message: err.to_string(),
        })
    }

    /// Apply a single exact replacement.
    ///
    /// Uniqueness is required, like every editing tool that has learned the
    /// lesson: an `old_string` that matches twice means the model was thinking
    /// about one of them and would have silently changed the other.
    pub fn edit(&mut self, relative: &str, old: &str, new: &str) -> Result<()> {
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
        self.write(&key, updated)
    }

    /// Delete a file.
    pub fn delete(&mut self, relative: &str) -> Result<()> {
        let key = self.key(relative);
        if !self.exists(&key) {
            return Err(WorkspaceError::NotFound(key));
        }
        let target = self.resolve(&key)?;
        std::fs::remove_file(&target).map_err(|err| WorkspaceError::Io {
            path: key,
            message: err.to_string(),
        })
    }

    /// Files under `relative`, root-relative, respecting `.gitignore`.
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
                if display.starts_with(".git/") || display == ".git" {
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
    fn an_edit_lands_on_disk_so_the_agent_can_test_it() {
        // The whole reason the overlay was replaced. Under staging this
        // assertion was the opposite — the working tree was untouched, and a
        // `cargo test` in the next step read the unedited file.
        let repo = TempRepo::new("writes");
        repo.write("a.txt", "one\n");

        let mut workspace = repo.workspace();
        workspace.write("a.txt", "two\n").unwrap();

        assert_eq!(repo.read("a.txt"), "two\n");
        assert_eq!(workspace.read("a.txt").unwrap(), "two\n");
    }

    #[test]
    fn writing_creates_parent_directories_for_a_new_file() {
        let repo = TempRepo::new("parents");
        let mut workspace = repo.workspace();
        workspace
            .write("src/deep/new.rs", "fn main() {}\n")
            .unwrap();
        assert_eq!(repo.read("src/deep/new.rs"), "fn main() {}\n");
    }

    #[test]
    fn two_edits_to_one_file_compose() {
        // Under the overlay each edit re-diffed against the original. Now the
        // second edit reads what the first one wrote, which is what makes a
        // sequence of edits behave the way the model expects.
        let repo = TempRepo::new("compose");
        repo.write("a.txt", "one two three\n");

        let mut workspace = repo.workspace();
        workspace.edit("a.txt", "one", "1").unwrap();
        workspace.edit("a.txt", "three", "3").unwrap();

        assert_eq!(repo.read("a.txt"), "1 two 3\n");
    }

    #[test]
    fn an_absolute_path_is_refused() {
        let repo = TempRepo::new("absolute");
        let mut workspace = repo.workspace();
        assert!(matches!(
            workspace.write("/etc/passwd", "nope"),
            Err(WorkspaceError::Escapes(_))
        ));
        assert!(matches!(
            workspace.read("/etc/passwd"),
            Err(WorkspaceError::Escapes(_))
        ));
    }

    #[test]
    fn a_parent_component_is_refused_even_when_it_would_stay_inside() {
        // `src/../a.txt` resolves inside the root, and is still refused: the
        // rule is "no parent components", because that is the rule a reader can
        // check by eye and a resolver cannot get subtly wrong.
        let repo = TempRepo::new("parent");
        repo.write("a.txt", "one\n");
        let mut workspace = repo.workspace();

        assert!(matches!(
            workspace.write("src/../a.txt", "two"),
            Err(WorkspaceError::Escapes(_))
        ));
        assert!(matches!(
            workspace.write("../outside.txt", "two"),
            Err(WorkspaceError::Escapes(_))
        ));
        assert_eq!(
            repo.read("a.txt"),
            "one\n",
            "nothing should have been written"
        );
    }

    #[test]
    fn a_symlink_pointing_out_of_the_root_is_refused() {
        // The case the lexical check cannot see. Having its own branch does not
        // sandbox an agent that can write through a symlink.
        #[cfg(unix)]
        {
            let repo = TempRepo::new("symlink");
            let outside = std::env::temp_dir().join("forge-agent-symlink-target");
            std::fs::write(&outside, "secret\n").unwrap();
            std::os::unix::fs::symlink(&outside, repo.0.join("link.txt")).unwrap();

            let mut workspace = repo.workspace();
            assert!(matches!(
                workspace.write("link.txt", "clobbered"),
                Err(WorkspaceError::Escapes(_))
            ));
            assert_eq!(std::fs::read_to_string(&outside).unwrap(), "secret\n");
            let _ = std::fs::remove_file(&outside);
        }
    }

    #[test]
    fn an_edit_that_matches_twice_is_refused() {
        let repo = TempRepo::new("twice");
        repo.write("a.txt", "x\nx\n");
        let mut workspace = repo.workspace();

        assert!(matches!(
            workspace.edit("a.txt", "x", "y"),
            Err(WorkspaceError::NoUniqueMatch { matches: 2, .. })
        ));
        assert_eq!(
            repo.read("a.txt"),
            "x\nx\n",
            "a refused edit writes nothing"
        );
    }

    #[test]
    fn an_edit_that_matches_nothing_is_refused() {
        let repo = TempRepo::new("nomatch");
        repo.write("a.txt", "one\n");
        let mut workspace = repo.workspace();

        assert!(matches!(
            workspace.edit("a.txt", "absent", "y"),
            Err(WorkspaceError::NoUniqueMatch { matches: 0, .. })
        ));
        assert_eq!(repo.read("a.txt"), "one\n");
    }

    #[test]
    fn deleting_removes_the_file_and_deleting_it_twice_is_an_error() {
        let repo = TempRepo::new("delete");
        repo.write("a.txt", "one\n");
        let mut workspace = repo.workspace();

        workspace.delete("a.txt").unwrap();
        assert!(!repo.0.join("a.txt").exists());
        assert!(matches!(
            workspace.delete("a.txt"),
            Err(WorkspaceError::NotFound(_))
        ));
    }

    #[test]
    fn listing_skips_gitignored_files() {
        let repo = TempRepo::new("ignored");
        repo.write(".gitignore", "target/\n");
        repo.write("src/main.rs", "fn main() {}\n");
        repo.write("target/debug/huge.bin", "junk\n");

        let listed = repo.workspace().list(None, 100).unwrap();
        assert!(listed.contains(&"src/main.rs".to_owned()));
        assert!(
            !listed.iter().any(|path| path.starts_with("target/")),
            "listed: {listed:?}"
        );
    }

    #[test]
    fn search_sees_edits_not_just_what_was_committed() {
        let repo = TempRepo::new("search");
        repo.write("a.txt", "nothing here\n");

        let mut workspace = repo.workspace();
        workspace.write("a.txt", "needle here\n").unwrap();

        let hits = workspace.search("needle", None, 10).unwrap();
        assert_eq!(hits, vec!["a.txt:1: needle here".to_owned()]);
    }

    #[test]
    fn an_oversized_file_is_refused_rather_than_loaded() {
        let repo = TempRepo::new("huge");
        repo.write("big.txt", &"x".repeat(MAX_FILE_BYTES as usize + 1));

        assert!(matches!(
            repo.workspace().read("big.txt"),
            Err(WorkspaceError::TooLarge { .. })
        ));
    }

    #[test]
    fn an_oversized_write_is_refused_rather_than_stored() {
        let repo = TempRepo::new("hugewrite");
        let mut workspace = repo.workspace();

        assert!(matches!(
            workspace.write("big.txt", "x".repeat(MAX_FILE_BYTES as usize + 1)),
            Err(WorkspaceError::TooLarge { .. })
        ));
        assert!(!repo.0.join("big.txt").exists());
    }

    #[test]
    fn a_binary_file_is_refused_rather_than_mangled() {
        let repo = TempRepo::new("binary");
        std::fs::write(repo.0.join("blob.bin"), [0xff, 0xfe, 0x00]).unwrap();

        assert!(matches!(
            repo.workspace().read("blob.bin"),
            Err(WorkspaceError::Binary(_))
        ));
    }
}
