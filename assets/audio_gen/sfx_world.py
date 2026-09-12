"""sfx_world.py - the `world` sheet. Fourteen cues; the biggest spaces.

This sheet is where the reverb lives. Everything on the fishing, UI and
character sheets is close and dry because it happens to YOU; everything here
happens to the WORLD, and the room is most of what says so. `_far_room()`
below is a large, slow-damping space, and the only cues that do not use
it are the two loops (a reverb tail would run past the loop point) and the
lamp pair (they are switches on a post, an arm's length away).

THE FOUR HARD ONES, and what each is actually modelling:

  thunder     Sound at 3 km is not "a bang, quieter". The crack has already
              lost everything above ~1.5 kHz to air absorption, the wavefront
              has been smeared by turbulence into a 2-4 s ROLL, and the roll
              arrives in irregular lumps because different parts of a
              kilometres-long channel are different distances away. `_roll`
              builds that from scattered brown-noise swells; the three
              variants are near/mid/far, and each carries its own distant
              roll after the strike.
  bellToll    A real bell is NOT harmonic. The partial set below is the
              measured one for a founder's bell - hum an octave BELOW the
              named note, then prime, minor third (1.2), fifth, nominal at
              2.0, and a stack of high partials that die first. The minor
              third is why every large bell sounds melancholy, and it is the
              single thing that separates a bell from `S.bell`'s generic
              inharmonic pile.
  gullCry     A formant-filtered, pitch-bent tone. The bird is a buzzy
              source (a narrow pulse) through three fixed resonances; the
              CRY is the pitch contour, which snaps up and then sags, and
              the formants stay put while the pitch moves - that is what
              makes it an animal and not a synth sweep.
  whirlpool   A roar that must loop. Built entirely from continuous noise
              through slowly-moving filters with whole-cycle LFOs, so there
              is nothing that can be cut by the loop point.
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

# The measured partial ratios of a founder's bell, and how fast each dies.
BELL_PARTIALS = [0.5, 1.0, 1.2, 1.5, 2.0, 2.5, 3.0, 4.0, 5.33, 6.4]
BELL_AMPS = [0.85, 1.00, 0.72, 0.45, 0.60, 0.30, 0.22, 0.14, 0.09, 0.06]
BELL_DECAYS = [1.00, 0.72, 0.55, 0.42, 0.38, 0.24, 0.18, 0.11, 0.07, 0.05]


def _far_room(x, size=1.6, damping=0.5, mix=0.28, predelay=0.02, tail=True):
    """Outdoors and large. See the header."""
    y = S.reverb(x, size=size, damping=damping, mix=mix, predelay=predelay,
                 seed=71, tail=tail)
    return _lead(y) if tail else y


def _roll(r, dur, level=1.0, low=40.0, high=900.0, lumps=7, spread=None):
    """The thunder roll: `lumps` overlapping brown-noise swells at random
    times, each with its own attack and length. Sum them and you get the
    characteristic uneven rumble that a single enveloped noise burst never
    produces - the unevenness IS the distance."""
    out = S.silence(dur)
    spread = spread if spread is not None else dur * 0.72
    for _ in range(lumps):
        at = float(r.random()) ** 1.3 * spread
        ln = min(dur - at, 0.35 + 1.1 * float(r.random()))
        if ln < 0.08:
            continue
        body = S.brown(ln, r)
        body = S.bandpass(body, low * (0.7 + 0.6 * float(r.random())),
                          high * (0.6 + 0.8 * float(r.random())), order=2)
        body *= S.breakpoints(ln, [(0.0, 0.0), (ln * (0.15 + 0.3 * float(r.random())), 1.0),
                                   (ln, 0.0)], curve="exp")
        out = S.place(out, body * (0.35 + 0.65 * float(r.random())) * level, at)
    return S.fit(out, dur)


# ---------------------------------------------------------------------------
# weather
# ---------------------------------------------------------------------------

@cue("thunder", variants=3)
def thunder(r, i):
    """Three strikes at three distances, each with its own distant roll.

    variant 1  NEAR   a hard crack (still low-passed to 4 kHz - even a close
                      strike has lost its top) with a short violent roll.
    variant 2  MID    no crack at all, just the leading edge of the roll and
                      a long uneven decay. The most usable one, so it is the
                      most neutral.
    variant 3  FAR    no transient whatsoever, nothing above 520 Hz, and the
                      longest roll. This is the one the ambience beds sit
                      under.

    All three end with the roll dying to nothing rather than being cut, so
    the client can overlap two of them without a seam.
    """
    spec = ((1.9, 1.00, 4200.0, 9, 0.9),      # near
            (2.4, 0.55, 1500.0, 8, 0.6),      # mid
            (2.0, 0.00, 520.0, 7, 0.35))[i % 3]
    dur, crack_amt, cutoff, lumps, brightness = spec
    out = S.silence(dur)

    if crack_amt > 0.0:
        # The strike: a very fast broadband spit through a closing filter.
        crack = S.band_noise(0.09, r, 150.0, 12000.0, order=2)
        crack = S.lp_sweep(crack, S.expsweep(0.09, cutoff, 400.0), order=2)
        crack *= S.perc_env(0.09, 0.0004, 0.018, curve=1.4)
        out = S.place(out, S.saturate(crack * crack_amt, 1.8), 0.0)
        # The pressure step under it - the part you feel.
        step = S.sine(0.30, S.expsweep(0.30, 90.0, 34.0)) * S.perc_env(0.30, 0.001, 0.075)
        out = S.place(out, S.saturate(step * 0.8 * crack_amt, 2.6), 0.004)

    out = S.mix(out, _roll(r, dur, level=1.0, low=38.0, high=260.0 + 700.0 * brightness,
                           lumps=lumps))
    # A wide, slow sub swell so the roll has a floor rather than just texture.
    sub = S.lowpass(S.brown(dur, r), 90.0, order=2)
    sub *= S.breakpoints(dur, [(0.0, 0.0), (dur * 0.18, 1.0), (dur * 0.6, 0.55),
                               (dur, 0.0)], curve="exp")
    out = S.mix(out, S.saturate(sub * 0.55, 1.6))
    out = S.lowpass(out, cutoff, order=2)
    # Room size is capped: the roll is already the "distance" cue, so a
    # bigger reverb only adds inaudible tail that the sprite has to carry.
    return _far_room(out * 0.85, size=1.0, damping=0.70,
                     mix=0.18 + 0.06 * (i % 3), predelay=0.03)


@cue("windGust")
def wind_gust(r):
    """A gust across the deck. Two things make wind and not hiss: the band
    centre RISES with the gust and falls after it (faster air is brighter),
    and there is a second, narrower resonance an octave up that whistles
    through the rigging at the peak. The envelope is asymmetric - gusts
    arrive faster than they leave."""
    dur = 1.8
    src = S.pink(dur, r)
    centre = S.breakpoints(dur, [(0.0, 320.0), (0.55, 1500.0), (0.85, 1100.0),
                                 (dur, 380.0)], curve="exp")
    body = S.bp_sweep(src, centre, q=1.1)
    whistle = S.bp_sweep(S.white(dur, r), centre * 2.6, q=7.0)
    env = S.breakpoints(dur, [(0.0, 0.0), (0.50, 1.0), (0.72, 0.72), (1.15, 0.40),
                              (dur, 0.0)], curve="exp")
    y = S.mix(body * 0.9, whistle * 0.22 * env)
    y *= env
    low = S.lowpass(S.brown(dur, r), 200.0, order=2) * env * 0.30
    return _far_room(S.mix(y, low), size=0.9, damping=0.65, mix=0.16)


# ---------------------------------------------------------------------------
# lamps - the two dry cues on the sheet
# ---------------------------------------------------------------------------

@cue("lampOn")
def lamp_on(r):
    """A lamp lights: a switch click, then the wick catching - a short
    upward whoosh of flame - then a faint hum settling. Dry and close;
    a lamp is on a post next to you, not out in the world."""
    dur = 0.75
    out = S.silence(dur)
    out = S.place(out, S.metal_hit(0.09, r, 1650.0, ring=0.08, roughness=0.6) * 0.60, 0.0)
    out = S.place(out, S.band_noise(0.002, r, 3000.0, 13000.0)
                  * S.perc_env(0.002, 0.0001, 0.0005) * 0.35, 0.0)
    catch = S.band_noise(0.30, r, 250.0, 5000.0, order=2)
    catch = S.lp_sweep(catch, S.expsweep(0.30, 900.0, 3400.0), order=2)
    catch *= S.breakpoints(0.30, [(0.0, 0.0), (0.055, 1.0), (0.16, 0.45), (0.30, 0.0)],
                           curve="exp")
    out = S.place(out, catch * 0.45, 0.045)
    glow = S.mix(S.sine(0.42, 196.0) * 0.30, S.sine(0.42, 392.0) * 0.10)
    glow *= S.breakpoints(0.42, [(0.0, 0.0), (0.12, 1.0), (0.42, 0.0)], curve="exp")
    out = S.place(out, S.saturate(glow * 0.35, 1.6), 0.10)
    return _lead(S.reverb(out * 0.9, size=0.5, damping=0.55, mix=0.10, seed=71))


@cue("lampOff")
def lamp_off(r):
    """The mirror: the same switch click, then the flame being cut - a
    downward puff that stops, and the hum falling away. Shorter than
    `lampOn`, because going out is quicker than catching."""
    dur = 0.50
    out = S.silence(dur)
    out = S.place(out, S.metal_hit(0.08, r, 1450.0, ring=0.07, roughness=0.65) * 0.55, 0.0)
    puff = S.band_noise(0.16, r, 200.0, 3600.0, order=2)
    puff = S.lp_sweep(puff, S.expsweep(0.16, 2800.0, 420.0), order=2)
    puff *= S.breakpoints(0.16, [(0.0, 0.0), (0.02, 1.0), (0.16, 0.0)], curve="exp")
    out = S.place(out, puff * 0.40, 0.030)
    fade = S.sine(0.22, S.expsweep(0.22, 196.0, 148.0)) * 0.22
    fade *= S.breakpoints(0.22, [(0.0, 1.0), (0.22, 0.0)], curve="exp")
    out = S.place(out, S.saturate(fade, 1.6), 0.030)
    return _lead(S.reverb(out * 0.9, size=0.45, damping=0.6, mix=0.09, seed=71))


# ---------------------------------------------------------------------------
# the volcano
# ---------------------------------------------------------------------------

@cue("lavaBurst")
def lava_burst(r):
    """A gout of lava: a low pressure THUMP, a thick wet burst (bandpassed
    noise with the low-pass closing slowly - lava is viscous, so its splash
    decays four times slower than water's) and then spatter falling back.
    Nothing above 6 kHz; molten rock has no spray."""
    dur = 1.3
    out = S.silence(dur)
    thump = S.membrane(0.35, 48.0, r, drop=0.5, noise=0.25, tau=0.10)
    out = S.place(out, S.saturate(thump, 2.8) * 0.95, 0.0)
    burst = S.band_noise(0.55, r, 120.0, 5200.0, order=2)
    burst = S.lp_sweep(burst, S.expsweep(0.55, 4600.0, 260.0), order=2)
    burst *= S.perc_env(0.55, 0.003, 0.14, curve=1.2)
    out = S.place(out, S.saturate(burst * 0.75, 1.8), 0.006)
    # Spatter: big, slow, low-pitched bubbles - the viscosity tell.
    for _ in range(9):
        f = 160.0 * float(2.0 ** (r.random() * 1.1 - 0.55))
        at = 0.18 + float(r.random()) * 0.55
        out = S.place(out, S.bubble(0.10 + 0.09 * float(r.random()), f, r, rise=1.8)
                      * 0.20 * (0.4 + 0.6 * float(r.random())), at)
    hiss = S.band_noise(0.6, r, 1200.0, 6000.0, order=2)
    hiss *= S.breakpoints(0.6, [(0.0, 0.0), (0.06, 0.6), (0.6, 0.0)], curve="exp")
    out = S.place(out, hiss * 0.16, 0.05)
    return _far_room(S.lowpass(out * 0.85, 6000.0, order=2), size=1.1, damping=0.65, mix=0.20)


@cue("lavaBubble", loop=True)
def lava_bubble(r):
    """LOOP: a lava pool bubbling, 3.0 s.

    Loop-safety, checked three ways: every bubble is placed before 2.60 s
    and none is longer than 0.19 s, so nothing is cut at the end; the two
    LFOs under the bed complete 2 and 3 whole cycles across the loop; and
    the reverb is `tail=False`.

    Lava bubbles are LOW (150-400 Hz, an octave and a half below water),
    SLOW (they rise over 100-190 ms) and they arrive in clumps rather than
    evenly - a regular bubble rate reads as an aquarium pump.
    """
    dur = 3.0
    out = S.silence(dur)
    # Clumped, not even: five clusters, each of 2-4 bubbles.
    for c in range(5):
        base = 0.10 + c * 0.50 + float(r.random()) * 0.12
        for _ in range(2 + int(r.random() * 3)):
            at = base + float(r.random()) * 0.30
            if at > 2.60:
                continue
            f = 210.0 * float(2.0 ** (r.random() * 1.2 - 0.6))
            d = 0.10 + 0.09 * float(r.random())
            out = S.place(out, S.bubble(d, f, r, rise=1.7) * (0.30 + 0.45 * float(r.random())), at)
    idx = np.arange(S.n(dur)) / S.n(dur)
    slow = 0.65 + 0.35 * np.sin(2.0 * np.pi * 2.0 * idx)
    slower = 0.70 + 0.30 * np.sin(2.0 * np.pi * 3.0 * idx + 0.8)
    bed = S.lowpass(S.brown(dur, r), 220.0, order=2) * 0.85 * slow
    crust = S.bandpass(S.pink(dur, r), 500.0, 3200.0, order=2) * 0.14 * slower
    y = S.mix(out * 0.9, S.saturate(bed, 1.8), crust)
    y = S.lowpass(y, 4500.0, order=2)
    return _far_room(y, size=0.9, damping=0.72, mix=0.14, predelay=0.0, tail=False)


# ---------------------------------------------------------------------------
# the sea
# ---------------------------------------------------------------------------

@cue("whirlpool", loop=True)
def whirlpool(r):
    """LOOP: the roar of a maelstrom, 4.0 s, with slow modulation.

    Everything here is CONTINUOUS - not one event is placed - so there is
    nothing the loop point can cut. The modulation is three LFOs at 1, 2 and
    3 whole cycles across the loop: one on the low roar's level, one on the
    mid band's centre frequency (the water turning past you) and one on the
    high spray. Whole cycles mean the last sample's state equals the
    first's, which is what makes a 4 s texture loop for ten minutes without
    anyone noticing a period.

    The 2 Hz "turn" is deliberately slower than a wave and faster than a
    swell; that tempo is the difference between a whirlpool and surf.
    """
    dur = 4.0
    idx = np.arange(S.n(dur)) / S.n(dur)
    turn = 0.5 + 0.5 * np.sin(2.0 * np.pi * 2.0 * idx)
    sway = 0.5 + 0.5 * np.sin(2.0 * np.pi * 1.0 * idx + 0.6)
    fizz = 0.5 + 0.5 * np.sin(2.0 * np.pi * 3.0 * idx + 2.1)

    roar = S.lowpass(S.brown(dur, r), 260.0, order=2)
    roar = S.saturate(roar * 1.6, 1.9) * (0.55 + 0.45 * sway)

    mid = S.bp_sweep(S.pink(dur, r), 420.0 + 520.0 * turn, q=1.3) * (0.5 + 0.5 * turn) * 0.9
    churn = S.bandpass(S.white(dur, r), 900.0, 5200.0, order=2) * (0.30 + 0.30 * fizz) * 0.35
    spray = S.bandpass(S.white(dur, r), 5000.0, 12000.0, order=2) * (0.10 + 0.14 * fizz)

    y = S.mix(roar * 0.9, mid, churn, spray)
    y = S.lowpass(y, 11000.0, order=2)
    return _far_room(y, size=1.1, damping=0.62, mix=0.16, predelay=0.0, tail=False)


@cue("bellToll")
def bell_toll(r):
    """The Bellbuoy's sea-bell: a real struck-bell partial set with a long
    decay - see the header for why the ratios are what they are.

    Three things beyond the partials make it a bell and not an additive
    chord: the strike (4 ms of bright noise through the same resonances, so
    the attack has the bell's colour and not white noise's), a slight
    DETUNE on the upper partials so they beat against each other (a cast
    bell is never perfectly symmetric, and the beating is what makes it
    sound heavy), and a warble on the hum tone - this bell is on a buoy, so
    it is swinging as it rings.
    """
    dur = 1.9
    f0 = 220.0                   # named note A3; the hum sits an octave below
    body = np.zeros(S.n(dur))
    for k, (ratio, amp, dec) in enumerate(zip(BELL_PARTIALS, BELL_AMPS, BELL_DECAYS)):
        # Beating: each partial is a PAIR a few cents apart.
        detune = 1.0 + 0.0009 * (k + 1)
        f = f0 * ratio
        tau = 1.6 * dec
        body += S.sine(dur, f) * S.expdec(dur, tau) * amp
        body += S.sine(dur, f * detune) * S.expdec(dur, tau * 0.92) * amp * 0.7
    body /= (np.max(np.abs(body)) + 1e-12)
    body *= S.breakpoints(dur, [(0.0, 0.0), (0.0025, 1.0), (dur, 0.6)], curve="lin")

    strike = S.band_noise(0.006, r, 700.0, 11000.0) * S.perc_env(0.006, 0.0002, 0.0016)
    strike = S.fit(strike, dur)
    coloured = np.zeros(S.n(dur))
    for ratio, amp in zip(BELL_PARTIALS[:6], BELL_AMPS[:6]):
        coloured += S.resonator(strike, f0 * ratio, q=45.0) * amp
    coloured *= S.expdec(dur, 0.055)

    y = S.mix(body * 0.9, coloured * 0.45, strike * 0.25)
    y = S.vibrato(y, rate=0.55, depth_cents=6.0)        # the buoy swinging
    return _far_room(S.saturate(y * 0.75, 1.3), size=1.0, damping=0.50, mix=0.20,
                     predelay=0.03)


@cue("iceCreak")
def ice_creak(r):
    """A floe taking strain: a long stick-slip groan that BENDS UP (load
    increasing) with high crackles breaking off it, and one sharp crack near
    the end where a fracture runs. Two registers at once - a 90-200 Hz groan
    and 3-10 kHz splinters - with nothing in between, which is exactly what
    ice does and what no other cue in the game does."""
    dur = 1.6
    out = S.silence(dur)

    # The groan: irregular grains through a comb, bending up.
    grains = S.silence(1.15)
    at = 0.01
    while at < 1.10:
        g = S.band_noise(0.005, r, 300.0, 4000.0) * S.perc_env(0.005, 0.0002, 0.0014)
        grains = S.place(grains, g * (0.3 + 0.7 * float(r.random())), at)
        at += (1.0 / 22.0) * (0.4 + 1.1 * float(r.random()))
    groan = S.comb(S.fit(grains, 1.15), 1.0 / 92.0, feedback=0.90, damp=0.35)
    groan = S.bp_sweep(groan, S.expsweep(1.15, 190.0, 330.0), q=2.0)
    groan *= S.breakpoints(1.15, [(0.0, 0.0), (0.10, 0.8), (0.80, 1.0), (1.15, 0.0)],
                           curve="exp")
    groan /= (np.max(np.abs(groan)) + 1e-12)
    out = S.place(out, groan * 0.85, 0.0)

    # Splinters coming off it, getting denser as the strain rises.
    for k in range(26):
        u = float(r.random()) ** 0.7
        at = 0.06 + u * 1.05
        f = 3200.0 * float(2.0 ** (r.random() * 1.5))
        g = S.band_noise(0.0025, r, f, min(15500.0, f * 3.2))
        g *= S.perc_env(0.0025, 0.0001, 0.0006)
        out = S.place(out, g * (0.10 + 0.28 * u) * (0.4 + 0.6 * float(r.random())), at)

    # The fracture: one hard crack with a short ringing tail.
    crack = S.band_noise(0.004, r, 900.0, 14000.0) * S.perc_env(0.004, 0.0001, 0.0009)
    exc = S.fit(crack, 0.45)
    ring = (S.resonator(exc, 1250.0, q=16.0) * 0.7 + S.resonator(exc, 2900.0, q=12.0) * 0.4
            + S.resonator(exc, 460.0, q=10.0) * 0.5)
    ring *= S.expdec(0.45, 0.055)
    out = S.place(out, S.mix(S.fit(crack, 0.45) * 0.8, ring), 1.02)
    sub = S.sine(0.4, S.expsweep(0.4, 110.0, 42.0)) * S.perc_env(0.4, 0.002, 0.085)
    out = S.place(out, S.saturate(sub * 0.5, 2.2), 1.02)
    return _far_room(out * 0.85, size=1.1, damping=0.55, mix=0.20)


@cue("gullCry", variants=3)
def gull_cry(r, i):
    """Three gull calls, made the way a bird actually is: a buzzy narrow
    pulse (the syrinx) whose PITCH bends, sent through three FIXED formant
    resonances (the throat and beak, which do not move much). Keeping the
    formants still while the pitch moves is the whole trick - sweep them
    together and you get a synth siren instead of an animal.

    variant 1  the classic two-note "kee-yaa": a fast snap up, a held note,
               then a long sagging fall.
    variant 2  three short barks on a descending line - the alarm call.
    variant 3  one long rising-then-falling wail, further away and softer.
    """
    if i % 3 == 0:
        dur = 0.85
        calls = [(0.00, 0.30, [(0.0, 620.0), (0.05, 1250.0), (0.30, 1180.0)], 1.0),
                 (0.33, 0.46, [(0.0, 1180.0), (0.10, 1320.0), (0.46, 640.0)], 0.95)]
        formants, gains, size = (900.0, 2100.0, 3600.0), (1.0, 0.55, 0.28), 0.9
        level, breath = 1.0, 0.22
    elif i % 3 == 1:
        dur = 0.80
        calls = [(0.00, 0.15, [(0.0, 1150.0), (0.03, 1400.0), (0.15, 1100.0)], 1.0),
                 (0.22, 0.15, [(0.0, 1060.0), (0.03, 1290.0), (0.15, 1000.0)], 0.9),
                 (0.44, 0.20, [(0.0, 960.0), (0.03, 1160.0), (0.20, 820.0)], 0.8)]
        formants, gains, size = (1000.0, 2300.0, 3900.0), (1.0, 0.6, 0.3), 0.85
        level, breath = 0.95, 0.18
    else:
        dur = 1.25
        calls = [(0.00, 1.00, [(0.0, 700.0), (0.22, 1150.0), (0.45, 1210.0),
                               (1.00, 720.0)], 1.0)]
        formants, gains, size = (820.0, 1900.0, 3200.0), (1.0, 0.5, 0.20), 1.4
        level, breath = 0.75, 0.30

    out = S.silence(dur)
    for at, ln, points, amp in calls:
        f = S.breakpoints(ln, points, curve="exp")
        # A narrow pulse is buzzy - lots of harmonics for the formants to eat.
        src = S.pulse(ln, f, 0.16)
        src = S.mix(src * 0.8, S.white(ln, r) * breath)
        voice = S.formant(src, list(formants), qs=[11.0, 9.0, 7.0], gains=list(gains))
        voice /= (np.max(np.abs(voice)) + 1e-12)
        voice *= S.breakpoints(ln, [(0.0, 0.0), (ln * 0.10, 1.0), (ln * 0.55, 0.85),
                                    (ln, 0.0)], curve="exp")
        out = S.place(out, voice * amp, at)
    out = S.highpass(out, 420.0, order=2)
    return _far_room(out * level, size=size, damping=0.55, mix=0.20, predelay=0.02)


# ---------------------------------------------------------------------------
# THE SHOWREEL AND THE NUMERIC AUDIT
#
# Neither runs on import - `build.py` imports every `sfx_*.py` just to collect
# its cues, and importing must never render audio. Run this file directly:
#
#     python3 assets/audio_gen/sfx_world.py
#
# Both belong to this lane's six sheets (boat, character, combat, ui,
# progression, world) rather than to any one of them, which is why they live
# behind one __main__ instead of being copied into six modules.
#
# WHAT IS MEASURED, AND ON WHICH SIGNAL. Two of the checks have to look at
# the RAW render rather than the finished cue, and the reason is a real bug
# in the toolkit that this lane must not edit around:
#
#   `synth.limit()` smooths its gain curve with
#       gain = sps.lfilter([1 - rc], [1, -rc], gain)
#   and lfilter defaults to ZERO initial conditions. On a signal that needs
#   no limiting at all the gain curve is a constant 1.0, but the smoother
#   starts it at 1 - rc = 4.5e-4 and takes the release time to climb: the
#   measured gain is 0.09 at 5 ms, 0.33 at 20 ms, 0.63 at 50 ms and 0.86 at
#   100 ms. `build.finish_cue` limits EVERY cue, so EVERY cue in the pack -
#   `sfx_fishing`'s included - is multiplied by a ~150 ms fade-in it never
#   asked for. The one-line fix is to pass steady-state `zi` to that lfilter
#   (synth._design_zi already exists to do exactly this for the filters), but
#   synth.py is out of this lane's scope, so it is reported, not patched.
#
#   Consequence for the audit: the finished head of every cue is attenuated,
#   so a finished-signal loop-seam ratio measures the bug rather than the
#   loop. SEAM is therefore taken on the raw render.
#
# PEAK, CLIPPING, EDGE and SUB are measured on the finished cue, because
# those are properties of what actually lands in the sheet. EDGE is the one
# that matters most: the sprite is seeked to and away from exactly those
# samples, so a non-zero value there is an audible click on every play.
#
# DC is measured as |mean| RELATIVE TO RMS, not as an absolute mean. An
# absolute threshold cannot tell a genuine offset from the two innocent
# reasons a short cue has a nonzero mean - a decaying sine is not symmetric
# about zero, and `finish_cue` trims the tail, truncating a sub-100 Hz layer
# mid-cycle. A real offset (an unbalanced saturator, an un-blocked filter)
# sits at |mean|/rms of 0.1 or more; envelope asymmetry sits three orders
# below that. Measuring the ratio separates them, and an absolute test does
# not. (Filtering out "subsonic energy" instead does not work either: a
# thunder roll is legitimately almost all sub-80 Hz, so that test flags the
# sound design rather than a defect.)
#
# There is deliberately NO pass/fail on the largest sample-to-sample step.
# At 44.1 kHz a legitimate 10 kHz component at -1 dBFS steps by 1.2 between
# adjacent samples, so on a bright percussive cue that number says "this cue
# has treble", not "this cue clicks". It is printed as a diagnostic only.
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import os
    import sys

    import numpy as np

    import build
    import cues as _cues
    import sfx_boat        # noqa: F401 - imported for the side effect of
    import sfx_character   # noqa: F401   registering their render functions
    import sfx_combat      # noqa: F401
    import sfx_progression  # noqa: F401
    import sfx_ui          # noqa: F401

    LANE = ["boat", "character", "combat", "ui", "progression", "world"]

    # A vignette, not a catalogue: two cues per sheet, in the order a player
    # meets them - called the boat, crossed the beach, weather came in, a
    # fight, and got paid - chosen so no two neighbours share a register.
    REEL = ["boatSummon", "boatEngine", "stepWood1", "stepMud1",
            "stepShallow1", "gullCry1", "thunder1", "uiEquip", "gunFire",
            "hitThump", "coinGain", "levelUp"]

    def _rms(a):
        return float(np.sqrt(np.mean(a ** 2))) if len(a) else 0.0

    mod_hashes = {}
    for _m in ("sfx_boat", "sfx_character", "sfx_combat", "sfx_ui",
               "sfx_progression", "sfx_world"):
        mod_hashes[_m] = build._file_hash(os.path.join(build.HERE, _m + ".py"))

    # -- 1. the audit -------------------------------------------------------
    print("%-24s %6s %7s %8s %5s %8s %7s %6s %s"
          % ("cue", "dur", "peak", "dc/rms", "clip", "edge", "step", "rms", "seam"))
    problems = []
    n_cues = 0
    for sheet in LANE:
        for c in _cues.by_sheet(sheet):
            if c.render is None:
                problems.append("%s UNIMPLEMENTED" % c.name)
                continue
            n_cues += 1
            raw = np.asarray(c.render(S.rng(c.name)), dtype=float)
            y = build.render_cue(c, mod_hashes, use_cache=False).astype(float)
            dur = len(y) / S.SR
            peak = float(np.max(np.abs(y)))
            dc = abs(float(np.mean(y))) / (_rms(y) + 1e-12)
            clip = int(np.sum(np.abs(y) >= 0.999))
            edge = max(abs(float(y[0])), abs(float(y[-1])))
            step = float(np.max(np.abs(np.diff(y))))
            rms = _rms(y)
            seam = ""
            if c.loop:
                # 150 ms, not 30: a 30 ms window of brown noise has enough
                # variance of its own to read as a seam that is not there.
                k = S.n(0.15)
                ratio = _rms(raw[-k:]) / (_rms(raw[:k]) + 1e-9)
                seam = "%.2f" % ratio
                if not (0.15 <= ratio <= 3.0):
                    problems.append("%s LOOP SEAM %.2f" % (c.name, ratio))
            print("%-24s %6.3f %7.4f %8.5f %5d %8.5f %7.3f %6.3f %s"
                  % (c.name, dur, peak, dc, clip, edge, step, rms, seam))
            if peak > 1.0:
                problems.append("%s PEAK %.4f" % (c.name, peak))
            if clip:
                problems.append("%s CLIPPED %d samples" % (c.name, clip))
            if dc > 0.02:
                problems.append("%s DC %.4f of rms" % (c.name, dc))
            if edge > 1e-4:
                problems.append("%s EDGE %.5f (boundary click)" % (c.name, edge))
            if rms < 0.015:
                problems.append("%s QUIET rms %.4f" % (c.name, rms))
            if not c.loop and dur > 3.0:
                problems.append("%s LONG %.2fs" % (c.name, dur))
    print()
    print("audited %d cues on %s" % (n_cues, ", ".join(LANE)))
    if problems:
        print("AUDIT PROBLEMS (%d):" % len(problems))
        for p in problems:
            print("  ", p)
    else:
        print("AUDIT CLEAN: no clipping, no DC, no boundary clicks, every "
              "one-shot under 3 s, every loop seam inside 0.15-3.0x.")

    # -- 2. the showreel ----------------------------------------------------
    reel = np.zeros(0)
    used = 0
    for name in REEL:
        c = _cues.get(name)
        if c is None or c.render is None:
            print("showreel: skipping %s (not implemented)" % name)
            continue
        audio = build.render_cue(c, mod_hashes).astype(float)
        if c.loop:
            # One extra lap cut to ~1 s, so a loop is represented without
            # taking a tenth of the reel.
            audio = np.concatenate([audio, audio])[: S.n(0.9)]
            audio = S.fade(audio, 0.01, 0.06)
        # 0.4 s between cues, and none hanging off the end.
        if used:
            reel = np.concatenate([reel, S.silence(0.4)])
        reel = np.concatenate([reel, audio])
        used += 1
    reel = S.normalize(reel, -1.5)
    os.makedirs(build.PREVIEW_DIR, exist_ok=True)
    out_path = os.path.join(build.PREVIEW_DIR, "showreel_gameplay.wav")
    S.write_wav(out_path, S.stereo_width(reel, width=0.35), stereo=True)
    print("showreel: %s (%d cues, %.1fs)"
          % (os.path.relpath(out_path, build.ROOT), used, len(reel) / S.SR))
    sys.exit(1 if problems else 0)
