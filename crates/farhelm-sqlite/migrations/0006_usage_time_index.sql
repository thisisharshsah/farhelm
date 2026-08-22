-- The fleet's cost strip sums spend across every session over the last 24
-- hours. `ix_usage_session_time` is (session_id, created_at), which serves a
-- per-session lookup and cannot serve a fleet-wide one: a query filtering only
-- on created_at scans the table.
--
-- Additive. No data moves, and an older binary reading this database is
-- unaffected by an index it does not know about.
CREATE INDEX IF NOT EXISTS ix_usage_time ON usage_event(created_at);
