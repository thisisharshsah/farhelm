//! Process lifetime and bounded output for approved commands and trusted checks.
//!
//! Commands run in a Unix process group or Windows Job Object. Dropping the
//! future requests termination of that group, including ordinary descendants.
//! This is lifecycle management, not a sandbox: a hostile Unix process can
//! escape its group, and filesystem/network/environment policy is the caller's.

use std::io;
use std::process::{ExitStatus, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::Duration;

use process_wrap::tokio::{ChildWrapper, CommandWrap, KillOnDrop};
use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::process::Command;

#[derive(Debug)]
pub struct Output {
    pub status: ExitStatus,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub truncated: bool,
}

#[derive(Debug)]
pub enum RunError {
    Io(io::Error),
    /// Cleanup failure is retained instead of claiming the command was killed.
    TimedOut {
        cleanup_error: Option<String>,
    },
}

impl std::fmt::Display for RunError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(error) => write!(f, "{error}"),
            Self::TimedOut {
                cleanup_error: None,
            } => f.write_str("timed out; command-group termination requested"),
            Self::TimedOut {
                cleanup_error: Some(error),
            } => {
                write!(f, "timed out; command-group cleanup failed: {error}")
            }
        }
    }
}

impl std::error::Error for RunError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            Self::TimedOut { .. } => None,
        }
    }
}

impl From<io::Error> for RunError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

struct ManagedChild {
    child: Box<dyn ChildWrapper>,
    armed: bool,
}

impl ManagedChild {
    async fn complete(&mut self) -> io::Result<ExitStatus> {
        // A wrapper's async wait may include all job members. Observe the
        // primary command first so background children cannot hold inherited
        // pipes open until the deadline after the command itself succeeds.
        loop {
            if let Some(status) = self.child.try_wait()? {
                self.terminate()?;
                self.child.wait().await?;
                return Ok(status);
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    fn terminate(&mut self) -> io::Result<()> {
        match self.child.start_kill() {
            Ok(()) => Ok(()),
            #[cfg(unix)]
            Err(error) if error.raw_os_error() == Some(nix::errno::Errno::ESRCH as i32) => {
                // A completed command may already have no process group left.
                Ok(())
            }
            Err(error) => Err(error),
        }
    }
}

impl Drop for ManagedChild {
    fn drop(&mut self) {
        if self.armed {
            let _ = self.terminate();
        }
        // KillOnDrop also retains Tokio's best-effort child reaping behavior.
    }
}

/// Run a command with a deadline and one combined byte budget for both pipes.
///
/// Excess output is drained, not retained, so a full pipe cannot deadlock a
/// command. No reader tasks are detached. On normal completion we also stop
/// background descendants; a command cannot leave an untracked daemon behind.
pub async fn run(
    mut command: Command,
    timeout: Duration,
    max_output_bytes: usize,
) -> Result<Output, RunError> {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut wrapped = CommandWrap::from(command);
    wrapped.wrap(KillOnDrop);
    #[cfg(unix)]
    wrapped.wrap(process_wrap::tokio::ProcessGroup::leader());
    #[cfg(windows)]
    wrapped.wrap(process_wrap::tokio::JobObject);
    #[cfg(not(any(unix, windows)))]
    return Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "managed process groups are unsupported",
    )
    .into());

    let mut managed = ManagedChild {
        child: wrapped.spawn()?,
        armed: true,
    };
    let stdout = managed.child.stdout().take();
    let stderr = managed.child.stderr().take();
    let remaining = Arc::new(AtomicUsize::new(max_output_bytes));
    let truncated = Arc::new(AtomicBool::new(false));
    let capture = async {
        tokio::try_join!(
            managed.complete(),
            drain(stdout, Arc::clone(&remaining), Arc::clone(&truncated)),
            drain(stderr, Arc::clone(&remaining), Arc::clone(&truncated)),
        )
    };

    match tokio::time::timeout(timeout, capture).await {
        Ok(Ok((status, stdout, stderr))) => {
            managed.armed = false;
            Ok(Output {
                status,
                stdout,
                stderr,
                truncated: truncated.load(Ordering::Relaxed),
            })
        }
        Ok(Err(error)) => Err(error.into()),
        Err(_) => {
            let mut cleanup_error = managed.terminate().err().map(|error| error.to_string());
            // Bound cleanup too: a stuck OS wait must not hold the run slot forever.
            match tokio::time::timeout(Duration::from_secs(2), managed.child.wait()).await {
                Ok(Ok(_)) => {}
                Ok(Err(error)) => {
                    cleanup_error.get_or_insert_with(|| error.to_string());
                }
                Err(_) => {
                    cleanup_error
                        .get_or_insert_with(|| "waiting for command exit timed out".into());
                }
            }
            if cleanup_error.is_none() {
                managed.armed = false;
            }
            Err(RunError::TimedOut { cleanup_error })
        }
    }
}

async fn drain<R: AsyncRead + Unpin>(
    reader: Option<R>,
    remaining: Arc<AtomicUsize>,
    truncated: Arc<AtomicBool>,
) -> io::Result<Vec<u8>> {
    let mut captured = Vec::new();
    let Some(mut reader) = reader else {
        return Ok(captured);
    };
    let mut buffer = [0; 8192];
    loop {
        let count = reader.read(&mut buffer).await?;
        if count == 0 {
            break;
        }
        let retained = take_budget(&remaining, count);
        captured.extend_from_slice(&buffer[..retained]);
        if retained < count {
            truncated.store(true, Ordering::Relaxed);
        }
    }
    Ok(captured)
}

fn take_budget(remaining: &AtomicUsize, count: usize) -> usize {
    let mut available = remaining.load(Ordering::Relaxed);
    loop {
        match remaining.compare_exchange_weak(
            available,
            available.saturating_sub(count),
            Ordering::Relaxed,
            Ordering::Relaxed,
        ) {
            Ok(_) => return available.min(count),
            Err(current) => available = current,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shell(script: &str, root: &std::path::Path) -> Command {
        #[cfg(unix)]
        let mut command = Command::new("sh");
        #[cfg(unix)]
        command.args(["-c", script]);
        #[cfg(windows)]
        let mut command = Command::new("cmd");
        #[cfg(windows)]
        command.args(["/C", script]);
        command.current_dir(root);
        command
    }

    #[tokio::test]
    async fn captures_both_pipes_and_preserves_the_exit_code() {
        let dir = tempfile::tempdir().unwrap();
        let output = run(
            shell("echo hello && echo problem 1>&2 && exit 3", dir.path()),
            Duration::from_secs(5),
            1024,
        )
        .await
        .unwrap();
        assert_eq!(output.status.code(), Some(3));
        assert!(String::from_utf8_lossy(&output.stdout).contains("hello"));
        assert!(String::from_utf8_lossy(&output.stderr).contains("problem"));
        assert!(!output.truncated);
    }

    #[tokio::test]
    async fn a_missing_program_preserves_not_found() {
        let error = run(
            Command::new("farhelm-nonexistent-program-for-test"),
            Duration::from_secs(1),
            100,
        )
        .await
        .unwrap_err();
        assert!(
            matches!(error, RunError::Io(ref error) if error.kind() == io::ErrorKind::NotFound)
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn noisy_output_is_drained_with_one_combined_capture_limit() {
        let dir = tempfile::tempdir().unwrap();
        let output = run(
            shell(
                "head -c 100000 /dev/zero; head -c 100000 /dev/zero >&2",
                dir.path(),
            ),
            Duration::from_secs(5),
            4096,
        )
        .await
        .unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout.len() + output.stderr.len(), 4096);
        assert!(output.truncated);
    }

    #[tokio::test]
    async fn a_timeout_stops_the_shells_background_descendants() {
        let dir = tempfile::tempdir().unwrap();
        let task = tokio::spawn(run(
            descendant_command(dir.path(), 5000),
            Duration::from_secs(3),
            1024,
        ));
        wait_for_descendant(dir.path()).await;
        let error = task.await.unwrap().unwrap_err();
        assert!(matches!(
            error,
            RunError::TimedOut {
                cleanup_error: None
            }
        ));
        tokio::time::sleep(Duration::from_millis(3200)).await;
        assert!(!dir.path().join("escaped").exists());
    }

    #[tokio::test]
    async fn cancelling_the_future_stops_background_descendants() {
        let dir = tempfile::tempdir().unwrap();
        let task = tokio::spawn(run(
            descendant_command(dir.path(), 750),
            Duration::from_secs(10),
            1024,
        ));
        wait_for_descendant(dir.path()).await;
        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());
        tokio::time::sleep(Duration::from_millis(1000)).await;
        assert!(!dir.path().join("escaped").exists());
    }

    fn descendant_command(root: &std::path::Path, delay_ms: u64) -> Command {
        let mut command = Command::new(std::env::current_exe().unwrap());
        command
            .args(["--exact", "tests::command_fixture", "--nocapture"])
            .current_dir(root)
            .env("FARHELM_PROCESS_FIXTURE", "parent")
            .env("FARHELM_PROCESS_FIXTURE_DELAY_MS", delay_ms.to_string());
        command
    }

    async fn wait_for_descendant(root: &std::path::Path) {
        tokio::time::timeout(Duration::from_secs(2), async {
            while !root.join("ready").exists() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("fixture descendant must start before testing cleanup");
    }

    // Invoke this test in separate processes to exercise Unix groups and
    // Windows Job Objects without depending on shell-specific sleep utilities.
    #[allow(
        clippy::zombie_processes,
        reason = "the background fixture deliberately leaves a descendant for the managed supervisor to terminate"
    )]
    #[test]
    fn command_fixture() {
        match std::env::var("FARHELM_PROCESS_FIXTURE").as_deref() {
            Ok(mode @ ("parent" | "background")) => {
                let mut child = std::process::Command::new(std::env::current_exe().unwrap())
                    .args(["--exact", "tests::command_fixture", "--nocapture"])
                    .env("FARHELM_PROCESS_FIXTURE", "leaf")
                    .stdin(Stdio::null())
                    .stdout(Stdio::inherit())
                    .stderr(Stdio::inherit())
                    .spawn()
                    .unwrap();
                if mode == "parent" {
                    let _ = child.wait();
                } else {
                    let deadline = std::time::Instant::now() + Duration::from_secs(2);
                    while !std::path::Path::new("ready").exists() {
                        assert!(std::time::Instant::now() < deadline);
                        std::thread::sleep(Duration::from_millis(10));
                    }
                }
            }
            Ok("leaf") => {
                let delay = std::env::var("FARHELM_PROCESS_FIXTURE_DELAY_MS")
                    .unwrap()
                    .parse()
                    .unwrap();
                std::fs::write("ready", "ready").unwrap();
                std::thread::sleep(Duration::from_millis(delay));
                std::fs::write("escaped", "still running").unwrap();
            }
            _ => {}
        }
    }

    #[tokio::test]
    async fn a_successful_primary_stops_background_children_with_inherited_pipes() {
        let dir = tempfile::tempdir().unwrap();
        let mut command = descendant_command(dir.path(), 5000);
        command.env("FARHELM_PROCESS_FIXTURE", "background");
        let output = run(command, Duration::from_secs(3), 1024).await.unwrap();
        assert!(dir.path().join("ready").exists());
        assert!(output.status.success());
        assert!(!dir.path().join("escaped").exists());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn successful_commands_cannot_leave_detached_group_members() {
        let dir = tempfile::tempdir().unwrap();
        let output = run(
            shell(
                "(sleep 0.5; echo escaped > escaped) >/dev/null 2>&1 &",
                dir.path(),
            ),
            Duration::from_secs(3),
            100,
        )
        .await
        .unwrap();
        assert!(output.status.success());
        tokio::time::sleep(Duration::from_millis(700)).await;
        assert!(!dir.path().join("escaped").exists());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_successful_shell_does_not_wait_for_inherited_background_pipes() {
        let dir = tempfile::tempdir().unwrap();
        let output = run(
            shell("sleep 30 &", dir.path()),
            Duration::from_millis(500),
            100,
        )
        .await
        .unwrap();
        assert!(output.status.success());
    }
}
