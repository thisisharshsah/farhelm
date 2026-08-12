/**
 * The phone's half of the control-plane connection.
 *
 * Same client as the web — `@relayforge/client-core` — with the two things a
 * phone does differently: the session goes in the platform keystore rather than
 * IndexedDB, and the control plane's address has to be typed or built in,
 * because there is no origin to infer it from.
 */

import * as SecureStore from "expo-secure-store";
import {
  CloudClient,
  cloudSessionStore,
  type CloudSession,
} from "@relayforge/client-core";
import { Platform } from "react-native";

/**
 * The signed-in session, in the platform keystore.
 *
 * Keychain on iOS, EncryptedSharedPreferences on Android. This is the one place
 * the phone client is meaningfully safer than the PWA: there is no origin for a
 * script to run on and steal the device key, and the refresh token gets the same
 * protection for free.
 *
 * `SecureStore` caps a value at 2 KB on iOS. A session is a few hundred bytes —
 * two base64 keys and four ids — which is comfortably inside that.
 */
export const secureCloudSessionStore = cloudSessionStore({
  get: (key) => SecureStore.getItemAsync(key),
  set: (key, value) => SecureStore.setItemAsync(key, value),
  remove: (key) => SecureStore.deleteItemAsync(key),
});

/**
 * Where the control plane is.
 *
 * Baked in at build time through `EXPO_PUBLIC_CLOUD_URL` so the shipped app has
 * nothing to configure. It is still editable on the sign-in screen, because a
 * self-hosted deployment is a supported case and hard-coding one hostname would
 * make the app useless to anybody running their own.
 */
export const DEFAULT_CLOUD_URL: string =
  process.env.EXPO_PUBLIC_CLOUD_URL ?? "https://farhelm.aurovie.com";

/**
 * A client that writes every rotated refresh token back to the keystore.
 *
 * Rotation happens inside the client on a schedule nothing else can see, so
 * persisting it anywhere else would produce a session that works until the app
 * is backgrounded and then does not.
 */
export function cloudClient(session: CloudSession | null, baseUrl?: string): CloudClient {
  return new CloudClient(
    session?.baseUrl ?? baseUrl ?? DEFAULT_CLOUD_URL,
    session?.refreshToken ?? null,
    (refreshToken) => {
      void secureCloudSessionStore.load().then((current) => {
        if (!current) return;
        void secureCloudSessionStore.save({ ...current, refreshToken });
      });
    },
  );
}

/**
 * What this phone is called in the workspace.
 *
 * Not the device's real model name: `expo-device` would give one, and it is
 * another dependency to render a string that only has to distinguish two
 * entries in a list. "iPhone" and "Android phone" do that.
 */
export function deviceName(): string {
  return Platform.OS === "ios" ? "iPhone" : "Android phone";
}
