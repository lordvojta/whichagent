#!/usr/bin/env bash
# agentcue installer.
#
# Merges into an existing setup rather than replacing it. Claude Code users
# routinely already have hooks in settings.json, and clobbering those would be
# the single most destructive thing an installer of this kind could do.
#
#   ./install.sh              install
#   ./install.sh --dry-run    print what would change, touch nothing
#   ./install.sh --uninstall  remove only what this installed

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE="$HOME/.claude"
HOOKS="$CLAUDE/hooks"
SOUNDS="$CLAUDE/sounds"
SETTINGS="$CLAUDE/settings.json"
CONF="$CLAUDE/agent-sound.conf"

DRY=0; UNINSTALL=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

say()  { printf '  %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }
run()  { if [ "$DRY" = 1 ]; then say "would: $*"; else "$@"; fi; }

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
head_ "preflight"
if [ ! -x "$REPO/bin/agenthud" ] || [ ! -x "$REPO/bin/hitplay" ]; then
  echo "  binaries missing. run 'make' first." >&2
  exit 1
fi
say "binaries built"
[ "$DRY" = 1 ] && say "DRY RUN: nothing will be written"

# ---------------------------------------------------------------- uninstall
if [ "$UNINSTALL" = 1 ]; then
  head_ "uninstall"
  for f in agent-sound.sh agent-notify.sh agent-focus.sh agent-icon.py \
           session-tty.sh agent-sound-codex.sh agent-demo.sh soundcheck.sh \
           notify-test.sh warp-sound.zsh; do
    [ -e "$HOOKS/$f" ] && run rm -f "$HOOKS/$f"
  done
  run rm -f "$SOUNDS/agenthud" "$SOUNDS/hitplay"
  if [ -f "$SETTINGS" ]; then
    run cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
    if [ "$DRY" = 0 ]; then
      python3 - "$SETTINGS" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f: cfg = json.load(f)
hooks = cfg.get("hooks", {})
for event in list(hooks):
    kept = []
    for group in hooks[event]:
        subs = [h for h in group.get("hooks", [])
                if "agent-sound.sh" not in json.dumps(h)]
        if subs:
            group["hooks"] = subs
            kept.append(group)
    if kept: hooks[event] = kept
    else: hooks.pop(event)
if hooks: cfg["hooks"] = hooks
else: cfg.pop("hooks", None)
with open(p, "w") as f: json.dump(cfg, f, indent=2); f.write("\n")
PY
    fi
  fi
  say "removed. your settings.json was backed up; agent-sound.conf was left alone."
  exit 0
fi

# ---------------------------------------------------------------- files
head_ "hooks and binaries"
run mkdir -p "$HOOKS" "$SOUNDS/assets"
n=0
for f in "$REPO"/hooks/*; do
  # Files only: a stray __pycache__ would otherwise be copied as a directory.
  [ -f "$f" ] || continue
  run cp "$f" "$HOOKS/"
  # chmod only what we just installed. Globbing $HOOKS would change the mode
  # of the user's own unrelated hooks sitting in the same directory.
  case "$f" in *.sh|*.py) run chmod +x "$HOOKS/$(basename "$f")" ;; esac
  n=$((n+1))
done
say "installed $n hooks"

run cp "$REPO/bin/agenthud" "$REPO/bin/hitplay" "$SOUNDS/"
[ -d "$REPO/bin/AgentNotify.app" ] && run cp -R "$REPO/bin/AgentNotify.app" "$SOUNDS/"
for w in "$REPO"/sounds/*.wav; do run cp "$w" "$SOUNDS/"; done
run cp "$REPO"/sounds/generate-*.py "$SOUNDS/" 2>/dev/null || true
[ -f "$REPO/sounds/assets/test-icon.png" ] && run cp "$REPO/sounds/assets/test-icon.png" "$SOUNDS/assets/"
say "installed binaries and $(ls -1 "$REPO"/sounds/*.wav 2>/dev/null | wc -l | tr -d ' ') cues"

# ---------------------------------------------------------------- config
head_ "config"
if [ -f "$CONF" ]; then
  say "$CONF exists, left untouched"
else
  run cp "$REPO/agent-sound.conf.example" "$CONF"
  say "wrote $CONF from the example"
fi

# ---------------------------------------------------------------- settings
head_ "settings.json"
if [ -f "$SETTINGS" ]; then
  run cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
  say "backed up existing settings.json"
else
  [ "$DRY" = 0 ] && echo '{}' > "$SETTINGS"
fi

if [ "$DRY" = 0 ]; then
  python3 - "$SETTINGS" "$HOOKS" <<'PY'
import json, sys, os

settings, hooks_dir = sys.argv[1], sys.argv[2]
script = os.path.join(hooks_dir, "agent-sound.sh")

# event -> (matcher, argv). PreToolUse fires on ExitPlanMode only: that is the
# moment a plan becomes reviewable, which is a different cue from "finished".
WANT = {
    "Stop":         (None,           f'"{script}" done'),
    "Notification": (None,           f'"{script}" input'),
    "SessionStart": (None,           f'"{script}" warm'),
    "PreToolUse":   ("ExitPlanMode", f'"{script}" plan'),
}

with open(settings) as f:
    try: cfg = json.load(f)
    except Exception: cfg = {}
hooks = cfg.setdefault("hooks", {})

added = kept = 0
for event, (matcher, cmd) in WANT.items():
    groups = hooks.setdefault(event, [])
    # Idempotent: never add a second copy of our own hook, and never disturb
    # anyone else's. Matching on the script name rather than the exact command
    # so an upgrade that changes arguments still replaces rather than doubles.
    for g in groups:
        for h in g.get("hooks", []):
            if "agent-sound.sh" in json.dumps(h):
                h["command"] = cmd
                kept += 1
                break
        else:
            continue
        break
    else:
        entry = {"hooks": [{"type": "command", "command": cmd}]}
        if matcher: entry["matcher"] = matcher
        groups.append(entry)
        added += 1

with open(settings, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(f"  merged: {added} added, {kept} updated, other hooks untouched")
PY
else
  say "would merge 4 hook entries into settings.json"
fi

# ---------------------------------------------------------------- optional
head_ "optional integrations"
if [ -d "$HOME/.hammerspoon" ]; then
  run cp "$REPO/integrations/hammerspoon/agenthud.lua" "$HOME/.hammerspoon/"
  if ! grep -q "agenthud.lua" "$HOME/.hammerspoon/init.lua" 2>/dev/null; then
    say "ACTION NEEDED: add to ~/.hammerspoon/init.lua ->"
    say '  dofile(os.getenv("HOME") .. "/.hammerspoon/agenthud.lua")'
  else
    say "hammerspoon: already wired"
  fi
else
  say "hammerspoon not installed, skipping keyboard shortcuts"
fi

if command -v code >/dev/null 2>&1; then
  say "VS Code found. For per-terminal focus:"
  say "  cd integrations/vscode && npx --yes @vscode/vsce package --allow-missing-repository --skip-license"
  say "  code --install-extension claude-terminal-focus-*.vsix"
else
  say "VS Code CLI not on PATH, skipping terminal-focus extension"
fi

head_ "done"
say "try it:  $HOOKS/agent-demo.sh"
say "check:   $HOOKS/soundcheck.sh"
