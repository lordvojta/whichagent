#!/bin/bash
# Install a stock macOS sound as the agent notification sound.
#
#   use-system-sound.sh            use the sound configured in System Settings
#   use-system-sound.sh Ping       use a named sound from /System/Library/Sounds
#   use-system-sound.sh --list     show what is available
#   use-system-sound.sh --restore  put the previous custom sounds back
#
# Why this exists: the event router resolves <provider>-<event>.wav before
# default-<event>.wav, and hitplay only preloads files ending in .wav, so the
# stock .aiff files cannot just be pointed at. This converts the chosen sound
# and installs it as the single default-*.wav set, removing the per provider
# overrides so there is one place that decides what you hear.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYS=/System/Library/Sounds
BACKUP="$DIR/custom-backup"
EVENTS="done plan input"
PROVIDERS="claude codex opencode warp default"

if [ "${1:-}" = "--list" ]; then
  echo "Stock macOS sounds:"
  for f in "$SYS"/*.aiff; do echo "  $(basename "$f" .aiff)"; done
  echo
  echo "Currently configured system alert sound:"
  echo "  $(defaults read -g com.apple.sound.beep.sound 2>/dev/null || echo '(system default)')"
  exit 0
fi

if [ "${1:-}" = "--restore" ]; then
  if [ ! -d "$BACKUP" ]; then
    echo "No backup at $BACKUP" >&2
    exit 1
  fi
  cp "$BACKUP"/*.wav "$DIR"/ 2>/dev/null
  echo "Restored the custom sounds from $BACKUP"
  "$DIR/hitplay" --stop >/dev/null 2>&1
  exit 0
fi

# Resolve which stock sound to use.
if [ -n "${1:-}" ]; then
  SRC="$SYS/$1.aiff"
else
  SRC="$(defaults read -g com.apple.sound.beep.sound 2>/dev/null)"
  case "$SRC" in
    /*) : ;;
    '') SRC="$SYS/Ping.aiff" ;;
    *)  SRC="$SYS/$SRC.aiff" ;;
  esac
fi

if [ ! -f "$SRC" ]; then
  echo "No such sound: $SRC" >&2
  echo "Run with --list to see the options." >&2
  exit 1
fi

command -v afconvert >/dev/null 2>&1 || { echo "afconvert missing" >&2; exit 1; }

# Back up the custom sounds once, so --restore stays meaningful even if this
# script is run repeatedly.
if [ ! -d "$BACKUP" ]; then
  mkdir -p "$BACKUP"
  for p in $PROVIDERS; do
    for e in $EVENTS; do
      [ -f "$DIR/$p-$e.wav" ] && cp "$DIR/$p-$e.wav" "$BACKUP/" 2>/dev/null
    done
  done
  echo "Backed up the previous sounds to $BACKUP"
fi

# Convert once into the format hitplay and afplay both want.
TMP="$(mktemp -t agentsound).wav"
afconvert -f WAVE -d LEI16@44100 -c 1 "$SRC" "$TMP" >/dev/null 2>&1 || {
  echo "Conversion failed for $SRC" >&2; exit 1; }

# Stock sounds are padded with trailing silence: Pop is a 1.63s file holding
# 0.21s of actual sound, Tink is 0.56s holding 0.04s. Perceptually that padding
# is free, but the player holds the audio device open for the full length, so
# trimming it keeps a "pop" from occupying a second of nothing.
trim_tail() {
  python3 - "$1" <<'PYEOF' 2>/dev/null || return 1
import sys, wave, numpy as np
path = sys.argv[1]
with wave.open(path) as w:
    sr, n, ch, sw = w.getframerate(), w.getnframes(), w.getnchannels(), w.getsampwidth()
    d = np.frombuffer(w.readframes(n), dtype="<i2")
env = np.abs(d.astype(float))
win = max(1, int(sr * 0.005))
env = np.convolve(env, np.ones(win) / win, "same")
peak = env.max()
if peak <= 0:
    sys.exit(1)
loud = np.where(env > peak * 0.01)[0]
if len(loud) == 0:
    sys.exit(1)
end = min(len(d), loud[-1] + int(sr * 0.02))   # keep 20ms so the tail is not clipped
out = d[: end].astype(float)

# Stock sounds sit at wildly different levels: Pop peaks at 0.28 of full scale
# where Tink peaks near 1.0. Left alone, switching tone silently changes how
# audible the notification is over music. Normalising to a fixed peak makes the
# choice about character only, not volume.
peak_now = np.abs(out).max()
if peak_now > 0:
    out = out * (0.90 * 32767 / peak_now)
out = np.clip(out, -32768, 32767).astype("<i2")
fade = min(int(sr * 0.005), len(out))          # 5ms fade so it ends without a click
if fade > 1:
    out[-fade:] = (out[-fade:].astype(float) * np.linspace(1, 0, fade)).astype("<i2")
with wave.open(path, "wb") as w:
    w.setnchannels(ch); w.setsampwidth(sw); w.setframerate(sr)
    w.writeframes(out.tobytes())
PYEOF
}

trim_tail "$TMP" || echo "(trim skipped, using the padded file)"

for e in $EVENTS; do
  cp "$TMP" "$DIR/default-$e.wav"
done
rm -f "$TMP"

# Drop the per provider files so default-*.wav is what every agent resolves to.
for p in claude codex opencode warp; do
  for e in $EVENTS; do
    rm -f "$DIR/$p-$e.wav"
  done
done

# The daemon preloads every wav at startup, so it has to be restarted to pick
# up new file contents. The next event starts a fresh one automatically.
"$DIR/hitplay" --stop >/dev/null 2>&1

echo "Now using: $(basename "$SRC" .aiff)  ($SRC)"
afinfo "$DIR/default-done.wav" 2>/dev/null | awk -F': *' '/duration/{printf "Duration:  %.2fs\n",$2}'
