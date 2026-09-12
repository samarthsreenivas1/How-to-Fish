"""sfx_boss_shared.py - the shared boss vocabulary, in the NEUTRAL voice.

Fifteen cues that every boss can fall back on. Each of the seven bosses
overrides seven of them (`bossTell__pyrelisk` and friends, on the boss's own
sheet); what lives here is the generic version a creature with no voice - or
a boss whose variant is missing - gets instead.

WHAT MAKES A BOSS CUE DIFFERENT FROM A CREATURE CUE. Three things, and they
are all about SIZE:

1. THE SUB IS A SEPARATE LAYER. A big hit is not a small hit turned up; it
   is a sine at 30-60 Hz that sweeps DOWN and is saturated until it has
   harmonics of its own (`_sub`). Saturation is what lets a laptop speaker
   with no response under 150 Hz still hear the weight, because the
   distortion products land where the speaker can reproduce them.
2. THE CRACK ARRIVES FIRST. Anything enormous landing is CRACK -> BOOM, a
   few milliseconds apart (`_crack` placed ahead of `_sub`). One flat wall
   of low end reads as a mix problem; the split reads as mass.
3. THE ROOM IS BIG AND SLOW. `_room` here is an outdoor arena, not the
   dock: RT ~1.3 s, lightly damped, with predelay so the direct sound is
   still the first thing heard.

TELEGRAPHS. `bossTell`, `bossStance` and `bossSweep` are heard BEFORE the
blow and are what the player reads, so they RISE - in pitch, in level, or
in both - and they have no big transient competing with the news. A
telegraph with a hard attack reads as the hit having already landed.
"""

import numpy as np

import synth as S
from cues import cue


# ---------------------------------------------------------------------------
# the arena and the three layers
# ---------------------------------------------------------------------------

# build.py puts a 3 ms fade on the HEAD of every cue as click insurance.
# A cue whose loudest sample is a hard transient at t=0 therefore loses its
# own peak to that fade: it comes out several dB under -1 dBFS, and the
# attack the whole cue is built around is the part that got shaved. Four
# milliseconds of silence in front of every one-shot puts the transient
# clear of the fade. Four ms is below the ear's ability to hear a delay and
# is not enough sprite length to matter; the alternative - authoring every
# transient 4 ms late by hand - is the same thing done less reliably.
HEAD_LEAD = 0.004


def _room(x, size=1.3, damping=0.42, mix=0.26, predelay=0.012, tail=True,
          cap=None):
    """The generic boss arena: big, stony, outdoors, a little bright.

    `tail=False` for a loop cue - a reverb tail hanging off the end makes
    the file longer than the loop it was authored as.

    `cap` is the OTHER half of that problem, and it matters on a sprite
    sheet. build.py trims trailing silence at -62 dBFS, which is so far
    down that a big room's tail survives for seconds; a 0.8 s telegraph
    with a 1.9 s room becomes a 2.7 s sprite, and the client's fade-out
    lands in the middle of it. `cap` sets the cue's real length and rolls
    the tail off over its last third, so the room is as big as it sounds
    and the sprite is as long as it needs to be.
    """
    # ONE INFRASONIC HIGH-PASS FOR THE WHOLE SHEET. Layered saturated subs
    # and brown-noise rumbles put real energy under 20 Hz, where no speaker
    # a player owns reproduces anything - but build.py peak-normalises every
    # cue, so that energy is paid for by turning the AUDIBLE part down. A
    # 26 Hz high-pass here is the difference between a slam that measures
    # big and a slam that sounds big.
    x = S.highpass(x, 26.0, order=2)
    y = S.reverb(x, size=size, damping=damping, mix=mix, predelay=predelay,
                 seed=57, tail=tail)
    if cap is None:
        return y
    y = np.concatenate([np.zeros(S.n(HEAD_LEAD)), y])
    cap = cap + HEAD_LEAD
    y = S.fit(y, cap)
    return y * S.breakpoints(cap, [(0.0, 1.0), (cap * 0.64, 1.0), (cap, 0.0)],
                             curve="exp")


def _lvl(x, amp):
    """Scale a layer to a known PEAK before mixing.

    Layers here come out of very different generators - `membrane` peaks
    near 1, `formant` at whatever three resonators happened to sum to, a
    saturated sine at ~0.95 - so a bare multiplier is not a balance, it is
    a guess. Normalising first makes every weight in a `mix` below mean the
    same thing, which is the only way a cue's low/mid split stays where it
    was put when one of its layers is retuned.
    """
    peak = float(np.max(np.abs(x))) if len(x) else 0.0
    return x * (amp / peak) if peak > 1e-9 else x


def _sub(dur, f0, f1, tau=None, drive=2.4, attack=0.002):
    """The weight layer: a saturated sine falling from f0 to f1."""
    if tau is None:
        tau = float(dur) * 0.34
    y = S.sine(dur, S.expsweep(dur, f0, f1)) * S.perc_env(dur, attack, tau)
    return S.saturate(y, drive)


def _crack(dur, r, low=900.0, high=11000.0, tau=0.020, sweep=True):
    """The transient layer: a noise spit through a fast-closing filter."""
    x = S.band_noise(dur, r, low, high, order=3)
    if sweep:
        x = S.lp_sweep(x, S.expsweep(dur, high, max(400.0, low * 0.45)), order=2)
    return x * S.perc_env(dur, 0.0004, tau, curve=1.2)


def _body(dur, r, freq, drive=2.0, noise=0.3, drop=0.5, tau=None):
    """The middle layer: a struck mass. Membrane, saturated for guts."""
    y = S.membrane(dur, freq, r, drop=drop, noise=noise, tau=tau)
    return S.saturate(y, drive)


def _debris(r, count=9, spread=0.5, start=0.05, level=0.30, freq=280.0,
            grain=0.09):
    """Rock and shell coming back down - the tail of anything that shatters."""
    out = S.silence(start + spread + grain + 0.05)
    for _ in range(count):
        at = start + float(r.random()) * spread
        f = freq * float(2.0 ** (r.random() * 1.8 - 0.9))
        one = S.mix(S.bar(grain, f, r, decay=0.030, strike=0.5) * 0.7,
                    S.band_noise(0.012, r, f * 2.0, min(14000.0, f * 16.0)) *
                    S.perc_env(0.012, 0.0003, 0.004) * 0.6)
        out = S.place(out, one * (0.3 + 0.7 * float(r.random())) * level, at)
    return out


def _growl(dur, r, f0=58.0, bend=(1.0, 1.22, 0.78), formants=(300.0, 880.0, 2000.0),
           rasp=0.55, sub=0.7, bright=1.0, flutter=27.0):
    """A throat. The one helper every boss's roar is a recolouring of.

    Four parts: a bent saw/pulse CORE (the vocal fold), a FORMANT bank (the
    throat and mouth - moving these is most of what makes one animal sound
    unlike another), a RASP of amplitude-fluttered noise (the wet edge that
    stops it sounding like a synth patch), and a SUBHARMONIC an octave
    under everything, which is the trick real big-animal vocalisations use
    and the reason the result sounds larger than its fundamental.
    """
    contour = S.breakpoints(dur, [(0.0, f0 * bend[0]),
                                  (dur * 0.32, f0 * bend[1]),
                                  (dur, f0 * bend[2])], curve="exp")
    core = S.saw(dur, contour, bright=0.85) * 0.6 + S.pulse(dur, contour, 0.31) * 0.45
    core = S.moog(core, S.breakpoints(dur, [(0.0, 420.0),
                                            (dur * 0.28, 2600.0 * bright),
                                            (dur, 620.0)], curve="exp"), res=0.34)
    throat = S.formant(core, list(formants), qs=[9.0, 7.0, 5.0],
                       gains=[1.0, 0.55, 0.26])
    voice = S.mix(core * 0.34, throat * 0.85)

    if rasp > 0:
        edge = S.band_noise(dur, r, 260.0, 4200.0 * bright, order=2)
        edge = S.tremolo(edge, rate=flutter, depth=0.85, shape="sine")
        edge *= S.breakpoints(dur, [(0.0, 0.0), (0.04, 1.0), (dur, 0.35)])
        voice = S.mix(voice, edge * rasp * 0.5)

    if sub > 0:
        # The second octave down lands at 12-16 Hz for a 50 Hz throat -
        # inaudible, but it is real signal: it eats headroom the peak
        # normalise then gives away, and it survives build.py's 18 Hz DC
        # blocker as a slow offset. High-pass the whole subharmonic stack
        # at 26 Hz so what is left is weight the player can actually hear.
        low = S.sine(dur, contour * 0.5) + S.sine(dur, contour * 0.25) * 0.5
        low = S.highpass(low, 26.0, order=2)
        voice = S.mix(voice, S.saturate(low * 0.5, 2.2) * sub)

    return voice


def _roar_env(dur, attack=0.06, peak=0.30, hold=0.55):
    """The shape of a shout: a fast-but-not-instant swell, a held middle, a
    fall that is longer than the rise. An instant attack on a roar reads as
    a hit; a slow one reads as a pad."""
    return S.breakpoints(dur, [(0.0, 0.0), (attack, 0.75), (dur * peak, 1.0),
                               (dur * hold, 0.8), (dur * 0.92, 0.2),
                               (dur, 0.0)], curve="exp")


# ---------------------------------------------------------------------------
# the seven voiced cues, neutral
# ---------------------------------------------------------------------------

@cue("bossTell")
def boss_tell(r):
    """The wind-up a player reads. No transient worth the name: a knell that
    RISES, doubled a fifth up so it reads as intent rather than as a noise,
    plus an intake of breath under it. 0.8 s, which is about as long as a
    warning can be before the player stops waiting for it.

    IT IS NOT LOW. Every other cue on this sheet lives under 200 Hz, and a
    telegraph pitched down there disappears under the fight it is warning
    about. The knell sits at F3/C4 - an octave above the bodies - and the
    only sub in it is a swell that never gets to the top of the mix. Being
    audible IS the feature; being ominous is what the interval is for.
    """
    dur = 0.80
    knell = S.silence(dur)
    for i, f in enumerate((174.61, 261.63)):         # F3 and C4 - a bare fifth
        v = S.bell(0.62, f, r, decay=0.30, strike=0.55, inharmonic=0.55)
        knell = S.place(knell, v * (0.9 - 0.3 * i), i * 0.045)
    swell = S.sine(dur, S.expsweep(dur, 62.0, 104.0))
    swell *= S.breakpoints(dur, [(0.0, 0.0), (0.55, 0.8), (0.72, 1.0), (dur, 0.15)],
                           curve="exp")
    breath = S.band_noise(dur, r, 300.0, 3200.0, order=2)
    breath = S.lp_sweep(breath, S.expsweep(dur, 900.0, 3400.0), order=2)
    breath *= S.breakpoints(dur, [(0.0, 0.0), (0.6, 0.55), (dur, 0.0)], curve="exp")
    y = S.mix(_lvl(knell, 1.0), _lvl(swell, 0.45), _lvl(breath, 0.22))
    return _room(y, size=1.1, mix=0.24, cap=1.15)


@cue("bossRise")
def boss_rise(r):
    """It comes up. Water and mass being displaced: a long noise swell that
    OPENS (the filter climbs) over a sub that climbs with it, and one heavy
    surge of water breaking near the end. Nothing here is percussive - the
    rise is the news, the hit comes later."""
    dur = 1.90
    surge = S.band_noise(dur, r, 90.0, 5200.0, order=2)
    surge = S.lp_sweep(surge, S.breakpoints(dur, [(0.0, 260.0), (1.35, 2600.0),
                                                  (dur, 900.0)], curve="exp"), order=2)
    surge *= S.breakpoints(dur, [(0.0, 0.0), (1.25, 0.85), (1.5, 1.0), (dur, 0.10)],
                           curve="exp")
    low = S.sine(dur, S.expsweep(dur, 30.0, 52.0))
    low *= S.breakpoints(dur, [(0.0, 0.0), (1.4, 1.0), (dur, 0.2)], curve="exp")
    heave = S.splash(0.65, r, low=220.0, high=4200.0, sweep_to=200.0, body=0.7)
    drops = S.wet_texture(0.55, r, density=16.0, freq=520.0, spread=2.4, level=0.35)
    y = S.mix(surge * 0.6, S.saturate(low * 0.8, 2.2))
    y = S.place(y, heave * 0.85, 1.28)
    y = S.place(y, drops * 0.45, 1.45)
    return _room(y, size=1.5, damping=0.45, mix=0.28, cap=2.30)


@cue("bossRoar")
def boss_roar(r):
    """The shout. Growl core plus subharmonic plus rasp, over a sub that
    lands with it, in a room big enough to answer. This is the reference the
    seven voices are colourings of."""
    dur = 2.10
    voice = _growl(dur, r, f0=62.0, bend=(0.9, 1.25, 0.72), rasp=0.6, sub=0.75)
    voice *= _roar_env(dur)
    floor = _sub(dur, 58.0, 30.0, tau=0.85, drive=2.6, attack=0.02)
    air = S.band_noise(dur, r, 900.0, 7000.0, order=2)
    air *= S.breakpoints(dur, [(0.0, 0.0), (0.10, 0.5), (0.9, 0.25), (dur, 0.0)],
                         curve="exp")
    y = S.mix(S.saturate(voice * 0.8, 1.7), floor * 0.6, air * 0.16)
    return _room(y, size=1.9, damping=0.38, mix=0.30, predelay=0.02, cap=2.60)


@cue("bossSnap")
def boss_snap(r):
    """A jaw shutting. Three events inside 40 ms: the air being cut, the
    teeth meeting (a hard dry crack), and the wet closure behind them."""
    dur = 0.52
    out = S.silence(dur)
    cut = S.bp_sweep(S.white(0.09, r), S.expsweep(0.09, 1400.0, 5200.0), q=2.4)
    cut *= S.breakpoints(0.09, [(0.0, 0.0), (0.06, 1.0), (0.09, 0.0)], curve="exp")
    out = S.place(out, cut * 0.45, 0.0)
    out = S.place(out, _crack(0.16, r, 1200.0, 12000.0, tau=0.012) * 1.0, 0.075)
    knock = S.mix(S.bar(0.22, 168.0, r, decay=0.055, strike=0.9) * 0.8,
                  S.bar(0.22, 268.0, r, decay=0.040, strike=0.7) * 0.45)
    out = S.place(out, knock, 0.075)
    out = S.place(out, _sub(0.34, 96.0, 44.0, tau=0.08, drive=2.4) * 0.75, 0.076)
    wet = S.splash(0.16, r, low=400.0, high=3600.0, sweep_to=260.0, body=0.35)
    out = S.place(out, wet * 0.30, 0.086)
    return _room(out, size=1.0, damping=0.5, mix=0.20, cap=0.80)


@cue("bossSlam")
def boss_slam(r):
    """The whole body landing. The canonical CRACK -> BOOM: 8 ms of crack,
    then a saturated sub and a struck mass, then debris coming back down."""
    dur = 1.55
    out = S.silence(dur)
    out = S.place(out, _crack(0.20, r, 700.0, 12000.0, tau=0.022) * 0.85, 0.0)
    out = S.place(out, _body(0.85, r, 58.0, drive=2.4, noise=0.30, tau=0.24) * 0.95, 0.008)
    out = S.place(out, _sub(1.20, 62.0, 27.0, tau=0.36, drive=2.8), 0.008)
    thump = S.mix(S.bar(0.5, 92.0, r, decay=0.13, strike=0.8) * 0.5,
                  S.bar(0.5, 147.0, r, decay=0.09, strike=0.6) * 0.28)
    out = S.place(out, thump, 0.010)
    out = S.place(out, _debris(r, count=11, spread=0.55, level=0.26, freq=300.0), 0.09)
    return _room(out, size=1.7, damping=0.40, mix=0.28, predelay=0.014, cap=2.00)


@cue("bossDown")
def boss_down(r):
    """It goes down. A falling collapse: the pitch of everything slides,
    the noise closes, and it ends in water rather than in a hit."""
    dur = 2.40
    out = S.silence(dur)
    fall = S.band_noise(1.5, r, 120.0, 5000.0, order=2)
    fall = S.lp_sweep(fall, S.expsweep(1.5, 3400.0, 320.0), order=2)
    fall *= S.breakpoints(1.5, [(0.0, 0.6), (0.35, 1.0), (1.5, 0.08)], curve="exp")
    out = S.place(out, fall * 0.55, 0.0)
    out = S.place(out, _sub(2.0, 74.0, 24.0, tau=0.75, drive=2.6, attack=0.05) * 0.9, 0.02)
    groan = _growl(1.1, r, f0=48.0, bend=(1.1, 0.85, 0.6), rasp=0.35, sub=0.6,
                   bright=0.55)
    groan *= S.breakpoints(1.1, [(0.0, 0.0), (0.15, 0.8), (0.7, 0.6), (1.1, 0.0)],
                           curve="exp")
    out = S.place(out, groan * 0.55, 0.10)
    wash = S.splash(0.9, r, low=200.0, high=5200.0, sweep_to=190.0, body=0.8)
    out = S.place(out, wash * 0.8, 0.95)
    out = S.place(out, S.wet_texture(0.8, r, density=14.0, freq=460.0, level=0.35) * 0.5,
                  1.15)
    return _room(out, size=2.0, damping=0.45, mix=0.30, cap=2.80)


@cue("bossStagger")
def boss_stagger(r):
    """The window opens: it loses its footing and comes down. The heaviest
    cue here short of the death - lower than the slam and left longer,
    because everyone in the arena has to know the punish has started."""
    dur = 1.90
    out = S.silence(dur)
    stumble = S.silence(dur)
    for i, at in enumerate((0.0, 0.115)):            # two feet failing
        stumble = S.place(stumble, _body(0.4, r, 74.0 - 8.0 * i, drive=2.0,
                                         noise=0.25, tau=0.10) * (0.55 - 0.15 * i), at)
    out = S.mix(out, stumble)
    out = S.place(out, _crack(0.26, r, 500.0, 9000.0, tau=0.035) * 0.75, 0.30)
    out = S.place(out, _body(1.0, r, 48.0, drive=2.6, noise=0.35, tau=0.30) * 1.0, 0.308)
    out = S.place(out, _sub(1.5, 54.0, 22.0, tau=0.50, drive=3.0), 0.308)
    groan = _growl(0.9, r, f0=52.0, bend=(1.0, 0.8, 0.62), rasp=0.45, sub=0.7,
                   bright=0.6)
    groan *= S.breakpoints(0.9, [(0.0, 0.0), (0.12, 1.0), (0.6, 0.5), (0.9, 0.0)],
                           curve="exp")
    out = S.place(out, groan * 0.5, 0.42)
    out = S.place(out, _debris(r, count=13, spread=0.8, level=0.24, freq=240.0), 0.40)
    return _room(out, size=2.0, damping=0.42, mix=0.30, predelay=0.016, cap=2.40)


# ---------------------------------------------------------------------------
# the rest of the shared vocabulary
# ---------------------------------------------------------------------------

@cue("bossSweep")
def boss_sweep(r):
    """A limb passing through the arena. Band noise whose centre rises and
    falls - the arc IS the pitch contour - with a low body under it so it
    has mass, and a dip at the moment it passes."""
    dur = 0.85
    air = S.band_noise(dur, r, 160.0, 9000.0, order=2)
    centre = S.breakpoints(dur, [(0.0, 380.0), (0.34, 2200.0), (0.46, 1500.0),
                                 (dur, 420.0)], curve="exp")
    air = S.bp_sweep(air, centre, q=1.9)
    air *= S.breakpoints(dur, [(0.0, 0.0), (0.14, 0.45), (0.38, 1.0), (0.52, 0.7),
                               (dur, 0.0)], curve="exp")
    mass = S.sine(dur, S.expsweep(dur, 120.0, 55.0))
    mass *= S.breakpoints(dur, [(0.0, 0.0), (0.36, 1.0), (dur, 0.0)], curve="exp")
    y = S.mix(_lvl(air, 1.0), _lvl(S.saturate(mass, 2.0), 0.42))
    return _room(y, size=1.2, damping=0.45, mix=0.22, cap=1.15)


@cue("bossStance")
def boss_stance(r):
    """A stance change: the whole mass grinding one turn. A grind has NO
    transient - it is a rough noise bed under a slow low-frequency
    modulation, and it takes its time."""
    dur = 1.10
    grit = S.band_noise(dur, r, 90.0, 3600.0, order=2)
    grit = S.bp_sweep(grit, S.breakpoints(dur, [(0.0, 300.0), (0.5, 620.0),
                                                (dur, 240.0)]), q=1.3)
    # The stick-slip: a fast irregular tremolo is what stone on stone is.
    grind = S.tremolo(grit, rate=19.0, depth=0.55, shape="sine")
    grind = S.tremolo(grind, rate=4.3, depth=0.35, shape="sine")
    grind *= S.breakpoints(dur, [(0.0, 0.0), (0.18, 0.9), (0.7, 1.0), (dur, 0.0)],
                           curve="exp")
    rumble = S.brown(dur, r)
    rumble = S.lowpass(rumble, 130.0, order=2)
    rumble *= S.breakpoints(dur, [(0.0, 0.0), (0.3, 1.0), (dur, 0.05)], curve="exp")
    ticks = S.silence(dur)
    for _ in range(7):
        at = 0.12 + float(r.random()) * 0.80
        ticks = S.place(ticks, S.bar(0.10, 210.0 * float(2.0 ** (r.random() - 0.5)),
                                     r, decay=0.030, strike=0.6) * 0.22, at)
    y = S.mix(grind * 0.85, S.saturate(rumble * 0.8, 2.0), ticks)
    return _room(y, size=1.4, damping=0.5, mix=0.24, cap=1.45)


@cue("bossCollapse")
def boss_collapse(r):
    """The death. `bossDown` given twice the room and a body that never
    recovers - a long slide, a fall, and the arena ringing after it."""
    dur = 2.80
    out = S.silence(dur)
    slide = S.band_noise(1.2, r, 80.0, 3000.0, order=2)
    slide = S.bp_sweep(slide, S.expsweep(1.2, 900.0, 200.0), q=1.4)
    slide = S.tremolo(slide, rate=13.0, depth=0.4)
    slide *= S.breakpoints(1.2, [(0.0, 0.0), (0.2, 0.9), (1.2, 0.15)], curve="exp")
    out = S.place(out, slide * 0.5, 0.0)
    last = _growl(1.4, r, f0=44.0, bend=(1.15, 0.9, 0.55), rasp=0.4, sub=0.85,
                  bright=0.5)
    last *= S.breakpoints(1.4, [(0.0, 0.0), (0.1, 0.9), (0.75, 0.55), (1.4, 0.0)],
                          curve="exp")
    out = S.place(out, last * 0.65, 0.06)
    out = S.place(out, _crack(0.3, r, 400.0, 8000.0, tau=0.05) * 0.55, 1.05)
    out = S.place(out, _body(1.2, r, 42.0, drive=2.6, noise=0.30, tau=0.40) * 0.9, 1.06)
    out = S.place(out, _sub(1.7, 48.0, 19.0, tau=0.60, drive=3.0), 1.06)
    out = S.place(out, S.splash(1.0, r, low=180.0, high=4600.0, sweep_to=170.0,
                                body=0.8) * 0.6, 1.10)
    out = S.place(out, _debris(r, count=15, spread=1.0, level=0.20, freq=220.0), 1.15)
    return _room(out, size=2.4, damping=0.40, mix=0.32, cap=3.20)


@cue("reefShatter")
def reef_shatter(r):
    """A stone spent. Dry, bright, and over quickly - the one sound in the
    boss vocabulary with no low end at all, which is what makes it readable
    under everything else."""
    dur = 0.60
    out = S.silence(dur)
    out = S.place(out, _crack(0.12, r, 1800.0, 15000.0, tau=0.010, sweep=False), 0.0)
    for i, f in enumerate((1180.0, 1760.0, 2640.0, 3920.0)):
        v = S.bar(0.26, f, r, decay=0.042 - 0.006 * i, strike=0.95)
        out = S.place(out, v * (0.55 - 0.10 * i), 0.001 + i * 0.004)
    out = S.place(out, _sub(0.24, 150.0, 80.0, tau=0.05, drive=2.0) * 0.35, 0.002)
    out = S.place(out, _debris(r, count=9, spread=0.32, level=0.30, freq=900.0,
                               grain=0.06), 0.03)
    return _room(out, size=1.0, damping=0.35, mix=0.22, cap=0.85)


@cue("bossSpit")
def boss_spit(r):
    """A glob leaving the throat: a wet heave, then the launch. Deep, short,
    and unmistakably organic - it is the only cue here that is mostly
    bubbles."""
    dur = 0.46
    out = S.silence(dur)
    heave = _growl(0.22, r, f0=70.0, bend=(0.85, 1.35, 1.0), rasp=0.7, sub=0.5,
                   bright=0.7, flutter=34.0)
    heave *= S.breakpoints(0.22, [(0.0, 0.0), (0.05, 1.0), (0.22, 0.0)], curve="exp")
    out = S.place(out, _lvl(heave, 1.0), 0.0)
    spit = S.bp_sweep(S.white(0.14, r), S.expsweep(0.14, 620.0, 1900.0), q=2.2)
    spit *= S.perc_env(0.14, 0.0015, 0.035)
    out = S.place(out, _lvl(spit, 0.45), 0.16)
    out = S.place(out, S.wet_texture(0.20, r, density=30.0, freq=300.0, spread=2.6,
                                     level=0.5) * 0.45, 0.14)
    out = S.place(out, _sub(0.34, 110.0, 52.0, tau=0.10, drive=2.2) * 0.65, 0.16)
    return _room(out, size=0.9, damping=0.55, mix=0.18, cap=0.65)


@cue("bossSpine")
def boss_spine(r):
    """A spine loosed: a sharp dry "thk" with a whistle of travel behind it.
    Very short - this fires several times a second in a volley."""
    dur = 0.22
    out = S.silence(dur)
    out = S.place(out, _crack(0.05, r, 2200.0, 15000.0, tau=0.006) * 0.9, 0.0)
    out = S.place(out, S.bar(0.12, 1180.0, r, decay=0.022, strike=0.9) * 0.55, 0.0)
    whizz = S.bp_sweep(S.white(0.14, r), S.expsweep(0.14, 3200.0, 1500.0), q=5.0)
    whizz *= S.breakpoints(0.14, [(0.0, 0.0), (0.02, 0.8), (0.14, 0.0)], curve="exp")
    out = S.place(out, whizz * 0.35, 0.02)
    return _room(out, size=0.7, damping=0.45, mix=0.16, cap=0.40)


@cue("bossSpineHit")
def boss_spine_hit(r):
    """Where it sticks. The same dry transient landing in something solid -
    a shorter crack, a woody knock, and no travel."""
    dur = 0.30
    out = S.silence(dur)
    out = S.place(out, _crack(0.04, r, 1200.0, 11000.0, tau=0.005) * 0.8, 0.0)
    for i, f in enumerate((330.0, 520.0, 810.0)):
        out = S.place(out, S.bar(0.20, f, r, decay=0.040 - 0.008 * i, strike=0.8) *
                      (0.7 - 0.18 * i), 0.001)
    out = S.place(out, _sub(0.18, 130.0, 74.0, tau=0.04, drive=2.0) * 0.4, 0.002)
    return _room(out, size=0.8, damping=0.5, mix=0.17, cap=0.50)


@cue("bossGlobThud")
def boss_glob_thud(r):
    """A glob landing on ground: a dull body thud with no ring and a wet
    edge. The point of it is that it is NOT a splash - it is mass."""
    dur = 0.50
    out = S.silence(dur)
    out = S.place(out, _body(0.34, r, 82.0, drive=2.2, noise=0.40, tau=0.09) * 0.95, 0.0)
    out = S.place(out, _sub(0.42, 96.0, 46.0, tau=0.11, drive=2.4) * 0.7, 0.001)
    slap = S.band_noise(0.09, r, 400.0, 4200.0, order=3)
    slap = S.lp_sweep(slap, S.expsweep(0.09, 3800.0, 600.0), order=2)
    slap *= S.perc_env(0.09, 0.001, 0.018, curve=1.3)
    out = S.place(out, slap * 0.45, 0.0)
    out = S.place(out, S.wet_texture(0.24, r, density=14.0, freq=380.0, level=0.35) * 0.4,
                  0.05)
    return _room(S.lowpass(out, 5200.0, order=2), size=1.0, damping=0.55, mix=0.18, cap=0.72)
