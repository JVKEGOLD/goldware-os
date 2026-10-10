// Headless Chrome pass over the Office phone (dashboard/office-phone.js) inside the real dashboard. It serves the
// repo's dashboard files plus a fixture for the Office endpoints on its own free port, so it never touches the
// real server, the agents on this Mac, or any data folder. Every POST is recorded, none is acted on.
//   node tests/office_phone_cdp.mjs <screenshot dir>
// Set CHROME to use another browser binary. Exits 1 on any failure.
import { spawn } from 'node:child_process'; import fs from 'node:fs'; import path from 'node:path'; import http from 'node:http'; import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outdir = path.resolve(process.argv[2] || '.');
fs.mkdirSync(outdir, { recursive: true });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const now = Date.now() / 1000;
const mk = (id, name, extra = {}) => ({ id, tty: 'ttys0' + id.length, kind: 'hermes', title: 'Tidy the layout', name, closing: null, todos: [], ask: 'Tidy the layout', cwd: '/home/a/site',
  model: 'Opus 5.5', provider: 'anthropic', activity: 'idle', working: false, started_at: now - 600, last_at: now - 30, messages: 4, helpers: [], ...extra });
const agents = [mk('boss-1', 'Boss', { boss: true }), mk('fx-2', 'Bolt'), mk('fx-3', 'Pip')];
const turns = [{ kind: 'you', text: 'Tidy the layout' }, { kind: 'said', text: 'Done. The **layout** is tidy.' }];
const posts = [];
const board = { tasks: [], ideas: [], suggestions: [], project: {}, runs: {}, groupings: {}, progress: { done: 0, total: 0 } };
const json = (res, o) => { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(o)); };
const types = { '.js': 'application/javascript', '.css': 'text/css', '.html': 'text/html' };
const server = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (req.method === 'POST') { let b = ''; req.on('data', c => b += c); req.on('end', () => { posts.push({ url: u.pathname, body: JSON.parse(b || '{}') }); json(res, { ok: true, sent: true, queued: false }); }); return; }
  if (u.pathname === '/api/office/agents') return json(res, { agents, home: '/home/a', rack: { ollama: false, units: [] }, topics: [] });
  if (u.pathname === '/api/office/chat') return json(res, { id: u.searchParams.get('id'), turns });
  if (u.pathname === '/api/office/screen') return json(res, { id: u.searchParams.get('id'), activity: 'idle', screen: 'fixture screen' });
  if (u.pathname === '/api/office/board') return json(res, board);
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
const chrome = spawn(process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', ['--headless=new', `--user-data-dir=${prof}`, '--remote-debugging-port=0', '--window-size=1440,900', 'about:blank'], { stdio: 'ignore' });
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
const VK = { Enter: 13, Escape: 27, p: 80 };
const key = async k => { const text = k === 'Enter' ? '\r' : k.length === 1 ? k : undefined;
  await send('Input.dispatchKeyEvent', { type: 'keyDown', key: k, code: k.length === 1 ? 'Key' + k.toUpperCase() : k, windowsVirtualKeyCode: VK[k] || 0, text });
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key: k, code: k.length === 1 ? 'Key' + k.toUpperCase() : k, windowsVirtualKeyCode: VK[k] || 0 }); await sleep(150); };
const press = async (x, y) => { for (const type of ['mousePressed', 'mouseReleased']) await send('Input.dispatchMouseEvent', { type, x, y, button: 'left', clickCount: 1 }); await sleep(300); };
const iconAt = `(()=>{const b=document.querySelector('.op-icon');if(!b)return null;const r=b.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2,w:r.width,top:b.contains(document.elementFromPoint(r.x+r.width/2,r.y+r.height/2))};})()`;
const checks = {}; const ok = (name, v) => { checks[name] = !!v; };
try {
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
  await send('Page.navigate', { url: base + '/#office' }); await sleep(2500);
  const st = await ev(`(()=>{const r=document.getElementById('office-stage').getBoundingClientRect();return {x:r.x,bottom:r.bottom};})()`);
  let ic = await ev(iconAt);
  ok('the phone icon sits in the room\'s bottom-left corner, on the page (not inside the room), and takes the tap', ic && ic.top && ic.w >= 44 && ic.x - st.x < 60 && st.bottom - ic.y < 70 && await ev(`document.querySelector('.op-root').parentElement===document.body`));
  ok('it does not cover the record player', await ev(`(()=>{const a=document.querySelector('.op-icon').getBoundingClientRect(),r=document.querySelector('.rp-root');if(!r)return true;const b=r.getBoundingClientRect();return a.right<=b.left||b.right<=a.left||a.bottom<=b.top||b.bottom<=a.top;})()`));
  await shot('phone-closed');
  await press(ic.x, ic.y);
  ok('a tap opens the phone with the boss\'s chat', await ev(`!document.querySelector('.op-panel').hidden`) && /layout/.test(await ev(`document.querySelector('.op-thread').textContent`)));
  ok('the contacts strip lists the boss and every agent', await ev(`[...document.querySelectorAll('.op-contact')].map(b=>b.dataset.name).join(',')`) === 'Boss,Bolt,Pip');
  await shot('phone-open');
  await send('Input.insertText', { text: 'Check the build' }); await key('Enter'); await sleep(500);
  ok('a plain line goes to the boss', posts.some(p => p.url === '/api/office/send' && p.body.id === 'boss-1' && p.body.text === 'Check the build'));
  await sleep(2200);
  await send('Input.insertText', { text: 'Bolt, run the tests' }); await key('Enter'); await sleep(500);
  ok('a line that starts with an agent\'s name goes to that agent, name stripped', posts.some(p => p.url === '/api/office/send' && p.body.id === 'fx-2' && p.body.text === 'run the tests'));
  ok('the routed line is tagged in the thread', await ev(`!!document.querySelector('.op-msg.routed')`)); await shot('phone-routed');
  await key('Escape'); await sleep(300);
  ok('Esc closes it', await ev(`document.querySelector('.op-panel').hidden`));
  await ev(`document.activeElement&&document.activeElement.blur()`); await key('p'); await sleep(300);
  ok('P opens it from the room', await ev(`!document.querySelector('.op-panel').hidden`));
  await ev(`document.querySelector('.op-input').blur()`); await key('Escape'); await sleep(300);
  ok('Esc closes it first even when focus is elsewhere', await ev(`document.querySelector('.op-panel').hidden`));
  // Reachable over everything the room stacks on top: a zoomed whiteboard.
  await ev(`(()=>{const b=document.querySelector('.office-hit.wb');if(b)b.click();})()`); await sleep(700);
  ic = await ev(iconAt);
  ok('over a zoomed whiteboard the icon still shows and takes the tap', ic && ic.top);
  await key('Escape'); await sleep(400);
  // Phone width.
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 2, mobile: true });
  await send('Page.navigate', { url: base + '/#office' }); await sleep(2500);
  ic = await ev(iconAt);
  ok('iPhone: the icon is a 44 px target that takes the tap', ic && ic.top && ic.w >= 44); await shot('phone-iphone');
  ok('iPhone: it does not cover the record player', await ev(`(()=>{const a=document.querySelector('.op-icon').getBoundingClientRect(),r=document.querySelector('.rp-root');if(!r)return true;const b=r.getBoundingClientRect();return a.right<=b.left||b.right<=a.left||a.bottom<=b.top||b.bottom<=a.top;})()`));
  ok('no script errors', errors.length === 0);
} catch (e) { checks['ran to the end: ' + e.message] = false; }
const bad = Object.entries(checks).filter(([, v]) => !v);
for (const [k, v] of Object.entries(checks)) console.log((v ? 'ok   ' : 'FAIL ') + k);
if (errors.length) console.log('errors:', errors);
chrome.kill(); server.close(); await sleep(500); try { fs.rmSync(prof, { recursive: true, force: true }); } catch {}
process.exit(bad.length ? 1 : 0);
