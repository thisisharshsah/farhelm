//! What this machine still needs, and the front door that says so.
//!
//! Setting Farhelm up used to be a document: build two binaries, build the web
//! app, make a directory, `cd` into it, pick route A or route B, export a
//! credential, paste a settings block, write a unit file. Every one of those is
//! something the program knows how to do, and every one of them is a place to
//! get it wrong quietly — the failure mode of most of them is a daemon that
//! starts, looks healthy, and supervises nothing.
//!
//! So this module answers one question — *what is not set up here yet* — and
//! everything user-facing is a rendering of that answer:
//!
//! - `farhelm` with no arguments shows where you stand and the one command that
//!   moves you forward. Not a hundred lines of usage: somebody typing the bare
//!   name is asking "what is this and what do I do", and a wall of flags
//!   answers neither.
//! - `farhelm setup` walks the same list, doing each step.
//! - `farhelm doctor` checks a *finished* setup for things that have since
//!   broken. The two are deliberately different questions, and answering them
//!   with one command would mean answering both badly.
//!
//! The order of [`Step`] is the order things block each other in, not the order
//! they were built. A model credential comes before hooks because an agent with
//! hooks and no gateway can be supervised but cannot be paid for; the fleet
//! comes before running at login because a daemon that survives a reboot and
//! cannot be reached from your phone is a daemon you will not use.

use std::path::{Path, PathBuf};

/// Where the hook bridge is registered, which is what decides whether anything
/// an agent does ever reaches this runner.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookScope {
    /// Nowhere. An agent runs unsupervised and nothing appears in the fleet.
    None,
    /// One repository. Fine, and quietly surprising in every other repository.
    Repo,
    /// `~/.claude/settings.json` — every repo on this machine.
    Global,
}

impl HookScope {
    /// How to say it in one line.
    pub fn describe(self) -> &'static str {
        match self {
            HookScope::None => "not installed — an agent's tool calls reach nothing",
            HookScope::Repo => "this repo only",
            HookScope::Global => "every repo on this machine",
        }
    }
}

/// Where this machine has got to.
///
/// Deliberately just facts. Deciding what they *mean* is [`Standing::remaining`],
/// so the decision can be tested without arranging a filesystem.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Standing {
    /// A database exists, so this directory has been used before.
    pub started_before: bool,
    /// Enrolled with a control plane: reachable from a phone.
    pub in_a_fleet: bool,
    /// A model credential is stored, so agent tasks can run.
    pub has_credential: bool,
    /// Where the hook bridge is registered.
    pub hooks: HookScope,
    /// Registered to start at login or boot.
    pub runs_at_login: bool,
    /// Agents installed on this machine, by display name.
    pub agents: Vec<String>,
}

/// One thing left to do, in the order it blocks you.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    /// Sign in to a model provider, or store an API key.
    Credential,
    /// Register the hook bridge.
    Hooks,
    /// Join a workspace, so a phone can reach this machine.
    Fleet,
    /// Keep the daemon running across reboots.
    Service,
}

impl Step {
    /// The short label, for a checklist.
    pub fn title(self) -> &'static str {
        match self {
            Step::Credential => "a model credential",
            Step::Hooks => "supervision",
            Step::Fleet => "your fleet",
            Step::Service => "run at login",
        }
    }

    /// What is actually lost by skipping it. Every step is skippable, so each
    /// one has to say what it costs rather than insisting.
    pub fn why(self) -> &'static str {
        match self {
            Step::Credential => "without one, agent tasks cannot run at all",
            Step::Hooks => {
                "without them, an agent's tool calls reach nothing and \
                            you supervise nothing"
            }
            Step::Fleet => {
                "without it, this machine is reachable from this \
                            browser and nowhere else"
            }
            Step::Service => {
                "without it, supervision stops the next time this \
                              machine reboots"
            }
        }
    }

    /// The command that does it, for anyone who would rather type than be asked.
    pub fn command(self) -> &'static str {
        match self {
            Step::Credential => "farhelm auth",
            Step::Hooks => "farhelm install-hooks --global",
            Step::Fleet => "farhelm login --cloud <url>",
            Step::Service => "farhelm install-service",
        }
    }
}

impl Standing {
    /// Read it off the filesystem.
    ///
    /// Everything here is a file test, deliberately: `read` is called before the
    /// daemon is necessarily running, and a front door that hangs on a network
    /// timeout to tell you nothing is set up would be worse than no front door.
    /// Whether a *running* system still works is [`crate::api`]'s `/v1/status`,
    /// which `doctor` asks.
    pub fn read(db: &Path, cloud_file: &Path, credential_file: &Path) -> Self {
        Self {
            started_before: db.exists(),
            in_a_fleet: cloud_file.exists(),
            has_credential: credential_file.exists(),
            hooks: hook_scope(),
            runs_at_login: runs_at_login(),
            agents: Vec::new(),
        }
    }

    /// Everything still undone, in the order it blocks you.
    pub fn remaining(&self) -> Vec<Step> {
        let mut steps = Vec::new();
        if !self.has_credential {
            steps.push(Step::Credential);
        }
        if self.hooks == HookScope::None {
            steps.push(Step::Hooks);
        }
        if !self.in_a_fleet {
            steps.push(Step::Fleet);
        }
        if !self.runs_at_login {
            steps.push(Step::Service);
        }
        steps
    }

    /// Nothing left to ask about.
    pub fn is_complete(&self) -> bool {
        self.remaining().is_empty()
    }
}

/// Whether the hook bridge is registered, and how widely.
///
/// Both spellings count. A machine set up before the rename has
/// `forge-runner hook` in its settings, and reporting that as "no hooks" would
/// send somebody to reinstall supervision they already have — and, worse, make
/// them doubt the supervision that is working.
fn hook_scope() -> HookScope {
    let mentions_the_bridge = |path: PathBuf| {
        std::fs::read_to_string(path)
            .map(|text| text.contains("farhelm hook") || text.contains("forge-runner hook"))
            .unwrap_or(false)
    };

    if let Some(home) = std::env::var_os("HOME")
        && mentions_the_bridge(PathBuf::from(home).join(".claude").join("settings.json"))
    {
        return HookScope::Global;
    }
    if mentions_the_bridge(PathBuf::from(".claude").join("settings.json")) {
        return HookScope::Repo;
    }
    HookScope::None
}

/// Whether something will start the daemon without being asked.
///
/// A file test rather than `launchctl list` or `systemctl is-enabled`: this runs
/// on the front door, where shelling out twice to answer a line of text is a
/// visible pause for no gain. A stale unit file reads as "installed", which is
/// the answer that sends someone to look at it — which is where the truth is.
///
/// The pre-rename labels count. A machine set up before this system had one
/// name is running `com.relayforge.runner` right now, and telling its owner to
/// install a service would have them install a *second* one, fighting the first
/// for the same port. Anything that was already true has to keep reading as
/// true.
fn runs_at_login() -> bool {
    const AGENTS: &[&str] = &[
        "Library/LaunchAgents/com.farhelm.runner.plist",
        "Library/LaunchAgents/com.relayforge.runner.plist",
        ".config/systemd/user/farhelm.service",
        ".config/systemd/user/forge-runner.service",
    ];
    const SYSTEM: &[&str] = &[
        "/etc/systemd/system/farhelm.service",
        "/etc/systemd/system/forge-runner.service",
    ];

    if let Some(home) = std::env::var_os("HOME") {
        let home = PathBuf::from(home);
        if AGENTS.iter().any(|unit| home.join(unit).exists()) {
            return true;
        }
    }
    SYSTEM.iter().any(|unit| Path::new(unit).exists())
}

/// What a bare `farhelm` prints.
///
/// Three sections at most: what is true, what to do next, and where the rest is.
/// It has to fit on a phone-sized terminal without scrolling, because the moment
/// it does not, it becomes the usage dump it replaced.
pub fn front_door(standing: &Standing, version: &str) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "\n  \u{1b}[1mfarhelm\u{1b}[0m {version} — supervise your coding agents from anywhere\n\n"
    ));

    let remaining = standing.remaining();

    if !standing.started_before && remaining.len() == 4 {
        // A genuinely fresh directory. Nothing to report about it, so do not
        // print a status block of four crosses — that reads as breakage rather
        // than as a beginning.
        out.push_str("  Nothing is set up here yet.\n\n");
        out.push_str("    \u{1b}[1mfarhelm setup\u{1b}[0m    do it now — a few questions, and it explains each one\n");
        out.push_str("    farhelm serve    skip all of it and start on loopback\n");
        out.push_str("    farhelm help     every command\n\n");
        return out;
    }

    out.push_str(&line(
        standing.has_credential,
        "model",
        if standing.has_credential {
            "a credential is stored"
        } else {
            "none stored"
        },
    ));
    out.push_str(&line(
        standing.hooks != HookScope::None,
        "supervision",
        standing.hooks.describe(),
    ));
    out.push_str(&line(
        standing.in_a_fleet,
        "fleet",
        if standing.in_a_fleet {
            "enrolled"
        } else {
            "loopback only"
        },
    ));
    out.push_str(&line(
        standing.runs_at_login,
        "at login",
        if standing.runs_at_login {
            "yes"
        } else {
            "no — supervision stops at the next reboot"
        },
    ));

    out.push('\n');
    match remaining.first() {
        Some(step) => {
            out.push_str(&format!(
                "  {} left. \u{1b}[1mfarhelm setup\u{1b}[0m walks them, or do this one:\n",
                match remaining.len() {
                    1 => "One thing".to_owned(),
                    n => format!("{n} things"),
                }
            ));
            out.push_str(&format!("    {}\n", step.command()));
        }
        None => {
            out.push_str("  Set up. \u{1b}[1mfarhelm serve\u{1b}[0m to start it, `farhelm doctor` if something is off.\n");
        }
    }
    out.push_str("\n  farhelm help     every command\n\n");
    out
}

fn line(ok: bool, label: &str, detail: &str) -> String {
    let mark = if ok { "\u{2713}" } else { "\u{2717}" };
    format!("  {mark} {label:<12} {detail}\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn nothing() -> Standing {
        Standing {
            started_before: false,
            in_a_fleet: false,
            has_credential: false,
            hooks: HookScope::None,
            runs_at_login: false,
            agents: Vec::new(),
        }
    }

    fn everything() -> Standing {
        Standing {
            started_before: true,
            in_a_fleet: true,
            has_credential: true,
            hooks: HookScope::Global,
            runs_at_login: true,
            agents: vec!["Claude Code".into()],
        }
    }

    #[test]
    fn a_finished_machine_has_nothing_to_ask() {
        assert!(everything().is_complete());
        assert_eq!(everything().remaining(), Vec::new());
    }

    #[test]
    fn the_steps_come_in_the_order_they_block_you() {
        // A credential first: hooks with no gateway supervise an agent that
        // cannot run. Running at login last: there is no point surviving a
        // reboot before there is something worth keeping alive.
        assert_eq!(
            nothing().remaining(),
            vec![Step::Credential, Step::Hooks, Step::Fleet, Step::Service]
        );
    }

    #[test]
    fn a_half_finished_machine_is_asked_only_what_is_left() {
        let mut standing = nothing();
        standing.has_credential = true;
        standing.hooks = HookScope::Repo;
        assert_eq!(standing.remaining(), vec![Step::Fleet, Step::Service]);
    }

    #[test]
    fn hooks_in_one_repo_count_as_installed() {
        // Not "half done". Per-repo is a legitimate choice, and re-asking about
        // it every time would train somebody to ignore the whole checklist.
        let mut standing = nothing();
        standing.hooks = HookScope::Repo;
        assert!(!standing.remaining().contains(&Step::Hooks));
    }

    #[test]
    fn a_fresh_directory_is_greeted_rather_than_diagnosed() {
        let text = front_door(&nothing(), "0.1.0");
        assert!(text.contains("Nothing is set up here yet"));
        assert!(
            !text.contains('\u{2717}'),
            "four crosses on a first run reads as breakage, not as a beginning"
        );
    }

    #[test]
    fn a_working_machine_is_not_told_to_set_anything_up() {
        let text = front_door(&everything(), "0.1.0");
        assert!(text.contains("Set up."));
        assert!(!text.contains("farhelm setup"));
    }

    #[test]
    fn a_partial_setup_names_the_next_command_exactly() {
        let mut standing = nothing();
        standing.started_before = true;
        standing.has_credential = true;
        standing.hooks = HookScope::Global;
        let text = front_door(&standing, "0.1.0");
        assert!(text.contains("2 things left"));
        assert!(text.contains("farhelm login --cloud"));
    }

    #[test]
    fn the_front_door_stays_short_enough_to_read() {
        // The thing it replaced was a hundred lines. If this ever grows past a
        // small terminal it has become that again, and this test is the only
        // thing that would notice.
        for standing in [nothing(), everything()] {
            let lines = front_door(&standing, "0.1.0").lines().count();
            assert!(lines <= 16, "front door grew to {lines} lines");
        }
    }
}
