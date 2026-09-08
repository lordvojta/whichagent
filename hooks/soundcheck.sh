#!/bin/bash
# Play each layer of the notification stack in turn, so a failure can be
# localised instead of guessed at.
#
#   ~/.claude/hooks/soundcheck.sh

# Everything this script shows is a test. Marked by construction so a demo
# banner can never be mistaken for a real session firing.
export AGENT_NOTIFY_TEST=1

SOUNDS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../sounds" && pwd)"
S="${TMPDIR:-/tmp}/agent-sound"

echo "system: $(osascript -e 'get volume settings' 2>/dev/null)"
echo "output: $(system_profiler SPAudioDataType 2>/dev/null | awk '/Default Output Device: Yes/{f=1} f&&/Output Source:/{print $3,$4,$5; exit}')"
if read -r p < "$S/hitplay.pid" 2>/dev/null && kill -0 "$p" 2>/dev/null; then
  echo "daemon: running (pid $p)"
else
  echo "daemon: NOT RUNNING"
fi
echo

echo "1) direct player (bypasses the daemon)"
afplay -v 1 "$SOUNDS/claude-done.wav"; sleep 1
echo "2) warm daemon (what the hooks use)"
printf '%s\t1\n' "$SOUNDS/claude-done.wav" > "$S/hit.fifo" 2>/dev/null; sleep 1.5
echo "3) full hook, exactly as an agent fires it"
rm -f "$S"/claude.*
( cd "$HOME" && bash "$HOME/.claude/hooks/agent-sound.sh" done claude ); sleep 2

cat <<'MSG'

Which numbers did you hear? 1 2 3, or none.
  only 1        -> the daemon is broken, hooks will be silent
  1 and 2, no 3 -> the dispatcher or its suppression logic is eating the event
  all three     -> the stack works; the problem is that an already-running
                   agent session still has the OLD hooks loaded. Restart it.
  none          -> audio output is not reaching your ears at all
MSG
