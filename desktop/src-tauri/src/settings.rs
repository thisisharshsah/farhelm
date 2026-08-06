//! Where the desktop app keeps its state.
//!
//! Not next to the binary. A desktop app is installed to a read-only location on
//! macOS and to `Program Files` on Windows, so the CLI's habit of writing
//! `forge.db` into the working directory is not available — and would be the
//! wrong place anyway, because the working directory of a GUI app is arbitrary.
//!
//! Everything lives in one per-user directory, so "where is my data" and "how do
//! I start over" both have a one-sentence answer.

use std::path::PathBuf;

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct Settings {
    /// `wss://…` of a relay, if this machine should be reachable remotely.
    ///
    /// Absent by default. A machine that has not been told about a relay is
    /// loopback-only, which is the safe thing to be until someone asks for more.
    pub relay: Option<String>,
}

impl Settings {
    /// `~/Library/Application Support/RelayForge`, `%APPDATA%\RelayForge`, or
    /// `~/.local/share/relayforge`.
    pub fn directory() -> PathBuf {
        let base = if cfg!(target_os = "macos") {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .map(|home| home.join("Library/Application Support"))
        } else if cfg!(target_os = "windows") {
            std::env::var_os("APPDATA").map(PathBuf::from)
        } else {
            std::env::var_os("XDG_DATA_HOME")
                .map(PathBuf::from)
                .or_else(|| {
                    std::env::var_os("HOME")
                        .map(PathBuf::from)
                        .map(|home| home.join(".local/share"))
                })
        };

        let directory =
            base.unwrap_or_else(std::env::temp_dir)
                .join(if cfg!(target_os = "linux") {
                    "relayforge"
                } else {
                    "RelayForge"
                });
        // Created eagerly: the key file is written with `0600` at creation, and
        // that guarantee is only meaningful if the directory it lands in exists.
        let _ = std::fs::create_dir_all(&directory);
        directory
    }

    pub fn path() -> PathBuf {
        Self::directory().join("settings.json")
    }

    pub fn database_path(&self) -> PathBuf {
        Self::directory().join("forge.db")
    }

    /// This machine's long-term keypair. Devices pair against its public half,
    /// so losing it unpairs every one of them.
    pub fn key_path(&self) -> PathBuf {
        Self::directory().join("forge.key")
    }

    /// Read the settings, falling back to defaults.
    ///
    /// A corrupt file is treated as absent rather than fatal: refusing to start
    /// over a malformed JSON field would strand someone with no way to fix it
    /// except finding the file by hand.
    pub fn load() -> Self {
        std::fs::read_to_string(Self::path())
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) -> std::io::Result<()> {
        std::fs::write(Self::path(), serde_json::to_string_pretty(self)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_file_lives_in_one_directory() {
        // So "where is my data" and "how do I start over" have one answer.
        let settings = Settings::default();
        let directory = Settings::directory();
        assert!(settings.database_path().starts_with(&directory));
        assert!(settings.key_path().starts_with(&directory));
        assert!(Settings::path().starts_with(&directory));
    }

    #[test]
    fn a_machine_is_loopback_only_until_it_is_told_otherwise() {
        assert_eq!(Settings::default().relay, None);
    }

    #[test]
    fn a_corrupt_settings_file_is_not_fatal() {
        // Refusing to start over a malformed field would strand someone with no
        // way to fix it but to find the file by hand. `load` turns this `None`
        // into defaults.
        assert!(serde_json::from_str::<Settings>("{ not json").is_err());
        assert!(serde_json::from_str::<Settings>("{}").is_ok());
    }

    #[test]
    fn a_relay_survives_a_round_trip() {
        let settings = Settings {
            relay: Some("wss://relay.example".into()),
        };
        let json = serde_json::to_string(&settings).unwrap();
        assert_eq!(
            serde_json::from_str::<Settings>(&json).unwrap().relay,
            settings.relay
        );
    }
}
