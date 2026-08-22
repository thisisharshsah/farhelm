-- Split "which model ran" from "how it was dispatched".
--
-- `usage_event.tier` carried `batch`, which is not a model tier at all: a
-- deferred call lost which model ran it, and with it the tier split in the
-- dashboard for exactly the work most worth splitting. The router had known
-- both all along — it overwrote the tier it had just computed.
--
-- Additive and backfilled in one transaction with the version bump, so a crash
-- leaves the database on 6 rather than half-migrated.

ALTER TABLE usage_event ADD COLUMN dispatch TEXT NOT NULL DEFAULT 'live';

-- Rows that said `batch` were batched. Their real model tier is not recoverable
-- — the model name is in the row, but the router's configuration has moved on
-- since — so `tier` keeps saying `batch` for history and `dispatch` becomes
-- true going forward.
UPDATE usage_event SET dispatch = 'batch' WHERE tier = 'batch';

-- The routing decision belongs with the queued item: a batch can come back a
-- day after it was queued, by which time the router may pick a different model.
-- 'small' for anything already in flight — deferrable work is overwhelmingly
-- triage and titles — and nothing queued before this upgrade survives longer
-- than the provider's 24-hour window.
ALTER TABLE batch_item ADD COLUMN tier TEXT NOT NULL DEFAULT 'small';
