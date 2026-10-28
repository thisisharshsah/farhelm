//! API clients: other projects that send their model calls through Farhelm.
//!
//! Each client has a name, which is part of its URL
//! (`http://127.0.0.1:7842/p/<name>/v1`), and a key it sends as
//! `Authorization: Bearer` or `x-api-key`. Farhelm stores only the key's
//! SHA-256, so the file can be read without exposing a key; the key itself is
//! printed once, when it is made. A client may be limited to some models and to
//! a number of tokens a day, and its usage is recorded under its own session.
//!
//! "Client" rather than "project": Farhelm's projects are something else (a
//! workspace's repositories, conversations and tasks), and two meanings for one
//! word would be read wrong sooner or later.

use std::collections::BTreeMap;
use std::path::Path;

use serde::Deserialize;

pub const DEFAULT_CLIENTS_FILE: &str = "clients.toml";
/// Recognisable in a log or a paste, so a leaked key can be found and rotated.
pub const KEY_PREFIX: &str = "fhk_";

#[derive(Debug)]
pub struct ClientsError(pub String);

impl std::fmt::Display for ClientsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ClientsError {}

fn fail(message: impl Into<String>) -> ClientsError {
    ClientsError(message.into())
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ClientsFile {
    #[serde(default)]
    pub clients: BTreeMap<String, Client>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Client {
    /// SHA-256 of the key, hex.
    pub key_sha256: String,
    /// What a request without a model, or naming one the registry does not
    /// declare, is served by. `None` leaves it to the gateway's routing.
    #[serde(default)]
    pub default_model: Option<String>,
    /// Registry models this client may name. Empty means any.
    #[serde(default)]
    pub models: Vec<String>,
    /// Input plus output tokens a day, from local midnight. `None` is no limit.
    #[serde(default)]
    pub daily_token_limit: Option<u64>,
}

pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '-' | '_'))
}

pub fn hash_key(key: &str) -> String {
    use sha2::{Digest as _, Sha256};
    format!("{:x}", Sha256::digest(key.as_bytes()))
}

/// A new key: 256 bits from the OS, behind the recognisable prefix.
pub fn new_key() -> String {
    format!("{KEY_PREFIX}{}", farhelm_cloud::secret::random_secret())
}

/// Compare without stopping at the first difference, so response time says
/// nothing about how much of a guess was right.
fn same(a: &str, b: &str) -> bool {
    a.len() == b.len()
        && a.bytes()
            .zip(b.bytes())
            .fold(0u8, |acc, (x, y)| acc | (x ^ y))
            == 0
}

impl Client {
    pub fn accepts(&self, key: &str) -> bool {
        same(&hash_key(key), &self.key_sha256)
    }

    /// Whether this client may name `model`.
    pub fn allows(&self, model: &str) -> bool {
        self.models.is_empty() || self.models.iter().any(|allowed| allowed == model)
    }
}

impl ClientsFile {
    /// `Ok(default)` when there is no file: no clients yet.
    pub fn load(path: &Path) -> Result<Self, ClientsError> {
        let text = match std::fs::read_to_string(path) {
            Ok(text) => text,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Self::default()),
            Err(err) => return Err(fail(format!("{}: {err}", path.display()))),
        };
        let file: Self =
            toml::from_str(&text).map_err(|err| fail(format!("{}: {err}", path.display())))?;
        for (name, client) in &file.clients {
            if !valid_name(name) {
                return Err(fail(format!(
                    "client name `{name}` must be lowercase letters, digits, '-' or '_'"
                )));
            }
            if client.key_sha256.len() != 64
                || !client.key_sha256.bytes().all(|b| b.is_ascii_hexdigit())
            {
                return Err(fail(format!("client `{name}` has no valid key_sha256")));
            }
        }
        Ok(file)
    }

    pub fn to_toml(&self) -> String {
        let quote = |value: &str| format!("{value:?}");
        let mut out = String::from(
            "# API clients: projects that send model calls through Farhelm at\n\
             # http://127.0.0.1:7842/p/<name>/v1. Keys are stored as SHA-256 only.\n\
             # Managed with `farhelm clients`; the runner reads this file at start.\n",
        );
        for (name, client) in &self.clients {
            out.push_str(&format!(
                "\n[clients.{name}]\nkey_sha256 = {}\n",
                quote(&client.key_sha256)
            ));
            if let Some(model) = &client.default_model {
                out.push_str(&format!("default_model = {}\n", quote(model)));
            }
            if !client.models.is_empty() {
                let list: Vec<String> = client.models.iter().map(|model| quote(model)).collect();
                out.push_str(&format!("models = [{}]\n", list.join(", ")));
            }
            if let Some(limit) = client.daily_token_limit {
                out.push_str(&format!("daily_token_limit = {limit}\n"));
            }
        }
        out
    }

    /// The client a request names, if its key is right. One answer for a
    /// missing client and a wrong key, so a caller cannot list client names.
    pub fn authenticate(&self, name: &str, key: Option<&str>) -> Option<&Client> {
        let client = self.clients.get(name)?;
        key.filter(|key| client.accepts(key)).map(|_| client)
    }
}

/// The session a client's calls are recorded under.
pub fn session_id(name: &str) -> String {
    format!("client-{name}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_key_is_checked_against_its_hash_only() {
        let key = new_key();
        assert!(key.starts_with(KEY_PREFIX));
        let mut file = ClientsFile::default();
        file.clients.insert(
            "everest".into(),
            Client {
                key_sha256: hash_key(&key),
                default_model: Some("gpt-oss-20b".into()),
                models: vec!["gpt-oss-20b".into(), "gpt-oss-c2".into()],
                daily_token_limit: Some(2_000_000),
            },
        );
        let text = file.to_toml();
        assert!(!text.contains(&key), "the key itself must never be written");
        let read: ClientsFile = toml::from_str(&text).unwrap();
        assert_eq!(read, file);

        assert!(read.authenticate("everest", Some(&key)).is_some());
        assert!(read.authenticate("everest", Some("fhk_wrong")).is_none());
        assert!(read.authenticate("everest", None).is_none());
        assert!(read.authenticate("lacuna", Some(&key)).is_none());
    }

    #[test]
    fn a_client_is_held_to_its_models() {
        let client = Client {
            key_sha256: "0".repeat(64),
            default_model: None,
            models: vec!["gpt-oss-20b".into()],
            daily_token_limit: None,
        };
        assert!(client.allows("gpt-oss-20b"));
        assert!(!client.allows("engine-code"));
        let open = Client {
            models: Vec::new(),
            ..client
        };
        assert!(open.allows("engine-code"));
    }

    #[test]
    fn names_and_hashes_are_validated() {
        let bad = "[clients.Everest]\nkey_sha256 = \"00\"\n";
        let dir = std::env::temp_dir().join(format!("farhelm-clients-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("clients.toml");
        std::fs::write(&path, bad).unwrap();
        assert!(ClientsFile::load(&path).is_err());
        assert_eq!(
            ClientsFile::load(&dir.join("absent.toml")).unwrap(),
            ClientsFile::default()
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
