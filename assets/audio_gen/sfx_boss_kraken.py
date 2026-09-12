"""sfx_boss_kraken.py - the Maw of the Maelstrom. The end of the sea.

THE VOICE: EVERYTHING, BIGGER. This is the last boss in the game and the
sheet is authored against the other six rather than in isolation: every cue
here has to be recognisably the same KIND of event as its cousin on another
sheet and unmistakably larger. Three rules do that work:

* TONNAGE, NOT SPLASH (`_ocean`). Brinejaw's water is a wave crossing an
  arena; the Kraken's is the arena itself moving. `_ocean` is the same
  no-transient filtered swell taken a full octave lower, with a second slow
  layer under it so it never resolves into one gesture - the ear cannot find
  the edges of it, which is exactly how a storm sounds.
* THE ROAR IS THE DEEPEST THING IN THE GAME. `krakenRoar` runs a 32 Hz
  fundamental with the subharmonic stack under it and formants at
  140/560/1500 - lower than Pyrelisk's 36 Hz magma throat, which was the
  previous floor. Nothing else in the pack is allowed under it, and the two
  are deliberately a whole tone apart so a player who has fought both can
  tell them apart in the dark.
* INK IS A MATERIAL (`_ink`). Thick, wet and heavy - a low, viscous
  splatter with almost no top end and a long clinging tail. It is the one
  sound in the game with no hard edge at all, which is what makes the ink
  attacks read as fluid rather than as impacts.

THE ROOM IS THE STORM. `_room` here is the biggest on any sheet (RT ~2.6 s)
and the most damped at the top - a wall of rain and spray eats high
frequencies - so cues that would be bright anywhere else come back darker,
and the arena itself is audible in every one of them.
"""

import numpy as np

import synth as S
from cues import cue


# build.py puts a 3 ms fade on the HEAD of every cue as click insurance, so a
# transient at t=0 loses its own peak to it. Four milliseconds of silence in
# front of every one-shot puts the attack clear of the fade.
HEAD_LEAD = 0.004


def _room(x, size=2.4, damping=0.56, mix=0.30, predelay=0.026, tail=True,
          cap=None):
    """The Maelstrom: the largest arena in the game and the wettest. High
    damping is the rain wall - it is why nothing on this sheet is ever
    bright, however hard it is struck."""
    # 28 Hz and ORDER 4, steeper than any other sheet's. This one runs a
    # 32 Hz fundamental with a subharmonic stack under it, so an order-2
    # corner at 26 leaves a tenth of the roar's energy under 22 Hz - real
    # signal that no speaker reproduces and that the peak normalise then
    # charges the audible part for. See sfx_boss_shared._room.
    x = S.highpass(x, 28.0, order=4)
    y = S.reverb(x, size=size, damping=damping, mix=mix, predelay=predelay,
                 seed=5, tail=tail)
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


def _sub(dur, f0, f1, tau=None, drive=2.6, attack=0.003):
    if tau is None:
        tau = float(dur) * 0.36
    return S.saturate(S.sine(dur, S.expsweep(dur, f0, f1)) *
                      S.perc_env(dur, attack, tau), drive)


# ---------------------------------------------------------------------------
# the three materials
# ---------------------------------------------------------------------------

def _ocean(dur, r, low=40.0, high=6000.0, open_to=2200.0, close_to=300.0,
           peak=0.62, body=0.85, slow=0.55):
    """WATER BY THE THOUSAND TONS.

    The same shape as any big-water cue - a filter that opens as it arrives
    and closes as it passes, with a sub swelling under it and no transient
    anywhere - but an octave down and with a SECOND, slower layer offset
    from the first. That offset is what stops it resolving into a single
    gesture: the ear cannot find the edge of the event, which is what makes
    it a sea rather than a wave.
    """
    wash = S.band_noise(dur, r, low, high, order=2)
    wash = S.lp_sweep(wash, S.breakpoints(dur, [(0.0, low * 3.0),
                                                (dur * peak, open_to),
                                                (dur, close_to)], curve="exp"),
                      order=2)
    wash *= S.breakpoints(dur, [(0.0, 0.0), (dur * peak * 0.72, 0.8),
                                (dur * peak, 1.0), (dur, 0.05)], curve="exp")
    wash = S.tremolo(wash, rate=1.7, depth=0.18)
    out = _lvl(wash, 1.0)
    if slow > 0:
        deep = S.band_noise(dur, r, low * 0.7, 1400.0, order=2)
        deep = S.lp_sweep(deep, S.breakpoints(dur, [(0.0, 110.0),
                                                    (dur * min(0.95, peak + 0.22),
                                                     620.0),
                                                    (dur, 180.0)], curve="exp"),
                          order=2)
        deep *= S.breakpoints(dur, [(0.0, 0.0), (dur * min(0.95, peak + 0.22), 1.0),
                                    (dur, 0.08)], curve="exp")
        out = S.mix(out, _lvl(deep, slow))
    swell = S.sine(dur, S.expsweep(dur, 28.0, 48.0))
    swell *= S.breakpoints(dur, [(0.0, 0.0), (dur * peak, 1.0), (dur, 0.06)],
                           curve="exp")
    return S.mix(out, _lvl(S.saturate(swell, 2.6), body))


def _ink(dur, r, freq=110.0, thick=0.85, cling=0.7):
    """THICK WET. Ink is not water: it is heavy, viscous and has no top end
    at all, and it CLINGS - so the tail is a long low gurgle rather than
    spray. The absence of a hard edge is the whole identity."""
    splat = S.band_noise(dur * 0.5, r, 60.0, 2600.0, order=3)
    splat = S.lp_sweep(splat, S.expsweep(dur * 0.5, 2000.0, 160.0), order=2)
    splat *= S.perc_env(dur * 0.5, 0.004, dur * 0.10, curve=1.4)
    body = S.membrane(dur, freq, r, drop=0.6, noise=0.18, tau=dur * 0.24)
    body = S.lowpass(S.saturate(body, 2.4), 700.0, order=2)
    out = S.mix(_lvl(S.fit(splat, dur), thick), _lvl(body, 1.0))
    if cling > 0:
        goo = S.wet_texture(dur, r, density=22.0, freq=120.0, spread=3.0, level=0.6)
        goo = S.lowpass(goo, 1100.0, order=2)
        out = S.mix(out, _lvl(goo, cling * 0.42))
    return S.lowpass(out, 3400.0, order=2)


def _limb(dur, r, freq=54.0, wet=0.8, drive=2.7):
    """A TENTACLE. Tonnage with water in it: a low saturated body with a
    heavy wet skin and slosh through the whole of it. Not stone, not ice -
    when this lands it should sound absorbent."""
    body = S.membrane(dur, freq, r, drop=0.52, noise=0.22, tau=dur * 0.28)
    body = S.saturate(body, drive)
    skin = S.band_noise(dur * 0.55, r, 130.0, 4200.0, order=3)
    skin = S.lp_sweep(skin, S.expsweep(dur * 0.55, 3800.0, 300.0), order=2)
    skin *= S.perc_env(dur * 0.55, 0.002, dur * 0.10, curve=1.3)
    out = S.mix(_lvl(body, 1.0), _lvl(S.fit(skin, dur), wet * 0.6))
    slosh = S.wet_texture(dur, r, density=20.0, freq=180.0, spread=2.8, level=0.55)
    return S.mix(out, _lvl(slosh, wet * 0.30))


def _gale(dur, r, level=1.0, rate=0.9):
    """STORM WIND. Broad, wide and slow-moving, with the pitch of the band
    wandering - a gale is not a hiss, it is a filter that never stops
    changing its mind."""
    wind = S.band_noise(dur, r, 150.0, 13000.0, order=2)
    centre = 1100.0 + 600.0 * np.sin(2.0 * np.pi * rate * S.t(dur)) + \
        260.0 * np.sin(2.0 * np.pi * rate * 2.3 * S.t(dur) + 1.0)
    wind = S.bp_sweep(wind, centre, q=1.0)
    gust = (0.6 + 0.4 * np.sin(2.0 * np.pi * rate * S.t(dur) + 0.4)) * \
           (0.78 + 0.22 * np.sin(2.0 * np.pi * rate * 3.1 * S.t(dur)))
    return _lvl(wind * gust, level)


def _thunder(dur, r, near=1.0):
    """A THUNDER ROLL. The crack (only when it is close), then the roll:
    the roll is what says how far away it is, and it is built as a long
    low-passed noise bed whose brightness falls as it goes, because distance
    eats the top end of everything behind the first arrival."""
    out = S.silence(dur)
    if near > 0.4:
        crack = S.band_noise(0.16, r, 200.0, 16000.0, order=3)
        crack = S.lp_sweep(crack, S.expsweep(0.16, 14000.0, 700.0), order=2)
        crack *= S.perc_env(0.16, 0.0004, 0.012, curve=1.2)
        out = S.place(out, _lvl(crack, near), 0.0)
    roll = S.brown(dur, r)
    roll = S.bandpass(roll, 34.0, 900.0, order=2)
    roll = roll * S.breakpoints(dur, [(0.0, 0.15), (0.06, 1.0), (dur * 0.45, 0.75),
                                      (dur * 0.75, 0.45), (dur, 0.0)], curve="exp")
    roll = S.tremolo(roll, rate=3.1, depth=0.30)
    roll = S.tremolo(roll, rate=1.3, depth=0.25)
    out = S.mix(out, _lvl(S.saturate(roll * 1.4, 2.8), 0.95))
    return out


def _krak_growl(dur, r, f0=34.0, bend=(0.92, 1.22, 0.66), rasp=0.7, sub=1.0,
                bright=0.7, flutter=11.0):
    """THE DEEPEST THROAT IN THE GAME.

    A 34 Hz fundamental (Pyrelisk, the previous floor, is 36), formants
    placed very low and very wide apart (140/560/1500 - a cavity the size of
    a ship), and the slowest flutter anywhere in the pack: at this size the
    vocal folds cannot move quickly, and hearing the individual pulses is
    most of what makes the scale believable.
    """
    contour = S.breakpoints(dur, [(0.0, f0 * bend[0]), (dur * 0.33, f0 * bend[1]),
                                  (dur, f0 * bend[2])], curve="exp")
    core = S.saw(dur, contour, bright=0.8) * 0.6 + S.pulse(dur, contour, 0.33) * 0.5
    core = S.moog(core, S.breakpoints(dur, [(0.0, 280.0), (dur * 0.3, 2000.0 * bright),
                                            (dur, 400.0)], curve="exp"), res=0.36)
    throat = S.formant(core, [140.0, 560.0, 1500.0], qs=[13.0, 8.0, 5.0],
                       gains=[1.0, 0.55, 0.22])
    voice = S.mix(_lvl(core, 0.30), _lvl(throat, 0.95))
    if rasp > 0:
        edge = S.band_noise(dur, r, 170.0, 3200.0 * bright, order=2)
        edge = S.tremolo(edge, rate=flutter, depth=0.9)
        edge *= S.breakpoints(dur, [(0.0, 0.0), (0.06, 1.0), (dur, 0.4)])
        voice = S.mix(voice, _lvl(edge, rasp * 0.45))
    if sub > 0:
        # Order 4 at 30 Hz: at a 34 Hz fundamental the octave-down partial
        # is 17 Hz and the two-octave one is 8.5, both inaudible and both
        # expensive in headroom.
        low = S.highpass(S.sine(dur, contour * 0.5) +
                         S.sine(dur, contour * 0.25) * 0.5, 30.0, order=4)
        voice = S.mix(voice, _lvl(S.saturate(low, 2.2), sub * 0.9))
    return voice


# ---------------------------------------------------------------------------
# the seven voice variants - the shared vocabulary at maelstrom scale
# ---------------------------------------------------------------------------

@cue("bossTell__kraken")
def tell_kraken(r):
    """The sea decides. There is no body to hear winding up - the tell is
    the WATER changing: a suck as the surface is drawn down somewhere, the
    gale dropping for a beat (silence is the loudest warning this fight
    has), and one very low note coming up from underneath."""
    dur = 1.00
    out = S.silence(dur)
    draw = S.band_noise(dur, r, 50.0, 3400.0, order=2)
    draw = S.bp_sweep(draw, S.breakpoints(dur, [(0.0, 700.0), (0.65, 300.0),
                                                (dur, 180.0)], curve="exp"), q=1.8)
    draw *= S.breakpoints(dur, [(0.0, 0.0), (0.20, 0.9), (0.80, 1.0), (dur, 0.0)],
                          curve="exp")
    out = S.mix(out, _lvl(draw, 1.0))
    # The gale drops away rather than swells - the hole in the noise is the
    # thing the player learns to hear.
    lull = _gale(dur, r, level=1.0, rate=1.1)
    lull *= S.breakpoints(dur, [(0.0, 1.0), (0.35, 0.7), (0.72, 0.12), (dur, 0.5)],
                          curve="exp")
    out = S.mix(out, _lvl(lull, 0.40))
    rise = S.sine(dur, S.expsweep(dur, 34.0, 60.0))
    rise *= S.breakpoints(dur, [(0.0, 0.0), (0.78, 1.0), (dur, 0.15)], curve="exp")
    out = S.mix(out, _lvl(S.saturate(rise, 2.6), 0.55))
    return _room(out, size=2.0, mix=0.28, cap=1.40)


@cue("bossRise__kraken")
def rise_kraken(r):
    """Something the size of an island coming up under the ship. The whole
    ocean is displaced: `_ocean` at its slowest and lowest, the surface
    tearing open near the top of it, and the sub climbing the entire way."""
    dur = 2.40
    out = _ocean(2.1, r, low=34.0, high=6500.0, open_to=2600.0, close_to=700.0,
                 peak=0.80, body=0.95, slow=0.7)
    out = S.fit(out, dur)
    out = S.place(out, _lvl(S.splash(0.9, r, low=200.0, high=6000.0, sweep_to=200.0,
                                     body=0.6), 0.45), 1.55)
    out = S.place(out, _lvl(S.wet_texture(1.0, r, density=24.0, freq=520.0,
                                          spread=3.0, level=0.55), 0.30), 1.65)
    out = S.mix(out, _lvl(S.fit(_gale(dur, r, level=1.0, rate=0.8), dur), 0.20))
    return _room(out, size=2.5, damping=0.54, mix=0.31, cap=2.90)


@cue("bossRoar__kraken")
def roar_kraken(r):
    """THE DEEPEST, BIGGEST THING IN THE GAME. A 34 Hz throat with the
    subharmonic stack under it, the ocean answering underneath, and the
    storm behind that - three enormous layers, none of them fast, in the
    largest room on any sheet."""
    dur = 2.50
    voice = _krak_growl(dur, r, f0=34.0, bend=(0.90, 1.26, 0.62), rasp=0.75,
                        sub=1.0, bright=0.75, flutter=10.0)
    voice = S.saturate(voice * 1.25, 2.1)
    voice *= S.breakpoints(dur, [(0.0, 0.0), (0.10, 0.7), (dur * 0.34, 1.0),
                                 (dur * 0.64, 0.85), (dur * 0.92, 0.22), (dur, 0.0)],
                           curve="exp")
    floor = _sub(dur, 42.0, 26.0, tau=1.10, drive=3.2, attack=0.04)
    sea = _ocean(dur, r, low=36.0, high=3000.0, open_to=900.0, close_to=260.0,
                 peak=0.45, body=0.7, slow=0.6)
    y = S.mix(_lvl(voice, 1.0), _lvl(floor, 0.60), _lvl(sea, 0.38))
    y = S.mix(y, _lvl(_gale(dur, r, level=1.0, rate=0.7), 0.16))
    return _room(y, size=2.8, damping=0.52, mix=0.33, predelay=0.030, cap=3.20)


@cue("bossSnap__kraken")
def snap_kraken(r):
    """The beak. A cephalopod's beak is HORN, not bone - so this is a hard,
    dry, mid-register clack with no ring at all, and it is startling
    precisely because everything else on this sheet is soft and wet."""
    dur = 0.70
    out = S.silence(dur)
    draw = S.band_noise(0.13, r, 120.0, 3000.0, order=2)
    draw = S.bp_sweep(draw, S.expsweep(0.13, 260.0, 900.0), q=2.2)
    draw *= S.breakpoints(0.13, [(0.0, 0.0), (0.10, 1.0), (0.13, 0.0)], curve="exp")
    out = S.place(out, _lvl(draw, 0.42), 0.0)
    clack = S.band_noise(0.05, r, 600.0, 12000.0, order=3)
    clack = S.lp_sweep(clack, S.expsweep(0.05, 10000.0, 800.0), order=2)
    clack *= S.perc_env(0.05, 0.0003, 0.004, curve=1.2)
    out = S.place(out, _lvl(clack, 1.0), 0.100)
    for i, f in enumerate((310.0, 505.0, 790.0)):
        out = S.place(out, S.bar(0.20, f, r, decay=0.026 - 0.005 * i,
                                 strike=0.95) * (0.6 - 0.15 * i), 0.101)
    out = S.place(out, _lvl(_sub(0.45, 86.0, 36.0, tau=0.12, drive=2.7), 0.75), 0.101)
    out = S.place(out, _lvl(_limb(0.30, r, freq=76.0, wet=0.85), 0.42), 0.108)
    return _room(out, size=2.0, damping=0.54, mix=0.24, cap=1.05)


@cue("bossSlam__kraken")
def slam_kraken(r):
    """An arm coming down across the deck. Wet tonnage - no crack, because
    there is nothing hard in it - so the front is a broad water impact and
    what carries is a 26 Hz body and the sea thrown out from under it."""
    dur = 1.95
    out = S.silence(dur)
    out = S.place(out, _lvl(S.band_noise(0.15, r, 150.0, 7000.0, order=3) *
                            S.perc_env(0.15, 0.0012, 0.020), 0.65), 0.0)
    out = S.place(out, _lvl(_limb(1.10, r, freq=44.0, wet=0.85, drive=2.9), 1.0),
                  0.003)
    out = S.place(out, _lvl(_sub(1.55, 48.0, 26.0, tau=0.50, drive=3.2), 1.0), 0.003)
    out = S.place(out, _lvl(S.splash(0.7, r, low=180.0, high=5600.0, sweep_to=190.0,
                                     body=0.55), 0.48), 0.020)
    out = S.place(out, _lvl(S.wet_texture(0.9, r, density=24.0, freq=280.0,
                                          level=0.55), 0.30), 0.10)
    return _room(out, size=2.5, damping=0.54, mix=0.31, predelay=0.026, cap=2.50)


@cue("bossDown__kraken")
def down_kraken(r):
    """It goes back under. The sea closing over something enormous - a long
    descending wash, the throat trailing off underneath it, and the storm
    still going afterwards, because the Maelstrom does not stop for this."""
    dur = 2.70
    out = S.silence(dur)
    sink = S.band_noise(2.1, r, 45.0, 5000.0, order=2)
    sink = S.lp_sweep(sink, S.expsweep(2.1, 3200.0, 200.0), order=2)
    sink *= S.breakpoints(2.1, [(0.0, 0.4), (0.30, 1.0), (2.1, 0.06)], curve="exp")
    out = S.place(out, _lvl(sink, 0.80), 0.0)
    last = _krak_growl(1.4, r, f0=36.0, bend=(1.1, 0.85, 0.48), rasp=0.55, sub=1.0,
                       bright=0.5, flutter=9.0)
    last *= S.breakpoints(1.4, [(0.0, 0.0), (0.12, 0.9), (0.8, 0.45), (1.4, 0.0)],
                          curve="exp")
    out = S.place(out, _lvl(last, 0.85), 0.05)
    out = S.place(out, _lvl(_sub(1.9, 50.0, 25.0, tau=0.78, drive=3.1, attack=0.05),
                            0.88), 0.85)
    out = S.place(out, _lvl(S.splash(1.1, r, low=170.0, high=5800.0, sweep_to=175.0,
                                     body=0.8), 0.72), 0.95)
    out = S.mix(out, _lvl(S.fit(_gale(dur, r, level=1.0, rate=0.8), dur), 0.22))
    return _room(out, size=2.6, damping=0.54, mix=0.32, cap=3.10)


@cue("bossStagger__kraken")
def stagger_kraken(r):
    """The window. An arm fails and comes down full length across the deck -
    the heaviest wet impact in the game, and then the limb LYING there,
    twitching and sloshing, for as long as the party has to work. The
    sloshing is the window, so it is what runs on."""
    dur = 2.50
    out = S.silence(dur)
    out = S.place(out, _lvl(S.band_noise(0.18, r, 130.0, 6500.0, order=3) *
                            S.perc_env(0.18, 0.0015, 0.024), 0.60), 0.0)
    out = S.place(out, _lvl(_limb(1.25, r, freq=38.0, wet=0.9, drive=3.0), 1.0), 0.004)
    out = S.place(out, _lvl(_sub(1.85, 44.0, 25.0, tau=0.62, drive=3.3), 1.0), 0.004)
    groan = _krak_growl(1.3, r, f0=38.0, bend=(1.0, 0.84, 0.56), rasp=0.6, sub=0.95,
                        bright=0.55, flutter=10.0)
    groan *= S.breakpoints(1.3, [(0.0, 0.0), (0.16, 1.0), (0.68, 0.5), (1.3, 0.0)],
                           curve="exp")
    out = S.place(out, _lvl(groan, 0.55), 0.32)
    for at in (0.55, 0.95, 1.45):
        out = S.place(out, _lvl(_limb(0.42, r, freq=62.0, wet=0.9, drive=2.2),
                                0.20 + 0.10 * float(r.random())), at)
    out = S.place(out, _lvl(S.wet_texture(1.4, r, density=20.0, freq=250.0,
                                          spread=3.0, level=0.55), 0.28), 0.30)
    return _room(out, size=2.6, damping=0.54, mix=0.32, predelay=0.028, cap=2.95)


# ---------------------------------------------------------------------------
# the eleven
# ---------------------------------------------------------------------------

@cue("krakenTentacleRise")
def kraken_tentacle_rise(r):
    """AN ARM COMING OUT OF THE SEA. Storm-sized water tonnage: the surface
    tearing, a column of water going up with the limb, and the whole thing
    still climbing when the cue ends - it is a warning, and it must not
    resolve, because the thing is still on its way up."""
    dur = 1.90
    out = S.silence(dur)
    tear = S.band_noise(1.6, r, 60.0, 7000.0, order=2)
    tear = S.lp_sweep(tear, S.breakpoints(1.6, [(0.0, 260.0), (1.15, 3000.0),
                                                (1.6, 1200.0)], curve="exp"), order=2)
    tear *= S.breakpoints(1.6, [(0.0, 0.0), (0.9, 0.75), (1.25, 1.0), (1.6, 0.15)],
                          curve="exp")
    out = S.place(out, _lvl(tear, 1.0), 0.0)
    out = S.place(out, _lvl(_sub(1.7, 32.0, 58.0, tau=0.75, drive=3.0, attack=0.05),
                            0.85), 0.0)
    out = S.place(out, _lvl(S.wet_texture(1.0, r, density=30.0, freq=480.0,
                                          spread=2.8, level=0.6), 0.34), 0.75)
    out = S.place(out, _lvl(_limb(0.9, r, freq=58.0, wet=0.9, drive=2.2), 0.42), 0.55)
    return _room(out, size=2.4, damping=0.54, mix=0.30, cap=2.30)


@cue("krakenTentaclelash")
def kraken_tentaclelash(r):
    """The arm whipping across. It is enormous and it MOVES - a broad wet
    rush with a real Doppler arc in it and the tip cracking the air at the
    end of the stroke, which is the only fast thing on this sheet."""
    dur = 1.35
    out = S.silence(dur)
    lash = S.band_noise(dur, r, 90.0, 9000.0, order=2)
    lash = S.bp_sweep(lash, S.breakpoints(dur, [(0.0, 260.0), (0.46, 1700.0),
                                                (0.58, 1200.0), (dur, 300.0)],
                                          curve="exp"), q=1.7)
    lash *= S.breakpoints(dur, [(0.0, 0.0), (0.18, 0.5), (0.48, 1.0), (0.62, 0.6),
                                (dur, 0.0)], curve="exp")
    out = S.mix(out, _lvl(lash, 1.0))
    mass = S.sine(dur, S.expsweep(dur, 120.0, 46.0))
    mass *= S.breakpoints(dur, [(0.0, 0.0), (0.50, 1.0), (dur, 0.0)], curve="exp")
    out = S.mix(out, _lvl(S.saturate(mass, 2.6), 0.55))
    out = S.place(out, _lvl(S.wet_texture(0.6, r, density=26.0, freq=380.0,
                                          level=0.55), 0.26), 0.30)
    # The tip: a wet crack at the end of the stroke.
    tip = S.band_noise(0.06, r, 500.0, 12000.0, order=3)
    tip = S.lp_sweep(tip, S.expsweep(0.06, 10000.0, 700.0), order=2)
    tip *= S.perc_env(0.06, 0.0004, 0.005, curve=1.2)
    out = S.place(out, _lvl(tip, 0.55), 0.585)
    return _room(out, size=2.3, damping=0.54, mix=0.28, cap=1.75)


@cue("krakenRingwave")
def kraken_ringwave(r):
    """A ring of sea going out from the body. `_ocean` fired three times at
    a widening spacing - the widening IS the ring expanding, and it is the
    only thing in a one-shot that can convey distance travelled."""
    dur = 2.00
    out = S.silence(dur)
    at = 0.0
    for i in range(3):
        ring = _ocean(0.95, r, low=44.0, high=5000.0, open_to=1700.0, close_to=340.0,
                      peak=0.42, body=0.75, slow=0.45)
        out = S.place(out, _lvl(ring, 0.95 - 0.20 * i), at)
        out = S.place(out, _lvl(S.splash(0.30, r, low=400.0, high=6000.0,
                                         sweep_to=300.0, body=0.25),
                                0.26 - 0.05 * i), at + 0.30)
        at += 0.34 + 0.13 * i             # widening: each ring is further out
    return _room(out, size=2.4, damping=0.56, mix=0.30, cap=2.40)


@cue("krakenClosingfist")
def kraken_closingfist(r):
    """Arms closing into a ring around the ship. Everything CONVERGES: the
    filters close, the register falls, and the wet layers get denser as the
    gap shuts. Nothing arrives - the cue is the gap closing, and it ends
    just before it does."""
    dur = 1.60
    close = S.band_noise(dur, r, 55.0, 5000.0, order=2)
    close = S.lp_sweep(close, S.breakpoints(dur, [(0.0, 2400.0), (0.8, 900.0),
                                                  (dur, 260.0)], curve="exp"),
                       order=2)
    close *= S.breakpoints(dur, [(0.0, 0.0), (0.25, 0.8), (1.15, 1.0), (dur, 0.10)],
                           curve="exp")
    grip = S.sine(dur, S.expsweep(dur, 78.0, 34.0))
    grip *= S.breakpoints(dur, [(0.0, 0.0), (0.55, 0.85), (1.20, 1.0), (dur, 0.08)],
                          curve="exp")
    slosh = S.wet_texture(dur, r, density=26.0, freq=200.0, spread=2.8, level=0.6)
    slosh = slosh * S.breakpoints(dur, [(0.0, 0.2), (1.2, 1.0), (dur, 0.4)])
    y = S.mix(_lvl(close, 1.0), _lvl(S.saturate(grip, 2.8), 0.70), _lvl(slosh, 0.30))
    return _room(y, size=2.4, damping=0.56, mix=0.29, cap=2.00)


@cue("krakenInkspit")
def kraken_inkspit(r):
    """A gout of ink leaving the siphon. THICK WET: a pressurised heave, and
    then something heavy and viscous in the air - no spray, no brightness,
    and a tail that clings rather than falls."""
    dur = 1.00
    out = S.silence(dur)
    charge = S.band_noise(0.26, r, 90.0, 2400.0, order=2)
    charge = S.bp_sweep(charge, S.expsweep(0.26, 200.0, 800.0), q=2.4)
    charge *= S.breakpoints(0.26, [(0.0, 0.0), (0.21, 1.0), (0.26, 0.5)], curve="exp")
    out = S.place(out, _lvl(charge, 0.60), 0.0)
    jet = S.band_noise(0.42, r, 80.0, 3600.0, order=2)
    jet = S.lp_sweep(jet, S.expsweep(0.42, 2800.0, 260.0), order=2)
    jet *= S.breakpoints(0.42, [(0.0, 0.0), (0.02, 1.0), (0.42, 0.0)], curve="exp")
    out = S.place(out, _lvl(jet, 1.0), 0.24)
    out = S.place(out, _lvl(_ink(0.55, r, freq=120.0, thick=0.85, cling=0.8), 0.75),
                  0.26)
    out = S.place(out, _lvl(_sub(0.5, 96.0, 42.0, tau=0.14, drive=2.6), 0.50), 0.245)
    return _room(out, size=2.1, damping=0.58, mix=0.26, cap=1.45)


@cue("krakenInknova")
def kraken_inknova(r):
    """A DEEP SWALLOWING DETONATION. The ink does not explode outward - it
    goes off and then takes the sound with it: a huge low body, and then a
    filter closing over the whole arena so the room itself is muffled for a
    second afterwards. That inversion (a blast that ends in LESS sound than
    it started with) is the cue's whole identity."""
    dur = 2.60
    out = S.silence(dur)
    # The detonation: all body, no crack.
    out = S.place(out, _lvl(S.band_noise(0.20, r, 90.0, 4000.0, order=3) *
                            S.perc_env(0.20, 0.0025, 0.030), 0.65), 0.0)
    out = S.place(out, _lvl(_ink(1.20, r, freq=52.0, thick=1.0, cling=0.9), 1.0),
                  0.002)
    out = S.place(out, _lvl(_sub(1.90, 46.0, 24.0, tau=0.70, drive=3.3), 1.0), 0.002)
    # The swallow: a band that opens for a moment and then shuts to nothing,
    # taking the arena with it.
    swallow = S.band_noise(1.60, r, 50.0, 7000.0, order=2)
    swallow = S.lp_sweep(swallow, S.breakpoints(1.60, [(0.0, 3600.0), (0.28, 1600.0),
                                                       (1.60, 120.0)], curve="exp"),
                         order=2)
    swallow *= S.breakpoints(1.60, [(0.0, 0.0), (0.05, 1.0), (0.7, 0.35),
                                    (1.60, 0.0)], curve="exp")
    out = S.place(out, _lvl(swallow, 0.70), 0.010)
    out = S.place(out, _lvl(S.wet_texture(1.2, r, density=18.0, freq=150.0,
                                          spread=3.0, level=0.55), 0.26), 0.45)
    return _room(S.lowpass(out, 5200.0, order=2), size=2.6, damping=0.60, mix=0.32,
                 predelay=0.026, cap=3.00)


@cue("krakenUndertow")
def kraken_undertow(r):
    """PULLING WATER. The whole sea going one way, and it is the longest
    sustained cue on the sheet because the answer to it is five seconds of
    walking. Everything descends and NOTHING resolves: the filter closes,
    the pitch falls, the level holds - a pull that ends is a pull you can
    stop bracing against."""
    dur = 2.20
    drag = S.band_noise(dur, r, 40.0, 4600.0, order=2)
    drag = S.lp_sweep(drag, S.breakpoints(dur, [(0.0, 2600.0), (0.9, 1000.0),
                                                (dur, 240.0)], curve="exp"), order=2)
    drag *= S.breakpoints(dur, [(0.0, 0.0), (0.22, 0.85), (1.7, 1.0), (dur, 0.06)],
                          curve="exp")
    drag = S.tremolo(drag, rate=1.4, depth=0.18)
    hole = S.sine(dur, S.expsweep(dur, 62.0, 27.0))
    hole *= S.breakpoints(dur, [(0.0, 0.0), (0.5, 0.9), (1.8, 1.0), (dur, 0.06)],
                          curve="exp")
    swirl = S.wet_texture(dur, r, density=16.0, freq=260.0, spread=3.0, level=0.55)
    y = S.mix(_lvl(drag, 1.0), _lvl(S.saturate(hole, 3.0), 0.72), _lvl(swirl, 0.22))
    y = S.mix(y, _lvl(_gale(dur, r, level=1.0, rate=0.6), 0.14))
    return _room(y, size=2.5, damping=0.58, mix=0.30, cap=2.60)


@cue("krakenStormcall")
def kraken_stormcall(r):
    """IT CALLS THE WEATHER DOWN. Thunder and gale: a close strike with a
    roll behind it, the wind coming up hard underneath, and rain arriving on
    the deck a beat later. The order matters - the strike first and the wind
    AFTER is what makes the storm read as summoned rather than as ambient."""
    dur = 2.80
    out = S.silence(dur)
    out = S.place(out, _lvl(_thunder(2.2, r, near=1.0), 1.0), 0.0)
    out = S.place(out, _lvl(_sub(1.8, 48.0, 20.0, tau=0.70, drive=3.1, attack=0.010),
                            0.80), 0.006)
    # The gale coming up behind the strike.
    gale = _gale(2.3, r, level=1.0, rate=0.9)
    gale *= S.breakpoints(2.3, [(0.0, 0.0), (0.55, 0.5), (1.5, 1.0), (2.3, 0.45)],
                          curve="exp")
    out = S.place(out, _lvl(gale, 0.55), 0.30)
    # Rain arriving on the deck.
    rain = S.band_noise(1.7, r, 1200.0, 14000.0, order=2)
    rain = S.tremolo(rain, rate=7.0, depth=0.20)
    rain *= S.breakpoints(1.7, [(0.0, 0.0), (0.6, 0.85), (1.7, 0.55)], curve="exp")
    out = S.place(out, _lvl(rain, 0.30), 0.85)
    return _room(out, size=2.7, damping=0.54, mix=0.31, cap=3.20)


@cue("krakenWreckhurl")
def kraken_wreckhurl(r):
    """It picks up a ship and throws it. Three stages and they must all be
    audible: the hull being TAKEN (timber failing, water pouring off it),
    the flight (a low mass moving air), and the arrival - a whole vessel
    landing, which is the largest debris field on any sheet."""
    dur = 2.40
    out = S.silence(dur)
    # Taken: timber giving way under a grip.
    take = S.band_noise(0.50, r, 150.0, 5000.0, order=2)
    take = S.bp_sweep(take, S.expsweep(0.50, 300.0, 1100.0), q=2.2)
    take = S.tremolo(take, rate=24.0, depth=0.55)
    take *= S.breakpoints(0.50, [(0.0, 0.0), (0.06, 0.9), (0.50, 0.0)], curve="exp")
    out = S.place(out, _lvl(take, 0.60), 0.0)
    for i, f in enumerate((88.0, 152.0, 246.0)):
        out = S.place(out, S.bar(0.40, f, r, decay=0.075 - 0.015 * i, strike=0.85) *
                      (0.36 - 0.08 * i), 0.02)
    # Flight: a low mass moving air, arcing.
    flight = S.band_noise(0.75, r, 70.0, 4000.0, order=2)
    flight = S.bp_sweep(flight, S.breakpoints(0.75, [(0.0, 220.0), (0.40, 800.0),
                                                     (0.75, 300.0)], curve="exp"),
                        q=1.6)
    flight *= S.breakpoints(0.75, [(0.0, 0.0), (0.35, 1.0), (0.75, 0.25)], curve="exp")
    out = S.place(out, _lvl(flight, 0.55), 0.45)
    # Arrival.
    out = S.place(out, _lvl(S.band_noise(0.20, r, 200.0, 11000.0, order=3) *
                            S.perc_env(0.20, 0.0006, 0.022), 0.85), 1.15)
    out = S.place(out, _lvl(S.saturate(S.membrane(1.05, 40.0, r, drop=0.48,
                                                  noise=0.32, tau=0.34), 3.0),
                            1.0), 1.158)
    out = S.place(out, _lvl(_sub(1.60, 46.0, 26.0, tau=0.55, drive=3.2), 1.0), 1.158)
    out = S.place(out, _lvl(S.splash(0.8, r, low=200.0, high=6000.0, sweep_to=200.0,
                                     body=0.55), 0.48), 1.175)
    for _ in range(16):
        at = 1.22 + float(r.random()) * 0.85
        f = 200.0 * float(2.0 ** (r.random() * 1.9 - 0.95))
        out = S.place(out, S.bar(0.22, f, r, decay=0.030, strike=0.85) *
                      (0.07 + 0.16 * float(r.random())), at)
    return _room(out, size=2.6, damping=0.52, mix=0.31, predelay=0.026, cap=2.90)


@cue("krakenRoar")
def kraken_roar(r):
    """THE ROAR. The deepest, biggest sound in the game, and the sheet's
    reason to exist: `bossRoar__kraken` driven harder and given a full half
    second more, with the ocean and the storm both answering it. Nothing in
    the pack is allowed to sit under this."""
    dur = 2.90
    voice = _krak_growl(dur, r, f0=32.0, bend=(0.88, 1.30, 0.60), rasp=0.85,
                        sub=1.0, bright=0.85, flutter=9.0)
    voice = S.saturate(voice * 1.45, 2.4)
    voice *= S.breakpoints(dur, [(0.0, 0.0), (0.12, 0.7), (dur * 0.34, 1.0),
                                 (dur * 0.66, 0.88), (dur * 0.92, 0.24), (dur, 0.0)],
                           curve="exp")
    floor = _sub(dur, 40.0, 25.0, tau=1.25, drive=3.4, attack=0.05)
    sea = _ocean(dur, r, low=34.0, high=3600.0, open_to=1100.0, close_to=240.0,
                 peak=0.48, body=0.85, slow=0.7)
    thunder = _thunder(1.9, r, near=0.3)
    y = S.mix(_lvl(voice, 1.0), _lvl(floor, 0.62), _lvl(sea, 0.42),
              _lvl(S.fit(thunder, dur), 0.22))
    y = S.mix(y, _lvl(_gale(dur, r, level=1.0, rate=0.6), 0.15))
    return _room(y, size=3.0, damping=0.50, mix=0.34, predelay=0.032, cap=3.30)


@cue("krakenDeath")
def kraken_death(r):
    """The end of the sea. Everything at once and then nothing: the roar
    failing, the arms coming down, the whole Maelstrom draining away - and
    the cue ends on the storm THINNING, because the last statement of the
    game's last fight is that the weather has stopped."""
    dur = 3.20
    out = S.silence(dur)
    last = _krak_growl(1.7, r, f0=34.0, bend=(1.15, 0.82, 0.44), rasp=0.7, sub=1.0,
                       bright=0.5, flutter=8.5)
    last *= S.breakpoints(1.7, [(0.0, 0.0), (0.10, 0.95), (0.9, 0.45), (1.7, 0.0)],
                          curve="exp")
    out = S.place(out, _lvl(last, 0.95), 0.0)
    for i, at in enumerate((0.75, 1.05, 1.30)):
        out = S.place(out, _lvl(_limb(0.9, r, freq=44.0 + 6.0 * i, wet=0.9,
                                      drive=2.8), 0.75 - 0.15 * i), at)
    out = S.place(out, _lvl(_sub(2.0, 44.0, 24.0, tau=0.80, drive=3.3, attack=0.05),
                            0.95), 1.05)
    out = S.place(out, _lvl(S.splash(1.2, r, low=160.0, high=6000.0, sweep_to=165.0,
                                     body=0.85), 0.72), 1.35)
    drain = S.band_noise(1.5, r, 45.0, 4200.0, order=2)
    drain = S.lp_sweep(drain, S.expsweep(1.5, 2600.0, 150.0), order=2)
    drain *= S.breakpoints(1.5, [(0.0, 0.0), (0.20, 1.0), (1.5, 0.05)], curve="exp")
    out = S.place(out, _lvl(drain, 0.60), 1.55)
    # The storm thinning out - the last thing anyone hears in the game.
    gale = _gale(2.4, r, level=1.0, rate=0.7)
    gale *= S.breakpoints(2.4, [(0.0, 0.7), (0.8, 0.85), (1.8, 0.35), (2.4, 0.0)],
                          curve="exp")
    out = S.place(out, _lvl(gale, 0.30), 0.55)
    return _room(out, size=2.9, damping=0.52, mix=0.33, cap=3.30)
