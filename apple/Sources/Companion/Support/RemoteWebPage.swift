import Foundation

extension RemoteServer {
    /// The browser's page (`/web`): the Mac's projects with their folders,
    /// each project's chats, the recent chats, and the open chat with a box
    /// to write to it. One self-contained page; nothing is loaded from
    /// anywhere else. Like the phone's page it reads the pairing code from
    /// the link's `#`, keeps it in the browser under the same name, and
    /// sends it with every request. Opening a chat here opens it on the
    /// Mac, as it does from the phone.
    static let webPage = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Companion</title>
    <meta name="theme-color" content="#0e0f13">
    <link rel="icon" href="/icon.png">
    <style>
      :root { color-scheme:dark; --bg:#0e0f13; --side:#13151a; --card:#1a1c22; --line:#2a2d36;
              --ink:#eef0f5; --dim:#9aa0ad; --accent:#8b7cf6; --me:#232733; }
      * { box-sizing:border-box; }
      [hidden] { display:none !important; }
      html, body { height:100%; }
      body { margin:0; background:var(--bg); color:var(--ink); font:15px/1.5 -apple-system,system-ui,sans-serif; }
      button { font:inherit; color:inherit; border:0; cursor:pointer; }
      button:focus-visible, textarea:focus-visible { outline:2px solid var(--accent); outline-offset:1px; }
      #app { display:flex; height:100%; }
      #side { width:300px; flex:none; background:var(--side); border-right:1px solid var(--line);
              overflow-y:auto; padding:14px 10px 24px; }
      .brand { display:flex; align-items:baseline; gap:8px; padding:0 6px 10px; }
      .brand span { color:var(--dim); font-size:12px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
      h2 { margin:16px 6px 6px; font-size:11px; font-weight:600; color:var(--dim);
           text-transform:uppercase; letter-spacing:.5px; }
      .wide { width:100%; height:38px; border-radius:10px; background:var(--accent); color:#fff; font-weight:600; }
      .phead, .chat { display:block; width:100%; text-align:left; background:none; border-radius:8px; padding:7px 8px; }
      .phead:hover, .chat:hover { background:var(--card); }
      .chat.on { background:var(--me); }
      .t { display:block; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
      .phead .t { font-weight:600; }
      .f { display:block; color:var(--dim); font:11.5px ui-monospace,Menlo,monospace;
           white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
      .d { display:block; color:var(--dim); font-size:11px; }
      .pchats { margin:0 0 6px 10px; padding-left:6px; border-left:1px solid var(--line); }
      .none { color:var(--dim); font-size:12px; padding:6px 8px; }
      #main { flex:1; min-width:0; display:flex; flex-direction:column; }
      header { flex:none; display:flex; align-items:center; gap:10px; padding:12px 18px;
               border-bottom:1px solid var(--line); }
      header b { white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
      #status { margin-left:auto; flex:none; color:var(--dim); font-size:12px; }
      .icon { display:none; background:none; font-size:20px; width:32px; height:32px; }
      #log { flex:1; overflow-y:auto; padding:18px; }
      .turn { display:flex; flex-direction:column; gap:8px; max-width:820px; margin:0 auto 14px; }
      .me { align-self:flex-end; max-width:85%; background:var(--me); padding:9px 13px;
            border-radius:16px 16px 4px 16px; white-space:pre-wrap; overflow-wrap:anywhere; }
      .reply { align-self:flex-start; max-width:100%; white-space:pre-wrap; overflow-wrap:anywhere; }
      .model { color:var(--dim); font-size:11px; margin-bottom:4px; text-transform:uppercase; letter-spacing:.4px; }
      .step { color:var(--dim); font-size:12px; }
      .err { color:#ff8080; }
      .dots::after { content:'…'; animation:blink 1.2s infinite; }
      @keyframes blink { 0%,100% { opacity:.3 } 50% { opacity:1 } }
      .ask { max-width:820px; margin:0 auto 14px; background:var(--card); border:1px solid var(--accent);
             border-radius:12px; padding:10px 13px; }
      .ask .label { color:var(--accent); font-size:11px; text-transform:uppercase; letter-spacing:.4px; margin-bottom:4px; }
      .opts { display:flex; flex-wrap:wrap; gap:8px; margin-top:8px; }
      .opts button { height:34px; padding:0 14px; border-radius:10px; background:var(--me); border:1px solid var(--accent); }
      .note { color:var(--dim); font-size:13px; text-align:center; padding:24px; }
      .shot { max-width:100%; border-radius:10px; border:1px solid var(--line); display:block; }
      .reply pre { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:10px;
                   overflow-x:auto; font:12.5px/1.45 ui-monospace,Menlo,monospace; white-space:pre; margin:6px 0; }
      .reply code { font:13px ui-monospace,Menlo,monospace; background:var(--card); padding:1px 5px; border-radius:5px; }
      footer { flex:none; display:flex; gap:8px; align-items:flex-end; padding:10px 18px 14px;
               border-top:1px solid var(--line); }
      textarea { flex:1; resize:none; background:var(--card); color:var(--ink); border:1px solid var(--line);
                 border-radius:12px; padding:10px 13px; font:inherit; max-height:160px; }
      footer button { height:42px; padding:0 18px; border-radius:12px; background:var(--accent); color:#fff; font-weight:600; }
      footer .stop { background:#e2556a; }
      @media (max-width:760px) {
        .icon { display:block; }
        #side { position:fixed; z-index:5; top:0; bottom:0; left:0; width:min(320px,86%);
                transform:translateX(-100%); transition:transform .15s; }
        #app.menu #side { transform:none; box-shadow:0 0 0 100vmax rgba(0,0,0,.5); }
      }
    </style>
    </head>
    <body>
    <div id="app">
      <aside id="side">
        <div class="brand"><b>Companion</b><span id="mac"></span></div>
        <button class="wide" id="newchat">New chat</button>
        <h2>Projects</h2>
        <div id="projects"><div class="none">Loading…</div></div>
        <h2>Recent chats</h2>
        <div id="recent"></div>
      </aside>
      <section id="main">
        <header><button class="icon" id="menu" aria-label="Projects and chats">&#9776;</button><b id="title">Companion</b><span id="status">connecting…</span></header>
        <div id="log"><div class="note">Waiting for the conversation…</div></div>
        <footer>
          <textarea id="box" rows="1" placeholder="Message"></textarea>
          <button class="stop" id="stop" hidden>Stop</button>
          <button id="send">Send</button>
        </footer>
      </section>
    </div>
    <script>
    (() => {
      const $ = id => document.getElementById(id);
      // The code comes in the link's #; it is kept so the page still knows
      // it when opened without one (the phone's page keeps it the same way).
      let token = location.hash.slice(1);
      try { if(token) localStorage.setItem('companionToken', token); else token = localStorage.getItem('companionToken') || ''; } catch(_){}
      const T = encodeURIComponent(token);
      const app = $('app'), log = $('log'), box = $('box');
      let current = '', projects = [], recent = [], opened = {}, chatsOf = {};
      let turnsById = {}, lastLog = '', lastSide = '', ticking = false;

      function esc(s){
        return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
      }
      // Just enough formatting to read: code blocks, inline code, bold.
      function fmt(s){
        return String(s || '').split('```').map((p, i) => {
          if(i % 2 === 1) return '<pre>' + esc(p.replace(/^[a-zA-Z0-9_+-]*\n/, '')) + '</pre>';
          return esc(p).replace(/`([^`]+)`/g, '<code>$1</code>').replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>');
        }).join('');
      }
      function when(seconds){
        return new Date(seconds * 1000).toLocaleString([], {month:'short', day:'numeric', hour:'numeric', minute:'2-digit'});
      }
      async function getJSON(path){
        const r = await fetch(path + (path.indexOf('?') < 0 ? '?' : '&') + 'token=' + T, {cache:'no-store'});
        if(!r.ok) throw new Error(String(r.status));
        return r.json();
      }
      function post(path, body){ return fetch(path + '?token=' + T, {method:'POST', body: body || ''}); }
      function note(text){ lastLog = ''; log.innerHTML = '<div class="note">' + esc(text) + '</div>'; }

      // The projects and chats on the left.
      function chatRow(c){
        const more = (c.running ? ' · working' : '') + (c.waiting ? ' · waiting for you' : '');
        return '<button class="chat' + (c.id === current ? ' on' : '') + '" data-chat="' + esc(c.id) + '"><span class="t">' +
          esc(c.title || 'New chat') + '</span><span class="d">' + esc(when(c.date) + more) + '</span></button>';
      }
      function renderSide(){
        const p = projects.length ? projects.map(x => {
          const isOpen = !!opened[x.id], list = chatsOf[x.id], n = x.chats || 0;
          let h = '<div class="proj"><button class="phead" data-project="' + esc(x.id) + '" aria-expanded="' + isOpen +
            '" title="' + esc(x.folder || '') + '"><span class="t">' + esc(x.name) + '</span><span class="f">' +
            esc(x.folder || 'No folder') + '</span><span class="d">' + n + (n === 1 ? ' chat' : ' chats') + '</span></button>';
          if(isOpen) h += '<div class="pchats">' + (!list ? '<div class="none">Loading…</div>'
            : list.length ? list.map(chatRow).join('') : '<div class="none">No chats yet</div>') + '</div>';
          return h + '</div>';
        }).join('') : '<div class="none">No projects on this Mac yet.</div>';
        const r = recent.length ? recent.map(chatRow).join('') : '<div class="none">No chats yet</div>';
        if(p + '\n' + r === lastSide) return;
        lastSide = p + '\n' + r;
        $('projects').innerHTML = p;
        $('recent').innerHTML = r;
      }
      async function loadProject(id){
        try { chatsOf[id] = (await getJSON('/project/chats?id=' + encodeURIComponent(id))).chats || []; }
        catch(_){ if(!chatsOf[id]) chatsOf[id] = []; }
      }
      async function loadLists(){
        try { projects = (await getJSON('/projects')).projects || []; } catch(_){}
        try { const c = await getJSON('/chats'); recent = c.chats || []; if(c.current) current = c.current; } catch(_){}
        for(const id of Object.keys(opened)) if(opened[id]) await loadProject(id);
        renderSide();
      }
      $('side').addEventListener('click', async e => {
        const c = e.target.closest('[data-chat]');
        if(c){
          const id = c.getAttribute('data-chat');
          try { await post('/open', id); } catch(_){ $('status').textContent = 'Could not open it. Try again.'; return; }
          current = id; renderSide(); app.classList.remove('menu'); box.focus();
          return;
        }
        const p = e.target.closest('[data-project]');
        if(p){
          const id = p.getAttribute('data-project');
          opened[id] = !opened[id]; renderSide();
          if(opened[id]){ await loadProject(id); renderSide(); }
        }
      });

      // The open chat. Each message from the feed brings only the turns
      // that changed, plus the order they go in.
      function apply(msg){
        if(msg.full) turnsById = {};
        for(const t of msg.changed) turnsById[t.id] = t;
        const state = msg.meta;
        state.turns = msg.order.map(id => turnsById[id]).filter(Boolean);
        const keep = {}; for(const t of state.turns) keep[t.id] = t; turnsById = keep;
        render(state);
      }
      function render(state){
        let toEnd = log.scrollHeight - log.scrollTop - log.clientHeight < 200;
        $('status').textContent = state.status || 'Ready';
        $('title').textContent = state.title || 'New chat';
        $('mac').textContent = state.mac || '';
        document.title = state.title ? 'Companion - ' + state.title : 'Companion';
        $('stop').hidden = !(state.agentRunning || state.replying);
        if(state.chat && state.chat !== current){ current = state.chat; toEnd = true; loadLists(); }
        let html = '';
        for(const t of state.turns){
          html += '<div class="turn">';
          if(t.image) html += '<img class="shot" loading="lazy" alt="Screen capture" src="/image?token=' + T + '&amp;id=' + esc(t.id) + '">';
          if(t.me) html += '<div class="me">' + esc(t.me) + '</div>';
          if(t.error) html += '<div class="reply err">' + esc(t.error) + '</div>';
          else html += '<div class="reply"><div class="model">' + esc(t.model || '') + '</div>' + fmt(t.reply) +
            (t.streaming ? '<span class="dots"></span>' : '') + '</div>';
          const step = t.steps && t.steps.length ? t.steps[t.steps.length - 1] : null;
          if(step && !t.error && (t.streaming || !t.reply)) html += '<div class="step">' + esc(step.title) + '</div>';
          html += '</div>';
        }
        if(state.question){
          html += '<div class="ask"><div class="label">It is asking</div>' + esc(state.question);
          if(state.options && state.options.length){
            html += '<div class="opts">' + state.options.map(o => '<button data-say="' + esc(o) + '">' + esc(o) + '</button>').join('') + '</div>';
          }
          html += '</div>';
        }
        if(state.awaitingApproval) html += '<div class="ask"><div class="label">Waiting on the Mac</div>Approve what the agent wants to do on the Mac itself.</div>';
        html = html || '<div class="note">No messages yet. Write one below.</div>';
        if(html !== lastLog){ lastLog = html; log.innerHTML = html; }
        if(toEnd) log.scrollTop = log.scrollHeight;
      }

      async function send(){
        const text = box.value.trim();
        if(!text) return;
        box.value = ''; box.style.height = 'auto';
        log.scrollTop = log.scrollHeight;
        try { const r = await post('/say', text); if(!r.ok) throw new Error(String(r.status)); }
        catch(_){ box.value = text; $('status').textContent = 'Not sent. Try again.'; }
      }
      // Clicking one of the agent's offered answers sends it.
      log.addEventListener('click', e => {
        const b = e.target.closest('button[data-say]');
        if(b) post('/say', b.getAttribute('data-say'));
      });
      $('send').onclick = send;
      $('stop').onclick = () => post('/stop');
      $('newchat').onclick = async () => { await post('/new'); app.classList.remove('menu'); box.focus(); };
      $('menu').onclick = e => { e.stopPropagation(); app.classList.toggle('menu'); };
      $('main').addEventListener('click', () => app.classList.remove('menu'));
      box.addEventListener('input', () => { box.style.height = 'auto'; box.style.height = Math.min(box.scrollHeight, 160) + 'px'; });
      box.addEventListener('keydown', e => {
        if(e.key === 'Enter' && !e.shiftKey && !e.isComposing){ e.preventDefault(); send(); }
      });

      function connect(){
        const source = new EventSource('/events?token=' + T);
        source.onmessage = e => { try { apply(JSON.parse(e.data)); } catch(_){} };
        source.onerror = () => {
          $('status').textContent = 'reconnecting…';
          // Closed for good (the browser gave up): start over, which also
          // finds out whether the Mac still takes the code.
          if(source.readyState === 2) setTimeout(start, 4000);
        };
      }
      async function start(){
        let r;
        try { r = await fetch('/state?token=' + T, {cache:'no-store'}); }
        catch(_){ $('status').textContent = 'Can’t reach the Mac. Trying again…'; setTimeout(start, 4000); return; }
        if(r.status === 401){
          $('status').textContent = 'Not paired';
          note('This Mac did not take the pairing code. Open the link from Companion > Settings > Remote again, with /web before the #.');
          return;
        }
        try { apply(await r.json()); } catch(_){}
        connect();
        if(!ticking){ ticking = true; loadLists(); setInterval(loadLists, 8000); }
      }

      if(!token){
        $('status').textContent = 'Not paired';
        $('projects').innerHTML = '';
        note('This link is missing its pairing code. Open the link from Companion > Settings > Remote, with /web before the #.');
      } else start();
    })();
    </script>
    </body>
    </html>
    """#
}