/**
 * The passkey ceremony, behind a narrow port so the routes can be tested
 * without a real authenticator. Production uses SimpleWebAuthn.
 */
import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} from "@simplewebauthn/server";

export interface VerifiedCredential {
  id: string;
  publicKey: Uint8Array;
  counter: number;
  transports: string[];
  deviceType: string;
  backedUp: boolean;
}

export interface StoredCredential {
  id: string;
  publicKey: Uint8Array;
  counter: number;
  transports: string[];
}

export interface WebAuthnPort {
  registrationOptions(input: {
    rpName: string;
    rpID: string;
    userName: string;
    userHandle: Uint8Array;
    exclude: { id: string; transports: string[] }[];
  }): Promise<{ challenge: string; options: Record<string, unknown> }>;
  verifyRegistration(input: {
    response: unknown;
    challenge: string;
    origin: string;
    rpID: string;
  }): Promise<VerifiedCredential | null>;
  authenticationOptions(input: { rpID: string }): Promise<{ challenge: string; options: Record<string, unknown> }>;
  verifyAuthentication(input: {
    response: unknown;
    challenge: string;
    origin: string;
    rpID: string;
    credential: StoredCredential;
  }): Promise<{ newCounter: number } | null>;
}

export const simpleWebAuthn: WebAuthnPort = {
  async registrationOptions({ rpName, rpID, userName, userHandle, exclude }) {
    const options = await generateRegistrationOptions({
      rpName,
      rpID,
      userName,
      userDisplayName: userName,
      userID: new Uint8Array(userHandle),
      attestationType: "none",
      // Discoverable credentials: sign-in needs no user name.
      authenticatorSelection: { residentKey: "required", userVerification: "preferred" },
      excludeCredentials: exclude,
    });
    return { challenge: options.challenge, options: options as unknown as Record<string, unknown> };
  },

  async verifyRegistration({ response, challenge, origin, rpID }) {
    try {
      const result = await verifyRegistrationResponse({
        response: response as Parameters<typeof verifyRegistrationResponse>[0]["response"],
        expectedChallenge: challenge,
        expectedOrigin: origin,
        expectedRPID: rpID,
        requireUserVerification: false,
      });
      if (!result.verified || !result.registrationInfo) return null;
      const { credential, credentialDeviceType, credentialBackedUp } = result.registrationInfo;
      return {
        id: credential.id,
        publicKey: credential.publicKey,
        counter: credential.counter,
        transports: credential.transports ?? [],
        deviceType: credentialDeviceType,
        backedUp: credentialBackedUp,
      };
    } catch {
      return null;
    }
  },

  async authenticationOptions({ rpID }) {
    const options = await generateAuthenticationOptions({ rpID, userVerification: "preferred", allowCredentials: [] });
    return { challenge: options.challenge, options: options as unknown as Record<string, unknown> };
  },

  async verifyAuthentication({ response, challenge, origin, rpID, credential }) {
    try {
      const result = await verifyAuthenticationResponse({
        response: response as Parameters<typeof verifyAuthenticationResponse>[0]["response"],
        expectedChallenge: challenge,
        expectedOrigin: origin,
        expectedRPID: rpID,
        credential: {
          id: credential.id,
          publicKey: new Uint8Array(credential.publicKey),
          counter: credential.counter,
          transports: credential.transports as never,
        },
        requireUserVerification: false,
      });
      return result.verified ? { newCounter: result.authenticationInfo.newCounter } : null;
    } catch {
      return null;
    }
  },
};
