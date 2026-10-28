/**
 * The client for the control plane: accounts, workspaces, machines, plans.
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
 *   a race: whoever uses it second is signed out, which is a signal the user
 *   can act on.
 *
 * The access token is not persisted for the same reason a password is not: it
 * is a bearer credential with a short life, and writing it to disk to save one
 * round trip on a cold start is a bad trade.
 */

import { getMigrating } from "./legacy.ts";
import { ApiError } from "./api.ts";
import { Identity, type DeviceKind } from "./crypto.ts";

/* ---------------------------------------------------------------- the types */

/** Mirrors `farhelm_cloud::plan::Plan`. */
export type Plan = "free" | "pro" | "team";

/** Mirrors `farhelm_crypto::token::Role`. Ordered by capability. */
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

/** A machine waiting to be let into the workspace. */
export interface PendingDevice {
  /** Normalised: upper case, no dash. */
  user_code: string;
  /**
   * What the machine calls itself, the only thing a human has to go on when
   * deciding, so it is shown prominently rather than as a subtitle.
   */
  name: string;
  version: string;
  status: "pending" | "approved" | "denied";
  created_at: number;
  expires_at: number;
}

export interface DeviceDecision {
  user_code: string;
  name: string;
  status: "pending" | "approved" | "denied";
}

/**
 * Codes are shown as `BKPT-4QW9` and typed every other way.
 *
 * The server normalises too; this is so the URL a person is looking at matches
 * what they typed, not a correctness measure.
 */
export function normaliseUserCode(code: string): string {
  return code.replace(/[^a-zA-Z0-9]/g, "").toUpperCase();
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

export const CLOUD_SESSION_STORAGE_KEY = "farhelm-cloud-session";
/** What it was called before the rename. See `legacy.ts`. */
export const LEGACY_CLOUD_SESSION_STORAGE_KEY = "forge-cloud-session";

/**
 * Where this device's own keypair is kept, deliberately *not* inside the
 * session.
 *
 * A device seat is a property of the device, not of a sign-in. Storing the key
 * with the session meant signing out destroyed it, so signing back in generated
 * a fresh key, registered a *new* device, and consumed another seat. Two
 * sign-outs on a two-device plan was enough to lock the account out of its own
 * workspace.
 */
export const DEVICE_KEY_STORAGE_KEY = "farhelm-device-key";
/** What it was called before the rename. See `legacy.ts`. */
export const LEGACY_DEVICE_KEY_STORAGE_KEY = "forge-device-key";

/**
 * This device's long-term identity, created once and reused for every later
 * sign-in.
 */
export async function deviceIdentity(backend: {
  get(key: string): Promise<string | null>;
  set(key: string, value: string): Promise<void>;
}): Promise<Identity> {
  // The legacy key is read but not deleted: this backend has no `remove`, and
  // the seat this key holds is worth more than a stale entry is worth tidying.
  // Missing it would generate a fresh identity and consume a second seat,
  // precisely the failure the comment above this function describes.
  const stored =
    (await backend.get(DEVICE_KEY_STORAGE_KEY)) ??
    (await backend.get(LEGACY_DEVICE_KEY_STORAGE_KEY));
  if (stored) {
    try {
      const identity = Identity.fromSecret(stored);
      await backend.set(DEVICE_KEY_STORAGE_KEY, stored);
      return identity;
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
 * unusable: a session whose key cannot decrypt anything is worse than no
 * session, because it looks signed in and fails at the first approval.
 */
export function cloudSessionStore(backend: {
  get(key: string): Promise<string | null>;
  set(key: string, value: string): Promise<void>;
  remove(key: string): Promise<void>;
}): CloudSessionStore {
  return {
    async load() {
      const raw = await getMigrating(
        backend,
        CLOUD_SESSION_STORAGE_KEY,
        LEGACY_CLOUD_SESSION_STORAGE_KEY,
      );
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

/** How long a failed refresh waits before its one retry. Well inside the
 *  server's grace window for the previous token. */
const REFRESH_RETRY_MS = 2_000;

export class CloudClient {
  private accessToken: string | null = null;
  private accessExpiresAt = 0;
  /** In flight refresh, so ten parallel calls do not rotate ten times. */
  private refreshing: Promise<void> | null = null;
  /**
   * Tokens this client has rotated away from. Persisting a rotation is
   * asynchronous, so storage can briefly still hold the token just replaced;
   * adopting it back would be a replay of this client's own old token.
   */
  private readonly retired: string[] = [];

  constructor(
    readonly baseUrl: string,
    private refreshToken: string | null = null,
    /** Called whenever the refresh token rotates, so it can be persisted. */
    private readonly onRotate: (refreshToken: string) => void = () => {},
    /**
     * The refresh token as persisted right now, if the platform can say.
     *
     * Read before every refresh. Another tab, or a service worker, sharing
     * this storage may have rotated the token since this client loaded it;
     * presenting the stale one is a replay, and the server ends the session
     * for replays (see `rotate_refresh_token` in farhelm-cloud).
     */
    private readonly storedRefreshToken: (() => Promise<string | null>) | null = null,
  ) {}

  get isSignedIn(): boolean {
    return this.refreshToken !== null;
  }

  private url(path: string): string {
    return `${this.baseUrl.replace(/\/$/, "")}${path}`;
  }

  /** Bound the entire exchange, including a body that stalls after headers. */
  private async exchange<T>(path: string, init: RequestInit, read: (response: Response) => Promise<T>): Promise<T> {
    const controller = new AbortController();
    const deadline = setTimeout(() => controller.abort(), 20_000);
    try {
      const response = await fetch(this.url(path), {
        ...init, signal: controller.signal, redirect: "error", credentials: "omit",
      });
      return await read(response);
    } catch (cause) {
      if (controller.signal.aborted) {
        throw new CloudError("The workspace server took too long to respond. Check its address and try again.", 0);
      }
      if (cause instanceof CloudError) throw cause;
      throw new CloudError("Cannot reach the workspace server. Check its address and your connection.", 0);
    } finally {
      clearTimeout(deadline);
    }
  }

  private async json<T>(response: Response): Promise<T> {
    const contentType = response.headers.get("content-type")?.split(";", 1)[0]?.trim().toLowerCase();
    if (contentType !== "application/json" && !contentType?.endsWith("+json")) {
      throw new CloudError("This address did not return the workspace API. Check the workspace server address.", response.status);
    }
    try { return await response.json() as T; }
    catch { throw new CloudError("The workspace server returned an invalid response. Try again or check the server address.", response.status); }
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

    const result = await this.exchange(path, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    }, async (response) => {
      // Return the refusal outside this exchange before attempting a refresh;
      // otherwise two request deadlines would cover the same token rotation.
      if (response.status === 401 && auth && retry && this.refreshToken) return { retry: true } as const;
      if (!response.ok) throw await this.refusal(response, path);
      return { retry: false, value: response.status === 204 ? undefined as T : await this.json<T>(response) } as const;
    });

    if (result.retry) {
      this.accessToken = null;
      await this.ensureFresh();
      return this.call<T>(method, path, body, { auth, retry: false });
    }
    return result.value;
  }

  private async refusal(response: Response, path = ""): Promise<CloudError> {
    let message = response.statusText || `request failed (${response.status})`;
    if ([502, 503, 504].includes(response.status)) {
      message = `The workspace server is unavailable (${response.status}). Check the server address or try again when the service is running.`;
    } else if (response.status === 404 && path.startsWith("/v1/auth/")) {
      message = "This server does not provide account sign-in. Check the workspace server address.";
    }
    let upgradeTo: Plan | null = null;
    try {
      const body = (await response.json()) as {
        error?: string;
        upgrade_to?: Plan | null;
      };
      if (typeof body?.error === "string" && body.error.length > 0) message = body.error;
      if (body?.upgrade_to === "free" || body?.upgrade_to === "pro" || body?.upgrade_to === "team") upgradeTo = body.upgrade_to;
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
    await this.adoptStored();
    const presented = this.refreshToken;
    try {
      await this.rotate();
    } catch (cause) {
      if (!(cause instanceof CloudError)) throw cause;
      if (cause.status === 0 || cause.status >= 502) {
        // Unreachable, or the gateway answered for a server it could not
        // reach. The server may already have rotated the token and lost the
        // reply; it accepts the previous token for a short grace window, so one
        // prompt retry recovers a dropped tunnel connection.
        await new Promise((resolve) => setTimeout(resolve, REFRESH_RETRY_MS));
        await this.rotate();
        return;
      }
      // Refused. If another tab rotated the session after this one last
      // looked, storage now holds the live token: use it rather than sign out.
      if ((cause.status === 401 || cause.status === 403) && presented && await this.adoptStored(presented)) {
        await this.rotate();
        return;
      }
      throw cause;
    }
  }

  /**
   * Take the persisted token when it is newer than the one held here.
   *
   * Never one this client has itself rotated away from (storage can lag a
   * rotation), nor `refused`, the token the server just turned down.
   */
  private async adoptStored(refused: string | null = null): Promise<boolean> {
    if (!this.storedRefreshToken) return false;
    const stored = await this.storedRefreshToken().catch(() => null);
    if (!stored || stored === refused || stored === this.refreshToken || this.retired.includes(stored)) {
      return false;
    }
    this.refreshToken = stored;
    return true;
  }

  private async rotate(): Promise<void> {
    if (!this.refreshToken) throw new CloudError("sign in to continue", 401);
    const body = await this.exchange("/v1/auth/refresh", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refresh_token: this.refreshToken }),
    }, async (response) => {
      if (!response.ok) {
        // An upstream outage is recoverable. Retain the refresh credential so
        // a transient 502 cannot silently turn into a forced sign-out.
        if (response.status === 401 || response.status === 403) {
          this.refreshToken = null;
          this.accessToken = null;
        }
        throw await this.refusal(response, "/v1/auth/refresh");
      }
      return this.json<{ access_token: string; access_expires_at: number; refresh_token: string }>(response);
    });
    this.validateTokens(body);
    if (this.refreshToken) {
      this.retired.push(this.refreshToken);
      if (this.retired.length > 4) this.retired.shift();
    }
    this.accessToken = body.access_token;
    this.accessExpiresAt = body.access_expires_at;
    this.refreshToken = body.refresh_token;
    this.onRotate(body.refresh_token);
  }

  private adopt(auth: AuthResponse): Workspace {
    this.validateTokens(auth);
    if (!auth.workspace || typeof auth.workspace !== "object") {
      throw new CloudError("The workspace server returned an invalid sign-in response.", 502);
    }
    this.accessToken = auth.access_token;
    this.accessExpiresAt = auth.access_expires_at;
    this.refreshToken = auth.refresh_token;
    this.onRotate(auth.refresh_token);
    return auth.workspace;
  }

  private validateTokens(value: { access_token: string; access_expires_at: number; refresh_token: string }): void {
    if (!value || typeof value.access_token !== "string" || !value.access_token
      || typeof value.refresh_token !== "string" || !value.refresh_token
      || !Number.isSafeInteger(value.access_expires_at) || value.access_expires_at <= Date.now()) {
      throw new CloudError("The workspace server returned an invalid sign-in response.", 502);
    }
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
      await this.exchange("/v1/auth/logout", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ refresh_token: token }),
      }, async () => undefined);
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

  /* ------------------------------------------------------- self-enrolment */

  /**
   * What a machine that ran `farhelm login` is waiting to be told.
   *
   * The code is normalised here rather than at the call sites: people type it
   * off a terminal with or without its dash, in either case.
   */
  pendingDevice(userCode: string): Promise<PendingDevice> {
    return this.call<PendingDevice>(
      "GET",
      `/v1/device/${normaliseUserCode(userCode)}`,
    );
  }

  /** Let it in. This is what mints its enrolment key. */
  approveDevice(userCode: string): Promise<DeviceDecision> {
    return this.call<DeviceDecision>(
      "POST",
      `/v1/device/${normaliseUserCode(userCode)}/approve`,
    );
  }

  denyDevice(userCode: string): Promise<DeviceDecision> {
    return this.call<DeviceDecision>(
      "POST",
      `/v1/device/${normaliseUserCode(userCode)}/deny`,
    );
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
 * Used to disable an action *before* the server refuses it: a button that
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
 * saying. That is the common case, and a banner that is always present is a banner
 * nobody reads.
 */
export function subscriptionNotice(subscription: Subscription): string | null {
  if (subscription.status === "past_due") {
    return "A payment did not go through. Everything keeps working; update your card to avoid losing the plan.";
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
