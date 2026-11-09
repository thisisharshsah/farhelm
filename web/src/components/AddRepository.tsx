/**
 * Add a repository to a project without knowing its path by heart.
 *
 * Opening this asks the runner to look for checkouts, one level down beside the
 * ones it knows and in the usual folders, and offers each with one button. A
 * folder can be named when the look missed it. Adding registers the checkout and
 * attaches it; it runs nothing.
 */

import { useEffect, useRef, useState } from "react";
import type {
  DiscoveredRepository,
  ProjectRepository,
  RepositoryDiscovery,
  Transport,
} from "@farhelm/client-core";

function message(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause);
}

/** Found checkouts and registered ones together, without what is attached. */
export function addable(
  found: DiscoveredRepository[],
  registered: ProjectRepository[],
  attached: ProjectRepository[],
): DiscoveredRepository[] {
  const byPath = new Map<string, DiscoveredRepository>();
  for (const repo of [...found, ...registered]) byPath.set(repo.path, { name: repo.name, path: repo.path });
  for (const repo of attached) byPath.delete(repo.path);
  return [...byPath.values()].sort((a, b) => a.name.localeCompare(b.name) || a.path.localeCompare(b.path));
}

export function AddRepository({ transport, projectId, attached, onAdded }: {
  transport: Transport;
  projectId: string;
  attached: ProjectRepository[];
  onAdded: (repo: ProjectRepository) => void;
}) {
  const [look, setLook] = useState<RepositoryDiscovery | null>(null);
  const [registered, setRegistered] = useState<ProjectRepository[]>([]);
  const [lookError, setLookError] = useState<string | null>(null);
  const [folder, setFolder] = useState("");
  const [lookedIn, setLookedIn] = useState<string | undefined>(undefined);
  const [adding, setAdding] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);

  useEffect(() => {
    let cancelled = false;
    setLook(null);
    setLookError(null);
    transport.discoverProjectRepositories?.(projectId, lookedIn)
      .then((next) => { if (!cancelled) setLook(next); })
      .catch((cause) => { if (!cancelled) setLookError(message(cause)); });
    return () => { cancelled = true; };
  }, [transport, projectId, lookedIn]);

  useEffect(() => {
    let cancelled = false;
    transport.projectRepoCandidates?.(projectId, { limit: 100 })
      .then((page) => { if (!cancelled) setRegistered(page.repositories); })
      .catch(() => { /* The look above still offers what is on disk. */ });
    return () => { cancelled = true; };
  }, [transport, projectId]);

  const add = async (path: string) => {
    if (inFlight.current || !transport.addProjectRepository) return;
    inFlight.current = true;
    setAdding(path);
    setError(null);
    try {
      const repo = await transport.addProjectRepository(projectId, path);
      setFolder("");
      onAdded(repo);
    } catch (cause) {
      setError(message(cause));
    } finally {
      inFlight.current = false;
      setAdding(null);
    }
  };

  const rows = addable(look?.repositories ?? [], registered, attached);
  const busy = adding !== null;

  return (
    <section className="add-repo" aria-label="Add a repository">
      <h3>Add a repository</h3>
      {look === null && !lookError ? <p role="status" className="tile-note">Looking for repositories on this runner…</p> : null}
      {lookError ? <p className="error" role="alert">{lookError}</p> : null}
      {rows.length > 0 ? (
        <ul className="add-repo-list">
          {rows.map((repo) => (
            <li key={repo.path}>
              <span className="add-repo-name"><b>{repo.name}</b><span className="muted" title={repo.path}>{repo.path}</span></span>
              <button
                type="button"
                className="btn btn-small"
                aria-label={`Add ${repo.name}`}
                disabled={busy}
                onClick={() => void add(repo.path)}
              >
                {adding === repo.path ? "Adding…" : "Add"}
              </button>
            </li>
          ))}
        </ul>
      ) : null}
      {look && rows.length === 0 ? (
        <p className="tile-note">
          No other repositories found in {look.searched.length > 0 ? look.searched.join(", ") : "the usual folders"}.
        </p>
      ) : null}
      {look?.truncated ? <p className="tile-note">There are more than this list shows. Name the folder below to narrow it.</p> : null}
      <form className="add-repo-other" onSubmit={(event) => { event.preventDefault(); if (folder.trim()) void add(folder.trim()); }}>
        <label htmlFor={`add-repo-${projectId}`} className="tile-label">Somewhere else</label>
        <input
          id={`add-repo-${projectId}`}
          className="pair-input"
          value={folder}
          onChange={(event) => setFolder(event.target.value)}
          placeholder="/full/path/to/folder"
          spellCheck={false}
          autoCapitalize="none"
          autoCorrect="off"
          disabled={busy}
        />
        <button type="submit" className="btn btn-small" disabled={busy || !folder.trim()}>Add this repository</button>
        <button type="button" className="btn btn-quiet btn-small" disabled={busy || !folder.trim()} onClick={() => setLookedIn(folder.trim())}>Look inside</button>
      </form>
      {error ? <p className="error" role="alert">{error}</p> : null}
    </section>
  );
}
