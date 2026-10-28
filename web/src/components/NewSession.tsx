/**
 * Starting an agent.
 *
 * The gap this fills was the biggest one in the product: every screen could
 * *supervise* a session, and nothing could *start* one. The empty state used to
 * say "start one on the runner", which means open a terminal, which is the
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

import { getMigratingSync } from "@farhelm/client-core";
import { useEffect, useMemo, useState } from "react";
import type { AgentView, FleetView, RepositoryView, Transport } from "@farhelm/client-core";

/** Remembered between visits: nobody wants to retype an absolute path. */
const RECENT_KEY = "farhelm-recent-repos";
const LEGACY_RECENT_KEY = "forge-recent-repos";

function recentRepos(): string[] {
  try {
    const raw = JSON.parse(getMigratingSync(RECENT_KEY, LEGACY_RECENT_KEY) ?? "[]") as unknown;
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
  const [registered, setRegistered] = useState<RepositoryView[]>([]);
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

  useEffect(() => {
    if (!transport?.supportsSessionControl || typeof transport.repositories !== "function") return;
    let cancelled = false;
    transport
      .repositories()
      .then((list) => { if (!cancelled) setRegistered(list); })
      // Recent paths still offer the common case; typing a path always works.
      .catch(() => {});
    return () => { cancelled = true; };
  }, [transport]);

  // Repos the runner already knows about, so the common case is one tap. Only
  // paths: a session reports its repository's name, which the runner cannot
  // start in.
  const known = useMemo(() => {
    const byPath = new Map<string, string>();
    for (const item of registered) byPath.set(item.path, item.name);
    for (const path of recentRepos()) if (!byPath.has(path)) byPath.set(path, path.split("/").filter(Boolean).pop() ?? path);
    return Array.from(byPath, ([path, name]) => ({ path, name }));
  }, [registered]);

  if (!transport?.supportsSessionControl) {
    return (
      <section className="card" aria-label="Start a session">
        <div className="chart-title">Start a session</div>
        <p className="tile-note">
          Only from the machine the agent will run on. A paired device supervises
          work that already exists; starting an agent picks a directory on
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
  const installed = agents?.filter((a) => a.installed) ?? [];
  const missing = agents?.filter((a) => !a.installed) ?? [];

  const option = (candidate: AgentView) => (
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
  );

  return (
    <div className="page page-narrow">
      <header className="page-head">
        <div>
          <h1 className="page-title">Start a session</h1>
          <p className="page-sub">An agent works in a repository on this machine and asks before anything risky.</p>
        </div>
      </header>

      <form
        className="panel new-session"
        aria-label="Start a session"
        onSubmit={(event) => { event.preventDefault(); void submit(); }}
      >
        <label className="field-label" htmlFor="new-session-repo">
          Repository
        </label>
        {known.length > 0 ? (
          <div className="repo-choices" role="group" aria-label="Known repositories">
            {known.map((item) => (
              <button
                key={item.path}
                type="button"
                className="repo-choice"
                aria-pressed={repo === item.path}
                onClick={() => setRepo(item.path)}
                title={item.path}
              >
                {item.name}
              </button>
            ))}
          </div>
        ) : null}
        <input
          id="new-session-repo"
          className="pair-input"
          value={repo}
          onChange={(event) => setRepo(event.target.value)}
          placeholder="/Users/you/code/payments-api"
          spellCheck={false}
          autoCapitalize="none"
          autoCorrect="off"
        />
        <p className="field-hint">An absolute path on this machine. The agent starts there.</p>

        <div className="field-label">Agent</div>
        {agents === null ? (
          <p className="field-hint">Looking at what is installed…</p>
        ) : (
          <>
            <div className="agent-list">{installed.map(option)}</div>
            {missing.length > 0 ? (
              <details className="agent-missing">
                <summary>
                  {missing.length} more not installed: {missing.map((a) => a.name).join(", ")}
                </summary>
                <div className="agent-list">{missing.map(option)}</div>
              </details>
            ) : null}
          </>
        )}

        {/* Said before the session starts, not after a prompt slips past. */}
        {chosen && chosen.approvals === "prompt" ? (
          <p className="notice">
            <span aria-hidden="true">■</span>
            <span>
              Approvals for {chosen.name} are read from its terminal output. A
              prompt it does not recognise means a session that waits, never one
              that proceeds unwatched, but it has not been checked against the
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

        {error ? <p className="notice error-text" role="alert">{error}</p> : null}

        <div className="form-actions">
          <button type="button" className="btn" onClick={onCancel} disabled={busy}>
            Cancel
          </button>
          <button
            type="submit"
            className="btn btn-primary"
            disabled={busy || !repo.trim() || !agent}
          >
            {busy ? "Starting…" : "Start session"}
          </button>
        </div>
      </form>
    </div>
  );
}
