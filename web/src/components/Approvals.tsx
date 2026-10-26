/**
 * Command approvals, and the standing delegation that removes most of them.
 *
 * Every supervised command used to need a tap, which turned a long task into a
 * stream of identical "cargo test? yes" prompts. A session can now delegate its
 * low-risk (or low- and medium-risk) commands to the runner's policy. The
 * runner enforces the ceiling, not this file: a destructive command is never
 * cleared on its own, and only a phone or the web app may change the level.
 * These controls only ask for it, and show what the runner reports back.
 */

import { useRef, useState } from "react";
import {
  since,
  type ApprovalView,
  type AutoApprove,
  type Decision,
  type Risk,
  type SessionView,
  type Transport,
} from "@farhelm/client-core";
import { BudgetMeter } from "./charts";

/**
 * Named by what the classifier does, not by the enum. It rates every shell
 * command `medium` unless a destructive rule matches; `low` is only the
 * read-only tools (Read, Grep, Glob and similar). "Low risk" on a `cargo test`
 * card would make the low level look broken.
 */
const RISK_LABEL: Record<Risk, string> = {
  low: "Read-only",
  medium: "Command",
  destructive: "Destructive",
};

/** The level that would have cleared an approval of this risk, if any. */
function levelCovering(risk: Risk): Exclude<AutoApprove, "off"> | null {
  return risk === "low" ? "low" : risk === "medium" ? "medium" : null;
}

export const AUTO_APPROVE_LABEL: Record<AutoApprove, string> = {
  off: "Ask every time",
  low: "Auto-approve read-only tools",
  medium: "Auto-approve commands",
};

function message(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause);
}

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
  const [busy, setBusy] = useState<Decision | "delegate" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);
  const delegate = levelCovering(approval.risk);

  const decide = async (decision: Decision, thenDelegate: AutoApprove | null = null) => {
    if (inFlight.current) return;
    inFlight.current = true;
    setBusy(thenDelegate ? "delegate" : decision);
    setError(null);
    try {
      if (!transport) throw new Error("not connected");
      await transport.decide(approval.id, decision);
    } catch (cause) {
      inFlight.current = false;
      setError(message(cause));
      setBusy(null);
      return;
    }
    // Decided first, delegated second: raising the level first would let the
    // runner's sweep clear this very request, and the explicit decision would
    // then race it. If delegating fails, the approval still stands and the
    // card says exactly which half did not happen.
    if (thenDelegate) {
      try {
        await transport.setAutoApprove(approval.session_id, thenDelegate);
      } catch (cause) {
        setError(`Approved, but auto-approve was not turned on: ${message(cause)}`);
        setBusy(null);
        onDecided();
        return;
      }
    }
    onDecided();
  };

  return (
    <section className="approval" data-risk={approval.risk} aria-label="Approval request">
      <div className="approval-head">
        <span className="approval-title">
          {showRepo ? approval.repo_name : "Wants to run a command"}
        </span>
        <span className="risk-chip" data-risk={approval.risk}>{RISK_LABEL[approval.risk]}</span>
        <span className="spacer" />
        <span className="muted approval-when">{since(approval.requested_at)}</span>
      </div>
      <div className="tile-note">{approval.tool}</div>
      <code>{approval.payload}</code>

      {/* The moment of approval is the moment of spend, so the bar lives here. */}
      <BudgetMeter budget={approval.budget} compact />

      {!delegate ? (
        <p className="notice">
          <span aria-hidden="true">■</span>
          <span>
            Destructive command. It always needs a person: auto-approve never
            clears it, and neither does the watch.
          </span>
        </p>
      ) : null}

      {error ? <p className="notice" role="alert">{error}</p> : null}

      <div className="approval-actions">
        <button
          className="btn btn-approve"
          disabled={busy !== null}
          onClick={() => void decide("approved")}
        >
          {busy === "approved" ? "Approving…" : "Approve"}
        </button>
        <button
          className="btn btn-deny"
          disabled={busy !== null}
          onClick={() => void decide("denied")}
        >
          {busy === "denied" ? "Denying…" : "Deny"}
        </button>
        {delegate ? (
          <button
            className="btn btn-quiet approval-delegate"
            disabled={busy !== null}
            onClick={() => void decide("approved", delegate)}
          >
            {busy === "delegate"
              ? "Approving…"
              : delegate === "low"
                ? "Approve and auto-approve read-only tools"
                : "Approve and stop asking for commands like this"}
          </button>
        ) : null}
      </div>
    </section>
  );
}

/* ------------------------------------------------------- access level picker */

/**
 * The session's approval level, as a native select.
 *
 * Shows the level the runner last reported. While a change is in flight the
 * new choice is shown with "Saving…" beside it; if the runner refuses, the
 * select returns to the reported level and the reason is shown. No optimistic
 * success: a delegation the user believes is on but is not is the failure
 * mode this control exists to prevent.
 */
export function AutoApproveControl({
  session,
  transport,
  onChanged,
  compact = false,
}: {
  session: Pick<SessionView, "id" | "auto_approve" | "is_live">;
  transport: Transport | null;
  onChanged: (session: SessionView) => void;
  compact?: boolean;
}) {
  // What the runner answered last, until the next session snapshot catches up.
  // A new snapshot (or a different session) replaces it, so a change made on
  // another device is never masked by this one's memory.
  // A runner that predates auto-approve sends no level; it asks every time.
  const level = session.auto_approve ?? "off";
  const [basis, setBasis] = useState({ id: session.id, level });
  const [answered, setAnswered] = useState<AutoApprove | null>(null);
  const [pending, setPending] = useState<AutoApprove | null>(null);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);
  const current = useRef(session.id);
  current.current = session.id;

  if (basis.id !== session.id || basis.level !== level) {
    setBasis({ id: session.id, level });
    setAnswered(null);
  }
  const reported = answered ?? level;

  const change = async (level: AutoApprove) => {
    if (inFlight.current || level === reported) return;
    const asked = session.id;
    inFlight.current = true;
    setPending(level);
    setError(null);
    try {
      if (!transport) throw new Error("not connected");
      const next = await transport.setAutoApprove(asked, level);
      if (current.current !== asked) return;
      setAnswered(next.auto_approve);
      onChanged(next);
    } catch (cause) {
      if (current.current === asked) setError(message(cause));
    } finally {
      inFlight.current = false;
      setPending(null);
    }
  };

  const id = `auto-approve-${session.id}`;
  return (
    <div className="auto-approve" data-compact={compact ? "yes" : undefined} data-level={pending ?? reported}>
      <label htmlFor={id} className="auto-approve-label">Approvals</label>
      <select
        id={id}
        className="auto-approve-select"
        value={pending ?? reported}
        disabled={pending !== null || !session.is_live || !transport}
        onChange={(event) => void change(event.target.value as AutoApprove)}
        aria-describedby={`${id}-note`}
      >
        {(Object.keys(AUTO_APPROVE_LABEL) as AutoApprove[]).map((level) => (
          <option key={level} value={level}>{AUTO_APPROVE_LABEL[level]}</option>
        ))}
      </select>
      <span id={`${id}-note`} className="auto-approve-note" role="status">
        {pending !== null
          ? "Saving…"
          : error
            ? `Not changed: ${error}`
            : "Destructive commands always ask."}
      </span>
    </div>
  );
}
