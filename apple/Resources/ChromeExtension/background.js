// Companion's bridge to Chrome. The Companion app on this Mac sends
// commands (open a page, read it, click, type) through Chrome's native
// messaging; this runs them in your tabs and sends back what happened.
// It never reads or types into password fields: sign-ins are left to you
// and iCloud Passwords.
const HOST = "com.companion.browser";
let port = null;
let agentTab = null;

function connect() {
  if (port) return;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (e) {
    port = null;
    return retry();
  }
  port.onMessage.addListener(onCommand);
  port.onDisconnect.addListener(() => { port = null; retry(); });
  port.postMessage({ type: "hello", version: chrome.runtime.getManifest().version, agent: navigator.userAgent });
}

function retry() { chrome.alarms.create("companion-reconnect", { delayInMinutes: 0.5 }); }
chrome.alarms.onAlarm.addListener((alarm) => { if (alarm.name === "companion-reconnect") connect(); });
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
chrome.action.onClicked.addListener(connect);
connect();

function reply(id, ok, result) {
  if (port) port.postMessage({ type: "result", id, ok, result });
}

async function onCommand(message) {
  if (!message || message.type !== "command") return;
  const { id, command, args = {} } = message;
  try {
    reply(id, true, await run(command, args));
  } catch (e) {
    reply(id, false, { error: String(e && e.message ? e.message : e) });
  }
}

async function targetTab(args) {
  if (args.tab) return args.tab;
  if (agentTab) {
    try { await chrome.tabs.get(agentTab); return agentTab; } catch (e) { agentTab = null; }
  }
  const [active] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  if (!active) throw new Error("No tab is open in Chrome.");
  return active.id;
}

function loaded(tabId, timeout = 20000) {
  return new Promise((resolve) => {
    let done = false;
    const finish = () => { if (!done) { done = true; chrome.tabs.onUpdated.removeListener(listener); resolve(); } };
    const listener = (id, info) => { if (id === tabId && info.status === "complete") finish(); };
    chrome.tabs.onUpdated.addListener(listener);
    chrome.tabs.get(tabId).then((tab) => { if (tab.status === "complete") setTimeout(finish, 300); }).catch(finish);
    setTimeout(finish, timeout);
  });
}

async function inPage(tabId, func, args = []) {
  const [result] = await chrome.scripting.executeScript({ target: { tabId }, func, args });
  return result ? result.result : null;
}

async function describe(tabId) {
  const tab = await chrome.tabs.get(tabId);
  return { tab: tab.id, title: tab.title, url: tab.url };
}

async function run(command, args) {
  switch (command) {
    case "tabs": {
      const tabs = await chrome.tabs.query({});
      return { tabs: tabs.map((t) => ({ tab: t.id, title: t.title, url: t.url, active: t.active })) };
    }
    case "open": {
      let tabId;
      if (args.newTab || !agentTab) {
        const tab = await chrome.tabs.create({ url: args.url, active: true });
        tabId = tab.id;
      } else {
        tabId = await targetTab(args);
        await chrome.tabs.update(tabId, { url: args.url, active: true });
      }
      agentTab = tabId;
      await loaded(tabId);
      return await describe(tabId);
    }
    case "focus": {
      const tabId = await targetTab(args);
      const tab = await chrome.tabs.update(tabId, { active: true });
      await chrome.windows.update(tab.windowId, { focused: true });
      agentTab = tabId;
      return await describe(tabId);
    }
    case "read": {
      const tabId = await targetTab(args);
      agentTab = tabId;
      return await inPage(tabId, snapshot);
    }
    case "click": {
      const tabId = await targetTab(args);
      const label = await inPage(tabId, clickElement, [String(args.target)]);
      await new Promise((r) => setTimeout(r, 700));
      await loaded(tabId, 8000);
      return Object.assign({ clicked: label }, await describe(tabId));
    }
    case "type": {
      const tabId = await targetTab(args);
      const outcome = await inPage(tabId, typeInto, [String(args.target), String(args.text || ""), !!args.submit]);
      if (outcome && outcome.error) throw new Error(outcome.error);
      if (args.submit) { await new Promise((r) => setTimeout(r, 700)); await loaded(tabId, 8000); }
      return Object.assign({ typed: outcome && outcome.field }, await describe(tabId));
    }
    case "scroll": {
      const tabId = await targetTab(args);
      await inPage(tabId, (down) => window.scrollBy(0, (down ? 1 : -1) * window.innerHeight * 0.8), [args.direction !== "up"]);
      return await describe(tabId);
    }
    case "back": {
      const tabId = await targetTab(args);
      await chrome.tabs.goBack(tabId);
      await loaded(tabId, 8000);
      return await describe(tabId);
    }
    case "key": {
      const tabId = await targetTab(args);
      await inPage(tabId, pressKey, [String(args.key || "Enter")]);
      return await describe(tabId);
    }
    default:
      throw new Error("Unknown command " + command);
  }
}

// ---- Run inside the page ----

function snapshot() {
  document.querySelectorAll("[data-companion-id]").forEach((e) => e.removeAttribute("data-companion-id"));
  const selector = "a[href],button,input,select,textarea,summary,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[role=option],[contenteditable=true]";
  const elements = [];
  let n = 0;
  for (const el of document.querySelectorAll(selector)) {
    const box = el.getBoundingClientRect();
    if (box.width === 0 && box.height === 0) continue;
    const style = getComputedStyle(el);
    if (style.visibility === "hidden" || style.display === "none") continue;
    if (el.type === "hidden") continue;
    n += 1;
    el.setAttribute("data-companion-id", String(n));
    const secret = el.type === "password";
    const label = (el.getAttribute("aria-label") || el.innerText || (secret ? "" : el.value) || el.placeholder || el.title || el.name || "")
      .trim().replace(/\s+/g, " ").slice(0, 80);
    elements.push({ i: n, tag: el.tagName.toLowerCase(), type: el.type || el.getAttribute("role") || "", label,
                    href: el.href ? String(el.href).slice(0, 140) : "" });
    if (n >= 300) break;
  }
  const text = (document.body ? document.body.innerText : "").replace(/\n{3,}/g, "\n\n").slice(0, 15000);
  return { title: document.title, url: location.href, text, elements };
}

function clickElement(id) {
  const el = document.querySelector('[data-companion-id="' + id + '"]');
  if (!el) throw new Error("Element " + id + " is not on the page any more; read the page again.");
  el.scrollIntoView({ block: "center" });
  el.click();
  return (el.getAttribute("aria-label") || el.innerText || el.value || el.tagName).trim().slice(0, 80);
}

function typeInto(id, text, submit) {
  const el = document.querySelector('[data-companion-id="' + id + '"]');
  if (!el) return { error: "Element " + id + " is not on the page any more; read the page again." };
  if (el.type === "password" || /pass(word|code)|one-time-code/i.test(el.autocomplete || "")) {
    return { error: "That is a password field. Passwords are filled by you or iCloud Passwords, never typed by the agent: ask the user to sign in." };
  }
  el.scrollIntoView({ block: "center" });
  el.focus();
  if (el.isContentEditable) {
    el.textContent = text;
  } else {
    const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype
      : (el.tagName === "SELECT" ? HTMLSelectElement.prototype : HTMLInputElement.prototype);
    const setter = Object.getOwnPropertyDescriptor(proto, "value").set;
    setter.call(el, text);
  }
  el.dispatchEvent(new Event("input", { bubbles: true }));
  el.dispatchEvent(new Event("change", { bubbles: true }));
  if (submit) {
    if (el.form && el.form.requestSubmit) el.form.requestSubmit();
    else el.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  }
  return { field: (el.getAttribute("aria-label") || el.placeholder || el.name || el.tagName).slice(0, 60) };
}

function pressKey(key) {
  const target = document.activeElement || document.body;
  for (const type of ["keydown", "keyup"]) {
    target.dispatchEvent(new KeyboardEvent(type, { key, bubbles: true }));
  }
}
