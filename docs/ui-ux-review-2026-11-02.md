# Workspace usability review, 2026-11-02

This increment follows the existing product direction: a Task is planned work, a Run is an agent attempt, and a conversation can lead to either. It keeps the existing shell, design tokens, native form controls and gateway behavior.

## Reference patterns

- [Cursor's modes guide](https://prod.cursor.com/help/ai-features/agent) presents explicit choices for understanding code, planning changes and executing them. Farhelm already has its own approved Ask, Plan, Agent and Review vocabulary. Keep those choices visible at the point of action.
- [monday.com's board filters](https://support.monday.com/hc/en-us/articles/360003624660-The-Board-Filters) support narrowing a large work list. Farhelm now provides task search and project filtering using the existing board controls.
- [W3C disclosure pattern](https://www.w3.org/WAI/ARIA/apg/patterns/disclosure/) gives the keyboard and expanded-state contract for a navigation disclosure. The mobile project list uses a native button, explicit expanded state, and focus restoration after choosing an item.

These are reference patterns, not a claim of feature parity. No new component framework or model configuration is introduced.

## Changes

1. **Project navigation:** a compact header and expandable list on narrow screens; independently scrolling navigation on desktop; search of loaded items; explicit pagination for conversations, tasks, runs and attached repositories. Completed tasks remain reachable. Counts with a plus sign indicate more pages.
2. **Reliable links:** a selected conversation resolves by its own ID rather than being rejected because it is absent from the first list page. Each list has loading, error and retry feedback. Refreshing lists preserves the active conversation draft.
3. **Task and Run language:** standalone agent actions and agent history consistently use Run. The project board retains Task and its planned-work statuses.
4. **Honest mutations:** task cards stay in their confirmed column while status is saving. Rejections preserve the prior status. Switching project, task or runner resets the corresponding editor and ignores late results.
5. **Partial creation:** after a conversation or task is created, a failed or uncertain follow-up message/run offers a link to the saved item. It does not invite creating a second item as a retry. Run creation still has no backend idempotency guarantee.

## Verification and limits

Rendered regression tests cover direct links outside the first page, list pagination and recovery, navigation disclosure, identity changes, draft preservation, duplicate submissions and partial creation. Browser checks use the running local app for navigation and responsive layout without sending model prompts, starting runs or changing customer tasks.

Search operates on loaded data. The cross-project board still loads up to 50 projects and 100 tasks per project and explicitly identifies incomplete coverage. Server-side search (`GET /v1/search`, added 2026-11-04) now covers what the board did not load; conversation message text is not yet searched. Model quality, authentication behavior and native device packaging are outside this UI increment.
