"""music_ambience.py - the nine ambience beds (CONTRACT.md §4).

A bed is NOT music. There is no melody, no pulse and no key anywhere in
this file: every one of the nine is built from noise, filters and slow
modulation, plus sparse one-shot events (gulls, drips, ticks, thunder). The
theme sits over the bed, so anything pitched down here would fight it.

WHAT EACH BED IS MADE OF

    amb_sea       swell + low wind + far gulls + deep surge
    amb_clear     near surf with crests + palm rustle + gulls + lapping
    amb_mist      insect clusters + drips + frog blips + murk + still air
    amb_blizzard  howl (two bands) + gusts + ice ticks + snow hiss
    amb_ash       low roar + crackle bursts + fumarole hisses + ground rumble
    amb_summit    thin high wind + sub rumble + rare gust, and not much else
    amb_ghost     hull creaks + a low moan + water lapping + rigging ticks
    amb_storm     rain wall + thunder rolls + surge + wind
    amb_gloom     pressure hum (detuned subs) + drips + far clicks + a whoosh
    amb_heartchamber  a 45 BPM sub heartbeat + magma glow + drips on hot
                  stone, in a small room. An interior: no wind layer.

LOOP SAFETY, WHICH IS THE WHOLE ENGINEERING PROBLEM HERE.

Two separate mechanisms, because there are two kinds of layer:

1. CONTINUOUS layers (wind, swell, hum) are exactly `dur` long and every
   LFO driving them completes a WHOLE number of cycles in `dur`, so the
   modulation arriving at sample 0 is the modulation that was leaving at
   sample N-1. `_cyc` is the only oscillator used for that, and it takes
   the cycle COUNT, never a frequency, so the constraint cannot be broken
   by editing a number.
2. EVENT layers (a gull, a drip, a thunder roll) are placed anywhere in
   [0, dur) into a buffer that is `dur + TAIL` long, reverberated with the
   tail left on, and folded by `music.loop_wrap`. An event that starts a
   second before the loop point therefore CONTINUES across it.

Every filter also gets `PRE` seconds of pre-roll that is thrown away, so no
layer opens with an IIR settling transient - which would otherwise be an
audible "wff" once per loop, and only at the loop point.

They are quiet on purpose. build.py normalises these to -24 LUFS, about
8 dB under the themes, which is where a bed belongs under music and SFX.
"""

import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import music as M  # noqa: E402
import synth as S  # noqa: E402

PRE = 1.5          # seconds of discarded filter pre-roll
TAIL = 6.0         # reverb overhang folded back under the head


# ---------------------------------------------------------------------------
# the texture toolkit
# ---------------------------------------------------------------------------

def _cyc(length, cycles, dur, phase=0.0, pre=0):
    """A sine completing exactly `cycles` cycles in `dur` seconds.

    Evaluated over `length` samples starting `pre` samples BEFORE t=0, so a
    pre-rolled filter sees the correct continuation of the curve. Because
    the count is an integer, the value at sample N is the value at sample 0
    - which is what makes the loop seamless.
    """
    idx = np.arange(length, dtype=np.float64) - float(pre)
    return np.sin(2.0 * np.pi * (float(cycles) * idx / S.n(dur) + phase))


def _uni(length, cycles, dur, phase=0.0, pre=0):
    """`_cyc` mapped to 0..1."""
    return 0.5 + 0.5 * _cyc(length, cycles, dur, phase, pre)


SLOPE = {"white": 0.0, "pink": 1.0, "brown": 2.0}


def _pnoise(dur, r, colour="pink"):
    """Noise that is EXACTLY periodic in `dur`.

    synth's `pink`/`brown` are perfectly good noise and completely unusable
    here: their low-frequency content at t=0 has nothing to do with their
    content at t=dur, so a bed built on them thumps once a loop even though
    its envelopes line up. (The high band gets away with it - one noise
    sample next to an uncorrelated one is just noise - but a rumble layer
    jumping half its amplitude is a click you feel rather than hear.)

    Built instead as an inverse FFT of a 1/f^slope magnitude spectrum with
    random phases: every component completes a whole number of cycles in
    the buffer by construction, so sample N IS sample 0.
    """
    length = S.n(dur)
    freqs = np.fft.rfftfreq(length, 1.0 / S.SR)
    mag = np.zeros_like(freqs)
    mag[1:] = freqs[1:] ** (-SLOPE[colour] * 0.5)
    phase = r.random(len(freqs)) * 2.0 * np.pi
    x = np.fft.irfft(mag * np.exp(1j * phase), length)
    return x / (np.max(np.abs(x)) + 1e-12)


def _ploop(x, pre_n):
    """Prepend the buffer's own tail as filter pre-roll.

    For a periodic buffer this is not an approximation: the samples before
    t=0 on the previous pass ARE the last `pre_n` samples, so an IIR fed
    this way reaches t=0 in exactly the state it will be in at the loop
    point. That is what makes a FILTERED periodic layer periodic too.
    """
    return np.concatenate([x[len(x) - pre_n:], x])


def _swell(dur, r, cycles=10, lo=120.0, hi=1100.0, colour="pink", depth=0.7):
    """Slow LP-swept noise - the ocean. `cycles` sets the period: 10 cycles
    in 84 s is one swell every 8.4 s, which is the brief's 6-10 s."""
    p = S.n(PRE)
    src = _ploop(_pnoise(dur, r, colour), p)
    cut = lo * (hi / lo) ** _uni(len(src), cycles, dur, pre=p)
    y = S.lp_sweep(src, cut, order=2)[p:]
    amp = 1.0 - depth + depth * _uni(S.n(dur), cycles, dur)
    return y * amp


def _wind(dur, r, low=300.0, high=3000.0, gusts=7, swirl=11, depth=0.6,
          sweep=0.55):
    """Band-limited noise with a swept top and two gust LFOs at coprime
    cycle counts, so the gusts never land in the same place twice."""
    p = S.n(PRE)
    src = S.highpass(_ploop(_pnoise(dur, r, "white"), p), low, order=2)
    cut = high * (1.0 - sweep + sweep * _uni(len(src), gusts, dur, pre=p))
    y = S.lp_sweep(src, cut, order=2)[p:]
    n_out = S.n(dur)
    amp = (1.0 - depth) + depth * (0.6 * _uni(n_out, gusts, dur)
                                   + 0.4 * _uni(n_out, swirl, dur, phase=0.3))
    return y * amp


def _hum(dur, r, freqs, detune_cents=7.0, wobble=3):
    """Detuned sub sines. Frequencies are SNAPPED to a whole number of
    cycles in `dur`, so each one is periodic in the loop by construction."""
    n_out = S.n(dur)
    out = np.zeros(n_out)
    for i, f in enumerate(freqs):
        for k, cents in enumerate((-detune_cents, 0.0, detune_cents)):
            hz = f * (2.0 ** (cents / 1200.0))
            cycles = max(1.0, round(hz * float(dur)))       # snap to the loop
            out += np.sin(2.0 * np.pi * cycles * np.arange(n_out) / n_out
                          + 0.37 * (i * 3 + k)) * (0.5 if k == 1 else 0.3)
    out /= max(1.0, len(freqs) * 1.1)
    return out * (0.75 + 0.25 * _uni(n_out, wobble, dur))


def _rumble(dur, r, cut=90.0, cycles=5, depth=0.5):
    """Sub-audible ground/water movement. Brown noise, hard low-passed."""
    p = S.n(PRE)
    y = S.lowpass(_ploop(_pnoise(dur, r, "brown"), p), cut, order=2)[p:]
    return y * ((1.0 - depth) + depth * _uni(S.n(dur), cycles, dur))


def _hiss(dur, r, low=4000.0, high=13000.0, cycles=13, depth=0.8):
    """Air, rain-adjacent, snow. Bright, thin, and always modulated - a
    static hiss is the single most fatiguing thing a bed can contain."""
    p = S.n(PRE)
    y = S.bandpass(_ploop(_pnoise(dur, r, "white"), p), low, high, order=2)[p:]
    n_out = S.n(dur)
    amp = ((1.0 - depth) + depth * (0.5 * _uni(n_out, cycles, dur)
                                    + 0.5 * _uni(n_out, cycles + 5, dur, 0.2)))
    return y * amp


# -- one-shot event generators. Each returns a short mono array. -----------

def _gull(r, far=1.0):
    """A gull cry: a formant-filtered saw bent down through its own call."""
    d = 0.22 + 0.26 * float(r.random())
    f0 = 780.0 + 620.0 * float(r.random())
    bend = S.breakpoints(d, [(0.0, f0 * 1.35), (d * 0.18, f0 * 1.7),
                             (d * 0.55, f0 * 0.92), (d, f0 * 0.72)], curve="exp")
    src = S.saw(d, bend, bright=0.45) * 0.6 + S.white(d, r) * 0.15
    y = S.formant(src, [620.0, 1750.0, 3100.0], qs=[10.0, 8.0, 6.0],
                  gains=[1.0, 0.7, 0.3])
    y *= S.breakpoints(d, [(0.0, 0.0), (0.02, 1.0), (d * 0.45, 0.75),
                           (d * 0.8, 0.5), (d, 0.0)])
    y = S.lowpass(y, 6000.0 / max(1.0, far), order=2)
    peak = np.max(np.abs(y)) + 1e-12
    return S.fade(y / peak, 0.006, 0.03)


def _tick_cluster(r, count=5, low=5200.0, high=12000.0, spread=0.05):
    """A short burst of high ticks - insects, ice, distant clicks."""
    span = spread * count + 0.08
    out = S.silence(span)
    for _ in range(int(count)):
        d = 0.004 + 0.006 * float(r.random())
        one = S.band_noise(d, r, low, high, order=3) * S.perc_env(d, 0.0002, d * 0.35)
        out = S.place(out, one * (0.4 + 0.6 * float(r.random())),
                      float(r.random()) * spread * count)
    peak = np.max(np.abs(out)) + 1e-12
    return out / peak


def _crackle(r, count=9, low=900.0, high=7000.0, span=0.5):
    """Fire: a burst of short, low-mid snaps at irregular intervals."""
    out = S.silence(span + 0.1)
    for _ in range(int(count)):
        d = 0.006 + 0.02 * float(r.random())
        one = S.band_noise(d, r, low, high, order=3) * S.perc_env(d, 0.0003, d * 0.3)
        one = S.saturate(one * 1.4, 1.6)
        out = S.place(out, one * (0.3 + 0.7 * float(r.random())),
                      float(r.random()) ** 1.6 * span)
    peak = np.max(np.abs(out)) + 1e-12
    return out / peak


def _thunder_roll(r, far=1.0):
    """A roll, not a crack: low noise with a slow attack and a long, darker
    decay, plus a second, later body so it reads as distance."""
    d = 3.2 + 3.4 * float(r.random())
    body = S.brown(d, r)
    body = S.lowpass(body, 130.0 + 220.0 / max(1.0, far), order=2)
    env = S.breakpoints(d, [(0.0, 0.0), (0.10, 0.55), (0.45, 1.0),
                            (d * 0.35, 0.45), (d * 0.7, 0.18), (d, 0.0)])
    y = body * env
    late = S.lowpass(S.brown(d, r), 90.0, order=2)
    y = S.mix(y, late * S.breakpoints(d, [(0.0, 0.0), (d * 0.4, 0.5),
                                          (d * 0.75, 0.25), (d, 0.0)]) * 0.7)
    peak = np.max(np.abs(y)) + 1e-12
    return S.fade(y / peak, 0.05, 0.4)


def _drip(r):
    """A drip in a cave: a bubble with a resonant afterglow."""
    d = 0.10 + 0.10 * float(r.random())
    f = 320.0 + 700.0 * float(r.random())
    y = S.bubble(d, f, r, rise=1.8 + 1.8 * float(r.random()))
    y = S.mix(y, S.resonator(y, f * 2.0, q=24.0) * 0.3)
    peak = np.max(np.abs(y)) + 1e-12
    return S.fade(y / peak, 0.002, 0.02)


def _frog(r):
    """A croak: a low buzz through two formants. Not a pitch - a texture."""
    d = 0.12 + 0.14 * float(r.random())
    f = 90.0 + 60.0 * float(r.random())
    src = S.pulse(d, f, 0.3) * 0.5 + S.white(d, r) * 0.2
    y = S.formant(src, [430.0, 980.0], qs=[9.0, 7.0], gains=[1.0, 0.5])
    y *= S.tremolo(np.ones(S.n(d)), rate=34.0, depth=0.8)
    y *= S.breakpoints(d, [(0.0, 0.0), (0.015, 1.0), (d * 0.7, 0.6), (d, 0.0)])
    peak = np.max(np.abs(y)) + 1e-12
    return S.fade(y / peak, 0.004, 0.02)


def _lap(r, level=0.5):
    """Water against something: a scatter of small bubbles and a soft wash."""
    d = 0.5 + 0.5 * float(r.random())
    y = S.wet_texture(d, r, density=18.0, freq=460.0, spread=2.4, level=level)
    y = S.mix(y, S.band_noise(d, r, 700.0, 4200.0)
              * S.breakpoints(d, [(0.0, 0.0), (0.08, 0.5), (d, 0.0)]) * 0.5)
    peak = np.max(np.abs(y)) + 1e-12
    return S.fade(y / peak, 0.01, 0.08)


def _crest(r):
    """A wave breaking - the transient that turns a swell into surf."""
    d = 1.1 + 0.7 * float(r.random())
    x = S.band_noise(d, r, 400.0, 9000.0, order=3)
    x = S.lp_sweep(x, S.expsweep(d, 7000.0, 500.0), order=2)
    x *= S.breakpoints(d, [(0.0, 0.0), (0.06, 1.0), (d * 0.4, 0.35), (d, 0.0)],
                       curve="exp")
    peak = np.max(np.abs(x)) + 1e-12
    return S.fade(x / peak, 0.01, 0.1)


def _creak(r):
    """A hull or a rope taking load."""
    d = 0.5 + 0.7 * float(r.random())
    f = 120.0 + 220.0 * float(r.random())
    y = M.rope_creak(f, d, 0.8, r)
    y = S.lowpass(y, 3000.0, order=2)
    peak = np.max(np.abs(y)) + 1e-12
    return y / peak


def _groan(r):
    """A long low moan - timber, or something that used to be a ship."""
    d = 2.5 + 2.0 * float(r.random())
    f = 48.0 + 26.0 * float(r.random())
    bend = S.breakpoints(d, [(0.0, f), (d * 0.5, f * 1.09), (d, f * 0.94)])
    y = S.saw(d, bend, bright=0.25) * 0.5 + S.sine(d, bend * 2.0) * 0.25
    y = S.lowpass(y, 420.0, order=2)
    y = S.vibrato(y, rate=0.7, depth_cents=22.0)
    y *= S.breakpoints(d, [(0.0, 0.0), (d * 0.3, 1.0), (d * 0.65, 0.7), (d, 0.0)])
    peak = np.max(np.abs(y)) + 1e-12
    return S.fade(y / peak, 0.15, 0.5)


def _far_clang(r):
    """Something metal, a long way off, in water."""
    d = 1.8 + 1.4 * float(r.random())
    y = S.metal_hit(d, r, freq=90.0 + 150.0 * float(r.random()), ring=0.9,
                    roughness=0.8)
    y = S.lowpass(y, 900.0, order=2)
    peak = np.max(np.abs(y)) + 1e-12
    return S.fade(y / peak, 0.01, 0.2)


# ---------------------------------------------------------------------------
# assembly
# ---------------------------------------------------------------------------

class Bed(object):
    """Two buses, and the difference between them is the whole design.

    CONTINUOUS bus - exactly `dur` long, and periodic in `dur` by
    construction (periodic noise, whole-cycle LFOs, filters pre-rolled with
    the buffer's own tail). It is never extended past the loop point and it
    is never folded, because it does not end: sample N of it IS sample 0.

    EVENT bus - `dur + tail` long, holding one-shots and their reverb. It
    IS folded by `loop_wrap`, which is how a gull that cries a second
    before the loop point finishes its cry after it.

    Mixing the two into one buffer and folding the lot is the obvious
    implementation and it is wrong: `loop_wrap` adds everything past the
    loop point onto the head, so a continuous layer - which stops dead at
    the loop point rather than decaying - gets its own last value added to
    its first. On the dark beds, where the content is nearly all sub-100 Hz,
    that was a 0.13 step at sample 0, an order of magnitude bigger than any
    real transition in the file. Keeping the buses apart until after the
    fold removes it completely.
    """

    def __init__(self, dur, tail=TAIL):
        self.dur = float(dur)
        self.tail = float(tail)
        self.n_body = S.n(dur)
        self.n_full = S.n(dur + tail)
        self.cont = [np.zeros(self.n_body), np.zeros(self.n_body)]
        self.evt = [np.zeros(self.n_full), np.zeros(self.n_full)]

    @staticmethod
    def _pan(pan):
        th = (float(np.clip(pan, -1.0, 1.0)) + 1.0) * (np.pi / 4.0)
        return float(np.cos(th)) * 1.414, float(np.sin(th)) * 1.414

    def layer(self, mono, gain=1.0, pan=0.0):
        """Add a continuous, loop-periodic layer. `pan` -1..1, equal power."""
        x = S.fit(np.asarray(mono, dtype=np.float64), self.n_body / S.SR)
        gl, gr = self._pan(pan)
        self.cont[0] += x * gain * gl
        self.cont[1] += x * gain * gr
        return self

    def event(self, mono, at, gain=1.0, pan=0.0):
        """Place a one-shot. It may run past the loop point; the fold in
        `render` carries it across the seam."""
        gl, gr = self._pan(pan)
        x = np.asarray(mono, dtype=np.float64) * gain
        self.evt[0] = S.place(self.evt[0], x * gl, at)
        self.evt[1] = S.place(self.evt[1], x * gr, at)
        return self

    def scatter(self, make, r, count, gain=1.0, spread=0.9, start=0.0,
                gain_jitter=0.5, reverb=None):
        """`count` one-shots at random times in [start, dur), each panned
        somewhere in +-`spread`. Deterministic: the rng draw order is fixed
        by the loop, never by sorting or by wall time."""
        span = self.dur - start
        for _ in range(int(count)):
            at = start + float(r.random()) * span
            one = make(r)
            if reverb is not None:
                size, damp, mixv = reverb
                one = S.reverb(one, size=size, damping=damp, mix=mixv, seed=7)
            g = gain * (1.0 - gain_jitter + gain_jitter * 2.0 * float(r.random()))
            self.event(one, at, g, pan=(float(r.random()) * 2.0 - 1.0) * spread)
        return self

    def _pre(self, x, fn, pre=PRE):
        """Run a filter (or the room) on a PERIODIC buffer with the buffer's
        own tail as pre-roll.

        A filter starts from rest, and something that starts from rest at
        sample 0 and nowhere else IS the loop seam: a 20 Hz high-pass takes
        ~60 ms to settle, a 3 s room takes its whole impulse response. For a
        periodic buffer the samples preceding t=0 are exactly its last
        samples, so this is not an approximation - the filter arrives at
        t=0 in the state it will really be in.
        """
        p = min(S.n(pre), len(x))
        return fn(np.concatenate([x[len(x) - p:], x]))[p:]

    def render(self, room=None, hp=20.0, lp=None):
        """Filter both buses, fold the event bus, sum, limit.

        The two sides get DIFFERENT reverb seeds - two rooms of the same
        size but different early reflections - which is where the width of
        these beds comes from. Nothing here is a stereo widener; a Haas
        copy would collapse the moment Roblox plays the bed in mono.
        """
        out = []
        for ch, room_seed in ((0, 7), (1, 9)):
            steps = [(lambda x: S.highpass(x, hp, order=2), PRE)]
            if lp:
                steps.append((lambda x: S.lowpass(x, lp, order=2), PRE))
            if room:
                size, damp, mixv = room
                # make_ir is 1.6*size long, so the room needs at least that
                # much history before t=0 or it fades itself in at the loop.
                steps.append((lambda x: S.reverb(x, size=size, damping=damp,
                                                 mix=mixv, seed=room_seed,
                                                 tail=False),
                              max(PRE, size * 2.0)))

            cont = self.cont[ch]
            evt = S.fit(self.evt[ch], self.n_full / S.SR)
            for fn, pre in steps:
                cont = self._pre(cont, fn, pre)   # periodic: exact pre-roll
                evt = fn(evt)                     # starts from silence: correct

            # Anything still sounding at the very end of the overhang (a
            # thunder roll placed a second before the loop point, a 4 s
            # event reverb) is taken down gently. Cut instead, it would land
            # in the head as a step `tail` seconds after the loop.
            evt = S.fit(evt, self.n_full / S.SR)
            taper = S.n(0.6)
            evt[len(evt) - taper:] *= np.linspace(1.0, 0.0, taper) ** 0.6
            out.append(S.fit(cont, self.n_body / S.SR)
                       + M.loop_wrap(evt, self.tail, fade_in=0.0))
        return np.stack([S.limit(out[0], -3.0), S.limit(out[1], -3.0)], axis=1)


# ---------------------------------------------------------------------------
# the nine beds
# ---------------------------------------------------------------------------

def amb_sea(r):
    """Open water. Swell every 8.4 s, a low steady wind, gulls a long way off."""
    dur = 84.0
    bed = Bed(dur)
    bed.layer(_swell(dur, r, cycles=10, lo=110.0, hi=800.0), 0.62, pan=-0.55)
    bed.layer(_swell(dur, r, cycles=7, lo=90.0, hi=620.0), 0.55, pan=0.55)
    bed.layer(_wind(dur, r, low=220.0, high=1700.0, gusts=5, swirl=8, depth=0.5),
              0.16, pan=0.15)
    bed.layer(_rumble(dur, r, cut=70.0, cycles=3, depth=0.6), 0.40)
    bed.layer(_hiss(dur, r, low=3000.0, high=9000.0, cycles=9, depth=0.85), 0.05)
    bed.scatter(lambda rr: _gull(rr, far=1.6), r, 7, gain=0.10, spread=0.95,
                reverb=(2.6, 0.4, 0.5))
    bed.scatter(_lap, r, 9, gain=0.10, spread=0.7)
    return bed.render(room=(1.8, 0.45, 0.16), hp=22.0)


def amb_clear(r):
    """The cove. Nearer surf with crests you can hear break, palms, gulls."""
    dur = 72.0
    bed = Bed(dur)
    bed.layer(_swell(dur, r, cycles=9, lo=180.0, hi=1900.0, depth=0.75), 0.55, pan=-0.5)
    bed.layer(_swell(dur, r, cycles=12, lo=150.0, hi=1500.0, depth=0.7), 0.48, pan=0.5)
    bed.layer(_rumble(dur, r, cut=90.0, cycles=4, depth=0.5), 0.26)
    # Palms: bright, thin, gusting on a different period from the surf.
    bed.layer(_hiss(dur, r, low=2600.0, high=11000.0, cycles=7, depth=0.9), 0.11, pan=0.35)
    bed.layer(_hiss(dur, r, low=3400.0, high=13000.0, cycles=11, depth=0.9), 0.09, pan=-0.4)
    bed.scatter(_crest, r, 11, gain=0.16, spread=0.8)
    bed.scatter(lambda rr: _gull(rr, far=1.1), r, 13, gain=0.13, spread=0.95,
                reverb=(1.6, 0.45, 0.35))
    bed.scatter(_lap, r, 16, gain=0.13, spread=0.75)
    return bed.render(room=(1.2, 0.5, 0.14), hp=24.0)


def amb_mist(r):
    """The fen. Insects in clusters, drips, croaks, and almost no air movement."""
    dur = 78.0
    bed = Bed(dur)
    bed.layer(_rumble(dur, r, cut=110.0, cycles=3, depth=0.7), 0.30)
    bed.layer(_swell(dur, r, cycles=6, lo=80.0, hi=420.0, colour="brown",
                     depth=0.6), 0.34, pan=-0.25)
    bed.layer(_wind(dur, r, low=400.0, high=1400.0, gusts=4, swirl=7, depth=0.75),
              0.07, pan=0.3)
    bed.layer(_hiss(dur, r, low=5000.0, high=9000.0, cycles=17, depth=0.95), 0.035)
    # Insects: many small clusters, most of them quiet, all of them high.
    bed.scatter(lambda rr: _tick_cluster(rr, count=4 + int(rr.random() * 6),
                                         low=5800.0, high=12500.0, spread=0.045),
                r, 42, gain=0.055, spread=0.95)
    bed.scatter(_drip, r, 22, gain=0.13, spread=0.85, reverb=(1.9, 0.35, 0.4))
    bed.scatter(_frog, r, 15, gain=0.15, spread=0.8, reverb=(2.2, 0.4, 0.35))
    return bed.render(room=(1.6, 0.5, 0.18), hp=26.0, lp=13000.0)


def amb_blizzard(r):
    """Frostmaw in weather. Two howl bands beating against each other, ice."""
    dur = 72.0
    bed = Bed(dur)
    bed.layer(_wind(dur, r, low=260.0, high=3600.0, gusts=6, swirl=11,
                    depth=0.72, sweep=0.7), 0.52, pan=-0.5)
    bed.layer(_wind(dur, r, low=420.0, high=5200.0, gusts=9, swirl=13,
                    depth=0.78, sweep=0.75), 0.44, pan=0.55)
    # The howl: a resonant band that rises and falls with the gusts.
    p = S.n(PRE)
    src = _ploop(_pnoise(dur, r, "white"), p)
    howl = S.bp_sweep(src, 700.0 * (1.0 + 0.9 * _uni(len(src), 5, dur, pre=p)),
                      q=7.0)[p:]
    bed.layer(howl * (0.25 + 0.75 * _uni(S.n(dur), 5, dur)), 0.26, pan=0.2)
    bed.layer(_hiss(dur, r, low=4500.0, high=14000.0, cycles=8, depth=0.85), 0.16)
    bed.layer(_rumble(dur, r, cut=80.0, cycles=4, depth=0.6), 0.28)
    bed.scatter(lambda rr: _tick_cluster(rr, count=2 + int(rr.random() * 4),
                                         low=3800.0, high=11000.0, spread=0.07),
                r, 26, gain=0.075, spread=0.9, reverb=(2.2, 0.3, 0.3))
    return bed.render(room=(2.0, 0.35, 0.14), hp=28.0)


def amb_ash(r):
    """The caldera. A roar under everything, fire crackle, fumaroles venting."""
    dur = 66.0
    bed = Bed(dur)
    bed.layer(_rumble(dur, r, cut=75.0, cycles=3, depth=0.55), 0.62)
    bed.layer(_swell(dur, r, cycles=5, lo=70.0, hi=340.0, colour="brown",
                     depth=0.5), 0.44, pan=-0.3)
    bed.layer(_swell(dur, r, cycles=8, lo=90.0, hi=430.0, colour="brown",
                     depth=0.55), 0.36, pan=0.35)
    # Fumaroles: mid-high hiss that swells and vents rather than blowing.
    bed.layer(_hiss(dur, r, low=1800.0, high=7000.0, cycles=6, depth=0.95), 0.13, pan=0.45)
    bed.layer(_hiss(dur, r, low=2600.0, high=9500.0, cycles=9, depth=0.95), 0.10, pan=-0.5)
    bed.scatter(lambda rr: _crackle(rr, count=6 + int(rr.random() * 10),
                                    span=0.35 + 0.5 * float(rr.random())),
                r, 34, gain=0.085, spread=0.9)
    bed.scatter(lambda rr: _thunder_roll(rr, far=2.4), r, 4, gain=0.16, spread=0.5)
    return bed.render(room=(1.4, 0.55, 0.16), hp=20.0, lp=12000.0)


def amb_summit(r):
    """High and thin. This is the quietest bed in the game and it should be:
    a little air, a lot of nothing, and the mountain underneath it."""
    dur = 72.0
    bed = Bed(dur)
    bed.layer(_wind(dur, r, low=900.0, high=6500.0, gusts=4, swirl=7,
                    depth=0.65, sweep=0.6), 0.30, pan=-0.45)
    bed.layer(_wind(dur, r, low=1200.0, high=8500.0, gusts=6, swirl=9,
                    depth=0.7, sweep=0.65), 0.24, pan=0.5)
    bed.layer(_hiss(dur, r, low=6000.0, high=15000.0, cycles=5, depth=0.9), 0.07)
    bed.layer(_rumble(dur, r, cut=55.0, cycles=2, depth=0.7), 0.34)
    bed.layer(_hum(dur, r, [31.0], detune_cents=5.0, wobble=2), 0.16)
    # Three gusts in seventy seconds. That is the whole event budget.
    bed.scatter(lambda rr: _crest(rr), r, 3, gain=0.05, spread=0.8,
                reverb=(3.0, 0.3, 0.6))
    return bed.render(room=(2.6, 0.3, 0.12), hp=24.0)


def amb_ghost(r):
    """Wreckwater. Hulls working against each other, a moan, water in a hold."""
    dur = 78.0
    bed = Bed(dur)
    bed.layer(_swell(dur, r, cycles=8, lo=90.0, hi=520.0, depth=0.7), 0.42, pan=-0.45)
    bed.layer(_swell(dur, r, cycles=11, lo=80.0, hi=430.0, depth=0.65), 0.36, pan=0.45)
    bed.layer(_rumble(dur, r, cut=70.0, cycles=3, depth=0.6), 0.32)
    bed.layer(_wind(dur, r, low=350.0, high=2200.0, gusts=5, swirl=8, depth=0.8),
              0.10, pan=0.2)
    bed.scatter(_creak, r, 20, gain=0.16, spread=0.9, reverb=(2.4, 0.4, 0.38))
    bed.scatter(_groan, r, 5, gain=0.14, spread=0.45, reverb=(3.2, 0.35, 0.45))
    bed.scatter(_lap, r, 18, gain=0.12, spread=0.8, reverb=(1.8, 0.45, 0.3))
    bed.scatter(lambda rr: _tick_cluster(rr, count=2 + int(rr.random() * 3),
                                         low=2800.0, high=8000.0, spread=0.09),
                r, 14, gain=0.06, spread=0.95, reverb=(2.6, 0.35, 0.4))
    return bed.render(room=(2.4, 0.42, 0.20), hp=24.0, lp=11000.0)


def amb_storm(r):
    """A wall of rain, a heaving sea under it, and thunder rolling away."""
    dur = 66.0
    bed = Bed(dur)
    bed.layer(_hiss(dur, r, low=2200.0, high=13000.0, cycles=7, depth=0.45), 0.44, pan=-0.4)
    bed.layer(_hiss(dur, r, low=1800.0, high=11000.0, cycles=11, depth=0.5), 0.40, pan=0.45)
    bed.layer(_swell(dur, r, cycles=8, lo=120.0, hi=1400.0, depth=0.8), 0.48, pan=0.1)
    bed.layer(_wind(dur, r, low=300.0, high=4200.0, gusts=5, swirl=9,
                    depth=0.7, sweep=0.7), 0.30, pan=-0.2)
    bed.layer(_rumble(dur, r, cut=85.0, cycles=3, depth=0.65), 0.42)
    # Individual heavy drops over the wall, so it is rain and not static.
    bed.scatter(lambda rr: _tick_cluster(rr, count=3 + int(rr.random() * 5),
                                         low=1800.0, high=9000.0, spread=0.03),
                r, 40, gain=0.05, spread=0.95)
    bed.scatter(_crest, r, 9, gain=0.16, spread=0.7)
    bed.scatter(lambda rr: _thunder_roll(rr, far=1.3), r, 5, gain=0.30, spread=0.55,
                reverb=(3.4, 0.3, 0.4))
    return bed.render(room=(1.6, 0.45, 0.14), hp=22.0)


def _heartbeat(r, level=1.0):
    """One beat of something enormous, two chambers: lub, then a softer dub.

    Pitched under 60 Hz and low-passed hard, so it is felt rather than
    heard - there is no click anywhere in it, and no noise above 200 Hz,
    which is what keeps it from reading as a kick drum.
    """
    d = 1.05
    out = S.silence(d)
    for at, f0, f1, g, tau in ((0.0, 52.0, 34.0, 1.0, 0.16),
                               (0.30, 44.0, 30.0, 0.62, 0.13)):
        span = 0.55
        body = S.sine(span, S.expsweep(span, f0, f1))
        body = body * S.perc_env(span, 0.022, tau, curve=1.1)
        thud = S.lowpass(S.brown(span, r), 150.0, order=2)
        thud = thud * S.perc_env(span, 0.03, tau * 0.7)
        one = S.mix(body * 0.9, thud * 0.35)
        out = S.place(out, one * g * (0.88 + 0.24 * float(r.random())), at)
    out = S.lowpass(out, 130.0, order=2)
    peak = np.max(np.abs(out)) + 1e-12
    return S.fade(S.dc_block(out / peak, 16.0), 0.01, 0.15) * level


def _stone_drip(r):
    """A drip landing on hot stone: `_drip` with the splash dried out and a
    short bright tick of the strike, close rather than cavernous."""
    y = _drip(r)
    tick = S.band_noise(0.004, r, 2200.0, 7000.0, order=3)
    tick *= S.perc_env(0.004, 0.0002, 0.0012)
    y = S.mix(y, S.fit(tick, len(y) / S.SR) * 0.25)
    y = S.lowpass(y, 7000.0, order=2)
    peak = np.max(np.abs(y)) + 1e-12
    return y / peak


def _glow_flare(r):
    """Magma breathing out: a slow, dark swell of filtered noise with no
    transient at either end. The only 'event' in the chamber that moves."""
    d = 1.8 + 2.2 * float(r.random())
    y = S.band_noise(d, r, 90.0, 900.0, order=2)
    y = S.lp_sweep(y, S.expsweep(d, 700.0, 220.0), order=2)
    y *= S.breakpoints(d, [(0.0, 0.0), (d * 0.45, 1.0), (d * 0.72, 0.6),
                           (d, 0.0)], curve="lin")
    peak = np.max(np.abs(y)) + 1e-12
    return S.fade(y / peak, 0.25, 0.5)


def amb_gloom(r):
    """The trench. Pressure you can feel, drips off something overhead, and
    clicks from things that are not close enough to see."""
    dur = 84.0
    bed = Bed(dur)
    bed.layer(_hum(dur, r, [27.5, 41.2, 55.0], detune_cents=9.0, wobble=2), 0.50)
    bed.layer(_rumble(dur, r, cut=60.0, cycles=2, depth=0.7), 0.40)
    bed.layer(_swell(dur, r, cycles=7, lo=60.0, hi=300.0, colour="brown",
                     depth=0.75), 0.30, pan=-0.35)
    bed.layer(_swell(dur, r, cycles=10, lo=70.0, hi=260.0, colour="brown",
                     depth=0.7), 0.26, pan=0.4)
    bed.layer(_hiss(dur, r, low=3000.0, high=8000.0, cycles=13, depth=0.98), 0.030)
    bed.scatter(_drip, r, 18, gain=0.15, spread=0.9, reverb=(3.4, 0.3, 0.5))
    bed.scatter(lambda rr: _tick_cluster(rr, count=2 + int(rr.random() * 3),
                                         low=4200.0, high=10000.0, spread=0.06),
                r, 24, gain=0.05, spread=0.95, reverb=(3.6, 0.28, 0.55))
    bed.scatter(_far_clang, r, 4, gain=0.10, spread=0.6, reverb=(4.0, 0.25, 0.55))
    return bed.render(room=(3.0, 0.30, 0.22), hp=20.0, lp=10000.0)



def amb_heartchamber(r):
    """Inside the Pyrelisk - close, hot and beating.

    An INTERIOR, so there is no wind layer at all: the air does not move,
    it radiates. Four things only - a 45 BPM sub heartbeat felt through the
    floor, the magma glow breathing under it, water finding its way down
    hot stone, and the small room all of that is happening in.

    LOOP: 60.0 s is exactly 45 beats at 45 BPM, so the heartbeat lands on
    the loop point and the pulse never limps across the seam; every
    continuous layer's LFO count is an integer as usual, and the last
    beat's tail is folded under the head by `Bed.render`.

    WHY 60 s AND NOT 80: the pack's whole reason for existing is the upload
    budget (CONTRACT.md §1). At 72 s this bed did not fit beside the four
    beds already in `audio_ambience_1` and the packer opened a TWELFTH
    bundle for it alone - one more file for a human to import, to carry
    66 seconds. 60 s is the longest whole number of beats that still fits
    the existing pack.
    """
    dur, bpm = 60.0, 45.0
    beat = 60.0 / bpm                    # 1.3333 s; 45 of them in 60.0 s
    beats = int(round(dur / beat))
    bed = Bed(dur)

    # THE FLOOR - the chamber's own resonance and the magma under it. Kept
    # narrow and quiet: this is the thing you stop noticing after ten
    # seconds and would miss immediately if it went.
    bed.layer(_hum(dur, r, [32.7, 49.0], detune_cents=6.0, wobble=3), 0.34)
    bed.layer(_rumble(dur, r, cut=75.0, cycles=3, depth=0.6), 0.40)
    # GLOW - low filtered noise that breathes. Two swells at coprime cycle
    # counts so the breathing never repeats inside the loop.
    bed.layer(_swell(dur, r, cycles=7, lo=110.0, hi=780.0, colour="pink",
                     depth=0.75), 0.26, pan=-0.3)
    bed.layer(_swell(dur, r, cycles=11, lo=90.0, hi=520.0, colour="pink",
                     depth=0.8), 0.22, pan=0.35)
    # the hiss OF the glow, not of air: band-limited well under a wind
    bed.layer(_hiss(dur, r, low=1400.0, high=5200.0, cycles=9, depth=0.9), 0.045)

    # THE HEARTBEAT - on the grid, not scattered. Amplitude drifts across
    # the loop (a whole number of cycles of it) so it breathes without ever
    # falling out of time.
    for i in range(beats):
        swell = 0.80 + 0.20 * float(np.sin(2.0 * np.pi * 3.0 * i / beats))
        bed.event(_heartbeat(r), i * beat, gain=0.52 * swell,
                  pan=0.06 * float(np.sin(2.0 * np.pi * i / beats)))

    # WATER on hot stone, and the glow flaring. Both are events, so they
    # carry across the loop point.
    bed.scatter(_stone_drip, r, 26, gain=0.13, spread=0.85,
                reverb=(1.4, 0.45, 0.40))
    bed.scatter(_glow_flare, r, 7, gain=0.12, spread=0.5,
                reverb=(1.8, 0.5, 0.35))
    # A small stone room, not a cathedral: 1.6 s and damped.
    return bed.render(room=(1.6, 0.45, 0.30), hp=20.0, lp=8500.0)


TRACKS = {
    "amb_sea": amb_sea,
    "amb_clear": amb_clear,
    "amb_mist": amb_mist,
    "amb_blizzard": amb_blizzard,
    "amb_ash": amb_ash,
    "amb_summit": amb_summit,
    "amb_ghost": amb_ghost,
    "amb_storm": amb_storm,
    "amb_gloom": amb_gloom,
    "amb_heartchamber": amb_heartchamber,
}


if __name__ == "__main__":
    import time

    for key, fn in TRACKS.items():
        t0 = time.time()
        audio = S.normalize_lufs(fn(S.rng(key)), -24.0, -1.0)
        mono = audio.mean(axis=1)
        head = float(np.sqrt(np.mean(mono[:S.n(0.05)] ** 2)))
        tail = float(np.sqrt(np.mean(mono[-S.n(0.05):] ** 2)))
        print("%-14s %6.2fs  %4.1fs render  peak %+.2f dB  seam %.5f  "
              "head/tail rms %.5f/%.5f"
              % (key, len(audio) / S.SR, time.time() - t0, S.db(audio),
                 abs(mono[0] - mono[-1]), head, tail))
