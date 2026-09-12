"""sfx_combat.py - the `combat` sheet. Nineteen cues.

THE TWO-LAYER HIT. `hitCrack` and `hitThump` are one impact split into two
cues on purpose: the client plays both for a normal hit and can drop the
crack for a glancing one or swap in `killCrack`/`killThump` for the last.
So the two must SUM to a single event, which constrains them:

  * the crack lives entirely above 700 Hz and is under 60 ms;
  * the thump lives entirely below 700 Hz and is under 250 ms;
  * neither has reverb (the sum gets it on the client, and reverb on both
    would double the room).

Cross them over anywhere else and playing both gives a 200 Hz honk where
the layers overlap.

DISTANCE. `gunFireRemote` and `bowFireRemote` are NOT the near cues turned
down. Distance is: high frequencies gone (air absorbs them), the transient
smeared, and a slap-back arriving 60-90 ms later off whatever is nearby.
`_far()` does all three, and it is the only difference between the pairs -
which is what keeps someone else's shot recognisable as the same weapon.

REGISTER MAP (nothing may collide with the fishing sheet's minigame blips):
  gunFire      broadband, 40 Hz-14 kHz, the loudest thing here
  bowFire      1-6 kHz thwip, no low end at all
  bulletWhiz   a 2-5 kHz doppler swept ACROSS the head, no attack
  zoomIn/Out   200-900 Hz only, soft attacks - the two non-violent cues
"""

import numpy as np

import synth as S
from cues import cue


# The 5 ms lead-in. `build.finish_cue` puts a 3 ms fade on BOTH edges of
# every cue as click insurance - correct in general, but that fade lands on
# the transient of any cue whose peak is at t=0, which on this sheet is
# nearly all of them, and takes 50-80% off it. That transient is the entire
# reason `hitCrack` exists, so five milliseconds of leading silence moves it
# clear of the fade. Well under the ~10 ms at which anyone perceives
# latency, and it costs 5 ms of sprite.
LEAD = 0.005


def _lead(x):
    return S.place(S.silence(LEAD), x, LEAD)


def _far(x, cutoff=2600.0, slap_ms=72.0, slap=0.30, seed=29):
    """Turn a near sound into a distant one: kill the air-absorbed highs,
    soften the leading edge, and add one reflection off the terrain."""
    y = S.lowpass(x, cutoff, order=3)
    out = S.mix(y, S.place(S.silence(len(y) / S.SR + slap_ms / 1000.0 + 0.05),
                           S.lowpass(y, cutoff * 0.55, order=2) * slap,
                           slap_ms / 1000.0))
    return _lead(S.reverb(out, size=1.2, damping=0.55, mix=0.26, seed=seed))


def _whoosh(r, dur, f_lo, f_hi, q=2.0, peak=0.45, level=1.0, width=0.0):
    """Air moving past: a band centre that rises to `f_hi` at the moment of
    closest approach (`peak` of the way through) and falls after. The ARC,
    not the noise, is what makes it a swing.

    `width` (0-1) additionally OPENS the band as the arm accelerates and
    closes it again as it slows, by crossfading a narrow pass against a
    wide one. A whoosh whose bandwidth never changes is a filter sweep; the
    bandwidth moving is what the ear hears as something passing it. Left at
    0 the behaviour is exactly what it was before 2026-09-12.
    """
    src = S.white(dur, r)
    centre = S.breakpoints(dur, [(0.0, f_lo), (dur * peak, f_hi),
                                 (dur * (peak + 0.12), f_hi * 0.62), (dur, f_lo * 0.8)],
                           curve="exp")
    y = S.bp_sweep(src, centre, q=q)
    if width > 0.0:
        wide = S.bp_sweep(src, centre, q=max(0.7, q * 0.30))
        open_ = S.breakpoints(dur, [(0.0, 0.0), (dur * peak, 1.0),
                                    (dur * min(0.99, peak + 0.25), 0.25), (dur, 0.0)])
        g = np.clip(open_ * float(width), 0.0, 1.0)[: len(y)]
        y = y * (1.0 - g) + wide[: len(y)] * g
    y *= S.breakpoints(dur, [(0.0, 0.0), (dur * 0.2, 0.4), (dur * peak, 1.0),
                             (dur * (peak + 0.18), 0.42), (dur, 0.0)], curve="exp")
    return y * level


def _impact(r, dur, thud_hz=88.0, slap_level=0.55, grit=8, drive=3.0, mass=1.0):
    """The body of a landed blow, as three physically separate things.

    A hit on a creature is NOT one filtered thump. It is the BODY moving
    (a membrane at 60-110 Hz - flesh over a cavity, which is what a drum
    head is), the SLAP of the surface (a short 150-900 Hz band: skin and
    cloth, not the mass behind them) and a little GRIT thrown off it. The
    three have independent envelopes, and the slap leads the body by about
    a millisecond, exactly as it does physically - the surface fails before
    the mass behind it starts to move.

    Band-limited to the sheet's 700 Hz crossover by the caller; everything
    here lives below it so `hitCrack` can own everything above.
    """
    f0 = float(np.clip(thud_hz, 60.0, 110.0))
    head = S.membrane(dur * 0.75, f0, r, drop=0.5 + 0.12 * mass, noise=0.22,
                      tau=dur * 0.20 * mass)
    sine = S.sine(dur, S.expsweep(dur, f0 * 2.1, f0 * 0.68))
    sine *= S.perc_env(dur, 0.0015, dur * 0.22 * mass, curve=1.2)
    slap = S.band_noise(0.05, r, 150.0, 900.0, order=2)
    slap = S.lp_sweep(slap, S.expsweep(0.05, 900.0, 260.0), order=2)
    slap *= S.perc_env(0.05, 0.0008, 0.011, curve=1.3)
    dust = _debris(r, grit, dur * 0.45, 0.16, 180.0, 690.0, 0.010)
    return S.mix(S.fit(S.saturate(head * 0.95, 2.2), dur),
                 S.fit(S.saturate(sine, drive), dur),
                 S.fit(slap, dur) * slap_level,
                 S.fit(dust, dur))


def _debris(r, count, spread, level, low=1200.0, high=9000.0, start=0.02):
    """Fragments landing after an impact - grit, chips, shell casing bounce."""
    out = S.silence(start + spread + 0.06)
    for _ in range(count):
        at = start + float(r.random()) ** 1.4 * spread
        g = S.band_noise(0.004, r, low, high) * S.perc_env(0.004, 0.0002, 0.0010)
        out = S.place(out, g * (0.25 + 0.75 * float(r.random())) * level, at)
    return out


def _take(i):
    """The three BAKED TAKES, added 2026-09-12. Same idea as the footsteps'
    `_v`: a sprite plays back identically every time, so seeded jitter
    inside a renderer only varies things between builds, not between
    swings - and `punchSwing` / `hitCrack` / `hitThump` fire dozens of
    times a minute, which is most of why melee read as repetitive.

    (pitch, level, time-skew), chosen so that no two takes are close on
    more than one axis: two takes differing only in level are heard as the
    same sample twice, which is worse than no variants at all.
    """
    return ((1.00, 1.00, 1.00),
            (1.07, 0.90, 0.94),
            (0.94, 0.97, 1.07))[i % 3]


# ---------------------------------------------------------------------------
# swings
# ---------------------------------------------------------------------------

@cue("punchSwing")
def punch_swing(r):
    """A fist: short, broad, no edge. Nothing above 5 kHz, because a fist
    has no thin part to whistle.

    Softer and WIDER than the cast: an arm is a blunt object, so the band
    opens right out at the moment of closest approach (`width=0.8`) instead
    of staying a narrow whistle, and there are three layers under it -
    sleeve cloth with a soft attack, the body of air the arm displaces
    (brown noise, no top at all) and a tiny low puff for weight.
    """
    return _punch(r)


def _punch(r, p=1.0, lv=1.0, sk=1.0):
    dur = 0.26 * sk
    y = _whoosh(r, dur, 240.0 * p, 1700.0 * p, q=1.6, peak=0.50, width=0.80)
    cl = 0.12 * sk
    cloth = S.band_noise(cl, r, 600.0 * p, 4000.0 * p, order=2) * S.perc_env(cl, 0.008, 0.032)
    air = S.brown(0.16, r)
    air = S.lp_sweep(air, S.breakpoints(0.16, [(0.0, 600.0 * p), (0.09, 1500.0 * p),
                                               (0.16, 400.0 * p)], curve="exp"), order=2)
    air *= S.breakpoints(0.16, [(0.0, 0.0), (0.03, 0.6), (0.085, 1.0),
                                (0.16, 0.0)], curve="exp")
    puff = S.sine(dur, S.expsweep(dur, 116.0 * p, 62.0 * p)) * S.perc_env(dur, 0.010, 0.045)
    return _lead(S.reverb(
        S.lowpass(S.mix(y * 0.9, S.fit(cloth, dur) * 0.30,
                        S.place(S.silence(dur), air * 0.45, 0.030 * sk),
                        S.saturate(puff * 0.26, 1.8)), 5000.0 * p, order=2),
        size=0.4, damping=0.6, mix=0.09, seed=29) * lv)


@cue("punchSwing", variants=3)
def punch_swing_takes(r, i):
    """Three takes of `punchSwing`. The base cue above is the fallback."""
    return _punch(r, *_take(i))


@cue("weaponSwing")
def weapon_swing(r):
    """A weapon: longer, faster, and with an EDGE - a thin resonant tone
    tracking the whoosh an octave and a half above it. That tone is the
    only reason this reads as steel rather than as a bigger fist.

    MASS is now explicit. `_swing_mass` takes one number (1.0 = a cutlass)
    and derives every frequency and length from it, because that is how
    mass actually works: a heavier weapon moves a bigger, slower column of
    air, so its whoosh is LOWER, LONGER and starts earlier, and its edge
    tone drops with it. The shipped cue is authored at 1.25 - the game's
    melee weapons are hatchets and gaffs, not rapiers - which makes it
    audibly heavier than `punchSwing` rather than just brighter.
    """
    return _lead(S.reverb(_swing_mass(r, mass=1.25),
                          size=0.45, damping=0.5, mix=0.10, seed=29))


def _swing_mass(r, mass=1.0):
    """A weapon swing at a given mass. Heavier = lower, longer, more body.

    Four layers: the AIR (a moving centre and a moving bandwidth), the
    EDGE (a thin tone tracking the air an octave and a half up - the only
    reason this reads as steel rather than as a bigger fist), the HEFT (a
    low sweep, saturated, the arm behind it) and a HAFT creak for anything
    heavy enough to load a wooden handle.
    """
    m = float(np.clip(mass, 0.6, 2.2))
    dur = 0.30 * (0.72 + 0.28 * m) + 0.06 * m
    peak = 0.52
    y = _whoosh(r, dur, 340.0 / m, 4200.0 / (0.55 + 0.45 * m), q=2.6, peak=peak,
                width=0.55)
    f = S.breakpoints(dur, [(0.0, 900.0 / m), (dur * peak, 3100.0 / m),
                            (dur, 1100.0 / m)], curve="exp")
    edge = S.sine(dur, f) * 0.18 + S.sine(dur, f * 1.5) * 0.07
    edge *= S.breakpoints(dur, [(0.0, 0.0), (dur * 0.35, 0.5), (dur * peak, 1.0),
                                (dur, 0.0)], curve="exp")
    heft = S.sine(dur, S.expsweep(dur, 210.0 / m, 105.0 / m))
    heft *= S.perc_env(dur, 0.012, 0.075 * m)
    haft = S.band_noise(0.09, r, 300.0, 2200.0, order=2)
    haft = S.resonator(haft, 420.0 / m, q=16.0)
    haft = haft / (np.max(np.abs(haft)) + 1e-12)
    haft *= S.breakpoints(0.09, [(0.0, 0.0), (0.02, 1.0), (0.09, 0.0)], curve="exp")
    return S.mix(y, edge, S.saturate(heft * (0.20 + 0.14 * m), 1.8),
                 S.place(S.silence(dur), haft * 0.16 * (m - 0.6), dur * 0.18))


@cue("swingRefused")
def swing_refused(r):
    """On cooldown / no stamina: the swing that does not happen. A muted,
    choked-off version of `weaponSwing` - it starts identically for 25 ms
    and then is smothered. That shared opening is what makes it read as
    'that input was heard and denied' rather than as a new sound."""
    dur = 0.26
    y = _whoosh(r, 0.10, 340.0, 1300.0, q=2.0, peak=0.6) * 0.55
    mute = S.band_noise(0.09, r, 200.0, 1400.0, order=2)
    mute *= S.perc_env(0.09, 0.001, 0.020, curve=1.5)
    low = S.sine(0.18, S.expsweep(0.18, 165.0, 98.0)) * S.perc_env(0.18, 0.003, 0.040)
    y = S.mix(S.fit(y, dur), S.fit(mute, dur) * 0.6, S.fit(S.saturate(low * 0.6, 2.0), dur))
    return _lead(S.lowpass(y, 2000.0, order=2))


# ---------------------------------------------------------------------------
# the landed hit - two layers that must sum to one event (see the header)
# ---------------------------------------------------------------------------

@cue("hitCrack")
def hit_crack(r):
    """The crack layer: everything ABOVE 700 Hz, under 60 ms, no reverb.
    A 1.5 ms noise spit through two short resonances - the sound of the
    surface failing, not of the mass behind it.

    Since 2026-09-12 it also carries the UPPER half of the skin/cloth slap
    (a 900-3000 Hz band with a 0.8 ms attack) and a few grains of grit.
    `hitThump` has the lower half; played together they are one slap, and
    played apart - which is what a glancing hit does - the crack alone
    still reads as contact rather than as a tick.
    """
    return _hit_crack(r)


def _hit_crack(r, p=1.0, lv=1.0, sk=1.0):
    dur = 0.095 * sk
    spit = S.band_noise(0.0015, r, 1400.0 * p, 15000.0) * S.perc_env(0.0015, 0.00008, 0.0004)
    exc = S.fit(spit, dur)
    ring = (S.resonator(exc, 2400.0 * p, q=9.0) * 0.8
            + S.resonator(exc, 4600.0 * p, q=7.0) * 0.45)
    ring *= S.expdec(dur, 0.012 * sk)
    snap = S.band_noise(0.03, r, 1800.0 * p, 11000.0, order=2) * S.perc_env(0.03, 0.0002, 0.005)
    slap = S.band_noise(0.030, r, 900.0 * p, 3000.0 * p, order=2)
    slap = S.lp_sweep(slap, S.expsweep(0.030, 3000.0 * p, 1100.0 * p), order=2)
    slap *= S.perc_env(0.030, 0.0008, 0.0075, curve=1.3)
    grit = _debris(r, 6, 0.045 * sk, 0.20, 3000.0, 12000.0, 0.006)
    y = S.mix(S.fit(spit, dur) * 0.8, ring, S.fit(snap, dur) * 0.55,
              S.fit(slap, dur) * 0.45, S.fit(grit, dur))
    return _lead(S.highpass(y, 700.0, order=2)) * lv


@cue("hitCrack", variants=3)
def hit_crack_takes(r, i):
    """Three takes of the crack layer. Still entirely above 700 Hz."""
    return _hit_crack(r, *_take(i))


@cue("hitThump")
def hit_thump(r):
    """The body layer: everything BELOW 700 Hz, under 250 ms, no reverb.
    Saturated hard, because on its own a sine at 90 Hz is a test tone; with
    drive it is a mass arriving.

    `_impact` now builds it: a MEMBRANE at 88 Hz (a body is a cavity with a
    face on it, and a drum head is the same object), a saturated sine
    sweep under that for the mass, the low half of the skin/cloth SLAP, and
    a little sub-700 Hz grit. Four envelopes instead of two, which is the
    difference between a thud and a filtered beep.
    """
    return _hit_thump(r)


def _hit_thump(r, p=1.0, lv=1.0, sk=1.0):
    dur = 0.26 * sk
    y = _impact(r, dur, thud_hz=88.0 * p, slap_level=0.50, grit=7, drive=3.0,
                mass=1.0 * sk)
    return _lead(S.lowpass(y, 700.0, order=3)) * lv


@cue("hitThump", variants=3)
def hit_thump_takes(r, i):
    """Three takes of the body layer. Still entirely below 700 Hz, so any
    crack take sums cleanly with any thump take."""
    return _hit_thump(r, *_take(i))


@cue("killCrack")
def kill_crack(r):
    """The killing blow's crack: lower, wider and with a bone-splinter tail
    of grit. Still band-limited to the same crossover as `hitCrack`, so the
    two pairs are interchangeable."""
    dur = 0.20
    spit = S.band_noise(0.002, r, 900.0, 14000.0) * S.perc_env(0.002, 0.00008, 0.0006)
    exc = S.fit(spit, dur)
    ring = (S.resonator(exc, 1500.0, q=11.0) * 0.9 + S.resonator(exc, 3100.0, q=8.0) * 0.5
            + S.resonator(exc, 5900.0, q=6.0) * 0.25)
    ring *= S.expdec(dur, 0.028)
    y = S.mix(S.fit(spit, dur) * 0.9, ring,
              S.fit(_debris(r, 9, 0.11, 0.28, 2200.0, 12000.0, 0.012), dur))
    return _lead(S.highpass(y, 700.0, order=2))


@cue("killThump")
def kill_thump(r):
    """The killing blow's body: a fifth lower than `hitThump`, twice as
    long, and it ends with a short downward drop - a 'that is over' gesture
    that a normal hit must not have."""
    dur = 0.58
    heavy = _impact(r, 0.40, thud_hz=66.0, slap_level=0.55, grit=10, drive=3.2,
                    mass=1.8)
    sub = S.sine(dur, S.expsweep(dur, 78.0, 32.0)) * S.perc_env(dur, 0.010, 0.16)
    y = S.mix(S.fit(heavy, dur), S.saturate(sub * 0.7, 2.2))
    return _lead(S.lowpass(y, 700.0, order=3))


# ---------------------------------------------------------------------------
# guns
# ---------------------------------------------------------------------------

def _gun_core(r, dur=0.55, pitch=1.0, level=1.0):
    """The shot itself, before any distance treatment. Three parts: the
    2 ms CRACK (the bullet going supersonic), the BLAST (a saturated
    low-passed noise body) and the muzzle CAVITY ringing under it."""
    crack = S.band_noise(0.002, r, 2000.0 * pitch, 16000.0) * S.perc_env(0.002, 0.00005, 0.0005)
    blast = S.band_noise(0.24, r, 60.0, 12000.0, order=2)
    blast = S.lp_sweep(blast, S.expsweep(0.24, 11000.0 * pitch, 380.0), order=2)
    blast *= S.perc_env(0.24, 0.0006, 0.038, curve=1.4)
    boom = S.sine(0.30, S.expsweep(0.30, 220.0 * pitch, 52.0)) * S.perc_env(0.30, 0.0015, 0.070)
    cavity = S.resonator(S.fit(crack, 0.18), 540.0 * pitch, q=7.0) * S.expdec(0.18, 0.030)
    y = S.mix(S.fit(crack, dur) * 0.85, S.fit(S.saturate(blast, 2.0), dur),
              S.fit(S.saturate(boom * 0.9, 2.8), dur), S.fit(cavity, dur) * 0.35)
    return y * level


@cue("gunFire")
def gun_fire(r):
    """The player's own shot. Big, close and dry-ish: a tight room only, so
    it sits in front of the mix. The tail is the shell casing landing."""
    dur = 0.65
    y = _gun_core(r, dur)
    y = S.mix(y, S.fit(_debris(r, 5, 0.22, 0.10, 3000.0, 11000.0, 0.20), dur))
    return _lead(S.reverb(y, size=0.55, damping=0.45, mix=0.12, seed=29))


@cue("gunFireRemote")
def gun_fire_remote(r):
    """Someone else's shot: `_far` on the same core - highs gone, edge
    smeared, one slap-back off the terrain. Same weapon, other end of the
    beach."""
    return _far(_gun_core(r, 0.6, pitch=0.94, level=0.9), cutoff=2400.0,
                slap_ms=86.0, slap=0.34)


@cue("gunReload")
def gun_reload(r):
    """A three-beat mechanical phrase - magazine RELEASED (a spring click
    plus the mag dropping away), magazine SEATED (a solid low clack), bolt
    RUN (a metal slide and a hard lock). Uneven spacing on purpose; evenly
    spaced clicks read as a machine, not as hands."""
    dur = 1.25
    out = S.silence(dur)

    def clack(f, ring, rough, gain, at, low=None):
        m = S.metal_hit(0.16, r, f, ring=ring, roughness=rough) * gain
        out_ = S.place(out, m, at)
        if low is not None:
            out_ = S.place(out_, S.saturate(
                S.sine(0.10, S.expsweep(0.10, low * 1.8, low))
                * S.perc_env(0.10, 0.001, 0.018), 2.2) * gain * 0.7, at)
        return out_

    out = clack(1750.0, 0.10, 0.7, 0.55, 0.00)                 # catch released
    out = S.place(out, S.metal_hit(0.22, r, 420.0, ring=0.20, roughness=0.6) * 0.35, 0.09)
    out = clack(760.0, 0.14, 0.5, 0.85, 0.34, low=120.0)       # mag seated
    # The bolt running back and forward: a short metallic slide each way.
    for at, lo, hi in ((0.62, 1100.0, 3400.0), (0.80, 3400.0, 1300.0)):
        sl = S.bp_sweep(S.white(0.09, r), S.expsweep(0.09, lo, hi), q=4.0)
        sl *= S.breakpoints(0.09, [(0.0, 0.0), (0.012, 1.0), (0.09, 0.0)])
        out = S.place(out, sl * 0.30, at)
    out = clack(1280.0, 0.16, 0.45, 0.95, 0.88, low=150.0)     # bolt locked
    return _lead(S.reverb(out * 0.85, size=0.5, damping=0.5, mix=0.11, seed=29))


@cue("gunReady")
def gun_ready(r):
    """One click - the weapon is up and will fire. Tiny, dry, and the
    highest-pitched mechanical cue on the sheet so it never hides inside
    the reload phrase."""
    dur = 0.10
    m = S.metal_hit(0.075, r, 2050.0, ring=0.08, roughness=0.6)
    tick = S.band_noise(0.0018, r, 3000.0, 15000.0) * S.perc_env(0.0018, 0.00008, 0.0004)
    return _lead(S.mix(S.fit(m, dur) * 0.8, S.fit(tick, dur) * 0.5))


@cue("dryFire")
def dry_fire(r):
    """The trigger with nothing behind it: `gunReady`'s click a fifth lower,
    hollow, and with a hint of the blast that DID NOT happen - 20 ms of
    heavily filtered air where the shot should be. That absence is the cue."""
    dur = 0.20
    m = S.metal_hit(0.14, r, 1150.0, ring=0.12, roughness=0.75) * 0.8
    hollow = S.resonator(S.fit(S.white(0.003, r) * S.perc_env(0.003, 0.0002, 0.0008), dur),
                         290.0, q=6.0) * S.expdec(dur, 0.035) * 0.5
    ghost = S.band_noise(0.02, r, 150.0, 900.0, order=2) * S.perc_env(0.02, 0.001, 0.006)
    return _lead(S.lowpass(S.mix(S.fit(m, dur), hollow,
                                S.fit(ghost, dur) * 0.35), 3200.0, order=2))


@cue("zoomIn")
def zoom_in(r):
    """Sights up. One of only two non-violent cues here, so it is soft-attack
    and narrow-band (200-900 Hz): a short rising filtered swell with a tiny
    lens click at the top. It must never sound like a weapon."""
    dur = 0.26
    swell = S.band_noise(0.20, r, 180.0, 1400.0, order=2)
    swell = S.bp_sweep(swell, S.expsweep(0.20, 260.0, 900.0), q=3.0)
    swell *= S.breakpoints(0.20, [(0.0, 0.0), (0.10, 1.0), (0.20, 0.0)], curve="exp")
    tone = S.sine(0.20, S.expsweep(0.20, 330.0, 494.0)) * S.perc_env(0.20, 0.020, 0.055) * 0.4
    click = S.band_noise(0.0022, r, 2200.0, 9000.0) * S.perc_env(0.0022, 0.0001, 0.0006)
    return _lead(S.mix(S.fit(swell, dur) * 0.8, S.fit(tone, dur),
                       S.place(S.silence(dur), click * 0.30, 0.155)))


@cue("zoomOut")
def zoom_out(r):
    """Sights down: `zoomIn` reversed in gesture - falling band, falling
    tone, click FIRST. Shorter, because leaving a state should be quicker
    than entering it."""
    dur = 0.20
    swell = S.band_noise(0.16, r, 180.0, 1400.0, order=2)
    swell = S.bp_sweep(swell, S.expsweep(0.16, 820.0, 250.0), q=3.0)
    swell *= S.breakpoints(0.16, [(0.0, 0.0), (0.05, 1.0), (0.16, 0.0)], curve="exp")
    tone = S.sine(0.16, S.expsweep(0.16, 494.0, 330.0)) * S.perc_env(0.16, 0.012, 0.040) * 0.35
    click = S.band_noise(0.0022, r, 1800.0, 8000.0) * S.perc_env(0.0022, 0.0001, 0.0006)
    return _lead(S.mix(S.fit(swell, dur) * 0.8, S.fit(tone, dur),
                       S.fit(click, dur) * 0.28))


# ---------------------------------------------------------------------------
# bows
# ---------------------------------------------------------------------------

def _bow_core(r, dur=0.45, pitch=1.0, level=1.0):
    """String release + shaft. The THWIP is a plucked string damped almost
    to nothing (a bowstring is a string that is not allowed to ring), and
    the shaft leaving is a fast rising band. No low end at all - that is
    what separates a bow from a gun at any distance."""
    thwip = S.karplus(0.18, 320.0 * pitch, r, brightness=0.85, damping=0.72)
    thwip *= S.perc_env(0.18, 0.0004, 0.026, curve=1.5)
    limb = S.resonator(S.fit(S.white(0.003, r) * S.perc_env(0.003, 0.0002, 0.0008), 0.20),
                       165.0 * pitch, q=8.0) * S.expdec(0.20, 0.045) * 0.35
    shaft = S.bp_sweep(S.white(0.22, r), S.expsweep(0.22, 1600.0 * pitch, 5200.0), q=2.4)
    shaft *= S.breakpoints(0.22, [(0.0, 0.0), (0.006, 1.0), (0.09, 0.35), (0.22, 0.0)],
                           curve="exp")
    y = S.mix(S.fit(thwip, dur) * 0.95, S.fit(limb, dur), S.fit(shaft, dur) * 0.55)
    return S.highpass(y, 130.0, order=2) * level


@cue("bowFire")
def bow_fire(r):
    """The player's own release."""
    return _lead(S.reverb(_bow_core(r, 0.45), size=0.5, damping=0.5, mix=0.11,
                          seed=29))


@cue("bowFireRemote")
def bow_fire_remote(r):
    """Someone else's release: `_far` with a HIGHER cutoff than the gun uses.
    A bow has no low end to survive the distance, so cutting it as hard as a
    gunshot would leave nothing audible at all."""
    return _far(_bow_core(r, 0.5, pitch=0.96, level=0.9), cutoff=3400.0,
                slap_ms=64.0, slap=0.26)


@cue("renock")
def renock(r):
    """Next arrow onto the string: a small wooden tap, a nock clicking home
    and the string taking the tension (a very short rising creak). All three
    are quiet - this is a housekeeping sound and must not compete with the
    shot it precedes."""
    dur = 0.34
    out = S.silence(dur)
    out = S.place(out, S.bar(0.10, 640.0, r, decay=0.030, strike=0.5) * 0.45, 0.0)
    click = S.band_noise(0.0025, r, 2400.0, 11000.0) * S.perc_env(0.0025, 0.0001, 0.0006)
    out = S.place(out, click * 0.35, 0.095)
    creak = S.karplus(0.16, 296.0, r, brightness=0.35, damping=0.55)
    creak *= S.breakpoints(0.16, [(0.0, 0.0), (0.04, 0.7), (0.16, 0.0)], curve="exp")
    out = S.place(out, creak * 0.30, 0.115)
    return _lead(S.reverb(out, size=0.4, damping=0.6, mix=0.09, seed=29))


# ---------------------------------------------------------------------------
# what the shot does
# ---------------------------------------------------------------------------

@cue("bulletImpact")
def bullet_impact(r):
    """A round arriving in a surface: a very hard 1 ms transient, a short
    ricochet-ish resonance and a spray of grit. Under 300 ms in total - a
    long impact reads as an explosion."""
    dur = 0.30
    spit = S.band_noise(0.0012, r, 1600.0, 16000.0) * S.perc_env(0.0012, 0.00005, 0.0003)
    exc = S.fit(spit, dur)
    stone = (S.resonator(exc, 1900.0, q=14.0) * 0.7 + S.resonator(exc, 3700.0, q=10.0) * 0.4
             + S.resonator(exc, 780.0, q=9.0) * 0.5)
    stone *= S.expdec(dur, 0.022)
    punch = S.sine(0.12, S.expsweep(0.12, 240.0, 78.0)) * S.perc_env(0.12, 0.0008, 0.022)
    grit = _debris(r, 11, 0.16, 0.30, 1800.0, 12000.0, 0.010)
    y = S.mix(S.fit(spit, dur), stone, S.fit(S.saturate(punch * 0.8, 2.4), dur),
              S.fit(grit, dur))
    return _lead(S.reverb(y, size=0.6, damping=0.5, mix=0.13, seed=29))


@cue("bulletWhiz")
def bullet_whiz(r):
    """A near miss. NO attack at all - by the time you hear it the round is
    already past, so the envelope peaks in the middle. The band centre
    sweeps 5 kHz -> 1.6 kHz across 120 ms, which is the Doppler shift of
    something going by fast, and it is the only cue on the sheet built that
    way, so a near miss is never confused with a hit."""
    dur = 0.24
    src = S.white(dur, r)
    centre = S.breakpoints(dur, [(0.0, 5200.0), (0.10, 3400.0), (0.14, 2000.0),
                                 (dur, 1300.0)], curve="exp")
    y = S.bp_sweep(src, centre, q=5.0)
    tone = S.sine(dur, centre * 0.5) * 0.22
    y = S.mix(y, tone)
    y *= S.breakpoints(dur, [(0.0, 0.0), (0.06, 0.5), (0.105, 1.0), (0.16, 0.35),
                             (dur, 0.0)], curve="exp")
    return _lead(S.reverb(S.highpass(y, 600.0, order=2), size=0.7, damping=0.5,
                          mix=0.10, seed=29))
