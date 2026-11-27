"use strict";

(function () {
  const chat = () => document.getElementById("chat");
  const scroller = () => document.scrollingElement || document.documentElement;

  function atEnd() {
    const s = scroller();
    return s.scrollHeight - s.scrollTop - s.clientHeight < 48;
  }

  function settle(follow, keep) {
    const s = scroller();
    s.scrollTop = follow ? s.scrollHeight : keep;
  }

  window.ChatPage = {
    render(html) {
      const follow = atEnd();
      const keep = scroller().scrollTop;
      chat().innerHTML = html;
      settle(follow, keep);
    },

    updateElement(id, innerHTML) {
      const el = document.getElementById(id);
      if (!el) return;
      const follow = atEnd();
      const keep = scroller().scrollTop;
      el.innerHTML = innerHTML;
      settle(follow, keep);
    },

    append(html) {
      const follow = atEnd();
      const keep = scroller().scrollTop;
      chat().insertAdjacentHTML("beforeend", html);
      settle(follow, keep);
    },

    removeElement(id) {
      const el = document.getElementById(id);
      if (!el) return;
      const follow = atEnd();
      const keep = scroller().scrollTop;
      el.remove();
      settle(follow, keep);
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