import { useResource } from "../../client/resource.ts";
import { Note, Passkey, SessionInfo, WebApp, list } from "../../shared/api.ts";
import type { PageProps } from "../App.tsx";
import { AppTiles, BUILT_INS } from "../apps.tsx";
import { useLensChat } from "../chat/ChatContext.tsx";
import { Composer } from "../chat/Composer.tsx";
import { Feed } from "../chat/Feed.tsx";
import { greeting, timeAgo } from "../format.ts";
import { Link } from "../router.tsx";
import { Avatar, CopyButton, ErrorNote, Icon, type IconName } from "../ui.tsx";

const Sessions = list(SessionInfo);
const Apps = list(WebApp);
const Notes = list(Note);
const Passkeys = list(Passkey);

/** Seen within this long counts as connected right now. */
const ACTIVE_MS = 10 * 60_000;

const QUICK: { to: string; icon: IconName; label: string; primary?: boolean }[] = [
  { to: "/link", icon: "link", label: "Link", primary: true },
  { to: "/apps#add", icon: "plus", label: "Add app" },
  { to: "/notes", icon: "note", label: "Note" },
  { to: "/security", icon: "shield", label: "Security" },
];

export function Home({ me }: PageProps) {
  const chat = useLensChat();
  const sessions = useResource("/api/sessions", Sessions);
  const apps = useResource("/api/apps", Apps);
  const notes = useResource("/api/notes", Notes);
  const passkeys = useResource("/api/passkeys", Passkeys);

  const glasses = (sessions.data?.items ?? []).filter((s) => s.kind === "glasses");
  const latest = glasses.reduce<SessionInfo | null>((a, g) => (a === null || g.lastSeenAt > a.lastSeenAt ? g : a), null);
  const active = latest !== null && Date.now() - latest.lastSeenAt < ACTIVE_MS;
  const first = me.user.name.split(" ")[0] ?? me.user.name;
  const talked = chat.items.length > 0 || chat.pending.length > 0;

  return (
    <>
      <header className="hello">
        <div>
          <small>{greeting()}</small>
          <h1>{first}</h1>
        </div>
        <Link to="/account" aria-label="Account">
          <Avatar name={me.user.name} />
        </Link>
      </header>

      <Composer />

      {talked ? (
        <section className="section">
          <div className="section-head">
            <h2>Latest</h2>
            <Link to="/chat" className="section-link">
              All messages
            </Link>
          </div>
          <Feed limit={1} />
        </section>
      ) : null}

      <section className="hero glass">
        <div className="hero-top">
          <span className="hero-icon" aria-hidden="true">
            <Icon name="glasses" size={30} />
          </span>
          <div className="hero-text">
            <h2>{latest?.name ?? "No glasses linked"}</h2>
            <p className="live">
              {latest ? (
                <>
                  <span className={`dot${active ? " on" : ""}`} aria-hidden="true" />
                  {active ? "Connected · active now" : `Last active ${timeAgo(latest.lastSeenAt)}`}
                </>
              ) : (
                "Link them to see your apps there"
              )}
            </p>
          </div>
        </div>
        <div className="stats">
          <Link to="/apps" className="stat">
            <b>{BUILT_INS.length + (apps.data?.items.length ?? 0)}</b>
            <span>Apps</span>
          </Link>
          <Link to="/notes" className="stat">
            <b>{notes.data?.items.length ?? "–"}</b>
            <span>Notes</span>
          </Link>
          <Link to="/security" className="stat">
            <b>{passkeys.data?.items.length ?? "–"}</b>
            <span>Passkeys</span>
          </Link>
        </div>
        <ErrorNote message={sessions.error} onRetry={() => void sessions.reload()} />
      </section>

      <nav className="quick" aria-label="Quick actions">
        {QUICK.map((q) => (
          <Link key={q.label} to={q.to} className={`qa${q.primary ? " primary" : ""}`}>
            <span className="qb">
              <Icon name={q.icon} size={20} />
            </span>
            <span>{q.label}</span>
          </Link>
        ))}
      </nav>

      <section className="card glass">
        <div className="card-head">
          <h2>On your glasses</h2>
          <Link to="/apps" className="section-link">
            Edit
          </Link>
        </div>
        <AppTiles apps={apps.data?.items ?? []} />
        <ErrorNote message={apps.error} onRetry={() => void apps.reload()} />
      </section>

      {glasses.length === 0 ? <Setup /> : null}
    </>
  );
}

/** First run: how to get Lens onto the glasses. */
function Setup() {
  const appUrl = `${location.origin}/glasses`;
  return (
    <section className="card glass">
      <div className="card-head">
        <div>
          <h2>Open Lens on your glasses</h2>
          <p>Add this address once in the Meta AI app.</p>
        </div>
      </div>
      <div className="url-box">
        <code>{appUrl}</code>
        <CopyButton text={appUrl} />
      </div>
      <ol className="steps">
        <li>
          In the Meta AI app, turn on Developer Mode: <em>Settings, App Info</em>, then tap the version five times.
        </li>
        <li>
          Open <em>App connections</em>, choose <em>Add a Web App</em>, and paste the address.
        </li>
        <li>Open Lens on your glasses and link them with the code they show.</li>
      </ol>
    </section>
  );
}
