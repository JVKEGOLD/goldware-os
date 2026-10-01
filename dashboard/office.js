/* GoldWare OS Office tab. See server/office.py for the data. */
/* The Office: every agent working on this Mac, at a desk, drawn as pixel art.
   Reads /api/office/agents (server/office.py) every 3 s while the tab is open
   and draws at 12 fps only while it is visible. You are the boss, at the front desk.
   Add ?office-demo to the URL for made-up agents (no terminals are touched). */
(() => {
  const tab = document.getElementById('tab-office');
  const canvas = document.getElementById('office-canvas');
  if (!tab || !canvas) return;
  const ctx = canvas.getContext('2d');
  const stage = document.getElementById('office-stage');
  const desksLayer = document.getElementById('office-desks');
  const card = document.getElementById('office-card');
  const ticker = document.getElementById('office-ticker');
  const summary = document.getElementById('office-summary');
  const still = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const WALL = 92, ROW = 76, SLOT = 71, FPS = 12;

  const C = {
    wall: '#1d1a15', wallHi: '#24201a', trim: '#2f2a22', floor: '#2a2119', floorLine: '#231c15', floorHi: '#32281e',
    wood: '#7a5634', woodHi: '#9a7046', woodLo: '#5a3f26', woodDark: '#3e2b1a',
    chair: '#241f1a', chairHi: '#332c24', metal: '#3a3631', screen: '#0f1512', bezel: '#26231f',
    suit: '#34323a', suitHi: '#4a4852', suitLo: '#232228', skin: '#e2b48c', skinLo: '#c4966f', hair: '#2b1d14', eye: '#f2eee4', pupil: '#0c0b09',
    gold: '#d2aa5f', goldHi: '#f9d976', ink: '#0c0b09', text: '#f2eee4', green: '#9fd07f', red: '#f0806b', cyan: '#86cbc2'
  };
  // The boss (you) wears a charcoal suit and a gold tie. Everyone else gets their own colour, in order,
  // and keeps it for as long as they sit here. Claude Code and Codex wear their own brands.
  const COLORS = ['#3f9a8c', '#8a63c4', '#d08a2e', '#4f8fd0', '#5b9a4a', '#c0566e', '#b8a23a', '#6a7fd8', '#2f8fb0', '#a8577f'];
  const shade = (hex, f) => {
    const n = parseInt(hex.slice(1), 16), c = [n >> 16, (n >> 8) & 255, n & 255].map(v => Math.max(0, Math.min(255, Math.round(f > 0 ? v + (255 - v) * f : v * (1 + f)))));
    return '#' + c.map(v => v.toString(16).padStart(2, '0')).join('');
  };
  const colorOf = new Map();
  let nextColor = 0;
  const assign = id => { if (!colorOf.has(id)) colorOf.set(id, COLORS[nextColor++ % COLORS.length]); return colorOf.get(id); };
  const WORDS = {
    typing: 'Running commands', writing: 'Writing files', reading: 'Reading', browsing: 'On the web',
    looking: 'Looking at an image', delegating: 'Handing work to helpers', thinking: 'Thinking',
    working: 'Working', your_turn: 'Waiting on you', idle: 'Idle', asleep: 'Asleep',
    helpers: 'Waiting on its helpers', bed: 'Out of usage, in bed'
  };
  const BUSY = new Set(['typing', 'writing', 'reading', 'browsing', 'looking', 'delegating', 'thinking', 'working', 'helpers']);

  let data = null, error = false, selected = null, frame = 0, timer = null, poller = null, W = 332, H = 282;
  const seen = new Map(), log = [];

  const px = (x, y, w, h, c) => { ctx.fillStyle = c; ctx.fillRect(Math.round(x), Math.round(y), w, h); };
  const pattern = (x, y, rows, c) => rows.forEach((r, j) => [...r].forEach((ch, i) => { if (ch === '#') px(x + i, y + j, 1, 1, c); }));
  const rand = n => { const s = Math.sin(n * 12.9898) * 43758.5453; return s - Math.floor(s); };

  // ── Layout: one desk per open terminal, no empty desks. For n agents every column count is
  //    tried and the one that draws the room biggest in the space it has wins (ties: fewer columns,
  //    so rows stay balanced). Rows step toward you; Your desk is always at the front. ──
  const FRONT = 96;   // Your row at the front of the room
  function roomSize(n, cols) {
    const rows = n ? Math.ceil(n / cols) : 0, area = Math.max(4, cols) * SLOT;
    const bossY = rows ? 130 + (rows - 1) * ROW + FRONT : 150;
    return { cols, rows, area, W: 48 + area, H: bossY + 56 + (rows > 1 ? 6 : 0), bossY };
  }
  function chooseLayout(n, aw, ah) {
    let best = null;
    for (let cols = n ? 1 : 0; cols <= Math.min(Math.max(n, 0), 8); cols++) {
      const g = roomSize(n, cols), scale = Math.min(aw / g.W, ah / g.H);
      if (!best || scale > best.scale * 1.02) best = { ...g, n, scale };
    }
    return best;
  }
  let geo = roomSize(0, 0), bossSpot = { x: 148, y: 150 };
  // The room canvas is as big as the space it has; the desks sit in the middle of it (ox, oy) and the
  // extra becomes wall and floor, so the room fills the window instead of letterboxing.
  let ox = 0, oy = 0;
  function layout(n) {
    const { cols, area } = geo, desks = n;
    bossSpot = { x: Math.round(ox + 6 + area / 2), y: oy + geo.bossY };
    return Array.from({ length: desks }, (_, i) => {
      const r = Math.floor(i / cols), c = i % cols;
      const inRow = Math.min(cols, desks - r * cols);
      const offset = (area - inRow * SLOT) / 2;
      // A desk alone in its row may use the spare width for its plate, so it keeps its whole title.
      return { x: Math.round(ox + 6 + offset + SLOT * c + SLOT / 2), y: oy + 130 + r * ROW, slot: inRow === 1 ? Math.min(SLOT * 2, area) : SLOT };
    });
  }
  const lamps = () => { const l = []; for (let x = 70; x < W - 50; x += 96) l.push(x); return l; };
  // Bulbs on a sagging wire from the left wall to the rack: [x, y, colour, index].
  const BULBS = ['#ffd38a', '#ffb45e', '#fff0c8', '#ff9f6a'];
  function stringLights() {
    const out = [], ends = [4, ...lamps(), W - 46];
    for (let i = 0; i < ends.length - 1; i++) {
      const a = ends[i], b = ends[i + 1];
      for (let x = a + 6; x < b - 3; x += 8) { const u = (x - a) / (b - a); px(x - 4, 3 + Math.round(Math.sin(u * Math.PI) * 4), 8, 1, '#2a2016'); out.push([x, 4 + Math.round(Math.sin(u * Math.PI) * 4), BULBS[(x >> 3) % 4], x]); }
    }
    return out;
  }

  // ── Room ──
  function sky(hour) {
    if (hour >= 7 && hour < 17) return ['#5d8fc9', '#a9c9e6', 'day'];
    if (hour >= 17 && hour < 19) return ['#4a3a6e', '#e59a62', 'dusk'];
    if (hour >= 5 && hour < 7) return ['#3f4f86', '#e6b07a', 'dusk'];
    return ['#0b1230', '#1d2752', 'night'];
  }
  // One building: the GoldWare coffee shop. Warm brick, walnut floor, wood wainscot.
  const CAFE = { wall: '#3a2216', wallHi: '#2a170e', trim: '#5a3a22', floor: '#6a4326', floorLine: '#4e301a', floorHi: '#7a5030', floorKind: 'planks', brick: true };
  function room(now) {
    const hour = now.getHours() + now.getMinutes() / 60;
    const [top, bottom, phase] = sky(hour);
    const T = CAFE;
    Object.assign(C, T);
    px(0, 0, W, WALL, C.wall);
    if (T.brick) {
      for (let y = 4, k = 0; y < WALL - 18; y += 6, k++) {
        px(0, y, W, 1, C.wallHi);
        for (let x = (k % 2) * 7 - 7; x < W; x += 14) {
          const r = rand(x * 0.37 + k * 13.1);
          if (r > 0.7) px(x + 1, y + 1, 13, 5, r > 0.9 ? '#4a2c1c' : '#432719');
          px(x, y + 1, 1, 5, C.wallHi);
        }
      }
    } else for (let x = 0; x < W; x += 20) px(x, 0, 1, WALL - 18, C.wallHi);
    // Wainscot: walnut panels with a rail on top.
    px(0, WALL - 19, W, 2, '#7a5030'); px(0, WALL - 17, W, 17, '#2e1c10');
    for (let x = 6; x < W; x += 18) { px(x, WALL - 14, 14, 11, '#36210f'); px(x, WALL - 14, 14, 1, '#24150a'); }
    px(0, WALL - 1, W, 1, C.trim);
    // Floor: planks, poured concrete, or marble with veins.
    px(0, WALL, W, H - WALL, C.floor);
    if (T.floorKind === 'planks') {
      for (let y = WALL + 6, k = 0; y < H; y += 7, k++) {
        px(0, y, W, 1, C.floorLine);
        for (let x = (k % 3) * 29; x < W; x += 87) px(x, y - 6, 1, 6, C.floorLine);
        for (let x = 0; x < W; x += 9) if (rand(x * 0.7 + k * 3.1) > 0.72) px(x, y - 3 - (k % 2), 5, 1, rand(x + k) > 0.5 ? C.floorHi : '#5e3b21');
      }
    } else if (T.floorKind === 'concrete') {
      for (let y = WALL + 30; y < H; y += 30) px(0, y, W, 1, C.floorLine);
      for (let x = 40; x < W; x += 60) px(x, WALL, 1, H - WALL, C.floorLine);
      for (let s = 0; s < W * (H - WALL) / 260; s++) px(Math.floor(rand(s) * W), WALL + Math.floor(rand(s * 7.1) * (H - WALL)), 1, 1, C.floorHi);
    } else {
      for (let y = WALL + 24; y < H; y += 24) px(0, y, W, 1, C.floorLine);
      for (let x = 0; x < W; x += 24) px(x, WALL, 1, H - WALL, C.floorLine);
      for (let v = 0; v < W / 20; v++) {
        let vx = rand(v * 3.3) * W, vy = WALL + rand(v * 5.7) * (H - WALL);
        for (let s = 0; s < 14; s++) { px(vx, vy, 1, 1, C.floorHi); vx += 1; vy += rand(v + s) > 0.5 ? 1 : 0; }
      }
    }
    px(0, WALL, W, 1, C.floorHi);
    // Windows: Hawaii outside, the real sky for the hour.
    // The wall, left to right: a window, the three boards (tasks, ideas, the lab), a portrait of the boss,
    // the clock, more windows while they fit, the plant. The rack stands at the right end.
    // The boards are written on, so they take the wall's spare width (46 to 104 px each).
    const BW = Math.max(46, Math.min(104, Math.floor((W - 19 - 64 - 72 - 40 - 34 - 30) / 3)));
    const wallPlan = [['win', 62, 'a'], ['tasks', BW + 4], ['ideas', BW + 4], ['lab', BW + 4], ['portrait', 30], ['clock', 24], ['win', 62, 'b']];
    for (let k = 0; k < 6; k++) wallPlan.push(['win', 62, 'c']);
    wallPlan.push(['plant', 12]);
    const placed = {}, wins = [];
    let cur = 19;
    wallPlan.forEach(([kind, w, id]) => {
      const fits = cur + w <= W - 50 - (kind === 'plant' ? 0 : 14);
      const must = kind === 'tasks' || kind === 'ideas' || kind === 'lab';
      if (!fits && !must) return;
      if (kind === 'win') wins.push([cur + 3, id]); else placed[kind] = cur;
      cur += w + 10;
    });
    wallBoards = { tasks: { x: placed.tasks, y: 9, w: BW, h: 54 }, ideas: { x: placed.ideas, y: 9, w: BW, h: 54 }, lab: { x: placed.lab, y: 9, w: BW, h: 50 } };
    wallClock = placed.clock != null ? placed.clock + 12 : null;
    wins.forEach(([wx, id]) => {
      const ww = 56, wh = 44, wy = 16;
      px(wx - 3, wy - 3, ww + 6, wh + 6, C.trim);
      const g = ctx.createLinearGradient(0, wy, 0, wy + wh);
      g.addColorStop(0, top); g.addColorStop(1, bottom);
      ctx.fillStyle = g; ctx.fillRect(wx, wy, ww, wh);
      if (phase === 'night') {
        for (let s = 0; s < 14; s++) {
          const sx = wx + Math.floor(rand(s + wx) * ww), sy = wy + Math.floor(rand(s * 3 + wx) * (wh - 16));
          if ((frame + s * 7) % 40 > 3) px(sx, sy, 1, 1, '#f2eee4');
        }
        if (id === 'b') { px(wx + 44, wy + 8, 6, 6, '#efe6c8'); px(wx + 46, wy + 8, 4, 4, '#0b1230'); }
      } else if (id === 'a') {
        const sun = phase === 'day' ? '#f9d976' : '#f0a060';
        px(wx + 40, wy + (phase === 'day' ? 8 : 26), 8, 8, sun); px(wx + 39, wy + (phase === 'day' ? 9 : 27), 10, 6, sun);
        const cx = (frame / 3 + wx) % (ww + 20) - 10;
        if (phase === 'day') { px(wx + cx, wy + 14, 12, 3, '#e8eef6'); px(wx + cx + 3, wy + 12, 6, 2, '#e8eef6'); }
      }
      // Ocean and a palm on the left window.
      const sea = phase === 'night' ? '#14234a' : phase === 'dusk' ? '#5a5a8a' : '#3f78b8';
      px(wx, wy + wh - 12, ww, 12, sea);
      for (let x = 0; x < ww; x += 6) if ((x + frame) % 12 < 6) px(wx + x, wy + wh - 11 + ((x / 6) % 2), 3, 1, phase === 'night' ? '#2a3b6a' : '#9cc4e8');
      if (id === 'a') {
        const trunk = '#2a1d12', leaf = phase === 'night' ? '#0f1a12' : '#2f5a2c';
        for (let i = 0; i < 26; i++) px(wx + 12 + Math.round(Math.sin(i / 9) * 3), wy + wh - 1 - i, 2, 1, trunk);
        const sway = Math.round(Math.sin(frame / 8));
        const tx = wx + 13 + sway, ty = wy + wh - 27;
        [[-10, 2], [-7, -2], [0, -4], [7, -2], [10, 3]].forEach(([dx, dy]) => {
          for (let s = 0; s <= 6; s++) px(tx + Math.round(dx * s / 6), ty + Math.round(dy * s / 6 + (s * s) / 14), 2, 1, leaf);
        });
      }
      px(wx + ww / 2 - 1, wy, 2, wh, C.trim); px(wx, wy + wh / 2 - 1, ww, 2, C.trim);
    });
    // The GoldWare neon: GW in gold light on the brick.
    if (placed.portrait != null) {
      const gx = placed.portrait + 3, gy = 24, on = still || frame % 90 !== 0;
      const neon = on ? '#ffd27a' : '#6b5228';
      ctx.globalCompositeOperation = 'lighter';
      const g = ctx.createRadialGradient(gx + 12, gy + 4, 1, gx + 12, gy + 4, 22);
      g.addColorStop(0, on ? 'rgba(255,190,90,.35)' : 'rgba(0,0,0,0)'); g.addColorStop(1, 'rgba(0,0,0,0)');
      ctx.fillStyle = g; ctx.fillRect(gx - 12, gy - 18, 48, 44);
      ctx.globalCompositeOperation = 'source-over';
      const big = (x, y, rows) => rows.forEach((r, j) => [...r].forEach((ch, i) => { if (ch === '#') px(x + i * 2, y + j * 2, 2, 2, neon); }));
      big(gx - 4, gy - 6, ['.###.', '#...#', '#....', '#.###', '#...#', '.###.']);
      big(gx + 8, gy - 6, ['#...#', '#...#', '#...#', '#.#.#', '##.##', '#...#']);
    }
    // Clock with the real time.
    if (wallClock != null) {
      const ccx = wallClock, ccy = 32;
      ctx.fillStyle = C.gold; ctx.beginPath(); ctx.arc(ccx, ccy, 10, 0, 7); ctx.fill();
      ctx.fillStyle = '#efe6d2'; ctx.beginPath(); ctx.arc(ccx, ccy, 8.5, 0, 7); ctx.fill();
      const hand = (a, len, c) => { for (let s = 0; s <= len; s++) px(ccx + Math.round(Math.sin(a) * s) - 0.5, ccy - Math.round(Math.cos(a) * s) - 0.5, 1, 1, c); };
      hand((hour % 12) / 12 * Math.PI * 2, 4, C.ink); hand(now.getMinutes() / 60 * Math.PI * 2, 6, C.ink);
    }
    wallArt();
    // Plant
    const pl = placed.plant != null ? placed.plant : W - 62;
    px(pl, WALL - 12, 10, 12, '#6b4a2b'); px(pl - 1, WALL - 13, 12, 2, '#7a5634');
    [[-4, -10], [0, -14], [4, -10], [-2, -18], [3, -16]].forEach(([dx, dy], i) => {
      const sway = Math.round(Math.sin(frame / 10 + i));
      for (let s = 0; s < 6; s++) px(pl + 5 + dx * s / 6 + (s > 3 ? sway : 0), WALL - 13 + dy * s / 6, 2, 2, i % 2 ? '#3f7a3a' : '#4f8f46');
    });
    // Ivy along the ceiling: long draping strands over bare wall, short ones over the boards.
    const overBoard = x => Object.values(wallBoards).some(b => b.x != null && x > b.x - 3 && x < b.x + b.w + 3) || (wallClock != null && Math.abs(x - wallClock) < 14);
    for (let x = 2; x < W - 4; x += 3) {
      const r = rand(x * 1.31), long = !overBoard(x) && r > 0.55;
      const len = long ? 6 + Math.floor(rand(x * 7.7) * 22) : 1 + Math.floor(r * 4);
      const sway = still ? 0 : Math.round(Math.sin(frame / 14 + x * 0.3) * 0.7);
      for (let s = 0; s < len; s++) {
        const dx = (s > len / 2 ? sway : 0) + (s % 4 < 2 ? 0 : 1);
        px(x + dx, s + 1, 1, 1, '#2f5a2c');
        if (s % 2 === 1) px(x + dx + (s % 4 < 2 ? -1 : 1), s, 2, 2, (x + s) % 5 ? '#4f8f46' : '#6aaa52');
      }
    }
    // Little pots on the wainscot ledge, wherever the wall is clear.
    for (let x = 30; x < W - 60; x += 47) {
      if (overBoard(x) || rand(x * 0.91) < 0.35) continue;
      const y = WALL - 19;
      px(x, y - 5, 6, 5, rand(x) > 0.5 ? '#b5653a' : '#d9cfbf'); px(x - 1, y - 6, 8, 1, '#8a4a2a');
      pattern(x - 2, y - 11, ['..#.#.#...', '.##.#.##..', '#..###..#.', '..#####...', '...###....'], '#4f8f46');
    }
    // A string of warm bulbs swagged between the pendants.
    stringLights().forEach(([bx, by, c, k]) => { px(bx, by, 2, 2, (still || (frame + k * 5) % 37 > 2) ? c : '#5a4024'); });
    // Pendant lamps: brass cord, a wide shade, a hot bulb under it.
    lamps().forEach(lx => { px(lx, 0, 1, 7, '#5a4a32'); px(lx - 4, 7, 9, 1, '#6b5228'); px(lx - 6, 8, 13, 3, '#3a2a18'); px(lx - 6, 8, 13, 1, C.gold);
      px(lx - 3, 11, 7, 1, '#ffe2a8'); px(lx - 1, 12, 3, 1, '#fff3d0'); });
    return phase;
  }

  // The coffee bar at the right end: a chalk menu, jars on a shelf, an espresso machine that steams
  // while anyone works, and a pastry dome.
  function coffeeBar(t, agents) {
    const x = W - 44, top = WALL - 22, busy = agents.some(a => BUSY.has(a.activity));
    px(x + 2, 12, 36, 28, '#6b4a2b'); px(x + 3, 13, 34, 26, '#1f2622');
    px(x + 7, 16, 18, 1, '#f2f6f2'); [21, 25, 29, 33].forEach((y, i) => { px(x + 7, y, 16 + (i % 2) * 6, 1, '#9fb0a4'); px(x + 30, y, 4, 1, '#f9d976'); });
    px(x, 48, 40, 2, '#7a5030');
    ['#c9963a', '#8a5a32', '#e9e3d4', '#a8743f', '#d9893a'].forEach((c, i) => { px(x + 3 + i * 7, 42, 5, 6, c); px(x + 3 + i * 7, 41, 5, 1, '#3a2a18'); });
    px(x + 6, top - 6, 18, 14, '#b9b4aa'); px(x + 6, top - 6, 18, 2, '#e0dbd0'); px(x + 8, top - 2, 14, 4, '#3a3631');
    px(x + 10, top + 2, 2, 3, '#3a3631'); px(x + 18, top + 2, 2, 3, '#3a3631'); px(x + 20, top - 4, 2, 2, C.goldHi);
    px(x + 9, top + 5, 4, 3, '#efe6d2'); px(x + 17, top + 5, 4, 3, '#efe6d2');
    if (busy && !still) for (let i = 0; i < 3; i++) { const p = ((t + i * 4) % 12) / 12; ctx.globalAlpha = 0.6 * (1 - p); px(x + 11 + i * 3 + Math.round(Math.sin(p * 6)), top - 8 - p * 12, 1, 2, '#efe6d2'); }
    ctx.globalAlpha = 1;
    px(x + 28, top + 1, 9, 7, '#cfe3e8'); px(x + 29, top, 7, 1, '#cfe3e8'); px(x + 30, top + 5, 5, 2, '#c9963a'); px(x + 32, top - 1, 1, 1, '#efe6d2');
    px(x - 2, top + 8, 44, 4, '#a8743f'); px(x - 2, top + 8, 44, 1, '#c48a4c');
    px(x, top + 12, 40, 28, '#5a3820'); for (let i = 1; i < 4; i++) px(x + i * 10, top + 12, 1, 28, '#4a2e18');
    px(x, top + 12, 40, 1, '#3a2414');
  }

  // ── A desk and whoever sits at it ──
  function screen(x, y, a, t, agent) {
    const sw = 16, sh = 10;
    px(x, y, sw, sh, a ? C.screen : '#0a0a09');
    if (!a) return;
    const act = a.activity;
    if (act === 'asleep') return;
    if (act === 'typing' || act === 'working') {
      for (let i = 0; i < 5; i++) {
        const w = 3 + Math.floor(rand(i + Math.floor(t / 2)) * 10);
        px(x + 1 + (i % 2) * 2, y + 1 + i * 2, Math.min(w, sw - 3), 1, i === 4 ? C.green : '#4f8f6a');
      }
      if (t % 4 < 2) px(x + 2 + Math.floor(rand(Math.floor(t / 2)) * 10), y + 9, 2, 1, C.goldHi);
    } else if (act === 'writing') {
      px(x + 1, y + 1, sw - 2, sh - 2, '#e9e3d4');
      const lines = 1 + (Math.floor(t / 3) % 4);
      for (let i = 0; i < lines; i++) px(x + 3, y + 2 + i * 2, i === lines - 1 ? 2 + (t % 8) : 10, 1, '#5a5245');
    } else if (act === 'reading') {
      px(x + 1, y + 1, sw - 2, sh - 2, '#e9e3d4');
      const off = Math.floor(t / 4) % 2;
      for (let i = 0; i < 4; i++) px(x + 3, y + 2 + i * 2 - off + 1, 9 - (i % 2) * 3, 1, '#8a8070');
    } else if (act === 'browsing') {
      px(x + 1, y + 1, sw - 2, 2, '#3b4152'); px(x + 2, y + 1, 2, 1, C.red);
      px(x + 1, y + 3, sw - 2, sh - 4, '#dfe7ef');
      ctx.fillStyle = '#5d8fc9'; ctx.beginPath(); ctx.arc(x + 8, y + 6, 2.5, 0, 7); ctx.fill();
      px(x + 7 + Math.round(Math.sin(t / 3) * 3), y + 5 + Math.round(Math.cos(t / 3)), 1, 1, C.ink);
    } else if (act === 'looking') {
      px(x + 1, y + 1, sw - 2, sh - 2, '#a9c9e6');
      pattern(x + 3, y + 3, ['...#.....', '..###..#.', '.#####.##', '#########'], '#3f6a3a');
      px(x + 11, y + 2, 2, 2, C.goldHi);
    } else if (act === 'delegating' || act === 'helpers') {
      // Handing out work, or waiting on helpers: one box per helper, the active one blinking.
      for (let i = 0; i < 3; i++) px(x + 2 + i * 5, y + 3, 3, 3, i === t % 3 ? C.goldHi : '#4a4a40');
      px(x + 2, y + 7, 13, 1, '#4a4a40');
    } else if (act === 'thinking') {
      for (let i = 0; i < 3; i++) px(x + 4 + i * 3, y + 5, 2, 1, (Math.floor(t / 3) % 3) === i ? C.goldHi : '#4a4a40');
    } else if (act === 'your_turn') {
      px(x + 2, y + 2, 12, 5, '#1b2a22');
      px(x + 3, y + 3, 8, 1, '#4f8f6a'); px(x + 3, y + 5, 5, 1, '#4f8f6a');
      if (t % 6 < 3) px(x + 9, y + 5, 2, 1, C.goldHi);
    } else {
      // Idle: a gold square bouncing around a screensaver.
      const bx = Math.abs((t % 22) - 11), by = Math.abs((t % 12) - 6);
      px(x + 1 + bx, y + 1 + by * 0.9, 3, 2, a.color || C.gold);
    }
  }

  function blob(x, y, a, t, scale = 1) {
    // x,y = top-left of the 14x15 body.
    const body = a.color;
    const hi = shade(body, 0.22), lo = shade(body, -0.25);
    const act = a.activity;
    const bob = BUSY.has(act) && !still ? (t % 4 < 2 ? 0 : 1) : 0;
    const slump = act === 'asleep' ? 2 : 0;
    y += bob + slump;
    px(x + 2, y, 10, 1, body); px(x + 1, y + 1, 12, 1, body); px(x, y + 2, 14, 13, body);
    px(x + 1, y + 2, 1, 10, hi); px(x + 12, y + 3, 1, 11, lo);
    // Hermes agents: a little antenna in their own colour.
    if (a.kind === 'hermes') {
      px(x + 6, y - 3, 1, 3, lo); px(x + 5, y - 5, 3, 2, hi);
    } else if (a.kind === 'claude') {
      pattern(x + 5, y - 3, ['#.#', '.#.', '#.#'], '#f2c6a8');
    } else {
      px(x + 2, y - 1, 10, 2, '#2b2924'); px(x + 1, y + 1, 12, 1, '#2b2924');
    }
    // Face
    const eyeY = y + 6;
    const look = act === 'thinking' ? -1 : 0;
    const shift = act === 'reading' ? (t % 8 < 4 ? -1 : 0) : act === 'your_turn' ? 0 : 0;
    const blink = !still && (t + Math.floor(x)) % 37 === 0;
    const eye = a.kind === 'codex' ? C.pupil : C.eye;
    if (act === 'asleep' || blink) {
      px(x + 3, eyeY + 1, 3, 1, eye); px(x + 8, eyeY + 1, 3, 1, eye);
    } else {
      px(x + 3, eyeY, 3, 3, eye); px(x + 8, eyeY, 3, 3, eye);
      if (a.kind !== 'codex') { px(x + 4 + shift, eyeY + 1 + look, 1, 1, C.pupil); px(x + 9 + shift, eyeY + 1 + look, 1, 1, C.pupil); }
    }
    if (act === 'your_turn') px(x + 6, eyeY + 4, 2, 1, C.pupil);          // a small "o"
    if (act === 'idle') px(x + 5, eyeY + 4, 4, 1, 'rgba(0,0,0,.35)');      // content little smile line
    // Cheeks
    if (a.kind === 'hermes') { px(x + 2, eyeY + 3, 2, 1, 'rgba(255,255,255,.18)'); px(x + 10, eyeY + 3, 2, 1, 'rgba(255,255,255,.18)'); }
    return { body, y };
  }

  function arms(x, y, a, t, body, deskY) {
    const act = a.activity;
    if (act === 'your_turn') {
      // Right arm up, waving, outlined so it reads against the chair.
      const wave = still ? 0 : (t % 6 < 3 ? 0 : 1);
      px(x + 13, y + 1, 4, 9, '#0c0b09');
      px(x + 14, y + 2, 2, 8, body);
      px(x + 13 + wave, y - 3, 4, 4, '#0c0b09'); px(x + 14 + wave, y - 2, 2, 2, body);
      px(x + 1, deskY - 2, 3, 2, body);
    } else if (act === 'typing' || act === 'writing' || act === 'working') {
      const l = still ? 0 : (t % 2), r = still ? 0 : ((t + 1) % 2);
      px(x + 1, deskY - 2 - l, 3, 2, body); px(x + 10, deskY - 2 - r, 3, 2, body);
    } else if (act === 'looking') {
      px(x + 10, deskY - 6, 3, 5, body);
      ctx.strokeStyle = C.goldHi; ctx.lineWidth = 1; ctx.beginPath(); ctx.arc(x + 15.5, deskY - 9.5, 2.5, 0, 7); ctx.stroke();
      px(x + 13, deskY - 7, 1, 2, '#6b4a2b');
    } else if (act === 'reading') {
      px(x + 2, deskY - 6, 10, 5, '#efe6d2'); px(x + 6, deskY - 6, 1, 5, '#b9ae98');
      px(x, deskY - 4, 3, 3, body); px(x + 11, deskY - 4, 3, 3, body);
    } else if (act === 'asleep') {
      px(x - 1, deskY - 2, 6, 2, body); px(x + 9, deskY - 2, 6, 2, body);
    } else if (act === 'thinking') {
      px(x + 11, y + 9, 3, 4, body); px(x + 9, y + 11, 3, 2, body);
    } else if (act === 'helpers') {
      // Arms folded, foot-tapping patience, watching its helpers work.
      px(x + 2, y + 10, 10, 2, body); px(x + 2, y + 9, 2, 1, body); px(x + 10, y + 9, 2, 1, body);
    } else {
      px(x - 1, deskY - 2, 3, 2, body); px(x + 12, deskY - 2, 3, 2, body);
    }
  }

  function bubble(x, y, a, t) {
    const act = a.activity;
    if (act === 'your_turn') {
      const pulse = still ? 0 : (t % 8 < 4 ? 0 : 1);
      px(x - 1, y - 1 - pulse, 11, 11, C.gold);
      px(x, y - pulse, 9, 9, '#fbf3df');
      px(x + 2, y + 9 - pulse, 2, 2, '#fbf3df'); px(x + 1, y + 11 - pulse, 1, 1, '#fbf3df');
      px(x + 4, y + 2 - pulse, 1, 4, C.ink); px(x + 4, y + 7 - pulse, 1, 1, C.ink);
    } else if (act === 'thinking') {
      const lift = still ? 0 : (t % 10 < 5 ? 0 : -1);
      px(x + 1, y + 10, 2, 2, '#e9e3d4'); px(x + 3, y + 6 + lift, 3, 3, '#e9e3d4');
      px(x + 5, y - 2 + lift, 13, 7, '#e9e3d4'); px(x + 6, y - 3 + lift, 11, 9, '#e9e3d4');
      for (let i = 0; i < 3; i++) px(x + 8 + i * 3, y + 1 + lift, 2, 1, (Math.floor(t / 2) % 3) === i ? C.ink : '#a59c8a');
    } else if (act === 'asleep') {
      for (let i = 0; i < 3; i++) {
        const p = ((t / 2 + i * 6) % 18) / 18;
        const zx = x + 6 + i * 4 + Math.round(Math.sin(p * 6) * 1), zy = y + 8 - p * 14;
        ctx.globalAlpha = 1 - p;
        pattern(zx, zy, ['####', '..#.', '.#..', '####'], '#cfc8b8');
        ctx.globalAlpha = 1;
      }
    } else if (act === 'browsing' && t % 10 < 5) {
      pattern(x + 4, y + 4, ['.##.', '#..#', '..#.', '....', '..#.'], '#cfc8b8');
    }
  }

  // Helpers (subagents) stand on their agent's desk: two to the right of it, one beside the monitor.
  // Each keeps its own colour and carries a light for what it is doing; a helper's own helpers are
  // smaller. Past three, the name plate counts them.
  const HELPER_SPOTS = [50, 57, 26];
  const helperList = a => (a.helpers || []).length ? a.helpers : (a.activity === 'delegating' ? [{ id: a.id + ':helper', activity: 'thinking', depth: 1 }] : []);
  function helpers(x0, deskY, a, t) {
    const list = helperList(a);
    list.slice(0, HELPER_SPOTS.length).forEach((h, i) => {
      const small = (h.depth || 1) > 1, w = small ? 5 : 7, hh = small ? 6 : 8;
      const color = assign(h.id || a.id + ':' + i), act = h.activity || 'working', busy = BUSY.has(act);
      const hx = x0 + HELPER_SPOTS[i] + (small ? 1 : 0);
      const hy = deskY - hh - 1 + (busy && !still ? ((t + i * 2) % 4 < 2 ? 0 : -1) : 0);
      px(hx, hy, w, hh, color); px(hx, hy, 1, hh - 1, shade(color, 0.22)); px(hx + w - 1, hy + 1, 1, hh - 1, shade(color, -0.25));
      const mid = hx + (w >> 1);
      if (h.id === helperSel) {
        // The helper you are reading about: a gold caret bobbing over it and a line under its feet.
        const b = still ? 0 : (frame % 8 < 4 ? 0 : 1);
        px(mid - 2, hy - 11 + b, 5, 1, C.goldHi); px(mid - 1, hy - 10 + b, 3, 1, C.goldHi); px(mid, hy - 9 + b, 1, 1, C.goldHi);
        px(hx - 1, hy + hh + 1, w + 2, 1, C.goldHi);
      }
      px(mid, hy - 2, 1, 2, shade(color, -0.25)); px(mid - 1, hy - 3, 3, 1, shade(color, 0.3));
      if (small) { px(hx + 1, hy + 2, 1, 1, C.eye); px(hx + 3, hy + 2, 1, 1, C.eye); }
      else { px(hx + 1, hy + 3, 2, 2, C.eye); px(hx + 4, hy + 3, 2, 2, C.eye); px(hx + 2, hy + (act === 'thinking' ? 3 : 4), 1, 1, C.pupil); px(hx + 5, hy + (act === 'thinking' ? 3 : 4), 1, 1, C.pupil); }
      px(hx + 1, hy + hh, 2, 1, '#0a0908'); px(hx + w - 3, hy + hh, 2, 1, '#0a0908');
      // What it is doing: a little prop, or dots for thinking.
      if (act === 'thinking') {
        for (let k = 0; k < 3; k++) px(hx + k * 2 + (small ? 0 : 1), hy - 6, 1, 1, (Math.floor(t / 2) + i) % 3 === k ? '#e9e3d4' : '#5a5245');
      } else if (act === 'reading' || act === 'writing') {
        px(hx + 1, hy + hh - 3, w - 2, 2, '#efe6d2');
        if (act === 'writing' && !still && t % 4 < 2) px(hx + w - 2, hy + hh - 4, 1, 1, C.ink);
      } else {
        const lamp = act === 'browsing' || act === 'looking' ? C.cyan : act === 'delegating' ? C.goldHi : C.green;
        if (still || (t + i) % 6 < 4) px(mid, hy - 5, 1, 1, lamp);
      }
    });
    // A note flies over to the newest helper while the agent is handing work out.
    if (a.activity === 'delegating' && list.length && !still) {
      const p = (t % 12) / 12, tx = x0 + HELPER_SPOTS[0], fx = x0 + 40;
      px(fx + (tx - fx) * p, deskY - 14 - Math.sin(p * 3) * 4, 3, 2, '#efe6d2');
    }
  }

  // The boss, 28 wide and 32 tall, drawn from rectangles: hair, face, collar, suit, gold tie.
  function boss(x, y, state, t) {
    const shut = state === 'asleep' || (!still && t % 41 === 0);
    px(x + 7, y + 2, 14, 3, C.hair); px(x + 6, y + 4, 16, 4, C.hair);
    px(x + 8, y + 6, 12, 14, C.skin); px(x + 8, y + 17, 12, 3, C.skinLo);
    px(x + 6, y + 9, 2, 5, C.skin); px(x + 20, y + 9, 2, 5, C.skin);
    px(x + 8, y + 6, 12, 2, C.hair);
    if (shut) { px(x + 10, y + 13, 3, 1, C.hair); px(x + 15, y + 13, 3, 1, C.hair); }
    else { px(x + 10, y + 12, 3, 3, C.eye); px(x + 15, y + 12, 3, 3, C.eye); px(x + 11, y + 13, 2, 2, C.pupil); px(x + 16, y + 13, 2, 2, C.pupil); }
    px(x + 12, y + 17, 4, 1, state === 'your_turn' ? C.skinLo : '#8a4a3a');
    px(x + 11, y + 20, 6, 2, C.skin);
    px(x + 3, y + 22, 22, 10, C.suit); px(x + 2, y + 24, 24, 8, C.suit);
    px(x + 3, y + 22, 22, 1, C.suitHi); px(x + 4, y + 23, 2, 9, C.suitLo); px(x + 22, y + 23, 2, 9, C.suitLo);
    px(x + 10, y + 22, 8, 3, '#efe6d2'); px(x + 11, y + 25, 6, 1, '#efe6d2');
    px(x + 13, y + 24, 2, 8, C.gold); px(x + 12, y + 24, 4, 2, C.goldHi);
  }
  // ── The boss's front desk, facing the floor. The boss mirrors the room:
  //    busy while anyone works, hand up when someone is waiting on you, asleep when everyone is. ──
  function bossState(agents) {
    if (!agents.length) return 'idle';
    if (agents.every(a => a.bed)) return 'asleep';
    agents = agents.filter(a => !a.bed);
    if (agents.some(a => a.activity === 'your_turn')) return 'your_turn';
    if (agents.some(a => BUSY.has(a.activity))) return 'watching';
    return agents.every(a => a.activity === 'asleep') ? 'asleep' : 'idle';
  }
  function bossDesk(agents, t, phase) {
    const { x: cx, y: dy } = bossSpot, x0 = cx - 50, state = bossState(agents);
    const sel = selected === 'boss';
    // Rug under the boss desk
    ctx.globalAlpha = sel ? 0.55 : 0; ctx.fillStyle = C.goldHi;
    ctx.beginPath(); ctx.ellipse(cx, dy + 24, 64, 9, 0, 0, 7); ctx.fill(); ctx.globalAlpha = 1;
    // High-back chair in gold-trimmed leather
    px(cx - 15, dy - 40, 30, 36, '#3a1f26'); px(cx - 14, dy - 39, 28, 2, '#4d2a33'); px(cx - 15, dy - 40, 30, 1, C.gold);
    // The boss: charcoal suit, gold tie, bobbing while the floor works.
    const bob = !still && (state === 'watching' || state === 'your_turn') && t % 6 < 3 ? 1 : 0;
    const slump = state === 'asleep' ? 3 : 0;
    const mx = cx - 14, my = dy - 33 + bob + slump;
    boss(mx, my, state, t);
    // Desk: wider, darker wood, gold inlay, a name plate.
    px(x0, dy, 100, 4, '#8a6238'); px(x0, dy + 4, 100, 1, C.woodLo);
    px(x0 + 2, dy + 5, 96, 16, '#6b4a2b'); px(x0 + 2, dy + 5, 96, 1, C.gold);
    px(x0 + 8, dy + 10, 84, 1, '#5a3f26'); px(x0 + 46, dy + 13, 8, 2, C.gold);
    px(x0 + 4, dy + 21, 4, 4, C.woodDark); px(x0 + 92, dy + 21, 4, 4, C.woodDark);
    px(cx - 9, dy - 4, 18, 4, C.gold); px(cx - 8, dy - 3, 16, 2, '#14120f'); px(cx - 5, dy - 2, 10, 1, C.goldHi);
    // Hands on the desk; one goes up when someone is waiting on you.
    if (state === 'your_turn') {
      const wave = still ? 0 : (t % 6 < 3 ? 0 : 1);
      px(mx + 28, my + 2, 4, 14, '#0c0b09'); px(mx + 29, my + 3, 2, 13, C.suitHi);
      px(mx + 28 + wave, my - 3, 5, 5, '#0c0b09'); px(mx + 29 + wave, my - 2, 3, 3, C.suitHi);
      bubble(mx + 36, my + 2, { activity: 'your_turn' }, t);
    } else {
      px(mx - 2, dy - 2, 5, 2, C.suitHi); px(mx + 25, dy - 2, 5, 2, C.suitHi);
    }
    if (state === 'asleep') bubble(mx + 20, my - 8, { activity: 'asleep' }, t);
    // A gold desk lamp and a tiny stack of reports from the floor.
    px(x0 + 86, dy - 12, 1, 12, C.metal); px(x0 + 82, dy - 14, 8, 3, C.gold);
    if (phase !== 'day') { ctx.globalAlpha = 0.25; ctx.fillStyle = C.goldHi; ctx.beginPath(); ctx.ellipse(x0 + 86, dy + 1, 12, 3, 0, 0, 7); ctx.fill(); ctx.globalAlpha = 1; }
    // A ginger cat curled up asleep beside the desk, breathing.
    const kx = x0 - 22, ky = dy + 12, br = still ? 0 : (t % 10 < 5 ? 0 : 1);
    pattern(kx, ky - br, ['.#..#...........', '.####...........', '######.#######..', '##############..', '.##############.', '..##############', '...#############', '..............##'], '#d9893a');
    pattern(kx, ky - br, ['................', '................', '.......#..#..#..', '........#..#..#.', '................', '................', '................', '................'], '#a85e22');
    px(kx + 1, ky + 3 - br, 1, 1, '#2a1a0c'); px(kx + 4, ky + 3 - br, 1, 1, '#2a1a0c'); px(kx + 2, ky + 4 - br, 2, 1, '#f2c6a8');
    px(kx + 2, ky + 1 - br, 1, 1, '#f2c6a8');
    const reports = Math.min(5, agents.filter(a => BUSY.has(a.activity)).length);
    for (let i = 0; i < reports; i++) px(x0 + 10 + (i % 2), dy - 2 - i * 2, 12, 2, i % 2 ? '#e9e3d4' : '#d9d0bd');
  }

  // A cafe table: walnut top on two legs, a wooden chair, a monitor, a brass lamp that is always on.
  function desk(spot, a, t, phase) {
    const { x: cx, y: dy } = spot, x0 = cx - 32;
    const sel = a && selected === a.id;
    // A warm pool of lamplight under every table; gold when it needs you or is selected.
    ctx.globalAlpha = 0.16; ctx.fillStyle = '#ffb45e'; ctx.beginPath(); ctx.ellipse(cx - 2, dy + 22, 40, 6, 0, 0, 7); ctx.fill(); ctx.globalAlpha = 1;
    if (a && (a.activity === 'your_turn' || sel)) {
      ctx.globalAlpha = sel ? 0.5 : 0.18 + (still ? 0 : 0.1 * Math.sin(t / 2));
      ctx.fillStyle = sel ? C.goldHi : C.gold;
      ctx.beginPath(); ctx.ellipse(cx, dy + 22, 40, 6, 0, 0, 7); ctx.fill();
      ctx.globalAlpha = 1;
    }
    // Chair back, then the agent, then the table in front of them.
    const chx = cx + 1, chairTop = dy - 20;
    px(chx - 2, chairTop, 20, 3, '#6b4426'); px(chx - 2, chairTop, 20, 1, '#8a5a32');
    px(chx - 1, chairTop + 3, 2, 14, '#5a3820'); px(chx + 15, chairTop + 3, 2, 14, '#5a3820'); px(chx + 1, chairTop + 7, 14, 1, '#5a3820');
    if (a) px(chx + 4, chairTop + 1, 8, 1, a.color);
    let top = dy - 16;
    if (a) { const { y } = blob(cx + 2, top, a, t); top = y; }
    px(x0, dy, 64, 3, '#a8743f'); px(x0, dy, 64, 1, '#c48a4c'); px(x0, dy + 3, 64, 2, '#6b4426');
    px(x0 + 4, dy + 5, 3, 17, '#4a2e18'); px(x0 + 57, dy + 5, 3, 17, '#4a2e18'); px(x0 + 4, dy + 15, 56, 2, '#5a3820');
    px(x0 + 10, dy + 11, 3, 4, '#7a3a2a'); px(x0 + 13, dy + 12, 2, 3, '#3f6a5a'); px(x0 + 15, dy + 10, 3, 5, '#c9a46a'); px(x0 + 44, dy + 12, 6, 3, '#8a5a32');
    px(x0 + 24, dy + 6, 16, 4, C.gold); px(x0 + 25, dy + 7, 14, 2, '#241c12'); if (a) px(x0 + 26, dy + 7, 3, 2, a.color);
    const mx = x0 + 5, my = dy - 15;
    px(mx - 1, my - 1, 20, 13, C.bezel); px(mx + 8, my + 12, 2, 2, C.metal); px(mx + 4, dy - 1, 10, 1, C.metal);
    screen(mx + 1, my + 0.5, a, t, a);
    px(x0 + 29, dy - 9, 1, 9, '#8a6a3a'); px(x0 + 27, dy - 1, 5, 1, '#8a6a3a'); px(x0 + 26, dy - 11, 7, 2, '#c9963a'); px(x0 + 27, dy - 9, 5, 1, '#ffe2a8');
    ctx.globalAlpha = phase === 'day' ? 0.14 : 0.28; ctx.fillStyle = C.goldHi; ctx.beginPath(); ctx.ellipse(x0 + 29.5, dy + 1, 10, 2, 0, 0, 7); ctx.fill(); ctx.globalAlpha = 1;
    if (a && a.activity !== 'asleep') {
      ctx.globalAlpha = phase === 'night' ? 0.22 : 0.08; ctx.fillStyle = a.activity === 'your_turn' ? C.goldHi : '#9fd0c0';
      ctx.fillRect(mx - 2, dy, 22, 3); ctx.globalAlpha = 1;
    }
    if (a) { px(cx + 2, dy - 1, 14, 2, '#3a3631'); px(cx + 3, dy - 1, 12, 1, '#57524a'); }
    if (a) arms(cx + 2, top, a, t, shade(a.color, 0.3), dy);
    const crowd = a ? helperList(a).length : 0;
    // A latte in a cup and saucer, steaming while it is fresh.
    if (!crowd) { px(x0 + 53, dy - 1, 8, 1, '#efe6d2'); px(x0 + 54, dy - 5, 5, 4, a ? '#efe6d2' : '#8a8578'); px(x0 + 55, dy - 5, 3, 1, '#c9963a'); px(x0 + 59, dy - 4, 1, 2, '#efe6d2'); }
    if (a && !crowd && (a.activity === 'idle' || a.activity === 'your_turn') && !still) {
      for (let i = 0; i < 2; i++) { const p = ((t + i * 5) % 10) / 10; ctx.globalAlpha = 0.6 * (1 - p); px(x0 + 55 + i * 2 + Math.round(Math.sin(p * 5)), dy - 7 - p * 7, 1, 2, '#e9e3d4'); }
      ctx.globalAlpha = 1;
    }
    if (a) { helpers(x0, dy, a, t); bubble(cx + 15, top - 16, a, t); }
  }

  function night(phase, spots, agents) {
    if (phase === 'day') {
      ctx.globalCompositeOperation = 'lighter';
      lamps().forEach(lx => { const g = ctx.createRadialGradient(lx, 12, 1, lx, 12, 40); g.addColorStop(0, 'rgba(255,190,110,.10)'); g.addColorStop(1, 'rgba(0,0,0,0)'); ctx.fillStyle = g; ctx.fillRect(lx - 44, 0, 88, 56); });
      ctx.globalCompositeOperation = 'source-over';
      return;
    }
    ctx.fillStyle = phase === 'night' ? 'rgba(14,8,4,.34)' : 'rgba(30,14,10,.16)';
    ctx.fillRect(0, 0, W, H);
    ctx.globalCompositeOperation = 'lighter';
    stringLights().forEach(([bx, by, c, k]) => {
      if (!still && (frame + k * 5) % 37 <= 2) return;
      const g = ctx.createRadialGradient(bx + 1, by + 1, 0, bx + 1, by + 1, 7);
      g.addColorStop(0, 'rgba(255,190,110,.32)'); g.addColorStop(1, 'rgba(0,0,0,0)');
      ctx.fillStyle = g; ctx.fillRect(bx - 6, by - 6, 14, 14);
    });
    spots.forEach((s, i) => {
      const a = agents[i];
      if (!a || a.activity === 'asleep') return;
      const g = ctx.createRadialGradient(s.x - 18, s.y - 8, 1, s.x - 18, s.y - 8, 28);
      g.addColorStop(0, a.activity === 'your_turn' ? 'rgba(249,217,118,.30)' : 'rgba(120,200,170,.18)');
      g.addColorStop(1, 'rgba(0,0,0,0)');
      ctx.fillStyle = g; ctx.fillRect(s.x - 50, s.y - 40, 64, 64);
    });
    lamps().forEach(lx => {
      const g = ctx.createRadialGradient(lx, 12, 1, lx, 12, 54);
      g.addColorStop(0, 'rgba(255,190,110,.26)'); g.addColorStop(1, 'rgba(0,0,0,0)');
      ctx.fillStyle = g; ctx.fillRect(lx - 56, 0, 112, 68);
      // A soft cone of light down onto the floor.
      const f = ctx.createRadialGradient(lx, WALL + 40, 2, lx, WALL + 40, 60);
      f.addColorStop(0, 'rgba(255,170,80,.10)'); f.addColorStop(1, 'rgba(0,0,0,0)');
      ctx.fillStyle = f; ctx.fillRect(lx - 62, WALL - 20, 124, 120);
    });
    ctx.globalCompositeOperation = 'source-over';
  }

  // One table per agent on the floor.
  const seatCount = agents => agents.length;
  let lastSpots = [];
  function draw() {
    const agents = (data && data.agents) || [];
    const n = seatCount(agents);
    if (geo.n !== n) fit();
    const spots = layout(n);
    lastSpots = spots;
    const now = new Date();
    if (hourOverride !== null) now.setHours(hourOverride);
    const t = still ? 0 : frame;
    const phase = room(now);
    cafeBack(t, agents);
    coffeeBar(t, agents);
    labStaff(t);
    // Back row first so the front row overlaps it.
    // An agent whose plan is out of usage is not at its desk: it is in a bunk (or walking there).
    spots.forEach((s, i) => {
      const away = agents[i] && (agents[i].bed || walking.has(agents[i].id) || awayToBoss(agents[i].id));
      desk(s, away ? undefined : agents[i], t + i * 3, phase);
    });
    bossDesk(agents, t, phase);
    bossQueue(agents, spots, t);
    cafeFront(t);
    bunks(agents, spots, t);
    night(phase, spots, agents.map(a => (a.bed || awayToBoss(a.id) ? null : a)));
    particles(t);
    if (error) { ctx.fillStyle = 'rgba(6,6,8,.55)'; ctx.fillRect(0, 0, W, H); }
    placeDesks(spots, agents);
  }

  // ── The boards on the wall, the lab staff in front of them, and the bunk beds ──
  let wallBoards = { tasks: {}, ideas: {}, lab: {} }, wallClock = null;
  let board = null, usage = null;
  const walking = new Map();   // agent id -> { dir: 'in'|'out', at: frame }
  const WALK = 30;
  function wallArt() {
    const T = wallBoards.tasks, I = wallBoards.ideas, L = wallBoards.lab;
    // Task board: cork in a wood frame, with a header strip; the cards are written on in HTML.
    if (T.x != null) {
      px(T.x, T.y, T.w, T.h, '#6b4a2b'); px(T.x + 2, T.y + 2, T.w - 4, T.h - 4, '#1f2622');
      for (let k = 0; k < T.w / 3; k++) px(T.x + 3 + Math.floor(rand(k * 2.3) * (T.w - 6)), T.y + 3 + Math.floor(rand(k * 4.1) * (T.h - 6)), 2, 1, '#28302b');
      px(T.x, T.y + T.h, T.w, 2, '#5a3f26');
    }
    // Idea board: a whiteboard with a marker tray.
    if (I.x != null) {
      px(I.x, I.y, I.w, I.h, '#6b4a2b'); px(I.x + 2, I.y + 2, I.w - 4, I.h - 4, '#232420');
      for (let k = 0; k < I.w / 3; k++) px(I.x + 3 + Math.floor(rand(k * 3.9) * (I.w - 6)), I.y + 3 + Math.floor(rand(k * 1.3) * (I.h - 6)), 2, 1, '#2d2e29');
      px(I.x + 4, I.y + I.h, I.w - 8, 2, '#5a3f26'); px(I.x + 8, I.y + I.h - 1, 3, 1, '#efe6d2'); px(I.x + 13, I.y + I.h - 1, 3, 1, '#f2c6a8');
    }
    // The lab: a green chalkboard, a beaker shelf under it (they bubble while the researcher works).
    if (L.x != null) {
      px(L.x, L.y, L.w, L.h, '#6b4a2b'); px(L.x + 2, L.y + 2, L.w - 4, L.h - 4, '#24402f');
      for (let k = 0; k < L.w / 3; k++) px(L.x + 3 + Math.floor(rand(k * 5.3) * (L.w - 6)), L.y + 3 + Math.floor(rand(k * 1.7) * (L.h - 6)), 2, 1, '#2c4a37');
      px(L.x, L.y + L.h + 4, L.w, 2, '#5a3f26');
      [['#86cbc2', 6], ['#e46a8a', 18], ['#9fd07f', 30]].forEach(([c, dx], k) => {
        const bx = L.x + dx, by = L.y + L.h - 3;
        px(bx + 1, by + 4, 2, 3, '#cfd8dc'); px(bx, by + 7, 4, 4, '#cfd8dc'); px(bx + 1, by + 8, 2, 3, c);
        if (running('research') && !still && (frame + k * 4) % 10 < 5) px(bx + 1, by + 2 - ((frame + k * 3) % 4), 1, 1, c);
      });
    }
  }
  // Every agent has a first name (given by the server when it sits down), written in its colour.
  const nameOf = a => a.name || (a.title || 'Agent').split(/\s+/)[0];
  const nameTag = a => `<b class="agent-name" style="color:${esc(nameColor(a.color))}">${esc(nameOf(a))}</b>`;
  // Lift dark colours a little so the name reads on the dark plates.
  const nameColor = c => { if (!c || c[0] !== '#') return c; const n = parseInt(c.slice(1), 16), l = (0.3 * (n >> 16) + 0.59 * ((n >> 8) & 255) + 0.11 * (n & 255)) / 255; return l < 0.5 ? shade(c, 0.35) : c; };
  // The task board, by agent: each agent's own to-do list (what it is working through right now, read
  // from its chat) plus the board tasks handed to it; unassigned board tasks last.
  function tasksByAgent() {
    const b = board || { tasks: [] }, agents = (data && data.agents) || [];
    const groups = agents.map(a => ({
      agent: a,
      own: (a.todos || []).filter(x => x.status !== 'dropped'),
      board: b.tasks.filter(t => t.agent === a.id)
    }));
    const known = new Set(agents.map(a => a.id));
    const loose = b.tasks.filter(t => !t.agent || !known.has(t.agent));
    return { groups, loose };
  }
  const STEP = { done: '✓', doing: '▸', todo: '○' };
  // The writing on the boards: the real items, always visible. Rendered inside each board's button.
  function boardWriting(kind) {
    const b = board || { project: {}, tasks: [], ideas: [], suggestions: [], runs: {} };
    const li = (cls, mark, text, extra = '') => `<li class="${cls}"><i>${mark}</i><span>${esc(text)}</span>${extra}</li>`;
    if (kind === 'tasks') {
      // One column of cards per agent, headed by its name in its colour: what it is doing first.
      const { groups, loose } = tasksByAgent();
      const rank = { doing: 0, todo: 1, done: 2 };
      const cols = groups.map(g => {
        const items = [...g.own.map(x => ({ s: x.status, t: x.text })), ...g.board.map(t => ({ s: t.status === 'done' ? 'done' : t.status === 'assigned' ? 'doing' : 'todo', t: t.title }))]
          .sort((x, y) => rank[x.s] - rank[y.s]);
        if (!items.length) return '';
        const open = items.filter(x => x.s !== 'done'), shown = (open.length ? open : items).slice(0, 2);
        return `<li class="bw-col"><h6 style="color:${esc(nameColor(g.agent.color))}">${esc(nameOf(g.agent))}</h6><ol>${shown.map(x => `<li class="${x.s === 'done' ? 'done' : x.s === 'doing' ? 'with' : 'todo'}"><i>${STEP[x.s]}</i><span>${esc(x.t)}</span></li>`).join('')}</ol></li>`;
      }).filter(Boolean);
      if (loose.length) cols.push(`<li class="bw-col"><h6>Open</h6><ol>${loose.filter(t => t.status !== 'done').slice(0, 2).map(t => li(t.status === 'done' ? 'done' : 'todo', t.status === 'done' ? '✓' : '○', t.title)).join('')}</ol></li>`);
      const all = groups.reduce((n, g) => n + g.own.length + g.board.length, 0) + loose.length;
      const done = groups.reduce((n, g) => n + g.own.filter(x => x.status === 'done').length + g.board.filter(t => t.status === 'done').length, 0) + loose.filter(t => t.status === 'done').length;
      const name = (b.project && b.project.name) || 'Tasks';
      return `<div class="bw bw-tasks"><h5>${esc(name)}<small>${done}/${all}</small></h5><ul class="bw-cols">${cols.join('') || `<li class="hint"><span>Tasks show up as agents plan their work</span></li>`}</ul></div>`;
    }
    if (kind === 'ideas') {
      const notes = ['#f9d976', '#ff9fc5', '#9fe0d0', '#c9b8ff'];
      const body = b.ideas.length ? b.ideas.map((x, k) => `<li class="${x.new ? 'new' : ''}" style="--note:${notes[k % 4]}"><span>${esc(x.title)}</span></li>`).join('')
        : `<li class="hint"><span>${running('brainstorm') ? 'Thinking…' : 'Brainstorm ideas'}</span></li>`;
      return `<div class="bw bw-ideas"><h5>Ideas${running('brainstorm') ? '<small>thinking…</small>' : ''}</h5><ul>${body}</ul></div>`;
    }
    const body = b.suggestions.length ? b.suggestions.map(x => li(x.new ? 'new' : '', '–', x.title)).join('')
      : `<li class="hint"><span>${running('research') ? 'Researching…' : 'Send the researcher'}</span></li>`;
    return `<div class="bw bw-lab"><h5>The lab${running('research') ? '<small>researching…</small>' : ''}</h5><ul>${body}</ul></div>`;
  }
  const running = kind => !!(board && board.runs && board.runs[kind] && board.runs[kind].status === 'running');
  // The brainstormer (a gold one with a light bulb) and the researcher (white coat, goggles) stand
  // against the wall under their boards, clear of the desks; they work when their run is going and idle in place otherwise.
  function labStaff(t) {
    const I = wallBoards.ideas, L = wallBoards.lab;
    if (I.x != null) {
      const on = running('brainstorm'), x = I.x + 34, y = WALL - 14 + (on && !still && t % 6 < 3 ? -1 : 0);
      px(x, y, 11, 12, '#e0b84a'); px(x, y, 1, 11, '#f2d27a'); px(x + 10, y + 1, 1, 11, '#b8902e');
      px(x + 2, y + 4, 2, 2, C.eye); px(x + 7, y + 4, 2, 2, C.eye); px(x + 3, y + 5, 1, 1, C.pupil); px(x + 8, y + 5, 1, 1, C.pupil);
      px(x + 2, y + 12, 2, 2, '#0a0908'); px(x + 7, y + 12, 2, 2, '#0a0908');
      const lit = on ? (still || t % 8 < 6) : false;
      px(x + 4, y - 7, 3, 4, lit ? C.goldHi : '#6f6a60'); px(x + 4, y - 3, 3, 1, '#8a8578');
      if (lit) { ctx.globalAlpha = 0.25; ctx.fillStyle = C.goldHi; ctx.beginPath(); ctx.arc(x + 5.5, y - 5, 6, 0, 7); ctx.fill(); ctx.globalAlpha = 1; }
      if (on && !still) { const k = t % 16; px(x - 6 + (k < 8 ? 0 : 1), y + 3 - (k % 8 < 4 ? 1 : 0), 3, 2, '#e0b84a'); }   // arm sticking a note
    }
    if (L.x != null) {
      const on = running('research'), x = L.x + 34, y = WALL - 14 + (on && !still && t % 8 < 4 ? -1 : 0);
      px(x, y, 11, 12, '#e8edef'); px(x, y, 1, 11, '#ffffff'); px(x + 10, y + 1, 1, 11, '#b9c3c7');
      px(x + 5, y + 6, 1, 6, '#b9c3c7');
      px(x + 1, y + 3, 9, 3, '#3a3631'); px(x + 2, y + 4, 2, 1, C.cyan); px(x + 7, y + 4, 2, 1, C.cyan);
      px(x + 2, y + 12, 2, 2, '#0a0908'); px(x + 7, y + 12, 2, 2, '#0a0908');
      if (on && !still) {
        // Writing on the chalkboard, then checking a clipboard.
        if (t % 24 < 12) { px(x - 4, y + 2 - (t % 4 < 2 ? 1 : 0), 4, 2, '#e8edef'); px(x - 5, y + 1, 1, 1, '#ffffff'); }
        else { px(x + 11, y + 5, 5, 6, '#c9a46a'); px(x + 12, y + 6, 3, 1, '#efe6d2'); px(x + 12, y + 8, 3, 1, '#efe6d2'); }
      }
    }
  }

  // Bunk beds roll in along the front wall when a plan runs out; its agents walk over and climb in.
  function bedSlots(n) {
    const x0 = 30, y0 = H - 44, slots = [];
    const leftCap = Math.max(0, Math.floor((bossSpot.x - 60 - x0) / 34)) * 2;
    for (let i = 0; i < n; i++) {
      const left = i < leftCap, k = left ? i : i - leftCap, bed = Math.floor(k / 2);
      const bx = left ? x0 + bed * 34 : W - 50 - 22 - 30 - bed * 34;
      slots.push({ bx, by: y0, top: k % 2 === 1, x: bx + 6, y: k % 2 ? y0 + 3 : y0 + 21 });
    }
    return slots;
  }
  function bunks(agents, spots, t) {
    const sleepers = agents.filter(a => a.bed || walking.has(a.id));
    if (!sleepers.length) return;
    const slots = bedSlots(sleepers.length);
    const beds = new Set(slots.map(s => s.bx));
    beds.forEach(bx => {
      const by = slots.find(s => s.bx === bx).by;
      // Frame, two mattresses, pillows, a ladder on the right.
      px(bx, by, 2, 40, '#3e2b1a'); px(bx + 28, by, 2, 40, '#3e2b1a');
      [by + 10, by + 28].forEach(my => { px(bx + 2, my, 26, 3, '#5a3f26'); px(bx + 2, my - 3, 26, 3, '#d9d6cf'); px(bx + 3, my - 5, 7, 3, '#f2eee4'); });
      for (let r = 0; r < 4; r++) px(bx + 30, by + 4 + r * 6, 4, 1, '#5a3f26');
      px(bx + 33, by + 2, 1, 26, '#3e2b1a');
    });
    sleepers.forEach((a, i) => {
      const slot = slots[i], w = walking.get(a.id);
      const deskSpot = spots[agents.indexOf(a)] || { x: bossSpot.x, y: bossSpot.y };
      if (w) {
        // Walking: desk to the ladder, then up (or the reverse when the plan resets).
        let p = Math.min(1, (frame - w.at) / WALK);
        if (w.dir === 'out') p = 1 - p;
        const ladderX = slot.bx + 31, floorY = slot.by + 34;
        const sx = deskSpot.x - 6, sy = deskSpot.y - 6;
        let x, y;
        if (p < 0.75) { const q = p / 0.75; x = sx + (ladderX - sx) * q; y = sy + (floorY - sy) * q; }
        else { const q = (p - 0.75) / 0.25; x = ladderX - (slot.top ? 0 : q * 14); y = floorY - q * (floorY - (slot.y - 4)); }
        const step = !still && Math.floor(frame / 3) % 2;
        px(x, y, 9, 9, a.color); px(x, y, 1, 8, shade(a.color, 0.22));
        px(x + 2, y + 3, 2, 2, C.eye); px(x + 5, y + 3, 2, 2, C.eye);
        px(x + 1 + (step ? 1 : 0), y + 9, 2, 2, '#0a0908'); px(x + 6 - (step ? 1 : 0), y + 9, 2, 2, '#0a0908');
        return;
      }
      // Asleep: a head on the pillow, a blanket in its colour, Zzz rising.
      px(slot.x - 3, slot.y - 6, 7, 6, a.color); px(slot.x - 2, slot.y - 4, 2, 1, C.eye); px(slot.x + 1, slot.y - 4, 2, 1, C.eye);
      px(slot.x + 4, slot.y - 6, 18, 5, shade(a.color, -0.2)); px(slot.x + 4, slot.y - 6, 18, 1, shade(a.color, 0.15));
      bubble(slot.x - 2, slot.y - 22, { activity: 'asleep' }, t + i * 5);
    });
  }
  // Which agents are in bed: their plan is out. Start a walk when that changes.
  function applyUsage() {
    const agents = (data && data.agents) || [], out = {};
    ((usage && usage.plans) || []).forEach(p => { if (p.out) out[p.id] = p.back_at || 1; });
    agents.forEach(a => {
      const plan = a.kind === 'claude' ? 'claude' : a.kind === 'codex' ? 'codex' : /anthropic/.test(a.provider || '') ? 'claude' : /codex/.test(a.provider || '') ? 'codex' : null;
      const bed = plan && out[plan] ? out[plan] : null;
      const was = bedOf.get(a.id);
      if (!!bed !== !!was && bedOf.has(a.id) && !still) { walking.set(a.id, { dir: bed ? 'in' : 'out', at: frame }); }
      bedOf.set(a.id, bed);
      a.bed = bed && !walking.has(a.id) ? bed : null;
      if (bed && walking.has(a.id)) a.bedSoon = bed;
    });
  }
  const bedOf = new Map();
  // ── Questions for the boss: an agent that has finished and is waiting on you gets up, walks to the front
  //    desk, and waits beside it with a question mark until you answer; then it walks back. ──
  const TRIP = 36;                 // frames for the walk (3 s at 12 fps)
  const atBoss = new Set();       // agents standing at (or heading to) the front desk
  const trips = new Map();         // id -> { to: true|false, at: frame }
  let tripsSeeded = false;
  const awayToBoss = id => atBoss.has(id) || trips.has(id);
  function updateTrips() {
    const agents = (data && data.agents) || [];
    agents.forEach(a => {
      const want = a.activity === 'your_turn' && !a.bed && !walking.has(a.id), has = atBoss.has(a.id);
      if (want === has) return;
      if (want) atBoss.add(a.id); else atBoss.delete(a.id);
      // On first sight they are simply there; after that every change is a walk.
      if (tripsSeeded && !still) trips.set(a.id, { to: want, at: frame }); else trips.delete(a.id);
    });
    [...atBoss, ...trips.keys()].forEach(id => { if (!agents.some(a => a.id === id)) { atBoss.delete(id); trips.delete(id); } });
    tripsSeeded = true;
  }
  function tickTrips() {
    trips.forEach((tr, id) => { if (frame - tr.at >= TRIP) { trips.delete(id); lastPlateKey = ''; } });
  }
  // The line beside the front desk: first on the left, second on the right, then further out.
  function queueSpot(k) {
    const step = Math.floor(k / 2) * 18, left = k % 2 === 0;
    const x = left ? bossSpot.x - 68 - step : bossSpot.x + 54 + step;
    return { x: Math.max(4, Math.min(W - 60, x)), y: bossSpot.y - 17 };
  }
  const queueLine = agents => agents.filter(a => atBoss.has(a.id) || (trips.get(a.id) || {}).to === false);
  function bossQueue(agents, spots, t) {
    queueLine(agents).forEach((a, k) => {
      const s = spots[agents.indexOf(a)];
      if (!s) return;
      const q = queueSpot(k), home = { x: s.x + 2, y: s.y - 16 }, tr = trips.get(a.id);
      let p = 1;
      if (tr) { p = Math.min(1, (frame - tr.at) / TRIP); if (!tr.to) p = 1 - p; }
      const e = p < 0.5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2;
      const moving = !!tr && !still;
      const x = Math.round(home.x + (q.x - home.x) * e), y = Math.round(home.y + (q.y - home.y) * e) - (moving && frame % 4 < 2 ? 1 : 0);
      // Shadow, feet (stepping while it walks), the body, and on arrival a question mark.
      ctx.globalAlpha = 0.3; ctx.fillStyle = '#000'; ctx.beginPath(); ctx.ellipse(x + 7, y + 17, 8, 2, 0, 0, 7); ctx.fill(); ctx.globalAlpha = 1;
      const st = moving ? Math.floor(frame / 3) % 2 : 0;
      px(x + 2, y + 15 - st, 4, 2, '#0a0908'); px(x + 8, y + 14 + st, 4, 2, '#0a0908');
      blob(x, y, { ...a, activity: moving ? 'idle' : 'your_turn' }, t);
      if (!moving) {
        const lift = still ? 0 : (t % 10 < 5 ? 0 : -1), bx = x + 9, by = y - 15 + lift;
        px(bx, by, 11, 11, C.gold); px(bx + 1, by + 1, 9, 9, '#fbf3df'); px(bx + 2, by + 11, 2, 2, '#fbf3df'); px(bx + 1, by + 13, 1, 1, '#fbf3df');
        pattern(bx + 3, by + 2, ['.##.', '#..#', '..#.', '.#..', '....', '.#..'], C.ink);
        // Arm up toward the boss.
        const toward = q.x < bossSpot.x ? 1 : -1, ax = toward > 0 ? x + 13 : x - 3;
        px(ax, y + 2, 4, 9, '#0c0b09'); px(ax + 1, y + 3, 2, 8, shade(a.color, 0.3));
      }
    });
  }
  function tickWalks() {
    walking.forEach((w, id) => {
      if (frame - w.at < WALK) return;
      walking.delete(id);
      const a = ((data && data.agents) || []).find(x => x.id === id);
      if (a) a.bed = w.dir === 'in' ? bedOf.get(id) : null;
      lastPlateKey = ''; lastRosterKey = '';
    });
  }

  // ── The coffee shop's furniture, and the little celebrations ──
  const bits = [];
  const hud = document.getElementById('office-hud');
  const toastEl = document.getElementById('office-toast');
  const num = n => Math.round(n).toLocaleString('en-US');

  // Behind the tables: a big patterned rug.
  function cafeBack(t, agents) {
    const rx = ox + 8, ry = oy + 112, rw = geo.W - 58, rh = Math.max(20, bossSpot.y - 34 - ry);
    rug(rx, ry, rw, rh, 0);
    rug(bossSpot.x - 66, bossSpot.y + 4, 132, 30, 2);
  }
  // ── The lounge, left of the tables: a bookshelf, a guitar, a cork board, the green sofa with a
  //    sleeping cat, a coffee table, a floor lamp and a rug. Only when the room has the width. ──
  const RUGS = [['#7a2e22', '#a8743f', '#5a2018'], ['#2f3e5a', '#c9963a', '#22304a'], ['#5a2a3a', '#d9a56a', '#401c2a']];
  function rug(x, y, w, h, k) {
    const [base, edge, dark] = RUGS[k % RUGS.length];
    px(x, y, w, h, dark); px(x + 1, y + 1, w - 2, h - 2, base);
    px(x + 3, y + 3, w - 6, 1, edge); px(x + 3, y + h - 4, w - 6, 1, edge); px(x + 3, y + 3, 1, h - 6, edge); px(x + w - 4, y + 3, 1, h - 6, edge);
    for (let i = x + 8; i < x + w - 8; i += 10) for (let j = y + 8; j < y + h - 7; j += 8) pattern(i, j, ['.#.', '#.#', '.#.'], edge);
    for (let i = x + 1; i < x + w - 1; i += 2) { px(i, y - 1, 1, 1, edge); px(i, y + h, 1, 1, edge); }
  }
  function pot(x, y, big, k) {
    const s = big ? 1.6 : 1, pw = Math.round(10 * s), ph = Math.round(9 * s);
    px(x, y - ph, pw, ph, k % 2 ? '#b5653a' : '#c9b8a0'); px(x - 1, y - ph - 1, pw + 2, 2, k % 2 ? '#8a4a2a' : '#a8987e');
    for (let i = 0; i < 9; i++) {
      const sway = still ? 0 : Math.round(Math.sin(frame / 12 + i + k));
      const dx = (i - 4) * 1.8 * s, h = (9 + (i % 3) * 5) * s;
      for (let q = 0; q < h; q++) px(x + pw / 2 + dx * q / h + (q > h - 3 ? sway : 0), y - ph - 1 - q, 2, 1, i % 2 ? '#3f7a3a' : '#4f8f46');
    }
  }
  function lampGlow(x, y, r, a) {
    ctx.globalCompositeOperation = 'lighter';
    const g = ctx.createRadialGradient(x, y, 1, x, y, r);
    g.addColorStop(0, `rgba(255,190,110,${a})`); g.addColorStop(1, 'rgba(0,0,0,0)');
    ctx.fillStyle = g; ctx.fillRect(x - r, y - r, r * 2, r * 2);
    ctx.globalCompositeOperation = 'source-over';
  }
  function lounge(t) {
    const x1 = ox + 4, x0 = 4, w = x1 - x0;
    if (w < 110) return false;
    // Bookshelf against the wall, and a cork board with polaroids beside it.
    const bx = x0 + 6, by = WALL - 30;
    px(bx, by, 30, 48, '#4a2e18'); px(bx + 1, by + 1, 28, 46, '#2a170c');
    const books = ['#a8402a', '#3f6a5a', '#c9963a', '#5a4a8a', '#e9e3d4', '#7a3a2a', '#2f5a7a', '#8a6a3a'];
    for (let sh = 0; sh < 4; sh++) {
      const sy = by + 2 + sh * 11;
      px(bx + 1, sy + 9, 28, 2, '#5a3820');
      for (let k = 0; k < 8; k++) { const hh = 6 + Math.floor(rand(k * 3 + sh * 7) * 3); if (rand(k + sh * 9) > 0.15) px(bx + 2 + k * 3, sy + 9 - hh, 3, hh, books[(k + sh * 3) % 8]); }
    }
    pot(bx + 9, by, false, 1);
    // A guitar leaning on the wall.
    const gx = bx + 34, gy = WALL - 6;
    px(gx + 3, gy - 14, 2, 14, '#3a2414'); px(gx + 2, gy - 17, 4, 3, '#2a170c');
    px(gx, gy, 8, 6, '#c47a3a'); px(gx + 1, gy + 6, 6, 8, '#c47a3a'); px(gx - 1, gy + 8, 10, 6, '#c47a3a'); px(gx + 3, gy + 3, 2, 2, '#2a170c');
    // The rug, the sofa with its cat, the coffee table, the lamp.
    const rw = Math.min(w - 10, 150), rx = x0 + Math.max(4, (w - rw) / 2), ry = WALL + 34, rh = 80;
    rug(rx, ry, rw, rh, 0);
    const sw = 80, sx = rx + (rw - sw) / 2, sy = ry - 14;
    px(sx, sy - 3, sw, 14, '#2f4a33'); px(sx, sy - 3, sw, 1, '#456a4a'); for (let i = 1; i < 4; i++) px(sx + i * 20, sy - 1, 1, 12, '#28402c');
    px(sx, sy + 11, sw, 9, '#3a5a3e'); px(sx + 2, sy + 11, sw - 4, 1, '#4f7a52');
    px(sx - 5, sy + 5, 6, 16, '#2f4a33'); px(sx + sw - 1, sy + 5, 6, 16, '#2f4a33'); px(sx - 5, sy + 5, 6, 1, '#456a4a'); px(sx + sw - 1, sy + 5, 6, 1, '#456a4a');
    px(sx + 4, sy + 4, 10, 7, '#c9963a'); px(sx + sw - 14, sy + 4, 10, 7, '#a85e22');
    px(sx - 3, sy + 21, 2, 3, '#24150a'); px(sx + sw + 1, sy + 21, 2, 3, '#24150a');
    const kx = sx + 22, ky = sy + 5, br = still ? 0 : (t % 10 < 5 ? 0 : 1);
    pattern(kx, ky - br, ['.#..#...........', '.####...........', '######.#######..', '##############..', '.##############.', '..##############'], '#d9893a');
    pattern(kx, ky - br, ['................', '................', '.......#..#..#..', '........#..#..#.', '................', '................'], '#a85e22');
    px(kx + 1, ky + 3 - br, 1, 1, '#2a1a0c'); px(kx + 4, ky + 3 - br, 1, 1, '#2a1a0c');
    for (let i = 0; i < 2 && !still; i++) { const q = ((t / 2 + i * 7) % 14) / 14; ctx.globalAlpha = 1 - q; pattern(kx + 2 + i * 4, ky - 6 - q * 10, ['###', '.#.', '###'], '#cfc8b8'); ctx.globalAlpha = 1; }
    const tx = sx + 8, ty = sy + 36;
    px(tx, ty, 44, 4, '#8a5a32'); px(tx, ty, 44, 1, '#a8743f'); px(tx + 2, ty + 4, 3, 7, '#4a2e18'); px(tx + 39, ty + 4, 3, 7, '#4a2e18');
    px(tx + 6, ty - 3, 9, 3, '#a8402a'); px(tx + 7, ty - 5, 8, 2, '#3f6a5a');
    px(tx + 28, ty - 5, 5, 5, '#efe6d2'); px(tx + 33, ty - 4, 1, 2, '#efe6d2'); px(tx + 29, ty - 5, 3, 1, '#7a4a2a');
    if (!still) for (let i = 0; i < 2; i++) { const q = ((t + i * 5) % 10) / 10; ctx.globalAlpha = 0.6 * (1 - q); px(tx + 29 + i * 2, ty - 7 - q * 7, 1, 2, '#e9e3d4'); ctx.globalAlpha = 1; }
    const lx = Math.max(x0 + 6, rx - 2), ly = sy - 28;
    px(lx, ly + 6, 1, 44, '#8a6a3a'); px(lx - 3, ly + 49, 7, 2, '#5a4a32'); px(lx - 6, ly, 13, 7, '#e9c88a'); px(lx - 6, ly + 6, 13, 1, '#c9963a');
    lampGlow(lx, ly + 8, 40, 0.3);
    pot(rx + rw - 8, ry + rh + 6, true, 2);
    pot(x0 + 4, ry + rh + 20, false, 3);
    return true;
  }
  // ── The lab corner, right of the tables: a bench of glowing flasks, a microscope, a stool, the
  //    "Push ideas" arcade cabinet, a bean bag with a second cat, and a big plant. ──
  function labCorner(t) {
    const x0 = ox + geo.W - 34, x1 = W - 50, w = x1 - x0;
    if (w < 100) return false;
    const on = running('research');
    const bx = x0 + 6, by = WALL + 4;
    // A shelf of books and jars on the wall, and a chalk "Coffee & Code" sign.
    px(bx, WALL - 32, 50, 2, '#7a5030');
    for (let k = 0; k < 14; k++) if (rand(k * 5.3) > 0.2) { const hh = 6 + Math.floor(rand(k * 2.1) * 4); px(bx + 2 + k * 3, WALL - 32 - hh, 3, hh, ['#a8402a', '#3f6a5a', '#c9963a', '#5a4a8a', '#e9e3d4'][k % 5]); }
    if (x1 - bx > 90) {
      const cx = bx + 56, cy = WALL - 44;
      px(cx, cy, 31, 30, '#6b4a2b'); px(cx + 2, cy + 2, 27, 26, '#1f2622');
      pattern(cx + 4, cy + 5, ['###.###.###.###.###.###', '#...#.#.#...#...#...#..', '#...#.#.##..##..##..##.', '#...#.#.#...#...#...#..', '###.###.#...#...###.###'], '#efe6d2');
      pattern(cx + 13, cy + 12, ['.#..', '#.#.', '.##.', '#.##'], '#f9d976');
      pattern(cx + 8, cy + 18, ['###.###.##..###', '#...#.#.#.#.#..', '#...#.#.#.#.##.', '#...#.#.#.#.#..', '###.###.##..###'], '#efe6d2');
    }
    px(bx, by, 56, 4, '#8a5a32'); px(bx, by, 56, 1, '#a8743f'); px(bx + 2, by + 4, 52, 16, '#5a3820');
    px(bx + 4, by + 7, 22, 10, '#4a2e18'); px(bx + 30, by + 7, 22, 10, '#4a2e18'); px(bx + 14, by + 11, 3, 1, C.gold); px(bx + 40, by + 11, 3, 1, C.gold);
    [['#5ad0ff', 3], ['#5ad0ff', 12], ['#9fe08a', 21], ['#c98aff', 30]].forEach(([c, dx], k) => {
      const fx = bx + dx, fy = by - 9;
      px(fx + 2, fy, 3, 4, '#cfe3e8'); px(fx, fy + 4, 7, 5, '#cfe3e8'); px(fx + 1, fy + 5, 5, 4, c);
      if (!still && (frame + k * 4) % 10 < 5 && (on || k % 2)) px(fx + 3, fy - 2 - ((frame + k * 3) % 4), 1, 1, c);
      ctx.globalCompositeOperation = 'lighter';
      const g = ctx.createRadialGradient(fx + 3.5, fy + 6, 0, fx + 3.5, fy + 6, 9);
      g.addColorStop(0, c === '#c98aff' ? 'rgba(200,140,255,.35)' : c === '#9fe08a' ? 'rgba(160,224,138,.3)' : 'rgba(90,208,255,.35)'); g.addColorStop(1, 'rgba(0,0,0,0)');
      ctx.fillStyle = g; ctx.fillRect(fx - 6, fy - 3, 20, 18); ctx.globalCompositeOperation = 'source-over';
    });
    px(bx + 44, by - 12, 4, 2, '#3a3631'); px(bx + 45, by - 10, 2, 7, '#57524a'); px(bx + 42, by - 3, 9, 3, '#3a3631'); px(bx + 47, by - 9, 3, 2, '#86cbc2');
    px(bx + 22, by + 28, 10, 2, '#8a5a32'); px(bx + 23, by + 30, 1, 8, '#4a2e18'); px(bx + 30, by + 30, 1, 8, '#4a2e18');
    // The arcade cabinet.
    const ax = Math.min(x1 - 20, bx + 70), ay = WALL - 8;
    px(ax, ay, 19, 40, '#2a1a4a'); px(ax + 1, ay + 1, 17, 4, '#ff6fb5'); px(ax + 1, ay + 7, 17, 11, '#081018');
    const blink = still || frame % 16 < 12;
    pattern(ax + 2, ay + 9, ['###.#....#..#.#', '#.#.#...#.#.#.#', '###.#...###..#.', '#...#...#.#..#.', '#...###.#.#..#.'], blink ? '#ffd27a' : '#6b5228');
    px(ax + 3, ay + 15, 12, 1, blink ? '#5ad0ff' : '#2a3b4a');
    px(ax + 2, ay + 20, 14, 5, '#3b2a5c'); px(ax + 4, ay + 21, 2, 2, C.red); px(ax + 9, ay + 22, 2, 1, C.goldHi); px(ax + 12, ay + 22, 2, 1, '#5ad0ff');
    px(ax + 1, ay + 26, 16, 14, '#22143c');
    lampGlow(ax + 9, ay + 12, 22, 0.18);
    // A rug with a bean bag and a cat curled in it.
    const rx = x0 + 8, ry = WALL + 58, rw = Math.min(w - 12, 80);
    rug(rx, ry, rw, 40, 1);
    const qx = rx + 14, qy = ry + 16;
    px(qx, qy + 4, 30, 14, '#2f4a5a'); px(qx + 3, qy, 24, 6, '#3a5a6e'); px(qx + 2, qy + 4, 26, 1, '#4a6e84');
    const br = still ? 0 : (t % 12 < 6 ? 0 : 1);
    pattern(qx + 8, qy + 1 - br, ['.#..#.......', '.####.......', '############', '.##########.'], '#c9b8a0');
    px(qx + 9, qy + 3 - br, 1, 1, '#2a1a0c'); px(qx + 12, qy + 3 - br, 1, 1, '#2a1a0c');
    pot(rx + rw - 18, ry + 44, true, 4);
    return true;
  }
  function tablePlants() {
    const y = oy + 128;
    pot(ox + 4, y + 6, true, 5); pot(ox + geo.W - 52, y + 6, true, 6);
  }
  // In front: big leafy plants in the corners; the lounge and the lab corner when they fit.
  function cafeFront(t) {
    tablePlants();
    [[6, 1], [W - 56, -1]].forEach(([x, dir], k) => {
      const y = H - 36;
      px(x, y + 16, 16, 14, '#7a5030'); px(x - 1, y + 15, 18, 2, '#9a6a40');
      for (let i = 0; i < 9; i++) {
        const sway = still ? 0 : Math.round(Math.sin(frame / 12 + i + k));
        const dx = (i - 4) * 2.6, h = 12 + (i % 3) * 5;
        for (let s = 0; s < h; s++) px(x + 8 + dx * s / h + (s > h - 3 ? sway : 0), y + 15 - s, 3, 1, i % 2 ? '#3f7a3a' : '#4f8f46');
      }
    });
    if (!lounge(t)) { /* narrow room: the corner plants carry it */ }
    labCorner(t);
  }

  // Confetti lives on the canvas, for a finished task.
  function confetti() {
    if (still) return;
    const cols = [C.goldHi, C.gold, '#ff6fb5', C.cyan, C.green, '#efe6d2'];
    for (let i = 0; i < 90; i++) bits.push({ kind: 'confetti', x: rand(i * 1.7 + frame) * W, y: -rand(i * 2.3) * 40, vx: (rand(i * 5.1) - 0.5) * 0.8, vy: 0.8 + rand(i * 9.3) * 1.2, born: frame, life: 60, c: cols[i % cols.length] });
  }
  function particles() {
    for (let i = bits.length - 1; i >= 0; i--) {
      const b = bits[i], age = frame - b.born;
      if (age < 0) continue;
      if (age > b.life) { bits.splice(i, 1); continue; }
      const x = b.x + b.vx * age, y = b.y + b.vy * age;
      ctx.globalAlpha = Math.max(0, 1 - age / b.life * (b.kind === 'confetti' ? 0.6 : 1));
      px(x, y, 2, 2 + (age % 3 === 0 ? 1 : 0), b.c);
    }
    ctx.globalAlpha = 1;
  }
  function toast(kicker, title) {
    toastEl.hidden = true; void toastEl.offsetWidth;
    toastEl.innerHTML = `<small>${esc(kicker)}</small><b>${esc(title)}</b>`;
    toastEl.hidden = false;
    clearTimeout(toast.t); toast.t = setTimeout(() => { toastEl.hidden = true; }, 3500);
  }

  function floorStatus(snapshot, failed) {
    if (failed) return 'Connection lost · last view retained';
    if (!snapshot) return 'Opening the office…';
    const agents = snapshot.agents || [], awake = agents.filter(a => !a.bed);
    if (!agents.length) return 'Quiet floor · ready for work';
    const busy = awake.filter(a => BUSY.has(a.activity)).length, waiting = awake.filter(a => a.activity === 'your_turn').length;
    const helpers = agents.reduce((n, a) => n + (a.helpers || []).length, 0), beds = agents.length - awake.length;
    return [`${agents.length} agent${agents.length === 1 ? '' : 's'}`, busy ? `${busy} working` : null,
      waiting ? `${waiting} need${waiting === 1 ? 's' : ''} you` : null, helpers ? `${helpers} helper${helpers === 1 ? '' : 's'}` : null,
      beds ? `${beds} in bed` : null].filter(Boolean).join(' · ');
  }
  function renderHud() {
    const st = hud.querySelector('.oh-status');
    st.textContent = floorStatus(data, error);
    st.classList.toggle('offline', error);
  }

  // ── HTML over the canvas: name plates and click targets ──
  const ago = s => { s = Math.max(0, Math.round(s)); return s < 60 ? s + 's' : s < 3600 ? Math.round(s / 60) + 'm' : s < 86400 ? Math.round(s / 3600) + 'h' : Math.round(s / 86400) + 'd'; };
  const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  // "ttys004" reads as "tty 4": shown only when two desks share a title, to tell them apart.
  const ttyName = t => String(t).replace(/^ttys0*(\d+)$/, 'tty $1');
  // Waiting and asleep say for how long, so the one that has waited longest stands out.
  const clockTime = at => new Date(at * 1000).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
  const backWhen = at => { const d = new Date(at * 1000), today = new Date(); return d.toDateString() === today.toDateString() ? clockTime(at) : d.toLocaleDateString('en-US', { weekday: 'short' }) + ' ' + clockTime(at); };
  const plateWords = a => {
    if (a.bed) return `In bed till ${backWhen(a.bed)}`;
    const w = a.activity === 'your_turn' ? 'Has a question' : WORDS[a.activity] || a.activity;
    return (a.activity === 'your_turn' || a.activity === 'asleep') && a.last_at ? `${w} ${ago(Date.now() / 1000 - a.last_at)}` : w;
  };
  const helperWords = h => `${h.title || 'Helper'}: ${(WORDS[h.activity] || h.activity || 'working').toLowerCase()}`;
  // The visible way in: a gold pill on every plate. It says what a click does (talk to it in its
  // terminal, see its card, or close what is open).
  const goBtn = (id, a) => {
    const open = selected === id;
    const word = open ? 'Close' : id === 'boss' ? 'Open' : a && a.tty && !demo ? 'Talk' : 'Open';
    return `<b class="office-go${open ? ' on' : ''}" aria-hidden="true">${word}${open ? '' : '<em>›</em>'}</b>`;
  };
  let lastPlateKey = '';
  function placeDesks(spots, agents) {
    const mins = Math.floor(Date.now() / 60000);
    const key = JSON.stringify([W, H, mins, selected, helperSel, [...atBoss], [...trips.keys()], wallBoards.tasks.x, wallBoards.tasks.w, board, running('brainstorm'), running('research'), spots.length, bossState(agents), agents.map(a => [a.id, a.name, a.title, a.activity, a.bed, a.model, a.color, a.tty, a.closing && a.closing.text, (a.helpers || []).map(h => h.id + h.activity)])]);
    if (key === lastPlateKey) return;
    lastPlateKey = key;
    const st = bossState(agents);
    const bossWords = { your_turn: 'Someone is waiting on you', watching: `Watching ${agents.length} agent${agents.length === 1 ? '' : 's'}`, asleep: 'Asleep', idle: agents.length ? 'Everyone is resting' : 'Waiting for work' }[st];
    const aLeft = (bossSpot.x / W * 100).toFixed(3);
    const bossHTML = `<button class="office-hit${selected === 'boss' ? ' on' : ''}" data-id="boss" style="left:${aLeft}%;top:${((bossSpot.y - 44) / H * 100).toFixed(3)}%;height:${(70 / H * 100).toFixed(3)}%;width:${(104 / W * 100).toFixed(3)}%" aria-label="The boss, ${esc(bossWords)}"></button>
      <div class="office-plate boss ${st === 'your_turn' ? 'you' : st === 'watching' ? 'busy' : st}" data-id="boss" style="left:${aLeft}%;top:${((bossSpot.y + 27) / H * 100).toFixed(3)}%"><div class="op-top"><b>Boss</b>${goBtn('boss')}</div><span><i></i>${esc(bossWords)}</span></div>`;
    const dupes = new Set(agents.map(a => a.title).filter((t, i, all) => all.indexOf(t) !== i));
    const boardNames = { tasks: 'Task board', ideas: 'Idea board', lab: 'The lab: suggestions' };
    const boardHits = Object.entries(wallBoards).filter(([, b]) => b.x != null).map(([k, b]) =>
      `<button class="office-hit board" data-board="${k}" style="left:${((b.x + b.w / 2) / W * 100).toFixed(3)}%;top:${(b.y / H * 100).toFixed(3)}%;width:${(b.w / W * 100).toFixed(3)}%;height:${(b.h / H * 100).toFixed(3)}%" title="Open the ${boardNames[k].toLowerCase()}" aria-label="${boardNames[k]}">${boardWriting(k)}</button>`).join('');
    // The ones standing at the front desk are clickable where they stand, their name under their feet.
    const askers = queueLine(agents).filter(a => !trips.has(a.id)).map((a, k) => {
      const q = queueSpot(queueLine(agents).indexOf(a));
      return `<button class="office-hit asker${selected === a.id ? ' on' : ''}" data-id="${esc(a.id)}" style="left:${((q.x + 7) / W * 100).toFixed(3)}%;top:${((q.y - 16) / H * 100).toFixed(3)}%;width:${(24 / W * 100).toFixed(3)}%;height:${(36 / H * 100).toFixed(3)}%" aria-label="${esc(nameOf(a))} has a question" title="${esc(nameOf(a))} has a question: ${esc(a.title)}"><span style="color:${esc(nameColor(a.color))}">${esc(nameOf(a))}</span></button>`;
    }).join('');
    desksLayer.innerHTML = bossHTML + boardHits + askers + spots.map((s, i) => {
      const a = agents[i];
      // The plate is one slim line under the table legs (status dot, name, Talk), so it never covers the
      // agent or the desk; the title and status open below it on hover or keyboard focus.
      const left = (s.x / W * 100).toFixed(3), top = ((s.y - 36) / H * 100).toFixed(3), plate = ((s.y + 25) / H * 100).toFixed(3);
      const fit = `max-width:${((s.slot - 5) / W * 100).toFixed(3)}%`;
      if (!a) return `<div class="office-plate open" style="left:${left}%;top:${plate}%;${fit}"><b>Open desk</b><span>Waiting for an agent</span></div>`;
      // Each helper drawn on the desk is its own click target (over the agent's).
      const helperHits = (a.helpers || []).slice(0, HELPER_SPOTS.length).map((h, k) => {
        const hx = s.x - 32 + HELPER_SPOTS[k] + 3.5, hy = s.y - 9;
        return `<button class="office-hit helper${helperSel === h.id ? ' on' : ''}" data-helper="${esc(h.id)}" style="left:${(hx / W * 100).toFixed(3)}%;top:${((hy - 8) / H * 100).toFixed(3)}%;width:${(12 / W * 100).toFixed(3)}%;height:${(17 / H * 100).toFixed(3)}%" aria-label="Helper ${esc(h.title || '')}, ${esc(WORDS[h.activity] || h.activity || '')}" title="${esc(h.title || 'Helper')}"></button>`;
      }).join('');
      const state = a.bed ? 'asleep' : a.activity === 'your_turn' ? 'you' : BUSY.has(a.activity) ? 'busy' : a.activity;
      return `<button class="office-hit${selected === a.id ? ' on' : ''}" data-id="${esc(a.id)}" style="left:${left}%;top:${top}%;height:${(64 / H * 100).toFixed(3)}%;width:${(Math.min(70, s.slot - 4) / W * 100).toFixed(3)}%" aria-label="${esc(nameOf(a))}, ${esc(a.title)}, ${esc(WORDS[a.activity] || a.activity)}${(a.helpers || []).length ? `, ${a.helpers.length} helper${a.helpers.length === 1 ? '' : 's'} out` : ''}"></button>
        <div class="office-plate ${state}" data-id="${esc(a.id)}" style="left:${left}%;top:${plate}%;${fit}">
          ${(a.helpers || []).length ? `<em class="office-help" title="${a.helpers.length} helper${a.helpers.length === 1 ? '' : 's'} out">${a.helpers.length}</em>` : ''}<div class="op-top"><i class="op-dot"></i>${nameTag(a)}${goBtn(a.id, a)}</div><div class="op-more"><p class="op-title" title="${esc(a.title)}">${esc(a.title)}</p>${a.closing && a.activity === 'your_turn' ? `<p class="op-close${a.closing.question ? ' ask' : ''}" title="${esc(a.closing.text)}">${esc(a.closing.text)}</p>` : ''}<span><i></i>${esc(plateWords(a))}${a.tty && dupes.has(a.title) ? `<em class="office-tty">· ${esc(ttyName(a.tty))}</em>` : ''}</span></div>
        </div>${helperHits}`;
    }).join('');
  }

  function renderCard() {
    if (selected === 'boss' && data) {
      const ag = data.agents || [], busy = ag.filter(x => BUSY.has(x.activity)).length, you = ag.filter(x => x.activity === 'your_turn');
      const rows = [['Reporting to you', `${ag.length} agent${ag.length === 1 ? '' : 's'}`], ['Working', String(busy)],
        ['Waiting on you', you.length ? you.map(x => x.title).join(', ') : 'Nobody'],
        ['Hermes gateway', (data.gateway || {}).running ? 'On' : 'Off']];
      closeConsole();
      card.hidden = false;
      card.innerHTML = `<div class="office-card-head"><span class="office-card-kind">The front desk</span><button class="office-card-close" aria-label="Close">✕</button></div>
        <h3>You, the boss</h3><dl>${rows.map(([k, v]) => `<div><dt>${esc(k)}</dt><dd>${esc(v)}</dd></div>`).join('')}</dl>`;
      return;
    }
    const a = data && (data.agents || []).find(x => x.id === selected);
    if (!a) {
      card.hidden = true;
      if (selected && consoleFor === selected) endConsole('It left the office: its terminal closed.'); else closeConsole();
      return;
    }
    if (a.tty && !demo) return renderConsole(a);
    closeConsole();
    const now = Date.now() / 1000;
    const rows = [
      a.closing ? [a.closing.question ? 'Asks' : 'Last word', a.closing.text, 'gold'] : null,
      ['Doing', WORDS[a.activity] || a.activity],
      a.tool ? ['Last tool', a.tool.replace(/^mcp__/, '')] : null,
      ['Model', a.model || (a.kind === 'hermes' ? 'Hermes' : a.kind)],
      a.messages != null ? ['Messages', a.messages.toLocaleString('en-US')] : null,
      a.tokens_out ? ['Tokens', `${Math.round(a.tokens_in / 1000).toLocaleString('en-US')}k in · ${Math.round(a.tokens_out / 1000).toLocaleString('en-US')}k out`] : null,
      ['At this desk', ago(now - a.started_at)],
      a.last_at ? ['Last move', ago(now - a.last_at) + ' ago'] : null,
      a.tty ? ['Terminal', a.tty] : null,
      (a.helpers || []).length ? ['Helpers', a.helpers.map(helperWords).join('; ')] : null
    ].filter(Boolean);
    card.hidden = false;
    card.innerHTML = `
      <div class="office-card-head">
        <span class="office-card-kind"><em class="office-swatch" style="background:${esc(a.color)}"></em>${a.kind === 'hermes' ? 'Hermes agent' : a.kind === 'claude' ? 'Claude Code' : 'Codex'}</span>
        <button class="office-card-close" aria-label="Close">✕</button>
      </div>
      <h3>${nameTag(a)} <span class="oc-full">${esc(a.title)}</span></h3>
      <dl>${rows.map(([k, v, g]) => `<div${g ? ' class="gold"' : ''}><dt>${esc(k)}</dt><dd>${esc(v)}</dd></div>`).join('')}</dl>
      <p class="office-card-id">${esc(a.id)}</p>`;
  }

  // ── Fit to the window: the whole room shows without scrolling, at any window size ──
  function topbarBottom() { const b = document.querySelector('.topbar'); return b ? Math.max(0, b.getBoundingClientRect().bottom) : 0; }
  // Space for the room: the column beside the console when it is open, else the page column; below
  // the masthead when that leaves a usable room, else a window's height under the top bar.
  // The shell takes the rest of the window (no page scroll); the room gets whatever the shell leaves
  // beside the roster, minus the console when one is open, and the layout picks the biggest fit.
  const shell = document.getElementById('office-shell'), roomEl = document.getElementById('office-room'), dockEl = document.getElementById('office-dock');
  function fit() {
    const n = seatCount((data && data.agents) || []), narrow = innerWidth <= 900;
    shell.style.height = narrow ? '' : Math.max(420, innerHeight - (shell.getBoundingClientRect().top + window.scrollY) - 12) + 'px';
    const r = roomEl.getBoundingClientRect();
    const cw = consoleFor && !narrow ? Math.round(Math.min(960, r.width - 296, Math.max(340, r.width * 0.60))) : 0;
    shell.style.setProperty('--office-drawer-h', Math.max(120, innerHeight - r.top - 12) + 'px');
    const root = document.documentElement.style;
    root.setProperty('--office-console-w', cw ? cw + 'px' : '');
    root.setProperty('--office-console-right', narrow ? '12px' : Math.max(12, innerWidth - r.right) + 'px');
    root.setProperty('--office-top', (narrow ? topbarBottom() + 12 : Math.max(topbarBottom() + 8, r.top)) + 'px');
    root.setProperty('--office-bottom', (narrow ? 12 : Math.max(12, innerHeight - r.bottom)) + 'px');
    const aw = Math.max(280, r.width - (cw ? cw + 16 : 0));
    dockEl.style.width = Math.round(aw) + 'px';
    // A short window with the terminal open gives the room the height; the board is a tab away.
    dockEl.hidden = !!(cw && innerHeight < 820);
    const dockH = dockEl.childElementCount && !dockEl.hidden ? dockEl.offsetHeight + 10 : 0;
    const ah = Math.max(220, narrow ? innerHeight * 0.62 : r.height - dockH);
    geo = chooseLayout(n, aw, ah);
    // Fill the whole space: grow the canvas to its shape and centre the desks in it. Most of the extra
    // height goes to the floor in front, a little to the wall, so the room does not look top-heavy.
    W = Math.max(geo.W, Math.round(aw / geo.scale)); H = Math.max(geo.H, Math.round(ah / geo.scale));
    ox = Math.round((W - geo.W) / 2); oy = Math.round((H - geo.H) * 0.35);
    if (canvas.width !== W || canvas.height !== H) { canvas.width = W; canvas.height = H; lastPlateKey = ''; }
    stage.style.aspectRatio = '';
    stage.style.width = Math.round(aw) + 'px';
    stage.style.height = Math.round(ah) + 'px';
    stage.style.setProperty('--office-scale', geo.scale.toFixed(3));
  }
  window.addEventListener('resize', () => { if (active()) { fit(); draw(); } });
  // Bring the room up under the top bar, so the office and its console fill the window.
  function showStage() {
    const y = hud.getBoundingClientRect().top + window.scrollY - topbarBottom() - 12;
    if (Math.abs(window.scrollY - y) > 4) window.scrollTo({ top: Math.max(0, y), behavior: still ? 'auto' : 'smooth' });
  }

  // ── The console: the agent's terminal screen, read every 1.5 s, and a line to send it ──
  // It lives on <body> so it pins to the window (the tab's fade-in transform would trap a fixed child).
  const consoleEl = document.getElementById('office-console');
  document.body.appendChild(consoleEl);
  let consoleFor = null, screenTimer = null, screenBusy = false, pinned = true, lastScreen = '', ended = false;
  // A request that never answers must not freeze the console: give up and let the next tick retry.
  async function fetchT(url, opts = {}, ms = 5000) {
    const ctl = new AbortController(), t = setTimeout(() => ctl.abort(), ms);
    try { return await fetch(url, { ...opts, signal: ctl.signal }); } finally { clearTimeout(t); }
  }
  const stateWords = a => a.activity === 'your_turn' ? 'Waiting on you' : BUSY.has(a.activity) ? (WORDS[a.activity] || 'Working') : (WORDS[a.activity] || a.activity);

  // The agent left (its terminal closed or the chat ended): keep the last screen, say so, stop polling.
  function endConsole(why) {
    if (!consoleFor || ended) return;
    ended = true;
    clearInterval(screenTimer); screenTimer = null;
    consoleEl.classList.add('ended');
    const $ = sel => consoleEl.querySelector(sel);
    $('.oc-state').className = 'oc-state ended';
    $('.oc-state b').textContent = 'Ended';
    $('.oc-ended').innerHTML = `<b>Session ended.</b>${esc(why || 'Its terminal closed.')} ${new Date().toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' })}. Close this to pick another agent.`;
  }

  function closeConsole() {
    if (!consoleFor) return;
    consoleFor = null; lastScreen = ''; ended = false;
    consoleEl.classList.remove('ended');
    clearInterval(screenTimer); screenTimer = null;
    consoleEl.classList.remove('open');
    stage.classList.remove('console-open');
    fit();
    setTimeout(() => { if (!consoleFor) consoleEl.hidden = true; }, 260);
  }

  function renderConsole(a) {
    card.hidden = true;
    const state = a.activity === 'your_turn' ? 'you' : BUSY.has(a.activity) ? 'busy' : 'rest';
    if (consoleFor !== a.id) {
      consoleFor = a.id; pinned = true; lastScreen = ''; ended = false;
      consoleEl.classList.remove('ended');
      consoleEl.hidden = false;
      fit(); showStage();
      consoleEl.innerHTML = `
        <header class="oc-head">
          <div class="oc-who">
            <span class="oc-avatar" aria-hidden="true"></span>
            <div class="oc-who-text"><div class="oc-name-row"><h3 class="oc-title"></h3><span class="oc-state"><i></i><b></b></span></div><p class="oc-sub"><span class="oc-full-title"></span> <span class="oc-kind-text"></span></p></div>
          </div>
          <div class="oc-tools">
            <button class="oc-btn oc-jump" title="Bring its iTerm tab to the front">Open in iTerm</button>
            <button class="oc-btn oc-close" aria-label="Close">✕</button>
          </div>
        </header>
        <div class="oc-meta"></div>
        <div class="oc-closing" hidden><span class="oc-avatar md" aria-hidden="true"></span><div><small></small><p></p></div></div>
        <div class="oc-helpers" aria-label="Its helpers"></div>
        <div class="oc-tabs" role="tablist"><button type="button" role="tab" data-view="term" aria-selected="true">&gt;_ Terminal</button><button type="button" role="tab" data-view="plan" aria-selected="false">Plan <small></small></button></div>
        <div class="oc-screen-wrap">
          <pre class="oc-screen" tabindex="0" aria-live="off"><span class="oc-dim">Reading its screen…</span></pre>
          <div class="oc-plan" hidden></div>
          <button class="oc-latest" hidden>↓ Latest</button>
        </div>
        <form class="oc-send" autocomplete="off">
          <span class="oc-prompt">❯</span>
          <input class="oc-input" type="text" maxlength="2000" spellcheck="true" placeholder="Message this agent">
          <button class="oc-btn oc-go" type="submit">Send</button>
        </form>
        <p class="oc-hint"></p>
        <div class="oc-usage" aria-label="Plan usage"></div>
        <p class="oc-ended" role="status"></p>`;
      ocView = a.activity === 'your_turn' && (a.todos || []).length ? 'plan' : 'term';
      const screenEl = consoleEl.querySelector('.oc-screen');
      screenEl.addEventListener('scroll', () => {
        pinned = screenEl.scrollHeight - screenEl.scrollTop - screenEl.clientHeight < 24;
        consoleEl.querySelector('.oc-latest').hidden = pinned;
      });
      requestAnimationFrame(() => { consoleEl.classList.add('open'); stage.classList.add('console-open'); consoleEl.querySelector('.oc-input').focus({ preventScroll: true }); });
      clearInterval(screenTimer);
      readScreen();
      screenTimer = setInterval(readScreen, 1500);
    }
    // It came back (same chat, terminal open again): resume.
    if (ended) {
      ended = false; consoleEl.classList.remove('ended');
      clearInterval(screenTimer); readScreen(); screenTimer = setInterval(readScreen, 1500);
    }
    // In-place updates: name, colour, state, numbers.
    const $ = sel => consoleEl.querySelector(sel);
    consoleEl.querySelectorAll('.oc-avatar').forEach(e => e.style.setProperty('--agent', a.color));
    $('.oc-kind-text').textContent = '· ' + (a.kind === 'hermes' ? 'Hermes' + (a.model ? ' · ' + a.model : '') : a.kind === 'claude' ? 'Claude Code' : 'Codex');
    $('.oc-title').innerHTML = `${nameTag(a)}`;
    $('.oc-full-title').textContent = a.title;
    const steps = (a.todos || []).filter(x => x.status !== 'dropped'), doneN = steps.filter(x => x.status === 'done').length;
    $('.oc-tabs [data-view="plan"] small').textContent = steps.length ? `${doneN}/${steps.length}` : '';
    $('.oc-plan').innerHTML = steps.length ? `<ol>${steps.map(x => `<li class="${x.status}"><i>${x.status === 'done' ? '✓' : ''}</i><span>${esc(x.text)}</span></li>`).join('')}</ol>`
      : `<p class="oc-empty">No plan yet. It shows up here when ${esc(nameOf(a))} lists its steps.</p>`;
    setOcView(ocView);
    const plans = ((usage && usage.plans) || []).filter(p => p.top != null);
    $('.oc-usage').innerHTML = plans.map(p => `<div class="${p.top >= 90 ? 'hot' : ''}"><b>${esc(p.name)}</b><span>${Math.round(p.top)}%</span><em><i style="width:${Math.min(100, p.top)}%"></i></em></div>`).join('');
    $('.oc-state').className = 'oc-state ' + state;
    $('.oc-state b').textContent = stateWords(a);
    const now = Date.now() / 1000;
    $('.oc-meta').textContent = [a.tty, a.messages != null ? a.messages + ' messages' : null,
      a.tool ? 'last tool ' + a.tool.replace(/^mcp__/, '') : null, 'at this desk ' + ago(now - a.started_at),
      (a.helpers || []).length ? a.helpers.length + ' helper' + (a.helpers.length === 1 ? '' : 's') + ' out' : null].filter(Boolean).join('  ·  ');
    const cl = $('.oc-closing');
    cl.hidden = !a.closing || BUSY.has(a.activity);
    if (a.closing) { cl.querySelector('small').textContent = a.closing.question ? `${nameOf(a)} asks` : `${nameOf(a)}'s last word`; cl.querySelector('p').textContent = a.closing.text; cl.classList.toggle('ask', !!a.closing.question); }
    $('.oc-helpers').innerHTML = (a.helpers || []).map(h =>
      `<span><em class="office-swatch" style="background:${esc(assign(h.id))}"></em><b>${esc(h.title || 'Helper')}</b>&nbsp;${esc((WORDS[h.activity] || h.activity || '').toLowerCase())}</span>`).join('');
    $('.oc-hint').textContent = a.kind === 'hermes'
      ? (a.working ? 'It is working: your line waits until this turn ends (sent with /queue). Start with / for a command.' : 'It is waiting: your line runs right away. Start with / for a command.')
      : 'Your line is typed into its terminal, then Return.';
  }

  async function readScreen() {
    if (!consoleFor || screenBusy || !active()) return;
    screenBusy = true;
    const id = consoleFor;
    try {
      const res = await fetchT('/api/office/screen?id=' + encodeURIComponent(id), { cache: 'no-store' }, 5000);
      const body = await res.json().catch(() => ({}));
      if (consoleFor !== id || ended) return;
      const pre = consoleEl.querySelector('.oc-screen');
      if (res.status === 404) { if (lastScreen) endConsole(body.error); else pre.innerHTML = `<span class="oc-dim">${esc(body.error || 'Its screen could not be read.')}</span>`; return; }
      if (!res.ok) { flash(body.error || 'Its screen could not be read just now.', true); return; }
      if (body.screen === lastScreen) return;
      lastScreen = body.screen;
      const ag = data && data.agents.find(x => x.id === id);
      pre.innerHTML = paint(body.screen, ag && ag.closing && ag.closing.text);
      if (pinned) pre.scrollTop = pre.scrollHeight;
    } catch (e) {
      /* the next tick tries again */
    } finally { screenBusy = false; }
  }

  // Light colour for a plain-text screen: Hermes's prompt, your lines, and the ruled boxes.
  // Lines of the screen that hold the reply's closing statement or question get the gold highlight.
  // The terminal wraps long lines, so match on words: a line is part of it when most of its words are.
  function closingLines(lines, closing) {
    const marks = new Set();
    const words = t => (String(t).toLowerCase().match(/[a-z0-9']+/g) || []);
    const want = new Set(words(closing || ''));
    if (want.size < 3) return marks;
    const fits = i => { const w = words(lines[i]); return w.length > 0 && w.filter(x => want.has(x)).length / w.length >= 0.8; };
    // The closing is the last run of such lines near the bottom (the prompt and status bar sit under it).
    let i = lines.length - 1;
    while (i >= 0 && lines.length - i <= 40 && !fits(i)) i--;
    while (i >= 0 && fits(i) && marks.size < 8) marks.add(i--);
    // Guard: the run must cover most of the closing, or it was a coincidence.
    const got = new Set([...marks].flatMap(k => words(lines[k])));
    return [...want].filter(x => got.has(x)).length / want.size >= 0.6 ? marks : new Set();
  }
  function paint(text, closing) {
    const lines = text.split('\n'), gold = closingLines(lines, closing);
    return lines.map((line, i) => {
      const e = esc(line);
      if (gold.has(i)) return `<span class="oc-close">${e}</span>`;
      if (/^\s*[─━╭╰│╮╯]/.test(line) && !/[A-Za-z]{3}/.test(line.replace(/[│]/g, ''))) return `<span class="oc-rule">${e}</span>`;
      if (/^\s*(☤ ❯|❯|>)\s/.test(line)) return `<span class="oc-you">${e}</span>`;
      if (/^\s*●\s/.test(line)) return `<span class="oc-said">${e}</span>`;
      if (/^\s*☤ /.test(line)) return `<span class="oc-status">${e}</span>`;
      return e;
    }).join('\n');
  }

  let ocView = 'term';
  function setOcView(v) {
    ocView = v;
    consoleEl.querySelectorAll('.oc-tabs button').forEach(b => b.setAttribute('aria-selected', String(b.dataset.view === v)));
    const pre = consoleEl.querySelector('.oc-screen'), plan = consoleEl.querySelector('.oc-plan');
    if (pre) pre.hidden = v !== 'term'; if (plan) plan.hidden = v !== 'plan';
  }
  consoleEl.addEventListener('click', async e => {
    const tabBtn = e.target.closest('.oc-tabs button');
    if (tabBtn) { setOcView(tabBtn.dataset.view); return; }
    if (e.target.closest('.oc-close')) { selected = null; lastPlateKey = ''; renderCard(); draw(); return; }
    if (e.target.closest('.oc-latest')) { const pre = consoleEl.querySelector('.oc-screen'); pinned = true; pre.scrollTop = pre.scrollHeight; e.target.hidden = true; return; }
    if (e.target.closest('.oc-jump')) {
      const r = await fetchT('/api/office/focus', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id: consoleFor }) });
      if (!r.ok) flash((await r.json().catch(() => ({}))).error || 'Could not open it.', true);
    }
  });
  consoleEl.addEventListener('submit', async e => {
    e.preventDefault();
    const input = consoleEl.querySelector('.oc-input'), go = consoleEl.querySelector('.oc-go');
    const text = input.value.trim();
    if (!text || go.disabled) return;
    go.disabled = true;
    try {
      const res = await fetchT('/api/office/send', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id: consoleFor, text }) });
      const body = await res.json().catch(() => ({}));
      if (res.status === 404) { endConsole(body.error); return; }
      if (!res.ok) throw new Error(body.error || 'Not sent.');
      input.value = '';
      flash(body.queued ? 'Queued: it runs when this turn ends.' : 'Sent.');
      pinned = true;
      setTimeout(readScreen, 700); setTimeout(poll, 1200);
    } catch (err) { flash(err.name === 'AbortError' ? 'iTerm did not answer. Nothing may have been sent; check the screen.' : err.message, true); }
    finally { setTimeout(() => { go.disabled = false; }, 2000); }
  });
  function flash(text, bad) {
    const hint = consoleEl.querySelector('.oc-hint');
    if (!hint) return;
    hint.textContent = text; hint.classList.toggle('bad', !!bad); hint.classList.add('flash');
    setTimeout(() => { hint.classList.remove('flash', 'bad'); const a = data && data.agents.find(x => x.id === consoleFor); if (a) renderConsole(a); }, 3200);
  }

  function tick(prev, next) {
    const now = new Date().toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
    (next.agents || []).forEach(a => {
      const was = prev.has(a.id) ? prev.get(a.id).activity : undefined;
      if (was === undefined && prev.size) log.unshift([now, nameOf(a), 'sat down']);
      else if (was && was !== a.activity) {
        const word = a.activity === 'your_turn' ? 'walked up to you with a question' : a.activity === 'asleep' ? 'fell asleep' : a.activity === 'helpers' ? 'is waiting on its helpers'
          : a.activity === 'idle' ? 'finished' : (WORDS[a.activity] || a.activity).toLowerCase();
        log.unshift([now, a.title, word]);
      }
    });
    (next.agents || []).forEach(a => {
      const was = prev.get(a.id);
      if (!was) return;
      const before = new Map(was.helpers.map(h => [h.id, h.title]));
      (a.helpers || []).forEach(h => { if (!before.has(h.id)) log.unshift([now, a.title, `sent out a helper: ${h.title || 'Helper'}`]); before.delete(h.id); });
      before.forEach(title => log.unshift([now, title || 'A helper', `finished for ${a.title}`]));
    });
    prev.forEach((p, id) => { if (!(next.agents || []).some(a => a.id === id)) log.unshift([now, p.title, 'left the office']); });
    log.splice(7);
    prev.clear();
    (next.agents || []).forEach(a => prev.set(a.id, { activity: a.activity, title: a.title, helpers: (a.helpers || []).map(h => ({ id: h.id, title: h.title })) }));
    ticker.innerHTML = log.length
      ? log.map(([time, who, what]) => `<li><time>${esc(time)}</time><b>${esc(who.length > 46 ? who.slice(0, 45) + '…' : who)}</b> ${esc(what)}</li>`).join('')
      : '<li class="quiet">Changes show up here as they happen.</li>';
  }

  // ?office-demo shows every activity at once; &office-hour=22 sets the sky. For checking the art.
  const params = new URLSearchParams(location.search);
  const demo = params.has('office-demo');
  const hourOverride = params.has('office-hour') ? Number(params.get('office-hour')) : null;
  function demoData() {
    const now = Date.now() / 1000;
    const all = ['typing', 'writing', 'reading', 'thinking', 'your_turn', 'browsing', 'looking', 'delegating', 'asleep', 'idle'];
    const count = params.has('office-n') ? Math.max(0, Math.min(24, Number(params.get('office-n')) || 0)) : all.length;
    const acts = Array.from({ length: count }, (_, i) => all[i % all.length]);
    // &office-cycle: the first agent alternates every 9 s between working and having a question.
    if (params.has('office-cycle') && acts.length) acts[0] = Math.floor(Date.now() / 9000) % 2 ? 'your_turn' : 'typing';
    return { agents: acts.map((a, i) => ({
      id: 'demo-' + i, tty: 'ttys0' + String(i + 1).padStart(2, '0'), kind: i === 5 ? 'claude' : i === 6 ? 'codex' : 'hermes',
      title: ['Build the waitlist form with a referral field', 'Write the landing page copy for Sunrise', 'Research competitor pricing pages', 'Plan the onboarding flow'][i % 4] + (i >= 4 ? ' ' + (i + 1) : ''),
      name: ['Ada', 'Bo', 'Cleo', 'Dex', 'Echo', 'Finn', 'Gus', 'Hana', 'Iggy', 'Juno', 'Kai', 'Lumi'][i % 12],
      closing: a === 'your_turn' ? { text: 'The waitlist form is live locally. Should I add the referral field before we publish, or ship it as is?', question: true }
        : a === 'idle' ? { text: 'Done: the landing copy is in docs/landing.md, ready for your review.', question: false } : null,
      todos: i === 0 ? [{ text: 'Read the current waitlist code', status: 'done' }, { text: 'Add the referral field to the form', status: 'doing' }, { text: 'Run the form tests', status: 'todo' }]
        : i === 1 ? [{ text: 'Draft the hero copy', status: 'doing' }, { text: 'Write three feature blurbs', status: 'todo' }] : [],
      model: 'Opus 5.5', provider: i === 5 || i === 6 ? '' : 'anthropic', activity: a, working: BUSY.has(a), started_at: now - 600 * (i + 1), last_at: now - 30,
      messages: 10 * i, helpers: a === 'delegating' ? [
        { id: 'h-r' + i, title: 'Research', activity: 'browsing', depth: 1 }, { id: 'h-d' + i, title: 'Draft', activity: 'writing', depth: 1 },
        { id: 'h-f' + i, title: 'Fact check', activity: 'reading', depth: 2 }, { id: 'h-t' + i, title: 'Tests', activity: 'typing', depth: 1 }]
        : a === 'typing' ? [{ id: 'h-x' + i, title: 'Review', activity: 'thinking', depth: 1 }] : [] })),
      rack: { ollama: true, units: [{ name: 'gemma4:26b', kind: 'ollama' }, { name: 'whisper', kind: 'whisper' }] } };
  }

  let demoB = null;
  function demoBoard() {
    if (!demoB) {
      const now = Date.now() / 1000;
      demoB = { project: { name: 'Sunrise', about: 'A habit app that helps people start the day with a short walk.' },
        tasks: [{ id: 'dt1', title: 'Write the landing page', notes: 'Hero, three features, pricing', status: 'todo', created_at: now - 900 },
          { id: 'dt2', title: 'Set up the waitlist form', notes: '', status: 'assigned', agent: 'demo-0', agent_title: 'Demo: Running commands', assigned_at: now - 400, created_at: now - 2000 },
          { id: 'dt3', title: 'Pick the app name', notes: '', status: 'done', created_at: now - 9000, done_at: now - 3000 }],
        ideas: [{ id: 'di1', title: 'A 7-day starter plan for new users', why: 'Gives first users a reason to come back daily.', at: now - 600, new: true },
          { id: 'di2', title: 'Share a progress video each week', why: 'People love showing progress; it is free marketing.', at: now - 600 }],
        suggestions: [{ id: 'ds1', title: 'Launch to one community first', advice: 'Apps that launched into a single niche forum got their first 100 users faster. Pick one community and serve it well.', source_title: 'Demo source', source_url: 'https://example.com', at: now - 1200, new: true }],
        runs: params.has('office-lab') ? { research: { status: 'running', started_at: now - 40 }, brainstorm: { status: 'running', started_at: now - 10 } } : {} };
    }
    demoB.progress = { done: demoB.tasks.filter(t => t.status === 'done').length, total: demoB.tasks.length };
    return JSON.parse(JSON.stringify(demoB));
  }
  function demoBoardPost(body) {
    const b = demoB, t = b.tasks.find(x => x.id === body.id);
    let result = true;
    if (body.action === 'add') b.tasks.push(result = { id: 'dt' + Math.random().toString(36).slice(2, 7), title: body.title, notes: body.notes || '', status: 'todo', created_at: Date.now() / 1000 });
    if (body.action === 'assign' && t) { const a = data.agents.find(x => x.id === body.agent) || data.agents[0]; Object.assign(t, { status: 'assigned', agent: a.id, agent_title: a.title, assigned_at: Date.now() / 1000 }); result = t; }
    if (body.action === 'done' && t) { t.status = 'done'; result = t; }
    if (body.action === 'reopen' && t) t.status = t.agent ? 'assigned' : 'todo';
    if (body.action === 'remove') b[body.list] = b[body.list].filter(x => x.id !== body.id);
    if (body.action === 'project') b.project = { name: body.name, about: body.about };
    if (body.action === 'seen') b[body.list].forEach(c => delete c.new);
    if (body.action === 'lab') b.runs[body.kind] = { status: 'running', started_at: Date.now() / 1000 };
    return { ok: true, result, board: demoBoard() };
  }
  function demoUsage() {
    const now = Date.now() / 1000, out = params.get('office-out') || '';
    const hours = Array.from({ length: 24 }, (_, i) => ({ at: now - (23 - i) * 3600, claude: Math.round(3e5 + 2.5e6 * Math.abs(Math.sin(i / 3))), codex: i % 5 === 0 ? 4e5 : 0, other: 0 }));
    return { checked_at: now, hours, plans: [
      { id: 'claude', name: 'Claude', out: out.includes('claude'), back_at: now + 5400, top: out.includes('claude') ? 100 : 52, windows: [{ label: '5H', percent: out.includes('claude') ? 100 : 52, resets_at: now + 5400 }, { label: 'WEEK', percent: 39, resets_at: now + 3 * 86400 }] },
      { id: 'codex', name: 'Codex', out: out.includes('codex'), back_at: now + 2 * 86400, top: 40, windows: [{ label: 'WEEK', percent: out.includes('codex') ? 100 : 40, resets_at: now + 2 * 86400 }] }] };
  }
  // ── The roster: every agent and every helper, and one helper's steps, live ──
  const rosterList = document.querySelector('#office-roster-list .or-list');
  const helperView = document.getElementById('office-helper');
  const listView = document.getElementById('office-roster-list');
  let helperSel = null, helperTimer = null, helperBusy = false, helperGone = false, lastRosterKey = '';
  const stateClass = act => act === 'your_turn' ? 'you' : BUSY.has(act) ? 'busy' : 'rest';
  const toolName = t => String(t || '').replace(/^mcp__/, '');
  const findHelper = id => { for (const a of (data && data.agents) || []) { const h = (a.helpers || []).find(x => x.id === id); if (h) return [a, h]; } return [null, null]; };

  function renderRoster() {
    const agents = (data && data.agents) || [];
    const key = JSON.stringify([selected, helperSel, agents.map(a => [a.id, a.name, a.title, a.activity, a.bed, a.color, a.closing && a.closing.text, (a.helpers || []).map(h => [h.id, h.title, h.activity, h.tool])])]);
    if (key === lastRosterKey) return;
    lastRosterKey = key;
    if (!agents.length) { rosterList.innerHTML = '<p class="or-empty">Nobody is in yet. Start Hermes, Claude Code or Codex in a terminal and it takes a desk.</p>'; return; }
    rosterList.innerHTML = agents.map(a => {
      const helpers = (a.helpers || []).map(h => `<button class="or-helper${h.depth > 1 ? ' deep' : ''}${helperSel === h.id ? ' on' : ''}" data-helper="${esc(h.id)}">
          <em class="office-swatch" style="background:${esc(assign(h.id))}"></em><span class="or-name">${esc(h.title || 'Helper')}</span>
          <span class="or-state ${stateClass(h.activity)}"><i></i>${esc(WORDS[h.activity] || h.activity || '')}${h.tool ? ' · ' + esc(toolName(h.tool)) : ''}</span></button>`).join('');
      return `<div class="or-agent${selected === a.id ? ' on' : ''}"><button class="or-row" data-id="${esc(a.id)}">
          <em class="office-swatch" style="background:${esc(a.color)}"></em><span class="or-name">${nameTag(a)}</span><span class="or-go">${selected === a.id ? 'Open' : a.tty && !demo ? 'Talk ›' : 'Open ›'}</span>
          <span class="or-title">${esc(a.title)}</span>${a.closing && !BUSY.has(a.activity) ? `<span class="or-close${a.closing.question ? ' ask' : ''}">${esc(a.closing.text)}</span>` : ''}
          <span class="or-state ${a.bed ? 'rest' : stateClass(a.activity)}"><i></i>${esc(plateWords(a))}${(a.helpers || []).length ? ` · ${a.helpers.length} helper${a.helpers.length === 1 ? '' : 's'}` : ''}</span></button>${helpers}</div>`;
    }).join('');
  }
  document.getElementById('office-roster').addEventListener('click', e => {
    const h = e.target.closest('[data-helper]');
    if (h) { openHelper(h.dataset.helper); return; }
    if (e.target.closest('.or-back')) { closeHelper(); return; }
    const row = e.target.closest('.or-row, [data-agent]');
    if (row) { selected = row.dataset.id || row.dataset.agent; setFolded(true); lastPlateKey = ''; lastRosterKey = ''; renderCard(); renderRoster(); draw(); }
  });

  function openHelper(id) {
    setPanel('floor');
    if (helperSel === id && !helperView.hidden) return;
    helperSel = id; helperGone = false; lastPlateKey = ''; lastRosterKey = '';
    listView.hidden = true; helperView.hidden = false; helperView.scrollTop = 0;
    helperView.classList.remove('finished');
    helperView.innerHTML = '<button class="or-back">← Everyone on the floor</button><p class="or-empty" style="margin-top:14px">Reading its steps…</p>';
    clearInterval(helperTimer); readHelper(); helperTimer = setInterval(readHelper, 2000);
    renderRoster(); draw();
  }
  function closeHelper() {
    helperSel = null; clearInterval(helperTimer); helperTimer = null;
    helperView.hidden = true; listView.hidden = panel !== 'floor'; lastPlateKey = ''; lastRosterKey = '';
    renderRoster(); draw();
  }
  function demoHelper(id) {
    const [a, h] = findHelper(id);
    if (!h) return null;
    const now = Date.now() / 1000, tools = { browsing: ['web_search', 'pixel art office tycoon games'], writing: ['write_file', 'notes/draft.md'], reading: ['read_file', 'docs/ARCHITECTURE.md'], typing: ['terminal', 'make check'], thinking: ['search_files', 'HELPER_SPOTS'] };
    const [tool, arg] = tools[h.activity] || ['terminal', 'ls'];
    return { id, owner: a.id, owner_title: a.title, helper: { ...h, goal: `Demo task for ${h.title}: gather what the lead agent needs and report back.`, started_at: now - 240, last_at: now - 4, tool },
      steps: [{ at: now - 240, kind: 'task', text: `Demo task for ${h.title}.` }, { at: now - 200, kind: 'tool', tool: 'read_file', text: 'README.md' },
        { at: now - 120, kind: 'said', text: 'Found the relevant section; checking one more source.' }, { at: now - 4, kind: 'tool', tool, text: arg }] };
  }
  async function readHelper() {
    if (!helperSel || helperBusy || !active() || helperGone) return;
    helperBusy = true;
    const id = helperSel;
    try {
      let d;
      if (demo) d = demoHelper(id);
      else {
        const res = await fetchT('/api/office/helper?id=' + encodeURIComponent(id), { cache: 'no-store' }, 5000);
        d = res.status === 404 ? null : await res.json();
        if (res.status !== 404 && !res.ok) return;
      }
      if (helperSel !== id) return;
      if (!d) { helperGone = true; clearInterval(helperTimer); helperView.classList.add('finished'); const st = helperView.querySelector('.oc-state'); if (st) { st.className = 'oc-state'; st.querySelector('b').textContent = 'Finished'; } else helperView.querySelector('.or-empty').textContent = 'This helper has finished.'; return; }
      paintHelper(d);
    } catch (e) { /* next tick */ } finally { helperBusy = false; }
  }
  function paintHelper(d) {
    const h = d.helper, now = Date.now() / 1000, color = assign(h.id);
    const steps = (d.steps || []).slice().reverse();
    const kindWord = h.kind === 'claude' ? 'Claude Code helper' : 'Hermes helper';
    const time = at => at ? ago(now - at) : '';
    helperView.innerHTML = `<button class="or-back">← Everyone on the floor</button>
      <div class="or-kind"><em class="office-swatch" style="background:${esc(color)}"></em>${esc(kindWord)}${h.model ? ' · ' + esc(h.model) : ''}${h.depth > 1 ? ' · helper of a helper' : ''}</div>
      <h3>${esc(h.title || 'Helper')}</h3>
      <p class="or-for">Working for <button data-agent="${esc(d.owner)}">${(() => { const o = ((data && data.agents) || []).find(x => x.id === d.owner); return o ? nameTag(o) + ' · ' : ''; })()}${esc(d.owner_title)}</button>${h.started_at ? ` · out ${ago(now - h.started_at)}` : ''}</p>
      <span class="oc-state ${stateClass(h.activity)}"><i></i><b>${esc(WORDS[h.activity] || h.activity || 'Working')}${h.tool ? ' · ' + esc(toolName(h.tool)) : ''}</b></span>
      ${h.goal ? `<div class="or-goal"><small>Its task</small><p>${esc(h.goal)}</p></div>` : ''}
      <h4>Latest steps</h4>
      <ol class="or-steps">${steps.length ? steps.map(st => `<li class="${esc(st.kind)}"><time>${esc(time(st.at))}</time><b>${st.kind === 'tool' ? esc(toolName(st.tool)) : st.kind === 'said' ? 'Said' : 'Task'}</b><span>${esc(st.text || '')}</span></li>`).join('') : '<li class="said"><time></time><b>Nothing yet</b><span>It has not made a move.</span></li>'}</ol>`;
  }

  // ── Panel tabs: the floor, the three boards, usage ──
  const boardEl = document.getElementById('office-board');
  const rosterEl = document.getElementById('office-roster');
  let panel = 'floor', boardMsg = ['', false], editingProject = false;
  function setPanel(name) {
    const changed = panel !== name;
    panel = name;
    setFolded(false);
    const floor = name === 'floor';
    boardEl.hidden = floor;
    listView.hidden = !floor || !!helperSel; helperView.hidden = !floor || !helperSel;
    if (!floor) { if (changed) boardEl.scrollTop = 0; renderBoard(changed || !boardEl.firstChild); }
    if ((name === 'ideas' || name === 'lab') && board && board[name === 'ideas' ? 'ideas' : 'suggestions'].some(c => c.new)) boardPost({ action: 'seen', list: name === 'ideas' ? 'ideas' : 'suggestions' }, true);
  }
  // An inspector is temporary, not a third column. Start closed and keep the terminal's width.
  function setFolded(on) {
    const restoreFocus = on && rosterEl.contains(document.activeElement);
    shell.classList.toggle('roster-folded', on);
    if (on && helperSel) closeHelper();
    markNew();
    rosterEl.querySelectorAll('.or-tabs button[data-tab]').forEach(b => b.setAttribute('aria-expanded', String(!on && b.dataset.tab === panel)));
    if (restoreFocus) rosterEl.querySelector(`[data-tab="${panel}"]`).focus({ preventScroll: true });
  }
  rosterEl.querySelector('.or-tabs').addEventListener('click', e => {
    if (e.target.closest('.or-fold')) { setFolded(true); return; }
    const b = e.target.closest('button[data-tab]');
    if (b) { if (panel === b.dataset.tab && !shell.classList.contains('roster-folded')) setFolded(true); else setPanel(b.dataset.tab); }
  });
  hud.querySelector('.oh-usage').addEventListener('click', () => setPanel('usage'));
  document.addEventListener('pointerdown', e => {
    if (e.button !== 0 || !active() || shell.classList.contains('roster-folded') || rosterEl.contains(e.target)) return;
    if (e.target.closest('.office-hit.board, .office-hit.helper, .oh-usage')) return;
    setFolded(true);
  });

  async function boardPost(body, quiet) {
    try {
      let out;
      if (demo) out = demoBoardPost(body);
      else {
        const res = await fetchT('/api/office/board', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }, 9000);
        out = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error(out.error || 'That did not work.');
      }
      board = out.board; lastBoardKey = '';
      if (!quiet) boardMsg = [{ add: 'Added to the board.', assign: `Typed into ${(out.result || {}).agent_title || 'its terminal'}.`, done: 'Done.',
        lab: body.kind === 'research' ? 'The researcher is in the lab.' : 'The brainstormer is on it.', project: 'Project saved.' }[body.action] || '', false];
      if (body.action === 'done') { toast('Task done', (out.result || {}).title || 'Nice work'); confetti(); }
      renderBoard(true); markNew(); draw();
      return out;
    } catch (err) { boardMsg = [err.name === 'AbortError' ? 'It did not answer in time.' : err.message, true]; renderBoard(true); }
  }

  let lastBoardKey = '';
  function agentOptions() {
    const agents = ((data && data.agents) || []).filter(a => a.tty || demo);
    return '<option value="auto">Auto: whoever is free</option>' + agents.map(a => `<option value="${esc(a.id)}">${esc(nameOf(a))}: ${esc(a.title)}${a.bed ? ' (in bed)' : ''}</option>`).join('');
  }
  function renderBoard(force) {
    if (panel === 'floor') return;
    const key = JSON.stringify([panel, board, usage && usage.checked_at, editingProject, boardMsg, ((data && data.agents) || []).map(a => [a.id, a.title, a.name, a.todos])]);
    if (!force && key === lastBoardKey) return;
    if (!force && (shell.classList.contains('roster-folded') ||
      (boardEl.contains(document.activeElement) && /INPUT|TEXTAREA|SELECT/.test(document.activeElement.tagName)) ||
      [...boardEl.querySelectorAll('input, textarea')].some(e => e.value !== e.defaultValue))) return;
    lastBoardKey = key;
    const b = board || { project: {}, tasks: [], ideas: [], suggestions: [], runs: {}, progress: { done: 0, total: 0 } };
    const msg = `<p class="ob-msg${boardMsg[1] ? ' bad' : ''}">${esc(boardMsg[0])}</p>`;
    const project = () => {
      const pr = b.project || {}, pct = b.progress.total ? Math.round(b.progress.done / b.progress.total * 100) : 0;
      if (editingProject || !pr.name) return `<form class="ob-form" data-form="project"><input name="name" maxlength="80" placeholder="What are you building?" value="${esc(pr.name || '')}" required>
        <textarea name="about" maxlength="400" placeholder="One or two lines about it, so the brainstormer and researcher know">${esc(pr.about || '')}</textarea>
        <div class="ob-row"><button class="ob-btn gold" type="submit">Save project</button>${pr.name ? '<button class="ob-btn" type="button" data-act="cancel-project">Cancel</button>' : ''}</div></form>`;
      return `<div class="ob-project"><button class="ob-edit" data-act="edit-project">Edit</button><small>The project</small><b>${esc(pr.name)}</b>${pr.about ? `<p>${esc(pr.about)}</p>` : ''}
        <div class="ob-bar"><i style="width:${pct}%"></i></div><p>${b.progress.done} of ${b.progress.total} tasks done${b.progress.total ? ` · ${pct}%` : ''}</p></div>`;
    };
    if (panel === 'tasks') {
      const card = t => `<div class="ob-card${t.status === 'done' ? ' done' : ''}" data-id="${esc(t.id)}"><button class="ob-x" data-act="remove" data-list="tasks" title="Remove">✕</button>
          <b>${esc(t.title)}<span class="ob-chip ${t.status}">${t.status === 'todo' ? 'To do' : t.status === 'assigned' ? 'Assigned' : 'Done'}</span></b>${t.notes ? `<p>${esc(t.notes)}</p>` : ''}
          ${t.agent_title && t.status !== 'done' ? `<div class="ob-meta">Sent ${t.assigned_at ? ago(Date.now() / 1000 - t.assigned_at) + ' ago' : ''}</div>` : ''}
          <div class="ob-actions">${t.status === 'done' ? '<button class="ob-btn" data-act="reopen">Reopen</button>'
            : `<select class="ob-pick" aria-label="Assign to">${agentOptions()}</select><button class="ob-btn gold" data-act="assign">${t.status === 'assigned' ? 'Send again' : 'Assign'}</button><button class="ob-btn" data-act="done">Done</button>`}</div></div>`;
      // By agent: its name in its colour, its own to-do list (live from its chat), the board tasks it has.
      const { groups: byAgent, loose } = tasksByAgent();
      const groups = byAgent.map(g => {
        const a = g.agent, n = g.own.length + g.board.length, done = g.own.filter(x => x.status === 'done').length + g.board.filter(t => t.status === 'done').length;
        const own = g.own.map(x => `<li class="${x.status}"><i>${STEP[x.status]}</i><span>${esc(x.text)}</span></li>`).join('');
        return `<section class="ob-agent" style="--agent:${esc(nameColor(a.color))}">
          <header><em class="office-swatch" style="background:${esc(a.color)}"></em>${nameTag(a)}<span class="ob-agent-title">${esc(a.title)}</span><small>${n ? `${done}/${n}` : ''}</small></header>
          ${own ? `<ol class="ob-steps">${own}</ol>` : ''}${g.board.map(card).join('')}
          ${!n ? `<p class="ob-empty">No list yet. It shows up here when ${esc(nameOf(a))} plans its work.</p>` : ''}</section>`;
      }).join('') + (loose.length ? `<section class="ob-agent loose"><header><b class="agent-name">Not assigned</b><small>${loose.length}</small></header>${loose.map(card).join('')}</section>` : '');
      boardEl.innerHTML = `<h3>Task board</h3><p class="ob-sub">Each agent's own to-do list fills in by itself as it plans its work. Add a task and Assign types it into an agent's terminal (Auto picks whoever is free); Done moves it off the board.</p>
        ${project()}<form class="ob-form" data-form="task"><input name="title" maxlength="140" placeholder="Add a task" required><div class="ob-row"><input name="notes" maxlength="600" placeholder="Details (optional)"><button class="ob-btn gold" type="submit">Add</button></div></form>${msg}
        ${groups || '<p class="ob-empty">Nobody is on the floor yet.</p>'}`;
    } else if (panel === 'ideas' || panel === 'lab') {
      const isIdeas = panel === 'ideas', kind = isIdeas ? 'brainstorm' : 'research', list = isIdeas ? b.ideas : b.suggestions, run = (b.runs || {})[kind];
      const who = isIdeas ? 'The brainstormer' : 'The researcher';
      const busy = run && run.status === 'running';
      const runLine = busy ? `<div class="ob-run"><i class="ob-spin"></i>${who} ${isIdeas ? 'is thinking up ideas' : 'is in the lab reading sources'} · ${ago(Date.now() / 1000 - run.started_at)}</div>`
        : run && run.status === 'failed' ? `<p class="ob-msg bad">Last run: ${esc(run.error || 'it did not finish')}</p>` : '';
      const card = c => `<div class="ob-card${c.new ? ' new' : ''}" data-id="${esc(c.id)}"><button class="ob-x" data-act="remove" data-list="${isIdeas ? 'ideas' : 'suggestions'}" title="Dismiss">✕</button>
          <b>${esc(c.title)}</b><p>${esc(isIdeas ? c.why : c.advice)}</p>
          ${!isIdeas && c.source_url ? `<a href="${esc(c.source_url)}" target="_blank" rel="noopener noreferrer">${esc(c.source_title || 'Source')} ↗</a>` : !isIdeas && c.source_title ? `<div class="ob-meta">${esc(c.source_title)}</div>` : ''}
          <div class="ob-actions"><button class="ob-btn" data-act="to-task">Make it a task</button><span class="ob-meta">${ago(Date.now() / 1000 - c.at)} ago</span></div></div>`;
      boardEl.innerHTML = `<h3>${isIdeas ? 'Idea board' : 'The lab'}</h3>
        <p class="ob-sub">${isIdeas ? 'A brainstorming agent pins ideas for the project here.' : 'A researcher reads what others learned and chalks up advice, with the source.'} It runs only when you press the button (one model call${isIdeas ? '' : ' with web search'}).</p>
        ${b.project && b.project.name ? '' : '<p class="ob-msg bad">Name the project on the Tasks tab first, so it knows what to work on.</p>'}
        <div class="ob-row"><button class="ob-btn gold" data-act="lab" data-kind="${kind}" ${busy ? 'disabled' : ''}>${isIdeas ? 'Brainstorm 5 ideas' : 'Send the researcher'}</button></div>${msg}${runLine}
        ${list.length ? list.map(card).join('') : `<p class="ob-empty">${isIdeas ? 'No ideas yet.' : 'No suggestions yet.'}</p>`}`;
    } else if (panel === 'usage') renderUsage();
  }

  function renderUsage() {
    const u = usage;
    if (!u) { boardEl.innerHTML = '<h3>AI usage</h3><p class="ob-empty">Reading your plans…</p>'; return; }
    const plan = p => `<div class="ou-plan${p.out ? ' out' : ''}"><header><b>${esc(p.name)}</b><span>${p.out ? 'Out until ' + esc(backWhen(p.back_at)) : p.error ? esc(p.error) : p.top != null ? Math.round(p.top) + '% used' : ''}</span></header>
        ${p.windows.map(w => `<div class="ou-win${w.percent >= 90 ? ' hot' : w.percent >= 70 ? ' warm' : ''}"><span>${esc(w.label)}</span><div class="ou-track"><i style="width:${Math.min(100, w.percent)}%"></i></div><span>${Math.round(w.percent)}%</span>${w.resets_at ? `<small>resets ${esc(backWhen(w.resets_at))}</small>` : ''}</div>`).join('')}</div>`;
    const hrs = u.hours || [], max = Math.max(1, ...hrs.map(h => h.claude + h.codex + h.other));
    const bw = 300 / Math.max(1, hrs.length);
    const bars = hrs.map((h, i) => {
      let y = 100, out = '';
      [['claude', '#d2aa5f'], ['codex', '#86cbc2'], ['other', '#8a8578']].forEach(([k, c]) => {
        const hgt = h[k] / max * 92; if (hgt <= 0) return; y -= hgt;
        out += `<rect x="${(i * bw + 1).toFixed(1)}" y="${y.toFixed(1)}" width="${(bw - 2).toFixed(1)}" height="${hgt.toFixed(1)}" rx="1.5" fill="${c}"><title>${clockTime(h.at)}: ${num(h[k])} ${k} tokens</title></rect>`;
      });
      return out;
    }).join('');
    const total = hrs.reduce((n, h) => n + h.claude + h.codex + h.other, 0);
    const fmt = n => n >= 1e6 ? (n / 1e6).toFixed(1) + 'M' : n >= 1e3 ? Math.round(n / 1e3) + 'k' : String(n);
    boardEl.innerHTML = `<h3>AI usage</h3><p class="ob-sub">Your subscription limits, read every 2 minutes. When a plan hits 100%, its agents climb into the bunk beds until it resets.</p>
      ${(u.plans || []).map(plan).join('')}
      <div class="ou-chart"><div class="ob-group">Hermes tokens, last 24 hours · ${fmt(total)}</div>
        <svg viewBox="0 0 300 108" preserveAspectRatio="none" role="img" aria-label="Tokens per hour">${bars}<line x1="0" y1="100.5" x2="300" y2="100.5" stroke="rgba(255,255,255,.12)"/></svg>
        <div class="ou-key"><span><i style="background:#d2aa5f"></i>Claude</span><span><i style="background:#86cbc2"></i>Codex</span><span><i style="background:#8a8578"></i>Other</span><span style="margin-left:auto">peak ${fmt(max)}/h</span></div></div>`;
  }

  boardEl.addEventListener('submit', e => {
    e.preventDefault();
    const f = e.target, d = Object.fromEntries(new FormData(f));
    if (f.dataset.form === 'task') { boardPost({ action: 'add', title: d.title, notes: d.notes }); }
    else if (f.dataset.form === 'project') { editingProject = false; boardPost({ action: 'project', name: d.name, about: d.about }); }
  });
  boardEl.addEventListener('click', e => {
    const btn = e.target.closest('[data-act]');
    if (!btn || btn.disabled) return;
    const card = btn.closest('.ob-card'), id = card && card.dataset.id, act = btn.dataset.act;
    if (act === 'edit-project') { editingProject = true; renderBoard(true); return; }
    if (act === 'cancel-project') { editingProject = false; renderBoard(true); return; }
    if (act === 'assign') { btn.disabled = true; boardPost({ action: 'assign', id, agent: card.querySelector('.ob-pick').value }); return; }
    if (act === 'done' || act === 'reopen') { boardPost({ action: act, id }); return; }
    if (act === 'remove') { boardPost({ action: 'remove', list: btn.dataset.list, id }, true); return; }
    if (act === 'lab') { btn.disabled = true; boardPost({ action: 'lab', kind: btn.dataset.kind }); return; }
    if (act === 'to-task') {
      const list = panel === 'ideas' ? board.ideas : board.suggestions, c = list.find(x => x.id === id);
      if (c) boardPost({ action: 'add', title: c.title, notes: panel === 'ideas' ? c.why : c.advice + (c.source_url ? ' Source: ' + c.source_url : ''), from: c.id }).then(() => setPanel('tasks'));
    }
  });
  // ── The docked task board: agents waiting on you first, then open tasks, then what each is doing. ──
  let lastDockKey = '';
  function renderDock() {
    const agents = ((data && data.agents) || []), b = board || { tasks: [] };
    const key = JSON.stringify([b.tasks, agents.map(a => [a.id, a.name, a.title, a.activity, a.bed, a.color, a.last_at, a.closing && a.closing.text, a.todos]), innerWidth]);
    if (key === lastDockKey || dockEl.contains(document.activeElement) && document.activeElement.tagName === 'SELECT') return;
    lastDockKey = key;
    const now = Date.now() / 1000, cards = [];
    const foot = (a, extra) => `<div class="od-foot"><span class="oc-avatar sm" style="--agent:${esc(a.color)}"></span><span>${nameTag(a)} · ${esc(a.title)}</span>${extra || ''}</div>`;
    agents.filter(a => !a.bed && a.activity === 'your_turn').forEach(a => cards.push(`<button type="button" class="od-card you" data-agent="${esc(a.id)}"><div class="od-top"><b>${esc(a.closing ? a.closing.text : 'Finished, and waiting on you')}</b><span class="od-badge you">! Needs you</span></div>${foot(a, a.last_at ? `<time>${ago(now - a.last_at)} ago</time>` : '')}</button>`));
    (b.tasks || []).filter(t => t.status !== 'done').forEach(t => cards.push(`<div class="od-card" data-id="${esc(t.id)}"><div class="od-top"><b>${esc(t.title)}</b><span class="od-badge ${t.status}">${t.status === 'assigned' ? 'Assigned' : 'To do'}</span></div>${t.notes ? `<p>${esc(t.notes)}</p>` : ''}
      ${t.status === 'assigned' ? `<div class="od-foot"><span>With ${esc(t.agent_title || 'an agent')}</span>${t.assigned_at ? `<time>${ago(now - t.assigned_at)} ago</time>` : ''}</div>` : `<div class="od-assign"><select aria-label="Assign to">${agentOptions()}</select><button type="button" class="od-btn gold" data-act="assign">Assign</button></div>`}</div>`));
    agents.filter(a => !a.bed && a.activity !== 'your_turn').forEach(a => { const d = (a.todos || []).find(x => x.status === 'doing'); if (d) cards.push(`<button type="button" class="od-card" data-agent="${esc(a.id)}"><div class="od-top"><b>${esc(d.text)}</b><span class="od-badge doing">Working</span></div>${foot(a)}</button>`); });
    const open = (b.tasks || []).filter(t => t.status !== 'done').length, waiting = agents.filter(a => !a.bed && a.activity === 'your_turn').length;
    const max = Math.max(1, Math.min(3, Math.floor((parseFloat(dockEl.style.width) || 900) / 250)));
    dockEl.innerHTML = `<header class="od-head"><h3><svg viewBox="0 0 16 16" aria-hidden="true"><path d="m4 8 3 3 5-6"/></svg>Task board</h3><small>${[waiting ? `${waiting} need${waiting === 1 ? 's' : ''} you` : null, `${open} open`].filter(Boolean).join(' · ')}</small>
      <button type="button" class="od-btn gold" data-go="tasks">+ <span>Add task</span></button><button type="button" class="od-btn" data-go="ideas">Ideas → <span>Tasks</span></button><button type="button" class="od-btn" data-go="lab"><span>Send</span> researcher…</button></header>
      <div class="od-cards">${cards.slice(0, max).join('') || '<p class="od-empty">Nothing waiting on you. Add a task to hand work to whoever is free.</p>'}</div>`;
  }
  dockEl.addEventListener('click', e => {
    const go = e.target.closest('[data-go]');
    if (go) { setPanel(go.dataset.go); if (go.dataset.go === 'tasks') { const i = boardEl.querySelector('input[name="title"]'); if (i) i.focus({ preventScroll: true }); } return; }
    const as = e.target.closest('[data-act="assign"]');
    if (as) { const c = as.closest('.od-card'); as.disabled = true; boardPost({ action: 'assign', id: c.dataset.id, agent: c.querySelector('select').value }).then(() => { lastDockKey = ''; renderDock(); }); return; }
    const ag = e.target.closest('[data-agent]');
    if (ag) { selected = ag.dataset.agent; lastPlateKey = ''; renderCard(); renderRoster(); draw(); }
  });
  // New cards on the idea board or in the lab light up their tab.
  function markNew() {
    const tabs = rosterEl.querySelectorAll('.or-tabs button');
    tabs.forEach(t => {
      const k = t.dataset.tab, list = k === 'ideas' ? board && board.ideas : k === 'lab' ? board && board.suggestions : null;
      t.classList.toggle('new', !!(list && list.some(c => c.new)) && (panel !== k || shell.classList.contains('roster-folded')));
    });
    const out = ((usage && usage.plans) || []).filter(p => p.out);
    const pill = hud.querySelector('.oh-usage');
    pill.classList.toggle('out', out.length > 0);
    hud.querySelector('.oh-usage-text').textContent = usage ? (usage.plans || []).filter(p => p.top != null).map(p => `${p.name} ${Math.round(p.top)}%`).join(' · ') || 'Usage' : 'Usage';
  }
  let lastUsageAt = 0, prevRuns = {};
  async function pollBoards() {
    try {
      if (demo) board = demoBoard();
      else { const r = await fetchT('/api/office/board', { cache: 'no-store' }, 5000); if (r.ok) board = await r.json(); }
      // A lab run that just finished gets a toast.
      Object.entries((board && board.runs) || {}).forEach(([k, r]) => {
        if (prevRuns[k] === 'running' && r.status === 'done') toast(k === 'research' ? 'From the lab' : 'New ideas', `${r.count} ${k === 'research' ? 'suggestions' : 'ideas'} on the board`);
        prevRuns[k] = r.status;
      });
      if (demo) usage = demoUsage();
      else if (Date.now() - lastUsageAt > 60000) { lastUsageAt = Date.now(); const r = await fetchT('/api/office/usage', { cache: 'no-store' }, 15000); if (r.ok) usage = await r.json(); }
      applyUsage(); markNew(); renderBoard(); renderHud();
      const hadDock = dockEl.childElementCount; renderDock(); if (!hadDock && dockEl.childElementCount) { fit(); draw(); }
    } catch (e) { /* the floor still works */ }
  }

  // Full screen: the top bar goes away and the window (or the screen) is all office.
  function setImmersive(on) {
    document.body.classList.toggle('office-immersive', on);
    hud.querySelector('.oh-full').setAttribute('aria-pressed', String(on));
    if (on && document.fullscreenEnabled && !document.fullscreenElement) document.documentElement.requestFullscreen().catch(() => {});
    if (!on && document.fullscreenElement) document.exitFullscreen().catch(() => {});
    requestAnimationFrame(() => { fit(); draw(); });
  }
  hud.querySelector('.oh-full').addEventListener('click', () => setImmersive(!document.body.classList.contains('office-immersive')));
  document.addEventListener('fullscreenchange', () => { if (!document.fullscreenElement && document.body.classList.contains('office-immersive')) setImmersive(false); else if (active()) { fit(); draw(); } });

  let polling = false;
  async function poll() {
    if (!active() || polling) return;
    polling = true;
    try {
      let next;
      if (demo) next = demoData();
      else {
        const res = await fetchT('/api/office/agents', { cache: 'no-store' }, 6000);
        if (!res.ok) throw new Error(res.status);
        next = await res.json();
      }
      (next.agents || []).forEach(a => { a.color = a.kind === 'claude' ? '#c96442' : a.kind === 'codex' ? '#d9d6cf' : assign(a.id); });
      tick(seen, next);
      data = next; error = false;
      applyUsage(); updateTrips();
      const awake = data.agents.filter(a => !a.bed), inBed = data.agents.length - awake.length;
      const n = data.agents.length, busy = awake.filter(a => BUSY.has(a.activity)).length;
      const you = awake.filter(a => a.activity === 'your_turn').length;
      const out = data.agents.reduce((sum, a) => sum + (a.helpers || []).length, 0);
      summary.textContent = n === 0 ? 'Nobody is in yet' : [
        `${n} at ${n === 1 ? 'a desk' : 'their desks'}`, busy ? `${busy} working` : 'nobody working',
        out ? `${out} helper${out === 1 ? '' : 's'} out` : null, inBed ? `${inBed} in bed` : null,
        you ? `${you} waiting on you` : null].filter(Boolean).join(' · ');
      renderCard();
      applyUsage();
      renderRoster();
      renderHud();
      await pollBoards();
    } catch (e) {
      error = true;
      summary.textContent = 'The office is dark: the GoldWare server did not answer';
      renderHud();
    } finally { polling = false; }
    if (still) draw();
  }

  function active() { return tab.classList.contains('active') && !document.hidden; }
  function start() {
    if (!active()) return;
    fit();
    if (!poller) { poll(); poller = setInterval(poll, 3000); }
    if (!timer && !still) timer = setInterval(() => { if (!active()) return stop(); frame++; tickWalks(); tickTrips(); draw(); }, 1000 / FPS);
    draw();
  }
  function stop() { clearInterval(timer); clearInterval(poller); timer = poller = null; }
  new MutationObserver(() => {
    if (!tab.classList.contains('active') && document.body.classList.contains('office-immersive')) setImmersive(false);
    if (!active() && consoleFor) { selected = null; renderCard(); }
  }).observe(tab, { attributes: true, attributeFilter: ['class'] });
  new MutationObserver(() => (active() ? start() : stop())).observe(tab, { attributes: true, attributeFilter: ['class'] });
  document.addEventListener('visibilitychange', () => (active() ? start() : stop()));

  // Desks, plates, helpers and boards act on pointer-down: the layer is rebuilt when the floor
  // changes, and a rebuild between press and release would swallow a click. Keyboard (Enter/Space on
  // a focused target) still arrives as a click with no pointer.
  function pickTarget(e) {
    const hit = e.target.closest('.office-hit, .office-plate[data-id]');
    if (!hit) return;
    if (hit.dataset.helper) { openHelper(hit.dataset.helper); return; }
    if (hit.dataset.board) { setPanel(hit.dataset.board); return; }
    selected = selected === hit.dataset.id ? null : hit.dataset.id;
    lastPlateKey = '';
    renderCard(); renderRoster(); draw();
  }
  desksLayer.addEventListener('pointerdown', e => { if (e.button === 0 && e.isPrimary) { e.preventDefault(); pickTarget(e); } });
  desksLayer.addEventListener('click', e => { if (e.detail === 0) pickTarget(e); });
  card.addEventListener('click', e => { if (e.target.closest('.office-card-close')) { selected = null; lastPlateKey = ''; renderCard(); draw(); } });
  document.addEventListener('keydown', e => {
    if (!active()) return;
    if (e.key === 'Escape' && !shell.classList.contains('roster-folded')) { setFolded(true); return; }
    if ((e.key === 'f' || e.key === 'F') && !e.metaKey && !e.ctrlKey && !e.altKey && !(e.target.closest && e.target.closest('input, textarea, select, [contenteditable]'))) { e.preventDefault(); setImmersive(!document.body.classList.contains('office-immersive')); return; }
    if (e.key === 'Escape' && selected) { selected = null; lastPlateKey = ''; renderCard(); draw(); return; }
    // Left and right step through the desks in reading order, the boss first. Never while typing
    // somewhere (digits are already the tab shortcuts).
    if (e.metaKey || e.ctrlKey || e.altKey || (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') || (e.target.closest && e.target.closest('input, textarea, select, [contenteditable], #office-roster'))) return;
    const ids = ['boss', ...((data && data.agents) || []).map(a => a.id)];
    const at = ids.indexOf(selected), step = e.key === 'ArrowRight' ? 1 : -1;
    e.preventDefault();
    selected = ids[at < 0 ? (step > 0 ? 0 : ids.length - 1) : (at + step + ids.length) % ids.length]; lastPlateKey = '';
    renderCard(); draw();
  });
  start();
})();
