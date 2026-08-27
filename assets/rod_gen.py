# rod_gen.py
# Generates every fishing rod as low-poly meshes and exports them together as
# one glTF pack (.glb) for Roblox's Import - the same "one import" approach as
# fish_gen.py's FishPack. Run headless:
#
#   blender --background --python assets/rod_gen.py -- assets/rod.glb
#   blender --background --python assets/rod_gen.py -- assets/rod.glb preview
#
# The second form also writes assets/rod_preview.png (the four rods lined up)
# for design review without importing.
#
# One pack, many rods: each variant is exported as <Variant>_Twig / _Grip /
# _Trim / _Line / _BobberTop / _BobberBottom, all overlapping at the origin
# (they're never shown together in game - RodModel clones one variant's parts
# out by name and renames them to the generic Rod_* set). Overlap in the
# template is invisible; the preview render lays them out side by side.
#
#   _Twig          the shaft (plus grown twigs / barbs)
#   _Grip          the handle, and anything that should share its colour
#                  (the Abyssal's iron reel + pommel spike)
#   _Trim          the hardware: line guides, bands / lashings, tip ring,
#                  reel, pommel cap - everything in the rod's "metal" colour
#                  (twine on the twig, brass on the bamboo, steel on the
#                  angler's, glowing teal on the abyssal)
#   _Line          the idle line hanging off the tip
#   _BobberTop/    the float, split at its waterline so the two halves can
#   _BobberBottom  take two colours (red/white, orange/pearl, glow/iron...)
#
# Authoring contract (RodModel / RodService rely on these, keep them true):
#   - 1 Blender unit = 1 Roblox stud. Exported Y-up, so Blender +Z -> Roblox
#     +Y: every rod stands upright, butt at y = 0, tip at y = ROD_LENGTH.
#   - Every variant shares ROD_LENGTH and GRIP_CENTER so one Rods.luau
#     grip/length pair covers them all; the shapes differ, the frame doesn't.
#   - Parts named as above. The grip is its own object and its centre is the
#     hand point. _Trim is optional per variant (RodModel skips a missing one).
#   - Flat shading everywhere, matching the island.
#
# Colours here are only for the preview; in game RodModel recolours per rod
# row (Rods.luau model.colors, one key per part), and marks the parts listed
# in model.neon as glowing. The preview colours below mirror those rows so
# the render is a fair picture of the game.

import math
import sys

import bmesh
import bpy
from mathutils import Vector

# ---------------------------------------------------------------- shared frame

ROD_LENGTH = 7.0  # butt to tip, studs, for every variant

GRIP_START = 0.15
GRIP_END = 1.75
GRIP_CENTER = (GRIP_START + GRIP_END) / 2  # 0.95 - Rods.luau `grip` must match

# Axis note (learned the hard way): Studio's importer turns the model 180
# about Y, so Blender -y -> Roblox -Z. In the first-person hold local -Z is
# down-and-forward, i.e. the rod's underside - so guides, reels and the
# hanging line all live on Blender -y.
UNDER = Vector((0.0, -1.0, 0.0))

# ---------------------------------------------------------------- variants
#
# Each rod is a config over one shared builder. The knobs:
#   radius_butt/tip  - taper of the shaft
#   sides            - facets around it (round vs angular)
#   flatten          - y-scale of the shaft's cross-section (1 = round;
#                      < 1 is a blade seen edge-on from the side)
#   lean/kink        - how much the shaft curves (0 = a straight cane)
#   hook             - extra forward (-y) curl concentrated at the tip
#   grip_style       - "wrapped" ridged cord, or smooth "cork"
#   grip_radius      - handle thickness
#   nodes/node_amp   - N periodic bulges baked into the radius (bamboo joints)
#   cones            - list of (z, angle, length, cant) jutting cones on the
#                      shaft: cant > 0 tilts them toward the tip (grown
#                      twigs), cant < 0 toward the butt (backswept barbs)
#   bands            - list of (z, width) wraps around the shaft (_Trim):
#                      twine lashings, ferrules, glowing rings
#   guides           - z positions of line guides, all on the underside
#   guide_style      - "loop" (bent wire on a foot) / "collar" (a ring
#                      around the shaft itself)
#   tip_ring         - a ring at the very tip
#   reel             - None, or {"style": "spinning" | "spiked", "part": ...}
#   pommel           - None / "cap" (_Trim) / "spike" (_Grip)
#   line             - length / tilt (deg) / bow / radius of the idle line
#   float            - "round" / "quill" / "pear" / "lantern"
#   colors           - PREVIEW ONLY (r,g,b 0..1); game colour is per rod row

VARIANTS = {
    # Driftwood twig - the starter. A crooked stick with grown twigs, a
    # cord grip, two twine-lashed wire loops for guides, the classic
    # red-and-white round bobber.
    "Twig": {
        "radius_butt": 0.20,
        "radius_tip": 0.05,
        "sides": 6,
        "flatten": 1.0,
        "lean": 0.22,
        "kink": 0.06,
        "hook": 0.0,
        "grip_style": "wrapped",
        "grip_radius": 0.30,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [(2.6, 0.8, 0.30, 0.55), (4.1, 3.9, 0.26, 0.55), (5.3, 2.2, 0.20, 0.55)],
        "bands": [(2.15, 0.16), (4.75, 0.14)],
        "guides": [2.15, 4.75],
        "guide_style": "loop",
        "tip_ring": False,
        "reel": None,
        "pommel": None,
        "line": {"length": 2.6, "tilt": 24, "bow": 0.18, "radius": 0.028},
        "float": "round",
        "colors": {
            "twig": (0.545, 0.408, 0.267),
            "grip": (0.361, 0.318, 0.224),
            "trim": (0.27, 0.23, 0.17),
            "line": (0.88, 0.88, 0.84),
            "top": (0.85, 0.18, 0.16),
            "bottom": (0.96, 0.96, 0.94),
        },
    },
    # Bamboo cane - straight, round, clear segment joints with brass
    # ferrules at each, brass wire guides, a capped butt, a slim quill float.
    "Bamboo": {
        "radius_butt": 0.17,
        "radius_tip": 0.10,
        "sides": 8,
        "flatten": 1.0,
        "lean": 0.03,
        "kink": 0.0,
        "hook": 0.0,
        "grip_style": "wrapped",
        "grip_radius": 0.26,
        "nodes": 5,
        "node_amp": 0.05,
        "cones": [],
        "bands": [(2.33, 0.1), (3.5, 0.1), (4.67, 0.1), (5.83, 0.1)],
        "guides": [2.9, 4.1, 5.25, 6.3],
        "guide_style": "loop",
        "tip_ring": True,
        "reel": None,
        "pommel": "cap",
        "line": {"length": 2.8, "tilt": 20, "bow": 0.12, "radius": 0.024},
        "float": "quill",
        "colors": {
            "twig": (0.60, 0.68, 0.36),
            "grip": (0.34, 0.45, 0.24),
            "trim": (0.77, 0.60, 0.28),
            "line": (0.90, 0.90, 0.86),
            "top": (1.0, 0.67, 0.16),
            "bottom": (0.93, 0.89, 0.77),
        },
    },
    # Angler's rod - the proper one: slim varnished blank with a clean fast
    # taper, cork handle with a steel reel seat, a spinning reel hung under
    # it, a run of snake guides up to a tip ring, a pear float on a stem.
    "Angler": {
        "radius_butt": 0.15,
        "radius_tip": 0.03,
        "sides": 8,
        "flatten": 1.0,
        "lean": 0.12,
        "kink": 0.0,
        "hook": 0.0,
        "grip_style": "cork",
        "grip_radius": 0.27,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [],
        "bands": [(1.3, 0.12), (1.62, 0.12), (2.05, 0.08)],
        "guides": [2.55, 3.45, 4.3, 5.1, 5.85, 6.5],
        "guide_style": "loop",
        "tip_ring": True,
        "reel": {"style": "spinning", "part": "Trim", "z": 1.46},
        "pommel": "cap",
        "line": {"length": 2.9, "tilt": 18, "bow": 0.10, "radius": 0.022},
        "float": "pear",
        "colors": {
            "twig": (0.55, 0.33, 0.17),
            "grip": (0.80, 0.68, 0.47),
            "trim": (0.78, 0.80, 0.84),
            "line": (0.78, 0.88, 0.93),
            "top": (1.0, 0.50, 0.12),
            "bottom": (0.98, 0.97, 0.94),
        },
    },
    # Reefmaw rod - crab-crusted salvage: a stout weathered shaft studded with
    # barnacle cones, banded in shell, a proper spinning reel, a round cork
    # float. Built from barnacle chitin - tough and forgiving (control). Rare.
    "Reefmaw": {
        "radius_butt": 0.23,
        "radius_tip": 0.06,
        "sides": 7,
        "flatten": 0.92,
        "lean": 0.14,
        "kink": 0.05,
        "hook": 0.12,
        "grip_style": "wrapped",
        "grip_radius": 0.33,
        "nodes": 0,
        "node_amp": 0.0,
        # stubby barnacle cones clustered up the shaft (cant ~0 = they stick
        # straight out, like the real crust rather than grown twigs)
        "cones": [(1.9, 1.0, 0.20, 0.15), (2.8, 4.2, 0.17, 0.1), (3.7, 2.0, 0.18, 0.15), (4.6, 5.4, 0.15, 0.1), (5.4, 3.0, 0.14, 0.15)],
        "bands": [(1.85, 0.16), (3.3, 0.13), (4.9, 0.11)],
        "guides": [2.4, 3.6, 4.8, 6.0],
        "guide_style": "loop",
        "tip_ring": True,
        "reel": {"style": "spinning", "part": "Trim", "z": 1.46},
        "pommel": "cap",
        "line": {"length": 2.7, "tilt": 22, "bow": 0.14, "radius": 0.030},
        "float": "round",
        "colors": {
            "twig": (0.42, 0.46, 0.40),
            "grip": (0.27, 0.25, 0.21),
            "trim": (0.80, 0.78, 0.66),
            "line": (0.85, 0.88, 0.86),
            "top": (0.96, 0.55, 0.32),
            "bottom": (0.93, 0.90, 0.82),
        },
    },
    # Bonecaster rod - lashed from cursed bone: a pale flattened shaft that
    # hooks forward, backswept rib-barbs down its spine, glowing brine-green
    # collars and a will-o'-wisp lantern float, a spiked bone drum. Lucky and
    # strong, but twitchy (low control). Epic.
    "Bonecaster": {
        "radius_butt": 0.24,
        "radius_tip": 0.05,
        "sides": 6,
        "flatten": 0.62,
        "lean": 0.11,
        "kink": 0.06,
        "hook": 0.55,
        "grip_style": "wrapped",
        "grip_radius": 0.32,
        "nodes": 0,
        "node_amp": 0.0,
        # backswept rib-barbs, a drowned spine
        "cones": [(2.9, 1.2, 0.42, -0.7), (3.8, 4.4, 0.38, -0.7), (4.6, 2.6, 0.32, -0.75), (5.4, 0.3, 0.26, -0.8), (6.0, 3.4, 0.22, -0.85)],
        "bands": [(2.4, 0.1), (3.4, 0.09), (4.5, 0.08), (5.5, 0.07)],
        "guides": [2.4, 3.4, 4.5, 5.5],
        "guide_style": "collar",
        "tip_ring": True,
        "reel": {"style": "spiked", "part": "Grip", "z": 1.5},
        "pommel": "spike",
        "line": {"length": 2.4, "tilt": 28, "bow": 0.06, "radius": 0.032},
        "float": "lantern",
        "neon": ["Trim", "BobberTop"],  # preview-only glow; game reads model.neon
        "colors": {
            "twig": (0.80, 0.78, 0.68),
            "grip": (0.20, 0.23, 0.21),
            "trim": (0.45, 0.95, 0.55),
            "line": (0.30, 0.40, 0.34),
            "top": (0.55, 1.0, 0.60),
            "bottom": (0.34, 0.35, 0.29),
        },
    },
    # Strung on a thread of Brinejaw's heart: a heavy red-heartwood blank with
    # bone hardware, a broad pear float and a big drum. The capstone - it reads
    # as the most substantial rod on the rack. Legendary.
    "Brineheart": {
        "radius_butt": 0.27,
        "radius_tip": 0.052,
        "sides": 8,
        "flatten": 0.72,
        "lean": 0.1,
        "kink": 0.05,
        "hook": 0.6,
        "grip_style": "wrapped",
        "grip_radius": 0.35,
        "nodes": 0,
        "node_amp": 0.0,
        # heavy backswept barbs, thinning toward the tip
        "cones": [
            (2.5, 1.6, 0.46, -0.65),
            (3.4, 4.8, 0.4, -0.7),
            (4.3, 1.6, 0.33, -0.75),
            (5.2, 4.8, 0.26, -0.8),
            (5.9, 1.6, 0.2, -0.85),
        ],
        "bands": [(2.1, 0.11), (3.2, 0.1), (4.3, 0.09), (5.4, 0.075)],
        "guides": [2.3, 3.4, 4.5, 5.6],
        "guide_style": "collar",
        "tip_ring": True,
        "reel": {"style": "spiked", "part": "Grip", "z": 1.55},
        "pommel": "spike",
        "line": {"length": 2.6, "tilt": 26, "bow": 0.07, "radius": 0.034},
        "float": "pear",
        "neon": ["Trim", "BobberTop"],  # preview-only glow; game reads model.neon
        "colors": {
            "twig": (0.41, 0.23, 0.24),
            "grip": (0.20, 0.13, 0.15),
            "trim": (0.89, 0.84, 0.75),
            "line": (0.94, 0.82, 0.82),
            "top": (1.0, 0.38, 0.41),
            "bottom": (0.94, 0.91, 0.86),
        },
    },
    # ---------------------------------------------------------- Volcano rods
    # Fourteen more variants (Rods.luau cinderline_rod .. phoenix_ash_rod),
    # Uncommon -> Legendary. Thirteen are plain config entries like Reefmaw;
    # PhoenixAsh gets a bespoke builder (below) for its Legendary flourish.
    #
    # Cinderline - a scorched driftwood twig with a scatter of ember-hot
    # cones. Simple recolour of the Twig frame. Uncommon.
    "Cinderline": {
        "radius_butt": 0.19,
        "radius_tip": 0.045,
        "sides": 6,
        "flatten": 1.0,
        "lean": 0.18,
        "kink": 0.05,
        "hook": 0.0,
        "grip_style": "wrapped",
        "grip_radius": 0.28,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [(2.3, 1.0, 0.22, 0.5), (3.9, 4.0, 0.20, 0.5), (5.2, 2.4, 0.16, 0.5)],
        "bands": [(2.0, 0.14), (4.5, 0.12)],
        "guides": [2.0, 4.5],
        "guide_style": "loop",
        "tip_ring": False,
        "reel": None,
        "pommel": None,
        "line": {"length": 2.5, "tilt": 24, "bow": 0.16, "radius": 0.026},
        "float": "round",
        "colors": {
            "twig": (0.37, 0.28, 0.21),
            "grip": (0.24, 0.19, 0.15),
            "trim": (0.94, 0.52, 0.20),
            "line": (0.77, 0.71, 0.64),
            "top": (0.94, 0.52, 0.20),
            "bottom": (0.24, 0.21, 0.18),
        },
    },
    # Obsidian - a glassy black-glass blade that hooks forward, glowing
    # ember hardware, a spinning reel. Rare.
    "Obsidian": {
        "radius_butt": 0.24,
        "radius_tip": 0.06,
        "sides": 6,
        "flatten": 0.65,
        "lean": 0.1,
        "kink": 0.04,
        "hook": 0.4,
        "grip_style": "wrapped",
        "grip_radius": 0.31,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [(3.0, 1.2, 0.24, -0.4), (4.4, 4.4, 0.2, -0.4), (5.6, 2.4, 0.16, -0.45)],
        "bands": [(2.2, 0.1), (3.6, 0.09), (5.0, 0.08)],
        "guides": [2.2, 3.6, 5.0, 6.1],
        "guide_style": "collar",
        "tip_ring": True,
        "reel": {"style": "spinning", "part": "Trim", "z": 1.46},
        "pommel": "cap",
        "line": {"length": 2.6, "tilt": 24, "bow": 0.09, "radius": 0.028},
        "float": "round",
        "neon": ["Trim", "BobberTop"],
        "colors": {
            "twig": (0.19, 0.17, 0.24),
            "grip": (0.13, 0.12, 0.16),
            "trim": (0.94, 0.52, 0.20),
            "line": (0.35, 0.33, 0.39),
            "top": (0.94, 0.52, 0.20),
            "bottom": (0.16, 0.15, 0.20),
        },
    },
    # Cinderglass - obsidian fused with hot cinder: a hooked flattened blade,
    # glowing magma-orange hardware. Rare.
    "Cinderglass": {
        "radius_butt": 0.23,
        "radius_tip": 0.05,
        "sides": 6,
        "flatten": 0.6,
        "lean": 0.11,
        "kink": 0.05,
        "hook": 0.5,
        "grip_style": "wrapped",
        "grip_radius": 0.3,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [(3.1, 1.4, 0.3, -0.5), (4.3, 4.6, 0.26, -0.55), (5.5, 2.6, 0.2, -0.6)],
        "bands": [(2.3, 0.09), (3.7, 0.08), (5.1, 0.07)],
        "guides": [2.3, 3.7, 5.1, 6.2],
        "guide_style": "collar",
        "tip_ring": True,
        "reel": {"style": "spinning", "part": "Grip", "z": 1.46},
        "pommel": "cap",
        "line": {"length": 2.5, "tilt": 26, "bow": 0.07, "radius": 0.03},
        "float": "quill",
        "neon": ["Trim", "BobberTop"],
        "colors": {
            "twig": (0.19, 0.17, 0.24),
            "grip": (0.13, 0.12, 0.16),
            "trim": (0.96, 0.38, 0.16),
            "line": (0.39, 0.35, 0.39),
            "top": (0.96, 0.38, 0.16),
            "bottom": (0.19, 0.17, 0.24),
        },
    },
    # MagmaCore - a living coal bound into a hooked, backswept-barbed shaft, a
    # spiked drum reel, a lantern float. Epic.
    "MagmaCore": {
        "radius_butt": 0.25,
        "radius_tip": 0.05,
        "sides": 6,
        "flatten": 0.72,
        "lean": 0.1,
        "kink": 0.05,
        "hook": 0.5,
        "grip_style": "wrapped",
        "grip_radius": 0.32,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [(2.6, 1.5, 0.34, -0.55), (3.6, 4.7, 0.3, -0.6), (4.7, 1.9, 0.25, -0.65), (5.7, 4.9, 0.19, -0.7)],
        "bands": [(2.2, 0.1), (3.4, 0.09), (4.6, 0.08), (5.7, 0.07)],
        "guides": [2.4, 3.6, 4.8, 5.9],
        "guide_style": "collar",
        "tip_ring": True,
        "reel": {"style": "spiked", "part": "Grip", "z": 1.5},
        "pommel": "spike",
        "line": {"length": 2.5, "tilt": 27, "bow": 0.07, "radius": 0.032},
        "float": "lantern",
        "neon": ["Trim", "BobberTop"],
        "colors": {
            "twig": (0.24, 0.16, 0.13),
            "grip": (0.15, 0.10, 0.09),
            "trim": (0.96, 0.38, 0.16),
            "line": (0.59, 0.35, 0.31),
            "top": (0.96, 0.38, 0.16),
            "bottom": (0.19, 0.13, 0.11),
        },
    },
    # PhoenixAsh - the capstone: bespoke geometry (build_phoenix_ash, below),
    # this config only carries its shared frame/reel/line/float/colours.
    # Legendary.
    "PhoenixAsh": {
        "radius_butt": 0.24,
        "radius_tip": 0.045,
        "sides": 8,
        "flatten": 0.85,
        "lean": 0.08,
        "kink": 0.04,
        "hook": 0.35,
        "grip_style": "wrapped",
        "grip_radius": 0.33,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [],  # the bespoke builder adds the flame crest + barbs directly
        "bands": [],
        "guides": [],
        "guide_style": "collar",
        "tip_ring": False,
        "reel": {"style": "spiked", "part": "Grip", "z": 1.55},
        "pommel": "spike",
        "line": {"length": 2.6, "tilt": 25, "bow": 0.06, "radius": 0.032},
        "float": "lantern",
        "neon": ["Trim", "BobberTop"],
        "colors": {
            "twig": (0.85, 0.62, 0.42),
            "grip": (0.35, 0.22, 0.16),
            "trim": (1.0, 0.66, 0.38),
            "line": (0.95, 0.82, 0.70),
            "top": (1.0, 0.66, 0.38),
            "bottom": (0.80, 0.35, 0.16),
        },
    },
    # ---------------------------------------------------------- Blackmire Fen
    # Five swamp rods (Rods.luau reedlash_rod .. mireheart_rod). The family
    # reads as reeds, armour and root-wood: whippy segmented canes at the
    # bottom, wisp-lit iron and heartwood at the top.
    #
    # Reedlash - a whippy cured reed: clear segment joints, a big soft bow,
    # nothing metallic. Uncommon.
    "Reedlash": {
        "radius_butt": 0.16,
        "radius_tip": 0.045,
        "sides": 7,
        "flatten": 1.0,
        "lean": 0.26,
        "kink": 0.03,
        "hook": 0.0,
        "grip_style": "wrapped",
        "grip_radius": 0.26,
        "nodes": 6,
        "node_amp": 0.06,
        "cones": [],
        "bands": [(2.4, 0.11), (3.9, 0.1), (5.4, 0.09)],
        "guides": [2.9, 4.4, 5.8],
        "guide_style": "loop",
        "tip_ring": False,
        "reel": None,
        "pommel": None,
        "line": {"length": 2.7, "tilt": 22, "bow": 0.16, "radius": 0.026},
        "float": "quill",
        "colors": {
            "twig": (0.58, 0.557, 0.353),
            "grip": (0.376, 0.345, 0.227),
            "trim": (0.643, 0.384, 0.243),
            "line": (0.839, 0.824, 0.745),
            "top": (0.643, 0.384, 0.243),
            "bottom": (0.886, 0.847, 0.729),
        },
    },
    # Gatorback - a stout blank armoured in scute: straight-out studs up the
    # shaft, heavy armour bands, a proper reel. Rare.
    "Gatorback": {
        "radius_butt": 0.25,
        "radius_tip": 0.06,
        "sides": 7,
        "flatten": 0.94,
        "lean": 0.09,
        "kink": 0.03,
        "hook": 0.08,
        "grip_style": "wrapped",
        "grip_radius": 0.34,
        "nodes": 0,
        "node_amp": 0.0,
        # scute studs: stubby, straight out, ridged down the back
        "cones": [(2.1, 0.9, 0.18, 0.1), (2.9, 4.0, 0.17, 0.1), (3.7, 1.6, 0.16, 0.1), (4.5, 4.8, 0.14, 0.1), (5.2, 2.4, 0.13, 0.1)],
        "bands": [(1.95, 0.17), (3.2, 0.14), (4.4, 0.12), (5.5, 0.1)],
        "guides": [2.5, 3.7, 4.9, 6.0],
        "guide_style": "loop",
        "tip_ring": True,
        "reel": {"style": "spinning", "part": "Trim", "z": 1.46},
        "pommel": "cap",
        "line": {"length": 2.7, "tilt": 22, "bow": 0.13, "radius": 0.03},
        "float": "round",
        "colors": {
            "twig": (0.369, 0.455, 0.282),
            "grip": (0.227, 0.275, 0.188),
            "trim": (0.851, 0.816, 0.702),  # tooth-bone: _Trim is the jaw's teeth
            "line": (0.808, 0.824, 0.769),
            "top": (0.369, 0.455, 0.282),
            "bottom": (0.886, 0.871, 0.784),
        },
    },
    # Wisplight - a dark slim rod that exists to carry its light: glowing
    # collars up a bog-black blank to a caged wisp lantern. Rare.
    "Wisplight": {
        "radius_butt": 0.17,
        "radius_tip": 0.04,
        "sides": 6,
        "flatten": 1.0,
        "lean": 0.14,
        "kink": 0.03,
        "hook": 0.35,
        "grip_style": "wrapped",
        "grip_radius": 0.28,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [],
        "bands": [(2.2, 0.09), (3.3, 0.08), (4.4, 0.07), (5.5, 0.06)],
        "guides": [2.2, 3.3, 4.4, 5.5],
        "guide_style": "collar",
        "tip_ring": True,
        "reel": {"style": "spinning", "part": "Trim", "z": 1.46},
        "pommel": "cap",
        "line": {"length": 2.6, "tilt": 26, "bow": 0.09, "radius": 0.028},
        "float": "lantern",
        "neon": ["Trim", "BobberTop"],
        "colors": {
            "twig": (0.29, 0.267, 0.212),
            "grip": (0.204, 0.188, 0.157),
            "trim": (0.588, 0.922, 0.784),
            "line": (0.776, 0.886, 0.831),
            "top": (0.588, 0.922, 0.784),
            "bottom": (0.376, 0.588, 0.502),
        },
    },
    # Fenpiercer - a flattened bog-iron lance: dead straight, angular,
    # backswept barbs, venom-green fittings. Epic.
    "Fenpiercer": {
        "radius_butt": 0.24,
        "radius_tip": 0.05,
        "sides": 5,
        "flatten": 0.6,
        "lean": 0.03,
        "kink": 0.01,
        "hook": 0.18,
        "grip_style": "wrapped",
        "grip_radius": 0.31,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [(3.1, 1.4, 0.3, -0.7), (4.2, 4.6, 0.26, -0.75), (5.2, 2.2, 0.22, -0.8)],
        "bands": [(2.3, 0.09), (3.5, 0.08), (4.7, 0.07), (5.8, 0.06)],
        "guides": [2.3, 3.5, 4.7, 5.8],
        "guide_style": "collar",
        "tip_ring": True,
        "reel": {"style": "spiked", "part": "Grip", "z": 1.5},
        "pommel": "spike",
        "line": {"length": 2.5, "tilt": 27, "bow": 0.06, "radius": 0.03},
        "float": "quill",
        # the choke-wrap cord is cord, not light - only the float glows
        "neon": ["BobberTop"],
        "colors": {
            "twig": (0.431, 0.29, 0.204),
            "grip": (0.251, 0.196, 0.165),
            "trim": (0.478, 0.404, 0.243),
            "line": (0.839, 0.871, 0.729),
            "top": (0.698, 0.824, 0.353),
            "bottom": (0.471, 0.549, 0.275),
        },
    },
    # Mireheart - the fen's capstone: a heavy living root, grown crooked,
    # sprouting root-twigs, every fitting lit with the heart's wisp-glow.
    # Legendary.
    "Mireheart": {
        "radius_butt": 0.27,
        "radius_tip": 0.055,
        "sides": 6,
        "flatten": 0.85,
        "lean": 0.16,
        "kink": 0.08,
        "hook": 0.5,
        "grip_style": "wrapped",
        "grip_radius": 0.35,
        "nodes": 3,
        "node_amp": 0.07,
        # grown root-twigs, curling toward the tip like new growth
        "cones": [(2.4, 1.1, 0.34, 0.45), (3.3, 4.3, 0.3, 0.45), (4.2, 2.0, 0.26, 0.5), (5.1, 5.2, 0.22, 0.5), (5.8, 3.0, 0.18, 0.55)],
        "bands": [(2.1, 0.11), (3.3, 0.1), (4.5, 0.09), (5.6, 0.08)],
        "guides": [2.5, 3.7, 4.9, 5.9],
        "guide_style": "collar",
        "tip_ring": True,
        "reel": {"style": "spiked", "part": "Grip", "z": 1.55},
        "pommel": "spike",
        "line": {"length": 2.6, "tilt": 26, "bow": 0.08, "radius": 0.032},
        "float": "lantern",
        "neon": ["Trim", "BobberTop"],
        "colors": {
            "twig": (0.227, 0.259, 0.18),
            "grip": (0.173, 0.188, 0.141),
            # bog-amber: the crown's heart, its collars and its lantern all
            # burn the same colour, which is the fen's only warm light
            "trim": (0.98, 0.749, 0.302),
            "line": (0.886, 0.855, 0.769),
            "top": (0.98, 0.749, 0.302),
            "bottom": (0.227, 0.259, 0.18),
        },
    },
    # ---------------------------------------------------------- Frostmaw Reach
    # Five ice rods (auger_rod .. frostheart_rod): pale, angular, frost-crusted.
    #
    # Auger - the ice-hole driller: a squared, dead-straight shaft with a
    # spiral of cutting studs, more tool than tackle. Uncommon.
    "Auger": {
        "radius_butt": 0.2,
        "radius_tip": 0.06,
        "sides": 4,
        "flatten": 1.0,
        "lean": 0.02,
        "kink": 0.0,
        "hook": 0.0,
        "grip_style": "wrapped",
        "grip_radius": 0.29,
        "nodes": 0,
        "node_amp": 0.0,
        # the drill spiral: short cutters stepping around and up the shaft
        "cones": [(2.2, 0.0, 0.16, 0.3), (2.8, 1.6, 0.15, 0.3), (3.4, 3.2, 0.14, 0.3), (4.0, 4.8, 0.13, 0.3), (4.6, 0.8, 0.12, 0.3), (5.2, 2.4, 0.11, 0.3)],
        "bands": [(2.0, 0.12), (4.9, 0.09)],
        "guides": [2.6, 4.2, 5.7],
        "guide_style": "loop",
        "tip_ring": True,
        "reel": None,
        "pommel": "cap",
        "line": {"length": 2.6, "tilt": 22, "bow": 0.12, "radius": 0.026},
        "float": "quill",
        "neon": ["BobberTop"],  # cold steel flighting, a lit float
        "colors": {
            "twig": (0.588, 0.667, 0.729),
            "grip": (0.353, 0.408, 0.471),
            "trim": (0.824, 0.894, 0.941),
            "line": (0.863, 0.91, 0.941),
            "top": (0.471, 0.745, 1.0),
            "bottom": (0.925, 0.957, 0.98),
        },
    },
    # Rimebound - frost-crusted driftwood: icicles hanging off the underside,
    # frozen rings, a glow of rime. Rare.
    "Rimebound": {
        "radius_butt": 0.22,
        "radius_tip": 0.055,
        "sides": 7,
        "flatten": 0.95,
        "lean": 0.12,
        "kink": 0.05,
        "hook": 0.1,
        "grip_style": "wrapped",
        "grip_radius": 0.32,
        "nodes": 4,
        "node_amp": 0.04,
        # icicles: thin straight spikes, canted back toward the butt so they
        # read as hanging when the rod is pitched up in the hold
        "cones": [(2.4, 1.2, 0.26, -0.85), (3.2, 4.4, 0.24, -0.85), (4.0, 1.8, 0.22, -0.9), (4.8, 5.0, 0.19, -0.9), (5.5, 2.6, 0.16, -0.9)],
        "bands": [(2.1, 0.13), (3.6, 0.11), (5.0, 0.09)],
        "guides": [2.7, 4.1, 5.5],
        "guide_style": "loop",
        "tip_ring": True,
        "reel": {"style": "spinning", "part": "Trim", "z": 1.46},
        "pommel": "cap",
        "line": {"length": 2.7, "tilt": 23, "bow": 0.11, "radius": 0.028},
        "float": "round",
        "neon": ["Trim", "BobberTop"],
        "colors": {
            "twig": (0.698, 0.816, 0.886),
            "grip": (0.471, 0.549, 0.627),
            "trim": (0.941, 0.98, 1.0),
            "line": (0.824, 0.902, 0.957),
            "top": (0.941, 0.98, 1.0),
            "bottom": (0.471, 0.627, 0.784),
        },
    },
    # Silverscale - the reach's clean one: a sleek fast-tapered silver blank,
    # cork grip, a proper reel and a run of guides. Rare.
    "Silverscale": {
        "radius_butt": 0.15,
        "radius_tip": 0.03,
        "sides": 8,
        "flatten": 1.0,
        "lean": 0.11,
        "kink": 0.0,
        "hook": 0.0,
        "grip_style": "cork",
        "grip_radius": 0.27,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [],
        "bands": [(1.3, 0.12), (1.62, 0.12), (2.05, 0.08)],
        "guides": [2.5, 3.4, 4.3, 5.1, 5.9, 6.5],
        "guide_style": "loop",
        "tip_ring": True,
        "reel": {"style": "spinning", "part": "Trim", "z": 1.46},
        "pommel": "cap",
        "line": {"length": 2.9, "tilt": 18, "bow": 0.1, "radius": 0.022},
        "float": "pear",
        "neon": ["BobberTop"],  # the scales stay metal; only the float lights
        "colors": {
            "twig": (0.784, 0.831, 0.878),
            "grip": (0.549, 0.588, 0.643),
            "trim": (0.902, 0.941, 0.98),
            "line": (0.878, 0.918, 0.957),
            "top": (0.769, 0.863, 0.957),
            "bottom": (1.0, 1.0, 1.0),
        },
    },
    # Aurora - a long smooth sweep of a rod, glowing collars shading along it
    # like the lights it's named for, a lantern for a float. Epic.
    "Aurora": {
        "radius_butt": 0.18,
        "radius_tip": 0.035,
        "sides": 8,
        "flatten": 1.0,
        "lean": 0.22,
        "kink": 0.0,
        "hook": 0.15,
        "grip_style": "cork",
        "grip_radius": 0.28,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [],
        "bands": [(2.0, 0.09), (2.9, 0.085), (3.8, 0.08), (4.7, 0.07), (5.6, 0.06), (6.3, 0.05)],
        "guides": [2.4, 3.4, 4.4, 5.4, 6.2],
        "guide_style": "collar",
        "tip_ring": True,
        "reel": {"style": "spinning", "part": "Trim", "z": 1.46},
        "pommel": "cap",
        "line": {"length": 2.8, "tilt": 20, "bow": 0.09, "radius": 0.024},
        "float": "lantern",
        "neon": ["Trim", "BobberTop"],
        "colors": {
            "twig": (0.376, 0.549, 0.745),
            "grip": (0.235, 0.314, 0.431),
            "trim": (0.588, 0.902, 0.784),
            "line": (0.745, 0.941, 0.863),
            "top": (0.902, 0.588, 0.902),
            "bottom": (0.588, 0.902, 0.784),
        },
    },
    # Frostheart - the reach's capstone: a flattened blade of ancient ice,
    # hooked at the tip, backswept shard-barbs, everice-blue glow. Legendary.
    "Frostheart": {
        "radius_butt": 0.26,
        "radius_tip": 0.05,
        "sides": 6,
        "flatten": 0.62,
        "lean": 0.1,
        "kink": 0.05,
        "hook": 0.55,
        "grip_style": "wrapped",
        "grip_radius": 0.34,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [(2.8, 1.3, 0.42, -0.7), (3.7, 4.5, 0.37, -0.72), (4.6, 2.4, 0.31, -0.76), (5.4, 0.2, 0.25, -0.8), (6.0, 3.3, 0.2, -0.85)],
        "bands": [(2.3, 0.1), (3.4, 0.09), (4.5, 0.08), (5.5, 0.07)],
        "guides": [2.3, 3.4, 4.5, 5.5],
        "guide_style": "collar",
        "tip_ring": True,
        "reel": {"style": "spiked", "part": "Grip", "z": 1.5},
        "pommel": "spike",
        "line": {"length": 2.5, "tilt": 28, "bow": 0.06, "radius": 0.032},
        "float": "lantern",
        "neon": ["Trim", "BobberTop"],
        "colors": {
            "twig": (0.549, 0.706, 0.824),
            "grip": (0.314, 0.392, 0.494),
            "trim": (0.314, 0.863, 1.0),
            "line": (0.784, 0.941, 1.0),
            "top": (0.314, 0.863, 1.0),
            "bottom": (0.925, 0.965, 0.988),
        },
    },
    # ---------------------------------------------------------- Gloomtrench
    # Five abyss rods (lanternline_rod .. gloomheart_rod): near-black blanks
    # that exist to carry their own light down into the dark.
    #
    # Lanternline - the light-bearer: a plain dark cane built around one
    # bright caged lantern. Uncommon.
    "Lanternline": {
        "radius_butt": 0.18,
        "radius_tip": 0.05,
        "sides": 6,
        "flatten": 1.0,
        "lean": 0.13,
        "kink": 0.03,
        "hook": 0.2,
        "grip_style": "wrapped",
        "grip_radius": 0.29,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [],
        "bands": [(2.3, 0.12), (4.0, 0.1), (5.6, 0.08)],
        "guides": [2.8, 4.4, 5.9],
        "guide_style": "loop",
        "tip_ring": True,
        "reel": None,
        "pommel": "cap",
        "line": {"length": 2.6, "tilt": 24, "bow": 0.11, "radius": 0.028},
        "float": "lantern",
        "neon": ["Trim", "BobberTop"],
        "colors": {
            "twig": (0.314, 0.29, 0.376),
            "grip": (0.22, 0.196, 0.267),
            "trim": (1.0, 0.886, 0.51),
            "line": (0.588, 0.549, 0.667),
            "top": (1.0, 0.886, 0.51),
            "bottom": (0.275, 0.243, 0.337),
        },
    },
    # Trenchglass - drawn from pressure-glass: a slim translucent-looking
    # blank with glowing collars, sharp and clean. Rare.
    "Trenchglass": {
        "radius_butt": 0.16,
        "radius_tip": 0.035,
        "sides": 6,
        "flatten": 0.85,
        "lean": 0.08,
        "kink": 0.02,
        "hook": 0.12,
        "grip_style": "wrapped",
        "grip_radius": 0.27,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [],
        "bands": [(2.1, 0.08), (3.2, 0.075), (4.3, 0.07), (5.4, 0.06), (6.2, 0.05)],
        "guides": [2.1, 3.2, 4.3, 5.4, 6.2],
        "guide_style": "collar",
        "tip_ring": True,
        "reel": {"style": "spinning", "part": "Grip", "z": 1.45},  # dark metal, so only the collars + prism tip glow
        "pommel": "cap",
        "line": {"length": 2.7, "tilt": 22, "bow": 0.08, "radius": 0.024},
        "float": "quill",
        "neon": ["Trim", "BobberTop"],
        "colors": {
            "twig": (0.275, 0.329, 0.431),
            "grip": (0.188, 0.22, 0.298),
            "trim": (0.549, 0.863, 1.0),
            "line": (0.471, 0.588, 0.745),
            "top": (0.549, 0.863, 1.0),
            "bottom": (0.204, 0.235, 0.329),
        },
    },
    # Inkveil - wound in vampire-squid ink: a dark violet blank with curled
    # tentacle-barbs down its length. Rare.
    "Inkveil": {
        "radius_butt": 0.2,
        "radius_tip": 0.045,
        "sides": 7,
        "flatten": 0.8,
        "lean": 0.15,
        "kink": 0.05,
        "hook": 0.3,
        "grip_style": "wrapped",
        "grip_radius": 0.3,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [(2.7, 1.5, 0.28, -0.6), (3.7, 4.7, 0.25, -0.65), (4.7, 2.5, 0.21, -0.7), (5.6, 0.5, 0.17, -0.75)],
        "bands": [(2.2, 0.09), (3.4, 0.08), (4.6, 0.07), (5.7, 0.06)],
        "guides": [2.6, 3.8, 5.0, 6.0],
        "guide_style": "collar",
        "tip_ring": True,
        "reel": {"style": "spiked", "part": "Grip", "z": 1.5},
        "pommel": "cap",
        "line": {"length": 2.5, "tilt": 25, "bow": 0.07, "radius": 0.028},
        "float": "pear",
        "neon": ["Trim", "BobberTop"],
        "colors": {
            "twig": (0.22, 0.188, 0.282),
            "grip": (0.157, 0.133, 0.204),
            "trim": (0.667, 0.471, 1.0),
            "line": (0.431, 0.353, 0.588),
            "top": (0.667, 0.471, 1.0),
            "bottom": (0.173, 0.149, 0.227),
        },
    },
    # Voidline - the trench's whip: near-black, dead taut, violet arc-collars,
    # a spiked drum. Epic.
    "Voidline": {
        "radius_butt": 0.21,
        "radius_tip": 0.032,
        "sides": 6,
        "flatten": 0.9,
        "lean": 0.04,
        "kink": 0.015,
        "hook": 0.25,
        "grip_style": "wrapped",
        "grip_radius": 0.3,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [(3.0, 0.7, 0.18, 0.55), (4.2, 3.5, 0.16, 0.55), (5.3, 0.7, 0.14, 0.6)],
        "bands": [(2.0, 0.085), (3.1, 0.08), (4.2, 0.07), (5.3, 0.06), (6.1, 0.05)],
        "guides": [2.4, 3.5, 4.6, 5.7],
        "guide_style": "collar",
        "tip_ring": True,
        "reel": {"style": "spiked", "part": "Grip", "z": 1.5},
        "pommel": "spike",
        "line": {"length": 2.5, "tilt": 25, "bow": 0.05, "radius": 0.03},
        "float": "quill",
        "neon": ["Trim", "BobberTop"],
        "colors": {
            "twig": (0.157, 0.141, 0.22),
            "grip": (0.118, 0.102, 0.165),
            "trim": (0.667, 0.471, 1.0),
            "line": (0.353, 0.275, 0.51),
            "top": (0.471, 0.314, 0.863),
            "bottom": (0.141, 0.125, 0.196),
        },
    },
    # Gloomheart - the trench's capstone: a heavy dark relic hooked like an
    # angler's lure-stalk, barbed, its lantern burning the Trench Mother's
    # gold. Legendary.
    "Gloomheart": {
        "radius_butt": 0.27,
        "radius_tip": 0.052,
        "sides": 6,
        "flatten": 0.7,
        "lean": 0.11,
        "kink": 0.06,
        "hook": 0.62,
        "grip_style": "wrapped",
        "grip_radius": 0.35,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [(2.5, 1.7, 0.44, -0.65), (3.4, 4.9, 0.38, -0.7), (4.3, 1.7, 0.32, -0.75), (5.2, 4.9, 0.25, -0.8), (5.9, 1.7, 0.2, -0.85)],
        "bands": [(2.1, 0.11), (3.2, 0.1), (4.3, 0.09), (5.4, 0.075)],
        "guides": [2.3, 3.4, 4.5, 5.6],
        "guide_style": "collar",
        "tip_ring": True,
        "reel": {"style": "spiked", "part": "Grip", "z": 1.55},
        "pommel": "spike",
        "line": {"length": 2.6, "tilt": 27, "bow": 0.06, "radius": 0.034},
        "float": "lantern",
        "neon": ["Trim", "BobberTop"],
        "colors": {
            "twig": (0.227, 0.196, 0.306),
            "grip": (0.157, 0.133, 0.212),
            "trim": (1.0, 0.886, 0.51),
            "line": (0.784, 0.706, 0.941),
            "top": (1.0, 0.886, 0.51),
            "bottom": (0.173, 0.149, 0.227),
        },
    },
    # ---------------------------------------------------------- Wreckwater
    # Five ghost-fleet rods (ghostplank_rod .. wraithheart_rod): salvage
    # timber, rigging and drowned gold, shading spectral at the top.
    #
    # Ghostplank - hewn from a wreck's hull plank: squared, warped, iron
    # straps and nail-stubs. Uncommon.
    "Ghostplank": {
        # wide and thin: a board on edge, not a stick
        "radius_butt": 0.32,
        "radius_tip": 0.13,
        "sides": 4,
        "flatten": 0.4,
        "lean": 0.09,
        "kink": 0.07,
        "hook": 0.0,
        "grip_style": "wrapped",
        "grip_radius": 0.3,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [],  # bespoke: the split-out slivers are grown in build_ghostplank
        "bands": [(2.25, 0.16), (3.9, 0.14), (5.35, 0.12)],  # iron straps
        "guides": [2.7, 4.2, 5.6],  # bent nails, not wire loops
        "guide_style": "loop",
        "tip_ring": False,
        "reel": None,
        "pommel": "cap",
        "line": {"length": 2.6, "tilt": 23, "bow": 0.13, "radius": 0.028},
        "float": "round",
        "neon": ["BobberTop"],
        "colors": {
            "twig": (0.478, 0.51, 0.451),  # sea-bleached hull timber
            "grip": (0.294, 0.31, 0.278),  # tarred rope
            "trim": (0.6, 0.631, 0.639),  # rusted iron straps + nails
            "line": (0.706, 0.769, 0.729),
            "top": (0.627, 1.0, 0.824),
            "bottom": (0.353, 0.392, 0.365),
        },
    },
    # Riggingline - a salvaged topmast section: straight, served in rope
    # wraps at regular intervals the way a mast is, a proper reel. Rare.
    "Riggingline": {
        "radius_butt": 0.19,
        "radius_tip": 0.05,
        "sides": 7,
        "flatten": 1.0,
        "lean": 0.05,
        "kink": 0.01,
        "hook": 0.0,
        "grip_style": "wrapped",
        "grip_radius": 0.29,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [],
        # rope servings at regular intervals, the way a mast is served
        "bands": [(2.05, 0.13), (4.05, 0.11), (5.55, 0.09)],
        "guides": [2.55, 4.0, 5.35],  # ratline-style double pairs
        "guide_style": "loop",
        "tip_ring": True,
        "reel": {"style": "spinning", "part": "Trim", "z": 1.46},
        "pommel": "cap",
        "line": {"length": 2.8, "tilt": 21, "bow": 0.12, "radius": 0.026},
        "float": "quill",
        "neon": ["BobberTop"],
        "colors": {
            "twig": (0.451, 0.475, 0.42),  # weathered spar
            "grip": (0.267, 0.286, 0.251),  # tarred grip
            "trim": (0.769, 0.667, 0.451),  # hemp rope, brass block
            "line": (0.627, 0.588, 0.494),
            "top": (0.863, 0.98, 0.925),
            "bottom": (0.318, 0.353, 0.322),
        },
    },
    # Doubloon - drowned gold: a dark blank studded with coin-bosses, gilded
    # bands, a gold-lit pear float. Rare.
    "Doubloon": {
        "radius_butt": 0.2,
        "radius_tip": 0.05,
        "sides": 7,
        "flatten": 0.95,
        "lean": 0.12,
        "kink": 0.03,
        "hook": 0.1,
        "grip_style": "wrapped",
        "grip_radius": 0.31,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [],  # bespoke: the coin bosses are struck discs, not stubs
        "bands": [(2.0, 0.12), (3.4, 0.1), (4.8, 0.09)],
        "guides": [2.6, 3.9, 5.2, 6.1],
        "guide_style": "loop",
        "tip_ring": True,
        "reel": {"style": "spinning", "part": "Trim", "z": 1.46},
        "pommel": "cap",
        "line": {"length": 2.7, "tilt": 22, "bow": 0.11, "radius": 0.028},
        "float": "pear",
        "neon": ["BobberTop"],  # the gold stays metal; only the float lights
        "colors": {
            "twig": (0.263, 0.224, 0.184),  # drowned oak, near-black
            "grip": (0.176, 0.149, 0.125),
            "trim": (0.937, 0.769, 0.353),  # struck gold: coins, chain, drum
            "line": (0.784, 0.706, 0.549),
            "top": (1.0, 0.855, 0.42),  # gold-lit float
            "bottom": (0.31, 0.251, 0.169),
        },
    },
    # Sailcloth - a long graceful sweep rigged like a sail's luff: pale
    # spectral canvas colours, a soft bow. Epic.
    "Sailcloth": {
        "radius_butt": 0.17,
        "radius_tip": 0.035,
        "sides": 8,
        "flatten": 0.95,
        "lean": 0.24,
        "kink": 0.0,
        "hook": 0.1,
        "grip_style": "cork",
        "grip_radius": 0.27,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [],
        "bands": [(2.35, 0.09), (3.95, 0.08), (5.25, 0.07), (6.3, 0.06)],  # clear of the sails
        "guides": [2.6, 3.8, 5.0, 6.1],
        "guide_style": "loop",
        "tip_ring": True,
        "reel": {"style": "spinning", "part": "Trim", "z": 1.46},
        "pommel": "cap",
        "line": {"length": 2.9, "tilt": 19, "bow": 0.1, "radius": 0.024},
        "float": "pear",
        "neon": ["Trim", "BobberTop"],
        "colors": {
            "twig": (0.612, 0.667, 0.612),  # pale spar
            "grip": (0.38, 0.427, 0.396),
            "trim": (0.878, 0.988, 0.937),  # ghost canvas: sails, cleat, halyard
            "line": (0.784, 0.863, 0.824),
            "top": (0.627, 1.0, 0.824),
            "bottom": (0.451, 0.502, 0.467),
        },
    },
    # Wraithheart - the fleet's capstone: a spectral flattened blade hooked
    # like a boarding-axe haft, wisped with drowned-green fire. Legendary.
    "Wraithheart": {
        "radius_butt": 0.26,
        "radius_tip": 0.05,
        "sides": 6,
        "flatten": 0.66,
        "lean": 0.1,
        "kink": 0.05,
        "hook": 0.28,  # a mast, not an axe haft: the drama is the caged heart
        "grip_style": "wrapped",
        "grip_radius": 0.34,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [],  # bespoke: the ghost-fire wisps replace the barbs
        "bands": [],  # bespoke: glowing collars are placed by the builder
        "guides": [],  # bespoke: the wisp collars double as guides
        "guide_style": "collar",
        "tip_ring": False,  # the heart cage sits where the tip ring would
        "reel": {"style": "spiked", "part": "Grip", "z": 1.55},  # bespoke: a ship's wheel
        "pommel": "spike",  # bespoke: a figurehead
        "line": {"length": 2.6, "tilt": 26, "bow": 0.06, "radius": 0.032},
        "float": "lantern",
        "neon": ["Trim", "BobberTop"],
        "colors": {
            "twig": (0.212, 0.259, 0.251),  # black spectral timber
            "grip": (0.145, 0.184, 0.176),  # iron wheel + figurehead
            "trim": (0.549, 1.0, 0.804),  # ghost fire: heart, cage, wisps
            "line": (0.745, 0.902, 0.824),
            "top": (0.627, 1.0, 0.824),
            "bottom": (0.216, 0.278, 0.267),
        },
    },
    # ---------------------------------------------------------- The Maelstrom
    # The finale's five (squallcaster_rod .. krakenheart_rod): the storm
    # family - wind-whipped slate, lightning, the hurricane's wall, and the
    # Kraken's own violet at the very top.
    #
    # Squallcaster - a storm-bent cane, whipped into a permanent lean.
    # Uncommon.
    "Squallcaster": {
        "radius_butt": 0.17,
        "radius_tip": 0.045,
        "sides": 7,
        "flatten": 1.0,
        "lean": 0.24,
        "kink": 0.05,
        "hook": 0.0,
        "grip_style": "wrapped",
        "grip_radius": 0.28,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [],
        "bands": [(2.3, 0.11), (3.8, 0.1), (5.3, 0.08)],
        "guides": [2.8, 4.3, 5.7],
        "guide_style": "loop",
        "tip_ring": True,
        "reel": None,
        "pommel": "cap",
        "line": {"length": 2.7, "tilt": 23, "bow": 0.15, "radius": 0.026},
        "float": "quill",
        "colors": {
            "twig": (0.431, 0.486, 0.549),
            "grip": (0.298, 0.337, 0.392),
            "trim": (0.745, 0.824, 0.902),
            "line": (0.784, 0.839, 0.894),
            "top": (0.549, 0.745, 0.902),
            "bottom": (0.353, 0.4, 0.463),
        },
    },
    # Riptide - current-swept and smooth, glowing tide-blue collars. Rare.
    "Riptide": {
        "radius_butt": 0.18,
        "radius_tip": 0.04,
        "sides": 8,
        "flatten": 0.9,
        "lean": 0.18,
        "kink": 0.0,
        "hook": 0.12,
        "grip_style": "cork",
        "grip_radius": 0.28,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [],
        "bands": [(2.1, 0.09), (3.2, 0.08), (4.3, 0.075), (5.4, 0.065), (6.2, 0.055)],
        "guides": [2.5, 3.6, 4.7, 5.8],
        "guide_style": "collar",
        "tip_ring": True,
        "reel": {"style": "spinning", "part": "Trim", "z": 1.46},
        "pommel": "cap",
        "line": {"length": 2.8, "tilt": 20, "bow": 0.09, "radius": 0.024},
        "float": "pear",
        "neon": ["Trim", "BobberTop"],
        "colors": {
            "twig": (0.314, 0.431, 0.549),
            "grip": (0.22, 0.298, 0.384),
            "trim": (0.549, 0.784, 1.0),
            "line": (0.667, 0.784, 0.902),
            "top": (0.549, 0.784, 1.0),
            "bottom": (0.235, 0.322, 0.416),
        },
    },
    # Thunderhead - a charged mast of a rod: dead straight, forked with
    # little lightning-spur cones, white-hot fittings. Rare.
    "Thunderhead": {
        "radius_butt": 0.2,
        "radius_tip": 0.038,
        "sides": 6,
        "flatten": 1.0,
        "lean": 0.05,
        "kink": 0.02,
        "hook": 0.1,
        "grip_style": "wrapped",
        "grip_radius": 0.29,
        "nodes": 0,
        "node_amp": 0.0,
        # lightning spurs: thin forks jumping forward off the blank
        "cones": [(2.8, 0.9, 0.22, 0.65), (3.8, 3.7, 0.2, 0.65), (4.8, 1.5, 0.18, 0.7), (5.7, 4.3, 0.15, 0.7)],
        "bands": [(2.0, 0.085), (3.1, 0.08), (4.2, 0.07), (5.3, 0.06), (6.1, 0.05)],
        "guides": [2.4, 3.5, 4.6, 5.7],
        "guide_style": "collar",
        "tip_ring": True,
        "reel": {"style": "spinning", "part": "Trim", "z": 1.45},
        "pommel": "cap",
        "line": {"length": 2.6, "tilt": 24, "bow": 0.07, "radius": 0.026},
        "float": "quill",
        "neon": ["Trim", "BobberTop"],
        "colors": {
            "twig": (0.275, 0.314, 0.392),
            # _Grip carries the anvil cloud, so it is cloud-grey, not handle-dark
            "grip": (0.612, 0.651, 0.729),
            "trim": (0.863, 0.902, 1.0),
            "line": (0.745, 0.784, 0.886),
            "top": (0.863, 0.902, 1.0),
            "bottom": (0.22, 0.251, 0.329),
        },
    },
    # Eyewall - the hurricane's wall: a heavy blank wound in a rising spiral
    # of storm-vanes, deep hurricane blue. Epic.
    "Eyewall": {
        "radius_butt": 0.24,
        "radius_tip": 0.05,
        "sides": 7,
        "flatten": 0.9,
        "lean": 0.1,
        "kink": 0.04,
        "hook": 0.2,
        "grip_style": "wrapped",
        "grip_radius": 0.32,
        "nodes": 0,
        "node_amp": 0.0,
        # the rotation: vanes stepping around and up the shaft
        "cones": [(2.2, 0.0, 0.2, 0.35), (2.9, 1.8, 0.19, 0.35), (3.6, 3.6, 0.18, 0.35), (4.3, 5.4, 0.17, 0.4), (5.0, 1.0, 0.15, 0.4), (5.7, 2.8, 0.13, 0.4)],
        "bands": [(2.0, 0.1), (3.4, 0.09), (4.8, 0.08), (5.9, 0.07)],
        "guides": [2.5, 3.8, 5.1, 6.0],
        "guide_style": "collar",
        "tip_ring": True,
        "reel": {"style": "spiked", "part": "Grip", "z": 1.5},
        "pommel": "spike",
        "line": {"length": 2.6, "tilt": 25, "bow": 0.07, "radius": 0.03},
        "float": "round",
        "neon": ["Trim", "BobberTop"],
        "colors": {
            "twig": (0.353, 0.431, 0.588),
            "grip": (0.243, 0.298, 0.408),
            "trim": (0.353, 0.51, 1.0),
            "line": (0.667, 0.745, 0.941),
            "top": (0.353, 0.51, 1.0),
            "bottom": (0.259, 0.314, 0.439),
        },
    },
    # Krakenheart - the best rod in the game: a heavy violet relic curling
    # into a full tentacle hook, sucker-stubbed down its length, barbed at
    # the top, its lantern burning the Kraken's own light. Legendary.
    "Krakenheart": {
        "radius_butt": 0.28,
        "radius_tip": 0.055,
        "sides": 7,
        "flatten": 0.7,
        "lean": 0.12,
        "kink": 0.06,
        "hook": 0.75,
        "grip_style": "wrapped",
        "grip_radius": 0.36,
        "nodes": 0,
        "node_amp": 0.0,
        # sucker stubs low, swept barbs high - a tentacle turned tackle
        "cones": [(2.2, 0.7, 0.1, 0.0), (2.8, 2.8, 0.1, 0.0), (3.4, 4.9, 0.09, 0.0), (4.1, 1.5, 0.32, -0.7), (5.0, 4.6, 0.27, -0.75), (5.8, 2.2, 0.21, -0.8)],
        "bands": [(2.0, 0.11), (3.2, 0.1), (4.4, 0.09), (5.5, 0.08)],
        "guides": [2.4, 3.6, 4.8, 5.8],
        "guide_style": "collar",
        "tip_ring": True,
        "reel": {"style": "spiked", "part": "Grip", "z": 1.55},
        "pommel": "spike",
        "line": {"length": 2.6, "tilt": 27, "bow": 0.06, "radius": 0.034},
        "float": "lantern",
        "neon": ["Trim", "BobberTop"],
        "colors": {
            "twig": (0.235, 0.173, 0.329),
            "grip": (0.173, 0.133, 0.235),
            "trim": (0.588, 0.471, 1.0),
            "line": (0.784, 0.745, 0.941),
            "top": (0.588, 0.471, 1.0),
            "bottom": (0.204, 0.157, 0.282),
        },
    },
}

# Float profiles: revolved around the float's axis, (radius, z) with z
# relative to the float's waterline (z = 0, where the two colours meet).
# "top" runs upward from the waterline, "bottom" downward. Any extra
# geometry (the lantern's cage) is added by the builder.
FLOATS = {
    "round": {
        "top": [(0.24, 0.0), (0.208, 0.12), (0.12, 0.208), (0.035, 0.235), (0.035, 0.46), (0.0, 0.46)],
        "bottom": [(0.0, -0.54), (0.035, -0.54), (0.035, -0.235), (0.12, -0.208), (0.208, -0.12), (0.24, 0.0)],
    },
    "quill": {
        "top": [(0.09, 0.0), (0.075, 0.22), (0.045, 0.5), (0.02, 0.72), (0.0, 0.8)],
        "bottom": [(0.0, -0.6), (0.03, -0.5), (0.07, -0.22), (0.09, 0.0)],
    },
    "pear": {
        "top": [(0.22, 0.0), (0.19, 0.12), (0.12, 0.24), (0.05, 0.33), (0.03, 0.36), (0.03, 0.66), (0.0, 0.68)],
        "bottom": [(0.0, -0.26), (0.12, -0.22), (0.2, -0.11), (0.22, 0.0)],
    },
    "lantern": {
        "top": [(0.25, 0.0), (0.22, 0.12), (0.14, 0.21), (0.04, 0.25), (0.04, 0.42), (0.0, 0.44)],
        "bottom": [(0.0, -0.16), (0.2, -0.12), (0.28, -0.03), (0.28, 0.0)],
    },
}


# ---------------------------------------------------------------- shape maths


def spine(z, cfg):
    """Centreline (x, y) offset at height z. Scaled per variant so a bamboo
    cane is near-straight, a twig leans, and the abyssal hooks forward."""
    t = max(z, 0.0) / ROD_LENGTH
    lean = cfg["lean"] * t * t
    kink = cfg["kink"] * math.sin(t * math.tau * 1.7 + 0.4) * t
    y = 0.05 * cfg["kink"] / 0.06 * math.sin(t * math.tau * 1.1 + 2.0) * t if cfg["kink"] else 0.0
    y -= cfg["hook"] * t**4
    return (lean + kink, y)


def radius(z, cfg):
    """Shaft radius: an ease-in taper, plus optional periodic node bulges
    (bamboo joints)."""
    t = min(max(z, 0.0), ROD_LENGTH) / ROD_LENGTH
    r = cfg["radius_butt"] + (cfg["radius_tip"] - cfg["radius_butt"]) * (t * t * (3 - 2 * t))
    n = cfg["nodes"]
    if n > 0 and cfg["node_amp"] > 0:
        for k in range(1, n + 1):
            zk = (k / (n + 1)) * ROD_LENGTH
            d = (z - zk) / 0.13
            r += cfg["node_amp"] * math.exp(-d * d)
    return r


def shaft_point(z, cfg):
    x, y = spine(z, cfg)
    return Vector((x, y, z))


def tip_point(cfg):
    return shaft_point(ROD_LENGTH + 0.25, cfg)


# ---------------------------------------------------------------- scene helpers


def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    for block in (bpy.data.meshes, bpy.data.materials, bpy.data.objects):
        for item in list(block):
            block.remove(item)


def make_material(name, rgb, glow=False):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (rgb[0], rgb[1], rgb[2], 1)
    bsdf.inputs["Roughness"].default_value = 1.0
    if glow:
        # Preview-only stand-in for Roblox's Neon material.
        bsdf.inputs["Emission Color"].default_value = (rgb[0], rgb[1], rgb[2], 1)
        bsdf.inputs["Emission Strength"].default_value = 2.5
    mat.diffuse_color = (rgb[0], rgb[1], rgb[2], 1)
    return mat


def object_from_bmesh(name, bm, material):
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    obj.data.materials.append(material)
    for poly in mesh.polygons:
        poly.use_smooth = False
    bpy.context.collection.objects.link(obj)
    return obj


# ---------------------------------------------------------------- mesh primitives


def frame_for(direction):
    """Two unit vectors spanning the plane perpendicular to `direction`."""
    d = direction.normalized()
    u = d.cross(Vector((0, 0, 1)))
    if u.length < 1e-6:
        u = d.cross(Vector((1, 0, 0)))
    u.normalize()
    v = d.cross(u).normalized()
    return d, u, v


def ring(bm, cx, cy, z, r, sides, phase=0.0, flatten=1.0):
    return [
        bm.verts.new(Vector((cx + math.cos(a) * r, cy + math.sin(a) * r * flatten, z)))
        for a in ((i / sides) * math.tau + phase for i in range(sides))
    ]


def bridge(bm, a, b):
    n = len(a)
    for i in range(n):
        bm.faces.new((a[i], a[(i + 1) % n], b[(i + 1) % n], b[i]))


def tube(bm, stations, sides, phase=0.0, flatten=1.0):
    rings = [ring(bm, cx, cy, z, r, sides, phase, flatten) for cx, cy, z, r in stations]
    for a, b in zip(rings, rings[1:]):
        bridge(bm, a, b)
    return rings


def lathe(bm, center, profile, segments, phase=0.0):
    """Revolve a (radius, z) profile about the vertical axis through
    `center`; z is relative to it. A zero radius becomes an apex point."""
    rings = []
    for r, z in profile:
        if r < 1e-5:
            rings.append(bm.verts.new(center + Vector((0, 0, z))))
        else:
            rings.append(ring(bm, center.x, center.y, center.z + z, r, segments, phase))
    for a, b in zip(rings, rings[1:]):
        if isinstance(a, list) and isinstance(b, list):
            bridge(bm, a, b)
        elif isinstance(a, list):
            for i in range(segments):
                bm.faces.new((a[i], a[(i + 1) % segments], b))
        elif isinstance(b, list):
            for i in range(segments):
                bm.faces.new((b[(i + 1) % segments], b[i], a))
    if isinstance(rings[0], list):
        bm.faces.new(list(reversed(rings[0])))
    if isinstance(rings[-1], list):
        bm.faces.new(rings[-1])


def segment(bm, p0, p1, r0, r1, sides=6):
    """A capped frustum from p0 to p1."""
    d, u, v = frame_for(p1 - p0)
    rings = []
    for p, r in ((p0, r0), (p1, r1)):
        rings.append([bm.verts.new(p + (u * math.cos(a) + v * math.sin(a)) * r) for a in ((i / sides) * math.tau for i in range(sides))])
    bridge(bm, rings[0], rings[1])
    bm.faces.new(list(reversed(rings[0])))
    bm.faces.new(rings[1])


def cone(bm, base_center, direction, length, base_r, sides=5):
    d, u, v = frame_for(direction)
    base = [bm.verts.new(base_center + (u * math.cos(a) + v * math.sin(a)) * base_r) for a in ((i / sides) * math.tau for i in range(sides))]
    apex = bm.verts.new(base_center + d * length)
    for i in range(sides):
        bm.faces.new((base[i], base[(i + 1) % sides], apex))
    bm.faces.new(list(reversed(base)))


def torus(bm, center, normal, major, minor, seg_major=8, seg_minor=4):
    n, u, v = frame_for(normal)
    rings = []
    for i in range(seg_major):
        a = (i / seg_major) * math.tau
        radial = u * math.cos(a) + v * math.sin(a)
        c = center + radial * major
        rings.append([bm.verts.new(c + (radial * math.cos(b) + n * math.sin(b)) * minor) for b in ((j / seg_minor) * math.tau for j in range(seg_minor))])
    for i in range(seg_major):
        bridge(bm, rings[i], rings[(i + 1) % seg_major])


def ball(bm, center, r, segments=8):
    profile = [(0.0, -r)]
    for k in range(1, 5):
        a = -math.pi / 2 + (k / 5) * math.pi
        profile.append((r * math.cos(a), r * math.sin(a)))
    profile.append((0.0, r))
    lathe(bm, center, profile, segments)


# ---------------------------------------------------------------- parts


def build_shaft(bm, cfg):
    sides = cfg["sides"]
    flatten = cfg["flatten"]

    steps = 18
    stations = [(*spine(z, cfg), z, radius(z, cfg)) for z in ((i / steps) * ROD_LENGTH for i in range(steps + 1))]
    rings = tube(bm, stations, sides, flatten=flatten)

    bm.faces.new(list(reversed(rings[0])))
    tip = bm.verts.new(tip_point(cfg))
    top = rings[-1]
    for i in range(sides):
        bm.faces.new((top[i], top[(i + 1) % sides], tip))

    # Jutting cones: grown twigs (cant > 0) or backswept barbs (cant < 0).
    for z, angle, length, cant in cfg["cones"]:
        r = radius(z, cfg)
        out = Vector((math.cos(angle), math.sin(angle) * flatten, 0.0))
        base_center = shaft_point(z, cfg) + out * (r * 0.6)
        direction = (out + Vector((0, 0, cant))).normalized()
        cone(bm, base_center, direction, length, r * 0.55)


def build_grip(bm, cfg):
    sides = cfg["sides"] + 1
    gr = cfg["grip_radius"]
    wraps = 7
    stations = []
    for i in range(wraps * 2 + 1):
        t = i / (wraps * 2)
        z = GRIP_START + (GRIP_END - GRIP_START) * t
        cx, cy = spine(z, cfg)
        if cfg["grip_style"] == "cork":
            r = gr * (0.82 + 0.18 * math.sin(t * math.pi))
        else:
            r = gr if i % 2 == 0 else gr * 0.86
        if i == 0 or i == wraps * 2:
            r = radius(z, cfg) + 0.02
        stations.append((cx, cy, z, r))

    rings = tube(bm, stations, sides, phase=0.3)
    bm.faces.new(list(reversed(rings[0])))
    bm.faces.new(rings[-1])


def build_bands(bm, cfg):
    """Wraps around the shaft: twine lashings, ferrules, glowing collars."""
    sides = cfg["sides"] + 2
    for z, width in cfg["bands"]:
        r = radius(z, cfg) + 0.035
        stations = [(*spine(z - width / 2, cfg), z - width / 2, r), (*spine(z + width / 2, cfg), z + width / 2, r)]
        rings = tube(bm, stations, sides, phase=0.2, flatten=cfg["flatten"])
        bm.faces.new(list(reversed(rings[0])))
        bm.faces.new(rings[-1])


def build_guides(bm, cfg):
    """Line guides on the underside: a wire loop on a short foot, or a
    collar ring around the shaft itself."""
    for z in cfg["guides"]:
        r = radius(z, cfg)
        p = shaft_point(z, cfg)
        if cfg["guide_style"] == "collar":
            torus(bm, p, Vector((0, 0, 1)), r * cfg["flatten"] + 0.1, 0.045, seg_major=8, seg_minor=4)
        else:
            loop_r = 0.09 + r * 0.6
            foot = p + UNDER * (r * 0.7)
            center = p + UNDER * (r + loop_r + 0.04)
            segment(bm, foot, center - UNDER * loop_r * 0.5, 0.03, 0.03, sides=4)
            torus(bm, center, Vector((0, 0, 1)), loop_r, 0.028, seg_major=8, seg_minor=3)


def build_tip_ring(bm, cfg):
    tip = tip_point(cfg)
    r = cfg["radius_tip"]
    torus(bm, tip + Vector((0, 0, 0.02)), Vector((1, 0, 0)), r + 0.07, 0.03, seg_major=8, seg_minor=3)


def build_pommel(bm, cfg):
    gr = cfg["grip_radius"]
    if cfg["pommel"] == "cap":
        # Butt plane is z=0 exactly (was -0.02: every cap rod dipped 2cm
        # below the frame's butt - flagged in the 2026-08-27 rod QA).
        lathe(bm, Vector((0, 0, 0)), [(0.0, 0.0), (gr * 0.9, 0.0), (gr * 1.08, 0.05), (gr * 1.08, 0.2), (gr * 0.95, 0.26), (0.0, 0.26)], cfg["sides"] + 1)
    elif cfg["pommel"] == "spike":
        lathe(bm, Vector((0, 0, 0)), [(0.0, -0.55), (0.12, -0.25), (gr * 0.85, 0.05), (gr * 1.05, 0.14), (gr * 0.9, 0.24), (0.0, 0.24)], cfg["sides"])


def build_reel(bm, cfg):
    reel = cfg["reel"]
    z = reel["z"]
    r = radius(z, cfg)
    seat = shaft_point(z, cfg)

    if reel["style"] == "spinning":
        # Stem down from the seat, a rounded body, the spool ahead of it
        # (coaxial with the rod), a bail wire round the spool, a crank knob.
        body = seat + UNDER * (r + 0.5)
        segment(bm, seat + UNDER * (r * 0.5), body, 0.07, 0.1, sides=6)
        ball(bm, body, 0.2, segments=8)
        spool = body + Vector((0, 0, 0.46))
        segment(bm, body + Vector((0, 0, 0.15)), spool - Vector((0, 0, 0.16)), 0.07, 0.12, sides=6)
        segment(bm, spool - Vector((0, 0, 0.16)), spool + Vector((0, 0, 0.16)), 0.27, 0.27, sides=10)
        segment(bm, spool + Vector((0, 0, 0.16)), spool + Vector((0, 0, 0.2)), 0.22, 0.22, sides=10)
        torus(bm, spool + Vector((0, 0, 0.05)), Vector((0, 0, 1)), 0.32, 0.022, seg_major=10, seg_minor=3)
        crank_end = body + Vector((0.34, 0, 0))
        segment(bm, body, crank_end, 0.035, 0.035, sides=4)
        segment(bm, crank_end, crank_end + Vector((0, 0, 0.18)), 0.06, 0.06, sides=5)
    else:
        # A black-iron drum hung on a short stem, ringed with spikes.
        drum = seat + UNDER * (r + 0.42)
        segment(bm, seat + UNDER * (r * 0.5), drum, 0.09, 0.09, sides=5)
        axis = Vector((1, 0, 0))
        segment(bm, drum - axis * 0.16, drum + axis * 0.16, 0.3, 0.3, sides=6)
        segment(bm, drum - axis * 0.22, drum + axis * 0.22, 0.12, 0.12, sides=6)
        for i in range(6):
            a = (i / 6) * math.tau + 0.5
            out = Vector((0, math.cos(a), math.sin(a)))
            cone(bm, drum + out * 0.26, out, 0.22, 0.06, sides=4)


def line_path(cfg, steps):
    line = cfg["line"]
    start = tip_point(cfg)
    tilt = math.radians(line["tilt"])
    hang = Vector((0.0, -math.sin(tilt), -math.cos(tilt)))
    side = Vector((1.0, 0.0, 0.0))
    return [start + hang * (line["length"] * (i / steps)) + side * (math.sin((i / steps) * math.pi) * line["bow"]) for i in range(steps + 1)]


def build_line(bm, cfg):
    points = line_path(cfg, 8)
    d, u, v = frame_for(points[-1] - points[0])
    r = cfg["line"]["radius"]
    rings = [[bm.verts.new(p + (u * math.cos(a) + v * math.sin(a)) * r) for a in ((i / 3) * math.tau for i in range(3))] for p in points]
    for a, b in zip(rings, rings[1:]):
        bridge(bm, a, b)
    bm.faces.new(list(reversed(rings[0])))
    bm.faces.new(rings[-1])


def build_float(top_bm, bottom_bm, cfg):
    profile = FLOATS[cfg["float"]]
    end = line_path(cfg, 8)[-1]
    top_height = max(z for _, z in profile["top"])
    center = end - Vector((0, 0, top_height))

    lathe(top_bm, center, profile["top"], 8)
    lathe(bottom_bm, center, profile["bottom"], 8)

    if cfg["float"] == "lantern":
        # An iron cage under the orb: a rim ring and three barbs curling
        # down and out, like the lure on an anglerfish.
        rim_r = 0.28
        torus(bottom_bm, center - Vector((0, 0, 0.02)), Vector((0, 0, 1)), rim_r, 0.03, seg_major=8, seg_minor=3)
        for i in range(3):
            a = (i / 3) * math.tau + 0.3
            out = Vector((math.cos(a), math.sin(a), 0.0))
            base = center + out * (rim_r - 0.02) - Vector((0, 0, 0.06))
            cone(bottom_bm, base, (out * 0.45 - Vector((0, 0, 1))).normalized(), 0.34, 0.045, sides=4)


def build_variant(name, cfg):
    bms = {part: bmesh.new() for part in ("Twig", "Grip", "Trim", "Line", "BobberTop", "BobberBottom")}

    build_shaft(bms["Twig"], cfg)
    build_grip(bms["Grip"], cfg)
    build_bands(bms["Trim"], cfg)
    build_guides(bms["Trim"], cfg)
    if cfg["tip_ring"]:
        build_tip_ring(bms["Trim"], cfg)
    if cfg["pommel"]:
        build_pommel(bms["Trim"] if cfg["pommel"] == "cap" else bms["Grip"], cfg)
    if cfg["reel"]:
        build_reel(bms[cfg["reel"]["part"]], cfg)
    build_line(bms["Line"], cfg)
    build_float(bms["BobberTop"], bms["BobberBottom"], cfg)

    colors = cfg["colors"]
    color_of = {"Twig": "twig", "Grip": "grip", "Trim": "trim", "Line": "line", "BobberTop": "top", "BobberBottom": "bottom"}
    objects = []
    for part, bm in bms.items():
        if len(bm.faces) == 0:
            bm.free()
            continue
        glow = part in cfg.get("neon", [])
        objects.append(object_from_bmesh(f"{name}_{part}", bm, make_material(f"{name}_M_{part}", colors[color_of[part]], glow)))
    return objects


# ---------------------------------------------------------------- bespoke rods
# The config builder above makes every rod "a tapered shaft + guides + a float",
# so they read as variations of one stick. These three break that mould with
# their own geometry - a bone spine, a coiled electrode, a heart-cored relic -
# so the high rods actually look unique. They still emit the same six
# Twig/Grip/Trim/Line/BobberTop/BobberBottom parts (RodModel's contract) and
# keep the ROD_LENGTH / GRIP_CENTER frame, and they reuse the shared grip / reel
# / line / float so only the signature silhouette is new. Colours + neon still
# come from the variant's config (preview only; the game recolours per row).

PART_NAMES = ("Twig", "Grip", "Trim", "Line", "BobberTop", "BobberBottom")


def _finish(name, cfg, bms):
    """Colour + flat-shade a dict of part bmeshes into objects (shared tail of
    every bespoke builder; mirrors build_variant's finishing loop)."""
    colors = cfg["colors"]
    color_of = {"Twig": "twig", "Grip": "grip", "Trim": "trim", "Line": "line", "BobberTop": "top", "BobberBottom": "bottom"}
    objects = []
    for part, bm in bms.items():
        if len(bm.faces) == 0:
            bm.free()
            continue
        glow = part in cfg.get("neon", [])
        objects.append(object_from_bmesh(f"{name}_{part}", bm, make_material(f"{name}_M_{part}", colors[color_of[part]], glow)))
    return objects


def _cap_tube_tip(bm, rings, cfg, sides):
    """Butt cap + a pointed tip fan on a tube built from `rings` (like build_shaft)."""
    bm.faces.new(list(reversed(rings[0])))
    tip = bm.verts.new(tip_point(cfg))
    for i in range(sides):
        bm.faces.new((rings[-1][i], rings[-1][(i + 1) % sides], tip))


# Bonecaster - a spine: a column of vertebra knuckles and thin discs up a
# curved bone, transverse rib-spurs, glowing brine-green collars in the gaps, a
# fanged tip, a spiked bone drum. Reads as a skeleton, not a cane.
def build_bonecaster(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]
    z0 = GRIP_END
    n = 9
    zs = [z0 + (ROD_LENGTH - z0) * (i / n) for i in range(n + 1)]
    prev = None
    for i, z in enumerate(zs):
        c = shaft_point(z, cfg)
        r = radius(z, cfg)
        if i % 2 == 0:
            ball(twig, c, r * 2.1, segments=6)  # a fat vertebra knuckle
            if 2 <= i <= n - 2:  # transverse rib spurs, backswept
                for sy in (-1, 1):
                    out = Vector((0, sy, -0.25)).normalized()
                    cone(twig, c + out * r, out, r * 2.8, r * 0.6, sides=4)
        else:
            ball(twig, c, r * 0.5, segments=5)  # the thin disc between
        if prev is not None:  # a thin neck so the knuckles read as separate bones
            segment(twig, prev, c, radius(zs[i - 1], cfg) * 0.34, r * 0.34, sides=5)
        prev = c
    # A fanged bone tip.
    cone(twig, shaft_point(ROD_LENGTH, cfg), Vector((0, -cfg["hook"], 1)).normalized(), 0.5, radius(ROD_LENGTH, cfg), sides=5)

    build_grip(bms["Grip"], cfg)
    if cfg["reel"]:
        build_reel(bms[cfg["reel"]["part"]], cfg)
    # Glowing collars in the vertebra gaps + the tip ring (Trim).
    for i in range(1, n, 2):
        z = zs[i]
        torus(trim, shaft_point(z, cfg), Vector((0, 0, 1)), radius(z, cfg) * 1.15 + 0.03, 0.05, seg_major=8, seg_minor=4)
    build_tip_ring(trim, cfg)
    build_line(bms["Line"], cfg)
    build_float(bms["BobberTop"], bms["BobberBottom"], cfg)
    return _finish(name, cfg, bms)


# Voltline - an electrode whip: a lean straight blank with a glowing wire COIL
# wound up it, a forked lightning tip, and a battery canister slung under the
# butt. Reads as a tesla rod, not a fishing pole.
def build_voltline(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]
    sides = cfg["sides"]
    z0 = GRIP_END
    steps = 14
    stations = [(*spine(z, cfg), z, radius(z, cfg)) for z in (z0 + (ROD_LENGTH - z0) * (i / steps) for i in range(steps + 1))]
    rings = tube(twig, stations, sides)
    _cap_tube_tip(twig, rings, cfg, sides)
    # Forked electrode tip: two glowing prongs splitting off the end (Trim).
    tipc = shaft_point(ROD_LENGTH, cfg)
    for sy in (-1, 1):
        cone(trim, tipc + Vector((0, 0, 0.05)), Vector((0.24 * sy, 0, 1.0)).normalized(), 0.7, 0.055, sides=4)
    # Helical coil of glowing wire up the shaft (Trim).
    turns, per = 5, 9
    m = turns * per
    coil = []
    for k in range(m + 1):
        t = k / m
        z = z0 + 0.3 + (ROD_LENGTH - 0.9 - z0) * t
        rr = radius(z, cfg) + 0.11
        a = t * turns * math.tau
        coil.append(shaft_point(z, cfg) + Vector((math.cos(a) * rr, math.sin(a) * rr, 0)))
    for i in range(len(coil) - 1):
        segment(trim, coil[i], coil[i + 1], 0.05, 0.05, sides=4)

    build_grip(bms["Grip"], cfg)
    # Battery canister slung under the butt (Trim).
    can = shaft_point(0.95, cfg) + UNDER * (radius(0.95, cfg) + 0.34)
    segment(trim, can + Vector((0, 0, -0.4)), can + Vector((0, 0, 0.4)), 0.2, 0.2, sides=8)
    for cap_z in (-0.4, 0.4):
        torus(trim, can + Vector((0, 0, cap_z)), Vector((0, 0, 1)), 0.17, 0.035, seg_major=8, seg_minor=3)
    if cfg["reel"]:
        build_reel(bms[cfg["reel"]["part"]], cfg)
    build_line(bms["Line"], cfg)
    build_float(bms["BobberTop"], bms["BobberBottom"], cfg)
    return _finish(name, cfg, bms)


# Brineheart - the capstone relic: a thick organic shaft that swells around a
# glowing HEART-CORE orb caged in bone ribs near the grip, backswept barbs, a
# spiked drum, glowing collars, and a big lantern float. Reads as grown, not made.
def build_brineheart(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]
    sides = cfg["sides"]
    z0 = GRIP_END
    heart_z = 2.9

    def r_at(z):
        base = radius(z, cfg)
        d = (z - heart_z) / 0.6
        return base + 0.28 * math.exp(-d * d)  # swell where the heart is mounted

    steps = 16
    stations = [(*spine(z, cfg), z, r_at(z)) for z in (z0 + (ROD_LENGTH - z0) * (i / steps) for i in range(steps + 1))]
    rings = tube(twig, stations, sides)
    _cap_tube_tip(twig, rings, cfg, sides)
    # Backswept barbs down the spine.
    for z, ang in ((3.1, 1.3), (4.0, 4.6), (4.8, 2.5), (5.6, 0.5)):
        out = Vector((math.cos(ang), math.sin(ang), 0.0))
        base = shaft_point(z, cfg) + out * (r_at(z) * 0.6)
        cone(twig, base, (out + Vector((0, 0, -0.7))).normalized(), 0.42, r_at(z) * 0.5, sides=4)
    # The heart: a glowing core orb (Trim) in a cage of bone ribs (Twig).
    heart = shaft_point(heart_z, cfg)
    ball(trim, heart, 0.46, segments=8)
    for i in range(5):
        a = (i / 5) * math.tau + 0.3
        out = Vector((math.cos(a), math.sin(a), 0.0))
        segment(twig, heart + out * 0.36 + Vector((0, 0, -0.52)), heart + out * 0.6, 0.045, 0.045, sides=3)
        segment(twig, heart + out * 0.6, heart + out * 0.36 + Vector((0, 0, 0.52)), 0.045, 0.045, sides=3)

    build_grip(bms["Grip"], cfg)
    if cfg["reel"]:
        build_reel(bms[cfg["reel"]["part"]], cfg)
    for z in (3.4, 4.5, 5.6):
        torus(trim, shaft_point(z, cfg), Vector((0, 0, 1)), r_at(z) + 0.04, 0.05, seg_major=8, seg_minor=4)
    build_tip_ring(trim, cfg)
    build_line(bms["Line"], cfg)
    build_float(bms["BobberTop"], bms["BobberBottom"], cfg)
    return _finish(name, cfg, bms)


# Phoenix Ash - the capstone relic reborn from fire: a slender ash-pale shaft
# that flares at the tip into a fanned crest of flame feathers, a caged
# ember-heart swells near the grip, backswept flame-feather barbs run down
# the spine, and glowing rings mark where the ash still smoulders. Reads as
# something that rose, not something that was carved. Legendary.
def build_phoenix_ash(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]
    sides = cfg["sides"]
    z0 = GRIP_END
    ember_z = 2.7

    def r_at(z):
        base = radius(z, cfg)
        d = (z - ember_z) / 0.55
        return base + 0.24 * math.exp(-d * d)  # swell where the ember-heart is caged

    steps = 16
    stations = [(*spine(z, cfg), z, r_at(z)) for z in (z0 + (ROD_LENGTH - z0) * (i / steps) for i in range(steps + 1))]
    rings = tube(twig, stations, sides)
    _cap_tube_tip(twig, rings, cfg, sides)

    # A crest of flame feathers fanning up and back from the tip (Trim, glowing).
    tipc = tip_point(cfg)
    for i in range(5):
        a = (i / 4 - 0.5) * 1.5
        out = Vector((math.sin(a), 0.2, math.cos(a) * 0.6 + 0.5)).normalized()
        cone(trim, tipc, out, 0.6 - abs(a) * 0.14, 0.05, sides=4)

    # Backswept flame-feather barbs down the spine (Trim, glowing).
    for z, ang in ((3.2, 1.4), (4.1, 4.6), (4.9, 2.6), (5.7, 0.4)):
        out = Vector((math.cos(ang), math.sin(ang), 0.0))
        base = shaft_point(z, cfg) + out * (r_at(z) * 0.6)
        cone(trim, base, (out + Vector((0, 0, -0.6))).normalized(), 0.4, r_at(z) * 0.45, sides=4)

    # The ember-heart: a glowing core (Trim) caged in ash-pale ribs (Twig).
    heart = shaft_point(ember_z, cfg)
    ball(trim, heart, 0.4, segments=8)
    for i in range(5):
        a = (i / 5) * math.tau + 0.3
        out = Vector((math.cos(a), math.sin(a), 0.0))
        segment(twig, heart + out * 0.3 + Vector((0, 0, -0.46)), heart + out * 0.5, 0.04, 0.04, sides=3)
        segment(twig, heart + out * 0.5, heart + out * 0.3 + Vector((0, 0, 0.46)), 0.04, 0.04, sides=3)

    build_grip(bms["Grip"], cfg)
    if cfg["reel"]:
        build_reel(bms[cfg["reel"]["part"]], cfg)
    for z in (3.5, 4.6, 5.6):
        torus(trim, shaft_point(z, cfg), Vector((0, 0, 1)), r_at(z) + 0.04, 0.05, seg_major=8, seg_minor=4)
    build_line(bms["Line"], cfg)
    build_float(bms["BobberTop"], bms["BobberBottom"], cfg)
    return _finish(name, cfg, bms)


# --------------------------------------------- fen / ice / maelstrom helpers
# The five island families below are all bespoke (one builder each), so they
# share this second tier of primitives on top of the mesh primitives above:
# boxes, blades, discs, ribbons, arcs, helices and a warped shaft tube. Every
# one is deterministic - shapes vary by fixed numbers, never `random`.


def _fim_box(bm, c, ex, ey, ez):
    """A box at `c` from three half-extent VECTORS (any orientation)."""
    vs = []
    for sz in (-1, 1):
        for sy in (-1, 1):
            for sx in (-1, 1):
                vs.append(bm.verts.new(c + ex * sx + ey * sy + ez * sz))
    for f in ((0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)):
        bm.faces.new([vs[i] for i in f])


def _fim_quad_slab(bm, quad, offset):
    """A flat plate: one quad thickened by +/- `offset` (scutes, sails, coins,
    auger flighting - anything that reads as sheet material)."""
    lo = [bm.verts.new(p - offset) for p in quad]
    hi = [bm.verts.new(p + offset) for p in quad]
    bm.faces.new(lo)
    bm.faces.new(list(reversed(hi)))
    for k in range(4):
        bm.faces.new((lo[k], lo[(k + 1) % 4], hi[(k + 1) % 4], hi[k]))


def _fim_blade(bm, base, direction, side, length, half_w, half_t, shoulder=0.35):
    """A flat leaf/fin: base -> widest at `shoulder` -> point, thin along the
    normal. Harpoon heads, scutes, scales, storm vanes, wave crests."""
    d = direction.normalized()
    s = side.normalized()
    n = d.cross(s)
    if n.length < 1e-6:
        n = d.cross(Vector((0, 0, 1)))
    n = n.normalized() * half_t
    apex = base + d * length
    sh = base + d * (length * shoulder)
    faces = []
    for sn in (-1, 1):
        o = n * sn
        faces.append([bm.verts.new(base + o), bm.verts.new(sh + s * half_w + o), bm.verts.new(apex + o), bm.verts.new(sh - s * half_w + o)])
    a, b = faces
    bm.faces.new(a)
    bm.faces.new(list(reversed(b)))
    for i in range(4):
        bm.faces.new((a[i], a[(i + 1) % 4], b[(i + 1) % 4], b[i]))


def _fim_disc(bm, center, normal, r, half_thick, sides=8):
    """A coin: a short capped cylinder facing `normal`."""
    d, _u, _v = frame_for(normal)
    segment(bm, center - d * half_thick, center + d * half_thick, r, r, sides=sides)


def _fim_crystal(bm, center, r, drop, rise, segments=6, phase=0.0):
    """A faceted gem: a point below, a girdle, a shouldered point above."""
    lathe(bm, center, [(0.0, -drop), (r, 0.0), (r * 0.6, rise * 0.45), (0.0, rise)], segments, phase)


def _fim_arc(a, b, bulge_dir, bulge, steps=8):
    """Points along a bowed arc from a to b (roots, tendrils, stalks, jaws)."""
    d = bulge_dir.normalized()
    return [a.lerp(b, i / steps) + d * (math.sin((i / steps) * math.pi) * bulge) for i in range(steps + 1)]


def _fim_taper_chain(bm, pts, r0, r1, sides=4):
    """A tapering tube down a polyline."""
    n = len(pts) - 1
    for i in range(n):
        if (pts[i + 1] - pts[i]).length < 1e-6:
            continue
        segment(bm, pts[i], pts[i + 1], r0 + (r1 - r0) * (i / n), r0 + (r1 - r0) * ((i + 1) / n), sides=sides)


def _fim_zigzag(bm, bm_start, direction, side, n, length, thick, kick=0.17):
    """A lightning bolt: a polyline that kicks side to side as it travels.
    `kick` shrinks with the run so a short bolt stays a bolt, not a fan."""
    p = bm_start
    pts = [p]
    for i in range(n):
        p = p + direction.normalized() * (length / n) + side.normalized() * (kick if i % 2 == 0 else -kick)
        pts.append(p)
    _fim_taper_chain(bm, pts, thick, thick * 0.55, sides=3)
    return pts


def _fim_helix_pts(cfg, z_lo, z_hi, turns, offset, phase=0.0, per_turn=8, r_fn=None, warp=None):
    """Points on a helix wound around the blank. `offset` is a constant or a
    f(t) stand-off from the shaft surface - one helper serves the auger's
    flighting, the eyewall's vortex band and the kraken's tentacle."""
    m = max(4, int(round(abs(turns) * per_turn)))
    pts = []
    for k in range(m + 1):
        t = k / m
        z = z_lo + (z_hi - z_lo) * t
        rr = (r_fn(z) if r_fn else radius(z, cfg)) + (offset(t) if callable(offset) else offset)
        a = phase + t * turns * math.tau
        p = shaft_point(z, cfg) + Vector((math.cos(a) * rr, math.sin(a) * rr, 0.0))
        pts.append(p + warp(z) if warp else p)
    return pts


def _fim_helix_band(bm, inner, outer, half_t=0.035):
    """A wide ribbon between two helices (auger flight, vortex wall)."""
    up = Vector((0.0, 0.0, half_t))
    for i in range(len(inner) - 1):
        _fim_quad_slab(bm, [inner[i], inner[i + 1], outer[i + 1], outer[i]], up)


def _fim_warp_tube(bm, cfg, warp=None, z0=0.0, z1=None, steps=16, sides=None, flatten=None, r_fn=None, phase=0.0, cap_tip=True):
    """build_shaft's tube, but with a per-rod centreline `warp` (which MUST
    fade to zero at ROD_LENGTH so the tip stays on tip_point) and a per-rod
    radius. cap_tip=False makes a closed barrel instead of a pointed tip."""
    sides = sides or cfg["sides"]
    flatten = cfg["flatten"] if flatten is None else flatten
    z1 = ROD_LENGTH if z1 is None else z1
    stations = []
    for i in range(steps + 1):
        z = z0 + (z1 - z0) * (i / steps)
        cx, cy = spine(z, cfg)
        if warp:
            w = warp(z)
            cx += w.x
            cy += w.y
        stations.append((cx, cy, z, r_fn(z) if r_fn else radius(z, cfg)))
    rings = tube(bm, stations, sides, phase=phase, flatten=flatten)
    if cap_tip:
        _cap_tube_tip(bm, rings, cfg, sides)
    else:
        bm.faces.new(list(reversed(rings[0])))
        bm.faces.new(rings[-1])
    return rings


def _fim_butt(bm, cfg, style):
    """Per-rod butt furniture. The shared build_pommel's "spike" hangs to
    z = -0.55, which would put the rod through the floor AND put one identical
    spike on six of these rods - so the rods that wanted a spike get their own
    butt instead. Every profile here starts at z >= 0.10: nothing dips below 0."""
    gr = cfg["grip_radius"]
    sides = cfg["sides"]
    if style == "lance":  # Fenpiercer: a squat faceted counterweight
        lathe(bm, Vector((0, 0, 0)), [(0.0, 0.10), (gr * 0.95, 0.15), (gr * 1.14, 0.27), (gr * 0.98, 0.44), (0.0, 0.50)], sides)
    elif style == "root":  # Mireheart: a knot of root balled around the butt
        lathe(bm, Vector((0, 0, 0)), [(0.0, 0.10), (gr * 1.05, 0.19), (gr * 1.15, 0.38), (gr * 0.82, 0.54), (0.0, 0.58)], sides)
        for i in range(4):
            a = (i / 4) * math.tau + 0.4
            out = Vector((math.cos(a), math.sin(a), 0.0))
            p = Vector((0, 0, 0.32)) + out * (gr * 0.95)
            _fim_taper_chain(bm, _fim_arc(p, p + out * 0.34 + Vector((0, 0, 0.44)), out, 0.12, 4), 0.055, 0.025, sides=4)
    elif style == "shards":  # Frostheart: a ring of ice shards pointing UP
        lathe(bm, Vector((0, 0, 0)), [(0.0, 0.10), (gr * 0.92, 0.17), (gr * 0.92, 0.30), (0.0, 0.36)], sides)
        for i in range(5):
            a = (i / 5) * math.tau + 0.3
            _fim_crystal(bm, Vector((0, 0, 0.40)) + Vector((math.cos(a), math.sin(a), 0.0)) * (gr * 0.78), 0.085, 0.14, 0.34, segments=4, phase=a)
    elif style == "eye":  # Eyewall: a wide flat storm-eye plate, no point at all
        lathe(bm, Vector((0, 0, 0)), [(0.0, 0.12), (gr * 1.45, 0.17), (gr * 1.52, 0.27), (gr * 0.9, 0.33), (0.0, 0.36)], 10)
    elif style == "curl":  # Krakenheart: the tentacle's tail curling up the grip
        lathe(bm, Vector((0, 0, 0)), [(0.0, 0.10), (gr * 0.95, 0.16), (gr * 1.02, 0.30), (0.0, 0.36)], sides)
        pts = []
        for k in range(13):
            t = k / 12
            a = 0.4 + t * 1.35 * math.tau
            rr = gr + 0.13
            pts.append(Vector((math.cos(a) * rr, math.sin(a) * rr, 0.30 + 1.05 * t)))
        _fim_taper_chain(bm, pts, 0.10, 0.05, sides=4)
    elif style == "collar":  # Silverscale: a plain rounded scale collar
        lathe(bm, Vector((0, 0, 0)), [(0.0, 0.10), (gr * 0.85, 0.14), (gr * 1.06, 0.23), (gr * 1.0, 0.36), (0.0, 0.42)], sides + 1)


def _fim_float(top_bm, bot_bm, cfg, style):
    """A per-rod bobber. build_float's tripod-legged lantern cage is
    Wisplight's signature, so the other rods that carry a lantern in their cfg
    get their own float here instead. Still split at the waterline into
    _BobberTop / _BobberBottom, still hung off the line's end."""
    end = line_path(cfg, 8)[-1]
    if style == "bead":  # Mireheart: two amber beads threaded on a stem
        c = end - Vector((0, 0, 0.50))
        segment(top_bm, c + Vector((0, 0, -0.02)), c + Vector((0, 0, 0.34)), 0.035, 0.035, sides=4)
        ball(top_bm, c + Vector((0, 0, 0.30)), 0.20, segments=8)
        ball(top_bm, c + Vector((0, 0, 0.07)), 0.13, segments=6)
        lathe(bot_bm, c, [(0.0, -0.30), (0.16, -0.17), (0.18, 0.0)], 8)
    elif style == "teardrop":  # Aurora: a faceted teardrop, point up
        c = end - Vector((0, 0, 0.52))
        lathe(top_bm, c, [(0.20, 0.0), (0.16, 0.24), (0.08, 0.44), (0.0, 0.52)], 6)
        lathe(bot_bm, c, [(0.0, -0.40), (0.12, -0.24), (0.20, 0.0)], 6)
    elif style == "bipyramid":  # Frostheart: a small ice crystal
        c = end - Vector((0, 0, 0.44))
        lathe(top_bm, c, [(0.19, 0.0), (0.13, 0.26), (0.0, 0.44)], 6)
        lathe(bot_bm, c, [(0.0, -0.46), (0.13, -0.22), (0.19, 0.0)], 6)
    elif style == "pearl":  # Krakenheart: a storm-pearl inside a ring halo
        c = end - Vector((0, 0, 0.26))
        lathe(top_bm, c, [(0.24, 0.0), (0.20, 0.14), (0.10, 0.24), (0.0, 0.26)], 8)
        torus(top_bm, c + Vector((0, 0, 0.05)), Vector((0.25, -0.3, 1.0)), 0.36, 0.03, seg_major=10, seg_minor=3)
        lathe(bot_bm, c, [(0.0, -0.28), (0.12, -0.22), (0.22, -0.08), (0.24, 0.0)], 8)


def _fim_tail(name, cfg, bms, reel=True, pommel=True, bands=False, guides=False, tip_ring=False, butt=None, float_style=None):
    """The shared furniture every bespoke still wants: grip, pommel, reel,
    optional bands/guides/tip ring, the hanging line and the float. `butt`
    swaps build_pommel for a per-rod butt; `float_style` swaps build_float."""
    build_grip(bms["Grip"], cfg)
    if butt:
        _fim_butt(bms["Trim"] if cfg["pommel"] == "cap" else bms["Grip"], cfg, butt)
    elif pommel and cfg["pommel"]:
        build_pommel(bms["Trim"] if cfg["pommel"] == "cap" else bms["Grip"], cfg)
    if reel and cfg["reel"]:
        build_reel(bms[cfg["reel"]["part"]], cfg)
    if bands:
        build_bands(bms["Trim"], cfg)
    if guides:
        build_guides(bms["Trim"], cfg)
    if tip_ring:
        build_tip_ring(bms["Trim"], cfg)
    build_line(bms["Line"], cfg)
    if float_style:
        _fim_float(bms["BobberTop"], bms["BobberBottom"], cfg, float_style)
    else:
        build_float(bms["BobberTop"], bms["BobberBottom"], cfg)
    return _finish(name, cfg, bms)


# ---------------------------------------------------------------- Blackmire Fen
# Root-wrapped blanks, gator scute, wisp light.


# Reedlash - not a rod but a BUNDLE: five cured reeds lashed together, splaying
# apart as they rise and finishing in flat reed leaves. Reads as a broom of
# river cane, widest at the top.
def build_reedlash(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]

    _fim_warp_tube(twig, cfg, steps=16, r_fn=lambda z: radius(z, cfg) * 0.74)
    for ang, sc, ztop in ((0.4, 1.0, 6.30), (1.7, 0.85, 5.55), (3.0, 1.0, 6.05), (4.3, 0.8, 5.15), (5.5, 0.92, 5.85)):
        out = Vector((math.cos(ang), math.sin(ang), 0.0))
        n = 8
        pts = []
        for i in range(n + 1):
            z = 0.25 + (ztop - 0.25) * (i / n)
            t = z / ROD_LENGTH
            pts.append(shaft_point(z, cfg) + out * (0.10 + 0.34 * sc * t * t * t))
        _fim_taper_chain(twig, pts, radius(0.25, cfg) * 0.46, 0.022, sides=4)
        d = (pts[-1] - pts[-2]).normalized()
        _fim_blade(twig, pts[-1], d, out.cross(d), 0.58 * sc, 0.07, 0.012, shoulder=0.25)
    # twine lashings binding the bundle, opening up as it splays (_Trim)
    for z, mr in ((1.95, 0.20), (3.25, 0.26), (4.50, 0.34), (5.45, 0.41)):
        torus(trim, shaft_point(z, cfg), Vector((0, 0, 1)), mr, 0.055, seg_major=8, seg_minor=4)
    return _fim_tail(name, cfg, bms, guides=True)


# Gatorback - an armoured recurve: the blank bends one way then the other, a
# row of keeled scutes ridges its back, and the top closes into a gator's
# jaw-hook - two curved fangs meeting past the tip.
def build_gatorback(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]

    def warp(z):
        return Vector((0.0, 0.21 * math.sin((z / ROD_LENGTH) * math.tau), 0.0))

    _fim_warp_tube(twig, cfg, warp=warp, steps=20)
    # keeled dorsal scutes, shrinking toward the jaw
    for i in range(8):
        z = 2.0 + i * 0.60
        r = radius(z, cfg)
        p = shaft_point(z, cfg) + warp(z) + Vector((0, r * 0.5, 0))
        _fim_blade(twig, p, Vector((0, 1, 0)), Vector((0, 0, 1)), 0.36 - i * 0.03, r * 1.25, r * 0.5, shoulder=0.30)
    # the jaw: an upper fang off the tip and a lower fang swinging up to meet it
    upper = _fim_arc(shaft_point(6.45, cfg) + warp(6.45), tip_point(cfg) + Vector((0, -0.66, 0.06)), Vector((0, -1, 0.3)), 0.16, 6)
    lower = _fim_arc(shaft_point(5.85, cfg) + UNDER * 0.16, tip_point(cfg) + Vector((0, -0.56, -0.34)), Vector((0, -0.5, 1)), 0.34, 6)
    _fim_taper_chain(twig, upper, 0.095, 0.022, sides=5)
    _fim_taper_chain(twig, lower, 0.105, 0.022, sides=5)
    for i in range(3):  # teeth in the gap (_Trim)
        t = 0.35 + i * 0.22
        a = upper[int(t * 6)]
        b = lower[int(t * 6)]
        cone(trim, a, (b - a).normalized(), 0.16, 0.035, sides=3)
        cone(trim, b, (a - b).normalized(), 0.16, 0.035, sides=3)
    return _fim_tail(name, cfg, bms, bands=True, guides=True)


# Wisplight - the top of the blank opens into a CROOK, an empty eye of wood,
# and a wisp orb hovers inside it with three motes circling. The blank itself
# is deliberately plain so the light is the whole silhouette.
def build_wisplight(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]

    _fim_warp_tube(twig, cfg, steps=16)
    a = shaft_point(5.15, cfg)
    b = tip_point(cfg)
    crook = _fim_arc(a, b, Vector((0, 1, 0)), 0.66, 9)
    _fim_taper_chain(twig, crook, 0.085, 0.045, sides=5)
    eye = a.lerp(b, 0.5) + Vector((0, 0.32, 0))
    ball(trim, eye, 0.19, segments=8)
    # A lantern FRAME around the orb - ribs bowing between a bottom and a top
    # ring - so the silhouette says candle-lantern, not bare orb. It is bolted
    # into the crook on two solid struts and a mount collar: this lantern is
    # held IN the wood. (The trench's Lanternline dangles its cage off a stalk;
    # these two must never read the same.)
    top = eye + Vector((0, 0, 0.31))
    bot = eye + Vector((0, 0, -0.27))
    for i in range(3):
        ang = i * (math.tau / 3) + 0.5
        out = Vector((math.cos(ang), math.sin(ang), 0.0))
        _fim_taper_chain(trim, _fim_arc(bot, top, out, 0.26, 4), 0.03, 0.03, sides=3)
    torus(trim, top, Vector((0, 0, 1)), 0.13, 0.032, seg_major=6, seg_minor=3)
    torus(trim, bot, Vector((0, 0, 1)), 0.11, 0.030, seg_major=6, seg_minor=3)
    for k in (3, 6):  # rigid struts into the crook's inner face
        segment(trim, crook[k], crook[k].lerp(eye, 0.62), 0.045, 0.035, sides=4)
    torus(trim, top + Vector((0, 0, 0.05)), Vector((0, 0, 1)), 0.07, 0.03, seg_major=6, seg_minor=3)
    for i in range(3):
        ang = i * (math.tau / 3) + 0.4
        ball(trim, eye + Vector((math.cos(ang) * 0.42, math.sin(ang) * 0.26, 0.16 * (i - 1))), 0.055, segments=5)
    return _fim_tail(name, cfg, bms, bands=True, guides=True)


# Fenpiercer - a spear, not a cane: dead straight and angular, a broad barbed
# harpoon head at the business end, and a fat cord-wrapped choke grip halfway
# up the blank where a spearman's second hand would go.
def build_fenpiercer(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]

    _fim_warp_tube(twig, cfg, steps=14)
    base = shaft_point(6.05, cfg)
    d = (tip_point(cfg) - base).normalized()
    _fim_blade(twig, base, d, Vector((1, 0, 0)), 1.30, 0.30, 0.05, shoulder=0.30)
    for sx in (-1, 1):  # harpoon barbs raked back off the head's shoulders
        cone(twig, base + d * 0.42 + Vector((0.24 * sx, 0, 0)), Vector((0.62 * sx, -0.12, -1.0)).normalized(), 0.52, 0.075, sides=4)
    for i in range(8):  # the cord-wrapped choke (_Trim)
        z = 2.95 + i * 0.135
        torus(trim, shaft_point(z, cfg), Vector((0, 0, 1)), radius(z, cfg) + 0.055, 0.045, seg_major=7, seg_minor=3)
    return _fim_tail(name, cfg, bms, guides=True, tip_ring=False, butt="lance")


# Mireheart (CROWN) - a living mangrove: two roots braid up the blank, prop
# roots arch off the butt, and four root-fingers reach out under the tip to
# clutch a glowing bog-amber heart.
def build_mireheart(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]
    core = lambda z: radius(z, cfg) * 0.86  # noqa: E731 - the blank under the braid

    _fim_warp_tube(twig, cfg, steps=18, r_fn=core)
    for phase, turns in ((0.0, 2.0), (math.pi, -1.6)):
        pts = _fim_helix_pts(cfg, GRIP_END, 6.2, turns, lambda t: 0.09 + 0.05 * (1 - t), phase=phase, per_turn=7, r_fn=core)
        _fim_taper_chain(twig, pts, 0.105, 0.045, sides=4)
    for i in range(5):  # prop roots arching off the blank above the grip
        a = (i / 5) * math.tau + 0.35
        out = Vector((math.cos(a), math.sin(a), 0.0))
        p = shaft_point(2.05, cfg) + out * radius(2.05, cfg)
        _fim_taper_chain(twig, _fim_arc(p, p + out * 0.52 + Vector((0, 0, -0.78)), out, 0.17, 5), 0.075, 0.026, sides=4)
    heart = shaft_point(6.05, cfg) + UNDER * 0.46
    ball(trim, heart, 0.28, segments=8)
    _fim_crystal(trim, heart, 0.34, 0.30, 0.30, segments=6, phase=0.4)
    for i in range(4):  # the fingers that hold it
        a = (i / 4) * math.tau + 0.6
        out = Vector((math.cos(a), math.sin(a), 0.0))
        top = shaft_point(6.05, cfg) + out * 0.10
        _fim_taper_chain(twig, _fim_arc(top, heart + out * 0.12 + Vector((0, 0, -0.28)), out, 0.32, 6), 0.062, 0.030, sides=4)
    for z in (2.6, 3.6, 4.6, 5.5):  # wisp-lit collars in the braid's gaps
        torus(trim, shaft_point(z, cfg), Vector((0, 0, 1)), core(z) + 0.05, 0.05, seg_major=8, seg_minor=4)
    return _fim_tail(name, cfg, bms, tip_ring=True, butt="root", float_style="bead")


# ------------------------------------------------------------- Frostmaw Reach
# Ice crystal, rime fringe, aurora ribbon.


# Auger - a tool, not tackle: a square shaft wound with a real helical cutting
# FLIGHT, a centring point past the tip, and a cranked brace handle instead of
# a reel. The only screw-shaped rod on the rack.
def build_auger(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]

    _fim_warp_tube(twig, cfg, steps=14, sides=4)
    inner = _fim_helix_pts(cfg, 1.95, 5.60, 3.0, 0.01, per_turn=8)
    outer = _fim_helix_pts(cfg, 1.95, 5.60, 3.0, 0.26, per_turn=8)
    _fim_helix_band(trim, inner, outer, half_t=0.035)
    for i in range(0, len(outer) - 1, 4):  # cutting teeth on the flight's edge
        cone(trim, outer[i], (outer[i] - inner[i]).normalized(), 0.14, 0.045, sides=3)
    cone(twig, shaft_point(ROD_LENGTH, cfg), Vector((0, 0, 1)), 0.55, radius(ROD_LENGTH, cfg) * 0.9, sides=4)
    c0 = shaft_point(1.92, cfg)  # the crank: an arm out and a knob up
    arm = c0 + Vector((0.66, 0, 0))
    segment(trim, c0, arm, 0.06, 0.06, sides=4)
    segment(trim, arm, arm + Vector((0, 0, 0.36)), 0.09, 0.09, sides=6)
    ball(trim, arm + Vector((0, 0, 0.40)), 0.11, segments=6)
    return _fim_tail(name, cfg, bms, guides=True)


# Rimebound - a cane frozen inside its own weather: a lumpy rime-crusted blank
# with a full FRINGE of icicles hanging off the underside, longest at the
# middle. Reads like a comb or a frozen eave.
def build_rimebound(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]

    _fim_warp_tube(twig, cfg, steps=22, r_fn=lambda z: radius(z, cfg) + 0.05 * math.sin(z * 3.1) ** 2)
    for i in range(12):
        t = i / 11
        z = 1.95 + 4.45 * t
        base = shaft_point(z, cfg) + UNDER * (radius(z, cfg) * 0.85)
        length = 0.30 + 0.52 * math.sin(t * math.pi) + 0.11 * math.cos(i * 2.3)
        d = Vector((0.18 * math.cos(i * 1.7), -1.0, -0.06)).normalized()
        cone(trim, base, d, length, 0.055 + 0.022 * math.sin(t * math.pi), sides=4)
    for i in range(4):  # rime shards riding the blank's back
        z = 2.6 + i * 1.05
        _fim_crystal(twig, shaft_point(z, cfg) + Vector((0, radius(z, cfg) * 0.7, 0)), 0.13, 0.05, 0.34 - i * 0.04, segments=5)
    return _fim_tail(name, cfg, bms, bands=True, guides=True)


# Silverscale - a slim blank PLATED in overlapping fish scales that lap toward
# the butt, finished with a caudal scale-fan pommel. The one rod that reads as
# a fish rather than a stick.
def build_silverscale(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]

    _fim_warp_tube(twig, cfg, steps=16, sides=8)
    # Shingled lamination: each row is a short skirt flaring toward the butt
    # over the row below it, so the free edges all face the tail the way real
    # scale armour laps. Every other row is offset half a facet, which gives
    # the broken brickwork seam. Rows LIE ON the blank - nothing stands off it
    # (paired stand-off diamonds read as leaf sprigs, not scales).
    rows = 14
    for row in range(rows):
        z_lo = 2.00 + row * 0.31
        z_hi = z_lo + 0.40  # rows overlap in z, so no gap ever shows
        stations = [
            (*spine(z_lo, cfg), z_lo, radius(z_lo, cfg) + 0.115),
            (*spine(z_hi, cfg), z_hi, radius(z_hi, cfg) + 0.02),
        ]
        rings = tube(trim, stations, 8, phase=(row % 2) * (math.pi / 8))
        trim.faces.new(list(reversed(rings[0])))  # close the proud lower lip
    # the tail fan, folded UP against the grip rather than hanging under the
    # butt - same caudal read, nothing below z = 0
    for i in range(5):
        a = (i / 4 - 0.5) * 1.9
        d = Vector((math.sin(a) * 0.85, 0.0, math.cos(a) * 0.55 + 0.72)).normalized()
        _fim_blade(trim, Vector((0, 0, 0.20)), d, Vector((0, 1, 0)), 0.70 - abs(a) * 0.13, 0.13, 0.02, shoulder=0.5)
    return _fim_tail(name, cfg, bms, guides=True, tip_ring=True, butt="collar")


# Aurora - a long S-curved blank with translucent aurora RIBBONS arcing from
# guide to guide, standing off the blank like curtains of light. The curve is
# the silhouette; the ribbons are the glow.
def build_aurora(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]

    def warp(z):
        return Vector((0.30 * math.sin((z / ROD_LENGTH) * math.tau), 0.0, 0.0))

    _fim_warp_tube(twig, cfg, warp=warp, steps=20, sides=8)
    anchors = [2.4, 3.4, 4.4, 5.4, 6.2]
    for i in range(len(anchors) - 1):
        a = shaft_point(anchors[i], cfg) + warp(anchors[i])
        b = shaft_point(anchors[i + 1], cfg) + warp(anchors[i + 1])
        for lane, (bow, wide) in enumerate(((0.46, 0.17), (0.30, 0.11))):
            pts = _fim_arc(a, b, Vector((0, 1, 0)), bow - i * 0.05, 6)
            for k in range(len(pts) - 1):
                side = Vector((1.0, 0.0, 0.0)) * (wide * (1 if lane == 0 else -1))
                _fim_quad_slab(trim, [pts[k] - side, pts[k] + side, pts[k + 1] + side, pts[k + 1] - side], Vector((0, 0.018, 0)))
        torus(trim, a, Vector((0, 0, 1)), radius(anchors[i], cfg) + 0.09, 0.04, seg_major=8, seg_minor=3)
    return _fim_tail(name, cfg, bms, guides=False, tip_ring=True, float_style="teardrop")


# Frostheart (CROWN) - a HOLLOW rod: a thin ice core inside a counter-wound
# lattice of ribs and hoops that swells around a suspended heart crystal, and
# a crown of crystal spikes fanning off the tip.
def build_frostheart(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]
    heart_z = 3.6
    core = lambda z: radius(z, cfg) * 0.42  # noqa: E731

    def stand(z):
        return 0.21 + 0.24 * math.exp(-(((z - heart_z) / 0.62) ** 2))

    _fim_warp_tube(twig, cfg, steps=18, r_fn=core)
    for turns, phase in ((2.2, 0.0), (-2.2, math.pi)):
        pts = _fim_helix_pts(cfg, GRIP_END, 6.4, turns, lambda t: stand(GRIP_END + (6.4 - GRIP_END) * t), phase=phase, per_turn=7, r_fn=core)
        _fim_taper_chain(twig, pts, 0.055, 0.032, sides=3)
    for z in (2.2, 3.0, 3.6, 4.2, 5.1, 6.0, 6.4):
        torus(trim, shaft_point(z, cfg), Vector((0, 0, 1)), core(z) + stand(z), 0.038, seg_major=8, seg_minor=3)
    _fim_crystal(trim, shaft_point(heart_z, cfg), 0.30, 0.42, 0.52, segments=6, phase=0.3)
    tipc = tip_point(cfg)
    for i in range(5):  # the spike crown
        a = (i / 4 - 0.5) * 1.7
        out = Vector((math.sin(a) * 0.85, 0.16, math.cos(a))).normalized()
        _fim_crystal(trim, tipc + out * 0.30, 0.09, 0.30, 0.34 - abs(a) * 0.06, segments=4, phase=a)
    return _fim_tail(name, cfg, bms, butt="shards", float_style="bipyramid")


# ---------------------------------------------------------------- The Maelstrom
# Storm glass, lightning, the eye.


# Squallcaster - bent by weather it can't escape: the blank bows out of true
# and three swept storm VANES rake back off it like feathers off an arrow.
def build_squallcaster(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]

    def warp(z):
        t = z / ROD_LENGTH
        return Vector((0.16 * math.sin(t * math.tau), -0.26 * math.sin(t * math.pi) ** 2, 0.0))

    _fim_warp_tube(twig, cfg, warp=warp, steps=20)
    for z, ang, ln in ((2.70, 1.1, 1.10), (4.10, 3.9, 0.92), (5.40, 2.0, 0.76)):
        out = Vector((math.cos(ang), math.sin(ang), 0.0))
        p = shaft_point(z, cfg) + warp(z) + out * (radius(z, cfg) * 0.7)
        d = (out * 0.85 + Vector((0, 0, -0.55))).normalized()
        _fim_blade(trim, p, d, out.cross(d), ln, 0.21, 0.022, shoulder=0.28)
    return _fim_tail(name, cfg, bms, bands=True, guides=True, tip_ring=True)


# Riptide - a swell turned solid: the blank's radius ROLLS like a wave, a
# scalloped crest ridge runs its back, and the top breaks over into a curl of
# whitewater spiralling past the tip.
def build_riptide(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]

    def r_at(z):
        return radius(z, cfg) * (1.0 + 0.35 * math.sin(z * 2.0 - 0.6))

    _fim_warp_tube(twig, cfg, steps=24, r_fn=r_at)
    for i in range(7):
        z = 2.10 + i * 0.66
        p = shaft_point(z, cfg) + Vector((0, r_at(z) * 0.55, 0))
        # the crest panes are thinned so they read as a ridge, not as panels
        # competing with the curl
        _fim_blade(twig, p, Vector((0, 1, 0)), Vector((0, 0, 1)), 0.17 + 0.13 * math.sin(z * 2.0 - 0.6), 0.24, 0.03, shoulder=0.45)
    # The breaking curl: enlarged to roughly twice its old radius and hung
    # lower on the blank so it is the first thing the eye lands on. This ring
    # is Riptide's tell - at 30 studs it has to own the silhouette.
    c = shaft_point(6.10, cfg) + Vector((0, -0.55, 0.42))
    curl = [shaft_point(5.85, cfg)]
    for k in range(15):
        t = k / 14
        th = 1.75 + t * 5.0
        rr = 0.78 * (1.0 - 0.55 * t)
        curl.append(c + Vector((0.12 * t, math.cos(th) * rr, math.sin(th) * rr)))
    _fim_taper_chain(trim, curl, 0.17, 0.045, sides=5)
    return _fim_tail(name, cfg, bms, guides=True, tip_ring=True)


# Thunderhead - a storm cell on a stick: an anvil-cloud pommel spreading at
# the butt, and a forked LIGHTNING prong zigzagging off the tip into two
# branches, with lesser bolts jumping off the blank.
def build_thunderhead(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim, grip = bms["Twig"], bms["Trim"], bms["Grip"]

    _fim_warp_tube(twig, cfg, steps=14)
    # The anvil cloud, sitting ON the butt rather than hanging below it: it
    # spreads WIDE at z ~ 0.15 and flattens off at the top, the way a real
    # cumulonimbus anvil does. Nothing dips under z = 0.
    lathe(grip, Vector((0, 0, 0)), [(0.0, 0.12), (0.34, 0.17), (0.30, 0.30), (0.46, 0.41), (0.88, 0.55), (0.96, 0.67), (0.52, 0.79), (0.0, 0.83)], 8)
    for i in range(3):  # ragged cloud lobes riding the anvil's flare
        a = (i / 3) * math.tau + 0.4
        ball(grip, Vector((math.cos(a) * 0.74, math.sin(a) * 0.74, 0.62)), 0.19, segments=6)
    # The fork, compressed: shorter runs and a tighter kick so the whole bolt
    # tops out under the PhoenixAsh ceiling instead of overshooting it.
    main = _fim_zigzag(trim, tip_point(cfg), Vector((0, -0.15, 1.0)), Vector((1, 0, 0)), 4, 0.40, 0.07, kick=0.10)
    for sx in (-1, 1):
        _fim_zigzag(trim, main[3], Vector((0.5 * sx, -0.2, 1.0)), Vector((0, 1, 0)), 3, 0.30, 0.045, kick=0.08)
    for z, ang in ((3.10, 0.9), (4.40, 3.9), (5.60, 2.1)):  # arcs off the blank
        out = Vector((math.cos(ang), math.sin(ang), 0.0))
        _fim_zigzag(trim, shaft_point(z, cfg) + out * radius(z, cfg), out * 0.8 + Vector((0, 0, 0.6)), Vector((0, 0, 1)), 3, 0.46, 0.035)
    return _fim_tail(name, cfg, bms, pommel=False, bands=True, guides=True, tip_ring=True)


# Eyewall - the storm's wall around its eye: a thin straight core with a wide
# DETACHED vortex band spiralling around it on three struts, widest at the
# middle, and a lit eye-ring at the tip.
def build_eyewall(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]
    core = lambda z: radius(z, cfg) * 0.62  # noqa: E731

    _fim_warp_tube(twig, cfg, steps=16, r_fn=core)
    inner = _fim_helix_pts(cfg, 2.0, 6.30, 2.5, lambda t: 0.34 + 0.18 * math.sin(t * math.pi), per_turn=10, r_fn=core)
    outer = _fim_helix_pts(cfg, 2.0, 6.30, 2.5, lambda t: 0.56 + 0.24 * math.sin(t * math.pi), per_turn=10, r_fn=core)
    _fim_helix_band(trim, inner, outer, half_t=0.03)
    for k in range(0, len(inner) - 1, 8):  # struts tying the band to the core
        z = inner[k].z
        segment(twig, shaft_point(z, cfg), inner[k], 0.035, 0.035, sides=3)
    torus(trim, shaft_point(6.70, cfg), Vector((0, 0, 1)), 0.30, 0.05, seg_major=10, seg_minor=3)
    return _fim_tail(name, cfg, bms, tip_ring=True, butt="eye")


# Krakenheart (CROWN) - the best rod in the game: a TENTACLE coiled around the
# whole blank, thick at the butt and thinning as it climbs, sucker discs down
# its outer face, its last three fingers reaching off the tip to grip a
# glowing storm-pearl.
def build_krakenheart(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]
    core = lambda z: radius(z, cfg) * 0.78  # noqa: E731

    _fim_warp_tube(twig, cfg, steps=20, r_fn=core)
    pts = _fim_helix_pts(cfg, 1.80, 6.20, 2.6, lambda t: 0.16 + 0.15 * (1 - t), per_turn=9, r_fn=core)
    n = len(pts) - 1
    for i in range(n):
        segment(twig, pts[i], pts[i + 1], 0.22 - 0.13 * (i / n), 0.22 - 0.13 * ((i + 1) / n), sides=5)
    for i in range(0, n, 2):  # suckers on the tentacle's outward face
        p = pts[i]
        out = p - shaft_point(p.z, cfg)
        out.z = 0.0
        if out.length < 1e-5:
            continue
        out.normalize()
        _fim_disc(trim, p + out * (0.20 - 0.12 * (i / n)), out, 0.078 - 0.03 * (i / n), 0.022, sides=6)
    pearl = shaft_point(6.60, cfg) + UNDER * 0.34 + Vector((0, 0, 0.34))
    ball(trim, pearl, 0.30, segments=8)
    torus(trim, pearl, Vector((0.3, -0.4, 1.0)), 0.40, 0.035, seg_major=10, seg_minor=3)
    for i in range(3):  # the gripping fingers
        a = (i / 3) * math.tau + 0.5
        out = Vector((math.cos(a), math.sin(a) * 0.8 - 0.25, 0.0)).normalized()
        start = shaft_point(6.10, cfg) + out * 0.12
        _fim_taper_chain(twig, _fim_arc(start, pearl + out * 0.16 + Vector((0, 0, 0.14)), out * 0.6 + Vector((0, 0, 0.5)), 0.30, 6), 0.09, 0.035, sides=4)
    for z in (2.60, 3.90, 5.10):
        torus(trim, shaft_point(z, cfg), Vector((0, 0, 1)), core(z) + 0.05, 0.05, seg_major=8, seg_minor=4)
    return _fim_tail(name, cfg, bms, tip_ring=True, butt="curl", float_style="pearl")


# ---- gloom rods (a6) ----
# The five Gloomtrench rods (Lanternline / Trenchglass / Inkveil / Voidline /
# Gloomheart). Lightless deep sea: the only light a rod gets down there is the
# one it carries, so each of these is built around its own glow. They also each
# get their own blank silhouette - curl, facet, ribbon, skeleton, coil - so no
# two read alike in a lineup. The _gloom_* helpers below serve only this set.
#
# All five keep the shared frame: the blank follows spine()/radius() through the
# handle (so GRIP_CENTER is still the hand point and build_grip fits), tops out
# at ROD_LENGTH, and emits the full Twig/Grip/Trim/Line/BobberTop/BobberBottom
# set. Because their tips are bespoke, they hang the line with _gloom_hang()
# from wherever their own tip ended up rather than from tip_point().


def _gloom_frames(points):
    """Parallel-transported (u, v) cross-section frames along a polyline. Unlike
    calling frame_for() per point, these never flip when a curve swings through
    vertical - which the lantern stalk and the coil both do."""
    n = len(points)
    tangents = []
    for i in range(n):
        d = points[1] - points[0] if i == 0 else points[-1] - points[-2] if i == n - 1 else points[i + 1] - points[i - 1]
        tangents.append(d.normalized())
    u = Vector((1.0, 0.0, 0.0)) - tangents[0] * tangents[0].x
    if u.length < 1e-5:
        u = Vector((0.0, 1.0, 0.0)) - tangents[0] * tangents[0].y
    u.normalize()
    frames = []
    for t in tangents:
        u = u - t * u.dot(t)
        if u.length < 1e-5:
            u = t.cross(Vector((0.0, 0.0, 1.0)))
        u.normalize()
        frames.append((u.copy(), t.cross(u).normalized()))
    return tangents, frames


def _gloom_sweep(bm, points, radii, sides=5, flat=1.0, phase=0.0, cap_ends=True):
    """Sweep a polygonal tube along `points` with per-point radii."""
    _, frames = _gloom_frames(points)
    rings = [
        [bm.verts.new(p + u * (math.cos(a) * r) + v * (math.sin(a) * r * flat)) for a in ((i / sides) * math.tau + phase for i in range(sides))]
        for p, r, (u, v) in zip(points, radii, frames)
    ]
    for a, b in zip(rings, rings[1:]):
        bridge(bm, a, b)
    if cap_ends:
        bm.faces.new(list(reversed(rings[0])))
        bm.faces.new(rings[-1])
    return rings


def _gloom_tip(bm, rng, apex_point):
    """Close a sweep's last ring into a point (the blank's tip)."""
    apex = bm.verts.new(apex_point)
    n = len(rng)
    for i in range(n):
        bm.faces.new((rng[i], rng[(i + 1) % n], apex))


def _gloom_fin(bm, points, half_widths, thick):
    """A thin flat blade swept along `points` - Inkveil's trailing ribbons."""
    _, frames = _gloom_frames(points)
    rows = []
    for p, w, (u, v) in zip(points, half_widths, frames):
        rows.append([bm.verts.new(p + u * w + v * thick), bm.verts.new(p - u * w + v * thick), bm.verts.new(p - u * w - v * thick), bm.verts.new(p + u * w - v * thick)])
    for a, b in zip(rows, rows[1:]):
        bridge(bm, a, b)
    bm.faces.new(list(reversed(rows[0])))
    bm.faces.new(rows[-1])


def _gloom_hang(bm, cfg, tip):
    """The idle line, hung from a bespoke tip instead of tip_point(). Same
    length / tilt / bow knobs as line_path; returns the far end for the float."""
    line = cfg["line"]
    tilt = math.radians(line["tilt"])
    hang = Vector((0.0, -math.sin(tilt), -math.cos(tilt)))
    steps = 8
    pts = [tip + hang * (line["length"] * (i / steps)) + Vector((math.sin((i / steps) * math.pi) * line["bow"], 0.0, 0.0)) for i in range(steps + 1)]
    _gloom_sweep(bm, pts, [line["radius"]] * (steps + 1), sides=3)
    return pts[-1]


def _gloom_butt(bm, cfg, style):
    """Per-rod butts for the two gloom rods whose config asks for a "spike".
    The shared build_pommel's spike hangs to z = -0.55, which would stand these
    rods through the floor; both profiles here start at z >= 0.08, so nothing
    dips below the butt plane."""
    gr = cfg["grip_radius"]
    if style == "disc":  # Voidline: a flat void-disc, echoing its ring float
        lathe(bm, Vector((0, 0, 0)), [(0.0, 0.08), (gr * 0.55, 0.11), (gr * 0.6, 0.22), (0.0, 0.26)], cfg["sides"])
        torus(bm, Vector((0.0, 0.0, 0.17)), Vector((0.0, 0.0, 1.0)), gr * 1.15, 0.075, seg_major=10, seg_minor=4)
        for i in range(4):  # spokes out to the rim
            a = (i / 4) * math.tau + 0.4
            out = Vector((math.cos(a), math.sin(a), 0.0))
            segment(bm, Vector((0, 0, 0.17)) + out * (gr * 0.45), Vector((0, 0, 0.17)) + out * (gr * 1.15), 0.035, 0.035, sides=3)
    elif style == "knot":  # Gloomheart: a knotted polyp bulb, tendrils and all
        lathe(bm, Vector((0, 0, 0)), [(0.0, 0.1), (gr * 0.92, 0.17), (gr * 1.14, 0.35), (gr * 0.84, 0.51), (0.0, 0.57)], cfg["sides"])
        for i in range(4):
            a = (i / 4) * math.tau + 0.5
            knot = []
            for k in range(4):
                s = k / 3
                b = a + s * 2.2
                rr = gr * 0.95 + 0.16 * s
                knot.append(Vector((math.cos(b) * rr, math.sin(b) * rr, 0.26 + 0.3 * s)))
            _gloom_sweep(bm, knot, [0.075, 0.06, 0.045, 0.025], sides=3)


# Lanternline - the light-bearer: a dark cane whose top third curls forward like
# an anglerfish stalk, with a caged lantern bulb swinging under the curl and the
# line falling straight off it. Little glow-vine tendrils curl off the blank and
# the float is a tiny stoppered jar of the same light. Uncommon.
def build_lanternline(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]
    z0 = GRIP_END

    steps = 14
    pts, rads = [], []
    for i in range(steps + 1):
        t = i / steps
        z = z0 + (ROD_LENGTH - z0) * t
        curl = 1.35 * max(0.0, (t - 0.34) / 0.66) ** 2.3  # the stalk's bend, all in the top third
        # Bent forward AND across, so the stalk reads as a curl from the side as
        # well as in the hold (a purely forward bend foreshortens to nothing).
        pts.append(shaft_point(z, cfg) + Vector((-curl * 0.66, -curl * 0.75, 0.0)))
        rads.append(radius(z, cfg) * (1.0 - 0.22 * t))
    tangents, _ = _gloom_frames(pts)
    rings = _gloom_sweep(twig, pts, rads, sides=5, cap_ends=False)
    twig.faces.new(list(reversed(rings[0])))
    stalk_tip = pts[-1] + tangents[-1] * 0.2
    _gloom_tip(twig, rings[-1], stalk_tip)

    # Glow-vine tendrils curling off the blank (Twig).
    for i, ang in ((4, 0.9), (7, 4.0), (9, 2.1), (11, 5.2)):
        vine = []
        for k in range(4):
            s = k / 3
            a = ang + s * 2.1
            rr = rads[i] * 0.6 + 0.46 * s
            vine.append(pts[i] + Vector((math.cos(a) * rr, math.sin(a) * rr, -0.42 * s)))
        _gloom_sweep(twig, vine, [0.062, 0.05, 0.038, 0.022], sides=3)

    # The lantern: a bulb (Trim, glowing) swinging under the stalk in an iron cage (Twig).
    bulb = stalk_tip + Vector((0.0, 0.0, -0.62))
    segment(trim, stalk_tip, bulb + Vector((0.0, 0.0, 0.28)), 0.028, 0.028, sides=3)
    ball(trim, bulb, 0.26, segments=6)
    for dz in (0.28, -0.26):
        torus(twig, bulb + Vector((0.0, 0.0, dz)), Vector((0.0, 0.0, 1.0)), 0.2 if dz > 0 else 0.15, 0.035, seg_major=6, seg_minor=3)
    for i in range(4):
        a = (i / 4) * math.tau + 0.4
        out = Vector((math.cos(a), math.sin(a), 0.0))
        segment(twig, bulb + out * 0.2 + Vector((0.0, 0.0, 0.28)), bulb + out * 0.15 - Vector((0.0, 0.0, 0.26)), 0.026, 0.026, sides=3)

    # Guides: collars square to the blank, so they follow it around the curl.
    for i in (3, 6, 9, 12):
        torus(trim, pts[i], tangents[i], rads[i] + 0.085, 0.04, seg_major=6, seg_minor=3)

    build_grip(bms["Grip"], cfg)
    build_pommel(trim, cfg)
    end = _gloom_hang(bms["Line"], cfg, bulb - Vector((0.0, 0.0, 0.3)))
    # Float: a little stoppered jar with the same light shut inside it.
    jar = end - Vector((0.0, 0.0, 0.28))
    lathe(bms["BobberTop"], jar, [(0.0, 0.0), (0.18, 0.03), (0.15, 0.24), (0.08, 0.28), (0.0, 0.3)], 6)
    lathe(bms["BobberBottom"], jar, [(0.0, -0.26), (0.2, -0.2), (0.19, 0.01), (0.0, 0.03)], 6)
    return _finish(name, cfg, bms)


# Trenchglass - drawn from pressure-glass: five faceted crystal segments belled
# between pinched joints, each rotated off the last so the facets catch light
# differently, banded by metal collars, ending in a glowing prism spike behind a
# hex tip ring. The float is a cut gem, not a ball. Rare.
def build_trenchglass(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]
    z0 = GRIP_END
    segs = 4
    span = (ROD_LENGTH - z0) / segs

    for s in range(segs):
        za = z0 + span * s
        zb = za + span
        # Each segment is one long cut prism: pinched to nothing at the joints,
        # shouldered wide just past them, so the blank reads as stacked glass
        # blades rather than a cane. Five sides, rotated off the last segment.
        zsl = (za + 0.03, za + span * 0.16, za + span * 0.5, zb - span * 0.14, zb - 0.03)
        swell = (0.42, 1.85, 1.35, 1.7, 0.38)
        _gloom_sweep(
            twig,
            [shaft_point(z, cfg) for z in zsl],
            [radius(z, cfg) * k for z, k in zip(zsl, swell)],
            sides=5,
            flat=0.78,
            phase=0.63 * s,
        )
        # Metal collar clamping the joint below each segment.
        torus(trim, shaft_point(za, cfg), Vector((0.0, 0.0, 1.0)), radius(za, cfg) * 0.7 + 0.05, 0.085, seg_major=6, seg_minor=4)

    # Underside guides, kept small so the glass reads.
    for z in (2.6, 4.0, 5.4):
        r = radius(z, cfg)
        p = shaft_point(z, cfg)
        center = p + UNDER * (r + 0.17)
        segment(trim, p + UNDER * (r * 0.6), center, 0.028, 0.028, sides=3)
        torus(trim, center, Vector((0.0, 0.0, 1.0)), 0.13, 0.028, seg_major=6, seg_minor=3)

    # Prism tip: a glowing crystal spike through a hex ring (Trim).
    tipc = shaft_point(ROD_LENGTH, cfg)
    lathe(trim, tipc, [(0.0, -0.12), (0.13, 0.0), (0.09, 0.22), (0.0, 0.34)], 6)
    torus(trim, tipc + Vector((0.0, 0.0, 0.06)), Vector((1.0, 0.0, 0.0)), 0.15, 0.03, seg_major=6, seg_minor=3)

    build_grip(bms["Grip"], cfg)
    build_pommel(trim, cfg)
    if cfg["reel"]:
        build_reel(bms[cfg["reel"]["part"]], cfg)
    end = _gloom_hang(bms["Line"], cfg, tipc + Vector((0.0, 0.0, 0.34)))
    # Float: a riveted bathysphere - a little pressure hull slung by its eyelet,
    # portholes studded round the waterline.
    sph = end - Vector((0.0, 0.0, 0.3))
    lathe(bms["BobberTop"], sph, [(0.24, 0.0), (0.21, 0.16), (0.12, 0.27), (0.0, 0.3)], 8)
    torus(bms["BobberTop"], sph + Vector((0.0, 0.0, 0.3)), Vector((1.0, 0.0, 0.0)), 0.075, 0.025, seg_major=6, seg_minor=3)
    lathe(bms["BobberBottom"], sph, [(0.0, -0.3), (0.12, -0.27), (0.21, -0.16), (0.24, 0.0)], 8)
    for i in range(6):
        out = Vector((math.cos((i / 6) * math.tau + 0.3), math.sin((i / 6) * math.tau + 0.3), 0.0))
        segment(bms["BobberBottom"], sph + out * 0.19 - Vector((0.0, 0.0, 0.09)), sph + out * 0.27 - Vector((0.0, 0.0, 0.09)), 0.045, 0.032, sides=4)
    return _finish(name, cfg, bms)


# Inkveil - sleek and shrouded: a slim flattened blank trailing thin ink-ribbon
# veils that stream back and down its length, hardware swept backward like cloth
# in a current, and a single drop of ink for a float. Rare.
def build_inkveil(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]
    z0 = GRIP_END

    steps = 12
    pts = [shaft_point(z, cfg) for z in (z0 + (ROD_LENGTH - z0) * (i / steps) for i in range(steps + 1))]
    rads = [radius(z, cfg) * 0.74 for z in (z0 + (ROD_LENGTH - z0) * (i / steps) for i in range(steps + 1))]
    rings = _gloom_sweep(twig, pts, rads, sides=5, flat=0.72, cap_ends=False)
    twig.faces.new(list(reversed(rings[0])))
    _gloom_tip(twig, rings[-1], tip_point(cfg))

    # Ink-ribbon veils: long thin streamers peeling off the blank and trailing
    # astern, hugging it, waving as they fall - a shroud, not a set of barbs.
    for i, ang in ((2, 1.05), (4, 3.9), (6, 2.2), (8, 5.2), (10, 0.7)):
        out = Vector((math.cos(ang), math.sin(ang) * 0.7, 0.0)).normalized()
        wave = out.cross(Vector((0.0, 0.0, 1.0)))
        rib = []
        for k in range(5):
            s = k / 4
            rib.append(pts[i] + out * (rads[i] * 0.5 + 0.2 * s) - Vector((0.0, 0.0, 1.15 * s)) + wave * (0.16 * math.sin(s * 4.2)))
        _gloom_fin(twig, rib, [0.05, 0.13, 0.15, 0.11, 0.03], 0.016)

    # Hardware swept backward like cloth caught in a current (Trim).
    for z, ang in ((2.4, 1.15), (3.9, 4.3), (5.3, 2.0)):
        r = radius(z, cfg) * 0.74
        torus(trim, shaft_point(z, cfg), Vector((0.0, 0.0, 1.0)), r + 0.07, 0.038, seg_major=6, seg_minor=3)
        cone(trim, shaft_point(z, cfg) + Vector((math.cos(ang), math.sin(ang) * 0.7, 0.0)) * r, (Vector((math.cos(ang), math.sin(ang) * 0.7, 0.0)) + Vector((0.0, 0.0, -1.5))).normalized(), 0.3, 0.06, sides=4)
    build_tip_ring(trim, cfg)

    build_grip(bms["Grip"], cfg)
    build_pommel(trim, cfg)
    if cfg["reel"]:
        build_reel(bms[cfg["reel"]["part"]], cfg)
    end = _gloom_hang(bms["Line"], cfg, tip_point(cfg))
    # Float: an ink sac - a soft round drop with a wisp of ink trailing off it.
    sac = end - Vector((0.0, 0.0, 0.4))
    lathe(bms["BobberTop"], sac, [(0.22, 0.0), (0.2, 0.17), (0.12, 0.32), (0.0, 0.4)], 7)
    lathe(bms["BobberBottom"], sac, [(0.0, -0.66), (0.05, -0.46), (0.14, -0.23), (0.22, 0.0)], 7)
    return _finish(name, cfg, bms)


# Voidline - severe and skeletal: no blank at all, just twin thin rails bridged
# by rungs with daylight showing through the gaps, a void-purple glow seam
# burning down the slot between them, and a hollow ring for a float. Epic.
def build_voidline(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]
    z0 = GRIP_END
    top = ROD_LENGTH - 0.6

    steps = 11
    zs = [z0 + (top - z0) * (i / steps) for i in range(steps + 1)]
    rails = {}
    for sx in (-1, 1):
        pts = []
        for z in zs:
            t = (z - z0) / (top - z0)
            pts.append(shaft_point(z, cfg) + Vector((sx * (0.09 * (1.0 - t * t) + 0.095), 0.0, 0.0)))
        rails[sx] = pts
        _gloom_sweep(twig, pts, [radius(z, cfg) * 0.44 + 0.015 for z in zs], sides=4)

    # Rung bridges - the frame is open between them.
    for i in range(1, steps, 2):
        segment(twig, rails[-1][i], rails[1][i], 0.032, 0.032, sides=3)
    # The glow seam burning down the slot (Trim, neon), broken where rungs cross.
    for i in range(0, steps, 2):
        a = (rails[-1][i] + rails[1][i]) / 2
        b = (rails[-1][i + 1] + rails[1][i + 1]) / 2
        segment(trim, a + (b - a) * 0.12, a + (b - a) * 0.88, 0.045, 0.045, sides=4)

    # The rails close into a single spike above the frame.
    apex = tip_point(cfg)
    for sx in (-1, 1):
        segment(twig, rails[sx][-1], apex, 0.05, 0.02, sides=3)
    cone(trim, shaft_point(top, cfg), Vector((0.0, -cfg["hook"] * 0.6, 1.0)).normalized(), 0.55, 0.055, sides=4)

    build_grip(bms["Grip"], cfg)
    _gloom_butt(bms["Grip"], cfg, "disc")
    # An open ring reel, in keeping: a hoop on a stem, no drum.
    seat = shaft_point(1.55, cfg)
    hub = seat + UNDER * 0.5
    segment(trim, seat, hub, 0.05, 0.05, sides=4)
    torus(trim, hub, Vector((1.0, 0.0, 0.0)), 0.3, 0.05, seg_major=8, seg_minor=4)
    torus(trim, hub, Vector((1.0, 0.0, 0.0)), 0.12, 0.04, seg_major=6, seg_minor=3)

    end = _gloom_hang(bms["Line"], cfg, apex)
    # Float: a hollow ring, hung edge-on so it reads as a hoop, not a bead.
    ringc = end - Vector((0.0, 0.0, 0.34))
    torus(bms["BobberTop"], ringc, Vector((0.0, 1.0, 0.0)), 0.28, 0.07, seg_major=10, seg_minor=4)
    segment(bms["BobberBottom"], end, ringc + Vector((0.0, 0.0, 0.2)), 0.05, 0.08, sides=4)
    return _finish(name, cfg, bms)


# Gloomheart - the trench's crown: a coiled black blank that twists as it rises,
# wound its whole length by a glowing vine, twin tendrils curling off the grip,
# and near the tip a burning HEART orb cradled in a five-clawed anemone cage.
# The float is a smaller heart on the same line. Legendary.
def build_gloomheart(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]
    z0 = GRIP_END
    heart_z = 5.55

    steps = 18
    pts, rads, zs = [], [], []
    for i in range(steps + 1):
        t = i / steps
        z = z0 + (ROD_LENGTH - z0) * t
        a = t * math.tau * 1.15
        amp = 0.15 * math.sin(math.pi * min(1.0, t * 1.1))  # the coil, dying out at both ends
        zs.append(z)
        pts.append(shaft_point(z, cfg) + Vector((math.cos(a) * amp, math.sin(a) * amp * 0.55, 0.0)))
        rads.append(radius(z, cfg) * 1.05)
    tangents, _ = _gloom_frames(pts)
    rings = _gloom_sweep(twig, pts, rads, sides=6, cap_ends=False)
    twig.faces.new(list(reversed(rings[0])))
    _gloom_tip(twig, rings[-1], pts[-1] + tangents[-1] * 0.28)

    # Glow-vine spiralling the whole blank (Trim, neon).
    turns, per = 6, 6
    m = turns * per
    vine = []
    for k in range(m + 1):
        t = k / m
        idx = t * steps
        i0 = min(steps - 1, int(idx))
        c = pts[i0] + (pts[i0 + 1] - pts[i0]) * (idx - i0)
        rr = (rads[i0] + 0.075) * 1.0
        a = t * turns * math.tau + 0.6
        vine.append(c + Vector((math.cos(a) * rr, math.sin(a) * rr, 0.0)))
    for i in range(m):
        segment(trim, vine[i], vine[i + 1], 0.04, 0.04, sides=3)

    # Twin tendrils curling off the grip collar (Twig).
    for sx in (-1, 1):
        curl = []
        for k in range(4):
            s = k / 3
            a = (0.6 if sx > 0 else 3.7) + s * 2.0 * sx
            rr = 0.2 + 0.36 * s
            curl.append(shaft_point(z0 + 0.12, cfg) + Vector((math.cos(a) * rr, math.sin(a) * rr, 0.3 * s - 0.18 * s * s * 3)))
        _gloom_sweep(twig, curl, [0.07, 0.055, 0.04, 0.024], sides=3)

    # The heart: a big burning orb (Trim) cradled in five claws (Twig).
    heart_i = min(range(len(zs)), key=lambda i: abs(zs[i] - heart_z))
    heart = pts[heart_i]
    ball(trim, heart, 0.44, segments=8)
    for i in range(5):
        a = (i / 5) * math.tau + 0.35
        out = Vector((math.cos(a), math.sin(a), 0.0))
        claw = [heart + out * 0.14 - Vector((0.0, 0.0, 0.66)), heart + out * 0.64 - Vector((0.0, 0.0, 0.2)), heart + out * 0.68 + Vector((0.0, 0.0, 0.34)), heart + out * 0.3 + Vector((0.0, 0.0, 0.78))]
        _gloom_sweep(twig, claw, [0.085, 0.07, 0.055, 0.03], sides=3)

    build_grip(bms["Grip"], cfg)
    _gloom_butt(bms["Grip"], cfg, "knot")
    if cfg["reel"]:
        build_reel(bms[cfg["reel"]["part"]], cfg)
    end = _gloom_hang(bms["Line"], cfg, pts[-1] + tangents[-1] * 0.28)
    # Float: a smaller heart in the same cradle, so the set's crown matches itself.
    core = end - Vector((0.0, 0.0, 0.3))
    ball(bms["BobberTop"], core, 0.24, segments=7)
    for i in range(3):
        a = (i / 3) * math.tau + 0.4
        out = Vector((math.cos(a), math.sin(a), 0.0))
        segment(bms["BobberBottom"], core + out * 0.1 - Vector((0.0, 0.0, 0.3)), core + out * 0.3 + Vector((0.0, 0.0, 0.12)), 0.05, 0.035, sides=3)
    return _finish(name, cfg, bms)


# ---- end gloom rods (a6) ----


# ---- wreck rods (87) ----
# The five Wreckwater rods, cut from a ghost fleet's salvage: a hull plank, a
# topmast with its working tackle, drowned gold, a rigged sail, and the
# flagship's caged ghost-fire heart. Each carries one signature nothing else in
# the pack has - nail guides / a block-and-tackle / a doubloon charm chain /
# sailcloth pennants / a heart in a rib cage - so they read apart at a glance.
# Local helpers are _wr2_-prefixed; everything else is the shared kit.


def _wr2_poly(bm, points, r0, r1=None, sides=4):
    """A tapered polyline of capped frusta: bent nails, chain, cage ribs."""
    r1 = r0 if r1 is None else r1
    n = max(len(points) - 1, 1)
    for i in range(n):
        segment(bm, points[i], points[i + 1], r0 + (r1 - r0) * (i / n), r0 + (r1 - r0) * ((i + 1) / n), sides=sides)


def _wr2_disc(bm, center, normal, r, thick, sides=8):
    """A flat struck disc facing `normal`: coins, sheaves, block cheeks."""
    d, u, v = frame_for(normal)
    rings = []
    for s in (-0.5, 0.5):
        c = center + d * (thick * s)
        rings.append([bm.verts.new(c + (u * math.cos(a) + v * math.sin(a)) * r) for a in ((i / sides) * math.tau for i in range(sides))])
    bridge(bm, rings[0], rings[1])
    bm.faces.new(list(reversed(rings[0])))
    bm.faces.new(rings[1])


# --- Ghostplank ------------------------------------------------------------
# Hewn from a hull plank and still shaped like one: a squared blank that steps
# down at each hewing seam, iron straps bolted round it, and - the signature -
# BENT NAILS driven through the underside as line guides. Crude carpentry.


def _wr2_plank_point(z, cfg):
    """The plank dried warped: a slow S out of the sawn line, worst at the tip."""
    p = shaft_point(z, cfg)
    t = max(z, 0.0) / ROD_LENGTH
    p.x += 0.07 * math.sin(t * 5.0) * t
    p.y += 0.07 * math.sin(t * 3.3 + 1.0) * t * t
    return p


_WR2_PLANK_STEPS = 4


def _wr2_plank_r(z, cfg):
    """Hewn down in flats, so the taper happens at a few seams, not smoothly."""
    t = min(max(z, 0.0), ROD_LENGTH) / ROD_LENGTH
    k = min(int(t * _WR2_PLANK_STEPS), _WR2_PLANK_STEPS - 1)
    return radius(((k + 0.5) / _WR2_PLANK_STEPS) * ROD_LENGTH, cfg)


def _wr2_nail(bm, p, r, length=0.26):
    """A nail driven through the plank and bent back up into a hook - the line
    runs through the gap under the hook. Ghostplank's guides are literally nails."""
    _wr2_disc(bm, p + UNDER * (r * 0.3), UNDER, 0.1, 0.05, sides=5)  # the struck head
    shank = p + UNDER * (r + length)
    _wr2_poly(bm, [p + UNDER * (r * 0.3), shank, shank + Vector((0, -0.05, 0.26))], 0.042, 0.03, sides=4)


def build_ghostplank(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]

    # The plank blank: a squared section that steps down at every hewing seam.
    stations = []
    for k in range(_WR2_PLANK_STEPS):
        z0 = (k / _WR2_PLANK_STEPS) * ROD_LENGTH
        z1 = ((k + 1) / _WR2_PLANK_STEPS) * ROD_LENGTH
        r = _wr2_plank_r((z0 + z1) * 0.5, cfg)
        for z in (z0, z1):
            p = _wr2_plank_point(z, cfg)
            stations.append((p.x, p.y, z, r))
    rings = tube(twig, stations, 4, phase=math.pi / 4, flatten=cfg["flatten"])
    twig.faces.new(list(reversed(rings[0])))
    twig.faces.new(rings[-1])  # a sawn-off end, not a point
    # A proud lip at every hewing seam, so the steps read as worked timber.
    for k in range(1, _WR2_PLANK_STEPS):
        zs = (k / _WR2_PLANK_STEPS) * ROD_LENGTH
        r = _wr2_plank_r(zs - 0.05, cfg) + 0.035
        st = []
        for zz in (zs - 0.06, zs + 0.02):
            p = _wr2_plank_point(zz, cfg)
            st.append((p.x, p.y, zz, r))
        rg = tube(twig, st, 4, phase=math.pi / 4, flatten=cfg["flatten"])
        twig.faces.new(list(reversed(rg[0])))
        twig.faces.new(rg[-1])
    # Split-out slivers along the edges, where the plank was prised off the hull.
    for z, sx in ((1.95, 1), (3.05, -1), (4.35, 1), (5.45, -1), (6.3, 1)):
        p = _wr2_plank_point(z, cfg)
        out = Vector((sx, -0.2, 0.0)).normalized()
        cone(twig, p + out * (_wr2_plank_r(z, cfg) * 0.85), (out * 0.55 + Vector((0, 0, 1))).normalized(), 0.44, 0.055, sides=3)

    # Iron straps, bolted through: squared bands with a bolt head each side.
    for z, w in cfg["bands"]:
        r = _wr2_plank_r(z, cfg) + 0.05
        st = []
        for zz in (z - w / 2, z + w / 2):
            p = _wr2_plank_point(zz, cfg)
            st.append((p.x, p.y, zz, r))
        rg = tube(trim, st, 4, phase=math.pi / 4, flatten=cfg["flatten"])
        trim.faces.new(list(reversed(rg[0])))
        trim.faces.new(rg[-1])
        c = _wr2_plank_point(z, cfg)
        for sx in (-1, 1):
            _wr2_disc(trim, c + Vector((sx * (r + 0.01), 0, 0)), Vector((sx, 0, 0)), 0.06, 0.035, sides=5)

    # Nail heads driven flush through the plank's face, off the strap corners.
    for z, sx in ((2.25, -1), (3.9, 1), (5.35, -1), (6.2, 1)):
        p = _wr2_plank_point(z, cfg)
        face = p + Vector((sx * _wr2_plank_r(z, cfg) * 0.55, -_wr2_plank_r(z, cfg) * cfg["flatten"], 0))
        _wr2_disc(trim, face, UNDER, 0.075, 0.04, sides=5)

    # The signature: bent-nail line guides.
    for z in cfg["guides"]:
        _wr2_nail(trim, _wr2_plank_point(z, cfg), _wr2_plank_r(z, cfg) * cfg["flatten"])
    _wr2_nail(trim, _wr2_plank_point(6.6, cfg), _wr2_plank_r(6.6, cfg) * cfg["flatten"], length=0.2)  # the tip nail the line leaves by

    build_grip(bms["Grip"], cfg)
    build_pommel(trim, cfg)
    build_line(bms["Line"], cfg)
    build_float(bms["BobberTop"], bms["BobberBottom"], cfg)
    return _finish(name, cfg, bms)


# --- Riggingline -----------------------------------------------------------
# A salvaged topmast: a round blank served in neat rope whippings, ratline-style
# DOUBLE guide pairs rung together, a crow's-nest ring near the head, and - the
# signature - a working BLOCK-AND-TACKLE slung under the mid-blank with the line
# threading round its sheave before it runs up the guides.


def _wr2_serving(bm, z, cfg, turns=2):
    """A rope whipping: tight turns lying side by side, the way a mast is served."""
    for i in range(turns):
        zz = z + (i - (turns - 1) * 0.5) * 0.1
        torus(bm, shaft_point(zz, cfg), Vector((0, 0, 1)), radius(zz, cfg) + 0.055, 0.045, seg_major=6, seg_minor=3)


def _wr2_ratline_pair(bm, z, cfg):
    """Two guide loops abreast with a rung between them, like a ratline."""
    r = radius(z, cfg)
    p = shaft_point(z, cfg)
    loop_r = 0.07 + r * 0.4
    centers = []
    for sx in (-1, 1):
        foot = p + UNDER * (r * 0.6) + Vector((sx * r * 0.45, 0, 0))
        c = p + UNDER * (r + loop_r + 0.05) + Vector((sx * (loop_r + 0.02), 0, 0))
        segment(bm, foot, c - UNDER * loop_r * 0.5, 0.026, 0.026, sides=3)
        torus(bm, c, Vector((0, 0, 1)), loop_r, 0.028, seg_major=6, seg_minor=3)
        centers.append(c)
    segment(bm, centers[0], centers[1], 0.024, 0.024, sides=3)
    return (centers[0] + centers[1]) * 0.5


def _wr2_block(bm, cfg, z, r=0.3):
    """The pulley block: two cheeks around a sheave, strop over the top, becket
    below, hung off the blank on a short strap. Returns the sheave centre."""
    seat = shaft_point(z, cfg)
    c = seat + UNDER * (radius(z, cfg) + 0.14 + r)
    segment(bm, seat + UNDER * (radius(z, cfg) * 0.5), c - UNDER * (r * 0.2), 0.055, 0.055, sides=4)
    for sx in (-1, 1):
        _wr2_disc(bm, c + Vector((sx * 0.1, 0, 0)), Vector((1, 0, 0)), r, 0.06, sides=7)
    _wr2_disc(bm, c, Vector((1, 0, 0)), r * 0.66, 0.14, sides=7)  # the sheave
    torus(bm, c, Vector((1, 0, 0)), r + 0.05, 0.035, seg_major=8, seg_minor=3)  # the strop
    torus(bm, c - Vector((0, 0, r + 0.16)), Vector((1, 0, 0)), 0.1, 0.03, seg_major=6, seg_minor=3)  # the becket
    return c, r * 0.66 + 0.035


def _wr2_crows_nest(bm, z, cfg):
    """A little top: two hoops on four stanchions, near the masthead."""
    p = shaft_point(z, cfg)
    r = 0.28
    for dz, minor in ((0.0, 0.04), (0.19, 0.03)):
        torus(bm, p + Vector((0, 0, dz)), Vector((0, 0, 1)), r, minor, seg_major=6, seg_minor=3)
    for i in range(3):
        a = (i / 3) * math.tau + 0.4
        o = Vector((math.cos(a), math.sin(a), 0)) * r
        segment(bm, p + o, p + o + Vector((0, 0, 0.19)), 0.028, 0.028, sides=3)


def build_riggingline(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim, line = bms["Twig"], bms["Trim"], bms["Line"]
    sides = cfg["sides"]

    steps = 10
    stations = [(*spine(z, cfg), z, radius(z, cfg)) for z in ((i / steps) * ROD_LENGTH for i in range(steps + 1))]
    rings = tube(twig, stations, sides)
    _cap_tube_tip(twig, rings, cfg, sides)

    for z, _w in cfg["bands"]:
        _wr2_serving(trim, z, cfg)
    guide_centers = [_wr2_ratline_pair(trim, z, cfg) for z in cfg["guides"]]
    _wr2_crows_nest(trim, 6.15, cfg)
    build_tip_ring(trim, cfg)
    build_grip(bms["Grip"], cfg)
    build_pommel(trim, cfg)
    if cfg["reel"]:
        build_reel(bms[cfg["reel"]["part"]], cfg)

    # The signature: the line comes off the becket, wraps the block's sheave,
    # then runs up through every ratline pair and over the tip.
    block_c, wrap_r = _wr2_block(trim, cfg, 3.05)
    rove = [block_c - Vector((0, 0, wrap_r + 0.12))]
    for deg in (200, 250, 300, 345, 25):
        a = math.radians(deg)
        rove.append(block_c + Vector((0, -math.sin(a) * wrap_r, math.cos(a) * wrap_r)))
    rove.extend(guide_centers)
    rove.append(tip_point(cfg))
    _wr2_poly(line, rove, cfg["line"]["radius"], sides=3)
    build_line(line, cfg)
    build_float(bms["BobberTop"], bms["BobberBottom"], cfg)
    return _finish(name, cfg, bms)


# --- Doubloon --------------------------------------------------------------
# The treasure rod: a dark drowned-oak blank inlaid with coin bosses, a reel
# whose drum is a stack of struck coins, and - the signature - a DOUBLOON CHARM
# CHAIN of gold discs swinging off the tip ring.


def _wr2_coin(bm, center, normal, r, thick=0.05):
    """A struck coin: a disc with a raised rim so it catches light edge-on."""
    _wr2_disc(bm, center, normal, r, thick, sides=8)
    torus(bm, center, normal, r - 0.02, 0.022, seg_major=8, seg_minor=3)


def _wr2_charm_chain(bm, top, count=3):
    """Doubloons on a short chain, hung off the tip ring and left to swing."""
    face = Vector((0, 1.0, 0.22))
    p = top
    for i in range(count):
        link = p - Vector((0, 0.03, 0.1))
        torus(bm, link, Vector((0, 1, 0)), 0.05, 0.02, seg_major=6, seg_minor=3)
        c = link - Vector((0, 0.03, 0.21))
        _wr2_coin(bm, c, face, 0.15 - i * 0.018, 0.045)
        p = c - Vector((0, 0, 0.16))


def _wr2_coin_drum(bm, cfg, z):
    """The reel drum, built as a stack of coins on a spindle."""
    seat = shaft_point(z, cfg)
    sr = radius(z, cfg)
    drum = seat + UNDER * (sr + 0.44)
    segment(bm, seat + UNDER * (sr * 0.5), drum, 0.08, 0.08, sides=5)
    axis = Vector((1, 0, 0))
    for i in range(4):
        _wr2_disc(bm, drum + axis * ((i - 1.5) * 0.1), axis, 0.29 - abs(i - 1.5) * 0.03, 0.09, sides=7)
    segment(bm, drum - axis * 0.3, drum + axis * 0.36, 0.045, 0.045, sides=4)
    knob = drum + axis * 0.36
    segment(bm, knob, knob + Vector((0, 0, 0.24)), 0.05, 0.05, sides=4)


def build_doubloon(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]
    sides = cfg["sides"]

    steps = 13
    stations = [(*spine(z, cfg), z, radius(z, cfg)) for z in ((i / steps) * ROD_LENGTH for i in range(steps + 1))]
    rings = tube(twig, stations, sides, flatten=cfg["flatten"])
    _cap_tube_tip(twig, rings, cfg, sides)

    # Coin bosses inlaid into the blank, canted alternately off the face.
    for i, z in enumerate((2.25, 3.05, 3.85, 4.65, 5.35)):
        sx = 1 if i % 2 else -1
        out = Vector((sx * 0.55, -0.84, 0.0)).normalized()
        _wr2_disc(trim, shaft_point(z, cfg) + out * (radius(z, cfg) * 0.7), out, 0.165 - i * 0.012, 0.05, sides=8)
    build_bands(trim, cfg)
    build_guides(trim, cfg)
    build_tip_ring(trim, cfg)
    build_grip(bms["Grip"], cfg)
    build_pommel(trim, cfg)
    _wr2_coin_drum(trim, cfg, cfg["reel"]["z"])
    # The signature: the charm chain, off the underside of the tip ring.
    _wr2_charm_chain(trim, tip_point(cfg) - Vector((0, 0, cfg["radius_tip"] + 0.05)))

    build_line(bms["Line"], cfg)
    build_float(bms["BobberTop"], bms["BobberBottom"], cfg)
    return _finish(name, cfg, bms)


# --- Sailcloth -------------------------------------------------------------
# The wind rod: a raked blank carried like a mast under way, a cleat and halyard
# at the grip, and - the signature - three SAILCLOTH PENNANTS bellied out along
# the upper blank.


def _wr2_pennant(bm, luff_lo, luff_hi, clew, belly, thick=0.035):
    """A small triangular sail: a four-cornered panel bellied out to leeward,
    given a little thickness so it reads from either side."""
    poly = [luff_lo, luff_hi, (luff_hi + clew) * 0.5 + belly, clew]
    n = (luff_hi - luff_lo).cross(clew - luff_lo)
    n = n.normalized() if n.length > 1e-6 else Vector((0, 1, 0))
    a = [bm.verts.new(p + n * (thick * 0.5)) for p in poly]
    b = [bm.verts.new(p - n * (thick * 0.5)) for p in poly]
    bridge(bm, a, b)
    bm.faces.new(a)
    bm.faces.new(list(reversed(b)))


def build_sailcloth(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim = bms["Twig"], bms["Trim"]
    sides = cfg["sides"]

    steps = 14
    stations = [(*spine(z, cfg), z, radius(z, cfg)) for z in ((i / steps) * ROD_LENGTH for i in range(steps + 1))]
    rings = tube(twig, stations, sides, flatten=cfg["flatten"])
    _cap_tube_tip(twig, rings, cfg, sides)

    build_bands(trim, cfg)
    build_guides(trim, cfg)
    build_tip_ring(trim, cfg)
    build_grip(bms["Grip"], cfg)
    build_pommel(trim, cfg)
    if cfg["reel"]:
        build_reel(bms[cfg["reel"]["part"]], cfg)

    # The signature: pennant sails set along the blank, smaller as they go up.
    heads = []
    for z0, hgt, chord in ((2.75, 0.95, 0.95), (4.20, 0.80, 0.78), (5.50, 0.62, 0.58)):
        lo = shaft_point(z0, cfg) + Vector((0.06, 0, 0))
        hi = shaft_point(z0 + hgt, cfg) + Vector((0.06, 0, 0))
        clew = lo + Vector((chord, -0.1, hgt * 0.25))
        _wr2_pennant(trim, lo, hi, clew, Vector((0, -0.22, 0)))
        segment(trim, lo, hi, 0.022, 0.02, sides=3)  # the luff rope
        heads.append(hi)

    # Cleat and halyard at the grip: the sails are actually made fast to it.
    cleat = shaft_point(GRIP_END - 0.12, cfg) + Vector((cfg["grip_radius"] * 0.9, 0, 0))
    segment(trim, cleat - Vector((0.1, 0, 0)), cleat + Vector((0.08, 0, 0)), 0.045, 0.045, sides=4)
    segment(trim, cleat + Vector((0.05, 0, -0.11)), cleat + Vector((0.05, 0, 0.11)), 0.035, 0.035, sides=4)
    _wr2_poly(trim, [cleat + Vector((0.05, 0, 0.08)), (cleat + heads[0]) * 0.5 + Vector((0.1, -0.04, 0)), heads[0]], 0.022, 0.018, sides=3)

    build_line(bms["Line"], cfg)
    build_float(bms["BobberTop"], bms["BobberBottom"], cfg)
    return _finish(name, cfg, bms)


# --- Wraithheart -----------------------------------------------------------
# The island's crown: a spectral flagship's mast. Ghost-fire streamers wisp off
# the blank, a spoked ship's wheel serves as the reel, a drowned figurehead
# leans out of the butt - and the signature, a GHOST-FIRE HEART CAGED AT THE TIP,
# an ellipsoid core burning inside an open cage of curved ribs.


def _wr2_ellipsoid(bm, center, rx, rz, segments=8):
    profile = [(0.0, -rz)]
    for k in range(1, 6):
        a = -math.pi / 2 + (k / 6) * math.pi
        profile.append((rx * math.cos(a), rz * math.sin(a)))
    profile.append((0.0, rz))
    lathe(bm, center, profile, segments)


def _wr2_wisp(bm, base, out, length, r=0.06):
    """A streamer of ghost-fire peeling off the blank and curling back on itself."""
    pts = []
    for i in range(6):
        t = i / 5
        pts.append(base + out * (math.sin(t * math.pi) * length * 0.62) + Vector((0, 0, t * length * 1.5)))
    pts.append(pts[-1] + out * (length * 0.3) + Vector((0, 0, length * 0.35)))  # the tail flicking off
    _wr2_poly(bm, pts, r, r * 0.25, sides=3)


def _wr2_ships_wheel(bm, cfg, z, r=0.34):
    """A spoked ship's wheel where the reel should be, handles and all."""
    seat = shaft_point(z, cfg)
    sr = radius(z, cfg)
    hub = seat + UNDER * (sr + 0.46)
    segment(bm, seat + UNDER * (sr * 0.5), hub, 0.08, 0.08, sides=5)
    axis = Vector((1, 0, 0))
    _wr2_disc(bm, hub, axis, 0.12, 0.17, sides=6)
    torus(bm, hub, axis, r, 0.045, seg_major=10, seg_minor=3)
    for i in range(6):
        a = (i / 6) * math.tau + 0.3
        o = Vector((0, math.cos(a), math.sin(a)))
        segment(bm, hub + o * 0.1, hub + o * (r + 0.17), 0.035, 0.035, sides=3)


def _wr2_figurehead(bm, cfg):
    """The drowned figurehead at the butt: a bust leaning out under the grip,
    hair still streaming as if the ship were making way."""
    gr = cfg["grip_radius"]
    lathe(bm, Vector((0, 0, 0)), [(0.0, 0.02), (gr * 0.7, 0.02), (gr * 1.05, 0.12), (gr * 0.95, 0.28), (0.0, 0.34)], 6)
    lean = Vector((0, -0.85, 0.42)).normalized()  # out over the 'prow' and RISING - nothing may dip under the butt plane (harness find)
    neck = Vector((0, 0, 0.18))  # the leaning cone's tilted base ring dips ~0.15 below the mount - keep it clear of z=0
    cone(bm, neck, lean, 0.6, 0.19, sides=6)
    head = neck + lean * 0.56
    ball(bm, head, 0.14, segments=6)
    for sx in (-1, 1):
        cone(bm, head, Vector((sx * 0.45, 0.6, 0.66)).normalized(), 0.44, 0.07, sides=4)


def build_wraithheart(name, cfg):
    bms = {p: bmesh.new() for p in PART_NAMES}
    twig, trim, grip = bms["Twig"], bms["Trim"], bms["Grip"]
    sides = cfg["sides"]

    steps = 15
    stations = [(*spine(z, cfg), z, radius(z, cfg)) for z in ((i / steps) * ROD_LENGTH for i in range(steps + 1))]
    rings = tube(twig, stations, sides, flatten=cfg["flatten"])
    _cap_tube_tip(twig, rings, cfg, sides)

    # Ghost-fire streamers curling off the blank, biggest low, fading upward.
    for z, sx, length in ((2.5, -1, 0.85), (3.15, 1, 0.78), (3.9, -1, 0.7), (4.6, 1, 0.62), (5.3, -1, 0.53), (5.95, 1, 0.44)):
        out = Vector((sx * 0.94, -0.34, 0.0)).normalized()
        _wr2_wisp(trim, shaft_point(z, cfg) + out * radius(z, cfg), out, length, r=0.075)
    for z in (3.0, 4.0, 5.0, 5.9):
        torus(trim, shaft_point(z, cfg), Vector((0, 0, 1)), radius(z, cfg) * cfg["flatten"] + 0.09, 0.045, seg_major=8, seg_minor=3)

    # THE SIGNATURE: the ghost-fire heart, caged in ribs above the masthead.
    tip = shaft_point(ROD_LENGTH, cfg)
    up = (tip_point(cfg) - shaft_point(ROD_LENGTH - 0.5, cfg)).normalized()
    heart = tip + up * 0.30
    collar = heart - Vector((0, 0, 0.44))
    finial = heart + Vector((0, 0, 0.32))
    _wr2_ellipsoid(trim, heart, 0.27, 0.35, segments=8)
    torus(trim, collar, Vector((0, 0, 1)), 0.17, 0.045, seg_major=8, seg_minor=3)
    for i in range(5):
        a = (i / 5) * math.tau + 0.3
        o = Vector((math.cos(a), math.sin(a), 0.0))
        _wr2_poly(
            trim,
            [collar + o * 0.15, collar + o * 0.42 + Vector((0, 0, 0.22)), heart + o * 0.5, finial + o * 0.38 - Vector((0, 0, 0.2)), finial + o * 0.08],
            0.055,
            0.04,
            sides=3,
        )
    cone(trim, finial, Vector((0, 0, 1)), 0.24, 0.085, sides=5)

    build_grip(grip, cfg)
    _wr2_ships_wheel(grip, cfg, cfg["reel"]["z"])
    _wr2_figurehead(grip, cfg)
    build_line(bms["Line"], cfg)
    build_float(bms["BobberTop"], bms["BobberBottom"], cfg)
    return _finish(name, cfg, bms)


# ---- end wreck rods (87) ----


BESPOKE = {
    # cove + volcano (frozen)
    "Bonecaster": build_bonecaster,
    "Voltline": build_voltline,
    "Brineheart": build_brineheart,
    "PhoenixAsh": build_phoenix_ash,
    "Lanternline": build_lanternline,
    "Trenchglass": build_trenchglass,
    "Inkveil": build_inkveil,
    "Voidline": build_voidline,
    "Gloomheart": build_gloomheart,
    # fen (0f)
    "Reedlash": build_reedlash,
    "Gatorback": build_gatorback,
    "Wisplight": build_wisplight,
    "Fenpiercer": build_fenpiercer,
    "Mireheart": build_mireheart,
    # ice (0f)
    "Auger": build_auger,
    "Rimebound": build_rimebound,
    "Silverscale": build_silverscale,
    "Aurora": build_aurora,
    "Frostheart": build_frostheart,
    # wreck (87)
    "Ghostplank": build_ghostplank,
    "Riggingline": build_riggingline,
    "Doubloon": build_doubloon,
    "Sailcloth": build_sailcloth,
    "Wraithheart": build_wraithheart,
    # maelstrom (0f)
    "Squallcaster": build_squallcaster,
    "Riptide": build_riptide,
    "Thunderhead": build_thunderhead,
    "Eyewall": build_eyewall,
    "Krakenheart": build_krakenheart,
}


# ---------------------------------------------------------------- preview


def render_preview(variant_objects, out_png):
    scene = bpy.context.scene
    # "BLENDER_EEVEE_NEXT" is the newer Blender's engine id, but the
    # `hasattr(bpy.types, "SceneEEVEE")` probe misdetects on some builds
    # (Blender 5.2 LTS keeps SceneEEVEE for compat while only accepting
    # "BLENDER_EEVEE" as the enum value) - try the modern id, fall back if
    # the running Blender rejects it.
    try:
        scene.render.engine = "BLENDER_EEVEE_NEXT"
    except TypeError:
        scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_y = 1000
    scene.render.filepath = out_png

    world = bpy.data.worlds.new("W")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.36, 0.40, 0.47, 1)
    scene.world = world
    scene.view_settings.view_transform = "Standard"

    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.data.energy = 4
    sun.rotation_euler = (math.radians(55), math.radians(15), math.radians(35))
    bpy.context.collection.objects.link(sun)

    # Spread the rods out along X and look at them from a front-left 3/4 so
    # the underside hardware (guides, reels) silhouettes.
    spacing = 3.2
    names = list(variant_objects.keys())
    width = max(1.0, (len(names) - 1) * spacing)
    for i, nm in enumerate(names):
        for obj in variant_objects[nm]:
            obj.location.x += (i - (len(names) - 1) / 2) * spacing

    # Camera distance (and resolution width) scale with the lineup's width
    # so every variant stays in frame no matter how many get added - ratio
    # tuned to the original 8-variant framing (distance 34 at width 22.4).
    reference_width = 22.4
    distance = max(34.0, width * (34.0 / reference_width))
    scene.render.resolution_x = min(4096, round(1400 * width / reference_width))

    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    bpy.context.collection.objects.link(cam)
    scene.camera = cam
    cam.location = Vector((0.0, -distance, 5.4))
    target = Vector((0.0, 0.0, 3.4))
    cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
    cam.data.lens = 40

    bpy.ops.render.render(write_still=True)
    print("[rod_gen] preview ->", out_png)


# ---------------------------------------------------------------- export


def main():
    argv = sys.argv[sys.argv.index("--") + 1 :]
    out_path = argv[0]
    want_preview = len(argv) > 1 and argv[1] == "preview"

    clear_scene()

    variant_objects = {}
    for name, cfg in VARIANTS.items():
        builder = BESPOKE.get(name)  # a few rods have bespoke geometry; the rest use the config builder
        variant_objects[name] = builder(name, cfg) if builder else build_variant(name, cfg)

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

    total = sum(len(o.data.polygons) for objs in variant_objects.values() for o in objs)
    print(f"[rod_gen] exported {out_path}")
    for nm, objs in variant_objects.items():
        print(f"[rod_gen]   {nm}: {[o.name.split('_', 1)[1] for o in objs]} ({sum(len(o.data.polygons) for o in objs)} polys)")
    print(f"[rod_gen] grip centre z = {GRIP_CENTER:.2f}, length = {ROD_LENGTH:.1f} (Rods.luau must match)")
    print(f"[rod_gen] polys: {total}")

    if want_preview:
        import os

        render_preview(variant_objects, os.path.abspath("assets/rod_preview.png"))


main()
