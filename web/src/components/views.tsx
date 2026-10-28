import { useEffect, useLayoutEffect, useRef, useState } from "react";
import {
  FOLD_AFTER,
  agentName,
  clockOf,
  displayText,
  pct,
  since,
  turnsOf,
  usd,
  type DashboardView,
  type OutputLine,
  type PlanStepView,
  type SessionDetail as SessionDetailData,
  type Transport,
} from "@farhelm/client-core";
import { BudgetMeter, Sparkline, StatTile, TierBars, ValuesTable } from "./charts";
import { Icon } from "./Icon";
import { ApprovalCard, AutoApproveControl } from "./Approvals";
import { SESSION_STATUS, StatusPill } from "./status";

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

export function OutputTail({ lines, agent }: { lines: OutputLine[]; agent: string }) {
  const ref = useRef<HTMLDivElement | null>(null);
  const pinned = useRef(true);
  const [opened, setOpened] = useState<Set<number>>(() => new Set());

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
      {turnsOf(lines).map((turn) => {
        const key = turn.lines[0]?.seq ?? 0;
        const folded = turn.kind === "agent" && turn.lines.length > FOLD_AFTER && !opened.has(key);
        const shown = folded ? turn.lines.slice(-FOLD_AFTER) : turn.lines;
        const hidden = turn.lines.length - shown.length;

        return (
          <div className="turn" data-kind={turn.kind} key={key}>
            {/* Both sides are named, and both carry a time. Only your own turns
                were labelled before, which left the reader inferring where one
                agent response ended and the next began from spacing alone,
                and left a transcript with no times in it at all, though every
                line has carried one on the wire the whole time. */}
            <div className="turn-head">
              <span className="turn-who">{turn.kind === "instruction" ? "You" : agent}</span>
              <span className="turn-when">{clockOf(turn.lines[0]?.at_ms)}</span>
            </div>

            {folded ? (
              <button
                className="turn-more"
                onClick={() => setOpened((open) => new Set(open).add(key))}
              >
                Show {hidden} earlier {hidden === 1 ? "line" : "lines"}
              </button>
            ) : null}

            <div className="turn-body">
              {shown.map((line) => (
                <div className="output-line" key={line.seq}>
                  {displayText(line.text) || " "}
                </div>
              ))}
            </div>
          </div>
        );
      })}
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
      // Never sent automatically: a dictation error into a live agent is
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
  const look = SESSION_STATUS[session.status];

  const send = async () => {
    if (!text.trim() || sending) return;
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
    <div className="thread-layout">
      <section className="thread" aria-label="Session">
        <header className="thread-head">
          <div className="thread-head-title">
            <span className="thread-crumb">{session.machine_name}</span>
            <h1>{session.repo_name}</h1>
          </div>
          <StatusPill look={look} />
          <span className="spacer" />
          {transport?.supportsDashboard ? (
            <button className="btn btn-quiet btn-small" onClick={onCost}>Cost</button>
          ) : null}
          {/* Stopping is loopback-only for the same reason starting is: it ends
              a process on somebody's machine. Hidden rather than disabled over
              the relay; a button that always refuses teaches nothing. */}
          {transport?.supportsSessionControl && session.is_live ? (
            <button
              className="btn btn-quiet btn-small"
              onClick={() => {
                void transport
                  .stopSession(session.id)
                  .then(onStopped)
                  .catch((cause: unknown) =>
                    setNotice(cause instanceof Error ? cause.message : String(cause)),
                  );
              }}
            >
              <Icon name="stop" size={14} /> Stop
            </button>
          ) : null}
        </header>

        <div className="thread-scroll">
          {session.pending_approval ? (
            <ApprovalCard
              approval={session.pending_approval}
              onDecided={onChanged}
              transport={transport}
            />
          ) : null}

          {/* What the agent is doing, where you are already looking. A session
              that is working and silent is indistinguishable from one that has
              died unless something says so. */}
          {session.is_live ? (
            <p className="working" aria-live="polite">
              <span className="working-dot" aria-hidden="true" />
              {session.status === "awaiting_approval" ? "Waiting on you" : "Working"}
            </p>
          ) : null}

          <div className="thread-transcript">
            <OutputTail lines={session.output} agent={agentName(session.agent)} />
          </div>
        </div>

        <div className="composer-dock">
          <div className="composer-box">
            <textarea
              value={text}
              rows={2}
              placeholder="Tell the agent…"
              onChange={(event) => setText(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter" && !event.shiftKey) {
                  event.preventDefault();
                  void send();
                }
              }}
              aria-label="Instruction for the agent"
              disabled={!session.is_live}
            />
            <div className="composer-bar">
              <AutoApproveControl
                key={session.id}
                session={session}
                transport={transport}
                onChanged={onChanged}
                compact
              />
              <span className="spacer" />
              {dictation.supported ? (
                <button
                  className="icon-button"
                  onClick={dictation.start}
                  aria-label="Dictate an instruction"
                  aria-pressed={dictation.listening}
                >
                  <Icon name="mic" />
                </button>
              ) : null}
              <button
                className="send-button"
                onClick={() => void send()}
                disabled={sending || !text.trim() || !session.is_live}
                aria-label="Send instruction"
              >
                <Icon name="send" size={16} />
              </button>
            </div>
          </div>
          {notice ? <p className="notice" role="alert">{notice}</p> : null}
        </div>
      </section>

      <aside className="thread-rail" aria-label="Session details">
        <section className="rail-panel">
          <h2>Budget</h2>
          <BudgetMeter budget={session.budget} />
        </section>

        {session.steps.length > 0 ? (
          <section className="rail-panel">
            <h2>
              Plan
              <span className="muted">
                {session.plan ? ` ${session.plan.settled}/${session.plan.total}` : ""}
              </span>
            </h2>
            <PlanList steps={session.steps} />
            <div className="row-actions">
              <button className="btn btn-small" onClick={() => void control(paused ? "resume" : "pause")}>
                {paused ? "Resume" : "Pause"}
              </button>
              <button className="btn btn-small" onClick={() => void control("skip")}>
                Skip step
              </button>
            </div>
          </section>
        ) : null}

        <section className="rail-panel">
          <h2>Session</h2>
          <dl className="facts">
            <dt>Agent</dt><dd>{agentName(session.agent)}</dd>
            <dt>Machine</dt><dd>{session.machine_name}</dd>
            <dt>Started</dt><dd>{since(session.started_at)}</dd>
            {session.ended_at ? (<><dt>Ended</dt><dd>{since(session.ended_at)}</dd></>) : null}
          </dl>
        </section>
      </aside>
    </div>
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
              ? "No cap"
              : usd(Math.max(0, dashboard.budget.cap_usd - dashboard.budget.spent_usd))
          }
          note={dashboard.budget.cap_usd == null ? "nothing to run out of" : "of session cap"}
        />
      </div>

      <section className="card">
        <div className="chart-title">
          <span>Spend per hour</span>
          <span className="spacer" />
          <button
            className="btn btn-quiet btn-small"
            onClick={() => setShowTable((on) => !on)}
          >
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

/** Scroll to the top whenever the route changes: a phone habit, not a nicety. */
export function useScrollReset(key: string) {
  useEffect(() => {
    window.scrollTo(0, 0);
  }, [key]);
}
