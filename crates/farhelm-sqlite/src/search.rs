//! Workspace search: one query over the four kinds of thing a person looks
//! for, newest first.
//!
//! A plain `LIKE` scan. SQLite folds ASCII case for `LIKE`, and the pattern is
//! escaped so a `%` or `_` in the query matches itself. Long text is cut to a
//! bounded prefix in SQL, so a 4 MB summary never crosses into the process
//! just to be trimmed there.

use super::*;
use farhelm_app::store::{SearchRow, SearchStore};
use farhelm_proto::SearchHitKind;

/// How much of a description or summary is returned for snippet extraction.
const BODY_PREFIX_CHARS: i64 = 4_000;

/// Escape `LIKE` wildcards so the query is matched literally.
fn like_pattern(needle: &str) -> String {
    let mut pattern = String::with_capacity(needle.len() + 2);
    pattern.push('%');
    for c in needle.chars() {
        if matches!(c, '%' | '_' | '\\') {
            pattern.push('\\');
        }
        pattern.push(c);
    }
    pattern.push('%');
    pattern
}

impl SearchStore for SqliteStore {
    fn search_workspace(
        &self,
        workspace_id: &str,
        machine_id: &str,
        needle: &str,
        limit: usize,
    ) -> Result<Vec<SearchRow>> {
        let conn = self.lock()?;
        let limit = i64::try_from(limit).map_err(|error| StoreError::Backend(Box::new(error)))?;
        let pattern = like_pattern(needle);
        let mut stmt = conn
            .prepare(
                "SELECT kind, id, project_id, project_name, title, substr(body, 1, ?4), status, updated_at
                 FROM (
                   SELECT 'project' AS kind, p.id AS id, p.id AS project_id, p.name AS project_name,
                          p.name AS title, p.description AS body, NULL AS status,
                          p.updated_at AS updated_at
                   FROM project p
                   WHERE p.workspace_id = ?1
                     AND (p.name LIKE ?2 ESCAPE '\\' OR p.description LIKE ?2 ESCAPE '\\')
                   UNION ALL
                   SELECT 'task', w.id, p.id, p.name, w.title, w.description, w.status, w.updated_at
                   FROM work_item w JOIN project p ON p.id = w.project_id
                   WHERE p.workspace_id = ?1
                     AND (w.title LIKE ?2 ESCAPE '\\' OR w.description LIKE ?2 ESCAPE '\\')
                   UNION ALL
                   SELECT 'run', t.id, p.id, p.name, t.prompt, t.summary, t.status, t.updated_at
                   FROM project_task pt
                   JOIN agent_task t ON t.id = pt.task_id
                   JOIN project p ON p.id = pt.project_id
                   JOIN repo r ON r.id = pt.repo_id
                   WHERE p.workspace_id = ?1 AND r.machine_id = ?3
                     AND (t.prompt LIKE ?2 ESCAPE '\\' OR t.summary LIKE ?2 ESCAPE '\\')
                   UNION ALL
                   SELECT 'conversation', c.id, p.id, p.name, c.title, '', NULL, c.updated_at
                   FROM conversation c JOIN project p ON p.id = c.project_id
                   WHERE p.workspace_id = ?1 AND c.title LIKE ?2 ESCAPE '\\'
                 )
                 ORDER BY updated_at DESC, id DESC
                 LIMIT ?5",
            )
            .map_err(backend)?;
        let raw = stmt
            .query_map(
                params![workspace_id, pattern, machine_id, BODY_PREFIX_CHARS, limit],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        SearchRow {
                            kind: SearchHitKind::Project,
                            id: row.get(1)?,
                            project_id: row.get(2)?,
                            project_name: row.get(3)?,
                            title: row.get(4)?,
                            body: row.get::<_, Option<String>>(5)?.unwrap_or_default(),
                            status: row.get(6)?,
                            updated_at: row.get(7)?,
                        },
                    ))
                },
            )
            .map_err(backend)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(backend)?;
        raw.into_iter()
            .map(|(kind, mut row)| {
                row.kind = kind
                    .parse()
                    .map_err(|_| StoreError::Corrupt(format!("search hit kind {kind:?}")))?;
                Ok(row)
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::like_pattern;

    #[test]
    fn wildcards_in_a_query_match_themselves() {
        assert_eq!(like_pattern("50%_off\\"), "%50\\%\\_off\\\\%");
    }
}
