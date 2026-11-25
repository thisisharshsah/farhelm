# 0016: A team of roles on every board

Status: **Proposed**, 2026-11-24 (board task T-43). Nothing here is built
until the owner approves it, and the owner may change any rule or number in
it first. Every name a person would see (Project Manager, Specialist, Team,
Scorecard, Team Size, the role titles) is the agent's proposal, to be
confirmed before it is used in code or the app.

Numbering: 0016 is also the number of the Lens record
([0016-lens-platform.md](0016-lens-platform.md)). This file uses the name its
task asked for; on approval it should be renumbered to the next free number
(0020 today) and its links updated with it.

Extends [ADR 0014](0014-advanced-mode.md) (Advanced mode: a supervisor, a
board, a model per task) and keeps [ADR 0012](0012-tasks-and-runs.md)'s
names: a **Task** is planned work, a **Run** is one agent attempt.

## Context

A board today has one supervisor and one pool of tasks. The supervisor plans,
picks a model for every task, reviews finished runs and, in Supervisor mode,
answers in the person's place. Any ready task can start, up to the board's
Runs at Once (`BoardSettings.parallel`, three on a new board), within the
leases and the budget. Limit on In Progress (`BoardSettings.wipLimit`) is
only shown as a warning (`Board.overWipLimit`); nothing obeys it.

What that leaves short:

- **Nobody owns a kind of work.** A task is given to a model, not to someone
  who knows the Mac app, the design system or the release. Its brief is the
  task alone, so every run starts as a newcomer to that part of the project.
- **The record of a model mixes everything.** `TrackRecord` counts a model's
  approved, sent back and failed runs across the whole board, so a model that
  writes good docs and weak Swift looks average at both. It ignores tokens
  against the estimate and whether the project's checks passed.
- **Runs at Once is a number with no meaning in the work.** Three runs at
  once is three whatever the work is: three Swift tasks queue behind each
  other's leases while a writing task waits for no reason, and raising it
  only adds runs, not skills.
- **Runs that go far over their estimate are not stopped.** `estimateTokens`
  feeds the model choice and the budget's `fits`; a run that uses five times
  its estimate goes on until it ends or the budget is gone.
- **No one reports.** The board shows how work stands, but nothing sums it
  up for the owner between goals.

This has to hold for any project Companion runs, not only this repository:
an app, a website, a book, a data pipeline, a research question.

## Decision

Every board runs as a managed team: a **Project Manager** who owns the plan,
and **Specialists**, each holding one **Role**. Tasks are given to a role,
each specialist works one task at a time, and team size, within the budget,
is how much runs at once.

The board's package keeps deciding. As in ADR 0014, the Project Manager is a
model and only asks for changes; every rule below is in
`apple/Shared/CompanionBoard`, with tests, and a reply that breaks one is
refused in part with the reason said in its chat.

### 1. The team

**The Project Manager (PM)** is the board's supervisor in a new role, not a
second model: the same chat (`Board.supervisorChat`), the same model
(`Board.supervisor`), every request through `Advanced.askSupervisor` or
`supervisorStream` with its failover. There is one per board. It owns the
plan, the team and the review (section 5).

**A Role** is a kind of work the project needs, written down once:

| Field | What it is | Limit |
| --- | --- | --- |
| `key` | a short, unique slug: `mac-engineer` | 32 characters, `a-z0-9-` |
| `title` | as shown: Mac engineer | 40 characters |
| `brief` | what it does here, how this project does it, what its review looks for | 1,200 characters |
| `kinds` | the `WorkKind`s it takes (feature, bug, docs, design, ops ...) | at least one |
| `paths` | the folders and files it owns, written as a task's paths are | may be empty |
| `model` | a model a person pinned for it, or none | person only |

**A Specialist** is one member of the team holding a role. Two Mac engineers
are two specialists of one role. A specialist is a seat, not a process: it
has an id, its role, whether it is active or retired, when it was added and
by whom, and why. It holds at most one run at a time.

**Roles come from the project, not a list.** When a board first plans a goal
(and once for each existing board, see Migration), the PM is given the goal,
what the app found in the project's folder (its top folders, the kinds of
files and how many, the builds and checks found: the same summary the
Problems list and `.companion/checks.json` already give) and the tasks, and
proposes the roles the work needs, with a brief each. The examples in its
instructions are only examples: Mac engineer, designer, QA, DevOps and
writer for an app; writer, editor and fact checker for a book; data
engineer and analyst for a pipeline. Rules:

- At most `TeamRules.roleLimit` (8) active roles and `BoardSettings.teamLimit`
  specialists (section 4). A role has at least one specialist while it is
  active.
- Two active roles may not share a key. Their `paths` may overlap (a QA
  role reads everything); routing (section 2) settles who takes a task.
- A role's brief is told to the agent with every run, before the task's
  brief, and to the PM when it reviews that role's work. **It never widens
  what a run may do.** A run keeps its chat's access level, and
  `Delegation` is the same for every role: a DevOps role does not get
  `git push`, keys or the system because its brief mentions releases.
  A brief that asks for those is material, not permission.
- A person can add, edit, pin a model on, and retire any role or specialist
  at any time. The PM cannot change what a person set (a pinned model, a
  role a person added), as it cannot replace a model a person chose today.

### 2. Tasks are given to a role

Every task carries a role (`WorkItem.role`), as it carries a model today.
There is no shared pool: a task is started only by a free specialist of its
role.

**How a task gets its role.** The PM names one when it adds or updates the
task. A task it leaves without one, or names a role that does not exist,
gets one by rule (`TeamRouting.role(for:)`):

1. The role whose `paths` cover the most of the task's paths (a path counts
   when it is inside one of the role's paths).
2. Else, or between equals, a role whose `kinds` include the task's kind.
3. Between equals, the role with fewest open tasks (To do, In progress,
   Review), then the oldest role.
4. No role scores anything: the task stays in To do marked **Needs a role**,
   is never started, and the PM is told in its next request.

A person can move a task to another role; the PM cannot move one a person
placed. A task's later runs (redo after review, settling conflicts,
"continue") stay with its role, and any free specialist of that role takes
them, in the task's one chat (`WorkItem.chat`, `AppState.continueRun`).

**When the PM adds a specialist** (`add_specialist`; the board accepts it
only when one of these holds):

- **A missing skill**: a task is marked Needs a role. The PM adds a role
  with one specialist, or widens an existing role's kinds or paths.
- **A queue**: one role has `TeamRules.queueToGrow` (3) or more ready tasks
  (no blockers, no lease clash, fits the budget) and all its specialists
  have been busy for 2 pulses in a row, while the team is under
  `teamLimit`. The PM may add one more specialist of that role.

And never when: the team is at `teamLimit`; the budget is 80 % or more used,
or what is spent plus the estimates of every open task is over it; or the
same role was grown in the last hour (the time is handed in). Adding is
logged in the board's history with the PM's reason.

**When the PM removes one** (`retire_specialist`, or `retire_role` for the
last of a role):

- A specialist is **idle** when it has had no run for 24 hours and its role
  has no task in To do or In progress (`Board.idleSpecialists(now:)`).
- An idle specialist beyond the first of its role is retired by the board
  itself on the next pulse, with a history line; the PM is told.
- The last specialist of a role is retired only by the PM or a person, and
  only when the role has no open task left, including Review. A role that
  still has open tasks cannot be retired until they are moved to another.
- Nobody is retired while it holds a run.
- Retired roles and specialists stay on the board with their scorecards;
  bringing a role back brings its record back. They are never deleted.

### 3. The scorecard

`Scorecard` replaces `TrackRecord`. It is kept per **role and model pair**
(Mac engineer with model m2), built from the board's runs as `TrackRecord` is
now, over each pair's latest 20 judged runs, and with the same runs left out:
runs a person or the PM stopped, runs that failed for want of an answer
(`Board.modelFailed`), and runs still going. A run is judged under the model
that actually ran it, so a stand-in (`Failover.standIn`) earns its own
record.

| Measure | From | Counts |
| --- | --- | --- |
| Approved on first review | the first judged run of each task under the pair | share approved with no changes asked before |
| Changes asked | every review of the pair's runs, by the PM or a person | share that asked for changes |
| Tokens against estimate | a run's tokens (recorded at its end) over the task's estimate | the median ratio, tasks with an estimate only |
| Checks passing | `WorkRun.checks` of the pair's finished runs | share where every check passed; runs with no checks left out |
| Failed or stopped over estimate | `WorkRun.outcome`, the new `Ending.overrun` | share |

One score from 0 to 1 sums it up for comparing:

```
score = 0.40 * firstReview
      + 0.20 * (1 - changesAsked)
      + 0.25 * checksPassing
      + 0.15 * tokenFit
tokenFit = 1 when the ratio is 1.2 or less, falling evenly to 0 at 3.0
```

A pair's own record counts once it has 3 judged runs (`Scorecard.enough`,
as `TrackRecord.enough` today) and fully from 10; between them it is blended
with its prior in proportion (5 runs: half its own, half the prior).

**The prior, for a pair with no history yet** (a new role, a new model, a
new board):

1. The same model's record on this board in other roles, summed, if it has
   3 judged runs or more.
2. Else a neutral prior: first review 0.5, changes asked 0.5, checks 0.75,
   token ratio 1.0. That is a score of 0.60, in the middle, so a new pair
   is neither favoured nor held back, as `TrackRecord.standing` does now.

**How a task's model is chosen** (`ModelRouting.suggest`, given the task's
role and the scorecards):

1. A model a person chose for the task, then one a person pinned on its
   role, is kept. The rest is the rule the PM's own suggestion is checked
   against, as today.
2. **Effort** is the tier the task wants, `ModelRouting.demand` as now: its
   kind, its estimate, its priority and how many "done means" lines it has.
3. **Candidates**: models whose window fits the estimate, strong enough for
   the effort (else the strongest there is), with a known price before one
   whose price is not set, as now.
4. **Drop poor pairs**: a pair with 5 or more judged runs and a score under
   0.35 is not chosen by rule, unless that leaves no candidate. A person
   can still choose it.
5. **Rank** by the expected cost of one approved task:
   `cost(estimate * tokenRatio) / max(firstReview, 0.25)`, so a cheap model
   that needs three tries is not taken for cheap. Costs within 10 % of each
   other, and models with no charge per token, count as equal; between
   equals: native tool calls, then the higher score, then the closest tier
   (no stronger than needed), then the least busy group
   (`ModelRouting.busy`), then on this Mac, then by name.
6. **Trying new pairs**: so a role does not keep one model for ever, one
   task in 5 of a role whose leading pair has 5 or more judged runs goes to
   an able candidate with fewer than 3, at no more cost, when the task is
   light or balanced work, not urgent, and the review gate is on.
7. The reason shown says it in a line: "Everyday Mac work: m2 approved 5 of
   7 at first review here, 1.3x its estimates, checks passing 6 of 7."

The PM is shown every active role's scorecard, a line per pair, and is told
to follow the same order; its pick is checked against the rule as now.

### 4. No fixed Runs at Once: team size sets parallelism

Each specialist works one task at a time, so the runs going at once are the
busy specialists. A ready task starts, by itself or by hand, when:

- a specialist of its role is free;
- nothing it depends on is unmerged (`Board.blockers`), and its paths meet
  no other task's (`Leases`, `Board.leaseHolder`);
- its estimate fits what is left of the budget (`Budget.fits`);
- the app's own limit is not reached ("Tasks at once" in Settings > Agent,
  which counts every chat's task, not only the board's; it stays);
- its role has fewer than `TeamRules.reviewQueue` (3) tasks waiting in
  Review for a person. Work nobody can look at piles up; the role waits.

Between ready tasks of one role: priority, then their place in To do, then
the oldest, as Autopilot orders them now. Between roles, specialists are
independent: a writer starts while every Mac engineer is busy.

**The budget bounds the team**: past 80 % of the budget used, at most one
run goes at a time across the team and no specialist is added; at 100 % no
run starts, as now.

**What happens to the two settings**:

- **Runs at Once** (`BoardSettings.parallel`) goes. Its place in the board's
  menu becomes **Team Size**, the most specialists the board may have
  (`BoardSettings.teamLimit`, from 1 to 8, 3 on a new board). The PM grows
  and shrinks the team inside it (section 2); a person can add specialists
  up to it and raise it.
- **Limit on In Progress** (`BoardSettings.wipLimit`) goes. In progress can
  never hold more tasks than there are specialists, which is the limit it
  meant, and the Review queue rule above is the limit that was missing.
  `Board.overWipLimit` goes with it.
- **Autopilot** and **Supervisor mode** keep their meaning: they decide
  whether free specialists start ready tasks by themselves. With both off,
  a person starts a task, and it still needs a free specialist of its role.

`Advanced.waiting` says why work waits in the team's words: "Both Mac
engineers are busy", "T-12 needs a role", "Writer has 3 tasks waiting for
you in Review", "Team is at its size", beside the reasons it gives now.

### 5. The Project Manager's duties

**Planning.** As the supervisor plans now, and also: every task it adds has
a role, an estimate and paths. A task without an estimate is never started
by itself (a person may start it; 30,000 tokens is assumed for the limits
below, as routing assumes now). Proposing and changing roles is part of the
plan, through new operations (`add_role`, `update_role`, `retire_role`,
`add_specialist`, `retire_specialist`, and `role` on `add` and `update`),
within the reply limits of ADR 0014 (80 operations, 300 tasks).

**Priorities.** The PM sets each task's priority and order in To do, which
is the order its role's specialists take them. It cannot reorder what a
person moved by hand since its last reply.

**Review before the owner sees the work.** The review gate becomes the PM's
review of each specialist's work, on by default and with every rule of ADR
0014 kept: the project's checks run first, `Checks.letThrough` holds back
work whose checks did not all pass, ASK leaves a task for the person,
`BoardRules.redoLimit` stops a task going round. What changes is what the PM
is given: the role's brief (what its review looks for) and the pair's
scorecard beside the task's "done means", diff, checks and earlier reviews.
The owner sees the PM's verdict and notes on every task, and is asked only
where the PM answers ASK or the rules hold work back. Every review counts in
the scorecard (section 3).

**Status reports.** The PM writes a report in its chat:

- when asked;
- when a goal is reached or set aside;
- after every 5 finished runs, at most once every 4 hours, and at least once
  a day on which work happened (`BoardSettings.reportEvery`, 5 runs by
  default; 0 turns the scheduled ones off).

The facts come from the board by rule (`TeamReport.facts(since:now:)`): tasks
per column and what changed, each specialist busy or idle with what it
finished, spend against the budget and against the sum of the estimates,
runs over their estimate, changes to the team, what waits on the person, and
what is next. The PM puts them in words; if it cannot answer, the facts are
posted as they are. Each report is one request, filed under supervising in
Usage.

**Stopping runs far over estimate.** A run's tokens so far are read from the
ledger on every pulse (`Ledger.total(of:now:)`) and set against its task's
estimate by a rule in the package (`Overrun.state`):

| Used, against the estimate | What happens |
| --- | --- |
| 1.5x | Warned: the card and the run's chat say so; the next report names it. No request. |
| 2x | Check-in: the PM is asked once (a small request, filed as Advice) to answer CONTINUE with a new estimate, at most 3x the first, or STOP with a reason. No answer in 40 seconds counts as CONTINUE to the next line. |
| 3x, or 1.5x a new estimate the PM gave, never past 4x the first | Stopped by rule (`WorkRun.Ending.overrun`). The task goes back to To do with a note, and is not started again until the PM splits it or gives a new estimate. |
| A quarter of what is left of the budget, in one run | Stopped by rule, whatever its estimate. |

A run stopped this way is never carried on (`Board.mayCarryOn`), and two in
a row leave the task for the person. A run a person started by hand is
warned and checked in with the person, never stopped by rule. These numbers
are `TeamRules` constants, with tests, not words in a prompt.

## How this maps onto the code

### `apple/Shared/CompanionBoard`

| Where | Change |
| --- | --- |
| `Team.swift` (new) | `TeamRole`, `Specialist`, `Board.team`; `TeamRules` (`roleLimit`, `queueToGrow`, `reviewQueue`, the idle time); `Board.addRole`, `retireRole`, `addSpecialist`, `retireSpecialist`, `idleSpecialists(now:)`, `freeSpecialist(for:)`; `TeamRouting.role(for:)` |
| `Scorecard.swift` (new) | `Scorecard`, its score, prior and blending; `Scorecard.of(items:)` by role and model. Replaces `TrackRecord`, which goes once nothing reads it |
| `Overrun.swift` (new) | the thresholds of section 5 as `Overrun.state(estimate:extended:used:budgetLeft:)` |
| `TeamReport.swift` (new) | the facts of a status report |
| `WorkItem.swift` | `WorkItem.role`; `WorkRun.specialist`, `WorkRun.tokens` (recorded at the end of a run), `WorkRun.Ending.overrun` |
| `Board.swift` | `BoardSettings.teamLimit` and `reportEvery` in place of `parallel` and `wipLimit` (still read, for migration; no longer written); `overWipLimit` goes; `autopilotMayStart` and starting a run need a free specialist and the Review queue rule; `beginRun` records the specialist; `mayCarryOn` leaves `overrun` out; board version 3 |
| `ModelRouting.swift` | `suggest(for:role:among:busy:scorecards:)` with the order of section 3; `demand` unchanged; `records(of:)` goes with `TrackRecord` |
| `Operations.swift`, `SupervisorReply.swift` | the new operations and `role` on tasks, read forgivingly and checked by `Board.apply`, with what was refused said in the chat |
| `Delegation.swift`, `Failover.swift`, `Leases.swift`, `Checks.swift`, `WorkingCopy.swift`, `ChatShelf.swift` | no change. Roles never widen `Delegation`; a stand-in is scored as the model that ran |
| Tests | `TeamTests`, `ScorecardTests`, `OverrunTests`, `TeamReportTests`; `BoardTests` and `SupervisorReplyTests` extended for roles, starting rules and migration |

### The app (`apple/Sources`), named for completeness

The PM's instructions (roles, scorecards, estimates required), a run's brief
(the role's brief before the task's), the board's team strip (each
specialist, busy or idle, and its task), Team Size and the report setting in
the board's menu, the pulse that reads tokens for `Overrun`, and
`Advanced.waiting`'s new reasons. No change to `AgentProcess`, the task
copies or how work is merged.

### ADR 0014

On approval, ADR 0014 gets a line under its status pointing here, and these
of its parts are read with this record:

- "The supervisor asks; the board decides": the supervisor is the Project
  Manager; the rule is unchanged.
- "A model per task": the choice is by role and scorecard (section 3);
  `TrackRecord` is replaced.
- "Review gate, Autopilot, budgets": Autopilot starts work per free
  specialist, not up to Runs at Once; the review gate is the PM's review.
- "Why work waits": the team's reasons replace "the board's runs at once".
- The line "Runs no longer share a folder, so Runs at Once can be raised"
  becomes "so a team can grow".

Everything else in ADR 0014 stands: copies and merging, leases, checks,
Supervisor mode and `Delegation`, failover, goals, chats.

## Migration of existing boards

A board file of version 2 is read as version 3 the first time, and nothing
it did before changes until the PM proposes a team:

1. **One role, Generalist**, taking every kind of work and no paths, with as
   many specialists as the board's Runs at Once (`parallel`, from 1 to 8).
   So the board runs exactly as many tasks at once as before.
2. **Team Size** is set to that same number. A Limit on In Progress that was
   set is dropped, with a line in the board's history saying so.
3. **Every task** gets Generalist as its role. Runs going on are taken to
   belong to Generalist specialists; if there are more than its specialists
   (Runs at Once lowered while they ran), they finish, and nothing new starts
   until one is free.
4. **Past runs** are scored under Generalist and the model that ran them.
   Their tokens are taken from the ledger by the time each ran, where it has
   them; where not, the run counts for everything but tokens against
   estimate. The model's record in other roles then serves as the prior for
   new roles (section 3).
5. **The PM is asked once**, on the board's next opening, to propose roles
   for the goal being worked toward and to move the open tasks to them. A
   person sees the proposal in the PM's chat; with Supervisor mode off it is
   applied only when they agree. Generalist is retired once it holds no open
   task, unless a person keeps it.
6. **Older builds**: a version 3 file opened by a build that knows only
   version 2 would lose the team when written back, since boards are read
   field by field. So the version 3 change also makes a build that finds a
   newer version open the board read-only and say so; that guard ships
   first, in a build before the team.

Boards of earlier goals are migrated with the rest of the file: their tasks
get Generalist too and keep their history.

## Order of work, once approved

1. The rules in the package (team, routing, scorecard, overrun, report
   facts) with their tests, and the read-only guard for newer files.
2. Storage version 3 and the migration, with tests on version 1 and 2 files.
3. The app: the PM's instructions, briefs, team strip, menu settings, the
   overrun pulse, status reports.
4. First use on one board, then ADR 0014 and AGENTS.md updated with what it
   showed.

## Alternatives considered

- **A fixed list of roles.** Simple to build, wrong for most projects: a book
  has no DevOps and a Mac app needs more than one kind of engineer. Roles
  come from the project, with examples as guidance only.
- **Keep the shared pool and Runs at Once, add a role label.** Labels would
  inform the model choice but not who works or how much runs; the
  meaningless number stays.
- **A scorecard per model only.** That is `TrackRecord` today; it cannot
  tell a model's Swift from its prose.
- **A separate model per role, always.** It would cost more and bind a role
  to one model before there is evidence; the scorecard lets the evidence
  choose, and a person can still pin one.
- **Stopping over-estimate runs by the PM's judgment alone.** A model's
  care is not a limit; the thresholds are rules, with the PM's say only at
  the check-in.

## Consequences

- Parallelism follows the team: a board with one role runs one task at a
  time unless it grows, which can be slower than three anonymous runs; a
  board with several roles runs different kinds of work side by side.
- The PM makes more requests (roles, check-ins at 2x, reports). Each is
  small, filed under supervising or Advice, and within the budget.
- Every task needs an estimate to start by itself, which makes the PM's
  estimates matter; the scorecard's token ratio shows when they are off.
- A run's tokens are kept on the run, so the scorecard does not depend on
  the ledger being kept for ever.
- `TrackRecord`, `BoardSettings.parallel`, `wipLimit` and `overWipLimit` go
  after the migration; code that reads them moves to the scorecard and
  `teamLimit`.

## Open for the owner

- The names: Project Manager (or keep Supervisor), Specialist, Role, Team,
  Team Size, Scorecard, Generalist, Needs a role.
- The numbers: score weights, the 1.5x, 2x and 3x thresholds, a team of 3 on
  a new board, 8 roles at most, 24 hours to idle, a report every 5 runs.
- Whether the owner wants to approve PM-approved work as well (an "owner
  approves" step after the PM's review), which this record does not add.
- Whether a role's pinned model may be set by the PM after enough evidence,
  rather than by a person only.