/**
 * The desktop navigation rail.
 *
 * The app was built phone-first and stayed there: one 34rem column, a `← Back`
 * button, and a row of glyphs in a top bar. That is a good phone app and a poor
 * desktop one — on a wide screen it left the other 80% of the window empty
 * while hiding every destination one tap deep behind a back stack.
 *
 * A rail fixes the part that matters more than the empty pixels: **where am I,
 * and what else is there**. Every destination is visible and one click away,
 * the current one is marked, and the machine being supervised — the single most
 * important piece of context in the app, and previously legible only as a word
 * in the top bar — is stated permanently.
 *
 * It renders only above the breakpoint. Below it the phone layout is untouched,
 * because it was not broken; see `styles.css`, `--rail` and the `52rem` query.
 */

import type { Workspace } from "@relayforge/client-core";
import type { Route } from "../hooks";
import { Icon, type IconName } from "./Icon";

export type Theme = "system" | "light" | "dark";

const THEME_ICON: Record<Theme, IconName> = {
  system: "auto",
  light: "sun",
  dark: "moon",
};

const THEME_LABEL: Record<Theme, string> = {
  system: "Match the system",
  light: "Light",
  dark: "Dark",
};

/** Which rail entry a route belongs under. */
function sectionOf(route: Route): "fleet" | "tasks" | "account" {
  switch (route.view) {
    case "tasks":
    case "task":
    case "new-task":
      return "tasks";
    case "account":
    case "billing":
      return "account";
    default:
      // Sessions and their cost views are things you opened *from* the fleet,
      // so the fleet stays lit rather than nothing being lit.
      return "fleet";
  }
}

export function Sidebar({
  workspace,
  route,
  activeRunnerId,
  connectionState,
  theme,
  onNavigate,
  onPickRunner,
  onCycleTheme,
  onOpenPalette,
  onSignOut,
}: {
  workspace: Workspace | null;
  route: Route;
  activeRunnerId: string | null;
  connectionState: string;
  theme: Theme;
  onNavigate: (to: string) => void;
  onPickRunner: (id: string) => void;
  onCycleTheme: () => void;
  onOpenPalette: () => void;
  onSignOut: () => void;
}) {
  const section = sectionOf(route);
  const runners = workspace?.runners ?? [];
  const active = runners.find((runner) => runner.id === activeRunnerId) ?? null;

  const entry = (
    key: "fleet" | "tasks" | "account",
    to: string,
    icon: IconName,
    label: string,
  ) => (
    <button
      className={`rail-link${section === key ? " is-current" : ""}`}
      onClick={() => onNavigate(to)}
      // Marks the destination for a screen reader the same way the tint marks
      // it visually, rather than leaving the current page identifiable only by
      // colour.
      aria-current={section === key ? "page" : undefined}
    >
      <Icon name={icon} />
      {label}
    </button>
  );

  return (
    <nav className="rail" aria-label="Main">
      <div className="rail-org">
        <span className="rail-org-name">{workspace?.org.name ?? "Workspace"}</span>
        {workspace ? (
          <span className="plan-chip">{workspace.subscription.plan}</span>
        ) : null}
      </div>

      <button className="rail-search" onClick={onOpenPalette}>
        <Icon name="search" size={16} />
        <span>Search…</span>
        {/* Teaching the shortcut in place beats a help screen nobody opens. */}
        <kbd>⌘K</kbd>
      </button>

      <div className="rail-group">
        {entry("fleet", "/", "fleet", "Fleet")}
        {entry("tasks", "/t", "tasks", "Tasks")}
        {entry("account", "/account", "account", "Workspace")}
      </div>

      {runners.length > 0 ? (
        <div className="rail-group">
          <h2 className="rail-heading">Machines</h2>
          {runners.map((runner) => (
            <button
              key={runner.id}
              className={`rail-machine${runner.id === activeRunnerId ? " is-current" : ""}`}
              onClick={() => onPickRunner(runner.id)}
              title={runner.online ? "Online" : "Offline"}
            >
              <span
                className={`dot ${runner.online ? "is-online" : "is-offline"}`}
                aria-hidden="true"
              />
              <span className="rail-machine-name">{runner.name}</span>
              {runner.id === activeRunnerId ? (
                <Icon name="check" size={15} />
              ) : null}
            </button>
          ))}
        </div>
      ) : null}

      <div className="rail-foot">
        {/* The link's health, stated plainly and always. It used to appear only
            as the word "reconnecting…" in the top bar while degraded, so a
            healthy link and a missing one looked identical. */}
        <div className="rail-status">
          <span
            className={`dot ${
              connectionState === "open"
                ? "is-online"
                : connectionState === "connecting"
                  ? "is-pending"
                  : "is-offline"
            }`}
            aria-hidden="true"
          />
          {active
            ? connectionState === "open"
              ? "Connected"
              : connectionState === "connecting"
                ? "Connecting…"
                : "Reconnecting…"
            : "No machine selected"}
        </div>

        <div className="rail-foot-actions">
          <button
            className="icon-button"
            onClick={onCycleTheme}
            aria-label={`Theme: ${THEME_LABEL[theme]}. Change it.`}
            title={`Theme: ${THEME_LABEL[theme]}`}
          >
            <Icon name={THEME_ICON[theme]} />
          </button>
          <button
            className="icon-button"
            onClick={onSignOut}
            aria-label="Sign out"
            title="Sign out"
          >
            <Icon name="signout" />
          </button>
        </div>
      </div>
    </nav>
  );
}
