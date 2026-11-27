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

  // The one channel every tool and the work-timeline toggle posts on.
  // The app refuses unknown names and malformed payloads, so a stray
  // message never runs anything.
  function post(message) {
    const bridge = window.webkit
      && window.webkit.messageHandlers
      && window.webkit.messageHandlers.chatPage;
    if (bridge) bridge.postMessage(message);
  }

  // A work-timeline toggle flips its section's open flag in place so the
  // page responds the moment it is pressed. The app is told after, which
  // keeps the state across the next render.
  function toggleWork(button, opening) {
    const section = button.closest("section.work");
    if (!section) return;
    section.dataset.open = opening ? "true" : "false";
    button.setAttribute("aria-expanded", opening ? "true" : "false");
    button.dataset.action = opening ? "closeWork" : "openWork";
  }

  function onClick(event) {
    const button = event.target.closest("button[data-action]");
    if (!button) return;
    const action = button.dataset.action;
    const turn = button.dataset.turn;
    if (!action || !turn) return;
    if (action === "openWork" || action === "closeWork") {
      toggleWork(button, action === "openWork");
    }
    post({ kind: action, turn: turn });
  }

  document.addEventListener("click", onClick);

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