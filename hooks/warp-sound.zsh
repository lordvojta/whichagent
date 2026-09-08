# Warp notification hits.
#
# Warp is the one agent here with no hook API: its CLI takes no hook flags and
# its settings.toml only has on/off notification preferences with no custom
# sound path. So the only available seam is the CLI's exit. Source this from
# ~/.zshrc to get a hit when a `warp` agent session ends.
#
#   source ~/.claude/hooks/warp-sound.zsh
#
# Turn Warp's own sound off in Settings > Notifications (play_notification_sound)
# if you do not want both.
warp() {
  command warp "$@"
  local rc=$?
  "$HOME/.claude/hooks/agent-sound.sh" done warp >/dev/null 2>&1 || true
  return $rc
}
