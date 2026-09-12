"""sfx_boss_wrack.py - Admiral Wrack, the Fleet-Eater: a ghost ship.

THE VOICE: TIMBER, POWDER AND IRON, with something dead in the rigging. The
only boss in the game that is a MACHINE as well as a monster, and the only
one whose attacks are fired rather than swung - so this sheet is built out
of four materials no other sheet uses:

* THE HULL (`_hull`). A hundred feet of oak: low resonant modes with almost
  no damping and a rope creak riding on them. Every gun on this ship recoils
  INTO the hull, so `_hull` is mixed under every cannon cue - that recoil is
  the single thing that stops a broadside sounding like a firework, because
  a real cannon is heard mostly as the ship it is bolted to.
* POWDER (`_blast`). A charge, not an impact: a very fast broadband crack, a
  low body that PUSHES rather than lands, and a long, dirty tail of burnt
  gas. The tail is what separates a gun from a hit.
* IRON (`_iron`, `_rattle`). Chain, anchor and shot. Struck metal with real
  inharmonic ring, and a rattle built from many small links rather than one
  scraped mass - a chain is a crowd of tiny impacts, and if it is authored
  as filtered noise it reads as sand.
* THE DEAD (`_wisp`). Airy formant moans with no fundamental at all - the
  crew. It is the only pitched-but-unvoiced material in the pack, and it is
  the reason the ship reads as haunted rather than as a warship.

THE FIGHT IS FOUGHT ON DECKS, so the room is smaller and woodier than any
other boss arena: a hull answers fast and close, and the sea is the tail.
"""

import numpy as np

import synth as S
from cues import cue


# build.py puts a 3 ms fade on the HEAD of every cue as click insurance, so a
# cue whose loudest sample is a transient at t=0 loses its own peak to it.
# Four milliseconds of silence in front of every one-shot puts the transient
# clear of the fade - inaudible as a delay, and it costs nothing.
HEAD_LEAD = 0.004

# LOOP LEAD-IN. Every filter and noise integrator in synth.py starts from
# ZERO state, so the head of a filtered bed is quieter than the rest - on a
# LOOP that is a dip once per revolution. A loop here is built LOOP_LEAD
# longer than it ships and the lead is discarded (`_settle`). Every LFO
# frequency still divides the SHIPPED length, so the slice does not move
# where a cycle ends.
LOOP_LEAD = 0.6


def _room(x, size=1.5, damping=0.48, mix=0.26, predelay=0.012, tail=True,
          cap=None):
    """A deck at night: wood close in, open water behind it. Smaller and
    faster than any other boss arena, because a hull answers immediately -
    what makes it feel big is the length of the tail, not the predelay."""
    # Sub-26 Hz is headroom the peak normalise gives away (sfx_boss_shared).
    x = S.highpass(x, 26.0, order=2)
    y = S.reverb(x, size=size, damping=damping, mix=mix, predelay=predelay,
                 seed=37, tail=tail)
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


def _settle(x, dur, lead=LOOP_LEAD):
    """Drop the filter-startup lead: a loop must start at steady state."""
    return S.fit(np.asarray(x, dtype=np.float64)[S.n(lead):], dur)


# ---------------------------------------------------------------------------
# the four materials
# ---------------------------------------------------------------------------

def _hull(dur, r, freq=58.0, decay=0.55, creak=0.4, hit=1.0):
    """A HUNDRED FEET OF OAK. Low modes with long decays - a ship's hull is
    an enormous, badly damped box - plus rope creak riding on top. Mixed
    under every gun so the recoil goes somewhere."""
    exc = S.fit(S.white(0.006, r) * S.perc_env(0.006, 0.0002, 0.0018), dur)
    body = np.zeros(S.n(dur))
    for i, ratio in enumerate((1.0, 1.87, 2.94, 4.31, 6.02)):
        f = freq * ratio * (0.97 + 0.06 * float(r.random()))
        body = body + S.resonator(exc, f, q=22.0 - 3.0 * i) / (i + 1.3)
    body *= S.expdec(dur, decay * 0.30)
    out = _lvl(S.saturate(body, 2.2), 1.0) * hit
    if creak > 0:
        # Rope and joint: a resonant band chopped by a slowing irregular
        # tremolo - stick-slip, which is what timber under load does.
        rope = S.band_noise(dur, r, 180.0, 3200.0, order=2)
        rope = S.mix(_lvl(S.resonator(rope, 260.0, q=18.0), 1.0),
                     _lvl(S.resonator(rope, 393.0, q=13.0), 0.5))
        tt = S.t(dur)
        chop = 0.5 + 0.5 * np.sin(2.0 * np.pi * (19.0 / 0.8) * (1.0 - np.exp(-tt * 0.8)))
        rope = rope * (0.2 + 0.8 * chop ** 3)
        rope *= S.breakpoints(dur, [(0.0, 0.0), (0.05, 0.8), (dur * 0.7, 0.5),
                                    (dur, 0.0)], curve="exp")
        out = S.mix(out, _lvl(rope, creak * 0.55))
    return out


def _blast(dur, r, size=1.0, low=44.0, dirt=0.7):
    """POWDER. A charge going off, which is not an impact:

    a sub-millisecond broadband CRACK, a low body that pushes outward
    (rising very slightly before it falls - expanding gas, not a struck
    mass), and a long dirty TAIL of burnt smoke. The tail is the whole
    difference between a gun and a hammer.
    """
    crack = S.band_noise(min(dur, 0.09), r, 220.0, 17000.0, order=3)
    crack = S.lp_sweep(crack, S.expsweep(min(dur, 0.09), 15000.0, 900.0), order=2)
    crack *= S.perc_env(min(dur, 0.09), 0.0002, 0.006 * size, curve=1.2)
    push = S.sine(dur, S.breakpoints(dur, [(0.0, low * 1.15), (0.03, low * 1.35),
                                           (dur, low * 0.45)], curve="exp"))
    push *= S.perc_env(dur, 0.0015, dur * 0.24 * size, curve=1.1)
    out = S.mix(_lvl(S.fit(crack, dur), 1.0),
                _lvl(S.saturate(push, 3.0), 0.95))
    if dirt > 0:
        smoke = S.band_noise(dur, r, 90.0, 7000.0, order=2)
        smoke = S.lp_sweep(smoke, S.expsweep(dur, 5000.0, 260.0), order=2)
        smoke *= S.breakpoints(dur, [(0.0, 0.0), (0.012, 1.0), (dur * 0.55, 0.35),
                                     (dur, 0.0)], curve="exp")
        out = S.mix(out, _lvl(smoke, dirt * 0.55))
    return out


def _iron(dur, r, freq=280.0, ring=0.7, rough=0.5, level=1.0):
    """STRUCK IRON: anchor, chain stock, gun barrel. Real inharmonic ring
    with a metallic roughness - the one material on this sheet with a long
    sustain, which is what makes an anchor unmistakable next to a hull."""
    return S.metal_hit(dur, r, freq=freq, ring=ring, roughness=rough) * level


def _rattle(dur, r, count=22, freq=900.0, spread=None, level=1.0, accel=1.0):
    """CHAIN. A crowd of small iron impacts, not a scrape - authored as
    filtered noise a chain reads as sand, and the individual links are what
    make it read as weight being dragged."""
    if spread is None:
        spread = dur * 0.88
    out = S.silence(dur)
    for i in range(count):
        u = (i / max(1, count - 1.0)) ** accel
        at = u * spread + 0.010 * float(r.random())
        f = freq * float(2.0 ** (r.random() * 1.5 - 0.75))
        link = S.mix(_lvl(S.metal_hit(0.10, r, freq=f, ring=0.35, roughness=0.7), 1.0),
                     _lvl(S.band_noise(0.006, r, f, min(16000.0, f * 8.0)) *
                          S.perc_env(0.006, 0.0002, 0.0016), 0.5))
        out = S.place(out, link * (0.25 + 0.75 * float(r.random())) * level, at)
    return S.fit(out, dur)


def _wisp(dur, r, f0=210.0, drift=0.35, breath=0.8, voices=3):
    """THE DEAD IN THE RIGGING. Airy moans with NO fundamental: formant
    bands over filtered noise, several of them, each drifting at its own
    rate so they never lock. Unvoiced-but-pitched is a very specific effect
    and it is the whole reason this ship sounds haunted."""
    out = np.zeros(S.n(dur))
    tt = S.t(dur)
    for v in range(voices):
        rate = 0.55 + 0.35 * v + 0.2 * float(r.random())
        f = f0 * (0.78 + 0.30 * v) * (1.0 + drift * 0.25 *
                                      np.sin(2.0 * np.pi * rate * tt + v))
        src = S.band_noise(dur, r, 120.0, 6000.0, order=2)
        # `bp_sweep`, not `resonator`: the formant DRIFTS, and `resonator`
        # designs one fixed peak (it takes a scalar). The drift is the whole
        # effect - three fixed bands over noise is a filter, three wandering
        # ones is a voice that is not quite there.
        voice = (S.bp_sweep(src, f, q=8.0) +
                 S.bp_sweep(src, f * 2.42, q=6.0) * 0.45 +
                 S.bp_sweep(src, f * 4.1, q=4.5) * 0.18)
        env = S.breakpoints(dur, [(0.0, 0.0), (dur * (0.20 + 0.10 * v), 1.0),
                                  (dur * (0.62 + 0.08 * v), 0.7), (dur, 0.0)],
                            curve="exp")
        out = out + _lvl(voice, 1.0 / (1.0 + 0.4 * v)) * env
    if breath > 0:
        air = S.band_noise(dur, r, 900.0, 7000.0, order=2)
        air = S.tremolo(air, rate=1.7, depth=0.4)
        air *= S.breakpoints(dur, [(0.0, 0.0), (dur * 0.35, 1.0), (dur, 0.0)],
                             curve="exp")
        out = S.mix(out, _lvl(air, breath * 0.20))
    return out


def _wrack_growl(dur, r, f0=56.0, bend=(0.92, 1.20, 0.72), rasp=0.55, sub=0.85,
                 bright=0.9, flutter=21.0, ghost=0.45):
    """THE ADMIRAL. A drowned man's shout with the ship in it: an ordinary
    low throat, but bandpassed hard and mixed with `_wisp` so it is never
    quite solid - the voice of something that is speaking through timber
    rather than air."""
    contour = S.breakpoints(dur, [(0.0, f0 * bend[0]), (dur * 0.31, f0 * bend[1]),
                                  (dur, f0 * bend[2])], curve="exp")
    core = S.saw(dur, contour, bright=0.85) * 0.6 + S.pulse(dur, contour, 0.30) * 0.45
    core = S.moog(core, S.breakpoints(dur, [(0.0, 420.0), (dur * 0.28, 2400.0 * bright),
                                            (dur, 560.0)], curve="exp"), res=0.36)
    throat = S.formant(core, [280.0, 810.0, 1900.0], qs=[9.0, 7.0, 5.0],
                       gains=[1.0, 0.58, 0.26])
    voice = S.mix(_lvl(core, 0.32), _lvl(throat, 0.95))
    if rasp > 0:
        edge = S.band_noise(dur, r, 240.0, 4200.0 * bright, order=2)
        edge = S.tremolo(edge, rate=flutter, depth=0.85)
        edge *= S.breakpoints(dur, [(0.0, 0.0), (0.05, 1.0), (dur, 0.35)])
        voice = S.mix(voice, _lvl(edge, rasp * 0.45))
    if sub > 0:
        low = S.highpass(S.sine(dur, contour * 0.5) +
                         S.sine(dur, contour * 0.25) * 0.5, 27.0, order=4)
        voice = S.mix(voice, _lvl(S.saturate(low, 2.2), sub * 0.9))
    if ghost > 0:
        voice = S.mix(voice, _lvl(_wisp(dur, r, f0=f0 * 5.0, breath=0.4, voices=2),
                                  ghost * 0.4))
    return voice


# ---------------------------------------------------------------------------
# the seven voice variants - the shared vocabulary in oak and powder
# ---------------------------------------------------------------------------

@cue("bossTell__admiral_wrack")
def tell_wrack(r):
    """The ship takes aim. A boatswain's warning in the shape of the fight:
    the hull heeling over (a low creak that rises), the wisps going quiet
    for a beat, and one iron note - a gunport chain drawn back. The iron is
    what the player learns to listen for."""
    dur = 0.90
    out = S.silence(dur)
    heel = _hull(0.75, r, freq=52.0, decay=0.9, creak=0.85, hit=0.45)
    heel *= S.breakpoints(0.75, [(0.0, 0.0), (0.15, 0.7), (0.62, 1.0), (0.75, 0.0)],
                          curve="exp")
    out = S.place(out, _lvl(heel, 1.0), 0.0)
    out = S.place(out, _lvl(_iron(0.42, r, freq=430.0, ring=0.5, rough=0.6), 0.50),
                  0.36)
    out = S.place(out, _lvl(_rattle(0.30, r, count=7, freq=1100.0, level=0.7), 0.34),
                  0.38)
    swell = S.sine(dur, S.expsweep(dur, 50.0, 82.0))
    swell *= S.breakpoints(dur, [(0.0, 0.0), (0.72, 1.0), (dur, 0.1)], curve="exp")
    out = S.mix(out, _lvl(S.saturate(swell, 2.0), 0.40))
    return _room(out, size=1.3, mix=0.24, cap=1.20)


@cue("bossRise__admiral_wrack")
def rise_wrack(r):
    """The wreck comes up. A hull breaking the surface: water pouring out of
    a hundred feet of rotten oak, the timbers taking their own weight again
    for the first time in years, and the crew waking in the rigging."""
    dur = 2.20
    out = S.silence(dur)
    surface = S.band_noise(1.9, r, 70.0, 6000.0, order=2)
    surface = S.lp_sweep(surface, S.breakpoints(1.9, [(0.0, 240.0), (1.35, 2800.0),
                                                      (1.9, 800.0)], curve="exp"),
                         order=2)
    surface *= S.breakpoints(1.9, [(0.0, 0.0), (1.30, 0.85), (1.55, 1.0), (1.9, 0.08)],
                             curve="exp")
    out = S.place(out, _lvl(surface, 0.90), 0.0)
    out = S.place(out, _lvl(_sub(2.0, 30.0, 50.0, tau=0.85, drive=2.6, attack=0.06),
                            0.75), 0.0)
    groan = _hull(1.5, r, freq=44.0, decay=1.4, creak=1.0, hit=0.55)
    groan *= S.breakpoints(1.5, [(0.0, 0.0), (0.25, 0.8), (1.15, 1.0), (1.5, 0.0)],
                           curve="exp")
    out = S.place(out, _lvl(groan, 0.70), 0.45)
    out = S.place(out, _lvl(_wisp(1.2, r, f0=260.0, breath=0.9), 0.35), 0.85)
    out = S.place(out, _lvl(S.wet_texture(0.9, r, density=20.0, freq=600.0,
                                          level=0.5), 0.30), 1.20)
    return _room(out, size=1.8, damping=0.48, mix=0.29, cap=2.70)


@cue("bossRoar__admiral_wrack")
def roar_wrack(r):
    """THE ADMIRAL GIVES AN ORDER. Not an animal noise - a shout, with the
    ship speaking under it: the throat, the hull resonating in sympathy, and
    the crew answering from the rigging half a beat behind. The half-beat
    lag is what makes it a CREW rather than a chorus effect."""
    dur = 2.20
    voice = _wrack_growl(dur, r, f0=54.0, bend=(0.88, 1.28, 0.68), rasp=0.62,
                         sub=0.92, ghost=0.55)
    voice *= S.breakpoints(dur, [(0.0, 0.0), (0.06, 0.75), (dur * 0.30, 1.0),
                                 (dur * 0.60, 0.8), (dur * 0.92, 0.2), (dur, 0.0)],
                           curve="exp")
    out = _lvl(S.saturate(voice, 1.7), 1.0)
    out = S.mix(out, _lvl(_sub(dur, 50.0, 26.0, tau=0.90, drive=2.8, attack=0.03),
                          0.55))
    hull = _hull(1.6, r, freq=48.0, decay=1.5, creak=0.5, hit=0.4)
    hull *= S.breakpoints(1.6, [(0.0, 0.0), (0.12, 0.9), (1.6, 0.0)], curve="exp")
    out = S.mix(out, _lvl(S.fit(hull, dur), 0.34))
    out = S.place(out, _lvl(_wisp(1.3, r, f0=300.0, breath=1.0, voices=4), 0.40), 0.32)
    return _room(out, size=1.9, damping=0.44, mix=0.29, predelay=0.018, cap=2.70)


@cue("bossSnap__admiral_wrack")
def snap_wrack(r):
    """A gunport slamming, or a jaw that is mostly iron. Hard, metallic and
    short - the one cue in the voice set with no powder in it, so the ear
    keeps it separate from the guns."""
    dur = 0.60
    out = S.silence(dur)
    out = S.place(out, _lvl(S.band_noise(0.05, r, 700.0, 14000.0, order=3) *
                            S.perc_env(0.05, 0.0003, 0.005), 0.90), 0.0)
    out = S.place(out, _lvl(_iron(0.34, r, freq=340.0, ring=0.35, rough=0.75), 0.85),
                  0.002)
    out = S.place(out, _lvl(_hull(0.30, r, freq=88.0, decay=0.30, creak=0.0), 0.65),
                  0.003)
    out = S.place(out, _lvl(_sub(0.34, 96.0, 44.0, tau=0.08, drive=2.5), 0.62), 0.003)
    out = S.place(out, _lvl(_rattle(0.22, r, count=6, freq=1400.0), 0.28), 0.020)
    return _room(out, size=1.2, damping=0.46, mix=0.21, cap=0.90)


@cue("bossSlam__admiral_wrack")
def slam_wrack(r):
    """Something enormous coming down on the deck. Planking, not stone: the
    boards give, the hull answers underneath, and the whole ship rolls a
    little afterwards - that roll is the low creak in the tail."""
    dur = 1.60
    out = S.silence(dur)
    out = S.place(out, _lvl(S.band_noise(0.13, r, 300.0, 11000.0, order=3) *
                            S.perc_env(0.13, 0.0004, 0.016), 0.75), 0.0)
    out = S.place(out, _lvl(_hull(1.0, r, freq=54.0, decay=0.9, creak=0.55), 1.0),
                  0.004)
    out = S.place(out, _lvl(_sub(1.20, 58.0, 25.0, tau=0.36, drive=2.9), 0.95), 0.004)
    for i, f in enumerate((132.0, 208.0, 331.0)):
        out = S.place(out, S.bar(0.34, f, r, decay=0.045 - 0.008 * i, strike=0.9) *
                      (0.42 - 0.10 * i), 0.005)
    out = S.place(out, _lvl(_rattle(0.5, r, count=10, freq=1200.0, level=0.6), 0.24),
                  0.05)
    return _room(out, size=1.7, damping=0.46, mix=0.27, predelay=0.014, cap=2.05)


@cue("bossDown__admiral_wrack")
def down_wrack(r):
    """The ship going back down. Water taking the hold, the timbers letting
    go one after another, and the crew going quiet - the wisps are the last
    thing left, and they simply stop."""
    dur = 2.50
    out = S.silence(dur)
    give = _hull(1.2, r, freq=42.0, decay=1.3, creak=1.0, hit=0.7)
    give *= S.breakpoints(1.2, [(0.0, 0.0), (0.06, 1.0), (0.75, 0.55), (1.2, 0.0)],
                          curve="exp")
    out = S.place(out, _lvl(give, 0.85), 0.0)
    last = _wrack_growl(1.1, r, f0=46.0, bend=(1.1, 0.86, 0.54), rasp=0.45, sub=0.9,
                        bright=0.6, ghost=0.6)
    last *= S.breakpoints(1.1, [(0.0, 0.0), (0.12, 0.9), (0.7, 0.45), (1.1, 0.0)],
                          curve="exp")
    out = S.place(out, _lvl(last, 0.70), 0.10)
    out = S.place(out, _lvl(_sub(1.7, 60.0, 21.0, tau=0.66, drive=2.8, attack=0.05),
                            0.88), 0.90)
    out = S.place(out, _lvl(S.splash(1.0, r, low=180.0, high=5200.0, sweep_to=180.0,
                                     body=0.8), 0.72), 0.95)
    out = S.place(out, _lvl(_wisp(1.0, r, f0=280.0, breath=0.9, voices=3), 0.30), 1.25)
    return _room(out, size=2.0, damping=0.48, mix=0.30, cap=2.90)


@cue("bossStagger__admiral_wrack")
def stagger_wrack(r):
    """The ship takes it badly. A mast or a spar comes down across the deck:
    timber failing (a long tearing creak that speeds up), the arrival, and
    then the hull rolling and complaining for as long as the window is
    open - the roll IS the window, so it is what carries."""
    dur = 2.20
    out = S.silence(dur)
    tear = _hull(0.50, r, freq=76.0, decay=0.5, creak=1.0, hit=0.35)
    tear *= S.breakpoints(0.50, [(0.0, 0.0), (0.05, 1.0), (0.50, 0.0)], curve="exp")
    out = S.place(out, _lvl(tear, 0.65), 0.0)
    out = S.place(out, _lvl(S.band_noise(0.16, r, 250.0, 10000.0, order=3) *
                            S.perc_env(0.16, 0.0005, 0.020), 0.70), 0.36)
    out = S.place(out, _lvl(_hull(1.25, r, freq=44.0, decay=1.3, creak=0.7), 1.0),
                  0.364)
    out = S.place(out, _lvl(_sub(1.60, 50.0, 21.0, tau=0.52, drive=3.0), 1.0), 0.364)
    out = S.place(out, _lvl(_rattle(0.9, r, count=16, freq=1000.0, level=0.7,
                                    accel=0.7), 0.30), 0.40)
    groan = _wrack_growl(1.0, r, f0=48.0, bend=(1.0, 0.84, 0.58), rasp=0.5, sub=0.85,
                         bright=0.6, ghost=0.5)
    groan *= S.breakpoints(1.0, [(0.0, 0.0), (0.14, 1.0), (0.6, 0.5), (1.0, 0.0)],
                           curve="exp")
    out = S.place(out, _lvl(groan, 0.48), 0.50)
    return _room(out, size=1.9, damping=0.46, mix=0.29, predelay=0.016, cap=2.65)


# ---------------------------------------------------------------------------
# the guns
# ---------------------------------------------------------------------------

@cue("wrackBroadside")
def wrack_broadside(r):
    """THE BROADSIDE. Six guns going off down one side of the ship, NOT
    together: 18-40 ms apart, because a real broadside is fired in a ripple
    and that ripple is the whole sound. Each charge recoils into the hull,
    and what is left afterwards is a hundred feet of oak ringing."""
    dur = 2.20
    out = S.silence(dur)
    at = 0.0
    for i in range(6):
        size = 0.9 + 0.25 * float(r.random())
        out = S.place(out, _lvl(_blast(0.85, r, size=size, low=42.0 + 4.0 * i,
                                       dirt=0.7), 1.0 - 0.07 * i), at)
        out = S.place(out, _lvl(_hull(0.7, r, freq=50.0 + 3.0 * i, decay=0.8,
                                      creak=0.3), 0.55 - 0.05 * i), at + 0.004)
        at += 0.018 + 0.026 * float(r.random())
    out = S.place(out, _lvl(_sub(1.7, 46.0, 20.0, tau=0.55, drive=3.1), 0.95), 0.006)
    # The ship absorbing it: the roll afterwards.
    roll = _hull(1.4, r, freq=40.0, decay=1.5, creak=0.85, hit=0.4)
    roll *= S.breakpoints(1.4, [(0.0, 0.0), (0.12, 0.9), (1.4, 0.0)], curve="exp")
    out = S.place(out, _lvl(roll, 0.42), 0.20)
    return _room(out, size=1.9, damping=0.44, mix=0.28, predelay=0.014, cap=2.60)


@cue("wrackCannonoverload")
def wrack_cannonoverload(r):
    """A gun bursting its own barrel. The biggest single report on the
    sheet, and it is WRONG on purpose: the crack has iron shrapnel in it,
    the body is too big for the barrel that made it, and it ends in a
    scatter of hot metal on planking rather than in smoke."""
    dur = 2.40
    out = S.silence(dur)
    out = S.place(out, _lvl(_blast(1.30, r, size=1.6, low=36.0, dirt=0.9), 1.0), 0.0)
    out = S.place(out, _lvl(_iron(0.7, r, freq=190.0, ring=0.85, rough=0.9), 0.60),
                  0.002)
    out = S.place(out, _lvl(_sub(1.9, 42.0, 18.0, tau=0.70, drive=3.2), 1.0), 0.003)
    out = S.place(out, _lvl(_hull(1.3, r, freq=46.0, decay=1.3, creak=0.7), 0.65),
                  0.006)
    # The barrel coming apart, landing across the deck.
    for _ in range(13):
        at = 0.10 + float(r.random()) * 0.95
        f = 620.0 * float(2.0 ** (r.random() * 1.8 - 0.9))
        out = S.place(out, _lvl(_iron(0.20, r, freq=f, ring=0.4, rough=0.8),
                                0.09 + 0.16 * float(r.random())), at)
    return _room(out, size=2.0, damping=0.42, mix=0.30, predelay=0.016, cap=2.80)


@cue("wrackShots")
def wrack_shots(r):
    """Small arms - the crew firing muskets. Three or four flat, dry cracks
    with almost no low end, pitched well above the guns so a volley of these
    can never be mistaken for a broadside."""
    dur = 0.85
    out = S.silence(dur)
    at = 0.0
    for i in range(4):
        out = S.place(out, _lvl(_blast(0.30, r, size=0.32, low=110.0, dirt=0.5),
                                0.95 - 0.12 * i), at)
        at += 0.055 + 0.055 * float(r.random())
    return _room(out, size=1.4, damping=0.42, mix=0.22, cap=1.15)


@cue("wrackGrapeshot")
def wrack_grapeshot(r):
    """MANY SMALL IMPACTS. The gun has already fired; this is the shot
    ARRIVING - twenty-odd iron balls hitting planking and rail across about
    a fifth of a second, each with its own pitch and its own distance. The
    scatter is the cue: one impact is a bullet, twenty is grapeshot."""
    dur = 0.85
    out = S.silence(dur)
    times = np.sort(r.random(23)) ** 0.75 * 0.30
    for i, at in enumerate(times):
        near = 0.3 + 0.7 * float(r.random())
        f = 320.0 * float(2.0 ** (r.random() * 2.0 - 1.0))
        one = S.mix(_lvl(S.band_noise(0.014, r, 800.0, 14000.0, order=3) *
                         S.perc_env(0.014, 0.0002, 0.0022), 1.0),
                    _lvl(S.bar(0.14, f, r, decay=0.022, strike=0.9), 0.75),
                    _lvl(_iron(0.10, r, freq=f * 3.1, ring=0.25, rough=0.8), 0.35))
        out = S.place(out, one * near * 0.55, float(at))
    out = S.place(out, _lvl(_hull(0.55, r, freq=72.0, decay=0.45, creak=0.2), 0.40),
                  0.010)
    return _room(out, size=1.4, damping=0.44, mix=0.23, cap=1.10)


@cue("wrackBulletWhiz")
def wrack_bullet_whiz(r):
    """A near miss. Very short, very close: a band of noise sweeping DOWN
    through the ear as the ball passes, with the classic Doppler dip at the
    moment it goes by. Nothing else - a whiz with a body is a hit."""
    dur = 0.24
    src = S.band_noise(dur, r, 700.0, 14000.0, order=2)
    centre = S.breakpoints(dur, [(0.0, 3600.0), (0.075, 2600.0), (dur, 900.0)],
                           curve="exp")
    y = S.bp_sweep(src, centre, q=5.5)
    y = S.mix(_lvl(y, 1.0), _lvl(S.sine(dur, centre), 0.30))
    y *= S.breakpoints(dur, [(0.0, 0.0), (0.020, 1.0), (0.055, 0.75), (dur, 0.0)],
                       curve="exp")
    return _room(y, size=0.9, damping=0.40, mix=0.14, cap=0.34)


# ---------------------------------------------------------------------------
# powder and fire
# ---------------------------------------------------------------------------

@cue("wrackPowderrun")
def wrack_powderrun(r):
    """A powder trail burning ACROSS the deck toward something. A travelling
    fizz: the hiss gets brighter and closer as it runs, with grains popping
    inside it, so the player can hear which way it is going and how long is
    left. It is a countdown, so it must never sound steady."""
    dur = 1.25
    fizz = S.band_noise(dur, r, 700.0, 16000.0, order=2)
    fizz = S.bp_sweep(fizz, S.breakpoints(dur, [(0.0, 2600.0), (0.7, 4600.0),
                                                (dur, 7000.0)], curve="exp"), q=1.2)
    fizz = S.tremolo(fizz, rate=23.0, depth=0.35)
    fizz *= S.breakpoints(dur, [(0.0, 0.0), (0.06, 0.5), (0.9, 0.9), (dur, 1.0)],
                          curve="exp")
    grains = S.silence(dur)
    at = 0.0
    gap = 0.055
    while at < dur - 0.02:
        pop = S.band_noise(0.010, r, 2000.0, 15000.0, order=2)
        pop *= S.perc_env(0.010, 0.0002, 0.0018)
        grains = S.place(grains, pop * (0.3 + 0.7 * float(r.random())), at)
        at += gap * (0.6 + 0.8 * float(r.random()))
        gap *= 0.965                          # it is speeding up as it closes
    y = S.mix(_lvl(fizz, 1.0), _lvl(S.fit(grains, dur), 0.45))
    return _room(y, size=1.2, damping=0.44, mix=0.18, cap=1.45)


@cue("wrackKegFuse", loop=True)
def wrack_keg_fuse(r):
    """LOOP: a fuse burning on a powder keg. It runs for as long as the keg
    is alive, so it must be a texture with no shape at all - a player who
    hears a rhythm in it will try to read a countdown out of it and be
    wrong.

    LOOP-SAFETY. Exactly 1.2 s. The two flutter LFOs run at 5 Hz and 15 Hz -
    6 and 18 whole cycles across the loop. The grain pops are placed only
    inside the first 1.1 s and none of them is longer than 10 ms, so nothing
    is ringing at the seam. Built over `LOOP_LEAD` and the lead discarded so
    the filters are at steady state at sample zero, and `tail=False`.
    """
    dur = 1.2
    build = dur + LOOP_LEAD
    tt = S.t(build)
    hiss = S.band_noise(build, r, 1600.0, 17000.0, order=2)
    hiss = S.bp_sweep(hiss, 5200.0 + 1200.0 * np.sin(2.0 * np.pi * 5.0 * tt), q=1.1)
    flick = (0.70 + 0.30 * np.sin(2.0 * np.pi * 5.0 * tt)) * \
            (0.82 + 0.18 * np.sin(2.0 * np.pi * 15.0 * tt + 0.6))
    hiss = hiss * flick
    heat = S.band_noise(build, r, 200.0, 1600.0, order=2) * flick
    y = S.mix(_lvl(_settle(hiss, dur), 1.0), _lvl(_settle(heat, dur), 0.30))
    grains = S.silence(dur)
    at = 0.01
    while at < 1.10:
        pop = S.band_noise(0.009, r, 2400.0, 16000.0, order=2)
        pop *= S.perc_env(0.009, 0.0002, 0.0016)
        grains = S.place(grains, pop * (0.25 + 0.55 * float(r.random())), at)
        at += 0.035 + 0.065 * float(r.random())
    y = S.mix(y, _lvl(S.fit(grains, dur), 0.42))
    return _room(y, size=1.0, damping=0.50, mix=0.14, tail=False)


@cue("wrackKegBlast")
def wrack_keg_blast(r):
    """The keg going up. A bigger, dirtier, LOWER charge than a gun - a keg
    is unconfined, so there is no barrel crack on the front of it: it is
    almost all body and smoke, with the deck it was standing on failing
    underneath."""
    dur = 2.10
    out = S.silence(dur)
    out = S.place(out, _lvl(_blast(1.20, r, size=1.4, low=38.0, dirt=1.0), 1.0), 0.0)
    out = S.place(out, _lvl(_sub(1.75, 44.0, 19.0, tau=0.62, drive=3.2), 1.0), 0.002)
    out = S.place(out, _lvl(_hull(1.1, r, freq=48.0, decay=1.1, creak=0.6), 0.70),
                  0.005)
    # Deck planking failing and coming back down.
    for _ in range(12):
        at = 0.06 + float(r.random()) * 0.70
        f = 190.0 * float(2.0 ** (r.random() * 1.7 - 0.85))
        out = S.place(out, S.bar(0.20, f, r, decay=0.030, strike=0.85) *
                      (0.08 + 0.16 * float(r.random())), at)
    out = S.place(out, _lvl(_rattle(0.9, r, count=12, freq=1100.0, level=0.6,
                                    accel=0.7), 0.24), 0.10)
    return _room(out, size=1.9, damping=0.44, mix=0.29, predelay=0.014, cap=2.50)


@cue("wrackBrazier")
def wrack_brazier(r):
    """FIRE. A brazier catching and settling: a low roar of combustion with
    irregular flare-ups in it and the wood inside it ticking. The one warm
    sound in a fight made of cold iron and cold water."""
    dur = 1.35
    fire = S.band_noise(dur, r, 120.0, 9000.0, order=2)
    fire = S.bp_sweep(fire, S.breakpoints(dur, [(0.0, 700.0), (0.35, 2200.0),
                                                (dur, 900.0)], curve="exp"), q=1.0)
    flare = (0.55 + 0.45 * np.sin(2.0 * np.pi * 3.3 * S.t(dur))) * \
            (0.7 + 0.3 * np.sin(2.0 * np.pi * 1.1 * S.t(dur) + 0.8))
    fire = fire * flare
    fire *= S.breakpoints(dur, [(0.0, 0.0), (0.10, 1.0), (0.9, 0.75), (dur, 0.0)],
                          curve="exp")
    roar = S.brown(dur, r)
    roar = S.bandpass(roar, 40.0, 340.0, order=2) * flare
    ticks = S.silence(dur)
    for _ in range(15):
        at = 0.05 + float(r.random()) * 1.15
        f = 900.0 * float(2.0 ** (r.random() * 1.6 - 0.8))
        ticks = S.place(ticks, S.bar(0.09, f, r, decay=0.018, strike=0.8) *
                        (0.08 + 0.18 * float(r.random())), at)
    y = S.mix(_lvl(fire, 1.0), _lvl(S.saturate(roar, 2.2), 0.45), _lvl(ticks, 0.30))
    return _room(y, size=1.3, damping=0.50, mix=0.20, cap=1.60)


# ---------------------------------------------------------------------------
# iron: chain, anchor, boom
# ---------------------------------------------------------------------------

@cue("wrackAnchorsweep")
def wrack_anchorsweep(r):
    """AN ANCHOR ON A CHAIN, swept across the deck. Three things at once and
    all of them iron: the chain paying out (a rattle that accelerates), the
    anchor's own ring as it travels, and the deep drag of something very
    heavy scraping planking."""
    dur = 1.55
    out = S.silence(dur)
    drag = S.band_noise(dur, r, 90.0, 5000.0, order=2)
    drag = S.bp_sweep(drag, S.breakpoints(dur, [(0.0, 240.0), (0.6, 700.0),
                                                (dur, 280.0)], curve="exp"), q=1.5)
    drag = S.tremolo(drag, rate=29.0, depth=0.55)
    drag *= S.breakpoints(dur, [(0.0, 0.0), (0.22, 0.7), (0.68, 1.0), (dur, 0.0)],
                          curve="exp")
    out = S.mix(out, _lvl(drag, 0.85))
    out = S.mix(out, _lvl(_rattle(dur, r, count=30, freq=850.0, level=0.9,
                                  accel=1.35), 1.0))
    out = S.place(out, _lvl(_iron(0.9, r, freq=155.0, ring=0.9, rough=0.6), 0.55),
                  0.10)
    mass = S.sine(dur, S.expsweep(dur, 96.0, 46.0))
    mass *= S.breakpoints(dur, [(0.0, 0.0), (0.66, 1.0), (dur, 0.0)], curve="exp")
    out = S.mix(out, _lvl(S.saturate(mass, 2.4), 0.55))
    return _room(out, size=1.6, damping=0.44, mix=0.26, cap=1.90)


@cue("wrackAnchorline")
def wrack_anchorline(r):
    """The line itself: chain running out fast through a hawse. A pure
    rattle, accelerating hard and then STOPPING DEAD on an iron clang - the
    stop is the information, because it is where the anchor reaches the end
    of its travel."""
    dur = 1.00
    out = S.silence(dur)
    out = S.mix(out, _lvl(_rattle(0.72, r, count=34, freq=1050.0, level=0.9,
                                  accel=1.6), 1.0))
    run = S.band_noise(0.72, r, 500.0, 11000.0, order=2)
    run = S.tremolo(run, rate=44.0, depth=0.6)
    run *= S.breakpoints(0.72, [(0.0, 0.0), (0.10, 0.6), (0.62, 1.0), (0.72, 0.0)],
                         curve="exp")
    out = S.mix(out, _lvl(S.fit(run, dur), 0.38))
    out = S.place(out, _lvl(_iron(0.42, r, freq=240.0, ring=0.55, rough=0.7), 0.85),
                  0.70)
    out = S.place(out, _lvl(_sub(0.36, 110.0, 52.0, tau=0.07, drive=2.4), 0.35), 0.702)
    return _room(out, size=1.4, damping=0.44, mix=0.23, cap=1.30)


@cue("wrackBoomsweep")
def wrack_boomsweep(r):
    """The boom swinging across the deck. A big spar moving fast: a broad
    air rush with the rigging singing under load and the block-and-tackle
    complaining - and it passes, so the whole thing arcs."""
    dur = 1.25
    air = S.band_noise(dur, r, 120.0, 8000.0, order=2)
    air = S.bp_sweep(air, S.breakpoints(dur, [(0.0, 300.0), (0.48, 1500.0),
                                              (0.62, 1100.0), (dur, 320.0)],
                                        curve="exp"), q=1.7)
    air *= S.breakpoints(dur, [(0.0, 0.0), (0.18, 0.5), (0.50, 1.0), (0.68, 0.65),
                               (dur, 0.0)], curve="exp")
    rig = _hull(0.95, r, freq=118.0, decay=0.55, creak=1.0, hit=0.25)
    rig *= S.breakpoints(0.95, [(0.0, 0.0), (0.2, 0.8), (0.95, 0.0)], curve="exp")
    mass = S.sine(dur, S.expsweep(dur, 110.0, 52.0))
    mass *= S.breakpoints(dur, [(0.0, 0.0), (0.52, 1.0), (dur, 0.0)], curve="exp")
    y = S.mix(_lvl(air, 1.0), _lvl(S.fit(rig, dur), 0.45),
              _lvl(S.saturate(mass, 2.2), 0.38))
    return _room(y, size=1.5, damping=0.46, mix=0.24, cap=1.55)


@cue("wrackBell")
def wrack_bell(r):
    """THE SHIP'S BELL. Bronze, struck once, and the cleanest sound in the
    fight - it is the ship keeping time, so it is tuned, it rings honestly,
    and it is allowed a long tail. The slow beat in it is two partials a few
    cents apart, which is what a cast bell actually does."""
    dur = 2.20
    body = S.silence(dur)
    for i, f in enumerate((523.25, 784.0, 1046.5)):        # C5 G5 C6
        v = S.bell(1.7, f * (1.0 + 0.0025 * i), r, decay=0.75 - 0.15 * i,
                   strike=0.55, inharmonic=1.15)
        body = S.place(body, v * (0.95 - 0.24 * i), 0.0)
    hum = S.bell(1.9, 261.63, r, decay=1.0, strike=0.3, inharmonic=0.9) * 0.45
    strike = S.mix(_lvl(S.band_noise(0.020, r, 1500.0, 15000.0, order=3) *
                        S.perc_env(0.020, 0.0002, 0.0025), 1.0),
                   _lvl(_iron(0.20, r, freq=1400.0, ring=0.3, rough=0.5), 0.5))
    y = S.mix(_lvl(body, 1.0), _lvl(S.fit(hum, dur), 0.40),
              _lvl(S.fit(strike, dur), 0.32))
    return _room(y, size=1.9, damping=0.36, mix=0.28, cap=2.55)


@cue("wrackHullGroan")
def wrack_hull_groan(r):
    """The hull working in a swell. No event at all - just a hundred feet of
    oak flexing: the pure form of `_hull`'s creak with the low modes barely
    excited under it. It is the ship's idle, so it must not sound like a
    warning."""
    dur = 1.70
    groan = _hull(dur, r, freq=40.0, decay=1.8, creak=1.0, hit=0.30)
    groan *= S.breakpoints(dur, [(0.0, 0.0), (0.22, 0.75), (1.05, 1.0), (dur, 0.0)],
                           curve="exp")
    swell = S.band_noise(dur, r, 60.0, 900.0, order=2)
    swell = S.tremolo(swell, rate=1.4, depth=0.45)
    swell *= S.breakpoints(dur, [(0.0, 0.0), (0.5, 0.9), (dur, 0.0)], curve="exp")
    y = S.mix(_lvl(groan, 1.0), _lvl(swell, 0.35))
    return _room(S.lowpass(y, 5200.0, order=2), size=1.7, damping=0.52, mix=0.26,
                 cap=2.05)


# ---------------------------------------------------------------------------
# the crew, the boats and the water
# ---------------------------------------------------------------------------

@cue("wrackWisps")
def wrack_wisps(r):
    """GHOST WISPS: airy moans coming off the rigging. Four voices with no
    fundamental between them, each drifting at its own rate so they never
    lock into a chord - a chord would be a choir, and this has to be a
    crowd. Deliberately thin: it should be hard to say how many there are."""
    dur = 1.60
    y = _wisp(dur, r, f0=240.0, drift=0.55, breath=1.0, voices=4)
    cold = S.band_noise(dur, r, 3000.0, 12000.0, order=2)
    cold = S.tremolo(cold, rate=0.9, depth=0.5)
    cold *= S.breakpoints(dur, [(0.0, 0.0), (0.5, 0.8), (dur, 0.0)], curve="exp")
    return _room(S.mix(_lvl(y, 1.0), _lvl(cold, 0.16)), size=2.0, damping=0.40,
                 mix=0.31, cap=2.00)


@cue("wrackLadybelow")
def wrack_ladybelow(r):
    """THE LADY, diving past. The fight's one named ghost: the wisp voice
    given a body and a trajectory - it comes in, passes, and goes, so the
    formants sweep DOWN through the pass and the air goes with them. Low and
    long, because she is the size of the ship."""
    dur = 2.00
    out = S.silence(dur)
    approach = _wisp(1.5, r, f0=180.0, drift=0.5, breath=0.9, voices=3)
    approach = S.bp_sweep(approach, S.breakpoints(1.5, [(0.0, 900.0), (0.75, 2400.0),
                                                        (1.5, 600.0)], curve="exp"),
                          q=1.2)
    approach *= S.breakpoints(1.5, [(0.0, 0.0), (0.55, 0.7), (0.85, 1.0),
                                    (1.5, 0.0)], curve="exp")
    out = S.place(out, _lvl(approach, 1.0), 0.0)
    wake = S.band_noise(1.0, r, 90.0, 5000.0, order=2)
    wake = S.lp_sweep(wake, S.expsweep(1.0, 2600.0, 300.0), order=2)
    wake *= S.breakpoints(1.0, [(0.0, 0.0), (0.16, 1.0), (1.0, 0.0)], curve="exp")
    out = S.place(out, _lvl(wake, 0.50), 0.72)
    out = S.place(out, _lvl(_sub(1.3, 62.0, 30.0, tau=0.42, drive=2.6, attack=0.05),
                            0.55), 0.66)
    return _room(out, size=2.1, damping=0.42, mix=0.30, cap=2.40)


@cue("wrackLongboat")
def wrack_longboat(r):
    """A longboat coming alongside: oars in the water in time, a hull
    knocking against the ship's side, and rope. The rhythm is the cue - four
    strokes, evenly spaced, which is the only regular pulse on this whole
    sheet and reads instantly as MEN ROWING."""
    dur = 1.80
    out = S.silence(dur)
    for i in range(4):
        at = i * 0.40
        pull = S.splash(0.26, r, low=350.0, high=5000.0, sweep_to=300.0, body=0.35)
        out = S.place(out, _lvl(pull, 0.85 - 0.05 * i), at)
        creak = _hull(0.30, r, freq=200.0, decay=0.25, creak=1.0, hit=0.2)
        out = S.place(out, _lvl(creak, 0.40), at + 0.06)
        drip = S.wet_texture(0.22, r, density=14.0, freq=1100.0, level=0.5)
        out = S.place(out, _lvl(drip, 0.22), at + 0.18)
    out = S.place(out, _lvl(_hull(0.6, r, freq=90.0, decay=0.4, creak=0.4), 0.42),
                  1.35)
    return _room(out, size=1.4, damping=0.48, mix=0.24, cap=2.10)


@cue("wrackBilgeblow")
def wrack_bilgeblow(r):
    """The bilge letting go: a column of foul water blown out through the
    hull. Wet and pressurised - it starts as a strained hiss, breaks into
    water, and ends in the slop of it hitting the deck."""
    dur = 1.50
    out = S.silence(dur)
    strain = S.band_noise(0.38, r, 200.0, 4000.0, order=2)
    strain = S.bp_sweep(strain, S.expsweep(0.38, 400.0, 1400.0), q=3.0)
    strain *= S.breakpoints(0.38, [(0.0, 0.0), (0.30, 1.0), (0.38, 0.7)], curve="exp")
    out = S.place(out, _lvl(strain, 0.55), 0.0)
    blow = S.band_noise(0.75, r, 120.0, 9000.0, order=2)
    blow = S.lp_sweep(blow, S.expsweep(0.75, 7000.0, 500.0), order=2)
    blow *= S.breakpoints(0.75, [(0.0, 0.0), (0.03, 1.0), (0.45, 0.5), (0.75, 0.0)],
                          curve="exp")
    out = S.place(out, _lvl(blow, 1.0), 0.36)
    out = S.place(out, _lvl(_sub(0.7, 90.0, 40.0, tau=0.2, drive=2.6), 0.55), 0.365)
    out = S.place(out, _lvl(S.wet_texture(0.7, r, density=26.0, freq=330.0,
                                          spread=2.8, level=0.55), 0.42), 0.55)
    out = S.place(out, _lvl(S.splash(0.45, r, low=250.0, high=5200.0, sweep_to=260.0,
                                     body=0.4), 0.45), 0.72)
    return _room(out, size=1.5, damping=0.50, mix=0.25, cap=1.85)


@cue("wrackDeath")
def wrack_death(r):
    """The Fleet-Eater goes down for good. Everything the sheet has, in
    order: the magazine going up somewhere below decks, the hull failing
    along its whole length, the sea taking it, and the crew - the wisps -
    thinning out and stopping. The wisps are the last thing, and their
    ending is the point."""
    dur = 3.10
    out = S.silence(dur)
    out = S.place(out, _lvl(_blast(1.2, r, size=1.5, low=36.0, dirt=1.0), 0.85), 0.0)
    out = S.place(out, _lvl(_sub(1.9, 42.0, 18.0, tau=0.72, drive=3.2), 0.90), 0.003)
    fail = _hull(1.7, r, freq=38.0, decay=1.8, creak=1.0, hit=0.8)
    fail *= S.breakpoints(1.7, [(0.0, 0.0), (0.10, 1.0), (1.0, 0.55), (1.7, 0.0)],
                          curve="exp")
    out = S.place(out, _lvl(fail, 0.80), 0.35)
    last = _wrack_growl(1.3, r, f0=44.0, bend=(1.15, 0.84, 0.48), rasp=0.5, sub=0.95,
                        bright=0.55, ghost=0.7)
    last *= S.breakpoints(1.3, [(0.0, 0.0), (0.12, 0.9), (0.8, 0.4), (1.3, 0.0)],
                          curve="exp")
    out = S.place(out, _lvl(last, 0.70), 0.60)
    out = S.place(out, _lvl(S.splash(1.1, r, low=170.0, high=5400.0, sweep_to=170.0,
                                     body=0.8), 0.75), 1.45)
    out = S.place(out, _lvl(_rattle(1.2, r, count=18, freq=800.0, level=0.7,
                                    accel=0.6), 0.26), 1.30)
    out = S.place(out, _lvl(_wisp(1.4, r, f0=300.0, breath=1.0, voices=4), 0.42), 1.55)
    return _room(out, size=2.2, damping=0.44, mix=0.32, cap=3.30)
