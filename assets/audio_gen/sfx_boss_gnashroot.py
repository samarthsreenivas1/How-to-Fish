"""sfx_boss_gnashroot.py - Old Gnashroot, the fen standing up.

THE VOICE: WET WOOD. A hunched colossus of mud, roots and teeth hauling
itself out of a mere. Three materials and nothing else:

* WOOD UNDER STRAIN (`_creak`). Not a knock - a CREAK, which is stick-slip:
  a resonant band of noise chopped by an irregular, slowing tremolo, so it
  sounds like fibres letting go one after another rather than like a tone.
  Every big move here creaks before it lands, and that creak is the tell.
* PEAT (`_slop`). The fen's impact material, and the reason nothing on this
  sheet is bright: mud absorbs the top end. A slop is a heavily low-passed
  noise burst with a sucking tail - the suck is what says the ground is
  wet, and it is the one thing that makes this boss's slam unmistakable
  next to Pyrelisk's rock or Rimefang's ice.
* WOODEN TEETH (`_teeth`). Bars in a low cluster with almost no ring,
  played several times in a row at an accelerating rate. Gnashing is a
  RHYTHM, not a hit.

THE ROOM IS SMALL AND DEAD. `_room` here is a fog-bound mere: short, very
damped, with the top rolled off everything. Every other boss gets an arena
that answers; this one gets a swamp that swallows, which is most of why the
fight sounds close and heavy even though the animal is enormous.
"""

import numpy as np

import synth as S
from cues import cue


# ---------------------------------------------------------------------------
# the mere: fog, peat and standing water
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


def _room(x, size=1.15, damping=0.72, mix=0.24, predelay=0.008, tail=True,
          cap=None):
    """Close, wet and dead. High damping is the fog: it eats the highs long
    before it eats the lows, which is what a room full of water vapour and
    reeds does. `cap` fixes the sprite length (see sfx_boss_shared)."""
    # ONE INFRASONIC HIGH-PASS FOR THE WHOLE SHEET. Layered saturated subs
    # and brown-noise rumbles put real energy under 20 Hz, where no speaker
    # a player owns reproduces anything - but build.py peak-normalises every
    # cue, so that energy is paid for by turning the AUDIBLE part down. A
    # 26 Hz high-pass here is the difference between a slam that measures
    # big and a slam that sounds big.
    x = S.highpass(x, 26.0, order=2)
    y = S.reverb(x, size=size, damping=damping, mix=mix, predelay=predelay,
                 seed=61, tail=tail)
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


def _sub(dur, f0, f1, tau=None, drive=2.4, attack=0.002):
    if tau is None:
        tau = float(dur) * 0.34
    return S.saturate(S.sine(dur, S.expsweep(dur, f0, f1)) *
                      S.perc_env(dur, attack, tau), drive)


def _creak(dur, r, freq=180.0, rate=22.0, slow=0.55, rough=0.75):
    """WOOD UNDER STRAIN. Stick-slip, not a knock.

    A resonant band chopped by a tremolo whose rate FALLS across the sound
    (`slow`): fibres let go faster at first and then the timber settles.
    Two resonators a fifth apart give it a pitch without giving it a note.
    """
    src = S.band_noise(dur, r, freq * 0.6, freq * 14.0, order=2)
    tone = S.mix(_lvl(S.resonator(src, freq, q=22.0), 1.0),
                 _lvl(S.resonator(src, freq * 1.51, q=16.0), 0.55),
                 _lvl(S.resonator(src, freq * 2.63, q=11.0), 0.25))
    # The chop: an LFO whose rate decays, rectified hard so it is a series
    # of grabs rather than a wobble.
    tt = S.t(dur)
    phase = (rate / max(0.05, slow)) * (1.0 - np.exp(-tt * slow))
    chop = 0.5 + 0.5 * np.sin(2.0 * np.pi * phase)
    chop = chop ** (1.0 + 3.0 * rough)
    y = tone * (0.18 + 0.82 * chop)
    return S.lowpass(y, 4200.0, order=2)


def _slop(dur, r, freq=90.0, wet=0.65, suck=0.5):
    """PEAT. A heavily low-passed impact with a SUCKING tail - the mud
    closing over whatever just hit it. The suck is a band of noise whose
    filter opens backwards, which is the only way a one-shot reads as
    something being pulled out rather than pushed in."""
    body = S.membrane(dur, freq, r, drop=0.55, noise=0.42, tau=dur * 0.22)
    body = S.lowpass(S.saturate(body, 2.2), 900.0, order=2)
    splat = S.band_noise(dur * 0.5, r, 120.0, 2600.0, order=3)
    splat = S.lp_sweep(splat, S.expsweep(dur * 0.5, 2200.0, 260.0), order=2)
    splat *= S.perc_env(dur * 0.5, 0.001, dur * 0.09, curve=1.4)
    out = S.mix(_lvl(body, 1.0), _lvl(S.fit(splat, dur), wet))
    if suck > 0:
        pull = S.band_noise(dur * 0.55, r, 150.0, 1800.0, order=2)
        pull = S.bp_sweep(pull, S.expsweep(dur * 0.55, 280.0, 900.0), q=2.6)
        pull *= S.breakpoints(dur * 0.55, [(0.0, 0.0), (dur * 0.44, 1.0),
                                           (dur * 0.55, 0.0)], curve="exp")
        out = S.place(out, _lvl(pull, suck * 0.45), dur * 0.28)
    return out


def _teeth(dur, r, freq=150.0, count=5, accel=0.86, spacing=0.075):
    """GNASHING. Wooden teeth meeting, several times, SPEEDING UP. Bars with
    a fast decay and a dry click - almost no ring, because wet wood has
    none - and the acceleration is what makes it a jaw rather than a
    metronome."""
    out = S.silence(dur)
    at = 0.0
    gap = spacing
    for i in range(count):
        f = freq * (0.90 + 0.22 * float(r.random()))
        one = S.mix(_lvl(S.bar(0.16, f, r, decay=0.022, strike=0.9), 1.0),
                    _lvl(S.bar(0.16, f * 1.87, r, decay=0.014, strike=0.7), 0.40),
                    _lvl(S.band_noise(0.008, r, 700.0, 6500.0) *
                         S.perc_env(0.008, 0.0003, 0.002), 0.45))
        out = S.place(out, one * (0.62 + 0.38 * float(r.random())), at)
        at += gap
        gap *= accel
    return S.fit(S.lowpass(out, 6000.0, order=2), dur)


def _gurgle(dur, r, freq=130.0, density=22.0, level=0.6):
    """WET GUTS. Big slow bubbles, an octave under anything the fishing
    sheet uses - a bubble's pitch is its size, so low bubbles read as a
    large body of standing water rather than as a bobber."""
    y = S.wet_texture(dur, r, density=density, freq=freq, spread=3.0, level=level)
    return S.lowpass(y, 2400.0, order=2)


def _gnash_growl(dur, r, f0=50.0, bend=(0.92, 1.18, 0.72), rasp=0.60, sub=0.85,
                 bright=0.7, flutter=19.0, gurgle=0.45):
    """A throat with a bog in it. Formants low and DARK (200/520/1150 - a
    mouth full of mud, not a resonant cavern), a slow flutter (this thing is
    huge and slow), and gurgle running through the whole vocalisation."""
    contour = S.breakpoints(dur, [(0.0, f0 * bend[0]), (dur * 0.34, f0 * bend[1]),
                                  (dur, f0 * bend[2])], curve="exp")
    core = S.saw(dur, contour, bright=0.7) * 0.6 + S.pulse(dur, contour, 0.34) * 0.45
    core = S.moog(core, S.breakpoints(dur, [(0.0, 300.0), (dur * 0.3, 1500.0 * bright),
                                            (dur, 420.0)], curve="exp"), res=0.34)
    throat = S.formant(core, [200.0, 520.0, 1150.0], qs=[11.0, 8.0, 6.0],
                       gains=[1.0, 0.55, 0.20])
    voice = S.mix(_lvl(core, 0.32), _lvl(throat, 0.95))
    if rasp > 0:
        edge = S.band_noise(dur, r, 180.0, 2600.0 * bright, order=2)
        edge = S.tremolo(edge, rate=flutter, depth=0.9)
        edge *= S.breakpoints(dur, [(0.0, 0.0), (0.05, 1.0), (dur, 0.35)])
        voice = S.mix(voice, _lvl(edge, rasp * 0.45))
    if sub > 0:
        # High-passed at 26 Hz - see sfx_boss_shared._growl. Below that the
        # subharmonic is headroom and DC offset, not weight.
        low = S.sine(dur, contour * 0.5) + S.sine(dur, contour * 0.25) * 0.5
        low = S.highpass(low, 26.0, order=2)
        voice = S.mix(voice, _lvl(S.saturate(low, 2.2), sub * 0.9))
    if gurgle > 0:
        voice = S.mix(voice, _lvl(_gurgle(dur, r, freq=140.0, density=26.0),
                                  gurgle * 0.4))
    return S.lowpass(voice, 5200.0, order=2)


# ---------------------------------------------------------------------------
# the seven voice variants - the shared vocabulary in wet wood
# ---------------------------------------------------------------------------

# NOTE THE SUFFIX. This boss's voice key is `old_gnashroot`, not
# `gnashroot` - it is the creature id, and cues.BOSS_VOICES maps it to the
# `boss_gnashroot` SHEET. Decorating `bossTell__gnashroot` would raise at
# import, which is the registry doing its job.

@cue("bossTell__old_gnashroot")
def tell_gnashroot(r):
    """The mass takes a set. Timber creaking under load and one wet intake -
    the creak is the whole warning, because everything this boss does is
    preceded by wood complaining."""
    dur = 0.85
    creak = _creak(0.70, r, freq=132.0, rate=17.0, slow=0.9, rough=0.8)
    creak *= S.breakpoints(0.70, [(0.0, 0.0), (0.10, 0.8), (0.55, 1.0), (0.70, 0.0)],
                           curve="exp")
    intake = S.band_noise(dur, r, 150.0, 2400.0, order=2)
    intake = S.bp_sweep(intake, S.expsweep(dur, 300.0, 980.0), q=2.4)
    intake *= S.breakpoints(dur, [(0.0, 0.0), (0.66, 1.0), (dur, 0.0)], curve="exp")
    swell = S.sine(dur, S.expsweep(dur, 44.0, 70.0))
    swell *= S.breakpoints(dur, [(0.0, 0.0), (0.72, 1.0), (dur, 0.1)], curve="exp")
    y = S.mix(_lvl(S.fit(creak, dur), 1.0), _lvl(intake, 0.45),
              _lvl(S.saturate(swell, 2.0), 0.40),
              _lvl(_gurgle(0.6, r, freq=160.0, density=12.0), 0.20))
    return _room(y, size=1.0, mix=0.22, cap=1.15)


@cue("bossRise__old_gnashroot")
def rise_gnashroot(r):
    """It hauls out of the mere. Peat letting go of something enormous: a
    long suck, timber straining the whole way up, and water running back
    down off it. There is no splash - mud does not splash, it releases."""
    dur = 2.10
    suck = S.band_noise(1.7, r, 90.0, 3000.0, order=2)
    suck = S.bp_sweep(suck, S.breakpoints(1.7, [(0.0, 220.0), (1.25, 820.0),
                                                (1.7, 380.0)], curve="exp"), q=2.0)
    suck = S.tremolo(suck, rate=6.5, depth=0.30)
    suck *= S.breakpoints(1.7, [(0.0, 0.0), (1.15, 0.85), (1.4, 1.0), (1.7, 0.05)],
                          curve="exp")
    timber = _creak(1.5, r, freq=104.0, rate=13.0, slow=0.6, rough=0.7)
    timber *= S.breakpoints(1.5, [(0.0, 0.0), (0.3, 0.8), (1.2, 1.0), (1.5, 0.0)],
                            curve="exp")
    low = S.sine(1.9, S.expsweep(1.9, 28.0, 48.0))
    low *= S.breakpoints(1.9, [(0.0, 0.0), (1.45, 1.0), (1.9, 0.15)], curve="exp")
    out = S.mix(_lvl(S.fit(suck, dur), 1.0), _lvl(S.fit(timber, dur), 0.60),
                _lvl(S.fit(S.saturate(low, 2.4), dur), 0.70))
    out = S.place(out, _lvl(_gurgle(0.9, r, freq=120.0, density=24.0), 0.35), 1.25)
    return _room(out, size=1.5, damping=0.68, mix=0.26, cap=2.55)


@cue("bossRoar__old_gnashroot")
def roar_gnashroot(r):
    """The bellow. A bog-dark throat - low, thick and gurgling, with the
    subharmonic under it and no brightness anywhere. It is a big sound that
    never gets sharp, which is what a hundred tons of wet mud shouting is."""
    dur = 2.10
    voice = _gnash_growl(dur, r, f0=47.0, bend=(0.88, 1.22, 0.66), rasp=0.66,
                         sub=0.95, gurgle=0.55)
    voice *= S.breakpoints(dur, [(0.0, 0.0), (0.08, 0.7), (dur * 0.32, 1.0),
                                 (dur * 0.60, 0.78), (dur * 0.92, 0.2), (dur, 0.0)],
                           curve="exp")
    floor = _sub(dur, 48.0, 25.0, tau=0.9, drive=2.8, attack=0.03)
    timber = _creak(1.1, r, freq=118.0, rate=15.0, slow=0.8, rough=0.6)
    timber *= S.breakpoints(1.1, [(0.0, 0.0), (0.15, 1.0), (1.1, 0.0)], curve="exp")
    y = S.mix(_lvl(S.saturate(voice, 1.7), 1.0), _lvl(floor, 0.58),
              _lvl(S.fit(timber, dur), 0.24))
    return _room(y, size=1.6, damping=0.62, mix=0.28, predelay=0.014, cap=2.55)


@cue("bossSnap__old_gnashroot")
def snap_gnashroot(r):
    """The gape shutting. Wooden teeth meeting hard - one big strike and
    two smaller ones behind it as the jaw settles, over a wet swallow."""
    dur = 0.62
    out = S.silence(dur)
    out = S.place(out, _lvl(S.band_noise(0.09, r, 300.0, 4200.0, order=3) *
                            S.perc_env(0.09, 0.0008, 0.016), 0.40), 0.0)
    out = S.place(out, _lvl(_teeth(0.42, r, freq=138.0, count=3, accel=0.72,
                                   spacing=0.055), 1.0), 0.060)
    out = S.place(out, _lvl(_sub(0.36, 90.0, 40.0, tau=0.09, drive=2.5), 0.75), 0.061)
    out = S.place(out, _lvl(_slop(0.30, r, freq=105.0, wet=0.7, suck=0.35), 0.55),
                  0.068)
    return _room(out, size=1.0, damping=0.70, mix=0.20, cap=0.95)


@cue("bossSlam__old_gnashroot")
def slam_gnashroot(r):
    """Both arms into the peat. The fen's slam: almost no crack at all,
    because mud has none - it is a low body, a wide slop and a suck, and
    the timber complaining a beat after the ground has taken it."""
    dur = 1.65
    out = S.silence(dur)
    out = S.place(out, _lvl(S.band_noise(0.10, r, 200.0, 5000.0, order=3) *
                            S.perc_env(0.10, 0.0006, 0.014), 0.45), 0.0)
    out = S.place(out, _lvl(_slop(0.85, r, freq=66.0, wet=0.75, suck=0.6), 1.0), 0.002)
    out = S.place(out, _lvl(_sub(1.20, 58.0, 24.0, tau=0.36, drive=2.9), 0.95), 0.002)
    creak = _creak(0.75, r, freq=112.0, rate=16.0, slow=1.0, rough=0.75)
    creak *= S.breakpoints(0.75, [(0.0, 0.0), (0.06, 1.0), (0.75, 0.0)], curve="exp")
    out = S.place(out, _lvl(creak, 0.42), 0.055)
    out = S.place(out, _lvl(_gurgle(0.8, r, freq=150.0, density=20.0), 0.28), 0.12)
    return _room(S.lowpass(out, 6000.0, order=2), size=1.5, damping=0.66, mix=0.26,
                 cap=2.05)


@cue("bossDown__old_gnashroot")
def down_gnashroot(r):
    """It goes back into the mere. A long collapse: the frame giving way,
    the body sliding, and the peat closing over it - and the last thing
    audible is the gurgle, not the impact."""
    dur = 2.50
    out = S.silence(dur)
    give = _creak(1.1, r, freq=92.0, rate=20.0, slow=1.6, rough=0.85)
    give *= S.breakpoints(1.1, [(0.0, 0.0), (0.08, 1.0), (0.7, 0.6), (1.1, 0.0)],
                          curve="exp")
    out = S.place(out, _lvl(give, 0.70), 0.0)
    fail = _gnash_growl(1.2, r, f0=42.0, bend=(1.1, 0.84, 0.52), rasp=0.5, sub=0.9,
                        bright=0.5, gurgle=0.6)
    fail *= S.breakpoints(1.2, [(0.0, 0.0), (0.12, 0.9), (0.7, 0.45), (1.2, 0.0)],
                          curve="exp")
    out = S.place(out, _lvl(fail, 0.72), 0.06)
    out = S.place(out, _lvl(_slop(1.1, r, freq=50.0, wet=0.8, suck=0.85), 0.95), 0.95)
    out = S.place(out, _lvl(_sub(1.6, 56.0, 20.0, tau=0.60, drive=2.9, attack=0.04),
                            0.88), 0.95)
    out = S.place(out, _lvl(_gurgle(1.1, r, freq=110.0, density=26.0), 0.40), 1.20)
    return _room(S.lowpass(out, 5600.0, order=2), size=1.7, damping=0.66, mix=0.28,
                 cap=2.90)


@cue("bossStagger__old_gnashroot")
def stagger_gnashroot(r):
    """THE EARNED OPENING. It plants both arms and the chest pitches
    forward. Timber tearing, then the whole mass arriving in the peat, then
    a long strained groan while the core is open - the groan is the window,
    so it is the part that is left running."""
    dur = 2.05
    out = S.silence(dur)
    tear = _creak(0.45, r, freq=98.0, rate=30.0, slow=2.2, rough=0.9)
    tear *= S.breakpoints(0.45, [(0.0, 0.0), (0.05, 1.0), (0.45, 0.0)], curve="exp")
    out = S.place(out, _lvl(tear, 0.65), 0.0)
    out = S.place(out, _lvl(_slop(1.0, r, freq=52.0, wet=0.8, suck=0.7), 1.0), 0.34)
    out = S.place(out, _lvl(_sub(1.55, 50.0, 20.0, tau=0.52, drive=3.0), 1.0), 0.34)
    out = S.place(out, _lvl(_teeth(0.3, r, freq=120.0, count=2, accel=0.8,
                                   spacing=0.09), 0.35), 0.35)
    groan = _gnash_growl(1.1, r, f0=45.0, bend=(1.0, 0.8, 0.58), rasp=0.5, sub=0.85,
                         bright=0.55, gurgle=0.5)
    groan *= S.breakpoints(1.1, [(0.0, 0.0), (0.15, 1.0), (0.65, 0.5), (1.1, 0.0)],
                           curve="exp")
    out = S.place(out, _lvl(groan, 0.58), 0.46)
    out = S.place(out, _lvl(_gurgle(0.9, r, freq=130.0, density=22.0), 0.26), 0.55)
    return _room(S.lowpass(out, 6000.0, order=2), size=1.6, damping=0.64, mix=0.28,
                 cap=2.50)


# ---------------------------------------------------------------------------
# the fen's own nine
# ---------------------------------------------------------------------------

@cue("gnashBite")
def gnash_bite(r):
    """THE GAPE. It takes a bite out of the bank. Gnashing wooden teeth -
    five strikes accelerating into one another - with the bank coming away
    underneath and a wet swallow at the end. The acceleration is the cue's
    whole identity: this is the boss the fight is named for."""
    dur = 0.95
    out = S.silence(dur)
    lead = S.band_noise(0.12, r, 250.0, 3800.0, order=3)
    lead = S.lp_sweep(lead, S.expsweep(0.12, 3200.0, 500.0), order=2)
    lead *= S.perc_env(0.12, 0.001, 0.022)
    out = S.place(out, _lvl(lead, 0.42), 0.0)
    out = S.place(out, _lvl(_teeth(0.60, r, freq=146.0, count=5, accel=0.80,
                                   spacing=0.085), 1.0), 0.055)
    out = S.place(out, _lvl(_slop(0.45, r, freq=88.0, wet=0.7, suck=0.55), 0.62), 0.075)
    out = S.place(out, _lvl(_sub(0.55, 96.0, 42.0, tau=0.14, drive=2.5), 0.65), 0.056)
    out = S.place(out, _lvl(_gurgle(0.45, r, freq=170.0, density=24.0), 0.28), 0.30)
    return _room(out, size=1.1, damping=0.68, mix=0.22, cap=1.25)


@cue("gnashWallow")
def gnash_wallow(r):
    """IT BECOMES A WAVE. The whole mass surges forward in a line and leaves
    half of itself behind. A long low ploughing rush with peat turning over
    inside it - no transient, because a wall of mud arrives the way a wall
    of water does."""
    dur = 1.35
    plough = S.band_noise(dur, r, 55.0, 3200.0, order=2)
    plough = S.lp_sweep(plough, S.breakpoints(dur, [(0.0, 240.0), (0.75, 1300.0),
                                                    (dur, 320.0)], curve="exp"),
                        order=2)
    plough *= S.breakpoints(dur, [(0.0, 0.0), (0.55, 0.8), (0.85, 1.0), (dur, 0.05)],
                            curve="exp")
    plough = S.tremolo(plough, rate=4.2, depth=0.30)
    mass = S.sine(dur, S.expsweep(dur, 32.0, 52.0))
    mass *= S.breakpoints(dur, [(0.0, 0.0), (0.9, 1.0), (dur, 0.08)], curve="exp")
    turn = S.silence(dur)
    for _ in range(6):
        at = 0.15 + float(r.random()) * 0.95
        turn = S.place(turn, _lvl(_slop(0.26, r, freq=120.0 *
                                        float(2.0 ** (r.random() - 0.5)),
                                        wet=0.8, suck=0.4),
                                  0.28 + 0.3 * float(r.random())), at)
    y = S.mix(_lvl(plough, 1.0), _lvl(S.saturate(mass, 2.4), 0.62), _lvl(turn, 0.45),
              _lvl(_gurgle(dur, r, freq=140.0, density=14.0), 0.20))
    return _room(S.lowpass(y, 5000.0, order=2), size=1.4, damping=0.70, mix=0.25,
                 cap=1.80)


@cue("gnashDisgorge")
def gnash_disgorge(r):
    """It brings the mere up and throws it. A wet heave from deep in the
    body, then the gobs leaving - the heave is long and the launch is
    short, which is the way round that makes it read as effort."""
    dur = 0.95
    out = S.silence(dur)
    heave = _gnash_growl(0.46, r, f0=64.0, bend=(0.8, 1.45, 1.05), rasp=0.8, sub=0.5,
                         bright=0.8, flutter=26.0, gurgle=0.8)
    heave *= S.breakpoints(0.46, [(0.0, 0.0), (0.06, 0.7), (0.34, 1.0), (0.46, 0.0)],
                           curve="exp")
    out = S.place(out, _lvl(heave, 0.95), 0.0)
    for i in range(3):
        at = 0.40 + i * 0.065 + 0.02 * float(r.random())
        launch = S.bp_sweep(S.white(0.13, r), S.expsweep(0.13, 480.0, 1500.0), q=2.4)
        launch *= S.perc_env(0.13, 0.0015, 0.030)
        out = S.place(out, _lvl(launch, 0.55 - 0.10 * i), at)
        out = S.place(out, _lvl(_gurgle(0.18, r, freq=220.0, density=30.0),
                                0.30), at)
    out = S.place(out, _lvl(_sub(0.4, 100.0, 48.0, tau=0.10, drive=2.2), 0.45), 0.40)
    return _room(S.lowpass(out, 6500.0, order=2), size=1.1, damping=0.68, mix=0.21,
                 cap=1.20)


@cue("gnashHeave")
def gnash_heave(r):
    """IT GOES UNDER THE PEAT. A hump racing out from a planted hand: the
    ground bulging (a rising, muffled low rush), then the rank breaking
    surface in a run of slops. Everything is heard THROUGH mud until the
    moment it comes up, which is the filter opening."""
    dur = 1.40
    out = S.silence(dur)
    under = S.band_noise(0.85, r, 40.0, 2200.0, order=2)
    under = S.lp_sweep(under, S.expsweep(0.85, 180.0, 900.0), order=2)
    under *= S.breakpoints(0.85, [(0.0, 0.0), (0.6, 0.85), (0.85, 1.0)], curve="exp")
    out = S.place(out, _lvl(under, 0.80), 0.0)
    out = S.place(out, _lvl(_sub(1.0, 34.0, 58.0, tau=0.55, drive=2.6, attack=0.06),
                            0.75), 0.0)
    for i in range(4):
        at = 0.80 + i * 0.075
        out = S.place(out, _lvl(_slop(0.34, r, freq=86.0 + 10.0 * i, wet=0.75,
                                      suck=0.45), 0.85 - 0.14 * i), at)
        out = S.place(out, _lvl(_sub(0.32, 84.0, 40.0, tau=0.08, drive=2.4),
                                0.50 - 0.08 * i), at)
    out = S.place(out, _lvl(_gurgle(0.5, r, freq=160.0, density=26.0), 0.28), 0.90)
    return _room(S.lowpass(out, 5200.0, order=2), size=1.3, damping=0.70, mix=0.24,
                 cap=1.85)


@cue("gnashMire")
def gnash_mire(r):
    """The ground softening under you. A slow suck with nothing struck in
    it at all - the only cue on the sheet with no impact, because the
    hazard IS the absence of footing. Quiet, close and continuous."""
    dur = 1.15
    pull = S.band_noise(dur, r, 80.0, 2000.0, order=2)
    pull = S.bp_sweep(pull, S.breakpoints(dur, [(0.0, 200.0), (0.7, 620.0),
                                                (dur, 260.0)], curve="exp"), q=2.2)
    pull = S.tremolo(pull, rate=3.1, depth=0.35)
    pull *= S.breakpoints(dur, [(0.0, 0.0), (0.30, 0.8), (0.80, 1.0), (dur, 0.0)],
                          curve="exp")
    seep = _gurgle(dur, r, freq=200.0, density=20.0, level=0.55)
    low = S.brown(dur, r)
    low = S.lowpass(low, 110.0, order=2)
    low *= S.breakpoints(dur, [(0.0, 0.0), (0.6, 1.0), (dur, 0.05)], curve="exp")
    y = S.mix(_lvl(pull, 1.0), _lvl(seep, 0.38), _lvl(S.saturate(low, 2.0), 0.35))
    return _room(S.lowpass(y, 4200.0, order=2), size=1.2, damping=0.74, mix=0.24,
                 cap=1.55)


@cue("gnashHammerfall")
def gnash_hammerfall(r):
    """A TREE TRUNK LANDING. The one moment in the fight that is pure wood:
    a huge hollow bar struck at 44 Hz with its own splitting crack on top,
    the peat taking it, and the trunk's low partials ringing on afterwards.
    It is the heaviest cue here and the loudest thing the fen ever does."""
    dur = 2.00
    out = S.silence(dur)
    # The split: the timber's own fibres letting go, ahead of the landing.
    out = S.place(out, _lvl(S.band_noise(0.12, r, 400.0, 9000.0, order=3) *
                            S.perc_env(0.12, 0.0004, 0.010), 0.70), 0.0)
    # The trunk: low bar partials with almost no inharmonicity - a log rings.
    trunk = S.silence(1.2)
    for i, ratio in enumerate((1.0, 2.14, 3.71, 5.62)):
        exc = S.fit(S.white(0.005, r) * S.perc_env(0.005, 0.0002, 0.0012), 1.2)
        trunk = S.mix(trunk, S.resonator(exc, 44.0 * ratio, q=26.0 - 4.0 * i) /
                      (i + 1.2))
    trunk *= S.expdec(1.2, 0.26)
    out = S.place(out, _lvl(S.saturate(trunk, 2.4), 0.95), 0.004)
    out = S.place(out, _lvl(_sub(1.45, 54.0, 21.0, tau=0.44, drive=3.0), 1.0), 0.004)
    out = S.place(out, _lvl(_slop(0.75, r, freq=70.0, wet=0.8, suck=0.6), 0.70), 0.006)
    settle = _creak(0.9, r, freq=88.0, rate=11.0, slow=1.4, rough=0.8)
    settle *= S.breakpoints(0.9, [(0.0, 0.0), (0.10, 0.8), (0.9, 0.0)], curve="exp")
    out = S.place(out, _lvl(settle, 0.32), 0.16)
    out = S.place(out, _lvl(_gurgle(0.9, r, freq=140.0, density=18.0), 0.24), 0.20)
    return _room(out, size=1.7, damping=0.60, mix=0.27, predelay=0.012, cap=2.45)


@cue("gnashRootCreak")
def gnash_root_creak(r):
    """Roots taking the strain. The pure form of the material - two creaks
    a fifth apart, the second answering the first, and nothing else. This is
    the sound the whole sheet is built out of, played alone."""
    dur = 1.20
    out = S.silence(dur)
    a = _creak(0.85, r, freq=126.0, rate=14.0, slow=0.7, rough=0.8)
    a *= S.breakpoints(0.85, [(0.0, 0.0), (0.12, 0.9), (0.6, 1.0), (0.85, 0.0)],
                       curve="exp")
    out = S.place(out, _lvl(a, 1.0), 0.0)
    b = _creak(0.55, r, freq=188.0, rate=21.0, slow=1.3, rough=0.85)
    b *= S.breakpoints(0.55, [(0.0, 0.0), (0.08, 0.9), (0.55, 0.0)], curve="exp")
    out = S.place(out, _lvl(b, 0.55), 0.42)
    out = S.place(out, _lvl(_sub(0.7, 62.0, 34.0, tau=0.2, drive=2.2), 0.28), 0.02)
    return _room(out, size=1.2, damping=0.66, mix=0.24, cap=1.55)


@cue("gnashGurgle")
def gnash_gurgle(r):
    """The body idling. Slow wet guts - big low bubbles with a breath moving
    through them. Quiet by design: it is the ambient reminder that the thing
    is alive, not an event."""
    dur = 0.95
    guts = _gurgle(dur, r, freq=115.0, density=26.0, level=0.65)
    breath = _gnash_growl(dur, r, f0=40.0, bend=(1.0, 1.1, 0.85), rasp=0.35, sub=0.6,
                          bright=0.4, flutter=13.0, gurgle=0.0)
    breath *= S.breakpoints(dur, [(0.0, 0.0), (0.25, 0.55), (0.7, 0.45), (dur, 0.0)],
                            curve="exp")
    y = S.mix(_lvl(guts, 1.0), _lvl(breath, 0.45))
    return _room(S.lowpass(y, 3600.0, order=2), size=1.0, damping=0.74, mix=0.22,
                 cap=1.25)


@cue("gnashDeath")
def gnash_death(r):
    """The gnashroot burns out and the fen takes the rest. The frame goes
    first (a long tearing creak), then the mass, then the mere closing over
    it - and the cue ends on gurgle fading under the water, which is the
    fight's last statement: the swamp is still there."""
    dur = 2.90
    out = S.silence(dur)
    tear = _creak(1.4, r, freq=86.0, rate=24.0, slow=1.1, rough=0.9)
    tear *= S.breakpoints(1.4, [(0.0, 0.0), (0.08, 1.0), (0.9, 0.55), (1.4, 0.0)],
                          curve="exp")
    out = S.place(out, _lvl(tear, 0.80), 0.0)
    last = _gnash_growl(1.5, r, f0=40.0, bend=(1.15, 0.82, 0.48), rasp=0.55, sub=0.95,
                        bright=0.45, gurgle=0.7)
    last *= S.breakpoints(1.5, [(0.0, 0.0), (0.12, 0.95), (0.85, 0.4), (1.5, 0.0)],
                          curve="exp")
    out = S.place(out, _lvl(last, 0.85), 0.05)
    out = S.place(out, _lvl(_slop(1.2, r, freq=46.0, wet=0.85, suck=0.9), 0.95), 1.25)
    out = S.place(out, _lvl(_sub(1.7, 50.0, 18.0, tau=0.62, drive=3.0, attack=0.05),
                            0.90), 1.25)
    out = S.place(out, _lvl(_gurgle(1.3, r, freq=100.0, density=28.0), 0.42), 1.50)
    return _room(S.lowpass(out, 5200.0, order=2), size=1.8, damping=0.64, mix=0.29,
                 cap=3.20)
