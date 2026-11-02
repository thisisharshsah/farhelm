//! Tasks on a project's board: planned work that agent runs are attempts on.
//!
//! In the app a *task* is the planned unit of work and a *run* is one agent
//! attempt on it (user direction, 2026-11-02). In code the task is a work
//! item, because `agent_task` (the run) took the name first. This module
//! holds the rules: what a task may say, how it moves, and what a run started
//! from it inherits. Storage and execution stay outside.

use std::fmt;

use farhelm_proto::{
    AgentTask, CreateWorkItemRequest, StartWorkItemRunRequest, TaskStatus, UpdateWorkItemRequest,
    WorkItem, WorkItemStatus, types::StartProjectTaskRequest,
};

use crate::store::{ProjectScope, StoreError, WorkItemStore, WorkspaceStore};

pub const TITLE_MAX_CHARS: usize = 200;
pub const DESCRIPTION_MAX_BYTES: usize = 64 * 1024;

#[derive(Debug)]
pub enum WorkItemError {
    Validation(&'static str),
    NotFound,
    Conflict(&'static str),
    Store(StoreError),
}

impl fmt::Display for WorkItemError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Validation(message) | Self::Conflict(message) => f.write_str(message),
            Self::NotFound => f.write_str("task not found"),
            Self::Store(error) => write!(f, "{error}"),
        }
    }
}

impl std::error::Error for WorkItemError {}
impl From<StoreError> for WorkItemError {
    fn from(value: StoreError) -> Self {
        Self::Store(value)
    }
}

pub struct WorkItemRows {
    pub items: Vec<WorkItem>,
    pub next_cursor: Option<String>,
}

pub struct WorkItems<S> {
    store: S,
    workspace_id: String,
    machine_id: String,
}

impl<S: WorkItemStore + WorkspaceStore> WorkItems<S> {
    pub fn new(store: S, machine_id: &str) -> Result<Self, WorkItemError> {
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

    fn require_project(&self, project_id: &str) -> Result<(), WorkItemError> {
        validate_id(project_id)?;
        if self
            .store
            .get_project_in_workspace(&self.workspace_id, project_id)?
            .is_none()
        {
            return Err(WorkItemError::NotFound);
        }
        Ok(())
    }

    pub fn list(
        &self,
        project_id: &str,
        conversation_id: Option<&str>,
        after: Option<&str>,
        limit: usize,
    ) -> Result<WorkItemRows, WorkItemError> {
        if !(1..=100).contains(&limit) {
            return Err(WorkItemError::Validation("limit must be between 1 and 100"));
        }
        if let Some(id) = after {
            validate_id(id)?;
        }
        if let Some(id) = conversation_id {
            validate_id(id)?;
        }
        self.require_project(project_id)?;
        let mut items =
            self.store
                .work_items(self.scope(project_id), conversation_id, after, limit + 1)?;
        let more = items.len() > limit;
        items.truncate(limit);
        let next_cursor = more.then(|| items.last().unwrap().id.clone());
        Ok(WorkItemRows { items, next_cursor })
    }

    pub fn get(&self, project_id: &str, item_id: &str) -> Result<WorkItem, WorkItemError> {
        validate_id(project_id)?;
        validate_id(item_id)?;
        self.store
            .work_item(self.scope(project_id), item_id)?
            .ok_or(WorkItemError::NotFound)
    }

    pub fn create(
        &self,
        project_id: &str,
        request: &CreateWorkItemRequest,
        at_ms: i64,
    ) -> Result<WorkItem, WorkItemError> {
        self.require_project(project_id)?;
        let title = validate_title(&request.title)?;
        validate_description(&request.description)?;
        if let Some(id) = &request.repo_id {
            validate_id(id)?;
        }
        if let Some(id) = &request.conversation_id {
            validate_id(id)?;
        }
        let item = WorkItem {
            id: crate::id::new_id(),
            project_id: project_id.into(),
            title,
            description: request.description.clone(),
            status: request.status.unwrap_or(WorkItemStatus::Todo),
            repo_id: request.repo_id.clone(),
            conversation_id: request.conversation_id.clone(),
            created_at: at_ms,
            updated_at: at_ms,
        };
        if !self.store.insert_work_item(self.scope(project_id), &item)? {
            // The repository or conversation is not this project's.
            return Err(WorkItemError::NotFound);
        }
        Ok(item)
    }

    pub fn update(
        &self,
        project_id: &str,
        item_id: &str,
        request: &UpdateWorkItemRequest,
        at_ms: i64,
    ) -> Result<WorkItem, WorkItemError> {
        let mut item = self.get(project_id, item_id)?;
        if let Some(title) = &request.title {
            item.title = validate_title(title)?;
        }
        if let Some(description) = &request.description {
            validate_description(description)?;
            item.description = description.clone();
        }
        if let Some(status) = request.status {
            item.status = status;
        }
        if let Some(repo_id) = &request.repo_id {
            validate_id(repo_id)?;
            item.repo_id = Some(repo_id.clone());
        }
        item.updated_at = at_ms;
        if !self.store.update_work_item(self.scope(project_id), &item)? {
            return Err(WorkItemError::NotFound);
        }
        Ok(item)
    }

    pub fn runs(&self, project_id: &str, item_id: &str) -> Result<Vec<AgentTask>, WorkItemError> {
        self.get(project_id, item_id)?;
        Ok(self.store.work_item_runs(item_id)?)
    }

    /// The run request a task implies: its repository and its text unless the
    /// request names others. Refused while a run is still working, because
    /// two agents on one task would propose two change sets for one decision.
    pub fn run_request(
        &self,
        project_id: &str,
        item_id: &str,
        request: &StartWorkItemRunRequest,
    ) -> Result<StartProjectTaskRequest, WorkItemError> {
        let item = self.get(project_id, item_id)?;
        if self
            .store
            .work_item_runs(item_id)?
            .iter()
            .any(|run| run.status == TaskStatus::Running)
        {
            return Err(WorkItemError::Conflict(
                "a run is already working on this task",
            ));
        }
        let repo_id = request
            .repo_id
            .clone()
            .or_else(|| item.repo_id.clone())
            .ok_or(WorkItemError::Validation(
                "choose a repository for this task before running it",
            ))?;
        let prompt = match request.prompt.as_deref().map(str::trim) {
            Some(prompt) if !prompt.is_empty() => prompt.to_owned(),
            _ if item.description.trim().is_empty() => item.title.clone(),
            _ => format!("{}\n\n{}", item.title, item.description.trim()),
        };
        Ok(StartProjectTaskRequest {
            repo_id,
            prompt,
            budget_usd: request.budget_usd,
            max_steps: request.max_steps,
            retry_of: None,
            model: request.model.clone(),
            work_item_id: Some(item.id),
        })
    }

    /// Where a task stands after one of its runs changed. `None` when the run
    /// belongs to no task.
    pub fn follow_run(
        &self,
        run: &AgentTask,
        at_ms: i64,
    ) -> Result<Option<WorkItem>, WorkItemError> {
        if run.work_item_id.is_none() {
            return Ok(None);
        }
        Ok(self
            .store
            .set_work_item_status_for_run(&run.id, status_after(run.status), at_ms)?)
    }
}

/// How a run's status moves the task it belongs to.
pub fn status_after(run: TaskStatus) -> WorkItemStatus {
    match run {
        TaskStatus::Running => WorkItemStatus::InProgress,
        TaskStatus::AwaitingReview => WorkItemStatus::Review,
        TaskStatus::Applied => WorkItemStatus::Done,
        // The work is still to do: rejected with a reason, undone, failed,
        // or finished without changing anything.
        TaskStatus::Rejected
        | TaskStatus::Reverted
        | TaskStatus::Failed
        | TaskStatus::NoChanges => WorkItemStatus::Todo,
    }
}

fn validate_title(title: &str) -> Result<String, WorkItemError> {
    let title = title.trim();
    if title.is_empty()
        || title.chars().count() > TITLE_MAX_CHARS
        || title.chars().any(char::is_control)
    {
        return Err(WorkItemError::Validation(
            "title must be 1 to 200 characters on one line",
        ));
    }
    Ok(title.to_owned())
}

fn validate_description(description: &str) -> Result<(), WorkItemError> {
    if description.len() > DESCRIPTION_MAX_BYTES
        || description
            .chars()
            .any(|c| c.is_control() && c != '\n' && c != '\r' && c != '\t')
    {
        return Err(WorkItemError::Validation(
            "description must fit within 64 KiB without control characters",
        ));
    }
    Ok(())
}

fn validate_id(id: &str) -> Result<(), WorkItemError> {
    if id.is_empty() || id.len() > 128 || id.chars().any(char::is_control) {
        return Err(WorkItemError::Validation("invalid resource identity"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_run_moves_its_task() {
        assert_eq!(
            status_after(TaskStatus::Running),
            WorkItemStatus::InProgress
        );
        assert_eq!(
            status_after(TaskStatus::AwaitingReview),
            WorkItemStatus::Review
        );
        assert_eq!(status_after(TaskStatus::Applied), WorkItemStatus::Done);
        for back in [
            TaskStatus::Rejected,
            TaskStatus::Reverted,
            TaskStatus::Failed,
            TaskStatus::NoChanges,
        ] {
            assert_eq!(status_after(back), WorkItemStatus::Todo);
        }
    }

    #[test]
    fn titles_are_one_bounded_line() {
        assert_eq!(validate_title("  Fix the cap  ").unwrap(), "Fix the cap");
        assert!(validate_title("   ").is_err());
        assert!(validate_title("two\nlines").is_err());
        assert!(validate_title(&"x".repeat(201)).is_err());
    }
}
