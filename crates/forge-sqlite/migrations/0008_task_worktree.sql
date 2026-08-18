-- A task's work moved out of this database and into git.
--
-- `staged_json` held the whole staging overlay: both sides of every file the
-- agent touched, so the change set could be rendered and applied after a
-- restart. That is why a task had a size limit measured in megabytes, and why
-- the agent could not run its own tests — the edits existed only here.
--
-- A task now works on its own branch in its own checkout, so what has to
-- survive a restart is four strings saying where that is. The column is renamed
-- rather than reused under its old name, because a column called `staged_json`
-- holding a worktree descriptor is the kind of thing that reads correctly for
-- about a year.
--
-- Rows written before this point carried an overlay that nothing can apply any
-- more: the code that understood that shape is gone. Their descriptors are
-- cleared rather than left to be parsed into a confusing failure at approval
-- time. The diff stays, so a task already reviewed still renders, and its status
-- still says what was decided — what it loses is the ability to be approved,
-- which it had already lost the moment the overlay stopped being understood.

ALTER TABLE agent_task RENAME COLUMN staged_json TO worktree_json;

UPDATE agent_task SET worktree_json = '' WHERE worktree_json <> '';
