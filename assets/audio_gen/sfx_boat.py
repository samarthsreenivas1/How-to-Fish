"""sfx_boat.py - the `boat` sheet. Eleven cues, one vessel.

The boat is a small wooden hull with a tin outboard on the back. Everything
here is built from three materials so the set reads as ONE object:

  WOOD    resonators at 118 / 196 / 311 Hz over a 4 ms noise exciter. That
          triad is the hull, and it appears in board, leave, creak, hit,
          arrive and upgrade. Reuse of a resonance set is what makes a
          sound-family; a different pitch per cue reads as different props.
  WATER   `S.splash` with a low sweep_to (this is a heavy displacement, not
          a bobber) plus scattered droplets.
  TIN     `S.metal_hit` at 520 Hz for the engine cowl and the alarm bell.

Loop cues (`boatEngine`, `boatWash`) are authored at an exact length with
whole LFO cycles, nothing starting in the last period, and
`reverb(..., tail=False)` so the file never runs past its own loop point.

Register plan, so no two cues collide: summon is the only cue above 900 Hz
with a sustained pitch; warn is the only repeated bright bell; hit and
arrive share a register but arrive is 4x longer and ends in wash.
"""

import numpy as np

import synth as S
from cues import cue


# The 5 ms lead-in. `build.finish_cue` puts a 3 ms fade on BOTH edges of
# every cue as click insurance - correct in general, but that fade lands on
# the transient of any cue whose peak is at t=0 (a footstep, a click, a
# gunshot) and takes 50-80% off it, which is precisely the part of the sound
# the ear uses to place the event. Five milliseconds of leading silence puts
# the transient clear of the fade. It is well under the ~10 ms at which
# anyone perceives latency, and it costs 5 ms of sprite.
#
# LOOP cues must never use it: silence inside the loop period is a hole once
# per lap. Every helper below therefore applies it only on the `tail=True`
# (one-shot) path.
LEAD = 0.005


def _lead(x):
    return S.place(S.silence(LEAD), x, LEAD)

HULL = (118.0, 196.0, 311.0)     # the wooden hull's resonance triad


def _open_water(x, size=0.75, damping=0.5, mix=0.16, tail=True):
    """The boat lives outside: a big, soft, damp space with little early
    reflection. Small rooms would put the sea in a shed."""
    y = S.reverb(x, size=size, damping=damping, mix=mix, seed=23, tail=tail)
    return _lead(y) if tail else y


def _tick(r, dur=0.004, low=1200.0, high=9000.0):
    """The universal exciter: a few ms of band noise. Feeding resonators
    from this rather than from a click keeps them from all sounding
    identical, because the noise seeds each resonator differently."""
    return S.band_noise(dur, r, low, high) * S.perc_env(dur, 0.0002, dur * 0.3)


def _wood(r, dur, freqs=HULL, decay=0.09, bright=1.0, gain=1.0):
    """Struck hull: the HULL triad rung by a noise tick. `bright` scales the
    exciter band, which is the difference between a knuckle and a boot."""
    exc = S.fit(_tick(r, 0.004, 700.0 * bright, 7000.0 * bright), dur)
    out = np.zeros(S.n(dur))
    for i, f in enumerate(freqs):
        out += S.resonator(exc, f, q=10.0 + 3.0 * i) / (i + 1.3)
    return out * S.expdec(dur, decay) * gain


def _droplets(r, count=6, spread=0.3, level=0.3, start=0.08, freq=1500.0):
    out = S.silence(start + spread + 0.1)
    for _ in range(count):
        at = start + float(r.random()) * spread
        f = freq * float(2.0 ** (r.random() * 1.4 - 0.7))
        d = 0.02 + 0.03 * float(r.random())
        out = S.place(out, S.bubble(d, f, r, rise=2.0 + 1.2 * float(r.random()))
                      * (0.3 + 0.7 * float(r.random())) * level, at)
    return out


def _creak(r, dur, f0=210.0, f1=330.0, roughness=26.0, level=1.0):
    """Stick-slip: wood or rope under load does not slide smoothly, it grabs
    and releases. Model it as a burst of irregular grains through a comb
    whose pitch bends - the bend is what makes it a creak and not a rattle."""
    grains = S.silence(dur)
    at = 0.012
    while at < dur - 0.04:
        g = S.band_noise(0.005, r, 500.0, 5200.0) * S.perc_env(0.005, 0.0002, 0.0014)
        grains = S.place(grains, g * (0.4 + 0.6 * float(r.random())), at)
        at += (1.0 / roughness) * (0.55 + 0.9 * float(r.random()))
    grains = S.fit(grains, dur)
    y = S.comb(grains, 1.0 / f0, feedback=0.88, damp=0.42)
    y = S.bp_sweep(y, S.expsweep(dur, f0 * 3.0, f1 * 3.0), q=2.4)
    y *= S.breakpoints(dur, [(0.0, 0.0), (0.05, 1.0), (dur * 0.7, 0.7), (dur, 0.0)],
                       curve="exp")
    peak = float(np.max(np.abs(y))) + 1e-12
    return y / peak * level


# ---------------------------------------------------------------------------
# calling and leaving the boat
# ---------------------------------------------------------------------------

@cue("boatSummon")
def boat_summon(r):
    """The boat is called: a two-note rising signal on a blown pipe, like a
    small conch. The ONLY sustained pitched cue on the sheet, so it can
    never be confused with the alarm (which is struck) or the engine."""
    dur = 0.85
    out = S.silence(dur)
    for i, (f, at, ln) in enumerate(((392.0, 0.0, 0.30), (587.33, 0.24, 0.52))):
        v = S.blown(ln, S.expsweep(ln, f * 0.94, f), r, breath=0.32, bright=0.7, vib=0.5)
        v *= S.breakpoints(ln, [(0.0, 0.0), (0.035, 1.0), (ln * 0.6, 0.85), (ln, 0.0)],
                           curve="exp")
        out = S.place(out, v * (0.7 + 0.3 * i), at)
    # A small wake answering underneath so it belongs to the water.
    wake = S.band_noise(0.5, r, 180.0, 1600.0, order=2)
    wake *= S.breakpoints(0.5, [(0.0, 0.0), (0.34, 1.0), (0.5, 0.0)], curve="exp")
    out = S.place(out, wake * 0.18, 0.30)
    return _open_water(out * 0.8, size=0.9, mix=0.20)


@cue("boatArrive")
def boat_arrive(r):
    """Hull settling into water: displacement first (a wide, low splash),
    then the hull rocking - two wooden groans a beat apart - then wash."""
    dur = 1.5
    out = S.silence(dur)
    disp = S.splash(0.55, r, low=300.0, high=5000.0, sweep_to=200.0, body=0.8)
    out = S.place(out, S.saturate(disp * 0.9, 1.5), 0.0)
    low = S.sine(0.5, S.expsweep(0.5, 120.0, 48.0)) * S.perc_env(0.5, 0.004, 0.14)
    out = S.place(out, S.saturate(low * 0.7, 2.2), 0.01)
    out = S.place(out, _wood(r, 0.5, decay=0.14, gain=0.55), 0.02)
    # The hull rocks twice as it finds its waterline.
    out = S.place(out, _creak(r, 0.34, 190.0, 250.0, level=0.30), 0.34)
    out = S.place(out, _wood(r, 0.35, decay=0.10, bright=0.7, gain=0.30), 0.62)
    wash = S.band_noise(0.9, r, 250.0, 4200.0, order=2)
    wash = S.lp_sweep(wash, S.expsweep(0.9, 4000.0, 700.0), order=2)
    wash *= S.breakpoints(0.9, [(0.0, 0.0), (0.06, 0.8), (0.4, 0.4), (0.9, 0.0)])
    out = S.place(out, wash * 0.35, 0.10)
    out = S.place(out, _droplets(r, count=9, spread=0.5, level=0.24, start=0.18), 0.0)
    return _open_water(out * 0.85, size=0.85, mix=0.19)


@cue("boatBoard")
def boat_board(r):
    """Stepping onto the planks: a boot on wood, then the hull taking the
    weight - a short creak with a slight pitch RISE (load increasing)."""
    dur = 0.6
    out = S.silence(dur)
    boot = S.membrane(0.09, 132.0, r, drop=0.6, noise=0.5, tau=0.024)
    out = S.place(out, S.saturate(boot * 0.9, 1.7), 0.0)
    out = S.place(out, _wood(r, 0.34, decay=0.075, gain=0.9), 0.0)
    out = S.place(out, _creak(r, 0.34, 200.0, 300.0, roughness=22.0, level=0.42), 0.055)
    # A little water knocking against the hull as it takes the load.
    out = S.place(out, S.splash(0.16, r, low=400.0, high=3000.0, sweep_to=250.0,
                                body=0.3) * 0.20, 0.09)
    return _open_water(out * 0.85, size=0.5, damping=0.6, mix=0.14)


@cue("boatLeave")
def boat_leave(r):
    """Stepping off: the mirror of board, but the creak FALLS (load coming
    off) and the wood is lighter - you push away rather than land."""
    dur = 0.5
    out = S.silence(dur)
    out = S.place(out, _creak(r, 0.26, 300.0, 205.0, roughness=24.0, level=0.40), 0.0)
    step = S.membrane(0.07, 156.0, r, drop=0.65, noise=0.45, tau=0.018)
    out = S.place(out, S.saturate(step * 0.7, 1.6), 0.10)
    out = S.place(out, _wood(r, 0.26, decay=0.055, bright=0.8, gain=0.6), 0.10)
    out = S.place(out, _droplets(r, count=3, spread=0.12, level=0.18, start=0.14), 0.0)
    return _open_water(out * 0.85, size=0.5, damping=0.6, mix=0.13)


# ---------------------------------------------------------------------------
# under way - the two loops
# ---------------------------------------------------------------------------

@cue("boatEngine", loop=True)
def boat_engine(r):
    """LOOP: a small outboard puttering. The client pitches the whole sprite
    with throttle, so this is authored at an idle-to-cruise middle.

    Loop-safety, three ways: the firing rate (8 Hz) divides the 1.5 s loop
    exactly (12 strokes), every stroke is shorter than one period so nothing
    is cut by the end, the drone frequencies (68 Hz and its harmonics) all
    complete whole cycles in 1.5 s, and the reverb is tail=False.

    A putter is NOT a buzz: each stroke is a saturated low thump with a tin
    chuff on top, and the strokes are deliberately UNEVEN in level (a real
    two-stroke never fires twice the same) - that irregularity is what stops
    it sounding like a square wave.
    """
    dur = 1.5
    rate = 8.0
    strokes = S.silence(dur)
    for i in range(int(rate * dur)):
        at = i / rate
        amp = 0.72 + 0.28 * float(r.random())
        thump = S.membrane(0.10, 84.0, r, drop=0.55, noise=0.2, tau=0.026)
        chuff = S.band_noise(0.055, r, 900.0, 6500.0, order=2)
        chuff = S.lp_sweep(chuff, S.expsweep(0.055, 5200.0, 1100.0), order=2)
        chuff *= S.perc_env(0.055, 0.0008, 0.012)
        strokes = S.place(strokes, S.mix(S.saturate(thump, 2.4) * 0.9,
                                         chuff * 0.32) * amp, at)
    strokes = S.fit(strokes, dur)
    # The block itself ringing: whole-cycle harmonics of the firing rate.
    drone = (S.sine(dur, 68.0) * 0.5 + S.sine(dur, 136.0) * 0.22
             + S.sine(dur, 204.0) * 0.10)
    drone = S.saturate(drone * 0.6, 2.6) * 0.35
    # Cowl rattle: a band of noise gated by the same 8 Hz so it breathes.
    ph = 2.0 * np.pi * rate * np.arange(S.n(dur)) / S.SR
    gate = 0.35 + 0.65 * (0.5 + 0.5 * np.sin(ph)) ** 3
    rattle = S.bandpass(S.white(dur, r), 1400.0, 5000.0, order=2) * gate * 0.10
    y = S.mix(strokes * 0.9, drone, rattle)
    y = S.lowpass(y, 7000.0, order=2)
    return _open_water(y, size=0.4, damping=0.75, mix=0.09, tail=False)


@cue("boatWash", loop=True)
def boat_wash(r):
    """LOOP: bow wash. The client volumes this with speed, so it is authored
    flat-out and quiet-safe. Pure texture, deliberately with NO events in it
    - anything rhythmic here would fight the engine loop sitting on top.

    Loop-safety: the two swell LFOs complete 3 and 5 whole cycles across the
    2.0 s loop, so level and colour at the end equal level and colour at the
    start; nothing is placed, so nothing can be cut.
    """
    dur = 2.0
    idx = np.arange(S.n(dur)) / S.n(dur)
    slow = 0.62 + 0.38 * np.sin(2.0 * np.pi * 3.0 * idx)
    fast = 0.75 + 0.25 * np.sin(2.0 * np.pi * 5.0 * idx + 1.1)
    hiss = S.bandpass(S.white(dur, r), 1200.0, 9000.0, order=2) * 0.30 * fast
    body = S.bandpass(S.pink(dur, r), 260.0, 2600.0, order=2) * 0.85 * slow
    surge = S.lowpass(S.brown(dur, r), 220.0, order=2) * 0.5 * slow
    y = S.mix(body, hiss, surge)
    y = S.lowpass(y, 9500.0, order=2)
    return _open_water(y, size=0.55, damping=0.7, mix=0.12, tail=False)


@cue("boatCreak")
def boat_creak(r):
    """Rudder/hull creak on a turn: one long stick-slip groan that bends up
    and then releases. Longer and lower than the board/leave creaks so a
    turn does not sound like someone getting on."""
    dur = 0.75
    y = _creak(r, 0.62, 148.0, 232.0, roughness=19.0, level=1.0)
    y = S.fit(y, dur)
    # A rope taking the strain over it, an octave up and much quieter.
    rope = S.fit(_creak(r, 0.45, 320.0, 400.0, roughness=31.0, level=0.28), dur)
    groan = S.sine(dur, S.expsweep(dur, 96.0, 132.0))
    groan *= S.breakpoints(dur, [(0.0, 0.0), (0.12, 1.0), (0.5, 0.6), (dur, 0.0)])
    return _open_water(S.mix(y * 0.9, rope, S.saturate(groan * 0.22, 2.0)),
                       size=0.55, damping=0.6, mix=0.15)


@cue("boatHit")
def boat_hit(r):
    """Hull thud: something solid, under the waterline. All body, no ring -
    a boat hitting a rock is a DULL impact plus water shoved sideways."""
    dur = 0.65
    out = S.silence(dur)
    body = S.membrane(0.28, 62.0, r, drop=0.5, noise=0.3, tau=0.075)
    out = S.place(out, S.saturate(body, 2.6), 0.0)
    out = S.place(out, _wood(r, 0.34, decay=0.065, gain=1.0), 0.0)
    out = S.place(out, S.splash(0.3, r, low=350.0, high=4500.0, sweep_to=220.0,
                                body=0.4) * 0.4, 0.006)
    # The hull complaining a beat after the impact - the part that says wood.
    out = S.place(out, _creak(r, 0.28, 175.0, 205.0, roughness=24.0, level=0.28), 0.14)
    return _open_water(S.lowpass(out, 5200.0, order=2), size=0.6, damping=0.6, mix=0.16)


@cue("boatWarn")
def boat_warn(r):
    """Hull damage alarm: a small brass bell struck twice, hard and bright,
    with a slight pitch drop between strikes so it reads as ALARM and not as
    a reward chime. It is the highest-energy thing on the sheet on purpose."""
    dur = 1.0
    out = S.silence(dur)
    for i, (at, f, amp) in enumerate(((0.0, 1046.5, 1.0), (0.20, 987.77, 0.85))):
        strike = S.metal_hit(0.55, r, f * 0.5, ring=0.85, roughness=0.35)
        clapper = S.bell(0.5, f, r, decay=0.30, strike=0.9, inharmonic=1.1) * 0.55
        out = S.place(out, S.mix(strike * 0.8, clapper) * amp, at)
    out = S.place(out, S.band_noise(0.006, r, 3000.0, 12000.0)
                  * S.perc_env(0.006, 0.0002, 0.0015) * 0.35, 0.0)
    return _open_water(out * 0.8, size=0.7, damping=0.35, mix=0.18)


@cue("boatSink")
def boat_sink(r):
    """The boat goes under: a long descending gurgle. Everything falls -
    the noise band, the bubble register and the hull groan - because a
    single consistent downward gesture is what "sinking" means."""
    dur = 2.2
    out = S.silence(dur)
    flood = S.band_noise(1.8, r, 200.0, 6000.0, order=2)
    flood = S.lp_sweep(flood, S.expsweep(1.8, 5000.0, 320.0), order=2)
    flood *= S.breakpoints(1.8, [(0.0, 0.0), (0.10, 1.0), (1.1, 0.55), (1.8, 0.0)])
    out = S.place(out, flood * 0.6, 0.0)
    # Bubbles, getting bigger (lower) as she goes down. Not a scatter: a run.
    for i in range(22):
        at = 0.06 + 1.65 * (i / 22.0) + float(r.random()) * 0.05
        f = 900.0 * (1.0 - 0.62 * (i / 22.0)) * float(2.0 ** (r.random() * 0.7 - 0.35))
        d = 0.04 + 0.05 * float(r.random())
        out = S.place(out, S.bubble(d, f, r, rise=2.0) * (0.20 + 0.28 * float(r.random())), at)
    groan = S.sine(1.6, S.expsweep(1.6, 128.0, 46.0))
    groan *= S.breakpoints(1.6, [(0.0, 0.0), (0.2, 1.0), (1.1, 0.7), (1.6, 0.0)])
    out = S.place(out, S.saturate(groan * 0.45, 2.4), 0.15)
    out = S.place(out, _creak(r, 0.7, 165.0, 110.0, roughness=17.0, level=0.30), 0.25)
    return _open_water(out * 0.85, size=1.0, damping=0.55, mix=0.22)


@cue("boatUpgrade")
def boat_upgrade(r):
    """Hammer and rope: three hammer blows on the hull (uneven, like a real
    swing) and a rope being hauled tight over them, then one bright confirm
    tap. The confirm is the only pitched note, which is what makes the cue
    read as SUCCESS rather than as repair noise."""
    dur = 1.3
    out = S.silence(dur)
    for at, amp in ((0.0, 1.0), (0.26, 0.9), (0.50, 0.95)):
        head = S.metal_hit(0.10, r, 780.0, ring=0.15, roughness=0.7) * 0.45
        nail = S.membrane(0.12, 148.0, r, drop=0.55, noise=0.55, tau=0.028)
        out = S.place(out, S.mix(S.saturate(nail, 2.0) * 0.9, head) * amp, at)
        out = S.place(out, _wood(r, 0.30, decay=0.06, gain=0.55 * amp), at)
    out = S.place(out, _creak(r, 0.45, 260.0, 380.0, roughness=27.0, level=0.30), 0.62)
    # The confirm: a wooden fifth, D5 -> A5, on bars so it stays in-material.
    for i, f in enumerate((587.33, 880.0)):
        out = S.place(out, S.bar(0.35, f, r, decay=0.17, strike=0.6) * (0.5 + 0.15 * i),
                      0.86 + i * 0.075)
    return _open_water(out * 0.8, size=0.6, damping=0.5, mix=0.17)
