## Goal
- Keep Companion's project notes and change log current, so work can be picked up in any chat without asking again.
- Companion should reopen as it was left (open chat, window frame, zoom, sidebar), even after a force-quit or crash.
- Show Companion's work as a Claude-style timeline.

## Where things are (hosts, user names, accounts, folders, files, pages, job or session numbers)
- Project notes: `~/Project/farhelm/.companion/notes.md`, at the repository root beside `checks.json` (created Nov 24, 2026).
- Companion builds from `~/Project/farhelm/apple`. `bash build.sh restart` builds and relaunches; `bash build.sh check` only compiles.
- Reply voice: `Prompts.voice`.
- Launch restore and state saving: `Sources/Companion/CompanionApp.swift` (`restoreSession`, `scheduleSessionSave`, `saveSession`) and `Sources/Companion/UI/FloatingPanel.swift` (panel moves and resizes, the circle's move handler).
- Work timeline: `WorkTimeline` splits the work into stretches between the agent's notes, and `WorkTrail` is the row for one stretch. Both, plus the page preview card, are in `Sources/Companion/UI/OverlayView.swift` (around lines 2640-3420). Work steps are in `Sources/Companion/Conversation/Conversation.swift`.
- Design parts: `Sources/Companion/UI/Design/Theme.swift`, `Sources/Companion/UI/Design/GlassSurfaces.swift`, `Shared/CompanionDesign/Sources/CompanionDesign/OrbitMark.swift`.

## What works and what does not (ways that failed, with the error, and the way that works instead)
- `ls`/`wc` on `.companion/` fails (exit 1) if the folder doesn't exist yet. Create the folder and file first, then append.
- The supervisor (Claude · Opus 5.5) allowed read-only checks and creating files inside the project for the person.
- Companion froze in a layout loop and had to be force-quit. The loop is fixed.
- A force-quit or crash skips `applicationWillTerminate`, so saving only there loses state. State is now also saved about 0.5 s after any change (debounced).
- Check `git log` before redoing work after a force-quit. The restore edits had already been committed (bd95506) even though the working tree was clean.

## Done (results, with numbers)
- Nov 24, 2026: created `.companion/notes.md` with 2 sections, overwriting nothing.
  - "Standing rule (Nov 24, 2026)": Companion does the work itself. Claude in the desktop app only guides and helps remember.
  - "Changes made Nov 24, 2026", 8 bullets: notes kept in `.companion/notes.md` and written after every task; notes and work logs read before acting; project files read without asking; clicks that open a new tab (for example Connect to Jupyter) stay in the same tab; scroll follows the newest message unless the user scrolls by hand; the held message is cut to 2 lines on glass; Companion learns from the Claude app (Settings > Skills); replies use a serif font and the Claude-style voice.
- Nov 24, 2026, launch restore (commit bd95506): Companion restores the open chat, sidebar, zoom, panel position and frame at launch, before the panel first shows. It saves them about 0.5 s after any change and on quit.
- Nov 24, 2026, gap fixed (commit 4d5b3cc): dragging the circle while the panel was hidden cleared the detached flag without saving, so after a force-quit the panel would reopen in its old spot. It now saves in that case too (in the circle's move handler in `FloatingPanel.swift`). `bash build.sh check` passed with no errors.
- Nov 25, 2026: committed the day's Companion work on main (speed, memory and project notes, learning from the Claude app, scroll and restore fixes, VS Code bridge, passkeys and browser), without `apple/sample*.txt`. Not pushed.
- The restore work has been reported to the user.

## Next
- Try the restore in the running app, only when the user allows it: change the chat, sidebar or size, wait 1 s, force-quit, then reopen.
- Claude-style work timeline: change `WorkTrail`, its page preview card and the style of the agent's notes. Not started (the files have been read, nothing edited).
- Append to `.companion/notes.md` after every task, keeping what is already there.

## User decisions
- Companion does the editing, building (`bash build.sh restart`), checking and committing. Claude in the desktop app only guides and helps remember, and doesn't edit files.
- Read the notes and work logs before acting. Read project files without asking.
- When working on Companion's own code, follow AGENTS.md and the existing style: comments explain why, and never use em dashes.
- During the restore task, don't restart or relaunch the app and don't run `build.sh restart`. Use `bash build.sh check`.
- Never write passwords, tokens or keys in notes.