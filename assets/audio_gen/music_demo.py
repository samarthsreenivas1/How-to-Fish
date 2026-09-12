"""music_demo.py - the worked example for the music agents. NOT shipped.

build.py skips any module whose name starts with `music_demo`, so this
renders only when you ask for it:

    python3 assets/audio_gen/music_demo.py     # -> assets/audio/preview/

It is a 30 s loopable piece in the shape a real island theme takes, and it
exists to show the five things every theme has to get right:

1. AUTHOR TO AN EXACT BAR COUNT. `BARS * beats_per_bar` beats, no more. The
   loop point is sample-exact in Roblox; a piece that ends "about there"
   has an audible seam every pass.
2. RENDER LONG, THEN `loop_wrap`. The arrangement is rendered with
   `TAIL` seconds of reverb hanging off the end, and `loop_wrap` folds that
   overhang back under bar 1. That is what makes the seam disappear - not a
   crossfade, which would duck the whole mix once a loop.
3. ONE HARMONIC PLAN, SEVERAL VOICES. Chords are computed once and every
   track reads from the same list, so the bass, the pad and the lead cannot
   drift apart when the progression is edited.
4. TRACKS ARE STEMS. Everything goes through `master()` together, once. A
   per-track limiter would fight the bus one and the mix would pump.
5. HUMANISE, SEEDED. The pluck is jittered so it does not sound quantised;
   the seed lives on the Sequencer, so the render is still byte-identical
   run to run and `--check` still works.

A boss theme differs only in the last step: build the shared tracks, then
call `stem_pair(low_tracks, high_tracks)` instead of `master(...)` and
write two files.
"""

import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import music as M  # noqa: E402
import synth as S  # noqa: E402

BPM = 96.0
BEATS_PER_BAR = 4
BARS = 12                 # 12 bars at 96 BPM = 30.0 s exactly
TAIL = 2.5                # reverb overhang, folded back by loop_wrap
KEY = "D3"

# One harmonic plan, read by every track. | Dmaj9 | Bmin7 | Gmaj7 | A7sus4 |
PROGRESSION = [("D3", "maj9"), ("B2", "min7"), ("G2", "maj7"), ("A2", "sus4")]


def demo_theme(r):
    """A sunny 30 s loop: uke pluck, marimba counter, pad, light kit."""
    seq = M.Sequencer(bpm=BPM, beats_per_bar=BEATS_PER_BAR, swing=0.12,
                      seed="demo_theme")
    total_beats = BARS * BEATS_PER_BAR

    lead = seq.track(M.pluck_uke, name="lead", gain=0.85, humanise=0.6,
                     reverb=(0.7, 0.45, 0.16))
    counter = seq.track(M.marimba, name="counter", gain=0.5, humanise=0.4,
                        reverb=(0.6, 0.5, 0.20))
    padt = seq.track(M.pad, name="pad", gain=0.30, reverb=(1.3, 0.35, 0.30))
    bass = seq.track(M.pluck_bass, name="bass", gain=0.7, humanise=0.25)
    kick = seq.track(M.kick, name="kick", gain=0.75, humanise=0.2)
    shak = seq.track(M.shaker, name="shaker", gain=0.35, humanise=0.8)
    hat = seq.track(M.hat_closed, name="hat", gain=0.30, humanise=0.6)

    for bar_i in range(BARS):
        root, quality = PROGRESSION[bar_i % len(PROGRESSION)]
        b0 = seq.bar(bar_i)
        notes = M.chord(root, quality, inversion=1)

        # PAD: one long chord per bar, voiced in the middle register so it
        # never competes with the lead or the bass.
        for m in M.voice_chord(root, quality, low=57, high=76, voices=4):
            padt.note(b0, BEATS_PER_BAR, m, 0.42)

        # BASS: root on 1, fifth on 3-and. Sparse is what makes it groove.
        bass.note(b0, 1.5, M.midi(root) - 12, 0.85)
        bass.note(b0 + 2.5, 1.0, M.midi(root) - 12 + 7, 0.62)

        # LEAD: an eight-note arpeggio across the bar, pattern alternating so
        # the four-bar cycle does not read as a loop of one bar.
        pattern = "updown" if bar_i % 2 == 0 else "up"
        for i, m in enumerate(M.arp(notes, pattern, 8, octaves=2)):
            lead.note(b0 + i * 0.5, 0.45, m + 12, 0.55 + 0.25 * (i % 2 == 0))

        # COUNTER: marimba answers only in the second half of each phrase.
        if bar_i % 4 >= 2:
            for i, m in enumerate(M.arp(notes, "down", 4)):
                counter.note(b0 + 1.0 + i * 0.5, 0.4, m + 12, 0.5)

        # KIT: kick on 1 and 3-and, shaker eighths, hats on the offbeats.
        kick.hit(b0, 0.92)
        kick.hit(b0 + 2.5, 0.72)
        shak.every(0.5, 8, offset=b0, velocity=0.5)
        for i in range(4):
            hat.hit(b0 + 0.5 + i, 0.45)

    # A cymbal swell into the top of the loop - which, because of loop_wrap,
    # is also what leads back INTO bar 1 on every pass.
    swell = seq.track(M.cymbal_swell, name="swell", gain=0.35)
    swell.hit(total_beats - 2.0, 0.6, dur_beats=2.0)

    loop_seconds = M.beats_to_seconds(total_beats, BPM)
    stems = seq.render_stems(extra_tail=TAIL)
    mixed = M.master(stems, target_lufs=-16.0, peak_db=-1.0, tilt=1.0, width=0.5)
    # Trim to EXACTLY loop + tail before wrapping: the tracks' own tails
    # made the render a little longer, and loop_wrap treats everything past
    # `len - TAIL` as the overhang, so a stray extra second would fold real
    # music back under bar 1 instead of just the reverb.
    span = loop_seconds + TAIL
    mixed = np.stack([S.fit(mixed[:, 0], span), S.fit(mixed[:, 1], span)], axis=1)
    return M.loop_wrap(mixed, TAIL)


TRACKS = {"demo_theme": demo_theme}


if __name__ == "__main__":
    import time

    out_dir = os.path.join(os.path.dirname(os.path.dirname(HERE)),
                           "assets", "audio", "preview")
    os.makedirs(out_dir, exist_ok=True)
    t0 = time.time()
    audio = demo_theme(S.rng("demo_theme"))
    path = os.path.join(out_dir, "demo_theme.ogg")
    S.write_ogg(path, audio, stereo=True)
    print("%s  %.2fs audio  %.1fs render  %s" %
          (path, len(audio) / S.SR, time.time() - t0, S.clip_report(audio)))
