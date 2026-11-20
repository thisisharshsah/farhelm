import { useCallback, useEffect, useRef, useState } from "react";
import { HttpError, api, messageOf } from "../../../client/http.ts";
import { DevicePoll, DeviceStart } from "../../../shared/api.ts";
import { formatClock } from "../timer/timer.ts";
import { useNow } from "../../lib/useNow.ts";
import { Mark } from "../../ui/Mark.tsx";

type Phase =
  | { kind: "starting" }
  | { kind: "waiting"; codes: DeviceStart; expiresAt: number }
  | { kind: "denied" }
  | { kind: "error"; message: string };

/**
 * Links these glasses to an account. The glasses show a short code; the
 * person approves it at lens.aurovie.com/link, signed in with a passkey on
 * their phone or computer. Codes renew themselves when they expire.
 */
export function Pairing({ onLinked }: { onLinked: () => void }) {
  const [phase, setPhase] = useState<Phase>({ kind: "starting" });
  const now = useNow(1000);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const retry = useRef<HTMLButtonElement>(null);

  const start = useCallback(async () => {
    if (timer.current) clearTimeout(timer.current);
    setPhase({ kind: "starting" });
    try {
      const codes = await api("/api/device/start", { method: "POST", body: { clientName: "Ray-Ban Display" }, schema: DeviceStart });
      setPhase({ kind: "waiting", codes, expiresAt: Date.now() + codes.expiresIn * 1000 });
    } catch (e) {
      setPhase({ kind: "error", message: messageOf(e) });
    }
  }, []);

  useEffect(() => {
    void start();
    return () => {
      if (timer.current) clearTimeout(timer.current);
    };
  }, [start]);

  // Poll while waiting, at the interval the server asked for (longer after slow_down).
  useEffect(() => {
    if (phase.kind !== "waiting") return;
    let interval = phase.codes.interval * 1000;
    let stopped = false;
    const poll = async () => {
      if (stopped) return;
      try {
        const answer = await api("/api/device/poll", {
          method: "POST",
          body: { deviceCode: phase.codes.deviceCode },
          schema: DevicePoll,
        });
        if (stopped) return;
        switch (answer.status) {
          case "approved":
            onLinked();
            return;
          case "denied":
            setPhase({ kind: "denied" });
            return;
          case "expired":
            void start();
            return;
          case "slow_down":
            interval += 5000;
            break;
          case "pending":
            break;
        }
      } catch (e) {
        if (stopped) return;
        // A dropped connection is retried; anything the server rejected outright is shown.
        if (e instanceof HttpError && e.status >= 400 && e.status < 500) {
          setPhase({ kind: "error", message: e.message });
          return;
        }
      }
      timer.current = setTimeout(poll, interval);
    };
    timer.current = setTimeout(poll, interval);
    return () => {
      stopped = true;
      if (timer.current) clearTimeout(timer.current);
    };
  }, [phase, onLinked, start]);

  useEffect(() => {
    if (phase.kind === "denied" || phase.kind === "error") retry.current?.focus();
  }, [phase.kind]);

  const host = phase.kind === "waiting" ? phase.codes.verificationUri.replace(/^https?:\/\//, "") : "";

  return (
    <section className="view pairing" aria-label="Link your glasses">
      <Mark size={64} />
      <h1 className="title">Link your glasses</h1>
      {phase.kind === "waiting" ? (
        <>
          <p className="pair-step">On your phone or computer, open</p>
          <p className="pair-url">{host}</p>
          <p className="pair-step">and enter</p>
          <p className="pair-code" aria-live="polite">
            {phase.codes.userCode}
          </p>
          <p className="pair-expiry">New code in {formatClock(Math.min(phase.codes.expiresIn * 1000, Math.max(0, phase.expiresAt - now)))}</p>
        </>
      ) : phase.kind === "starting" ? (
        <div className="center">
          <p>Getting a code…</p>
        </div>
      ) : (
        <>
          <div className="center">
            <p>{phase.kind === "denied" ? "The link was declined on your other device." : phase.message}</p>
          </div>
          <button ref={retry} className="btn primary" onClick={() => void start()}>
            Get a new code
          </button>
        </>
      )}
    </section>
  );
}
