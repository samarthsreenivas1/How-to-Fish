"""sfx_progression.py - the `progression` sheet. Twenty-one cues.

WHAT THIS SHEET IS FOR. Everything here answers "you got somewhere". The
risk with a reward sheet is that all 21 cues become the same rising arpeggio
at different lengths, so the set is organised along two axes that are
audible before the notes are:

  SIZE   coinGain (90 ms, one bell) -> xpGain -> questTick -> ...
         -> levelUp (2.0 s) -> islandUnlock (2.4 s). A player should be able
         to tell how big the reward was with the volume off in their head.
  COLOUR three timbres, one per kind of reward, and they never mix:
           METAL (bells, `metal_hit`)  currency and items
           WOOD  (`S.bar`, marimba)    quests, bestiary, materials
           BRASS (`supersaw` + moog)   the big ceremonial cues and the raid

KEY. G major - deliberately NOT the fishing sheet's D major. A catch
stinger and an XP tick fire within a few hundred ms of each other
constantly; putting them a fifth apart makes that overlap sound intentional
instead of muddy. The three FAILURE cues (`travelRefused`, `raidFail`) drop
to G minor, which is the same tonic and therefore obviously related, and
the only place on the sheet where a Bb appears.

The two ceremonial cues are the ones the contract calls out, and they are
built to that brief exactly: `levelUp` is a genuine 2 s fanfare (chord stab
-> rising arpeggio -> shimmer, with a brass swell answering); `islandUnlock`
is a big warm chord with a slow heartbeat pulse under it.
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

# G major, three octaves, plus the Bb that only the failure cues may use.
G3, B3, D4, G4 = 196.0, 246.94, 293.66, 392.0
A4, B4, C5, D5, E5, G5 = 440.0, 493.88, 523.25, 587.33, 659.25, 783.99
A5, B5, D6, G6, B6, D7 = 880.0, 987.77, 1174.66, 1567.98, 1975.53, 2349.32
Bb3, Bb4 = 233.08, 466.16      # the minor third - failure cues only


def _hall(x, size=0.75, damping=0.42, mix=0.20, tail=True):
    """The progression sheet's room: bigger and brighter than the dock, so a
    reward sounds like it happened in a larger world than a footstep did."""
    y = S.reverb(x, size=size, damping=damping, mix=mix, seed=53, tail=tail)
    return _lead(y) if tail else y


def _shimmer(r, dur, low=4000.0, high=13000.0, level=0.22, attack=0.03):
    y = S.bp_sweep(S.white(dur, r), S.expsweep(dur, low, high), q=1.8)
    y *= S.breakpoints(dur, [(0.0, 0.0), (attack, 1.0), (dur, 0.0)], curve="exp")
    return y * level


def _sparkle(r, dur, count=8, base=2093.0, spread=1.3, level=0.12, start=0.0, over=None):
    """A scatter of tiny high bells. The 'valuable' signifier: metal, high,
    and irregular in time so it reads as many small things, not one chord."""
    out = S.silence(dur)
    span = over if over is not None else dur * 0.6
    for _ in range(count):
        f = base * float(2.0 ** (r.random() * spread))
        at = start + float(r.random()) * span
        out = S.place(out, S.bell(0.28, f, r, decay=0.11, strike=0.6)
                      * level * (0.5 + 0.5 * float(r.random())), at)
    return S.fit(out, dur)


def _coin(r, f, dur=0.26, level=1.0):
    """One coin: a small bright bell plus a metallic edge. Metal COLOUR - see
    the header - so currency is never confused with the wooden quest cues."""
    body = S.bell(dur, f, r, decay=0.085, strike=0.85, inharmonic=1.25)
    edge = S.metal_hit(min(dur, 0.14), r, f * 0.62, ring=0.35, roughness=0.35)
    tick = S.band_noise(0.0016, r, 4000.0, 15000.0) * S.perc_env(0.0016, 0.0001, 0.0004)
    return S.mix(body * 0.9, S.fit(edge, dur) * 0.32, S.fit(tick, dur) * 0.22) * level


def _wood_note(r, f, dur=0.30, decay=None, level=1.0, strike=0.6):
    """WOOD colour: quests, bestiary, materials. A marimba bar - warm, no
    inharmonicity, and it stops. Nothing wooden on this sheet rings."""
    return S.bar(dur, f, r, decay=decay or dur * 0.5, strike=strike) * level


def _brass(r, dur, f, level=1.0, open_to=2800.0, attack=0.08, hold=0.55):
    """BRASS colour: the ceremonial cues and the raid. A detuned saw stack
    through a filter that OPENS - the opening is the whole gesture, and it
    is why this reads as ceremony rather than as a pad."""
    y = S.supersaw(dur, f, voices=5, detune=0.0075, phase_seed=r)
    y = S.moog(y, S.breakpoints(dur, [(0.0, 380.0), (dur * 0.45, open_to),
                                      (dur, open_to * 0.35)]), res=0.34)
    y *= S.breakpoints(dur, [(0.0, 0.0), (attack, 1.0), (dur * hold, 0.82), (dur, 0.0)],
                       curve="exp")
    return S.saturate(y * 0.4, 1.7) * level


# ---------------------------------------------------------------------------
# the small, constant rewards
# ---------------------------------------------------------------------------

@cue("coinGain")
def coin_gain(r):
    """A bright coin chime. Two coins, 55 ms apart, up a fourth - two,
    because a single bell reads as a UI ping and a pair reads as money
    landing on money. 90 ms of body; this fires several times a second when
    a haul is counted, so it cannot be longer."""
    dur = 0.34
    out = S.silence(dur)
    out = S.place(out, _coin(r, D6, 0.24, 0.95), 0.0)
    out = S.place(out, _coin(r, G6, 0.26, 0.80), 0.055)
    out = S.place(out, _sparkle(r, 0.22, count=3, base=3136.0, spread=0.9,
                                level=0.10, start=0.05, over=0.10), 0.03)
    return _hall(out * 0.85, size=0.45, mix=0.13)


@cue("xpGain")
def xp_gain(r):
    """Experience: WOOD, not metal - XP is progress, coins are wealth, and
    keeping the two timbres apart is what lets a player hear which one they
    just got when both fire together. A single rising fourth, D5 -> G5."""
    dur = 0.28
    out = S.silence(dur)
    out = S.place(out, _wood_note(r, D5, 0.20, 0.075, 0.75), 0.0)
    out = S.place(out, _wood_note(r, G5, 0.22, 0.085, 0.85), 0.048)
    return _hall(out * 0.8, size=0.4, mix=0.12)


@cue("materialGain")
def material_gain(r):
    """Raw material picked up: a low wooden knock with a soft rattle after
    it - the sound of something going into a bag. Deliberately the DULLEST
    positive cue on the sheet; materials are constant and must not celebrate."""
    dur = 0.34
    out = S.silence(dur)
    out = S.place(out, _wood_note(r, G4, 0.22, 0.060, 0.85, strike=0.35), 0.0)
    out = S.place(out, _wood_note(r, B4, 0.18, 0.045, 0.35, strike=0.3), 0.030)
    rattle = S.silence(0.22)
    for _ in range(7):
        g = S.band_noise(0.005, r, 900.0, 6500.0) * S.perc_env(0.005, 0.0003, 0.0014)
        rattle = S.place(rattle, g * (0.2 + 0.5 * float(r.random())),
                         0.03 + float(r.random()) * 0.14)
    out = S.mix(out, S.fit(rattle, dur) * 0.5)
    return _hall(S.lowpass(out, 5200.0, order=2) * 0.85, size=0.4, mix=0.11)


@cue("baitGain")
def bait_gain(r):
    """Bait: the wet cousin of `materialGain` - the same wooden knock with a
    small squelch instead of a rattle, a semitone-ish lower. Bait is the one
    consumable the player handles constantly, so it gets its own texture."""
    dur = 0.30
    out = S.silence(dur)
    out = S.place(out, _wood_note(r, D4 * 1.5, 0.20, 0.055, 0.7, strike=0.3), 0.0)
    wet = S.band_noise(0.09, r, 400.0, 3800.0, order=2)
    wet = S.lp_sweep(wet, S.expsweep(0.09, 3200.0, 500.0), order=2)
    wet *= S.perc_env(0.09, 0.0015, 0.020, curve=1.3)
    out = S.place(out, wet * 0.45, 0.010)
    out = S.place(out, S.bubble(0.05, 320.0, r, rise=2.6) * 0.20, 0.035)
    return _hall(S.lowpass(out, 4200.0, order=2) * 0.85, size=0.4, mix=0.11)


@cue("itemDrop")
def item_drop(r):
    """A rare drop: SPARKLE. A soft rising bed of air, then eight small high
    bells scattered across half a second, then one clear bell at D7 landing
    on top. No low end at all - the cue is entirely above 1 kHz, which is
    what makes it read as 'something glittering appeared' rather than as
    'something fell'."""
    dur = 1.0
    out = S.silence(dur)
    rise = S.bp_sweep(S.white(0.35, r), S.expsweep(0.35, 2000.0, 9000.0), q=2.2)
    rise *= S.breakpoints(0.35, [(0.0, 0.0), (0.28, 1.0), (0.35, 0.3)], curve="exp")
    out = S.place(out, rise * 0.20, 0.0)
    out = S.place(out, _sparkle(r, 0.8, count=10, base=2349.0, spread=1.4,
                                level=0.15, start=0.06, over=0.42), 0.0)
    out = S.place(out, S.bell(0.6, D7, r, decay=0.30, strike=0.7, inharmonic=1.1) * 0.35, 0.26)
    out = S.place(out, S.bell(0.5, B6, r, decay=0.24, strike=0.5) * 0.22, 0.30)
    out = S.place(out, _shimmer(r, 0.5, 6000.0, 15000.0, 0.16, attack=0.12), 0.22)
    return _hall(S.highpass(out, 700.0, order=2) * 0.85, size=0.8, damping=0.35, mix=0.24)


# ---------------------------------------------------------------------------
# the ceremonial cues
# ---------------------------------------------------------------------------

@cue("levelUp")
def level_up(r):
    """A genuine 2 s fanfare, in three movements exactly as the contract
    asks - and the order matters, because each one hands over to the next:

      0.00  CHORD STAB. A wide G major struck across four octaves on bells,
            with a saturated low G under it to seat the whole thing.
      0.30  RISING ARPEGGIO. G B D G B D G climbing two octaves, each note
            a little louder than the last so the line pulls upward.
      0.35  BRASS answering underneath - the filter opening is what makes it
            feel like an announcement rather than a chime.
      0.55  SHIMMER, with a slow 0.5 s attack so it arrives under the top of
            the arpeggio instead of competing with the stab.
      1.10  A scatter of high sparkles, which is the only part that is
            allowed to be irregular; everything before it is on the grid.
    """
    dur = 2.0
    out = S.silence(dur)

    # 1. the stab
    for f in (G3, D4, G4, B4, D5, G5, B5):
        out = S.place(out, S.bell(1.5, f, r, decay=0.85, strike=0.6) * 0.24, 0.0)
    low = S.sine(1.6, S.expsweep(1.6, 146.83, 97.99)) * S.perc_env(1.6, 0.003, 0.34)
    out = S.mix(out, S.fit(S.saturate(low * 0.6, 2.1) * 0.5, dur))
    out = S.place(out, S.band_noise(0.008, r, 2000.0, 14000.0)
                  * S.perc_env(0.008, 0.0002, 0.002) * 0.30, 0.0)

    # 2. the arpeggio
    for i, f in enumerate((G4, B4, D5, G5, B5, D6, G6)):
        v = S.bell(0.85, f, r, decay=0.38, strike=0.75, inharmonic=0.55)
        out = S.place(out, v * (0.28 + 0.045 * i), 0.30 + i * 0.080)

    # 3. the brass answering
    out = S.place(out, _brass(r, 1.05, G3, level=0.85, open_to=2900.0,
                              attack=0.30, hold=0.72), 0.35)

    # 4. shimmer and sparkle
    out = S.place(out, _shimmer(r, 1.25, 4000.0, 15000.0, 0.20, attack=0.50), 0.55)
    out = S.place(out, _sparkle(r, 0.85, count=8, base=2349.0, spread=1.2,
                                level=0.11, start=0.0, over=0.55), 1.10)
    return _hall(out * 0.72, size=1.1, damping=0.38, mix=0.27)


@cue("islandUnlock")
def island_unlock(r):
    """A big warm chord with a slow HEARTBEAT pulse under it - the contract's
    brief, taken literally.

    The chord is Gmaj9 on brass and bells, entered with a 0.35 s attack (a
    struck chord would make this a fanfare, and `levelUp` is already the
    fanfare). The heartbeat is three lub-dub pairs at 52/61 Hz, on the beat
    at 0.10 / 0.85 / 1.60 s - slow enough to feel like a place waking up
    rather than a rhythm. The pulses are UNDER the chord in level; you feel
    them in the chest rather than hear them, which is the whole idea.
    """
    dur = 2.4
    out = S.silence(dur)

    for f in (G3, D4, G4, B4, D5, A5):
        out = S.place(out, S.bell(2.0, f, r, decay=1.1, strike=0.30) * 0.20, 0.02)
    out = S.place(out, _brass(r, 2.0, G3, level=1.0, open_to=2200.0,
                              attack=0.35, hold=0.70), 0.0)
    out = S.place(out, _brass(r, 1.7, D4, level=0.5, open_to=2600.0,
                              attack=0.45, hold=0.68), 0.10)

    # the heartbeat: lub-dub, three times, slow
    for beat in (0.10, 0.85, 1.60):
        for off, f, amp, tau in ((0.0, 52.0, 1.0, 0.090), (0.30, 61.0, 0.6, 0.065)):
            p = S.sine(0.32, S.expsweep(0.32, f * 1.6, f * 0.9))
            p *= S.perc_env(0.32, 0.005, tau, curve=1.4)
            out = S.place(out, S.saturate(p, 2.6) * 0.55 * amp, beat + off)

    out = S.place(out, _shimmer(r, 1.4, 3000.0, 12000.0, 0.16, attack=0.70), 0.35)
    out = S.place(out, _sparkle(r, 1.0, count=7, base=1976.0, spread=1.2,
                                level=0.10, start=0.0, over=0.7), 1.10)
    return _hall(out * 0.75, size=1.05, damping=0.42, mix=0.27)


@cue("heartsAll")
def hearts_all(r):
    """Every heart on an island filled: a short, very high, very sweet
    confirmation - a G major triad in the top octave on glass bells, with a
    single low G an octave and a half below to give it a floor. Short (1.1 s)
    on purpose: `islandUnlock` is the big one, and this must not upstage it."""
    dur = 1.1
    out = S.silence(dur)
    for i, f in enumerate((G5, B5, D6, G6)):
        out = S.place(out, S.bell(0.85, f, r, decay=0.42, strike=0.55,
                                  inharmonic=0.9) * (0.30 - 0.03 * i), i * 0.035)
    out = S.place(out, S.bell(0.9, G3, r, decay=0.5, strike=0.35) * 0.22, 0.0)
    out = S.place(out, _sparkle(r, 0.7, count=6, base=2637.0, spread=1.0,
                                level=0.11, start=0.06, over=0.32), 0.0)
    out = S.place(out, _shimmer(r, 0.6, 5000.0, 14000.0, 0.15, attack=0.15), 0.10)
    return _hall(out * 0.8, size=0.9, damping=0.35, mix=0.24)


@cue("collectionComplete")
def collection_complete(r):
    """A whole collection finished: WOOD and metal together, which happens
    nowhere else on the sheet - a wooden run up the triad (the bestiary
    closing) answered by a bell chord (the reward). A 1.4 s cue that lands
    between the small pickups and the ceremonial pair."""
    dur = 1.4
    out = S.silence(dur)
    for i, f in enumerate((G4, B4, D5, G5)):
        out = S.place(out, _wood_note(r, f, 0.40, 0.16, 0.55 + 0.06 * i), i * 0.070)
    for i, f in enumerate((D5, G5, B5, D6)):
        out = S.place(out, S.bell(0.9, f, r, decay=0.45, strike=0.5) * 0.22,
                      0.36 + i * 0.020)
    out = S.place(out, _shimmer(r, 0.8, 4000.0, 12000.0, 0.16, attack=0.25), 0.34)
    out = S.place(out, _sparkle(r, 0.7, count=5, base=2349.0, spread=1.0,
                                level=0.10, start=0.05, over=0.35), 0.45)
    return _hall(out * 0.8, size=0.95, damping=0.4, mix=0.24)


@cue("newSpecies")
def new_species(r):
    """A bestiary page turn plus chime. The page is a real gesture: a
    2-3 kHz noise sweep that RISES then falls in about 120 ms (paper lifting
    and settling), with a small flick of grains at the end. The chime after
    it is wooden, because the bestiary is a book."""
    dur = 0.95
    out = S.silence(dur)
    page = S.bp_sweep(S.white(0.16, r), S.breakpoints(0.16, [(0.0, 1400.0),
                                                             (0.07, 4200.0),
                                                             (0.16, 1800.0)], curve="exp"),
                      q=1.4)
    page *= S.breakpoints(0.16, [(0.0, 0.0), (0.02, 0.8), (0.075, 1.0), (0.16, 0.0)],
                          curve="exp")
    out = S.place(out, page * 0.55, 0.0)
    for _ in range(6):
        g = S.band_noise(0.004, r, 1800.0, 9000.0) * S.perc_env(0.004, 0.0002, 0.0010)
        out = S.place(out, g * 0.18 * (0.4 + 0.6 * float(r.random())),
                      0.10 + float(r.random()) * 0.07)
    for i, f in enumerate((G5, D6)):
        out = S.place(out, _wood_note(r, f, 0.45, 0.20, 0.7 - 0.05 * i), 0.20 + i * 0.070)
    out = S.place(out, S.bell(0.55, G6, r, decay=0.26, strike=0.5) * 0.22, 0.275)
    out = S.place(out, _shimmer(r, 0.45, 5000.0, 13000.0, 0.13, attack=0.10), 0.26)
    return _hall(out * 0.85, size=0.7, damping=0.45, mix=0.20)


# ---------------------------------------------------------------------------
# quests - all WOOD, one family, four sizes
# ---------------------------------------------------------------------------

@cue("questTick")
def quest_tick(r):
    """One objective step (3/5 fish caught): the smallest wooden cue there
    is. One note, B4, 70 ms. It fires on every increment, so it is barely a
    sound - just enough to confirm the counter moved."""
    dur = 0.16
    out = _wood_note(r, B4, 0.14, 0.040, 0.85, strike=0.5)
    return _hall(S.fit(out, dur) * 0.8, size=0.35, mix=0.10)


@cue("questReady")
def quest_ready(r):
    """The objective is complete and can be handed in: `questTick`'s note
    with the fifth above it added, and a soft chime - the same event, one
    step bigger. That containment is the family: tick < ready < accept <
    complete, each one adding a layer rather than changing instrument."""
    dur = 0.42
    out = S.silence(dur)
    out = S.place(out, _wood_note(r, B4, 0.26, 0.10, 0.7), 0.0)
    out = S.place(out, _wood_note(r, G5, 0.30, 0.12, 0.75), 0.055)      # the fifth above
    out = S.place(out, S.bell(0.34, D6, r, decay=0.16, strike=0.45) * 0.18, 0.06)
    return _hall(out * 0.8, size=0.5, mix=0.14)


@cue("questAccept")
def quest_accept(r):
    """A quest is taken on: a wooden rise G4 -> B4 -> D5, warm and
    unhurried, with a low G under it. Rising but NOT triumphant - accepting
    work is a beginning, and it must not sound like the reward for finishing
    it (`questComplete`), which is the same shape an octave higher plus a
    chime."""
    dur = 0.6
    out = S.silence(dur)
    for i, f in enumerate((G4, B4, D5)):
        out = S.place(out, _wood_note(r, f, 0.34, 0.14, 0.62 + 0.06 * i), i * 0.075)
    out = S.place(out, _wood_note(r, G3, 0.40, 0.18, 0.35, strike=0.3), 0.0)
    return _hall(out * 0.8, size=0.55, mix=0.16)


@cue("questComplete")
def quest_complete(r):
    """Handed in: `questAccept` an octave up, faster, with a bell chord and
    a shimmer landing on the last note. The biggest wooden cue on the
    sheet - but still wood, so it never competes with `levelUp`."""
    dur = 0.95
    out = S.silence(dur)
    for i, f in enumerate((G5, B5, D6, G6)):
        out = S.place(out, _wood_note(r, f, 0.40, 0.17, 0.55 + 0.06 * i), i * 0.060)
    for i, f in enumerate((D6, G6, B6)):
        out = S.place(out, S.bell(0.55, f, r, decay=0.26, strike=0.5) * 0.16,
                      0.18 + i * 0.025)
    out = S.place(out, _shimmer(r, 0.55, 4500.0, 13000.0, 0.15, attack=0.14), 0.16)
    return _hall(out * 0.8, size=0.75, damping=0.42, mix=0.21)


# ---------------------------------------------------------------------------
# travel
# ---------------------------------------------------------------------------

@cue("travelGo")
def travel_go(r):
    """Leaving for another island: a departing gesture - a rising brass
    swell with a wind-like band opening under it, then the sound moving away
    (the low-pass closes over the last 300 ms, which is distance). It ends
    quieter than it started; nothing else on the sheet does."""
    dur = 1.2
    out = S.silence(dur)
    out = S.place(out, _brass(r, 0.85, D4, level=0.85, open_to=3000.0,
                              attack=0.20, hold=0.60), 0.0)
    for i, f in enumerate((D5, G5, B5)):
        out = S.place(out, S.bell(0.6, f, r, decay=0.28, strike=0.5)
                      * (0.22 - 0.03 * i), 0.10 + i * 0.055)
    rush = S.band_noise(0.9, r, 250.0, 7000.0, order=2)
    rush = S.lp_sweep(rush, S.breakpoints(0.9, [(0.0, 900.0), (0.35, 6500.0),
                                                (0.9, 700.0)], curve="exp"), order=2)
    rush *= S.breakpoints(0.9, [(0.0, 0.0), (0.30, 0.9), (0.6, 0.5), (0.9, 0.0)],
                          curve="exp")
    out = S.place(out, rush * 0.28, 0.06)
    return _hall(out * 0.85, size=1.0, damping=0.45, mix=0.24)


@cue("travelArrive")
def travel_arrive(r):
    """Landing somewhere new: the inverse - it comes IN from a distance (the
    filter opens), lands on a G major chord, and a small surf wash settles
    behind it. Paired with `travelGo` deliberately: the two are one journey,
    and the arriving chord is the tonic that `travelGo` left on the fifth."""
    dur = 1.3
    out = S.silence(dur)
    approach = S.band_noise(0.55, r, 250.0, 8000.0, order=2)
    approach = S.lp_sweep(approach, S.expsweep(0.55, 700.0, 7000.0), order=2)
    approach *= S.breakpoints(0.55, [(0.0, 0.0), (0.48, 1.0), (0.55, 0.4)], curve="exp")
    out = S.place(out, approach * 0.26, 0.0)
    for i, f in enumerate((G3, D4, G4, B4, D5)):
        out = S.place(out, S.bell(0.9, f, r, decay=0.5, strike=0.5)
                      * (0.24 - 0.02 * i), 0.45 + i * 0.012)
    out = S.place(out, _brass(r, 0.7, G3, level=0.55, open_to=2000.0,
                              attack=0.12, hold=0.6), 0.45)
    wash = S.band_noise(0.6, r, 300.0, 4000.0, order=2)
    wash = S.lp_sweep(wash, S.expsweep(0.6, 3600.0, 800.0), order=2)
    wash *= S.breakpoints(0.6, [(0.0, 0.0), (0.05, 0.8), (0.6, 0.0)])
    out = S.place(out, wash * 0.22, 0.44)
    return _hall(out * 0.85, size=1.0, damping=0.45, mix=0.24)


@cue("travelRefused")
def travel_refused(r):
    """You cannot go there yet. G MINOR - the Bb is the only note outside
    the sheet's key, exactly as `uiError`'s F natural is on the UI sheet,
    and for the same reason: one wrong note says no better than any amount
    of dissonance. Two notes falling, damped, with a dead low thud."""
    dur = 0.55
    out = S.silence(dur)
    out = S.place(out, _wood_note(r, D5, 0.30, 0.11, 0.85, strike=0.4), 0.0)
    out = S.place(out, _wood_note(r, Bb4, 0.34, 0.13, 0.80, strike=0.4), 0.105)
    thud = S.sine(0.26, S.expsweep(0.26, 130.0, 58.0)) * S.perc_env(0.26, 0.003, 0.055)
    out = S.mix(out, S.fit(S.saturate(thud * 0.6, 2.2), dur))
    return _hall(S.lowpass(out, 2600.0, order=2) * 0.85, size=0.5, mix=0.14)


# ---------------------------------------------------------------------------
# the raid - all four cues MARTIAL: drum, brass, no bells
# ---------------------------------------------------------------------------

def _drum(r, dur, f, tau, level=1.0, noise=0.30):
    """A war drum. The raid cues are the only place on the sheet with a
    struck skin, and there are no bells anywhere in them - that is what
    makes the raid sound like a different kind of event from a reward."""
    y = S.membrane(dur, f, r, drop=0.55, noise=noise, tau=tau)
    return S.saturate(y, 2.6) * level


@cue("raidStart")
def raid_start(r):
    """The raid begins: three war-drum hits accelerating into a brass call.
    Martial, in G minor-ish colour (the brass is on G with a bare fifth, no
    third at all, which is the oldest 'this is not a celebration' trick
    there is)."""
    dur = 1.6
    out = S.silence(dur)
    for at, amp in ((0.0, 1.0), (0.26, 0.95), (0.46, 1.0), (0.60, 0.8)):
        out = S.place(out, _drum(r, 0.34, 62.0, 0.075, amp), at)
        out = S.place(out, S.band_noise(0.05, r, 200.0, 2600.0, order=2)
                      * S.perc_env(0.05, 0.0008, 0.012) * 0.25 * amp, at)
    out = S.place(out, _brass(r, 0.85, G3, level=1.0, open_to=3200.0,
                              attack=0.10, hold=0.65), 0.62)
    out = S.place(out, _brass(r, 0.80, D4, level=0.6, open_to=3400.0,
                              attack=0.14, hold=0.62), 0.66)
    return _hall(out * 0.8, size=1.1, damping=0.45, mix=0.24)


@cue("raidWave")
def raid_wave(r):
    """The next wave is coming: two drum hits and a SHORT rising brass
    figure - a fragment of `raidStart`, which is what makes a wave feel like
    a continuation of the same fight rather than a new one."""
    dur = 0.9
    out = S.silence(dur)
    for at, amp in ((0.0, 1.0), (0.18, 0.85)):
        out = S.place(out, _drum(r, 0.28, 70.0, 0.060, amp), at)
    out = S.place(out, _brass(r, 0.55, D4, level=0.85, open_to=3000.0,
                              attack=0.06, hold=0.55), 0.22)
    out = S.place(out, S.band_noise(0.10, r, 1500.0, 8000.0, order=2)
                  * S.perc_env(0.10, 0.002, 0.022) * 0.20, 0.22)
    return _hall(out * 0.8, size=0.9, damping=0.5, mix=0.20)


@cue("raidClear")
def raid_clear(r):
    """The raid is beaten: the martial material RESOLVING - a drum roll that
    stops dead on a full G major brass chord. This is the only raid cue with
    a major third in it, and that arrival is the reward."""
    dur = 1.7
    out = S.silence(dur)
    at = 0.0
    gap = 0.075
    while at < 0.42:
        out = S.place(out, _drum(r, 0.16, 78.0, 0.028, 0.45 + 0.55 * (at / 0.42), noise=0.4), at)
        at += gap
        gap = max(0.030, gap * 0.86)
    out = S.place(out, _drum(r, 0.45, 55.0, 0.10, 1.0), 0.44)
    for i, f in enumerate((G3, D4, G4, B4, D5)):
        out = S.place(out, _brass(r, 1.0, f, level=0.55 - 0.06 * i, open_to=3000.0,
                                  attack=0.05, hold=0.60), 0.44 + i * 0.008)
    out = S.place(out, _shimmer(r, 0.8, 3500.0, 12000.0, 0.16, attack=0.30), 0.50)
    return _hall(out * 0.78, size=1.2, damping=0.40, mix=0.26)


@cue("raidFail")
def raid_fail(r):
    """The raid is lost: the same brass, but the filter CLOSES instead of
    opening and the chord falls to G minor over a drum that slows down. It
    is the only cue on the sheet that ends lower and darker than it began."""
    dur = 1.8
    out = S.silence(dur)
    at = 0.0
    gap = 0.13
    while at < 1.0:
        out = S.place(out, _drum(r, 0.30, 58.0, 0.070, 0.9 - 0.5 * at), at)
        at += gap
        gap *= 1.28                       # slowing - the line is breaking
    fall = S.supersaw(1.3, G3, voices=5, detune=0.009, phase_seed=r)
    fall = S.moog(fall, S.breakpoints(1.3, [(0.0, 2400.0), (1.3, 240.0)]), res=0.36)
    fall *= S.breakpoints(1.3, [(0.0, 0.0), (0.10, 1.0), (0.8, 0.55), (1.3, 0.0)],
                          curve="exp")
    out = S.place(out, S.saturate(fall * 0.42, 1.8), 0.05)
    for f in (Bb3, D4):                   # the minor third arriving
        out = S.place(out, S.bell(1.0, f, r, decay=0.55, strike=0.35) * 0.18, 0.35)
    sub = S.sine(1.1, S.expsweep(1.1, 88.0, 33.0)) * S.perc_env(1.1, 0.010, 0.28)
    out = S.place(out, S.saturate(sub * 0.6, 2.4), 0.30)
    return _hall(S.lowpass(out * 0.8, 4200.0, order=2), size=1.2, damping=0.55, mix=0.24)
