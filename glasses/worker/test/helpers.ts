import { createExecutionContext, env, waitOnExecutionContext } from "cloudflare:test";
import { createApp } from "../app.ts";
import type { WebAuthnPort } from "../webauthn.ts";

export const ORIGIN = "http://localhost";

/**
 * Stands in for an authenticator: every response "verifies", and the
 * credential is whatever id the test sends. The real library is exercised
 * end to end in the browser, with a virtual authenticator.
 */
export const fakeWebAuthn: WebAuthnPort = {
  async registrationOptions() {
    return { challenge: `reg-${crypto.randomUUID()}`, options: { rp: { id: "localhost" } } };
  },
  async verifyRegistration({ response }) {
    const id = (response as { id: string }).id;
    return id === "reject"
      ? null
      : { id, publicKey: new Uint8Array([1, 2, 3]), counter: 0, transports: ["internal"], deviceType: "multiDevice", backedUp: true };
  },
  async authenticationOptions() {
    return { challenge: `auth-${crypto.randomUUID()}`, options: {} };
  },
  async verifyAuthentication({ response, credential }) {
    return (response as { id: string }).id === credential.id ? { newCounter: credential.counter + 1 } : null;
  },
};

/** A browser-like client: keeps its cookie, sends JSON with a same-origin Origin header. */
export class Client {
  cookie = "";
  constructor(
    private readonly app = createApp({ webauthn: fakeWebAuthn, fetch: offline }),
    // Each client looks like its own device to the rate limiter.
    private readonly headers: Record<string, string> = { "cf-connecting-ip": randomIp() },
  ) {}

  async request(method: string, path: string, json?: unknown, extra: Record<string, string> = {}): Promise<Response> {
    const headers: Record<string, string> = { origin: ORIGIN, ...this.headers, ...extra };
    if (this.cookie) headers.cookie = this.cookie;
    if (json !== undefined) headers["content-type"] = "application/json";
    const ctx = createExecutionContext();
    const res = await this.app.request(
      `${ORIGIN}${path}`,
      { method, headers, body: json === undefined ? undefined : JSON.stringify(json) },
      env,
      ctx,
    );
    await waitOnExecutionContext(ctx);
    const set = res.headers.get("set-cookie");
    if (set) {
      const pair = set.split(";")[0]!;
      this.cookie = /=$/.test(pair) || /Max-Age=0/i.test(set) ? "" : pair;
    }
    return res;
  }

  get = (path: string) => this.request("GET", path);
  post = (path: string, json: unknown = {}) => this.request("POST", path, json);
  patch = (path: string, json: unknown) => this.request("PATCH", path, json);
  put = (path: string, json: unknown) => this.request("PUT", path, json);
  delete = (path: string) => this.request("DELETE", path);
}

const randomIp = () => `10.${[0, 0, 0].map(() => Math.floor(Math.random() * 255)).join(".")}`;

export async function offline(): Promise<Response> {
  throw new TypeError("network disabled in tests");
}

/** Creates the owner account through the real registration routes. */
export async function signUpOwner(client: Client, credentialId = "owner-key"): Promise<Response> {
  const start = await client.post("/api/auth/register/options", { name: "Harsh", inviteCode: "test-setup-code" });
  if (start.status !== 200) return start;
  const { challengeId } = (await start.json()) as { challengeId: string };
  return client.post("/api/auth/register/verify", { challengeId, response: { id: credentialId, type: "public-key" } });
}

export async function signUpWithInvite(client: Client, code: string, credentialId: string): Promise<Response> {
  const start = await client.post("/api/auth/register/options", { name: "Guest", inviteCode: code });
  if (start.status !== 200) return start;
  const { challengeId } = (await start.json()) as { challengeId: string };
  return client.post("/api/auth/register/verify", { challengeId, response: { id: credentialId, type: "public-key" } });
}

/** Pairs a glasses client (a fresh one by default) through the device flow, approved by `console`. */
export async function pairGlasses(console: Client, glasses = new Client()): Promise<Client> {
  const start = (await (await glasses.post("/api/device/start", { clientName: "Ray-Ban Display" })).json()) as {
    deviceCode: string;
    userCode: string;
  };
  const decided = await console.post("/api/device/decide", { userCode: start.userCode, decision: "approve" });
  if (decided.status !== 204) throw new Error(`approve failed: ${decided.status}`);
  const polled = await glasses.post("/api/device/poll", { deviceCode: start.deviceCode });
  if (((await polled.json()) as { status: string }).status !== "approved") throw new Error("not approved");
  return glasses;
}
