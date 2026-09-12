"""sfx_boss_rimefang.py - the Floe-Breaker: an orca the size of a ship.

THE VOICE: ICE AND BREATH. The fight is fought on a floating sheet with the
animal underneath it, so for long stretches the sound is the only thing that
says where it is. Two materials:

* ICE (`_snap`, `_run`, `_sheet`). Ice is not glass and it is not stone. A
  crack in sea ice is a very fast transient followed by a DISPERSIVE chirp -
  the high frequencies travel faster through the sheet than the low ones, so
  what reaches you sweeps DOWNWARD over 30-80 ms. `_snap` builds exactly
  that (a resonant ping on a falling sweep), and it is the single most
  identifying sound on this sheet: nothing else in the game chirps.
* BREATH (`_spout`). Not a jet - an exhale. Filtered noise with a wet edge
  and a body of moving air, opening and closing, with the blowhole's own
  low resonance under it.

THE REGISTER IS THE BOTTOM OF THE CATALOGUE. Sfx.luau's block for this fight
says so explicitly and it is load-bearing: everything is pitched to the floor
so that the ice cracks - the only bright thing here - read at all. The two
skyfall cues are the biggest, lowest hits in the game, and they are the ONLY
place a crack layer is allowed to arrive ahead of the low end at full level.

LOOPS. `rimeWhiteout` and `rimeRiftAmbient` are authored loop-safe: exact
length, nothing starting near the end, every LFO completing a whole number of
cycles across the loop, and `reverb(..., tail=False)`.
"""

import numpy as np

import synth as S
from cues import cue


# ---------------------------------------------------------------------------
# the floe: open sky, hard ice, no walls
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


def _room(x, size=1.7, damping=0.30, mix=0.26, predelay=0.016, tail=True,
          cap=None):
    """Wide, cold and BRIGHT. Low damping is the whole trick: ice reflects
    the top end instead of eating it, which is what makes this arena sound
    unlike Gnashroot's fog even at the same size."""
    # See sfx_boss_shared._room: sub-26 Hz energy is headroom the peak
    # normalise gives away, and this sheet has more of it than any other.
    x = S.highpass(x, 26.0, order=2)
    y = S.reverb(x, size=size, damping=damping, mix=mix, predelay=predelay,
                 seed=13, tail=tail)
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


def _snap(dur, r, freq=2600.0, chirp=0.42, tau=0.010, grit=0.5):
    """ONE ICE CRACK, with the dispersive chirp that makes it ice.

    High frequencies outrun low ones through a sheet, so a crack heard from
    any distance arrives as a descending whistle behind its transient.
    `chirp` is how far it falls (0.42 = down to 42% of `freq`). Take this
    out and the cue is a twig snapping; leave it in and it is sea ice.
    """
    click = S.band_noise(min(dur, 0.012), r, freq * 0.6, min(18000.0, freq * 5.0),
                         order=3)
    click *= S.perc_env(min(dur, 0.012), 0.0002, 0.0022)
    ping = S.sine(dur, S.expsweep(dur, freq, freq * chirp))
    ping = S.mix(ping, S.sine(dur, S.expsweep(dur, freq * 1.61, freq * 1.61 * chirp))
                 * 0.4)
    ping *= S.perc_env(dur, 0.0006, tau, curve=1.1)
    out = S.mix(_lvl(S.fit(click, dur), 0.9), _lvl(ping, 1.0))
    if grit > 0:
        rip = S.band_noise(dur, r, 1200.0, 14000.0, order=2)
        rip = S.lp_sweep(rip, S.expsweep(dur, 12000.0, 1800.0), order=2)
        rip *= S.perc_env(dur, 0.0004, tau * 1.6, curve=1.3)
        out = S.mix(out, _lvl(rip, grit * 0.55))
    return out


def _run(dur, r, count=14, f0=3200.0, f1=1500.0, accel=1.0, level=0.9,
         spread=0.82, grit=0.45):
    """A RUN OF CRACKS - a web spreading across the sheet.

    `accel` > 1 packs the snaps toward the end (density RISING, which reads
    as the web racing outward and is the tell for `rimeCrackWeb`); < 1
    spaces them out (a sheet settling). The pitch walks from f0 to f1 across
    the run because a crack that has travelled further is heard lower.
    """
    out = S.silence(dur)
    span = dur * spread
    for i in range(count):
        u = (i / max(1, count - 1.0)) ** accel
        at = u * span + 0.006 * float(r.random())
        f = f0 * (f1 / f0) ** u * (0.85 + 0.34 * float(r.random()))
        one = _snap(0.20, r, freq=f, chirp=0.40 + 0.16 * float(r.random()),
                    tau=0.009 + 0.010 * float(r.random()), grit=grit)
        out = S.place(out, one * level * (0.35 + 0.65 * float(r.random())), at)
    return S.fit(out, dur)


def _sheet(dur, r, freq=44.0, tau=None, groan=0.5):
    """THE FLOE ITSELF answering - the low body under any ice event. A
    saturated sub plus the sheet's own groan: two close low resonances that
    beat, which is what a hundred yards of ice under strain does."""
    if tau is None:
        tau = dur * 0.30
    low = S.saturate(S.sine(dur, S.expsweep(dur, freq * 1.5, freq * 0.62)) *
                     S.perc_env(dur, 0.003, tau), 2.8)
    if groan <= 0:
        return low
    exc = S.fit(S.white(0.006, r) * S.perc_env(0.006, 0.0003, 0.0015), dur)
    ring = (S.resonator(exc, freq * 2.1, q=30.0) +
            S.resonator(exc, freq * 2.17, q=26.0) * 0.8 +
            S.resonator(exc, freq * 3.6, q=18.0) * 0.4)
    ring *= S.expdec(dur, tau * 1.4)
    return S.mix(_lvl(low, 1.0), _lvl(ring, groan * 0.55))


def _shards(r, count=12, spread=0.6, start=0.05, level=0.28, freq=3000.0):
    """Broken ice landing back on the sheet. Bright, short, and scattered -
    the tail of everything that erupts or shatters."""
    out = S.silence(start + spread + 0.25)
    for _ in range(count):
        at = start + float(r.random()) * spread
        f = freq * float(2.0 ** (r.random() * 1.6 - 0.8))
        out = S.place(out, _snap(0.14, r, freq=f, chirp=0.5, tau=0.006, grit=0.3) *
                      (0.25 + 0.75 * float(r.random())) * level, at)
    return out


def _spout(dur, r, f0=210.0, wet=0.45, force=1.0):
    """THE BLOW. An exhale, not a jet: a broad band of moving air whose
    filter opens fast and closes slowly, the blowhole's own low resonance
    under it, and a wet flutter at the front where the water goes first."""
    air = S.band_noise(dur, r, 120.0, 11000.0, order=2)
    air = S.bp_sweep(air, S.breakpoints(dur, [(0.0, f0 * 2.0),
                                              (dur * 0.16, f0 * 9.0 * force),
                                              (dur, f0 * 2.4)], curve="exp"), q=1.5)
    air *= S.breakpoints(dur, [(0.0, 0.0), (0.035, 1.0), (dur * 0.45, 0.55),
                               (dur, 0.0)], curve="exp")
    pipe = S.resonator(air, f0, q=9.0) + S.resonator(air, f0 * 2.6, q=6.0) * 0.5
    out = S.mix(_lvl(air, 1.0), _lvl(pipe, 0.45))
    if wet > 0:
        spit = S.wet_texture(min(dur, 0.22), r, density=34.0, freq=700.0,
                             spread=2.6, level=0.55)
        out = S.place(out, _lvl(spit, wet * 0.5), 0.010)
    return out


def _rime_growl(dur, r, f0=68.0, bend=(0.9, 1.20, 0.74), rasp=0.5, sub=0.8,
                bright=0.9, flutter=31.0):
    """A CETACEAN throat, not a lizard's. Formants placed high and wide
    apart (420/1250/2900) over a low fundamental, which is what gives a
    whale call its strange "small mouth on a huge body" quality, plus a fast
    flutter - whale vocalisations pulse much faster than a reptile's roar."""
    contour = S.breakpoints(dur, [(0.0, f0 * bend[0]), (dur * 0.30, f0 * bend[1]),
                                  (dur, f0 * bend[2])], curve="exp")
    core = S.saw(dur, contour, bright=0.9) * 0.55 + S.pulse(dur, contour, 0.24) * 0.5
    core = S.moog(core, S.breakpoints(dur, [(0.0, 600.0), (dur * 0.26, 3200.0 * bright),
                                            (dur, 800.0)], curve="exp"), res=0.38)
    throat = S.formant(core, [420.0, 1250.0, 2900.0], qs=[8.0, 6.5, 5.0],
                       gains=[1.0, 0.62, 0.30])
    voice = S.mix(_lvl(core, 0.32), _lvl(throat, 0.95))
    if rasp > 0:
        edge = S.band_noise(dur, r, 350.0, 5200.0 * bright, order=2)
        edge = S.tremolo(edge, rate=flutter, depth=0.8)
        edge *= S.breakpoints(dur, [(0.0, 0.0), (0.04, 1.0), (dur, 0.4)])
        voice = S.mix(voice, _lvl(edge, rasp * 0.45))
    if sub > 0:
        low = S.highpass(S.sine(dur, contour * 0.5) +
                         S.sine(dur, contour * 0.25) * 0.5, 26.0, order=2)
        voice = S.mix(voice, _lvl(S.saturate(low, 2.2), sub * 0.9))
    return voice


# ---------------------------------------------------------------------------
# the seven voice variants - the shared vocabulary in ice
# ---------------------------------------------------------------------------

@cue("bossTell__rimefang")
def tell_rimefang(r):
    """It is under you and it has chosen. The sheet GROANS - a rising low
    resonance - and two small cracks answer from somewhere else on the floe.
    The cracks are the direction cue; the groan is the warning."""
    dur = 0.85
    strain = S.band_noise(dur, r, 60.0, 1400.0, order=2)
    strain = S.bp_sweep(strain, S.breakpoints(dur, [(0.0, 130.0), (0.7, 340.0),
                                                    (dur, 220.0)], curve="exp"), q=6.0)
    strain = S.tremolo(strain, rate=8.5, depth=0.35)
    strain *= S.breakpoints(dur, [(0.0, 0.0), (0.62, 0.85), (0.76, 1.0), (dur, 0.0)],
                            curve="exp")
    out = S.mix(_lvl(strain, 1.0),
                _lvl(_sheet(dur, r, freq=40.0, tau=0.4, groan=0.7), 0.55))
    out = S.place(out, _lvl(_snap(0.22, r, freq=2100.0, tau=0.012), 0.40), 0.30)
    out = S.place(out, _lvl(_snap(0.22, r, freq=1700.0, tau=0.014), 0.32), 0.52)
    return _room(out, size=1.5, mix=0.26, cap=1.20)


@cue("bossRise__rimefang")
def rise_rimefang(r):
    """A ship-sized body clearing the sheet. The sea letting go: a long
    rising rush of displaced water with the ice failing around the edge of
    it, and no impact anywhere - the impact is the next cue."""
    dur = 2.00
    rush = S.band_noise(1.75, r, 70.0, 7000.0, order=2)
    rush = S.lp_sweep(rush, S.breakpoints(1.75, [(0.0, 240.0), (1.30, 3200.0),
                                                 (1.75, 900.0)], curve="exp"), order=2)
    rush *= S.breakpoints(1.75, [(0.0, 0.0), (1.20, 0.85), (1.45, 1.0), (1.75, 0.06)],
                          curve="exp")
    low = S.sine(1.9, S.expsweep(1.9, 28.0, 50.0))
    low *= S.breakpoints(1.9, [(0.0, 0.0), (1.45, 1.0), (1.9, 0.12)], curve="exp")
    out = S.mix(_lvl(S.fit(rush, dur), 1.0),
                _lvl(S.fit(S.saturate(low, 2.4), dur), 0.72))
    out = S.place(out, _lvl(_run(0.7, r, count=10, f0=3000.0, f1=1400.0, accel=1.0),
                            0.45), 0.85)
    out = S.place(out, _lvl(S.wet_texture(0.9, r, density=22.0, freq=640.0,
                                          level=0.5), 0.32), 1.25)
    return _room(out, size=1.9, damping=0.34, mix=0.29, cap=2.50)


@cue("bossRoar__rimefang")
def roar_rimefang(r):
    """The call. A whale, not a monster: high wide formants over a very low
    fundamental, a fast pulse in it, and the sheet ringing sympathetically
    underneath. Strange rather than angry - that is what makes it this
    animal instead of a generic big thing shouting."""
    dur = 2.10
    voice = _rime_growl(dur, r, f0=64.0, bend=(0.85, 1.32, 0.70), rasp=0.52,
                        sub=0.90, bright=1.0)
    voice *= S.breakpoints(dur, [(0.0, 0.0), (0.05, 0.7), (dur * 0.28, 1.0),
                                 (dur * 0.58, 0.82), (dur * 0.92, 0.2), (dur, 0.0)],
                           curve="exp")
    floor = _sub(dur, 54.0, 28.0, tau=0.90, drive=2.8, attack=0.025)
    ring = _sheet(1.4, r, freq=38.0, tau=0.55, groan=0.9)
    y = S.mix(_lvl(S.saturate(voice, 1.7), 1.0), _lvl(floor, 0.55),
              _lvl(S.fit(ring, dur), 0.34))
    return _room(y, size=2.0, damping=0.32, mix=0.30, predelay=0.020, cap=2.60)


@cue("bossSnap__rimefang")
def snap_rimefang(r):
    """The jaw. A killer whale's bite is a hard, high, WET clap - conical
    teeth in a short jaw, closing all at once - so this is bright for the
    sheet, and the ice snaps behind it place it on the floe."""
    dur = 0.55
    out = S.silence(dur)
    rush = S.bp_sweep(S.white(0.09, r), S.expsweep(0.09, 1200.0, 4400.0), q=2.2)
    rush *= S.breakpoints(0.09, [(0.0, 0.0), (0.065, 1.0), (0.09, 0.0)], curve="exp")
    out = S.place(out, _lvl(rush, 0.40), 0.0)
    clap = S.band_noise(0.10, r, 800.0, 13000.0, order=3)
    clap = S.lp_sweep(clap, S.expsweep(0.10, 12000.0, 900.0), order=2)
    clap *= S.perc_env(0.10, 0.0003, 0.010, curve=1.2)
    out = S.place(out, _lvl(clap, 1.0), 0.070)
    out = S.place(out, _lvl(S.mix(S.bar(0.20, 260.0, r, decay=0.035, strike=0.95),
                                  S.bar(0.20, 470.0, r, decay=0.022,
                                        strike=0.8) * 0.5), 0.70), 0.070)
    out = S.place(out, _lvl(_sub(0.34, 94.0, 42.0, tau=0.08, drive=2.5), 0.70), 0.071)
    out = S.place(out, _lvl(S.splash(0.18, r, low=500.0, high=5200.0, sweep_to=320.0,
                                     body=0.3), 0.32), 0.082)
    return _room(out, size=1.3, damping=0.36, mix=0.22, cap=0.90)


@cue("bossSlam__rimefang")
def slam_rimefang(r):
    """Body on ice. CRACK -> BOOM with the crack made of ice rather than
    stone: the sheet fails first in a burst of snaps, then the floe takes
    the weight."""
    dur = 1.60
    out = S.silence(dur)
    out = S.place(out, _lvl(_run(0.30, r, count=9, f0=4200.0, f1=1600.0, accel=0.7,
                                 spread=0.5), 0.85), 0.0)
    out = S.place(out, _lvl(S.saturate(S.membrane(0.85, 52.0, r, drop=0.5, noise=0.28,
                                                  tau=0.25), 2.5), 0.95), 0.006)
    out = S.place(out, _lvl(_sheet(1.25, r, freq=42.0, tau=0.36, groan=0.8), 1.0), 0.006)
    out = S.place(out, _lvl(S.splash(0.45, r, low=300.0, high=6000.0, sweep_to=280.0,
                                     body=0.35), 0.35), 0.030)
    out = S.place(out, _lvl(_shards(r, count=12, spread=0.55, level=0.3), 0.28), 0.09)
    return _room(out, size=1.9, damping=0.32, mix=0.28, predelay=0.016, cap=2.10)


@cue("bossDown__rimefang")
def down_rimefang(r):
    """It goes back under. The sheet closing over it: a long descending
    wash, the last of the call trailing off, and the ice knitting shut
    behind it in a slow run of settling snaps."""
    dur = 2.40
    out = S.silence(dur)
    fall = S.band_noise(1.4, r, 90.0, 5000.0, order=2)
    fall = S.lp_sweep(fall, S.expsweep(1.4, 3000.0, 260.0), order=2)
    fall *= S.breakpoints(1.4, [(0.0, 0.5), (0.3, 1.0), (1.4, 0.08)], curve="exp")
    out = S.place(out, _lvl(fall, 0.60), 0.0)
    last = _rime_growl(1.1, r, f0=54.0, bend=(1.05, 0.86, 0.56), rasp=0.4, sub=0.85,
                       bright=0.6)
    last *= S.breakpoints(1.1, [(0.0, 0.0), (0.12, 0.85), (0.65, 0.5), (1.1, 0.0)],
                          curve="exp")
    out = S.place(out, _lvl(last, 0.62), 0.06)
    out = S.place(out, _lvl(_sub(1.7, 62.0, 22.0, tau=0.70, drive=2.7, attack=0.04),
                            0.88), 0.55)
    out = S.place(out, _lvl(S.splash(0.9, r, low=200.0, high=5400.0, sweep_to=190.0,
                                     body=0.8), 0.70), 0.90)
    out = S.place(out, _lvl(_run(0.9, r, count=9, f0=2200.0, f1=900.0, accel=0.55),
                            0.30), 1.15)
    return _room(out, size=2.0, damping=0.36, mix=0.30, cap=2.80)


@cue("bossStagger__rimefang")
def stagger_rimefang(r):
    """Beached. It comes down across the sheet and the sheet loses - the
    punish window opening, so the ice failure under it is left running long
    after the impact has gone."""
    dur = 2.10
    out = S.silence(dur)
    out = S.place(out, _lvl(_run(0.34, r, count=12, f0=4600.0, f1=1500.0, accel=0.6,
                                 spread=0.55), 0.80), 0.0)
    out = S.place(out, _lvl(S.saturate(S.membrane(1.0, 44.0, r, drop=0.5, noise=0.32,
                                                  tau=0.30), 2.7), 1.0), 0.010)
    out = S.place(out, _lvl(_sheet(1.6, r, freq=36.0, tau=0.52, groan=0.9), 1.0), 0.010)
    groan = _rime_growl(1.0, r, f0=58.0, bend=(1.0, 0.84, 0.60), rasp=0.5, sub=0.85,
                        bright=0.65)
    groan *= S.breakpoints(1.0, [(0.0, 0.0), (0.14, 1.0), (0.6, 0.5), (1.0, 0.0)],
                           curve="exp")
    out = S.place(out, _lvl(groan, 0.50), 0.20)
    out = S.place(out, _lvl(_run(1.1, r, count=16, f0=2800.0, f1=1100.0, accel=0.5),
                            0.38), 0.32)
    out = S.place(out, _lvl(_shards(r, count=14, spread=0.9, level=0.3), 0.26), 0.20)
    return _room(out, size=2.0, damping=0.34, mix=0.30, predelay=0.018, cap=2.65)


# ---------------------------------------------------------------------------
# the animal: breath, wash, breach, thrash
# ---------------------------------------------------------------------------

@cue("rimeSpout")
def rime_spout(r):
    """THE LOCATOR. It surfaces on the ring and breathes out. Most players
    hear this before they turn, so it is clean, mid-register and carries -
    a wet exhale with the blowhole's pipe in it, then the intake behind."""
    dur = 0.75
    out = S.silence(dur)
    out = S.place(out, _lvl(_spout(0.42, r, f0=210.0, wet=0.5, force=1.0), 1.0), 0.0)
    intake = S.band_noise(0.28, r, 250.0, 4200.0, order=2)
    intake = S.bp_sweep(intake, S.expsweep(0.28, 420.0, 1300.0), q=2.6)
    intake *= S.breakpoints(0.28, [(0.0, 0.0), (0.22, 1.0), (0.28, 0.0)], curve="exp")
    out = S.place(out, _lvl(intake, 0.42), 0.40)
    out = S.place(out, _lvl(S.wet_texture(0.35, r, density=16.0, freq=520.0,
                                          level=0.5), 0.24), 0.10)
    return _room(out, size=1.6, damping=0.34, mix=0.26, cap=1.10)


@cue("rimeWash")
def rime_wash(r):
    """THE SIGNATURE. It shoulders a wall of water across the floe. The
    longest cue on the sheet and deliberately so: the answer is cover, the
    read has to start during the windup, and a cue that arrives with the
    damage is not a warning. No transient exists anywhere in it."""
    dur = 1.85
    wall = S.band_noise(dur, r, 55.0, 6500.0, order=2)
    wall = S.lp_sweep(wall, S.breakpoints(dur, [(0.0, 180.0), (0.55, 700.0),
                                                (1.30, 3000.0), (dur, 800.0)],
                                          curve="exp"), order=2)
    wall *= S.breakpoints(dur, [(0.0, 0.0), (0.85, 0.55), (1.35, 1.0), (1.60, 0.85),
                                (dur, 0.04)], curve="exp")
    wall = S.tremolo(wall, rate=2.1, depth=0.16)
    swell = S.sine(dur, S.expsweep(dur, 30.0, 54.0))
    swell *= S.breakpoints(dur, [(0.0, 0.0), (1.35, 1.0), (dur, 0.06)], curve="exp")
    out = S.mix(_lvl(wall, 1.0), _lvl(S.saturate(swell, 2.5), 0.72))
    # The sheet groaning under the load as it passes - not a crack, a strain.
    out = S.place(out, _lvl(_run(0.55, r, count=7, f0=2200.0, f1=1000.0, accel=1.4),
                            0.26), 1.20)
    out = S.place(out, _lvl(S.wet_texture(0.55, r, density=20.0, freq=760.0,
                                          level=0.5), 0.22), 1.35)
    return _room(out, size=2.0, damping=0.38, mix=0.29, cap=2.35)


@cue("rimeBreachLaunch")
def rime_breach_launch(r):
    """THE BREACH, part one: it leaves the water. The sea letting go of
    something enormous - deeper and heavier than the generic rise, with the
    hole it came out of collapsing behind it."""
    dur = 1.30
    out = S.silence(dur)
    tear = S.band_noise(1.1, r, 70.0, 8000.0, order=2)
    tear = S.lp_sweep(tear, S.breakpoints(1.1, [(0.0, 300.0), (0.55, 4000.0),
                                                (1.1, 900.0)], curve="exp"), order=2)
    tear *= S.breakpoints(1.1, [(0.0, 0.0), (0.12, 0.7), (0.5, 1.0), (1.1, 0.04)],
                          curve="exp")
    out = S.place(out, _lvl(tear, 1.0), 0.0)
    out = S.place(out, _lvl(_sub(1.15, 40.0, 62.0, tau=0.55, drive=2.8, attack=0.05),
                            0.80), 0.0)
    out = S.place(out, _lvl(_run(0.5, r, count=11, f0=3600.0, f1=1500.0, accel=1.0),
                            0.42), 0.05)
    out = S.place(out, _lvl(S.wet_texture(0.7, r, density=26.0, freq=600.0,
                                          level=0.55), 0.30), 0.35)
    return _room(out, size=1.9, damping=0.34, mix=0.28, cap=1.80)


@cue("rimeBreachCrash")
def rime_breach_crash(r):
    """THE BREACH, part two: it lands FLAT. Under the slam, under the
    stagger - the punish window opening, arena-wide, left to ring out whole.
    The ice crack layer arrives 12 ms AHEAD of the low end, which is the
    whole reason this reads as CRACK -> BOOM instead of one wall of sub."""
    dur = 2.30
    out = S.silence(dur)
    out = S.place(out, _lvl(_run(0.30, r, count=16, f0=5200.0, f1=1400.0, accel=0.55,
                                 spread=0.45), 0.95), 0.0)
    out = S.place(out, _lvl(S.saturate(S.membrane(1.1, 38.0, r, drop=0.48, noise=0.30,
                                                  tau=0.34), 2.9), 1.0), 0.012)
    out = S.place(out, _lvl(_sheet(1.9, r, freq=32.0, tau=0.62, groan=1.0), 1.0), 0.012)
    out = S.place(out, _lvl(S.splash(0.8, r, low=220.0, high=6500.0, sweep_to=210.0,
                                     body=0.5), 0.42), 0.030)
    out = S.place(out, _lvl(_run(1.2, r, count=18, f0=3000.0, f1=900.0, accel=0.45),
                            0.34), 0.16)
    out = S.place(out, _lvl(_shards(r, count=18, spread=1.1, level=0.3), 0.28), 0.14)
    return _room(out, size=2.2, damping=0.32, mix=0.31, predelay=0.020, cap=2.95)


@cue("rimeFloeCrack")
def rime_floe_crack(r):
    """The crash's top layer, thrown the width of the floe: the sheet
    splitting under a landing. Pure ice, no low end at all - it exists to be
    staggered a beat AHEAD of the crash, the way killCrack sits ahead of
    killThump, and it has to survive being played over it."""
    dur = 0.85
    out = S.silence(dur)
    out = S.place(out, _lvl(_snap(0.30, r, freq=5200.0, chirp=0.30, tau=0.016,
                                  grit=0.8), 1.0), 0.0)
    out = S.place(out, _lvl(_run(0.55, r, count=13, f0=4200.0, f1=1300.0, accel=1.15,
                                 spread=0.75), 0.72), 0.020)
    out = S.place(out, _lvl(_sub(0.40, 120.0, 58.0, tau=0.09, drive=2.2), 0.28), 0.002)
    return _room(out, size=1.7, damping=0.28, mix=0.26, cap=1.20)


@cue("rimeThrash")
def rime_thrash(r):
    """BEACHED: a ship-sized animal working itself back to water. One beat
    of it - the caller fires this three or four times across the window. A
    heave of the body, ice grinding under it, and a strained breath: fired
    twice it must not sound like a sampler, so nothing here is symmetrical."""
    dur = 0.90
    out = S.silence(dur)
    heave = S.band_noise(0.55, r, 80.0, 3600.0, order=2)
    heave = S.bp_sweep(heave, S.breakpoints(0.55, [(0.0, 200.0), (0.22, 700.0),
                                                   (0.55, 260.0)], curve="exp"), q=1.6)
    heave = S.tremolo(heave, rate=9.0, depth=0.45)
    heave *= S.breakpoints(0.55, [(0.0, 0.0), (0.08, 1.0), (0.4, 0.7), (0.55, 0.0)],
                           curve="exp")
    out = S.place(out, _lvl(heave, 0.85), 0.0)
    out = S.place(out, _lvl(_sub(0.62, 66.0, 34.0, tau=0.18, drive=2.6), 0.75), 0.005)
    out = S.place(out, _lvl(_run(0.6, r, count=8, f0=2600.0, f1=1100.0, accel=1.3),
                            0.40), 0.06)
    breath = _rime_growl(0.42, r, f0=76.0, bend=(0.95, 1.25, 0.85), rasp=0.7, sub=0.5,
                         bright=1.05, flutter=36.0)
    breath *= S.breakpoints(0.42, [(0.0, 0.0), (0.06, 1.0), (0.42, 0.0)], curve="exp")
    out = S.place(out, _lvl(breath, 0.45), 0.34)
    return _room(out, size=1.5, damping=0.36, mix=0.24, cap=1.25)


@cue("rimeFlukeSlam")
def rime_fluke_slam(r):
    """The tail comes up through a hole and hammers down. A LIMB, not the
    whole animal - so it sits between the body slam and the breach crash:
    tighter, a shade brighter, and over faster, which is what stops it being
    mistaken for the breach when both are behind you."""
    dur = 1.35
    out = S.silence(dur)
    swing = S.bp_sweep(S.white(0.16, r), S.expsweep(0.16, 500.0, 2200.0), q=1.8)
    swing *= S.breakpoints(0.16, [(0.0, 0.0), (0.12, 1.0), (0.16, 0.0)], curve="exp")
    out = S.place(out, _lvl(swing, 0.40), 0.0)
    out = S.place(out, _lvl(_run(0.22, r, count=8, f0=4800.0, f1=1900.0, accel=0.7,
                                 spread=0.45), 0.80), 0.145)
    out = S.place(out, _lvl(S.saturate(S.membrane(0.65, 62.0, r, drop=0.52, noise=0.3,
                                                  tau=0.18), 2.4), 0.95), 0.150)
    out = S.place(out, _lvl(_sheet(0.9, r, freq=50.0, tau=0.24, groan=0.6), 0.85), 0.150)
    out = S.place(out, _lvl(S.splash(0.4, r, low=400.0, high=7000.0, sweep_to=340.0,
                                     body=0.3), 0.38), 0.165)
    out = S.place(out, _lvl(_shards(r, count=10, spread=0.5, level=0.3), 0.26), 0.22)
    return _room(out, size=1.7, damping=0.32, mix=0.26, cap=1.75)


@cue("rimeSpyHop")
def rime_spy_hop(r):
    """It stands up out of the water and picks someone. The one beat where
    nothing is coming, so it is the one cue here allowed to be BRIGHT: water
    shedding off a flank, high against a fight pitched to the floor. A
    one-shot cannot sweep upward, so the rise is carried by register."""
    dur = 0.70
    out = S.silence(dur)
    shed = S.band_noise(0.45, r, 600.0, 13000.0, order=2)
    shed = S.lp_sweep(shed, S.expsweep(0.45, 11000.0, 1800.0), order=2)
    shed *= S.breakpoints(0.45, [(0.0, 0.0), (0.05, 1.0), (0.45, 0.0)], curve="exp")
    out = S.place(out, _lvl(shed, 1.0), 0.0)
    out = S.place(out, _lvl(S.wet_texture(0.40, r, density=40.0, freq=1500.0,
                                          spread=2.4, level=0.6), 0.55), 0.02)
    out = S.place(out, _lvl(_snap(0.20, r, freq=3400.0, tau=0.010), 0.35), 0.0)
    out = S.place(out, _lvl(_sub(0.42, 130.0, 62.0, tau=0.11, drive=2.2), 0.30), 0.004)
    return _room(out, size=1.6, damping=0.26, mix=0.26, cap=1.00)


# ---------------------------------------------------------------------------
# the new kit: the ice web, the eruption, the sky-fall, the quake
# ---------------------------------------------------------------------------

@cue("rimeCrackWeb")
def rime_crack_web(r):
    """A WEB OF CRACKS RACING TOWARD YOU. Many small snaps RISING IN
    DENSITY - `_run(accel=1.9)` packs them toward the end, which is the
    whole read: the web is closing, and it should get worse as it comes.
    Fired on a beat rather than looped, so the caller owns the rhythm.

    Mid-register on purpose: it is the sound of something UNDER you, so the
    sheet's groan is mixed in beneath the snaps rather than a body hit."""
    dur = 0.80
    out = S.silence(dur)
    strain = S.band_noise(dur, r, 70.0, 1600.0, order=2)
    strain = S.bp_sweep(strain, S.breakpoints(dur, [(0.0, 150.0), (0.6, 380.0),
                                                    (dur, 260.0)], curve="exp"), q=5.0)
    strain = S.tremolo(strain, rate=11.0, depth=0.4)
    strain *= S.breakpoints(dur, [(0.0, 0.0), (0.2, 0.6), (0.7, 1.0), (dur, 0.0)],
                            curve="exp")
    out = S.mix(out, _lvl(strain, 0.55))
    out = S.mix(out, _lvl(_run(dur, r, count=22, f0=3800.0, f1=1500.0, accel=1.9,
                               spread=0.90, grit=0.4), 1.0))
    out = S.mix(out, _lvl(_sheet(dur, r, freq=46.0, tau=0.35, groan=0.8), 0.40))
    return _room(out, size=1.5, damping=0.30, mix=0.24, cap=1.15)


@cue("rimeCrackLock")
def rime_crack_lock(r):
    """THE LOCK. The target stops tracking and the ground is chosen: ONE
    decisive snap of ice giving up, bright against the groan it interrupts.
    The most transient thing in the fight by design - nothing else here has
    an attack this fast, which is what makes it impossible to mistake for
    the weather. It is the "MOVE" beat, so it is short and it is loud."""
    dur = 0.45
    out = S.silence(dur)
    out = S.place(out, _lvl(_snap(0.28, r, freq=6200.0, chirp=0.26, tau=0.011,
                                  grit=0.9), 1.0), 0.0)
    # A second failure 18 ms behind, deeper: the crack finding its length.
    out = S.place(out, _lvl(_snap(0.24, r, freq=2400.0, chirp=0.34, tau=0.014,
                                  grit=0.5), 0.55), 0.018)
    out = S.place(out, _lvl(_sub(0.30, 150.0, 66.0, tau=0.055, drive=2.4), 0.42), 0.002)
    out = S.place(out, _lvl(_shards(r, count=6, spread=0.18, level=0.3, freq=4200.0),
                            0.22), 0.03)
    return _room(out, size=1.4, damping=0.24, mix=0.22, cap=0.62)


@cue("rimeIceBurst")
def rime_ice_burst(r):
    """THE ERUPTION. It comes UP through the sheet. Not a landing and not a
    splash: ice being opened from underneath by something that weighs more
    than the ice does. The order is inverted from every other impact here -
    the LOW arrives first (the push from below), then the sheet fails, then
    the shards come down."""
    dur = 1.70
    out = S.silence(dur)
    push = S.band_noise(0.22, r, 40.0, 1200.0, order=2)
    push = S.lp_sweep(push, S.expsweep(0.22, 140.0, 600.0), order=2)
    push *= S.breakpoints(0.22, [(0.0, 0.0), (0.18, 1.0), (0.22, 0.9)], curve="exp")
    out = S.place(out, _lvl(push, 0.65), 0.0)
    out = S.place(out, _lvl(_sub(1.35, 34.0, 26.0, tau=0.42, drive=3.0, attack=0.02),
                            0.95), 0.10)
    out = S.place(out, _lvl(_run(0.45, r, count=20, f0=5600.0, f1=1600.0, accel=0.6,
                                 spread=0.55), 0.95), 0.180)
    out = S.place(out, _lvl(_sheet(1.2, r, freq=40.0, tau=0.40, groan=0.9), 0.85), 0.185)
    burst = S.band_noise(0.5, r, 300.0, 9000.0, order=2)
    burst = S.lp_sweep(burst, S.expsweep(0.5, 8000.0, 600.0), order=2)
    burst *= S.perc_env(0.5, 0.0008, 0.10, curve=1.3)
    out = S.place(out, _lvl(burst, 0.55), 0.182)
    out = S.place(out, _lvl(_shards(r, count=18, spread=0.85, start=0.10, level=0.3),
                            0.32), 0.25)
    return _room(out, size=2.0, damping=0.30, mix=0.29, cap=2.30)


@cue("rimeSkyLaunch")
def rime_sky_launch(r):
    """SKYFALL, part one: seventy studs of launch. The cue that makes people
    LOOK UP, and a player who does not look up does not see the shadow - so
    it is thrown further than anything else in the fight and it RISES the
    whole way: the filter climbs, the sub climbs, and the water goes with
    it. Pitched just above the eruption so the two are never one event."""
    dur = 1.60
    out = S.silence(dur)
    leave = S.band_noise(1.45, r, 80.0, 9000.0, order=2)
    leave = S.lp_sweep(leave, S.breakpoints(1.45, [(0.0, 320.0), (0.50, 2200.0),
                                                   (0.95, 5000.0), (1.45, 1400.0)],
                                            curve="exp"), order=2)
    leave *= S.breakpoints(1.45, [(0.0, 0.0), (0.10, 0.6), (0.75, 1.0), (1.45, 0.05)],
                           curve="exp")
    out = S.place(out, _lvl(leave, 1.0), 0.0)
    out = S.place(out, _lvl(_sub(1.35, 38.0, 78.0, tau=0.60, drive=2.8, attack=0.04),
                            0.85), 0.0)
    out = S.place(out, _lvl(_run(0.55, r, count=14, f0=4200.0, f1=1700.0, accel=1.1),
                            0.48), 0.03)
    # The water going up with it, and then falling back - the only part of
    # the launch that descends, which is what gives the rise its height.
    out = S.place(out, _lvl(S.wet_texture(0.85, r, density=30.0, freq=900.0,
                                          spread=2.6, level=0.55), 0.34), 0.55)
    return _room(out, size=2.1, damping=0.32, mix=0.30, cap=2.10)


@cue("rimeSkyImpact")
def rime_sky_impact(r):
    """SKYFALL, part two: IT ARRIVES. The biggest, lowest hit in the game.

    Everything on this sheet has been building the vocabulary for this one
    cue: a full-level ice crack layer 14 ms ahead of a 30 Hz body, the floe
    ringing at its own resonance for a second and a half, a second failure
    wave as the sheet redistributes, and shards for a whole second after.
    It is the long punish window opening, so it is left to ring out whole.
    """
    dur = 2.80
    out = S.silence(dur)
    # 1. The sheet failing - full level, ahead of everything.
    out = S.place(out, _lvl(_run(0.34, r, count=22, f0=6000.0, f1=1400.0, accel=0.5,
                                 spread=0.42, grit=0.7), 1.0), 0.0)
    out = S.place(out, _lvl(_snap(0.30, r, freq=7000.0, chirp=0.22, tau=0.014,
                                  grit=0.9), 0.75), 0.002)
    # 2. The body. 30 Hz, saturated hard, and the deepest thing in the pack.
    out = S.place(out, _lvl(S.saturate(S.membrane(1.3, 32.0, r, drop=0.45, noise=0.28,
                                                  tau=0.42), 3.2), 1.0), 0.014)
    out = S.place(out, _lvl(_sub(2.0, 46.0, 19.0, tau=0.80, drive=3.2), 1.0), 0.014)
    # 3. The floe ringing at its own resonance, long after the hit.
    out = S.place(out, _lvl(_sheet(2.1, r, freq=29.0, tau=0.75, groan=1.0), 0.95), 0.014)
    # 4. The second failure wave: the sheet redistributing the load.
    out = S.place(out, _lvl(_run(1.4, r, count=20, f0=2800.0, f1=800.0, accel=0.5),
                            0.36), 0.30)
    out = S.place(out, _lvl(S.splash(1.0, r, low=200.0, high=7000.0, sweep_to=190.0,
                                     body=0.5), 0.40), 0.040)
    out = S.place(out, _lvl(_shards(r, count=24, spread=1.3, level=0.3), 0.30), 0.18)
    return _room(out, size=2.4, damping=0.30, mix=0.32, predelay=0.022, cap=3.25)


@cue("rimeShock")
def rime_shock(r):
    """THE SHOCKWAVE ring leaving the impact. A RING OF SHATTERING ICE: no
    transient of its own (the impact already spent it) and RISING in the mix
    as it goes, which is the only way a one-shot can say "this is still
    coming". Fired with the ring, not with the damage - the answer is to
    outrun it, and a cue that arrives when it hits you is not a warning."""
    dur = 1.30
    out = S.silence(dur)
    rush = S.band_noise(dur, r, 90.0, 7000.0, order=2)
    rush = S.bp_sweep(rush, S.breakpoints(dur, [(0.0, 260.0), (0.55, 900.0),
                                                (dur, 1600.0)], curve="exp"), q=1.5)
    rush *= S.breakpoints(dur, [(0.0, 0.25), (0.45, 0.6), (0.95, 1.0), (dur, 0.0)],
                          curve="exp")
    out = S.mix(out, _lvl(rush, 1.0))
    # The ring is made of ice giving way, and the failures get FURTHER away
    # as it expands - so the run's pitch falls while its level rises.
    out = S.mix(out, _lvl(_run(dur, r, count=24, f0=3400.0, f1=1100.0, accel=0.95,
                               spread=0.95, grit=0.5) *
                          S.breakpoints(dur, [(0.0, 0.4), (0.9, 1.0), (dur, 0.2)]),
                          0.85))
    low = S.sine(dur, S.expsweep(dur, 52.0, 34.0))
    low *= S.breakpoints(dur, [(0.0, 0.3), (0.8, 1.0), (dur, 0.05)], curve="exp")
    out = S.mix(out, _lvl(S.saturate(low, 2.6), 0.55))
    return _room(out, size=1.9, damping=0.30, mix=0.28, cap=1.75)


@cue("rimeQuake")
def rime_quake(r):
    """THE FLOEQUAKE. Sixty studs of sheet heaving at once - the widest
    ground the fight ever moves, and the cue is broad and blunt to match:
    MORE RUMBLE THAN REPORT. A long low bed with the sheet's resonances
    walking through it and only a handful of cracks, spaced far apart,
    because a quake is not a shatter - it is the floor moving."""
    dur = 1.70
    bed = S.brown(dur, r)
    bed = S.lowpass(bed, 150.0, order=2)
    bed = S.highpass(bed, 27.0, order=2)
    bed = S.saturate(bed * 1.4, 2.4)
    bed *= S.breakpoints(dur, [(0.0, 0.0), (0.22, 0.85), (0.70, 1.0), (1.25, 0.8),
                               (dur, 0.0)], curve="exp")
    heave = S.sine(dur, S.breakpoints(dur, [(0.0, 44.0), (0.6, 33.0), (dur, 28.0)],
                                      curve="exp"))
    heave = S.tremolo(heave, rate=2.3, depth=0.35)
    heave *= S.breakpoints(dur, [(0.0, 0.0), (0.30, 1.0), (1.10, 0.7), (dur, 0.0)],
                           curve="exp")
    out = S.mix(_lvl(bed, 1.0), _lvl(S.saturate(heave, 2.8), 0.85))
    out = S.mix(out, _lvl(_sheet(dur, r, freq=31.0, tau=0.70, groan=1.0), 0.60))
    for at in (0.18, 0.44, 0.79, 1.12):
        out = S.place(out, _lvl(_snap(0.26, r, freq=1900.0 *
                                      float(2.0 ** (r.random() * 0.8 - 0.4)),
                                      chirp=0.40, tau=0.016, grit=0.4),
                                0.26 + 0.10 * float(r.random())), at)
    return _room(out, size=2.1, damping=0.40, mix=0.28, cap=2.20)


@cue("rimeShatter")
def rime_shatter(r):
    """THE FLOOR BREAKING - phase two's opener landing.

    Not a hit: a STRUCTURAL FAILURE, which is a different shape. It starts
    as a run of small snaps that ACCELERATES (the fracture propagating),
    crosses into a sheet-wide collapse about two-thirds through, and ends
    with water where the ice was. The low end arrives with the collapse and
    not with the first snap, because nothing has landed - the floor has
    simply stopped being a floor.
    """
    dur = 2.10
    out = S.silence(dur)
    # 1. The fracture propagating: density rising for a full second.
    out = S.mix(out, _lvl(_run(1.15, r, count=26, f0=4600.0, f1=1700.0, accel=2.1,
                               spread=0.95, grit=0.45), 0.85))
    strain = S.band_noise(1.15, r, 60.0, 1800.0, order=2)
    strain = S.bp_sweep(strain, S.breakpoints(1.15, [(0.0, 140.0), (0.9, 420.0),
                                                     (1.15, 300.0)], curve="exp"),
                        q=5.5)
    strain = S.tremolo(strain, rate=7.0, depth=0.45)
    strain *= S.breakpoints(1.15, [(0.0, 0.0), (0.35, 0.6), (1.05, 1.0), (1.15, 0.7)],
                            curve="exp")
    out = S.mix(out, _lvl(S.fit(strain, dur), 0.55))
    # 2. The collapse. Everything fails at once and the sheet drops.
    out = S.place(out, _lvl(_run(0.45, r, count=24, f0=6000.0, f1=1300.0, accel=0.45,
                                 spread=0.5, grit=0.75), 1.0), 1.10)
    out = S.place(out, _lvl(S.saturate(S.membrane(0.95, 36.0, r, drop=0.46,
                                                  noise=0.30, tau=0.32), 3.0),
                            0.95), 1.118)
    out = S.place(out, _lvl(_sheet(1.5, r, freq=33.0, tau=0.55, groan=1.0), 1.0), 1.118)
    # 3. Water where the ice was, and the pieces coming down on it.
    out = S.place(out, _lvl(S.splash(0.85, r, low=220.0, high=6500.0, sweep_to=210.0,
                                     body=0.55), 0.48), 1.16)
    out = S.place(out, _lvl(_shards(r, count=20, spread=0.75, level=0.3), 0.30), 1.22)
    out = S.place(out, _lvl(S.wet_texture(0.7, r, density=24.0, freq=560.0,
                                          level=0.5), 0.26), 1.40)
    return _room(out, size=2.2, damping=0.32, mix=0.31, predelay=0.018, cap=2.60)


@cue("rimeEnrage")
def rime_enrage(r):
    """THE 50% TRANSITION. Higher, angrier and more STRAINED than the
    thrash: the fundamental is up a fourth, the formants are dragged up with
    it, the flutter is faster, and the whole thing is driven hard enough to
    break up. A breath-IN comes first - a sharp reversed rush - because a
    scream with no intake is a synth patch, and the intake is also what
    makes the roar land on a beat the player can feel coming."""
    dur = 2.00
    out = S.silence(dur)
    # The breath in: a rising, closing rush - the opposite shape to a spout.
    gasp = S.band_noise(0.42, r, 200.0, 6000.0, order=2)
    gasp = S.bp_sweep(gasp, S.expsweep(0.42, 520.0, 2100.0), q=2.4)
    gasp *= S.breakpoints(0.42, [(0.0, 0.0), (0.34, 0.9), (0.42, 0.15)], curve="exp")
    out = S.place(out, _lvl(gasp, 0.55), 0.0)
    # The scream. Up a fourth on the roar, and driven until it tears.
    voice = _rime_growl(1.45, r, f0=88.0, bend=(0.95, 1.42, 0.86), rasp=0.85,
                        sub=0.70, bright=1.35, flutter=44.0)
    voice = S.saturate(voice * 1.4, 2.6)
    voice *= S.breakpoints(1.45, [(0.0, 0.0), (0.045, 0.9), (0.35, 1.0), (0.95, 0.85),
                                  (1.30, 0.3), (1.45, 0.0)], curve="exp")
    out = S.place(out, _lvl(voice, 1.0), 0.44)
    out = S.place(out, _lvl(_sub(1.5, 70.0, 34.0, tau=0.60, drive=3.0, attack=0.02),
                            0.62), 0.45)
    # The floe answering it - the ice cracks on the downbeat of the scream.
    out = S.place(out, _lvl(_run(0.9, r, count=15, f0=4000.0, f1=1500.0, accel=1.5),
                            0.40), 0.47)
    out = S.place(out, _lvl(_sheet(1.3, r, freq=42.0, tau=0.45, groan=0.9), 0.45), 0.46)
    return _room(out, size=2.0, damping=0.32, mix=0.30, predelay=0.018, cap=2.55)


# ---------------------------------------------------------------------------
# the two loops
# ---------------------------------------------------------------------------

# LOOP LEAD-IN. Every filter in synth.py starts from zero state, so the
# first 100-300 ms of any filtered bed is quieter than the rest - which on
# a LOOP is a dip once per revolution, exactly the artefact loop-safety is
# supposed to prevent. So a loop here is built LEAD seconds longer than it
# ships and the lead is thrown away (`_settle`): by the time the retained
# window starts, every filter, comb and noise integrator has reached its
# steady state. Every LFO frequency below still divides the SHIPPED length,
# so slicing off a lead does not move where a cycle ends.
LOOP_LEAD = 0.6

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


@cue("rimeWhiteout", loop=True)
def rime_whiteout(r):
    """LOOP: phase three's storm. A wind BED, not an event - it has to sit
    under the barrage's strikes without competing, because the strikes are
    the thing you dodge and the wind is only the reason you cannot see them
    coming.

    LOOP-SAFETY, four things. The shipped length is exactly 3.0 s. Both gust
    LFOs (2/3 Hz and 4/3 Hz) complete a whole number of cycles across it, so
    the level at the seam matches on both sides. The ice ticks are scattered
    only inside the first 2.6 s, so nothing is still ringing when the file
    wraps. Everything is built over a `LOOP_LEAD` that is then discarded, so
    the head is at full steady-state level instead of ramping up out of the
    filters' zero state. And the reverb is `tail=False`.
    """
    dur = 3.0
    build = dur + LOOP_LEAD
    tt = S.t(build)
    wind = S.band_noise(build, r, 200.0, 12000.0, order=2)
    wind = S.bp_sweep(wind, 1400.0 + 700.0 * np.sin(2.0 * np.pi * (2.0 / 3.0) * tt),
                      q=1.1)
    gust = (0.62 + 0.38 * np.sin(2.0 * np.pi * (2.0 / 3.0) * tt)) * \
           (0.80 + 0.20 * np.sin(2.0 * np.pi * (4.0 / 3.0) * tt))
    wind = wind * gust
    hiss = S.band_noise(build, r, 3000.0, 15000.0, order=2) * gust
    low = S.brown(build, r)
    low = S.bandpass(low, 30.0, 180.0, order=2)
    low = low * (0.7 + 0.3 * np.sin(2.0 * np.pi * (2.0 / 3.0) * tt))
    y = S.mix(_lvl(_settle(wind, dur), 1.0), _lvl(_settle(hiss, dur), 0.28),
              _lvl(S.saturate(_settle(low, dur), 2.0), 0.40))
    ticks = S.silence(dur)
    for _ in range(11):
        at = float(r.random()) * 2.6                    # nothing near the seam
        ticks = S.place(ticks, _snap(0.16, r, freq=2600.0 *
                                     float(2.0 ** (r.random() * 1.2 - 0.6)),
                                     chirp=0.45, tau=0.007, grit=0.3) *
                        (0.10 + 0.14 * float(r.random())), at)
    y = S.mix(y, S.fit(ticks, dur))
    return (_room(y, size=1.8, damping=0.42, mix=0.22, tail=False))


@cue("rimeRiftAmbient", loop=True)
def rime_rift_ambient(r):
    """LOOP: an open hole in the ice. Slow irregular water slaps against the
    rim, the rift breathing, and nothing else - it is a place marker the
    player navigates by, so it must never sound like an attack.

    LOOP-SAFETY. 2.8 s exactly. The slaps sit on an IRREGULAR grid (regular
    slaps read as a machine) but none begins after 2.45 s, so the longest of
    them has died before the seam. The swell LFO completes two whole cycles.
    The resonant bed is built over `LOOP_LEAD` and the lead discarded, so the
    hole is already ringing at the head instead of fading in. `tail=False`.
    """
    dur = 2.8
    build = dur + LOOP_LEAD
    # The rift itself: a hollow, resonant column of air over water.
    hollow = S.band_noise(build, r, 90.0, 2600.0, order=2)
    hollow = S.mix(_lvl(S.resonator(hollow, 118.0, q=13.0), 1.0),
                   _lvl(S.resonator(hollow, 176.0, q=10.0), 0.5),
                   _lvl(S.resonator(hollow, 310.0, q=7.0), 0.22))
    hollow = _settle(hollow, dur)
    hollow = hollow * (0.70 + 0.30 * np.sin(2.0 * np.pi * (2.0 / dur) * S.t(dur)))
    slaps = S.silence(dur)
    at = 0.02
    while at < 2.45:
        wet = S.splash(0.26, r, low=280.0, high=4200.0, sweep_to=240.0, body=0.45)
        lap = S.mix(_lvl(wet, 1.0),
                    _lvl(S.bubble(0.10, 190.0 * float(2.0 ** (r.random() - 0.5)), r,
                                  rise=2.2, tau=0.045), 0.45))
        slaps = S.place(slaps, lap * (0.35 + 0.55 * float(r.random())), at)
        at += 0.30 + 0.38 * float(r.random())          # irregular on purpose
    drips = S.wet_texture(2.4, r, density=3.2, freq=1300.0, spread=2.6, level=0.4)
    y = S.mix(_lvl(hollow, 0.55), _lvl(S.fit(slaps, dur), 1.0),
              _lvl(S.fit(drips, dur), 0.22))
    y = S.lowpass(y, 7000.0, order=2)
    return (_room(y, size=1.4, damping=0.45, mix=0.20, tail=False))


@cue("rimeDeath")
def rime_death(r):
    """It goes back down through its own broken sheet for the last time.
    The call fails, the body goes under, and the floe knits shut over it in
    a long run of settling cracks - the last sound on the ice, and the only
    one on this sheet that ends quieter than it began."""
    dur = 3.00
    out = S.silence(dur)
    last = _rime_growl(1.6, r, f0=58.0, bend=(1.1, 0.88, 0.46), rasp=0.55, sub=0.95,
                       bright=0.6, flutter=24.0)
    last *= S.breakpoints(1.6, [(0.0, 0.0), (0.10, 0.95), (0.85, 0.45), (1.6, 0.0)],
                          curve="exp")
    out = S.place(out, _lvl(last, 0.90), 0.0)
    out = S.place(out, _lvl(_run(0.8, r, count=14, f0=3600.0, f1=1300.0, accel=1.2),
                            0.40), 0.55)
    out = S.place(out, _lvl(_sub(1.9, 52.0, 18.0, tau=0.75, drive=3.0, attack=0.05),
                            0.92), 1.15)
    out = S.place(out, _lvl(S.splash(1.1, r, low=190.0, high=5600.0, sweep_to=180.0,
                                     body=0.8), 0.72), 1.25)
    out = S.place(out, _lvl(_sheet(1.6, r, freq=30.0, tau=0.62, groan=1.0), 0.75), 1.20)
    out = S.place(out, _lvl(_run(1.3, r, count=18, f0=2400.0, f1=800.0, accel=0.45),
                            0.30), 1.55)
    out = S.place(out, _lvl(S.wet_texture(1.0, r, density=18.0, freq=520.0,
                                          level=0.5), 0.26), 1.70)
    return _room(out, size=2.3, damping=0.34, mix=0.31, cap=3.30)
