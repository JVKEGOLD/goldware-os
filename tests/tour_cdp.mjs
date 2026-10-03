// Headless Chrome pass over the first-run tour, against a dry-run server (no Node needed by make test).
//   GOLDWARE_ROOT=<scratch copy> GOLDWARE_DATA_ROOT=<scratch>/data GOLDWARE_DATA=<scratch>/app \
//   GOLDWARE_OFFICE_DRY_RUN=1 GOLDWARE_OFFICE_EMPTY=1 python3 server/goldware_server.py --port 4291 &
//   node tests/tour_cdp.mjs http://127.0.0.1:4291 <screenshot dir> [width height]
// Start with no data/onboarding.json so the first-run checks see a new install. Exits 1 on any failure.
import { spawn } from 'node:child_process'; import fs from 'node:fs'; import path from 'node:path';
const base = process.argv[2] || 'http://127.0.0.1:4291', outdir = process.argv[3] || '.';
const W = +(process.argv[4] || 1440), H = +(process.argv[5] || 900);
fs.mkdirSync(outdir, { recursive: true });
const prof = fs.mkdtempSync(path.join(outdir, 'cdp-'));
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', ['--headless=new', `--user-data-dir=${prof}`, '--remote-debugging-port=0', `--window-size=${W},${H}`, 'about:blank'], { stdio: 'ignore' });
const sleep = ms => new Promise(r => setTimeout(r, ms));
let port; for (let i = 0; i < 60 && !port; i++) { await sleep(200); try { port = fs.readFileSync(path.join(prof, 'DevToolsActivePort'), 'utf8').split('\n')[0]; } catch {} }
const list = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.onopen = r);
let id = 0; const pend = new Map(), errors = [];
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pend.has(m.id)) { pend.get(m.id)(m); pend.delete(m.id); }
  if (m.method === 'Runtime.exceptionThrown') errors.push(m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text);
  if (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'error') errors.push('console: ' + m.params.args.map(a => a.value || a.description).join(' ')); };
const send = (method, params = {}) => new Promise(r => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async expr => { const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true }); if (r.result?.exceptionDetails) throw new Error(expr + ' -> ' + JSON.stringify(r.result.exceptionDetails.exception?.description)); return r.result?.result?.value; };
const shot = async name => { const r = await send('Page.captureScreenshot', { format: 'png' }); fs.writeFileSync(path.join(outdir, name + '.png'), Buffer.from(r.result.data, 'base64')); };
const key = async (k, code, vk) => { for (const type of ['keyDown', 'keyUp']) await send('Input.dispatchKeyEvent', { type, key: k, code, windowsVirtualKeyCode: vk }); };
await send('Runtime.enable'); await send('Page.enable');
const out = { checks: {} };
const ok = (name, v) => { out.checks[name] = !!v; };

// 1. A brand new install: the tour opens by itself, once.
await send('Page.navigate', { url: base + '/#dashboard' }); await sleep(2500);
ok('opens by itself on a new install', await ev(`!document.getElementById('tour').hidden`));
ok('is a modal dialog with a label', await ev(`(d=>d.getAttribute('role')==='dialog'&&d.getAttribute('aria-modal')==='true'&&!!document.getElementById(d.getAttribute('aria-labelledby')))(document.querySelector('.tour'))`));
ok('focus starts on the chapter title', await ev(`document.activeElement.id==='tour-title'`));
const chapters = await ev(`GoldWareTour.chapters().map(c=>c.id)`);
out.chapters = chapters;
// keyboard: right arrow moves on, left back
await key('ArrowRight', 'ArrowRight', 39); await sleep(200);
ok('right arrow goes to the next chapter', await ev(`document.querySelector('.tour-main').dataset.chapter==='permissions'`));
await key('ArrowLeft', 'ArrowLeft', 37); await sleep(200);
ok('left arrow goes back', await ev(`document.querySelector('.tour-main').dataset.chapter==='welcome'`));
// Esc closes and saves "open"
await key('Escape', 'Escape', 27); await sleep(400);
ok('Esc closes it', await ev(`document.getElementById('tour').hidden`));
const st1 = await ev(`fetch('/api/onboarding').then(r=>r.json())`);
ok('closing saves the tour as open (resumable)', st1.state.status === 'open');
ok('Tour button reads Resume', await ev(`document.getElementById('tour-btn').textContent==='Tour'`) && await ev(`document.querySelector('.tour-entry button').textContent==='Resume the tour'`));
// reload: does not reopen by itself
await send('Page.navigate', { url: base + '/#dashboard' }); await sleep(2000);
ok('does not reopen by itself after that', await ev(`document.getElementById('tour').hidden`));
// skip
await ev(`document.getElementById('tour-btn').click()`); await sleep(300);
ok('Tour button reopens it', await ev(`!document.getElementById('tour').hidden`));
await ev(`document.querySelector('.tour-skip').click()`); await sleep(400);
const st2 = await ev(`fetch('/api/onboarding').then(r=>r.json())`);
ok('Skip saves skipped', st2.state.status === 'skipped');
ok('Welcome card offers Replay', await ev(`document.querySelector('.tour-entry button').textContent==='Replay the tour'`));
// Replay from the Welcome card, walk every chapter with Next, Finish
await ev(`document.querySelector('.tour-entry button').click()`); await sleep(300);
ok('Replay starts at chapter 1', await ev(`document.querySelector('.tour-main').dataset.chapter==='welcome'`));
for (let i = 0; i < chapters.length - 1; i++) { await ev(`document.querySelector('.tour-next').click()`); await sleep(150); }
ok('Next walks to the last chapter', await ev(`document.querySelector('.tour-main').dataset.chapter==='help' && document.querySelector('.tour-next').textContent==='Finish'`));
await ev(`document.querySelector('.tour-next').click()`); await sleep(400);
const st3 = await ev(`fetch('/api/onboarding').then(r=>r.json())`);
ok('Finish saves done with every chapter seen', st3.state.status === 'done' && chapters.every(c => st3.state.seen.includes(c)));

// 2. Content rules on every chapter (demo mode: nothing saved)
await send('Page.navigate', { url: base + '/?tour-demo#dashboard' }); await sleep(2200);
const texts = {};
for (const c of chapters) {
  await ev(`GoldWareTour.open(${JSON.stringify(c)})`); await sleep(250);
  texts[c] = await ev(`document.querySelector('.tour').innerText`);
}
const all = Object.values(texts).join('\n');
ok('no em dashes in tour text', !/\u2014/.test(all));
ok('unlock gesture never described (no diamond, prayer-spread, steps)', !/diamond|index tips stay|palms spread|palms flat|tips let go|let go of the tips/i.test(all));
ok('unlock placeholder is shown', /Set or use your unlock gesture/.test(texts.vision));
ok('vision embeds gestures through GoldWareGestures.render', await ev(`GoldWareTour.open('vision'), document.querySelectorAll('.tour-g[data-gesture]:not(.tour-unlock) > figure').length`) > 5);
ok('every listed gesture appears exactly once', await ev(`(()=>{const ids=GoldWareGestures.list().filter(g=>!/unlock/i.test(g.id+g.name)).map(g=>g.id);const shown=[...document.querySelectorAll('.tour-g[data-gesture]')].map(f=>f.dataset.gesture).filter(x=>x!=='unlock-placeholder');return ids.length===shown.length&&ids.every(i=>shown.filter(s=>s===i).length===1)})()`));
ok('no unlock gesture is ever rendered', await ev(`![...document.querySelectorAll('.tour-g[data-gesture]')].some(f=>/unlock/.test(f.dataset.gesture)&&f.dataset.gesture!=='unlock-placeholder')`));
ok('permissions list covers mic, accessibility, speech, camera, automation, calendar', await ev(`GoldWareTour.open('permissions'), ['microphone','accessibility','speech','camera','automation','calendar'].every(k=>document.querySelector('[data-perm='+k+']'))`));
await ev(`GoldWareTour._setPerms({microphone:'granted',accessibility:'not granted',camera:'not asked yet',speech:'granted',calendar:'denied',automation:'granted',milestones:['dictated','lets-work'],updated:new Date().toISOString()})`); await sleep(100);
ok('permission states render from the app report', await ev(`document.querySelector('[data-perm=microphone]').classList.contains('ok') && document.querySelector('[data-perm=accessibility]').classList.contains('off') && document.querySelector('[data-perm=camera]').classList.contains('wait')`));
await ev(`GoldWareTour.open('voice')`); await sleep(150);
ok('app milestones tick checks (dictated)', await ev(`document.querySelector('[data-check=dictated]').classList.contains('ok') && !document.querySelector('[data-check=assistant]').classList.contains('ok')`));
// type into the practice box with real keys
await ev(`document.querySelector('.tour-dictate').focus()`);
for (const ch of 'hello there') await send('Input.dispatchKeyEvent', { type: 'char', text: ch });
await sleep(150);
ok('typing in the practice box does not move chapters', await ev(`document.querySelector('.tour-main').dataset.chapter==='voice'`));
// focus trap
await ev(`GoldWareTour.open('help')`); await sleep(150);
for (let i = 0; i < 25; i++) await key('Tab', 'Tab', 9);
ok('Tab stays inside the dialog', await ev(`document.querySelector('.tour').contains(document.activeElement)`));

// 3. Screenshots of each chapter (fresh demo page, mocked permissions so the list is filled in)
await send('Page.navigate', { url: base + '/?tour-demo#dashboard' }); await sleep(2200);
await ev(`GoldWareTour._setPerms({microphone:'granted',accessibility:'granted',camera:'not asked yet',speech:'not asked yet',calendar:'not asked yet',automation:'iterm closed',milestones:['dictated','vision-on'],updated:new Date().toISOString()})`);
for (const [i, c] of chapters.entries()) { await ev(`GoldWareTour.open(${JSON.stringify(c)})`); await sleep(500); await shot(`${String(i + 1).padStart(2, '0')}-${c}`); }
// Vision chapter scrolled, to show the lower half
await ev(`GoldWareTour.open('vision')`); await sleep(300);
{ const hgt = await ev(`document.querySelector('.tour-body').scrollHeight`); const vh = await ev(`document.querySelector('.tour-body').clientHeight`);
  let n = 0; for (let y = vh - 40; y < hgt - vh; y += vh - 40) { await ev(`document.querySelector('.tour-body').scrollTop = ${y}`); await sleep(500); await shot('04' + 'abcdefghij'[n++] + '-vision-scroll'); }
  await ev(`document.querySelector('.tour-body').scrollTop = 1e6`); await sleep(400); await shot('04z-vision-end'); }
await ev(`GoldWareTour.close('open')`); await sleep(400); await shot('09-dashboard-welcome-card');

// 4. Reduced motion
await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'reduce' }] });
await send('Page.navigate', { url: base + '/?tour-demo#dashboard' }); await sleep(2000);
ok('reduced motion: no tour animation', await ev(`getComputedStyle(document.querySelector('.tour')).animationName==='none'`));
out.errors = errors;
out.pass = Object.values(out.checks).every(Boolean) && !errors.length;
console.log(JSON.stringify(out, null, 1));
ws.close(); chrome.kill(); await sleep(800); fs.rmSync(prof, { recursive: true, force: true });
process.exit(out.pass ? 0 : 1);
