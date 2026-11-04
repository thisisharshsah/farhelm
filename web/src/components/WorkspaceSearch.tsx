/**
 * Search across every project in the local workspace, on the runner.
 *
 * The Board page loads at most 50 projects and 100 tasks each, so filtering
 * what is loaded can miss things. This asks the runner instead, which scans
 * projects, tasks, runs and conversation titles in one query, and links each
 * hit to where it lives.
 */

import { useEffect, useRef, useState } from "react";
import {
  since,
  type SearchHit,
  type SearchHitKind,
  type TaskStatus,
  type Transport,
  type WorkItemStatus,
  type WorkspaceSearch,
} from "@farhelm/client-core";
import { StatusPill, TASK_STATUS, WORK_ITEM_STATUS, type StatusLook } from "./status";

/** Wait this long after the last keystroke before asking the runner. */
export const SEARCH_DEBOUNCE_MS = 250;
const MIN_QUERY_CHARS = 2;

const KIND_LABEL: Record<SearchHitKind, string> = {
  project: "Project",
  task: "Task",
  run: "Run",
  conversation: "Conversation",
};

/** Where a hit lives in the app; mirrors the router's project paths. */
export function hitPath(hit: SearchHit): string {
  const project = `/p/${encodeURIComponent(hit.project_id)}`;
  const id = encodeURIComponent(hit.id);
  switch (hit.kind) {
    case "project": return project;
    case "task": return `${project}/w/${id}`;
    case "run": return `${project}/t/${id}`;
    case "conversation": return `${project}/c/${id}`;
  }
}

function statusLook(hit: SearchHit): StatusLook | null {
  if (hit.status === null) return null;
  if (hit.kind === "task" && hit.status in WORK_ITEM_STATUS) return WORK_ITEM_STATUS[hit.status as WorkItemStatus];
  if (hit.kind === "run" && hit.status in TASK_STATUS) return TASK_STATUS[hit.status as TaskStatus];
  return null;
}

type Searchable = Transport & Required<Pick<Transport, "searchWorkspace">>;

export function supportsSearch(transport: Transport | null): transport is Searchable {
  return transport?.kind === "loopback" && typeof transport.searchWorkspace === "function";
}

export function WorkspaceSearchResults({ transport, query, onNavigate }: {
  transport: Searchable;
  query: string;
  onNavigate: (path: string) => void;
}) {
  const trimmed = query.trim();
  const [result, setResult] = useState<WorkspaceSearch | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState(false);
  // Only the latest query's answer may land; an earlier one arriving late is dropped.
  const latest = useRef(0);

  useEffect(() => {
    const ticket = ++latest.current;
    setError(null);
    if (Array.from(trimmed).length < MIN_QUERY_CHARS) {
      setResult(null); setPending(false);
      return;
    }
    setPending(true);
    const timer = setTimeout(() => {
      transport.searchWorkspace(trimmed)
        .then((value) => { if (ticket === latest.current) setResult(value); })
        .catch((cause: unknown) => {
          if (ticket === latest.current) setError(cause instanceof Error ? cause.message : String(cause));
        })
        .finally(() => { if (ticket === latest.current) setPending(false); });
    }, SEARCH_DEBOUNCE_MS);
    return () => clearTimeout(timer);
  }, [transport, trimmed]);

  if (Array.from(trimmed).length < MIN_QUERY_CHARS) return null;
  const hits = result?.query === trimmed ? result.hits : null;

  return (
    <section className="workspace-search" aria-label="Search results across the workspace">
      <h3 className="kanban-column-head">
        Everywhere in this workspace
        {pending ? <span className="muted" role="status"> Searching…</span> : null}
      </h3>
      {error ? <p className="error" role="alert">{error}</p> : null}
      {hits && hits.length === 0 ? <p className="tile-note">Nothing in any project matches “{trimmed}”.</p> : null}
      {hits && hits.length > 0 ? (
        <ul className="workspace-search-list">
          {hits.map((hit) => {
            const look = statusLook(hit);
            return (
              <li className="workspace-search-hit" key={`${hit.kind}:${hit.id}`}>
                <div className="kanban-card-meta">
                  <span className="workspace-search-kind">{KIND_LABEL[hit.kind]}</span>
                  {hit.kind !== "project" ? <span className="thread-crumb">{hit.project_name}</span> : null}
                  {look ? <StatusPill look={look} size="sm" /> : null}
                  <span className="muted">{since(hit.updated_at)}</span>
                </div>
                <button type="button" className="work-item-title" onClick={() => onNavigate(hitPath(hit))}>
                  {hit.title}
                </button>
                {hit.snippet ? <p className="tile-note workspace-search-snippet">{hit.snippet}</p> : null}
              </li>
            );
          })}
        </ul>
      ) : null}
      {result?.truncated && hits ? <p className="tile-note">Showing the newest {hits.length}. Add words to narrow the search.</p> : null}
    </section>
  );
}
