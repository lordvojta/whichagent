-- Global hotkeys for the coding-agent HUD banners.
--
-- These have to be global hotkeys. The HUD is an NSNonactivatingPanel so that
-- it never steals focus while you are mid-sentence, and a non-activating panel
-- cannot receive key events at all. Hammerspoon is already running, so it is
-- the natural home rather than a second background agent.
--
-- Return and Backspace are chosen for being physically large, easy targets and
-- mnemonic (enter = go there, delete = get rid of it). J and D on this modifier
-- pair were an awkward stretch.
--
-- Option/Alt is deliberately avoided: on British and Czech layouts Option is a
-- dead-key modifier and unusable as Meta. cmd+ctrl matches the pattern already
-- established by the other bindings in init.lua.

local FOCUS = os.getenv("HOME") .. "/.claude/hooks/agent-focus.sh"

-- cmd+ctrl+Return: jump to the banner nearest the eye, the bottom one.
--
-- This asks the DAEMON, not agent-focus.sh. The daemon is the only thing that
-- knows what is actually on screen. agent-focus.sh reads .last, which records
-- the last session to fire any hook: a warm SessionStart, or an event with
-- notifications suppressed, both move it without ever showing a banner. So the
-- old binding could send you to a session with nothing displayed while three
-- real banners sat there. The registry lookup stays as the fallback for when
-- no daemon is running, which is the case it was always right for.
local HUD = os.getenv("HOME") .. "/.claude/sounds/agenthud"

local function focusBanner(n)
  local args = n and { "--focus", tostring(n) } or { "--focus" }
  hs.task.new(HUD, function(rc)
    if rc ~= 0 and not n then
      hs.task.new("/bin/bash", nil, { FOCUS, "focus" }):start()
    end
  end, args):start()
end

hs.hotkey.bind({ "cmd", "ctrl" }, "return", function() focusBanner(nil) end)

-- cmd+ctrl+1..5: address a specific banner, counting from the bottom, matching
-- the numerals drawn on the stack. Without these only the newest is reachable
-- by keyboard and the rest need the mouse, which was the actual complaint.
--
-- Bound by PHYSICAL KEYCODE, not by character. Binding "1".."5" by name is
-- layout dependent: on his Czech layout the unshifted number row produces
-- + e s c r, so those bindings registered as cmd+ctrl+ě and friends and the
-- digits did nothing. Keycodes 18/19/20/21/23 are the number row positions
-- regardless of the active layout, which also keeps this working when he
-- switches between Czech and British.
local NUM_KEYCODES = { 18, 19, 20, 21, 23 }
for i, code in ipairs(NUM_KEYCODES) do
  hs.hotkey.bind({ "cmd", "ctrl" }, code, function() focusBanner(i) end)
end

-- cmd+ctrl+Backspace: dismiss every visible HUD.
--
-- SIGUSR1: agenthud traps it and runs the same fade the close
-- button uses, so a stack of banners animates out together instead of
-- vanishing. Up to five can be on screen at once, so this has to clear all of
-- them rather than just the newest.
hs.hotkey.bind({ "cmd", "ctrl" }, "delete", function()
  hs.task.new("/usr/bin/pkill", nil, { "-USR1", "-x", "agenthud" }):start()
end)
