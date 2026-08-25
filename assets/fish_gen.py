# fish_gen.py
# Generates every fish species as low-poly meshes and exports them together
# as ONE glTF (.glb) for Roblox's Import. Same pipeline as island_gen.py /
# rod_gen.py:
#
#   blender --background --python assets/fish_gen.py -- assets/fish.glb
#
# Every species is a parameter set in SPECIES below - body profile, tail
# style, fin set, markings, barbels, jaw - all built by the same code, so a
# new species is a dict entry (and a row in Shared/Data/Creatures.luau), not
# new modelling. They're all based on real fish and kept recognisable by
# silhouette: a bass is deep with a spiny dorsal and a stripe, a tuna is a
# torpedo with a crescent tail and finlets, a cod has three dorsals and a
# chin barbel, and so on.
#
# One file on purpose: Studio's Import is a manual step, so all species go
# in at once as a single model (named FishPack in ReplicatedStorage/Assets),
# and CreatureModel.luau picks a species out of it by part-name prefix. In
# the file the species sit side by side along X for previewing; runtime
# positions each relative to its own body, so the spacing is irrelevant.
#
# Authoring contract (CreatureModel / CreatureService rely on these):
#   - 1 Blender unit = 1 Roblox stud. Exported Y-up. Nose along Blender +Y.
#   - Every species is BODY_LENGTH long nose to tail (fins may poke past),
#     body centred on its own origin before the preview offset. Rows scale
#     the whole thing uniformly, so a tuna is "the tuna shape at 2.2x".
#   - Length > height > width for every species: CreatureService lays a fish
#     flat by reading its bounding box's longest and shortest axes.
#   - Objects per species, named exactly <Species>_Body, <Species>_Fins,
#     <Species>_Eyes and optionally <Species>_Marks (stripes / bars /
#     finlets, recoloured separately). The prefix is the row's `species`,
#     the suffixes are the recolour contract.
#   - Flat shading everywhere, matching the island and rod.

import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

# ---------------------------------------------------------------- shared parameters

BODY_LENGTH = 2.0  # nose to tail, studs, before per-row scaling
BODY_RINGS = 7  # cross-sections along the body; fewer = more angular
FIN_THICKNESS = 0.03  # fins are thin prisms, not single faces, so they render from both sides
MARK_THICKNESS = 0.02
PREVIEW_SPACING = 3.2  # studs between species in the file, nose to tail along Y

EYE_COLOR = (0.05, 0.05, 0.06)

# ---------------------------------------------------------------- species
#
# Keys:
#   profile      (t, half-height) tail (0) -> nose (1). Few points on purpose:
#                the silhouette is a handful of straight runs.
#   width        half-width as a fraction of half-height (laterally compressed
#                fish are ~0.5, a round tuna ~0.85). `width_profile` overrides
#                it with explicit (t, half-width) points (catfish: flat head).
#   sides        facets around the body.
#   tail         "forked" | "rounded" | "square" | "lunate", plus reach/spread.
#   dorsals      list of fins on the back: t0, t1, height, kind
#                ("soft" | "spiny" | "sickle" | "adipose").
#   anals        same underneath.
#   pectoral     pectoral fin length.
#   finlets      (t0, t1, count) tiny triangles on back and belly, in Marks.
#   barbel       "chin" (cod) | "whiskers" (catfish) | None.
#   jaw          "kype" (salmon's hooked lower jaw) | None.
#   marks        "stripe" (lateral band), "bars" (vertical bars), or None,
#                with its own parameters.
#   eye          (t, radius).
#   colors       preview only - the game recolours from the creature row.

SPECIES = {
    "Perch": dict(
        profile=[(0.00, 0.05), (0.18, 0.17), (0.50, 0.34), (0.84, 0.19), (1.00, 0.03)],
        width=0.50,
        sides=6,
        tail=dict(kind="rounded", reach=0.34, spread=0.28),
        dorsals=[dict(t0=0.40, t1=0.66, height=0.30, kind="spiny", spines=6), dict(t0=0.20, t1=0.38, height=0.18, kind="soft")],
        anals=[dict(t0=0.24, t1=0.40, height=0.14, kind="soft")],
        pectoral=0.28,
        marks=dict(kind="bars", count=6, t0=0.22, t1=0.82, width=0.045, height=0.75),
        eye=(0.87, 0.05),
        colors=dict(body=(0.62, 0.66, 0.30), fins=(0.92, 0.48, 0.14), marks=(0.22, 0.26, 0.12)),
    ),
    "Mackerel": dict(
        profile=[(0.00, 0.04), (0.20, 0.11), (0.52, 0.19), (0.86, 0.12), (1.00, 0.02)],
        width=0.62,
        sides=6,
        tail=dict(kind="forked", reach=0.40, spread=0.30, notch=0.14),
        dorsals=[dict(t0=0.52, t1=0.70, height=0.14, kind="spiny", spines=5), dict(t0=0.30, t1=0.42, height=0.10, kind="soft")],
        anals=[dict(t0=0.30, t1=0.42, height=0.10, kind="soft")],
        pectoral=0.24,
        finlets=(0.12, 0.28, 5),
        marks=dict(kind="bars", count=7, t0=0.26, t1=0.78, width=0.03, height=0.45, top=True),
        eye=(0.88, 0.045),
        colors=dict(body=(0.36, 0.56, 0.66), fins=(0.30, 0.42, 0.50), marks=(0.10, 0.18, 0.26)),
    ),
    "Trout": dict(
        profile=[(0.00, 0.05), (0.20, 0.14), (0.52, 0.24), (0.86, 0.15), (1.00, 0.03)],
        width=0.55,
        sides=6,
        tail=dict(kind="square", reach=0.34, spread=0.30),
        dorsals=[dict(t0=0.42, t1=0.60, height=0.18, kind="soft"), dict(t0=0.20, t1=0.28, height=0.07, kind="adipose")],
        anals=[dict(t0=0.26, t1=0.40, height=0.12, kind="soft")],
        pectoral=0.28,
        marks=dict(kind="stripe", t0=0.10, t1=0.92, height=0.30),
        eye=(0.87, 0.05),
        colors=dict(body=(0.48, 0.62, 0.44), fins=(0.40, 0.50, 0.38), marks=(0.88, 0.42, 0.52)),
    ),
    "Bass": dict(
        profile=[(0.00, 0.06), (0.18, 0.18), (0.48, 0.36), (0.74, 0.30), (0.92, 0.16), (1.00, 0.04)],
        width=0.52,
        sides=6,
        tail=dict(kind="rounded", reach=0.36, spread=0.32),
        dorsals=[dict(t0=0.44, t1=0.70, height=0.26, kind="spiny", spines=7), dict(t0=0.22, t1=0.42, height=0.20, kind="soft")],
        anals=[dict(t0=0.24, t1=0.40, height=0.16, kind="soft")],
        pectoral=0.30,
        marks=dict(kind="stripe", t0=0.08, t1=0.90, height=0.22),
        eye=(0.86, 0.055),
        colors=dict(body=(0.42, 0.55, 0.28), fins=(0.34, 0.44, 0.24), marks=(0.12, 0.18, 0.10)),
    ),
    "Cod": dict(
        profile=[(0.00, 0.05), (0.22, 0.14), (0.55, 0.26), (0.84, 0.22), (1.00, 0.04)],
        width=0.60,
        sides=6,
        tail=dict(kind="square", reach=0.32, spread=0.28),
        dorsals=[
            dict(t0=0.66, t1=0.80, height=0.20, kind="soft"),
            dict(t0=0.44, t1=0.62, height=0.16, kind="soft"),
            dict(t0=0.22, t1=0.40, height=0.13, kind="soft"),
        ],
        anals=[dict(t0=0.42, t1=0.56, height=0.12, kind="soft"), dict(t0=0.22, t1=0.38, height=0.11, kind="soft")],
        pectoral=0.26,
        barbel="chin",
        marks=dict(kind="stripe", t0=0.10, t1=0.90, height=0.06, lift=0.25),
        eye=(0.87, 0.05),
        colors=dict(body=(0.58, 0.52, 0.36), fins=(0.46, 0.42, 0.30), marks=(0.82, 0.78, 0.66)),
    ),
    "Catfish": dict(
        profile=[(0.00, 0.05), (0.22, 0.15), (0.55, 0.24), (0.82, 0.20), (1.00, 0.07)],
        width_profile=[(0.00, 0.03), (0.22, 0.09), (0.55, 0.15), (0.80, 0.19), (1.00, 0.09)],
        sides=6,
        tail=dict(kind="rounded", reach=0.34, spread=0.28),
        dorsals=[dict(t0=0.58, t1=0.70, height=0.22, kind="spiny", spines=3), dict(t0=0.24, t1=0.32, height=0.06, kind="adipose")],
        anals=[dict(t0=0.18, t1=0.52, height=0.12, kind="soft")],
        pectoral=0.30,
        barbel="whiskers",
        marks=None,
        eye=(0.88, 0.035),
        colors=dict(body=(0.40, 0.40, 0.34), fins=(0.30, 0.30, 0.26)),
    ),
    "Salmon": dict(
        profile=[(0.00, 0.05), (0.20, 0.15), (0.50, 0.28), (0.78, 0.24), (0.94, 0.12), (1.00, 0.03)],
        width=0.55,
        sides=6,
        tail=dict(kind="forked", reach=0.40, spread=0.34, notch=0.10),
        dorsals=[dict(t0=0.46, t1=0.62, height=0.20, kind="soft"), dict(t0=0.20, t1=0.28, height=0.08, kind="adipose")],
        anals=[dict(t0=0.24, t1=0.40, height=0.14, kind="soft")],
        pectoral=0.30,
        jaw="kype",
        marks=dict(kind="stripe", t0=0.12, t1=0.88, height=0.26),
        eye=(0.88, 0.05),
        colors=dict(body=(0.72, 0.74, 0.72), fins=(0.50, 0.50, 0.48), marks=(0.86, 0.38, 0.36)),
    ),
    "Tuna": dict(
        profile=[(0.00, 0.03), (0.16, 0.10), (0.50, 0.30), (0.80, 0.24), (1.00, 0.03)],
        width=0.85,
        sides=8,
        tail=dict(kind="lunate", reach=0.46, spread=0.44),
        dorsals=[dict(t0=0.52, t1=0.68, height=0.30, kind="sickle"), dict(t0=0.34, t1=0.46, height=0.16, kind="sickle")],
        anals=[dict(t0=0.34, t1=0.46, height=0.16, kind="sickle")],
        pectoral=0.42,
        finlets=(0.10, 0.32, 7),
        marks=None,
        eye=(0.88, 0.05),
        colors=dict(body=(0.20, 0.28, 0.46), fins=(0.30, 0.34, 0.44), marks=(0.92, 0.78, 0.20)),
    ),
    # The pufferfish is not a profile-and-fins fish - it's a fat faceted ball
    # ringed with short cone spikes, big eyes and a little beak. It has its
    # own builder (build_puffer, `custom="puffer"`) instead of the shared
    # body/fin/mark code, but exports the same Puffer_Body/_Fins/_Eyes/_Marks
    # objects so CreatureModel treats it like any other pack species.
    "Puffer": dict(
        custom="puffer",
        colors=dict(body=(0.85, 0.78, 0.50), fins=(0.59, 0.47, 0.27), marks=(0.18, 0.15, 0.11)),
    ),
    # ---- Volcano fish (2026-08-23) ----
    # The lava island's catch. Same profile-and-fins builder, but each is shaped
    # to read as its own lava creature, not a recolour: exaggerated spiny crests,
    # faceted obsidian bodies, molten finlets. Colours here are preview-only (the
    # game recolours from the Creatures.luau `waters="volcano"` rows); set to the
    # row palette so the preview reads right. See docs/volcano-content-spec.md.
    # Common - a deep perch with an exaggerated spiny ember crest.
    "Emberfin": dict(
        profile=[(0.00, 0.05), (0.16, 0.20), (0.48, 0.38), (0.84, 0.18), (1.00, 0.03)],
        width=0.48,
        sides=6,
        tail=dict(kind="rounded", reach=0.36, spread=0.32),
        dorsals=[dict(t0=0.34, t1=0.72, height=0.54, kind="spiny", spines=10), dict(t0=0.18, t1=0.32, height=0.20, kind="soft")],
        anals=[dict(t0=0.22, t1=0.44, height=0.22, kind="spiny", spines=5)],
        pectoral=0.26,
        marks=dict(kind="bars", count=6, t0=0.20, t1=0.82, width=0.055, height=0.88),
        eye=(0.87, 0.05),
        colors=dict(body=(0.26, 0.15, 0.15), fins=(0.85, 0.32, 0.10), marks=(1.00, 0.62, 0.14)),
    ),
    # Common - a small, lean, ashy minnow; deeply forked tail, faint top bars.
    "Ashgill": dict(
        profile=[(0.00, 0.04), (0.22, 0.10), (0.54, 0.16), (0.86, 0.10), (1.00, 0.02)],
        width=0.55,
        sides=6,
        tail=dict(kind="forked", reach=0.48, spread=0.32, notch=0.18),
        dorsals=[dict(t0=0.44, t1=0.66, height=0.17, kind="spiny", spines=5)],
        anals=[dict(t0=0.30, t1=0.44, height=0.11, kind="soft")],
        pectoral=0.22,
        finlets=(0.12, 0.30, 6),
        marks=dict(kind="bars", count=9, t0=0.22, t1=0.82, width=0.03, height=0.58, top=True),
        eye=(0.88, 0.045),
        colors=dict(body=(0.20, 0.19, 0.21), fins=(0.44, 0.21, 0.12), marks=(1.00, 0.52, 0.12)),
    ),
    # Common - a stubby guppy with big flowing fins, molten-bright.
    "MagmaGuppy": dict(
        profile=[(0.00, 0.06), (0.22, 0.18), (0.52, 0.26), (0.82, 0.16), (1.00, 0.04)],
        width=0.52,
        sides=6,
        tail=dict(kind="rounded", reach=0.52, spread=0.52),
        dorsals=[dict(t0=0.32, t1=0.68, height=0.42, kind="soft")],
        anals=[dict(t0=0.24, t1=0.52, height=0.28, kind="soft")],
        pectoral=0.36,
        marks=dict(kind="stripe", t0=0.08, t1=0.92, height=0.36),
        eye=(0.86, 0.055),
        # The one deliberately BRIGHT fish in the set: everything else is black
        # rock with molten cracks, so the family needs one that is simply molten.
        colors=dict(body=(0.97, 0.42, 0.10), fins=(0.72, 0.20, 0.08), marks=(1.00, 0.80, 0.30)),
    ),
    # Uncommon - a bass gone angular/faceted (obsidian), sharp spiny crest, crack-marks.
    "ObsidianBass": dict(
        profile=[(0.00, 0.06), (0.16, 0.20), (0.46, 0.38), (0.74, 0.30), (0.92, 0.15), (1.00, 0.04)],
        width=0.46,
        sides=5,  # fewer sides = a harder, faceted obsidian read
        tail=dict(kind="square", reach=0.36, spread=0.32),
        dorsals=[dict(t0=0.40, t1=0.76, height=0.44, kind="spiny", spines=11), dict(t0=0.18, t1=0.40, height=0.22, kind="soft")],
        anals=[dict(t0=0.20, t1=0.42, height=0.20, kind="spiny", spines=5)],
        pectoral=0.28,
        # Bars rather than a stripe: on a black glass body they read as the
        # cracks the lava shows through, which is the whole idea of the fish.
        marks=dict(kind="bars", count=5, t0=0.18, t1=0.84, width=0.045, height=0.92),
        eye=(0.86, 0.05),
        colors=dict(body=(0.13, 0.12, 0.16), fins=(0.21, 0.19, 0.25), marks=(1.00, 0.40, 0.10)),
    ),
    # Uncommon - a chunky basalt cod: three soft dorsals, chin barbel, warm belly stripe.
    "BasaltCod": dict(
        profile=[(0.00, 0.05), (0.22, 0.15), (0.55, 0.28), (0.84, 0.23), (1.00, 0.04)],
        width=0.62,
        sides=6,
        tail=dict(kind="square", reach=0.32, spread=0.28),
        dorsals=[
            dict(t0=0.64, t1=0.82, height=0.28, kind="spiny", spines=6),
            dict(t0=0.42, t1=0.62, height=0.18, kind="soft"),
            dict(t0=0.20, t1=0.40, height=0.14, kind="soft"),
        ],
        anals=[dict(t0=0.42, t1=0.56, height=0.13, kind="soft"), dict(t0=0.22, t1=0.38, height=0.11, kind="soft")],
        pectoral=0.26,
        barbel="chin",
        marks=dict(kind="bars", count=7, t0=0.20, t1=0.84, width=0.035, height=0.62, top=True),
        eye=(0.87, 0.05),
        colors=dict(body=(0.22, 0.21, 0.24), fins=(0.16, 0.15, 0.19), marks=(0.98, 0.48, 0.14)),
    ),
    # Rare - a fiery salmon torpedo: forked tail, kype jaw, blazing lateral stripe.
    "PyreSalmon": dict(
        profile=[(0.00, 0.05), (0.20, 0.15), (0.50, 0.28), (0.78, 0.24), (0.94, 0.12), (1.00, 0.03)],
        width=0.55,
        sides=6,
        tail=dict(kind="forked", reach=0.48, spread=0.36, notch=0.14),
        dorsals=[dict(t0=0.44, t1=0.64, height=0.28, kind="soft"), dict(t0=0.20, t1=0.28, height=0.08, kind="adipose")],
        anals=[dict(t0=0.24, t1=0.40, height=0.17, kind="soft")],
        pectoral=0.30,
        jaw="kype",
        marks=dict(kind="stripe", t0=0.08, t1=0.92, height=0.38),
        eye=(0.88, 0.05),
        colors=dict(body=(0.30, 0.14, 0.12), fins=(0.88, 0.34, 0.12), marks=(1.00, 0.70, 0.22)),
    ),
    # ---- Frostmaw Reach fish (island 3) ----
    # Cold silvers and glacier blues; the marlin is the Legendary chase.
    # Common - a slender melt-water smelt, faint silver line.
    "IcemeltSmelt": dict(
        profile=[(0.00, 0.04), (0.24, 0.09), (0.55, 0.14), (0.86, 0.09), (1.00, 0.02)],
        width=0.52,
        sides=6,
        tail=dict(kind="forked", reach=0.38, spread=0.26, notch=0.14),
        dorsals=[dict(t0=0.44, t1=0.60, height=0.13, kind="soft"), dict(t0=0.22, t1=0.28, height=0.06, kind="adipose")],
        anals=[dict(t0=0.26, t1=0.40, height=0.09, kind="soft")],
        pectoral=0.22,
        marks=dict(kind="stripe", t0=0.12, t1=0.90, height=0.20),
        eye=(0.88, 0.045),
        colors=dict(body=(0.72, 0.76, 0.80), fins=(0.55, 0.60, 0.68), marks=(0.90, 0.93, 0.96)),
    ),
    # Common - an arctic char: square tail, adipose, the pink char stripe.
    "FrostfinChar": dict(
        profile=[(0.00, 0.05), (0.20, 0.14), (0.52, 0.25), (0.86, 0.15), (1.00, 0.03)],
        width=0.55,
        sides=6,
        tail=dict(kind="square", reach=0.34, spread=0.30),
        dorsals=[dict(t0=0.44, t1=0.62, height=0.19, kind="soft"), dict(t0=0.20, t1=0.28, height=0.07, kind="adipose")],
        anals=[dict(t0=0.26, t1=0.40, height=0.13, kind="soft")],
        pectoral=0.28,
        marks=dict(kind="stripe", t0=0.10, t1=0.90, height=0.28),
        eye=(0.87, 0.05),
        colors=dict(body=(0.50, 0.60, 0.68), fins=(0.75, 0.85, 0.90), marks=(0.90, 0.55, 0.45)),
    ),
    # Common - a squat sculpin: flat wide head, fan pectorals, dark saddles.
    "SnowdriftSculpin": dict(
        profile=[(0.00, 0.04), (0.24, 0.13), (0.58, 0.20), (0.84, 0.19), (1.00, 0.06)],
        width_profile=[(0.00, 0.02), (0.24, 0.08), (0.58, 0.13), (0.82, 0.17), (1.00, 0.08)],
        sides=6,
        tail=dict(kind="rounded", reach=0.30, spread=0.24),
        dorsals=[dict(t0=0.48, t1=0.72, height=0.22, kind="spiny", spines=6), dict(t0=0.20, t1=0.44, height=0.15, kind="soft")],
        anals=[dict(t0=0.22, t1=0.44, height=0.11, kind="soft")],
        pectoral=0.40,
        marks=dict(kind="bars", count=4, t0=0.24, t1=0.78, width=0.06, height=0.85),
        eye=(0.86, 0.045),
        colors=dict(body=(0.62, 0.65, 0.70), fins=(0.50, 0.55, 0.62), marks=(0.35, 0.40, 0.48)),
    ),
    # Uncommon - a bright herring, deeply forked, mirror-striped.
    "RimeHerring": dict(
        profile=[(0.00, 0.04), (0.20, 0.12), (0.52, 0.20), (0.86, 0.12), (1.00, 0.02)],
        width=0.48,
        sides=6,
        tail=dict(kind="forked", reach=0.46, spread=0.32, notch=0.18),
        dorsals=[dict(t0=0.42, t1=0.58, height=0.16, kind="soft")],
        anals=[dict(t0=0.22, t1=0.40, height=0.11, kind="soft")],
        pectoral=0.24,
        marks=dict(kind="stripe", t0=0.10, t1=0.92, height=0.16),
        eye=(0.88, 0.05),
        colors=dict(body=(0.70, 0.75, 0.82), fins=(0.55, 0.62, 0.72), marks=(0.95, 0.97, 1.00)),
    ),
    # LEGENDARY chase - the Aurorafin Marlin (rows scale it 1.9): a bill, a
    # tall aurora sickle dorsal, a deep lunate tail.
    "AurorafinMarlin": dict(
        profile=[(0.00, 0.03), (0.16, 0.10), (0.48, 0.28), (0.80, 0.20), (1.00, 0.04)],
        width=0.62,
        sides=7,
        tail=dict(kind="lunate", reach=0.52, spread=0.48),
        dorsals=[dict(t0=0.42, t1=0.74, height=0.46, kind="sickle"), dict(t0=0.22, t1=0.34, height=0.14, kind="sickle")],
        anals=[dict(t0=0.28, t1=0.42, height=0.16, kind="sickle")],
        pectoral=0.40,
        jaw="bill",
        marks=dict(kind="stripe", t0=0.12, t1=0.88, height=0.22),
        eye=(0.86, 0.05),
        colors=dict(body=(0.25, 0.35, 0.50), fins=(0.45, 0.80, 0.85), marks=(0.50, 0.95, 0.85)),
    ),
    # ---- Gloomtrench fish (island 5) ----
    # Pale things that never saw the sun; the oarfish is the Legendary.
    # Common - a washed-out dace.
    "PaleDace": dict(
        profile=[(0.00, 0.04), (0.22, 0.11), (0.54, 0.17), (0.86, 0.11), (1.00, 0.02)],
        width=0.52,
        sides=6,
        tail=dict(kind="rounded", reach=0.34, spread=0.26),
        dorsals=[dict(t0=0.42, t1=0.60, height=0.15, kind="soft")],
        anals=[dict(t0=0.26, t1=0.42, height=0.10, kind="soft")],
        pectoral=0.24,
        marks=dict(kind="stripe", t0=0.12, t1=0.88, height=0.18),
        eye=(0.87, 0.05),
        colors=dict(body=(0.75, 0.75, 0.72), fins=(0.60, 0.60, 0.58), marks=(0.86, 0.86, 0.81)),
    ),
    # Common - a blindcave sardine: pin-prick eyes, translucent pink-white.
    "BlindcaveSardine": dict(
        profile=[(0.00, 0.04), (0.22, 0.10), (0.54, 0.16), (0.86, 0.10), (1.00, 0.02)],
        width=0.5,
        sides=6,
        tail=dict(kind="forked", reach=0.40, spread=0.28, notch=0.14),
        dorsals=[dict(t0=0.44, t1=0.58, height=0.13, kind="soft")],
        anals=[dict(t0=0.26, t1=0.40, height=0.09, kind="soft")],
        pectoral=0.22,
        marks=dict(kind="stripe", t0=0.14, t1=0.86, height=0.14),
        eye=(0.88, 0.02),
        colors=dict(body=(0.80, 0.72, 0.70), fins=(0.68, 0.60, 0.60), marks=(0.90, 0.83, 0.81)),
    ),
    # Common - a soot-gilled hagfish: an eel of a thing, whiskered, its gill
    # row barred black.
    "SootgillHagfish": dict(
        profile=[(0.00, 0.05), (0.25, 0.09), (0.60, 0.11), (0.88, 0.10), (1.00, 0.04)],
        width_profile=[(0.00, 0.03), (0.30, 0.06), (0.65, 0.08), (1.00, 0.05)],
        sides=6,
        tail=dict(kind="rounded", reach=0.26, spread=0.16),
        dorsals=[dict(t0=0.08, t1=0.55, height=0.08, kind="soft")],
        anals=[dict(t0=0.10, t1=0.42, height=0.06, kind="soft")],
        pectoral=0.10,
        barbel="whiskers",
        marks=dict(kind="bars", count=4, t0=0.70, t1=0.88, width=0.025, height=0.55),
        eye=(0.90, 0.025),
        colors=dict(body=(0.30, 0.28, 0.30), fins=(0.22, 0.20, 0.22), marks=(0.12, 0.11, 0.12)),
    ),
    # LEGENDARY chase - the Ghostlight Oarfish (rows scale it 2.2): a silver
    # ribbon under a full-length spectral dorsal with a crest at the head.
    "GhostlightOarfish": dict(
        profile=[(0.00, 0.04), (0.15, 0.11), (0.45, 0.13), (0.75, 0.12), (0.94, 0.09), (1.00, 0.03)],
        width=0.30,
        sides=6,
        tail=dict(kind="rounded", reach=0.22, spread=0.14),
        dorsals=[dict(t0=0.10, t1=0.78, height=0.22, kind="soft"), dict(t0=0.80, t1=0.94, height=0.48, kind="spiny", spines=3)],
        anals=[],
        pectoral=0.16,
        marks=dict(kind="stripe", t0=0.08, t1=0.92, height=0.14),
        eye=(0.88, 0.05),
        colors=dict(body=(0.80, 0.85, 0.90), fins=(0.55, 0.90, 0.80), marks=(0.60, 0.95, 0.85)),
    ),
    # ---- Wreckwater fish (island 6) ----
    # Rust, barnacle and grave-light; the sailfish is the Legendary.
    # Common - a dull wreck herring, finlets like rivet stubs.
    "WreckHerring": dict(
        profile=[(0.00, 0.04), (0.20, 0.12), (0.52, 0.19), (0.86, 0.12), (1.00, 0.02)],
        width=0.5,
        sides=6,
        tail=dict(kind="forked", reach=0.42, spread=0.30, notch=0.16),
        dorsals=[dict(t0=0.44, t1=0.60, height=0.15, kind="soft")],
        anals=[dict(t0=0.24, t1=0.40, height=0.10, kind="soft")],
        pectoral=0.24,
        finlets=(0.12, 0.26, 4),
        marks=dict(kind="bars", count=6, t0=0.24, t1=0.80, width=0.03, height=0.50, top=True),
        eye=(0.88, 0.05),
        colors=dict(body=(0.60, 0.65, 0.60), fins=(0.48, 0.52, 0.48), marks=(0.30, 0.35, 0.30)),
    ),
    # Common - a rust-scaled snapper: deep-bodied, spiny-crested, oxide red.
    "RustscaleSnapper": dict(
        profile=[(0.00, 0.06), (0.18, 0.18), (0.48, 0.34), (0.78, 0.24), (0.94, 0.13), (1.00, 0.04)],
        width=0.5,
        sides=6,
        tail=dict(kind="forked", reach=0.36, spread=0.32, notch=0.10),
        dorsals=[dict(t0=0.40, t1=0.70, height=0.28, kind="spiny", spines=8), dict(t0=0.22, t1=0.38, height=0.16, kind="soft")],
        anals=[dict(t0=0.24, t1=0.40, height=0.14, kind="soft")],
        pectoral=0.28,
        marks=dict(kind="bars", count=5, t0=0.22, t1=0.80, width=0.045, height=0.80),
        eye=(0.86, 0.055),
        colors=dict(body=(0.65, 0.40, 0.30), fins=(0.50, 0.30, 0.24), marks=(0.35, 0.20, 0.15)),
    ),
    # Common - a barnacle blenny: blunt-headed, one long dorsal, mottled.
    "BarnacleBlenny": dict(
        profile=[(0.00, 0.04), (0.24, 0.12), (0.60, 0.17), (0.86, 0.16), (1.00, 0.06)],
        width_profile=[(0.00, 0.02), (0.25, 0.07), (0.60, 0.10), (0.85, 0.13), (1.00, 0.07)],
        sides=6,
        tail=dict(kind="rounded", reach=0.28, spread=0.22),
        dorsals=[dict(t0=0.14, t1=0.86, height=0.18, kind="soft")],
        anals=[dict(t0=0.14, t1=0.50, height=0.10, kind="soft")],
        pectoral=0.30,
        marks=dict(kind="bars", count=5, t0=0.22, t1=0.78, width=0.05, height=0.70),
        eye=(0.86, 0.05),
        colors=dict(body=(0.50, 0.48, 0.40), fins=(0.42, 0.40, 0.34), marks=(0.72, 0.70, 0.62)),
    ),
    # Uncommon - a ghost carp: deep, whiskered, pale as fog.
    "GhostCarp": dict(
        profile=[(0.00, 0.05), (0.20, 0.16), (0.50, 0.30), (0.80, 0.22), (1.00, 0.05)],
        width=0.58,
        sides=6,
        tail=dict(kind="forked", reach=0.38, spread=0.32, notch=0.10),
        dorsals=[dict(t0=0.30, t1=0.62, height=0.24, kind="soft")],
        anals=[dict(t0=0.22, t1=0.36, height=0.12, kind="soft")],
        pectoral=0.28,
        barbel="whiskers",
        marks=dict(kind="stripe", t0=0.10, t1=0.90, height=0.20),
        eye=(0.87, 0.05),
        colors=dict(body=(0.72, 0.78, 0.75), fins=(0.60, 0.68, 0.66), marks=(0.86, 0.92, 0.88)),
    ),
    # LEGENDARY chase - the Spectral Sailfish (rows scale it 2.1): the bill
    # and THE SAIL, grave-teal and glowing.
    "SpectralSailfish": dict(
        profile=[(0.00, 0.03), (0.16, 0.10), (0.48, 0.26), (0.80, 0.19), (1.00, 0.04)],
        width=0.55,
        sides=7,
        tail=dict(kind="lunate", reach=0.50, spread=0.46),
        dorsals=[dict(t0=0.28, t1=0.78, height=0.55, kind="soft"), dict(t0=0.16, t1=0.24, height=0.10, kind="soft")],
        anals=[dict(t0=0.26, t1=0.40, height=0.14, kind="sickle")],
        pectoral=0.38,
        jaw="bill",
        marks=dict(kind="bars", count=6, t0=0.24, t1=0.76, width=0.03, height=0.70),
        eye=(0.86, 0.05),
        colors=dict(body=(0.45, 0.60, 0.62), fins=(0.50, 0.85, 0.80), marks=(0.60, 0.95, 0.88)),
    ),
    # ---- Maelstrom fish (island 7) ----
    # Storm silver and thunderhead blue; the tuna is the Legendary.
    # Common - a squall sprat, barely more than a fleck of storm-light.
    "SquallSprat": dict(
        profile=[(0.00, 0.03), (0.24, 0.09), (0.55, 0.14), (0.86, 0.09), (1.00, 0.02)],
        width=0.48,
        sides=6,
        tail=dict(kind="forked", reach=0.40, spread=0.26, notch=0.16),
        dorsals=[dict(t0=0.44, t1=0.58, height=0.12, kind="soft")],
        anals=[dict(t0=0.26, t1=0.40, height=0.08, kind="soft")],
        pectoral=0.20,
        marks=dict(kind="stripe", t0=0.14, t1=0.88, height=0.14),
        eye=(0.88, 0.045),
        colors=dict(body=(0.65, 0.70, 0.78), fins=(0.50, 0.56, 0.66), marks=(0.82, 0.87, 0.95)),
    ),
    # Common - a rainfin mackerel: storm bars, wet-sky sheen.
    "RainfinMackerel": dict(
        profile=[(0.00, 0.04), (0.20, 0.11), (0.52, 0.19), (0.86, 0.12), (1.00, 0.02)],
        width=0.62,
        sides=6,
        tail=dict(kind="forked", reach=0.42, spread=0.30, notch=0.14),
        dorsals=[dict(t0=0.52, t1=0.70, height=0.14, kind="spiny", spines=5), dict(t0=0.30, t1=0.42, height=0.10, kind="soft")],
        anals=[dict(t0=0.30, t1=0.42, height=0.10, kind="soft")],
        pectoral=0.24,
        finlets=(0.12, 0.28, 5),
        marks=dict(kind="bars", count=8, t0=0.24, t1=0.80, width=0.028, height=0.50, top=True),
        eye=(0.88, 0.045),
        colors=dict(body=(0.35, 0.45, 0.55), fins=(0.28, 0.36, 0.46), marks=(0.12, 0.20, 0.30)),
    ),
    # Common - a foam-chaser mullet: blunt, twin short dorsals, spray-pale.
    "FoamchaserMullet": dict(
        profile=[(0.00, 0.05), (0.22, 0.14), (0.55, 0.22), (0.84, 0.16), (1.00, 0.04)],
        width=0.60,
        sides=6,
        tail=dict(kind="square", reach=0.32, spread=0.28),
        dorsals=[dict(t0=0.56, t1=0.68, height=0.16, kind="spiny", spines=4), dict(t0=0.30, t1=0.42, height=0.13, kind="soft")],
        anals=[dict(t0=0.28, t1=0.42, height=0.11, kind="soft")],
        pectoral=0.26,
        marks=dict(kind="stripe", t0=0.12, t1=0.88, height=0.16),
        eye=(0.87, 0.05),
        colors=dict(body=(0.55, 0.60, 0.62), fins=(0.44, 0.50, 0.54), marks=(0.80, 0.84, 0.86)),
    ),
    # LEGENDARY chase - the Stormking Tuna (rows scale it 2.3): the biggest
    # torpedo in the game, thunder-dark with a lightning-gold stripe.
    "StormkingTuna": dict(
        profile=[(0.00, 0.03), (0.16, 0.10), (0.50, 0.32), (0.80, 0.25), (1.00, 0.03)],
        width=0.88,
        sides=8,
        tail=dict(kind="lunate", reach=0.56, spread=0.52),
        dorsals=[dict(t0=0.50, t1=0.70, height=0.42, kind="sickle"), dict(t0=0.32, t1=0.46, height=0.18, kind="sickle")],
        anals=[dict(t0=0.32, t1=0.46, height=0.18, kind="sickle")],
        pectoral=0.50,
        finlets=(0.10, 0.36, 9),
        marks=dict(kind="stripe", t0=0.10, t1=0.90, height=0.24),
        eye=(0.88, 0.05),
        colors=dict(body=(0.16, 0.22, 0.36), fins=(0.30, 0.38, 0.50), marks=(0.95, 0.85, 0.40)),
    ),
    # Epic - the trophy: a molten-cored tuna, lunate tail, a long run of ember finlets.
    "MagmafinTuna": dict(
        profile=[(0.00, 0.03), (0.16, 0.10), (0.50, 0.31), (0.80, 0.24), (1.00, 0.03)],
        width=0.86,
        sides=8,
        tail=dict(kind="lunate", reach=0.54, spread=0.50),
        dorsals=[dict(t0=0.50, t1=0.70, height=0.40, kind="sickle"), dict(t0=0.32, t1=0.46, height=0.18, kind="sickle")],
        anals=[dict(t0=0.32, t1=0.46, height=0.18, kind="sickle")],
        pectoral=0.48,
        finlets=(0.10, 0.36, 9),
        marks=dict(kind="stripe", t0=0.10, t1=0.90, height=0.26),
        eye=(0.88, 0.05),
        colors=dict(body=(0.12, 0.11, 0.14), fins=(0.58, 0.22, 0.12), marks=(1.00, 0.55, 0.12)),
    ),
}

# Preview order left to right, smallest to largest.
ORDER = [
    "Perch", "Mackerel", "Trout", "Puffer", "Bass", "Cod", "Catfish", "Salmon", "Tuna",
    # Volcano fish, smallest to largest.
    "Ashgill", "MagmaGuppy", "Emberfin", "ObsidianBass", "BasaltCod", "PyreSalmon", "MagmafinTuna",
    # Frostmaw Reach, smallest to largest.
    "IcemeltSmelt", "SnowdriftSculpin", "FrostfinChar", "RimeHerring", "AurorafinMarlin",
    # Gloomtrench.
    "PaleDace", "BlindcaveSardine", "SootgillHagfish", "GhostlightOarfish",
    # Wreckwater.
    "BarnacleBlenny", "WreckHerring", "RustscaleSnapper", "GhostCarp", "SpectralSailfish",
    # The Maelstrom.
    "SquallSprat", "RainfinMackerel", "FoamchaserMullet", "StormkingTuna",
]


# ---------------------------------------------------------------- profile math


def interp(points, t):
    for i in range(len(points) - 1):
        t0, v0 = points[i]
        t1, v1 = points[i + 1]
        if t <= t1:
            u = 0 if t1 == t0 else (t - t0) / (t1 - t0)
            return v0 + (v1 - v0) * u
    return points[-1][1]


def y_at(t):
    """Blender y for a profile parameter: tail at -L/2, nose at +L/2."""
    return -BODY_LENGTH / 2 + t * BODY_LENGTH


class Shape:
    """A species' body functions, so every part builder reads the same body."""

    def __init__(self, spec):
        self.spec = spec
        self.profile = spec["profile"]
        self.width_profile = spec.get("width_profile")
        self.width = spec.get("width", 0.55)

    def hh(self, t):
        return interp(self.profile, t)

    def hw(self, t):
        if self.width_profile:
            return interp(self.width_profile, t)
        return self.hh(t) * self.width

    def back(self, t, lift=0.0):
        return Vector((0, y_at(t), self.hh(t) - 0.02 + lift))

    def belly(self, t, drop=0.0):
        return Vector((0, y_at(t), -self.hh(t) + 0.02 - drop))


# ---------------------------------------------------------------- scene helpers


def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    for block in (bpy.data.meshes, bpy.data.materials):
        for item in list(block):
            block.remove(item)


def make_material(name, rgb):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    r, g, b = rgb
    bsdf.inputs["Base Color"].default_value = (r, g, b, 1)
    bsdf.inputs["Roughness"].default_value = 1.0
    # Workbench (the preview render) draws the viewport colour, not the node.
    mat.diffuse_color = (r, g, b, 1)
    return mat


def object_from_bmesh(name, bm, material, offset):
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])

    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()

    obj = bpy.data.objects.new(name, mesh)
    obj.data.materials.append(material)
    obj.location = offset

    for poly in mesh.polygons:
        poly.use_smooth = False

    bpy.context.collection.objects.link(obj)
    return obj


def prism(bm, points, normal, thickness):
    """A thin slab from a planar polygon: the polygon offset half the
    thickness each way along `normal`, plus side quads. Gives fins volume so
    they don't vanish when seen edge-on or from behind."""
    n = normal.normalized() * (thickness / 2)
    top = [bm.verts.new(p + n) for p in points]
    bottom = [bm.verts.new(p - n) for p in points]
    bm.faces.new(top)
    bm.faces.new(list(reversed(bottom)))
    count = len(points)
    for i in range(count):
        j = (i + 1) % count
        bm.faces.new((top[i], top[j], bottom[j], bottom[i]))


SIDE = Vector((1, 0, 0))
BACKWARD = Vector((0, -1, 0))


# ---------------------------------------------------------------- body


def build_body(shape, bm):
    sides = shape.spec["sides"]
    steps = BODY_RINGS + 1
    rings = []
    for i in range(1, steps):  # ends are closed to points below
        t = i / steps
        hz, hx = shape.hh(t), shape.hw(t)
        ring = []
        for s in range(sides):
            a = (s / sides) * math.tau
            ring.append(bm.verts.new(Vector((math.cos(a) * hx, y_at(t), math.sin(a) * hz))))
        rings.append(ring)

    for a, b in zip(rings, rings[1:]):
        for i in range(sides):
            bm.faces.new((a[i], a[(i + 1) % sides], b[(i + 1) % sides], b[i]))

    tail = bm.verts.new(Vector((0, y_at(0), 0)))
    nose = bm.verts.new(Vector((0, y_at(1), 0)))
    first, last = rings[0], rings[-1]
    for i in range(sides):
        bm.faces.new((first[(i + 1) % sides], first[i], tail))
        bm.faces.new((last[i], last[(i + 1) % sides], nose))


def build_jaw(shape, bm, kind):
    """Salmon kype: the hooked lower jaw, a wedge under the nose curling up.
    Bill: a marlin/sailfish spear off the nose, a long thin wedge along +Y."""
    if kind == "bill":
        y1 = y_at(1.0)
        prism(
            bm,
            [
                Vector((0, y1 - 0.06, shape.hh(0.96) * 0.4)),
                Vector((0, y1 + 0.6, 0.05)),
                Vector((0, y1 - 0.06, -shape.hh(0.96) * 0.05)),
            ],
            SIDE,
            0.045,
        )
        return
    if kind != "kype":
        return
    prism(
        bm,
        [
            Vector((0, y_at(0.90), -shape.hh(0.90) + 0.02)),
            Vector((0, y_at(1.00) + 0.12, -0.03)),
            Vector((0, y_at(1.00) + 0.10, 0.06)),
            Vector((0, y_at(0.96), -shape.hh(0.96) * 0.4)),
        ],
        SIDE,
        shape.hw(0.95) * 1.2,
    )


def build_barbels(shape, bm, kind):
    """Skin-coloured feelers: a cod's single chin barbel, a catfish's
    whiskers. Thin prisms so they have an edge at a glance."""
    if kind == "chin":
        t = 0.95
        root = Vector((0, y_at(t), -shape.hh(t) + 0.01))
        prism(
            bm,
            [root, root + Vector((0, 0.03, -0.14)), root + Vector((0, -0.04, -0.02))],
            SIDE,
            0.025,
        )
    elif kind == "whiskers":
        t = 0.96
        for sign in (1, -1):
            root = Vector((sign * shape.hw(t) * 0.8, y_at(t), -0.02))
            tip = root + Vector((sign * 0.46, -0.34, -0.10))
            prism(bm, [root, tip, root + Vector((0, -0.06, 0))], Vector((0, 0, 1)), 0.022)
        # A second, shorter pair under the chin.
        for sign in (1, -1):
            root = Vector((sign * shape.hw(t) * 0.35, y_at(t) - 0.02, -shape.hh(t) + 0.02))
            tip = root + Vector((sign * 0.10, -0.18, -0.16))
            prism(bm, [root, tip, root + Vector((0, -0.05, 0))], Vector((1, 0, 0)), 0.02)


# ---------------------------------------------------------------- fins


def tail_points(shape, tail):
    tail_y = y_at(0)
    root_h = shape.hh(0.06)
    reach, spread = tail["reach"], tail["spread"]
    kind = tail["kind"]
    top_root = Vector((0, tail_y + 0.05, root_h))
    bottom_root = Vector((0, tail_y + 0.05, -root_h))

    if kind == "forked":
        notch = tail.get("notch", 0.12)
        return [
            top_root,
            Vector((0, tail_y - reach, spread)),
            Vector((0, tail_y - reach + notch, 0.0)),
            Vector((0, tail_y - reach, -spread)),
            bottom_root,
        ]
    if kind == "rounded":
        return [
            top_root,
            Vector((0, tail_y - reach * 0.75, spread)),
            Vector((0, tail_y - reach, spread * 0.45)),
            Vector((0, tail_y - reach, -spread * 0.45)),
            Vector((0, tail_y - reach * 0.75, -spread)),
            bottom_root,
        ]
    if kind == "square":
        return [
            top_root,
            Vector((0, tail_y - reach, spread)),
            Vector((0, tail_y - reach, -spread)),
            bottom_root,
        ]
    if kind == "lunate":
        # Narrow peduncle, deep crescent, pointed lobes swept back.
        return [
            Vector((0, tail_y + 0.08, root_h * 0.7)),
            Vector((0, tail_y - reach * 0.45, spread * 0.55)),
            Vector((0, tail_y - reach, spread)),
            Vector((0, tail_y - reach * 0.30, 0.0)),
            Vector((0, tail_y - reach, -spread)),
            Vector((0, tail_y - reach * 0.45, -spread * 0.55)),
            Vector((0, tail_y + 0.08, -root_h * 0.7)),
        ]
    raise ValueError(f"unknown tail kind {kind}")


def fin_points(shape, fin, on_back):
    """Polygon for a dorsal (on_back) or anal fin, in the side plane."""
    t0, t1, h = fin["t0"], fin["t1"], fin["height"]
    kind = fin.get("kind", "soft")
    edge = shape.back if on_back else shape.belly
    points = [edge(t0, 0), edge(t1, 0)]
    if kind == "spiny":
        # Sawtooth top edge: each spine a sharp point with a dip between.
        spines = fin.get("spines", 5)
        for i in range(spines):
            u = i / (spines - 1) if spines > 1 else 0.5
            t = t1 - (t1 - t0) * u
            # Tallest at the front, shrinking toward the back.
            height = h * (1.0 - 0.45 * u)
            points.append(edge(t, height))
            if i < spines - 1:
                t_dip = t - (t1 - t0) / (spines - 1) * 0.5
                points.append(edge(t_dip, height * 0.55))
    elif kind == "sickle":
        # Tall, narrow, swept back to a point: a tuna's dorsal.
        points += [edge(t1 - 0.02, h), edge(t1 - 0.06, h * 0.75), edge((t0 + t1) / 2, h * 0.25)]
    elif kind == "adipose":
        # The small fleshy nub salmonids carry behind the dorsal.
        points += [edge(t1 - 0.01, h), edge(t0 + 0.02, h * 0.8)]
    else:
        points += [edge(t1 - 0.06, h), edge(t0 + 0.08, h * 0.85)]
    return points


def build_fins(shape, bm):
    spec = shape.spec
    prism(bm, tail_points(shape, spec["tail"]), SIDE, FIN_THICKNESS)

    for fin in spec.get("dorsals", []):
        prism(bm, fin_points(shape, fin, True), SIDE, FIN_THICKNESS)
    for fin in spec.get("anals", []):
        prism(bm, fin_points(shape, fin, False), SIDE, FIN_THICKNESS)

    # Pectorals: one each side, rooted just behind the head, swept back and
    # angled down. Built in a tilted plane so they read as fins, not shelves.
    length = spec.get("pectoral", 0.3)
    droop = math.radians(25)
    for sign in (1, -1):
        t_root = 0.68
        root = Vector((sign * shape.hw(t_root) * 0.9, y_at(t_root), -0.04))
        out = Vector((sign * math.cos(droop), 0, -math.sin(droop)))
        tip = root + out * length * 0.55 + BACKWARD * length * 0.85
        trailing = root + BACKWARD * length * 0.45
        prism(bm, [root, tip, trailing], out.cross(BACKWARD), FIN_THICKNESS)


# ---------------------------------------------------------------- marks


def build_finlets(shape, bm, finlets):
    """A row of tiny triangles between the rear fins and the tail, top and
    bottom - the tuna / mackerel signature."""
    t0, t1, count = finlets
    for i in range(count):
        t = t0 + (t1 - t0) * i / max(count - 1, 1)
        prism(bm, [shape.back(t, 0), shape.back(t + 0.035, 0), shape.back(t + 0.045, 0.07)], SIDE, FIN_THICKNESS)
        prism(bm, [shape.belly(t, 0), shape.belly(t + 0.035, 0), shape.belly(t + 0.045, 0.07)], SIDE, FIN_THICKNESS)


def build_marks(shape, bm, marks):
    """Side markings as thin slabs just off the body surface, one per side."""
    if not marks:
        return
    kind = marks["kind"]
    for sign in (1, -1):
        normal = Vector((sign, 0, 0))

        def side_point(t, z):
            return Vector((sign * (shape.hw(t) + 0.012), y_at(t), z))

        if kind == "stripe":
            # Lateral band, height as a fraction of the body's half-height
            # there, optionally lifted toward the back (cod's lateral line).
            t0, t1, h = marks["t0"], marks["t1"], marks["height"]
            lift = marks.get("lift", 0.0)
            steps = 6
            top, bottom = [], []
            for i in range(steps + 1):
                t = t0 + (t1 - t0) * i / steps
                hh = shape.hh(t)
                centre = hh * lift
                top.append(side_point(t, centre + hh * h / 2))
                bottom.append(side_point(t, centre - hh * h / 2))
            prism(bm, top + list(reversed(bottom)), normal, MARK_THICKNESS)
        elif kind == "bars":
            # Vertical bars; `top` keeps them to the upper half (mackerel).
            count, t0, t1, w, h = marks["count"], marks["t0"], marks["t1"], marks["width"], marks["height"]
            only_top = marks.get("top", False)
            for i in range(count):
                t = t0 + (t1 - t0) * i / max(count - 1, 1)
                hh = shape.hh(t)
                z_top = hh * h
                z_bottom = hh * 0.15 if only_top else -hh * h
                prism(
                    bm,
                    [side_point(t - w, z_bottom), side_point(t + w, z_bottom), side_point(t + w * 0.6, z_top), side_point(t - w * 0.6, z_top)],
                    normal,
                    MARK_THICKNESS,
                )


# ---------------------------------------------------------------- eyes


def build_eyes(shape, bm):
    # A flat hexagon stuck to each side of the head - six triangles per eye
    # instead of an icosphere's eighty. Thin prism so it has an edge when
    # seen at a glance, same treatment as the fins.
    eye_t, radius = shape.spec["eye"]
    y = y_at(eye_t)
    z = shape.hh(eye_t) * 0.3
    for sign in (1, -1):
        x = sign * (shape.hw(eye_t) - 0.005)
        points = []
        for i in range(6):
            a = (i / 6) * math.tau
            points.append(Vector((x, y + math.cos(a) * radius, z + math.sin(a) * radius)))
        prism(bm, points, Vector((sign, 0, 0)), 0.03)


# ---------------------------------------------------------------- pufferfish
#
# Its own builder: a fat faceted ellipsoid (an icosphere, flat-shaded low
# poly), ringed with short cone spikes, big hex eyes and a small beak.
#
# Axis ordering matters for how it rests. CreatureService.flatOrientation
# lays a creature with its LONGEST bbox axis horizontal (nose-tail) and its
# SHORTEST axis pointing UP. So for the puffer to sit belly-down and upright
# (not on its side) the top-to-bottom height must be the SHORTEST dimension,
# and nose-tail the longest (which also keeps the rusher's lunge aiming the
# right way). Hence length (Y) > width (X) > height (Z). The tail spike along
# -Y keeps Y the longest even after the spikes extend the box.

PUFFER_HALF = Vector((0.70, 1.0, 0.58))  # (width, length, height) half-extents; height smallest = sits upright
PUFFER_SPIKE_LEN = 0.34
PUFFER_SPIKE_RADIUS = 0.13
PUFFER_SPIKE_SIDES = 5


def _spike(bm, direction, length, radius):
    """A short cone from the body surface outward along `direction`, tip out.
    Appended into `bm`."""
    d = direction.normalized()
    surface = Vector((d.x * PUFFER_HALF.x, d.y * PUFFER_HALF.y, d.z * PUFFER_HALF.z))

    tmp = bmesh.new()
    # create_cone points its tip toward +Z (radius2 = 0); depth runs along Z.
    bmesh.ops.create_cone(
        tmp, cap_ends=True, cap_tris=False, segments=PUFFER_SPIKE_SIDES, radius1=radius, radius2=0.0, depth=length
    )
    rot = Vector((0, 0, 1)).rotation_difference(d).to_matrix().to_4x4()
    # After rotation the cone spans surface .. surface + d*length (base at the body).
    move = Matrix.Translation(surface + d * (length / 2 - 0.04))
    bmesh.ops.transform(tmp, matrix=move @ rot, verts=tmp.verts[:])

    mesh = bpy.data.meshes.new("_spike")
    tmp.to_mesh(mesh)
    tmp.free()
    bm.from_mesh(mesh)
    bpy.data.meshes.remove(mesh)


def build_puffer(name, spec, offset):
    colors = spec["colors"]
    objects = []

    # Body: a low-poly icosphere squashed to the puffer's proportions.
    body_bm = bmesh.new()
    bmesh.ops.create_icosphere(body_bm, subdivisions=1, radius=1.0)
    bmesh.ops.scale(body_bm, vec=PUFFER_HALF, verts=body_bm.verts[:])
    objects.append(object_from_bmesh(f"{name}_Body", body_bm, make_material(f"M_{name}_Body", colors["body"]), offset))

    # Spikes (Fins): latitude rings, plus poles and a tail spike; the front
    # cone (toward the face, +Y) is left clear for the eyes and beak.
    # Spike directions on latitude rings. Axes here are Blender's:
    # x = width, y = nose-tail (length), z = up (height).
    fins_bm = bmesh.new()
    directions = []
    for lat_deg in (-40, 0, 40):
        lat = math.radians(lat_deg)
        offset_ring = 0.0 if lat_deg == 0 else math.pi / 6
        for i in range(6):
            ang = (i / 6) * math.tau + offset_ring
            directions.append(Vector((math.cos(lat) * math.sin(ang), math.cos(lat) * math.cos(ang), math.sin(lat))))
    directions.append(Vector((0, -1, 0)))  # tail (keeps the box's Y axis longest)
    # NO straight up/down pole spikes on purpose: a full-length spike along
    # the height axis would push the height extent past the width extent
    # (the equatorial spikes only reach out at 60-degree steps, never pure
    # sideways), which would make WIDTH the shortest axis and flatOrientation
    # would stand the puffer on its side. The lat +/-40 rings already put
    # spikes near the top and bottom, so it doesn't look bald.

    for dir in directions:
        # Skip the face: a cone of directions around straight-ahead (+Y).
        if dir.normalized().y > 0.55:
            continue
        _spike(fins_bm, dir, PUFFER_SPIKE_LEN, PUFFER_SPIKE_RADIUS)

    # A small rounded tail behind the body.
    tail_y = -PUFFER_HALF.y
    prism(
        fins_bm,
        [
            Vector((0, tail_y + 0.05, PUFFER_HALF.z * 0.5)),
            Vector((0, tail_y - 0.26, PUFFER_HALF.z * 0.5)),
            Vector((0, tail_y - 0.30, 0.0)),
            Vector((0, tail_y - 0.26, -PUFFER_HALF.z * 0.5)),
            Vector((0, tail_y + 0.05, -PUFFER_HALF.z * 0.5)),
        ],
        SIDE,
        FIN_THICKNESS,
    )
    # Little pectoral fins, one each side.
    for sign in (1, -1):
        root = Vector((sign * PUFFER_HALF.x * 0.9, 0.15, -0.05))
        prism(
            fins_bm,
            [root, root + Vector((sign * 0.24, -0.18, -0.06)), root + Vector((0, -0.16, 0))],
            Vector((0, 0, 1)),
            FIN_THICKNESS,
        )
    objects.append(object_from_bmesh(f"{name}_Fins", fins_bm, make_material(f"M_{name}_Fins", colors["fins"]), offset))

    # Eyes: big hex prisms high on the front sides.
    eyes_bm = bmesh.new()
    for sign in (1, -1):
        ey, ez, radius = 0.52, 0.30, 0.20
        # Sit on the ellipsoid surface at that (y, z).
        ex = sign * PUFFER_HALF.x * math.sqrt(max(0.0, 1 - (ey / PUFFER_HALF.y) ** 2 - (ez / PUFFER_HALF.z) ** 2))
        points = []
        for i in range(6):
            a = (i / 6) * math.tau
            points.append(Vector((ex + sign * 0.02, ey + math.cos(a) * radius, ez + math.sin(a) * radius)))
        prism(eyes_bm, points, Vector((sign, 0, 0)), 0.05)
    objects.append(object_from_bmesh(f"{name}_Eyes", eyes_bm, make_material(f"M_{name}_Eyes", EYE_COLOR), offset))

    # Beak (Marks): a small dark wedge at the nose.
    marks_bm = bmesh.new()
    nose_y = PUFFER_HALF.y
    for zc, sign in ((0.04, 1), (-0.04, -1)):
        prism(
            marks_bm,
            [
                Vector((0.12, nose_y - 0.10, zc)),
                Vector((-0.12, nose_y - 0.10, zc)),
                Vector((-0.10, nose_y + 0.04, zc + sign * 0.05)),
                Vector((0.10, nose_y + 0.04, zc + sign * 0.05)),
            ],
            BACKWARD,
            MARK_THICKNESS,
        )
    objects.append(object_from_bmesh(f"{name}_Marks", marks_bm, make_material(f"M_{name}_Marks", colors["marks"]), offset))

    # Report the finished bounding box so the flat-lay ordering can be checked
    # without a Studio round-trip: for the puffer to sit upright (belly-down)
    # the height (z) must be the SMALLEST of the three, and the nose-tail (y)
    # the largest. flatOrientation stands the shortest axis up.
    mins = [1e9, 1e9, 1e9]
    maxs = [-1e9, -1e9, -1e9]
    for o in objects:
        for v in o.data.vertices:
            for i in range(3):
                mins[i] = min(mins[i], v.co[i])
                maxs[i] = max(maxs[i], v.co[i])
    dx, dy, dz = (maxs[i] - mins[i] for i in range(3))
    order = "OK (y>x>z, sits upright)" if dy > dx > dz else "BAD - will not sit upright"
    print(f"[fish_gen] Puffer bbox width(x)={dx:.3f} length(y)={dy:.3f} height(z)={dz:.3f}  -> {order}")

    return objects


# ---------------------------------------------------------------- assembly


def build_species(name, spec, offset):
    if spec.get("custom") == "puffer":
        return build_puffer(name, spec, offset)

    shape = Shape(spec)
    colors = spec["colors"]
    objects = []

    body_bm = bmesh.new()
    build_body(shape, body_bm)
    build_jaw(shape, body_bm, spec.get("jaw"))
    build_barbels(shape, body_bm, spec.get("barbel"))
    objects.append(object_from_bmesh(f"{name}_Body", body_bm, make_material(f"M_{name}_Body", colors["body"]), offset))

    fins_bm = bmesh.new()
    build_fins(shape, fins_bm)
    objects.append(object_from_bmesh(f"{name}_Fins", fins_bm, make_material(f"M_{name}_Fins", colors["fins"]), offset))

    eyes_bm = bmesh.new()
    build_eyes(shape, eyes_bm)
    objects.append(object_from_bmesh(f"{name}_Eyes", eyes_bm, make_material(f"M_{name}_Eyes", EYE_COLOR), offset))

    marks_bm = bmesh.new()
    build_marks(shape, marks_bm, spec.get("marks"))
    if spec.get("finlets"):
        build_finlets(shape, marks_bm, spec["finlets"])
    if len(marks_bm.verts) > 0:
        objects.append(object_from_bmesh(f"{name}_Marks", marks_bm, make_material(f"M_{name}_Marks", colors["marks"]), offset))
    else:
        marks_bm.free()

    return objects


def render_preview(path, count=None):
    """A flat-shaded line-up of every species from the side, so a design
    pass can be judged from a PNG without a Studio import. Workbench, so it
    renders in a second or two headless."""
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "MATERIAL"
    scene.display.shading.show_cavity = False
    # Kept under 2000px wide so the PNG can be opened and judged directly by
    # tooling that caps image size; the line-up is legible either way.
    scene.render.resolution_x = 1920
    scene.render.resolution_y = 760
    scene.render.film_transparent = False
    scene.world = scene.world or bpy.data.worlds.new("World")
    scene.world.color = (0.85, 0.88, 0.92)

    width = (count or len(ORDER)) * PREVIEW_SPACING
    cam_data = bpy.data.cameras.new("PreviewCam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = width + 1.0
    cam = bpy.data.objects.new("PreviewCam", cam_data)
    # The species are spaced along Y (nose to tail) for the preview, so a
    # camera out on +X looking back along -X sees every flank side by side,
    # noses pointing right. Tipped a little from above so the dorsal line
    # and the back markings read.
    cam.location = Vector((25, 0, 7))
    cam.rotation_euler = (math.radians(75), 0, math.radians(90))
    bpy.context.collection.objects.link(cam)
    scene.camera = cam

    # Absolute on purpose: in background mode a relative render path is
    # resolved against Blender's own idea of the working directory, not the
    # shell's, and quietly lands somewhere else (or nowhere).
    path = os.path.abspath(path)
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    bpy.data.objects.remove(cam)
    bpy.data.cameras.remove(cam_data)
    if not os.path.exists(path):
        raise RuntimeError(f"render did not produce {path}")


def main():
    args = sys.argv[sys.argv.index("--") + 1 :]
    out_path = args[0]
    preview_path = args[1] if len(args) > 1 and not args[1].startswith("only=") else None

    # `only=Name,Name` builds just those species, for REVIEWING a few at a time
    # (sixteen in one line-up is too small to judge a fin on). It renders to its
    # own PNG and deliberately writes NO .glb, so a partial build can never
    # overwrite the real pack.
    only = None
    for arg in args[1:]:
        if arg.startswith("only="):
            only = [n.strip() for n in arg[len("only=") :].split(",") if n.strip()]
    order = ORDER
    if only:
        missing = [n for n in only if n not in SPECIES]
        if missing:
            raise SystemExit(f"[fish_gen] unknown species: {', '.join(missing)}")
        order = [n for n in ORDER if n in only]
        preview_path = "assets/fish_preview_subset.png"
        out_path = None

    clear_scene()

    objects = []
    for index, name in enumerate(order):
        offset = Vector((0, (index - (len(order) - 1) / 2) * PREVIEW_SPACING, 0))
        objects += build_species(name, SPECIES[name], offset)

    if preview_path:
        render_preview(preview_path, len(order))
        print(f"[fish_gen] preview rendered to {preview_path}")

    if out_path:
        bpy.ops.object.select_all(action="SELECT")
        bpy.ops.export_scene.gltf(
            filepath=out_path,
            export_format="GLB",
            use_selection=True,
            export_yup=True,
            export_materials="EXPORT",
            export_apply=True,
            export_normals=True,
            export_texcoords=False,
        )
        print(f"[fish_gen] exported {out_path}")
    else:
        print("[fish_gen] only= subset: preview only, no .glb written")

    total_polys = sum(len(o.data.polygons) for o in objects)
    print(f"[fish_gen] species: {order}")
    print(f"[fish_gen] objects: {[o.name for o in objects]}")
    print(f"[fish_gen] body length {BODY_LENGTH} studs each, polys: {total_polys}")


main()
