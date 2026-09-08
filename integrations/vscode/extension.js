// Claude Terminal Focus
//
// The Claude Code extension exposes a vscode:// handler, but its /open path
// dispatches to createPanel(), which only reveals a session already present in
// its sessionPanels map. That map is populated on panel creation, and there is
// no session-to-terminal mapping anywhere in it. So a session running in an
// integrated terminal cannot be revealed that way: firing the URI at one opens
// a spurious second panel instead.
//
// This bridges that gap. VS Code exposes Terminal.processId (the shell's pid),
// and a pid resolves to a tty via ps. The Claude focus registry already records
// each session's ttys, so tty is the join key that already exists on both sides.
//
//   vscode://local.claude-terminal-focus/focus?session=<uuid>
//   vscode://local.claude-terminal-focus/focus?tty=/dev/ttys013
//
// Caveat worth knowing: a vscode:// URI is delivered to ONE window. If the
// session lives in a different window, this window cannot focus it. Callers
// should focus the right window first (`code <folder>`) and then fire the URI.

const vscode = require('vscode');
const cp = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const REGISTRY = path.join(os.homedir(), '.claude', 'cache', 'agent-sessions');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

let log;

/** Normalise "ttys013" and "/dev/ttys013" to one form. */
function normaliseTty(t) {
  if (!t) return null;
  const s = String(t).trim();
  if (!s || s === '??' || s === '?') return null;
  return s.startsWith('/dev/') ? s : `/dev/${s}`;
}

/** The controlling terminal of a pid, or null if it has none. */
function ttyOfPid(pid) {
  try {
    const out = cp.execFileSync('ps', ['-o', 'tty=', '-p', String(pid)], {
      encoding: 'utf8',
      timeout: 2000,
    });
    return normaliseTty(out);
  } catch {
    return null;
  }
}

/** Every open terminal in this window, keyed by the tty of its shell. */
async function terminalsByTty() {
  const map = new Map();
  for (const term of vscode.window.terminals) {
    let pid;
    try {
      pid = await term.processId;
    } catch {
      continue;
    }
    if (!pid) continue;
    const tty = ttyOfPid(pid);
    if (tty && !map.has(tty)) map.set(tty, term);
  }
  return map;
}

/** The ttys recorded for a session id, most specific first. */
function ttysForSession(sessionId) {
  try {
    const text = fs.readFileSync(path.join(REGISTRY, sessionId), 'utf8');
    const m = text.match(/^TTYS=(.*)$/m);
    if (!m) return [];
    return m[1].split(',').map(normaliseTty).filter(Boolean);
  } catch {
    return [];
  }
}

/**
 * Reveal the terminal on one of `ttys`. preserveFocus:false so the cursor
 * lands in the terminal ready to type, which is the whole point of the jump.
 */
async function focusByTtys(ttys) {
  if (!ttys.length) return false;
  const map = await terminalsByTty();
  for (const tty of ttys) {
    const term = map.get(tty);
    if (term) {
      term.show(false);
      log.appendLine(`focused terminal on ${tty}`);
      return true;
    }
  }
  log.appendLine(`no terminal here for ${ttys.join(', ')}; open: ${[...map.keys()].join(', ') || 'none'}`);
  return false;
}

async function handleFocus(query) {
  const q = new URLSearchParams(query || '');
  const tty = q.get('tty');
  const session = q.get('session');

  let ttys = [];
  let label = '';

  if (tty) {
    const n = normaliseTty(tty);
    if (n) { ttys = [n]; label = n; }
  } else if (session) {
    if (!UUID.test(session)) {
      log.appendLine(`rejected malformed session id: ${session}`);
      return;
    }
    ttys = ttysForSession(session);
    label = session;
    if (!ttys.length) {
      vscode.window.showWarningMessage(
        `Claude Focus: no registry entry for session ${session.slice(0, 8)}.`);
      return;
    }
  } else {
    log.appendLine('focus called with neither tty nor session');
    return;
  }

  if (!(await focusByTtys(ttys))) {
    // Quiet by design: with several windows open, the URI lands in exactly one
    // of them and the others legitimately have nothing to focus. Shouting on
    // every miss would mean a warning in every other window.
    log.appendLine(`could not focus ${label} in this window`);
  }
}

function activate(context) {
  log = vscode.window.createOutputChannel('Claude Terminal Focus');
  context.subscriptions.push(log);
  log.appendLine('activated');

  context.subscriptions.push(
    vscode.window.registerUriHandler({
      handleUri(uri) {
        if (uri.path === '/focus') return handleFocus(uri.query);
        log.appendLine(`ignoring unknown path: ${uri.path}`);
      },
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('claudeTerminalFocus.list', async () => {
      const map = await terminalsByTty();
      const rows = [...map.entries()].map(([tty, t]) => `${tty}  ${t.name}`);
      log.appendLine('--- terminals in this window ---');
      rows.forEach((r) => log.appendLine('  ' + r));
      log.show(true);
      vscode.window.showInformationMessage(
        rows.length ? `${rows.length} terminal(s); see output channel.`
                    : 'No terminals with a resolvable tty in this window.');
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('claudeTerminalFocus.focusSession', async () => {
      let ids = [];
      try {
        ids = fs.readdirSync(REGISTRY).filter((f) => UUID.test(f));
      } catch { /* registry may not exist yet */ }
      if (!ids.length) {
        vscode.window.showWarningMessage('Claude Focus: registry is empty.');
        return;
      }
      const items = ids.map((id) => {
        let cwd = '';
        try {
          const t = fs.readFileSync(path.join(REGISTRY, id), 'utf8');
          cwd = (t.match(/^CWD=(.*)$/m) || [, ''])[1];
        } catch { /* ignore unreadable entry */ }
        return { label: cwd ? path.basename(cwd) : id.slice(0, 8), description: id, detail: cwd };
      });
      const pick = await vscode.window.showQuickPick(items, { placeHolder: 'Session to focus' });
      if (!pick) return;
      if (!(await focusByTtys(ttysForSession(pick.description)))) {
        vscode.window.showWarningMessage('Claude Focus: that session has no terminal in this window.');
      }
    })
  );
}

function deactivate() {}

module.exports = { activate, deactivate };
