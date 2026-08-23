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
    # Abyssal rod - forged for the deep: a flattened black-iron blade that
    # curls forward into a hook at the tip, backswept barbs, glowing teal
    # collars and tip ring, a spiked iron reel, a pommel spike, and an
    # anglerfish lantern for a lure - a glowing orb in an iron cage.
    "Abyssal": {
        "radius_butt": 0.26,
        "radius_tip": 0.07,
        "sides": 6,
        "flatten": 0.55,
        "lean": 0.10,
        "kink": 0.04,
        "hook": 0.95,
        "grip_style": "wrapped",
        "grip_radius": 0.34,
        "nodes": 0,
        "node_amp": 0.0,
        "cones": [(4.2, 1.3, 0.46, -0.8), (5.0, 4.6, 0.42, -0.8), (5.7, 2.9, 0.34, -0.8), (6.3, 0.4, 0.26, -0.9)],
        "bands": [(2.4, 0.1), (3.4, 0.1), (4.5, 0.09), (5.4, 0.08), (6.1, 0.07)],
        "guides": [2.4, 3.4, 4.5, 5.4, 6.1],
        "guide_style": "collar",
        "tip_ring": True,
        "reel": {"style": "spiked", "part": "Grip", "z": 1.5},
        "pommel": "spike",
        "line": {"length": 2.4, "tilt": 30, "bow": 0.06, "radius": 0.034},
        "float": "lantern",
        "neon": ["Trim", "BobberTop"],  # preview-only glow; the game reads Rods.luau model.neon
        "colors": {
            "twig": (0.16, 0.17, 0.24),
            "grip": (0.12, 0.13, 0.18),
            "trim": (0.25, 0.88, 0.82),
            "line": (0.24, 0.27, 0.35),
            "top": (0.35, 0.94, 0.86),
            "bottom": (0.11, 0.12, 0.16),
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
    # A Voltray's organ wound into a dark blank: straight, taut and hard, with
    # nacre collars up the shaft and a crackling quill float. The fastest bar
    # in the game, so the silhouette is a lean whip - no nodes, little bow.
    # Epic.
    "Voltline": {
        "radius_butt": 0.21,
        "radius_tip": 0.036,
        "sides": 6,
        "flatten": 0.9,
        "lean": 0.05,
        "kink": 0.02,
        "hook": 0.3,
        "grip_style": "wrapped",
        "grip_radius": 0.3,
        "nodes": 0,
        "node_amp": 0.0,
        # short forward-swept fins, like arc-gaps down the shaft
        "cones": [(2.6, 0.6, 0.2, 0.55), (3.6, 3.4, 0.18, 0.55), (4.6, 0.6, 0.16, 0.6), (5.5, 3.4, 0.13, 0.6)],
        "bands": [(1.9, 0.085), (3.0, 0.08), (4.1, 0.07), (5.2, 0.06), (6.1, 0.05)],
        "guides": [2.2, 3.3, 4.4, 5.5, 6.2],
        "guide_style": "collar",
        "tip_ring": True,
        "reel": {"style": "spinning", "part": "Grip", "z": 1.45},
        "pommel": "cap",
        "line": {"length": 2.5, "tilt": 24, "bow": 0.05, "radius": 0.03},
        "float": "quill",
        "neon": ["Trim", "BobberTop"],  # preview-only glow; game reads model.neon
        "colors": {
            "twig": (0.23, 0.25, 0.32),
            "grip": (0.15, 0.16, 0.21),
            "trim": (0.81, 0.87, 0.93),
            "line": (0.70, 0.86, 0.96),
            "top": (0.49, 0.84, 1.0),
            "bottom": (0.93, 0.96, 0.99),
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
        lathe(bm, Vector((0, 0, 0)), [(0.0, -0.02), (gr * 0.9, -0.02), (gr * 1.08, 0.05), (gr * 1.08, 0.2), (gr * 0.95, 0.26), (0.0, 0.26)], cfg["sides"] + 1)
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


BESPOKE = {
    "Bonecaster": build_bonecaster,
    "Voltline": build_voltline,
    "Brineheart": build_brineheart,
}


# ---------------------------------------------------------------- preview


def render_preview(variant_objects, out_png):
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE_NEXT" if hasattr(bpy.types, "SceneEEVEE") else "BLENDER_EEVEE"
    scene.render.resolution_x = 1400
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
    for i, nm in enumerate(names):
        for obj in variant_objects[nm]:
            obj.location.x += (i - (len(names) - 1) / 2) * spacing

    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    bpy.context.collection.objects.link(cam)
    scene.camera = cam
    cam.location = Vector((0.0, -34.0, 5.4))
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
