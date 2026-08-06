/**
 * The notification toggle.
 *
 * Lives inside the pairing card because it only makes sense there: the relay is
 * what wakes a sleeping device, and a device that has not paired has no relay.
 *
 * The screen's real job is explaining the failure modes rather than the success
 * one. Push on iOS fails silently in a specific, well-known way — Safari
 * resolves `requestPermission()` to `"denied"` in a browser tab without ever
 * prompting — so "add it to your Home Screen first" is stated up front instead
 * of after a mysterious refusal.
 */

import { useEffect, useState } from "react";
import type { Pairing } from "@relayforge/client-core";
import { disablePush, enablePush, pushState, type PushState } from "../push";

export function PushSettings({ pairing }: { pairing: Pairing }) {
  const [state, setState] = useState<PushState | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    void pushState().then(setState);
  }, []);

  const act = async (run: () => Promise<PushState>) => {
    setBusy(true);
    setError(null);
    try {
      setState(await run());
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  };

  if (!state) return null;

  return (
    <div style={{ marginTop: "0.75rem" }}>
      <div className="tile-label">Notifications</div>

      {state.status === "needs-install" ? (
        <p className="tile-note">
          Add RelayForge to your Home Screen first — iOS only allows
          notifications for installed apps, and refuses silently in a browser
          tab. Share → <b>Add to Home Screen</b>, then open it from there.
        </p>
      ) : state.status === "unsupported" ? (
        <p className="tile-note">{state.reason}</p>
      ) : state.status === "denied" ? (
        <p className="tile-note">
          Notifications are blocked for this site. The browser will not ask
          again — turn them back on in its site settings.
        </p>
      ) : (
        <>
          <p className="tile-note">
            {state.status === "on"
              ? "This device gets woken when an agent needs you. The notification says nothing about what — the relay cannot read it, so the app decrypts and shows the real card when you open it."
              : "Without this, you only see approvals while the app is open."}
          </p>

          {error ? <p className="notice error-text">{error}</p> : null}

          <button
            className={state.status === "on" ? "btn btn-deny" : "btn btn-approve"}
            disabled={busy}
            onClick={() =>
              void act(() =>
                state.status === "on" ? disablePush() : enablePush(pairing),
              )
            }
            style={{ marginTop: "0.5rem" }}
          >
            {busy
              ? "…"
              : state.status === "on"
                ? "Turn off notifications"
                : "Turn on notifications"}
          </button>
        </>
      )}
    </div>
  );
}
