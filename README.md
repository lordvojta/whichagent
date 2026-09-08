# whichagent

![macOS only](https://img.shields.io/badge/platform-macOS%20only-000000?logo=apple&logoColor=white)
![License MIT](https://img.shields.io/badge/license-MIT-blue)
![Claude Code · Codex · opencode · Warp](https://img.shields.io/badge/agents-Claude%20Code%20%C2%B7%20Codex%20%C2%B7%20opencode%20%C2%B7%20Warp-6c47ff)

**Which agent wants me, what does it want, and take me back to it.**

Sound and desktop notifications for Claude Code, Codex, opencode and Warp. Plus the
part nobody else does: one keystroke returns you to the *exact terminal session* that
asked, including the right integrated terminal inside VS Code.

Every tool in this space plays you a sound. Once you run more than a couple of agents
at once, the question you actually have is *which one*, and then *where was it?*

> **macOS only, and not portable in principle.** The audio engine is AVAudioEngine, the
> banner is an AppKit window, and focus goes through AppleScript. There is no Linux or
> Windows path and none is planned. If you are not on a Mac, this is not for you.

## Install

Needs the Xcode Command Line Tools (`xcode-select --install`). Nothing else.

```sh
git clone https://github.com/lordvojta/whichagent
cd whichagent
make
./install.sh
```

`install.sh` merges into your existing `~/.claude/settings.json` and backs it up first.
It never touches hooks it did not add. `./install.sh --dry-run` shows you what it would
do; `--uninstall` removes only its own entries.

You compile the four helpers yourself, so macOS never asks you to trust an unsigned
binary from the internet.

## What you get

**A sound that means something.** Timbre tells you the provider, melody tells you the
event. A finished turn, a plan waiting for review and a blocked prompt are three
different phrases, so you can keep typing and still know what happened.

**A banner that says which project.** Bottom-right stack, each with the project's own
icon, name, branch and path, a coloured ring per repo, and a badge for the event:
green check finished, blue clipboard plan ready, orange question mark needs you.

**A board of who is waiting.** A menu bar item showing how many agents are
blocked on you, and a list you can jump from. It counts only sessions that
block progress, never the idle ones, so the number stays worth reading.

```
  3 need you   21 sessions

   1 ● acme-shop  needs permission  12m
   2 ● acme-web   plan ready         3m
   3 ● acme-api   waiting on you     1m
   4 ○ acme-site  finished          20m
   5 ▸ acme-3d    working
```

Same thing in the terminal with `whichagent`, `whichagent watch` to leave it
running in a split, and `whichagent focus 2` to jump.

Past five minutes the badge shows the age of the most neglected one, so `2 · 14m`
reads differently from `2`.

**A key that takes you back.**

| | |
|---|---|
| `⌘⌃↩` | jump to the session that asked |
| `⌘⌃1`…`5` | jump to a specific banner |
| `⌘⌃⌫` | dismiss all banners |
| `⌘⌃W` | open the board from the menu bar |

## Configure

Optional. Defaults are the intended experience. Edit `~/.claude/agent-sound.conf`.

| | default | |
|---|---|---|
| `AGENT_HUD_WIDTH` / `_HEIGHT` | `360` / `64` | banner size |
| `AGENT_HUD_SCALE` | `1.0` | scales box **and text** together |
| `AGENT_HUD_ANCHOR_BOTTOM` | `1` | `0` puts the stack top-right |
| `AGENT_HUD_HINTS` | `1` | keybind hint line |
| `AGENT_HUD_INDEX` | `1` | number the banners when several are up |
| `AGENT_FOCUS_DEFAULT` | `vscode` | where to go when a host is unknown |
| `AGENT_SOUND_PAUSE_MUSIC` | `0` | pause Spotify/Music while a cue plays |
| `AGENT_NOTIFY_DISABLE` | `0` | sound only, no banner |
| `AGENT_STATE_DIR` | `~/.claude/cache/agent-state` | where session state is kept |

To make banners smaller, reduce `AGENT_HUD_HEIGHT`. Do not reach for
`AGENT_HUD_SCALE`: font size derives from it, so it shrinks the text too.

## Try it

```sh
~/.claude/hooks/agent-demo.sh     # the walkthrough
~/.claude/hooks/soundcheck.sh     # every cue, labelled
~/.claude/hooks/notify-test.sh    # diagnose banner delivery
```

Test banners always carry a black-and-yellow TEST icon, so a demo can never be mistaken
for a real session.

## How it works

Two long-lived daemons rather than a process per event.

`hitplay` holds an `AVAudioEngine` open and is poked over a FIFO. `afplay` costs a fixed
~800ms of process startup every time it runs, so this took the hook from **1.1s to
0.02s**.

`agenthud` owns every banner window. Independent processes cannot lay out a shared
stack, so gaps and overlaps were unavoidable until one process owned the layout. The
banner is a self-drawn `NSPanel`, not a Notification Center notification, so it needs no
notification permission and never steals focus mid-keystroke.

**State is tracked, not just events.** Each session records whether it is
working or waiting, why, and since when. `Stop` means waiting: a finished turn
is a session that will not move until you say something. `UserPromptSubmit`
clears it, gated on `source == "user"` so a `/loop` wakeup or a scheduled fire
does not falsely count as you answering. `Notification` is filtered hard: it
carries 14 types and most, including `agent_completed` and `agent_needs_input`
(which reports on a *different* session), do not mean this one is blocked.

Liveness is decided in exactly one place, by a sweep keyed on the session's
tty. A session id appears in no process's arguments, so the obvious check
(`pgrep -f "$session_id"`) matches nothing and would mark every session dead.
The board and the menu bar both simply list what survives the sweep, so they
cannot disagree about what is running.

Focusing a specific VS Code terminal uses a join key that already existed on both sides:
VS Code exposes `Terminal.processId`, a pid resolves to a tty via `ps`, and the session
registry already records ttys. The bundled extension closes the loop. Claude Code's own
`vscode://` handler cannot do this, because it only reveals sessions in its panel map
and terminal sessions are never in it.

## Limits

- **macOS only.** See the note at the top: this is not portable in principle.
- **VS Code multi-window.** A `vscode://` URI reaches one window. If the session is in
  another, focus lands on the window, not the terminal.
- **Per-tab focus is Terminal.app only.** It is the only terminal exposing tab ttys over
  AppleScript. Warp and iTerm get window-level focus.
- **Notification Center is optional.** macOS persists a denied consent in
  `com.apple.ncprefs` where `tccutil` cannot clear it. The self-drawn banner exists so
  that does not matter.

## License

MIT.
