//! Direct-only project workflow composition, without execution or transport.

use std::fmt;

use farhelm_proto::types::{
    AgentTask, ProjectRepository, ProjectRepositoryPage, Repo, Session, StartProjectTaskRequest,
    TaskStatus,
};

use crate::store::{
    ProjectScope, ProjectTaskInsertOutcome, ProjectWorkflowStore, StoreError, WorkspaceStore,
};

#[derive(Debug)]
pub enum ProjectWorkflowError {
    Validation(&'static str),
    NotFound,
    Conflict(&'static str),
    Store(StoreError),
}

impl fmt::Display for ProjectWorkflowError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Validation(message) | Self::Conflict(message) => f.write_str(message),
            Self::NotFound => f.write_str("project resource not found"),
            Self::Store(error) => write!(f, "{error}"),
        }
    }
}

impl std::error::Error for ProjectWorkflowError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Store(error) => Some(error),
            _ => None,
        }
    }
}

impl From<StoreError> for ProjectWorkflowError {
    fn from(error: StoreError) -> Self {
        Self::Store(error)
    }
}

pub struct ProjectTaskRows {
    pub tasks: Vec<AgentTask>,
    pub next_cursor: Option<String>,
}

pub struct ProjectWorkflow<S> {
    store: S,
    workspace_id: String,
    machine_id: String,
}

impl<S: WorkspaceStore + ProjectWorkflowStore> ProjectWorkflow<S> {
    pub fn new(store: S, machine_id: &str) -> Result<Self, ProjectWorkflowError> {
        let workspace_id = store.local_workspace_id()?;
        Ok(Self {
            store,
            workspace_id,
            machine_id: machine_id.into(),
        })
    }

    fn scope<'a>(&'a self, project_id: &'a str) -> ProjectScope<'a> {
        ProjectScope {
            workspace_id: &self.workspace_id,
            machine_id: &self.machine_id,
            project_id,
        }
    }

    fn require_project(&self, project_id: &str) -> Result<(), ProjectWorkflowError> {
        if self
            .store
            .get_project_in_workspace(&self.workspace_id, project_id)?
            .is_none()
        {
            return Err(ProjectWorkflowError::NotFound);
        }
        Ok(())
    }

    pub fn repository_candidates(
        &self,
        project_id: &str,
        after: Option<&str>,
        limit: usize,
    ) -> Result<ProjectRepositoryPage, ProjectWorkflowError> {
        validate_page(after, limit)?;
        self.require_project(project_id)?;
        let rows =
            self.store
                .project_repository_candidates(self.scope(project_id), after, limit + 1)?;
        Ok(repository_page(rows, limit))
    }

    pub fn repositories(
        &self,
        project_id: &str,
        after: Option<&str>,
        limit: usize,
    ) -> Result<ProjectRepositoryPage, ProjectWorkflowError> {
        validate_page(after, limit)?;
        self.require_project(project_id)?;
        let rows = self
            .store
            .project_repositories(self.scope(project_id), after, limit + 1)?;
        Ok(repository_page(rows, limit))
    }

    pub fn attach_repository(
        &self,
        project_id: &str,
        repo_id: &str,
        at_ms: i64,
    ) -> Result<ProjectRepository, ProjectWorkflowError> {
        validate_id(repo_id)?;
        self.store
            .attach_project_repository(self.scope(project_id), repo_id, at_ms)?
            .map(repository_view)
            .ok_or(ProjectWorkflowError::NotFound)
    }

    pub fn prepare(
        &self,
        project_id: &str,
        repo_id: &str,
        retry_of: Option<&str>,
    ) -> Result<(Repo, Option<AgentTask>), ProjectWorkflowError> {
        validate_id(repo_id)?;
        let repo = self
            .store
            .project_repository(self.scope(project_id), repo_id)?
            .ok_or(ProjectWorkflowError::NotFound)?;
        let previous = retry_of
            .map(|task_id| {
                validate_id(task_id)?;
                // The SQL predicate checks project AND repository before loading
                // any previous prompt, rejection note or diff into application code.
                let task = self
                    .store
                    .project_task(self.scope(project_id), task_id, Some(repo_id))?
                    .ok_or(ProjectWorkflowError::NotFound)?;
                if task.status != TaskStatus::Rejected {
                    return Err(ProjectWorkflowError::Conflict(
                        "only rejected tasks may be retried",
                    ));
                }
                Ok(task)
            })
            .transpose()?;
        Ok((repo, previous))
    }

    pub fn task(&self, project_id: &str, task_id: &str) -> Result<AgentTask, ProjectWorkflowError> {
        self.store
            .project_task(self.scope(project_id), task_id, None)?
            .ok_or(ProjectWorkflowError::NotFound)
    }

    pub fn tasks(
        &self,
        project_id: &str,
        after: Option<&str>,
        limit: usize,
    ) -> Result<ProjectTaskRows, ProjectWorkflowError> {
        validate_page(after, limit)?;
        self.require_project(project_id)?;
        let mut tasks = self
            .store
            .project_tasks(self.scope(project_id), after, limit + 1)?;
        let more = tasks.len() > limit;
        tasks.truncate(limit);
        let next_cursor = if more {
            tasks.last().map(|task| task.id.clone())
        } else {
            None
        };
        Ok(ProjectTaskRows { tasks, next_cursor })
    }

    pub fn insert_task(
        &self,
        project_id: &str,
        session: &Session,
        task: &AgentTask,
        retry_of: Option<&str>,
    ) -> Result<(), ProjectWorkflowError> {
        match self
            .store
            .insert_project_task(self.scope(project_id), session, task, retry_of)?
        {
            ProjectTaskInsertOutcome::Inserted => Ok(()),
            ProjectTaskInsertOutcome::NotFound => Err(ProjectWorkflowError::NotFound),
            ProjectTaskInsertOutcome::RetryNotRejected => Err(ProjectWorkflowError::Conflict(
                "only rejected tasks may be retried",
            )),
            ProjectTaskInsertOutcome::InvalidTask => Err(ProjectWorkflowError::Validation(
                "task and session must identify the same running repository workflow",
            )),
        }
    }
}

fn repository_view(repo: Repo) -> ProjectRepository {
    ProjectRepository {
        id: repo.id,
        name: repo.name,
        path: repo.path,
    }
}

fn repository_page(mut rows: Vec<Repo>, limit: usize) -> ProjectRepositoryPage {
    let more = rows.len() > limit;
    rows.truncate(limit);
    let next_cursor = if more {
        rows.last().map(|repo| repo.id.clone())
    } else {
        None
    };
    ProjectRepositoryPage {
        repositories: rows.into_iter().map(repository_view).collect(),
        next_cursor,
    }
}

fn validate_id(id: &str) -> Result<(), ProjectWorkflowError> {
    if id.is_empty() || id.len() > 128 || id.chars().any(char::is_control) {
        return Err(ProjectWorkflowError::Validation(
            "invalid resource identity",
        ));
    }
    Ok(())
}

fn validate_page(after: Option<&str>, limit: usize) -> Result<(), ProjectWorkflowError> {
    if !(1..=100).contains(&limit) {
        return Err(ProjectWorkflowError::Validation(
            "limit must be between 1 and 100",
        ));
    }
    if let Some(after) = after {
        validate_id(after)?;
    }
    Ok(())
}

pub fn validate_start_task(input: &StartProjectTaskRequest) -> Result<(), ProjectWorkflowError> {
    validate_id(&input.repo_id)?;
    if let Some(id) = &input.retry_of {
        validate_id(id)?;
    }
    if input.prompt.trim().is_empty() || input.prompt.len() > 64 * 1024 {
        return Err(ProjectWorkflowError::Validation(
            "prompt must be nonblank and at most 64 KiB",
        ));
    }
    if input
        .budget_usd
        .is_some_and(|budget| !budget.is_finite() || budget <= 0.0)
    {
        return Err(ProjectWorkflowError::Validation(
            "budget must be positive and finite",
        ));
    }
    if input
        .max_steps
        .is_some_and(|steps| !(1..=256).contains(&steps))
    {
        return Err(ProjectWorkflowError::Validation(
            "max_steps must be between 1 and 256",
        ));
    }
    Ok(())
}
