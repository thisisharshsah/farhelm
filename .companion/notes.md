## Goal

- Make every Companion screen look and behave like Apple's native Liquid Glass, replace basic option pickers with polished, enterprise-grade controls, and keep layouts aligned and readable from compact to full screen.
- T-22: move the Advanced side (`apple/Sources/Companion/UI/Advanced/`) onto the design system (`apple/Design/README.md`). This covers board columns, task cards, task detail, model assignment, budgets and the timeline.
- Keep Companion working end to end. Companion does the work itself, with guidance and memory support from Claude in the desktop app.

## Where things are (hosts, user names, accounts, folders, files, pages, job or session numbers)

- T-22 worktree: `/Users/harshsah/.companion/worktrees/farhelm-879947/t-22`, branch `task/t-22-advanced-board-on-liquid-glass-with`, based on `main`.
- Files T-22 has changed so far (not committed): `BoardKanban.swift`, `BoardKit.swift`, `BoardPane.swift`, `BoardTable.swift`, `TaskInspector.swift`, and the new `BoardFilters.swift`, all in `apple/Sources/Companion/UI/Advanced/`.
- Selection controls from T-18:
  - `apple/Sources/Companion/UI/Design/Controls/FilterChips.swift`
  - `apple/Sources/Companion/UI/Design/Controls/SelectionControlsDemo.swift` (usage examples)
  - The model picker, shared by the chat, the supervisor and task cards since T-61: `apple/Sources/Companion/UI/Design/Controls/ModelPickerPopup.swift`
- Model list (source, cost, window): `apple/Sources/Companion/Advanced/ModelRoster.swift`.
- Task assignment and model choice types: `apple/Shared/CompanionBoard/Sources/CompanionBoard/WorkItem.swift`. These are read-only for T-22: the board's rules must not change.
- Snapshot script: `apple/scripts/snapshots.sh`. Build: `bash apple/build.sh`.
- Checkout `~/Project/farhelm`. From `apple/`, build with `bash build.sh` or rebuild and restart with `bash build.sh restart`. Log `apple/.build/restart.log`. App `apple/dist/Companion.app`.
- Project notes live in `.companion/notes.md`. Companion learns from the Claude app through Settings > Skills.
- Supervisor stops go through `AppState.swift` near line 4141 and `AgentJob.stoppedBySupervisor()` in `apple/Sources/Companion/Support/AgentJob.swift`. `Board.autopilotMayStart` (`Board.swift:410`) and `mayCarryOn` skip runs that ended as `.supervisor`.
- Design files under `apple/` are `Sources/Companion/UI/Design/Theme.swift`, `Sources/Companion/UI/Design/GlassSurfaces.swift` and `Shared/CompanionDesign/Sources/CompanionDesign/OrbitMark.swift`. Chat selection lives in `ChatSelection.swift`.
- Keep untracked `apple/sample.txt` and `apple/sample2.txt` out of commits.

## What works and what does not (ways that failed, with the error, and the way that works instead)

- Run 1 stopped twice: the app was quit, then Codex hit its usage limit. The edits it left have not been built or checked yet.
- `ls` or `wc` on a missing `.companion/` exits 1. Create the directory and notes file before appending.
- Claude Opus 5.5, acting as supervisor, allowed read-only checks and file creation inside the owner's project.
- Force-quits and crashes skip `applicationWillTerminate`. Debounced saves preserve state about 0.5 seconds after a change. Check `git log` before redoing work after a force-quit. The restore edits were already in `bd95506` when the tree looked clean.
- Match U+2014 in code-server's window title with `\u{2014}` and describe it in comments. Scan added lines for U+2014 (`grep $'\u2014'`), keys and tokens before committing.
- Update notes before staging to keep the work in one commit. Fold in an accidental second commit with `git reset --soft HEAD~1` and `git commit --amend --no-edit` only before pushing.
- If a session disables file edits, turn edits on before making changes.
- The board records supervisor stops and `Advanced` ends the process. Naming `WorkRun` in `AppState.swift` fails to build because the file lacks a CompanionBoard import. Pass plain flags to `AgentJob`, which imports the package and sets the run ending.
- `bash build.sh check` passes with one pre-existing warning in `AgentSession.swift`.
- The first Nov 26 restart attempt was stopped after two minutes without output. The command can return while the build continues in the background. Companion restarts automatically after a successful build. When verification is requested, use the restart log and process list.

## T-21 review follow-up

- Worktree: `/Users/harshsah/.companion/worktrees/farhelm-879947/t-21`, branch `task/t-21-floating-panel-overlay-and-dock-as-true`.
- The glass work and merge are committed in `b89d857` and `378370b`. The previous run reported a passing build check. Do not redo the restyle.
- FloatingPanel.swift, OverlayView.swift and OrbitDock.swift are all still in use. Previous verification found a clear borderless panel, design-system glass, compact/expanded morphing, Reduce Motion fades and selection controls, with none of the prohibited blur or colour implementations.
- Six panel snapshots were saved under `apple/.build/snapshots/`, at minimum, default and maximum sizes in light and dark. Earlier notes do not confirm that all six were visually reviewed.
- Restored `.companion/checks.json` from the shared base, leaving no working-tree change to it. Restored shared notes from `companion/main`, preserving T-22 notes and user decisions.
- Review verification: `bash apple/build.sh check` passed. The final diff contains only this T-21 notes section, the checks file matches the shared base exactly, and the whitespace check passed. The completed UI is unchanged.

## Done (results, with numbers)

- Merged into main before T-22: T-16 (glass design system: tokens, glass surfaces, size rules) and T-18 (searchable picker, switcher, filter chips, settings rows).
- T-22 so far (not built):
  - `BoardFilters.swift` written.
  - Filter wiring added to the kanban view, the table view and the board pane.
- Nov 24, 2026. Created `.companion/notes.md` with two sections covering the standing rule and eight changes, preserving existing content.
- Nov 24, `bd95506`. Fixed the layout loop that froze Companion and required a force-quit. Companion restores the open chat, sidebar, zoom, panel position and frame before showing the panel. Changes save after about 0.5 seconds and on quit. Reported to the owner.
- Nov 24, `4d5b3cc`. Dragging the circle while the panel is hidden now saves its position.
- Nov 25, `6653988` on `main`, merged into `companion/main` as `32bbfb2`. Landed 77 files covering speed and memory, project notes, learning from Claude, scroll and restore, the VS Code bridge, passkeys, the browser and ADR 0020.
- Nov 25, `5f2d44a` on `main`, merged into `companion/main` as `bf09c46`. Supervisor `stop` (`cancel`, `halt`) requires a run, records the reason, queues the task in `ChangeSummary.stopping`, ends the run as `.supervisor` and returns the task to To do to wait for the owner. The prompt calls for stopping and replanning in the same reply when a run exceeds 3× its estimate, repeats reads or failing edits, or loops after model fallback. All 147 board tests passed, including two new tests. `bash build.sh check` passed.
- Nov 25, supervisor `approve` (`accept`, `pass`) on `main`. `Board.apply` requires Review, no active run and a last run whose checks ran and passed. Refusals leave a reason in Review. `ChangeSummary.approving` feeds `Advanced.approveForSupervisor`, which checks `TaskCopies.wouldNotMerge` via `git merge-tree`. Conflicts leave a note in Review. Otherwise the card's `Advanced.approve` merges and moves the task to Done.
- Nov 25, supervisor `delete` (`trash`) on `main` is separate from `remove`. For a task with an active run or open copy, the owner must name the task in their own message. `Board.named(in:)` accepts `T-3`, `t3`, `#3` and `task 3`. Refusals leave a reason. Allowed deletions go through `ChangeSummary.deleting` and the card's `Advanced.remove`, with each run written to the board log before deletion.
- The approve and delete rules are in the supervisor prompt under the standing review rule. All 151 board tests passed, including four new tests. `bash build.sh check` passed.
- Nov 26. Made “Select across messages” the sole rendering path in `ChatSelection.swift` and removed its switch. Settings has about 30 switches, with no trial switches remaining.
- Nov 26. An earlier restart succeeded according to the restart log. The process list confirmed Companion was running from `apple/dist/Companion.app`.
- Latest task. Ran `cd ~/Project/farhelm/apple && bash build.sh restart 2>&1 | tail -15` and stopped after reporting the output as requested. Verified Nov 28: restart.log ends "Built dist/Companion.app" then "Restarting" (01:43), and Companion runs from `apple/dist/Companion.app` (started 01:45). The quit was the restart itself: no crash report after Nov 25. Newest report (Nov 25 19:16) is an older SIGSEGV on the main thread inside Chromium Embedded Framework (KERN_INVALID_ADDRESS at 0x40).
  > Building apart now; Companion restarts by itself when it is built (log: apple/.build/restart.log).

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
- No follow-up requested for the latest restart.

## User decisions

- Never change `apple/Shared/CompanionBoard/` for UI work.
- Commits carry no Co-Authored-By or AI attribution line. Never write the em dash.
- Names others will see are proposed first and used only after the owner confirms them.
- Read project notes and work logs before acting, read project files without asking, and update notes after every task.
