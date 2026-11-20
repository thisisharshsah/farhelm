import { GlobeIcon, Trash2Icon } from "lucide-react";
import { useRef, useState } from "react";
import { api, messageOf } from "../../../client/http.ts";
import { WebApp } from "../../../shared/api.ts";
import { AskBar } from "../../ui/AskBar.tsx";
import { AppIcon } from "../shell/AppIcon.tsx";
import { siteTabId } from "../shell/tabs.ts";

interface AddAppsProps {
  apps: WebApp[];
  /** Applies a change the server confirmed. */
  update: (change: (prev: WebApp[]) => WebApp[]) => void;
}

/**
 * The "+" at the end of the bar: add a website by saying or writing its
 * address; remove one with two pinches. The phone does the same, faster.
 */
export function AddApps({ apps, update }: AddAppsProps) {
  const bar = useRef<HTMLInputElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const [message, setMessage] = useState("");
  const [armed, setArmed] = useState<string | null>(null);

  const add = async (url: string) => {
    setMessage("Adding…");
    try {
      const app = await api("/api/apps", { method: "POST", body: { url }, schema: WebApp });
      update((prev) => [...prev, app]);
      setMessage(`Added ${app.name}`);
    } catch (e) {
      setMessage(messageOf(e));
    }
  };

  const remove = async (app: WebApp, index: number) => {
    if (armed !== app.id) {
      setArmed(app.id);
      return;
    }
    setArmed(null);
    try {
      await api(`/api/apps/${encodeURIComponent(app.id)}`, { method: "DELETE" });
      update((prev) => prev.filter((a) => a.id !== app.id));
      setMessage(`Removed ${app.name}`);
      requestAnimationFrame(() => {
        const items = list.current?.querySelectorAll<HTMLButtonElement>("button");
        (items?.[Math.min(index, (items?.length ?? 1) - 1)] ?? bar.current)?.focus();
      });
    } catch (e) {
      setMessage(messageOf(e));
    }
  };

  return (
    <section className="app-page" aria-label="Add apps">
      <AskBar
        ref={bar}
        label="Add a website"
        placeholder="Add a website, like github.com"
        icon={<GlobeIcon size={26} />}
        onSubmit={(text) => void add(text)}
      />
      <p className="page-note" aria-live="polite">
        {message || "Websites you add join the bar below. Pinch one twice here to remove it."}
      </p>
      <div className="list" ref={list}>
        {apps.length === 0 ? <p className="welcome">No websites yet. Say or write an address above, or add one on your phone.</p> : null}
        {apps.map((app, i) => (
          <button
            key={app.id}
            className={`app-row${armed === app.id ? " armed" : ""}`}
            onClick={() => void remove(app, i)}
            onBlur={() => setArmed((a) => (a === app.id ? null : a))}
          >
            <AppIcon tab={{ kind: "web", id: siteTabId(app.id), name: app.name, url: app.url, appId: app.id }} />
            <span className="app-row-text">
              <span>{app.name}</span>
              <span className="app-row-sub">
                {armed === app.id ? (
                  <>
                    <Trash2Icon size={18} /> Pinch again to remove
                  </>
                ) : (
                  new URL(app.url).hostname
                )}
              </span>
            </span>
          </button>
        ))}
      </div>
    </section>
  );
}
