/** Account access and the local-only entry point share the same front door. */

import { useRef, useState } from "react";
import { CloudError } from "@farhelm/client-core";
import "./Auth.css";

export type Mode = "sign-in" | "sign-up";

function AuthIntroduction({ welcome = false }: { welcome?: boolean }) {
  return (
    <div className="auth-introduction">
      <div className="auth-brand">
        <span aria-hidden="true">◈</span> Farhelm
      </div>
      <p className="auth-eyebrow">AI work, under your control</p>
      <h1>{welcome ? "Build with AI. Keep control." : "Your workspace, wherever you work."}</h1>
      <p className="auth-description">
        Bring your projects and AI agents together. Work on your own machine,
        approve consequential actions, and review the changes.
      </p>
      <ol className="auth-workflow" aria-label="How Farhelm works">
        <li>
          <span aria-hidden="true">01</span>
          <div><strong>Give the work direction</strong><p>Start with a project and a clear task.</p></div>
        </li>
        <li>
          <span aria-hidden="true">02</span>
          <div><strong>Stay in the loop</strong><p>Approve commands before they run.</p></div>
        </li>
        <li>
          <span aria-hidden="true">03</span>
          <div><strong>Review what changed</strong><p>Inspect the tests, cost and diff.</p></div>
        </li>
      </ol>
    </div>
  );
}

export function WelcomeScreen({
  onChoose,
  loopbackAvailable,
}: {
  onChoose: (choice: "cloud" | "loopback") => void;
  /** False when this page is not being served by a runner. */
  loopbackAvailable: boolean;
}) {
  return (
    <section className="auth-layout" aria-label="Welcome">
      <AuthIntroduction welcome />
      <div className="card auth-panel auth-welcome-panel">
        <p className="auth-eyebrow">Get started</p>
        <h2>Choose how to connect</h2>
        <p className="auth-panel-description">{loopbackAvailable ? "Use an account to connect your devices, or stay on this machine." : "Use your account to connect your devices and supervise your work."}</p>
        <button className="btn btn-primary btn-lg auth-primary" onClick={() => onChoose("cloud")}>
          Sign in to your workspace <span aria-hidden="true">→</span>
        </button>
        <p className="auth-caption">New here? You can create an account on the next screen.</p>
        {loopbackAvailable ? (
          <div className="auth-local-option">
            <div className="auth-divider"><span>On this computer</span></div>
            <button className="btn btn-lg auth-primary" onClick={() => onChoose("loopback")}>
              Use this machine only
            </button>
            <p className="auth-caption">Connect to your local runner. No account required.</p>
          </div>
        ) : null}
        <p className="auth-privacy">Your runner executes the work. Remote access uses an encrypted connection between your devices.</p>
      </div>
    </section>
  );
}

export function AuthScreen({
  initialMode = "sign-in",
  onSubmit,
  onCancel,
  busy,
  error,
  onModeChange,
  serviceUrl,
  onServiceUrlChange,
}: {
  initialMode?: Mode;
  onSubmit: (input: {
    mode: Mode;
    email: string;
    password: string;
    name: string;
  }) => Promise<void> | void;
  onCancel: (() => void) | null;
  busy: boolean;
  error: string | null;
  onModeChange?: () => void;
  serviceUrl?: string;
  onServiceUrlChange?: (url: string) => void;
}) {
  const [mode, setMode] = useState<Mode>(initialMode);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [name, setName] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [localError, setLocalError] = useState<string | null>(null);
  const submitted = useRef(false);

  const signingUp = mode === "sign-up";
  // Mirrors `farhelm_cloud::secret::MIN_PASSWORD_LEN`. Checked here so the length
  // rule is visible while typing rather than as a rejection after submitting.
  const passwordLength = [...password].length;
  const tooShort = signingUp && passwordLength > 0 && passwordLength < 10;
  const pending = busy || submitting;
  const ready =
    email.trim().length > 0 &&
    password.length > 0 &&
    !tooShort &&
    (!signingUp || name.trim().length > 0);

  const submit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!ready || pending || submitted.current || !event.currentTarget.checkValidity()) return;
    submitted.current = true;
    setSubmitting(true);
    setLocalError(null);
    try {
      await onSubmit({ mode, email: email.trim(), password, name: name.trim() });
    } catch (cause) {
      setLocalError(readableError(cause));
    } finally {
      submitted.current = false;
      setSubmitting(false);
    }
  };

  const changeMode = (next: Mode) => {
    if (pending || next === mode) return;
    setMode(next);
    setPassword("");
    setShowPassword(false);
    setLocalError(null);
    onModeChange?.();
  };

  return (
    <section className="auth-layout" aria-label={signingUp ? "Create an account" : "Sign in"}>
      <AuthIntroduction />
      <div className="card auth-panel">
        <div className="auth-mode-switch" role="group" aria-label="Account access">
          <button
            aria-pressed={!signingUp}
            className={!signingUp ? "auth-mode is-active" : "auth-mode"}
            onClick={() => changeMode("sign-in")}
            type="button"
            disabled={pending}
          >
            Sign in
          </button>
          <button
            aria-pressed={signingUp}
            className={signingUp ? "auth-mode is-active" : "auth-mode"}
            onClick={() => changeMode("sign-up")}
            type="button"
            disabled={pending}
          >
            Create account
          </button>
        </div>
        <h2>{signingUp ? "Create your workspace" : "Welcome back"}</h2>
        <p className="auth-panel-description">{signingUp ? "Start with your account. Connect a machine when you’re ready." : "Sign in to connect your machines and review their work."}</p>
        <form onSubmit={submit} aria-busy={pending}>
          <fieldset className="auth-fields" disabled={pending}>
            {signingUp ? (
              <>
                <label htmlFor="auth-name">
                  Your name
                </label>
                <input
                  id="auth-name"
                  className="pair-input"
                  value={name}
                  onChange={(event) => setName(event.target.value)}
                  autoComplete="name"
                  name="name"
                  placeholder="Your name"
                  required
                />
              </>
            ) : null}

            <label htmlFor="auth-email">
              Email
            </label>
            <input
              id="auth-email"
              className="pair-input"
              type="email"
              value={email}
              onChange={(event) => setEmail(event.target.value)}
              autoComplete="email"
              name="email"
              autoCapitalize="none"
              autoCorrect="off"
              spellCheck={false}
              placeholder="you@example.com"
              required
            />

            <label htmlFor="auth-password">
              Password
            </label>
            <div className="auth-password">
              <input
                id="auth-password"
                className="pair-input"
                type={showPassword ? "text" : "password"}
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                autoComplete={signingUp ? "new-password" : "current-password"}
                name="password"
                aria-describedby={signingUp ? "auth-password-hint" : undefined}
                aria-invalid={tooShort || undefined}
                required
              />
              <button
                type="button"
                className="auth-password-toggle"
                aria-controls="auth-password"
                aria-label={showPassword ? "Hide password" : "Show password"}
                aria-pressed={showPassword}
                onClick={() => setShowPassword((value) => !value)}
              >
                {showPassword ? "Hide" : "Show"}
              </button>
            </div>
            {signingUp ? (
              <p className="auth-caption" id="auth-password-hint">
                {tooShort ? `Use at least 10 characters (${10 - passwordLength} more needed).` : "Use at least 10 characters."}
              </p>
            ) : null}
            {serviceUrl !== undefined ? (
              <details className="auth-server">
                <summary>Workspace server</summary>
                <label htmlFor="auth-server-url">Server address</label>
                <input
                  id="auth-server-url"
                  className="pair-input"
                  type="url"
                  name="server"
                  value={serviceUrl}
                  onChange={(event) => onServiceUrlChange?.(event.target.value)}
                  readOnly={!onServiceUrlChange}
                  spellCheck={false}
                  autoCapitalize="none"
                  autoComplete="url"
                />
                <p className="auth-caption">Your email and password are sent to this server.</p>
              </details>
            ) : null}
          </fieldset>
          {error || localError ? (
            <p className="auth-error" role="alert">
              {error || localError}
            </p>
          ) : null}
          <button className="btn btn-primary btn-lg auth-primary" type="submit" disabled={!ready || pending}>
            {pending ? (signingUp ? "Creating account…" : "Signing in…") : signingUp ? "Create account" : "Sign in"}
            {!pending ? <span aria-hidden="true">→</span> : null}
          </button>
          {pending ? <p className="auth-caption" role="status">{signingUp ? "Creating your account. Please wait." : "Connecting to your workspace. Please wait."}</p> : null}
          {onCancel ? (
            <button className="btn btn-quiet auth-back" type="button" onClick={onCancel} disabled={pending}>
              <span aria-hidden="true">←</span> Back to connection options
            </button>
          ) : null}
        </form>
      </div>
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
          One command on the machine you want supervised — it installs Farhelm
          and asks to join, and you approve it here.
        </p>
        <button className="btn btn-primary" onClick={onAddMachine}>
          Show me the command
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
