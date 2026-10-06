/* The Office record player: a pixel-art turntable in the corner and a flat dial for picking music.
 * Instrumental and Vocals are built in; Mine shows the user's own playlists from goldware.json
 * (office.music.playlists). GoldWare ships with none: the Mine tab's button asks the boss to add them.
 * mountRecordPlayer(rootEl, { fetchJson }) adds it to rootEl (the Office stage) and returns
 * { open, close, refresh, destroy }. fetchJson(url, { method, body }) resolves to the parsed JSON;
 * on a failed request it resolves to an object with `error`. Mounting only reads the player state:
 * music starts only from an explicit click or Enter. */
(function () {
  'use strict';
  const GROUPS = [['instrumental', 'Instrumental'], ['vocals', 'Vocals'], ['mine', 'Mine']];
  const KIND = { instrumental: 'Instrumental', vocals: 'Vocals', mine: 'My playlists' };
  const SVGNS = 'http://www.w3.org/2000/svg';
  let mounted = 0;
  const px = d => `<svg viewBox="0 0 10 10" shape-rendering="crispEdges" aria-hidden="true"><path d="${d}"/></svg>`;
  const ICONS = {
    play: px('M2 1h2v1h1v1h1v1h1v1h1v1h-1v1h-1v1h-1v1h-1v1h-2z'),
    pause: px('M2 1h2v8h-2zM6 1h2v8h-2z'),
    skip: px('M1 1h2v1h1v1h1v1h1v2h-1v1h-1v1h-1v1h-2zM7 1h2v8h-2z'),
    vol: px('M1 4h2v-1h1v-1h1v6h-1v-1h-1v-1h-2zM6 3h1v4h-1zM8 2h1v6h-1z')
  };
  // The tonearm resting on the record from the top right; its stylus is the needle (.rp-needle).
  const TONEARM = `
<svg class="rp-tonearm" viewBox="0 0 340 48" shape-rendering="crispEdges" aria-hidden="true">
  <rect x="286" y="2" width="38" height="38" rx="6" fill="#202030"/>
  <rect x="289" y="5" width="32" height="32" rx="5" fill="#3a3a4c"/>
  <rect x="296" y="12" width="18" height="18" rx="9" fill="#b4c0da"/>
  <rect x="301" y="17" width="8" height="8" rx="4" fill="#202030"/>
  <rect x="322" y="13" width="14" height="16" rx="2" fill="#202030"/><rect x="324" y="15" width="10" height="12" rx="1" fill="#6a7286"/>
  <rect x="176" y="18" width="130" height="6" fill="#202030"/>
  <rect x="176" y="19" width="130" height="3" fill="#e6e9f4"/>
  <rect x="176" y="22" width="130" height="1" fill="#9aa0b8"/>
  <rect x="160" y="14" width="20" height="13" rx="2" fill="#202030"/>
  <rect x="162" y="16" width="16" height="5" fill="#ffcb05"/>
  <rect x="162" y="21" width="16" height="4" fill="#3a3a4c"/>
</svg>`;

  async function defaultFetchJson(url, opts = {}) {
    const init = { method: opts.method || 'GET', headers: { Accept: 'application/json' }, credentials: 'same-origin', cache: 'no-store' };
    if (opts.body !== undefined) { init.headers['Content-Type'] = 'application/json'; init.body = JSON.stringify(opts.body); }
    const res = await fetch(url, init);
    let data = {};
    try { data = await res.json(); } catch (e) { data = {}; }
    if (!res.ok) return Object.assign({}, data, { error: data.error || 'The Command Center said ' + res.status + '.' });
    return data;
  }

  const el = (tag, cls, attrs) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (attrs) for (const k in attrs) e.setAttribute(k, attrs[k]);
    return e;
  };
  const mod = (n, m) => ((n % m) + m) % m;

  // The corner turntable, drawn on a 32 x 24 pixel grid.
  const TURNTABLE = `
<svg viewBox="0 0 32 24" shape-rendering="crispEdges" aria-hidden="true">
  <rect x="2" y="21" width="29" height="2" fill="rgba(0,0,0,.28)"/>
  <rect x="1" y="7" width="30" height="15" fill="#202030"/>
  <rect x="2" y="8" width="28" height="13" fill="#9a6235"/>
  <rect x="2" y="8" width="28" height="2" fill="#c4874f"/>
  <rect x="2" y="18" width="28" height="3" fill="#6e4123"/>
  <rect x="4" y="19" width="2" height="1" fill="#ffcb05"/><rect x="7" y="19" width="2" height="1" fill="#e3350d"/>
  <rect x="25" y="19" width="3" height="1" fill="#f3efe0"/>
  <g class="rp-vinyl">
    <rect x="4" y="2" width="16" height="16" rx="8" fill="#202030"/>
    <rect x="5" y="3" width="14" height="14" rx="7" fill="#15151f"/>
    <rect x="6" y="4" width="12" height="12" rx="6" fill="none" stroke="#2c2c3e" stroke-width="1"/>
    <rect x="8" y="6" width="8" height="8" rx="4" fill="none" stroke="#2c2c3e" stroke-width="1"/>
    <rect x="9.5" y="7.5" width="5" height="5" rx="2.5" class="rp-label-fill"/>
    <rect x="11.5" y="7.5" width="1" height="2" fill="#fff" opacity=".85"/>
    <rect x="6" y="5" width="2" height="1" fill="#ffffff" opacity=".22"/>
  </g>
  <g class="rp-arm">
    <rect x="24" y="3" width="4" height="4" fill="#202030"/><rect x="25" y="4" width="2" height="2" fill="#b4c0da"/>
    <rect x="25.5" y="6" width="1" height="7" fill="#dcdce6"/>
    <rect x="22" y="12" width="4" height="1" fill="#dcdce6"/>
    <rect x="20" y="11" width="3" height="3" fill="#202030"/>
  </g>
  <g class="rp-notes"><rect x="27" y="0" width="1" height="3" fill="#ffcb05"/><rect x="25" y="2" width="2" height="2" fill="#ffcb05"/></g>
</svg>`;

  function mountRecordPlayer(rootEl, options = {}) {
    if (!rootEl) throw new Error('mountRecordPlayer needs an element');
    const fetchJson = options.fetchJson || defaultFetchJson;
    const endpoint = options.endpoint || '/api/office/music';
    const uid = 'rp' + (++mounted);
    const reduceQuery = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;

    let styles = [];
    let server = { running: false, state: 'stopped' };
    let group = 'instrumental';
    const lastIndex = Object.fromEntries(GROUPS.map(([k]) => [k, 0]));
    let items = [];          // styles in the current group
    let step = 30;           // degrees between styles on the dial
    let angle = 0;           // drawn rotation of the dial
    let target = 0;          // rotation the dial eases toward
    let selected = -1;
    let raf = 0, lastT = 0, snapTimer = 0, pollTimer = 0, volTimer = 0;
    let isOpen = false, busy = false, destroyed = false, reduced = !!(reduceQuery && reduceQuery.matches);
    let wheelCarry = 0;
    let drag = null;

    // ---- DOM
    const root = el('div', 'rp-root');
    const corner = el('button', 'rp-corner', { type: 'button', 'aria-haspopup': 'dialog', 'aria-expanded': 'false', 'aria-controls': uid + '-panel' });
    corner.innerHTML = TURNTABLE + '<span class="rp-tip" aria-hidden="true">Pick music</span>';
    const tip = corner.querySelector('.rp-tip');

    const panel = el('div', 'rp-panel', { id: uid + '-panel', role: 'dialog', 'aria-label': 'Record player: pick music', hidden: '' });
    panel.innerHTML = `
      <header class="rp-head"><b><i class="rp-led" aria-hidden="true"></i>Record player</b><button type="button" class="rp-x" aria-label="Close the record player (Esc)" title="Close (Esc)">×</button></header>
      <div class="rp-toggle" role="group" aria-label="Kind of music">
        ${GROUPS.map(([k, label]) => `<button type="button" data-group="${k}" aria-pressed="${k === 'instrumental'}">${label}</button>`).join('')}
      </div>
      <div class="rp-wheel" tabindex="0" role="listbox" aria-label="Music styles. Scroll, drag or use the arrow keys to turn the dial, Enter to play.">
        <div class="rp-dial">
          <svg class="rp-disc" viewBox="0 0 200 200" aria-hidden="true"></svg>
          <div class="rp-opts"></div>
        </div>
        <i class="rp-sheen" aria-hidden="true"></i>
        <div class="rp-center" aria-hidden="true"><span class="rp-center-kind"></span><b class="rp-center-name"></b></div>
        ${TONEARM}
        <i class="rp-needle" aria-hidden="true"></i>
      </div>
      <div class="rp-mine" hidden>
        <p class="rp-mine-text">Your own Spotify playlists go here. Press the button and an agent will ask which ones you want and add them for you.</p>
        <button type="button" class="rp-add">Add my playlists</button>
      </div>
      <button type="button" class="rp-play">Play</button>
      <div class="rp-now">
        <div class="rp-np">
          <canvas class="rp-cover" width="20" height="20" aria-hidden="true"></canvas>
          <p class="rp-now-line" aria-live="polite">Nothing playing</p>
          <span class="rp-eq" aria-hidden="true"><i></i><i></i><i></i><i></i></span>
        </div>
        <div class="rp-controls">
          <button type="button" class="rp-pp" data-act="pause" aria-label="Pause" title="Pause">${ICONS.pause}</button>
          <button type="button" class="rp-skip" aria-label="Skip to the next song" title="Skip">${ICONS.skip}</button>
          <label class="rp-vol" title="Volume">${ICONS.vol}<input type="range" min="0" max="100" step="1" value="50" aria-label="Volume"></label>
        </div>
      </div>
      <p class="rp-msg" role="status" aria-live="polite"></p>`;
    root.append(corner, panel);
    rootEl.appendChild(root);

    const $ = s => panel.querySelector(s);
    const wheel = $('.rp-wheel'), dial = $('.rp-dial'), disc = $('.rp-disc'), opts = $('.rp-opts');
    const centerName = $('.rp-center-name'), centerKind = $('.rp-center-kind');
    const playBtn = $('.rp-play'), ppBtn = $('.rp-pp'), skipBtn = $('.rp-skip'), vol = $('.rp-vol input');
    const nowLine = $('.rp-now-line'), msg = $('.rp-msg'), cover = $('.rp-cover');
    const mineBox = $('.rp-mine'), mineText = $('.rp-mine-text'), addBtn = $('.rp-add');

    // ---- the dial
    function build() {
      items = styles.filter(s => s.group === group);
      step = items.length ? 360 / items.length : 360;
      // Few styles leave wide gaps on the rim: let their names use them.
      wheel.style.setProperty('--rp-lw', step >= 60 ? 'calc(var(--rp-size) * .34)' : 'calc(var(--rp-size) * .2)');
      opts.textContent = '';
      disc.textContent = '';
      drawDisc();
      // Mine with nothing on it yet: no record, just the button that asks an agent to add playlists.
      const emptyMine = group === 'mine' && !items.length;
      mineBox.hidden = group !== 'mine';
      mineBox.classList.toggle('empty', emptyMine);
      mineText.hidden = !emptyMine;
      addBtn.textContent = emptyMine ? 'Add my playlists' : 'Add more playlists';
      wheel.hidden = emptyMine;
      playBtn.hidden = emptyMine;
      items.forEach((s, i) => {
        const o = el('div', 'rp-opt', { id: `${uid}-${s.key}`, role: 'option', 'aria-selected': 'false', 'data-key': s.key, 'data-i': i,
          'aria-label': `${s.label}, ${group === 'vocals' ? 'with vocals' : group === 'mine' ? 'one of your playlists' : 'instrumental'}. Spotify playlist ${s.title}` });
        o.style.setProperty('--rp-c', s.color);
        o.style.setProperty('--rp-a', (i * step) + 'deg');
        o.appendChild(el('i', 'rp-opt-k', { 'aria-hidden': 'true' }));   // its color block on the rim
        const t = el('span', 'rp-opt-t');
        t.textContent = s.label;
        o.appendChild(t);
        opts.appendChild(o);
      });
      selected = -1;
      const i = Math.min(lastIndex[group], Math.max(items.length - 1, 0));
      angle = target = -i * step;
      render(true);
    }

    // The platter (with strobe dots that shimmer as it turns) and the record: fine grooves, the gaps
    // between tracks, a glossy lip and the run-out near the label. Drawn once; the dial turns it.
    function drawDisc() {
      if (disc.childNodes.length) return;
      const add = (tag, attrs) => { const n = document.createElementNS(SVGNS, tag); for (const k in attrs) n.setAttribute(k, attrs[k]); disc.appendChild(n); return n; };
      add('circle', { cx: 100, cy: 100, r: 100, fill: '#202030' });
      add('circle', { cx: 100, cy: 100, r: 99, fill: '#9aa0b8' });
      add('circle', { cx: 100, cy: 100, r: 99, fill: 'none', stroke: '#c9cee0', 'stroke-width': 0.8 });
      for (let i = 0; i < 72; i++) {
        const g = add('g', { transform: `rotate(${i * 5} 100 100)` });
        const r = document.createElementNS(SVGNS, 'rect');
        for (const [k, v] of Object.entries({ x: 99.2, y: 1.6, width: 1.6, height: 1.6, fill: i % 2 ? '#6c7290' : '#e6e9f4' })) r.setAttribute(k, v);
        g.appendChild(r);
      }
      add('circle', { cx: 100, cy: 100, r: 96.4, fill: '#0b0b12' });
      add('circle', { cx: 100, cy: 100, r: 95.6, fill: '#15151f' });
      add('circle', { cx: 100, cy: 100, r: 94.6, fill: 'none', stroke: '#2a2a3c', 'stroke-width': 1 });
      for (let r = 35; r <= 92; r += 1.5) {
        const gap = [50, 63, 76].some(g => Math.abs(r - g) < 0.8);
        add('circle', { cx: 100, cy: 100, r, fill: 'none', stroke: gap ? '#262638' : (Math.round(r / 1.5) % 2 ? '#1b1b28' : '#181823'), 'stroke-width': gap ? 1.4 : 0.8 });
      }
      add('circle', { cx: 100, cy: 100, r: 33.5, fill: '#12121b' });
    }

    function indexAt(a) { return items.length ? mod(Math.round(-a / step), items.length) : -1; }

    function render(force) {
      if (reduced) { angle = target; dial.style.transform = ''; }   // no turning: the list highlight moves instead
      else dial.style.transform = `rotate(${angle}deg)`;
      const nodes = opts.children;
      for (let i = 0; i < nodes.length; i++) {
        const span = nodes[i].lastChild;
        if (reduced) { span.style.transform = ''; span.style.opacity = ''; continue; }
        const signed = mod(i * step + angle + 180, 360) - 180;          // 0 at the needle, ±180 at the bottom
        const d = Math.abs(signed);
        const near = Math.max(0, 1 - d / step);
        // Spread the labels near the needle and gather them at the bottom (a smooth sine warp, so the
        // order and the motion stay even): the enlarged name gets room and nobody crowds a neighbour.
        const push = step * 0.3 * Math.sin(signed * Math.PI / 180);
        nodes[i].style.setProperty('--rp-a', (i * step + push).toFixed(2) + 'deg');
        const fade = near > 0 ? 0.42 + 0.58 * Math.pow(near, 1.5) : 0.42 * (1 - 0.8 * Math.pow((d - step) / (180 - step), 0.8));
        span.style.opacity = fade.toFixed(3);
        nodes[i].firstChild.style.opacity = Math.max(0.7, fade).toFixed(3);   // the rim stays colorful
        // Past the sides a label turns over, so every name reads upright.
        span.style.transform = `scale(${(0.9 + 0.3 * near - 0.14 * d / 180).toFixed(3)})${Math.abs(signed + push) > 90 ? ' rotate(180deg)' : ''}`;
      }
      const now = indexAt(reduced ? target : angle);
      if (now !== selected || force) select(now);
    }

    function select(i) {
      selected = i;
      lastIndex[group] = Math.max(i, 0);
      const s = items[i];
      [...opts.children].forEach((n, k) => { n.classList.toggle('on', k === i); n.setAttribute('aria-selected', String(k === i)); });
      if (s) {
        wheel.setAttribute('aria-activedescendant', `${uid}-${s.key}`);
        centerName.textContent = s.label;
        centerKind.textContent = KIND[group] || '';
        centerName.classList.toggle('long', s.label.length > 22);
        wheel.style.setProperty('--rp-sel', s.color);
        playBtn.textContent = (server.style === s.key && server.state === 'playing') ? 'Playing ' + s.label : 'Play ' + s.label;
        playBtn.disabled = busy;
      } else {
        centerName.textContent = styles.length ? '' : 'No styles yet';
        playBtn.disabled = true;
      }
    }

    function tick(t) {
      raf = 0;
      const dt = lastT ? Math.min((t - lastT) / 1000, 0.05) : 1 / 60;
      lastT = t;
      if (!drag) angle += (target - angle) * (1 - Math.exp(-dt / 0.085));
      if (Math.abs(target - angle) < 0.02 && !drag) angle = target;
      render(false);
      if (angle !== target || drag) raf = requestAnimationFrame(tick);
      else lastT = 0;
    }
    function animate() { if (!raf && !reduced) raf = requestAnimationFrame(tick); }
    function snapTarget() { target = Math.round(target / step) * step; }
    function moveBy(n) {
      if (!items.length) return;
      if (reduced) { target = -mod(indexAt(target) + n, items.length) * step; render(false); return; }
      snapTarget(); target -= n * step; animate();
    }
    function goTo(i) {
      // The shortest way round to put style i under the needle.
      const want = -i * step;
      target = want + Math.round((target - want) / 360) * 360;
      if (reduced) render(false); else animate();
    }

    wheel.addEventListener('wheel', e => {
      e.preventDefault();
      if (!items.length) return;
      const px = (e.deltaY || e.deltaX) * (e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 400 : 1);
      if (reduced) {
        wheelCarry += px;
        while (Math.abs(wheelCarry) >= 60) { moveBy(Math.sign(wheelCarry)); wheelCarry -= 60 * Math.sign(wheelCarry); }
        return;
      }
      target -= px * step / 100;          // one mouse notch turns one style
      animate();
      clearTimeout(snapTimer);
      snapTimer = setTimeout(() => { snapTarget(); animate(); }, 140);
    }, { passive: false });

    const pointerAngle = e => {
      const r = wheel.getBoundingClientRect();
      return Math.atan2(e.clientY - (r.top + r.height / 2), e.clientX - (r.left + r.width / 2)) * 180 / Math.PI;
    };
    wheel.addEventListener('pointerdown', e => {
      if (e.button !== 0) return;
      drag = { start: pointerAngle(e), from: angle, x: e.clientX, y: e.clientY, moved: false, last: performance.now(), lastA: angle, v: 0, opt: e.target.closest('.rp-opt') };
      wheel.focus({ preventScroll: true });
      try { wheel.setPointerCapture(e.pointerId); } catch (err) { /* a synthetic pointer */ }
    });
    wheel.addEventListener('pointermove', e => {
      if (!drag) return;
      if (!drag.moved && Math.hypot(e.clientX - drag.x, e.clientY - drag.y) < 5) return;
      drag.moved = true;
      if (reduced) return;
      let d = pointerAngle(e) - drag.start;
      d = mod(d + 180, 360) - 180;
      const now = performance.now();
      const next = drag.from + d;
      const dt = Math.max(now - drag.last, 1) / 1000;
      drag.v = drag.v * 0.6 + ((next - drag.lastA) / dt) * 0.4;
      drag.last = now; drag.lastA = next;
      angle = target = next;
      if (!raf) raf = requestAnimationFrame(tick);
    });
    const endDrag = e => {
      if (!drag) return;
      const d = drag;
      drag = null;
      if (!d.moved) {
        if (d.opt) {
          const i = Number(d.opt.dataset.i);
          if (i === selected) play(); else goTo(i);
        }
        return;
      }
      if (reduced) return;
      target = angle + Math.max(-540, Math.min(540, d.v)) * 0.22;   // a flick carries on, then settles
      snapTarget();
      animate();
    };
    wheel.addEventListener('pointerup', endDrag);
    wheel.addEventListener('pointercancel', endDrag);

    // ---- keyboard: keys inside the panel stay in the panel (the Office's own shortcuts sleep)
    panel.addEventListener('keydown', e => {
      if (e.key === 'Tab') return;
      e.stopPropagation();
      if (e.key === 'Escape') { e.preventDefault(); close(); return; }
      if (e.target === vol) return;
      if (e.target !== wheel) return;
      if (e.key === 'ArrowRight' || e.key === 'ArrowDown') { e.preventDefault(); moveBy(1); }
      else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') { e.preventDefault(); moveBy(-1); }
      else if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); play(); }
    });
    const onDocKey = e => { if (isOpen && e.key === 'Escape') { e.stopPropagation(); e.preventDefault(); close(); } };
    const onDocDown = e => { if (isOpen && !root.contains(e.target)) close(false); };

    // ---- panel open and close
    function place() {
      const r = corner.getBoundingClientRect();
      const w = Math.min(400, innerWidth - 16);
      panel.style.width = w + 'px';
      panel.style.left = Math.max(8, Math.min(r.left, innerWidth - w - 8)) + 'px';
      // Stay inside the room (below the Office toolbar) and inside the window: if the panel would
      // not fit, the record shrinks (never below 200px) before the panel moves.
      const room = rootEl.getBoundingClientRect();
      const top = Math.max(8, room.top + 8);
      wheel.style.removeProperty('--rp-size');
      let h = panel.offsetHeight;
      const fitsAbove = r.top - 10 - top;
      if (h <= fitsAbove || innerWidth < 600) {
        panel.style.top = Math.max(8, Math.min(r.top - h - 10, innerHeight - h - 8)) + 'px';
        return;
      }
      // Not enough room above the turntable: open beside it, inside the room. Only when even that is
      // too short does the record shrink (never below 200px).
      const fitsBeside = Math.min(innerHeight - 8, Math.max(room.bottom - 8, r.bottom)) - top;
      if (h > fitsBeside && !reduced) {
        const size = wheel.getBoundingClientRect().width;
        wheel.style.setProperty('--rp-size', Math.max(200, Math.floor(size - (h - fitsBeside))) + 'px');
        h = panel.offsetHeight;
      }
      panel.style.left = Math.max(8, Math.min(r.right + 14, innerWidth - w - 8)) + 'px';
      panel.style.top = Math.max(top, Math.min(r.bottom - h, innerHeight - h - 8)) + 'px';
    }
    function open() {
      if (isOpen) return;
      isOpen = true;
      panel.hidden = false;
      corner.setAttribute('aria-expanded', 'true');
      root.classList.add('open');
      place();
      (wheel.hidden ? addBtn : wheel).focus({ preventScroll: true });
      document.addEventListener('keydown', onDocKey, true);
      document.addEventListener('pointerdown', onDocDown, true);
      addEventListener('resize', place);
      refresh();
    }
    function close(restoreFocus = true) {
      if (!isOpen) return;
      isOpen = false;
      panel.hidden = true;
      corner.setAttribute('aria-expanded', 'false');
      root.classList.remove('open');
      document.removeEventListener('keydown', onDocKey, true);
      document.removeEventListener('pointerdown', onDocDown, true);
      removeEventListener('resize', place);
      if (restoreFocus) corner.focus({ preventScroll: true });
      schedule();
    }
    corner.addEventListener('click', () => (isOpen ? close() : open()));
    $('.rp-x').addEventListener('click', () => close());
    panel.querySelector('.rp-toggle').addEventListener('click', e => {
      const b = e.target.closest('[data-group]');
      if (b && b.dataset.group !== group) setGroup(b.dataset.group);
    });
    function setGroup(g) {
      group = g;
      panel.querySelectorAll('.rp-toggle [data-group]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.group === g)));
      wheel.classList.remove('rp-flip'); void wheel.offsetWidth; wheel.classList.add('rp-flip');
      build();
    }

    // ---- talking to the server
    function say(text, bad) { msg.textContent = text || ''; msg.classList.toggle('bad', !!bad); }
    async function call(body) {
      let res;
      try { res = await fetchJson(endpoint, body ? { method: 'POST', body } : { method: 'GET' }); }
      catch (err) { res = { error: 'The Command Center is not answering.' }; }
      return res || { error: 'No answer.' };
    }
    async function act(body, pending) {
      if (busy) return;
      busy = true; root.classList.add('busy'); say(pending || '');
      [playBtn, ppBtn, skipBtn].forEach(b => (b.disabled = true));
      const res = await call(body);
      busy = false; root.classList.remove('busy');
      if (res.error) { say(res.error, true); show(); return; }
      say('');
      take(res);
    }
    function play() {
      const s = items[selected];
      if (!s) return;
      act({ action: 'play', style: s.key }, 'Starting ' + s.label + '…');
    }
    playBtn.addEventListener('click', play);
    addBtn.addEventListener('click', async () => {
      if (addBtn.disabled) return;
      addBtn.disabled = true; say('Asking the boss…');
      const res = await call({ action: 'add-playlists' });
      if (res.error) say(res.error, true);
      else say(res.demo ? 'Demo: nothing was sent.' : res.started
        ? 'The boss is sitting down at the front desk. Tell it which playlists you want; its console opens there.'
        : 'Sent to the boss at the front desk. Tell it which playlists you want.');
      setTimeout(() => { addBtn.disabled = false; }, 2000);
    });
    ppBtn.addEventListener('click', () => act({ action: ppBtn.dataset.act }));
    skipBtn.addEventListener('click', () => act({ action: 'next' }));
    vol.addEventListener('input', () => {
      vol.style.setProperty('--v', vol.value + '%');
      clearTimeout(volTimer);
      const v = Math.round(Number(vol.value));
      volTimer = setTimeout(async () => { const r = await call({ action: 'volume', volume: v }); if (r.error) say(r.error, true); }, 160);
    });

    function take(res) {
      if (Array.isArray(res.styles) && res.styles.length && JSON.stringify(res.styles) !== JSON.stringify(styles)) {
        const first = !styles.length;
        styles = res.styles;
        if (first && res.style) {
          const s = styles.find(x => x.key === res.style);
          if (s) { group = s.group; lastIndex[group] = styles.filter(x => x.group === group).indexOf(s); setGroupButtons(); }
        }
        build();
      }
      server = res;
      show();
    }
    function setGroupButtons() { panel.querySelectorAll('.rp-toggle [data-group]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.group === group))); }

    function show() {
      const playing = server.state === 'playing';
      const style = styles.find(s => s.key === server.style);
      root.classList.toggle('playing', playing);
      root.style.setProperty('--rp-now', style ? style.color : '#ffcb05');
      const name = style ? style.label : (playing ? 'Spotify' : '');
      tip.textContent = playing ? name + ' · playing' : (name ? name + ' · paused' : 'Pick music');
      corner.setAttribute('aria-label', 'Record player. ' + (playing ? 'Playing ' + name : name ? name + ' is paused' : 'Nothing playing') + '. Open the music picker.');
      corner.title = tip.textContent;
      nowLine.textContent = '';
      const b = el('b');
      b.textContent = !server.running ? 'Nothing playing' : (playing ? 'Now playing' : server.state === 'paused' ? 'Paused' : 'Stopped') + (style ? ' · ' + style.label : '');
      nowLine.append(b);
      const t = el('span', 'rp-track'), a = el('span', 'rp-artist');
      t.textContent = server.running ? (server.track || 'Spotify') : 'Pick a style and press Play.';
      a.textContent = server.running ? (server.artist || '') : '';
      nowLine.append(t, a);
      paintCover(server.running ? server.art : null, style ? style.color : '#ffcb05');
      ppBtn.dataset.act = playing ? 'pause' : 'resume';
      ppBtn.innerHTML = playing ? ICONS.pause : ICONS.play;
      ppBtn.setAttribute('aria-label', playing ? 'Pause' : 'Resume');
      ppBtn.title = playing ? 'Pause' : 'Resume';
      ppBtn.disabled = busy || !server.running || server.state === 'stopped';
      skipBtn.disabled = busy || !server.running;
      vol.disabled = !server.running;
      if (Number.isInteger(server.volume) && document.activeElement !== vol) vol.value = server.volume;
      vol.style.setProperty('--v', vol.value + '%');
      [...opts.children].forEach(n => n.classList.toggle('live', server.running && server.style === n.dataset.key && server.state !== 'stopped'));
      select(selected);
    }

    // The album cover, shrunk to 20 x 20 and shown with hard pixels so it matches the Office. Without
    // a cover: a little record in the style's color.
    let coverKey = '';
    function paintCover(url, color) {
      const key = (url || '') + '|' + color;
      if (key === coverKey) return;
      coverKey = key;
      const g = cover.getContext('2d');
      const blank = () => {
        g.fillStyle = '#202030'; g.fillRect(0, 0, 20, 20);
        g.fillStyle = '#15151f'; g.beginPath(); g.arc(10, 10, 8, 0, 7); g.fill();
        g.fillStyle = color; g.beginPath(); g.arc(10, 10, 3, 0, 7); g.fill();
        g.fillStyle = '#f3efe0'; g.fillRect(9.5, 9.5, 1, 1);
      };
      blank();
      if (!url || !/^https:\/\/i\.scdn\.co\/image\/[a-z0-9]+$/.test(url)) return;
      const img = new Image();
      img.onload = () => { if (coverKey === key) { g.imageSmoothingQuality = 'high'; g.drawImage(img, 0, 0, 20, 20); } };
      img.src = url;
    }

    async function refresh() {
      clearTimeout(pollTimer);
      const res = await call(null);
      if (destroyed) return;
      if (res.error) { if (isOpen) say(res.error, true); }
      else { if (msg.classList.contains('bad') && !busy) say(''); take(res); }
      schedule();
    }
    function schedule() {
      clearTimeout(pollTimer);
      if (destroyed) return;
      const wait = document.hidden ? 30000 : (isOpen || server.state === 'playing') ? 4000 : 15000;
      pollTimer = setTimeout(refresh, wait);
    }
    const onVisible = () => { if (!document.hidden) refresh(); };
    document.addEventListener('visibilitychange', onVisible);

    const onReduce = () => {
      reduced = !!reduceQuery.matches;
      root.classList.toggle('rp-reduced', reduced);
      if (reduced) { snapTarget(); angle = target; }
      render(true);
    };
    if (reduceQuery) reduceQuery.addEventListener ? reduceQuery.addEventListener('change', onReduce) : reduceQuery.addListener(onReduce);
    root.classList.toggle('rp-reduced', reduced);

    build();
    show();
    refresh();

    function destroy() {
      destroyed = true;
      close(false);
      clearTimeout(pollTimer); clearTimeout(snapTimer); clearTimeout(volTimer);
      if (raf) cancelAnimationFrame(raf);
      document.removeEventListener('visibilitychange', onVisible);
      if (reduceQuery && reduceQuery.removeEventListener) reduceQuery.removeEventListener('change', onReduce);
      root.remove();
    }
    return { open, close, refresh, destroy, get selected() { return items[selected] ? items[selected].key : null; }, get angle() { return angle; }, root };
  }

  // ?office-demo: the real style list, a pretend player. Nothing reaches Spotify or the boss.
  mountRecordPlayer.demoFetch = (() => {
    const fake = { running: false, state: 'stopped', track: null, artist: null, volume: 50, style: null, art: null };
    let list = null;
    return async (url, opts = {}) => {
      if (!list) { try { list = (await defaultFetchJson(url)).styles || []; } catch (e) { list = []; } }
      const b = opts.body || {};
      if (opts.method === 'POST') {
        if (b.action === 'add-playlists') return { ok: true, demo: true };
        if (b.action === 'play') {
          const s = list.find(x => x.key === b.style);
          if (!s) return { error: 'Pick one of the styles on the wheel.' };
          Object.assign(fake, { running: true, state: 'playing', style: s.key, track: 'A song from ' + s.title, artist: 'Demo' });
        } else if (!fake.running) return { error: 'Spotify is not open. Pick a style to start it.' };
        else if (b.action === 'pause') fake.state = 'paused';
        else if (b.action === 'resume') fake.state = 'playing';
        else if (b.action === 'next') fake.track = 'Another song';
        else if (b.action === 'volume') fake.volume = b.volume;
      }
      const s = list.find(x => x.key === fake.style);
      return Object.assign({ ok: true, styles: list, style_label: s ? s.label : null }, fake);
    };
  })();

  window.mountRecordPlayer = mountRecordPlayer;
})();
