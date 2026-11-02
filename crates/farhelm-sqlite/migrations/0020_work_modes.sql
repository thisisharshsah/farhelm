-- Work modes (ADR 0009): what a request asked the model for, and which model
-- it named. Recorded with the request so a reply and a task each say how they
-- were made. Older rows have neither; readers treat a missing task mode as
-- `agent`, the only mode a task could have had.
ALTER TABLE chat_turn ADD COLUMN mode TEXT;
ALTER TABLE chat_turn ADD COLUMN model TEXT;
ALTER TABLE chat_message ADD COLUMN mode TEXT;
ALTER TABLE agent_task ADD COLUMN mode TEXT;
ALTER TABLE agent_task ADD COLUMN model TEXT;
