import { LucideProvider } from "lucide-react";
import { useCallback, useEffect, type ComponentType } from "react";
import { useAccount } from "../client/account.ts";
import type { Me } from "../shared/api.ts";
import { ChatProvider } from "./chat/ChatContext.tsx";
import { Account } from "./pages/Account.tsx";
import { Apps } from "./pages/Apps.tsx";
import { ChatPage } from "./pages/Chat.tsx";
import { Devices } from "./pages/Devices.tsx";
import { Home } from "./pages/Home.tsx";
import { LinkGlasses } from "./pages/LinkGlasses.tsx";
import { NotesPage } from "./pages/Notes.tsx";
import { HistoryPage } from "./pages/History.tsx";
import { Security } from "./pages/Security.tsx";
import { SignIn } from "./pages/SignIn.tsx";
import { Team } from "./pages/Team.tsx";
import { Link, usePath } from "./router.tsx";
import { Button, Icon, Mark, type IconName } from "./ui.tsx";

export interface PageProps {
  me: Me;
  onSignOut: () => void;
}

type Section = "home" | "chat" | "apps" | "account";

interface PageDef {
  path: string;
  component: ComponentType<PageProps>;
  section: Section;
  ownerOnly?: boolean;
}

const PAGES: PageDef[] = [
  { path: "/", component: Home, section: "home" },
  { path: "/chat", component: ChatPage, section: "chat" },
  { path: "/apps", component: Apps, section: "apps" },
  { path: "/notes", component: NotesPage, section: "apps" },
  { path: "/history", component: HistoryPage, section: "apps" },
  { path: "/account", component: Account, section: "account" },
  { path: "/link", component: LinkGlasses, section: "account" },
  { path: "/devices", component: Devices, section: "account" },
  { path: "/security", component: Security, section: "account" },
  { path: "/team", component: Team, section: "account", ownerOnly: true },
];

/** Older addresses that still work. */
const MOVED: Record<string, string> = { "/home-screen": "/apps", "/overview": "/" };

const DOCK: { section: Section; to: string; icon: IconName; label: string }[] = [
  { section: "home", to: "/", icon: "home", label: "Home" },
  { section: "chat", to: "/chat", icon: "chat", label: "Chat" },
  { section: "apps", to: "/apps", icon: "apps", label: "Apps" },
  { section: "account", to: "/account", icon: "user", label: "Account" },
];

export function App() {
  const { state, refresh, signOut } = useAccount();
  const onSignedIn = useCallback(() => void refresh(), [refresh]);

  let content;
  if (state.status === "loading") {
    content = (
      <div className="boot">
        <Mark size={48} />
      </div>
    );
  } else if (state.status === "error") {
    content = (
      <div className="boot">
        <Mark size={48} />
        <p>{state.message}</p>
        <Button variant="primary" onClick={() => void refresh()}>
          Try again
        </Button>
      </div>
    );
  } else if (state.status === "signed_out") {
    content = <SignIn onSignedIn={onSignedIn} />;
  } else {
    content = <Shell me={state.me} onSignOut={() => void signOut()} />;
  }

  return (
    <LucideProvider strokeWidth={2}>
      <div className="aurora" aria-hidden="true" />
      {content}
    </LucideProvider>
  );
}

function Shell({ me, onSignOut }: PageProps) {
  const raw = usePath();
  const path = MOVED[raw] ?? raw;
  useEffect(() => {
    if (MOVED[raw]) history.replaceState(null, "", MOVED[raw]);
  }, [raw]);

  const pages = PAGES.filter((p) => !p.ownerOnly || me.user.role === "owner");
  const page = pages.find((p) => p.path === path);
  const Page = page?.component;
  const section = page?.section ?? PAGES.find((p) => p.path === path)?.section;

  return (
    <ChatProvider me={me}>
      <main className="app" key={path}>
        {Page ? (
          <Page me={me} onSignOut={onSignOut} />
        ) : (
          <div className="not-found">
            <h1>{path === "/team" ? "Only the owner manages the team" : "Page not found"}</h1>
            <Link to="/" className="btn btn-secondary btn-md">
              Go home
            </Link>
          </div>
        )}
      </main>
      <nav className="dock" aria-label="Sections">
        {DOCK.map((d) => (
          <Link
            key={d.section}
            to={d.to}
            className={`dock-item${section === d.section ? " on" : ""}`}
            aria-label={d.label}
            title={d.label}
            aria-current={section === d.section ? "page" : undefined}
          >
            <Icon name={d.icon} size={22} />
          </Link>
        ))}
      </nav>
    </ChatProvider>
  );
}
