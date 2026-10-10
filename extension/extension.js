'use strict';
// Shows pop-ups for the events that .devcontainer/autosave.sh writes to a status file.
// The file holds the latest event as one JSON object:
//   {"id","event":"success|pending|failure","time","branch","changes","unsaved_seconds","detail"}
// Each event has a new "id"; a pop-up is shown whenever the id changes.

const vscode = require('vscode');
const fs = require('fs');

const POLL_MS = 500;
const DEFAULT_STATUS_FILE = '/tmp/autosave.status';

const TEXT = {
  ja: {
    success: (e) => `wip/${e.branch} にバックアップしました(変更 ${e.changes} 行)`,
    pending: (e) => `${minutes(e)}分間、${e.changes} 行の変更がバックアップされていません(${e.branch})`,
    failure: (e) =>
      `バックアップのpushに失敗しました。${e.changes} 行の変更が保護されていません(${minutes(e)}分経過)` +
      (e.detail ? `: ${e.detail}` : ''),
  },
  en: {
    success: (e) => `Backed up to wip/${e.branch} (${e.changes} changed lines)`,
    pending: (e) => `${e.changes} changed lines have not been backed up for ${minutes(e)} min (${e.branch})`,
    failure: (e) =>
      `Backup push failed. ${e.changes} changed lines are not protected (${minutes(e)} min)` +
      (e.detail ? `: ${e.detail}` : ''),
  },
};

function minutes(e) {
  return Math.max(1, Math.round((Number(e.unsaved_seconds) || 0) / 60));
}

function readStatus(file) {
  try {
    const event = JSON.parse(fs.readFileSync(file, 'utf8'));
    return event && typeof event === 'object' && event.id ? event : null;
  } catch {
    return null; // missing, half-written or invalid: ignore
  }
}

function activate(context) {
  let file = null;
  let lastId = null;

  const config = () => vscode.workspace.getConfiguration('autosaveNotify');

  function show(event) {
    const lang = String(vscode.env.language || 'en').startsWith('ja') ? 'ja' : 'en';
    const cfg = config();
    if (event.event === 'success' && cfg.get('showSuccess') !== false) {
      vscode.window.showInformationMessage(TEXT[lang].success(event));
    } else if (event.event === 'pending' && cfg.get('showPending') !== false) {
      vscode.window.showWarningMessage(TEXT[lang].pending(event));
    } else if (event.event === 'failure' && cfg.get('showFailure') !== false) {
      vscode.window.showErrorMessage(TEXT[lang].failure(event));
    }
  }

  function onChange() {
    const event = readStatus(file);
    if (!event || event.id === lastId) return;
    lastId = event.id;
    show(event);
  }

  function watch() {
    if (file) fs.unwatchFile(file, onChange);
    file = config().get('statusFile') || DEFAULT_STATUS_FILE;
    // Do not replay an event that already existed before the extension started.
    const current = readStatus(file);
    lastId = current ? current.id : null;
    // watchFile polls, so it also notices a file that is created later.
    fs.watchFile(file, { interval: POLL_MS }, onChange);
  }

  watch();
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration('autosaveNotify.statusFile')) watch();
    }),
    { dispose: () => file && fs.unwatchFile(file, onChange) }
  );
}

function deactivate() {}

module.exports = { activate, deactivate };
