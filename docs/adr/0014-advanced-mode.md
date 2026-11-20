# 0014: Advanced mode in Companion: a supervisor, a board, a model per task

Status: accepted, 2026-11-16. User direction the same day: an Advanced mode
beside Chat and Code, in which a supervisor model plans the selected project,
keeps the plan through a proper project life cycle (Kanban, monday.com),
suggests which model each piece of work goes to, and counts every token in
every conversation; with Autopilot, a review gate, budgets and a timeline, to
an enterprise standard. Built by the owner the same day (`bash build.sh`),
who also ran the board package's tests. **It has not been used end to end
yet**: the first plan, run and review in the app are still to come, and this
record is updated with what they show.

Added later the same day, on the owner's direction: several goals for a
project with their history, the supervisor's recommendation wherever a person
is asked to choose, and a project's chats kept inside the project in the
sidebar (the three sections marked "added" below). The owner built them that
evening. The first use showed a trap, set out under "Taking a project off the
list" below: its fix has been written but not built yet.

Added 2026-11-17, on the owner's direction: an option for the supervisor to
answer in the person's place where it recommends an answer, with the reach of
its yes chosen by the owner ("project work and installs"), its saying
"continue" where work stopped halfway, the next available model standing
in while the supervisor's own is out of its limit, and a project's chats
placed by how its work stands, with one chat per task. Written, not built or
used yet.

Extends [ADR 0012](0012-tasks-and-runs.md) (tasks and runs) and follows
[ADR 0013](0013-farhelm-companion-orbit.md) (Companion works without Farhelm).

## Context

Companion had two sides, Chat and Code, and one engine at a time: whatever the
chat box's model picker said answered everything. Planning lived in a chat's
own checklist and ended with the chat. Usage was recorded per request, but a
request was filed under whichever chat was open when it ended, so work in a
chat that had been left was counted against the wrong one.

Farhelm already has tasks on a board and runs as attempts (ADR 0012), but
Companion must work alone (ADR 0013), so it cannot depend on them.

## Decision

### A third side of the app

`AppState.mode` is one value, `chat`, `code` or `advanced` (`AppMode`), in
place of the `codeMode` flag, which is now derived from it. In Advanced the
project's board has the middle and the chat is a column on its right, the
arrangement Code already uses for the workspace (`SidePanelMode.board`, and
`splitLayout` in `OverlayView`).

### The board is plain data with its rules, in a package of its own

`apple/Shared/CompanionBoard` holds tasks, runs, statuses, what a supervisor
may change, the ledger, budgets and the rule that picks a model. It has no
interface, files, network or clock (the time is handed in), in the manner of
`farhelm-domain`, so every rule is tested and the iPhone, iPad and Watch apps
can show the same board later.

It keeps ADR 0012's names and rules: a **Task** is planned work, a **Run** is
one agent attempt, the statuses are Backlog, To do, In progress, Review and
Done, and a run moves its task as `work_items::status_after` does (started:
in progress; finished: review; failed or stopped: to do).

### The supervisor asks; the board decides

The supervisor is a model the user talks to in the project's supervisor chat.
It answers in words and ends with one fenced block of JSON operations. A model
wrote that block, so it is untrusted input: `SupervisorReply` reads it
forgivingly and `Board.apply` checks every operation. It cannot mark new work
done, cannot move or remove a task with a run going on, cannot replace a model
a person chose, cannot make tasks wait on each other in a circle, and is
limited to 80 operations a reply and 300 tasks a board. What it could not do
is said in the chat.

### A model per task

Every task carries an assignment: the model, who proposed it (the supervisor,
a rule, or a person) and why. The supervisor chooses from the engines that are
set up (`ModelRoster`), told where each runs, what it costs, how much it
holds and how capable it is. `ModelRouting` gives the same answer by rule
(the least costly model that is strong enough) when no model is asked.
`EngineChoice` is now the one place that turns an engine and model into a
request's configuration, for the engine in use and for any other.

### A run is an ordinary agent task

A task has one chat, which all its runs share. Its first run starts that chat
in the project (`AppState.startBoardRun`); every later run (a retry, a redo
after review, "continue") goes into it (`AppState.continueRun`), under a line
saying what this run is, and the chat is named after the task as it is called
then. Each run hands the agent the task's brief whole, with the task's model
(`runAgent(_:in:engine:)`), since an agent starts each message knowing only
what the message says. What one run used is told apart from the others in the
same chat by the time it ran (`Ledger.total(of:now:)`). A message the person
types in a task's chat, or sends again, goes to the agent with the task's
brief after it (`Advanced.taskBackground`, added 2026-11-18): before, it went
alone, and an agent told "do T-14" had no way to know what T-14 was. Nothing
about approvals changes: a run follows its chat's access level, and the
board's "what runs may do unasked" sets that level for the task's chat.

### A task works in a copy of its own, on a branch of its own (added 2026-11-18)

Runs used to work in the project's own folder, so two at once that touched the
same files got in each other's way, their changes could land in one commit,
and the supervisor's yes reached into the person's own folder. Now, where the
project's folder is in a git repository with a commit, on a branch, each task
works in a copy of the repository of its own: a git worktree on a branch of
its own (`WorkingCopy` in the board's package, with tests; `TaskCopies` does
git's part). It is on unless switched off ("Give Each Task Its Own Branch" in
the board's menu, `BoardSettings.copyPerTask`).

- The copy is made for the task's first run, from the board's own branch for
  the branch the project's folder is on (see the next section), at its last
  commit: in
  `~/.companion/worktrees/<repository>-<project>/t-<n>`, on the branch
  `task/t-<n>-<words of its title>`. Changes the person has not committed are
  not in it, and the task's notes say how many files that was. It is outside
  every repository, so no copy turns up in the project's searches or builds,
  and its path has no space in it, which some build tools still trip over.
- All of a task's runs work in it, as they share its chat
  (`AppState.startDirectory(of:)`); the chat's workspace, terminal and git
  panel show it. What the app records a run changing is committed there, on
  the task's branch, each run its own (`ChangeStore.commitPending`).
- A run's brief names the copy and the branch, says the project's own folder
  is the person's and is to be left as it is, and says not to switch
  branches, rebase, push or merge it anywhere. The supervisor's yes ends where
  the folder a run starts in ends (`Delegation`), which is now the copy: the
  person's folder is outside it.
- The review is given the branch's diff against where it began, with what is
  not committed yet and the names of new files, cut to fit.
- Approved (by the review, or a person), or moved to Done by a person, the
  task's work is merged into the branch its copy came from, the board's own
  (`Advanced.settle`). What was left uncommitted in the copy is committed on
  its branch first, unless a merge in it was left unsettled. git works the
  merge out without touching any folder (`git merge-tree`, git 2.38 or
  later), and it is made a commit on top of that branch, "Merge T-n: its
  title". Where that branch is checked out, its folder is moved up to it the
  way `git merge --ff-only` does, which changes nothing at all when changes
  in that folder are in the way; anywhere else only the branch moves, and
  only from where it was. The copy and its branch are then taken down.
  Nothing is rebased, forced or pushed.
- A merge comes out one of four ways: merged; nothing to merge; the branch it
  goes into has moved on and conflicts with it, when the task goes back to To
  do with the files named, and its next run is told to bring that branch in
  and settle them, and is reviewed again; or held back by something only the
  person can settle (changes of theirs in the way, a branch gone), when it
  waits in Done, under Needs you, with Merge Now.
- The supervisor cannot move a task with an open copy to Done: only an
  approval merges.
- Asked for changes, the next run carries on in the same copy, which its
  chat remembers. Throw Away deletes the copy and its branch, with their
  work; the next run starts again in a new copy, and is told why. A task
  taken off the board keeps its branch, with what was left in the copy
  committed on it; only the folder goes.
- A copy whose folder went is made again from its branch; one whose branch
  went is let go, and a new one is made.
- Runs no longer share a folder, so "Runs at once" can be raised.
- A task that ran in the project's folder before goes on there. Where no copy
  can be made (no git, no commit yet, not on a branch), runs work in the
  folder as before, and the task's notes say why.

### No conflicts reach the person; the supervisor merges them all (added 2026-11-20)

First use found a board in supervisor mode where nothing started: tasks only
ever started with Autopilot, which was off, and the supervisor had no way to
start work. And the merging above still let conflicts reach the person: a
task that waited on another started as soon as that one was Done, from a
base without its work; two tasks on the same files ran side by side; and
work merged straight into the person's checked-out branch, where any
uncommitted change of theirs held it back. Now the flow is built so that
merges have nothing to settle, and what is left is settled by an agent.

- Supervisor mode. "Let the Supervisor Answer for Me" is now "Supervisor
  Mode: Let It Run the Board": besides answering in the person's place, the
  supervisor starts ready tasks itself (`BoardSettings.startsWorkByItself`,
  Autopilot or supervisor mode), so turning it on is all it takes. Its
  control reads "runs the board", and Autopilot's button shows on, unclickable,
  while it does. The supervisor is told how work moves on its board, so it
  does not promise work that will not start.
- Why nothing runs is shown on the board (`Advanced.waiting`), from the first
  ready task that was held back, or else what the work left waits on: a
  task waiting on another, a task in Review, work held for the person, the
  backlog, the budget.
- Leases (`Leases`, `Board.leaseHolder`, with tests). The supervisor gives
  every task the files and folders it will change ("paths"), and the brief
  tells the agent to stay inside them. No two tasks whose paths overlap run
  at once; a task without paths runs alone. Work not merged yet (in Review,
  waiting to be merged, or back to settle conflicts) holds the files its copy
  changed, looked at on every pulse, so a task never starts beside work it
  could collide with.
- A task waits on another until that one is done and merged, not only done
  (`Board.blockers`), so it starts from a base with that work in it.
- The board's own branch, `companion/<the person's branch>`
  (`WorkingCopy.boardBranch`, "companion-..." where a branch named
  "companion" leaves no room). Tasks branch from it, and approved work is
  merged into it one task at a time, which moves only that branch: the
  person's folder and what they have not committed are never touched. It
  first takes the person's newer commits (`TaskCopies.catchUp`): it is moved
  up to them, or they are merged in by git without a folder. On every pulse
  the board's work goes on into the person's branch by fast-forward
  (`TaskCopies.deliver`), whenever no change of theirs is in the way; when
  one is, that is said once, and it goes in by itself once they commit.
- Conflicts that come all the same go back to the task's own agent: the task
  returns to To do and its next run brings the board's branch in and settles
  them, then is reviewed again (`Board.copyConflicts`). After
  `BoardRules.settleLimit` (2) runs it waits in Done for the person instead.
  A merge a run left unsettled, or conflict marks among its changes
  (`git diff --check`), are never committed or merged
  (`TaskCopies.unsettled`). Where the person's branch and the board's
  changed the same lines, a task is put on the board, once, for an agent to
  merge them (`Advanced.syncTask`); its work then goes in by itself.
- On a board the supervisor runs, a check of a finished run that did not
  come back is asked again after 5 minutes, 3 times at most
  (`Advanced.reviewAgain`), so no task waits in Review for nobody.
- A run that failed only because its model could not answer (out of its
  limit, rate limited, overloaded, out of reach) is not counted against its
  task (`Board.modelFailed`): two of those in a row no longer leave the task
  for the person, and the next run goes to a model that stands in.
- What is left to the person: their own uncommitted changes, which nothing
  touches, and conflicts that came back after two runs.

### Every request is filed where it belongs

`WorkScope` is a task-local set once around a piece of work: the chat, and in a
project the board task and the project. It follows everything the work does,
so each request is filed under the right chat and task even when that chat is
not the one on screen. `UsageRecord` gains optional `workItem` and `project`.

### Review gate, Autopilot, budgets

- **Review gate** (on by default): when a run finishes, the supervisor checks
  its report, changed files and command outcomes against the task's "done
  means". Approved, the task is done; otherwise it goes back with notes the
  next run is given. With no clear verdict it waits for a person.
- **Autopilot** (off by default, per project): starts ready tasks, most
  pressing first, up to the board's "runs at once" (one, unless raised),
  never two whose paths overlap. It acts only for projects whose board was
  opened since launch, stops when the budget is used up, and leaves a task
  whose last two runs did not finish for a person. Supervisor mode starts
  ready tasks the same way, with Autopilot on or off.
- **Budgets**: a limit in tokens, dollars or both. No run starts past it,
  by hand or by Autopilot.

### Goals, one at a time, with the ones before kept (added)

A project has goals over time, not one. `Board.goals` holds every goal the
project has had (`BoardGoal`: its number, G-2; its words; how it stands; the
stretches of time it was worked toward), and `currentGoal` names the one being
worked toward. A task is under one goal, and the board shows the tasks of the
goal being worked toward (`Board.items`); the tasks of every goal are in
`allItems`. Task numbers run on across goals, so T-7 names one task for good.

- **New goal** turns the board to a new goal. The goal before it is kept with
  its tasks, as reached when every one of them is done and otherwise as set
  aside. Its open tasks stay with it unless the person asks to bring them
  along. A goal that was never put into words and has no tasks is not kept:
  it simply becomes the new one.
- **Going back** to an earlier goal makes it the goal worked toward again,
  with its tasks as they were left; the goal left for it is kept in its turn.
  So starting a goal by mistake loses nothing.
- An earlier goal can be removed only when it has no tasks.
- A run that is going when the board turns goes on and ends like any other,
  under the goal its task belongs to.
- The supervisor sees the earlier goals as a line each and can start a new
  goal (`new_goal`) only when asked to; it is turned to before the rest of
  the reply is carried out, one a reply. It cannot change a task of an earlier
  goal.
- What each goal cost: a request made for a task counts toward the goal the
  task is under, and any other (planning, talk in the project's chats) toward
  the goal the board was working toward when it was made
  (`Board.usageByGoal`). The budget stays the project's.

### The supervisor recommends, the person decides (added)

Wherever a person is asked to choose, the project's supervisor says which
answer it recommends, and that answer carries "Recommended" with the reason
beside it:

- steps an agent needs a yes for (Allow, Always allow, Deny),
- an agent's question with answers to pick from,
- a task waiting in Review when the review gate is off (Approve, or send it
  back); with the gate on the same check decides, as before,
- the model for a task: the one the supervisor picked stays marked in the
  list after a person chooses another.

It is advice and nothing more: nothing runs, is refused or moves because of
it, the person can answer before it arrives, and it is asked for only in a
project that is run from a board (it has a supervisor's chat) whose board has
"Recommend an Answer Wherever I Am Asked" on (the default). The supervisor's
answer is read, not trusted (`Recommendation.parse`): "Always allow" is passed
on only for commands that keep to the project's folder and name no keys,
whatever the model wrote, and an answer that cannot be read is no
recommendation. Each one is a small request to the supervisor's model, filed
under the chat and task it advises on as "Advice" and counted with
supervising in Usage.

### The supervisor can answer in the person's place (added 2026-11-17)

Off until switched on, per project: "Let the Supervisor Answer for Me", in
the board's menu and in the supervisor's own menu, whose control says
"answers for you" for as long as it is on (`BoardSettings.followsAdvice`; it
needs recommendations, and switching those off switches it off). With it on,
what the supervisor recommends is the answer, and nobody is waited for:

- steps an agent needs a yes for: its ALLOW or DENY is taken. Its yes is for
  that once. "Always allow" is never taken, so what the person is asked about
  from then on stays theirs to change. A DENY ends the task with the
  supervisor's reason, as a person's no does.
- an agent's question with answers to pick from: the one it picks is given,
- a task in Review: its verdict decides, as the review gate's does,
- work that stopped halfway: it says "continue" (below).

How far its yes reaches is the owner's choice of 2026-11-17, "project work
and installs", and it is kept in code, not in the model's instructions
(`Delegation`, in the board's package, with its tests). Its yes counts for
work in the project's folder and for installing or downloading what the task
needs. These stay the person's whatever the supervisor answers, and the card
says which applies: steps that name keys or credentials (the app's own
judgment, the same as for every level of access); acting on the system or as
its administrator (`sudo`, `launchctl`, `defaults write`, containers);
sending something off this Mac or acting on another machine (`git push`,
publishing, `ssh`, `scp`, a request that carries a body or a value from the
shell, GitHub's own program except where it only shows); working other apps,
the screen or the clipboard; anything that reaches outside the project's
folder unless it only looks; git's own files; removing a folder that is not
one that can be made again (`build`, `node_modules` and the like);
throwing away changes that are not saved in git (`git reset --hard`,
`git clean`, `git stash`); running what was fetched in the same breath; and
anything whose program cannot be told from how it is written (backticks,
`$(...)`, `eval`). Text fed to a program with `<<` is not read as commands
unless it is fed to a shell. The rules read a command as text, so a command
written to hide what it runs can get past them: they come after the
supervisor's own judgment, never instead of it, and a sandbox would be the
stronger guard.

The supervisor is told that its answer will be taken, and is given a third
answer for leaving it to the person (ASK for steps, NONE for a question),
with its reason shown on the card. It answers only for what it was shown in
full: more than twelve steps, or a step longer than 4,000 characters, are the
person's. Nothing is answered once the project's budget is used up. A long
task's own check-in ("Carry on?") is answered at most twice in a row, then
it is the person's. An answer that cannot be read, or does not come in 40
seconds, leaves the task waiting for the person as before, and the person
can always answer first.

Who answered is kept: the record of what the agent did says "the supervisor
(model), in your place" for every step it let run or refused, the chat says
so with its reason, a question it answered shows "Answered in your place
by", and the board's history has a line when the setting is switched.

### Carrying on where work stopped halfway (added 2026-11-17)

On a board where the supervisor answers for the person, it also does what
the person would do in a chat that stopped halfway: it says "continue"
there. The chat shows that word as a message of its own. The agent is given
the task again with how far it got, since an agent starts each message
knowing only what the message says.

- A run the app was quit under (`WorkRun.ending == .quit`, set when a board
  finds a run it still calls running with no agent at work) is carried on
  when its board is next opened, however often that happens.
- A run that failed by itself (an error, a time limit, rounds without a
  step) is carried on a little later, at most `BoardRules.carryOnLimit`
  (two) times in a row for a task; then it waits for a person.
- A run that ended by itself but only part way (it asks whether to continue,
  or lists what is left) is found by the check of the finished run, which
  has a third verdict, CONTINUE, on such a board.
- A task in a chat of the project that is no board's run is looked at the
  same way when it ends, with one small request to the supervisor (filed as
  "Advice"), and told to carry on at most twice in a row.

Never carried on: a run a person stopped, a task that was refused a step or
told to stop at its check-in (by the person or by the supervisor,
`WorkRun.ending`), and a task a person has moved since. Of runs from before
the ending was kept, one the app found cut off is told by its having no
report and is carried on; one that failed is left to the person, as nobody
can tell whether it was refused a step. The rule is `Board.mayCarryOn`.
Autopilot, too, no longer starts a task again whose last run a person
stopped or that was refused a step. Like
Autopilot it acts only for boards opened since launch, within the budget and
the number of runs at once, and Autopilot leaves such tasks to it rather than
start them again itself.

### The next model stands in while the supervisor's is out of its limit (added 2026-11-17)

Every request to a project's supervisor (its chat, the check of a finished
run, an answer or recommendation for an agent, the look at a chat that
stopped) goes to its model through one path (`Advanced.supervisorChain`,
`askSupervisor`, `supervisorStream`), with the pattern of a circuit breaker
and a failover list:

- When the model answers with an error that says it cannot answer for now,
  before it has said anything else, it is rested and the next model is
  asked. Which errors count, and for how long, are rules in the board's
  package (`Failover.trouble`, with tests): out of its limit, quota or
  credit (an hour, or until the time the tool names); rate limited or
  overloaded (two minutes); out of reach, such as a model on this Mac that
  is not running (five minutes). An error another model would meet too (a
  request that is too long, a key that is refused) is shown as before.
- A subscription tool that reported a window of its plan used up is rested
  until that window starts over, before it is even asked. A window of one
  model ("seven_day_opus", the week's limit for Opus) rests that model only:
  the tool's other models can still be asked, and its own pick is rested
  only when what the tool says of it names that model, or nothing is known
  of it (`Failover.window`, with tests).
- The next model (`Failover.order`): those as strong as the chosen one
  first, the ones with no charge per token (on this Mac or under a
  subscription) before those billed by use, in the order the model list
  gives them; then weaker ones, strongest first. At most five are tried for
  one request. The chosen model is asked again once its rest is over, and
  last even while it rests, in case its limit is over sooner.
- Rests are kept while the app runs. What a stand-in costs is counted under
  its own model, like any request.
- A task's run (added 2026-11-18): a run that Autopilot starts, or the
  supervisor carries on, while the model the task was given rests is run
  by the first model of the same order that is as able as it and, where
  the task's model has no charge per token, has none either
  (`Failover.standIn`, with tests). So a stand-in never makes the work
  weaker or starts spending by use that nobody chose. The task keeps its
  model; its notes say which model ran it and why. With no such model the
  task waits for its own, as before. A person who starts a task starts it
  with its own model.

The board says so: the supervisor's control shows the model standing in with
an hourglass, and its help says which model is out of its limit and until
when. In the supervisor's chat, an answer from a stand-in starts with a line
saying the same.

### A project's chats are placed by how its work stands (added, reworked 2026-11-17)

In the sidebar a project is a row that opens and closes. Its chats (the
supervisor's, its tasks', any other started in it) are listed inside it and
not in the list below, which holds the chats that are in no project. Which
projects are open is kept between launches, and the open chat's project opens
itself. A closed project says how many of its tasks need the person.

Inside it, chats are placed by a rule in the board's package
(`ChatShelf.spot`, with tests), not by recency alone:

- the supervisor's chat, pinned on top and called Supervisor;
- Needs you: a task whose agent asks something or waits for a yes, a task
  in Review, a task the review sent back, and a task whose run stopped, unless
  Autopilot or the supervisor will take it up by itself
  (`Board.movesOnByItself`, the same rule Autopilot follows); and a done task
  whose work could not be merged (`Board.mergeWaitsOnPerson`);
- Running: a task being worked on, checked, merged, or about to be started by
  itself;
- the person's own chats, the newest few, with those unused for two weeks
  folded into Older. An own chat stays where it is whatever runs in it, so
  the chat being used never jumps; one that waits on the person is marked
  where it is.

A task's chat is named after its task, with its key in front and how the task
stands at the end, and is reached from the board as well. Once the task is
done, shelved in the backlog, under an earlier goal or off the board, its chat
is put away (Archived), still found by search and from the task; so are the
older chats of a task that had one per run, before runs shared one. The person
archives their own chats by hand. A filter shows one group at a time (All,
Needs you, Running, Mine, Archived), and a search finds a chat in the project
by its name or its task's.

A chat says what it is to the board (`Conversation.kind`, `taskID`): new ones
from the start, and chats from before, once, from their board's run records
(`Advanced.prepareChats`). What the board knows comes first; the stored kind
keeps a task's chat out of the person's own once its task is taken off.

### Taking a project off the list loses nothing (added after first use)

What happened: a project row is now something to click, to open and close
it, and under the pointer it showed a round minus that took the project off
the list at one click. Read as "close", it was clicked. Removal then cut the
project's chats loose (they became plain chats for good), and adding the
folder again made a new project with an empty board, the old board left
behind under the old id.

So:

- No button sits on a project's row, so a click meant to open or close it
  can land on nothing else. A new chat in it, rename, change folder and
  remove are in the row's menu (right-click), and removing asks first.
- Removing is undone by adding the folder again. A project taken off the
  list is remembered (its id, name and folder), its chats keep naming it,
  and its board stays where it is. While it is off the list its chats are
  plain chats; added again, it is the same project, with its chats inside it
  and its board.
- A project that was already lost this way is offered back where projects
  are listed: the sidebar and Advanced's project chooser show it ("Off the
  list ... Click to bring it back"). It is found by the board it left
  behind (`Advanced.lookForLostProjects`). Its name is read from its
  supervisor's chat and its folder from what one of its runs was told; the
  folder is asked for when that fails. One click puts the same project
  back, under the id its board carries, with its chats inside it
  (`Advanced.bringBack`, `AppState.reviveProject`).
- When the folder was added again as a new project instead, the board that
  was left behind can be brought to it. On a project whose own board has
  nothing planned, the board lists the boards on this Mac
  that belong to no project (what each was for, how far it got, when it was
  last changed). "Bring it back" makes one this project's board
  (`Board.rehome`, `BoardStore.adopt`) and puts its chats back inside the
  project: the supervisor's, its runs', and every chat that asked a model
  anything under the old id. What was spent under the old id still counts
  (`Board.earlierProjects`). The old file is put aside, not deleted.
- Deleting a chat from the sidebar asks first, for the same reason: its
  button sits where a click to open the chat can land, and a deleted chat
  does not come back. The question says so when a task is running in the
  chat, and when it is a supervisor's chat or the chat of a run.

### Storage

One JSON file per project in `Application Support/Companion/boards`, written
whole and atomically, read field by field so older files load. A file that
cannot be read is put aside, never written over. This moves to SQLite with the
rest of Companion's data (ADR 0013, step 6).

The file's shape is version 2 since goals: `goals`, `currentGoal`, and a
`goal` on every task. A version 1 file (one goal, kept as a text) is read as
one goal with every task under it, and written as version 2 from then on.

## Consequences

- `codeMode` is read-only; anything that set it calls `setCode` or
  `setAdvanced`.
- Usage is attributed to the chat that made the request. Totals per chat can
  differ from before for work that finished in a chat that had been left.
- A subscription tool started for an agent task in a repository now starts in
  that repository whichever chat is open.
- The labels Advanced, Autopilot, Review gate, Budgets and Timeline are the
  ones the owner chose from on 2026-11-16. Supervisor, Board, Task and Run
  follow the owner's wording and ADR 0012.
- New goal and Recommended are the owner's words. Earlier goals, Reached,
  Set aside and "Work on it again" are the agent's, for the owner to change.
- `Board.items` now means the tasks of the goal being worked toward. Code
  that wants every task reads `allItems`.
- A click on a project in the sidebar opens and closes it. It used to open
  the project's newest chat, which is now one click further, inside it.
- A chat of a project that is off the list still names that project
  (`Conversation.projectID`). Code that wants "the chat's project" asks
  `AppState.project(of:)`, which answers only for projects on the list.
- With recommendations on, every approval and every question with answers in
  a supervised project costs one more small request, and so does every
  finished run while the review gate is off.
- With the supervisor answering, an agent's steps can run with nobody
  looking, on the say of a model. What bounds that is the rules in
  `Delegation` and the budget, not the model's care. "Let the Supervisor
  Answer for Me", "answers for you" and the reach of its yes are the owner's
  choices of 2026-11-17; the other words are the agent's.
- A task's later runs no longer start a chat each: a task with several run
  chats from before keeps its latest as its chat, and the others are put away
  (not deleted). A run's card on the task shows what that run used, not its
  whole chat.
- `Advanced.runEnded` takes how a task came to an end (`WorkRun.Ending`), and
  `ActionRecord` lines for refused steps say who refused them (`by`).
- `AppState.chatsWaiting` and the marks that follow it mean "waiting on the
  person": a task the supervisor is answering for is not counted until the
  answer is left to them.
- A task's chat works in the task's copy while it is open, not in the
  project's folder. `Advanced.start` makes or checks the copy first, out of
  the way, so a start that returns nil may still fail, and says so on the
  board. `ChangeStore.commitPending` commits one chat's changes when given it.
- Each open copy is a whole checkout of the repository's files, plus what its
  runs build there, until it is merged or thrown away. While it is open, its
  branch shows in the repository's branches.
- Approving a task with a copy changes the person's branch: it gets a merge
  commit. "Give Each Task Its Own Branch", Throw Away, Merge Now and the
  `task/` branch names are the agent's words, for the owner to change.

## Not done

- A first plan, run and review in the app.
- Building the copies and the merging, and using them end to end. The git
  steps were tried on git 2.43, not on the Mac's own git. The same goes for
  the board's own branch, its catching up and delivering, and the leases
  (2026-11-20): their git steps were run in a scratch repository, and the
  rules have tests, but none of it was built or run in the app here.
- Files git does not keep, copied into a new copy (`.env`, say), and a setup
  command a project can give for its copies (installing what it depends on).
  Settling a conflict by hand in the copy, rather than by a run. Merging by
  squashing, as a setting.
- A plan cut off at the output limit is refused whole; the operations that
  arrived complete could be kept.
- The board on iPhone, iPad and Watch, and in `RemoteServer`.
- Using Farhelm's work items as the store when a Farhelm is connected.
- Reminders for due dates, and monday.com-style automations.
- Building and running the fix for taking a project off the list, and
  using the goals and the recommendations end to end.
- A budget of a goal's own, moving one task to another goal, and a word on
  what came of a goal when it is left.
- A recommendation for a question that has no answers to pick from, and for
  work outside any supervised project.
- Building the supervisor's answers, the carrying on and the stand-in model,
  and using them end to end. The rules in `Delegation` were exercised only through a copy of
  them in another language, since no Swift could be run where they were
  written.
- A sandbox per run, which is what would let the supervisor's yes reach
  further safely: a copy of its own bounds where a run's files go, not what
  its commands can reach. A setting for how far it reaches (only the
  project; everything but keys). Remembering a program for one task, so the
  supervisor is not asked about the same one again and again.
- A run whose model runs out mid-task ends; a stand-in takes the task up
  only from its next run. An order of stand-ins a person can set. Carrying
  on a chat that is no board's run after the app was quit under it.
- Moving a chat into or out of a project from the sidebar
  (`AppState.moveConversation` is there; nothing calls it).
