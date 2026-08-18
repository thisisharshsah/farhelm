//! The task's branch.
//!
//! [`crate::workspace`] holds a task's edits in memory and writes them to the
//! working tree only once somebody approves. That gets the review property
//! right and pays for it three times over: it reimplements diffing, it caps a
//! change set at a few megabytes because the whole thing lives in a database
//! row, and — the expensive one — **the agent cannot run its own tests**. The
//! `run` tool executes against the working tree, which by construction does not
//! contain the agent's staged edits, so `cargo test` in step nine tests the code
//! as it was in step one.
//!
//! A worktree fixes all three by moving the work somewhere real. The task gets
//! its own branch and its own checkout: the agent writes files normally, its
//! tests see its own edits, the diff is `git diff`, approving is a merge, and
//! discarding is deleting a branch. Nothing reaches the branch you are sitting
//! on until you say so, which is the property the overlay existed to provide.
//!
//! ## What this module deliberately does not do
//!
//! **It cuts from `HEAD`, not from your uncommitted work.** A worktree created
//! here contains the last commit, so an agent asked to "finish what I was
//! editing" will not see what you were editing. That is the reproducible
//! choice, and it is what a cloud agent working from a pushed ref would do —
//! but it is a real behavioural difference from the overlay, which reads the
//! live working tree. Carrying dirty state across is a decision worth making
//! deliberately rather than defaulting into, so it is not implemented here.
//!
//! **It is synchronous.** Every call shells out and blocks. The operations are
//! milliseconds on repositories of ordinary size, but a caller inside an async
//! task should still put them behind `spawn_blocking` rather than assume.

use std::path::{Path, PathBuf};
use std::process::Command;

use serde::{Deserialize, Serialize};

use crate::diff::{ChangeKind, ChangeSet, binary_diff, file_diff};

/// Bytes as text, or `None` if they are not text at all.
fn as_text(bytes: &Option<Vec<u8>>) -> Option<String> {
    String::from_utf8(bytes.as_ref()?.clone()).ok()
}

/// Who commits, when the repository has no identity configured.
///
/// Passed per-command with `-c` rather than written into any config: a task
/// must not be able to change the identity of the repository it was given, and
/// a machine that has never run `git config user.email` must still be able to
/// run one. The address is `.invalid` by RFC 2606, so it can never be somebody.
const AUTHOR_NAME: &str = "RelayForge agent";
const AUTHOR_EMAIL: &str = "agent@relayforge.invalid";

#[derive(Debug)]
pub enum GitError {
    /// The path is not inside a git repository.
    NotARepository(PathBuf),
    /// The repository exists but has no commits, so there is nothing to branch
    /// from. Reported separately because the fix is `git commit`, not anything
    /// about the task.
    NoCommits(PathBuf),
    /// A git invocation failed. Carries what was run and what it said, because
    /// "git failed" on its own has never helped anybody.
    Failed {
        command: String,
        message: String,
    },
    Io {
        command: String,
        message: String,
    },
}

impl std::fmt::Display for GitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GitError::NotARepository(path) => {
                write!(f, "{} is not inside a git repository", path.display())
            }
            GitError::NoCommits(path) => write!(
                f,
                "{} has no commits yet — commit once before running a task here",
                path.display()
            ),
            GitError::Failed { command, message } => write!(f, "`{command}` failed: {message}"),
            GitError::Io { command, message } => write!(f, "could not run `{command}`: {message}"),
        }
    }
}

impl std::error::Error for GitError {}

type Result<T> = std::result::Result<T, GitError>;

/// Run git in `dir` and return its stdout, trimmed.
fn git(dir: &Path, args: &[&str]) -> Result<String> {
    let rendered = || format!("git {}", args.join(" "));
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .map_err(|err| GitError::Io {
            command: rendered(),
            message: err.to_string(),
        })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_owned();
        return Err(GitError::Failed {
            command: rendered(),
            message: if stderr.is_empty() { stdout } else { stderr },
        });
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .trim_end()
        .to_owned())
}

/// Run git in `dir` and return its stdout untouched.
///
/// Separate from [`git`] because that one trims, which is right for reading a
/// commit id and catastrophic for reading a file: trailing newlines are content,
/// and a differ that loses them reports a change nobody made.
fn git_bytes(dir: &Path, args: &[&str]) -> Result<Vec<u8>> {
    let rendered = || format!("git {}", args.join(" "));
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .map_err(|err| GitError::Io {
            command: rendered(),
            message: err.to_string(),
        })?;

    if !output.status.success() {
        return Err(GitError::Failed {
            command: rendered(),
            message: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        });
    }
    Ok(output.stdout)
}

/// Whether `root` is inside a git repository — the question that decides
/// whether a task can have a branch at all.
pub fn is_repository(root: &Path) -> bool {
    git(root, &["rev-parse", "--is-inside-work-tree"])
        .map(|out| out == "true")
        .unwrap_or(false)
}

/// A file the task changed, as git sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Change {
    /// `A`, `M`, `D`, `R`… — git's own status letter.
    pub status: char,
    pub path: String,
}

/// What happened when a finished branch was merged back.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Merge {
    /// The base had not moved; the branch is now part of it.
    FastForwarded { commit: String },
    /// The base moved while the task was running. Nothing was merged and the
    /// branch is still there — the mirror of the overlay refusing to apply over
    /// somebody's later edit, except the work survives and can be merged by
    /// hand.
    Diverged,
}

/// One task's branch and checkout.
///
/// Serialisable, because a task awaiting review has to survive a runner
/// restart. What is stored is only the four strings needed to find the work
/// again — the work itself is on disk in git, which is the point. The overlay
/// this replaced had to serialise both sides of every file it touched.
///
/// Three of the four could in principle be recomputed (the path is derived from
/// the repo and the id, the branch from the id). [`Worktree::base`] cannot: it
/// is the commit the branch was cut from, and once the branch has commits on it
/// there is no reliable way to ask git which one that was. So all four are
/// written down rather than half recovered and half guessed.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Worktree {
    /// The repository this was cut from.
    repo: PathBuf,
    /// Where the agent works.
    path: PathBuf,
    branch: String,
    /// The commit the branch was cut from.
    base: String,
}

impl Worktree {
    /// Cut a new branch and checkout for `task_id`.
    ///
    /// The checkout lives under the repository's git directory, which is the
    /// one place guaranteed not to appear in the user's `git status` and not to
    /// need a `.gitignore` entry.
    pub fn create(repo_root: &Path, task_id: &str) -> Result<Self> {
        if !is_repository(repo_root) {
            return Err(GitError::NotARepository(repo_root.to_path_buf()));
        }

        let base = git(repo_root, &["rev-parse", "HEAD"])
            .map_err(|_| GitError::NoCommits(repo_root.to_path_buf()))?;

        let slug = slug(task_id);
        let branch = format!("forge/{slug}");
        let path = worktree_home(repo_root)?.join(&slug);

        // A previous run that died without cleaning up would otherwise make the
        // branch unusable for its own retry.
        let _ = git(
            repo_root,
            &["worktree", "remove", "--force", &path_str(&path)],
        );
        let _ = git(repo_root, &["branch", "-D", &branch]);

        git(
            repo_root,
            &["worktree", "add", "-b", &branch, &path_str(&path), &base],
        )?;

        Ok(Self {
            repo: repo_root.to_path_buf(),
            path,
            branch,
            base,
        })
    }

    /// Where the agent writes, and where its commands run.
    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn branch(&self) -> &str {
        &self.branch
    }

    /// The commit this branch was cut from.
    pub fn base(&self) -> &str {
        &self.base
    }

    /// Stage everything the task has done so far.
    ///
    /// Called before reading a diff so that a file the agent *created* shows up
    /// in it. Untracked files are invisible to `git diff` until they are staged,
    /// and a review card that silently omitted every new file would be worse
    /// than no card. Staging inside a throwaway worktree costs nothing.
    fn stage_all(&self) -> Result<()> {
        git(&self.path, &["add", "-A"]).map(|_| ())
    }

    /// The unified diff of everything the task has changed, against its base.
    pub fn diff(&self) -> Result<String> {
        self.stage_all()?;
        git(&self.path, &["diff", "--cached", "--no-color", &self.base])
    }

    /// Which files the task touched, and how.
    pub fn changed_files(&self) -> Result<Vec<Change>> {
        self.stage_all()?;
        let out = git(
            &self.path,
            &["diff", "--cached", "--name-status", &self.base],
        )?;
        Ok(out
            .lines()
            .filter_map(|line| {
                let mut parts = line.split('\t');
                let status = parts.next()?.chars().next()?;
                // A rename is `R100\told\tnew`: the last field is the path that
                // exists now, which is the one worth showing.
                let path = parts.next_back()?.to_owned();
                Some(Change { status, path })
            })
            .collect())
    }

    /// What the file looked like before the task touched it.
    ///
    /// `None` for a file the task created — there is no blob to ask for, and
    /// asking anyway is an error rather than an empty answer.
    fn blob_at_base(&self, path: &str) -> Result<Vec<u8>> {
        git_bytes(&self.path, &["show", &format!("{}:{}", self.base, path)])
    }

    /// The task's work as the review card renders it.
    ///
    /// Deliberately **not** a parse of `git diff`. Git decides isolation and
    /// lifecycle; [`crate::diff`] still decides presentation, so the bytes that
    /// reach a phone are produced by the same differ, with the same line
    /// numbering the clients have unit tests for. The switch from an overlay to
    /// a branch is then invisible to every screen — which is the only reason it
    /// can be made without touching three clients.
    ///
    /// Renames are detected off (`--no-renames`) so one arrives as a delete plus
    /// an add. The overlay has no concept of a rename, and a change set that
    /// suddenly grew one would be a wire change in disguise.
    pub fn change_set(&self) -> Result<ChangeSet> {
        self.stage_all()?;
        let listed = git(
            &self.path,
            &[
                "diff",
                "--cached",
                "--name-status",
                "--no-renames",
                &self.base,
            ],
        )?;

        let mut files = Vec::new();
        for line in listed.lines() {
            let mut parts = line.split('\t');
            let Some(status) = parts.next().and_then(|s| s.chars().next()) else {
                continue;
            };
            let Some(path) = parts.next_back() else {
                continue;
            };

            let before = match status {
                'A' => None,
                _ => Some(self.blob_at_base(path)?),
            };
            let after = match status {
                'D' => None,
                _ => Some(
                    std::fs::read(self.path.join(path)).map_err(|err| GitError::Io {
                        command: format!("read {path}"),
                        message: err.to_string(),
                    })?,
                ),
            };

            // A file the agent cannot have written as text is reported as
            // binary rather than mangled into a diff nobody can read.
            let before_text = as_text(&before);
            let after_text = as_text(&after);
            let readable = before_text.is_some() == before.is_some()
                && after_text.is_some() == after.is_some();

            if readable {
                if let Some(diff) = file_diff(path, before_text.as_deref(), after_text.as_deref()) {
                    files.push(diff);
                }
            } else {
                files.push(binary_diff(
                    path,
                    match status {
                        'A' => ChangeKind::Added,
                        'D' => ChangeKind::Deleted,
                        _ => ChangeKind::Modified,
                    },
                ));
            }
        }

        files.sort_by(|left, right| left.path.cmp(&right.path));
        Ok(ChangeSet { files })
    }

    /// Commit whatever the task has done. `None` when it changed nothing.
    pub fn commit(&self, message: &str) -> Result<Option<String>> {
        self.stage_all()?;
        // `git commit` on an empty index fails, and a failure that means
        // "nothing happened" must not look like a failure that means "git
        // broke".
        let clean = Command::new("git")
            .arg("-C")
            .arg(&self.path)
            .args(["diff", "--cached", "--quiet"])
            .status()
            .map(|status| status.success())
            .unwrap_or(false);
        if clean {
            return Ok(None);
        }

        git(
            &self.path,
            &[
                "-c",
                &format!("user.name={AUTHOR_NAME}"),
                "-c",
                &format!("user.email={AUTHOR_EMAIL}"),
                "commit",
                "--no-verify",
                "-m",
                message,
            ],
        )?;
        git(&self.path, &["rev-parse", "HEAD"]).map(Some)
    }

    /// Merge the finished branch into whatever the repository has checked out.
    ///
    /// Fast-forward only. If the base moved while the task ran, this refuses
    /// and says so rather than resolving a conflict on somebody's behalf.
    pub fn merge_into_base(&self) -> Result<Merge> {
        let head = git(&self.repo, &["rev-parse", "HEAD"])?;
        if head != self.base {
            return Ok(Merge::Diverged);
        }
        git(&self.repo, &["merge", "--ff-only", &self.branch])?;
        let commit = git(&self.repo, &["rev-parse", "HEAD"])?;
        Ok(Merge::FastForwarded { commit })
    }

    /// Throw the task away: remove the checkout and delete the branch.
    ///
    /// This is the whole of "reject" — there is no half-written state to clean
    /// up, because nothing was ever written anywhere the user was looking.
    pub fn discard(self) -> Result<()> {
        git(
            &self.repo,
            &["worktree", "remove", "--force", &path_str(&self.path)],
        )?;
        git(&self.repo, &["branch", "-D", &self.branch])?;
        Ok(())
    }

    /// Remove the checkout but keep the branch.
    ///
    /// For a task that has been merged, or one a human wants to pick up by
    /// hand: the commits stay reachable, the disk does not.
    ///
    /// Keeping the branch is what makes [`Worktree::undo`] possible without
    /// storing a commit id anywhere: the branch *is* the record of what landed.
    pub fn release(self) -> Result<()> {
        git(
            &self.repo,
            &["worktree", "remove", "--force", &path_str(&self.path)],
        )?;
        Ok(())
    }

    /// Whether the checkout is still on disk.
    ///
    /// A worktree survives a runner restart, which is the whole reason this
    /// type is serialisable — but it does not survive somebody deleting it, or
    /// a `git worktree prune`. Asking before using one turns a confusing git
    /// error into a sentence that says what happened.
    pub fn is_present(&self) -> bool {
        // In a linked worktree `.git` is a file pointing at the real git dir,
        // not a directory — so this is `exists`, not `is_dir`.
        self.path.join(".git").exists()
    }

    /// The commit this task's branch points at, if the branch is still there.
    pub fn tip(&self) -> Result<String> {
        git(&self.repo, &["rev-parse", &self.branch])
    }

    /// Take an applied task back off the branch it was merged into.
    ///
    /// This is the mirror of [`Worktree::merge_into_base`], and it is a
    /// **revert commit** rather than a rewind. The overlay could put the old
    /// bytes back because it was holding them; git can do better, but only by
    /// moving history, and moving history under somebody who has since
    /// committed — or pushed — is the one way this could destroy work it was
    /// never shown. So the undo is additive: a commit that takes the change
    /// back out, which is what `git revert` is for.
    ///
    /// Refuses in the two cases where undoing would be a lie:
    ///
    /// - the change is not in the current branch at all, so there is nothing to
    ///   take out — the mirror of the overlay's staleness check; and
    /// - the revert does not apply cleanly, which means somebody edited the same
    ///   lines afterwards and rewinding would throw *their* work away.
    ///
    /// Neither case leaves anything half-done: a conflicted revert is aborted
    /// before returning, so the working tree is as it was.
    pub fn undo(&self) -> Result<String> {
        let applied = self.tip().map_err(|_| GitError::Failed {
            command: format!("git rev-parse {}", self.branch),
            message: format!(
                "branch {} is gone, so there is no record of what was applied",
                self.branch
            ),
        })?;

        let contains = Command::new("git")
            .arg("-C")
            .arg(&self.repo)
            .args(["merge-base", "--is-ancestor", &applied, "HEAD"])
            .status()
            .map(|status| status.success())
            .unwrap_or(false);
        if !contains {
            return Err(GitError::Failed {
                command: format!("git merge-base --is-ancestor {applied} HEAD"),
                message: "that change set is not in the branch you have checked \
                          out, so there is nothing here to undo"
                    .into(),
            });
        }

        let reverted = git(
            &self.repo,
            &[
                "-c",
                &format!("user.name={AUTHOR_NAME}"),
                "-c",
                &format!("user.email={AUTHOR_EMAIL}"),
                "revert",
                "--no-edit",
                &applied,
            ],
        );
        if let Err(err) = reverted {
            // A conflicted revert leaves the tree mid-operation. Put it back
            // before reporting, so a failed undo costs the user nothing.
            let _ = git(&self.repo, &["revert", "--abort"]);
            return Err(err);
        }

        git(&self.repo, &["rev-parse", "HEAD"])
    }
}

/// Where this repository's task checkouts live.
fn worktree_home(repo_root: &Path) -> Result<PathBuf> {
    let common = git(repo_root, &["rev-parse", "--git-common-dir"])?;
    let common = PathBuf::from(&common);
    let common = if common.is_absolute() {
        common
    } else {
        repo_root.join(common)
    };
    Ok(common.join("forge-worktrees"))
}

fn path_str(path: &Path) -> String {
    path.display().to_string()
}

/// Reduce a task id to something git will accept as a branch component.
///
/// Task ids are generated, so this is a guard rather than a transformation —
/// but a branch name is a path, and one built from an id nobody validated is a
/// way to write outside `refs/heads/forge/`.
fn slug(task_id: &str) -> String {
    let cleaned: String = task_id
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '-'
            }
        })
        .collect();
    let trimmed = cleaned.trim_matches(['-', '.']).to_owned();
    if trimmed.is_empty() {
        "task".to_owned()
    } else {
        trimmed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TempRepo(PathBuf);

    impl TempRepo {
        /// A real repository with one commit, because every property here is
        /// about what git actually does.
        fn new(name: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "forge-git-{name}-{}-{:?}",
                std::process::id(),
                std::thread::current().id()
            ));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).unwrap();

            git(&path, &["init", "-q", "-b", "main"]).unwrap();
            std::fs::write(path.join("a.txt"), "one\n").unwrap();
            git(&path, &["add", "-A"]).unwrap();
            git(
                &path,
                &[
                    "-c",
                    "user.name=test",
                    "-c",
                    "user.email=test@example.invalid",
                    "commit",
                    "-q",
                    "-m",
                    "first",
                ],
            )
            .unwrap();
            Self(path)
        }

        fn head(&self) -> String {
            git(&self.0, &["rev-parse", "HEAD"]).unwrap()
        }

        /// Add another file to the base commit.
        fn with_committed(self, name: &str, content: &str) -> Self {
            std::fs::write(self.0.join(name), content).unwrap();
            git(&self.0, &["add", "-A"]).unwrap();
            git(
                &self.0,
                &[
                    "-c",
                    "user.name=test",
                    "-c",
                    "user.email=test@example.invalid",
                    "commit",
                    "-q",
                    "-m",
                    "add file",
                ],
            )
            .unwrap();
            self
        }
    }

    impl Drop for TempRepo {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn a_directory_that_is_not_a_repository_is_refused() {
        let dir = std::env::temp_dir().join(format!("forge-git-plain-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        assert!(!is_repository(&dir));
        assert!(matches!(
            Worktree::create(&dir, "t1"),
            Err(GitError::NotARepository(_))
        ));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_agent_writes_into_its_own_checkout_not_yours() {
        let repo = TempRepo::new("isolated");
        let tree = Worktree::create(&repo.0, "task-1").unwrap();

        std::fs::write(tree.path().join("a.txt"), "two\n").unwrap();

        // The property the overlay existed to provide, obtained for free.
        assert_eq!(
            std::fs::read_to_string(repo.0.join("a.txt")).unwrap(),
            "one\n",
            "the repository the human is sitting in must not have moved"
        );
        assert_eq!(
            std::fs::read_to_string(tree.path().join("a.txt")).unwrap(),
            "two\n"
        );
        tree.discard().unwrap();
    }

    #[test]
    fn a_created_file_appears_in_the_diff() {
        // The failure this prevents: `git diff` ignores untracked files, so a
        // task whose whole output is a new file would produce an empty review
        // card that looks like "the agent did nothing".
        let repo = TempRepo::new("untracked");
        let tree = Worktree::create(&repo.0, "task-2").unwrap();

        std::fs::write(tree.path().join("new.txt"), "hello\n").unwrap();

        let diff = tree.diff().unwrap();
        assert!(diff.contains("new.txt"), "diff was: {diff}");
        assert!(diff.contains("+hello"), "diff was: {diff}");

        let changed = tree.changed_files().unwrap();
        assert_eq!(
            changed,
            vec![Change {
                status: 'A',
                path: "new.txt".into()
            }]
        );
        tree.discard().unwrap();
    }

    #[test]
    fn a_task_that_changed_nothing_has_nothing_to_commit() {
        let repo = TempRepo::new("nothing");
        let tree = Worktree::create(&repo.0, "task-3").unwrap();
        assert_eq!(tree.commit("no-op").unwrap(), None);
        assert!(tree.diff().unwrap().is_empty());
        tree.discard().unwrap();
    }

    #[test]
    fn committing_works_without_a_configured_identity() {
        // A machine that has never run `git config user.email` must still be
        // able to run a task; the identity is passed per-command.
        let repo = TempRepo::new("identity");
        let tree = Worktree::create(&repo.0, "task-4").unwrap();
        std::fs::write(tree.path().join("a.txt"), "two\n").unwrap();

        let commit = tree.commit("change a").unwrap();
        assert!(commit.is_some());

        let author = git(tree.path(), &["log", "-1", "--format=%an <%ae>"]).unwrap();
        assert_eq!(author, format!("{AUTHOR_NAME} <{AUTHOR_EMAIL}>"));
        tree.discard().unwrap();
    }

    #[test]
    fn approving_fast_forwards_the_branch_you_were_on() {
        let repo = TempRepo::new("merge");
        let before = repo.head();
        let tree = Worktree::create(&repo.0, "task-5").unwrap();

        std::fs::write(tree.path().join("a.txt"), "two\n").unwrap();
        tree.commit("change a").unwrap();

        let merged = tree.merge_into_base().unwrap();
        assert!(matches!(merged, Merge::FastForwarded { .. }));
        assert_ne!(repo.head(), before);
        assert_eq!(
            std::fs::read_to_string(repo.0.join("a.txt")).unwrap(),
            "two\n",
            "the change should now be in the working tree"
        );
        tree.release().unwrap();
    }

    #[test]
    fn a_base_that_moved_underneath_the_task_refuses_to_merge() {
        // The mirror of the overlay's staleness check — except the work is not
        // lost, it is sitting on a branch somebody can merge by hand.
        let repo = TempRepo::new("diverged");
        let tree = Worktree::create(&repo.0, "task-6").unwrap();
        std::fs::write(tree.path().join("a.txt"), "from the agent\n").unwrap();
        tree.commit("agent change").unwrap();

        std::fs::write(repo.0.join("b.txt"), "from the human\n").unwrap();
        git(&repo.0, &["add", "-A"]).unwrap();
        git(
            &repo.0,
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "commit",
                "-q",
                "-m",
                "human change",
            ],
        )
        .unwrap();

        assert_eq!(tree.merge_into_base().unwrap(), Merge::Diverged);
        assert_eq!(
            std::fs::read_to_string(repo.0.join("a.txt")).unwrap(),
            "one\n",
            "nothing of the task should have landed"
        );
        // The branch survives a refusal.
        let branches = git(&repo.0, &["branch", "--list", tree.branch()]).unwrap();
        assert!(branches.contains("forge/task-6"));
        tree.discard().unwrap();
    }

    #[test]
    fn discarding_leaves_neither_a_checkout_nor_a_branch() {
        let repo = TempRepo::new("discard");
        let tree = Worktree::create(&repo.0, "task-7").unwrap();
        let path = tree.path().to_path_buf();
        let branch = tree.branch().to_owned();
        std::fs::write(path.join("a.txt"), "two\n").unwrap();
        tree.commit("change").unwrap();

        tree.discard().unwrap();

        assert!(!path.exists(), "the checkout should be gone");
        let branches = git(&repo.0, &["branch", "--list", &branch]).unwrap();
        assert!(branches.is_empty(), "the branch should be gone: {branches}");
    }

    #[test]
    fn a_retry_can_reuse_the_id_of_a_run_that_died() {
        // A runner killed mid-task leaves a checkout and a branch behind. The
        // retry must not fail with "branch already exists".
        let repo = TempRepo::new("reuse");
        let first = Worktree::create(&repo.0, "task-8").unwrap();
        std::fs::write(first.path().join("a.txt"), "abandoned\n").unwrap();
        std::mem::forget(first); // die without cleaning up

        let second = Worktree::create(&repo.0, "task-8").unwrap();
        assert_eq!(
            std::fs::read_to_string(second.path().join("a.txt")).unwrap(),
            "one\n",
            "the retry should start from the base, not from the wreckage"
        );
        second.discard().unwrap();
    }

    #[test]
    fn a_branch_and_the_overlay_describe_the_same_change_identically() {
        // The property that makes the switchover safe. Three clients render
        // `ChangeSet` and one of them reimplements the renderer in Swift, so a
        // worktree must produce exactly what the overlay produced — otherwise
        // replacing one with the other is a wire change wearing a refactor's
        // clothes.
        let repo = TempRepo::new("parity").with_committed("b.txt", "keep\n");

        let mut overlay = crate::workspace::Workspace::open(&repo.0).unwrap();
        overlay.stage_write("a.txt", "two\n").unwrap();
        overlay.stage_write("new.txt", "hello\nworld\n").unwrap();
        overlay.stage_delete("b.txt").unwrap();

        let tree = Worktree::create(&repo.0, "parity").unwrap();
        std::fs::write(tree.path().join("a.txt"), "two\n").unwrap();
        std::fs::write(tree.path().join("new.txt"), "hello\nworld\n").unwrap();
        std::fs::remove_file(tree.path().join("b.txt")).unwrap();

        let from_branch = tree.change_set().unwrap();
        assert_eq!(from_branch, overlay.changes());
        assert_eq!(from_branch.files.len(), 3);
        assert_eq!(from_branch.added(), 3);
        tree.discard().unwrap();
    }

    #[test]
    fn a_file_edited_back_to_what_it_was_is_not_a_change() {
        // The overlay drops these so a review card never asks for a decision
        // about nothing. Git agrees, but for a different reason, so it is worth
        // pinning that the two agree.
        let repo = TempRepo::new("noop");
        let tree = Worktree::create(&repo.0, "noop").unwrap();
        std::fs::write(tree.path().join("a.txt"), "changed\n").unwrap();
        std::fs::write(tree.path().join("a.txt"), "one\n").unwrap();

        assert!(tree.change_set().unwrap().is_empty());
        tree.discard().unwrap();
    }

    #[test]
    fn a_file_that_is_not_text_is_reported_as_binary_not_mangled() {
        let repo = TempRepo::new("binary");
        let tree = Worktree::create(&repo.0, "binary").unwrap();
        std::fs::write(tree.path().join("blob.bin"), [0xff, 0xfe, 0x00, 0x01]).unwrap();

        let changes = tree.change_set().unwrap();
        assert_eq!(changes.files.len(), 1);
        assert!(changes.files[0].binary);
        assert_eq!(changes.files[0].kind, ChangeKind::Added);
        assert!(changes.files[0].hunks.is_empty());
        tree.discard().unwrap();
    }

    #[test]
    fn the_two_backing_stores_agree_about_a_trailing_newline() {
        // Two separate things are being pinned here.
        //
        // First: reading a blob must not go through the trimming helper. If it
        // did, every file ending in a newline would come back one byte short
        // and the first `change_set` on an untouched repository would report
        // changes nobody made. Hence `git_bytes`.
        //
        // Second, and less comfortable: a change that is *only* a trailing
        // newline is invisible to `crate::diff`, which compares files by line
        // and cannot represent "the last line lost its terminator". That is a
        // property of the differ, not of either backing store — so the useful
        // assertion is that the branch and the overlay are wrong in exactly the
        // same way, which is what makes them interchangeable.
        let repo = TempRepo::new("newline").with_committed("c.txt", "line\n");

        let tree = Worktree::create(&repo.0, "newline").unwrap();
        std::fs::write(tree.path().join("c.txt"), "line\n").unwrap();
        assert!(
            tree.change_set().unwrap().is_empty(),
            "identical bytes must not read as a change"
        );

        std::fs::write(tree.path().join("c.txt"), "line").unwrap();
        let mut overlay = crate::workspace::Workspace::open(&repo.0).unwrap();
        overlay.stage_write("c.txt", "line").unwrap();

        assert_eq!(
            tree.change_set().unwrap(),
            overlay.changes(),
            "branch and overlay must agree, whatever the differ does"
        );
        tree.discard().unwrap();
    }

    #[test]
    fn an_id_that_is_not_a_branch_name_is_made_into_one() {
        assert_eq!(slug("01a00ec8-81ce-7b41"), "01a00ec8-81ce-7b41");
        assert_eq!(slug("../../etc/passwd"), "etc-passwd");
        assert_eq!(slug(""), "task");
        assert_eq!(slug("///"), "task");
    }

    #[test]
    fn undoing_an_applied_task_puts_the_files_back() {
        let repo = TempRepo::new("undo");
        let tree = Worktree::create(&repo.0, "task-undo").unwrap();
        std::fs::write(tree.path().join("a.txt"), "from the agent\n").unwrap();
        tree.commit("agent change").unwrap();
        tree.merge_into_base().unwrap();
        assert_eq!(
            std::fs::read_to_string(repo.0.join("a.txt")).unwrap(),
            "from the agent\n"
        );

        tree.undo().unwrap();

        assert_eq!(
            std::fs::read_to_string(repo.0.join("a.txt")).unwrap(),
            "one\n",
            "undo should restore what was there before the task"
        );
    }

    #[test]
    fn undo_is_a_commit_rather_than_a_rewind() {
        // The behavioural difference from the overlay, pinned deliberately.
        // Rewinding would be tidier and is exactly what must not happen: the
        // commit may already have been pushed, and moving history under
        // somebody is how an undo destroys work it was never shown.
        let repo = TempRepo::new("undo-additive");
        let tree = Worktree::create(&repo.0, "task-additive").unwrap();
        std::fs::write(tree.path().join("a.txt"), "two\n").unwrap();
        let applied = tree.commit("agent change").unwrap().unwrap();
        tree.merge_into_base().unwrap();

        let reverting = tree.undo().unwrap();

        assert_ne!(reverting, applied);
        let contains = git(&repo.0, &["merge-base", "--is-ancestor", &applied, "HEAD"]);
        assert!(contains.is_ok(), "the applied commit must still be history");
    }

    #[test]
    fn undoing_over_somebody_elses_later_edit_is_refused_not_forced() {
        let repo = TempRepo::new("undo-conflict");
        let tree = Worktree::create(&repo.0, "task-conflict").unwrap();
        std::fs::write(tree.path().join("a.txt"), "from the agent\n").unwrap();
        tree.commit("agent change").unwrap();
        tree.merge_into_base().unwrap();

        // A human edits the same line afterwards and commits it.
        std::fs::write(repo.0.join("a.txt"), "and then a human\n").unwrap();
        git(&repo.0, &["add", "-A"]).unwrap();
        git(
            &repo.0,
            &[
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.invalid",
                "commit",
                "-q",
                "-m",
                "human change",
            ],
        )
        .unwrap();

        assert!(tree.undo().is_err(), "a conflicted undo must refuse");
        assert_eq!(
            std::fs::read_to_string(repo.0.join("a.txt")).unwrap(),
            "and then a human\n",
            "the human's work must be exactly where they left it"
        );
        // And the repository must not be sitting mid-revert.
        let status = git(&repo.0, &["status", "--porcelain"]).unwrap();
        assert!(status.is_empty(), "the tree was left dirty: {status}");
    }

    #[test]
    fn undoing_something_that_never_landed_is_refused() {
        let repo = TempRepo::new("undo-unapplied");
        let tree = Worktree::create(&repo.0, "task-unapplied").unwrap();
        std::fs::write(tree.path().join("a.txt"), "two\n").unwrap();
        tree.commit("agent change").unwrap();

        // Never merged, so there is nothing in HEAD to take back out.
        assert!(tree.undo().is_err());
        tree.discard().unwrap();
    }

    #[test]
    fn a_worktree_survives_a_round_trip_through_json() {
        // What lets a task await review across a runner restart. The overlay
        // had to serialise both sides of every file to manage this; here it is
        // four strings, because the work itself is in git.
        let repo = TempRepo::new("json");
        let tree = Worktree::create(&repo.0, "task-json").unwrap();
        std::fs::write(tree.path().join("a.txt"), "two\n").unwrap();

        let json = serde_json::to_string(&tree).unwrap();
        let reopened: Worktree = serde_json::from_str(&json).unwrap();

        assert_eq!(reopened.branch(), tree.branch());
        assert_eq!(reopened.base(), tree.base());
        assert!(reopened.is_present());
        assert_eq!(reopened.change_set().unwrap(), tree.change_set().unwrap());
        reopened.discard().unwrap();
    }

    #[test]
    fn a_checkout_somebody_deleted_is_reported_rather_than_used() {
        let repo = TempRepo::new("absent");
        let tree = Worktree::create(&repo.0, "task-absent").unwrap();
        assert!(tree.is_present());

        std::fs::remove_dir_all(tree.path()).unwrap();
        assert!(!tree.is_present());
    }

    #[test]
    fn the_checkout_does_not_show_up_in_the_users_status() {
        // A worktree in the working tree would appear as an untracked directory
        // and, worse, could be committed by the human by accident.
        let repo = TempRepo::new("status");
        let tree = Worktree::create(&repo.0, "task-9").unwrap();
        std::fs::write(tree.path().join("a.txt"), "two\n").unwrap();

        let status = git(&repo.0, &["status", "--porcelain"]).unwrap();
        assert!(status.is_empty(), "status should be clean, was: {status}");
        tree.discard().unwrap();
    }
}
