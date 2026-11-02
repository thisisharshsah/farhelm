//! Tasks on a project's board (work items): scoped reads and writes, and the
//! runs made on them.
//!
//! Every read and write re-checks the scope first: the project is in the
//! workspace, and a repository or conversation named by an item belongs to
//! that project. A task outside the scope is `None` or `false`, never a row
//! touched by accident.

use super::*;
use farhelm_app::store::{ProjectScope, WorkItemStore};
use farhelm_proto::{WorkItem, WorkItemStatus};

const ITEM_COLUMNS: &str = "w.id, w.project_id, w.title, w.description, w.status, w.repo_id, w.conversation_id, \
     w.created_at, w.updated_at";

/// The scope every query starts from: the item's project is in the
/// workspace, and its repository, when it has one, is on this machine.
const SCOPED_FROM: &str = "FROM work_item w
     JOIN project p ON p.id = w.project_id
     LEFT JOIN repo r ON r.id = w.repo_id
     WHERE p.id = ?1 AND p.workspace_id = ?2 AND (w.repo_id IS NULL OR r.machine_id = ?3)";

struct RawItem {
    id: String,
    project_id: String,
    title: String,
    description: String,
    status: String,
    repo_id: Option<String>,
    conversation_id: Option<String>,
    created_at: i64,
    updated_at: i64,
}

fn read_item(row: &Row<'_>) -> rusqlite::Result<RawItem> {
    Ok(RawItem {
        id: row.get(0)?,
        project_id: row.get(1)?,
        title: row.get(2)?,
        description: row.get(3)?,
        status: row.get(4)?,
        repo_id: row.get(5)?,
        conversation_id: row.get(6)?,
        created_at: row.get(7)?,
        updated_at: row.get(8)?,
    })
}

fn item_from(raw: RawItem) -> Result<WorkItem> {
    Ok(WorkItem {
        id: raw.id,
        project_id: raw.project_id,
        title: raw.title,
        description: raw.description,
        status: parse_enum::<WorkItemStatus>(&raw.status)?,
        repo_id: raw.repo_id,
        conversation_id: raw.conversation_id,
        created_at: raw.created_at,
        updated_at: raw.updated_at,
    })
}

/// Whether the repository and conversation an item names are the project's.
fn members_in_scope(conn: &Connection, scope: ProjectScope<'_>, item: &WorkItem) -> Result<bool> {
    if let Some(repo_id) = &item.repo_id {
        let attached: Option<i64> = conn
            .query_row(
                "SELECT 1 FROM project_repo pr JOIN repo r ON r.id = pr.repo_id
                 WHERE pr.project_id = ?1 AND pr.repo_id = ?2 AND r.machine_id = ?3",
                params![scope.project_id, repo_id, scope.machine_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(backend)?;
        if attached.is_none() {
            return Ok(false);
        }
    }
    if let Some(conversation_id) = &item.conversation_id {
        let owned: Option<i64> = conn
            .query_row(
                "SELECT 1 FROM conversation WHERE id = ?1 AND project_id = ?2",
                params![conversation_id, scope.project_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(backend)?;
        if owned.is_none() {
            return Ok(false);
        }
    }
    Ok(true)
}

impl WorkItemStore for SqliteStore {
    fn work_items(
        &self,
        scope: ProjectScope<'_>,
        conversation_id: Option<&str>,
        after: Option<&str>,
        limit: usize,
    ) -> Result<Vec<WorkItem>> {
        let conn = self.lock()?;
        let limit = i64::try_from(limit).map_err(|error| StoreError::Backend(Box::new(error)))?;
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {ITEM_COLUMNS} {SCOPED_FROM}
                 AND (?4 IS NULL OR w.conversation_id = ?4)
                 AND (?5 IS NULL OR w.id < ?5) ORDER BY w.id DESC LIMIT ?6"
            ))
            .map_err(backend)?;
        let rows = stmt
            .query_map(
                params![
                    scope.project_id,
                    scope.workspace_id,
                    scope.machine_id,
                    conversation_id,
                    after,
                    limit
                ],
                read_item,
            )
            .map_err(backend)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(backend)?;
        rows.into_iter().map(item_from).collect()
    }

    fn work_item(&self, scope: ProjectScope<'_>, item_id: &str) -> Result<Option<WorkItem>> {
        let conn = self.lock()?;
        conn.query_row(
            &format!("SELECT {ITEM_COLUMNS} {SCOPED_FROM} AND w.id = ?4"),
            params![
                scope.project_id,
                scope.workspace_id,
                scope.machine_id,
                item_id
            ],
            read_item,
        )
        .optional()
        .map_err(backend)?
        .map(item_from)
        .transpose()
    }

    fn insert_work_item(&self, scope: ProjectScope<'_>, item: &WorkItem) -> Result<bool> {
        let mut conn = self.lock()?;
        let tx = conn
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(backend)?;
        let project: Option<i64> = tx
            .query_row(
                "SELECT 1 FROM project WHERE id = ?1 AND workspace_id = ?2",
                params![scope.project_id, scope.workspace_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(backend)?;
        if project.is_none()
            || item.project_id != scope.project_id
            || !members_in_scope(&tx, scope, item)?
        {
            return Ok(false);
        }
        tx.execute(
            "INSERT INTO work_item (id, project_id, title, description, status, repo_id,
                                    conversation_id, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                item.id,
                item.project_id,
                item.title,
                item.description,
                item.status.as_str(),
                item.repo_id,
                item.conversation_id,
                item.created_at,
                item.updated_at
            ],
        )
        .map_err(backend)?;
        tx.commit().map_err(backend)?;
        Ok(true)
    }

    fn update_work_item(&self, scope: ProjectScope<'_>, item: &WorkItem) -> Result<bool> {
        let mut conn = self.lock()?;
        let tx = conn
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(backend)?;
        let current: Option<i64> = tx
            .query_row(
                &format!("SELECT 1 {SCOPED_FROM} AND w.id = ?4"),
                params![
                    scope.project_id,
                    scope.workspace_id,
                    scope.machine_id,
                    item.id
                ],
                |row| row.get(0),
            )
            .optional()
            .map_err(backend)?;
        if current.is_none() || !members_in_scope(&tx, scope, item)? {
            return Ok(false);
        }
        // Identity (project, conversation) is not in the SET: it never moves.
        tx.execute(
            "UPDATE work_item SET title = ?2, description = ?3, status = ?4, repo_id = ?5,
                                  updated_at = ?6
             WHERE id = ?1",
            params![
                item.id,
                item.title,
                item.description,
                item.status.as_str(),
                item.repo_id,
                item.updated_at
            ],
        )
        .map_err(backend)?;
        tx.commit().map_err(backend)?;
        Ok(true)
    }

    fn work_item_runs(&self, item_id: &str) -> Result<Vec<AgentTask>> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {TASK_COLUMNS} FROM agent_task WHERE work_item_id = ?1 ORDER BY id DESC"
            ))
            .map_err(backend)?;
        let rows = stmt
            .query_map(params![item_id], read_task)
            .map_err(backend)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(backend)?;
        rows.into_iter().map(AgentTask::try_from).collect()
    }

    fn set_work_item_status_for_run(
        &self,
        task_id: &str,
        status: WorkItemStatus,
        at_ms: i64,
    ) -> Result<Option<WorkItem>> {
        let mut conn = self.lock()?;
        let tx = conn
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(backend)?;
        let item_id: Option<String> = tx
            .query_row(
                "SELECT work_item_id FROM agent_task WHERE id = ?1",
                params![task_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(backend)?
            .flatten();
        let Some(item_id) = item_id else {
            return Ok(None);
        };
        tx.execute(
            "UPDATE work_item SET status = ?2, updated_at = ?3 WHERE id = ?1",
            params![item_id, status.as_str(), at_ms],
        )
        .map_err(backend)?;
        let item = tx
            .query_row(
                &format!("SELECT {ITEM_COLUMNS} FROM work_item w WHERE w.id = ?1"),
                params![item_id],
                read_item,
            )
            .optional()
            .map_err(backend)?
            .map(item_from)
            .transpose()?;
        tx.commit().map_err(backend)?;
        Ok(item)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use farhelm_app::store::{ProjectWorkflowStore, WorkspaceStore};
    use farhelm_proto::{Machine, Project, WorkMode};

    const NOW: i64 = 1_785_369_600_000;

    fn setup() -> (SqliteStore, String) {
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
        for (id, machine) in [("repo-a", "machine"), ("repo-z", "foreign-machine")] {
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
        let workspace = store.local_workspace_id().unwrap();
        for (id, workspace) in [("project-a", workspace.as_str()), ("foreign", "elsewhere")] {
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
            .attach_project_repository(
                ProjectScope {
                    workspace_id: &workspace,
                    machine_id: "machine",
                    project_id: "project-a",
                },
                "repo-a",
                1,
            )
            .unwrap()
            .expect("repo-a attaches to project-a");
        (store, workspace)
    }

    fn item(id: &str, project: &str, repo: Option<&str>) -> WorkItem {
        WorkItem {
            id: id.into(),
            project_id: project.into(),
            title: format!("Task {id}"),
            description: String::new(),
            status: WorkItemStatus::Todo,
            repo_id: repo.map(str::to_owned),
            conversation_id: None,
            created_at: NOW,
            updated_at: NOW,
        }
    }

    /// A run's row needs its session row first, as every real start writes.
    fn run(store: &SqliteStore, id: &str, item: &str) -> AgentTask {
        store
            .upsert_session(&Session {
                id: format!("session-{id}"),
                repo_id: "repo-a".into(),
                agent: Agent::Farhelm,
                tmux_target: None,
                status: SessionStatus::Running,
                plan_id: None,
                budget_usd: None,
                spent_usd: 0.0,
                started_at: NOW,
                ended_at: None,
                agent_session_id: None,
            })
            .unwrap();
        AgentTask {
            id: id.into(),
            session_id: format!("session-{id}"),
            repo_id: "repo-a".into(),
            prompt: "Do the task".into(),
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
            mode: WorkMode::Agent,
            model: None,
            work_item_id: Some(item.into()),
            decided_via: None,
            created_at: NOW,
            updated_at: NOW,
            decided_at: None,
        }
    }

    #[test]
    fn items_are_scoped_to_their_project_and_this_machine() {
        let (store, workspace) = setup();
        let scope = ProjectScope {
            workspace_id: &workspace,
            machine_id: "machine",
            project_id: "project-a",
        };
        assert!(
            store
                .insert_work_item(scope, &item("w1", "project-a", None))
                .unwrap()
        );
        assert!(
            store
                .insert_work_item(scope, &item("w2", "project-a", Some("repo-a")))
                .unwrap()
        );
        // Another project's repository, another machine's repository, and a
        // project outside the workspace are all refused.
        assert!(
            !store
                .insert_work_item(scope, &item("w3", "project-a", Some("repo-z")))
                .unwrap()
        );
        assert!(
            !store
                .insert_work_item(scope, &item("w4", "foreign", None))
                .unwrap()
        );
        let foreign = ProjectScope {
            project_id: "foreign",
            ..scope
        };
        assert!(
            !store
                .insert_work_item(foreign, &item("w5", "foreign", None))
                .unwrap()
        );

        let listed = store.work_items(scope, None, None, 10).unwrap();
        assert_eq!(
            listed
                .iter()
                .map(|item| item.id.as_str())
                .collect::<Vec<_>>(),
            ["w2", "w1"],
            "newest first"
        );
        assert!(store.work_item(foreign, "w1").unwrap().is_none());

        let mut moved = listed[0].clone();
        moved.status = WorkItemStatus::Review;
        moved.title = "Renamed".into();
        assert!(store.update_work_item(scope, &moved).unwrap());
        let read = store.work_item(scope, "w2").unwrap().unwrap();
        assert_eq!(
            (read.status, read.title.as_str()),
            (WorkItemStatus::Review, "Renamed")
        );
        assert!(!store.update_work_item(foreign, &moved).unwrap());
    }

    #[test]
    fn a_run_belongs_to_its_task_and_moves_it() {
        let (store, workspace) = setup();
        let scope = ProjectScope {
            workspace_id: &workspace,
            machine_id: "machine",
            project_id: "project-a",
        };
        assert!(
            store
                .insert_work_item(scope, &item("w1", "project-a", Some("repo-a")))
                .unwrap()
        );
        store.upsert_task(&run(&store, "r1", "w1")).unwrap();
        store.upsert_task(&run(&store, "r2", "w1")).unwrap();
        let runs = store.work_item_runs("w1").unwrap();
        assert_eq!(
            runs.iter().map(|run| run.id.as_str()).collect::<Vec<_>>(),
            ["r2", "r1"]
        );

        let moved = store
            .set_work_item_status_for_run("r2", WorkItemStatus::Review, NOW + 5)
            .unwrap()
            .expect("r2 belongs to w1");
        assert_eq!(
            (moved.status, moved.updated_at),
            (WorkItemStatus::Review, NOW + 5)
        );
        assert_eq!(
            store.work_item(scope, "w1").unwrap().unwrap().status,
            WorkItemStatus::Review
        );

        // A run with no task moves nothing.
        let mut loose = run(&store, "r3", "w1");
        loose.work_item_id = None;
        store.upsert_task(&loose).unwrap();
        assert!(
            store
                .set_work_item_status_for_run("r3", WorkItemStatus::Done, NOW)
                .unwrap()
                .is_none()
        );
    }
}
