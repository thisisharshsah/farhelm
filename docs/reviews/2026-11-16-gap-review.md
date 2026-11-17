# Gap review against ChatGPT, Claude Code, Cursor, Devin, Macro and monday.com

Review date: 2026-11-16. Read-only research, written as board Task T-2. No code, configuration or other document was changed.

The goal this measures against: make Farhelm and Companion easier to use than the six reference products, able to scale, and fit for enterprise needs (teams, roles, audit, security and reliability).

## How to read this

- Every gap says what the repository does today, the file that shows it, what the reference products offer, a size and a suggested next task.
- Sizes are estimates, not measurements. **S**: about three days or less. **M**: one to three weeks. **L**: a month or more, or it waits on an owner decision or an outside party.
- Gaps are ranked inside each section by how much they block the goal. Ids: U for ease of use, S for scale, E for enterprise.
- Product facts were read on 2026-11-16 from each product's own pages by a research helper limited to four pages per product. I did not read those pages myself. Whatever the helper could not read is marked **(not verified)** and should not be relied on.
- This is a comparison of what exists, not a claim of parity anywhere. Farhelm's strengths (local-first policy, approvals that fail closed, leased and resumable runs, the sealed relay, Companion's editor, agent and browser) are noted only where they change the size of a gap.

### Sources for the six products

- ChatGPT: https://openai.com/enterprise-privacy/, https://help.openai.com/en/articles/8792828-what-is-chatgpt-team, https://help.openai.com/en/articles/8265053-what-is-chatgpt-enterprise, https://chatgpt.com/pricing/
- Claude Code: https://code.claude.com/docs/en/security.md (the only page read; boards, SSO and SCIM are not verified)
- Cursor: https://cursor.com/docs/get-started/quickstart.md, https://cursor.com/docs/cloud-agent.md, https://cursor.com/pricing, https://cursor.com/docs/llms.txt (page titles only)
- Devin: https://docs.devin.ai/get-started/first-run.md, https://devin.ai/pricing, https://docs.devin.ai/llms.txt, https://docs.devin.ai/enterprise/security-access/security/enterprise-security.md. The pricing table's check marks did not render, so which plan includes a row is not verified.
- Macro: https://macro.com, https://macro.com/pricing, https://github.com/macro-inc/macro (README cut off partway). Its "Teams & Admin" and "Security" pages were not opened.
- monday.com: https://monday.com/pricing, https://monday.com/trustcenter, https://support.monday.com/hc/en-us/articles/34336185460498-monday-com-secure-configuration-checklist

### What was not checked

- Nothing was built or run. Source files were found by listing and text search, and only some were read. First pass: the documents and ADRs named in the task, `apple/README.md` up to line 124, and parts of `crates/farhelm-cloud/src`, `crates/farhelm-runner/src/front_door.rs` and `mobile/src/App.tsx`.
- A second pass on 2026-11-16 read these files: `web/src/App.tsx` (lines 1 to 281), `web/src/components/Account.tsx`, `web/src/components/WorkspaceSearch.tsx`, `web/src/components/Auth.tsx` (to line 294), `web/src/components/WorkBoard.tsx` (to line 479), `web/src/components/ProjectChat.tsx` (to line 70), `mobile/README.md`, `mobile/src/App.tsx` (to line 301), `mobile/src/screens/Task.tsx` (to line 350), `mobile/src/screens/Account.tsx` (to line 357), `packages/client-core/src/api.ts`, `packages/client-core/src/cloud.ts` (all but lines 362 to 574), `packages/client-core/src/transport.ts` (lines 60 to 200 and 405 to 470), `packages/client-core/src/contracts.ts` (lines 225 to 275), `apple/Sources/Companion/Screen/Redaction.swift` (to line 245), `apple/Sources/Companion/Support/ActionRecord.swift`, `apple/Sources/Companion/UI/SetupGuide.swift`, and the lines of `apple/Sources/Companion/AppState.swift` and `apple/Sources/Companion/Support/DeviceControl.swift` cited in this document.
- A third pass on 2026-11-17 read what the second pass had left or cut short. In the web app: the rest of `web/src/App.tsx` and, under `web/src/components`, the rest of `Auth.tsx`, `WorkBoard.tsx` and `ProjectChat.tsx` and all of `Overview.tsx`, `views.tsx`, `charts.tsx`, `Approvals.tsx`, `Board.tsx`, `Palette.tsx`, `Sidebar.tsx`, `Projects.tsx`, `ProjectWorkflow.tsx`, `ProjectWorkspace.tsx`, `TaskThread.tsx`, `Tasks.tsx`, `Preferences.tsx`, `ModelChoice.tsx`, `NewSession.tsx`, `AddMachine.tsx`, `Connect.tsx` and `PushSettings.tsx`; also `web/src/connection.ts`, `web/src/hooks.ts`, `web/src/notification.ts`, `web/src/push.ts` and `web/src/sw.ts`. In the phone app: the rest of `mobile/src/App.tsx`, `mobile/src/screens/Task.tsx` and `mobile/src/screens/Account.tsx`, and all of `mobile/src/screens/Session.tsx`, `mobile/src/screens/Pairing.tsx`, `mobile/src/screens/Watch.tsx`, `mobile/src/components/pieces.tsx` and `mobile/src/watch/bridge.ts`. In the watch package: `mobile/watch/README.md`, `mobile/watch/Sources/FarhelmWatchUI/Views.swift` and `mobile/watch/Sources/FarhelmWatchUI/WatchStore.swift`. Also lines 362 to 574 of `packages/client-core/src/cloud.ts` and the end of `apple/Sources/Companion/Screen/Redaction.swift` (from line 245). Files longer than about 250 lines were read in two or more parts. This pass changed five places: E7, U9, U10 and U12 were corrected and S9 was added. It contradicted no other gap.
- Still not opened: in `web/src`, the files `main.tsx`, `cloud.ts`, `cloud-endpoint.ts`, `idb.ts` and `platform.ts`, the style sheets, every test file, and under `components` the files `AddRepository.tsx`, `DeviceSlot.tsx`, `Pairing.tsx`, `Markdown.tsx`, `Icon.tsx`, `status.tsx`, `tasks-view.ts` and `workspace-list.ts`; in `mobile/src`, the files `cloud.ts`, `platform.ts` and `theme.ts` and the one test file; in `mobile/watch`, the crypto and relay code (`Sources/FarhelmCrypto`, `Sources/FarhelmWatchKit`), the app shell and the tests. By their names these are set-up, storage, styling and helper code plus three small forms (add a repository, claim a device seat, pair a device). None was checked beyond its name, so a feature inside one of them would be missed.
- "There is no X" rests on text searches of `crates/` and `apple/Sources` for the terms named in each gap. For the web and phone apps it rests on the list of operations a screen can ask a server for: the `Transport` interface (`packages/client-core/src/transport.ts`, lines 67 to 185) and the account client (`packages/client-core/src/cloud.ts`, from line 579). A search for `fetch(` finds one use in `web/src` (the service worker) and none in `mobile/src`, so screens reach a server only through those two. A feature under another name, or one that needs no server, would be missed.
- Orbit's three safety ideas (ADR 0013, step 2) were checked in a second pass by reading the code, not by running it. All three are in Companion and called from the agent's step loop: password fields and card numbers are blacked out before a capture is released, and password managers are never pictured (`apple/Sources/Companion/Screen/Redaction.swift`, called from `apple/Sources/Companion/Screen/ScreenReader.swift`); every step is appended to a permanent record (`apple/Sources/Companion/Support/ActionRecord.swift`); and a type, key or click step is refused when the field or window changed since it was planned (`apple/Sources/Companion/Support/DeviceControl.swift`, lines 219 to 240, called at `apple/Sources/Companion/AppState.swift`, lines 2539 to 2540). ADR 0013 still lists them as missing; it was not changed, because this task may only touch `docs/reviews/`. None of the three was exercised in a running app, and no test for them was looked for.

## 1. Ease of use

### U1. A first answer takes many steps, and the two guides do not meet

- **Today:** Farhelm's quickstart is an install script and `farhelm setup`, which then walks four things (a model credential, hooks, fleet sign-in, run at login) and says agent tasks cannot run without the first. It does not mention `farhelm engine`, although local models through the engine have been the working default since 2026-10-28. Companion is built from source with `bash build.sh`, which downloads Chromium (about 250 MB); no CI job builds or publishes it. Companion's own setup guide is a checklist of five things (microphone, AI model, your details, screen recording, your voice). It counts the microphone and a model as the essentials, and the model row only opens Settings to pick an engine and add a key: nothing in that view installs or starts a local model. Its code still lists Ollama as an engine (line 32), although project direction on 2026-11-09 says nothing uses it any more.
- **Evidence:** `docs/quickstart.md`, `apple/README.md`, `.github/workflows/ci.yml`, `apple/Sources/Companion/UI/SetupGuide.swift`
- **Reference products:** Cursor: download, sign in, pick a folder, open the agent with Cmd I. Sign-up steps for ChatGPT, Devin, Macro and monday.com: (not verified).
- **Size:** M
- **Next task:** Ship a signed, notarized Companion download whose first run ends in a first answer (a key pasted, or a local model installed for the person), and rewrite the quickstart around the local default.

### U2. Advanced mode has not been used end to end

- **Today:** The supervisor, board, review gate, Autopilot and budgets are built and the board's rules are tested, but the ADR records that no plan, run and review has been completed in the app. This review was written as one board task, so a first run is under way; the record is not updated yet.
- **Evidence:** `docs/adr/0014-advanced-mode.md`, `apple/Shared/CompanionBoard/Tests/CompanionBoardTests/BoardTests.swift`
- **Reference products:** All six are shipped and in daily use. This is a readiness gap, not a feature gap.
- **Size:** S
- **Next task:** Take one small real project through plan, run, review gate and done, and write what broke into ADR 0014's "Not done" list.

### U3. Farhelm sends a reply whole, not as it is written

- **Today:** When a client asks the front door to stream, it gets one delta holding the entire answer, then the finish. The gateway's local transport is non-streaming Chat Completions. Companion streams from its own engines, but a reply from a Farhelm model arrives in one piece. The runner's event stream carries session events, not model text. Farhelm's web chat does not stream either: by its own description, a message is claimed with a request id, the reply is composed on the runner afterwards, and the pane polls the conversation until the turn settles, showing in the meantime what the reply is reading. A search of `web/src` for "delta" finds nothing.
- **Evidence:** `crates/farhelm-runner/src/front_door.rs` (lines 582 to 607), `web/src/components/ProjectChat.tsx` (lines 4 to 9), `docs/engineering-stack.md`
- **Reference products:** Word-by-word replies in ChatGPT and the others: (not verified on the pages read; it is the common behaviour of chat products).
- **Size:** M
- **Next task:** Add streamed events to the gateway's model port (bounded accumulation, complete tool calls before validation, final usage), pass the deltas through the front door, and add a fixture per deployed runtime.

### U4. Two boards that do not share data, and the board is on the Mac only

- **Today:** Companion keeps each project's board as a JSON file on one Mac. Farhelm keeps tasks in SQLite with its own web board. Neither reads the other. Farhelm's board does travel off the machine: a signed-in device sends project operations, the board-task routes among them, as `project_call` messages over the relay, and the runner answers them with its own HTTP handlers. ADR 0012 still says "the relay has no task protocol yet"; the code has overtaken that sentence (an earlier version of this review repeated it; the ADR itself was not changed). Only the web app shows that board. The Expo phone app has runs, command approvals and change-set review but no board: its routes are fleet, session, task (a run's change set), pairing, workspace and watch, and a search of `mobile/src` for "WorkItem" finds nothing. Companion's board is not on iPhone, iPad or Watch (ADR 0014).
- **Evidence:** `apple/Sources/Companion/Advanced/BoardStore.swift`, `crates/farhelm-sqlite/migrations/0021_work_items.sql`, `web/src/components/WorkBoard.tsx`, `packages/client-core/src/transport.ts` (lines 431 to 462), `crates/farhelm-runner/src/api.rs` (lines 147 to 156), `crates/farhelm-runner/src/project_calls.rs`, `mobile/src/App.tsx` (lines 61 to 67), `docs/adr/0014-advanced-mode.md`, `docs/adr/0012-tasks-and-runs.md`
- **Reference products:** monday.com has iOS and Android apps. Cursor's agents are on the web, a native iOS and iPad app and an Android PWA.
- **Size:** L
- **Next task:** After the contract in S6, let Companion use Farhelm's work items as the board's store when a Farhelm is connected, then show the board read-only in the iPhone app from `apple/Shared/CompanionBoard`.

### U5. A task lacks the fields a work tracker is built on

- **Today:** A Farhelm task has a title, description, status, repository and the conversation it came from. No priority, owner, due date or comments; a search for "assignee" in `crates/` finds nothing. The type every client shares has the same fields and no others, the web app's task form edits only title, status, description and repository, and a search of `packages/client-core/src` for "priority" finds nothing.
- **Evidence:** `crates/farhelm-sqlite/migrations/0021_work_items.sql`, `packages/client-core/src/contracts.ts` (lines 244 to 256), `web/src/components/WorkBoard.tsx` (lines 388 to 405), `docs/adr/0012-tasks-and-runs.md`
- **Reference products:** monday.com has Timeline, Gantt and Calendar views and many column types. Its people, status, priority and due date columns and item updates: (not verified on the pages read).
- **Size:** M
- **Next task:** An additive migration for priority and due date now; owner and comments once people exist as principals (E1).

### U6. Search does not read message text, and nothing is indexed by meaning

- **Today:** Workspace search covers projects, tasks, runs and conversation titles. Conversation text is not searched, and as of 2026-11-04 the installed runner did not serve the route at all. No embedding index exists in `crates/`. Companion retrieves passages from a person's own details, files and memories on the Mac, not from a team's work.
- **Evidence:** `docs/ui-ux-review-2026-11-02.md`, `crates/farhelm-sqlite/src/search.rs`, `web/src/components/WorkspaceSearch.tsx` (lines 4 to 7), `apple/README.md`
- **Reference products:** Devin has code search (Ask Devin) and generated repository wikis. Macro says everything in a workspace is searchable. Cursor's codebase indexing: (not verified).
- **Size:** M
- **Next task:** A full-text index (SQLite FTS5) over conversation messages and task descriptions behind `GET /v1/search`; measure it before considering embeddings.

### U7. Documents and links are stored but nothing reaches them

- **Today:** Tables and store methods for documents and typed links between items exist, with integrity triggers and tests. No caller outside storage and tests writes a document, and no runner route serves links. Companion's @mentions attach repository files only. On the client side a `Document` type is defined, and in `packages/client-core/src` only a wire test uses it; the list of operations a web or phone screen can ask a runner for has none for documents or links. The link mark on a web board card means only that the task was made from a discussion.
- **Evidence:** `crates/farhelm-sqlite/migrations/0011_workspace.sql`, `crates/farhelm-app/src/store.rs`, `packages/client-core/src/contracts.ts` (line 557), `packages/client-core/src/transport.ts` (lines 67 to 185), `web/src/components/WorkBoard.tsx` (line 175), `apple/Sources/Companion/UI/Mentions.swift`, `docs/engineering-stack.md`
- **Reference products:** Macro links items with @mentions and stores the references as a two-way graph. The word "backlinks": (not verified).
- **Size:** L
- **Next task:** A document create and read route under a project, a "mentions" link written when a conversation or task names another item, and "linked from" shown on a task.

### U8. No way in from where teams already talk and track work

- **Today:** A search for "Slack" finds nothing in `crates/` or `apple/Sources`. Companion reaches GitHub through the GitHub CLI; Farhelm exposes MCP tools. Nothing starts a task from a chat tool or an issue tracker.
- **Evidence:** `apple/Sources/Companion/UI/GitHubPanel.swift`, `crates/farhelm-mcp/src/tools.rs`
- **Reference products:** Cursor's agents start from Slack, Linear or GitHub. Devin lists Slack, Teams, Linear, Jira, GitHub, GitLab and Bitbucket. Cursor with Jira: (not verified). ChatGPT's "Slack and Teams" was seen as a menu item only.
- **Size:** M
- **Next task:** One inbound path first: a GitHub issue becomes a Task, and the run's pull request links back to it.

### U9. Approvals work differently in the two products, and Companion's stop at the Mac

- **Today:** Companion's phone page and app can watch and send, but Allow and Deny stay on the Mac. Farhelm lets a phone or the web approve and records which device did. Farhelm also has an Apple Watch package that lists sessions and clears ordinary approvals, with destructive commands refused from a wrist. Its README says no line of its screens has run on a watch, so it is not evidence of working wrist approvals. The split is an open decision.
- **Evidence:** `apple/README.md` (Remote session), `apple/Sources/Companion/Support/RemoteServer.swift`, `docs/adr/0013-farhelm-companion-orbit.md`, `mobile/watch/README.md` (lines 19 to 23 and 103 to 114), `mobile/watch/Sources/FarhelmWatchUI/Views.swift`
- **Reference products:** Cursor has mobile clients for its agents; whether approvals happen there: (not verified).
- **Size:** M
- **Next task:** The owner settles rule 1 of ADR 0013; then routine approvals from a paired iPhone over `apple/Shared/CompanionLink`, with destructive ones kept on the Mac.

### U10. No automations, reminders or templates

- **Today:** Due-date reminders and monday.com-style automations are listed as not done, and the earlier review says durable automations still need a design. One fixed notice does exist on the Farhelm side: when a browser with push turned on is woken, the web app's service worker names the command waiting for approval, or the change set waiting for review, in a notification, and offers Approve and Deny for anything that is not destructive. It is built in, not a rule a person can set. The code that sends the wake-up was not read, and none of it was run. Companion sends no system notification: a search of `apple/` for "UserNotification" finds nothing.
- **Evidence:** `docs/adr/0014-advanced-mode.md`, `docs/reviews/2026-10-22-platform-review.md`, `web/src/sw.ts` (lines 182 to 207), `web/src/notification.ts` (lines 106 to 188), `web/src/push.ts`
- **Reference products:** monday.com sells automations and integrations by monthly action quota and offers more than 200 templates. ChatGPT lists scheduled tasks. Cursor lists an automations page (title only, contents not verified).
- **Size:** L
- **Next task:** One rule in the board package first ("when a task enters Review, notify"), shown as a system notification on the Mac, which Companion does not send today; Farhelm's notice for a waiting change set is the pattern to follow. Then due-date reminders, before any rule builder.

### U11. Companion's chats, boards and usage live on one Mac

- **Today:** No CloudKit use in `apple/Sources`. Boards, memory and usage are local files. SQLite with iCloud sync is step 6 of ADR 0013, not begun.
- **Evidence:** `docs/adr/0013-farhelm-companion-orbit.md`, `apple/Sources/Companion/Advanced/BoardStore.swift`, `apple/Sources/Companion/Support/Usage.swift`
- **Reference products:** ChatGPT runs on web, iOS and Android under one account. Syncing as a stated feature: (not verified).
- **Size:** L
- **Next task:** ADR 0013 step 6: move the JSON files into SQLite once, then sync.

### U12. Apple devices only

- **Today:** Companion is the only interface in the plan and is Swift for Mac, iPhone, iPad and Watch. Whether a web version is kept for everyone else is open decision 1. The repository also holds Farhelm's web app and an Expo phone app aimed at iOS and Android (sign-in, machine picker, command approvals and change-set review). The phone app's README says no screen of it has been rendered, so it is not evidence of a working Android client. The same holds for Farhelm's watch package under `mobile/watch`: its logic has tests, and its README says no line of its screens has run on a watch.
- **Evidence:** `docs/adr/0013-farhelm-companion-orbit.md`, `apple/README.md`, `mobile/README.md` (lines 66 to 70), `mobile/src/App.tsx`, `mobile/watch/README.md` (lines 103 to 110)
- **Reference products:** Cursor runs on macOS, Windows and Linux. ChatGPT runs on web, iOS and Android; a Windows app by name: (not verified). Macro lists iOS and Android; web, Mac and Windows: (not verified).
- **Size:** L
- **Next task:** The owner decides open decision 1. If kept, the existing web app is that version and stays in CI.

## 2. Scale

### S1. Companion's runs share one folder, so they go one at a time

- **Today:** A board run works in the project's own folder. Two at once can touch the same files and land in one commit, so "runs at once" is one by default. Farhelm's own runs already have a worktree, a lease and checkpoints.
- **Evidence:** `docs/adr/0014-advanced-mode.md`, `docs/adr/0004-durable-task-execution-and-recovery.md`, `crates/farhelm-sqlite/migrations/0008_task_worktree.sql`
- **Reference products:** Cursor's cloud agents run in isolated VMs on a separate branch, as many in parallel as wanted, and produce pull requests. Devin allows up to 10 or unlimited concurrent sessions by plan.
- **Size:** M
- **Next task:** A git worktree and branch per run in Companion, merged when the task is approved.

### S2. Commands run with the user's full privileges

- **Today:** File tools are confined and process lifetimes are bounded, but subprocesses run as the runner's user with its files and network. The project's own instructions call `crates/farhelm-process` "not a sandbox", and hosted isolation is an open release gate. A small virtual machine per run is a choice in ADR 0013, not built.
- **Evidence:** `docs/adr/0001-local-execution-boundaries.md`, `docs/adr/0005-scoped-principal-authorization.md`, `docs/adr/0013-farhelm-companion-orbit.md`
- **Reference products:** Claude Code has a sandboxed shell with filesystem and network isolation, and each cloud session runs in an isolated VM. Cursor's cloud agents run in isolated VMs.
- **Size:** L
- **Next task:** A spike that runs one approved command inside Apple's Containerization with writes limited to the checkout and the network off, measuring start time.

### S3. CI never builds or tests Companion

- **Today:** CI has jobs for the Rust workspace, the minimum Rust version, process safety, the TypeScript clients and the watch package under `mobile/watch`. Nothing under `apple/` runs, including the board rules that decide what a supervisor model may change.
- **Evidence:** `.github/workflows/ci.yml`, `apple/Shared/CompanionBoard/Tests/CompanionBoardTests/BoardTests.swift`
- **Reference products:** Not a product feature; it is what lets the others ship daily.
- **Size:** S
- **Next task:** A macOS job running `swift test` for the three packages under `apple/Shared` and for CompanionKit; an app build later.

### S4. No structured tracing, metrics or status page

- **Today:** A search for `tracing::` in `crates/` finds nothing. The control plane records changes with a printed line. The engineering guide lists tracing as preferred, not adopted.
- **Evidence:** `crates/farhelm-cloud/src/api.rs` (lines 102 to 134), `docs/engineering-stack.md`
- **Reference products:** monday.com commits to 99.9% uptime on Enterprise. Public status pages for ChatGPT and monday.com: (not verified; links were seen, the pages were not read).
- **Size:** M
- **Next task:** `tracing` spans for request, run, step and provider call in the runner and gateway, with no customer content in fields.

### S5. One runner is on the path of every project, and a bad file stops it

- **Today:** Every project's model calls go through one runner on one machine. An invalid registry stops it from starting; on 2026-10-28 that cost about 10 and then 36 minutes. `farhelm check` exists but depends on someone running it.
- **Evidence:** `docs/adr/0011-model-hub.md`, `docs/adr/0009-specialists-and-modes.md`
- **Reference products:** All six are hosted services run by their makers.
- **Size:** M
- **Next task:** On an invalid registry, start with the last good configuration and report the fault, so a bad file is a warning and not an outage.

### S6. No published API contract

- **Today:** TypeScript types mirror the Rust ones by hand; CI's own comment says nothing else checks that file. The OpenAPI document, capabilities call and generated Swift client are step 5 of ADR 0013, not begun.
- **Evidence:** `packages/client-core/src/api.ts`, `.github/workflows/ci.yml`, `docs/adr/0013-farhelm-companion-orbit.md`
- **Reference products:** Cursor's cloud agents can be started through an API; its SDK pages were listed only. Devin lists an API. monday.com's API has daily call quotas by plan.
- **Size:** M
- **Next task:** Derive an OpenAPI document for the front door and project routes, add the capabilities call, and fail CI on drift.

### S7. Model serving is one machine

- **Today:** No shared GPU serving exists. Every loaded model counts against one Mac's memory, and loading models that do not fit together is still to come.
- **Evidence:** `docs/engineering-stack.md`, `docs/adr/0011-model-hub.md`
- **Reference products:** All six serve from their own or their providers' fleets; capacity figures: (not verified).
- **Size:** L
- **Next task:** Run the conformance probe against vLLM on one rented GPU, then the pilot load test proposed in the 2026-10-22 review.

### S8. Hosted data is SQLite behind synchronous ports

- **Today:** The control plane persists to SQLite. Postgres is planned, and the store ports are synchronous, so it needs a deliberate async boundary first.
- **Evidence:** `crates/farhelm-cloud/src/store.rs`, `crates/farhelm-app/src/store.rs`, `docs/engineering-stack.md`
- **Reference products:** Storage internals of the six: (not verified, and not needed for the comparison).
- **Size:** L
- **Next task:** An ADR for the async storage boundary, then Postgres for the control plane only.

### S9. The board across projects shows a capped slice of the work

- **Today:** The web board that spans every project asks for at most 50 projects and the first 100 tasks of each. When it stops short it says so on screen ("Some tasks are not loaded") and points to search for the rest, where the runner supports search. A single project's board also asks for 100 tasks; whether it then loads more was not checked.
- **Evidence:** `web/src/components/WorkBoard.tsx` (lines 142, 533 to 544 and 596)
- **Reference products:** monday.com's limits on items per board: (not verified).
- **Size:** S
- **Next task:** Page the cross-project board (more projects, and more tasks per project) and filter on the runner, so the counts shown are the counts that exist.

## 3. Enterprise

### E1. Roles and grants are defined but not enforced where work runs

- **Today:** The principal, role and grant check exists as a pure function whose only callers are its own tests. The control plane does check roles for account actions (adding a member needs Admin). The runner's local API has no authentication, and commands carry no project-scoped principal.
- **Evidence:** `crates/farhelm-domain/src/auth.rs`, `docs/adr/0005-scoped-principal-authorization.md`, `crates/farhelm-cloud/src/api.rs` (lines 697 to 707), `mobile/src/App.tsx` (lines 98 to 100)
- **Reference products:** monday.com has account, workspace, board and column permissions and custom roles. ChatGPT Enterprise has roles, groups and role-based access. Devin lists role-based access on Enterprise. Cursor's roles: (not verified).
- **Size:** L
- **Next task:** Middleware that resolves a verified principal on the runner's project routes and checks a project-scoped grant, with tests for cross-project denial, then the same on relay and MCP.

### E2. The Team plan promises an audit log that is not built

- **Today:** The Team plan's limits set `audit_log: true`, the limits are sent to clients in the workspace payload, and the web app's plan card turns that flag into the words "Exportable audit log" for a buyer. A search of `web/src` for "audit" finds only that card: no screen shows or exports one. The only record of account changes is a printed line per request, and the comment says it is deliberately not an audit table. Two real bases exist. The runner keeps every approval decision permanently. Companion appends every agent step (start, end or declined, and who allowed it) to a monthly file on the Mac, opened for appending only, with keys scrubbed and long typed text kept as its length. That file stays on one Mac and is not tied to a person, and the search found no caller that reads it back, so no viewer or export was seen.
- **Evidence:** `crates/farhelm-cloud/src/plan.rs` (lines 113 to 114 and 155), `web/src/components/Account.tsx` (lines 590 to 592), `crates/farhelm-cloud/src/api.rs` (lines 102 to 134), `crates/farhelm-cloud/src/model.rs`, `crates/farhelm-sqlite/migrations/0001_init.sql`, `apple/Sources/Companion/Support/ActionRecord.swift`, `apple/Sources/Companion/AppState.swift` (lines 2466 to 2531)
- **Reference products:** monday.com has an audit log and an Audit Log API. ChatGPT Enterprise has an audit log through its Compliance API. Cursor lists audit logs on Enterprise. Devin's audit logs: (not verified).
- **Size:** M
- **Next task:** An append-only audit table in the control plane for member, device, key and plan changes, with the actor, and an export route gated on the plan flag. Until then, set the flag to false.

### E3. No single sign-on or directory provisioning

- **Today:** Sign-in is an email and password against one account server. Searches for "saml", "SAML" and "oidc" in `crates/` find nothing. The OAuth code in the MCP crate serves connectors, not sign-in (by its place and name; not read). The web and phone sign-in forms have a name, an email and a password field and no other way in, and the account client's sign-in call sends an email, a password and a device label.
- **Evidence:** `docs/account-sign-in.md`, `crates/farhelm-cloud/src/model.rs`, `web/src/components/Auth.tsx` (lines 171 to 238), `mobile/src/screens/Account.tsx` (lines 114 to 146), `packages/client-core/src/cloud.ts` (lines 603 to 619)
- **Reference products:** ChatGPT: SAML SSO, with SCIM on Enterprise. Cursor: SAML and OIDC on Teams, SCIM on Enterprise. Devin: SAML and OIDC on Teams, SCIM on Enterprise. monday.com: SAML 2.0 and SCIM (which plan: not verified). Macro and Claude Code: (not verified).
- **Size:** L
- **Next task:** OIDC sign-in against one identity provider, issuing the control plane's existing sessions; SAML and SCIM after a customer asks.

### E4. A teammate can only be added after signing up alone

- **Today:** There are no invitations: the person creates an account, then an admin adds them by address and picks Viewer, Member or Admin. The web app says so itself under People ("They need an account first; there is no email being sent from here"). The phone app leaves member management out on purpose. The top plan allows 25 members, and there is no tier above Team. Companion has no other people at all (rule 4 of ADR 0013: "there is no view for anyone else").
- **Evidence:** `crates/farhelm-cloud/src/api.rs` (lines 692 to 730), `web/src/components/Account.tsx` (lines 464 to 505), `mobile/src/screens/Account.tsx` (lines 4 to 8), `crates/farhelm-cloud/src/plan.rs`, `docs/adr/0013-farhelm-companion-orbit.md`
- **Reference products:** ChatGPT Business starts at two seats with roles and an admin console. Devin's Teams plan covers up to 100 users. Macro prices per seat for teams.
- **Size:** M
- **Next task:** Single-use, expiring invitation links that an admin copies and passes on, which need no mail transport.

### E5. No second sign-in step

- **Today:** Searches for "totp" in `crates/` and "factor" in the control plane find nothing relevant. The account client's calls for signing in are sign up, sign in, sign out and change password; none enrols or checks a code, and the web sign-in form has no field for one.
- **Evidence:** `docs/account-sign-in.md`, `crates/farhelm-cloud/src/store.rs`, `packages/client-core/src/cloud.ts` (lines 579 to 644), `web/src/components/Auth.tsx` (lines 171 to 238)
- **Reference products:** monday.com offers two-factor sign-in by SMS or authenticator app. ChatGPT: (not verified). Devin states it for Cognition's own staff only.
- **Size:** M
- **Next task:** Authenticator-app codes at sign-in with recovery codes, required for Owner and Admin first.

### E6. Data policy is one switch for the whole gateway

- **Today:** `local_only` or `cloud_allowed` is set by the operator for the gateway, not stored per workspace or project. Companion has no matching switch yet. Local-first is a real advantage here; the gap is that a team cannot set, see or prove the policy per workspace.
- **Evidence:** `docs/system-architecture.md` (section 4.2), `docs/model-providers.md`, `docs/adr/0013-farhelm-companion-orbit.md`
- **Reference products:** ChatGPT does not train on business data by default and lets admins set retention. Cursor guarantees no training in privacy mode. Devin does not train on customer data by default. monday.com offers EU, US or APAC hosting.
- **Size:** M
- **Next task:** Persist the policy per workspace, check it before model selection, and show it wherever a model is chosen.

### E7. No admin view of use and spend across people

- **Today:** Farhelm records calls per project in one ledger and Companion keeps its own usage file per Mac, with budgets per project. Nothing shows or limits use per person or team, and local compute is priced at zero. The web app's home screen shows one "Spend today" total for the whole runner, and the phone's fleet screen shows the same total beside the cache hit rate (an earlier version of this review left that total out). The cost dashboard is asked for one session at a time and splits spend by hour and by tier, not by person or project. The account screen counts machines, devices and people against the plan's limits and nothing else; a search of `web/src/components/Overview.tsx` for "member" finds nothing. The phone app leaves the cost dashboard out on purpose.
- **Evidence:** `apple/Sources/Companion/Support/Usage.swift`, `crates/farhelm-domain/src/price.rs`, `packages/client-core/src/api.ts` (lines 296 to 300), `web/src/components/Overview.tsx` (line 110), `web/src/components/views.tsx` (lines 352 to 433), `mobile/src/App.tsx` (lines 758 to 768), `web/src/components/Account.tsx` (lines 103 to 119), `packages/client-core/src/cloud.ts` (lines 59 to 63), `mobile/README.md` (line 30), `docs/adr/0009-specialists-and-modes.md`
- **Reference products:** Cursor has usage analytics, with group spend limits on Enterprise. Devin has cost controls by team and by user. ChatGPT Business has usage visibility and spend controls.
- **Size:** M
- **Next task:** Per-member and per-project totals from the ledger in the account area, and a compute-time meter for local models.

### E8. No security, retention or compliance material

- **Today:** `docs/` has no page saying where plaintext is processed, how long data is kept or how it is deleted; the ADRs say retention and redaction are still to be defined. (`docs/relay-system-design.md` may cover the relay; it was not read.)
- **Evidence:** `docs/adr/0005-scoped-principal-authorization.md`, `docs/system-architecture.md` (section 5.2)
- **Reference products:** SOC 2 Type 2 is stated by ChatGPT, Claude Code, Devin, monday.com and Macro; ISO 27001 by Claude Code, monday.com and Macro. Cursor's footer names SOC 2 and ISO 27001 (details not verified).
- **Size:** L
- **Next task:** Write the data-handling page first (what is stored where, retention, deletion, sub-processors). A certification needs an organisation and an auditor, not only code.

## The 10 gaps to close first

The order puts cheap unblockers first, then what makes one person's day easier, then the base that teams and enterprise features rest on. Next in line after these: S2 (isolation), S4 (tracing) and E4 (invitations).

1. **U2, Advanced mode end to end (S).** Everything else in Advanced rests on a first finished plan, run and review.
2. **S3, CI for Companion (S).** The board's rules are the safety boundary for a supervisor model and should fail a change that breaks them.
3. **U1, a first answer in minutes (M).** A signed download and a first run that ends in an answer; no later gap matters to someone who never gets this far.
4. **U3, streamed replies from Farhelm (M).** The most visible difference from every chat product, and Companion already expects it.
5. **S1, a working copy per run (M).** It makes parallel runs safe and Autopilot useful.
6. **E1, enforce principals and roles (L).** The gate for sharing a runner; owners, comments, audit and sign-on all need a verified person.
7. **E2, the audit log (M).** The Team plan already says it exists.
8. **S6, the published contract (M).** It lets Companion and Farhelm share one board (U4) and release separately.
9. **U5, task fields (M).** Priority and due date now, owner and comments once E1 lands.
10. **E3, single sign-on with OIDC (L).** The usual first question from a company buyer; start after E1.