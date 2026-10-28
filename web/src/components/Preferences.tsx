/**
 * Settings that belong to this browser and this connection, not to an
 * account. Shown signed in or not, so the Settings page is never just a
 * sign-in button: someone using the app on their own machine still has a
 * theme to pick and a runner to read about.
 */

export type Theme = "system" | "light" | "dark";

const THEMES: { id: Theme; label: string }[] = [
  { id: "system", label: "System" },
  { id: "light", label: "Light" },
  { id: "dark", label: "Dark" },
];

export function Preferences({
  theme,
  onTheme,
  connection,
  machineName,
  sessions,
}: {
  theme: Theme;
  onTheme: (theme: Theme) => void;
  /** How this browser reaches the runner, in words. */
  connection: string;
  machineName: string | null;
  sessions: number | null;
}) {
  return (
    <>
      <header className="page-head settings-head">
        <div>
          <h1 className="page-title">Settings</h1>
          <p className="page-sub">This browser, this machine and your account.</p>
        </div>
      </header>
      <div className="settings-grid">
        <section className="panel settings-section" aria-labelledby="pref-appearance">
          <h2 className="panel-title" id="pref-appearance">Appearance</h2>
          <p className="field-hint">Saved in this browser.</p>
          <div className="seg" role="group" aria-label="Theme">
            {THEMES.map((option) => (
              <button
                key={option.id}
                type="button"
                aria-pressed={theme === option.id}
                onClick={() => onTheme(option.id)}
              >
                {option.label}
              </button>
            ))}
          </div>
        </section>

        <section className="panel settings-section" aria-labelledby="pref-machine">
          <h2 className="panel-title" id="pref-machine">This machine</h2>
          <dl className="settings-facts">
            <div><dt>Runner</dt><dd>{machineName ?? "Not connected"}</dd></div>
            <div><dt>Connection</dt><dd>{connection}</dd></div>
            <div><dt>Sessions</dt><dd>{sessions === null ? "Loading…" : sessions}</dd></div>
          </dl>
        </section>
      </div>
    </>
  );
}
