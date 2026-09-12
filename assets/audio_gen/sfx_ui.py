"""sfx_ui.py - the `ui` sheet. Twenty cues, ONE instrument.

THE RULE THAT MAKES A UI FEEL DESIGNED: every cue on this sheet is the same
voice at a different pitch, length and count. `_v()` below is that voice - a
3.5:1 FM pair with a fast-decaying index (bright attack, glassy tail) plus a
struck bar for the wooden knock underneath. Nothing else generates a pitch
on this sheet. Change `_v` and the whole interface changes together, which
is the point.

PITCH IS THE VOCABULARY, not timbre:

    up          affirmative      select, buy, craft success, open, lock
    down        negative         error, fail, close, free
    flat/single neutral          click, hover, tab, blip
    high        small/fast       hover (A6), click (D6)
    low         large/final      dialog, craft fail (D4-A4)

Everything is in D major pentatonic (D E F# A B) so that two cues landing
together - a click while a notification arrives - are consonant. The two
FAILURE cues are the deliberate exception: `uiError` falls a minor third to
F natural, which is the one note NOT in the scale, and that single wrong
note is what the ear reads as "no". Harshness is not needed and is worse -
a player hears this cue every time they misclick.

LENGTH AND ROOM. UI is 2D, in the player's ears, in front of everything.
Cues are 40-450 ms and the reverb is tiny (mix <= 0.06) or absent; only
`notify` and `craftSuccess` get any space at all, because they are events
rather than feedback. A UI click with a room on it sounds like it happened
somewhere else, which is exactly wrong for a button.
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

# D major pentatonic, four octaves. Named so the intervals below are readable.
D4, E4, Fs4, A4, B4 = 293.66, 329.63, 369.99, 440.0, 493.88
D5, E5, Fs5, A5, B5 = 587.33, 659.25, 739.99, 880.0, 987.77
D6, E6, Fs6, A6, B6 = 1174.66, 1318.51, 1479.98, 1760.0, 1975.53
F5 = 698.46          # the one note outside the scale - reserved for `uiError`


def _v(dur, freq, r, decay=None, bright=1.0, knock=0.35, level=1.0):
    """THE UI VOICE. FM glass over a struck bar.

    The FM index falls from `6 * bright` to nearly nothing in 25 ms, which
    is what gives every cue the same 'tick' of brightness on the attack; the
    bar underneath supplies the wooden body so the voice is not glassy all
    the way down. `knock` is how much of that body you want - high for the
    low register (where pure FM sounds thin), low for the top octave (where
    the bar's partials get shrill).
    """
    decay = decay or max(0.020, dur * 0.42)
    idx_env = S.breakpoints(dur, [(0.0, 1.0), (0.006, 0.85), (0.025, 0.22), (dur, 0.05)],
                            curve="exp")
    glass = S.fm(dur, freq, ratio=3.5, index=6.0 * bright, index_env=idx_env)
    glass *= S.perc_env(dur, 0.0012, decay, curve=1.15)
    body = S.bar(dur, freq, r, decay=decay * 1.1, strike=0.45) * knock
    return S.mix(glass * 0.85, body) * level


def _tick(r, level=0.25, low=2600.0, high=12000.0, dur=0.0018):
    """The mechanical edge of a button: sub-2 ms of band noise. It carries
    no pitch, so it can be added to any cue without joining the harmony."""
    return S.band_noise(dur, r, low, high) * S.perc_env(dur, 0.0001, dur * 0.3) * level


def _tiny(x, mix=0.05, size=0.20):
    """A room so small it only removes the dryness. See the header."""
    return _lead(S.reverb(x, size=size, damping=0.55, mix=mix, seed=61))


def _seq(r, dur, notes, level=1.0, **kw):
    """`notes` is [(at, freq, amp), ...]. Every multi-note UI cue is built
    from this, so gesture is the only thing that varies between them."""
    out = S.silence(dur)
    for at, f, amp in notes:
        out = S.place(out, _v(min(0.45, dur - at), f, r, level=amp, **kw), at)
    return out * level


# ---------------------------------------------------------------------------
# feedback - the cues a player hears hundreds of times an hour
# ---------------------------------------------------------------------------

@cue("uiHover")
def ui_hover(r):
    """The smallest thing on the sheet: one note at A6, 40 ms, quiet. It
    fires on every pointer move across a grid, so any length or any low end
    at all would turn a shop into a machine gun."""
    dur = 0.05
    return _lead(S.mix(_v(dur, A6, r, decay=0.014, bright=0.6, knock=0.10,
                           level=0.55), S.fit(_tick(r, 0.12), dur)))


@cue("uiClick")
def ui_click(r):
    """The button. One note at D6 - an octave below hover, so hovering then
    clicking is a step DOWN into commitment - with the mechanical tick in
    front of it. 70 ms, dry."""
    dur = 0.09
    return _tiny(S.mix(_v(dur, D6, r, decay=0.030, bright=1.0, knock=0.30),
                       S.fit(_tick(r, 0.30), dur)), mix=0.04)


@cue("uiTab")
def ui_tab(r):
    """Switching tabs: two notes a fourth apart, FLAT in gesture (A5 then
    B5, barely up) because changing tab is lateral movement, not progress.
    Fast enough to read as one event."""
    dur = 0.16
    return _tiny(_seq(r, dur, [(0.0, A5, 0.75), (0.045, B5, 0.85)],
                      decay=0.035, knock=0.25), mix=0.04)


@cue("uiSelect")
def ui_select(r):
    """Choosing a thing: two notes UP a fifth, D6 -> A6. Same interval as
    `uiTab` inverted in direction, and one octave higher, so select is
    unmistakably the affirmative of the pair."""
    dur = 0.22
    out = _seq(r, dur, [(0.0, D6, 0.85), (0.055, A6, 0.9)], decay=0.045, knock=0.20)
    return _tiny(S.mix(out, S.fit(_tick(r, 0.20), dur)), mix=0.05)


@cue("uiOpen")
def ui_open(r):
    """A panel arrives: three notes up the pentatonic (D5 A5 D6) with a
    short breath of air rising underneath. Long enough (280 ms) to feel like
    a thing appearing rather than a button being pressed."""
    dur = 0.30
    out = _seq(r, dur, [(0.0, D5, 0.7), (0.045, A5, 0.75), (0.090, D6, 0.85)],
               decay=0.075, knock=0.30)
    air = S.bp_sweep(S.white(0.16, r), S.expsweep(0.16, 2200.0, 7000.0), q=2.2)
    air *= S.breakpoints(0.16, [(0.0, 0.0), (0.03, 1.0), (0.16, 0.0)], curve="exp")
    return _tiny(S.mix(out, S.fit(air, dur) * 0.14), mix=0.06, size=0.28)


@cue("uiClose")
def ui_close(r):
    """The exact retrograde of `uiOpen` - the same three notes in reverse,
    damped shorter and with the air falling. A close that is not the mirror
    of its open always feels like a different panel."""
    dur = 0.24
    out = _seq(r, dur, [(0.0, D6, 0.7), (0.045, A5, 0.65), (0.085, D5, 0.7)],
               decay=0.050, knock=0.35)
    air = S.bp_sweep(S.white(0.14, r), S.expsweep(0.14, 6000.0, 1800.0), q=2.2)
    air *= S.breakpoints(0.14, [(0.0, 0.0), (0.02, 1.0), (0.14, 0.0)], curve="exp")
    return _tiny(S.mix(out, S.fit(air, dur) * 0.12), mix=0.04)


@cue("uiEquip")
def ui_equip(r):
    """Equipping: a satisfying CLACK plus SHIMMER. The clack is two hard
    transients 12 ms apart (a thing seating into a slot never makes one
    sound) over a low bar at D4, and the shimmer is a rising band of air
    with three bells scattered in the top octave. The pitched note is D6, so
    it belongs to the family - but the weight is all in the noise layers,
    which is what makes it feel physical instead of musical."""
    dur = 0.42
    out = S.silence(dur)
    out = S.place(out, _tick(r, 0.55, 1400.0, 9000.0, 0.0025), 0.0)
    out = S.place(out, _tick(r, 0.34, 2600.0, 13000.0, 0.0018), 0.012)
    out = S.place(out, S.metal_hit(0.13, r, 880.0, ring=0.12, roughness=0.6) * 0.40, 0.0)
    out = S.place(out, _v(0.28, D4, r, decay=0.055, bright=0.7, knock=0.85, level=0.55), 0.0)
    out = S.place(out, _v(0.30, D6, r, decay=0.085, bright=1.1, knock=0.20, level=0.60), 0.014)
    shim = S.bp_sweep(S.white(0.24, r), S.expsweep(0.24, 4000.0, 12000.0), q=1.8)
    shim *= S.breakpoints(0.24, [(0.0, 0.0), (0.05, 1.0), (0.24, 0.0)], curve="exp")
    out = S.place(out, shim * 0.20, 0.05)
    for i, f in enumerate((A6, D6 * 2.0, Fs6)):
        out = S.place(out, S.bell(0.20, f, r, decay=0.085, strike=0.5) * 0.11,
                      0.09 + i * 0.045)
    return _tiny(out, mix=0.06, size=0.26)


@cue("uiError")
def ui_error(r):
    """A soft two-note DOWN: A5 -> F5. F natural is the only note on this
    sheet outside D major pentatonic, and that one wrong note is the whole
    message - see the header. Low-passed to 2.6 kHz so it is soft; a player
    hears this every time they misclick and it must not sting."""
    dur = 0.34
    out = _seq(r, dur, [(0.0, A5, 0.85), (0.085, F5, 0.80)],
               decay=0.090, bright=0.55, knock=0.55)
    return _tiny(S.lowpass(out, 2600.0, order=2) * 0.9, mix=0.05)


# ---------------------------------------------------------------------------
# transactions
# ---------------------------------------------------------------------------

@cue("craftSuccess")
def craft_success(r):
    """Something was made: the full pentatonic run D5 E5 Fs5 A5 D6 with a
    warm shimmer over it. The longest affirmative on the sheet (450 ms) -
    crafting is the biggest thing the UI does."""
    dur = 0.55
    out = _seq(r, dur, [(0.0, D5, 0.6), (0.045, E5, 0.62), (0.085, Fs5, 0.68),
                        (0.125, A5, 0.74), (0.170, D6, 0.9)],
               decay=0.12, knock=0.28)
    for i, f in enumerate((A6, B6)):
        out = S.place(out, S.bell(0.30, f, r, decay=0.14, strike=0.45) * 0.13,
                      0.20 + i * 0.06)
    shim = S.bp_sweep(S.white(0.30, r), S.expsweep(0.30, 3500.0, 11000.0), q=1.8)
    shim *= S.breakpoints(0.30, [(0.0, 0.0), (0.08, 1.0), (0.30, 0.0)], curve="exp")
    out = S.place(out, shim * 0.16, 0.14)
    return _tiny(out, mix=0.08, size=0.35)


@cue("craftFail")
def craft_fail(r):
    """The recipe was refused. Two notes down in the LOW octave (A4 -> D4),
    with a dull knock under them - the same gesture as `uiError` an octave
    and a half lower and with mass, so 'this cannot be built' is clearly a
    bigger no than 'that button does nothing'."""
    dur = 0.42
    out = _seq(r, dur, [(0.0, A4, 0.85), (0.095, D4, 0.85)],
               decay=0.11, bright=0.45, knock=0.9)
    thud = S.sine(0.20, S.expsweep(0.20, 140.0, 62.0)) * S.perc_env(0.20, 0.003, 0.045)
    out = S.mix(out, S.fit(S.saturate(thud * 0.5, 2.0), dur))
    # The 62 Hz tail of that thud sits just above build.py's 18 Hz DC blocker
    # and leaves ~-59 dBFS of offset in the finished cue; 40 Hz here removes
    # it and is inaudible, since nothing in the cue is written below 62 Hz.
    out = S.highpass(S.lowpass(out, 2000.0, order=2), 40.0, order=2)
    return _tiny(out, mix=0.05)


@cue("shopBuy")
def shop_buy(r):
    """A purchase: the affirmative gesture (D5 -> A5 -> D6) with a till in
    it - one metallic tick at the moment of the top note. The till is what
    separates this from `craftSuccess`; the notes are shorter and there is
    no shimmer, because buying is a transaction, not a creation."""
    dur = 0.36
    out = _seq(r, dur, [(0.0, D5, 0.7), (0.055, A5, 0.75), (0.105, D6, 0.85)],
               decay=0.070, knock=0.30)
    out = S.place(out, S.metal_hit(0.14, r, 2100.0, ring=0.30, roughness=0.4) * 0.28, 0.105)
    out = S.place(out, _tick(r, 0.22, 3000.0, 13000.0), 0.108)
    return _tiny(out, mix=0.05)


@cue("shopFail")
def shopFail(r):
    """Cannot afford it: the SAME note twice (A4, A4) rather than a fall.
    A repeated note is the 'nope' gesture - it refuses to go anywhere - and
    it keeps this distinct from both `uiError` (falls a minor third) and
    `craftFail` (falls a fifth with mass)."""
    dur = 0.34
    out = _seq(r, dur, [(0.0, A4, 0.85), (0.105, A4, 0.62)],
               decay=0.070, bright=0.40, knock=0.75)
    return _tiny(S.lowpass(out, 2200.0, order=2), mix=0.04)


@cue("baitCycle")
def bait_cycle(r):
    """Stepping through the bait list: a single flat note at B5 with a hard
    tick, deliberately NEUTRAL - cycling is not progress in either
    direction, and giving it a rising interval would make the last bait feel
    better than the first."""
    dur = 0.11
    out = S.mix(_v(dur, B5, r, decay=0.028, bright=0.8, knock=0.40, level=0.85),
                S.fit(_tick(r, 0.28, 2000.0, 10000.0), dur))
    return _tiny(out, mix=0.04)


# ---------------------------------------------------------------------------
# mode and attention
# ---------------------------------------------------------------------------

@cue("cursorFree")
def cursor_free(r):
    """The mouse is released to the interface: a soft two-note fall (D6 ->
    A5) with air opening out. Quiet - this is a mode change, not an event."""
    dur = 0.20
    out = _seq(r, dur, [(0.0, D6, 0.5), (0.050, A5, 0.55)],
               decay=0.045, bright=0.5, knock=0.20)
    air = S.bp_sweep(S.white(0.12, r), S.expsweep(0.12, 5500.0, 2000.0), q=2.0)
    air *= S.breakpoints(0.12, [(0.0, 0.0), (0.02, 1.0), (0.12, 0.0)], curve="exp")
    return _tiny(S.mix(out, S.fit(air, dur) * 0.10), mix=0.04)


@cue("cursorLock")
def cursor_lock(r):
    """The mouse is taken back by the game: the mirror, A5 -> D6 rising,
    with a tighter tick - locking snaps, freeing sighs."""
    dur = 0.18
    out = _seq(r, dur, [(0.0, A5, 0.5), (0.045, D6, 0.6)],
               decay=0.038, bright=0.7, knock=0.20)
    return _tiny(S.mix(out, S.fit(_tick(r, 0.22, 3400.0, 13000.0), dur)), mix=0.03)


@cue("notify")
def notify(r):
    """Something wants attention. A rising fourth in the TOP octave (D6 ->
    Fs6 -> A6, bell-like and long) with the only real reverb on the sheet.
    Register is doing the work: it is above everything else the UI plays, so
    it cuts through a full panel without being loud."""
    dur = 0.65
    out = _seq(r, dur, [(0.0, D6, 0.55), (0.070, Fs6, 0.60), (0.140, A6, 0.72)],
               decay=0.16, bright=1.1, knock=0.12)
    for i, f in enumerate((A6, D6 * 2.0)):
        out = S.place(out, S.bell(0.45, f, r, decay=0.22, strike=0.4) * 0.14, 0.14 + i * 0.08)
    return _lead(S.reverb(out * 0.9, size=0.5, damping=0.4, mix=0.14, seed=61))


# ---------------------------------------------------------------------------
# dialogue - the low register, so speech never fights the interface
# ---------------------------------------------------------------------------

@cue("dialogOpen")
def dialog_open(r):
    """A conversation starts: a slow warm rise in the LOW octave (D4 -> A4 ->
    D5) over a soft swell. Everything dialogue-related lives an octave or
    two below the interface so a talking NPC never sounds like a button."""
    dur = 0.55
    out = _seq(r, dur, [(0.0, D4, 0.6), (0.075, A4, 0.62), (0.150, D5, 0.7)],
               decay=0.16, bright=0.55, knock=0.65)
    swell = S.band_noise(0.28, r, 180.0, 1600.0, order=2)
    swell *= S.breakpoints(0.28, [(0.0, 0.0), (0.18, 1.0), (0.28, 0.0)], curve="exp")
    out = S.place(out, swell * 0.13, 0.0)
    return _tiny(S.lowpass(out, 5000.0, order=2), mix=0.06, size=0.30)


@cue("dialogBlip")
def dialog_blip(r):
    """One character of text. The client fires this many times a second, so
    it is the shortest and dullest cue in the whole pack: 35 ms, E4, almost
    no brightness, no tick. Anything sharper becomes unbearable in a
    paragraph."""
    dur = 0.045
    return _lead(_v(dur, E4 * 2.0, r, decay=0.012, bright=0.30, knock=0.55,
                    level=0.5))


@cue("dialogChoice")
def dialog_choice(r):
    """A reply is picked: one warm note at A4 with a small confirming fifth
    above it (E5), struck together rather than in sequence. A chord, not a
    gesture - the choice is already made, so nothing needs to move."""
    dur = 0.30
    out = S.mix(_v(0.28, A4, r, decay=0.090, bright=0.6, knock=0.60, level=0.85),
                _v(0.24, E5, r, decay=0.070, bright=0.7, knock=0.30, level=0.45))
    out = S.mix(S.fit(out, dur), S.fit(_tick(r, 0.16, 1800.0, 9000.0), dur))
    return _tiny(out, mix=0.05)


@cue("dialogClose")
def dialog_close(r):
    """The conversation ends: `dialogOpen` reversed and damped, D5 -> A4 ->
    D4, with the swell falling away instead of rising."""
    dur = 0.42
    out = _seq(r, dur, [(0.0, D5, 0.55), (0.065, A4, 0.55), (0.125, D4, 0.62)],
               decay=0.11, bright=0.45, knock=0.70)
    return _tiny(S.lowpass(out, 3600.0, order=2), mix=0.05)
