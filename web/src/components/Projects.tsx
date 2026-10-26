import { useEffect, useRef, useState } from "react";
import type { CreateProjectRequest, Project, ProjectPage, Transport } from "@farhelm/client-core";
import { Icon } from "./Icon";
import { ProjectWorkflow } from "./ProjectWorkflow";

type ProjectTransport = Transport & {
  projects: NonNullable<Transport["projects"]>;
  project: NonNullable<Transport["project"]>;
  createProject: NonNullable<Transport["createProject"]>;
};

function supportsProjects(transport: Transport | null): transport is ProjectTransport {
  return transport?.kind === "loopback" && transport.supportsProjects === true
    && typeof transport.projects === "function" && typeof transport.project === "function"
    && typeof transport.createProject === "function";
}

function message(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause);
}

/** Projects stay on the active runner until an authorized relay contract exists. */
export function ProjectsList({ transport, projectId = null, onNavigate }: {
  transport: Transport | null;
  projectId?: string | null;
  onNavigate: (to: string) => void;
}) {
  if (!supportsProjects(transport)) {
    return (
      <div className="view">
        <header className="view-head"><h1 className="view-title">Projects</h1></header>
        <section className="card" aria-label="Projects unavailable">
          <p className="tile-note">
            Connect directly to a runner to manage its local projects. Projects are not available over the relay yet.
          </p>
          <button className="btn" onClick={() => onNavigate("/t")}>
            <Icon name="tasks" size={14} /><span>View Tasks</span>
          </button>
        </section>
      </div>
    );
  }
  return <ProjectsWorkspace transport={transport} projectId={projectId} onNavigate={onNavigate} />;
}

interface ProjectResource {
  owner: ProjectTransport;
  id: string | null;
  page: ProjectPage | null;
  detail: Project | null;
  loading: boolean;
  error: string | null;
  morePending: boolean;
  moreError: string | null;
}

function ProjectsWorkspace({ transport, projectId, onNavigate }: {
  transport: ProjectTransport;
  projectId: string | null;
  onNavigate: (to: string) => void;
}) {
  const [revision, setRevision] = useState(0);
  const [resource, setResource] = useState<ProjectResource>(() => ({
    owner: transport, id: projectId, page: null, detail: null, loading: true,
    error: null, morePending: false, moreError: null,
  }));
  const generation = useRef(0);
  const moreInFlight = useRef(false);

  useEffect(() => {
    let cancelled = false;
    generation.current += 1;
    moreInFlight.current = false;
    setResource((current) => ({
      owner: transport, id: projectId,
      page: current.owner === transport && current.id === projectId ? current.page : null,
      detail: current.owner === transport && current.id === projectId ? current.detail : null,
      loading: true, error: null, morePending: false, moreError: null,
    }));
    const load = projectId === null ? transport.projects({ limit: 50 }) : transport.project(projectId);
    void load.then((value) => {
      if (cancelled) return;
      setResource({
        owner: transport, id: projectId, page: projectId === null ? value as ProjectPage : null,
        detail: projectId === null ? null : value as Project, loading: false,
        error: null, morePending: false, moreError: null,
      });
    }).catch((cause: unknown) => {
      if (!cancelled) setResource((current) => ({ ...current, loading: false, error: message(cause) }));
    });
    return () => { cancelled = true; generation.current += 1; };
  }, [transport, projectId, revision]);

  async function loadMore() {
    const cursor = resource.page?.next_cursor;
    if (!cursor || resource.loading || moreInFlight.current) return;
    moreInFlight.current = true;
    const startedGeneration = generation.current;
    setResource((current) => ({ ...current, morePending: true, moreError: null }));
    try {
      const next = await transport.projects({ after: cursor, limit: 50 });
      if (generation.current !== startedGeneration) return;
      setResource((current) => {
        if (current.owner !== transport || current.id !== null || !current.page) return current;
        if (next.next_cursor === cursor) {
          return { ...current, morePending: false, moreError: "The runner returned the same page cursor. Refresh the list to continue." };
        }
        if (current.page.projects[0] && next.projects[0]
          && current.page.projects[0].workspace_id !== next.projects[0].workspace_id) {
          return { ...current, morePending: false, moreError: "The runner returned projects from a different workspace. Refresh the list to continue." };
        }
        const seen = new Set(current.page.projects.map((project) => project.id));
        return { ...current, morePending: false, page: {
          projects: [...current.page.projects, ...next.projects.filter((project) => !seen.has(project.id))],
          next_cursor: next.next_cursor,
        } };
      });
    } catch (cause) {
      if (generation.current === startedGeneration) {
        setResource((current) => ({ ...current, morePending: false, moreError: message(cause) }));
      }
    } finally {
      if (generation.current === startedGeneration) moreInFlight.current = false;
    }
  }

  const current = resource.owner === transport && resource.id === projectId;
  const page = current ? resource.page : null;
  const detail = current ? resource.detail : null;
  const loading = !current || resource.loading;
  const error = current ? resource.error : null;
  const reload = () => setRevision((value) => value + 1);

  return (
    <div className="view">
      <header className="view-head">
        <h1 className="view-title">{projectId === null ? "Projects" : detail?.name ?? "Project"}</h1>
        <div className="approval-actions">
          {projectId !== null ? <button className="btn" onClick={() => onNavigate("/p")}>All projects</button> : null}
          <button className="btn" onClick={reload} disabled={loading || resource.morePending}>
            {loading && (page || detail) ? "Refreshing…" : "Refresh"}
          </button>
        </div>
      </header>
      {error ? (
        <div className="card error" role="alert">
          <b>{page || detail ? "Could not refresh projects." : "Projects unavailable."}</b>
          <p>{error}</p>
          {page || detail ? <p>Showing the last loaded projects from this runner.</p> : null}
        </div>
      ) : null}
      {loading && !page && !detail ? <p className="empty" role="status">Loading {projectId === null ? "projects" : "project"}…</p> : null}
      {detail ? (
        <section className="card" aria-label="Project details" aria-busy={loading}>
          <p className="project-description">{detail.description || "No description."}</p>
          <dl className="project-dates">
            <div><dt>Created</dt><dd><ProjectTime at={detail.created_at} /></dd></div>
            <div><dt>Updated</dt><dd><ProjectTime at={detail.updated_at} /></dd></div>
          </dl>
        </section>
      ) : null}
      {detail ? <ProjectWorkflow transport={transport} projectId={detail.id} onNavigate={onNavigate} /> : null}
      {page ? (
        <section aria-label="Local projects" aria-busy={loading}>
          {page.projects.length === 0 ? <p className="empty">No projects yet. Create a project on this runner.</p> : (
            <div className="projects-grid">
              {page.projects.map((project) => (
                <article className="project-card" key={project.id}>
                  <h2 className="project-name">{project.name}</h2>
                  <p className="project-description">{project.description || "No description."}</p>
                  <button className="btn" aria-label={`Open ${project.name}`} onClick={() => onNavigate(`/p/${encodeURIComponent(project.id)}`)}>Open project</button>
                </article>
              ))}
            </div>
          )}
          {resource.moreError ? <p className="error" role="alert">{resource.moreError}</p> : null}
          {page.next_cursor !== null ? (
            <button className="btn projects-more" onClick={() => void loadMore()} disabled={loading || resource.morePending}>
              {resource.morePending ? "Loading more…" : "Load more"}
            </button>
          ) : null}
        </section>
      ) : null}
      {current && projectId === null ? (
        <CreateProjectForm transport={transport} onCreated={(project) => {
          reload();
          onNavigate(`/p/${encodeURIComponent(project.id)}`);
        }} />
      ) : null}
    </div>
  );
}

function ProjectTime({ at }: { at: number }) {
  const date = new Date(at);
  return Number.isFinite(date.getTime())
    ? <time dateTime={date.toISOString()}>{date.toLocaleString()}</time>
    : <span>Unknown date</span>;
}

function CreateProjectForm({ transport, onCreated }: {
  transport: ProjectTransport;
  onCreated: (project: Project) => void;
}) {
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);
  const active = useRef(true);
  useEffect(() => {
    active.current = true;
    return () => { active.current = false; };
  }, []);

  async function create() {
    if (inFlight.current) return;
    const input: CreateProjectRequest = { name: name.trim(), description };
    if (!input.name || Array.from(input.name).length > 120) {
      setError("Enter a project name between 1 and 120 characters.");
      return;
    }
    if (Array.from(description).length > 4_000 || new TextEncoder().encode(description).length > 16_000) {
      setError("Keep the description within 4,000 characters.");
      return;
    }
    inFlight.current = true;
    setPending(true);
    setError(null);
    try {
      const project = await transport.createProject(input);
      if (!active.current) return;
      setName("");
      setDescription("");
      onCreated(project);
    } catch (cause) {
      if (active.current) setError(message(cause));
    } finally {
      inFlight.current = false;
      if (active.current) setPending(false);
    }
  }

  return (
    <section className="card project-create" aria-label="Create a project">
      <h2 className="chart-title">Create a project</h2>
      <p className="tile-note">Project names and descriptions are stored on this runner.</p>
      <form onSubmit={(event) => { event.preventDefault(); void create(); }} aria-busy={pending}>
        <label className="tile-label" htmlFor="project-name">Name</label>
        <input className="pair-input" id="project-name" name="name" value={name}
          onChange={(event) => setName(event.target.value)} required maxLength={240} disabled={pending} autoComplete="off" />
        <label className="tile-label" htmlFor="project-description">Description <span className="tile-note">(optional)</span></label>
        <textarea className="pair-input" id="project-description" name="description" value={description}
          onChange={(event) => setDescription(event.target.value)} rows={4} maxLength={8_000} disabled={pending} />
        {error ? <p className="error" role="alert">{error}</p> : null}
        <button className="btn btn-primary" type="submit" disabled={pending}>{pending ? "Creating…" : "Create project"}</button>
      </form>
    </section>
  );
}
