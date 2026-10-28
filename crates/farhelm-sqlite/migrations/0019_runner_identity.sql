-- Which machine row this database's runner is.
--
-- The id used to be re-derived from the hostname on every start. macOS hands
-- out a network-dependent hostname (`name.attlocal.net` on one network,
-- `name.local` on another), so a reboot could turn the same Mac into a new,
-- empty machine and hide every repository registered to it. Recorded once, the
-- identity no longer follows the network. One row at most.
CREATE TABLE runner_identity (
  slot        INTEGER PRIMARY KEY CHECK (slot = 1),
  machine_id  TEXT NOT NULL REFERENCES machine(id),
  recorded_at INTEGER NOT NULL
);
