#!/bin/bash
# Post a macOS notification banner for a coding-agent event.
#
#   agent-notify.sh EVENT PROVIDER [REPO_DIR]
#
# The banner answers the two questions the sound cannot: which repo, and what
# happened. The sound is instant and tells you an agent finished; this tells you
# it was acme-web and that it finished planning rather than finished working.
#
#   title     repo name
#   subtitle  "Claude Code: plan ready"
#   message   ~/code/acme-web (main)
#   image     the project favicon or logo, else a generated identicon
#
# On the app icon: macOS removed the API to override a notification's app icon,
# so the banner always carries the icon of whichever app posted it. The project
# artwork goes in -contentImage instead, which is the image on the right.
#
# Delivery is attempted in order, because notification permission is granted per
# posting app and is attributed to the responsible parent process:
#   1. terminal-notifier directly
#   2. terminal-notifier via LaunchServices, which gives it its own identity
#   3. osascript, which posts under Script Editor
#
# Env:
#   AGENT_NOTIFY_DISABLE=1  no banner, keep the sound
#   AGENT_NOTIFY_SPEAK=1    also say the repo and the event out loud. This needs
#                           no notification permission at all, which matters
#                           because macOS keeps notification consent in
#                           com.apple.ncprefs and a process with no GUI
#                           attribution cannot post, read or reset it. Speech is
#                           the one channel that always works.
#   AGENT_NOTIFY_VOICE      voice for the above, default the system voice

# Provider-agnostic settings. Codex hook commands must be a plain string and
# opencode spawns without a shell, so prefixing env vars per provider is
# fragile. A conf file is the one place every provider reads the same way.
# Anything already set in the environment wins over the file.
CONF="${AGENT_SOUND_CONF:-$HOME/.claude/agent-sound.conf}"
if [ -f "$CONF" ]; then
  _speak_env="$AGENT_NOTIFY_SPEAK"
  _disable_env="$AGENT_NOTIFY_DISABLE"
  # shellcheck disable=SC1090
  . "$CONF"
  [ -n "$_speak_env" ] && AGENT_NOTIFY_SPEAK="$_speak_env"
  [ -n "$_disable_env" ] && AGENT_NOTIFY_DISABLE="$_disable_env"
fi

[ -n "$AGENT_NOTIFY_DISABLE" ] && exit 0

# --diagnose runs every delivery route in turn and reports which ones worked,
# because the normal path deliberately swallows output and always exits 0.
DIAGNOSE=0
if [ "$1" = "--diagnose" ]; then
  DIAGNOSE=1
  shift
fi

EVENT="${1:-done}"
PROVIDER="${2:-default}"
REPO="$3"

case "$EVENT" in
  warm) exit 0 ;;   # device warm-up is not an event worth a banner
esac

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------- repo

[ -n "$REPO" ] || REPO="${CLAUDE_PROJECT_DIR:-$PWD}"
ROOT="$(cd "$REPO" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$ROOT" ] || ROOT="$REPO"
NAME="$(basename "$ROOT")"

BRANCH="$(cd "$ROOT" 2>/dev/null && git branch --show-current 2>/dev/null)"
SHORT="${ROOT/#$HOME/~}"
[ -n "$BRANCH" ] && SHORT="$SHORT ($BRANCH)"

# ------------------------------------------------------------------ label

case "$PROVIDER" in
  claude)   PRETTY="Claude Code" ;;
  codex)    PRETTY="Codex" ;;
  opencode) PRETTY="opencode" ;;
  warp)     PRETTY="Warp" ;;
  *)        PRETTY="$PROVIDER" ;;
esac

case "$EVENT" in
  done)  WHAT="finished" ;;
  plan)  WHAT="plan ready for review" ;;
  input) WHAT="needs your input" ;;
  *)     WHAT="$EVENT" ;;
esac

TITLE="$NAME"
SUBTITLE="$PRETTY: $WHAT"
MESSAGE="$SHORT"
GROUP="agent-$NAME"

# ------------------------------------------------------------------- icon

ICON=""
if [ -x "$DIR/agent-icon.py" ] || [ -f "$DIR/agent-icon.py" ]; then
  ICON="$(python3 "$DIR/agent-icon.py" "$ROOT" 2>/dev/null)"
fi

# ------------------------------------------------------------------- post

TN="$(command -v terminal-notifier 2>/dev/null)"

args=(-title "$TITLE" -subtitle "$SUBTITLE" -message "$MESSAGE" -group "$GROUP")
[ -n "$ICON" ] && [ -f "$ICON" ] && args+=(-contentImage "$ICON")

# Clicking the banner jumps to the terminal tab this session is running in.
# Only terminal-notifier can do this: the osascript fallback has no click
# action, and our own bundle exits before a click could ever be delivered.
FOCUS="$DIR/agent-focus.sh"
FOCUSCMD=""
if [ -x "$FOCUS" ]; then
  FOCUSCMD="\"$FOCUS\" focus ${CLAUDE_CODE_SESSION_ID:-}"
  args+=(-execute "$FOCUSCMD")
fi

APPBUNDLE="$(find /opt/homebrew/Cellar/terminal-notifier -maxdepth 4 -name 'terminal-notifier.app' 2>/dev/null | head -1)"

if [ "$DIAGNOSE" = 1 ]; then
  echo "repo:     $ROOT"
  echo "title:    $TITLE"
  echo "subtitle: $SUBTITLE"
  echo "message:  $MESSAGE"
  echo "image:    ${ICON:-none}"
  echo
  echo "route 0: AgentNotify.app (Coding Agents)"
  AGENTNOTIFY="$DIR/../sounds/AgentNotify.app/Contents/MacOS/agentnotify"
  if [ -x "$AGENTNOTIFY" ]; then
    "$AGENTNOTIFY" "$TITLE" "$SUBTITLE" "$MESSAGE" "$GROUP" "$ICON"; echo "  exit=$?"
  else
    echo "  not built"
  fi
  echo "route 1: terminal-notifier direct"
  if [ -n "$TN" ]; then
    "$TN" "${args[@]}"; echo "  exit=$?"
  else
    echo "  not installed"
  fi
  echo "route 2: terminal-notifier via LaunchServices"
  if [ -n "$APPBUNDLE" ]; then
    open -na "$APPBUNDLE" --args "${args[@]}"; echo "  exit=$? (launch only, delivery not observable)"
  else
    echo "  app bundle not found"
  fi
  echo "route 3: osascript (Script Editor, no image)"
  osascript -e "display notification \"$MESSAGE\" with title \"$TITLE (route 3)\" subtitle \"$SUBTITLE\""
  echo "  exit=$?"
  echo
  echo "Look at your screen: up to three banners should have appeared."
  echo "Tell me which ones you saw (1, 2, 3, or none)."
  exit 0
fi

# Delivery ladder. Ordered by quality, not by likelihood: if the real thing is
# ever permitted we want it, and otherwise we fall to something that always
# works rather than to something that silently does not.

# 1. A real Notification Center banner. Carries the icon and the click action,
#    persists in the notification list, and is what you actually want. Needs
#    notification permission, which is off for this app on this machine.
if [ -n "$TN" ]; then
  "$TN" "${args[@]}" >/dev/null 2>&1 && exit 0
fi

# 2. Our own on-screen HUD. An app drawing its own window needs no notification
#    permission at all, so this is the route that works here. Same icon, same
#    click to focus, and it never steals keyboard focus.
HUD="$DIR/../sounds/agenthud"
if [ -x "$HUD" ]; then
  nohup "$HUD" "$TITLE" "$SUBTITLE" "$MESSAGE" "${ICON:-}" "${FOCUSCMD:-}" 5 "$EVENT" "$PROVIDER" \
    >/dev/null 2>&1 &
  exit 0
fi

# Speech does not care about notification consent, so it is attempted
# independently of whether any banner route worked.
speak() {
  [ -n "$AGENT_NOTIFY_SPEAK" ] || return 0
  command -v say >/dev/null 2>&1 || return 0
  local voice=()
  [ -n "$AGENT_NOTIFY_VOICE" ] && voice=(-v "$AGENT_NOTIFY_VOICE")
  # Rate a touch above default: this lands right after a 0.4 s drum hit and
  # should not turn a notification into a sentence.
  say "${voice[@]}" -r 210 "$NAME, $WHAT" >/dev/null 2>&1 &
}
speak

# Last resort. No image support, and it posts as Script Editor.
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
osascript -e "display notification \"$(esc "$MESSAGE")\" with title \"$(esc "$TITLE")\" subtitle \"$(esc "$SUBTITLE")\"" >/dev/null 2>&1
exit 0
