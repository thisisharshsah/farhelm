/**
 * How a machine joins this workspace.
 *
 * The app used to answer this with an enrolment key: mint one, copy it, paste
 * it into a daemon, remember that it is a live credential and is shown exactly
 * once. That is still here, at the bottom, because provisioning a fleet from a
 * script needs a credential a script can carry.
 *
 * It is no longer the *answer*, because it stopped being the shortest path a
 * while ago and nothing in the app said so. `farhelm login` asks to join, and
 * the install script does the installing and the asking in one line — neither
 * puts a bearer credential through a clipboard, and both work on a box whose
 * browser belongs to somebody else. An empty workspace that recommends the long
 * way is the same failure as a diagnostic that recommends the setup it
 * replaced: the advice is followable, and following it is worse than following
 * nothing.
 *
 * # Why the script is offered from here and not written out
 *
 * The one-liner is served by the control plane you are signed into, so the
 * TLS connection that hands over the script is the same one the machine will
 * authenticate against afterwards. That property only holds if the URL comes
 * from the live session rather than from documentation, which is why every
 * command on this screen is built from `cloud.baseUrl`.
 */

import { useState } from "react";
import type { CloudClient, EnrollmentKey } from "@farhelm/client-core";
import { readableError } from "./Auth";

/**
 * A command with a copy button.
 *
 * Copying is the whole interaction — the command is going to a different
 * machine, and retyping a URL by hand is where the typo goes. The button keeps
 * its confirmation for a moment and then returns, so the state is legible
 * without becoming a thing to dismiss.
 */
export function CopyCommand({ command, label }: { command: string; label?: string }) {
  const [copied, setCopied] = useState(false);

  const copy = () => {
    // `clipboard` is undefined on an insecure origin, which is exactly where a
    // loopback deployment lives. Falling back to selecting the text keeps the
    // button honest rather than silently doing nothing.
    void navigator.clipboard
      ?.writeText(command)
      .then(() => {
        setCopied(true);
        setTimeout(() => setCopied(false), 2000);
      })
      .catch(() => setCopied(false));
  };

  return (
    <div className="copy-command">
      <code className="secret-block">{command}</code>
      <button
        className="btn btn-small"
        onClick={copy}
        aria-label={label ? `Copy ${label}` : "Copy command"}
      >
        {copied ? "Copied" : "Copy"}
      </button>
    </div>
  );
}

export function AddMachine({
  cloud,
  onError,
  /** Rendered inline in an empty workspace, and as a card in settings. */
  variant = "card",
}: {
  cloud: CloudClient;
  onError: (message: string) => void;
  variant?: "card" | "bare";
}) {
  const base = cloud.baseUrl.replace(/\/$/, "");

  const body = (
    <>
      <p className="tile-note">
        Run this on the machine you want supervised. It installs Farhelm, then
        asks to join — you approve it here, and it appears in this list.
      </p>
      <CopyCommand command={`curl -fsSL ${base}/install.sh | bash`} label="the install command" />

      <p className="tile-note">
        Already have it installed? <code className="key-fragment">farhelm login</code> does the
        joining half on its own:
      </p>
      <CopyCommand command={`farhelm login --cloud ${base}`} label="the join command" />

      <p className="tile-note">
        Either way the machine prints a short code and waits. Nothing is copied
        by hand, and it works over SSH.
      </p>

      <ScriptedFleet cloud={cloud} onError={onError} base={base} />
    </>
  );

  if (variant === "bare") return body;

  return (
    <section className="card" aria-label="Add a machine">
      <div className="chart-title">Add a machine</div>
      {body}
    </section>
  );
}

/**
 * The enrolment-key path, folded away.
 *
 * Kept because it is genuinely the right tool for a fleet somebody provisions
 * from configuration management, where there is no person to approve a code.
 * Folded because it is the wrong tool for the one machine most people are
 * adding, and an interface that presents both at equal weight makes everybody
 * read both.
 */
function ScriptedFleet({
  cloud,
  onError,
  base,
}: {
  cloud: CloudClient;
  onError: (message: string) => void;
  base: string;
}) {
  const [open, setOpen] = useState(false);
  const [name, setName] = useState("");
  const [minted, setMinted] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [keys, setKeys] = useState<EnrollmentKey[] | null>(null);

  const load = () => {
    cloud
      .enrollmentKeys()
      .then(setKeys)
      .catch((cause: unknown) => onError(readableError(cause)));
  };

  // Loaded on opening rather than on mount: this section is folded away for
  // almost everybody, and a request nobody asked for on every visit to the
  // settings screen is a request that only ever costs something.
  const toggle = () => {
    const next = !open;
    setOpen(next);
    if (next && keys === null) load();
  };

  const create = () => {
    cloud
      .createEnrollmentKey(name.trim() || "Machines")
      .then((created) => {
        setMinted(created.token);
        setName("");
        setCopied(false);
        load();
      })
      .catch((cause: unknown) => onError(readableError(cause)));
  };

  return (
    <div className="scripted-fleet">
      <button className="disclosure" onClick={toggle} aria-expanded={open}>
        <span className="tile-note">Provisioning several from a script?</span>
        <span aria-hidden="true">{open ? "−" : "+"}</span>
      </button>

      {open ? (
        <>
          <p className="tile-note">
            An enrolment key joins a machine with no one present to approve a
            code. It is a live credential: anything holding it can enrol as this
            workspace, so it belongs in a secret store rather than in a shell
            history.
          </p>

          {minted ? (
            <div className="notice success-panel">
              <b>Your key — copy it now.</b>
              <p className="tile-note">
                Only a hash of it is stored, so this is the one time it can be
                shown.
              </p>
              <code className="secret-block">{minted}</code>
              <button
                className="btn"
                onClick={() => {
                  void navigator.clipboard?.writeText(minted).then(() => setCopied(true));
                }}
              >
                {copied ? "Copied" : "Copy key"}
              </button>

              <p className="tile-note">Then, on each machine:</p>
              <code className="secret-block">
                {`FARHELM_CLOUD_KEY=${minted.slice(0, 12)}… \\\n  farhelm serve --cloud ${base}`}
              </code>
              <p className="tile-note">
                In the environment rather than on the command line — a credential
                in an argument is in every <code className="key-fragment">ps</code>.
              </p>
              <button className="btn btn-small" onClick={() => setMinted(null)}>
                Done
              </button>
            </div>
          ) : (
            <div className="inline-form">
              <input
                className="pair-input"
                value={name}
                onChange={(event) => setName(event.target.value)}
                placeholder="What is this key for? e.g. CI fleet"
              />
              <button className="btn" onClick={create}>
                Create key
              </button>
            </div>
          )}

          {keys && keys.length > 0 ? (
            <ul className="key-list">
              {keys.map((key) => (
                <li key={key.id} className="row-between">
                  <div>
                    <div className="machine-name">{key.name}</div>
                    <p className="tile-note">
                      <code className="key-fragment">{key.prefix}…</code>{" "}
                      {key.revoked_at
                        ? "· revoked"
                        : key.last_used_at
                          ? `· last used ${new Date(key.last_used_at).toLocaleDateString()}`
                          : "· never used"}
                    </p>
                  </div>
                  {key.revoked_at ? null : (
                    // Revoking is why the list is here at all: a key that has
                    // leaked has to be killable from the same screen that
                    // minted it, without going looking for where keys live.
                    <button
                      className="btn btn-small btn-deny"
                      onClick={() => {
                        cloud
                          .revokeEnrollmentKey(key.id)
                          .then(load)
                          .catch((cause: unknown) => onError(readableError(cause)));
                      }}
                    >
                      Revoke
                    </button>
                  )}
                </li>
              ))}
            </ul>
          ) : null}
        </>
      ) : null}
    </div>
  );
}
