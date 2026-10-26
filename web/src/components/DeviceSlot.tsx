/**
 * What to do when this browser was refused a device seat.
 *
 * The usual cause is not a second computer. A device is a key kept in the
 * browser's storage, and that storage belongs to one browser at one address,
 * so the same Mac in Arc and in Chrome, or at `localhost` and at the public
 * address, is two devices. On a two-device plan that fills up fast, and the
 * old banner only said "no device slot" and pointed at the account screen.
 * This one names the devices holding the seats and offers to move one of them
 * to this browser in a single step.
 */

import { useRef, useState } from "react";
import { since, type CloudDevice } from "@farhelm/client-core";

export function DeviceSlotNotice({
  problem,
  devices,
  onReplace,
  onRetry,
  onPlans,
}: {
  problem: string;
  devices: CloudDevice[];
  onReplace: (deviceId: string) => Promise<void>;
  onRetry: () => Promise<void>;
  onPlans: () => void;
}) {
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);

  const run = async (key: string, action: () => Promise<void>) => {
    if (inFlight.current) return;
    inFlight.current = true;
    setBusy(key);
    setError(null);
    try {
      await action();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      inFlight.current = false;
      setBusy(null);
    }
  };

  const newestFirst = [...devices].sort((a, b) => b.last_seen_at - a.last_seen_at);

  return (
    <section className="card notice-card device-slot" aria-label="Device slot">
      <b>This browser is not one of your devices yet.</b>
      {/* Punctuated here rather than trusting the server's wording to end in a
          full stop; it does not. */}
      <p className="tile-note">
        {problem.replace(/[.\s]*$/, "")}. Each browser, and each web address,
        keeps its own device key, so this computer in another browser or at
        another address counts separately. You can manage the workspace, but
        this browser cannot open an encrypted link to a machine until it holds a
        slot.
      </p>

      {newestFirst.length > 0 ? (
        <ul className="device-slot-list">
          {newestFirst.map((device) => (
            <li key={device.id}>
              <span className="device-slot-name">{device.name}</span>
              <span className="muted">last seen {since(device.last_seen_at)}</span>
              <span className="spacer" />
              <button
                className="btn btn-small"
                disabled={busy !== null}
                onClick={() => void run(device.id, () => onReplace(device.id))}
              >
                {busy === device.id ? "Moving…" : "Use this browser instead"}
              </button>
            </li>
          ))}
        </ul>
      ) : null}
      <p className="tile-note">
        Replacing a device signs it out of encrypted links. It can take its slot
        back the same way.
      </p>

      {error ? <p className="notice" role="alert">{error}</p> : null}

      <div className="approval-actions">
        <button className="btn" disabled={busy !== null} onClick={() => void run("retry", onRetry)}>
          {busy === "retry" ? "Trying…" : "Try again"}
        </button>
        <button className="btn" onClick={onPlans}>See plans</button>
      </div>
    </section>
  );
}
