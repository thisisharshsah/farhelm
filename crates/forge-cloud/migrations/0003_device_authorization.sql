-- Letting a machine ask to join a workspace, instead of being told a secret.
--
-- The old way round was: a human opens the web app, mints an enrolment key,
-- and copies `frg_…` onto the machine by hand. That works, and it means a
-- long-lived bearer credential travels through a clipboard, a shell history, a
-- terminal scrollback and quite often a chat message — and it cannot be done at
-- all over SSH on a box whose browser is somebody else's laptop.
--
-- Here the machine starts the exchange. It generates a device code it keeps,
-- gets back a short user code a person can read off a console, and waits. The
-- human approves that code once, signed in, wherever they already are. Only
-- then is an enrolment key minted, and it is handed to whoever presents the
-- device code — which never left the machine that made it.
--
-- Two halves, deliberately asymmetric:
--
--   device_code  256 bits, never displayed, never typed, hashed here. This is
--                what actually authenticates the collection.
--   user_code    eight legible characters, shown to a human. Short enough to
--                transcribe, which is only safe because holding it grants
--                nothing on its own.

CREATE TABLE device_authorization (
  -- Like `oauth_code`, the secret half is never stored: a leaked database must
  -- not let anyone collect a credential that somebody else's approval created.
  device_code_hash TEXT PRIMARY KEY,

  -- Stored normalised (upper case, no dash) so the lookup a human triggers is
  -- one indexed query rather than a search across the ways they might type it.
  user_code        TEXT NOT NULL UNIQUE,

  -- What the machine calls itself, shown on the approval screen. This is the
  -- only thing the human has to go on, so it is captured at request time and
  -- never rewritten afterwards.
  name             TEXT NOT NULL,
  version          TEXT NOT NULL,

  -- pending | approved | denied. A denial is kept rather than deleted so the
  -- machine polling gets told "no" and stops, instead of timing out and
  -- retrying into a wall.
  status           TEXT NOT NULL DEFAULT 'pending',

  -- Null until somebody approves: an unapproved request belongs to no
  -- workspace, which is what stops a request being redeemed by a passer-by.
  org_id           TEXT REFERENCES org(id) ON DELETE CASCADE,
  approved_by      TEXT REFERENCES account(id) ON DELETE SET NULL,

  -- The minted enrolment key, in plaintext, from approval until the machine
  -- collects it — and cleared in the same statement that hands it over.
  --
  -- Every device-authorization flow has this moment: a credential exists that
  -- its owner has not yet fetched, so something must hold it. What bounds the
  -- exposure is that it is single-use, that it lives at most until
  -- `expires_at`, and that reading it requires the device code. The row is the
  -- narrowest place to put it; the alternative — minting the key at request
  -- time — would leave a usable credential sitting there before any human had
  -- agreed to anything.
  enrollment_key   TEXT,

  created_at       INTEGER NOT NULL,
  -- Approval and collection must both happen inside this window. Short, because
  -- a code nobody typed is a code somebody may yet type.
  expires_at       INTEGER NOT NULL
);

CREATE INDEX device_authorization_by_expiry ON device_authorization(expires_at);
