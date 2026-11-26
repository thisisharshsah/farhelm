## Goal
- Make every Companion screen look and behave like Apple's native Liquid Glass, replace basic option pickers with polished, enterprise-grade controls, and keep layouts aligned and readable from compact to full screen.
- T-22: move the Advanced side (`apple/Sources/Companion/UI/Advanced/`) onto the design system (`apple/Design/README.md`). This covers board columns, task cards, task detail, model assignment, budgets and the timeline.

## Where things are (hosts, user names, accounts, folders, files, pages, job or session numbers)
- T-22 worktree: `/Users/harshsah/.companion/worktrees/farhelm-879947/t-22`, branch `task/t-22-advanced-board-on-liquid-glass-with`, based on `main`.
- Files T-22 has changed so far (not committed): `BoardKanban.swift`, `BoardKit.swift`, `BoardPane.swift`, `BoardTable.swift`, `TaskInspector.swift`, and the new `BoardFilters.swift`, all in `apple/Sources/Companion/UI/Advanced/`.
- Selection controls from T-18:
  - `apple/Sources/Companion/UI/Design/Controls/FilterChips.swift`
  - `apple/Sources/Companion/UI/Design/Controls/SelectionControlsDemo.swift` (usage examples)
  - The searchable picker, used for a chat's model in `apple/Sources/Companion/UI/ModelPicker.swift` (around lines 630-790)
- Model list (source, cost, window): `apple/Sources/Companion/Advanced/ModelRoster.swift`.
- Task assignment and model choice types: `apple/Shared/CompanionBoard/Sources/CompanionBoard/WorkItem.swift`. These are read-only for T-22: the board's rules must not change.
- Snapshot script: `apple/scripts/snapshots.sh`. Build: `bash apple/build.sh`.

## What works and what does not (ways that failed, with the error, and the way that works instead)
- Run 1 stopped twice: the app was quit, then Codex hit its usage limit. The edits it left have not been built or checked yet.

## Done (results, with numbers)
- Merged into main before T-22: T-16 (glass design system: tokens, glass surfaces, size rules) and T-18 (searchable picker, switcher, filter chips, settings rows).
- T-22 so far (not built):
  - `BoardFilters.swift` written.
  - Filter wiring added to the kanban view, the table view and the board pane.

## Next
- Check the current diff, then finish model assignment in `TaskInspector` and `BoardTable` with the searchable picker, showing each model's source, cost and window from `ModelRoster`.
- Use selection controls for status, priority and kind.
- Make sure filtering by status, priority and model works and shows how many filters are active.
- Columns by width class:
  - Wide: all five side by side.
  - Regular: horizontal scrolling with snapping.
  - Compact: one list grouped by status, with a status switcher.
- Column headers, filters and toolbars on glass; cards and details on plain backgrounds.
- Cards: title, then one row of badges (priority, kind, model, tokens) that truncates cleanly.
- Replace literal colours, font sizes and spacing with tokens, including in budgets and the timeline.
- Add board screens with 15 or more tasks to `apple/scripts/snapshots.sh`, at compact, regular and wide, light and dark. Look at the images.
- `apple/build.sh` must exit 0.

## User decisions
- Never change `apple/Shared/CompanionBoard/` for UI work.
- Commits carry no Co-Authored-By or AI attribution line. Never write the em dash.
- Names others will see are proposed first and used only after the owner confirms them.