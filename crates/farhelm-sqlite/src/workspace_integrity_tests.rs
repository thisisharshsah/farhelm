use super::*;

fn project(id: &str, workspace: &str) -> Project {
    Project {
        id: id.into(),
        workspace_id: workspace.into(),
        name: id.into(),
        description: String::new(),
        budget_cap_usd: None,
        created_at: 1,
        updated_at: 1,
    }
}

fn conversation(id: &str, project_id: &str) -> Conversation {
    Conversation {
        id: id.into(),
        project_id: project_id.into(),
        title: id.into(),
        created_at: 1,
        updated_at: 1,
    }
}

fn document(id: &str, project_id: &str) -> Document {
    Document {
        id: id.into(),
        project_id: project_id.into(),
        title: id.into(),
        content: "retained fixture content".into(),
        content_hash: "fixture-hash".into(),
        version: 1,
        created_at: 1,
        updated_at: 1,
    }
}

fn link() -> EntityLink {
    EntityLink {
        id: "link".into(),
        source_type: EntityKind::Conversation,
        source_id: "conversation".into(),
        target_type: EntityKind::Document,
        target_id: "document".into(),
        relation_kind: RelationKind::Documents,
        created_at: 1,
    }
}

fn store_with_entities() -> SqliteStore {
    let store = SqliteStore::open_in_memory().unwrap();
    for (id, workspace) in [("p1", "ws1"), ("p2", "ws1"), ("p3", "ws2")] {
        store.put_project(&project(id, workspace)).unwrap();
    }
    store
        .put_conversation(&conversation("conversation", "p1"))
        .unwrap();
    store.put_document(&document("document", "p1")).unwrap();
    store
        .put_document(&document("other-tenant-document", "p3"))
        .unwrap();
    store
}

fn version_11_connection() -> Connection {
    let conn = Connection::open_in_memory().unwrap();
    conn.pragma_update(None, "foreign_keys", "ON").unwrap();
    for (index, sql) in MIGRATIONS.iter().take(11).enumerate() {
        conn.execute_batch(&format!(
            "BEGIN;\n{sql}\nPRAGMA user_version = {};\nCOMMIT;",
            index + 1
        ))
        .unwrap();
    }
    conn.execute_batch(
        "INSERT INTO project VALUES ('p1', 'ws1', 'P1', '', NULL, 1, 1);
         INSERT INTO project VALUES ('p2', 'ws2', 'P2', '', NULL, 1, 1);
         INSERT INTO conversation VALUES ('conversation', 'p1', 'Discussion', 1, 1);
         INSERT INTO document VALUES ('document', 'p1', 'Doc', 'retained content', 'hash', 1, 1, 1);
         INSERT INTO document VALUES ('other-document', 'p2', 'Other', 'other content', 'hash', 1, 1, 1);",
    )
    .unwrap();
    conn
}

fn schema_version(conn: &Connection) -> i64 {
    conn.query_row("PRAGMA user_version", [], |row| row.get(0))
        .unwrap()
}

#[test]
fn valid_version_11_data_upgrades_with_content_and_links_intact() {
    let conn = version_11_connection();
    conn.execute_batch(
        "INSERT INTO entity_link VALUES ('link', 'conversation', 'conversation', 'document', 'document', 'documents', 1);",
    )
    .unwrap();
    migrate(&conn).unwrap();
    assert_eq!(schema_version(&conn), MIGRATIONS.len() as i64);
    assert_eq!(
        conn.query_row(
            "SELECT content FROM document WHERE id = 'document'",
            [],
            |row| { row.get::<_, String>(0) }
        )
        .unwrap(),
        "retained content"
    );
    let foreign_key_violations: usize = conn
        .prepare("PRAGMA foreign_key_check")
        .unwrap()
        .query_map([], |_| Ok(()))
        .unwrap()
        .count();
    assert_eq!(foreign_key_violations, 0);
    let store = SqliteStore {
        conn: Mutex::new(conn),
    };
    assert_eq!(
        store
            .list_links_from(EntityKind::Conversation, "conversation")
            .unwrap(),
        vec![link()]
    );
}

#[test]
fn invalid_legacy_parent_aborts_and_preserves_original_data_for_repair() {
    let conn = version_11_connection();
    conn.execute_batch(
        "INSERT INTO document VALUES ('orphan', 'missing', 'Orphan', 'preserve me', 'hash', 1, 1, 1);",
    )
    .unwrap();
    let error = migrate(&conn).unwrap_err().to_string();
    assert!(error.contains("migration 12 failed"), "{error}");
    assert!(error.contains("existing data retained"), "{error}");
    assert!(
        error.contains("repair invalid workspace parents/links"),
        "{error}"
    );
    assert!(conn.is_autocommit(), "migration must explicitly roll back");
    assert_eq!(schema_version(&conn), 11);
    assert_eq!(
        conn.query_row(
            "SELECT content FROM document WHERE id = 'orphan'",
            [],
            |row| { row.get::<_, String>(0) }
        )
        .unwrap(),
        "preserve me"
    );
    // A verified repair can retry the same migration without dropping content.
    conn.execute_batch(
        "INSERT INTO project VALUES ('missing', 'ws1', 'Recovered', '', NULL, 1, 1);",
    )
    .unwrap();
    migrate(&conn).unwrap();
    assert_eq!(schema_version(&conn), MIGRATIONS.len() as i64);
}

#[test]
fn invalid_version_11_links_fail_upgrade_without_deleting_rows() {
    for (source_type, source_id, target_id, relation, expected) in [
        (
            "conversation",
            "conversation",
            "other-document",
            "documents",
            "share a workspace",
        ),
        (
            "conversation",
            "missing",
            "document",
            "documents",
            "does not exist",
        ),
        (
            "task",
            "conversation",
            "document",
            "documents",
            "no implemented workspace scope",
        ),
        (
            "conversation",
            "conversation",
            "document",
            "unknown",
            "invalid entity link relation",
        ),
    ] {
        let conn = version_11_connection();
        conn.execute(
            "INSERT INTO entity_link VALUES ('invalid-link', ?1, ?2, 'document', ?3, ?4, 1)",
            params![source_type, source_id, target_id, relation],
        )
        .unwrap();
        let error = migrate(&conn).unwrap_err().to_string();
        assert!(error.contains(expected), "{error}");
        assert!(conn.is_autocommit());
        assert_eq!(schema_version(&conn), 11);
        let retained: String = conn
            .query_row(
                "SELECT source_type FROM entity_link WHERE id = 'invalid-link'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(retained, source_type);
    }
}

#[test]
fn missing_containment_parent_is_rejected_before_data_is_written() {
    let store = SqliteStore::open_in_memory().unwrap();
    assert!(
        store
            .put_conversation(&conversation("orphan", "missing"))
            .is_err()
    );
    assert!(store.put_document(&document("orphan", "missing")).is_err());
    assert!(store.get_conversation("orphan").unwrap().is_none());
    assert!(store.get_document("orphan").unwrap().is_none());
    assert!(store.put_project(&project("blank", "  ")).is_err());
}

#[test]
fn upserts_cannot_move_existing_objects_to_a_different_workspace() {
    let store = store_with_entities();
    assert!(store.put_project(&project("p1", "ws2")).is_err());
    assert!(
        store
            .put_conversation(&conversation("conversation", "p3"))
            .is_err()
    );
    assert!(store.put_document(&document("document", "p3")).is_err());
    assert_eq!(
        store.get_project("p1").unwrap().unwrap().workspace_id,
        "ws1"
    );
    assert_eq!(
        store
            .get_conversation("conversation")
            .unwrap()
            .unwrap()
            .project_id,
        "p1"
    );
    assert_eq!(
        store.get_document("document").unwrap().unwrap().project_id,
        "p1"
    );
    // Moving between projects inside the same workspace preserves tenant scope.
    store
        .put_conversation(&conversation("conversation", "p2"))
        .unwrap();
    store.put_document(&document("document", "p2")).unwrap();
}

#[test]
fn links_require_existing_same_workspace_endpoints_with_implemented_scope() {
    let store = store_with_entities();
    let mut invalid = link();
    invalid.target_id = "other-tenant-document".into();
    assert!(store.put_entity_link(&invalid).is_err());
    invalid.target_id = "missing".into();
    assert!(store.put_entity_link(&invalid).is_err());
    invalid.target_id = "document".into();
    for kind in [
        EntityKind::Task,
        EntityKind::TaskRun,
        EntityKind::Artifact,
        EntityKind::Repo,
    ] {
        invalid.source_type = kind;
        assert!(store.put_entity_link(&invalid).is_err());
    }
    store.put_entity_link(&link()).unwrap();
    assert_eq!(
        store
            .list_links_to(EntityKind::Document, "document")
            .unwrap(),
        vec![link()]
    );
}

#[test]
fn repeated_edges_return_canonical_identity_without_rewriting_creation_time() {
    let store = store_with_entities();
    let original = link();
    assert_eq!(store.put_entity_link(&original).unwrap(), original);
    let mut retry = original.clone();
    retry.id = "retry-id".into();
    retry.created_at = 999;
    let canonical = store.put_entity_link(&retry).unwrap();
    assert_eq!(canonical, original);
    assert!(!store.remove_entity_link("retry-id").unwrap());
    let mut conflicting = original.clone();
    conflicting.relation_kind = RelationKind::Mentions;
    assert!(store.put_entity_link(&conflicting).is_err());
    assert_eq!(
        store
            .list_links_from(EntityKind::Conversation, "conversation")
            .unwrap(),
        vec![original.clone()]
    );
    assert!(store.remove_entity_link(&canonical.id).unwrap());
}

#[test]
fn database_triggers_guard_direct_endpoint_deletion_identity_and_link_updates() {
    let store = store_with_entities();
    store.put_entity_link(&link()).unwrap();
    let conn = store.lock().unwrap();
    for sql in [
        "UPDATE entity_link SET target_id = 'other-tenant-document' WHERE id = 'link'",
        "UPDATE entity_link SET relation_kind = 'unknown' WHERE id = 'link'",
        "UPDATE entity_link SET source_type = 'invalid' WHERE id = 'link'",
        "UPDATE project SET id = 'changed' WHERE id = 'p1'",
        "UPDATE conversation SET id = 'changed' WHERE id = 'conversation'",
        "UPDATE document SET id = 'changed' WHERE id = 'document'",
        "DELETE FROM conversation WHERE id = 'conversation'",
        "DELETE FROM document WHERE id = 'document'",
        "DELETE FROM project WHERE id = 'p1'",
    ] {
        assert!(conn.execute_batch(sql).is_err(), "must refuse: {sql}");
    }
    conn.execute_batch("DELETE FROM entity_link WHERE id = 'link'; DELETE FROM conversation WHERE id = 'conversation'; DELETE FROM document WHERE id = 'document'; DELETE FROM project WHERE id = 'p1';")
        .unwrap();
}
