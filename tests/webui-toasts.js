// tests/webui-toasts.js - the toasts webroot/index.html shows for the answers of service.sh.
//   node tests/webui-toasts.js      (tests/run.sh calls it when node is there; prints ok/FAIL lines)
// The page script runs in a vm context with a stub DOM; svc(), refreshStatus() and the log and
// backup loaders are replaced, so no root bridge or shell is involved.
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const html = fs.readFileSync(path.join(__dirname, '..', 'webroot', 'index.html'), 'utf8');
const m = /<script>([\s\S]*?)<\/script>/.exec(html);
if (!m) { console.log('FAIL index.html has no inline script'); process.exit(1); }

function element() {
  return {
    classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
    style: {}, dataset: {}, value: '', disabled: false, textContent: '', innerHTML: '',
    addEventListener() {}, focus() {}, querySelector() { return null; }, querySelectorAll() { return []; },
    getBoundingClientRect() { return { top: 0, height: 0 }; }
  };
}
const els = {};
const document = {
  hidden: false, body: element(), activeElement: null,
  getElementById(id) { return els[id] || (els[id] = element()); },
  addEventListener() {}, querySelector() { return null; }, querySelectorAll() { return []; }
};
const ctx = {
  document, console, Promise, TextDecoder, Uint8Array, Set, Math, Date, JSON, String, Error,
  parseInt, parseFloat, atob: (s) => Buffer.from(s, 'base64').toString('binary'),
  setTimeout: () => 0, clearTimeout() {}, setInterval: () => 0, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  confirm: () => true, addEventListener() {}, innerHeight: 800, scrollY: 0
};
ctx.window = ctx;
vm.createContext(ctx);
vm.runInContext(m[1], ctx);

let toasts = [];
let answers = {};
ctx.showToast = (msg, type) => { toasts.push([msg, type || '']); };
ctx.svc = async (args) => {
  for (const k of Object.keys(answers)) if (args.indexOf(k) === 0) return answers[k];
  throw new Error('no canned answer for ' + args);
};
for (const f of ['refreshStatus', 'loadLogs', 'loadBackups', 'loadMockApps']) ctx[f] = async () => {};

let failed = 0;
async function expectToast(name, canned, run, msg, type) {
  toasts = [];
  answers = canned;
  try { await run(); } catch (e) { toasts.push(['threw: ' + e.message, '']); }
  const last = toasts[toasts.length - 1] || ['(no toast)', ''];
  if (last[0] === msg && last[1] === type) {
    console.log('ok   ' + name);
  } else {
    failed++;
    console.log('FAIL ' + name);
    console.log('     got "' + last[0] + '" (' + last[1] + '), want "' + msg + '" (' + type + ')');
  }
}

function customForm(kind, target, value) {
  ctx.document.getElementById('cKind').value = kind;
  ctx.document.getElementById('cTarget').value = target;
  ctx.document.getElementById('cValue').value = value;
  ctx.document.getElementById('cUnit').style.display = 'none';
}

(async () => {
  const apply = () => ctx.doAction('apply');
  await expectToast('Apply Now: corrections counted', { '--apply': 'applied=2\ndaemon=running\nrc=0\n' },
    apply, 'Applied · 2 correction(s)', 'ok');
  await expectToast('Apply Now: daemon restarted', { '--apply': 'applied=0\ndaemon=restarted\nrc=0\n' },
    apply, 'Applied · daemon restarted', 'ok');
  await expectToast('Apply Now: apply lock busy is not a success', { '--apply': 'applied=0\nerror=busy\nrc=1\n' },
    apply, 'Apply busy, try again', 'err');
  await expectToast('Apply Now: a daemon that did not start is not a success', { '--apply': 'applied=1\ndaemon=failed\nrc=0\n' },
    apply, 'Applied · daemon failed to start', 'err');

  const snap = () => ctx.doAction('snapshot');
  await expectToast('New Snapshot: busy', { '--snapshot': 'error=busy\nrc=1\n' }, snap, 'Snapshot failed (busy, try again)', 'err');
  await expectToast('New Snapshot: not saved', { '--snapshot': 'snapped=0\nunreadable=0\nfailed=1\nrc=1\n' },
    snap, 'Snapshot failed (could not save)', 'err');
  await expectToast('Restore Original: busy', { '--restore': 'error=busy\nrc=1\n' }, () => ctx.doAction('restore'),
    'Restore busy, try again', 'err');

  customForm('system', 'example_mode', '5');
  await expectToast('Custom add: busy', { '--custom-add': 'error=busy\nrc=1\n' }, () => ctx.addCustom(), 'Busy, try again', 'err');
  customForm('system', 'example_mode', '5');
  await expectToast('Custom add: refused value', { '--custom-add': 'error=bad-value\nrc=1\n' }, () => ctx.addCustom(),
    'Value: letters, digits and . _ , : + - only', 'err');
  ctx.STATUS = { TARGET_c1: 'example_mode' };
  await expectToast('Custom remove: busy', { '--custom-del': 'error=busy\nrc=1\n' }, () => ctx.delCustom('c1'),
    'Busy, try again', 'err');
  await expectToast('Custom remove: done', { '--custom-del': 'rc=0\n' }, () => ctx.delCustom('c1'), 'Removed example_mode', 'ok');

  process.exit(failed ? 1 : 0);
})();
