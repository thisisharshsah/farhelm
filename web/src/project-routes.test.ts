import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { expect, it } from "vitest";
import { useRoute } from "./hooks";
import { projectTaskPath } from "./components/ProjectWorkflow";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

it("keeps project and task IDs in the nested route without double encoding opaque IDs", async () => {
  const host = document.createElement("div");
  const root = createRoot(host);
  const prior = location.hash;
  const projectId = "legacy/project ?%";
  const taskId = "legacy/task ?%";
  location.hash = projectTaskPath(projectId, taskId);
  function RouteView() { const [route] = useRoute(); return createElement("output", null, JSON.stringify(route)); }
  try {
    await act(async () => root.render(createElement(RouteView)));
    expect(JSON.parse(host.textContent!)).toEqual({ view: "project-task", projectId, id: taskId });
    await act(async () => { location.hash = `/p/${encodeURIComponent(projectId)}`; dispatchEvent(new HashChangeEvent("hashchange")); });
    expect(JSON.parse(host.textContent!)).toEqual({ view: "project", id: projectId });
  } finally { await act(async () => root.unmount()); location.hash = prior; }
});
