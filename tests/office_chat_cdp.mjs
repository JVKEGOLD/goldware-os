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
  ok('no script errors', errors.length === 0);
} catch (e) { checks['ran to the end: ' + e.message] = false; }
const bad = Object.entries(checks).filter(([, v]) => !v);
for (const [k, v] of Object.entries(checks)) console.log((v ? 'ok   ' : 'FAIL ') + k);
if (errors.length) console.log('errors:', errors);
chrome.kill(); server.close(); await sleep(500); try { fs.rmSync(prof, { recursive: true, force: true }); } catch {}
process.exit(bad.length ? 1 : 0);
