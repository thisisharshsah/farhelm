/**
 * The workspace: machines, devices, people, and what it costs.
 *
 * One screen rather than a settings tree, because there are four short lists and
 * a tree would mean three taps to answer "which of my machines is offline".
 *
 * # The enrolment key is shown once
 *
 * Only its hash is stored, so there is no endpoint that could return it again.
 * The UI has to be honest about that at the moment it matters — a key panel that
 * looks re-openable and is not is how somebody loses one and blames the app.
 */

import { useState } from "react";
import {
  describeLimit,
  formatPrice,
  isAtLimit,
  subscriptionNotice,
  type BillingState,
  type CloudClient,
  type CloudDevice,
  type EnrollmentKey,
  type MemberView,
  type Plan,
  type Role,
  type RunnerView,
  type Workspace,
} from "@relayforge/client-core";
import { readableError } from "./Auth";

const ROLE_BLURB: Record<Role, string> = {
  owner: "Everything, including billing",
  admin: "Adds and removes machines and people",
  member: "Approves commands and reviews diffs",
  viewer: "Reads the fleet and the cost dashboard",
  runner: "A machine, not a person",
};

export function AccountScreen({
  workspace,
  cloud,
  onChanged,
  onBilling,
  onSignOut,
  activeRunnerId,
  onPickRunner,
}: {
  workspace: Workspace;
  cloud: CloudClient;
  onChanged: () => void;
  onBilling: () => void;
  onSignOut: () => void;
  activeRunnerId: string | null;
  onPickRunner: (runnerId: string) => void;
}) {
  const [error, setError] = useState<string | null>(null);
  const notice = subscriptionNotice(workspace.subscription);
  const canAdminister = workspace.role === "admin" || workspace.role === "owner";

  const run = (work: () => Promise<unknown>) => {
    setError(null);
    void work()
      .then(onChanged)
      .catch((cause: unknown) => setError(readableError(cause)));
  };

  return (
    <>
      {notice ? (
        <div className="card notice-card" role="status">
          <p className="tile-note">{notice}</p>
          {workspace.role === "owner" ? (
            <button className="btn" onClick={onBilling}>
              Manage plan
            </button>
          ) : null}
        </div>
      ) : null}

      {error ? (
        <div className="card error" role="alert">
          <p className="tile-note">{error}</p>
        </div>
      ) : null}

      <section className="card" aria-label="Workspace">
        <div className="row-between">
          <div>
            <div className="chart-title">{workspace.org.name}</div>
            <p className="tile-note">
              {workspace.account.email} · {workspace.role}
            </p>
          </div>
          <span className="plan-chip">
            {workspace.subscription.plan.toUpperCase()}
          </span>
        </div>

        <div className="usage-grid">
          <UsageTile
            label="Machines"
            used={workspace.usage.runners}
            limit={workspace.limits.runners}
          />
          <UsageTile
            label="Devices"
            used={workspace.usage.devices}
            limit={workspace.limits.devices}
          />
          <UsageTile
            label="People"
            used={workspace.usage.members}
            limit={workspace.limits.members}
          />
        </div>

        <div className="approval-actions">
          <button className="btn" onClick={onBilling}>
            Plan &amp; billing
          </button>
          <button className="btn btn-deny" onClick={onSignOut}>
            Sign out
          </button>
        </div>
      </section>

      <Machines
        runners={workspace.runners}
        activeRunnerId={activeRunnerId}
        canAdminister={canAdminister}
        onPick={onPickRunner}
        onRename={(id, name) => run(() => cloud.renameRunner(id, name))}
        onApproveKey={(id) => run(() => cloud.approveRunnerKey(id))}
        onForget={(id) => run(() => cloud.forgetRunner(id))}
      />

      {canAdminister ? (
        <EnrolmentKeys cloud={cloud} onError={setError} />
      ) : null}

      <Devices
        devices={workspace.devices}
        accountId={workspace.account.id}
        onForget={(id) => run(() => cloud.forgetDevice(id))}
      />

      <Members
        cloud={cloud}
        role={workspace.role}
        atLimit={isAtLimit(workspace.usage.members, workspace.limits.members)}
        onChanged={onChanged}
        onError={setError}
        onBilling={onBilling}
      />
    </>
  );
}

function UsageTile({
  label,
  used,
  limit,
}: {
  label: string;
  used: number;
  limit: number;
}) {
  const full = isAtLimit(used, limit);
  return (
    <div className={full ? "usage-tile is-full" : "usage-tile"}>
      <div className="tile-label">{label}</div>
      <div className="usage-value">
        {used}
        <span className="usage-limit"> / {describeLimit(limit)}</span>
      </div>
    </div>
  );
}

/* -------------------------------------------------------------------- machines */

function Machines({
  runners,
  activeRunnerId,
  canAdminister,
  onPick,
  onRename,
  onApproveKey,
  onForget,
}: {
  runners: RunnerView[];
  activeRunnerId: string | null;
  canAdminister: boolean;
  onPick: (id: string) => void;
  onRename: (id: string, name: string) => void;
  onApproveKey: (id: string) => void;
  onForget: (id: string) => void;
}) {
  const [renaming, setRenaming] = useState<string | null>(null);
  const [draft, setDraft] = useState("");

  return (
    <section className="card" aria-label="Machines">
      <div className="chart-title">Machines</div>
      {runners.length === 0 ? (
        <p className="tile-note">
          None yet. Create an enrolment key below and start the daemon with it.
        </p>
      ) : null}

      <ul className="machine-list">
        {runners.map((runner) => (
          <li key={runner.id} className="machine-item">
            <div className="row-between">
              <div className="machine-headline">
                <span
                  className={runner.online ? "machine-dot is-online" : "machine-dot is-offline"}
                  aria-hidden="true"
                />
                {renaming === runner.id ? (
                  <input
                    className="pair-input inline-input"
                    value={draft}
                    autoFocus
                    onChange={(event) => setDraft(event.target.value)}
                    onBlur={() => {
                      if (draft.trim()) onRename(runner.id, draft.trim());
                      setRenaming(null);
                    }}
                    onKeyDown={(event) => {
                      if (event.key === "Enter") event.currentTarget.blur();
                      if (event.key === "Escape") setRenaming(null);
                    }}
                  />
                ) : (
                  <span className="machine-name">{runner.name}</span>
                )}
              </div>
              {activeRunnerId === runner.id ? (
                <span className="badge badge-active">Watching</span>
              ) : (
                <button
                  className="btn btn-small"
                  onClick={() => onPick(runner.id)}
                  disabled={runner.needs_key_approval}
                >
                  Watch
                </button>
              )}
            </div>

            <p className="tile-note">
              {runner.online ? "online" : "offline"} · v{runner.version} ·{" "}
              <code className="key-fragment">
                {runner.public_key.slice(0, 12)}…
              </code>
            </p>

            {runner.needs_key_approval ? (
              <div className="notice warn-text">
                <b>This machine&rsquo;s identity changed.</b>
                <p className="tile-note">
                  It is offering a different key from the one on file. That is
                  what a reinstall looks like — and also what somebody standing
                  in front of it looks like. Devices cannot connect until you
                  say which.
                </p>
                {canAdminister ? (
                  <button
                    className="btn btn-approve"
                    onClick={() => onApproveKey(runner.id)}
                  >
                    That was me — accept the new key
                  </button>
                ) : (
                  <p className="tile-note">An admin has to confirm it.</p>
                )}
              </div>
            ) : null}

            {canAdminister ? (
              <div className="approval-actions">
                <button
                  className="btn btn-small"
                  onClick={() => {
                    setRenaming(runner.id);
                    setDraft(runner.name);
                  }}
                >
                  Rename
                </button>
                <button
                  className="btn btn-small btn-deny"
                  onClick={() => onForget(runner.id)}
                >
                  Remove
                </button>
              </div>
            ) : null}
          </li>
        ))}
      </ul>
    </section>
  );
}

/* -------------------------------------------------------------- enrolment keys */

function EnrolmentKeys({
  cloud,
  onError,
}: {
  cloud: CloudClient;
  onError: (message: string) => void;
}) {
  const [keys, setKeys] = useState<EnrollmentKey[] | null>(null);
  const [minted, setMinted] = useState<string | null>(null);
  const [name, setName] = useState("");
  const [open, setOpen] = useState(false);
  const [copied, setCopied] = useState(false);

  const load = () => {
    cloud
      .enrollmentKeys()
      .then(setKeys)
      .catch((cause: unknown) => onError(readableError(cause)));
  };

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
    <section className="card" aria-label="Enrolment keys">
      <button className="disclosure" onClick={toggle} aria-expanded={open}>
        <span className="chart-title">Add a machine</span>
        <span aria-hidden="true">{open ? "−" : "+"}</span>
      </button>

      {open ? (
        <>
          <p className="tile-note">
            An enrolment key is what a machine uses to join this workspace. Paste
            it into the daemon once; every machine you start with it appears
            here by itself.
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
                  void navigator.clipboard.writeText(minted).then(() => setCopied(true));
                }}
              >
                {copied ? "Copied" : "Copy key"}
              </button>

              <p className="tile-note">Then, on the machine:</p>
              <code className="secret-block">
                {`FORGE_CLOUD_KEY=${minted.slice(0, 12)}… \\\n  forge-runner serve --cloud ${cloud.baseUrl}`}
              </code>
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
                placeholder="What is this key for? e.g. Home server"
              />
              <button className="btn btn-primary" onClick={create}>
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
    </section>
  );
}

/* --------------------------------------------------------------------- devices */

function Devices({
  devices,
  accountId,
  onForget,
}: {
  devices: CloudDevice[];
  accountId: string;
  onForget: (id: string) => void;
}) {
  return (
    <section className="card" aria-label="Devices">
      <div className="chart-title">Devices</div>
      <p className="tile-note">
        Each holds its own key. Removing one stops it decrypting anything new
        within fifteen minutes, and needs no action on any machine.
      </p>
      <ul className="key-list">
        {devices.map((device) => (
          <li key={device.id} className="row-between">
            <div>
              <div className="machine-name">{device.name}</div>
              <p className="tile-note">
                {device.kind}
                {device.account_id === accountId ? " · yours" : ""} · added{" "}
                {new Date(device.created_at).toLocaleDateString()}
              </p>
            </div>
            <button
              className="btn btn-small btn-deny"
              onClick={() => onForget(device.id)}
            >
              Remove
            </button>
          </li>
        ))}
      </ul>
    </section>
  );
}

/* --------------------------------------------------------------------- members */

function Members({
  cloud,
  role,
  atLimit,
  onChanged,
  onError,
  onBilling,
}: {
  cloud: CloudClient;
  role: Role;
  atLimit: boolean;
  onChanged: () => void;
  onError: (message: string) => void;
  onBilling: () => void;
}) {
  const [members, setMembers] = useState<MemberView[] | null>(null);
  const [open, setOpen] = useState(false);
  const [email, setEmail] = useState("");
  const [invited, setInvited] = useState<Role>("member");

  const canAdminister = role === "admin" || role === "owner";

  const load = () => {
    cloud
      .members()
      .then(setMembers)
      .catch((cause: unknown) => onError(readableError(cause)));
  };

  const toggle = () => {
    const next = !open;
    setOpen(next);
    if (next && members === null) load();
  };

  return (
    <section className="card" aria-label="People">
      <button className="disclosure" onClick={toggle} aria-expanded={open}>
        <span className="chart-title">People</span>
        <span aria-hidden="true">{open ? "−" : "+"}</span>
      </button>

      {open ? (
        <>
          <ul className="key-list">
            {(members ?? []).map((member) => (
              <li key={member.id} className="row-between">
                <div>
                  <div className="machine-name">{member.display_name}</div>
                  <p className="tile-note">
                    {member.email} · {member.role} — {ROLE_BLURB[member.role]}
                  </p>
                </div>
                {canAdminister ? (
                  <button
                    className="btn btn-small btn-deny"
                    onClick={() => {
                      cloud
                        .removeMember(member.id)
                        .then(() => {
                          load();
                          onChanged();
                        })
                        .catch((cause: unknown) => onError(readableError(cause)));
                    }}
                  >
                    Remove
                  </button>
                ) : null}
              </li>
            ))}
          </ul>

          {canAdminister ? (
            atLimit ? (
              <div className="notice">
                <p className="tile-note">
                  Your plan has no room for another person.
                </p>
                <button className="btn btn-primary" onClick={onBilling}>
                  See plans
                </button>
              </div>
            ) : (
              <div className="inline-form">
                <input
                  className="pair-input"
                  value={email}
                  onChange={(event) => setEmail(event.target.value)}
                  placeholder="Their email"
                  autoCapitalize="none"
                  spellCheck={false}
                />
                <select
                  className="pair-input"
                  value={invited}
                  onChange={(event) => setInvited(event.target.value as Role)}
                >
                  <option value="viewer">Viewer</option>
                  <option value="member">Member</option>
                  <option value="admin">Admin</option>
                </select>
                <button
                  className="btn btn-primary"
                  disabled={!email.trim()}
                  onClick={() => {
                    cloud
                      .addMember(email.trim(), invited)
                      .then(() => {
                        setEmail("");
                        load();
                        onChanged();
                      })
                      .catch((cause: unknown) => onError(readableError(cause)));
                  }}
                >
                  Add
                </button>
              </div>
            )
          ) : null}

          <p className="tile-note">
            They need an account first — there is no email being sent from here,
            and a button that silently does nothing would be worse than saying so.
          </p>
        </>
      ) : null}
    </section>
  );
}

/* --------------------------------------------------------------------- billing */

export function BillingScreen({
  billing,
  cloud,
  role,
  onError,
}: {
  billing: BillingState;
  cloud: CloudClient;
  role: Role;
  onError: (message: string) => void;
}) {
  const [busy, setBusy] = useState<Plan | "portal" | null>(null);
  const notice = subscriptionNotice(billing.subscription);
  const isOwner = role === "owner";

  const go = (work: Promise<{ url: string }>, tag: Plan | "portal") => {
    setBusy(tag);
    work
      .then(({ url }) => {
        location.href = url;
      })
      .catch((cause: unknown) => {
        onError(readableError(cause));
        setBusy(null);
      });
  };

  return (
    <>
      {notice ? (
        <div className="card notice-card" role="status">
          <p className="tile-note">{notice}</p>
        </div>
      ) : null}

      {!billing.enabled ? (
        <div className="card" role="status">
          <div className="chart-title">Self-hosted</div>
          <p className="tile-note">
            No payment provider is configured on this deployment, so every
            workspace runs on the Free plan&rsquo;s limits. The plans below are
            what a hosted deployment would offer.
          </p>
        </div>
      ) : null}

      <div className="plan-grid">
        {billing.plans.map((card) => (
          <section
            key={card.plan}
            className={card.current ? "card plan-card is-current" : "card plan-card"}
            aria-label={`${card.name} plan`}
          >
            <div className="row-between">
              <div className="chart-title">{card.name}</div>
              {card.current ? <span className="badge badge-active">Current</span> : null}
            </div>

            <div className="plan-price">
              {formatPrice(card.monthly_cents)}
              {card.monthly_cents > 0 ? (
                <span className="plan-period">/month</span>
              ) : null}
            </div>

            <ul className="plan-features">
              <li>{describeLimit(card.limits.runners)} machines</li>
              <li>{describeLimit(card.limits.devices)} devices</li>
              <li>
                {describeLimit(card.limits.members)}{" "}
                {card.limits.members === 1 ? "person" : "people"}
              </li>
              <li>{card.limits.history_days} days of cost history</li>
              <li className={card.limits.batch_queue ? undefined : "feature-off"}>
                {card.limits.batch_queue ? "Batch queue (50% cheaper)" : "No batch queue"}
              </li>
              <li className={card.limits.audit_log ? undefined : "feature-off"}>
                {card.limits.audit_log ? "Exportable audit log" : "No audit log"}
              </li>
            </ul>

            {card.current ? (
              billing.subscription.customer_id && isOwner ? (
                <button
                  className="btn"
                  disabled={busy !== null}
                  onClick={() => go(cloud.billingPortal(), "portal")}
                >
                  {busy === "portal" ? "…" : "Manage subscription"}
                </button>
              ) : null
            ) : card.purchasable ? (
              <button
                className="btn btn-primary"
                disabled={busy !== null || !isOwner}
                title={isOwner ? undefined : "Only the workspace owner can change the plan"}
                onClick={() => go(cloud.checkout(card.plan), card.plan)}
              >
                {busy === card.plan ? "…" : `Choose ${card.name}`}
              </button>
            ) : (
              <button className="btn" disabled>
                {card.monthly_cents === 0 ? "Always available" : "Not available here"}
              </button>
            )}
          </section>
        ))}
      </div>

      <section className="card">
        <div className="chart-title">In use now</div>
        <div className="usage-grid">
          <UsageTile
            label="Machines"
            used={billing.usage.runners}
            limit={
              billing.plans.find((card) => card.current)?.limits.runners ?? 0
            }
          />
          <UsageTile
            label="Devices"
            used={billing.usage.devices}
            limit={
              billing.plans.find((card) => card.current)?.limits.devices ?? 0
            }
          />
          <UsageTile
            label="People"
            used={billing.usage.members}
            limit={
              billing.plans.find((card) => card.current)?.limits.members ?? 0
            }
          />
        </div>
      </section>
    </>
  );
}
