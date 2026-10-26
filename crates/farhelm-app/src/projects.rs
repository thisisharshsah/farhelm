//! Local project metadata. Scope comes from the server's database, never input.

use std::fmt;

use farhelm_proto::types::{CreateProjectRequest, Project, ProjectPage};

use crate::id::new_id;
use crate::store::{StoreError, WorkspaceStore};

pub const DEFAULT_PROJECT_PAGE_SIZE: usize = 50;
pub const MAX_PROJECT_PAGE_SIZE: usize = 100;

#[derive(Debug)]
pub enum ProjectError {
    Validation(&'static str),
    NotFound,
    Store(StoreError),
}

impl fmt::Display for ProjectError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Validation(message) => f.write_str(message),
            Self::NotFound => f.write_str("project not found"),
            Self::Store(error) => write!(f, "{error}"),
        }
    }
}

impl std::error::Error for ProjectError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Store(error) => Some(error),
            _ => None,
        }
    }
}

impl From<StoreError> for ProjectError {
    fn from(error: StoreError) -> Self {
        Self::Store(error)
    }
}

/// The local workspace is resolved once from the store. This use case does not
/// accept client-provided workspace identities or expose unscoped lookups.
pub struct Projects<S> {
    store: S,
    workspace_id: String,
}

impl<S: WorkspaceStore> Projects<S> {
    pub fn new(store: S) -> Result<Self, ProjectError> {
        let workspace_id = store.local_workspace_id()?;
        Ok(Self {
            store,
            workspace_id,
        })
    }

    pub fn create(&self, input: CreateProjectRequest, at_ms: i64) -> Result<Project, ProjectError> {
        validate_name(&input.name)?;
        validate_description(&input.description)?;
        let project = Project {
            id: new_id(),
            workspace_id: self.workspace_id.clone(),
            name: input.name.trim().to_owned(),
            description: input.description,
            budget_cap_usd: None,
            created_at: at_ms,
            updated_at: at_ms,
        };
        self.store.insert_project(&project)?;
        Ok(project)
    }

    pub fn get(&self, id: &str) -> Result<Project, ProjectError> {
        self.store
            .get_project_in_workspace(&self.workspace_id, id)?
            .ok_or(ProjectError::NotFound)
    }

    /// Newest UUIDv7 identities first. Fetch one extra row to distinguish a
    /// complete page from a page whose last row is also the next cursor.
    pub fn list(&self, after: Option<&str>, limit: usize) -> Result<ProjectPage, ProjectError> {
        if !(1..=MAX_PROJECT_PAGE_SIZE).contains(&limit) {
            return Err(ProjectError::Validation("limit must be between 1 and 100"));
        }
        if after.is_some_and(|cursor| {
            cursor.len() > 128
                || !uuid::Uuid::parse_str(cursor)
                    .is_ok_and(|id| id.hyphenated().to_string() == cursor)
        }) {
            return Err(ProjectError::Validation("invalid project cursor"));
        }
        let mut projects = self
            .store
            .list_project_page(&self.workspace_id, after, limit + 1)?;
        let has_more = projects.len() > limit;
        projects.truncate(limit);
        let next_cursor = has_more
            .then(|| projects.last().map(|project| project.id.clone()))
            .flatten();
        Ok(ProjectPage {
            projects,
            next_cursor,
        })
    }
}

fn validate_name(name: &str) -> Result<(), ProjectError> {
    if name.len() > 480
        || name.chars().count() > 120
        || name.trim().is_empty()
        || name.chars().any(char::is_control)
    {
        return Err(ProjectError::Validation(
            "name must contain 1 to 120 characters without control characters",
        ));
    }
    Ok(())
}

fn validate_description(description: &str) -> Result<(), ProjectError> {
    if description.len() > 16_000
        || description.chars().count() > 4_000
        || description
            .chars()
            .any(|character| character.is_control() && !matches!(character, '\n' | '\t'))
    {
        return Err(ProjectError::Validation(
            "description must contain at most 4000 characters; only newline and tab controls are allowed",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::collections::BTreeMap;

    use farhelm_proto::types::{Conversation, Document, EntityKind, EntityLink};

    use super::*;
    use crate::store::Result as StoreResult;

    #[derive(Default)]
    struct MemoryStore(RefCell<BTreeMap<String, Project>>);

    impl WorkspaceStore for MemoryStore {
        fn local_workspace_id(&self) -> StoreResult<String> {
            Ok("local:test".to_owned())
        }

        fn insert_project(&self, project: &Project) -> StoreResult<()> {
            let mut rows = self.0.borrow_mut();
            if rows.contains_key(&project.id) {
                return Err(StoreError::Corrupt("duplicate project identity".into()));
            }
            rows.insert(project.id.clone(), project.clone());
            Ok(())
        }

        fn get_project_in_workspace(&self, scope: &str, id: &str) -> StoreResult<Option<Project>> {
            Ok(self
                .0
                .borrow()
                .get(id)
                .filter(|project| project.workspace_id == scope)
                .cloned())
        }

        fn list_project_page(
            &self,
            scope: &str,
            after: Option<&str>,
            limit: usize,
        ) -> StoreResult<Vec<Project>> {
            Ok(self
                .0
                .borrow()
                .values()
                .rev()
                .filter(|project| {
                    project.workspace_id == scope
                        && after.is_none_or(|cursor| project.id.as_str() < cursor)
                })
                .take(limit)
                .cloned()
                .collect())
        }

        fn put_project(&self, _: &Project) -> StoreResult<()> {
            unreachable!("the local use case never uses upsert")
        }
        fn get_project(&self, _: &str) -> StoreResult<Option<Project>> {
            unreachable!("the local use case never uses an unscoped lookup")
        }
        fn list_projects(&self, _: &str) -> StoreResult<Vec<Project>> {
            unreachable!("the local use case never uses an unbounded query")
        }
        fn put_conversation(&self, _: &Conversation) -> StoreResult<()> {
            unreachable!()
        }
        fn get_conversation(&self, _: &str) -> StoreResult<Option<Conversation>> {
            unreachable!()
        }
        fn list_conversations(&self, _: &str) -> StoreResult<Vec<Conversation>> {
            unreachable!()
        }
        fn put_document(&self, _: &Document) -> StoreResult<()> {
            unreachable!()
        }
        fn get_document(&self, _: &str) -> StoreResult<Option<Document>> {
            unreachable!()
        }
        fn list_documents(&self, _: &str) -> StoreResult<Vec<Document>> {
            unreachable!()
        }
        fn put_entity_link(&self, _: &EntityLink) -> StoreResult<EntityLink> {
            unreachable!()
        }
        fn list_links_from(&self, _: EntityKind, _: &str) -> StoreResult<Vec<EntityLink>> {
            unreachable!()
        }
        fn list_links_to(&self, _: EntityKind, _: &str) -> StoreResult<Vec<EntityLink>> {
            unreachable!()
        }
        fn remove_entity_link(&self, _: &str) -> StoreResult<bool> {
            unreachable!()
        }
    }

    fn input(name: &str, description: &str) -> CreateProjectRequest {
        CreateProjectRequest {
            name: name.into(),
            description: description.into(),
        }
    }

    #[test]
    fn create_uses_persisted_scope_and_explicit_timestamp() {
        let store = MemoryStore::default();
        let projects = Projects::new(&store).unwrap();
        let created = projects
            .create(input("  Research  ", "Plan\n\tSteps"), 123)
            .unwrap();
        assert_eq!(created.name, "Research");
        assert_eq!(created.description, "Plan\n\tSteps");
        assert_eq!(created.workspace_id, "local:test");
        assert_eq!(created.created_at, 123);
        assert_eq!(created.updated_at, 123);
        assert_eq!(created.budget_cap_usd, None);
        assert_eq!(projects.get(&created.id).unwrap(), created);
    }

    #[test]
    fn invalid_input_is_rejected_before_storage() {
        let store = MemoryStore::default();
        let projects = Projects::new(&store).unwrap();
        for name in ["", "   ", "with\nnewline", "nul\0", &"é".repeat(121)] {
            assert!(matches!(
                projects.create(input(name, ""), 0),
                Err(ProjectError::Validation(_))
            ));
        }
        for description in ["nul\0", "escape\u{1b}", &"x".repeat(4001)] {
            assert!(matches!(
                projects.create(input("Valid", description), 0),
                Err(ProjectError::Validation(_))
            ));
        }
        assert!(store.0.borrow().is_empty());
        let boundary = projects
            .create(input(&"🦀".repeat(120), &"🦀".repeat(4000)), 0)
            .unwrap();
        assert_eq!(boundary.description.len(), 16_000);
    }

    #[test]
    fn pagination_is_bounded_ordered_and_scope_filtered() {
        let store = MemoryStore::default();
        let projects = Projects::new(&store).unwrap();
        let mut created = Vec::new();
        for _ in 0..5 {
            created.push(projects.create(input("Project", ""), 1).unwrap());
        }
        let mut foreign = created[0].clone();
        foreign.id = "foreign-project".into();
        foreign.workspace_id = "other-workspace".into();
        store.insert_project(&foreign).unwrap();
        assert!(matches!(
            projects.get(&foreign.id),
            Err(ProjectError::NotFound)
        ));
        assert!(matches!(
            projects.get("missing"),
            Err(ProjectError::NotFound)
        ));

        let first = projects.list(None, 2).unwrap();
        assert_eq!(first.projects, vec![created[4].clone(), created[3].clone()]);
        assert_eq!(first.next_cursor.as_deref(), Some(created[3].id.as_str()));
        let second = projects.list(first.next_cursor.as_deref(), 2).unwrap();
        assert_eq!(
            second.projects,
            vec![created[2].clone(), created[1].clone()]
        );
        let last = projects.list(second.next_cursor.as_deref(), 2).unwrap();
        assert_eq!(last.projects, vec![created[0].clone()]);
        assert_eq!(last.next_cursor, None);
        let exact = projects.list(Some(&created[2].id), 2).unwrap();
        assert_eq!(exact.projects.len(), 2);
        assert_eq!(exact.next_cursor, None);
    }

    #[test]
    fn rejects_invalid_page_parameters() {
        let projects = Projects::new(MemoryStore::default()).unwrap();
        for limit in [0, 101, usize::MAX] {
            assert!(matches!(
                projects.list(None, limit),
                Err(ProjectError::Validation(_))
            ));
        }
        for cursor in [
            "",
            "not-a-uuid",
            "line\n",
            "00112233445566778899aabbccddeeff",
            "00112233-4455-6677-8899-AABBCCDDEEFF",
            &"x".repeat(129),
        ] {
            assert!(matches!(
                projects.list(Some(cursor), 50),
                Err(ProjectError::Validation(_))
            ));
        }
        assert!(projects.list(None, 100).unwrap().projects.is_empty());
    }
}
