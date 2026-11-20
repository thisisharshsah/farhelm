# 0018: Voice control through Meta AI (WebMCP)

Status: accepted, 2026-11-17. User feedback the same evening, after [ADR 0017](0017-lens-chat.md) went live: selecting the bar on the glasses still opens a separate writing panel at the bottom. **Checked locally**: unit tests for every tool and the registration guard, and the end-to-end run with a stand-in model context. Not yet checked on the glasses.

## Context

The panel is Meta's composer. Every supported text field in a glasses Web App opens it for handwriting, dictation or an on-screen keyboard, apps cannot move or replace it, and Meta's guidance is not to build a custom keyboard. Web Apps have no microphone of their own. What Meta does offer is WebMCP: a Web App registers tools on `document.modelContext`, the wearer speaks to Meta AI, and Meta AI calls the tools. It is off by default and enabled per device by Developer Mode or rollout, and only while the app is in front.

## Decision

- **Seven tools** in `src/lens/assistant/tools.ts`: `lens_search`, `lens_play` (a result number or anything to play), `lens_note`, `lens_timer`, `lens_open`, `lens_video` (pause, resume, forward, back, restart) and the read-only `lens_status`. Each goes through the same chat as the bar, so the phone sees voice requests too and every screen updates by the usual path.
- **Platform rules.** Registered on `document.modelContext` with no polyfill, one guarded call per tool so a failure can never stop the others or the app; scalar parameters only, validated in `execute`; the 10 second deadline's signal is forwarded to the API; handled problems are ordinary results with a `next_action`, since only a thrown error counts as failure; results ask Meta AI for one short sentence and leave the detail on the display. Tools returning YouTube titles are marked `untrustedContentHint`, honestly, though Meta does not enforce it.
- **On the display.** The latest search results stay listed with numbers, so "play number two" has something to point at. Home and the empty chat teach the phrase when the tools registered. The page description carries the guardrails Meta AI always reads.
- **The bar stays.** Writing through the composer still works for handwriting, and the console remains the keyboard.

## Consequences

- Nothing new to deploy: the tools ship with the glasses app and do nothing where the browser has no model context.
- Whether a given pair of glasses offers it is Meta's decision per device; after enabling Developer Mode, the glasses and the Meta AI app may need a restart, and eligibility is fixed when Lens launches.
- Not done: no spoken answers from Lens itself (`speechSynthesis` exists on the glasses and could read short answers later).
