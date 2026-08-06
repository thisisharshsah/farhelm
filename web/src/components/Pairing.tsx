/**
 * Pairing (D2).
 *
 * The runner prints a QR; this screen takes it and finishes the exchange:
 * generate a device keypair, redeem the one-time code, and remember what the
 * runner told us. The secret key never leaves the device.
 *
 * There is no camera here. Reading a QR in-browser needs either a barcode
 * library or `BarcodeDetector`, which is not on iOS Safari — the platform every
 * other part of this design already bends around. Pasting the payload works
 * everywhere today, and the terminal prints it alongside the QR for exactly
 * this reason.
 */

import { useState } from "react";
import {
  Identity,
  claimPairing,
  parseOffer,
  type Pairing,
} from "@relayforge/client-core";
import { decisionSurface, webPairingStore } from "../platform";

export function PairingScreen({
  onPaired,
  onCancel,
}: {
  onPaired: (pairing: Pairing) => void;
  onCancel: () => void;
}) {
  const [payload, setPayload] = useState("");
  // Defaults to the same origin: the usual flow is opening the app from the
  // runner, pairing, and only then walking out of the building.
  const [runnerUrl, setRunnerUrl] = useState(location.origin);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async () => {
    setBusy(true);
    setError(null);
    try {
      const offer = parseOffer(payload);

      // The keypair is generated here and now. The runner only ever learns the
      // public half.
      const identity = Identity.generate();
      const claimed = await claimPairing(
        runnerUrl,
        offer,
        decisionSurface(),
        identity.publicKey,
      );

      const pairing: Pairing = { ...claimed, secret: identity.toSecret() };
      await webPairingStore.save(pairing);
      onPaired(pairing);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="card" aria-label="Pair this device">
      <div className="chart-title">Pair this device</div>
      <p className="tile-note">
        Run <code>forge-runner pair</code> on the runner and paste what it
        prints. The code works once and expires in ten minutes.
      </p>

      <label className="tile-label" htmlFor="pair-payload">
        Pairing code
      </label>
      <textarea
        id="pair-payload"
        className="pair-input"
        value={payload}
        onChange={(event) => setPayload(event.target.value)}
        placeholder='{"relay_url":"wss://…","channel":"forge-…",…}'
        rows={4}
        spellCheck={false}
        autoCapitalize="none"
        autoCorrect="off"
      />

      <label className="tile-label" htmlFor="pair-runner">
        Runner address
      </label>
      <input
        id="pair-runner"
        className="pair-input"
        value={runnerUrl}
        onChange={(event) => setRunnerUrl(event.target.value)}
        placeholder="http://192.168.1.10:7842"
        spellCheck={false}
        autoCapitalize="none"
        autoCorrect="off"
      />
      <p className="tile-note">
        Reachable now — pairing happens on your own network, before the relay
        takes over.
      </p>

      {error ? <p className="notice error-text">{error}</p> : null}

      <div className="approval-actions">
        <button className="btn" onClick={onCancel} disabled={busy}>
          Cancel
        </button>
        <button
          className="btn btn-approve"
          onClick={() => void submit()}
          disabled={busy || !payload.trim()}
        >
          {busy ? "Pairing…" : "Pair"}
        </button>
      </div>
    </section>
  );
}
