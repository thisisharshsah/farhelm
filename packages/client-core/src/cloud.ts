/**
 * The client for the control plane — accounts, workspaces, machines, plans.
 *
 * This is the half of the app that replaced pairing. The old flow was: run a
 * command on the runner, read a QR, paste a JSON blob, be on the same network.
 * The new one is: sign in. Machines enrol themselves and appear in the fleet;
 * a device asks the control plane for a seat on one and gets the runner's
 * public key back over an authenticated call rather than out of a photograph.
 *
 * # What has *not* changed
 *
 * The device keypair is still generated here and its secret half still never
 * leaves the device. Every message on a channel is still sealed with it. The
 * control plane hands out addresses and permissions; it has no key that opens
 * anything, and none of the code below sends it one.
 *
 * # Token handling
 *
 * Two tokens, deliberately different:
 *
 * - an **access token**, an hour, held in memory only. Sent on every call.
 * - a **refresh token**, a month, persisted, and *rotated on every use*. A
 *   stolen refresh token therefore stops being a permanent foothold and becomes
 *   a race — whoever uses it second is signed out, which is a signal the user
 *   can act on.
 *
 * The access token is not persisted for the same reason a password is not: it
 * is a bearer credential with a short life, and writing it to disk to save one
 * round trip on a cold start is a bad trade.
 */

import { ApiError } from "./api.ts";
import { Identity, type DeviceKind } from "./crypto.ts";

/* ---------------------------------------------------------------- the types */

/** Mirrors `forge_cloud::plan::Plan`. */
export type Plan = "free" | "pro" | "team";

/** Mirrors `forge_crypto::token::Role`. Ordered by capability. */
export type Role = "viewer" | "runner" | "member" | "admin" | "owner";

export type SubscriptionStatus = "active" | "past_due" | "canceled";

export interface Limits {
  runners: number;
  devices: number;
  members: number;
  relay_messages_per_minute: number;
  history_days: number;
  batch_queue: boolean;
  audit_log: boolean;
}

/** `u32::MAX` is how the server spells "no limit". */
export const UNLIMITED = 4294967295;

export interface Usage {
  runners: number;
  devices: number;
  members: number;
}

export interface Account {
  id: string;
  email: string;
  display_name: string;
  created_at: number;
  last_seen_at: number;
}

export interface Org {
  id: string;
  name: string;
  slug: string;
  created_at: number;
}

export interface Subscription {
  org_id: string;
  plan: Plan;
  status: SubscriptionStatus;
  customer_id: string | null;
  subscription_id: string | null;
  current_period_end: number | null;
  cancel_at_period_end: boolean;
  updated_at: number;
}

export interface RunnerView {
  id: string;
  org_id: string;
  name: string;
  public_key: string;
  pending_public_key: string | null;
  channel: string;
  created_at: number;
  last_seen_at: number;
  version: string;
  online: boolean;
  needs_key_approval: boolean;
}

export interface CloudDevice {
  id: string;
  org_id: string;
  account_id: string;
  kind: DeviceKind;
  name: string;
  public_key: string;
  created_at: number;
  last_seen_at: number;
}

export interface Workspace {
  account: Account;
  org: Org;
  role: Role;
  subscription: Subscription;
  limits: Limits;
  usage: Usage;
  runners: RunnerView[];
  devices: CloudDevice[];
  relay_url: string;
}

export interface MemberView extends Account {
  role: Role;
}

export interface EnrollmentKey {
  id: string;
  org_id: string;
  name: string;
  prefix: string;
  created_at: number;
  created_by: string;
  last_used_at: number | null;
  revoked_at: number | null;
}

export interface PlanCard {
  plan: Plan;
  name: string;
  monthly_cents: number;
  limits: Limits;
  purchasable: boolean;
  current: boolean;
}

export interface BillingState {
  enabled: boolean;
  subscription: Subscription;
  usage: Usage;
  plans: PlanCard[];
}

/** A seat on one machine's channel. Fifteen minutes. */
export interface ChannelSeat {
  token: string;
  expires_at: number;
  channel: string;
  relay_url: string;
  runner_public_key: string;
}

/**
 * What a signed-in device persists.
 *
 * The device secret lives here rather than in a separate record because the two
 * are useless apart: a key with no account cannot ask for a seat, and an account
 * with no key cannot decrypt anything it would be given.
 */
export interface CloudSession {
  baseUrl: string;
  refreshToken: string;
  accountId: string;
  orgId: string;
  /** Assigned by the control plane when this device registered its key. */
  deviceId: string;
  /** base64url X25519 secret. Never sent anywhere. */
  deviceSecret: string;
}

/** Where a signed-in session is kept. Async because React Native's store is. */
export interface CloudSessionStore {
  load(): Promise<CloudSession | null>;
  save(session: CloudSession): Promise<void>;
  clear(): Promise<void>;
}

export const CLOUD_SESSION_STORAGE_KEY = "forge-cloud-session";

/**
 * Where this device's own keypair is kept — deliberately *not* inside the
 * session.
 *
 * A device seat is a property of the device, not of a sign-in. Storing the key
 * with the session meant signing out destroyed it, so signing back in generated
 * a fresh key, registered a *new* device, and consumed another seat. Two
 * sign-outs on a two-device plan was enough to lock the account out of its own
 * workspace.
 */
export const DEVICE_KEY_STORAGE_KEY = "forge-device-key";

/**
 * This device's long-term identity, created once and reused for every later
 * sign-in.
 */
export async function deviceIdentity(backend: {
  get(key: string): Promise<string | null>;
  set(key: string, value: string): Promise<void>;
}): Promise<Identity> {
  const stored = await backend.get(DEVICE_KEY_STORAGE_KEY);
  if (stored) {
    try {
      return Identity.fromSecret(stored);
    } catch {
      // A corrupt key is worth replacing; a *missing* one is not worth
      // inventing a second time.
    }
  }
  const identity = Identity.generate();
  await backend.set(DEVICE_KEY_STORAGE_KEY, identity.toSecret());
  return identity;
}

/**
 * Build a [`CloudSessionStore`] over any get/set/remove trio.
 *
 * Validates the stored device secret on load and drops the session if it is
 * unusable — a session whose key cannot decrypt anything is worse than no
 * session, because it looks signed in and fails at the first approval.
 */
export function cloudSessionStore(backend: {
  get(key: string): Promise<string | null>;
  set(key: string, value: string): Promise<void>;
  remove(key: string): Promise<void>;
}): CloudSessionStore {
  return {
    async load() {
      const raw = await backend.get(CLOUD_SESSION_STORAGE_KEY);
      if (!raw) return null;
      try {
        const session = JSON.parse(raw) as CloudSession;
        Identity.fromSecret(session.deviceSecret);
        if (!session.refreshToken || !session.baseUrl) throw new Error("incomplete");
        return session;
      } catch {
        await backend.remove(CLOUD_SESSION_STORAGE_KEY);
        return null;
      }
    },
    async save(session) {
      await backend.set(CLOUD_SESSION_STORAGE_KEY, JSON.stringify(session));
    },
    async clear() {
      await backend.remove(CLOUD_SESSION_STORAGE_KEY);
    },
  };
}

/* --------------------------------------------------------------- the client */

/** Refresh this long before the access token actually expires. */
const REFRESH_MARGIN_MS = 60_000;

interface AuthResponse {
  access_token: string;
  access_expires_at: number;
  refresh_token: string;
  workspace: Workspace;
}

/**
 * A refusal the user can act on.
 *
 * `upgradeTo` is set when the server refused because of a plan limit, so a
 * screen can offer the upgrade rather than rendering a dead end.
 */
export class CloudError extends ApiError {
  constructor(
    message: string,
    status: number,
    readonly upgradeTo: Plan | null = null,
  ) {
    super(message, status);
    this.name = "CloudError";
  }
}

export class CloudClient {
  private accessToken: string | null = null;
  private accessExpiresAt = 0;
  /** In flight refresh, so ten parallel calls do not rotate ten times. */
  private refreshing: Promise<void> | null = null;

  constructor(
    readonly baseUrl: string,
    private refreshToken: string | null = null,
    /** Called whenever the refresh token rotates, so it can be persisted. */
    private readonly onRotate: (refreshToken: string) => void = () => {},
  ) {}

  get isSignedIn(): boolean {
    return this.refreshToken !== null;
  }

  private url(path: string): string {
    return `${this.baseUrl.replace(/\/$/, "")}${path}`;
  }

  /**
   * One request, with the access token attached and refreshed if needed.
   *
   * A 401 triggers exactly one retry after a refresh. Retrying more than once
   * on an endpoint that is refusing for a *different* reason is how a client
   * ends up hammering a server that is telling it to stop.
   */
  private async call<T>(
    method: string,
    path: string,
    body?: unknown,
    options: { auth?: boolean; retry?: boolean } = {},
  ): Promise<T> {
    const { auth = true, retry = true } = options;
    if (auth) await this.ensureFresh();

    const headers: Record<string, string> = {};
    if (body !== undefined) headers["content-type"] = "application/json";
    if (auth && this.accessToken) {
      headers.authorization = `Bearer ${this.accessToken}`;
    }

    const response = await fetch(this.url(path), {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });

    if (response.status === 401 && auth && retry && this.refreshToken) {
      this.accessToken = null;
      await this.ensureFresh();
      return this.call<T>(method, path, body, { auth, retry: false });
    }

    if (!response.ok) {
      throw await this.refusal(response);
    }
    if (response.status === 204) return undefined as T;
    return (await response.json()) as T;
  }

  private async refusal(response: Response): Promise<CloudError> {
    let message = response.statusText || `request failed (${response.status})`;
    let upgradeTo: Plan | null = null;
    try {
      const body = (await response.json()) as {
        error?: string;
        upgrade_to?: Plan | null;
      };
      if (body.error) message = body.error;
      if (body.upgrade_to) upgradeTo = body.upgrade_to;
    } catch {
      /* a non-JSON error body is still an error */
    }
    return new CloudError(message, response.status, upgradeTo);
  }

  /** Get a usable access token, refreshing if it is missing or nearly stale. */
  private async ensureFresh(): Promise<void> {
    if (this.accessToken && Date.now() < this.accessExpiresAt - REFRESH_MARGIN_MS) {
      return;
    }
    if (!this.refreshToken) {
      throw new CloudError("sign in to continue", 401);
    }
    // Collapse concurrent refreshes: the token rotates, so two in flight means
    // one of them is guaranteed to be rejected and sign the user out.
    this.refreshing ??= this.doRefresh().finally(() => {
      this.refreshing = null;
    });
    await this.refreshing;
  }

  private async doRefresh(): Promise<void> {
    const response = await fetch(this.url("/v1/auth/refresh"), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refresh_token: this.refreshToken }),
    });
    if (!response.ok) {
      this.refreshToken = null;
      this.accessToken = null;
      throw await this.refusal(response);
    }
    const body = (await response.json()) as {
      access_token: string;
      access_expires_at: number;
      refresh_token: string;
    };
    this.accessToken = body.access_token;
    this.accessExpiresAt = body.access_expires_at;
    this.refreshToken = body.refresh_token;
    this.onRotate(body.refresh_token);
  }

  private adopt(auth: AuthResponse): Workspace {
    this.accessToken = auth.access_token;
    this.accessExpiresAt = auth.access_expires_at;
    this.refreshToken = auth.refresh_token;
    this.onRotate(auth.refresh_token);
    return auth.workspace;
  }

  /* ------------------------------------------------------------------ auth */

  async signUp(input: {
    email: string;
    password: string;
    name: string;
    orgName?: string;
    deviceLabel?: string;
  }): Promise<Workspace> {
    const auth = await this.call<AuthResponse>(
      "POST",
      "/v1/auth/signup",
      {
        email: input.email,
        password: input.password,
        name: input.name,
        org_name: input.orgName ?? null,
        device_label: input.deviceLabel ?? null,
      },
      { auth: false },
    );
    return this.adopt(auth);
  }

  async signIn(input: {
    email: string;
    password: string;
    deviceLabel?: string;
  }): Promise<Workspace> {
    const auth = await this.call<AuthResponse>(
      "POST",
      "/v1/auth/login",
      {
        email: input.email,
        password: input.password,
        device_label: input.deviceLabel ?? null,
      },
      { auth: false },
    );
    return this.adopt(auth);
  }

  /**
   * Sign out. Revokes the refresh token server-side so the session cannot be
   * resumed from a copy of local storage.
   */
  async signOut(): Promise<void> {
    const token = this.refreshToken;
    this.refreshToken = null;
    this.accessToken = null;
    if (!token) return;
    try {
      await fetch(this.url("/v1/auth/logout"), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ refresh_token: token }),
      });
    } catch {
      // Already signed out locally, which is the part that matters to the
      // person holding the device. The token expires on its own.
    }
  }

  changePassword(current: string, next: string): Promise<void> {
    return this.call("POST", "/v1/account/password", { current, next });
  }

  /* ------------------------------------------------------------- workspace */

  workspace(): Promise<Workspace> {
    return this.call<Workspace>("GET", "/v1/workspace");
  }

  runners(): Promise<RunnerView[]> {
    return this.call<RunnerView[]>("GET", "/v1/runners");
  }

  renameRunner(id: string, name: string): Promise<RunnerView> {
    return this.call<RunnerView>("PATCH", `/v1/runners/${id}`, { name });
  }

  approveRunnerKey(id: string): Promise<RunnerView> {
    return this.call<RunnerView>("POST", `/v1/runners/${id}/approve-key`, {});
  }

  forgetRunner(id: string): Promise<void> {
    return this.call("DELETE", `/v1/runners/${id}`);
  }

  members(): Promise<MemberView[]> {
    return this.call<MemberView[]>("GET", "/v1/members");
  }

  addMember(email: string, role: Role): Promise<MemberView> {
    return this.call<MemberView>("POST", "/v1/members", { email, role });
  }

  removeMember(accountId: string): Promise<void> {
    return this.call("DELETE", `/v1/members/${accountId}`);
  }

  /* --------------------------------------------------------------- devices */

  /**
   * Register this device's public key.
   *
   * Idempotent on the key, so a browser that re-opens with the same stored
   * identity does not consume a second device seat.
   */
  registerDevice(input: {
    kind: DeviceKind;
    name: string;
    publicKey: string;
  }): Promise<CloudDevice> {
    return this.call<CloudDevice>("POST", "/v1/devices", {
      kind: input.kind,
      name: input.name,
      public_key: input.publicKey,
    });
  }

  devices(): Promise<CloudDevice[]> {
    return this.call<CloudDevice[]>("GET", "/v1/devices");
  }

  forgetDevice(id: string): Promise<void> {
    return this.call("DELETE", `/v1/devices/${id}`);
  }

  /** A seat on one machine's relay channel. */
  channelToken(runnerId: string, deviceId: string): Promise<ChannelSeat> {
    return this.call<ChannelSeat>("POST", "/v1/channel-token", {
      runner_id: runnerId,
      device_id: deviceId,
    });
  }

  /* ------------------------------------------------------- enrolment keys */

  enrollmentKeys(): Promise<EnrollmentKey[]> {
    return this.call<EnrollmentKey[]>("GET", "/v1/enrollment-keys");
  }

  /** The plaintext comes back once and is never retrievable again. */
  createEnrollmentKey(name: string): Promise<EnrollmentKey & { token: string }> {
    return this.call<EnrollmentKey & { token: string }>(
      "POST",
      "/v1/enrollment-keys",
      { name },
    );
  }

  revokeEnrollmentKey(id: string): Promise<void> {
    return this.call("DELETE", `/v1/enrollment-keys/${id}`);
  }

  /* --------------------------------------------------------------- billing */

  billing(): Promise<BillingState> {
    return this.call<BillingState>("GET", "/v1/billing");
  }

  checkout(plan: Plan): Promise<{ url: string }> {
    return this.call<{ url: string }>("POST", "/v1/billing/checkout", { plan });
  }

  billingPortal(): Promise<{ url: string }> {
    return this.call<{ url: string }>("POST", "/v1/billing/portal", {});
  }
}

/* --------------------------------------------------------------- utilities */

/** Render a limit, with the sentinel spelled the way a person would say it. */
export function describeLimit(value: number): string {
  return value === UNLIMITED ? "Unlimited" : String(value);
}

/**
 * Whether a plan's allowance for something has run out.
 *
 * Used to disable an action *before* the server refuses it — a button that
 * explains why it is unavailable beats one that fails when pressed.
 */
export function isAtLimit(used: number, limit: number): boolean {
  return limit !== UNLIMITED && used >= limit;
}

/** `900` → `$9`, `2900` → `$29`, `0` → `Free`. */
export function formatPrice(cents: number): string {
  if (cents === 0) return "Free";
  const dollars = cents / 100;
  return Number.isInteger(dollars) ? `$${dollars}` : `$${dollars.toFixed(2)}`;
}

/**
 * A sentence for the subscription banner, or `null` when there is nothing worth
 * saying — the common case, and a banner that is always present is a banner
 * nobody reads.
 */
export function subscriptionNotice(subscription: Subscription): string | null {
  if (subscription.status === "past_due") {
    return "A payment did not go through. Everything keeps working — update your card to avoid losing the plan.";
  }
  if (subscription.status === "canceled") {
    return "This workspace is on the Free plan.";
  }
  if (subscription.cancel_at_period_end && subscription.current_period_end) {
    const when = new Date(subscription.current_period_end).toLocaleDateString();
    return `Your plan ends on ${when}. You will keep Free-plan limits after that.`;
  }
  return null;
}
