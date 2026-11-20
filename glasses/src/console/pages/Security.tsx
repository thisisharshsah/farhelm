import { api } from "../../client/http.ts";
import { useResource } from "../../client/resource.ts";
import { ActivityItem, Passkey, list } from "../../shared/api.ts";
import type { PageProps } from "../App.tsx";
import { shortDate, timeAgo } from "../format.ts";
import { addPasskey, passkeyError } from "../passkeys.ts";
import { Badge, Button, Empty, ErrorNote, Group, Loading, PageHeader, Row, Tile, useAction, type IconName } from "../ui.tsx";

const Passkeys = list(Passkey);
const Activity = list(ActivityItem);

const EVENTS: Record<string, { label: string; icon: IconName }> = {
  account_created: { label: "Account created", icon: "users" },
  signed_in: { label: "Signed in", icon: "key" },
  signed_out: { label: "Signed out", icon: "signOut" },
  passkey_added: { label: "Passkey added", icon: "key" },
  passkey_removed: { label: "Passkey removed", icon: "trash" },
  session_revoked: { label: "Device signed out", icon: "devices" },
  glasses_linked: { label: "Glasses linked", icon: "glasses" },
  glasses_link_denied: { label: "Glasses link declined", icon: "alert" },
  invite_created: { label: "Invite created", icon: "users" },
  invite_revoked: { label: "Invite revoked", icon: "users" },
};

function describe(e: ActivityItem): string {
  const name = typeof e.detail.name === "string" ? e.detail.name : null;
  return name ? `${EVENTS[e.type]?.label ?? e.type}: ${name}` : (EVENTS[e.type]?.label ?? e.type);
}

export function Security(_: PageProps) {
  const passkeys = useResource("/api/passkeys", Passkeys);
  const activity = useResource("/api/activity", Activity);

  const add = useAction(async () => {
    try {
      const key = await addPasskey();
      passkeys.set((prev) => ({ items: [...(prev?.items ?? []), key] }));
      void activity.reload();
    } catch (e) {
      throw passkeyError(e);
    }
  });
  const remove = useAction(async (id: string) => {
    await api(`/api/passkeys/${encodeURIComponent(id)}`, { method: "DELETE" });
    passkeys.set((prev) => ({ items: (prev?.items ?? []).filter((p) => p.id !== id) }));
    void activity.reload();
  });

  const keys = passkeys.data?.items ?? [];

  return (
    <>
      <PageHeader
        title="Security"
        description="How you sign in, and everything that happened on your account."
        back={{ to: "/account", label: "Account" }}
        actions={
          <Button variant="primary" icon="plus" busy={add.busy} onClick={() => void add.run()}>
            Add a passkey
          </Button>
        }
      />
      <ErrorNote message={add.error ?? remove.error ?? passkeys.error} />
      {passkeys.loading && !passkeys.data ? (
        <Loading />
      ) : (
        <Group title="Passkeys" footer="Add one on each device you use, so losing one never locks you out.">
          {keys.map((k) => (
            <Row
              key={k.id}
              icon={<Tile tone="green" icon="key" size="sm" />}
              title={
                <>
                  {k.name} {k.backedUp ? <Badge tone="success">Synced</Badge> : <Badge>This device only</Badge>}
                </>
              }
              detail={`Added ${shortDate(k.createdAt)}${k.lastUsedAt ? ` · Last used ${timeAgo(k.lastUsedAt)}` : ""}`}
              trailing={
                <Button
                  variant="ghost"
                  icon="trash"
                  disabled={keys.length <= 1}
                  title={keys.length <= 1 ? "Keep at least one passkey" : undefined}
                  onClick={() => void remove.run(k.id)}
                  aria-label={`Remove passkey ${k.name}`}
                />
              }
            />
          ))}
        </Group>
      )}

      <ErrorNote message={activity.error} onRetry={() => void activity.reload()} />
      {activity.loading && !activity.data ? (
        <Loading />
      ) : activity.data?.items.length ? (
        <Group title="Activity" footer="The last 50 security events.">
          {activity.data.items.map((e) => (
            <Row
              key={e.id}
              icon={<Tile tone="gray" icon={EVENTS[e.type]?.icon ?? "shield"} size="sm" />}
              title={describe(e)}
              detail={`${timeAgo(e.createdAt)}${e.ip ? ` · ${e.ip}` : ""}`}
            />
          ))}
        </Group>
      ) : (
        <div className="glass card">
          <Empty icon="shield" title="No activity yet" />
        </div>
      )}
    </>
  );
}
