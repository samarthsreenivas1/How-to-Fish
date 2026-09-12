"""sfx_families.py - the fourteen creature VOICES.

Four cues per body family (`<F>Idle` `<F>Attack` `<F>Hurt` `<F>Die`), 56 in
all, every one 3D. This is the throat; `sfx_creatures.py` is what the
creature does to the world. The two play together constantly, so nothing in
here may read as sand, water impact or machinery for its own sake - it has
to read as a THING making a noise.

THE ONE RULE THAT MATTERS: no two families may be confusable. A player
hears a voice before they see the silhouette, and the voice has to name the
family on its own. So each family is built from a DIFFERENT synthesis
method, not from the same layer stack at a different pitch:

  smallFish   bubbles (Minnaert rising chirps), nothing else
  bigFish     low bubbles through a drum membrane - gulps with mass
  spiny       scattered tuned clicks (rattling spines) + an inflating hiss
  crustacean  dry high-Q resonators - chitin on chitin, no water at all
  eel         band-swept noise with a moving centre + a saw growl under it
  jelly       glass bells and pure sines, pitch-bending, no transient ever
  blob        a resonant low-pass swept over wet texture - suction
  wing        pulsed air puffs (the beat rate IS the family) + a formant cry
  burrower    grains and a saturated sub growl, everything muffled
  mimic       comb-filtered stick-slip creak, then a hard struck-wood snap
  undead      formant vowels over a detuned saw, gurgle and bone clatter
  elemental   crackle grains around a detuned tonal core, no body at all
  mechanical  metal_hit resonators, a fuse fizz and a ratchet
  flora       a stretching resonant tone that bends up, then a wet pop

PITCH. The client multiplies by `opts.pitch` from `body.scale`, so every
cue here is authored at a NEUTRAL middle size. That means no cue may depend
on a frequency being exactly where it is (nothing tuned to a musical key,
no filter fixed at a formant the pitch shift would move off), and the low
layers stay well above DC so a 0.6x shift does not fall out of the speaker.

SHAPES. Idle is a short call (0.3-0.7 s) that can fire on a loose timer
without becoming wallpaper. Attack is a lunge, 0.3-0.6 s, with its
transient in the first 10 ms so it lands with the damage. Hurt is SHORT
(0.2-0.4 s) and clearly the same voice interrupted. Die is the long one,
up to 2 s, and always has a tail: the voice stops before the body does.
"""

import numpy as np

import synth as S
from cues import cue

_SEED = 91


def _room(x, size=0.5, damping=0.55, mix=0.15, tail=True):
    """One room for all fourteen families, so they sit in the same world
    as each other and as the behaviour cues next door."""
    return S.reverb(x, size=size, damping=damping, mix=mix, seed=_SEED, tail=tail)


def _near_room(x, size=0.34, damping=0.68, mix=0.10, tail=True):
    """The 3D room, 2026-09-12. A positional cue is heard at 20-80 studs
    with Roblox's own rolloff on top, and reverb is the first thing that
    stops carrying at distance - a wet 3D cue arrives as mush with no
    transient left. So the fish voices sit in a SMALLER, DRIER room than
    the 2D sheets and put the difference into body instead. `_room` is
    still what the other twelve families use."""
    return S.reverb(x, size=size, damping=damping, mix=mix, seed=_SEED, tail=tail)


def _air_body(dur, r, low, high, points, level=1.0, centre=None):
    """Moving air through a body: filtered noise with a soft attack and a
    band centre that MOVES. Every organic voice has one under it; without
    it a creature call is a synth patch with an envelope on it."""
    y = S.band_noise(dur, r, low, high, order=3)
    if centre is not None:
        y = S.bp_sweep(y, centre, q=1.8)
    y *= S.breakpoints(dur, points, curve="exp")
    return y / (np.max(np.abs(y)) + 1e-12) * level
    # NB: named `_air_body`, not `_breath` - this module already has a
    # `_breath` further down and the later definition would silently win.


# ---------------------------------------------------------------------------
# shared helpers
#
# TOOLKIT BUG WORKAROUND (`_bell` / `_bar`): S.bell builds its strike click
# as band_noise(freq * 3, min(14000, freq * 14)) and S.bar as
# band_noise(freq * 2, min(9000, freq * 9)). Above ~4.7 kHz (bell) and
# ~4.5 kHz (bar) the low edge passes the high edge and scipy raises
# "Wn[0] must be less than Wn[1]". Both wrappers clamp the fundamental and
# re-add the lost brightness as plain air.
# ---------------------------------------------------------------------------

def _bell(dur, freq, r, **kw):
    f = min(float(freq), 4200.0)
    y = S.bell(dur, f, r, **kw)
    if f < float(freq):
        click = S.band_noise(min(0.008, dur), r, 6000.0, 15000.0, order=2)
        y = S.mix(y, S.fit(click * S.perc_env(min(0.008, dur), 0.0002, 0.002), dur) * 0.25)
    return y


def _bar(dur, freq, r, **kw):
    f = min(float(freq), 4000.0)
    return S.bar(dur, f, r, **kw)


def _clicks(dur, r, count, low, high, level=0.5, spread=None, start=0.0,
            decay=0.0, tuned=None, q=18.0):
    """A scatter of short events. `tuned` rings each one through a resonator
    at that frequency (times a random spread), which is the difference
    between chitin and gravel."""
    spread = (dur * 0.85) if spread is None else spread
    out = S.silence(start + spread + 0.06)
    times = np.sort(r.random(count)) * spread
    for i in range(count):
        d = 0.004 + 0.007 * float(r.random())
        g = S.band_noise(d, r, low, high, order=2) * S.perc_env(d, 0.0002, 0.0018)
        if tuned:
            g = S.fit(g, 0.05)
            f = tuned * float(2.0 ** (r.random() * 0.9 - 0.45))
            g = S.resonator(g, f, q=q) * S.expdec(0.05, 0.010)
        amp = level * (0.3 + 0.7 * float(r.random()))
        amp *= float(np.exp(-decay * times[i] / max(1e-3, spread)))
        out = S.place(out, g * amp, start + float(times[i]))
    return out


def _sub(dur, hi, lo, tau, drive=2.2, attack=0.003):
    y = S.sine(dur, S.expsweep(dur, hi, lo)) * S.perc_env(dur, attack, tau)
    return S.saturate(y, drive)


def _breath(dur, r, low, high, env_points, curve="exp", q=None):
    y = S.band_noise(dur, r, low, high, order=3)
    if q is not None:
        y = S.bp_sweep(y, q, q=1.8)
    y *= S.breakpoints(dur, env_points, curve=curve)
    return y


# ===========================================================================
# smallFish - bubbles and nothing else. A palm-sized fish: a flick, a chirp.
# ===========================================================================

def _fish_chirp(dur, f0, r, rise=3.0, level=1.0):
    y = S.bubble(dur, f0, r, rise=rise, tau=dur * 0.42)
    return y * level


@cue("smallFishIdle")
def small_fish_idle(r):
    """Two tiny bubbly chirps, the second higher - a fish saying nothing in
    particular. Deliberately small: this fires on a timer all day."""
    dur = 0.36
    out = S.silence(dur)
    # The two chirps are no longer identical in shape: the second is a
    # touch shorter and rises faster, which is what a second call from the
    # same animal does. Identical repeats are the tell of a synth.
    out = S.place(out, _fish_chirp(0.055, 620.0, r, rise=2.8, level=0.9), 0.0)
    out = S.place(out, _fish_chirp(0.042, 780.0, r, rise=3.4, level=0.6),
                  0.095 + 0.010 * float(r.random()))
    # A gill flick: the little breath of water a fish moves even at rest.
    gill = _air_body(0.10, r, 700.0, 5000.0,
                     [(0.0, 0.0), (0.025, 1.0), (0.10, 0.0)], level=0.20,
                     centre=S.expsweep(0.10, 2400.0, 1300.0))
    out = S.place(out, S.fit(gill, 0.10), 0.150)
    fizz = S.wet_texture(0.22, r, density=14.0, freq=1500.0, spread=2.0, level=0.22)
    return _near_room(S.mix(S.fit(out, dur), S.fit(fizz, dur)), size=0.34, mix=0.11)


@cue("smallFishAttack")
def small_fish_attack(r):
    """A darting nip: a flick of water off the tail, then a hard little
    chirp where the mouth closes."""
    dur = 0.30
    flick = S.band_noise(0.06, r, 900.0, 9000.0, order=3)
    flick = S.lp_sweep(flick, S.expsweep(0.06, 8000.0, 1200.0), order=2)
    flick *= S.perc_env(0.06, 0.0006, 0.012, curve=1.3)
    nip = _fish_chirp(0.045, 900.0, r, rise=3.6, level=1.0)
    tick = S.band_noise(0.005, r, 2000.0, 11000.0) * S.perc_env(0.005, 0.0002, 0.0014)
    out = S.place(S.silence(dur), flick * 0.8, 0.0)
    out = S.place(out, S.fit(nip, 0.06), 0.022)
    out = S.place(out, S.fit(tick, 0.02) * 0.5, 0.020)
    # The body behind the dart. A nip with no mass under it is a click;
    # 3D cues need this more than 2D ones, because the room is not there
    # to lend them any weight at distance.
    mass = S.membrane(0.10, 168.0, r, drop=0.55, noise=0.30, tau=0.022)
    out = S.place(out, S.fit(S.saturate(mass * 0.7, 2.0), 0.10) * 0.45, 0.004)
    wake = S.wet_texture(0.14, r, density=20.0, freq=1600.0, spread=2.2, level=0.20)
    out = S.place(out, S.fit(wake, 0.14) * 0.6, 0.040)
    return _near_room(S.fit(out, dur), size=0.30, mix=0.10)


@cue("smallFishHurt")
def small_fish_hurt(r):
    """The chirp inverted - a bubble that FALLS instead of rising, which the
    ear reads as wrong, plus a squeezed spurt of small bubbles."""
    dur = 0.26
    down = S.sine(0.07, S.expsweep(0.07, 1050.0, 430.0)) * S.perc_env(0.07, 0.0008, 0.020)
    spurt = S.wet_texture(0.16, r, density=34.0, freq=1100.0, spread=2.2, level=0.45)
    slap = S.band_noise(0.03, r, 700.0, 6000.0, order=2) * S.perc_env(0.03, 0.0004, 0.007)
    # A contour, not a straight fall: it catches for a moment in the
    # middle before giving out, which is what a squeezed animal does.
    down2 = S.sine(0.09, S.breakpoints(0.09, [(0.0, 1050.0), (0.030, 560.0),
                                              (0.045, 640.0), (0.09, 380.0)],
                                       curve="exp"))
    down2 *= S.perc_env(0.09, 0.0008, 0.026)
    gasp = _air_body(0.11, r, 600.0, 6000.0,
                     [(0.0, 0.0), (0.012, 1.0), (0.11, 0.0)], level=0.28,
                     centre=S.expsweep(0.11, 2600.0, 900.0))
    y = S.mix(S.fit(down, dur) * 0.5, S.fit(down2, dur) * 0.7,
              S.fit(spurt, dur) * 0.6, S.fit(slap, dur) * 0.5,
              S.fit(gasp, dur))
    return _near_room(y, size=0.30, mix=0.10)


@cue("smallFishDie")
def small_fish_die(r):
    """A last chirp giving out, a flop, and the bubbles going up without
    it. The tail is the point: the fish stops before the water does."""
    dur = 1.05
    out = S.silence(dur)
    for i, (at, f, lv) in enumerate(((0.0, 780.0, 1.0), (0.11, 600.0, 0.7),
                                     (0.24, 440.0, 0.45))):
        c = S.sine(0.075, S.expsweep(0.075, f, f * 0.55)) * S.perc_env(0.075, 0.001, 0.022)
        out = S.place(out, c * lv, at)
    flop = S.band_noise(0.09, r, 500.0, 5500.0, order=3)
    flop = S.lp_sweep(flop, S.expsweep(0.09, 5000.0, 700.0), order=2)
    flop *= S.perc_env(0.09, 0.0008, 0.018, curve=1.3)
    out = S.place(out, flop * 0.55, 0.33)
    trail = S.wet_texture(0.62, r, density=11.0, freq=900.0, spread=2.6, level=0.34)
    trail = S.fit(trail, 0.62) * S.breakpoints(0.62, [(0.0, 1.0), (0.62, 0.15)])
    out = S.place(out, trail, 0.36)
    # One last gill flare, weaker than the idle's, under the third chirp.
    out = S.place(out, S.fit(_air_body(0.13, r, 500.0, 4500.0,
                                       [(0.0, 0.0), (0.030, 1.0), (0.13, 0.0)],
                                       level=0.16,
                                       centre=S.expsweep(0.13, 1800.0, 800.0)), 0.13),
                  0.255)
    return _near_room(S.fit(out, dur), size=0.42, damping=0.66, mix=0.14)


# ===========================================================================
# bigFish - the same water, an order of magnitude more of it. Low gulps
# through a drum membrane, and a tail slapping something solid.
# ===========================================================================

def _gulp(dur, f0, r, level=1.0):
    """A gulp is a big slow bubble with a drum head behind it - the bubble
    alone is a cartoon, the membrane alone is a kick."""
    bub = S.bubble(dur, f0, r, rise=1.7, tau=dur * 0.5)
    head = S.membrane(dur, f0 * 0.55, r, drop=0.5, noise=0.18, tau=dur * 0.4)
    return S.mix(bub * 0.8, S.saturate(head * 0.7, 1.9)) * level


@cue("bigFishIdle")
def big_fish_idle(r):
    """One low wet gulp with the water settling after it."""
    dur = 0.52
    g = _gulp(0.20, 150.0, r, level=1.0)
    settle = S.wet_texture(0.30, r, density=8.0, freq=340.0, spread=2.0, level=0.30)
    low = _sub(dur, 110.0, 58.0, 0.10, drive=2.0) * 0.45
    out = S.place(S.silence(dur), S.fit(g, 0.22), 0.0)
    out = S.place(out, S.fit(settle, 0.30) * 0.7, 0.16)
    # The slow breath through a big set of gills, behind the gulp. It is
    # the layer that makes this an ANIMAL at rest rather than a bloop.
    breath = _air_body(0.30, r, 180.0, 2600.0,
                       [(0.0, 0.0), (0.09, 1.0), (0.20, 0.7), (0.30, 0.0)],
                       level=0.26,
                       centre=S.breakpoints(0.30, [(0.0, 520.0), (0.10, 900.0),
                                                   (0.30, 420.0)], curve="exp"))
    out = S.place(out, S.fit(breath, 0.30), 0.130)
    return _near_room(S.mix(S.fit(out, dur), low * 1.25), size=0.40,
                      damping=0.70, mix=0.12)


@cue("bigFishAttack")
def big_fish_attack(r):
    """A body committing: water shoved aside, a hard tail slap, and the
    gulp of the mouth closing over where you were."""
    dur = 0.55
    surge = S.band_noise(0.22, r, 200.0, 6500.0, order=3)
    surge = S.lp_sweep(surge, S.breakpoints(0.22, [(0.0, 1400.0), (0.06, 5200.0),
                                                   (0.22, 600.0)], curve="exp"), order=2)
    surge *= S.breakpoints(0.22, [(0.0, 0.0), (0.02, 1.0), (0.22, 0.0)], curve="exp")
    slap = S.membrane(0.16, 96.0, r, drop=0.45, noise=0.55, tau=0.04, sweep_time=0.010)
    gulp = _gulp(0.16, 190.0, r, level=0.9)
    body = _sub(dur, 175.0, 55.0, 0.12, drive=2.6) * 0.8
    out = S.place(S.silence(dur), surge * 0.8, 0.0)
    out = S.place(out, S.saturate(slap, 2.2) * 0.9, 0.015)
    out = S.place(out, S.fit(gulp, 0.18), 0.14)
    # The intake before the lunge - 60 ms of water being drawn in, rising.
    # A predator's attack starts before the impact does.
    intake = _air_body(0.07, r, 300.0, 3200.0,
                       [(0.0, 0.0), (0.050, 1.0), (0.07, 0.25)], level=0.30,
                       centre=S.expsweep(0.07, 500.0, 1400.0))
    out = S.mix(out, S.fit(intake, dur))
    jaw = S.bar(0.09, 210.0, r, decay=0.024, strike=0.45) * 0.22
    out = S.place(out, S.fit(jaw, 0.09), 0.150)
    return _near_room(S.mix(S.fit(out, dur), body * 1.2), size=0.40,
                      damping=0.64, mix=0.11)


@cue("bigFishHurt")
def big_fish_hurt(r):
    """A gulp that gets cut off - the air goes out instead of in."""
    dur = 0.34
    out_ = S.sine(0.10, S.expsweep(0.10, 300.0, 128.0)) * S.perc_env(0.10, 0.0012, 0.030)
    out_ = S.saturate(out_, 2.4)
    burst = S.wet_texture(0.20, r, density=26.0, freq=520.0, spread=2.2, level=0.5)
    thud = S.membrane(0.18, 88.0, r, drop=0.5, noise=0.25, tau=0.045)
    # The pitch CONTOUR is the voice: it drops, catches, and drops again,
    # rather than sliding straight down.
    contour = S.sine(0.13, S.breakpoints(0.13, [(0.0, 300.0), (0.045, 150.0),
                                                (0.065, 178.0), (0.13, 104.0)],
                                         curve="exp"))
    contour *= S.perc_env(0.13, 0.0015, 0.040)
    huff = _air_body(0.16, r, 200.0, 2800.0,
                     [(0.0, 0.0), (0.020, 1.0), (0.16, 0.0)], level=0.30,
                     centre=S.expsweep(0.16, 900.0, 380.0))
    y = S.mix(S.fit(out_, dur) * 0.45, S.fit(S.saturate(contour, 2.3), dur) * 0.8,
              S.fit(burst, dur) * 0.55, S.fit(huff, dur),
              S.fit(S.saturate(thud, 2.0), dur) * 0.7)
    return _near_room(y, size=0.36, damping=0.68, mix=0.10)


@cue("bigFishDie")
def big_fish_die(r):
    """It goes over: a long low groan out of the gulp, one last heavy slap,
    and the water closing above it."""
    dur = 1.75
    groan = S.sine(0.85, S.expsweep(0.85, 190.0, 74.0)) * 0.8
    groan = S.vibrato(groan, rate=4.5, depth_cents=45.0)
    groan *= S.breakpoints(0.85, [(0.0, 0.0), (0.03, 1.0), (0.5, 0.55),
                                  (0.85, 0.0)], curve="exp")
    groan = S.saturate(groan, 2.2)
    bubbles = S.fit(S.wet_texture(1.1, r, density=9.0, freq=330.0, spread=2.6,
                                  level=0.42), 1.1)
    bubbles *= S.breakpoints(1.1, [(0.0, 0.4), (0.35, 1.0), (1.1, 0.1)])
    slap = S.membrane(0.24, 78.0, r, drop=0.4, noise=0.5, tau=0.06, sweep_time=0.014)
    close = S.splash(0.42, r, low=350.0, high=4500.0, sweep_to=240.0, body=0.5)
    out = S.place(S.silence(dur), groan * 0.75, 0.0)
    out = S.place(out, S.saturate(slap, 2.2) * 0.75, 0.62)
    out = S.place(out, close * 0.45, 0.74)
    out = S.place(out, bubbles * 0.6, 0.55)
    # The last breath going out of it, long and falling, under the groan.
    last = _air_body(0.45, r, 150.0, 2200.0,
                     [(0.0, 0.0), (0.06, 1.0), (0.25, 0.45), (0.45, 0.0)],
                     level=0.24,
                     centre=S.expsweep(0.45, 800.0, 260.0))
    out = S.place(out, S.fit(last, 0.45), 0.060)
    return _near_room(S.fit(out, dur), size=0.60, damping=0.74, mix=0.16)


# ===========================================================================
# spiny - armour first. A rattle of tuned spines over an inflating hiss.
# No water in this voice at all; the fish under it is implied.
# ===========================================================================

def _spines(dur, r, count, level=0.5, spread=None, start=0.0, decay=0.0):
    return _clicks(dur, r, count, 2200.0, 11000.0, level=level, spread=spread,
                   start=start, decay=decay, tuned=2600.0, q=26.0)


@cue("spinyIdle")
def spiny_idle(r):
    """The spines shifting against each other, and one short intake."""
    dur = 0.42
    rattle = _spines(0.30, r, 11, level=0.55, spread=0.26, decay=1.2)
    intake = S.band_noise(0.13, r, 1400.0, 9000.0, order=3)
    intake = S.bp_sweep(intake, S.expsweep(0.13, 2200.0, 3800.0), q=2.2)
    intake *= S.breakpoints(0.13, [(0.0, 0.0), (0.09, 1.0), (0.13, 0.0)], curve="exp")
    y = S.mix(S.fit(rattle, dur), S.fit(S.place(S.silence(dur), intake * 0.55, 0.06), dur))
    # Sparse tuned clicks peak far above their own average; softclip the
    # spikes so the peak-normalise brings the body of the rattle up.
    y = S.softclip(y * 1.6, 0.6)
    return _room(y, size=0.4, damping=0.45, mix=0.13)


@cue("spinyAttack")
def spiny_attack(r):
    """It inflates and the spines lock out: a hiss RISING in pitch and
    level, cut off by a hard rattle burst as everything comes up at once."""
    dur = 0.48
    infl = S.band_noise(0.24, r, 900.0, 11000.0, order=3)
    infl = S.bp_sweep(infl, S.expsweep(0.24, 1600.0, 5200.0), q=1.9)
    infl *= S.breakpoints(0.24, [(0.0, 0.0), (0.02, 0.35), (0.22, 1.0),
                                 (0.24, 0.5)], curve="exp")
    lock = _spines(0.22, r, 16, level=0.85, spread=0.09, decay=0.4, start=0.0)
    stab = _bar(0.12, 3100.0, r, decay=0.045, strike=0.9) * 0.5
    puff = _sub(dur, 200.0, 92.0, 0.05, drive=2.0) * 0.35
    out = S.place(S.silence(dur), infl * 0.75, 0.0)
    out = S.place(out, S.fit(lock, 0.30), 0.225)
    out = S.place(out, S.fit(stab, 0.14), 0.228)
    return _room(S.mix(S.fit(out, dur), puff), size=0.4, damping=0.4, mix=0.14)


@cue("spinyHurt")
def spiny_hurt(r):
    """A squeak of air out of the body and the spines clattering down."""
    dur = 0.30
    squeak = S.sine(0.09, S.expsweep(0.09, 2100.0, 900.0)) * S.perc_env(0.09, 0.0008, 0.022)
    squeak = S.mix(squeak, S.band_noise(0.09, r, 2000.0, 9000.0, order=2) *
                   S.perc_env(0.09, 0.0008, 0.014) * 0.6)
    rattle = _spines(0.22, r, 10, level=0.7, spread=0.16, decay=2.0, start=0.01)
    y = S.mix(S.fit(squeak, dur) * 0.8, S.fit(rattle, dur))
    return _room(y, size=0.35, damping=0.45, mix=0.12)


@cue("spinyDie")
def spiny_die(r):
    """It deflates. The hiss falls where the attack's rose, the rattle
    slows and thins, and a few chips of shell land last."""
    dur = 1.55
    defl = S.band_noise(0.85, r, 700.0, 10000.0, order=3)
    defl = S.bp_sweep(defl, S.expsweep(0.85, 4600.0, 900.0), q=1.7)
    defl *= S.breakpoints(0.85, [(0.0, 0.0), (0.02, 1.0), (0.45, 0.45),
                                 (0.85, 0.0)], curve="exp")
    rattle = _spines(1.0, r, 22, level=0.6, spread=0.9, decay=2.6, start=0.02)
    sag = S.sine(0.7, S.expsweep(0.7, 1300.0, 380.0)) * 0.25
    sag = S.vibrato(sag, rate=6.5, depth_cents=60.0)
    sag *= S.breakpoints(0.7, [(0.0, 0.0), (0.05, 1.0), (0.7, 0.0)], curve="exp")
    chips = _clicks(0.5, r, 7, 1800.0, 9000.0, level=0.30, spread=0.35,
                    start=0.0, decay=1.2, tuned=1500.0, q=14.0)
    out = S.place(S.silence(dur), defl * 0.8, 0.0)
    out = S.place(out, S.fit(rattle, 1.05), 0.0)
    out = S.place(out, sag * 0.7, 0.03)
    out = S.place(out, S.fit(chips, 0.5), 0.85)
    return _room(S.fit(out, dur), size=0.55, damping=0.5, mix=0.17)


# ===========================================================================
# crustacean - chitin on chitin. Dry, high-Q, no water anywhere in it.
# ===========================================================================

def _chitin(dur, r, count, level=0.6, spread=None, start=0.0, decay=0.0,
            tuned=1700.0):
    return _clicks(dur, r, count, 900.0, 7000.0, level=level, spread=spread,
                   start=start, decay=decay, tuned=tuned, q=22.0)


@cue("crustaceanIdle")
def crustacean_idle(r):
    """Scuttling: a fast irregular roll of leg clicks that slows and stops.
    Irregular on purpose - even spacing is a machine, and mechanical is a
    different family two sections down."""
    dur = 0.52
    out = S.silence(dur)
    at = 0.0
    gap = 0.030
    while at < 0.40:
        f = 1650.0 * float(2.0 ** (r.random() * 0.8 - 0.4))
        exc = S.fit(S.band_noise(0.004, r, 1200.0, 8000.0, order=2) *
                    S.perc_env(0.004, 0.0002, 0.0014), 0.05)
        tick = S.resonator(exc, f, q=24.0) * S.expdec(0.05, 0.009)
        out = S.place(out, tick * (0.35 + 0.65 * float(r.random())), at)
        at += gap * (0.6 + 0.8 * float(r.random()))
        gap *= 1.06
    tap = _bar(0.10, 820.0, r, decay=0.035, strike=0.6) * 0.35
    out = S.place(out, S.fit(tap, 0.12), 0.42)
    return _room(S.fit(out, dur), size=0.35, damping=0.4, mix=0.12)


@cue("crustaceanAttack")
def crustacean_attack(r):
    """The claw: a scrape as it opens, then it SNAPS - a hard dry crack with
    a short shell ring and a thump of the whole body behind it."""
    dur = 0.42
    scrape = S.band_noise(0.10, r, 800.0, 6000.0, order=3)
    scrape = S.bp_sweep(scrape, S.expsweep(0.10, 1200.0, 2600.0), q=3.0)
    scrape *= S.breakpoints(0.10, [(0.0, 0.0), (0.03, 0.7), (0.10, 0.0)], curve="exp")
    crack = S.band_noise(0.006, r, 700.0, 12000.0) * S.perc_env(0.006, 0.00008, 0.0016)
    crack = S.fit(crack, 0.22)
    shell = np.zeros(S.n(0.22))
    for i, f in enumerate((760.0, 1490.0, 2610.0, 3980.0)):
        shell += S.resonator(crack, f, q=24.0) / (i + 1.3)
    shell *= S.expdec(0.22, 0.028)
    thump = S.membrane(0.10, 128.0, r, drop=0.5, noise=0.12, tau=0.024)
    out = S.place(S.silence(dur), scrape * 0.45, 0.0)
    out = S.place(out, S.mix(crack * 0.8, shell), 0.105)
    out = S.place(out, S.saturate(thump, 2.0) * 0.5, 0.106)
    return _room(S.fit(out, dur), size=0.35, damping=0.45, mix=0.12)


@cue("crustaceanHurt")
def crustacean_hurt(r):
    """A shell scraped hard and a burst of legs going everywhere."""
    dur = 0.30
    grind = S.band_noise(0.12, r, 600.0, 5000.0, order=3)
    grind = S.bp_sweep(grind, S.breakpoints(0.12, [(0.0, 2400.0), (0.12, 900.0)],
                                            curve="exp"), q=2.4)
    grind *= S.breakpoints(0.12, [(0.0, 0.0), (0.008, 1.0), (0.12, 0.0)], curve="exp")
    legs = _chitin(0.22, r, 12, level=0.65, spread=0.16, decay=1.8, start=0.005)
    y = S.mix(S.fit(grind, dur) * 0.8, S.fit(legs, dur))
    return _room(y, size=0.32, damping=0.45, mix=0.11)


@cue("crustaceanDie")
def crustacean_die(r):
    """The shell fails: one big crack, the plates coming apart, and the
    legs clattering to a stop. All dry - a crustacean never gurgles."""
    dur = 1.60
    exc = S.fit(S.white(0.006, r) * S.perc_env(0.006, 0.00008, 0.0018), 0.40)
    plates = np.zeros(S.n(0.40))
    for i, f in enumerate((420.0, 880.0, 1560.0, 2740.0, 4100.0)):
        plates += S.resonator(exc, f, q=18.0) / (i + 1.2)
    plates *= S.expdec(0.40, 0.055)
    split = S.band_noise(0.20, r, 500.0, 9000.0, order=3)
    split = S.lp_sweep(split, S.expsweep(0.20, 8000.0, 900.0), order=2)
    split *= S.perc_env(0.20, 0.0003, 0.035, curve=1.3)
    fall = _chitin(1.05, r, 26, level=0.55, spread=0.95, decay=2.4, start=0.0,
                   tuned=1300.0)
    last = _bar(0.20, 380.0, r, decay=0.07, strike=0.5) * 0.35
    out = S.place(S.silence(dur), S.mix(plates, split * 0.7), 0.0)
    out = S.place(out, S.fit(fall, 1.1), 0.10)
    out = S.place(out, S.fit(last, 0.22), 1.12)
    return _room(S.fit(out, dur), size=0.5, damping=0.5, mix=0.16)


# ===========================================================================
# eel - a long body. A sinuous sizzling hiss whose band centre WANDERS
# (that wander is the coil), over a low saw growl.
# ===========================================================================

def _sizzle(dur, r, centre, wander=0.5, rate=7.0, level=1.0):
    y = S.band_noise(dur, r, 700.0, 12000.0, order=3)
    tt = np.arange(S.n(dur)) / S.SR
    cen = centre * (1.0 + wander * np.sin(2.0 * np.pi * rate * tt))
    return S.bp_sweep(y, cen, q=2.4) * level


def _growl(dur, freq, r, cutoff, level=1.0, res=0.5):
    y = S.supersaw(dur, freq, voices=4, detune=0.010, phase_seed=r)
    y = S.moog(y, cutoff, res=res)
    return S.saturate(y * 0.8, 2.2) * level


@cue("eelIdle")
def eel_idle(r):
    """A coil shifting: the sizzle wandering slowly, with a low growl
    breathing under it. Menace at rest."""
    dur = 0.62
    sz = _sizzle(0.55, r, 2600.0, wander=0.42, rate=4.2, level=0.55)
    sz *= S.breakpoints(0.55, [(0.0, 0.0), (0.10, 1.0), (0.40, 0.7),
                               (0.55, 0.0)], curve="exp")
    gr = _growl(0.5, 96.0, r, S.breakpoints(0.5, [(0.0, 320.0), (0.25, 700.0),
                                                  (0.5, 300.0)]), level=0.45)
    gr *= S.breakpoints(0.5, [(0.0, 0.0), (0.12, 1.0), (0.5, 0.0)], curve="exp")
    out = S.place(S.silence(dur), sz, 0.0)
    out = S.place(out, gr, 0.03)
    return _room(S.fit(out, dur), size=0.5, damping=0.6, mix=0.17)


@cue("eelAttack")
def eel_attack(r):
    """The strike: the whole coil releases at once. The sizzle rate goes up
    with the body, the growl opens, and the bite is the punctuation."""
    dur = 0.50
    rush = _sizzle(0.20, r, 3400.0, wander=0.55, rate=17.0, level=0.9)
    rush *= S.breakpoints(0.20, [(0.0, 0.0), (0.015, 0.7), (0.16, 1.0),
                                 (0.20, 0.0)], curve="exp")
    gr = _growl(0.24, 110.0, r, S.expsweep(0.24, 500.0, 1800.0), level=0.7, res=0.6)
    gr *= S.breakpoints(0.24, [(0.0, 0.0), (0.01, 0.8), (0.20, 1.0), (0.24, 0.0)],
                        curve="exp")
    bite = S.band_noise(0.008, r, 800.0, 11000.0) * S.perc_env(0.008, 0.0001, 0.0022)
    bite = S.fit(bite, 0.16)
    jaw = S.resonator(bite, 560.0, q=16.0) + S.resonator(bite, 1180.0, q=13.0) * 0.6
    jaw *= S.expdec(0.16, 0.022)
    snapthud = S.membrane(0.12, 105.0, r, drop=0.45, noise=0.20, tau=0.028)
    out = S.place(S.silence(dur), rush, 0.0)
    out = S.place(out, gr, 0.0)
    out = S.place(out, S.mix(bite * 0.8, jaw), 0.195)
    out = S.place(out, S.saturate(snapthud, 2.2) * 0.55, 0.196)
    return _room(S.fit(out, dur), size=0.45, damping=0.55, mix=0.15)


@cue("eelHurt")
def eel_hurt(r):
    """A hiss spiking as the body convulses - the wander goes fast and
    narrow, and the growl chokes."""
    dur = 0.32
    sz = _sizzle(0.18, r, 3000.0, wander=0.30, rate=26.0, level=0.9)
    sz *= S.breakpoints(0.18, [(0.0, 0.0), (0.006, 1.0), (0.18, 0.0)], curve="exp")
    gr = _growl(0.16, 130.0, r, S.expsweep(0.16, 1400.0, 380.0), level=0.6, res=0.55)
    gr *= S.perc_env(0.16, 0.002, 0.045)
    y = S.mix(S.fit(sz, dur) * 0.85, S.fit(gr, dur))
    return _room(y, size=0.4, damping=0.6, mix=0.14)


@cue("eelDie")
def eel_die(r):
    """The length goes slack: the growl slides down and loses its filter,
    the sizzle wanders slower and wider, and the last of it dissolves into
    the water rather than stopping."""
    dur = 1.85
    gr = _growl(1.05, 120.0, r, S.breakpoints(1.05, [(0.0, 1500.0), (0.45, 600.0),
                                                     (1.05, 220.0)], curve="exp"),
                level=0.75, res=0.5)
    gr = S.vibrato(gr, rate=3.4, depth_cents=70.0)
    gr *= S.breakpoints(1.05, [(0.0, 0.0), (0.02, 1.0), (0.55, 0.55),
                               (1.05, 0.0)], curve="exp")
    sz = _sizzle(1.25, r, 2300.0, wander=0.6, rate=2.6, level=0.55)
    sz *= S.breakpoints(1.25, [(0.0, 0.5), (0.15, 1.0), (1.25, 0.0)], curve="exp")
    thrash = S.silence(dur)
    for at, amp in ((0.10, 0.7), (0.34, 0.5), (0.66, 0.3)):
        w = S.band_noise(0.07, r, 600.0, 7000.0, order=3)
        w = S.lp_sweep(w, S.expsweep(0.07, 6000.0, 800.0), order=2)
        w *= S.perc_env(0.07, 0.0008, 0.014, curve=1.3)
        thrash = S.place(thrash, w * amp, at)
    settle = S.fit(S.wet_texture(0.6, r, density=8.0, freq=420.0, spread=2.4,
                                 level=0.32), 0.6)
    settle *= S.breakpoints(0.6, [(0.0, 1.0), (0.6, 0.1)])
    out = S.place(S.silence(dur), gr, 0.0)
    out = S.place(out, sz * 0.8, 0.0)
    out = S.place(out, thrash * 0.6, 0.0)
    out = S.place(out, settle * 0.7, 1.05)
    return _room(S.fit(out, dur), size=0.7, damping=0.65, mix=0.21)


# ===========================================================================
# jelly - glass and pure tone. Pitch bends everywhere, and there is NEVER a
# hard transient: every envelope in this family has a slow attack.
# ===========================================================================

def _jelly_pulse(dur, freq, r, bend=1.25, level=1.0):
    core = S.sine(dur, S.expsweep(dur, freq, freq * bend)) * 0.6
    core += S.sine(dur, S.expsweep(dur, freq * 2.01, freq * 2.01 * bend)) * 0.22
    glass = _bell(dur, freq * 2.0, r, decay=dur * 0.55, strike=0.15,
                  inharmonic=0.85) * 0.35
    env = S.breakpoints(dur, [(0.0, 0.0), (dur * 0.35, 1.0), (dur, 0.0)], curve="exp")
    return S.mix(core, glass) * env * level


@cue("jellyIdle")
def jelly_idle(r):
    """One bell pulsing: a soft glassy hum that swells, bends up and goes."""
    dur = 0.68
    y = _jelly_pulse(0.62, 430.0, r, bend=1.22, level=1.0)
    shimmer = S.band_noise(0.5, r, 4000.0, 12000.0, order=2)
    shimmer = S.bp_sweep(shimmer, S.expsweep(0.5, 5000.0, 9000.0), q=2.0)
    shimmer *= S.breakpoints(0.5, [(0.0, 0.0), (0.3, 1.0), (0.5, 0.0)], curve="exp")
    y = S.mix(S.fit(y, dur), S.fit(S.place(S.silence(dur), shimmer * 0.10, 0.08), dur))
    return _room(y, size=0.75, damping=0.35, mix=0.26)


@cue("jellyAttack")
def jellyAttack(r):
    """The sting: the hum contracts - pitch bends DOWN as it gathers, then
    a bright glassy discharge on top. Soft attack even here; the damage
    reads from the discharge, not from a click."""
    dur = 0.52
    gather = S.sine(0.20, S.expsweep(0.20, 520.0, 300.0)) * 0.7
    gather = S.mix(gather, S.sine(0.20, S.expsweep(0.20, 781.0, 451.0)) * 0.25)
    gather *= S.breakpoints(0.20, [(0.0, 0.0), (0.16, 1.0), (0.20, 0.8)], curve="exp")
    disc = _bell(0.32, 1240.0, r, decay=0.16, strike=0.35, inharmonic=0.9)
    disc = S.mix(disc, S.sine(0.32, S.expsweep(0.32, 1240.0, 1860.0)) *
                 S.breakpoints(0.32, [(0.0, 0.0), (0.010, 1.0), (0.32, 0.0)],
                               curve="exp") * 0.45)
    pop = S.bubble(0.05, 380.0, r, rise=2.4) * 0.35
    out = S.place(S.silence(dur), gather * 0.8, 0.0)
    out = S.place(out, disc * 0.85, 0.185)
    out = S.place(out, S.fit(pop, 0.06), 0.19)
    return _room(S.fit(out, dur), size=0.8, damping=0.3, mix=0.26)


@cue("jellyHurt")
def jelly_hurt(r):
    """The tone goes sour: two partials pull apart and beat against each
    other, and the bell rings off-key."""
    dur = 0.34
    a = S.sine(0.24, S.expsweep(0.24, 610.0, 470.0)) * 0.6
    b = S.sine(0.24, S.expsweep(0.24, 640.0, 452.0)) * 0.5
    beat = (a + b) * S.breakpoints(0.24, [(0.0, 0.0), (0.02, 1.0), (0.24, 0.0)],
                                   curve="exp")
    sour = _bell(0.28, 900.0, r, decay=0.10, strike=0.25, inharmonic=1.3) * 0.4
    wet = S.wet_texture(0.16, r, density=16.0, freq=800.0, spread=2.0, level=0.22)
    y = S.mix(S.fit(beat, dur) * 0.9, S.fit(sour, dur), S.fit(wet, dur) * 0.5)
    return _room(y, size=0.65, damping=0.4, mix=0.24)


@cue("jellyDie")
def jelly_die(r):
    """The pulse slows and detunes until it is not a pitch any more, and
    what is left is the glass ringing out into the water."""
    dur = 1.45
    out = S.silence(dur)
    times = (0.0, 0.30, 0.62, 0.92)
    freqs = (470.0, 420.0, 355.0, 280.0)
    lens = (0.30, 0.36, 0.42, 0.50)
    for at, f, ln in zip(times, freqs, lens):
        p = _jelly_pulse(ln, f, r, bend=0.82, level=1.0 - 0.18 * times.index(at))
        out = S.place(out, p, at)
    drift = S.sine(1.0, S.expsweep(1.0, 300.0, 168.0)) * 0.22
    drift = S.vibrato(drift, rate=2.2, depth_cents=110.0)
    drift *= S.breakpoints(1.0, [(0.0, 0.0), (0.25, 1.0), (1.0, 0.0)], curve="exp")
    ring = _bell(0.8, 620.0, r, decay=0.40, strike=0.2, inharmonic=1.05) * 0.30
    out = S.place(out, drift, 0.30)
    out = S.place(out, ring, 0.62)
    return _room(S.fit(out, dur), size=0.72, damping=0.35, mix=0.28)


# ===========================================================================
# blob - suction. A resonant low-pass swept hard over wet texture; the
# sweep direction is the whole grammar (in = gathering, out = releasing).
# ===========================================================================

def _squelch(dur, r, f_from, f_to, q=7.0, level=1.0, density=30.0):
    wet = S.fit(S.wet_texture(dur, r, density=density, freq=420.0, spread=2.6,
                              level=0.6), dur)
    src = S.mix(wet, S.band_noise(dur, r, 120.0, 4000.0, order=2) * 0.5)
    y = S.svf(src, S.expsweep(dur, f_from, f_to), q=q, mode="low")
    return y * level


@cue("blobIdle")
def blob_idle(r):
    """A mass shifting where it stands: one slow gloopy squelch, sucking
    inward, with a wet slump under it."""
    dur = 0.60
    sq = _squelch(0.48, r, 1500.0, 380.0, q=6.5, level=0.9, density=26.0)
    sq *= S.breakpoints(0.48, [(0.0, 0.0), (0.10, 1.0), (0.34, 0.6),
                               (0.48, 0.0)], curve="exp")
    slump = _sub(dur, 105.0, 52.0, 0.13, drive=2.2, attack=0.020) * 0.45
    return _room(S.mix(S.fit(sq, dur), slump), size=0.45, damping=0.75, mix=0.15)


@cue("blobAttack")
def blob_attack(r):
    """It throws itself: the filter opens FAST outward, then a wet slap as
    the mass arrives and a suck as it pulls back together."""
    dur = 0.55
    lunge = _squelch(0.16, r, 300.0, 3200.0, q=8.0, level=1.0, density=44.0)
    lunge *= S.breakpoints(0.16, [(0.0, 0.0), (0.012, 1.0), (0.16, 0.15)], curve="exp")
    slap = S.band_noise(0.10, r, 400.0, 6000.0, order=3)
    slap = S.lp_sweep(slap, S.expsweep(0.10, 5200.0, 600.0), order=2)
    slap *= S.perc_env(0.10, 0.0006, 0.016, curve=1.3)
    suck = _squelch(0.24, r, 2400.0, 420.0, q=9.0, level=0.6, density=30.0)
    suck *= S.breakpoints(0.24, [(0.0, 0.0), (0.06, 1.0), (0.24, 0.0)], curve="exp")
    mass = _sub(dur, 165.0, 48.0, 0.10, drive=2.6) * 0.7
    out = S.place(S.silence(dur), lunge * 0.9, 0.0)
    out = S.place(out, slap * 0.8, 0.145)
    out = S.place(out, suck, 0.22)
    return _room(S.mix(S.fit(out, dur), mass), size=0.45, damping=0.75, mix=0.14)


@cue("blobHurt")
def blob_hurt(r):
    """A spurt: pressure finding a hole. Short, wet and high for a blob."""
    dur = 0.28
    spurt = _squelch(0.16, r, 700.0, 2600.0, q=9.0, level=1.0, density=60.0)
    spurt *= S.breakpoints(0.16, [(0.0, 0.0), (0.008, 1.0), (0.16, 0.0)], curve="exp")
    plop = S.bubble(0.06, 300.0, r, rise=2.8) * 0.5
    y = S.mix(S.fit(spurt, dur), S.fit(plop, dur))
    return _room(y, size=0.4, damping=0.75, mix=0.14)


@cue("blobDie")
def blob_die(r):
    """It stops holding itself together: a long sagging squelch, a slump
    with real weight in it, and the last of it draining."""
    dur = 1.80
    sag = _squelch(0.95, r, 2600.0, 220.0, q=6.0, level=0.9, density=22.0)
    sag *= S.breakpoints(0.95, [(0.0, 0.0), (0.05, 1.0), (0.55, 0.55),
                                (0.95, 0.0)], curve="exp")
    slump = S.membrane(0.4, 62.0, r, drop=0.45, noise=0.40, tau=0.13, sweep_time=0.030)
    spread = S.band_noise(0.6, r, 150.0, 2600.0, order=2)
    spread = S.lp_sweep(spread, S.expsweep(0.6, 2200.0, 300.0), order=2)
    spread *= S.breakpoints(0.6, [(0.0, 0.0), (0.06, 0.7), (0.6, 0.0)], curve="exp")
    drain = S.fit(S.wet_texture(0.7, r, density=13.0, freq=340.0, spread=2.8,
                                level=0.42), 0.7)
    drain *= S.breakpoints(0.7, [(0.0, 1.0), (0.7, 0.08)])
    out = S.place(S.silence(dur), sag, 0.0)
    out = S.place(out, S.saturate(slump * 0.9, 2.2), 0.60)
    out = S.place(out, spread * 0.6, 0.62)
    out = S.place(out, drain * 0.65, 0.95)
    return _room(S.fit(out, dur), size=0.6, damping=0.8, mix=0.19)


# ===========================================================================
# wing - air moved in PULSES. The beat rate is the family: no other voice
# here repeats at 8-14 Hz. Over it, a formant cry.
# ===========================================================================

def _beats(dur, r, count, rate, level=0.6, decay=0.0, start=0.0, bright=4200.0):
    """Wing beats: a puff of air per beat, each one swept down as the wing
    finishes its stroke."""
    out = S.silence(start + count / rate + 0.15)
    for i in range(count):
        at = start + i / rate
        d = min(0.11, 0.75 / rate)
        puff = S.band_noise(d, r, 250.0, 9000.0, order=3)
        puff = S.lp_sweep(puff, S.expsweep(d, bright, 550.0), order=2)
        puff *= S.breakpoints(d, [(0.0, 0.0), (d * 0.22, 1.0), (d, 0.0)], curve="exp")
        thump = S.sine(d, S.expsweep(d, 150.0, 72.0)) * S.perc_env(d, 0.004, d * 0.3)
        amp = level * (0.8 + 0.2 * float(r.random())) * float(np.exp(-decay * i / count))
        out = S.place(out, S.mix(puff, S.saturate(thump * 0.5, 1.8) * 0.35) * amp, at)
    return out


def _cry(dur, r, f_from, f_to, level=1.0, rasp=0.35):
    """A formant cry: a bright source through three vowel bands. The bands
    move WITH the pitch so the pitch shift the client applies stays sane."""
    src = S.saw(dur, S.expsweep(dur, f_from, f_to), bright=0.9) * 0.6
    src = S.mix(src, S.band_noise(dur, r, 800.0, 9000.0, order=2) * rasp * 0.5)
    y = S.formant(src, [820.0, 1900.0, 3100.0], qs=[7.0, 6.0, 5.0],
                  gains=[1.0, 0.65, 0.35])
    return (y * 0.7 + src * 0.35) * level


@cue("wingIdle")
def wing_idle(r):
    """Three unhurried beats and a short call between them."""
    dur = 0.66
    beats = _beats(0.6, r, 3, 6.5, level=0.55, decay=0.2, bright=3600.0)
    call = _cry(0.16, r, 900.0, 1250.0, level=0.5, rasp=0.25)
    call *= S.breakpoints(0.16, [(0.0, 0.0), (0.03, 1.0), (0.11, 0.8),
                                 (0.16, 0.0)], curve="exp")
    out = S.place(S.silence(dur), S.fit(beats, 0.62), 0.0)
    out = S.place(out, call, 0.20)
    return _room(S.fit(out, dur), size=0.6, damping=0.45, mix=0.19)


@cue("wingAttack")
def wing_attack(r):
    """The stoop: beats accelerating into a dive whoosh, and a shriek that
    arrives with the strike."""
    dur = 0.58
    beats = _beats(0.22, r, 3, 14.0, level=0.7, bright=5200.0)
    dive = S.band_noise(0.24, r, 400.0, 13000.0, order=3)
    dive = S.bp_sweep(dive, S.breakpoints(0.24, [(0.0, 1200.0), (0.14, 4800.0),
                                                 (0.24, 1800.0)], curve="exp"), q=1.7)
    dive *= S.breakpoints(0.24, [(0.0, 0.0), (0.03, 0.6), (0.15, 1.0),
                                 (0.24, 0.0)], curve="exp")
    shriek = _cry(0.22, r, 1500.0, 780.0, level=0.9, rasp=0.55)
    shriek *= S.breakpoints(0.22, [(0.0, 0.0), (0.008, 1.0), (0.14, 0.6),
                                   (0.22, 0.0)], curve="exp")
    out = S.place(S.silence(dur), S.fit(beats, 0.26) * 0.8, 0.0)
    out = S.place(out, dive * 0.75, 0.10)
    out = S.place(out, shriek, 0.19)
    return _room(S.fit(out, dur), size=0.55, damping=0.45, mix=0.17)


@cue("wingHurt")
def wing_hurt(r):
    """A cry clipped off, and feathers scrambling for air."""
    dur = 0.32
    yelp = _cry(0.11, r, 1350.0, 1000.0, level=1.0, rasp=0.5)
    yelp *= S.breakpoints(0.11, [(0.0, 0.0), (0.006, 1.0), (0.11, 0.0)], curve="exp")
    flutter = _beats(0.20, r, 3, 17.0, level=0.45, bright=6000.0)
    y = S.mix(S.fit(yelp, dur), S.fit(flutter, dur) * 0.8)
    return _room(y, size=0.45, damping=0.5, mix=0.15)


@cue("wingDie")
def wing_die(r):
    """The cry falls away, the beats go ragged and stop, and it hits the
    ground - the only thump in this family, and it comes last."""
    dur = 1.70
    fall = _cry(0.62, r, 1250.0, 380.0, level=0.85, rasp=0.6)
    fall = S.vibrato(fall, rate=7.5, depth_cents=70.0)
    fall *= S.breakpoints(0.62, [(0.0, 0.0), (0.02, 1.0), (0.35, 0.55),
                                 (0.62, 0.0)], curve="exp")
    beats = _beats(0.85, r, 7, 8.5, level=0.5, decay=2.2, bright=4200.0)
    land = S.membrane(0.30, 84.0, r, drop=0.5, noise=0.55, tau=0.07, sweep_time=0.016)
    dust = S.band_noise(0.24, r, 700.0, 7000.0, order=2)
    dust *= S.breakpoints(0.24, [(0.0, 0.0), (0.01, 0.6), (0.24, 0.0)], curve="exp")
    out = S.place(S.silence(dur), fall, 0.0)
    out = S.place(out, S.fit(beats, 0.9) * 0.75, 0.02)
    out = S.place(out, S.saturate(land, 2.0) * 0.8, 0.98)
    out = S.place(out, dust * 0.35, 1.0)
    return _room(S.fit(out, dur), size=0.65, damping=0.5, mix=0.19)


# ===========================================================================
# burrower - heard through ground. Everything is muffled: no component in
# this family has energy above ~6 kHz, which is the family's signature.
# ===========================================================================

def _rumble(dur, r, cut_points, level=1.0, drive=2.4):
    y = S.brown(dur, r) * 1.4
    y = S.lp_sweep(y, S.breakpoints(dur, cut_points, curve="exp"), order=2)
    return S.saturate(y, drive) * level


@cue("burrowerIdle")
def burrower_idle(r):
    """Something big under the floor: grit shifting and a low growl that
    never quite becomes a pitch."""
    dur = 0.70
    grit = _clicks(0.6, r, 24, 500.0, 4000.0, level=0.30, spread=0.55, decay=0.8)
    rum = _rumble(0.62, r, [(0.0, 150.0), (0.3, 420.0), (0.62, 130.0)], level=0.8)
    rum *= S.breakpoints(0.62, [(0.0, 0.0), (0.15, 1.0), (0.62, 0.0)], curve="exp")
    growl = S.saw(0.5, S.expsweep(0.5, 74.0, 62.0), bright=0.4) * 0.35
    growl = S.moog(growl, 340.0, res=0.45)
    growl = S.vibrato(growl, rate=9.0, depth_cents=40.0)
    growl *= S.breakpoints(0.5, [(0.0, 0.0), (0.12, 1.0), (0.5, 0.0)], curve="exp")
    y = S.mix(S.fit(grit, dur), S.fit(rum, dur), S.fit(S.saturate(growl, 2.0), dur))
    return _room(S.lowpass(y, 5000.0, order=2), size=0.6, damping=0.8, mix=0.16)


@cue("burrowerAttack")
def burrower_attack(r):
    """It comes up under you: a hard burst of displaced ground and a roar
    that opens as the head clears."""
    dur = 0.62
    burst = S.band_noise(0.20, r, 200.0, 6000.0, order=3)
    burst = S.bp_sweep(burst, S.expsweep(0.20, 700.0, 2600.0), q=1.3)
    burst *= S.breakpoints(0.20, [(0.0, 0.0), (0.006, 1.0), (0.10, 0.45),
                                  (0.20, 0.0)], curve="exp")
    throw = _clicks(0.34, r, 30, 700.0, 5500.0, level=0.36, spread=0.30, decay=1.6)
    roar = S.saw(0.34, S.expsweep(0.34, 88.0, 126.0), bright=0.6) * 0.7
    roar = S.moog(roar, S.expsweep(0.34, 300.0, 1400.0), res=0.55)
    roar = S.saturate(roar, 2.6)
    roar *= S.breakpoints(0.34, [(0.0, 0.0), (0.03, 0.8), (0.22, 1.0),
                                 (0.34, 0.0)], curve="exp")
    heave = _sub(dur, 130.0, 44.0, 0.14, drive=2.8) * 0.85
    out = S.place(S.silence(dur), burst * 0.9, 0.0)
    out = S.place(out, S.fit(throw, 0.36), 0.01)
    out = S.place(out, roar * 0.8, 0.10)
    return _room(S.lowpass(S.mix(S.fit(out, dur), heave), 6000.0, order=2),
                 size=0.6, damping=0.75, mix=0.15)


@cue("burrowerHurt")
def burrower_hurt(r):
    """A grunt with the ground still on it - muffled, short, no top end."""
    dur = 0.30
    grunt = S.saw(0.14, S.expsweep(0.14, 132.0, 84.0), bright=0.5) * 0.8
    grunt = S.moog(grunt, S.expsweep(0.14, 900.0, 300.0), res=0.5)
    grunt = S.saturate(grunt, 2.6)
    grunt *= S.perc_env(0.14, 0.003, 0.038)
    grit = _clicks(0.22, r, 14, 400.0, 3600.0, level=0.32, spread=0.18, decay=1.6)
    y = S.mix(S.fit(grunt, dur), S.fit(grit, dur))
    return _room(S.lowpass(y, 4200.0, order=2), size=0.5, damping=0.8, mix=0.13)


@cue("burrowerDie")
def burrower_die(r):
    """The growl runs out of air, the body drops, and the hole it made
    falls in on top of it."""
    dur = 1.80
    growl = S.saw(0.75, S.expsweep(0.75, 110.0, 48.0), bright=0.5) * 0.8
    growl = S.moog(growl, S.breakpoints(0.75, [(0.0, 1100.0), (0.4, 420.0),
                                               (0.75, 180.0)], curve="exp"), res=0.5)
    growl = S.vibrato(growl, rate=5.0, depth_cents=60.0)
    growl = S.saturate(growl, 2.6)
    growl *= S.breakpoints(0.75, [(0.0, 0.0), (0.02, 1.0), (0.42, 0.5),
                                  (0.75, 0.0)], curve="exp")
    drop = S.membrane(0.38, 56.0, r, drop=0.4, noise=0.35, tau=0.12, sweep_time=0.026)
    collapse = _clicks(0.75, r, 34, 350.0, 4200.0, level=0.34, spread=0.65, decay=2.0)
    fill = _rumble(0.7, r, [(0.0, 500.0), (0.25, 260.0), (0.7, 110.0)], level=0.55)
    fill *= S.breakpoints(0.7, [(0.0, 0.0), (0.08, 1.0), (0.7, 0.0)], curve="exp")
    out = S.place(S.silence(dur), growl * 0.85, 0.0)
    out = S.place(out, S.saturate(drop, 2.2) * 0.8, 0.70)
    out = S.place(out, S.fit(collapse, 0.8), 0.78)
    out = S.place(out, fill, 0.80)
    return _room(S.lowpass(S.fit(out, dur), 5200.0, order=2), size=0.7,
                 damping=0.8, mix=0.18)


# ===========================================================================
# mimic - furniture until it isn't. A comb-filtered stick-slip creak
# (the lid), then struck wood (the snap). The creak IS the tell.
# ===========================================================================

def _creak(dur, r, pitch, accel=1.0, level=0.6, low=400.0, high=4200.0):
    """Stick-slip: short noise events through a tuned comb, so every slip
    rings at the body's pitch. `accel` > 1 slows the slips down."""
    ticks = S.silence(dur)
    at = 0.0
    gap = 0.010
    # `accel < 1` speeds the slips UP, and a bare `gap *= accel` loop then
    # converges on a time short of `dur` and never terminates - the gap
    # floor is what makes an accelerating creak finite.
    while at < dur - 0.03:
        g = S.band_noise(0.004, r, low, high, order=2) * S.perc_env(0.004, 0.0003, 0.0014)
        ticks = S.place(ticks, g * (0.35 + 0.65 * float(r.random())), at)
        at += gap
        gap = min(0.09, max(0.0035, gap * accel))
    ticks = S.fit(ticks, dur)
    ring = S.comb(ticks, 1.0 / pitch, feedback=0.90, damp=0.45)
    ring = S.bandpass(ring, pitch * 0.6, 5200.0, order=2)
    return ring / (np.max(np.abs(ring)) + 1e-12) * level


@cue("mimicIdle")
def mimic_idle(r):
    """The lid settling a fraction: one small creak that stops itself. It
    should sound like furniture, right up until it doesn't."""
    dur = 0.55
    cr = _creak(0.34, r, 190.0, accel=1.09, level=0.85)
    cr *= S.breakpoints(0.34, [(0.0, 0.0), (0.05, 1.0), (0.26, 0.6),
                               (0.34, 0.0)], curve="exp")
    knock = _bar(0.16, 210.0, r, decay=0.05, strike=0.35) * 0.30
    out = S.place(S.silence(dur), S.fit(cr, 0.36), 0.0)
    out = S.place(out, S.fit(knock, 0.18), 0.36)
    return _room(S.fit(out, dur), size=0.4, damping=0.6, mix=0.14)


@cue("mimicAttack")
def mimic_attack(r):
    """The reveal: the creak accelerates as the lid comes up, then the jaw
    SLAMS - struck wood, a shell plate ringing, and a thud of the whole
    box behind it."""
    dur = 0.58
    cr = _creak(0.24, r, 175.0, accel=0.94, level=0.9)
    cr *= S.breakpoints(0.24, [(0.0, 0.0), (0.03, 0.8), (0.22, 1.0),
                               (0.24, 0.4)], curve="exp")
    hit = S.fit(S.white(0.006, r) * S.perc_env(0.006, 0.00008, 0.0018), 0.30)
    wood = np.zeros(S.n(0.30))
    for i, f in enumerate((240.0, 470.0, 830.0, 1420.0)):
        wood += S.resonator(hit, f, q=17.0) / (i + 1.25)
    wood *= S.expdec(0.30, 0.042)
    box = S.membrane(0.20, 108.0, r, drop=0.45, noise=0.22, tau=0.05, sweep_time=0.012)
    out = S.place(S.silence(dur), cr * 0.8, 0.0)
    out = S.place(out, S.mix(hit * 0.7, wood), 0.245)
    out = S.place(out, S.saturate(box, 2.2) * 0.7, 0.246)
    return _room(S.fit(out, dur), size=0.45, damping=0.55, mix=0.15)


@cue("mimicHurt")
def mimic_hurt(r):
    """Timber cracking: a split down the grain and the hinges complaining."""
    dur = 0.34
    split = S.band_noise(0.008, r, 400.0, 9000.0) * S.perc_env(0.008, 0.0001, 0.0022)
    split = S.fit(split, 0.24)
    grain = np.zeros(S.n(0.24))
    for i, f in enumerate((330.0, 690.0, 1240.0)):
        grain += S.resonator(grain * 0 + split, f, q=13.0) / (i + 1.3)
    grain *= S.expdec(0.24, 0.030)
    cr = _creak(0.18, r, 240.0, accel=1.12, level=0.5)
    y = S.mix(S.fit(S.mix(split * 0.7, grain), dur), S.fit(cr, dur) * 0.7)
    return _room(y, size=0.4, damping=0.55, mix=0.13)


@cue("mimicDie")
def mimic_die(r):
    """It comes apart: the box splits, the boards clatter down, the lid
    drops last and rocks twice on the floor."""
    dur = 1.65
    hit = S.fit(S.white(0.007, r) * S.perc_env(0.007, 0.00008, 0.0022), 0.45)
    burst = np.zeros(S.n(0.45))
    for i, f in enumerate((190.0, 400.0, 720.0, 1180.0, 2050.0)):
        burst += S.resonator(hit, f, q=14.0) / (i + 1.2)
    burst *= S.expdec(0.45, 0.075)
    boards = S.silence(dur)
    for at, f, amp in ((0.16, 300.0, 0.55), (0.29, 210.0, 0.45), (0.47, 380.0, 0.35),
                       (0.66, 260.0, 0.28)):
        boards = S.place(boards, _bar(0.22, f, r, decay=0.06, strike=0.6) * amp, at)
    lid = _bar(0.30, 165.0, r, decay=0.09, strike=0.7) * 0.5
    rock = S.silence(dur)
    for at, amp in ((0.98, 0.45), (1.14, 0.28), (1.26, 0.16)):
        rock = S.place(rock, _bar(0.16, 178.0, r, decay=0.04, strike=0.4) * amp, at)
    creak = _creak(0.35, r, 150.0, accel=1.16, level=0.4)
    out = S.place(S.silence(dur), S.mix(hit * 0.7, burst), 0.0)
    out = S.place(out, boards, 0.0)
    out = S.place(out, S.fit(lid, 0.32), 0.90)
    out = S.place(out, rock, 0.0)
    out = S.place(out, S.fit(creak, 0.36), 0.55)
    return _room(S.fit(out, dur), size=0.5, damping=0.55, mix=0.17)


# ===========================================================================
# undead - the drowned crew. Formant vowels over a detuned saw, with water
# in the throat and bone hardware hanging off them.
# ===========================================================================

def _voice(dur, freq, r, vowel=(400.0, 900.0, 2400.0), level=1.0, rasp=0.5,
           detune=0.012):
    """A drowned throat: two saws beating against each other through vowel
    formants. The detune is what makes it dead rather than sung."""
    src = S.supersaw(dur, freq, voices=3, detune=detune, phase_seed=r) * 0.7
    src = S.mix(src, S.band_noise(dur, r, 200.0, 5000.0, order=2) * rasp * 0.4)
    y = S.formant(src, list(vowel), qs=[8.0, 7.0, 5.0], gains=[1.0, 0.6, 0.28])
    return (y * 0.8 + src * 0.25) * level


def _gurgle(dur, r, level=0.5, density=22.0):
    g = S.fit(S.wet_texture(dur, r, density=density, freq=260.0, spread=2.4,
                            level=0.6), dur)
    return S.lowpass(g, 1600.0, order=2) * level


def _bones(dur, r, count, level=0.4, spread=None, start=0.0, decay=1.0):
    return _clicks(dur, r, count, 700.0, 6000.0, level=level, spread=spread,
                   start=start, decay=decay, tuned=980.0, q=12.0)


@cue("undeadIdle")
def undead_idle(r):
    """A groan with water in it, and something bony moving as it turns."""
    dur = 0.72
    gr = _voice(0.55, 92.0, r, vowel=(360.0, 780.0, 2300.0), level=0.85, rasp=0.55)
    gr = S.vibrato(gr, rate=3.6, depth_cents=45.0)
    gr *= S.breakpoints(0.55, [(0.0, 0.0), (0.10, 1.0), (0.36, 0.6),
                               (0.55, 0.0)], curve="exp")
    gur = _gurgle(0.34, r, level=0.45, density=18.0)
    bn = _bones(0.30, r, 5, level=0.28, spread=0.24, decay=1.0)
    out = S.place(S.silence(dur), gr, 0.0)
    out = S.place(out, S.fit(gur, 0.34), 0.24)
    out = S.place(out, S.fit(bn, 0.32), 0.36)
    return _room(S.lowpass(S.fit(out, dur), 7000.0, order=2), size=0.75,
                 damping=0.6, mix=0.24)


@cue("undeadAttack")
def undead_attack(r):
    """A shout it cannot finish: the vowel opens hard, the water comes up
    with it, and iron swings through on the end."""
    dur = 0.58
    shout = _voice(0.30, 118.0, r, vowel=(620.0, 1200.0, 2700.0), level=1.0,
                   rasp=0.65, detune=0.016)
    shout *= S.breakpoints(0.30, [(0.0, 0.0), (0.012, 1.0), (0.20, 0.65),
                                  (0.30, 0.0)], curve="exp")
    gur = _gurgle(0.22, r, level=0.55, density=40.0)
    iron = S.metal_hit(0.30, r, 620.0, ring=0.35, roughness=0.7) * 0.45
    swing = S.band_noise(0.14, r, 600.0, 8000.0, order=3)
    swing = S.bp_sweep(swing, S.expsweep(0.14, 1400.0, 3600.0), q=2.0)
    swing *= S.breakpoints(0.14, [(0.0, 0.0), (0.02, 1.0), (0.14, 0.0)], curve="exp")
    out = S.place(S.silence(dur), shout, 0.0)
    out = S.place(out, S.fit(gur, 0.22) * 0.7, 0.02)
    out = S.place(out, swing * 0.5, 0.22)
    out = S.place(out, S.fit(iron, 0.32), 0.30)
    return _room(S.fit(out, dur), size=0.7, damping=0.6, mix=0.21)


@cue("undeadHurt")
def undead_hurt(r):
    """A wet grunt and the bones taking the hit."""
    dur = 0.34
    grunt = _voice(0.14, 104.0, r, vowel=(480.0, 1000.0, 2500.0), level=0.9, rasp=0.6)
    grunt *= S.perc_env(0.14, 0.003, 0.040)
    gur = _gurgle(0.18, r, level=0.5, density=34.0)
    bn = _bones(0.24, r, 8, level=0.4, spread=0.16, decay=2.0)
    y = S.mix(S.fit(grunt, dur), S.fit(gur, dur) * 0.7, S.fit(bn, dur))
    return _room(y, size=0.55, damping=0.6, mix=0.18)


@cue("undeadDie")
def undead_die(r):
    """It goes down for the second time: the groan slides off pitch, the
    water finally wins, and the bones and iron land after the voice has
    already stopped."""
    dur = 1.70
    groan = _voice(1.00, 96.0, r, vowel=(340.0, 760.0, 2200.0), level=0.9, rasp=0.6)
    groan = S.vibrato(groan, rate=3.0, depth_cents=90.0)
    slide = S.breakpoints(1.00, [(0.0, 0.0), (0.03, 1.0), (0.5, 0.6),
                                 (1.00, 0.0)], curve="exp")
    groan = groan * slide
    sink = _voice(0.55, 68.0, r, vowel=(300.0, 640.0, 1900.0), level=0.55, rasp=0.5)
    sink *= S.breakpoints(0.55, [(0.0, 0.0), (0.15, 1.0), (0.55, 0.0)], curve="exp")
    gur = _gurgle(0.85, r, level=0.55, density=16.0)
    gur = S.fit(gur, 0.85) * S.breakpoints(0.85, [(0.0, 0.3), (0.45, 1.0), (0.85, 0.1)])
    bn = _bones(0.7, r, 12, level=0.42, spread=0.5, decay=2.2)
    iron = S.metal_hit(0.5, r, 380.0, ring=0.4, roughness=0.6) * 0.35
    out = S.place(S.silence(dur), groan, 0.0)
    out = S.place(out, sink, 0.62)
    out = S.place(out, gur * 0.8, 0.45)
    out = S.place(out, S.fit(bn, 0.75), 1.05)
    out = S.place(out, S.fit(iron, 0.52), 1.22)
    return _room(S.lowpass(S.fit(out, dur), 7500.0, order=2), size=0.66,
                 damping=0.65, mix=0.24)


# ===========================================================================
# elemental - no flesh. Crackle grains around a detuned tonal core; the
# core is the only pitch in the family and it never has an attack.
# ===========================================================================

def _element_core(dur, freq, r, level=1.0, detune=0.9):
    a = S.sine(dur, freq) * 0.5
    b = S.sine(dur, freq * (1.0 + detune * 0.004)) * 0.4
    c = S.sine(dur, freq * 2.02) * 0.18
    y = S.mix(a, b, c)
    return S.saturate(y, 1.7) * level


def _element_grains(dur, r, count, level=0.5, spread=None, start=0.0, decay=0.0,
                    low=1500.0, high=13000.0):
    return _clicks(dur, r, count, low, high, level=level, spread=spread,
                   start=start, decay=decay)


@cue("elementalIdle")
def elemental_idle(r):
    """It burns / freezes / charges in place: crackle grains over a core
    that beats slowly against itself."""
    dur = 0.66
    core = _element_core(0.6, 176.0, r, level=0.55)
    core *= S.breakpoints(0.6, [(0.0, 0.0), (0.15, 1.0), (0.45, 0.75),
                                (0.6, 0.0)], curve="exp")
    grains = _element_grains(0.6, r, 26, level=0.36, spread=0.55, decay=0.4)
    air = S.band_noise(0.55, r, 2000.0, 11000.0, order=2) * 0.14
    air *= S.breakpoints(0.55, [(0.0, 0.0), (0.2, 1.0), (0.55, 0.0)])
    y = S.mix(S.fit(core, dur), S.fit(grains, dur), S.fit(air, dur))
    return _room(y, size=0.65, damping=0.4, mix=0.21)


@cue("elementalAttack")
def elemental_attack(r):
    """It throws its element: a rush of grains, the core jumping an octave
    and opening, and a discharge crack at the top of the rise."""
    dur = 0.56
    rush = S.band_noise(0.22, r, 700.0, 14000.0, order=3)
    rush = S.bp_sweep(rush, S.expsweep(0.22, 1600.0, 6500.0), q=1.6)
    rush *= S.breakpoints(0.22, [(0.0, 0.0), (0.02, 0.7), (0.19, 1.0),
                                 (0.22, 0.2)], curve="exp")
    core = _element_core(0.34, 220.0, r, level=0.8)
    core = core * S.breakpoints(0.34, [(0.0, 0.0), (0.03, 0.6), (0.20, 1.0),
                                       (0.34, 0.0)], curve="exp")
    core = S.mix(core, S.sine(0.34, S.expsweep(0.34, 220.0, 440.0)) *
                 S.breakpoints(0.34, [(0.0, 0.0), (0.20, 0.8), (0.34, 0.0)],
                               curve="exp") * 0.35)
    crack = S.white(0.03, r)
    crack = S.svf(crack, S.expsweep(0.03, 4200.0, 1800.0), q=7.0, mode="band")
    crack *= S.perc_env(0.03, 0.0002, 0.005, curve=1.4)
    grains = _element_grains(0.38, r, 30, level=0.40, spread=0.32, decay=1.4,
                             start=0.0)
    out = S.place(S.silence(dur), rush * 0.75, 0.0)
    out = S.place(out, core, 0.0)
    out = S.place(out, crack * 0.9, 0.205)
    out = S.place(out, S.fit(grains, 0.40), 0.20)
    return _room(S.fit(out, dur), size=0.6, damping=0.4, mix=0.19)


@cue("elementalHurt")
def elemental_hurt(r):
    """The core destabilises: a fast detune wobble and a spit of grains."""
    dur = 0.32
    core = _element_core(0.20, 200.0, r, level=0.9, detune=3.5)
    core = S.vibrato(core, rate=22.0, depth_cents=90.0)
    core *= S.breakpoints(0.20, [(0.0, 0.0), (0.008, 1.0), (0.20, 0.0)], curve="exp")
    spit = _element_grains(0.22, r, 18, level=0.42, spread=0.15, decay=2.0)
    hiss = S.band_noise(0.14, r, 2500.0, 12000.0, order=2) * 0.22
    hiss *= S.breakpoints(0.14, [(0.0, 0.0), (0.006, 1.0), (0.14, 0.0)], curve="exp")
    y = S.mix(S.fit(core, dur), S.fit(spit, dur), S.fit(hiss, dur))
    return _room(y, size=0.5, damping=0.4, mix=0.18)


@cue("elementalDie")
def elemental_die(r):
    """The core collapses: pitch falls away, the crackle flares as whatever
    held it together lets go, and embers tick out into silence."""
    dur = 1.85
    core = S.sine(0.95, S.expsweep(0.95, 200.0, 46.0)) * 0.6
    core = S.mix(core, S.sine(0.95, S.expsweep(0.95, 302.0, 69.0)) * 0.3)
    core = S.vibrato(core, rate=6.0, depth_cents=60.0)
    core = S.saturate(core, 2.2)
    core *= S.breakpoints(0.95, [(0.0, 0.0), (0.02, 1.0), (0.5, 0.5),
                                 (0.95, 0.0)], curve="exp")
    flare = S.band_noise(0.30, r, 900.0, 14000.0, order=3)
    flare = S.lp_sweep(flare, S.expsweep(0.30, 12000.0, 1400.0), order=2)
    flare *= S.breakpoints(0.30, [(0.0, 0.0), (0.006, 1.0), (0.30, 0.0)], curve="exp")
    grains = _element_grains(1.30, r, 40, level=0.36, spread=1.15, decay=2.6)
    embers = _element_grains(0.55, r, 8, level=0.20, spread=0.45, decay=1.4,
                             low=3000.0, high=15000.0)
    out = S.place(S.silence(dur), core * 0.9, 0.0)
    out = S.place(out, flare * 0.7, 0.0)
    out = S.place(out, S.fit(grains, 1.35), 0.02)
    out = S.place(out, S.fit(embers, 0.6), 1.20)
    return _room(S.fit(out, dur), size=0.8, damping=0.4, mix=0.24)


# ===========================================================================
# mechanical - Wrack's ship animated. Iron resonators, a powder fizz and a
# ratchet. Nothing in this family is organic, and nothing here is wet.
# ===========================================================================

def _ratchet(dur, r, rate_from, rate_to, level=0.5, pitch=210.0):
    """A pawl over a toothed wheel: evenly-spaced ticks (the ONE family
    allowed to be even) rung through a comb at the wheel's pitch."""
    ticks = S.silence(dur)
    at = 0.0
    i = 0
    while at < dur - 0.02:
        g = S.band_noise(0.004, r, 1500.0, 9000.0, order=2) * S.perc_env(0.004, 0.0002, 0.0012)
        ticks = S.place(ticks, g * (0.6 + 0.4 * float(r.random())), at)
        frac = at / max(1e-3, dur)
        at += 1.0 / (rate_from + (rate_to - rate_from) * frac)
        i += 1
    ticks = S.fit(ticks, dur)
    y = S.comb(ticks, 1.0 / pitch, feedback=0.78, damp=0.18)
    y = S.bandpass(y, 200.0, 11000.0, order=2)
    return y / (np.max(np.abs(y)) + 1e-12) * level


@cue("mechanicalIdle")
def mechanical_idle(r):
    """It winds itself: a ratchet turn and one loose iron plate settling."""
    dur = 0.60
    rt = _ratchet(0.32, r, 26.0, 15.0, level=0.75, pitch=230.0)
    rt *= S.breakpoints(0.32, [(0.0, 0.0), (0.02, 1.0), (0.32, 0.3)])
    clank = S.metal_hit(0.30, r, 420.0, ring=0.35, roughness=0.6) * 0.45
    hum = S.sine(0.4, 118.0) * 0.12 + S.sine(0.4, 236.0) * 0.05
    hum *= S.breakpoints(0.4, [(0.0, 0.0), (0.12, 1.0), (0.4, 0.0)])
    out = S.place(S.silence(dur), rt, 0.0)
    out = S.place(out, S.fit(clank, 0.32), 0.33)
    out = S.place(out, S.saturate(hum, 1.6), 0.05)
    return _room(S.fit(out, dur), size=0.5, damping=0.35, mix=0.18)


@cue("mechanicalAttack")
def mechanical_attack(r):
    """It swings: iron through air, a heavy clank on the end of it, and a
    fuse fizzing where the powder is."""
    dur = 0.58
    swing = S.band_noise(0.16, r, 400.0, 9000.0, order=3)
    swing = S.bp_sweep(swing, S.expsweep(0.16, 900.0, 3200.0), q=2.2)
    swing *= S.breakpoints(0.16, [(0.0, 0.0), (0.02, 1.0), (0.16, 0.0)], curve="exp")
    clank = S.metal_hit(0.40, r, 300.0, ring=0.55, roughness=0.75)
    ham = S.membrane(0.16, 120.0, r, drop=0.4, noise=0.20, tau=0.04, sweep_time=0.010)
    fizz = S.band_noise(0.26, r, 3000.0, 14000.0, order=2)
    fizz = S.bp_sweep(fizz, S.expsweep(0.26, 6000.0, 9000.0), q=1.5)
    fizz *= S.breakpoints(0.26, [(0.0, 0.0), (0.04, 0.55), (0.26, 0.0)])
    out = S.place(S.silence(dur), swing * 0.6, 0.0)
    out = S.place(out, S.fit(clank, 0.42) * 0.95, 0.155)
    out = S.place(out, S.saturate(ham, 2.4) * 0.7, 0.156)
    out = S.place(out, fizz * 0.35, 0.20)
    return _room(S.fit(out, dur), size=0.55, damping=0.35, mix=0.18)


@cue("mechanicalHurt")
def mechanical_hurt(r):
    """A dull iron hit and something inside coming loose."""
    dur = 0.34
    hit = S.metal_hit(0.26, r, 250.0, ring=0.25, roughness=0.9) * 0.9
    loose = _clicks(0.24, r, 9, 900.0, 8000.0, level=0.4, spread=0.18, decay=1.8,
                    tuned=1450.0, q=20.0)
    thud = S.membrane(0.14, 96.0, r, drop=0.45, noise=0.15, tau=0.035)
    y = S.mix(S.fit(hit, dur), S.fit(loose, dur), S.fit(S.saturate(thud, 2.2), dur) * 0.5)
    return _room(y, size=0.45, damping=0.4, mix=0.15)


@cue("mechanicalDie")
def mechanical_die(r):
    """It comes to pieces: the mainspring lets go (a ratchet running away
    with itself), then the iron falls, and one plate rings on longest."""
    dur = 1.85
    burst = S.metal_hit(0.5, r, 210.0, ring=0.6, roughness=0.85)
    spring = _ratchet(0.55, r, 14.0, 62.0, level=0.6, pitch=340.0)
    spring *= S.breakpoints(0.55, [(0.0, 0.0), (0.03, 1.0), (0.45, 0.5),
                                   (0.55, 0.0)], curve="exp")
    fall = S.silence(dur)
    for at, f, amp in ((0.30, 520.0, 0.5), (0.46, 340.0, 0.42), (0.63, 780.0, 0.32),
                       (0.86, 260.0, 0.30), (1.08, 610.0, 0.22)):
        fall = S.place(fall, S.metal_hit(0.30, r, f, ring=0.35, roughness=0.7) * amp, at)
    ring = S.metal_hit(0.9, r, 176.0, ring=0.9, roughness=0.4) * 0.35
    steam = S.band_noise(0.45, r, 1800.0, 11000.0, order=2) * 0.16
    steam *= S.breakpoints(0.45, [(0.0, 0.0), (0.05, 1.0), (0.45, 0.0)], curve="exp")
    out = S.place(S.silence(dur), S.fit(burst, 0.52) * 0.9, 0.0)
    out = S.place(out, spring, 0.02)
    out = S.place(out, fall, 0.0)
    out = S.place(out, S.fit(ring, 0.92), 0.88)
    out = S.place(out, steam, 0.55)
    return _room(S.fit(out, dur), size=0.6, damping=0.35, mix=0.20)


# ===========================================================================
# flora - rooted and rubbery. A resonant tone STRETCHING up under tension,
# a wet pop when it lets go, and sap in everything.
# ===========================================================================

def _stretch(dur, f_from, f_to, r, level=1.0, q=9.0):
    """Rubber under tension: filtered noise plus a resonant tone, both
    climbing. The climb is the tension; where it stops is where it tears."""
    src = S.band_noise(dur, r, 200.0, 6000.0, order=2)
    cen = S.expsweep(dur, f_from, f_to)
    y = S.svf(src, cen, q=q, mode="band") * 0.8
    tone = S.sine(dur, cen * 0.5) * 0.35 + S.sine(dur, cen * 1.01) * 0.15
    y = S.mix(y, tone)
    return y * level


@cue("floraIdle")
def flora_idle(r):
    """It leans: a slow rubbery stretch with sap moving inside it, and a
    small creak at the root."""
    dur = 0.62
    st = _stretch(0.46, 320.0, 620.0, r, level=0.8, q=8.0)
    st *= S.breakpoints(0.46, [(0.0, 0.0), (0.12, 1.0), (0.36, 0.7),
                               (0.46, 0.0)], curve="exp")
    sap = S.fit(S.wet_texture(0.4, r, density=10.0, freq=440.0, spread=2.2,
                              level=0.28), 0.4)
    root = _bar(0.18, 148.0, r, decay=0.05, strike=0.3) * 0.28
    out = S.place(S.silence(dur), S.fit(st, 0.48), 0.0)
    out = S.place(out, sap * 0.7, 0.10)
    out = S.place(out, S.fit(root, 0.20), 0.42)
    return _room(S.fit(out, dur), size=0.5, damping=0.65, mix=0.16)


@cue("floraAttack")
def flora_attack(r):
    """It lashes: the stretch winds up fast, releases with a wet whip, and
    the vine snaps back with a rubbery pop."""
    dur = 0.52
    wind = _stretch(0.18, 380.0, 1300.0, r, level=0.9, q=10.0)
    wind *= S.breakpoints(0.18, [(0.0, 0.0), (0.03, 0.7), (0.16, 1.0),
                                 (0.18, 0.5)], curve="exp")
    whip = S.band_noise(0.09, r, 700.0, 11000.0, order=3)
    whip = S.bp_sweep(whip, S.expsweep(0.09, 2200.0, 5600.0), q=2.2)
    whip *= S.breakpoints(0.09, [(0.0, 0.0), (0.008, 1.0), (0.09, 0.0)], curve="exp")
    pop = S.sine(0.05, S.expsweep(0.05, 700.0, 220.0)) * S.perc_env(0.05, 0.0005, 0.012)
    pop = S.mix(pop, S.bubble(0.045, 340.0, r, rise=2.2) * 0.5)
    wet = S.band_noise(0.08, r, 400.0, 5000.0, order=2)
    wet = S.lp_sweep(wet, S.expsweep(0.08, 4200.0, 600.0), order=2)
    wet *= S.perc_env(0.08, 0.0008, 0.014, curve=1.3)
    out = S.place(S.silence(dur), wind * 0.8, 0.0)
    out = S.place(out, whip * 0.85, 0.175)
    out = S.place(out, S.fit(pop, 0.06) * 0.8, 0.185)
    out = S.place(out, wet * 0.55, 0.19)
    return _room(S.fit(out, dur), size=0.5, damping=0.6, mix=0.16)


@cue("floraHurt")
def flora_hurt(r):
    """A fibre tears and sap comes out under pressure."""
    dur = 0.30
    tear = S.band_noise(0.10, r, 600.0, 9000.0, order=3)
    tear = S.bp_sweep(tear, S.breakpoints(0.10, [(0.0, 3600.0), (0.10, 1100.0)],
                                          curve="exp"), q=2.6)
    tear *= S.breakpoints(0.10, [(0.0, 0.0), (0.006, 1.0), (0.10, 0.0)], curve="exp")
    pop = S.bubble(0.05, 420.0, r, rise=2.6) * 0.6
    sap = S.fit(S.wet_texture(0.16, r, density=24.0, freq=620.0, spread=2.0,
                              level=0.4), 0.16)
    y = S.mix(S.fit(tear, dur) * 0.9, S.fit(pop, dur), S.fit(sap, dur) * 0.6)
    return _room(y, size=0.42, damping=0.65, mix=0.14)


@cue("floraDie")
def flora_die(r):
    """The stalk gives: a long rip down the fibres, the stretch falling
    instead of rising, the mass coming down, and sap draining after."""
    dur = 1.75
    rip = S.band_noise(0.45, r, 400.0, 10000.0, order=3)
    rip = S.bp_sweep(rip, S.breakpoints(0.45, [(0.0, 4200.0), (0.15, 2400.0),
                                               (0.45, 700.0)], curve="exp"), q=2.0)
    rip *= S.breakpoints(0.45, [(0.0, 0.0), (0.008, 1.0), (0.24, 0.45),
                                (0.45, 0.0)], curve="exp")
    sag = _stretch(0.7, 900.0, 190.0, r, level=0.6, q=7.0)
    sag *= S.breakpoints(0.7, [(0.0, 0.0), (0.06, 1.0), (0.7, 0.0)], curve="exp")
    fall = S.membrane(0.34, 74.0, r, drop=0.45, noise=0.45, tau=0.10, sweep_time=0.022)
    rustle = _clicks(0.55, r, 22, 1200.0, 9000.0, level=0.26, spread=0.45, decay=1.8)
    drain = S.fit(S.wet_texture(0.6, r, density=12.0, freq=380.0, spread=2.6,
                                level=0.36), 0.6)
    drain *= S.breakpoints(0.6, [(0.0, 1.0), (0.6, 0.1)])
    out = S.place(S.silence(dur), rip * 0.85, 0.0)
    out = S.place(out, sag, 0.05)
    out = S.place(out, S.saturate(fall, 2.0) * 0.75, 0.72)
    out = S.place(out, S.fit(rustle, 0.6), 0.70)
    out = S.place(out, drain * 0.6, 1.02)
    return _room(S.fit(out, dur), size=0.6, damping=0.7, mix=0.19)
