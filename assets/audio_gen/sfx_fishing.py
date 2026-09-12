"""sfx_fishing.py - the REFERENCE category module. Copy this pattern.

Every cue on the `fishing` sheet, implemented. If you are writing another
`sfx_<sheet>.py`, read this file first: it is meant to be the worked
example, not just one more module.

THE PATTERN

    from cues import cue
    import synth as S

    @cue("bobberPlop")            # name already declared in cues.py
    def bobber_plop(r):           # r is a seeded numpy Generator
        return S.mix(transient, body, tail)

Five rules that make the difference between a game and a beeping demo:

1. THREE LAYERS. Nearly every cue below is TRANSIENT (0-20 ms: a click, a
   noise spit - this is what the ear uses to place the event), BODY (the
   pitched or resonant part that says what the object was) and TAIL (room,
   spray, ring - this says where you are). Drop the transient and the cue
   sounds distant; drop the tail and it sounds like a sample library.
2. FAST ATTACKS. Anything struck or splashed wants under 3 ms of attack.
   A 20 ms attack on a hit reads as a swell.
3. PITCH MOVES. Static pitch is the tell of a synthesised sound. Bubbles
   rise, splashes sweep down, ratchets wobble, whooshes bend.
4. SATURATE FOR WEIGHT. `S.saturate(x, 1.5..3)` on the low layers is what
   makes a thud feel like mass rather than like a sine.
5. LEAVE THE LEVEL ALONE. build.py limits and peak-normalises every cue to
   -1 dBFS and puts 3 ms fades on the edges. Balance BETWEEN cues is the
   Luau catalogue's `volume`, not this file's job.

The musical stingers (catchCommon .. catchLegendary) share a key - D major -
so that two of them landing close together do not clash. `catchBoss` is
deliberately outside it.
"""

import numpy as np

import synth as S
from cues import cue

# The reveal stingers all live here so the escalation is visible in one
# place: same key, rising register, more shimmer and more length each step.
D_MAJ = {"root": 587.33}  # D5


def _room(x, size=0.5, damping=0.55, mix=0.16, predelay=0.0, tail=True):
    """The dock: a small, damp, wooden space. Every fishing cue sits in it,
    which is most of why they sound like one set rather than 29 sounds.

    `tail=False` keeps the output the same length as the input. A LOOP cue
    must use that: a reverb tail hanging off the end makes the file longer
    than the loop it was authored as, and the loop point then lands in the
    middle of the tail instead of on the downbeat.
    """
    return S.reverb(x, size=size, damping=damping, mix=mix, predelay=predelay,
                    seed=41, tail=tail)


# The 5 ms lead-in, brought to this sheet on 2026-09-12. `build.finish_cue`
# puts a 3 ms fade on BOTH edges of every cue as click insurance. On the
# combat and character sheets that has always been paired with five
# milliseconds of leading silence, because the fade otherwise lands ON the
# transient of any cue whose peak is at t=0 and takes 50-80% off it - and
# the transient is precisely what the ear uses to place the event. This
# sheet never had it, which is a large part of why its water impacts read
# as soft: every one of them was having its first millisecond faded out.
# Five ms is well under the ~10 ms at which anyone perceives latency.
#
# LOOP cues must never use it: silence inside the loop period is a hole
# once per lap. `bobberBob` and `reelTension` therefore do not.
LEAD = 0.005


def _lead(x):
    return S.place(S.silence(LEAD), x, LEAD)


def _droplets(r, count=5, spread=0.25, level=0.35, start=0.05, freq=1800.0):
    """Scattered droplets falling back - the tail of any water impact."""
    out = S.silence(start + spread + 0.08)
    for _ in range(count):
        at = start + float(r.random()) * spread
        f = freq * float(2.0 ** (r.random() * 1.6 - 0.8))
        d = 0.018 + 0.03 * float(r.random())
        drop = S.bubble(d, f, r, rise=2.2 + 1.2 * float(r.random()))
        out = S.place(out, drop * (0.3 + 0.7 * float(r.random())) * level, at)
    return out


# ---------------------------------------------------------------------------
# the four helpers the 2026-09-12 realism pass added. Every cue below is
# built out of these rather than out of one filtered noise sweep, which is
# what "choppy" was: a single band with a hard envelope has no transient of
# its own, no independent tail, and no part that varies between plays.
# ---------------------------------------------------------------------------

def _moving_band(x, centres, focus, q_narrow=5.0, q_wide=1.0):
    """A band-pass whose CENTRE and BANDWIDTH both move.

    `S.bp_sweep` takes a scalar q, so one call can only move the centre -
    and air whose bandwidth never changes reads as a filter sweep, not as
    something passing you. Two passes (one narrow, one wide) crossfaded
    sample-by-sample by `focus` (1 = narrow, 0 = wide) gives a band that
    opens as the tip accelerates and closes again as it slows, with no new
    DSP in the toolkit.
    """
    narrow = S.bp_sweep(x, centres, q=q_narrow)
    wide = S.bp_sweep(x, centres, q=q_wide)
    f = np.asarray(focus, dtype=np.float64)
    if f.ndim == 0:
        f = np.full(len(x), float(f))
    f = f[: len(x)]
    if len(f) < len(x):
        f = np.concatenate([f, np.full(len(x) - len(f), f[-1] if len(f) else 0.0)])
    return narrow * f + wide * (1.0 - f)


def _accel_times(start, end, first_gap, ratio, floor=0.006):
    """Tick times for a spool or ratchet whose rate changes. `ratio` < 1
    accelerates (line being pulled off), > 1 decelerates (spool winding
    down). Returned as a list so a caller can thin or jitter it."""
    out = []
    at = float(start)
    gap = float(first_gap)
    while at < end:
        out.append(at)
        at += gap
        gap = max(floor, gap * ratio)
    return out


def _ticks(r, dur, times, level=0.5, res=2800.0, low=1400.0, high=9000.0,
           jitter=0.35, decay=0.0035, spread=0.35):
    """A ratchet: individual pawl clicks, not a noise band pretending.

    Each tick is a sub-millisecond noise spit rung through two resonators.
    The spit alone is a click (which is what the old reel cues were); the
    resonators are what make it a small metal part in a housing. Level and
    resonance are jittered per tick from the cue's own rng, so a train of
    thirty never machine-guns.
    """
    out = S.silence(dur)
    glen = 0.016
    for at in times:
        if at < 0.0 or at >= dur - glen:
            continue
        spit = S.band_noise(0.0008, r, low, high) * S.perc_env(0.0008, 0.00008, 0.0003)
        g = S.fit(spit, glen)
        f = res * float(2.0 ** ((r.random() * 2.0 - 1.0) * spread))
        g = S.resonator(g, f, q=17.0) * 0.9 + S.resonator(g, f * 2.37, q=11.0) * 0.35
        g = g * S.expdec(glen, decay)
        amp = level * (1.0 - jitter + 2.0 * jitter * float(r.random()))
        out = S.place(out, g * amp, float(at))
    return out


def _creak(r, dur, f0, f1, level=0.5, q=26.0, rough=7.0, attack=0.02):
    """Something under load: a resonator fed thin noise, its pitch bending
    from `f0` to `f1` while the drive wobbles. This is the drag washer, the
    rope on a cleat and the line stretching - one mechanism, three uses."""
    exc = S.band_noise(dur, r, 200.0, 3000.0, order=2)
    exc *= 0.25 + 0.75 * (0.5 + 0.5 * np.sin(2.0 * np.pi * rough *
                                             np.arange(S.n(dur)) / S.SR))
    y = S.bp_sweep(exc, S.expsweep(dur, f0, f1), q=q)
    y = S.mix(y, S.resonator(exc, (f0 + f1) * 0.5, q=q * 0.6) * 0.5)
    y *= S.breakpoints(dur, [(0.0, 0.0), (attack, 1.0), (dur * 0.7, 0.55),
                             (dur, 0.0)], curve="exp")
    return y / (np.max(np.abs(y)) + 1e-12) * level


def _gulp(r, dur, f0=210.0, level=1.0):
    """The low 'gulp' under a plop: the cavity water leaves behind, closing.
    A resonator whose pitch DIPS and then comes back up - that turn is the
    difference between a plop and a kick drum."""
    exc = S.fit(S.white(0.003, r) * S.perc_env(0.003, 0.0004, 0.0009), dur)
    f = S.breakpoints(dur, [(0.0, f0), (dur * 0.35, f0 * 0.62),
                            (dur, f0 * 1.25)], curve="exp")
    y = S.bp_sweep(exc, f, q=9.0) * 2.0
    y = S.mix(y, S.sine(dur, f) * S.perc_env(dur, 0.003, dur * 0.30) * 0.55)
    y *= S.expdec(dur, dur * 0.34)
    return S.saturate(y, 1.7) * level


# ---------------------------------------------------------------------------
# casting
# ---------------------------------------------------------------------------

@cue("castSwing")
def cast_swing(r):
    """The rod whip - FIVE layers, each with its own envelope, because the
    single swept noise band this used to be is exactly what reads as cheap.

    1. ROD FLEX: a low, heavily damped Karplus blank whose resonance climbs
       as the rod straightens out of its load, plus a bar ring on top of it.
    2. AIR: band noise whose centre AND bandwidth move (`_moving_band`) -
       the band opens as the tip accelerates and closes as it slows, and
       the centre falls after the tip passes, which is the doppler dip.
    3. LINE HISS: a thin 5-9 kHz band that STARTS at the release and decays
       slowly - the line is still paying out after the rod has stopped, so
       it is the one layer whose tail outlasts the gesture.
    4. REEL TICKS: a pawl train accelerating as the spool spins up.
    5. BODY: a short saturated low sweep so the whole thing has mass.
    """
    # `castSwing` is 2D and the lane owner offsets animation against its
    # length, so the total is held to the pre-rework 0.56 s (+/- 50 ms):
    # 0.425 s of material plus the room tail trims back to ~0.56.
    dur = 0.425
    peak = 0.165                    # the tip passes the ear here

    flex = S.karplus(0.26, 168.0, r, brightness=0.30, damping=0.60, stretch=0.25)
    flex = S.bp_sweep(flex, S.breakpoints(0.26, [(0.0, 185.0), (0.14, 520.0),
                                                 (0.26, 275.0)], curve="exp"), q=1.5)
    flex *= S.breakpoints(0.26, [(0.0, 0.0), (0.004, 0.55), (0.09, 1.0),
                                 (0.26, 0.0)], curve="exp")
    ring = S.bar(0.20, 248.0, r, decay=0.085, strike=0.30) * 0.22

    centre = S.breakpoints(dur, [(0.0, 390.0), (peak, 3500.0),
                                 (peak + 0.040, 1900.0), (dur, 600.0)], curve="exp")
    focus = S.breakpoints(dur, [(0.0, 0.88), (peak, 0.10), (peak + 0.07, 0.55),
                                (dur, 0.92)])
    air = _moving_band(S.white(dur, r), centre, focus, q_narrow=5.0, q_wide=0.95)
    air *= S.breakpoints(dur, [(0.0, 0.0), (0.028, 0.20), (peak, 1.0),
                               (peak + 0.022, 0.68), (peak + 0.10, 0.22),
                               (dur, 0.0)], curve="exp")

    hiss = S.band_noise(dur, r, 4200.0, 13000.0, order=3)
    hiss = S.bp_sweep(hiss, S.breakpoints(dur, [(0.0, 5200.0), (peak, 8400.0),
                                                (dur, 5200.0)], curve="exp"), q=1.7)
    # The line is still running out after the rod has stopped, so this is
    # the one layer that is still audible at the end of the cue - it is
    # what gives the whole thing its length.
    hiss *= S.breakpoints(dur, [(0.0, 0.0), (peak - 0.02, 0.06), (peak + 0.012, 1.0),
                                (peak + 0.11, 0.50), (dur - 0.05, 0.26),
                                (dur, 0.0)], curve="exp")

    ticks = _ticks(r, dur, _accel_times(peak - 0.012, dur - 0.02, 0.030, 0.87,
                                        floor=0.010),
                   level=0.38, res=3200.0, decay=0.0028)

    body = S.sine(dur, S.expsweep(dur, 132.0, 70.0)) * S.perc_env(dur, 0.004, 0.050)

    y = S.mix(air * 0.95, S.fit(flex, dur) * 0.42, S.fit(ring, dur),
              hiss * 0.30, ticks, S.saturate(body * 0.45, 1.8))
    return _lead(_room(y, size=0.42, damping=0.50, mix=0.12, predelay=0.008))


@cue("lineWhizz")
def line_whizz(r):
    """Line paying out. The zip is still a swept band, but it now has the
    three things that were missing: a real transient (the loop of line
    jumping off the lip of the spool), the SPOOL underneath it as a tick
    train that accelerates and then eases, and a tail of air that keeps
    going for 150 ms after the zip has gone - line does not stop dead."""
    dur = 0.44
    f = S.expsweep(0.34, 360.0, 1520.0)

    lip = S.band_noise(0.004, r, 1800.0, 12000.0) * S.perc_env(0.004, 0.0004, 0.0011)

    src = S.band_noise(0.34, r, 900.0, 11000.0, order=3)
    focus = S.breakpoints(0.34, [(0.0, 0.25), (0.12, 0.8), (0.34, 0.45)])
    zip_ = _moving_band(src, f * 2.2, focus, q_narrow=6.0, q_wide=1.6)
    tone = S.sine(0.34, f) * 0.18 + S.sine(0.34, f * 2.0) * 0.07
    tone = S.vibrato(tone, rate=17.0, depth_cents=14.0)
    zip_ = S.mix(zip_ * 0.9, tone)
    zip_ *= S.breakpoints(0.34, [(0.0, 0.0), (0.006, 1.0), (0.06, 0.8),
                                 (0.26, 0.45), (0.34, 0.0)], curve="exp")

    spool = _ticks(r, dur, _accel_times(0.004, 0.34, 0.020, 0.90, floor=0.0075),
                   level=0.26, res=3600.0, decay=0.0022)

    # The air still moving after the line has run out.
    trail = S.band_noise(dur, r, 3000.0, 9000.0, order=2)
    trail = S.bp_sweep(trail, S.expsweep(dur, 6200.0, 3200.0), q=1.6)
    trail *= S.breakpoints(dur, [(0.0, 0.0), (0.05, 0.35), (0.22, 0.28),
                                 (dur, 0.0)], curve="exp")

    y = S.mix(S.fit(lip, dur) * 0.45, S.fit(zip_, dur), spool, trail * 0.20)
    return _lead(_room(y, size=0.30, damping=0.5, mix=0.10, predelay=0.006))


@cue("castRefused")
def cast_refused(r):
    """Soft negative - two descending muted plinks, no harshness. A refusal
    should be readable, not punishing."""
    dur = 0.30
    out = S.silence(dur)
    for i, f in enumerate((392.0, 311.1)):     # G4 -> Eb4, a falling minor 3rd
        v = S.bar(0.22, f, r, decay=0.11, strike=0.35)
        v = S.lowpass(v, 2200.0, order=2)
        out = S.place(out, v * (0.9 - 0.25 * i), i * 0.075)
    return _room(out * 0.7, size=0.3, mix=0.12)


@cue("castCancel")
def cast_cancel(r):
    """Line reeled back in quickly: a short ratchet burst that speeds up and
    stops dead with a click."""
    dur = 0.40
    # Accelerating clicks - the spool spinning up as it takes up slack.
    out = _ticks(r, dur, _accel_times(0.0, dur - 0.05, 0.030, 0.86, floor=0.010),
                 level=0.75, res=2600.0, low=1400.0, high=8500.0, decay=0.0030)
    whir = S.bp_sweep(S.white(dur, r), S.expsweep(dur, 900.0, 2600.0), q=3.0)
    whir *= S.breakpoints(dur, [(0.0, 0.0), (0.04, 0.5), (0.3, 0.35), (dur, 0.0)])
    stop = S.place(S.silence(dur), S.metal_hit(0.09, r, 900.0, ring=0.25) * 0.5, dur - 0.09)
    return _room(S.mix(out * 0.8, whir * 0.5, stop), size=0.3, mix=0.10)


# ---------------------------------------------------------------------------
# the bobber and the bite
# ---------------------------------------------------------------------------

@cue("bobberPlop")
def bobber_plop(r):
    """The signature cue. Three layers, exactly as the contract describes:

    a BUBBLE chirp (a sine rising 300 -> 900 Hz over 60 ms - rising, because
    a falling pitch reads as a cave drip and a rising one reads as water
    closing over something), a bandpassed noise SPLASH with a fast low-pass
    sweep for the spray, and a tail of DROPLETS falling back.

    Since the realism pass it has five: an ENTRY spit (the surface tension
    breaking - 1.5 ms, and without it the plop starts 20 ms late to the
    ear), the bubble chirp, the low GULP (`_gulp`: the cavity closing over
    the bobber, a pitch that dips and comes back - that turn is what stops
    it sounding like a kick drum), the spray, and droplets falling back.
    """
    dur = 0.48
    entry = S.band_noise(0.0015, r, 1200.0, 13000.0) * S.perc_env(0.0015, 0.0002, 0.0005)

    bub = S.bubble(0.060, 300.0, r, rise=3.0, tau=0.030)
    bub = S.fit(bub, dur) * 0.85

    gulp = S.fit(_gulp(r, 0.26, 205.0, level=0.75), dur)

    spray = S.splash(0.22, r, low=800.0, high=9500.0, sweep_to=420.0, body=0.0)
    spray = S.fit(spray, dur) * 0.55

    thud = S.sine(dur, S.expsweep(dur, 150.0, 62.0)) * S.perc_env(dur, 0.002, 0.045)
    thud = S.saturate(thud * 0.5, 1.8)

    # The ring of water spreading out - quiet, but it is the reason the
    # plop sounds like it happened ON something rather than in a booth.
    ring = S.wet_texture(0.30, r, density=10.0, freq=900.0, spread=2.4, level=0.22)
    ring = S.fit(ring, 0.30) * S.breakpoints(0.30, [(0.0, 0.3), (0.08, 1.0), (0.30, 0.0)])

    tail = S.fit(_droplets(r, count=7, spread=0.24, level=0.30, start=0.09), dur)
    y = S.mix(S.fit(entry, dur) * 0.5, bub, gulp, spray, thud * 0.45,
              S.place(S.silence(dur), ring, 0.07), tail)
    return _lead(_room(y, size=0.45, damping=0.6, mix=0.18, predelay=0.006))


@cue("bobberBob", loop=True)
def bobber_bob(r):
    """Loop: gentle lapping at a floating bobber.

    LOOP-SAFE means the last moment has to hand over to the first without a
    seam. Two things do that here: the wet texture is scattered inside the
    body only (nothing starts in the final 0.2 s), and the swell LFO
    completes a whole number of cycles across the loop, so the level at the
    end equals the level at the start.
    """
    dur = 2.4
    nn = S.n(dur)
    phase = np.arange(nn) / float(nn)

    lap = S.wet_texture(dur - 0.25, r, density=7.0, freq=620.0, spread=1.8, level=0.5)
    lap = S.fit(lap, dur)
    wash = S.band_noise(dur, r, 220.0, 2400.0, order=2) * 0.20
    swell = 0.55 + 0.45 * np.sin(2.0 * np.pi * 3.0 * phase)   # 3 whole swells

    # The float itself. A cork on the water is not only water: it has a
    # small hollow body that the swell rocks, so a quiet resonance at ~330 Hz
    # breathes with a SECOND LFO at a different whole-cycle rate (2 against
    # 3). Two incommensurate-sounding rates that both close over the loop
    # are what stops a 2.4 s bed sounding like a 2.4 s bed.
    hollow = S.band_noise(dur, r, 260.0, 900.0, order=2)
    hollow = S.resonator(hollow, 334.0, q=14.0) * 0.9 + S.resonator(hollow, 512.0, q=9.0) * 0.4
    hollow = hollow / (np.max(np.abs(hollow)) + 1e-12)
    hollow *= 0.16 * (0.45 + 0.55 * (0.5 + 0.5 * np.sin(2.0 * np.pi * 2.0 * phase)))

    # A handful of small bubbles under the float, all of them finished well
    # before the loop point (nothing may start in the last 0.25 s).
    pops = S.silence(dur)
    for _ in range(5):
        at = 0.05 + float(r.random()) * (dur - 0.45)
        f = 700.0 * float(2.0 ** (r.random() * 1.2 - 0.6))
        pops = S.place(pops, S.bubble(0.035, f, r, rise=2.2) * 0.10, at)

    y = S.mix(lap * 0.8, wash * swell, hollow, pops)
    y = S.lowpass(y, 3400.0, order=2)
    return _room(y, size=0.4, mix=0.14, damping=0.7, tail=False)


@cue("tug")
def tug(r):
    """A fish pulls: a sharp water tug over a low thump. The pull is a
    downward noise sweep (water being dragged), the thump is the mass."""
    dur = 0.36
    pull = S.band_noise(0.18, r, 500.0, 6000.0, order=3)
    pull = S.lp_sweep(pull, S.expsweep(0.18, 6000.0, 500.0), order=2)
    pull *= S.perc_env(0.18, 0.0015, 0.045, curve=1.2)
    pull = S.fit(pull, dur)

    thump = S.sine(dur, S.expsweep(dur, 190.0, 58.0)) * S.perc_env(dur, 0.0015, 0.075)
    thump = S.saturate(thump, 2.2)

    # The line taking it: a short creak that arrives 25 ms AFTER the water,
    # because the rod feels the fish a moment after the fish moves.
    line = S.place(S.silence(dur), _creak(r, 0.16, 1250.0, 2100.0, level=0.30,
                                          q=30.0, rough=23.0, attack=0.012), 0.025)

    ripple = S.fit(_droplets(r, count=4, spread=0.14, level=0.22, start=0.06, freq=1200.0), dur)
    return _lead(_room(S.mix(pull * 0.75, thump * 0.8, line, ripple), size=0.4,
                       mix=0.15, predelay=0.005))


# ---------------------------------------------------------------------------
# the reel bar
# ---------------------------------------------------------------------------

@cue("reelOpen")
def reel_open(r):
    """Mechanical click-whirr: the bail closing, then the spool spinning up."""
    dur = 0.42
    # 1. The bail arm going over: a metal clack with a low body under it so
    #    it is a PART moving, not a ping.
    click = S.metal_hit(0.07, r, 1400.0, ring=0.2, roughness=0.4) * 0.9
    seat = S.sine(0.05, S.expsweep(0.05, 240.0, 120.0)) * S.perc_env(0.05, 0.0012, 0.012)

    # 2. The spool spinning down: real pawl clicks through `_ticks`, their
    #    rate DECELERATING. The old version was a noise spit per tick, which
    #    is why it read as static rather than as a ratchet.
    whirr = _ticks(r, dur, _accel_times(0.050, 0.36, 0.0155, 1.055),
                   level=0.55, res=2900.0, decay=0.0030)

    # 3. The drag washer under it all, creaking as the spool loads it.
    drag = S.place(S.silence(dur), _creak(r, 0.24, 780.0, 560.0, level=0.22,
                                          q=22.0, rough=13.0), 0.045)

    tone = S.bp_sweep(S.white(dur, r), S.expsweep(dur, 2400.0, 1300.0), q=5.0)
    tone *= S.breakpoints(dur, [(0.0, 0.0), (0.06, 0.6), (0.30, 0.3), (dur, 0.0)])
    body = S.fit(click, dur)
    return _lead(_room(S.mix(body, S.fit(S.saturate(seat * 0.6, 1.8), dur), whirr,
                             drag, tone * 0.28),
                       size=0.3, mix=0.11, predelay=0.005))


@cue("reelTension", loop=True)
def reel_tension(r):
    """Loop: line under strain - a creaking ratchet with a stressed tone.

    Comb-filtered noise pulses at ~14 Hz (the ratchet pawl), a comb tuned to
    a low pitch so each pulse RINGS instead of just ticking, and a stressed
    tone that beats slightly. The client scales the whole thing by marker
    tension, so this is authored at a neutral middle strain.

    Loop-safety: the pulse rate divides the loop length exactly (14 Hz x
    1.0 s = 14 pulses), so pulse 15 lands exactly where pulse 1 did.

    Since the realism pass the pawl is `_ticks` - an individually rung
    click per pulse, with its resonance and level jittered - rather than a
    comb-filtered noise pulse train, and the drag creak is a real
    `_creak` resonator whose two LFOs complete whole cycles across the
    loop. The client scales the whole thing by marker tension.
    """
    dur = 1.0
    rate = 14.0
    nn = S.n(dur)
    phase = np.arange(nn) / float(nn)

    ratchet = _ticks(r, dur, [i / rate for i in range(int(rate * dur))],
                     level=0.85, res=1500.0, low=600.0, high=7000.0,
                     decay=0.0060, jitter=0.22, spread=0.16)
    ratchet = S.bandpass(ratchet, 180.0, 6000.0, order=2)
    ratchet = ratchet / (np.max(np.abs(ratchet)) + 1e-12)
    # The pawl is not hit equally hard all the way round the spool: a 2-cycle
    # weight makes it breathe without moving the pulse grid.
    ratchet *= 0.72 + 0.28 * (0.5 + 0.5 * np.sin(2.0 * np.pi * 2.0 * phase))

    # The drag washer slipping. Loop-safe: built from steady noise shaped by
    # whole-cycle LFOs, so there is no envelope to land in the wrong place.
    drag = S.band_noise(dur, r, 300.0, 3500.0, order=2)
    drag *= 0.3 + 0.7 * (0.5 + 0.5 * np.sin(2.0 * np.pi * 7.0 * phase))
    drag = S.resonator(drag, 640.0, q=24.0) * 0.9 + S.resonator(drag, 980.0, q=16.0) * 0.4
    drag = drag / (np.max(np.abs(drag)) + 1e-12)
    drag *= 0.26 * (0.4 + 0.6 * (0.5 + 0.5 * np.sin(2.0 * np.pi * 3.0 * phase)))

    # The stressed line: two close tones beating, plus a slow creak wobble.
    stress = (S.sine(dur, 196.0) + S.sine(dur, 197.6) * 0.8) * 0.30
    stress = S.vibrato(stress, rate=3.0, depth_cents=22.0)
    stress = S.saturate(stress, 2.4) * 0.35

    # A little low body so the loop has weight at 3D distance as well as
    # in the ears; 4 whole cycles, so the loop point sits on a zero.
    body = S.sine(dur, 98.0) * 0.10 * (0.5 + 0.5 * np.sin(2.0 * np.pi * 4.0 * phase))

    y = S.mix(ratchet * 0.8, drag, stress, S.saturate(body, 1.6))
    return S.lowpass(y, 7000.0, order=2)


@cue("reelMiss")
def reel_miss(r):
    """Dull thunk - a wood knock with the top taken off and no ring.

    Now with the two things a thunk has and a filtered knock does not: a
    MEMBRANE under it (the reel body is a box with a face, and the face
    moves) and a short damped wood ring from the rod butt it is bolted to.
    """
    dur = 0.30
    exc = S.fit(S.white(0.004, r) * S.perc_env(0.004, 0.0002, 0.0012), dur)
    body = np.zeros(S.n(dur))
    for i, f in enumerate((140.0, 232.0, 361.0)):
        body += S.resonator(exc, f, q=11.0) / (i + 1.4)
    body *= S.expdec(dur, 0.055)

    head = S.membrane(0.22, 92.0, r, drop=0.55, noise=0.20, tau=0.050)
    head = S.saturate(head * 0.85, 2.0)

    butt = S.bar(0.14, 196.0, r, decay=0.040, strike=0.25) * 0.30

    low = S.sine(dur, S.expsweep(dur, 130.0, 74.0)) * S.perc_env(dur, 0.002, 0.05)
    y = S.mix(body * 0.9, S.fit(head, dur) * 0.8, S.fit(butt, dur),
              S.saturate(low * 0.7, 2.0))
    return _lead(_room(S.lowpass(y, 2600.0, order=2), size=0.3, mix=0.12,
                       predelay=0.005))


@cue("reelZoneShrink")
def reel_zone_shrink(r):
    """A tight descending tick - three fast blips walking down. Tells the
    player the target got smaller without stealing attention."""
    dur = 0.20
    out = S.silence(dur)
    for i, f in enumerate((2200.0, 1750.0, 1380.0)):
        blip = S.sine(0.030, S.expsweep(0.030, f, f * 0.82))
        blip *= S.perc_env(0.030, 0.0008, 0.008)
        blip = S.mix(blip, S.bar(0.030, f * 1.5, r, decay=0.012) * 0.25)
        out = S.place(out, blip * (1.0 - 0.18 * i), i * 0.038)
    return _room(out * 0.8, size=0.25, mix=0.10)


# ---------------------------------------------------------------------------
# the tap minigame
# ---------------------------------------------------------------------------

@cue("burstOpen")
def burst_open(r):
    """The bar appears: a short rising sweep with a soft bell on top."""
    dur = 0.30
    sweepy = S.sine(dur, S.expsweep(dur, 330.0, 880.0)) * S.perc_env(dur, 0.006, 0.09)
    ring = S.bell(0.26, 880.0, r, decay=0.14, strike=0.4) * 0.45
    air = S.bp_sweep(S.white(0.14, r), S.expsweep(0.14, 3000.0, 7000.0), q=3.0)
    air *= S.perc_env(0.14, 0.004, 0.04) * 0.3
    return _room(S.mix(sweepy * 0.7, S.fit(ring, dur), S.fit(air, dur)), size=0.35, mix=0.14)


@cue("burstTap")
def burst_tap(r):
    """One tap lands - a bright, very short marimba blip. This fires many
    times a second, so it has to be short and never fatiguing."""
    dur = 0.09
    y = S.bar(dur, 1174.7, r, decay=0.035, strike=0.7)     # D6
    click = S.band_noise(0.003, r, 3000.0, 11000.0) * S.perc_env(0.003, 0.0002, 0.0008)
    return S.mix(y * 0.85, S.fit(click, dur) * 0.3)


@cue("burstFill")
def burst_fill(r):
    """The bar fills: a fast rising arpeggio into a bright chord."""
    dur = 0.55
    out = S.silence(dur)
    for i, m in enumerate((587.33, 739.99, 880.0, 1174.66)):   # D F# A D
        v = S.bar(0.30, m, r, decay=0.16, strike=0.6)
        out = S.place(out, v * (0.55 + 0.15 * i), i * 0.045)
    shim = S.bp_sweep(S.white(0.3, r), S.expsweep(0.3, 4000.0, 10000.0), q=2.5)
    shim *= S.perc_env(0.3, 0.01, 0.10) * 0.25
    out = S.place(out, shim, 0.14)
    return _room(out * 0.8, size=0.5, mix=0.20)


@cue("burstFail")
def burst_fail(r):
    """The tap minigame is lost: a downward buzz with a dead thud under it."""
    dur = 0.42
    buzz = S.pulse(0.26, S.expsweep(0.26, 300.0, 130.0), 0.30)
    buzz = S.moog(buzz, S.expsweep(0.26, 1600.0, 400.0), res=0.45)
    buzz *= S.perc_env(0.26, 0.004, 0.09)
    thud = S.sine(dur, S.expsweep(dur, 120.0, 55.0)) * S.perc_env(dur, 0.002, 0.09)
    y = S.mix(S.fit(buzz, dur) * 0.6, S.saturate(thud, 2.2) * 0.8)
    return _room(y, size=0.35, mix=0.12)


# ---------------------------------------------------------------------------
# the snap minigame
# ---------------------------------------------------------------------------

@cue("snapAppear")
def snap_appear(r):
    """The target appears: a single glassy ping with a fast shimmer. Has to
    cut through everything else, so it lives high and is very short."""
    dur = 0.26
    y = S.bell(dur, 1567.98, r, decay=0.16, strike=0.8, inharmonic=0.7)   # G6
    air = S.bp_sweep(S.white(0.10, r), S.expsweep(0.10, 6000.0, 12000.0), q=2.0)
    air *= S.perc_env(0.10, 0.001, 0.025) * 0.35
    return _room(S.mix(y * 0.9, S.fit(air, dur)), size=0.4, mix=0.18)


@cue("snapHit")
def snap_hit(r):
    """The snap lands: a hard transient with a rising confirm. Reward has to
    arrive with the input, so the attack is under a millisecond."""
    dur = 0.30
    snap = S.band_noise(0.012, r, 1800.0, 12000.0) * S.perc_env(0.012, 0.0001, 0.0025)
    tone = S.sine(0.16, S.expsweep(0.16, 880.0, 1760.0)) * S.perc_env(0.16, 0.001, 0.045)
    body = S.bar(0.24, 1174.66, r, decay=0.11, strike=0.9) * 0.7
    y = S.mix(S.fit(snap, dur) * 0.8, S.fit(tone, dur) * 0.55, S.fit(body, dur))
    return _room(y, size=0.4, mix=0.16)


@cue("snapMiss")
def snap_miss(r):
    """The snap is missed: a flat, damped click that goes nowhere."""
    dur = 0.16
    click = S.band_noise(0.010, r, 400.0, 2600.0) * S.perc_env(0.010, 0.0002, 0.003)
    body = S.bar(0.12, 233.08, r, decay=0.035, strike=0.3) * 0.6
    return S.lowpass(S.mix(S.fit(click, dur), S.fit(body, dur)), 1800.0, order=2)


# ---------------------------------------------------------------------------
# the reveal stingers - one escalation, one key (D major)
# ---------------------------------------------------------------------------

def _shimmer(r, dur, low=5000.0, high=13000.0, level=0.3, attack=0.02):
    y = S.bp_sweep(S.white(dur, r), S.expsweep(dur, low, high), q=1.8)
    y *= S.breakpoints(dur, [(0.0, 0.0), (attack, 1.0), (dur, 0.0)], curve="exp")
    return y * level


@cue("catchCommon")
def catch_common(r):
    """A two-note plink. Deliberately small: this fires constantly."""
    dur = 0.34
    out = S.silence(dur)
    for i, f in enumerate((587.33, 880.0)):        # D5 -> A5
        v = S.bar(0.24, f, r, decay=0.13, strike=0.55)
        out = S.place(out, v * (0.85 if i == 0 else 1.0), i * 0.085)
    return _room(out * 0.8, size=0.4, mix=0.16)


@cue("catchUncommon")
def catch_uncommon(r):
    """Three notes up the triad, with a little air on the last."""
    dur = 0.52
    out = S.silence(dur)
    for i, f in enumerate((587.33, 739.99, 880.0)):    # D F# A
        v = S.bar(0.30, f, r, decay=0.16, strike=0.6)
        out = S.place(out, v * (0.8 + 0.1 * i), i * 0.075)
    out = S.place(out, _shimmer(r, 0.22, 4500.0, 9000.0, 0.16), 0.18)
    return _room(out * 0.8, size=0.45, mix=0.18)


@cue("catchRare")
def catch_rare(r):
    """A chord stab plus sparkle - the first one that feels like an event."""
    dur = 0.9
    out = S.silence(dur)
    for i, f in enumerate((293.66, 440.0, 587.33, 739.99)):   # D3 A3 D4 F#4
        v = S.bar(0.55, f, r, decay=0.30, strike=0.6)
        out = S.place(out, v * (0.9 - 0.08 * i), i * 0.018)
    for i, f in enumerate((1174.66, 1479.98, 1760.0)):
        out = S.place(out, S.bell(0.5, f, r, decay=0.28, strike=0.5) * 0.30,
                      0.12 + i * 0.055)
    out = S.place(out, _shimmer(r, 0.5, 5000.0, 11000.0, 0.20), 0.10)
    return _room(out * 0.75, size=0.7, mix=0.22)


@cue("catchEpic")
def catch_epic(r):
    """A rising figure over a sustained chord, with shimmer and a swell."""
    dur = 1.5
    out = S.silence(dur)
    # Bed: a held Dmaj chord on soft bells.
    for f in (146.83, 293.66, 440.0, 587.33):
        out = S.place(out, S.bell(1.2, f, r, decay=0.75, strike=0.4) * 0.28, 0.0)
    # The rising figure.
    figure = [587.33, 739.99, 880.0, 1174.66, 1479.98, 1760.0]
    for i, f in enumerate(figure):
        v = S.bell(0.7, f, r, decay=0.34, strike=0.7, inharmonic=0.6)
        out = S.place(out, v * (0.42 + 0.06 * i), 0.06 + i * 0.070)
    out = S.place(out, _shimmer(r, 0.9, 4000.0, 13000.0, 0.22, attack=0.25), 0.20)
    swellup = S.band_noise(0.5, r, 200.0, 1200.0, order=2)
    swellup *= S.breakpoints(0.5, [(0.0, 0.0), (0.45, 1.0), (0.5, 0.0)], curve="exp")
    out = S.place(out, swellup * 0.18, 0.0)
    return _room(out * 0.7, size=0.9, mix=0.26)


@cue("catchLegendary")
def catch_legendary(r):
    """The full 2 s fanfare: chord stab, arpeggio, shimmer, a brass swell
    and a low hit to seat it. This is the biggest thing on the sheet, so it
    gets the most layers and the largest room."""
    dur = 2.2
    out = S.silence(dur)

    # 1. The stab: a wide D major chord across four octaves, struck at once.
    for f in (146.83, 220.0, 293.66, 440.0, 587.33, 880.0, 1174.66):
        out = S.place(out, S.bell(1.6, f, r, decay=0.9, strike=0.6) * 0.24, 0.0)
    low = S.sine(dur, S.expsweep(dur, 110.0, 73.4)) * S.perc_env(dur, 0.003, 0.35)
    out = S.mix(out, S.saturate(low * 0.6, 2.0) * 0.5)

    # 2. The arpeggio climbing over it.
    arp_notes = [587.33, 739.99, 880.0, 1174.66, 1479.98, 1760.0, 2349.32]
    for i, f in enumerate(arp_notes):
        v = S.bell(0.9, f, r, decay=0.42, strike=0.75, inharmonic=0.55)
        out = S.place(out, v * (0.30 + 0.045 * i), 0.30 + i * 0.085)

    # 3. A brass-ish swell answering underneath (saw stack through a filter).
    br = S.supersaw(1.1, 293.66, voices=5, detune=0.008, phase_seed=r)
    br = S.moog(br, S.breakpoints(1.1, [(0.0, 400.0), (0.5, 2600.0), (1.1, 900.0)]), res=0.35)
    br *= S.breakpoints(1.1, [(0.0, 0.0), (0.35, 1.0), (0.8, 0.8), (1.1, 0.0)], curve="exp")
    out = S.place(out, S.saturate(br * 0.35, 1.6), 0.22)

    # 4. Shimmer over the top and a last high sparkle.
    out = S.place(out, _shimmer(r, 1.4, 4000.0, 15000.0, 0.20, attack=0.5), 0.25)
    for i in range(7):
        f = 2093.0 * float(2.0 ** (r.random() * 1.2))
        out = S.place(out, S.bell(0.35, f, r, decay=0.16, strike=0.5) * 0.12,
                      0.9 + float(r.random()) * 0.9)

    return _room(out * 0.72, size=1.1, damping=0.4, mix=0.28)


@cue("catchBoss")
def catch_boss(r):
    """The summon answers the call: a low ominous swell, deliberately OUTSIDE
    the stingers' key so it never sounds like a reward."""
    dur = 2.4
    out = S.silence(dur)
    # A rising minor cluster on drones, growing out of nothing.
    for f in (43.65, 65.41, 87.31, 103.83):        # F1 C2 F2 G#2
        v = S.supersaw(2.0, f, voices=4, detune=0.005, phase_seed=r)
        v = S.lowpass(v, 700.0, order=2)
        v *= S.breakpoints(2.0, [(0.0, 0.0), (1.5, 1.0), (1.85, 0.9), (2.0, 0.0)],
                           curve="exp")
        out = S.place(out, v * 0.28, 0.0)
    # A distant bell tolling once, and the water answering.
    out = S.place(out, S.bell(1.6, 116.54, r, decay=1.1, strike=0.8) * 0.35, 0.55)
    rumble = S.brown(2.0, r) * 0.5
    rumble = S.lowpass(rumble, 160.0, order=2)
    rumble *= S.breakpoints(2.0, [(0.0, 0.0), (1.6, 1.0), (2.0, 0.1)], curve="exp")
    out = S.place(out, rumble, 0.1)
    surge = S.splash(0.7, r, low=200.0, high=2500.0, sweep_to=180.0, body=0.6)
    out = S.place(out, surge * 0.35, 1.45)
    return _room(S.saturate(out * 0.7, 1.4), size=1.4, damping=0.35, mix=0.30)


# ---------------------------------------------------------------------------
# hauling and the fish itself
# ---------------------------------------------------------------------------

@cue("salvageHaul")
def salvage_haul(r):
    """A wet crate thudding onto the boards, then coins spilling out of it."""
    dur = 1.1
    out = S.silence(dur)
    # The crate: a big wooden thud with water coming off it.
    thud = S.membrane(0.4, 74.0, r, drop=0.55, noise=0.25, tau=0.10)
    out = S.place(out, S.saturate(thud * 0.9, 2.0), 0.0)
    for i, f in enumerate((128.0, 205.0, 331.0)):
        knock = S.resonator(S.fit(S.white(0.004, r) * S.perc_env(0.004, 0.0002, 0.001), 0.35),
                            f, q=14.0)
        out = S.place(out, knock * (0.5 / (i + 1)) * S.expdec(0.35, 0.09), 0.002)
    out = S.place(out, S.splash(0.35, r, low=600.0, high=7000.0, body=0.0) * 0.35, 0.02)
    # The coins: a scatter of small bright bells, all in one bright key.
    for _ in range(14):
        f = 2400.0 * float(2.0 ** (r.random() * 1.5))
        at = 0.16 + float(r.random()) * 0.55
        out = S.place(out, S.bell(0.22, f, r, decay=0.08, strike=0.7) * 0.16, at)
    return _room(out * 0.8, size=0.6, damping=0.5, mix=0.20)


@cue("fishSurface")
def fish_surface(r):
    """A fish breaks the surface: water opening, then closing over it.

    A real one is five things in 400 ms: the SLAP of a wet body arriving at
    the surface (2 ms, and it is the whole transient), the sheet of water
    OPENING, the bubbles released under it, the water CLOSING back over,
    and droplets landing after. 3D, so the room is small and the body is
    big - at twenty studs the tail is the first thing to go.
    """
    dur = 0.62
    slap = S.band_noise(0.024, r, 500.0, 9000.0, order=2)
    slap = S.lp_sweep(slap, S.expsweep(0.024, 8000.0, 1100.0), order=2)
    slap *= S.perc_env(0.024, 0.0008, 0.006, curve=1.3)

    breakout = S.splash(0.26, r, low=900.0, high=11000.0, sweep_to=600.0, body=0.25)
    close = S.splash(0.30, r, low=500.0, high=6000.0, sweep_to=300.0, body=0.5)
    swirl = S.bubble(0.09, 260.0, r, rise=2.6)
    fizz = S.wet_texture(0.34, r, density=22.0, freq=1100.0, spread=2.4, level=0.34)
    mass = S.membrane(0.20, 84.0, r, drop=0.5, noise=0.30, tau=0.050)

    out = S.silence(dur)
    out = S.place(out, slap * 0.85, 0.0)
    out = S.place(out, S.saturate(mass * 0.7, 2.0), 0.004)
    out = S.place(out, breakout * 0.9, 0.006)
    out = S.place(out, S.fit(swirl, 0.12) * 0.5, 0.03)
    out = S.place(out, S.fit(fizz, 0.34) * 0.55, 0.05)
    out = S.place(out, close * 0.7, 0.16)
    out = S.place(out, _droplets(r, count=8, spread=0.26, level=0.28, start=0.20), 0.0)
    return _lead(_room(out, size=0.42, damping=0.65, mix=0.15, predelay=0.005))


@cue("flopWater")
def flop_water(r):
    """A fish slapping the water - two quick slaps, the second smaller.

    Each slap is now THREE things, not one `splash()`: the skin-on-water
    transient (2 ms), the water displaced (the splash), and the body behind
    it (a membrane at 80-95 Hz). The second slap is off the grid by 15 ms
    and a semitone lower, because a fish is not a metronome.
    """
    dur = 0.54
    out = S.silence(dur)
    for i, (at, amp) in enumerate(((0.0, 1.0), (0.150, 0.62))):
        p = 1.0 + 0.2 * i
        crack = S.band_noise(0.020, r, 600.0 * p, 9000.0, order=2)
        crack = S.lp_sweep(crack, S.expsweep(0.020, 7500.0, 1000.0), order=2)
        crack *= S.perc_env(0.020, 0.0008, 0.005, curve=1.3)
        slap = S.splash(0.20, r, low=700.0 * p, high=9000.0, sweep_to=420.0, body=0.45)
        mass = S.membrane(0.16, 92.0 / p, r, drop=0.5, noise=0.30, tau=0.042)
        one = S.mix(S.fit(crack, 0.22) * 0.7, S.fit(slap, 0.22),
                    S.fit(S.saturate(mass * 0.75, 2.0), 0.22) * 0.7)
        out = S.place(out, one * amp, at + (0.0 if i == 0 else 0.008 * float(r.random())))
    fizz = S.wet_texture(0.26, r, density=18.0, freq=1000.0, spread=2.3, level=0.26)
    out = S.place(out, S.fit(fizz, 0.26) * 0.5, 0.03)
    out = S.place(out, _droplets(r, count=6, spread=0.20, level=0.25, start=0.18), 0.0)
    return _lead(_room(out * 0.9, size=0.42, damping=0.65, mix=0.14, predelay=0.005))


@cue("landGround")
def land_ground(r):
    """The fish lands on dock or sand: a soft wet thud on wood, no ring."""
    dur = 0.42
    body = S.membrane(0.24, 96.0, r, drop=0.6, noise=0.35, tau=0.055)
    plank = S.resonator(S.fit(S.white(0.004, r) * S.perc_env(0.004, 0.0002, 0.001), 0.30),
                        168.0, q=9.0) * 0.6
    plank += S.resonator(S.fit(S.white(0.004, r) * S.perc_env(0.004, 0.0002, 0.001), 0.30),
                         310.0, q=7.0) * 0.3
    plank *= S.expdec(0.30, 0.07)
    wet = S.band_noise(0.10, r, 700.0, 4500.0) * S.perc_env(0.10, 0.001, 0.020) * 0.4
    # The wet skin hitting first - 1.5 ms, and it is what places the event.
    skin = S.band_noise(0.015, r, 900.0, 8000.0, order=2)
    skin = S.lp_sweep(skin, S.expsweep(0.015, 7000.0, 1300.0), order=2)
    skin *= S.perc_env(0.015, 0.0006, 0.0035, curve=1.3)
    drip = _droplets(r, count=4, spread=0.16, level=0.18, start=0.07, freq=2200.0)
    y = S.mix(S.fit(S.saturate(body * 0.9, 1.8), dur), S.fit(plank, dur),
              S.fit(wet, dur), S.fit(skin, dur) * 0.55, S.fit(drip, dur))
    return _lead(_room(S.lowpass(y, 5000.0, order=2), size=0.4, damping=0.6,
                       mix=0.13, predelay=0.004))


@cue("flopGround")
def flop_ground(r):
    """Wet flop on planks: three irregular slaps with wood under each one.
    Irregular ON PURPOSE - three evenly spaced slaps read as a machine.

    Each slap is a SKIN transient, the wet layer, the plank under it, and
    now the thing that was missing: the tail flicking BACK on the boards a
    few tens of milliseconds later, quieter and higher. A fish on a dock
    makes a double knock, not a single one, and that is the whole read.
    """
    return _flop_ground(r)


def _flop_ground(r, p=1.0, lv=1.0, sk=1.0):
    dur = 0.90 * sk
    out = S.silence(dur)
    times = [0.0 * sk, 0.19 * sk, 0.44 * sk]
    amps = [1.0, 0.72, 0.5]
    for at, amp in zip(times, amps):
        jit = 0.012 * (float(r.random()) - 0.5)
        skin = S.band_noise(0.016, r, 800.0, 8000.0, order=2)
        skin = S.lp_sweep(skin, S.expsweep(0.016, 7000.0, 1200.0), order=2)
        skin *= S.perc_env(0.016, 0.0006, 0.004, curve=1.3)
        wet = S.band_noise(0.09, r, 600.0, 5500.0, order=3)
        wet = S.lp_sweep(wet, S.expsweep(0.09, 5000.0, 900.0), order=2)
        wet *= S.perc_env(0.09, 0.0008, 0.016, curve=1.2)
        wood = S.membrane(0.18, 118.0 * p * (0.9 + 0.2 * float(r.random())), r,
                          drop=0.65, noise=0.15, tau=0.035)
        plank = S.bar(0.12, 176.0 * p * (0.94 + 0.12 * float(r.random())), r,
                      decay=0.035, strike=0.35) * 0.28
        one = S.mix(S.fit(skin, 0.20) * 0.6, S.fit(wet, 0.20) * 0.8,
                    S.fit(S.saturate(wood * 0.7, 1.8), 0.20) * 0.7,
                    S.fit(plank, 0.20))
        out = S.place(out, one * amp, max(0.0, at + jit))
        # the tail coming back down
        flick = S.mix(S.fit(S.band_noise(0.010, r, 1200.0, 9000.0)
                            * S.perc_env(0.010, 0.0005, 0.0028), 0.10),
                      S.fit(S.membrane(0.08, 165.0, r, drop=0.6, noise=0.2,
                                       tau=0.018), 0.10) * 0.5)
        out = S.place(out, flick * amp * 0.42,
                      at + 0.055 + 0.025 * float(r.random()))
    drip = _droplets(r, count=4, spread=0.40 * sk, level=0.16, start=0.12, freq=2400.0)
    out = S.mix(out, S.fit(drip, dur))
    return _lead(_room(S.lowpass(out, 6500.0 * p, order=2), size=0.45, damping=0.6,
                       mix=0.14, predelay=0.005)) * lv


def _take(i):
    """Three baked takes. A sprite plays back identically every time, so a
    fish landing on the same dock three times running was audibly the same
    three-slap pattern; the client's resolver fans `flopGround` out to
    these. (pitch, level, time-skew), no two close on more than one axis."""
    return ((1.00, 1.00, 1.00),
            (1.06, 0.92, 0.95),
            (0.95, 0.98, 1.06))[i % 3]


@cue("flopGround", variants=3)
def flop_ground_takes(r, i):
    """Three takes of `flopGround`. The base cue above stays the fallback."""
    return _flop_ground(r, *_take(i))
