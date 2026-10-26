-- The token a session held before its last rotation, and when it rotated.
--
-- Rotation is single-use, so a refresh whose response never arrived (a tunnel
-- drop after the server committed) or a second tab still holding the old token
-- used to sign the person out. `rotate_refresh_token` accepts the previous
-- token for a short grace window after a rotation; these two columns are what
-- it checks. Both are NULL until a session first rotates.
ALTER TABLE refresh_token ADD COLUMN previous_hash TEXT;
ALTER TABLE refresh_token ADD COLUMN rotated_at INTEGER;
CREATE INDEX refresh_token_by_previous ON refresh_token(previous_hash);
