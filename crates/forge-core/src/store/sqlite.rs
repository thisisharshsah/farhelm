//! SQLite (WAL) implementation of [`Store`].
//!
//! One file, no daemon, trivially backed up — the right shape for a single
//! always-on runner. The connection sits behind a `Mutex` because SQLite is a
//! single writer anyway and [`Store`] takes `&self`.

use std::path::Path;
use std::str::FromStr;
use std::sync::Mutex;

use rusqlite::{Connection, OptionalExtension, Row, params};

use super::{
    ApprovalStore, BatchStore, DecisionOutcome, DeviceStore, FleetStore, LedgerStore, PlanStore,
    ResponseCache, Result, SessionStore, StoreError, TaskOutcome, TaskStore, TimeRange,
};
use crate::types::{
    Agent, AgentTask, Approval, Avoided, BatchItem, BatchStatus, Budget, DecidedVia, Decision,
    Device, DeviceKind, Machine, ParseEnumError, Plan, PlanStep, PlanStepStatus, Repo, Risk,
    Session, SessionStatus, TaskStatus, TaskType, Tier, Usage, UsageEvent,
};

/// Applied in order; the index+1 is the `PRAGMA user_version` they leave behind.
const MIGRATIONS: &[&str] = &[
    include_str!("../../migrations/0001_init.sql"),
    include_str!("../../migrations/0002_agent_session_id.sql"),
    include_str!("../../migrations/0003_batch_queue.sql"),
    include_str!("../../migrations/0004_agent_task.sql"),
    include_str!("../../migrations/0005_task_verification.sql"),
];

const BATCH_COLUMNS: &str = "id, session_id, custom_id, task_type, model, request_json, \
     batch_id, status, response_text, error, queued_at, submitted_at, settled_at";

/// Ordered to match the `?1..?19` in `upsert_task` and the indices in
/// [`read_task`]. Three lists that have to agree, so they sit together.
const TASK_COLUMNS: &str = "id, session_id, repo_id, prompt, status, summary, diff_json, \
     staged_json, files_changed, lines_added, lines_removed, steps, cost_usd, error, \
     review_note, decided_via, created_at, updated_at, decided_at, verify_grade, \
     verify_notes, verify_model";

struct RawTask {
    id: String,
    session_id: String,
    repo_id: String,
    prompt: String,
    status: String,
    summary: String,
    diff_json: String,
    staged_json: String,
    files_changed: i64,
    lines_added: i64,
    lines_removed: i64,
    steps: i64,
    cost_usd: f64,
    error: Option<String>,
    review_note: Option<String>,
    decided_via: Option<String>,
    created_at: i64,
    updated_at: i64,
    decided_at: Option<i64>,
    verify_grade: Option<String>,
    verify_notes: Option<String>,
    verify_model: Option<String>,
}

fn read_task(row: &Row<'_>) -> rusqlite::Result<RawTask> {
    Ok(RawTask {
        id: row.get(0)?,
        session_id: row.get(1)?,
        repo_id: row.get(2)?,
        prompt: row.get(3)?,
        status: row.get(4)?,
        summary: row.get(5)?,
        diff_json: row.get(6)?,
        staged_json: row.get(7)?,
        files_changed: row.get(8)?,
        lines_added: row.get(9)?,
        lines_removed: row.get(10)?,
        steps: row.get(11)?,
        cost_usd: row.get(12)?,
        error: row.get(13)?,
        review_note: row.get(14)?,
        decided_via: row.get(15)?,
        created_at: row.get(16)?,
        updated_at: row.get(17)?,
        decided_at: row.get(18)?,
        verify_grade: row.get(19)?,
        verify_notes: row.get(20)?,
        verify_model: row.get(21)?,
    })
}

impl TryFrom<RawTask> for AgentTask {
    type Error = StoreError;

    fn try_from(raw: RawTask) -> Result<Self> {
        Ok(AgentTask {
            id: raw.id,
            session_id: raw.session_id,
            repo_id: raw.repo_id,
            prompt: raw.prompt,
            status: parse_enum::<TaskStatus>(&raw.status)?,
            summary: raw.summary,
            diff_json: raw.diff_json,
            staged_json: raw.staged_json,
            files_changed: raw.files_changed,
            lines_added: raw.lines_added,
            lines_removed: raw.lines_removed,
            steps: raw.steps,
            cost_usd: raw.cost_usd,
            error: raw.error,
            review_note: raw.review_note,
            decided_via: raw
                .decided_via
                .as_deref()
                .map(parse_enum::<DecidedVia>)
                .transpose()?,
            created_at: raw.created_at,
            updated_at: raw.updated_at,
            decided_at: raw.decided_at,
            verify_grade: raw.verify_grade,
            verify_notes: raw.verify_notes,
            verify_model: raw.verify_model,
        })
    }
}

/// Read as strings and convert afterwards, like every other row here: a text
/// column that does not parse is a `StoreError::Corrupt` with the bad value in
/// it, not a panic inside rusqlite's callback.
struct RawBatchItem {
    id: String,
    session_id: String,
    custom_id: String,
    task_type: String,
    model: String,
    request_json: String,
    batch_id: Option<String>,
    status: String,
    response_text: Option<String>,
    error: Option<String>,
    queued_at: i64,
    submitted_at: Option<i64>,
    settled_at: Option<i64>,
}

fn read_batch_item(row: &Row<'_>) -> rusqlite::Result<RawBatchItem> {
    Ok(RawBatchItem {
        id: row.get(0)?,
        session_id: row.get(1)?,
        custom_id: row.get(2)?,
        task_type: row.get(3)?,
        model: row.get(4)?,
        request_json: row.get(5)?,
        batch_id: row.get(6)?,
        status: row.get(7)?,
        response_text: row.get(8)?,
        error: row.get(9)?,
        queued_at: row.get(10)?,
        submitted_at: row.get(11)?,
        settled_at: row.get(12)?,
    })
}

impl TryFrom<RawBatchItem> for BatchItem {
    type Error = StoreError;

    fn try_from(raw: RawBatchItem) -> Result<Self> {
        Ok(BatchItem {
            id: raw.id,
            session_id: raw.session_id,
            custom_id: raw.custom_id,
            task_type: parse_enum::<TaskType>(&raw.task_type)?,
            model: raw.model,
            request_json: raw.request_json,
            batch_id: raw.batch_id,
            status: parse_enum::<BatchStatus>(&raw.status)?,
            response_text: raw.response_text,
            error: raw.error,
            queued_at: raw.queued_at,
            submitted_at: raw.submitted_at,
            settled_at: raw.settled_at,
        })
    }
}

pub struct SqliteStore {
    conn: Mutex<Connection>,
}

impl SqliteStore {
    /// Open (creating if absent) the runner's database and bring it to the
    /// latest schema version.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn = Connection::open(path).map_err(backend)?;
        Self::from_connection(conn)
    }

    /// An ephemeral database. Used by tests, and by `--dry-run` on the runner.
    pub fn open_in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory().map_err(backend)?;
        Self::from_connection(conn)
    }

    fn from_connection(conn: Connection) -> Result<Self> {
        // WAL lets the UI read while the gateway writes. It is a no-op on
        // in-memory databases, which is why the returned mode is ignored.
        conn.pragma_update_and_check(None, "journal_mode", "WAL", |_| Ok(()))
            .map_err(backend)?;
        conn.pragma_update(None, "synchronous", "NORMAL")
            .map_err(backend)?;
        conn.pragma_update(None, "foreign_keys", "ON")
            .map_err(backend)?;
        migrate(&conn)?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    /// The schema version currently applied.
    pub fn schema_version(&self) -> Result<i64> {
        let conn = self.lock()?;
        conn.query_row("PRAGMA user_version", [], |row| row.get(0))
            .map_err(backend)
    }

    fn lock(&self) -> Result<std::sync::MutexGuard<'_, Connection>> {
        self.conn
            .lock()
            .map_err(|_| StoreError::Backend("database mutex poisoned".into()))
    }
}

fn migrate(conn: &Connection) -> Result<()> {
    let mut version: i64 = conn
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .map_err(backend)?;

    for (index, sql) in MIGRATIONS.iter().enumerate() {
        let target = index as i64 + 1;
        if version >= target {
            continue;
        }
        // DDL and the version bump go in one transaction, so a crash mid-migration
        // leaves the database on the previous version rather than half-applied.
        conn.execute_batch(&format!(
            "BEGIN;\n{sql}\nPRAGMA user_version = {target};\nCOMMIT;"
        ))
        .map_err(backend)?;
        version = target;
    }
    Ok(())
}

fn backend(err: rusqlite::Error) -> StoreError {
    StoreError::Backend(Box::new(err))
}

fn parse_enum<T: FromStr<Err = ParseEnumError>>(value: &str) -> Result<T> {
    T::from_str(value).map_err(|err| StoreError::Corrupt(err.to_string()))
}

fn token_count(value: i64, column: &str) -> Result<u32> {
    u32::try_from(value).map_err(|_| StoreError::Corrupt(format!("{column} out of range: {value}")))
}

// Raw row shapes. Enum columns come back as `String` so parse failures can be
// reported as `Corrupt` rather than smuggled through rusqlite's error type.

struct RawSession {
    id: String,
    repo_id: String,
    agent: String,
    tmux_target: Option<String>,
    status: String,
    plan_id: Option<String>,
    budget_usd: Option<f64>,
    spent_usd: f64,
    started_at: i64,
    ended_at: Option<i64>,
    agent_session_id: Option<String>,
}

fn read_session(row: &Row<'_>) -> rusqlite::Result<RawSession> {
    Ok(RawSession {
        id: row.get(0)?,
        repo_id: row.get(1)?,
        agent: row.get(2)?,
        tmux_target: row.get(3)?,
        status: row.get(4)?,
        plan_id: row.get(5)?,
        budget_usd: row.get(6)?,
        spent_usd: row.get(7)?,
        started_at: row.get(8)?,
        ended_at: row.get(9)?,
        agent_session_id: row.get(10)?,
    })
}

impl TryFrom<RawSession> for Session {
    type Error = StoreError;

    fn try_from(raw: RawSession) -> Result<Self> {
        Ok(Session {
            id: raw.id,
            repo_id: raw.repo_id,
            agent: parse_enum::<Agent>(&raw.agent)?,
            tmux_target: raw.tmux_target,
            status: parse_enum::<SessionStatus>(&raw.status)?,
            plan_id: raw.plan_id,
            budget_usd: raw.budget_usd,
            spent_usd: raw.spent_usd,
            started_at: raw.started_at,
            ended_at: raw.ended_at,
            agent_session_id: raw.agent_session_id,
        })
    }
}

struct RawUsageEvent {
    id: String,
    session_id: String,
    model: String,
    tier: String,
    task_type: String,
    input_tokens: i64,
    output_tokens: i64,
    cache_write_tokens: i64,
    cache_read_tokens: i64,
    cost_usd: f64,
    avoided: Option<String>,
    created_at: i64,
}

fn read_usage_event(row: &Row<'_>) -> rusqlite::Result<RawUsageEvent> {
    Ok(RawUsageEvent {
        id: row.get(0)?,
        session_id: row.get(1)?,
        model: row.get(2)?,
        tier: row.get(3)?,
        task_type: row.get(4)?,
        input_tokens: row.get(5)?,
        output_tokens: row.get(6)?,
        cache_write_tokens: row.get(7)?,
        cache_read_tokens: row.get(8)?,
        cost_usd: row.get(9)?,
        avoided: row.get(10)?,
        created_at: row.get(11)?,
    })
}

impl TryFrom<RawUsageEvent> for UsageEvent {
    type Error = StoreError;

    fn try_from(raw: RawUsageEvent) -> Result<Self> {
        Ok(UsageEvent {
            id: raw.id,
            session_id: raw.session_id,
            model: raw.model,
            tier: parse_enum::<Tier>(&raw.tier)?,
            task_type: parse_enum::<TaskType>(&raw.task_type)?,
            usage: Usage {
                input_tokens: token_count(raw.input_tokens, "input_tokens")?,
                output_tokens: token_count(raw.output_tokens, "output_tokens")?,
                cache_write_tokens: token_count(raw.cache_write_tokens, "cache_write_tokens")?,
                cache_read_tokens: token_count(raw.cache_read_tokens, "cache_read_tokens")?,
            },
            cost_usd: raw.cost_usd,
            avoided: raw
                .avoided
                .as_deref()
                .map(parse_enum::<Avoided>)
                .transpose()?,
            created_at: raw.created_at,
        })
    }
}

struct RawPlanStep {
    id: String,
    plan_id: String,
    ordinal: i64,
    title: String,
    status: String,
    checkpoint_sha: Option<String>,
}

fn read_plan_step(row: &Row<'_>) -> rusqlite::Result<RawPlanStep> {
    Ok(RawPlanStep {
        id: row.get(0)?,
        plan_id: row.get(1)?,
        ordinal: row.get(2)?,
        title: row.get(3)?,
        status: row.get(4)?,
        checkpoint_sha: row.get(5)?,
    })
}

impl TryFrom<RawPlanStep> for PlanStep {
    type Error = StoreError;

    fn try_from(raw: RawPlanStep) -> Result<Self> {
        Ok(PlanStep {
            id: raw.id,
            plan_id: raw.plan_id,
            ordinal: raw.ordinal,
            title: raw.title,
            status: parse_enum::<PlanStepStatus>(&raw.status)?,
            checkpoint_sha: raw.checkpoint_sha,
        })
    }
}

struct RawApproval {
    id: String,
    session_id: String,
    tool: String,
    payload: String,
    risk: String,
    decision: Option<String>,
    decided_via: Option<String>,
    requested_at: i64,
    decided_at: Option<i64>,
}

fn read_approval(row: &Row<'_>) -> rusqlite::Result<RawApproval> {
    Ok(RawApproval {
        id: row.get(0)?,
        session_id: row.get(1)?,
        tool: row.get(2)?,
        payload: row.get(3)?,
        risk: row.get(4)?,
        decision: row.get(5)?,
        decided_via: row.get(6)?,
        requested_at: row.get(7)?,
        decided_at: row.get(8)?,
    })
}

impl TryFrom<RawApproval> for Approval {
    type Error = StoreError;

    fn try_from(raw: RawApproval) -> Result<Self> {
        Ok(Approval {
            id: raw.id,
            session_id: raw.session_id,
            tool: raw.tool,
            payload: raw.payload,
            risk: parse_enum::<Risk>(&raw.risk)?,
            decision: raw
                .decision
                .as_deref()
                .map(parse_enum::<Decision>)
                .transpose()?,
            decided_via: raw
                .decided_via
                .as_deref()
                .map(parse_enum::<DecidedVia>)
                .transpose()?,
            requested_at: raw.requested_at,
            decided_at: raw.decided_at,
        })
    }
}

struct RawDevice {
    id: String,
    kind: String,
    pubkey: String,
    push_token: Option<String>,
    paired_at: i64,
}

fn read_device(row: &Row<'_>) -> rusqlite::Result<RawDevice> {
    Ok(RawDevice {
        id: row.get(0)?,
        kind: row.get(1)?,
        pubkey: row.get(2)?,
        push_token: row.get(3)?,
        paired_at: row.get(4)?,
    })
}

impl TryFrom<RawDevice> for Device {
    type Error = StoreError;

    fn try_from(raw: RawDevice) -> Result<Self> {
        Ok(Device {
            id: raw.id,
            kind: parse_enum::<DeviceKind>(&raw.kind)?,
            pubkey: raw.pubkey,
            push_token: raw.push_token,
            paired_at: raw.paired_at,
        })
    }
}

const PLAN_STEP_COLUMNS: &str = "id, plan_id, ordinal, title, status, checkpoint_sha";

const APPROVAL_COLUMNS: &str = "id, session_id, tool, payload, risk, decision, decided_via, \
                                requested_at, decided_at";

const SESSION_COLUMNS: &str = "id, repo_id, agent, tmux_target, status, plan_id, budget_usd, \
                               spent_usd, started_at, ended_at, agent_session_id";

const USAGE_COLUMNS: &str = "id, session_id, model, tier, task_type, input_tokens, output_tokens, \
                             cache_write_tokens, cache_read_tokens, cost_usd, avoided, created_at";

impl FleetStore for SqliteStore {
    fn upsert_machine(&self, machine: &Machine) -> Result<()> {
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO machine (id, name, pubkey, last_seen_at, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(id) DO UPDATE SET
                 name = excluded.name,
                 pubkey = excluded.pubkey,
                 last_seen_at = excluded.last_seen_at",
            params![
                machine.id,
                machine.name,
                machine.pubkey,
                machine.last_seen_at,
                machine.created_at
            ],
        )
        .map_err(backend)?;
        Ok(())
    }

    fn get_machine(&self, id: &str) -> Result<Option<Machine>> {
        let conn = self.lock()?;
        conn.query_row(
            "SELECT id, name, pubkey, last_seen_at, created_at FROM machine WHERE id = ?1",
            params![id],
            |row| {
                Ok(Machine {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    pubkey: row.get(2)?,
                    last_seen_at: row.get(3)?,
                    created_at: row.get(4)?,
                })
            },
        )
        .optional()
        .map_err(backend)
    }

    fn upsert_repo(&self, repo: &Repo) -> Result<()> {
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO repo (id, machine_id, path, name, budget_usd)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(id) DO UPDATE SET
                 machine_id = excluded.machine_id,
                 path = excluded.path,
                 name = excluded.name,
                 budget_usd = excluded.budget_usd",
            params![
                repo.id,
                repo.machine_id,
                repo.path,
                repo.name,
                repo.budget_usd
            ],
        )
        .map_err(backend)?;
        Ok(())
    }

    fn get_repo(&self, id: &str) -> Result<Option<Repo>> {
        let conn = self.lock()?;
        conn.query_row(
            "SELECT id, machine_id, path, name, budget_usd FROM repo WHERE id = ?1",
            params![id],
            |row| {
                Ok(Repo {
                    id: row.get(0)?,
                    machine_id: row.get(1)?,
                    path: row.get(2)?,
                    name: row.get(3)?,
                    budget_usd: row.get(4)?,
                })
            },
        )
        .optional()
        .map_err(backend)
    }

    fn find_repo_by_path(&self, machine_id: &str, path: &str) -> Result<Option<Repo>> {
        let conn = self.lock()?;
        conn.query_row(
            "SELECT id, machine_id, path, name, budget_usd FROM repo
             WHERE machine_id = ?1 AND path = ?2",
            params![machine_id, path],
            |row| {
                Ok(Repo {
                    id: row.get(0)?,
                    machine_id: row.get(1)?,
                    path: row.get(2)?,
                    name: row.get(3)?,
                    budget_usd: row.get(4)?,
                })
            },
        )
        .optional()
        .map_err(backend)
    }
}

impl SessionStore for SqliteStore {
    fn upsert_session(&self, session: &Session) -> Result<()> {
        let conn = self.lock()?;
        // `spent_usd` is deliberately NOT overwritten on conflict: it is owned by
        // `record_usage`, and a stale in-memory copy must never roll the ledger back.
        conn.execute(
            "INSERT INTO session (id, repo_id, agent, tmux_target, status, plan_id, budget_usd,
                                  spent_usd, started_at, ended_at, agent_session_id)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
             ON CONFLICT(id) DO UPDATE SET
                 repo_id = excluded.repo_id,
                 agent = excluded.agent,
                 tmux_target = excluded.tmux_target,
                 status = excluded.status,
                 plan_id = excluded.plan_id,
                 budget_usd = excluded.budget_usd,
                 started_at = excluded.started_at,
                 ended_at = excluded.ended_at,
                 agent_session_id = COALESCE(excluded.agent_session_id, session.agent_session_id)",
            params![
                session.id,
                session.repo_id,
                session.agent.as_str(),
                session.tmux_target,
                session.status.as_str(),
                session.plan_id,
                session.budget_usd,
                session.spent_usd,
                session.started_at,
                session.ended_at,
                session.agent_session_id,
            ],
        )
        .map_err(backend)?;
        Ok(())
    }

    fn get_session(&self, id: &str) -> Result<Option<Session>> {
        let conn = self.lock()?;
        let raw = conn
            .query_row(
                &format!("SELECT {SESSION_COLUMNS} FROM session WHERE id = ?1"),
                params![id],
                read_session,
            )
            .optional()
            .map_err(backend)?;
        raw.map(Session::try_from).transpose()
    }

    fn list_sessions(&self) -> Result<Vec<Session>> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {SESSION_COLUMNS} FROM session ORDER BY started_at DESC"
            ))
            .map_err(backend)?;
        let rows = stmt
            .query_map([], read_session)
            .map_err(backend)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(backend)?;
        rows.into_iter().map(Session::try_from).collect()
    }

    fn find_session_by_agent_id(&self, agent_session_id: &str) -> Result<Option<Session>> {
        let conn = self.lock()?;
        let raw = conn
            .query_row(
                &format!("SELECT {SESSION_COLUMNS} FROM session WHERE agent_session_id = ?1"),
                params![agent_session_id],
                read_session,
            )
            .optional()
            .map_err(backend)?;
        raw.map(Session::try_from).transpose()
    }
}

impl LedgerStore for SqliteStore {
    fn record_usage(&self, event: &UsageEvent) -> Result<()> {
        let mut conn = self.lock()?;
        let tx = conn.transaction().map_err(backend)?;

        // Budget first: an unknown session is a caller mistake worth naming, and
        // going through the foreign key on usage_event instead would surface it
        // as an opaque constraint failure.
        let updated = tx
            .execute(
                "UPDATE session SET spent_usd = spent_usd + ?1 WHERE id = ?2",
                params![event.cost_usd, event.session_id],
            )
            .map_err(backend)?;
        if updated == 0 {
            return Err(StoreError::NotFound(format!(
                "session {}",
                event.session_id
            )));
        }

        tx.execute(
            "INSERT INTO usage_event (id, session_id, model, tier, task_type, input_tokens,
                                      output_tokens, cache_write_tokens, cache_read_tokens,
                                      cost_usd, avoided, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
            params![
                event.id,
                event.session_id,
                event.model,
                event.tier.as_str(),
                event.task_type.as_str(),
                event.usage.input_tokens,
                event.usage.output_tokens,
                event.usage.cache_write_tokens,
                event.usage.cache_read_tokens,
                event.cost_usd,
                event.avoided.map(|a| a.as_str()),
                event.created_at,
            ],
        )
        .map_err(backend)?;

        tx.commit().map_err(backend)?;
        Ok(())
    }

    fn list_usage(&self, session_id: &str, range: TimeRange) -> Result<Vec<UsageEvent>> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {USAGE_COLUMNS} FROM usage_event
                 WHERE session_id = ?1
                   AND (?2 IS NULL OR created_at >= ?2)
                   AND (?3 IS NULL OR created_at < ?3)
                 ORDER BY created_at ASC"
            ))
            .map_err(backend)?;
        let rows = stmt
            .query_map(
                params![session_id, range.since_ms, range.until_ms],
                read_usage_event,
            )
            .map_err(backend)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(backend)?;
        rows.into_iter().map(UsageEvent::try_from).collect()
    }

    fn session_budget(&self, session_id: &str) -> Result<Budget> {
        let conn = self.lock()?;
        conn.query_row(
            "SELECT budget_usd, spent_usd FROM session WHERE id = ?1",
            params![session_id],
            |row| {
                Ok(Budget {
                    cap_usd: row.get(0)?,
                    spent_usd: row.get(1)?,
                })
            },
        )
        .optional()
        .map_err(backend)?
        .ok_or_else(|| StoreError::NotFound(format!("session {session_id}")))
    }

    fn repo_budget(&self, repo_id: &str) -> Result<Budget> {
        let conn = self.lock()?;
        let cap: Option<f64> = conn
            .query_row(
                "SELECT budget_usd FROM repo WHERE id = ?1",
                params![repo_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(backend)?
            .ok_or_else(|| StoreError::NotFound(format!("repo {repo_id}")))?;

        let spent: f64 = conn
            .query_row(
                "SELECT COALESCE(SUM(spent_usd), 0.0) FROM session WHERE repo_id = ?1",
                params![repo_id],
                |row| row.get(0),
            )
            .map_err(backend)?;

        Ok(Budget {
            cap_usd: cap,
            spent_usd: spent,
        })
    }
}

impl PlanStore for SqliteStore {
    fn upsert_plan(&self, plan: &Plan) -> Result<()> {
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO plan (id, repo_id, file_path, content_hash, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(id) DO UPDATE SET
                 repo_id = excluded.repo_id,
                 file_path = excluded.file_path,
                 content_hash = excluded.content_hash",
            params![
                plan.id,
                plan.repo_id,
                plan.file_path,
                plan.content_hash,
                plan.created_at
            ],
        )
        .map_err(backend)?;
        Ok(())
    }

    fn get_plan(&self, id: &str) -> Result<Option<Plan>> {
        let conn = self.lock()?;
        conn.query_row(
            "SELECT id, repo_id, file_path, content_hash, created_at FROM plan WHERE id = ?1",
            params![id],
            |row| {
                Ok(Plan {
                    id: row.get(0)?,
                    repo_id: row.get(1)?,
                    file_path: row.get(2)?,
                    content_hash: row.get(3)?,
                    created_at: row.get(4)?,
                })
            },
        )
        .optional()
        .map_err(backend)
    }

    fn replace_plan_steps(&self, plan_id: &str, steps: &[PlanStep]) -> Result<()> {
        let mut conn = self.lock()?;
        let tx = conn.transaction().map_err(backend)?;
        tx.execute("DELETE FROM plan_step WHERE plan_id = ?1", params![plan_id])
            .map_err(backend)?;
        for step in steps {
            tx.execute(
                &format!(
                    "INSERT INTO plan_step ({PLAN_STEP_COLUMNS}) VALUES (?1, ?2, ?3, ?4, ?5, ?6)"
                ),
                params![
                    step.id,
                    plan_id,
                    step.ordinal,
                    step.title,
                    step.status.as_str(),
                    step.checkpoint_sha,
                ],
            )
            .map_err(backend)?;
        }
        tx.commit().map_err(backend)?;
        Ok(())
    }

    fn list_plan_steps(&self, plan_id: &str) -> Result<Vec<PlanStep>> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {PLAN_STEP_COLUMNS} FROM plan_step WHERE plan_id = ?1 ORDER BY ordinal ASC"
            ))
            .map_err(backend)?;
        let rows = stmt
            .query_map(params![plan_id], read_plan_step)
            .map_err(backend)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(backend)?;
        rows.into_iter().map(PlanStep::try_from).collect()
    }

    fn update_plan_step(&self, step: &PlanStep) -> Result<()> {
        let conn = self.lock()?;
        let updated = conn
            .execute(
                "UPDATE plan_step SET status = ?1, checkpoint_sha = ?2, title = ?3 WHERE id = ?4",
                params![
                    step.status.as_str(),
                    step.checkpoint_sha,
                    step.title,
                    step.id
                ],
            )
            .map_err(backend)?;
        if updated == 0 {
            return Err(StoreError::NotFound(format!("plan_step {}", step.id)));
        }
        Ok(())
    }
}

impl ApprovalStore for SqliteStore {
    fn create_approval(&self, approval: &Approval) -> Result<()> {
        let conn = self.lock()?;
        conn.execute(
            &format!(
                "INSERT INTO approval ({APPROVAL_COLUMNS})
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)"
            ),
            params![
                approval.id,
                approval.session_id,
                approval.tool,
                approval.payload,
                approval.risk.as_str(),
                approval.decision.map(|d| d.as_str()),
                approval.decided_via.map(|v| v.as_str()),
                approval.requested_at,
                approval.decided_at,
            ],
        )
        .map_err(backend)?;
        Ok(())
    }

    fn get_approval(&self, id: &str) -> Result<Option<Approval>> {
        let conn = self.lock()?;
        let raw = conn
            .query_row(
                &format!("SELECT {APPROVAL_COLUMNS} FROM approval WHERE id = ?1"),
                params![id],
                read_approval,
            )
            .optional()
            .map_err(backend)?;
        raw.map(Approval::try_from).transpose()
    }

    fn list_pending_approvals(&self) -> Result<Vec<Approval>> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {APPROVAL_COLUMNS} FROM approval
                 WHERE decision IS NULL ORDER BY requested_at ASC"
            ))
            .map_err(backend)?;
        let rows = stmt
            .query_map([], read_approval)
            .map_err(backend)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(backend)?;
        rows.into_iter().map(Approval::try_from).collect()
    }

    fn decide_approval(
        &self,
        id: &str,
        decision: Decision,
        via: DecidedVia,
        decided_at: i64,
    ) -> Result<DecisionOutcome> {
        let mut conn = self.lock()?;
        let tx = conn.transaction().map_err(backend)?;

        // `decision IS NULL` is the whole race guard: the second device to tap
        // updates zero rows rather than overwriting the first decision.
        let updated = tx
            .execute(
                "UPDATE approval SET decision = ?1, decided_via = ?2, decided_at = ?3
                 WHERE id = ?4 AND decision IS NULL",
                params![decision.as_str(), via.as_str(), decided_at, id],
            )
            .map_err(backend)?;

        let raw = tx
            .query_row(
                &format!("SELECT {APPROVAL_COLUMNS} FROM approval WHERE id = ?1"),
                params![id],
                read_approval,
            )
            .optional()
            .map_err(backend)?
            .ok_or_else(|| StoreError::NotFound(format!("approval {id}")))?;

        tx.commit().map_err(backend)?;

        let approval = Approval::try_from(raw)?;
        Ok(if updated == 1 {
            DecisionOutcome::Recorded(approval)
        } else {
            DecisionOutcome::AlreadyDecided(approval)
        })
    }
}

impl BatchStore for SqliteStore {
    /* ------------------------------------------------- batch queue (C6) */

    fn enqueue_batch_item(&self, item: &BatchItem) -> Result<()> {
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO batch_item
               (id, session_id, custom_id, task_type, model, request_json,
                batch_id, status, response_text, error, queued_at, submitted_at, settled_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            params![
                item.id,
                item.session_id,
                item.custom_id,
                item.task_type.as_str(),
                item.model,
                item.request_json,
                item.batch_id,
                item.status.as_str(),
                item.response_text,
                item.error,
                item.queued_at,
                item.submitted_at,
                item.settled_at,
            ],
        )
        .map_err(backend)?;
        Ok(())
    }

    fn list_queued_batch_items(&self, limit: usize) -> Result<Vec<BatchItem>> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {BATCH_COLUMNS} FROM batch_item
                 WHERE status = 'queued' ORDER BY queued_at ASC LIMIT ?1"
            ))
            .map_err(backend)?;
        let rows = stmt
            .query_map([limit as i64], read_batch_item)
            .map_err(backend)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(backend)?;
        rows.into_iter().map(BatchItem::try_from).collect()
    }

    fn list_submitted_batch_items(&self) -> Result<Vec<BatchItem>> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {BATCH_COLUMNS} FROM batch_item
                 WHERE status = 'submitted' ORDER BY submitted_at ASC"
            ))
            .map_err(backend)?;
        let rows = stmt
            .query_map([], read_batch_item)
            .map_err(backend)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(backend)?;
        rows.into_iter().map(BatchItem::try_from).collect()
    }

    fn get_batch_item(&self, id: &str) -> Result<Option<BatchItem>> {
        let conn = self.lock()?;
        let raw = conn
            .query_row(
                &format!("SELECT {BATCH_COLUMNS} FROM batch_item WHERE id = ?1"),
                [id],
                read_batch_item,
            )
            .optional()
            .map_err(backend)?;
        raw.map(BatchItem::try_from).transpose()
    }

    fn list_batch_items_for_session(&self, session_id: &str) -> Result<Vec<BatchItem>> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {BATCH_COLUMNS} FROM batch_item
                 WHERE session_id = ?1 ORDER BY queued_at DESC"
            ))
            .map_err(backend)?;
        let rows = stmt
            .query_map([session_id], read_batch_item)
            .map_err(backend)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(backend)?;
        rows.into_iter().map(BatchItem::try_from).collect()
    }

    fn mark_batch_submitted(
        &self,
        item_ids: &[String],
        batch_id: &str,
        submitted_at: i64,
    ) -> Result<()> {
        if item_ids.is_empty() {
            return Ok(());
        }
        let mut conn = self.lock()?;
        // One transaction for the whole flush. A crash partway through would
        // otherwise leave some rows queued and some submitted, and the queued
        // half would go out again in the next batch — paid for twice.
        let tx = conn.transaction().map_err(backend)?;
        for id in item_ids {
            tx.execute(
                "UPDATE batch_item
                 SET batch_id = ?2, status = 'submitted', submitted_at = ?3
                 WHERE id = ?1 AND status = 'queued'",
                params![id, batch_id, submitted_at],
            )
            .map_err(backend)?;
        }
        tx.commit().map_err(backend)?;
        Ok(())
    }

    fn settle_batch_item(
        &self,
        custom_id: &str,
        status: BatchStatus,
        response_text: Option<&str>,
        error: Option<&str>,
        settled_at: i64,
    ) -> Result<()> {
        let conn = self.lock()?;
        // `status = 'submitted'` is the guard: results can be fetched more than
        // once (a poll that overlaps a retry), and settling twice would bill the
        // same tokens twice.
        conn.execute(
            "UPDATE batch_item
             SET status = ?2, response_text = ?3, error = ?4, settled_at = ?5
             WHERE custom_id = ?1 AND status = 'submitted'",
            params![custom_id, status.as_str(), response_text, error, settled_at],
        )
        .map_err(backend)?;
        Ok(())
    }
}

impl TaskStore for SqliteStore {
    fn upsert_task(&self, task: &AgentTask) -> Result<()> {
        let conn = self.lock()?;
        conn.execute(
            &format!(
                "INSERT INTO agent_task ({TASK_COLUMNS}) VALUES
                 (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,
                  ?20,?21,?22)
                 ON CONFLICT(id) DO UPDATE SET
                   status = excluded.status,
                   summary = excluded.summary,
                   diff_json = excluded.diff_json,
                   staged_json = excluded.staged_json,
                   files_changed = excluded.files_changed,
                   lines_added = excluded.lines_added,
                   lines_removed = excluded.lines_removed,
                   steps = excluded.steps,
                   cost_usd = excluded.cost_usd,
                   error = excluded.error,
                   review_note = excluded.review_note,
                   decided_via = excluded.decided_via,
                   updated_at = excluded.updated_at,
                   decided_at = excluded.decided_at,
                   verify_grade = excluded.verify_grade,
                   verify_notes = excluded.verify_notes,
                   verify_model = excluded.verify_model"
            ),
            params![
                task.id,
                task.session_id,
                task.repo_id,
                task.prompt,
                task.status.as_str(),
                task.summary,
                task.diff_json,
                task.staged_json,
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
                task.verify_model,
            ],
        )
        .map_err(backend)?;
        Ok(())
    }

    fn get_task(&self, id: &str) -> Result<Option<AgentTask>> {
        let conn = self.lock()?;
        let raw = conn
            .query_row(
                &format!("SELECT {TASK_COLUMNS} FROM agent_task WHERE id = ?1"),
                params![id],
                read_task,
            )
            .optional()
            .map_err(backend)?;
        raw.map(AgentTask::try_from).transpose()
    }

    fn list_tasks(&self, limit: usize) -> Result<Vec<AgentTask>> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {TASK_COLUMNS} FROM agent_task ORDER BY created_at DESC LIMIT ?1"
            ))
            .map_err(backend)?;
        let rows = stmt
            .query_map(params![limit as i64], read_task)
            .map_err(backend)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(backend)?;
        rows.into_iter().map(AgentTask::try_from).collect()
    }

    fn list_tasks_awaiting_review(&self) -> Result<Vec<AgentTask>> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {TASK_COLUMNS} FROM agent_task
                 WHERE status = 'awaiting_review' ORDER BY created_at ASC"
            ))
            .map_err(backend)?;
        let rows = stmt
            .query_map([], read_task)
            .map_err(backend)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(backend)?;
        rows.into_iter().map(AgentTask::try_from).collect()
    }

    fn decide_task(
        &self,
        id: &str,
        status: TaskStatus,
        via: DecidedVia,
        note: Option<&str>,
        decided_at: i64,
    ) -> Result<TaskOutcome> {
        let mut conn = self.lock()?;
        let tx = conn.transaction().map_err(backend)?;

        // `status = 'awaiting_review'` is the race guard, and it does more work
        // here than the approval equivalent: applying a change set twice would
        // write files a second time against a tree that has already moved.
        let updated = tx
            .execute(
                "UPDATE agent_task
                 SET status = ?1, decided_via = ?2, review_note = ?3,
                     decided_at = ?4, updated_at = ?4
                 WHERE id = ?5 AND status = 'awaiting_review'",
                params![status.as_str(), via.as_str(), note, decided_at, id],
            )
            .map_err(backend)?;

        let raw = tx
            .query_row(
                &format!("SELECT {TASK_COLUMNS} FROM agent_task WHERE id = ?1"),
                params![id],
                read_task,
            )
            .optional()
            .map_err(backend)?
            .ok_or_else(|| StoreError::NotFound(format!("task {id}")))?;

        tx.commit().map_err(backend)?;

        let task = AgentTask::try_from(raw)?;
        Ok(if updated == 1 {
            TaskOutcome::Recorded(task)
        } else {
            TaskOutcome::AlreadyDecided(task)
        })
    }
}

impl ResponseCache for SqliteStore {
    fn cache_get(&self, key_hash: &str, now_ms: i64) -> Result<Option<String>> {
        let mut conn = self.lock()?;
        let tx = conn.transaction().map_err(backend)?;

        // Freshness is checked in SQL rather than after the read, so an expired
        // entry can never be returned by a caller that forgets to compare.
        let hit: Option<String> = tx
            .query_row(
                "SELECT response FROM response_cache WHERE key_hash = ?1 AND expires_at > ?2",
                params![key_hash, now_ms],
                |row| row.get(0),
            )
            .optional()
            .map_err(backend)?;

        if hit.is_some() {
            tx.execute(
                "UPDATE response_cache SET hit_count = hit_count + 1 WHERE key_hash = ?1",
                params![key_hash],
            )
            .map_err(backend)?;
        }

        tx.commit().map_err(backend)?;
        Ok(hit)
    }

    fn cache_put(&self, key_hash: &str, response: &str, now_ms: i64, ttl_ms: i64) -> Result<()> {
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO response_cache (key_hash, response, hit_count, created_at, expires_at)
             VALUES (?1, ?2, 0, ?3, ?4)
             ON CONFLICT(key_hash) DO UPDATE SET
                 response = excluded.response,
                 created_at = excluded.created_at,
                 expires_at = excluded.expires_at",
            params![key_hash, response, now_ms, now_ms + ttl_ms],
        )
        .map_err(backend)?;
        Ok(())
    }

    fn cache_purge_expired(&self, now_ms: i64) -> Result<usize> {
        let conn = self.lock()?;
        conn.execute(
            "DELETE FROM response_cache WHERE expires_at <= ?1",
            params![now_ms],
        )
        .map_err(backend)
    }
}

impl DeviceStore for SqliteStore {
    fn upsert_device(&self, device: &Device) -> Result<()> {
        let conn = self.lock()?;
        conn.execute(
            "INSERT INTO device (id, kind, pubkey, push_token, paired_at)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(id) DO UPDATE SET
                 kind = excluded.kind,
                 pubkey = excluded.pubkey,
                 push_token = COALESCE(excluded.push_token, device.push_token)",
            params![
                device.id,
                device.kind.as_str(),
                device.pubkey,
                device.push_token,
                device.paired_at,
            ],
        )
        .map_err(backend)?;
        Ok(())
    }

    fn list_devices(&self) -> Result<Vec<Device>> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare(
                "SELECT id, kind, pubkey, push_token, paired_at FROM device
                 ORDER BY paired_at ASC",
            )
            .map_err(backend)?;
        let rows = stmt
            .query_map([], read_device)
            .map_err(backend)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(backend)?;
        rows.into_iter().map(Device::try_from).collect()
    }

    fn get_device(&self, id: &str) -> Result<Option<Device>> {
        let conn = self.lock()?;
        let raw = conn
            .query_row(
                "SELECT id, kind, pubkey, push_token, paired_at FROM device WHERE id = ?1",
                params![id],
                read_device,
            )
            .optional()
            .map_err(backend)?;
        raw.map(Device::try_from).transpose()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::price::{QuoteContext, quote};
    use crate::types::Agent;
    use forge_domain::BudgetRules as _;

    const NOW_MS: i64 = 1_785_369_600_000;

    fn seeded() -> SqliteStore {
        let store = SqliteStore::open_in_memory().unwrap();
        store
            .upsert_machine(&Machine {
                id: "machine-1".into(),
                name: "hetzner-1".into(),
                pubkey: "pk".into(),
                last_seen_at: Some(NOW_MS),
                created_at: NOW_MS,
            })
            .unwrap();
        store
            .upsert_repo(&Repo {
                id: "repo-1".into(),
                machine_id: "machine-1".into(),
                path: "/srv/payments-api".into(),
                name: "payments-api".into(),
                budget_usd: Some(10.0),
            })
            .unwrap();
        store
            .upsert_session(&session("session-1", Some(5.0)))
            .unwrap();
        store
    }

    fn session(id: &str, budget_usd: Option<f64>) -> Session {
        Session {
            id: id.into(),
            repo_id: "repo-1".into(),
            agent: Agent::ClaudeCode,
            tmux_target: Some("forge:3.1".into()),
            status: SessionStatus::Running,
            plan_id: None,
            budget_usd,
            spent_usd: 0.0,
            started_at: NOW_MS,
            ended_at: None,
            agent_session_id: None,
        }
    }

    fn task(id: &str, status: TaskStatus) -> AgentTask {
        AgentTask {
            id: id.into(),
            session_id: "session-1".into(),
            repo_id: "repo-1".into(),
            prompt: "Fix the webhook retry".into(),
            status,
            summary: String::new(),
            diff_json: r#"{"files":[]}"#.into(),
            staged_json: "{}".into(),
            files_changed: 2,
            lines_added: 40,
            lines_removed: 7,
            steps: 5,
            cost_usd: 0.031,
            error: None,
            review_note: None,
            verify_grade: None,
            verify_notes: None,
            verify_model: None,
            decided_via: None,
            created_at: NOW_MS,
            updated_at: NOW_MS,
            decided_at: None,
        }
    }

    #[test]
    fn a_task_round_trips_through_every_column() {
        let store = seeded();
        let mut written = task("task-1", TaskStatus::AwaitingReview);
        written.summary = "Bounded the backoff.".into();
        written.error = Some("none really".into());
        written.verify_grade = Some("concerns".into());
        written.verify_notes = Some("the cap is not tested".into());
        written.verify_model = Some("claude-opus-5".into());
        store.upsert_task(&written).unwrap();

        assert_eq!(store.get_task("task-1").unwrap().unwrap(), written);
    }

    #[test]
    fn an_unjudged_task_is_null_rather_than_a_pass() {
        // A card must never render "not judged" as "judged and found fine".
        let store = seeded();
        store
            .upsert_task(&task("task-1", TaskStatus::AwaitingReview))
            .unwrap();

        let stored = store.get_task("task-1").unwrap().unwrap();
        assert_eq!(stored.verify_grade, None);
        assert_eq!(stored.verify_model, None);
    }

    #[test]
    fn upserting_a_task_updates_it_rather_than_duplicating_it() {
        let store = seeded();
        store
            .upsert_task(&task("task-1", TaskStatus::Running))
            .unwrap();

        let mut finished = task("task-1", TaskStatus::AwaitingReview);
        finished.cost_usd = 0.42;
        store.upsert_task(&finished).unwrap();

        assert_eq!(store.list_tasks(10).unwrap().len(), 1);
        let stored = store.get_task("task-1").unwrap().unwrap();
        assert_eq!(stored.status, TaskStatus::AwaitingReview);
        assert_eq!(stored.cost_usd, 0.42);
    }

    #[test]
    fn only_tasks_awaiting_review_are_listed_for_a_human() {
        let store = seeded();
        store
            .upsert_task(&task("t-running", TaskStatus::Running))
            .unwrap();
        store
            .upsert_task(&task("t-waiting", TaskStatus::AwaitingReview))
            .unwrap();
        store
            .upsert_task(&task("t-done", TaskStatus::Applied))
            .unwrap();

        let waiting = store.list_tasks_awaiting_review().unwrap();
        assert_eq!(waiting.len(), 1);
        assert_eq!(waiting[0].id, "t-waiting");
    }

    #[test]
    fn the_second_device_to_review_a_diff_does_not_apply_it_again() {
        // The failure this prevents: two phones on the same notification, and a
        // change set written to the working tree twice — the second time
        // against a tree that has already moved.
        let store = seeded();
        store
            .upsert_task(&task("task-1", TaskStatus::AwaitingReview))
            .unwrap();

        let first = store
            .decide_task("task-1", TaskStatus::Applied, DecidedVia::Phone, None, 100)
            .unwrap();
        assert!(first.was_recorded());

        let second = store
            .decide_task(
                "task-1",
                TaskStatus::Rejected,
                DecidedVia::Web,
                Some("no"),
                200,
            )
            .unwrap();
        assert!(!second.was_recorded());
        assert_eq!(second.task().status, TaskStatus::Applied);
        assert_eq!(second.task().decided_via, Some(DecidedVia::Phone));
        assert_eq!(second.task().review_note, None);
    }

    #[test]
    fn a_rejection_keeps_the_reason_the_reviewer_gave() {
        let store = seeded();
        store
            .upsert_task(&task("task-1", TaskStatus::AwaitingReview))
            .unwrap();

        let outcome = store
            .decide_task(
                "task-1",
                TaskStatus::Rejected,
                DecidedVia::Phone,
                Some("this breaks the retry cap"),
                300,
            )
            .unwrap();

        let task = outcome.task();
        assert_eq!(
            task.review_note.as_deref(),
            Some("this breaks the retry cap")
        );
        assert_eq!(task.decided_at, Some(300));
        assert_eq!(task.updated_at, 300);
    }

    #[test]
    fn deciding_a_task_that_does_not_exist_is_not_found_rather_than_a_panic() {
        assert!(matches!(
            seeded().decide_task("nope", TaskStatus::Applied, DecidedVia::Web, None, 1),
            Err(StoreError::NotFound(_))
        ));
    }

    #[test]
    fn tasks_are_listed_newest_first() {
        let store = seeded();
        for (id, created_at) in [("old", 1_000), ("new", 3_000), ("middle", 2_000)] {
            let mut row = task(id, TaskStatus::Applied);
            row.created_at = created_at;
            store.upsert_task(&row).unwrap();
        }

        let ids: Vec<String> = store
            .list_tasks(10)
            .unwrap()
            .into_iter()
            .map(|task| task.id)
            .collect();
        assert_eq!(ids, vec!["new", "middle", "old"]);
    }

    fn event(id: &str, session_id: &str, cost_usd: f64, created_at: i64) -> UsageEvent {
        UsageEvent {
            id: id.into(),
            session_id: session_id.into(),
            model: "claude-opus-5".into(),
            tier: Tier::Large,
            task_type: TaskType::Edit,
            usage: Usage {
                input_tokens: 1_000,
                output_tokens: 200,
                cache_write_tokens: 0,
                cache_read_tokens: 40_000,
            },
            cost_usd,
            avoided: None,
            created_at,
        }
    }

    #[test]
    fn a_fresh_database_is_at_the_latest_schema_version() {
        let store = SqliteStore::open_in_memory().unwrap();
        assert_eq!(store.schema_version().unwrap(), MIGRATIONS.len() as i64);
    }

    #[test]
    fn migrating_twice_is_a_no_op() {
        let store = SqliteStore::open_in_memory().unwrap();
        let conn = store.lock().unwrap();
        migrate(&conn).expect("re-running migrations must not re-apply DDL");
    }

    #[test]
    fn a_recorded_call_moves_the_session_budget_in_the_same_breath() {
        let store = seeded();
        let quote = quote(
            "claude-opus-5",
            &event("e", "session-1", 0.0, NOW_MS).usage,
            QuoteContext::interactive(NOW_MS),
        )
        .unwrap();

        store
            .record_usage(&event("event-1", "session-1", quote.total_usd(), NOW_MS))
            .unwrap();

        let budget = store.session_budget("session-1").unwrap();
        assert!((budget.spent_usd - quote.total_usd()).abs() < 1e-12);
        assert_eq!(
            store.get_session("session-1").unwrap().unwrap().spent_usd,
            budget.spent_usd
        );
    }

    #[test]
    fn recording_against_an_unknown_session_writes_nothing() {
        let store = seeded();
        let err = store
            .record_usage(&event("event-1", "ghost-session", 1.0, NOW_MS))
            .unwrap_err();
        assert!(matches!(err, StoreError::NotFound(_)));
        // The ledger insert must have rolled back with the failed budget update.
        assert!(
            store
                .list_usage("ghost-session", TimeRange::ALL)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn a_failed_ledger_insert_rolls_back_the_budget_it_already_moved() {
        let store = seeded();
        store
            .record_usage(&event("event-1", "session-1", 1.0, NOW_MS))
            .unwrap();

        // Same primary key: the insert violates the PK *after* the budget update
        // in the same transaction. Spend must not drift.
        store
            .record_usage(&event("event-1", "session-1", 1.0, NOW_MS))
            .unwrap_err();

        let budget = store.session_budget("session-1").unwrap();
        assert!(
            (budget.spent_usd - 1.0).abs() < 1e-12,
            "got {}",
            budget.spent_usd
        );
        assert_eq!(
            store.list_usage("session-1", TimeRange::ALL).unwrap().len(),
            1
        );
    }

    #[test]
    fn ledger_rows_round_trip_with_their_token_counts_intact() {
        let store = seeded();
        let written = event("event-1", "session-1", 0.25, NOW_MS);
        store.record_usage(&written).unwrap();

        let read = store.list_usage("session-1", TimeRange::ALL).unwrap();
        assert_eq!(read, vec![written]);
    }

    #[test]
    fn list_usage_honours_the_time_range() {
        let store = seeded();
        store
            .record_usage(&event("old", "session-1", 0.1, NOW_MS - 10_000))
            .unwrap();
        store
            .record_usage(&event("new", "session-1", 0.1, NOW_MS))
            .unwrap();

        let recent = store
            .list_usage("session-1", TimeRange::since(NOW_MS))
            .unwrap();
        assert_eq!(recent.len(), 1);
        assert_eq!(recent[0].id, "new");
    }

    #[test]
    fn repo_budget_sums_every_session_in_the_repo() {
        let store = seeded();
        store.upsert_session(&session("session-2", None)).unwrap();
        store
            .record_usage(&event("e1", "session-1", 1.50, NOW_MS))
            .unwrap();
        store
            .record_usage(&event("e2", "session-2", 2.25, NOW_MS))
            .unwrap();

        let budget = store.repo_budget("repo-1").unwrap();
        assert_eq!(budget.cap_usd, Some(10.0));
        assert!((budget.spent_usd - 3.75).abs() < 1e-12);
        assert!(!budget.is_warning());
    }

    #[test]
    fn re_upserting_a_session_does_not_reset_its_spend() {
        let store = seeded();
        store
            .record_usage(&event("e1", "session-1", 2.0, NOW_MS))
            .unwrap();

        // A status update carrying a stale spent_usd = 0.0, as the session
        // manager would send after a restart.
        let mut stale = session("session-1", Some(5.0));
        stale.status = SessionStatus::AwaitingApproval;
        store.upsert_session(&stale).unwrap();

        let after = store.get_session("session-1").unwrap().unwrap();
        assert_eq!(after.status, SessionStatus::AwaitingApproval);
        assert!((after.spent_usd - 2.0).abs() < 1e-12);
    }

    fn plan_step(ordinal: i64, status: PlanStepStatus) -> PlanStep {
        PlanStep {
            id: format!("step-{ordinal}"),
            plan_id: "plan-1".into(),
            ordinal,
            title: format!("Step {ordinal}"),
            status,
            checkpoint_sha: None,
        }
    }

    fn seeded_plan(store: &SqliteStore) {
        store
            .upsert_plan(&Plan {
                id: "plan-1".into(),
                repo_id: "repo-1".into(),
                file_path: "PLAN.md".into(),
                content_hash: "hash-a".into(),
                created_at: NOW_MS,
            })
            .unwrap();
    }

    fn approval(id: &str, risk: Risk) -> Approval {
        Approval {
            id: id.into(),
            session_id: "session-1".into(),
            tool: "bash".into(),
            payload: "pytest tests/billing -x".into(),
            risk,
            decision: None,
            decided_via: None,
            requested_at: NOW_MS,
            decided_at: None,
        }
    }

    #[test]
    fn plan_steps_come_back_in_ordinal_order() {
        let store = seeded();
        seeded_plan(&store);
        store
            .replace_plan_steps(
                "plan-1",
                &[
                    plan_step(3, PlanStepStatus::Todo),
                    plan_step(1, PlanStepStatus::Done),
                    plan_step(2, PlanStepStatus::Active),
                ],
            )
            .unwrap();

        let ordinals: Vec<i64> = store
            .list_plan_steps("plan-1")
            .unwrap()
            .iter()
            .map(|step| step.ordinal)
            .collect();
        assert_eq!(ordinals, vec![1, 2, 3]);
    }

    #[test]
    fn replacing_steps_rebuilds_the_mirror_rather_than_appending() {
        let store = seeded();
        seeded_plan(&store);
        store
            .replace_plan_steps(
                "plan-1",
                &[
                    plan_step(1, PlanStepStatus::Todo),
                    plan_step(2, PlanStepStatus::Todo),
                    plan_step(3, PlanStepStatus::Todo),
                ],
            )
            .unwrap();

        // The file lost a step; the mirror must follow, not accumulate.
        store
            .replace_plan_steps("plan-1", &[plan_step(1, PlanStepStatus::Todo)])
            .unwrap();
        assert_eq!(store.list_plan_steps("plan-1").unwrap().len(), 1);
    }

    #[test]
    fn a_step_transition_persists_its_checkpoint() {
        let store = seeded();
        seeded_plan(&store);
        store
            .replace_plan_steps("plan-1", &[plan_step(1, PlanStepStatus::Active)])
            .unwrap();

        let mut step = store.list_plan_steps("plan-1").unwrap().remove(0);
        step.status = PlanStepStatus::Done;
        step.checkpoint_sha = Some("abc123".into());
        store.update_plan_step(&step).unwrap();

        let stored = store.list_plan_steps("plan-1").unwrap().remove(0);
        assert_eq!(stored.status, PlanStepStatus::Done);
        assert_eq!(stored.checkpoint_sha.as_deref(), Some("abc123"));
    }

    #[test]
    fn updating_a_step_that_is_not_there_is_an_error() {
        let store = seeded();
        seeded_plan(&store);
        let err = store
            .update_plan_step(&plan_step(9, PlanStepStatus::Done))
            .unwrap_err();
        assert!(matches!(err, StoreError::NotFound(_)));
    }

    #[test]
    fn only_undecided_approvals_are_pending() {
        let store = seeded();
        store.create_approval(&approval("a1", Risk::Low)).unwrap();
        store
            .create_approval(&approval("a2", Risk::Destructive))
            .unwrap();
        assert_eq!(store.list_pending_approvals().unwrap().len(), 2);

        store
            .decide_approval("a1", Decision::Approved, DecidedVia::Watch, NOW_MS + 3_000)
            .unwrap();

        let pending = store.list_pending_approvals().unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].id, "a2");
    }

    #[test]
    fn the_first_device_to_decide_wins_the_race() {
        let store = seeded();
        store.create_approval(&approval("a1", Risk::Low)).unwrap();

        let first = store
            .decide_approval("a1", Decision::Approved, DecidedVia::Watch, NOW_MS + 1_000)
            .unwrap();
        let second = store
            .decide_approval("a1", Decision::Denied, DecidedVia::Phone, NOW_MS + 2_000)
            .unwrap();

        assert!(matches!(first, DecisionOutcome::Recorded(_)));
        assert!(matches!(second, DecisionOutcome::AlreadyDecided(_)));

        // The deny must not have overwritten the approve.
        let stored = second.approval();
        assert_eq!(stored.decision, Some(Decision::Approved));
        assert_eq!(stored.decided_via, Some(DecidedVia::Watch));
        assert_eq!(stored.latency_ms(), Some(1_000));
    }

    #[test]
    fn deciding_an_unknown_approval_is_an_error() {
        let store = seeded();
        let err = store
            .decide_approval("ghost", Decision::Approved, DecidedVia::Web, NOW_MS)
            .unwrap_err();
        assert!(matches!(err, StoreError::NotFound(_)));
    }

    const MINUTE_MS: i64 = 60 * 1_000;

    #[test]
    fn a_cached_response_comes_back_until_it_expires() {
        let store = seeded();
        store
            .cache_put("key-a", "the answer", NOW_MS, 5 * MINUTE_MS)
            .unwrap();

        assert_eq!(
            store
                .cache_get("key-a", NOW_MS + MINUTE_MS)
                .unwrap()
                .as_deref(),
            Some("the answer")
        );
        // Exactly at the expiry instant it is already gone — the boundary is
        // exclusive, so a stale answer never sneaks through on a tie.
        assert_eq!(
            store.cache_get("key-a", NOW_MS + 5 * MINUTE_MS).unwrap(),
            None
        );
    }

    #[test]
    fn a_cache_miss_is_none_rather_than_an_error() {
        let store = seeded();
        assert_eq!(store.cache_get("never-written", NOW_MS).unwrap(), None);
    }

    #[test]
    fn hits_are_counted_but_misses_are_not() {
        let store = seeded();
        store
            .cache_put("key-a", "answer", NOW_MS, MINUTE_MS)
            .unwrap();
        store.cache_get("key-a", NOW_MS).unwrap();
        store.cache_get("key-a", NOW_MS).unwrap();
        store.cache_get("absent", NOW_MS).unwrap();

        let hits: i64 = {
            let conn = store.lock().unwrap();
            conn.query_row(
                "SELECT hit_count FROM response_cache WHERE key_hash = 'key-a'",
                [],
                |row| row.get(0),
            )
            .unwrap()
        };
        assert_eq!(hits, 2);
    }

    #[test]
    fn re_putting_a_key_refreshes_it_instead_of_failing() {
        let store = seeded();
        store
            .cache_put("key-a", "first", NOW_MS, MINUTE_MS)
            .unwrap();
        store
            .cache_put("key-a", "second", NOW_MS + MINUTE_MS, MINUTE_MS)
            .unwrap();

        assert_eq!(
            store
                .cache_get("key-a", NOW_MS + MINUTE_MS)
                .unwrap()
                .as_deref(),
            Some("second")
        );
    }

    #[test]
    fn purging_removes_only_expired_entries() {
        let store = seeded();
        store.cache_put("stale", "old", NOW_MS, MINUTE_MS).unwrap();
        store
            .cache_put("fresh", "new", NOW_MS, 60 * MINUTE_MS)
            .unwrap();

        let purged = store.cache_purge_expired(NOW_MS + 2 * MINUTE_MS).unwrap();
        assert_eq!(purged, 1);
        assert!(
            store
                .cache_get("fresh", NOW_MS + 2 * MINUTE_MS)
                .unwrap()
                .is_some()
        );
    }

    fn device(id: &str, kind: DeviceKind) -> Device {
        Device {
            id: id.into(),
            kind,
            pubkey: "cHVia2V5".into(),
            push_token: None,
            paired_at: NOW_MS,
        }
    }

    #[test]
    fn paired_devices_come_back_in_pairing_order() {
        let store = seeded();
        store
            .upsert_device(&device("phone", DeviceKind::Phone))
            .unwrap();
        let mut watch = device("watch", DeviceKind::Watch);
        watch.paired_at = NOW_MS + 1_000;
        store.upsert_device(&watch).unwrap();

        let ids: Vec<String> = store
            .list_devices()
            .unwrap()
            .into_iter()
            .map(|d| d.id)
            .collect();
        assert_eq!(ids, vec!["phone", "watch"]);
    }

    #[test]
    fn re_pairing_a_device_replaces_its_key() {
        let store = seeded();
        store
            .upsert_device(&device("phone", DeviceKind::Phone))
            .unwrap();

        let mut rotated = device("phone", DeviceKind::Phone);
        rotated.pubkey = "bmV3LWtleQ".into();
        store.upsert_device(&rotated).unwrap();

        assert_eq!(store.list_devices().unwrap().len(), 1);
        assert_eq!(
            store.get_device("phone").unwrap().unwrap().pubkey,
            "bmV3LWtleQ"
        );
    }

    #[test]
    fn re_pairing_keeps_a_push_token_the_new_registration_did_not_carry() {
        // Pairing and push subscription happen at different moments; the second
        // must not wipe the first.
        let store = seeded();
        let mut with_token = device("phone", DeviceKind::Phone);
        with_token.push_token = Some("https://push.example/abc".into());
        store.upsert_device(&with_token).unwrap();

        store
            .upsert_device(&device("phone", DeviceKind::Phone))
            .unwrap();
        assert_eq!(
            store
                .get_device("phone")
                .unwrap()
                .unwrap()
                .push_token
                .as_deref(),
            Some("https://push.example/abc")
        );
    }

    #[test]
    fn an_unknown_device_is_none() {
        assert_eq!(seeded().get_device("never-paired").unwrap(), None);
    }

    #[test]
    fn a_row_with_an_unknown_enum_value_reports_corruption() {
        let store = seeded();
        {
            let conn = store.lock().unwrap();
            conn.execute("UPDATE session SET status = 'levitating'", [])
                .unwrap();
        }
        let err = store.get_session("session-1").unwrap_err();
        assert!(matches!(err, StoreError::Corrupt(_)), "got {err:?}");
    }
}

#[cfg(test)]
mod batch_queue_tests {
    use super::*;
    use crate::types::{Agent, BatchItem, BatchStatus, Repo, Session, SessionStatus, TaskType};

    const NOW: i64 = 1_785_369_600_000;

    fn store() -> SqliteStore {
        let store = SqliteStore::open_in_memory().unwrap();
        store
            .upsert_machine(&crate::types::Machine {
                id: "m1".into(),
                name: "laptop".into(),
                pubkey: "k".into(),
                last_seen_at: Some(NOW),
                created_at: NOW,
            })
            .unwrap();
        store
            .upsert_repo(&Repo {
                id: "r1".into(),
                machine_id: "m1".into(),
                path: "/srv/api".into(),
                name: "api".into(),
                budget_usd: None,
            })
            .unwrap();
        store
            .upsert_session(&Session {
                id: "s1".into(),
                repo_id: "r1".into(),
                agent: Agent::ClaudeCode,
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
        store
    }

    fn item(id: &str, custom: &str) -> BatchItem {
        BatchItem {
            id: id.into(),
            session_id: "s1".into(),
            custom_id: custom.into(),
            task_type: TaskType::Summarize,
            model: "claude-haiku-4-5".into(),
            request_json: r#"{"model":"claude-haiku-4-5"}"#.into(),
            batch_id: None,
            status: BatchStatus::Queued,
            response_text: None,
            error: None,
            queued_at: NOW,
            submitted_at: None,
            settled_at: None,
        }
    }

    #[test]
    fn a_queued_item_round_trips() {
        let store = store();
        let queued = item("b1", "c1");
        store.enqueue_batch_item(&queued).unwrap();
        assert_eq!(store.get_batch_item("b1").unwrap().unwrap(), queued);
    }

    #[test]
    fn the_flusher_sees_queued_items_oldest_first() {
        let store = store();
        let mut later = item("b2", "c2");
        later.queued_at = NOW + 1_000;
        store.enqueue_batch_item(&later).unwrap();
        store.enqueue_batch_item(&item("b1", "c1")).unwrap();

        let queued = store.list_queued_batch_items(10).unwrap();
        assert_eq!(
            queued.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(),
            ["b1", "b2"],
            "the oldest deferred work should not starve"
        );
    }

    #[test]
    fn the_flusher_can_bound_how_much_it_takes() {
        // A batch is capped at 100,000 requests; the queue is not.
        let store = store();
        for index in 0..5 {
            store
                .enqueue_batch_item(&item(&format!("b{index}"), &format!("c{index}")))
                .unwrap();
        }
        assert_eq!(store.list_queued_batch_items(3).unwrap().len(), 3);
    }

    #[test]
    fn two_items_cannot_share_a_custom_id() {
        // The custom id is the only thing tying a result — and its cost — to the
        // row that asked for it. A collision would bill the wrong session.
        let store = store();
        store.enqueue_batch_item(&item("b1", "same")).unwrap();
        assert!(store.enqueue_batch_item(&item("b2", "same")).is_err());
    }

    #[test]
    fn submitting_moves_the_whole_batch_at_once() {
        let store = store();
        store.enqueue_batch_item(&item("b1", "c1")).unwrap();
        store.enqueue_batch_item(&item("b2", "c2")).unwrap();

        store
            .mark_batch_submitted(&["b1".into(), "b2".into()], "batch_abc", NOW + 500)
            .unwrap();

        assert!(store.list_queued_batch_items(10).unwrap().is_empty());
        let submitted = store.list_submitted_batch_items().unwrap();
        assert_eq!(submitted.len(), 2);
        assert!(
            submitted
                .iter()
                .all(|i| i.batch_id.as_deref() == Some("batch_abc"))
        );
        assert!(submitted.iter().all(|i| i.submitted_at == Some(NOW + 500)));
    }

    #[test]
    fn submitting_nothing_is_not_an_error() {
        // An empty queue is the normal state, and the flusher runs on a timer.
        let store = store();
        assert!(store.mark_batch_submitted(&[], "batch_abc", NOW).is_ok());
    }

    #[test]
    fn an_item_already_in_flight_is_not_resubmitted() {
        // The guard against paying twice: a flush that overlaps a retry must not
        // move an item that is already out with another batch.
        let store = store();
        store.enqueue_batch_item(&item("b1", "c1")).unwrap();
        store
            .mark_batch_submitted(&["b1".into()], "first", NOW)
            .unwrap();
        store
            .mark_batch_submitted(&["b1".into()], "second", NOW + 100)
            .unwrap();

        let item = store.get_batch_item("b1").unwrap().unwrap();
        assert_eq!(item.batch_id.as_deref(), Some("first"));
        assert_eq!(item.submitted_at, Some(NOW));
    }

    #[test]
    fn settling_records_the_answer() {
        let store = store();
        store.enqueue_batch_item(&item("b1", "c1")).unwrap();
        store
            .mark_batch_submitted(&["b1".into()], "batch_abc", NOW)
            .unwrap();
        store
            .settle_batch_item(
                "c1",
                BatchStatus::Succeeded,
                Some("the summary"),
                None,
                NOW + 900,
            )
            .unwrap();

        let settled = store.get_batch_item("b1").unwrap().unwrap();
        assert_eq!(settled.status, BatchStatus::Succeeded);
        assert_eq!(settled.response_text.as_deref(), Some("the summary"));
        assert_eq!(settled.settled_at, Some(NOW + 900));
        assert!(store.list_submitted_batch_items().unwrap().is_empty());
    }

    #[test]
    fn settling_twice_does_not_overwrite_the_first_answer() {
        // Results can be fetched more than once — a poll overlapping a retry.
        // Billing the same tokens twice is the failure this prevents.
        let store = store();
        store.enqueue_batch_item(&item("b1", "c1")).unwrap();
        store
            .mark_batch_submitted(&["b1".into()], "batch_abc", NOW)
            .unwrap();
        store
            .settle_batch_item("c1", BatchStatus::Succeeded, Some("first"), None, NOW + 900)
            .unwrap();
        store
            .settle_batch_item("c1", BatchStatus::Errored, None, Some("late"), NOW + 950)
            .unwrap();

        let settled = store.get_batch_item("b1").unwrap().unwrap();
        assert_eq!(settled.status, BatchStatus::Succeeded);
        assert_eq!(settled.response_text.as_deref(), Some("first"));
    }

    #[test]
    fn settling_something_that_was_never_sent_changes_nothing() {
        let store = store();
        store.enqueue_batch_item(&item("b1", "c1")).unwrap();
        store
            .settle_batch_item("c1", BatchStatus::Succeeded, Some("x"), None, NOW)
            .unwrap();
        assert_eq!(
            store.get_batch_item("b1").unwrap().unwrap().status,
            BatchStatus::Queued
        );
    }

    #[test]
    fn an_error_is_recorded_with_its_reason() {
        let store = store();
        store.enqueue_batch_item(&item("b1", "c1")).unwrap();
        store
            .mark_batch_submitted(&["b1".into()], "batch_abc", NOW)
            .unwrap();
        store
            .settle_batch_item(
                "c1",
                BatchStatus::Errored,
                None,
                Some("invalid_request"),
                NOW,
            )
            .unwrap();

        let settled = store.get_batch_item("b1").unwrap().unwrap();
        assert_eq!(settled.error.as_deref(), Some("invalid_request"));
        assert!(settled.status.is_settled());
    }

    #[test]
    fn a_sessions_items_are_newest_first() {
        let store = store();
        store.enqueue_batch_item(&item("b1", "c1")).unwrap();
        let mut newer = item("b2", "c2");
        newer.queued_at = NOW + 1_000;
        store.enqueue_batch_item(&newer).unwrap();

        let listed = store.list_batch_items_for_session("s1").unwrap();
        assert_eq!(
            listed.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(),
            ["b2", "b1"]
        );
    }

    #[test]
    fn queued_work_is_not_readable_as_another_sessions() {
        let store = store();
        store.enqueue_batch_item(&item("b1", "c1")).unwrap();
        assert!(
            store
                .list_batch_items_for_session("nope")
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn a_corrupt_status_column_is_an_error_not_a_panic() {
        let store = store();
        store.enqueue_batch_item(&item("b1", "c1")).unwrap();
        store
            .lock()
            .unwrap()
            .execute("UPDATE batch_item SET status = 'nonsense'", [])
            .unwrap();
        assert!(store.get_batch_item("b1").is_err());
    }
}
