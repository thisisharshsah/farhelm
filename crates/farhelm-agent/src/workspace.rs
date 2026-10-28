//! The files a task can see and change, inside its own checkout.
//!
//! This used to be a staging overlay: every write the agent made was held in
//! memory and flushed to the working tree only once somebody approved. That got
//! the review property right (nothing reaches your files until you say yes)
//! and paid for it three times over. [`crate::git`] has the full account; the
//! expensive one was that the `run` tool executed against a working tree which
//! by construction did not contain the agent's own edits, so an agent could not
//! test its own work.
//!
//! Isolation now comes from [`crate::git::Worktree`]: the task gets its own
//! branch and its own checkout, so writing a file is just writing a file. What
//! is left here is the part that was never about staging: resolving a path
//! safely, reading, listing and searching, with the write methods doing what
//! they say.
//!
//! ## The invariant that survived
//!
//! File access is relative to an open directory capability, never an absolute
//! path checked earlier. Every component is opened without following symlinks,
//! including missing-file parents and the final file. Replacing a checked path
//! with a symlink therefore cannot redirect an operation outside the checkout.
//! This deliberately rejects internal symlinks too. Capabilities continue to
//! refer to an opened directory if it is renamed; hard links and mount points
//! are not isolated by this boundary. Commands and hostile concurrent host
//! processes still need the runner's separate execution/trust policy.

use std::ffi::OsStr;
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

use cap_fs_ext::{DirExt, FollowSymlinks, OpenOptionsFollowExt, OpenOptionsSyncExt};
use cap_std::fs::{Dir, OpenOptions};
use ignore::gitignore::{Gitignore, GitignoreBuilder};

/// Refuse to read or write anything larger than this. A source file is
/// kilobytes; a megabyte means a lockfile, a vendored bundle, or a mistake, and
/// none of the three belong in a prompt or on a review card.
pub const MAX_FILE_BYTES: u64 = 512 * 1024;

/// Bound input traversal and recursive listing on small runtime worker stacks.
pub const MAX_PATH_COMPONENTS: usize = 128;

#[derive(Debug)]
pub enum WorkspaceError {
    /// The path left the root, or tried to.
    Escapes(String),
    NotFound(String),
    TooLarge {
        path: String,
        bytes: u64,
    },
    TooDeep(String),
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
            WorkspaceError::TooDeep(path) => {
                write!(
                    f,
                    "{path} exceeds the {MAX_PATH_COMPONENTS}-component path depth limit"
                )
            }
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

fn io_error(path: &str, err: std::io::Error) -> WorkspaceError {
    if err.kind() == std::io::ErrorKind::NotFound {
        WorkspaceError::NotFound(path.to_owned())
    } else {
        WorkspaceError::Io {
            path: path.to_owned(),
            message: err.to_string(),
        }
    }
}

fn read_file(directory: &Dir, name: &OsStr, display: &str) -> Result<String> {
    Workspace::reject_symlink(directory, name, display)?;
    let file = directory
        .open_with(
            name,
            OpenOptions::new()
                .read(true)
                .follow(FollowSymlinks::No)
                .nonblock(true),
        )
        .map_err(|err| io_error(display, err))?;
    // Inspect and read the same handle. A pathname metadata check followed by
    // a separate open would reintroduce the replacement race.
    let metadata = file.metadata().map_err(|err| io_error(display, err))?;
    if !metadata.is_file() {
        return Err(WorkspaceError::Io {
            path: display.to_owned(),
            message: "is not a regular file".into(),
        });
    }
    if metadata.len() > MAX_FILE_BYTES {
        return Err(WorkspaceError::TooLarge {
            path: display.to_owned(),
            bytes: metadata.len(),
        });
    }
    let mut bytes = Vec::new();
    file.take(MAX_FILE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|err| io_error(display, err))?;
    // The file may grow after metadata was read, so enforce the cap while reading.
    if bytes.len() as u64 > MAX_FILE_BYTES {
        return Err(WorkspaceError::TooLarge {
            path: display.to_owned(),
            bytes: bytes.len() as u64,
        });
    }
    String::from_utf8(bytes).map_err(|_| WorkspaceError::Binary(display.to_owned()))
}

#[derive(Clone, Default)]
struct IgnoreRules {
    ignore: Vec<Gitignore>,
    gitignore: Vec<Gitignore>,
    git_exclude: Vec<Gitignore>,
}

impl IgnoreRules {
    fn is_ignored(&self, path: &Path, is_directory: bool) -> bool {
        // File type precedence is stronger than directory depth: an ancestor
        // .ignore must override even a more deeply nested .gitignore. Within
        // each type, the nearest file and its last matching pattern win.
        self.ignore
            .iter()
            .rev()
            .chain(self.gitignore.iter().rev())
            .chain(self.git_exclude.iter().rev())
            .find_map(|rule| {
                let matched = rule.matched(path, is_directory);
                (!matched.is_none()).then_some(matched.is_ignore())
            })
            .unwrap_or(false)
    }
}

/// An opened directory capability used for the agent's file tools.
///
/// Not serialisable, and deliberately so. When this held staged edits it had to
/// survive a runner restart, because the edits existed nowhere else. They are
/// now committed to a branch, so there is nothing here worth writing down; a
/// `Workspace` is reconstructed from a path whenever one is needed.
#[derive(Debug, Clone)]
pub struct Workspace {
    root: PathBuf,
    directory: Arc<Dir>,
    git_exclude: Option<Gitignore>,
}

impl Workspace {
    /// Acquire the workspace capability once. The path is retained for command
    /// execution and display; file tools use the open handle even if it moves.
    pub fn open(root: impl AsRef<Path>) -> Result<Self> {
        let root = root.as_ref();
        let canonical = root.canonicalize().map_err(|err| WorkspaceError::Io {
            path: root.display().to_string(),
            message: err.to_string(),
        })?;
        let directory = Dir::open_ambient_dir(&canonical, cap_std::ambient_authority())
            .map_err(|err| io_error(&root.display().to_string(), err))?;
        Ok(Self {
            root: canonical,
            directory: Arc::new(directory),
            git_exclude: None,
        })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// A lexically checked absolute path for display, not for filesystem access.
    ///
    /// Containment is enforced by the handle-relative operations below. No path
    /// returned by an earlier check can authorize a later ambient filesystem call.
    pub fn resolve(&self, relative: &str) -> Result<PathBuf> {
        let path = self.relative_path(relative)?;
        let mut directory = Arc::clone(&self.directory);
        let mut components = path.components().peekable();
        while let Some(component) = components.next() {
            let name = component.as_os_str();
            match directory.symlink_metadata(name) {
                Ok(metadata) if metadata.file_type().is_symlink() => {
                    return Err(WorkspaceError::Escapes(relative.to_owned()));
                }
                Ok(_) => {}
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => break,
                Err(err) => return Err(io_error(relative, err)),
            }
            if components.peek().is_some() {
                directory = Arc::new(
                    directory
                        .open_dir_nofollow(name)
                        .map_err(|err| io_error(relative, err))?,
                );
            }
        }
        Ok(self.root.join(path))
    }

    fn relative_path(&self, relative: &str) -> Result<PathBuf> {
        let candidate = Path::new(relative);
        if candidate.is_absolute() {
            return Err(WorkspaceError::Escapes(relative.to_owned()));
        }

        let mut out = PathBuf::new();
        let mut depth = 0;
        for component in candidate.components() {
            match component {
                Component::Normal(part) => {
                    depth += 1;
                    if depth > MAX_PATH_COMPONENTS {
                        return Err(WorkspaceError::TooDeep(relative.to_owned()));
                    }
                    out.push(part);
                }
                Component::CurDir => {}
                Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                    return Err(WorkspaceError::Escapes(relative.to_owned()));
                }
            }
        }

        Ok(out)
    }

    fn reject_symlink(directory: &Dir, name: &OsStr, display: &str) -> Result<()> {
        match directory.symlink_metadata(name) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                Err(WorkspaceError::Escapes(display.to_owned()))
            }
            Ok(_) => Ok(()),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(err) => Err(io_error(display, err)),
        }
    }

    /// Each descent is relative to the preceding open directory. The metadata
    /// check provides a useful error; `open_dir_nofollow` is what closes the race.
    fn directory(&self, path: &Path, create: bool, display: &str) -> Result<Arc<Dir>> {
        let mut directory = Arc::clone(&self.directory);
        for component in path.components() {
            let Component::Normal(name) = component else {
                continue;
            };
            Self::reject_symlink(&directory, name, display)?;
            let opened = match directory.open_dir_nofollow(name) {
                Err(err) if create && err.kind() == std::io::ErrorKind::NotFound => {
                    match directory.create_dir(name) {
                        Ok(()) => {}
                        Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {}
                        Err(err) => return Err(io_error(display, err)),
                    }
                    directory.open_dir_nofollow(name)
                }
                result => result,
            };
            directory = Arc::new(opened.map_err(|err| io_error(display, err))?);
        }
        Ok(directory)
    }

    fn parent(&self, path: &Path, create: bool, display: &str) -> Result<Arc<Dir>> {
        self.directory(path.parent().unwrap_or(Path::new("")), create, display)
    }

    fn file_name<'a>(&self, path: &'a Path, display: &str) -> Result<&'a OsStr> {
        path.file_name().ok_or_else(|| WorkspaceError::Io {
            path: display.to_owned(),
            message: "is a directory".into(),
        })
    }

    /// Normalise a path for display and lookup: forward slashes, no `./`.
    fn key(&self, relative: &str) -> String {
        relative.trim_start_matches("./").replace('\\', "/")
    }

    /// Read a file's content. `None` when it does not exist.
    fn on_disk(&self, relative: &str) -> Result<Option<String>> {
        let path = self.relative_path(relative)?;
        let directory = match self.parent(&path, false, relative) {
            Ok(directory) => directory,
            Err(WorkspaceError::NotFound(_)) => return Ok(None),
            Err(err) => return Err(err),
        };
        let name = self.file_name(&path, relative)?;
        match read_file(&directory, name, relative) {
            Ok(text) => Ok(Some(text)),
            Err(WorkspaceError::NotFound(_)) => Ok(None),
            Err(err) => Err(err),
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
        let Ok(path) = self.relative_path(&key) else {
            return false;
        };
        let Ok(directory) = self.parent(&path, false, &key) else {
            return false;
        };
        let Ok(name) = self.file_name(&path, &key) else {
            return false;
        };
        directory
            .symlink_metadata(name)
            .is_ok_and(|metadata| metadata.is_file())
    }

    /// Snapshot in-root Git excludes without resolving a worktree's external
    /// .git pointer. Missing, oversized or symlinked metadata is not consulted.
    pub fn git_exclude(&self) -> Option<String> {
        let info = self
            .directory(Path::new(".git/info"), false, ".git/info")
            .ok()?;
        read_file(&info, OsStr::new("exclude"), ".git/info/exclude").ok()
    }

    /// Carry a trusted source-workspace exclude snapshot into a task worktree.
    /// Patterns are interpreted against this checkout; no external path opens.
    pub fn set_git_exclude(&mut self, content: &str) -> Result<()> {
        if content.len() as u64 > MAX_FILE_BYTES {
            return Err(WorkspaceError::TooLarge {
                path: ".git/info/exclude".into(),
                bytes: content.len() as u64,
            });
        }
        self.git_exclude =
            Self::parse_ignore(content, &self.root, &self.root.join(".git/info/exclude"));
        Ok(())
    }

    /// Write a whole file, creating it and any missing parents.
    pub fn write(&mut self, relative: &str, content: impl Into<String>) -> Result<()> {
        let key = self.key(relative);
        let path = self.relative_path(&key)?;
        let content = content.into();
        if content.len() as u64 > MAX_FILE_BYTES {
            return Err(WorkspaceError::TooLarge {
                path: key,
                bytes: content.len() as u64,
            });
        }

        let directory = self.parent(&path, true, &key)?;
        let name = self.file_name(&path, &key)?;
        Self::reject_symlink(&directory, name, &key)?;
        let mut file = directory
            .open_with(
                name,
                OpenOptions::new()
                    .write(true)
                    .create(true)
                    .follow(FollowSymlinks::No)
                    .nonblock(true),
            )
            .map_err(|err| io_error(&key, err))?;
        // Do not truncate before validating the opened object. Nonblocking
        // opens also avoid waiting forever if the leaf was replaced by a FIFO.
        if !file
            .metadata()
            .map_err(|err| io_error(&key, err))?
            .is_file()
        {
            return Err(WorkspaceError::Io {
                path: key,
                message: "is not a regular file".into(),
            });
        }
        file.set_len(0).map_err(|err| io_error(&key, err))?;
        file.write_all(content.as_bytes())
            .map_err(|err| io_error(&key, err))
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
        let path = self.relative_path(&key)?;
        let directory = self.parent(&path, false, &key)?;
        let name = self.file_name(&path, &key)?;
        Self::reject_symlink(&directory, name, &key)?;
        let metadata = directory
            .symlink_metadata(name)
            .map_err(|err| io_error(&key, err))?;
        if !metadata.is_file() {
            return Err(WorkspaceError::Io {
                path: key,
                message: "is not a regular file".into(),
            });
        }
        // Unlink is relative to the open parent and never follows the final
        // component, even if it was replaced after the metadata check.
        directory
            .remove_file(name)
            .map_err(|err| io_error(&key, err))
    }

    /// Files under `relative`, root-relative, respecting `.gitignore`.
    ///
    /// Traverse directory capabilities without following links. Ignore patterns
    /// are parsed from bounded, handle-relative reads; an ambient path walker
    /// could otherwise read outside the root during a directory replacement.
    pub fn list(&self, relative: Option<&str>, limit: usize) -> Result<Vec<String>> {
        let display = relative.unwrap_or(".");
        let start = self.relative_path(display)?;
        if limit == 0 {
            return Ok(Vec::new());
        }
        if start.components().any(|part| part.as_os_str() == ".git") {
            return Ok(Vec::new());
        }
        if !start.as_os_str().is_empty() {
            let parent = self.parent(&start, false, display)?;
            let name = self.file_name(&start, display)?;
            Self::reject_symlink(&parent, name, display)?;
            if parent
                .symlink_metadata(name)
                .map_err(|err| io_error(display, err))?
                .is_file()
            {
                return Ok(vec![start.to_string_lossy().replace('\\', "/")]);
            }
        }
        let directory = self.directory(&start, false, display)?;
        let mut rules = IgnoreRules::default();
        // Only in-root Git metadata is read. A worktree's .git pointer may
        // refer outside this capability and is deliberately not followed.
        if let Some(matcher) = self.git_exclude.clone().or_else(|| {
            Self::parse_ignore(
                &self.git_exclude()?,
                &self.root,
                &self.root.join(".git/info/exclude"),
            )
        }) {
            rules.git_exclude.push(matcher);
        }
        for ancestor in start
            .ancestors()
            .skip(1)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
        {
            let parent = self.directory(ancestor, false, display)?;
            self.add_ignore_rules(&mut rules, &parent, ancestor);
        }
        let mut out = Vec::new();
        self.list_directory(&directory, &start, &rules, limit, &mut out)?;
        out.sort();
        Ok(out)
    }

    fn add_ignore_rules(&self, rules: &mut IgnoreRules, directory: &Dir, relative: &Path) {
        let root = self.root.join(relative);
        if let Some(matcher) =
            Self::ignore_matcher(directory, ".gitignore", &root, &root.join(".gitignore"))
        {
            rules.gitignore.push(matcher);
        }
        if let Some(matcher) =
            Self::ignore_matcher(directory, ".ignore", &root, &root.join(".ignore"))
        {
            rules.ignore.push(matcher);
        }
    }

    fn ignore_matcher(
        directory: &Dir,
        name: &str,
        root: &Path,
        source: &Path,
    ) -> Option<Gitignore> {
        let text = read_file(directory, OsStr::new(name), &source.to_string_lossy()).ok()?;
        Self::parse_ignore(&text, root, source)
    }

    fn parse_ignore(text: &str, root: &Path, source: &Path) -> Option<Gitignore> {
        let mut builder = GitignoreBuilder::new(root);
        for line in text.lines() {
            // Like ignore's walker, keep usable patterns if another line is malformed.
            let _ = builder.add_line(Some(source.to_owned()), line);
        }
        builder.build().ok()
    }

    fn list_directory(
        &self,
        directory: &Dir,
        relative: &Path,
        inherited: &IgnoreRules,
        limit: usize,
        out: &mut Vec<String>,
    ) -> Result<()> {
        let mut rules = inherited.clone();
        self.add_ignore_rules(&mut rules, directory, relative);
        let entries = directory
            .entries()
            .map_err(|err| io_error(&relative.to_string_lossy(), err))?;
        for entry in entries {
            if out.len() >= limit {
                break;
            }
            let Ok(entry) = entry else { continue };
            let name = entry.file_name();
            if name == ".git" {
                continue;
            }
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            if !kind.is_file() && !kind.is_dir() {
                continue;
            }
            let path = relative.join(&name);
            if rules.is_ignored(&self.root.join(&path), kind.is_dir()) {
                continue;
            }
            if path.components().count() > MAX_PATH_COMPONENTS {
                return Err(WorkspaceError::TooDeep(path.to_string_lossy().into_owned()));
            }
            if kind.is_dir() {
                // If the entry changed into a symlink after file_type(), the
                // no-follow open fails rather than visiting its target.
                let Ok(child) = directory.open_dir_nofollow(&name) else {
                    continue;
                };
                self.list_directory(&child, &path, &rules, limit, out)?;
            } else {
                out.push(path.to_string_lossy().replace('\\', "/"));
            }
        }
        Ok(())
    }

    /// Literal, case-insensitive substring search. Returns `path:line: text`.
    ///
    /// Not a regex engine: the agent asks for identifiers, and a bad regex from
    /// a model is a tool error it then has to spend a turn recovering from.
    pub fn search(&self, query: &str, relative: Option<&str>, limit: usize) -> Result<Vec<String>> {
        let needle = query.to_lowercase();
        if needle.is_empty() || limit == 0 {
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
                "farhelm-agent-{name}-{}",
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
        // assertion was the opposite: the working tree was untouched, and a
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
    fn overly_deep_paths_are_refused_before_creating_directories() {
        let repo = TempRepo::new("path-depth");
        let path = std::iter::repeat_n("d", MAX_PATH_COMPONENTS + 1)
            .collect::<Vec<_>>()
            .join("/");
        let mut workspace = repo.workspace();
        assert!(matches!(
            workspace.write(&path, "refused"),
            Err(WorkspaceError::TooDeep(_))
        ));
        assert!(matches!(
            workspace.list(Some(&path), 100),
            Err(WorkspaceError::TooDeep(_))
        ));
        assert!(!repo.0.join("d").exists());
    }

    #[test]
    fn listing_deep_existing_directories_returns_an_error_on_a_small_stack() {
        let repo = TempRepo::new("list-depth");
        let path = std::iter::repeat_n("d", MAX_PATH_COMPONENTS + 1)
            .collect::<Vec<_>>()
            .join("/");
        std::fs::create_dir_all(repo.0.join(&path)).unwrap();
        let workspace = repo.workspace();
        let result = std::thread::Builder::new()
            .stack_size(2 * 1024 * 1024)
            .spawn(move || workspace.list(None, 100))
            .unwrap()
            .join()
            .expect("listing must not panic on a runtime-sized stack");
        let error = result.unwrap_err();
        assert!(matches!(error, WorkspaceError::TooDeep(_)));
        assert!(error.to_string().contains("128-component path depth limit"));
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
            let outside = std::env::temp_dir().join("farhelm-agent-symlink-target");
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

    #[cfg(unix)]
    #[test]
    fn a_new_file_beneath_an_external_directory_symlink_is_refused() {
        let repo = TempRepo::new("missing-leaf-symlink");
        let outside = TempRepo::new("missing-leaf-outside");
        outside.write("existing.txt", "outside\n");
        std::os::unix::fs::symlink(&outside.0, repo.0.join("linked")).unwrap();

        let mut workspace = repo.workspace();
        for path in ["linked/new.txt", "linked/nested/new.txt"] {
            assert!(matches!(
                workspace.write(path, "escaped"),
                Err(WorkspaceError::Escapes(_))
            ));
            assert!(matches!(
                workspace.resolve(path),
                Err(WorkspaceError::Escapes(_))
            ));
        }
        assert!(matches!(
            workspace.read("linked/existing.txt"),
            Err(WorkspaceError::Escapes(_))
        ));
        assert!(matches!(
            workspace.list(Some("linked"), 100),
            Err(WorkspaceError::Escapes(_))
        ));
        assert!(!outside.0.join("new.txt").exists());
        assert!(!outside.0.join("nested").exists());
        assert_eq!(outside.read("existing.txt"), "outside\n");
    }

    #[cfg(unix)]
    #[test]
    fn internal_and_dangling_symlinks_are_refused_too() {
        let repo = TempRepo::new("internal-symlinks");
        repo.write("real/a.txt", "inside\n");
        std::os::unix::fs::symlink("real", repo.0.join("linked")).unwrap();
        std::os::unix::fs::symlink("absent", repo.0.join("dangling")).unwrap();

        let mut workspace = repo.workspace();
        for path in ["linked/a.txt", "linked/new.txt", "dangling/new.txt"] {
            assert!(matches!(
                workspace.write(path, "changed"),
                Err(WorkspaceError::Escapes(_))
            ));
            assert!(!workspace.exists(path));
        }
        assert_eq!(repo.read("real/a.txt"), "inside\n");
        assert!(!repo.0.join("real/new.txt").exists());
        assert!(!repo.0.join("absent").exists());
    }

    #[cfg(unix)]
    #[test]
    fn leaf_symlinks_are_neither_read_edited_deleted_nor_discovered() {
        let repo = TempRepo::new("leaf-symlinks");
        let outside = TempRepo::new("leaf-symlinks-outside");
        outside.write("private.txt", "external needle\n");
        std::os::unix::fs::symlink(outside.0.join("private.txt"), repo.0.join("linked.txt"))
            .unwrap();
        let mut workspace = repo.workspace();

        assert!(matches!(
            workspace.read("linked.txt"),
            Err(WorkspaceError::Escapes(_))
        ));
        assert!(matches!(
            workspace.edit("linked.txt", "needle", "changed"),
            Err(WorkspaceError::Escapes(_))
        ));
        assert!(matches!(
            workspace.delete("linked.txt"),
            Err(WorkspaceError::Escapes(_))
        ));
        assert!(!workspace.exists("linked.txt"));
        assert!(workspace.list(None, 100).unwrap().is_empty());
        assert!(workspace.search("needle", None, 100).unwrap().is_empty());
        assert_eq!(outside.read("private.txt"), "external needle\n");
        assert!(repo.0.join("linked.txt").symlink_metadata().is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn replacing_the_root_path_does_not_redirect_an_open_workspace() {
        let repo = TempRepo::new("root-replacement");
        let original = TempRepo::new("root-replacement-original");
        let outside = TempRepo::new("root-replacement-outside");
        repo.write("a.txt", "original\n");
        outside.write("a.txt", "outside needle\n");
        let mut workspace = repo.workspace();

        std::fs::remove_dir(&original.0).unwrap();
        std::fs::rename(&repo.0, &original.0).unwrap();
        std::os::unix::fs::symlink(&outside.0, &repo.0).unwrap();

        assert_eq!(workspace.read("a.txt").unwrap(), "original\n");
        workspace.write("new/deep.txt", "created\n").unwrap();
        assert_eq!(original.read("new/deep.txt"), "created\n");
        assert!(!outside.0.join("new").exists());
        assert!(workspace.search("needle", None, 100).unwrap().is_empty());
        workspace.delete("a.txt").unwrap();
        assert!(!original.0.join("a.txt").exists());
        assert_eq!(outside.read("a.txt"), "outside needle\n");
    }

    #[cfg(unix)]
    #[test]
    fn replacing_an_open_parent_path_does_not_redirect_its_handle() {
        let repo = TempRepo::new("parent-replacement");
        let outside = TempRepo::new("parent-replacement-outside");
        repo.write("src/a.txt", "original\n");
        outside.write("a.txt", "outside\n");
        let mut workspace = repo.workspace();
        let parent = workspace.directory(Path::new("src"), false, "src").unwrap();

        std::fs::rename(repo.0.join("src"), repo.0.join("original-src")).unwrap();
        std::os::unix::fs::symlink(&outside.0, repo.0.join("src")).unwrap();

        assert_eq!(
            read_file(&parent, OsStr::new("a.txt"), "src/a.txt").unwrap(),
            "original\n"
        );
        assert!(matches!(
            workspace.write("src/new.txt", "escaped"),
            Err(WorkspaceError::Escapes(_))
        ));
        assert!(!outside.0.join("new.txt").exists());
    }

    #[cfg(unix)]
    #[test]
    fn concurrent_leaf_symlink_replacement_cannot_read_or_overwrite_its_target() {
        use std::sync::atomic::{AtomicBool, Ordering};

        let repo = TempRepo::new("leaf-replacement-race");
        let outside = TempRepo::new("leaf-replacement-race-outside");
        repo.write("a.txt", "inside\n");
        outside.write("private.txt", "outside secret\n");
        let mut workspace = repo.workspace();
        let path = repo.0.join("a.txt");
        let target = outside.0.join("private.txt");
        let running = Arc::new(AtomicBool::new(true));
        let worker_running = Arc::clone(&running);
        let worker = std::thread::spawn(move || {
            while worker_running.load(Ordering::Relaxed) {
                let _ = std::fs::remove_file(&path);
                let _ = std::os::unix::fs::symlink(&target, &path);
                std::thread::yield_now();
                let _ = std::fs::remove_file(&path);
                // create_new avoids following a concurrently created leaf.
                let _ = std::fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(&path);
            }
        });
        let mut exposed = false;
        for _ in 0..300 {
            if let Ok(text) = workspace.read("a.txt") {
                exposed |= text.contains("outside secret");
            }
            let _ = workspace.write("a.txt", "agent\n");
        }
        running.store(false, Ordering::Relaxed);
        worker.join().unwrap();

        assert!(!exposed, "the symlink target must never be read");
        assert_eq!(outside.read("private.txt"), "outside secret\n");
    }

    #[cfg(unix)]
    #[test]
    fn fifos_are_refused_without_waiting_for_another_process() {
        let repo = TempRepo::new("fifo");
        assert!(
            std::process::Command::new("mkfifo")
                .arg(repo.0.join("pipe"))
                .status()
                .unwrap()
                .success()
        );
        let workspace = repo.workspace();
        let mut worker_workspace = workspace.clone();
        let (sender, receiver) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            let read = worker_workspace.read("pipe");
            let write = worker_workspace.write("pipe", "refused");
            sender.send((read, write)).unwrap();
        });
        let (read, write) = receiver
            .recv_timeout(std::time::Duration::from_secs(2))
            .expect("file tools must not block opening a FIFO");
        worker.join().unwrap();
        assert!(matches!(read, Err(WorkspaceError::Io { .. })));
        assert!(matches!(write, Err(WorkspaceError::Io { .. })));
        assert!(!workspace.exists("pipe"));
        assert!(workspace.list(None, 100).unwrap().is_empty());
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
    fn nested_listing_inherits_ignores_and_allows_nested_exceptions() {
        let repo = TempRepo::new("nested-ignores");
        repo.write(".gitignore", "*.tmp\ntarget/\n");
        repo.write("src/.gitignore", "!keep.tmp\n");
        repo.write("src/keep.tmp", "keep\n");
        repo.write("src/discard.tmp", "discard\n");
        repo.write("src/main.rs", "code\n");
        repo.write("src/target/build.txt", "discard\n");
        repo.write(".git/private.txt", "discard\n");

        let workspace = repo.workspace();
        let listed = workspace.list(Some("src"), 100).unwrap();
        assert!(listed.contains(&"src/keep.tmp".to_owned()));
        assert!(listed.contains(&"src/main.rs".to_owned()));
        assert!(!listed.contains(&"src/discard.tmp".to_owned()));
        assert!(!listed.iter().any(|path| path.contains("target/")));
        assert!(workspace.list(Some(".git"), 100).unwrap().is_empty());
        assert_eq!(
            workspace.list(Some("src/main.rs"), 100).unwrap(),
            vec!["src/main.rs"]
        );
    }

    #[test]
    fn ignore_files_take_precedence_over_gitignore_files() {
        let repo = TempRepo::new("ignore-precedence");
        repo.write(".gitignore", "*.txt\n");
        repo.write(".ignore", "!keep.txt\n");
        repo.write("keep.txt", "keep\n");
        repo.write("discard.txt", "discard\n");
        let listed = repo.workspace().list(None, 100).unwrap();
        assert!(listed.contains(&"keep.txt".to_owned()));
        assert!(!listed.contains(&"discard.txt".to_owned()));
    }

    #[test]
    fn ancestor_ignore_takes_precedence_over_nested_gitignore() {
        let repo = TempRepo::new("nested-ignore-precedence");
        repo.write(".ignore", "*.secret\n");
        repo.write("src/.gitignore", "!notes.secret\n");
        repo.write("src/notes.secret", "private needle\n");
        repo.write("src/.ignore", "!allowed.secret\n");
        repo.write("src/allowed.secret", "allowed\n");
        let workspace = repo.workspace();

        for start in [None, Some("src")] {
            let listed = workspace.list(start, 100).unwrap();
            assert!(!listed.contains(&"src/notes.secret".to_owned()));
            assert!(listed.contains(&"src/allowed.secret".to_owned()));
            assert!(workspace.search("needle", start, 100).unwrap().is_empty());
        }
    }

    #[test]
    fn in_root_git_info_excludes_apply_below_gitignore_precedence() {
        let repo = TempRepo::new("git-info-exclude");
        repo.write(".git/info/exclude", "*.private\n");
        repo.write("src/.gitignore", "!allowed.private\n");
        repo.write("src/notes.private", "private needle\n");
        repo.write("src/allowed.private", "allowed\n");
        let workspace = repo.workspace();

        for start in [None, Some("src")] {
            let listed = workspace.list(start, 100).unwrap();
            assert!(!listed.contains(&"src/notes.private".to_owned()));
            assert!(listed.contains(&"src/allowed.private".to_owned()));
            assert!(workspace.search("needle", start, 100).unwrap().is_empty());
        }
    }

    #[test]
    fn a_source_exclude_snapshot_is_interpreted_against_the_task_checkout() {
        let source = TempRepo::new("exclude-snapshot-source");
        let task = TempRepo::new("exclude-snapshot-task");
        source.write(".git/info/exclude", "/private.txt\n");
        task.write(".git", "gitdir: /untrusted/external/metadata\n");
        task.write("private.txt", "private needle\n");
        task.write("src/private.txt", "visible\n");
        let snapshot = source.workspace().git_exclude().unwrap();
        let mut workspace = task.workspace();
        workspace.set_git_exclude(&snapshot).unwrap();

        let listed = workspace.list(None, 100).unwrap();
        assert!(!listed.contains(&"private.txt".to_owned()));
        assert!(listed.contains(&"src/private.txt".to_owned()));
        assert!(workspace.search("needle", None, 100).unwrap().is_empty());
        assert!(matches!(
            workspace.set_git_exclude(&"x".repeat(MAX_FILE_BYTES as usize + 1)),
            Err(WorkspaceError::TooLarge { .. })
        ));
        assert!(workspace.search("needle", None, 100).unwrap().is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn git_excludes_do_not_follow_external_symlinks_or_worktree_pointers() {
        let repo = TempRepo::new("git-exclude-links");
        let outside = TempRepo::new("git-exclude-links-outside");
        repo.write("visible.txt", "visible\n");
        repo.write(".git/info/placeholder", "");
        outside.write("exclude", "visible.txt\n");
        std::os::unix::fs::symlink(outside.0.join("exclude"), repo.0.join(".git/info/exclude"))
            .unwrap();

        let workspace = repo.workspace();
        assert!(
            workspace
                .list(None, 100)
                .unwrap()
                .contains(&"visible.txt".to_owned())
        );

        std::fs::remove_dir_all(repo.0.join(".git")).unwrap();
        repo.write(".git", &format!("gitdir: {}\n", outside.0.display()));
        assert!(
            workspace
                .list(None, 100)
                .unwrap()
                .contains(&"visible.txt".to_owned())
        );
    }

    #[test]
    fn listing_and_searching_with_zero_limit_return_no_results() {
        let repo = TempRepo::new("zero-limit");
        repo.write("a.txt", "needle\n");
        let workspace = repo.workspace();
        assert!(workspace.list(None, 0).unwrap().is_empty());
        assert!(workspace.search("needle", None, 0).unwrap().is_empty());
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
