/**
 * Starting an agent.
 *
 * The gap this fills was the biggest one in the product: every screen could
 * *supervise* a session, and nothing could *start* one. The empty state used to
 * say "start one on the runner" — which means open a terminal, which is the
 * thing this exists to avoid.
 *
 * # Two decisions the picker makes for you
 *
 * **It shows agents that are not installed, greyed out, rather than hiding
 * them.** "Aider is not in the list" and "Aider is not installed" look identical
 * when the list is filtered, and only one of them has a fix.
 *
 * **It says which agents are supervised by a heuristic.** Claude Code's hook
 * bridge blocks the agent until you answer; the others are supervised by reading
 * their terminal output, which can miss a prompt it does not recognise. Someone
 * choosing between them deserves to know that before the session starts, not
 * after one slips past.
 */

import { useEffect, useState } from "react";
import type { AgentView, FleetView, Transport } from "@relayforge/client-core";

/** Remembered between visits — nobody wants to retype an absolute path. */
const RECENT_KEY = "forge-recent-repos";

function recentRepos(): string[] {
  try {
    const raw = JSON.parse(localStorage.getItem(RECENT_KEY) ?? "[]") as unknown;
    return Array.isArray(raw) ? raw.filter((x): x is string => typeof x === "string") : [];
  } catch {
    return [];
  }
}

function rememberRepo(path: string) {
  const next = [path, ...recentRepos().filter((p) => p !== path)].slice(0, 8);
  localStorage.setItem(RECENT_KEY, JSON.stringify(next));
}

export function NewSession({
  transport,
  fleet,
  onStarted,
  onCancel,
}: {
  transport: Transport | null;
  fleet: FleetView | null;
  onStarted: (sessionId: string) => void;
  onCancel: () => void;
}) {
  const [agents, setAgents] = useState<AgentView[] | null>(null);
  const [agent, setAgent] = useState<string | null>(null);
  const [repo, setRepo] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!transport?.supportsSessionControl) return;
    void transport
      .agents()
      .then((list) => {
        setAgents(list);
        // Default to something that will actually start.
        setAgent(
          (current) =>
            current ?? list.find((a) => a.installed && a.supervised)?.id ?? null,
        );
      })
      .catch((cause: unknown) =>
        setError(cause instanceof Error ? cause.message : String(cause)),
      );
  }, [transport]);

  // Repos the runner already knows about, so the common case is one tap.
  const known = [
    ...new Set([
      ...recentRepos(),
      ...(fleet?.sessions.map((session) => session.repo_name) ?? []),
    ]),
  ];

  if (!transport?.supportsSessionControl) {
    return (
      <section className="card" aria-label="Start a session">
        <div className="chart-title">Start a session</div>
        <p className="tile-note">
          Only from the machine the agent will run on. A paired device supervises
          work that already exists — starting an agent picks a directory on
          somebody's computer and runs a process in it, which is a different kind
          of permission from clearing an approval.
        </p>
        <div className="approval-actions">
          <button className="btn" onClick={onCancel}>
            Close
          </button>
        </div>
      </section>
    );
  }

  const submit = async () => {
    const path = repo.trim();
    if (!path || !agent) return;
    setBusy(true);
    setError(null);
    try {
      const session = await transport.startSession(path, agent);
      rememberRepo(path);
      onStarted(session.id);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  };

  const chosen = agents?.find((a) => a.id === agent);

  return (
    <section className="card" aria-label="Start a session">
      <div className="chart-title">Start a session</div>

      <label className="tile-label" htmlFor="new-session-repo">
        Repository
      </label>
      <input
        id="new-session-repo"
        className="pair-input"
        value={repo}
        onChange={(event) => setRepo(event.target.value)}
        placeholder="/Users/you/code/payments-api"
        list="forge-known-repos"
        spellCheck={false}
        autoCapitalize="none"
        autoCorrect="off"
      />
      <datalist id="forge-known-repos">
        {known.map((path) => (
          <option key={path} value={path} />
        ))}
      </datalist>
      <p className="tile-note">
        An absolute path on this machine. The agent starts there.
      </p>

      <div className="tile-label" style={{ marginTop: "0.75rem" }}>
        Agent
      </div>
      {agents === null ? (
        <p className="tile-note">Looking at what is installed…</p>
      ) : (
        <div className="agent-list">
          {agents.map((candidate) => (
            <button
              key={candidate.id}
              type="button"
              className="agent-option"
              aria-pressed={agent === candidate.id}
              data-selected={agent === candidate.id}
              disabled={!candidate.installed}
              onClick={() => setAgent(candidate.id)}
            >
              <span className="agent-name">
                {candidate.name}
                {!candidate.installed ? (
                  <span className="muted"> · not installed</span>
                ) : !candidate.supervised ? (
                  <span className="muted"> · nothing is gated</span>
                ) : !candidate.verified ? (
                  <span className="muted"> · prompts unverified</span>
                ) : null}
              </span>
              <span className="agent-note">
                {candidate.installed
                  ? candidate.note
                  : `\`${candidate.binary}\` is not on this machine's PATH`}
              </span>
            </button>
          ))}
        </div>
      )}

      {/* Said before the session starts, not after a prompt slips past. */}
      {chosen && chosen.approvals === "prompt" ? (
        <p className="notice">
          <span aria-hidden="true">■</span>
          <span>
            Approvals for {chosen.name} are read from its terminal output. A
            prompt it does not recognise means a session that waits, never one
            that proceeds unwatched — but it has not been checked against the
            real binary.
          </span>
        </p>
      ) : null}
      {chosen && !chosen.supervised ? (
        <p className="notice">
          <span aria-hidden="true">■</span>
          <span>Nothing is gated in a plain shell. You are the one typing.</span>
        </p>
      ) : null}

      {error ? <p className="notice error-text">{error}</p> : null}

      <div className="approval-actions">
        <button className="btn" onClick={onCancel} disabled={busy}>
          Cancel
        </button>
        <button
          className="btn btn-approve"
          onClick={() => void submit()}
          disabled={busy || !repo.trim() || !agent}
        >
          {busy ? "Starting…" : "Start"}
        </button>
      </div>
    </section>
  );
}
