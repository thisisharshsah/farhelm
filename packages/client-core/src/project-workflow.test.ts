import { afterEach, expect, it, vi } from "vitest";
import fixture from "../../../crates/farhelm-proto/tests/fixtures/wire.json";
import { createRunnerApi, HttpTransport, parseProjectRepository, parseProjectRepositoryPage,
  parseProjectTaskPage, parseTaskDetail, parseTaskView, type TaskDetail, type StartProjectTaskRequest } from "./index.ts";

const task = fixture.task_detail as TaskDetail;
const repo = { id: task.repo_id, name: task.repo_name, path: task.repo_path };
const response = (value: unknown) => new Response(JSON.stringify(value));

afterEach(() => vi.unstubAllGlobals());

it("validates the real Rust task fixture including its review diff and output", () => {
  expect(parseTaskDetail(fixture.task_detail)).toEqual(fixture.task_detail);
  expect(parseTaskView(task)).toMatchObject({ id: task.id });
  expect(parseProjectTaskPage({ tasks: [task], next_cursor: task.id })).toMatchObject({ tasks: [task] });
  expect(parseProjectRepositoryPage({ repositories: [repo], next_cursor: null })).toEqual({ repositories: [repo], next_cursor: null });
});

it.each([
  { ...task, cost_usd: -1 }, { ...task, status: "invented" }, { ...task, verify_grade: "unknown" },
  { ...task, steps: 1.5 }, { ...task, repo_id: "repo\n" }, { ...task, error: undefined },
  { ...task, decided_via: "untrusted" }, { ...task, updated_at: NaN },
])("rejects malformed project task records %#", (value) => {
  expect(() => parseTaskView(value)).toThrow("invalid project task");
});

it.each([
  { ...task, changes: null }, { ...task, patch: undefined }, { ...task, output: Array.from({ length: 201 }, () => task.output[0]) },
  { ...task, changes: { files: [{ path: "x", kind: "modified", added: 1, removed: 0, binary: false, hunks: [{ old_start: 1, old_len: 0, new_start: 1, new_len: 1, lines: [{ tag: "execute", text: "no" }] }] }] } },
  { ...task, output: [{ seq: 1, text: "one", at_ms: 1 }, { seq: 1, text: "duplicate", at_ms: 1 }] },
])("rejects malformed or unbounded detail payloads %#", (value) => {
  expect(() => parseTaskDetail(value)).toThrow(/invalid project/);
});

it("rejects repository and task pages with invalid records, cursors or duplicate identities", () => {
  expect(() => parseProjectRepository({ ...repo, path: 1 })).toThrow("invalid project repository");
  expect(() => parseProjectRepository({ ...repo, id: "🛠".repeat(33) })).toThrow("invalid project repository");
  expect(() => parseProjectRepositoryPage({ repositories: [repo], next_cursor: "different" })).toThrow("invalid project page cursor");
  expect(() => parseProjectTaskPage({ tasks: [task, task], next_cursor: null })).toThrow("invalid project page cursor");
  expect(() => parseProjectTaskPage({ tasks: Array.from({ length: 101 }, () => task), next_cursor: null })).toThrow("invalid project task list");
});

it("encodes nested resource routes and sends only registered IDs and writable task fields", async () => {
  const fetch = vi.fn()
    .mockResolvedValueOnce(response({ repositories: [repo], next_cursor: null }))
    .mockResolvedValueOnce(response({ repositories: [repo], next_cursor: null }))
    .mockResolvedValueOnce(response(repo))
    .mockResolvedValueOnce(response({ tasks: [task], next_cursor: null }))
    .mockResolvedValueOnce(response(task))
    .mockResolvedValueOnce(response(task))
    .mockResolvedValueOnce(response(task))
    .mockResolvedValueOnce(response(task));
  vi.stubGlobal("fetch", fetch);
  const api = createRunnerApi("http://127.0.0.1:7842");
  await api.projectRepoCandidates("project/id", { after: "repo/cursor", limit: 50 });
  await api.projectRepositories("project/id");
  await api.attachProjectRepository("project/id", repo.id);
  await api.projectTasks("project/id", { limit: 50 });
  await api.startProjectTask("project/id", { repo_id: repo.id, prompt: "Implement synthetic change", max_steps: 3,
    repo_path: "/must-not-be-sent", project_id: "must-not-be-sent" } as StartProjectTaskRequest);
  await api.projectTask("project/id", task.id);
  await api.reviewProjectTask("project/id", task.id, "reject", "web", "Fix synthetic issue");
  await api.revertProjectTask("project/id", task.id, "phone");
  expect(fetch.mock.calls[0]?.[0]).toBe("http://127.0.0.1:7842/v1/projects/project%2Fid/repo-candidates?after=repo%2Fcursor&limit=50");
  expect(fetch.mock.calls[1]?.[0]).toBe("http://127.0.0.1:7842/v1/projects/project%2Fid/repos");
  expect(JSON.parse(fetch.mock.calls[2]?.[1].body as string)).toEqual({ repo_id: repo.id });
  expect(JSON.parse(fetch.mock.calls[4]?.[1].body as string)).toEqual({ repo_id: repo.id, prompt: "Implement synthetic change", budget_usd: null, max_steps: 3, retry_of: null });
  expect(fetch.mock.calls[5]?.[0]).toBe(`http://127.0.0.1:7842/v1/projects/project%2Fid/tasks/${encodeURIComponent(task.id)}`);
  expect(JSON.parse(fetch.mock.calls[6]?.[1].body as string)).toEqual({ decision: "reject", via: "web", note: "Fix synthetic issue" });
  expect(JSON.parse(fetch.mock.calls[7]?.[1].body as string)).toEqual({ via: "phone" });
});

it("rejects mismatched repository, task and start response identities", async () => {
  vi.stubGlobal("fetch", vi.fn()
    .mockResolvedValueOnce(response({ ...repo, id: "other-repo" }))
    .mockResolvedValueOnce(response({ ...task, repo_id: "other-repo" }))
    .mockResolvedValueOnce(response({ ...task, id: "other-task" }))
    .mockResolvedValueOnce(response({ ...task, id: "other-task" }))
    .mockResolvedValueOnce(response({ ...task, id: "other-task" })));
  const api = createRunnerApi();
  await expect(api.attachProjectRepository("project", repo.id)).rejects.toThrow("different repository");
  await expect(api.startProjectTask("project", { repo_id: repo.id, prompt: "Synthetic" })).rejects.toThrow("different repository");
  await expect(api.projectTask("project", task.id)).rejects.toThrow("different task");
  await expect(api.reviewProjectTask("project", task.id, "approve", "web")).rejects.toThrow("different task");
  await expect(api.revertProjectTask("project", task.id, "web")).rejects.toThrow("different task");
});

it("exposes project workflow only on the direct transport and preserves decision surface", async () => {
  const api = createRunnerApi();
  const review = vi.spyOn(api, "reviewProjectTask").mockResolvedValue(task);
  const revert = vi.spyOn(api, "revertProjectTask").mockResolvedValue(task);
  const transport = new HttpTransport(api, () => () => {}, "phone");
  expect(transport.supportsProjectWorkflow).toBe(true);
  await transport.reviewProjectTask("project", task.id, "approve");
  await transport.revertProjectTask("project", task.id);
  expect(review).toHaveBeenCalledExactlyOnceWith("project", task.id, "approve", "phone", undefined);
  expect(revert).toHaveBeenCalledExactlyOnceWith("project", task.id, "phone");
  transport.close();
});
