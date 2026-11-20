/**
 * The console's building blocks: icons, buttons, glass cards, grouped lists,
 * fields and states. Styles live in console.css; components only choose classes.
 */
import {
  ActivityIcon,
  ArrowRightIcon,
  ArrowUpIcon,
  CheckIcon,
  ChevronLeftIcon,
  ChevronRightIcon,
  CircleAlertIcon,
  CircleUserIcon,
  CopyIcon,
  GlassesIcon,
  GlobeIcon,
  HistoryIcon,
  HouseIcon,
  KeyRoundIcon,
  LayoutGridIcon,
  LogOutIcon,
  MessageCircleIcon,
  MessageSquareTextIcon,
  MicIcon,
  MonitorSmartphoneIcon,
  NotebookPenIcon,
  PlayIcon,
  PlusIcon,
  RotateCwIcon,
  ScanLineIcon,
  ShieldCheckIcon,
  SmartphoneIcon,
  SparklesIcon,
  SquareIcon,
  TimerIcon,
  Trash2Icon,
  TvMinimalPlayIcon,
  UsersIcon,
  XIcon,
  type LucideIcon,
} from "lucide-react";
import { useCallback, useEffect, useRef, useState, type ButtonHTMLAttributes, type InputHTMLAttributes, type ReactNode } from "react";
import { messageOf } from "../client/http.ts";
import { Link } from "./router.tsx";

// ---------- icons (Lucide, one set across the console and the glasses) ----------

const ICONS = {
  activity: ActivityIcon,
  alert: CircleAlertIcon,
  apps: LayoutGridIcon,
  arrow: ArrowRightIcon,
  back: ChevronLeftIcon,
  chat: MessageCircleIcon,
  check: CheckIcon,
  chevron: ChevronRightIcon,
  companion: MessageSquareTextIcon,
  copy: CopyIcon,
  devices: MonitorSmartphoneIcon,
  glasses: GlassesIcon,
  globe: GlobeIcon,
  history: HistoryIcon,
  home: HouseIcon,
  key: KeyRoundIcon,
  link: ScanLineIcon,
  mic: MicIcon,
  note: NotebookPenIcon,
  phone: SmartphoneIcon,
  play: PlayIcon,
  plus: PlusIcon,
  retry: RotateCwIcon,
  send: ArrowUpIcon,
  shield: ShieldCheckIcon,
  signOut: LogOutIcon,
  sparkles: SparklesIcon,
  stop: SquareIcon,
  timer: TimerIcon,
  trash: Trash2Icon,
  user: CircleUserIcon,
  users: UsersIcon,
  video: TvMinimalPlayIcon,
  x: XIcon,
} satisfies Record<string, LucideIcon>;

export type IconName = keyof typeof ICONS;

export function Icon({ name, size = 18, fill }: { name: IconName; size?: number; fill?: string }) {
  const Glyph = ICONS[name];
  // Only pass fill when set: an explicit undefined would replace Lucide's "none" and fill the outline.
  return <Glyph className="icon" size={size} aria-hidden="true" {...(fill ? { fill } : {})} />;
}

/** The Lens mark: a lens ring with a highlight, on the brand gradient. */
export function Mark({ size = 28 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" aria-hidden="true" className="mark">
      <defs>
        <linearGradient id="lens-mark" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#9b7bff" />
          <stop offset="1" stopColor="#5b3fc4" />
        </linearGradient>
      </defs>
      <rect width="32" height="32" rx="8" fill="url(#lens-mark)" />
      <circle cx="16" cy="16" r="7.5" fill="none" stroke="#fff" strokeWidth="2.4" />
      <circle cx="19.2" cy="12.8" r="1.7" fill="#fff" />
    </svg>
  );
}

/** A coloured, rounded app tile, as on the glasses' app bar. */
export function Tile({ tone, icon, size = "md", children }: { tone: string; icon?: IconName; size?: "sm" | "md" | "lg"; children?: ReactNode }) {
  return (
    <span className={`tile tile-${size} tone-${tone}`} aria-hidden="true">
      {icon ? <Icon name={icon} size={size === "lg" ? 26 : size === "sm" ? 16 : 20} /> : children}
    </span>
  );
}

export function Avatar({ name, size = "md" }: { name: string; size?: "md" | "lg" }) {
  return (
    <span className={`avatar avatar-${size}`} aria-hidden="true">
      <span>{name.charAt(0).toUpperCase()}</span>
    </span>
  );
}

// ---------- controls ----------

type Variant = "primary" | "secondary" | "ghost" | "danger";

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant;
  icon?: IconName;
  busy?: boolean;
  size?: "md" | "lg";
}

export function Button({ variant = "secondary", icon, busy, size = "md", children, className, disabled, ...rest }: ButtonProps) {
  return (
    <button
      className={`btn btn-${variant} btn-${size}${children ? "" : " btn-icon"}${className ? ` ${className}` : ""}`}
      disabled={disabled || busy}
      aria-busy={busy || undefined}
      {...rest}
    >
      {busy ? <Spinner /> : icon ? <Icon name={icon} /> : null}
      {children ? <span>{children}</span> : null}
    </button>
  );
}

export function Spinner() {
  return <span className="spinner" aria-hidden="true" />;
}

interface FieldProps extends InputHTMLAttributes<HTMLInputElement> {
  label: string;
  hint?: ReactNode;
}

export function Field({ label, hint, id, ...rest }: FieldProps) {
  const fieldId = id ?? `f-${label.toLowerCase().replace(/\W+/g, "-")}`;
  return (
    <label className="field" htmlFor={fieldId}>
      <span className="field-label">{label}</span>
      <input id={fieldId} {...rest} />
      {hint ? <span className="field-hint">{hint}</span> : null}
    </label>
  );
}

export function CopyButton({ text, label = "Copy" }: { text: string; label?: string }) {
  const [copied, setCopied] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(
    () => () => {
      if (timer.current) clearTimeout(timer.current);
    },
    [],
  );
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      timer.current = setTimeout(() => setCopied(false), 1600);
    } catch {
      // Clipboard blocked: the text is on screen to select by hand.
    }
  };
  return (
    <Button variant="ghost" icon={copied ? "check" : "copy"} onClick={() => void copy()} aria-live="polite">
      {copied ? "Copied" : label}
    </Button>
  );
}

// ---------- layout ----------

export function PageHeader({
  title,
  description,
  actions,
  back,
}: {
  title: string;
  description?: ReactNode;
  actions?: ReactNode;
  /** Where the back link goes, with its label. */
  back?: { to: string; label: string };
}) {
  return (
    <header className="page-header">
      {back ? (
        <Link to={back.to} className="back">
          <Icon name="back" size={20} />
          <span>{back.label}</span>
        </Link>
      ) : null}
      <div className="page-title">
        <div>
          <h1>{title}</h1>
          {description ? <p>{description}</p> : null}
        </div>
        {actions ? <div className="page-actions">{actions}</div> : null}
      </div>
    </header>
  );
}

export function Card({
  title,
  description,
  actions,
  children,
  className,
}: {
  title?: ReactNode;
  description?: ReactNode;
  actions?: ReactNode;
  children?: ReactNode;
  className?: string;
}) {
  return (
    <section className={`card glass${className ? ` ${className}` : ""}`}>
      {title || actions ? (
        <div className="card-head">
          <div>
            {title ? <h2>{title}</h2> : null}
            {description ? <p>{description}</p> : null}
          </div>
          {actions ? <div className="card-actions">{actions}</div> : null}
        </div>
      ) : null}
      {children}
    </section>
  );
}

/** An iOS-style inset group: rows with an icon, text, and an action or chevron. */
export function Group({ title, children, footer }: { title?: string; children: ReactNode; footer?: ReactNode }) {
  return (
    <section className="group">
      {title ? <h2 className="group-title">{title}</h2> : null}
      <ul className="group-list glass">{children}</ul>
      {footer ? <p className="group-footer">{footer}</p> : null}
    </section>
  );
}

interface RowProps {
  icon?: ReactNode;
  title: ReactNode;
  detail?: ReactNode;
  /** Shown on the right: a button, a badge. */
  trailing?: ReactNode;
  /** Makes the row a link with a chevron. */
  to?: string;
  onClick?: () => void;
  tone?: "danger";
}

export function Row({ icon, title, detail, trailing, to, onClick, tone }: RowProps) {
  const body = (
    <>
      {icon}
      <span className="row-main">
        <span className="row-title">{title}</span>
        {detail ? <small>{detail}</small> : null}
      </span>
      {trailing}
      {to ? <Icon name="chevron" size={18} /> : null}
    </>
  );
  const cls = `row${to || onClick ? " row-action" : ""}${tone ? ` row-${tone}` : ""}`;
  return (
    <li>
      {to ? (
        <Link to={to} className={cls}>
          {body}
        </Link>
      ) : onClick ? (
        <button className={cls} onClick={onClick}>
          {body}
        </button>
      ) : (
        <div className={cls}>{body}</div>
      )}
    </li>
  );
}

export function Badge({ tone = "neutral", children }: { tone?: "neutral" | "brand" | "success" | "danger"; children: ReactNode }) {
  return <span className={`badge badge-${tone}`}>{children}</span>;
}

export function Empty({ icon, title, children }: { icon: IconName; title: string; children?: ReactNode }) {
  return (
    <div className="empty">
      <span className="empty-icon">
        <Icon name={icon} size={22} />
      </span>
      <strong>{title}</strong>
      {children ? <p>{children}</p> : null}
    </div>
  );
}

export function ErrorNote({ message, onRetry }: { message: string | null; onRetry?: () => void }) {
  if (!message) return null;
  return (
    <div className="error-note" role="alert">
      <Icon name="alert" />
      <span>{message}</span>
      {onRetry ? (
        <button className="link-button" onClick={onRetry}>
          Try again
        </button>
      ) : null}
    </div>
  );
}

export function Loading({ label = "Loading" }: { label?: string }) {
  return (
    <div className="loading" role="status">
      <Spinner />
      <span>{label}…</span>
    </div>
  );
}

/**
 * Runs one action at a time with busy and error state, so double clicks do
 * not double-submit and failures are shown, not swallowed.
 */
export function useAction<A extends unknown[]>(action: (...args: A) => Promise<void>) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const running = useRef(false);
  const run = useCallback(
    async (...args: A) => {
      if (running.current) return;
      running.current = true;
      setBusy(true);
      setError(null);
      try {
        await action(...args);
      } catch (e) {
        setError(messageOf(e));
      } finally {
        running.current = false;
        setBusy(false);
      }
    },
    [action],
  );
  return { run, busy, error, setError };
}
