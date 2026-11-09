//! Finding Git checkouts on this machine, so adding one to a project is a click
//! rather than a typed path.
//!
//! An explicit, bounded operation (AGENTS.md: repository *list* reads never scan
//! the host). It runs only when someone asks, looks one level down in the named
//! folder or, with none named, beside repositories already registered and in a
//! few conventional folders under the home directory. It follows no symlinks,
//! opens no file and registers nothing; a checkout is a folder holding `.git`.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use farhelm_proto::{DiscoveredRepository, RepositoryDiscovery, types::Repo};

/// Where to look under the home directory when nothing is named.
const CONVENTIONAL: &[&str] = &[
    "Project", "Projects", "projects", "code", "src", "dev", "work",
];
/// Directory entries read per folder, and checkouts returned in all.
const MAX_ENTRIES: usize = 2_000;
const MAX_FOUND: usize = 200;

/// The folder a path names, if it is the top of a Git checkout.
pub(crate) fn checkout(path: &str) -> Result<PathBuf, String> {
    let given = Path::new(path.trim());
    if !given.is_absolute() {
        return Err("give the full path of the repository's folder".to_owned());
    }
    let folder = given
        .canonicalize()
        .map_err(|_| format!("{} does not exist on this machine", given.display()))?;
    if !folder.is_dir() {
        return Err(format!("{} is not a folder", folder.display()));
    }
    if !folder.join(".git").exists() {
        return Err(format!(
            "{} is not the top of a Git repository",
            folder.display()
        ));
    }
    Ok(folder)
}

pub(crate) fn discover(
    directory: Option<&str>,
    known: &[Repo],
    home: Option<&Path>,
) -> Result<RepositoryDiscovery, String> {
    let roots: BTreeSet<PathBuf> = match directory.map(str::trim).filter(|dir| !dir.is_empty()) {
        Some(directory) => {
            let given = Path::new(directory);
            if !given.is_absolute() {
                return Err("give the full path of the folder to look in".to_owned());
            }
            let folder = given
                .canonicalize()
                .map_err(|_| format!("{} does not exist on this machine", given.display()))?;
            if !folder.is_dir() {
                return Err(format!("{} is not a folder", folder.display()));
            }
            BTreeSet::from([folder])
        }
        None => known
            .iter()
            .filter(|repo| !repo.path.is_empty())
            .filter_map(|repo| Path::new(&repo.path).parent().map(Path::to_path_buf))
            .chain(
                home.into_iter()
                    .flat_map(|home| CONVENTIONAL.iter().map(|name| home.join(name))),
            )
            .filter(|folder| folder.is_dir())
            .collect(),
    };

    let mut found = Vec::new();
    let mut truncated = false;
    for root in &roots {
        let Ok(entries) = std::fs::read_dir(root) else {
            continue;
        };
        for (index, entry) in entries.flatten().enumerate() {
            if index >= MAX_ENTRIES {
                truncated = true;
                break;
            }
            let name = entry.file_name().to_string_lossy().into_owned();
            // `file_type` does not follow a symlink, so a link cannot walk this
            // out of the folder it was asked about.
            let is_folder = entry.file_type().is_ok_and(|kind| kind.is_dir());
            if name.starts_with('.') || !is_folder || !entry.path().join(".git").exists() {
                continue;
            }
            found.push(DiscoveredRepository {
                name,
                path: entry.path().to_string_lossy().into_owned(),
            });
        }
    }
    found.sort_by(|a, b| (&a.name, &a.path).cmp(&(&b.name, &b.path)));
    found.dedup_by(|a, b| a.path == b.path);
    if found.len() > MAX_FOUND {
        found.truncate(MAX_FOUND);
        truncated = true;
    }
    Ok(RepositoryDiscovery {
        searched: roots
            .iter()
            .map(|root| root.to_string_lossy().into_owned())
            .collect(),
        repositories: found,
        truncated,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Temp(PathBuf);
    impl Temp {
        fn new(name: &str) -> Self {
            let dir = std::env::temp_dir()
                .join(format!("farhelm-discovery-{name}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            Self(dir.canonicalize().unwrap())
        }
        fn checkout(&self, name: &str) -> PathBuf {
            let path = self.0.join(name);
            std::fs::create_dir_all(path.join(".git")).unwrap();
            path
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn names(found: &RepositoryDiscovery) -> Vec<&str> {
        found
            .repositories
            .iter()
            .map(|repo| repo.name.as_str())
            .collect()
    }

    #[test]
    fn a_look_goes_one_level_down_and_follows_nothing() {
        let temp = Temp::new("level");
        temp.checkout("beta");
        let alpha = temp.checkout("alpha");
        temp.checkout(".hidden");
        temp.checkout("group/nested");
        std::fs::create_dir(temp.0.join("plain")).unwrap();
        std::os::unix::fs::symlink(&alpha, temp.0.join("link")).unwrap();

        let found = discover(temp.0.to_str(), &[], None).unwrap();
        assert_eq!(names(&found), ["alpha", "beta"]);
        assert_eq!(found.searched, [temp.0.to_string_lossy()]);
        assert!(!found.truncated);
    }

    #[test]
    fn with_no_folder_named_it_looks_beside_known_repositories() {
        let temp = Temp::new("beside");
        let known = temp.checkout("known");
        temp.checkout("sibling");
        let repo = Repo {
            id: "r".into(),
            machine_id: "m".into(),
            path: known.to_string_lossy().into_owned(),
            name: "known".into(),
            budget_usd: None,
        };
        // The gateway's bookkeeping row has no path and adds no folder.
        let pathless = Repo {
            path: String::new(),
            ..repo.clone()
        };
        let found = discover(None, &[pathless, repo], None).unwrap();
        assert_eq!(names(&found), ["known", "sibling"]);
    }

    #[test]
    fn only_the_top_of_a_checkout_is_accepted() {
        let temp = Temp::new("accept");
        let repo = temp.checkout("repo");
        std::fs::create_dir(repo.join("sub")).unwrap();
        assert_eq!(checkout(repo.to_str().unwrap()).unwrap(), repo);
        assert!(
            checkout(repo.join("sub").to_str().unwrap())
                .unwrap_err()
                .contains("not the top")
        );
        assert!(checkout("relative/path").unwrap_err().contains("full path"));
        assert!(
            checkout("/no/such/folder")
                .unwrap_err()
                .contains("does not exist")
        );
        assert!(discover(Some("relative"), &[], None).is_err());
    }
}
