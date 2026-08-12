//! The control plane's storage, backed by SQLite in WAL mode.
//!
//! Same shape as `forge-sqlite`: one file, no daemon, migrations keyed on
//! `PRAGMA user_version`. Postgres is the obvious eventual move, and the reason
//! this is a concrete struct rather than a trait is that inventing the port
//! before there are two implementations produces the wrong port. Every query
//! here is ordinary SQL against ordinary tables; porting it is a day, and a
//! speculative abstraction would cost more than that in the meantime.
//!
//! **Secrets stop here.** Password hashes and token hashes are read and compared
//! inside this module and are not fields on any type in [`crate::model`], so
//! there is no route by which one reaches a handler, let alone a response.

use std::path::Path;
use std::sync::Mutex;

use rusqlite::{Connection, OptionalExtension, Row, params};

use crate::model::{
    Account, Device, EnrollmentKey, Membership, Org, Runner, Subscription, normalize_email,
};
use crate::plan::{Plan, SubscriptionStatus, Usage};
use crate::secret;
use forge_crypto::token::Role;

/// Applied in order; the index+1 is the `PRAGMA user_version` they leave behind.
const MIGRATIONS: &[&str] = &[
    include_str!("../migrations/0001_init.sql"),
    include_str!("../migrations/0002_oauth.sql"),
];

#[derive(Debug)]
pub enum StoreError {
    /// Something the caller could have avoided: a duplicate email, an unknown
    /// id, a slug already taken.
    Conflict(String),
    NotFound(String),
    /// Anything else SQLite said. Never shown to a user verbatim.
    Backend(String),
}

impl std::fmt::Display for StoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StoreError::Conflict(what) => write!(f, "{what}"),
            StoreError::NotFound(what) => write!(f, "{what} not found"),
            StoreError::Backend(what) => write!(f, "storage error: {what}"),
        }
    }
}

impl std::error::Error for StoreError {}

pub type Result<T> = std::result::Result<T, StoreError>;

fn backend(err: rusqlite::Error) -> StoreError {
    StoreError::Backend(err.to_string())
}

/// One row of `oauth_code`, as it comes back from SQLite.
type OauthCodeRow = (
    String,
    String,
    String,
    String,
    String,
    String,
    Option<String>,
    i64,
);

/// A connector a person has authorised: client id, its name, when it was
/// granted, and when it was last used.
pub type ConnectorGrant = (String, String, i64, Option<i64>);

/// A short, sortable, unguessable id.
///
/// Prefixed by kind (`acc_`, `org_`, `run_`, `dev_`) because ids end up in
/// logs, URLs and support conversations, and "which table is this from" should
/// not require a query to answer.
pub fn new_id(prefix: &str) -> String {
    use base64::Engine as _;
    use rand_core::RngCore as _;
    let mut bytes = [0u8; 12];
    rand_core::OsRng.fill_bytes(&mut bytes);
    format!(
        "{prefix}_{}",
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
    )
}

pub struct CloudStore {
    conn: Mutex<Connection>,
}

impl CloudStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Self::from_connection(Connection::open(path).map_err(backend)?)
    }

    pub fn open_in_memory() -> Result<Self> {
        Self::from_connection(Connection::open_in_memory().map_err(backend)?)
    }

    fn from_connection(conn: Connection) -> Result<Self> {
        conn.pragma_update_and_check(None, "journal_mode", "WAL", |_| Ok(()))
            .map_err(backend)?;
        conn.pragma_update(None, "synchronous", "NORMAL")
            .map_err(backend)?;
        // Load-bearing: the cascades in the schema are what make deleting an
        // account actually remove its devices and tokens rather than orphan them.
        conn.pragma_update(None, "foreign_keys", "ON")
            .map_err(backend)?;
        migrate(&conn)?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    fn lock(&self) -> Result<std::sync::MutexGuard<'_, Connection>> {
        self.conn
            .lock()
            .map_err(|_| StoreError::Backend("database mutex poisoned".into()))
    }

    pub fn schema_version(&self) -> Result<i64> {
        self.lock()?
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .map_err(backend)
    }

    /* ------------------------------------------------------------ accounts */

    /// Create an account, its organisation, its owner membership and its free
    /// subscription — in one transaction, because an account with no
    /// organisation is an account that cannot do anything and cannot be fixed
    /// through the API.
    pub fn create_account(
        &self,
        email: &str,
        display_name: &str,
        password_hash: &str,
        org_name: &str,
        now_ms: i64,
    ) -> Result<(Account, Org)> {
        let normalized = normalize_email(email);
        let account_id = new_id("acc");
        let org_id = new_id("org");

        let mut conn = self.lock()?;
        let tx = conn.transaction().map_err(backend)?;

        let taken: Option<String> = tx
            .query_row(
                "SELECT id FROM account WHERE email_normalized = ?1",
                params![normalized],
                |row| row.get(0),
            )
            .optional()
            .map_err(backend)?;
        if taken.is_some() {
            return Err(StoreError::Conflict(
                "an account with that email already exists".into(),
            ));
        }

        tx.execute(
            "INSERT INTO account (id, email, email_normalized, password_hash, display_name, \
             created_at, last_seen_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)",
            params![
                account_id,
                email.trim(),
                normalized,
                password_hash,
                display_name.trim(),
                now_ms
            ],
        )
        .map_err(backend)?;

        // A slug collision is expected, not exceptional: two people called
        // "Harsh" both want `harsh`. Suffix rather than fail the sign-up.
        let mut slug = crate::model::slugify(org_name, &org_id);
        for suffix in 1..=64 {
            let exists: Option<String> = tx
                .query_row("SELECT id FROM org WHERE slug = ?1", params![slug], |row| {
                    row.get(0)
                })
                .optional()
                .map_err(backend)?;
            if exists.is_none() {
                break;
            }
            slug = format!("{}-{suffix}", crate::model::slugify(org_name, &org_id));
        }

        tx.execute(
            "INSERT INTO org (id, name, slug, created_at) VALUES (?1, ?2, ?3, ?4)",
            params![org_id, org_name.trim(), slug, now_ms],
        )
        .map_err(backend)?;

        tx.execute(
            "INSERT INTO membership (org_id, account_id, role, created_at) \
             VALUES (?1, ?2, ?3, ?4)",
            params![org_id, account_id, Role::Owner.as_str(), now_ms],
        )
        .map_err(backend)?;

        tx.execute(
            "INSERT INTO subscription (org_id, plan, status, cancel_at_period_end, updated_at) \
             VALUES (?1, ?2, ?3, 0, ?4)",
            params![
                org_id,
                Plan::Free.as_str(),
                SubscriptionStatus::Active.as_str(),
                now_ms
            ],
        )
        .map_err(backend)?;

        tx.commit().map_err(backend)?;

        Ok((
            Account {
                id: account_id,
                email: email.trim().to_owned(),
                display_name: display_name.trim().to_owned(),
                created_at: now_ms,
                last_seen_at: now_ms,
            },
            Org {
                id: org_id,
                name: org_name.trim().to_owned(),
                slug,
                created_at: now_ms,
            },
        ))
    }

    /// Look up an account by email and check its password.
    ///
    /// Returns `None` for both "no such account" and "wrong password", and
    /// spends the Argon2 verification either way. A caller that could tell the
    /// two apart — by the answer or by the timing — is an account enumeration
    /// oracle, which is how credential-stuffing lists get built.
    pub fn authenticate(&self, email: &str, password: &str) -> Result<Option<Account>> {
        let normalized = normalize_email(email);
        let conn = self.lock()?;

        let found: Option<(String, String)> = conn
            .query_row(
                "SELECT id, password_hash FROM account WHERE email_normalized = ?1",
                params![normalized],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .map_err(backend)?;

        let (id, hash) = match found {
            Some(row) => row,
            None => {
                // A hash of the right shape over a value nobody can produce, so
                // the miss costs the same as a hit.
                let decoy = DECOY_HASH;
                let _ = secret::verify_password(password, decoy);
                return Ok(None);
            }
        };

        if !secret::verify_password(password, &hash).unwrap_or(false) {
            return Ok(None);
        }
        drop(conn);
        self.account(&id).map(Some)
    }

    pub fn account(&self, id: &str) -> Result<Account> {
        self.lock()?
            .query_row(
                "SELECT id, email, display_name, created_at, last_seen_at FROM account \
                 WHERE id = ?1",
                params![id],
                read_account,
            )
            .optional()
            .map_err(backend)?
            .ok_or_else(|| StoreError::NotFound(format!("account {id}")))
    }

    pub fn touch_account(&self, id: &str, now_ms: i64) -> Result<()> {
        self.lock()?
            .execute(
                "UPDATE account SET last_seen_at = ?2 WHERE id = ?1",
                params![id, now_ms],
            )
            .map_err(backend)?;
        Ok(())
    }

    pub fn update_password(&self, id: &str, password_hash: &str) -> Result<()> {
        let changed = self
            .lock()?
            .execute(
                "UPDATE account SET password_hash = ?2 WHERE id = ?1",
                params![id, password_hash],
            )
            .map_err(backend)?;
        if changed == 0 {
            return Err(StoreError::NotFound(format!("account {id}")));
        }
        Ok(())
    }

    /* --------------------------------------------------------- memberships */

    /// The organisations this account belongs to, most recently joined first.
    pub fn memberships(&self, account_id: &str) -> Result<Vec<(Org, Role)>> {
        let conn = self.lock()?;
        let mut statement = conn
            .prepare(
                "SELECT o.id, o.name, o.slug, o.created_at, m.role \
                 FROM membership m JOIN org o ON o.id = m.org_id \
                 WHERE m.account_id = ?1 ORDER BY m.created_at",
            )
            .map_err(backend)?;

        let rows = statement
            .query_map(params![account_id], |row| {
                Ok((
                    Org {
                        id: row.get(0)?,
                        name: row.get(1)?,
                        slug: row.get(2)?,
                        created_at: row.get(3)?,
                    },
                    row.get::<_, String>(4)?,
                ))
            })
            .map_err(backend)?;

        let mut out = Vec::new();
        for row in rows {
            let (org, role) = row.map_err(backend)?;
            out.push((org, role.parse().unwrap_or(Role::Viewer)));
        }
        Ok(out)
    }

    /// This account's role in `org_id`, or `None` if it is not a member.
    ///
    /// Every authenticated handler funnels through this. It is the single point
    /// where "you asked about an organisation" becomes "you may ask about this
    /// organisation" — a tenancy check in one place rather than in thirty.
    pub fn role_in(&self, org_id: &str, account_id: &str) -> Result<Option<Role>> {
        Ok(self
            .lock()?
            .query_row(
                "SELECT role FROM membership WHERE org_id = ?1 AND account_id = ?2",
                params![org_id, account_id],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(backend)?
            .and_then(|role| role.parse().ok()))
    }

    pub fn members(&self, org_id: &str) -> Result<Vec<(Account, Role)>> {
        let conn = self.lock()?;
        let mut statement = conn
            .prepare(
                "SELECT a.id, a.email, a.display_name, a.created_at, a.last_seen_at, m.role \
                 FROM membership m JOIN account a ON a.id = m.account_id \
                 WHERE m.org_id = ?1 ORDER BY m.created_at",
            )
            .map_err(backend)?;

        let rows = statement
            .query_map(params![org_id], |row| {
                Ok((read_account(row)?, row.get::<_, String>(5)?))
            })
            .map_err(backend)?;

        let mut out = Vec::new();
        for row in rows {
            let (account, role) = row.map_err(backend)?;
            out.push((account, role.parse().unwrap_or(Role::Viewer)));
        }
        Ok(out)
    }

    pub fn add_member(
        &self,
        org_id: &str,
        account_id: &str,
        role: Role,
        now_ms: i64,
    ) -> Result<Membership> {
        self.lock()?
            .execute(
                "INSERT INTO membership (org_id, account_id, role, created_at) \
                 VALUES (?1, ?2, ?3, ?4) \
                 ON CONFLICT(org_id, account_id) DO UPDATE SET role = excluded.role",
                params![org_id, account_id, role.as_str(), now_ms],
            )
            .map_err(backend)?;
        Ok(Membership {
            org_id: org_id.to_owned(),
            account_id: account_id.to_owned(),
            role,
            created_at: now_ms,
        })
    }

    /// Remove someone from an organisation.
    ///
    /// Refuses to remove the last owner. An organisation nobody can administer
    /// is one that can never be billed, upgraded, or deleted — recoverable only
    /// by hand, in the database.
    pub fn remove_member(&self, org_id: &str, account_id: &str) -> Result<()> {
        let mut conn = self.lock()?;
        let tx = conn.transaction().map_err(backend)?;

        let role: Option<String> = tx
            .query_row(
                "SELECT role FROM membership WHERE org_id = ?1 AND account_id = ?2",
                params![org_id, account_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(backend)?;
        let Some(role) = role else {
            return Err(StoreError::NotFound("membership".into()));
        };

        if role == Role::Owner.as_str() {
            let owners: i64 = tx
                .query_row(
                    "SELECT COUNT(*) FROM membership WHERE org_id = ?1 AND role = ?2",
                    params![org_id, Role::Owner.as_str()],
                    |row| row.get(0),
                )
                .map_err(backend)?;
            if owners <= 1 {
                return Err(StoreError::Conflict(
                    "an organisation must keep at least one owner".into(),
                ));
            }
        }

        tx.execute(
            "DELETE FROM membership WHERE org_id = ?1 AND account_id = ?2",
            params![org_id, account_id],
        )
        .map_err(backend)?;
        tx.commit().map_err(backend)?;
        Ok(())
    }

    pub fn account_by_email(&self, email: &str) -> Result<Option<Account>> {
        self.lock()?
            .query_row(
                "SELECT id, email, display_name, created_at, last_seen_at FROM account \
                 WHERE email_normalized = ?1",
                params![normalize_email(email)],
                read_account,
            )
            .optional()
            .map_err(backend)
    }

    /* -------------------------------------------------------- subscription */

    pub fn subscription(&self, org_id: &str) -> Result<Subscription> {
        self.lock()?
            .query_row(
                "SELECT org_id, plan, status, customer_id, subscription_id, current_period_end, \
                 cancel_at_period_end, updated_at FROM subscription WHERE org_id = ?1",
                params![org_id],
                read_subscription,
            )
            .optional()
            .map_err(backend)?
            .ok_or_else(|| StoreError::NotFound(format!("subscription for {org_id}")))
    }

    pub fn save_subscription(&self, subscription: &Subscription) -> Result<()> {
        self.lock()?
            .execute(
                "INSERT INTO subscription (org_id, plan, status, customer_id, subscription_id, \
                 current_period_end, cancel_at_period_end, updated_at) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8) \
                 ON CONFLICT(org_id) DO UPDATE SET plan = excluded.plan, \
                 status = excluded.status, customer_id = excluded.customer_id, \
                 subscription_id = excluded.subscription_id, \
                 current_period_end = excluded.current_period_end, \
                 cancel_at_period_end = excluded.cancel_at_period_end, \
                 updated_at = excluded.updated_at",
                params![
                    subscription.org_id,
                    subscription.plan.as_str(),
                    subscription.status.as_str(),
                    subscription.customer_id,
                    subscription.subscription_id,
                    subscription.current_period_end,
                    subscription.cancel_at_period_end as i64,
                    subscription.updated_at,
                ],
            )
            .map_err(backend)?;
        Ok(())
    }

    /// Find the organisation a Stripe webhook is about.
    pub fn org_by_customer(&self, customer_id: &str) -> Result<Option<String>> {
        self.lock()?
            .query_row(
                "SELECT org_id FROM subscription WHERE customer_id = ?1",
                params![customer_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(backend)
    }

    /* -------------------------------------------------------------- usage */

    /// What this organisation is using, counted in one round trip.
    pub fn usage(&self, org_id: &str) -> Result<Usage> {
        self.lock()?
            .query_row(
                "SELECT (SELECT COUNT(*) FROM runner WHERE org_id = ?1), \
                        (SELECT COUNT(*) FROM device WHERE org_id = ?1), \
                        (SELECT COUNT(*) FROM membership WHERE org_id = ?1)",
                params![org_id],
                |row| {
                    Ok(Usage {
                        runners: row.get::<_, i64>(0)? as u32,
                        devices: row.get::<_, i64>(1)? as u32,
                        members: row.get::<_, i64>(2)? as u32,
                    })
                },
            )
            .map_err(backend)
    }

    /* ------------------------------------------------------------ runners */

    pub fn runners(&self, org_id: &str) -> Result<Vec<Runner>> {
        let conn = self.lock()?;
        let mut statement = conn
            .prepare(&format!(
                "SELECT {RUNNER_COLUMNS} FROM runner WHERE org_id = ?1 ORDER BY created_at"
            ))
            .map_err(backend)?;
        let rows = statement
            .query_map(params![org_id], read_runner)
            .map_err(backend)?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(backend)
    }

    pub fn runner(&self, id: &str) -> Result<Runner> {
        self.lock()?
            .query_row(
                &format!("SELECT {RUNNER_COLUMNS} FROM runner WHERE id = ?1"),
                params![id],
                read_runner,
            )
            .optional()
            .map_err(backend)?
            .ok_or_else(|| StoreError::NotFound(format!("runner {id}")))
    }

    pub fn runner_by_key(&self, public_key: &str) -> Result<Option<Runner>> {
        self.lock()?
            .query_row(
                &format!("SELECT {RUNNER_COLUMNS} FROM runner WHERE public_key = ?1"),
                params![public_key],
                read_runner,
            )
            .optional()
            .map_err(backend)
    }

    pub fn insert_runner(&self, runner: &Runner) -> Result<()> {
        self.lock()?
            .execute(
                "INSERT INTO runner (id, org_id, name, public_key, pending_public_key, channel, \
                 created_at, last_seen_at, version) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    runner.id,
                    runner.org_id,
                    runner.name,
                    runner.public_key,
                    runner.pending_public_key,
                    runner.channel,
                    runner.created_at,
                    runner.last_seen_at,
                    runner.version,
                ],
            )
            .map_err(|err| match err {
                rusqlite::Error::SqliteFailure(error, _)
                    if error.code == rusqlite::ErrorCode::ConstraintViolation =>
                {
                    StoreError::Conflict("that machine is already enrolled".into())
                }
                other => backend(other),
            })?;
        Ok(())
    }

    /// Record that a runner checked in.
    pub fn touch_runner(&self, id: &str, version: &str, now_ms: i64) -> Result<()> {
        self.lock()?
            .execute(
                "UPDATE runner SET last_seen_at = ?2, version = ?3 WHERE id = ?1",
                params![id, now_ms, version],
            )
            .map_err(backend)?;
        Ok(())
    }

    /// Park a key that does not match the pinned one.
    pub fn set_pending_key(&self, id: &str, public_key: Option<&str>) -> Result<()> {
        self.lock()?
            .execute(
                "UPDATE runner SET pending_public_key = ?2 WHERE id = ?1",
                params![id, public_key],
            )
            .map_err(backend)?;
        Ok(())
    }

    /// Accept a pending key as this runner's new identity.
    ///
    /// The channel moves with it, because the channel *is* the key — every
    /// device will pick the new one up on its next workspace fetch.
    pub fn approve_pending_key(&self, id: &str) -> Result<Runner> {
        let mut conn = self.lock()?;
        let tx = conn.transaction().map_err(backend)?;

        let pending: Option<Option<String>> = tx
            .query_row(
                "SELECT pending_public_key FROM runner WHERE id = ?1",
                params![id],
                |row| row.get(0),
            )
            .optional()
            .map_err(backend)?;

        let Some(Some(pending)) = pending else {
            return Err(StoreError::Conflict(
                "that machine has no key change waiting".into(),
            ));
        };

        tx.execute(
            "UPDATE runner SET public_key = ?2, channel = ?3, pending_public_key = NULL \
             WHERE id = ?1",
            params![id, pending, forge_proto::channel_for(&pending)],
        )
        .map_err(backend)?;
        tx.commit().map_err(backend)?;
        drop(conn);
        self.runner(id)
    }

    pub fn rename_runner(&self, id: &str, name: &str) -> Result<()> {
        self.lock()?
            .execute(
                "UPDATE runner SET name = ?2 WHERE id = ?1",
                params![id, name.trim()],
            )
            .map_err(backend)?;
        Ok(())
    }

    pub fn delete_runner(&self, id: &str) -> Result<()> {
        let removed = self
            .lock()?
            .execute("DELETE FROM runner WHERE id = ?1", params![id])
            .map_err(backend)?;
        if removed == 0 {
            return Err(StoreError::NotFound(format!("runner {id}")));
        }
        Ok(())
    }

    /* ------------------------------------------------------------ devices */

    pub fn devices(&self, org_id: &str) -> Result<Vec<Device>> {
        let conn = self.lock()?;
        let mut statement = conn
            .prepare(&format!(
                "SELECT {DEVICE_COLUMNS} FROM device WHERE org_id = ?1 ORDER BY created_at"
            ))
            .map_err(backend)?;
        let rows = statement
            .query_map(params![org_id], read_device)
            .map_err(backend)?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(backend)
    }

    pub fn device(&self, id: &str) -> Result<Device> {
        self.lock()?
            .query_row(
                &format!("SELECT {DEVICE_COLUMNS} FROM device WHERE id = ?1"),
                params![id],
                read_device,
            )
            .optional()
            .map_err(backend)?
            .ok_or_else(|| StoreError::NotFound(format!("device {id}")))
    }

    pub fn device_by_key(&self, public_key: &str) -> Result<Option<Device>> {
        self.lock()?
            .query_row(
                &format!("SELECT {DEVICE_COLUMNS} FROM device WHERE public_key = ?1"),
                params![public_key],
                read_device,
            )
            .optional()
            .map_err(backend)
    }

    pub fn insert_device(&self, device: &Device) -> Result<()> {
        self.lock()?
            .execute(
                "INSERT INTO device (id, org_id, account_id, kind, name, public_key, created_at, \
                 last_seen_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    device.id,
                    device.org_id,
                    device.account_id,
                    device.kind.as_str(),
                    device.name,
                    device.public_key,
                    device.created_at,
                    device.last_seen_at,
                ],
            )
            .map_err(|err| match err {
                rusqlite::Error::SqliteFailure(error, _)
                    if error.code == rusqlite::ErrorCode::ConstraintViolation =>
                {
                    StoreError::Conflict("that device key is already registered".into())
                }
                other => backend(other),
            })?;
        Ok(())
    }

    pub fn touch_device(&self, id: &str, now_ms: i64) -> Result<()> {
        self.lock()?
            .execute(
                "UPDATE device SET last_seen_at = ?2 WHERE id = ?1",
                params![id, now_ms],
            )
            .map_err(backend)?;
        Ok(())
    }

    /// Revoke a device.
    ///
    /// Deleting the row is the revocation: the next channel token it asks for is
    /// refused, and the one it holds expires within
    /// [`forge_crypto::token::CHANNEL_TOKEN_TTL_MS`]. Nothing has to be told —
    /// which is exactly why the tokens are short-lived.
    pub fn delete_device(&self, id: &str) -> Result<()> {
        let removed = self
            .lock()?
            .execute("DELETE FROM device WHERE id = ?1", params![id])
            .map_err(backend)?;
        if removed == 0 {
            return Err(StoreError::NotFound(format!("device {id}")));
        }
        Ok(())
    }

    /* ---------------------------------------------------- enrolment keys */

    pub fn insert_enrollment_key(&self, key: &EnrollmentKey, token_hash: &str) -> Result<()> {
        self.lock()?
            .execute(
                "INSERT INTO enrollment_key (id, org_id, name, prefix, token_hash, created_at, \
                 created_by) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    key.id,
                    key.org_id,
                    key.name,
                    key.prefix,
                    token_hash,
                    key.created_at,
                    key.created_by,
                ],
            )
            .map_err(backend)?;
        Ok(())
    }

    pub fn enrollment_keys(&self, org_id: &str) -> Result<Vec<EnrollmentKey>> {
        let conn = self.lock()?;
        let mut statement = conn
            .prepare(
                "SELECT id, org_id, name, prefix, created_at, created_by, last_used_at, \
                 revoked_at FROM enrollment_key WHERE org_id = ?1 ORDER BY created_at DESC",
            )
            .map_err(backend)?;
        let rows = statement
            .query_map(params![org_id], |row| {
                Ok(EnrollmentKey {
                    id: row.get(0)?,
                    org_id: row.get(1)?,
                    name: row.get(2)?,
                    prefix: row.get(3)?,
                    created_at: row.get(4)?,
                    created_by: row.get(5)?,
                    last_used_at: row.get(6)?,
                    revoked_at: row.get(7)?,
                })
            })
            .map_err(backend)?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(backend)
    }

    /// Resolve a presented enrolment key to the organisation it belongs to.
    ///
    /// Revoked keys resolve to `None` rather than to an error, so a revoked key
    /// and a made-up one are indistinguishable to whoever is trying them.
    pub fn redeem_enrollment_key(&self, token: &str, now_ms: i64) -> Result<Option<String>> {
        let hash = secret::hash_token(token);
        let conn = self.lock()?;

        let found: Option<(String, String, Option<i64>)> = conn
            .query_row(
                "SELECT id, org_id, revoked_at FROM enrollment_key WHERE token_hash = ?1",
                params![hash],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()
            .map_err(backend)?;

        let Some((id, org_id, revoked_at)) = found else {
            return Ok(None);
        };
        if revoked_at.is_some() {
            return Ok(None);
        }

        conn.execute(
            "UPDATE enrollment_key SET last_used_at = ?2 WHERE id = ?1",
            params![id, now_ms],
        )
        .map_err(backend)?;
        Ok(Some(org_id))
    }

    pub fn revoke_enrollment_key(&self, org_id: &str, id: &str, now_ms: i64) -> Result<()> {
        let changed = self
            .lock()?
            .execute(
                "UPDATE enrollment_key SET revoked_at = ?3 WHERE id = ?1 AND org_id = ?2 \
                 AND revoked_at IS NULL",
                params![id, org_id, now_ms],
            )
            .map_err(backend)?;
        if changed == 0 {
            return Err(StoreError::NotFound(format!("enrolment key {id}")));
        }
        Ok(())
    }

    /* ------------------------------------------------------ refresh tokens */

    pub fn insert_refresh_token(
        &self,
        account_id: &str,
        token: &str,
        label: &str,
        now_ms: i64,
        expires_at: i64,
    ) -> Result<String> {
        let id = new_id("ses");
        self.lock()?
            .execute(
                "INSERT INTO refresh_token (id, account_id, token_hash, label, created_at, \
                 expires_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    id,
                    account_id,
                    secret::hash_token(token),
                    label,
                    now_ms,
                    expires_at
                ],
            )
            .map_err(backend)?;
        Ok(id)
    }

    /// Exchange a refresh token for the account it belongs to, rotating it.
    ///
    /// Rotation on every use is what turns a stolen refresh token from a
    /// permanent foothold into a race: whichever party uses it second is
    /// refused, and the legitimate user's next refresh failing is a signal
    /// worth acting on.
    pub fn rotate_refresh_token(
        &self,
        token: &str,
        replacement: &str,
        now_ms: i64,
        expires_at: i64,
    ) -> Result<Option<String>> {
        let mut conn = self.lock()?;
        let tx = conn.transaction().map_err(backend)?;

        let found: Option<(String, String, i64, Option<i64>)> = tx
            .query_row(
                "SELECT id, account_id, expires_at, revoked_at FROM refresh_token \
                 WHERE token_hash = ?1",
                params![secret::hash_token(token)],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()
            .map_err(backend)?;

        let Some((id, account_id, token_expires_at, revoked_at)) = found else {
            return Ok(None);
        };
        if revoked_at.is_some() || now_ms >= token_expires_at {
            return Ok(None);
        }

        tx.execute(
            "UPDATE refresh_token SET token_hash = ?2, expires_at = ?3 WHERE id = ?1",
            params![id, secret::hash_token(replacement), expires_at],
        )
        .map_err(backend)?;
        tx.commit().map_err(backend)?;
        Ok(Some(account_id))
    }

    pub fn revoke_refresh_token(&self, token: &str, now_ms: i64) -> Result<()> {
        self.lock()?
            .execute(
                "UPDATE refresh_token SET revoked_at = ?2 WHERE token_hash = ?1",
                params![secret::hash_token(token), now_ms],
            )
            .map_err(backend)?;
        Ok(())
    }

    /// Sign every session for this account out. What "log out everywhere" and a
    /// password change both call.
    pub fn revoke_all_refresh_tokens(&self, account_id: &str, now_ms: i64) -> Result<usize> {
        self.lock()?
            .execute(
                "UPDATE refresh_token SET revoked_at = ?2 WHERE account_id = ?1 \
                 AND revoked_at IS NULL",
                params![account_id, now_ms],
            )
            .map_err(backend)
    }
}

impl CloudStore {
    /* -------------------------------------------------------------- oauth */

    pub fn insert_oauth_client(&self, client: &forge_mcp::oauth::RegisteredClient) -> Result<()> {
        self.lock()?
            .execute(
                "INSERT INTO oauth_client (id, name, redirect_uris, created_at) \
                 VALUES (?1, ?2, ?3, ?4)",
                params![
                    client.client_id,
                    client.client_name,
                    serde_json::to_string(&client.redirect_uris).unwrap_or_default(),
                    client.client_id_issued_at,
                ],
            )
            .map_err(backend)?;
        Ok(())
    }

    /// A client's registered redirect URIs, or `None` if the id is unknown.
    pub fn oauth_client(&self, client_id: &str) -> Result<Option<(String, Vec<String>)>> {
        Ok(self
            .lock()?
            .query_row(
                "SELECT name, redirect_uris FROM oauth_client WHERE id = ?1",
                params![client_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()
            .map_err(backend)?
            .map(|(name, raw)| {
                (
                    name,
                    serde_json::from_str::<Vec<String>>(&raw).unwrap_or_default(),
                )
            }))
    }

    pub fn insert_oauth_code(
        &self,
        code: &str,
        pending: &forge_mcp::oauth::PendingAuthorization,
        org_id: &str,
    ) -> Result<()> {
        self.lock()?
            .execute(
                "INSERT INTO oauth_code (code_hash, client_id, account_id, org_id, redirect_uri, \
                 code_challenge, code_challenge_method, resource, expires_at) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    secret::hash_token(code),
                    pending.client_id,
                    pending.account_id,
                    org_id,
                    pending.redirect_uri,
                    pending.code_challenge,
                    pending.code_challenge_method,
                    pending.resource,
                    pending.expires_at,
                ],
            )
            .map_err(backend)?;
        Ok(())
    }

    /// Redeem an authorization code. Single use: the row is deleted whether or
    /// not the exchange goes on to succeed, so a replay finds nothing even if
    /// the first attempt failed PKCE.
    pub fn take_oauth_code(
        &self,
        code: &str,
    ) -> Result<Option<(forge_mcp::oauth::PendingAuthorization, String)>> {
        let hash = secret::hash_token(code);
        let mut conn = self.lock()?;
        let tx = conn.transaction().map_err(backend)?;

        let found: Option<OauthCodeRow> = tx
            .query_row(
                "SELECT client_id, account_id, org_id, redirect_uri, code_challenge, \
                 code_challenge_method, resource, expires_at FROM oauth_code WHERE code_hash = ?1",
                params![hash],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                        row.get(6)?,
                        row.get(7)?,
                    ))
                },
            )
            .optional()
            .map_err(backend)?;

        tx.execute("DELETE FROM oauth_code WHERE code_hash = ?1", params![hash])
            .map_err(backend)?;
        tx.commit().map_err(backend)?;

        Ok(found.map(
            |(
                client_id,
                account_id,
                org_id,
                redirect_uri,
                challenge,
                method,
                resource,
                expires,
            )| {
                (
                    forge_mcp::oauth::PendingAuthorization {
                        client_id,
                        redirect_uri,
                        code_challenge: challenge,
                        code_challenge_method: method,
                        state: None,
                        account_id,
                        expires_at: expires,
                        resource,
                    },
                    org_id,
                )
            },
        ))
    }

    pub fn insert_oauth_grant(
        &self,
        token: &str,
        client_id: &str,
        client_name: &str,
        account_id: &str,
        org_id: &str,
        now_ms: i64,
    ) -> Result<()> {
        self.lock()?
            .execute(
                "INSERT INTO oauth_grant (token_hash, client_id, client_name, account_id, \
                 org_id, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    secret::hash_token(token),
                    client_id,
                    client_name,
                    account_id,
                    org_id,
                    now_ms
                ],
            )
            .map_err(backend)?;
        Ok(())
    }

    /// Resolve a refresh token to the grant behind it.
    pub fn oauth_grant(
        &self,
        token: &str,
        now_ms: i64,
    ) -> Result<Option<(String, String, String)>> {
        let hash = secret::hash_token(token);
        let conn = self.lock()?;
        let found: Option<(String, String, String, Option<i64>)> = conn
            .query_row(
                "SELECT client_id, account_id, org_id, revoked_at FROM oauth_grant \
                 WHERE token_hash = ?1",
                params![hash],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()
            .map_err(backend)?;

        let Some((client_id, account_id, org_id, revoked_at)) = found else {
            return Ok(None);
        };
        if revoked_at.is_some() {
            return Ok(None);
        }
        conn.execute(
            "UPDATE oauth_grant SET last_used_at = ?2 WHERE token_hash = ?1",
            params![hash, now_ms],
        )
        .map_err(backend)?;
        Ok(Some((client_id, account_id, org_id)))
    }

    /// The connectors this account has authorised.
    pub fn oauth_grants(&self, account_id: &str) -> Result<Vec<ConnectorGrant>> {
        let conn = self.lock()?;
        let mut statement = conn
            .prepare(
                "SELECT client_id, client_name, created_at, last_used_at FROM oauth_grant \
                 WHERE account_id = ?1 AND revoked_at IS NULL ORDER BY created_at DESC",
            )
            .map_err(backend)?;
        let rows = statement
            .query_map(params![account_id], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
            })
            .map_err(backend)?;
        rows.collect::<rusqlite::Result<Vec<_>>>().map_err(backend)
    }

    /// Disconnect a connector. Every grant this account holds for the client.
    pub fn revoke_oauth_grants(
        &self,
        account_id: &str,
        client_id: &str,
        now_ms: i64,
    ) -> Result<usize> {
        self.lock()?
            .execute(
                "UPDATE oauth_grant SET revoked_at = ?3 WHERE account_id = ?1 AND client_id = ?2 \
                 AND revoked_at IS NULL",
                params![account_id, client_id, now_ms],
            )
            .map_err(backend)
    }

    /// Drop codes nobody redeemed.
    pub fn purge_oauth_codes(&self, now_ms: i64) -> Result<usize> {
        self.lock()?
            .execute(
                "DELETE FROM oauth_code WHERE expires_at < ?1",
                params![now_ms],
            )
            .map_err(backend)
    }
}

/// A syntactically valid Argon2id hash of a value nobody knows.
///
/// Used only to spend the same time on a missing account as on a present one.
const DECOY_HASH: &str = "$argon2id$v=19$m=19456,t=2,p=1$\
    c29tZXNhbHRzb21lc2FsdA$Xf0Y5tYqEMhY2hHkMHbz2sQVv7bkwYqQ5nZ0lFZ0Zzk";

const RUNNER_COLUMNS: &str = "id, org_id, name, public_key, pending_public_key, channel, \
     created_at, last_seen_at, version";

const DEVICE_COLUMNS: &str =
    "id, org_id, account_id, kind, name, public_key, created_at, last_seen_at";

fn read_account(row: &Row<'_>) -> rusqlite::Result<Account> {
    Ok(Account {
        id: row.get(0)?,
        email: row.get(1)?,
        display_name: row.get(2)?,
        created_at: row.get(3)?,
        last_seen_at: row.get(4)?,
    })
}

fn read_runner(row: &Row<'_>) -> rusqlite::Result<Runner> {
    Ok(Runner {
        id: row.get(0)?,
        org_id: row.get(1)?,
        name: row.get(2)?,
        public_key: row.get(3)?,
        pending_public_key: row.get(4)?,
        channel: row.get(5)?,
        created_at: row.get(6)?,
        last_seen_at: row.get(7)?,
        version: row.get(8)?,
    })
}

fn read_device(row: &Row<'_>) -> rusqlite::Result<Device> {
    Ok(Device {
        id: row.get(0)?,
        org_id: row.get(1)?,
        account_id: row.get(2)?,
        kind: row
            .get::<_, String>(3)?
            .parse()
            .unwrap_or(forge_proto::types::DeviceKind::Web),
        name: row.get(4)?,
        public_key: row.get(5)?,
        created_at: row.get(6)?,
        last_seen_at: row.get(7)?,
    })
}

fn read_subscription(row: &Row<'_>) -> rusqlite::Result<Subscription> {
    Ok(Subscription {
        org_id: row.get(0)?,
        plan: row.get::<_, String>(1)?.parse().unwrap_or(Plan::Free),
        status: row
            .get::<_, String>(2)?
            .parse()
            .unwrap_or(SubscriptionStatus::Active),
        customer_id: row.get(3)?,
        subscription_id: row.get(4)?,
        current_period_end: row.get(5)?,
        cancel_at_period_end: row.get::<_, i64>(6)? != 0,
        updated_at: row.get(7)?,
    })
}

fn migrate(conn: &Connection) -> Result<()> {
    let applied: i64 = conn
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .map_err(backend)?;

    for (index, sql) in MIGRATIONS.iter().enumerate() {
        let target = index as i64 + 1;
        if target <= applied {
            continue;
        }
        conn.execute_batch(&format!(
            "BEGIN;\n{sql}\nPRAGMA user_version = {target};\nCOMMIT;"
        ))
        .map_err(backend)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_785_369_600_000;

    fn store() -> CloudStore {
        CloudStore::open_in_memory().unwrap()
    }

    fn signed_up(store: &CloudStore) -> (Account, Org) {
        store
            .create_account(
                "Harsh@Example.com",
                "Harsh",
                &secret::hash_password("correct horse battery").unwrap(),
                "Harsh's Lab",
                NOW,
            )
            .unwrap()
    }

    #[test]
    fn a_fresh_database_is_at_the_latest_schema_version() {
        assert_eq!(store().schema_version().unwrap(), MIGRATIONS.len() as i64);
    }

    #[test]
    fn migrations_are_idempotent() {
        let store = store();
        let conn = store.lock().unwrap();
        migrate(&conn).unwrap();
        migrate(&conn).unwrap();
        let version: i64 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(version, MIGRATIONS.len() as i64);
    }

    #[test]
    fn signing_up_creates_an_org_an_owner_and_a_free_subscription() {
        // The invariant this whole design rests on: there is no such thing as
        // an account without a tenant.
        let store = store();
        let (account, org) = signed_up(&store);

        assert_eq!(
            store.role_in(&org.id, &account.id).unwrap(),
            Some(Role::Owner)
        );
        assert_eq!(store.subscription(&org.id).unwrap().plan, Plan::Free);
        assert_eq!(
            store.usage(&org.id).unwrap(),
            Usage {
                runners: 0,
                devices: 0,
                members: 1
            }
        );
    }

    #[test]
    fn the_same_email_in_a_different_case_is_the_same_account() {
        let store = store();
        signed_up(&store);
        let again = store.create_account("HARSH@EXAMPLE.COM", "Impostor", "hash", "Other Lab", NOW);
        assert!(matches!(again, Err(StoreError::Conflict(_))));
    }

    #[test]
    fn two_orgs_wanting_the_same_slug_both_get_one() {
        let store = store();
        store
            .create_account("a@example.com", "A", "h", "Acme", NOW)
            .unwrap();
        let (_, second) = store
            .create_account("b@example.com", "B", "h", "Acme", NOW)
            .unwrap();

        assert_eq!(second.slug, "acme-1");
    }

    #[test]
    fn authentication_accepts_the_right_password_and_nothing_else() {
        let store = store();
        let (account, _) = signed_up(&store);

        assert_eq!(
            store
                .authenticate("harsh@example.com", "correct horse battery")
                .unwrap()
                .map(|found| found.id),
            Some(account.id)
        );
        assert!(
            store
                .authenticate("harsh@example.com", "wrong")
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn an_unknown_email_is_indistinguishable_from_a_wrong_password() {
        // Both `None`, and both having spent an Argon2 verification. An
        // enumeration oracle here is how credential-stuffing lists are built.
        let store = store();
        signed_up(&store);
        assert!(
            store
                .authenticate("nobody@example.com", "correct horse battery")
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn a_non_member_has_no_role_in_an_org() {
        // The tenancy check every handler funnels through.
        let store = store();
        let (_, org) = signed_up(&store);
        let (outsider, _) = store
            .create_account("other@example.com", "Other", "h", "Other Lab", NOW)
            .unwrap();

        assert_eq!(store.role_in(&org.id, &outsider.id).unwrap(), None);
    }

    #[test]
    fn the_last_owner_cannot_be_removed() {
        let store = store();
        let (account, org) = signed_up(&store);
        assert!(matches!(
            store.remove_member(&org.id, &account.id),
            Err(StoreError::Conflict(_))
        ));

        // With a second owner, the first may leave.
        let (colleague, _) = store
            .create_account("c@example.com", "C", "h", "C Lab", NOW)
            .unwrap();
        store
            .add_member(&org.id, &colleague.id, Role::Owner, NOW)
            .unwrap();
        assert!(store.remove_member(&org.id, &account.id).is_ok());
    }

    #[test]
    fn a_runner_is_enrolled_once_and_counted() {
        let store = store();
        let (_, org) = signed_up(&store);
        let runner = Runner {
            id: new_id("run"),
            org_id: org.id.clone(),
            name: "mac-studio".into(),
            public_key: "pubkey-1".into(),
            pending_public_key: None,
            channel: forge_proto::channel_for("pubkey-1"),
            created_at: NOW,
            last_seen_at: NOW,
            version: "0.1.0".into(),
        };
        store.insert_runner(&runner).unwrap();

        assert_eq!(store.usage(&org.id).unwrap().runners, 1);
        assert_eq!(
            store.runner_by_key("pubkey-1").unwrap().unwrap().id,
            runner.id
        );
        // A second machine claiming the same identity is refused globally.
        assert!(matches!(
            store.insert_runner(&Runner {
                id: new_id("run"),
                ..runner
            }),
            Err(StoreError::Conflict(_))
        ));
    }

    #[test]
    fn a_changed_runner_key_waits_for_a_human() {
        let store = store();
        let (_, org) = signed_up(&store);
        let id = new_id("run");
        store
            .insert_runner(&Runner {
                id: id.clone(),
                org_id: org.id,
                name: "mac-studio".into(),
                public_key: "original".into(),
                pending_public_key: None,
                channel: forge_proto::channel_for("original"),
                created_at: NOW,
                last_seen_at: NOW,
                version: "0.1.0".into(),
            })
            .unwrap();

        store.set_pending_key(&id, Some("rotated")).unwrap();
        assert_eq!(
            store.runner(&id).unwrap().pending_public_key.as_deref(),
            Some("rotated")
        );
        // Until approved, the pinned key — and therefore the channel — is
        // unchanged. This is the whole point of pinning.
        assert_eq!(store.runner(&id).unwrap().public_key, "original");

        let approved = store.approve_pending_key(&id).unwrap();
        assert_eq!(approved.public_key, "rotated");
        assert_eq!(approved.channel, forge_proto::channel_for("rotated"));
        assert_eq!(approved.pending_public_key, None);
    }

    #[test]
    fn approving_a_key_change_that_is_not_pending_is_refused() {
        let store = store();
        let (_, org) = signed_up(&store);
        let id = new_id("run");
        store
            .insert_runner(&Runner {
                id: id.clone(),
                org_id: org.id,
                name: "m".into(),
                public_key: "k".into(),
                pending_public_key: None,
                channel: "c".into(),
                created_at: NOW,
                last_seen_at: NOW,
                version: "0".into(),
            })
            .unwrap();

        assert!(matches!(
            store.approve_pending_key(&id),
            Err(StoreError::Conflict(_))
        ));
    }

    #[test]
    fn an_enrollment_key_resolves_to_its_org_until_revoked() {
        let store = store();
        let (account, org) = signed_up(&store);
        let token = secret::new_enrollment_key();
        let key = EnrollmentKey {
            id: new_id("key"),
            org_id: org.id.clone(),
            name: "laptop".into(),
            prefix: secret::displayed_prefix(&token),
            created_at: NOW,
            created_by: account.id,
            last_used_at: None,
            revoked_at: None,
        };
        store
            .insert_enrollment_key(&key, &secret::hash_token(&token))
            .unwrap();

        assert_eq!(
            store.redeem_enrollment_key(&token, NOW).unwrap(),
            Some(org.id.clone())
        );
        assert_eq!(
            store.enrollment_keys(&org.id).unwrap()[0].last_used_at,
            Some(NOW)
        );

        store.revoke_enrollment_key(&org.id, &key.id, NOW).unwrap();
        assert_eq!(store.redeem_enrollment_key(&token, NOW).unwrap(), None);
    }

    #[test]
    fn an_invented_enrollment_key_resolves_to_nothing() {
        let store = store();
        signed_up(&store);
        assert_eq!(
            store
                .redeem_enrollment_key("frg_not-a-real-key", NOW)
                .unwrap(),
            None
        );
    }

    #[test]
    fn a_refresh_token_rotates_and_the_old_one_stops_working() {
        let store = store();
        let (account, _) = signed_up(&store);
        let first = secret::random_secret();
        store
            .insert_refresh_token(&account.id, &first, "Safari", NOW, NOW + 1_000_000)
            .unwrap();

        let second = secret::random_secret();
        assert_eq!(
            store
                .rotate_refresh_token(&first, &second, NOW, NOW + 1_000_000)
                .unwrap(),
            Some(account.id.clone())
        );
        // Replaying the used token is the signal that one of the two holders is
        // not the user.
        assert_eq!(
            store
                .rotate_refresh_token(&first, &secret::random_secret(), NOW, NOW + 1_000_000)
                .unwrap(),
            None
        );
        assert!(
            store
                .rotate_refresh_token(&second, &secret::random_secret(), NOW, NOW + 1_000_000)
                .unwrap()
                .is_some()
        );
    }

    #[test]
    fn an_expired_refresh_token_is_refused() {
        let store = store();
        let (account, _) = signed_up(&store);
        let token = secret::random_secret();
        store
            .insert_refresh_token(&account.id, &token, "Safari", NOW, NOW + 1_000)
            .unwrap();

        assert_eq!(
            store
                .rotate_refresh_token(&token, &secret::random_secret(), NOW + 1_000, NOW)
                .unwrap(),
            None
        );
    }

    #[test]
    fn signing_out_everywhere_revokes_every_session() {
        let store = store();
        let (account, _) = signed_up(&store);
        let tokens: Vec<String> = (0..3).map(|_| secret::random_secret()).collect();
        for token in &tokens {
            store
                .insert_refresh_token(&account.id, token, "device", NOW, NOW + 1_000_000)
                .unwrap();
        }

        assert_eq!(
            store.revoke_all_refresh_tokens(&account.id, NOW).unwrap(),
            3
        );
        for token in &tokens {
            assert_eq!(
                store
                    .rotate_refresh_token(token, &secret::random_secret(), NOW, NOW + 1)
                    .unwrap(),
                None
            );
        }
    }

    #[test]
    fn deleting_a_device_is_the_revocation() {
        let store = store();
        let (account, org) = signed_up(&store);
        let device = Device {
            id: new_id("dev"),
            org_id: org.id.clone(),
            account_id: account.id,
            kind: forge_proto::types::DeviceKind::Phone,
            name: "iPhone".into(),
            public_key: "device-key".into(),
            created_at: NOW,
            last_seen_at: NOW,
        };
        store.insert_device(&device).unwrap();
        assert_eq!(store.usage(&org.id).unwrap().devices, 1);

        store.delete_device(&device.id).unwrap();
        assert_eq!(store.usage(&org.id).unwrap().devices, 0);
        assert!(store.device_by_key("device-key").unwrap().is_none());
    }

    #[test]
    fn deleting_an_account_takes_its_devices_with_it() {
        // The `ON DELETE CASCADE` is only real if `foreign_keys` is on, which is
        // easy to lose in a refactor and silent when you do.
        let store = store();
        let (account, org) = signed_up(&store);
        store
            .insert_device(&Device {
                id: new_id("dev"),
                org_id: org.id.clone(),
                account_id: account.id.clone(),
                kind: forge_proto::types::DeviceKind::Phone,
                name: "iPhone".into(),
                public_key: "device-key".into(),
                created_at: NOW,
                last_seen_at: NOW,
            })
            .unwrap();

        store
            .lock()
            .unwrap()
            .execute("DELETE FROM account WHERE id = ?1", params![account.id])
            .unwrap();

        assert!(store.device_by_key("device-key").unwrap().is_none());
    }

    #[test]
    fn a_subscription_is_found_by_its_stripe_customer() {
        let store = store();
        let (_, org) = signed_up(&store);
        let mut subscription = store.subscription(&org.id).unwrap();
        subscription.customer_id = Some("cus_123".into());
        subscription.plan = Plan::Pro;
        store.save_subscription(&subscription).unwrap();

        assert_eq!(
            store.org_by_customer("cus_123").unwrap(),
            Some(org.id.clone())
        );
        assert_eq!(store.subscription(&org.id).unwrap().plan, Plan::Pro);
    }
}
