import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { Client, pairGlasses, signUpOwner } from "./helpers.ts";

async function start(glasses: Client) {
  const res = await glasses.post("/api/device/start", { clientName: "Ray-Ban Display" });
  expect(res.status).toBe(200);
  return (await res.json()) as { deviceCode: string; userCode: string; verificationUri: string; interval: number };
}

describe("pairing glasses (device flow)", () => {
  it("issues a short code and a long secret, storing neither in the clear", async () => {
    const codes = await start(new Client());
    expect(codes.userCode).toMatch(/^[BCDFGHJKLMNPQRSTVWXZ]{4}-[BCDFGHJKLMNPQRSTVWXZ]{4}$/);
    expect(codes.deviceCode.length).toBeGreaterThanOrEqual(40);
    expect(codes.verificationUri).toBe("http://localhost/link");
    const row = await env.DB.prepare("SELECT device_code_hash FROM device_codes").first<{ device_code_hash: string }>();
    expect(row?.device_code_hash).not.toBe(codes.deviceCode);
  });

  it("goes pending, then approved once, and gives the glasses their own session", async () => {
    const owner = new Client();
    await signUpOwner(owner);
    const glasses = new Client();
    const codes = await start(glasses);

    const pending = await glasses.post("/api/device/poll", { deviceCode: codes.deviceCode });
    expect(await pending.json()).toEqual({ status: "pending" });
    // Polling faster than the interval is told to slow down.
    const fast = await glasses.post("/api/device/poll", { deviceCode: codes.deviceCode });
    expect(await fast.json()).toEqual({ status: "slow_down" });

    const lookup = await owner.post("/api/device/lookup", { userCode: codes.userCode.toLowerCase() });
    expect(await lookup.json()).toMatchObject({ clientName: "Ray-Ban Display" });
    expect((await owner.post("/api/device/decide", { userCode: codes.userCode, decision: "approve" })).status).toBe(204);

    const approved = await glasses.post("/api/device/poll", { deviceCode: codes.deviceCode });
    expect(await approved.json()).toMatchObject({ status: "approved", user: { role: "owner" } });
    const me = (await (await glasses.get("/api/me")).json()) as { session: { kind: string } };
    expect(me.session.kind).toBe("glasses");

    // The code is spent: a second poll gets nothing.
    const again = new Client();
    const replay = await again.post("/api/device/poll", { deviceCode: codes.deviceCode });
    expect(await replay.json()).toEqual({ status: "expired" });
    expect(again.cookie).toBe("");
  });

  it("can be denied", async () => {
    const owner = new Client();
    await signUpOwner(owner);
    const glasses = new Client();
    const codes = await start(glasses);
    await owner.post("/api/device/decide", { userCode: codes.userCode, decision: "deny" });
    const res = await glasses.post("/api/device/poll", { deviceCode: codes.deviceCode });
    expect(await res.json()).toEqual({ status: "denied" });
    expect(glasses.cookie).toBe("");
  });

  it("only lets a console session approve", async () => {
    const owner = new Client();
    await signUpOwner(owner);
    const paired = await pairGlasses(owner);
    const codes = await start(new Client());
    const res = await paired.post("/api/device/decide", { userCode: codes.userCode, decision: "approve" });
    expect(res.status).toBe(403);
    expect((await new Client().post("/api/device/decide", { userCode: codes.userCode, decision: "approve" })).status).toBe(401);
  });

  it("expires codes", async () => {
    const owner = new Client();
    await signUpOwner(owner);
    const glasses = new Client();
    const codes = await start(glasses);
    await env.DB.prepare("UPDATE device_codes SET expires_at = 0").run();
    expect((await owner.post("/api/device/lookup", { userCode: codes.userCode })).status).toBe(404);
    const res = await glasses.post("/api/device/poll", { deviceCode: codes.deviceCode });
    expect(await res.json()).toEqual({ status: "expired" });
  });

  it("signs the glasses out when their session is revoked from the console", async () => {
    const owner = new Client();
    await signUpOwner(owner);
    const glasses = await pairGlasses(owner);
    const sessions = (await (await owner.get("/api/sessions")).json()) as {
      items: { id: string; kind: string; current: boolean }[];
    };
    expect(sessions.items).toHaveLength(2);
    const target = sessions.items.find((s) => s.kind === "glasses")!;
    expect((await owner.delete(`/api/sessions/${target.id}`)).status).toBe(204);
    expect((await glasses.get("/api/me")).status).toBe(401);
    expect((await owner.get("/api/me")).status).toBe(200);
  });
});
