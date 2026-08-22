-- The control plane's schema.
--
-- Everything countable hangs off `org`, including in the single-user case: an
-- account gets an organisation at sign-up, so there is no "personal" code path
-- that has to be retrofitted into a tenant one later. That is the single
-- decision that makes this multi-user without a rewrite.

CREATE TABLE account (
  id                TEXT PRIMARY KEY,
  -- As typed, for display.
  email             TEXT NOT NULL,
  -- Lowercased and trimmed. Login matches on this; the UNIQUE is what stops two
  -- accounts differing only in case.
  email_normalized  TEXT NOT NULL UNIQUE,
  password_hash     TEXT NOT NULL,
  display_name      TEXT NOT NULL,
  created_at        INTEGER NOT NULL,
  last_seen_at      INTEGER NOT NULL
);

CREATE TABLE org (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  slug        TEXT NOT NULL UNIQUE,
  created_at  INTEGER NOT NULL
);

CREATE TABLE membership (
  org_id      TEXT NOT NULL REFERENCES org(id) ON DELETE CASCADE,
  account_id  TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  role        TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  PRIMARY KEY (org_id, account_id)
);

CREATE INDEX membership_by_account ON membership(account_id);

CREATE TABLE subscription (
  org_id                TEXT PRIMARY KEY REFERENCES org(id) ON DELETE CASCADE,
  plan                  TEXT NOT NULL,
  status                TEXT NOT NULL,
  customer_id           TEXT,
  subscription_id       TEXT,
  current_period_end    INTEGER,
  cancel_at_period_end  INTEGER NOT NULL DEFAULT 0,
  updated_at            INTEGER NOT NULL
);

-- The webhook arrives knowing a Stripe customer, not an organisation. This index
-- is how it finds its way back, and the UNIQUE is what stops two organisations
-- claiming one customer and fighting over the plan.
CREATE UNIQUE INDEX subscription_by_customer
  ON subscription(customer_id) WHERE customer_id IS NOT NULL;

CREATE TABLE runner (
  id                  TEXT PRIMARY KEY,
  org_id              TEXT NOT NULL REFERENCES org(id) ON DELETE CASCADE,
  name                TEXT NOT NULL,
  -- Pinned at first enrolment. See `model::Runner`.
  public_key          TEXT NOT NULL,
  -- A key that does not match the pinned one, awaiting a human.
  pending_public_key  TEXT,
  channel             TEXT NOT NULL,
  created_at          INTEGER NOT NULL,
  last_seen_at        INTEGER NOT NULL,
  version             TEXT NOT NULL
);

-- One machine, one identity, globally. Two organisations sharing a public key
-- would share a relay channel, which is how one tenant ends up watching
-- another's ciphertext.
CREATE UNIQUE INDEX runner_by_key ON runner(public_key);
CREATE INDEX runner_by_org ON runner(org_id);

CREATE TABLE device (
  id            TEXT PRIMARY KEY,
  org_id        TEXT NOT NULL REFERENCES org(id) ON DELETE CASCADE,
  account_id    TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  kind          TEXT NOT NULL,
  name          TEXT NOT NULL,
  public_key    TEXT NOT NULL,
  created_at    INTEGER NOT NULL,
  last_seen_at  INTEGER NOT NULL
);

CREATE UNIQUE INDEX device_by_key ON device(public_key);
CREATE INDEX device_by_org ON device(org_id);
CREATE INDEX device_by_account ON device(account_id);

CREATE TABLE enrollment_key (
  id            TEXT PRIMARY KEY,
  org_id        TEXT NOT NULL REFERENCES org(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  -- The first few characters of the plaintext, so a list can name a key.
  prefix        TEXT NOT NULL,
  -- SHA-256 of the plaintext. The plaintext is shown once and never stored.
  token_hash    TEXT NOT NULL UNIQUE,
  created_at    INTEGER NOT NULL,
  created_by    TEXT NOT NULL REFERENCES account(id),
  last_used_at  INTEGER,
  revoked_at    INTEGER
);

CREATE INDEX enrollment_key_by_org ON enrollment_key(org_id);

CREATE TABLE refresh_token (
  id          TEXT PRIMARY KEY,
  account_id  TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  token_hash  TEXT NOT NULL UNIQUE,
  -- What the user sees in "signed-in devices": a browser name, or a phone model.
  label       TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  expires_at  INTEGER NOT NULL,
  revoked_at  INTEGER
);

CREATE INDEX refresh_token_by_account ON refresh_token(account_id);
