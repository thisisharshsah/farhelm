## Goal

- Keep Companion working end to end. Companion does the work itself, with guidance and memory support from Claude in the desktop app.

## Where things are (hosts, user names, accounts, folders, files, pages, job or session numbers)

- Checkout `~/Project/farhelm`. From `apple/`, build with `bash build.sh` and rebuild and restart with `bash build.sh restart`. Restart log is `apple/.build/restart.log`. The running app is `apple/dist/Companion.app`.
- Project notes are in `.companion/notes.md`. Companion learns from the Claude app through Settings > Skills.
- Supervisor stops go through `AppState.swift` around line 4141 and `AgentJob.stoppedBySupervisor()` in `apple/Sources/Companion/Support/AgentJob.swift`. `Board.autopilotMayStart` (`Board.swift:410`) and `mayCarryOn` skip runs that ended as `.supervisor`.
- Design files under `apple/` are `Sources/Companion/UI/Design/Theme.swift`, `Sources/Companion/UI/Design/GlassSurfaces.swift` and `Shared/CompanionDesign/Sources/CompanionDesign/OrbitMark.swift`. Chat selection is in `ChatSelection.swift`.
- Keep untracked `apple/sample.txt` and `apple/sample2.txt` out of commits.

## What works and what does not (ways that failed, with the error, and the way that works instead)

- `ls` or `wc` on a missing `.companion/` exits 1. Create the directory and notes file before appending.
- Claude Opus 5.5, acting as supervisor, allowed read-only checks and file creation inside the project for the owner.
- Force-quits and crashes skip `applicationWillTerminate`. Debounced saves preserve state about 0.5 s after a change. Check `git log` before redoing work after a force-quit. The restore edits were already in `bd95506` when the tree looked clean.
- code-server's window title contains U+2014. Match it with `\u{2014}` and describe it in comments without quoting it. Before committing, scan added lines for U+2014 (`grep $'\u2014'`), keys and tokens.
- Update notes before staging to keep the work in one commit. If a second commit slips in, fold it in with `git reset --soft HEAD~1` and `git commit --amend --no-edit` only before pushing.
- If a session disables file edits, turn edits on before making changes.
- The board records supervisor stops, and `Advanced` ends the process. Naming `WorkRun` in `AppState.swift` fails to build because it lacks a CompanionBoard import. Pass plain flags to `AgentJob`, which imports the package and sets the run ending.
- `bash build.sh check` passes with one pre-existing warning in `AgentSession.swift`.
- The first Nov 26 restart attempt was stopped after two minutes without output. A later invocation returned after launching a background build. Companion restarts automatically on a successful build. Verify the outcome in the restart log and process list.

## Done (results, with numbers)

- Nov 24, 2026. Created `.companion/notes.md` with two sections covering the standing rule and eight changes, without overwriting anything.
- Nov 24, `bd95506`. Fixed the layout loop that froze Companion and required a force-quit. Companion restores the open chat, sidebar, zoom, panel position and frame before first showing the panel. Changes save after about 0.5 s and on quit. Reported to the owner.
- Nov 24, `4d5b3cc`. Dragging the circle while the panel is hidden now saves its position.
- Nov 25, `6653988` on `main`, merged into `companion/main` as `32bbfb2`. Landed 77 files covering speed and memory, project notes, learning from Claude, scroll and restore, VS Code bridge, passkeys, browser and ADR 0020.
- Nov 25, `5f2d44a` on `main`, merged into `companion/main` as `bf09c46`. Supervisor `stop` (`cancel`, `halt`) requires a run. It records the reason, queues the task in `ChangeSummary.stopping`, ends the run as `.supervisor` and returns the task to To do to wait for the owner. The prompt calls for stopping and replanning in the same reply when a run exceeds 3× its estimate, repeats reads or failing edits, or loops after model fallback. All 147 board tests passed, including two new tests, and `bash build.sh check` passed.
- Nov 25, supervisor `approve` (`accept`, `pass`) on `main`. `Board.apply` requires Review, no active run, and a last run whose checks ran and passed. Refusals leave a reason in Review. `ChangeSummary.approving` feeds `Advanced.approveForSupervisor`, which checks `TaskCopies.wouldNotMerge` via `git merge-tree`. Conflicts leave a note in Review. Otherwise the card's `Advanced.approve` merges and moves the task to Done.
- Nov 25, supervisor `delete` (`trash`) on `main`. It is a separate operation from `remove`. For a task with an active run or open copy, the owner must name the task in their own message. `Board.named(in:)` accepts `T-3`, `t3`, `#3` and `task 3`. Refusals leave a reason. Allowed deletions go through `ChangeSummary.deleting` and the card's `Advanced.remove`, with each run written to the board log before deletion.
- The approve and delete operations and their rules are in the supervisor prompt under the standing review rule. All 151 board tests passed, including four new tests, and `bash build.sh check` passed.
- Nov 26. Made “Select across messages” the sole rendering path in `ChatSelection.swift` and removed its switch. No trial switches remain. Settings has about 30 switches.
- Nov 26. Ran `cd ~/Project/farhelm/apple && bash build.sh restart 2>&1 | tail -15`. The restart log confirmed the build succeeded, and the process list confirmed the restarted Companion was running from `apple/dist/Companion.app`.

## Next

- No pending follow-up from the restart.

## User decisions

- Read project notes and work logs before acting, read project files without asking, and update notes after every task.
- Keep clicks that would open a new browser tab in the current tab. Follow the newest message until the user scrolls by hand. Limit the held message on glass to two lines.
- Use a serif font and a Claude-style voice for replies. Learn from the Claude app through Settings > Skills.
- Use trial switches only when needed 