# agentcue

Know which coding agent wants you, what it wants, and get back to it in one keystroke.

When you run more than a couple of agent sessions at once, "something finished" stops
being useful information. agentcue answers the two questions that actually matter:
**which project**, and **what happened** — with a sound you can identify without
looking, a banner you can read at a glance, and a shortcut that puts you back in the
exact terminal that asked.

macOS only. Claude Code, Codex, opencode and Warp.

## What it does

**Sound carries meaning.** Timbre identifies the provider, melodic contour identifies
the event. A finished turn, a plan waiting for review and a blocked prompt are three
different phrases, so you can keep typing and still know what happened.

**Banners answer "which one".** A stack in the corner of the screen, each carrying the
project's own icon, its name, branch and path, plus a badge for the event: a green
check for finished, a blue clipboard for a plan, an orange question mark for blocked.

**One keystroke goes back.** `⌘⌃↩` jumps to whichever session asked for you.
Numbered shortcuts reach the others. It resolves the actual terminal, including the
right integrated terminal inside VS Code, not just the right window.

## Install

Needs the Xcode Command Line Tools (`xcode-select --install`). Nothing else.

```sh
git clone https://github.com/YOUR-USER/agentcue
cd agentcue
make
./install.sh
```

`install.sh` merges its hooks into your existing `~/.claude/settings.json` rather than
replacing it, and backs the file up first.

Nothing is downloaded as a binary, deliberately: you compile the three native helpers
locally, so macOS never asks you to trust an unsigned executable from the internet.

## How it fits together

```
Claude Code hook ─→ hooks/agent-sound.sh ─┬─→ hitplay      (warm audio daemon)
                                          └─→ agent-notify.sh ─→ agenthud (banner daemon)

⌘⌃↩ ─→ Hammerspoon ─→ agenthud --focus ─→ the banner's own click command
                                          └─→ agent-focus.sh ─→ Terminal tab / Warp /
                                                                VS Code integrated terminal
```

**Two long-lived daemons, not per-event processes.** `afplay` costs a fixed ~800ms of
process startup on every invocation. Holding an `AVAudioEngine` open and poking it over
a FIFO took the hook from **1.1s to 0.02s**. The banner daemon exists for a different
reason: five independent processes cannot lay out a shared stack, so gaps and overlaps
were unavoidable until one process owned every window.

**The banner draws its own windows.** It is an `NSPanel`, not a Notification Center
notification, so it needs no notification permission, cannot be silenced by a stale
consent decision, and can be sized and styled freely. It is also non-activating, so it
never steals focus mid-keystroke.

**Focusing a VS Code terminal** works by a join key that already existed on both sides:
VS Code exposes `Terminal.processId`, a pid resolves to a tty via `ps`, and the session
registry already records each session's ttys. The bundled extension closes the loop.
The Claude Code extension's own `vscode://` handler cannot do this — it only reveals
sessions in its panel map, and terminal sessions are never in it.

## Configuration

Copy `agent-sound.conf.example` to `~/.claude/agent-sound.conf`. Everything is
optional; the defaults are the intended experience.

| Setting | Default | |
|---|---|---|
| `AGENT_HUD_WIDTH` / `AGENT_HUD_HEIGHT` | `360` / `64` | Banner size |
| `AGENT_HUD_SCALE` | `1.0` | Scales box *and* text together |
| `AGENT_HUD_ANCHOR_BOTTOM` | `1` | Bottom-right; `0` for top-right |
| `AGENT_HUD_HINTS` | `1` | Show the keybind hint line |
| `AGENT_HUD_INDEX` | `1` | Number the banners when several are up |
| `AGENT_FOCUS_DEFAULT` | `vscode` | Where to go when a session's host is unknown |
| `AGENT_SOUND_PAUSE_MUSIC` | `0` | Pause Spotify/Music while a cue plays |
| `AGENT_NOTIFY_DISABLE` | `0` | Sound only, no banner |

`AGENT_HUD_SCALE` is the knob people reach for to make banners smaller, and it is
usually the wrong one: font size derives from it, so shrinking the box shrinks the text
with it. For a smaller banner that stays readable, reduce `AGENT_HUD_HEIGHT` and leave
the scale alone.

## Try it without wiring anything up

```sh
hooks/agent-demo.sh          # the full walkthrough
hooks/soundcheck.sh          # every cue, labelled
hooks/notify-test.sh         # diagnose banner delivery
```

Test banners always carry a black-and-yellow **TEST** icon, so a demo can never be
mistaken for a real session.

## Known limits

- **macOS only.** `AVAudioEngine`, AppKit and AppleScript throughout.
- **VS Code multi-window.** A `vscode://` URI reaches one window. If the session's
  terminal is in a different one, focus lands on the window, not the terminal.
- **Notification Center is optional and often blocked.** macOS persists a denied
  notification consent in `com.apple.ncprefs`, where `tccutil` cannot clear it. The
  self-drawn banner exists precisely so this does not matter.
- **Per-tab focus only works in Terminal.app.** It is the only terminal exposing tab
  ttys over AppleScript. Warp and iTerm get window-level focus.

## License

MIT.
