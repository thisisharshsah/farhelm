-- C10: the frontier model's read of a finished diff.
--
-- The loop drafts on the large tier; one call at the end judges the patch alone.
-- That verdict is worth keeping next to the change set it judged, so a review
-- card can lead with it and so a later question — "did anything warn us about
-- this?" — has an answer that is not "read the logs".
--
-- Nullable throughout: verification can be switched off, a task with no change
-- set has nothing to judge, and a task that failed before producing one never
-- gets here. A null verdict means "not judged", which is different from, and
-- must never be confused with, "judged fine".

ALTER TABLE agent_task ADD COLUMN verify_grade TEXT;   -- pass | concerns | fail
ALTER TABLE agent_task ADD COLUMN verify_notes TEXT;
-- Which model judged it. "Opus 5 says concerns" reads differently from "Haiku
-- says concerns", and the router's configuration can change between tasks.
ALTER TABLE agent_task ADD COLUMN verify_model TEXT;
