import { ExternalLinkIcon } from "lucide-react";
import { AppIcon } from "../shell/AppIcon.tsx";
import type { Tab } from "../shell/tabs.ts";

/**
 * A website on the bar. Websites open in the glasses' browser in place of
 * Lens; Back comes back here.
 */
export function Site({ tab }: { tab: Extract<Tab, { kind: "web" }> }) {
  const host = new URL(tab.url).hostname.replace(/^www\./, "");
  return (
    <section className="app-page fixed" aria-label={tab.name}>
      <div className="center site">
        <AppIcon tab={tab} />
        <p className="site-name">{tab.name}</p>
        <p className="site-host">{host}</p>
      </div>
      <button className="btn primary" data-primary onClick={() => location.assign(tab.url)}>
        <ExternalLinkIcon size={26} />
        Open {host}
      </button>
    </section>
  );
}
