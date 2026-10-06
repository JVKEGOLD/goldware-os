// Headless Chrome pass over the Office console's group chat. It serves the real dashboard files from this
// repo plus a fixture for the two Office endpoints, on its own free port, so it never touches the real
// server, the agents on this Mac, or any data folder.
//   node tests/office_chat_cdp.mjs <screenshot dir> [width height]
// Set CHROME to use another browser binary. Exits 1 on any failure.
import { spawn } from 'node:child_process'; import fs from 'node:fs'; import path from 'node:path'; import http from 'node:http'; import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outdir = path.resolve(process.argv[2] || '.'), W = +(process.argv[3] || 1440), H = +(process.argv[4] || 900);
fs.mkdirSync(outdir, { recursive: true });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const now = Date.now() / 1000;
const mk = (id, name, extra = {}) => ({ id, tty: 'ttys0' + id.length, kind: 'hermes', title: 'Tidy the layout', name, closing: null, todos: [], ask: 'Tidy the layout', cwd: '/home/a/site',
  model: 'Opus 5.5', provider: 'anthropic', activity: 'idle', working: false, started_at: now - 600, last_at: now - 30, messages: 4, helpers: [], ...extra });
const agents = [mk('boss-1', 'Boss', { boss: true }), mk('fx-2', 'Bolt'), mk('fx-3', 'Pip')];
const turns = [
  { kind: 'you', text: 'Tidy the layout' }, { kind: 'did', text: 'Ran 2 commands' },
  { kind: 'handoff', helper: 'gh-1', n: 1, title: 'Check spacing', text: 'Check the spacing' },
  { kind: 'handoff', helper: 'gh-2', n: 2, title: 'Check type', text: 'Check the type' },
  { kind: 'send', to: 'gone-7', name: 'Mocha', text: 'Tidy the cards too. ' + 'More detail about the cards. '.repeat(30) },
  { kind: 'helper', helper: 'gh-1', n: 1, title: 'Check spacing', text: 'Spacing is even.' },
  { kind: 'helper', helper: 'gh-2', n: 2, title: 'Check type', text: '', working: true, activity: 'reading', tool: 'read_file' },
  { kind: 'agent', from: 'gone-7', name: 'Mocha', text: 'Cards tidied.' },
  { kind: 'agent', from: 'fx-2', name: 'Bolt', text: 'Footer fixed.', report: true },
  { kind: 'said', text: 'Done. The **layout** is tidy.' }];
const json = (res, o) => { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(o)); };
const types = { '.js': 'application/javascript', '.css': 'text/css', '.html': 'text/html' };
const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/api/office/agents') return json(res, { agents, home: '/home/a', rack: { ollama: false, units: [] }, topics: [] });
  if (u.pathname === '/api/office/chat') return json(res, { id: u.searchParams.get('id'), turns });
  if (u.pathname === '/api/office/screen') return json(res, { id: u.searchParams.get('id'), activity: 'idle', screen: 'fixture screen' });
  if (u.pathname === '/api/office/board') return json(res, { tasks: [], ideas: [], suggestions: [], project: {}, runs: {}, groupings: {} });
  if (u.pathname === '/api/office/settings') return json(res, { topics: [], presets: [], limits: { items: 12, label: 40, command: 200 } });
  if (u.pathname === '/api/office/usage') return json(res, { plans: [], hours: [], checked_at: now });
  if (u.pathname.startsWith('/api/')) return json(res, {});
  const file = u.pathname === '/' ? 'dashboard/index.html' : u.pathname.replace(/^\//, '');
  const full = path.join(root, file);
  if (!full.startsWith(path.join(root, 'dashboard') + path.sep) || !fs.existsSync(full)) { res.statusCode = 404; return res.end(); }
  res.setHeader('Content-Type', types[path.extname(full)] || 'application/octet-stream'); res.end(fs.readFileSync(full));
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const base = 'http://127.0.0.1:' + server.address().port;
const prof = fs.mkdtempSync(path.join(outdir, 'cdp-'));
const chrome = spawn(process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', ['--headless=new', `--user-data-dir=${prof}`, '--remote-debugging-port=0', `--window-size=${W},${H}`, 'about:blank'], { stdio: 'ignore' });
let port; for (let i = 0; i < 60 && !port; i++) { await sleep(200); try { port = fs.readFileSync(path.join(prof, 'DevToolsActivePort'), 'utf8').split('\n')[0]; } catch {} }
const list = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.onopen = r);
let id = 0; const pend = new Map(), errors = [];
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pend.has(m.id)) { pend.get(m.id)(m); pend.delete(m.id); }
  if (m.method === 'Runtime.exceptionThrown') errors.push(m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text); };
const send = (method, params = {}) => new Promise(r => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async expr => { const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true }); if (r.result?.exceptionDetails) throw new Error(expr + ' -> ' + JSON.stringify(r.result.exceptionDetails.exception?.description)); return r.result?.result?.value; };
const shot = async name => { const r = await send('Page.captureScreenshot', { format: 'png' }); fs.writeFileSync(path.join(outdir, name + '.png'), Buffer.from(r.result.data, 'base64')); };
await send('Runtime.enable'); await send('Page.enable');
const checks = {}; const ok = (name, v) => { checks[name] = !!v; };
try {
  await send('Page.navigate', { url: base + '/#office' }); await sleep(2500);
  await ev(`document.querySelector('.office-hit[data-id="boss"]').click()`); await sleep(1800);
  ok('console opens on the Chat view', await ev(`(()=>{const c=document.querySelector('#office-console .oc-chat');return !!c&&!c.hidden;})()`));
  ok('header keeps its own layout (.oc-who is not reused by the chat)', await ev(`document.querySelectorAll('#office-console .oc-chat .oc-who').length===0&&!!document.querySelector('#office-console .oc-head .oc-who')`));
  ok('chat reads as a group chat: 7 rows, helpers batched into one handoff, senders named', await ev(`(()=>{const c=document.querySelector('#office-console .oc-chat'),rows=[...c.querySelectorAll('.oc-row')],who=rows.map(r=>r.querySelector('.oc-from b').textContent);return rows.length===7&&c.querySelectorAll('.oc-hand').length===2&&who.join(',')==='Boss,Boss,Helper 1,Helper 2,Mocha,Bolt,Boss';})()`));
  ok('every row has a painted picture: cast sprite for agents, blob for helpers and the boss', await ev(`(()=>{const rows=[...document.querySelectorAll('#office-console .oc-chat .oc-row')];return rows.every(r=>{const a=r.querySelector('.oc-av');return a&&a.getBoundingClientRect().width>=28&&(a.classList.contains('blob')||a.querySelector('i'));})&&rows[2].querySelector('.oc-av').classList.contains('blob')&&!!rows[4].querySelector('.oc-av i')&&!!rows[5].querySelector('.oc-av i')&&rows[0].querySelector('.oc-av').classList.contains('blob');})()`));
  ok('a helper keeps the colour of its floor blob in both its handoff and its answer', await ev(`(()=>{const c=document.querySelector('#office-console .oc-chat');return c.querySelector('.oc-at').style.getPropertyValue('--agent')===c.querySelectorAll('.oc-row')[2].querySelector('.oc-av').style.getPropertyValue('--agent');})()`));
  ok('typing dots while a helper works', await ev(`(()=>{const t=document.querySelector('#office-console .oc-chat .oc-typing');return !!t&&t.querySelectorAll('i').length===3&&/Reading/.test(t.textContent);})()`));
  ok('a Report is tagged', await ev(`(()=>{const t=document.querySelector('#office-console .oc-chat .oc-tag');return !!t&&t.textContent==='Report'&&t.closest('.oc-row').querySelector('.oc-from b').textContent==='Bolt';})()`));
  ok('a long message clamps, then opens on click', await ev(`(async()=>{const el=[...document.querySelectorAll('#office-console .oc-chat .oc-clamp')].find(x=>x.textContent.startsWith('Tidy the cards')),h=el.getBoundingClientRect().height;el.click();await new Promise(r=>setTimeout(r,50));const open=el.classList.contains('open')&&el.getBoundingClientRect().height>h;el.click();return h<110&&open&&!el.classList.contains('open');})()`));
  ok('the chat stays put when the same turns arrive again', await ev(`(async()=>{const c=document.querySelector('#office-console .oc-chat'),first=c.querySelector('.oc-row');await new Promise(r=>setTimeout(r,3500));return c.querySelector('.oc-row')===first&&c.querySelectorAll('.oc-row').length===7;})()`));
  await ev(`document.querySelector('#office-console .oc-chat').scrollTop=0`); await sleep(200);
  await shot('chat-group');
  // Task board (demo mode: nothing is sent): lanes, flags, Give, Done with Undo, drag, search, filters, add with details.
  const key = async k => { await send('Input.dispatchKeyEvent', { type: 'keyDown', key: k, code: k }); await send('Input.dispatchKeyEvent', { type: 'keyUp', key: k, code: k }); await sleep(150); };
  await send('Page.navigate', { url: base + '/?office-demo&office-n=4#office' }); await sleep(2500);
  await ev(`document.querySelector('.office-hit.wb[data-table="/home/demo/sunrise"]').click()`); await sleep(800);
  const tbAdd = async t => { await ev(`(()=>{const i=document.querySelector('.tb-add input');i.value=${JSON.stringify(t)};document.querySelector('.tb-add').requestSubmit();})()`); await sleep(350); };
  await tbAdd('Decide the launch price (K-07)'); await tbAdd('Draft the waitlist email');
  ok('whiteboard is a task board: three lanes, a Done bar and the team with pictures', await ev(`(()=>{const b=document.querySelector('.tb-board');return !!b&&['todo','agents','done'].every(l=>b.querySelector('.tb-lane[data-lane="'+l+'"]'))&&!!b.querySelector('.tb-hp-bar i')&&!!b.querySelector('.tb-mate .tb-av i');})()`));
  ok('a Decide task is flagged Needs you and its code becomes a chip', await ev(`(()=>{const c=[...document.querySelectorAll('.tb-card')].find(c=>/Decide the launch price/.test(c.textContent));return !!c&&c.classList.contains('is-you')&&c.querySelector('.tb-ref').textContent==='K-07'&&!/K-07/.test(c.querySelector('.tb-title').textContent);})()`));
  const tbId = await ev(`[...document.querySelectorAll('.tb-card[data-lane="todo"]')].find(c=>/Draft the waitlist email/.test(c.textContent)).dataset.id`);
  const lane = () => ev(`document.querySelector('.tb-card[data-id="${tbId}"]').dataset.lane`);
  await ev(`document.querySelector('.tb-card[data-id="${tbId}"] [data-wact="give"]').click()`); await sleep(300);
  ok('Give lists the agents at the table', await ev(`document.querySelectorAll('.tb-give [data-wact="pick"]').length>=2`));
  await ev(`document.querySelector('.tb-give [data-wact="pick"]').click()`); await sleep(500);
  ok('giving moves the card to With an agent, with its picture', await ev(`document.querySelector('.tb-card[data-id="${tbId}"]').dataset.lane==='agents'&&!!document.querySelector('.tb-card[data-id="${tbId}"] .tb-who .tb-av')`));
  await ev(`document.querySelector('.tb-card[data-id="${tbId}"] .tb-tick').click()`); await sleep(700);
  ok('ticking a card moves it to Done and offers Undo', (await lane()) === 'done' && await ev(`!!document.querySelector('.tb-undo')`));
  await ev(`document.querySelector('.tb-undo button').click()`); await sleep(500);
  ok('Undo puts it back', (await lane()) !== 'done' && await ev(`!document.querySelector('.tb-undo')`));
  const drag = (from, to) => ev(`(()=>{const c=document.querySelector('.tb-card[data-id="${tbId}"]'),dt=new DataTransfer();c.dispatchEvent(new DragEvent('dragstart',{bubbles:true,dataTransfer:dt}));const l=document.querySelector(${JSON.stringify(to)});l.dispatchEvent(new DragEvent('dragover',{bubbles:true,cancelable:true,dataTransfer:dt}));l.dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:dt}));c.dispatchEvent(new DragEvent('dragend',{bubbles:true,dataTransfer:dt}));})()`);
  await drag(null, '.tb-lane[data-lane="done"]'); await sleep(700);
  ok('dragging a card onto Done finishes it', (await lane()) === 'done');
  await drag(null, '.tb-lane[data-lane="todo"]'); await sleep(500);
  ok('dragging it back to To do reopens it', (await lane()) !== 'done');
  await ev(`document.body.focus()`); await send('Input.dispatchKeyEvent', { type: 'keyDown', key: '/', text: '/' }); await send('Input.dispatchKeyEvent', { type: 'keyUp', key: '/' }); await sleep(200);
  ok('/ jumps to the task search', await ev(`document.activeElement.matches('.tb-search input')`));
  await send('Input.insertText', { text: 'launch price' }); await sleep(250);
  ok('search narrows the cards in place', await ev(`(()=>{const v=[...document.querySelectorAll('.tb-card')].filter(c=>!c.hidden);return v.length===1&&/launch price/.test(v[0].textContent);})()`));
  await key('Escape');
  ok('Escape clears the search before it closes the board', await ev(`!document.querySelector('#office-wbzoom').hidden&&document.querySelector('.tb-search input').value===''`));
  await ev(`document.querySelector('[data-wact="filter"][data-filter="you"]').click()`); await sleep(200);
  ok('Needs you shows only what waits on you', await ev(`(()=>{const v=[...document.querySelectorAll('.tb-card')].filter(c=>!c.hidden);return v.length>0&&v.every(c=>c.classList.contains('is-you'));})()`));
  await ev(`document.querySelector('[data-wact="filter"][data-filter="all"]').click()`);
  await ev(`(()=>{document.querySelector('.tb-add input').value='Record the demo';document.querySelector('[data-wact="details"]').click();})()`); await sleep(200);
  await ev(`(()=>{document.querySelector('.tb-add textarea').value='Two takes, one with sound';document.querySelector('.tb-add').requestSubmit();})()`); await sleep(500);
  ok('add with details keeps the title and saves the notes', await ev(`[...document.querySelectorAll('.tb-card')].some(c=>/Record the demo/.test(c.textContent)&&/Two takes/.test(c.textContent))`));
  await ev(`document.querySelector('.tb-view [data-view="list"]').click()`); await sleep(300);
  ok('list view shows the same cards as a list', await ev(`!!document.querySelector('.tb-list .tb-card')&&!document.querySelector('.tb-lanes')`)); await shot('task-board-list');
  await ev(`document.querySelector('.tb-view [data-view="board"]').click()`); await sleep(300); await shot('task-board');
  ok('the task board has no horizontal overflow', await ev(`document.documentElement.scrollWidth<=innerWidth+1`));
  await key('Escape'); await sleep(400);
  ok('no script errors', errors.length === 0);
} catch (e) { checks['ran to the end: ' + e.message] = false; }
const bad = Object.entries(checks).filter(([, v]) => !v);
for (const [k, v] of Object.entries(checks)) console.log((v ? 'ok   ' : 'FAIL ') + k);
if (errors.length) console.log('errors:', errors);
chrome.kill(); server.close(); await sleep(500); try { fs.rmSync(prof, { recursive: true, force: true }); } catch {}
process.exit(bad.length ? 1 : 0);
