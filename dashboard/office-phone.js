/* The Office phone: a pixel-art cell phone in the bottom-left corner of the room that opens your
 * chat with the boss at the front desk (server/office_boss.py) and commands every agent from one place.
 *
 * mountOfficePhone(rootEl, { fetchJson, sendLine, agents }) pins the icon to rootEl's (the Office
 * stage's) bottom-left corner as a fixed element on <body>, so no room, garden, house, walk or zoom
 * inside the stage can cover or hide it; the phone panel is on <body> too. P opens it (not while
 * typing); Esc closes it before anything else in the Office handles Esc.
 * Returns { open, close, toggle, state, refresh, destroy }.
 *   fetchJson(url, { method, body }) resolves to the parsed JSON, or an object with `error` on failure.
 *   sendLine(id, text) posts one line to an agent; default POST /api/office/send { id, text }.
 *   agents() returns the /api/office/agents list (sync or async); default GET /api/office/agents.
 * The thread is the boss session's own chat (GET /api/office/chat?id=<boss>), not a second store.
 * A line that starts with an agent's name or @Name goes straight to that agent;
 * everything else goes to the boss. Mounting only reads: nothing is sent until you press Send. */
(function () {
  'use strict';
  // Same set as the Office (dashboard/office.js: BUSY).
  const BUSY = new Set(['typing', 'writing', 'reading', 'browsing', 'looking', 'delegating', 'thinking', 'working', 'helpers']);
  const BOSS = /^(the )?boss$/i;
  const AGENTS_MS = 4000, CHAT_MS = 2000, LOCAL_TTL = 180000;
  let mounted = 0;

  async function defaultFetchJson(url, opts = {}) {
    const ctl = new AbortController(), timer = setTimeout(() => ctl.abort(), opts.method === 'POST' ? 20000 : 6000);
    const init = { method: opts.method || 'GET', headers: { Accept: 'application/json' }, credentials: 'same-origin', cache: 'no-store', signal: ctl.signal };
    if (opts.body !== undefined) { init.headers['Content-Type'] = 'application/json'; init.body = JSON.stringify(opts.body); }
    try {
      const res = await fetch(url, init);
      let data = {};
      try { data = await res.json(); } catch (e) { data = {}; }
      if (!res.ok) return Object.assign({}, data, { error: data.error || 'The dashboard said ' + res.status + '.' });
      return data;
    } catch (e) {
      return { error: e.name === 'AbortError' ? 'iTerm did not answer. Check the front desk.' : 'The dashboard server is not answering.' };
    } finally { clearTimeout(timer); }
  }

  // ── Who a line is for. The agent name rule:
  // an optional "hey/hi/ok", then the first two words, else the first word, fuzzily matching an
  // agent's name (long names forgive two letters, 4-5 letter names one, shorter must be exact);
  // the boss by "boss" or "the boss". Typed lines may also start with @Name. ──
  const norm = s => String(s || '').toLowerCase().replace(/[’']/g, '').replace(/[^a-z0-9]+/g, ' ').trim();
  const squash = s => norm(s).replace(/ /g, '');
  function dist(a, b) {
    let row = Array.from({ length: b.length + 1 }, (_, j) => j);
    for (let i = 1; i <= a.length; i++) {
      const next = [i];
      for (let j = 1; j <= b.length; j++) next[j] = Math.min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
      row = next;
    }
    return row[b.length];
  }
  const near = (said, name) => { const a = squash(said), b = squash(name); if (!a || !b) return false; if (a === b) return true; const d = dist(a, b); return b.length >= 6 ? d <= 2 : b.length >= 4 && d <= 1; };
  // Returns { to: 'boss' | agentId, name, text }. text is what goes out (the name stripped off);
  // an empty text means the line only named someone.
  function route(line, agents) {
    const raw = String(line || '').trim();
    if (!raw) return { to: 'boss', name: 'Boss', text: '' };
    const toks = raw.split(/\s+/);
    const word = t => t.replace(/[“”"]/g, '').replace(/^@/, '').replace(/[,:;.!?]+$/, '');
    const people = (agents || []).filter(a => a && a.name && !a.boss).map(a => ({ id: a.id, name: a.name }));
    const person = said => BOSS.test(norm(said)) ? { id: 'boss', name: 'Boss' } : people.find(p => near(said, p.name)) || null;
    const start = toks.length > 1 && /^(hey|hi|okay|ok)$/i.test(word(toks[0])) ? 1 : 0;
    for (const n of [2, 1]) {
      if (toks.length - start < n) continue;
      const who = person(toks.slice(start, start + n).map(word).join(' '));
      if (!who) continue;
      return { to: who.id, name: who.name, text: toks.slice(start + n).join(' ').trim() };
    }
    return { to: 'boss', name: 'Boss', text: raw };
  }

  const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
  // The boss writes light Markdown: keep bold, code and line breaks, drop the rest of the markup.
  const prose = s => esc(s).replace(/\*\*([^*\n]+)\*\*/g, '<b>$1</b>').replace(/`([^`\n]+)`/g, '<code>$1</code>').replace(/^#{1,6} /gm, '').replace(/\n/g, '<br>');
  const sig = t => t ? t.kind + '|' + String(t.text || '').slice(0, 160) : '';
  const same = (a, b) => norm(a).slice(0, 120) === norm(b).slice(0, 120);
  const dotOf = a => a.activity === 'your_turn' ? 'you' : (BUSY.has(a.activity) || a.working) ? 'busy' : a.activity === 'asleep' ? 'sleep' : 'rest';
  const PALETTE = ['#f8d030', '#f08030', '#6890f0', '#78c850', '#f85888', '#a890f0', '#e0c068', '#98d8d8', '#c03028', '#705898'];
  const colorOf = a => a.color || (a.boss ? '#d9a441' : PALETTE[[...String(a.name || a.id)].reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7) % PALETTE.length]);
  const clock = () => new Date().toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' }).replace(/\s?[AP]M$/i, '');

  // The icon: a 12 x 20 pixel handset (antenna, screen with two chat bubbles, keypad).
  const ICON = `
<svg class="op-handset" viewBox="0 0 12 20" shape-rendering="crispEdges" aria-hidden="true">
  <path fill="#202030" d="M8 0h2v3h-2zM2 3h8v1h1v15h-1v1h-8v-1h-1v-15h1z"/>
  <path fill="#3b4270" d="M2 4h8v15h-8z"/>
  <path fill="#5a64a8" d="M2 4h8v1h-8z"/>
  <path fill="#0f1830" d="M3 6h6v6h-6z"/>
  <path class="op-glow" fill="#7fd8ff" d="M3 6h6v6h-6z"/>
  <path fill="#ffffff" d="M4 7h3v1h-3z"/>
  <path fill="#ffcb05" d="M5 9h3v1h-3z"/>
  <path fill="#c8cee8" d="M3 13h2v1h-2zM5 13h2v1h-2zM7 13h2v1h-2zM3 15h2v1h-2zM5 15h2v1h-2zM7 15h2v1h-2zM3 17h2v1h-2zM7 17h2v1h-2z"/>
  <path fill="#ffcb05" d="M5 17h2v1h-2z"/>
</svg>`;

  function mountOfficePhone(rootEl, options = {}) {
    if (!rootEl) return null;
    const fetchJson = options.fetchJson || defaultFetchJson;
    const sendLine = options.sendLine || ((id, text) => fetchJson('/api/office/send', { method: 'POST', body: { id, text } }));
    const listAgents = options.agents || (async () => { const d = await fetchJson('/api/office/agents', { method: 'GET' }); if (d && d.error) throw new Error(d.error); return (d && d.agents) || []; });
    const uid = 'op' + (++mounted);
    const reduce = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : { matches: false };

    // The icon and the panel both live on <body>; the icon is pinned to the stage's bottom-left corner.
    const corner = document.createElement('div');
    corner.className = 'op-root';
    corner.innerHTML = `<button type="button" class="op-icon" aria-haspopup="dialog" aria-expanded="false" aria-controls="${uid}-panel" title="Phone: talk to the boss and command every agent">${ICON}<b class="op-badge" hidden></b><span class="op-tip">Phone</span></button>`;
    document.body.appendChild(corner);
    const icon = corner.querySelector('.op-icon'), badge = corner.querySelector('.op-badge');
    // Pin: the stage's bottom-left corner, kept inside the window when the stage runs past its bottom.
    // Gone only while the stage itself is not on screen (another tab).
    let pinKey = '';
    function pin() {
      const shown = !!rootEl.getClientRects().length && !document.hidden;
      const sr = shown ? rootEl.getBoundingClientRect() : null, inset = window.innerWidth < 600 ? 8 : 14;
      const k = sr ? [Math.round(Math.max(0, sr.left)), Math.round(Math.max(0, window.innerHeight - Math.min(sr.bottom, window.innerHeight))), inset].join() : 'off';
      if (k === pinKey) return;
      pinKey = k;
      corner.classList.toggle('op-off', !sr);
      if (sr) { const [l, b] = k.split(',').map(Number); corner.style.left = (l + inset) + 'px'; corner.style.bottom = (b + inset) + 'px'; }
    }
    pin();

    const panel = document.createElement('section');
    panel.className = 'op-panel';
    panel.id = uid + '-panel';
    panel.hidden = true;
    panel.setAttribute('role', 'dialog');
    panel.setAttribute('aria-label', 'Phone: chat with the boss');
    panel.innerHTML = `
      <div class="op-bezel">
        <div class="op-status"><span class="op-time"></span><i class="op-notch" aria-hidden="true"></i><span class="op-signal" aria-hidden="true"><i></i><i></i><i></i><i></i><em></em></span></div>
        <header class="op-head">
          <span class="op-face" aria-hidden="true">B</span>
          <div class="op-who"><h3>Boss</h3><p class="op-state"><i></i><span>Front desk</span></p></div>
          <button type="button" class="op-close" aria-label="Close the phone (Esc)">✕</button>
        </header>
        <nav class="op-contacts" aria-label="Agents: tap one to message it"></nav>
        <div class="op-thread" tabindex="0" aria-live="polite" aria-label="Messages"></div>
        <form class="op-compose" autocomplete="off">
          <textarea class="op-input" rows="1" maxlength="2000" spellcheck="true" placeholder="Message the boss" aria-label="Message" enterkeyhint="send"></textarea>
          <button type="submit" class="op-send" aria-label="Send">Send</button>
        </form>
        <p class="op-to" aria-live="polite"></p>
      </div>`;
    document.body.appendChild(panel);
    const $ = s => panel.querySelector(s);
    const thread = $('.op-thread'), input = $('.op-input'), sendBtn = $('.op-send'), contacts = $('.op-contacts'), toLine = $('.op-to');

    let agents = [], boss = null, turns = [], local = [], open = false, unread = 0, seenSaid = null, bossMsgs = null;
    let agentsTimer = null, chatTimer = null, clockTimer = null, watchTimer = null, chatBusy = false, agentsBusy = false, sending = false, dead = false, lastHtml = '', lastContacts = '';

    // ── Data: the same /api/agents list the Office polls; the boss is the one marked boss: true. ──
    async function readAgents() {
      if (agentsBusy || dead) return;
      agentsBusy = true;
      try {
        const list = await listAgents();
        if (!Array.isArray(list)) return;
        boss = list.find(a => a && a.boss) || null;
        agents = list.filter(a => a && !a.boss && a.name);
        paintHead(); paintContacts(); paintTo();
        const msgs = boss ? boss.messages : null;
        if (!open && boss && boss.tty && msgs !== bossMsgs && !boss.working) readChat();
        bossMsgs = msgs;
      } catch (e) { /* the next tick retries */ } finally { agentsBusy = false; }
    }
    async function readChat() {
      if (chatBusy || dead || !boss || !boss.tty) return;
      chatBusy = true;
      const id = boss.id;
      try {
        const body = await fetchJson('/api/office/chat?id=' + encodeURIComponent(id), { method: 'GET' });
        if (!body || body.error || !Array.isArray(body.turns) || !boss || boss.id !== id) return;
        turns = body.turns.filter(t => t.kind === 'you' || t.kind === 'said' || (t.kind === 'ask' && t.open));
        countUnread();
        paintThread();
      } finally { chatBusy = false; }
    }
    // The boss's replies that arrived since you last looked. The first read only sets the mark.
    function countUnread() {
      const said = turns.filter(t => t.kind !== 'you');
      const last = said.length ? sig(said[said.length - 1]) : '';
      if (open || seenSaid === null) { seenSaid = last; unread = 0; }
      else if (last !== seenSaid) {
        const at = said.map(sig).lastIndexOf(seenSaid);
        unread = at < 0 ? said.length : said.length - 1 - at;
      }
      badge.hidden = !unread;
      badge.textContent = unread > 9 ? '9+' : String(unread || '');
      corner.classList.toggle('op-ringing', !!unread);
      icon.setAttribute('aria-label', unread ? `Phone: ${unread} new from the boss` : 'Phone: talk to the boss and command every agent');
    }

    // ── Painting ──
    function paintHead() {
      const st = $('.op-state');
      if (!boss || !boss.tty) { st.className = 'op-state away'; st.querySelector('span').textContent = 'Not at the front desk yet'; return; }
      const d = dotOf(boss);
      st.className = 'op-state ' + d;
      st.querySelector('span').textContent = boss.working ? 'Working' : d === 'you' ? 'Waiting on you' : 'At the front desk';
    }
    function paintContacts() {
      const people = [{ id: 'boss', name: 'Boss', boss: true, activity: boss ? boss.activity : 'asleep', working: boss && boss.working }].concat(agents);
      const html = people.map(a => `<button type="button" class="op-contact" data-name="${esc(a.name)}" data-id="${esc(a.id)}" title="${a.boss ? 'Message the boss' : 'Message ' + esc(a.name) + ' directly'}" style="--op-c:${esc(colorOf(a))}"><i class="op-dot ${dotOf(a)}" aria-hidden="true"></i><span>${esc(a.name)}</span></button>`).join('');
      if (html === lastContacts) return;
      lastContacts = html; contacts.innerHTML = html;
    }
    function paintTo() {
      const r = route(input.value, agents);
      const to = r.to === 'boss' ? 'Boss' : r.name;
      toLine.className = 'op-to' + (r.to === 'boss' ? '' : ' routed');
      toLine.textContent = !input.value.trim() ? 'Start with a name: straight to that agent' : (r.text ? 'To ' + to : `Add what ${to} should do`);
    }
    // Boss turns in order, with the phone's own lines (routed ones and boss lines not yet in its chat)
    // placed after the turn that was last when they were sent.
    function items() {
      const now = Date.now();
      local = local.filter(l => l.routed || now - l.at < LOCAL_TTL);
      // A boss line is in its chat now: drop the local copy.
      local = local.filter(l => {
        if (l.routed || l.failed) return true;
        const from = l.anchor ? turns.map(sig).lastIndexOf(l.anchor) + 1 : 0;
        return !turns.slice(from).some(t => t.kind === 'you' && same(t.text, l.text));
      });
      const out = turns.map(t => ({ turn: t }));
      local.forEach(l => {
        const at = l.anchor ? out.map(x => x.turn ? sig(x.turn) : null).lastIndexOf(l.anchor) : -1;
        let i = at + 1;
        while (i < out.length && out[i].local) i++;
        out.splice(at < 0 && l.anchor ? 0 : i, 0, { local: l });
      });
      return out;
    }
    function paintThread() {
      const list = items();
      let html = list.map(x => {
        if (x.turn) {
          const t = x.turn;
          if (t.kind === 'you') return `<div class="op-msg me"><p>${prose(t.text)}</p></div>`;
          if (t.kind === 'ask') return `<div class="op-msg them ask"><p>${(t.questions || []).map(q => esc(q.question || q.text || '')).join('<br>')}</p><small>Answer it at the front desk console.</small></div>`;
          return `<div class="op-msg them"><p>${prose(t.text)}</p></div>`;
        }
        const l = x.local;
        return `<div class="op-msg me${l.routed ? ' routed' : ''}${l.failed ? ' failed' : ''}">${l.routed ? `<b class="op-tag">to ${esc(l.name)}</b>` : ''}<p>${esc(l.text)}</p><small class="op-receipt">${esc(l.receipt || '')}</small></div>`;
      }).join('');
      if (!list.length) html = `<p class="op-empty">${boss && boss.tty ? 'Reading the front desk chat…' : 'The boss is not at the front desk. Your first line sits it down.'}</p>`;
      if (html === lastHtml) return;
      const pinned = thread.scrollHeight - thread.scrollTop - thread.clientHeight < 40 || !lastHtml;
      lastHtml = html; thread.innerHTML = html;
      if (pinned) thread.scrollTop = thread.scrollHeight;
    }

    // ── Sending ──
    async function send() {
      const text = input.value.trim();
      if (!text || sending) return;
      const r = route(text, agents);
      if (!r.text) { paintTo(); input.focus(); return; }
      const anchorTurn = turns[turns.length - 1];
      const item = { text: r.text, at: Date.now(), anchor: sig(anchorTurn), routed: r.to !== 'boss', name: r.name, receipt: 'Sending…' };
      local.push(item);
      input.value = ''; grow(); paintTo(); lastHtml = ''; thread.scrollTop = thread.scrollHeight; paintThread();
      sending = true; sendBtn.disabled = true;
      let out;
      try {
        if (r.to !== 'boss') out = await sendLine(r.to, r.text);
        else if (boss && boss.tty) out = await sendLine(boss.id, r.text);
        else out = await fetchJson('/api/office/boss', { method: 'POST', body: { text: r.text } });
      } catch (e) { out = { error: e && e.message || 'Not sent.' }; }
      if (!out || out.error) {
        item.failed = true; item.receipt = 'Not sent: ' + ((out && out.error) || 'no answer.');
        if (!input.value) { input.value = text; grow(); paintTo(); }
      } else if (r.to !== 'boss') item.receipt = (out.queued ? 'Queued for ' : 'Sent to ') + r.name;
      else if (!(boss && boss.tty)) item.receipt = out.started ? 'The boss is sitting down at the front desk' : 'Sent to the boss';
      else item.receipt = out.queued ? 'Queued: the boss reads it when this turn ends' : 'Sent';
      lastHtml = ''; paintThread();
      setTimeout(() => { sending = false; sendBtn.disabled = false; }, 600);
      setTimeout(readAgents, 1200); setTimeout(readChat, 1500);
    }
    const grow = () => { input.style.height = 'auto'; const h = Math.min(input.scrollHeight + 2, 120); input.style.height = h + 'px'; input.style.overflowY = input.scrollHeight + 2 > 120 ? 'auto' : 'hidden'; };

    // ── Placement: above the icon if it fits, else beside it inside the room, then shrink (floor 300).
    // Never above the room's top edge, so the Office toolbar stays reachable. Phones: CSS, full width. ──
    function place() {
      if (!open) return;
      if (window.innerWidth < 600) { panel.style.left = panel.style.top = panel.style.width = panel.style.height = ''; return; }
      const ir = icon.getBoundingClientRect(), sr = rootEl.getBoundingClientRect();
      const W = 340, H = 580, gap = 10, minTop = Math.max(8, sr.top + 8);
      const floor = Math.min(window.innerHeight - 8, sr.bottom - 8);
      let left = ir.left, top = ir.top - gap - H, h = H;
      if (top < minTop) { left = ir.right + gap; top = Math.min(floor, ir.bottom) - H; }
      if (top < minTop) { top = minTop; h = Math.max(300, Math.min(floor, ir.bottom) - minTop); }
      left = Math.max(8, Math.min(left, window.innerWidth - W - 8));
      Object.assign(panel.style, { left: left + 'px', top: top + 'px', width: W + 'px', height: h + 'px' });
    }

    // Reachable everywhere: only a hidden stage (another tab) puts the open phone away.
    const mirror = () => { panel.classList.toggle('op-away', !rootEl.getClientRects().length); pin(); };
    const observer = window.ResizeObserver ? new ResizeObserver(() => pin()) : null;
    if (observer) observer.observe(rootEl);
    // The stage can move without resizing (a banner above it, the page scrolling): follow it every frame
    // while it is shown, and check four times a second while it is not.
    let pinFrame = 0;
    const pinLoop = () => { pin(); pinFrame = rootEl.getClientRects().length && !document.hidden ? requestAnimationFrame(pinLoop) : 0; };
    const pinTimer = setInterval(() => { if (!pinFrame) pinLoop(); }, 400);
    pinLoop();

    function openPhone() {
      if (open || dead) return;
      open = true;
      panel.hidden = false;
      icon.setAttribute('aria-expanded', 'true');
      corner.classList.add('op-open');
      mirror(); place();
      $('.op-time').textContent = clock();
      clockTimer = setInterval(() => { $('.op-time').textContent = clock(); }, 15000);
      watchTimer = setInterval(() => { mirror(); place(); }, 500);
      requestAnimationFrame(() => panel.classList.add('op-shown'));
      lastHtml = ''; paintThread(); paintContacts(); paintTo();
      seenSaid = null; countUnread();
      readChat(); readAgents();
      chatTimer = setInterval(readChat, CHAT_MS);
      input.focus({ preventScroll: true });
    }
    function closePhone(refocus) {
      if (!open) return;
      open = false;
      clearInterval(chatTimer); clearInterval(clockTimer); clearInterval(watchTimer);
      panel.classList.remove('op-shown');
      icon.setAttribute('aria-expanded', 'false');
      corner.classList.remove('op-open');
      const done = () => { if (!open) panel.hidden = true; };
      if (reduce.matches) done(); else setTimeout(done, 180);
      if (refocus !== false) icon.focus({ preventScroll: true });
    }

    // ── Events ──
    const swallow = e => e.stopPropagation();
    ['pointerdown', 'mousedown', 'click', 'dblclick'].forEach(t => corner.addEventListener(t, swallow));
    icon.addEventListener('click', () => (open ? closePhone() : openPhone()));
    panel.addEventListener('click', e => {
      if (e.target.closest('.op-close')) { closePhone(); return; }
      const c = e.target.closest('.op-contact');
      if (c) {
        const rest = route(input.value, agents);
        const body = rest.to === 'boss' && rest.text === input.value.trim() ? input.value.trim() : rest.text;
        input.value = c.dataset.id === 'boss' ? body : c.dataset.name + ', ' + body;
        grow(); paintTo(); input.focus(); input.setSelectionRange(input.value.length, input.value.length);
      }
    });
    panel.addEventListener('submit', e => { e.preventDefault(); send(); });
    input.addEventListener('input', () => { grow(); paintTo(); });
    // Keys typed in the phone belong to the phone. A window capture listener runs before the Office's
    // own (the walk handler is one too, registered later), so W, arrows and F never reach the room.
    const typingIn = el => !!el && (/^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName) || el.isContentEditable);
    function onKey(e) {
      // P anywhere in the Office (floor, rooms, house, garden, walk, zooms) opens the phone; not while typing.
      if (!open && e.type === 'keydown' && (e.key === 'p' || e.key === 'P') && !e.metaKey && !e.ctrlKey && !e.altKey && !e.repeat
        && !typingIn(e.target) && rootEl.getClientRects().length) { e.preventDefault(); e.stopImmediatePropagation(); openPhone(); return; }
      // Esc closes the phone first, wherever focus is (walk mode, a room, the house); a second Esc is the Office's.
      if (open && e.key === 'Escape' && !panel.contains(e.target)) { e.stopImmediatePropagation(); if (e.type === 'keydown') { e.preventDefault(); closePhone(false); } return; }
      if (!open || !panel.contains(e.target) || e.key === 'Tab') return;
      e.stopImmediatePropagation();
      if (e.type !== 'keydown') return;
      if (e.key === 'Escape') { e.preventDefault(); closePhone(); return; }
      if (e.key === 'Enter' && e.target === input && !e.shiftKey && !e.isComposing) { e.preventDefault(); send(); }
    }
    ['keydown', 'keyup', 'keypress'].forEach(t => window.addEventListener(t, onKey, true));
    const onResize = () => { pin(); place(); };
    window.addEventListener('resize', onResize);
    window.addEventListener('scroll', onResize, { passive: true, capture: true });

    readAgents();
    agentsTimer = setInterval(() => { if (!document.hidden && rootEl.getClientRects().length) readAgents(); }, AGENTS_MS);

    return {
      open: openPhone, close: closePhone, toggle: () => (open ? closePhone() : openPhone()),
      refresh: () => Promise.all([readAgents(), readChat()]),
      state: () => ({ open, unread, boss: boss && boss.id, agents: agents.map(a => a.name), local: local.map(l => ({ text: l.text, routed: l.routed, name: l.name, receipt: l.receipt, failed: !!l.failed })), turns: turns.length }),
      destroy() {
        dead = true; closePhone(false); clearInterval(agentsTimer); clearInterval(pinTimer); cancelAnimationFrame(pinFrame);
        ['keydown', 'keyup', 'keypress'].forEach(t => window.removeEventListener(t, onKey, true));
        window.removeEventListener('resize', onResize); window.removeEventListener('scroll', onResize, true);
        if (observer) observer.disconnect();
        corner.remove(); panel.remove();
      }
    };
  }
  mountOfficePhone.route = route;
  // ?office-demo: reads stay real, every POST pretends (nothing reaches a terminal or the boss).
  mountOfficePhone.demoFetch = (url, opts = {}) => (opts.method === 'POST' ? Promise.resolve({ ok: true, sent: true, queued: false, demo: true }) : defaultFetchJson(url, opts));
  window.mountOfficePhone = mountOfficePhone;
})();
