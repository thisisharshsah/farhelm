import { useCallback, useEffect, useRef, useState } from "react";
import { isVideoId, type Video } from "../../shared/youtube.ts";

/**
 * Where the glasses are: one of the apps on the bottom bar, the video player
 * or the profile. Switching apps replaces the history entry, so Back never
 * walks through apps; the player and the profile are pushed, so Back closes
 * them. The glasses' Back follows standard history.
 */
export type Route = { view: "tab"; tab: string } | { view: "watch"; video: Video } | { view: "profile" };
export type Cover = Exclude<Route, { view: "tab" }>;

/** The app last shown, so the glasses reopen on it. */
const TAB_KEY = "glasses.tab.v1";
export const DEFAULT_TAB = "youtube";

function storedTab(): string {
  try {
    return localStorage.getItem(TAB_KEY) || DEFAULT_TAB;
  } catch {
    return DEFAULT_TAB;
  }
}

function storeTab(tab: string): void {
  try {
    localStorage.setItem(TAB_KEY, tab);
  } catch {
    // Unavailable: the glasses reopen on the default app.
  }
}

/** History state is untrusted: it survives reloads and app updates. */
export function parseRoute(state: unknown, fallbackTab = DEFAULT_TAB): Route {
  if (typeof state !== "object" || state === null) return { view: "tab", tab: fallbackTab };
  const s = state as { view?: unknown; tab?: unknown; video?: unknown };
  if (s.view === "watch") {
    const v = s.video as Partial<Video> | undefined;
    if (v && isVideoId(v.id)) {
      return {
        view: "watch",
        video: {
          id: v.id,
          title: typeof v.title === "string" ? v.title : "",
          channel: typeof v.channel === "string" ? v.channel : "",
          thumbnail: typeof v.thumbnail === "string" ? v.thumbnail : "",
          seconds: typeof v.seconds === "number" ? v.seconds : null,
        },
      };
    }
    return { view: "tab", tab: "youtube" };
  }
  if (s.view === "profile") return { view: "profile" };
  if (s.view === "tab" && typeof s.tab === "string" && s.tab.length > 0 && s.tab.length <= 80) return { view: "tab", tab: s.tab };
  return { view: "tab", tab: fallbackTab };
}

export interface Router {
  route: Route;
  /** The app on the bottom bar, also while the player or profile covers it. */
  tab: string;
  /** Shows an app. From the player or profile, closes them first. */
  select: (tab: string) => void;
  /** Opens the player or the profile on top; `replace` swaps the current one (the next video). */
  go: (cover: Cover, options?: { replace?: boolean }) => void;
  back: () => void;
}

export function useRouter(): Router {
  const [route, setRoute] = useState<Route>(() => parseRoute(history.state, storedTab()));
  const [tab, setTab] = useState(() => (route.view === "tab" ? route.tab : storedTab()));
  // An app picked while something covers it: shown once Back has closed the cover.
  const pending = useRef<string | null>(null);
  const routeRef = useRef(route);
  routeRef.current = route;

  useEffect(() => {
    if (history.state === null) history.replaceState({ view: "tab", tab }, "");
    const onPop = (e: PopStateEvent) => {
      let next = parseRoute(e.state, storedTab());
      if (pending.current !== null) {
        if (next.view === "tab") {
          next = { view: "tab", tab: pending.current };
          history.replaceState(next, "");
          pending.current = null;
        } else {
          // Still covered (a video over the profile): keep closing.
          history.back();
          return;
        }
      }
      if (next.view === "tab") {
        setTab(next.tab);
        storeTab(next.tab);
      }
      setRoute(next);
    };
    addEventListener("popstate", onPop);
    return () => removeEventListener("popstate", onPop);
    // Only on mount: the listener reads refs and storage.
  }, []);

  const select = useCallback((next: string) => {
    storeTab(next);
    setTab(next);
    if (routeRef.current.view === "tab") {
      const r: Route = { view: "tab", tab: next };
      history.replaceState(r, "");
      setRoute(r);
    } else {
      pending.current = next;
      history.back();
    }
  }, []);

  const go = useCallback((next: Cover, options?: { replace?: boolean }) => {
    if (options?.replace) history.replaceState(next, "");
    else history.pushState(next, "");
    setRoute(next);
  }, []);

  const back = useCallback(() => history.back(), []);
  return { route, tab, select, go, back };
}
