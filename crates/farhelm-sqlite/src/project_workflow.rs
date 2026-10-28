use super::*;
use farhelm_app::store::{ProjectScope, ProjectTaskInsertOutcome, ProjectWorkflowStore};

fn read_repo(row: &Row<'_>) -> rusqlite::Result<Repo> {
    Ok(Repo {
        id: row.get(0)?,
        machine_id: row.get(1)?,
        path: row.get(2)?,
        name: row.get(3)?,
        budget_usd: row.get(4)?,
    })
}

fn scoped_repo(conn: &Connection, scope: ProjectScope<'_>, repo_id: &str) -> Result<Option<Repo>> {
    conn.query_row(
        "SELECT r.id,r.machine_id,r.path,r.name,r.budget_usd FROM repo r
         JOIN project_repo pr ON pr.repo_id=r.id JOIN project p ON p.id=pr.project_id
         WHERE p.id=?1 AND p.workspace_id=?2 AND r.machine_id=?3 AND r.id=?4",
        params![
            scope.project_id,
            scope.workspace_id,
            scope.machine_id,
            repo_id
        ],
        read_repo,
    )
    .optional()
    .map_err(backend)
}

impl ProjectWorkflowStore for SqliteStore {
    fn project_repository_candidates(
        &self,
        scope: ProjectScope<'_>,
        after: Option<&str>,
        limit: usize,
    ) -> Result<Vec<Repo>> {
        let conn = self.lock()?;
        let limit = i64::try_from(limit).map_err(|error| StoreError::Backend(Box::new(error)))?;
        let mut stmt = conn.prepare(
            // A repository with no path is the gateway's bookkeeping row for
            // direct API calls; nothing can be attached to or run in it.
            "SELECT r.id,r.machine_id,r.path,r.name,r.budget_usd FROM repo r
             WHERE r.machine_id=?3 AND r.path <> '' AND EXISTS (SELECT 1 FROM project WHERE id=?1 AND workspace_id=?2)
               AND (?4 IS NULL OR r.id<?4) ORDER BY r.id DESC LIMIT ?5"
        ).map_err(backend)?;
        stmt.query_map(
            params![
                scope.project_id,
                scope.workspace_id,
                scope.machine_id,
                after,
                limit
            ],
            read_repo,
        )
        .map_err(backend)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(backend)
    }

    fn project_repositories(
        &self,
        scope: ProjectScope<'_>,
        after: Option<&str>,
        limit: usize,
    ) -> Result<Vec<Repo>> {
        let conn = self.lock()?;
        let limit = i64::try_from(limit).map_err(|error| StoreError::Backend(Box::new(error)))?;
        let mut stmt = conn
            .prepare(
                "SELECT r.id,r.machine_id,r.path,r.name,r.budget_usd FROM repo r
             JOIN project_repo pr ON pr.repo_id=r.id JOIN project p ON p.id=pr.project_id
             WHERE p.id=?1 AND p.workspace_id=?2 AND r.machine_id=?3
               AND (?4 IS NULL OR r.id<?4) ORDER BY r.id DESC LIMIT ?5",
            )
            .map_err(backend)?;
        stmt.query_map(
            params![
                scope.project_id,
                scope.workspace_id,
                scope.machine_id,
                after,
                limit
            ],
            read_repo,
        )
        .map_err(backend)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(backend)
    }

    fn attach_project_repository(
        &self,
        scope: ProjectScope<'_>,
        repo_id: &str,
        at_ms: i64,
    ) -> Result<Option<Repo>> {
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO project_repo(project_id,repo_id,attached_at)
             SELECT p.id,r.id,?5 FROM project p JOIN repo r ON r.id=?4
             WHERE p.id=?1 AND p.workspace_id=?2 AND r.machine_id=?3
             ON CONFLICT(project_id,repo_id) DO NOTHING",
            params![
                scope.project_id,
                scope.workspace_id,
                scope.machine_id,
                repo_id,
                at_ms
            ],
        )
        .map_err(backend)?;
        scoped_repo(&conn, scope, repo_id)
    }

    fn project_repository(&self, scope: ProjectScope<'_>, repo_id: &str) -> Result<Option<Repo>> {
        let conn = self.lock()?;
        scoped_repo(&conn, scope, repo_id)
    }

    fn project_task(
        &self,
        scope: ProjectScope<'_>,
        task_id: &str,
        repo_id: Option<&str>,
    ) -> Result<Option<AgentTask>> {
        let conn = self.lock()?;
        let raw = conn
            .query_row(
                &format!(
                    "SELECT {TASK_COLUMNS} FROM agent_task WHERE id IN (
                SELECT pt.task_id FROM project_task pt JOIN project p ON p.id=pt.project_id
                JOIN repo r ON r.id=pt.repo_id WHERE p.id=?1 AND p.workspace_id=?2
                AND r.machine_id=?3 AND pt.task_id=?4 AND (?5 IS NULL OR pt.repo_id=?5))"
                ),
                params![
                    scope.project_id,
                    scope.workspace_id,
                    scope.machine_id,
                    task_id,
                    repo_id
                ],
                read_task,
            )
            .optional()
            .map_err(backend)?;
        raw.map(AgentTask::try_from).transpose()
    }

    fn project_tasks(
        &self,
        scope: ProjectScope<'_>,
        after: Option<&str>,
        limit: usize,
    ) -> Result<Vec<AgentTask>> {
        let conn = self.lock()?;
        let limit = i64::try_from(limit).map_err(|error| StoreError::Backend(Box::new(error)))?;
        let mut stmt = conn.prepare(&format!(
            "SELECT {TASK_COLUMNS} FROM agent_task WHERE id IN (
             SELECT pt.task_id FROM project_task pt JOIN project p ON p.id=pt.project_id JOIN repo r ON r.id=pt.repo_id
             WHERE p.id=?1 AND p.workspace_id=?2 AND r.machine_id=?3
               AND (?4 IS NULL OR pt.task_id<?4) ORDER BY pt.task_id DESC LIMIT ?5)
             ORDER BY id DESC"
        )).map_err(backend)?;
        let rows = stmt
            .query_map(
                params![
                    scope.project_id,
                    scope.workspace_id,
                    scope.machine_id,
                    after,
                    limit
                ],
                read_task,
            )
            .map_err(backend)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(backend)?;
        rows.into_iter().map(AgentTask::try_from).collect()
    }

    fn project_for_task(&self, task_id: &str) -> Result<Option<String>> {
        self.lock()?
            .query_row(
                "SELECT project_id FROM project_task WHERE task_id=?1",
                params![task_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(backend)
    }

    fn insert_project_task(
        &self,
        scope: ProjectScope<'_>,
        session: &Session,
        task: &AgentTask,
        retry_of: Option<&str>,
    ) -> Result<ProjectTaskInsertOutcome> {
        if session.id != task.session_id
            || session.repo_id != task.repo_id
            || session.status != SessionStatus::Running
            || task.status != TaskStatus::Running
            || session.agent != Agent::Farhelm
        {
            return Ok(ProjectTaskInsertOutcome::InvalidTask);
        }
        let mut conn = self.lock()?;
        let tx = conn
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(backend)?;
        if scoped_repo(&tx, scope, &task.repo_id)?.is_none() {
            return Ok(ProjectTaskInsertOutcome::NotFound);
        }
        if let Some(previous) = retry_of {
            let status: Option<String> = tx
                .query_row(
                    "SELECT t.status FROM project_task pt JOIN agent_task t ON t.id=pt.task_id
                 WHERE pt.task_id=?1 AND pt.project_id=?2 AND pt.repo_id=?3",
                    params![previous, scope.project_id, task.repo_id],
                    |row| row.get(0),
                )
                .optional()
                .map_err(backend)?;
            match status.as_deref() {
                None => return Ok(ProjectTaskInsertOutcome::NotFound),
                Some("rejected") => {}
                Some(_) => return Ok(ProjectTaskInsertOutcome::RetryNotRejected),
            }
        }
        tx.execute(
            "INSERT INTO session(id,repo_id,agent,tmux_target,status,plan_id,budget_usd,spent_usd,started_at,ended_at,agent_session_id)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
            params![session.id,session.repo_id,session.agent.as_str(),session.tmux_target,session.status.as_str(),session.plan_id,
                session.budget_usd,session.spent_usd,session.started_at,session.ended_at,session.agent_session_id],
        ).map_err(backend)?;
        tx.execute(
            &format!(
                "INSERT INTO agent_task ({TASK_COLUMNS}) VALUES
            (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22)"
            ),
            params![
                task.id,
                task.session_id,
                task.repo_id,
                task.prompt,
                task.status.as_str(),
                task.summary,
                task.diff_json,
                task.worktree_json,
                task.files_changed,
                task.lines_added,
                task.lines_removed,
                task.steps,
                task.cost_usd,
                task.error,
                task.review_note,
                task.decided_via.map(|via| via.as_str()),
                task.created_at,
                task.updated_at,
                task.decided_at,
                task.verify_grade,
                task.verify_notes,
                task.verify_model
            ],
        )
        .map_err(backend)?;
        tx.execute("INSERT INTO project_task(task_id,project_id,repo_id,retry_of,created_at) VALUES (?1,?2,?3,?4,?5)",
            params![task.id,scope.project_id,task.repo_id,retry_of,task.created_at]).map_err(backend)?;
        tx.commit().map_err(backend)?;
        Ok(ProjectTaskInsertOutcome::Inserted)
    }
}

#[cfg(test)]
mod tests;
