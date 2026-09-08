#!/bin/bash
# Play a short drill hit for a coding-agent lifecycle event.
#
#   agent-sound.sh EVENT [PROVIDER]
#
#   EVENT     done  | plan | input  (any name works, it just needs a matching wav)
#   PROVIDER  claude | codex | opencode | warp | ...  (auto-detected when omitted)
#
# The whole point of this script is that nothing happens before afplay. The
# previous version made four to six osascript round trips to pause Spotify and
# read the system volume first, which cost 0.5 to 1 second, so the hit landed
# long after the moment it was reporting. Music pausing is now opt in.
#
# Sound file resolution, first hit wins:
#   $AGENT_SOUND_<PROVIDER>_<EVENT>   explicit path override
#   <dir>/<provider>-<event>.wav
#   <dir>/default-<event>.wav
#   <dir>/<provider>-done.wav
#   <dir>/default-done.wav
#
# Env:
#   AGENT_SOUND_MUTE=1          play nothing
#   AGENT_SOUND_VOLUME=1        afplay volume, 0.0 to 2.0
#   AGENT_SOUND_DIR             where the wavs live
#   AGENT_SOUND_PAUSE_MUSIC=1   pause Spotify/Music around the hit (slow, see above)
#   AGENT_SOUND_MIN_VOLUME=n    raise system output volume to at least n first (slow)
#   AGENT_SOUND_NO_NOTIFY=1     play the hit but post no banner
#   AGENT_SOUND_SUPPRESS_WINDOW=6
#                               seconds during which a `done` is swallowed after a
#                               more specific event fired. Claude Code emits Stop
#                               immediately after ExitPlanMode, so without this you
#                               would hear the plan hit and the done hit back to back.

[ -n "$AGENT_SOUND_MUTE" ] && exit 0

EVENT="${1:-done}"
PROVIDER="$2"

DIR="${AGENT_SOUND_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../sounds" 2>/dev/null && pwd)}"
[ -d "$DIR" ] || exit 0

# ---------------------------------------------------------------- provider

if [ -z "$PROVIDER" ]; then
  if [ -n "$AGENT_SOUND_PROVIDER" ]; then
    PROVIDER="$AGENT_SOUND_PROVIDER"
  elif [ -n "$CLAUDECODE" ] || [ -n "$CLAUDE_CODE_SSE_PORT" ]; then
    PROVIDER=claude
  elif [ -n "$CODEX_HOME" ] || [ -n "$CODEX_SANDBOX" ] || [ -n "$CODEX_THREAD_ID" ]; then
    PROVIDER=codex
  elif [ -n "$OPENCODE" ] || [ -n "$OPENCODE_BIN_PATH" ]; then
    PROVIDER=opencode
  elif [ -n "$WARP_IS_LOCAL_SHELL_SESSION" ] || [ "$TERM_PROGRAM" = "WarpTerminal" ]; then
    PROVIDER=warp
  else
    PROVIDER=default
  fi
fi

# ------------------------------------------------------- event suppression

STATE="${TMPDIR:-/tmp}/agent-sound"
mkdir -p "$STATE" 2>/dev/null
WINDOW="${AGENT_SOUND_SUPPRESS_WINDOW:-6}"
NOW=$(date +%s)
MARK="$STATE/$PROVIDER.specific"

if [ "$EVENT" = "warm" ]; then
  :
elif [ "$EVENT" = "done" ]; then
  # A plan or input hit already told the story. Do not tack a done onto it.
  if [ -f "$MARK" ]; then
    LAST=$(cat "$MARK" 2>/dev/null)
    case "$LAST" in
      ''|*[!0-9]*) LAST=0 ;;
    esac
    [ $((NOW - LAST)) -lt "$WINDOW" ] && exit 0
  fi
else
  echo "$NOW" > "$MARK" 2>/dev/null
fi

# Debounce: identical event for the same provider inside the same second.
DEB="$STATE/$PROVIDER.$EVENT"
if [ -f "$DEB" ] && [ "$(cat "$DEB" 2>/dev/null)" = "$NOW" ]; then
  exit 0
fi
echo "$NOW" > "$DEB" 2>/dev/null

# ------------------------------------------------------------ resolve file

up() { echo "$1" | tr '[:lower:]-' '[:upper:]_'; }
OVERRIDE_VAR="AGENT_SOUND_$(up "$PROVIDER")_$(up "$EVENT")"
eval "OVERRIDE=\"\${$OVERRIDE_VAR:-}\""

SOUND=""
for candidate in \
  "$OVERRIDE" \
  "$DIR/$PROVIDER-$EVENT.wav" \
  "$DIR/default-$EVENT.wav" \
  "$DIR/$PROVIDER-done.wav" \
  "$DIR/default-done.wav"
do
  if [ -n "$candidate" ] && [ -f "$candidate" ]; then
    SOUND="$candidate"
    break
  fi
done

[ -n "$SOUND" ] || exit 0

VOLUME="${AGENT_SOUND_VOLUME:-1}"
HOOKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_HINT="${CLAUDE_PROJECT_DIR:-$PWD}"

# Record which terminal tab this session lives in, so a notification click and
# the global hotkey can both jump back to it.
#
# Resolving the tab means walking the process ancestry, which cannot be done in
# a backgrounded copy: nohup reparents it to launchd and the ancestry is gone.
# It has to run inline. That costs about 80 ms, so it runs once per session and
# every later event just moves the "most recent" pointer, which is free.
SESSREG="$HOME/.claude/cache/agent-sessions"
if [ -n "$CLAUDE_CODE_SESSION_ID" ] && [ -x "$HOOKDIR/agent-focus.sh" ]; then
  # Re-register when the record is missing OR written by an older schema. The
  # previous version only checked existence, so a record predating a new field
  # was touched forever and never rewritten: it could not self-heal, because
  # this branch is what prevented it.
  if "$HOOKDIR/agent-focus.sh" current "$CLAUDE_CODE_SESSION_ID" 2>/dev/null; then
    echo "$CLAUDE_CODE_SESSION_ID" > "$SESSREG/.last" 2>/dev/null
    touch "$SESSREG/$CLAUDE_CODE_SESSION_ID" 2>/dev/null
  else
    "$HOOKDIR/agent-focus.sh" register >/dev/null 2>&1
  fi
fi

# Always after the sound has been fired, never before it.
fire_notify() {
  [ -n "$AGENT_SOUND_NO_NOTIFY" ] && return 0
  [ -f "$HOOKDIR/agent-notify.sh" ] || return 0
  nohup "$HOOKDIR/agent-notify.sh" "$EVENT" "$PROVIDER" "$REPO_HINT" >/dev/null 2>&1 &
  return 0
}

# ------------------------------------------------------------------- play

FIFO="$STATE/hit.fifo"
PIDFILE="$STATE/hitplay.pid"
HITPLAY="$DIR/hitplay"

daemon_alive() {
  local p=""
  [ -f "$PIDFILE" ] || return 1
  read -r p < "$PIDFILE" 2>/dev/null || return 1
  [ -n "$p" ] || return 1
  kill -0 "$p" 2>/dev/null
}

start_daemon() {
  [ -x "$HITPLAY" ] || return 1
  [ -n "$AGENT_SOUND_NO_DAEMON" ] && return 1
  daemon_alive && return 0
  nohup "$HITPLAY" --daemon "$DIR" >/dev/null 2>&1 &
  return 0
}

if [ "$EVENT" = "warm" ]; then
  start_daemon
  exit 0
fi

# Fast path. A warm daemon holds the audio device open with every wav already
# in memory, so firing a hit is one write into a FIFO and no process spawn at
# all: about 0.2 ms. Spawning afplay instead costs a fixed 800 ms on this
# machine no matter how short the file is, which is the difference between
# landing on the beat and landing most of a second late.
if [ -z "$AGENT_SOUND_PAUSE_MUSIC" ] && [ -z "$AGENT_SOUND_MIN_VOLUME" ] &&
   [ -p "$FIFO" ] && daemon_alive; then
  if printf '%s\t%s\n' "$SOUND" "$VOLUME" > "$FIFO" 2>/dev/null; then
    fire_notify
    exit 0
  fi
fi

# No daemon yet. Start one so the next hit is instant, and fall back for this one.
start_daemon

if [ -z "$AGENT_SOUND_PAUSE_MUSIC" ] && [ -z "$AGENT_SOUND_MIN_VOLUME" ]; then
  command -v afplay >/dev/null 2>&1 || exit 0
  fire_notify
  exec afplay -v "$VOLUME" -q 1 "$SOUND" >/dev/null 2>&1
fi

command -v afplay >/dev/null 2>&1 || exit 0
fire_notify

# Slow path, opt in only.
osa() { osascript -e "$1" 2>/dev/null; }
resume_spotify=0
resume_music=0
old_volume=""

cleanup() {
  [ "$resume_spotify" = 1 ] && osa 'tell application "Spotify" to play' >/dev/null 2>&1
  [ "$resume_music" = 1 ] && osa 'tell application "Music" to play' >/dev/null 2>&1
  [ -n "$old_volume" ] && osa "set volume output volume $old_volume" >/dev/null 2>&1
  return 0
}
trap cleanup EXIT INT TERM

if [ -n "$AGENT_SOUND_PAUSE_MUSIC" ]; then
  if [ "$(osa 'application "Spotify" is running')" = "true" ] &&
     [ "$(osa 'tell application "Spotify" to player state as text')" = "playing" ]; then
    osa 'tell application "Spotify" to pause'
    resume_spotify=1
  fi
  if [ "$(osa 'application "Music" is running')" = "true" ] &&
     [ "$(osa 'tell application "Music" to player state as text')" = "playing" ]; then
    osa 'tell application "Music" to pause'
    resume_music=1
  fi
fi

if [ -n "$AGENT_SOUND_MIN_VOLUME" ]; then
  cur="$(osa 'output volume of (get volume settings)')"
  if [ -n "$cur" ] && [ "$cur" -lt "$AGENT_SOUND_MIN_VOLUME" ] 2>/dev/null; then
    old_volume="$cur"
    osa "set volume output volume $AGENT_SOUND_MIN_VOLUME"
  fi
fi

afplay -v "$VOLUME" -q 1 "$SOUND" >/dev/null 2>&1
exit 0
