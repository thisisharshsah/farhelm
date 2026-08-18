/**
 * Approving a machine that asked to join.
 *
 * The other half of `forge-runner login`. A machine generates a secret it keeps
 * and shows its owner eight characters; this is where those eight characters
 * are turned into a decision.
 *
 * The screen is deliberately small and says one thing: **which machine**. That
 * is the only fact a person can actually check — everything else on the request
 * came from the machine itself and would be reassurance rather than evidence.
 */

import { useCallback, useEffect, useState } from "react";
import type { CloudClient, PendingDevice } from "@relayforge/client-core";
import { normaliseUserCode } from "@relayforge/client-core";

import { readableError } from "./Auth";

/** Render `BKPT4QW9` the way the terminal printed it. */
function pretty(code: string): string {
  const clean = normaliseUserCode(code);
  return clean.length === 8 ? `${clean.slice(0, 4)}-${clean.slice(4)}` : clean;
}

type Outcome =
  | { kind: "approved"; name: string }
  | { kind: "denied"; name: string };

export function Connect({
  cloud,
  initialCode,
  onDone,
}: {
  cloud: CloudClient;
  /** From `#/connect/BKPT-4QW9`, when the link carried one. */
  initialCode: string | null;
  onDone: () => void;
}) {
  const [code, setCode] = useState(initialCode ? pretty(initialCode) : "");
  const [pending, setPending] = useState<PendingDevice | null>(null);
  const [outcome, setOutcome] = useState<Outcome | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const look = useCallback(
    (raw: string) => {
      const clean = normaliseUserCode(raw);
      if (clean.length !== 8) {
        setError("A code is eight characters, like BKPT-4QW9.");
        return;
      }
      setBusy(true);
      setError(null);
      cloud
        .pendingDevice(clean)
        .then((found) => setPending(found))
        .catch((cause: unknown) => {
          setPending(null);
          setError(readableError(cause));
        })
        .finally(() => setBusy(false));
    },
    [cloud],
  );

  // A link from the runner carries the code, so the common path is no typing
  // at all: land here and read the machine's name.
  useEffect(() => {
    if (initialCode) look(initialCode);
  }, [initialCode, look]);

  const decide = (approve: boolean) => {
    if (!pending) return;
    setBusy(true);
    setError(null);
    const call = approve
      ? cloud.approveDevice(pending.user_code)
      : cloud.denyDevice(pending.user_code);
    call
      .then(() => {
        setOutcome({
          kind: approve ? "approved" : "denied",
          name: pending.name,
        });
        setPending(null);
      })
      .catch((cause: unknown) => setError(readableError(cause)))
      .finally(() => setBusy(false));
  };

  if (outcome) {
    return (
      <section className="card" aria-label="Machine connected">
        <h2 className="chart-title">
          {outcome.kind === "approved" ? "Connected" : "Refused"}
        </h2>
        {outcome.kind === "approved" ? (
          <>
            <p className="tile-note">
              <b>{outcome.name}</b> is enrolling now and will appear in your
              fleet within about thirty seconds. It reconnects by itself from
              here on — there is nothing to keep or copy.
            </p>
            <button className="btn btn-primary" onClick={onDone}>
              Go to the fleet
            </button>
          </>
        ) : (
          <>
            <p className="tile-note">
              <b>{outcome.name}</b> was told no and has stopped asking. Nothing
              was created and no credential was issued.
            </p>
            <button className="btn" onClick={onDone}>
              Done
            </button>
          </>
        )}
      </section>
    );
  }

  return (
    <section className="card" aria-label="Connect a machine">
      <h2 className="chart-title">Connect a machine</h2>
      <p className="tile-note">
        Run <code>forge-runner login</code> on the machine you want to add. It
        prints a code — type it here.
      </p>

      <div className="inline-form">
        <input
          className="pair-input"
          value={code}
          autoFocus={!initialCode}
          autoCapitalize="characters"
          autoCorrect="off"
          spellCheck={false}
          placeholder="BKPT-4QW9"
          aria-label="The code shown on the machine"
          onChange={(event) => {
            setCode(event.target.value);
            setPending(null);
            setError(null);
          }}
          onKeyDown={(event) => {
            if (event.key === "Enter") look(code);
          }}
        />
        <button
          className="btn btn-primary"
          disabled={busy || normaliseUserCode(code).length !== 8}
          onClick={() => look(code)}
        >
          {busy ? "Checking…" : "Find it"}
        </button>
      </div>

      {error ? <p className="notice error-panel">{error}</p> : null}

      {pending ? (
        <div className="notice success-panel">
          <p className="tile-note">A machine is asking to join this workspace:</p>
          <p>
            <b>{pending.name}</b>
            {pending.version ? (
              <span className="tile-note"> · runner {pending.version}</span>
            ) : null}
          </p>
          <p className="tile-note">
            Approving adds it to your fleet and lets any device signed into this
            workspace reach it. If that name is not a machine you just ran{" "}
            <code>login</code> on, refuse — somebody else is asking.
          </p>
          <div className="inline-form">
            <button
              className="btn btn-primary"
              disabled={busy}
              onClick={() => decide(true)}
            >
              Approve {pending.name}
            </button>
            <button className="btn" disabled={busy} onClick={() => decide(false)}>
              Refuse
            </button>
          </div>
        </div>
      ) : null}
    </section>
  );
}
