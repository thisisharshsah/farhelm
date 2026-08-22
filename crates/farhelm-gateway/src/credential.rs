//! Where the bearer token comes from, and who keeps it fresh.
//!
//! # The problem with reading a token once
//!
//! A Console API key is a long-lived secret: read it from the environment at
//! startup, hold it forever, done. A *subscription* token is not. It expires in
//! hours, and a client that captured one at startup begins returning 401s in
//! the middle of an afternoon with no explanation on screen — and the fix is to
//! paste a new token and restart, which is precisely the chore nobody should be
//! doing twice.
//!
//! So a credential here is not a string. It is **a way of obtaining a string**,
//! re-run when the last one is close to expiring or when the provider rejects
//! it.
//!
//! # Why a command rather than a built-in login
//!
//! Because the token already exists. Whatever tool the person signed in with —
//! Claude Code, `ant`, a Workload Identity Federation exchange in CI — owns the
//! refresh flow, holds the refresh token, and stores it wherever that platform
//! thinks secrets belong. Re-implementing that here would mean a second copy of
//! an OAuth client, a second place a refresh token is written, and a second
//! thing to keep current when the flow changes.
//!
//! Running a command that prints a token has none of those problems and works
//! with any of them. It is also the only design that lets someone use a source
//! this file has never heard of.
//!
//! # What is deliberately not done
//!
//! Nothing here writes a token to disk, and nothing logs one. The command's
//! output is held in memory for the life of the process and replaced when it
//! ages out. On failure the *command* is named in the error and its output is
//! not, because a credential helper that fails often fails by printing
//! something sensitive to stderr.

use std::process::Command;
use std::sync::RwLock;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Refresh this long before the token actually expires.
///
/// A call that starts valid and ends expired still fails, so the window has to
/// cover the slowest request the gateway will make. Model calls can run for
/// minutes; five of them is comfortable without refreshing so eagerly that a
/// short-lived token is re-fetched on every request.
const REFRESH_MARGIN: Duration = Duration::from_secs(5 * 60);

/// Assumed lifetime when the helper prints a bare token and no expiry.
///
/// Short on purpose. Guessing long means discovering the mistake as a 401 in
/// the middle of somebody's work; guessing short costs one extra subprocess.
const ASSUMED_LIFETIME: Duration = Duration::from_secs(15 * 60);

/// Written out by hand, like every other error in this crate.
///
/// Each variant names the *program* — the first word of the command — because
/// the first question on a credential failure is always "which helper".
///
/// Not the whole command line, and not the helper's output. Both can hold a
/// secret: a helper that fails often prints one while complaining, and a
/// command configured as `echo sk-ant-…` carries one in its arguments. Either
/// would end up in a log file that is not treated as a secret. A test holds
/// this, and it caught the argument case rather than the one it was aimed at.
#[derive(Debug)]
pub enum CredentialError {
    NotRunnable { command: String, detail: String },
    Failed { command: String, status: String },
    Empty { command: String },
}

impl std::fmt::Display for CredentialError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotRunnable { command, detail } => {
                write!(
                    f,
                    "the credential command `{command}` could not be run: {detail}"
                )
            }
            Self::Failed { command, status } => {
                write!(
                    f,
                    "the credential command `{command}` exited with status {status}"
                )
            }
            Self::Empty { command } => {
                write!(f, "the credential command `{command}` printed nothing")
            }
        }
    }
}

impl std::error::Error for CredentialError {}

/// A token, and when it stops being one.
#[derive(Debug, Clone)]
pub struct Held {
    token: String,
    /// Unix milliseconds. `None` when the helper did not say.
    expires_at: Option<u64>,
}

impl Held {
    fn stale(&self, now_ms: u64) -> bool {
        match self.expires_at {
            Some(at) => at.saturating_sub(REFRESH_MARGIN.as_millis() as u64) <= now_ms,
            None => true,
        }
    }
}

/// How the client gets a token when it needs one.
#[derive(Debug)]
pub enum CredentialSource {
    /// A fixed secret from the environment. Never refreshed, because a Console
    /// key has nothing to refresh to.
    Static(super::dispatch::Credential),
    /// A shell command printing a bearer token, re-run as it ages out.
    Command {
        command: String,
        held: RwLock<Option<Held>>,
    },
}

impl CredentialSource {
    pub fn command(command: impl Into<String>) -> Self {
        Self::Command {
            command: command.into(),
            held: RwLock::new(None),
        }
    }

    /// The credential to send on the next request.
    pub fn get(&self) -> Result<super::dispatch::Credential, CredentialError> {
        match self {
            Self::Static(credential) => Ok(credential.clone()),
            Self::Command { command, held } => {
                let now = now_ms();

                // Read lock first: the overwhelmingly common case is a token
                // that is still good, and that path must not serialise every
                // request behind a writer.
                if let Ok(guard) = held.read()
                    && let Some(current) = guard.as_ref()
                    && !current.stale(now)
                {
                    return Ok(super::dispatch::Credential::AuthToken(
                        current.token.clone(),
                    ));
                }

                let fresh = run(command)?;
                let token = fresh.token.clone();
                if let Ok(mut guard) = held.write() {
                    *guard = Some(fresh);
                }
                Ok(super::dispatch::Credential::AuthToken(token))
            }
        }
    }

    /// Drop what is held, so the next `get` re-runs the command.
    ///
    /// Called when the provider rejects a token the source still believed in —
    /// a revoked session, or a clock further out than the refresh margin. One
    /// forced refresh is a better answer than failing every request until the
    /// stated expiry passes.
    pub fn invalidate(&self) {
        if let Self::Command { held, .. } = self
            && let Ok(mut guard) = held.write()
        {
            *guard = None;
        }
    }

    pub fn kind(&self) -> &'static str {
        match self {
            Self::Static(super::dispatch::Credential::ApiKey(_)) => "api key",
            Self::Static(super::dispatch::Credential::AuthToken(_)) => "auth token",
            Self::Command { .. } => "auth token (refreshed on demand)",
        }
    }
}

/// Run the helper and read a token out of whatever it printed.
///
/// Two output shapes are accepted because both are what real helpers emit: a
/// bare token on stdout, or a JSON object holding one. The JSON form is
/// preferred when present since it can carry an expiry, and an expiry the
/// helper actually knows beats this file's assumption.
fn run(command: &str) -> Result<Held, CredentialError> {
    let program = program_of(command);
    let output = Command::new("/bin/sh")
        .arg("-c")
        .arg(command)
        .output()
        .map_err(|err| CredentialError::NotRunnable {
            command: program.clone(),
            detail: err.to_string(),
        })?;

    if !output.status.success() {
        return Err(CredentialError::Failed {
            command: program,
            status: output.status.to_string(),
        });
    }

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if stdout.is_empty() {
        return Err(CredentialError::Empty { command: program });
    }

    if let Ok(value) = serde_json::from_str::<serde_json::Value>(&stdout)
        && let Some(held) = from_json(&value)
    {
        return Ok(held);
    }

    Ok(Held {
        token: stdout,
        expires_at: Some(now_ms() + ASSUMED_LIFETIME.as_millis() as u64),
    })
}

/// Pull a token and expiry out of a helper's JSON, wherever it put them.
///
/// Nested under a provider-specific key in at least one real store, so the
/// search descends one level rather than insisting on a shape.
fn from_json(value: &serde_json::Value) -> Option<Held> {
    fn token_of(object: &serde_json::Value) -> Option<Held> {
        let token = ["accessToken", "access_token", "token"]
            .iter()
            .find_map(|key| object.get(key).and_then(|value| value.as_str()))?;
        let expires_at = ["expiresAt", "expires_at"]
            .iter()
            .find_map(|key| object.get(key).and_then(|value| value.as_u64()));
        Some(Held {
            token: token.to_owned(),
            expires_at,
        })
    }

    token_of(value).or_else(|| value.as_object()?.values().find_map(token_of))
}

/// The first word of a command line — enough to say which helper, without
/// repeating arguments that may hold a secret.
fn program_of(command: &str) -> String {
    command
        .split_whitespace()
        .next()
        .unwrap_or("(empty)")
        .to_owned()
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|since| since.as_millis() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_bare_token_is_taken_as_printed() {
        let source = CredentialSource::command("printf 'tok-abc'");
        let credential = source.get().unwrap();
        assert!(matches!(
            credential,
            super::super::dispatch::Credential::AuthToken(token) if token == "tok-abc"
        ));
    }

    #[test]
    fn trailing_whitespace_does_not_become_part_of_the_token() {
        // A helper that ends with a newline is the normal case, and a header
        // containing one is rejected by the provider as malformed rather than
        // as unauthorised — which sends the reader hunting the wrong bug.
        let source = CredentialSource::command("echo 'tok-nl'");
        let credential = source.get().unwrap();
        assert!(matches!(
            credential,
            super::super::dispatch::Credential::AuthToken(token) if token == "tok-nl"
        ));
    }

    #[test]
    fn json_output_is_read_including_its_expiry() {
        let source = CredentialSource::command(
            r#"printf '{"accessToken":"tok-json","expiresAt":4102444800000}'"#,
        );
        assert!(matches!(
            source.get().unwrap(),
            super::super::dispatch::Credential::AuthToken(token) if token == "tok-json"
        ));
    }

    #[test]
    fn a_token_nested_one_level_down_is_still_found() {
        // The shape Claude Code's own credential store uses.
        let source = CredentialSource::command(
            r#"printf '{"claudeAiOauth":{"accessToken":"tok-nested","expiresAt":4102444800000}}'"#,
        );
        assert!(matches!(
            source.get().unwrap(),
            super::super::dispatch::Credential::AuthToken(token) if token == "tok-nested"
        ));
    }

    #[test]
    fn a_live_token_is_reused_rather_than_re_fetched() {
        // The helper appends on each run, so a second subprocess would change
        // the answer. It must not: refreshing per request would fork a process
        // on every model call.
        let dir = std::env::temp_dir().join(format!("forge-cred-{}", std::process::id()));
        let _ = std::fs::remove_file(&dir);
        let source = CredentialSource::command(format!(
            r#"echo x >> {0}; printf '{{"accessToken":"tok-%s","expiresAt":4102444800000}}' $(wc -l < {0} | tr -d ' ')"#,
            dir.display()
        ));

        let first = source.get().unwrap();
        let second = source.get().unwrap();
        assert_eq!(format!("{first:?}"), format!("{second:?}"));
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn an_expired_token_is_re_fetched() {
        let dir = std::env::temp_dir().join(format!("forge-cred-exp-{}", std::process::id()));
        let _ = std::fs::remove_file(&dir);
        // Expiry in 1970: always stale.
        let source = CredentialSource::command(format!(
            r#"echo x >> {0}; printf '{{"accessToken":"tok-%s","expiresAt":1}}' $(wc -l < {0} | tr -d ' ')"#,
            dir.display()
        ));

        let first = format!("{:?}", source.get().unwrap());
        let second = format!("{:?}", source.get().unwrap());
        assert_ne!(first, second);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn invalidating_forces_the_next_call_to_re_run() {
        let dir = std::env::temp_dir().join(format!("forge-cred-inv-{}", std::process::id()));
        let _ = std::fs::remove_file(&dir);
        let source = CredentialSource::command(format!(
            r#"echo x >> {0}; printf '{{"accessToken":"tok-%s","expiresAt":4102444800000}}' $(wc -l < {0} | tr -d ' ')"#,
            dir.display()
        ));

        let first = format!("{:?}", source.get().unwrap());
        source.invalidate();
        let second = format!("{:?}", source.get().unwrap());
        assert_ne!(first, second);
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn a_failing_helper_names_its_program_and_leaks_nothing_else() {
        // The secret appears twice on purpose: once in the command's arguments
        // and once on its stderr. Neither may reach the message. The first of
        // those is why this test exists — the original version reported the
        // whole command line, so a helper written as `echo sk-ant-…` printed
        // its own credential into the log.
        let source = CredentialSource::command("printf 'sk-ant-leaked' >&2; exit 3");
        let rendered = source.get().unwrap_err().to_string();

        assert!(rendered.contains("printf"), "should name the helper");
        assert!(!rendered.contains("sk-ant-leaked"));
    }

    #[test]
    fn a_silent_helper_is_an_error_rather_than_an_empty_token() {
        // An empty bearer header is a 401 from the provider, which reads as
        // "your subscription is wrong" instead of "your helper printed nothing".
        let source = CredentialSource::command("true");
        assert!(matches!(
            source.get().unwrap_err(),
            CredentialError::Empty { .. }
        ));
    }
}
