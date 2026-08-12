/**
 * Sign in, and the screen that comes before it.
 *
 * This replaces the pairing screen as the app's front door, and the difference
 * is the whole point of the change: pairing asked you to run a command on
 * another machine, read a QR, and paste two hundred characters of JSON — while
 * standing on the same network. This asks for an email and a password.
 *
 * # Why "use this machine" is still here
 *
 * A control plane is one deployment shape, not the only one. Opening the app on
 * the runner's own machine should work with no account at all, and hiding that
 * behind a sign-up wall would make the simplest case the hardest. So the choice
 * is offered once, on first run, and remembered.
 */

import { useState } from "react";
import { CloudError } from "@relayforge/client-core";

export type Mode = "sign-in" | "sign-up";

export function WelcomeScreen({
  onChoose,
  loopbackAvailable,
}: {
  onChoose: (choice: "cloud" | "loopback") => void;
  /** False when this page is not being served by a runner. */
  loopbackAvailable: boolean;
}) {
  return (
    <section className="hero" aria-label="Welcome">
      <div className="hero-mark" aria-hidden="true">
        ◈
      </div>
      <h2 className="hero-title">Supervise your agents from anywhere</h2>
      <p className="hero-sub">
        Approve a command from your phone, review a diff on the train, and see
        what it all cost — while the work keeps running on your own machine.
      </p>

      <div className="hero-actions">
        <button className="btn btn-primary btn-lg" onClick={() => onChoose("cloud")}>
          Sign in
        </button>
        {loopbackAvailable ? (
          <button className="btn btn-lg" onClick={() => onChoose("loopback")}>
            Use this machine only
          </button>
        ) : null}
      </div>

      <p className="hero-note">
        Signing in never gives us your code. Your machine and your devices
        exchange keys directly; we route the ciphertext and cannot read it.
      </p>
    </section>
  );
}

export function AuthScreen({
  initialMode = "sign-in",
  onSubmit,
  onCancel,
  busy,
  error,
}: {
  initialMode?: Mode;
  onSubmit: (input: {
    mode: Mode;
    email: string;
    password: string;
    name: string;
  }) => void;
  onCancel: (() => void) | null;
  busy: boolean;
  error: string | null;
}) {
  const [mode, setMode] = useState<Mode>(initialMode);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [name, setName] = useState("");

  const signingUp = mode === "sign-up";
  // Mirrors `forge_cloud::secret::MIN_PASSWORD_LEN`. Checked here so the length
  // rule is visible while typing rather than as a rejection after submitting.
  const tooShort = signingUp && password.length > 0 && password.length < 10;
  const ready =
    email.trim().length > 0 &&
    password.length > 0 &&
    !tooShort &&
    (!signingUp || name.trim().length > 0);

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    if (!ready || busy) return;
    onSubmit({ mode, email: email.trim(), password, name: name.trim() });
  };

  return (
    <section className="card auth" aria-label={signingUp ? "Create an account" : "Sign in"}>
      <div className="auth-switch" role="tablist">
        <button
          role="tab"
          aria-selected={!signingUp}
          className={!signingUp ? "auth-tab is-active" : "auth-tab"}
          onClick={() => setMode("sign-in")}
          type="button"
        >
          Sign in
        </button>
        <button
          role="tab"
          aria-selected={signingUp}
          className={signingUp ? "auth-tab is-active" : "auth-tab"}
          onClick={() => setMode("sign-up")}
          type="button"
        >
          Create account
        </button>
      </div>

      <form onSubmit={submit}>
        {signingUp ? (
          <>
            <label className="tile-label" htmlFor="auth-name">
              Your name
            </label>
            <input
              id="auth-name"
              className="pair-input"
              value={name}
              onChange={(event) => setName(event.target.value)}
              autoComplete="name"
              placeholder="Harsh"
            />
          </>
        ) : null}

        <label className="tile-label" htmlFor="auth-email">
          Email
        </label>
        <input
          id="auth-email"
          className="pair-input"
          type="email"
          value={email}
          onChange={(event) => setEmail(event.target.value)}
          autoComplete="email"
          autoCapitalize="none"
          autoCorrect="off"
          spellCheck={false}
          placeholder="you@example.com"
        />

        <label className="tile-label" htmlFor="auth-password">
          Password
        </label>
        <input
          id="auth-password"
          className="pair-input"
          type="password"
          value={password}
          onChange={(event) => setPassword(event.target.value)}
          autoComplete={signingUp ? "new-password" : "current-password"}
          placeholder={signingUp ? "At least 10 characters" : ""}
        />
        {tooShort ? (
          <p className="tile-note">
            {10 - password.length} more character
            {10 - password.length === 1 ? "" : "s"} — length is what actually
            makes a password hard to guess.
          </p>
        ) : null}

        {error ? (
          <p className="notice error-text" role="alert">
            {error}
          </p>
        ) : null}

        <div className="approval-actions">
          {onCancel ? (
            <button className="btn" type="button" onClick={onCancel} disabled={busy}>
              Back
            </button>
          ) : null}
          <button className="btn btn-primary" type="submit" disabled={!ready || busy}>
            {busy ? "…" : signingUp ? "Create account" : "Sign in"}
          </button>
        </div>
      </form>

      {signingUp ? (
        <p className="tile-note">
          You get a workspace of your own. Add a machine to it in one step
          afterwards — there is nothing to pair.
        </p>
      ) : null}
    </section>
  );
}

/**
 * The step between signing in and having a fleet: pick which machine this
 * device should watch.
 *
 * Skipped automatically when there is exactly one, which is the common case and
 * the one that should not cost a tap.
 */
export function MachinePicker({
  runners,
  onPick,
  onAddMachine,
  busy,
}: {
  runners: Array<{
    id: string;
    name: string;
    online: boolean;
    needs_key_approval: boolean;
    version: string;
  }>;
  onPick: (runnerId: string) => void;
  onAddMachine: () => void;
  busy: boolean;
}) {
  if (runners.length === 0) {
    return (
      <section className="card" aria-label="No machines yet">
        <div className="chart-title">No machines yet</div>
        <p className="tile-note">
          A machine joins your workspace by running the daemon with an enrolment
          key. There is no code to type on either side.
        </p>
        <button className="btn btn-primary" onClick={onAddMachine}>
          Add a machine
        </button>
      </section>
    );
  }

  return (
    <section className="card" aria-label="Choose a machine">
      <div className="chart-title">Which machine?</div>
      <ul className="machine-list">
        {runners.map((runner) => (
          <li key={runner.id}>
            <button
              className="machine-row"
              onClick={() => onPick(runner.id)}
              disabled={busy || runner.needs_key_approval}
            >
              <span
                className={runner.online ? "machine-dot is-online" : "machine-dot is-offline"}
                aria-hidden="true"
              />
              <span className="machine-name">{runner.name}</span>
              <span className="machine-meta">
                {runner.needs_key_approval
                  ? "identity changed — needs confirming"
                  : runner.online
                    ? `v${runner.version}`
                    : "offline"}
              </span>
            </button>
          </li>
        ))}
      </ul>
      <button className="btn" onClick={onAddMachine}>
        Add another machine
      </button>
    </section>
  );
}

/** Turn any thrown value into something worth showing a person. */
export function readableError(cause: unknown): string {
  if (cause instanceof CloudError) return cause.message;
  if (cause instanceof Error) return cause.message;
  return String(cause);
}
