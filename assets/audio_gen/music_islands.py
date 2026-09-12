"""music_islands.py - the seven island themes (CONTRACT.md §4).

ONE IDIOM, SEVEN WORLDS. Every theme is still a nocturne - a real grand
(FL Studio's Stage Grand, sampled, §3e) at pp-mp with the sustain pedal held
for a bar or two at a time, 50-72 BPM, rubato, no drum kit and no pulse you
could tap. What changed in v5 is that each one is now a LAYERED production
and no two of them share a scale, a chord language or an instrument set.

    theme             scale                          layers (S = sampled, Y = synth)
    island_tropical   F lydian <-> F mixolydian      S grand, S choir "ooh", additive
                                                     solo violin, celesta, harp arps,
                                                     Y warm pad, Y shimmer
    island_swamp      D dorian + blues b3/b5/b7      S grand (low), S celli, S woodwind
                                                     reed, worn music box, Y dark drone
    island_ice        C lydian + whole-tone          S grand (high), glass bells,
                                                     far glockenspiel, S high strings,
                                                     Y icy shimmer, Y slow arp
    island_volcano    E phrygian dominant / harm.min S grand ostinato, S brass,
                                                     S timpani (far back), S choir "ahh",
                                                     Y filtered pulse
    island_gloom      A minor, min-maj7 + quartal    S CLOSE grand, S Rhodes,
                                                     Y bowed-glass pad, violin harmonics
    island_wreck      G aeolian/phrygian, 6/8        S celli, additive solo violin,
                                                     S grand, Y accordion reed, sea-chime
    island_maelstrom  D minor / octatonic swells     S strings, S choir "ahh", grand
                                                     tremolo, tubular bells, Y big pad

THE MELODIES ARE V4'S, UNCHANGED. Every note of every tune and every grace
note and turn is byte-for-byte what was approved; the work here is harmony
and arrangement. Chord colour now moves EVERY BAR (and twice a bar in the
melody's rests) instead of every two, with passing chords, secondary colour
and inner voices that step rather than leap - and still no functional pop
loop anywhere: the bass is a pedal, a stepwise walk or a chromatic descent,
never a cycle of fourths.

THE SYNTHS ARE UNDER-LAYERS. Everything in §3g is high-passed at 120-170 Hz
and mixed 12-16 dB below the piano's melody. The grand is the only
instrument in this soundtrack with a bottom octave. If you can name the
synth while the tune is playing, it is too loud.

STRUCTURE. Authored to an exact bar count and rendered with TAIL seconds of
overhang, which `Nocturne.render` trims and `loop_wrap` folds under bar 1.
The last bar is written as a lead-in to bar 0.

    python3 assets/audio_gen/music_islands.py    # -> preview/showreel_islands.ogg
"""

import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import music as M  # noqa: E402
import synth as S  # noqa: E402

TAIL = 8.0


def lay(p, first_bar, prog, vel=0.22, offs=None, restrike=True):
    """Write a chord table into the left hand, one entry per chord.

    `prog` is [(bars, bass, [upper, ...], "Chord name"), ...]. A chord held
    for more than a bar re-strikes its bass (quieter) and rotates its upper
    notes by one, so two bars of the same harmony are not two identical
    bars - the inner voices keep moving even when the chord does not.
    """
    bar = first_bar
    for (nb, bass, ups, label) in prog:
        for k in range(int(nb)):
            u = ups[k % len(ups):] + ups[:k % len(ups)] if (k and restrike) else ups
            p.lh(bar, bass if (k == 0 or restrike) else None, u,
                 vel=vel * (1.0 if k == 0 else 0.86), label=label, offs=offs)
            bar += 1
    return bar


def _colour(p, inst, name, gain, pan, reverb, events, humanise=1.1):
    tr = p.track(inst, name, gain=gain, pan=pan, humanise=humanise, reverb=reverb)
    for (t, d, m, v) in events:
        tr.note(t, d, m, v)
    return tr


def pad_bed(p, inst, name, gain, pan, reverb, spans, humanise=0.4):
    """A pad written as [(bar, bars, [notes]), ...] - one long note a voice.

    A pad is not a chord track: it holds two or three notes ACROSS the
    piano's chord changes and lets the piano supply the colour that moves.
    That is why it can be quiet and still glue the arrangement.
    """
    ev = []
    for (bar, nb, notes) in spans:
        dur = nb * p.beats_per_bar - 0.2
        for i, nte in enumerate(notes):
            ev.append((p.b(bar), dur, nte, 0.40 - 0.03 * i))
    return _colour(p, inst, name, gain, pan, reverb, ev, humanise=humanise)


def arp_line(p, inst, name, gain, pan, reverb, runs, step=0.5, dur=0.9,
             vel=0.26, humanise=0.8):
    """A slow arpeggio: [(start_beat, [notes]), ...], one note every `step`."""
    ev = []
    for (t0, notes) in runs:
        for i, nte in enumerate(notes):
            ev.append((t0 + i * step, dur, nte, vel * (1.0 - 0.035 * i)))
    return _colour(p, inst, name, gain, pan, reverb, ev, humanise=humanise)


# ===========================================================================
# 1. island_tropical - Starter Cove. F lydian <-> mixolydian, 60 BPM, 40 bars
# ===========================================================================
#
# The warmest and the simplest, and the only theme that changes MODE inside
# itself: the B natural of F lydian and the Eb of F mixolydian are both in
# it, and which one is sounding is how you know where you are in the form.
# Layers: the grand has the tune, a celesta doubles it an octave up at the
# phrase ends, a harp arpeggiates through the changes, a warm pad holds two
# notes under everything, a soft choir "ooh" answers in the return, and the
# solo violin does not exist until bar 22.

def island_tropical(rng):
    p = M.Nocturne("island_tropical", bpm=60.0, bars=40, tail=TAIL, lufs=-20.0,
                   width=0.38, sympathetic=0.17, humanise=0.030, spread=0.28,
                   room=(1.8, 0.66, 0.18, 0.021))
    b = p.b

    # -- harmony: one chord a bar, over an F pedal that only moves twice.
    lay(p, 0, [
        (1, "F2", ["C3", "E3", "A3"], "Fmaj9"),
        (1, "F2", ["C3", "E3", "G3"], "Fmaj9 (inner step)"),
        (1, "F2", ["C3", "E3", "B3"], "Fmaj7#11"),
        (1, "F2", ["D3", "E3", "B3"], "Fmaj13#11"),
        (1, "F2", ["G3", "C4", "E4"], "C/F"),
        (1, "F2", ["G3", "B3", "E4"], "Cmaj7#11/F"),
        (1, "F2", ["C3", "D3", "A3"], "F6/9"),
        (1, "F2", ["C3", "D3", "G3"], "Fsus2add6"),
        (1, "F2", ["Bb2", "E3", "G3"], "Fmaj7sus4"),
        (1, "F2", ["A2", "E3", "G3"], "Fmaj9 (open)"),
    ], vel=0.21)
    lay(p, 10, [
        (1, "F2", ["C3", "E3", "A3"], "Fmaj9"),
        (1, "E2", ["B2", "G3", "D4"], "Em11"),
        (1, "D2", ["A2", "C3", "G3"], "Dm11"),
        (1, "C#2", ["G#2", "C3", "F3"], "C#dim7 (passing)"),
        (1, "C2", ["G2", "E3", "D4"], "Cmaj9"),
        (1, "Bb1", ["F2", "D3", "C4"], "Bb6/9"),
        (1, "A1", ["E2", "C3", "G3"], "Am11"),
        (1, "Bb1", ["F2", "Eb3", "C4"], "Bb7sus4 (mixolydian Eb)"),
        (1, "C2", ["G2", "Bb2", "F3"], "C7sus4"),
        (1, "D2", ["A2", "F3", "E4"], "Dm(maj9)"),
    ], vel=0.22)
    # the quiet middle: two low notes, then ONE pedal F under the violin
    p.lh(20, "Bb1", ["F2", "D3"], vel=0.18, label="Bbmaj9", offs=[2.0, 3.0],
         hold=6.0, bass_hold=8.0)
    p.lh(21, None, ["Eb3", "A3"], vel=0.15, label="Bb7#11 (mixolydian)",
         offs=[1.0, 3.0], hold=5.0)
    p.lh(22, "F2", ["C3", "G3"], vel=0.18, label="Fsus2 (pedal)", offs=[2.5, 3.5],
         hold=12.0, bass_hold=16.0)
    p.lh(24, None, ["A3", "E4"], vel=0.15, label="Fmaj9", offs=[1.0, 2.5], hold=8.0)
    p.lh(25, None, ["G3", "D4"], vel=0.14, label="Fmaj13", offs=[1.5, 3.0], hold=5.0)
    # the return: one chord a bar again, richer, with the borrowed Eb major
    lay(p, 26, [
        (1, "F2", ["C3", "E3", "A3"], "Fmaj9"),
        (1, "F2", ["C3", "G3", "E4"], "Fmaj9/9"),
        (1, "F2", ["C3", "E3", "B3"], "Fmaj7#11"),
        (1, "F2", ["D3", "G3", "B3"], "Fmaj13#11"),
        (1, "G2", ["D3", "F3", "B3"], "G7/6 (lydian II)"),
        (1, "A2", ["E3", "G3", "D4"], "Am7add11"),
        (1, "D2", ["A2", "F3", "E4"], "Dm(maj9)"),
        (1, "Eb2", ["Bb2", "G3", "D4"], "Ebmaj9 (borrowed)"),
        (1, "F2", ["C3", "E3", "G3"], "Fmaj13"),
        (1, "F2", ["C3", "E3", "D4"], "Fmaj13 (6th on top)"),
    ], vel=0.28)
    lay(p, 36, [
        (1, "D2", ["A2", "F3"], "Dm11"),
        (1, "Bb1", ["F2", "C3"], "Bbmaj9"),
        (1, "F2", ["C3", "E3"], "Fmaj7"),
        (1, "C2", ["G2", "D3"], "Csus2 (lead-in)"),
    ], vel=0.19)
    p.mel([
        (b(0, 1.0), 1.0, "A4", 0.44), (b(0, 2.0), 1.0, "B4", 0.44),
        (b(0, 3.0), 5.0, "C5", 0.50),
        (b(2, 1.0), 1.0, "A4", 0.42), (b(2, 2.0), 1.0, "B4", 0.42),
        (b(2, 3.0), 5.0, "D5", 0.49),
        (b(4, 1.0), 1.0, "A4", 0.44), (b(4, 2.0), 1.0, "B4", 0.44),
        (b(4, 3.0), 1.0, "C5", 0.47), (b(5, 0.0), 1.0, "D5", 0.50),
        (b(5, 1.0), 7.0, "C5", 0.49),
        (b(6, 1.0), 1.0, "B4", 0.38), (b(6, 2.0), 1.0, "A4", 0.38),
        (b(6, 3.0), 5.0, "G4", 0.43),
        (b(8, 2.0), 6.0, "C5", 0.40),
    ])
    p.grace(b(10, 1.0), 1.0, "A4", "G4", 0.47)
    p.mel([
        (b(10, 2.0), 1.0, "B4", 0.47), (b(10, 3.0), 2.0, "C5", 0.50),
        (b(11, 1.0), 1.0, "D5", 0.50), (b(11, 2.0), 6.0, "E5", 0.53),
        (b(13, 1.0), 1.0, "D5", 0.44), (b(13, 2.0), 1.0, "C5", 0.44),
        (b(13, 3.0), 5.0, "B4", 0.46),
        (b(15, 1.0), 1.0, "A4", 0.45), (b(15, 2.0), 1.0, "C5", 0.47),
        (b(15, 3.0), 6.0, "D5", 0.49),
        (b(17, 1.0), 1.0, "C5", 0.41), (b(17, 2.0), 1.0, "B4", 0.41),
        (b(17, 3.0), 5.0, "A4", 0.43),
        # the middle: high, sparse, one borrowed Eb
        (b(18, 2.0), 4.0, "F5", 0.35), (b(19, 2.0), 4.0, "Eb5", 0.33),
        (b(20, 2.0), 4.0, "D5", 0.34), (b(21, 2.0), 6.0, "C5", 0.33),
        (b(23, 2.0), 4.0, "A4", 0.29), (b(25, 2.0), 5.0, "G4", 0.29),
        # the return
        (b(26, 1.0), 1.0, "A4", 0.56), (b(26, 2.0), 1.0, "B4", 0.56),
        (b(26, 3.0), 5.0, "C5", 0.62),
        (b(28, 1.0), 1.0, "A4", 0.53), (b(28, 2.0), 1.0, "B4", 0.53),
        (b(28, 3.0), 5.0, "D5", 0.60),
    ])
    p.turn(b(30, 1.0), "C5", "D5", "B4", 0.56)
    p.mel([
        (b(30, 3.0), 1.0, "D5", 0.59), (b(31, 0.0), 1.0, "F5", 0.60),
        (b(31, 1.0), 7.0, "E5", 0.64),
        (b(33, 1.0), 1.0, "D5", 0.50), (b(33, 2.0), 1.0, "C5", 0.50),
        (b(33, 3.0), 5.0, "A4", 0.51),
        (b(34, 2.0), 6.0, "C5", 0.38), (b(35, 2.0), 6.0, "A4", 0.35),
        (b(36, 2.0), 6.0, "G4", 0.34), (b(37, 2.0), 6.0, "F4", 0.32),
        (b(38, 2.0), 5.0, "C5", 0.32), (b(39, 2.0), 2.0, "G4", 0.29),
    ])

    p.pedal_bars(0, 10, per=2)
    p.pedal_bars(10, 10, per=1)
    p.pedal_bars(20, 2, per=1)
    p.pedal(b(22), b(26))
    p.pedal_bars(26, 8, per=1)
    p.pedal_bars(34, 6, per=2)

    # -- layers
    _colour(p, M.violin_solo, "violin", 0.95, 0.18, (2.0, 0.70, 0.20, 0.030), [
        (b(22, 1.0), 4.0, "A4", 0.30), (b(23, 1.0), 3.5, "B4", 0.28),
        (b(24, 2.0), 5.0, "C5", 0.32), (b(25, 3.0), 2.5, "A4", 0.24),
        (b(27, 0.0), 5.0, "F4", 0.32), (b(29, 0.0), 4.0, "G4", 0.33),
        (b(31, 0.0), 6.0, "A4", 0.36), (b(33, 0.0), 5.0, "F4", 0.30),
        (b(35, 0.0), 6.0, "E4", 0.24),
    ])
    # the celesta doubles the tune an octave up, but only its LAST note - it
    # lights the end of a phrase rather than shadowing the whole line
    _colour(p, M.celesta, "celesta", 0.52, 0.26, (2.4, 0.58, 0.24, 0.028), [
        (b(0, 3.0), 2.5, "C6", 0.34), (b(2, 3.0), 2.5, "D6", 0.32),
        (b(5, 1.0), 3.0, "C6", 0.34), (b(6, 3.0), 2.5, "G5", 0.28),
        (b(11, 2.0), 3.0, "E6", 0.36), (b(13, 3.0), 2.5, "B5", 0.30),
        (b(15, 3.0), 3.0, "D6", 0.32), (b(17, 3.0), 2.5, "A5", 0.28),
        (b(26, 3.0), 2.5, "C6", 0.40), (b(28, 3.0), 2.5, "D6", 0.38),
        (b(31, 1.0), 3.5, "E6", 0.44), (b(33, 3.0), 3.0, "A5", 0.34),
        (b(38, 2.0), 3.0, "C6", 0.26),
    ], humanise=0.6)
    arp_line(p, M.harp_air, "harp", 0.40, -0.24, (2.6, 0.66, 0.24, 0.032), [
        (b(4, 0.5), ["F3", "A3", "C4", "E4", "G4"]),
        (b(8, 0.5), ["F3", "Bb3", "E4", "G4"]),
        (b(12, 0.5), ["D3", "A3", "C4", "G4"]),
        (b(14, 0.5), ["Bb2", "F3", "D4", "C5"]),
        (b(16, 0.5), ["A2", "E3", "G3", "C4", "E4"]),
        (b(26, 0.5), ["F3", "A3", "C4", "E4", "G4", "C5"]),
        (b(30, 0.5), ["G3", "B3", "D4", "F4", "A4"]),
        (b(32, 0.5), ["D3", "A3", "F4", "E5"]),
    ], step=0.5, dur=1.6, vel=0.27)
    pad_bed(p, M.warm_pad_syn, "pad", 0.34, 0.0, (2.8, 0.70, 0.22, 0.036), [
        (0, 4, ["F3", "C4"]), (4, 4, ["G3", "C4"]), (8, 2, ["F3", "Bb3"]),
        (10, 4, ["F3", "C4"]), (14, 4, ["F3", "D4"]),
        (20, 2, ["Bb3", "D4"]), (22, 4, ["F3", "C4"]),
        (26, 4, ["F3", "C4"]), (30, 4, ["G3", "D4"]), (34, 4, ["F3", "C4"]),
    ])
    _colour(p, M.choir_ooh, "choir", 0.30, -0.20, (2.4, 0.74, 0.22, 0.040), [
        (b(26, 0.0), 7.5, "F3", 0.40), (b(28, 0.0), 7.5, "A3", 0.38),
        (b(30, 0.0), 7.5, "C4", 0.40), (b(32, 0.0), 7.0, "A3", 0.34),
    ], humanise=0.6)
    _colour(p, M.shimmer_syn, "air", 0.30, 0.30, (3.0, 0.60, 0.26, 0.040), [
        (b(16, 0.0), 8.0, "F3", 0.34), (b(26, 0.0), 8.0, "F3", 0.38),
        (b(30, 0.0), 8.0, "G3", 0.36),
    ], humanise=0.3)
    # one reversed piano note swells INTO the return
    _colour(p, M.piano_reverse, "rev", 0.50, 0.0, (2.2, 0.68, 0.22, 0.026), [
        (b(24, 2.0), 2.0, "F4", 0.40), (b(25, 2.0), 2.0, "C5", 0.42),
    ], humanise=0.0)
    return p


# ===========================================================================
# 2. island_swamp - Blackmire Fen. D dorian + blues colour, 54 BPM, 37 bars
# ===========================================================================
#
# Mysterious, not sad. Dorian keeps the sixth major so the mode never settles
# into the minor you expect, and on top of that the fen is the only theme
# with BLUES inflection: the b3 (F) and the natural 3 (F#) are both used, the
# b5 (Ab) appears as a passing colour, and the b7 (C) is permanent. Nothing
# else in the game does that. Everything sits a register lower than the cove.
# Layers: low grand, celli, a woodwind reed answering underneath, a music box
# that has been in the damp (two combs, one nine cents flat), and a dark synth
# drone that lives at 150-400 Hz and never below.

def island_swamp(rng):
    p = M.Nocturne("island_swamp", bpm=54.0, bars=37, tail=TAIL, lufs=-20.0,
                   tilt=-0.9, width=0.34, sympathetic=0.19, humanise=0.034,
                   spread=0.26, room=(2.0, 0.72, 0.20, 0.026))
    b = p.b
    lay(p, 0, [
        (1, "D2", ["A2", "F3", "E4"], "Dm(add9)"),
        (1, "D2", ["A2", "F3", "G4"], "Dm11"),
        (1, "D2", ["A2", "C4", "G4"], "Dm11 (b7 on top)"),
        (1, "D2", ["A2", "C4", "F4"], "Dm7"),
        (1, "C2", ["G2", "E3", "D4"], "Cmaj9"),
        (1, "C2", ["G2", "E3", "A3"], "C6/9"),
        (1, "D2", ["A2", "F3", "B3"], "Dm6/9 (dorian 6)"),
        (1, "Ab1", ["Eb2", "B3", "F4"], "Ab7#11 (blue b5)"),
    ], vel=0.20)
    lay(p, 8, [
        (1, "Bb1", ["F2", "D3", "E4"], "Bbmaj7#11"),
        (1, "Bb1", ["F2", "D3", "A3"], "Bbmaj9"),
        (1, "G2", ["D3", "B3", "F4"], "G7/6 (dorian IV)"),
        (1, "G2", ["D3", "Bb3", "F4"], "Gm7 (blue b3)"),
        (1, "A2", ["E3", "G3", "D4"], "Am7add11"),
        (1, "A2", ["E3", "G3", "C4"], "Am11"),
        (1, "D2", ["A2", "C4", "E4"], "Dm11"),
        (1, "D2", ["A2", "C4", "F#4"], "D7 (dorian major 3)"),
    ], vel=0.22)
    # the middle: the piano nearly stops. Three low notes in eight bars.
    p.lh(16, "D2", ["A2"], vel=0.16, label="D pedal", offs=[2.5], hold=10.0,
         bass_hold=12.0)
    p.lh(19, "Bb1", ["F2", "D3"], vel=0.16, label="Bbmaj9", offs=[2.0, 3.0],
         hold=8.0, bass_hold=10.0)
    p.lh(22, None, ["E3", "A3", "D4"], vel=0.15, label="Asus4 over D",
         offs=[1.0, 2.0, 3.0], hold=8.0)
    lay(p, 24, [
        (1, "D2", ["A2", "F3", "E4"], "Dm(add9)"),
        (1, "D2", ["A2", "F3", "B3"], "Dm6/9"),
        (1, "F2", ["C3", "A3", "E4"], "Fmaj7"),
        (1, "E2", ["B2", "G3", "D4"], "Em11 (dorian ii)"),
        (1, "Bb1", ["F2", "D3", "A3"], "Bbmaj9"),
        (1, "Bb1", ["F2", "Eb3", "A3"], "Bbmaj7#11 (Eb passing)"),
        (1, "G2", ["D3", "F3", "B3"], "G7sus4/6"),
        (1, "G2", ["D3", "F3", "Bb3"], "Gm11 (blue b3)"),
    ], vel=0.25)
    lay(p, 32, [
        (1, "D2", ["A2", "C4"], "Dm11"),
        (1, "D2", ["A2", "F3"], "Dm9"),
        (1, "C2", ["G2", "E3"], "Cmaj9"),
        (1, "Bb1", ["F2", "D3"], "Bbmaj7"),
        (1, "D2", ["A2", "E3"], "Dsus2 (lead-in)"),
    ], vel=0.18)

    p.mel([
        (b(0, 1.5), 1.0, "D4", 0.42), (b(0, 2.5), 1.0, "E4", 0.42),
        (b(0, 3.5), 4.5, "F4", 0.47),
        (b(2, 1.5), 1.0, "D4", 0.40), (b(2, 2.5), 1.0, "E4", 0.40),
        (b(2, 3.5), 4.5, "G4", 0.46),
        (b(4, 2.0), 1.0, "E4", 0.41), (b(4, 3.0), 1.0, "D4", 0.41),
        (b(5, 0.0), 6.0, "B3", 0.44),
        (b(6, 3.0), 5.0, "A3", 0.39),
    ])
    p.grace(b(8, 1.5), 1.0, "D4", "C4", 0.45)
    p.mel([
        (b(8, 2.5), 1.0, "F4", 0.46), (b(8, 3.5), 3.0, "G4", 0.48),
        (b(9, 2.5), 5.5, "A4", 0.50),
        (b(11, 2.0), 1.0, "G4", 0.43), (b(11, 3.0), 1.0, "F4", 0.43),
        (b(12, 0.0), 6.0, "E4", 0.46),
        (b(13, 3.0), 1.0, "D4", 0.42), (b(14, 0.0), 1.0, "F4", 0.44),
        (b(14, 1.0), 6.0, "E4", 0.45),
        # the middle - almost nothing
        (b(17, 1.0), 5.0, "A3", 0.28), (b(18, 2.0), 5.0, "D4", 0.27),
        (b(20, 1.0), 5.0, "F4", 0.28), (b(21, 2.0), 6.0, "D4", 0.26),
        (b(23, 1.0), 5.0, "C4", 0.25),
        # the return, the melody an octave up for the only time
        (b(24, 1.5), 1.0, "D5", 0.50), (b(24, 2.5), 1.0, "E5", 0.50),
        (b(24, 3.5), 4.5, "F5", 0.56),
        (b(26, 1.5), 1.0, "D5", 0.48), (b(26, 2.5), 1.0, "C5", 0.48),
        (b(27, 0.0), 6.0, "B4", 0.53),
    ])
    p.turn(b(28, 1.5), "A4", "B4", "G4", 0.50)
    p.mel([
        (b(28, 3.0), 5.0, "F4", 0.49),
        (b(30, 1.5), 1.0, "G4", 0.45), (b(30, 2.5), 1.0, "A4", 0.46),
        (b(31, 0.0), 6.0, "D4", 0.47),
        (b(32, 2.0), 6.0, "F4", 0.34), (b(33, 2.0), 6.0, "E4", 0.31),
        (b(34, 2.0), 6.0, "D4", 0.30), (b(35, 2.0), 5.0, "A3", 0.28),
        (b(36, 2.0), 2.0, "C4", 0.26),
    ])

    p.pedal_bars(0, 16, per=2)
    p.pedal(b(16), b(19))
    p.pedal(b(19), b(22))
    p.pedal(b(22), b(24))
    p.pedal_bars(24, 8, per=1)
    p.pedal_bars(32, 5, per=2)

    _colour(p, M.strings_sec_lo, "celli", 0.42, -0.16, (2.6, 0.76, 0.22, 0.036), [
        (b(9, 0.0), 5.0, "D3", 0.40), (b(11, 0.0), 5.0, "F3", 0.38),
        (b(13, 0.0), 6.0, "E3", 0.40),
        (b(24, 0.0), 6.0, "A2", 0.44), (b(26, 0.0), 6.0, "Bb2", 0.42),
        (b(28, 0.0), 6.0, "A2", 0.44), (b(30, 0.0), 6.0, "D3", 0.40),
    ], humanise=0.7)
    _colour(p, M.winds_sec, "reed", 0.34, 0.22, (2.2, 0.74, 0.20, 0.030), [
        (b(17, 2.0), 4.0, "D3", 0.36), (b(19, 2.0), 4.0, "F3", 0.34),
        (b(21, 2.0), 5.0, "C3", 0.33), (b(23, 2.0), 4.0, "A2", 0.30),
        (b(5, 2.0), 4.0, "A2", 0.30), (b(12, 2.0), 4.0, "C3", 0.30),
        (b(29, 1.0), 5.0, "Bb2", 0.32), (b(33, 1.0), 5.0, "D3", 0.28),
    ], humanise=0.8)
    # the worn music box answers the tune a tenth up, four times
    _colour(p, M.music_box_worn, "box", 0.38, 0.28, (2.8, 0.70, 0.26, 0.034), [
        (b(2, 2.0), 2.5, "A4", 0.30), (b(6, 2.0), 2.5, "F4", 0.28),
        (b(10, 2.0), 2.5, "D5", 0.32), (b(14, 2.0), 2.5, "A4", 0.28),
        (b(20, 1.0), 3.0, "F4", 0.24), (b(26, 2.0), 2.5, "D5", 0.34),
        (b(30, 2.0), 2.5, "A4", 0.30), (b(35, 1.0), 3.0, "D4", 0.22),
    ], humanise=0.7)
    pad_bed(p, M.drone_syn_dark, "drone", 0.36, -0.06, (3.0, 0.80, 0.24, 0.042), [
        (0, 8, ["D3", "A3"]), (8, 4, ["Bb2", "F3"]), (12, 4, ["D3", "A3"]),
        (16, 6, ["D3", "A3"]), (24, 4, ["D3", "A3"]), (28, 4, ["Bb2", "F3"]),
        (32, 5, ["D3", "A3"]),
    ])
    return p


# ===========================================================================
# 3. island_ice - Frostmaw Reach. C lydian + whole-tone, 54 BPM, 36 bars
# ===========================================================================
#
# Cold is a register and a spacing: everything above C5 in the right hand,
# one low note every two bars in the left, and NOTHING in the middle where
# warmth lives. The F# of the lydian mode rings against the C under the pedal
# for bars at a time, and twice a section the harmony slips into a WHOLE-TONE
# chord - the only scale in the game with no semitone in it, which is why it
# sounds like nothing is holding it up. Layers: high grand, glass bells, a far
# glockenspiel, the string section sitting ABOVE the piano, a slow synth arp,
# and an icy shimmer that exists only above 2 kHz.

def island_ice(rng):
    p = M.Nocturne("island_ice", bpm=54.0, bars=36, tail=TAIL, lufs=-20.0,
                   tilt=0.55, width=0.44, sympathetic=0.24, humanise=0.038,
                   spread=0.34, room=(2.2, 0.60, 0.22, 0.026))
    b = p.b
    lay(p, 0, [
        (1, "C2", ["G2", "E4", "B4"], "Cmaj9"),
        (1, "C2", ["G2", "E4", "D5"], "Cmaj9 (9 on top)"),
        (1, "C2", ["G2", "F#4", "B4"], "Cmaj7#11"),
        (1, "C2", ["A3", "F#4", "B4"], "Cmaj13#11"),
        (1, "C2", ["A3", "E4", "D5"], "C6/9"),
        (1, "D2", ["A3", "E4", "B4"], "Dsus2add13"),
        (1, "A1", ["E3", "C4", "B4"], "Am(add9)"),
        (1, "A1", ["E3", "D4", "B4"], "Am11"),
    ], vel=0.20)
    lay(p, 8, [
        (1, "G2", ["D3", "F#4", "C5"], "Gmaj7#11"),
        (1, "G2", ["D3", "B3", "A4"], "Gmaj9"),
        (1, "B1", ["F#3", "D4", "A4"], "Bm11"),
        (1, "B1", ["F#3", "E4", "A4"], "Bm7add11"),
        (1, "E2", ["B2", "G4", "D5"], "Em11"),
        (1, "Eb2", ["A2", "D4", "G4"], "Eb+ (whole tone)"),
        (1, "C2", ["G2", "E4", "D5"], "Cmaj9"),
        (1, "D2", ["G#2", "C4", "F#4"], "D7#11 (whole tone)"),
    ], vel=0.22)
    p.lh(16, "D2", ["A3", "E4"], vel=0.16, label="Dsus2/9", offs=[2.0, 3.0],
         hold=7.0, bass_hold=8.0)
    p.lh(17, None, ["B3", "F#4"], vel=0.14, label="D6/9", offs=[1.5, 3.0], hold=5.0)
    p.lh(18, "F#1", ["C#3", "A3", "E4"], vel=0.16, label="F#m11 (borrowed)",
         offs=[1.5, 2.5, 3.5], hold=6.0, bass_hold=8.0)
    p.lh(19, None, ["B3", "E4"], vel=0.13, label="F#m11 (open)", offs=[2.0, 3.5], hold=4.0)
    p.lh(20, "C2", ["G3", "D4"], vel=0.15, label="Csus2 (pedal)", offs=[2.0, 3.0],
         hold=12.0, bass_hold=16.0)
    p.lh(22, None, ["E4", "B4"], vel=0.14, label="Cmaj9", offs=[1.0, 2.5], hold=8.0)
    p.lh(23, None, ["F#4", "A4"], vel=0.13, label="Cmaj7#11", offs=[1.5, 3.0], hold=5.0)
    lay(p, 24, [
        (1, "C2", ["G2", "E4", "B4"], "Cmaj9"),
        (1, "C2", ["G2", "D4", "B4"], "Cmaj13"),
        (1, "C2", ["G2", "F#4", "B4"], "Cmaj7#11"),
        (1, "C2", ["A3", "F#4", "D5"], "Cmaj13#11"),
        (1, "A1", ["E3", "C4", "G4"], "Am9"),
        (1, "Ab1", ["Eb3", "C4", "G4"], "Abmaj7 (borrowed)"),
        (1, "C2", ["G2", "D4", "A4"], "Cmaj13"),
        (1, "D2", ["G#2", "C4", "E4"], "D7#11 (whole tone)"),
    ], vel=0.26)
    lay(p, 32, [
        (1, "C2", ["G3", "E4"], "Cmaj9"),
        (1, "C2", ["G3", "D4"], "Csus2"),
        (1, "A1", ["E3", "B3"], "Am(add9)"),
        (1, "C2", ["G2", "D4"], "Csus2 (lead-in)"),
    ], vel=0.17)

    p.mel([
        (b(0, 1.0), 3.0, "G5", 0.40), (b(1, 0.5), 4.0, "F#5", 0.38),
        (b(2, 2.0), 4.0, "E5", 0.40), (b(3, 2.0), 5.0, "G5", 0.37),
        (b(4, 1.0), 3.0, "B5", 0.42), (b(4, 3.0), 4.0, "A5", 0.38),
        (b(5, 3.0), 6.0, "F#5", 0.40),
        (b(7, 1.0), 5.0, "E5", 0.35),
        (b(8, 1.0), 2.0, "D5", 0.40), (b(8, 3.0), 3.0, "F#5", 0.42),
        (b(9, 2.0), 6.0, "A5", 0.44),
        (b(11, 1.0), 2.0, "G5", 0.38), (b(11, 3.0), 5.0, "D5", 0.39),
        (b(13, 1.0), 2.0, "B4", 0.36), (b(13, 3.0), 2.0, "E5", 0.38),
        (b(14, 1.0), 6.0, "G5", 0.41),
        # the middle
        (b(16, 2.0), 5.0, "E5", 0.28), (b(18, 2.0), 5.0, "C#5", 0.27),
        (b(20, 2.0), 5.0, "D5", 0.26), (b(22, 2.0), 6.0, "B4", 0.25),
        # the return, the climax on B5
        (b(24, 1.0), 3.0, "G5", 0.50), (b(25, 0.5), 4.0, "F#5", 0.48),
        (b(26, 1.0), 2.0, "A5", 0.52), (b(26, 3.0), 5.0, "B5", 0.55),
        (b(28, 1.0), 2.0, "G5", 0.46), (b(28, 3.0), 2.0, "E5", 0.45),
        (b(29, 1.0), 6.0, "D5", 0.47),
        (b(31, 1.0), 5.0, "C5", 0.40),
        (b(32, 2.0), 6.0, "E5", 0.30), (b(33, 2.0), 6.0, "B4", 0.28),
        (b(34, 2.0), 6.0, "G4", 0.26), (b(35, 2.0), 2.0, "D5", 0.25),
    ])

    p.pedal_bars(0, 16, per=2)
    p.pedal(b(16), b(20))
    p.pedal(b(20), b(24))
    p.pedal_bars(24, 8, per=1)
    p.pedal_bars(32, 4, per=2)

    _colour(p, M.strings_sec, "strings", 0.34, -0.22, (2.8, 0.62, 0.24, 0.038), [
        (b(9, 0.0), 6.0, "E5", 0.34), (b(11, 0.0), 6.0, "D5", 0.32),
        (b(13, 0.0), 6.0, "B4", 0.34),
        (b(24, 0.0), 7.0, "G5", 0.36), (b(26, 0.0), 7.0, "B5", 0.38),
        (b(28, 0.0), 7.0, "A5", 0.34), (b(30, 0.0), 6.0, "F#5", 0.32),
    ], humanise=0.7)
    _colour(p, M.glock_far, "glock", 0.28, 0.26, (2.6, 0.55, 0.26, 0.030), [
        (b(3, 2.0), 2.0, "G6", 0.30), (b(7, 1.0), 2.0, "E6", 0.28),
        (b(13, 3.0), 2.0, "B5", 0.28), (b(21, 2.0), 2.0, "D6", 0.24),
        (b(26, 3.0), 2.0, "B6", 0.30), (b(31, 1.0), 2.0, "C6", 0.24),
    ], humanise=0.5)
    # glass bells double the tune an octave up at the phrase ends
    _colour(p, M.glass_bell, "glass", 0.24, -0.30, (3.0, 0.52, 0.28, 0.034), [
        (b(1, 0.5), 3.0, "F#6", 0.26), (b(5, 3.0), 3.0, "F#6", 0.24),
        (b(9, 2.0), 3.5, "A6", 0.28), (b(14, 1.0), 3.5, "G6", 0.26),
        (b(22, 2.0), 3.5, "B5", 0.20), (b(26, 3.0), 3.5, "B6", 0.30),
        (b(29, 1.0), 3.5, "D6", 0.26), (b(34, 2.0), 3.0, "G5", 0.20),
    ], humanise=0.5)
    arp_line(p, M.pluck_syn, "arp", 0.30, 0.20, (2.8, 0.58, 0.26, 0.034), [
        (b(4, 0.0), ["C4", "E4", "G4", "B4", "D5"]),
        (b(10, 0.0), ["B3", "D4", "F#4", "A4", "C#5"]),
        (b(14, 0.0), ["C4", "E4", "G4", "D5"]),
        (b(24, 0.0), ["C4", "E4", "G4", "B4", "D5", "E5"]),
        (b(28, 0.0), ["A3", "C4", "E4", "G4", "B4"]),
        (b(30, 0.0), ["C4", "D4", "G4", "A4"]),
    ], step=0.75, dur=1.2, vel=0.24)
    _colour(p, M.shimmer_syn, "air", 0.24, 0.32, (3.2, 0.52, 0.30, 0.044), [
        (b(0, 0.0), 8.0, "C4", 0.34), (b(8, 0.0), 8.0, "G3", 0.34),
        (b(16, 0.0), 8.0, "D4", 0.28), (b(24, 0.0), 8.0, "C4", 0.38),
        (b(32, 0.0), 8.0, "C4", 0.28),
    ], humanise=0.3)
    return p


# ===========================================================================
# 4. island_volcano - Ashfall Caldera. E phrygian dominant, 58 BPM, 34 bars
# ===========================================================================
#
# Heat without speed. The pulse is in the BASS NOTES ONLY - a two-note piano
# ostinato in the bottom octave that never stops - and everything above it is
# held. The mode is E PHRYGIAN DOMINANT (E F G# A B C D): the flat second of
# phrygian with a MAJOR third over it, which is the interval that makes it
# sound scorched rather than merely dark. Where the tune plays a G natural
# the harmony drops back to plain phrygian, and that G/G# cross-relation
# between bars is deliberate - it is the only place two modes are audible at
# once. Layers: the grand's ostinato, soft brass, timpani a long way back, a
# choir "ahh", and a filtered synth pulse that marks the bar at 200-600 Hz
# and has no sub content at all.

def island_volcano(rng):
    p = M.Nocturne("island_volcano", bpm=58.0, bars=34, tail=TAIL, lufs=-20.0,
                   tilt=-1.1, width=0.36, sympathetic=0.15, humanise=0.028,
                   spread=0.24, room=(2.0, 0.74, 0.19, 0.024))
    b = p.b
    for bar in list(range(0, 16)) + list(range(22, 34)):
        v = 0.26 if bar < 16 else 0.29
        p.piano.note(b(bar, 0.0), 2.2, "E1", v)
        p.piano.note(b(bar, 2.5), 1.4, "B1", v * 0.78)
    OFF = [1.0, 1.75, 3.5]
    lay(p, 0, [
        (1, None, ["E3", "G3", "D4"], "Em11 (phrygian)"),
        (1, None, ["E3", "G3", "F4"], "Em11 b9"),
        (1, None, ["F3", "A3", "E4"], "Fmaj7#11 (bII)"),
        (1, None, ["F3", "C4", "E4"], "Fmaj9 (bII)"),
        (1, None, ["E3", "B3", "G#4"], "E(add9) MAJOR 3rd"),
        (1, None, ["E3", "B3", "F#4"], "Esus2"),
        (1, None, ["C3", "G3", "E4"], "Cmaj9"),
        (1, None, ["C3", "G#3", "E4"], "C+ (raised 5)"),
    ], vel=0.21, offs=OFF)
    lay(p, 8, [
        (1, None, ["A3", "C4", "G4"], "Am11"),
        (1, None, ["A3", "C4", "F4"], "Am(b6)"),
        (1, None, ["D3", "A3", "F4"], "Dm9"),
        (1, None, ["D3", "G#3", "F4"], "D7b5 (tritone)"),
        (1, None, ["F3", "C4", "A4"], "Fmaj9 (bII)"),
        (1, None, ["F3", "B3", "A4"], "Fmaj7#11 (bII)"),
        (1, None, ["E3", "G3", "D#4"], "Em(maj7) harmonic minor"),
        (1, None, ["E3", "G#3", "D4"], "E7 phrygian dominant"),
    ], vel=0.23, offs=OFF)
    p.lh(16, "E2", ["B2", "G3", "F4"], vel=0.17, label="Em(b9) held",
         offs=[1.5, 2.5, 3.5], hold=9.0, bass_hold=12.0)
    p.lh(19, "C2", ["G2", "E3", "B3"], vel=0.17, label="Cmaj9",
         offs=[1.5, 2.5, 3.5], hold=9.0, bass_hold=12.0)
    lay(p, 22, [
        (1, None, ["E3", "G3", "D4"], "Em11"),
        (1, None, ["E3", "A3", "D4"], "Esus4add11"),
        (1, None, ["F3", "A3", "E4"], "Fmaj7#11 (bII)"),
        (1, None, ["F3", "C4", "G#4"], "Fmaj7#5 (bII)"),
        (1, None, ["C3", "G3", "E4"], "Cmaj9"),
        (1, None, ["C3", "G3", "D4"], "Cmaj9 (9 on top)"),
        (1, None, ["B2", "F#3", "D#4"], "B(maj7) leading tone"),
        (1, None, ["B2", "F3", "D#4"], "B7b5 (tritone)"),
    ], vel=0.27, offs=OFF)
    lay(p, 30, [
        (1, None, ["E3", "B3", "G4"], "Em(add9)"),
        (1, None, ["E3", "G3", "D4"], "Em11"),
        (1, None, ["F3", "A3", "C4"], "F (bII)"),
        (1, None, ["E3", "B3"], "E5 (lead-in)"),
    ], vel=0.18, offs=[1.5, 3.0, 3.75])

    p.mel([
        (b(0, 1.5), 3.0, "B4", 0.40), (b(1, 1.5), 4.0, "G4", 0.38),
        (b(2, 1.5), 3.0, "A4", 0.41), (b(3, 1.5), 4.5, "F4", 0.42),
        (b(4, 1.5), 3.0, "B4", 0.40), (b(5, 1.5), 5.0, "E5", 0.44),
        (b(7, 1.5), 4.0, "D5", 0.38),
        (b(8, 1.5), 3.0, "C5", 0.42), (b(9, 1.5), 4.0, "B4", 0.41),
        (b(10, 1.5), 3.0, "A4", 0.43), (b(11, 1.5), 5.0, "D5", 0.45),
        (b(13, 1.5), 3.0, "C5", 0.40), (b(14, 1.5), 5.0, "B4", 0.42),
        (b(16, 2.0), 6.0, "G4", 0.28), (b(18, 2.0), 6.0, "F4", 0.27),
        (b(20, 2.0), 6.0, "E4", 0.26),
    ])
    p.grace(b(22, 1.5), 3.0, "B4", "A4", 0.50)
    p.mel([
        (b(23, 1.5), 4.0, "G4", 0.48),
        (b(24, 1.5), 3.0, "C5", 0.52), (b(25, 1.5), 5.0, "A4", 0.50),
        (b(27, 1.5), 3.0, "D5", 0.54), (b(28, 1.5), 5.0, "E5", 0.57),
        (b(30, 1.5), 5.0, "B4", 0.38), (b(31, 1.5), 5.0, "G4", 0.34),
        (b(32, 1.5), 5.0, "F4", 0.31), (b(33, 2.0), 2.0, "E4", 0.28),
    ])

    p.pedal_bars(0, 16, per=1)
    p.pedal(b(16), b(19))
    p.pedal(b(19), b(22))
    p.pedal_bars(22, 8, per=1)
    p.pedal_bars(30, 4, per=2)

    _colour(p, M.brass_sec, "brass", 0.26, -0.14, (2.4, 0.78, 0.20, 0.034), [
        (b(9, 0.0), 6.0, "E3", 0.32), (b(11, 0.0), 6.0, "D3", 0.30),
        (b(13, 0.0), 6.0, "C3", 0.32),
        (b(24, 0.0), 7.0, "E3", 0.38), (b(26, 0.0), 7.0, "F3", 0.36),
        (b(28, 0.0), 7.0, "G#3", 0.38), (b(30, 0.0), 6.0, "E3", 0.30),
    ], humanise=0.6)
    _colour(p, M.choir_ahh, "choir", 0.24, 0.18, (3.2, 0.78, 0.26, 0.050), [
        (b(22, 0.0), 7.5, "E3", 0.34), (b(24, 0.0), 7.5, "F3", 0.32),
        (b(26, 0.0), 7.5, "G#3", 0.34), (b(28, 0.0), 7.0, "B3", 0.32),
    ], humanise=0.5)
    # timpani a long way back: a swell under the bar, four times a section
    _colour(p, M.timpani_s, "timp", 0.20, 0.0, (3.4, 0.84, 0.30, 0.055), [
        (b(4, 0.0), 2.0, "E1", 0.34), (b(12, 0.0), 2.0, "E1", 0.32),
        (b(22, 0.0), 2.0, "E1", 0.40), (b(28, 0.0), 2.0, "B1", 0.36),
    ], humanise=0.2)
    _colour(p, M.pulse_syn_low, "pulse", 0.34, 0.10, (2.2, 0.76, 0.20, 0.028), [
        (b(bar, 0.0), 1.6, "E2", 0.30) for bar in range(0, 16, 2)
    ] + [
        (b(bar, 0.0), 1.6, "E2", 0.34) for bar in range(22, 34, 2)
    ], humanise=0.3)
    return p


# ===========================================================================
# 5. island_gloom - Gloomtrench. A minor, min-maj7 + quartal, 50 BPM, 36 bars
# ===========================================================================
#
# The sparsest thing in the game and the only one on the CLOSE Grand, which
# is drier and closer-miked and therefore lonelier: you hear the room stop.
# v4 had no key at all; v5 gives it A MINOR and then refuses to confirm it -
# the tonic chord is Am(maj7), whose raised seventh grinds a semitone under
# the octave and never resolves, and between those chords the harmony is
# quartal stacks that belong to no key. The silences are still longer than
# the phrases. Layers: Close Grand, a Rhodes answering from a long way back,
# a bowed-glass synth pad with no attack at all, and the solo violin playing
# HARMONICS - a touched string, almost no even partials, no weight.

def island_gloom(rng):
    p = M.Nocturne("island_gloom", bpm=50.0, bars=36, tail=TAIL, lufs=-20.0,
                   tilt=-1.4, width=0.30, sympathetic=0.22, humanise=0.044,
                   spread=0.22, room=(2.2, 0.80, 0.20, 0.030), bank="close")
    b = p.b
    OFF = [2.0, 3.5]
    lay(p, 0, [
        (1, "A1", ["E2", "C4", "G#4"], "Am(maj7)"),
        (1, "A1", ["E2", "B3", "G#4"], "Am(maj9)"),
        (1, None, ["D2", "G2", "C3"], "quartal, no root"),
        (1, None, ["D2", "A2", "E3"], "quintal, no root"),
        (1, "F1", ["C2", "E3", "A3"], "Fmaj7"),
        (1, "F1", ["C2", "E3", "B3"], "Fmaj7#11"),
        (1, None, ["G2", "C3", "F3"], "quartal"),
        (1, None, ["G2", "D3", "A3"], "quintal"),
    ], vel=0.19, offs=OFF)
    lay(p, 8, [
        (1, "D2", ["A2", "F3", "C#4"], "Dm(maj7)"),
        (1, "D2", ["A2", "Eb4"], "D + minor 9th"),
        (1, "Db2", ["Ab2", "Eb3", "Bb3"], "Dbsus2add9"),
        (1, "Db2", ["Ab2", "F3", "C4"], "Dbmaj7"),
        (1, "B1", ["F#2", "D3", "A#3"], "Bm(maj7)"),
        (1, "B1", ["F#2", "C4"], "B + minor 9th"),
        (1, None, ["E2", "A2", "D3"], "quartal"),
        (1, None, ["E2", "B2", "F#3"], "quintal, unresolved"),
    ], vel=0.20, offs=OFF)
    # the longest silence in the soundtrack: bars 16-23, six notes total
    p.piano.note(b(16, 1.0), 6.0, "A1", 0.17)
    p.piano.note(b(17, 2.0), 5.0, "C4", 0.15)
    p.piano.note(b(17, 3.0), 4.0, "G#4", 0.13)
    p.harmony[16] = "Am(maj7), alone"
    p.piano.note(b(19, 1.0), 6.0, "Eb2", 0.16)
    p.piano.note(b(20, 2.0), 5.0, "A3", 0.14)
    p.harmony[19] = "Eb + tritone, alone"
    p.piano.note(b(22, 2.0), 8.0, "F1", 0.16)
    p.harmony[22] = "F, nothing over it"
    lay(p, 24, [
        (1, "A1", ["E2", "C4", "G#4"], "Am(maj7)"),
        (1, "A1", ["E2", "C4", "F4"], "Am(b6)"),
        (1, "C2", ["G2", "E3", "B3"], "Cmaj9"),
        (1, "C2", ["G2", "Db4"], "C + minor 9th"),
        (1, None, ["F2", "Bb2", "Eb3"], "quartal"),
        (1, None, ["F2", "C3", "G3"], "quintal"),
        (1, "Ab1", ["Eb2", "C3", "G3"], "Abmaj7"),
        (1, "Ab1", ["Eb2", "A3"], "Ab + minor 9th"),
    ], vel=0.23, offs=OFF)
    lay(p, 32, [
        (1, "A1", ["E2", "C4"], "Am"),
        (1, "A1", ["E2", "G#4"], "Am(maj7)"),
        (1, None, ["D2", "G2", "C3"], "quartal"),
        (1, None, ["D2", "A2", "E3"], "quintal, unresolved"),
    ], vel=0.17, offs=OFF)

    p.mel([
        (b(1, 1.0), 5.0, "E4", 0.34), (b(3, 1.0), 5.0, "F4", 0.32),
        (b(5, 2.0), 6.0, "C4", 0.33), (b(7, 1.0), 5.0, "Bb3", 0.30),
        (b(9, 1.0), 4.0, "F4", 0.36), (b(10, 1.0), 5.0, "Eb4", 0.34),
        (b(12, 2.0), 6.0, "C4", 0.35), (b(14, 1.0), 6.0, "B3", 0.32),
        (b(17, 3.0), 5.0, "A4", 0.24), (b(21, 1.0), 6.0, "Bb4", 0.22),
        (b(25, 1.0), 4.0, "F4", 0.40), (b(26, 1.0), 4.0, "E4", 0.38),
        (b(27, 1.0), 5.0, "Db4", 0.41),
        (b(29, 1.0), 4.0, "Eb4", 0.42), (b(30, 1.0), 6.0, "A3", 0.40),
        (b(32, 2.0), 6.0, "E4", 0.28), (b(34, 2.0), 6.0, "Bb3", 0.25),
        (b(35, 2.0), 2.0, "C4", 0.22),
    ])

    p.pedal_bars(0, 16, per=2)
    p.pedal(b(16), b(19))
    p.pedal(b(19), b(22))
    p.pedal(b(22), b(24))
    p.pedal_bars(24, 8, per=2)
    p.pedal_bars(32, 4, per=2)

    _colour(p, M.rhodes_s, "rhodes", 0.22, 0.24, (3.0, 0.80, 0.30, 0.055), [
        (b(6, 2.0), 3.0, "A3", 0.30), (b(13, 2.0), 3.0, "F3", 0.28),
        (b(20, 2.0), 3.0, "Eb3", 0.26), (b(31, 2.0), 3.0, "A3", 0.28),
        (b(2, 2.0), 3.0, "D3", 0.24), (b(27, 2.0), 3.0, "C3", 0.26),
    ], humanise=0.6)
    _colour(p, M.violin_harmonic, "vln_harm", 0.70, -0.18, (3.0, 0.78, 0.26, 0.044), [
        (b(17, 0.0), 6.0, "E5", 0.30), (b(20, 0.0), 5.0, "Eb5", 0.28),
        (b(22, 1.0), 7.0, "C5", 0.26),
        (b(9, 0.0), 5.0, "A4", 0.26), (b(14, 0.0), 5.0, "B4", 0.24),
        (b(28, 0.0), 6.0, "F5", 0.32), (b(30, 0.0), 6.0, "E5", 0.30),
        (b(34, 0.0), 6.0, "A4", 0.24),
    ], humanise=1.0)
    pad_bed(p, M.glass_pad_syn, "glass_pad", 0.40, 0.08, (3.4, 0.82, 0.28, 0.055), [
        (0, 4, ["A3", "E4"]), (4, 4, ["F3", "C4"]), (8, 4, ["D3", "A3"]),
        (12, 4, ["B3", "F#4"]), (16, 4, ["A3", "E4"]), (20, 4, ["Eb3", "A3"]),
        (24, 4, ["A3", "E4"]), (28, 4, ["C4", "G4"]), (32, 4, ["A3", "E4"]),
    ])
    return p


# ===========================================================================
# 6. island_wreck - Wreckwater. G aeolian/phrygian, 6/8, 132 BPM, 57 bars
# ===========================================================================
#
# A lament in slow 6/8 - the dotted crotchet is at 44, a walking pace behind
# a coffin, not a waltz. The CELLI and the solo violin carry the tune; the
# piano is underneath for the whole first half and only takes it back at the
# return. The phrygian Ab is the salt, and the cadences are modal
# sea-shanty ones - bVII to i, bII to i - never a dominant. Layers: celli,
# solo violin, grand, an accordion-ish reed synth wheezing under the strings,
# and a sea-chime that tolls four times in three minutes.

def island_wreck(rng):
    p = M.Nocturne("island_wreck", bpm=132.0, bars=57, beats_per_bar=6,
                   tail=TAIL, lufs=-20.0, tilt=-0.7, width=0.36,
                   sympathetic=0.18, humanise=0.032, spread=0.26,
                   room=(2.4, 0.74, 0.21, 0.030))
    b = p.b
    OFF = [2.0, 4.0, 5.0]
    lay(p, 0, [
        (1, "G2", ["D3", "Bb3", "A4"], "Gm9"),
        (1, "G2", ["D3", "Bb3", "C4"], "Gm11"),
        (1, "F2", ["C3", "Bb3", "D4"], "F6/9 (bVII)"),
        (1, "Eb2", ["Bb2", "G3", "A4"], "Ebmaj7#11"),
        (1, "Eb2", ["Bb2", "G3", "D4"], "Ebmaj9"),
        (1, "D2", ["A2", "F3", "Bb3"], "Dm7b6"),
        (1, "C2", ["G2", "Eb3", "F4"], "Cm11"),
        (1, "C2", ["G2", "Eb3", "Bb3"], "Cm7"),
        (1, "Bb1", ["F2", "D3", "G3"], "Bb6"),
        (1, "Ab1", ["Eb2", "C3", "G3"], "Abmaj7 (phrygian bII)"),
        (1, "Ab1", ["Eb2", "C3", "Bb3"], "Abmaj9 (bII)"),
        (1, "G2", ["D3", "Bb3", "F4"], "Gm11 (modal bII-i)"),
    ], vel=0.19, offs=OFF)
    lay(p, 12, [
        (1, "D2", ["A2", "F3", "Eb4"], "Dm7b5 add b9"),
        (1, "D2", ["A2", "F3", "Bb3"], "Dm7b6"),
        (1, "Eb2", ["Bb2", "G3", "C4"], "Ebmaj13"),
        (1, "Bb1", ["F2", "D3", "C4"], "Bb6/9"),
        (1, "Bb1", ["F2", "D3", "G3"], "Bb6"),
        (1, "F2", ["C3", "A3", "D4"], "F6 (bVII)"),
        (1, "G2", ["D3", "E3", "Bb3"], "Gm6/9"),
        (1, "G2", ["D3", "Bb3", "A4"], "Gm9"),
        (1, "Eb2", ["Bb2", "G3", "D4"], "Ebmaj9"),
        (1, "F2", ["C3", "Ab3", "Eb4"], "Fm11"),
        (1, "F2", ["C3", "Ab3", "Db4"], "Fm7b9 (bII colour)"),
        (1, "G2", ["D3", "Bb3", "C4"], "Gm11 (bVII-i)"),
    ], vel=0.21, offs=OFF)
    p.lh(24, "G2", ["D3"], vel=0.16, label="G pedal", offs=[3.0], hold=16.0,
         bass_hold=24.0)
    p.lh(26, None, ["Bb3", "C4"], vel=0.13, label="Gm11 (open)", offs=[1.0, 4.0], hold=10.0)
    p.lh(28, None, ["Bb3", "F4"], vel=0.14, label="Gm11", offs=[1.0, 3.0], hold=12.0)
    p.lh(30, None, ["Eb4", "D4"], vel=0.13, label="Gm(b6)", offs=[2.0, 4.0], hold=8.0)
    p.lh(32, "Eb2", ["Bb2", "G3"], vel=0.15, label="Ebmaj9", offs=[2.0, 4.0],
         hold=12.0, bass_hold=18.0)
    p.lh(34, None, ["C4", "F4"], vel=0.13, label="Ebmaj13", offs=[1.0, 3.0], hold=10.0)
    lay(p, 36, [
        (1, "G2", ["D3", "Bb3", "A4"], "Gm9"),
        (1, "G2", ["D3", "C4", "A4"], "Gm11"),
        (1, "F2", ["C3", "Bb3", "D4"], "F6/9 (bVII)"),
        (1, "Eb2", ["Bb2", "G3", "D4"], "Ebmaj9"),
        (1, "Eb2", ["Bb2", "A3", "D4"], "Ebmaj7#11"),
        (1, "D2", ["A2", "F3", "C4"], "Dm11"),
        (1, "Ab1", ["Eb2", "C3", "Bb3"], "Abmaj9 (bII)"),
        (1, "Ab1", ["Eb2", "Db3", "Bb3"], "Absus2 (bII)"),
        (1, "Bb1", ["F2", "D3", "Eb4"], "Bbmaj7#11"),
        (1, "D2", ["A2", "F#3", "C4"], "D7b9 (raised 3rd)"),
        (1, "D2", ["A2", "F#3", "Eb4"], "D7b9"),
        (1, "G2", ["D3", "Bb3", "F4"], "Gm11"),
    ], vel=0.26, offs=OFF)
    lay(p, 48, [
        (1, "G2", ["D3", "Bb3"], "Gm9"),
        (1, "F2", ["C3", "Bb3"], "F6 (bVII)"),
        (1, "Eb2", ["Bb2", "G3"], "Ebmaj7"),
        (1, "C2", ["G2", "Eb3"], "Cm11"),
        (1, "C2", ["G2", "Bb3"], "Cm7"),
        (1, "Bb1", ["F2", "D3"], "Bbmaj9"),
        (1, "Ab1", ["Eb2", "C3"], "Abmaj7 (bII)"),
        (1, "G2", ["D3", "Bb3"], "Gm9"),
        (1, "Eb2", ["Bb2", "G3"], "Ebmaj7 (lead-in)"),
    ], vel=0.18, offs=OFF)

    p.mel([
        (b(3, 1.0), 2.0, "D4", 0.36), (b(3, 3.0), 3.0, "Eb4", 0.36),
        (b(4, 0.0), 6.0, "D4", 0.38),
        (b(9, 1.0), 2.0, "G4", 0.36), (b(9, 3.0), 3.0, "F4", 0.36),
        (b(10, 0.0), 6.0, "Eb4", 0.38),
        (b(15, 1.0), 2.0, "D4", 0.38), (b(15, 3.0), 2.0, "C4", 0.38),
        (b(16, 0.0), 7.0, "Bb3", 0.40),
        (b(21, 1.0), 3.0, "F4", 0.38), (b(21, 4.0), 5.0, "Eb4", 0.40),
        (b(28, 2.0), 6.0, "Bb4", 0.26), (b(31, 2.0), 6.0, "G4", 0.24),
        (b(34, 2.0), 6.0, "F4", 0.24),
        # the piano takes the tune back
        (b(36, 1.0), 2.0, "D5", 0.48), (b(36, 3.0), 3.0, "Eb5", 0.48),
        (b(37, 0.0), 6.0, "D5", 0.52),
        (b(39, 1.0), 2.0, "G5", 0.50), (b(39, 3.0), 2.0, "F5", 0.50),
        (b(40, 0.0), 6.0, "Eb5", 0.54),
    ])
    p.turn(b(42, 1.0), "D5", "Eb5", "C5", 0.50, step=0.5)
    p.mel([
        (b(42, 4.0), 5.0, "Bb4", 0.50),
        (b(45, 1.0), 3.0, "C5", 0.48), (b(45, 4.0), 6.0, "A4", 0.50),
        (b(48, 2.0), 6.0, "Bb4", 0.34), (b(50, 2.0), 6.0, "G4", 0.31),
        (b(52, 2.0), 6.0, "Eb4", 0.29), (b(54, 2.0), 6.0, "D4", 0.27),
        (b(56, 2.0), 3.0, "F4", 0.25),
    ])

    p.pedal_bars(0, 24, per=2)
    p.pedal(b(24), b(28))
    p.pedal(b(28), b(32))
    p.pedal(b(32), b(36))
    p.pedal_bars(36, 12, per=1)
    p.pedal_bars(48, 9, per=3)

    _colour(p, M.strings_sec_lo, "celli", 0.46, -0.18, (2.8, 0.76, 0.24, 0.038), [
        (b(0, 2.0), 4.0, "Bb2", 0.38), (b(3, 0.0), 5.0, "G2", 0.36),
        (b(6, 2.0), 5.0, "Bb2", 0.38), (b(9, 0.0), 5.0, "Eb3", 0.40),
        (b(12, 2.0), 5.0, "F2", 0.36), (b(15, 0.0), 5.0, "D3", 0.38),
        (b(18, 2.0), 5.0, "Bb2", 0.36), (b(21, 0.0), 6.0, "G2", 0.38),
        (b(36, 0.0), 6.0, "G2", 0.42), (b(39, 0.0), 6.0, "Eb2", 0.40),
        (b(42, 0.0), 6.0, "Ab2", 0.42), (b(45, 0.0), 6.0, "D3", 0.40),
    ], humanise=0.7)
    _colour(p, M.violin_solo, "violin", 0.90, 0.20, (2.6, 0.72, 0.22, 0.034), [
        (b(24, 1.0), 5.0, "D4", 0.30), (b(25, 3.0), 4.0, "Eb4", 0.29),
        (b(27, 1.0), 5.0, "D4", 0.31), (b(29, 0.0), 6.0, "G4", 0.33),
        (b(30, 3.0), 5.0, "F4", 0.30), (b(32, 1.0), 6.0, "Eb4", 0.32),
        (b(34, 0.0), 5.0, "D4", 0.28),
        (b(43, 0.0), 6.0, "Bb4", 0.30), (b(46, 0.0), 6.0, "A4", 0.28),
        (b(49, 0.0), 6.0, "G4", 0.24),
    ], humanise=1.1)
    _colour(p, M.reed_syn, "accordion", 0.30, 0.10, (2.6, 0.78, 0.22, 0.036), [
        (b(2, 0.0), 5.0, "D3", 0.30), (b(5, 0.0), 5.0, "Bb2", 0.28),
        (b(8, 0.0), 5.0, "C3", 0.30), (b(11, 0.0), 5.0, "D3", 0.28),
        (b(14, 0.0), 5.0, "Eb3", 0.30), (b(17, 0.0), 5.0, "D3", 0.28),
        (b(20, 0.0), 5.0, "Bb2", 0.30), (b(37, 0.0), 5.0, "D3", 0.32),
        (b(40, 0.0), 5.0, "Eb3", 0.30), (b(43, 0.0), 5.0, "C3", 0.32),
        (b(46, 0.0), 5.0, "D3", 0.30), (b(50, 0.0), 5.0, "Bb2", 0.24),
    ], humanise=0.8)
    _colour(p, M.chime_soft, "sea_bell", 0.34, -0.28, (3.4, 0.70, 0.30, 0.055), [
        (b(6, 0.0), 5.0, "G4", 0.28), (b(21, 0.0), 5.0, "D4", 0.26),
        (b(33, 0.0), 5.0, "Bb4", 0.24), (b(45, 0.0), 5.0, "G4", 0.30),
        (b(54, 0.0), 5.0, "D4", 0.22),
    ], humanise=0.4)
    return p


# ===========================================================================
# 7. island_maelstrom - The Maelstrom. D minor / octatonic, 64 BPM, 40 bars
# ===========================================================================
#
# The end of the sea, and still not loud. Open fifths and octaves in both
# hands for the first sixteen bars - no thirds at all, so nothing is major or
# minor, only wide - and then the swells go OCTATONIC: the half-whole scale
# on D, which supplies chords a tritone apart that both belong, and is why
# the middle of this piece sounds like it is turning. The Neapolitan Eb is
# the borrowed chord. Layers: the string section swelling, a choir "ahh", the
# grand's tremolo, a big synth pad (high-passed, still not booming) and a
# tubular bell tolling four times - the only bell in the game with a hum tone.

def island_maelstrom(rng):
    p = M.Nocturne("island_maelstrom", bpm=64.0, bars=40, tail=TAIL, lufs=-20.0,
                   tilt=-0.4, width=0.44, sympathetic=0.20, humanise=0.030,
                   spread=0.30, room=(2.4, 0.70, 0.22, 0.028))
    b = p.b
    OFF = [1.5, 2.5, 3.5]
    lay(p, 0, [
        (1, "D2", ["A2", "D3", "A3"], "D5 (open fifths)"),
        (1, "D2", ["A2", "E3", "A3"], "Dsus2 open"),
        (1, "C2", ["G2", "C3", "G3"], "C5"),
        (1, "C2", ["G2", "D3", "G3"], "Csus2 open"),
        (1, "Bb1", ["F2", "Bb2", "F3"], "Bb5"),
        (1, "Bb1", ["F2", "C3", "F3"], "Bbsus2 open"),
        (1, "A1", ["E2", "A2", "E3"], "A5"),
        (1, "A1", ["E2", "B2", "E3"], "Asus2 open"),
    ], vel=0.22, offs=OFF)
    lay(p, 8, [
        (1, "D2", ["A2", "E3", "G3"], "Dsus2add11"),
        (1, "D2", ["A2", "E3", "F3"], "Dm add9"),
        (1, "F2", ["C3", "G3", "D4"], "Fmaj9"),
        (1, "Ab1", ["Eb2", "B2", "F3"], "Ab7 (octatonic tritone)"),
        (1, "Bb1", ["F2", "D3", "E4"], "Bbmaj7#11"),
        (1, "B1", ["F#2", "D3", "A3"], "Bm7 (octatonic)"),
        (1, "A1", ["E2", "C3", "F3"], "Am(b6)"),
        (1, "Eb2", ["Bb2", "Db3", "G3"], "Eb7 (octatonic tritone)"),
    ], vel=0.24, offs=OFF)
    for k in range(16):
        bar = 16 + k // 2
        off = (k % 2) * 2.0
        for j in range(4):
            p.piano.note(b(bar, off + j * 0.5), 0.55,
                         ["D4", "F4", "A4", "F4"][j], 0.17 + 0.015 * (j == 0))
    p.lh(16, "D2", [], vel=0.20, bass_hold=16.0)
    p.harmony[16] = "Dm tremolo"
    p.harmony[18] = "Dm tremolo (pedal holds)"
    p.lh(20, "Bb1", [], vel=0.19, bass_hold=16.0)
    p.harmony[20] = "Bb/D tremolo"
    p.harmony[22] = "Bb/D tremolo (pedal holds)"
    lay(p, 24, [
        (1, "D2", ["A2", "D3", "F3"], "Dm(add9) open"),
        (1, "D2", ["A2", "E3", "F3"], "Dm11 open"),
        (1, "Eb2", ["Bb2", "G3", "D4"], "Ebmaj7 (Neapolitan)"),
        (1, "Eb2", ["Bb2", "G3", "C4"], "Ebmaj13 (Neapolitan)"),
        (1, "C2", ["G2", "E3", "Bb3"], "C9"),
        (1, "B1", ["F#2", "D3", "A3"], "Bm7 (octatonic)"),
        (1, "A1", ["E2", "C3", "G3"], "Am11"),
        (1, "Ab1", ["Eb2", "C3", "Gb3"], "Ab7 (octatonic tritone)"),
    ], vel=0.28, offs=OFF)
    lay(p, 32, [
        (1, "D2", ["A2", "D3", "F3"], "Dm9"),
        (1, "D2", ["A2", "E3", "F3"], "Dm11"),
        (1, "Bb1", ["F2", "D3", "A3"], "Bbmaj9"),
        (1, "Bb1", ["F2", "C3", "A3"], "Bbmaj13"),
        (1, "G2", ["D3", "Bb3", "F4"], "Gm11"),
        (1, "G2", ["D3", "Bb3", "E4"], "Gm6/9"),
        (1, "D2", ["A2", "D3", "A3"], "D5"),
        (1, "D2", ["A2", "E3", "A3"], "Dsus2 (lead-in)"),
    ], vel=0.20, offs=OFF)

    p.mel([
        (b(0, 2.0), 4.0, "D5", 0.42), (b(2, 2.0), 4.0, "C5", 0.40),
        (b(4, 2.0), 4.0, "D5", 0.43), (b(6, 2.0), 5.0, "A4", 0.41),
        (b(8, 1.0), 3.0, "E5", 0.46), (b(9, 1.0), 4.0, "D5", 0.44),
        (b(10, 1.0), 3.0, "F5", 0.48), (b(11, 1.0), 5.0, "D5", 0.46),
        (b(12, 1.0), 3.0, "E5", 0.45), (b(13, 1.0), 4.0, "C5", 0.43),
        (b(14, 1.0), 6.0, "A4", 0.44),
        (b(24, 2.0), 4.0, "D5", 0.54), (b(26, 2.0), 4.0, "Eb5", 0.56),
        (b(28, 1.0), 3.0, "F5", 0.58), (b(29, 1.0), 5.0, "E5", 0.56),
        (b(31, 1.0), 5.0, "D5", 0.52),
        (b(32, 2.0), 6.0, "A4", 0.36), (b(34, 2.0), 6.0, "F4", 0.33),
        (b(36, 2.0), 6.0, "D4", 0.31), (b(38, 2.0), 6.0, "A4", 0.29),
        (b(39, 3.0), 2.0, "C5", 0.26),
    ])

    p.pedal_bars(0, 16, per=2)
    p.pedal(b(16), b(20))
    p.pedal(b(20), b(24))
    p.pedal_bars(24, 8, per=1)
    p.pedal_bars(32, 8, per=2)

    _colour(p, M.strings_sec, "strings", 0.40, -0.20, (3.0, 0.68, 0.26, 0.040), [
        (b(8, 0.0), 7.0, "A4", 0.34), (b(10, 0.0), 7.0, "D5", 0.36),
        (b(12, 0.0), 7.0, "C5", 0.34), (b(14, 0.0), 6.0, "A4", 0.32),
        (b(24, 0.0), 7.5, "D5", 0.40), (b(26, 0.0), 7.5, "Eb5", 0.42),
        (b(28, 0.0), 7.5, "F5", 0.44), (b(30, 0.0), 7.0, "D5", 0.38),
    ], humanise=0.7)
    _colour(p, M.choir_ahh, "choir", 0.30, 0.22, (3.2, 0.74, 0.26, 0.048), [
        (b(24, 0.0), 7.5, "D4", 0.36), (b(26, 0.0), 7.5, "G4", 0.34),
        (b(28, 0.0), 7.5, "A4", 0.36), (b(30, 0.0), 7.0, "F4", 0.32),
    ], humanise=0.6)
    _colour(p, M.strings_sec_lo, "celli", 0.34, 0.0, (3.0, 0.72, 0.24, 0.040), [
        (b(17, 0.0), 6.0, "D3", 0.32), (b(19, 0.0), 5.0, "A2", 0.30),
        (b(21, 0.0), 6.0, "Bb2", 0.32), (b(23, 0.0), 4.0, "F2", 0.28),
    ], humanise=0.6)
    pad_bed(p, M.warm_pad_syn, "big_pad", 0.40, 0.06, (3.4, 0.72, 0.28, 0.050), [
        (0, 8, ["D3", "A3"]), (8, 4, ["D3", "A3"]), (12, 4, ["Bb2", "F3"]),
        (16, 8, ["D3", "A3"]), (24, 4, ["D3", "A3"]), (26, 2, ["Eb3", "Bb3"]),
        (28, 4, ["C3", "G3"]), (32, 8, ["D3", "A3"]),
    ])
    _colour(p, M.tubular_bell, "bells", 0.34, 0.28, (3.6, 0.66, 0.30, 0.055), [
        (b(8, 0.0), 7.0, "D4", 0.34), (b(16, 0.0), 7.0, "A3", 0.30),
        (b(24, 0.0), 7.0, "D4", 0.40), (b(28, 0.0), 7.0, "F4", 0.36),
        (b(36, 0.0), 7.0, "D4", 0.26),
    ], humanise=0.2)
    return p


# ---------------------------------------------------------------------------

_PIECES = {
    "island_tropical": island_tropical,
    "island_swamp": island_swamp,
    "island_ice": island_ice,
    "island_volcano": island_volcano,
    "island_gloom": island_gloom,
    "island_wreck": island_wreck,
    "island_maelstrom": island_maelstrom,
}


def _wrap(fn, low_mid=0.0):
    def render(rng):
        return fn(rng).render(low_mid=low_mid)
    return render


# The fen and the caldera are the two themes whose register puts them near
# the octave-band rule (150-400 Hz must not beat 400-2000 Hz by more than
# 2 dB): both are LOW piano pieces with a low colour layer under them. The
# trim is the fix the check was written for, applied per track.
_LOW_MID = {"island_swamp": -3.0, "island_volcano": -1.5}

TRACKS = {k: _wrap(v, _LOW_MID.get(k, 0.0)) for k, v in _PIECES.items()}


# ---------------------------------------------------------------------------
# the showreel - one file the whole team can listen to
# ---------------------------------------------------------------------------

SHOWREEL = [
    ("island_tropical", 104.0),
    ("island_swamp", 96.0),
    ("island_ice", 107.0),
    ("island_volcano", 91.0),
    ("island_gloom", 100.0),
    ("island_wreck", 98.0),
    ("island_maelstrom", 96.0),
]
REEL_SEG, REEL_XF = 8.5, 0.5


def build_showreel(rendered=None, out=None):
    """60.0 s: 8.5 s of each theme's return section, 0.5 s equal-power crossfades."""
    out = out or os.path.join(os.path.dirname(os.path.dirname(HERE)),
                              "assets", "audio", "preview", "showreel_islands.ogg")
    reel = None
    for key, at in SHOWREEL:
        audio = (rendered or {}).get(key)
        if audio is None:
            audio = TRACKS[key](S.rng(key))
        audio = S.normalize_lufs(audio, -16.0, -1.0)
        i0 = S.n(at)
        seg = audio[i0:i0 + S.n(REEL_SEG + REEL_XF)]
        seg = np.stack([S.fade(seg[:, 0], 0.02, 0.02),
                        S.fade(seg[:, 1], 0.02, 0.02)], axis=1)
        if reel is None:
            reel = seg
        else:
            reel = np.stack([S.crossfade(reel[:, 0], seg[:, 0], REEL_XF),
                             S.crossfade(reel[:, 1], seg[:, 1], REEL_XF)], axis=1)
    reel = S.normalize_lufs(reel, -16.0, -1.0)
    S.write_ogg(out, reel, stereo=True)
    return out, len(reel) / S.SR


if __name__ == "__main__":
    import time

    M.verify_sample_maps()
    done = {}
    for key, fn in _PIECES.items():
        t0 = time.time()
        piece = fn(S.rng(key))
        audio = piece.render(low_mid=_LOW_MID.get(key, 0.0))
        done[key] = audio
        print("\n=== %s  %.1f BPM  %d/8 or /4  %d bars  %.3f s  (%.1fs render)"
              % (key, piece.bpm, piece.beats_per_bar, piece.bars,
                 len(audio) / S.SR, time.time() - t0))
        print("  melody:")
        piece.print_melody()
        piece.print_harmony()
    path, secs = build_showreel(done)
    print("showreel: %s  %.1fs" % (path, secs))
