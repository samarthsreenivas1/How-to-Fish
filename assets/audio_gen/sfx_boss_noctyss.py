"""sfx_boss_noctyss.py - the Trench Mother and her Lantern Choir.

THE FIGHT IS FOUGHT BY EAR. The arena is pitch black, seven angler lanterns
are the only light in it, and the player's job is to find the TRUE lure among
them by listening. Sfx.luau's catalogue block says it outright: this is the
quietest block in the game on purpose, because a choir a player can hear
comfortably from anywhere locates nothing, and leaning in is the whole fight.

HOW "QUIET" IS AUTHORED HERE. build.py peak-normalises every cue to -1 dBFS,
so quietness is NOT a level in this file - the Luau catalogue's `volume`
(0.12 for choirPulse, against 0.85 for slamImpact) is where loudness lives.
What this module controls is everything else that makes a sound read as
quiet and close, and all of it is deliberate:

* NARROW BAND. The choir cues live inside roughly 60-900 Hz. A sound with no
  top end reads as distant-and-soft however loud it is played, and it also
  leaves the whole top of the spectrum free for the ONE bright thing.
* NO TRANSIENTS. Attacks of 40-120 ms on everything in the choir block. A
  transient is what makes the ear place a sound instantly; taking it away is
  what forces the player to keep listening.
* ONE EXCEPTION, PROTECTED. `lanternBreak` is the only sharp dry event in
  the fight and the only sound the player CAUSES, so it gets the top octave
  to itself and a 0.3 ms attack. `jabCrack` is deliberately pitched APART
  from it - one is the boss hitting you, the other is you hitting the boss,
  and they must never be confused.

THE REGISTERS ARE THE PUZZLE. `choirPulse` sits at ~150 Hz, `choirPulseTrue`
a fifth-and-an-octave BELOW it at ~62 Hz and held half again as long. That
gap is the tell the player is hunting, so it is the one number in this file
that must not be nudged for balance.
"""

import numpy as np

import synth as S
from cues import cue


# ---------------------------------------------------------------------------
# the trench: enormous, black, and almost entirely reverb
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


def _room(x, size=2.2, damping=0.60, mix=0.30, predelay=0.030, tail=True,
          cap=None):
    """A shelf at the bottom of a trench. The predelay is long (30 ms - the
    walls are far away and the ceiling is water), the damping is high (deep
    water eats the top end), and the size is the largest on any sheet. It is
    what makes a very small sound feel like it is in a very big place."""
    # See sfx_boss_shared._room. Even here, where the register is low on
    # purpose, energy under 26 Hz is only headroom given away.
    x = S.highpass(x, 26.0, order=2)
    y = S.reverb(x, size=size, damping=damping, mix=mix, predelay=predelay,
                 seed=91, tail=tail)
    if cap is None:
        return y
    y = np.concatenate([np.zeros(S.n(HEAD_LEAD)), y])
    cap = cap + HEAD_LEAD
    y = S.fit(y, cap)
    return y * S.breakpoints(cap, [(0.0, 1.0), (cap * 0.64, 1.0), (cap, 0.0)],
                             curve="exp")


def _lvl(x, amp):
    peak = float(np.max(np.abs(x))) if len(x) else 0.0
    return x * (amp / peak) if peak > 1e-9 else x


def _sub(dur, f0, f1, tau=None, drive=2.4, attack=0.006):
    if tau is None:
        tau = float(dur) * 0.34
    return S.saturate(S.sine(dur, S.expsweep(dur, f0, f1)) *
                      S.perc_env(dur, attack, tau), drive)


# LOOP LEAD-IN. Every filter, comb and noise integrator in synth.py starts
# from ZERO state, so the first 100-300 ms of any filtered bed is quieter
# than the rest. On a one-shot that is invisible (it starts from silence
# anyway); on a LOOP it is a dip once per revolution, which is exactly the
# artefact loop-safety exists to prevent. So a loop here is built LOOP_LEAD
# seconds longer than it ships and the lead is thrown away: by the time the
# retained window starts, everything has reached steady state. Every LFO
# frequency below still divides the SHIPPED length, so slicing off a lead
# does not move where a cycle ends.
LOOP_LEAD = 0.6


def _settle(x, dur, lead=LOOP_LEAD):
    """Drop the filter-startup lead: a loop must start at steady state."""
    return S.fit(np.asarray(x, dtype=np.float64)[S.n(lead):], dur)


# ---------------------------------------------------------------------------
# the materials: breath, flesh, glass
# ---------------------------------------------------------------------------

def _breath(dur, r, f0=150.0, width=0.55, wet=0.45, attack=0.09, hold=0.45,
            vowel=(280.0, 620.0, 1150.0)):
    """LOW WET BREATHING - the choir's whole vocabulary.

    A voiced column: a soft triangle core at `f0` (a triangle, not a saw -
    it has almost no upper harmonics, which is what keeps this inside its
    band), a formant bank giving it a vowel, and a wet noise edge. There is
    no attack transient anywhere: the envelope opens over ~90 ms, which is
    slow enough that the ear has to track it rather than place it.
    """
    tt = S.t(dur)
    drift = 1.0 + 0.02 * np.sin(2.0 * np.pi * 1.4 * tt)
    core = S.tri(dur, f0 * drift) * 0.8 + S.sine(dur, f0 * 2.0 * drift) * 0.22
    throat = S.formant(core, list(vowel), qs=[9.0, 7.0, 5.0],
                       gains=[1.0, 0.5 * width, 0.18 * width])
    voice = S.mix(_lvl(core, 0.55), _lvl(throat, 1.0))
    if wet > 0:
        edge = S.band_noise(dur, r, f0 * 1.5, 2600.0, order=2)
        edge = S.tremolo(edge, rate=9.5, depth=0.5)
        voice = S.mix(voice, _lvl(edge, wet * 0.35))
    env = S.breakpoints(dur, [(0.0, 0.0), (attack, 0.85), (dur * hold, 1.0),
                              (dur * 0.86, 0.55), (dur, 0.0)], curve="exp")
    return S.lowpass(voice * env, 3200.0, order=2)


def _flesh(dur, r, freq=70.0, wet=0.7, drive=2.2):
    """A LIMB. Tonnage with water in it - not a rock and not a splash: a low
    saturated body with a wet, absorbent skin over it. The tentacle cues are
    all built on this, and it is why they never read as stone."""
    body = S.membrane(dur, freq, r, drop=0.55, noise=0.20, tau=dur * 0.26)
    body = S.saturate(body, drive)
    skin = S.band_noise(dur * 0.55, r, 150.0, 3400.0, order=3)
    skin = S.lp_sweep(skin, S.expsweep(dur * 0.55, 3000.0, 320.0), order=2)
    skin *= S.perc_env(dur * 0.55, 0.0025, dur * 0.10, curve=1.3)
    out = S.mix(_lvl(body, 1.0), _lvl(S.fit(skin, dur), wet * 0.55))
    slosh = S.wet_texture(dur, r, density=18.0, freq=170.0, spread=2.8, level=0.5)
    return S.mix(out, _lvl(slosh, wet * 0.28))


def _glass(dur, r, freq=2600.0, count=5, spread=0.30, level=1.0):
    """BREAKING GLASS. The fight's one bright material, and the only place
    in this file allowed a sub-millisecond attack: a hard shatter transient
    plus inharmonic bell partials, then a scatter of falling fragments."""
    out = S.silence(dur)
    out = S.place(out, S.band_noise(0.035, r, freq * 0.5, 18000.0, order=3) *
                  S.perc_env(0.035, 0.0002, 0.0035) * 1.0, 0.0)
    for i in range(count):
        f = freq * (1.0 + 0.42 * i) * (0.9 + 0.2 * float(r.random()))
        out = S.place(out, S.bell(min(dur, 0.30), f, r, decay=0.08 - 0.011 * i,
                                  strike=0.9, inharmonic=1.35) * (0.72 ** i),
                      0.001 * i)
    for _ in range(9):
        at = 0.03 + float(r.random()) * spread
        f = freq * float(2.0 ** (r.random() * 1.7 - 0.6))
        out = S.place(out, S.bell(0.10, f, r, decay=0.022, strike=0.9,
                                  inharmonic=1.5) *
                      (0.06 + 0.14 * float(r.random())), at)
    return S.fit(out, dur) * level


def _noct_growl(dur, r, f0=44.0, bend=(0.95, 1.15, 0.76), rasp=0.4, sub=0.85,
                bright=0.45, flutter=17.0):
    """THE MOTHER'S throat, when she is finally allowed to use it. Dark
    formants placed very low and close (160/480/980), almost no brightness,
    and a strong subharmonic - a voice from something enormous in water that
    has never needed to be heard above anything."""
    contour = S.breakpoints(dur, [(0.0, f0 * bend[0]), (dur * 0.33, f0 * bend[1]),
                                  (dur, f0 * bend[2])], curve="exp")
    core = S.saw(dur, contour, bright=0.55) * 0.55 + S.pulse(dur, contour, 0.38) * 0.4
    core = S.moog(core, S.breakpoints(dur, [(0.0, 240.0), (dur * 0.3, 1200.0 * bright),
                                            (dur, 340.0)], curve="exp"), res=0.32)
    throat = S.formant(core, [160.0, 480.0, 980.0], qs=[12.0, 8.0, 6.0],
                       gains=[1.0, 0.5, 0.16])
    voice = S.mix(_lvl(core, 0.28), _lvl(throat, 0.95))
    if rasp > 0:
        edge = S.band_noise(dur, r, 150.0, 2000.0 * (1.0 + bright), order=2)
        edge = S.tremolo(edge, rate=flutter, depth=0.85)
        edge *= S.breakpoints(dur, [(0.0, 0.0), (0.09, 1.0), (dur, 0.4)])
        voice = S.mix(voice, _lvl(edge, rasp * 0.45))
    if sub > 0:
        low = S.highpass(S.sine(dur, contour * 0.5) +
                         S.sine(dur, contour * 0.25) * 0.5, 28.0, order=4)
        voice = S.mix(voice, _lvl(S.saturate(low, 2.2), sub * 0.9))
    return S.lowpass(voice, 4200.0, order=2)


# ---------------------------------------------------------------------------
# the seven voice variants - the shared vocabulary in the dark
# ---------------------------------------------------------------------------

@cue("bossTell__noctyss")
def tell_noctyss(r):
    """Something in the dark decides. The quietest telegraph in the pack: a
    single low breath that opens and does not resolve, with one small glass
    tick from a lantern somewhere off to the side. The tick is the only
    thing the player can localise, which is the point."""
    dur = 0.90
    out = S.silence(dur)
    out = S.mix(out, _lvl(_breath(dur, r, f0=118.0, width=0.6, wet=0.4, attack=0.12,
                                  hold=0.62, vowel=(240.0, 560.0, 1000.0)), 1.0))
    swell = S.sine(dur, S.expsweep(dur, 44.0, 66.0))
    swell *= S.breakpoints(dur, [(0.0, 0.0), (0.7, 1.0), (dur, 0.1)], curve="exp")
    out = S.mix(out, _lvl(S.saturate(swell, 2.0), 0.40))
    out = S.place(out, _lvl(_glass(0.24, r, freq=4200.0, count=2, spread=0.12),
                            0.22), 0.42)
    return _room(out, size=2.0, mix=0.30, cap=1.35)


@cue("bossRise__noctyss")
def rise_noctyss(r):
    """Trench water displaced by something the size of the arena floor. Slow
    and deep - no splash, because there is no surface down here: just an
    enormous volume of water being moved and the pressure changing."""
    dur = 2.20
    push = S.band_noise(1.9, r, 40.0, 2600.0, order=2)
    push = S.lp_sweep(push, S.breakpoints(1.9, [(0.0, 150.0), (1.4, 900.0),
                                                (1.9, 380.0)], curve="exp"), order=2)
    push = S.tremolo(push, rate=2.2, depth=0.25)
    push *= S.breakpoints(1.9, [(0.0, 0.0), (1.35, 0.85), (1.6, 1.0), (1.9, 0.08)],
                          curve="exp")
    low = S.sine(2.0, S.expsweep(2.0, 30.0, 46.0))
    low *= S.breakpoints(2.0, [(0.0, 0.0), (1.5, 1.0), (2.0, 0.14)], curve="exp")
    out = S.mix(_lvl(S.fit(push, dur), 1.0),
                _lvl(S.fit(S.saturate(low, 2.4), dur), 0.78))
    out = S.place(out, _lvl(S.wet_texture(1.0, r, density=12.0, freq=210.0,
                                          spread=3.0, level=0.5), 0.28), 1.05)
    return _room(out, size=2.4, damping=0.62, mix=0.32, cap=2.70)


@cue("bossRoar__noctyss")
def roar_noctyss(r):
    """She is heard properly, once. Even at full stretch this stays under
    the top of its band: a dark throat, a heavy subharmonic, no rasp to
    speak of and no brightness at all - the loudest quiet thing in the
    game, and it works because everything around it has been softer."""
    dur = 2.40
    voice = _noct_growl(dur, r, f0=42.0, bend=(0.92, 1.22, 0.68), rasp=0.45,
                        sub=1.0, bright=0.5, flutter=15.0)
    voice *= S.breakpoints(dur, [(0.0, 0.0), (0.13, 0.6), (dur * 0.36, 1.0),
                                 (dur * 0.66, 0.8), (dur * 0.93, 0.2), (dur, 0.0)],
                           curve="exp")
    floor = _sub(dur, 46.0, 24.0, tau=1.05, drive=2.9, attack=0.06)
    water = S.band_noise(dur, r, 60.0, 1400.0, order=2)
    water *= S.breakpoints(dur, [(0.0, 0.0), (0.25, 0.7), (dur, 0.0)], curve="exp")
    y = S.mix(_lvl(S.saturate(voice, 1.6), 1.0), _lvl(floor, 0.60), _lvl(water, 0.22))
    return _room(y, size=2.6, damping=0.58, mix=0.33, predelay=0.034, cap=3.00)


@cue("bossSnap__noctyss")
def snap_noctyss(r):
    """A mouth closing in the dark. Wet, low and surprisingly SOFT-edged -
    there is no bone in it. What makes it read as a bite is the two-stage
    close (front then back) and the swallow behind, not a crack."""
    dur = 0.70
    out = S.silence(dur)
    draw = S.band_noise(0.14, r, 150.0, 2200.0, order=2)
    draw = S.bp_sweep(draw, S.expsweep(0.14, 300.0, 900.0), q=2.4)
    draw *= S.breakpoints(0.14, [(0.0, 0.0), (0.11, 1.0), (0.14, 0.0)], curve="exp")
    out = S.place(out, _lvl(draw, 0.42), 0.0)
    for i, at in enumerate((0.105, 0.140)):
        out = S.place(out, _lvl(_flesh(0.32, r, freq=88.0 - 14.0 * i, wet=0.8),
                                0.95 - 0.35 * i), at)
    out = S.place(out, _lvl(_sub(0.45, 84.0, 36.0, tau=0.12, drive=2.6), 0.75), 0.107)
    out = S.place(out, _lvl(S.wet_texture(0.30, r, density=26.0, freq=190.0,
                                          level=0.55), 0.30), 0.15)
    return _room(S.lowpass(out, 4600.0, order=2), size=2.0, damping=0.62, mix=0.26,
                 cap=1.15)


@cue("bossSlam__noctyss")
def slam_noctyss(r):
    """A limb the size of a mast landing across the stone. Wet and heavy
    rather than dry - tonnage with water in it - so the front of it is a
    broad wet impact, not a crack, and what carries is the low end."""
    dur = 1.80
    out = S.silence(dur)
    out = S.place(out, _lvl(S.band_noise(0.10, r, 200.0, 6000.0, order=3) *
                            S.perc_env(0.10, 0.0015, 0.016), 0.55), 0.0)
    out = S.place(out, _lvl(_flesh(0.95, r, freq=52.0, wet=0.75, drive=2.6), 1.0),
                  0.002)
    out = S.place(out, _lvl(_sub(1.40, 54.0, 23.0, tau=0.44, drive=3.0), 0.95), 0.002)
    out = S.place(out, _lvl(S.splash(0.5, r, low=200.0, high=4200.0, sweep_to=220.0,
                                     body=0.4), 0.38), 0.020)
    out = S.place(out, _lvl(S.wet_texture(0.8, r, density=18.0, freq=260.0,
                                          level=0.5), 0.26), 0.12)
    return _room(S.lowpass(out, 6500.0, order=2), size=2.3, damping=0.58, mix=0.30,
                 predelay=0.026, cap=2.35)


@cue("bossDown__noctyss")
def down_noctyss(r):
    """She goes back into the pit. A long descent with the pressure closing
    over it - the filter shuts, the register falls, and there is no impact
    at the end at all, because there is no floor down there worth hitting."""
    dur = 2.60
    out = S.silence(dur)
    sink = S.band_noise(2.0, r, 40.0, 3400.0, order=2)
    sink = S.lp_sweep(sink, S.expsweep(2.0, 2000.0, 160.0), order=2)
    sink *= S.breakpoints(2.0, [(0.0, 0.4), (0.35, 1.0), (2.0, 0.05)], curve="exp")
    out = S.place(out, _lvl(sink, 0.75), 0.0)
    last = _noct_growl(1.4, r, f0=40.0, bend=(1.1, 0.85, 0.50), rasp=0.4, sub=0.95,
                       bright=0.4, flutter=13.0)
    last *= S.breakpoints(1.4, [(0.0, 0.0), (0.14, 0.9), (0.8, 0.45), (1.4, 0.0)],
                          curve="exp")
    out = S.place(out, _lvl(last, 0.85), 0.05)
    out = S.place(out, _lvl(_sub(1.9, 52.0, 19.0, tau=0.80, drive=3.0, attack=0.07),
                            0.85), 0.70)
    out = S.place(out, _lvl(S.wet_texture(1.2, r, density=14.0, freq=180.0,
                                          spread=3.0, level=0.5), 0.28), 1.10)
    return _room(S.lowpass(out, 5200.0, order=2), size=2.6, damping=0.60, mix=0.32,
                 cap=3.05)


@cue("bossStagger__noctyss")
def stagger_noctyss(r):
    """The maw opens the window. The one moment the fight is allowed to be
    LOUD, and it earns it by being the punish - a huge wet arrival with the
    whole shelf answering, and the throat groaning under it for as long as
    the window is open."""
    dur = 2.30
    out = S.silence(dur)
    out = S.place(out, _lvl(S.band_noise(0.14, r, 150.0, 5000.0, order=3) *
                            S.perc_env(0.14, 0.002, 0.022), 0.50), 0.0)
    out = S.place(out, _lvl(_flesh(1.10, r, freq=44.0, wet=0.8, drive=2.8), 1.0), 0.004)
    out = S.place(out, _lvl(_sub(1.75, 48.0, 20.0, tau=0.60, drive=3.1), 1.0), 0.004)
    groan = _noct_growl(1.3, r, f0=44.0, bend=(1.0, 0.84, 0.58), rasp=0.45, sub=0.9,
                        bright=0.45, flutter=14.0)
    groan *= S.breakpoints(1.3, [(0.0, 0.0), (0.18, 1.0), (0.7, 0.5), (1.3, 0.0)],
                           curve="exp")
    out = S.place(out, _lvl(groan, 0.58), 0.35)
    out = S.place(out, _lvl(S.wet_texture(1.1, r, density=20.0, freq=220.0,
                                          level=0.5), 0.28), 0.20)
    return _room(S.lowpass(out, 6000.0, order=2), size=2.5, damping=0.58, mix=0.32,
                 predelay=0.030, cap=2.85)


# ---------------------------------------------------------------------------
# THE CHOIR - the quiet block, and the puzzle
# ---------------------------------------------------------------------------

@cue("choirPulse")
def choir_pulse(r):
    """A DECOY LANTERN BREATHING. One pulse of the cycle, fired per beat at
    a stalk's foot so the caller owns the rhythm.

    ~150 Hz, narrow band, 90 ms attack, nothing above 3 kHz. Six of these in
    unison have to sound like ONE tone - so there is no noise transient and
    almost no random variation in it, because a wobble would smear the very
    rhythm the player is trying to read.
    """
    dur = 0.90
    y = _breath(dur, r, f0=150.0, width=0.55, wet=0.40, attack=0.09, hold=0.42,
                vowel=(300.0, 640.0, 1180.0))
    glow = S.sine(dur, 75.0) * S.breakpoints(dur, [(0.0, 0.0), (0.12, 0.8),
                                                   (0.55, 0.7), (dur, 0.0)],
                                             curve="exp")
    return _room(S.mix(_lvl(y, 1.0), _lvl(S.saturate(glow, 1.8), 0.30)),
                 size=1.9, damping=0.62, mix=0.28, cap=1.30)


@cue("choirPulseTrue")
def choir_pulse_true(r):
    """THE TRUE LURE, findable by ear alone in full darkness.

    The same wet throat as the decoys pitched WELL under them - 62 Hz
    against 150, an octave and a fifth down - and held half again as long,
    so it reads as a DIFFERENT THING BREATHING rather than as the same thing
    standing nearer. Distance changes level; it does not change register,
    which is exactly why register is what carries the tell through a
    strobewave or a room full of decoys.
    """
    dur = 1.30
    y = _breath(dur, r, f0=62.0, width=0.7, wet=0.35, attack=0.13, hold=0.50,
                vowel=(180.0, 430.0, 820.0))
    glow = S.sine(dur, 41.0) * S.breakpoints(dur, [(0.0, 0.0), (0.18, 0.85),
                                                   (0.75, 0.75), (dur, 0.0)],
                                             curve="exp")
    return _room(S.mix(_lvl(y, 1.0), _lvl(S.saturate(glow, 2.0), 0.45)),
                 size=2.1, damping=0.62, mix=0.30, cap=1.75)


@cue("choirBeam")
def choir_beam(r):
    """LIGHTSWEEP: a stalk leans and drags its light across the shelf. An
    ENORMOUS SLOW ARM, not a swing - so it is the bossSweep shape stretched
    until the transient is gone entirely, and only the front of it plays
    (the light itself is the rest). Low in volume, long in reach."""
    dur = 1.45
    lean = S.band_noise(dur, r, 60.0, 3600.0, order=2)
    lean = S.bp_sweep(lean, S.breakpoints(dur, [(0.0, 180.0), (0.55, 520.0),
                                                (1.05, 440.0), (dur, 200.0)],
                                          curve="exp"), q=1.6)
    lean *= S.breakpoints(dur, [(0.0, 0.0), (0.32, 0.55), (0.80, 1.0), (1.15, 0.75),
                                (dur, 0.0)], curve="exp")
    mass = S.sine(dur, S.expsweep(dur, 80.0, 44.0))
    mass *= S.breakpoints(dur, [(0.0, 0.0), (0.80, 1.0), (dur, 0.0)], curve="exp")
    hum = _breath(dur, r, f0=96.0, width=0.4, wet=0.25, attack=0.25, hold=0.55,
                  vowel=(210.0, 470.0, 900.0))
    y = S.mix(_lvl(lean, 1.0), _lvl(S.saturate(mass, 2.2), 0.55), _lvl(hum, 0.35))
    return _room(S.lowpass(y, 5000.0, order=2), size=2.3, damping=0.60, mix=0.30,
                 cap=1.90)


@cue("lanternBreak")
def lantern_break(r):
    """A LANTERN GOING OUT THE HARD WAY. GLASS.

    The one sharp dry transient in the fight and the only sound the player
    CAUSES, so it has to cut cleanly through all that low wet breathing or a
    good shot feels like nothing. It owns the top octave: a hard shatter at
    0.3 ms, inharmonic bell partials well above anything else here, and the
    fragments falling - and then the light it was making goes out, which is
    the small dying hiss underneath.
    """
    dur = 0.90
    out = S.silence(dur)
    out = S.place(out, _lvl(_glass(0.55, r, freq=3400.0, count=6, spread=0.34),
                            1.0), 0.0)
    # The light dying: a thin sizzle that fades rather than stops.
    die = S.band_noise(0.35, r, 2000.0, 12000.0, order=2)
    die = S.lp_sweep(die, S.expsweep(0.35, 9000.0, 1600.0), order=2)
    die *= S.breakpoints(0.35, [(0.0, 0.0), (0.012, 0.9), (0.35, 0.0)], curve="exp")
    out = S.place(out, _lvl(die, 0.35), 0.008)
    out = S.place(out, _lvl(_sub(0.24, 210.0, 96.0, tau=0.045, drive=2.0), 0.22),
                  0.001)
    return _room(out, size=2.0, damping=0.45, mix=0.26, cap=1.15)


@cue("lureFlare")
def lure_flare(r):
    """A FALSE lure breaking: it flares white and the trench answers.
    DELIBERATELY THE WRONG NOTE - a thin bright click where the fight has
    trained the ear to expect a low breath, so the mistake registers before
    the blast that follows it does. Not glass: this is electrical, dry, and
    entirely without body."""
    dur = 0.55
    out = S.silence(dur)
    tick = S.band_noise(0.020, r, 3000.0, 17000.0, order=3)
    tick *= S.perc_env(0.020, 0.0002, 0.0022)
    out = S.place(out, _lvl(tick, 1.0), 0.0)
    for i, f in enumerate((5200.0, 7400.0)):
        out = S.place(out, S.bell(0.16, f, r, decay=0.030, strike=0.9,
                                  inharmonic=1.6) * (0.32 - 0.12 * i), 0.001)
    flare = S.bp_sweep(S.white(0.30, r), S.expsweep(0.30, 6000.0, 13000.0), q=1.8)
    flare *= S.breakpoints(0.30, [(0.0, 0.0), (0.006, 1.0), (0.30, 0.0)], curve="exp")
    out = S.place(out, _lvl(flare, 0.45), 0.002)
    return _room(out, size=1.8, damping=0.40, mix=0.24, cap=0.75)


@cue("choirDouse")
def choir_douse(r):
    """EVERY LANTERN AT ONCE. Nothing is visible for the next second and a
    half, so for that beat THIS SOUND IS THE FIGHT.

    A SWALLOWING WHOOSH: the whole choir being taken away. Everything about
    it descends - seven breaths pitched down and collapsing into one, a
    filter that shuts to nothing, and the deepest note on any boss sheet
    left ringing under the darkness instead of being cut short.
    """
    dur = 2.60
    out = S.silence(dur)
    # Seven voices collapsing together - they start apart and end as one.
    for i in range(7):
        f0 = 150.0 * (0.86 + 0.06 * i)
        v = S.tri(1.0, S.expsweep(1.0, f0, 48.0)) * 0.7
        v = S.lowpass(v, 1800.0, order=2)
        v *= S.breakpoints(1.0, [(0.0, 0.0), (0.05, 0.9), (0.55, 0.7), (1.0, 0.0)],
                           curve="exp")
        out = S.place(out, _lvl(v, 0.30), 0.012 * i)
    # The swallow: a broad rush whose filter closes to nothing.
    pull = S.band_noise(1.30, r, 50.0, 6000.0, order=2)
    pull = S.lp_sweep(pull, S.expsweep(1.30, 4200.0, 140.0), order=2)
    pull *= S.breakpoints(1.30, [(0.0, 0.0), (0.10, 1.0), (0.80, 0.5), (1.30, 0.0)],
                          curve="exp")
    out = S.place(out, _lvl(pull, 0.85), 0.0)
    # And the note that is left. Deeper than anything else in the pack.
    out = S.place(out, _lvl(_sub(2.1, 44.0, 18.0, tau=0.95, drive=3.0, attack=0.10),
                            0.95), 0.30)
    out = S.place(out, _lvl(S.wet_texture(1.1, r, density=10.0, freq=150.0,
                                          spread=3.0, level=0.5), 0.20), 0.55)
    return _room(S.lowpass(out, 4000.0, order=2), size=2.8, damping=0.58, mix=0.34,
                 predelay=0.034, cap=3.05)


# ---------------------------------------------------------------------------
# THE MAW - the punish window
# ---------------------------------------------------------------------------

@cue("mawRise")
def maw_rise(r):
    """The maw coming up through the pit - the WET layer, meant to sit UNDER
    the stagger the open already plays. Slower and deeper than any other
    rise, and heard everywhere, because the window opening is the news the
    party is waiting for."""
    dur = 2.10
    push = S.band_noise(1.85, r, 35.0, 2200.0, order=2)
    push = S.lp_sweep(push, S.breakpoints(1.85, [(0.0, 120.0), (1.35, 700.0),
                                                 (1.85, 300.0)], curve="exp"),
                      order=2)
    push = S.tremolo(push, rate=1.9, depth=0.30)
    push *= S.breakpoints(1.85, [(0.0, 0.0), (1.30, 0.85), (1.55, 1.0), (1.85, 0.06)],
                          curve="exp")
    low = S.sine(1.95, S.expsweep(1.95, 26.0, 42.0))
    low *= S.breakpoints(1.95, [(0.0, 0.0), (1.5, 1.0), (1.95, 0.12)], curve="exp")
    out = S.mix(_lvl(S.fit(push, dur), 1.0),
                _lvl(S.fit(S.saturate(low, 2.6), dur), 0.85))
    out = S.place(out, _lvl(S.wet_texture(1.0, r, density=14.0, freq=175.0,
                                          spread=3.0, level=0.55), 0.30), 1.00)
    return _room(S.lowpass(out, 3800.0, order=2), size=2.6, damping=0.62, mix=0.33,
                 cap=2.60)


@cue("mawBite")
def maw_bite(r):
    """The jaw shutting - the WET half of the bite, layered over the dry
    slam the close already fires. A closing gulp: two wet stages and a
    swallow, so the moment is a MOUTH rather than a rock landing."""
    dur = 0.90
    out = S.silence(dur)
    close = S.band_noise(0.22, r, 90.0, 2600.0, order=2)
    close = S.lp_sweep(close, S.expsweep(0.22, 2200.0, 200.0), order=2)
    close *= S.breakpoints(0.22, [(0.0, 0.0), (0.16, 1.0), (0.22, 0.2)], curve="exp")
    out = S.place(out, _lvl(close, 0.85), 0.0)
    for i, at in enumerate((0.185, 0.235)):
        out = S.place(out, _lvl(_flesh(0.42, r, freq=64.0 - 10.0 * i, wet=0.85),
                                1.0 - 0.38 * i), at)
    out = S.place(out, _lvl(_sub(0.60, 70.0, 28.0, tau=0.18, drive=2.8), 0.85), 0.187)
    out = S.place(out, _lvl(S.wet_texture(0.42, r, density=30.0, freq=160.0,
                                          level=0.6), 0.34), 0.24)
    return _room(S.lowpass(out, 4200.0, order=2), size=2.2, damping=0.62, mix=0.28,
                 cap=1.40)


# ---------------------------------------------------------------------------
# THE THREE TENTACLE ATTACKS - the sound IS the telegraph
# ---------------------------------------------------------------------------

@cue("slamSnuff")
def slam_snuff(r):
    """THE SLAM'S TELL, and it is the LIGHT DYING. The lantern goes out, so
    the windup voice is a sizzle - quiet, close, and cut so it FADES rather
    than ends. Heard once, it teaches "that stalk just went dark and is
    above me", which is the only warning a limb swinging in from behind
    gets in a pitch-black room."""
    dur = 0.65
    out = S.silence(dur)
    sizzle = S.band_noise(0.45, r, 1200.0, 9000.0, order=2)
    sizzle = S.lp_sweep(sizzle, S.expsweep(0.45, 7000.0, 900.0), order=2)
    sizzle = S.tremolo(sizzle, rate=27.0, depth=0.55)
    sizzle *= S.breakpoints(0.45, [(0.0, 0.0), (0.025, 1.0), (0.22, 0.45),
                                   (0.45, 0.0)], curve="exp")
    out = S.place(out, _lvl(sizzle, 1.0), 0.0)
    # The glow going out under it - a low note that simply stops being there.
    glow = S.sine(0.42, S.expsweep(0.42, 96.0, 58.0))
    glow *= S.breakpoints(0.42, [(0.0, 0.0), (0.03, 0.9), (0.42, 0.0)], curve="exp")
    out = S.place(out, _lvl(S.saturate(glow, 2.0), 0.40), 0.0)
    out = S.place(out, _lvl(S.wet_texture(0.25, r, density=20.0, freq=900.0,
                                          level=0.5), 0.20), 0.03)
    return _room(out, size=1.9, damping=0.56, mix=0.26, cap=0.95)


@cue("slamImpact")
def slam_impact(r):
    """The limb landing across the stone. The LOUDEST thing in this block by
    a distance, because it is the one moment that has already hurt you - and
    wet rather than dry, because a tentacle the size of a mast is tonnage
    with water in it."""
    dur = 1.85
    out = S.silence(dur)
    out = S.place(out, _lvl(S.band_noise(0.12, r, 180.0, 6500.0, order=3) *
                            S.perc_env(0.12, 0.0012, 0.018), 0.60), 0.0)
    out = S.place(out, _lvl(_flesh(1.00, r, freq=48.0, wet=0.8, drive=2.7), 1.0), 0.003)
    out = S.place(out, _lvl(_sub(1.45, 52.0, 22.0, tau=0.46, drive=3.0), 0.95), 0.003)
    out = S.place(out, _lvl(S.splash(0.55, r, low=180.0, high=4600.0, sweep_to=200.0,
                                     body=0.45), 0.42), 0.018)
    out = S.place(out, _lvl(S.wet_texture(0.85, r, density=22.0, freq=240.0,
                                          level=0.55), 0.28), 0.10)
    return _room(S.lowpass(out, 6500.0, order=2), size=2.4, damping=0.56, mix=0.31,
                 predelay=0.028, cap=2.40)


@cue("slamPeel")
def slam_peel(r):
    """Peeling back up. LOW, LONG AND UNHURRIED - the recover is the window
    the party moves in, so it wants a sound that says the beat is OVER and
    KEEPS SAYING IT, not a transient that leaves silence to be read as
    safety. So it is entirely sustain: a wet drag lifting off stone with no
    beginning and a very slow end."""
    dur = 1.60
    lift = S.band_noise(dur, r, 45.0, 2600.0, order=2)
    lift = S.bp_sweep(lift, S.breakpoints(dur, [(0.0, 170.0), (0.5, 380.0),
                                                (dur, 150.0)], curve="exp"), q=1.8)
    lift = S.tremolo(lift, rate=4.5, depth=0.35)
    lift *= S.breakpoints(dur, [(0.0, 0.0), (0.30, 0.9), (0.95, 1.0), (dur, 0.0)],
                          curve="exp")
    suck = S.wet_texture(dur, r, density=16.0, freq=200.0, spread=2.8, level=0.55)
    low = S.sine(dur, S.expsweep(dur, 52.0, 33.0))
    low *= S.breakpoints(dur, [(0.0, 0.0), (0.45, 1.0), (dur, 0.0)], curve="exp")
    y = S.mix(_lvl(lift, 1.0), _lvl(suck, 0.32), _lvl(S.saturate(low, 2.4), 0.60))
    return _room(S.lowpass(y, 4200.0, order=2), size=2.3, damping=0.60, mix=0.30,
                 cap=2.05)


@cue("scytheCreak")
def scythe_creak(r):
    """THE SCYTHE bowing down: something enormous taking a set before it
    moves. The only warning that arrives BEFORE the arc lights up, which is
    why it reaches further than its volume suggests. A groan, not a creak in
    the wooden sense - a low resonance bending upward under load."""
    dur = 1.00
    bend = S.band_noise(dur, r, 50.0, 1600.0, order=2)
    bend = S.bp_sweep(bend, S.breakpoints(dur, [(0.0, 120.0), (0.72, 330.0),
                                                (dur, 250.0)], curve="exp"), q=7.0)
    bend = S.tremolo(bend, rate=6.5, depth=0.40)
    bend *= S.breakpoints(dur, [(0.0, 0.0), (0.14, 0.7), (0.78, 1.0), (dur, 0.0)],
                          curve="exp")
    strain = S.sine(dur, S.expsweep(dur, 46.0, 72.0))
    strain *= S.breakpoints(dur, [(0.0, 0.0), (0.75, 1.0), (dur, 0.08)], curve="exp")
    tissue = _flesh(0.7, r, freq=76.0, wet=0.6, drive=2.0)
    tissue *= S.breakpoints(0.7, [(0.0, 0.0), (0.3, 0.6), (0.7, 0.0)], curve="exp")
    y = S.mix(_lvl(bend, 1.0), _lvl(S.saturate(strain, 2.2), 0.55),
              _lvl(S.fit(tissue, dur), 0.28))
    return _room(S.lowpass(y, 3800.0, order=2), size=2.2, damping=0.58, mix=0.29,
                 cap=1.45)


@cue("scytheDrag", loop=True)
def scythe_drag(r):
    """LOOP: the eye dragging along the stone for a second and a half. The
    only loop in the fight, and it has to be WHERE IT IS, continuously, or a
    player in the dark cannot tell an arc coming toward them from one going
    away. Held mid-register - between the choir's breath and the break's
    crack - so it never hides either.

    LOOP-SAFETY. Exactly 1.8 s. The scrape's two modulators run at 5/3 Hz
    and 10/3 Hz, whole cycles across it (3 and 6). It is entirely continuous
    - no triggered event to be cut in half. Built over `LOOP_LEAD` and the
    lead discarded so it starts at steady state, and `tail=False`.
    """
    dur = 1.8
    build = dur + LOOP_LEAD
    tt = S.t(build)
    scrape = S.band_noise(build, r, 200.0, 7000.0, order=2)
    scrape = S.bp_sweep(scrape, 700.0 + 260.0 *
                        np.sin(2.0 * np.pi * (5.0 / 3.0) * tt), q=2.2)
    rough = (0.68 + 0.32 * np.sin(2.0 * np.pi * (10.0 / 3.0) * tt)) * \
            (0.82 + 0.18 * np.sin(2.0 * np.pi * (5.0 / 3.0) * tt + 0.9))
    scrape = scrape * rough
    # The wet underside: the limb itself, not the stone it is crossing.
    wet = S.band_noise(build, r, 90.0, 1400.0, order=2)
    wet = S.tremolo(wet, rate=10.0 / 3.0, depth=0.4)
    body = S.tri(build, 132.0) * 0.5
    body = S.lowpass(body, 900.0, order=2) * rough
    y = S.mix(_lvl(_settle(scrape, dur), 1.0), _lvl(_settle(wet, dur), 0.35),
              _lvl(_settle(body, dur), 0.30))
    y = S.lowpass(y, 8000.0, order=2)
    return _room(y, size=2.0, damping=0.58, mix=0.20, tail=False)


@cue("jabCoil")
def jab_coil(r):
    """THE JAB coiling. SHORT, THIN AND UP TOP - a quick intake against the
    fight's low breathing, which is what makes a third of a second's warning
    worth having at all. It is the highest-pitched sustained thing in the
    block, and the only one that rises."""
    dur = 0.42
    draw = S.band_noise(dur, r, 400.0, 7000.0, order=2)
    draw = S.bp_sweep(draw, S.expsweep(dur, 700.0, 2600.0), q=3.2)
    draw *= S.breakpoints(dur, [(0.0, 0.0), (0.06, 0.6), (0.30, 1.0), (dur, 0.0)],
                          curve="exp")
    tighten = S.sine(dur, S.expsweep(dur, 320.0, 780.0))
    tighten *= S.breakpoints(dur, [(0.0, 0.0), (0.30, 0.7), (dur, 0.0)], curve="exp")
    y = S.mix(_lvl(draw, 1.0), _lvl(tighten, 0.30))
    return _room(y, size=1.7, damping=0.52, mix=0.24, cap=0.70)


@cue("jabCrack")
def jab_crack(r):
    """The thrust: A WHIP-CRACK. The same class of dry transient
    `lanternBreak` uses, but PITCHED APART from it on purpose - the break is
    glass in the top octave, this is a mid-high snap with a body under it.
    One is the boss hitting you and one is you hitting the boss, and they
    must never share a sound."""
    dur = 0.60
    out = S.silence(dur)
    crack = S.band_noise(0.045, r, 900.0, 9000.0, order=3)
    crack = S.lp_sweep(crack, S.expsweep(0.045, 8000.0, 1200.0), order=2)
    crack *= S.perc_env(0.045, 0.0003, 0.0045, curve=1.2)
    out = S.place(out, _lvl(crack, 1.0), 0.0)
    for i, f in enumerate((880.0, 1310.0)):
        out = S.place(out, S.bar(0.18, f, r, decay=0.028 - 0.008 * i,
                                 strike=0.95) * (0.45 - 0.15 * i), 0.001)
    # The tip snapping past: a very fast falling whistle behind the crack.
    tail = S.bp_sweep(S.white(0.16, r), S.expsweep(0.16, 4200.0, 1100.0), q=6.0)
    tail *= S.breakpoints(0.16, [(0.0, 0.0), (0.008, 0.9), (0.16, 0.0)], curve="exp")
    out = S.place(out, _lvl(tail, 0.42), 0.004)
    out = S.place(out, _lvl(_sub(0.26, 150.0, 70.0, tau=0.05, drive=2.2), 0.32), 0.002)
    return _room(out, size=1.9, damping=0.50, mix=0.25, cap=0.85)
