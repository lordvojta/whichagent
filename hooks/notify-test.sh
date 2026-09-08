#!/bin/bash
# Work out which notification route actually works on this machine.
#
# Run this from a normal terminal window, NOT from inside a coding agent.
# Notification permission is granted per posting app and is attributed to the
# responsible parent process, so a helper launched from a restricted parent is
# denied without ever showing you a prompt.
#
#   ~/.claude/hooks/notify-test.sh [repo-dir]

# Clear any stuck permission record first. A request made from a restricted
# process gets auto-denied and macOS *persists* that denial, after which every
# later attempt fails silently, including from a normal terminal. tccutil only
# works from an unrestricted session, which is why this script exists.

# Everything this script shows is a test. Marked by construction so a demo
# banner can never be mistaken for a real session firing.
export AGENT_NOTIFY_TEST=1

echo "resetting notification permission records..."
for bid in fr.julienxx.oss.terminal-notifier cz.example.agentnotify; do
  printf '  %-42s ' "$bid"
  if tccutil reset UserNotification "$bid" >/dev/null 2>&1; then
    echo "reset"
  else
    echo "could not reset (may simply have no record yet)"
  fi
done
echo

REPO="${1:-$PWD}"
HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOUNDS="$HOOKS/../sounds"
AGENTNOTIFY="$SOUNDS/AgentNotify.app/Contents/MacOS/agentnotify"

ROOT="$(cd "$REPO" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$ROOT" ] || ROOT="$REPO"
NAME="$(basename "$ROOT")"

echo "repo: $ROOT"
ICON="$(python3 "$HOOKS/agent-icon.py" "$ROOT" 2>&1)"
echo "icon: $ICON"
if [ -f "$ICON" ]; then
  echo "      $(stat -f'%Sp %z bytes' "$ICON")  $(sips -g pixelWidth -g pixelHeight "$ICON" 2>/dev/null | tr -d '\n' | sed 's/  */ /g')"
else
  echo "      NOT A FILE, that alone would explain a missing image"
fi
echo

echo "========== A: agentnotify (our own bundle, shows as 'Coding Agents') =========="
if [ -x "$AGENTNOTIFY" ]; then
  echo "auth status: $("$AGENTNOTIFY" --check 2>&1)"
  "$AGENTNOTIFY" "$NAME" "Claude Code: A agentnotify" "with project image" "test-a" "$ICON"
  echo "exit=$?"
else
  echo "not built"
fi
echo

echo "========== B: terminal-notifier direct =========="
if command -v terminal-notifier >/dev/null 2>&1; then
  terminal-notifier -title "$NAME" -subtitle "Claude Code: B terminal-notifier" \
    -message "with project image" -group "test-b" -contentImage "$ICON"
  echo "exit=$?"
else
  echo "not installed"
fi
echo

echo "========== C: terminal-notifier, no image (control) =========="
if command -v terminal-notifier >/dev/null 2>&1; then
  terminal-notifier -title "$NAME" -subtitle "Claude Code: C no image" \
    -message "control, no image attached" -group "test-c"
  echo "exit=$?"
fi
echo

echo "========== D: osascript (Script Editor, cannot carry an image) =========="
osascript -e "display notification \"control\" with title \"$NAME\" subtitle \"Claude Code: D osascript\""
echo "exit=$?"
echo

cat <<'MSG'
Tell me, for each of A B C D:
  - did a banner appear at all
  - did it show the project image on the right

If C appears but B does not, the attachment is what breaks delivery.
If B and C both appear but neither shows an image, macOS is ignoring
attachments for that app and A is the way forward.
MSG
