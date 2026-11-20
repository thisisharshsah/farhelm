import { useEffect, useState, type AnchorHTMLAttributes, type MouseEvent } from "react";

/** Page paths in the address bar; a small router, since the console has a handful of pages. */
const NAVIGATE_EVENT = "lens:navigate";

export function navigate(to: string): void {
  if (to === location.pathname + location.search) return;
  history.pushState(null, "", to);
  dispatchEvent(new Event(NAVIGATE_EVENT));
  scrollTo({ top: 0 });
}

export function usePath(): string {
  const [path, setPath] = useState(location.pathname);
  useEffect(() => {
    const update = () => setPath(location.pathname);
    addEventListener("popstate", update);
    addEventListener(NAVIGATE_EVENT, update);
    return () => {
      removeEventListener("popstate", update);
      removeEventListener(NAVIGATE_EVENT, update);
    };
  }, []);
  return path;
}

/** An ordinary link that navigates in place; modified clicks still open new tabs. */
export function Link({ to, onClick, ...rest }: AnchorHTMLAttributes<HTMLAnchorElement> & { to: string }) {
  const handle = (e: MouseEvent<HTMLAnchorElement>) => {
    onClick?.(e);
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    e.preventDefault();
    navigate(to);
  };
  return <a href={to} onClick={handle} {...rest} />;
}
