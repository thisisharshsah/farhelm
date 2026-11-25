# 0020: Companion's browser: one adaptive frame for both engines

Status: accepted, 2026-11-22. User direction the same day: make the browser
light, advanced, dynamic and easy to use, with the best design on the market
as the reference; an adaptive layout (one compact bar beside the chat, an
Arc or Zen style tab sidebar when there is room, tucked away on request);
light in both senses (memory and CPU, and a minimal look); built straight in
the app, without a mockup first. The features were left to us. Built by the
owner the same day; the first look at it asked for consistent components and
icons (item 9), which is **written, not built yet**. This record is updated
with what use shows.

Follows the Chromium engine described in `apple/README.md` (CEF in Chrome
style, each tab a frameless window kept over the pane) and the WebKit browser
before it.

## Context

The browser had two engines behind one pair of protocols (`BrowsingTab`,
`BrowsingModel`) and one bar: back and forward, a tab strip whose showing tab
was an address field typed into in place, and a new tab page of suggestions.
Every Chromium tab kept a whole browser (its processes and memory) for as long
as it was open, blank or not. Nothing could be drawn over a Chromium page:
each page is a window of its own above the pane, so SwiftUI views over it are
hidden.

## Decision

1. **One frame, both engines.** `BrowserBody` (`UI/Browser/BrowserPane.swift`)
   draws the browser for any `BrowsingModel`. Every key and button runs
   through `BrowserActions` (`Support/BrowserUI.swift`), so the engines cannot
   drift apart; view state that belongs to no chat (the command bar is open,
   the sidebar is out, which start page takes the keys, the agent is at work)
   lives in `BrowserUI`. Tab changes go through `BrowsingModel.show`, which
   keeps split view's rules in one place.
2. **Adaptive layout.** Under 760pt the browser is one compact bar over the
   page. From 760pt (the column dragged wide, or the whole panel) the tabs
   move to a 232pt sidebar beside the page: navigation and Ask, the address,
   the project's pinned pages as tiles, the tabs one per line (dragged to
   reorder). Shift+Cmd+L hides it, remembered; the compact bar comes back in
   its place. The layout follows the measured width, not a mode.
3. **A command bar instead of an address field.** Cmd+L, or a click on the
   address, floats the bar over the page; a new tab (Cmd+T) has it in its
   start page. It goes to an address or searches, finds open tabs, pinned
   pages and history, and offers what to do with the page: ask, pin, copy,
   split view, open outside, reopen a closed tab, put other tabs to sleep.
4. **Anything over a page is in a window of its own.** `OverPage`
   (`UI/Browser/OverPage.swift`) hosts the overlay in a borderless child panel
   above the page windows, following the pane's frame and the panel's
   screen-share setting, and lets it go when it loses the keys. WebKit pages
   get the same treatment so both engines behave alike.
5. **Light.** A Chromium tab makes its browser only when it goes somewhere,
   so a blank tab costs nothing. A tab out of sight for 20 minutes
   (`ChromiumTabs.napAfter`) sleeps: its browser closes, its address, title
   and place stay, and it wakes when shown. A tab playing sound or video is
   left awake. Put Other Tabs to Sleep does the same at once. WebKit tabs do
   not sleep yet.
6. **Pinned pages per project**, in every chat of it: `BrowserPins`, kept in
   `browser-pins.json` in Companion's folder, keyed by project (chats in no
   project share one set), 24 at most each. Cmd+D pins or unpins.
7. **The chat knows the browser beside it** (user direction, 2026-11-23: the
   chat has access to what is open and what is selected). Two levels, so
   nothing large is sent unasked. Every request carries the list of open
   tabs, the one showing marked (`BrowserActions.tabsNote`). A page's text
   goes only with a message: the page showing, as a chip in the chat box
   whose cross keeps it out (the pattern of the open file in code), plus
   tabs added from the chip row, a tab's menu, Ask, or "all open tabs", six
   at most. Pages are read when the message is sent
   (`BrowserActions.snapshots`, 1.5 seconds each at most), so they go as
   they are then: title, address, what is selected, and the text of the
   article or main part (60,000 characters at most). In a chat answer they
   are attachments like any file; the agent gets the first 12,000
   characters of each and can read any tab by number without switching to
   it.
8. **Dynamic, quietly.** The frame takes on the page's color (its
   `theme-color`, or the paint at its top), strongest when the page matches
   the panel's light or dark and faint when it would fight the glass. While
   the agent takes browser steps in this chat, a ring in the look's colors
   breathes in the gap round the page (a Chromium page covers anything drawn
   over it), and the Ask button shows the agent at work in its place.
9. **One look** (added the same day, after the first build: "consistent
   design on component and icons"). Sizes, weights and colors live in
   `BrowserChrome`; every round button is `BarButton` (the panel's top bar
   button, with `.disabled` and an `on` state), every bar menu `BarMenu`
   (AppKit's menu under a `BarButton` face, since SwiftUI's menu button drew
   its label heavier and brighter), every small close, stop or reload
   `InlineButton`. The look's color marks only what is chosen or on: the
   tab showing, the row picked, the side in use, a button whose thing is on.
   The compact bar is always three pieces of glass: back and forward, the
   tabs, and what the browser can do (extensions, Ask, new tab, whole
   panel, close). Ask shows the agent at work in its own place.
10. **Split view** shows the current tab beside another: side by side from
   600pt of page room, one over the other below that. Each side has a header;
   a click there uses that side. Picking any other tab, or opening a new one,
   ends split view; closing the tab in use leaves its partner showing.

Fixed on the way: the Chromium windows did not follow the panel's "hide from
screen sharing" setting, and `AppState.browse` always opened pages in WebKit
even with Chromium showing.

Added 2026-11-23, written and not built yet: find in page, as a small bar
over the page's corner (in `OverPage`, like the command bar) that runs the
page's own `window.find` and counts matches in the page's text, so one
implementation serves both engines; and sound on Chromium tabs, reported by
a page script on the media's own events through a DevTools binding, with
mute through CEF (`ChromiumBrowser.muted`). WebKit tabs show no speaker yet.

## Consequences

- `ChromiumTab.browser` is nil while a tab is blank or asleep; code that
  needs the page must allow for that (`evaluate` answers why not).
- Browser keys apply only while the browser is open in the panel; otherwise
  they pass on as before. They are listed in the command palette.
- Clicking into a Chromium page in split view does not change which side is
  in use (the page window takes the click); the side's header does.

## Not done yet

A downloads list (Chromium saves files itself for now, to Downloads, and
tells Companion nothing), ad and tracker blocking, peek (a link opened in a
preview over the page), the sidebar showing on hover
while tucked away, spaces or tab groups, dragging tabs in the compact strip or
pins to reorder, keeping split pairs as a unit in the sidebar, and sleeping
WebKit tabs.
