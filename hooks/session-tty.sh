#!/bin/bash
# Print the tty of the Terminal tab that owns the current process, or nothing.
#
# Walking up the process tree is not enough on its own. A background job, a
# subagent and the pty host all sit on their own ptys, so the nearest tty is
# usually an invisible one. The tty we want is the one that actually belongs to
# a Terminal tab, so the ancestry is collected first and matched against the
# tabs Terminal really has.
#
#   session-tty.sh            resolve for this process
#   session-tty.sh --ancestry just print the candidate ttys, cheapest form
#   session-tty.sh --host     which terminal app this process lives in

# One ps snapshot, walked in awk. This used to be a ps call per generation,
# which was both slow and fragile: the walk has to finish before the caller
# exits, because a backgrounded copy gets reparented to launchd and loses the
# ancestry entirely. One fork is fast enough to run inline.
ancestry() {
  local start="${1:-$$}"
  ps -Ao pid=,ppid=,tty= | awk -v start="$start" '
    { ppid[$1] = $2; tty[$1] = $3 }
    END {
      p = start
      for (i = 0; i < 16; i++) {
        if (!(p in ppid)) break
        t = tty[p]
        if (t != "??" && t != "?" && t != "-" && t != "") print "/dev/" t
        p = ppid[p]
        if (p <= 1) break
      }
    }'
}

# Which app owns this session's terminal.
#
# TERM_PROGRAM is the obvious signal but it is not reliable here: hooks often
# run in a context that never inherited it (it is unset in a background job, for
# one). So the environment is preferred when present, and the process ancestry
# is the fallback that actually works. Matching is on comm= (the executable
# path) rather than command=, so a stray argument cannot produce a false match.
host_from_ancestry() {
  ps -Ao pid=,ppid=,comm= | awk -v start="${1:-$$}" '
    { p = $1; pp = $2; $1 = ""; $2 = ""; sub(/^ +/, ""); ppid[p] = pp; cmd[p] = $0 }
    END {
      q = start
      for (i = 0; i < 24; i++) {
        if (!(q in ppid)) break
        print cmd[q]
        q = ppid[q]
        if (q <= 1) break
      }
    }'
}

detect_host() {
  case "$TERM_PROGRAM" in
    vscode)         echo vscode;         return ;;
    WarpTerminal)   echo WarpTerminal;   return ;;
    Apple_Terminal) echo Apple_Terminal; return ;;
    iTerm.app)      echo iTerm.app;      return ;;
  esac
  case "$(host_from_ancestry "$$")" in
    *"Visual Studio Code.app"*|*"Code Helper"*) echo vscode ;;
    *"Warp.app"*)                               echo WarpTerminal ;;
    *"Terminal.app"*)                           echo Apple_Terminal ;;
    *"iTerm.app"*)                              echo iTerm.app ;;
    *)                                          echo "" ;;
  esac
}

if [ "$1" = "--host" ]; then
  detect_host
  exit 0
fi

if [ "$1" = "--ancestry" ]; then
  ancestry | awk '!seen[$0]++'
  exit 0
fi

CAND="$(ancestry | awk '!seen[$0]++')"
[ -n "$CAND" ] || exit 1

# Ask Terminal which ttys it actually shows, then take the first candidate that
# appears there. Ordering matters: the ancestry is nearest first, so a real tab
# close to us wins over the login shell further up.
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
[ -n "$TABS" ] || exit 1

while IFS= read -r c; do
  [ -n "$c" ] || continue
  if printf '%s\n' "$TABS" | grep -qx "$c"; then
    echo "$c"
    exit 0
  fi
done <<< "$CAND"
exit 1
