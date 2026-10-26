use super::*;
use farhelm_app::{ProjectWorkflow, ProjectWorkflowError};

fn setup() -> SqliteStore {
    let store = SqliteStore::open_in_memory().unwrap();
    for id in ["machine", "foreign-machine"] {
        store
            .upsert_machine(&Machine {
                id: id.into(),
                name: id.into(),
                pubkey: id.into(),
                last_seen_at: None,
                created_at: 1,
            })
            .unwrap();
    }
    for (id, machine) in [
        ("repo-a", "machine"),
        ("repo-b", "machine"),
        ("repo-z", "foreign-machine"),
    ] {
        store
            .upsert_repo(&Repo {
                id: id.into(),
                machine_id: machine.into(),
                path: format!("/synthetic/{id}"),
                name: id.into(),
                budget_usd: None,
            })
            .unwrap();
    }
    let scope = store.local_workspace_id().unwrap();
    for (id, workspace) in [
        ("project-a", scope.as_str()),
        ("project-b", scope.as_str()),
        ("foreign-project", "foreign-workspace"),
    ] {
        store
            .insert_project(&Project {
                id: id.into(),
                workspace_id: workspace.into(),
                name: id.into(),
                description: String::new(),
                budget_cap_usd: None,
                created_at: 1,
                updated_at: 1,
            })
            .unwrap();
    }
    store
}

fn rows(id: &str, repo: &str) -> (Session, AgentTask) {
    let session = Session {
        id: format!("session-{id}"),
        repo_id: repo.into(),
        agent: Agent::Farhelm,
        tmux_target: None,
        status: SessionStatus::Running,
        plan_id: None,
        budget_usd: None,
        spent_usd: 0.0,
        started_at: 1,
        ended_at: None,
        agent_session_id: None,
    };
    let task = AgentTask {
        id: id.into(),
        session_id: session.id.clone(),
        repo_id: repo.into(),
        prompt: "Synthetic work".into(),
        status: TaskStatus::Running,
        summary: String::new(),
        diff_json: String::new(),
        worktree_json: String::new(),
        files_changed: 0,
        lines_added: 0,
        lines_removed: 0,
        steps: 0,
        cost_usd: 0.0,
        error: None,
        review_note: None,
        verify_grade: None,
        verify_notes: None,
        verify_model: None,
        decided_via: None,
        created_at: 1,
        updated_at: 1,
        decided_at: None,
    };
    (session, task)
}

#[test]
fn registered_repository_pages_and_idempotent_attachment_are_scoped() {
    let store = setup();
    let workflow = ProjectWorkflow::new(&store, "machine").unwrap();
    let first = workflow
        .repository_candidates("project-a", None, 1)
        .unwrap();
    assert_eq!(first.repositories[0].id, "repo-b");
    assert_eq!(first.next_cursor.as_deref(), Some("repo-b"));
    let next = workflow
        .repository_candidates("project-a", first.next_cursor.as_deref(), 1)
        .unwrap();
    assert_eq!(next.repositories[0].id, "repo-a");
    assert_eq!(next.next_cursor, None);
    assert!(matches!(
        workflow.repository_candidates("foreign-project", None, 50),
        Err(ProjectWorkflowError::NotFound)
    ));
    assert!(matches!(
        workflow.attach_repository("project-a", "repo-z", 1),
        Err(ProjectWorkflowError::NotFound)
    ));
    assert!(matches!(
        workflow.attach_repository("foreign-project", "repo-a", 1),
        Err(ProjectWorkflowError::NotFound)
    ));
    let attached = workflow
        .attach_repository("project-a", "repo-a", 10)
        .unwrap();
    assert_eq!(
        workflow
            .attach_repository("project-a", "repo-a", 99)
            .unwrap(),
        attached
    );
    let at: i64 = store
        .lock()
        .unwrap()
        .query_row("SELECT attached_at FROM project_repo", [], |row| row.get(0))
        .unwrap();
    assert_eq!(at, 10);
    assert_eq!(
        workflow
            .repositories("project-a", None, 50)
            .unwrap()
            .repositories,
        vec![attached]
    );
    assert!(
        workflow
            .repositories("project-b", None, 50)
            .unwrap()
            .repositories
            .is_empty()
    );
    for limit in [0, 101, usize::MAX] {
        assert!(matches!(
            workflow.repository_candidates("project-a", None, limit),
            Err(ProjectWorkflowError::Validation(_))
        ));
    }
}

#[test]
fn shared_repositories_do_not_share_runs_or_adopt_legacy_tasks() {
    let store = setup();
    let workflow = ProjectWorkflow::new(&store, "machine").unwrap();
    for project in ["project-a", "project-b"] {
        workflow.attach_repository(project, "repo-a", 1).unwrap();
    }
    let (session, task) = rows("task-a", "repo-a");
    workflow
        .insert_task("project-a", &session, &task, None)
        .unwrap();
    let (legacy_session, legacy) = rows("legacy", "repo-a");
    store.upsert_session(&legacy_session).unwrap();
    store.upsert_task(&legacy).unwrap();
    assert_eq!(store.project_for_task(&legacy.id).unwrap(), None);
    assert_eq!(
        store.project_for_task(&task.id).unwrap().as_deref(),
        Some("project-a")
    );
    assert!(matches!(
        workflow.task("project-b", &task.id),
        Err(ProjectWorkflowError::NotFound)
    ));
    assert!(matches!(
        workflow.task("foreign-project", &task.id),
        Err(ProjectWorkflowError::NotFound)
    ));
    assert!(
        workflow
            .tasks("project-b", None, 50)
            .unwrap()
            .tasks
            .is_empty()
    );
    assert_eq!(
        workflow.tasks("project-a", None, 50).unwrap().tasks,
        vec![task]
    );
    assert_eq!(store.get_task(&legacy.id).unwrap(), Some(legacy));
}

#[test]
fn retry_context_requires_same_project_repo_and_rejected_status_then_rechecks_on_insert() {
    let store = setup();
    let workflow = ProjectWorkflow::new(&store, "machine").unwrap();
    for project in ["project-a", "project-b"] {
        for repo in ["repo-a", "repo-b"] {
            workflow.attach_repository(project, repo, 1).unwrap();
        }
    }
    let (session, mut prior) = rows("original", "repo-a");
    workflow
        .insert_task("project-a", &session, &prior, None)
        .unwrap();
    assert!(matches!(
        workflow.prepare("project-a", "repo-a", Some(&prior.id)),
        Err(ProjectWorkflowError::Conflict(_))
    ));
    prior.status = TaskStatus::Rejected;
    prior.review_note = Some("Synthetic rejection".into());
    store.upsert_task(&prior).unwrap();
    assert_eq!(
        workflow
            .prepare("project-a", "repo-a", Some(&prior.id))
            .unwrap()
            .1,
        Some(prior.clone())
    );
    assert!(matches!(
        workflow.prepare("project-b", "repo-a", Some(&prior.id)),
        Err(ProjectWorkflowError::NotFound)
    ));
    assert!(matches!(
        workflow.prepare("project-a", "repo-b", Some(&prior.id)),
        Err(ProjectWorkflowError::NotFound)
    ));
    let (retry_session, retry) = rows("retry", "repo-a");
    assert!(matches!(
        workflow.insert_task("project-b", &retry_session, &retry, Some(&prior.id)),
        Err(ProjectWorkflowError::NotFound)
    ));
    assert!(store.get_session(&retry_session.id).unwrap().is_none());
    prior.status = TaskStatus::Applied;
    store.upsert_task(&prior).unwrap();
    assert!(matches!(
        workflow.insert_task("project-a", &retry_session, &retry, Some(&prior.id)),
        Err(ProjectWorkflowError::Conflict(_))
    ));
    assert!(store.get_task(&retry.id).unwrap().is_none());
    prior.status = TaskStatus::Rejected;
    store.upsert_task(&prior).unwrap();
    workflow
        .insert_task("project-a", &retry_session, &retry, Some(&prior.id))
        .unwrap();
}

#[test]
fn transaction_rolls_back_session_and_task_when_final_link_insert_fails() {
    let store = setup();
    let workflow = ProjectWorkflow::new(&store, "machine").unwrap();
    workflow
        .attach_repository("project-a", "repo-a", 1)
        .unwrap();
    store.lock().unwrap().execute_batch("CREATE TRIGGER reject_project_task BEFORE INSERT ON project_task BEGIN SELECT RAISE(ABORT,'synthetic final-write failure'); END;").unwrap();
    let (session, task) = rows("rollback", "repo-a");
    assert!(
        workflow
            .insert_task("project-a", &session, &task, None)
            .is_err()
    );
    assert!(store.get_session(&session.id).unwrap().is_none());
    assert!(store.get_task(&task.id).unwrap().is_none());
    assert!(store.project_for_task(&task.id).unwrap().is_none());
}

#[test]
fn invalid_scope_or_repository_mismatch_writes_no_rows() {
    let store = setup();
    let workflow = ProjectWorkflow::new(&store, "machine").unwrap();
    workflow
        .attach_repository("project-a", "repo-a", 1)
        .unwrap();
    let (mut session, task) = rows("no-write", "repo-b");
    assert!(matches!(
        workflow.insert_task("project-a", &session, &task, None),
        Err(ProjectWorkflowError::NotFound)
    ));
    assert!(matches!(
        workflow.insert_task("foreign-project", &session, &task, None),
        Err(ProjectWorkflowError::NotFound)
    ));
    session.repo_id = "repo-a".into();
    assert!(matches!(
        workflow.insert_task("project-a", &session, &task, None),
        Err(ProjectWorkflowError::Validation(_))
    ));
    assert!(store.get_session(&session.id).unwrap().is_none());
    assert!(store.get_task(&task.id).unwrap().is_none());
}

#[test]
fn persisted_provenance_cannot_be_reassigned_deleted_or_moved_to_another_repository() {
    let store = setup();
    let workflow = ProjectWorkflow::new(&store, "machine").unwrap();
    workflow
        .attach_repository("project-a", "repo-a", 1)
        .unwrap();
    workflow
        .attach_repository("project-b", "repo-a", 1)
        .unwrap();
    let (session, task) = rows("immutable", "repo-a");
    workflow
        .insert_task("project-a", &session, &task, None)
        .unwrap();
    let conn = store.lock().unwrap();
    for sql in [
        "UPDATE project_task SET project_id='project-b' WHERE task_id='immutable'",
        "DELETE FROM project_task WHERE task_id='immutable'",
        "UPDATE agent_task SET repo_id='repo-b' WHERE id='immutable'",
        "UPDATE agent_task SET session_id='other' WHERE id='immutable'",
        "UPDATE session SET repo_id='repo-b' WHERE id='session-immutable'",
        "UPDATE repo SET machine_id='foreign-machine' WHERE id='repo-a'",
    ] {
        assert!(conn.execute(sql, []).is_err(), "must reject {sql}");
    }
}

#[test]
fn migration_from_thirteen_preserves_legacy_records_and_does_not_create_links() {
    let conn = Connection::open_in_memory().unwrap();
    for (index, sql) in MIGRATIONS.iter().take(13).enumerate() {
        conn.execute_batch(&format!(
            "BEGIN;\n{sql}\nPRAGMA user_version={};\nCOMMIT;",
            index + 1
        ))
        .unwrap();
    }
    conn.execute_batch("INSERT INTO machine(id,name,pubkey,created_at) VALUES('m','M','key',1);
        INSERT INTO repo(id,machine_id,path,name) VALUES('r','m','/synthetic','R');
        INSERT INTO session(id,repo_id,agent,status,started_at) VALUES('s','r','farhelm','done',1);
        INSERT INTO agent_task(id,session_id,repo_id,prompt,status,created_at,updated_at) VALUES('t','s','r','Keep original','rejected',1,1);").unwrap();
    let store = SqliteStore::from_connection(conn).unwrap();
    assert_eq!(
        store.get_task("t").unwrap().unwrap().prompt,
        "Keep original"
    );
    assert_eq!(store.project_for_task("t").unwrap(), None);
    assert_eq!(
        store
            .lock()
            .unwrap()
            .query_row("SELECT count(*) FROM project_repo", [], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        0
    );
}

#[test]
fn task_creation_validation_bounds_user_inputs_before_execution() {
    use farhelm_app::validate_start_task;
    use farhelm_proto::StartProjectTaskRequest;
    let good = StartProjectTaskRequest {
        repo_id: "repo".into(),
        prompt: "Synthetic task".into(),
        budget_usd: Some(1.0),
        max_steps: Some(10),
        retry_of: None,
    };
    assert!(validate_start_task(&good).is_ok());
    for budget in [0.0, -1.0, f64::NAN, f64::INFINITY] {
        let mut input = good.clone();
        input.budget_usd = Some(budget);
        assert!(validate_start_task(&input).is_err());
    }
    for steps in [0, 257, usize::MAX] {
        let mut input = good.clone();
        input.max_steps = Some(steps);
        assert!(validate_start_task(&input).is_err());
    }
    for prompt in [String::new(), "   ".into(), "x".repeat(64 * 1024 + 1)] {
        let mut input = good.clone();
        input.prompt = prompt;
        assert!(validate_start_task(&input).is_err());
    }
}
