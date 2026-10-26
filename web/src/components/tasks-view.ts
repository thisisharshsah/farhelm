/** Optional task layout preference must never prevent task review. */
export type TaskViewMode = "list" | "board";

const VIEW_STORAGE_KEY = "farhelm-tasks-view";

export function readTaskView(): TaskViewMode {
  try {
    return localStorage.getItem(VIEW_STORAGE_KEY) === "board" ? "board" : "list";
  } catch {
    return "list";
  }
}

export function saveTaskView(mode: TaskViewMode): void {
  try {
    localStorage.setItem(VIEW_STORAGE_KEY, mode);
  } catch {
    // The current layout still works when browser storage is unavailable.
  }
}
