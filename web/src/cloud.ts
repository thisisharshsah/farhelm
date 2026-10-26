/**
 * The browser's half of the control-plane connection.
 *
 * Everything portable is in `@farhelm/client-core`. What is left here is the
 * three things a browser decides for itself: where the control plane is, what to
 * call this device, and where the session is kept.
 */

import {
  CLOUD_SESSION_STORAGE_KEY,
  CloudClient,
  cloudSessionStore,
  type CloudSession,
} from "@farhelm/client-core";
import { idbBackend } from "./idb.ts";
import { defaultCloudUrl, preferredCloudUrl } from "./cloud-endpoint.ts";

/**
 * Where the control plane is.
 *
 * Hosted clients use the same origin. A locally served runner/dev app uses
 * the account service on its documented port, not the runner's API. A build
 * setting or the sign-in page's explicit server choice can select a deployment.
 */
export const CLOUD_URL: string = preferredCloudUrl(defaultCloudUrl(
  location.origin,
  import.meta.env.VITE_CLOUD_URL as string | undefined,
));

/**
 * The session, in IndexedDB.
 *
 * The same store the pairing uses, and for the same reason: the **service
 * worker** needs the device key to decrypt a fleet snapshot when a push arrives,
 * and a worker cannot read `localStorage`.
 *
 * The device secret is stored in the clear, which is worth naming rather than
 * burying. Any XSS on this origin steals it and can then act as this device. The
 * mitigations are that the app loads no third-party script, the service worker
 * caches only the app shell, and a stolen device key is revoked by removing the
 * device in the web app — without rotating any machine's key or disturbing any
 * other device.
 */
export const webCloudSessionStore = cloudSessionStore(idbBackend);

export { CLOUD_SESSION_STORAGE_KEY };

/**
 * Build a client that writes every rotated refresh token straight back to
 * storage.
 *
 * Rotation happens inside the client, on a schedule nothing else can see, so
 * persisting it anywhere but here would mean a token that works until the tab
 * is closed and then does not.
 */
export function cloudClient(session: CloudSession | null): CloudClient {
  const baseUrl = session?.baseUrl ?? CLOUD_URL;
  return new CloudClient(
    baseUrl,
    session?.refreshToken ?? null,
    (refreshToken) => {
      void webCloudSessionStore.load().then((current) => {
        if (!current) return;
        void webCloudSessionStore.save({ ...current, refreshToken });
      });
    },
    // Another tab of this app shares the stored session. Reading it before a
    // refresh means a tab that loaded an older token picks up the newer one
    // instead of replaying the old one, which the server treats as theft.
    () => webCloudSessionStore.load().then((current) => current?.refreshToken ?? null),
  );
}

/**
 * What this device is called in the workspace.
 *
 * A guess from the user agent, because the alternative is asking somebody to
 * name their browser during sign-up — a question with no good answer and a
 * mandatory field. It is editable later, and "Safari on macOS" is enough to tell
 * two entries apart, which is the only job this string has.
 */
export function deviceName(): string {
  const agent = navigator.userAgent;
  const browser = /Firefox\//.test(agent)
    ? "Firefox"
    : /Edg\//.test(agent)
      ? "Edge"
      : /Chrome\//.test(agent)
        ? "Chrome"
        : /Safari\//.test(agent)
          ? "Safari"
          : "A browser";

  const platform = /iPhone|iPad/.test(agent)
    ? "iOS"
    : /Android/.test(agent)
      ? "Android"
      : /Mac OS X/.test(agent)
        ? "macOS"
        : /Windows/.test(agent)
          ? "Windows"
          : /Linux/.test(agent)
            ? "Linux"
            : null;

  const installed = matchMedia("(display-mode: standalone)").matches;
  const base = platform ? `${browser} on ${platform}` : browser;
  return installed ? `${base} (installed)` : base;
}

/**
 * Which device kind this surface registers as.
 *
 * Drives the D3 rule server-side: a destructive command is phone-only, and a
 * `web` device is held to the desktop rules. Narrow viewport means phone, which
 * is the same heuristic the loopback path already uses.
 */
export function deviceKind(): "phone" | "web" {
  return matchMedia("(max-width: 640px)").matches ? "phone" : "web";
}
