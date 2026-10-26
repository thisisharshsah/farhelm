const SERVER_KEY = "farhelm-cloud-url";

/** Credentials may travel over HTTP only to an explicit loopback service. */
export function validateCloudUrl(value: string): string {
  let url: URL;
  try { url = new URL(value.trim()); }
  catch { throw new Error("Enter a complete workspace server address, such as https://workspace.example.com."); }
  const loopback = url.hostname === "localhost" || url.hostname === "[::1]"
    || /^127(?:\.\d{1,3}){3}$/.test(url.hostname);
  if ((url.protocol !== "https:" && !(url.protocol === "http:" && loopback))
    || url.username || url.password || url.search || url.hash) {
    throw new Error("Use HTTPS for the workspace server, or HTTP on localhost. Remove credentials, query parameters and fragments from the address.");
  }
  return url.href.replace(/\/+$/, "");
}

export function defaultCloudUrl(origin: string, configured?: string): string {
  if (configured?.trim()) {
    // A bad build-time setting must remain editable on the sign-in screen,
    // rather than throwing during module load and blanking the entire app.
    try { return validateCloudUrl(configured); }
    catch { return configured.trim(); }
  }
  const url = new URL(origin);
  // The local runner (including Tauri's ephemeral port) has no account routes.
  // The control plane's documented local port is 7844. Hosted clients continue
  // to use their own origin; no credentials silently fall back to a service.
  const local = url.hostname === "localhost" || url.hostname === "127.0.0.1" || url.hostname === "[::1]";
  return local && url.port !== "7844" ? "http://127.0.0.1:7844" : validateCloudUrl(origin);
}

export function preferredCloudUrl(fallback: string): string {
  try {
    const saved = localStorage.getItem(SERVER_KEY);
    return saved ? validateCloudUrl(saved) : fallback;
  } catch { return fallback; }
}

export function rememberCloudUrl(value: string): void {
  try { localStorage.setItem(SERVER_KEY, validateCloudUrl(value)); }
  catch { /* A storage restriction must not prevent a working sign-in. */ }
}
