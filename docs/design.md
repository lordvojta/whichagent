# Agent notification chimes

Short tonal chimes for coding-agent lifecycle events. Two axes, so one sound
under a second tells you two things at once:

- **Which agent**, from the instrument.
- **What happened**, from the melodic shape.

An earlier drill/trap set is kept in `sounds/drill/`. It was built to punch
through music, which made it percussive and tiring to hear fifty times a day.
Copy those files back over the ones in `sounds/` to return to it.

## The matrix

| | instrument | home note |
|---|---|---|
| claude | marimba | C5 523 Hz |
| codex | glass bell | G4 392 Hz |
| opencode | music box | E5 659 Hz |
| warp | electric piano | A4 440 Hz |
| default | soft bell | D5 587 Hz |

Events, which is the part you actually recognise:

- `done` (~0.98 s) two notes falling a fifth onto the tonic. Resolved.
- `plan` (~1.06 s) three notes rising, ending on the sixth so it never
  resolves. Reads as a question, which is what a plan awaiting review is.
- `input` (~0.85 s) the same note twice. A knock, deliberately not a melody.

What keeps them pleasant: additive synthesis with a separate decay per partial
(bright content fades first, as a real struck bar does), just intonation so
partials reinforce instead of beating, a few ms of soft attack, a short dark
reverb tail, everything above 9 kHz rolled off, and a peak of 0.72 rather than
full scale. Measured against the drill set, energy above 6 kHz fell from 29%
to under 1%.

Regenerate with `python3 sounds/generate-chime.py`, then restart the daemon
(`sounds/hitplay --stop`) because it caches decoded audio by path.

## Why it is fast

`afplay` costs a fixed ~800 ms per invocation on this machine no matter how
short the file is, because it cold starts CoreAudio each time. `ffplay` is
~350 ms. The old hook then added four to six `osascript` round trips to pause
Spotify before playing, so a hit landed roughly a second after the moment it was
reporting.

Now `hitplay` runs as a small daemon that keeps an `AVAudioEngine` open with
every wav preloaded. Firing a hit is one `printf` into a FIFO: about **0.2 ms**,
and the hook returns in 0.02 s. Music pausing is opt in and off by default,
because the hits are mixed to sit on top of music, not to replace it.

## Notification banners

The hit tells you an agent finished. The banner tells you *which repo* and
*which kind of finished*:

    title     acme-web
    subtitle  Claude Code: plan ready for review
    message   ~/code/acme-web (main)
    image     the project favicon or logo, else a generated identicon

Posted by `agent-notify.sh`, always fired in the background after the sound, so
it never adds latency to the hit (the hook still returns in 0.02 s).

`agent-icon.py` finds the artwork. It looks for the usual committed icons
(`public/apple-touch-icon.png`, `public/favicon.ico`, `src/app/icon.png`,
`build/icon.png`, and about twenty more), normalises whatever it finds to a
128 px png with `sips`, and caches it per repo keyed on the source mtime. A repo
with no artwork at all gets a deterministic identicon generated from a hash of
its path, so every project still has a distinct mark.

Two macOS limits worth knowing:

- **The app icon cannot be changed.** macOS removed that API, so the banner
  always shows the icon of whichever app posted it. Project artwork goes in
  `-contentImage`, the image on the right of the banner. `terminal-notifier`'s
  own `-appIcon` flag is documented as no longer supported for this reason.
- **Permission is per posting app** and is attributed to the responsible parent
  process. A helper launched from a restricted parent inherits that restriction
  and gets denied without a prompt. So delivery is attempted in three steps:
  `terminal-notifier` directly, then the same tool relaunched through
  LaunchServices so it becomes its own responsible process, then `osascript`
  (which posts under Script Editor and cannot carry an image).

### Banners did not work here, and why

On this machine no banner route delivers, including plain `osascript` through
Script Editor, which exits 0 and shows nothing. That rules out anything
app-specific and points at a system level block (a Focus mode, or the alert
style set to None). Check **System Settings > Notifications**.

Two corrections worth recording so nobody repeats them:

- **Notification consent is not in TCC.** `tccutil reset UserNotification <id>`
  does nothing useful; the suggestion comes from terminal-notifier's own error
  text and is wrong on macOS 26. Consent lives in `com.apple.ncprefs`, which is
  only reachable from a process with GUI attribution.
- **A process without that attribution cannot post, read or reset any of it.**
  A request from such a process is auto-denied and the denial sticks, which is
  what happened here on the first attempt.

`sounds/agentnotify.m` and `AgentNotify.app` are a complete, correct
implementation (UNUserNotificationCenter plus UNNotificationAttachment for the
project image). They are wired in and will work the moment consent is granted.

### Settings file

`~/.claude/agent-sound.conf` is read by `agent-notify.sh` for every provider,
because Codex hook commands must be a plain string and opencode spawns without
a shell, so per-provider env prefixes are fragile. Environment variables still
win over the file. Point `AGENT_SOUND_CONF` elsewhere, or at `/dev/null`, to
ignore it.

### Speech, the channel that always works

`AGENT_NOTIFY_SPEAK=1` says "<repo>, <what happened>" after the hit. It needs no
consent of any kind, so it is the reliable way to get the repo name across when
banners are blocked. It is on by default in `~/.claude/agent-sound.conf`. Comment out
`AGENT_NOTIFY_SPEAK=1` there to go back to the hit alone, or set
`AGENT_NOTIFY_VOICE` to pick a voice (`say -v '?'` lists them).

`warm` never speaks, so opening a session stays silent.

Disable banners and keep the sounds with `AGENT_NOTIFY_DISABLE=1` or
`AGENT_SOUND_NO_NOTIFY=1`.

## Files

    sounds/generate-drill.py   synthesis, edit here to change the sounds
    sounds/hitplay.m           low latency player, daemon plus one shot
    sounds/build.sh            rebuilds hitplay
    sounds/<provider>-<event>.wav
    sounds/preview-labelled.wav  spoken labels then each hit, for auditioning
    hooks/agent-sound.sh       the dispatcher every agent calls
    hooks/agent-sound-codex.sh Codex Stop wrapper, see below
    hooks/warp-sound.zsh       Warp shell wrapper, source from ~/.zshrc
    hooks/agent-notify.sh      posts the banner
    hooks/agent-icon.py        finds or generates the project image

Regenerate the sounds with `python3 sounds/generate-drill.py`, then
`sounds/hitplay --stop` so the daemon reloads them.

## Wiring, per provider

**Claude Code** (`~/.claude/settings.json`) is the only one with an exact
"plan is ready" signal, because presenting a plan is a tool call:

    Stop                        -> done
    PreToolUse / ExitPlanMode   -> plan
    Notification                -> input
    SessionStart                -> warm (opens the audio device early)

`PreToolUse` rather than `PostToolUse`, because PostToolUse fires only after you
have already approved the plan.

**Codex** (`~/.codex/config.toml`) uses the same event-keyed hook shape. Its only
plan related tool is `update_plan`, a running TODO tracker that fires many times
per task, so matching on it would fire the plan hit constantly. Finishing a plan
in Codex just ends the turn. `agent-sound-codex.sh` therefore reads the Stop
payload and picks `plan` when the turn ended in Plan mode, falling back to
`done`. Run with `AGENT_SOUND_LOG_PAYLOAD=1` to dump payloads and refine the
match. Codex asks you to trust new hooks the first time, so approve them in its
hooks screen.

**opencode** (`~/.config/opencode/plugin/agent-sound.js`) has no plan event
either, but `chat.message` carries the agent name and `plan` is a built in
agent. The plugin remembers the agent per session and picks the hit on
`session.idle`. `permission.ask` maps to `input`.

**Warp** has no hook surface: its CLI takes no hook flags and `~/.warp/settings.toml`
only has on/off notification preferences with no custom sound path. The only
seam is the CLI exiting, so `warp-sound.zsh` wraps the command. Source it from
`~/.zshrc`, and turn off `play_notification_sound` in Warp's settings if you do
not want both sounds.

## Adding a provider

Drop `sounds/<name>-done.wav` etc. into the sounds dir and call
`agent-sound.sh <event> <name>`. Nothing else needs to change: resolution falls
back through `<provider>-<event>`, `default-<event>`, `<provider>-done`,
`default-done`, so a new agent makes a sound before you have drawn it one.

To give it a real voice, add an entry to `VOICES` in `generate-drill.py` and
pick a `bass` engine from `BASSES`.

## Env

    AGENT_SOUND_MUTE=1              play nothing
    AGENT_SOUND_VOLUME=1            0.0 to 2.0
    AGENT_SOUND_PROVIDER=claude     override auto detection
    AGENT_SOUND_DIR                 where the wavs live
    AGENT_SOUND_NO_DAEMON=1         never start hitplay, always use afplay
    AGENT_SOUND_DAEMON_IDLE=3600    daemon releases the audio device after this
    AGENT_SOUND_SUPPRESS_WINDOW=6   seconds a `done` is swallowed after a plan
                                    or input hit, so ExitPlanMode followed
                                    immediately by Stop is one sound, not two
    AGENT_SOUND_PAUSE_MUSIC=1       pause Spotify/Music around the hit (slow)
    AGENT_SOUND_MIN_VOLUME=n        raise system volume first (slow)
    AGENT_SOUND_NO_NOTIFY=1         hit only, no banner
    AGENT_NOTIFY_DISABLE=1          same, honoured by agent-notify.sh itself
    AGENT_SOUND_<PROVIDER>_<EVENT>  explicit path for one combination
