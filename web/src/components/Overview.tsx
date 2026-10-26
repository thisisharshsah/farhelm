/**
 * Home: everything the agents are doing, on one screen.
 *
 * Laid out like a work-management dashboard. A row of headline numbers, then
 * the queue of things only a person can clear, then the state of the work.
 * Forms follow the job each number does: single values are stat tiles, the
 * task mix is one horizontal stacked bar (part-to-whole) with every count
 * written in its legend, and the live sessions are a table because each row
 * carries five facts.
 *
 * Every chart here has its values in text next to it, so nothing is reachable
 * only by hovering and nothing depends on telling two hues apart.
 */

import { useMemo } from "react";
import {
  agentName,
  pct,
  since,
  usd,
  type FleetView,
  type TaskView,
  type Transport,
} from "@farhelm/client-core";
import { ApprovalCard, AUTO_APPROVE_LABEL } from "./Approvals";
import { BudgetMeter, StatTile } from "./charts";
import { Icon } from "./Icon";
import { NewTaskComposer } from "./TaskThread";
import { SESSION_STATUS, StatusPill, TASK_GROUPS, TASK_STATUS } from "./status";

export function Overview({
  fleet,
  tasks,
  transport,
  machineName,
  onNavigate,
  onChanged,
}: {
  fleet: FleetView;
  tasks: TaskView[] | null;
  transport: Transport | null;
  machineName: string | null;
  onNavigate: (to: string) => void;
  onChanged: () => void;
}) {
  const allTasks = useMemo(() => tasks ?? [], [tasks]);
  const live = fleet.sessions.filter((session) => session.is_live);
  const reviews = fleet.tasks_awaiting_review;
  const needsYou = fleet.pending_approvals.length + reviews.length;
  const working = allTasks.filter((task) => task.status === "running").length;
  const applied = allTasks.filter((task) => task.status === "applied").length;

  const mix = useMemo(
    () => TASK_GROUPS.map((group) => ({
      ...group,
      count: allTasks.filter((task) => group.statuses.includes(task.status)).length,
    })),
    [allTasks],
  );
  const recent = useMemo(
    () => [...allTasks].sort((a, b) => b.updated_at - a.updated_at).slice(0, 6),
    [allTasks],
  );

  const empty = allTasks.length === 0 && fleet.sessions.length === 0;

  return (
    <div className="page">
      <header className="page-head">
        <div>
          <h1 className="page-title">Home</h1>
          <p className="page-sub">{machineName ?? "This runner"}</p>
        </div>
        <span className="spacer" />
        {transport?.supportsTaskControl ? (
          <button className="btn btn-primary" onClick={() => onNavigate("/t/new")}>
            <Icon name="plus" size={14} /> New task
          </button>
        ) : null}
      </header>

      {empty && transport?.supportsTaskControl ? (
        <NewTaskComposer
          transport={transport}
          tasks={tasks}
          onStarted={(id) => onNavigate(`/t/${id}`)}
          variant="hero"
        />
      ) : null}

      <div className="kpi-row">
        <StatTile
          label="Needs you"
          value={String(needsYou)}
          note={`${fleet.pending_approvals.length} approval${fleet.pending_approvals.length === 1 ? "" : "s"} · ${reviews.length} review${reviews.length === 1 ? "" : "s"}`}
        />
        <StatTile
          label="Agents working"
          value={String(live.length)}
          note={`${working} task${working === 1 ? "" : "s"} drafting`}
        />
        <StatTile
          label="Spend today"
          value={usd(fleet.today_usd)}
          note={`cache hit ${pct(fleet.cache_hit_ratio)}`}
        />
        <StatTile
          label="Applied"
          value={String(applied)}
          note={`of ${allTasks.length} task${allTasks.length === 1 ? "" : "s"}`}
        />
      </div>

      <div className="overview-grid">
        <section className="panel panel-wide" aria-labelledby="needs-you">
          <div className="panel-head">
            <h2 id="needs-you">Needs you</h2>
            <span className="count-pill">{needsYou}</span>
          </div>
          {needsYou === 0 ? (
            <p className="panel-empty">Nothing is waiting on you. Approvals and finished diffs land here.</p>
          ) : (
            <div className="needs-you">
              {fleet.pending_approvals.map((approval) => (
                <ApprovalCard
                  key={approval.id}
                  approval={approval}
                  transport={transport}
                  onDecided={onChanged}
                  showRepo
                />
              ))}
              {reviews.map((task) => (
                <div className="review-item" key={task.id}>
                  <StatusPill look={TASK_STATUS[task.status]} size="sm" />
                  <button type="button" className="row-open" onClick={() => onNavigate(`/t/${task.id}`)}>
                    {task.prompt}
                  </button>
                  <span className="muted review-item-meta">
                    {task.repo_name} · {task.change_summary} · {usd(task.cost_usd)}
                  </span>
                </div>
              ))}
            </div>
          )}
        </section>

        <section className="panel" aria-labelledby="task-mix">
          <div className="panel-head">
            <h2 id="task-mix">Tasks by status</h2>
            <span className="spacer" />
            <button type="button" className="btn btn-quiet btn-small" onClick={() => onNavigate("/t")}>
              Open board
            </button>
          </div>
          {allTasks.length === 0 ? (
            <p className="panel-empty">No tasks yet.</p>
          ) : (
            <>
              <div className="mix-bar" role="img" aria-label={mix.filter((m) => m.count > 0).map((m) => `${m.title} ${m.count}`).join(", ")}>
                {mix.filter((m) => m.count > 0).map((m) => (
                  <span
                    key={m.id}
                    className="mix-segment"
                    data-tone={m.tone}
                    style={{ flexGrow: m.count }}
                    title={`${m.title}: ${m.count}`}
                  />
                ))}
              </div>
              <ul className="mix-legend">
                {mix.map((m) => (
                  <li key={m.id}>
                    <span className="status-dot" data-tone={m.tone} aria-hidden="true" />
                    <span>{m.title}</span>
                    <span className="spacer" />
                    <b>{m.count}</b>
                  </li>
                ))}
              </ul>
            </>
          )}
        </section>

        <section className="panel panel-wide" aria-labelledby="live-sessions">
          <div className="panel-head">
            <h2 id="live-sessions">Sessions</h2>
            <span className="count-pill">{live.length} live</span>
            <span className="spacer" />
            {transport?.supportsSessionControl ? (
              <button type="button" className="btn btn-quiet btn-small" onClick={() => onNavigate("/new")}>
                <Icon name="plus" size={14} /> Start a session
              </button>
            ) : null}
          </div>
          {fleet.sessions.length === 0 ? (
            <p className="panel-empty">
              No sessions yet. A supervised agent session shows up here, and waits
              for you before it runs anything risky.
            </p>
          ) : (
            <div className="board-table-wrap">
              <table className="board-table compact">
                <thead>
                  <tr>
                    <th scope="col" className="col-task">Repository</th>
                    <th scope="col" className="col-status">Status</th>
                    <th scope="col">Plan</th>
                    <th scope="col">Budget</th>
                    <th scope="col">Approvals</th>
                    <th scope="col">Started</th>
                  </tr>
                </thead>
                <tbody>
                  {fleet.sessions.map((session) => (
                    <tr key={session.id}>
                      <td className="col-task">
                        <button type="button" className="row-open" onClick={() => onNavigate(`/s/${session.id}`)}>
                          {session.repo_name}
                        </button>
                        <span className="cell-sub">{agentName(session.agent)} · {session.machine_name}</span>
                      </td>
                      <td className="col-status"><StatusPill look={SESSION_STATUS[session.status]} /></td>
                      <td>
                        {session.plan && session.plan.total > 0 ? (
                          <span className="plan-progress">
                            <span className="progress-track" aria-hidden="true">
                              <span style={{ width: `${(session.plan.settled / session.plan.total) * 100}%` }} />
                            </span>
                            {session.plan.settled}/{session.plan.total}
                          </span>
                        ) : <span className="muted">—</span>}
                      </td>
                      <td className="col-budget"><BudgetMeter budget={session.budget} compact /></td>
                      <td className="muted">{AUTO_APPROVE_LABEL[session.auto_approve ?? "off"]}</td>
                      <td className="muted">{since(session.started_at)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>

        <section className="panel" aria-labelledby="recent-tasks">
          <div className="panel-head">
            <h2 id="recent-tasks">Recent tasks</h2>
          </div>
          {recent.length === 0 ? (
            <p className="panel-empty">Finished and running tasks appear here.</p>
          ) : (
            <ul className="recent-list">
              {recent.map((task) => (
                <li key={task.id}>
                  <StatusPill look={TASK_STATUS[task.status]} size="sm" />
                  <button type="button" className="row-open" onClick={() => onNavigate(`/t/${task.id}`)}>
                    {task.prompt}
                  </button>
                  <span className="muted">{since(task.updated_at)}</span>
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>
    </div>
  );
}
