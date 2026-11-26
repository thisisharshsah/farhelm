"use strict";

// The app calls these with HTML it has already escaped (ChatDocument), so
// nothing in a message runs. Read-only for now: the whole conversation is
// put in again when it changes; later work replaces single turns by id.
(function () {
  const chat = () => document.getElementById("chat");
  const scroller = () => document.scrollingElement || document.documentElement;

  // Follows what is new while the reader is at the end; once they scroll up
  // the page stays where they put it.
  function atEnd() {
    const s = scroller();
    return s.scrollHeight - s.scrollTop - s.clientHeight < 48;
  }

  window.ChatPage = {
    render(html) {
      const follow = atEnd();
      const keep = scroller().scrollTop;
      chat().innerHTML = html;
      scroller().scrollTop = follow ? scroller().scrollHeight : keep;
    },

    style(look) {
      const root = document.documentElement.style;
      root.setProperty("--accent", look.accent);
      root.setProperty("--ink", look.ink);
      root.setProperty("--scale", String(look.scale));
      root.setProperty("--top", look.top + "px");
      root.setProperty("--bottom", look.bottom + "px");
      root.setProperty("--reply-font", look.serif
        ? 'ui-serif, "New York", Georgia, serif'
        : '-apple-system, BlinkMacSystemFont, sans-serif');
      root.colorScheme = look.light ? "light" : "dark";
    },
  };
})();