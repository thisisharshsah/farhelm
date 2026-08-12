-- The OAuth authorization server that backs the MCP connectors.
--
-- Separate from `refresh_token`, which is the first-party app's session. These
-- grants belong to a *third party* — Claude — acting with a user's authority,
-- and they are revoked independently: signing out of the web app should not
-- disconnect a connector, and disconnecting a connector should not sign the
-- user out of their own phone.

CREATE TABLE oauth_client (
  id             TEXT PRIMARY KEY,
  name           TEXT NOT NULL,
  -- JSON array. A code is only ever sent to a URI registered here, which is
  -- what stops a stolen client id being used to redirect codes elsewhere.
  redirect_uris  TEXT NOT NULL,
  created_at     INTEGER NOT NULL
);

CREATE TABLE oauth_code (
  -- The code itself is never stored; a leaked database must not yield usable
  -- codes even inside their one-minute window.
  code_hash             TEXT PRIMARY KEY,
  client_id             TEXT NOT NULL REFERENCES oauth_client(id) ON DELETE CASCADE,
  account_id            TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  org_id                TEXT NOT NULL REFERENCES org(id) ON DELETE CASCADE,
  redirect_uri          TEXT NOT NULL,
  code_challenge        TEXT NOT NULL,
  code_challenge_method TEXT NOT NULL,
  resource              TEXT,
  expires_at            INTEGER NOT NULL
);

CREATE TABLE oauth_grant (
  token_hash  TEXT PRIMARY KEY,
  client_id   TEXT NOT NULL REFERENCES oauth_client(id) ON DELETE CASCADE,
  account_id  TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  org_id      TEXT NOT NULL REFERENCES org(id) ON DELETE CASCADE,
  -- What the user saw named on the consent screen, so the connector list can
  -- say which client a grant belongs to without joining at read time.
  client_name TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  last_used_at INTEGER,
  revoked_at  INTEGER
);

CREATE INDEX oauth_grant_by_account ON oauth_grant(account_id);
