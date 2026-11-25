## Goal
- Show Companion's work as a Claude-style timeline.
- The board supervisor can stop a run, approve a Review task whose checks passed, and delete junk tasks (all done Nov 25, 2026, on main).

## Where things are (hosts, user names, accounts, folders, files, pages, job or session numbers)
- Project notes: `~/Project/farhelm/.companion/notes.md`, at the repository root beside `checks.json`, not under `apple/` (created Nov 24, 2026).
- Companion builds from `~/Project/farhelm/apple`. `bash build.sh restart` builds and relaunches. `bash build.sh check` only compiles.
- Board tests: `swift test --package-path Shared/CompanionBoard`, run from `apple/`.
- Branches: work is committed on `main`, then main is merged into `companion/main` with `--no-ff`, then you switch back to main.
- Reply voice: `Prompts.voice`.
- Launch restore and state saving: `Sources/Companion/CompanionApp.swift` (`restoreSession`, `scheduleSessionSave`, `saveSession`) and `Sources/Companion/UI/FloatingPanel.swift` (panel moves and resizes, the circle's move handler).
- Work timeline: `WorkTimeline` splits the work into stretches between the agent's notes, and `WorkTrail` is the row for one stretch. Both are in `Sources/Companion/UI/OverlayView.swift` (around lines 2640-3420), along with the page preview card. Work steps are in `Sources/Companion/Conversation/Conversation.swift`.
- Supervisor board ops: the op list and prompt rules are in `Sources/Companion/Advanced/Supervisor.swift`. Replies are decoded in `Shared/CompanionBoard/Sources/CompanionBoard/SupervisorReply.swift` into `BoardOperation` in `Operations.swift`. `Board.apply` applies the ops and returns a `ChangeSummary`.
- Advanced applies the supervisor's reply in `Sources/Companion/Advanced/Advanced.swift` (`Advanced.finish`, around lines 660-730). Stopping goes through `Advanced.stop(_:in:bySupervisor:)` (around lines 870-960), then `AppState.stopAgent(in:bySupervisor:)` (`AppState.swift` around line 4141), then `AgentJob.stoppedBySupervisor()` in `Sources/Companion/Support/AgentJob.swift`.
- Autopilot and carry-on skip runs that ended as `.supervisor`: `Board.autopilotMayStart` (`Board.swift:410`) and `mayCarryOn`.
- Design parts: `Sources/Companion/UI/Design/Theme.swift`, `Sources/Companion/UI/Design/GlassSurfaces.swift`, `Shared/CompanionDesign/Sources/CompanionDesign/OrbitMark.swift`.
- Untracked files that stay out of commits: `apple/sample.txt`, `apple/sample2.txt`.

## What works and what does not (ways that failed, with the error, and the way that works instead)
- `ls`/`wc` on `.companion/` fails (exit 1) if the folder doesn't exist yet. Create the folder and file first, then append.
- The supervisor (Claude · Opus 5.5) allowed read-only checks and creating files inside the project for the person.
- Companion froze in a layout loop and had to be force-quit. The loop is fixed.
- A force-quit or crash skips `applicationWillTerminate`, so saving only there loses state. State is now also saved about 0.5 s after any change (debounced).
- After a force-quit, check `git log` before redoing work. The restore edits had already been committed (bd95506) even though the working tree was clean.
- code-server's window title contains an em dash. The code matches it with `\u{2014}`, so comments must describe the title without quoting it literally.
- Before committing, scan the added lines for em dashes (`grep $'\u2014'`) and for keys and tokens.
- Update the notes before staging so the work stays one commit. If a second commit happens anyway, fold it back in with `git reset --soft HEAD~1` and `git commit --amend --no-edit`, and only before pushing.
- If file edits are turned off in a session, stop rather than editing through the shell. Turn edits on first.
- The board package only records changes and can't end a process, so the app (`Advanced`) does the actual stop.
- `AppState.swift` does not import CompanionBoard, so it can't name `WorkRun` (the build fails). Pass plain flags there and let `AgentJob`, which imports it, set the ending.
- `bash build.sh check` shows one warning, in `AgentSession.swift`. It was there before the stop op.

## Done (results, with numbers)
- Nov 24, 2026: created `.companion/notes.md` with 2 sections and overwrote nothing.
  - "Standing rule (Nov 24, 2026)": Companion does the work itself. Claude in the desktop app only guides and helps remember.
  - "Changes made Nov 24, 2026", 8 bullets: notes kept and written after every task; notes and work logs read before acting; project files read without asking; clicks that open a new tab stay in the same tab; scroll follows the newest message unless the user scrolls by hand; the held message is cut to 2 lines on glass; Companion learns from the Claude app (Settings > Skills); replies use a serif font and the Claude-style voice.
- Nov 24, 2026, launch restore (commit bd95506): at launch, before the panel first shows, Companion restores the open chat, sidebar, zoom, panel position and frame. It saves them about 0.5 s after any change and on quit. Reported to the user.
- Nov 24, 2026, commit 4d5b3cc: dragging the circle while the panel is hidden now saves too.
- Nov 25, 2026, commit 6653988 on main: 77 files of Companion work (speed and memory, project notes, learning from the Claude app, scroll and restore fixes, VS Code bridge, passkeys, browser, ADR 0020). Merged into companion/main (32bbfb2).
- Nov 25, 2026, supervisor stop op, commit 5f2d44a on main, merged into companion/main as bf09c46. The supervisor sends `{"op":"stop","id":"T-3","reason":"..."}`, and `cancel` and `halt` also work. `Board.apply` refuses it for a task with no run, leaves the note "Stopped the run: <reason>" and lists the task in `ChangeSummary.stopping`. The run ends as `.supervisor`, the task goes back to To do, and it waits for the person. Prompt rule: stop a run that has used more than 3x its estimate, keeps repeating the same reads or failing edits, or loops after falling back to a weaker model, and re-plan the task in the same reply. All 147 board tests pass (2 new) and `bash build.sh check` passes.
- Nov 25, 2026, supervisor approve and delete ops on main. `{"op":"approve","id":"T-3"}` (also `accept`, `pass`): `Board.apply` takes it only for a task in Review with no run going whose last run's checks ran and all passed; otherwise it leaves "Not approved: <why>. It stays in Review for you." and the task stays in Review. Allowed ones go in `ChangeSummary.approving`; `Advanced.approveForSupervisor` first asks `TaskCopies.wouldNotMerge` (git merge-tree, as `land` does), and on a conflict leaves the reason as a note and keeps the task in Review, else calls the card's own `Advanced.approve(_:in:by: "Supervisor")`, which merges and moves it to Done. `{"op":"delete","id":"T-3","reason":"..."}` (also `trash`; "delete" is no longer another name for `remove`): refused with a "Not deleted: ..." note for a task with unmerged work (a run going on or an open copy, `Board.unmergedWork`) unless the owner named it in their own message (`Board.named(in:)` reads T-3, t3, #3, task 3 from the person's message, never the model's). Before it goes, each of its runs is written to the board log. Allowed ones go in `ChangeSummary.deleting` and the app removes them through the card's `Advanced.remove(_:in:bySupervisor: true)`. Prompt: both op lines, plus rules under the standing review rule. 151 board tests pass (4 new) and `bash build.sh check` passes. 