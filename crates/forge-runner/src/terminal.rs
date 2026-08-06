//! tmux, behind an interface (M1).
//!
//! The session manager drives agents through tmux so they survive a closed lid
//! and an ssh disconnect — that is D1's whole mechanism. Everything tmux-shaped
//! lives here, behind [`Terminal`], so the manager above can be tested without
//! a terminal multiplexer installed.
//!
//! ## Building the argv is the risky part
//!
//! Shelling out goes wrong in the argument list, not the spawn, so the argv
//! builders are pure functions with their own tests. Two details carry real
//! weight:
//!
//! - **`send-keys -l`** sends text *literally*. Without it, an instruction
//!   dictated from a phone containing `C-c` would be interpreted as Ctrl-C and
//!   kill the agent. Every instruction from a remote device goes through here,
//!   so literal mode is not optional.
//! - **`--` before the command** stops tmux parsing an agent's own flags as its
//!   own.
//!
//! ## What is not verified
//!
//! The argv construction and the manager's logic are tested. The calls to tmux
//! itself are not exercised anywhere — tmux is not installed in the development
//! environment this was written in. Treat [`TmuxTerminal`] as unproven against a
//! real tmux until someone runs it against one.

use std::process::Stdio;

use tokio::process::Command;

/// The tmux session every agent window lives in. One session, one window per
/// agent — `forge:3.1` in the schema is `session:window.pane`.
pub const TMUX_SESSION: &str = "forge";

/// Format string that makes tmux print a target we can store verbatim.
const TARGET_FORMAT: &str = "#{session_name}:#{window_index}.#{pane_index}";

#[derive(Debug)]
pub enum TerminalError {
    /// tmux is not installed. Distinct from a failure, because it is a setup
    /// problem with a one-line fix.
    NotInstalled,
    /// tmux ran and refused.
    Failed {
        command: String,
        output: String,
    },
    Io(std::io::Error),
}

impl std::fmt::Display for TerminalError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TerminalError::NotInstalled => {
                f.write_str("tmux is not installed — the runner needs it to host agent sessions")
            }
            TerminalError::Failed { command, output } => {
                write!(f, "tmux {command} failed: {}", output.trim())
            }
            TerminalError::Io(err) => write!(f, "tmux: {err}"),
        }
    }
}

impl std::error::Error for TerminalError {}

/// What to start, and where.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpawnSpec {
    /// Window name, shown in tmux. Usually the repo name.
    pub name: String,
    /// Working directory for the agent.
    pub cwd: String,
    /// argv of the agent itself.
    pub command: Vec<String>,
}

pub trait Terminal: Send + Sync {
    /// Start an agent and return its target (`forge:3.1`).
    fn spawn(
        &self,
        spec: &SpawnSpec,
    ) -> impl std::future::Future<Output = Result<String, TerminalError>> + Send;

    /// Type a line into a pane, as if a human had.
    fn send_line(
        &self,
        target: &str,
        text: &str,
    ) -> impl std::future::Future<Output = Result<(), TerminalError>> + Send;

    /// The last `lines` of a pane's scrollback.
    fn capture(
        &self,
        target: &str,
        lines: usize,
    ) -> impl std::future::Future<Output = Result<String, TerminalError>> + Send;

    fn kill(
        &self,
        target: &str,
    ) -> impl std::future::Future<Output = Result<(), TerminalError>> + Send;

    /// Every pane tmux currently has. Used to garbage-collect dead sessions (D4).
    fn live_targets(
        &self,
    ) -> impl std::future::Future<Output = Result<Vec<String>, TerminalError>> + Send;
}

/* --------------------------------------------------------------- argv builders */

/// `tmux has-session -t forge`
pub fn argv_has_session() -> Vec<String> {
    vec!["has-session".into(), "-t".into(), TMUX_SESSION.into()]
}

/// The argv that starts an agent.
///
/// `create_session` picks between `new-session` (the first agent) and
/// `new-window` (every one after). Both print the new target thanks to `-P -F`.
pub fn argv_spawn(spec: &SpawnSpec, create_session: bool) -> Vec<String> {
    let mut argv: Vec<String> = if create_session {
        vec![
            "new-session".into(),
            "-d".into(),
            "-s".into(),
            TMUX_SESSION.into(),
        ]
    } else {
        vec![
            "new-window".into(),
            "-d".into(),
            "-t".into(),
            TMUX_SESSION.into(),
        ]
    };

    argv.extend([
        "-n".into(),
        spec.name.clone(),
        "-c".into(),
        spec.cwd.clone(),
        "-P".into(),
        "-F".into(),
        TARGET_FORMAT.into(),
    ]);

    // `--` stops tmux from claiming the agent's own flags.
    argv.push("--".into());
    argv.extend(spec.command.iter().cloned());
    argv
}

/// The two commands that type a line: the text, then the newline.
///
/// They are separate because `-l` (literal) is exactly what stops `Enter` from
/// being typed as the five characters `E n t e r`, and exactly what stops a
/// dictated `C-c` from killing the agent.
pub fn argv_send_line(target: &str, text: &str) -> [Vec<String>; 2] {
    [
        vec![
            "send-keys".into(),
            "-t".into(),
            target.into(),
            "-l".into(),
            "--".into(),
            text.into(),
        ],
        vec![
            "send-keys".into(),
            "-t".into(),
            target.into(),
            "Enter".into(),
        ],
    ]
}

/// `tmux capture-pane -p -J -t <target> -S -<lines>`
///
/// `-J` joins wrapped lines, so a long command does not arrive at the phone
/// split across two entries in the tail.
pub fn argv_capture(target: &str, lines: usize) -> Vec<String> {
    vec![
        "capture-pane".into(),
        "-p".into(),
        "-J".into(),
        "-t".into(),
        target.into(),
        "-S".into(),
        format!("-{lines}"),
    ]
}

pub fn argv_kill(target: &str) -> Vec<String> {
    vec!["kill-window".into(), "-t".into(), target.into()]
}

pub fn argv_live_targets() -> Vec<String> {
    vec![
        "list-panes".into(),
        "-a".into(),
        "-F".into(),
        TARGET_FORMAT.into(),
    ]
}

/* ------------------------------------------------------------- real terminal */

pub struct TmuxTerminal {
    binary: String,
}

impl Default for TmuxTerminal {
    fn default() -> Self {
        Self {
            binary: std::env::var("FORGE_TMUX").unwrap_or_else(|_| "tmux".to_owned()),
        }
    }
}

impl TmuxTerminal {
    async fn run(&self, argv: &[String]) -> Result<String, TerminalError> {
        let output = Command::new(&self.binary)
            .args(argv)
            .stdin(Stdio::null())
            .output()
            .await
            .map_err(|err| match err.kind() {
                std::io::ErrorKind::NotFound => TerminalError::NotInstalled,
                _ => TerminalError::Io(err),
            })?;

        if !output.status.success() {
            let mut combined = String::from_utf8_lossy(&output.stderr).into_owned();
            combined.push_str(&String::from_utf8_lossy(&output.stdout));
            return Err(TerminalError::Failed {
                command: argv.join(" "),
                output: combined,
            });
        }

        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    }

    /// Whether the shared tmux session already exists.
    async fn session_exists(&self) -> bool {
        self.run(&argv_has_session()).await.is_ok()
    }
}

impl Terminal for TmuxTerminal {
    async fn spawn(&self, spec: &SpawnSpec) -> Result<String, TerminalError> {
        let create_session = !self.session_exists().await;
        let target = self.run(&argv_spawn(spec, create_session)).await?;
        Ok(target.trim().to_owned())
    }

    async fn send_line(&self, target: &str, text: &str) -> Result<(), TerminalError> {
        for argv in argv_send_line(target, text) {
            self.run(&argv).await?;
        }
        Ok(())
    }

    async fn capture(&self, target: &str, lines: usize) -> Result<String, TerminalError> {
        self.run(&argv_capture(target, lines)).await
    }

    async fn kill(&self, target: &str) -> Result<(), TerminalError> {
        self.run(&argv_kill(target)).await.map(|_| ())
    }

    async fn live_targets(&self) -> Result<Vec<String>, TerminalError> {
        // No tmux server running at all means no panes, not an error — that is
        // the normal state before the first agent starts.
        match self.run(&argv_live_targets()).await {
            Ok(output) => Ok(output
                .lines()
                .map(str::trim)
                .filter(|line| !line.is_empty())
                .map(str::to_owned)
                .collect()),
            Err(TerminalError::Failed { .. }) => Ok(Vec::new()),
            Err(err) => Err(err),
        }
    }
}

/* ------------------------------------------------------------- fake terminal */

/// An in-memory terminal. Records everything, invents plausible targets.
#[cfg(test)]
pub struct FakeTerminal {
    panes: std::sync::Mutex<std::collections::HashMap<String, String>>,
    sent: std::sync::Mutex<Vec<(String, String)>>,
    next_window: std::sync::Mutex<usize>,
    fail_spawn: bool,
}

#[cfg(test)]
impl Default for FakeTerminal {
    fn default() -> Self {
        Self {
            panes: std::sync::Mutex::new(std::collections::HashMap::new()),
            sent: std::sync::Mutex::new(Vec::new()),
            next_window: std::sync::Mutex::new(0),
            fail_spawn: false,
        }
    }
}

#[cfg(test)]
impl FakeTerminal {
    /// A terminal that behaves as though tmux is not installed.
    pub fn unavailable() -> Self {
        Self {
            fail_spawn: true,
            ..Self::default()
        }
    }

    /// Everything typed into a pane, in order.
    pub fn sent(&self) -> Vec<(String, String)> {
        self.sent.lock().expect("fake terminal poisoned").clone()
    }

    /// Pretend a pane produced some output.
    pub fn set_output(&self, target: &str, text: &str) {
        self.panes
            .lock()
            .expect("fake terminal poisoned")
            .insert(target.to_owned(), text.to_owned());
    }
}

#[cfg(test)]
impl Terminal for FakeTerminal {
    async fn spawn(&self, _spec: &SpawnSpec) -> Result<String, TerminalError> {
        if self.fail_spawn {
            return Err(TerminalError::NotInstalled);
        }
        let mut next = self.next_window.lock().expect("fake terminal poisoned");
        *next += 1;
        let target = format!("{TMUX_SESSION}:{next}.0");
        self.panes
            .lock()
            .expect("fake terminal poisoned")
            .insert(target.clone(), String::new());
        Ok(target)
    }

    async fn send_line(&self, target: &str, text: &str) -> Result<(), TerminalError> {
        self.sent
            .lock()
            .expect("fake terminal poisoned")
            .push((target.to_owned(), text.to_owned()));
        Ok(())
    }

    async fn capture(&self, target: &str, _lines: usize) -> Result<String, TerminalError> {
        Ok(self
            .panes
            .lock()
            .expect("fake terminal poisoned")
            .get(target)
            .cloned()
            .unwrap_or_default())
    }

    async fn kill(&self, target: &str) -> Result<(), TerminalError> {
        self.panes
            .lock()
            .expect("fake terminal poisoned")
            .remove(target);
        Ok(())
    }

    async fn live_targets(&self) -> Result<Vec<String>, TerminalError> {
        Ok(self
            .panes
            .lock()
            .expect("fake terminal poisoned")
            .keys()
            .cloned()
            .collect())
    }
}

/* --------------------------------------------------------- backend selection */

/// Which terminal backend a runner is using.
///
/// [`Terminal`] uses return-position `impl Trait`, so it is not object safe and
/// cannot be a `Box<dyn Terminal>`. An enum costs one match per call and keeps
/// the trait as it is — worth it, because the alternative is boxing every future
/// in the hot output path.
pub enum AnyTerminal {
    /// tmux. Panes outlive the runner and can be attached to by hand.
    Tmux(TmuxTerminal),
    /// PTYs this process owns. Works everywhere, dies with the runner.
    Pty(crate::pty::PtyTerminal),
}

impl AnyTerminal {
    /// Pick a backend by name, or by what is actually available.
    ///
    /// `auto` prefers tmux when it is installed, because surviving a runner
    /// restart is worth more than anything the PTY backend offers — an agent
    /// mid-task should not die because you upgraded the daemon.
    pub async fn select(requested: Option<&str>) -> Self {
        match requested {
            Some("tmux") => Self::Tmux(TmuxTerminal::default()),
            Some("pty") => Self::Pty(crate::pty::PtyTerminal::new()),
            _ => {
                if crate::pty::binary_exists(
                    &std::env::var("FORGE_TMUX").unwrap_or_else(|_| "tmux".to_owned()),
                ) {
                    Self::Tmux(TmuxTerminal::default())
                } else {
                    Self::Pty(crate::pty::PtyTerminal::new())
                }
            }
        }
    }

    pub fn name(&self) -> &'static str {
        match self {
            Self::Tmux(_) => "tmux",
            Self::Pty(_) => "pty",
        }
    }

    /// Whether sessions survive the runner exiting.
    pub fn is_durable(&self) -> bool {
        matches!(self, Self::Tmux(_))
    }
}

impl Terminal for AnyTerminal {
    async fn spawn(&self, spec: &SpawnSpec) -> Result<String, TerminalError> {
        match self {
            Self::Tmux(inner) => inner.spawn(spec).await,
            Self::Pty(inner) => inner.spawn(spec).await,
        }
    }

    async fn send_line(&self, target: &str, text: &str) -> Result<(), TerminalError> {
        match self {
            Self::Tmux(inner) => inner.send_line(target, text).await,
            Self::Pty(inner) => inner.send_line(target, text).await,
        }
    }

    async fn capture(&self, target: &str, lines: usize) -> Result<String, TerminalError> {
        match self {
            Self::Tmux(inner) => inner.capture(target, lines).await,
            Self::Pty(inner) => inner.capture(target, lines).await,
        }
    }

    async fn kill(&self, target: &str) -> Result<(), TerminalError> {
        match self {
            Self::Tmux(inner) => inner.kill(target).await,
            Self::Pty(inner) => inner.kill(target).await,
        }
    }

    async fn live_targets(&self) -> Result<Vec<String>, TerminalError> {
        match self {
            Self::Tmux(inner) => inner.live_targets().await,
            Self::Pty(inner) => inner.live_targets().await,
        }
    }
}

/// A [`Terminal`] shared by every call site.
///
/// The PTY backend owns its panes, so there can only be one of it — unlike
/// `TmuxTerminal`, which is stateless because tmux holds the state. Call sites
/// take this rather than constructing a backend.
impl Terminal for std::sync::Arc<AnyTerminal> {
    async fn spawn(&self, spec: &SpawnSpec) -> Result<String, TerminalError> {
        self.as_ref().spawn(spec).await
    }
    async fn send_line(&self, target: &str, text: &str) -> Result<(), TerminalError> {
        self.as_ref().send_line(target, text).await
    }
    async fn capture(&self, target: &str, lines: usize) -> Result<String, TerminalError> {
        self.as_ref().capture(target, lines).await
    }
    async fn kill(&self, target: &str) -> Result<(), TerminalError> {
        self.as_ref().kill(target).await
    }
    async fn live_targets(&self) -> Result<Vec<String>, TerminalError> {
        self.as_ref().live_targets().await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec() -> SpawnSpec {
        SpawnSpec {
            name: "payments-api".into(),
            cwd: "/srv/payments-api".into(),
            command: vec!["claude".into(), "--dangerously-skip-permissions".into()],
        }
    }

    #[test]
    fn the_first_agent_creates_the_shared_session() {
        let argv = argv_spawn(&spec(), true);
        assert_eq!(argv[0], "new-session");
        assert!(argv.contains(&"-s".to_owned()));
        assert!(argv.contains(&TMUX_SESSION.to_owned()));
    }

    #[test]
    fn later_agents_open_a_window_in_it() {
        let argv = argv_spawn(&spec(), false);
        assert_eq!(argv[0], "new-window");
        assert!(argv.contains(&"-t".to_owned()));
    }

    #[test]
    fn spawning_asks_tmux_to_print_the_target_we_store() {
        let argv = argv_spawn(&spec(), true);
        let format_index = argv.iter().position(|arg| arg == "-F").unwrap();
        assert_eq!(argv[format_index + 1], TARGET_FORMAT);
        assert!(argv.contains(&"-P".to_owned()));
    }

    #[test]
    fn the_agents_own_flags_are_protected_by_a_double_dash() {
        let argv = argv_spawn(&spec(), true);
        let dash = argv.iter().position(|arg| arg == "--").unwrap();
        // Everything after `--` is the agent's argv, untouched and in order.
        assert_eq!(
            &argv[dash + 1..],
            &["claude", "--dangerously-skip-permissions"]
        );
    }

    #[test]
    fn the_agent_starts_in_its_own_repo() {
        let argv = argv_spawn(&spec(), true);
        let cwd = argv.iter().position(|arg| arg == "-c").unwrap();
        assert_eq!(argv[cwd + 1], "/srv/payments-api");
    }

    #[test]
    fn instructions_are_typed_literally_so_control_sequences_cannot_slip_in() {
        // A dictated instruction containing `C-c` must arrive as text, not as
        // Ctrl-C. `-l` is the entire defence.
        let [text, newline] = argv_send_line("forge:3.1", "please stop C-c and retry");
        assert!(
            text.contains(&"-l".to_owned()),
            "literal flag missing: {text:?}"
        );
        let dash = text.iter().position(|arg| arg == "--").unwrap();
        assert_eq!(text[dash + 1], "please stop C-c and retry");

        // The newline is a separate, non-literal call — that is what makes it
        // an Enter keypress rather than five characters.
        assert!(!newline.contains(&"-l".to_owned()));
        assert_eq!(newline.last().unwrap(), "Enter");
    }

    #[test]
    fn an_instruction_that_looks_like_a_flag_is_still_text() {
        let [text, _] = argv_send_line("forge:3.1", "--version");
        let dash = text.iter().position(|arg| arg == "--").unwrap();
        assert_eq!(text[dash + 1], "--version");
    }

    #[test]
    fn capture_joins_wrapped_lines_and_bounds_the_scrollback() {
        let argv = argv_capture("forge:3.1", 200);
        assert!(argv.contains(&"-J".to_owned()), "wrapped lines would split");
        let start = argv.iter().position(|arg| arg == "-S").unwrap();
        assert_eq!(argv[start + 1], "-200");
    }

    #[test]
    fn killing_removes_the_window_not_the_whole_session() {
        // `kill-session` would take every other agent down with it.
        let argv = argv_kill("forge:3.1");
        assert_eq!(argv[0], "kill-window");
    }

    #[tokio::test]
    async fn the_fake_terminal_hands_out_distinct_targets() {
        let terminal = FakeTerminal::default();
        let first = terminal.spawn(&spec()).await.unwrap();
        let second = terminal.spawn(&spec()).await.unwrap();

        assert_ne!(first, second);
        assert!(first.starts_with("forge:"));
        assert_eq!(terminal.live_targets().await.unwrap().len(), 2);
    }

    #[tokio::test]
    async fn killing_a_pane_removes_it_from_the_live_list() {
        let terminal = FakeTerminal::default();
        let target = terminal.spawn(&spec()).await.unwrap();
        terminal.kill(&target).await.unwrap();
        assert!(terminal.live_targets().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn an_unavailable_terminal_reports_the_setup_problem() {
        let err = FakeTerminal::unavailable()
            .spawn(&spec())
            .await
            .unwrap_err();
        assert!(matches!(err, TerminalError::NotInstalled));
        assert!(err.to_string().contains("not installed"));
    }
}
