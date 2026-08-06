//! systemd units, generated with this machine's actual paths in them.
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
    /// Absolute path to the `forge-runner` binary.
    pub binary: String,
    /// The user the service runs as.
    pub user: String,
    /// Working directory — where `forge.db`, `forge.key` and
    /// `forge.policy.toml` are resolved from.
    pub working_dir: String,
    /// `--relay wss://…`, if this machine should be reachable remotely.
    pub relay: Option<String>,
}

impl ServiceSpec {
    /// Resolve from the running process and environment.
    pub fn detect(relay: Option<String>) -> Self {
        let binary = std::env::current_exe()
            .map(|path| path.display().to_string())
            // A relative name still works if it is on the service's PATH, which
            // is a fair fallback for a build tree.
            .unwrap_or_else(|_| "forge-runner".to_owned());

        let working_dir = std::env::current_dir()
            .map(|path| path.display().to_string())
            .unwrap_or_else(|_| "/var/lib/relayforge".to_owned());

        let user = std::env::var("SUDO_USER")
            .or_else(|_| std::env::var("USER"))
            .or_else(|_| std::env::var("LOGNAME"))
            .unwrap_or_else(|_| "relayforge".to_owned());

        Self {
            binary,
            user,
            working_dir,
            relay,
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
Description=RelayForge runner — supervises AI coding agents
Documentation=https://github.com/relayforge/relayforge
# Sessions and the relay link both need the network to be up, not merely
# configured; `network-online` is the one that means what it says.
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User={user}
WorkingDirectory={working_dir}
ExecStart={binary} serve --db {working_dir}/forge.db --key {working_dir}/forge.key{relay}

# The runner dials out and never listens on a public port, so a restart is
# always safe — no connection is being held open on its behalf.
Restart=always
RestartSec=5

# Read from an EnvironmentFile rather than being written into the unit: an
# ANTHROPIC_API_KEY in a unit file ends up in `systemctl cat` output, in
# journald, and in your shell history.
EnvironmentFile=-{working_dir}/forge.env

# Cheap hardening. Deliberately not ProtectHome or ReadOnlyPaths: the runner's
# job is running agents in your repositories, and a unit that sandboxed those
# away is a unit nobody would keep.
NoNewPrivileges=true
PrivateTmp=true

# Agent output goes to the journal, so `journalctl -u relayforge -f` is the
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
Description=RelayForge relay — encrypted fan-out, holds no keys
Documentation=https://github.com/relayforge/relayforge
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
            binary: "/usr/local/bin/forge-runner".into(),
            user: "dev".into(),
            working_dir: "/var/lib/relayforge".into(),
            relay: None,
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
    fn the_relay_unit_is_well_formed() {
        assert_well_formed(&spec().relay_unit("/usr/local/bin/forge-relay", 7843, "mailto:a@b.c"));
    }

    #[test]
    fn the_runner_unit_carries_this_machines_paths() {
        // The whole reason this is generated rather than pasted: a hand-edited
        // unit with the wrong WorkingDirectory starts fine and silently uses a
        // different database.
        let unit = spec().runner_unit();
        assert!(unit.contains("User=dev"));
        assert!(unit.contains("WorkingDirectory=/var/lib/relayforge"));
        assert!(unit.contains("/usr/local/bin/forge-runner serve"));
        assert!(unit.contains("--db /var/lib/relayforge/forge.db"));
        assert!(unit.contains("--key /var/lib/relayforge/forge.key"));
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
        let unit = spec().relay_unit("/usr/local/bin/forge-relay", 7843, "mailto:a@b.c");
        assert!(unit.contains("ProtectSystem=strict"));
        assert!(unit.contains("ProtectHome=true"));
        // But it must still be able to write the VAPID key it mints on first
        // start — losing that unpairs every push subscription.
        assert!(unit.contains("ReadWritePaths=/var/lib/relayforge"));
        assert!(unit.contains("--vapid-key /var/lib/relayforge/vapid.key"));
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
            spec().relay_unit("/usr/local/bin/forge-relay", 7843, "mailto:a@b.c"),
        ] {
            assert!(unit.contains("After=network-online.target"));
            assert!(unit.contains("Wants=network-online.target"));
        }
    }
}
