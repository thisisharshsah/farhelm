# 0015: A Web App for Meta Ray-Ban Display, in `glasses/`

Status: accepted, 2026-11-17; hosting, access and the home screen layout superseded the same day by [ADR 0016](0016-lens-platform.md) (Cloudflare Worker with D1, passkey accounts and glasses pairing instead of Pages Functions and a shared access key). User direction the same day: build the owner's own apps for their Meta Ray-Ban Display glasses, starting with an iOS-style home screen and a YouTube app fast enough to use on the lens, and keep it with Companion in this repository. **Checked in headless Chrome at 600 x 600 only**: it has not run on the glasses yet, and no YouTube key is configured.

## Context

Meta offers two ways onto the display: Web Apps (HTML, CSS and JavaScript at an https address, added in the Meta AI app in Developer Mode) and the Device Access Toolkit (a native SDK inside an iPhone or Android app). Opening youtube.com on the glasses was slow and its search box took no input: the site is several megabytes of script, and its custom controls are out of reach of the glasses' directional focus.

Companion already serves a page for the glasses (`/glass` in `apple/Sources/Companion/Support/RemoteGlassPage.swift`), with its own pairing code and live feed.

## Decision

- A new client root, `glasses/` (`@farhelm/glasses`), on the repository's client stack: React, strict TypeScript, Vite, Vitest. No router or state library: five screens kept in browser history, because the glasses' Back follows history.
- YouTube search goes through a server function so the API key never reaches the device and the glasses receive a few kilobytes of JSON. The handler (`glasses/server/youtube.ts`) uses only the standard Fetch API; a thin Cloudflare Pages Function adds the edge cache. Pages because the owner's domains already run on Cloudflare; moving host means rewriting only the wrapper.
- Playback uses YouTube's documented IFrame Player API, with the frame made `inert` and our own controls, so focus cannot get stuck inside it.
- The home screen is an iOS-style grid of app icons, four to a row, under a clock (user direction, 2026-11-17: iOS-style icons with each app's real logo, laid out like the iPhone home screen rather than one card per screen). The glasses' own directional focus moves between icons; a line under the grid shows live detail for the focused app. A website's icon is the one it publishes, found at runtime by `/api/icon` (a redirect, cached a day at the edge); nothing is bundled. Any https site can be added as an app.
- Companion stays the owner of its glasses page. The home screen only links to it; nothing is copied.
- An optional shared access key guards the search endpoint, since the daily quota is small (about 100 new searches).
- Settings that would be painful to write on the glasses (access key, Companion link) arrive once as query parameters, are saved on the device and removed from the address.

## Consequences

- `pnpm -r typecheck` and `pnpm -r test` now include `glasses/`, so CI covers it without a workflow change.
- Deploying needs a Cloudflare Pages project and a YouTube Data API key; see `glasses/README.md`.
- Companion's `/glass` is plain HTTP from the Mac. Whether the glasses will open it, and from where, is untested; reaching it away from home depends on Companion's transport, not on this app.
- The native path (Device Access Toolkit inside Companion's iPhone app) remains the route for the microphone, camera and anything the Web App cannot do.
