## Goal
- Project goal: every Companion screen and component looks and behaves like Apple's native Liquid Glass, with polished enterprise-grade controls in place of basic option pickers, and layouts that stay aligned and readable at every size from compact to full screen.
- T-44: build the board team design (docs/adr/0016-board-team.md, from T-43) in apple/Shared/CompanionBoard/. It covers roles, assigning tasks to roles, one task at a time per specialist, and a scorecard per role and model. Views are out of scope.

## Where things are (hosts, user names, accounts, folders, files, pages, job or session numbers)
- Person's own checkout: /Users/harshsah/Project/farhelm. Leave it untouched.
- T-44 worktree: /Users/harshsah/.companion/worktrees/farhelm-879947/t-44, branch task/t-44-board-rules-roles-role-assignment-and, made from companion/main.
- companion/main is now at 0392957, which is newer than the branch's base. The agent expects it to contain `CodeServer`, but nobody has checked that yet.
- Board package: apple/Shared/CompanionBoard. Test it with `swift test --package-path apple/Shared/CompanionBoard`.
- Full app check: `bash apple/build.sh check`, run from the worktree root.
- New files: Sources/CompanionBoard/Team.swift, Sources/CompanionBoard/Scorecard.swift, Tests/CompanionBoardTests/TeamTests.swift, Tests/CompanionBoardTests/ScorecardTests.swift.
- Changed files: WorkItem.swift, Board.swift, Operations.swift, SupervisorReply.swift.
- All 8 files are still in the worktree and have not been committed.
- Stash entry "t44-wip" is sha 6e50e03709173f9cb4a9483a486254a1abee4475. It has been applied to the worktree but is still in the shared stash.
- A stray untracked file named `]` sits in the worktree root. It is not part of T-44, so do not commit it. Remove it.
- AGENTS.md already lists ADR 0016 as docs/adr/0016-lens-platform.md, and the board-team design also uses number 0016.

## What works and what does not (ways that failed, with the error, and the way that works instead)
- Board package tests pass with the recovered work in the worktree: 170 tests, 0 failures.
- In "don't ask" permission mode, only read-only git (`git status`, `git log`) works. It blocks `rm`, `git merge`, `git add`, `git commit`, `swift test` and `bash`. Eight attempts in a row failed. Retrying does not help: the person must allow these commands or run them.
- `bash apple/build.sh check` fails in apple/Sources/Companion/CompanionApp.swift. That file uses `CodeServer` and `ConversationStore.flush`, which do not exist on this branch. These errors existed before T-44 and are unrelated to the board package.
- Calls to WorkItem's init failed until a `paths` parameter was added to it.
- Restore stashed work with `git stash apply <sha>`, never a bare `git stash pop`, because other worktrees share the stash.

## Done (results, with numbers)
- Team.swift:
  - Types: `TeamRole`, `Specialist`, `TeamRules`.
  - `TeamRouting.role(for:among:items:)` picks a role by path coverage first, then by matching kind, then by fewest open tasks.
  - Board functions: `addRole`, `retireRole`, `addSpecialist`, `retireSpecialist`, `freeSpecialist(for:)`, `idleSpecialists(now:)`.
- Scorecard.swift scores each role and model pair over its latest 20 judged runs:
  - rates: approved at first review, changes asked, checks passing
  - token fit: 1 up to 1.2x the estimate, falling to 0 at 3x
  - blended with a neutral prior, and flags poor pairs
- New fields: `WorkItem.role`, `WorkRun.specialist`, `WorkRun.tokens`, and `WorkRun.Ending.overrun`.
- Board.swift:
  - New: `roles`, `specialists`, `BoardSettings.teamLimit`.
  - Board version 3. Moving a v2 board to v3 adds one Generalist role that can run many tasks at once and assigns it every existing task.
  - `mayCarryOn` refuses runs that ended in overrun.
- `ItemPatch.role` passes the role through add and update. SupervisorReply reads `role` from the supervisor's reply.
- Tests:
  - TeamTests: 12 tests (one task at a time, parallel specialists, routing, limits, retiring, idle, v2 move, overrun).
  - ScorecardTests: 11 tests (approve, send back and fail counting, exclusions, scoring, blending, token fit).

## Next
- From the worktree, in this order:
  1. Run `rm ']'`.
  2. Run `git merge companion/main --no-edit`. If `.companion/notes.md` conflicts, take companion/main's version.
  3. `git add` the 8 board files.
  4. Commit them with the message "T-44: Board rules: roles, role assignment and per-role model scorecard".
  5. Run `bash apple/build.sh check`.
  6. Run `swift test --package-path apple/Shared/CompanionBoard` again.
- All of these steps need write permission from the person, or the person runs them.
- If companion/main does not supply `CodeServer` and `ConversationStore.flush`, find where they come from. Do not rebase or switch branches yourself.
- After the commit, drop the "t44-wip" stash entry. Find its current `stash@{n}` by its tag first.
- Check whether the board-team ADR needs a number other than 0016.

## User decisions
- Never commit to main without the owner's approval. Never switch branches, rebase, push or merge this branch into another yourself.
- Do not change views in T-44.
- Comments explain why, not what. No em dashes anywhere. No AI attribution lines in commits.