"""music_bosses.py - the seven boss stem pairs (CONTRACT.md §4).

THESE ARE NOT NOCTURNES. The islands are the calm the player fishes in; a
boss is the moment that stops. Same two-and-a-bit instruments and the same
sampled palette, driven hard: 144-160 BPM, the grand playing an OCTAVE
OSTINATO in its bottom two octaves with the pedal UP so it is articulate
rather than blurred, the string section grinding a suspension over it, brass
stabs and held pedals, choir, and real percussion - FL's orchestral timpani,
a low tom and a crash.

v5 ADDS LAYERS, NOT VOLUME. Each boss keeps its v4 ostinato, chord table
and countermelody exactly; what is new is a synth bass DOUBLING the ostinato
an octave up (§3g `bass_syn`, high-passed at 120 Hz - the grand still owns
the bottom), a synth arp in the drive sections for motion, and a bell voice
chosen per boss: icy glass bells for Rimefang, a saturated saw stack on
Pyrelisk's brass stabs, tubular bells tolling through the Kraken.

TENSION IS HARMONIC, NOT LOUD. Every one of these is built on some
combination of: a chromatic descending bass under a fixed upper voice, a
suspension that is re-struck instead of resolving, a tritone in the
ostinato, and a minor/major shift (the raised third arriving over a minor
ostinato). Nothing here cadences either.

THE TWO STEMS. `low` is the phase-1 read: the ostinato, the strings, and
sparse timpani. `high` is the SAME arrangement plus brass, choir, full
percussion, and an octave-up countermelody in the piano. Same key, tempo,
bar count and grid, mastered identically by `stem_pair`, so the client can
crossfade mid-bar.

EACH BOSS IS ITS ISLAND'S BOSS. The mode and the motif are quoted from the
theme that plays outside the arena:

    boss_brinejaw        D dorian, nautical      152 BPM  58 bars  91.58 s
    boss_old_gnashroot   D dorian, low and wide  144 BPM  54 bars  90.00 s
    boss_rimefang        C minor with a lydian 4 150 BPM  57 bars  91.20 s
    boss_pyrelisk        E phrygian, brass-heavy 156 BPM  59 bars  90.77 s
    boss_noctyss         minor 9ths, then erupts 146 BPM  56 bars  92.05 s
    boss_admiral_wrack   G aeolian/phrygian      154 BPM  59 bars  91.95 s
    boss_kraken          D minor, open fifths    160 BPM  61 bars  91.50 s
"""

import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import music as M  # noqa: E402
import synth as S  # noqa: E402

TAIL = 6.0


class Boss(object):
    """One boss: a shared core (the `low` stem) plus what `high` adds."""

    def __init__(self, key, bpm, bars, tilt=0.0, width=0.42,
                 room=(1.6, 0.70, 0.15, 0.018)):
        self.key = key
        self.bpm = float(bpm)
        self.bars = int(bars)
        self.core = M.Nocturne(key, bpm=bpm, bars=bars, tail=TAIL, lufs=-16.0,
                               tilt=tilt, width=width, sympathetic=0.07,
                               humanise=0.012, spread=0.22, room=room)
        # The high stem's own piano: an octave-up countermelody, its own rng,
        # so adding it does not move a single note of the low stem.
        self.hp = M.PianoPart(bpm=bpm, seed=key + "|hi", humanise=0.014,
                              sympathetic=0.05, spread=0.34, bank="stage")
        self.hi = M.Sequencer(bpm=bpm, beats_per_bar=4, seed=key + "|hi")
        self.room = room

    def b(self, bar, off=0.0):
        return float(bar) * 4.0 + float(off)

    # -- the low stem -------------------------------------------------------

    # NOTE: the outro ostinato of every boss runs to the LAST bar of the
    # piece. A boss that stopped two bars early left `loop_wrap` folding a
    # silent tail into the head, and the loop measured a 224 dB drop at the
    # seam - a hole you hear once a pass.
    def ostinato(self, bar0, nbars, roots, pattern="x.x.xx.x", vel=0.52,
                 octave=True, dur=0.22):
        """The engine. An octave in the piano's bottom two octaves, one
        16-step pattern a bar, the root changing per bar from `roots`."""
        step = 0.5
        for k in range(int(nbars)):
            root = roots[k % len(roots)]
            m = M.midi(root)
            for i, ch in enumerate(pattern.replace(" ", "")):
                if ch == ".":
                    continue
                v = vel if ch == "x" else vel * 0.62
                t = self.b(bar0 + k, i * step)
                self.core.piano.note(t, dur, m, v)
                if octave:
                    self.core.piano.note(t, dur, m + 12, v * 0.80)
        return self

    def bassline(self, bar0, notes, vel=0.46, dur=3.4, label=None):
        """One long low note a bar - the chromatic descents live here."""
        for k, nte in enumerate(notes):
            self.core.piano.note(self.b(bar0 + k), dur, nte, vel)
            if label:
                self.core.harmony[bar0 + k] = label[k] if isinstance(label, list) else label
        return self

    def chords(self, bar0, table, vel=0.34, off=0.0, stagger=0.02):
        """Piano voicings, struck on the bar. `table` is [(bars, [notes], label)]."""
        bar = bar0
        for (nb, notes, label) in table:
            for k in range(int(nb)):
                self.core.block(bar, off, 3.2, notes, vel=vel * (1.0 if k == 0 else 0.8),
                                stagger=stagger, label=label)
                bar += 1
        return bar

    def track(self, instrument, name, **kw):
        return self.core.track(instrument, name, **kw)

    def hi_track(self, instrument, name, **kw):
        tr = M.StereoTrack(self.hi, instrument, name=name, **kw)
        self.hi.tracks.append(tr)
        return tr

    def hi_mel(self, events):
        for (t, d, m, v) in events:
            self.hp.note(t, d, m, v)
        return self

    # -- rendering ----------------------------------------------------------

    def render(self):
        low_stems = self.core.stems(extra=3.0)
        rt, damp, mix, pre = self.room
        hi_dry = self.hp.render(extra_tail=TAIL + 3.0)
        hi_wet = np.stack([S.reverb(hi_dry[:, 0], size=rt, damping=damp, mix=mix,
                                    predelay=pre, seed=11)[:len(hi_dry)],
                           S.reverb(hi_dry[:, 1], size=rt, damping=damp, mix=mix,
                                    predelay=pre, seed=13)[:len(hi_dry)]], axis=1)
        high_stems = dict(low_stems)
        high_stems["hi_piano"] = hi_wet
        for tr in self.hi.tracks:
            high_stems["hi_" + tr.name] = tr.render(extra_tail=TAIL + 3.0)
        low, high = M.stem_pair(low_stems, high_stems, target_lufs=-16.0,
                               peak_db=-1.5, tilt=self.core.tilt)
        span = self.core.loop_seconds + TAIL
        cut = lambda a: np.stack([S.fit(a[:, 0], span), S.fit(a[:, 1], span)], axis=1)
        # fade_in=0: see Nocturne.render - the wrap IS the continuity, and
        # the 12 ms head ramp is itself the seam step.
        low = M.loop_wrap(cut(low), TAIL, fade_in=0.0)
        high = M.loop_wrap(cut(high), TAIL, fade_in=0.0)
        low = S.normalize_lufs(low, -16.0, -1.5)
        high = S.normalize_lufs(high, -16.0, -1.5)
        return low, high


def _synth_bass(b, bar0, nbars, roots, pattern, vel=0.40, high=False, octave=12):
    """`bass_syn` doubling the piano ostinato an octave up. High-passed at
    120 Hz by construction, so it adds edge in the 150-500 Hz band and
    nothing at all underneath the grand."""
    ev = []
    for k in range(int(nbars)):
        root = M.midi(roots[k % len(roots)]) + octave
        for i, ch in enumerate(pattern.replace(" ", "")):
            if ch == ".":
                continue
            ev.append((b.b(bar0 + k, i * 0.5), 0.30, root, vel if ch == "x" else vel * 0.6))
    return _perc(b, "sbass", M.bass_syn, ev, gain=0.34, pan=0.10,
                 reverb=(1.6, 0.74, 0.14, 0.018), high=high)


def _arp(b, name, bar0, nbars, notes, step=0.5, vel=0.26, gain=0.26, pan=-0.22,
         high=True):
    """A slow synth arp under the drive - motion, not a beat."""
    ev = []
    for k in range(int(nbars)):
        for i, nte in enumerate(notes[k % len(notes)]):
            ev.append((b.b(bar0 + k, i * step), step * 1.6, nte,
                       vel * (1.0 - 0.04 * i)))
    return _perc(b, name, M.pluck_syn, ev, gain=gain, pan=pan,
                 reverb=(2.0, 0.68, 0.20, 0.026), high=high)


def _perc(b, name, inst, events, gain, pan=0.0, reverb=(2.0, 0.72, 0.18, 0.026),
          high=False):
    tr = (b.hi_track if high else b.track)(inst, name, gain=gain, pan=pan,
                                          humanise=0.25, reverb=reverb)
    for (t, d, m, v) in events:
        tr.note(t, d, m, v)
    return tr


def _sus(b, name, inst, events, gain, pan=0.0, reverb=(2.2, 0.74, 0.20, 0.030),
         high=False, humanise=0.5):
    tr = (b.hi_track if high else b.track)(inst, name, gain=gain, pan=pan,
                                          humanise=humanise, reverb=reverb)
    for (t, d, m, v) in events:
        tr.note(t, d, m, v)
    return tr


# ===========================================================================
# brinejaw - the cove's serpent. D dorian, nautical. 152 BPM, 58 bars.
# ===========================================================================

def _brinejaw():
    b = Boss("boss_brinejaw", 152.0, 58, tilt=-0.3)
    B = b.b
    # intro: the bass alone, a chromatic walk down to the tonic
    b.bassline(0, ["F2", "E2", "Eb2", "D2"], vel=0.46, label="chromatic descent")
    b.bassline(4, ["D2", "D2", "C2", "D2"], vel=0.48, label="D pedal")
    # the drive
    b.ostinato(8, 16, ["D1", "D1", "C1", "D1", "D1", "Bb0", "C1", "D1"],
               pattern="x.xx.x.x", vel=0.54)
    b.chords(8, [(2, ["A3", "D4", "F4"], "Dm11"), (2, ["G3", "C4", "E4"], "Cmaj9/D"),
                 (2, ["A3", "D4", "G4"], "Dsus4add11"), (2, ["Bb3", "D4", "F4"], "Bbmaj7/D"),
                 (2, ["A3", "C4", "F4"], "Dm7 open"), (2, ["G#3", "C4", "F4"], "D7b5 (tritone)"),
                 (2, ["A3", "D4", "F4"], "Dm11"), (2, ["G3", "B3", "E4"], "G6/9 (dorian IV)")],
             vel=0.30)
    # the break - the ostinato stops, the suspension is re-struck
    b.bassline(24, ["Bb1", "Bb1", "A1", "A1", "F1", "F1", "E1", "E1"], vel=0.42,
               label="break: bVI - V - bIII - chromatic")
    b.chords(24, [(2, ["F3", "Bb3", "D4"], "Bbmaj9"), (2, ["E3", "A3", "C4"], "Am11"),
                  (2, ["F3", "A3", "D4"], "Dm/F"), (2, ["E3", "G#3", "D4"], "E7b9 (major 3rd)")],
             vel=0.32)
    # drive 2
    b.ostinato(32, 16, ["D1", "D1", "C1", "D1", "D1", "Bb0", "G0", "A0"],
               pattern="x.xx.xxx", vel=0.58)
    b.chords(32, [(2, ["A3", "D4", "F4"], "Dm11"), (2, ["G3", "C4", "E4"], "Cmaj9/D"),
                  (2, ["Bb3", "D4", "F4"], "Bbmaj7"), (2, ["A3", "C#4", "F4"], "D(maj7) shift"),
                  (2, ["A3", "D4", "G4"], "Dsus4add11"), (2, ["G3", "B3", "F4"], "G7/6"),
                  (2, ["A3", "D4", "F4"], "Dm11"), (2, ["A3", "Eb4", "G4"], "Ebmaj7/D (bII)")],
             vel=0.34)
    b.ostinato(48, 8, ["D1", "D1", "C1", "Bb0"], pattern="x.x.x.x.", vel=0.50)
    b.bassline(56, ["F2", "D2"], vel=0.44, label="lead-in")

    _sus(b, "strings", M.strings_sec,
         [(B(8 + 2 * k), 7.0, n, 0.42) for k, n in
          enumerate(["D4", "E4", "F4", "D4", "A4", "G4", "F4", "E4"])] +
         [(B(32 + 2 * k), 7.0, n, 0.46) for k, n in
          enumerate(["D4", "E4", "F4", "C#5", "D5", "B4", "A4", "G4"])] +
         [(B(24), 7.0, "Bb4", 0.36), (B(26), 7.0, "A4", 0.34),
          (B(28), 7.0, "F4", 0.34), (B(30), 7.0, "G#4", 0.38)],
         gain=0.55, pan=-0.18)
    _perc(b, "timp", M.timpani_s,
          [(B(8 + 4 * k), 1.6, "D2", 0.60) for k in range(4)] +
          [(B(32 + 4 * k), 1.6, "D2", 0.66) for k in range(4)] +
          [(B(24), 1.8, "Bb1", 0.52), (B(28), 1.8, "F2", 0.52)],
          gain=0.42, pan=0.06)

    # -- what `high` adds
    _sus(b, "brass", M.brass_sec,
         [(B(8 + 2 * k, 0.0), 1.4, n, 0.60) for k, n in
          enumerate(["D3", "C3", "D3", "Bb2", "D3", "G#2", "D3", "G2"])] +
         [(B(32 + 2 * k, 0.0), 3.6, n, 0.66) for k, n in
          enumerate(["D3", "C3", "Bb2", "C#3", "D3", "G2", "D3", "Eb3"])],
         gain=0.42, pan=0.16, high=True)
    _sus(b, "choir", M.choir_ahh,
         [(B(32 + 2 * k), 7.0, n, 0.44) for k, n in
          enumerate(["D4", "C4", "Bb3", "C#4", "D4", "B3", "A3", "G3"])],
         gain=0.34, pan=-0.10, high=True)
    _perc(b, "toms", M.tom_s,
          [(B(8 + k, o), 0.5, "D2", 0.48) for k in range(16) for o in (0.0, 2.5)] +
          [(B(32 + k, o), 0.5, "D2", 0.54) for k in range(16) for o in (0.0, 1.5, 2.5)],
          gain=0.30, pan=-0.12, high=True)
    _perc(b, "crash", M.crash_s,
          [(B(8), 2.4, "C4", 0.50), (B(32), 2.4, "C4", 0.58), (B(48), 2.4, "C4", 0.44)],
          gain=0.26, pan=0.18, high=True)
    b.hi_mel([(B(32 + 2 * k, 1.0), 2.6, n, 0.40) for k, n in
              enumerate(["D5", "F5", "E5", "C#5", "D5", "Bb4", "A4", "G4"])] +
             [(B(40 + 2 * k, 3.0), 1.4, n, 0.36) for k, n in
              enumerate(["A5", "G5", "F5", "E5"])])
    _synth_bass(b, 8, 16, ["D1", "D1", "C1", "D1", "D1", "Bb0", "C1", "D1"],
                "x.xx.x.x", vel=0.38)
    _synth_bass(b, 32, 16, ["D1", "D1", "C1", "D1", "D1", "Bb0", "G0", "A0"],
                "x.xx.xxx", vel=0.42, high=True)
    _arp(b, "arp", 32, 16, [["D4", "F4", "A4", "D5"], ["C4", "E4", "G4", "C5"],
                            ["Bb3", "D4", "F4", "Bb4"], ["A3", "C#4", "E4", "A4"],
                            ["D4", "F4", "A4", "E5"], ["G3", "B3", "D4", "G4"],
                            ["D4", "F4", "A4", "D5"], ["Eb4", "G4", "Bb4", "Eb5"]])
    return b


# ===========================================================================
# old_gnashroot - the fen's root. D dorian, low and wide. 144 BPM, 54 bars.
# ===========================================================================

def _gnashroot():
    b = Boss("boss_old_gnashroot", 144.0, 54, tilt=-1.2)
    B = b.b
    b.bassline(0, ["D2", "D2", "Eb2", "D2"], vel=0.44, label="D + bII grind")
    b.bassline(4, ["C2", "C2", "Bb1", "A1"], vel=0.46, label="stepwise down")
    b.ostinato(8, 16, ["D1", "D1", "Eb1", "D1", "C1", "C1", "Bb0", "A0"],
               pattern="x..xx..x", vel=0.52, dur=0.30)
    b.chords(8, [(2, ["A3", "D4", "G4"], "Dm11"), (2, ["Bb3", "Eb4", "G4"], "Ebmaj7 (bII)"),
                 (2, ["A3", "C4", "F4"], "Dm7"), (2, ["G3", "C4", "E4"], "Cmaj9"),
                 (2, ["A3", "D4", "F4"], "Dm add11"), (2, ["Ab3", "C4", "F4"], "Fm/Ab (borrowed)"),
                 (2, ["G3", "B3", "E4"], "G6/9 (dorian IV)"), (2, ["A3", "D4", "G4"], "Dsus4add11")],
             vel=0.28)
    b.bassline(24, ["Bb1", "A1", "Ab1", "G1", "Gb1", "F1", "E1", "Eb1"], vel=0.44,
               label="chromatic descent, eight bars")
    b.chords(24, [(8, ["D4", "F4", "A4"], "Dm held over the descent")], vel=0.26)
    b.ostinato(32, 16, ["D1", "Eb1", "D1", "C1", "Bb0", "A0", "Ab0", "G0"],
               pattern="x.xxx..x", vel=0.56, dur=0.28)
    b.chords(32, [(2, ["A3", "D4", "G4"], "Dm11"), (2, ["Bb3", "Eb4", "Ab4"], "Ebmaj7#11 (bII)"),
                  (2, ["A3", "C4", "F4"], "Dm7"), (2, ["A3", "C#4", "F#4"], "D major shift"),
                  (2, ["G3", "C4", "F4"], "Gm11"), (2, ["F3", "Bb3", "Eb4"], "Bb quartal"),
                  (2, ["A3", "D4", "F4"], "Dm add11"), (2, ["G#3", "D4", "F4"], "D dim (tritone)")],
             vel=0.32)
    b.ostinato(48, 6, ["D1", "D1", "Eb1", "D1"], pattern="x...x...", vel=0.46, dur=0.40)
    _sus(b, "strings", M.strings_sec_lo,
         [(B(8 + 2 * k), 6.6, n, 0.44) for k, n in
          enumerate(["D3", "Eb3", "C3", "E3", "D3", "F3", "B2", "D3"])] +
         [(B(24 + k), 3.4, n, 0.36) for k, n in
          enumerate(["A3", "A3", "A3", "A3", "A3", "A3", "A3", "A3"])] +
         [(B(32 + 2 * k), 6.6, n, 0.48) for k, n in
          enumerate(["D3", "Eb3", "C3", "F#3", "G3", "Bb3", "A3", "Ab3"])],
         gain=0.58, pan=-0.16)
    _perc(b, "timp", M.timpani_s,
          [(B(8 + 2 * k), 1.8, "D2", 0.56) for k in range(8)] +
          [(B(32 + 2 * k), 1.8, "D2", 0.62) for k in range(8)],
          gain=0.44, pan=0.04)
    _sus(b, "brass", M.brass_sec,
         [(B(8 + 2 * k, 0.0), 3.4, n, 0.58) for k, n in
          enumerate(["D2", "Eb2", "C2", "E2", "D2", "F2", "B1", "D2"])] +
         [(B(32 + 2 * k, 0.0), 3.4, n, 0.66) for k, n in
          enumerate(["D2", "Eb2", "C2", "F#2", "G2", "Bb2", "A2", "Ab2"])],
         gain=0.46, pan=0.14, high=True)
    _sus(b, "choir", M.choir_ooh,
         [(B(24 + 2 * k), 7.0, n, 0.40) for k, n in enumerate(["A3", "A3", "A3", "A3"])] +
         [(B(32 + 2 * k), 6.6, n, 0.44) for k, n in
          enumerate(["D4", "Eb4", "C4", "F#4", "G4", "Bb4", "A4", "Ab4"])],
         gain=0.32, pan=-0.08, high=True)
    _perc(b, "toms", M.tom_s,
          [(B(32 + k, o), 0.55, "A1", 0.52) for k in range(16) for o in (0.0, 1.0, 2.0, 3.0)],
          gain=0.26, pan=-0.14, high=True)
    _perc(b, "crash", M.crash_s, [(B(8), 2.4, "C4", 0.48), (B(32), 2.4, "C4", 0.58)],
          gain=0.24, pan=0.16, high=True)
    b.hi_mel([(B(32 + 2 * k, 1.0), 2.4, n, 0.38) for k, n in
              enumerate(["D5", "Eb5", "C5", "F#5", "G5", "F5", "E5", "Eb5"])])
    _synth_bass(b, 8, 16, ["D1", "D1", "Eb1", "D1", "C1", "C1", "Bb0", "A0"],
                "x..xx..x", vel=0.36)
    _synth_bass(b, 32, 16, ["D1", "Eb1", "D1", "C1", "Bb0", "A0", "Ab0", "G0"],
                "x.xxx..x", vel=0.42, high=True)
    _perc(b, "box", M.music_box_worn,
          [(b.b(32 + 2 * k, 3.0), 1.6, n, 0.34) for k, n in
           enumerate(["D5", "Eb5", "C5", "F#5", "G5", "F5", "E5", "Eb5"])],
          gain=0.30, pan=0.26, reverb=(2.6, 0.74, 0.26, 0.034), high=True)
    return b


# ===========================================================================
# rimefang - the ice. C minor with a lydian raised 4th. 150 BPM, 57 bars.
# ===========================================================================
#
# Cold and mean: the theme's F# survives into the minor, so the ostinato's
# tritone against the C is the same interval that made the island sound like
# glass. The strings sit high and the brass never plays a third.

def _rimefang():
    b = Boss("boss_rimefang", 150.0, 57, tilt=0.7)
    B = b.b
    b.bassline(0, ["C2", "C2", "F#1", "G1"], vel=0.46, label="C - tritone - G")
    b.bassline(4, ["Ab1", "G1", "F#1", "F1"], vel=0.46, label="chromatic descent")
    b.ostinato(8, 16, ["C1", "C1", "F#0", "G0", "C1", "C1", "Ab0", "G0"],
               pattern="xx.x.x.x", vel=0.54, dur=0.20)
    b.chords(8, [(2, ["G3", "C4", "Eb4"], "Cm add9"), (2, ["F#3", "C4", "Eb4"], "Cm7b5 (lydian 4)"),
                 (2, ["G3", "Bb3", "Eb4"], "Cm11"), (2, ["Ab3", "C4", "F4"], "Abmaj7#11"),
                 (2, ["G3", "C4", "D4"], "Csus2"), (2, ["F#3", "A3", "D4"], "D/F# (raised)"),
                 (2, ["G3", "Bb3", "F4"], "Cm11"), (2, ["Ab3", "Eb4", "G4"], "Abmaj9")],
             vel=0.30)
    b.bassline(24, ["Eb2", "Eb2", "D2", "D2", "Db2", "Db2", "C2", "C2"], vel=0.42,
               label="break: chromatic Eb - D - Db - C")
    b.chords(24, [(2, ["Bb3", "Eb4", "G4"], "Ebmaj9"), (2, ["A3", "D4", "F#4"], "D (major)"),
                  (2, ["Ab3", "Db4", "F4"], "Dbmaj7 (bII)"), (2, ["G3", "C4", "Eb4"], "Cm add9")],
             vel=0.32)
    b.ostinato(32, 16, ["C1", "F#0", "C1", "G0", "Ab0", "G0", "F#0", "F0"],
               pattern="xx.xx.xx", vel=0.58, dur=0.18)
    b.chords(32, [(2, ["G3", "C4", "Eb4"], "Cm add9"), (2, ["F#3", "C4", "Eb4"], "Cm7b5"),
                  (2, ["G3", "Bb3", "Eb4"], "Cm11"), (2, ["G3", "B3", "Eb4"], "C(maj7) shift"),
                  (2, ["Ab3", "C4", "F4"], "Abmaj7#11"), (2, ["F#3", "B3", "E4"], "B quartal"),
                  (2, ["G3", "C4", "D4"], "Csus2"), (2, ["G3", "Db4", "F4"], "Dbmaj7/G (bII)")],
             vel=0.34)
    b.ostinato(48, 8, ["C1", "C1", "F#0", "G0"], pattern="x.x.x...", vel=0.48, dur=0.24)
    b.bassline(56, ["Ab1"], vel=0.42, label="lead-in")
    _sus(b, "strings", M.strings_sec,
         [(B(8 + 2 * k), 7.0, n, 0.44) for k, n in
          enumerate(["G4", "F#4", "Eb4", "C5", "Bb4", "A4", "G4", "Eb5"])] +
         [(B(24 + 2 * k), 7.0, n, 0.36) for k, n in enumerate(["G4", "F#4", "F4", "Eb4"])] +
         [(B(32 + 2 * k), 7.0, n, 0.48) for k, n in
          enumerate(["G5", "F#5", "Eb5", "B4", "C5", "E5", "D5", "Db5"])],
         gain=0.54, pan=-0.20)
    _perc(b, "timp", M.timpani_s,
          [(B(8 + 4 * k), 1.5, "C2", 0.58) for k in range(4)] +
          [(B(32 + 2 * k), 1.5, "C2", 0.64) for k in range(8)],
          gain=0.40, pan=0.05)
    _sus(b, "brass", M.brass_sec,
         [(B(8 + 2 * k, 0.0), 1.2, n, 0.58) for k, n in
          enumerate(["C2", "F#2", "C2", "Ab2", "C2", "D2", "C2", "Eb2"])] +
         [(B(32 + 2 * k, 0.0), 3.4, n, 0.66) for k, n in
          enumerate(["C2", "F#2", "G2", "B1", "Ab2", "E2", "G2", "Db2"])],
         gain=0.44, pan=0.16, high=True)
    _sus(b, "choir", M.choir_ahh,
         [(B(32 + 2 * k), 7.0, n, 0.42) for k, n in
          enumerate(["C5", "F#4", "G4", "B4", "C5", "E5", "D5", "Db5"])],
         gain=0.32, pan=-0.06, high=True)
    _perc(b, "toms", M.tom_s,
          [(B(32 + k, o), 0.45, "C2", 0.50) for k in range(16) for o in (0.0, 1.5, 3.0)],
          gain=0.26, pan=-0.14, high=True)
    _perc(b, "crash", M.crash_s,
          [(B(8), 2.2, "C4", 0.48), (B(24), 2.2, "C4", 0.44), (B(32), 2.2, "C4", 0.60)],
          gain=0.26, pan=0.18, high=True)
    b.hi_mel([(B(32 + 2 * k, 1.0), 2.4, n, 0.40) for k, n in
              enumerate(["C6", "F#5", "G5", "B5", "C6", "Bb5", "Ab5", "G5"])] +
             [(B(40 + k, 3.0), 1.0, n, 0.34) for k, n in
              enumerate(["Eb6", "D6", "C6", "B5", "C6", "G5", "Eb5", "C5"])])
    _synth_bass(b, 8, 16, ["C1", "C1", "F#0", "G0", "C1", "C1", "Ab0", "G0"],
                "xx.x.x.x", vel=0.38)
    _synth_bass(b, 32, 16, ["C1", "F#0", "C1", "G0", "Ab0", "G0", "F#0", "F0"],
                "xx.xx.xx", vel=0.44, high=True)
    _arp(b, "arp", 8, 16, [["C5", "Eb5", "G5", "C6"], ["F#4", "C5", "Eb5", "F#5"],
                           ["G4", "Bb4", "Eb5", "G5"], ["Ab4", "C5", "F5", "Ab5"],
                           ["C5", "D5", "G5", "C6"], ["F#4", "A4", "D5", "F#5"],
                           ["G4", "Bb4", "F5", "G5"], ["Eb5", "G5", "Ab5", "Eb6"]],
         step=0.5, vel=0.24, gain=0.24)
    # the island's glass bells survive into its boss - the only thing that
    # says "this is Frostmaw" before the first tell
    _perc(b, "glass", M.glass_bell,
          [(b.b(8 + 2 * k, 0.0), 3.0, n, 0.30) for k, n in
           enumerate(["C6", "F#5", "G5", "Eb6", "C6", "D6", "G5", "Ab5"])] +
          [(b.b(32 + 2 * k, 0.0), 3.0, n, 0.36) for k, n in
           enumerate(["C6", "F#6", "G6", "B5", "C6", "E6", "D6", "Db6"])],
          gain=0.30, pan=-0.28, reverb=(2.8, 0.56, 0.28, 0.034), high=True)
    return b


# ===========================================================================
# pyrelisk - the caldera. E phrygian, brass-heavy. 156 BPM, 59 bars.
# ===========================================================================

def _pyrelisk():
    b = Boss("boss_pyrelisk", 156.0, 59, tilt=-1.0)
    B = b.b
    b.bassline(0, ["E2", "F2", "E2", "F2"], vel=0.48, label="E - bII grind")
    b.bassline(4, ["E2", "F2", "G2", "F2"], vel=0.50, label="phrygian rise")
    b.ostinato(8, 16, ["E1", "F1", "E1", "E1", "G1", "F1", "E1", "Bb0"],
               pattern="xx.xxx.x", vel=0.56, dur=0.18)
    b.chords(8, [(2, ["B3", "E4", "G4"], "Em add9"), (2, ["C4", "F4", "A4"], "Fmaj7#11 (bII)"),
                 (2, ["B3", "D4", "G4"], "Em11"), (2, ["C4", "E4", "G4"], "Cmaj9"),
                 (2, ["B3", "E4", "A4"], "Esus4add11"), (2, ["Bb3", "E4", "G4"], "Edim (tritone)"),
                 (2, ["B3", "D4", "F4"], "Em7b9"), (2, ["C4", "F4", "Bb4"], "F quartal")],
             vel=0.30)
    b.bassline(24, ["C2", "C2", "Bb1", "Bb1", "A1", "A1", "Ab1", "G1"], vel=0.44,
               label="break: bVI - bV - IV - chromatic")
    b.chords(24, [(2, ["G3", "C4", "E4"], "Cmaj9"), (2, ["F3", "Bb3", "D4"], "Bbmaj9"),
                  (2, ["E3", "A3", "C4"], "Am11"), (2, ["Eb3", "G3", "B3"], "G#aug/Eb")],
             vel=0.32)
    b.ostinato(32, 16, ["E1", "F1", "E1", "G1", "F1", "E1", "Bb0", "B0"],
               pattern="xxxx.xxx", vel=0.60, dur=0.16)
    b.chords(32, [(2, ["B3", "E4", "G4"], "Em add9"), (2, ["C4", "F4", "A4"], "Fmaj7#11 (bII)"),
                  (2, ["B3", "E4", "G#4"], "E major shift"), (2, ["C4", "E4", "A4"], "Am/C"),
                  (2, ["B3", "D4", "G4"], "Em11"), (2, ["Bb3", "E4", "Ab4"], "E7b5"),
                  (2, ["B3", "E4", "A4"], "Esus4add11"), (2, ["C4", "F4", "Bb4"], "F quartal")],
             vel=0.36)
    b.ostinato(48, 11, ["E1", "F1", "E1", "E1"], pattern="x...x...", vel=0.48, dur=0.32)
    _sus(b, "strings", M.strings_sec,
         [(B(8 + 2 * k), 7.2, n, 0.44) for k, n in
          enumerate(["E4", "F4", "G4", "E4", "A4", "Bb4", "F4", "E4"])] +
         [(B(24 + 2 * k), 7.2, n, 0.36) for k, n in enumerate(["E4", "D4", "C4", "B3"])] +
         [(B(32 + 2 * k), 7.2, n, 0.48) for k, n in
          enumerate(["E5", "F5", "G#4", "A4", "G4", "Ab4", "B4", "Bb4"])],
         gain=0.54, pan=-0.18)
    _perc(b, "timp", M.timpani_s,
          [(B(8 + 2 * k), 1.5, "E2", 0.58) for k in range(8)] +
          [(B(32 + k), 1.2, "E2", 0.62) for k in range(16)],
          gain=0.42, pan=0.05)
    _sus(b, "brass", M.brass_sec,
         [(B(8 + k, 0.0), 1.6, n, 0.62) for k, n in
          enumerate(["E2", "F2", "E2", "G2", "E2", "F2", "E2", "Bb1",
                     "E2", "F2", "G2", "F2", "E2", "Bb1", "E2", "F2"])] +
         [(B(32 + k, 0.0), 1.6, n, 0.70) for k, n in
          enumerate(["E2", "F2", "E2", "G#2", "A2", "G2", "E2", "Bb1",
                     "E2", "F2", "B1", "E2", "F2", "G2", "Bb1", "E2"])],
         gain=0.50, pan=0.14, high=True)
    _sus(b, "choir", M.choir_ahh,
         [(B(32 + 2 * k), 7.2, n, 0.44) for k, n in
          enumerate(["E4", "F4", "G#4", "A4", "G4", "Ab4", "B4", "E4"])],
         gain=0.32, pan=-0.06, high=True)
    _perc(b, "toms", M.tom_s,
          [(B(8 + k, o), 0.45, "E2", 0.46) for k in range(16) for o in (0.0, 2.0)] +
          [(B(32 + k, o), 0.45, "E2", 0.56) for k in range(16) for o in (0.0, 1.0, 2.0, 3.0)],
          gain=0.28, pan=-0.12, high=True)
    _perc(b, "crash", M.crash_s,
          [(B(8), 2.2, "C4", 0.50), (B(32), 2.2, "C4", 0.62), (B(48), 2.2, "C4", 0.44)],
          gain=0.26, pan=0.18, high=True)
    b.hi_mel([(B(32 + 2 * k, 1.0), 2.2, n, 0.40) for k, n in
              enumerate(["E5", "F5", "G#5", "A5", "G5", "F5", "E5", "Bb4"])])
    _synth_bass(b, 8, 16, ["E1", "F1", "E1", "E1", "G1", "F1", "E1", "Bb0"],
                "xx.xxx.x", vel=0.40)
    _synth_bass(b, 32, 16, ["E1", "F1", "E1", "G1", "F1", "E1", "Bb0", "B0"],
                "xxxx.xxx", vel=0.46, high=True)
    # the saturated stack rides the brass stabs: a 1-3 kHz edge neither the
    # brass nor the piano can make, and still high-passed at 130 Hz
    _perc(b, "rasp", M.rasp_syn,
          [(b.b(32 + k, 0.0), 1.2, n, 0.44) for k, n in
           enumerate(["E2", "F2", "E2", "G#2", "A2", "G2", "E2", "Bb1",
                      "E2", "F2", "B1", "E2", "F2", "G2", "Bb1", "E2"])],
          gain=0.30, pan=0.22, reverb=(1.8, 0.76, 0.16, 0.022), high=True)
    return b


# ===========================================================================
# noctyss - the trench. Minor 9ths, sparse, then it erupts. 146 BPM, 56 bars.
# ===========================================================================
#
# The only boss whose `low` stem is nearly empty: a two-note figure, a held
# ninth, a timpani every four bars. The `high` stem is what erupts - and it
# is the loudest thing in the game, which is the point: phase 1 is the
# quietest boss music there is and phase 2 is a wall.

def _noctyss():
    b = Boss("boss_noctyss", 146.0, 56, tilt=-0.8)
    B = b.b
    b.bassline(0, ["A1", "A1", "Bb1", "A1"], vel=0.40, label="A + minor 9th")
    b.bassline(4, ["F1", "F1", "Gb1", "F1"], vel=0.40, label="F + minor 9th")
    b.ostinato(8, 16, ["A0", "A0", "Bb0", "A0", "F0", "F0", "Gb0", "F0"],
               pattern="x.......", vel=0.50, dur=0.60)
    b.chords(8, [(2, ["E3", "Bb3"], "A + m9"), (2, ["E3", "A3"], "A5 open"),
                 (2, ["Eb3", "Bb3"], "A tritone"), (2, ["F3", "C4"], "F5"),
                 (2, ["E3", "Bb3"], "A + m9"), (2, ["Gb3", "C4"], "Gb + tritone"),
                 (2, ["E3", "A3"], "A5"), (2, ["F3", "B3"], "F + tritone")],
             vel=0.26)
    b.bassline(24, ["A1", "Ab1", "G1", "Gb1", "F1", "E1", "Eb1", "D1"], vel=0.42,
               label="chromatic descent, eight bars")
    b.chords(24, [(8, ["Bb3", "E4"], "held tritone over the descent")], vel=0.24)
    b.ostinato(32, 16, ["A0", "Bb0", "A0", "F0", "Gb0", "F0", "Eb0", "D0"],
               pattern="xx.xxx.x", vel=0.60, dur=0.16)
    b.chords(32, [(2, ["E3", "Bb3", "D4"], "A7b9 no 3rd"), (2, ["F3", "Bb3", "Eb4"], "Bb quartal"),
                  (2, ["E3", "A3", "C#4"], "A major shift"), (2, ["F3", "C4", "F4"], "F5 open"),
                  (2, ["Eb3", "Bb3", "D4"], "Eb tritone"), (2, ["F3", "B3", "E4"], "F#dim/F"),
                  (2, ["E3", "Bb3", "D4"], "A7b5"), (2, ["D3", "Ab3", "C4"], "D7b5")],
             vel=0.36)
    b.ostinato(48, 8, ["A0", "A0", "Bb0", "A0"], pattern="x...x...", vel=0.46, dur=0.40)
    _sus(b, "strings", M.strings_sec,
         [(B(8 + 4 * k), 14.0, n, 0.34) for k, n in enumerate(["Bb4", "A4", "Bb4", "C5"])] +
         [(B(24 + 2 * k), 7.0, n, 0.34) for k, n in enumerate(["Bb4", "Bb4", "Bb4", "Bb4"])] +
         [(B(32 + 2 * k), 7.0, n, 0.50) for k, n in
          enumerate(["Bb5", "A5", "C#5", "C5", "Bb4", "B4", "D5", "Ab4"])],
         gain=0.50, pan=-0.20)
    _perc(b, "timp", M.timpani_s,
          [(B(8 + 4 * k), 2.0, "A1", 0.54) for k in range(4)] +
          [(B(32 + k), 1.2, "A1", 0.64) for k in range(16)],
          gain=0.44, pan=0.05)
    _sus(b, "brass", M.brass_sec,
         [(B(32 + k, 0.0), 1.7, n, 0.72) for k, n in
          enumerate(["A1", "Bb1", "A1", "C#2", "F2", "E2", "Eb2", "D2",
                     "A1", "Bb1", "E2", "F2", "Eb2", "B1", "Ab1", "A1"])],
         gain=0.52, pan=0.14, high=True)
    _sus(b, "choir", M.choir_ahh,
         [(B(32 + 2 * k), 7.0, n, 0.50) for k, n in
          enumerate(["A4", "Bb4", "C#5", "C5", "Bb4", "B4", "D5", "A4"])],
         gain=0.38, pan=-0.06, high=True)
    _perc(b, "toms", M.tom_s,
          [(B(32 + k, o), 0.45, "A1", 0.58) for k in range(16)
           for o in (0.0, 0.5, 1.5, 2.0, 3.0)],
          gain=0.30, pan=-0.12, high=True)
    _perc(b, "crash", M.crash_s,
          [(B(32), 2.4, "C4", 0.66), (B(40), 2.4, "C4", 0.50)],
          gain=0.30, pan=0.18, high=True)
    b.hi_mel([(B(32 + 2 * k, 1.0), 2.2, n, 0.44) for k, n in
              enumerate(["A5", "Bb5", "C#6", "C6", "Bb5", "A5", "Ab5", "A5"])])
    _synth_bass(b, 32, 16, ["A0", "Bb0", "A0", "F0", "Gb0", "F0", "Eb0", "D0"],
                "xx.xxx.x", vel=0.46, high=True)
    _perc(b, "glasspad", M.glass_pad_syn,
          [(b.b(8 + 4 * k), 14.0, n, 0.42) for k, n in enumerate(["A3", "F3", "A3", "Bb3"])],
          gain=0.34, pan=0.12, reverb=(3.4, 0.82, 0.30, 0.055))
    _arp(b, "arp", 32, 16, [["A4", "C5", "E5", "A5"], ["Bb4", "D5", "F5", "Bb5"],
                            ["A4", "C#5", "E5", "A5"], ["F4", "A4", "C5", "F5"],
                            ["Gb4", "Bb4", "Db5", "Gb5"], ["F4", "A4", "C5", "F5"],
                            ["Eb4", "G4", "Bb4", "Eb5"], ["D4", "F4", "Ab4", "D5"]],
         step=0.5, vel=0.26, gain=0.26)
    return b


# ===========================================================================
# admiral_wrack - the wreck. G aeolian/phrygian, nautical. 154 BPM, 59 bars.
# ===========================================================================

def _wrack():
    b = Boss("boss_admiral_wrack", 154.0, 59, tilt=-0.5)
    B = b.b
    b.bassline(0, ["G2", "G2", "Ab2", "G2"], vel=0.46, label="G + phrygian bII")
    b.bassline(4, ["Eb2", "D2", "Db2", "C2"], vel=0.46, label="chromatic descent")
    b.ostinato(8, 16, ["G1", "G1", "Ab1", "G1", "Eb1", "D1", "C1", "D1"],
               pattern="x.xx.x.x", vel=0.54, dur=0.20)
    b.chords(8, [(2, ["D4", "G4", "Bb4"], "Gm add9"), (2, ["Eb4", "Ab4", "C5"], "Abmaj7#11 (bII)"),
                 (2, ["D4", "F4", "Bb4"], "Gm11"), (2, ["Eb4", "G4", "Bb4"], "Ebmaj9"),
                 (2, ["D4", "G4", "C5"], "Gsus4add11"), (2, ["Db4", "G4", "Bb4"], "G7b5 (tritone)"),
                 (2, ["D4", "F4", "A4"], "Dm7b5"), (2, ["C4", "F4", "Bb4"], "C quartal")],
             vel=0.30)
    b.bassline(24, ["Eb2", "Eb2", "Bb1", "Bb1", "Ab1", "Ab1", "D2", "D2"], vel=0.42,
               label="break: bVI - bIII - bII - V")
    b.chords(24, [(2, ["Bb3", "Eb4", "G4"], "Ebmaj9"), (2, ["F3", "Bb3", "D4"], "Bbmaj9"),
                  (2, ["Eb4", "Ab4", "C5"], "Abmaj7"), (2, ["D4", "F#4", "C5"], "D7 (raised 3rd)")],
             vel=0.32)
    b.ostinato(32, 16, ["G1", "Ab1", "G1", "Eb1", "D1", "Db1", "C1", "B0"],
               pattern="xx.xx.xx", vel=0.58, dur=0.18)
    b.chords(32, [(2, ["D4", "G4", "Bb4"], "Gm add9"), (2, ["Eb4", "Ab4", "C5"], "Abmaj7#11"),
                  (2, ["D4", "G4", "B4"], "G major shift"), (2, ["Eb4", "Bb4", "D5"], "Ebmaj7"),
                  (2, ["D4", "F4", "Bb4"], "Gm11"), (2, ["Db4", "F4", "B4"], "Db7 (tritone sub)"),
                  (2, ["C4", "F4", "Bb4"], "C quartal"), (2, ["B3", "F4", "A4"], "B dim")],
             vel=0.34)
    b.ostinato(48, 11, ["G1", "G1", "Ab1", "G1"], pattern="x.x.x...", vel=0.48, dur=0.26)
    _sus(b, "strings", M.strings_sec,
         [(B(8 + 2 * k), 7.2, n, 0.44) for k, n in
          enumerate(["G4", "Ab4", "Bb4", "G4", "D5", "C5", "A4", "Bb4"])] +
         [(B(24 + 2 * k), 7.2, n, 0.36) for k, n in enumerate(["G4", "F4", "Eb4", "F#4"])] +
         [(B(32 + 2 * k), 7.2, n, 0.48) for k, n in
          enumerate(["G5", "Ab5", "B4", "Bb4", "D5", "F5", "Eb5", "D5"])],
         gain=0.54, pan=-0.18)
    _perc(b, "timp", M.timpani_s,
          [(B(8 + 2 * k), 1.5, "G1", 0.56) for k in range(8)] +
          [(B(32 + 2 * k), 1.5, "G1", 0.62) for k in range(8)],
          gain=0.42, pan=0.05)
    _sus(b, "brass", M.brass_sec,
         [(B(8 + 2 * k, 0.0), 1.4, n, 0.60) for k, n in
          enumerate(["G2", "Ab2", "G2", "Eb2", "G2", "Db2", "D2", "C2"])] +
         [(B(32 + k, 0.0), 1.6, n, 0.68) for k, n in
          enumerate(["G2", "Ab2", "G2", "B1", "Eb2", "D2", "Db2", "C2",
                     "G2", "Ab2", "Bb2", "G2", "F2", "Eb2", "D2", "G2"])],
         gain=0.48, pan=0.14, high=True)
    _sus(b, "choir", M.choir_ahh,
         [(B(32 + 2 * k), 7.2, n, 0.44) for k, n in
          enumerate(["G4", "Ab4", "B4", "Bb4", "D5", "C5", "Bb4", "G4"])],
         gain=0.34, pan=-0.06, high=True)
    _perc(b, "toms", M.tom_s,
          [(B(32 + k, o), 0.45, "G1", 0.54) for k in range(16) for o in (0.0, 1.0, 2.0, 3.0)],
          gain=0.28, pan=-0.12, high=True)
    _perc(b, "crash", M.crash_s,
          [(B(8), 2.2, "C4", 0.48), (B(32), 2.2, "C4", 0.60)],
          gain=0.26, pan=0.18, high=True)
    b.hi_mel([(B(32 + 2 * k, 1.0), 2.4, n, 0.40) for k, n in
              enumerate(["G5", "Ab5", "B5", "Bb5", "D6", "C6", "Bb5", "G5"])])
    _synth_bass(b, 8, 16, ["G1", "G1", "Ab1", "G1", "Eb1", "D1", "C1", "D1"],
                "x.xx.x.x", vel=0.38)
    _synth_bass(b, 32, 16, ["G1", "Ab1", "G1", "Eb1", "D1", "Db1", "C1", "B0"],
                "xx.xx.xx", vel=0.44, high=True)
    _perc(b, "accordion", M.reed_syn,
          [(b.b(8 + 2 * k, 0.0), 3.4, n, 0.36) for k, n in
           enumerate(["D3", "Eb3", "D3", "Bb2", "C3", "Db3", "D3", "F3"])] +
          [(b.b(32 + 2 * k, 0.0), 3.4, n, 0.42) for k, n in
           enumerate(["D3", "Eb3", "D3", "Bb2", "F3", "Db3", "C3", "B2"])],
          gain=0.28, pan=-0.24, reverb=(2.4, 0.78, 0.22, 0.032), high=True)
    _perc(b, "sea_bell", M.chime_soft,
          [(b.b(8), 4.0, "G4", 0.34), (b.b(24), 4.0, "Eb4", 0.30),
           (b.b(32), 4.0, "G4", 0.40), (b.b(48), 4.0, "D4", 0.30)],
          gain=0.32, pan=0.26, reverb=(3.2, 0.70, 0.30, 0.050), high=True)
    return b


# ===========================================================================
# kraken - the Maelstrom. D minor, open fifths, storm. 160 BPM, 61 bars.
# ===========================================================================

def _kraken():
    b = Boss("boss_kraken", 160.0, 61, tilt=-0.2, width=0.46)
    B = b.b
    b.bassline(0, ["D2", "A1", "D2", "E2"], vel=0.48, label="open fifths")
    b.bassline(4, ["F2", "E2", "Eb2", "D2"], vel=0.50, label="chromatic descent")
    b.ostinato(8, 16, ["D1", "D1", "A0", "D1", "C1", "Bb0", "A0", "G0"],
               pattern="xx.xxx.x", vel=0.58, dur=0.16)
    b.chords(8, [(2, ["A3", "D4", "A4"], "D5 open"), (2, ["A3", "E4", "G4"], "Dsus2add11"),
                 (2, ["Bb3", "D4", "F4"], "Bbmaj7/D"), (2, ["C4", "G4", "Bb4"], "C9 no 3rd"),
                 (2, ["A3", "D4", "F4"], "Dm add9"), (2, ["Ab3", "D4", "F4"], "D dim (tritone)"),
                 (2, ["A3", "E4", "A4"], "A5 open"), (2, ["G3", "D4", "Bb4"], "Gm11")],
             vel=0.32)
    b.bassline(24, ["Eb2", "Eb2", "D2", "D2", "C2", "C2", "Bb1", "A1"], vel=0.44,
               label="break: Neapolitan Eb, then stepwise down")
    b.chords(24, [(2, ["Bb3", "Eb4", "G4"], "Ebmaj7 (Neapolitan)"),
                  (2, ["A3", "D4", "F4"], "Dm add9"),
                  (2, ["G3", "C4", "E4"], "Cmaj9"), (2, ["A3", "C#4", "E4"], "A major shift")],
             vel=0.34)
    b.ostinato(32, 16, ["D1", "A0", "D1", "Eb1", "D1", "C1", "Bb0", "A0"],
               pattern="xxxxx.xx", vel=0.62, dur=0.15)
    b.chords(32, [(2, ["A3", "D4", "A4"], "D5 open"), (2, ["Bb3", "Eb4", "Bb4"], "Eb5 (bII)"),
                  (2, ["A3", "D4", "F#4"], "D major shift"), (2, ["A3", "E4", "G4"], "Dsus4add11"),
                  (2, ["Bb3", "F4", "D5"], "Bbmaj9"), (2, ["G3", "D4", "Bb4"], "Gm11"),
                  (2, ["A3", "E4", "C#5"], "A(maj7) no 3rd"), (2, ["Ab3", "Eb4", "C5"], "Abmaj7 (tritone)")],
             vel=0.38)
    b.ostinato(48, 13, ["D1", "D1", "A0", "D1"], pattern="x.x.x.x.", vel=0.50, dur=0.22)
    _sus(b, "strings", M.strings_sec,
         [(B(8 + 2 * k), 7.4, n, 0.46) for k, n in
          enumerate(["D5", "E5", "F5", "D5", "A4", "Bb4", "C5", "D5"])] +
         [(B(24 + 2 * k), 7.4, n, 0.38) for k, n in enumerate(["Eb5", "D5", "C5", "C#5"])] +
         [(B(32 + 2 * k), 7.4, n, 0.52) for k, n in
          enumerate(["D5", "Eb5", "F#5", "G5", "F5", "D5", "C#5", "C5"])],
         gain=0.58, pan=-0.20)
    _perc(b, "timp", M.timpani_s,
          [(B(8 + 2 * k), 1.4, "D2", 0.60) for k in range(8)] +
          [(B(32 + k), 1.1, "D2", 0.66) for k in range(16)],
          gain=0.44, pan=0.05)
    _sus(b, "brass", M.brass_sec,
         [(B(8 + 2 * k, 0.0), 1.4, n, 0.62) for k, n in
          enumerate(["D2", "A1", "D2", "Bb1", "C2", "Ab1", "D2", "G1"])] +
         [(B(32 + k, 0.0), 1.5, n, 0.72) for k, n in
          enumerate(["D2", "A1", "D2", "Eb2", "D2", "C2", "Bb1", "A1",
                     "D2", "F#2", "G2", "F2", "D2", "C#2", "C2", "D2"])],
         gain=0.52, pan=0.14, high=True)
    _sus(b, "choir", M.choir_ahh,
         [(B(32 + 2 * k), 7.4, n, 0.50) for k, n in
          enumerate(["D5", "Eb5", "F#5", "G5", "F5", "D5", "C#5", "D5"])],
         gain=0.38, pan=-0.06, high=True)
    _perc(b, "toms", M.tom_s,
          [(B(8 + k, o), 0.45, "D2", 0.50) for k in range(16) for o in (0.0, 2.0)] +
          [(B(32 + k, o), 0.42, "D2", 0.60) for k in range(16)
           for o in (0.0, 0.5, 1.5, 2.0, 3.0)],
          gain=0.30, pan=-0.12, high=True)
    _perc(b, "crash", M.crash_s,
          [(B(8), 2.4, "C4", 0.52), (B(24), 2.4, "C4", 0.48), (B(32), 2.4, "C4", 0.66),
           (B(48), 2.4, "C4", 0.50)],
          gain=0.28, pan=0.18, high=True)
    b.hi_mel([(B(32 + 2 * k, 1.0), 2.2, n, 0.44) for k, n in
              enumerate(["D6", "Eb6", "F#6", "G6", "F6", "D6", "C#6", "D6"])] +
             [(B(40 + k, 3.0), 1.0, n, 0.36) for k, n in
              enumerate(["A5", "Bb5", "C6", "D6", "C6", "Bb5", "A5", "G5"])])
    _synth_bass(b, 8, 16, ["D1", "D1", "A0", "D1", "C1", "Bb0", "A0", "G0"],
                "xx.xxx.x", vel=0.40)
    _synth_bass(b, 32, 16, ["D1", "A0", "D1", "Eb1", "D1", "C1", "Bb0", "A0"],
                "xxxxx.xx", vel=0.48, high=True)
    _arp(b, "arp", 8, 16, [["D4", "A4", "D5", "A5"], ["E4", "A4", "E5", "A5"],
                           ["Bb3", "F4", "Bb4", "F5"], ["C4", "G4", "C5", "G5"],
                           ["D4", "A4", "D5", "F5"], ["Ab3", "Eb4", "Ab4", "Eb5"],
                           ["A3", "E4", "A4", "E5"], ["G3", "D4", "G4", "D5"]],
         step=0.5, vel=0.24, gain=0.24, high=False)
    # the Maelstrom's tubular bells toll through the fight
    _perc(b, "bells", M.tubular_bell,
          [(b.b(8), 7.0, "D3", 0.40), (b.b(16), 7.0, "A2", 0.34),
           (b.b(24), 7.0, "Eb3", 0.38), (b.b(32), 7.0, "D3", 0.46),
           (b.b(40), 7.0, "F3", 0.40), (b.b(48), 7.0, "D3", 0.36)],
          gain=0.34, pan=0.24, reverb=(3.6, 0.66, 0.30, 0.055), high=True)
    return b


# ---------------------------------------------------------------------------

_BOSSES = {
    "brinejaw": _brinejaw,
    "old_gnashroot": _gnashroot,
    "rimefang": _rimefang,
    "pyrelisk": _pyrelisk,
    "noctyss": _noctyss,
    "admiral_wrack": _wrack,
    "kraken": _kraken,
}

_RENDERED = {}


def _stems(boss_id):
    if boss_id not in _RENDERED:
        _RENDERED[boss_id] = _BOSSES[boss_id]().render()
    return _RENDERED[boss_id]


def _stem_fn(boss_id, which):
    def render(rng):
        return _stems(boss_id)[0 if which == "low" else 1]
    return render


TRACKS = {}
for _bid in _BOSSES:
    TRACKS["boss_%s_low" % _bid] = _stem_fn(_bid, "low")
    TRACKS["boss_%s_high" % _bid] = _stem_fn(_bid, "high")


if __name__ == "__main__":
    import time

    for bid in _BOSSES:
        t0 = time.time()
        lo, hi = _stems(bid)
        piece = _BOSSES[bid]()
        print("%-22s %5.1f BPM  %2d bars  low %.3fs  high %.3fs  (%.1fs)"
              % (bid, piece.bpm, piece.bars, len(lo) / S.SR, len(hi) / S.SR,
                 time.time() - t0))
