# 0012: Tasks on a board, runs as attempts

Status: accepted, 2026-11-02 (user direction: statuses Backlog, To do, In
progress, Review, Done; names Task and Run).

## Context

Until now a task existed only as an agent run (`agent_task`): nothing could
be planned without starting an agent, nothing could be moved by hand, and a
run started from a discussion did not know which discussion. The product
goal (AGENTS.md) is discussion, then task, then agent work, then review, then
the task updated, with an overview in the manner of monday.com.

## Decision

- A **task** is planned work on a project's board, with a title, a
  description the agent reads, a status (`backlog`, `todo`, `in_progress`,
  `review`, `done`), an optional repository and the discussion it came from.
  In code it is a *work item* (`work_item`), because `agent_task` took the
  name first; the app says Task.
- A **run** is one agent attempt on a task: an `agent_task` row carrying
  `work_item_id`. The app says Run where runs appear beside tasks. A task may
  have no run, one, or several (retries are new runs).
- A person moves a task with its status control. A run moves it too, from
  `farhelm_app::work_items::status_after`: starting puts it in progress, a
  proposed change set puts it in review, an applied one marks it done, and a
  rejected, failed, undone or no-change run sends it back to to do. The move
  follows the run's own row and is best-effort: a board one step behind is
  recoverable, an unrecorded run is not.
- A task made from a discussion keeps `conversation_id`, and the
  conversation shows its tasks with their status, so the result of the work
  is visible where it was asked for. Nothing is written into the transcript.
- Routes are direct HTTP under `/v1/projects/{id}/work-items`, scoped like
  the rest of the project workflow (project in the workspace, repositories on
  this machine); the relay has no task protocol yet.

## Consequences

- The Board page shows every project's tasks in one board above the runs
  on this runner (read project by project; a workspace-wide route is a later
  change), and run screens say Run.
- Comments, priority, assignees and due dates are not part of this change.
- Older `agent_task` rows have no task; they stay as plain runs.
