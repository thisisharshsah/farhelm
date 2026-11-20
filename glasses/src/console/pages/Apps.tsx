import { useEffect, useRef, useState, type FormEvent } from "react";
import { api } from "../../client/http.ts";
import { useResource } from "../../client/resource.ts";
import { Preferences, WebApp, list } from "../../shared/api.ts";
import type { PageProps } from "../App.tsx";
import { AppTiles, BUILT_INS, BuiltInTile, SiteTile } from "../apps.tsx";
import { Button, Card, ErrorNote, Field, Group, Loading, PageHeader, Row, useAction } from "../ui.tsx";

const AppList = list(WebApp);

export function Apps(_: PageProps) {
  const apps = useResource("/api/apps", AppList);
  const prefs = useResource("/api/preferences", Preferences);
  const [url, setUrl] = useState("");
  const [companion, setCompanion] = useState("");
  const addField = useRef<HTMLDivElement>(null);

  // Arriving from "Add app" goes straight to the address field.
  useEffect(() => {
    if (location.hash !== "#add") return;
    addField.current?.scrollIntoView({ block: "center" });
    addField.current?.querySelector("input")?.focus();
  }, []);

  useEffect(() => {
    if (prefs.data) setCompanion(prefs.data.companionLink ?? "");
  }, [prefs.data]);

  const add = useAction(async () => {
    const app = await api("/api/apps", { method: "POST", body: { url }, schema: WebApp });
    apps.set((prev) => ({ items: [...(prev?.items ?? []), app] }));
    setUrl("");
  });
  const remove = useAction(async (id: string) => {
    await api(`/api/apps/${encodeURIComponent(id)}`, { method: "DELETE" });
    apps.set((prev) => ({ items: (prev?.items ?? []).filter((a) => a.id !== id) }));
  });
  const saveCompanion = useAction(async (value: string | null) => {
    const next = await api("/api/preferences", { method: "PATCH", body: { companionLink: value }, schema: Preferences });
    prefs.set(() => next);
    setCompanion(next.companionLink ?? "");
  });

  const submitApp = (e: FormEvent) => {
    e.preventDefault();
    void add.run();
  };
  const submitCompanion = (e: FormEvent) => {
    e.preventDefault();
    void saveCompanion.run(companion.trim() || null);
  };

  const websites = apps.data?.items ?? [];

  return (
    <>
      <PageHeader title="Apps" description="What your glasses show on their app bar, in this order." />

      <section className="card glass">
        <AppTiles apps={websites} />
      </section>

      <Card title="Add a website" description="Any https site. It shows with its own icon and opens with one pinch.">
        <div ref={addField}>
          <form className="inline-form" onSubmit={submitApp}>
            <Field
              label="Website address"
              placeholder="github.com"
              value={url}
              onChange={(e) => setUrl(e.target.value)}
              autoCapitalize="none"
              spellCheck={false}
              inputMode="url"
              required
            />
            <Button type="submit" variant="primary" icon="plus" busy={add.busy}>
              Add
            </Button>
          </form>
        </div>
        <ErrorNote message={add.error ?? remove.error} />
      </Card>

      {apps.loading && !apps.data ? (
        <Loading />
      ) : websites.length ? (
        <Group title="Websites">
          {websites.map((a) => (
            <Row
              key={a.id}
              icon={<SiteTile url={a.url} size="sm" />}
              title={a.name}
              detail={new URL(a.url).hostname}
              trailing={<Button variant="ghost" icon="trash" onClick={() => void remove.run(a.id)} aria-label={`Remove ${a.name}`} />}
            />
          ))}
        </Group>
      ) : null}
      <ErrorNote message={apps.error} onRetry={() => void apps.reload()} />

      <Group title="Built in">
        {BUILT_INS.map((b) => (
          <Row key={b.id} icon={<BuiltInTile app={b} size="sm" />} title={b.name} detail={b.detail} to={b.to} />
        ))}
      </Group>

      <Card title="Companion" description="Paste the glasses link Companion shows on your Mac. It must be https, or an address on your own network.">
        <form className="inline-form" onSubmit={submitCompanion}>
          <Field
            label="Companion glasses link"
            placeholder="http://192.168.1.20:8787/glass#…"
            value={companion}
            onChange={(e) => setCompanion(e.target.value)}
            autoCapitalize="none"
            spellCheck={false}
            inputMode="url"
          />
          <Button type="submit" variant="primary" busy={saveCompanion.busy}>
            Save
          </Button>
        </form>
        {prefs.data?.companionLink ? (
          <button className="link-button" onClick={() => void saveCompanion.run(null)}>
            Remove the link
          </button>
        ) : null}
        <ErrorNote message={saveCompanion.error} />
      </Card>
    </>
  );
}
