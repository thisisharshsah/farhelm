import {
  ClockIcon,
  GlassesIcon,
  HistoryIcon,
  LayoutGridIcon,
  ListOrderedIcon,
  LogOutIcon,
  MessageSquareTextIcon,
  MicIcon,
  SkipForwardIcon,
  SmartphoneIcon,
  TextSearchIcon,
  WindIcon,
  type LucideIcon,
} from "lucide-react";
import { useEffect, useRef, useState, type Ref } from "react";
import { messageOf } from "../../../client/http.ts";
import type { Me } from "../../../shared/api.ts";
import type { Settings } from "../../lib/settings.ts";

interface ProfileProps {
  me: Me;
  settings: Settings;
  setSettings: (change: (prev: Settings) => Settings) => void;
  voice: boolean;
  companionLinked: boolean;
  websites: number;
  /** Shows the add-and-remove page for websites. */
  manageApps: () => void;
  /** Clear on every device. */
  clearSearches: () => Promise<void>;
  clearWatched: () => Promise<void>;
  signOut: () => Promise<void>;
}

type Armed = "searches" | "watched" | "signout";

const VERSION = "0.4";

/**
 * The profile in the top bar: everything these glasses can change, in one
 * list. Switches act on one pinch; anything that removes data takes two.
 * What needs typing or a passkey stays on the phone.
 */
export function Profile(props: ProfileProps) {
  const { me, settings, setSettings, voice, companionLinked, websites, manageApps, clearSearches, clearWatched, signOut } = props;
  const first = useRef<HTMLButtonElement>(null);
  const [armed, setArmed] = useState<Armed | null>(null);
  // What happened, shown on the row that did it.
  const [result, setResult] = useState<{ what: Armed; text: string; failed: boolean } | null>(null);

  useEffect(() => first.current?.focus(), []);

  const toggle = (key: keyof Settings) => setSettings((prev) => ({ ...prev, [key]: !prev[key] }));

  /** The first pinch asks, the second does it. */
  const twice = async (what: Armed, run: () => Promise<void>, done?: string) => {
    if (armed !== what) {
      setArmed(what);
      setResult(null);
      return;
    }
    setArmed(null);
    try {
      await run();
      if (done) setResult({ what, text: done, failed: false });
    } catch (e) {
      setResult({ what, text: messageOf(e), failed: true });
    }
  };

  const confirmRow = (what: Armed, Icon: LucideIcon, label: string, sub: string, run: () => Promise<void>, done?: string, danger = false) => {
    const said = result?.what === what ? result : null;
    return (
      <button
        className={`setting${danger ? " danger" : ""}${armed === what ? " armed" : ""}`}
        onClick={() => void twice(what, run, done)}
        onBlur={() => setArmed((a) => (a === what ? null : a))}
      >
        <Icon size={22} className="setting-icon" />
        <span className="setting-text">
          <span>{armed === what ? "Pinch again to confirm" : label}</span>
          <small className={said ? (said.failed ? "failed" : "done") : undefined} role={said ? "status" : undefined}>
            {said ? said.text : sub}
          </small>
        </span>
      </button>
    );
  };

  return (
    <section className="app-page profile" aria-label="Profile and settings">
      <div className="list">
        <div className="profile-head">
          <span className="avatar-lg" aria-hidden="true">
            {me.user.name.trim().charAt(0).toUpperCase() || "L"}
          </span>
          <span className="profile-who">
            <span className="profile-name">{me.user.name}</span>
            <span className="profile-sub">{me.user.role === "owner" ? "Owner" : "Member"} · These glasses</span>
          </span>
        </div>

        <p className="section-label">Display</p>
        <Switch buttonRef={first} icon={ClockIcon} label="24-hour clock" on={settings.clock24} onToggle={() => toggle("clock24")} />
        <Switch icon={WindIcon} label="Reduce motion" on={settings.reduceMotion} onToggle={() => toggle("reduceMotion")} />

        <p className="section-label">YouTube</p>
        <Switch icon={SkipForwardIcon} label="Play next automatically" on={settings.autoplay} onToggle={() => toggle("autoplay")} />
        <Switch icon={ListOrderedIcon} label="Number results for voice" on={settings.numbers} onToggle={() => toggle("numbers")} />
        {confirmRow("watched", HistoryIcon, "Clear watch history", "Also on your phone", clearWatched, "Watch history cleared")}
        {confirmRow("searches", TextSearchIcon, "Clear search history", "Also on your phone", clearSearches, "Search history cleared")}

        <p className="section-label">Apps</p>
        <button className="setting" onClick={manageApps}>
          <LayoutGridIcon size={22} className="setting-icon" />
          <span className="setting-text">
            <span>Manage websites</span>
            <small>{websites === 1 ? "1 website on the bar" : `${websites} websites on the bar`}</small>
          </span>
        </button>
        <Info icon={MessageSquareTextIcon} label="Companion" value={companionLinked ? "Linked" : "Not linked: set it on your phone"} />

        <p className="section-label">Voice</p>
        <Info icon={MicIcon} label="Meta AI" value={voice ? "On: say “Hey Meta, play lofi beats”" : "Not on for these glasses yet"} />

        <p className="section-label">Account</p>
        <Info icon={SmartphoneIcon} label="More on your phone" value="Passkeys, devices and team at lens.aurovie.com" />
        {confirmRow("signout", LogOutIcon, "Sign out these glasses", "You can link them again with a code", signOut, undefined, true)}
        <Info icon={GlassesIcon} label="Lens" value={`Version ${VERSION}`} />
      </div>
    </section>
  );
}

interface SwitchProps {
  icon: LucideIcon;
  label: string;
  on: boolean;
  onToggle: () => void;
  buttonRef?: Ref<HTMLButtonElement>;
}

function Switch({ icon: Icon, label, on, onToggle, buttonRef }: SwitchProps) {
  return (
    <button ref={buttonRef} className="setting" role="switch" aria-checked={on} onClick={onToggle}>
      <Icon size={22} className="setting-icon" />
      <span className="setting-text">
        <span>{label}</span>
      </span>
      <span className={`switch${on ? " on" : ""}`} aria-hidden="true">
        <span className="switch-knob" />
      </span>
    </button>
  );
}

/** A row to read, not a stop for focus. */
function Info({ icon: Icon, label, value }: { icon: LucideIcon; label: string; value: string }) {
  return (
    <div className="setting info">
      <Icon size={22} className="setting-icon" />
      <span className="setting-text">
        <span>{label}</span>
        <small>{value}</small>
      </span>
    </div>
  );
}
