"""sfx_character.py - the `character` sheet. 32 footsteps + 12 body cues.

FOOTSTEPS. Eight surfaces, four baked variants each. A footstep is the cue
a player hears more than any other in the game - several thousand times an
hour - so two things matter more than richness:

1. IT MUST NOT MACHINE-GUN. That is what the four variants are for, and
   variety inside a variant is not enough on its own: each variant here
   moves PITCH (a semitone-ish spread), LEVEL, and the internal timing of
   its grains. `_v(i)` returns those three as a triple so every surface
   varies along the same axes and the set stays coherent.
2. IT MUST BE SHORT AND DARK. Anything over ~180 ms or with much energy
   above 8 kHz becomes fatiguing at that repetition rate. Every surface
   below is low-passed on the way out, and only stone and metal keep a
   bright transient - because those are the two that physically have one.

The eight surfaces are separated by MECHANISM, not by EQ, which is what
stops them all sounding like the same noise burst through a different
filter:

    sand      pure granular hiss, no resonance at all, fastest decay
    stone     a hard 2 ms click over two very short high resonances
    wood      a hollow resonance triad (a box under the foot) + knock
    grass     dense high micro-grains, dry, no low end
    snow      a burst of tiny CRACKLES (discrete impulses, not noise) plus
              the low "compaction" thump underneath
    metal     `metal_hit` - the only surface that rings past 200 ms
    mud       a downward squelch and then an upward SUCK as the foot lifts
    shallow   an actual splash with droplets falling back

BODY CUES. `hurt`/`hurtHeavy`/`death` are deliberately NON-VOCAL: a
formant-filtered breath, not a voice. A synthesised voice sounds wrong
next to no other voices in the game, and it also ties the player to one
gender/age. Breath plus impact reads as "you were hit" and stays neutral.
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

OUTSIDE = dict(size=0.45, damping=0.62, seed=17)


def _room(x, mix=0.12, size=None, damping=None, tail=True):
    y = S.reverb(x, size=size or OUTSIDE["size"],
                 damping=damping or OUTSIDE["damping"], mix=mix,
                 seed=OUTSIDE["seed"], tail=tail)
    return _lead(y) if tail else y


def _v(i):
    """The variant axes: (pitch ratio, level, time skew). Four points chosen
    so no two are close on more than one axis - two variants that differ
    only in level still read as the same sample twice."""
    return ((1.00, 1.00, 1.00),
            (1.09, 0.86, 0.92),
            (0.93, 0.95, 1.08),
            (1.04, 0.78, 0.97))[i % 4]


def _grains(r, dur, count, low, high, level=1.0, skew=1.0, glen=0.004, front=0.65):
    """`count` micro-impulses of band noise scattered over `dur`, weighted
    towards the front (a footstep is loudest at contact and then crumbles).
    This is the granular engine behind sand, grass, snow and gravel."""
    out = S.silence(dur)
    for k in range(count):
        u = float(r.random()) ** (1.0 / max(0.05, front)) if front < 1.0 else float(r.random())
        at = u * (dur - glen * 2.0) * skew
        g = S.band_noise(glen, r, low, high) * S.perc_env(glen, 0.0002, glen * 0.28)
        out = S.place(out, g * (0.25 + 0.75 * float(r.random())) * level, at)
    return S.fit(out, dur)


def _thump(dur, f0, tau, drive=2.2, gain=1.0):
    """The compaction layer: the ground giving under weight. Every surface
    has one; its pitch and decay are most of what says how hard the ground
    is (sand 70 Hz/soft, stone 110 Hz/instant, metal 90 Hz/hollow)."""
    y = S.sine(dur, S.expsweep(dur, f0 * 1.9, f0)) * S.perc_env(dur, 0.0015, tau)
    return S.saturate(y * gain, drive)


# ---------------------------------------------------------------------------
# footsteps
# ---------------------------------------------------------------------------

@cue("stepSand", variants=4)
def step_sand(r, i):
    """Soft and grainy: no resonance whatsoever, just a fast dry crumble
    over a low, dull compaction. Sand is the DEADEST surface in the game."""
    p, lv, sk = _v(i)
    dur = 0.17
    grit = _grains(r, dur, 46, 900.0 * p, 6500.0 * p, level=0.55, skew=sk, glen=0.0035)
    hiss = S.band_noise(0.085, r, 700.0 * p, 5200.0 * p, order=2)
    hiss = S.lp_sweep(hiss, S.expsweep(0.085, 4600.0 * p, 900.0), order=2)
    hiss *= S.perc_env(0.085, 0.001, 0.020 * sk, curve=1.4)
    low = _thump(dur, 68.0 * p, 0.030, drive=2.0, gain=0.55)
    y = S.mix(grit, S.fit(hiss, dur) * 0.8, low)
    return _room(S.lowpass(y, 6000.0, order=2) * lv, mix=0.07, size=0.28)


@cue("stepStone", variants=4)
def step_stone(r, i):
    """Hard, with the small bright CLICK a boot heel makes on rock. Two very
    short high resonances give it stone's characteristic 'tick' without any
    ring - stone that rings is metal."""
    p, lv, sk = _v(i)
    dur = 0.20
    click = S.band_noise(0.0022, r, 2600.0 * p, 13000.0) * S.perc_env(0.0022, 0.0001, 0.0007)
    exc = S.fit(click, dur)
    stone = (S.resonator(exc, 1450.0 * p, q=13.0) * 0.9
             + S.resonator(exc, 2700.0 * p, q=10.0) * 0.5
             + S.resonator(exc, 640.0 * p, q=8.0) * 0.6)
    stone *= S.expdec(dur, 0.020 * sk)
    scuff = _grains(r, dur, 12, 1800.0, 9000.0, level=0.20, skew=sk, glen=0.003)
    low = _thump(dur, 112.0 * p, 0.026, drive=2.4, gain=0.7)
    y = S.mix(S.fit(click, dur) * 0.55, stone * 0.9, scuff, low)
    return _room(y * lv, mix=0.09, size=0.30, damping=0.45)


@cue("stepWood", variants=4)
def step_wood(r, i):
    """Hollow, with a knock. The resonance triad IS a plank over a void -
    a fundamental near 190 Hz with two inharmonic partials, decaying in
    about 60 ms. The dock and the boat deck share this shape."""
    p, lv, sk = _v(i)
    dur = 0.24
    exc = S.fit(S.band_noise(0.004, r, 500.0, 6000.0) * S.perc_env(0.004, 0.0002, 0.0012), dur)
    board = (S.resonator(exc, 188.0 * p, q=11.0)
             + S.resonator(exc, 322.0 * p, q=9.0) * 0.5
             + S.resonator(exc, 511.0 * p, q=7.0) * 0.25)
    board *= S.expdec(dur, 0.055 * sk)
    knock = S.membrane(0.10, 142.0 * p, r, drop=0.6, noise=0.35, tau=0.022)
    scuff = _grains(r, dur, 9, 1200.0, 6000.0, level=0.14, skew=sk)
    y = S.mix(board * 0.9, S.fit(S.saturate(knock, 1.9), dur) * 0.7, scuff)
    return _room(S.lowpass(y, 5500.0, order=2) * lv, mix=0.10, size=0.30)


@cue("stepGrass", variants=4)
def step_grass(r, i):
    """Rustly: dense high grains and nothing below 400 Hz to speak of.
    Grass has no mass, so it has no thump - the low layer here is a whisper
    of the ground UNDER the grass, at a quarter the level of every other
    surface. Take that low layer out entirely and it floats; leave it at
    full and it becomes mud."""
    p, lv, sk = _v(i)
    dur = 0.22
    rustle = _grains(r, dur, 62, 2200.0 * p, 11000.0, level=0.5, skew=sk,
                     glen=0.003, front=0.8)
    swish = S.band_noise(0.12, r, 1800.0 * p, 9000.0, order=2)
    swish *= S.breakpoints(0.12, [(0.0, 0.0), (0.008, 1.0), (0.05, 0.45), (0.12, 0.0)],
                           curve="exp")
    low = _thump(dur, 78.0 * p, 0.026, drive=1.8, gain=0.18)
    y = S.mix(rustle, S.fit(swish, dur) * 0.55, low)
    return _room(S.highpass(y, 220.0, order=2) * lv, mix=0.09, size=0.30)


@cue("stepSnow", variants=4)
def step_snow(r, i):
    """Crunchy. The crunch is DISCRETE: ~30 individual crackles in the first
    50 ms, each one a single sharp impulse rather than shaped noise - that
    is the difference between snow and sand, which are otherwise the same
    spectrum. Under it, a soft compaction thump that starts a touch LATE,
    because snow gives before it stops you."""
    p, lv, sk = _v(i)
    dur = 0.26
    crack = S.silence(dur)
    for k in range(30):
        at = (float(r.random()) ** 1.6) * 0.13 * sk
        g = S.band_noise(0.0018, r, 1400.0 * p, 9500.0) * S.perc_env(0.0018, 0.00008, 0.0004)
        crack = S.place(crack, g * (0.3 + 0.7 * float(r.random())), at)
    crack = S.fit(crack, dur)
    pack = S.band_noise(0.10, r, 500.0 * p, 4200.0, order=2)
    pack = S.lp_sweep(pack, S.expsweep(0.10, 3600.0, 700.0), order=2)
    pack *= S.perc_env(0.10, 0.002, 0.028, curve=1.3)
    low = S.place(S.silence(dur), _thump(0.18, 74.0 * p, 0.045, drive=1.7, gain=0.6), 0.006)
    y = S.mix(crack * 0.9, S.fit(pack, dur) * 0.6, low)
    return _room(S.lowpass(y, 8000.0, order=2) * lv, mix=0.08, size=0.35, damping=0.75)


@cue("stepMetal", variants=4)
def step_metal(r, i):
    """Ringing: the only footstep that lasts past 200 ms. A metal_hit at
    ~620 Hz (a deck plate, not a bell) with a hard heel click on top and a
    hollow boom under - a steel plate over air."""
    p, lv, sk = _v(i)
    dur = 0.42
    plate = S.metal_hit(0.34, r, 620.0 * p, ring=0.42, roughness=0.6)
    plate *= S.expdec(0.34, 0.055 * sk)
    heel = S.band_noise(0.0025, r, 3000.0, 14000.0) * S.perc_env(0.0025, 0.0001, 0.0008)
    boom = _thump(dur, 96.0 * p, 0.055, drive=2.4, gain=0.55)
    y = S.mix(S.fit(plate, dur) * 0.9, S.fit(heel, dur) * 0.45, boom)
    return _room(y * lv, mix=0.11, size=0.38, damping=0.40)


@cue("stepMud", variants=4)
def step_mud(r, i):
    """Wet and sucking, in two halves: DOWN is a squelch (noise through a
    fast-closing filter, like shallow water but darker), UP is the suck -
    a bubble whose pitch RISES under a rising filter, 60 ms later. That
    second event is the whole cue; without it this is just wet sand."""
    p, lv, sk = _v(i)
    dur = 0.34
    out = S.silence(dur)
    squelch = S.band_noise(0.12, r, 300.0 * p, 3800.0, order=3)
    squelch = S.lp_sweep(squelch, S.expsweep(0.12, 3200.0 * p, 380.0), order=2)
    squelch *= S.perc_env(0.12, 0.0015, 0.030, curve=1.3)
    out = S.place(out, squelch * 0.8, 0.0)
    out = S.place(out, _thump(0.20, 62.0 * p, 0.048, drive=2.4, gain=0.8), 0.0)
    # The suck: rising pitch AND rising cutoff, together.
    suck = S.bubble(0.11, 190.0 * p, r, rise=3.4, tau=0.055)
    smear = S.band_noise(0.11, r, 400.0, 4200.0, order=2)
    smear = S.lp_sweep(smear, S.expsweep(0.11, 500.0, 3000.0), order=2)
    smear *= S.breakpoints(0.11, [(0.0, 0.0), (0.06, 1.0), (0.11, 0.0)], curve="exp")
    out = S.place(out, S.mix(suck * 0.55, smear * 0.30), 0.075 * sk + 0.055)
    return _room(S.lowpass(out, 5000.0, order=2) * lv, mix=0.09, size=0.30, damping=0.7)


@cue("stepShallow", variants=4)
def step_shallow(r, i):
    """Splashy: a real (small) splash with droplets falling back. Brighter
    and longer than mud, and it is the only footstep with a tail."""
    p, lv, sk = _v(i)
    dur = 0.38
    out = S.silence(dur)
    out = S.place(out, S.splash(0.20, r, low=700.0 * p, high=9500.0,
                                sweep_to=420.0, body=0.35) * 0.95, 0.0)
    out = S.place(out, _thump(0.16, 86.0 * p, 0.032, drive=2.0, gain=0.45), 0.0)
    for k in range(5):
        at = 0.07 + float(r.random()) * 0.18 * sk
        f = 1500.0 * float(2.0 ** (r.random() * 1.4 - 0.7))
        out = S.place(out, S.bubble(0.022 + 0.02 * float(r.random()), f, r, rise=2.4)
                      * 0.22 * (0.4 + 0.6 * float(r.random())), at)
    return _room(out * lv, mix=0.11, size=0.35, damping=0.6)


# ---------------------------------------------------------------------------
# movement
# ---------------------------------------------------------------------------

@cue("jump")
def jump(r):
    """The push-off: a scuff, a cloth/rig rustle and a short UPWARD air
    swish. The rising direction is doing all the work - the same layers
    with a falling sweep are `land`."""
    dur = 0.30
    scuff = _grains(r, 0.10, 20, 900.0, 7000.0, level=0.45, glen=0.003)
    cloth = S.band_noise(0.16, r, 1200.0, 8000.0, order=2)
    cloth = S.bp_sweep(cloth, S.expsweep(0.16, 1600.0, 4200.0), q=1.8)
    cloth *= S.breakpoints(0.16, [(0.0, 0.0), (0.02, 1.0), (0.16, 0.0)], curve="exp")
    push = S.sine(0.18, S.expsweep(0.18, 130.0, 210.0)) * S.perc_env(0.18, 0.003, 0.045)
    y = S.mix(S.fit(scuff, dur), S.fit(cloth, dur) * 0.55,
              S.fit(S.saturate(push * 0.6, 1.8), dur))
    return _room(y, mix=0.09, size=0.30)


@cue("land")
def land(r):
    """Both feet arriving: a heavier, lower version of a footstep with a
    knee-bend scuff AFTER the impact. Pitched a fifth below `stepStone` so
    landing on rock is never mistaken for walking on it."""
    dur = 0.42
    out = S.silence(dur)
    out = S.place(out, _thump(0.26, 74.0, 0.055, drive=2.8, gain=1.0), 0.0)
    hit = S.membrane(0.16, 128.0, r, drop=0.5, noise=0.45, tau=0.030)
    out = S.place(out, S.saturate(hit, 2.2) * 0.8, 0.0)
    out = S.place(out, _grains(r, 0.20, 26, 800.0, 7500.0, level=0.32, glen=0.0035), 0.004)
    out = S.place(out, _grains(r, 0.14, 10, 1400.0, 8000.0, level=0.16), 0.10)
    return _room(S.lowpass(out, 6500.0, order=2), mix=0.13, size=0.5)


@cue("swimStroke")
def swim_stroke(r):
    """One arm through water: a pull (noise sweeping DOWN as the hand
    submerges) and a small surface break as it comes out. Soft attack on
    purpose - a swim stroke has no transient, and giving it one makes the
    player sound like they are punching the sea."""
    dur = 0.55
    out = S.silence(dur)
    pull = S.band_noise(0.30, r, 300.0, 5000.0, order=3)
    pull = S.lp_sweep(pull, S.expsweep(0.30, 4200.0, 450.0), order=2)
    pull *= S.breakpoints(0.30, [(0.0, 0.0), (0.05, 1.0), (0.18, 0.6), (0.30, 0.0)],
                          curve="exp")
    out = S.place(out, pull * 0.75, 0.0)
    out = S.place(out, S.splash(0.18, r, low=800.0, high=8000.0, sweep_to=500.0,
                                body=0.2) * 0.4, 0.24)
    for k in range(4):
        out = S.place(out, S.bubble(0.03, 420.0 * float(2.0 ** (r.random() - 0.5)), r,
                                    rise=2.2) * 0.16, 0.05 + float(r.random()) * 0.20)
    return _room(S.lowpass(out, 7000.0, order=2), mix=0.14, size=0.55, damping=0.65)


@cue("waterEnter")
def water_enter(r):
    """Going in: a big displacement splash, then the muffling. The low-pass
    closing to 900 Hz over the last third is the ears going under, and it is
    what makes this different from any other splash in the game."""
    dur = 0.85
    out = S.silence(dur)
    out = S.place(out, S.splash(0.34, r, low=400.0, high=11000.0, sweep_to=300.0,
                                body=0.6) * 1.0, 0.0)
    out = S.place(out, _thump(0.28, 88.0, 0.070, drive=2.2, gain=0.7), 0.0)
    under = S.band_noise(0.5, r, 150.0, 3000.0, order=2)
    under = S.lp_sweep(under, S.expsweep(0.5, 2800.0, 620.0), order=2)
    under *= S.breakpoints(0.5, [(0.0, 0.0), (0.08, 0.8), (0.5, 0.0)])
    out = S.place(out, under * 0.45, 0.14)
    for k in range(12):
        f = 700.0 * float(2.0 ** (r.random() * 1.6 - 0.8))
        out = S.place(out, S.bubble(0.03 + 0.03 * float(r.random()), f, r, rise=2.6)
                      * 0.20, 0.16 + float(r.random()) * 0.45)
    return _room(out * 0.9, mix=0.16, size=0.6, damping=0.7)


@cue("waterExit")
def water_exit(r):
    """Coming out: the mirror - the muffle OPENS (cutoff rising), water
    sheets off, and it ends on droplets rather than bubbles."""
    dur = 0.9
    out = S.silence(dur)
    heave = S.band_noise(0.32, r, 250.0, 6000.0, order=2)
    heave = S.lp_sweep(heave, S.expsweep(0.32, 700.0, 6500.0), order=2)
    heave *= S.breakpoints(0.32, [(0.0, 0.0), (0.10, 1.0), (0.32, 0.15)], curve="exp")
    out = S.place(out, heave * 0.8, 0.0)
    out = S.place(out, S.splash(0.22, r, low=600.0, high=9000.0, sweep_to=450.0,
                                body=0.25) * 0.5, 0.20)
    for k in range(14):
        f = 1600.0 * float(2.0 ** (r.random() * 1.4 - 0.7))
        out = S.place(out, S.bubble(0.02 + 0.025 * float(r.random()), f, r, rise=2.2)
                      * 0.18 * (0.4 + 0.6 * float(r.random())),
                      0.22 + float(r.random()) * 0.5)
    return _room(out * 0.9, mix=0.14, size=0.5, damping=0.6)


# ---------------------------------------------------------------------------
# damage and state
# ---------------------------------------------------------------------------

def _breath(r, dur, f0=180.0, vowel=(560.0, 1100.0, 2500.0), level=1.0, curve=None):
    """A non-vocal grunt: noise + a weak pitched core through three formant
    bands. Reads as a person without ever being a voice - see the header."""
    src = S.mix(S.white(dur, r) * 0.9, S.saw(dur, S.expsweep(dur, f0 * 1.15, f0 * 0.85)) * 0.35)
    y = S.formant(src, list(vowel), qs=[9.0, 8.0, 6.0], gains=[1.0, 0.55, 0.22])
    env = curve or [(0.0, 0.0), (0.012, 1.0), (dur * 0.45, 0.45), (dur, 0.0)]
    y *= S.breakpoints(dur, env, curve="exp")
    return y / (np.max(np.abs(y)) + 1e-12) * level


@cue("hurt")
def hurt(r):
    """Took a hit: a short breath out over a dull body thump. Kept small -
    this fires often, and a big hurt sound makes chip damage feel fatal."""
    dur = 0.32
    y = S.mix(_breath(r, 0.22, 190.0, (620.0, 1150.0, 2600.0), level=0.75),
              S.fit(_thump(0.18, 105.0, 0.038, drive=2.2, gain=0.6), 0.22),
              S.fit(S.band_noise(0.02, r, 300.0, 3000.0) * S.perc_env(0.02, 0.0008, 0.005) * 0.4,
                    0.22))
    return _room(S.fit(S.lowpass(y, 5000.0, order=2), dur), mix=0.09, size=0.30)


@cue("hurtHeavy")
def hurt_heavy(r):
    """A big hit: the same voice a fourth LOWER and twice as long, with a
    real impact crack in front and the wind knocked out at the end. Same
    family as `hurt` deliberately - the player should hear a degree, not a
    different event."""
    dur = 0.65
    out = S.silence(dur)
    crack = S.band_noise(0.02, r, 700.0, 9000.0) * S.perc_env(0.02, 0.0003, 0.004)
    out = S.place(out, crack * 0.7, 0.0)
    out = S.place(out, _thump(0.34, 68.0, 0.085, drive=3.0, gain=1.0), 0.0)
    out = S.place(out, _breath(r, 0.42, 138.0, (480.0, 900.0, 2100.0), level=0.85), 0.015)
    # The exhale after it - a slow drop, quieter, so the hit has a shadow.
    out = S.place(out, _breath(r, 0.28, 120.0, (420.0, 780.0, 1800.0), level=0.28,
                               curve=[(0.0, 0.0), (0.08, 1.0), (0.28, 0.0)]), 0.30)
    return _room(S.lowpass(out, 4600.0, order=2), mix=0.13, size=0.55)


@cue("lowHealth", loop=True)
def low_health(r):
    """LOOP: a slow heartbeat, 60 bpm - two beats per 2.0 s loop, so the
    rhythm is continuous across the loop point.

    Loop-safety: both beats and every layer they carry finish well before
    1.9 s, and the pressure hum's frequency (55 Hz) completes 110 whole
    cycles in 2.0 s, so its phase at the end matches its phase at the start.
    tail=False keeps the reverb inside the loop.

    A heartbeat is TWO thumps, lub-dub, 0.30 s apart and the second quieter
    and slightly higher - a single evenly-spaced thump reads as a machine.
    """
    dur = 2.0
    out = S.silence(dur)
    for at, f, amp, tau in ((0.00, 52.0, 1.00, 0.085), (0.30, 61.0, 0.62, 0.060),
                            (1.00, 52.0, 0.96, 0.085), (1.30, 61.0, 0.60, 0.060)):
        beat = S.sine(0.30, S.expsweep(0.30, f * 1.6, f * 0.9))
        beat *= S.perc_env(0.30, 0.004, tau, curve=1.4)
        thud = S.band_noise(0.05, r, 60.0, 340.0, order=2) * S.perc_env(0.05, 0.003, 0.014)
        out = S.place(out, S.mix(S.saturate(beat, 2.6), S.fit(thud, 0.30) * 0.35) * amp, at)
    # The blood-in-the-ears layer: a quiet steady hum, whole cycles.
    hum = S.sine(dur, 55.0) * 0.10 + S.sine(dur, 110.0) * 0.03
    out = S.mix(out, S.saturate(hum, 1.8))
    return S.reverb(S.lowpass(out, 900.0, order=2), size=0.5, damping=0.85,
                    mix=0.10, seed=17, tail=False)


@cue("death")
def death(r):
    """Everything falls and stops. A low descending drone, one last breath,
    and a dead thud that is NOT followed by a tail - the abrupt end is the
    point. Nothing here is in a key, so it can never read as a stinger."""
    dur = 2.0
    out = S.silence(dur)
    drone = S.supersaw(1.4, 87.31, voices=4, detune=0.006, phase_seed=r)
    drone = S.moog(drone, S.breakpoints(1.4, [(0.0, 900.0), (1.4, 180.0)]), res=0.30)
    drone *= S.breakpoints(1.4, [(0.0, 0.0), (0.06, 1.0), (1.0, 0.45), (1.4, 0.0)],
                           curve="exp")
    out = S.place(out, S.saturate(drone * 0.5, 1.8), 0.0)
    sub = S.sine(1.2, S.expsweep(1.2, 96.0, 34.0)) * S.perc_env(1.2, 0.008, 0.30)
    out = S.place(out, S.saturate(sub * 0.7, 2.4), 0.0)
    out = S.place(out, _breath(r, 0.55, 116.0, (440.0, 820.0, 1900.0), level=0.45,
                               curve=[(0.0, 0.0), (0.05, 1.0), (0.30, 0.35), (0.55, 0.0)]),
                  0.05)
    # The body landing, late, quiet, with no ring.
    out = S.place(out, S.saturate(S.membrane(0.30, 58.0, r, drop=0.5, noise=0.4,
                                             tau=0.070), 2.4) * 0.55, 0.95)
    return _lead(S.reverb(S.lowpass(out, 3200.0, order=2), size=0.9,
                          damping=0.7, mix=0.20, seed=17))


@cue("respawn")
def respawn(r):
    """Coming back: the exact inverse of `death`. The filter OPENS, the
    pitch RISES, and it lands on a warm major third instead of a thud."""
    dur = 1.4
    out = S.silence(dur)
    rise = S.supersaw(0.8, 174.61, voices=5, detune=0.007, phase_seed=r)
    rise = S.moog(rise, S.breakpoints(0.8, [(0.0, 200.0), (0.8, 3400.0)]), res=0.35)
    rise *= S.breakpoints(0.8, [(0.0, 0.0), (0.7, 0.9), (0.8, 0.5)], curve="exp")
    out = S.place(out, S.saturate(rise * 0.35, 1.5), 0.0)
    # The arrival chord: F major, soft bells, a bit of air over it.
    for f in (349.23, 440.0, 523.25, 698.46):
        out = S.place(out, S.bell(0.9, f, r, decay=0.45, strike=0.35) * 0.26, 0.70)
    air = S.bp_sweep(S.white(0.6, r), S.expsweep(0.6, 3000.0, 11000.0), q=1.8)
    air *= S.breakpoints(0.6, [(0.0, 0.0), (0.12, 1.0), (0.6, 0.0)], curve="exp")
    out = S.place(out, air * 0.18, 0.62)
    return _lead(S.reverb(out * 0.85, size=0.9, damping=0.4, mix=0.24, seed=17))


@cue("chilled")
def chilled(r):
    """Frost applied: crackles spreading SLOWLY outward (they get sparser
    and higher as they go) over a glassy shiver. The deceleration is the
    tell - ice forming slows down; ice breaking speeds up."""
    dur = 1.1
    out = S.silence(dur)
    at = 0.0
    gap = 0.018
    while at < 0.85:
        f_lo = 2200.0 * (1.0 + 1.2 * (at / 0.85))
        g = S.band_noise(0.0035, r, f_lo, min(15000.0, f_lo * 4.5))
        g *= S.perc_env(0.0035, 0.0001, 0.0008)
        out = S.place(out, g * (0.35 + 0.65 * float(r.random())) * (1.0 - 0.5 * at), at)
        at += gap
        gap *= 1.085          # slowing: the frost is settling, not shattering
    # The glassy shiver: two close high bells beating against each other.
    for f in (1567.98, 1580.0, 2349.32):
        out = S.place(out, S.bell(0.9, f, r, decay=0.42, strike=0.25,
                                  inharmonic=1.3) * 0.13, 0.02)
    breathe = S.band_noise(0.7, r, 4000.0, 13000.0, order=2)
    breathe *= S.breakpoints(0.7, [(0.0, 0.0), (0.25, 1.0), (0.7, 0.0)], curve="exp")
    out = S.place(out, breathe * 0.12, 0.05)
    return _lead(S.reverb(S.highpass(out, 500.0, order=2) * 0.85, size=0.85,
                          damping=0.30, mix=0.22, seed=17))


@cue("knockback")
def knockback(r):
    """Whump: displaced air and a shove. A wide low-frequency puff with a
    fast downward sweep and no click at all - a transient here would make
    it a hit, and the hit is `hitThump`'s job on the combat sheet."""
    dur = 0.5
    puff = S.brown(0.28, r)
    puff = S.lp_sweep(puff, S.expsweep(0.28, 2200.0, 180.0), order=2)
    puff *= S.breakpoints(0.28, [(0.0, 0.0), (0.010, 1.0), (0.12, 0.4), (0.28, 0.0)],
                          curve="exp")
    body = S.sine(0.36, S.expsweep(0.36, 145.0, 42.0)) * S.perc_env(0.36, 0.005, 0.090)
    cloth = S.band_noise(0.14, r, 900.0, 6000.0, order=2)
    cloth *= S.perc_env(0.14, 0.004, 0.028)
    y = S.mix(S.fit(puff, dur) * 1.0, S.fit(S.saturate(body * 0.9, 2.6), dur),
              S.fit(cloth, dur) * 0.22)
    return _room(S.lowpass(y, 4000.0, order=2), mix=0.12, size=0.55)


# ---------------------------------------------------------------------------
# equipping - rodDraw / rodStow / weaponDraw / weaponStow / fistReady
#
# Added 2026-09-12. These five replace a UI clack (`uiEquip`) on the
# rod/fist/tool switch, and the whole point of them is that they are
# MATERIALS rather than events: cloth, leather, graphite, steel. Each is
# built from the four primitives below, never from a single noise burst,
# and every one ends in a short room with a matching pre-delay so the
# switch happens somewhere rather than in the player's skull.
#
# The gesture shape is the same for all five and is what makes them a set:
#   GRIP (a small cloth/hand noise, 0-40 ms) ->
#   TRAVEL (the long layer: leather, graphite flex or a sleeve, 80-250 ms) ->
#   SEAT (the hard event that ends it: a click, a ring, a knuckle) ->
#   SETTLE (cloth falling back, 60-150 ms, under everything).
# A draw's travel RISES in pitch and ends bright; a stow's falls and ends
# dull. That contour, not the timbre, is what tells the player which way
# the switch went when both cues are played inside a second of each other.
# ---------------------------------------------------------------------------

GEAR = dict(size=0.34, damping=0.55, seed=17)


def _gear_room(x, mix=0.13, predelay=0.007):
    """The close room these five sit in: small, fairly dead, with 7 ms of
    pre-delay so the direct sound arrives first and the space arrives after
    it. 2D cues with no pre-delay at all sound like they were recorded
    inside the listener."""
    return _lead(S.reverb(x, size=GEAR["size"], damping=GEAR["damping"], mix=mix,
                          predelay=predelay, seed=GEAR["seed"]))


def _cloth(r, dur, level=1.0, low=350.0, high=3200.0, attack=0.010, peak=0.35,
           moving=True):
    """A sleeve or a glove moving: PINK noise (not white - cloth has no top
    octave) through a band that closes as the fabric settles, with a soft
    attack. Hard-enveloped white noise is what a cheap 'swish' is; the two
    differences are the spectrum tilt and the 10 ms attack."""
    y = S.pink(dur, r)
    if moving:
        y = S.bp_sweep(y, S.breakpoints(dur, [(0.0, high * 0.55), (dur * peak, high),
                                              (dur, low * 1.6)], curve="exp"), q=1.1)
    else:
        y = S.bandpass(y, low, high, order=2)
    y *= S.breakpoints(dur, [(0.0, 0.0), (attack, 0.75), (dur * peak, 1.0),
                             (dur, 0.0)], curve="exp")
    return y / (np.max(np.abs(y)) + 1e-12) * level


def _leather(r, dur, f0=520.0, f1=780.0, level=1.0, attack=0.012, grip=0.55):
    """Leather sliding on leather: lower and longer than cloth, with a
    resonance that bends (the scabbard mouth changing shape as the blade
    passes) and a stick-slip roughness under it. The roughness is a slow
    amplitude ripple on the noise BEFORE the filter, so it colours the
    resonance instead of just chopping the level."""
    src = S.brown(dur, r) * 0.7 + S.pink(dur, r) * 0.5
    tt = np.arange(S.n(dur)) / S.SR
    src *= 1.0 - grip * 0.5 * (0.5 + 0.5 * np.sin(2.0 * np.pi * 31.0 * tt +
                                                  3.0 * np.sin(2.0 * np.pi * 7.0 * tt)))
    y = S.bp_sweep(src, S.expsweep(dur, f0, f1), q=2.6)
    y = S.mix(y, S.resonator(src, (f0 + f1) * 0.5, q=9.0) * 0.45)
    y *= S.breakpoints(dur, [(0.0, 0.0), (attack, 0.6), (dur * 0.55, 1.0),
                             (dur, 0.0)], curve="exp")
    return y / (np.max(np.abs(y)) + 1e-12) * level


def _ring(r, dur, freq=2350.0, level=1.0, rough=0.35):
    """Steel leaving steel: a short bright ring. `metal_hit` for the body of
    it plus two bell partials an octave up, because a guard ringing has
    inharmonic content a single resonator bank does not give you."""
    y = S.metal_hit(dur, r, freq, ring=0.55, roughness=rough)
    y = S.mix(y * 0.9,
              S.bell(dur * 0.8, freq * 1.97, r, decay=dur * 0.30, strike=0.55) * 0.30,
              S.bell(dur * 0.6, freq * 3.11, r, decay=dur * 0.18, strike=0.45) * 0.14)
    return S.fit(y, dur) * S.expdec(dur, dur * 0.30) * level


def _gear_ticks(r, dur, times, level=0.5, res=2700.0, decay=0.0035, jitter=0.3):
    """A pawl/detent train. Defined here rather than imported from
    `sfx_fishing` on purpose: build.py keys the render cache on the source
    hash of the module that IMPLEMENTED a cue, so a cue that reached across
    modules would not re-render when the helper it depends on changed."""
    out = S.silence(dur)
    glen = 0.016
    for at in times:
        if at < 0.0 or at >= dur - glen:
            continue
        spit = S.band_noise(0.0008, r, 1400.0, 9000.0) * S.perc_env(0.0008, 0.00008, 0.0003)
        g = S.fit(spit, glen)
        f = res * float(2.0 ** ((r.random() * 2.0 - 1.0) * 0.35))
        g = S.resonator(g, f, q=17.0) * 0.9 + S.resonator(g, f * 2.37, q=11.0) * 0.35
        g = g * S.expdec(glen, decay)
        out = S.place(out, g * level * (1.0 - jitter + 2.0 * jitter * float(r.random())),
                      float(at))
    return out


def _knuckle(r, at_pitch=1.0, level=1.0):
    """One knuckle going. A joint cavitating is a tiny, very dry wooden
    click with almost no ring - two short resonances and a 0.4 ms spit. It
    must NOT be a bone crunch; this is a player idle gesture, not a hit."""
    dur = 0.07
    spit = S.band_noise(0.0006, r, 900.0, 9000.0) * S.perc_env(0.0006, 0.00006, 0.0002)
    exc = S.fit(spit, dur)
    y = (S.resonator(exc, 720.0 * at_pitch, q=13.0) * 0.9
         + S.resonator(exc, 1340.0 * at_pitch, q=9.0) * 0.45
         + S.resonator(exc, 320.0 * at_pitch, q=7.0) * 0.35)
    y *= S.expdec(dur, 0.010)
    return S.mix(S.fit(spit, dur) * 0.35, y) * level


@cue("rodDraw")
def rod_draw(r):
    """The rod comes out. Four things in 600 ms, in the order a hand does
    them: the grip (cloth), the blank UNFOLDING - a graphite tube sliding
    out of a graphite tube, which is a dry mid-band whose resonance RISES
    as the section extends - the flex as the tip whips up and settles
    (Karplus, low and damped), and the reel handle clicking over twice as
    the rod comes level. Decelerating clicks, so the spool is coasting to
    a stop rather than being cranked."""
    dur = 0.62
    out = S.silence(dur)

    out = S.place(out, _cloth(r, 0.13, level=0.42, low=420.0, high=3400.0), 0.0)

    # The section extending: a rising, dry, hollow slide.
    slide = S.band_noise(0.20, r, 500.0, 5200.0, order=2)
    slide = S.bp_sweep(slide, S.expsweep(0.20, 760.0, 2100.0), q=3.2)
    slide = S.mix(slide, S.resonator(slide, 1280.0, q=11.0) * 0.4)
    slide *= S.breakpoints(0.20, [(0.0, 0.0), (0.012, 0.5), (0.15, 1.0),
                                  (0.20, 0.0)], curve="exp")
    out = S.place(out, slide / (np.max(np.abs(slide)) + 1e-12) * 0.55, 0.045)

    # The tip stopping and the blank ringing it off.
    flex = S.karplus(0.34, 184.0, r, brightness=0.34, damping=0.55, stretch=0.3)
    flex = S.bp_sweep(flex, S.breakpoints(0.34, [(0.0, 230.0), (0.10, 620.0),
                                                 (0.34, 300.0)], curve="exp"), q=1.6)
    flex *= S.breakpoints(0.34, [(0.0, 0.0), (0.006, 0.9), (0.07, 1.0),
                                 (0.34, 0.0)], curve="exp")
    out = S.place(out, flex * 0.50, 0.215)
    out = S.place(out, S.bar(0.16, 268.0, r, decay=0.060, strike=0.30) * 0.20, 0.215)

    # The reel handle coming over: two clicks, decelerating.
    out = S.place(out, _gear_ticks(r, 0.24, [0.0, 0.075, 0.175], level=0.55,
                                   res=2700.0, decay=0.0040), 0.300)

    # The hand settling on the grip, and the strap falling back.
    out = S.place(out, _cloth(r, 0.20, level=0.24, low=300.0, high=2200.0,
                              attack=0.018, peak=0.4), 0.360)
    body = S.sine(dur, S.expsweep(dur, 118.0, 66.0)) * S.perc_env(dur, 0.006, 0.055)
    out = S.mix(out, S.saturate(body * 0.30, 1.8))
    return _gear_room(out, mix=0.13)


@cue("rodStow")
def rod_stow(r):
    """The rod goes away: rodDraw's gesture run backwards and shorter. The
    slide FALLS in pitch (a section collapsing into the one below it), the
    flex settles instead of whipping, and it ends on one dull seat click
    rather than on a bright ring. Shorter than the draw, because putting
    something down is always quicker than picking it up."""
    dur = 0.50
    out = S.silence(dur)

    out = S.place(out, _cloth(r, 0.11, level=0.38, low=380.0, high=3000.0), 0.0)

    slide = S.band_noise(0.19, r, 400.0, 4200.0, order=2)
    slide = S.bp_sweep(slide, S.expsweep(0.19, 1900.0, 620.0), q=3.0)
    slide = S.mix(slide, S.resonator(slide, 900.0, q=10.0) * 0.4)
    slide *= S.breakpoints(0.19, [(0.0, 0.0), (0.014, 0.8), (0.12, 0.7),
                                  (0.19, 0.0)], curve="exp")
    out = S.place(out, slide / (np.max(np.abs(slide)) + 1e-12) * 0.50, 0.040)

    flex = S.karplus(0.24, 152.0, r, brightness=0.22, damping=0.70, stretch=0.2)
    flex *= S.breakpoints(0.24, [(0.0, 0.0), (0.010, 0.8), (0.24, 0.0)], curve="exp")
    out = S.place(out, S.lowpass(flex, 1400.0, order=2) * 0.40, 0.150)

    # It seating in the rack: a dull knock, not a ring.
    seat = S.mix(S.membrane(0.14, 128.0, r, drop=0.55, noise=0.22, tau=0.032) * 0.8,
                 S.bar(0.10, 214.0, r, decay=0.028, strike=0.30) * 0.35)
    out = S.place(out, S.lowpass(S.saturate(seat, 1.9), 2600.0, order=2) * 0.75, 0.255)
    out = S.place(out, _cloth(r, 0.17, level=0.22, low=280.0, high=1900.0,
                              attack=0.016, peak=0.4), 0.290)
    return _gear_room(out, mix=0.12)


@cue("weaponDraw")
def weapon_draw(r):
    """Something with an edge coming off a belt. The classic is a single
    bright 'shiiing', which is wrong twice over: the ring belongs at the
    END (the blade leaves the throat of the sheath and only then is free to
    ring), and most of the sound is LEATHER, not steel. So: grip, a
    260 ms leather slide whose resonance rises as the blade clears, the
    ring at 0.30 s, and cloth settling after it."""
    dur = 0.56
    out = S.silence(dur)

    out = S.place(out, _cloth(r, 0.10, level=0.38, low=400.0, high=3200.0), 0.0)
    out = S.place(out, _leather(r, 0.27, f0=470.0, f1=980.0, level=0.80,
                                attack=0.014, grip=0.6), 0.030)
    # A thin metal-on-leather hiss riding the top of the slide.
    hiss = S.band_noise(0.22, r, 2600.0, 9500.0, order=2)
    hiss = S.bp_sweep(hiss, S.expsweep(0.22, 3400.0, 6200.0), q=2.0)
    hiss *= S.breakpoints(0.22, [(0.0, 0.0), (0.03, 0.35), (0.20, 1.0),
                                 (0.22, 0.2)], curve="exp")
    out = S.place(out, hiss * 0.22, 0.060)

    # It clears: the ring, and the throat of the sheath knocking behind it.
    out = S.place(out, _ring(r, 0.26, freq=2380.0, level=0.85, rough=0.30), 0.285)
    out = S.place(out, S.bar(0.09, 640.0, r, decay=0.022, strike=0.4) * 0.22, 0.285)
    out = S.place(out, _cloth(r, 0.18, level=0.20, low=300.0, high=2000.0,
                              attack=0.016, peak=0.4), 0.330)
    body = S.sine(dur, S.expsweep(dur, 126.0, 70.0)) * S.perc_env(dur, 0.008, 0.050)
    out = S.mix(out, S.saturate(body * 0.26, 1.8))
    return _gear_room(out, mix=0.14)


@cue("weaponStow")
def weapon_stow(r):
    """Back into the sheath. The leather resonance FALLS (the blade is
    going into a narrowing throat), there is no free ring at all - the
    steel is damped by the leather the whole way - and it ends on the
    guard meeting the mouth of the sheath: a short dull metal knock with
    the belt taking the weight."""
    dur = 0.46
    out = S.silence(dur)

    out = S.place(out, _cloth(r, 0.09, level=0.34, low=380.0, high=2900.0), 0.0)
    # The tip finding the mouth: one tiny tick before the slide.
    tick = S.band_noise(0.0015, r, 1800.0, 9000.0) * S.perc_env(0.0015, 0.0002, 0.0005)
    out = S.place(out, S.fit(tick, 0.02) * 0.30, 0.035)
    out = S.place(out, _leather(r, 0.24, f0=900.0, f1=430.0, level=0.80,
                                attack=0.012, grip=0.7), 0.045)

    # The guard arriving. Metal, but heavily damped - a knock, not a ring.
    knock = S.mix(S.metal_hit(0.11, r, 1180.0, ring=0.12, roughness=0.6) * 0.7,
                  S.membrane(0.12, 112.0, r, drop=0.5, noise=0.25, tau=0.028) * 0.8)
    out = S.place(out, S.lowpass(S.saturate(knock, 1.8), 3200.0, order=2) * 0.70, 0.250)
    out = S.place(out, _cloth(r, 0.16, level=0.22, low=260.0, high=1800.0,
                              attack=0.015, peak=0.4), 0.285)
    return _gear_room(out, mix=0.12)


@cue("fistReady")
def fist_ready(r):
    """No tool: the hands close. Two knuckles going a little apart (never
    together - a single crack reads as a break, two spaced 55 ms apart
    read as a fist closing), a glove tightening around them, and one soft
    low thump where the hands set. The quietest of the five on purpose:
    switching to fists should not be louder than drawing a weapon."""
    dur = 0.40
    out = S.silence(dur)

    out = S.place(out, _cloth(r, 0.16, level=0.50, low=320.0, high=2800.0,
                              attack=0.012, peak=0.45), 0.0)
    out = S.place(out, _knuckle(r, at_pitch=1.00, level=0.85), 0.085)
    out = S.place(out, _knuckle(r, at_pitch=0.84, level=0.55), 0.140)
    # The glove closing after them.
    out = S.place(out, _cloth(r, 0.19, level=0.34, low=280.0, high=2200.0,
                              attack=0.020, peak=0.5), 0.150)
    thump = S.sine(0.20, S.expsweep(0.20, 128.0, 64.0)) * S.perc_env(0.20, 0.006, 0.040)
    out = S.place(out, S.saturate(thump * 0.42, 2.0), 0.145)
    return _gear_room(out, mix=0.12)
