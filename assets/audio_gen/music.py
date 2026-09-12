"""music.py - notes, sequencing, instruments and mastering, on top of synth.py.

The one idea to hold on to: an INSTRUMENT is just a function

    inst(freq_hz, dur_seconds, velocity_0_to_1, rng) -> mono float array

and nothing else. Every instrument in `INSTRUMENTS` has that signature,
drums included (a drum ignores `freq`, or uses it as its tuning), so a
Track does not know or care what it is playing. To add an instrument,
write a function with that signature - you do not need to touch this file.

Writing a piece looks like this:

    seq = Sequencer(bpm=96, beats_per_bar=4)
    lead = seq.track(pluck_uke, gain=0.8, reverb=(0.7, 0.35, 0.18))
    for i, m in enumerate(arp(chord(midi("C4"), "maj7"), "updown", 8)):
        lead.note(i * 0.5, 0.45, m, 0.8)
    drums = seq.track(kick)
    drums.hits("kick", every=1.0, bars=4)
    stereo = master({"lead": lead.render(), "drums": drums.render()})

TIMING. Everything is in BEATS, converted once at render time. `swing`
delays every off-eighth; `humanise` jitters start times and velocities
from a SEEDED rng, so a piece with humanise on still renders identically
every run - which `build.py --check` depends on.

LOOPS. Island themes and ambience beds loop with `Sound.Looped`, which is
sample-exact and unforgiving: a reverb tail that runs past the last bar is
simply cut off, and you hear the cut once a loop. `loop_wrap` folds that
overhang back into the head so the tail of bar 32 arrives under bar 1.
Author the arrangement to an exact bar count, render it LONG, then wrap.
"""

import io
import math
import os
import sys

import numpy as np

import synth as S
from synth import SR

__all__ = [
    "midi", "hz", "note_name", "SCALES", "scale", "degree", "CHORDS", "chord",
    "voice_chord", "arp", "Track", "Sequencer", "beats_to_seconds",
    "INSTRUMENTS", "DRUMS", "master", "loop_wrap", "stem_pair", "hall",
    # 3d - the nocturne palette
    "piano", "piano_note", "PianoPart", "piano_room", "piano_ring",
    "piano_strings", "piano_inharmonicity", "piano_partial_taus",
    "violin_solo", "violin_pair", "violin_trem",
    # 3e - the sampled palette
    "StereoTrack", "Nocturne", "fl_available", "sample_map", "sample_root", "verify_sample_maps", "sampled_note",
    "sampled_hit", "sampled_piano_note", "strings_sec", "strings_sec_lo",
    "strings_solo_s", "choir_ahh", "choir_ooh", "brass_sec", "winds_sec",
    "rhodes_s", "timpani_s", "tom_s", "crash_s", "orch_hit_s",
]

A4 = 69
A4_HZ = 440.0
_NOTE_INDEX = {"c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11}


# ---------------------------------------------------------------------------
# 1. notes, scales, chords
# ---------------------------------------------------------------------------

def midi(value):
    """MIDI number from a number or a name: `midi("C4") == 60`, `midi("F#3")`."""
    if isinstance(value, (int, float, np.integer, np.floating)):
        return float(value)
    text = str(value).strip()
    letter = text[0].lower()
    if letter not in _NOTE_INDEX:
        raise ValueError("bad note name %r" % value)
    i = 1
    semi = _NOTE_INDEX[letter]
    while i < len(text) and text[i] in "#b":
        semi += 1 if text[i] == "#" else -1
        i += 1
    octave = int(text[i:]) if i < len(text) else 4
    return float(12 * (octave + 1) + semi)


def hz(m):
    """MIDI (fractional allowed - detune in cents is `m + cents/100`) -> Hz."""
    return A4_HZ * (2.0 ** ((np.asarray(m, dtype=np.float64) - A4) / 12.0))


def note_name(m):
    names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    m = int(round(m))
    return "%s%d" % (names[m % 12], m // 12 - 1)


SCALES = {
    "major": [0, 2, 4, 5, 7, 9, 11],
    "ionian": [0, 2, 4, 5, 7, 9, 11],
    "minor": [0, 2, 3, 5, 7, 8, 10],
    "aeolian": [0, 2, 3, 5, 7, 8, 10],
    "harmonic_minor": [0, 2, 3, 5, 7, 8, 11],
    "dorian": [0, 2, 3, 5, 7, 9, 10],
    "phrygian": [0, 1, 3, 5, 7, 8, 10],
    "lydian": [0, 2, 4, 6, 7, 9, 11],
    "mixolydian": [0, 2, 4, 5, 7, 9, 10],
    "locrian": [0, 1, 3, 5, 6, 8, 10],
    "pentatonic": [0, 2, 4, 7, 9],
    "pentatonic_minor": [0, 3, 5, 7, 10],
    "blues": [0, 3, 5, 6, 7, 10],
    "whole_tone": [0, 2, 4, 6, 8, 10],
    "octatonic": [0, 2, 3, 5, 6, 8, 9, 11],
    "chromatic": list(range(12)),
}


def scale(root, name="major", octaves=2, start_octave=0):
    """Ascending MIDI numbers for `octaves` octaves from `root`."""
    root = midi(root) + 12 * start_octave
    steps = SCALES[name]
    out = []
    for o in range(int(octaves)):
        for s in steps:
            out.append(root + 12 * o + s)
    out.append(root + 12 * octaves)
    return out


def degree(root, name, n_deg):
    """Scale degree `n_deg` (0-based, may exceed the scale -> next octave).

    Negative degrees walk downward, which is what a bass line wants.
    """
    steps = SCALES[name]
    k = len(steps)
    octave, idx = divmod(int(n_deg), k)
    return midi(root) + 12 * octave + steps[idx]


CHORDS = {
    "maj": [0, 4, 7], "min": [0, 3, 7], "dim": [0, 3, 6], "aug": [0, 4, 8],
    "sus2": [0, 2, 7], "sus4": [0, 5, 7], "5": [0, 7], "oct": [0, 12],
    "maj7": [0, 4, 7, 11], "min7": [0, 3, 7, 10], "dom7": [0, 4, 7, 10],
    "min7b5": [0, 3, 6, 10], "dim7": [0, 3, 6, 9], "maj9": [0, 4, 7, 11, 14],
    "min9": [0, 3, 7, 10, 14], "add9": [0, 4, 7, 14], "6": [0, 4, 7, 9],
    "min6": [0, 3, 7, 9], "min_add9": [0, 3, 7, 14], "quartal": [0, 5, 10],
}


def chord(root, quality="maj", inversion=0, drop=None, spread=0):
    """MIDI numbers for a chord.

    `inversion` rotates the lowest note up an octave; `drop` moves the Nth
    voice from the top down an octave (drop-2 voicings are why a pad sounds
    like an arrangement rather than a stack); `spread` adds an octave gap
    between every voice.
    """
    notes = [midi(root) + i for i in CHORDS[quality]]
    for _ in range(int(inversion)):
        notes = notes[1:] + [notes[0] + 12]
    if spread:
        notes = [nn + 12 * spread * i for i, nn in enumerate(notes)]
    if drop:
        i = len(notes) - int(drop)
        if 0 <= i < len(notes):
            notes[i] -= 12
    return sorted(notes)


def voice_chord(root, quality="maj", low=48, high=76, voices=4):
    """Fit a chord into a register - the lazy but effective voice-leading."""
    base = chord(root, quality)
    out = []
    i = 0
    pitch = midi(root)
    while pitch < low:
        pitch += 12
    while len(out) < voices:
        nn = base[i % len(base)] + 12 * (i // len(base))
        while nn < low:
            nn += 12
        while nn > high:
            nn -= 12
        if nn not in out:
            out.append(nn)
        i += 1
        if i > 40:
            break
    return sorted(out)


def arp(notes, pattern="up", length=8, octaves=1):
    """An arpeggio as a list of MIDI numbers, `length` long.

    Patterns: up, down, updown, downup, thumb (root between each note),
    random-ish `converge`. Extra octaves are appended before patterning.
    """
    pool = list(notes)
    for o in range(1, int(octaves)):
        pool += [x + 12 * o for x in notes]
    if not pool:
        return []
    if pattern == "up":
        seq = pool
    elif pattern == "down":
        seq = pool[::-1]
    elif pattern == "updown":
        seq = pool + pool[-2:0:-1]
    elif pattern == "downup":
        seq = pool[::-1] + pool[1:-1]
    elif pattern == "thumb":
        seq = []
        for x in pool[1:]:
            seq += [pool[0], x]
    elif pattern == "converge":
        seq = []
        lo, hi = 0, len(pool) - 1
        while lo <= hi:
            seq.append(pool[lo])
            if hi != lo:
                seq.append(pool[hi])
            lo += 1
            hi -= 1
    else:
        seq = pool
    if not seq:
        return []
    return [seq[i % len(seq)] for i in range(int(length))]


# ---------------------------------------------------------------------------
# 2. sequencing
# ---------------------------------------------------------------------------

def beats_to_seconds(beats, bpm):
    return float(beats) * 60.0 / float(bpm)


class Track(object):
    """One instrument's worth of note events, rendered on demand.

    A Track owns its own seeded rng, derived from the Sequencer's seed and
    the track's index, so adding a track does not reshuffle the humanise
    jitter of the tracks beside it.
    """

    def __init__(self, seq, instrument, name="track", gain=1.0, pan=0.0,
                 reverb=None, swing=None, humanise=0.0, seed=None):
        self.seq = seq
        self.instrument = instrument
        self.name = name
        self.gain = float(gain)
        self.pan = float(pan)
        self.reverb = reverb          # (size, damping, mix) or None
        self.swing = swing            # 0..0.5, overrides the sequencer's
        self.humanise = float(humanise)
        self.events = []              # (start_beat, dur_beats, midi, vel, inst)
        self._seed = seed

    # -- writing notes ------------------------------------------------------

    def note(self, start_beat, dur_beats, m, velocity=0.8, instrument=None):
        self.events.append((float(start_beat), float(dur_beats), midi(m),
                            float(velocity), instrument))
        return self

    def notes(self, start_beat, dur_beats, midis, velocity=0.8, stagger=0.0,
              instrument=None):
        """A chord. `stagger` beats between voices gives you a strum."""
        for i, m in enumerate(midis):
            self.note(start_beat + i * stagger, dur_beats, m, velocity, instrument)
        return self

    def hit(self, start_beat, velocity=0.9, m=60, dur_beats=0.25, instrument=None):
        """A drum hit - same event, but the instrument usually ignores pitch."""
        return self.note(start_beat, dur_beats, m, velocity, instrument)

    def hits(self, beats, velocity=0.9, m=60, dur_beats=0.25, instrument=None):
        for b in beats:
            self.hit(b, velocity, m, dur_beats, instrument)
        return self

    def every(self, step_beats, count, offset=0.0, velocity=0.9, m=60,
              dur_beats=0.25, instrument=None):
        """`count` evenly spaced hits - the backbone of any groove."""
        for i in range(int(count)):
            self.hit(offset + i * float(step_beats), velocity, m, dur_beats, instrument)
        return self

    def pattern(self, string, step_beats=0.25, offset=0.0, velocity=0.9, m=60,
                dur_beats=0.25, instrument=None):
        """Step string: 'x...x...x.x.' - `x` loud, `o` soft, `.`/space rest."""
        for i, ch in enumerate(string.replace(" ", "")):
            if ch == "x":
                self.hit(offset + i * step_beats, velocity, m, dur_beats, instrument)
            elif ch == "o":
                self.hit(offset + i * step_beats, velocity * 0.55, m, dur_beats, instrument)
        return self

    def repeat(self, times, period_beats):
        """Duplicate everything written so far, `times` more times."""
        base = list(self.events)
        for k in range(1, int(times) + 1):
            for (b, d, m, v, inst) in base:
                self.events.append((b + k * float(period_beats), d, m, v, inst))
        return self

    # -- rendering ----------------------------------------------------------

    @property
    def end_beat(self):
        return max((b + d for (b, d, _m, _v, _i) in self.events), default=0.0)

    def render(self, extra_tail=1.5):
        """Mono array. `extra_tail` seconds of room past the last note-off."""
        bpm = self.seq.bpm
        swing = self.seq.swing if self.swing is None else self.swing
        r = S.rng(self._seed if self._seed is not None else
                  S.seed_from("%s|%s|%d" % (self.seq.seed, self.name, len(self.events))))
        total = beats_to_seconds(self.end_beat, bpm) + float(extra_tail)
        out = S.silence(max(0.05, total))
        for (beat, dur_beats, m, vel, inst) in sorted(self.events):
            b = beat
            if swing:
                # Delay every second eighth-note. `swing` 1/3 is a triplet feel.
                pos = math.fmod(b, 1.0)
                if abs(pos - 0.5) < 1e-6:
                    b = b + 0.5 * float(swing)
            if self.humanise:
                b += float(r.normal(0.0, 0.012 * self.humanise)) * (60.0 / bpm) / (60.0 / bpm)
                b = max(0.0, b)
            v = float(np.clip(vel + (r.normal(0.0, 0.06 * self.humanise) if self.humanise else 0.0),
                              0.05, 1.0))
            dur_s = max(0.02, beats_to_seconds(dur_beats, bpm))
            fn = inst or self.instrument
            voice = np.asarray(fn(float(hz(m)), dur_s, v, r), dtype=np.float64)
            voice = S.fade(voice, 0.002, min(0.02, len(voice) / SR * 0.25))
            out = S.place(out, voice, beats_to_seconds(b, bpm))
        if self.reverb:
            # (size, damping, mix) or (size, damping, mix, predelay). The
            # fourth element is what puts a hall BEHIND an instrument rather
            # than around it: the dry note arrives first and the room answers
            # 20-60 ms later, which is how a big room actually sounds and
            # what keeps a 4 s tail from smearing the attack.
            if len(self.reverb) == 4:
                size, damp, mixv, pre = self.reverb
            else:
                size, damp, mixv = self.reverb
                pre = 0.0
            out = S.reverb(out, size=size, damping=damp, mix=mixv,
                           predelay=pre, seed=7)
        return out * self.gain


class Sequencer(object):
    """Tempo, bar arithmetic and a bag of Tracks."""

    def __init__(self, bpm=100.0, beats_per_bar=4, swing=0.0, seed="song"):
        self.bpm = float(bpm)
        self.beats_per_bar = int(beats_per_bar)
        self.swing = float(swing)
        self.seed = seed
        self.tracks = []

    # -- bar arithmetic -----------------------------------------------------

    def bar(self, index):
        """Start beat of bar `index` (0-based)."""
        return float(index) * self.beats_per_bar

    def bars_seconds(self, bars):
        return beats_to_seconds(bars * self.beats_per_bar, self.bpm)

    def seconds_to_beats(self, seconds):
        return float(seconds) * self.bpm / 60.0

    def track(self, instrument, name=None, **kwargs):
        tr = Track(self, instrument, name=name or ("track%d" % len(self.tracks)), **kwargs)
        self.tracks.append(tr)
        return tr

    def render_stems(self, extra_tail=1.5):
        """{name: mono array}, all padded to the same length."""
        stems = {}
        for tr in self.tracks:
            stems[tr.name] = tr.render(extra_tail=extra_tail)
        if stems:
            longest = max(len(v) for v in stems.values())
            stems = {k: S.fit(v, longest / SR) for k, v in stems.items()}
        return stems


# ---------------------------------------------------------------------------
# 3. instruments - inst(freq, dur, velocity, rng) -> mono
# ---------------------------------------------------------------------------

def _v(velocity):
    """Velocity curve: loud notes are also BRIGHTER, not just louder. Without
    this every dynamic sounds like a volume knob rather than a performance."""
    return float(np.clip(velocity, 0.02, 1.0))


def pluck(freq, dur, vel=0.8, r=None, brightness=0.6, damping=0.35, stretch=0.0, body=1.0):
    """Generic Karplus-Strong string. The other plucks are presets of this."""
    r = r or S.rng(1)
    v = _v(vel)
    y = S.karplus(dur, freq, r, brightness=brightness * (0.5 + 0.5 * v),
                  damping=damping, stretch=stretch)
    y *= S.expdec(dur, max(0.08, dur * 0.55))
    if body != 1.0:
        y = S.mix(y * body, S.lowpass(y, freq * 3.0, order=2) * (1.0 - body))
    return S.fade(y, 0.001, 0.01) * v


def pluck_uke(freq, dur, vel=0.8, r=None):
    """Nylon ukulele - soft exciter, quick damping, a little body resonance."""
    r = r or S.rng(2)
    v = _v(vel)
    y = S.karplus(dur, freq, r, brightness=0.35 + 0.3 * v, damping=0.42)
    y = S.mix(y, S.resonator(y, 240.0, q=6.0) * 0.25)      # soundboard
    y *= S.expdec(dur, max(0.1, min(0.9, dur * 0.7)))
    return S.fade(S.saturate(y * 0.8, 1.4), 0.001, 0.012) * v


def pluck_harp(freq, dur, vel=0.8, r=None):
    """Harp - bright exciter, very slow damping, long ring."""
    r = r or S.rng(3)
    v = _v(vel)
    y = S.karplus(dur, freq, r, brightness=0.55 + 0.35 * v, damping=0.12)
    y *= S.expdec(dur, max(0.4, dur * 1.1))
    return S.fade(y, 0.0015, 0.03) * v * 0.9


def pluck_banjo(freq, dur, vel=0.8, r=None):
    """Banjo - hard exciter, stretched (inharmonic) loop, drum-head body."""
    r = r or S.rng(4)
    v = _v(vel)
    y = S.karplus(dur, freq, r, brightness=0.95, damping=0.30, stretch=0.12)
    y = S.highpass(y, 180.0, order=2)
    y = S.mix(y, S.resonator(y, 420.0, q=9.0) * 0.35)
    y *= S.expdec(dur, max(0.08, min(0.5, dur * 0.5)))
    return S.fade(S.saturate(y, 1.8) * 0.7, 0.0008, 0.01) * v


def pluck_bass(freq, dur, vel=0.85, r=None):
    """Plucked bass - KS low, sub sine underneath, saturated for weight."""
    r = r or S.rng(5)
    v = _v(vel)
    y = S.karplus(dur, freq, r, brightness=0.35, damping=0.5)
    sub = S.sine(dur, freq) * S.perc_env(dur, 0.004, max(0.12, dur * 0.5))
    y = S.mix(S.lowpass(y, 1800.0, order=2) * 0.8, sub * 0.7)
    return S.fade(S.saturate(y * 0.8, 2.0), 0.002, 0.02) * v


def marimba(freq, dur, vel=0.8, r=None):
    """Rosewood bar over a tube resonator: the bar's odd partials plus a
    strong, fast-decaying fundamental."""
    r = r or S.rng(6)
    v = _v(vel)
    y = S.bar(dur, freq, r, decay=min(1.2, max(0.18, dur * 0.8)), strike=0.4 + 0.6 * v)
    tube = S.sine(dur, freq) * S.perc_env(dur, 0.003, max(0.12, dur * 0.6))
    y = S.mix(y * 0.75, tube * 0.45)
    return S.fade(y, 0.001, 0.015) * v


def steel_drum(freq, dur, vel=0.8, r=None):
    """FM steel pan - the tropical island's lead. Ratio 1:1 with a fast index
    envelope gives the metallic 'ping' that decays into a near-sine."""
    r = r or S.rng(7)
    v = _v(vel)
    idx = S.breakpoints(dur, [(0.0, 5.0 + 4.0 * v), (0.05, 2.2), (dur, 0.4)], curve="exp")
    y = S.fm(dur, freq, ratio=1.0, index=idx)
    y += 0.35 * S.fm(dur, freq * 2.01, ratio=3.0, index=idx * 0.4)
    y *= S.perc_env(dur, 0.002, max(0.15, dur * 0.55))
    y = S.mix(y, S.bar(min(dur, 0.08), freq * 4.0, r) * 0.12 * v)
    return S.fade(S.saturate(y * 0.6, 1.5), 0.001, 0.015) * v


def glass_bell(freq, dur, vel=0.7, r=None):
    """Glass / crotale - long inharmonic partials, hardly any body."""
    r = r or S.rng(8)
    v = _v(vel)
    y = S.bell(dur, freq, r, decay=max(0.8, dur * 0.9), strike=0.5 + 0.5 * v,
               inharmonic=0.85)
    y = S.highpass(y, 200.0, order=2)
    return S.fade(y, 0.001, 0.04) * v * 0.8


def music_box(freq, dur, vel=0.7, r=None):
    """Music box comb tooth - a bright, short, slightly detuned bell with a
    mechanical tick. Gloomtrench uses this detuned and slow."""
    r = r or S.rng(9)
    v = _v(vel)
    y = S.additive(dur, freq, [1.0, 2.03, 3.11, 4.9, 6.4, 9.1],
                   amps=[1.0, 0.55, 0.3, 0.2, 0.1, 0.06],
                   decays=[d * max(0.3, min(1.6, dur)) for d in [0.9, 0.5, 0.32, 0.2, 0.12, 0.08]])
    tick = S.band_noise(min(0.006, dur), r, 2000.0, 9000.0)
    tick *= S.perc_env(min(0.006, dur), 0.0002, 0.0015)
    y = S.mix(y, tick * 0.2 * v)
    return S.fade(y, 0.0008, 0.02) * v * 0.85


def organ(freq, dur, vel=0.8, r=None):
    """Drawbar organ: 16'/8'/5⅓'/4'/2⅔'/2' sines and a little key click."""
    r = r or S.rng(10)
    v = _v(vel)
    mults = [0.5, 1.0, 1.5, 2.0, 3.0, 4.0]
    gains = [0.5, 1.0, 0.35, 0.6, 0.22, 0.3]
    y = np.zeros(S.n(dur))
    for m, g in zip(mults, gains):
        y += S.sine(dur, freq * m) * g
    y /= sum(gains)
    y *= S.adsr(dur, a=0.008, d=0.03, s=0.9, rel=min(0.12, dur * 0.3))
    click = S.band_noise(min(0.004, dur), r, 1500.0, 8000.0) * 0.25
    y = S.mix(y, S.fit(click * S.perc_env(min(0.004, dur), 0.0002, 0.001), dur))
    return S.fade(y, 0.002, 0.01) * v


def pad(freq, dur, vel=0.7, r=None, cutoff=1800.0, attack=0.45):
    """Detuned saw pad through a slowly opening low-pass. The bed of every
    island theme; keep it quiet and wide."""
    r = r or S.rng(11)
    v = _v(vel)
    y = S.supersaw(dur, freq, voices=7, detune=0.010, phase_seed=r)
    y += S.supersaw(dur, freq * 0.5, voices=3, detune=0.006, phase_seed=r) * 0.4
    cut = S.breakpoints(dur, [(0.0, cutoff * 0.35), (min(dur, attack * 2.0), cutoff),
                              (dur, cutoff * 0.7)])
    y = S.lp_sweep(y, cut, order=2)
    y *= S.adsr(dur, a=min(attack, dur * 0.5), d=0.2, s=0.8,
                rel=min(max(0.2, dur * 0.35), dur * 0.5), curve=1.6)
    y = S.chorus(y, rate=0.25, depth_ms=8.0, voices=3, mix=0.4, seed=5)
    return S.fade(y * 0.5, 0.01, 0.05) * v


def pad_choir(freq, dur, vel=0.6, r=None, vowel=(600.0, 1040.0, 2450.0)):
    """Choir-ish: saws + breath through parallel formants. Not a real choir,
    but it reads as voices at low level under a pad, which is the job."""
    r = r or S.rng(12)
    v = _v(vel)
    src = S.supersaw(dur, freq, voices=5, detune=0.008, phase_seed=r) * 0.7
    src += S.white(dur, r) * 0.25
    src = S.lowpass(src, 4000.0, order=2)
    y = S.formant(src, list(vowel), qs=[11.0, 9.0, 7.0], gains=[1.0, 0.7, 0.35])
    y = S.vibrato(y, rate=4.6, depth_cents=14.0)
    y *= S.adsr(dur, a=min(0.35, dur * 0.4), d=0.15, s=0.85, rel=min(0.5, dur * 0.45), curve=1.4)
    y = S.chorus(y, rate=0.18, depth_ms=10.0, voices=3, mix=0.45, seed=6)
    peak = np.max(np.abs(y)) + 1e-12
    return S.fade(y / peak * 0.45, 0.02, 0.06) * v


def brass(freq, dur, vel=0.85, r=None):
    """Saw stack with a filter that opens with the note - the classic
    synth-brass 'blat'. Volcano and Maelstrom lean on this."""
    r = r or S.rng(13)
    v = _v(vel)
    y = S.supersaw(dur, freq, voices=5, detune=0.006, phase_seed=r)
    y += S.pulse(dur, freq * 0.5, 0.35) * 0.25
    cut = S.breakpoints(dur, [(0.0, 400.0), (0.06, 900.0 + 4200.0 * v), (dur, 1300.0)])
    y = S.moog(y, cut, res=0.35)
    y *= S.adsr(dur, a=0.02, d=0.09, s=0.75, rel=min(0.18, dur * 0.4), curve=1.5)
    return S.fade(S.saturate(y * 0.8, 1.8), 0.004, 0.02) * v * 0.8


def strings(freq, dur, vel=0.7, r=None):
    """Bowed section: filtered saws, vibrato, slow-ish attack. The ostinato
    instrument - short notes read as spiccato, long ones as sustain."""
    r = r or S.rng(14)
    v = _v(vel)
    y = S.supersaw(dur, freq, voices=6, detune=0.007, phase_seed=r)
    y = S.vibrato(y, rate=5.4, depth_cents=11.0)
    bow = S.band_noise(dur, r, freq * 2.0, min(12000.0, freq * 12.0)) * 0.12
    y = S.mix(y, bow)
    y = S.lowpass(y, 900.0 + 3500.0 * v, order=2)
    a = min(0.06 + 0.10 * (1.0 - v), dur * 0.4)
    y *= S.adsr(dur, a=a, d=0.1, s=0.85, rel=min(0.25, dur * 0.45), curve=1.3)
    return S.fade(y * 0.55, 0.006, 0.03) * v


def reed(freq, dur, vel=0.8, r=None):
    """Accordion / concertina - a pulse pair beating slightly, plus vibrato
    and the breath of the bellows. Wreckwater's shanty voice."""
    r = r or S.rng(15)
    v = _v(vel)
    a = S.pulse(dur, freq, 0.42)
    b = S.pulse(dur, freq * 1.004, 0.30)
    y = (a + b) * 0.5 + S.saw(dur, freq * 2.0, bright=0.5) * 0.18
    y = S.vibrato(y, rate=4.2, depth_cents=9.0)
    y = S.lowpass(y, 2600.0, order=2)
    y = S.mix(y, S.band_noise(dur, r, 600.0, 3000.0) * 0.05)
    y *= S.adsr(dur, a=min(0.05, dur * 0.3), d=0.08, s=0.85, rel=min(0.16, dur * 0.4))
    return S.fade(y * 0.5, 0.005, 0.02) * v


def whistle(freq, dur, vel=0.6, r=None):
    """A whistled melody - blown model, heavy breath, gentle vibrato."""
    r = r or S.rng(16)
    v = _v(vel)
    y = S.blown(dur, freq, r, breath=0.22, bright=0.25, vib=1.0)
    y = S.lowpass(y, 4500.0, order=2)
    y *= S.adsr(dur, a=min(0.05, dur * 0.3), d=0.06, s=0.9, rel=min(0.12, dur * 0.4))
    return S.fade(y * 0.5, 0.008, 0.02) * v


def sub_bass(freq, dur, vel=0.9, r=None):
    """Sine sub with a touch of second harmonic so it survives small speakers."""
    r = r or S.rng(17)
    v = _v(vel)
    while freq > 110.0:
        freq *= 0.5
    y = S.sine(dur, freq) + 0.18 * S.sine(dur, freq * 2.0)
    y *= S.adsr(dur, a=0.008, d=0.05, s=0.9, rel=min(0.10, dur * 0.4))
    return S.fade(S.saturate(y * 0.85, 1.3), 0.004, 0.02) * v


def drone(freq, dur, vel=0.6, r=None):
    """Bowed low drone - the swamp/gloom bed. Slow, dark, faintly moving."""
    r = r or S.rng(18)
    v = _v(vel)
    y = S.supersaw(dur, freq, voices=4, detune=0.004, phase_seed=r) * 0.6
    y += S.sine(dur, freq * 0.5) * 0.5
    y = S.lowpass(y, 700.0, order=2)
    y = S.tremolo(y, rate=0.13, depth=0.25)
    y *= S.adsr(dur, a=min(1.2, dur * 0.35), d=0.3, s=0.9, rel=min(1.5, dur * 0.4), curve=1.2)
    return S.fade(y * 0.6, 0.05, 0.2) * v


# -- drums. Same signature; `freq` is the tuning, most callers pass a default.

def kick(freq=55.0, dur=0.5, vel=0.95, r=None):
    r = r or S.rng(20)
    v = _v(vel)
    y = S.membrane(dur, freq, r, drop=0.34, noise=0.10, tau=dur * 0.28, sweep_time=0.028)
    click = S.band_noise(min(0.008, dur), r, 1200.0, 6000.0) * S.perc_env(min(0.008, dur), 0.0002, 0.002)
    y = S.mix(y, S.fit(click, dur) * 0.25 * v)
    y = S.saturate(y * 0.9, 2.2) * 0.80
    return S.fade(S.dc_block(y, 25.0), 0.0005, 0.01) * v


def snare(freq=190.0, dur=0.28, vel=0.9, r=None):
    r = r or S.rng(21)
    v = _v(vel)
    body = S.membrane(dur, freq, r, drop=0.6, noise=0.0, tau=dur * 0.22, sweep_time=0.012)
    wires = S.band_noise(dur, r, 900.0, 9000.0) * S.perc_env(dur, 0.0004, dur * 0.30, curve=1.2)
    y = S.mix(body * 0.55, wires * 0.9)
    y = S.highpass(y, 160.0, order=2)
    return S.fade(S.saturate(y * 0.8, 1.6), 0.0005, 0.008) * v


def hat_closed(freq=8000.0, dur=0.07, vel=0.7, r=None):
    r = r or S.rng(22)
    v = _v(vel)
    y = S.band_noise(dur, r, 5500.0, 15000.0, order=3)
    # A ring of inharmonic squares is what separates a hat from a noise tick.
    for m in (1.0, 1.41, 1.78, 2.33):
        y += S.square(dur, freq * 0.42 * m) * 0.06
    y *= S.perc_env(dur, 0.0003, dur * 0.28, curve=1.4)
    return S.fade(y * 1.6, 0.0004, 0.006) * v


def hat_open(freq=8000.0, dur=0.34, vel=0.65, r=None):
    r = r or S.rng(23)
    v = _v(vel)
    y = S.band_noise(dur, r, 5000.0, 15000.0, order=3)
    for m in (1.0, 1.41, 1.78, 2.33, 2.9):
        y += S.square(dur, freq * 0.42 * m) * 0.05
    y *= S.perc_env(dur, 0.0004, dur * 0.42, curve=1.1)
    return S.fade(y * 1.7, 0.0005, 0.02) * v


def shaker(freq=6000.0, dur=0.10, vel=0.6, r=None):
    r = r or S.rng(24)
    v = _v(vel)
    y = S.band_noise(dur, r, 3500.0, 12000.0, order=3)
    # Two-stage envelope: the beads hit the shell, then rattle.
    y *= S.breakpoints(dur, [(0.0, 0.0), (0.004, 1.0), (0.03, 0.35), (dur, 0.0)], curve="exp")
    return S.fade(y * 2.4, 0.0008, 0.008) * v


def wood_block(freq=900.0, dur=0.12, vel=0.8, r=None):
    r = r or S.rng(25)
    v = _v(vel)
    y = S.bar(dur, freq, r, decay=0.055, strike=0.9,
              partials=[1.0, 2.4, 4.2, 6.9])
    y = S.mix(y, S.band_noise(min(0.004, dur), r, 1500.0, 7000.0) *
              S.perc_env(min(0.004, dur), 0.0002, 0.0015) * 0.4)
    return S.fade(S.saturate(y * 0.8, 1.5), 0.0004, 0.008) * v


def taiko(freq=78.0, dur=0.7, vel=0.95, r=None):
    r = r or S.rng(26)
    v = _v(vel)
    y = S.membrane(dur, freq, r, drop=0.55, noise=0.30, tau=dur * 0.30, sweep_time=0.05)
    y = S.mix(y, S.membrane(dur, freq * 1.51, r, drop=0.7, noise=0.0, tau=dur * 0.12) * 0.3)
    y = S.saturate(y * 0.9, 2.4) * 0.72
    return S.fade(S.dc_block(y, 28.0), 0.0006, 0.02) * v


def timpani(freq=98.0, dur=1.4, vel=0.9, r=None):
    r = r or S.rng(27)
    v = _v(vel)
    parts = [1.0, 1.504, 1.742, 2.0, 2.245, 2.494]
    y = S.additive(dur, freq, parts,
                   amps=[1.0, 0.7, 0.45, 0.35, 0.22, 0.14],
                   decays=[dur * k for k in (0.55, 0.42, 0.33, 0.26, 0.2, 0.14)])
    mallet = S.band_noise(min(0.012, dur), r, 300.0, 3000.0) * S.perc_env(min(0.012, dur), 0.0004, 0.004)
    y = S.mix(y * 0.9, S.fit(mallet, dur) * 0.35)
    return S.fade(S.saturate(y * 0.8, 1.6) * 0.9, 0.001, 0.05) * v


def low_tom(freq=110.0, dur=0.45, vel=0.85, r=None):
    r = r or S.rng(28)
    v = _v(vel)
    y = S.membrane(dur, freq, r, drop=0.6, noise=0.18, tau=dur * 0.30, sweep_time=0.04)
    return S.fade(S.saturate(y * 0.85, 1.8) * 0.85, 0.0006, 0.015) * v


def cymbal_swell(freq=520.0, dur=1.6, vel=0.7, r=None):
    """Reverse-ish swell into a crash. Use before a downbeat."""
    r = r or S.rng(29)
    v = _v(vel)
    y = S.band_noise(dur, r, 2500.0, 16000.0, order=2)
    for m in (1.0, 1.41, 1.93, 2.61, 3.4, 4.7):
        y += S.square(dur, freq * m * 0.5) * 0.03
    env = S.breakpoints(dur, [(0.0, 0.002), (dur * 0.72, 1.0), (dur * 0.78, 0.85), (dur, 0.02)],
                        curve="exp")
    y *= env
    y = S.highpass(y, 900.0, order=2)
    return S.fade(y * 1.5, 0.02, 0.06) * v


def crash(freq=480.0, dur=1.2, vel=0.85, r=None):
    r = r or S.rng(30)
    v = _v(vel)
    y = S.band_noise(dur, r, 2000.0, 16000.0, order=2)
    for m in (1.0, 1.41, 1.93, 2.61, 3.4):
        y += S.square(dur, freq * m * 0.5) * 0.04
    y *= S.perc_env(dur, 0.0008, dur * 0.34, curve=1.1)
    y = S.highpass(y, 700.0, order=2)
    return S.fade(y * 1.1, 0.001, 0.05) * v


def rope_creak(freq=210.0, dur=0.5, vel=0.7, r=None):
    """Rope under load / rigging creak - stick-slip as comb-filtered noise
    pulses. Wreckwater percussion, and the base of `reelTension`."""
    r = r or S.rng(31)
    v = _v(vel)
    pulses = S.silence(dur)
    rate = 17.0 + 10.0 * float(r.random())
    count = max(2, int(dur * rate))
    for i in range(count):
        at = (i / rate) * (0.9 + 0.2 * float(r.random()))
        if at >= dur:
            break
        grain = S.band_noise(0.006, r, freq * 0.8, freq * 6.0) * S.perc_env(0.006, 0.0002, 0.0018)
        pulses = S.place(pulses, grain * (0.5 + 0.5 * float(r.random())), at)
    y = S.comb(S.fit(pulses, dur), 1.0 / freq, feedback=0.82, damp=0.35)
    y = S.bandpass(y, freq * 0.6, freq * 8.0, order=2)
    y *= S.breakpoints(dur, [(0.0, 0.0), (dur * 0.25, 1.0), (dur * 0.7, 0.8), (dur, 0.0)])
    peak = np.max(np.abs(y)) + 1e-12
    return S.fade(y / peak * 0.7, 0.004, 0.02) * v


def wood_knock(freq=260.0, dur=0.18, vel=0.8, r=None):
    """Knuckle on a plank - hollow, short, a bit of air behind it."""
    r = r or S.rng(32)
    v = _v(vel)
    exc = S.fit(S.white(0.003, r) * S.perc_env(0.003, 0.0002, 0.0009), dur)
    y = np.zeros(S.n(dur))
    for i, m in enumerate((1.0, 2.1, 3.4, 5.6)):
        y += S.resonator(exc, freq * m, q=22.0) / (i + 1.3)
    y *= S.expdec(dur, dur * 0.22)
    y = S.mix(y, S.band_noise(dur, r, 200.0, 1200.0) * S.perc_env(dur, 0.0003, 0.012) * 0.25)
    peak = np.max(np.abs(y)) + 1e-12
    return S.fade(S.saturate(y / peak * 0.8, 1.6), 0.0004, 0.01) * v


# ---------------------------------------------------------------------------
# 3b. the LUSH palette - bowed strings, felt keys, warm pads, soft percussion
# ---------------------------------------------------------------------------
#
# These are ADDITIVE: nothing above was changed or removed, because every SFX
# module and the existing themes are built on those. What is here is the
# vocabulary the island themes move to - slow attacks, no bright transients,
# 7ths and 9ths held long, and a hall behind everything.
#
# THE ONE IDEA that separates a string ENSEMBLE from a saw stack: no two
# players are in tune, in phase, or steady. Each voice gets its own slow
# random pitch drift, its own vibrato phase, and its own bow noise, so the
# sum never locks - which is what "lush" actually is. Then a body filter
# (a violin or cello is a handful of fixed resonances, not an EQ curve) and
# a long attack that the vibrato fades in UNDER, the way a real player
# leans into a held note.


def _drifted_saw_stack(dur, freq, r, voices=12, detune=0.006, drift=0.0035,
                       vib_cents=0.0, vib_rate=5.1, vib_delay=0.35, vib_ramp=0.55):
    """`voices` saws, each with its own detune, slow drift and vibrato phase.

    The vibrato is written into the FREQUENCY array rather than applied as a
    resampling afterwards: it costs nothing extra here, and it lets every
    player's vibrato start at a different moment, which is the difference
    between a section and a chorus pedal.
    """
    length = S.n(dur)
    tt = np.arange(length, dtype=np.float64) / SR
    vib_amt = np.clip((tt - vib_delay) / max(1e-3, vib_ramp), 0.0, 1.0) ** 1.5
    out = np.zeros(length)
    voices = max(1, int(voices))
    for i in range(voices):
        k = 0.0 if voices == 1 else (i / (voices - 1.0)) * 2.0 - 1.0
        ratio = 1.0 + k * detune + 0.0012 * (float(r.random()) - 0.5)
        f = freq * ratio
        if drift:
            rate = 0.11 + 0.55 * float(r.random())
            f = f * (1.0 + drift * np.sin(S.TWO_PI * (rate * tt + float(r.random()))))
        if vib_cents:
            vr = vib_rate * (0.88 + 0.24 * float(r.random()))
            depth = (vib_cents / 1200.0) * (0.7 + 0.6 * float(r.random()))
            f = f * (1.0 + depth * vib_amt * np.sin(S.TWO_PI * (vr * tt + float(r.random()))))
        out += S.saw(dur, f, phase=float(r.random()))
    return out / math.sqrt(voices)


# Body resonances, in Hz. A violin's air mode and main wood mode plus the
# "bridge hill" around 2.5 kHz; a cello's are an octave and a bit lower.
BODY_VIOLIN = ([275.0, 460.0, 700.0, 1250.0, 2600.0],
               [7.0, 6.0, 5.0, 4.0, 2.5], [1.0, 0.9, 0.5, 0.35, 0.22])
BODY_VIOLA = ([220.0, 350.0, 600.0, 1100.0, 2200.0],
              [7.0, 6.0, 5.0, 4.0, 2.5], [1.0, 0.85, 0.5, 0.3, 0.16])
BODY_CELLO = ([100.0, 175.0, 250.0, 460.0, 1000.0],
              [8.0, 7.0, 6.0, 4.5, 3.0], [1.0, 0.9, 0.6, 0.35, 0.18])
BODY_BASS = ([58.0, 95.0, 160.0, 320.0, 700.0],
             [8.0, 7.0, 6.0, 4.5, 3.0], [1.0, 0.9, 0.55, 0.3, 0.14])


def string_ensemble(freq, dur, vel=0.7, r=None, voices=13, body=BODY_VIOLIN,
                    cutoff=2600.0, detune=0.0065, attack=None, bow=0.16,
                    vib_cents=13.0, level=0.5, hp=70.0):
    """A bowed SECTION. The lead voice of the whole new palette.

    Synthesis: `voices` drifting, independently-vibratoed saws (the bowed
    core) + a band of bow noise that is loudest during the attack (rosin on
    the string, which is most of what tells the ear "bowed" rather than
    "sawtooth") -> parallel body resonances -> a warm low-pass that opens a
    little with velocity -> an ADSR whose attack scales with the note
    length (0.35 s on a short note, up to ~1.1 s on a long one) and whose
    release always completes inside the note -> ensemble chorus.

    LEGATO: the envelope starts and ends at zero and is slow at both ends,
    so overlapping notes written by a Track sum into a crossfade rather
    than a retrigger click. Write legato lines with the note duration
    LONGER than the gap to the next note.
    """
    r = r or S.rng(40)
    v = _v(vel)
    dur = max(0.12, float(dur))
    a = attack if attack is not None else min(1.1, max(0.30, dur * 0.28))
    a = min(a, dur * 0.45)
    core = _drifted_saw_stack(dur, freq, r, voices=voices, detune=detune,
                              drift=0.0035, vib_cents=vib_cents,
                              vib_delay=min(a * 1.15, dur * 0.5),
                              vib_ramp=max(0.3, dur * 0.25))
    # Bow noise: a band around the string's own register, loud at the
    # attack, settling to a whisper.
    nz = S.band_noise(dur, r, max(120.0, freq * 1.2), min(11000.0, freq * 9.0), order=2)
    nz *= S.breakpoints(dur, [(0.0, 1.0), (min(a, dur * 0.4), 0.35), (dur, 0.22)],
                        curve="exp")
    y = core + nz * bow
    freqs, qs, gains = body
    y = y * 0.55 + S.formant(y, freqs, qs=qs, gains=gains) * 0.55
    y = S.lowpass(y, cutoff * (0.72 + 0.48 * v), order=2)
    # A whisper of bow sheen ABOVE the low-pass. Without it a warm string
    # patch is not warm, it is muffled: the ear reads the 4-9 kHz rosin
    # noise as "a bow on a string in a room", and it costs almost no energy.
    air = S.band_noise(dur, r, 3500.0, 13000.0, order=2)
    air *= S.breakpoints(dur, [(0.0, 1.0), (min(a, dur * 0.4), 0.45), (dur, 0.3)],
                         curve="exp")
    y = y + air * bow * 0.45
    if hp:
        y = S.highpass(y, hp, order=2)
    env = S.adsr(dur, a=a, d=min(0.25, dur * 0.15), s=0.86,
                 rel=min(max(0.30, dur * 0.32), dur * 0.5), curve=1.25)
    # A slow swell inside the note - a held string note is never flat.
    env = env * (1.0 + 0.10 * np.sin(S.TWO_PI * (0.23 * np.arange(len(env)) / SR)))
    y = y * env
    y = S.chorus(y, rate=0.19, depth_ms=9.0, voices=3, mix=0.34, seed=17)
    peak = np.max(np.abs(y)) + 1e-12
    return S.fade(y / peak * level, min(0.02, dur * 0.1), min(0.08, dur * 0.2)) * v


def strings_violins(freq, dur, vel=0.7, r=None):
    """The high section - bright-ish but never buzzy, 14 players."""
    return string_ensemble(freq, dur, vel, r or S.rng(41), voices=14,
                           body=BODY_VIOLIN, cutoff=2900.0, detune=0.0060,
                           bow=0.15, vib_cents=14.0, level=0.50, hp=90.0)


def strings_violas(freq, dur, vel=0.7, r=None):
    """The middle - the glue in a four-part string voicing."""
    return string_ensemble(freq, dur, vel, r or S.rng(42), voices=12,
                           body=BODY_VIOLA, cutoff=2100.0, detune=0.0068,
                           bow=0.16, vib_cents=12.0, level=0.52, hp=70.0)


def strings_celli(freq, dur, vel=0.75, r=None):
    """Celli - the voice the swamp and the wreck lean on. Dark, woody."""
    return string_ensemble(freq, dur, vel, r or S.rng(43), voices=12,
                           body=BODY_CELLO, cutoff=1500.0, detune=0.0072,
                           bow=0.18, vib_cents=11.0, level=0.56, hp=45.0)


def strings_bass(freq, dur, vel=0.8, r=None):
    """Contrabass section - slow, round, no bite at all."""
    return string_ensemble(freq, dur, vel, r or S.rng(44), voices=9,
                           body=BODY_BASS, cutoff=750.0, detune=0.0080,
                           bow=0.10, vib_cents=7.0, level=0.60, hp=28.0)


def strings_tremolo(freq, dur, vel=0.6, r=None):
    """Sustained section with a bowed shimmer - the Maelstrom's swell and the
    boss ostinati. Tremolo, not spiccato: no note is re-attacked."""
    y = string_ensemble(freq, dur, vel, r or S.rng(45), voices=13,
                        body=BODY_VIOLA, cutoff=2300.0, detune=0.0075,
                        attack=min(0.55, max(0.16, dur * 0.18)), bow=0.30,
                        vib_cents=9.0, level=0.52, hp=70.0)
    return S.tremolo(y, rate=7.4, depth=0.30)


def warm_pad(freq, dur, vel=0.6, r=None, cutoff=1500.0, attack=None):
    """Soft, wide, slow. maj7/add9 friendly because it has almost no upper
    harmonic left to argue with the extensions: a gently drifting saw pair
    an octave apart, a sine fundamental for weight, a static low-pass (no
    filter sweep - a sweep is a synth gesture and this must not sound like
    a synth), long attack and long release, wide chorus."""
    r = r or S.rng(46)
    v = _v(vel)
    dur = max(0.2, float(dur))
    a = attack if attack is not None else min(1.4, max(0.45, dur * 0.30))
    a = min(a, dur * 0.45)
    y = _drifted_saw_stack(dur, freq, r, voices=8, detune=0.0055, drift=0.0025)
    y += _drifted_saw_stack(dur, freq * 0.5, r, voices=5, detune=0.0040, drift=0.0018) * 0.45
    y += S.sine(dur, freq) * 0.30 + S.sine(dur, freq * 2.0) * 0.08
    y = S.lowpass(y, cutoff, order=4)
    y *= S.adsr(dur, a=a, d=min(0.4, dur * 0.2), s=0.88,
                rel=min(max(0.45, dur * 0.38), dur * 0.5), curve=1.2)
    y = S.chorus(y, rate=0.13, depth_ms=12.0, voices=4, mix=0.45, seed=19)
    peak = np.max(np.abs(y)) + 1e-12
    return S.fade(y / peak * 0.42, min(0.03, dur * 0.1), min(0.10, dur * 0.25)) * v


def choir_warm(freq, dur, vel=0.5, r=None, vowel=(480.0, 900.0, 2100.0)):
    """A softer `pad_choir`: an 'oo' rather than an 'ah', no top, slow in and
    out. It sits UNDER the strings and is never the thing you notice."""
    r = r or S.rng(47)
    v = _v(vel)
    dur = max(0.2, float(dur))
    src = _drifted_saw_stack(dur, freq, r, voices=7, detune=0.0060, drift=0.0030,
                             vib_cents=9.0, vib_delay=min(0.5, dur * 0.35),
                             vib_ramp=max(0.3, dur * 0.3))
    src = src * 0.75 + S.pink(dur, r) * 0.22
    src = S.lowpass(src, 3000.0, order=2)
    y = S.formant(src, list(vowel), qs=[10.0, 8.0, 5.0], gains=[1.0, 0.55, 0.18])
    y = S.lowpass(y, 2400.0, order=2)
    a = min(1.0, max(0.35, dur * 0.30))
    y *= S.adsr(dur, a=min(a, dur * 0.45), d=min(0.3, dur * 0.15), s=0.88,
                rel=min(max(0.4, dur * 0.35), dur * 0.5), curve=1.2)
    y = S.chorus(y, rate=0.15, depth_ms=11.0, voices=3, mix=0.42, seed=21)
    peak = np.max(np.abs(y)) + 1e-12
    return S.fade(y / peak * 0.40, min(0.03, dur * 0.1), min(0.10, dur * 0.25)) * v


def felt_piano(freq, dur, vel=0.6, r=None):
    """Felt piano - the melodic voice where a theme wants a key rather than a
    bow. Three Karplus strings per note (a real piano has three, slightly
    apart, which is where the shimmer in a held chord comes from), damped
    hard so nothing rings bright, a sine body under them, and instead of a
    hammer CLICK a low-passed felt thump: the attack transient is under
    1 kHz, so it reads as a soft key rather than a pluck."""
    r = r or S.rng(48)
    v = _v(vel)
    dur = max(0.12, float(dur))
    ring = min(4.5, max(0.6, dur * 1.6))
    y = np.zeros(S.n(ring))
    for det in (-0.0016, 0.0, 0.0019):
        s = S.karplus(ring, freq * (1.0 + det), r, brightness=0.16 + 0.16 * v,
                      damping=0.52)
        y += s
    y /= 3.0
    y = y * S.expdec(ring, max(0.45, ring * 0.55))
    y += S.sine(ring, freq) * S.expdec(ring, max(0.35, ring * 0.4)) * 0.35
    y += S.sine(ring, freq * 2.0) * S.expdec(ring, max(0.15, ring * 0.18)) * 0.09
    felt = S.band_noise(min(0.05, ring), r, 90.0, 900.0, order=2)
    felt *= S.perc_env(min(0.05, ring), 0.006, 0.012)
    y = S.mix(y, S.fit(felt, ring) * 0.18 * (0.5 + 0.5 * v))
    y = S.lowpass(y, 1900.0 + 1600.0 * v, order=2)
    y = S.fit(y, dur)
    peak = np.max(np.abs(y)) + 1e-12
    return S.fade(y / peak * 0.52, 0.008, min(0.12, dur * 0.3)) * v


def soft_harp(freq, dur, vel=0.6, r=None):
    """Harp with the top taken off: long ring, soft nail, no click. The
    tropical lead. `pluck_harp` is bright on purpose; this is not."""
    r = r or S.rng(49)
    v = _v(vel)
    dur = max(0.12, float(dur))
    ring = min(5.0, max(0.8, dur * 1.5))
    y = S.karplus(ring, freq, r, brightness=0.30 + 0.20 * v, damping=0.20)
    y += S.karplus(ring, freq * 1.0013, r, brightness=0.24, damping=0.24) * 0.5
    y *= S.expdec(ring, max(0.7, ring * 0.85))
    y += S.sine(ring, freq) * S.expdec(ring, max(0.5, ring * 0.5)) * 0.22
    y = S.lowpass(y, 3000.0 + 2600.0 * v, order=2)
    y = S.fit(y, dur)
    peak = np.max(np.abs(y)) + 1e-12
    return S.fade(y / peak * 0.50, 0.006, min(0.10, dur * 0.3)) * v


def glass_soft(freq, dur, vel=0.5, r=None):
    """A bell heard from the far end of the hall: the ice theme's glint, with
    the strike almost gone and everything above 3 kHz rolled away."""
    r = r or S.rng(50)
    v = _v(vel)
    dur = max(0.2, float(dur))
    y = S.bell(dur, freq, r, decay=max(1.2, dur * 0.9), strike=0.18 + 0.2 * v,
               inharmonic=0.55)
    y = S.lowpass(y, 5000.0, order=4)
    y = S.mix(y * 0.8, S.sine(dur, freq * 0.5) * S.expdec(dur, dur * 0.45) * 0.2)
    peak = np.max(np.abs(y)) + 1e-12
    return S.fade(y / peak * 0.40, 0.02, min(0.15, dur * 0.3)) * v


def soft_bass(freq, dur, vel=0.8, r=None):
    """Round bass: a sine sub, an upright-ish damped string a little above it,
    a slow-ish attack and a release that outlives the note. Nothing about it
    is percussive - it is a floor, not a pulse."""
    r = r or S.rng(51)
    v = _v(vel)
    dur = max(0.12, float(dur))
    f = float(freq)
    while f > 130.0:
        f *= 0.5
    y = S.sine(dur, f) + 0.22 * S.sine(dur, f * 2.0) + 0.07 * S.sine(dur, f * 3.0)
    body = S.karplus(dur, f, r, brightness=0.12, damping=0.62) * 0.35
    y = S.mix(y * 0.85, S.lowpass(body, 420.0, order=2))
    y *= S.adsr(dur, a=min(0.09, dur * 0.25), d=min(0.2, dur * 0.2), s=0.85,
                rel=min(max(0.25, dur * 0.35), dur * 0.5), curve=1.3)
    y = S.saturate(y * 0.75, 1.2)
    peak = np.max(np.abs(y)) + 1e-12
    return S.fade(y / peak * 0.60, 0.006, min(0.09, dur * 0.25)) * v


def brush_shaker(freq=5200.0, dur=0.42, vel=0.5, r=None):
    """A brushed shaker/egg: the beads SWELL in instead of hitting. Long
    attack, no transient, low-passed. This is the only pulse a cozy theme
    needs - it marks the beat without ever being a click."""
    r = r or S.rng(52)
    v = _v(vel)
    dur = max(0.08, float(dur))
    y = S.band_noise(dur, r, 1800.0, 7500.0, order=2)
    y *= S.breakpoints(dur, [(0.0, 0.0), (dur * 0.42, 1.0), (dur * 0.65, 0.55),
                             (dur, 0.0)], curve="lin")
    y = S.lowpass(y, 6500.0, order=2)
    peak = np.max(np.abs(y)) + 1e-12
    return S.fade(y / peak * 0.55, min(0.02, dur * 0.2), min(0.06, dur * 0.3)) * v


def soft_tom(freq=96.0, dur=0.9, vel=0.6, r=None):
    """A felt-mallet tom: a membrane with the stick noise removed and the top
    rolled off, struck softly. The heartbeat under a slow theme."""
    r = r or S.rng(53)
    v = _v(vel)
    dur = max(0.15, float(dur))
    y = S.membrane(dur, freq, r, drop=0.45, noise=0.04, tau=dur * 0.28,
                   sweep_time=0.06)
    y = S.lowpass(y, 700.0, order=2)
    y = S.mix(y, S.sine(dur, freq * 0.5) * S.perc_env(dur, 0.012, dur * 0.3) * 0.3)
    peak = np.max(np.abs(y)) + 1e-12
    return S.fade(S.dc_block(y / peak * 0.55, 24.0), 0.006, min(0.08, dur * 0.2)) * v


def timpani_soft(freq=98.0, dur=1.8, vel=0.7, r=None):
    """`timpani` with felt sticks: the mallet noise is gone, the attack is
    10 ms rather than instant and the top is filtered. Keeps a boss stem's
    weight without the crack."""
    r = r or S.rng(54)
    v = _v(vel)
    dur = max(0.2, float(dur))
    parts = [1.0, 1.504, 1.742, 2.0, 2.245]
    y = S.additive(dur, freq, parts, amps=[1.0, 0.6, 0.34, 0.22, 0.12],
                   decays=[dur * k for k in (0.6, 0.42, 0.3, 0.22, 0.16)])
    y = S.lowpass(y, 1100.0, order=2)
    y *= S.breakpoints(dur, [(0.0, 0.0), (0.012, 1.0), (dur, 1.0)], curve="lin")
    peak = np.max(np.abs(y)) + 1e-12
    return S.fade(y / peak * 0.55, 0.008, min(0.12, dur * 0.2)) * v


def string_swell(freq, dur, vel=0.7, r=None):
    """A crescendo into the end of the note - the stinger voice and the lift
    into a section. The envelope is the instrument: it arrives, it does not
    start."""
    r = r or S.rng(55)
    v = _v(vel)
    dur = max(0.3, float(dur))
    y = string_ensemble(freq, dur, vel, r, voices=14, body=BODY_VIOLA,
                        cutoff=2600.0, detune=0.0070,
                        attack=min(0.35, dur * 0.2), bow=0.22, vib_cents=12.0,
                        level=0.55, hp=60.0)
    env = S.breakpoints(dur, [(0.0, 0.03), (dur * 0.80, 1.0), (dur * 0.90, 0.92),
                              (dur, 0.0)], curve="exp")
    return S.fade(y * env, min(0.03, dur * 0.1), min(0.15, dur * 0.2))


INSTRUMENTS = {
    "pluck": pluck, "pluck_uke": pluck_uke, "pluck_harp": pluck_harp,
    "pluck_banjo": pluck_banjo, "pluck_bass": pluck_bass,
    "marimba": marimba, "steel_drum": steel_drum, "glass_bell": glass_bell,
    "music_box": music_box, "organ": organ, "pad": pad, "pad_choir": pad_choir,
    "brass": brass, "strings": strings, "reed": reed, "whistle": whistle,
    "sub_bass": sub_bass, "drone": drone,
    # the lush palette (3b)
    "string_ensemble": string_ensemble, "strings_violins": strings_violins,
    "strings_violas": strings_violas, "strings_celli": strings_celli,
    "strings_bass": strings_bass, "strings_tremolo": strings_tremolo,
    "string_swell": string_swell, "warm_pad": warm_pad, "choir_warm": choir_warm,
    "felt_piano": felt_piano, "soft_harp": soft_harp, "glass_soft": glass_soft,
    "soft_bass": soft_bass,
}

DRUMS = {
    "kick": kick, "snare": snare, "hat_closed": hat_closed, "hat_open": hat_open,
    "shaker": shaker, "wood_block": wood_block, "taiko": taiko, "timpani": timpani,
    "low_tom": low_tom, "cymbal_swell": cymbal_swell, "crash": crash,
    "rope_creak": rope_creak, "wood_knock": wood_knock,
    # soft kit (3b)
    "brush_shaker": brush_shaker, "soft_tom": soft_tom, "timpani_soft": timpani_soft,
}


# ---------------------------------------------------------------------------
# 4. mastering
# ---------------------------------------------------------------------------

def master(stems, target_lufs=-16.0, peak_db=-1.0, tilt=0.0, glue=True,
           width=0.55, stereo=True):
    """Sum stems -> bus compression -> EQ tilt -> width -> loudness -> limit.

    `stems` may be a dict (name -> mono) or a list; a stem may already be
    stereo. `tilt` in dB is a broad shelf pair: positive is brighter (an
    ice theme), negative is darker (the gloom). Returns (N, 2) unless
    `stereo=False`.
    """
    if isinstance(stems, dict):
        parts = list(stems.values())
    else:
        parts = list(stems)
    parts = [np.asarray(p, dtype=np.float64) for p in parts if p is not None and len(p)]
    if not parts:
        return np.zeros((1, 2)) if stereo else np.zeros(1)
    length = max(len(p) for p in parts)

    left = np.zeros(length)
    right = np.zeros(length)
    for p in parts:
        if p.ndim == 2:
            left[: len(p)] += p[:, 0]
            right[: len(p)] += p[:, 1]
        else:
            left[: len(p)] += p
            right[: len(p)] += p

    def chain(x):
        x = S.dc_block(x, 22.0)
        if glue:
            x = S.compress(x, threshold_db=-20.0, ratio=2.2, attack=0.012,
                           release=0.18, makeup_db=1.5)
        if tilt:
            hi = S.highpass(x, 2500.0, order=2)
            lo = S.lowpass(x, 200.0, order=2)
            x = x + hi * (S.amp_db(tilt) - 1.0) * 0.6 + lo * (S.amp_db(-tilt) - 1.0) * 0.6
        return x

    left, right = chain(left), chain(right)
    if not stereo:
        return S.normalize_lufs(S.limit((left + right) * 0.5, peak_db), target_lufs, peak_db)

    if width > 0:
        mid = (left + right) * 0.5
        side = (left - right) * 0.5
        # If the sum is effectively mono, manufacture width rather than
        # boosting a side channel that is all zeros.
        if float(np.max(np.abs(side))) < 1e-6:
            wide = S.stereo_width(mid, width=width, delay_ms=11.0)
            left, right = wide[:, 0], wide[:, 1]
        else:
            side = side * (1.0 + width)
            left, right = mid + side, mid - side

    out = np.stack([left, right], axis=1)
    return S.normalize_lufs(out, target_lufs, peak_db)


def hall(x, size=4.0, damping=0.55, mix=0.30, predelay=0.035, seed=7, tail=True):
    """The long room the lush palette lives in.

    A convenience over `S.reverb` with the settings a 3-5 s hall wants:
    a pre-delay so attacks stay readable, and damping high enough that the
    tail gets darker as it decays instead of hanging as hiss. Use it on a
    SUBMIX (all the strings at once) rather than per note - a shared room is
    what makes separate tracks sound like one ensemble in one place.
    """
    return S.reverb(x, size=size, damping=damping, mix=mix, predelay=predelay,
                    seed=seed, tail=tail)


def loop_wrap(audio, tail_seconds, fade_in=0.012):
    """Fold the reverb tail past the loop point back into the head.

    `audio` is the arrangement rendered LONG: `loop_length + tail_seconds`.
    The first `loop_length` samples are kept, and everything past them is
    added back at the start, so the sound arriving at bar 1 is exactly the
    sound that would have been arriving there on the previous pass. That -
    plus authoring to an exact bar multiple - is the whole trick to a
    Looped Sound with no seam.

    Accepts mono or (N, 2).
    """
    a = np.asarray(audio, dtype=np.float64)
    tail_n = S.n(tail_seconds)
    body_n = len(a) - tail_n
    if body_n <= 0:
        return a
    head = a[:body_n].copy()
    tail = a[body_n:]
    k = min(len(tail), body_n)
    head[:k] += tail[:k]
    # A tiny fade at the very start would ruin the seam; instead the wrap
    # IS the continuity. Only kill a DC step at sample 0.
    if fade_in > 0:
        ni = min(S.n(fade_in), body_n)
        ramp = np.linspace(0.6, 1.0, ni) ** 0.5
        if head.ndim == 2:
            head[:ni] *= ramp[:, None]
        else:
            head[:ni] *= ramp
    return head


def stem_pair(low_tracks, high_tracks, target_lufs=-16.0, peak_db=-1.0,
              tail_seconds=0.0, tilt=0.0):
    """Two bar-aligned stems from one arrangement.

    `low_tracks` is the phase-1 set; `high_tracks` is what phase 2/3 ADDS
    (the caller passes the shared tracks in both lists, or renders the low
    set once and hands it to both). Both stems are padded to the same
    length and mastered with the same settings, so the client can crossfade
    between them mid-bar without a level or tonal jump - which it cannot do
    if each stem is loudness-normalised independently to its own content.
    """
    low = master(low_tracks, target_lufs=target_lufs, peak_db=peak_db, tilt=tilt)
    high_raw = master(high_tracks, target_lufs=target_lufs, peak_db=peak_db, tilt=tilt)
    length = max(len(low), len(high_raw))
    low = S.fit(low[:, 0], length / SR), S.fit(low[:, 1], length / SR)
    low = np.stack(low, axis=1)
    high = np.stack([S.fit(high_raw[:, 0], length / SR),
                     S.fit(high_raw[:, 1], length / SR)], axis=1)
    if tail_seconds > 0:
        low = loop_wrap(low, tail_seconds)
        high = loop_wrap(high, tail_seconds)
    return low, high


# ---------------------------------------------------------------------------
# 3c. the ACOUSTIC palette - ADDITIVE bowed strings, and friends
# ---------------------------------------------------------------------------
#
# Why this exists next to 3b: 3b builds a "string section" out of detuned
# saws through a low-pass, which is a synth pad wearing a string's clothes.
# The ear hears the sawtooth's full harmonic series arriving all at once and
# reads "synth". A bowed string does not do that. It BLOOMS: the fundamental
# and the low harmonics speak first, the upper ones arrive over the next
# ~250 ms as the bow catches, and over a held note the top of the spectrum
# quietly recedes again. That envelope-per-harmonic is the whole difference,
# and it cannot be made with one filter over one oscillator.
#
# So every note here is built harmonic by harmonic:
#
#   y(t) = SUM_k  a_k * A_k(t) * sin(k * phase_v(t) + p_k)
#
#   a_k     static spectrum, k^-tilt with the even harmonics pulled down a
#           little (a bowed string is not a saw; its evens are weaker) and
#           an extra roll-off above the 10th so nothing above ~8 kHz bites
#   A_k(t)  the per-harmonic envelope: (1 - e^(-t/tau_k)) with
#           tau_k = 20 ms + 16 ms * (k-1), so harmonic 1 is instant and
#           harmonic 20 takes ~320 ms - the spectral BLOOM - multiplied by
#           e^(-warm * t * (k-3)), the slow warming of a held note
#   phase_v the voice's own phase: its own detune (<= 8 cents), its own slow
#           pitch drift, and its own vibrato - 5-6 Hz, +-10-15 cents, which
#           does not start until 0.4 s in and fades in over half a second,
#           the way a player leans into a note rather than shaking it
#
# An ENSEMBLE is 5-8 of those, each with its own detune, drift, vibrato rate
# AND vibrato phase, and its own onset jitter of 10-40 ms. That is a section:
# players who agree on the note and on nothing else. It is NOT one voice
# through a chorus - a chorus moves every partial of one tone together and
# the ear hears the modulation as an effect.
#
# On top of the partials: bow noise (rosin, loud at the onset, a whisper
# after) through the same body resonances, and a little 3.5-13 kHz "air" so
# the section reads as a bow in a room rather than a muffled organ. Then the
# body itself - parallel resonators, the BODY_* tables above - and a release
# in which the highs die faster than the lows.
#
# Levels are NOT peak-normalised per note (3b does that, which flattens
# dynamics): each note is divided by the sum of its own static spectrum, so
# a soft note really is softer AND darker than a loud one.

# Body resonances for the additive sections. These are SEPARATE from the
# BODY_* tables above on purpose: 3b drives them with Q 6-8, which puts a
# 10 dB bump under whichever harmonic happens to land on 460 Hz and makes
# the fundamental of some notes twice the size of the fundamental of their
# neighbours. A real body is broader than that. Q 3-4, and mixed in at a
# fifth, colours the note without re-writing its spectrum.
BODY_VIOLIN_AC = ([275.0, 460.0, 700.0, 1300.0, 2600.0],
                  [3.5, 3.5, 3.0, 2.5, 2.0], [1.0, 0.85, 0.6, 0.4, 0.25])
BODY_VIOLA_AC = ([220.0, 350.0, 600.0, 1150.0, 2200.0],
                 [3.5, 3.5, 3.0, 2.5, 2.0], [1.0, 0.85, 0.6, 0.35, 0.2])
BODY_CELLO_AC = ([100.0, 175.0, 260.0, 480.0, 1000.0],
                 [3.5, 3.5, 3.0, 2.5, 2.0], [1.0, 0.9, 0.6, 0.4, 0.22])

_BOW_CACHE = {}
_BOW_ORDER = []
_BOW_CACHE_MAX = 900


def _sect(name, **kw):
    spec = dict(voices=6, body=BODY_VIOLIN_AC, hp=120.0, tilt=1.30, even=0.82,
                warm=0.055, bow=0.085, air=0.030, vib=12.0, vib_rate=5.5,
                detune=6.0, jitter=0.030, kmax=20, top=8200.0, level=0.30,
                attack=None, trem=0.0)
    spec.update(kw)
    spec["name"] = name
    return spec


SECT_VLN1 = _sect("vln1", voices=7, body=BODY_VIOLIN_AC, hp=150.0, tilt=0.88,
                  even=0.80, warm=0.055, bow=0.080, air=0.034, vib=13.0,
                  vib_rate=5.6, detune=6.0, jitter=0.032, kmax=20,
                  top=8200.0, level=0.30)
SECT_VLN2 = _sect("vln2", voices=6, body=BODY_VIOLIN_AC, hp=140.0, tilt=0.95,
                  even=0.78, warm=0.062, bow=0.075, air=0.028, vib=11.0,
                  vib_rate=5.2, detune=7.0, jitter=0.036, kmax=18,
                  top=7600.0, level=0.28)
SECT_VIOLA = _sect("viola", voices=6, body=BODY_VIOLA_AC, hp=105.0, tilt=1.00,
                   even=0.76, warm=0.060, bow=0.085, air=0.024, vib=10.0,
                   vib_rate=5.1, detune=7.0, jitter=0.038, kmax=18,
                   top=6800.0, level=0.30)
SECT_CELLO = _sect("cello", voices=6, body=BODY_CELLO_AC, hp=48.0, tilt=0.96,
                   even=0.80, warm=0.052, bow=0.090, air=0.020, vib=9.0,
                   vib_rate=4.9, detune=8.0, jitter=0.040, kmax=20,
                   top=5800.0, level=0.34)
SECT_TREM = _sect("trem", voices=7, body=BODY_VIOLA_AC, hp=120.0, tilt=1.06,
                  even=0.80, warm=0.040, bow=0.150, air=0.030, vib=7.0,
                  vib_rate=5.0, detune=8.0, jitter=0.040, kmax=16,
                  top=6600.0, level=0.26, attack=0.09, trem=0.30)


def _harmonic_envs(dur, K, tilt, even, warm, length):
    """(base amplitudes, per-harmonic envelope rows). The envelopes are built
    on a coarse grid and interpolated up - they are smooth by construction
    and this is the difference between 40 ms and 2 s a note."""
    gn = max(48, min(4096, int(dur * 220.0)))
    gt = np.linspace(0.0, dur, gn)
    base = np.zeros(K)
    rows = np.zeros((K, gn))
    for i in range(K):
        k = i + 1
        a = k ** (-tilt)
        if k % 2 == 0:
            a *= even
        if k > 10:
            a *= math.exp(-(k - 10) * 0.11)
        base[i] = a
        tau = 0.020 + 0.016 * (k - 1)
        rows[i] = (1.0 - np.exp(-gt / tau)) * np.exp(-gt * warm * max(0, k - 3))
    return base, gt, rows


def _bowed_render(freq, dur, vel, spec, variant):
    """One section playing one note. Additive; see the header above."""
    r = np.random.default_rng(S.seed_from("%s|%.3f|%.3f|%.2f|%d" %
                                          (spec["name"], freq, dur, vel, variant)))
    dur = max(0.18, float(dur))
    v = float(np.clip(vel, 0.05, 1.0))
    jit = float(spec["jitter"])
    length = S.n(dur + jit + 0.02)
    tt = np.arange(length, dtype=np.float64) / SR

    # Spectrum. A quiet note is a DARKER note, not just a smaller one: the
    # tilt steepens and the bow noise recedes as the player eases off.
    tilt = float(spec["tilt"]) + 0.38 * (1.0 - v)
    K = int(max(4, min(int(spec["kmax"]), spec["top"] / max(55.0, freq))))
    base, gt, rows = _harmonic_envs(dur + jit + 0.02, K, tilt, float(spec["even"]),
                                    float(spec["warm"]), length)
    envs = [np.interp(tt, gt, rows[i]) for i in range(K)]

    voices = int(spec["voices"])
    core = np.zeros(length)
    for vi in range(voices):
        det_cents = (float(r.random()) * 2.0 - 1.0) * float(spec["detune"])
        f0 = freq * (2.0 ** (det_cents / 1200.0))
        # slow independent drift, a couple of cents
        drate = 0.11 + 0.42 * float(r.random())
        ft = f0 * (1.0 + 0.0013 * np.sin(S.TWO_PI * (drate * tt + float(r.random()))))
        # delayed vibrato, each player's own rate and phase
        vdelay = 0.40 + 0.18 * float(r.random())
        vamt = np.clip((tt - vdelay) / 0.55, 0.0, 1.0) ** 1.6
        vrate = float(spec["vib_rate"]) * (0.90 + 0.20 * float(r.random()))
        vdepth = (float(spec["vib"]) / 1200.0) * (0.75 + 0.5 * float(r.random()))
        ft = ft * (1.0 + vdepth * vamt * np.sin(S.TWO_PI * (vrate * tt + float(r.random()))))
        ph = S.TWO_PI * np.cumsum(ft) / SR
        onset = int(SR * jit * float(r.random()))
        acc = np.zeros(length)
        for i in range(K):
            acc += base[i] * envs[i] * np.sin((i + 1) * ph + S.TWO_PI * float(r.random()))
        if onset:
            acc = np.concatenate([np.zeros(onset), acc[:length - onset]])
        core += acc
    core /= (voices * float(np.sum(base)) + 1e-12)

    # Bow noise through the same body, plus a little air above it.
    nz = S.band_noise(len(core) / SR, r, max(140.0, freq * 1.6),
                      min(9000.0, freq * 10.0), order=2)
    nz *= S.breakpoints(len(core) / SR,
                        [(0.0, 0.15), (0.045, 1.0), (0.30, 0.34), (dur, 0.24)],
                        curve="exp")
    air = S.band_noise(len(core) / SR, r, 3500.0, 12000.0, order=2)
    air *= S.breakpoints(len(core) / SR,
                         [(0.0, 0.2), (0.05, 1.0), (0.35, 0.42), (dur, 0.30)],
                         curve="exp")
    y = core + nz * float(spec["bow"]) * (0.55 + 0.45 * v)
    freqs, qs, gains = spec["body"]
    y = y * 0.80 + S.formant(y, freqs, qs=qs, gains=gains) * 0.10
    y = y + air * float(spec["air"]) * (0.5 + 0.5 * v)
    y = S.lowpass(y, min(11000.0, float(spec["top"]) * 1.25), order=2)
    if spec["hp"]:
        y = S.highpass(y, float(spec["hp"]), order=2)

    # The bow gesture. Slow in, slow out, a breath of swell inside.
    a = spec["attack"] if spec["attack"] is not None else min(0.40, max(0.13, dur * 0.20))
    a = min(a, dur * 0.45)
    rel = min(max(0.28, dur * 0.30), dur * 0.5)
    env = S.adsr(len(y) / SR, a=a, d=min(0.22, dur * 0.14), s=0.90, rel=rel, curve=1.25)
    env = env * (1.0 + 0.035 * np.sin(S.TWO_PI * (0.21 * np.arange(len(env)) / SR
                                                  + float(r.random()))))
    # Highs let go before the lows do - a release, not a fader.
    lo = S.lowpass(y, 900.0, order=2)
    hi = y - lo
    y = lo * env + hi * (env ** 1.7)
    if spec["trem"]:
        y = y * (1.0 - float(spec["trem"])
                 + float(spec["trem"]) * (0.5 + 0.5 * np.sin(
                     S.TWO_PI * (6.6 * np.arange(len(y)) / SR + float(r.random())))))
    y = y * (float(spec["level"]) * (v ** 1.25))
    return S.fade(y, min(0.015, dur * 0.08), min(0.06, dur * 0.2))


def bowed(freq, dur, vel=0.6, r=None, spec=SECT_VLN1):
    """Cached entry point. The cache is what makes an additive section
    affordable: a piece re-uses maybe 150 distinct (pitch, length, dynamic)
    notes, and three baked variants per key keep repeats from being
    bit-identical without re-synthesising every time."""
    key = (spec["name"], round(float(freq), 2), round(float(dur), 3),
           round(float(np.clip(vel, 0.05, 1.0)), 2))
    # WHICH of the three variants is drawn from the TRACK's rng, never from a
    # global counter. A global counter would make a note's timbre depend on
    # how many other tracks had already rendered, and build.py renders a
    # cached track's module without re-rendering its neighbours - the render
    # would stop being reproducible and `--check` would fail at random.
    if r is not None:
        turn = int(r.integers(0, 3))
    else:
        turn = S.seed_from(repr(key)) % 3
    vk = key + (turn,)
    hit = _BOW_CACHE.get(vk)
    if hit is None:
        hit = _bowed_render(key[1], key[2], key[3], spec, turn).astype(np.float32)
        _BOW_CACHE[vk] = hit
        _BOW_ORDER.append(vk)
        if len(_BOW_ORDER) > _BOW_CACHE_MAX:
            _BOW_CACHE.pop(_BOW_ORDER.pop(0), None)
    return hit.astype(np.float64)


def violins_1(freq, dur, vel=0.6, r=None):
    return bowed(freq, dur, vel, r, SECT_VLN1)


def violins_2(freq, dur, vel=0.6, r=None):
    return bowed(freq, dur, vel, r, SECT_VLN2)


def violas_(freq, dur, vel=0.6, r=None):
    return bowed(freq, dur, vel, r, SECT_VIOLA)


def celli_(freq, dur, vel=0.65, r=None):
    return bowed(freq, dur, vel, r, SECT_CELLO)


def tremolo_strings(freq, dur, vel=0.5, r=None):
    return bowed(freq, dur, vel, r, SECT_TREM)


def pizz_bass(freq, dur, vel=0.7, r=None):
    """Plucked contrabass. Rare, short, and the only thing below the celli."""
    r = r or S.rng(61)
    v = _v(vel)
    ring = min(2.2, max(0.35, dur * 1.1))
    y = S.karplus(ring, freq, r, brightness=0.22 + 0.12 * v, damping=0.46)
    y *= S.expdec(ring, max(0.22, ring * 0.42))
    y += S.sine(ring, freq) * S.expdec(ring, max(0.18, ring * 0.3)) * 0.30
    freqs, qs, gains = BODY_BASS
    y = y * 0.7 + S.formant(y, freqs, qs=qs, gains=gains) * 0.25
    y = S.lowpass(y, 1400.0, order=2)
    y = S.highpass(y, 45.0, order=2)
    y = S.fit(y, max(dur, 0.12))
    peak = float(np.max(np.abs(y))) + 1e-12
    return S.fade(y / peak * 0.30, 0.004, min(0.08, dur * 0.25)) * v


def harp_air(freq, dur, vel=0.55, r=None):
    """Harp with no nail in it: a soft 8 ms lean-in instead of a transient,
    heavy damping, and the top rolled off at 3 kHz. It is allowed to be the
    only bright thing in a piece because it is never loud."""
    r = r or S.rng(62)
    v = _v(vel)
    ring = min(4.0, max(0.7, dur * 1.4))
    y = S.karplus(ring, freq, r, brightness=0.26 + 0.16 * v, damping=0.26)
    y += S.karplus(ring, freq * 1.0011, r, brightness=0.20, damping=0.30) * 0.45
    y *= S.expdec(ring, max(0.55, ring * 0.7))
    y += S.sine(ring, freq) * S.expdec(ring, max(0.4, ring * 0.45)) * 0.20
    y = S.lowpass(y, 2400.0 + 1400.0 * v, order=2)
    y = S.highpass(y, 90.0, order=2)
    y = S.fit(y, max(dur, 0.15))
    peak = float(np.max(np.abs(y))) + 1e-12
    return S.fade(y / peak * 0.26, 0.008, min(0.12, dur * 0.3)) * v


def nylon_soft(freq, dur, vel=0.55, r=None):
    """Nylon-string guitar: same idea as the harp with a guitar's body and a
    shorter ring."""
    r = r or S.rng(63)
    v = _v(vel)
    ring = min(2.6, max(0.5, dur * 1.25))
    y = S.karplus(ring, freq, r, brightness=0.30 + 0.18 * v, damping=0.34)
    y *= S.expdec(ring, max(0.35, ring * 0.5))
    y = y * 0.7 + S.formant(y, [100.0, 200.0, 400.0, 2400.0],
                            qs=[9.0, 7.0, 5.0, 3.0],
                            gains=[0.8, 0.7, 0.4, 0.2]) * 0.28
    y = S.lowpass(y, 2800.0 + 1200.0 * v, order=2)
    y = S.highpass(y, 80.0, order=2)
    y = S.fit(y, max(dur, 0.12))
    peak = float(np.max(np.abs(y))) + 1e-12
    return S.fade(y / peak * 0.27, 0.006, min(0.10, dur * 0.28)) * v


def flute_soft(freq, dur, vel=0.5, r=None):
    """Additive flute: a strong fundamental, a weak octave, almost nothing
    above the fifth partial, and breath - a band of noise around the mouth
    hole that is most of what makes it a flute rather than a sine."""
    r = r or S.rng(64)
    v = _v(vel)
    dur = max(0.2, float(dur))
    tt = np.arange(S.n(dur), dtype=np.float64) / SR
    vamt = np.clip((tt - 0.45) / 0.5, 0.0, 1.0) ** 1.5
    ft = freq * (1.0 + (8.0 / 1200.0) * vamt * np.sin(S.TWO_PI * (5.1 * tt + 0.3)))
    ph = S.TWO_PI * np.cumsum(ft) / SR
    amps = [1.0, 0.16 + 0.10 * v, 0.05, 0.022, 0.010]
    y = np.zeros(len(tt))
    for i, a in enumerate(amps):
        y += a * np.sin((i + 1) * ph + 0.7 * i)
    y /= sum(amps)
    breath = S.band_noise(dur, r, max(600.0, freq * 1.4), min(9000.0, freq * 9.0), order=2)
    breath *= S.breakpoints(dur, [(0.0, 1.0), (0.12, 0.5), (dur, 0.4)], curve="exp")
    y = y + breath * 0.10 * (0.6 + 0.4 * v)
    y = S.lowpass(y, 5200.0, order=2)
    y = S.highpass(y, max(90.0, freq * 0.6), order=2)
    a = min(0.28, max(0.09, dur * 0.16))
    y *= S.adsr(dur, a=a, d=min(0.2, dur * 0.12), s=0.92,
                rel=min(max(0.22, dur * 0.28), dur * 0.45), curve=1.2)
    peak = float(np.max(np.abs(y))) + 1e-12
    return S.fade(y / peak * 0.24, 0.010, min(0.08, dur * 0.25)) * v


def glock_far(freq, dur, vel=0.4, r=None):
    """Glockenspiel heard from the far end of the hall: inharmonic partials,
    no strike noise to speak of, and quiet. Ice only."""
    r = r or S.rng(65)
    v = _v(vel)
    ring = min(3.0, max(0.5, dur * 1.4))
    parts = [(1.0, 1.0, 0.55), (3.01, 0.34, 0.32), (5.98, 0.15, 0.20),
             (9.2, 0.06, 0.12), (13.1, 0.03, 0.08)]
    y = np.zeros(S.n(ring))
    for mult, amp, tau in parts:
        y += amp * S.sine(ring, freq * mult) * S.expdec(ring, tau * ring)
    y = S.lowpass(y, 7000.0, order=2)
    y = S.highpass(y, 300.0, order=2)
    y = S.fit(y, max(dur, 0.12))
    peak = float(np.max(np.abs(y))) + 1e-12
    return S.fade(y / peak * 0.20, 0.004, min(0.10, dur * 0.3)) * v


def medium_hall(x, rt=2.4, damping=0.72, mix=0.22, predelay=0.032, seed=7, tail=True):
    """A hall, not a cathedral. 2.0-2.8 s, a pre-delay so the bow still has
    an attack, damping high enough that the tail goes dark rather than
    hissing, and a modest mix - the room should be something you notice only
    when it stops."""
    return S.reverb(x, size=float(rt), damping=float(damping), mix=float(mix),
                    predelay=float(predelay), seed=seed, tail=tail)


def low_mid_trim(x, amount_db=-2.2, low=150.0, high=420.0):
    """Take a little out of the 150-420 Hz shelf where a string section piles
    up. Measured, not guessed: the octave-band check compares 150-400 Hz
    against 400-2000 Hz and this is the knob that fixes it."""
    band = S.bandpass(x, low, high, order=2) if x.ndim == 1 else np.stack(
        [S.bandpass(x[:, 0], low, high, order=2),
         S.bandpass(x[:, 1], low, high, order=2)], axis=1)
    return x + band * (S.amp_db(amount_db) - 1.0)


INSTRUMENTS.update({
    "violins_1": violins_1, "violins_2": violins_2, "violas_": violas_,
    "celli_": celli_, "tremolo_strings": tremolo_strings, "pizz_bass": pizz_bass,
    "harp_air": harp_air, "nylon_soft": nylon_soft, "flute_soft": flute_soft,
    "glock_far": glock_far,
})


# ---------------------------------------------------------------------------
# 3d. the NOCTURNE palette - a real piano with a sustain pedal, and one violin
# ---------------------------------------------------------------------------
#
# The whole soundtrack is TWO instruments: this piano and one violin. Nothing
# in 3b or 3c's ensembles is used by it. What follows is a physical-ish piano
# rather than an "instrument function", because the music it has to carry is
# solo piano at pp-mp with the sustain pedal down, and at that dynamic a
# piano IS its decay: the double decay of coupled strings, the inharmonic
# stretch of the partials, and - the thing the pedal buys you - the other 200
# strings in the box ringing in sympathy with whatever you just played.
#
# WHY A DEDICATED RENDERER AND NOT JUST AN `inst(freq, dur, vel, rng)`.
# A Track hands an instrument a DURATION and expects a note that long. A
# pedalled piano does not work that way: the note-off does nothing at all
# while the pedal is down, the string keeps ringing its full natural decay
# (8-15 s in the bass), and the next note lands on top of it. The overlap is
# the harmony. So `PianoPart` below owns the events AND the pedal regions,
# and decides per note when - if ever - a damper touches the string.
#
# THE NOTE (`_piano_render`):
#
#   strings    1 below E2, 2 below C4, 3 above - each detuned by 1-2 cents
#              and struck 0-0.4 ms apart, so a unison BEATS slowly (middle C
#              with +-1.5 cents beats at about 0.45 Hz) instead of sitting
#              dead still. This is most of "a piano is not a sine".
#   partials   f_k = k * f0 * sqrt(1 + B k^2), B from 1.8e-4 at A0 to 1.0e-2
#              at C8 (log-interpolated). The stretch is small down low and
#              large up top, which is why the top octave of a piano is tuned
#              sharp and why an unstretched additive "piano" sounds like an
#              organ. 6-38 partials, more in the bass.
#   spectrum   a_k = k^-tilt with tilt from -9 dB/oct at pp to -5 at f (a
#              harder blow is a BRIGHTER note, not just a louder one), times
#              the hammer's comb |sin(pi k p)| with p ~ 1/7: the strike point
#              cancels the 7th, 14th, 21st partial, which is the notch every
#              piano has and no additive tone has by accident.
#   decay      TWO stages per partial: 0.58 e^(-t/tau_f) + 0.42 e^(-t/tau_s)
#              with tau_f = 0.18 tau_s. That is the coupled-string double
#              decay - the strings of a unison start in phase, dump energy
#              into the bridge fast, then drift out of phase and the
#              remaining energy leaks away slowly. tau_s shortens with k, so
#              a note gets darker as it rings.
#   hammer     3-8 ms of band-passed noise whose top end opens with velocity,
#              plus a felt thud under it.
#   body       a small bank of low-Q soundboard resonances mixed at ~8%.
#
# THE PEDAL (`PianoPart.render`):
#
#   * `pedal(a, b)` marks a region in beats. A note released inside one keeps
#     ringing to the END of the region (or to its own natural end, whichever
#     comes first); a note released outside one gets a 60-120 ms damper
#     close and a faint damper thump.
#   * SYMPATHETIC RESONANCE. While the pedal is down every damper is off the
#     strings, so a new note excites the strings of the notes still ringing.
#     Each note-on is fed, at a low level, through combs tuned to the
#     fundamentals of up to three ringing notes (T60 ~ 2 s) and the result is
#     mixed back in. That shimmer is what a pedalled piano sounds like and it
#     is the only reason a held-down pedal is worth modelling at all.
#
# Levels are NOT peak-normalised per note - pp has to be quieter AND darker
# than mp or the whole nocturne idea dies at the first bar.

_PIANO_CACHE = {}
_PIANO_ORDER = []
_PIANO_CACHE_MAX = 360

# Soundboard: broad, low-Q, and mixed low. A piano body is not a formant
# filter; it is a plate with a lot of weakly-resonant modes.
BODY_PIANO = ([78.0, 132.0, 196.0, 293.0, 442.0, 720.0, 1180.0, 2300.0],
              [3.0, 3.0, 2.6, 2.4, 2.2, 2.0, 1.8, 1.6],
              [1.0, 0.85, 0.7, 0.55, 0.42, 0.30, 0.20, 0.12])


def piano_inharmonicity(m):
    """Stiffness coefficient B for MIDI note `m`. 1.8e-4 (A0) to 1.0e-2 (C8)."""
    x = min(1.0, max(0.0, (float(m) - 21.0) / 87.0))
    return 1.8e-4 * (1.0e-2 / 1.8e-4) ** x


def piano_strings(m):
    """1 string in the bass, 2 in the tenor, 3 in the treble."""
    return 1 if m < 40 else (2 if m < 60 else 3)


def piano_ring(m):
    """Natural ring with the dampers OFF, in seconds: 15 s at A0, 2.6 s at C8."""
    x = min(1.0, max(0.0, (float(m) - 21.0) / 87.0))
    return 15.0 * (2.6 / 15.0) ** x


def piano_partial_taus(m, k):
    """(fast, slow) decay constants of partial `k`. Exposed for verification."""
    ring = piano_ring(m)
    tau_s = ring / (1.0 + 0.55 * (k - 1) ** 0.9)
    # The fast stage is capped in ABSOLUTE time: a bass note that rings 12 s
    # still dumps its first burst of energy in about a second, and without
    # the cap the "double" decay in the bottom octave is one slow slope.
    return min(0.18 * tau_s, 0.90), tau_s


def _piano_render(m, vel, variant=0):
    """One free-ringing note, undamped, from the hammer to silence."""
    f0 = float(hz(m))
    v = float(np.clip(vel, 0.05, 1.0))
    r = np.random.default_rng(S.seed_from("piano|%.2f|%.3f|%d" % (m, v, variant)))
    ring = piano_ring(m)
    length = S.n(ring)
    tt = np.arange(length, dtype=np.float64) / SR

    B = piano_inharmonicity(m)
    K = int(np.clip(9000.0 / f0, 6, 38))
    p_strike = 1.0 / 7.0 + float(r.normal(0.0, 0.004))
    tilt = (9.0 - 4.0 * v) / 6.0206          # dB/oct -> k^-tilt

    parts = []
    for k in range(1, K + 1):
        fk = k * f0 * math.sqrt(1.0 + B * k * k)
        if fk > 0.46 * SR:
            break
        a = k ** (-tilt)
        a *= 0.12 + 0.88 * abs(math.sin(math.pi * k * p_strike))
        parts.append((k, fk, a))
    norm = sum(a for (_k, _f, a) in parts) + 1e-12

    ns = piano_strings(m)
    core = np.zeros(length)
    for si in range(ns):
        spread = 0.0 if ns == 1 else (si - (ns - 1) * 0.5) * 1.5
        cents = spread + float(r.normal(0.0, 0.35))
        mult = 2.0 ** (cents / 1200.0)
        off = int(SR * float(r.random()) * 0.00040)      # strings not struck together
        n_av = length - off
        if n_av <= 16:
            continue
        t = tt[:n_av]
        acc = np.zeros(n_av)
        for (k, fk, a) in parts:
            tau_f, tau_s = piano_partial_taus(m, k)
            # stop this partial where it falls under -80 dB - the top of the
            # spectrum dies in under a second and generating 15 s of it is
            # most of the cost of an additive piano.
            reach = tau_s * math.log(max(1.0001, a * 0.42 / 1e-4))
            nk = min(n_av, max(64, S.n(reach)))
            tk = t[:nk]
            env = 0.58 * np.exp(-tk / tau_f) + 0.42 * np.exp(-tk / tau_s)
            f = fk * mult
            if f > 0.46 * SR:
                continue
            acc[:nk] += a * env * np.sin(S.TWO_PI * f * tk + S.TWO_PI * float(r.random()))
        if off:
            core[off:] += acc
        else:
            core += acc
    core /= (ns * norm)

    # Hammer: a short band of noise whose top opens with velocity, and the
    # felt thud of the head hitting the string under it.
    hn = S.n(0.030)
    nz = np.asarray(S.white(0.030, r))[:hn]
    ht = np.arange(hn, dtype=np.float64) / SR
    nz = nz * np.exp(-ht / (0.0010 + 0.0022 * (1.0 - v)))
    nz = S.bandpass(nz, 320.0, min(11000.0, 1400.0 + 7200.0 * v), order=2)
    thud = np.asarray(S.white(0.060, r))[:S.n(0.060)]
    thud = S.lowpass(thud, 150.0 + 130.0 * v, order=2)
    thud = thud * np.exp(-np.arange(len(thud), dtype=np.float64) / SR / 0.011)
    y = core.copy()
    y[:hn] += nz * (0.055 * (0.4 + 0.6 * v))
    y[:len(thud)] += thud * (0.030 * (0.5 + 0.5 * v))

    # Soundboard. Low-Q, low level: colour, not a filter.
    freqs, qs, gains = BODY_PIANO
    y = y * 0.92 + S.formant(y, freqs, qs=qs, gains=gains) * 0.075
    y = S.highpass(y, 26.0, order=2)
    y = S.lowpass(y, 12500.0, order=2)
    y = y * (0.42 * (v ** 1.15))
    return S.fade(y, 0.0004, 0.020)


def piano_note(m, vel=0.5, variant=0):
    """Cached free-ringing note. `m` is MIDI, quantised; `vel` to 0.05 steps."""
    key = (round(float(m), 2), round(float(np.clip(vel, 0.05, 1.0)) / 0.05) * 0.05,
           int(variant) % 3)
    hit = _PIANO_CACHE.get(key)
    if hit is None:
        hit = _piano_render(key[0], key[1], key[2]).astype(np.float32)
        _PIANO_CACHE[key] = hit
        _PIANO_ORDER.append(key)
        if len(_PIANO_ORDER) > _PIANO_CACHE_MAX:
            _PIANO_CACHE.pop(_PIANO_ORDER.pop(0), None)
    return hit.astype(np.float64)


def piano(freq, dur, vel=0.5, r=None, pedal=False):
    """`inst(...)` adapter, for a Track that wants one piano note.

    `pedal=True` lets the note ring its natural length past `dur`; otherwise
    the damper closes at `dur`. The real music does NOT go through here - it
    goes through `PianoPart`, which is the only thing that can model a pedal
    region spanning many notes. This exists so a piano note can be dropped
    into an ordinary Track (a stinger, a test tone).
    """
    m = 69.0 + 12.0 * math.log(max(1e-6, float(freq)) / A4_HZ, 2.0)
    turn = int(r.integers(0, 3)) if r is not None else S.seed_from("%.3f" % freq) % 3
    y = piano_note(m, vel, turn)
    if pedal:
        return y
    cut = S.n(max(0.05, float(dur)))
    if cut >= len(y):
        return y
    out = y[:cut + S.n(0.14)].copy()
    out[cut:] *= np.exp(-np.arange(len(out) - cut, dtype=np.float64) / SR / 0.022)
    return out


def _damper_close(y, cut, m, r):
    """Close the damper on a ringing note at sample `cut`. Returns a new array.

    A damper is felt, not instant: 60 ms up top, 120 ms in the bass where
    there is more string to stop, and it makes a small noise doing it.
    """
    if cut >= len(y):
        return y
    rel = 0.060 + 0.060 * (1.0 - min(1.0, max(0.0, (float(m) - 21.0) / 87.0)))
    nrel = S.n(rel)
    out = y[:cut + nrel].copy()
    tail = np.arange(len(out) - cut, dtype=np.float64) / SR
    damp = np.exp(-tail / (rel * 0.30))
    thump = np.asarray(S.white(0.045, r))[:S.n(0.045)]
    thump = S.lowpass(thump, 210.0, order=2)
    thump *= np.exp(-np.arange(len(thump), dtype=np.float64) / SR / 0.009)
    k = min(len(thump), len(out) - cut)
    if out.ndim == 2:
        out[cut:] *= damp[:, None]
        if k > 0:
            out[cut:cut + k] += thump[:k, None] * 0.010
    else:
        out[cut:] *= damp
        if k > 0:
            out[cut:cut + k] += thump[:k] * 0.010
    return out


def _sympathetic(exciter, freqs, level=1.0):
    """The other strings answering. Combs at the ringing fundamentals, T60 ~ 2 s."""
    if not len(freqs) or level <= 0.0:
        return None
    x = np.concatenate([np.asarray(exciter, dtype=np.float64), np.zeros(S.n(2.4))])
    out = np.zeros(len(x))
    for f in freqs[:3]:
        d = 1.0 / max(20.0, float(f))
        fb = float(np.clip(10.0 ** (-3.0 * d / 2.0), 0.0, 0.996))
        out += S.comb(x, d, feedback=fb, mix=1.0, damp=0.55)
    out = S.highpass(out, 140.0, order=2)
    out = S.lowpass(out, 5200.0, order=2)
    return out * (level / max(1, min(3, len(freqs))))


class PianoPart(object):
    """Piano events plus SUSTAIN PEDAL regions, rendered to stereo.

        p = PianoPart(bpm=60, seed="tropical")
        p.pedal(0, 8); p.note(0, 3.5, "F2", 0.34); p.note(1.5, 2.0, "C5", 0.42)
        audio = p.render(extra_tail=6.0)        # (N, 2)

    Times are in BEATS. `note(start, dur, midi, vel)` - `dur` is when the KEY
    comes up, which matters only if the pedal is up. Pedal regions are
    half-open [a, b) in beats and may not overlap (they are merged if they
    do). `humanise` is the rubato: seconds of jitter on every onset, which is
    what keeps 60 BPM from sounding like a sequencer.

    The stereo image is the keyboard: low notes left, high notes right, by
    `spread`. Everything shares one room, applied by the caller.
    """

    def __init__(self, bpm=60.0, seed="piano", gain=1.0, humanise=0.026,
                 sympathetic=0.16, spread=0.45, beats_per_bar=4, bank="stage"):
        # `bank` selects the SAMPLED grand (section 3e): "stage" is the
        # default instrument of the whole soundtrack, "close" is drier and
        # closer-miked (the Gloomtrench), "synth" forces the 3d model. On a
        # machine with no FL Studio content every bank falls back to 3d.
        self.bank = bank
        self.bpm = float(bpm)
        self.beats_per_bar = int(beats_per_bar)
        self.seed = seed
        self.gain = float(gain)
        self.humanise = float(humanise)
        self.sympathetic = float(sympathetic)
        self.spread = float(spread)
        self.events = []          # (start_beat, dur_beats, midi, vel)
        self.pedals = []          # (start_beat, end_beat)

    # -- writing ------------------------------------------------------------

    def note(self, start_beat, dur_beats, m, vel=0.45):
        self.events.append((float(start_beat), float(dur_beats), midi(m), float(vel)))
        return self

    def notes(self, start_beat, dur_beats, ms, vel=0.45, stagger=0.0):
        for i, m in enumerate(ms):
            self.note(start_beat + i * stagger, dur_beats, m, vel)
        return self

    def pedal(self, start_beat, end_beat):
        self.pedals.append((float(start_beat), float(end_beat)))
        return self

    def pedal_bars(self, first_bar, count, per=1):
        """Pedal down for `per` bars at a time, `count` bars from `first_bar`."""
        b = self.beats_per_bar
        i = 0
        while i < count:
            span = min(per, count - i)
            self.pedal((first_bar + i) * b, (first_bar + i + span) * b)
            i += span
        return self

    # -- queries ------------------------------------------------------------

    @property
    def end_beat(self):
        return max([b + d for (b, d, _m, _v) in self.events] +
                   [e for (_s, e) in self.pedals] + [0.0])

    def _merged_pedals(self):
        raw = sorted((beats_to_seconds(a, self.bpm), beats_to_seconds(b, self.bpm))
                     for (a, b) in self.pedals)
        out = []
        for (a, b) in raw:
            if out and a <= out[-1][1] + 1e-6:
                out[-1] = (out[-1][0], max(out[-1][1], b))
            else:
                out.append((a, b))
        return out

    def melody_names(self, low=None):
        """The written pitches in time order, as names - for the report."""
        ev = sorted(self.events)
        return [note_name(m) for (_b, _d, m, _v) in ev
                if low is None or m >= midi(low)]

    def pitch_classes_by_bar(self):
        """{bar: sorted pitch-class names} - what the harmony actually IS."""
        names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        out = {}
        for (b, _d, m, _v) in self.events:
            bar = int(b // self.beats_per_bar)
            out.setdefault(bar, set()).add(names[int(round(m)) % 12])
        return {k: sorted(v) for k, v in sorted(out.items())}

    def sounding_pitch_classes_by_bar(self, floor_db=-22.0):
        """What is AUDIBLE in each bar, ringing notes included.

        `pitch_classes_by_bar` reports what is struck; this reports what the
        ear is actually holding, which under a sustain pedal is a different
        thing and is the only honest way to describe this harmony. A note
        counts in a bar if it was struck in or before it, has not been
        damped, and its own decay has not yet put it below `floor_db`.
        """
        names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        peds = self._merged_pedals()

        def pedal_end_at(t):
            for (a, bb) in peds:
                if a - 1e-6 <= t < bb:
                    return bb
            return None

        bar_s = beats_to_seconds(self.beats_per_bar, self.bpm)
        nbars = int(math.ceil(self.end_beat / self.beats_per_bar))
        out = {}
        for (beat, dur_beats, m, _v) in self.events:
            t_on = beats_to_seconds(beat, self.bpm)
            t_off = t_on + beats_to_seconds(dur_beats, self.bpm)
            pe = pedal_end_at(t_off)
            ring_end = pe if pe is not None else t_off
            # audible until the slow stage of the fundamental crosses the floor
            _tf, tau_s = piano_partial_taus(m, 1)
            ring_end = min(ring_end, t_on + tau_s * math.log(10.0) * (-floor_db / 20.0))
            for bar in range(int(t_on // bar_s), min(nbars, int(ring_end // bar_s) + 1)):
                out.setdefault(bar, set()).add(names[int(round(m)) % 12])
        return {k: sorted(v) for k, v in sorted(out.items())}

    def bass_line(self, ceiling="C3"):
        """The governing bass of each bar: the lowest note struck in it below
        `ceiling`, or - if the bar strikes none - the one still holding from
        an earlier bar, which under a pedal is what the ear is standing on."""
        top = midi(ceiling)
        low = {}
        for (b, _d, m, _v) in self.events:
            if m > top:
                continue
            bar = int(b // self.beats_per_bar)
            if bar not in low or m < low[bar]:
                low[bar] = m
        out, held = [], None
        nbars = int(math.ceil(self.end_beat / self.beats_per_bar))
        for bar in range(nbars):
            if bar in low:
                held = low[bar]
                out.append((bar, note_name(held)))
            else:
                out.append((bar, ("(%s)" % note_name(held)) if held is not None else "-"))
        return out

    # -- rendering ----------------------------------------------------------

    def render(self, extra_tail=6.0):
        r = S.rng(S.seed_from("%s|piano|%d" % (self.seed, len(self.events))))
        peds = self._merged_pedals()

        def pedal_end_at(t):
            for (a, b) in peds:
                if a - 1e-6 <= t < b:
                    return b
            return None

        ev = []
        for (beat, dur_beats, m, vel) in sorted(self.events):
            t_on = beats_to_seconds(beat, self.bpm)
            if self.humanise:
                t_on = max(0.0, t_on + float(r.normal(0.0, self.humanise)))
            v = float(np.clip(vel + r.normal(0.0, 0.022), 0.05, 1.0))
            ev.append((t_on, beats_to_seconds(dur_beats, self.bpm), m, v,
                       int(r.integers(0, 3))))
        ev.sort()

        total = 0.0
        for (t_on, _d, m, _v, _t) in ev:
            total = max(total, t_on + piano_ring(m))
        total = max(total, beats_to_seconds(self.end_beat, self.bpm)) + float(extra_tail)
        left = np.zeros(S.n(total) + S.n(3.0))
        right = np.zeros(len(left))
        ringing = []                       # (f0, ring_end_seconds)

        for (t_on, dur_s, m, v, turn) in ev:
            y = None
            if self.bank != "synth":
                y = sampled_piano_note(m, v, self.bank, turn)
            if y is None:
                y = piano_note(m, v, turn)
            t_off = t_on + dur_s
            pe = pedal_end_at(t_off)
            ring_end = pe if pe is not None else t_off
            cut = S.n(max(0.0, ring_end - t_on))
            if cut < len(y):
                y = _damper_close(y, cut, m, r)
            f0 = float(hz(m))

            # Sympathetic answer, only while the dampers are off.
            if self.sympathetic > 0.0 and pedal_end_at(t_on) is not None:
                live = [f for (f, e) in ringing
                        if e > t_on + 0.05 and abs(f - f0) > 0.5]
                if live:
                    live = sorted(live, key=lambda f: abs(math.log(f / f0)))[:3]
                    mono = y if y.ndim == 1 else y.mean(axis=1)
                    sym = _sympathetic(mono[:S.n(0.75)] * 0.5, live,
                                       level=self.sympathetic * v)
                    if sym is not None:
                        pad = max(0, len(sym) - len(y))
                        if y.ndim == 1:
                            y = np.concatenate([y, np.zeros(pad)])
                            y[:len(sym)] += sym
                        else:
                            y = np.concatenate([y, np.zeros((pad, 2))])
                            y[:len(sym), 0] += sym
                            y[:len(sym), 1] += sym

            ringing.append((f0, ring_end))
            if len(ringing) > 24:
                ringing = ringing[-24:]

            # The stereo image is the keyboard. A MONO (3d) note is panned by
            # pitch; a SAMPLED note already has the instrument's own image and
            # is only tilted, so the recording's width survives.
            pan = float(np.clip((m - 60.0) / 34.0, -1.0, 1.0)) * self.spread
            i0 = S.n(t_on)
            k = min(len(y), len(left) - i0)
            if k <= 0:
                continue
            if y.ndim == 1:
                gl = math.sqrt(0.5 * (1.0 - pan)) * 1.4142
                gr = math.sqrt(0.5 * (1.0 + pan)) * 1.4142
                left[i0:i0 + k] += y[:k] * gl
                right[i0:i0 + k] += y[:k] * gr
            else:
                gl = math.sqrt(max(0.0, 1.0 - pan * 0.7))
                gr = math.sqrt(max(0.0, 1.0 + pan * 0.7))
                left[i0:i0 + k] += y[:k, 0] * gl
                right[i0:i0 + k] += y[:k, 1] * gr

        out = np.stack([left, right], axis=1) * self.gain
        return out


def piano_room(x, rt=1.7, damping=0.66, mix=0.18, predelay=0.020, seed=7, tail=True):
    """A warm small-to-medium room, 1.4-2.2 s. A nocturne is not in a cathedral."""
    return S.reverb(x, size=float(rt), damping=float(damping), mix=float(mix),
                    predelay=float(predelay), seed=seed, tail=tail)


# -- the violin. One player. ------------------------------------------------
#
# 3c's `bowed` engine is right; what it was doing wrong for this music is
# being a SECTION. One voice, no section detune, a slower bow, a little more
# vibrato (a soloist leans where a section cannot), and a level that sits
# under the piano rather than over it.

SOLO_VLN = _sect("solo_vln", voices=1, body=BODY_VIOLIN_AC, hp=150.0, tilt=0.94,
                 even=0.80, warm=0.048, bow=0.070, air=0.026, vib=15.0,
                 vib_rate=5.3, detune=0.0, jitter=0.012, kmax=20, top=8000.0,
                 level=0.30, attack=0.26)
SOLO_VLN_PAIR = _sect("solo_vln_pair", voices=2, body=BODY_VIOLIN_AC, hp=150.0,
                      tilt=0.96, even=0.80, warm=0.050, bow=0.068, air=0.024,
                      vib=13.0, vib_rate=5.2, detune=4.0, jitter=0.026, kmax=20,
                      top=7800.0, level=0.26, attack=0.28)
SOLO_VLN_TREM = _sect("solo_vln_trem", voices=1, body=BODY_VIOLIN_AC, hp=140.0,
                      tilt=1.02, even=0.80, warm=0.038, bow=0.140, air=0.028,
                      vib=7.0, vib_rate=5.0, detune=0.0, jitter=0.014, kmax=16,
                      top=6600.0, level=0.24, attack=0.10, trem=0.34)


def violin_solo(freq, dur, vel=0.45, r=None):
    """One violin. Long bows, late vibrato, never a bed."""
    return bowed(freq, dur, vel, r, SOLO_VLN)


def violin_pair(freq, dur, vel=0.42, r=None):
    """Two players on the one line - the rare doubled phrase."""
    return bowed(freq, dur, vel, r, SOLO_VLN_PAIR)


def violin_trem(freq, dur, vel=0.38, r=None):
    """Bowed tremolo, for the boss stems' `high`."""
    return bowed(freq, dur, vel, r, SOLO_VLN_TREM)


INSTRUMENTS.update({
    "piano": piano, "violin_solo": violin_solo, "violin_pair": violin_pair,
    "violin_trem": violin_trem,
})


# ---------------------------------------------------------------------------
# 3e. SAMPLED instruments - FL Studio's bundled content, decoded at render time
# ---------------------------------------------------------------------------
#
# "Use actual piano, not just synth." The section-3d model is a good piano and
# it is still here (it is the fallback, and it is what a machine without FL
# Studio renders), but a sampled grand is a recording of a real instrument and
# nothing additive catches the way a felt hammer actually sounds at pp.
#
# WHAT IS BEING READ. FL Studio ships its instrument content as WAV files that
# are not PCM: the `fmt` tag is 0x674F ("Og") and the data chunk is a complete
# OGG VORBIS stream. So a plain `soundfile.read` fails and the fix is one line
# - slice from the first b"OggS" and hand THAT to soundfile. Nothing is copied
# into the repo: the samples are read from the app bundle at render time and
# only the finished OGG bundles are committed. See CONTRACT.md §6.
#
# THE KEY MAP, AND WHY IT IS ASSERTED. `Stage Grand N.wav` maps to MIDI 20+N,
# which makes `Stage Grand 40` middle C. A map that is wrong by one is a wrong
# note in every bar of every piece and nothing downstream would catch it, so
# `verify_sample_maps()` checks all 88 keys with TWO independent estimators:
#
#   * YIN (cumulative-mean-normalised difference, first dip under 0.12).
#     Correct on 81/88. It fails on the top octave (N=81..88) where the
#     period is under 20 samples at 44.1 kHz.
#   * a harmonic-template score at the EXPECTED pitch: a peak within 70 cents
#     of f0 at >18 dB over the local spectral median, with 2f and 3f present.
#     Correct on 76/88. It fails on the bottom octave (N=1..12) where a real
#     grand has almost no energy at the fundamental at all - there the second
#     and third partials measure 10-190x the fundamental, which is the
#     instrument being a piano, not the map being wrong.
#
# The two failure sets are disjoint (top octave vs bottom octave), so the
# union verifies 88/88. The numbered families (choir, brass, strings,
# woodwind, Rhodes) carry no pitch in the filename at all and their roots are
# DETECTED with YIN at import - all of them land within 0.12 semitones of an
# exact MIDI number, which is itself a check that the detector is right.
#
# LOOPING, AND WHY NOT THE SOUNDFONT. The sustained families are 2-3 s, which
# is shorter than a held string note, so they are crossfade-looped: find the
# offset in the back half with the highest normalised cross-correlation
# against a 450 ms window, then splice with a 350 ms equal-power crossfade.
# The alternative was `Soundfonts/STR_Ensemble.sf2` through Apple's
# AVAudioUnitSampler in offline manual-rendering mode, which does work (a
# Swift CLI rendered a 5 s C4 correctly). It was MEASURED against the looped
# WAV on a held C4 and lost:
#
#     sf2 via AVAudioUnitSampler   centroid 1338 Hz  drift 0.138  flatness 0.0174  worst frame jump 0.466
#     OSTR C3 crossfade loop       centroid 1325 Hz  drift 0.026  flatness 0.0059  worst frame jump 0.160
#
# Same timbre (the centroids agree to 1%), but the soundfont route is five
# times less steady frame to frame and three times noisier - and it would
# have covered strings only, while leaving choir, brass, woodwind and
# percussion on the WAV route anyway, and would have made the build depend on
# swiftc and AVFoundation. One route for everything, and it is the better
# sounding one.

FL_PACKS = ("/Applications/FL Studio 2024.app/Contents/Resources/FL/Data/"
            "Patches/Packs")
FL_AVAILABLE = os.path.isdir(FL_PACKS)
_FL_WARNED = [False]


def fl_available():
    """True if the sampled content is present. Everything degrades to 3d if not."""
    if not FL_AVAILABLE and not _FL_WARNED[0]:
        _FL_WARNED[0] = True
        sys.stderr.write(
            "\n*** WARNING: FL Studio sample content not found at\n"
            "***   %s\n"
            "*** Falling back to the synthesised section-3d piano and the\n"
            "*** section-3c additive strings. The render will be DIFFERENT\n"
            "*** from the committed bundles. See CONTRACT.md section 6.\n\n"
            % FL_PACKS)
    return FL_AVAILABLE


_WAV_CACHE = {}
_WAV_ORDER = []
_WAV_MAX = 160


def fl_decode(path):
    """(N, 2) float64 at SR. FL's WAVs wrap an OGG stream; slice from OggS."""
    hit = _WAV_CACHE.get(path)
    if hit is not None:
        return hit.astype(np.float64)
    import soundfile as _sf
    with open(path, "rb") as fh:
        raw = fh.read()
    i = raw.find(b"OggS")
    y, sr = _sf.read(io.BytesIO(raw[i:] if i >= 0 else raw),
                     dtype="float64", always_2d=True)
    if y.shape[1] == 1:
        y = np.repeat(y, 2, axis=1)
    y = y[:, :2]
    if int(sr) != SR:
        y = np.stack([_resample(y[:, 0], SR / float(sr)),
                      _resample(y[:, 1], SR / float(sr))], axis=1)
    y = np.ascontiguousarray(y)
    _WAV_CACHE[path] = y.astype(np.float32)
    _WAV_ORDER.append(path)
    if len(_WAV_ORDER) > _WAV_MAX:
        _WAV_CACHE.pop(_WAV_ORDER.pop(0), None)
    return y


def _resample(x, factor):
    """Linear-interpolation resample by `factor` (>1 = longer = lower)."""
    x = np.asarray(x, dtype=np.float64)
    n = max(1, int(round(len(x) * float(factor))))
    idx = np.arange(n, dtype=np.float64) / float(factor)
    i0 = np.clip(idx.astype(np.int64), 0, len(x) - 1)
    i1 = np.clip(i0 + 1, 0, len(x) - 1)
    fr = idx - i0
    return x[i0] * (1.0 - fr) + x[i1] * fr


def _yin(x, sr=SR, fmin=25.0, fmax=4200.0, thresh=0.12):
    """YIN f0. See the section header for why not plain autocorrelation."""
    x = np.asarray(x, dtype=np.float64)
    x = x - x.mean()
    n = len(x)
    tmax = min(n // 2 - 2, int(sr / fmin))
    tmin = max(2, int(sr / fmax))
    if tmax <= tmin + 2 or float(np.max(np.abs(x))) < 1e-7:
        return 0.0
    N = 1 << int(math.ceil(math.log2(2 * n)))
    sp = np.fft.rfft(x, N)
    ac = np.fft.irfft(sp * np.conj(sp), N)[: tmax + 1]
    cum = np.concatenate([[0.0], np.cumsum(x * x)])
    t = np.arange(tmax + 1)
    et = cum[n] - cum[t]
    eh = cum[n - t] - cum[0]
    d = eh + et - 2.0 * ac
    d[0] = 0.0
    cs = np.cumsum(d[1:])
    cm = np.ones(tmax + 1)
    cm[1:] = d[1:] * t[1:] / (cs + 1e-18)
    tau = -1
    i = tmin
    while i < tmax:
        if cm[i] < thresh:
            while i + 1 < tmax and cm[i + 1] < cm[i]:
                i += 1
            tau = i
            break
        i += 1
    if tau < 0:
        tau = tmin + int(np.argmin(cm[tmin:tmax]))
    a, b_, c = cm[tau - 1], cm[tau], cm[tau + 1]
    off = 0.5 * (a - c) / (a - 2 * b_ + c + 1e-18)
    return sr / (tau + off)


# -- the families -----------------------------------------------------------
#
# `dir` is under FL_PACKS; `glob` finds the members; `keys` is either the
# string "grand" (filename number N -> MIDI 20+N) or None (detect with YIN).
# `sustain` marks a family that must be crossfade-looped to reach a length.

SAMPLE_FAMILIES = {
    "stage_grand":  dict(dir="Instruments/Keyboard/Stage Grand",
                         pat="Stage Grand %d.wav", n=88, keys="grand", sustain=False),
    "close_grand":  dict(dir="Instruments/Keyboard/Close Grand",
                         pat="Close Grand %d.wav", n=88, keys="grand", sustain=False),
    "ostr":         dict(dir="Instruments/Orchestral/Strings Section",
                         glob="OSTR *.wav", keys=None, sustain=True),
    "ostr_solo":    dict(dir="Instruments/Orchestral/Strings Solo",
                         glob="VRZ Full Strings Vibrato (*).wav", keys=None, sustain=True),
    "choir_ah":     dict(dir="Instruments/Orchestral/Choir Ahh",
                         glob="Choir Ahh (*).wav", keys=None, sustain=True),
    "choir_oh":     dict(dir="Instruments/Orchestral/Choir Ooh",
                         glob="Choir Ooh (*).wav", keys=None, sustain=True),
    "brass":        dict(dir="Instruments/Orchestral/Brass Section",
                         glob="Brass section (*).wav", keys=None, sustain=True),
    "winds":        dict(dir="Instruments/Orchestral/Woodwind Section",
                         glob="Woodwind section (*).wav", keys=None, sustain=True),
    "rhodes":       dict(dir="Instruments/Keyboard/Rhodes",
                         glob="Piano Rhodes (*).wav", keys=None, sustain=False),
}

# One-shots. Percussion for the boss stems: FL's Legacy hit set has real
# timpani, and the Drums packs have an orchestral-ish tom and crash.
SAMPLE_HITS = {
    "timp_c":  "Legacy/Instruments/Hits/HIT_Ctim_C4.wav",
    "timp_f":  "Legacy/Instruments/Hits/HIT_Ctim_F3.wav",
    "orchhit": "Legacy/Instruments/Hits/HIT_Orch.wav",
    "brasshit": "Legacy/Instruments/Hits/HIT_BrassTab.wav",
    "tom":     "Drums/Toms/Overhead Tom.wav",
    "tom_low": "Drums/Toms/Alma Tom.wav",
    "crash":   "Drums/Cymbals/Overhead Crash.wav",
    "ride":    "Drums/Cymbals/Grv Ride 01.wav",
}

_MAPS = {}
_ROOTS = {}


def sample_root(family, key_midi):
    """The sample's TRUE pitch as a float MIDI number.

    Not the same as its slot. The choir families are up to a third of a
    semitone off an exact pitch - real singers, not a detection error - and
    resampling against the rounded slot would ship that detuning. Resampling
    against the measured pitch does not.
    """
    return _ROOTS.get(family, {}).get(key_midi, float(key_midi))


def sample_map(family):
    """{midi -> path} for a family, detected once. Empty if FL is absent."""
    if family in _MAPS:
        return _MAPS[family]
    if not fl_available():
        _MAPS[family] = {}
        return {}
    spec = SAMPLE_FAMILIES[family]
    base = os.path.join(FL_PACKS, spec["dir"])
    out = {}
    roots = {}
    if spec.get("keys") == "grand":
        for k in range(1, spec["n"] + 1):
            p = os.path.join(base, spec["pat"] % k)
            if os.path.exists(p):
                out[20 + k] = p
                roots[20 + k] = float(20 + k)
    else:
        import glob as _glob
        for p in sorted(_glob.glob(os.path.join(base, spec["glob"]))):
            y = fl_decode(p)
            m = y.mean(axis=1)
            seg = m[S.n(0.25): S.n(0.90)] if len(m) > S.n(1.0) else m[S.n(0.05):]
            f = _yin(seg)
            if f <= 0:
                continue
            exact = 69.0 + 12.0 * math.log(f / A4_HZ, 2.0)
            mid = int(round(exact))
            out[mid] = p
            roots[mid] = exact
    _MAPS[family] = out
    _ROOTS[family] = roots
    return out


def verify_sample_maps(verbose=True):
    """Assert the key maps. Returns (checked, failures). See the header."""
    if not fl_available():
        return 0, []
    fails = []
    gm = sample_map("stage_grand")
    yin_ok = tmpl_ok = both = 0
    for mid, path in sorted(gm.items()):
        y = fl_decode(path)
        m = y.mean(axis=1)
        seg = m[S.n(0.05): S.n(0.60)]
        f_exp = float(hz(mid))
        fy = _yin(seg)
        cy = 1200.0 * math.log(fy / f_exp, 2.0) if fy > 0 else 1e9
        ok_y = abs(cy) < 50.0
        # harmonic template at the expected pitch
        N = 1 << int(math.ceil(math.log2(len(seg) * 8)))
        sp = np.abs(np.fft.rfft(seg * np.hanning(len(seg)), N))
        sp = sp / (np.max(sp) + 1e-18)
        fr = np.fft.rfftfreq(N, 1.0 / SR)

        def pk(f, cents=70.0):
            lo = np.searchsorted(fr, f * 2.0 ** (-cents / 1200.0))
            hi = np.searchsorted(fr, f * 2.0 ** (cents / 1200.0))
            if hi <= lo or lo >= len(sp):
                return 0.0, f
            i = lo + int(np.argmax(sp[lo:hi]))
            return float(sp[i]), float(fr[i])
        a1, ff = pk(f_exp)
        lo = np.searchsorted(fr, f_exp * 0.6)
        hi = np.searchsorted(fr, f_exp * 1.7)
        floor = float(np.median(sp[lo:hi])) + 1e-12
        snr = 20.0 * math.log(a1 / floor, 10.0) if a1 > 0 else -99.0
        ok_t = snr > 18.0 and abs(1200.0 * math.log(ff / f_exp, 2.0)) < 50.0
        yin_ok += ok_y
        tmpl_ok += ok_t
        if ok_y or ok_t:
            both += 1
        else:
            fails.append((mid, os.path.basename(path), round(cy, 1), round(snr, 1)))
    if verbose:
        print("  stage_grand: YIN ok %d/%d, harmonic template ok %d/%d, union %d/%d"
              % (yin_ok, len(gm), tmpl_ok, len(gm), both, len(gm)))
    for fam in ("ostr", "ostr_solo", "choir_ah", "choir_oh", "brass", "winds", "rhodes"):
        mp = sample_map(fam)
        devs = []
        for mid, path in mp.items():
            y = fl_decode(path)
            m = y.mean(axis=1)
            seg = m[S.n(0.25): S.n(0.90)] if len(m) > S.n(1.0) else m[S.n(0.05):]
            f = _yin(seg)
            if f > 0:
                devs.append(abs(69.0 + 12.0 * math.log(f / A4_HZ, 2.0) - mid))
        if verbose:
            print("  %-10s %2d roots %3d..%3d, worst deviation from an exact MIDI "
                  "number %.3f semitone" % (fam, len(mp), min(mp) if mp else 0,
                                            max(mp) if mp else 0,
                                            max(devs) if devs else 0.0))
        # 0.4 semitone: the choirs really are that far off an exact pitch, and
        # `sample_root` resamples against the MEASURED pitch, so the deviation
        # is recorded rather than shipped. Anything past 0.4 would be a
        # detector that had picked the wrong note.
        if devs and max(devs) > 0.40:
            fails.append((fam, "root detection", round(max(devs), 3), 0))
    return both, fails


# -- turning a sample into a note -------------------------------------------

def _xfade_loop(y, target_s, search=(0.55, 0.95), win=0.45, xf=0.35):
    """Extend a sustained sample to `target_s` by crossfade looping.

    The loop point is not guessed: a 450 ms window taken from the steady part
    is cross-correlated against every offset in the back half and the best
    match wins. At a 350 ms equal-power crossfade the residual seam measures
    below the sample's own frame-to-frame centroid wobble.
    """
    n = len(y)
    if n / SR >= target_s:
        return y[: S.n(target_s)]
    start = int(n * search[0])
    Lw = min(S.n(win), max(256, int(n * 0.2)))
    nx = min(S.n(xf), Lw)
    a0 = y[start:start + Lw, 0] + y[start:start + Lw, 1]
    best, bestc = max(S.n(0.08), Lw // 4), -2.0
    hi = n - start - Lw
    if hi > best:
        for off in range(max(S.n(0.08), Lw // 4), hi, 64):
            b1 = y[start + off:start + off + Lw, 0] + y[start + off:start + off + Lw, 1]
            c = float(np.dot(a0, b1) /
                      (np.linalg.norm(a0) * np.linalg.norm(b1) + 1e-18))
            if c > bestc:
                bestc, best = c, off
    per = best
    cur = y[: start + per].copy()
    seg = y[start: start + per + nx]
    if len(seg) < nx + 8:
        return S.fit(y[:, 0], target_s), S.fit(y[:, 1], target_s)
    w = np.linspace(0.0, 1.0, nx)
    fo = np.cos(w * math.pi / 2.0)[:, None]
    fi = np.sin(w * math.pi / 2.0)[:, None]
    guard = 0
    while len(cur) / SR < target_s + 0.4 and guard < 400:
        cur = np.concatenate([cur[:-nx], cur[-nx:] * fo + seg[:nx] * fi, seg[nx:]])
        guard += 1
    return cur[: S.n(target_s)]


_SAMP_CACHE = {}
_SAMP_ORDER = []
_SAMP_MAX = 700


def _nearest_root(mp, m):
    return min(mp, key=lambda k: (abs(k - m), k))


def sampled_note(family, m, dur, vel=0.6, attack=None, release=None,
                 max_shift=7.0, gain=1.0, tilt_db=-13.0, sustain=None):
    """(N, 2) - one note of a sampled family at MIDI `m`, `dur` seconds.

    Touch is emulated, because these families are one velocity layer: a gain
    from about -18 dB at pp to -4 dB at mf, a shelf that takes `tilt_db` out
    of everything above 1.6 kHz as the velocity falls (a quiet note is a
    DARKER note), and 2-6 ms of extra attack softening at the bottom.
    """
    mp = sample_map(family)
    if not mp:
        return None
    spec = SAMPLE_FAMILIES[family]
    su = spec["sustain"] if sustain is None else sustain
    v = float(np.clip(vel, 0.05, 1.0))
    key = (family, round(float(m), 2), round(float(dur), 2), round(v / 0.05) * 0.05,
           attack, release, round(float(tilt_db), 1))
    hit = _SAMP_CACHE.get(key)
    if hit is None:
        root = _nearest_root(mp, m)
        if abs(root - m) > max_shift:
            return None
        y = fl_decode(mp[root])
        ratio = 2.0 ** ((sample_root(family, root) - m) / 12.0)   # >1 = lower
        if abs(ratio - 1.0) > 1e-6:
            y = np.stack([_resample(y[:, 0], ratio), _resample(y[:, 1], ratio)], axis=1)
        rel = release if release is not None else (0.35 if su else 0.10)
        need = float(dur) + rel
        if su:
            y = _xfade_loop(y, max(need, 0.25))
        elif len(y) / SR < need:
            y = np.concatenate([y, np.zeros((S.n(need) - len(y), 2))])
        y = y[: S.n(need) + 1]
        # touch
        a = attack if attack is not None else (0.045 if su else 0.002)
        a = a + (0.004 * (1.0 - v) if not su else 0.10 * (1.0 - v))
        env = S.adsr(len(y) / SR, a=min(a, need * 0.5), d=0.05, s=1.0,
                     rel=min(rel, need * 0.6), curve=1.3)
        hi = np.stack([S.highpass(y[:, 0], 1600.0, order=2),
                       S.highpass(y[:, 1], 1600.0, order=2)], axis=1)
        y = y + hi * (S.amp_db(float(tilt_db) * (1.0 - v) ** 1.25) - 1.0)
        y = y * env[:, None]
        hit = y.astype(np.float32)
        _SAMP_CACHE[key] = hit
        _SAMP_ORDER.append(key)
        if len(_SAMP_ORDER) > _SAMP_MAX:
            _SAMP_CACHE.pop(_SAMP_ORDER.pop(0), None)
    return hit.astype(np.float64) * (S.amp_db(-18.0 + 14.0 * v) * float(gain))


_HIT_CACHE = {}


def sampled_hit(name, dur=1.2, vel=0.8, semitones=0.0, gain=1.0):
    """(N, 2) - one percussion one-shot, optionally pitched."""
    if not fl_available():
        return None
    p = os.path.join(FL_PACKS, SAMPLE_HITS[name])
    if not os.path.exists(p):
        return None
    v = float(np.clip(vel, 0.05, 1.0))
    key = (name, round(float(dur), 2), round(v / 0.05) * 0.05, round(float(semitones), 1))
    hit = _HIT_CACHE.get(key)
    if hit is None:
        y = fl_decode(p)
        if abs(semitones) > 1e-6:
            ratio = 2.0 ** (-float(semitones) / 12.0)
            y = np.stack([_resample(y[:, 0], ratio), _resample(y[:, 1], ratio)], axis=1)
        y = y[: S.n(dur) + 1]
        if len(y) < S.n(dur):
            y = np.concatenate([y, np.zeros((S.n(dur) - len(y), 2))])
        n_out = len(y)
        ramp = np.ones(n_out)
        k = min(n_out, S.n(0.06))
        ramp[-k:] = np.linspace(1.0, 0.0, k) ** 1.6
        y = y * ramp[:, None]
        hit = y.astype(np.float32)
        if len(_HIT_CACHE) > 200:
            _HIT_CACHE.clear()
        _HIT_CACHE[key] = hit
    return hit.astype(np.float64) * (v ** 1.2) * float(gain)


# -- instrument adapters: inst(freq, dur, vel, rng) -> mono or (N, 2) --------

def _from_freq(freq):
    return 69.0 + 12.0 * math.log(max(1e-6, float(freq)) / A4_HZ, 2.0)


def _sampled_inst(family, gain, tilt, fallback, attack=None, release=None,
                  max_shift=7.0):
    def fn(freq, dur, vel=0.6, r=None):
        y = sampled_note(family, _from_freq(freq), dur, vel, attack=attack,
                         release=release, max_shift=max_shift, gain=gain,
                         tilt_db=tilt)
        if y is None:
            return fallback(freq, dur, vel, r)
        return y
    return fn


strings_sec = _sampled_inst("ostr", 1.00, -13.0, violins_1, max_shift=4.0)
strings_sec_lo = _sampled_inst("ostr", 1.05, -11.0, celli_, max_shift=4.0)
strings_solo_s = _sampled_inst("ostr_solo", 0.95, -12.0, violin_solo, max_shift=4.0)
choir_ahh = _sampled_inst("choir_ah", 0.90, -14.0, pad_choir, attack=0.10, max_shift=4.0)
choir_ooh = _sampled_inst("choir_oh", 0.90, -15.0, pad_choir, attack=0.12, max_shift=4.0)
brass_sec = _sampled_inst("brass", 1.00, -12.0, brass, attack=0.06, max_shift=4.0)
winds_sec = _sampled_inst("winds", 0.95, -13.0, flute_soft, attack=0.05, max_shift=4.0)
rhodes_s = _sampled_inst("rhodes", 1.00, -12.0, music_box, max_shift=6.0)


def timpani_s(freq=98.0, dur=1.6, vel=0.85, r=None):
    """Sampled timpani, pitched by resampling from the C4 hit."""
    base = 261.63 * 0.25                       # HIT_Ctim_C4 reads as a C
    st = 12.0 * math.log(max(30.0, float(freq)) / base, 2.0)
    y = sampled_hit("timp_c", dur, vel, semitones=st, gain=1.0)
    return timpani(freq, dur, vel, r) if y is None else y


def tom_s(freq=110.0, dur=0.7, vel=0.85, r=None):
    st = 12.0 * math.log(max(40.0, float(freq)) / 110.0, 2.0)
    y = sampled_hit("tom_low", dur, vel, semitones=st, gain=1.0)
    return low_tom(freq, dur, vel, r) if y is None else y


def crash_s(freq=480.0, dur=2.2, vel=0.8, r=None):
    y = sampled_hit("crash", dur, vel, gain=0.85)
    return crash(freq, dur, vel, r) if y is None else y


def orch_hit_s(freq=110.0, dur=1.8, vel=0.85, r=None):
    st = 12.0 * math.log(max(40.0, float(freq)) / 110.0, 2.0)
    y = sampled_hit("orchhit", dur, vel, semitones=st * 0.5, gain=0.9)
    return taiko(freq, dur, vel, r) if y is None else y


# -- the sampled piano, inside the 3d pedal machinery -----------------------

PIANO_BANKS = {"stage": "stage_grand", "close": "close_grand"}


def sampled_piano_note(m, vel=0.5, bank="stage", variant=0):
    """(N, 2) free-ringing sampled note, dampers OFF, touch emulated.

    The sample IS the decay - no envelope is imposed on the body at all, so
    the 3d pedal machinery above it (ring to the end of the pedal region,
    damper close with a thump outside one, sympathetic comb bus) works on a
    real piano's decay instead of a modelled one.
    """
    fam = PIANO_BANKS.get(bank, "stage_grand")
    mp = sample_map(fam)
    if not mp:
        return None
    v = float(np.clip(vel, 0.05, 1.0))
    key = (fam, int(round(m)), round(v / 0.05) * 0.05, int(variant) % 3)
    hit = _SAMP_CACHE.get(key)
    if hit is None:
        mi = int(round(m))
        root = _nearest_root(mp, mi)
        y = fl_decode(mp[root])
        if abs(sample_root(fam, root) - mi) > 1e-4:
            ratio = 2.0 ** ((sample_root(fam, root) - mi) / 12.0)
            y = np.stack([_resample(y[:, 0], ratio), _resample(y[:, 1], ratio)], axis=1)
        # touch: a quiet note is darker, and its hammer leans in rather than
        # striking. Three variants differ only by a sub-millisecond start
        # offset, so a repeated note is not bit-identical.
        off = (int(variant) % 3) * 13
        if off:
            y = np.concatenate([y[off:], np.zeros((off, 2))])
        hi = np.stack([S.highpass(y[:, 0], 1600.0, order=2),
                       S.highpass(y[:, 1], 1600.0, order=2)], axis=1)
        y = y + hi * (S.amp_db(-15.0 * (1.0 - v) ** 1.2) - 1.0)
        soft = 0.002 + 0.005 * (1.0 - v)
        y = np.stack([S.fade(y[:, 0], soft, 0.030), S.fade(y[:, 1], soft, 0.030)], axis=1)
        hit = y.astype(np.float32)
        _SAMP_CACHE[key] = hit
        _SAMP_ORDER.append(key)
        if len(_SAMP_ORDER) > _SAMP_MAX:
            _SAMP_CACHE.pop(_SAMP_ORDER.pop(0), None)
    return hit.astype(np.float64) * S.amp_db(-18.0 + 14.0 * v)


INSTRUMENTS.update({
    "strings_sec": strings_sec, "strings_sec_lo": strings_sec_lo,
    "strings_solo_s": strings_solo_s, "choir_ahh": choir_ahh,
    "choir_ooh": choir_ooh, "brass_sec": brass_sec, "winds_sec": winds_sec,
    "rhodes_s": rhodes_s, "timpani_s": timpani_s, "tom_s": tom_s,
    "crash_s": crash_s, "orch_hit_s": orch_hit_s,
})


# ---------------------------------------------------------------------------
# 3f. the NOCTURNE authoring layer - one piece, one room, one master
# ---------------------------------------------------------------------------
#
# Every island theme, boss stem and stinger in this soundtrack is built the
# same way, so the shape is here rather than copied seven times: a sampled
# grand under a sustain pedal (`PianoPart`), zero to three quiet colour
# tracks (strings, choir, a wind, the solo violin), one shared room, and a
# master that trims to an exact bar multiple and folds the tail under bar 1.
#
# The one thing `Nocturne` adds beyond plumbing is `lh`, the left hand. A
# nocturne's left hand is not a block chord: it is the bass note, then the
# fifth or tenth above it, then a colour tone, spread across the bar and left
# to blur under the pedal. Give it a bass and a set of upper notes and it
# writes that figure, with the velocities already voiced (the bass a little
# over the inner notes, both well under the melody).

CHORDS.update({
    "maj7#11": [0, 4, 7, 11, 18], "maj13": [0, 4, 11, 14, 21],
    "6/9": [0, 4, 9, 14], "min11": [0, 3, 7, 10, 14, 17],
    "min_maj7": [0, 3, 7, 11], "sus2add9": [0, 2, 7, 14],
    "sus4add9": [0, 5, 7, 14], "min9b6": [0, 3, 7, 8, 14],
    "add11": [0, 4, 7, 17], "min7add11": [0, 3, 7, 10, 17],
    "halfdim9": [0, 3, 6, 10, 14], "dom7sus4": [0, 5, 7, 10],
    "dom9": [0, 4, 7, 10, 14], "dom7b9": [0, 4, 7, 10, 13],
    "dom7#9": [0, 4, 7, 10, 15], "maj9#5": [0, 4, 8, 11, 14],
    "min6/9": [0, 3, 9, 14], "quartal4": [0, 5, 10, 15],
    "quintal": [0, 7, 14], "oct5": [0, 7, 12],
})


class StereoTrack(Track):
    """A Track whose instrument may return (N, 2).

    The sampled families (section 3e) are stereo recordings and downmixing
    them to feed the mono Track would throw away the only stereo image in
    the piece that was not manufactured. Everything else - swing, humanise,
    the seeded rng, the reverb tuple - is Track's, unchanged; this only
    replaces the mixdown loop with one that keeps two channels and pans by
    equal power.
    """

    def render(self, extra_tail=1.5):
        bpm = self.seq.bpm
        swing = self.seq.swing if self.swing is None else self.swing
        r = S.rng(self._seed if self._seed is not None else
                  S.seed_from("%s|%s|%d" % (self.seq.seed, self.name, len(self.events))))
        total = beats_to_seconds(self.end_beat, bpm) + float(extra_tail)
        out = np.zeros((S.n(max(0.05, total)), 2))
        gl = math.sqrt(0.5 * (1.0 - self.pan)) * 1.4142
        gr = math.sqrt(0.5 * (1.0 + self.pan)) * 1.4142
        for (beat, dur_beats, m, vel, inst) in sorted(self.events):
            b = beat
            if swing:
                pos = math.fmod(b, 1.0)
                if abs(pos - 0.5) < 1e-6:
                    b = b + 0.5 * float(swing)
            if self.humanise:
                b = max(0.0, b + float(r.normal(0.0, 0.012 * self.humanise)))
            v = float(np.clip(vel + (r.normal(0.0, 0.06 * self.humanise)
                                     if self.humanise else 0.0), 0.05, 1.0))
            dur_s = max(0.02, beats_to_seconds(dur_beats, bpm))
            fn = inst or self.instrument
            voice = np.asarray(fn(float(hz(m)), dur_s, v, r), dtype=np.float64)
            fin, fout = 0.004, min(0.05, len(voice) / SR * 0.25)
            if voice.ndim == 1:
                voice = np.stack([S.fade(voice, fin, fout) * gl,
                                  S.fade(voice, fin, fout) * gr], axis=1)
            else:
                voice = np.stack([S.fade(voice[:, 0], fin, fout) * (gl / 1.4142 * 2.0
                                                                   ) ** 0.5,
                                  S.fade(voice[:, 1], fin, fout) * (gr / 1.4142 * 2.0
                                                                   ) ** 0.5], axis=1)
            i0 = S.n(beats_to_seconds(b, bpm))
            k = min(len(voice), len(out) - i0)
            if k > 0:
                out[i0:i0 + k] += voice[:k]
        if self.reverb:
            if len(self.reverb) == 4:
                size, damp, mixv, pre = self.reverb
            else:
                size, damp, mixv = self.reverb
                pre = 0.0
            out = np.stack([S.reverb(out[:, 0], size=size, damping=damp, mix=mixv,
                                     predelay=pre, seed=7)[:len(out)],
                            S.reverb(out[:, 1], size=size, damping=damp, mix=mixv,
                                     predelay=pre, seed=9)[:len(out)]], axis=1)
        return out * self.gain


class Nocturne(object):
    """One piece. `bars` bars at `bpm`, rendered, trimmed and loop-wrapped.

        p = Nocturne("island_ice", bpm=54, bars=40, tail=8.0)
        p.pedal_bars(0, 40, per=2)
        p.lh(0, "C2", ["G2", "E3", "D4"], vel=0.22)
        p.mel([(p.b(0, 1), 3.0, "G5", 0.40)])
        strings = p.track(strings_sec, "strings", gain=0.5, reverb=(2.4, .72, .22, .03))
        audio = p.render()
    """

    def __init__(self, name, bpm=60.0, bars=40, beats_per_bar=4, bank="stage",
                 tail=8.0, lufs=-20.0, tilt=0.0, width=0.40, sympathetic=0.16,
                 humanise=0.030, spread=0.30, room=(1.8, 0.66, 0.18, 0.021),
                 piano_gain=1.0):
        self.name = name
        self.bpm = float(bpm)
        self.bars = int(bars)
        self.beats_per_bar = int(beats_per_bar)
        self.tail = float(tail)
        self.lufs = float(lufs)
        self.tilt = float(tilt)
        self.width = float(width)
        self.room = room
        self.loop_seconds = beats_to_seconds(bars * beats_per_bar, bpm)
        self.piano = PianoPart(bpm=bpm, seed=name, gain=piano_gain,
                               humanise=humanise, sympathetic=sympathetic,
                               spread=spread, beats_per_bar=beats_per_bar,
                               bank=bank)
        self.seq = Sequencer(bpm=bpm, beats_per_bar=beats_per_bar,
                             seed=name + "|colour")
        self.harmony = {}          # bar -> the chord name the composer wrote
        self.melody = []           # (beat, name) in order, for the report

    # -- bar arithmetic -----------------------------------------------------

    def b(self, bar, off=0.0):
        return float(bar) * self.beats_per_bar + float(off)

    def track(self, instrument, name, **kw):
        tr = StereoTrack(self.seq, instrument, name=name, **kw)
        self.seq.tracks.append(tr)
        return tr

    # -- writing ------------------------------------------------------------

    def pedal(self, a, b):
        self.piano.pedal(a, b)
        return self

    def pedal_bars(self, first, count, per=1):
        self.piano.pedal_bars(first, count, per)
        return self

    def lh(self, bar, bass, uppers, vel=0.22, label=None, offs=None,
           hold=None, bass_hold=None):
        """The broken left hand of one bar: bass, then the upper notes.

        `uppers` are placed at `offs` (default: 1.5, 3.0, 3.5 ...) and held
        into the pedal. `label` is the chord name for the report.
        """
        bp = self.beats_per_bar
        if offs is None:
            offs = [1.5, 3.0, 3.5, 2.5][: len(uppers)]
        if bass is not None:
            self.piano.note(self.b(bar), bass_hold or (bp - 0.4), bass, vel)
        for i, u in enumerate(uppers):
            o = offs[i % len(offs)]
            self.piano.note(self.b(bar, o), hold or max(0.8, bp - o - 0.2), u,
                            vel * (0.80 - 0.03 * i))
        if label:
            self.harmony[int(bar)] = label
        return self

    def block(self, bar, off, dur, notes, vel=0.22, stagger=0.045, label=None):
        """A voicing struck as one gesture - a small roll, never a stab."""
        for i, m in enumerate(notes):
            self.piano.note(self.b(bar, off) + i * stagger, dur, m,
                            vel * (1.0 - 0.04 * i))
        if label:
            self.harmony[int(bar)] = label
        return self

    def mel(self, events, register=None):
        """Melody events (start_beat, dur_beats, note, vel). Recorded for the report."""
        for (t, d, m, v) in events:
            self.piano.note(t, d, m, v)
            self.melody.append((float(t), note_name(midi(m))))
        return self

    def grace(self, beat, dur, main, from_note, vel=0.30, lead=0.11):
        """A grace note: the ornament, then the note it leans into."""
        self.piano.note(beat - lead, lead * 1.6, from_note, vel * 0.62)
        self.piano.note(beat, dur, main, vel)
        self.melody.append((float(beat), note_name(midi(main))))
        return self

    def turn(self, beat, main, upper, lower, vel=0.30, step=0.16):
        """A four-note turn into `main` - main, upper, main, lower, main."""
        for i, m in enumerate((main, upper, main, lower)):
            self.piano.note(beat + i * step, step * 1.3, m, vel * 0.66)
        self.melody.append((float(beat), note_name(midi(main)) + "(turn)"))
        return self

    # -- rendering ----------------------------------------------------------

    def stems(self, extra=4.0):
        dry = self.piano.render(extra_tail=self.tail + extra)
        rt, damp, mix, pre = self.room
        wet = np.stack([S.reverb(dry[:, 0], size=rt, damping=damp, mix=mix,
                                 predelay=pre, seed=7)[:len(dry)],
                        S.reverb(dry[:, 1], size=rt, damping=damp, mix=mix,
                                 predelay=pre, seed=9)[:len(dry)]], axis=1)
        # Not `Sequencer.render_stems`: that pads every stem to the longest
        # with `S.fit`, which is mono-only, and `master` pads for itself.
        out = {}
        for tr in self.seq.tracks:
            out[tr.name] = tr.render(extra_tail=self.tail + extra)
        out["piano"] = wet
        return out

    def render(self, stems=None, lufs=None, peak_db=-2.0, low_mid=0.0,
               seam_fade=0.0):
        """`seam_fade` is `loop_wrap`'s head ramp, and it defaults to ZERO here.

        `loop_wrap` multiplies the first 12 ms of the wrapped head by a
        0.6 -> 1.0 ramp to kill a DC step at sample 0. That is right for a
        sparse render and wrong for a layered one: after the wrap, sample 0
        IS the signal at the loop point, so scaling it by 0.6 manufactures
        exactly the discontinuity the ramp is meant to prevent. Measured on
        island_ice: the ramp made |x[0] - x[N]| 1.7x the track's own 99.9th
        percentile sample step - an audible tick once a loop - and turning it
        off drops the join to a fraction of a normal step. Nothing else
        needs a fade, because the fold is what makes the seam continuous.
        """
        st = self.stems() if stems is None else stems
        mixed = master(st, target_lufs=(self.lufs if lufs is None else lufs),
                       peak_db=peak_db, tilt=self.tilt, width=self.width)
        if low_mid:
            mixed = low_mid_trim(mixed, low_mid)
        span = self.loop_seconds + self.tail
        mixed = np.stack([S.fit(mixed[:, 0], span), S.fit(mixed[:, 1], span)], axis=1)
        out = loop_wrap(mixed, self.tail, fade_in=seam_fade)
        return S.normalize_lufs(out, (self.lufs if lufs is None else lufs), peak_db)

    # -- the report ---------------------------------------------------------

    def print_harmony(self):
        snd = self.piano.sounding_pitch_classes_by_bar()
        bass = dict(self.piano.bass_line())
        print("  bar  chord            bass   sounding pitch classes")
        for bar in range(self.bars):
            print("  %3d  %-16s %-6s {%s}"
                  % (bar, self.harmony.get(bar, ""), bass.get(bar, "-"),
                     " ".join(snd.get(bar, []))))

    def print_melody(self, width=26):
        names = [n for (_t, n) in sorted(self.melody)]
        for i in range(0, len(names), width):
            print("    " + " ".join(names[i:i + width]))


# ---------------------------------------------------------------------------
# 3g. the LAYER palette - bells, and synths that are allowed in the room
# ---------------------------------------------------------------------------
#
# v4 was piano plus one colour instrument. This is the layer set that makes
# it a production: bells over the tune, a pad under the chords, a slow arp
# for motion, air above 2 kHz, and a few one-island voices.
#
# THE RULE EVERY SYNTH HERE OBEYS. A synth was rejected once for booming, so
# nothing in this section is allowed to occupy the bottom: every voice is
# HIGH-PASSED AT 120 Hz OR ABOVE, and the two that are conceptually "low"
# (the fen drone, the caldera pulse) are high-passed hardest of all - they
# are felt at 150-300 Hz, not at 40. The piano is the only instrument in
# this soundtrack with a bottom octave. Levels are set so a pad sits 12-16 dB
# under the piano's melody; these are UNDER-layers, and if you can name the
# synth while the tune is playing it is too loud.
#
# Bells are struck-metal: inharmonic partial ratios (not k*f0), a strike
# transient short enough to be a mallet rather than a click, and decays long
# enough that under the pedal they blur with the piano instead of ticking.

def _bell_partials(dur, freq, ratios, amps, taus, r=None, top=12000.0):
    """Sum of inharmonic decaying sines. The shared body of every bell here."""
    dur = max(0.08, float(dur))
    y = np.zeros(S.n(dur))
    tt = np.arange(len(y), dtype=np.float64) / SR
    for ratio, a, tau in zip(ratios, amps, taus):
        f = float(freq) * float(ratio)
        if f > top or f > 0.45 * SR:
            continue
        y += a * np.sin(S.TWO_PI * f * tt + (0.0 if r is None else float(r.random()))) \
            * np.exp(-tt / max(0.03, tau * dur))
    return y


def celesta(freq, dur, vel=0.5, r=None):
    """Celesta: a felt hammer on a small steel bar over a resonator.

    Nearly a sine at the fundamental with a bright, fast-dying 4th and 5th
    partial on top - which is why a celesta doubling a melody an octave up
    reads as light rather than as a second melody.
    """
    r = r or S.rng(71)
    v = _v(vel)
    ring = min(4.5, max(0.6, dur * 1.8))
    y = _bell_partials(ring, freq,
                       [1.0, 2.004, 3.01, 4.05, 5.42, 6.91, 9.2],
                       [1.0, 0.26, 0.13, 0.20 + 0.10 * v, 0.07, 0.035, 0.015],
                       [0.62, 0.34, 0.24, 0.16, 0.10, 0.07, 0.045], r)
    strike = np.asarray(S.white(0.010, r))[:S.n(0.010)]
    strike = S.bandpass(strike, 1800.0, 5000.0 + 4000.0 * v, order=2)
    strike *= np.exp(-np.arange(len(strike), dtype=np.float64) / SR / 0.0018)
    y[:len(strike)] += strike * 0.05 * v
    y = S.highpass(y, 200.0, order=2)
    y = S.lowpass(y, 9000.0, order=2)
    y = S.fit(y, max(dur, 0.2))
    peak = float(np.max(np.abs(y))) + 1e-12
    return S.fade(y / peak * 0.22, 0.002, min(0.10, dur * 0.3)) * v


def chime_soft(freq, dur, vel=0.45, r=None):
    """A small hanging chime. Fewer partials than the celesta, longer decay."""
    r = r or S.rng(72)
    v = _v(vel)
    ring = min(6.0, max(0.8, dur * 2.0))
    y = _bell_partials(ring, freq, [1.0, 2.76, 5.40, 8.93],
                       [1.0, 0.34, 0.14, 0.06], [0.70, 0.42, 0.24, 0.14], r)
    y = S.highpass(y, 250.0, order=2)
    y = S.fit(y, max(dur, 0.2))
    peak = float(np.max(np.abs(y))) + 1e-12
    return S.fade(y / peak * 0.19, 0.004, min(0.15, dur * 0.3)) * v


def tubular_bell(freq, dur, vel=0.55, r=None):
    """A tubular bell toll. The hum tone an octave down is most of the weight,
    and it is the ONE bell allowed below 200 Hz - it is a real instrument, not
    a synth, and it tolls four times in a piece rather than sustaining."""
    r = r or S.rng(73)
    v = _v(vel)
    ring = min(9.0, max(1.5, dur * 2.2))
    y = _bell_partials(ring, freq, [0.5, 1.0, 1.98, 2.99, 4.19, 5.43, 6.8],
                       [0.42, 1.0, 0.55, 0.30, 0.16, 0.09, 0.045],
                       [0.85, 0.62, 0.40, 0.28, 0.18, 0.12, 0.08], r)
    strike = np.asarray(S.white(0.016, r))[:S.n(0.016)]
    strike = S.bandpass(strike, 900.0, 4200.0, order=2)
    strike *= np.exp(-np.arange(len(strike), dtype=np.float64) / SR / 0.0030)
    y[:len(strike)] += strike * 0.06 * v
    y = S.highpass(y, 90.0, order=2)
    y = S.fit(y, max(dur, 0.3))
    peak = float(np.max(np.abs(y))) + 1e-12
    return S.fade(y / peak * 0.24, 0.003, min(0.20, dur * 0.3)) * v


def music_box_worn(freq, dur, vel=0.45, r=None):
    """A music box that has been in the damp: two combs, one 9 cents flat,
    and the top rolled off. The fen's, and nowhere else's."""
    r = r or S.rng(74)
    v = _v(vel)
    a = music_box(freq, dur, vel, r)
    b = music_box(freq * (2.0 ** (-9.0 / 1200.0)), dur, vel * 0.75, r)
    n = max(len(a), len(b))
    y = np.zeros(n)
    y[:len(a)] += a
    y[:len(b)] += b * 0.8
    y = S.lowpass(y, 3400.0, order=2)
    return S.highpass(y, 220.0, order=2) * 0.62


# -- the synth layers -------------------------------------------------------

def warm_pad_syn(freq, dur, vel=0.5, r=None, cutoff=1350.0, hp=130.0,
                 attack=None, level=0.15):
    """The bed. Detuned saws, a low-pass that opens over a second and closes
    again, high-passed at 130 Hz so it never competes with the piano's left
    hand. It is meant to be noticed only when it stops."""
    r = r or S.rng(75)
    v = _v(vel)
    dur = max(0.4, float(dur))
    # `phase_seed` takes an rng, not an int, and it must be derived from the
    # PITCH so a note sounds the same whatever rendered before it.
    y = S.supersaw(dur, freq, voices=7, detune=0.010, spread=1.0,
                   phase_seed=S.rng(S.seed_from("pad|%0.2f" % freq)))
    n = len(y)
    tt = np.arange(n, dtype=np.float64) / SR
    open_env = cutoff * (0.55 + 0.45 * np.clip(tt / max(0.9, dur * 0.45), 0.0, 1.0)
                         * np.clip((dur - tt) / max(0.6, dur * 0.35), 0.0, 1.0))
    y = S.lp_sweep(y, open_env, order=2)
    y = S.highpass(y, hp, order=2)
    a = attack if attack is not None else min(1.2, max(0.35, dur * 0.30))
    y *= S.adsr(dur, a=a, d=min(0.4, dur * 0.2), s=0.92,
                rel=min(max(0.5, dur * 0.35), dur * 0.5), curve=1.4)
    y = S.chorus(y, rate=0.23, depth_ms=7.0, voices=3, mix=0.35, seed=5)
    peak = float(np.max(np.abs(y))) + 1e-12
    return y / peak * level * (v ** 1.1)


def glass_pad_syn(freq, dur, vel=0.45, r=None):
    """Bowed glass. Sine partials with independent slow swells and no attack
    at all - the Gloomtrench's pad, and the only one with no saw in it."""
    r = r or S.rng(76)
    v = _v(vel)
    dur = max(0.5, float(dur))
    tt = np.arange(S.n(dur), dtype=np.float64) / SR
    y = np.zeros(len(tt))
    for k, a in ((1, 1.0), (2, 0.42), (3, 0.18), (4, 0.11), (6, 0.05), (8, 0.03)):
        swell = 0.72 + 0.28 * np.sin(S.TWO_PI * (0.07 + 0.05 * k) * tt + k * 1.7)
        y += a * swell * np.sin(S.TWO_PI * freq * k * (1.0 + 0.0006 * k) * tt
                                + float(r.random()) * S.TWO_PI)
    y = S.highpass(y, 150.0, order=2)
    y = S.lowpass(y, 5200.0, order=2)
    y *= S.adsr(dur, a=min(1.6, dur * 0.38), d=0.3, s=0.95,
                rel=min(max(0.6, dur * 0.35), dur * 0.5), curve=1.5)
    peak = float(np.max(np.abs(y))) + 1e-12
    return y / peak * 0.14 * (v ** 1.1)


def shimmer_syn(freq, dur, vel=0.4, r=None):
    """Air. Only what is above 2 kHz: the note's 4th, 6th and 8th partials
    plus a breath of band noise, drifting slowly and panned wide by the
    caller. High-passed at 2 kHz by construction, so it adds sparkle and
    cannot add weight."""
    r = r or S.rng(77)
    v = _v(vel)
    dur = max(0.5, float(dur))
    tt = np.arange(S.n(dur), dtype=np.float64) / SR
    y = np.zeros(len(tt))
    for k, a in ((4, 1.0), (6, 0.55), (8, 0.34), (11, 0.16), (16, 0.07)):
        f = float(freq) * k
        if f < 1800.0 or f > 14000.0:
            continue
        drift = 1.0 + 0.0013 * np.sin(S.TWO_PI * (0.09 + 0.04 * k) * tt + k)
        y += a * np.sin(S.TWO_PI * f * np.cumsum(drift) / SR + float(r.random()))
    air = S.band_noise(dur, r, 3800.0, 12000.0, order=2)
    y = y + air * 0.22
    y = S.highpass(y, 2000.0, order=2)
    y *= S.adsr(dur, a=min(1.4, dur * 0.35), d=0.3, s=0.9,
                rel=min(max(0.6, dur * 0.35), dur * 0.5), curve=1.5)
    peak = float(np.max(np.abs(y))) + 1e-12
    return y / peak * 0.10 * (v ** 1.2)


def pluck_syn(freq, dur, vel=0.5, r=None):
    """The arp voice. A soft-attacked triangle-and-saw blend, short, quiet,
    high-passed at 160 Hz. Motion without a beat."""
    r = r or S.rng(78)
    v = _v(vel)
    ring = min(1.6, max(0.22, dur * 1.2))
    y = S.tri(ring, freq) * 0.7 + S.saw(ring, freq, bright=0.5) * 0.3
    y = S.lowpass(y, 1500.0 + 2200.0 * v, order=2)
    y = S.highpass(y, 160.0, order=2)
    y *= S.perc_env(ring, attack=0.014, tau=max(0.12, ring * 0.34), curve=1.1)
    y = S.fit(y, max(dur, 0.12))
    peak = float(np.max(np.abs(y))) + 1e-12
    return S.fade(y / peak * 0.17, 0.010, min(0.08, dur * 0.3)) * v


def drone_syn_dark(freq, dur, vel=0.5, r=None):
    """The fen's drone. Saws under a 600 Hz roof, high-passed at 150 Hz -
    the LOW instrument that is not allowed to be low. It sits at 150-400 Hz
    and reads as damp air rather than as a bass."""
    r = r or S.rng(79)
    v = _v(vel)
    dur = max(0.6, float(dur))
    y = S.supersaw(dur, freq, voices=5, detune=0.013, spread=0.8,
                   phase_seed=S.rng(S.seed_from("drone|%0.2f" % freq)))
    y = S.lowpass(y, 620.0, order=4)
    y = S.highpass(y, 150.0, order=2)
    tt = np.arange(len(y), dtype=np.float64) / SR
    y *= 1.0 + 0.10 * np.sin(S.TWO_PI * 0.13 * tt + 0.7)
    y *= S.adsr(dur, a=min(2.0, dur * 0.4), d=0.4, s=0.9,
                rel=min(max(0.8, dur * 0.35), dur * 0.5), curve=1.5)
    peak = float(np.max(np.abs(y))) + 1e-12
    return y / peak * 0.13 * (v ** 1.1)


def pulse_syn_low(freq, dur, vel=0.55, r=None):
    """The caldera's pulse. A filtered pulse wave with a closing low-pass,
    high-passed at 140 Hz. It marks the bar with the piano's bass note and
    has no sub content at all - the heat is in the 200-600 Hz band."""
    r = r or S.rng(80)
    v = _v(vel)
    ring = min(2.2, max(0.3, dur * 1.1))
    y = S.pulse(ring, freq, width=0.34)
    tt = np.arange(len(y), dtype=np.float64) / SR
    y = S.lp_sweep(y, 900.0 * np.exp(-tt / max(0.25, ring * 0.4)) + 230.0, order=2)
    y = S.highpass(y, 140.0, order=2)
    y *= S.perc_env(ring, attack=0.030, tau=max(0.22, ring * 0.42), curve=1.2)
    y = S.fit(y, max(dur, 0.15))
    peak = float(np.max(np.abs(y))) + 1e-12
    return S.fade(y / peak * 0.16, 0.012, min(0.10, dur * 0.3)) * v


def reed_syn(freq, dur, vel=0.5, r=None):
    """The wreck's accordion. `reed` with the bellows quieter and the bottom
    taken out at 170 Hz, because an accordion in a lament is a texture."""
    y = reed(freq, dur, vel, r)
    y = S.highpass(np.asarray(y, dtype=np.float64), 170.0, order=2)
    y = S.lowpass(y, 4200.0, order=2)
    return y * 0.52


def bass_syn(freq, dur, vel=0.6, r=None):
    """The bosses' synth bass. Saw + square through a resonant low-pass,
    HIGH-PASSED AT 120 Hz: it doubles the piano's ostinato an octave up in
    the 150-500 Hz band and leaves the actual bottom to the grand."""
    r = r or S.rng(81)
    v = _v(vel)
    ring = min(1.4, max(0.16, dur * 1.15))
    y = S.saw(ring, freq, bright=0.7) * 0.6 + S.square(ring, freq) * 0.4
    tt = np.arange(len(y), dtype=np.float64) / SR
    y = S.moog(y, 700.0 + 1600.0 * v * np.exp(-tt / max(0.12, ring * 0.35)), res=0.42)
    y = S.highpass(y, 120.0, order=2)
    y *= S.perc_env(ring, attack=0.006, tau=max(0.10, ring * 0.36), curve=1.1)
    y = S.fit(y, max(dur, 0.10))
    peak = float(np.max(np.abs(y))) + 1e-12
    return S.fade(y / peak * 0.20, 0.004, min(0.06, dur * 0.3)) * v


def rasp_syn(freq, dur, vel=0.6, r=None):
    """Pyrelisk only. A saturated saw stack, still high-passed at 130 Hz.
    Not distortion for its own sake: it puts a 1-3 kHz edge on the brass
    stabs that neither the brass nor the piano can make."""
    r = r or S.rng(82)
    v = _v(vel)
    ring = max(0.2, float(dur))
    y = S.supersaw(ring, freq, voices=5, detune=0.016, spread=0.9,
                   phase_seed=S.rng(S.seed_from("rasp|%0.2f" % freq)))
    y = S.saturate(y, drive=2.6 + 2.0 * v, mode="tanh")
    y = S.bandpass(y, 260.0, 3600.0, order=2)
    y = S.highpass(y, 130.0, order=2)
    y *= S.adsr(ring, a=0.020, d=0.10, s=0.72, rel=min(0.30, ring * 0.4), curve=1.3)
    peak = float(np.max(np.abs(y))) + 1e-12
    return S.fade(y / peak * 0.15, 0.006, min(0.08, ring * 0.3)) * v


# -- reversed piano: the swell INTO a phrase --------------------------------

def piano_reverse(freq, dur, vel=0.45, r=None, bank="stage"):
    """A piano note played backwards - it grows out of nothing and stops on
    the beat. Used once or twice a piece as the lead-in to a phrase; it is
    the only gesture in the soundtrack with no attack."""
    m = 69.0 + 12.0 * math.log(max(1e-6, float(freq)) / A4_HZ, 2.0)
    y = None
    if bank != "synth":
        y = sampled_piano_note(m, min(1.0, vel + 0.25), bank, 0)
    if y is None:
        y = piano_note(m, min(1.0, vel + 0.25), 0)
    dur = max(0.3, float(dur))
    take = min(len(y), S.n(dur))
    seg = y[:take]
    seg = seg[::-1] if seg.ndim == 1 else seg[::-1, :]
    n = len(seg)
    env = (np.arange(n, dtype=np.float64) / max(1, n - 1)) ** 1.6
    seg = seg * (env[:, None] if seg.ndim == 2 else env)
    out = seg * (0.55 * _v(vel))
    if out.ndim == 1:
        return S.fade(out, 0.02, 0.012)
    return np.stack([S.fade(out[:, 0], 0.02, 0.012),
                     S.fade(out[:, 1], 0.02, 0.012)], axis=1)


# -- a thinner, higher solo violin: harmonics -------------------------------

SOLO_VLN_HARM = _sect("solo_vln_harm", voices=1, body=BODY_VIOLIN_AC, hp=300.0,
                      tilt=1.90, even=0.70, warm=0.030, bow=0.045, air=0.040,
                      vib=5.0, vib_rate=4.8, detune=0.0, jitter=0.010, kmax=8,
                      top=9000.0, level=0.24, attack=0.34)


def violin_harmonic(freq, dur, vel=0.35, r=None):
    """Flageolet: a touched string, so almost no even partials and no weight.
    The Gloomtrench's only melodic instrument besides the piano."""
    return bowed(freq, dur, vel, r, SOLO_VLN_HARM)


INSTRUMENTS.update({
    "celesta": celesta, "chime_soft": chime_soft, "tubular_bell": tubular_bell,
    "music_box_worn": music_box_worn, "warm_pad_syn": warm_pad_syn,
    "glass_pad_syn": glass_pad_syn, "shimmer_syn": shimmer_syn,
    "pluck_syn": pluck_syn, "drone_syn_dark": drone_syn_dark,
    "pulse_syn_low": pulse_syn_low, "reed_syn": reed_syn, "bass_syn": bass_syn,
    "rasp_syn": rasp_syn, "piano_reverse": piano_reverse,
    "violin_harmonic": violin_harmonic,
})
