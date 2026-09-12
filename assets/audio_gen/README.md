# assets/audio_gen — the sound generator

Every sound in How to Fish is synthesised here, in pure Python
(numpy + scipy + soundfile). No Roblox library audio, no recordings, no
hand-typed asset ids. `CONTRACT.md` in this directory is the source of
truth for names, sheets, loudness and layout; this file is how to run it.

```
synth.py        DSP toolkit — oscillators, noise, envelopes, filters,
                physical models, effects, mastering, OGG/WAV out
music.py        notes, scales, chords, Sequencer/Track, instruments, master
cues.py         the registry: EVERY cue name in the game, declared up front
sfx_fishing.py  the reference category module — copy this pattern
sfx_*.py        one module per category sheet
music_*.py      island themes, boss stems, ambience beds, stingers
music_demo.py   the reference 30 s render (not shipped; build.py skips it)
build.py        the CLI
```

## Running it

```bash
python3 assets/audio_gen/build.py                  # render everything
python3 assets/audio_gen/build.py --only fishing   # repack the bundle holding it
python3 assets/audio_gen/build.py --check          # verify; writes nothing
python3 assets/audio_gen/build.py --preview        # + preview/ and showreel
python3 assets/audio_gen/build.py --list           # what is declared vs done
python3 assets/audio_gen/music_demo.py             # the composition example
```

Output lands in `assets/audio/bundles/` — **eleven** OGGs, not fifty:
`audio_sfx_1..2`, `audio_music_1..7`, `audio_ambience_1..2`, plus
`assets/audio/manifest.json` — and the generator rewrites
`src/Shared/Config/SoundSprites.luau`, which is GENERATED and must never be
hand-edited. `assets/audio/preview/` and `assets/audio/.cache/` are
git-ignored; the shipped OGGs are committed, because they are what gets
bulk-imported into Studio.

**Everything is a region of a bundle.** A sheet is no longer a file: the 17
category sheets are concatenated into the `audio_sfx_N` bundles, and the 24
music tracks and 9 beds into the `audio_music_N` / `audio_ambience_N` ones.
`SoundSprites` gives every cue, theme, stem, stinger and bed a
`{ file, start, length, loop }` row, and the client plays it by seeking a
clone of that bundle. Packing is greedy and deterministic (sheets in registry
order, tracks first-fit-decreasing by duration, name as the tie-break), every
bundle is kept under 6:30, and the build ASSERTS Roblox's 7:00 / 20 MB limits
with margin. A boss's `low` and `high` stem are packed as ONE unit so they
always share a bundle. `CONTRACT.md` §1 is the full story.

`--check` is the CI gate. It exits 1 when the manifest or the Luau module is
stale against the registry - per cue, per track and per BUNDLE (a member whose
audio changed, or a layout that moved a member to a different offset or a
different bundle) - and it renders nothing. Cues that are declared
but not yet implemented are REPORTED, not failed — that is the normal state
while the pack is being built. Add `--strict` to make completeness fatal
once every category module has landed.

Rendering is cached per cue AND per track under `assets/audio/.cache/`, keyed
by the source hash of the module that implemented it plus the toolkit hash, so
re-running after editing one cue re-renders one cue and repacks the one bundle
it lives in; the other ten are left alone (they print `(unchanged)`). Editing
`synth.py` re-renders everything, which is correct.

## Adding cues — the module pattern

The name is already declared in `cues.py` (every name in CONTRACT.md §3 is).
You are only supplying the render function. Five lines:

```python
from cues import cue
import synth as S

@cue("bobberPlop")                 # name must already exist in cues.py
def bobber_plop(r):                # r is a seeded numpy Generator
    return S.mix(S.bubble(0.06, 300, r, rise=3.0),          # body
                 S.splash(0.22, r, low=800, high=9500))     # transient + spray
```

Save it in `sfx_<sheet>.py` — `build.py` globs for that, so no registration
step. Rules:

- Signature is `fn(rng) -> mono float array`, or `fn(rng, index)` for a cue
  declared with `variants=4` (footsteps, thunder, gull cries).
- Use ONLY the `rng` you are handed. It is seeded from the cue name, so your
  cue renders the same whatever ran before it. Never `np.random.*`.
- Do not normalise or fade. `build.py` DC-blocks, trims the inaudible tail,
  limits, peak-normalises to −1 dBFS and puts 3 ms fades on both edges.
- Keep it tight: most SFX 0.1–1.5 s, stingers up to 3 s.
- A `loop=True` cue must be authored loop-safe: exact length, nothing
  starting near the end, LFOs completing whole cycles, and reverb applied
  with `tail=False` so the file does not run past its own loop point.

Read `sfx_fishing.py` before writing a module. It has all 29 fishing cues
and a header explaining the three-layer approach (transient / body / tail)
that separates a game sound from a beep.

## Writing music

`music_demo.py` is the worked example, and a theme differs from it only in
the notes. The shape:

```python
seq = M.Sequencer(bpm=96, beats_per_bar=4, swing=0.12, seed="island_x")
lead = seq.track(M.pluck_uke, name="lead", humanise=0.6, reverb=(0.7, 0.45, 0.16))
lead.note(start_beat, dur_beats, M.midi("D5"), velocity)
stems = seq.render_stems(extra_tail=TAIL)
audio = M.loop_wrap(M.master(stems, target_lufs=-16.0), TAIL)
```

Author to an exact bar count, render with a reverb tail hanging off the end,
then `loop_wrap` folds that tail back under bar 1 — that, not the client's
120 ms splice, is what makes a looped REGION seamless: the sound arriving at
bar 1 is the sound that was arriving there last pass, so the crossfade only
has to hide the seek. A boss theme calls
`stem_pair(low_tracks, high_tracks)` instead of `master(...)` to get two
bar-aligned, identically-mastered stems the client can crossfade mid-bar.

A `music_*.py` module exposes `TRACKS = {key: fn}` where `fn(rng)` returns
stereo audio. A key beginning `amb_` is normalised to −24 LUFS and packed
into an `audio_ambience_N` bundle; everything else is −16 LUFS into an
`audio_music_N` bundle.

## Instruments

`inst(freq_hz, dur_seconds, velocity, rng) -> mono array` — every one of
them, drums included. Write a function with that signature and a Track can
play it; you do not need to edit `music.py`.

**Pitched** — `pluck` (generic Karplus-Strong), `pluck_uke`, `pluck_harp`,
`pluck_banjo`, `pluck_bass`, `marimba`, `steel_drum` (FM pan),
`glass_bell`, `music_box`, `organ`, `pad` (detuned saws + LP + slow
attack), `pad_choir` (formant-filtered saws), `brass` (saw stack + opening
filter), `strings` (bowed, vibrato), `reed` (accordion), `whistle`,
`sub_bass`, `drone`.

**Drums** — `kick`, `snare`, `hat_closed`, `hat_open`, `shaker`,
`wood_block`, `taiko`, `timpani`, `low_tom`, `cymbal_swell`, `crash`,
`rope_creak`, `wood_knock`.

## Determinism

Every render is seeded and byte-reproducible; that is what makes `--check`
meaningful. Two things were needed to get there and both are load-bearing:

1. **Filter coefficients are rounded to 12 decimals and cached**
   (`synth._design`). `scipy.signal.butter` is not bit-deterministic — the
   same design returns coefficients differing in the last bit depending on
   array alignment. One ULP is inaudible, but every cue ends in a peak
   normalise, and dividing by a max that moved by one ULP shifts every
   sample. Symptom before the fix: a different OGG about one build in four
   with no source change.
2. **The OGG container is NOT byte-stable and cannot be made so** —
   libvorbis stamps a random stream serial into every file. So the manifest
   records `pcm_sha256`, a hash of the rendered SAMPLES — per sheet, per
   track, and per bundle over its members' hashes and their offsets — and a
   bundle is only rewritten when that hash moves. Rebuilding an unchanged
   pack leaves all eleven files (and the git tree) alone.

## Loudness

SFX: peak-normalised to −1 dBFS after a soft limiter, mono. Per-cue balance
lives in the Luau catalogue's `volume`, not in these files. Music: −16 LUFS
(RMS proxy), ambience: −24 LUFS, both stereo, true peak −1 dBFS. Vorbis
decoding can overshoot an encoded peak by a few tenths of a dB; that is
normal for a lossy codec and the client's mixer has the headroom.

## Importing into Studio

Brief version — `CONTRACT.md` §2 and `docs/import-checklist.md` row 8 have
the detail.

1. Run `python3 assets/audio_gen/build.py`, then `--check` (must exit 0).
   Both print the bundle list with durations and sizes.
2. Asset Manager → Bulk Import → Audio, selecting all eleven files under
   `assets/audio/bundles`: `audio_sfx_1`, `audio_sfx_2`, `audio_music_1` …
   `audio_music_7`, `audio_ambience_1`, `audio_ambience_2`. Roblox caps audio
   uploads per month (~100 with ID verification) and each file must be under
   7 minutes and 20 MB, which is the shape of the whole pack: as few files as
   those two limits allow.
3. Drag every imported Sound into a Folder named `SoundPack` under
   `ReplicatedStorage/Assets`. Each Sound's Name is the file's basename
   without the extension — that name is the lookup key (`SoundSprites.files`
   is exactly this list), so do not rename.
4. `SoundSprites.luau` is already generated and committed; `Sfx.luau` plays a
   cue by seeking its bundle to `start` and stopping at `start + length`, and
   `MusicController.luau` loops a theme, stem or bed as a region of its bundle
   with two alternating clones and a 120 ms crossfade over the seek.
