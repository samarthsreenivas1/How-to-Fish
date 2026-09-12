"""sfx_boss_brinejaw.py - the Drowned Leviathan, coiled on the lighthouse.

THE VOICE: WET STONE. Everything Brinejaw does is either water in enormous
quantity or masonry giving way, and most of it is both at once - it is a sea
serpent wrapped around a stone tower, and every move drags one against the
other. Two decisions carry the whole sheet:

* THE THROAT IS CAVERNOUS AND SUBHARMONIC. `_bjaw_growl` puts the formants
  low and close (230/620/1450 Hz - a big wet resonant pipe rather than a
  mouth), then adds an octave-down and two-octaves-down sine under the
  fundamental. Real large-animal roars do exactly this, and it is why the
  result sounds like a sixty-stud head and not like a loud lizard.
* THE STONE IS ALWAYS THERE. `_stone` - a grain of tuned bars over grinding
  noise - is mixed into the stance, the slams, the geysers and the rain. It
  is what makes this boss's slam different from Rimefang's (ice) or
  Pyrelisk's (rock on rock at temperature): masonry has a pitch, and its
  pitch is low mid, right where the water is not.

WATER IS NOT SPLASH. The wave, the surge and the undertow have NO transient
at all - they are filtered noise that opens, swells and closes, because a
wall of water reaching you announces itself for a second and a half before
it arrives. The splashy layer only appears where something small breaks the
surface (polyps, spines, droplets).
"""

import numpy as np

import synth as S
from cues import cue


# ---------------------------------------------------------------------------
# the lighthouse: a stone tower standing in open shallows
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


def _room(x, size=1.5, damping=0.45, mix=0.27, predelay=0.014, tail=True,
          cap=None):
    """Big, wet and stony, with a real predelay - the tower is 60 studs up
    and the arena is 140 across, so the reflections arrive late.

    `cap` fixes the sprite's length and rolls the tail off over its last
    third; without it build.py's -62 dBFS trim keeps seconds of inaudible
    reverb on every cue and the client's fade lands inside the tail.
    """
    # ONE INFRASONIC HIGH-PASS FOR THE WHOLE SHEET. Layered saturated subs
    # and brown-noise rumbles put real energy under 20 Hz, where no speaker
    # a player owns reproduces anything - but build.py peak-normalises every
    # cue, so that energy is paid for by turning the AUDIBLE part down. A
    # 26 Hz high-pass here is the difference between a slam that measures
    # big and a slam that sounds big.
    x = S.highpass(x, 26.0, order=2)
    y = S.reverb(x, size=size, damping=damping, mix=mix, predelay=predelay,
                 seed=23, tail=tail)
    if cap is None:
        return y
    y = np.concatenate([np.zeros(S.n(HEAD_LEAD)), y])
    cap = cap + HEAD_LEAD
    y = S.fit(y, cap)
    return y * S.breakpoints(cap, [(0.0, 1.0), (cap * 0.64, 1.0), (cap, 0.0)],
                             curve="exp")


def _lvl(x, amp):
    """Normalise a layer to a known peak before mixing - see sfx_boss_shared."""
    peak = float(np.max(np.abs(x))) if len(x) else 0.0
    return x * (amp / peak) if peak > 1e-9 else x


def _sub(dur, f0, f1, tau=None, drive=2.4, attack=0.002):
    if tau is None:
        tau = float(dur) * 0.34
    return S.saturate(S.sine(dur, S.expsweep(dur, f0, f1)) *
                      S.perc_env(dur, attack, tau), drive)


def _crack(dur, r, low=900.0, high=11000.0, tau=0.020, sweep=True):
    x = S.band_noise(dur, r, low, high, order=3)
    if sweep:
        x = S.lp_sweep(x, S.expsweep(dur, high, max(400.0, low * 0.45)), order=2)
    return x * S.perc_env(dur, 0.0004, tau, curve=1.2)


def _stone(dur, r, freq=185.0, count=4, decay=0.06, grind=0.35):
    """MASONRY. Tuned bars in a low-mid cluster over a bed of grinding
    noise. Stone is not a drum - it has a pitch and it has grit, and the
    grit is what stops four bars sounding like a marimba."""
    out = S.silence(dur)
    for i in range(count):
        f = freq * (1.0 + 0.62 * i) * (0.94 + 0.12 * float(r.random()))
        out = S.place(out, S.bar(min(dur, 0.34), f, r, decay=decay / (1.0 + 0.4 * i),
                                 strike=0.85) * (0.9 ** i), 0.0015 * i)
    if grind > 0:
        dust = S.band_noise(dur, r, 220.0, 3400.0, order=2)
        dust = S.tremolo(dust, rate=23.0, depth=0.5)
        dust *= S.perc_env(dur, 0.001, dur * 0.20, curve=1.3)
        out = S.mix(out, _lvl(dust, grind))
    return out


def _rubble(r, count=10, spread=0.6, start=0.06, level=0.28, freq=260.0):
    """Masonry coming back down. Bars, not noise - broken stone rings."""
    out = S.silence(start + spread + 0.2)
    for _ in range(count):
        at = start + float(r.random()) * spread
        f = freq * float(2.0 ** (r.random() * 1.7 - 0.85))
        one = S.mix(S.bar(0.13, f, r, decay=0.028, strike=0.7) * 0.8,
                    S.band_noise(0.010, r, f * 2.4, min(12000.0, f * 14.0)) *
                    S.perc_env(0.010, 0.0003, 0.003) * 0.5)
        out = S.place(out, one * (0.3 + 0.7 * float(r.random())) * level, at)
    return out


def _water(dur, r, low=90.0, high=5200.0, open_to=2400.0, close_to=420.0,
           peak=0.62, body=0.5):
    """TONNAGE, not splash. Noise through a filter that OPENS as the water
    arrives and CLOSES as it passes, with a sub swelling under it. No
    transient anywhere: a wall of water is heard coming, which is the whole
    reason the player can answer it."""
    wash = S.band_noise(dur, r, low, high, order=2)
    wash = S.lp_sweep(wash, S.breakpoints(dur, [(0.0, low * 3.0),
                                                (dur * peak, open_to),
                                                (dur, close_to)], curve="exp"),
                      order=2)
    wash *= S.breakpoints(dur, [(0.0, 0.0), (dur * peak * 0.75, 0.8),
                                (dur * peak, 1.0), (dur, 0.06)], curve="exp")
    wash = S.tremolo(wash, rate=2.6, depth=0.18)
    swell = S.sine(dur, S.expsweep(dur, 34.0, 56.0))
    swell *= S.breakpoints(dur, [(0.0, 0.0), (dur * peak, 1.0), (dur, 0.08)],
                           curve="exp")
    return S.mix(_lvl(wash, 1.0), _lvl(S.saturate(swell, 2.2), body))


def _bjaw_growl(dur, r, f0=54.0, bend=(0.92, 1.20, 0.70), rasp=0.55, sub=0.85,
                bright=0.85, flutter=24.0, wet=0.35):
    """THE DROWNED THROAT. A cavern with water in it.

    Low close formants (a pipe, not a mouth), a fluttered rasp, an octave
    AND two-octaves subharmonic, and - the part that makes it Brinejaw
    rather than a generic monster - a `wet` layer of bubbles rising through
    the voice for its whole length.
    """
    contour = S.breakpoints(dur, [(0.0, f0 * bend[0]), (dur * 0.30, f0 * bend[1]),
                                  (dur, f0 * bend[2])], curve="exp")
    core = S.saw(dur, contour, bright=0.8) * 0.6 + S.pulse(dur, contour, 0.29) * 0.45
    core = S.moog(core, S.breakpoints(dur, [(0.0, 380.0), (dur * 0.26, 2100.0 * bright),
                                            (dur, 520.0)], curve="exp"), res=0.36)
    throat = S.formant(core, [230.0, 620.0, 1450.0], qs=[10.0, 8.0, 5.5],
                       gains=[1.0, 0.60, 0.24])
    voice = S.mix(_lvl(core, 0.34), _lvl(throat, 0.95))

    if rasp > 0:
        edge = S.band_noise(dur, r, 220.0, 3600.0 * bright, order=2)
        edge = S.tremolo(edge, rate=flutter, depth=0.85)
        edge *= S.breakpoints(dur, [(0.0, 0.0), (0.05, 1.0), (dur, 0.35)])
        voice = S.mix(voice, _lvl(edge, rasp * 0.45))
    if sub > 0:
        # High-passed at 26 Hz: the two-octaves-down partial of a 52 Hz
        # throat is 13 Hz, which no speaker reproduces and which build.py's
        # DC blocker leaves behind as an offset. See sfx_boss_shared.
        low = S.sine(dur, contour * 0.5) + S.sine(dur, contour * 0.25) * 0.55
        low = S.highpass(low, 26.0, order=2)
        voice = S.mix(voice, _lvl(S.saturate(low, 2.2), sub * 0.9))
    if wet > 0:
        bubbles = S.wet_texture(dur, r, density=26.0, freq=190.0, spread=2.6,
                                level=0.6)
        voice = S.mix(voice, _lvl(bubbles, wet * 0.4))
    return voice


def _roar_env(dur, attack=0.06):
    return S.breakpoints(dur, [(0.0, 0.0), (attack, 0.75), (dur * 0.30, 1.0),
                               (dur * 0.58, 0.8), (dur * 0.92, 0.2), (dur, 0.0)],
                         curve="exp")


# ---------------------------------------------------------------------------
# the seven voice variants - the shared vocabulary in wet stone
# ---------------------------------------------------------------------------

@cue("bossTell__brinejaw")
def tell_brinejaw(r):
    """The coil takes a breath and the tower answers. A wet intake that
    rises, and one struck masonry note over it - the same "something is
    about to happen" as the neutral tell, said in this fight's materials."""
    dur = 0.82
    intake = S.band_noise(dur, r, 200.0, 3600.0, order=2)
    intake = S.bp_sweep(intake, S.expsweep(dur, 420.0, 1600.0), q=2.2)
    intake = S.tremolo(intake, rate=17.0, depth=0.35)
    intake *= S.breakpoints(dur, [(0.0, 0.0), (0.62, 0.9), (0.74, 1.0), (dur, 0.0)],
                            curve="exp")
    knock = S.fit(_stone(0.42, r, freq=196.0, count=3, decay=0.075, grind=0.25), dur)
    swell = S.sine(dur, S.expsweep(dur, 46.0, 78.0))
    swell *= S.breakpoints(dur, [(0.0, 0.0), (0.7, 1.0), (dur, 0.1)], curve="exp")
    drips = S.fit(S.wet_texture(0.5, r, density=10.0, freq=900.0, level=0.4), dur)
    y = S.mix(_lvl(knock, 1.0), _lvl(intake, 0.55), _lvl(S.saturate(swell, 2.0), 0.40),
              _lvl(drips, 0.20))
    return _room(y, size=1.2, mix=0.26, cap=1.20)


@cue("bossRise__brinejaw")
def rise_brinejaw(r):
    """Sixty studs of serpent coming out of the shallows and up the tower.
    The neutral rise plus the thing that makes it this boss: the coil
    GRINDING up the masonry the whole way, and water running off it."""
    dur = 2.00
    surge = _water(1.7, r, low=80.0, high=5200.0, open_to=2600.0, close_to=700.0,
                   peak=0.78, body=0.75)
    grind = S.band_noise(1.5, r, 140.0, 2800.0, order=2)
    grind = S.bp_sweep(grind, S.breakpoints(1.5, [(0.0, 260.0), (1.1, 640.0),
                                                  (1.5, 380.0)]), q=1.4)
    grind = S.tremolo(grind, rate=15.0, depth=0.55)
    grind = S.tremolo(grind, rate=3.7, depth=0.30)
    grind *= S.breakpoints(1.5, [(0.0, 0.0), (0.25, 0.8), (1.2, 1.0), (1.5, 0.1)],
                           curve="exp")
    out = S.mix(_lvl(surge, 1.0), _lvl(grind, 0.55))
    out = S.place(out, _lvl(_rubble(r, count=8, spread=0.7, level=0.3, freq=300.0),
                            0.35), 0.7)
    out = S.place(out, _lvl(S.wet_texture(0.9, r, density=20.0, freq=560.0,
                                          level=0.5), 0.35), 1.15)
    return _room(out, size=1.8, damping=0.45, mix=0.30, cap=2.50)


@cue("bossRoar__brinejaw")
def roar_brinejaw(r):
    """THE SIGNATURE. A wet cavernous roar with the subharmonic under it -
    the drowned throat at full stretch, in the biggest room on the sheet.
    Everything else Brinejaw has is a colouring of this."""
    dur = 2.20
    voice = _bjaw_growl(dur, r, f0=52.0, bend=(0.88, 1.24, 0.68), rasp=0.62,
                        sub=0.95, wet=0.40)
    voice *= _roar_env(dur)
    floor = _sub(dur, 52.0, 26.0, tau=0.95, drive=2.8, attack=0.03)
    spray = S.band_noise(1.1, r, 700.0, 6500.0, order=2)
    spray *= S.breakpoints(1.1, [(0.0, 0.0), (0.12, 0.6), (1.1, 0.0)], curve="exp")
    y = S.mix(_lvl(S.saturate(voice, 1.7), 1.0), _lvl(floor, 0.58),
              _lvl(S.fit(spray, dur), 0.14))
    return _room(y, size=2.0, damping=0.40, mix=0.31, predelay=0.022, cap=2.70)


@cue("bossSnap__brinejaw")
def snap_brinejaw(r):
    """The jaw shutting on nothing. A colossal snap: air cut, a bone-dry
    crack, and the wet closure behind it - deeper and wetter than the
    neutral snap because the mouth it belongs to is the size of a boat."""
    dur = 0.60
    out = S.silence(dur)
    cut = S.bp_sweep(S.white(0.11, r), S.expsweep(0.11, 900.0, 3800.0), q=2.2)
    cut *= S.breakpoints(0.11, [(0.0, 0.0), (0.075, 1.0), (0.11, 0.0)], curve="exp")
    out = S.place(out, _lvl(cut, 0.42), 0.0)
    out = S.place(out, _lvl(_crack(0.18, r, 900.0, 11000.0, tau=0.014), 0.95), 0.085)
    out = S.place(out, _lvl(_stone(0.26, r, freq=138.0, count=3, decay=0.05,
                                   grind=0.25), 0.85), 0.085)
    out = S.place(out, _lvl(_sub(0.40, 88.0, 38.0, tau=0.10, drive=2.6), 0.85), 0.086)
    gulp = S.splash(0.22, r, low=280.0, high=3000.0, sweep_to=220.0, body=0.5)
    out = S.place(out, _lvl(gulp, 0.35), 0.098)
    return _room(out, size=1.2, damping=0.48, mix=0.22, cap=0.95)


@cue("bossSlam__brinejaw")
def slam_brinejaw(r):
    """The coil comes down on the sand. Crack, masonry, sub, and a shallow
    sheet of water thrown out sideways - the wet stone slam."""
    dur = 1.60
    out = S.silence(dur)
    out = S.place(out, _lvl(_crack(0.20, r, 600.0, 12000.0, tau=0.024), 0.80), 0.0)
    out = S.place(out, _lvl(S.saturate(S.membrane(0.9, 56.0, r, drop=0.5, noise=0.32,
                                                  tau=0.26), 2.4), 0.95), 0.008)
    out = S.place(out, _lvl(_sub(1.25, 60.0, 26.0, tau=0.38, drive=2.8), 0.95), 0.008)
    out = S.place(out, _lvl(_stone(0.5, r, freq=150.0, count=4, decay=0.09,
                                   grind=0.3), 0.55), 0.010)
    sheet = S.splash(0.55, r, low=260.0, high=5200.0, sweep_to=240.0, body=0.4)
    out = S.place(out, _lvl(sheet, 0.42), 0.030)
    out = S.place(out, _lvl(_rubble(r, count=11, spread=0.6, level=0.3, freq=290.0),
                            0.28), 0.08)
    return _room(out, size=1.8, damping=0.42, mix=0.29, predelay=0.016, cap=2.10)


@cue("bossDown__brinejaw")
def down_brinejaw(r):
    """It loses the tower and goes into the shallows. A long wet fall with
    the throat failing over it, ending in water rather than in a hit."""
    dur = 2.40
    out = S.silence(dur)
    slip = S.band_noise(1.3, r, 120.0, 3600.0, order=2)
    slip = S.bp_sweep(slip, S.expsweep(1.3, 1000.0, 240.0), q=1.4)
    slip = S.tremolo(slip, rate=12.0, depth=0.45)
    slip *= S.breakpoints(1.3, [(0.0, 0.0), (0.22, 0.9), (1.3, 0.12)], curve="exp")
    out = S.place(out, _lvl(slip, 0.55), 0.0)
    fail = _bjaw_growl(1.2, r, f0=44.0, bend=(1.1, 0.86, 0.54), rasp=0.45, sub=0.9,
                       bright=0.55, wet=0.5)
    fail *= S.breakpoints(1.2, [(0.0, 0.0), (0.12, 0.9), (0.7, 0.5), (1.2, 0.0)],
                          curve="exp")
    out = S.place(out, _lvl(fail, 0.75), 0.05)
    out = S.place(out, _lvl(_sub(1.6, 66.0, 22.0, tau=0.62, drive=2.7, attack=0.04),
                            0.90), 0.85)
    out = S.place(out, _lvl(S.splash(1.0, r, low=180.0, high=5000.0, sweep_to=180.0,
                                     body=0.85), 0.85), 0.92)
    out = S.place(out, _lvl(S.wet_texture(0.9, r, density=16.0, freq=480.0,
                                          level=0.5), 0.35), 1.15)
    return _room(out, size=2.1, damping=0.46, mix=0.31, cap=2.80)


@cue("bossStagger__brinejaw")
def stagger_brinejaw(r):
    """THE WINDOW. It loses its grip and sixty studs of head come down on
    the sand - the heaviest thing in the fight short of the death, and the
    news the whole lair is waiting for, so it is left long."""
    dur = 2.00
    out = S.silence(dur)
    scrape = S.band_noise(0.42, r, 200.0, 4000.0, order=2)
    scrape = S.bp_sweep(scrape, S.expsweep(0.42, 900.0, 330.0), q=1.6)
    scrape = S.tremolo(scrape, rate=26.0, depth=0.6)
    scrape *= S.breakpoints(0.42, [(0.0, 0.0), (0.08, 1.0), (0.42, 0.1)], curve="exp")
    out = S.place(out, _lvl(scrape, 0.50), 0.0)
    out = S.place(out, _lvl(_crack(0.28, r, 450.0, 9000.0, tau=0.038), 0.72), 0.34)
    out = S.place(out, _lvl(S.saturate(S.membrane(1.05, 46.0, r, drop=0.5, noise=0.35,
                                                  tau=0.32), 2.6), 1.0), 0.348)
    out = S.place(out, _lvl(_sub(1.55, 52.0, 21.0, tau=0.52, drive=3.0), 1.0), 0.348)
    out = S.place(out, _lvl(_stone(0.7, r, freq=124.0, count=5, decay=0.12,
                                   grind=0.35), 0.55), 0.352)
    groan = _bjaw_growl(1.0, r, f0=48.0, bend=(1.0, 0.82, 0.60), rasp=0.5, sub=0.85,
                        bright=0.6, wet=0.45)
    groan *= S.breakpoints(1.0, [(0.0, 0.0), (0.14, 1.0), (0.62, 0.5), (1.0, 0.0)],
                           curve="exp")
    out = S.place(out, _lvl(groan, 0.52), 0.46)
    out = S.place(out, _lvl(_rubble(r, count=14, spread=0.9, level=0.3, freq=240.0),
                            0.30), 0.42)
    return _room(out, size=2.1, damping=0.44, mix=0.31, predelay=0.018, cap=2.60)


# ---------------------------------------------------------------------------
# the two sweeps - ONE arm at two heights, told apart by ear alone
# ---------------------------------------------------------------------------

@cue("serpentSweepLow")
def serpent_sweep_low(r):
    """Dragged along the sand: the one you JUMP. Low, gritty and long,
    because it is scraping the whole way - the grain of sand and shell in
    it is what says the hazard is at ankle height."""
    dur = 1.00
    rush = S.band_noise(dur, r, 70.0, 3400.0, order=2)
    rush = S.bp_sweep(rush, S.breakpoints(dur, [(0.0, 180.0), (0.40, 620.0),
                                                (0.55, 480.0), (dur, 170.0)],
                                          curve="exp"), q=1.5)
    rush *= S.breakpoints(dur, [(0.0, 0.0), (0.20, 0.5), (0.44, 1.0), (0.62, 0.65),
                                (dur, 0.0)], curve="exp")
    grit = S.band_noise(dur, r, 900.0, 7000.0, order=2)
    grit = S.tremolo(grit, rate=31.0, depth=0.6)
    grit *= S.breakpoints(dur, [(0.0, 0.0), (0.30, 0.7), (0.48, 1.0), (dur, 0.0)],
                          curve="exp")
    mass = S.sine(dur, S.expsweep(dur, 96.0, 44.0))
    mass *= S.breakpoints(dur, [(0.0, 0.0), (0.46, 1.0), (dur, 0.0)], curve="exp")
    y = S.mix(_lvl(rush, 1.0), _lvl(grit, 0.30), _lvl(S.saturate(mass, 2.2), 0.55))
    return _room(y, size=1.4, damping=0.46, mix=0.24, cap=1.35)


@cue("serpentSweepHigh")
def serpent_sweep_high(r):
    """Passing over your head: the one you STAND UNDER. Deliberately far
    from the low sweep rather than a shade of it - up an octave and a half,
    faster, all air and no grit, with the Doppler dip as it goes by."""
    dur = 0.75
    air = S.band_noise(dur, r, 400.0, 12000.0, order=2)
    air = S.bp_sweep(air, S.breakpoints(dur, [(0.0, 900.0), (0.32, 3400.0),
                                              (0.42, 2400.0), (dur, 950.0)],
                                        curve="exp"), q=1.9)
    air *= S.breakpoints(dur, [(0.0, 0.0), (0.14, 0.5), (0.34, 1.0), (0.44, 0.62),
                               (dur, 0.0)], curve="exp")
    whistle = S.sine(dur, S.breakpoints(dur, [(0.0, 700.0), (0.34, 2100.0),
                                              (dur, 760.0)], curve="exp"))
    whistle *= S.breakpoints(dur, [(0.0, 0.0), (0.34, 0.6), (dur, 0.0)], curve="exp")
    body = S.sine(dur, S.expsweep(dur, 190.0, 96.0))
    body *= S.breakpoints(dur, [(0.0, 0.0), (0.36, 1.0), (dur, 0.0)], curve="exp")
    y = S.mix(_lvl(air, 1.0), _lvl(whistle, 0.22), _lvl(S.saturate(body, 2.0), 0.30))
    return _room(y, size=1.3, damping=0.42, mix=0.22, cap=1.05)


# ---------------------------------------------------------------------------
# the arm, the coil and the jaw
# ---------------------------------------------------------------------------

@cue("serpentSlam")
def serpent_slam(r):
    """The tail coming down. `bossSlam__brinejaw` is the whole body; this is
    ONE arm, so it is tighter and a shade higher - same materials, less of
    them, and over sooner."""
    dur = 1.15
    out = S.silence(dur)
    out = S.place(out, _lvl(_crack(0.16, r, 800.0, 13000.0, tau=0.018), 0.85), 0.0)
    out = S.place(out, _lvl(S.saturate(S.membrane(0.6, 74.0, r, drop=0.52, noise=0.3,
                                                  tau=0.17), 2.3), 0.92), 0.006)
    out = S.place(out, _lvl(_sub(0.85, 78.0, 34.0, tau=0.24, drive=2.6), 0.80), 0.006)
    out = S.place(out, _lvl(_stone(0.36, r, freq=190.0, count=3, decay=0.06,
                                   grind=0.30), 0.50), 0.008)
    out = S.place(out, _lvl(S.splash(0.34, r, low=350.0, high=6000.0, sweep_to=300.0,
                                     body=0.3), 0.35), 0.020)
    out = S.place(out, _lvl(_rubble(r, count=8, spread=0.40, level=0.3, freq=340.0),
                            0.25), 0.06)
    return _room(out, size=1.5, damping=0.44, mix=0.26, cap=1.55)


@cue("serpentCoilslam")
def serpent_coilslam(r):
    """THE WHOLE COIL STACK comes off the tower at once. The biggest impact
    in the fight: three masonry hits inside 90 ms so it reads as a STACK
    rather than one body, over the deepest sub on the sheet."""
    dur = 1.90
    out = S.silence(dur)
    out = S.place(out, _lvl(_crack(0.26, r, 400.0, 11000.0, tau=0.030), 0.80), 0.0)
    for i, at in enumerate((0.004, 0.042, 0.086)):
        out = S.place(out, _lvl(S.saturate(
            S.membrane(0.8, 62.0 - 8.0 * i, r, drop=0.5, noise=0.30, tau=0.22),
            2.5), 0.95 - 0.20 * i), at)
        out = S.place(out, _lvl(_stone(0.44, r, freq=168.0 - 22.0 * i, count=4,
                                       decay=0.085, grind=0.32), 0.50 - 0.10 * i), at)
    out = S.place(out, _lvl(_sub(1.5, 56.0, 22.0, tau=0.48, drive=3.0), 1.0), 0.006)
    out = S.place(out, _lvl(S.splash(0.7, r, low=240.0, high=5600.0, sweep_to=230.0,
                                     body=0.45), 0.40), 0.05)
    out = S.place(out, _lvl(_rubble(r, count=16, spread=0.9, level=0.3, freq=250.0),
                            0.32), 0.10)
    return _room(out, size=2.0, damping=0.42, mix=0.30, predelay=0.018, cap=2.40)


@cue("serpentBite")
def serpent_bite(r):
    """A COLOSSAL JAW SNAP. The teeth are the event: a hard bone-dry crack
    with a second one 25 ms behind it (a jaw this long does not close all at
    once), the wet gulp under them, and a sub that lands with the front of
    the mouth."""
    dur = 0.72
    out = S.silence(dur)
    rush = S.bp_sweep(S.white(0.13, r), S.expsweep(0.13, 800.0, 3400.0), q=2.0)
    rush *= S.breakpoints(0.13, [(0.0, 0.0), (0.10, 1.0), (0.13, 0.0)], curve="exp")
    out = S.place(out, _lvl(rush, 0.40), 0.0)
    for i, at in enumerate((0.100, 0.126)):
        out = S.place(out, _lvl(_crack(0.14, r, 1100.0, 13000.0, tau=0.011),
                                1.0 - 0.35 * i), at)
        out = S.place(out, _lvl(S.mix(S.bar(0.22, 214.0 * (1.0 + 0.18 * i), r,
                                            decay=0.045, strike=0.95),
                                      S.bar(0.22, 386.0, r, decay=0.030,
                                            strike=0.8) * 0.5), 0.75 - 0.25 * i), at)
    out = S.place(out, _lvl(_sub(0.42, 102.0, 40.0, tau=0.11, drive=2.6), 0.80), 0.101)
    gulp = S.splash(0.24, r, low=240.0, high=2800.0, sweep_to=200.0, body=0.55)
    out = S.place(out, _lvl(gulp, 0.42), 0.115)
    out = S.place(out, _lvl(S.wet_texture(0.26, r, density=22.0, freq=260.0,
                                          level=0.55), 0.25), 0.115)
    return _room(out, size=1.3, damping=0.46, mix=0.24, cap=1.10)


# ---------------------------------------------------------------------------
# water in quantity
# ---------------------------------------------------------------------------

@cue("serpentWave")
def serpent_wave(r):
    """A wall of water crossing the arena. The longest cue here and the one
    with no transient at all: it is read on the way in, not on arrival."""
    dur = 1.60
    wall = _water(dur, r, low=70.0, high=6000.0, open_to=2800.0, close_to=420.0,
                  peak=0.66, body=0.80)
    foam = S.band_noise(0.7, r, 1400.0, 9000.0, order=2)
    foam *= S.breakpoints(0.7, [(0.0, 0.0), (0.35, 0.8), (0.7, 0.0)], curve="exp")
    out = S.place(wall, _lvl(foam, 0.22), 0.95)
    out = S.place(out, _lvl(S.wet_texture(0.6, r, density=18.0, freq=620.0,
                                          level=0.5), 0.22), 1.05)
    return _room(out, size=1.9, damping=0.48, mix=0.30, cap=2.10)


@cue("serpentSurge")
def serpent_surge(r):
    """The water heaving up under the arena - the wave's cousin, shorter and
    with the swell landing at the FRONT so it reads as a push rather than as
    something arriving."""
    dur = 1.20
    push = _water(dur, r, low=80.0, high=5000.0, open_to=2000.0, close_to=380.0,
                  peak=0.34, body=0.85)
    out = S.place(push, _lvl(S.wet_texture(0.7, r, density=22.0, freq=520.0,
                                           level=0.5), 0.28), 0.42)
    return _room(out, size=1.7, damping=0.48, mix=0.28, cap=1.60)


@cue("undertowPull")
def undertow_pull(r):
    """Water going the OTHER way: the arena draining toward it. Everything
    here descends - the filter closes rather than opens, and the swell falls
    - which is what makes a pull sound like a pull and not like a wave."""
    dur = 1.50
    drag = S.band_noise(dur, r, 60.0, 4200.0, order=2)
    drag = S.lp_sweep(drag, S.breakpoints(dur, [(0.0, 2200.0), (0.5, 1100.0),
                                                (dur, 300.0)], curve="exp"), order=2)
    drag *= S.breakpoints(dur, [(0.0, 0.0), (0.18, 0.9), (0.9, 1.0), (dur, 0.05)],
                          curve="exp")
    drag = S.tremolo(drag, rate=1.8, depth=0.20)
    hole = S.sine(dur, S.expsweep(dur, 70.0, 30.0))
    hole *= S.breakpoints(dur, [(0.0, 0.0), (0.35, 1.0), (dur, 0.06)], curve="exp")
    swirl = S.wet_texture(dur, r, density=14.0, freq=340.0, spread=2.8, level=0.5)
    y = S.mix(_lvl(drag, 1.0), _lvl(S.saturate(hole, 2.4), 0.62), _lvl(swirl, 0.22))
    return _room(y, size=1.8, damping=0.5, mix=0.28, cap=1.90)


@cue("serpentRings")
def serpent_rings(r):
    """Rings of water going out from the coil. Four swells at a widening
    spacing - the spacing IS the ring expanding, and nothing else here
    conveys distance."""
    dur = 1.55
    out = S.silence(dur)
    at = 0.0
    for i in range(4):
        ring = _water(0.60, r, low=110.0, high=4200.0, open_to=1700.0,
                      close_to=420.0, peak=0.40, body=0.5)
        out = S.place(out, _lvl(ring, 0.95 - 0.18 * i), at)
        out = S.place(out, _lvl(S.splash(0.22, r, low=500.0, high=6000.0,
                                         sweep_to=350.0, body=0.2), 0.28 - 0.05 * i),
                      at + 0.18)
        at += 0.24 + 0.075 * i          # widening: each ring is further out
    return _room(out, size=1.7, damping=0.5, mix=0.28, cap=1.95)


@cue("spiralWind")
def spiral_wind(r):
    """The vortex standing over the lair: a long, wide airy sweep with a
    slow rotation in it. Two resonant bands beating against each other at
    different rates is what makes a moving air mass rather than a hiss."""
    dur = 1.70
    base = S.band_noise(dur, r, 150.0, 9000.0, order=2)
    a = S.bp_sweep(base, S.breakpoints(dur, [(0.0, 380.0), (0.6, 1500.0),
                                             (1.2, 900.0), (dur, 420.0)],
                                       curve="exp"), q=2.4)
    b = S.bp_sweep(base, S.breakpoints(dur, [(0.0, 1400.0), (0.8, 3300.0),
                                             (dur, 1200.0)], curve="exp"), q=3.0)
    spin = S.tremolo(S.mix(_lvl(a, 1.0), _lvl(b, 0.45)), rate=3.4, depth=0.30)
    spin *= S.breakpoints(dur, [(0.0, 0.0), (0.35, 0.8), (0.95, 1.0), (dur, 0.0)],
                          curve="exp")
    low = S.brown(dur, r)
    low = S.lowpass(low, 140.0, order=2)
    low *= S.breakpoints(dur, [(0.0, 0.0), (0.8, 1.0), (dur, 0.05)], curve="exp")
    y = S.mix(_lvl(spin, 1.0), _lvl(S.saturate(low, 2.0), 0.40))
    return _room(y, size=1.9, damping=0.44, mix=0.29, cap=2.10)


# ---------------------------------------------------------------------------
# what falls out of the sky, and what comes up out of the ground
# ---------------------------------------------------------------------------

@cue("serpentRain")
def serpent_rain(r):
    """MASONRY RAIN. The tower shedding on the arena - eleven stone impacts
    over a second and a bit, irregular on purpose, each one a real hit with
    its own crack and rubble rather than a noise burst. The irregularity is
    the whole read: evenly spaced impacts are a machine."""
    dur = 1.55
    out = S.silence(dur)
    times = np.sort(r.random(11)) * 1.15
    for i, at in enumerate(times):
        near = 0.35 + 0.65 * float(r.random())        # how close this one lands
        f = 150.0 * float(2.0 ** (r.random() * 1.4 - 0.5))
        one = S.mix(_lvl(_crack(0.10, r, 500.0, 9000.0, tau=0.012), 0.7 * near),
                    _lvl(_stone(0.30, r, freq=f, count=3, decay=0.055,
                                grind=0.30), 1.0),
                    _lvl(_sub(0.28, f * 0.65, f * 0.30, tau=0.06, drive=2.2),
                         0.55 * near))
        out = S.place(out, one * (0.35 + 0.65 * near), float(at))
    out = S.place(out, _lvl(_rubble(r, count=14, spread=1.0, level=0.3, freq=380.0),
                            0.24), 0.25)
    return _room(out, size=1.7, damping=0.44, mix=0.27, cap=1.95)


@cue("serpentGeysers")
def serpent_geysers(r):
    """STONE SPIKES ERUPTING. Not a water geyser: the ground CRACKS first,
    then a column of rock tears up through it and water follows. Three of
    them, close together, rising in pitch - the rise says they are still
    coming up."""
    dur = 1.30
    out = S.silence(dur)
    for i, at in enumerate((0.0, 0.135, 0.255)):
        f = 160.0 * (1.0 + 0.22 * i)
        out = S.place(out, _lvl(_crack(0.09, r, 700.0, 12000.0, tau=0.010),
                                0.75 - 0.12 * i), at)
        # the column tearing up - a rising filtered rush, not a splash
        col = S.band_noise(0.42, r, 140.0, 6000.0, order=2)
        col = S.bp_sweep(col, S.expsweep(0.42, 380.0, 1900.0), q=2.0)
        col *= S.breakpoints(0.42, [(0.0, 0.0), (0.03, 0.9), (0.20, 1.0), (0.42, 0.0)],
                             curve="exp")
        out = S.place(out, _lvl(col, 0.85 - 0.15 * i), at + 0.008)
        out = S.place(out, _lvl(_stone(0.34, r, freq=f, count=4, decay=0.06,
                                       grind=0.35), 0.70 - 0.12 * i), at + 0.006)
        out = S.place(out, _lvl(_sub(0.44, 92.0, 44.0, tau=0.11, drive=2.4),
                                0.60 - 0.10 * i), at + 0.008)
        out = S.place(out, _lvl(S.splash(0.30, r, low=600.0, high=8000.0,
                                         sweep_to=420.0, body=0.2), 0.28), at + 0.06)
    out = S.place(out, _lvl(_rubble(r, count=12, spread=0.55, level=0.3, freq=420.0),
                            0.26), 0.32)
    return _room(out, size=1.6, damping=0.44, mix=0.27, cap=1.70)


@cue("serpentSpines")
def serpent_spines(r):
    """WHISTLING DARTS. Five spines loosed in a fan: each is a dry launch
    click and then a falling whistle as it goes past. The whistles are
    detuned from each other, which is what makes five darts rather than one
    played five times."""
    dur = 1.00
    out = S.silence(dur)
    for i in range(5):
        at = i * 0.062 + 0.02 * float(r.random())
        scale = 0.88 + 0.30 * float(r.random())
        out = S.place(out, _lvl(_crack(0.045, r, 2400.0, 15000.0, tau=0.005,
                                       sweep=False), 0.65 - 0.06 * i), at)
        w = S.sine(0.36, S.expsweep(0.36, 3400.0 * scale, 1100.0 * scale))
        w2 = S.bp_sweep(S.white(0.36, r), S.expsweep(0.36, 3400.0 * scale,
                                                     1100.0 * scale), q=7.0)
        whizz = S.mix(_lvl(w, 0.45), _lvl(w2, 1.0))
        whizz *= S.breakpoints(0.36, [(0.0, 0.0), (0.025, 1.0), (0.36, 0.0)],
                               curve="exp")
        out = S.place(out, _lvl(whizz, 0.55 - 0.05 * i), at + 0.01)
    return _room(out, size=1.2, damping=0.40, mix=0.20, cap=1.20)


# ---------------------------------------------------------------------------
# the polyps - the one soft thing in the fight
# ---------------------------------------------------------------------------

@cue("serpentPolyps")
def serpent_polyps(r):
    """Polyps budding off the coil: a run of soft wet pops, gelatinous and
    pitched UP as they open. Deliberately small and harmless-sounding -
    these are the things you are meant to walk over to."""
    dur = 0.85
    out = S.silence(dur)
    for i in range(7):
        at = float(np.sort(r.random(1))[0]) * 0.55 + i * 0.012
        f = 260.0 * float(2.0 ** (r.random() * 1.3 - 0.4))
        pop = S.bubble(0.10, f, r, rise=2.8 + 1.4 * float(r.random()), tau=0.045)
        skin = S.band_noise(0.05, r, f * 3.0, min(11000.0, f * 18.0), order=2)
        skin *= S.perc_env(0.05, 0.0008, 0.010)
        out = S.place(out, S.mix(_lvl(pop, 0.9), _lvl(skin, 0.28)) *
                      (0.55 + 0.45 * float(r.random())), at)
    out = S.place(out, _lvl(S.wet_texture(0.6, r, density=16.0, freq=420.0,
                                          level=0.5), 0.28), 0.10)
    return _room(S.lowpass(out, 8000.0, order=2), size=1.1, damping=0.55, mix=0.20,
                 cap=1.05)


@cue("polypBurst")
def polyp_burst(r):
    """One polyp bursting. A wet pop with the membrane tearing - a short
    band-noise rip over a bubble that RISES, then a small spray. It has to
    be readable as a reward, so it is bright for this sheet."""
    dur = 0.40
    out = S.silence(dur)
    rip = S.band_noise(0.035, r, 900.0, 12000.0, order=3)
    rip *= S.perc_env(0.035, 0.0004, 0.006)
    out = S.place(out, _lvl(rip, 0.85), 0.0)
    out = S.place(out, _lvl(S.bubble(0.14, 380.0, r, rise=3.2, tau=0.055), 1.0), 0.002)
    out = S.place(out, _lvl(S.splash(0.20, r, low=800.0, high=9000.0, sweep_to=500.0,
                                     body=0.15), 0.45), 0.012)
    out = S.place(out, _lvl(S.wet_texture(0.22, r, density=26.0, freq=900.0,
                                          level=0.5), 0.30), 0.05)
    out = S.place(out, _lvl(_sub(0.18, 130.0, 70.0, tau=0.035, drive=2.0), 0.28), 0.003)
    return _room(out, size=1.0, damping=0.5, mix=0.19, cap=0.60)


@cue("polypHeal")
def polyp_heal(r):
    """The polyp gives it back. The one bright, KIND sound in the fight: a
    small glass chime rising a fourth over a wet shimmer, pitched clear of
    everything else here so it never reads as a threat."""
    dur = 0.65
    out = S.silence(dur)
    for i, f in enumerate((1174.66, 1567.98)):        # D6 -> G6, a rising fourth
        out = S.place(out, S.bell(0.42, f, r, decay=0.20, strike=0.55,
                                  inharmonic=0.8) * (0.85 - 0.2 * i), i * 0.070)
    shim = S.bp_sweep(S.white(0.34, r), S.expsweep(0.34, 4000.0, 11000.0), q=2.0)
    shim *= S.breakpoints(0.34, [(0.0, 0.0), (0.05, 1.0), (0.34, 0.0)], curve="exp")
    out = S.place(out, _lvl(shim, 0.22), 0.03)
    out = S.place(out, _lvl(S.wet_texture(0.30, r, density=18.0, freq=1400.0,
                                          level=0.5), 0.20), 0.02)
    return _room(out, size=1.2, damping=0.35, mix=0.26, cap=0.85)


# ---------------------------------------------------------------------------
# the bell, the lunge and the warning
# ---------------------------------------------------------------------------

@cue("belltoll")
def belltoll(r):
    """A DROWNED BELL. The lighthouse bell struck under water: the strike is
    muffled (no top end at all), the partials beat against each other, and
    the whole thing wobbles slowly - a bell in air rings steady, a bell with
    water in it does not. It is the fight's clock, so it is long and clean."""
    dur = 2.20
    body = S.silence(dur)
    for i, f in enumerate((116.54, 174.61, 233.08, 349.23)):    # Bb2 F3 Bb3 F4
        v = S.bell(1.7, f * (1.0 + 0.004 * i), r, decay=0.85 - 0.15 * i,
                   strike=0.35, inharmonic=1.1)
        body = S.place(body, v * (0.95 - 0.18 * i), 0.0)
    body = S.vibrato(body, rate=0.9, depth_cents=14.0)         # the water in it
    body = S.lowpass(body, 2600.0, order=2)                    # drowned: no top
    strike = S.band_noise(0.05, r, 200.0, 2600.0, order=2)
    strike *= S.perc_env(0.05, 0.0006, 0.010)
    wash = S.wet_texture(1.0, r, density=8.0, freq=300.0, spread=2.6, level=0.5)
    y = S.mix(_lvl(body, 1.0), _lvl(S.fit(strike, dur), 0.30),
              _lvl(S.fit(wash, dur), 0.16))
    return _room(y, size=2.0, damping=0.42, mix=0.30, cap=2.60)


@cue("lungeRoar")
def lunge_roar(r):
    """The head comes at you. `bossRoar__brinejaw` with the envelope turned
    inside out: the roar STARTS at full and drives forward, the formants
    open as it closes the distance, and there is no tail to speak of -
    everything about it says the thing is arriving, not announcing."""
    dur = 1.60
    voice = _bjaw_growl(dur, r, f0=58.0, bend=(0.85, 1.34, 1.10), rasp=0.70,
                        sub=0.90, bright=1.15, flutter=29.0, wet=0.30)
    voice *= S.breakpoints(dur, [(0.0, 0.0), (0.035, 1.0), (0.75, 0.95),
                                 (dur, 0.0)], curve="exp")
    rush = S.band_noise(dur, r, 200.0, 7000.0, order=2)
    rush = S.bp_sweep(rush, S.expsweep(dur, 500.0, 2600.0), q=1.8)
    rush *= S.breakpoints(dur, [(0.0, 0.0), (0.12, 0.5), (0.85, 1.0), (dur, 0.0)],
                          curve="exp")
    floor = _sub(dur, 46.0, 62.0, tau=0.9, drive=2.8, attack=0.015)
    y = S.mix(_lvl(S.saturate(voice, 1.8), 1.0), _lvl(rush, 0.32), _lvl(floor, 0.55))
    return _room(y, size=1.7, damping=0.42, mix=0.27, cap=1.95)


@cue("comboWarn")
def combo_warn(r):
    """2D: the chain is coming. Three struck stone notes walking UP, dry and
    close in the player's ears - the only cue on this sheet with no water in
    it at all, which is exactly why it cuts through the fight."""
    dur = 0.62
    out = S.silence(dur)
    for i, f in enumerate((233.08, 311.13, 415.30)):    # Bb3 Eb4 Ab4, rising
        hit = S.mix(_lvl(S.bar(0.24, f, r, decay=0.055, strike=0.95), 1.0),
                    _lvl(S.bar(0.24, f * 2.51, r, decay=0.025, strike=0.7), 0.30),
                    _lvl(_crack(0.03, r, 1500.0, 11000.0, tau=0.004, sweep=False),
                         0.35))
        out = S.place(out, hit * (0.72 + 0.14 * i), i * 0.105)
    return _room(out, size=0.8, damping=0.45, mix=0.16, cap=0.75)
