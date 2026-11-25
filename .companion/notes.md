## Goal
- Keep Companion's project notes and change log current, so work can be picked up in any chat without asking again.
- Companion should reopen as it was left (open chat, window frame, zoom, sidebar), even after a force-quit or crash.
- Show Companion's work as a Claude-style timeline.
- Give the board supervisor a stop-run action (urgent, on main).

## Where things are (hosts, user names, accounts, folders, files, pages, job or session numbers)
- Project notes: `~/Project/farhelm/.companion/notes.md`, at the repository root beside `checks.json`, not under `apple/` (created Nov 24, 2026).
- Companion builds from `~/Project/farhelm/apple`. `bash build.sh restart` builds and relaunches, and `bash build.sh check` only compiles.
- Branches: work is committed on `main`, then main is merged into `companion/main`.
- Reply voice: `Prompts.voice`.
- Launch restore and state saving: `Sources/Companion/CompanionApp.swift` (`restoreSession`, `scheduleSessionSave`, `saveSession`) and `Sources/Companion/UI/FloatingPanel.swift` (panel moves and resizes, the circle's move handler).
- Work timeline: `WorkTimeline` splits the work into stretches between the agent's notes, and `WorkTrail` is the row for one stretch. Both, plus the page preview card, are in `Sources/Companion/UI/OverlayView.swift` (around lines 2640-3420). Work steps are in `Sources/Companion/Conversation/Conversation.swift`.
- Supervisor board ops: the op list and rules in the prompt are in `Sources/Companion/Advanced/Supervisor.swift`. Replies are decoded in `Shared/CompanionBoard/Sources/CompanionBoard/SupervisorReply.swift` into `BoardOperation` in `Operations.swift`. `Board.apply` applies the ops and returns a `ChangeSummary`.
- Advanced applies the supervisor's reply in `Sources/Companion/Advanced/Advanced.swift` (around lines 660-730). The card's Stop calls `advanced.stop(item.id, in: project.id)` (`Advanced.stop`, around lines 870-960), which calls `AppState.stopAgent(in:)` (`AppState.swift` around line 4141). `WorkRun.Ending.supervisor` already exists.
- Design parts: `Sources/Companion/UI/Design/Theme.swift`, `Sources/Companion/UI/Design/GlassSurfaces.swift`, `Shared/CompanionDesign/Sources/CompanionDesign/OrbitMark.swift`.
- Untracked files that stay out of commits: `apple/sample.txt`, `apple/sample2.txt`.

## What works and what does not (ways that failed, with the error, and the way that works instead)
- `ls`/`wc` on `.companion/` fails (exit 1) if the folder doesn't exist yet. Create the folder and file first, then append.
- The supervisor (Claude · Opus 5.5) allowed read-only checks and creating files inside the project for the person.
- Companion froze in a layout loop and had to be force-quit. The loop is fixed.
- A force-quit or crash skips `applicationWillTerminate`, so saving only there loses state. State is now also saved about 0.5 s after any change (debounced).
- Check `git log` before redoing work after a force-quit. The restore edits had already been committed (bd95506) even though the working tree was clean.
- code-server's window title contains an em dash. The code matches it with `\u{2014}`, so comments must describe the title without quoting it literally.
- Before committing, scan the added lines for em dashes (`grep $'\u2014'`) and for keys and tokens.
- Editing the notes after committing made a second commit by mistake. Update the notes before staging so the work stays one commit. If it happens anyway, fold it back in with `git reset --soft HEAD~1` and `git commit --amend --no-edit`, and only before pushing.
- Nov 25, 2026: the stop-op task couldn't edit files because file edits were turned off in that session. It stopped rather than editing through the shell. Turn edits on first.
- The board package only records changes and can't end a process, so the app (`Advanced`) has to do the actual stop.

## Done (results, with numbers)
- Nov 24, 2026: created `.companion/notes.md` with 2 sections and overwrote nothing.
  - "Standing rule (Nov 24, 2026)": Companion does the work itself. Claude in the desktop app only guides and helps remember.
  - "Changes made Nov 24, 2026", 8 bullets: notes kept in `.companion/notes.md` and written after every task; notes and work logs read before acting; project files read without asking; clicks that open a new tab stay in the same tab; scroll follows the newest message unless the user scrolls by hand; the held message is cut to 2 lines on glass; Companion learns from the Claude app (Settings > Skills); replies use a serif font and the Claude-style voice.
- Nov 24, 2026, launch restore (commit bd95506): at launch, before the panel first shows, Companion restores the open chat, sidebar, zoom, panel position and frame. It saves them about 0.5 s after any change and on quit.
- Nov 24, 2026, gap fixed (commit 4d5b3cc): dragging the circle while the panel was hidden now saves too, in the circle's move handler. `bash build.sh check` passed.
- Nov 25, 2026, commit 6653988 on main: 77 files of Companion work (speed and memory, project notes, learning from the Claude app, scroll and restore fixes, VS Code bridge, passkeys, browser, ADR 0020). `bash build.sh check` passed. Not pushed. Merged into companion/main (32bbfb2).
- The restore work has been reported to the user.
- Nov 25, 2026, supervisor stop op on main: `BoardOperation.stop(ref:reason:)`, read from `{"op":"stop","id":"T-3","reason":"..."}` (also `cancel`, `halt`). `Board.apply` refuses a task with no run, leaves the note "Stopped the run: <reason>" and lists it in `ChangeSummary.stopping`. `Advanced.finish` stops each through `Advanced.stop(_:in:bySupervisor: true)`, which calls `AppState.stopAgent(in:bySupervisor:)` and `AgentJob.stoppedBySupervisor()`, so the run ends as `.supervisor`, goes back to To do and waits for the person. Prompt rule and op line added in `Supervisor.swift`. 147 board tests and `bash build.sh check` passed. Not pushed, app not restarted.
- `AppState.swift` does not import CompanionBoard, so it cannot name `WorkRun`: pass plain flags there and let `AgentJob` (which imports it) set the ending.

## Next
- Nothing open for the stop op. Try it in the app after the next restart: a supervisor reply with a stop op should end the run and leave the note. 