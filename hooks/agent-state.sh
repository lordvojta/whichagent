#!/usr/bin/env bash
# Record whether a session is working or waiting on you.
#
# Wired as its own hook entry rather than folded into agent-sound.sh, for two
# reasons. agent-sound.sh has a suppression window that deliberately swallows a
# `done` arriving just after a `plan`, which is right for chimes and wrong for
# state: a swallowed event is a lost transition. And agent-sound.sh takes its
# event from argv and never reads stdin, whereas the distinctions that matter
# here (which notification type, who submitted the prompt) only exist in the
# JSON payload.
#
# State lives in its own directory, not in the focus registry. agent-focus.sh
# iterates that directory and treats every file as a session record, so a
# sibling file there would show up as a phantom session.
#
#   agent-state.sh          read the hook payload on stdin and record state
#   agent-state.sh gc       drop records for sessions that are gone

set -u

STATE_DIR="${AGENT_STATE_DIR:-$HOME/.claude/cache/agent-state}"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

# ---------------------------------------------------------------- gc
#
# gc is the ONLY authority on whether a session is still alive. The board and
# the menu bar both just list what is here, so they can never disagree with
# each other about what is running.
#
# Liveness is checked via the tty, not the session id. A session id appears
# nowhere in any process's arguments, so `pgrep -f "$sid"` matches nothing and
# would mark every session dead. The focus registry already records each
# session's tty, and a tty with a live claude on it is the signal that exists.
if [ "${1:-}" = "gc" ]; then
  command -v python3 >/dev/null 2>&1 || exit 0
  STATE_DIR="$STATE_DIR" \
  SESSION_DIR="${AGENT_SESSION_DIR:-$HOME/.claude/cache/agent-sessions}" \
  python3 <<'PY' 2>/dev/null
import os, subprocess, time

state_dir = os.environ["STATE_DIR"]
sess_dir = os.environ["SESSION_DIR"]
now = time.time()

# One ps call for every tty running claude, rather than one per session.
live_ttys = set()
try:
    out = subprocess.run(["ps", "-ax", "-o", "tty=,comm="],
                         capture_output=True, text=True, timeout=5).stdout
    for line in out.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and "claude" in parts[1] and parts[0] not in ("??", "?"):
            live_ttys.add("/dev/" + parts[0])
except Exception:
    live_ttys = None            # ps failed: keep everything rather than wrongly purge

for name in os.listdir(state_dir):
    if name.startswith("."):
        continue
    path = os.path.join(state_dir, name)
    try:
        updated = os.stat(path).st_mtime
    except OSError:
        continue

    ttys = []
    try:
        with open(os.path.join(sess_dir, name)) as f:
            for line in f:
                if line.startswith("TTYS="):
                    ttys = [t for t in line.strip()[5:].split(",") if t]
    except OSError:
        pass

    if live_ttys is None:
        dead = False
    elif ttys:
        dead = not any(t in live_ttys for t in ttys)
    else:
        # No registry record to join against, so liveness is unknowable. Fall
        # back to staleness, generously: a long-running session that simply has
        # not fired an event is not dead.
        dead = (now - updated) > 6 * 3600

    if dead:
        try: os.unlink(path)
        except OSError: pass
PY
  exit 0
fi

# ---------------------------------------------------------------- parse
# python3 rather than jq: jq is not installed by default on macOS and this runs
# on every hook, so a hard dependency would be a support burden for no gain.
command -v python3 >/dev/null 2>&1 || exit 0

read -r -d '' PARSE <<'PY' || true
import json, sys, os, time

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

sid = d.get("session_id")
if not sid:
    sys.exit(0)

# Subagents fire the same events as the main thread. Without this filter a
# session with three subagents reports itself waiting three times over.
# agent_id is the documented way to tell them apart; agent_type is not, because
# it is also set on the main thread of an --agent session.
if d.get("agent_id"):
    sys.exit(0)

event = d.get("hook_event_name") or ""
state = reason = None

if event == "Stop":
    # A finished turn IS a waiting session: the agent has stopped and will not
    # move until you say something. It is less urgent than a permission prompt,
    # not a different condition, so it is a reason rather than a third state.
    state, reason = "waiting", "finished"

elif event == "PreToolUse" and d.get("tool_name") == "ExitPlanMode":
    state, reason = "waiting", "plan"

elif event == "Notification":
    # Notification is a generic channel with 14 types, most unrelated to being
    # blocked: auth_success, agent_completed, push_notification, and
    # agent_needs_input (which reports on a DIFFERENT session, not this one).
    # Only these four mean this session cannot proceed without you.
    t = d.get("notification_type") or ""
    if t in ("permission_prompt", "elicitation_dialog", "elicitation_url_dialog"):
        state, reason = "waiting", "permission"
    elif t == "idle_prompt":
        state, reason = "waiting", "idle"
    else:
        sys.exit(0)

elif event == "UserPromptSubmit":
    # source distinguishes a human in the composer from a machine-injected
    # turn. A /loop wakeup or a scheduled fire is not you answering, and
    # treating it as such would silently clear a genuine block. The field is
    # documented as possibly absent while it rolls out, so absent counts as a
    # human rather than being dropped.
    src = d.get("source")
    if src in (None, "", "user"):
        state, reason = "working", ""
    else:
        sys.exit(0)

elif event in ("SessionStart", "SubagentStart"):
    state, reason = "working", ""

elif event == "SessionEnd":
    p = os.path.join(os.environ["STATE_DIR"], sid)
    try: os.unlink(p)
    except OSError: pass
    sys.exit(0)

else:
    sys.exit(0)

path = os.path.join(os.environ["STATE_DIR"], sid)

# SINCE must survive a repeat of the same state, or "waiting 12m" resets to
# zero every time an unrelated event re-asserts the same condition.
since = int(time.time())
try:
    with open(path) as f:
        prev = dict(
            l.rstrip("\n").split("=", 1)
            for l in f if "=" in l
        )
    if prev.get("STATE") == state and prev.get("REASON", "") == reason:
        since = int(prev.get("SINCE") or since)
except Exception:
    pass

cwd = d.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or ""
tmp = path + ".tmp"
with open(tmp, "w") as f:
    f.write(f"SID={sid}\n")
    f.write(f"STATE={state}\n")
    f.write(f"REASON={reason}\n")
    f.write(f"SINCE={since}\n")
    f.write(f"CWD={cwd}\n")
    f.write(f"UPDATED={int(time.time())}\n")
os.replace(tmp, path)   # atomic: a board reading mid-write must never see half a record
PY

STATE_DIR="$STATE_DIR" python3 -c "$PARSE" 2>/dev/null

# Cheap opportunistic sweep, at most once a minute, so dead sessions do not
# accumulate on a machine that is never restarted.
MARK="$STATE_DIR/.lastgc"
NOW=$(date +%s)
LAST=$(cat "$MARK" 2>/dev/null || echo 0)
if [ $(( NOW - LAST )) -gt 60 ]; then
  echo "$NOW" > "$MARK" 2>/dev/null
  "$0" gc >/dev/null 2>&1 &
fi
exit 0
