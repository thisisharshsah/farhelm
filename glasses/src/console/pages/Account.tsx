import { useResource } from "../../client/resource.ts";
import { Passkey, SessionInfo, list } from "../../shared/api.ts";
import type { PageProps } from "../App.tsx";
import { Avatar, Badge, Group, PageHeader, Row, Tile } from "../ui.tsx";

const Sessions = list(SessionInfo);
const Passkeys = list(Passkey);

const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

/** True when Lens was opened from the Home Screen rather than a browser tab. */
function installed(): boolean {
  return matchMedia("(display-mode: standalone)").matches || (navigator as Navigator & { standalone?: boolean }).standalone === true;
}

export function Account({ me, onSignOut }: PageProps) {
  const sessions = useResource("/api/sessions", Sessions);
  const passkeys = useResource("/api/passkeys", Passkeys);
  const items = sessions.data?.items ?? [];
  const glasses = items.filter((s) => s.kind === "glasses").length;
  const browsers = items.filter((s) => s.kind === "console").length;
  const owner = me.user.role === "owner";

  return (
    <>
      <PageHeader title="Account" />
      <section className="profile glass">
        <Avatar name={me.user.name} size="lg" />
        <div>
          <h2>{me.user.name}</h2>
          <p>
            <Badge tone="brand">{owner ? "Owner" : "Member"}</Badge> Signed in with a passkey
          </p>
        </div>
      </section>

      <Group title="Glasses">
        <Row icon={<Tile tone="purple" icon="link" size="sm" />} title="Link glasses" detail="Approve the code your glasses show" to="/link" />
        <Row
          icon={<Tile tone="blue" icon="devices" size="sm" />}
          title="Devices"
          detail={sessions.data ? `${plural(glasses, "pair", "pairs")} of glasses, ${plural(browsers, "browser")}` : "Everywhere you are signed in"}
          to="/devices"
        />
      </Group>

      <Group title="Security">
        <Row
          icon={<Tile tone="green" icon="key" size="sm" />}
          title="Passkeys and activity"
          detail={passkeys.data ? plural(passkeys.data.items.length, "passkey") : "How you sign in"}
          to="/security"
        />
        {owner ? <Row icon={<Tile tone="orange" icon="users" size="sm" />} title="Team" detail="Invite people to their own Lens" to="/team" /> : null}
      </Group>

      {installed() ? null : (
        <Group title="This phone" footer="In Safari, tap Share, then Add to Home Screen. Lens then opens full screen, like an app.">
          <Row icon={<Tile tone="gray" icon="phone" size="sm" />} title="Add Lens to your Home Screen" />
        </Group>
      )}

      <Group>
        <Row icon={<Tile tone="red" icon="signOut" size="sm" />} title="Sign out" onClick={onSignOut} tone="danger" />
      </Group>
    </>
  );
}
