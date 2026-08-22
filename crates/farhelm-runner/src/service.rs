//! Service definitions, generated with this machine's actual paths in them.
//!
//! A quickstart that says "create a unit file, substitute your paths, set your
//! user, mind the working directory" is a quickstart with four places to get it
//! wrong — and the failure mode of most of them is a service that starts, looks
//! healthy, and silently uses the wrong database.
//!
//! So the paths are resolved here and printed filled in. The only thing left to
//! decide is where it goes.
//!
//! # Why the hardening directives are not optional garnish
//!
//! The runner holds a long-term X25519 key that every paired device trusts, an
//! API key, and a database of what your agents have been doing. It also, by
//! design, executes things. `NoNewPrivileges` and `PrivateTmp` cost nothing and
//! remove whole categories of accident.
//!
//! What is deliberately *not* here is `ProtectHome` or a read-only filesystem:
//! the runner's entire job is running agents in your repositories, which live in
//! your home directory. A unit that sandboxed those away would be a unit that
//! does not work, and the version people would paste instead is the one with no
//! hardening at all.

/// What a generated unit needs to know.
pub struct ServiceSpec {
    /// Absolute path to the `farhelm` binary.
    pub binary: String,
    /// The user the service runs as.
    pub user: String,
    /// Working directory — where `farhelm.db`, `farhelm.key` and
    /// `farhelm.policy.toml` are resolved from.
    pub working_dir: String,
    /// `--relay wss://…`, if this machine should be reachable remotely.
    pub relay: Option<String>,
    /// The user's home directory, for a launchd agent's path and PATH.
    pub home: String,
}

impl ServiceSpec {
    /// Resolve from the running process and environment.
    pub fn detect(relay: Option<String>) -> Self {
        let binary = std::env::current_exe()
            .map(|path| path.display().to_string())
            // A relative name still works if it is on the service's PATH, which
            // is a fair fallback for a build tree.
            .unwrap_or_else(|_| "farhelm".to_owned());

        let working_dir = std::env::current_dir()
            .map(|path| path.display().to_string())
            .unwrap_or_else(|_| "/var/lib/farhelm".to_owned());

        let user = std::env::var("SUDO_USER")
            .or_else(|_| std::env::var("USER"))
            .or_else(|_| std::env::var("LOGNAME"))
            .unwrap_or_else(|_| "farhelm".to_owned());

        let home = std::env::var("HOME").unwrap_or_else(|_| format!("/Users/{user}"));

        Self {
            binary,
            user,
            working_dir,
            relay,
            home,
        }
    }

    /// The runner's unit.
    pub fn runner_unit(&self) -> String {
        let relay = match &self.relay {
            Some(url) => format!(" --relay {url}"),
            None => String::new(),
        };

        format!(
            r#"[Unit]
Description=Farhelm runner — supervises AI coding agents
Documentation=https://github.com/farhelm/farhelm
# Sessions and the relay link both need the network to be up, not merely
# configured; `network-online` is the one that means what it says.
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User={user}
WorkingDirectory={working_dir}
ExecStart={binary} serve --db {working_dir}/farhelm.db --key {working_dir}/farhelm.key{relay}

# The runner dials out and never listens on a public port, so a restart is
# always safe — no connection is being held open on its behalf.
Restart=always
RestartSec=5

# Read from an EnvironmentFile rather than being written into the unit: an
# ANTHROPIC_API_KEY in a unit file ends up in `systemctl cat` output, in
# journald, and in your shell history.
EnvironmentFile=-{working_dir}/farhelm.env

# Cheap hardening. Deliberately not ProtectHome or ReadOnlyPaths: the runner's
# job is running agents in your repositories, and a unit that sandboxed those
# away is a unit nobody would keep.
NoNewPrivileges=true
PrivateTmp=true

# Agent output goes to the journal, so `journalctl -u farhelm -f` is the
# answer to "what is it doing".
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
"#,
            user = self.user,
            working_dir = self.working_dir,
            binary = self.binary,
            relay = relay,
        )
    }

    /// The relay's unit, for the VPS side.
    pub fn relay_unit(&self, binary: &str, port: u16, subject: &str) -> String {
        format!(
            r#"[Unit]
Description=Farhelm relay — encrypted fan-out, holds no keys
Documentation=https://github.com/farhelm/farhelm
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User={user}
WorkingDirectory={working_dir}
ExecStart={binary} --port {port} --vapid-key {working_dir}/vapid.key --push-subject {subject}

Restart=always
RestartSec=5

# The relay keeps nothing across a restart by design, so it is safe to harden
# much more aggressively than the runner. It reads one file — the VAPID key —
# and writes it once on first start.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths={working_dir}

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
"#,
            user = self.user,
            working_dir = self.working_dir,
            binary = binary,
            port = port,
            subject = subject,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec() -> ServiceSpec {
        ServiceSpec {
            binary: "/usr/local/bin/farhelm".into(),
            user: "dev".into(),
            working_dir: "/var/lib/farhelm".into(),
            relay: None,
            home: "/home/dev".into(),
        }
    }

    /// A crude but effective check that every `[Section]` we expect is present
    /// and nothing is left as a placeholder.
    fn assert_well_formed(unit: &str) {
        for section in ["[Unit]", "[Service]", "[Install]"] {
            assert!(unit.contains(section), "missing {section}");
        }
        assert!(unit.contains("ExecStart="));
        assert!(unit.contains("WantedBy="));
        // The failure this catches: a format string that did not substitute,
        // producing a unit that starts and points at the wrong database.
        assert!(!unit.contains('{'), "unsubstituted placeholder: {unit}");
        assert!(!unit.contains('}'));
    }

    #[test]
    fn the_runner_unit_is_well_formed() {
        assert_well_formed(&spec().runner_unit());
    }

    #[test]
    fn the_launchd_agent_is_valid_xml_and_fully_substituted() {
        let plist = spec().launchd_plist();
        assert!(plist.starts_with("<?xml"));
        assert!(plist.contains("<string>com.farhelm.runner</string>"));
        assert!(plist.trim_end().ends_with("</plist>"));
        // The failure this catches is the same one `assert_well_formed` catches
        // for systemd: a placeholder that never got a value, producing a service
        // that loads and points at the wrong database.
        assert!(!plist.contains("{dir}"), "unsubstituted placeholder");
        assert!(!plist.contains("{binary}"));
    }

    #[test]
    fn the_shell_line_in_the_plist_is_escaped_for_xml() {
        // `&&` inside a <string> is not valid XML, and launchd rejects the whole
        // file rather than the one element — so the daemon silently never starts
        // and `launchctl load` is the only place it is mentioned.
        let plist = spec().launchd_plist();
        assert!(plist.contains("&amp;&amp;"));
        for (index, _) in plist.match_indices('&') {
            assert!(
                plist[index..].starts_with("&amp;")
                    || plist[index..].starts_with("&lt;")
                    || plist[index..].starts_with("&gt;"),
                "a bare & at {index} makes the plist unparseable"
            );
        }
    }

    #[test]
    fn each_platform_is_told_about_its_own_service_manager() {
        assert!(Manager::Launchd.path("/home/dev").ends_with(".plist"));
        assert!(Manager::Launchd.path("/home/dev").contains("LaunchAgents"));
        assert!(Manager::Systemd.path("/home/dev").ends_with(".service"));
        assert!(
            Manager::Launchd
                .install_commands("/x")
                .contains("launchctl")
        );
        assert!(
            Manager::Systemd
                .install_commands("/x")
                .contains("systemctl")
        );
    }

    #[test]
    fn the_relay_unit_is_well_formed() {
        assert_well_formed(&spec().relay_unit("/usr/local/bin/farhelm", 7843, "mailto:a@b.c"));
    }

    #[test]
    fn the_runner_unit_carries_this_machines_paths() {
        // The whole reason this is generated rather than pasted: a hand-edited
        // unit with the wrong WorkingDirectory starts fine and silently uses a
        // different database.
        let unit = spec().runner_unit();
        assert!(unit.contains("User=dev"));
        assert!(unit.contains("WorkingDirectory=/var/lib/farhelm"));
        assert!(unit.contains("/usr/local/bin/farhelm serve"));
        assert!(unit.contains("--db /var/lib/farhelm/farhelm.db"));
        assert!(unit.contains("--key /var/lib/farhelm/farhelm.key"));
    }

    #[test]
    fn a_relay_url_reaches_the_command_line() {
        let unit = ServiceSpec {
            relay: Some("wss://relay.example".into()),
            ..spec()
        }
        .runner_unit();
        assert!(unit.contains("--relay wss://relay.example"));
    }

    #[test]
    fn without_a_relay_the_flag_is_absent_not_empty() {
        // `--relay ` with nothing after it would be parsed as the next flag's
        // value, which is a confusing way to fail.
        let unit = spec().runner_unit();
        assert!(!unit.contains("--relay"));
    }

    #[test]
    fn the_api_key_is_read_from_a_file_never_written_into_the_unit() {
        // A key in a unit file is in `systemctl cat`, in journald, and in shell
        // history. This is the one hardening decision that is not optional.
        let unit = spec().runner_unit();
        assert!(unit.contains("EnvironmentFile=-"));
        assert!(
            !unit.contains("ANTHROPIC_API_KEY="),
            "the key must not be inlined"
        );
    }

    #[test]
    fn a_missing_environment_file_does_not_stop_the_service() {
        // The `-` prefix. Running without a provider is supported — the API and
        // the app still work — so a missing forge.env must not be fatal.
        assert!(spec().runner_unit().contains("EnvironmentFile=-"));
    }

    #[test]
    fn the_runner_restarts_but_is_not_sandboxed_away_from_your_repos() {
        // A unit that cannot see your home directory cannot run an agent in your
        // repository, and the version people would paste instead has no
        // hardening at all.
        let unit = spec().runner_unit();
        assert!(unit.contains("Restart=always"));
        assert!(unit.contains("NoNewPrivileges=true"));
        assert!(!unit.contains("ProtectHome=true"));
    }

    #[test]
    fn the_relay_is_hardened_harder_because_it_holds_nothing() {
        // It keeps no state across a restart by design, so there is nothing to
        // lose by locking it down.
        let unit = spec().relay_unit("/usr/local/bin/farhelm", 7843, "mailto:a@b.c");
        assert!(unit.contains("ProtectSystem=strict"));
        assert!(unit.contains("ProtectHome=true"));
        // But it must still be able to write the VAPID key it mints on first
        // start — losing that unpairs every push subscription.
        assert!(unit.contains("ReadWritePaths=/var/lib/farhelm"));
        assert!(unit.contains("--vapid-key /var/lib/farhelm/vapid.key"));
    }

    #[test]
    fn detection_never_produces_an_empty_field() {
        // A unit with `User=` or an empty ExecStart fails to start with an error
        // that does not name the cause.
        let detected = ServiceSpec::detect(None);
        assert!(!detected.binary.is_empty());
        assert!(!detected.user.is_empty());
        assert!(!detected.working_dir.is_empty());
        assert_well_formed(&detected.runner_unit());
    }

    #[test]
    fn both_units_wait_for_the_network_to_be_up() {
        // Not merely `network.target`, which means "configured" and fires before
        // anything is actually reachable — the relay link would fail its first
        // dial on every boot.
        for unit in [
            spec().runner_unit(),
            spec().relay_unit("/usr/local/bin/farhelm", 7843, "mailto:a@b.c"),
        ] {
            assert!(unit.contains("After=network-online.target"));
            assert!(unit.contains("Wants=network-online.target"));
        }
    }
}

/// Which service manager this machine actually has.
///
/// `install-service` printed a systemd unit unconditionally, which on macOS is
/// a page of text that cannot be used for anything — the platform most likely
/// to be somebody's laptop was the one told to configure Linux. The answer to
/// "keep it running" has to be the answer for the machine you are on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Manager {
    Launchd,
    Systemd,
}

impl Manager {
    /// What this platform uses.
    pub fn detect() -> Self {
        if cfg!(target_os = "macos") {
            Manager::Launchd
        } else {
            Manager::Systemd
        }
    }

    /// Where the generated file belongs.
    pub fn path(self, home: &str) -> String {
        match self {
            Manager::Launchd => format!("{home}/Library/LaunchAgents/{LAUNCHD_LABEL}.plist"),
            Manager::Systemd => "/etc/systemd/system/farhelm.service".to_owned(),
        }
    }

    /// The lines that install and start it, once the file is in place.
    pub fn install_commands(self, path: &str) -> String {
        match self {
            Manager::Launchd => format!(
                "launchctl unload {path} 2>/dev/null\n\
                 launchctl load -w {path}\n\
                 launchctl list | grep {LAUNCHD_LABEL}"
            ),
            Manager::Systemd => "sudo systemctl daemon-reload\n\
                                 sudo systemctl enable --now farhelm\n\
                                 journalctl -u farhelm -f"
                .to_owned(),
        }
    }
}

/// The launchd label. Also what [`crate::setup`] looks for to decide whether
/// this machine already starts the daemon by itself.
pub const LAUNCHD_LABEL: &str = "com.farhelm.runner";

impl ServiceSpec {
    /// The launchd agent, for macOS.
    ///
    /// Two details here are the ones that go wrong by hand. launchd starts a job
    /// with a minimal PATH, so an agent installed under a user prefix is
    /// invisible to it and the daemon reports "no agents installed" on a machine
    /// that plainly has them — so PATH is set explicitly. And the environment
    /// file is sourced by a shell rather than declared, because launchd has no
    /// equivalent of systemd's `EnvironmentFile` and the alternative is a
    /// credential written into the plist, where `launchctl print` will read it
    /// back out.
    pub fn launchd_plist(&self) -> String {
        let relay = match &self.relay {
            Some(url) => format!(" --relay {url}"),
            None => String::new(),
        };
        let dir = &self.working_dir;

        format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>{label}</string>
	<key>ProcessType</key>
	<string>Background</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<key>WorkingDirectory</key>
	<string>{dir}</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>{home}/.local/bin:{home}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
	</dict>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>-c</string>
		<string>[ -f {dir}/farhelm.env ] &amp;&amp; {{ set -a; . {dir}/farhelm.env; set +a; }}; exec {binary} serve --db {dir}/farhelm.db --key {dir}/farhelm.key{relay}</string>
	</array>
	<key>StandardOutPath</key>
	<string>{dir}/farhelm.log</string>
	<key>StandardErrorPath</key>
	<string>{dir}/farhelm.log</string>
</dict>
</plist>
"#,
            label = LAUNCHD_LABEL,
            dir = dir,
            home = self.home,
            binary = self.binary,
            relay = relay,
        )
    }
}
