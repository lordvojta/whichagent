#!/bin/bash
# Demonstrate the agent notification stack: sound, banner, per project icon,
# click to focus. Safe to run any time, it only shows things.
#
#   agent-demo.sh          the full walkthrough
#   agent-demo.sh quick    one banner and one hit


# Everything this script shows is a test. Marked by construction so a demo
# banner can never be mistaken for a real session firing.
export AGENT_NOTIFY_TEST=1

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOUNDS="$DIR/../sounds"
HUD="$SOUNDS/agenthud"
FOCUS="$DIR/agent-focus.sh"

b() { printf "\033[1m%s\033[0m\n" "$1"; }
dim() { printf "\033[2m%s\033[0m\n" "$1"; }

icon() { python3 "$DIR/agent-icon.py" "$1" 2>/dev/null; }

# Sample repos come from the sessions actually running, newest first, so the
# demo shows projects you are working in right now.
#
# This used to hardcode acme-web as the first sample. A demo that banners a
# project you are not touching teaches you to distrust the banners, which is
# the opposite of what a demo is for.
recent_repos() {
  local reg="$HOME/.claude/cache/agent-sessions" f
  [ -d "$reg" ] || return 0
  for f in $(ls -t "$reg" 2>/dev/null); do
    case "$f" in .*) continue ;; esac
    [ -f "$reg/$f" ] || continue
      # Skip $HOME itself: a session started there is not a project, and it
      # renders as a bare "~" where a repo name should be.
      ( CWD=""; . "$reg/$f" 2>/dev/null
        [ -d "$CWD" ] && [ "$CWD" != "$HOME" ] && echo "$CWD" )
  done | awk '!seen[$0]++'
}

# Current repo first, then whatever else is live, then a harmless last resort.
mapfile_repos() {
  local here
  here="$(cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$here" ] && echo "$here"
  recent_repos
  echo "$HOME/.claude"
}

REPOS="$(mapfile_repos | awk '!seen[$0]++')"
nth() { echo "$REPOS" | sed -n "${1}p"; }
R1="$(nth 1)"
R2="$(nth 2)"; [ -n "$R2" ] || R2="$R1"
R3="$(nth 3)"; [ -n "$R3" ] || R3="$R1"

hit() { "$DIR/agent-sound.sh" "${1:-done}" claude >/dev/null 2>&1; }

banner() {  # repo, subtitle, seconds
  local repo="$1" sub="$2" secs="${3:-4}"
  local name branch short
  name="$(basename "$repo")"
  branch="$(cd "$repo" 2>/dev/null && git branch --show-current 2>/dev/null)"
  short="${repo/#$HOME/~}"
  [ -n "$branch" ] && short="$short ($branch)"
  nohup "$HUD" "$name" "$sub" "$short" "$(icon "$repo")" \
        "\"$FOCUS\" focus" "$secs" >/dev/null 2>&1 &
}

[ -x "$HUD" ] || { echo "agenthud is not built. Run $SOUNDS/build.sh"; exit 1; }

if [ "$1" = "quick" ]; then
  hit done; banner "$R1" "Claude Code: finished" 4
  exit 0
fi

b "Agent notifications: demo"
dim "Watch the top right of your screen."
echo

b "1. The sound"
dim "Stock macOS Pop, trimmed to 0.23s and level matched."
"$SOUNDS/hitplay" --daemon "$SOUNDS" >/dev/null 2>&1 &
sleep 1
hit done
sleep 2
echo

b "2. A banner, with the project's own favicon"
dim "$(basename "$R1") -> $(icon "$R1")"
hit done; banner "$R1" "Claude Code: finished" 5
sleep 5
echo

b "3. Three projects at once, each with its own icon"
dim "They stack instead of covering each other."
banner "$R1" "Claude Code: finished" 6
sleep 0.5
banner "$R2" "Claude Code: plan ready for review" 6
sleep 0.5
banner "$R3" "Claude Code: needs your input" 6
hit done
sleep 7
echo

b "4. Click to jump back to the session"
dim "The next banner is clickable. Click it and the terminal tab"
dim "running that session comes to the front."
hit input
banner "$R1" "Claude Code: needs your input" 12
sleep 12
echo

b "5. The same jump, from a hotkey"
dim "System Settings > Keyboard > Keyboard Shortcuts > Services > General"
dim "  -> 'Focus Claude Session'"
dim "Runs: $FOCUS focus"
echo
b "Done."
