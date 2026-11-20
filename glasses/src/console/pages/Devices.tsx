import { useState } from "react";
import { api } from "../../client/http.ts";
import { useResource } from "../../client/resource.ts";
import { SessionInfo, list } from "../../shared/api.ts";
import type { PageProps } from "../App.tsx";
import { shortDate, timeAgo } from "../format.ts";
import { Badge, Button, Empty, ErrorNote, Group, Loading, PageHeader, Row, Tile, useAction } from "../ui.tsx";

const Sessions = list(SessionInfo);

export function Devices(_: PageProps) {
  const sessions = useResource("/api/sessions", Sessions);
  // Signing a device out takes two taps: the first arms the button.
  const [armed, setArmed] = useState<string | null>(null);

  const revoke = useAction(async (id: string) => {
    await api(`/api/sessions/${encodeURIComponent(id)}`, { method: "DELETE" });
    setArmed(null);
    sessions.set((prev) => ({ items: (prev?.items ?? []).filter((s) => s.id !== id) }));
  });

  const items = sessions.data?.items ?? [];
  const groups: { title: string; kind: SessionInfo["kind"]; empty: string }[] = [
    { title: "Glasses", kind: "glasses", empty: "No glasses are linked. Open Lens on them to get a code." },
    { title: "Browsers", kind: "console", empty: "" },
  ];

  return (
    <>
      <PageHeader
        title="Devices"
        description="Everywhere your account is signed in. Sign out anything you do not recognise."
        back={{ to: "/account", label: "Account" }}
      />
      <ErrorNote message={sessions.error ?? revoke.error} onRetry={sessions.error ? () => void sessions.reload() : undefined} />
      {sessions.loading && !sessions.data ? (
        <Loading />
      ) : (
        groups.map((g) => {
          const list = items.filter((s) => s.kind === g.kind);
          return list.length ? (
            <Group key={g.kind} title={g.title}>
              {list.map((s) => (
                <Row
                  key={s.id}
                  icon={<Tile tone={s.kind === "glasses" ? "purple" : "blue"} icon={s.kind === "glasses" ? "glasses" : "devices"} size="sm" />}
                  title={
                    <>
                      {s.name} {s.current ? <Badge tone="brand">This device</Badge> : null}
                    </>
                  }
                  detail={`Active ${timeAgo(s.lastSeenAt)} · Signed in ${shortDate(s.createdAt)}`}
                  trailing={
                    s.current ? null : (
                      <Button
                        variant={armed === s.id ? "danger" : "ghost"}
                        busy={revoke.busy && armed === s.id}
                        onClick={() => (armed === s.id ? void revoke.run(s.id) : setArmed(s.id))}
                        onBlur={() => setArmed((a) => (a === s.id ? null : a))}
                      >
                        {armed === s.id ? "Confirm sign out" : "Sign out"}
                      </Button>
                    )
                  }
                />
              ))}
            </Group>
          ) : (
            <section key={g.kind} className="group">
              <h2 className="group-title">{g.title}</h2>
              <div className="glass card">
                <Empty icon={g.kind === "glasses" ? "glasses" : "devices"} title={`No ${g.title.toLowerCase()}`}>
                  {g.empty}
                </Empty>
              </div>
            </section>
          );
        })
      )}
    </>
  );
}
