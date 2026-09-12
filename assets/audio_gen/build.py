#!/usr/bin/env python3
"""build.py - render every sprite sheet, every music track, and the Luau map.

USAGE

    python3 assets/audio_gen/build.py                 # render everything
    python3 assets/audio_gen/build.py --only fishing  # one sheet or music key
    python3 assets/audio_gen/build.py --check         # render nothing, verify
    python3 assets/audio_gen/build.py --preview       # + previews and showreel
    python3 assets/audio_gen/build.py --list          # what is declared/missing

WHAT IT PRODUCES

    assets/audio/bundles/audio_sfx_N.ogg       mono, the sprite sheets end to end
    assets/audio/bundles/audio_music_N.ogg     stereo, themes/stems/stingers
    assets/audio/bundles/audio_ambience_N.ogg  stereo, the beds
    assets/audio/manifest.json                 bundles, tracks, cues
    src/Shared/Config/SoundSprites.luau        GENERATED - the client's lookup

EVERYTHING IS A REGION OF A BUNDLE, and that is the whole point of this
file. Roblox caps audio UPLOADS (about 100 a month with ID verification)
but puts no cap on the length of one file beyond 7 minutes and 20 MB - so
the cheapest thing a human has to do, which is click "import" fifty times
and then name fifty Sounds correctly, is the thing we buy down. The 17
logical sprite sheets are concatenated into a couple of `audio_sfx_N.ogg`,
the 24 music tracks into ~7 `audio_music_N.ogg`, the 9 beds into two
`audio_ambience_N.ogg`: eleven files to import instead of fifty. Nothing
about playback changes in kind - a cue was already a slice of a sheet, and
now a THEME is a slice too, looped by the client between `start` and
`start + length` instead of by `Sound.Looped`.

    bundle  = one OGG, under BUNDLE_SECONDS (margin under the 7 min cap)
    member  = one sheet or one track inside a bundle, at a known offset
    cue     = one sprite inside a sheet, so its bundle start is the sum

Packing is greedy and DETERMINISTIC: sheets go in registry order, tracks
first-fit-decreasing by duration with the name as the tie-break, so the
same inputs always produce the same layout. A boss's `low` and `high` stem
are ONE unit and always land in the same bundle - the client crossfades
between them continuously, and two bundles means two preloads and two
streams for one piece of music.

MODULE DISCOVERY is by glob, not by an import list, so a category module
added later is picked up with no edit here:

    sfx_*.py     register cues with @cue - rendered into their sheet
    music_*.py   expose `TRACKS = {key: fn}` - rendered to one file each,
                 into music/ or ambience/ (a key starting `amb_` goes to
                 ambience). `music_demo*` is skipped: it is the worked
                 example, not shipped content.

--CHECK is the gate, and it mirrors `tools/gen_mesh_colors.py --check`: it
writes NOTHING and exits 1 when the registry, the manifest and the Luau
module disagree. The reason it renders nothing is the reason that tool
gives - a check that rewrites files as a side effect is one nobody runs
casually.

UNIMPLEMENTED CUES ARE REPORTED, NOT FAILED, by default. Every name in
CONTRACT.md is declared here from day one and the category modules land one
at a time, so "not yet implemented" is the NORMAL state of this repo for as
long as the pack is being built - a check that fails on it would be red for
weeks and would therefore be ignored, which is how a real staleness gets
through. So `--check` fails on DISAGREEMENT (a stale manifest, a stale
SoundSprites.luau, a missing sheet file) and prints the unimplemented list
as information. Pass `--strict` to make completeness fatal too; that is
what to turn on in CI once every category module has landed.

INCREMENTAL. Each cue's audio is cached under assets/audio/.cache/ keyed by
(module source hash, cue name, synth.py hash, music.py hash). Editing one
cue re-renders one cue. Editing synth.py re-renders everything, which is
correct: a change to a filter changes every sound that uses it.

DETERMINISM is not a nicety here, it is what makes --check possible. Every
cue gets an rng seeded from its own NAME (never from its position), so
adding a cue in the middle of a sheet does not silently re-roll every cue
after it and produce a diff nobody asked for.

A BUNDLE'S HASH IS COMPOSED, not re-hashed off its samples. Every member
(sheet or track) records the hash of its own rendered samples, and the
bundle records a hash over its members' hashes AND their offsets. That
catches both kinds of staleness - a member whose audio moved, and a member
that moved inside the bundle - without `--check` having to concatenate a
gigabyte of cached float32 to find out.

THE OGG BYTES ARE NOT DETERMINISTIC, THOUGH, AND THAT IS NOT OUR BUG.
libvorbis stamps a random stream serial number into every Ogg container,
so writing the SAME samples twice gives two different files whose decoded
audio is bit-identical. Left alone that means every build rewrites every
sheet and shows up as a diff on ~50 binary files, which would bury a real
change completely. So the manifest records `pcm_sha256`, a hash of the
RENDERED SAMPLES, and a sheet is only rewritten when that hash moves.
`--check` compares the same hash - it is the honest staleness test, since
comparing container bytes would report a change on every single run.
"""

import argparse
import glob
import hashlib
import importlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import cues  # noqa: E402
import synth as S  # noqa: E402

AUDIO = os.path.join(ROOT, "assets", "audio")
BUNDLE_DIR = os.path.join(AUDIO, "bundles")
# The old one-file-per-sheet / per-track layout. Nothing is written here any
# more; the build removes what a previous build left, so a checkout does not
# keep offering fifty stale files to the importer.
LEGACY_DIRS = (os.path.join(AUDIO, "sfx"),
               os.path.join(AUDIO, "music"),
               os.path.join(AUDIO, "ambience"))
PREVIEW_DIR = os.path.join(AUDIO, "preview")
CACHE_DIR = os.path.join(AUDIO, ".cache")
MANIFEST = os.path.join(AUDIO, "manifest.json")
LUAU_OUT = os.path.join(ROOT, "src", "Shared", "Config", "SoundSprites.luau")

GAP_SECONDS = 0.150       # silence between cues on a sheet (CONTRACT §1)
CUE_PEAK_DB = -1.0        # every cue peak-normalised to this after limiting
EDGE_FADE = 0.003         # 3 ms - click insurance at every cue boundary
TRIM_FLOOR_DB = -62.0     # trailing silence below this is cut from one-shots
MUSIC_LUFS = -16.0
AMBIENCE_LUFS = -24.0

# BUNDLES. Roblox refuses an upload at 7:00 or 20 MB, so the packer targets
# 6:30 and the build then ASSERTS the real limits with margin: a bundle that
# sails past either one is a build failure here, not an import failure in
# somebody's Studio session half an hour later.
BUNDLE_SECONDS = 390.0              # 6:30 - the packing cap
BUNDLE_HARD_SECONDS = 420.0         # 7:00 - Roblox's
BUNDLE_HARD_BYTES = 19 * 1024 * 1024
SHEET_GAP_SECONDS = 0.150           # between two sheets in an SFX bundle
TRACK_GAP_SECONDS = 0.500           # between two tracks in a music bundle

# The one cue per sheet used for `--preview`. Falls back to the first cue.
PREVIEW_PICK = {
    "fishing": "catchLegendary",
    "boat": "boatArrive",
    "character": "jump",
    "combat": "hitCrack",
    "ui": "uiClick",
    "progression": "levelUp",
    "world": "thunder1",
    "creatures": "explodeBoom",
    "families": "bigFishAttack",
    "boss_shared": "bossRoar",
}
# The showreel: ~8 fishing cues, in the order a player meets them.
SHOWREEL = ["castSwing", "bobberPlop", "tug", "reelTension", "snapHit",
            "catchCommon", "catchLegendary", "flopGround"]


# ---------------------------------------------------------------------------
# module discovery
# ---------------------------------------------------------------------------

def _file_hash(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()[:16]


def _pcm_hash(audio):
    """Hash the SAMPLES, not the file. See the header: an OGG of identical
    audio is a different file every time, so this is what 'unchanged' means."""
    a = np.asarray(audio, dtype=np.float32)
    return hashlib.sha256(np.ascontiguousarray(a).tobytes()).hexdigest()[:16]


def discover():
    """Import every sfx_*.py and music_*.py. Returns (sfx_mods, music_mods)."""
    sfx_mods, music_mods = {}, {}
    for path in sorted(glob.glob(os.path.join(HERE, "sfx_*.py"))):
        name = os.path.splitext(os.path.basename(path))[0]
        sfx_mods[name] = importlib.import_module(name)
    for path in sorted(glob.glob(os.path.join(HERE, "music_*.py"))):
        name = os.path.splitext(os.path.basename(path))[0]
        if name.startswith("music_demo"):
            # The reference render. It proves the composition path works and
            # is written to preview/ by --preview; it is not shipped content.
            continue
        music_mods[name] = importlib.import_module(name)
    return sfx_mods, music_mods


def _toolkit_hash():
    parts = [_file_hash(os.path.join(HERE, "synth.py")),
             _file_hash(os.path.join(HERE, "music.py")),
             _file_hash(os.path.join(HERE, "cues.py"))]
    return hashlib.sha256("|".join(parts).encode()).hexdigest()[:16]


def _module_hash_for(cue_obj, mod_hashes):
    """The source hash of whichever module implemented this cue.

    `Cue.module` is recorded by the @cue decorator rather than read off the
    render function, because a cue with variants is stored as a closure
    whose `__module__` is cues.py - keying the cache on that would mean a
    variant cue never noticed its own module changing.
    """
    return mod_hashes.get(cue_obj.module, "nomod")


_PREV = {}


def _load_prev_manifest():
    """Read the manifest already on disk, to answer 'did this change?'."""
    _PREV.clear()
    if os.path.exists(MANIFEST):
        try:
            with open(MANIFEST) as fh:
                _PREV.update(json.load(fh))
        except (ValueError, OSError):
            pass


def _prev_pcm_hash(section, key):
    return (_PREV.get(section) or {}).get(key, {}).get("pcm_sha256")


# ---------------------------------------------------------------------------
# rendering
# ---------------------------------------------------------------------------

def _trim_tail(x, floor_db=TRIM_FLOOR_DB):
    """Cut trailing near-silence. A convolution reverb leaves half a second
    of inaudible tail on every cue; across 400 cues that is minutes of
    download and seconds of dead sprite. The audible tail is kept - the
    floor is well below anything a player hears under game audio."""
    if len(x) == 0:
        return x
    thresh = S.amp_db(floor_db) * max(1e-9, float(np.max(np.abs(x))))
    loud = np.nonzero(np.abs(x) > thresh)[0]
    if len(loud) == 0:
        return x[: S.n(0.05)]
    end = min(len(x), int(loud[-1]) + S.n(0.02))
    return x[:end]


def finish_cue(audio, loop=False):
    """The identical treatment every cue gets on its way into a sheet.

    Order matters: DC first (it wastes headroom and thumps when the sprite
    seeks), then the limiter (so peak-normalising afterwards does not just
    re-expose the transient the limiter caught), then normalise, then the
    edge fades LAST so nothing after them can reintroduce a step at the
    boundary.
    """
    y = np.asarray(audio, dtype=np.float64)
    y = S.dc_block(y, 18.0)
    if not loop:
        y = _trim_tail(y)
    y = S.limit(y, CUE_PEAK_DB - 0.2)
    y = S.normalize(y, CUE_PEAK_DB)
    # A loop gets the shortest fade that still kills a click; a longer one
    # would be audible as a dip once per loop.
    fade_len = 0.0015 if loop else EDGE_FADE
    return S.fade(y, fade_len, fade_len)


def render_cue(cue_obj, mod_hashes, use_cache=True):
    """One cue, cached. The rng is seeded from the cue NAME - see the header."""
    key = "%s|%s|%s" % (_toolkit_hash(), _module_hash_for(cue_obj, mod_hashes),
                        cue_obj.name)
    digest = hashlib.sha256(key.encode()).hexdigest()[:24]
    path = os.path.join(CACHE_DIR, "%s_%s.npy" % (cue_obj.name, digest))
    if use_cache and os.path.exists(path):
        try:
            return np.load(path)
        except (ValueError, OSError):
            pass
    raw = cue_obj.render(S.rng(cue_obj.name))
    out = finish_cue(raw, loop=cue_obj.loop).astype(np.float32)
    if use_cache:
        os.makedirs(CACHE_DIR, exist_ok=True)
        np.save(path, out)
    return out


def render_sheet(sheet, mod_hashes, use_cache=True):
    """Returns (audio, [entry...]). Cue order is registry order, which is
    CONTRACT.md order - so offsets only move when that sheet changes."""
    entries = []
    parts = []
    cursor = 0.0
    gap = S.silence(GAP_SECONDS)
    ready = [c for c in cues.by_sheet(sheet) if c.render is not None]
    for i, c in enumerate(ready):
        audio = render_cue(c, mod_hashes, use_cache)
        entries.append({
            "name": c.name, "sheet": sheet,
            "start": round(cursor, 3),
            "length": round(len(audio) / S.SR, 3),
            "loop": c.loop, "spatial": c.spatial, "desc": c.desc,
        })
        parts.append(audio)
        cursor += len(audio) / S.SR
        if i < len(ready) - 1:
            parts.append(gap)
            cursor += GAP_SECONDS
    audio = np.concatenate(parts) if parts else np.zeros(1)
    return audio.astype(np.float64), entries


def render_track(key, fn, kind, mod_hash, use_cache=True):
    """One music or ambience track, mastered and CACHED.

    Tracks used to be rendered fresh on every build, which was affordable
    while each one was its own file: a changed theme rewrote one OGG. Now
    seven tracks share a bundle and the bundle has to be concatenated from
    all of them to be written at all, so an uncached track would mean
    re-rendering six innocent themes to repack one. Same cache key shape as
    a cue: toolkit hash, the module that owns it, the key.
    """
    digest = hashlib.sha256(
        ("%s|%s|%s|%s" % (_toolkit_hash(), mod_hash, kind, key)).encode()
    ).hexdigest()[:24]
    path = os.path.join(CACHE_DIR, "track_%s_%s.npy" % (key, digest))
    if use_cache and os.path.exists(path):
        try:
            return np.load(path)
        except (ValueError, OSError):
            pass
    audio = fn(S.rng(key))
    target = MUSIC_LUFS if kind == "music" else AMBIENCE_LUFS
    audio = S.normalize_lufs(audio, target, -1.0)
    out = np.asarray(audio, dtype=np.float64)
    if out.ndim == 1:
        out = np.stack([out, out], axis=1)
    out = out.astype(np.float32)
    if use_cache:
        os.makedirs(CACHE_DIR, exist_ok=True)
        np.save(path, out)
    return out


# ---------------------------------------------------------------------------
# bundles
# ---------------------------------------------------------------------------
#
# A Bundle is a plan, not audio: the ordered list of members it holds and
# where each one starts. The audio is concatenated from that plan exactly
# once, when the bundle is written, so nothing here has to hold a gigabyte
# of float32 to decide a layout.


class Bundle(object):
    def __init__(self, name, gap):
        self.name = name
        self.gap = gap
        self.members = []          # [(member_name, start, duration)]
        self.duration = 0.0

    def span(self, duration):
        """Where this bundle would end if `duration` were added."""
        return self.duration + (self.gap if self.members else 0.0) + duration

    def add(self, member_name, duration):
        start = self.duration + (self.gap if self.members else 0.0)
        self.members.append((member_name, round(start, 3), round(duration, 3)))
        self.duration = start + duration
        return start

    def start_of(self, member_name):
        for name, start, _dur in self.members:
            if name == member_name:
                return start
        return None


def plan_bundles(prefix, units, gap, limit=BUNDLE_SECONDS, decreasing=False):
    """Greedy first-fit pack of atomic units into `prefix_1`, `prefix_2`, ...

    `units` is [(unit_name, [(member_name, duration), ...])] and a unit is
    ATOMIC: its members land in one bundle, adjacent, in the order given.
    That is what keeps a boss's two stems together.

    `decreasing` sorts by total duration first (first-fit-decreasing, the
    classic bin-packing heuristic - it is what gets 40 minutes of music into
    seven 6:30 bundles instead of nine). The tie-break is the unit name, so
    the layout is a function of the inputs and nothing else.
    """
    def unit_duration(members):
        return sum(d for _, d in members) + gap * max(0, len(members) - 1)

    ordered = list(units)
    if decreasing:
        ordered.sort(key=lambda u: (-unit_duration(u[1]), u[0]))

    bins = []
    for unit_name, members in ordered:
        total = unit_duration(members)
        if total > limit:
            raise SystemExit(
                "build: %s is %.1fs, longer than a whole %.0fs bundle - split it"
                % (unit_name, total, limit))
        target = None
        for b in bins:
            if b.span(total) <= limit:
                target = b
                break
        if target is None:
            target = Bundle("%s_%d" % (prefix, len(bins) + 1), gap)
            bins.append(target)
        for member_name, duration in members:
            target.add(member_name, duration)
    return bins


def concat_bundle(bundle, audio_for, stereo):
    """The bundle's samples: every member in plan order, `gap` between."""
    gap_n = S.n(bundle.gap)
    gap = np.zeros((gap_n, 2), dtype=np.float32) if stereo else np.zeros(gap_n, dtype=np.float32)
    parts = []
    for i, (name, _start, _dur) in enumerate(bundle.members):
        if i:
            parts.append(gap)
        parts.append(np.asarray(audio_for(name), dtype=np.float32))
    if not parts:
        return np.zeros((1, 2), dtype=np.float32) if stereo else np.zeros(1, dtype=np.float32)
    return np.concatenate(parts)


def bundle_pcm_hash(bundle, member_pcm):
    """A hash over the members' sample hashes AND their offsets - see the
    header. Moves when a member's audio moves or when the layout does."""
    payload = "|".join("%s@%.3f:%s" % (name, start, member_pcm.get(name, ""))
                       for name, start, _dur in bundle.members)
    return hashlib.sha256(payload.encode()).hexdigest()[:16]


def assert_bundle_limits(path, duration):
    """Roblox's two hard limits. A build that breaks one fails HERE."""
    if duration >= BUNDLE_HARD_SECONDS:
        raise SystemExit("build: %s is %.1fs - Roblox refuses audio at %.0fs"
                         % (os.path.basename(path), duration, BUNDLE_HARD_SECONDS))
    size = os.path.getsize(path)
    if size >= BUNDLE_HARD_BYTES:
        raise SystemExit("build: %s is %.1f MB - Roblox refuses audio at %.0f MB"
                         % (os.path.basename(path), size / 1048576.0,
                            BUNDLE_HARD_BYTES / 1048576.0))
    return size


def remove_legacy_files():
    """Delete the per-sheet and per-track OGGs a previous build wrote."""
    gone = 0
    for d in LEGACY_DIRS:
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if name.endswith(".ogg"):
                os.remove(os.path.join(d, name))
                gone += 1
        try:
            os.rmdir(d)
        except OSError:
            pass
    return gone


# ---------------------------------------------------------------------------
# the generated Luau module
# ---------------------------------------------------------------------------

def render_luau(entries, tracks, files):
    """Build SoundSprites.luau as a string. The shape is a CONTRACT with the
    Luau side (Sfx.luau reads `.files` and `.cues`, MusicController reads
    `.files`, `.music` and `.ambience`), so do not reshape it without
    changing both.

    `entries` are cue rows with an ABSOLUTE `file`/`start`; `tracks` is
    {key: row} for music and ambience; `files` is every bundle name.
    """
    lines = [
        "--!strict",
        "-- GENERATED by assets/audio_gen/build.py - do not edit by hand.",
        "--",
        "-- EVERYTHING HERE IS A REGION OF A BUNDLE. Roblox caps audio uploads per",
        "-- month, so the ~350 cues, 24 music tracks and 9 ambience beds are packed",
        "-- into the handful of OGGs listed in `files` - each one under the 7 minute",
        "-- and 20 MB per-file limits. `files` is exactly the set of Sound names the",
        "-- imported pack must contain (ReplicatedStorage/Assets/SoundPack).",
        "--",
        "-- A cue, a theme, a boss stem and a bed are all played the same way: seek",
        "-- a clone of its bundle to `start` and stop at `start + length`. A row with",
        "-- `loop = true` is authored loop-safe (its reverb tail is wrapped into its",
        "-- head), so the client loops the REGION with two alternating clones and a",
        "-- short crossfade over the seek. `Sound.Looped` is never used: it would",
        "-- loop the whole bundle.",
        "--",
        "-- Re-run the generator after any change to assets/audio_gen/**, and run",
        "-- `python3 assets/audio_gen/build.py --check` in CI: a cue name that",
        "-- exists here but not in the pack (or the reverse) fails silently at",
        "-- runtime - the sound simply never plays.",
        "",
        "local SoundSprites = {}",
        "",
        "-- The Sound names the imported pack must have, one per bundle OGG.",
        "SoundSprites.files = {",
    ]
    for name in sorted(files):
        lines.append("\t%s = true," % _luau_key(name))
    lines += ["}", "", "SoundSprites.cues = {"]
    for e in sorted(entries, key=lambda x: x["name"]):
        lines.append(
            '\t%s = { file = "%s", start = %.3f, length = %.3f, loop = %s },'
            % (_luau_key(e["name"]), e["file"], e["start"], e["length"],
               "true" if e["loop"] else "false"))
    lines += ["}", ""]
    for section, kind in (("music", "music"), ("ambience", "ambience")):
        lines.append("SoundSprites.%s = {" % section)
        for key in sorted(k for k, row in tracks.items() if row["kind"] == kind):
            row = tracks[key]
            lines.append(
                '\t%s = { file = "%s", start = %.3f, length = %.3f, loop = %s },'
                % (_luau_key(key), row["file"], row["start"], row["length"],
                   "true" if row["loop"] else "false"))
        lines += ["}", ""]
    lines += ["return SoundSprites", ""]
    return "\n".join(lines)


def _luau_key(name):
    """A bare identifier where Luau allows one, `["..."]` otherwise. Voice
    variants (`bossSlam__pyrelisk`) are legal identifiers, so they stay bare."""
    ok = name and (name[0].isalpha() or name[0] == "_")
    if ok and all(ch.isalnum() or ch == "_" for ch in name):
        return name
    return '["%s"]' % name


def run_stylua(path):
    if shutil.which("stylua") is None:
        return False
    try:
        subprocess.run(["stylua", path], cwd=ROOT, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except (subprocess.CalledProcessError, OSError):
        return False


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def build_plan(mod_hashes, music_tracks, use_cache=True):
    """Render everything (from the cache where possible) and pack it.

    This is the ONE place the layout is decided, and both the build and
    `--check` call it - a check that computed offsets by a second route
    would be checking its own arithmetic rather than the build's.

    Returns a dict of plans and hashes, plus the sheet audio (small) and a
    loader for track audio (large, so it is fetched per bundle and dropped).
    """
    sheet_audio, sheet_entries, member_pcm = {}, {}, {}
    sheet_units = []
    for sheet in cues.sheets():
        if not [c for c in cues.by_sheet(sheet) if c.render is not None]:
            continue
        audio, ent = render_sheet(sheet, mod_hashes, use_cache=use_cache)
        sheet_audio[sheet] = audio
        sheet_entries[sheet] = ent
        member_pcm[sheet] = _pcm_hash(audio)
        sheet_units.append((sheet, [(sheet, len(audio) / S.SR)]))

    # Tracks are rendered (from cache) only to learn their length and hash;
    # the samples are re-loaded a bundle at a time when one is written.
    track_len, track_kind = {}, {}
    for key in sorted(music_tracks):
        fn, kind, mod_name = music_tracks[key]
        audio = render_track(key, fn, kind, mod_hashes.get(mod_name, "nomod"),
                             use_cache=use_cache)
        track_len[key] = len(audio) / S.SR
        track_kind[key] = kind
        member_pcm[key] = _pcm_hash(audio)
        del audio

    # THE BOSS STEM PAIR IS ONE UNIT. `boss_<id>_low` and `_high` are the
    # same piece of music and the client crossfades between them for the
    # length of a fight; in two different bundles that is two streams and
    # two preloads to hear one theme.
    music_units, seen = [], set()
    for key in sorted(k for k in track_len if track_kind[k] == "music"):
        if key in seen:
            continue
        if key.endswith("_low") or key.endswith("_high"):
            base = key.rsplit("_", 1)[0]
            pair = [k for k in (base + "_low", base + "_high") if k in track_len]
            if len(pair) == 2:
                seen.update(pair)
                music_units.append((base, [(k, track_len[k]) for k in pair]))
                continue
        seen.add(key)
        music_units.append((key, [(key, track_len[key])]))
    amb_units = [(k, [(k, track_len[k])])
                 for k in sorted(k for k in track_len if track_kind[k] == "ambience")]

    sfx_bundles = plan_bundles("audio_sfx", sheet_units, SHEET_GAP_SECONDS)
    music_bundles = plan_bundles("audio_music", music_units, TRACK_GAP_SECONDS,
                                 decreasing=True)
    amb_bundles = plan_bundles("audio_ambience", amb_units, TRACK_GAP_SECONDS,
                               decreasing=True)

    # Absolute cue rows: the sheet's offset in its bundle plus the cue's
    # offset in the sheet.
    entries = []
    sheet_home = {}
    for b in sfx_bundles:
        for name, start, _dur in b.members:
            sheet_home[name] = (b.name, start)
    for sheet, ent in sheet_entries.items():
        file_name, base = sheet_home[sheet]
        for e in ent:
            row = dict(e)
            row["file"] = file_name
            row["sheet_start"] = e["start"]
            row["start"] = round(base + e["start"], 3)
            entries.append(row)

    tracks = {}
    for b in music_bundles + amb_bundles:
        for name, start, dur in b.members:
            tracks[name] = {
                "file": b.name,
                "start": start,
                "length": dur,
                # A stinger is a one-shot card, not a bed: it is the one kind
                # of track the client must NOT loop.
                "loop": not name.startswith("stinger_"),
                "kind": track_kind[name],
            }

    def track_audio(key):
        fn, kind, mod_name = music_tracks[key]
        return render_track(key, fn, kind, mod_hashes.get(mod_name, "nomod"),
                            use_cache=use_cache)

    return {
        "sheet_audio": sheet_audio,
        "sheet_entries": sheet_entries,
        "member_pcm": member_pcm,
        "entries": entries,
        "tracks": tracks,
        "sfx": sfx_bundles,
        "music": music_bundles,
        "ambience": amb_bundles,
        "bundles": sfx_bundles + music_bundles + amb_bundles,
        "track_audio": track_audio,
    }


def _sheet_rows(plan):
    """Where each logical sheet ended up. Reporting, and the per-sheet sample
    hash that a bundle's composed hash is built out of."""
    rows = {}
    for sheet in sorted(plan["sheet_entries"]):
        home, start = "", 0.0
        for b in plan["sfx"]:
            s = b.start_of(sheet)
            if s is not None:
                home, start = b.name, s
                break
        rows[sheet] = {"bundle": home, "start": start,
                       "cues": len(plan["sheet_entries"][sheet]),
                       "pcm_sha256": plan["member_pcm"].get(sheet, "")}
    return rows


def collect_music(music_mods):
    """{key: (render_fn, 'music'|'ambience', module_name)}."""
    tracks = {}
    for mod_name, mod in music_mods.items():
        for key, fn in getattr(mod, "TRACKS", {}).items():
            kind = "ambience" if key.startswith("amb_") else "music"
            tracks[key] = (fn, kind, mod_name)
    return tracks



def check_call_sites():
    """Cue names played by the client that nothing would ever sound."""
    import glob as _glob
    src = os.path.join(ROOT, "src")
    played = set()
    for path in _glob.glob(os.path.join(src, "**", "*.luau"), recursive=True):
        with open(path, errors="replace") as fh:
            text = fh.read()
        for name in re.findall(r'Sfx\.(?:play|loop)\(\s*"([A-Za-z0-9_]+)"', text):
            played.add(name)
        # Table-driven plays: any string literal on a line that names a cue
        # table (`DRAW_CUE = { rod = "rodDraw" }`, `STOW_CUE`, `CUES.x`).
        for line in text.splitlines():
            if re.search(r"\b[A-Z_]*CUES?\b", line):
                for name in re.findall(r'"([a-z][A-Za-z0-9_]+)"', line):
                    played.add(name)
    # The fallback catalogue: rows written literally as `\tname = {` with an
    # rbxasset id inside Sfx.luau's CATALOGUE (the PACK_CATALOGUE rows are
    # sprite-only by construction, so they do not count as sounding).
    sfx_path = os.path.join(src, "Client", "Modules", "Sfx.luau")
    with open(sfx_path, errors="replace") as fh:
        sfx = fh.read()
    # A row "sounds" without the pack when it carries any `id =` (a literal
    # rbxasset string or one of the LAND/CLICK/... aliases). Rows are either
    # one line or a `{ ... }` block closed by a line of exactly `\t},`.
    with_id = set()
    for m in re.finditer(r"^\t([A-Za-z0-9_]+) = \{([^\n]*)$", sfx, re.M):
        name, rest = m.group(1), m.group(2)
        if "}" in rest:
            body = rest
        else:
            end = sfx.find("\n\t}", m.end())
            body = sfx[m.end():end if end > 0 else m.end()]
        if re.search(r"\bid = (?!nil)", body):
            with_id.add(name)
    registered = set(cues.all_names()) if hasattr(cues, "all_names") else {c.name for c in cues.all()}
    implemented = {c.name for c in cues.all() if getattr(c, "render", None) is not None}
    out = []
    for name in sorted(played):
        base = name.split("__", 1)[0]
        if base in implemented or base in with_id:
            continue
        if base in registered:
            out.append("cue %s is played by the client but declared without a "
                       "render function - it is silent" % base)
        else:
            out.append("cue %s is played by the client but is neither a rendered "
                       "sprite nor an rbxasset catalogue row - it is silent" % base)
    return out

def main(argv=None):
    ap = argparse.ArgumentParser(description="Render the How to Fish SoundPack.")
    ap.add_argument("--only", nargs="*", default=None,
                    help="sheet names and/or music keys to render")
    ap.add_argument("--check", action="store_true",
                    help="render nothing; exit 1 if the manifest or the Luau "
                         "module is stale")
    ap.add_argument("--strict", action="store_true",
                    help="with --check, also fail when a declared cue has no "
                         "render function (turn this on in CI once the pack "
                         "is complete)")
    ap.add_argument("--preview", action="store_true",
                    help="also write preview renders and the showreel WAV")
    ap.add_argument("--list", action="store_true",
                    help="print the registry and exit")
    ap.add_argument("--no-cache", action="store_true", help="ignore the cue cache")
    args = ap.parse_args(argv)

    t_start = time.time()
    sfx_mods, music_mods = discover()
    mod_hashes = {name: _file_hash(os.path.join(HERE, name + ".py"))
                  for name in list(sfx_mods) + list(music_mods)}
    music_tracks = collect_music(music_mods)

    if args.list:
        for sheet in cues.sheets():
            have = [c for c in cues.by_sheet(sheet) if c.render is not None]
            print("%-16s %3d cues, %3d implemented" %
                  (sheet, len(cues.by_sheet(sheet)), len(have)))
        print("\nmusic/ambience keys: %s" % (", ".join(sorted(music_tracks)) or "none"))
        return 0

    if args.check:
        return check(mod_hashes, music_tracks, t_start, strict=args.strict)

    only = set(args.only) if args.only else None
    for d in (BUNDLE_DIR, CACHE_DIR):
        os.makedirs(d, exist_ok=True)
    if args.preview:
        os.makedirs(PREVIEW_DIR, exist_ok=True)

    _load_prev_manifest()
    plan = build_plan(mod_hashes, music_tracks, use_cache=not args.no_cache)

    legacy = remove_legacy_files()
    if legacy:
        print("  removed %d per-sheet/per-track OGG(s) - bundles replace them"
              % legacy)

    # Anything in assets/audio/bundles that this build does not claim is a
    # bundle a previous layout wrote (the pack got smaller, or a sheet
    # landed and pushed a split). Leaving it behind means the importer
    # uploads a file nothing looks up.
    planned = {b.name + ".ogg" for b in plan["bundles"]}
    for name in sorted(os.listdir(BUNDLE_DIR)):
        if name.endswith(".ogg") and name not in planned:
            os.remove(os.path.join(BUNDLE_DIR, name))
            print("  removed stale bundle %s" % name)

    bundle_rows = {}
    written = 0
    for b in plan["bundles"]:
        stereo = not b.name.startswith("audio_sfx")
        path = os.path.join(BUNDLE_DIR, b.name + ".ogg")
        pcm = bundle_pcm_hash(b, plan["member_pcm"])
        # --only names MEMBERS (a sheet or a track key); a bundle is rewritten
        # when it holds one of them. The bookkeeping below is done for every
        # bundle either way - a partial manifest would be worse than a slow
        # build.
        names = {m[0] for m in b.members} | {b.name}
        wanted = only is None or bool(only & names)
        unchanged = os.path.exists(path) and _prev_pcm_hash("bundles", b.name) == pcm
        t0 = time.time()
        if wanted and not unchanged:
            audio = concat_bundle(
                b,
                lambda name: (plan["sheet_audio"][name] if name in plan["sheet_audio"]
                              else plan["track_audio"](name)),
                stereo)
            S.write_ogg(path, audio, stereo=stereo)
            del audio
            written += 1
        if not os.path.exists(path):
            raise SystemExit("build: %s was never written (use --only with care)"
                             % os.path.relpath(path, ROOT))
        size = assert_bundle_limits(path, b.duration)
        bundle_rows[b.name] = {
            "file": b.name + ".ogg",
            "seconds": round(b.duration, 3),
            "bytes": size,
            "gap_seconds": b.gap,
            "sha256": _file_hash(path),
            "pcm_sha256": pcm,
            "members": [{"name": m, "start": s, "length": d}
                        for m, s, d in b.members],
        }
        print("  %-22s %5.1f min  %5.2f MB  %2d member(s)  %5.1fs%s"
              % (b.name + ".ogg", b.duration / 60.0, size / 1048576.0,
                 len(b.members), time.time() - t0,
                 "  (unchanged)" if unchanged else ""))

    entries = plan["entries"]
    manifest = {
        "version": 2,
        "sample_rate": S.SR,
        "gap_seconds": GAP_SECONDS,
        "sheet_gap_seconds": SHEET_GAP_SECONDS,
        "track_gap_seconds": TRACK_GAP_SECONDS,
        "bundle_seconds": BUNDLE_SECONDS,
        "cue_peak_db": CUE_PEAK_DB,
        "bundles": bundle_rows,
        "files": sorted(b.name for b in plan["bundles"]),
        # The logical sheets are REPORTING only now: a sheet is a member of a
        # bundle, not a file, and `cues` carries the absolute offsets.
        "sheets": _sheet_rows(plan),
        "tracks": {k: {"file": row["file"], "start": row["start"],
                       "length": row["length"], "loop": row["loop"],
                       "kind": row["kind"],
                       "pcm_sha256": plan["member_pcm"].get(k, "")}
                   for k, row in sorted(plan["tracks"].items())},
        "music": sorted(k for k, r in plan["tracks"].items() if r["kind"] == "music"),
        "ambience": sorted(k for k, r in plan["tracks"].items()
                           if r["kind"] == "ambience"),
        "cues": {e["name"]: {"file": e["file"], "sheet": e["sheet"],
                             "start": e["start"], "sheet_start": e["sheet_start"],
                             "length": e["length"], "loop": e["loop"],
                             "spatial": e["spatial"]}
                 for e in entries},
        "declared": len(cues.all()),
        "implemented": len(cues.implemented()),
        "missing": [c.name for c in cues.missing()],
    }
    with open(MANIFEST, "w") as fh:
        json.dump(manifest, fh, indent=1, sort_keys=True)
        fh.write("\n")

    luau = render_luau(entries, plan["tracks"],
                       [b.name for b in plan["bundles"]])
    os.makedirs(os.path.dirname(LUAU_OUT), exist_ok=True)
    with open(LUAU_OUT, "w") as fh:
        fh.write(luau)
    styled = run_stylua(LUAU_OUT)

    if args.preview:
        write_previews(mod_hashes)

    print("\nmanifest: %s (%d cues, %d tracks)"
          % (os.path.relpath(MANIFEST, ROOT), len(entries), len(plan["tracks"])))
    print("luau:     %s%s" % (os.path.relpath(LUAU_OUT, ROOT),
                              " (stylua)" if styled else ""))
    miss = cues.missing()
    if miss:
        print("declared but not implemented: %d of %d cues" % (len(miss), len(cues.all())))
    print("pack: %d files to import from %s (%d rewritten), %.1f min total, %.1fs"
          % (len(plan["bundles"]), os.path.relpath(BUNDLE_DIR, ROOT), written,
             sum(b.duration for b in plan["bundles"]) / 60.0,
             time.time() - t_start))
    return 0


def write_previews(mod_hashes):
    """One sample cue per sheet, in stereo, plus the 10 s fishing showreel."""
    os.makedirs(PREVIEW_DIR, exist_ok=True)
    for sheet in cues.sheets():
        ready = [c for c in cues.by_sheet(sheet) if c.render is not None]
        if not ready:
            continue
        pick = cues.get(PREVIEW_PICK.get(sheet, "")) or ready[0]
        if pick.render is None or pick.sheet != sheet:
            pick = ready[0]
        audio = render_cue(pick, mod_hashes)
        S.write_ogg(os.path.join(PREVIEW_DIR, "%s__%s.ogg" % (sheet, pick.name)),
                    S.stereo_width(audio.astype(np.float64), width=0.4), stereo=True)

    # The showreel is a WAV so it can be listened to with no decoder at all.
    reel = np.zeros(0)
    for name in SHOWREEL:
        c = cues.get(name)
        if c is None or c.render is None:
            continue
        audio = render_cue(c, mod_hashes).astype(np.float64)
        if c.loop:
            audio = np.concatenate([audio, audio])[: S.n(1.4)]
            audio = S.fade(audio, 0.01, 0.05)
        reel = np.concatenate([reel, audio, S.silence(0.35)])
    reel = S.normalize(reel, -1.5)
    S.write_wav(os.path.join(PREVIEW_DIR, "showreel_fishing.wav"),
                S.stereo_width(reel, width=0.35), stereo=True)
    print("previews: %s (%.1fs showreel)" %
          (os.path.relpath(PREVIEW_DIR, ROOT), len(reel) / S.SR))


def check(mod_hashes, music_tracks, t_start, strict=False):
    """Report only. Exits 1 on disagreement. Writes nothing, ever."""
    problems = []
    notes = []

    miss = cues.missing()
    if miss:
        by_sheet = {}
        for c in miss:
            by_sheet.setdefault(c.sheet, []).append(c.name)
        bucket = problems if strict else notes
        bucket.append("%d of %d declared cues have no render function%s:"
                      % (len(miss), len(cues.all()),
                         "" if strict else " (not fatal - see --strict)"))
        for sheet in cues.SHEETS:
            names = by_sheet.get(sheet)
            if names:
                shown = ", ".join(names[:6])
                more = "" if len(names) <= 6 else " ... (+%d)" % (len(names) - 6)
                bucket.append("  %-16s %3d  %s%s" % (sheet, len(names), shown, more))

    if not os.path.exists(MANIFEST):
        problems.append("manifest.json is missing - run the generator")
        manifest = None
    else:
        with open(MANIFEST) as fh:
            manifest = json.load(fh)

    plan = build_plan(mod_hashes, music_tracks)
    entries = plan["entries"]

    if manifest is not None:
        have = set(manifest.get("cues", {}))
        want = {e["name"] for e in entries}
        for name in sorted(want - have):
            problems.append("manifest is missing cue %s" % name)
        for name in sorted(have - want):
            problems.append("manifest has stale cue %s" % name)
        for e in entries:
            row = manifest.get("cues", {}).get(e["name"])
            if row and (abs(row.get("start", -1) - e["start"]) > 0.0005 or
                        abs(row.get("length", -1) - e["length"]) > 0.0005 or
                        row.get("loop") != e["loop"] or
                        row.get("file") != e["file"]):
                problems.append("manifest is stale for %s (file/start/length/loop "
                                "moved)" % e["name"])
        for key, row in sorted(plan["tracks"].items()):
            was = manifest.get("tracks", {}).get(key)
            if not was:
                problems.append("manifest is missing track %s" % key)
                continue
            if (was.get("file") != row["file"] or
                    abs(was.get("start", -1) - row["start"]) > 0.0005 or
                    abs(was.get("length", -1) - row["length"]) > 0.0005 or
                    was.get("loop") != row["loop"]):
                problems.append("manifest is stale for track %s (file/start/length "
                                "moved)" % key)
            fresh = plan["member_pcm"].get(key)
            if fresh and was.get("pcm_sha256") and fresh != was["pcm_sha256"]:
                problems.append("track audio has changed since the manifest: %s "
                                "- re-run without --check" % key)
        for key in sorted(set(manifest.get("tracks", {})) - set(plan["tracks"])):
            problems.append("manifest has stale track %s" % key)

        # THE CALL SITES. Every literal cue name the client PLAYS has to be
        # either a rendered sprite or a catalogue row with an rbxasset id -
        # a row with neither is designed silence in Sfx.play (no warn), so
        # nothing else in the gate would ever notice a cue that code asks for
        # and no renderer provides (the way rodDraw was wired before it was
        # rendered). Voice variants (`name__voice`) resolve to their base.
        problems.extend(check_call_sites())

        # THE BUNDLES. Per bundle: the file has to be there, its composed
        # hash has to match (a member's audio moved, or the layout did), its
        # bytes have to be the bytes the generator wrote, and it still has to
        # be inside Roblox's two limits.
        rows = manifest.get("bundles", {})
        want_bundles = {b.name: b for b in plan["bundles"]}
        for name in sorted(set(rows) - set(want_bundles)):
            problems.append("manifest has stale bundle %s - re-run without --check"
                            % name)
        for name, b in sorted(want_bundles.items()):
            row = rows.get(name)
            path = os.path.join(BUNDLE_DIR, name + ".ogg")
            if not row:
                problems.append("manifest is missing bundle %s" % name)
                continue
            if not os.path.exists(path):
                problems.append("bundle file missing: %s" % os.path.relpath(path, ROOT))
                continue
            fresh = bundle_pcm_hash(b, plan["member_pcm"])
            if row.get("pcm_sha256") and fresh != row["pcm_sha256"]:
                problems.append("bundle audio or layout has changed since the "
                                "manifest: %s.ogg - re-run without --check" % name)
            if row.get("sha256") and _file_hash(path) != row["sha256"]:
                problems.append("bundle file on disk was modified outside the "
                                "generator: %s" % os.path.relpath(path, ROOT))
            if b.duration >= BUNDLE_HARD_SECONDS:
                problems.append("bundle %s.ogg is %.1fs - over Roblox's %.0fs limit"
                                % (name, b.duration, BUNDLE_HARD_SECONDS))
            if os.path.getsize(path) >= BUNDLE_HARD_BYTES:
                problems.append("bundle %s.ogg is %.1f MB - over Roblox's %.0f MB "
                                "limit" % (name, os.path.getsize(path) / 1048576.0,
                                           BUNDLE_HARD_BYTES / 1048576.0))

    music_keys = sorted(k for k, r in plan["tracks"].items() if r["kind"] == "music")
    amb_keys = sorted(k for k, r in plan["tracks"].items() if r["kind"] == "ambience")

    expected = render_luau(entries, plan["tracks"],
                           [b.name for b in plan["bundles"]])
    if not os.path.exists(LUAU_OUT):
        problems.append("%s is missing" % os.path.relpath(LUAU_OUT, ROOT))
    else:
        with open(LUAU_OUT) as fh:
            current = fh.read()
        if current != expected:
            # stylua may have reformatted it; compare again after styling a
            # temporary copy, so a formatted file is not reported as stale.
            if not _matches_after_stylua(current, expected):
                problems.append("%s is STALE - re-run without --check"
                                % os.path.relpath(LUAU_OUT, ROOT))

    print("SoundSprites: %d cues on %d sheets, %d music, %d ambience"
          % (len(entries), len({e["sheet"] for e in entries}),
             len(music_keys), len(amb_keys)))
    print("pack: %d bundles to import, %.1f min total" %
          (len(plan["bundles"]), sum(b.duration for b in plan["bundles"]) / 60.0))
    for b in plan["bundles"]:
        path = os.path.join(BUNDLE_DIR, b.name + ".ogg")
        size = os.path.getsize(path) / 1048576.0 if os.path.exists(path) else 0.0
        print("  %-22s %5.2f min  %5.2f MB  %s"
              % (b.name + ".ogg", b.duration / 60.0, size,
                 ", ".join(m[0] for m in b.members)))
    if notes:
        print("\nNOT YET IMPLEMENTED:")
        for line in notes:
            print("  " + line if not line.startswith("  ") else line)
    if problems:
        print("\nPROBLEMS (%d):" % len(problems))
        for p in problems:
            print("  " + p if not p.startswith("  ") else p)
        print("\n--check FAILED in %.1fs" % (time.time() - t_start))
        return 1
    print("--check OK in %.1fs" % (time.time() - t_start))
    return 0


def _matches_after_stylua(current, expected):
    """True if `expected` formatted by stylua equals what is on disk."""
    if shutil.which("stylua") is None:
        return False
    tmp = os.path.join(CACHE_DIR, "_check_soundsprites.luau")
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(tmp, "w") as fh:
        fh.write(expected)
    run_stylua(tmp)
    with open(tmp) as fh:
        styled = fh.read()
    os.remove(tmp)
    return styled == current


if __name__ == "__main__":
    sys.exit(main())
