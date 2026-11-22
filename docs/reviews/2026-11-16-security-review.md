# Security review and threat model: keys, gateway, relay and remote access

Date: 2026-11-16. Task T-5. Read-only: no code was changed, nothing was run against a live service and nothing was exploited.

## Scope and method

Covered by reading the code in the working tree (branch `provider-layer`, with its uncommitted work):

- Per-project keys and the front door. These live in `crates/farhelm-runner/src/clients.rs` and `front_door.rs`, not in `crates/farhelm-gateway`. The gateway's own credential handling (`crates/farhelm-gateway/src/credential.rs`) was read too.
- Sealing and tokens in `crates/farhelm-crypto`.
- The relay, `crates/farhelm-relay`, and pairing (`docs/relay-system-design.md`).
- Sign-in, `crates/farhelm-cloud` and `docs/account-sign-in.md`.
- Companion's remote server (`apple/Sources/Companion/Support/RemoteServer.swift`, `RemoteWebPage.swift`, `RemoteGlassPage.swift`, `RemoteRelay.swift`), its link through the relay (`apple/Shared/CompanionLink`) and how it keeps API keys (`Keychain.swift`).
- The tunnel config, `deploy/cloudflared/farhelm.yml`, and the launchd job that starts the relay.

Line numbers are those of the working tree on the date above. Every finding comes from reading; none was reproduced by running it. Where a point was not traced to its end, the finding says "to confirm", and section 6 lists what was not covered.

No key, token or other secret appears in this document. Key prefixes and file names are named; values are not.

## 1. What is exposed

| Surface | Where it listens | Who can reach it | What guards it |
|---|---|---|---|
| Control plane and web app | Loopback port 7844, public as `farhelm.aurovie.com` (`deploy/cloudflared/farhelm.yml:37-38`) | Anyone on the internet | Password sign-in, signed tokens, roles |
| Relay | Loopback port 7843 on this Mac, public as `farhelm-relay.aurovie.com` (`farhelm.yml:24-25`) | Anyone on the internet | A channel token from the control plane, or a seat |
| Front door, `/p/<client>/v1` | The runner's port on loopback (`crates/farhelm-runner/src/front_door.rs:7-8`) | Processes on this Mac (and see M11) | One key per client |
| Companion's remote server | Every network interface, plain HTTP, while Remote is on (`RemoteServer.swift:85-89`) | Anyone on the same network | The pairing code |
| Companion's link through the relay | An outgoing connection from the Mac (`RemoteRelay.swift:8`) | The relay and paired devices | The pairing's link key |
| Files and stores | `clients.toml`, the control plane's signing key and database, the macOS Keychain | Processes and people with access to this Mac or its backups | File permissions, the Keychain |

## 2. What is worth protecting

1. The Mac itself. An agent in Companion or the runner runs commands as the owner, so whoever steers an agent without approval controls the machine.
2. Source code, chats, documents and screen captures that pass through agents and remote devices.
3. Credentials: provider API keys, per-client keys, enrolment keys, refresh tokens, the control plane's signing key, the pairing code and link key.
4. Model capacity and budget: per-client token limits and the usage ledger.
5. Availability. Other projects call models through the runner, so an outage there is an outage for them.
6. Metadata: who is connected, and when approvals happen.

## 3. Who can attack, from where, and what they want

| Attacker | From where | What they want | Findings |
|---|---|---|---|
| A stranger on the internet | The two public hostnames | Someone's account, a way onto the host, or to knock the service over | H3, M2, M5, L10, L11, L14 |
| A stranger who signed up (sign-up is open) | The same, with valid tokens for a workspace of their own | To reach other workspaces, or to use the relay as a sender of requests | H4, M4, M5 |
| A workspace member with limited rights, or one who was removed | The control plane's API | More rights, or to keep access | M3, M4, M6 |
| A holder of an enrolment key, or an enrolled machine that was taken over | The control plane's API | Another machine's identity in the same workspace | H5, M7 |
| Someone on the same network as the Mac (shared Wi-Fi, an office, a compromised device at home) | The local network | The pairing code, then the agent, then the Mac | C1, H1, M1, L6, L7 |
| Content the model reads (web pages, repository files, documents, tool output) | Inside a chat or a Run | Commands run without approval, secrets sent out | H2, C1, M10 |
| The relay's operator, Cloudflare, or whoever takes over the relay host | The middle of every relayed connection | To read or forge traffic (they can already delay or drop it) | M2, L9, L12 |
| A lost phone, or a photograph of the pairing QR code | Anywhere | Lasting control of the Mac's agent | C1, M9 |
| Another process or person on the Mac, or a reader of a backup or database copy | Local files, environment, loopback ports | Keys | M7, M10, L4, L5 |
| A client project holding a front door key | Loopback | More models or tokens than it was given | L1, L2, L3 |

What is out of reach by design, and was found to hold: the relay cannot read what it carries (section 5), and the control plane never sees session content (`crates/farhelm-cloud/src/cli.rs:23-25`).

## 4. Findings

Ranking: critical means control of the Mac or of accounts by an attacker who needs little; high means a serious break that needs one condition (an account, a key, a model led astray); medium means a real weakness with limited reach or more conditions; low means hardening.

| ID | Finding | First place to look |
|---|---|---|
| C1 | A paired device can switch a chat to full access with nobody at the Mac | `RemoteServer.swift:580-584` |
| H1 | The pairing code travels in clear, in the address of every request | `RemoteServer.swift:443-444` |
| H2 | Model output can inject script into the phone's page | `RemoteServer.swift:1092` |
| H3 | Sign-in has no attempt limit, and the password check holds the database lock | `crates/farhelm-cloud/src/store.rs:272-301` |
| H4 | The relay sends requests to any address a caller registers for push | `crates/farhelm-relay/src/push.rs:207-230` |
| H5 | Enrolling under an existing machine's name returns a token for that machine | `crates/farhelm-cloud/src/api.rs:977-990` |
| M1 | The remote server's request parser can be crashed or filled before the code is checked | `RemoteServer.swift:384-396` |
| M2 | The relay's stats address answers anyone | `crates/farhelm-relay/src/lib.rs:186-202` |
| M3 | An admin can demote or remove an owner | `crates/farhelm-cloud/src/api.rs:697-734` |
| M4 | Adding a member needs no consent and moves where that person signs in | `crates/farhelm-cloud/src/api.rs:709-733` |
| M5 | Emails are never verified, and sign-up says which are registered | `crates/farhelm-cloud/src/api.rs:393-422` |
| M6 | Role changes and removals take up to an hour, and devices carry no role | `crates/farhelm-cloud/src/api.rs:281-296` |
| M7 | An enrolment key sits unhashed in the database until collected | `crates/farhelm-cloud/src/store.rs:928-952` |
| M8 | The relay starts open on every interface unless told otherwise | `crates/farhelm-relay/src/cli.rs:84` |
| M9 | One shared pairing secret for every device, with no end date | `RemoteServer.swift:300-315` |
| M10 | Agent processes get Companion's whole environment | `apple/Sources/Companion/LLM/CLIAgent.swift:403-405` |
| M11 | A public hostname is in use that the tunnel file does not list (to confirm) | `deploy/redeploy.sh:112` |
| L1 to L14 | Hardening | See below |

### Critical

### C1. A paired device can switch a chat to full access with nobody at the Mac

**Where:** `apple/Sources/Companion/Support/RemoteServer.swift:580-584` (the `/access` route), `apple/Sources/Companion/AppState.swift:4356-4359` (`setAgentAccess` only stores the new level), `apple/Sources/Companion/Support/AgentShell.swift:169-170` (what "full" allows), `RemoteServer.swift:463-469` (the same handlers answer requests that come through the relay).

**Abuse:** The comments say approving stays on the Mac (`RemoteRelay.swift:12-14`, `RemoteServer.swift:796-800`), and the phone is indeed given no Allow button. But `/access` accepts `full` from any request that passed the pairing check, and nothing at the Mac is asked. At that level the agent "asks about nothing": commands anywhere, file edits and control of other apps, with only commands whose text names keys or credentials still asked about (`AgentShell.swift:194-198`). The same caller can open any project chat (`/open`, lines 630-633), send it a message (`/say`, lines 506-511), ask for a look at the screen (`/screen`, lines 531-536) and fetch a turn's picture (`/image`, lines 609-619). So whoever holds the pairing code or the link key runs commands on the Mac as its owner. The pairing code is easy to get on a shared network (H1), script injected into the phone's page can make these calls itself (H2), and a lost phone or a photographed QR code is enough on its own (M9). The approval gate, the product's main safety control, is one request away from off.

**Fix:** Make raising the access level a decision taken at the Mac. Let a remote device lower it (to Manual) freely, and treat a request to raise it as a pending approval shown on the Mac, as command approvals are. Apply it in `handle` so the local and relayed paths share the rule (they already share the handler, lines 500-502). Record which path and device asked. Then bring the comments in `RemoteRelay.swift` and `RemoteServer.swift` in line with the code. The same reasoning applies to `/model` (lines 571-579), which lets a remote device move a chat to another engine and so decide where its content is sent.

### High

### H1. The pairing code travels in clear, in the address of every request

**Where:** `RemoteServer.swift:85-89` (a plain TCP listener, no TLS, no interface chosen), `:246` and `:254` (the link is `http://`), `:443-444` (the code is read from the query string), `:1054`, `:1080`, `:1102`, `:1128` (the phone's page puts it in every address), `RemoteWebPage.swift:209`, `:255`, `:266`, `RemoteGlassPage.swift:206`, `RemoteServer.swift:1038` (kept in the browser's local storage), `:312-315` (ten characters, made once, replaced only by hand at `:300-310`).

**Abuse:** Anyone who can see the network's traffic (another client on shared Wi-Fi, a compromised router, someone redirecting traffic on the local network) reads the code from the first line of any request. It never expires, so one capture is lasting access, and with C1 that is command execution on the Mac. The chat itself, attached files and screen captures cross the network in clear too. Because the pages are served over plain HTTP, an attacker in the path can also change the page and have the phone hand over the code.

**Fix:** Carry local traffic the way relayed traffic already goes: sealed with the pairing's link key, which the QR code already holds (`RemoteRelay.swift:76-79`). That removes the bearer code from the wire and needs no certificate. If the browser pages must stay plain web pages, use TLS with a certificate whose fingerprint travels in the QR code. Until then: take the code from a header, not the address (the event feed can be read with `fetch` streaming, which can set headers), bind the listener to the interface the user chose, and give codes an end date.

### H2. Model output can inject script into the phone's page

**Where:** `RemoteServer.swift:1045` (the phone page's `esc` turns text into HTML through a `div`, which leaves quote characters alone), `:1092` (an agent's offered answer is put inside an attribute, `data-say="..."`), `:792-795` (those answers come from the model's question), `:910-919` (no content security policy on any response). The browser page escapes quotes correctly (`RemoteWebPage.swift:119-121`), so this is the phone's page only.

**Abuse:** A web page, file or tool result the agent reads can lead the model to offer an answer that contains a quote followed by an event-handler attribute. The phone's page writes it into the button's markup with `innerHTML` (line 1097), and the handler runs as script on a page that holds the pairing code (lines 1037-1038). That script can call every route, including `/access` and `/say`. So hostile content read by the agent can end as commands on the Mac with approvals off (C1), with no one touching either device beyond having the page open.

**Fix:** Build that part of the page with `createElement`, `textContent` and `dataset`, not string joining, or at least use the browser page's `esc`, which covers quotes. Add a content security policy with a per-response nonce for the page's one script, so inline handlers cannot run. Fixing C1 removes the worst outcome whatever else slips through.

### H3. Sign-in has no attempt limit, and the password check holds the database lock

**Where:** `crates/farhelm-cloud/src/api.rs:54-100` (the router has only the CORS and change-log layers), `:424-431` (sign-in), `:393-407` (sign-up hashes a password before anything else), `crates/farhelm-cloud/src/store.rs:272-301` (the connection lock is taken at line 274 and held across the Argon2 check at lines 291 and 296), `crates/farhelm-cloud/src/secret.rs:45` and `:52-55` (ten characters minimum; 19 MiB per hash), `deploy/cloudflared/farhelm.yml:37-40` (public, with no rule in front).

**Abuse:** Two things. First, guessing: an attacker with a list of emails and leaked passwords can try them without limit, and M5 tells them which emails are registered. Second, an outage: every sign-in attempt costs an Argon2 check done while the one database connection is locked, on an async worker thread. A modest stream of sign-in attempts therefore stalls every other request, including the heartbeats and channel tokens that machines and devices need, and a stream of sign-ups costs 19 MiB and CPU each with no lock to slow them. Neither needs an account.

**Fix:** In `authenticate`, read the hash, release the lock, then verify, and run the check in bounded blocking execution (a small semaphore caps memory). Add attempt limits per account and per client address with backoff; behind the tunnel every request arrives from loopback, so take the address from Cloudflare's `CF-Connecting-IP` header and trust it only when the peer is loopback. Add a rate rule at Cloudflare for `/v1/auth/*` and `/v1/device/code` as a second layer. Log failed sign-ins (path and account id, never the password). For the team and enterprise goal, plan a second factor or passkeys.

### H4. The relay sends requests to any address a caller registers for push

**Where:** `crates/farhelm-relay/src/push.rs:207-230` (subscribe checks only that the endpoint is not empty), `:85-99` (no limit on subscriptions per channel), `crates/farhelm-relay/src/webpush.rs:173-185` (the only check is `http` or `https` with a host), `:305-313` (the POST), `:321-324` with `push.rs:149` (the response body goes into the log), `push.rs:246-247` (the caller is told how many deliveries succeeded), `crates/farhelm-relay/src/lib.rs:107-110` (the HTTP client has a timeout but no redirect rule, so redirects are followed).

**Abuse:** A caller with a valid token for one channel can register any address as a push endpoint and then trigger a wake-up. As far as the code read shows, a stranger gets such a token by signing up, enrolling a machine of their own and registering a device (`crates/farhelm-cloud/src/api.rs:1180-1246`). The relay then sends a POST from the host it runs on, which here is the owner's Mac: to loopback services (the control plane on 7844, the runner, the tunnel's metrics port named at `farhelm.yml:17`), to other machines on the home network, or to any site. The body is not the attacker's to choose, but the path and query are, the "woken" count says whether the answer was a success (a way to map ports and addresses), and redirects are followed. With no limit on subscriptions, one trigger every ten seconds (`push.rs:44`) becomes as many outgoing requests as were registered, aimed wherever the attacker likes. On a relay started open (M8) none of this needs a token.

**Fix:** Accept only `https` endpoints on the known push services' hosts (Apple, Google, Mozilla, Microsoft), checked at subscribe time. Resolve the host and refuse loopback, private and link-local addresses, then connect to the address that was checked. Turn redirects off for this client. Cap subscriptions per channel and the endpoint's length. Do not write response bodies to the log.

### H5. Enrolling under an existing machine's name returns a token for that machine

**Where:** `crates/farhelm-cloud/src/api.rs:977-990` (a new key under an existing name is parked on the existing machine, and the existing machine's record is what the function goes on with), `:1017-1018` (a runner token is minted for that record), `:1069-1107` (a heartbeat with that token returns a relay token for the machine's channel and a fresh runner token), `:1186-1190` (devices are refused channel tokens while a key change is pending), `:54-93` (there is a route to approve a pending key, none to reject it), `crates/farhelm-cloud/src/store.rs:1054-1080` (an enrolment key works any number of times and has no end date).

**Abuse:** The comment at `api.rs:937-940` says a stolen enrolment key cannot quietly take over an existing machine. In effect it nearly can. Whoever holds any valid enrolment key for a workspace (they are pasted into config files on machines, lines 934-935) enrols with a key of their own and the name of an existing machine. Three things follow. Every device is locked out of the real machine at once. The caller receives a runner token carrying the real machine's id and channel, can sit on its relay channel (the content stays sealed, but timing and sizes are visible and the channel can be flooded), keeps the machine looking online, and can renew the token through heartbeats even after the enrolment key is revoked. And the only way the API offers an admin to end the lockout, short of deleting the machine, is to approve the newcomer's key.

**Fix:** In the name-collision branch, return `key_change_pending` with no runner token (or one limited to asking whether the change was approved). Add a route that rejects a pending key and clears it. Decide whether devices should keep reaching the pinned key while a change is pending; refusing them makes this a lockout anyone with a key can cause. Show admins the fingerprint of both keys before they approve. Give enrolment keys an end date and a use count by default.

### Medium

### M1. The remote server's request parser can be crashed or filled before the code is checked

**Where:** `RemoteServer.swift:384-390` (`Content-Length` is taken as given), `:392-396` (a negative value passes the "has it arrived" test and is then used as an offset, which by reading builds a backwards range and traps), `:342-344` (bytes are appended to the connection's buffer without limit), `:319-331` (no limit on connections), against `:443-447` (the pairing code is checked only after a whole request is parsed) and `:516-518` (the 40 MB limit for attachments applies after the whole body is in memory).

**Abuse:** Anyone on the network, without the code, can send one request with a negative length and stop Companion (ending any agent work in progress), or open connections that declare huge bodies and feed them slowly until memory runs out. The crash was not reproduced; it follows from reading lines 388 to 395.

**Fix:** Refuse a length that is negative or over a cap, with the cap set per route once the request line and code have been read (small by default, 40 MB only for `/attach`). Cap the header size, the number of open connections and how long a connection may stay unfinished. Check the code before reading a body.

### M2. The relay's stats address answers anyone

**Where:** `crates/farhelm-relay/src/lib.rs:127` and `:186-202`.

**Abuse:** The handler takes no token and no seat, and its comment (lines 188-190) rests on a rule that no longer holds: on a gated relay, knowing a channel's name does not let you join it (`crates/farhelm-relay/src/auth.rs:9-17`). Channel names end up in addresses and logs, and a device that was removed still knows its own. With the name alone, anyone on the internet can poll how many parties are connected, how many envelopes and bytes have passed and how many devices wait for push: when someone is at their machine, when approvals happen and how large they are. That is the watching the token gate was added to stop.

**Fix:** Put the same check in front of it as the socket has (`auth::admit` with the token or seat), or serve it on loopback only for the operator.

### M3. An admin can demote or remove an owner

**Where:** `crates/farhelm-cloud/src/api.rs:697-734` (the only role check is that the new role is not above the caller's, line 703; the target's present role is not looked at), `crates/farhelm-cloud/src/store.rs:417-438` (an existing member's role is overwritten), compared with `store.rs:461-474` (the last-owner guard exists for removal only), `api.rs:736-747` (an admin may remove any other member, an owner included, while a second owner remains).

**Abuse:** An admin calls add-member with an owner's email and the role viewer. The owner is demoted. If that was the only owner, the workspace has none: billing needs the owner role (`api.rs:1655`, `:1678`) and nobody can grant it, since no caller may grant a role above their own. The comment at `store.rs:440-444` describes exactly this state as recoverable only by hand in the database.

**Fix:** Refuse any change to a member whose present role is at or above the caller's, unless the caller is an owner. Apply the last-owner guard to role changes in the same transaction as the write. Split "change a role" from "add a member" so each has its own rule.

### M4. Adding a member needs no consent and moves where that person signs in

**Where:** `crates/farhelm-cloud/src/api.rs:709-733` (any registered email can be added), `:437-441` and `:516-521` (sign-in and refresh land in the first workspace listed), `crates/farhelm-cloud/src/store.rs:342` (most recently joined first), `api.rs:434-436` (there is no switching), `:772-775` (a device key registered in one workspace is refused in another), `crates/farhelm-cloud/src/plan.rs:127`, `:139`, `:151` (member limits of 1, 1 and 25).

**Abuse:** An admin of a workspace on the 25-member plan adds a stranger's email. From that person's next sign-in or token refresh (within the hour), their sessions open in the attacker's workspace with whatever role the attacker chose, and their own workspace, machines and devices are out of reach, with no way to switch back. With billing off every workspace allows one member (`crates/farhelm-cloud/src/cli.rs:324`), so this cannot be done on a deployment in that state; it becomes high the day the larger plan is sold.

**Fix:** Make joining a two-step invitation the person accepts while signed in. Keep the workspace a session belongs to on the session itself (the refresh token's row), and pick it at sign-in by last use or by choice, never by "most recently joined".

### M5. Emails are never verified, and sign-up says which are registered

**Where:** `crates/farhelm-cloud/src/api.rs:393-422` (an account is live as soon as it is created), `crates/farhelm-cloud/src/store.rs:186-190` with `api.rs:211-228` (a second sign-up answers "an account with that email already exists"), `api.rs:709-714` (members are added by email alone).

**Abuse:** Sign-in was written with care not to reveal whether an email is registered (`store.rs:266-271`); sign-up reveals it to anyone who asks, which is how lists for password guessing are built (H3). And since nothing proves an email belongs to the person signing up, an attacker can register a colleague's address first. When an admin later adds that colleague "by address", it is the attacker's account that joins the workspace.

**Fix:** Verify an email before the account can be added to any workspace; that needs the mail transport the code notes is missing (`api.rs:694-696`). Until then, show admins when an account was created and require the invited person to accept (M4), and put the attempt limit from H3 in front of sign-up.

### M6. Role changes and removals take up to an hour, and devices carry no role

**Where:** `crates/farhelm-cloud/src/api.rs:42-48` (stated: an hour of staleness), `:281-296` (the caller's role comes from the token, the database is not asked), `:566-586` (a password change ends refresh tokens, not access tokens already issued), `:1180-1226` (any role may get a seat on a machine's channel), `:1061-1067` and `:1109-1118` (the device list a machine receives has no role or owner in it), `crates/farhelm-cloud/src/store.rs:476-480` (removing a member deletes the membership row).

**Abuse:** A demoted admin or a removed member keeps the old rights for up to an hour: time to create an enrolment key, approve a machine or remove others. Past that hour, two points are to confirm. No handling of the viewer role was found anywhere in `crates/farhelm-runner/src`, and the device list gives a machine no way to tell a viewer's phone from an admin's, so a viewer's device may be able to do what any device can. And removing a member was not seen to remove the devices that person registered, in which case machines keep sealing events to them.

**Fix:** On routes that grant something (enrolment keys, approvals, members, channel tokens), read the caller's present role from the store; it is the same database and one indexed query. Refuse channel tokens below the member role, or send each device's role to the machine and enforce it there. On removal, delete or disable the person's devices and end their sessions.

### M7. An enrolment key sits unhashed in the database until collected

**Where:** `crates/farhelm-cloud/src/store.rs:928-952` (approval writes the key itself into `device_authorization.enrollment_key`), `:1022-1027` (cleared only when the machine collects it), `:1039-1048` (expired rows are deleted, but only when called), `crates/farhelm-cloud/src/api.rs:1358-1360` (the only caller is the next request for a device code), `:1524-1547` (the key is minted and stored at approval).

**Abuse:** The design says such keys are stored nowhere (`api.rs:1259-1260`, `crates/farhelm-cloud/src/secret.rs:6-10`). Between approval and collection the key is in the database in usable form, and if the machine never collects it the row stays until some later machine asks for a code. The comment at `store.rs:1035-1037` says an expired row holds no key; an approved row that was never collected does. The key itself is never revoked in that case, so a copy of the database or a backup taken in that window yields a credential that adds machines to the workspace.

**Fix:** Seal the stored key with a value derived from the device code (which only the machine holds), or mint the key at collection time and store only the approval. Revoke the key when its row expires uncollected, and purge on a timer.

### M8. The relay starts open on every interface unless told otherwise

**Where:** `crates/farhelm-relay/src/cli.rs:84` (binds `0.0.0.0` by default), `:136-140` and `:165-176` (with no key it serves open and says so in one log line), `deploy/redeploy.sh:126-134` (the deploy check).

**Abuse:** The relay on this Mac is started correctly: on loopback, with the control plane's key (`deploy/launchd/plist/com.farhelm.relay.plist:15-16` and `:23-24`). The hazard is the default. A start by hand, or a job that loses two flags, puts an open relay on the local network and the public hostname, where any channel that is not a seat channel can be joined by name and H4 needs no token. The deploy check would not catch it reliably: its comment says the relay refuses to start ungated, which the code does not do, and it searches the whole log file, so an "auth on" line from an earlier start satisfies it.

**Fix:** Bind loopback by default, as the control plane does (`crates/farhelm-cloud/src/cli.rs:219-222`). Require an explicit flag to run open. In the deploy check, read the `auth` field of the relay's health answer (`crates/farhelm-relay/src/lib.rs:142`) instead of the log, and correct the comment.

### M9. One shared pairing secret for every device, with no end date

**Where:** `RemoteServer.swift:300-315` (one code; replacing it cuts off every device), `RemoteRelay.swift:90-103` (one link key, replaced only together with the code), `apple/Shared/CompanionLink/Sources/CompanionLink/LinkEndpoint.swift:80-90` (every device seals and opens with the same two keys), `:395-404` (the device id handed to the request handler is whatever the sender wrote).

**Abuse:** A phone that is lost, sold or borrowed, or a photograph of the QR code, keeps full remote access until the owner notices and pairs everything again; nothing expires and nothing lists the devices that are paired. Because all devices share the keys, one device cannot be cut off alone, any device can name itself as another, and any device can forge the Mac's answers to the others. For the audit goal, nothing can say which device did what.

**Fix:** Give each device its own key at pairing (the runner's design already does this for its devices, `docs/relay-system-design.md:600`), keep a list in Settings with last-seen times and a remove button, and expire pairings that go unused.

### M10. Agent processes get Companion's whole environment

**Where:** `apple/Sources/Companion/LLM/CLIAgent.swift:403-405`, `:704-707`, `:851-853`, `:1014-1016` (each copies the app's environment into the process it starts), `apple/Sources/Companion/LLM/EngineChoice.swift:73-97` and `apple/Sources/Companion/AppState.swift:4849`, `:4861` (provider keys are accepted from environment variables as well as the Keychain).

**Abuse:** When a provider key is supplied as an environment variable, every process started at those lines can read it. A model led astray by something it read needs only a command that prints the environment, which does not name a key and so does not trip the text match at `AgentShell.swift:194-198`, and the key is in the chat, in a file, or on its way to whichever provider serves the model. Which of the four places run agent commands and which run other tools was not traced one by one (to confirm).

**Fix:** Start child processes with a short allow-list of variables (path, home, language, terminal) plus what the tool itself needs, never the app's full environment. Prefer the Keychain and treat environment keys as a developer convenience that is off unless asked for.

### M11. A public hostname is in use that the tunnel file does not list (to confirm)

**Where:** `deploy/redeploy.sh:112` (the deploy check calls `farhelm-mac.aurovie.com/mcp` and notes that the runner serves the web app on paths it does not route), `deploy/cloudflared/farhelm.yml:20-43` (only two hostnames, then a catch-all 404).

**Abuse:** The checked-in tunnel file is a template (lines 3-4), and the live configuration is in the home folder, outside the repository, so it was not read. If a tunnel does route that hostname to the runner's port, then the front door (`/p/<client>/v1`) and the runner's own API are on the internet, where the project's rule is that the loopback API is not exposed. A review of the checked-in file alone cannot tell.

**Fix:** Keep every tunnel's ingress rules in the repository, with paths limited to what must be public (for a connector, `/mcp` only). Add a deploy check that fetches a front door path through each public hostname and fails unless it gets a 404.

### Low

### L1. The front door's daily limit is checked only before a call

**Where:** `crates/farhelm-runner/src/front_door.rs:185-203`, used at `:266` and `:498`.

**Abuse:** A client may start a call while one token of its allowance remains, and calls made at the same moment all pass the check before any is recorded, so a client can go well past its daily limit.

**Fix:** Reserve the request's `max_tokens` against the allowance before the call and settle to actual usage after it, in one transaction per step.

### L2. A client held to some models can be served by others

**Where:** `crates/farhelm-runner/src/front_door.rs:165-181`, `:81-97`, `crates/farhelm-runner/src/clients.rs:50-56`.

**Abuse:** The model list is enforced only when the request names a model the registry declares. An empty or undeclared name falls to the client's default model, and when the client has none, to the gateway's routing, which may pick a model outside the client's list.

**Fix:** After a model is chosen, check `client.allows` on what will actually run, and make `check` report a client that has a model list but no default.

### L3. One key per client, with no overlap, end date or record of failures

**Where:** `crates/farhelm-runner/src/clients.rs:45-49`, `:176-181`, `crates/farhelm-runner/src/front_door.rs:152-162`.

**Abuse:** Rotating a key means a gap or a restart with both sides changed at once, which discourages rotation; a leaked key works until someone notices; and a wrong key leaves no trace, so guessing or a misconfigured project cannot be seen.

**Fix:** Allow two hashes per client during rotation, an optional end date, and a counted, logged line for each refused key (client name and time, never the key).

### L4. `clients.toml` is neither committed nor ignored

**Where:** `clients.toml` at the repository root (untracked, and `git check-ignore` reports it is not ignored), `crates/farhelm-runner/src/clients.rs:19` and `:147-153`.

**Abuse:** The file holds only SHA-256 hashes of 256-bit keys, which cannot be reversed, so a commit would not expose a key. It would publish the client names, model lists and limits of the owner's other projects, and a stray `git add .` is all it takes.

**Fix:** Decide where the live file belongs (the runner's home folder) and ignore it in the repository, keeping an example file with placeholder values.

### L5. The Keychain wrapper sets no protection class and ignores failures

**Where:** `apple/Sources/Companion/Support/Keychain.swift:45-49` (no accessibility attribute, not the data protection keychain), `:55-60` (the results of update and add are dropped), `:11` and `:43` (values are cached in memory, and the cache is updated before the write is known to have worked).

**Abuse:** Keys do go to the Keychain, not to settings files, which is right. But a write that fails is reported nowhere while the app goes on using the cached value, so a key or a new pairing code can be lost at the next launch; in the pairing code's case the old code silently comes back. With no class set, when and by whom an item can be read is left to the system's defaults.

**Fix:** Set `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, use the data protection keychain, check each status, and update the cache only after a write succeeds.

### L6. The pairing code is compared with `==` and wrong guesses are not counted

**Where:** `RemoteServer.swift:443-447`, `:312-315`.

**Abuse:** The code has about 50 bits from the system's generator, so guessing over the network is not practical; the comparison is not constant-time and nothing slows or records repeated wrong codes. Hardening only.

**Fix:** Compare hashes in constant time, and after a few wrong codes from one address answer slowly and show it on the Mac.

### L7. Every response allows any origin and carries no security headers

**Where:** `RemoteServer.swift:650`, `:910-919`.

**Abuse:** `Access-Control-Allow-Origin: *` lets script on any website read this server's answers once it has the code, and with no content security policy, no `nosniff` and no framing rule, nothing limits what an injected script (H2) can do or where the pages can be embedded.

**Fix:** Drop the any-origin header (the pages are served by the same server), and add a content security policy, `X-Content-Type-Options: nosniff`, `frame-ancestors 'none'` and `Referrer-Policy: no-referrer`.

### L8. A replayed refresh token is refused without ending the session or telling anyone

**Where:** `crates/farhelm-cloud/src/store.rs:33`, `:1202-1207`.

**Abuse:** A deliberate trade-off, explained in the code: a used token presented after the 30-second window is refused and nothing else happens. A thief who refreshes first keeps the session; the owner is signed out with no sign of why.

**Fix:** Record the event, show "signed in elsewhere" in the session list, and consider ending the session when the old token arrives from a different address than the one that rotated it.

### L9. The relay does not cap sockets per channel or the number of channels

**Where:** `crates/farhelm-relay/src/hub.rs:58-78`, `crates/farhelm-relay/src/lib.rs:242-245`, `crates/farhelm-relay/src/auth.rs:193-197`.

**Abuse:** The rate limit is per connection, so a token or seat holder multiplies it by opening more sockets; each socket costs a buffer of 128 envelopes of up to 256 KiB (`hub.rs:20`, `lib.rs:43`).

**Fix:** Cap connections per subject and per channel, and meter the rate per subject across its connections.

### L10. The health addresses give away details

**Where:** `crates/farhelm-cloud/src/api.rs:602-609`, `crates/farhelm-relay/src/lib.rs:135-144`.

**Abuse:** Anyone can read the control plane's schema version, whether billing is on and the relay's address, and the relay's number of live channels. Useful to someone preparing an attack, and the channel count shows activity over time.

**Fix:** Answer `{"ok": true}` to the public and keep the rest for loopback or a signed-in admin.

### L11. Machine codes can be requested without limit, and the approval screen shows only a name the machine chose

**Where:** `crates/farhelm-cloud/src/api.rs:1353-1388`, `:1326-1327`, `:1454-1473`.

**Abuse:** Anyone can create rows in the database at will for fifteen minutes each. And a stranger can ask for a code under a familiar machine name and talk an admin into typing it in; the screen gives the admin nothing but that name to judge by.

**Fix:** Limit requests per address (see H3 for where the address comes from), cap live requests, and show the admin the requesting address, the time and a warning that the name is not checked.

### L12. The link uses random nonces under a key that is never rotated, and its memory ceiling is high

**Where:** `apple/Shared/CompanionLink/Sources/CompanionLink/LinkWire.swift:192-199`, `apple/Shared/CompanionLink/Sources/CompanionLink/LinkAssembler.swift:26-31`.

**Abuse:** Random 96-bit nonces are safe for about four billion frames per key; a pairing's key lasts until the user pairs again (M9), so there is a far-off ceiling nobody tracks. A paired device can also make the Mac hold up to 32 unfinished messages of 64 MiB each.

**Fix:** Derive a fresh key per connection from the link key and a nonce each side sends, which also bounds the count. Cap the total bytes held in unfinished messages, not only each one.

### L13. A personal email address is checked in as the push contact

**Where:** `deploy/launchd/plist/com.farhelm.relay.plist:22`.

**Abuse:** Not a secret, but it is in the repository's history and is sent to push services with every wake-up. A privacy point for a commercial product.

**Fix:** Use a role address for the product and keep per-machine values out of the checked-in job files.

### L14. The tunnel adds no rule of its own in front of the public services

**Where:** `deploy/cloudflared/farhelm.yml:24-40`.

**Abuse:** Every limit has to be in the applications, and today sign-in has none (H3). The file also sets `noTLSVerify: false` on an origin reached over plain HTTP on loopback (line 32), which has no effect and may read as protection it does not give.

**Fix:** Add Cloudflare rate rules for the sign-in, sign-up and machine-code paths, and remove the setting that does nothing.

## 5. What holds up

- **Per-client keys.** 256 bits from the operating system (`crates/farhelm-runner/src/clients.rs:81-83`), stored as SHA-256 only (`:45-49`), compared without stopping at the first difference (`:87-93`), with one answer for an unknown client and a wrong key (`:176-181`). Each client's calls are recorded under its own session and its cache is kept apart (`crates/farhelm-runner/src/front_door.rs:230-231`). Request bodies are capped at 8 MiB (`:70`).
- **Gateway credentials.** Tokens from a helper command are held in memory only, and errors name the program, never its arguments or output (`crates/farhelm-gateway/src/credential.rs:29-35`, `:57-64`).
- **Passwords and bearer tokens.** Argon2id (`crates/farhelm-cloud/src/secret.rs:52-55`); an unknown email costs the same as a wrong password at sign-in (`crates/farhelm-cloud/src/store.rs:285-293`); refresh tokens, enrolment keys and device codes are 256 bits and stored hashed (`secret.rs:82-86`, `:107-110`, `store.rs:892`, `:1115`); refresh tokens rotate on use (`store.rs:1139-1178`); a password change ends every session's refresh token (`crates/farhelm-cloud/src/api.rs:580-584`).
- **Workspace separation.** The workspace always comes from the signed token; a machine in another workspace answers 404 (`api.rs:894-905`); devices are checked against the caller's workspace and account (`:816-818`, `:1208-1210`); admin routes check the role (`:702`, `:1269`, `:1293`, `:1302`, `:1459`, `:1496`, `:1570`) and billing needs an owner (`:1655`, `:1678`).
- **Machine sign-in by code.** The key is minted only when an admin approves (`api.rs:1484-1487`), handed over once (`store.rs:1009-1030`), and an unknown code answers the same as an expired one (`api.rs:1427-1431`).
- **Tokens.** Verification was read (`crates/farhelm-crypto/src/token.rs:303-566`): one signing algorithm, expiry required, audience checked at each use (`api.rs:312`, `:342`, `crates/farhelm-relay/src/auth.rs:143`). Channel tokens last fifteen minutes (`token.rs:34`) and are bound to one channel (`auth.rs:146-150`).
- **The relay.** The token or seat is checked before the WebSocket opens (`crates/farhelm-relay/src/lib.rs:206-236`); seat channels are never opened by a token or left open on an open relay (`auth.rs:129-133`); envelopes over 256 KiB and envelopes for another channel are dropped (`lib.rs:286-299`); nothing is stored (`crates/farhelm-relay/src/hub.rs:7-10`); push wake-ups carry no content (`crates/farhelm-relay/src/push.rs:131-137`) and triggering one needs the channel's token (`:243-245`).
- **Companion's link.** Each frame is sealed with ChaCha20-Poly1305 with the channel and sender bound in (`LinkWire.swift:188-199`), with separate keys per direction (`LinkEndpoint.swift:80-90`); repeats are remembered for ten minutes and frames more than five minutes off are refused (`LinkAssembler.swift:26-31`, `:52-66`). The relay, and Cloudflare in front of it, can delay or drop frames but not read, change or replay them.
- **Companion's remote server.** Off unless turned on (`RemoteServer.swift:66-72`); the pairing code and link key are in the Keychain (`:290-297`, `RemoteRelay.swift:86-95`); pictures are looked up by turn, so no path from a phone reaches the disk (`:609-619`); attached files are capped and renamed (`:515-521`); the browser page escapes its output correctly (`RemoteWebPage.swift:119-121`).
- **The control plane's host.** Loopback by default (`crates/farhelm-cloud/src/cli.rs:219-222`); the signing key is created owner-only (`:244-257`); the change log never holds bodies or the authorization header (`api.rs:129-132`); database errors are not shown to callers (`:218-227`).
- **The tunnel.** A separate tunnel from the owner's other sites (`deploy/cloudflared/farhelm.yml:6-9`), metrics on loopback (`:17`), unknown hostnames answered 404 (`:43`), and the live relay started on loopback with the control plane's key (`deploy/launchd/plist/com.farhelm.relay.plist:15-16`, `:23-24`).

## 6. Not covered, or to confirm

- Nothing was run. The crash in M1 and the request paths in H4 and H5 follow from reading and should be confirmed with tests when they are fixed.
- Replay handling for envelopes between the runner and its devices in `crates/farhelm-crypto/src/lib.rs`: this review does not state a result. Companion's own link was checked (section 5).
- The runner's own API (`crates/farhelm-runner/src/api.rs`): whether loopback callers need a credential, and how a device's command is authorized by role (M6).
- The ledger's storage (`crates/farhelm-app/src/ledger.rs`): whether rows can be changed after the fact. Only what the front door writes and reads was reviewed.
- The billing webhook's signature check (`crates/farhelm-cloud/src/billing.rs`) and the connector's OAuth routes, which are merged into the control plane (`crates/farhelm-cloud/src/cli.rs:283`).
- Where the web app keeps its tokens in the browser.
- The live tunnel configuration in the home folder, and what `farhelm-mac.aurovie.com` routes to (M11).
- Which of the processes in M10 run agent commands, and what `AgentTools.isSensitive` matches.
- Whether removing a member also removes that person's devices (M6).
- The iPhone, iPad and Watch apps' side of pairing and their key storage.

## 7. Suggested order of work

1. C1 and H2: both are small changes in `RemoteServer.swift`, and together they close the path from hostile content or a captured code to commands on the Mac.
2. H1: move local traffic onto the sealed link, which also settles L6 and most of L7.
3. H3: release the lock before the password check and add attempt limits; this is the public sign-in.
4. H4 and M8: the push endpoint allow-list and the relay's defaults.
5. H5 and M7: enrolment.
6. M1, M2 and M3, each a short, contained fix, then the rest in order.

## 8. Status, 2026-11-20

Fixed on the `security-fixes` branch. The Rust changes are tested; the Swift changes are not yet built or tried on a device. Next by severity: M7 and enrolment keys' end dates, then the browser and glasses pages' part of H1.

| ID | Status | Where |
|---|---|---|
| C1 | Fixed: from a phone or the relay, access can only be lowered. Raising it is answered 403, and the iPhone app says to do it on the Mac | `RemoteServer.swift` (`/access`), `CompanionKit/Client.swift` |
| H2 | Fixed: the phone page's `esc` escapes quotes, as the browser page's does | `RemoteServer.swift` (the phone page) |
| M1 | Fixed: the head is capped at 16 KB; a missing, negative or doubled length is refused; the code is checked before the body; bodies are capped (40 MB for `/attach`, 1 MB otherwise); at most 32 connections, each with 120 seconds to send its request; the buffer grows in place | `RemoteServer.swift` (`takeRequest`, `accept`, `receive`) |
| L6 | Fixed: compared in constant time; past 1,000 wrong codes in ten minutes an address is refused | `RemoteServer.swift` |
| M10 | Partly: agent commands get a short list of variables (`AgentProcess.plainEnvironment`). CLI tools still get the app's environment, since they may need their own settings | `AgentProcess.swift`, `AgentShell.swift` |
| M11 | Partly: the runner refuses `/v1` through any tunnel or proxy. The live tunnel file is still outside the repository; the path rule to use is in `deploy/README.md` | `crates/farhelm-runner/src/api.rs` |
| H1 | Partly: the iPhone, iPad and Watch apps now reach the Mac on its network through the relay's sealed protocol, served by the Mac itself (`LocalLink`, found through `/link`), with the key in every pairing code. Still open: the browser and glasses pages send the code in clear (left as they are for now, by the owner's choice), and an app paired before this falls back to plain HTTP until paired again. The listener refuses connections from outside this Mac's own networks | `Support/LocalLink.swift`, `RemoteServer.isNearby`, `CompanionKit/Client.swift` |
| H3 | Fixed: ten failed sign-ins for an account, or a hundred from one address (a /64 for IPv6), in fifteen minutes, then a wait, a correct password included; twenty sign-ups an hour from one address. Argon2 runs off the async workers, four at a time, after the database lock is released. `CF-Connecting-IP` is believed only from a loopback peer. Still worth adding: a Cloudflare rate rule for `/v1/auth/*` | `crates/farhelm-cloud/src/throttle.rs`, `api.rs` (`login`, `signup`, `client_address`), `store.rs` (`authenticate`) |
| H4 | Fixed: push endpoints must be https, on the standard port, on Google's, Apple's, Mozilla's or Microsoft's push service; at most 1,024 characters and 20 devices a channel; no redirects; the other end's answer is not logged | `crates/farhelm-relay/src/push.rs` (`acceptable_endpoint`), `lib.rs`, `webpush.rs` |
| H5 | Fixed: a new key under a name on file is parked and answered 409, with no token and no sign of life on the machine on file; devices keep reaching the pinned key; an admin can approve or reject it (`/v1/runners/{id}/reject-key`), and the web app shows the new key's start; the runner asks again until approved. Still open: enrolment keys have no end date or use count (and M7) | `crates/farhelm-cloud/src/api.rs` (`enroll_runner`, `channel_token`, `reject_key`), `crates/farhelm-runner/src/cloud.rs`, `web/src/components/Account.tsx` |
| M2 | Fixed: the stats address asks for the channel's token, as a wake-up does | `crates/farhelm-relay/src/lib.rs` (`channel_stats`) |
| M8 | Fixed: the relay binds loopback unless told otherwise | `crates/farhelm-relay/src/cli.rs` |

New findings, 2026-11-20:

- **R1. The runner's local API trusts every program on this Mac.** `/v1` needs no credential on loopback, and an approval states its own channel (`decide` takes `via` from the body), so a script, or an agent the runner supervises, can clear a command, destructive ones included. Websites, DNS rebinding and tunnels are now refused (`api::local_only`, tested in `tests/local_api_guard.rs`). Destructive commands are now approved only from a paired device: the local API answers 403 to approving one and can still deny it (`api::decide`, tested in `tests/transport_parity.rs`). Still open: a program on this Mac can clear low and medium ones. Next: approvals at the Mac through Companion, signed with a key that needs Touch ID (ADR 0013, step 7).
- **R2. Agent commands ran with Companion's macOS permissions.** What `Process` starts counts as Companion for screen recording, the microphone, accessibility and automation. Fixed: `AgentShell` and the CLI agents start through `AgentProcess`, which disclaims that responsibility, as Terminal does for its shells. A command that drives another app through AppleScript is now asked about in its own name.
- **R3. A page could name another site to iCloud Passwords.** The page script reported `location.hostname`, and `fill` trusted it, so a page could be offered another site's logins and handed the password the person picked. Fixed: the site comes from the browser (`PasswordPage.passwordHost`) and is checked again just before filling; in WebKit the script runs in a content world of its own, out of the page's reach. In Chromium tabs it still runs in the page's world.
