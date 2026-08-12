import { useEffect, useLayoutEffect, useRef, useState } from "react";
import {
  pct,
  since,
  statusLabel,
  statusToken,
  usd,
  type ApprovalView,
  type DashboardView,
  type Decision,
  type FleetView,
  type OutputLine,
  type PlanStepView,
  type SessionDetail as SessionDetailData,
  type SessionView,
  type Transport,
} from "@relayforge/client-core";
import { BudgetMeter, Sparkline, StatTile, TierBars, ValuesTable } from "./charts";

/* ------------------------------------------------------------ approval card */

export function ApprovalCard({
  approval,
  onDecided,
  transport,
  showRepo = false,
}: {
  approval: ApprovalView;
  onDecided: () => void;
  transport: Transport | null;
  showRepo?: boolean;
}) {
  const [busy, setBusy] = useState<Decision | null>(null);
  const [error, setError] = useState<string | null>(null);

  const decide = async (decision: Decision) => {
    setBusy(decision);
    setError(null);
    try {
      if (!transport) throw new Error("not connected");
      await transport.decide(approval.id, decision);
      onDecided();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
      setBusy(null);
    }
  };

  return (
    <section className="approval" data-risk={approval.risk} aria-label="Approval request">
      <div className="session-head">
        <span className="session-name">
          {showRepo ? approval.repo_name : "Needs approval"}
        </span>
        <span className="session-machine">{since(approval.requested_at)}</span>
      </div>
      <div className="tile-note">wants to run {approval.tool}</div>
      <code>{approval.payload}</code>

      {/* The moment of approval is the moment of spend, so the bar lives here. */}
      <BudgetMeter budget={approval.budget} compact />

      {!approval.allows_watch_decision ? (
        <p className="notice">
          <span aria-hidden="true">■</span>
          <span>
            Destructive command — deliberate friction. This one cannot be cleared
            from the watch.
          </span>
        </p>
      ) : null}

      {error ? <p className="notice">{error}</p> : null}

      <div className="approval-actions">
        <button
          className="btn btn-approve"
          disabled={busy !== null}
          onClick={() => decide("approved")}
        >
          {busy === "approved" ? "Approving…" : "Approve"}
        </button>
        <button
          className="btn btn-deny"
          disabled={busy !== null}
          onClick={() => decide("denied")}
        >
          {busy === "denied" ? "Denying…" : "Deny"}
        </button>
      </div>
    </section>
  );
}

/* --------------------------------------------------------------- fleet view */

function SessionRow({
  session,
  onOpen,
}: {
  session: SessionView;
  onOpen: () => void;
}) {
  const plan = session.plan;
  return (
    <button className="session" onClick={onOpen}>
      <div className="session-head">
        <span
          className="dot"
          data-live={session.is_live}
          style={{ background: statusToken(session.status) }}
          aria-hidden="true"
        />
        <span className="session-name">{session.repo_name}</span>
        <span className="session-machine">{session.machine_name}</span>
      </div>

      <div className="session-line">
        <span>{statusLabel(session.status)}</span>
        {plan && plan.total > 0 ? (
          <>
            <span className="muted">·</span>
            <span>
              Step {plan.current_ordinal ?? plan.settled}/{plan.total}
              {plan.current_title ? ` · ${plan.current_title}` : ""}
            </span>
          </>
        ) : null}
        {!session.is_live && session.ended_at ? (
          <>
            <span className="muted">·</span>
            <span className="muted">{since(session.ended_at)}</span>
          </>
        ) : null}
      </div>

      <div style={{ marginTop: "0.5rem" }}>
        <BudgetMeter budget={session.budget} compact />
      </div>
    </button>
  );
}

export function FleetScreen({
  fleet,
  onOpen,
  onOpenTask,
  onChanged,
  onNewSession,
  transport,
}: {
  fleet: FleetView;
  onOpen: (id: string) => void;
  onOpenTask: (id: string) => void;
  onChanged: () => void;
  onNewSession: () => void;
  transport: Transport | null;
}) {
  return (
    <>
      {fleet.pending_approvals.map((approval) => (
        <ApprovalCard
          key={approval.id}
          approval={approval}
          onDecided={onChanged}
          transport={transport}
          showRepo
        />
      ))}

      {/* Below approvals, above sessions. An approval is holding a live process
          still; a change set is finished work waiting to be read. Both come
          before anything you have to go looking for. */}
      {fleet.tasks_awaiting_review.map((task) => (
        <button
          key={task.id}
          type="button"
          className="approval review-card"
          onClick={() => onOpenTask(task.id)}
        >
          <div className="session-head">
            <span className="session-name">{task.repo_name}</span>
            <span className="spacer" />
            <span className="status-chip" data-token="warning">
              needs review
            </span>
          </div>
          <div className="task-row-prompt">{task.prompt}</div>
          <div className="session-line">
            <span>{task.change_summary}</span>
            <span>·</span>
            <span>{usd(task.cost_usd)}</span>
          </div>
          <span className="linkish">Review the diff →</span>
        </button>
      ))}

      {fleet.sessions.length === 0 ? (
        // The old copy here said "start one on the runner" — i.e. go open a
        // terminal, which is the thing this app exists to avoid.
        <div className="empty-state">
          <p className="empty-title">Nothing running yet.</p>
          {transport?.supportsSessionControl ? (
            <>
              <p className="tile-note">
                Point an agent at a repository and it will wait for you before it
                does anything.
              </p>
              <button className="btn btn-approve" onClick={onNewSession}>
                Start a session
              </button>
            </>
          ) : (
            <p className="tile-note">
              Sessions start on the runner's own machine. Once one is running,
              it shows up here and you can supervise it from anywhere.
            </p>
          )}
        </div>
      ) : (
        <>
          <div className="session-grid">
            {fleet.sessions.map((session) => (
              <SessionRow
                key={session.id}
                session={session}
                onOpen={() => onOpen(session.id)}
              />
            ))}
          </div>
          {transport?.supportsSessionControl ? (
            <button className="btn btn-quiet full" onClick={onNewSession}>
              + Start another session
            </button>
          ) : null}
        </>
      )}
    </>
  );
}

export function CostStrip({ fleet }: { fleet: FleetView }) {
  return (
    <footer className="cost-strip">
      <span>
        Today <b>{usd(fleet.today_usd)}</b>
      </span>
      <span>
        Cache hit <b>{pct(fleet.cache_hit_ratio)}</b>
      </span>
    </footer>
  );
}

/* ------------------------------------------------------------- session view */

const STEP_MARK: Record<PlanStepView["status"], string> = {
  todo: "○",
  active: "▶",
  done: "✓",
  skipped: "–",
  failed: "✕",
};

function PlanList({ steps }: { steps: PlanStepView[] }) {
  if (steps.length === 0) return null;
  return (
    <ol className="steps">
      {steps.map((step) => (
        <li className="step" key={step.ordinal} data-status={step.status}>
          <span className="step-mark" aria-hidden="true">
            {STEP_MARK[step.status]}
          </span>
          <span className="step-title">
            {step.ordinal}. {step.title}
          </span>
          <span className="sr-only">{step.status}</span>
        </li>
      ))}
    </ol>
  );
}

function OutputTail({ lines }: { lines: OutputLine[] }) {
  const ref = useRef<HTMLDivElement | null>(null);
  const pinned = useRef(true);

  useLayoutEffect(() => {
    const node = ref.current;
    if (!node || !pinned.current) return;
    node.scrollTop = node.scrollHeight;
  }, [lines]);

  const onScroll = () => {
    const node = ref.current;
    if (!node) return;
    // Only auto-scroll when the reader is already at the bottom; yanking the
    // view while they scroll back through a failure is hostile.
    pinned.current = node.scrollHeight - node.scrollTop - node.clientHeight < 32;
  };

  if (lines.length === 0) {
    return <p className="empty">No output yet.</p>;
  }

  return (
    <div className="output" ref={ref} onScroll={onScroll} aria-live="polite">
      {lines.map((line) => (
        <div
          className="output-line"
          key={line.seq}
          data-kind={line.text.startsWith("›") ? "instruction" : "agent"}
        >
          {line.text || " "}
        </div>
      ))}
    </div>
  );
}

/** Dictation fills the box; sending stays a deliberate tap. */
function useDictation(onText: (text: string) => void) {
  const [listening, setListening] = useState(false);
  const supported =
    typeof window !== "undefined" &&
    ("SpeechRecognition" in window || "webkitSpeechRecognition" in window);

  const start = () => {
    const Recognition =
      (window as unknown as Record<string, unknown>).SpeechRecognition ??
      (window as unknown as Record<string, unknown>).webkitSpeechRecognition;
    if (typeof Recognition !== "function") return;

    const recognition = new (Recognition as new () => {
      lang: string;
      interimResults: boolean;
      start(): void;
      onresult: ((event: { results: ArrayLike<ArrayLike<{ transcript: string }>> }) => void) | null;
      onend: (() => void) | null;
    })();

    recognition.lang = navigator.language;
    recognition.interimResults = false;
    recognition.onresult = (event) => {
      const first = event.results[0]?.[0]?.transcript;
      // Never sent automatically — a dictation error into a live agent is
      // destructive, so the text lands in the box for review.
      if (first) onText(first);
    };
    recognition.onend = () => setListening(false);
    recognition.start();
    setListening(true);
  };

  return { supported, listening, start };
}

export function SessionScreen({
  session,
  onChanged,
  onCost,
  onStopped,
  transport,
}: {
  session: SessionDetailData;
  onChanged: () => void;
  onCost: () => void;
  onStopped: () => void;
  transport: Transport | null;
}) {
  const [text, setText] = useState("");
  const [sending, setSending] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const dictation = useDictation((spoken) =>
    setText((current) => (current ? `${current} ${spoken}` : spoken)),
  );

  const send = async () => {
    if (!text.trim()) return;
    setSending(true);
    try {
      if (!transport) throw new Error("not connected");
      await transport.instruct(session.id, text);
      setText("");
      onChanged();
    } catch (cause) {
      setNotice(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setSending(false);
    }
  };

  const control = async (action: "pause" | "resume" | "skip") => {
    setNotice(null);
    try {
      if (!transport) throw new Error("not connected");
      await transport.planControl(session.id, action);
      onChanged();
    } catch (cause) {
      setNotice(cause instanceof Error ? cause.message : String(cause));
    }
  };

  const paused = session.steps.every((step) => step.status !== "active");

  return (
    <>
      {session.pending_approval ? (
        <ApprovalCard
          approval={session.pending_approval}
          onDecided={onChanged}
          transport={transport}
        />
      ) : null}

      {session.steps.length > 0 ? (
        <section className="card">
          <div className="chart-title">
            <span>Plan</span>
            <span className="spacer" />
            <span className="muted">
              {session.plan
                ? `${session.plan.settled}/${session.plan.total} settled`
                : ""}
            </span>
          </div>
          <PlanList steps={session.steps} />
          <div className="row-actions">
            <button className="btn" onClick={() => control(paused ? "resume" : "pause")}>
              {paused ? "Resume" : "Pause"}
            </button>
            <button className="btn" onClick={() => control("skip")}>
              Skip step
            </button>
          </div>
        </section>
      ) : null}

      <section className="card">
        <div className="chart-title">
          <span>Live output</span>
          <span className="spacer" />
          {/* Stopping is loopback-only for the same reason starting is: it ends
              a process on somebody's machine. Hidden rather than disabled over
              the relay — a button that always refuses teaches nothing. */}
          {transport?.supportsSessionControl && session.is_live ? (
            <button
              className="linkish"
              onClick={() => {
                void transport
                  .stopSession(session.id)
                  .then(onStopped)
                  .catch((cause: unknown) =>
                    setNotice(
                      cause instanceof Error ? cause.message : String(cause),
                    ),
                  );
              }}
            >
              Stop
            </button>
          ) : null}
          {/* Available over the relay too, now that the dashboard has its own
              snapshot type. Hidden only when there is no transport at all —
              which is the loading state, not a capability the user lacks. */}
          {transport?.supportsDashboard ? (
            <button className="linkish" onClick={onCost}>
              Cost →
            </button>
          ) : null}
        </div>
        <OutputTail lines={session.output} />

        <div className="composer">
          <input
            value={text}
            placeholder="Tell the agent…"
            onChange={(event) => setText(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") void send();
            }}
            aria-label="Instruction for the agent"
          />
          {dictation.supported ? (
            <button
              className="icon-button"
              onClick={dictation.start}
              aria-label="Dictate an instruction"
              aria-pressed={dictation.listening}
            >
              {dictation.listening ? "…" : "🎤"}
            </button>
          ) : null}
          <button
            className="icon-button"
            onClick={() => void send()}
            disabled={sending || !text.trim()}
            aria-label="Send instruction"
          >
            ↑
          </button>
        </div>
        {notice ? <p className="notice">{notice}</p> : null}
      </section>

      <section className="card">
        <div className="chart-title">Budget</div>
        <BudgetMeter budget={session.budget} />
      </section>
    </>
  );
}

/* ----------------------------------------------------------- cost dashboard */

export function DashboardScreen({ dashboard }: { dashboard: DashboardView }) {
  const [showTable, setShowTable] = useState(false);

  return (
    <>
      <div className="tiles">
        <StatTile
          label="Spend"
          value={usd(dashboard.total_usd)}
          note={`${dashboard.calls} calls`}
        />
        <StatTile
          label="Cache hit"
          value={pct(dashboard.cache_hit_ratio)}
          note="target ≥ 70%"
        />
        <StatTile
          label="Saved by pre-gate"
          value={String(dashboard.avoided_calls)}
          note="calls never made"
        />
        <StatTile
          label="Budget left"
          value={
            dashboard.budget.cap_usd == null
              ? "—"
              : usd(Math.max(0, dashboard.budget.cap_usd - dashboard.budget.spent_usd))
          }
          note={dashboard.budget.cap_usd == null ? "no cap" : "of session cap"}
        />
      </div>

      <section className="card">
        <div className="chart-title">
          <span>Spend per hour</span>
          <span className="spacer" />
          <button className="linkish" onClick={() => setShowTable((on) => !on)}>
            {showTable ? "Show charts" : "Show values"}
          </button>
        </div>
        {showTable ? (
          <ValuesTable
            caption="Spend per hour"
            columns={["Hour", "Spend"]}
            rows={dashboard.spend_series.map((bucket) => [
              new Date(bucket.at_ms).toLocaleString([], {
                month: "short",
                day: "numeric",
                hour: "2-digit",
              }),
              usd(bucket.usd),
            ])}
          />
        ) : (
          <Sparkline series={dashboard.spend_series} />
        )}
      </section>

      <section className="card">
        <div className="chart-title">Spend by tier</div>
        {showTable ? (
          <ValuesTable
            caption="Spend by tier"
            columns={["Tier", "Spend"]}
            rows={dashboard.by_tier.map((slice) => [
              slice.tier,
              `${usd(slice.usd)} (${pct(slice.share)})`,
            ])}
          />
        ) : (
          <TierBars slices={dashboard.by_tier} />
        )}
      </section>

      <section className="card">
        <div className="chart-title">Session budget</div>
        <BudgetMeter budget={dashboard.budget} />
      </section>
    </>
  );
}

/** Scroll to the top whenever the route changes — a phone habit, not a nicety. */
export function useScrollReset(key: string) {
  useEffect(() => {
    window.scrollTo(0, 0);
  }, [key]);
}
