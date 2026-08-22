//! The names this system used to answer to.
//!
//! Everything a person types or stores was called `forge` something: the
//! environment variables, the database, the identity key, the policy file. The
//! product is Farhelm, so those are all `farhelm` now — but a rename that
//! silently stops reading somebody's existing configuration is not a rename,
//! it is a data-loss bug with a changelog entry.
//!
//! So both names work, and this is the only place that knows it. Two rules:
//!
//! - The **new name always wins.** If both are present the old one is ignored,
//!   rather than whichever is checked first deciding — that is how you end up
//!   configuring one thing and running another with nothing to say so.
//! - **Falling back is said out loud, once.** Silent compatibility is how a
//!   deprecation lasts forever: nobody is ever told there is something to do.
//!
//! Both helpers key their warning on the *old* name, so a variable read on
//! every request warns once rather than once per read.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

/// The prefix the environment variables used to carry.
const OLD_ENV_PREFIX: &str = "FORGE_";
/// The prefix they carry now.
const NEW_ENV_PREFIX: &str = "FARHELM_";

fn said_already(what: &str) -> bool {
    static SAID: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    let seen = SAID.get_or_init(|| Mutex::new(HashSet::new()));
    // A poisoned lock here means another thread panicked mid-warning. Warning
    // twice is a better outcome than propagating that panic into a config read.
    match seen.lock() {
        Ok(mut seen) => !seen.insert(what.to_owned()),
        Err(_) => false,
    }
}

/// Read `FARHELM_…`, falling back to the `FORGE_…` name it used to have.
///
/// Pass the new name. The old one is derived, so there is no second list to
/// keep in step with the first.
pub fn env_var(name: &str) -> Option<String> {
    if let Ok(value) = std::env::var(name) {
        return Some(value);
    }

    let old = name.strip_prefix(NEW_ENV_PREFIX)?;
    let old = format!("{OLD_ENV_PREFIX}{old}");
    let value = std::env::var(&old).ok()?;

    if !said_already(&old) {
        eprintln!("note: {old} is the old name for {name}. Both work; rename it when convenient.");
    }
    Some(value)
}

/// Which of a state file's two names to actually open.
///
/// Returns the new path unless it is absent and the old one is there, in which
/// case the old file is used *where it is*. Nothing is moved: a database has
/// `-wal` and `-shm` siblings and an identity key is the thing every paired
/// device trusts, and neither is worth relocating under someone on a startup
/// they did not ask for. `farhelm doctor` is where the one-line `mv` is
/// offered, once, to a person who can decide.
pub fn state_path(new: &str, old: &str) -> PathBuf {
    let new_path = PathBuf::from(new);
    if new_path.exists() || !Path::new(old).exists() {
        return new_path;
    }

    if !said_already(old) {
        eprintln!(
            "note: reading {old}, the old name for {new}. Both work; `mv {old} {new}` when convenient."
        );
    }
    PathBuf::from(old)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_new_path_wins_when_both_exist() {
        let dir = std::env::temp_dir().join(format!("farhelm-legacy-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let new = dir.join("farhelm.db");
        let old = dir.join("forge.db");
        std::fs::write(&new, b"new").unwrap();
        std::fs::write(&old, b"old").unwrap();

        assert_eq!(
            state_path(new.to_str().unwrap(), old.to_str().unwrap()),
            new,
            "a machine holding both files must not be quietly switched to the old one"
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn the_old_path_is_used_where_it_lies() {
        let dir = std::env::temp_dir().join(format!("farhelm-legacy-old-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let new = dir.join("farhelm.key");
        let old = dir.join("forge.key");
        std::fs::write(&old, b"identity").unwrap();

        assert_eq!(
            state_path(new.to_str().unwrap(), old.to_str().unwrap()),
            old,
            "an upgrade must not mint a new identity and unpair every device"
        );
        assert!(!new.exists(), "nothing is moved or created behind the user");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_missing_pair_resolves_to_the_new_name() {
        let dir = std::env::temp_dir().join(format!("farhelm-legacy-none-{}", std::process::id()));
        let new = dir.join("farhelm.db");
        let old = dir.join("forge.db");
        assert_eq!(
            state_path(new.to_str().unwrap(), old.to_str().unwrap()),
            new,
            "a fresh install gets the current name, not the one being retired"
        );
    }
}
