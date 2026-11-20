import Foundation

extension RemoteServer {
    /// The glasses' page (`/glass`, or `/web?glass=1`): made for a display
    /// of about 600 by 600 with no pointer. One column on black, the latest
    /// reply in large text, and a short picker for chats and projects.
    /// Everything that can be chosen takes focus: the arrow keys (a D-pad)
    /// go to the next or the previous one, Enter chooses, Escape goes back
    /// to the reply. It follows the same feed as the phone, so it is kept
    /// up to date without asking again and again, and the feed is closed
    /// while the page is hidden. Same pairing code as the other pages.
    static let glassPage = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
    <meta name="mrbd-web-app-capable" content="yes">
    <meta name="description" content="The latest reply from Companion on your Mac, with a short picker for projects and chats.">
    <title>Companion Glass</title>
    <style>
      * { box-sizing:border-box; }
      html, body { width:100%; height:100%; margin:0; background:#000; color:#fff; }
      body { display:flex; align-items:center; justify-content:center; overflow:hidden;
             font:600 28px/1.3 -apple-system,system-ui,sans-serif; }
      #g { width:100%; height:100%; max-width:600px; max-height:600px; display:flex;
           flex-direction:column; gap:10px; padding:16px; }
      #head { flex:none; display:flex; gap:12px; align-items:baseline; font-size:20px; color:#c8ccd6; }
      #title { flex:1; min-width:0; color:#fff; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
      #status { flex:none; max-width:50%; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
      #view { flex:1; min-height:0; display:flex; flex-direction:column; gap:10px; overflow-y:auto; }
      .reply { flex:1 1 auto; min-height:150px; overflow-y:auto; white-space:pre-wrap; overflow-wrap:anywhere;
               border:3px solid transparent; border-radius:16px; padding:6px 10px; outline:none; }
      .reply:focus { border-color:#fff; }
      .ask { flex:none; font-size:24px; color:#ffd866; }
      .hint { flex:none; font-size:22px; color:#c8ccd6; }
      .row { flex:none; display:flex; flex-wrap:wrap; gap:10px; }
      button { flex:none; width:100%; min-width:0; min-height:64px; padding:8px 18px; font:inherit; font-size:26px;
               color:#fff; background:#16181d; border:3px solid #6b7280; border-radius:16px;
               text-align:left; cursor:pointer; outline:none; }
      .row button { flex:1 1 auto; width:auto; max-width:100%; text-align:center; }
      button .l, button small { display:block; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
      button small { font-size:18px; font-weight:500; color:#c8ccd6; }
      button.on { border-color:#8b7cf6; }
      button.stop { border-color:#ff6b7d; }
      button:focus { background:#fff; color:#000; border-color:#fff; }
      button:focus small { color:#222; }
    </style>
    </head>
    <body>
    <main id="g">
      <div id="head"><span id="title">Companion</span><span id="status"></span></div>
      <div id="view"></div>
    </main>
    <script>
    (() => {
      const $ = id => document.getElementById(id);
      // The code comes in the link's #; it is kept so the page still knows
      // it when opened without one.
      let token = location.hash.slice(1);
      try { if(token) localStorage.setItem('companionToken', token); else token = localStorage.getItem('companionToken') || ''; } catch(_){}
      const T = encodeURIComponent(token);
      const view = $('view');
      // What is showing: the reply, the chats, the projects, or one project.
      let page = 'reply', state = null, note = '', unpaired = false, source = null;
      let chats = [], projects = [], projChats = [], projName = '';
      let turnsById = {}, lastHTML = '', want = '', shown = '';

      function esc(s){
        return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
      }
      async function getJSON(path){
        const r = await fetch(path + (path.indexOf('?') < 0 ? '?' : '&') + 'token=' + T, {cache:'no-store'});
        if(!r.ok) throw new Error(String(r.status));
        return r.json();
      }
      async function post(path, body){
        const r = await fetch(path + '?token=' + T, {method:'POST', body: body || ''});
        if(!r.ok) throw new Error(String(r.status));
      }
      // The end of a folder's path: all a small display has room for.
      function tail(folder){ return String(folder || '').split('/').filter(Boolean).slice(-2).join('/'); }
      function btn(key, act, arg, label, sub, cls){
        return '<button data-k="' + key + '" data-act="' + act + '" data-arg="' + esc(arg) + '"' + (cls ? ' class="' + cls + '"' : '') +
          '><span class="l">' + esc(label) + '</span>' + (sub ? '<small>' + esc(sub) + '</small>' : '') + '</button>';
      }
      function latest(){ const t = state && state.turns; return t && t.length ? t[t.length - 1] : null; }

      function replyView(){
        if(!state) return '<div class="reply" id="reply" tabindex="0" data-k="reply">' + esc(note || 'Connecting…') + '</div>';
        const t = latest(), busy = state.agentRunning || state.replying;
        let text;
        if(!t) text = 'No messages yet.';
        else if(t.error) text = t.error;
        else if(t.reply) text = t.reply + (t.streaming ? ' …' : '');
        else text = (state.agentStatus || state.status || 'Working') + ' …';
        if(text.length > 4000) text = text.slice(0, 4000) + ' …';
        let h = '<div class="reply" id="reply" tabindex="0" data-k="reply">' + esc(text) + '</div>';
        if(state.question) h += '<div class="ask">' + esc(state.question) + '</div>';
        if(state.awaitingApproval) h += '<div class="ask">Waiting for approval on the Mac.</div>';
        h += '<div class="row">';
        if(state.question) (state.options || []).slice(0, 4).forEach((o, i) => { h += btn('o' + i, 'say', o, o); });
        if(busy) h += btn('stop', 'stop', '', 'Stop', '', 'stop');
        return h + btn('chats', 'chats', '', 'Chats') + btn('projects', 'projects', '', 'Projects') + '</div>';
      }
      function chatButtons(list){
        if(!list.length) return '<div class="hint">No chats yet.</div>';
        return list.slice(0, 8).map((c, i) => btn('i' + i, 'open', c.id, c.title || 'New chat',
          c.waiting ? 'Waiting for you' : c.running ? 'Working' : '', state && c.id === state.chat ? 'on' : '')).join('');
      }
      function listView(){
        let h = btn('back', 'reply', '', 'Latest reply');
        if(page === 'chats') h += chatButtons(chats);
        else if(page === 'project') h += chatButtons(projChats);
        else if(!projects.length) h += '<div class="hint">No projects yet.</div>';
        else h += projects.slice(0, 8).map((p, i) => btn('i' + i, 'project', p.id, p.name, tail(p.folder) || 'No folder')).join('');
        return h;
      }

      // Draws what is showing, only when it changed, and keeps the focus
      // where it was (or puts it where `want` says).
      function draw(){
        $('title').textContent = page === 'reply' ? ((state && state.title) || 'Companion')
          : page === 'chats' ? 'Chats' : page === 'projects' ? 'Projects' : (projName || 'Project');
        $('status').textContent = state ? (note || state.status || 'Ready') : '';
        const html = page === 'reply' ? replyView() : listView();
        if(html === lastHTML && !want) return;
        const active = document.activeElement;
        const key = want || (active && active.getAttribute && active.getAttribute('data-k')) || '';
        const old = $('reply'), top = old ? old.scrollTop : 0;
        if(html !== lastHTML){ view.innerHTML = html; lastHTML = html; }
        // The same reply keeps its place; a new one starts at its top.
        const t = latest(), id = page + ':' + (t ? t.id : '');
        const now = $('reply');
        if(now) now.scrollTop = id === shown ? top : 0;
        shown = id; want = '';
        const el = (key && view.querySelector('[data-k="' + key + '"]')) || view.querySelector('[data-k]');
        if(el && el !== document.activeElement) el.focus();
      }
      function go(next){ page = next; want = next === 'reply' ? 'reply' : 'i0'; draw(); }

      view.addEventListener('click', async e => {
        const b = e.target.closest('button[data-act]');
        if(!b) return;
        const act = b.getAttribute('data-act'), arg = b.getAttribute('data-arg') || '';
        try {
          if(act === 'say') await post('/say', arg);
          else if(act === 'stop') await post('/stop');
          else if(act === 'reply') go('reply');
          else if(act === 'chats'){ chats = (await getJSON('/chats')).chats || []; go('chats'); }
          else if(act === 'projects'){ projects = (await getJSON('/projects')).projects || []; go('projects'); }
          else if(act === 'project'){
            const d = await getJSON('/project/chats?id=' + encodeURIComponent(arg));
            projName = d.name || ''; projChats = d.chats || []; go('project');
          }
          else if(act === 'open'){ await post('/open', arg); go('reply'); }
        } catch(_){ note = 'That did not go through.'; draw(); }
      });

      // Next and previous with the arrows, in the order on screen; Enter
      // chooses (a button does that by itself). On the reply, up and down
      // scroll it first and move on once it has no more to show.
      document.addEventListener('keydown', e => {
        const k = e.key;
        if(k === 'Escape'){
          if(page !== 'reply'){ e.preventDefault(); go('reply'); }
          return;
        }
        if(k !== 'ArrowDown' && k !== 'ArrowUp' && k !== 'ArrowRight' && k !== 'ArrowLeft') return;
        e.preventDefault();
        const forward = k === 'ArrowDown' || k === 'ArrowRight';
        const el = document.activeElement;
        if(el && el.id === 'reply' && (k === 'ArrowDown' || k === 'ArrowUp')){
          const before = el.scrollTop;
          el.scrollTop += forward ? 140 : -140;
          if(el.scrollTop !== before) return;
        }
        const items = Array.from(view.querySelectorAll('[data-k]'));
        if(!items.length) return;
        const i = items.indexOf(el);
        const j = i < 0 ? 0 : Math.min(items.length - 1, Math.max(0, i + (forward ? 1 : -1)));
        items[j].focus();
        items[j].scrollIntoView({block:'nearest'});
      });

      // The feed: the whole chat first, then only the turns that changed.
      function apply(msg){
        if(msg.full) turnsById = {};
        for(const t of msg.changed) turnsById[t.id] = t;
        const s = msg.meta;
        s.turns = msg.order.map(id => turnsById[id]).filter(Boolean);
        const keep = {}; for(const t of s.turns) keep[t.id] = t; turnsById = keep;
        state = s; note = '';
        draw();
      }
      function connect(){
        if(source) source.close();
        source = new EventSource('/events?token=' + T);
        source.onmessage = e => { try { apply(JSON.parse(e.data)); } catch(_){} };
        source.onerror = () => { note = 'Reconnecting…'; draw(); check(); };
      }
      // A dropped connection comes back by itself; a code the Mac no longer
      // takes does not, and is said so.
      async function check(){
        try {
          const r = await fetch('/info?token=' + T, {cache:'no-store'});
          if(r.status === 401){
            unpaired = true;
            if(source){ source.close(); source = null; }
            state = null; note = 'Pair again: open the link from Companion > Settings > Remote, with /glass before the #.';
            page = 'reply'; draw();
          }
        } catch(_){}
      }
      // Nothing is kept open while the page is hidden.
      document.addEventListener('visibilitychange', () => {
        if(document.hidden){ if(source){ source.close(); source = null; } }
        else if(token && !unpaired) connect();
      });
      setInterval(() => {
        if(!document.hidden && token && !unpaired && (!source || source.readyState === 2)) connect();
      }, 15000);

      if(!token){ note = 'No pairing code. Open the link from Companion > Settings > Remote, with /glass before the #.'; draw(); }
      else { draw(); connect(); }
    })();
    </script>
    </body>
    </html>
    """#
}