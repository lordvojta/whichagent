#!/bin/bash
# Claude Code Notification-hook wrapper.
#
# Notification fires for around fourteen different things, most of which are not
# you being blocked: auth_success, agent_completed, push_notification and so on.
# Chiming "needs your input" on all of them trains you to ignore the one that
# matters.
#
# settings.json also carries a matcher for this, listing the blocking types. I
# could not confirm from the shipped binary (a minified bundle) whether
# Notification honours matchers the way tool events do. So this decides from the
# payload as well, and correctness no longer depends on that question: if the
# matcher works, this agrees with it; if it does not, this filters anyway.
#
# FAIL OPEN, deliberately. If the payload carries no recognisable type at all,
# which is what a schema change would look like, the chime fires. An extra chime
# is a small annoyance; a silently swallowed permission prompt is the failure
# that costs you an hour of not noticing a stuck session.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PAYLOAD=""
[ ! -t 0 ] && PAYLOAD="$(cat 2>/dev/null)"

if [ -n "$AGENT_SOUND_LOG_PAYLOAD" ]; then
  STATE="${TMPDIR:-/tmp}/agent-sound"
  mkdir -p "$STATE" 2>/dev/null
  printf '%s\n---\n' "$PAYLOAD" >> "$STATE/notification-payload.log" 2>/dev/null
fi

# These are the ones that mean a human has to do something.
case "$PAYLOAD" in
  *permission_prompt*|*idle_prompt*|*elicitation_dialog*|*elicitation_url_dialog*)
    exec "$DIR/agent-sound.sh" input claude
    ;;
esac

# A recognised non-blocking type: stay quiet.
case "$PAYLOAD" in
  *auth_success*|*agent_completed*|*push_notification*|*agent_needs_input*|\
  *auth_failure*|*session_started*|*tool_denied*|*mcp_*)
    exit 0
    ;;
esac

# Nothing recognisable. Fail open.
exec "$DIR/agent-sound.sh" input claude
