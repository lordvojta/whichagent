#!/usr/bin/env python3
"""Generate short percussive notification hits for the Claude Code Stop hook.

Design goals:
  - Short: under half a second, so it reads as a hit and not a song.
  - Pointy: a hard transient plus energy in the 2-5 kHz band, which is where a
    click stays audible over music without needing to be loud.
  - Beat like: a fast pitch-swept low body, so it lands like a drum hit rather
    than a drone.

Run: python3 generate-hits.py
"""

import numpy as np
import wave
from pathlib import Path

SR = 44100
OUT = Path(__file__).resolve().parent


def t(n_samples):
    return np.arange(n_samples) / SR


def env_exp(n, decay, attack=0.0008):
    """Percussive envelope: near instant attack, exponential decay."""
    x = t(n)
    a = np.clip(x / max(attack, 1e-6), 0, 1)
    return a * np.exp(-x / decay)


def noise_burst(n, decay, lo=None, hi=None, seed=0):
    rng = np.random.default_rng(seed)
    sig = rng.standard_normal(n)
    if lo or hi:
        sig = bandpass(sig, lo, hi)
    return sig * env_exp(n, decay)


def bandpass(sig, lo, hi):
    """Cheap FFT band shaping, good enough for one shot percussion."""
    spec = np.fft.rfft(sig)
    freqs = np.fft.rfftfreq(len(sig), 1 / SR)
    mask = np.ones_like(freqs)
    if lo:
        mask *= 1 / (1 + (lo / np.maximum(freqs, 1)) ** 4)
    if hi:
        mask *= 1 / (1 + (np.maximum(freqs, 1) / hi) ** 4)
    return np.fft.irfft(spec * mask, n=len(sig))


def sweep(n, f_start, f_end, decay, curve=3.0):
    """Pitch swept sine, exponential glide down. This is the 'beat'."""
    x = t(n)
    k = np.exp(-x * curve / max(x[-1], 1e-6))
    freq = f_end + (f_start - f_end) * k
    phase = 2 * np.pi * np.cumsum(freq) / SR
    return np.sin(phase) * env_exp(n, decay)


def tone(n, freq, decay, wave_shape="sine"):
    x = t(n)
    phase = 2 * np.pi * freq * x
    if wave_shape == "tri":
        sig = 2 / np.pi * np.arcsin(np.sin(phase))
    else:
        sig = np.sin(phase)
    return sig * env_exp(n, decay)


def finish(sig, peak=0.89, fade_ms=8):
    """Soft clip, normalize, and fade the tail so it ends without a click."""
    sig = np.tanh(sig * 1.15)
    m = np.max(np.abs(sig))
    if m > 0:
        sig = sig / m * peak
    fade = int(SR * fade_ms / 1000)
    if fade > 0 and fade < len(sig):
        sig[-fade:] *= np.linspace(1, 0, fade)
    return sig


def write(name, sig):
    data = (np.clip(sig, -1, 1) * 32767).astype("<i2")
    path = OUT / name
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())
    print(f"{name}: {len(sig) / SR:.3f}s")


def place(buf, sig, at_ms):
    i = int(SR * at_ms / 1000)
    end = min(len(buf), i + len(sig))
    buf[i:end] += sig[: end - i]


def hit(seed=1, body_from=210, body_to=58, ping=2100, bright=1.0):
    """One percussive hit: click transient, metallic ping, swept body."""
    n = int(SR * 0.30)
    buf = np.zeros(n)
    # Transient. Short and wide, this is what makes it pointy.
    buf += noise_burst(n, 0.0032, lo=1400, hi=9000, seed=seed) * 0.85 * bright
    # Metallic ping with a detuned partial for edge, sits in the cut through band.
    buf += tone(n, ping, 0.030, "tri") * 0.34 * bright
    buf += tone(n, ping * 1.48, 0.018, "tri") * 0.20 * bright
    # Swept body. The part that lands on the beat.
    buf += sweep(n, body_from, body_to, 0.075) * 0.95
    # Dark tail, quiet, keeps a trace of the old character without adding length.
    buf += noise_burst(n, 0.055, lo=120, hi=900, seed=seed + 7) * 0.10
    return buf


# 1. Default: single sharp hit.
sig = hit(seed=1)
write("hit-tick.wav", finish(sig))

# 2. Two fast ticks, more explicitly rhythmic.
n = int(SR * 0.42)
buf = np.zeros(n)
place(buf, hit(seed=2, ping=2400) * 0.80, 0)
place(buf, hit(seed=5, body_from=250, ping=2900), 105)
write("hit-double.wav", finish(buf))

# 3. Woodier, deeper knock, still pointy but less bright.
sig = hit(seed=9, body_from=170, body_to=48, ping=1450, bright=0.72)
write("hit-knock.wav", finish(sig))
