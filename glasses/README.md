# Lens

Your apps on Meta Ray-Ban Display, run like a product: accounts with passkeys, glasses linked by a short code, a web console, and data synced across devices. Live at **lens.aurovie.com** on Cloudflare.

| Address | What |
| --- | --- |
| `https://lens.aurovie.com/` | Console, for your phone or computer: chat with your glasses, link them, apps, notes, watch history, devices, security, team. Installable with Add to Home Screen |
| `https://lens.aurovie.com/glasses` | The glasses app (add this in the Meta AI app) |
| `https://lens.aurovie.com/api/*` | The API (Cloudflare Worker) |

It works without Farhelm. The Companion app opens Companion's own glasses page (`/glass`, served by the Companion Mac app); its link is set in the console.

## How it fits together

```text
Glasses (Web App, 600x600)  ─┐
                             ├─ lens.aurovie.com ── Worker (Hono) ── D1 (SQLite)
Console (phone, Mac)        ─┘                       │
                                                     ├─ YouTube Data API (search)
                                                     └─ website icons
```

- **Sign-in.** Passkeys only, in the console (no passwords). The first account needs the `SETUP_CODE` secret and becomes the owner; the owner invites everyone else (single-use codes, a week each).
- **Glasses.** They cannot hold a passkey and nobody else can see their display, so they pair with the OAuth device flow (RFC 8628): the glasses show `BCDF-GHJK`, you enter it at `/link` and approve. The glasses get their own session, listed under Devices and revocable there.
- **Sessions.** Opaque tokens in `__Host-` cookies (HttpOnly, Secure, SameSite=Lax), stored only as SHA-256. Console sessions slide over 30 days, glasses over 90.
- **Glasses layout.** A top bar (profile, clock, status) and an app bar (YouTube, Companion, Notes, Timer, your websites, then "+") float over the app, which runs full screen and scrolls under them; swipe left or right on the bar to change app (focus stays on the bar), swipe up or pinch to go into it. The profile holds every setting. Everything is liquid glass, as in Companion and QuantNepal: clear, with a sheen, a rim and, on what floats, water at the edge that bends what passes behind (`src/lens/ui/Glass.tsx`, [ADR 0019](../docs/adr/0019-lens-glasses-layout.md)).
- **Chat.** The console's chat and every bar on the glasses send requests the same way. What you say or type is one message with Lens's reply (videos, a saved note, a timer, an opened app), and every device of the account sees both. Phrases are matched, not guessed (`src/shared/intents.ts`): anything else is a YouTube search. The glasses have no chat; they show the result (play, start the timer, open the app, a short notice), so the phone works as their keyboard. Clients sync with a long poll: `GET /api/chat?after=<seq>&wait=20` answers as soon as there is something newer.
- **YouTube.** Laid out as on a TV: earlier searches as words under the search bar, then rows to move along: results, Watched, then recommendations (For you, more from the channel, popular in its kind, because you watched, popular now). Every row grows as you move along it and more rows come as you move down (`GET /api/youtube/rows?seed=`, `GET /api/youtube/row?key=&page=`). Every card carries its details (length, channel, age, views, likes); videos that come without them (watch history, older answers) get them by id from `GET /api/youtube/details`. Full-screen player with controls over the picture (replay, back and forward 10, held to keep seeking, next, speed), and below it its details, Up next by the song's artist or the video's topic, and the same recommendations. A watch history per account resumes each video where it was left, on any device.
- **Voice.** Lens registers its actions with Meta AI (WebMCP, `src/lens/assistant/tools.ts`), so while Lens is open "Hey Meta, play lofi beats" works without the writing panel. Results are numbered on the display for "play number two". Meta turns this on per device, through Developer Mode or a rollout; elsewhere Lens works the same without it.
- **Hardening.** Same-origin writes only, JSON bodies only, rate limits on sign-in, pairing and search, `no-store` on account data, a Content Security Policy on the pages, an audit log per account, and daily cleanup of expired rows.

## Layout

```text
glasses/
  index.html, glasses.html     the two pages (console at /, glasses at /glasses)
  src/
    console/                   console app: pages/, ui.tsx (components), passkeys.ts
    lens/                      glasses app: features/<app>/ (shell: top bar and app bar), assistant/ (Meta AI tools), lib/ (router, focus, settings)
    client/                    browser code both apps share: API client, account, resources, chat sync
    shared/                    used by the Worker and the browser: API contract (zod), chat intents, apps, codes
    ui/tokens.css              design tokens (brand colours, type, radii)
  worker/
    app.ts                     the Hono app: logging, security headers, origin check, routes
    routes/                    auth, device (pairing), account, data, media, chat, history
    chat/                      chat storage and replies
    media/                     YouTube rows (search, Up next, channels, popular), video details, icons
    sessions.ts, webauthn.ts   sessions; the passkey port (SimpleWebAuthn)
    test/                      API tests, run in workerd with a real local D1
  migrations/                  D1 schema, append only
  wrangler.jsonc               Worker, assets, D1, rate limits, domain, cron
  scripts/release.mjs          one-command deploy
```

## Develop

```sh
pnpm install                                   # from the repository root
pnpm --filter @farhelm/glasses dev             # http://localhost:5180 (console), /glasses (glasses)
pnpm --filter @farhelm/glasses test            # browser logic in jsdom, API in workerd
pnpm --filter @farhelm/glasses typecheck
```

`dev` applies migrations to a local D1 and runs the Worker in workerd, so the API, cookies and passkeys behave as in production (passkeys work on `localhost`). Local secrets live in `glasses/.env.local`, which Git ignores:

```sh
YOUTUBE_API_KEY=...        # optional; without it search answers 503
SETUP_CODE=...             # lets you create the first local account
```

To test on the glasses before deploying, `cloudflared tunnel --url http://localhost:5180` gives an https address; add `<address>/glasses` in the Meta AI app. Passkeys only work on `localhost` and `lens.aurovie.com`, so approve pairing from `localhost` on the Mac.

## Release

```sh
pnpm --filter @farhelm/glasses exec wrangler login   # once
pnpm --filter @farhelm/glasses release
```

The script creates the D1 database if needed, applies migrations (asking first), typechecks, builds, deploys the Worker with its custom domain `lens.aurovie.com` (Cloudflare creates the DNS record and certificate), and sets missing secrets: `YOUTUBE_API_KEY` from `.env.local`, and a fresh `SETUP_CODE` that it prints once. Run it again for every release; it only changes what changed.

## Add it to the glasses

1. Meta AI app: Settings, App Info, tap the version 5 times to turn on Developer Mode.
2. App connections, Add a Web App, and enter `https://lens.aurovie.com/glasses`.
3. Open Lens on the glasses, then go to `lens.aurovie.com/link` on your phone and enter the code they show.
4. With Lens open, say "Hey Meta, play lofi beats". If Meta AI does not use Lens, voice tools are not on for these glasses yet; after turning Developer Mode on, restart the glasses and the Meta AI app.

## YouTube key

Google Cloud project with **YouTube Data API v3** enabled and an API key restricted to it. The default quota is 10,000 units a day. Every call asks for 50 videos, which costs the same as 1: a page of search results or of Up next costs about 101 units, a page from a channel 2, a page of popular videos 1, details for 50 videos 1. Pages are cached at the edge (search for an hour, Up next for 12, channels for 3, popular for 2), so repeats cost nothing and do not count against the per-person rate limit. Recommendations follow at most the 8 videos watched last; scrolling through all of them the first time costs about 900 units.

## Known limits

- Playback uses YouTube's embedded player: its speed depends on the glasses and the connection, YouTube's own buttons (Skip ad included) cannot be reached, and only embeddable videos are returned.
- YouTube removed its related-videos search in 2023, so Up next follows the artist (music) or the topic, not YouTube's own list.
- Holding back or forward keeps seeking only where the Neural Band repeats a held pinch; Meta does not document long press for Web Apps, so elsewhere a press skips 10 seconds.
- Web Apps on the glasses have no camera, microphone or notifications. Features that need them run on the phone or Mac and send results to the glasses.
- Text on the glasses comes from Meta's composer (handwriting, dictation or keyboard), a system panel at the bottom that apps cannot move or replace, and it cannot edit text in place. So every bar sends what it gets and empties; to skip the panel, speak to Meta AI or type in the console.
- Rate limits are approximate and per Cloudflare location.
