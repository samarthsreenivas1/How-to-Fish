"""sfx_creatures.py - the generic creature BEHAVIOUR cues.

These are the sounds a creature makes with the world rather than with its
throat: a dash, a spit, a burrow, an explosion, a trap closing. The family
VOICES live next door in `sfx_families.py`; nothing here should ever read as
a mouth, because both play at once and the pair has to stay legible.

Every one of these replaced a pitch-shifted Roblox built-in, so the bar is
SPECIFICITY: `burrow` is sand and gravel being displaced by something with
mass underneath it, not a generic rumble; `pulseZap` is an arc breaking down
across a gap, not a buzzer; `chainRattle` is iron links falling against each
other, not a shaker.

Structure follows `sfx_fishing.py`: TRANSIENT / BODY / TAIL, fast attacks,
pitch that moves, saturation on the low layers, and no normalising (build.py
DC-blocks, limits, peak-normalises to -1 dBFS and puts 3 ms fades on).

LOOPS (`sandShift`, `gasHiss`, `beamHum`) are authored loop-safe: an exact
length, nothing starting inside the last ~0.2 s, LFOs completing a whole
number of cycles across the loop, and `_room(..., tail=False)` so the
reverb cannot run past the loop point.

PAIRS. Four cues here are deliberately two halves of one event and must
stay matched:
  explodeCrack / explodeBoom  the shell fracturing and the pressure wave
  phantomOut  / phantomIn     one shimmer played backwards, then forwards
  spitSplashWater / spitSplashGround  the same glob landing on two surfaces
"""

import numpy as np

import synth as S
from cues import cue

# The creature room: bigger and brighter than the dock, because most of
# these happen out on open sand or water rather than under the pier roof.
_SEED = 73


def _room(x, size=0.5, damping=0.5, mix=0.15, predelay=0.0, tail=True):
    return S.reverb(x, size=size, damping=damping, mix=mix, predelay=predelay,
                    seed=_SEED, tail=tail)


def _grit(dur, r, count=40, low=1400.0, high=9000.0, level=0.5, start=0.0,
          spread=None, decay=1.0):
    """Loose grains - sand, gravel, shell chips, bone. The texture that
    separates 'ground' from 'noise': individual short bursts, not a wash."""
    spread = dur * 0.8 if spread is None else spread
    out = S.silence(start + spread + 0.05)
    times = np.sort(r.random(count)) * spread
    for i in range(count):
        d = 0.003 + 0.006 * float(r.random())
        g = S.band_noise(d, r, low * (0.6 + 0.8 * float(r.random())),
                         high * (0.5 + 0.7 * float(r.random())), order=2)
        g *= S.perc_env(d, 0.0002, 0.0016)
        fall = float(np.exp(-decay * times[i] / max(1e-3, spread)))
        out = S.place(out, g * level * (0.35 + 0.65 * float(r.random())) * fall,
                      start + float(times[i]))
    return out


def _droplets(r, count=5, spread=0.25, level=0.35, start=0.05, freq=1700.0):
    out = S.silence(start + spread + 0.08)
    for _ in range(count):
        at = start + float(r.random()) * spread
        f = freq * float(2.0 ** (r.random() * 1.6 - 0.8))
        d = 0.018 + 0.03 * float(r.random())
        drop = S.bubble(d, f, r, rise=2.2 + 1.2 * float(r.random()))
        out = S.place(out, drop * (0.3 + 0.7 * float(r.random())) * level, at)
    return out


def _bell(dur, freq, r, **kw):
    """TOOLKIT BUG WORKAROUND. `S.bell` builds its strike click as
    `band_noise(freq * 3, min(14000, freq * 14))`, so any fundamental at or
    above ~4.7 kHz asks scipy for a band whose low edge is above its high
    edge and raises `Wn[0] must be less than Wn[1]`. Coins and sparkles want
    to live up there, so the fundamental is clamped and the strike click is
    added here instead. Same for `S.bar` (it clicks at `freq * 2`).
    """
    f = min(float(freq), 4200.0)
    y = S.bell(dur, f, r, **kw)
    if f < float(freq):
        # Keep the brightness the clamp cost us as pure air, not a partial.
        click = S.band_noise(min(0.008, dur), r, 6000.0, 15000.0, order=2)
        click *= S.perc_env(min(0.008, dur), 0.0002, 0.002)
        y = S.mix(y, S.fit(click, dur) * 0.25)
    return y


def _second_loop(y, dur):
    """LOOP STEADY-STATE. Every loop cue here is rendered at TWICE its loop
    length and only the second half is kept.

    Why: filters, noise generators and the reverb all start from zero state,
    so the first 30 ms of a fresh render is measurably quieter than the rest
    (the audit measured the end of a loop at 3x the level of its start). At
    the loop point that reads as a dip once per cycle. Rendering two loops
    and returning the second means the head is already in steady state AND
    already carries the reverb wash of the loop before it - which is exactly
    what the loop point hands over. Every LFO is given twice its per-loop
    cycle count so the slice still lands on phase zero.
    """
    return y[S.n(dur):]


def _sub(dur, hi, lo, tau, drive=2.2, attack=0.002):
    """The low body under anything with mass: a sine falling from `hi` to
    `lo`, saturated so it reads as weight and not as a test tone."""
    y = S.sine(dur, S.expsweep(dur, hi, lo)) * S.perc_env(dur, attack, tau)
    return S.saturate(y, drive)


# ---------------------------------------------------------------------------
# movement
# ---------------------------------------------------------------------------

@cue("dashWhoosh")
def dash_whoosh(r):
    """Something small and fast passes: air ripping, water dragged with it,
    and the band centre sweeping up-then-down (the pass-by arc)."""
    dur = 0.34
    air = S.band_noise(dur, r, 300.0, 12000.0, order=3)
    centre = S.breakpoints(dur, [(0.0, 700.0), (0.13, 4200.0), (0.19, 2600.0),
                                 (dur, 600.0)], curve="exp")
    air = S.bp_sweep(air, centre, q=1.8)
    air *= S.breakpoints(dur, [(0.0, 0.0), (0.04, 0.4), (0.145, 1.0),
                               (0.22, 0.45), (dur, 0.0)], curve="exp")
    # Water pulled along behind it - a short wet drag half-way through.
    drag = S.band_noise(0.13, r, 500.0, 5000.0, order=2)
    drag = S.lp_sweep(drag, S.expsweep(0.13, 4800.0, 700.0), order=2)
    drag *= S.perc_env(0.13, 0.001, 0.035)
    # A little mass, so it is a body moving and not just wind.
    push = _sub(dur, 210.0, 78.0, 0.055, drive=1.8) * 0.4
    y = S.mix(air * 0.9, S.fit(S.place(S.silence(dur), drag * 0.55, 0.10), dur), push)
    return _room(y, size=0.4, mix=0.11)


@cue("dazed")
def dazed(r):
    """Stunned: a woozy tone sagging out of pitch with little bells circling
    it. Cartoon logic, but it has to be readable across a fight."""
    dur = 0.85
    wob = S.sine(dur, 470.0) * 0.5 + S.sine(dur, 471.9) * 0.4
    wob = S.vibrato(wob, rate=5.6, depth_cents=90.0)
    wob *= S.breakpoints(dur, [(0.0, 0.0), (0.03, 1.0), (0.55, 0.5), (dur, 0.0)],
                         curve="exp")
    # Pitch sags as the daze sets in.
    sag = S.sine(dur, S.expsweep(dur, 330.0, 232.0)) * 0.35
    sag = S.vibrato(sag, rate=4.1, depth_cents=60.0)
    sag *= S.breakpoints(dur, [(0.0, 0.0), (0.05, 0.9), (dur, 0.0)], curve="exp")
    # The circling stars: soft bells alternating around the head.
    stars = S.silence(dur)
    for i in range(6):
        f = 1320.0 * (2.0 ** ((i % 3) * 0.17))
        stars = S.place(stars, _bell(0.30, f, r, decay=0.15, strike=0.4) * 0.18,
                        0.10 + i * 0.105)
    y = S.mix(wob * 0.55, sag, S.fit(stars, dur))
    return _room(S.lowpass(y, 5200.0, order=2), size=0.55, mix=0.18)


# ---------------------------------------------------------------------------
# the spitters
# ---------------------------------------------------------------------------

@cue("spitLaunch")
def spit_launch(r):
    """A glob leaves the mouth: a wet lip-pop, then the air it takes with
    it rising away from the listener."""
    dur = 0.28
    # The pop: a short resonant burst with the mouth closing behind it.
    pop = S.sine(0.035, S.expsweep(0.035, 320.0, 900.0)) * S.perc_env(0.035, 0.0006, 0.010)
    pop = S.mix(pop, S.band_noise(0.012, r, 700.0, 5000.0) * S.perc_env(0.012, 0.0003, 0.004) * 0.7)
    pop = S.formant(pop, [520.0, 1180.0], qs=[7.0, 6.0], gains=[1.0, 0.5]) * 0.6 + pop * 0.6
    # The flight: a thin rising hiss that leaves.
    fly = S.band_noise(0.22, r, 1200.0, 9000.0, order=3)
    fly = S.bp_sweep(fly, S.expsweep(0.22, 1800.0, 5200.0), q=2.4)
    fly *= S.breakpoints(0.22, [(0.0, 0.0), (0.02, 0.7), (0.22, 0.0)], curve="exp")
    out = S.place(S.silence(dur), S.fit(pop, 0.06) * 1.0, 0.0)
    out = S.place(out, fly * 0.45, 0.035)
    return _room(S.fit(out, dur), size=0.35, mix=0.10)


@cue("spitSplashWater")
def spit_splash_water(r):
    """The glob lands in water: it opens the surface, sinks, and the surface
    closes over it with droplets falling back."""
    dur = 0.55
    open_ = S.splash(0.20, r, low=800.0, high=9000.0, sweep_to=460.0, body=0.2)
    swallow = S.bubble(0.075, 250.0, r, rise=3.2, tau=0.032)
    close = S.splash(0.22, r, low=420.0, high=4200.0, sweep_to=260.0, body=0.45)
    out = S.place(S.silence(dur), open_ * 0.95, 0.0)
    out = S.place(out, S.fit(swallow, 0.10) * 0.6, 0.025)
    out = S.place(out, close * 0.5, 0.115)
    out = S.place(out, _droplets(r, count=6, spread=0.22, level=0.26, start=0.14), 0.0)
    return _room(S.fit(out, dur), size=0.5, damping=0.6, mix=0.19)


@cue("spitSplashGround")
def spit_splash_ground(r):
    """The same glob on dirt: no ring, no droplets falling back - a flat wet
    slap, a dull thud, and grit thrown out sideways."""
    dur = 0.42
    slap = S.band_noise(0.10, r, 500.0, 6000.0, order=3)
    slap = S.lp_sweep(slap, S.expsweep(0.10, 5500.0, 700.0), order=2)
    slap *= S.perc_env(0.10, 0.0008, 0.016, curve=1.3)
    thud = _sub(dur, 165.0, 68.0, 0.045, drive=2.0) * 0.55
    spatter = _grit(0.2, r, count=16, low=1200.0, high=6500.0, level=0.22,
                    start=0.02, spread=0.16, decay=2.2)
    y = S.mix(S.fit(slap, dur) * 0.9, thud, S.fit(spatter, dur))
    return _room(S.lowpass(y, 6000.0, order=2), size=0.35, damping=0.7, mix=0.12)


# ---------------------------------------------------------------------------
# the bursters - one blast in two layers
# ---------------------------------------------------------------------------

@cue("explodeCrack")
def explode_crack(r):
    """Layer 1 of the blast: the SHELL failing. A hard bright transient plus
    a few high resonators snapping - this is the layer that tells you the
    thing had a carapace and that it just stopped having one."""
    dur = 0.34
    hit = S.white(0.006, r) * S.perc_env(0.006, 0.00008, 0.0018)
    hit = S.fit(hit, dur)
    shell = np.zeros(S.n(dur))
    for i, f in enumerate((1180.0, 1970.0, 3140.0, 4630.0)):
        shell += S.resonator(hit, f, q=26.0) / (i + 1.3)
    shell *= S.expdec(dur, 0.045)
    rip = S.band_noise(0.11, r, 1800.0, 14000.0, order=3)
    rip = S.lp_sweep(rip, S.expsweep(0.11, 13000.0, 2200.0), order=2)
    rip *= S.perc_env(0.11, 0.0002, 0.020, curve=1.4)
    chips = _grit(0.28, r, count=22, low=2200.0, high=12000.0, level=0.26,
                  start=0.012, spread=0.22, decay=2.4)
    y = S.mix(shell * 0.9, S.fit(rip, dur) * 0.8, S.fit(chips, dur))
    return _room(y, size=0.45, damping=0.4, mix=0.14)


@cue("explodeBoom")
def explode_boom(r):
    """Layer 2 of the same blast: the PRESSURE. A hard sub drop, a saturated
    body, and a rumble tail that decays into the room. Played together with
    explodeCrack these are one explosion; alone, neither is."""
    dur = 0.95
    punch = S.membrane(0.45, 58.0, r, drop=0.30, noise=0.12, tau=0.14,
                       sweep_time=0.020)
    punch = S.saturate(punch * 1.1, 2.6)
    sub = _sub(dur, 130.0, 34.0, 0.22, drive=2.8, attack=0.0015) * 0.9
    blast = S.brown(0.7, r) * 1.6
    blast = S.lp_sweep(blast, S.expsweep(0.7, 2600.0, 180.0), order=2)
    blast *= S.breakpoints(0.7, [(0.0, 0.0), (0.004, 1.0), (0.20, 0.35),
                                 (0.7, 0.0)], curve="exp")
    rumble = S.brown(dur, r) * 0.9
    rumble = S.lowpass(rumble, 300.0, order=2)
    rumble *= S.breakpoints(dur, [(0.0, 0.0), (0.03, 0.5), (0.35, 0.35),
                                 (dur, 0.0)], curve="exp")
    y = S.mix(S.fit(punch, dur), sub, S.fit(blast, dur) * 0.75, rumble * 0.5)
    return _room(S.saturate(y * 0.8, 1.5), size=1.0, damping=0.55, mix=0.24)


# ---------------------------------------------------------------------------
# the burrowers
# ---------------------------------------------------------------------------

@cue("burrow")
def burrow(r):
    """Going under: sand and gravel DISPLACED - a dense grain rush whose
    band falls as the body sinks, over a low mass that goes with it. The
    falling band is the whole read; a static band is a shaker."""
    dur = 0.60
    rush = S.band_noise(0.42, r, 200.0, 9000.0, order=3)
    rush = S.bp_sweep(rush, S.breakpoints(0.42, [(0.0, 3200.0), (0.10, 2100.0),
                                                 (0.42, 620.0)], curve="exp"), q=1.1)
    rush *= S.breakpoints(0.42, [(0.0, 0.0), (0.02, 1.0), (0.20, 0.6),
                                 (0.42, 0.0)], curve="exp")
    grains = _grit(0.45, r, count=48, low=900.0, high=6000.0, level=0.34,
                   start=0.0, spread=0.40, decay=1.8)
    body = _sub(dur, 140.0, 42.0, 0.16, drive=2.4) * 0.85
    # A soft collapse behind it as the hole fills in.
    fill = S.band_noise(0.22, r, 150.0, 1800.0, order=2)
    fill *= S.breakpoints(0.22, [(0.0, 0.0), (0.08, 0.6), (0.22, 0.0)], curve="exp")
    y = S.mix(S.fit(rush, dur) * 0.8, S.fit(grains, dur), body,
              S.fit(S.place(S.silence(dur), fill * 0.35, 0.30), dur))
    return _room(S.lowpass(y, 8000.0, order=2), size=0.45, damping=0.7, mix=0.13)


@cue("sandShift", loop=True)
def sand_shift(r):
    """Loop: something moving UNDER the sand. A continuous grain shuffle
    with a slow swell, and a subsonic drag beneath it.

    Loop-safe: the grains all start inside the first 1.0 s of a 1.2 s loop,
    the swell LFO completes exactly two cycles, and the room is truncated.
    """
    dur = 1.2
    full = dur * 2.0                    # two loops; the second is returned
    idx = np.arange(S.n(full))
    lfo = 0.55 + 0.45 * np.sin(2.0 * np.pi * 4.0 * idx / S.n(full))   # 2 per loop
    bed = S.band_noise(full, r, 400.0, 5200.0, order=2) * 0.55
    bed = S.bp_sweep(bed, 1200.0 + 700.0 * lfo, q=1.2) * lfo
    grains = S.silence(full)
    for _ in range(68):
        at = float(r.random()) * (full - 0.06)   # nothing truncated at the end
        d = 0.004 + 0.008 * float(r.random())
        g = S.band_noise(d, r, 800.0, 6500.0, order=2) * S.perc_env(d, 0.0003, 0.0022)
        grains = S.place(grains, g * (0.15 + 0.35 * float(r.random())), at)
    grains = S.fit(grains, full)
    drag = S.brown(full, r) * 0.8
    drag = S.lowpass(drag, 120.0, order=2) * (0.6 + 0.4 * lfo)
    y = S.mix(bed * 0.7, grains, S.saturate(drag * 0.5, 1.6))
    y = _room(S.lowpass(y, 7000.0, order=2), size=0.4, damping=0.75,
              mix=0.10, tail=False)
    return _second_loop(y, dur)


@cue("emerge")
def emerge(r):
    """Coming UP: grit thrown clear on a hard upward burst, then the wet
    heave of the body breaking the surface. The mirror of `burrow` - the
    band rises here instead of falling."""
    dur = 0.75
    burst = S.band_noise(0.20, r, 300.0, 11000.0, order=3)
    burst = S.bp_sweep(burst, S.expsweep(0.20, 900.0, 4600.0), q=1.3)
    burst *= S.breakpoints(0.20, [(0.0, 0.0), (0.006, 1.0), (0.09, 0.45),
                                  (0.20, 0.0)], curve="exp")
    throw = _grit(0.42, r, count=40, low=1400.0, high=10000.0, level=0.34,
                  start=0.01, spread=0.36, decay=1.5)
    heave = S.band_noise(0.30, r, 250.0, 4000.0, order=2)
    heave = S.lp_sweep(heave, S.breakpoints(0.30, [(0.0, 900.0), (0.09, 3200.0),
                                                   (0.30, 700.0)], curve="exp"), order=2)
    heave *= S.breakpoints(0.30, [(0.0, 0.0), (0.07, 1.0), (0.30, 0.0)], curve="exp")
    lift = S.sine(0.34, S.expsweep(0.34, 52.0, 128.0)) * S.perc_env(0.34, 0.004, 0.13)
    y = S.mix(S.fit(burst, dur) * 0.9, S.fit(throw, dur),
              S.fit(S.place(S.silence(dur), heave * 0.55, 0.08), dur),
              S.fit(S.saturate(lift * 0.8, 2.2), dur))
    return _room(y, size=0.55, damping=0.6, mix=0.16)


# ---------------------------------------------------------------------------
# shells
# ---------------------------------------------------------------------------

@cue("shellCreak")
def shell_creak(r):
    """A shell opening under load: stick-slip. Short noise events through a
    tuned comb so each slip RINGS, with the rate slowing as it gives."""
    dur = 0.62
    ticks = S.silence(dur)
    at = 0.0
    gap = 0.012
    while at < 0.48:
        d = 0.004
        g = S.band_noise(d, r, 600.0, 5000.0, order=2) * S.perc_env(d, 0.0003, 0.0014)
        ticks = S.place(ticks, g * (0.4 + 0.6 * float(r.random())), at)
        at += gap
        gap *= 1.10                     # slowing: the hinge is fighting back
    ticks = S.fit(ticks, dur)
    ring = S.comb(ticks, 1.0 / 168.0, feedback=0.90, damp=0.42)
    ring = S.bandpass(ring, 140.0, 3600.0, order=2)
    ring = ring / (np.max(np.abs(ring)) + 1e-12)
    strain = S.sine(dur, S.expsweep(dur, 205.0, 168.0)) * 0.22
    strain = S.vibrato(strain, rate=7.0, depth_cents=35.0)
    strain *= S.breakpoints(dur, [(0.0, 0.0), (0.10, 1.0), (0.45, 0.7), (dur, 0.0)])
    return _room(S.mix(ring * 0.85, S.saturate(strain, 2.0) * 0.5), size=0.4,
                 damping=0.6, mix=0.15)


@cue("shellSnap")
def shell_snap(r):
    """A shell slamming shut: a hard chitin crack with a very short dry
    ring under it and no tail. Must be able to fire twice in 200 ms."""
    dur = 0.20
    crack = S.band_noise(0.007, r, 900.0, 13000.0, order=2)
    crack *= S.perc_env(0.007, 0.00008, 0.0016)
    crack = S.fit(crack, dur)
    plate = np.zeros(S.n(dur))
    for i, f in enumerate((640.0, 1290.0, 2260.0)):
        plate += S.resonator(crack, f, q=20.0) / (i + 1.4)
    plate *= S.expdec(dur, 0.026)
    knock = S.membrane(0.09, 148.0, r, drop=0.55, noise=0.10, tau=0.022)
    y = S.mix(crack * 0.7, plate * 1.0, S.fit(S.saturate(knock * 0.8, 2.0), dur) * 0.6)
    return _room(S.lowpass(y, 12000.0, order=2), size=0.28, damping=0.6, mix=0.09)


# ---------------------------------------------------------------------------
# the thieves and the sparks
# ---------------------------------------------------------------------------

@cue("coinSteal")
def coin_steal(r):
    """Coins snatched: a fast swipe, then the purse contents leaving with
    it - bright metal, pitched UP as it runs away."""
    dur = 0.50
    swipe = S.band_noise(0.10, r, 1500.0, 12000.0, order=3)
    swipe = S.bp_sweep(swipe, S.expsweep(0.10, 2200.0, 6000.0), q=2.0)
    swipe *= S.breakpoints(0.10, [(0.0, 0.0), (0.015, 1.0), (0.10, 0.0)], curve="exp")
    coins = S.silence(dur)
    for i in range(9):
        f = 2350.0 * float(2.0 ** (r.random() * 1.3)) * (1.0 + 0.14 * i)
        at = 0.03 + float(r.random()) * 0.26
        coins = S.place(coins, _bell(0.20, f, r, decay=0.07, strike=0.8) * 0.20, at)
    away = S.sine(0.22, S.expsweep(0.22, 900.0, 2400.0)) * S.perc_env(0.22, 0.004, 0.06)
    y = S.mix(S.fit(swipe, dur) * 0.7, S.fit(coins, dur),
              S.fit(S.place(S.silence(dur), away * 0.22, 0.10), dur))
    return _room(y, size=0.45, damping=0.4, mix=0.16)


@cue("crackle")
def crackle(r):
    """Dry crackle - the surface of something burning, freezing or setting.
    Irregular grains with real silence between them; an even rate reads as
    static, and static is what this cue exists NOT to be."""
    dur = 0.55
    out = S.silence(dur)
    at = 0.0
    while at < 0.48:
        d = 0.006 + 0.010 * float(r.random())
        g = S.band_noise(d, r, 1100.0 * (0.5 + float(r.random())),
                         9000.0 * (0.5 + 0.6 * float(r.random())), order=2)
        g *= S.perc_env(d, 0.0002, 0.0022 + 0.004 * float(r.random()))
        # A tiny pitched snap on the louder ones - a fibre letting go.
        if r.random() < 0.4:
            f = 900.0 * float(2.0 ** (r.random() * 1.8))
            g = S.mix(g, S.bar(min(d, 0.02), f, r, decay=0.008, strike=0.6) * 0.35)
        out = S.place(out, g * (0.25 + 0.75 * float(r.random())), at)
        at += 0.010 + 0.055 * float(r.random())
    hiss = S.band_noise(dur, r, 2500.0, 11000.0, order=2) * 0.10
    hiss *= S.breakpoints(dur, [(0.0, 0.0), (0.05, 1.0), (dur, 0.2)])
    return _room(S.mix(S.fit(out, dur), hiss), size=0.4, damping=0.45, mix=0.13)


@cue("pulseZap")
def pulse_zap(r):
    """An electric arc: it does not hum, it BREAKS DOWN. Bursty crushed
    noise through a screaming resonance, restriking a few times, with the
    sixty-cycle-ish buzz only underneath it."""
    dur = 0.38
    out = S.silence(dur)
    strikes = (0.0, 0.052, 0.098, 0.176)
    amps = (1.0, 0.55, 0.72, 0.34)
    for at, amp in zip(strikes, amps):
        d = 0.045
        arc = S.white(d, r)
        arc = S.bitcrush(arc, bits=4, downsample=2 + int(r.random() * 3))
        cen = S.expsweep(d, 5200.0 * (0.7 + 0.6 * float(r.random())), 2400.0)
        arc = S.svf(arc, cen, q=9.0, mode="band")
        arc *= S.perc_env(d, 0.0002, 0.006, curve=1.4)
        out = S.place(out, arc * amp * 0.9, at)
    buzz = S.pulse(0.26, 118.0, 0.22) * 0.30
    buzz = S.moog(buzz, S.expsweep(0.26, 3200.0, 900.0), res=0.55)
    buzz *= S.breakpoints(0.26, [(0.0, 0.0), (0.006, 1.0), (0.12, 0.4), (0.26, 0.0)],
                          curve="exp")
    spark = _grit(0.26, r, count=14, low=4000.0, high=15000.0, level=0.20,
                  start=0.02, spread=0.22, decay=2.0)
    y = S.mix(out, S.fit(buzz * 0.5, dur), S.fit(spark, dur))
    return _room(S.highpass(y, 220.0, order=2), size=0.4, damping=0.35, mix=0.14)


@cue("pulseThump")
def pulse_thump(r):
    """The discharge landing in your chest: a sub thump with a short tuned
    ring on top, so it reads as ENERGY rather than as a footstep."""
    dur = 0.45
    body = S.membrane(0.30, 62.0, r, drop=0.34, noise=0.05, tau=0.10,
                      sweep_time=0.016)
    body = S.saturate(body * 1.1, 2.6)
    ring = S.sine(0.22, 196.0) * S.perc_env(0.22, 0.0012, 0.055) * 0.35
    ring = S.mix(ring, S.sine(0.22, 294.0) * S.perc_env(0.22, 0.0012, 0.032) * 0.18)
    click = S.band_noise(0.008, r, 700.0, 6000.0) * S.perc_env(0.008, 0.0002, 0.0022)
    y = S.mix(S.fit(body, dur), S.fit(ring, dur), S.fit(click, dur) * 0.35)
    return _room(S.lowpass(y, 5000.0, order=2), size=0.5, damping=0.6, mix=0.15)


@cue("gasHiss", loop=True)
def gas_hiss(r):
    """Loop: gas escaping under pressure. Narrow-band noise with a resonant
    whistle riding on it, breathing slightly.

    Loop-safe: one continuous source, two whole LFO cycles, room truncated.
    """
    dur = 1.4
    full = dur * 2.0                    # two loops; the second is returned
    idx = np.arange(S.n(full))
    lfo = np.sin(2.0 * np.pi * 4.0 * idx / S.n(full))          # 2 per loop
    jet = S.band_noise(full, r, 1200.0, 12000.0, order=3)
    jet = S.bp_sweep(jet, 3400.0 + 900.0 * lfo, q=1.6)
    jet *= 0.75 + 0.25 * lfo
    whistle = S.band_noise(full, r, 3000.0, 9000.0, order=2)
    whistle = S.svf(whistle, 5200.0 + 400.0 * lfo, q=11.0, mode="band") * 0.5
    low = S.band_noise(full, r, 200.0, 900.0, order=2) * 0.18 * (0.7 + 0.3 * lfo)
    y = S.mix(jet * 0.7, whistle * 0.35, low)
    y = _room(y, size=0.35, damping=0.5, mix=0.08, tail=False)
    return _second_loop(y, dur)


# ---------------------------------------------------------------------------
# water and spines
# ---------------------------------------------------------------------------

@cue("inkBlast")
def ink_blast(r):
    """Ink released: a soft-attacked dark gush that BLOOMS - the low-pass
    opens a little then shuts hard, which is what a cloud spreading and
    then hanging in the water sounds like."""
    dur = 0.70
    gush = S.band_noise(0.42, r, 120.0, 5000.0, order=3)
    gush = S.lp_sweep(gush, S.breakpoints(0.42, [(0.0, 700.0), (0.07, 3400.0),
                                                 (0.42, 380.0)], curve="exp"), order=2)
    gush *= S.breakpoints(0.42, [(0.0, 0.0), (0.020, 1.0), (0.18, 0.5),
                                 (0.42, 0.0)], curve="exp")
    swirl = S.wet_texture(0.5, r, density=9.0, freq=300.0, spread=1.7, level=0.45)
    swirl = S.lowpass(swirl, 1800.0, order=2)
    push = _sub(dur, 120.0, 46.0, 0.16, drive=2.0, attack=0.010) * 0.6
    cloud = S.band_noise(0.45, r, 80.0, 900.0, order=2) * 0.30
    cloud *= S.breakpoints(0.45, [(0.0, 0.0), (0.15, 1.0), (0.45, 0.0)])
    y = S.mix(S.fit(gush, dur), S.fit(swirl, dur) * 0.6, push,
              S.fit(S.place(S.silence(dur), cloud, 0.14), dur))
    return _room(S.lowpass(y, 5500.0, order=2), size=0.7, damping=0.75, mix=0.20)


@cue("splashRing")
def splash_ring(r):
    """An expanding ring of water leaving a body: one impact, then the ring
    reading OUTWARD - the band falls and the droplets arrive late and wide,
    which is how you hear a circle rather than a splash."""
    dur = 0.80
    hit = S.splash(0.24, r, low=700.0, high=10000.0, sweep_to=420.0, body=0.35)
    spread = S.band_noise(0.52, r, 250.0, 6000.0, order=2)
    spread = S.lp_sweep(spread, S.expsweep(0.52, 5000.0, 480.0), order=2)
    spread *= S.breakpoints(0.52, [(0.0, 0.0), (0.05, 0.55), (0.28, 0.35),
                                   (0.52, 0.0)], curve="exp")
    wave = _sub(dur, 96.0, 44.0, 0.20, drive=1.8, attack=0.012) * 0.45
    drops = _droplets(r, count=11, spread=0.40, level=0.24, start=0.16, freq=1500.0)
    y = S.mix(S.fit(hit, dur) * 0.9, S.fit(S.place(S.silence(dur), spread * 0.6, 0.05), dur),
              wave, S.fit(drops, dur))
    return _room(y, size=0.65, damping=0.6, mix=0.20)


@cue("spineStick")
def spine_stick(r):
    """A spine hits and stays in: the thwip of it arriving, a hard stick
    into meat, and a short quiver of the shaft afterwards."""
    dur = 0.30
    thwip = S.band_noise(0.05, r, 1400.0, 11000.0, order=3)
    thwip = S.bp_sweep(thwip, S.expsweep(0.05, 5200.0, 2000.0), q=2.6)
    thwip *= S.breakpoints(0.05, [(0.0, 0.0), (0.008, 1.0), (0.05, 0.0)], curve="exp")
    stick = S.membrane(0.14, 190.0, r, drop=0.5, noise=0.45, tau=0.030)
    stick = S.lowpass(stick, 3200.0, order=2)
    quiver = S.sine(0.22, 640.0) * S.perc_env(0.22, 0.001, 0.055) * 0.30
    quiver = S.vibrato(quiver, rate=44.0, depth_cents=55.0)
    y = S.mix(S.fit(thwip, dur) * 0.8, S.fit(S.saturate(stick, 1.8), dur) * 0.9,
              S.fit(S.place(S.silence(dur), quiver, 0.045), dur))
    return _room(y, size=0.35, damping=0.55, mix=0.12)


@cue("chillTick")
def chill_tick(r):
    """One tick of a chill stack: ice forming. A tiny glassy strike with a
    freezing crackle after it. Very short - this fires on a timer."""
    dur = 0.24
    ping = _bell(0.18, 2637.0, r, decay=0.08, strike=0.8, inharmonic=0.85) * 0.85
    frost = _grit(0.16, r, count=9, low=5000.0, high=15000.0, level=0.24,
                  start=0.008, spread=0.13, decay=2.6)
    breath = S.band_noise(0.10, r, 3000.0, 9000.0, order=2) * 0.16
    breath *= S.breakpoints(0.10, [(0.0, 0.0), (0.02, 1.0), (0.10, 0.0)], curve="exp")
    y = S.mix(S.fit(ping, dur), S.fit(frost, dur), S.fit(breath, dur))
    return _room(y, size=0.4, damping=0.3, mix=0.16)


# ---------------------------------------------------------------------------
# the revenants and the phantoms
# ---------------------------------------------------------------------------

@cue("rebornRise")
def reborn_rise(r):
    """It gets back up: a swell out of nothing, wet matter re-knitting, and
    a chord arriving on top when it is whole again."""
    dur = 1.30
    swell = S.supersaw(0.82, 82.4, voices=5, detune=0.007, phase_seed=r)
    swell = S.moog(swell, S.breakpoints(0.82, [(0.0, 260.0), (0.74, 2100.0),
                                               (0.82, 1200.0)], curve="exp"), res=0.40)
    swell *= S.breakpoints(0.82, [(0.0, 0.0), (0.70, 1.0), (0.82, 0.55)], curve="exp")
    # NOTE: wet_texture can return a few samples LONGER than `dur` (it
    # `place`s its last bubble near the end and place() grows the buffer),
    # so fit() before multiplying by an envelope or numpy refuses the shape.
    knit = S.fit(S.wet_texture(0.78, r, density=13.0, freq=520.0, spread=2.4, level=0.4), 0.78)
    knit *= S.breakpoints(0.78, [(0.0, 0.15), (0.74, 1.0), (0.78, 0.3)])
    lift = S.sine(0.86, S.expsweep(0.86, 44.0, 110.0)) * S.breakpoints(
        0.86, [(0.0, 0.0), (0.78, 1.0), (0.86, 0.4)], curve="exp")
    chord = S.silence(dur)
    for f in (164.81, 246.94, 329.63):          # E3 B3 E4 - it stands up whole
        chord = S.place(chord, _bell(0.46, f, r, decay=0.24, strike=0.5) * 0.26, 0.74)
    gasp = S.band_noise(0.18, r, 300.0, 3600.0, order=2)
    gasp = S.formant(gasp, [420.0, 1100.0, 2500.0], qs=[6.0, 5.0, 4.0],
                     gains=[1.0, 0.55, 0.25])
    gasp *= S.breakpoints(0.18, [(0.0, 0.0), (0.05, 1.0), (0.18, 0.0)], curve="exp")
    y = S.mix(S.fit(swell, dur) * 0.45, S.fit(knit, dur) * 0.5,
              S.fit(S.saturate(lift * 0.7, 2.0), dur),
              chord, S.fit(S.place(S.silence(dur), gasp * 0.35, 0.72), dur))
    return _room(y, size=0.62, damping=0.55, mix=0.22)


def _phantom_shimmer(r, dur):
    """The shape both phantom cues are cut from: a bright inharmonic cloud
    over a rising tone. `phantomOut` plays it BACKWARDS (a sound sucking
    itself in), `phantomIn` plays it forwards. Same material, so the pair
    is audibly one creature going and coming back."""
    out = S.silence(dur)
    for i in range(9):
        f = 1050.0 * float(2.0 ** (r.random() * 2.1))
        at = float(r.random()) * (dur * 0.62)
        out = S.place(out, _bell(0.28, f, r, decay=0.13, strike=0.5,
                                  inharmonic=0.75) * 0.16, at)
    air = S.band_noise(dur, r, 1800.0, 14000.0, order=2)
    air = S.bp_sweep(air, S.expsweep(dur, 2200.0, 9500.0), q=1.6)
    air *= S.breakpoints(dur, [(0.0, 0.0), (dur * 0.75, 1.0), (dur, 0.25)], curve="exp")
    tone = S.sine(dur, S.expsweep(dur, 220.0, 880.0)) * 0.22
    tone *= S.breakpoints(dur, [(0.0, 0.0), (dur * 0.8, 1.0), (dur, 0.0)], curve="exp")
    return S.fit(S.mix(out, air * 0.45, tone), dur)


@cue("phantomOut")
def phantom_out(r):
    """It leaves: the shimmer REVERSED, so everything sucks inward, ending
    on the pop of the space closing where it was."""
    dur = 0.55
    body = S.reverse(_phantom_shimmer(r, dur))
    pop = S.sine(0.05, S.expsweep(0.05, 700.0, 180.0)) * S.perc_env(0.05, 0.0004, 0.012)
    pop = S.mix(pop, S.band_noise(0.012, r, 400.0, 5000.0) *
                S.perc_env(0.012, 0.0002, 0.003) * 0.6)
    suck = S.band_noise(0.30, r, 200.0, 4000.0, order=2)
    suck = S.lp_sweep(suck, S.expsweep(0.30, 3600.0, 320.0), order=2)
    suck *= S.breakpoints(0.30, [(0.0, 0.0), (0.24, 1.0), (0.30, 0.0)], curve="exp")
    y = S.mix(body * 0.85, S.fit(S.place(S.silence(dur), suck * 0.4, 0.22), dur),
              S.fit(S.place(S.silence(dur), pop * 0.8, dur - 0.055), dur))
    return _room(y, size=0.7, damping=0.4, mix=0.22)


@cue("phantomIn")
def phantom_in(r):
    """It arrives: the same shimmer FORWARDS, opening on a hard displacement
    of air and blooming outward."""
    dur = 0.55
    body = _phantom_shimmer(r, dur)
    crack = S.band_noise(0.014, r, 1200.0, 13000.0) * S.perc_env(0.014, 0.0001, 0.003)
    thump = _sub(dur, 190.0, 60.0, 0.055, drive=2.2) * 0.5
    bloom = S.band_noise(0.30, r, 400.0, 9000.0, order=2)
    bloom = S.lp_sweep(bloom, S.expsweep(0.30, 900.0, 6500.0), order=2)
    bloom *= S.breakpoints(0.30, [(0.0, 0.0), (0.05, 0.8), (0.30, 0.0)], curve="exp")
    y = S.mix(body * 0.8, S.fit(crack, dur) * 0.7, thump,
              S.fit(bloom * 0.35, dur))
    return _room(y, size=0.7, damping=0.4, mix=0.22)


# ---------------------------------------------------------------------------
# traps, chains, decoys, beams
# ---------------------------------------------------------------------------

@cue("snareSnap")
def snare_snap(r):
    """A snare closing: the line whipping taut, then the jaws meeting on a
    hard wooden clack with a rope creak dying under it."""
    dur = 0.35
    whip = S.band_noise(0.045, r, 1000.0, 12000.0, order=3)
    whip = S.bp_sweep(whip, S.expsweep(0.045, 1600.0, 6000.0), q=2.2)
    whip *= S.breakpoints(0.045, [(0.0, 0.0), (0.006, 1.0), (0.045, 0.0)], curve="exp")
    clack = S.band_noise(0.006, r, 500.0, 9000.0) * S.perc_env(0.006, 0.0001, 0.0018)
    clack = S.fit(clack, 0.24)
    wood = np.zeros(S.n(0.24))
    for i, f in enumerate((312.0, 590.0, 1080.0)):
        wood += S.resonator(clack, f, q=15.0) / (i + 1.3)
    wood *= S.expdec(0.24, 0.035)
    creak = S.comb(S.fit(S.band_noise(0.006, r, 300.0, 3000.0) *
                         S.perc_env(0.006, 0.0004, 0.002), 0.22),
                   1.0 / 132.0, feedback=0.88, damp=0.5)
    creak *= S.expdec(0.22, 0.06)
    y = S.mix(S.fit(whip, dur) * 0.7,
              S.fit(S.place(S.silence(dur), S.mix(clack * 0.6, wood * 1.6), 0.042), dur),
              S.fit(S.place(S.silence(dur), creak * 0.7, 0.055), dur))
    # The clack peaks a single sample far above everything else, so the
    # peak-normalise in build.py was leaving the whole cue quiet. Softclip
    # takes the spike, not the body, and the cue comes up ~9 dB.
    y = S.softclip(y * 1.5, 0.55)
    return _room(y, size=0.4, damping=0.6, mix=0.16)


@cue("chainRattle")
def chain_rattle(r):
    """Iron links: many small metal strikes, IRREGULARLY spaced and each one
    a different length of link, so it swings rather than shakes. The comb
    under it is the chain itself carrying the sound along its length."""
    dur = 0.75
    hits = S.silence(dur)
    at = 0.0
    while at < 0.60:
        f = 1400.0 * float(2.0 ** (r.random() * 1.1 - 0.35))
        d = 0.055 + 0.05 * float(r.random())
        link = S.metal_hit(d, r, f, ring=0.30, roughness=0.8)
        link *= S.expdec(d, 0.016 + 0.012 * float(r.random()))
        amp = 0.28 + 0.55 * float(r.random())
        amp *= float(np.exp(-1.1 * at))       # the swing dying out
        hits = S.place(hits, link * amp, at)
        at += 0.014 + 0.052 * float(r.random())
    hits = S.fit(hits, dur)
    body = S.comb(hits, 1.0 / 96.0, feedback=0.62, damp=0.18, mix=0.5)
    body = S.bandpass(body, 220.0, 11000.0, order=2)
    body = body / (np.max(np.abs(body)) + 1e-12)
    return _room(body * 0.9, size=0.5, damping=0.35, mix=0.17)


@cue("decoyPop")
def decoy_pop(r):
    """A decoy appearing: a hollow cork pop with a short tuned ring. Light,
    friendly and small - it must never be mistaken for a hit."""
    dur = 0.26
    pop = S.sine(0.045, S.expsweep(0.045, 240.0, 760.0)) * S.perc_env(0.045, 0.0008, 0.011)
    tube = np.zeros(S.n(0.20))
    exc = S.fit(S.band_noise(0.005, r, 600.0, 7000.0) * S.perc_env(0.005, 0.0002, 0.0014), 0.20)
    for i, f in enumerate((520.0, 1040.0, 1560.0)):
        tube += S.resonator(exc, f, q=17.0) / (i + 1.5)
    tube *= S.expdec(0.20, 0.045)
    air = S.band_noise(0.06, r, 1500.0, 8000.0, order=2)
    air *= S.breakpoints(0.06, [(0.0, 0.0), (0.008, 1.0), (0.06, 0.0)], curve="exp")
    y = S.mix(S.fit(pop, dur) * 0.9, S.fit(tube, dur) * 0.7, S.fit(air, dur) * 0.25)
    return _room(y, size=0.35, damping=0.5, mix=0.15)


@cue("beamHum", loop=True)
def beam_hum(r):
    """Loop: a beam holding. A tuned core with a beating partial above it
    and a fine grain of static, so it is ENERGY and not an organ.

    Loop-safe: every component is periodic in the loop length (110 Hz and
    221 Hz over 1.0 s are whole cycles; the two LFOs are 3 and 5 cycles).
    """
    dur = 1.0
    full = dur * 2.0                    # two loops; the second is returned
    idx = np.arange(S.n(full))
    lfo_a = np.sin(2.0 * np.pi * 6.0 * idx / S.n(full))        # 3 per loop
    lfo_b = np.sin(2.0 * np.pi * 10.0 * idx / S.n(full))       # 5 per loop
    core = (S.sine(full, 110.0) * 0.5 + S.sine(full, 221.0) * 0.3 +
            S.sine(full, 330.0) * 0.14)
    core = S.saturate(core * (0.85 + 0.15 * lfo_a), 1.8)
    shine = S.sine(full, 1320.0) * 0.10 * (0.6 + 0.4 * lfo_b)
    shine = S.mix(shine, S.sine(full, 1980.0) * 0.05 * (0.6 + 0.4 * lfo_a))
    fizz = S.band_noise(full, r, 2600.0, 12000.0, order=2) * 0.13
    fizz = S.bp_sweep(fizz, 5000.0 + 1200.0 * lfo_b, q=1.4)
    y = S.mix(core * 0.7, shine, fizz)
    y = _room(y, size=0.35, damping=0.5, mix=0.09, tail=False)
    return _second_loop(y, dur)


@cue("poolSpawn")
def pool_spawn(r):
    """A spawn pool opening: liquid welling up out of the floor, thickening,
    and something forming in it. Slow attack on purpose - this is a warning,
    not a hit."""
    dur = 0.94
    well = S.band_noise(0.85, r, 100.0, 4200.0, order=2)
    well = S.lp_sweep(well, S.breakpoints(0.85, [(0.0, 300.0), (0.55, 2600.0),
                                                 (0.85, 900.0)], curve="exp"), order=2)
    well *= S.breakpoints(0.85, [(0.0, 0.0), (0.50, 1.0), (0.72, 0.7),
                                 (0.85, 0.0)], curve="exp")
    boil = S.fit(S.wet_texture(0.95, r, density=16.0, freq=280.0, spread=2.6, level=0.5), 0.95)
    boil *= S.breakpoints(0.95, [(0.0, 0.1), (0.6, 1.0), (0.95, 0.4)])
    heave = S.sine(dur, S.expsweep(dur, 38.0, 76.0)) * S.breakpoints(
        dur, [(0.0, 0.0), (0.6, 1.0), (dur, 0.15)], curve="exp")
    surge = S.splash(0.35, r, low=300.0, high=4500.0, sweep_to=240.0, body=0.5)
    y = S.mix(S.fit(well, dur) * 0.6, S.fit(boil, dur) * 0.55,
              S.fit(S.saturate(heave * 0.8, 2.2), dur),
              S.fit(S.place(S.silence(dur), surge * 0.45, 0.62), dur))
    return _room(y, size=0.6, damping=0.7, mix=0.20)
