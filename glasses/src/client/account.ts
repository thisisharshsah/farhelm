import { useCallback, useEffect, useState } from "react";
import { Me } from "../shared/api.ts";
import { HttpError, UNAUTHORIZED_EVENT, api, messageOf } from "./http.ts";
import { clearCaches } from "./resource.ts";

export type AccountState =
  | { status: "loading" }
  | { status: "signed_out" }
  | { status: "signed_in"; me: Me }
  | { status: "error"; message: string };

export const CACHE_PREFIX = "lens.cache.v1:";

/**
 * Who is signed in, from the session cookie. Any 401 from any request moves
 * the app back to signed out and clears cached account data.
 */
export function useAccount() {
  const [state, setState] = useState<AccountState>({ status: "loading" });

  const refresh = useCallback(async () => {
    try {
      const me = await api("/api/me", { schema: Me });
      setState({ status: "signed_in", me });
    } catch (e) {
      if (e instanceof HttpError && e.status === 401) {
        clearCaches(CACHE_PREFIX);
        setState({ status: "signed_out" });
      } else {
        setState({ status: "error", message: messageOf(e) });
      }
    }
  }, []);

  useEffect(() => {
    void refresh();
    const onUnauthorized = () => {
      clearCaches(CACHE_PREFIX);
      setState({ status: "signed_out" });
    };
    addEventListener(UNAUTHORIZED_EVENT, onUnauthorized);
    return () => removeEventListener(UNAUTHORIZED_EVENT, onUnauthorized);
  }, [refresh]);

  const signOut = useCallback(async () => {
    try {
      await api("/api/auth/sign-out", { method: "POST" });
    } finally {
      clearCaches(CACHE_PREFIX);
      setState({ status: "signed_out" });
    }
  }, []);

  return { state, refresh, signOut };
}
