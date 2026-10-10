'use strict';
// Tests the logic of .devcontainer/autosave-notify/extension.js with a fake `vscode` module.
// It does NOT start VS Code, so it cannot prove that the pop-ups really appear.
// Run: node test/notify-extension.test.js

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const Module = require('module');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'notify-test-'));
const statusFile = path.join(tmp, 'status.json');

const shown = [];
const settings = { statusFile, showSuccess: true, showPending: true, showFailure: true };
const fakeVscode = {
  env: { language: 'ja' },
  window: {
    showInformationMessage: (m) => shown.push(['info', m]),
    showWarningMessage: (m) => shown.push(['warning', m]),
    showErrorMessage: (m) => shown.push(['error', m]),
  },
  workspace: {
    getConfiguration: () => ({ get: (k) => settings[k] }),
    onDidChangeConfiguration: () => ({ dispose() {} }),
  },
};

const originalLoad = Module._load;
Module._load = function (request, ...rest) {
  return request === 'vscode' ? fakeVscode : originalLoad.call(this, request, ...rest);
};

const ext = require('../extension/extension.js');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let seq = 0;
const write = (event, extra = {}) =>
  fs.writeFileSync(
    statusFile,
    JSON.stringify({ id: String(++seq), event, time: 'now', branch: 'feature/x', changes: 12,
                     unsaved_seconds: 130, detail: '', ...extra }) + '\n'
  );

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

async function withExtension(fn) {
  shown.length = 0;
  const context = { subscriptions: [] };
  ext.activate(context);
  try { await fn(); } finally { context.subscriptions.forEach((s) => s.dispose()); }
}

test('success is shown as an information message', () => withExtension(async () => {
  write('success');
  await sleep(1200);
  assert.strictEqual(shown.length, 1);
  assert.strictEqual(shown[0][0], 'info');
  assert.match(shown[0][1], /wip\/feature\/x/);
  assert.match(shown[0][1], /12/);
}));

test('pending is shown as a warning with minutes', () => withExtension(async () => {
  write('pending');
  await sleep(1200);
  assert.deepStrictEqual(shown.map((s) => s[0]), ['warning']);
  assert.match(shown[0][1], /2分間/);
}));

test('failure is shown as an error with its detail', () => withExtension(async () => {
  write('failure', { detail: 'fatal: Authentication failed' });
  await sleep(1200);
  assert.deepStrictEqual(shown.map((s) => s[0]), ['error']);
  assert.match(shown[0][1], /Authentication failed/);
}));

test('the same event is not shown twice, a new id is', () => withExtension(async () => {
  write('success');
  await sleep(1200);
  fs.utimesSync(statusFile, new Date(), new Date(Date.now() + 5000)); // touch only
  await sleep(1200);
  assert.strictEqual(shown.length, 1);
  write('success');
  await sleep(1200);
  assert.strictEqual(shown.length, 2);
}));

test('an event that existed before activation is not replayed', async () => {
  write('failure');
  await withExtension(async () => {
    await sleep(1200);
    assert.strictEqual(shown.length, 0);
  });
});

test('a file created after activation is noticed', async () => {
  fs.rmSync(statusFile, { force: true });
  await withExtension(async () => {
    await sleep(700);
    write('success');
    await sleep(1200);
    assert.strictEqual(shown.length, 1);
  });
});

test('an invalid or half-written file is ignored', () => withExtension(async () => {
  fs.writeFileSync(statusFile, '{"id":"x","ev');
  await sleep(1200);
  assert.strictEqual(shown.length, 0);
}));

test('each kind can be switched off', async () => {
  settings.showSuccess = settings.showPending = settings.showFailure = false;
  try {
    await withExtension(async () => {
      write('success'); await sleep(1100);
      write('pending'); await sleep(1100);
      write('failure'); await sleep(1100);
      assert.strictEqual(shown.length, 0);
    });
  } finally {
    settings.showSuccess = settings.showPending = settings.showFailure = true;
  }
});

test('English is used when the UI language is not Japanese', async () => {
  fakeVscode.env.language = 'en';
  try {
    await withExtension(async () => {
      write('success');
      await sleep(1200);
      assert.match(shown[0][1], /Backed up to wip\/feature\/x/);
    });
  } finally {
    fakeVscode.env.language = 'ja';
  }
});

(async () => {
  let failed = 0;
  for (const [name, fn] of tests) {
    try {
      await fn();
      console.log(`ok   - ${name}`);
    } catch (e) {
      failed++;
      console.log(`FAIL - ${name}\n         ${String(e.message).split('\n').join('\n         ')}`);
    }
  }
  fs.rmSync(tmp, { recursive: true, force: true });
  console.log(`\npassed: ${tests.length - failed} / failed: ${failed}`);
  process.exit(failed ? 1 : 0);
})();
