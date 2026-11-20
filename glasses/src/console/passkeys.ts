/**
 * The browser side of passkeys: ask the server for options, let the device
 * create or use a passkey (Face ID, Touch ID, Windows Hello, a phone, or a
 * security key), and send the result back for verification.
 */
import { startAuthentication, startRegistration } from "@simplewebauthn/browser";
import { HttpError, api, messageOf } from "../client/http.ts";
import { CeremonyStart, Passkey } from "../shared/api.ts";

type RegistrationOptions = Parameters<typeof startRegistration>[0]["optionsJSON"];
type AuthenticationOptions = Parameters<typeof startAuthentication>[0]["optionsJSON"];

export const passkeysSupported = (): boolean => typeof window.PublicKeyCredential !== "undefined";

export async function signInWithPasskey(): Promise<void> {
  const start = await api("/api/auth/sign-in/options", { method: "POST", schema: CeremonyStart });
  const response = await startAuthentication({ optionsJSON: start.options as unknown as AuthenticationOptions });
  await api("/api/auth/sign-in/verify", { method: "POST", body: { challengeId: start.challengeId, response } });
}

export async function createAccount(name: string, inviteCode: string): Promise<void> {
  const start = await api("/api/auth/register/options", {
    method: "POST",
    body: { name, inviteCode },
    schema: CeremonyStart,
  });
  const response = await startRegistration({ optionsJSON: start.options as unknown as RegistrationOptions });
  await api("/api/auth/register/verify", { method: "POST", body: { challengeId: start.challengeId, response } });
}

export async function addPasskey(): Promise<Passkey> {
  const start = await api("/api/passkeys/options", { method: "POST", schema: CeremonyStart });
  const response = await startRegistration({ optionsJSON: start.options as unknown as RegistrationOptions });
  return api("/api/passkeys/verify", {
    method: "POST",
    body: { challengeId: start.challengeId, response },
    schema: Passkey,
  });
}

/** Turns WebAuthn's terse errors into something a person can act on. */
export function passkeyError(e: unknown): Error {
  if (e instanceof HttpError) return e;
  const name = (e as { name?: string } | null)?.name;
  const code = (e as { code?: string } | null)?.code;
  if (name === "NotAllowedError" || code === "ERROR_CEREMONY_ABORTED") {
    return new Error("The passkey request was cancelled or timed out.");
  }
  if (name === "InvalidStateError" || code === "ERROR_AUTHENTICATOR_PREVIOUSLY_REGISTERED") {
    return new Error("This device already has a passkey for Lens. Sign in with it instead.");
  }
  if (name === "SecurityError") return new Error("Passkeys only work on lens.aurovie.com.");
  return new Error(messageOf(e));
}
