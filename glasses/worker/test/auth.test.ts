import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { Client, signUpOwner, signUpWithInvite } from "./helpers.ts";

describe("accounts and passkeys", () => {
  it("creates the owner with the setup code and signs them in", async () => {
    const owner = new Client();
    const res = await signUpOwner(owner);
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ user: { name: "Harsh", role: "owner" } });
    const me = await owner.get("/api/me");
    expect(await me.json()).toMatchObject({ user: { role: "owner" }, session: { kind: "console" } });
  });

  it("sets a hardened session cookie", async () => {
    const owner = new Client();
    const res = await signUpOwner(owner);
    const cookie = res.headers.get("set-cookie") ?? "";
    expect(cookie).toMatch(/^__Host-lens_session=/);
    expect(cookie).toMatch(/HttpOnly/i);
    expect(cookie).toMatch(/Secure/i);
    expect(cookie).toMatch(/SameSite=Lax/i);
  });

  it("refuses a wrong setup code and a second owner", async () => {
    const stranger = new Client();
    const bad = await stranger.post("/api/auth/register/options", { name: "X", inviteCode: "wrong-code" });
    expect(bad.status).toBe(403);

    await signUpOwner(new Client());
    // The setup code means nothing once an account exists.
    const again = await signUpOwner(new Client(), "second-key");
    expect(again.status).toBe(403);
  });

  it("lets an invite be used exactly once", async () => {
    const owner = new Client();
    await signUpOwner(owner);
    const created = (await (await owner.post("/api/invites")).json()) as { code: string };

    const guest = new Client();
    const ok = await signUpWithInvite(guest, created.code, "guest-key");
    expect(ok.status).toBe(200);
    expect(await ok.json()).toMatchObject({ user: { role: "member" } });

    const late = await signUpWithInvite(new Client(), created.code, "late-key");
    expect(late.status).toBe(403);
  });

  it("does not create an account when the invite is used between options and verify", async () => {
    const owner = new Client();
    await signUpOwner(owner);
    const { code } = (await (await owner.post("/api/invites")).json()) as { code: string };

    // Two people start with the same invite; the first finishes.
    const a = new Client();
    const b = new Client();
    const startA = (await (await a.post("/api/auth/register/options", { name: "A", inviteCode: code })).json()) as {
      challengeId: string;
    };
    const startB = (await (await b.post("/api/auth/register/options", { name: "B", inviteCode: code })).json()) as {
      challengeId: string;
    };
    expect((await a.post("/api/auth/register/verify", { challengeId: startA.challengeId, response: { id: "a", type: "public-key" } })).status).toBe(200);
    const second = await b.post("/api/auth/register/verify", {
      challengeId: startB.challengeId,
      response: { id: "b", type: "public-key" },
    });
    expect(second.status).toBe(403);
    const users = await env.DB.prepare("SELECT COUNT(*) AS n FROM users").first<{ n: number }>();
    expect(users?.n).toBe(2); // owner and A, never B
    const orphan = await env.DB.prepare("SELECT COUNT(*) AS n FROM passkeys WHERE id = 'b'").first<{ n: number }>();
    expect(orphan?.n).toBe(0);
  });

  it("signs in with a registered passkey and refuses unknown ones", async () => {
    const owner = new Client();
    await signUpOwner(owner, "my-key");
    await owner.post("/api/auth/sign-out");
    expect((await owner.get("/api/me")).status).toBe(401);

    const start = (await (await owner.post("/api/auth/sign-in/options")).json()) as { challengeId: string };
    const unknown = await owner.post("/api/auth/sign-in/verify", {
      challengeId: start.challengeId,
      response: { id: "not-mine", type: "public-key" },
    });
    expect(unknown.status).toBe(400);

    // A challenge works once: the failed attempt above used it up.
    const reused = await owner.post("/api/auth/sign-in/verify", {
      challengeId: start.challengeId,
      response: { id: "my-key", type: "public-key" },
    });
    expect(reused.status).toBe(400);

    const fresh = (await (await owner.post("/api/auth/sign-in/options")).json()) as { challengeId: string };
    const ok = await owner.post("/api/auth/sign-in/verify", {
      challengeId: fresh.challengeId,
      response: { id: "my-key", type: "public-key" },
    });
    expect(ok.status).toBe(200);
    expect((await owner.get("/api/me")).status).toBe(200);
    const counter = await env.DB.prepare("SELECT counter FROM passkeys WHERE id = 'my-key'").first<{ counter: number }>();
    expect(counter?.counter).toBe(1);
  });

  it("keeps at least one passkey on the account", async () => {
    const owner = new Client();
    await signUpOwner(owner, "only-key");
    const res = await owner.delete("/api/passkeys/only-key");
    expect(res.status).toBe(409);

    const start = (await (await owner.post("/api/passkeys/options")).json()) as { challengeId: string };
    const added = await owner.post("/api/passkeys/verify", {
      challengeId: start.challengeId,
      response: { id: "second-key", type: "public-key" },
    });
    expect(added.status).toBe(201);
    expect((await owner.delete("/api/passkeys/only-key")).status).toBe(204);
    const list = (await (await owner.get("/api/passkeys")).json()) as { items: { id: string }[] };
    expect(list.items.map((p) => p.id)).toEqual(["second-key"]);
  });

  it("records security events for the account", async () => {
    const owner = new Client();
    await signUpOwner(owner);
    await owner.post("/api/invites");
    const activity = (await (await owner.get("/api/activity")).json()) as { items: { type: string }[] };
    expect(activity.items.map((e) => e.type)).toEqual(["invite_created", "account_created"]);
  });
});
