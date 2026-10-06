// Pure-function checks for the Office page: it pulls single functions out of dashboard/office.js and runs
// them in a sandbox, so no browser and no server are involved.  node tests/office_ui.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const office = fs.readFileSync(path.join(root, 'dashboard', 'office.js'), 'utf8');
const sandbox = {}; vm.createContext(sandbox);
function load(name) {
  const start = office.indexOf('  function ' + name + '(');
  assert.notEqual(start, -1, name + ' is present');
  const end = office.indexOf('\n  }', start);
  assert.notEqual(end, -1, name + ' ends');
  vm.runInContext(office.slice(start, end + 4), sandbox);
  return sandbox[name];
}

// Task board cards: codes come out of the title, a "Source:" line moves out of the note, flags and lanes.
{
  vm.runInContext(office.match(/  const TB_CODE = [^\n]+/)[0].replace('const ', 'var '), sandbox);
  const taskBits = load('taskBits'), taskFlags = load('taskFlags'), taskLane = load('taskLane'), taskMatches = load('taskMatches');
  let b = taskBits({ title: 'brief counsel on Terms (P-08, K-05)', notes: 'Launch blocker. Source: docs/tasks.md' });
  assert.equal(JSON.stringify([b.title, b.refs, b.note, b.source]), JSON.stringify(['Brief counsel on Terms', ['P-08', 'K-05'], 'Launch blocker.', 'docs/tasks.md']), 'Codes and source come out: ' + JSON.stringify(b));
  b = taskBits({ title: 'P-10/P-11 finish billing config' });
  assert.equal(JSON.stringify([b.title, b.refs]), JSON.stringify(['Finish billing config', ['P-10', 'P-11']]), 'Leading codes come out');
  assert.equal(taskBits({ title: 'Store: App listing (P-04-06)' }, ['Store']).title, 'App listing', 'A prefix that repeats the board drops, a three-part code too');
  assert.equal(taskBits({ title: 'Fix the (beta) form' }).title, 'Fix the (beta) form', 'Brackets that are not codes stay');
  assert.equal(taskFlags({ title: 'Decide the price' }).you, true, 'Decide waits on you');
  assert.equal(taskFlags({ title: 'Ship it', notes: 'Needs you to approve first' }).you, true, 'Notes saying it needs you flag it');
  assert.equal(taskFlags({ title: 'Ship it', notes: 'Only you can do this' }).you, true, 'Only you flags it');
  assert.equal(taskFlags({ title: 'Brief counsel', notes: 'Launch blocker: paid stays off' }).blocker, true, 'A launch blocker is flagged');
  assert.equal(taskFlags({ title: 'Watch the ticket' }).waiting, true, 'Watch waits on others');
  assert.equal(taskFlags({ title: 'Write the page' }).you, false, 'An ordinary task is not flagged');
  assert.equal(JSON.stringify([taskLane({ status: 'todo' }), taskLane({ status: 'assigned' }), taskLane({ status: 'done' })]), JSON.stringify(['todo', 'agents', 'done']), 'Lanes follow status');
  const t = { title: 'Record the demo', notes: 'two takes', status: 'assigned', agent_title: 'Bolt' };
  assert.equal(taskMatches(t, 'demo takes', 'all'), true, 'Search matches title and notes words');
  assert.equal(taskMatches(t, 'demo', 'free'), false, 'Not given out hides a task with an agent');
  assert.equal(taskMatches(t, 'bolt', 'agents'), true, 'Search finds who has it');
  assert.equal(taskMatches({ title: 'x' }, '', 'you'), false, 'Needs you hides other tasks');
  console.log('Office task board cards: 15 checks passed');
}
