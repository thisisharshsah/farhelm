# 0017: Lens chat: one bar for everything, synced between the glasses and the phone

Status: accepted, 2026-11-17. User direction the same day: the glasses' search box was awkward (text arrives from a separate composer and backspace does not work), so use the chat way of entering text, dictate or type, in one bar at the top instead of search bars; and redesign the phone console in the "Glass" style the owner picked, with the glasses app equally premium and easy. **Checked locally**: API tests in workerd with a real local D1, and the end-to-end run in Chrome (passkeys, pairing, phone to glasses and back, playing from the phone, clearing everywhere). Not yet checked on the glasses.

## Context

Text on Meta Ray-Ban Display Web Apps comes only from the glasses' own composer (dictation or neural handwriting), opened by selecting a focused text field. It hands back the whole entry; it cannot edit text already in the field. A search box that expects editing therefore fails on the glasses, while the same entry sent as a chat message works: it is complete when it arrives, and a mistake is fixed by saying it again. The phone, by contrast, edits freely and has its own dictation.

## Decision

- **One conversation per account.** `POST /api/chat` takes what was said or typed; Lens replies in the same row (`messages` table, migration 0002): YouTube results, a saved note, a timer, an opened app or website, help, or an error. Every device reads the same rows, so the glasses and the console show one chat.
- **Deterministic intents.** `src/shared/intents.ts` matches a few phrasings (note, timer with spoken numbers, open, play, search, help) and treats everything else as a YouTube search. Predictable and tested; the assistant (phase 2) takes over the fallthrough later. The YouTube screen sends with `scope: "videos"`, so everything said there is a search.
- **Bars send and empty.** On the glasses every text entry (home, chat, YouTube, notes, apps) is the same `AskBar`: the composer's entry is sent at once and the field empties. No editing, so no backspace.
- **The phone drives the glasses.** The glasses act on new messages from the console: play the asked-for video, start the timer, open the app, or bring the answer into view (never interrupting a playing video). They act once per message (last acted seq kept per account), only while it is under two minutes old, and never replay history on a new install. Results picked on the phone play on the glasses through `POST /api/chat/play`.
- **Sync by long poll.** `GET /api/chat?after=<seq>&cleared=<seq>&wait=20` answers as soon as something is newer, checking once a second, so a message reaches the other device in about a second with one request per 20 seconds when idle. 21 checks keep each request under D1's 50 queries per invocation on the Free plan. Clearing records a mark in `chat_state` that every client honours. WebSockets on the glasses are undocumented, so they are not relied on; a Durable Object push can replace the poll behind the same `useChat` hook later.
- **Console in Glass.** Aurora background, frosted cards, a floating dock (Home, Chat, Apps, Account), the chat composer with browser dictation where available and suggestions, iOS-style grouped lists, and an installable web app manifest. Icons on both apps come from Lucide (`lucide-react`, ISC).
- **Retention.** Messages older than 90 days are removed by the daily cron.

## Consequences

- New dependency: `lucide-react` in `glasses/` only. The release applies migration 0002 before deploying, as for every migration.
- `GET /api/youtube/search` stays for compatibility but the apps no longer call it; searches share its edge cache through `worker/media/videos.ts`. The `recentSearches` preference is no longer written; chat history replaces it.
- `Permissions-Policy` now allows the microphone for Lens's own origin, for dictation in the console. The glasses have no microphone access either way.
- Not done: no assistant answers yet; phrases outside the patterns become searches; the glasses keep the last 40 messages, the console 60.
