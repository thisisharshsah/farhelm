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
