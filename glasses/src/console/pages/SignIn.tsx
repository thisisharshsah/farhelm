import { useState, type FormEvent } from "react";
import { createAccount, passkeyError, passkeysSupported, signInWithPasskey } from "../passkeys.ts";
import { Button, ErrorNote, Field, Mark, useAction } from "../ui.tsx";

/** Sign in with a passkey, or create an account with an invite code. No passwords anywhere. */
export function SignIn({ onSignedIn }: { onSignedIn: () => void }) {
  const [mode, setMode] = useState<"sign-in" | "create">("sign-in");
  const [name, setName] = useState("");
  const [invite, setInvite] = useState("");
  const supported = passkeysSupported();

  const signIn = useAction(async () => {
    try {
      await signInWithPasskey();
    } catch (e) {
      throw passkeyError(e);
    }
    onSignedIn();
  });

  const create = useAction(async () => {
    try {
      await createAccount(name.trim(), invite.trim());
    } catch (e) {
      throw passkeyError(e);
    }
    onSignedIn();
  });

  const submitCreate = (e: FormEvent) => {
    e.preventDefault();
    void create.run();
  };

  return (
    <main className="auth">
      <div className="auth-panel glass">
        <div className="auth-brand">
          <Mark size={52} />
        </div>
        {mode === "sign-in" ? (
          <>
            <h1>Sign in to Lens</h1>
            <p className="auth-lead">Your glasses, your apps and one chat for both.</p>
            {supported ? (
              <Button variant="primary" size="lg" icon="key" busy={signIn.busy} onClick={() => void signIn.run()} className="wide">
                Sign in with a passkey
              </Button>
            ) : (
              <ErrorNote message="This browser does not support passkeys. Use a current Safari, Chrome, Edge or Firefox." />
            )}
            <ErrorNote message={signIn.error} />
            <div className="auth-switch">
              <span>New to Lens?</span>
              <button className="link-button" onClick={() => setMode("create")}>
                Create an account
              </button>
            </div>
          </>
        ) : (
          <>
            <h1>Create your account</h1>
            <p className="auth-lead">You need an invite code. Your device will save a passkey, so there is no password to remember.</p>
            <form className="stack" onSubmit={submitCreate}>
              <Field
                label="Your name"
                value={name}
                onChange={(e) => setName(e.target.value)}
                autoComplete="name"
                maxLength={60}
                required
                autoFocus
              />
              <Field
                label="Invite code"
                value={invite}
                onChange={(e) => setInvite(e.target.value)}
                autoComplete="one-time-code"
                autoCapitalize="none"
                spellCheck={false}
                required
                hint="The owner of this Lens gives you one. It works once."
              />
              <Button type="submit" variant="primary" size="lg" icon="key" busy={create.busy} className="wide" disabled={!supported}>
                Create account with a passkey
              </Button>
            </form>
            <ErrorNote message={create.error} />
            <div className="auth-switch">
              <span>Already have an account?</span>
              <button className="link-button" onClick={() => setMode("sign-in")}>
                Sign in
              </button>
            </div>
          </>
        )}
      </div>
      <p className="auth-foot">Passkeys stay on your devices. Lens never sees or stores a password.</p>
    </main>
  );
}
