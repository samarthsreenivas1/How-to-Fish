"""sfx_boss_pyrelisk.py - the Ashfall Colossus: 250 studs of standing lava.

THE VOICE: ROCK AT TEMPERATURE. This is the only boss whose material is
actively changing while you fight it, and that is the whole sound design.
Four elements:

* MAGMA (`_magma`). The bass. Not a growl - a moving MASS: very low
  saturated noise with slow irregular swells in it, plus a bubble bed an
  octave under anything the fishing sheet uses. It is what makes Pyrelisk's
  roar different from Brinejaw's: Brinejaw has a throat, Pyrelisk has a
  volume of molten rock with air in it.
* CRUST (`_crust`). The counterpart, and the identity. Cooling lava
  crackles: a dense scatter of very short, very bright ticks whose RATE
  decays. Every move here cracks its crust, and that crackle is the one
  bright thing in a fight otherwise pitched into the floor.
* ROCK ON ROCK (`_rock`). Dry, dense, and pitched LOW-mid - basalt is
  heavy and dead. Steps and handfalls are built on it. Crucially it is not
  masonry (Brinejaw) and not ice (Rimefang): no ring, no chirp, just mass
  and gravel.
* THE FURNACE (`_jet`). A pressurised roaring jet - broadband noise with a
  strong resonant throat and a turbulence flutter. `pyreVentbreath` is a
  LOOP built out of it, so it is authored exactly loop-safe.

EVERYTHING IS SLOW. `turnRate` is 28 deg/s and the shortest windup in the
book is 1.7 s. The cues are correspondingly unhurried: attacks of 5-20 ms
rather than 1 ms, long tails, and telegraphs that take their time, because
at this scale the player answers with their feet across a hundred studs.
"""

import numpy as np

import synth as S
from cues import cue


# ---------------------------------------------------------------------------
# the caldera
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


def _room(x, size=1.9, damping=0.52, mix=0.28, predelay=0.020, tail=True,
          cap=None):
    """A 250-stud bowl of hot rock: big, long, and dark - hot hazy air eats
    the top end, which is why this arena is damped where Rimefang's is
    not."""
    # Sub-26 Hz is headroom the peak normalise gives away - see
    # sfx_boss_shared._room. This sheet's magma layer has plenty of it.
    x = S.highpass(x, 26.0, order=2)
    y = S.reverb(x, size=size, damping=damping, mix=mix, predelay=predelay,
                 seed=77, tail=tail)
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


def _sub(dur, f0, f1, tau=None, drive=2.4, attack=0.003):
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
# the four materials
# ---------------------------------------------------------------------------

def _magma(dur, r, f0=42.0, swell=0.55, boil=0.45, drive=2.8):
    """THE BASS. A volume of molten rock, not a throat.

    Very low band-limited noise given a slow irregular swell (two LFOs at
    incommensurate rates, so it never settles into a pulse), a saturated
    sine core underneath, and a bed of big slow bubbles - lava boils, and
    the boil is what stops this reading as a sub-bass patch.
    """
    tt = S.t(dur)
    mass = S.brown(dur, r)
    # 34 Hz, not 28: brown noise is all bottom, and an order-2 band edge at
    # 28 leaves a fifth of this layer's energy under 22 Hz where nothing
    # reproduces it. The peak normalise then charges the audible part for it.
    mass = S.bandpass(mass, 34.0, 220.0, order=2)
    wob = (1.0 - swell) + swell * (0.55 + 0.45 * np.sin(2.0 * np.pi * 1.7 * tt)) * \
          (0.65 + 0.35 * np.sin(2.0 * np.pi * 0.9 * tt + 1.1))
    mass = mass * wob
    core = S.sine(dur, f0 * (1.0 + 0.06 * np.sin(2.0 * np.pi * 1.3 * tt)))
    core = core + S.sine(dur, f0 * 1.5) * 0.35
    out = S.mix(_lvl(S.saturate(mass * 1.5, drive), 1.0),
                _lvl(S.saturate(core, drive * 0.8), 0.75))
    if boil > 0:
        bub = S.wet_texture(dur, r, density=16.0, freq=95.0, spread=3.0, level=0.6)
        bub = S.lowpass(bub, 1400.0, order=2)
        out = S.mix(out, _lvl(bub, boil * 0.42))
    return S.highpass(out, 30.0, order=2)


def _crust(dur, r, density=90.0, f0=5200.0, f1=1800.0, decay=1.7, level=1.0):
    """COOLING CRUST. Dense, very short, very bright ticks whose RATE decays
    and whose pitch walks down - the sound of a hot skin contracting. This
    is the sheet's signature and the only bright material on it.

    The events are placed on a curve rather than uniformly: `decay` > 1
    front-loads them, which is what crackling actually does after a crack.
    """
    out = S.silence(dur)
    count = max(4, int(density * dur))
    us = np.sort(r.random(count)) ** decay
    for i in range(count):
        u = float(us[i])
        at = u * dur * 0.94
        f = f0 * (f1 / f0) ** u * (0.7 + 0.6 * float(r.random()))
        tick = S.band_noise(0.010, r, f * 0.6, min(18000.0, f * 3.0), order=2)
        tick *= S.perc_env(0.010, 0.0002, 0.0016)
        ping = S.sine(0.020, S.expsweep(0.020, f, f * 0.72))
        ping *= S.perc_env(0.020, 0.0004, 0.0035)
        one = S.mix(_lvl(tick, 1.0), _lvl(ping, 0.5))
        out = S.place(out, one * (0.12 + 0.88 * float(r.random())) *
                      (1.0 - 0.55 * u) * level, at)
    return S.fit(out, dur)


def _rock(dur, r, freq=98.0, count=5, decay=0.05, gravel=0.5):
    """BASALT ON BASALT. Dense, dead and low-mid: bars with a very fast
    decay (rock does not ring) plus gravel - a burst of grit whose filter
    closes. No metal, no glass, nothing sustained."""
    out = S.silence(dur)
    for i in range(count):
        f = freq * (1.0 + 0.47 * i) * (0.9 + 0.2 * float(r.random()))
        out = S.place(out, S.bar(min(dur, 0.26), f, r, decay=decay / (1.0 + 0.5 * i),
                                 strike=0.9) * (0.85 ** i), 0.001 * i)
    if gravel > 0:
        grit = S.band_noise(dur * 0.6, r, 400.0, 9000.0, order=3)
        grit = S.lp_sweep(grit, S.expsweep(dur * 0.6, 8000.0, 700.0), order=2)
        grit = S.tremolo(grit, rate=41.0, depth=0.55)
        grit *= S.perc_env(dur * 0.6, 0.0006, dur * 0.14, curve=1.3)
        out = S.mix(out, _lvl(S.fit(grit, dur), gravel))
    return S.lowpass(out, 9000.0, order=2)


def _jet(dur, r, throat=520.0, force=1.0, turb=32.0):
    """A FURNACE VENT. Pressurised gas: broadband noise with a strong
    resonant throat (the vent's own pipe), turbulence flutter, and a low
    roar under it. The throat resonance is what makes it a vent rather than
    white noise with an envelope."""
    air = S.band_noise(dur, r, 120.0, 16000.0, order=2)
    voiced = (S.resonator(air, throat, q=6.5) +
              S.resonator(air, throat * 2.4, q=5.0) * 0.55 +
              S.resonator(air, throat * 4.1, q=3.5) * 0.28)
    rough = S.tremolo(air, rate=turb, depth=0.35)
    low = S.lowpass(air, 320.0, order=2)
    return S.mix(_lvl(voiced, 1.0), _lvl(rough, 0.45 * force),
                 _lvl(S.saturate(low * 1.5, 2.4), 0.62 * force))


def _pyre_growl(dur, r, f0=40.0, bend=(0.92, 1.18, 0.72), rasp=0.7, sub=0.9,
                bright=0.7, flutter=15.0):
    """A MAGMA ROAR. The lowest fundamental of any boss here (40 Hz against
    Brinejaw's 52), formants dark and very wide apart (180/700/2400 - a
    mountain-sized cavity), and a SLOW flutter: something this large cannot
    modulate quickly, and the slowness is most of what sells the scale."""
    contour = S.breakpoints(dur, [(0.0, f0 * bend[0]), (dur * 0.34, f0 * bend[1]),
                                  (dur, f0 * bend[2])], curve="exp")
    core = S.saw(dur, contour, bright=0.75) * 0.6 + S.pulse(dur, contour, 0.36) * 0.5
    core = S.moog(core, S.breakpoints(dur, [(0.0, 300.0), (dur * 0.3, 1900.0 * bright),
                                            (dur, 460.0)], curve="exp"), res=0.36)
    throat = S.formant(core, [180.0, 700.0, 2400.0], qs=[12.0, 7.0, 4.5],
                       gains=[1.0, 0.52, 0.20])
    voice = S.mix(_lvl(core, 0.30), _lvl(throat, 0.95))
    if rasp > 0:
        edge = S.band_noise(dur, r, 200.0, 3400.0 * bright, order=2)
        edge = S.tremolo(edge, rate=flutter, depth=0.85)
        edge *= S.breakpoints(dur, [(0.0, 0.0), (0.06, 1.0), (dur, 0.4)])
        voice = S.mix(voice, _lvl(edge, rasp * 0.45))
    if sub > 0:
        # 30 Hz and order 4: this is the lowest throat in the pack (36-40 Hz
        # fundamental), so its half- and quarter-octave partials land at
        # 18 and 9 Hz and an order-2 corner does not clear them.
        low = S.highpass(S.sine(dur, contour * 0.5) +
                         S.sine(dur, contour * 0.25) * 0.5, 30.0, order=4)
        voice = S.mix(voice, _lvl(S.saturate(low, 2.2), sub * 0.9))
    return voice


# ---------------------------------------------------------------------------
# the seven voice variants - the shared vocabulary in hot rock
# ---------------------------------------------------------------------------

@cue("bossTell__pyrelisk")
def tell_pyrelisk(r):
    """The mountain commits. A seam opens somewhere on the body: the crust
    cracks (bright, and the only thing you can localise), the glow behind
    it swells, and the magma answers. The longest windups in the book hang
    off this, so it is unhurried and it RISES the whole way."""
    dur = 0.95
    out = S.silence(dur)
    out = S.place(out, _lvl(_crust(0.55, r, density=70.0, f0=5600.0, f1=2400.0,
                                   decay=1.4), 0.85), 0.0)
    glow = _magma(dur, r, f0=46.0, swell=0.4, boil=0.5)
    glow *= S.breakpoints(dur, [(0.0, 0.0), (0.62, 0.8), (0.80, 1.0), (dur, 0.12)],
                          curve="exp")
    out = S.mix(out, _lvl(glow, 1.0))
    hiss = _jet(0.6, r, throat=760.0, force=0.6, turb=26.0)
    hiss *= S.breakpoints(0.6, [(0.0, 0.0), (0.45, 1.0), (0.6, 0.0)], curve="exp")
    out = S.place(out, _lvl(hiss, 0.35), 0.30)
    return _room(out, size=1.6, mix=0.26, cap=1.30)


@cue("bossRise__pyrelisk")
def rise_pyrelisk(r):
    """It stands up out of the lake. Forty studs of rise over six and a half
    seconds in the fight; this is the front of it - lava pouring off a body
    the size of a mountain, the crust forming and cracking as it hits air,
    and the whole lake heaving underneath."""
    dur = 2.20
    out = S.silence(dur)
    pour = S.band_noise(1.9, r, 60.0, 6000.0, order=2)
    pour = S.lp_sweep(pour, S.breakpoints(1.9, [(0.0, 220.0), (1.4, 2400.0),
                                                (1.9, 800.0)], curve="exp"), order=2)
    pour = S.tremolo(pour, rate=5.5, depth=0.30)
    pour *= S.breakpoints(1.9, [(0.0, 0.0), (1.35, 0.85), (1.6, 1.0), (1.9, 0.08)],
                          curve="exp")
    out = S.place(out, _lvl(pour, 0.85), 0.0)
    body = _magma(2.0, r, f0=38.0, swell=0.5, boil=0.6)
    body *= S.breakpoints(2.0, [(0.0, 0.0), (1.5, 1.0), (2.0, 0.15)], curve="exp")
    out = S.mix(out, _lvl(S.fit(body, dur), 1.0))
    out = S.place(out, _lvl(_crust(1.1, r, density=80.0, f0=6000.0, f1=2000.0,
                                   decay=0.8), 0.42), 0.75)
    out = S.place(out, _lvl(_rock(0.6, r, freq=86.0, count=5, decay=0.09,
                                  gravel=0.6), 0.40), 1.30)
    return _room(out, size=2.0, damping=0.50, mix=0.30, cap=2.70)


@cue("bossRoar__pyrelisk")
def roar_pyrelisk(r):
    """THE SIGNATURE: a magma bass roar. The lowest voice in the pack, slow
    enough that you can hear the individual pulses of it, with the whole
    body of molten rock moving underneath and the crust breaking off the top
    as it opens. It does not screech; it does not have to."""
    dur = 2.30
    voice = _pyre_growl(dur, r, f0=38.0, bend=(0.88, 1.26, 0.66), rasp=0.75,
                        sub=0.95, bright=0.75, flutter=13.0)
    voice *= S.breakpoints(dur, [(0.0, 0.0), (0.09, 0.65), (dur * 0.34, 1.0),
                                 (dur * 0.62, 0.82), (dur * 0.92, 0.22), (dur, 0.0)],
                           curve="exp")
    bed = _magma(dur, r, f0=36.0, swell=0.6, boil=0.55)
    bed *= S.breakpoints(dur, [(0.0, 0.0), (0.15, 0.9), (0.75, 1.0), (dur, 0.0)],
                         curve="exp")
    floor = _sub(dur, 46.0, 24.0, tau=1.0, drive=3.0, attack=0.04)
    y = S.mix(_lvl(S.saturate(voice, 1.7), 1.0), _lvl(bed, 0.62), _lvl(floor, 0.55))
    y = S.mix(y, _lvl(S.fit(_crust(0.9, r, density=60.0, f0=5000.0, f1=2200.0),
                            dur), 0.16))
    return _room(y, size=2.2, damping=0.48, mix=0.31, predelay=0.024, cap=2.85)


@cue("bossSnap__pyrelisk")
def snap_pyrelisk(r):
    """The jaw on the throat glow shutting. Rock meeting rock at
    temperature: a dense basalt clack, the crust round the mouth shattering
    with it, and the furnace inside cut off mid-breath."""
    dur = 0.65
    out = S.silence(dur)
    jet = _jet(0.12, r, throat=640.0, force=0.8)
    jet *= S.breakpoints(0.12, [(0.0, 0.6), (0.085, 1.0), (0.095, 0.0)], curve="exp")
    out = S.place(out, _lvl(jet, 0.45), 0.0)
    out = S.place(out, _lvl(_rock(0.34, r, freq=142.0, count=4, decay=0.045,
                                  gravel=0.7), 1.0), 0.088)
    out = S.place(out, _lvl(_crust(0.35, r, density=110.0, f0=6400.0, f1=2400.0,
                                   decay=2.2), 0.55), 0.090)
    out = S.place(out, _lvl(_sub(0.42, 92.0, 40.0, tau=0.11, drive=2.6), 0.80), 0.089)
    return _room(out, size=1.5, damping=0.52, mix=0.22, cap=1.00)


@cue("bossSlam__pyrelisk")
def slam_pyrelisk(r):
    """The body arriving on basalt. Rock on rock with a magma core: the
    crack is gravel rather than a snap, the body is dense and dead, and what
    rings afterwards is the crust breaking, not the stone."""
    dur = 1.70
    out = S.silence(dur)
    out = S.place(out, _lvl(_rock(0.42, r, freq=104.0, count=5, decay=0.055,
                                  gravel=0.85), 0.90), 0.0)
    out = S.place(out, _lvl(S.saturate(S.membrane(0.9, 50.0, r, drop=0.5, noise=0.34,
                                                  tau=0.26), 2.6), 0.95), 0.006)
    out = S.place(out, _lvl(_sub(1.30, 56.0, 24.0, tau=0.40, drive=3.0), 0.95), 0.006)
    out = S.place(out, _lvl(_crust(0.85, r, density=95.0, f0=5600.0, f1=1800.0,
                                   decay=1.9), 0.48), 0.020)
    spill = _magma(0.9, r, f0=44.0, swell=0.5, boil=0.5)
    spill *= S.breakpoints(0.9, [(0.0, 0.0), (0.08, 1.0), (0.9, 0.0)], curve="exp")
    out = S.place(out, _lvl(spill, 0.40), 0.010)
    return _room(out, size=2.0, damping=0.50, mix=0.29, predelay=0.020, cap=2.20)


@cue("bossDown__pyrelisk")
def down_pyrelisk(r):
    """It goes back into the lake. A long collapse with the crust
    disintegrating the whole way down and the lava closing over it - the one
    place on this sheet where the magma bed is the LAST thing left, because
    the mountain is gone and the caldera is not."""
    dur = 2.60
    out = S.silence(dur)
    give = _rock(0.55, r, freq=78.0, count=6, decay=0.10, gravel=0.9)
    out = S.place(out, _lvl(give, 0.65), 0.0)
    last = _pyre_growl(1.3, r, f0=36.0, bend=(1.1, 0.84, 0.50), rasp=0.6, sub=0.95,
                       bright=0.5, flutter=11.0)
    last *= S.breakpoints(1.3, [(0.0, 0.0), (0.12, 0.9), (0.75, 0.45), (1.3, 0.0)],
                          curve="exp")
    out = S.place(out, _lvl(last, 0.80), 0.05)
    out = S.place(out, _lvl(_crust(1.5, r, density=85.0, f0=5200.0, f1=1500.0,
                                   decay=0.9), 0.42), 0.30)
    out = S.place(out, _lvl(_sub(1.8, 54.0, 20.0, tau=0.68, drive=3.0, attack=0.05),
                            0.90), 1.05)
    plunge = S.band_noise(1.0, r, 90.0, 4200.0, order=2)
    plunge = S.lp_sweep(plunge, S.expsweep(1.0, 2600.0, 260.0), order=2)
    plunge *= S.breakpoints(1.0, [(0.0, 0.0), (0.10, 1.0), (1.0, 0.05)], curve="exp")
    out = S.place(out, _lvl(plunge, 0.60), 1.05)
    bed = _magma(1.3, r, f0=34.0, swell=0.65, boil=0.7)
    bed *= S.breakpoints(1.3, [(0.0, 0.0), (0.3, 1.0), (1.3, 0.0)], curve="exp")
    out = S.place(out, _lvl(bed, 0.50), 1.20)
    return _room(out, size=2.3, damping=0.50, mix=0.31, cap=3.00)


@cue("bossStagger__pyrelisk")
def stagger_pyrelisk(r):
    """AN ARM COMES DOWN and stays down - a twenty-second window, the most
    important beat in the fight. So the impact is only the front of the cue:
    what carries is the arm SETTLING, crust cracking off it for a second and
    a half afterwards, which is the sound of a ramp being available."""
    dur = 2.30
    out = S.silence(dur)
    out = S.place(out, _lvl(_rock(0.50, r, freq=84.0, count=6, decay=0.075,
                                  gravel=0.95), 0.85), 0.0)
    out = S.place(out, _lvl(S.saturate(S.membrane(1.05, 42.0, r, drop=0.48,
                                                  noise=0.34, tau=0.32), 2.9),
                            1.0), 0.010)
    out = S.place(out, _lvl(_sub(1.60, 48.0, 21.0, tau=0.55, drive=3.1), 1.0), 0.010)
    groan = _pyre_growl(1.1, r, f0=40.0, bend=(1.0, 0.82, 0.58), rasp=0.6, sub=0.9,
                        bright=0.55, flutter=12.0)
    groan *= S.breakpoints(1.1, [(0.0, 0.0), (0.15, 1.0), (0.62, 0.5), (1.1, 0.0)],
                           curve="exp")
    out = S.place(out, _lvl(groan, 0.55), 0.28)
    # The settle: the arm is DOWN, and it keeps saying so.
    out = S.place(out, _lvl(_crust(1.6, r, density=70.0, f0=5000.0, f1=1600.0,
                                   decay=0.75), 0.50), 0.14)
    out = S.place(out, _lvl(_rock(0.6, r, freq=118.0, count=4, decay=0.06,
                                  gravel=0.7), 0.32), 0.62)
    return _room(out, size=2.2, damping=0.48, mix=0.31, predelay=0.022, cap=2.85)


# ---------------------------------------------------------------------------
# the colossus's own ten
# ---------------------------------------------------------------------------

@cue("pyreHandfall")
def pyre_handfall(r):
    """THE OPENER AND THE BAIT. A fist goes up over the rim and comes down
    on the path. 2.6 s of windup precede it, so the landing itself is a
    single enormous event with no lead-in: gravel, a dead low body, the
    shockwave leaving, and the monolith it shatters."""
    dur = 2.00
    out = S.silence(dur)
    out = S.place(out, _lvl(_rock(0.46, r, freq=92.0, count=6, decay=0.06,
                                  gravel=1.0), 0.95), 0.0)
    out = S.place(out, _lvl(S.saturate(S.membrane(1.0, 44.0, r, drop=0.48, noise=0.32,
                                                  tau=0.30), 3.0), 1.0), 0.008)
    out = S.place(out, _lvl(_sub(1.55, 52.0, 22.0, tau=0.50, drive=3.1), 1.0), 0.008)
    # The shockwave leaving along the path - a rush with no transient.
    wave = S.band_noise(0.9, r, 100.0, 5000.0, order=2)
    wave = S.bp_sweep(wave, S.breakpoints(0.9, [(0.0, 400.0), (0.55, 1100.0),
                                                (0.9, 500.0)], curve="exp"), q=1.4)
    wave *= S.breakpoints(0.9, [(0.0, 0.2), (0.35, 1.0), (0.9, 0.0)], curve="exp")
    out = S.place(out, _lvl(wave, 0.45), 0.05)
    out = S.place(out, _lvl(_crust(1.1, r, density=90.0, f0=5400.0, f1=1700.0,
                                   decay=1.7), 0.45), 0.015)
    # The stone it spends.
    for i in range(7):
        at = 0.10 + float(r.random()) * 0.65
        out = S.place(out, _lvl(_rock(0.22, r, freq=180.0 *
                                      float(2.0 ** (r.random() * 1.4 - 0.7)),
                                      count=3, decay=0.035, gravel=0.6),
                                0.16 + 0.16 * float(r.random())), at)
    return _room(out, size=2.2, damping=0.48, mix=0.30, predelay=0.022, cap=2.60)


@cue("pyreRimsweep")
def pyre_rimsweep(r):
    """THE HERD. The arm draws back low and rakes an arc of the path. The
    forearm is the hazard along its whole length, so this is BROAD rather
    than sharp: a long dragging rush with rock grinding along the ground for
    the whole of it, and the arc carried by the filter opening and closing."""
    dur = 1.55
    drag = S.band_noise(dur, r, 60.0, 6000.0, order=2)
    drag = S.bp_sweep(drag, S.breakpoints(dur, [(0.0, 220.0), (0.55, 780.0),
                                                (0.85, 620.0), (dur, 240.0)],
                                          curve="exp"), q=1.4)
    drag *= S.breakpoints(dur, [(0.0, 0.0), (0.22, 0.55), (0.62, 1.0), (0.95, 0.7),
                                (dur, 0.0)], curve="exp")
    gravel = S.band_noise(dur, r, 500.0, 9000.0, order=2)
    gravel = S.tremolo(gravel, rate=37.0, depth=0.65)
    gravel *= S.breakpoints(dur, [(0.0, 0.0), (0.35, 0.7), (0.68, 1.0), (dur, 0.0)],
                            curve="exp")
    mass = S.sine(dur, S.expsweep(dur, 92.0, 40.0))
    mass *= S.breakpoints(dur, [(0.0, 0.0), (0.66, 1.0), (dur, 0.0)], curve="exp")
    heat = _magma(dur, r, f0=48.0, swell=0.5, boil=0.35)
    heat *= S.breakpoints(dur, [(0.0, 0.0), (0.5, 0.9), (dur, 0.0)], curve="exp")
    y = S.mix(_lvl(drag, 1.0), _lvl(gravel, 0.35), _lvl(S.saturate(mass, 2.4), 0.60),
              _lvl(heat, 0.30))
    y = S.mix(y, _lvl(S.fit(_crust(1.0, r, density=60.0, f0=4800.0, f1=1800.0),
                            dur), 0.18))
    return _room(y, size=2.0, damping=0.50, mix=0.27, cap=2.00)


@cue("pyreVentbreath", loop=True)
def pyre_ventbreath(r):
    """LOOP: A ROARING FURNACE JET. The head rears, the jaw opens on the
    throat glow and a molten cone comes out of it for 2.6 s - so this has to
    be a bed that can run for as long as the handler needs and never
    develop a shape of its own.

    LOOP-SAFETY, four things. Exactly 2.4 s. Both turbulence LFOs (2.5 Hz
    and 5 Hz) complete whole cycles across it (6 and 12). Nothing is
    triggered - it is entirely continuous, so there is no event that can be
    cut in half at the seam. It is built over a `LOOP_LEAD` that is then
    discarded so the filters are at steady state at sample zero, and the
    reverb is and the reverb is `tail=False`.
    """
    dur = 2.4
    build = dur + LOOP_LEAD
    tt = S.t(build)
    jet = _jet(build, r, throat=560.0, force=1.0, turb=34.0)
    # Two commensurate LFOs: 6 and 12 whole cycles across 2.4 s.
    breath = (0.72 + 0.28 * np.sin(2.0 * np.pi * 2.5 * tt)) * \
             (0.85 + 0.15 * np.sin(2.0 * np.pi * 5.0 * tt + 0.7))
    jet = jet * breath
    # The molten stream inside the gas: a low boiling bed, not a growl.
    flow = S.brown(build, r)
    flow = S.bandpass(flow, 32.0, 260.0, order=2)
    flow = flow * (0.70 + 0.30 * np.sin(2.0 * np.pi * 2.5 * tt + 2.1))
    flow = S.saturate(flow * 1.6, 2.8)
    y = S.mix(_lvl(_settle(jet, dur), 1.0), _lvl(_settle(flow, dur), 0.55))
    y = S.lowpass(y, 13000.0, order=2)
    return _room(y, size=1.8, damping=0.55, mix=0.20, tail=False)


@cue("pyreAshfall")
def pyre_ashfall(r):
    """THE MOUNTAIN ANSWERS: a soft hissing rain of cinders. Deliberately
    the gentlest cue on the sheet, because the danger is the marks on the
    ground and not the sound - a loud ashfall would fight the marks for
    attention. Fine hiss, no transient, and a scatter of small warm ticks
    where cinders actually land."""
    dur = 1.40
    hiss = S.band_noise(dur, r, 1800.0, 15000.0, order=2)
    hiss = S.bp_sweep(hiss, S.breakpoints(dur, [(0.0, 5000.0), (0.6, 7000.0),
                                                (dur, 4200.0)], curve="exp"), q=0.9)
    hiss = S.tremolo(hiss, rate=6.5, depth=0.25)
    hiss *= S.breakpoints(dur, [(0.0, 0.0), (0.30, 0.85), (0.85, 1.0), (dur, 0.0)],
                          curve="exp")
    fall = S.band_noise(dur, r, 300.0, 3000.0, order=2)
    fall *= S.breakpoints(dur, [(0.0, 0.0), (0.45, 0.7), (dur, 0.0)], curve="exp")
    embers = S.silence(dur)
    for _ in range(26):
        at = 0.10 + float(r.random()) * 1.10
        f = 2200.0 * float(2.0 ** (r.random() * 1.8 - 0.9))
        tick = S.band_noise(0.012, r, f * 0.6, min(16000.0, f * 3.0), order=2)
        tick *= S.perc_env(0.012, 0.0004, 0.0028)
        embers = S.place(embers, tick * (0.10 + 0.30 * float(r.random())), at)
    warm = S.brown(dur, r)
    warm = S.bandpass(warm, 40.0, 220.0, order=2)
    warm *= S.breakpoints(dur, [(0.0, 0.0), (0.5, 0.8), (dur, 0.0)], curve="exp")
    y = S.mix(_lvl(hiss, 1.0), _lvl(fall, 0.28), _lvl(embers, 0.42),
              _lvl(S.saturate(warm, 2.2), 0.30))
    return _room(y, size=1.9, damping=0.55, mix=0.26, cap=1.85)


@cue("pyreShardhurl")
def pyre_shardhurl(r):
    """It tears a slab off its own shell and throws it. Two halves: the TEAR
    (rock separating, crust shattering along the seam) and the FLIGHT - an
    obsidian whistle, because a flat slab of volcanic glass spinning through
    the air sings, and that whistle is the only warning the far band gets."""
    dur = 1.00
    out = S.silence(dur)
    tear = S.band_noise(0.24, r, 300.0, 11000.0, order=3)
    tear = S.lp_sweep(tear, S.expsweep(0.24, 9000.0, 900.0), order=2)
    tear = S.tremolo(tear, rate=44.0, depth=0.5)
    tear *= S.breakpoints(0.24, [(0.0, 0.0), (0.02, 1.0), (0.24, 0.0)], curve="exp")
    out = S.place(out, _lvl(tear, 0.85), 0.0)
    out = S.place(out, _lvl(_rock(0.30, r, freq=170.0, count=4, decay=0.04,
                                  gravel=0.7), 0.65), 0.005)
    out = S.place(out, _lvl(_crust(0.45, r, density=110.0, f0=6800.0, f1=2600.0,
                                   decay=2.0), 0.55), 0.010)
    # The whistle: a spinning slab, so the pitch WOBBLES as it turns.
    spin = S.expsweep(0.62, 2600.0, 1150.0)
    whistle = S.mix(_lvl(S.sine(0.62, spin), 0.5),
                    _lvl(S.bp_sweep(S.white(0.62, r), spin, q=8.0), 1.0))
    whistle = S.vibrato(whistle, rate=13.0, depth_cents=90.0)
    whistle *= S.breakpoints(0.62, [(0.0, 0.0), (0.06, 0.9), (0.45, 0.7), (0.62, 0.0)],
                             curve="exp")
    out = S.place(out, _lvl(whistle, 0.55), 0.24)
    return _room(out, size=1.7, damping=0.48, mix=0.24, cap=1.40)


@cue("pyreShardHit")
def pyre_shard_hit(r):
    """The slab landing: OBSIDIAN SHATTERING. Volcanic glass, so this is the
    brightest and shortest thing on the sheet - a hard glassy crack, a
    scatter of shards, and only enough low end to say the piece was heavy."""
    dur = 0.75
    out = S.silence(dur)
    out = S.place(out, _lvl(S.band_noise(0.05, r, 2000.0, 17000.0, order=3) *
                            S.perc_env(0.05, 0.0002, 0.005), 1.0), 0.0)
    for i, f in enumerate((1480.0, 2260.0, 3410.0, 4980.0)):
        out = S.place(out, S.bell(0.28, f, r, decay=0.055 - 0.008 * i, strike=0.9,
                                  inharmonic=1.3) * (0.5 - 0.09 * i), 0.001 + 0.003 * i)
    out = S.place(out, _lvl(_rock(0.26, r, freq=150.0, count=3, decay=0.032,
                                  gravel=0.6), 0.50), 0.002)
    out = S.place(out, _lvl(_sub(0.30, 140.0, 64.0, tau=0.05, drive=2.2), 0.34), 0.002)
    for _ in range(11):
        at = 0.03 + float(r.random()) * 0.34
        f = 3600.0 * float(2.0 ** (r.random() * 1.6 - 0.8))
        out = S.place(out, S.bell(0.13, f, r, decay=0.028, strike=0.85,
                                  inharmonic=1.4) * (0.06 + 0.14 * float(r.random())),
                      at)
    return _room(out, size=1.6, damping=0.42, mix=0.24, cap=0.95)


@cue("pyreStep")
def pyre_step(r):
    """One foot. ROCK ON ROCK: a dense, dead basalt impact with a gravel
    front and a sub under it. It has to be readable from anywhere on the
    ring, because a step is how you know the mountain is turning."""
    dur = 1.25
    out = S.silence(dur)
    out = S.place(out, _lvl(_rock(0.36, r, freq=110.0, count=5, decay=0.05,
                                  gravel=0.9), 0.95), 0.0)
    out = S.place(out, _lvl(S.saturate(S.membrane(0.65, 54.0, r, drop=0.5, noise=0.32,
                                                  tau=0.19), 2.6), 0.90), 0.005)
    out = S.place(out, _lvl(_sub(0.95, 60.0, 27.0, tau=0.28, drive=2.9), 0.85), 0.005)
    out = S.place(out, _lvl(_crust(0.55, r, density=75.0, f0=5000.0, f1=1900.0,
                                   decay=2.1), 0.34), 0.012)
    for _ in range(6):
        at = 0.06 + float(r.random()) * 0.40
        out = S.place(out, _lvl(_rock(0.16, r, freq=260.0 *
                                      float(2.0 ** (r.random() - 0.5)),
                                      count=2, decay=0.024, gravel=0.5),
                                0.10 + 0.12 * float(r.random())), at)
    return _room(out, size=1.9, damping=0.52, mix=0.27, cap=1.65)


@cue("pyreRoar")
def pyre_roar(r):
    """The colossus's own roar - `bossRoar__pyrelisk`'s bigger brother, and
    the loudest thing the fight has. Same magma throat, driven harder, with
    the furnace opening behind it and the whole lake answering underneath."""
    dur = 2.40
    voice = _pyre_growl(dur, r, f0=36.0, bend=(0.86, 1.32, 0.62), rasp=0.85,
                        sub=1.0, bright=0.85, flutter=12.0)
    voice = S.saturate(voice * 1.3, 2.2)
    voice *= S.breakpoints(dur, [(0.0, 0.0), (0.10, 0.7), (dur * 0.32, 1.0),
                                 (dur * 0.66, 0.85), (dur * 0.92, 0.22), (dur, 0.0)],
                           curve="exp")
    bed = _magma(dur, r, f0=34.0, swell=0.65, boil=0.6)
    bed *= S.breakpoints(dur, [(0.0, 0.0), (0.18, 0.9), (0.8, 1.0), (dur, 0.0)],
                         curve="exp")
    furnace = _jet(1.5, r, throat=480.0, force=1.0, turb=30.0)
    furnace *= S.breakpoints(1.5, [(0.0, 0.0), (0.2, 0.9), (1.1, 0.7), (1.5, 0.0)],
                             curve="exp")
    floor = _sub(dur, 44.0, 22.0, tau=1.05, drive=3.2, attack=0.04)
    y = S.mix(_lvl(voice, 1.0), _lvl(bed, 0.60), _lvl(S.fit(furnace, dur), 0.28),
              _lvl(floor, 0.58))
    return _room(y, size=2.4, damping=0.46, mix=0.32, predelay=0.026, cap=3.00)


@cue("pyreCrustCrack")
def pyre_crust_crack(r):
    """A SEAM OPENING - the shell splitting where the party has been
    shooting. The pure form of the crust material: one hard split and then a
    second and a half of crackle behind it as the glow gets out. Bright by
    design, because this is feedback for shooting well."""
    dur = 1.20
    out = S.silence(dur)
    out = S.place(out, _lvl(S.band_noise(0.06, r, 1400.0, 16000.0, order=3) *
                            S.perc_env(0.06, 0.0003, 0.006), 0.90), 0.0)
    out = S.place(out, _lvl(_rock(0.28, r, freq=196.0, count=3, decay=0.035,
                                  gravel=0.75), 0.55), 0.002)
    out = S.place(out, _lvl(_crust(1.0, r, density=120.0, f0=7000.0, f1=1900.0,
                                   decay=1.5), 1.0), 0.010)
    glow = _magma(0.9, r, f0=52.0, swell=0.4, boil=0.6)
    glow *= S.breakpoints(0.9, [(0.0, 0.0), (0.15, 0.9), (0.9, 0.0)], curve="exp")
    out = S.place(out, _lvl(glow, 0.42), 0.020)
    out = S.place(out, _lvl(_sub(0.4, 130.0, 62.0, tau=0.08, drive=2.2), 0.30), 0.002)
    return _room(out, size=1.7, damping=0.46, mix=0.25, cap=1.55)


@cue("pyreDeath")
def pyre_death(r):
    """The mountain goes out. The longest cue on the sheet: the frame fails
    in a run of rock, the roar collapses in on itself, the whole crust
    shatters at once, and what is left is the lake cooling - the magma bed
    fading under the caldera's own reverb, with cinders still falling."""
    dur = 3.10
    out = S.silence(dur)
    fail = _rock(0.7, r, freq=72.0, count=6, decay=0.12, gravel=1.0)
    out = S.place(out, _lvl(fail, 0.70), 0.0)
    last = _pyre_growl(1.6, r, f0=34.0, bend=(1.15, 0.80, 0.46), rasp=0.7, sub=1.0,
                       bright=0.45, flutter=10.0)
    last *= S.breakpoints(1.6, [(0.0, 0.0), (0.10, 0.95), (0.85, 0.45), (1.6, 0.0)],
                          curve="exp")
    out = S.place(out, _lvl(last, 0.90), 0.04)
    out = S.place(out, _lvl(_crust(2.0, r, density=110.0, f0=6200.0, f1=1400.0,
                                   decay=1.1), 0.52), 0.90)
    out = S.place(out, _lvl(S.saturate(S.membrane(1.2, 38.0, r, drop=0.46, noise=0.32,
                                                  tau=0.40), 3.0), 0.92), 1.30)
    out = S.place(out, _lvl(_sub(1.9, 48.0, 18.0, tau=0.72, drive=3.2, attack=0.05),
                            0.92), 1.30)
    out = S.place(out, _lvl(_rock(0.8, r, freq=64.0, count=6, decay=0.13,
                                  gravel=0.9), 0.55), 1.31)
    cool = _magma(1.5, r, f0=32.0, swell=0.7, boil=0.75)
    cool *= S.breakpoints(1.5, [(0.0, 0.0), (0.25, 0.9), (1.5, 0.0)], curve="exp")
    out = S.place(out, _lvl(cool, 0.48), 1.50)
    return _room(out, size=2.5, damping=0.48, mix=0.32, cap=3.30)
