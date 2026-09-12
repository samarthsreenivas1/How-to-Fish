"""music_stingers.py - the three cards (CONTRACT.md §4).

Not loops and not background: three short pieces that land on a beat the
player is already watching. Same palette as everything else - the sampled
grand, the string section, brass, choir - and the same rule that nothing is
allowed to be a synth pad.

    stinger_bossIntro   4 s   a brass and piano hit, then a string swell that
                              does NOT resolve - it is a question the fight
                              answers
    stinger_victory     6 s   warm, with a celesta run and a pad: a piano figure over strings that settles
                              onto a major 9th, the first consonance in
                              several minutes
    stinger_finale     12 s   the Kraken is dead: a rising piano line, brass,
                              choir and a held maj9 with the pedal down for
                              the whole last four seconds
"""

import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import music as M  # noqa: E402
import synth as S  # noqa: E402


def _card(name, bpm, beats, seconds, build, tilt=0.0, lufs=-16.0, peak=-1.5,
          room=(2.0, 0.70, 0.20, 0.024), width=0.42):
    """Render exactly `seconds`, fade the last 120 ms, no loop wrap."""
    p = M.Nocturne(name, bpm=bpm, bars=1, tail=0.0, lufs=lufs, tilt=tilt,
                   width=width, sympathetic=0.14, humanise=0.012, spread=0.28,
                   room=room)
    build(p)
    stems = p.stems(extra=seconds + 2.0)
    mixed = M.master(stems, target_lufs=lufs, peak_db=peak, tilt=tilt, width=width)
    out = np.stack([S.fit(mixed[:, 0], seconds), S.fit(mixed[:, 1], seconds)], axis=1)
    out = np.stack([S.fade(out[:, 0], 0.004, 0.12), S.fade(out[:, 1], 0.004, 0.12)],
                   axis=1)
    return S.normalize_lufs(out, lufs, peak)


# ---------------------------------------------------------------------------

def stinger_bossIntro(rng):
    """4 s. RISES FROM THE DEEP. A hit, then a swell that stays open."""
    def build(p):
        # 100 BPM -> a beat is 0.6 s, so four seconds is about six beats.
        p.pedal(0.0, 8.0)
        p.block(0, 0.0, 3.5, ["D1", "D2", "A2"], vel=0.66, stagger=0.012,
                label="D5 hit")
        p.block(0, 0.10, 3.4, ["A3", "D4", "Eb4"], vel=0.42, stagger=0.02,
                label="D + minor 9th")
        p.mel([(1.9, 2.6, "A4", 0.46), (2.5, 2.2, "Bb4", 0.50),
               (3.1, 2.0, "D5", 0.56)])
        tr = p.track(M.strings_sec, "strings", gain=0.62, pan=-0.16,
                     humanise=0.3, reverb=(2.6, 0.70, 0.24, 0.034))
        for (t, d, m, v) in [(0.6, 4.4, "D4", 0.34), (1.4, 3.8, "A4", 0.38),
                             (2.2, 3.2, "Eb5", 0.44)]:
            tr.note(t, d, m, v)
        br = p.track(M.brass_sec, "brass", gain=0.55, pan=0.16, humanise=0.2,
                     reverb=(2.2, 0.74, 0.20, 0.028))
        for (t, d, m, v) in [(0.0, 1.6, "D2", 0.80), (0.0, 1.6, "A2", 0.66),
                             (2.4, 2.4, "Eb3", 0.62)]:
            br.note(t, d, m, v)
        pc = p.track(M.crash_s, "crash", gain=0.30, pan=0.20, humanise=0.0,
                     reverb=(2.4, 0.70, 0.20, 0.028))
        pc.note(0.0, 2.6, "C4", 0.62)
        tp = p.track(M.timpani_s, "timp", gain=0.46, pan=0.0, humanise=0.0,
                     reverb=(2.2, 0.72, 0.20, 0.026))
        tp.note(0.0, 1.8, "D2", 0.78)
        tp.note(2.4, 1.6, "D2", 0.60)
        # the saturated stack under the hit, and a bell that does not resolve
        rs = p.track(M.rasp_syn, "rasp", gain=0.28, pan=0.20, humanise=0.0,
                     reverb=(1.8, 0.76, 0.16, 0.022))
        rs.note(0.0, 1.4, "D2", 0.60)
        rs.note(2.4, 1.6, "Eb2", 0.52)
        bl = p.track(M.chime_soft, "bell", gain=0.34, pan=-0.24, humanise=0.0,
                     reverb=(3.2, 0.68, 0.30, 0.048))
        bl.note(0.0, 4.0, "D5", 0.42)
        bl.note(2.4, 2.4, "Eb5", 0.38)
    return _card("stinger_bossIntro", 100.0, 8, 4.0, build, tilt=-0.4)


def stinger_victory(rng):
    """6 s. The boss is down. Warm, and it actually resolves."""
    def build(p):
        p.pedal(0.0, 12.0)
        p.lh(0, "F1", ["C2", "F2", "A2"], vel=0.40, label="Fmaj9",
             offs=[0.35, 0.7, 1.05], hold=9.0, bass_hold=10.0)
        p.mel([(1.2, 1.0, "C4", 0.46), (1.8, 1.0, "F4", 0.48),
               (2.4, 1.0, "A4", 0.52), (3.0, 1.0, "C5", 0.56),
               (3.6, 5.0, "G5", 0.60)])
        p.block(0, 3.6, 5.0, ["E4", "A4", "D5"], vel=0.36, stagger=0.03,
                label="Fmaj13")
        tr = p.track(M.strings_sec, "strings", gain=0.60, pan=-0.16,
                     humanise=0.3, reverb=(2.8, 0.68, 0.26, 0.036))
        for (t, d, m, v) in [(0.2, 3.0, "C4", 0.36), (1.4, 3.2, "F4", 0.40),
                             (2.6, 4.6, "A4", 0.44), (3.6, 4.0, "C5", 0.46)]:
            tr.note(t, d, m, v)
        ch = p.track(M.choir_ooh, "choir", gain=0.36, pan=0.16, humanise=0.2,
                     reverb=(3.0, 0.72, 0.26, 0.044))
        for (t, d, m, v) in [(0.6, 5.0, "F3", 0.42), (2.4, 4.2, "A3", 0.40),
                             (3.6, 3.6, "C4", 0.42)]:
            ch.note(t, d, m, v)
        tp = p.track(M.timpani_s, "timp", gain=0.38, pan=0.0, humanise=0.0,
                     reverb=(2.2, 0.72, 0.20, 0.026))
        tp.note(0.0, 2.0, "F1", 0.62)
        ce = p.track(M.celesta, "celesta", gain=0.52, pan=0.24, humanise=0.3,
                     reverb=(2.6, 0.58, 0.26, 0.030))
        for (t, m, v) in [(1.2, "C6", 0.34), (1.8, "F6", 0.36), (2.4, "A6", 0.38),
                          (3.0, "C7", 0.36), (3.6, "G6", 0.40)]:
            ce.note(t, 2.4, m, v)
        pd = p.track(M.warm_pad_syn, "pad", gain=0.34, pan=-0.08, humanise=0.0,
                     reverb=(3.0, 0.70, 0.26, 0.040))
        for m in ("F3", "C4"):
            pd.note(0.0, 6.0, m, 0.40)
    return _card("stinger_victory", 100.0, 12, 6.0, build, tilt=0.3,
                 room=(2.2, 0.66, 0.22, 0.026))


def stinger_finale(rng):
    """12 s. The Kraken is slain. The only triumphant thing in the game."""
    def build(p):
        p.pedal(0.0, 26.0)
        p.lh(0, "D1", ["A1", "D2", "F2"], vel=0.42, label="Dm add9 (it starts minor)",
             offs=[0.3, 0.6, 0.9], hold=8.0, bass_hold=9.0)
        p.mel([(1.0, 1.4, "D4", 0.42), (1.8, 1.4, "F4", 0.44),
               (2.6, 1.4, "A4", 0.46), (3.4, 1.4, "C5", 0.48),
               (4.2, 2.0, "D5", 0.52)])
        # the turn to the major: the F sharpens under a held D
        p.block(2, 0.0, 9.0, ["A2", "D3", "F#3"], vel=0.44, stagger=0.03,
                label="D major arrives")
        p.mel([(9.0, 1.2, "E5", 0.56), (9.8, 1.2, "F#5", 0.58),
               (10.6, 1.2, "A5", 0.62), (11.4, 2.0, "B5", 0.62),
               (12.2, 8.0, "D6", 0.66)])
        p.block(4, 0.0, 10.0, ["D3", "A3", "E4", "F#4"], vel=0.42, stagger=0.035,
                label="Dmaj9 held to the end")
        tr = p.track(M.strings_sec, "strings", gain=0.64, pan=-0.16,
                     humanise=0.3, reverb=(3.2, 0.66, 0.28, 0.040))
        for (t, d, m, v) in [(0.2, 4.0, "D4", 0.36), (2.4, 4.0, "F4", 0.38),
                             (4.4, 4.0, "A4", 0.42), (6.4, 4.0, "D5", 0.46),
                             (8.4, 4.4, "F#5", 0.50), (11.0, 5.0, "A5", 0.52)]:
            tr.note(t, d, m, v)
        br = p.track(M.brass_sec, "brass", gain=0.54, pan=0.16, humanise=0.2,
                     reverb=(2.6, 0.72, 0.22, 0.032))
        for (t, d, m, v) in [(0.0, 2.2, "D2", 0.72), (4.4, 2.6, "A2", 0.66),
                             (8.4, 3.4, "D3", 0.74), (11.4, 4.0, "F#3", 0.70)]:
            br.note(t, d, m, v)
        ch = p.track(M.choir_ahh, "choir", gain=0.40, pan=-0.06, humanise=0.2,
                     reverb=(3.4, 0.70, 0.28, 0.048))
        for (t, d, m, v) in [(4.4, 5.0, "D4", 0.40), (8.4, 4.4, "F#4", 0.44),
                             (11.4, 4.6, "A4", 0.46)]:
            ch.note(t, d, m, v)
        tp = p.track(M.timpani_s, "timp", gain=0.44, pan=0.0, humanise=0.0,
                     reverb=(2.4, 0.72, 0.20, 0.026))
        for (t, v) in [(0.0, 0.72), (4.4, 0.58), (8.4, 0.66), (11.4, 0.62)]:
            tp.note(t, 2.0, "D1", v)
        cr = p.track(M.crash_s, "crash", gain=0.28, pan=0.20, humanise=0.0,
                     reverb=(2.8, 0.68, 0.22, 0.030))
        cr.note(0.0, 3.0, "C4", 0.56)
        cr.note(8.4, 3.6, "C4", 0.62)
        # the Maelstrom's bells, one last time, and a celesta over the maj9
        tb = p.track(M.tubular_bell, "bells", gain=0.36, pan=0.24, humanise=0.0,
                     reverb=(3.6, 0.66, 0.30, 0.055))
        for (t, m, v) in [(0.0, "D3", 0.44), (4.4, "A3", 0.38), (8.4, "D4", 0.48),
                          (11.4, "F#4", 0.44)]:
            tb.note(t, 7.0, m, v)
        ce = p.track(M.celesta, "celesta", gain=0.50, pan=-0.22, humanise=0.3,
                     reverb=(2.8, 0.56, 0.28, 0.032))
        for (t, m, v) in [(9.0, "E6", 0.34), (9.8, "F#6", 0.36), (10.6, "A6", 0.38),
                          (11.4, "B6", 0.38), (12.2, "D7", 0.42)]:
            ce.note(t, 3.0, m, v)
        pd = p.track(M.warm_pad_syn, "pad", gain=0.36, pan=0.06, humanise=0.0,
                     reverb=(3.4, 0.72, 0.28, 0.048))
        for m in ("D3", "A3"):
            pd.note(0.0, 8.0, m, 0.40)
        for m in ("D3", "A3", "F#4"):
            pd.note(8.0, 6.0, m, 0.42)
    return _card("stinger_finale", 60.0, 12, 12.0, build, tilt=0.2,
                 room=(2.4, 0.64, 0.24, 0.028))


TRACKS = {
    "stinger_bossIntro": stinger_bossIntro,
    "stinger_victory": stinger_victory,
    "stinger_finale": stinger_finale,
}


if __name__ == "__main__":
    for k, fn in TRACKS.items():
        a = fn(S.rng(k))
        print("%-20s %5.3f s  peak %.3f" % (k, len(a) / S.SR, float(np.max(np.abs(a)))))
