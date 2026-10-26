/**
 * The task board: every agent task on this runner, grouped by state.
 *
 * Modelled on a work-management board rather than an inbox. Groups are
 * ordered by what needs a person first, each status is a filled cell with its
 * word in it, and each group closes with a summary row so the cost of a whole
 * state reads at a glance. The kanban layout shows the same groups as
 * columns; which one is shown is a per-browser convenience (see
 * `tasks-view.ts`) that never blocks the board when storage is unavailable.
 *
 * Rows are not clickable as a whole. The task title is a real button, so the
 * table stays a table for a screen reader and every row is reachable by Tab.
 */

import { useMemo, useState } from "react";
import { since, usd, type TaskView, type Transport } from "@farhelm/client-core";
import { Icon } from "./Icon";
import { readTaskView, saveTaskView, type TaskViewMode } from "./tasks-view";
import { StatusPill, TASK_GROUPS, TASK_STATUS } from "./status";

const GRADE_LABEL = { pass: "Pass", concerns: "Concerns", fail: "Fail" } as const;

function Changes({ task }: { task: TaskView }) {
  if (task.files_changed === 0) return <span className="muted">—</span>;
  return (
    <span className="changes" title={task.change_summary}>
      <span className="changes-files">{task.files_changed} file{task.files_changed === 1 ? "" : "s"}</span>
      <span className="diff-count-add">+{task.lines_added}</span>
      <span className="diff-count-remove">−{task.lines_removed}</span>
    </span>
  );
}

export function TaskBoard({
  tasks,
  onOpen,
  onNewTask,
  transport,
}: {
  tasks: TaskView[];
  onOpen: (id: string) => void;
  onNewTask: () => void;
  transport: Transport | null;
}) {
  const [viewMode, setViewMode] = useState<TaskViewMode>(readTaskView);
  const [search, setSearch] = useState("");
  const [selectedRepo, setSelectedRepo] = useState("all");
  const [collapsed, setCollapsed] = useState<Set<string>>(() => new Set());

  const repos = useMemo(() => {
    const byId = new Map<string, { id: string; name: string; path: string }>();
    for (const task of tasks) byId.set(task.repo_id, { id: task.repo_id, name: task.repo_name, path: task.repo_path });
    const values = Array.from(byId.values());
    return values
      .map((repo) => ({
        ...repo,
        // Two checkouts of the same project are different repositories; their
        // names alone would make the filter lie about which one you picked.
        label: values.some((other) => other.id !== repo.id && other.name === repo.name)
          ? `${repo.name} — ${repo.path}`
          : repo.name,
      }))
      .sort((a, b) => a.label.localeCompare(b.label));
  }, [tasks]);

  // A deleted repo or runner switch must not leave an invisible stale filter.
  const activeRepo = repos.some((repo) => repo.id === selectedRepo) ? selectedRepo : "all";

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return tasks.filter((task) => {
      if (activeRepo !== "all" && task.repo_id !== activeRepo) return false;
      if (!q) return true;
      return task.prompt.toLowerCase().includes(q)
        || task.repo_name.toLowerCase().includes(q)
        || task.summary.toLowerCase().includes(q);
    });
  }, [tasks, search, activeRepo]);

  const groups = useMemo(
    () => TASK_GROUPS.map((group) => ({
      ...group,
      tasks: filtered
        .filter((task) => group.statuses.includes(task.status))
        .sort((a, b) => b.updated_at - a.updated_at),
    })),
    [filtered],
  );

  const toggleView = (mode: TaskViewMode) => {
    setViewMode(mode);
    saveTaskView(mode);
  };

  const toggleGroup = (id: string) =>
    setCollapsed((current) => {
      const next = new Set(current);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  return (
    <div className="page">
      <header className="page-head">
        <div>
          <h1 className="page-title">Board</h1>
          <p className="page-sub">
            {tasks.length} task{tasks.length === 1 ? "" : "s"} on this runner
          </p>
        </div>
        <span className="spacer" />
        {transport?.supportsTaskControl ? (
          <button className="btn btn-primary" onClick={onNewTask}>
            <Icon name="plus" size={14} /> New task
          </button>
        ) : null}
      </header>

      <div className="board-toolbar">
        <div className="seg" role="group" aria-label="Layout">
          <button type="button" aria-pressed={viewMode === "list"} onClick={() => toggleView("list")}>
            <Icon name="list" size={14} /> Table
          </button>
          <button type="button" aria-pressed={viewMode === "board"} onClick={() => toggleView("board")}>
            <Icon name="board" size={14} /> Kanban
          </button>
        </div>
        <label className="board-search">
          <Icon name="search" size={14} />
          <span className="sr-only">Filter tasks</span>
          <input
            type="search"
            placeholder="Search tasks"
            value={search}
            onChange={(event) => setSearch(event.target.value)}
          />
        </label>
        {repos.length > 1 ? (
          <select
            className="board-select"
            value={activeRepo}
            onChange={(event) => setSelectedRepo(event.target.value)}
            aria-label="Filter by repository"
          >
            <option value="all">All repositories ({tasks.length})</option>
            {repos.map((repo) => <option key={repo.id} value={repo.id}>{repo.label}</option>)}
          </select>
        ) : null}
      </div>

      {tasks.length === 0 ? (
        <div className="empty-state">
          <p className="empty-title">No tasks yet.</p>
          {transport?.supportsTaskControl ? (
            <>
              <p className="tile-note">
                Describe a change and an agent works on it in a separate worktree,
                then hands you a diff. Nothing reaches your files until you approve it.
              </p>
              <button className="btn btn-primary" onClick={onNewTask}>New task</button>
            </>
          ) : (
            <p className="tile-note">
              Tasks start on the runner's own machine. Once one is running you can
              review its diff from anywhere.
            </p>
          )}
        </div>
      ) : filtered.length === 0 ? (
        <div className="empty-state">
          <p className="empty-title">No matching tasks.</p>
          <p className="tile-note">Nothing matches the search or repository filter.</p>
        </div>
      ) : viewMode === "board" ? (
        <div className="kanban-board">
          {groups.map((group) => (
            <section className="kanban-column" key={group.id} data-tone={group.tone} aria-label={group.title}>
              <h2 className="kanban-column-head">
                <span>{group.title}</span>
                <span className="count-pill">{group.tasks.length}</span>
              </h2>
              <div className="kanban-stack">
                {group.tasks.length === 0 ? <p className="kanban-empty">No tasks</p> : group.tasks.map((task) => (
                  <button
                    type="button"
                    key={task.id}
                    className="kanban-card"
                    onClick={() => onOpen(task.id)}
                  >
                    <span className="kanban-card-prompt">{task.prompt}</span>
                    <span className="kanban-card-meta">
                      <span className="kanban-card-repo" title={task.repo_path}>{task.repo_name}</span>
                      <Changes task={task} />
                    </span>
                    <span className="kanban-card-foot">
                      <span>{usd(task.cost_usd)}</span>
                      <span>{since(task.updated_at)}</span>
                    </span>
                  </button>
                ))}
              </div>
            </section>
          ))}
        </div>
      ) : (
        <div className="task-list board-table-wrap">
          <table className="board-table">
            <thead>
              <tr>
                <th scope="col" className="col-task">Task</th>
                <th scope="col">Repository</th>
                <th scope="col" className="col-status">Status</th>
                <th scope="col">Changes</th>
                <th scope="col">Second opinion</th>
                <th scope="col" className="num">Steps</th>
                <th scope="col" className="num">Cost</th>
                <th scope="col">Updated</th>
              </tr>
            </thead>
            {groups.filter((group) => group.tasks.length > 0).map((group) => {
              const open = !collapsed.has(group.id);
              const cost = group.tasks.reduce((sum, task) => sum + task.cost_usd, 0);
              return (
                <tbody key={group.id} data-tone={group.tone}>
                  <tr className="group-row">
                    <th scope="rowgroup" colSpan={8}>
                      <button
                        type="button"
                        className="group-toggle"
                        aria-expanded={open}
                        onClick={() => toggleGroup(group.id)}
                      >
                        <span className="group-chevron" aria-hidden="true">{open ? "▾" : "▸"}</span>
                        <span className="group-name">{group.title}</span>
                        <span className="muted">{group.tasks.length}</span>
                      </button>
                    </th>
                  </tr>
                  {open ? group.tasks.map((task) => (
                    <tr key={task.id} className="task-row-cells">
                      <td className="col-task">
                        <button type="button" className="row-open" onClick={() => onOpen(task.id)} title={task.prompt}>
                          {task.prompt}
                        </button>
                      </td>
                      <td className="muted" title={task.repo_path}>{task.repo_name}</td>
                      <td className="col-status"><StatusPill look={TASK_STATUS[task.status]} /></td>
                      <td><Changes task={task} /></td>
                      <td>
                        {task.verify_grade ? (
                          <span className="grade" data-grade={task.verify_grade}>{GRADE_LABEL[task.verify_grade]}</span>
                        ) : <span className="muted">Not judged</span>}
                      </td>
                      <td className="num">{task.steps}</td>
                      <td className="num">{usd(task.cost_usd)}</td>
                      <td className="muted">{since(task.updated_at)}</td>
                    </tr>
                  )) : null}
                  {open ? (
                    <tr className="summary-row">
                      <td colSpan={6} />
                      <td className="num">{usd(cost)}</td>
                      <td />
                    </tr>
                  ) : null}
                </tbody>
              );
            })}
          </table>
        </div>
      )}
    </div>
  );
}
