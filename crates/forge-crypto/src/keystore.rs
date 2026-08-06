//! Where the runner's long-term secret key lives.
//!
//! §7 says keys go in platform keystores on the *devices*. The runner is a
//! headless daemon on a VPS with no keychain, so its key is a file — which makes
//! the file's permissions the entire access control. Two rules follow:
//!
//! 1. The file is created `0600` **before** any key material is written to it,
//!    never written first and chmod-ed after. That gap is a real window on a
//!    shared box.
//! 2. Loading a key from a world- or group-readable file is refused outright.
//!    Silently continuing would mean the daemon looks healthy while its identity
//!    is readable by every user on the machine.

use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};

use crate::{CryptoError, Identity};

/// Permission bits that must not be set on a key file.
#[cfg(unix)]
const FORBIDDEN_BITS: u32 = 0o077;

#[derive(Debug)]
pub enum KeystoreError {
    Io(std::io::Error),
    Crypto(CryptoError),
    /// The file is readable by someone other than its owner.
    TooPermissive {
        path: PathBuf,
        mode: u32,
    },
}

impl std::fmt::Display for KeystoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            KeystoreError::Io(err) => write!(f, "keystore: {err}"),
            KeystoreError::Crypto(err) => write!(f, "keystore: {err}"),
            KeystoreError::TooPermissive { path, mode } => write!(
                f,
                "{} is mode {mode:o}; the runner's secret key must be readable only by its owner \
                 — fix with `chmod 600 {}`",
                path.display(),
                path.display()
            ),
        }
    }
}

impl std::error::Error for KeystoreError {}

impl From<std::io::Error> for KeystoreError {
    fn from(err: std::io::Error) -> Self {
        KeystoreError::Io(err)
    }
}

impl From<CryptoError> for KeystoreError {
    fn from(err: CryptoError) -> Self {
        KeystoreError::Crypto(err)
    }
}

/// Load the identity at `path`, creating one if it is not there.
///
/// This is the only function the runner needs: first start mints a key, every
/// start after reuses it, and a device paired last week still recognises the
/// runner today.
pub fn load_or_create(path: impl AsRef<Path>) -> Result<Identity, KeystoreError> {
    let path = path.as_ref();
    if path.exists() {
        return load(path);
    }
    let identity = Identity::generate();
    save(path, &identity)?;
    Ok(identity)
}

pub fn load(path: impl AsRef<Path>) -> Result<Identity, KeystoreError> {
    Ok(Identity::from_secret_base64(&read_secret(path)?)?)
}

/// Write an identity, creating the file `0600` from the start.
pub fn save(path: impl AsRef<Path>, identity: &Identity) -> Result<(), KeystoreError> {
    write_secret(path, &identity.to_secret_base64())
}

/// Read a secret from a key file, refusing one anybody else can read.
///
/// Exposed because the runner's X25519 identity is not the only long-lived
/// secret on a RelayForge box — the relay's VAPID signing key is another, and it
/// deserves exactly the same two guarantees rather than a second, subtly
/// different implementation of them.
pub fn read_secret(path: impl AsRef<Path>) -> Result<String, KeystoreError> {
    let path = path.as_ref();
    check_permissions(path)?;
    Ok(fs::read_to_string(path)?.trim().to_owned())
}

/// Write a secret, creating the file `0600` from the start.
pub fn write_secret(path: impl AsRef<Path>, secret: &str) -> Result<(), KeystoreError> {
    let path = path.as_ref();
    if let Some(parent) = path.parent()
        && !parent.as_os_str().is_empty()
    {
        fs::create_dir_all(parent)?;
    }

    let mut options = fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);

    // The mode is part of the create call, so the file never exists in a
    // readable state — not even for the instant between create and chmod.
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.mode(0o600);
    }

    let mut file = options.open(path)?;
    file.write_all(secret.as_bytes())?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    Ok(())
}

#[cfg(unix)]
fn check_permissions(path: &Path) -> Result<(), KeystoreError> {
    use std::os::unix::fs::PermissionsExt as _;

    let mode = fs::metadata(path)?.permissions().mode() & 0o777;
    if mode & FORBIDDEN_BITS != 0 {
        return Err(KeystoreError::TooPermissive {
            path: path.to_path_buf(),
            mode,
        });
    }
    Ok(())
}

#[cfg(not(unix))]
fn check_permissions(_path: &Path) -> Result<(), KeystoreError> {
    // Windows ACLs are not a mode bitmask; the equivalent check belongs with a
    // platform-specific implementation rather than a wrong approximation.
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(label: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "forge-keystore-{}-{label}-{:?}",
                std::process::id(),
                std::thread::current().id()
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn join(&self, name: &str) -> PathBuf {
            self.0.join(name)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).ok();
        }
    }

    #[test]
    fn first_start_mints_a_key_and_later_starts_reuse_it() {
        let dir = TempDir::new("reuse");
        let path = dir.join("runner.key");

        let first = load_or_create(&path).unwrap();
        let second = load_or_create(&path).unwrap();

        assert_eq!(
            first.public_key(),
            second.public_key(),
            "the runner changed identity on restart — every paired device would break"
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_new_key_file_is_owner_only() {
        use std::os::unix::fs::PermissionsExt as _;

        let dir = TempDir::new("perms");
        let path = dir.join("runner.key");
        load_or_create(&path).unwrap();

        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "key file is mode {mode:o}");
    }

    #[cfg(unix)]
    #[test]
    fn a_world_readable_key_is_refused_rather_than_used() {
        use std::os::unix::fs::PermissionsExt as _;

        let dir = TempDir::new("loose");
        let path = dir.join("runner.key");
        load_or_create(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();

        let err = load(&path).unwrap_err();
        assert!(matches!(err, KeystoreError::TooPermissive { .. }));
        // The message has to tell the operator how to fix it.
        assert!(err.to_string().contains("chmod 600"));
    }

    #[cfg(unix)]
    #[test]
    fn a_group_readable_key_is_refused_too() {
        use std::os::unix::fs::PermissionsExt as _;

        let dir = TempDir::new("group");
        let path = dir.join("runner.key");
        load_or_create(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();

        assert!(matches!(
            load(&path).unwrap_err(),
            KeystoreError::TooPermissive { .. }
        ));
    }

    #[test]
    fn the_parent_directory_is_created_if_missing() {
        let dir = TempDir::new("nested");
        let path = dir.join("keys").join("nested").join("runner.key");

        let identity = load_or_create(&path).unwrap();
        assert!(path.exists());
        assert_eq!(load(&path).unwrap().public_key(), identity.public_key());
    }

    #[test]
    fn a_corrupt_key_file_is_an_error_not_a_fresh_identity() {
        // Silently regenerating would look like a working daemon while every
        // paired device quietly stopped being able to talk to it.
        let dir = TempDir::new("corrupt");
        let path = dir.join("runner.key");
        save(&path, &Identity::generate()).unwrap();
        fs::write(&path, "this is not a key").unwrap();

        assert!(matches!(load(&path).unwrap_err(), KeystoreError::Crypto(_)));
    }

    #[test]
    fn a_saved_key_still_decrypts_messages_after_a_reload() {
        let dir = TempDir::new("roundtrip");
        let path = dir.join("runner.key");
        let runner = load_or_create(&path).unwrap();

        let phone = Identity::generate();
        let envelope = phone
            .seal("chan", "phone", runner.public_key(), b"approve")
            .unwrap();

        let reloaded = load(&path).unwrap();
        assert_eq!(
            reloaded.open(phone.public_key(), &envelope).unwrap(),
            b"approve"
        );
    }
}
