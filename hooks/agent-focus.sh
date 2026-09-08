#!/bin/bash
# Jump to the terminal window a coding-agent session is running in.
#
#   agent-focus.sh register [SESSION_ID]   record where this session lives
#   agent-focus.sh focus [SESSION_ID]      bring that window to the front
#   agent-focus.sh list                    show what has been registered
#
# `focus` with no id uses the most recently registered session, which is what
# the global hotkey calls: "take me back to whatever just wanted me".
#
# Registration is deliberately cheap. It records the candidate ttys from the
# process ancestry only, with no AppleScript, because it runs on every hook.
# The expensive part, asking Terminal which tab owns which tty, is deferred to
# focus time, where a hundred milliseconds costs nothing.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REG="$HOME/.claude/cache/agent-sessions"
mkdir -p "$REG" 2>/dev/null

# Where to go when the session's host is unknown, which is the case for every
# registration made before hosts were recorded.
CONF="${AGENT_SOUND_CONF:-$HOME/.claude/agent-sound.conf}"
[ -f "$CONF" ] && . "$CONF" 2>/dev/null
DEFAULT_HOST="${AGENT_FOCUS_DEFAULT:-vscode}"

# Bump whenever a field is added to a registration record. Callers re-register
# on mismatch, so the new field appears everywhere instead of silently reading
# as absent. Adding HOST without this shipped a failure with no error at all:
# every pre-existing record kept no HOST, every lookup fell through to the
# default, and Apple Terminal sessions were quietly sent to VS Code.
REG_SCHEMA=2

# A recorded tty is only meaningful while something is still running on it.
# When a session dies its tty is recycled by the next terminal tab, and a stale
# entry then matches that new tab: the click lands on somebody else's window.
# 87 sessions were killed at once on this machine this afternoon, which is
# exactly the situation that fills the registry with recyclable ttys.
tty_live() {
  local t="${1#/dev/}"
  [ -n "$t" ] || return 1
  [ -n "$(ps -t "$t" -o pid= 2>/dev/null)" ]
}

# Drop entries whose tty is dead. Rate limited, because register runs on every
# hook and this costs a ps per entry.
prune_registry() {
  local now last marker f
  marker="$REG/.lastprune"
  now="$(date +%s)"
  if [ -f "$marker" ]; then
    read -r last < "$marker" 2>/dev/null || last=0
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $(( now - last )) -lt 300 ] && return 0
  fi
  echo "$now" > "$marker" 2>/dev/null
  for f in "$REG"/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in .last|.lastprune) continue ;; esac
    ( TTYS=""; . "$f" 2>/dev/null
      tty_live "${TTYS%%,*}" ) || rm -f "$f" 2>/dev/null
  done

  # Two records can name the same tty once a dead session's tty is recycled.
  # Anything matching on tty (the VS Code terminal lookup included) takes the
  # first hit, so a stale duplicate focuses the wrong terminal. Keep the newest.
  awk_in=""
  for f in "$REG"/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in .last|.lastprune) continue ;; esac
    ( TTYS=""; TS=0; . "$f" 2>/dev/null
      printf '%s\t%s\t%s\n' "${TTYS%%,*}" "${TS:-0}" "$f" )
  done | sort -t"$(printf '\t')" -k1,1 -k2,2nr | awk -F'\t' '
      $1 != "" { if ($1 == prev) print $3; prev = $1 }' | while read -r dup; do
    [ -n "$dup" ] && rm -f "$dup" 2>/dev/null
  done
}

CMD="${1:-focus}"
SID="${2:-${CLAUDE_CODE_SESSION_ID:-}}"

case "$CMD" in
register)
  [ -n "$SID" ] || SID="pid-$PPID"
  CAND="$("$DIR/session-tty.sh" --ancestry 2>/dev/null | paste -sd, -)"
  [ -n "$CAND" ] || exit 0
  # Record the host now rather than inferring it at focus time. A VS Code
  # integrated terminal sits on a pty owned by Code Helper, which Terminal.app
  # never reports, so asking Terminal at focus time can only ever fail for it.
  HOST="$("$DIR/session-tty.sh" --host 2>/dev/null)"
  {
    echo "SCHEMA=$REG_SCHEMA"
    echo "SID=$SID"
    echo "TTYS=$CAND"
    echo "CWD=${CLAUDE_PROJECT_DIR:-$PWD}"
    echo "HOST=$HOST"
    echo "TS=$(date +%s)"
  } > "$REG/$SID" 2>/dev/null
  echo "$SID" > "$REG/.last" 2>/dev/null
  prune_registry
  ;;

list)
  for f in "$REG"/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in .last|.lastprune) continue ;; esac
    ( HOST=""; . "$f" 2>/dev/null
      tty_live "${TTYS%%,*}" && alive=live || alive=STALE
      printf "  %s  %-5s host=%-14s ttys=%s  cwd=%s  age=%ss\n" \
        "${SID:0:12}" "$alive" "${HOST:-unknown}" "$TTYS" "$CWD" \
        "$(( $(date +%s) - ${TS:-0} ))" )
  done
  ;;

focus)
  [ -n "$SID" ] || SID="$(cat "$REG/.last" 2>/dev/null)"

  # Pick which session to focus. The requested one wins, but only while it is
  # still alive.
  #
  # Session death on this machine is bursty by design: a menu bar action
  # terminates every dev process past an age gate in one click, so roughly
  # twenty sessions can die within the same second, repeatedly. That means
  # `.last` routinely points at a session that died moments ago, and its
  # recorded tty is recycled by the next terminal tab soon after. Without this,
  # a click would activate a dead session's workspace, which is the same
  # wrong-window bug the Terminal scan already guards against.
  #
  # The liveness test must stay HERE, at scan time. Caching a liveness flag at
  # register time would be cheaper and would silently reintroduce the bug: a
  # burst outruns any cache, and nothing guarantees a fresh registration happens
  # between the burst and the next click.
  pick() {
    HOST=""; CWD=""; TTYS=""
    [ -f "$REG/$1" ] || return 1
    . "$REG/$1" 2>/dev/null
    tty_live "${TTYS%%,*}"
  }

  HOST=""; CWD=""; TTYS=""
  if ! { [ -n "$SID" ] && pick "$SID"; }; then
    SID=""
    for f in $(ls -t "$REG" 2>/dev/null); do
      case "$f" in .last|.lastprune) continue ;; esac
      if pick "$f"; then SID="$f"; break; fi
    done
    # Every entry is dead. Fall back to the configured default with no cwd,
    # rather than acting on a dead session's recorded workspace.
    [ -n "$SID" ] || { HOST=""; CWD=""; TTYS=""; }
  fi
  # Deliberately NOT coerced to DEFAULT_HOST here. An unknown host that jumps
  # straight to a default is indistinguishable from a correct answer until the
  # user notices it opening the wrong app. Unknown falls through to the tty
  # walk below, which either finds a real Terminal tab (correct) or finds
  # nothing (visibly wrong), and only then uses the default.

  activate_bundle() {
    osascript -e "tell application id \"$1\" to activate" >/dev/null 2>&1
  }

  # $1 = workspace dir, $2 = session id (may be empty on the fallback path)
  focus_vscode() {
    # `code <folder>` focuses a window that already has that folder open, and
    # only opens a new one if none does. `-r` is deliberately not used: it force
    # reuses the last active window, which would change what that window is
    # showing. There is no AppleScript API for selecting an individual
    # integrated-terminal tab, so window level focus is the realistic ceiling.
    if [ -n "$1" ] && [ -d "$1" ] && command -v code >/dev/null 2>&1 &&
       [ "${AGENT_FOCUS_VSCODE_OPEN:-1}" = "1" ]; then
      code "$1" >/dev/null 2>&1
    fi
    activate_bundle com.microsoft.VSCode

    # Then the individual terminal. VS Code's own API can do what the Claude
    # extension cannot: Terminal.processId gives the shell pid, a pid resolves
    # to a tty, and this registry already records ttys. tty is the join key.
    #
    # Order matters: a vscode:// URI is delivered to ONE window, so raising the
    # window holding this workspace first makes it far likelier the URI lands
    # where the terminal actually is. It does not guarantee it: with several
    # windows open the session's terminal may live in another one, and that
    # window simply logs a miss.
    if [ -n "$2" ] && [ "${AGENT_FOCUS_VSCODE_TERMINAL:-1}" = "1" ]; then
      open "vscode://local.claude-terminal-focus/focus?session=$2" >/dev/null 2>&1
    fi
  }

  # Hosts that own their own windows are a straight activation. Only Apple
  # Terminal exposes per-tab ttys over AppleScript, so only it gets the tab
  # walk below.
  case "$HOST" in
    "")           ;;   # unknown: try the tty walk before assuming anything
    vscode)       focus_vscode "$CWD" "$SID"; echo "true"; exit 0 ;;
    WarpTerminal) activate_bundle dev.warp.Warp-Stable; echo "true"; exit 0 ;;
    iTerm.app)    activate_bundle com.googlecode.iterm2; echo "true"; exit 0 ;;
  esac

  # Ask Terminal which ttys it is actually showing, once.
  TABS="$(osascript <<'AS' 2>/dev/null
tell application "Terminal"
  set out to ""
  repeat with w in windows
    try
      repeat with t in tabs of w
        try
          set out to out & (tty of t) & linefeed
        end try
      end repeat
    end try
  end repeat
  return out
end tell
AS
)"

  # First recorded tty that Terminal is really showing, or nothing.
  match_ttys() {
    local c old_ifs="$IFS"
    IFS=','
    for c in $1; do
      IFS="$old_ifs"
      [ -n "$c" ] || continue
      if printf '%s\n' "$TABS" | grep -qx "$c"; then echo "$c"; return 0; fi
      IFS=','
    done
    IFS="$old_ifs"
    return 1
  }

  WANT=""
  [ -n "$TTYS" ] && { WANT="$(match_ttys "$TTYS")" || WANT=""; }

  # Fall back to the most recent Apple Terminal session that has a visible tab.
  # The session that fired last is often a background job or a subagent sitting
  # on its own pty, and a pty with no Terminal tab cannot be brought to the
  # front. Sessions belonging to another host are skipped, since activating
  # Terminal for them would foreground the wrong application entirely.
  if [ -z "$WANT" ]; then
    for f in $(ls -t "$REG" 2>/dev/null); do
      case "$f" in .last|.lastprune) continue ;; esac
      [ -f "$REG/$f" ] || continue
      ( TTYS=""; HOST=""; . "$REG/$f" 2>/dev/null
        case "${HOST:-$DEFAULT_HOST}" in
          Apple_Terminal|"") ;;
          *) exit 1 ;;
        esac
        tty_live "${TTYS%%,*}" ) || continue
      TTYS=""; HOST=""; . "$REG/$f" 2>/dev/null
      if WANT="$(match_ttys "$TTYS")"; then break; fi
      WANT=""
    done
  fi

  # Nothing in Terminal matched. Go to the configured default rather than
  # assuming Terminal.app, which is what used to foreground the wrong app for
  # anyone working in a VS Code integrated terminal.
  if [ -z "$WANT" ]; then
    [ -n "$AGENT_FOCUS_DEBUG" ] && \
      echo "agent-focus: no tab matched, falling back to $DEFAULT_HOST" >&2
    case "$DEFAULT_HOST" in
      vscode)       focus_vscode "$CWD" "$SID" ;;
      WarpTerminal) activate_bundle dev.warp.Warp-Stable ;;
      iTerm.app)    activate_bundle com.googlecode.iterm2 ;;
      *)            osascript -e 'tell application "Terminal" to activate' >/dev/null 2>&1 ;;
    esac
    echo "false"
    exit 0
  fi

  osascript <<AS 2>/dev/null
tell application "Terminal"
  repeat with w in windows
    try
      repeat with t in tabs of w
        try
          if (tty of t) is "$WANT" then
            set selected tab of w to t
            set index of w to 1
            activate
            return "true"
          end if
        end try
      end repeat
    end try
  end repeat
  activate
  return "false"
end tell
AS
  ;;

current)
  # Exit 0 only if this record exists and matches the current schema. The
  # hot path uses this to decide whether a cheap touch is enough.
  [ -n "$SID" ] || exit 1
  [ -f "$REG/$SID" ] || exit 1
  ( SCHEMA=0; . "$REG/$SID" 2>/dev/null; [ "${SCHEMA:-0}" = "$REG_SCHEMA" ] )
  ;;

*)
  echo "usage: agent-focus.sh {register|focus|list|current} [session-id]" >&2
  exit 2
  ;;
esac
