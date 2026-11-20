import { useState } from "react";
import { api } from "../../client/http.ts";
import { useResource } from "../../client/resource.ts";
import { Invite, NewInvite, list } from "../../shared/api.ts";
import type { PageProps } from "../App.tsx";
import { shortDate, timeAgo } from "../format.ts";
import { Badge, Button, Card, CopyButton, Empty, ErrorNote, Group, Loading, PageHeader, Row, Tile, useAction } from "../ui.tsx";

const Invites = list(Invite);

function status(i: Invite, now: number) {
  if (i.usedAt) return <Badge tone="success">Used by {i.usedBy ?? "someone"}</Badge>;
  if (i.revokedAt) return <Badge tone="danger">Revoked</Badge>;
  if (i.expiresAt < now) return <Badge>Expired</Badge>;
  return <Badge tone="brand">Open · expires {timeAgo(i.expiresAt)}</Badge>;
}

export function Team(_: PageProps) {
  const invites = useResource("/api/invites", Invites);
  // A new code is shown once, right here; only its hash is stored.
  const [fresh, setFresh] = useState<string | null>(null);
  const now = Date.now();

  const create = useAction(async () => {
    const made = await api("/api/invites", { method: "POST", schema: NewInvite });
    setFresh(made.code);
    invites.set((prev) => ({ items: [made.invite, ...(prev?.items ?? [])] }));
  });
  const revoke = useAction(async (id: string) => {
    await api(`/api/invites/${encodeURIComponent(id)}`, { method: "DELETE" });
    invites.set((prev) => ({
      items: (prev?.items ?? []).map((i) => (i.id === id ? { ...i, revokedAt: Date.now() } : i)),
    }));
  });

  return (
    <>
      <PageHeader
        title="Team"
        description="Invite people to their own Lens account. Each invite works once and lasts a week."
        back={{ to: "/account", label: "Account" }}
        actions={
          <Button variant="primary" icon="plus" busy={create.busy} onClick={() => void create.run()}>
            New invite
          </Button>
        }
      />
      <ErrorNote message={create.error ?? revoke.error} />
      {fresh ? (
        <Card className="card-feature" title="Share this invite code" description="It is shown only now. Send it privately.">
          <div className="url-box">
            <code className="mono big">{fresh}</code>
            <CopyButton text={fresh} />
          </div>
        </Card>
      ) : null}
      <ErrorNote message={invites.error} onRetry={() => void invites.reload()} />
      {invites.loading && !invites.data ? (
        <Loading />
      ) : invites.data?.items.length ? (
        <Group title="Invites">
          {invites.data.items.map((i) => (
            <Row
              key={i.id}
              icon={<Tile tone="orange" icon="users" size="sm" />}
              title={`Invite from ${shortDate(i.createdAt)}`}
              detail={status(i, now)}
              trailing={
                !i.usedAt && !i.revokedAt && i.expiresAt > now ? (
                  <Button variant="ghost" onClick={() => void revoke.run(i.id)}>
                    Revoke
                  </Button>
                ) : null
              }
            />
          ))}
        </Group>
      ) : (
        <div className="glass card">
          <Empty icon="users" title="No invites yet">
            Create one to let someone set up their own account.
          </Empty>
        </div>
      )}
    </>
  );
}
