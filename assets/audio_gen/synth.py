"""synth.py - the DSP toolkit behind every sound in How to Fish.

Pure numpy/scipy. No external binaries. Everything is vectorised and every
render is DETERMINISTIC given a seed, because `build.py --check` compares
files on disk against a fresh render and a stochastic generator would make
that check useless.

CONVENTIONS - read these before writing a cue.

* Sample rate is `SR` (44100) everywhere. Nothing resamples.
* A "signal" is a 1-D float64/float32 numpy array, mono, nominally in
  [-1, 1]. Stereo appears only at the very end (`stereo_width`, music
  masters, `write_ogg(..., stereo=True)`); write cues in mono.
* Durations are SECONDS (floats), not sample counts. `t(dur)` gives you the
  time axis, `n(dur)` the sample count. Functions that take a frequency
  accept either a scalar or an array of the same length as the output, so
  every oscillator is also a glide/sweep oscillator - `sine(dur, sweep(dur,
  300, 900))` is a rising chirp, no special case needed.
* Randomness comes from a `numpy.random.Generator` that the caller passes
  in. NEVER call `np.random.*` at module level or inside a render: the
  registry hands each cue its own seeded `rng` so cue N's output does not
  depend on whether cue N-1 ran.
* Length mismatches are the most common bug here. `mix()` and `place()`
  grow the destination automatically, so layer with those rather than with
  `a + b`; `fit(x, dur)` truncates-or-pads when you need an exact length.

WHY SO MANY MODELS. A cue that is one oscillator through one envelope
sounds like a demo. Everything in the game is built as TRANSIENT (a few ms
of noise or a click, the part the ear localises), BODY (the pitched or
resonant part that tells you what the object is) and TAIL (the room, which
tells you where you are). The physical-ish models in section 6 are the
bodies; section 7 has the tails.
"""

import functools
import hashlib
import math
import os

import numpy as np
import soundfile as sf
from scipy import signal as sps

SR = 44100
TWO_PI = 2.0 * math.pi

__all__ = [
    "SR", "n", "t", "silence", "rng", "seed_from",
    "sine", "tri", "saw", "square", "pulse", "supersaw", "fm", "fm_stack",
    "additive", "phasor",
    "white", "pink", "brown", "band_noise",
    "adsr", "expdec", "breakpoints", "ar", "perc_env", "sweep", "expsweep",
    "lowpass", "highpass", "bandpass", "notch", "lp_sweep", "hp_sweep",
    "moog", "svf", "comb", "allpass", "resonator", "formant",
    "karplus", "bar", "bell", "blown", "membrane", "bubble", "splash",
    "wet_texture", "metal_hit",
    "reverb", "make_ir", "delay", "chorus", "flanger", "saturate", "softclip",
    "compress", "limit", "stereo_width", "haas", "mid_side", "tremolo",
    "vibrato", "bitcrush",
    "mix", "place", "concat", "crossfade", "normalize", "loudness",
    "normalize_lufs", "fade", "fit", "pitch_play", "reverse", "dc_block",
    "db", "amp_db", "clip_report",
    "write_ogg", "write_wav",
]


# ---------------------------------------------------------------------------
# 0. time, length and randomness helpers
# ---------------------------------------------------------------------------

def n(dur):
    """Sample count for `dur` seconds (at least 1)."""
    return max(1, int(round(float(dur) * SR)))


def t(dur):
    """Time axis in seconds, shape (n(dur),), starting at 0."""
    return np.arange(n(dur), dtype=np.float64) / SR


def silence(dur):
    return np.zeros(n(dur), dtype=np.float64)


def rng(seed):
    """The one blessed RNG constructor. `seed` may be an int or a string."""
    if isinstance(seed, str):
        seed = seed_from(seed)
    return np.random.default_rng(seed)


def seed_from(text):
    """Stable 32-bit seed from a string (hash() is salted per process)."""
    h = hashlib.sha256(text.encode("utf-8")).digest()
    return int.from_bytes(h[:4], "big")


def _as_array(value, length):
    """Broadcast a scalar-or-array parameter to exactly `length` samples."""
    arr = np.asarray(value, dtype=np.float64)
    if arr.ndim == 0:
        return np.full(length, float(arr))
    if arr.shape[0] == length:
        return arr
    # Resample by linear interpolation so a short control curve can drive a
    # long signal - lets you write `sine(2.0, [200, 900, 400])`.
    src = np.linspace(0.0, 1.0, arr.shape[0])
    dst = np.linspace(0.0, 1.0, length)
    return np.interp(dst, src, arr)


def phasor(dur, freq, phase=0.0):
    """Normalised phase ramp in [0,1) for a scalar or time-varying `freq`.

    Every oscillator is built on this, which is why they all accept sweeps:
    the phase is the running integral of frequency, not `freq * t`.
    """
    length = n(dur)
    f = _as_array(freq, length)
    ph = np.cumsum(f) / SR + phase
    return ph


# ---------------------------------------------------------------------------
# 1. oscillators
# ---------------------------------------------------------------------------

def sine(dur, freq, phase=0.0):
    return np.sin(TWO_PI * phasor(dur, freq, phase))


def tri(dur, freq, phase=0.0):
    p = np.mod(phasor(dur, freq, phase), 1.0)
    return 4.0 * np.abs(p - 0.5) - 1.0


def saw(dur, freq, phase=0.0, bright=1.0):
    """Naive saw, then gently low-passed to tame the worst aliasing.

    `bright` 1.0 keeps it raw; lower values roll the top off, which is what
    you want for pads (a raw saw stack at 44.1k aliases audibly above ~2 kHz
    fundamental).
    """
    p = np.mod(phasor(dur, freq, phase), 1.0)
    out = 2.0 * p - 1.0
    if bright < 1.0:
        cut = 800.0 + 15000.0 * float(np.clip(bright, 0.02, 1.0))
        out = lowpass(out, cut, order=2)
    return out


def square(dur, freq, phase=0.0):
    return np.where(np.mod(phasor(dur, freq, phase), 1.0) < 0.5, 1.0, -1.0)


def pulse(dur, freq, width=0.5, phase=0.0):
    """Pulse wave. `width` may be an array -> PWM."""
    length = n(dur)
    p = np.mod(phasor(dur, freq, phase), 1.0)
    w = np.clip(_as_array(width, length), 0.02, 0.98)
    return np.where(p < w, 1.0, -1.0)


def supersaw(dur, freq, voices=7, detune=0.012, spread=1.0, phase_seed=None):
    """Detuned saw stack. `detune` is the max ratio offset of the outer voices.

    Deterministic: voice phases come from a fixed golden-ratio sequence
    unless a `phase_seed` rng is supplied.
    """
    length = n(dur)
    f = _as_array(freq, length)
    out = np.zeros(length)
    if voices < 1:
        voices = 1
    for i in range(voices):
        k = 0.0 if voices == 1 else (i / (voices - 1.0)) * 2.0 - 1.0
        ratio = 1.0 + k * detune * spread
        if phase_seed is not None:
            ph = float(phase_seed.random())
        else:
            ph = math.fmod(i * 0.6180339887, 1.0)
        out += saw(dur, f * ratio, phase=ph)
    return out / math.sqrt(voices)


def fm(dur, carrier, ratio=2.0, index=3.0, index_env=None, phase=0.0):
    """One modulator -> one carrier. The workhorse for bells and steel drums.

    `index` is the modulation index in radians of carrier phase; pass an
    envelope as `index_env` (same length or a short curve) to get the
    characteristic FM "bright attack, mellow tail".
    """
    length = n(dur)
    c = _as_array(carrier, length)
    idx = _as_array(index, length)
    if index_env is not None:
        idx = idx * _as_array(index_env, length)
    mod = np.sin(TWO_PI * phasor(dur, c * ratio))
    return np.sin(TWO_PI * (phasor(dur, c, phase)) + idx * mod)


def fm_stack(dur, carrier, pairs, phase=0.0):
    """Several modulators onto one carrier.

    `pairs` is a list of (ratio, index) or (ratio, index, envelope).
    """
    length = n(dur)
    c = _as_array(carrier, length)
    acc = np.zeros(length)
    for spec in pairs:
        ratio, index = spec[0], spec[1]
        env = spec[2] if len(spec) > 2 else None
        idx = _as_array(index, length)
        if env is not None:
            idx = idx * _as_array(env, length)
        acc += idx * np.sin(TWO_PI * phasor(dur, c * ratio))
    return np.sin(TWO_PI * phasor(dur, c, phase) + acc)


def additive(dur, freq, partials, decays=None, amps=None, phases=None):
    """Sum of partials with an independent exponential decay per partial.

    `partials` are frequency MULTIPLIERS (1.0, 2.0, 3.0... for harmonic;
    1.0, 2.756, 5.404... for a bar). `decays` are per-partial time
    constants in seconds - high partials should die first or it sounds
    like an organ, not a struck object.
    """
    length = n(dur)
    tt = np.arange(length, dtype=np.float64) / SR
    f0 = _as_array(freq, length)
    k = len(partials)
    if amps is None:
        amps = [1.0 / (i + 1.0) for i in range(k)]
    if decays is None:
        decays = [max(0.02, float(dur) / (i + 1.0)) for i in range(k)]
    out = np.zeros(length)
    for i, mult in enumerate(partials):
        ph = 0.0 if phases is None else float(phases[i])
        env = np.exp(-tt / max(1e-4, float(decays[i])))
        out += float(amps[i]) * env * np.sin(TWO_PI * phasor(dur, f0 * float(mult), ph))
    peak = np.max(np.abs(out))
    return out / peak if peak > 0 else out


# ---------------------------------------------------------------------------
# 2. noise
# ---------------------------------------------------------------------------

def white(dur, r):
    return r.standard_normal(n(dur)) * 0.3


def pink(dur, r):
    """1/f noise via the Voss/filter approximation (Paul Kellet's coefficients)."""
    x = white(dur, r)
    b = np.array([0.049922035, -0.095993537, 0.050612699, -0.004408786])
    a = np.array([1.0, -2.494956002, 2.017265875, -0.522189400])
    out = sps.lfilter(b, a, x)
    return out / (np.max(np.abs(out)) + 1e-12) * 0.35


def brown(dur, r):
    """Integrated white noise, DC-blocked. Rumble, surf, distant thunder."""
    x = np.cumsum(white(dur, r))
    x = dc_block(x, 12.0)
    return x / (np.max(np.abs(x)) + 1e-12) * 0.5


def band_noise(dur, r, low, high, order=4):
    """Noise confined to a band. The base of almost every splash and hit."""
    x = white(dur, r)
    return bandpass(x, low, high, order=order)


# ---------------------------------------------------------------------------
# 3. envelopes
# ---------------------------------------------------------------------------

def adsr(dur, a=0.01, d=0.1, s=0.7, rel=0.2, hold=0.0, curve=2.0):
    """Attack / decay / (hold at) sustain / release, total length `dur`.

    The A and D segments are curved (`curve` > 1 = fast then slow, which is
    what a struck or plucked thing does). If a+d+hold+rel exceeds `dur` the
    segments are scaled down proportionally rather than clipped, so an
    envelope never runs off the end of its own note.
    """
    length = n(dur)
    total = a + d + hold + rel
    span = length / SR
    if total > span and total > 0:
        k = span / total
        a, d, hold, rel = a * k, d * k, hold * k, rel * k
    na, nd, nh = n(a) if a > 0 else 0, n(d) if d > 0 else 0, n(hold) if hold > 0 else 0
    nr = n(rel) if rel > 0 else 0
    ns = max(0, length - na - nd - nh - nr)
    segs = []
    if na:
        segs.append(np.linspace(0.0, 1.0, na) ** (1.0 / curve))
    if nd:
        segs.append(s + (1.0 - s) * (np.linspace(1.0, 0.0, nd) ** curve))
    if nh:
        segs.append(np.full(nh, s))
    if ns:
        segs.append(np.full(ns, s))
    if nr:
        segs.append(s * (np.linspace(1.0, 0.0, nr) ** curve))
    env = np.concatenate(segs) if segs else np.zeros(length)
    return fit(env, length / SR)


def ar(dur, a=0.005, r=None, curve=2.5):
    """Attack-release, no sustain. The default shape for a one-shot hit."""
    if r is None:
        r = max(0.001, float(dur) - a)
    return adsr(dur, a=a, d=0.0, s=1.0, rel=r, hold=0.0, curve=curve)


def expdec(dur, tau, start=1.0, floor=0.0):
    """Exponential decay with time constant `tau` seconds."""
    e = start * np.exp(-t(dur) / max(1e-5, float(tau)))
    return e + floor * (1.0 - e) if floor else e


def perc_env(dur, attack=0.002, tau=None, curve=1.0):
    """Instant attack + exponential body. Kicks, plucks, plops."""
    if tau is None:
        tau = float(dur) / 4.0
    length = n(dur)
    e = np.exp(-t(dur) / max(1e-5, tau)) ** curve
    na = max(1, n(attack))
    if na < length:
        e[:na] *= np.linspace(0.0, 1.0, na) ** 0.5
    return e


def breakpoints(dur, points, curve="lin"):
    """Custom envelope from [(time_s, value), ...]. Times need not span `dur`.

    `curve="exp"` interpolates in the log domain (values are floored at
    1e-4), which is the right shape for anything the ear reads as a decay.
    """
    length = n(dur)
    xs = np.array([float(p[0]) for p in points])
    ys = np.array([float(p[1]) for p in points])
    grid = np.arange(length, dtype=np.float64) / SR
    if curve == "exp":
        ys = np.log(np.maximum(ys, 1e-4))
        return np.exp(np.interp(grid, xs, ys))
    return np.interp(grid, xs, ys)


def sweep(dur, start, end, curve=1.0):
    """Linear-in-`curve`-power sweep, e.g. for a frequency glide."""
    x = np.linspace(0.0, 1.0, n(dur)) ** curve
    return start + (end - start) * x


def expsweep(dur, start, end):
    """Geometric sweep - the musically correct one for pitch."""
    start = max(1e-6, float(start))
    end = max(1e-6, float(end))
    return start * (end / start) ** np.linspace(0.0, 1.0, n(dur))


# ---------------------------------------------------------------------------
# 4. filters
# ---------------------------------------------------------------------------

_NYQ = SR * 0.5

# Filter coefficients are ROUNDED TO 12 DECIMALS before use, and the design
# is cached. This is not tidiness, it is what makes the whole generator
# reproducible.
#
# `scipy.signal.butter` is not bit-deterministic: designing the SAME filter
# twice in one process returns coefficients that differ in the last bit or
# two (numpy's polynomial multiply takes different SIMD paths depending on
# where the array happened to be allocated). One ULP in a filter coefficient
# is inaudible on its own - but every cue ends with a peak normalise, and
# dividing by a max that moved by one ULP shifts EVERY sample, which is
# enough to change the rendered file. The symptom was a build that produced
# a different OGG about one run in four with no source change, which makes
# `--check` meaningless and every rebuild a binary diff.
#
# Rounding to 12 decimals collapses those variants onto one value. The
# coefficients here are order 1e-2 to 1e1, so the change is under 5e-13
# relative - some 10 orders of magnitude below anything audible.
_COEF_DECIMALS = 12


def _canon(arr):
    return np.round(np.asarray(arr, dtype=np.float64), _COEF_DECIMALS)


def _wn(freq):
    return float(np.clip(freq / _NYQ, 1e-5, 0.999))


@functools.lru_cache(maxsize=2048)
def _design(kind, order, wn, extra=0.0):
    """Cached, canonicalised filter design. `wn` is a float or a 2-tuple."""
    if kind in ("low", "high", "band"):
        b, a = sps.butter(order, list(wn) if isinstance(wn, tuple) else wn, btype=kind)
    elif kind == "peak":
        b, a = sps.iirpeak(wn, extra)
    elif kind == "notch":
        b, a = sps.iirnotch(wn, extra)
    else:
        raise ValueError("unknown filter kind %r" % kind)
    return _canon(b), _canon(a)


@functools.lru_cache(maxsize=2048)
def _design_zi(kind, order, wn, extra=0.0):
    """Cached steady-state initial conditions, canonicalised for the same
    reason (`lfilter_zi` solves a linear system, and LAPACK is no more
    bit-stable across calls than numpy's convolve is)."""
    b, a = _design(kind, order, wn, extra)
    return _canon(sps.lfilter_zi(b, a))


def lowpass(x, cutoff, order=4):
    b, a = _design("low", order, _wn(cutoff))
    return sps.lfilter(b, a, x)


def highpass(x, cutoff, order=4):
    b, a = _design("high", order, _wn(cutoff))
    return sps.lfilter(b, a, x)


def bandpass(x, low, high, order=4):
    lo, hi = _wn(low), _wn(high)
    if hi <= lo:
        hi = min(0.999, lo * 1.05 + 1e-4)
    b, a = _design("band", order, (lo, hi))
    return sps.lfilter(b, a, x)


def notch(x, freq, q=8.0):
    b, a = _design("notch", 2, _wn(freq), float(q))
    return sps.lfilter(b, a, x)


def _chunked_filter(x, cutoffs, design, chunk=256):
    """Time-varying IIR: redesign every `chunk` samples, carry the state.

    Carrying `zi` across chunks is the whole trick - without it every chunk
    boundary is a click, and the clicks are exactly at 172 Hz so they read
    as a buzz rather than as a bug.
    """
    length = len(x)
    cut = _as_array(cutoffs, length)
    out = np.empty(length)
    zi = None
    pos = 0
    while pos < length:
        end = min(length, pos + chunk)
        b, a = design(float(np.mean(cut[pos:end])))
        if zi is None:
            zi = _canon(sps.lfilter_zi(b, a)) * x[pos]
        elif len(zi) != max(len(a), len(b)) - 1:
            zi = np.resize(zi, max(len(a), len(b)) - 1)
        out[pos:end], zi = sps.lfilter(b, a, x[pos:end], zi=zi)
        pos = end
    return out


def lp_sweep(x, cutoffs, order=2, chunk=256):
    """Low-pass whose cutoff moves. `cutoffs` is a scalar-or-curve in Hz."""
    return _chunked_filter(x, cutoffs, lambda c: _design("low", order, _wn(c)), chunk)


def hp_sweep(x, cutoffs, order=2, chunk=256):
    return _chunked_filter(x, cutoffs, lambda c: _design("high", order, _wn(c)), chunk)


def bp_sweep(x, centres, q=4.0, order=2, chunk=256):
    def design(c):
        bw = max(20.0, c / q)
        lo, hi = _wn(c - bw * 0.5), _wn(c + bw * 0.5)
        if hi <= lo:
            hi = min(0.999, lo * 1.05 + 1e-4)
        return _design("band", order, (lo, hi))
    return _chunked_filter(x, centres, design, chunk)


def svf(x, cutoff, q=1.0, mode="low"):
    """Chamberlin state-variable filter - resonant, and cheap to sweep.

    Implemented as a scipy biquad per chunk rather than sample-by-sample;
    same response, ~100x faster. `q` above ~6 self-emphasises usefully
    (zaps, laser-ish sweeps, resonant plucks).
    """
    cut = _as_array(cutoff, len(x))
    if mode == "band":
        return _chunked_filter(x, cut, lambda c: _design("peak", 2, _wn(c), float(q)), 256)

    # Resonant 2-pole biquad, built by hand so Q is honoured (scipy's butter
    # is maximally flat by definition - it cannot give you a resonant peak).
    def design2(c):
        w0 = TWO_PI * float(np.clip(c, 20.0, _NYQ * 0.98)) / SR
        alpha = math.sin(w0) / (2.0 * max(0.5, q))
        cosw = math.cos(w0)
        if mode == "low":
            b = np.array([(1 - cosw) / 2, 1 - cosw, (1 - cosw) / 2])
        else:
            b = np.array([(1 + cosw) / 2, -(1 + cosw), (1 + cosw) / 2])
        a = np.array([1 + alpha, -2 * cosw, 1 - alpha])
        return _canon(b / a[0]), _canon(a / a[0])
    return _chunked_filter(x, cut, design2, 256)


def moog(x, cutoff, res=0.6):
    """Four cascaded one-poles with feedback - the ladder approximation.

    Vectorised per chunk (the feedback is applied from the previous chunk's
    output, which at 256 samples is inaudible and keeps this fast). Good
    for basses and pads; use `svf` when you want a screaming resonance.
    """
    length = len(x)
    cut = _as_array(cutoff, length)
    res = float(np.clip(res, 0.0, 0.98))
    out = np.empty(length)
    z = [0.0, 0.0, 0.0, 0.0]
    fb = 0.0
    chunk = 128
    pos = 0
    while pos < length:
        end = min(length, pos + chunk)
        c = float(np.clip(np.mean(cut[pos:end]), 20.0, _NYQ * 0.9))
        g = 1.0 - math.exp(-TWO_PI * c / SR)
        seg = x[pos:end] - 4.0 * res * fb
        seg = np.tanh(seg * 0.7)
        for i in range(4):
            b = np.array([g])
            a = np.array([1.0, -(1.0 - g)])
            seg, zf = sps.lfilter(b, a, seg, zi=[z[i]])
            z[i] = float(zf[0])
        fb = float(seg[-1]) if len(seg) else fb
        out[pos:end] = seg
        pos = end
    return out


def comb(x, delay_s, feedback=0.7, mix=1.0, damp=0.0):
    """Feedback comb. `damp` (0..1) low-passes inside the loop - metal vs wood."""
    d = max(1, int(round(delay_s * SR)))
    out = np.array(x, dtype=np.float64, copy=True)
    if damp <= 0.0:
        # Pure recursive comb: y[i] += fb*y[i-d]. Vectorised block by block
        # because each block of `d` only depends on the previous block.
        for start in range(d, len(out), d):
            end = min(len(out), start + d)
            out[start:end] += feedback * out[start - d:start - d + (end - start)]
    else:
        # Damped comb: a one-pole inside the feedback loop. Still done a
        # PERIOD at a time - block j depends only on block j-1, so the
        # one-pole runs vectorised over each block with its state carried.
        a = float(np.clip(damp, 0.0, 0.99))
        b_lp, a_lp = np.array([1.0 - a]), np.array([1.0, -a])
        zi = np.zeros(1)
        for start in range(d, len(out), d):
            end = min(len(out), start + d)
            prev = out[start - d:start - d + (end - start)]
            low, zi = sps.lfilter(b_lp, a_lp, prev, zi=zi)
            out[start:end] = x[start:end] + feedback * low
    if mix >= 1.0:
        return out
    return x * (1.0 - mix) + out * mix


def allpass(x, delay_s, g=0.5):
    d = max(1, int(round(delay_s * SR)))
    y = np.zeros(len(x) + d)
    xin = np.concatenate([x, np.zeros(d)])
    # y[i] = -g*x[i] + x[i-d] + g*y[i-d]
    for start in range(0, len(y), d):
        end = min(len(y), start + d)
        seg = -g * xin[start:end]
        if start >= d:
            seg = seg + xin[start - d:start - d + (end - start)] + g * y[start - d:start - d + (end - start)]
        y[start:end] = seg
    return y[:len(x)]


def resonator(x, freq, q=30.0, gain=1.0):
    """A single ringing peak. Layer a few for a struck-metal body."""
    b, a = _design("peak", 2, _wn(freq), float(q))
    return sps.lfilter(b, a, x) * gain


def formant(x, freqs, qs=None, gains=None):
    """Parallel resonant bands - the cheap vowel/choir trick."""
    if qs is None:
        qs = [12.0] * len(freqs)
    if gains is None:
        gains = [1.0] * len(freqs)
    out = np.zeros(len(x))
    for f, q, g in zip(freqs, qs, gains):
        out += resonator(x, f, q) * g
    return out


# ---------------------------------------------------------------------------
# 5. physical-ish models
# ---------------------------------------------------------------------------

def karplus(dur, freq, r, brightness=0.5, damping=0.35, pluck=None, stretch=0.0):
    """Karplus-Strong plucked string.

    The exciter is a short noise burst shaped by `brightness` (0 = a soft
    thumb on a nylon string, 1 = a plectrum on steel). `damping` sets how
    fast the loop filter eats the highs, which is the difference between a
    harp and a banjo. `stretch` (0..0.5) adds allpass-ish detune to the loop
    for a slightly inharmonic, more metallic string.

    THE LOOP: the only Python loop in this file that runs per-period, not
    per-sample - a 2 s note at 220 Hz is 440 iterations of a vectorised
    period-length update, which is fast. Doing it per sample is ~40x slower
    and produces the same numbers.
    """
    length = n(dur)
    period = max(2, int(round(SR / max(20.0, float(freq)))))
    exc = r.standard_normal(period)
    b_val = float(np.clip(brightness, 0.0, 1.0))
    if b_val < 1.0:
        # Roll the exciter's top off; low brightness = duller pluck.
        cut = 500.0 + 9000.0 * b_val
        exc = lowpass(exc, cut, order=2)
    if pluck is not None:
        exc = exc * _as_array(pluck, period)
    exc = exc / (np.max(np.abs(exc)) + 1e-12)

    out = np.zeros(length + period)
    out[:period] = exc
    d = float(np.clip(damping, 0.01, 0.95))
    # Loop filter: y[i] = (1-d)*x[i] + d*x[i-1], applied to the whole period
    # at once, plus a small loss so it always decays.
    loss = 0.999 - 0.02 * d
    prev_tail = exc[-1]
    pos = period
    while pos < length + period:
        seg = out[pos - period:pos]
        filt = np.empty(period)
        filt[0] = (1.0 - d) * seg[0] + d * prev_tail
        filt[1:] = (1.0 - d) * seg[1:] + d * seg[:-1]
        if stretch > 0.0:
            filt = filt * (1.0 - stretch) + np.roll(filt, 1) * stretch
        prev_tail = seg[-1]
        end = min(length + period, pos + period)
        out[pos:end] = filt[:end - pos] * loss
        pos = end
    y = out[:length]
    peak = np.max(np.abs(y))
    return y / peak if peak > 0 else y


# Inharmonic partial sets, measured-ish ratios. These are what make a bar
# sound like a bar and not like a sine with a fast envelope.
BAR_PARTIALS = [1.0, 2.756, 5.404, 8.933, 13.34]
BELL_PARTIALS = [0.5, 1.0, 1.19, 1.56, 2.0, 2.51, 2.66, 3.01, 4.1, 5.43]
TUBE_PARTIALS = [1.0, 2.0, 3.0, 4.0, 5.0]


def bar(dur, freq, r=None, decay=0.6, strike=0.6, partials=None):
    """Struck bar - marimba, xylophone, wood block bodies."""
    parts = partials or BAR_PARTIALS
    amps = [1.0, 0.35 * strike, 0.16 * strike, 0.08 * strike, 0.04 * strike][:len(parts)]
    while len(amps) < len(parts):
        amps.append(0.03)
    decays = [decay * (0.9 ** i) / (1.0 + 0.55 * i) for i in range(len(parts))]
    body = additive(dur, freq, parts, decays=decays, amps=amps)
    if r is not None:
        # Mallet click: a couple of ms of band noise at the strike point.
        click = band_noise(min(0.012, dur), r, *_safe_band(freq * 2.0, freq * 9.0))
        click *= perc_env(min(0.012, dur), 0.0002, 0.003)
        body = mix(body, click * 0.35 * strike)
    return body


def bell(dur, freq, r=None, decay=2.0, strike=0.7, inharmonic=1.0):
    """Struck bell / glass - many long inharmonic partials, hum tone below."""
    parts = [1.0 + (p - 1.0) * inharmonic for p in BELL_PARTIALS]
    amps = [0.6, 1.0, 0.5, 0.42, 0.35, 0.25, 0.2, 0.16, 0.1, 0.07]
    decays = [decay * m for m in [1.4, 1.0, 0.8, 0.65, 0.55, 0.4, 0.35, 0.28, 0.18, 0.12]]
    body = additive(dur, freq, parts, decays=decays, amps=amps)
    if r is not None:
        click = band_noise(min(0.008, dur), r, *_safe_band(freq * 3.0, freq * 14.0))
        click *= perc_env(min(0.008, dur), 0.0002, 0.002)
        body = mix(body, click * 0.3 * strike)
    return body


def blown(dur, freq, r, breath=0.4, bright=0.5, vib=0.0):
    """Blown pipe - a resonated noise column plus a soft harmonic core.

    Whistles, flutes, the wreck island's melody, wind through a hull.
    """
    length = n(dur)
    f = _as_array(freq, length)
    if vib:
        f = f * (1.0 + vib * 0.012 * np.sin(TWO_PI * 5.2 * (np.arange(length) / SR)))
    air = white(dur, r)
    air = bp_sweep(air, f * (1.0 + 0.0), q=6.0)
    core = sine(dur, f) * 0.7 + sine(dur, f * 2.0) * 0.22 * bright + sine(dur, f * 3.0) * 0.08 * bright
    out = core * (1.0 - breath * 0.6) + air * breath * 2.2
    return out / (np.max(np.abs(out)) + 1e-12)


def membrane(dur, freq, r, drop=0.35, noise=0.35, tau=None, sweep_time=None):
    """Drum head: a sine whose pitch drops fast, plus a noise skin layer.

    `drop` is the fraction of the starting pitch the sound settles AT, so
    the hit begins at `freq / drop` and falls to `freq` with a time
    constant of `sweep_time` (default a tenth of the hit). This is the
    model behind kick, tom, taiko and timpani - only the numbers differ.
    """
    if tau is None:
        tau = float(dur) * 0.3
    if sweep_time is None:
        sweep_time = max(0.004, float(dur) * 0.10)
    length = n(dur)
    tt = np.arange(length) / SR
    pitch_env = np.exp(-tt / sweep_time)
    drop = float(np.clip(drop, 0.05, 1.0))
    f = freq * (1.0 + (1.0 / drop - 1.0) * pitch_env)
    body = sine(dur, f) * perc_env(dur, 0.0008, tau)
    skin = band_noise(dur, r, freq * 1.5, min(12000.0, freq * 20.0))
    skin *= perc_env(dur, 0.0003, min(0.05, tau * 0.25))
    return mix(body, skin * noise)


def bubble(dur, freq=420.0, r=None, rise=2.4, tau=None):
    """A single bubble: a sine whose pitch RISES as the bubble shrinks.

    The rise is the whole illusion - a falling pitch reads as a drip in a
    cave, a rising one reads as a bubble in water. (Minnaert: the resonant
    frequency goes up as the radius goes down.)
    """
    if tau is None:
        tau = float(dur) * 0.45
    f = expsweep(dur, freq, freq * rise)
    body = sine(dur, f) * perc_env(dur, 0.0015, tau, curve=1.2)
    if r is not None:
        body = mix(body, sine(dur, f * 2.01) * perc_env(dur, 0.002, tau * 0.5) * 0.12)
    return body


def splash(dur, r, low=700.0, high=9000.0, sweep_to=None, body=0.35):
    """Water impact: a noise burst through a fast-closing low-pass.

    The falling cutoff is what turns "a shhh" into "a splash" - the spray
    is bright for 30 ms then it is all water.
    """
    if sweep_to is None:
        sweep_to = max(300.0, low * 0.5)
    x = band_noise(dur, r, low, high, order=3)
    cut = expsweep(dur, high, sweep_to)
    x = lp_sweep(x, cut, order=2)
    x *= perc_env(dur, 0.0015, float(dur) * 0.28, curve=1.3)
    if body > 0:
        thud = sine(dur, expsweep(dur, 180.0, 70.0)) * perc_env(dur, 0.002, float(dur) * 0.16)
        x = mix(x, thud * body)
    return x / (np.max(np.abs(x)) + 1e-12)


def wet_texture(dur, r, density=26.0, freq=500.0, spread=2.2, level=0.6):
    """A scatter of bubbles/droplets over `dur` - lapping, drips, wet flop.

    Deterministic given `r`. `density` is events per second.
    """
    out = silence(dur)
    count = max(1, int(round(density * float(dur))))
    times = np.sort(r.random(count)) * max(0.0, float(dur) - 0.05)
    for i in range(count):
        f = freq * float(spread ** (r.random() * 2.0 - 1.0))
        d = float(0.02 + 0.05 * r.random())
        one = bubble(d, f, r, rise=1.6 + 1.4 * float(r.random()))
        out = place(out, one * (0.25 + 0.75 * float(r.random())) * level, float(times[i]))
    return out[: int(dur * SR)]


def metal_hit(dur, r, freq=340.0, ring=0.7, roughness=0.5):
    """Struck metal - hull, bell, anchor, cannon. Resonators over a noise hit."""
    exc = white(min(0.02, dur), r) * perc_env(min(0.02, dur), 0.0002, 0.004)
    exc = fit(exc, dur)
    out = np.zeros(n(dur))
    ratios = [1.0, 1.73, 2.41, 3.14, 4.62, 6.03]
    for i, ratio in enumerate(ratios):
        f = freq * ratio * (1.0 + roughness * 0.02 * (i % 3 - 1))
        out += resonator(exc, f, q=40.0 + 90.0 * ring) / (i + 1.0)
    out *= expdec(dur, max(0.05, float(dur) * 0.35 * (0.4 + ring)))
    return out / (np.max(np.abs(out)) + 1e-12)


# ---------------------------------------------------------------------------
# 6. effects
# ---------------------------------------------------------------------------

@functools.lru_cache(maxsize=64)
def make_ir(size=0.6, damping=0.5, predelay=0.0, seed=7, diffusion=0.7):
    """A synthetic reverb impulse response: decaying, progressively darker noise.

    Cached on its arguments because building one is ~50 ms and a sheet may
    ask for the same room a hundred times. `size` is roughly RT60 in
    seconds; `damping` is how much faster the highs die than the lows,
    which is the difference between a tiled room and a wooden hold.
    """
    rr = np.random.default_rng(seed)
    length = max(n(0.05), n(size * 1.6))
    tail = rr.standard_normal(length)
    tt = np.arange(length) / SR
    env = np.exp(-tt * (6.0 / max(0.05, size)))
    ir = tail * env
    # Darken over time: split into two bands and decay the top faster.
    hi = highpass(ir, 1800.0, order=2)
    ir = ir - hi + hi * np.exp(-tt * (6.0 / max(0.05, size)) * (1.0 + 4.0 * damping))
    # Early reflections give the room a size the ear can hear.
    for k in range(6):
        d = int((0.007 + 0.019 * k * (0.6 + 0.8 * float(rr.random()))) * SR * max(0.3, size))
        if d < length:
            ir[d:] += ir[:length - d] * (0.35 * diffusion) * (0.7 ** k)
    ir[:8] *= np.linspace(0.0, 1.0, 8)
    ir = ir / (np.max(np.abs(ir)) + 1e-12)
    if predelay > 0:
        ir = np.concatenate([np.zeros(n(predelay)), ir])
    return ir.astype(np.float64)


def reverb(x, size=0.6, damping=0.5, mix=0.25, predelay=0.0, seed=7, tail=True):
    """Convolution reverb. `tail=False` truncates to the input length."""
    ir = make_ir(size, damping, predelay, seed)
    wet = sps.fftconvolve(x, ir)[: len(x) + len(ir) - 1]
    wet = wet / (np.max(np.abs(wet)) + 1e-12) * (np.max(np.abs(x)) + 1e-12)
    if not tail:
        wet = wet[: len(x)]
    dry = fit(x, len(wet) / SR) if tail else x
    return dry * (1.0 - mix) + wet * mix


def delay(x, time_s=0.25, feedback=0.35, mix=0.3, damp=0.3, taps=6):
    """Feedback delay as a finite sum of taps - no per-sample loop.

    Each repeat is darker than the last (`damp`), which is what a real
    delay line with a lossy feedback path does and what stops a long tail
    turning into a hiss. The output is LONGER than the input by the tail.
    """
    extra = int(round(time_s * SR * taps))
    src = np.concatenate([np.asarray(x, dtype=np.float64), np.zeros(extra)])
    echo = np.zeros(len(src))
    g = feedback
    voice = src
    for i in range(taps):
        d = int(round(time_s * SR * (i + 1)))
        if d >= len(src):
            break
        voice = lowpass(voice, max(600.0, 14000.0 * (1.0 - damp)), order=2)
        echo[d:] += voice[: len(src) - d] * g
        g *= feedback
    return src * (1.0 - mix * 0.35) + echo * mix


def chorus(x, rate=0.6, depth_ms=6.0, voices=3, mix=0.4, seed=3):
    """Modulated short delays. Thickens pads, plucks, choirs."""
    rr = np.random.default_rng(seed)
    length = len(x)
    tt = np.arange(length) / SR
    idx = np.arange(length, dtype=np.float64)
    out = np.zeros(length)
    for v in range(voices):
        ph = float(rr.random())
        base = 0.012 + 0.006 * v
        mod = base + (depth_ms / 1000.0) * 0.5 * (1.0 + np.sin(TWO_PI * (rate * (0.8 + 0.4 * v) * tt + ph)))
        pos = idx - mod * SR
        out += np.interp(pos, idx, x, left=0.0, right=0.0)
    out /= voices
    return x * (1.0 - mix) + out * mix


def flanger(x, rate=0.25, depth_ms=3.0, feedback=0.3, mix=0.5):
    length = len(x)
    idx = np.arange(length, dtype=np.float64)
    tt = idx / SR
    mod = (0.001 + (depth_ms / 1000.0) * 0.5 * (1.0 + np.sin(TWO_PI * rate * tt)))
    wet = np.interp(idx - mod * SR, idx, x, left=0.0, right=0.0)
    wet = wet + feedback * np.interp(idx - mod * SR * 2.0, idx, x, left=0.0, right=0.0)
    return x * (1.0 - mix) + wet * mix


def saturate(x, drive=2.0, mode="tanh"):
    """Weight and glue. Everything percussive wants a little of this."""
    if mode == "tanh":
        y = np.tanh(x * drive) / math.tanh(drive) if drive > 0 else x
    elif mode == "cubic":
        v = np.clip(x * drive, -1.0, 1.0)
        y = 1.5 * v - 0.5 * v ** 3
    else:  # "fold"
        v = x * drive
        y = np.sin(v * (math.pi / 2.0))
    return y


def softclip(x, threshold=0.85):
    """Knee-limited clip; leaves everything under `threshold` untouched."""
    a = np.abs(x)
    over = a > threshold
    y = np.array(x, dtype=np.float64)
    if np.any(over):
        excess = a[over] - threshold
        y[over] = np.sign(x[over]) * (threshold + (1.0 - threshold) * np.tanh(excess / (1.0 - threshold)))
    return y


def compress(x, threshold_db=-18.0, ratio=4.0, attack=0.005, release=0.12, makeup_db=None):
    """Feed-forward compressor with an envelope-follower sidechain."""
    eps = 1e-9
    env = np.abs(x)
    a_c = math.exp(-1.0 / max(1.0, attack * SR))
    r_c = math.exp(-1.0 / max(1.0, release * SR))
    # One-pole follower, split attack/release. Vectorised approximation:
    # run the fast (attack) smoother, then a slower release smoother on top.
    fast = _onepole(env, a_c)
    slow = _onepole(np.maximum(env, fast), r_c)
    det = np.maximum(fast, slow)
    lvl = 20.0 * np.log10(det + eps)
    over = np.maximum(0.0, lvl - threshold_db)
    gain_db = -over * (1.0 - 1.0 / max(1.0001, ratio))
    y = x * (10.0 ** (gain_db / 20.0))
    if makeup_db is None:
        makeup_db = -threshold_db * (1.0 - 1.0 / max(1.0001, ratio)) * 0.5
    return y * (10.0 ** (makeup_db / 20.0))


def _onepole(v, coef):
    """y[n] = (1-c) v[n] + c y[n-1], started in STEADY STATE at v[0].

    With scipy's default zero initial state the smoother starts at ~0 and
    climbs over the release time, which - applied as a gain - faded in the
    first ~150 ms of every cue and flattened every attack in the pack.
    """
    if len(v) == 0:
        return v
    zi = sps.lfiltic([1.0 - coef], [1.0, -coef], y=[v[0]], x=[v[0]])
    out, _ = sps.lfilter([1.0 - coef], [1.0, -coef], v, zi=zi)
    return out


def _safe_band(lo, hi):
    """Clamp a band-noise edge pair inside (20 Hz, Nyquist) with lo < hi."""
    hi = min(float(hi), SR * 0.45)
    lo = min(float(lo), hi / 1.5)
    return max(20.0, lo), max(hi, lo * 1.5)


def limit(x, ceiling_db=-1.0, release=0.05):
    """Brickwall-ish limiter, no lookahead (so no pre-ringing, tiny overshoot
    is caught by the softclip at the end). Deterministic and cheap."""
    ceil = 10.0 ** (ceiling_db / 20.0)
    env = np.abs(x)
    r_c = math.exp(-1.0 / max(1.0, release * SR))
    smoothed = _onepole(env, r_c)
    det = np.maximum(env, smoothed)
    gain = np.minimum(1.0, ceil / (det + 1e-9))
    # Smooth the gain so it does not distort on transients.
    gain = _onepole(gain, r_c)
    gain = np.minimum(gain, np.minimum(1.0, ceil / (det + 1e-9)))
    y = x * gain
    return softclip(y, ceil * 0.999)


def mid_side(mid, side):
    """M/S -> L/R."""
    length = max(len(mid), len(side))
    m = fit(mid, length / SR)
    s = fit(side, length / SR)
    return np.stack([m + s, m - s], axis=1)


def haas(x, delay_ms=12.0, side_gain=0.7):
    """Cheap width: one ear hears a copy ~10 ms late. Mono-safe enough."""
    d = int(round(delay_ms / 1000.0 * SR))
    left = np.concatenate([x, np.zeros(d)])
    right = np.concatenate([np.zeros(d), x * side_gain])
    return np.stack([left, right], axis=1)


def stereo_width(x, width=0.6, delay_ms=9.0, seed=11):
    """Stereo from a mono source: decorrelate with a short allpass + Haas.

    Collapses to (almost) the original in mono, which matters because
    Roblox 3D sounds are played mono.
    """
    if x.ndim == 2:
        left, right = x[:, 0], x[:, 1]
    else:
        d = int(round(delay_ms / 1000.0 * SR))
        shifted = np.concatenate([np.zeros(d), x])[: len(x)]
        left = x + width * 0.5 * shifted
        right = x - width * 0.5 * shifted
    out = np.stack([left, right], axis=1)
    peak = np.max(np.abs(out))
    return out / peak if peak > 0 else out


def tremolo(x, rate=5.0, depth=0.4, shape="sine"):
    tt = np.arange(len(x)) / SR
    lfo = np.sin(TWO_PI * rate * tt) if shape == "sine" else sps.square(TWO_PI * rate * tt)
    return x * (1.0 - depth * 0.5 * (1.0 - lfo))


def vibrato(x, rate=5.0, depth_cents=25.0):
    """Pitch wobble by reading the buffer at a modulated rate."""
    length = len(x)
    idx = np.arange(length, dtype=np.float64)
    tt = idx / SR
    ratio = 2.0 ** ((depth_cents / 1200.0) * np.sin(TWO_PI * rate * tt))
    pos = np.cumsum(ratio)
    pos = pos / pos[-1] * (length - 1) if pos[-1] > 0 else idx
    return np.interp(pos, idx, x)


def bitcrush(x, bits=8, downsample=1):
    levels = float(2 ** max(1, int(bits)))
    y = np.round(x * levels) / levels
    if downsample > 1:
        k = int(downsample)
        y = np.repeat(y[::k], k)[: len(x)]
        if len(y) < len(x):
            y = np.concatenate([y, np.zeros(len(x) - len(y))])
    return y


# ---------------------------------------------------------------------------
# 7. utilities
# ---------------------------------------------------------------------------

def fit(x, dur):
    """Truncate or zero-pad `x` to exactly `dur` seconds."""
    length = n(dur)
    x = np.asarray(x, dtype=np.float64)
    if len(x) == length:
        return x
    if len(x) > length:
        return x[:length].copy()
    return np.concatenate([x, np.zeros(length - len(x))])


def mix(*signals):
    """Sum signals of any lengths; the result is as long as the longest."""
    sigs = [np.asarray(s, dtype=np.float64) for s in signals if s is not None and len(s)]
    if not sigs:
        return np.zeros(0)
    length = max(len(s) for s in sigs)
    out = np.zeros(length)
    for s in sigs:
        out[: len(s)] += s
    return out


def place(dest, x, at_seconds):
    """Add `x` into `dest` starting at `at_seconds`, growing `dest` if needed."""
    start = max(0, int(round(float(at_seconds) * SR)))
    x = np.asarray(x, dtype=np.float64)
    need = start + len(x)
    if len(dest) < need:
        dest = np.concatenate([dest, np.zeros(need - len(dest))])
    else:
        dest = np.array(dest, dtype=np.float64, copy=True)
    dest[start:need] += x
    return dest


def concat(signals, gap=0.0):
    """End-to-end with an optional silent gap. Used to build sprite sheets."""
    parts = []
    pad = silence(gap) if gap > 0 else None
    for i, s in enumerate(signals):
        parts.append(np.asarray(s, dtype=np.float64))
        if pad is not None and i < len(signals) - 1:
            parts.append(pad)
    return np.concatenate(parts) if parts else np.zeros(0)


def crossfade(a, b, dur):
    """Equal-power crossfade: `b` starts `dur` before `a` ends."""
    k = min(n(dur), len(a), len(b))
    if k <= 0:
        return np.concatenate([a, b])
    fo = np.cos(np.linspace(0.0, math.pi / 2.0, k))
    fi = np.sin(np.linspace(0.0, math.pi / 2.0, k))
    head = a[: len(a) - k]
    tail = a[len(a) - k:] * fo + b[:k] * fi
    return np.concatenate([head, tail, b[k:]])


def fade(x, in_s=0.003, out_s=0.003):
    """Click insurance. EVERY cue goes through this before it hits a sheet."""
    y = np.array(x, dtype=np.float64, copy=True)
    ni = min(n(in_s), len(y)) if in_s > 0 else 0
    no = min(n(out_s), len(y)) if out_s > 0 else 0
    if ni:
        y[:ni] *= np.linspace(0.0, 1.0, ni) ** 0.5
    if no:
        y[len(y) - no:] *= np.linspace(1.0, 0.0, no) ** 0.5
    return y


def dc_block(x, cutoff=20.0):
    """Remove DC and subsonic content. A cue with DC wastes headroom and
    thumps the speaker when the sprite jumps to it."""
    return highpass(x, cutoff, order=2)


def db(x):
    """Peak level of `x` in dBFS."""
    peak = float(np.max(np.abs(x))) if len(x) else 0.0
    return -np.inf if peak <= 0 else 20.0 * math.log10(peak)


def amp_db(x_db):
    return 10.0 ** (float(x_db) / 20.0)


def normalize(x, peak_db=-1.0):
    """Peak-normalise to `peak_db` dBFS."""
    peak = float(np.max(np.abs(x))) if len(x) else 0.0
    if peak <= 0:
        return np.asarray(x, dtype=np.float64)
    return np.asarray(x, dtype=np.float64) * (amp_db(peak_db) / peak)


def loudness(x):
    """LUFS-ish: K-weighted RMS. Not ITU-exact, but monotone with it and
    stable, which is all the mastering chain needs."""
    mono = x.mean(axis=1) if x.ndim == 2 else x
    if len(mono) < 32:
        return -np.inf
    # K-weighting approximation: high shelf + high-pass.
    y = highpass(mono, 60.0, order=2)
    y = y + highpass(y, 1500.0, order=2) * 0.7
    r = float(np.sqrt(np.mean(y ** 2)))
    return -np.inf if r <= 0 else 20.0 * math.log10(r) - 0.7


def normalize_lufs(x, target=-16.0, peak_db=-1.0):
    """Loudness-match, then guarantee the peak ceiling with the limiter."""
    cur = loudness(x)
    y = np.asarray(x, dtype=np.float64)
    if np.isfinite(cur):
        y = y * amp_db(target - cur)
    if y.ndim == 2:
        left = limit(y[:, 0], peak_db)
        right = limit(y[:, 1], peak_db)
        y = np.stack([left, right], axis=1)
    else:
        y = limit(y, peak_db)
    return y


def pitch_play(x, ratio):
    """Play a one-shot back at a different rate (pitch AND length change).

    For one-shots this is exactly what a sampler does and it is free; use
    it for footstep variants and creature-size pitch offsets.
    """
    ratio = max(0.05, float(ratio))
    length = len(x)
    out_len = max(1, int(round(length / ratio)))
    pos = np.arange(out_len) * ratio
    return np.interp(pos, np.arange(length), x, left=0.0, right=0.0)


def reverse(x):
    return np.asarray(x, dtype=np.float64)[::-1].copy()


def clip_report(x, name=""):
    """Diagnostics for the 'listen by numbers' pass: peak, DC, clipping."""
    mono = x.mean(axis=1) if x.ndim == 2 else x
    peak = float(np.max(np.abs(mono))) if len(mono) else 0.0
    dc = float(np.mean(mono)) if len(mono) else 0.0
    clipped = int(np.sum(np.abs(mono) >= 0.999))
    return {
        "name": name,
        "peak_db": round(db(mono), 2),
        "dc": round(dc, 6),
        "clipped_samples": clipped,
        "seconds": round(len(mono) / SR, 3),
        "rms_db": round(20.0 * math.log10(float(np.sqrt(np.mean(mono ** 2))) + 1e-12), 2),
    }


# ---------------------------------------------------------------------------
# 8. output
# ---------------------------------------------------------------------------

def _prep(audio, stereo):
    a = np.asarray(audio, dtype=np.float64)
    if stereo and a.ndim == 1:
        a = np.stack([a, a], axis=1)
    if not stereo and a.ndim == 2:
        a = a.mean(axis=1)
    a = np.clip(a, -1.0, 1.0)
    return a.astype(np.float32)


def write_ogg(path, audio, stereo=False):
    """Vorbis OGG at 44.1 kHz. The delivery format for everything shipped."""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    data = _prep(audio, stereo)
    # libsndfile 1.2.2 segfaults on a single Vorbis write past ~4.18 M frames
    # (a 95 s stereo theme), silently killing the build. Streaming the file
    # in blocks through SoundFile keeps every write well under that.
    block = 1 << 20
    with sf.SoundFile(path, mode="w", samplerate=SR, channels=data.shape[1] if data.ndim == 2 else 1,
                      format="OGG", subtype="VORBIS") as fh:
        for i in range(0, len(data), block):
            fh.write(data[i:i + block])
    return path


def write_wav(path, audio, stereo=False):
    """16-bit WAV - previews and the showreel, never shipped to Roblox."""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    sf.write(path, _prep(audio, stereo), SR, subtype="PCM_16")
    return path
