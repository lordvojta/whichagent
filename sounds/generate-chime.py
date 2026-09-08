#!/usr/bin/env python3
"""Generate pleasant notification chimes for coding-agent lifecycle events.

This replaces the drill hits. Those were built to punch through music, which
made them percussive and a bit aggressive for something you hear fifty times a
day. These are tonal instead: short melodic figures on tuned, bell-like voices,
mixed to sit politely rather than to cut.

The two axes are unchanged, so one sound still says two things:

  provider -> timbre. Each agent gets a different instrument and a different
              home note, an octave apart at the extremes.
  event    -> melodic contour, which is what you actually recognise:
                done   two notes falling to the tonic. Resolved, finished.
                plan   three notes rising, ending unresolved. Over to you.
                input  the same note twice. A polite knock, not an alarm.

What makes them nice rather than harsh:

  - Additive synthesis with per-partial decay. Upper partials die away faster
    than the fundamental, which is what real struck bars and bells do and is
    most of why a synthesised bell sounds cheap when you skip it.
  - Just intonation. Intervals are exact small-integer ratios, so the partials
    line up instead of beating against each other.
  - A soft attack of a few ms, not the sub-1 ms click the drill hits needed.
  - A short dark reverb tail, low in the mix, so the sound ends in air rather
    than stopping dead.
  - Rolled off above 9 kHz and normalised well below full scale.

Run: python3 generate-chime.py
"""

import numpy as np
import wave
from pathlib import Path

SR = 44100
OUT = Path(__file__).resolve().parent

# Just intonation, so partials reinforce instead of beating.
UNISON, MAJ2, MAJ3, P4, P5, MAJ6, OCT = 1.0, 9 / 8, 5 / 4, 4 / 3, 3 / 2, 5 / 3, 2.0


def _t(n):
    return np.arange(n) / SR


def shape(sig, lo=None, hi=None):
    spec = np.fft.rfft(sig)
    freqs = np.fft.rfftfreq(len(sig), 1 / SR)
    mask = np.ones_like(freqs)
    if lo:
        mask *= 1 / (1 + (lo / np.maximum(freqs, 1)) ** 4)
    if hi:
        mask *= 1 / (1 + (np.maximum(freqs, 1) / hi) ** 4)
    return np.fft.irfft(spec * mask, n=len(sig))


def fftconv(a, b, n_out):
    size = 1 << int(np.ceil(np.log2(len(a) + len(b))))
    return np.fft.irfft(np.fft.rfft(a, size) * np.fft.rfft(b, size), size)[:n_out]


def voice_additive(freq, dur, partials, attack=0.004, seed=0):
    """Struck-bar and bell voices.

    `partials` is a list of (ratio, amplitude, decay_seconds). Giving each
    partial its own decay is the whole trick: the bright content should fade
    first, leaving a clean fundamental ringing underneath.
    """
    n = int(SR * dur)
    x = _t(n)
    atk = np.clip(x / max(attack, 1e-6), 0, 1)
    atk = atk * atk * (3 - 2 * atk)          # smoothstep, no click on entry
    sig = np.zeros(n)
    rng = np.random.default_rng(seed)
    for ratio, amp, decay in partials:
        # A hair of detune per partial stops it sounding like a pure oscillator.
        f = freq * ratio * (1 + rng.normal(0, 0.0006))
        sig += np.sin(2 * np.pi * f * x) * amp * np.exp(-x / decay)
    return sig * atk


def voice_fm(freq, dur, ratio=1.0, index=2.4, decay=0.55, attack=0.004):
    """Rhodes-ish electric piano. Rounder and softer than an additive bell."""
    n = int(SR * dur)
    x = _t(n)
    atk = np.clip(x / max(attack, 1e-6), 0, 1)
    atk = atk * atk * (3 - 2 * atk)
    # The modulator decays faster than the carrier, so it starts sweet and
    # settles to something close to a sine.
    mod = np.sin(2 * np.pi * freq * ratio * x) * index * np.exp(-x / (decay * 0.30))
    return np.sin(2 * np.pi * freq * x + mod) * np.exp(-x / decay) * atk


# Per-partial (ratio, amplitude, decay). Ratios are what give each its identity.
TIMBRES = {
    # Marimba: the first overtone of a tuned bar sits two octaves and a third up.
    "marimba": lambda f, d: voice_additive(f, d, [
        (1.0, 1.00, 0.42), (4.0, 0.30, 0.13), (9.2, 0.10, 0.06), (2.0, 0.12, 0.20),
    ], attack=0.003),
    # Glass: near harmonic, long and clean.
    "glass": lambda f, d: voice_additive(f, d, [
        (1.0, 1.00, 0.55), (2.0, 0.42, 0.34), (3.01, 0.20, 0.20), (4.2, 0.09, 0.12),
    ], attack=0.006),
    # Music box: bright, twinkly, short.
    "musicbox": lambda f, d: voice_additive(f, d, [
        (1.0, 1.00, 0.34), (2.0, 0.34, 0.19), (3.0, 0.18, 0.11),
        (4.15, 0.10, 0.09), (6.3, 0.05, 0.05),
    ], attack=0.002),
    # Electric piano.
    "epiano": lambda f, d: voice_fm(f, d, ratio=1.0, index=2.2, decay=0.40),
    # Soft bell, the neutral default.
    "softbell": lambda f, d: voice_additive(f, d, [
        (1.0, 1.00, 0.50), (2.0, 0.30, 0.28), (2.76, 0.16, 0.17), (5.4, 0.06, 0.08),
    ], attack=0.005),
}

VOICES = {
    "claude":   dict(timbre="marimba",  root=523.25),   # C5, warm and friendly
    "codex":    dict(timbre="glass",    root=392.00),   # G4, lower and calmer
    "opencode": dict(timbre="musicbox", root=659.25),   # E5, light and high
    "warp":     dict(timbre="epiano",   root=440.00),   # A4, round
    "default":  dict(timbre="softbell", root=587.33),   # D5
}

# (interval, start time in seconds, gain). Contour is what you recognise.
PATTERNS = {
    # Falling fifth onto the tonic. Reads as settled and complete.
    "done":  [(P5, 0.000, 0.85), (UNISON, 0.150, 1.00)],
    # Rising, ending on the sixth so it never resolves. Reads as a question.
    "plan":  [(UNISON, 0.000, 0.80), (MAJ3, 0.120, 0.88), (MAJ6, 0.240, 1.00)],
    # The same note twice. A knock, deliberately not a melody.
    "input": [(P5, 0.000, 0.95), (P5, 0.130, 0.85)],
}

NOTE_LEN = {"done": 0.58, "plan": 0.58, "input": 0.46}


def reverb(sig, rt=0.28, mix=0.14, seed=7):
    """A short dark tail so the chime ends in air instead of stopping dead."""
    n = len(sig)
    L = int(SR * rt)
    rng = np.random.default_rng(seed)
    ir = rng.standard_normal(L) * np.exp(-np.arange(L) / (SR * rt / 4.5))
    ir = shape(ir, hi=5200)                  # dark tail, never fizzy
    ir /= np.max(np.abs(ir)) + 1e-9
    wet = fftconv(sig, ir, n + L)
    dry = np.zeros(n + L)
    dry[:n] = sig
    return dry * (1 - mix) + wet * mix


def finish(sig, peak=0.72, floor_db=-50, fade_ms=22):
    """Normalise gently, trim the dead tail, fade out cleanly.

    Peak is deliberately well below full scale: a notification should not be
    the loudest thing your machine does.
    """
    sig = shape(sig, hi=9000)                # take the glare off the top
    m = np.max(np.abs(sig))
    if m > 0:
        sig = sig / m * peak
    thresh = peak * (10 ** (floor_db / 20))
    loud = np.where(np.abs(sig) > thresh)[0]
    if len(loud):
        sig = sig[: loud[-1] + 1]
    fade = int(SR * fade_ms / 1000)
    if 0 < fade < len(sig):
        sig[-fade:] *= np.linspace(1, 0, fade) ** 0.5
    return sig


def place(buf, sig, at_s, gain=1.0):
    i = int(SR * at_s)
    end = min(len(buf), i + len(sig))
    if end > i:
        buf[i:end] += sig[: end - i] * gain


def build(voice, event):
    make = TIMBRES[voice["timbre"]]
    notes = PATTERNS[event]
    length = NOTE_LEN[event]
    total = int(SR * (notes[-1][1] + length + 0.05))
    buf = np.zeros(total)
    for interval, at, gain in notes:
        place(buf, make(voice["root"] * interval, length), at, gain)
    return finish(reverb(buf))


def write(name, sig):
    data = (np.clip(sig, -1, 1) * 32767).astype("<i2")
    with wave.open(str(OUT / name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())
    print(f"  {name:<24} {len(sig) / SR:.2f}s")
    return sig


def main():
    made = []
    for provider, voice in VOICES.items():
        print(f"{provider} ({voice['timbre']}, {voice['root']:.0f} Hz)")
        for event in PATTERNS:
            made.append((f"{provider} {event}",
                         write(f"{provider}-{event}.wav", build(voice, event))))

    gap = np.zeros(int(SR * 0.55))
    write("preview-all.wav",
          np.concatenate([np.concatenate([s, gap]) for _, s in made]))


if __name__ == "__main__":
    main()
