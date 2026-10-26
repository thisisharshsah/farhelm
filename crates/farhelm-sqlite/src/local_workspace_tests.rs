use super::*;

fn project(id: &str, scope: &str) -> Project {
    Project {
        id: id.into(),
        workspace_id: scope.into(),
        name: format!("Project {id}"),
        description: "Local metadata".into(),
        budget_cap_usd: None,
        created_at: 42,
        updated_at: 42,
    }
}

struct TempDatabase(std::path::PathBuf);

impl TempDatabase {
    fn new() -> Self {
        Self(std::env::temp_dir().join(format!(
            "farhelm-workspace-{}.sqlite",
            farhelm_app::id::new_id()
        )))
    }
}

impl Drop for TempDatabase {
    fn drop(&mut self) {
        for path in [
            self.0.clone(),
            self.0.with_extension("sqlite-wal"),
            self.0.with_extension("sqlite-shm"),
        ] {
            let _ = std::fs::remove_file(path);
        }
    }
}

#[test]
fn local_scope_and_project_survive_reopening_the_database() {
    let path = TempDatabase::new();
    let scope;
    let saved;
    {
        let store = SqliteStore::open(&path.0).unwrap();
        scope = store.local_workspace_id().unwrap();
        assert!(scope.starts_with("local:"));
        assert_eq!(scope.len(), 38);
        assert_eq!(store.local_workspace_id().unwrap(), scope);
        saved = project("persisted", &scope);
        store.insert_project(&saved).unwrap();
    }
    let reopened = SqliteStore::open(&path.0).unwrap();
    assert_eq!(reopened.local_workspace_id().unwrap(), scope);
    assert_eq!(
        reopened
            .get_project_in_workspace(&scope, "persisted")
            .unwrap(),
        Some(saved)
    );
    let other = SqliteStore::open_in_memory().unwrap();
    assert_ne!(other.local_workspace_id().unwrap(), scope);
}

#[test]
fn migration_creates_local_scope_without_adopting_existing_projects() {
    let conn = Connection::open_in_memory().unwrap();
    for (index, sql) in MIGRATIONS.iter().take(12).enumerate() {
        conn.execute_batch(&format!(
            "BEGIN;\n{sql}\nPRAGMA user_version = {};\nCOMMIT;",
            index + 1
        ))
        .unwrap();
    }
    conn.execute(
        "INSERT INTO project (id, workspace_id, name, description, created_at, updated_at)
         VALUES ('existing', 'original-workspace', 'Existing project', 'Keep me', 10, 20)",
        [],
    )
    .unwrap();
    let store = SqliteStore::from_connection(conn).unwrap();
    let scope = store.local_workspace_id().unwrap();
    let existing = store.get_project("existing").unwrap().unwrap();
    assert_eq!(existing.workspace_id, "original-workspace");
    assert_eq!(existing.name, "Existing project");
    assert_eq!(existing.description, "Keep me");
    assert_eq!(existing.created_at, 10);
    assert_eq!(existing.updated_at, 20);
    assert!(
        store
            .list_project_page(&scope, None, 101)
            .unwrap()
            .is_empty()
    );
    assert!(
        store
            .get_project_in_workspace(&scope, "existing")
            .unwrap()
            .is_none()
    );
}

#[test]
fn project_queries_filter_scope_before_ordering_and_paging() {
    let store = SqliteStore::open_in_memory().unwrap();
    let scope = store.local_workspace_id().unwrap();
    for id in ["a", "c", "b"] {
        store.insert_project(&project(id, &scope)).unwrap();
    }
    store
        .insert_project(&project("z-foreign", "other"))
        .unwrap();
    let first = store.list_project_page(&scope, None, 2).unwrap();
    assert_eq!(
        first
            .iter()
            .map(|project| project.id.as_str())
            .collect::<Vec<_>>(),
        ["c", "b"]
    );
    let next = store.list_project_page(&scope, Some("b"), 2).unwrap();
    assert_eq!(next, vec![project("a", &scope)]);
    assert!(
        store
            .get_project_in_workspace(&scope, "z-foreign")
            .unwrap()
            .is_none()
    );
    assert!(
        store
            .get_project_in_workspace("' OR 1=1--", "a")
            .unwrap()
            .is_none()
    );
    assert!(store.list_project_page(&scope, None, 0).unwrap().is_empty());
}

#[test]
fn insert_never_overwrites_an_existing_project() {
    let store = SqliteStore::open_in_memory().unwrap();
    let scope = store.local_workspace_id().unwrap();
    let original = project("existing", &scope);
    store.insert_project(&original).unwrap();
    let mut overwrite = original.clone();
    overwrite.name = "Replacement".into();
    assert!(store.insert_project(&overwrite).is_err());
    overwrite.workspace_id = "other".into();
    assert!(store.insert_project(&overwrite).is_err());
    assert_eq!(store.get_project("existing").unwrap(), Some(original));
}
