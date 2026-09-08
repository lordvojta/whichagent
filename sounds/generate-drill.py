#!/usr/bin/env python3
"""Generate drill/trap notification hits for coding-agent lifecycle events.

Two independent axes, so one short sound tells you two things at once:

  provider -> timbre.  The 808 root note, the hat character and the amount of
              saturation change per agent, so you hear *which* agent it was
              without looking: claude, codex, opencode, warp, default.

  event    -> rhythm.  The pattern changes per lifecycle event, so you hear
              *what* happened: done (turn finished), plan (a plan is ready for
              review), input (the agent is blocked on you).

Design rules, all aimed at "it hits the beat":

  - Everything sits on a 140 BPM grid. A 16th is 107 ms, a 32nd is 53 ms.
    Patterns are placed on that grid so they read as drum programming rather
    than as UI beeps.
  - Sample 0 is the transient. No lead-in silence, attacks under 2 ms.
  - The 808 is hard saturated. A laptop speaker cannot reproduce 45 Hz, so the
    punch has to come from the harmonics that saturation generates. Without
    this the sub is felt on headphones and simply missing everywhere else.
  - Tails are trimmed at -60 dB, so a file is exactly as long as it sounds.

Run: python3 generate-drill.py
"""

import numpy as np
import wave
from pathlib import Path

SR = 44100
BPM = 140.0
STEP = 60.0 / BPM / 4          # one 16th note, 107 ms
OUT = Path(__file__).resolve().parent


# ---------------------------------------------------------------- primitives

def _t(n):
    return np.arange(n) / SR


def env(n, decay, attack=0.0006):
    """Percussive envelope: near instant attack, exponential decay."""
    x = _t(n)
    a = np.clip(x / max(attack, 1e-9), 0, 1)
    return a * np.exp(-x / decay)


def shape(sig, lo=None, hi=None):
    """Cheap FFT band shaping. Good enough for one shots."""
    spec = np.fft.rfft(sig)
    freqs = np.fft.rfftfreq(len(sig), 1 / SR)
    mask = np.ones_like(freqs)
    if lo:
        mask *= 1 / (1 + (lo / np.maximum(freqs, 1)) ** 4)
    if hi:
        mask *= 1 / (1 + (np.maximum(freqs, 1) / hi) ** 4)
    return np.fft.irfft(spec * mask, n=len(sig))


def noise(n, decay, lo=None, hi=None, seed=0, attack=0.0003):
    rng = np.random.default_rng(seed)
    sig = rng.standard_normal(n)
    if lo or hi:
        sig = shape(sig, lo, hi)
    return sig * env(n, decay, attack)


def fftconv(a, b, n_out):
    size = 1 << int(np.ceil(np.log2(len(a) + len(b))))
    out = np.fft.irfft(np.fft.rfft(a, size) * np.fft.rfft(b, size), size)
    return out[:n_out]


# -------------------------------------------------------------------- voices

def eight08(dur, f_hi, f_lo, glide=0.026, decay=0.16, drive=3.2):
    """Trap 808: pitch drops hard into the root, saturated for small speakers.

    f_hi is the pitch the attack starts from. The fast drop to f_lo is what
    makes it read as a kick rather than as a bass note.
    """
    n = int(SR * dur)
    x = _t(n)
    freq = f_lo + (f_hi - f_lo) * np.exp(-x / glide)
    phase = 2 * np.pi * np.cumsum(freq) / SR
    body = np.tanh(np.sin(phase) * drive) / np.tanh(drive)
    return body * env(n, decay, attack=0.0008)


def eight08_slide(dur, f_hi, f1, f2, slide_at, slide_time=0.085,
                  glide=0.026, decay=0.20, drive=3.2):
    """The drill signature: the 808 lands on one note, then glides to another.

    slide_at is when the glide starts, in seconds from the attack.
    """
    n = int(SR * dur)
    x = _t(n)
    freq = f1 + (f_hi - f1) * np.exp(-x / glide)
    ramp = np.clip((x - slide_at) / slide_time, 0, 1)
    ramp = ramp * ramp * (3 - 2 * ramp)          # smoothstep, no corner
    freq = freq + (f2 - f1) * ramp
    phase = 2 * np.pi * np.cumsum(freq) / SR
    body = np.tanh(np.sin(phase) * drive) / np.tanh(drive)
    return body * env(n, decay, attack=0.0008)


HAT_RATIOS = [2.0, 3.0, 4.16, 5.43, 6.79, 8.21]   # classic 808 metallic set


def hat(dur=0.05, decay=0.011, base=44.0, hp=7600, seed=0, noise_mix=0.35):
    n = int(SR * dur)
    x = _t(n)
    sig = np.zeros(n)
    for r in HAT_RATIOS:
        sig += np.sign(np.sin(2 * np.pi * base * r * x))
    sig /= len(HAT_RATIOS)
    rng = np.random.default_rng(seed)
    sig = (1 - noise_mix) * sig + noise_mix * rng.standard_normal(n)
    sig = shape(sig, lo=hp)
    return sig * env(n, decay, attack=0.00025)


def snare(dur=0.20, decay=0.052, tone=190.0, bright=1.0, seed=3):
    """Trap snare: a cracked noise band over two detuned tonal bodies."""
    n = int(SR * dur)
    x = _t(n)
    crack = shape(np.random.default_rng(seed).standard_normal(n), lo=1500, hi=8500)
    crack *= env(n, decay, attack=0.0004)
    body = (np.sin(2 * np.pi * tone * x) + 0.7 * np.sin(2 * np.pi * tone * 1.62 * x))
    body *= env(n, 0.032, attack=0.0006)
    return crack * 0.95 * bright + body * 0.42


def clap(dur=0.22, tone=1900.0, seed=11, spread_ms=9.0):
    """Four fast noise bursts plus a short tail. Reads as a clap, not a snare."""
    n = int(SR * dur)
    buf = np.zeros(n)
    for i in range(4):
        off = int(SR * (i * spread_ms / 1000.0))
        burst = noise(n - off, 0.006, lo=tone * 0.55, hi=tone * 3.2, seed=seed + i)
        buf[off:] += burst * (1.0 - 0.15 * i)
    buf += noise(n, 0.045, lo=tone * 0.7, hi=tone * 2.4, seed=seed + 40) * 0.35
    return buf


def rim(dur=0.06, freq=1750.0, seed=21):
    """Rimshot tick. Pure transient, this is what makes the grid legible."""
    n = int(SR * dur)
    sig = noise(n, 0.0022, lo=1800, hi=9500, seed=seed) * 0.9
    sig += np.sin(2 * np.pi * freq * _t(n)) * env(n, 0.010) * 0.5
    return sig


def punch(dur=0.06, freq=3000.0, seed=51):
    """Mid band attack layer, 2 to 5 kHz.

    An 808 puts most of its energy below 120 Hz, which a laptop speaker cannot
    reproduce at all, and peak normalization then pulls everything audible down
    with it. This layer is the part that actually survives on small speakers and
    over music, so every pattern gets one on its downbeat.
    """
    n = int(SR * dur)
    sig = noise(n, 0.0040, lo=2000, hi=5200, seed=seed) * 1.0
    sig += np.sin(2 * np.pi * freq * _t(n)) * env(n, 0.012) * 0.45
    sig += np.sin(2 * np.pi * freq * 1.47 * _t(n)) * env(n, 0.008) * 0.28
    return sig


# Vowel formants, (freq, Q, gain) triples. Enough for a short ad-lib chop.
VOWELS = {
    "a":  [(760, 9, 1.0), (1180, 11, 0.62), (2600, 13, 0.32)],
    "e":  [(530, 10, 1.0), (1840, 12, 0.70), (2600, 13, 0.34)],
    "i":  [(320, 11, 1.0), (2300, 13, 0.55), (3100, 14, 0.30)],
    "u":  [(330, 10, 1.0), (720, 12, 0.50), (2400, 13, 0.18)],
}


def vocal(dur, f0_start, f0_end, vowel_from="e", vowel_to="i",
          decay=0.16, breath=0.10, seed=31):
    """A short vocal-ish ad-lib: glottal pulse train through moving formants.

    It is not a sampled voice, but with a pitch bend and a vowel glide it lands
    in the same place a chopped "ayy" does at the top of a drill bar.
    """
    n = int(SR * dur)
    x = _t(n)
    f0 = f0_end + (f0_start - f0_end) * np.exp(-x / (dur * 0.45))
    phase = np.cumsum(f0) / SR
    # Band limited-ish pulse train: a narrow raised cosine per period.
    frac = phase - np.floor(phase)
    src = np.where(frac < 0.06, 0.5 - 0.5 * np.cos(2 * np.pi * frac / 0.06), 0.0)
    src = src - src.mean()
    src += np.random.default_rng(seed).standard_normal(n) * breath

    fa, fb = VOWELS[vowel_from], VOWELS[vowel_to]
    out = np.zeros(n)
    blend = np.clip(x / (dur * 0.6), 0, 1)
    ir_len = int(SR * 0.05)
    ti = _t(ir_len)
    for (f1, q1, g1), (f2, q2, g2) in zip(fa, fb):
        # Two static resonators crossfaded, which is cheaper than a moving one
        # and indistinguishable over 300 ms.
        for f, q, g, w in ((f1, q1, g1, 1 - blend), (f2, q2, g2, blend)):
            ir = np.exp(-np.pi * f / q * ti) * np.sin(2 * np.pi * f * ti)
            out += fftconv(src, ir, n) * g * w
    return out * env(n, decay, attack=0.004)



# --------------------------------------------------------------- bass engines
#
# Pitch alone is not enough to tell two agents apart when you are not listening
# for it. Each provider gets a different synthesis method, so the bass has its
# own character: round, gritty, plucky or hard.

def bass_808(dur, f_hi, root, decay=0.16, drive=3.2, slide_to=None,
             slide_at=0.115, slide_time=0.10):
    """Round, deep, classic. Saturated sine with a hard pitch drop in."""
    if slide_to is None:
        return eight08(dur, f_hi, root, decay=decay, drive=drive)
    return eight08_slide(dur, f_hi, root, slide_to, slide_at=slide_at,
                         slide_time=slide_time, decay=decay, drive=drive)


def bass_reese(dur, f_hi, root, decay=0.18, drive=3.0, slide_to=None,
               slide_at=0.115, slide_time=0.10, detune=1.022):
    """Gritty and wide. Three detuned saws beating against each other, then
    low passed. This is the dark, moving bass sound."""
    n = int(SR * dur)
    x = _t(n)
    freq = root + (f_hi - root) * np.exp(-x / 0.026)
    if slide_to is not None:
        r = np.clip((x - slide_at) / slide_time, 0, 1)
        freq = freq + (slide_to - root) * (r * r * (3 - 2 * r))
    sig = np.zeros(n)
    for k, d in enumerate((1.0, detune, 1 / detune)):
        ph = 2 * np.pi * np.cumsum(freq * d) / SR
        frac = (ph / (2 * np.pi)) % 1.0
        sig += (2 * frac - 1) * (0.9 if k == 0 else 0.7)    # saw
    sig = shape(sig / 2.4, hi=1600)
    sig = np.tanh(sig * drive) / np.tanh(drive)
    return sig * env(n, decay, attack=0.0010)


def bass_pluck(dur, f_hi, root, decay=0.11, drive=2.2, slide_to=None,
               slide_at=0.115, slide_time=0.10, fm_ratio=2.0, fm_index=5.0):
    """Bouncy and short. FM bass: the modulator decays fast, so it starts
    bright and snaps shut. Reads higher and more playful than an 808."""
    n = int(SR * dur)
    x = _t(n)
    freq = root + (f_hi - root) * np.exp(-x / 0.020)
    if slide_to is not None:
        r = np.clip((x - slide_at) / slide_time, 0, 1)
        freq = freq + (slide_to - root) * (r * r * (3 - 2 * r))
    mod_env = np.exp(-x / 0.035)
    mod = np.sin(2 * np.pi * np.cumsum(freq * fm_ratio) / SR) * fm_index * mod_env
    sig = np.sin(2 * np.pi * np.cumsum(freq) / SR + mod)
    sig = np.tanh(sig * drive) / np.tanh(drive)
    return sig * env(n, decay, attack=0.0006)


def bass_hard(dur, f_hi, root, decay=0.13, drive=6.0, slide_to=None,
              slide_at=0.115, slide_time=0.10):
    """Aggressive. A square through heavy drive, so it is all harmonics and
    cuts on any speaker. The loudest personality of the four."""
    n = int(SR * dur)
    x = _t(n)
    freq = root + (f_hi - root) * np.exp(-x / 0.018)
    if slide_to is not None:
        r = np.clip((x - slide_at) / slide_time, 0, 1)
        freq = freq + (slide_to - root) * (r * r * (3 - 2 * r))
    ph = 2 * np.pi * np.cumsum(freq) / SR
    sig = np.sign(np.sin(ph)) * 0.7 + np.sin(ph) * 0.3
    sig = shape(sig, hi=3200)
    sig = np.tanh(sig * drive) / np.tanh(drive)
    return sig * env(n, decay, attack=0.0007)


BASSES = {"808": bass_808, "reese": bass_reese, "pluck": bass_pluck, "hard": bass_hard}


# ------------------------------------------------------------------ assembly

def place(buf, sig, at_s, gain=1.0):
    i = int(SR * at_s)
    end = min(len(buf), i + len(sig))
    if end > i:
        buf[i:end] += sig[: end - i] * gain


def finish(sig, peak=0.95, fade_ms=6, floor_db=-60):
    """Soft clip, normalize, trim the dead tail, fade out so it ends clean."""
    sig = np.tanh(sig * 1.08)
    m = np.max(np.abs(sig))
    if m > 0:
        sig = sig / m * peak
    thresh = peak * (10 ** (floor_db / 20))
    loud = np.where(np.abs(sig) > thresh)[0]
    if len(loud):
        sig = sig[: loud[-1] + 1]
    fade = int(SR * fade_ms / 1000)
    if 0 < fade < len(sig):
        sig[-fade:] *= np.linspace(1, 0, fade)
    return sig


def write(name, sig):
    data = (np.clip(sig, -1, 1) * 32767).astype("<i2")
    with wave.open(str(OUT / name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())
    print(f"  {name:<26} {len(sig) / SR:.3f}s")
    return sig


# ------------------------------------------------------------------- voicing

# root is the 808 fundamental in Hz. Low enough to thump, far enough apart
# between providers that two agents finishing back to back are distinguishable.
VOICES = {
    "claude":   dict(root=55.00,  f_hi=185, drive=3.0, hat_base=44, hat_hp=7600,
                     hat_decay=0.011, snare_tone=200, bright=1.00, rim=1750,
                     bass="808", punch=3000, vox=(330, 262)),
    "codex":    dict(root=36.71,  f_hi=140, drive=4.4, hat_base=33, hat_hp=6200,
                     hat_decay=0.017, snare_tone=165, bright=0.82, rim=1380,
                     bass="reese", punch=2350, vox=(247, 196)),
    "opencode": dict(root=73.42,  f_hi=240, drive=2.4, hat_base=53, hat_hp=8900,
                     hat_decay=0.008, snare_tone=245, bright=1.16, rim=2100,
                     bass="pluck", punch=4100, vox=(392, 330)),
    "warp":     dict(root=43.65,  f_hi=250, drive=6.2, hat_base=61, hat_hp=9500,
                     hat_decay=0.010, snare_tone=215, bright=1.28, rim=1950,
                     bass="hard", punch=3500, vox=(294, 233)),
    "default":  dict(root=61.74,  f_hi=200, drive=3.4, hat_base=46, hat_hp=7000,
                     hat_decay=0.012, snare_tone=190, bright=1.00, rim=1620,
                     bass="808", punch=2750, vox=(311, 247)),
}

FOURTH = 4 / 3        # slide interval up, reads as a question
FIFTH_DOWN = 2 / 3    # slide interval down, reads as a full stop


def _hat(v, seed, decay_mul=1.0, gain=1.0):
    return hat(decay=v["hat_decay"] * decay_mul, base=v["hat_base"],
               hp=v["hat_hp"], seed=seed) * gain


def _bass(v, dur, gain_note=1.0, **kw):
    fn = BASSES[v["bass"]]
    return fn(dur, v["f_hi"] * gain_note, v["root"] * gain_note,
              drive=v["drive"], **kw)


def make_done(v):
    """Turn finished. A quarter bar of groove rather than a single stab:
    accent on 1, ghost bass on the 3rd sixteenth, hats filling the gaps.

    This is the sound you hear dozens of times a day, so it stays the shortest
    of the three, but it still has to read as a bar of a beat and not a beep.
    """
    buf = np.zeros(int(SR * 0.60))
    place(buf, rim(freq=v["rim"]), 0.0, 0.85)
    place(buf, punch(freq=v["punch"]), 0.0, 0.90)
    place(buf, _bass(v, 0.34, decay=0.135), 0.0, 1.0)
    place(buf, _hat(v, 1), 0.0, 0.52 * v["bright"])

    place(buf, _hat(v, 2), STEP, 0.24 * v["bright"])

    # Ghost note a fifth up. The bass moves, so the ear hears a bassline.
    place(buf, _bass(v, 0.16, gain_note=1.5, decay=0.055), 2 * STEP, 0.46)
    place(buf, _hat(v, 3), 2 * STEP, 0.34 * v["bright"])

    place(buf, _hat(v, 4, decay_mul=1.8), 3 * STEP, 0.44 * v["bright"])
    place(buf, punch(freq=v["punch"]), 3 * STEP, 0.28)
    return buf


def make_plan(v):
    """A plan is ready. Half a bar: the bass slides up a fourth and does not
    resolve, a snare lands on the backbeat, hats run the sixteenths.

    The unresolved rise is the point. It reads as handing something back to you
    rather than as finishing.
    """
    buf = np.zeros(int(SR * 1.00))
    root = v["root"]
    place(buf, rim(freq=v["rim"]), 0.0, 0.80)
    place(buf, punch(freq=v["punch"]), 0.0, 0.85)
    place(buf, _bass(v, 0.72, decay=0.30, slide_to=root * FOURTH,
                     slide_at=0.30, slide_time=0.13), 0.0, 1.0)

    # Trap sixteenths with a velocity pattern, plus a triplet stutter on 2.
    for i, g in enumerate((0.52, 0.22, 0.36, 0.20, 0.44, 0.24)):
        place(buf, _hat(v, 10 + i), i * STEP, g * v["bright"])
    trip = STEP * 2 / 3
    for i in range(2):
        place(buf, _hat(v, 18 + i), STEP + (i + 1) * trip, 0.20 * v["bright"])

    place(buf, snare(tone=v["snare_tone"], bright=v["bright"]), 3 * STEP, 0.72)
    place(buf, _bass(v, 0.22, gain_note=FOURTH, decay=0.08), 4 * STEP, 0.42)
    place(buf, _hat(v, 22, decay_mul=3.2), 5 * STEP, 0.30 * v["bright"])
    return buf


def make_input(v):
    """Blocked on you. A 32nd hat roll into a snare, which is the trap way of
    saying something is about to happen and it needs you."""
    buf = np.zeros(int(SR * 0.62))
    half = STEP / 2
    for i in range(4):
        place(buf, _hat(v, 30 + i), i * half, (0.24 + 0.11 * i) * v["bright"])
    place(buf, punch(freq=v["punch"]), 3 * half, 0.70)
    place(buf, snare(tone=v["snare_tone"], bright=v["bright"]), 3 * half, 0.88)
    place(buf, _bass(v, 0.28, decay=0.10), 3 * half, 0.80)
    place(buf, _hat(v, 40, decay_mul=2.4), 5 * half, 0.34 * v["bright"])
    return buf


def make_vox_done(v):
    """Vocal flavour of `done`: the same groove with a short ad-lib chop on top."""
    buf = make_done(v) * 0.85
    lo, hi = v["vox"]
    place(buf, vocal(0.30, lo, hi, "e", "i", decay=0.10), 0.008, 0.60)
    return buf


EVENTS = {"done": make_done, "plan": make_plan, "input": make_input}


def main():
    made = []
    for provider, v in VOICES.items():
        print(provider)
        for event, fn in EVENTS.items():
            sig = write(f"{provider}-{event}.wav", finish(fn(v)))
            made.append((f"{provider} {event}", sig))
        write(f"{provider}-done-vox.wav", finish(make_vox_done(v)))

    # One file that plays the whole matrix with a gap, for auditioning.
    gap = np.zeros(int(SR * 0.45))
    preview = np.concatenate([np.concatenate([s, gap]) for _, s in made])
    write("preview-all.wav", preview)


if __name__ == "__main__":
    main()
