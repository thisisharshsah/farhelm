import { afterEach, describe, expect, it, vi } from "vitest";
import { createRunnerApi, HttpTransport, isProject, parseProject, parseProjectPage, type Project } from "./index.ts";

const project: Project = {
  id: "01PROJECT", workspace_id: "01LOCAL", name: "Local development", description: "Synthetic project",
  budget_cap_usd: null, created_at: 1_000, updated_at: 1_000,
};

afterEach(() => vi.unstubAllGlobals());

describe("project response validation", () => {
  it("accepts project metadata and compatible additional server fields", () => {
    expect(parseProject({ ...project, future_field: true })).toMatchObject(project);
    expect(parseProject({ ...project, name: "🛠".repeat(120), description: "🛠".repeat(4_000) })).toBeTruthy();
    expect(parseProjectPage({ projects: [project], next_cursor: project.id })).toEqual({ projects: [project], next_cursor: project.id });
  });

  it.each([
    null, [], {}, { ...project, id: "" }, { ...project, workspace_id: 1 },
    { ...project, name: " " }, { ...project, name: "a".repeat(121) },
    { ...project, description: "x".repeat(4_001) }, { ...project, budget_cap_usd: Infinity },
    { ...project, budget_cap_usd: -1 }, { ...project, budget_cap_usd: undefined },
    { ...project, created_at: -1 }, { ...project, updated_at: 1.5 },
  ])("rejects malformed project records %#", (value) => {
    expect(isProject(value)).toBe(false);
    expect(() => parseProject(value)).toThrow("invalid project");
  });

  it.each([
    null, {}, [], { projects: [], next_cursor: "dangling" }, { projects: [project], next_cursor: 1 },
    { projects: [{ ...project, name: null }], next_cursor: null },
    { projects: [project, project], next_cursor: null },
    { projects: [project], next_cursor: "another-id" },
    { projects: [project, { ...project, id: "another-id", workspace_id: "another-workspace" }], next_cursor: null },
    { projects: Array.from({ length: 101 }, (_, index) => ({ ...project, id: String(index) })), next_cursor: null },
  ])("rejects malformed or unbounded project pages %#", (value) => {
    expect(() => parseProjectPage(value)).toThrow("invalid project list");
  });
});

describe("runner project HTTP boundary", () => {
  it("encodes opaque cursors and IDs and serializes only writable fields", async () => {
    const fetch = vi.fn().mockImplementation((url: string) => Promise.resolve(new Response(JSON.stringify(
      url.includes("?after=") ? { projects: [project], next_cursor: null }
        : url.endsWith("/opaque%2Fid%3F") ? { ...project, id: "opaque/id?" } : project,
    ))));
    vi.stubGlobal("fetch", fetch);
    const api = createRunnerApi("http://localhost:7842/");
    await expect(api.projects({ after: "opaque/id?", limit: 50 })).resolves.toMatchObject({ projects: [project] });
    expect(fetch.mock.calls[0]?.[0]).toBe("http://localhost:7842/v1/projects?after=opaque%2Fid%3F&limit=50");
    await api.project("opaque/id?");
    expect(fetch.mock.calls[1]?.[0]).toBe("http://localhost:7842/v1/projects/opaque%2Fid%3F");
    await api.createProject({ name: "Local development", description: "Synthetic project", workspace_id: "must-not-leave-client" } as { name: string; description: string });
    expect(JSON.parse(fetch.mock.calls[2]?.[1].body as string)).toEqual({ name: "Local development", description: "Synthetic project" });
    await api.createProject({ name: "Only a name" });
    expect(JSON.parse(fetch.mock.calls[3]?.[1].body as string)).toEqual({ name: "Only a name" });
  });

  it("rejects invalid successful responses rather than treating type assertions as validation", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(JSON.stringify({ projects: [{ id: "incomplete" }], next_cursor: null }))));
    await expect(createRunnerApi().projects()).rejects.toThrow("invalid project list");
  });

  it("rejects a detail response for a different resource", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(JSON.stringify(project))));
    await expect(createRunnerApi().project("different-id")).rejects.toThrow("different project");
  });

  it("exposes local project operations through the active HTTP transport", async () => {
    const fetch = vi.fn().mockImplementation((url: string) => Promise.resolve(new Response(JSON.stringify(
      url.endsWith("/v1/projects") ? { projects: [project], next_cursor: null } : project,
    ))));
    vi.stubGlobal("fetch", fetch);
    const transport = new HttpTransport(createRunnerApi(), () => () => {});
    expect(transport.supportsProjects).toBe(true);
    await expect(transport.projects()).resolves.toMatchObject({ projects: [project] });
    await expect(transport.project(project.id)).resolves.toMatchObject(project);
    transport.close();
  });
});

describe("task recovery", () => {
  it("accepts a resumable or explained answer and rejects one that contradicts itself", async () => {
    const { parseTaskRecovery } = await import("./index.ts");
    expect(parseTaskRecovery({ resumable: true, reason: null, interrupted_at: 5, checkpoint_step: 0 }).checkpoint_step).toBe(0);
    expect(parseTaskRecovery({ resumable: false, reason: "its checkout is gone", interrupted_at: 5, checkpoint_step: null }).reason)
      .toBe("its checkout is gone");
    for (const bad of [
      { resumable: true, reason: "but also no", interrupted_at: 5, checkpoint_step: 2 },
      { resumable: true, reason: null, interrupted_at: 5, checkpoint_step: null },
      { resumable: false, reason: null, interrupted_at: null, checkpoint_step: null },
      { resumable: "yes", reason: null, interrupted_at: 5, checkpoint_step: 1 },
    ]) expect(() => parseTaskRecovery(bad)).toThrow();
  });

  it("asks and resumes only through the nested project routes", async () => {
    const calls: Array<[string, string]> = [];
    vi.stubGlobal("fetch", vi.fn(async (url: string, init?: RequestInit) => {
      calls.push([init?.method ?? "GET", url]);
      const body = url.endsWith("/recovery")
        ? { resumable: true, reason: null, interrupted_at: 5, checkpoint_step: 2 }
        : { id: "t1", session_id: "s1", repo_id: "r1", repo_name: "repo", repo_path: "/repo", prompt: "p", status: "running",
          summary: "", files_changed: 0, lines_added: 0, lines_removed: 0, change_summary: "", steps: 2, cost_usd: 0,
          error: null, review_note: null, verify_grade: null, verify_notes: null, verify_model: null, mode: "agent",
          model: null, work_item_id: null, decided_via: null, created_at: 1, updated_at: 2, decided_at: null };
      return new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } });
    }));
    const api = createRunnerApi("http://runner");
    expect((await api.projectTaskRecovery("p1", "t1")).resumable).toBe(true);
    expect((await api.resumeProjectTask("p1", "t1")).status).toBe("running");
    expect(calls).toEqual([
      ["GET", "http://runner/v1/projects/p1/tasks/t1/recovery"],
      ["POST", "http://runner/v1/projects/p1/tasks/t1/resume"],
    ]);
  });
});

describe("workspace search", () => {
  const hit = { kind: "run", id: "r1", project_id: "p1", project_name: "Payments", title: "Bound the backoff",
    snippet: "…the retry delay…", status: "applied", updated_at: 3 };

  it("accepts a well-formed result and rejects an unknown kind", async () => {
    const { parseWorkspaceSearch } = await import("./index.ts");
    expect(parseWorkspaceSearch({ query: "retry", hits: [hit], truncated: false }).hits[0]?.kind).toBe("run");
    expect(() => parseWorkspaceSearch({ query: "retry", hits: [{ ...hit, kind: "file" }], truncated: false })).toThrow();
    expect(() => parseWorkspaceSearch({ query: "retry", hits: [], truncated: "no" })).toThrow();
  });

  it("sends the query encoded, with the limit when given", async () => {
    const urls: string[] = [];
    vi.stubGlobal("fetch", vi.fn(async (url: string) => {
      urls.push(url);
      return new Response(JSON.stringify({ query: "50% off", hits: [], truncated: false }), { status: 200 });
    }));
    await createRunnerApi("http://runner").searchWorkspace("50% off", 10);
    expect(urls).toEqual(["http://runner/v1/search?q=50%25+off&limit=10"]);
  });
});
