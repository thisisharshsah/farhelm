//! A terminal backend that does not need tmux.
//!
//! [`crate::terminal::TmuxTerminal`] is the right default on a server: panes
//! outlive the runner, so restarting it does not kill every agent, and you can
//! `tmux attach` and take over by hand. But tmux does not exist on Windows,
//! is not installed by default on macOS, and asking someone to set it up before
//! they can try the product is a bad first five minutes.
//!
//! This backend owns the pseudo-terminals itself. It works everywhere —
//! including Windows, via ConPTY — and needs nothing installed.
//!
//! # The trade it makes, stated plainly
//!
//! **Sessions die with the runner.** A tmux pane survives; a PTY this process
//! owns does not. That is a real regression for a long-running server, and it is
//! why tmux stays the default where it is available. The desktop app uses this
//! backend because a desktop app *is* the process you are looking at — if it is
//! gone, you were not supervising anything anyway.
//!
//! # Scrollback
//!
//! tmux keeps scrollback and `capture-pane` reads it. A raw PTY has none, so
//! this keeps its own ring buffer per session — bounded, because an agent that
//! prints for six hours must not become the reason the machine runs out of
//! memory.

use std::collections::HashMap;
use std::io::{Read as _, Write as _};
use std::sync::{Arc, Mutex};

use portable_pty::{CommandBuilder, NativePtySystem, PtySize, PtySystem};

use crate::terminal::{SpawnSpec, Terminal, TerminalError};

/// How much output to keep per session. Roughly a screen's worth times ten;
/// the clients only ever render the last 200 lines.
const SCROLLBACK_LINES: usize = 2_000;

/// The size we tell the agent its terminal is.
///
/// Agents lay out boxes and progress bars to fit. Too narrow and the prompt
/// detection in [`forge_core::agent`] sees a wrapped, unrecognisable question;
/// too wide and nothing renders sensibly on a phone.
const COLS: u16 = 120;
const ROWS: u16 = 40;

struct Pane {
    /// Everything the agent has printed, bounded.
    scrollback: Arc<Mutex<Vec<String>>>,
    /// Writing end of the PTY, for typing into it.
    writer: Box<dyn std::io::Write + Send>,
    /// Keeps the child alive and lets us kill it.
    child: Box<dyn portable_pty::Child + Send + Sync>,
    /// Dropping this closes the PTY.
    _master: Box<dyn portable_pty::MasterPty + Send>,
}

/// PTYs this process owns.
#[derive(Default)]
pub struct PtyTerminal {
    panes: Arc<Mutex<HashMap<String, Pane>>>,
    next: Arc<Mutex<u64>>,
}

impl PtyTerminal {
    pub fn new() -> Self {
        Self::default()
    }

    /// Targets are `pty:N`, mirroring tmux's `forge:N.0` shape so the rest of
    /// the runner does not care which backend it is talking to.
    fn allocate_target(&self) -> String {
        let mut next = self.next.lock().expect("pty counter poisoned");
        *next += 1;
        format!("pty:{next}")
    }

    fn with_pane<T>(
        &self,
        target: &str,
        run: impl FnOnce(&mut Pane) -> Result<T, TerminalError>,
    ) -> Result<T, TerminalError> {
        let mut panes = self.panes.lock().expect("pty map poisoned");
        let pane = panes.get_mut(target).ok_or_else(|| TerminalError::Failed {
            command: target.to_owned(),
            output: "no such pane".into(),
        })?;
        run(pane)
    }
}

impl Terminal for PtyTerminal {
    async fn spawn(&self, spec: &SpawnSpec) -> Result<String, TerminalError> {
        let system = NativePtySystem::default();
        let pair = system
            .openpty(PtySize {
                rows: ROWS,
                cols: COLS,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|err| TerminalError::Failed {
                command: "openpty".into(),
                output: err.to_string(),
            })?;

        let (program, args) = spec.command.split_first().ok_or(TerminalError::Failed {
            command: spec.name.clone(),
            output: "no command to run".into(),
        })?;

        // Checked before the fork, because after it there is nothing to report:
        // a PTY spawn forks first and the exec failure happens in the child, so
        // the parent gets a live handle for a process that is already gone.
        // Without this, "Aider is not installed" looks like "the session died
        // for no reason three seconds in".
        if !binary_exists(program) {
            return Err(TerminalError::NotInstalled);
        }

        let mut command = CommandBuilder::new(program);
        command.args(args);
        command.cwd(&spec.cwd);
        // Agents check this to decide whether to emit colour and box drawing.
        // Left unset, some fall back to a dumb mode with no prompts to detect.
        command.env("TERM", "xterm-256color");

        let child = pair.slave.spawn_command(command).map_err(|err| {
            match err.downcast_ref::<std::io::Error>() {
                Some(io) if io.kind() == std::io::ErrorKind::NotFound => {
                    TerminalError::NotInstalled
                }
                _ => TerminalError::Failed {
                    command: spec.command.join(" "),
                    output: err.to_string(),
                },
            }
        })?;

        let writer = pair
            .master
            .take_writer()
            .map_err(|err| TerminalError::Failed {
                command: "take_writer".into(),
                output: err.to_string(),
            })?;
        let mut reader = pair
            .master
            .try_clone_reader()
            .map_err(|err| TerminalError::Failed {
                command: "clone_reader".into(),
                output: err.to_string(),
            })?;

        let scrollback: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&scrollback);

        // A blocking read on a dedicated thread rather than async I/O: PTY
        // readers are not pollable on every platform, and one thread per agent
        // session is a rounding error next to the agent itself.
        std::thread::spawn(move || {
            let mut buffer = [0u8; 8192];
            let mut partial = String::new();
            loop {
                match reader.read(&mut buffer) {
                    Ok(0) | Err(_) => break,
                    Ok(read) => {
                        partial.push_str(&String::from_utf8_lossy(&buffer[..read]));
                        let mut lines = sink.lock().expect("scrollback poisoned");
                        // Keep the trailing fragment: a prompt arrives without a
                        // newline, and dropping it would make every question
                        // invisible to the watcher.
                        while let Some(index) = partial.find('\n') {
                            let line: String = partial.drain(..=index).collect();
                            lines.push(strip_ansi(line.trim_end_matches(['\r', '\n'])));
                        }
                        if !partial.is_empty() {
                            lines.push(strip_ansi(&partial));
                            partial.clear();
                            // The fragment is provisional — the next read
                            // usually completes it, so it is replaced rather
                            // than appended to.
                            if lines.len() >= 2 {
                                let last = lines.pop().unwrap_or_default();
                                if lines
                                    .last()
                                    .is_some_and(|prev| last.starts_with(prev.as_str()))
                                {
                                    lines.pop();
                                }
                                lines.push(last);
                            }
                        }
                        let overflow = lines.len().saturating_sub(SCROLLBACK_LINES);
                        if overflow > 0 {
                            lines.drain(..overflow);
                        }
                    }
                }
            }
        });

        let target = self.allocate_target();
        self.panes.lock().expect("pty map poisoned").insert(
            target.clone(),
            Pane {
                scrollback,
                writer,
                child,
                _master: pair.master,
            },
        );
        Ok(target)
    }

    async fn send_line(&self, target: &str, text: &str) -> Result<(), TerminalError> {
        self.with_pane(target, |pane| {
            // Written as bytes, never interpolated into a shell command — the
            // same reasoning as tmux's `send-keys -l`. An instruction containing
            // `C-c` is text, not a control sequence.
            pane.writer
                .write_all(text.as_bytes())
                .and_then(|()| pane.writer.write_all(b"\r"))
                .and_then(|()| pane.writer.flush())
                .map_err(TerminalError::Io)
        })
    }

    async fn capture(&self, target: &str, lines: usize) -> Result<String, TerminalError> {
        self.with_pane(target, |pane| {
            let scrollback = pane.scrollback.lock().expect("scrollback poisoned");
            let start = scrollback.len().saturating_sub(lines);
            Ok(scrollback[start..].join("\n"))
        })
    }

    async fn kill(&self, target: &str) -> Result<(), TerminalError> {
        let mut panes = self.panes.lock().expect("pty map poisoned");
        if let Some(mut pane) = panes.remove(target) {
            let _ = pane.child.kill();
            let _ = pane.child.wait();
        }
        Ok(())
    }

    async fn live_targets(&self) -> Result<Vec<String>, TerminalError> {
        let mut panes = self.panes.lock().expect("pty map poisoned");
        let mut live = Vec::new();
        // `try_wait` reaps the exited ones, which is what makes a session that
        // ended show up as `dead` rather than running forever.
        panes.retain(|target, pane| match pane.child.try_wait() {
            Ok(Some(_)) => false,
            _ => {
                live.push(target.clone());
                true
            }
        });
        Ok(live)
    }
}

/// Is this binary on `PATH`?
///
/// A PTY spawn cannot report a missing binary — it forks first, and the exec
/// failure happens in the child, so the parent gets a live handle either way.
/// Without this check, starting a session with an agent that is not installed
/// looks like a session that mysteriously dies a moment later.
pub fn binary_exists(binary: &str) -> bool {
    if binary.is_empty() {
        return false;
    }
    // An explicit path is checked directly; a bare name is looked up on PATH.
    if binary.contains(std::path::MAIN_SEPARATOR) {
        return std::path::Path::new(binary).is_file();
    }

    let Some(path) = std::env::var_os("PATH") else {
        return false;
    };
    std::env::split_paths(&path).any(|directory| {
        let candidate = directory.join(binary);
        candidate.is_file() || candidate.with_extension("exe").is_file()
    })
}

/// Strip ANSI escape sequences.
///
/// Agents colour their output and redraw with cursor moves. Left in, the escape
/// bytes reach the phone as mojibake and — worse — break the prompt patterns in
/// [`forge_core::agent`], because `\x1b[32mProceed?` does not contain `proceed?`
/// at a position any human would recognise.
pub fn strip_ansi(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut chars = input.chars();

    while let Some(c) = chars.next() {
        if c != '\x1b' {
            // Carriage returns are how a progress bar redraws in place. Keeping
            // them would make one line look like fifty.
            if c != '\r' {
                out.push(c);
            }
            continue;
        }
        match chars.next() {
            // CSI — runs until a byte in `@`..`~`.
            Some('[') => {
                for next in chars.by_ref() {
                    if ('\x40'..='\x7e').contains(&next) {
                        break;
                    }
                }
            }
            // OSC — runs until BEL or ST.
            Some(']') => {
                while let Some(next) = chars.next() {
                    if next == '\x07' {
                        break;
                    }
                    if next == '\x1b' {
                        chars.next();
                        break;
                    }
                }
            }
            // A two-byte escape; the second byte is already consumed.
            Some(_) | None => {}
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn colour_is_stripped_so_the_phone_gets_text() {
        assert_eq!(strip_ansi("\x1b[32mok\x1b[0m"), "ok");
        assert_eq!(strip_ansi("\x1b[1;31mfailed\x1b[m"), "failed");
    }

    #[test]
    fn a_coloured_question_still_reads_as_a_question() {
        // The reason this matters: the prompt patterns match on plain text, so
        // an unstripped escape makes every question invisible to the watcher.
        let painted = "\x1b[33mProceed?\x1b[0m \x1b[2m(y/n)\x1b[0m";
        let plain = strip_ansi(painted);
        assert_eq!(plain, "Proceed? (y/n)");
        assert!(
            forge_core::agent::detect_prompt(
                &plain,
                forge_core::agent::spec(forge_core::types::Agent::OpenCode)
                    .dialect()
                    .unwrap()
            )
            .is_some()
        );
    }

    #[test]
    fn cursor_movement_and_clears_are_removed() {
        assert_eq!(strip_ansi("a\x1b[2Kb\x1b[1;1Hc"), "abc");
    }

    #[test]
    fn window_titles_are_removed() {
        assert_eq!(strip_ansi("\x1b]0;a title\x07done"), "done");
        assert_eq!(strip_ansi("\x1b]0;a title\x1b\\done"), "done");
    }

    #[test]
    fn a_progress_bar_redrawing_in_place_does_not_become_fifty_lines() {
        assert_eq!(strip_ansi("10%\r50%\r100%"), "10%50%100%");
    }

    #[test]
    fn ordinary_text_is_untouched() {
        assert_eq!(strip_ansi("cargo build --release"), "cargo build --release");
        assert_eq!(strip_ansi(""), "");
    }

    #[test]
    fn an_incomplete_escape_does_not_swallow_the_rest() {
        // A truncated read can split an escape sequence. Better to lose a few
        // bytes than the remainder of the line.
        assert_eq!(strip_ansi("ok\x1b"), "ok");
    }

    #[tokio::test]
    async fn a_command_runs_and_its_output_is_captured() {
        let terminal = PtyTerminal::new();
        let target = terminal
            .spawn(&SpawnSpec {
                name: "test".into(),
                cwd: ".".into(),
                command: vec!["echo".into(), "hello-from-pty".into()],
            })
            .await
            .expect("echo should exist everywhere this runs");

        // The reader thread needs a moment; the process is tiny.
        for _ in 0..40 {
            tokio::time::sleep(std::time::Duration::from_millis(25)).await;
            if terminal
                .capture(&target, 100)
                .await
                .unwrap()
                .contains("hello")
            {
                break;
            }
        }
        assert!(
            terminal
                .capture(&target, 100)
                .await
                .unwrap()
                .contains("hello-from-pty")
        );
    }

    #[tokio::test]
    async fn a_finished_process_stops_being_live() {
        // This is what makes the dead-session sweep work without tmux.
        let terminal = PtyTerminal::new();
        let target = terminal
            .spawn(&SpawnSpec {
                name: "test".into(),
                cwd: ".".into(),
                command: vec!["echo".into(), "done".into()],
            })
            .await
            .unwrap();

        for _ in 0..40 {
            tokio::time::sleep(std::time::Duration::from_millis(25)).await;
            if !terminal.live_targets().await.unwrap().contains(&target) {
                break;
            }
        }
        assert!(!terminal.live_targets().await.unwrap().contains(&target));
    }

    #[tokio::test]
    async fn a_missing_binary_says_it_is_not_installed() {
        // Not "the session died". The fork would have succeeded and left a
        // handle to a process that was already gone.
        let terminal = PtyTerminal::new();
        let result = terminal
            .spawn(&SpawnSpec {
                name: "test".into(),
                cwd: ".".into(),
                command: vec!["definitely-not-a-real-binary-xyzzy".into()],
            })
            .await;
        assert!(matches!(result, Err(TerminalError::NotInstalled)));
    }

    #[test]
    fn a_binary_on_path_is_found_and_a_missing_one_is_not() {
        assert!(binary_exists("echo"));
        assert!(!binary_exists("definitely-not-a-real-binary-xyzzy"));
        assert!(!binary_exists(""));
    }

    #[test]
    fn an_explicit_path_is_checked_directly_not_looked_up() {
        // A configured custom agent may be `/opt/tools/my-agent`, which is not
        // on PATH and never will be.
        assert!(binary_exists("/bin/sh") || binary_exists("/usr/bin/env"));
        assert!(!binary_exists("/definitely/not/here"));
    }

    #[tokio::test]
    async fn typing_into_a_pane_reaches_the_process() {
        let terminal = PtyTerminal::new();
        let target = terminal
            .spawn(&SpawnSpec {
                name: "test".into(),
                cwd: ".".into(),
                command: vec!["cat".into()],
            })
            .await
            .unwrap();

        terminal.send_line(&target, "typed-line").await.unwrap();
        for _ in 0..40 {
            tokio::time::sleep(std::time::Duration::from_millis(25)).await;
            if terminal
                .capture(&target, 100)
                .await
                .unwrap()
                .contains("typed-line")
            {
                break;
            }
        }
        assert!(
            terminal
                .capture(&target, 100)
                .await
                .unwrap()
                .contains("typed-line")
        );
        terminal.kill(&target).await.unwrap();
    }

    #[tokio::test]
    async fn killing_a_pane_removes_it() {
        let terminal = PtyTerminal::new();
        let target = terminal
            .spawn(&SpawnSpec {
                name: "test".into(),
                cwd: ".".into(),
                command: vec!["cat".into()],
            })
            .await
            .unwrap();

        assert!(terminal.live_targets().await.unwrap().contains(&target));
        terminal.kill(&target).await.unwrap();
        assert!(!terminal.live_targets().await.unwrap().contains(&target));
    }

    #[tokio::test]
    async fn capturing_an_unknown_pane_is_an_error_not_a_panic() {
        let terminal = PtyTerminal::new();
        assert!(terminal.capture("pty:999", 10).await.is_err());
    }

    #[tokio::test]
    async fn killing_an_unknown_pane_is_harmless() {
        // The GC may race a process that already exited.
        let terminal = PtyTerminal::new();
        assert!(terminal.kill("pty:999").await.is_ok());
    }

    #[tokio::test]
    async fn panes_get_distinct_targets() {
        let terminal = PtyTerminal::new();
        let spec = SpawnSpec {
            name: "test".into(),
            cwd: ".".into(),
            command: vec!["cat".into()],
        };
        let first = terminal.spawn(&spec).await.unwrap();
        let second = terminal.spawn(&spec).await.unwrap();
        assert_ne!(first, second);
        terminal.kill(&first).await.unwrap();
        terminal.kill(&second).await.unwrap();
    }
}
