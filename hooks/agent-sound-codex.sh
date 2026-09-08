#!/bin/bash
# Codex Stop-hook wrapper.
#
# Claude Code has an exact "the plan is ready" signal: it calls the
# ExitPlanMode tool, so a PreToolUse hook on that tool name is unambiguous.
# Codex has no equivalent. Its only plan related tool is `update_plan`, which is
# a running TODO tracker that fires many times per task, so matching on it would
# fire the plan hit constantly. In Codex, finishing a plan simply ends the turn,
# which is the same Stop hook that a normal answer produces.
#
# So this reads the Stop payload on stdin and picks the event from it: if the
# turn ended while Plan mode was active, play the plan hit, otherwise play done.
# When the payload carries no mode information the fallback is `done`, which is
# the safe direction to be wrong in.
#
# Set AGENT_SOUND_LOG_PAYLOAD=1 to dump payloads to $TMPDIR/agent-sound/codex
# payload.log, which is how to refine the match if Codex changes the shape.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${TMPDIR:-/tmp}/agent-sound"
mkdir -p "$STATE" 2>/dev/null

PAYLOAD=""
if [ ! -t 0 ]; then
  PAYLOAD="$(cat 2>/dev/null)"
fi

if [ -n "$AGENT_SOUND_LOG_PAYLOAD" ]; then
  printf '%s\n---\n' "$PAYLOAD" >> "$STATE/codex-payload.log" 2>/dev/null
fi

EVENT=done
case "$PAYLOAD" in
  *'"plan_mode":true'*|*'"plan_mode": true'*|\
  *'"mode":"plan"'*|*'"mode": "plan"'*|\
  *'"permission_profile":"plan"'*|*'"permission_profile": "plan"'*|\
  *'"approval_mode":"plan"'*|*'"approval_mode": "plan"'*)
    EVENT=plan
    ;;
esac

exec "$DIR/agent-sound.sh" "$EVENT" codex
