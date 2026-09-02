# island_gen.py
# Generates the game's islands as low-poly meshes and exports each as glTF
# (.glb) for Roblox's Import. Multi-island: one config per island in ISLANDS,
# selected by argv. Run headless:
#
#   blender --background --python assets/island_gen.py -- assets/island.glb
#   blender --background --python assets/island_gen.py -- assets/island_volcano.glb volcano
#   blender --background --python assets/island_gen.py -- assets/island_volcano.glb volcano preview
#
# Form: `-- <out.glb> [islandId=tropical] [preview]`. `preview` also writes
# <out>_preview.png (a headless 3/4 Workbench render) so an island's shape and
# palette can be refined from a picture without a Studio import.
#
# Everything is seeded and driven by the tables below, so an island is
# identical on every run and "editing an island" means editing its config and
# re-running - the mesh is never hand-sculpted.

# MATERIAL NAMES ARE GLOBAL - PREFIX THEM PER ISLAND (2026-08-29).
# make_material reuses a Blender datablock by NAME, so two islands that both
# declare `M_HutIron` share ONE material, and whichever island builds later in
# the pack silently repaints the other's parts. This shipped: the ice hut's
# palette overwrote the tropical hut's hearth and ironwork, and it was only
# caught by diffing material colours out of the built pack. It is invisible in
# a standalone build - each island looks right alone and wrong together - so
# name every material for its island (M_Frost*, M_Forge*, M_Bog*, ...) and
# never reach for a generic one.
#
# Why glTF and not OBJ: Roblox's modern Import pipeline preserves the full
# node hierarchy and per-object materials from glTF/FBX, but flattens OBJ into
# a single merged MeshPart with no material information at all.
#
# Authoring conventions (must stay true, the game code relies on them):
#   - 1 Blender unit = 1 Roblox stud. Exported Y-up (glTF's export_yup=True
#     converts Blender's native Z-up automatically).
#   - The waterline is at height 0, and the underwater skirt bottoms out at
#     exactly -9 for EVERY island. WorldService aligns the imported model by
#     that -9 bottom, so all islands share one waterline.
#   - Flat shading everywhere. The faceted look IS the art style.
#   - The starter (tropical) island's objects are named Island_Base /
#     Island_Rocks / Palm_* / Island_Bushes / Dock_* / Island_Foam. New
#     islands PREFIX their objects with the island id (Volcano_Base, ...) so
#     they never clash when several live under ReplicatedStorage/Assets.

import math
import os
import random
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector, noise
from mathutils.bvhtree import BVHTree

SEED = 7
SKIRT_BOTTOM = -9.0
_BASE_RADIUS = 68.0  # the scale hand-placed feature literals were tuned at

# ---------------------------------------------------------------- shape state
#
# These module globals define the CURRENT island being built. configure()
# overwrites them from an ISLANDS entry; their defaults here ARE the tropical
# island, so building "tropical" reproduces the original mesh exactly.

ISLAND_RADIUS = 96  # nominal shoreline radius; the coastline wobbles around it
SCALE = ISLAND_RADIUS / _BASE_RADIUS  # feature literals * SCALE at use
TREE_SCALE = SCALE * 1.6  # extra palm bump
SEGMENTS = 64  # angular resolution; facet size is the low-poly dial

# Craggy displacement for rocky islands: vertical noise + per-ring radial
# jitter pushed onto the base mesh so it reads as jagged rock instead of a
# smooth lathe. CRAG = 0 (tropical default) leaves the landform untouched.
CRAG = 0.0  # vertical crag amplitude, studs
CRAG_FREQ = 0.06  # spatial frequency of the crag noise
CRAG_RADIAL = 0.0  # per-ring radial wobble (fraction of the ring radius)
# The wobble noise's (angular, vertical) frequencies. The defaults reproduce
# the original hardcoded (6.0, 4.0) byte-for-byte on every island that does
# not override them. A tall cliff island raises the SECOND number so the
# outline wanders as you climb - bulges and ledges instead of vertical
# columns (the volcano restart's round-3 finding: with u varying only 4.0
# noise units top-to-bottom, a 900-stud flank reads as fluted stone).
CRAG_RADIAL_FREQS = (6.0, 4.0)

# Rim spillway notches (for the volcano): each (centre angle rad, angular
# half-width rad, depth studs) carves a gap in the rim so lava pours out
# there instead of over the whole lip. [] = none (tropical).
NOTCHES = []

# Walkable band: (u_lo, u_hi) where vertical crag is suppressed so the player
# has level ground to walk and fight on. For the old rim volcano this was the
# crater rim; for the tall volcano it is the ash apron at the foot. None = no
# suppression (tropical, which has no crag anyway).
RIM_FLAT = None

# Where NOTCHES carve, as a (u_lo, u_hi) band. None = fall back to RIM_FLAT
# (the old rim-volcano behaviour, notches through the walkable rim). The tall
# volcano sets this to its summit-crater lip so the walkable apron and the
# notch band are independent.
NOTCH_BAND = None

# Summit asymmetry: angular height modulation of the upper cone so the peak
# is a broken, asymmetric ridgeline instead of a lathe. PEAK_TERMS are
# (frequency, phase, amplitude01) sines summed per angle; PEAK_JAG scales the
# sum in studs. 0 = symmetric (tropical, and any island that doesn't set it).
PEAK_JAG = 0.0
PEAK_TERMS = []

# One angular sector where the vertical crag is DAMPED: (centre rad, half-width
# rad, strength 0-1). The volcano uses it to calm the face its switchback trail
# is cut into, so the path benches into believable ground while the rest of the
# cone stays shattered. None = untouched (every other island).
CRAG_CALM = None

# Extra preview cameras: (suffix, eye, target, lens) tuples rendered by
# render_preview after the main overview shot. An island sets this in its
# overrides when the standard shots can't show its layout (the Maelstrom's
# arena is read from ON a platform, not from the air). Empty = none.
PREVIEW_SHOTS = []

# Where the inner material band gives way to the beach, as a relative radius;
# must be one of RINGS so the boundary lies exactly on a mesh ring (a clean
# painted edge instead of a stair-stepped one).
GRASS_U = 0.62
RINGS = [0.0, 0.12, 0.24, 0.36, 0.48, GRASS_U, 0.74, 0.84, 0.93, 1.0, 1.09, 1.28]

# Height profile: (relative radius, height), piecewise linear.
PROFILE = [
    (0.00, 8.6),
    (0.20, 7.9),
    (0.40, 6.3),
    (0.55, 4.4),
    (0.72, 2.6),
    (0.88, 1.5),
    (1.00, 0.7),
    (1.09, -1.8),
    (1.28, SKIRT_BOTTOM),
]

# Outline wobble, as (frequency, phase, amplitude) sine terms. COAST is the
# lobed coastline; GRASS is the gentle swell of the inner plateau (kept
# independent so the green edge doesn't inherit coastal jags).
COAST_TERMS = [(2, 1.3, 0.15), (3, 4.1, 0.09), (5, 2.2, 0.06)]
GRASS_TERMS = [(2, 0.9, 0.04)]

# sRGB colours, written into the material and (for the preview) the viewport.
COLORS = {
    "M_Grass": (0.424, 0.698, 0.361),
    "M_Sand": (0.933, 0.867, 0.667),
    "M_WetSand": (0.816, 0.729, 0.549),
    "M_Rock": (0.259, 0.259, 0.282),
    "M_Trunk": (0.478, 0.333, 0.227),
    "M_Frond": (0.290, 0.627, 0.290),
    "M_FrondDark": (0.220, 0.500, 0.240),  # alternate blades; gives the canopy depth
    "M_Bush": (0.251, 0.541, 0.290),
    "M_Coconut": (0.361, 0.259, 0.180),
    "M_Plank": (0.690, 0.490, 0.290),
    "M_Post": (0.455, 0.310, 0.190),
    "M_Foam": (0.973, 0.996, 1.000),
    # Old Maren's stilt shack (build_hut_maren): sun-bleached driftwood walls,
    # and the dressing on her porch and shelves. The roof reuses the palms'
    # two frond greens and the chimney the island's own M_Rock, so the shack
    # is built out of the cove's existing palette wherever it can be.
    "M_Driftwood": (0.647, 0.549, 0.427),
    "M_HutCloth": (0.878, 0.831, 0.706),  # hammock canvas
    "M_HutFish": (0.769, 0.784, 0.741),  # drying fish on the line, and the gull
    "M_HutIron": (0.290, 0.302, 0.325),  # kettle, cleaver
    "M_HutJar": (0.518, 0.686, 0.478),  # the shelf of pickle jars
    "M_HutEmber": (1.000, 0.545, 0.184),  # hearth embers + the stall lantern
}

# ---------------------------------------------------------------- foam knobs
#
# The stylised-water rim: a clean white band where the water meets the sand,
# plus a small collar around every dock post standing in water. Paper-thin
# flat slabs a hair above the waterline, tucked back under the sand by
# FOAM_INSET so there is no seam where they meet the beach.
FOAM_SEGMENTS = 256
FOAM_INSET = 1.6
FOAM_WIDTH = 2.8  # reach past the shoreline; the sand slope hides the first ~2
FOAM_Z = 0.16
SLAB_THICKNESS = 0.1
FOAM_EDGE = [(11, 1.0, 0.03), (23, 2.5, 0.02)]
POST_FOAM_RADIUS = 0.75
POST_FOAM_SEGMENTS = 14
POST_FOAM_EDGE = [(5, 0.0, 0.05), (9, 1.0, 0.03)]

# ---------------------------------------------------------------- dock layout
#
# A short plank dock off the beach: chunky planks, round bollard posts with
# caps, a wider square at the end to cast from. Direction is a Blender polar
# angle; glTF's Y-up export maps Blender (x, y) to Roblox (x, -z), so 270 is
# Roblox +Z. Tropical only.
DOCK_ANGLE_DEG = 270
DOCK_START_U = 0.86
DOCK_LENGTH = 52.0
DOCK_WIDTH = 10.0
DOCK_END_LENGTH = 13.0
DOCK_END_WIDTH = 18.0
DOCK_MIN_TOP = 2.4
DOCK_POST_SPACING = 7.0
DOCK_POST_BOTTOM = -6.0

TRUNK_SEGMENTS = 6
TRUNK_SIDES = 6

# ---------------------------------------------------------------- terrain math


def coast(theta):
    """Coastline radius multiplier at `theta` - a sum of incommensurate sines
    (COAST_TERMS) so the outline has no visible repetition."""
    return 1.0 + sum(a * math.sin(f * theta + ph) for f, ph, a in COAST_TERMS)


def grass_shape(theta):
    """Radius multiplier for the inner plateau: a near-circle with a gentle
    swell (GRASS_TERMS), independent of coast()."""
    return 1.0 + sum(a * math.sin(f * theta + ph) for f, ph, a in GRASS_TERMS)


def profile_height(u):
    for i in range(len(PROFILE) - 1):
        u0, h0 = PROFILE[i]
        u1, h1 = PROFILE[i + 1]
        if u <= u1:
            t = 0 if u1 == u0 else (u - u0) / (u1 - u0)
            return h0 + (h1 - h0) * t
    return PROFILE[-1][1]


def smoothstep(edge0, edge1, x):
    t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)


def grass_radius(theta):
    """World radius of the inner-plateau/beach edge at this angle."""
    return GRASS_U * ISLAND_RADIUS * grass_shape(theta)


def ring_radius(u, theta):
    """World radius of relative-radius `u` at angle `theta`. Inside the
    plateau rings are smooth ovals; across the beach they blend into the lobed
    coastline, so the beach carries the organic outline and the inner edge
    stays a clean curve."""
    w = smoothstep(GRASS_U, 1.09, u)
    factor = grass_shape(theta) * (1 - w) + coast(theta) * w
    return u * ISLAND_RADIUS * factor


def u_at(x, z):
    """Inverse of ring_radius: the relative radius whose ring passes through
    (x, z). Bisection - ring_radius is monotonic in u."""
    r = math.hypot(x, z)
    theta = math.atan2(z, x)
    lo, hi = 0.0, RINGS[-1]
    if ring_radius(hi, theta) <= r:
        return hi
    for _ in range(40):
        mid = (lo + hi) * 0.5
        if ring_radius(mid, theta) < r:
            lo = mid
        else:
            hi = mid
    return (lo + hi) * 0.5


def height_at(x, z):
    """Terrain height at any world position - the single source of truth, so
    props sit exactly on the ground. Noise is confined to the sand band (zero
    on the inner plateau and zero at the shoreline so the waterline stays
    crisp)."""
    u = u_at(x, z)
    h = profile_height(min(u, RINGS[-1]))
    sand_band = smoothstep(GRASS_U, GRASS_U + 0.10, u) * (1 - smoothstep(0.90, 1.0, u))
    if sand_band > 0:
        h += noise.noise(Vector((x * 0.018, z * 0.018, 3.7))) * 1.2 * sand_band
        h += noise.noise(Vector((x * 0.05, z * 0.05, 9.1))) * 0.6 * sand_band
    return h


def crag(x, z, u):
    """Extra vertical jaggedness for rocky islands (CRAG > 0), fading out at
    the very centre (so a crater floor stays clean) and at the shoreline (so
    the waterline stays crisp). Zero for smooth islands like the tropics."""
    if CRAG == 0:
        return 0.0
    band = smoothstep(0.06, 0.22, u) * (1 - smoothstep(0.92, 1.0, u))
    if RIM_FLAT is not None:
        # Fade the crag to zero across the walkable rim so its top stays level.
        lo, hi = RIM_FLAT
        flat = smoothstep(lo - 0.05, lo, u) * (1 - smoothstep(hi, hi + 0.05, u))
        band *= 1 - flat
    if CRAG_CALM is not None:
        a0, half, strength = CRAG_CALM
        da = abs(((math.atan2(z, x) - a0 + math.pi) % math.tau) - math.pi)
        if da < half:
            band *= 1 - strength * smoothstep(half, half * 0.4, da)
    if band <= 0:
        return 0.0
    n = noise.noise(Vector((x * CRAG_FREQ, z * CRAG_FREQ, 2.0)))
    n2 = noise.noise(Vector((x * CRAG_FREQ * 2.4, z * CRAG_FREQ * 2.4, 9.0)))
    return (n * 0.7 + n2 * 0.3) * CRAG * band


def notch_cut(theta, u):
    """How much to LOWER the terrain to carve a rim spillway (0 where there's
    no notch). Deepest at the rim ring (~u 0.42) and at each notch's centre
    angle, fading inside/outside and to the sides - so the lip drops into a
    channel there and lava can pour out, while the rest of the rim stays
    high. NOTCHES is empty for smooth islands, so this is 0 for the tropics."""
    if not NOTCHES:
        return 0.0
    lo, hi = NOTCH_BAND if NOTCH_BAND is not None else (RIM_FLAT if RIM_FLAT is not None else (0.34, 0.50))
    cut = 0.0
    for a0, half, depth in NOTCHES:
        da = abs(((theta - a0 + math.pi) % math.tau) - math.pi)
        if da >= half:
            continue
        ang = smoothstep(half, half * 0.35, da)  # 1 at centre -> 0 at the edge
        # Peak across the whole walkable rim so the channel spans its width.
        rad = smoothstep(lo - 0.06, lo + 0.02, u) * (1 - smoothstep(hi - 0.02, hi + 0.08, u))
        cut = max(cut, depth * ang * rad)
    return cut


def peak_jag(theta, u):
    """Broken-ridgeline height offset for the upper cone (PEAK_JAG > 0): the
    crater mouth and shoulders rise and fall per angle so the silhouette is
    craggy and asymmetric, fading to nothing by mid-flank and inside the
    crater (the lake floor stays flat). Suppressed across each NOTCH's angular
    window so a spillway gash always stays below the lava lake regardless of
    how high the ridge beside it climbs."""
    if PEAK_JAG == 0:
        return 0.0
    band = smoothstep(0.075, 0.13, u) * (1 - smoothstep(0.22, 0.42, u))
    if band <= 0:
        return 0.0
    for a0, half, _depth in NOTCHES:
        da = abs(((theta - a0 + math.pi) % math.tau) - math.pi)
        if da < half:
            band *= smoothstep(half * 0.35, half, da)
    w = sum(a * math.sin(f * theta + ph) for f, ph, a in PEAK_TERMS)
    return PEAK_JAG * w * band


# ---------------------------------------------------------------- scene helpers


def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    for block in (bpy.data.meshes, bpy.data.materials):
        for item in list(block):
            block.remove(item)


def make_material(name):
    # Reuse an existing material of this name (the pack build makes materials
    # for several islands in one session); island palettes use unique names, so
    # this only ever no-op-refreshes, never cross-wires two islands' colours.
    mat = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    r, g, b = COLORS[name]
    bsdf.inputs["Base Color"].default_value = (r, g, b, 1)
    bsdf.inputs["Roughness"].default_value = 1.0
    # Workbench (the preview render) draws the viewport colour, not the node.
    mat.diffuse_color = (r, g, b, 1)
    return mat


def object_from_bmesh(name, bm, material_names):
    # Keeps every face's normal pointing outward regardless of the winding
    # order it was built with (matters for the closed frond/foam solids).
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])

    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()

    obj = bpy.data.objects.new(name, mesh)
    for mat_name in material_names:
        obj.data.materials.append(bpy.data.materials[mat_name])

    for poly in mesh.polygons:
        poly.use_smooth = False  # flat shading is the style

    bpy.context.collection.objects.link(obj)
    return obj


def add_blob(bm, center, scale, roughness, salt, yaw=0.0, subdiv=1):
    """One angular boulder: a low icosphere with noise pushed along the
    normals, then squashed/rotated into place. Appended into `bm`. `subdiv`
    defaults to the classic low-poly 1; a big hero rock passes 2 so the
    noise has enough vertices to break the icosphere silhouette."""
    temp = bmesh.new()
    bmesh.ops.create_icosphere(temp, subdivisions=subdiv, radius=1.0)

    for v in temp.verts:
        bump = noise.noise(v.co * 1.9 + Vector((salt, salt * 0.7, salt * 1.3)))
        v.co += v.co.normalized() * bump * roughness

    matrix = (
        Matrix.Translation(Vector(center))
        @ Matrix.Rotation(yaw, 4, "Z")
        @ Matrix.Diagonal(Vector(scale)).to_4x4()
    )
    bmesh.ops.transform(temp, matrix=matrix, verts=temp.verts[:])

    mesh = bpy.data.meshes.new("_blob")
    temp.to_mesh(mesh)
    temp.free()
    bm.from_mesh(mesh)
    bpy.data.meshes.remove(mesh)


def add_box(bm, center, size, yaw=0.0):
    """Axis-aligned box (optionally yawed about Z) appended into `bm`."""
    temp = bmesh.new()
    bmesh.ops.create_cube(temp, size=1.0)
    matrix = (
        Matrix.Translation(Vector(center))
        @ Matrix.Rotation(yaw, 4, "Z")
        @ Matrix.Diagonal(Vector(size)).to_4x4()
    )
    bmesh.ops.transform(temp, matrix=matrix, verts=temp.verts[:])
    mesh = bpy.data.meshes.new("_box")
    temp.to_mesh(mesh)
    temp.free()
    bm.from_mesh(mesh)
    bpy.data.meshes.remove(mesh)


def add_post(bm, x, y, z_bottom, z_top, radius, sides=6):
    """A chunky low-poly cylinder standing on Z, capped both ends."""
    temp = bmesh.new()
    height = z_top - z_bottom
    bmesh.ops.create_cone(
        temp, cap_ends=True, cap_tris=False, segments=sides, radius1=radius, radius2=radius, depth=height
    )
    matrix = Matrix.Translation(Vector((x, y, z_bottom + height / 2))) @ Matrix.Rotation(math.tau / (sides * 2), 4, "Z")
    bmesh.ops.transform(temp, matrix=matrix, verts=temp.verts[:])
    mesh = bpy.data.meshes.new("_post")
    temp.to_mesh(mesh)
    temp.free()
    bm.from_mesh(mesh)
    bpy.data.meshes.remove(mesh)


def add_cone(bm, center, r_bottom, r_top, height, sides=6, tilt=(0.0, 0.0), yaw=0.0):
    """A capped low-poly frustum whose BASE sits at `center`, its axis tilted
    off vertical by (pitch_x, pitch_y) radians about the base. Trunks,
    branches, vent cones."""
    temp = bmesh.new()
    bmesh.ops.create_cone(
        temp, cap_ends=True, cap_tris=False, segments=sides, radius1=r_bottom, radius2=r_top, depth=height
    )
    matrix = (
        Matrix.Translation(Vector(center))
        @ Matrix.Rotation(yaw, 4, "Z")
        @ Matrix.Rotation(tilt[0], 4, "X")
        @ Matrix.Rotation(tilt[1], 4, "Y")
        @ Matrix.Translation(Vector((0, 0, height / 2)))
    )
    bmesh.ops.transform(temp, matrix=matrix, verts=temp.verts[:])
    mesh = bpy.data.meshes.new("_cone")
    temp.to_mesh(mesh)
    temp.free()
    bm.from_mesh(mesh)
    bpy.data.meshes.remove(mesh)


def cone_axis(tilt, yaw):
    """World direction of an add_cone's axis for the same tilt/yaw - for
    seating branches partway up a tilted trunk."""
    rot = Matrix.Rotation(yaw, 3, "Z") @ Matrix.Rotation(tilt[0], 3, "X") @ Matrix.Rotation(tilt[1], 3, "Y")
    return rot @ Vector((0, 0, 1))


def ragged(theta, base, terms):
    """`base` scaled by a sum of sines - an edge that wanders."""
    wobble = sum(a * math.sin(f * theta + ph) for f, ph, a in terms)
    return base * (1 + wobble)


def add_ring_slab(bm, inner, outer, z_top, thickness):
    """A closed flat solid between two concentric closed loops of (x, y)."""

    def loop(points, z):
        return [bm.verts.new(Vector((x, y, z))) for x, y in points]

    inner_top, outer_top = loop(inner, z_top), loop(outer, z_top)
    inner_bot, outer_bot = loop(inner, z_top - thickness), loop(outer, z_top - thickness)
    n = len(inner)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((inner_top[i], outer_top[i], outer_top[j], inner_top[j]))
        bm.faces.new((inner_bot[j], outer_bot[j], outer_bot[i], inner_bot[i]))
        bm.faces.new((outer_top[i], outer_bot[i], outer_bot[j], outer_top[j]))
        bm.faces.new((inner_top[j], inner_bot[j], inner_bot[i], inner_top[i]))


def add_disc_slab(bm, points, z_top, thickness):
    """A closed flat solid from one closed loop of (x, y) points."""
    top = [bm.verts.new(Vector((x, y, z_top))) for x, y in points]
    bottom = [bm.verts.new(Vector((x, y, z_top - thickness))) for x, y in points]
    bm.faces.new(top)
    bm.faces.new(list(reversed(bottom)))
    n = len(points)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((top[i], bottom[i], bottom[j], top[j]))


def add_strip_slab(bm, left, right, thickness):
    """A closed thin ribbon down a run of left/right edge points (each a
    Vector) - top, bottom, both side walls, both end caps - so it reads from
    any angle. Used for lava flows down a slope."""
    n = len(left)
    down = Vector((0, 0, thickness))
    lt = [bm.verts.new(p) for p in left]
    rt = [bm.verts.new(p) for p in right]
    lb = [bm.verts.new(p - down) for p in left]
    rb = [bm.verts.new(p - down) for p in right]
    for i in range(n - 1):
        bm.faces.new((lt[i], rt[i], rt[i + 1], lt[i + 1]))  # top
        bm.faces.new((lb[i + 1], rb[i + 1], rb[i], lb[i]))  # bottom
        bm.faces.new((lt[i], lt[i + 1], lb[i + 1], lb[i]))  # left wall
        bm.faces.new((rt[i + 1], rt[i], rb[i], rb[i + 1]))  # right wall
    bm.faces.new((lt[0], lb[0], rb[0], rt[0]))  # top cap
    bm.faces.new((lt[-1], rt[-1], rb[-1], lb[-1]))  # bottom cap


# ---------------------------------------------------------------- island base


def build_island_base(base_name, material_names):
    """The radial-fan landform: a centre vertex then rings of SEGMENTS verts,
    material chosen by ring band (inner / beach / wet) so the boundary is
    exactly the GRASS_U ring polyline. `material_names` is [inner, beach, wet].
    """
    bm = bmesh.new()

    center = bm.verts.new(Vector((0, 0, height_at(0, 0))))
    rings = []
    for u in RINGS[1:]:
        ring = []
        for s in range(SEGMENTS):
            theta = (s / SEGMENTS) * math.tau
            r = ring_radius(u, theta)
            # Per-ring radial wobble so the outline is jagged, not a circle.
            if CRAG > 0 and CRAG_RADIAL > 0:
                af, uf = CRAG_RADIAL_FREQS
                r *= 1 + noise.noise(Vector((math.cos(theta) * af, math.sin(theta) * af, u * uf))) * CRAG_RADIAL
            x, z = math.cos(theta) * r, math.sin(theta) * r
            h = height_at(x, z) + crag(x, z, u) - notch_cut(theta, u) + peak_jag(theta, u)
            ring.append(bm.verts.new(Vector((x, z, h))))
        rings.append(ring)

    def material_for_band(outer_u):
        if outer_u <= GRASS_U:
            return 0
        if outer_u <= 1.0:
            return 1
        return 2

    def face(verts, material):
        f = bm.faces.new(verts)
        f.material_index = material

    for s in range(SEGMENTS):
        face((center, rings[0][s], rings[0][(s + 1) % SEGMENTS]), material_for_band(RINGS[1]))
    for i in range(len(rings) - 1):
        inner, outer = rings[i], rings[i + 1]
        band_material = material_for_band(RINGS[i + 2])
        for s in range(SEGMENTS):
            s2 = (s + 1) % SEGMENTS
            face((inner[s], outer[s], outer[s2], inner[s2]), band_material)

    return object_from_bmesh(base_name, bm, material_names)


# ---------------------------------------------------------------- rocks (tropical)

# Every rock's occupied space, filled by build_rocks, read by placement checks.
ROCK_FOOTPRINTS = []


def build_rocks():
    bm = bmesh.new()
    ROCK_FOOTPRINTS.clear()

    def rock(center, scale, roughness, salt, yaw=0.0):
        add_blob(bm, center, scale, roughness, salt, yaw)
        r_xy = max(scale[0], scale[1]) * (1 + roughness)
        ROCK_FOOTPRINTS.append((center[0], center[1], r_xy, center[2] - scale[2], center[2] + scale[2]))

    # --- the arch massif: two leaning pillars and a capstone spanning them.
    ROCK_SCALE = SCALE * 1.45

    ax, az = -2.0 * SCALE, 12.0 * SCALE
    ground = height_at(ax, az)
    rock(
        (ax - 9.5 * SCALE, az - 1 * SCALE, ground + 9.0 * ROCK_SCALE),
        (6.4 * ROCK_SCALE, 5.6 * ROCK_SCALE, 11.5 * ROCK_SCALE),
        0.26,
        11.0,
        yaw=0.25,
    )
    rock(
        (ax + 9.0 * SCALE, az + 2 * SCALE, ground + 8.5 * ROCK_SCALE),
        (5.8 * ROCK_SCALE, 5.2 * ROCK_SCALE, 10.8 * ROCK_SCALE),
        0.26,
        23.0,
        yaw=-0.35,
    )
    rock(
        (ax - 0.5 * SCALE, az + 0.5 * SCALE, ground + 18.0 * ROCK_SCALE),
        (12.5 * ROCK_SCALE, 6.0 * ROCK_SCALE, 5.2 * ROCK_SCALE),
        0.30,
        37.0,
        yaw=0.1,
    )
    # boulders piled at the feet so the arch grows out of a massif
    rock(
        (ax - 14 * SCALE, az - 5 * SCALE, ground + 2.2 * ROCK_SCALE),
        (4.2 * ROCK_SCALE, 3.8 * ROCK_SCALE, 3.4 * ROCK_SCALE),
        0.32,
        51.0,
        yaw=1.2,
    )
    rock(
        (ax + 12 * SCALE, az + 7 * SCALE, ground + 2.6 * ROCK_SCALE),
        (4.8 * ROCK_SCALE, 4.2 * ROCK_SCALE, 3.8 * ROCK_SCALE),
        0.32,
        63.0,
        yaw=2.1,
    )
    rock(
        (ax + 2 * SCALE, az + 9 * SCALE, ground + 1.8 * ROCK_SCALE),
        (3.4 * ROCK_SCALE, 3.0 * ROCK_SCALE, 2.8 * ROCK_SCALE),
        0.34,
        71.0,
        yaw=0.6,
    )

    # --- boulder ring at the grass/sand boundary, like the reference's collar.
    ring = [
        (15, 1.10, 5.8), (55, 1.18, 4.2), (100, 1.08, 6.5), (140, 1.45, 3.6),
        (170, 1.12, 5.2), (205, 1.22, 4.6), (250, 1.10, 6.0), (290, 1.16, 3.8), (330, 1.14, 5.5),
    ]  # fmt: skip
    for deg, edge_factor, size in ring:
        theta = math.radians(deg)
        r = grass_radius(theta) * edge_factor
        x, z = math.cos(theta) * r, math.sin(theta) * r
        s = size * SCALE
        g = height_at(x, z)
        rock((x, z, g + s * 0.30), (s, s * 0.85, s * 0.72), 0.30, deg * 1.7, yaw=random.uniform(0, math.tau))

    # --- a few half-buried pebbles on the open beach.
    for deg, u_factor, size in [(35, 0.83, 1.8), (160, 0.80, 2.2), (255, 0.86, 1.6)]:
        theta = math.radians(deg)
        r = ISLAND_RADIUS * coast(theta) * u_factor
        x, z = math.cos(theta) * r, math.sin(theta) * r
        s = size * SCALE
        rock((x, z, height_at(x, z) + s * 0.2), (s, s, s * 0.7), 0.28, deg * 3.1)

    return object_from_bmesh("Island_Rocks", bm, ["M_Rock"])


# ---------------------------------------------------------------- palms (tropical)

PALMS = [
    (-30, 26, 14, 10, 210),
    (26, 28, 13, 12, 40),
    (44, 26, 12, 16, 60),  # beach palm, leans out over the water
    (-34, -8, 14, 14, 260),
    (30, -18, 16, 12, 120),
    (-26, -30, 13, 16, 190),
    (34, 8, 12, 18, 80),
    (-40, 24, 15, 10, 210),
    (22, -34, 14, 14, 100),
]

PALM_CHECKPOINTS = []
BUSH_CHECKPOINTS = []


def _clearance(x, z, z_lo, z_hi, margin):
    worst = math.inf
    for rx, rz, rr, rz_lo, rz_hi in ROCK_FOOTPRINTS:
        if rz_hi < z_lo or rz_lo > z_hi:
            continue
        gap = math.hypot(x - rx, z - rz) - (rr + margin)
        worst = min(worst, gap)
    return worst


def validate_placement(palm_points, bush_points):
    """Fails the export loudly if any palm or bush sits inside a rock, or a
    bush strays outside the grass. Tropical only (its hand-placed props)."""
    problems = []

    for label, x, z, z_lo, z_hi in palm_points:
        margin = 6.0 if label.endswith("/base") else 2.5
        gap = _clearance(x, z, z_lo, z_hi, margin=margin)
        print(f"[island_gen]   palm {label:<8} ({x:6.1f}, {z:6.1f})  nearest-rock gap {gap:5.1f}")
        if gap < 0:
            problems.append(f"palm {label} at ({x:.1f}, {z:.1f}) too close to a rock (short by {-gap:.1f})")

    for label, x, z, size in bush_points:
        gap = _clearance(x, z, 0.0, 8.0, margin=1.5)
        if gap < 0:
            problems.append(f"bush {label} at ({x:.1f}, {z:.1f}) intersects a rock (short by {-gap:.1f})")

        theta = math.atan2(z, x)
        boundary = grass_radius(theta)
        if math.hypot(x, z) > boundary - (size + 2):
            problems.append(f"bush {label} at ({x:.1f}, {z:.1f}) pokes past the grass boundary")

    if problems:
        raise RuntimeError("[island_gen] placement validation FAILED:\n  " + "\n  ".join(problems))


def trunk_spine(base, h, lean_rad, lean_dir_rad):
    """Points along a gently curving trunk: leans progressively so the curve
    accelerates toward the crown."""
    points = [Vector(base)]
    direction = Vector((0, 0, 1))
    step = h / TRUNK_SEGMENTS
    lean_axis = Vector((math.cos(lean_dir_rad), math.sin(lean_dir_rad), 0))
    for i in range(TRUNK_SEGMENTS):
        bend = Matrix.Rotation(lean_rad * (i + 1) / TRUNK_SEGMENTS, 3, lean_axis.cross(Vector((0, 0, 1))))
        direction = bend @ Vector((0, 0, 1))
        points.append(points[-1] + direction * step)
    return points


def build_palm(trunk_bm, frond_bm, coco_bm, label, px, pz, h, lean_deg, dir_deg):
    base = Vector((px, pz, height_at(px, pz) - 0.6))
    spine = trunk_spine(base, h, math.radians(lean_deg), math.radians(dir_deg))

    rings = []
    for i, p in enumerate(spine):
        t = i / (len(spine) - 1)
        radius = (0.62 * (1 - t) + 0.34 * t) * TREE_SCALE
        ring = []
        for s in range(TRUNK_SIDES):
            a = (s / TRUNK_SIDES) * math.tau
            ring.append(trunk_bm.verts.new(p + Vector((math.cos(a) * radius, math.sin(a) * radius, 0))))
        rings.append(ring)
    for i in range(len(rings) - 1):
        for s in range(TRUNK_SIDES):
            s2 = (s + 1) % TRUNK_SIDES
            trunk_bm.faces.new((rings[i][s], rings[i + 1][s], rings[i + 1][s2], rings[i][s2]))
    trunk_bm.faces.new(tuple(reversed(rings[-1])))

    crown = spine[-1] + Vector((0, 0, 0.4 * TREE_SCALE))

    PALM_CHECKPOINTS.append((f"{label}/base", base.x, base.y, 0.0, base.z + h * 0.5))
    PALM_CHECKPOINTS.append((f"{label}/crown", crown.x, crown.y, crown.z - 4.0, crown.z + 4.0))

    frond_count = 12
    widths = [0.34, 1.15, 1.25, 0.85, 0.35, 0.06]
    droop = [0.4, 0.25, -0.6, -1.7, -2.9, -4.0]
    steps = len(widths)

    for f in range(frond_count):
        a = (f / frond_count) * math.tau + random.uniform(-0.12, 0.12)
        out = Vector((math.cos(a), math.sin(a), 0))
        side = Vector((-out.y, out.x, 0))
        length = h * 0.5 + random.uniform(-0.6, 1.0) * TREE_SCALE
        material = f % 2

        stations = []
        for k in range(steps):
            t = k / (steps - 1)
            p = crown + out * (length * t) + Vector((0, 0, droop[k] * (length / 7.0)))
            w = widths[k] * TREE_SCALE
            stations.append(
                (
                    frond_bm.verts.new(p + side * w),
                    frond_bm.verts.new(p + Vector((0, 0, w * 0.45))),
                    frond_bm.verts.new(p - side * w),
                    frond_bm.verts.new(p - Vector((0, 0, w * 0.30))),
                )
            )

        def blade_face(verts):
            face = frond_bm.faces.new(verts)
            face.material_index = material

        for k in range(steps - 1):
            near, far = stations[k], stations[k + 1]
            for i in range(4):
                j = (i + 1) % 4
                blade_face((near[i], far[i], far[j], near[j]))
        blade_face(tuple(stations[0]))
        blade_face(tuple(reversed(stations[-1])))

    for c in range(3):
        a = (c / 3) * math.tau + 0.5
        pos = crown + Vector((math.cos(a) * 1.0 * TREE_SCALE, math.sin(a) * 1.0 * TREE_SCALE, -0.7 * TREE_SCALE))
        add_blob(coco_bm, tuple(pos), (0.4 * TREE_SCALE, 0.4 * TREE_SCALE, 0.44 * TREE_SCALE), 0.05, 100 + c * 7.0)


def build_palms():
    trunk_bm, frond_bm, coco_bm = bmesh.new(), bmesh.new(), bmesh.new()
    PALM_CHECKPOINTS.clear()
    for index, (px, pz, h, lean_deg, dir_deg) in enumerate(PALMS):
        build_palm(trunk_bm, frond_bm, coco_bm, index + 1, px * SCALE, pz * SCALE, h * TREE_SCALE, lean_deg, dir_deg)
    return (
        object_from_bmesh("Palm_Trunks", trunk_bm, ["M_Trunk"]),
        object_from_bmesh("Palm_Fronds", frond_bm, ["M_Frond", "M_FrondDark"]),
        object_from_bmesh("Palm_Coconuts", coco_bm, ["M_Coconut"]),
    )


# ---------------------------------------------------------------- bushes (tropical)


def build_bushes():
    bm = bmesh.new()
    BUSH_CHECKPOINTS.clear()

    spots = [
        (34, 34, 3.0), (-30, 30, 3.4), (-36, 8, 2.6), (30, 6, 3.2), (10, -30, 3.4),
        (-22, -24, 2.8), (-16, 36, 2.4), (-2, -2, 2.6), (-8, -14, 2.2), (4, -18, 3.0),
        (44, -8, 2.6), (-42, -14, 2.8), (6, 42, 2.2), (-4, -42, 2.6),
    ]  # fmt: skip

    for index, (x, z, size) in enumerate(spots):
        g = height_at(x, z)
        add_blob(bm, (x, z, g + size * 0.30), (size, size * 0.92, size * 0.55), 0.15, x * 1.3 + z)
        BUSH_CHECKPOINTS.append((index + 1, x, z, size))

    return object_from_bmesh("Island_Bushes", bm, ["M_Bush"])


# ---------------------------------------------------------------- dock (tropical)

DOCK_TOP = None
DOCK_POST_POSITIONS = []


def build_dock(plank_name="Dock_Planks", post_name="Dock_Posts", plank_mat="M_Plank", post_mat="M_Post"):
    """Planks + stringers in one object, posts + caps + cross-beams in
    another. Built in a local frame then rotated into place. Driven by the
    DOCK_* globals, so an island sizes/places its dock via overrides; the
    object names + materials are parameters so each island keeps its own."""
    global DOCK_TOP

    theta = math.radians(DOCK_ANGLE_DEG)
    direction = Vector((math.cos(theta), math.sin(theta), 0))
    start_r = ring_radius(DOCK_START_U, theta)
    origin = direction * start_r

    sand_peak = -math.inf
    for t in range(0, 9):
        for s in (-DOCK_WIDTH / 2, 0.0, DOCK_WIDTH / 2):
            p = origin + direction * t + Vector((-direction.y, direction.x, 0)) * s
            sand_peak = max(sand_peak, height_at(p.x, p.y))
    DOCK_TOP = round(max(DOCK_MIN_TOP, sand_peak + 0.35), 2)

    plank_bm, post_bm = bmesh.new(), bmesh.new()

    plank_thick = 0.45
    plank_w = 1.25
    plank_gap = 0.22
    plank_z = DOCK_TOP - plank_thick / 2

    stringer_h = 0.55
    stringer_z = DOCK_TOP - plank_thick - stringer_h / 2

    main_len = DOCK_LENGTH - DOCK_END_LENGTH

    pitch = plank_w + plank_gap
    count = int(DOCK_LENGTH / pitch)
    for i in range(count):
        t = pitch * (i + 0.5)
        width = DOCK_WIDTH if t < main_len else DOCK_END_WIDTH
        length = width + random.uniform(-0.25, 0.35)
        add_box(
            plank_bm,
            (random.uniform(-0.08, 0.08), t, plank_z + random.uniform(-0.03, 0.03)),
            (length, plank_w, plank_thick),
            yaw=random.uniform(-0.025, 0.025),
        )

    for sx in (-DOCK_WIDTH / 2 + 0.8, DOCK_WIDTH / 2 - 0.8):
        add_box(plank_bm, (sx, DOCK_LENGTH / 2, stringer_z), (0.7, DOCK_LENGTH, stringer_h))
    for sx in (-DOCK_END_WIDTH / 2 + 0.8, DOCK_END_WIDTH / 2 - 0.8):
        add_box(plank_bm, (sx, main_len + DOCK_END_LENGTH / 2, stringer_z), (0.7, DOCK_END_LENGTH, stringer_h))

    bollard_h = 1.4
    post_r = 0.42
    cap_r = 0.58
    cap_h = 0.3

    local_posts = []

    def post(x, t):
        top = DOCK_TOP + bollard_h
        add_post(post_bm, x, t, DOCK_POST_BOTTOM, top, post_r)
        add_post(post_bm, x, t, top - 0.02, top + cap_h, cap_r)
        local_posts.append((x, t))

    t = 1.0
    while t < main_len - 1.5:
        for x in (-DOCK_WIDTH / 2 + 0.35, DOCK_WIDTH / 2 - 0.35):
            post(x, t)
        t += DOCK_POST_SPACING

    for x in (-DOCK_END_WIDTH / 2 + 0.45, DOCK_END_WIDTH / 2 - 0.45):
        post(x, main_len + 0.6)
        post(x, DOCK_LENGTH - 0.6)

    t = 1.0
    while t < main_len - 1.5:
        add_box(post_bm, (0.0, t, stringer_z - stringer_h / 2 - 0.3), (DOCK_WIDTH - 0.4, 0.6, 0.6))
        t += DOCK_POST_SPACING

    phi = theta - math.pi / 2
    world = Matrix.Translation(origin) @ Matrix.Rotation(phi, 4, "Z")
    for bm in (plank_bm, post_bm):
        bmesh.ops.transform(bm, matrix=world, verts=bm.verts[:])

    DOCK_POST_POSITIONS.clear()
    for x, t in local_posts:
        p = world @ Vector((x, t, 0))
        DOCK_POST_POSITIONS.append((p.x, p.y))

    print(f"[island_gen] dock: starts at r={start_r:.1f} (u={DOCK_START_U}), deck top y={DOCK_TOP}")
    return (
        object_from_bmesh(plank_name, plank_bm, [plank_mat]),
        object_from_bmesh(post_name, post_bm, [post_mat]),
    )


# ---------------------------------------------------------------- foam


def build_foam(foam_name, material_name):
    """The white rim + dock-post collars, following the actual shoreline ring.
    Must run after build_dock() (reads DOCK_POST_POSITIONS)."""
    foam_bm = bmesh.new()

    inner, outer = [], []
    for s in range(FOAM_SEGMENTS):
        theta = (s / FOAM_SEGMENTS) * math.tau
        c, sn = math.cos(theta), math.sin(theta)
        shore = ring_radius(1.0, theta)
        r_in = shore - FOAM_INSET
        r_out = shore + ragged(theta, FOAM_WIDTH, FOAM_EDGE)
        inner.append((c * r_in, sn * r_in))
        outer.append((c * r_out, sn * r_out))

    add_ring_slab(foam_bm, inner, outer, FOAM_Z, SLAB_THICKNESS)

    collars = 0
    for px, py in DOCK_POST_POSITIONS:
        if height_at(px, py) > -0.3:
            continue
        points = []
        for s in range(POST_FOAM_SEGMENTS):
            a = (s / POST_FOAM_SEGMENTS) * math.tau
            r = ragged(a + px * 0.37 + py * 0.11, POST_FOAM_RADIUS, POST_FOAM_EDGE)
            points.append((px + math.cos(a) * r, py + math.sin(a) * r))
        add_disc_slab(foam_bm, points, FOAM_Z, SLAB_THICKNESS)
        collars += 1

    print(f"[island_gen] foam: shoreline rim + {collars} dock-post collars")
    return object_from_bmesh(foam_name, foam_bm, [material_name])


# ---------------------------------------------------------------- volcano props


def _ground_bvh(obj):
    """A BVHTree of a finished object's mesh, for raycasting props onto the REAL
    faceted surface. The mesh verts are already in world space (built there) and
    the object sits at the origin, so tree hits are world coordinates."""
    tmp = bmesh.new()
    tmp.from_mesh(obj.data)
    tree = BVHTree.FromBMesh(tmp)
    tmp.free()
    return tree


def _drop_to_ground(ground, x, z):
    """True surface height at (x, z) on the base mesh via a downward raycast, or
    None if the ray misses (a gap / off the mesh). height_at is only the smooth
    profile - it disagrees with the jittered, craggy, faceted mesh by many studs
    (up to the full crag amplitude), which is what leaves props floating or
    buried when they trust it. The raycast uses the actual ground instead."""
    # Cast from above any island's peak (the tall volcano tops ~940 studs).
    hit = ground.ray_cast(Vector((x, z, 1500.0)), Vector((0.0, 0.0, -1.0)))
    return hit[0].z if hit[0] is not None else None


def _near_dock_corridor(theta, u):
    """True if (theta, u) sits in the wedge the shore dock (and the lava delta
    it casts into) occupies, so rocks never block the walk onto the planks or
    poke up through the delta."""
    a = math.radians(DOCK_ANGLE_DEG)
    da = abs(((theta - a + math.pi) % math.tau) - math.pi)
    return da < 0.065 and u > 0.80


def add_ribbon_slab(bm, left, right, thickness):
    """add_strip_slab with a PER-POINT thickness, so a ledge can taper away to
    nothing where it meets the ground instead of ending on a blank wall."""
    n = len(left)
    lt = [bm.verts.new(p) for p in left]
    rt = [bm.verts.new(p) for p in right]
    lb = [bm.verts.new(p - Vector((0, 0, thickness[i]))) for i, p in enumerate(left)]
    rb = [bm.verts.new(p - Vector((0, 0, thickness[i]))) for i, p in enumerate(right)]
    for i in range(n - 1):
        bm.faces.new((lt[i], rt[i], rt[i + 1], lt[i + 1]))
        bm.faces.new((lb[i + 1], rb[i + 1], rb[i], lb[i]))
        bm.faces.new((lt[i], lt[i + 1], lb[i + 1], lb[i]))
        bm.faces.new((rt[i + 1], rt[i], rb[i], rb[i + 1]))
    bm.faces.new((lt[0], lb[0], rb[0], rt[0]))
    bm.faces.new((lt[-1], rt[-1], rb[-1], lb[-1]))


# The shared pool keep-clear registry (the name is a volcano-era relic): every
# island's water builder records its pools/lake/bay here as (x, y, radius) -
# and CLEARS the list at its own start, since it survives across pack islands
# - so the prop scatters keep off the water. Swamp pools, the gloom lake, the
# wreck bay and (when the volcano's lava returns with a rebuild step) lava
# ponds all ride it. WALKED-GROUND POOLS ONLY: record what scatter must avoid.
LAVA_PONDS = []


def _clear_of_ponds(x, z, pad=4.0):
    return all((x - px) ** 2 + (z - py) ** 2 > (pr + pad) ** 2 for px, py, pr in LAVA_PONDS)


def _jagged_disc(bm, cx, cy, rx, ry, z_top, thickness, salt, seg=26):
    """A flat molten pool: a ragged-edged ellipse slab."""
    points = []
    for s in range(seg):
        a = (s / seg) * math.tau
        w = 1 + 0.10 * math.sin(3 * a + salt) + 0.06 * math.sin(7 * a + salt * 2.1)
        points.append((cx + math.cos(a) * rx * w, cy + math.sin(a) * ry * w))
    add_disc_slab(bm, points, z_top, thickness)


# ---------------------------------------------------------------- volcano lava (restart step 2)
#
# 2026-08-27, user: "add lava in the volcano and on the sides dripping down...
# realistic... it shouldn't have gaps... it should flow all the way down from
# the top to the floor and ocean. a good amount of lava."
#
# One `Volcano_Lava` object (the fishable-surface contract name - NEVER split
# it): a summit crater lake, six rivers pouring out through notches carved in
# the rim (the entry's NOTCHES drop the 895 lip below the 842 lake at each
# flow's bearing), each river a SINGLE CONTINUOUS RIBBON (add_strip_slab:
# consecutive samples share vertices, so gaps are impossible by construction)
# that hugs the real craggy mesh via BVH raycasts - the deleted old build's
# hard lesson: the analytic height disagrees with the crag by tens of studs,
# which is exactly where floating slabs and holes came from. Every river runs
# lake -> notch -> the full 900-stud flank -> across the ash apron -> a molten
# DELTA fanning into the sea at the waterline. Mid-apron pools + the deltas
# are recorded in LAVA_PONDS (the fishable lava, and the keep-clear registry
# for later prop steps). The 270-deg wedge (spawn now, dock later) stays
# lava-free: nearest flow bearing is 65 deg away.

LAVA_LAKE_LEVEL = 842.0  # crater lake surface; dish floor 830-836, inner lip 852
LAVA_LAKE_R = 48.0
LAVA_LIFT = 3.6  # base ride height above the raycast rock: a THICK visible
# layer (user round 3: "a thicker sheet... its own object layered on top of
# the rock") - the exposed side wall under the top surface is what sells the
# lava as a distinct slab resting on the mountain rather than paint on it.
LAVA_COLUMNS = 7  # lateral samples per row - every one conforms to the ground

# (bearing_deg, notch_half_width_deg, notch_depth, width_scale). Deliberately
# UNEVEN, like the old approved design: the 48-deg river is THE main breach.
# Bearings/widths/depths are mirrored into the entry's NOTCHES by hand - keep
# the two lists in step or a river runs over an uncut rim.
LAVA_FLOWS = [
    (318.0, 9.0, 66.0, 1.0),
    (5.0, 8.0, 62.0, 0.85),
    (48.0, 13.0, 78.0, 1.35),  # the main breach
    (100.0, 10.0, 70.0, 1.0),
    (152.0, 8.0, 64.0, 0.8),
    (205.0, 11.0, 72.0, 1.15),
]


def _lava_surface(ground, x, y):
    """The real mesh height at (x, y) - BVH first, analytic fallback - floored
    just under the waterline so a river entering the sea rides the surface."""
    z = _drop_to_ground(ground, x, y)
    if z is None:
        z = height_at(x, y)
    return max(z, -2.2)


def _lava_sheet(bm, rows, thickness):
    """A DRAPED sheet: `rows` is a grid of top-surface Vectors (each already
    sitting just above its own raycast ground), extruded down by `thickness`
    and closed with side walls + end caps. Every interior vertex conforms to
    the rock beneath it, so the surface follows every crag facet - unlike a
    two-edge strip, whose interpolated middle the rock could poke through
    (the user's 'lava blending into the rock' report, 2026-08-27)."""
    top = [[bm.verts.new(p) for p in row] for row in rows]
    down = Vector((0, 0, thickness))
    bot = [[bm.verts.new(p - down) for p in row] for row in rows]
    n, m = len(rows), len(rows[0])
    for i in range(n - 1):
        for j in range(m - 1):
            bm.faces.new((top[i][j], top[i][j + 1], top[i + 1][j + 1], top[i + 1][j]))
            bm.faces.new((bot[i + 1][j], bot[i + 1][j + 1], bot[i][j + 1], bot[i][j]))
    for i in range(n - 1):  # side walls
        bm.faces.new((top[i][0], top[i + 1][0], bot[i + 1][0], bot[i][0]))
        bm.faces.new((bot[i][m - 1], bot[i + 1][m - 1], top[i + 1][m - 1], top[i][m - 1]))
    bm.faces.new([top[0][j] for j in range(m)] + [bot[0][j] for j in range(m - 1, -1, -1)])  # start cap
    bm.faces.new([bot[n - 1][j] for j in range(m)] + [top[n - 1][j] for j in range(m - 1, -1, -1)])  # end cap


def _lava_river(bm, ground, bearing_deg, half_width_deg, width_scale):
    """One river, source to sea, as a single draped sheet resting ON the rock:
    a steps x LAVA_COLUMNS grid where EVERY vertex raycasts its own ground and
    sits LAVA_LIFT above it - so the lava coats spurs and sinks into gullies
    exactly like a flow, never disappears behind a facet, and never floats
    (the sheet's 4-stud underside is always inside the rock, and its edge
    walls reach below ground). Returns the delta centre + a mid-apron pool
    spot."""
    theta0 = math.radians(bearing_deg)
    r0 = LAVA_LAKE_R * 0.72  # starts INSIDE the lake so the join is seamless
    r_end = ring_radius(1.0, theta0) + 52.0  # well past the shore, into the sea
    steps = 168  # ~3.5-stud rows: on a 70-deg wall a coarser grid lets facets clip through mid-cell
    # The wander is bounded by the notch's half-width so the river can't climb
    # out of its own carved channel on the way through the rim.
    wander = min(math.radians(half_width_deg) * 0.55, 0.075)
    phase = bearing_deg * 0.37

    rows = []
    pool_at = None
    prev_raw = None
    raws = [0.0] * LAVA_COLUMNS
    for i in range(steps + 1):
        t = i / steps
        theta = theta0 + wander * math.sin(phase + t * 6.2)
        r = r0 + (r_end - r0) * t
        cx, cy = math.cos(theta) * r, math.sin(theta) * r

        # Widths: a tight chute up top, broadening down the flank, fanning
        # hard over the last stretch into the sea.
        w = width_scale * (7.0 + 20.0 * t + 6.0 * math.sin(math.pi * t))  # bulges mid-flank
        if t > 0.86:
            w += width_scale * 18.0 * (t - 0.86) / 0.14
        px, py = -math.sin(theta), math.cos(theta)
        row = []
        for j in range(LAVA_COLUMNS):
            frac = -1.0 + 2.0 * j / (LAVA_COLUMNS - 1)
            ex, ey = cx + px * w * frac, cy + py * w * frac
            raw = _lava_surface(ground, ex, ey)
            # SLOPE-SCALED lift (the 'still blending into the rock' fix): a
            # vertical offset of L on a wall of slope theta is only L*cos
            # (theta) of true clearance - ~a quarter of L on these cliffs -
            # so the grid's interpolation error still crossed the rock. Scale
            # the vertical lift by the local drop per row so the TRUE
            # clearance stays ~LAVA_LIFT everywhere: tight on the flat apron
            # (resting on it), tall on the plunging walls (where the offset
            # reads as thickness, never as floating).
            drop = abs(raw - prev_raw[j]) if prev_raw is not None else 0.0
            row.append(Vector((ex, ey, raw + LAVA_LIFT + min(12.0, 0.5 * drop))))
            raws[j] = raw
        prev_raw, raws = raws, [0.0] * LAVA_COLUMNS
        rows.append(row)

        # Where the river first crosses the mid-apron, remember the spot for
        # a molten pool beside it.
        if pool_at is None and u_at(cx, cy) >= 0.80:
            pool_at = (cx, cy, _lava_surface(ground, cx, cy))

    _lava_sheet(bm, rows, 10.0)
    end = rows[-1][LAVA_COLUMNS // 2]
    return (end.x, end.y), pool_at


def build_lava(ground):
    LAVA_PONDS.clear()  # this island's records only (shared-registry rule)
    bm = bmesh.new()

    # The crater lake, filling the summit dish.
    _jagged_disc(bm, 0.0, 0.0, LAVA_LAKE_R, LAVA_LAKE_R * 0.93, LAVA_LAKE_LEVEL, 8.0, salt=3.1, seg=30)

    deltas = 0
    for bearing, half_w, _depth, ws in LAVA_FLOWS:
        (ex, ey), pool_at = _lava_river(bm, ground, bearing, half_w, ws)
        # The delta: the river fans into a molten sheet at the waterline,
        # spreading into the sea - sunk deep so its underside is never seen.
        delta_r = 15.0 * ws
        _jagged_disc(bm, ex, ey, delta_r, delta_r * 0.8, 0.45, 5.0, salt=bearing * 1.7, seg=18)
        LAVA_PONDS.append((ex, ey, delta_r))
        deltas += 1
        if pool_at is not None:
            px, py, pz = pool_at
            pool_r = random.uniform(9.0, 14.0) * ws
            _jagged_disc(bm, px, py, pool_r, pool_r * random.uniform(0.75, 0.95), pz + 0.55, 4.0, salt=bearing * 2.3, seg=16)
            LAVA_PONDS.append((px, py, pool_r))

    print(
        f"[island_gen] HANDOFF volcano lava: lake r{LAVA_LAKE_R:.0f} at {LAVA_LAKE_LEVEL:.0f}, "
        f"{len(LAVA_FLOWS)} rivers, {deltas} sea deltas, {len(LAVA_PONDS)} fishable ponds recorded"
    )
    return object_from_bmesh("Volcano_Lava", bm, ["M_Lava"])


# ---------------------------------------------------------------- volcano dead trees (restart step 3)
#
# 2026-08-27, user: "add dead trees randomly across the base of the island.
# they should be huge dead trees with branches branching out largely." One
# `Volcano_DeadTrees` object (M_Charred - the old build's burnt-black), ~40
# giants scattered over the ash apron: kinked two-segment trunks 38-85 studs
# tall with root flares, throwing 4-6 LONG primary limbs wide of the trunk
# (50-80 deg off vertical - the "branching out largely") and gnarled
# secondaries off those. Raycast-seated; keeps clear of the lava rivers
# (angular corridors around each LAVA_FLOWS bearing), the recorded ponds/
# deltas, and the 270-deg spawn corridor. Collidable - trunks are real
# obstacles - so the import wants PreciseConvexDecomposition (a box hull
# over a spread crown would be an invisible wall).


def _volcano_clear_of_hut(x, y, pad=0.0):
    """Off Brakk's plot - the hold, its yard and the magma rill running down
    to it. Empty until build_volcano claims the plot, so the tropical/other
    islands are untouched by it."""
    return all((x - kx) ** 2 + (y - ky) ** 2 > (kr + pad) ** 2 for kx, ky, kr in _HUT_B_KEEP)


def _volcano_clear_of_rivers(x, y, margin):
    """True when (x, y) sits at least `margin` studs LATERALLY off every lava
    river's centreline (approximated as the radial ray at its bearing - the
    authored wander is under 0.075 rad, folded into the margin)."""
    r = math.hypot(x, y)
    if r < 1.0:
        return True
    theta = math.atan2(y, x)
    for bearing, _hw, _depth, ws in LAVA_FLOWS:
        da = abs(((theta - math.radians(bearing) + math.pi) % math.tau) - math.pi)
        if r * da < margin + 30.0 * ws:  # river half-width at the apron, scaled
            return False
    return True


def _dead_tree(bm, x, y, base_z, h, salt):
    """One huge charred snag: a kinked two-segment trunk with root flares,
    wide-flung primary limbs and gnarled secondaries. All add_cone segments;
    children seat on their parent's axis via cone_axis."""
    rng = random.Random(salt)
    trunk_r = max(2.4, h * 0.062)  # THICK - 'huge' needs mass, not just height

    # Root flares: short fat cones leaning outward from the base.
    for _ in range(3):
        a = rng.uniform(0, math.tau)
        add_cone(
            bm, (x + math.cos(a) * trunk_r * 0.9, y + math.sin(a) * trunk_r * 0.9, base_z - 0.6),
            trunk_r * 0.6, 0.3, rng.uniform(5.0, 8.5), sides=5,
            tilt=(math.sin(a) * 0.9, -math.cos(a) * 0.9), yaw=0.0,
        )

    # The trunk: two segments with a kink between them.
    t1 = (rng.uniform(-0.09, 0.09), rng.uniform(-0.09, 0.09))
    h1 = h * rng.uniform(0.5, 0.6)
    add_cone(bm, (x, y, base_z), trunk_r, trunk_r * 0.55, h1, sides=6, tilt=t1, yaw=0.0)
    axis1 = cone_axis(t1, 0.0)
    kink = Vector((x, y, base_z)) + axis1 * h1
    t2 = (t1[0] + rng.uniform(-0.16, 0.16), t1[1] + rng.uniform(-0.16, 0.16))
    h2 = h - h1
    add_cone(bm, tuple(kink), trunk_r * 0.55, 0.4, h2, sides=5, tilt=t2, yaw=0.0)
    axis2 = cone_axis(t2, 0.0)

    # Primary limbs: long, flung WIDE (50-80 deg off vertical), spiralling
    # around the trunk, seated along both trunk segments.
    limbs = rng.randint(4, 6)
    yaw0 = rng.uniform(0, math.tau)
    for k in range(limbs):
        f = rng.uniform(0.45, 0.95)
        up = f * h
        seat = (Vector((x, y, base_z)) + axis1 * up) if up < h1 else (kink + axis2 * (up - h1))
        yaw = yaw0 + k * (math.tau / limbs) + rng.uniform(-0.4, 0.4)
        spread = math.radians(rng.uniform(50.0, 80.0))
        tilt = (math.sin(yaw) * spread, -math.cos(yaw) * spread)
        length = h * rng.uniform(0.38, 0.62) * (1.15 - 0.35 * f)  # lower limbs reach furthest
        limb_r = trunk_r * rng.uniform(0.32, 0.45)
        add_cone(bm, tuple(seat), limb_r, 0.22, length, sides=5, tilt=tilt, yaw=0.0)
        # One or two gnarled secondaries per limb.
        laxis = cone_axis(tilt, 0.0)
        for _ in range(rng.randint(1, 2)):
            g = rng.uniform(0.45, 0.8)
            child = seat + laxis * (length * g)
            ct = (tilt[0] + rng.uniform(-0.5, 0.5), tilt[1] + rng.uniform(-0.5, 0.5))
            add_cone(bm, tuple(child), limb_r * 0.5, 0.14, length * rng.uniform(0.35, 0.55), sides=4, tilt=ct, yaw=0.0)


def build_volcano_trees(ground):
    bm = bmesh.new()
    placed = []
    made, attempts = 0, 0
    while made < 60 and attempts < 3400:  # density held as the apron grew
        attempts += 1
        theta = random.uniform(0, math.tau)
        u = random.uniform(0.63, 0.97)  # the widened apron (re-keyed 2026-08-28)
        # The spawn/dock corridor on 270 stays clear (the walk off the beach).
        if abs(((theta - math.radians(270) + math.pi) % math.tau) - math.pi) < math.radians(9):
            continue
        r = ring_radius(u, theta)
        x, y = math.cos(theta) * r, math.sin(theta) * r
        if not _volcano_clear_of_rivers(x, y, 14.0):
            continue
        if not _clear_of_ponds(x, y, 6.0):
            continue
        if not _volcano_clear_of_hut(x, y, 12.0):  # step 7: Brakk's plot
            continue
        if any((x - px) ** 2 + (y - py) ** 2 < 24.0**2 for px, py in placed):
            continue
        base = _drop_to_ground(ground, x, y)
        if base is None or base < 0.5:
            continue
        # Mostly huge, a few true giants towering over the apron.
        h = random.uniform(40.0, 64.0) if random.random() < 0.7 else random.uniform(64.0, 95.0)
        _dead_tree(bm, x, y, base - 0.8, h, salt=attempts * 3.7 + made)
        placed.append((x, y))
        made += 1
    print(f"[island_gen] HANDOFF volcano trees: {made} dead giants on the apron (heights 40-95)")
    return object_from_bmesh("Volcano_DeadTrees", bm, ["M_Charred"])


# ---------------------------------------------------------------- volcano rocks (restart step 4)
#
# 2026-08-27, user: "add large rocks along the volcano and the base as well...
# varying in size but large and randomly placed... the look of them shouldn't
# all be the exact same." One `Volcano_Rocks` object (M_Obsidian), two
# populations:
#   - APRON boulders (u 0.72-0.985): walked among, 5-26 studs
#   - FLANK boulders (u 0.20-0.68): MASSIVE 12-30-stud masses jammed into the
#     steep cone, half-buried, reading as broken rock faces from the beach
# Every rock is INDIVIDUALLY generated: a cluster of 1-3 noise-displaced
# blobs (independent squash/roughness/yaw/salt per blob), and ~1 in 7 gets a
# tilted shard-fang jutting out of the mass - so silhouettes run from round
# scree domes through angular slab piles to fanged crags, no two alike.
# All raycast-seated; keeps clear of the lava rivers/ponds and the 270-deg
# spawn corridor. Collidable and walked among (the old build's ruling) -
# covered by the checklist's PreciseConvexDecomposition-on-solid-props rule.


def _volcano_rock(bm, x, y, surface, size, salt, embed):
    """One unique rock: 1-3 overlapping angular blobs + an occasional shard.
    `embed` is the fraction of the (first, biggest) blob sunk into the
    ground - flank masses bury deeper than apron boulders."""
    rng = random.Random(salt)
    blobs = rng.randint(2, 4)  # composed masses, never a lone ball
    for k in range(blobs):
        s = size * (1.0 if k == 0 else rng.uniform(0.35, 0.65))
        dx, dy = (0.0, 0.0) if k == 0 else (rng.uniform(-size * 0.6, size * 0.6), rng.uniform(-size * 0.6, size * 0.6))
        # Wilder squash (down to 0.45 in z: slabs and shelves, not spheres).
        squash = (rng.uniform(0.65, 1.35), rng.uniform(0.65, 1.35), rng.uniform(0.45, 1.05))
        zc = surface + s * squash[2] * (1.0 - embed if k == 0 else rng.uniform(0.2, 0.55))
        add_blob(
            bm, (x + dx, y + dy, zc),
            (s * squash[0], s * squash[1], s * squash[2]),
            # Heavy displacement - at low roughness a big rock reads as a
            # bare icosphere (preview review); big hero blobs also get an
            # extra subdivision so the noise has vertices to bite into.
            rng.uniform(0.3, 0.52), salt * 2.9 + k * 7.3, yaw=rng.uniform(0, math.tau),
            subdiv=2 if s >= 12.0 else 1,
        )
    if rng.random() < 0.14:  # the occasional fang jutting from the mass
        add_cone(
            bm, (x + rng.uniform(-size * 0.4, size * 0.4), y + rng.uniform(-size * 0.4, size * 0.4), surface - 1.0),
            size * rng.uniform(0.28, 0.42), 0.3, size * rng.uniform(1.3, 2.2), sides=5,
            tilt=(rng.uniform(-0.35, 0.35), rng.uniform(-0.35, 0.35)), yaw=rng.uniform(0, math.tau),
        )


def build_volcano_rocks(ground):
    bm = bmesh.new()
    placed = []

    def spot(u_lo, u_hi, river_margin, salt_unused=None):
        theta = random.uniform(0, math.tau)
        if abs(((theta - math.radians(270) + math.pi) % math.tau) - math.pi) < math.radians(9):
            return None
        u = random.uniform(u_lo, u_hi)
        r = ring_radius(u, theta)
        x, y = math.cos(theta) * r, math.sin(theta) * r
        if not _volcano_clear_of_rivers(x, y, river_margin):
            return None
        if not _clear_of_ponds(x, y, 5.0):
            return None
        if not _volcano_clear_of_hut(x, y, 6.0):  # step 7: Brakk's plot
            return None
        return x, y

    def scatter(builder, count, u_lo, u_hi, size_lo, size_hi, giant_chance, giant_hi, river_margin, spacing, salt0, **kw):
        made, attempts = 0, 0
        while made < count and attempts < count * 60:
            attempts += 1
            hit = spot(u_lo, u_hi, river_margin)
            if hit is None:
                continue
            x, y = hit
            size = random.uniform(size_lo, size_hi) if random.random() > giant_chance else random.uniform(size_hi, giant_hi)
            if any((x - px) ** 2 + (y - py) ** 2 < (spacing + size) ** 2 for px, py, _ps in placed):
                continue
            surface = _drop_to_ground(ground, x, y)
            if surface is None or surface < 0.3:
                continue
            builder(bm, x, y, surface, size, salt=salt0 + attempts * 3.1, **kw)
            placed.append((x, y, size))
            made += 1
        return made

    # Loose rock lives where loose rock CAN live: scattered over the flat
    # apron, and piled thick as a TALUS band where the cone's cliffs meet it
    # (rockfall collects at the foot of a face). The steep wall itself is
    # BARE by user order (2026-08-27, "remove all rocks on the side of the
    # volcano" - the embedded-ledge experiment is gone too): nothing above
    # u 0.64 but mountain, crag and lava.
    apron = scatter(_volcano_rock, 70, 0.66, 0.985, 5.0, 14.0, 0.18, 26.0, 10.0, 4.0, salt0=610.0, embed=0.35)
    talus = scatter(_volcano_rock, 44, 0.56, 0.65, 8.0, 18.0, 0.22, 28.0, 10.0, 1.5, salt0=980.0, embed=0.5)
    print(f"[island_gen] HANDOFF volcano rocks: {apron} apron boulders + {talus} talus at the cliff foot; flanks bare")
    return object_from_bmesh("Volcano_Rocks", bm, ["M_Obsidian"])


# ------------------------------------------- Old Maren's stilt shack (tropical)
#
# The cove fishwife's driftwood shack, up on tide-stilts at the beach edge a
# short walk seaward of the spawn, facing INLAND so a new player walks out of
# the spawn plaza straight at its porch and market counter. It is a WALK-IN
# building: 11 x 11 studs of clear floor, a 5 x 7.6 door, a 9.5-stud ceiling,
# and every wall 0.8 studs thick so PreciseConvexDecomposition gives solid
# walls instead of a hull over the whole box. The deck, walls, stilts, ramp
# and chimney live in Island_Hut_Walls and must stay COLLIDABLE (the porch is
# floor Maren and the player stand on); only Island_Hut_Props is a candidate
# for NON_COLLIDE.

_HUT_MAREN_ANGLE = math.radians(72.0)  # bearing of the site from the island centre
_HUT_MAREN_RADIUS = 66.0  # out on the sand, ~22 studs seaward of Maren's old mark
_HUT_MAREN_YAW = _HUT_MAREN_ANGLE + math.pi  # local +front points back inland


def _hut_maren_quad_slab(bm, corners, thickness):
    """A flat solid from four world-space corner points, extruded `thickness`
    along the quad's own normal - the tilted plank the axis-aligned add_box
    helpers cannot make (roof shingles, the porch ramp, a hammock's sag).
    Shared by both of this pass's huts (Maren's and Morra's)."""
    pts = [Vector(c) for c in corners]
    n = (pts[1] - pts[0]).cross(pts[2] - pts[0])
    if n.length < 1e-9:
        return
    if n.z < 0:
        n = -n  # the solid always hangs BELOW the quad, whatever the winding -
    n = n.normalized() * thickness  # so the given corners are the walked/lit face
    top = [bm.verts.new(p) for p in pts]
    bot = [bm.verts.new(p - n) for p in pts]
    bm.faces.new(top)
    bm.faces.new(list(reversed(bot)))
    for i in range(4):
        j = (i + 1) % 4
        bm.faces.new((top[i], bot[i], bot[j], top[j]))


def _hut_maren_paint(bm, first, index):
    """Give every face added since `first` a second/third material slot - how
    a single hut object carries stone as well as wood (the importer splits it
    into <Name> / <Name>2, which is what MESH_COLOR keys)."""
    for f in list(bm.faces)[first:]:
        f.material_index = index


def build_hut_maren():
    """Old Maren's stilt shack: driftwood walls under an overlapping
    palm-frond roof, a crooked stone chimney, and a fold-out market counter
    on the porch she trades from. Four layers - Walls (structure, collidable),
    Roof, Props (the dressing, inside and out) and Glow (the hearth embers)."""
    walls, roof, props, glow = bmesh.new(), bmesh.new(), bmesh.new(), bmesh.new()
    rng = random.Random(8801)

    cx = math.cos(_HUT_MAREN_ANGLE) * _HUT_MAREN_RADIUS
    cy = math.sin(_HUT_MAREN_ANGLE) * _HUT_MAREN_RADIUS
    a = _HUT_MAREN_YAW
    fx, fy = math.cos(a), math.sin(a)  # +front: inland, toward the spawn beach
    rx, ry = -math.sin(a), math.cos(a)  # +side: Maren's right as she faces out

    def P(fwd, side, z):
        return (cx + fx * fwd + rx * side, cy + fy * fwd + ry * side, z)

    def B(bm, fwd, side, z, d, w, h):
        """Box centred at the local (fwd, side, z), `d` deep along front,
        `w` wide along side, `h` tall - yawed into the shack's frame."""
        add_box(bm, P(fwd, side, z), (d, w, h), yaw=a)

    def ground(fwd, side):
        x, y, _ = P(fwd, side, 0)
        return height_at(x, y)

    # The deck rides above the HIGHEST ground under the footprint, so no
    # corner of it is ever buried - the stilts take up the slack downhill.
    g_max = max(ground(f_, s_) for f_ in (-7.0, 0.0, 7.0, 12.0) for s_ in (-7.0, 0.0, 7.0))
    FLOOR = g_max + 1.35  # top of the deck planks

    T = 0.8  # wall thickness (>= 0.5: the solid-walls import rule)
    HW = 6.3  # outer half-width; interior half is HW - T = 5.5 -> 11 studs clear
    BACK, FRONT = -6.3, 6.3  # outer faces on the front axis (11 clear inside)
    PORCH = 11.5  # the porch deck's outer edge
    WALL_H = 9.5  # deck top -> wall top (ceiling well over the 8-stud rule)
    DOOR_LO, DOOR_HI, DOOR_H = -3.5, 1.5, 7.6  # 5.0 x 7.6 opening, left of the counter

    # ---- deck + stilts + walls (all collidable) ----
    B(walls, (BACK + PORCH) / 2, 0.0, FLOOR - 0.35, PORCH - BACK, 13.4, 0.7)
    for fwd, side in ((-5.4, -5.4), (-5.4, 5.4), (0.0, -5.9), (0.0, 5.9), (5.4, -5.4), (5.4, 5.4), (10.4, -5.2), (10.4, 5.2)):
        x, y, _ = P(fwd, side, 0)
        add_post(walls, x, y, height_at(x, y) - 0.9, FLOOR - 0.7, 0.55)
        # a knee brace back up under the deck, so it reads as built, not floated
        add_cone(
            walls,
            (x, y, height_at(x, y) + 0.4),
            0.26,
            0.14,
            2.4,
            sides=4,
            tilt=_tilt_toward(Vector((-fx * (1 if fwd > 0 else -1), -fy * (1 if fwd > 0 else -1), 2.2)).normalized()),
        )

    # Every wall foots 0.15 INTO the deck rather than resting coplanar on it -
    # the "nothing floats, everything overlaps" rule, and no coplanar z-fight.
    WZ, WM = FLOOR + (WALL_H - 0.15) / 2, WALL_H + 0.15
    B(walls, BACK + T / 2, 0.0, WZ, T, 2 * HW, WM)  # back wall
    B(walls, 0.0, -(HW - T / 2), WZ, FRONT - BACK, T, WM)  # left
    B(walls, 0.0, HW - T / 2, WZ, FRONT - BACK, T, WM)  # right
    B(walls, FRONT - T / 2, (-HW + DOOR_LO) / 2, WZ, T, DOOR_LO + HW, WM)
    B(walls, FRONT - T / 2, (DOOR_HI + HW) / 2, WZ, T, HW - DOOR_HI, WM)
    B(walls, FRONT - T / 2, (DOOR_LO + DOOR_HI) / 2, FLOOR + (DOOR_H + WALL_H) / 2, T, DOOR_HI - DOOR_LO, WALL_H - DOOR_H)

    # The porch ramp up off the sand, in line with the door.
    ramp_out = PORCH + 4.8
    gz = min(ground(ramp_out, DOOR_LO), ground(ramp_out, DOOR_HI)) - 0.2
    _hut_maren_quad_slab(
        walls,
        [P(PORCH, DOOR_LO, FLOOR), P(PORCH, DOOR_HI - 1.0, FLOOR), P(ramp_out, DOOR_HI - 1.0, gz), P(ramp_out, DOOR_LO, gz)],
        0.35,
    )

    # Porch posts (the drying-fish lines are strung between them) and the
    # ridgepole the gull stands on - wood, so they live with the walls.
    RIDGE_Z = FLOOR + WALL_H + 5.4
    EAVE_Z = FLOOR + WALL_H - 0.5
    EAVE_S = 7.7  # the roof's half-span; the porch posts run right up into it
    RIDGE_BACK, RIDGE_FRONT = BACK - 1.2, PORCH + 0.8

    def roof_z(side):
        return EAVE_Z + (RIDGE_Z - EAVE_Z) * (1.0 - min(abs(side), EAVE_S) / EAVE_S)

    for side in (-5.4, 5.4):
        x, y, _ = P(PORCH - 0.9, side, 0)
        add_post(walls, x, y, FLOOR - 0.5, roof_z(side) - 0.05, 0.4)  # deck -> into the roof
    add_cone(
        walls,
        P(RIDGE_BACK, 0.0, RIDGE_Z),
        0.3,
        0.24,
        RIDGE_FRONT - RIDGE_BACK,
        sides=4,
        tilt=_tilt_toward(Vector((fx, fy, 0.0))),
    )

    # ---- the crooked stone chimney + the hearth it serves (material slot 1) ----
    stone_first = len(walls.faces)
    stack_z = ground(-1.0, -(HW + 1.0)) - 0.4
    k = 0
    while stack_z < FLOOR + WALL_H + 2.6:  # clears the roof on its own side, no stovepipe
        h = 3.4 if k else (FLOOR - stack_z + 1.4)
        B(
            walls,
            -1.0 + rng.uniform(-0.5, 0.5),
            -(HW + 1.0) + rng.uniform(-0.35, 0.35),
            stack_z + h / 2,
            3.6 - k * 0.16,
            3.2 - k * 0.14,
            h,
        )
        stack_z += h - 0.3  # courses overlap; a chimney is not a stack of floaters
        k += 1
    B(walls, -1.0, -(HW - T - 1.2), FLOOR + 0.9, 2.6, 2.4, 1.8)  # the hearth shelf inside
    B(walls, -1.0, -(HW - T - 0.3), FLOOR + 2.6, 2.6, 0.7, 3.4)  # its sooty back slab
    _hut_maren_paint(walls, stone_first, 1)

    # The two GABLE ends, boarded up to the ridge - without them the roof
    # triangle is an open hole into the room at each end.
    for fwd, inward in ((BACK, T), (FRONT, -T)):
        tri = [
            (P(fwd, -EAVE_S, EAVE_Z), P(fwd, EAVE_S, EAVE_Z), P(fwd, 0.0, RIDGE_Z)),
            (P(fwd + inward, -EAVE_S, EAVE_Z), P(fwd + inward, EAVE_S, EAVE_Z), P(fwd + inward, 0.0, RIDGE_Z)),
        ]
        vs = [[walls.verts.new(Vector(p)) for p in face] for face in tri]
        walls.faces.new(vs[0])
        walls.faces.new(list(reversed(vs[1])))
        for i in range(3):
            j = (i + 1) % 3
            walls.faces.new((vs[0][i], vs[1][i], vs[1][j], vs[0][j]))

    # ---- the palm-frond roof: two slopes, overlapping frond courses on top ----
    for s in (-1.0, 1.0):
        _hut_maren_quad_slab(
            roof,
            [
                P(RIDGE_BACK, 0.0, RIDGE_Z),
                P(RIDGE_FRONT, 0.0, RIDGE_Z),
                P(RIDGE_FRONT, s * EAVE_S, EAVE_Z),
                P(RIDGE_BACK, s * EAVE_S, EAVE_Z),
            ],
            0.35,
        )
        for course in range(3):
            t0 = 0.02 + course * 0.32
            for seg in range(9):
                # Ragged, overlapping BLADES rather than tiles: every frond
                # runs a different distance down the slope and laps its
                # neighbour sideways, so the eave line comes out torn. The
                # courses cover ridge to eave - a bald patch on the upper
                # slope was the first pass's tell.
                t1 = t0 + 0.44 + rng.uniform(-0.07, 0.12)
                f0 = RIDGE_BACK + (RIDGE_FRONT - RIDGE_BACK) * (seg / 9.0) + rng.uniform(-0.2, 0.2)
                f1 = f0 + (RIDGE_FRONT - RIDGE_BACK) / 9.0 + rng.uniform(0.3, 0.7)  # blades overlap sideways too
                # Lifted less than the frond is thick, so every blade still
                # BITES the roof plane under it - nothing hovers.
                lift = 0.05 + rng.uniform(0.0, 0.09)
                first = len(roof.faces)
                _hut_maren_quad_slab(
                    roof,
                    [
                        P(f0, s * EAVE_S * t0, EAVE_Z + (RIDGE_Z - EAVE_Z) * (1 - t0) + lift),
                        P(f1, s * EAVE_S * t0, EAVE_Z + (RIDGE_Z - EAVE_Z) * (1 - t0) + lift),
                        P(f1, s * EAVE_S * t1, EAVE_Z + (RIDGE_Z - EAVE_Z) * (1 - t1) + lift * 0.5),
                        P(f0, s * EAVE_S * t1, EAVE_Z + (RIDGE_Z - EAVE_Z) * (1 - t1) + lift * 0.5),
                    ],
                    0.3,
                )
                if rng.random() < 0.45:
                    _hut_maren_paint(roof, first, 1)  # the darker frond, for depth

    # ---- props: material slots 0 plank / 1 cloth / 2 fish / 3 iron / 4 jar ----
    # EXTERIOR. The market counter Maren trades over, across the porch front.
    B(props, 8.9, 2.6, FLOOR + 3.2, 2.8, 7.4, 0.28)  # spans fwd 7.5..10.3
    first = len(props.faces)
    B(props, 10.2, 2.6, FLOOR + 2.3, 0.34, 7.4, 1.7)  # the fold-down apron board
    for side in (-0.7, 5.8):
        x, y, _ = P(10.1, side, 0)
        add_post(props, x, y, FLOOR - 0.1, FLOOR + 3.15, 0.22, sides=4)
        # ...and the fold-out's brace arms, running back INTO the front wall it
        # hinges off, so the counter is carried by the shack, not by air.
        arm = Vector(P(FRONT - 0.3, side, FLOOR + 1.5)) - Vector(P(7.6, side, FLOOR + 3.05))
        add_cone(props, P(7.6, side, FLOOR + 3.05), 0.16, 0.12, arm.length + 0.3, sides=3, tilt=_tilt_toward(arm.normalized()))
    _hut_maren_paint(props, first, 0)

    # Strings of drying fish: one line across the porch between the posts,
    # one down the left eave. Flattened blobs hanging off a thin cord.
    def fish_line(f0, s0, f1, s1, z, count):
        first = len(props.faces)
        p0, p1 = Vector(P(f0, s0, z)), Vector(P(f1, s1, z))
        add_cone(props, tuple(p0), 0.06, 0.06, (p1 - p0).length, sides=3, tilt=_tilt_toward((p1 - p0).normalized()))
        for i in range(count):
            t = (i + 0.5) / count
            p = p0 + (p1 - p0) * t
            drop = rng.uniform(0.7, 1.3)
            # cord from the line DOWN to the fish, then the fish on its end -
            # a hung fish must touch what it hangs from.
            add_cone(props, (p.x, p.y, p.z - drop), 0.05, 0.05, drop, sides=3)
            add_blob(props, (p.x, p.y, p.z - drop - 0.5), (0.2, 0.42, 0.85), 0.12, salt=40.0 + i * 3.1, yaw=a)
        _hut_maren_paint(props, first, 2)

    # Both lines are strung post-to-post / post-to-wall, ends buried in the wood.
    fish_line(PORCH - 0.9, -5.4, PORCH - 0.9, 5.4, FLOOR + 6.9, 6)
    fish_line(FRONT - 0.3, -5.9, PORCH - 0.9, -5.4, FLOOR + 5.9, 4)

    # Stacked crab traps by the ramp, and the rain barrel under the eave.
    first = len(props.faces)
    for k in range(3):  # traps rest ON the deck and ON each other (no gaps)
        B(props, 7.9 + k * 0.3, -4.9 + k * 0.25, FLOOR + 0.72 + k * 1.5, 1.9 - k * 0.12, 1.9 - k * 0.12, 1.6)
        B(props, 7.9 + k * 0.3, -4.9 + k * 0.25, FLOOR + 1.5 + k * 1.5, 2.1 - k * 0.12, 0.22, 0.18)  # slats
    bx, by, _ = P(-4.4, 5.4, 0)
    add_post(props, bx, by, FLOOR - 0.1, FLOOR + 2.7, 1.25, sides=8)
    add_post(props, bx, by, FLOOR + 2.3, FLOOR + 2.6, 1.38, sides=8)  # the iron hoop
    _hut_maren_paint(props, first, 0)

    # The gull on the ridgepole, watching the counter.
    first = len(props.faces)
    add_blob(props, P(8.6, 0.0, RIDGE_Z + 0.75), (0.9, 0.55, 0.5), 0.1, salt=71.0, yaw=a)
    add_blob(props, P(9.3, 0.0, RIDGE_Z + 1.25), (0.42, 0.38, 0.38), 0.08, salt=77.0, yaw=a)
    add_cone(props, P(9.6, 0.0, RIDGE_Z + 1.25), 0.16, 0.03, 0.6, sides=3, tilt=_tilt_toward(Vector((fx, fy, 0.0))))
    _hut_maren_paint(props, first, 2)

    # INTERIOR. The hammock, slung corner to corner and sagging in the middle.
    first = len(props.faces)
    h0, h1 = (-5.3, -5.3), (4.9, 5.3)
    axis = Vector((h1[0] - h0[0], h1[1] - h0[1], 0.0)).normalized()
    perp = Vector((-axis.y, axis.x, 0.0)) * 1.15
    prev = None
    for i in range(7):
        t = i / 6.0
        fwd = h0[0] + (h1[0] - h0[0]) * t
        side = h0[1] + (h1[1] - h0[1]) * t
        z = FLOOR + 5.6 - 8.0 * t * (1 - t)
        cur = ((fwd + perp.x, side + perp.y, z), (fwd - perp.x, side - perp.y, z))
        if prev:
            _hut_maren_quad_slab(
                props,
                [P(*prev[0]), P(*prev[1]), P(*cur[1]), P(*cur[0])],
                0.12,
            )
        prev = cur
    # Each end rope runs from the hammock's end UP INTO the wall corner it is
    # tied to - both ends physically meet the shack.
    for corner, cs in ((h0, (-1.0, -1.0)), (h1, (1.0, 1.0))):
        end = Vector(P(corner[0], corner[1], FLOOR + 5.6))
        tie = Vector(P(cs[0] * (HW - T + 0.4), cs[1] * (HW - T + 0.4), FLOOR + 7.9))
        add_cone(props, tuple(end), 0.1, 0.06, (tie - end).length, sides=3, tilt=_tilt_toward((tie - end).normalized()))
    _hut_maren_paint(props, first, 1)

    # The fish-gutting table, its cleaver, and the shelf of pickle jars.
    first = len(props.faces)
    B(props, 2.2, -3.4, FLOOR + 2.85, 4.6, 2.3, 0.3)
    for f_ in (0.2, 4.2):
        for s_ in (-4.3, -2.5):
            tx, ty, _ = P(f_, s_, 0)
            add_post(props, tx, ty, FLOOR - 0.1, FLOOR + 2.85, 0.18, sides=4)
    B(props, -5.1, 2.8, FLOOR + 5.0, 1.0, 5.6, 0.28)  # the jar shelf, let into the back wall
    for s_ in (0.6, 5.0):  # ...on brackets that reach the wall
        B(props, -5.15, s_, FLOOR + 4.55, 0.9, 0.22, 0.62)
    B(props, 2.6, -3.4, FLOOR + 3.14, 1.1, 0.16, 0.28)  # the cleaver's handle
    _hut_maren_paint(props, first, 0)
    first = len(props.faces)
    B(props, 1.7, -3.4, FLOOR + 3.3, 1.3, 0.1, 0.66)  # the cleaver blade
    add_blob(props, P(-1.0, -(HW - T - 1.2), FLOOR + 2.6), (0.85, 0.85, 0.75), 0.12, salt=91.0)  # the kettle
    for k in range(3):  # the tripod legs, each leaning IN to carry the kettle
        ang = k * math.tau / 3
        add_cone(
            props,
            P(-1.0 + math.cos(ang) * 0.9, -(HW - T - 1.2) + math.sin(ang) * 0.9, FLOOR + 1.7),
            0.08,
            0.05,
            1.9,
            sides=3,
            tilt=(math.sin(ang) * 0.4, -math.cos(ang) * 0.4),
        )
    _hut_maren_paint(props, first, 3)
    first = len(props.faces)
    for k in range(5):  # the pickle jars, standing ON the shelf
        s_ = 0.5 + k * 1.05
        jx, jy, _ = P(-5.1, s_, 0)
        add_post(props, jx, jy, FLOOR + 5.06, FLOOR + 6.1 + (k % 3) * 0.12, 0.4, sides=5)
    _hut_maren_paint(props, first, 4)

    # The framed fish picture, let into the back wall clear of the jar shelf.
    first = len(props.faces)
    B(props, BACK + T - 0.05, -2.4, FLOOR + 6.2, 0.3, 3.4, 2.4)
    _hut_maren_paint(props, first, 0)
    first = len(props.faces)
    B(props, BACK + T + 0.16, -2.4, FLOOR + 6.2, 0.2, 2.7, 1.8)
    _hut_maren_paint(props, first, 2)

    # ---- glow: the hearth embers under the kettle, and the counter lantern ----
    for k in range(5):
        add_cone(
            glow,
            P(-1.0 + rng.uniform(-0.8, 0.8), -(HW - T - 1.2) + rng.uniform(-0.7, 0.7), FLOOR + 1.82),
            rng.uniform(0.18, 0.34),
            0.05,
            rng.uniform(0.35, 0.7),
            sides=4,
        )
    add_box(glow, P(8.9, 5.5, FLOOR + 3.75), (0.7, 0.7, 0.9), yaw=a)  # the stall lantern, stood on the counter

    door = P(FRONT, (DOOR_LO + DOOR_HI) / 2, 0)
    stand = P(7.3, 2.6, 0)  # behind the counter, on the porch
    print(
        f"[island_gen] HANDOFF tropical hut (Old Maren's stilt shack): floor Y={FLOOR:.1f}, "
        f"door (Roblox rel) X={door[0]:.1f} Z={-door[1]:.1f}, counter stand X={stand[0]:.1f} Z={-stand[1]:.1f}; "
        f"Npcs.old_maren spawnOffset suggestion Vector3.new({stand[0]:.0f}, 0, {-stand[1] - (-50.0):.0f}) facing 162"
    )
    return [
        object_from_bmesh("Island_Hut_Walls", walls, ["M_Driftwood", "M_Rock"]),
        object_from_bmesh("Island_Hut_Roof", roof, ["M_Frond", "M_FrondDark"]),
        object_from_bmesh("Island_Hut_Props", props, ["M_Plank", "M_HutCloth", "M_HutFish", "M_HutIron", "M_HutJar"]),
        object_from_bmesh("Island_Hut_Glow", glow, ["M_HutEmber"]),
    ]


# ---------------------------------------------------------------- island builds


def build_tropical():
    objects = [
        build_island_base("Island_Base", ["M_Grass", "M_Sand", "M_WetSand"]),
        build_rocks(),
        *build_palms(),
        build_bushes(),
        *build_dock(),
        *build_hut_maren(),  # Old Maren's stilt shack, on the sand by the spawn
        build_foam("Island_Foam", "M_Foam"),
    ]
    validate_placement(PALM_CHECKPOINTS, BUSH_CHECKPOINTS)
    print(f"[island_gen] placement OK: {len(PALM_CHECKPOINTS)} palm points, {len(BUSH_CHECKPOINTS)} bushes clear")
    return objects


# ---------------------------------------------------------------- volcano: Brakk's forge-hold
#
# The Cinder-Smith's hold: a SQUAT BASALT-BLOCK BUNKER dug into the ash apron
# with a magma channel running clean THROUGH it. The rill comes down off the
# slope, ducks under the back wall through a culvert, runs the length of the
# floor under an iron grate, and pools in an open hearth on the FRONT face -
# where the counter you talk to Brakk over IS his anvil. Five layers, one
# material each:
#   Volcano_Hut_Walls  block courses, plinth, floor, chimney, hearth, trough
#   Volcano_Hut_Roof   the slate roof slabs, lintels and the forge hood
#   Volcano_Hut_Props  anvil counter, anvil, floor grate, tool rail + tongs
#                      and hammers, blade racks and blades, the bell's gibbet
#   Volcano_Hut_Trim   the cracked cannon-shell bell, brass ingots, sulfur
#   Volcano_Hut_Glow   the magma rill, the forge heart, the chimney's lip
#
# Sited 9.5 deg off the 270 dock lane (the apron scatter's own keep-clear
# angle) on the flat-ish band at u 0.84, with the building's long axis ALONG
# the contour so only its 18-stud depth crosses the apron's ~0.12/stud fall -
# the plinth takes up the rest. The nearest lava river bearing is 205, some
# 300 studs away.
#
# Walk-in contract: a 5.0 x 7.5 door, a 19 x 15 clear floor, 10 studs to the
# roof, 1.4-stud walls (PreciseConvexDecomposition on import).

_HUT_B_BEARING = math.radians(279.5)
_HUT_B_U = 0.84
_HUT_B_KEEP = []  # (x, y, radius): honoured by the dead-tree and rock scatters

_HUT_B_HX = 11.0  # half-width along the contour (local +x)
_HUT_B_HY = 9.0  # half-depth up the slope (local +y is INLAND / uphill)
_HUT_B_WALL = 1.4
_HUT_B_COURSE = 2.5
_HUT_B_COURSES = 4  # 10 studs of wall
_HUT_B_DOOR = (-8.2, -3.2)  # the doorway's x span on the front face
_HUT_B_DOOR_H = 7.5  # three courses
_HUT_B_FORGE = (1.6, 8.6)  # the open hearth's x span; sill at one course up
_HUT_B_HEARTH = 5.1  # x of the hearth, the chimney and the magma channel
_HUT_B_DOORX = -_HUT_B_HY  # the door plane, for the walk-in check


def _hut_b_site():
    """(centre x, centre y, yaw). Yaw puts the hold's +x along the contour and
    its +y INLAND, so the front face - door, hearth, anvil counter - looks
    down the apron at the dock and the spawn."""
    r = ring_radius(_HUT_B_U, _HUT_B_BEARING)
    return math.cos(_HUT_B_BEARING) * r, math.sin(_HUT_B_BEARING) * r, _HUT_B_BEARING + math.pi / 2


def _hut_b_pt(site, x, y, z):
    cx, cy, yaw = site
    ca, sa = math.cos(yaw), math.sin(yaw)
    return (cx + x * ca - y * sa, cy + x * sa + y * ca, z)


def _hut_b_box(bm, site, x, y, z, size, spin=0.0):
    add_box(bm, _hut_b_pt(site, x, y, z), size, yaw=site[2] + spin)


def _hut_b_cone(bm, site, x, y, z, r0, r1, h, sides=6, tilt=(0.0, 0.0), spin=0.0):
    add_cone(bm, _hut_b_pt(site, x, y, z), r0, r1, h, sides=sides, tilt=tilt, yaw=site[2] + spin)


def _hut_b_floor(gz):
    """Floor level: the HIGHEST ash under the building, so the apron can never
    heave up through the flags. The plinth below takes the ~2-stud fall to the
    downhill (front) corner, and two steps carry the sill down to the ash."""
    return max(gz(x, y) for x in (-10.0, -5.0, 0.0, 5.0, 10.0)
               for y in (-8.0, -4.0, 0.0, 4.0, 8.0)) + 0.10


def _hut_b_panel(bm, site, rng, z0, lo, hi, z_lo, z_hi, fixed, along_x):
    """Fill ONE rectangle of wall - a pier between openings, the strip over a
    door, the sill under the hearth mouth - with overlapping coursed basalt.
    Openings are made by leaving panels OUT, never by deleting whole blocks
    from a running course: a 5-stud doorway laid that way ate a 9-stud hole.
    Blocks overlap their neighbours in both directions, and each stands a
    little proud of the next, or four courses render as one flat grey slab."""
    span, rise = hi - lo, z_hi - z_lo
    if span < 0.4 or rise < 0.4:
        return
    n = max(1, int(round(span / 3.1)))
    rows = max(1, int(round(rise / _HUT_B_COURSE)))
    pitch, ch = span / n, rise / rows
    out = -1.0 if fixed < 0 else 1.0
    grounded = z_lo < 0.1  # the bottom course reaches down into the plinth
    for c in range(rows):
        za = z_lo + ch * c
        for k in range(n):
            m = lo + pitch * (k + 0.5)
            t = pitch + 0.20
            h = ch + 0.16 + (0.9 if (grounded and c == 0) else 0.0)
            zc = z0 + za + ch * 0.5 - (0.45 if (grounded and c == 0) else 0.0)
            d = _HUT_B_WALL + 0.12 + rng.uniform(0.0, 0.42)
            off = out * (d - _HUT_B_WALL - 0.12) * 0.5
            size = (t, d, h) if along_x else (d, t, h)
            pos = (m, fixed + off) if along_x else (fixed + off, m)
            _hut_b_box(bm, site, pos[0], pos[1], zc, size, spin=rng.uniform(-0.03, 0.03))


def build_volcano_hut(ground):
    """BRAKK'S FORGE-HOLD. Deterministic on its own Random(9151), so adding it
    does not move one boulder of the apron's shared random stream."""
    rng = random.Random(9151)
    site = _hut_b_site()
    cx, cy, yaw = site
    stone, roof, props, trim, glow = (bmesh.new() for _ in range(5))

    def gz(x, y):
        """The REAL ash height under a local point. Every prop outside the
        building is seated on this - nothing is offset from a nominal level."""
        p = _hut_b_pt(site, x, y, 0.0)
        g = _drop_to_ground(ground, p[0], p[1])
        return g if g is not None else height_at(p[0], p[1])

    z0 = _hut_b_floor(gz)
    hx, hy, wall = _HUT_B_HX, _HUT_B_HY, _HUT_B_WALL
    hearth = _HUT_B_HEARTH
    top = z0 + _HUT_B_COURSE * _HUT_B_COURSES  # 10 studs: the wall head

    # --- plinth and floor ---------------------------------------------------
    # One solid pad down to 4 studs under the floor: the uphill half is buried,
    # the downhill half stands out as the plinth the walls sit on.
    _hut_b_box(stone, site, 0.0, 0.0, z0 - 2.05, (hx * 2 + 1.6, hy * 2 + 1.6, 4.1))
    # The flagged floor, in two halves - the gap between them IS the magma
    # trench, so the rill is a real slot in the floor, not a stripe painted on
    # it. A slab under the trench closes its bottom.
    _hut_b_box(stone, site, (-hx + hearth - 1.4) * 0.5, 0.0, z0 - 0.4,
               (hearth - 1.4 + hx, hy * 2, 0.9))
    _hut_b_box(stone, site, (hx + hearth + 1.4) * 0.5, 0.0, z0 - 0.4,
               (hx - hearth - 1.4, hy * 2, 0.9))
    _hut_b_box(stone, site, hearth, 1.0, z0 - 1.85, (2.9, hy * 2 + 4.0, 1.5))

    # --- the four walls -----------------------------------------------------
    d0, d1 = _HUT_B_DOOR
    f0, f1 = _HUT_B_FORGE
    front_y, back_y = -(hy - wall * 0.5), hy - wall * 0.5

    def front(lo, hi, z_lo, z_hi):
        _hut_b_panel(stone, site, rng, z0, lo, hi, z_lo, z_hi, front_y, True)

    front(-hx, d0, 0.0, top - z0)  # the west pier
    front(d1, f0, 0.0, top - z0)  # the pier between door and hearth
    front(f1, hx, 0.0, top - z0)  # the east pier
    front(d0, d1, _HUT_B_DOOR_H, top - z0)  # over the door
    front(f0, f1, 0.0, _HUT_B_COURSE)  # the hearth's sill - the anvil's bed
    front(f0, f1, _HUT_B_DOOR_H, top - z0)  # over the hearth mouth
    _hut_b_panel(stone, site, rng, z0, -hx, hearth - 1.9, 0.0, top - z0, back_y, True)
    _hut_b_panel(stone, site, rng, z0, hearth + 1.9, hx, 0.0, top - z0, back_y, True)
    _hut_b_panel(stone, site, rng, z0, hearth - 1.9, hearth + 1.9, _HUT_B_COURSE,
                 top - z0, back_y, True)  # over the culvert the rill runs in through
    for sx in (-1.0, 1.0):
        _hut_b_panel(stone, site, rng, z0, -hy, hy, 0.0, top - z0, sx * (hx - wall * 0.5), False)
    # Lintels: over the door, over the hearth mouth, over the culvert. Each
    # one beds into the block courses either side of its opening.
    _hut_b_box(roof, site, sum(_HUT_B_DOOR) * 0.5, -(hy - wall * 0.5), z0 + _HUT_B_DOOR_H + 0.35,
               (_HUT_B_DOOR[1] - _HUT_B_DOOR[0] + 2.4, wall + 0.5, 0.9))
    _hut_b_box(roof, site, sum(_HUT_B_FORGE) * 0.5, -(hy - wall * 0.5), z0 + _HUT_B_DOOR_H + 0.35,
               (_HUT_B_FORGE[1] - _HUT_B_FORGE[0] + 2.4, wall + 0.5, 0.9))
    _hut_b_box(roof, site, hearth, hy - wall * 0.5, z0 + _HUT_B_COURSE + 0.3,
               (5.4, wall + 0.5, 0.8))

    # --- roof ---------------------------------------------------------------
    # Five heavy slate slabs laid across the hold on two purlins, overhanging
    # the walls by a stud and a bit. They rest ON the wall head.
    for sy in (-1.0, 1.0):
        _hut_b_box(roof, site, 0.0, sy * (hy - 2.2), top - 0.35, (hx * 2 + 0.8, 1.5, 1.0))
    for k in range(5):
        y = -hy + 1.9 + k * 3.55
        _hut_b_box(roof, site, rng.uniform(-0.2, 0.2), y, top + 0.45 + rng.uniform(-0.08, 0.08),
                   (hx * 2 + 2.6, 3.9, 0.95), spin=rng.uniform(-0.02, 0.02))

    # --- the hearth, the chimney and the magma channel ----------------------
    # Hearth masonry: two cheeks and a back, open to the front, standing on
    # the floor. The molten pool sits between them, set 0.15 under the sill.
    for sx in (-1.0, 1.0):
        _hut_b_box(stone, site, hearth + sx * 3.3, -6.4, z0 + 2.5, (1.2, 5.4, 5.0))
    _hut_b_box(stone, site, hearth, -3.9, z0 + 2.75, (7.8, 1.4, 5.5))
    _hut_b_box(stone, site, hearth, -6.4, z0 + 0.45, (5.6, 5.4, 1.0))  # the fire bed
    # The hood over the hearth, and the chimney climbing out through the roof.
    _hut_b_box(roof, site, hearth, -5.6, z0 + 8.1, (8.2, 5.2, 1.4))
    _hut_b_box(roof, site, hearth, -4.6, z0 + 9.3, (5.6, 3.4, 1.6))
    _hut_b_box(stone, site, hearth, -4.4, top + 1.4, (4.4, 4.4, 4.0))
    _hut_b_box(stone, site, hearth, -4.4, top + 5.0, (3.8, 3.8, 3.6))
    _hut_b_box(stone, site, hearth, -4.4, top + 8.2, (3.2, 3.2, 3.0))
    _hut_b_box(stone, site, hearth, -4.4, top + 9.9, (4.0, 4.0, 0.9))  # the cap course

    # The rill: one continuous molten ribbon from a fissure out on the slope,
    # down under the back wall, along the floor trench and into the hearth.
    # Every sample takes its height from the ground it is running over, so the
    # channel never leaves the ash on the way down.
    rows_l, rows_r = [], []
    ys = [20.0, 17.0, 14.0, 11.5, 9.6, 7.0, 4.0, 1.0, -2.0, -4.6]
    for y in ys:
        if y > 9.6:
            # Outside, the rill RIDES the ash between its kerbs (the island's
            # own lava sheets do the same, for the same reason: a channel sunk
            # into a surface that has no trench in it is simply buried).
            zt = gz(hearth, y) + 0.35
        else:
            # Inside, the rill fills its slot to the flags: recessed even a
            # quarter stud and there is nothing to see between the grate bars.
            zt = z0 + 0.02 + (gz(hearth, 9.6) + 0.35 - (z0 + 0.02)) * max(0.0, (y - 4.0) / 5.6)
        rows_l.append(Vector(_hut_b_pt(site, hearth - 1.3, y, zt)))
        rows_r.append(Vector(_hut_b_pt(site, hearth + 1.3, y, zt)))
    add_strip_slab(glow, rows_l, rows_r, 2.4)
    # The forge heart, standing tall enough in its hearth that it fills the
    # upper half of the mouth with light over the anvil counter.
    _hut_b_cone(glow, site, hearth, -6.4, z0 + 0.85, 2.4, 1.9, 2.4, sides=9)
    _hut_b_cone(glow, site, hearth, -6.4, z0 + 3.0, 1.55, 0.35, 2.4, sides=6)  # the flame off it
    _hut_b_cone(glow, site, hearth, -4.4, top + 9.6, 1.4, 1.2, 0.7, sides=6)  # ember at the lip
    # Trench lips, and the rill's banks out on the slope: laid stone kerbs
    # that sit on their own ground for the whole run.
    for sx in (-1.0, 1.0):
        for k in range(4):
            y = 10.0 + k * 3.4
            _hut_b_box(stone, site, hearth + sx * 2.35, y, gz(hearth + sx * 2.35, y) + 0.15,
                       (1.6, 3.7, 1.9), spin=rng.uniform(-0.05, 0.05))
    _hut_b_cone(glow, site, hearth, 21.4, gz(hearth, 21.4) - 0.9, 4.4, 2.4, 1.5, sides=9)  # the fissure
    # Ember bleeding out of the joints beside the hearth - the wall itself is
    # hot. Each sliver is bedded 0.3 into the blocks it shows between.
    for k, (ex, ez) in enumerate(((0.2, 1.1), (9.9, 3.4), (10.4, 6.0), (-0.4, 5.2))):
        _hut_b_box(glow, site, ex, -(hy - 0.15), z0 + ez, (1.7, 1.0, 0.32),
                   spin=rng.uniform(-0.05, 0.05))

    # --- iron: counter, anvil, grate, tools ---------------------------------
    # THE COUNTER IS THE ANVIL: a hardie block bedded on the hearth sill,
    # spanning the mouth, with its horn out over the ash.
    _hut_b_box(props, site, sum(_HUT_B_FORGE) * 0.5, -(hy + 0.3), z0 + _HUT_B_COURSE + 0.45,
               (_HUT_B_FORGE[1] - _HUT_B_FORGE[0] - 0.4, 3.6, 1.1))
    _hut_b_box(props, site, sum(_HUT_B_FORGE) * 0.5, -(hy + 0.3), z0 + _HUT_B_COURSE - 0.3,
               (3.4, 2.4, 1.4))
    _hut_b_cone(props, site, _HUT_B_FORGE[1] - 0.2, -(hy + 0.3), z0 + _HUT_B_COURSE + 0.45,
                0.9, 0.35, 2.2, sides=5, tilt=(0.0, math.pi / 2))  # the horn
    # The floor grate over the trench.
    for k in range(7):
        _hut_b_box(props, site, hearth, -1.4 + k * 1.35, z0 + 0.20, (3.4, 0.5, 0.55))
    # The tool wall: a peg rail down the west side, every tong and hammer
    # hanging THROUGH it.
    _hut_b_box(props, site, -(hx - wall - 0.35), 1.0, z0 + 5.6, (0.7, 13.0, 0.5))
    for k in range(7):
        y = -4.6 + k * 1.9
        kind = k % 3
        if kind == 0:  # a hammer: head across the shaft
            _hut_b_cone(props, site, -(hx - wall - 0.45), y, z0 + 5.9, 0.22, 0.20,
                        -2.6, sides=4)
            _hut_b_box(props, site, -(hx - wall - 0.75), y, z0 + 3.5, (1.5, 0.7, 0.7))
        elif kind == 1:  # tongs: two legs off one peg
            for s in (-1.0, 1.0):
                _hut_b_cone(props, site, -(hx - wall - 0.45), y, z0 + 5.9, 0.20, 0.13,
                            -3.2, sides=4, tilt=(0.0, 0.14 * s))
        else:  # a file / punch
            _hut_b_cone(props, site, -(hx - wall - 0.45), y, z0 + 5.9, 0.26, 0.10,
                        -2.9, sides=4)
    # The working anvil on its stump, and the stone slab bed against the back.
    _hut_b_cone(props, site, -2.6, 3.2, z0, 1.35, 1.25, 1.5, sides=6)
    _hut_b_box(props, site, -2.6, 3.2, z0 + 1.85, (3.6, 1.5, 0.9))
    _hut_b_cone(props, site, -0.9, 3.2, z0 + 1.85, 0.75, 0.28, 1.9, sides=5,
                tilt=(0.0, math.pi / 2))
    for sx in (-1.0, 1.0):
        _hut_b_box(stone, site, -6.6 + sx * 2.0, 6.6, z0 + 0.75, (1.6, 3.4, 1.5))
    _hut_b_box(stone, site, -6.6, 6.6, z0 + 1.85, (6.4, 4.0, 0.8))
    _hut_b_cone(trim, site, -6.6, 6.6, z0 + 2.55, 1.5, 1.2, 0.7, sides=6)  # the bedroll

    # --- brass and sulfur ---------------------------------------------------
    for s, (bx, by) in enumerate(((9.2, 3.2), (9.2, 5.8), (8.0, 7.4))):  # clear of the trench
        for c in range(3 - (s % 2)):
            _hut_b_box(trim, site, bx, by, z0 + 0.35 + c * 0.62, (2.6, 1.6, 0.7),
                       spin=rng.uniform(-0.12, 0.12))
    for k in range(4):  # slumped sacks of sulfur, not traffic cones
        sx, sy = -8.8 + k * 1.6, 4.6 + (k % 2) * 1.9  # the back-west corner, out of the walk
        _hut_b_cone(trim, site, sx, sy, z0, rng.uniform(0.95, 1.25),
                    rng.uniform(0.72, 0.95), rng.uniform(1.0, 1.4), sides=6,
                    spin=rng.uniform(0, 1.0))
        _hut_b_cone(trim, site, sx, sy, z0 + 1.0, 0.78, 0.30, 0.6, sides=5,
                    spin=rng.uniform(0, 1.0))  # the tied throat

    # --- the yard -----------------------------------------------------------
    # Two steps down off the sill to the ash.
    _hut_b_box(stone, site, sum(_HUT_B_DOOR) * 0.5, -(hy + 1.3), z0 - 0.55, (6.6, 3.0, 1.2))
    _hut_b_box(stone, site, sum(_HUT_B_DOOR) * 0.5, -(hy + 3.4),
               (gz(-5.7, -(hy + 3.4)) + z0) * 0.5 - 0.85, (6.0, 2.6, 1.8))
    # The quench trough: a hollowed basalt block on the ash, with a blade
    # still lying across it and the water hissing.
    tx, ty = -12.0, -6.0
    tg = gz(tx, ty)
    _hut_b_box(stone, site, tx, ty, tg + 0.7, (3.6, 7.4, 2.2))
    for sy in (-1.0, 1.0):
        _hut_b_box(stone, site, tx, ty + sy * 3.1, tg + 1.75, (3.6, 1.2, 1.0))
    for sx in (-1.0, 1.0):
        _hut_b_box(stone, site, tx + sx * 1.5, ty, tg + 1.75, (0.7, 5.2, 1.0))
    _hut_b_box(props, site, tx, ty, tg + 1.70, (2.4, 5.0, 0.5))  # the black water
    _hut_b_cone(props, site, tx, ty - 3.6, tg + 2.15, 0.42, 0.12, 5.6, sides=4,
                tilt=(-0.28, 0.0))  # a blade laid across it, still hissing
    _hut_b_box(glow, site, tx, ty - 1.4, tg + 1.78, (0.9, 2.2, 0.42))  # where it went in
    # Two racks of half-finished blades either side of the yard. Posts driven
    # into the ash, rail on the posts, every blade standing through the rail.
    for side, rx in ((-1.0, -15.6), (1.0, 15.6)):
        base = min(gz(rx, -2.0), gz(rx, 4.0))
        for k in (-1.0, 1.0):
            _hut_b_cone(props, site, rx, 1.0 + k * 3.2, base - 0.8, 0.5, 0.38, 5.4, sides=5)
        _hut_b_box(props, site, rx, 1.0, base + 4.1, (0.6, 7.4, 0.6))
        for k in range(6):
            y = -2.3 + k * 1.15
            _hut_b_cone(props, site, rx + rng.uniform(-0.1, 0.1), y, gz(rx, y) - 0.35,
                        rng.uniform(0.45, 0.62), 0.14, rng.uniform(4.9, 5.7), sides=4,
                        tilt=(rng.uniform(0.08, 0.18) * side, rng.uniform(-0.08, 0.08)),
                        spin=rng.uniform(-0.2, 0.2))
    # THE BELL - a cracked cannon shell - hung from an iron gibbet by the door.
    bx, by = -13.6, -12.2
    bg = gz(bx, by)
    _hut_b_cone(props, site, bx, by, bg - 0.8, 0.46, 0.32, 11.0, sides=5)  # the gibbet post
    _hut_b_box(props, site, bx + 1.7, by, bg + 9.7, (3.9, 0.5, 0.5))  # its arm
    _hut_b_box(props, site, bx + 3.1, by, bg + 8.85, (0.45, 0.45, 2.1))  # the shackle
    # The shell hangs mouth-DOWN off that shackle, cracked lip and all.
    _hut_b_cone(trim, site, bx + 3.1, by, bg + 6.0, 1.05, 0.50, 2.5, sides=8)
    _hut_b_cone(trim, site, bx + 3.1, by, bg + 8.3, 0.48, 0.30, 0.9, sides=6)  # its crown
    _hut_b_cone(props, site, bx + 3.1, by, bg + 4.9, 0.18, 0.18, 1.4, sides=4)  # the clapper

    door = _hut_b_pt(site, sum(_HUT_B_DOOR) * 0.5, -(hy + 1.0), 0.0)
    stand = _hut_b_pt(site, sum(_HUT_B_FORGE) * 0.5, -(hy + 4.2), 0.0)
    shore = ring_radius(1.0, math.radians(270))
    spawn_z = shore - 30.0
    dx, dz = math.cos(_HUT_B_BEARING), -math.sin(_HUT_B_BEARING)  # Roblox X/Z, facing out
    facing = math.degrees(math.atan2(-dx, -dz)) % 360.0
    print(
        f"[island_gen] HANDOFF volcano hut: Brakk's forge-hold, door (Roblox rel) "
        f"X={door[0]:.0f} Z={-door[1]:.0f}, anvil counter X={stand[0]:.0f} Z={-stand[1]:.0f}, "
        f"sill Y~{z0:.1f}; suggested brakk spawnOffset Vector3.new({stand[0]:.0f}, 0, "
        f"{-stand[1] - spawn_z:.0f}) facing {facing:.0f} "
        f"(island spawn is X=0 Z={spawn_z:.0f}; the hold sits {math.hypot(stand[0], -stand[1] - spawn_z):.0f} studs from it, "
        f"the nearest legal spot outside the 9-deg dock corridor)"
    )
    return (
        object_from_bmesh("Volcano_Hut_Walls", stone, ["M_ForgeBasalt"]),
        object_from_bmesh("Volcano_Hut_Roof", roof, ["M_ForgeSlate"]),
        object_from_bmesh("Volcano_Hut_Props", props, ["M_ForgeIron"]),
        object_from_bmesh("Volcano_Hut_Trim", trim, ["M_ForgeBrass"]),
        object_from_bmesh("Volcano_Hut_Glow", glow, ["M_ForgeEmber"]),
    )


def build_volcano():
    """RESTARTED FROM SCRATCH (2026-08-27, user: "completely start from
    scratch... a big base island with nothing on it") - the swamp-restart
    playbook applied to the volcano. The stratovolcano build (switchback
    trail, nine lava rivers, prop groves, the shore dock) was DELETED with
    step 1; the rebuild is step-by-step, each step reviewed from PNG previews
    and in Studio before the next.

    STEP 1 - the shape (iterated to the ~895-stud shattered spire on review);
    STEP 2 - the lava (build_lava: crater lake, six notch-fed rivers running
    rim to sea, apron pools + molten deltas); STEP 3 - the dead giants
    (build_volcano_trees); STEP 4 - the rocks (build_volcano_rocks: apron
    boulders + talus; flanks bare by user order); STEP 5 - the DOCK (the
    tropical dock verbatim on the 270-deg lane); STEP 6 - the shoreline
    foam (the standard thin white tide line + dock-post collars). The
    rebuild's geometry is COMPLETE; EruptionService was removed and lava
    deals no damage, both by user order."""
    base = build_island_base("Volcano_Base", ["M_VolRock", "M_VolAsh", "M_VolWet"])
    ground = _ground_bvh(base)
    # STEP 7 - Brakk's forge-hold. Its plot is claimed BEFORE the scatters run
    # (the hold itself is built last, off its own RNG, so the shared stream is
    # unmoved): no dead giant grows through the roof, no boulder lands in the
    # yard or across the magma rill.
    _HUT_B_KEEP.clear()
    _hut_b_c = _hut_b_site()
    _HUT_B_KEEP.append((*_hut_b_c[:2], 27.0))
    _HUT_B_KEEP.append((*_hut_b_pt(_hut_b_c, _HUT_B_HEARTH, 20.0, 0.0)[:2], 10.0))
    lava = build_lava(ground)  # step 2: clears + repopulates LAVA_PONDS itself
    trees = build_volcano_trees(ground)  # step 3: after lava - reads LAVA_PONDS to keep clear
    rocks = build_volcano_rocks(ground)  # step 4: same keep-clears
    hut = build_volcano_hut(ground)  # step 7: in the plot claimed above
    dock = build_dock("Volcano_Dock_Planks", "Volcano_Dock_Posts", "M_VolPlank", "M_VolPost")  # step 5
    foam = build_foam("Volcano_Foam", "M_VolFoam")  # step 6: after the dock - it collars the wet posts
    shore = ring_radius(1.0, math.radians(270))
    dock_start = ring_radius(DOCK_START_U, math.radians(270))
    dock_end = dock_start + DOCK_LENGTH + DOCK_END_LENGTH
    peak = max(h for _, h in PROFILE)
    print(
        f"[island_gen] HANDOFF volcano: peak ~{peak:.0f}, +Z shore at rel Z={shore:.0f}, "
        f"dock (Roblox rel) Z={dock_start:.0f}..{dock_end:.0f} plank top Y={DOCK_TOP}, "
        f"spawn suggestion X=0 Z={shore - 30:.0f} ground Y~{height_at(0, -(shore - 30)):.1f}; "
        f"Pyrelisk arena suggestion: rel Z={dock_end + 40:.0f} (open sea past the dock end)"
    )
    return [base, lava, trees, rocks, *hut, *dock, foam]


# ---------------------------------------------------------------- revamp islands (2026-08-25)
#
# The four new islands of the 7-island saga (docs/revamp-plan.md): Blackmire
# Fen (swamp), Frostmaw Reach (ice), Gloomtrench (abyss shelf) and Wreckwater
# (ghost-fleet lagoon). Same machinery as the volcano: a configured base, a
# ground BVH, pooled interior water (the fishable-surface contract names:
# Swamp_Water / Frostmaw_IceHoles / Gloomtrench_DarkWater / Wreckwater_Bay),
# prop scatter seated on the real faceted surface, the standard +Z sea dock
# and shoreline foam. Interior pools are recorded in LAVA_PONDS (despite the
# name - it is simply "keep-clear circles for the scatter").


def _pool_disc(bm, cx, cy, r, z_top, thickness, salt, squash=None):
    """One ragged interior pool, recorded for the prop scatter."""
    _jagged_disc(bm, cx, cy, r, r * (squash or random.uniform(0.72, 0.95)), z_top, thickness, salt)
    LAVA_PONDS.append((cx, cy, r))


def _interior_spot(ground, u_lo, u_hi, pad=3.0, tries=40):
    """A raycast-verified ground point in the walkable band, clear of the dock
    corridor and every recorded pool. The generic apron_spot, island-neutral."""
    for _ in range(tries):
        theta = random.uniform(0, math.tau)
        u = random.uniform(u_lo, u_hi)
        if _near_dock_corridor(theta, u):
            continue
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        if not _clear_of_ponds(x, z, pad):
            continue
        surface = _drop_to_ground(ground, x, z)
        if surface is not None:
            return x, z, surface
    return None


# ---- Blackmire Fen --------------------------------------------------------
#
# RESTARTED FROM SCRATCH (2026-08-27, user): the shipped mangrove fen was
# rejected wholesale ("absolutely atrocious" - grey unpainted canopy objects,
# water floating above the terrain, prop collision walling off the walkable
# ground), and the rebuild is deliberately step-by-step, reviewed in Studio
# between steps. Step 1 was the bare flat landform; step 2 the fen palette;
# THIS IS STEP 3, the marsh: pools of standing water SUNK INTO the ground
# across the middle. The core rule fixing the old "water floats on the
# island" bug: every pool's basin is carved into the heightfield itself
# (_swamp_height clamps the ground down to a real concave WATERBED below the
# water surface), and the Swamp_Water sheet is emitted from the exact same
# pool list, drawn smaller than its carve - so terrain and water physically
# cannot disagree. On top of the pools the interior rolls: dry concave
# divots and a gentle ground undulation, so the fen reads sunken-in-and-out
# rather than a snooker table with holes.
#
# Next steps (each on its own ask): trees/props, the dock + foam.

SWAMP_WATER_Z = 2.2  # standing-water plane (Blender z; sea is 0)
SWAMP_BED_Z = 0.9  # the flooded forest floor - ~1.3 studs under the water, wadeable
SWAMP_ISLET_Z = 3.5  # islet crowns - ~1.3 studs proud of the water
SWAMP_MARSH_U = 0.72  # the marsh floods the interior out to about here
SWAMP_RIM_U = 0.82  # by here the ground has climbed back above the water (the rim that holds it in)
SWAMP_SPAWN = (0.0, -117.0)  # keep-clear: the spawn shelf (Roblox rel Z=117; re-keyed when GRASS_U 0.88 pulled the shore to Z=147)
SWAMP_MERE = (0.0, -74.0, 30.0)
SWAMP_BASE_CENTER = [0.0, 0.0]  # Swamp_Base bbox centre, filled by build_swamp_base  # the boss mere: forced open water at Old Gnashroot's arena
# Morra's leaning bog hut (build_hut_morra): (x, y, keep-clear radius). The
# scatter builders below all steer round it the way they steer round the mere
# and the spawn shelf, and the circle is ALSO pushed into LAVA_PONDS (this
# region's shared keep-out registry) when the hut is built.
SWAMP_HUT = (-31.0, -119.0, 15.0)
SWAMP_HUT_FLOOR = 5.0  # the hut's deck: 2.8 studs clear of the standing water
_HUT_MORRA_YAW = math.atan2(-123.0 - SWAMP_HUT[1], -12.0 - SWAMP_HUT[0])  # door -> Morra's mark


def _hut_morra_clear(x, y, pad=0.0):
    """True where the fen's scatter may still plant - i.e. off Morra's hut,
    its plank path and its dooryard."""
    return math.hypot(x - SWAMP_HUT[0], y - SWAMP_HUT[1]) >= SWAMP_HUT[2] + pad


def _swamp_field(x, y):
    """The marsh's shape, one continuous noise field: negative = flooded
    floor, positive = ground rising out of it. Three octaves so the
    water/land boundary wanders - lobes, channels, peninsulas - instead of
    reading as stamped circles."""
    f = 0.58 * noise.noise(Vector((x * 0.011, y * 0.011, 21.4)))
    f += 0.30 * noise.noise(Vector((x * 0.028, y * 0.028, 8.9)))
    f += 0.12 * noise.noise(Vector((x * 0.07, y * 0.07, 3.3)))
    return f


def _swamp_height(x, y):
    """The fen's ground. Outside the marsh: the base profile (mud band,
    shore, skirt untouched). Inside: the floor sits BELOW the standing
    water and the noise field lifts islets and peninsulas up out of it -
    one huge flooded mangrove floor, ground sinking in and out of the
    water everywhere, every transition concave and walkable (the bed is
    only ~1.3 studs deep, so the whole marsh is wadeable)."""
    h = height_at(x, y)
    u = u_at(x, y)
    marsh = 1 - smoothstep(SWAMP_MARSH_U, SWAMP_RIM_U, u)
    if marsh <= 0:
        return h

    # Where between bed and islet this spot sits: the field, softened so
    # banks slope instead of stepping. The band is deliberately WIDE - a
    # narrow one made every islet edge a one-face cliff that read as
    # pixelated stair-steps (user, marsh v2 review).
    s = smoothstep(-0.26, 0.30, _swamp_field(x, y))

    # The boss mere is forced open water (no islet may grow in the arena),
    # and its bed dips an extra stud so it reads as the marsh's deep heart.
    mx, my, mr = SWAMP_MERE
    d_mere = math.hypot(x - mx, y - my)
    s = s * smoothstep(mr * 0.66, mr * 1.15, d_mere)
    extra_deep = 1.0 * (1 - smoothstep(mr * 0.4, mr, d_mere))

    # A dry approach shelf around the spawn so you land on ground, not murk.
    sx, sy = SWAMP_SPAWN
    s = max(s, 1 - smoothstep(14.0, 30.0, math.hypot(x - sx, y - sy)))

    wet = SWAMP_BED_Z - extra_deep + noise.noise(Vector((x * 0.05, y * 0.05, 14.2))) * 0.25
    dry = SWAMP_ISLET_Z + noise.noise(Vector((x * 0.02, y * 0.02, 6.1))) * 0.7
    marsh_h = wet + (dry - wet) * s
    return h + (marsh_h - h) * marsh


def build_swamp_base():
    """The fen landform: the shared radial-fan topology, every vertex from
    _swamp_height so the flooded floor and its islets are cut into the real
    mesh. Materials: the usual bands (peat / mud beach / wet), plus any
    interior face at or under the waterline paints wet mud - the submerged
    forest floor and every islet's mud rim."""
    bm = bmesh.new()
    center = bm.verts.new(Vector((0, 0, _swamp_height(0, 0))))
    rings = []
    for u in RINGS[1:]:
        ring = []
        for s in range(SEGMENTS):
            theta = (s / SEGMENTS) * math.tau
            r = ring_radius(u, theta)
            x, y = math.cos(theta) * r, math.sin(theta) * r
            ring.append(bm.verts.new(Vector((x, y, _swamp_height(x, y)))))
        rings.append(ring)

    def band_material(outer_u):
        if outer_u <= GRASS_U:
            return 0
        if outer_u <= 1.0:
            return 1
        return 2

    def face(verts, outer_u):
        f = bm.faces.new(verts)
        cz = sum(v.co.z for v in verts) / len(verts)
        # Only a clearly SUBMERGED face is wet mud - painting everything up
        # to above the waterline made the shoreline a two-tone stair-step
        # checker (user: "pixelated"); above water the murk isn't hiding
        # the boundary, so the peat runs to the water's edge instead.
        if outer_u <= GRASS_U and cz < SWAMP_WATER_Z - 0.15:
            f.material_index = 2  # clearly SUBMERGED floor: wet mud
        else:
            f.material_index = band_material(outer_u)

    for s in range(SEGMENTS):
        face((center, rings[0][s], rings[0][(s + 1) % SEGMENTS]), RINGS[1])
    for i in range(len(rings) - 1):
        inner, outer = rings[i], rings[i + 1]
        outer_u = RINGS[i + 2]
        for s in range(SEGMENTS):
            s2 = (s + 1) % SEGMENTS
            face((inner[s], outer[s], outer[s2], inner[s2]), outer_u)
    obj = object_from_bmesh("Swamp_Base", bm, ["M_Peat", "M_Mud", "M_WetMud"])
    # The base part's bbox centre is placeIsland's horizontal anchor; the
    # trunk-collider table is emitted relative to it (see build_swamp_trees).
    xs = [v[0] for v in obj.bound_box]
    ys = [v[1] for v in obj.bound_box]
    SWAMP_BASE_CENTER[0] = (min(xs) + max(xs)) * 0.5
    SWAMP_BASE_CENTER[1] = (min(ys) + max(ys)) * 0.5
    return obj


def build_swamp_water():
    """ONE huge sheet at the contract name (Swamp_Water keys the "swamp"
    roster): a ragged disc flooding the whole marsh interior, its edge out
    at the rim band where the ground has already climbed back above the
    water level - so the sheet's rim is buried inside rising terrain on
    every bearing, and the islets simply poke through it. (Binding rule
    from step 3: water may only ever emerge FROM ground - never draw a
    sheet that ends over a bed.) The slab reaches below the deepest floor.
    LAVA_PONDS (cleared first - the volcano's linger) records ONLY the boss
    mere: the rest of the marsh is exactly where the coming tree step wants
    to plant, so it must stay OFF the keep-clear list."""
    bm = bmesh.new()
    LAVA_PONDS.clear()
    points = []
    seg = 96
    edge_u = (SWAMP_MARSH_U + SWAMP_RIM_U) * 0.5 + 0.03
    for s in range(seg):
        a = (s / seg) * math.tau
        w = 1 + 0.025 * math.sin(3 * a + 1.3) + 0.015 * math.sin(7 * a + 4.1)
        rr = ring_radius(edge_u, a) * w
        points.append((math.cos(a) * rr, math.sin(a) * rr))
    add_disc_slab(bm, points, SWAMP_WATER_Z, SWAMP_WATER_Z - (SWAMP_BED_Z - 1.4) + 0.6)
    mx, my, mr = SWAMP_MERE
    LAVA_PONDS.append((mx, my, mr))
    return object_from_bmesh("Swamp_Water", bm, ["M_SwampWater"])


def build_swamp_cattails():
    """Cattail brakes along the marsh margins: clusters seeded ONLY where
    the ground sits within a stud or so of the waterline (the shallow
    fringe of every islet, inlet and bank - which is where real cattails
    live, and it makes the wandering water/land boundary read at ground
    level). Each stalk is a thin 4-sided cone with 2-3 blade cones and a
    brown seed head riding the same lean. Two objects, one material each
    (Swamp_Cattails = stalks + blades, Swamp_CattailHeads = the heads);
    both go NON-COLLIDE in WorldService - you wade through a reed brake,
    never bounce off it. Keeps clear of the boss mere and the spawn shelf."""
    stalk_bm = bmesh.new()
    head_bm = bmesh.new()
    rng = random.Random(2711)
    clusters, stalks, attempts = 0, 0, 0
    # Dense brakes (user: "much more... denser and taller"): ~70 brakes of
    # 8-14 stalks. Geometry per stalk is trimmed to 3-sided cones so the
    # whole crop stays well inside the importer's per-mesh triangle budget.
    while clusters < 70 and attempts < 2600:
        attempts += 1
        theta = rng.uniform(0, math.tau)
        u = rng.uniform(0.10, SWAMP_RIM_U + 0.02)
        r_world = ring_radius(u, theta)
        cx, cy = math.cos(theta) * r_world, math.sin(theta) * r_world
        g = _swamp_height(cx, cy)
        if not (SWAMP_WATER_Z - 0.9 <= g <= SWAMP_WATER_Z + 0.6):
            continue  # not a margin: open deep water or high ground
        mx, my, mr = SWAMP_MERE
        if math.hypot(cx - mx, cy - my) < mr + 6:
            continue  # the boss arena stays open
        sx, sy = SWAMP_SPAWN
        if math.hypot(cx - sx, cy - sy) < 26:
            continue  # the spawn shelf stays clear
        if not _hut_morra_clear(cx, cy, 2.0):
            continue  # ...and so does Morra's dooryard
        clusters += 1
        for _ in range(rng.randint(8, 14)):
            a = rng.uniform(0, math.tau)
            d = rng.uniform(0.0, 5.5)
            x, y = cx + math.cos(a) * d, cy + math.sin(a) * d
            g2 = _swamp_height(x, y)
            if not (SWAMP_WATER_Z - 1.0 <= g2 <= SWAMP_WATER_Z + 0.8):
                continue
            stalks += 1
            # Heads sit just under the player's eyeline: a character is ~5
            # studs, so the stalks top out a shade below that.
            h = rng.uniform(4.0, 4.8)
            lean = (rng.uniform(-0.09, 0.09), rng.uniform(-0.09, 0.09))
            base = (x, y, g2 - 0.4)  # rooted a little under the mud
            add_cone(stalk_bm, base, 0.15, 0.055, h, sides=3, tilt=lean)
            # Blade leaves: shorter, thinner cones fanning off the root.
            for _b in range(2):
                ba = rng.uniform(0, math.tau)
                add_cone(
                    stalk_bm,
                    (x + math.cos(ba) * 0.3, y + math.sin(ba) * 0.3, base[2]),
                    0.17,
                    0.02,
                    h * rng.uniform(0.5, 0.75),
                    sides=3,
                    tilt=(math.cos(ba) * 0.17, math.sin(ba) * 0.17),
                )
            # The seed head: a stubby brown cylinder ~3/4 of the way up,
            # seated on the stalk's own axis so it rides the lean.
            axis = cone_axis(lean, 0.0)
            hz = h * rng.uniform(0.7, 0.78)
            head_base = (base[0] + axis.x * hz, base[1] + axis.y * hz, base[2] + axis.z * hz)
            add_cone(head_bm, head_base, 0.16, 0.14, rng.uniform(0.85, 1.1), sides=4, tilt=lean)
    print(f"[island_gen] swamp cattails: {stalks} stalks in {clusters} brakes")
    return [
        object_from_bmesh("Swamp_Cattails", stalk_bm, ["M_Cattail"]),
        object_from_bmesh("Swamp_CattailHeads", head_bm, ["M_CattailHead"]),
    ]


def build_swamp_smalls():
    """The fen's small dressing - everything little that isn't a tree
    (user: "lily pads and other swamp decoration stuff... smaller stuff"):
      - Swamp_Lilies: rafts of flat pads floating on the open water
      - Swamp_LilyBlooms: a flower on roughly one pad in six
      - Swamp_Logs: half-sunken rotted logs in the shallows + clusters of
        cypress KNEES (little woody cones poking out of the water near the
        margins) - one object, both are M_RootWood
      - Swamp_Stones: mossy bog stones on the islets and banks
    All four go NON-COLLIDE in WorldService (the restart's no-prop-walls
    rule). Everything keeps clear of the boss mere and the spawn shelf."""
    lily_bm = bmesh.new()
    bloom_bm = bmesh.new()
    log_bm = bmesh.new()
    stone_bm = bmesh.new()
    rng = random.Random(3313)
    mx, my, mr = SWAMP_MERE
    sx, sy = SWAMP_SPAWN

    def clear(x, y, pad):
        return (
            math.hypot(x - mx, y - my) >= mr + pad
            and math.hypot(x - sx, y - sy) >= 24
            and _hut_morra_clear(x, y, 1.0)  # Morra's hut + plank path
        )

    def marsh_spot(lo, hi, tries=40):
        """A point in the marsh whose ground height sits in [lo, hi]."""
        for _ in range(tries):
            theta = rng.uniform(0, math.tau)
            u = rng.uniform(0.08, SWAMP_RIM_U)
            r_world = ring_radius(u, theta)
            x, y = math.cos(theta) * r_world, math.sin(theta) * r_world
            g = _swamp_height(x, y)
            if lo <= g <= hi and clear(x, y, 4):
                return x, y, g
        return None

    # Lily rafts: pads float on genuinely open water (bed well below the
    # surface), in loose drifts. Flat low-poly hexagon slabs a hair above
    # the sheet so they never z-fight it.
    pads, blooms, rafts = 0, 0, 0
    while rafts < 26:
        spot = marsh_spot(SWAMP_BED_Z - 1.2, SWAMP_WATER_Z - 0.45)
        if not spot:
            break
        rafts += 1
        cx, cy, _ = spot
        for _ in range(rng.randint(5, 11)):
            a = rng.uniform(0, math.tau)
            d = rng.uniform(0, 6.5)
            x, y = cx + math.cos(a) * d, cy + math.sin(a) * d
            if _swamp_height(x, y) > SWAMP_WATER_Z - 0.4 or not clear(x, y, 3):
                continue
            pads += 1
            pr = rng.uniform(0.8, 1.6)
            yaw0 = rng.uniform(0, math.tau)
            points = []
            for s in range(6):
                ang = yaw0 + (s / 6) * math.tau
                w = 1 + 0.12 * math.sin(2.7 * ang + pr * 9)
                points.append((x + math.cos(ang) * pr * w, y + math.sin(ang) * pr * w))
            add_disc_slab(lily_bm, points, SWAMP_WATER_Z + 0.08, 0.1)
            if rng.random() < 0.16:
                blooms += 1
                add_cone(bloom_bm, (x, y, SWAMP_WATER_Z + 0.1), 0.28, 0.05, rng.uniform(0.4, 0.6), sides=5)

    # Half-sunken logs: lying in the shallows and on the low banks, tilted
    # nearly flat, a couple of stub branches each.
    logs = 0
    while logs < 20:
        spot = marsh_spot(SWAMP_WATER_Z - 0.7, SWAMP_WATER_Z + 1.1)
        if not spot:
            break
        logs += 1
        x, y, g = spot
        yaw = rng.uniform(0, math.tau)
        length = rng.uniform(5.0, 9.0)
        r0 = rng.uniform(0.5, 0.75)
        # An add_cone tilted ~88 degrees lies the frustum on its side.
        tilt = (math.cos(yaw) * 1.52, math.sin(yaw) * 1.52)
        add_cone(log_bm, (x, y, g + r0 * 0.35), r0, r0 * 0.55, length, sides=5, tilt=tilt)
        axis = cone_axis(tilt, 0.0)
        for _b in range(rng.randint(1, 3)):
            t = rng.uniform(0.25, 0.8)
            bx, by, bz = x + axis.x * length * t, y + axis.y * length * t, g + r0 * 0.35 + axis.z * length * t
            add_cone(
                log_bm,
                (bx, by, bz),
                r0 * 0.35,
                0.05,
                rng.uniform(1.2, 2.4),
                sides=3,
                tilt=(rng.uniform(-0.9, 0.9), rng.uniform(-0.9, 0.9)),
            )

    # Cypress knees: little woody cones huddling in the shallow water off
    # the margins - the closest thing to trees this step allows itself.
    knees = 0
    for _ in range(26):
        spot = marsh_spot(SWAMP_WATER_Z - 1.0, SWAMP_WATER_Z - 0.15)
        if not spot:
            break
        cx, cy, _ = spot
        for _k in range(rng.randint(3, 5)):
            a = rng.uniform(0, math.tau)
            d = rng.uniform(0.4, 2.6)
            x, y = cx + math.cos(a) * d, cy + math.sin(a) * d
            g = _swamp_height(x, y)
            if g > SWAMP_WATER_Z:
                continue
            knees += 1
            add_cone(
                log_bm,
                (x, y, g),
                rng.uniform(0.28, 0.45),
                0.06,
                (SWAMP_WATER_Z - g) + rng.uniform(0.5, 1.4),
                sides=4,
                tilt=(rng.uniform(-0.12, 0.12), rng.uniform(-0.12, 0.12)),
            )

    # Bog stones: mossy lumps on the islets and banks, half-buried.
    stones = 0
    while stones < 30:
        spot = marsh_spot(SWAMP_WATER_Z + 0.25, 99.0)
        if not spot:
            break
        stones += 1
        x, y, g = spot
        s = rng.uniform(0.6, 1.6)
        add_blob(
            stone_bm,
            (x, y, g + s * 0.25),
            (s, s * rng.uniform(0.75, 1.0), s * rng.uniform(0.5, 0.75)),
            0.25,
            salt=stones * 3.7,
            yaw=rng.uniform(0, math.tau),
        )

    # ---- the storytelling details (user: "smaller details like small logs
    # laying horizontally... dont place too many but add some cool stuff").
    # Sparse, hand-countable set pieces, all on land or the wet margins:
    #   - FALLEN LOGS lying flat, a few with the very STUMP they snapped
    #     off standing beside them, branch stubs in the air
    #   - lone jagged-topped stumps
    #   - two BROKEN trees: a tall stump with its upper trunk leaning from
    #     the break down to the ground
    #   - mushroom clusters riding logs, stumps and banks (the colour pop)
    detail_spots = []  # (x, y, kind) - printed as HANDOFF so previews can find them

    def ground_spot(tries=60):
        for _ in range(tries):
            theta = rng.uniform(0, math.tau)
            u = rng.uniform(0.10, SWAMP_RIM_U + 0.03)
            r_world = ring_radius(u, theta)
            x, y = math.cos(theta) * r_world, math.sin(theta) * r_world
            g = _swamp_height(x, y)
            if SWAMP_WATER_Z + 0.15 <= g <= SWAMP_WATER_Z + 2.2 and clear(x, y, 5):
                return x, y, g
        return None

    shroom_bm = bmesh.new()
    shroom_anchors = []

    def mushrooms(x, y, z, n):
        for _ in range(n):
            a = rng.uniform(0, math.tau)
            d = rng.uniform(0.2, 1.4)
            mx_, my_ = x + math.cos(a) * d, y + math.sin(a) * d
            stem_h = rng.uniform(0.35, 0.7)
            add_cone(shroom_bm, (mx_, my_, z), 0.12, 0.09, stem_h, sides=4)
            add_cone(shroom_bm, (mx_, my_, z + stem_h), rng.uniform(0.35, 0.6), 0.06, rng.uniform(0.28, 0.45), sides=5)

    def fallen_log(x, y, g, yaw, length, r0, stubs=True):
        pitch = rng.uniform(1.46, 1.6)  # ~horizontal
        tilt = (math.cos(yaw) * pitch, math.sin(yaw) * pitch)
        add_cone(log_bm, (x, y, g + r0 * 0.55), r0, r0 * 0.7, length, sides=5, tilt=tilt)
        axis = cone_axis(tilt, 0.0)
        if stubs:
            for _s in range(rng.randint(1, 3)):
                t = rng.uniform(0.2, 0.85)
                sx_, sy_, sz_ = x + axis.x * length * t, y + axis.y * length * t, g + r0 * 0.55 + axis.z * length * t
                sa = rng.uniform(0, math.tau)
                add_cone(
                    log_bm,
                    (sx_, sy_, sz_),
                    r0 * 0.3,
                    0.05,
                    rng.uniform(0.8, 2.0),
                    sides=3,
                    tilt=(math.cos(sa) * rng.uniform(0.0, 0.6), math.sin(sa) * rng.uniform(0.0, 0.6)),
                )
        return axis

    def stump(x, y, g, r0, h):
        add_cone(log_bm, (x, y, g - 0.2), r0, r0 * 0.85, h + 0.2, sides=6)
        for _k in range(rng.randint(2, 4)):  # the jagged broken rim
            a = rng.uniform(0, math.tau)
            add_cone(
                log_bm,
                (x + math.cos(a) * r0 * 0.55, y + math.sin(a) * r0 * 0.55, g + h - 0.1),
                r0 * 0.22,
                0.03,
                rng.uniform(0.4, 1.0),
                sides=3,
                tilt=(math.cos(a) * 0.15, math.sin(a) * 0.15),
            )

    # Stump + its own fallen trunk beside it: "this tree came down".
    pairs = 0
    while pairs < 3:
        spot = ground_spot()
        if not spot:
            break
        pairs += 1
        x, y, g = spot
        yaw = rng.uniform(0, math.tau)
        r0 = rng.uniform(0.7, 0.95)
        stump(x, y, g, r0 * 1.15, rng.uniform(1.2, 2.0))
        lx, ly = x + math.cos(yaw) * (r0 + 1.6), y + math.sin(yaw) * (r0 + 1.6)
        fallen_log(lx, ly, _swamp_height(lx, ly), yaw, rng.uniform(8.0, 12.0), r0)
        if rng.random() < 0.8:
            shroom_anchors.append((x, y, g + rng.uniform(1.2, 1.9)))
        detail_spots.append((x, y, "stump+log"))

    # Lone fallen logs.
    lone_logs = 0
    while lone_logs < 6:
        spot = ground_spot()
        if not spot:
            break
        lone_logs += 1
        x, y, g = spot
        fallen_log(x, y, g, rng.uniform(0, math.tau), rng.uniform(6.0, 10.0), rng.uniform(0.55, 0.8))
        if rng.random() < 0.5:
            shroom_anchors.append((x, y, g + 0.9))
        detail_spots.append((x, y, "log"))

    # Lone stumps.
    for _ in range(4):
        spot = ground_spot()
        if not spot:
            break
        x, y, g = spot
        stump(x, y, g, rng.uniform(0.8, 1.2), rng.uniform(1.0, 2.2))
        detail_spots.append((x, y, "stump"))

    # Two BROKEN trees: tall shattered stump + the upper trunk leaning from
    # the break down to the ground.
    broken = 0
    while broken < 2:
        spot = ground_spot()
        if not spot:
            break
        broken += 1
        x, y, g = spot
        bh = rng.uniform(3.5, 5.5)
        r0 = rng.uniform(0.8, 1.1)
        stump(x, y, g, r0, bh)
        yaw = rng.uniform(0, math.tau)
        lean = Vector((math.cos(yaw) * 0.92, math.sin(yaw) * 0.92, -0.4)).normalized()
        add_cone(
            log_bm,
            (x + math.cos(yaw) * r0 * 0.4, y + math.sin(yaw) * r0 * 0.4, g + bh - 0.4),
            r0 * 0.8,
            r0 * 0.3,
            rng.uniform(9.0, 13.0),
            sides=5,
            tilt=_tilt_toward(lean),
        )
        detail_spots.append((x, y, "broken"))

    # Mushroom clusters: on the logs/stumps recorded above plus a few bank
    # spots of their own.
    for ax_, ay_, az_ in shroom_anchors:
        mushrooms(ax_, ay_, az_, rng.randint(2, 4))
    shroom_clusters = 0
    while shroom_clusters < 6:
        spot = ground_spot()
        if not spot:
            break
        shroom_clusters += 1
        x, y, g = spot
        mushrooms(x, y, g, rng.randint(3, 6))
        detail_spots.append((x, y, "mushrooms"))

    for dx_, dy_, kind in detail_spots:
        print(f"[island_gen] HANDOFF swamp detail: {kind} at rel X={dx_:.0f} Z={-dy_:.0f}")

    print(
        f"[island_gen] swamp smalls: {pads} pads ({blooms} blooms), {logs} shallow logs, {knees} knees, {stones} stones, {pairs} stump+log pairs, {lone_logs} fallen logs, {broken} broken trees, {shroom_clusters}+{len(shroom_anchors)} mushroom clusters"
    )
    return [
        object_from_bmesh("Swamp_Lilies", lily_bm, ["M_Lily"]),
        object_from_bmesh("Swamp_LilyBlooms", bloom_bm, ["M_LilyBloom"]),
        object_from_bmesh("Swamp_Logs", log_bm, ["M_RootWood"]),
        object_from_bmesh("Swamp_Stones", stone_bm, ["M_BogStone"]),
        object_from_bmesh("Swamp_Mushrooms", shroom_bm, ["M_Mushroom"]),
    ]


def _tilt_toward(direction):
    """The add_cone tilt (a, b) whose axis points along unit `direction`.
    The original derivation had the rotation order backwards AND could
    not aim below the horizontal - every affected branch was DRAWN off
    its intended direction while children attached at the intended tip:
    the floating-branch bug (user screenshots, 2026-08-28). Now solved
    exactly for the true axis Rx(a)Ry(b) @ +Z, and VERIFIED on every
    call: the produced axis must match the request or this raises."""
    # cone_axis applies Rx(a) @ Ry(b) @ +Z = (sin b, -sin a cos b,
    # cos a cos b): b = asin(dx) keeps cos b >= 0, and a = atan2(-dy, dz)
    # covers every quadrant - downward directions included - exactly.
    b = math.asin(max(-1.0, min(1.0, direction.x)))
    a = math.atan2(-direction.y, direction.z) if (abs(direction.y) + abs(direction.z)) > 1e-6 else 0.0
    axis = cone_axis((a, b), 0.0)
    if axis.dot(direction) < 0.998:
        raise ValueError(f"[island_gen] _tilt_toward failed to aim: want {tuple(direction)}, got {tuple(axis)}")
    return (a, b)


def build_swamp_trees():
    """The fen's dead forest: ~110 bare trees with EXPANSIVE forked crowns
    (user reference: a recursively branching skeleton - long limbs that
    split into sub-branches that split into twigs, sweeping up and out).
    Each tree: the solid curved tan trunk (unchanged - the user called the
    bases good), then 3-5 main limbs off the upper trunk, each forking
    twice (occasionally three ways) with an upward bias, so the crown
    spreads wide like the reference. On top of every crown sits a THICK
    BUSHY CANOPY (user: "really really thick and bushy"): overlapping
    noise-lumped leaf blobs - one fat mass over the crown's heart plus a
    puff at limb tips - so the skeleton wears a full head of foliage. The
    forest is SPLIT across paired objects (Swamp_Trees/2 wood,
    Swamp_TreeLeaves/2 canopy) because crowns+canopies breach a single
    mesh's triangle budget. Trunks stay collidable (Precise import note);
    canopies are NON-COLLIDE; mere + spawn keep-clears hold."""
    bms = [bmesh.new(), bmesh.new(), bmesh.new()]
    leaf_bms = [bmesh.new(), bmesh.new(), bmesh.new()]
    moss_bm = bmesh.new()  # pale hanging moss ribbons off the branch tips
    vine_bm = bmesh.new()  # darker, longer vines - a few reach for the water
    rng = random.Random(4517)
    mx, my, mr = SWAMP_MERE
    sx, sy = SWAMP_SPAWN
    placed = []

    def dir_of(az, elev):
        c = math.cos(elev)
        return Vector((math.cos(az) * c, math.sin(az) * c, math.sin(elev)))

    def limb(bm, base, direction, length, radius, depth, tips):
        """One branch segment, then fork: the reference's Y-splits.
        Every segment's BASE is sunk `radius` back along its own axis, so
        the cone root is buried inside whatever it grows from (trunk or
        parent tip) - a joint can gap only if the anchor itself is off the
        wood, which the trunk-polyline fix below rules out. Terminal tips
        collect into `tips` so the canopy knows where the crown is."""
        r_top = radius * (0.62 if depth > 0 else 0.22)
        sink = radius * 1.1 + 0.1
        root = base - direction * sink
        add_cone(bm, tuple(root), radius, max(r_top, 0.05), length + sink, sides=3, tilt=_tilt_toward(direction))
        if depth == 0:
            tips.append(base + direction * length)
            return
        tip = base + direction * length
        kids = 3 if rng.random() < 0.2 else 2
        for _ in range(kids):
            rand = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1)))
            perp = rand - direction * rand.dot(direction)
            if perp.length < 1e-3:
                continue
            perp.normalize()
            ang = rng.uniform(0.35, 0.7)
            child = (direction * math.cos(ang) + perp * math.sin(ang) + Vector((0, 0, 0.18))).normalized()
            limb(bm, tip, child, length * rng.uniform(0.6, 0.78), r_top, depth - 1, tips)

    trunk_rows = []  # (x, y, r0, top_z) -> Shared/Data/SwampTrees.luau
    trees, attempts = 0, 0
    while trees < 155 and attempts < 14000:
        attempts += 1
        theta = rng.uniform(0, math.tau)
        u = rng.uniform(0.06, SWAMP_RIM_U - 0.01)
        r_world = ring_radius(u, theta)
        x, y = math.cos(theta) * r_world, math.sin(theta) * r_world
        g = _swamp_height(x, y)
        if not (SWAMP_BED_Z - 1.2 <= g <= SWAMP_WATER_Z + 1.5):
            continue
        if math.hypot(x - mx, y - my) < mr + 9 or math.hypot(x - sx, y - sy) < 24:
            continue
        if not _hut_morra_clear(x, y, 3.0):
            continue  # Morra's hut stands in its own clearing (its mangrove is authored)
        if any(math.hypot(x - px, y - py) < 6.5 for px, py in placed):
            continue
        placed.append((x, y))
        bm = bms[trees % 3]
        trees += 1

        # The solid base: the curved 3-segment trunk, as before but with a
        # gentler final lean so the crown opens ABOVE the tree.
        bend_az = rng.uniform(0, math.tau)
        total_h = rng.uniform(12.0, 20.0)
        r0 = rng.uniform(1.0, 1.7)
        leans = [rng.uniform(0.03, 0.09), rng.uniform(0.10, 0.22), rng.uniform(0.16, 0.3)]
        directions = [dir_of(bend_az, math.pi * 0.5 - l) for l in leans]
        radii = [r0, r0 * 0.7, r0 * 0.48, r0 * 0.3]
        seg = total_h / 3
        trunk_rows.append((x, y, r0, g - 0.4 + total_h))
        pos = Vector((x, y, g - 0.4))
        joints = [Vector(pos)]
        for i, direction in enumerate(directions):
            add_cone(bm, tuple(pos), radii[i], radii[i + 1], seg, sides=5, tilt=_tilt_toward(direction))
            pos = pos + direction * seg
            joints.append(Vector(pos))

        # The expansive crown: 3-5 main limbs off the upper trunk, each a
        # long riser that forks twice - wide like the reference.
        tips = []
        for _b in range(rng.randint(3, 5)):
            baz = rng.uniform(0, math.tau)
            t = rng.uniform(0.55, 0.95)
            # ON the trunk: walk the actual joint polyline (the old code
            # lerped the joint1->joint3 CHORD, which the curved trunk bows
            # away from - limb bases hung up to a stud off the wood).
            s = t * 3.0
            i = min(int(s), 2)
            frac = s - i
            at = joints[i].lerp(joints[i + 1], frac)
            elev = rng.uniform(0.45, 0.95)
            limb(bm, at, dir_of(baz, elev), rng.uniform(4.5, 7.5) * (total_h / 16.0), r0 * 0.3, 2, tips)

        # The canopy: one fat lumpy mass over the crown's heart, plus a
        # puff at every third limb tip, all overlapping into one bush.
        if tips:
            leaf_bm = leaf_bms[(trees - 1) % 3]
            centroid = Vector((0, 0, 0))
            for t_ in tips:
                centroid += t_
            centroid /= len(tips)
            spread = max((max(abs(t_.x - centroid.x), abs(t_.y - centroid.y)) for t_ in tips), default=5.0)
            # HORIZONTAL pads (user): wide in XY, squashed in Z, sized to
            # overlap the neighbours ~6.5-8 studs away - the canopies knit
            # into one continuous forest roof.
            big = max(7.0, min(11.0, spread * 1.35))
            add_blob(
                leaf_bm,
                (centroid.x, centroid.y, centroid.z + 0.6),
                (big, big * rng.uniform(0.85, 1.0), big * 0.4),
                0.2,
                salt=trees * 2.9,
                yaw=rng.uniform(0, math.tau),
            )
            for k, t_ in enumerate(tips):
                if k % 2 != 0:
                    continue
                s = rng.uniform(4.5, 6.5)
                add_blob(
                    leaf_bm,
                    (t_.x, t_.y, t_.z + 0.4),
                    (s, s * rng.uniform(0.8, 1.0), s * 0.42),
                    0.22,
                    salt=trees * 7.1 + k,
                    yaw=rng.uniform(0, math.tau),
                )

            # The hanging garden: pale moss ribbons off roughly half the
            # tips, and the odd long vine dropping toward the water.
            for k, t_ in enumerate(tips):
                if rng.random() < 0.5:
                    ml = rng.uniform(2.5, 6.0)
                    add_cone(moss_bm, (t_.x, t_.y, t_.z - ml), 0.1, 0.04, ml, sides=3)
                if rng.random() < 0.22:
                    vl = rng.uniform(6.0, 12.0)
                    va = rng.uniform(0, math.tau)
                    add_cone(
                        vine_bm,
                        (t_.x, t_.y, t_.z - vl),
                        0.08,
                        0.05,
                        vl,
                        sides=3,
                        tilt=(math.cos(va) * rng.uniform(0.03, 0.12), math.sin(va) * rng.uniform(0.03, 0.12)),
                    )

    # The runtime trunk-collider table (src/Shared/Data/SwampTrees.luau):
    # every tree MESH is pass-through in game (an imported multi-tree mesh
    # wears whatever collision hull the import fidelity gave it - the
    # user's invisible-barrier reports, 2026-08-28), and WorldService
    # plants one invisible box collider per TRUNK from this data instead -
    # correct regardless of import settings. Coordinates are ISLAND-LOCAL
    # in the Roblox frame (X = blender x, Z = -blender y - the mapping the
    # shipped docks/spawns confirm), relative to the Swamp_Base bbox
    # centre `origin` because placeIsland anchors the island there.
    lines = [
        "-- AUTOGENERATED by assets/island_gen.py (swamp tree build) - do not hand-edit.",
        "-- Island-local trunk colliders: x/z relative to the Swamp_Base bbox centre",
        "-- (WorldService anchors the island on that part), r = trunk base radius,",
        "-- top = authored trunk-top height. Regenerated with every swamp build.",
        "return {",
        f"\torigin = {{ x = {SWAMP_BASE_CENTER[0]:.2f}, z = {-SWAMP_BASE_CENTER[1]:.2f} }},",
        "\ttrunks = {",
    ]
    for tx, ty, tr, ttop in trunk_rows:
        lines.append(f"\t\t{{ x = {tx:.2f}, z = {-ty:.2f}, r = {tr:.2f}, top = {ttop:.2f} }},")
    lines += ["\t},", "}", ""]
    with open("src/Shared/Data/SwampTrees.luau", "w") as fh:
        fh.write("\n".join(lines))
    print(f"[island_gen] swamp trees: wrote {len(trunk_rows)} trunk colliders -> src/Shared/Data/SwampTrees.luau")
    print(f"[island_gen] swamp trees: {trees} trees, knitted roof + hanging moss/vines, 3x2+2 objects")
    return [
        object_from_bmesh("Swamp_Trees", bms[0], ["M_TrunkWood"]),
        object_from_bmesh("Swamp_Trees2", bms[1], ["M_TrunkWood"]),
        object_from_bmesh("Swamp_Trees3", bms[2], ["M_TrunkWood"]),
        object_from_bmesh("Swamp_TreeLeaves", leaf_bms[0], ["M_WillowLeaf"]),
        object_from_bmesh("Swamp_TreeLeaves2", leaf_bms[1], ["M_WillowLeaf"]),
        object_from_bmesh("Swamp_TreeLeaves3", leaf_bms[2], ["M_WillowLeaf"]),
        object_from_bmesh("Swamp_HangMoss", moss_bm, ["M_HangMoss"]),
        object_from_bmesh("Swamp_Vines", vine_bm, ["M_Vine"]),
    ]


def build_hut_morra():
    """Morra's leaning bog hut: a hunched egg of wattle that leans off true,
    built half-around a living mangrove, scale-shingled and dripping moss,
    up on stilts driven into the marsh bed so its floor stands 2.8 studs
    clear of the standing water. A WALK-IN building: a 6-stud-wide, 7.3-tall
    door under the gator skull, 11 studs of clear floor inside, an 11.6-stud
    apex, and 1.1-stud-thick wattle walls (the solid-walls import rule).
    Swamp_Hut_Walls carries the shell, floor, stilts, mangrove and plank
    path and must stay COLLIDABLE - Morra and the player stand on it."""
    walls, roof, props, glow = bmesh.new(), bmesh.new(), bmesh.new(), bmesh.new()
    rng = random.Random(6421)

    cx, cy, keep_r = SWAMP_HUT
    FLOOR = SWAMP_HUT_FLOOR
    a = _HUT_MORRA_YAW
    fx, fy = math.cos(a), math.sin(a)  # +front: out of the door, toward Morra
    rx, ry = -math.sin(a), math.cos(a)

    def P(fwd, side, z):
        return (cx + fx * fwd + rx * side, cy + fy * fwd + ry * side, z)

    def B(bm, fwd, side, z, d, w, h, turn=0.0):
        add_box(bm, P(fwd, side, z), (d, w, h), yaw=a + turn)

    def bog(fwd, side):
        x, y, _ = P(fwd, side, 0)
        return _swamp_height(x, y)

    # ---- the leaning egg -------------------------------------------------
    S = 14  # angular segments; a door is two of them
    LVL_Z = [0.0, 2.3, 4.8, 7.3, 9.4, 11.6]
    LVL_R = [6.6, 7.5, 7.7, 7.0, 5.2, 1.7]
    WALL_T = 1.1
    LEAN = 3.8  # studs of shear, floor to apex - the hunch
    LEAN_F, LEAN_S = -0.45, 0.89  # it leans onto the mangrove propping it up

    def lean_at(z_local):
        """How far the shell has wandered off plumb at this height. Almost all
        of the lean is spent ABOVE the door head - the body stands near plumb
        and the dome hunches hard over it. Shearing the door band as well
        turns the opening into a parallelogram and squeezes the straight
        walk-through under 4 studs (measured, not guessed)."""
        t = z_local / LVL_Z[-1]
        k = 0.12 * t + 0.88 * smoothstep(LVL_Z[3], LVL_Z[-1], z_local)
        return LEAN_F * LEAN * k, LEAN_S * LEAN * k

    def shell_r(z_local, outer):
        for i in range(len(LVL_Z) - 1):
            if z_local <= LVL_Z[i + 1] or i == len(LVL_Z) - 2:
                t = (z_local - LVL_Z[i]) / (LVL_Z[i + 1] - LVL_Z[i])
                r = LVL_R[i] + (LVL_R[i + 1] - LVL_R[i]) * t
                return r if outer else max(r - WALL_T, 0.35)
        return LVL_R[-1]

    def shell_pt(ang, z_local, r=None, outer=True):
        rr = shell_r(z_local, outer) if r is None else r
        lf, ls = lean_at(z_local)
        return P(math.cos(ang) * rr + lf, math.sin(ang) * rr + ls, FLOOR + z_local)

    O = [[walls.verts.new(Vector(shell_pt(s / S * math.tau, z, outer=True))) for s in range(S)] for z in LVL_Z]
    I = [[walls.verts.new(Vector(shell_pt(s / S * math.tau, z, outer=False))) for s in range(S)] for z in LVL_Z]

    door_segs = {s for s in range(S) if abs((((s + 0.5) / S) * math.tau + math.pi) % math.tau - math.pi) < 0.45}
    door_bands = (0, 1, 2)  # the opening runs floor -> LVL_Z[3] = 7.3 studs
    jamb_verts = {v for s in door_segs for v in (s, (s + 1) % S) if not (v in door_segs and (v - 1) % S in door_segs)}

    for i in range(len(LVL_Z) - 1):
        for s in range(S):
            if i in door_bands and s in door_segs:
                continue
            s2 = (s + 1) % S
            walls.faces.new((O[i][s], O[i + 1][s], O[i + 1][s2], O[i][s2]))
            walls.faces.new((I[i][s2], I[i + 1][s2], I[i + 1][s], I[i][s]))
    for s in range(S):  # the wall's foot ring, and the closed apex
        s2 = (s + 1) % S
        walls.faces.new((O[0][s], I[0][s], I[0][s2], O[0][s2]))
        walls.faces.new((O[-1][s], O[-1][s2], I[-1][s2], I[-1][s]))
    walls.faces.new([I[-1][s] for s in range(S)])
    for i in door_bands:  # the door's jambs and its lintel underside
        for s in jamb_verts:
            walls.faces.new((O[i][s], I[i][s], I[i + 1][s], O[i + 1][s]))
    for s in door_segs:
        s2 = (s + 1) % S
        walls.faces.new((O[3][s], I[3][s], I[3][s2], O[3][s2]))

    # ---- floor, stilts, the mangrove, the plank path (all M_RootWood) -----
    wood_first = len(walls.faces)
    add_disc_slab(
        walls,
        [P(math.cos(s / S * math.tau) * 6.1, math.sin(s / S * math.tau) * 6.1, 0)[:2] for s in range(S)],
        FLOOR,
        0.6,
    )
    for k in range(6):  # stilts: marsh bed -> up INTO the floor slab
        ang = k * math.tau / 6 + 0.3
        px, py, _ = P(math.cos(ang) * 5.2, math.sin(ang) * 5.2, 0)
        add_post(walls, px, py, _swamp_height(px, py) - 0.8, FLOOR - 0.1, 0.5, sides=5)
    # ...and cross-braces, so the hut reads propped rather than perched.
    for k in range(3):
        ang = k * math.tau / 3 + 0.3
        px, py, _ = P(math.cos(ang) * 5.2, math.sin(ang) * 5.2, 0)
        g = _swamp_height(px, py)
        to = Vector(P(0.0, 0.0, FLOOR - 0.4)) - Vector((px, py, g + 0.4))
        add_cone(walls, (px, py, g + 0.4), 0.22, 0.16, to.length, sides=3, tilt=_tilt_toward(to.normalized()))

    # The mangrove the hut is built half-around: the trunk passes THROUGH the
    # wattle on the leaning side, prop roots splayed into the bog.
    tx, ty, _ = P(-3.2, 6.5, 0)  # on the side the hut leans onto - it holds it up
    t_g = _swamp_height(tx, ty)
    T_BASE = (tx, ty, t_g - 1.2)
    T_TILT = (0.06, -0.10)
    add_cone(walls, T_BASE, 1.5, 0.75, 24.0, sides=6, tilt=T_TILT)
    # The trunk LEANS, so its axis walks away from (tx, ty) as it climbs -
    # about 2.3 studs by the upper limb's height, against a trunk barely 0.9
    # wide up there. Anything hung off the base coordinates therefore floats
    # (user, 2026-08-29: "there is a floating stick"). Seat everything on the
    # real axis instead, computed with add_cone's own rotation order.
    t_axis = (Matrix.Rotation(T_TILT[0], 4, "X") @ Matrix.Rotation(T_TILT[1], 4, "Y")) @ Vector((0.0, 0.0, 1.0))

    def _on_trunk(height_above_ground):
        """The point on the trunk's axis level with `t_g + height`."""
        return Vector(T_BASE) + t_axis * ((height_above_ground + 1.2) / t_axis.z)

    for k in range(4):
        ang = k * math.tau / 4 + 0.6
        root = Vector((math.cos(ang) * 2.6, math.sin(ang) * 2.6, -3.4)).normalized()
        add_cone(walls, tuple(_on_trunk(2.6)), 0.55, 0.2, 4.6, sides=3, tilt=_tilt_toward(root))
    for k, (h, lean_ang) in enumerate(((15.0, 0.8), (18.5, 3.9))):  # two limbs over the roof
        d = Vector((math.cos(lean_ang) * 0.9, math.sin(lean_ang) * 0.9, 0.42)).normalized()
        # Base ON the axis, so each limb grows out from INSIDE the trunk.
        add_cone(walls, tuple(_on_trunk(h)), 0.5, 0.16, 9.0 - k * 1.5, sides=3, tilt=_tilt_toward(d))

    # The plank path out to Morra's mark, every plank resting ON the bog (or
    # on its own pile where the ground has dropped under the water).
    path_z = []
    for k in range(4):
        fwd = 10.0 + k * 3.2
        g = max(bog(fwd, 0.0), SWAMP_WATER_Z - 0.05)
        z = g + 0.15
        path_z.append(z)
        _hut_maren_quad_slab(
            walls,
            [P(fwd - 1.5, -1.9, z), P(fwd - 1.5, 1.9, z), P(fwd + 1.7, 1.9, z), P(fwd + 1.7, -1.9, z)],
            0.35,
        )
        for side in (-1.4, 1.4):  # piles down to the bed
            px, py, _ = P(fwd, side, 0)
            add_post(walls, px, py, _swamp_height(px, py) - 0.6, z - 0.05, 0.28, sides=4)
    # the doorstep ramp: threshold down to the first plank
    _hut_maren_quad_slab(
        walls,
        [P(5.6, -1.9, FLOOR), P(5.6, 1.9, FLOOR), P(9.0, 1.9, path_z[0]), P(9.0, -1.9, path_z[0])],
        0.4,
    )
    _hut_maren_paint(walls, wood_first, 1)

    # ---- roof: overlapping scale shingles + moss dripping off the eave ----
    def scale(bm, ang0, ang1, z0, z1, out, thick):
        pts_o = [
            shell_pt(ang1, z1, r=shell_r(z1, True) + out),
            shell_pt(ang0, z1, r=shell_r(z1, True) + out),
            shell_pt(ang0, z0, r=shell_r(z0, True) + out),
            shell_pt(ang1, z0, r=shell_r(z0, True) + out),
        ]
        pts_i = [
            shell_pt(ang1, z1, r=shell_r(z1, True) + out - thick),
            shell_pt(ang0, z1, r=shell_r(z1, True) + out - thick),
            shell_pt(ang0, z0, r=shell_r(z0, True) + out - thick),
            shell_pt(ang1, z0, r=shell_r(z0, True) + out - thick),
        ]
        vo = [bm.verts.new(Vector(p)) for p in pts_o]
        vi = [bm.verts.new(Vector(p)) for p in pts_i]
        bm.faces.new(vo)
        bm.faces.new(list(reversed(vi)))
        for i in range(4):
            j = (i + 1) % 4
            bm.faces.new((vo[i], vi[i], vi[j], vo[j]))

    scales = 0
    for band, (zlo, zhi) in enumerate(((4.8, 7.3), (7.3, 9.4), (9.4, 11.5))):
        stagger = (band % 2) * 0.5  # courses break joint like real scales
        for s in range(S):
            ang0 = ((s + stagger) / S) * math.tau - 0.06
            ang1 = ((s + 1 + stagger) / S) * math.tau + 0.06
            z0 = zlo + (zhi - zlo) * rng.uniform(-0.04, 0.06)
            z1 = zhi + (zhi - zlo) * rng.uniform(0.10, 0.26)  # every scale laps the course above
            # The lowest course crosses the DOOR - it starts above the head
            # there, or the shingles would board up the top of the opening.
            if band == 0 and s in door_segs:
                z0 = LVL_Z[3] + 0.06
                z1 = max(z1, z0 + 0.6)
            elif band == 1:
                z0 = max(z0, LVL_Z[3] + 0.06)
            scale(roof, ang0, ang1, z0, min(z1, LVL_Z[-1] - 0.2), 0.16, 0.34)
            scales += 1
    moss_first = len(roof.faces)
    for k in range(20):  # moss ribbons hanging off the shingle courses
        ang = rng.uniform(0, math.tau)
        z_top = rng.choice((4.9, 7.4, 9.5))
        if z_top < 8.0 and abs((ang + math.pi) % math.tau - math.pi) < 0.55:
            continue  # never curtain the doorway
        ml = rng.uniform(1.6, 4.4)
        mx_, my_, mz_ = shell_pt(ang, z_top, r=shell_r(z_top, True) - 0.1)
        add_cone(roof, (mx_, my_, mz_ - ml), 0.16, 0.05, ml, sides=3)
    _hut_maren_paint(roof, moss_first, 1)

    # ---- props: 0 wood / 1 herb+straw / 2 bone / 3 jar / 4 iron / 5 stone --
    # EXTERIOR. The gator skull over the door, and the bone-and-shell chime.
    # ...mounted ON the shell right over the door head, not up on the dome.
    lintel = shell_pt(0.0, LVL_Z[3] + 0.55, r=shell_r(LVL_Z[3] + 0.55, True) + 0.45)
    first = len(props.faces)
    add_blob(props, lintel, (1.6, 1.0, 0.85), 0.14, salt=12.0, yaw=a)
    snout = Vector(lintel) + Vector((fx, fy, -0.1)) * 1.1
    add_cone(props, tuple(snout), 0.75, 0.3, 2.2, sides=4, tilt=_tilt_toward(Vector((fx, fy, -0.06)).normalized()))
    # the chime: a stick under the door head, bones and shells on short cords
    # the bar runs PAST the door's edges (+-0.45 rad), so both ends are buried
    # in the jambs rather than floating in the opening
    bar_l = Vector(shell_pt(-0.56, LVL_Z[3] - 0.45, r=shell_r(LVL_Z[3] - 0.45, True) - 0.35))
    bar_r = Vector(shell_pt(0.56, LVL_Z[3] - 0.45, r=shell_r(LVL_Z[3] - 0.45, True) - 0.35))
    add_cone(props, tuple(bar_l), 0.14, 0.14, (bar_r - bar_l).length, sides=3, tilt=_tilt_toward((bar_r - bar_l).normalized()))
    for k in range(5):
        p = bar_l + (bar_r - bar_l) * ((k + 0.5) / 5)
        drop = rng.uniform(0.4, 0.95)  # hangs high in the head of the doorway
        add_cone(props, (p.x, p.y, p.z - drop), 0.05, 0.05, drop, sides=3)  # the cord
        if k % 2:
            add_cone(props, (p.x, p.y, p.z - drop - 0.7), 0.34, 0.06, 0.75, sides=5)  # a shell
        else:
            add_cone(props, (p.x, p.y, p.z - drop - 0.9), 0.14, 0.1, 0.95, sides=4)  # a bone
    _hut_maren_paint(props, first, 2)

    # The cauldron pit beside the door: a stone ring, a pot squatting in it.
    pit_f, pit_s = 8.6, -4.4
    pit_g = bog(pit_f, pit_s)
    first = len(props.faces)
    for k in range(7):
        ang = k * math.tau / 7
        add_blob(
            props,
            P(pit_f + math.cos(ang) * 2.3, pit_s + math.sin(ang) * 2.3, pit_g + 0.15),
            (0.7, 0.6, 0.45),
            0.2,
            salt=30.0 + k * 2.3,
            yaw=ang,
        )
    _hut_maren_paint(props, first, 5)
    first = len(props.faces)
    add_blob(props, P(pit_f, pit_s, pit_g + 1.35), (1.7, 1.7, 1.25), 0.1, salt=51.0, yaw=a)
    for k in range(3):  # its legs, standing in the ring
        ang = k * math.tau / 3 + 0.4
        add_cone(props, P(pit_f + math.cos(ang) * 0.9, pit_s + math.sin(ang) * 0.9, pit_g), 0.18, 0.12, 1.0, sides=3)
    _hut_maren_paint(props, first, 4)

    # The crooked wisp-lantern posts flanking the path (posts here, light below).
    lamps = []
    first = len(props.faces)
    for k, (fwd, side) in enumerate(((10.6, 3.4), (14.2, -3.4), (17.8, 3.2))):
        g = bog(fwd, side)
        h = 4.6 + 0.5 * (k % 2)
        tilt_ang = rng.uniform(0, math.tau)
        tilt = (math.cos(tilt_ang) * 0.18, math.sin(tilt_ang) * 0.18)
        add_cone(props, P(fwd, side, g - 0.7), 0.34, 0.22, h, sides=4, tilt=tilt)
        axis = cone_axis(tilt, 0.0)
        top = Vector(P(fwd, side, g - 0.7)) + axis * (h - 0.2)
        add_cone(props, tuple(top), 0.16, 0.1, 0.9, sides=3, tilt=_tilt_toward(Vector((-fx, -fy, 1.6)).normalized()))
        hook = top + Vector((-fx, -fy, 1.6)).normalized() * 0.85
        lamps.append(hook)
    _hut_maren_paint(props, first, 0)

    # INTERIOR. Rafters first - everything hanging inside hangs off THEM.
    RAFTER_Z = 8.2  # high enough that the lowest bundle clears a walking head
    inner_c = lean_at(RAFTER_Z)
    rafters = []
    first = len(props.faces)
    for off in (-2.2, 2.2):
        half = math.sqrt(max(shell_r(RAFTER_Z, False) ** 2 - off ** 2, 1.0)) + 0.9
        p0 = Vector(P(inner_c[0] + off, inner_c[1] - half, FLOOR + RAFTER_Z))
        p1 = Vector(P(inner_c[0] + off, inner_c[1] + half, FLOOR + RAFTER_Z))
        add_cone(props, tuple(p0), 0.3, 0.26, (p1 - p0).length, sides=4, tilt=_tilt_toward((p1 - p0).normalized()))
        rafters.append((p0, p1))
    # the potion shelf, let into the wall, and the stump table + straw cot
    shelf_ang = math.radians(205)
    shelf_r = shell_r(4.2, False) - 0.35
    lf, ls = lean_at(4.2)
    shelf_f, shelf_s = math.cos(shelf_ang) * shelf_r + lf, math.sin(shelf_ang) * shelf_r + ls
    B(props, shelf_f, shelf_s, FLOOR + 4.2, 1.5, 5.2, 0.3, turn=shelf_ang + math.pi / 2)
    for br in (-1.9, 1.9):  # brackets down to the wall
        B(
            props,
            shelf_f + math.cos(shelf_ang + math.pi / 2) * br,
            shelf_s + math.sin(shelf_ang + math.pi / 2) * br,
            FLOOR + 3.75,
            1.2,
            0.24,
            0.7,
            turn=shelf_ang + math.pi / 2,
        )
    stump_f, stump_s = inner_c[0] + 1.6, inner_c[1] - 2.4
    add_cone(props, P(stump_f, stump_s, FLOOR - 0.2), 1.25, 1.0, 2.8, sides=6)
    cot_ang = math.radians(285)
    cot_r = shell_r(1.0, False) - 2.0
    cot_f, cot_s = math.cos(cot_ang) * cot_r, math.sin(cot_ang) * cot_r
    B(props, cot_f, cot_s, FLOOR + 0.45, 3.0, 6.4, 0.9, turn=cot_ang)
    _hut_maren_paint(props, first, 0)

    first = len(props.faces)
    add_blob(props, P(stump_f, stump_s, FLOOR + 2.95), (1.15, 1.15, 0.5), 0.08, salt=77.0, yaw=a)  # scrying bowl
    _hut_maren_paint(props, first, 4)
    first = len(props.faces)
    B(props, cot_f, cot_s, FLOOR + 1.15, 2.8, 6.0, 0.6, turn=cot_ang)  # the straw on the cot
    for k in range(7):  # herb bundles, corded to the rafters
        p0, p1 = rafters[k % 2]
        p = p0 + (p1 - p0) * ((k + 0.6) / 7.4)
        drop = rng.uniform(0.5, 1.1)
        add_cone(props, (p.x, p.y, p.z - drop), 0.05, 0.05, drop, sides=3)
        add_cone(props, (p.x, p.y, p.z - drop - 1.5), 0.1, 0.55, 1.6, sides=4)
    _hut_maren_paint(props, first, 1)
    first = len(props.faces)
    for k in range(4):  # leech jars, hung off the same rafters
        p0, p1 = rafters[(k + 1) % 2]
        p = p0 + (p1 - p0) * ((k + 0.3) / 4.6)
        drop = rng.uniform(0.6, 1.2)
        add_cone(props, (p.x, p.y, p.z - drop), 0.05, 0.05, drop, sides=3)
        add_post(props, p.x, p.y, p.z - drop - 1.5, p.z - drop + 0.05, 0.45, sides=5)
    _hut_maren_paint(props, first, 3)

    # ---- glow: wisp lanterns, the potion bottles, bowl and cauldron fire ---
    for hook in lamps:
        add_blob(glow, tuple(hook), (0.52, 0.52, 0.62), 0.1, salt=61.0)
    for k in range(5):  # the mismatched bottles standing ON the shelf
        off = -1.9 + k * 0.95
        bx = shelf_f + math.cos(shelf_ang + math.pi / 2) * off
        by = shelf_s + math.sin(shelf_ang + math.pi / 2) * off
        px, py, _ = P(bx, by, 0)
        add_post(glow, px, py, FLOOR + 4.3, FLOOR + 5.05 + (k % 3) * 0.18, 0.34, sides=5)
    add_blob(glow, P(stump_f, stump_s, FLOOR + 3.32), (0.9, 0.9, 0.16), 0.06, salt=88.0, yaw=a)  # the scryed water
    for k in range(4):  # the fire under the cauldron
        ang = k * math.tau / 4
        add_cone(glow, P(pit_f + math.cos(ang) * 0.55, pit_s + math.sin(ang) * 0.55, pit_g + 0.1), 0.3, 0.05, 1.1, sides=4)

    LAVA_PONDS.append((cx, cy, keep_r))  # the region's shared keep-out registry
    door = P(shell_r(3.0, True), 0.0, 0)
    stand = P(10.5, 2.5, 0)  # at the cauldron, on the head of the plank path
    print(
        f"[island_gen] HANDOFF swamp hut (Morra's leaning bog hut): floor Y={FLOOR:.1f} on stilts over bed Y~{bog(0, 0):.1f}, "
        f"door (Roblox rel) X={door[0]:.1f} Z={-door[1]:.1f}, dooryard stand X={stand[0]:.1f} Z={-stand[1]:.1f}, "
        f"plank path runs out to X={P(19.6, 0, 0)[0]:.1f} Z={-P(19.6, 0, 0)[1]:.1f} (Morra's current mark); "
        f"Npcs.morra spawnOffset suggestion Vector3.new({stand[0]:.0f}, 0, {-stand[1] - 117.0:.0f}) facing 258"
    )
    print(f"[island_gen] swamp hut: {scales} roof scales, {len(lamps)} wisp posts, keep-clear r={keep_r:.0f} registered")
    return [
        object_from_bmesh("Swamp_Hut_Walls", walls, ["M_BogWattle", "M_RootWood"]),
        object_from_bmesh("Swamp_Hut_Roof", roof, ["M_BogShingle", "M_HangMoss"]),
        object_from_bmesh(
            "Swamp_Hut_Props", props, ["M_RootWood", "M_BogHerb", "M_BogBone", "M_BogJar", "M_BogIron", "M_BogStone"]
        ),
        object_from_bmesh("Swamp_Hut_Glow", glow, ["M_Wisp"]),
    ]


def build_swamp_foam():
    """The scummy pale rim where the fen meets the sea - the shared
    shoreline-foam builder on the standard coast ring. The swamp has NO
    sea dock, and build_foam collars whatever DOCK_POST_POSITIONS holds -
    which, in a pack build, is still the PREVIOUS island's posts (the
    same configure() carry-over family as the shape keys) - so the list
    is cleared first or the fen's rim grows phantom collars out at the
    volcano's dock coordinates."""
    DOCK_POST_POSITIONS.clear()
    return build_foam("Swamp_Foam", "M_SwampFoam")


def build_swamp():
    objects = [
        build_swamp_base(),
        build_swamp_water(),
        # Morra's hut BEFORE the scatter: it registers its keep-clear circle
        # (LAVA_PONDS + _hut_morra_clear) that the trees/reeds/smalls respect.
        *build_hut_morra(),
        *build_swamp_trees(),
        *build_swamp_cattails(),
        *build_swamp_smalls(),
        build_swamp_foam(),
    ]
    # The same guard the wreck island runs. It was Wreckwater-only, and a
    # floating mangrove limb shipped on THIS island because nothing checked
    # it (user, 2026-08-29). Nothing in the fen is meant to hover: the wisps
    # sit on their posts, the moss and bundles hang off geometry they touch.
    validate_no_floaters(objects, _swamp_height, label="swamp")
    a = math.radians(270)  # the +Z quadrant the dock will eventually face
    shore = ring_radius(1.0, a)
    mx, my, mr = SWAMP_MERE
    print(
        f"[island_gen] HANDOFF swamp: shore at +Z (Roblox rel) Z={shore:.0f}; spawn X=0 Z={shore - 30:.0f} ground Y~{_swamp_height(0, -(shore - 30)):.1f}"
    )
    print(
        f"[island_gen] HANDOFF swamp: marsh floods interior to u~{SWAMP_RIM_U} (water Y={SWAMP_WATER_Z}, bed ~{SWAMP_BED_Z}, wadeable); boss mere (Roblox rel) X={mx:.0f} Z={-my:.0f} r={mr:.0f} forced open"
    )
    return objects


# ---- Frostmaw Reach -------------------------------------------------------
#
# Frostmaw is a BLUNT island. Every form here is a chunky, soft-faceted mass
# with a wide base and a rounded shoulder - stacked ice courses, terraced
# slabs, rolled berg mounds, stubby teal crystals. Nothing on this island is a
# needle or a spike; the silhouette language is "boulder of ice", never
# "shard of glass".
#
# The read, from the sea in: stepped glacial cliff WALLS wrap most of the
# coast (leaving the dock quadrant and two beach bays open), the land behind
# them steps up in two broad TERRACES to a rolled berg MASSIF at the heart, an
# ICE ARCH stands out on the field, and the whole walkable sheet is scattered
# with hundreds of flat ice plates - the litter is the signature texture, and
# it thickens along the FROZEN CHANNEL (a broad shallow trough carved by
# NOTCHES) where most of the fishing holes are cut.
#
# Poly discipline: every ice mass is one low-sided tapered stack (_ice_mass,
# ~20 polys) and every plate is a yawed box (6 polys), so a very dense scatter
# still lands well inside the island budget.

_ICE_SNOW = {"bm": None}  # every snow stratum/cap on berg, walls and arches


def _snow_bm():
    """The one bmesh every ice mass drops its SNOW strata into - berg courses,
    wall courses, arch courses. Emitted once at the end as Frostmaw_SnowCaps
    (M_SnowCap), because one object carries exactly one material."""
    if _ICE_SNOW["bm"] is None:
        _ICE_SNOW["bm"] = bmesh.new()
    return _ICE_SNOW["bm"]


_ICE_OCC = []  # (x, z, radius) footprints of the big props, so they never merge
_ICE_CLUSTERS = []  # (x, z, radius) crystal cluster sites, shared with the litter
_ICE_WALL_FEET = []  # (x, z) wall course feet, so shard litter piles at their base


# Radius profiles for _ice_mass: (t along the height, radius multiplier).
# Every one of them ENDS WIDE - that is the whole art direction.
_PROF_BOULDER = ((0.0, 0.86), (0.30, 1.0), (0.70, 0.90), (1.0, 0.52))
_PROF_COURSE = ((0.0, 1.0), (0.55, 0.96), (0.85, 0.88), (1.0, 0.74))
_PROF_SLAB = ((0.0, 1.0), (0.70, 0.98), (1.0, 0.90))
_PROF_CRYSTAL = ((0.0, 1.0), (0.45, 0.88), (0.80, 0.68), (1.0, 0.52))  # tip = 52% of base
_PROF_DOME = ((0.0, 1.0), (0.40, 0.93), (0.75, 0.76), (1.0, 0.44))
_PROF_MOUND = ((0.0, 1.0), (0.35, 0.96), (0.70, 0.84), (1.0, 0.58))  # a rolled hill flank


def _ice_mass(bm, center, rx, ry, height, prof=_PROF_BOULDER, sides=6, yaw=0.0,
              tilt=(0.0, 0.0), jitter=0.0, salt=0.0):
    """ONE blunt ice mass: a low-sided stack of rings whose radius follows
    `prof`, capped top and bottom, then yawed/tilted into place with its BASE
    at `center`. This is the only solid Frostmaw builds anything from - bergs,
    wall courses, terrace slabs, crystals, snow mounds - which is what keeps
    the island's whole vocabulary chunky and consistent."""
    temp = bmesh.new()
    rings = []
    for t, m in prof:
        ring = []
        for s in range(sides):
            a = (s / sides) * math.tau
            w = 1.0
            if jitter:
                w += noise.noise(Vector((math.cos(a) * 1.7 + salt, math.sin(a) * 1.7 + salt * 0.6, t * 2.3))) * jitter
            ring.append(temp.verts.new(Vector((math.cos(a) * rx * m * w, math.sin(a) * ry * m * w, t * height))))
        rings.append(ring)
    temp.faces.new(list(reversed(rings[0])))
    for i in range(len(rings) - 1):
        lo, hi = rings[i], rings[i + 1]
        for s in range(sides):
            s2 = (s + 1) % sides
            temp.faces.new((lo[s], hi[s], hi[s2], lo[s2]))
    temp.faces.new(rings[-1])
    matrix = (
        Matrix.Translation(Vector(center))
        @ Matrix.Rotation(yaw, 4, "Z")
        @ Matrix.Rotation(tilt[0], 4, "X")
        @ Matrix.Rotation(tilt[1], 4, "Y")
    )
    bmesh.ops.transform(temp, matrix=matrix, verts=temp.verts[:])
    mesh = bpy.data.meshes.new("_icemass")
    temp.to_mesh(mesh)
    temp.free()
    bm.from_mesh(mesh)
    bpy.data.meshes.remove(mesh)


def _ice_plate(bm, x, z, surface, size, salt):
    """One flat broken floe on the ice: a thin yawed slab lying almost level.
    Six polys - the reason the sheet can carry hundreds of them."""
    thick = size * random.uniform(0.10, 0.20) + 0.16
    add_box(bm, (x, z, surface + thick * 0.35), (size, size * random.uniform(0.55, 0.95), thick),
            yaw=salt)


def _ragged_ring(sides, jitter, salt):
    """A closed ring of `sides` (x, y) offsets on the unit circle, each vertex
    pushed in or out by up to `jitter` and nudged around the circle a little,
    so no two rings are the same polygon. This is what killed the hexagon:
    every shelf, drift and fragment on Frostmaw draws its own plan here."""
    pts = []
    step = math.tau / sides
    for s in range(sides):
        a = s * step + noise.noise(Vector((s * 0.83 + salt, salt * 1.31, 0.0))) * step * 0.34
        w = 1.0 + noise.noise(Vector((math.cos(a) * 2.3 + salt,
                                      math.sin(a) * 2.3 - salt * 0.4,
                                      salt * 0.77))) * jitter
        pts.append((math.cos(a) * w, math.sin(a) * w))
    return pts


def _ice_slab(bm, ring, cx, cy, z0, thickness, rx, ry, yaw=0.0,
              top_scale=1.0, bot_scale=1.0):
    """ONE COURSE OF ICE: a broad, low, ragged slab. `ring` is its plan, `rx`
    and `ry` stretch it into an elongated shelf, `yaw` points that elongation,
    and top_scale/bot_scale decide whether the course is an INSET (a terrace
    you could stand on) or an OVERHANG (a cantilevered lip). Stacked, these
    read as horizontal strata in a carved glacier face."""
    ca, sa = math.cos(yaw), math.sin(yaw)

    def loop(scale, z):
        out = []
        for ux, uy in ring:
            x, y = ux * rx * scale, uy * ry * scale
            out.append(bm.verts.new(Vector((cx + x * ca - y * sa, cy + x * sa + y * ca, z))))
        return out

    bot = loop(bot_scale, z0)
    top = loop(top_scale, z0 + thickness)
    bm.faces.new(top)
    bm.faces.new(list(reversed(bot)))
    n = len(ring)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((bot[i], bot[j], top[j], top[i]))


def _ice_shelf_stack(ice_bm, snow_bm, cx, cy, z_base, radius, height, salt,
                     taper=0.70, drift=5.0, thick=(4.0, 10.0), sides=(10, 16),
                     ratio=(1.3, 2.2), jitter=(0.12, 0.25), snow=True,
                     lip_chance=0.26, benches=4, lean=None):
    """A STRATIFIED SHELF MASS - Frostmaw's whole structural language.

    A stack of broad low courses climbing from a wide base to a narrower,
    irregular crown. Every course is its OWN closed ragged polygon (10-16
    vertices, +-12-25% radial jitter), elongated 1.3-2.2:1 along its OWN
    axis, drifted and turned off the one below it, and set either narrower
    than its neighbour (a terrace) or wider (an overhanging lip). Every
    second or third course is a thin SNOW stratum, which is what turns the
    mass into visible horizontal banding instead of a lump.

    The radius does not fall smoothly: it HOLDS across a bench (a run of
    courses at one width, which is what a walkable glacier terrace looks
    like) and then steps back sharply to the next. That stepping is the
    difference between a carved massif and a wedding cake of discs.

    Returns (crown_z, list of (x, y, z, radius) terrace tops)."""
    # Bench levels: the width each terrace holds, with a jittered step down
    # between them so no two risers are the same height of ice.
    levels = []
    for b in range(benches + 1):
        f = b / max(benches, 1)
        levels.append((1.0 - taper * (f ** 1.05)) * random.uniform(0.94, 1.06))
    # Within one bench the courses share an elongation AXIS and roughly one
    # aspect, so they stack in register and read as a solid banded wall of
    # ice. Benches differ from each other, which is where the raggedness
    # lives. (Randomising both per course is what made the first pass look
    # like a stack of flying saucers.)
    # The elongation axis ROTATES slowly up the stack rather than jumping: two
    # neighbouring benches at right angles read as a pagoda of crossed plates,
    # which is exactly the failure this builder exists to avoid.
    bench_yaw = []
    a = random.uniform(0.0, math.tau)
    for _ in range(benches + 1):
        bench_yaw.append(a)
        a += random.uniform(0.22, 0.72) * random.choice((-1.0, 1.0))
    # And the plan rounds out as it climbs, so the crown is a broken cap
    # rather than a blade sticking out over the face below it.
    bench_ratio = []
    for b in range(benches + 1):
        f = b / max(benches, 1)
        r0 = random.uniform(*ratio)
        bench_ratio.append(r0 + (1.15 - r0) * (f ** 2))

    def core_at(t):
        p = min(t, 0.9999) * benches
        b = int(p)
        f = p - b
        lo, hi = levels[b], levels[min(b + 1, benches)]
        # A gentle batter across the bench, then the riser: a terrace face
        # that leans, not a drum of constant width.
        return (lo + (hi - lo) * smoothstep(0.62, 1.0, f)) * (1.0 - 0.07 * f)

    # `lean` is what makes the mass a GLACIER FACE rather than a cairn: as the
    # courses narrow they all shift the same way, so one flank stays a sheer
    # banded cliff while the other steps back into a run of broad terraces.
    lx, ly = lean if lean else (0.0, 0.0)
    z = z_base
    dx = dy = 0.0
    since_snow = 0
    want_snow = random.choice((1, 2))
    terraces = []
    i = 0
    prev_rr = radius * 1.2
    while z < z_base + height:
        t = max(0.0, (z - z_base) / height)
        b = min(int(min(t, 0.9999) * benches), benches)
        core = core_at(t)
        is_snow = snow and since_snow >= want_snow and t < 0.96
        n = random.randint(*sides)
        ring = _ragged_ring(n, random.uniform(*jitter), salt + i * 4.3)
        rr = radius * core * random.uniform(0.93, 1.04)
        # Lips only low down - a cantilever near the crown just makes a hat.
        lip = t < 0.62 and random.random() < lip_chance
        if lip:
            rr *= random.uniform(1.04, 1.12)  # a cantilevered course
        # No course may flare much past the one under it, or the mass turns
        # into a pile of saucers with daylight beneath every rim.
        rr = min(rr, prev_rr * 1.05)
        prev_rr = rr
        k = math.sqrt(bench_ratio[b] * random.uniform(0.92, 1.09))
        yaw = bench_yaw[b] + random.uniform(-0.30, 0.30)
        if is_snow:
            th = random.uniform(1.5, 3.2)
            bot_s, top_s = 1.0, random.uniform(0.90, 1.0)
        else:
            th = random.uniform(*thick) * (1.0 - 0.28 * t)
            # An overhanging course flares upward; an inset course pulls in.
            bot_s = 1.0
            top_s = random.uniform(1.01, 1.08) if lip else random.uniform(0.86, 0.99)
        shift = (radius - rr) * 0.62
        ox, oy = cx + dx + lx * shift, cy + dy + ly * shift
        _ice_slab(ice_bm if not is_snow else snow_bm, ring, ox, oy, z, th,
                  rr * k, rr / k, yaw=yaw, top_scale=top_s, bot_scale=bot_s)
        if not is_snow and top_s < 0.92 and t > 0.12:
            terraces.append((ox, oy, z + th, rr * top_s))
        if is_snow:
            since_snow = 0
            want_snow = random.choice((1, 2))
        else:
            since_snow += 1
        # Courses overlap slightly so the strata never gap open.
        z += th * random.uniform(0.68, 0.86)
        # Mean-reverting wander: courses shuffle off each other but the stack
        # never walks away from its own foot.
        dx = dx * 0.78 + random.uniform(-drift, drift)
        dy = dy * 0.78 + random.uniform(-drift, drift)
        i += 1
    return z, terraces


def _ice_chunk(bm, center, size, yaw, tilt):
    """An ANGULAR broken block - a tilted box, six flat faces, no roundness.
    The counterpoint to the flat plates in the shard litter."""
    temp = bmesh.new()
    bmesh.ops.create_cube(temp, size=1.0)
    matrix = (
        Matrix.Translation(Vector(center))
        @ Matrix.Rotation(yaw, 4, "Z")
        @ Matrix.Rotation(tilt[0], 4, "X")
        @ Matrix.Rotation(tilt[1], 4, "Y")
        @ Matrix.Diagonal(Vector(size)).to_4x4()
    )
    bmesh.ops.transform(temp, matrix=matrix, verts=temp.verts[:])
    mesh = bpy.data.meshes.new("_icechunk")
    temp.to_mesh(mesh)
    temp.free()
    bm.from_mesh(mesh)
    bpy.data.meshes.remove(mesh)


def _ice_drift(bm, x, z, surface, w, salt):
    """A wind-piled SNOW DRIFT: two or three overlapping low lobes, each its
    own ragged 5-9 sided plan, each elongated on its own axis and wedging
    down to a thin lip. Nothing here shares a silhouette with the shelves,
    the crystals or the litter - which is the entire point."""
    lobes = random.randint(2, 3)
    ang = random.uniform(0, math.tau)
    for k in range(lobes):
        ring = _ragged_ring(random.randint(5, 9), random.uniform(0.18, 0.34), salt + k * 3.7)
        f = 1.0 if k == 0 else random.uniform(0.42, 0.80)
        rr = w * f
        d = 0.0 if k == 0 else w * random.uniform(0.45, 1.0)
        a = ang + (k - 1) * random.uniform(0.6, 1.7)
        kk = math.sqrt(random.uniform(1.35, 2.5))
        h = rr * random.uniform(0.30, 0.60)
        _ice_slab(bm, ring, x + math.cos(a) * d, z + math.sin(a) * d,
                  surface - h * 0.5, h, rr * kk, rr / kk,
                  yaw=a + random.uniform(-0.7, 0.7),
                  top_scale=random.uniform(0.26, 0.55))


def _ice_fragment(bm, x, z, surface, w, salt):
    """A small SHELF FRAGMENT: one or two thin ragged courses, a chip off the
    big strata lying on the sheet."""
    zc = surface - w * 0.22
    for c in range(random.randint(1, 2)):
        ring = _ragged_ring(random.randint(6, 10), random.uniform(0.16, 0.30), salt + c * 2.9)
        rr = w * (1.0 if c == 0 else random.uniform(0.55, 0.82))
        kk = math.sqrt(random.uniform(1.4, 2.3))
        th = w * random.uniform(0.16, 0.30)
        _ice_slab(bm, ring, x + random.uniform(-w * 0.2, w * 0.2),
                  z + random.uniform(-w * 0.2, w * 0.2), zc, th,
                  rr * kk, rr / kk, yaw=random.uniform(0, math.tau),
                  top_scale=random.uniform(0.72, 1.06))
        zc += th * 0.88


# ---- the ice overhang (the island's centrepiece) --------------------------
#
# NOT a berg, NOT a stack of shelves: one CONTINUOUS LOFTED glacial headwall
# swept round a crescent, whose upper third curls outward into a cornice you
# can walk under. The cross-section below is the whole shape - a thick back
# face, a scooped waist, and a lip that noses out over the hollow - swept
# along the arc with a smoothly varying height and reach, so the silhouette
# flows like carved ice instead of reading as courses.
_OVERHANG = {
    "a0": math.radians(12.0),   # arc start bearing
    "a1": math.radians(168.0),  # arc end bearing (a 156 deg crescent)
    "R": 64.0,                  # arc radius from the island centre
    "H": 90.0,                  # peak headwall height
    "U": 24.0,                  # radial scale of the cross-section
}

# (u, v): u is INWARD from the arc line (so +u leans over the hollow), v is
# the fraction of the wall's height. One closed 16-vertex loop, traversed up
# the back face and down the overhanging front.
_OVERHANG_PROFILE = (
    (-0.55, 0.000),  # back toe
    (-0.58, 0.200),
    (-0.55, 0.420),
    (-0.50, 0.640),
    (-0.44, 0.820),
    (-0.30, 0.940),  # back shoulder      -- snow starts here
    (-0.08, 1.000),  # crest
    (0.34, 1.000),  # crest, front edge
    (0.62, 0.955),  # lip tip, top       -- snow ends here
    (0.72, 0.895),  # lip tip, nose
    (0.56, 0.822),  # underside of the cornice
    (0.26, 0.718),  # underside root     -- icicles hang along 9..11
    (-0.10, 0.560),  # the waist, scooped back
    (-0.26, 0.370),  # deepest scoop - the alcove
    (-0.14, 0.170),
    (0.10, 0.000),  # front toe
)  # fmt: skip
_OVERHANG_SNOW = (5, 6, 7, 8)  # profile indices whose faces are top surfaces
_OVERHANG_DRIP = (9, 10, 11)  # profile indices along the cornice underside


def _overhang_station(s):
    """The swept cross-section at fraction `s` along the crescent: its bearing,
    arc radius, height and radial reach. Tallest and deepest-reaching at the
    middle of the sweep, tapering away at both horns."""
    o = _OVERHANG
    s = min(max(s, 0.0), 1.0)
    theta = o["a0"] + (o["a1"] - o["a0"]) * s
    bell = math.sin(math.pi * s) ** 0.55
    # Two noise terms wander the crest line and the reach of the cornice, so
    # the sweep is lopsided - one horn taller, the lip biting deeper in some
    # stretches than others - rather than a clean parabola of ice.
    w = noise.noise(Vector((s * 3.3, 0.0, 11.0)))
    w2 = noise.noise(Vector((s * 8.1, 4.0, 5.0)))
    rad = o["R"] + 15.0 * math.sin(2.1 * math.pi * s + 0.7) + 8.0 * w
    # The horns melt back down into the snow rather than ending on a wall.
    horn = math.sin(math.pi * s) ** 0.75
    h = o["H"] * (0.06 + 0.94 * horn) * (1.0 + 0.20 * w + 0.09 * w2)
    h = min(h, o["H"])
    u = o["U"] * (0.70 + 0.30 * bell) * (1.0 + 0.12 * w2)
    return theta, rad, h, u


def _overhang_point(s, k, z0):
    """One lofted vertex: profile index `k` at sweep fraction `s`, jittered so
    the ice face is never a mathematically clean surface. Vertical jitter
    fades to nothing at the foot and the crest so the wall still seats on the
    ground and still caps cleanly."""
    theta, rad, h, uscale = _overhang_station(s)
    u, v = _OVERHANG_PROFILE[k]
    # The inner face - the one you stand under - gets the high-frequency
    # term at full strength, so the alcove wall is melt-fluted rather than a
    # clean swept shell.
    flute = 2.4 if k >= 10 else 1.0
    ju = (noise.noise(Vector((k * 0.53, s * 6.1, 3.7))) * 0.15
          + noise.noise(Vector((k * 1.9, s * 17.0, 8.3))) * 0.055 * flute)
    jv = (noise.noise(Vector((k * 0.41 + 9.0, s * 5.3, 1.9))) * 0.10
          + noise.noise(Vector((k * 1.7 + 3.0, s * 15.0, 6.1))) * 0.035)
    u = u * (1.0 + ju) + ju * 0.14
    v = v + jv * (v * (1.0 - v) * 4.0)
    r = rad - u * uscale
    return Vector((math.cos(theta) * r, math.sin(theta) * r, z0 + v * h))


def _in_overhang(x, z, pad=0.0):
    """Inside the crescent's footprint OR the sheltered hollow under its
    cornice - the ground props must leave both alone, so the walk under the
    ice stays clear."""
    o = _OVERHANG
    r = math.hypot(x, z)
    if not (28.0 - pad < r < 110.0 + pad):
        return False
    theta = math.atan2(z, x) % math.tau
    lo, hi = o["a0"] - 0.14, o["a1"] + 0.14
    return lo <= theta <= hi


def _ice_spawn_xy():
    """Where WorldService drops the player: 18 studs inland of the dock start
    on the dock bearing. Nothing is ever built inside its bubble."""
    a = math.radians(DOCK_ANGLE_DEG)
    r = ring_radius(DOCK_START_U, a) - 18.0
    return math.cos(a) * r, math.sin(a) * r


def _ice_open(x, z, pad=0.0, spawn_clear=14.0, hollow_ok=False):
    """Is (x, z) free to build on? Keeps the walk off the planks open, keeps a
    clear standing bubble at the spawn, stays out of every cut hole, keeps
    Halvard's yard swept, and (unless `hollow_ok`) stays out of the ice
    overhang and the standable hollow beneath its cornice."""
    if not hollow_ok and _in_overhang(x, z, pad):
        return False
    # Halvard's hull and its yard: the scatters (holes, drifts, litter, pines)
    # must not grow through his roof or bury his door.
    for kx, ky, kr in _HUT_H_KEEP:
        if (x - kx) ** 2 + (z - ky) ** 2 < (kr + pad) ** 2:
            return False
    theta = math.atan2(z, x)
    a = math.radians(DOCK_ANGLE_DEG)
    da = abs(((theta - a + math.pi) % math.tau) - math.pi)
    if da < 0.14 and math.hypot(x, z) > ring_radius(0.72, theta):
        return False
    sx, sz = _ice_spawn_xy()
    if (x - sx) ** 2 + (z - sz) ** 2 < (spawn_clear + pad) ** 2:
        return False
    return _clear_of_ponds(x, z, max(pad, 2.0))


def _ice_free(x, z, r):
    """No big prop overlaps another big prop's footprint."""
    return all((x - px) ** 2 + (z - pz) ** 2 > (r + pr) ** 2 for px, pz, pr in _ICE_OCC)


def _ice_claim(x, z, r):
    _ICE_OCC.append((x, z, r))


def _ice_channel_spot(u_lo=0.56, u_hi=0.93, spread=0.85):
    """A point in the frozen channel - the trough NOTCHES carves across the
    sheet. Holes cluster here and the floe litter thickens here."""
    if not NOTCHES:
        return None
    a0, half, _d = random.choice(NOTCHES)
    theta = a0 + random.uniform(-half * spread, half * spread)
    u = random.uniform(u_lo, u_hi)
    r = ring_radius(u, theta)
    return math.cos(theta) * r, math.sin(theta) * r


def build_ice_holes(ground):
    """The fishing holes: 18-24 ragged discs of black-blue water cut through
    the sheet, most of them strung along the frozen channel where the ice is
    thin, the rest out on the open terraces. One object, Frostmaw_IceHoles -
    the fishable-surface contract name (waters="ice")."""
    bm = bmesh.new()
    LAVA_PONDS.clear()
    _ICE_OCC.clear()
    _ICE_CLUSTERS.clear()
    _ICE_WALL_FEET.clear()
    placed = 0

    def cut(x, z, hollow_ok=False):
        nonlocal placed
        if not _ice_open(x, z, pad=11.0, spawn_clear=20.0, hollow_ok=hollow_ok):
            return False
        surface = _drop_to_ground(ground, x, z)
        if surface is None:
            return False
        hr = random.uniform(4.6, 8.0)
        _pool_disc(bm, x, z, hr, surface + 0.22, 2.0, salt=x * 0.13 + z * 0.07,
                   squash=random.uniform(0.82, 1.0))
        placed += 1
        return True

    # THE SHELTERED HOLES: three cut in the hollow roofed by the overhang's
    # cornice - you fish them standing under the ice.
    roofed = 0
    for j in range(9):
        if roofed >= 3:
            break
        theta, rad, _h, uscale = _overhang_station(0.28 + 0.19 * j)
        r = rad - uscale * random.uniform(0.34, 0.56)
        if cut(math.cos(theta) * r, math.sin(theta) * r, hollow_ok=True):
            roofed += 1

    # Strung along the channel: the run you walk to work the ice.
    for _ in range(120):
        if placed >= 13:
            break
        spot = _ice_channel_spot(0.58, 0.90)
        if spot is not None:
            cut(*spot)

    # The rest out on the open sheet, so the terraces are fishable too.
    for _ in range(220):
        if placed >= 21:
            break
        theta = random.uniform(0, math.tau)
        u = random.uniform(0.56, 0.90)
        r = ring_radius(u, theta)
        cut(math.cos(theta) * r, math.sin(theta) * r)

    print(f"[island_gen] ice holes: {placed}")
    return object_from_bmesh("Frostmaw_IceHoles", bm, ["M_IceWater"])


# The coastline windows left OPEN (no cliff wall): the dock quadrant, so the
# approach from the sea reads as a landing, and two beach bays. Everything
# else gets stepped glacial cliffs. (centre degrees, half-width degrees)
_ICE_WALL_GAPS = ((270.0, 40.0), (152.0, 24.0), (34.0, 20.0), (208.0, 12.0))


def _ice_wall_gap(theta):
    for c, half in _ICE_WALL_GAPS:
        a0 = math.radians(c)
        da = abs(((theta - a0 + math.pi) % math.tau) - math.pi)
        if da < math.radians(half):
            return True
    return False


def build_ice_walls(ground):
    """The coast the reference opens with: BIG SMOOTH GLACIAL CLIFFS. Stacked
    courses of rounded chunks - a wide foot course, a stepped-back middle, a
    narrower crown - marching round the shoreline wherever a bay or the dock
    quadrant does not open it up. 15-45 studs, and every course is blunt."""
    bm = bmesh.new()
    STEPS = 104
    built = 0
    for i in range(STEPS):
        theta = (i / STEPS) * math.tau
        if _ice_wall_gap(theta):
            continue
        # A slow swell along the coast: some stretches are low ramparts, some
        # are full cliffs, so the wall is never one extruded band.
        s = 0.5 + 0.5 * math.sin(2.7 * theta + 0.9)
        s2 = 0.5 + 0.5 * math.sin(6.1 * theta + 2.4)
        H = 18.0 + 22.0 * s + 6.0 * s2
        u = 0.995 + 0.012 * math.sin(9.0 * theta + 1.7)
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        surface = _drop_to_ground(ground, x, z)
        if surface is None:
            continue
        _ICE_WALL_FEET.append((x, z))
        # The SAME strata language as the massif: long low ragged courses laid
        # along the shore, each wider than the station spacing so the face
        # fuses into one continuous banded cliff, stepping back as it climbs
        # with the odd course overhanging into a lip.
        step = math.tau * r / STEPS
        out = Vector((math.cos(theta), math.sin(theta)))
        tangent = theta + math.pi / 2
        zc = surface - 7.0
        n_courses = random.randint(2, 3)
        rise = H / n_courses
        back = 0.0
        since_snow = 0
        for c in range(n_courses):
            f = c / max(n_courses - 1, 1)
            # Wide, deep courses with a shallow set-back: the face reads as
            # one continuous sweep of ice, with only the crest breaking up.
            long_r = step * random.uniform(1.55, 2.10) * (1.0 - 0.22 * f)
            ratio = random.uniform(1.9, 3.0)
            deep_r = long_r / ratio
            lip = random.random() < 0.22
            th = rise * random.uniform(1.15, 1.55)
            ring = _ragged_ring(random.randint(9, 14), random.uniform(0.10, 0.20),
                                120.0 + i * 3.1 + c * 1.7)
            cx = x + out.x * back + random.uniform(-step * 0.25, step * 0.25)
            cz = z + out.y * back + random.uniform(-step * 0.25, step * 0.25)
            _ice_slab(bm, ring, cx, cz, zc, th, long_r, deep_r,
                      yaw=tangent + random.uniform(-0.22, 0.22),
                      top_scale=random.uniform(1.02, 1.08) if lip else random.uniform(0.86, 0.98))
            since_snow += 1
            if since_snow >= 2 and c < n_courses - 1:
                sring = _ragged_ring(random.randint(8, 13), random.uniform(0.15, 0.28),
                                     260.0 + i * 2.3 + c)
                _ice_slab(_snow_bm(), sring, cx, cz, zc + th * 0.94,
                          random.uniform(1.4, 2.8), long_r * 0.97, deep_r * 0.97,
                          yaw=tangent + random.uniform(-0.3, 0.3),
                          top_scale=random.uniform(0.88, 1.0))
                since_snow = 0
            zc += th * random.uniform(0.72, 0.86)
            back -= deep_r * random.uniform(0.14, 0.34)
        # A snow crest on the top course, so the cliff line reads white-capped
        # from the sea.
        if i % 2 == 0:
            cring = _ragged_ring(random.randint(8, 12), random.uniform(0.16, 0.30), 380.0 + i * 1.9)
            cr = step * random.uniform(0.8, 1.25)
            _ice_slab(_snow_bm(), cring, x + out.x * back, z + out.y * back, zc,
                      random.uniform(2.0, 4.2), cr, cr / random.uniform(1.8, 2.8),
                      yaw=tangent + random.uniform(-0.4, 0.4),
                      top_scale=random.uniform(0.52, 0.80))
        built += 1
    print(f"[island_gen] ice walls: {built} cliff stations "
          f"({built / STEPS * 100:.0f}% of the coastline)")
    return object_from_bmesh("Frostmaw_Walls", bm, ["M_GlacialIce"])


def build_ice_terraces(ground):
    """The two terrace lips get a course of chunky ice blocks along their edge,
    so the step the PROFILE cuts reads as a flat-topped glacier plateau with a
    vertical chunky side (reference image 2) instead of a soft slope."""
    bm = bmesh.new()
    for lip_u, block in ((0.305, 7.5), (0.505, 6.5), (0.665, 5.5)):
        n = int(math.tau * lip_u * ISLAND_RADIUS / (block * 1.55))
        for i in range(n):
            theta = (i / n) * math.tau + random.uniform(-0.012, 0.012)
            # Only stretches of each lip are chunked, so it reads as a broken
            # glacier edge and not a fence running all the way round.
            if 0.5 + 0.5 * math.sin(4.3 * theta + lip_u * 31.0) < 0.34:
                continue
            r = ring_radius(lip_u + random.uniform(-0.004, 0.006), theta)
            x, z = math.cos(theta) * r, math.sin(theta) * r
            if not _ice_open(x, z, pad=0.0, spawn_clear=13.0):
                continue
            surface = _drop_to_ground(ground, x, z)
            if surface is None:
                continue
            # Two thin ragged courses laid ALONG the lip - the terrace edge
            # bands like the cliffs do, rather than growing teeth.
            w = block * random.uniform(0.95, 1.55)
            zc = surface - block * random.uniform(0.9, 1.5)
            for c in range(random.randint(1, 2)):
                ring = _ragged_ring(random.randint(8, 13), random.uniform(0.14, 0.28),
                                    300 + i * 1.7 + lip_u * 37.0 + c * 2.3)
                ratio = random.uniform(1.8, 2.9)
                th = block * random.uniform(0.45, 0.85)
                rr = w * (1.0 - c * random.uniform(0.10, 0.26))
                _ice_slab(bm, ring, x, z, zc, th, rr, rr / ratio,
                          yaw=theta + math.pi / 2 + random.uniform(-0.3, 0.3),
                          top_scale=random.uniform(1.02, 1.10) if random.random() < 0.3
                          else random.uniform(0.80, 0.96))
                zc += th * 0.9
    # A few free-standing stepped mesas out on the sheet - stratified shelf
    # stacks, flat-topped, with terraces cut into their flanks.
    mesas = 0
    for _ in range(90):
        if mesas >= 7:
            break
        theta = random.uniform(0, math.tau)
        u = random.uniform(0.58, 0.86)
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        base = random.uniform(13.0, 22.0)
        if not _ice_open(x, z, pad=base + 6.0, spawn_clear=24.0) or not _ice_free(x, z, base + 8.0):
            continue
        surface = _drop_to_ground(ground, x, z)
        if surface is None:
            continue
        _ice_claim(x, z, base + 6.0)
        _ice_shelf_stack(bm, _snow_bm(), x, z, surface - 3.0, radius=base,
                         height=random.uniform(16.0, 34.0), salt=420.0 + mesas * 9.3,
                         taper=random.uniform(0.42, 0.66), drift=1.8,
                         thick=(3.5, 7.0), sides=(9, 14), ratio=(1.4, 2.2),
                         jitter=(0.13, 0.26), lip_chance=0.34)
        mesas += 1
    print(f"[island_gen] ice terraces: {mesas} stepped mesas")
    return object_from_bmesh("Frostmaw_Terraces", bm, ["M_IceStep"])


def build_ice_berg(ground):
    """THE ICE OVERHANG - the island's centrepiece, and one continuous piece
    of ice, not an assembly.

    A crescent glacial headwall sweeps a 156-degree arc round the heart of
    the island. Its cross-section (_OVERHANG_PROFILE) is lofted station to
    station along that arc: a thick back face rising off the snow, a waist
    scooped back into an alcove, and an upper third that curls OUT over the
    hollow into a cornice reaching 15-25 studs past the wall below it. The
    ground under that cornice is left clear of every prop, so you can walk
    in under the ice - three of the fishing holes are cut in there.

    There is deliberately no visible stratification on this form: the only
    banding is the thin snow lying on its top surfaces (Frostmaw_SnowCaps),
    and a fringe of icicles hangs off the underside of the lip."""
    bm = bmesh.new()
    snow = _snow_bm()
    o = _OVERHANG
    STATIONS = 42

    # Seat each station on the ground under its own footprint, sunk deep
    # enough that the wall never floats over a terrace riser.
    bases = []
    for i in range(STATIONS + 1):
        s = i / STATIONS
        theta, rad, _h, uscale = _overhang_station(s)
        lo = None
        for u in (-0.58, 0.0, 0.20):
            r = rad - u * uscale
            g = _drop_to_ground(ground, math.cos(theta) * r, math.sin(theta) * r)
            if g is not None:
                lo = g if lo is None else min(lo, g)
        bases.append((lo if lo is not None else 32.0) - 9.0)

    n = len(_OVERHANG_PROFILE)
    rings = []
    for i in range(STATIONS + 1):
        s = i / STATIONS
        rings.append([bm.verts.new(_overhang_point(s, k, bases[i])) for k in range(n)])
    for i in range(STATIONS):
        a, b = rings[i], rings[i + 1]
        for k in range(n):
            k2 = (k + 1) % n
            bm.faces.new((a[k], a[k2], b[k2], b[k]))
    bm.faces.new(list(reversed(rings[0])))  # the two horns are capped
    bm.faces.new(rings[-1])

    # SNOW on the top surfaces only: a lofted ribbon over the crest and out
    # along the back of the lip, sitting a stud proud of the ice.
    lift = Vector((0.0, 0.0, 1.15))
    for k in _OVERHANG_SNOW[:-1]:
        left = [_overhang_point(i / STATIONS, k, bases[i]) + lift for i in range(STATIONS + 1)]
        right = [_overhang_point(i / STATIONS, k + 1, bases[i]) + lift for i in range(STATIONS + 1)]
        add_strip_slab(snow, left, right, 1.55)

    # ICICLES fringing the underside of the cornice: slender down-cones of
    # mixed length, thickest where the lip reaches furthest.
    drips = 0
    for j in range(30):
        s = (j + random.uniform(0.12, 0.88)) / 30.0
        theta, rad, h, uscale = _overhang_station(s)
        bell = math.sin(math.pi * s) ** 0.55
        if random.random() > 0.28 + 0.62 * bell:
            continue
        k = random.choice(_OVERHANG_DRIP)
        p = _overhang_point(s, k, bases[int(s * STATIONS)])
        p = p + Vector((math.cos(theta), math.sin(theta), 0.0)) * random.uniform(-1.2, 1.2)
        length = random.uniform(2.0, 8.0) * (0.55 + 0.45 * bell)
        rb = length * random.uniform(0.09, 0.17) + 0.22
        add_cone(bm, p, rb, rb * 0.10, length, sides=random.choice((4, 5, 6)),
                 tilt=(math.pi, 0.0), yaw=random.uniform(0, math.tau))
        drips += 1

    foot = min(bases) + 9.0
    crown = max(bases[i] + _overhang_station(i / STATIONS)[2] for i in range(STATIONS + 1))
    span = _OVERHANG_PROFILE[9][0] - _OVERHANG_PROFILE[13][0]
    # Measured where the wall is actually tall enough to carry a cornice.
    reaches = [span * _overhang_station(i / STATIONS)[3] for i in range(STATIONS + 1)
               if _overhang_station(i / STATIONS)[2] > o["H"] * 0.45]
    print(f"[island_gen] frostmaw overhang: crescent {math.degrees(o['a1'] - o['a0']):.0f} deg "
          f"at r~{o['R']:.0f}, foot Y~{foot:.1f}, crest ~{crown:.0f} "
          f"({crown - foot:.0f} studs of wall), cornice reaches "
          f"{min(reaches):.0f}-{max(reaches):.0f} studs over the hollow, {drips} icicles")
    return object_from_bmesh("Frostmaw_Berg", bm, ["M_BergIce"])


_ARCH_SITES = ((214.0, 118.0, 80.0, 36.0), (66.0, 132.0, 54.0, 27.0))
# (bearing deg, radius from centre, leg separation, leg height)


def build_ice_arch(ground):
    """ICE ARCHES: two thick blunt legs and a chunky curved span walked over
    them in overlapping blocks. The big one stands out on the sheet where you
    can walk under it; a smaller one springs near the massif's skirt."""
    bm = bmesh.new()
    built = 0
    for si, (bearing, dist, sep, legh) in enumerate(_ARCH_SITES):
        a = math.radians(bearing)
        cx, cz = math.cos(a) * dist, math.sin(a) * dist
        # The span runs across the bearing, so you walk under it going round.
        ax, az = math.cos(a + math.pi / 2), math.sin(a + math.pi / 2)
        legs = []
        ok = True
        for sgn in (-1, 1):
            lx, lz = cx + ax * sep * 0.5 * sgn, cz + az * sep * 0.5 * sgn
            s = _drop_to_ground(ground, lx, lz)
            if s is None:
                ok = False
                break
            legs.append((lx, lz, s))
        if not ok:
            continue
        legr = legh * 0.34
        for li, (lx, lz, s) in enumerate(legs):
            # The legs are strata too - short stacks of ragged courses, so the
            # arch belongs to the same glacier as the massif and the cliffs.
            _ice_shelf_stack(bm, _snow_bm(), lx, lz, s - 4.0, radius=legr,
                             height=legh + 4.0, salt=700.0 + si * 31.0 + li * 7.0,
                             taper=0.30, drift=0.9, thick=(3.4, 6.5),
                             sides=(9, 13), ratio=(1.3, 1.9), jitter=(0.12, 0.24),
                             lip_chance=0.28)
            _ice_claim(lx, lz, legr * 1.6)
        # The span: an arc of overlapping blunt blocks from leg top to leg top.
        base_z = min(l[2] for l in legs) + legh
        SEG = 11
        rise = sep * 0.34
        for k in range(SEG):
            t = k / (SEG - 1)
            ang = math.pi * t
            px = cx - ax * sep * 0.5 * math.cos(ang)
            pz = cz - az * sep * 0.5 * math.cos(ang)
            py = base_z + rise * math.sin(ang)
            w = sep * 0.115 * (1.0 + 0.18 * math.sin(ang))
            # Voussoir COURSES: flat ragged slabs laid along the span, each
            # one a shelf, so the arch bands like everything else here.
            ring = _ragged_ring(random.randint(8, 12), random.uniform(0.12, 0.24),
                                740 + si * 11 + k * 1.7)
            _ice_slab(bm, ring, px, pz, py - w * 0.62, w * random.uniform(1.05, 1.45),
                      w * 1.35, w * 0.62,
                      yaw=math.atan2(az, ax) + random.uniform(-0.16, 0.16),
                      top_scale=random.uniform(0.86, 1.06))
        _ice_claim(cx, cz, sep * 0.5 + legr)
        built += 1
        print(f"[island_gen] ice arch {built}: span {sep:.0f} studs, "
              f"clearance ~{legh:.0f} studs, apex ~{base_z + rise:.0f}")
    return object_from_bmesh("Frostmaw_Arch", bm, ["M_ArchIce"])


def build_ice_crystals(ground):
    """Clusters of STUBBY teal crystals: wide-based, blunt-tipped standing
    stones of ice (the tip is 44% of the base, so they read as monoliths, not
    needles). Knee-height to house-height, some tilted, always in a group."""
    bm = bmesh.new()
    grown = 0
    for _ in range(400):
        if len(_ICE_CLUSTERS) >= 13:
            break
        theta = random.uniform(0, math.tau)
        u = random.uniform(0.55, 0.90)
        r = ring_radius(u, theta)
        cx, cz = math.cos(theta) * r, math.sin(theta) * r
        crad = random.uniform(9.0, 16.0)
        if not _ice_open(cx, cz, pad=crad + 5.0, spawn_clear=26.0):
            continue
        if not _ice_free(cx, cz, crad + 9.0):
            continue
        _ice_claim(cx, cz, crad + 5.0)
        _ICE_CLUSTERS.append((cx, cz, crad))
        tall = random.uniform(17.0, 30.0)
        n = random.randint(3, 8)
        # Three different ARRANGEMENTS, so clusters do not all read as the
        # same rosette: a ring, a raked line (a fracture vein), and a tight
        # huddle with one dominant stone.
        plan = random.choice(("ring", "vein", "huddle"))
        vein = random.uniform(0, math.tau)
        for k in range(n):
            if plan == "ring":
                a = (k / n) * math.tau + random.uniform(-0.5, 0.5)
                d = random.uniform(0.0, crad * 0.85) if k else 0.0
            elif plan == "vein":
                a = vein + random.uniform(-0.28, 0.28) + (math.pi if k % 2 else 0.0)
                d = crad * (k / max(n - 1, 1)) * random.uniform(0.55, 1.0)
            else:
                a = random.uniform(0, math.tau)
                d = random.uniform(0.0, crad * 0.45) if k else 0.0
            x, z = cx + math.cos(a) * d, cz + math.sin(a) * d
            s = _drop_to_ground(ground, x, z)
            if s is None:
                continue
            h = tall * (1.0 if k == 0 else random.uniform(0.20, 0.80))
            h = max(4.0, h)
            rb = h * random.uniform(0.28, 0.52)
            lean = random.uniform(0.0, 0.22) if random.random() < 0.6 else 0.0
            # Facet count AND plan aspect both vary, so no two stones share a
            # profile: 4-sided wedges next to 7-sided blocks, some slab-flat.
            _ice_mass(bm, (x, z, s - h * 0.10), rb, rb * random.uniform(0.48, 1.05),
                      h * 1.10, prof=_PROF_CRYSTAL,
                      sides=random.choice((4, 4, 5, 6, 7)),
                      yaw=a + random.uniform(-0.9, 0.9), tilt=(lean, 0.0),
                      jitter=random.uniform(0.05, 0.16), salt=800 + grown * 1.9)
            grown += 1
    print(f"[island_gen] ice crystals: {len(_ICE_CLUSTERS)} clusters, {grown} crystals")
    return object_from_bmesh("Frostmaw_Crystals", bm, ["M_IceCrystal"])


def build_ice_litter(ground):
    """SHARD LITTER - the signature ground texture. Hundreds of small flat
    broken floes lying on the ice: dense down the frozen channel, ringing every
    hole (with a course of blunt collar chunks), aprons under the crystal
    clusters, drifts at the foot of the cliff walls, and a thin scatter
    everywhere else. The spawn bubble stays swept clean."""
    bm = bmesh.new()
    n = 0

    def plate(x, z, lo, hi, salt, spawn_clear=12.0):
        """One piece of litter, and deliberately NOT always the same piece:
        mostly flat floe plates, but one in five is an angular tilted block
        of heaved ice and one in eight a small stratified shelf fragment."""
        nonlocal n
        if not _ice_open(x, z, pad=0.0, spawn_clear=spawn_clear):
            return
        surface = _drop_to_ground(ground, x, z)
        if surface is None:
            return
        w = random.uniform(lo, hi) * 1.25
        roll = random.random()
        if roll < 0.20:
            _ice_chunk(bm, (x, z, surface + w * random.uniform(0.05, 0.30)),
                       (w * random.uniform(0.6, 1.1), w * random.uniform(0.35, 0.8),
                        w * random.uniform(0.35, 0.9)),
                       yaw=salt, tilt=(random.uniform(-0.55, 0.55), random.uniform(-0.5, 0.5)))
        elif roll < 0.33:
            _ice_fragment(bm, x, z, surface, w * random.uniform(0.7, 1.1), salt)
        else:
            _ice_plate(bm, x, z, surface, w, salt)
        n += 1

    # Hole collars: a BROKEN FLOE RING - flat plates heaved up and tipped
    # against the rim, the way real ice breaks. No blunt boulders.
    for px, pz, pr in list(LAVA_PONDS):
        for i in range(random.randint(7, 11)):
            a = random.uniform(0, math.tau)
            d = pr + random.uniform(0.8, 2.8)
            x, z = px + math.cos(a) * d, pz + math.sin(a) * d
            s = _drop_to_ground(ground, x, z)
            if s is None:
                continue
            w = random.uniform(2.2, 5.0)
            ring = _ragged_ring(random.randint(5, 8), random.uniform(0.18, 0.34),
                                900 + i * 1.7 + px * 0.05)
            kk = math.sqrt(random.uniform(1.6, 3.0))
            _ice_slab(bm, ring, x, z, s - w * 0.25, w * random.uniform(0.16, 0.32),
                      w * kk, w / kk, yaw=a + math.pi / 2 + random.uniform(-0.4, 0.4),
                      top_scale=random.uniform(0.62, 1.05))
            n += 1
        for i in range(random.randint(6, 10)):
            a = random.uniform(0, math.tau)
            d = pr + random.uniform(2.5, 12.0)
            plate(px + math.cos(a) * d, pz + math.sin(a) * d, 1.2, 4.0, a * 3.0)

    # The frozen channel floor: dense broken floe litter, the reference's
    # walled-channel bed.
    for i in range(175):
        spot = _ice_channel_spot(0.58, 0.94, spread=1.0)
        if spot is None:
            break
        plate(spot[0], spot[1], 1.0, 4.6, i * 0.37)

    # Aprons under the crystal clusters.
    for ci, (cx, cz, crad) in enumerate(_ICE_CLUSTERS):
        for i in range(random.randint(9, 15)):
            a = random.uniform(0, math.tau)
            d = random.uniform(crad * 0.4, crad * 1.9)
            plate(cx + math.cos(a) * d, cz + math.sin(a) * d, 0.9, 3.4, ci * 1.3 + i * 0.29)

    # Drifts at the foot of the cliff walls, seen from the beaches.
    for i, (wx, wz) in enumerate(_ICE_WALL_FEET):
        if i % 3:
            continue
        for k in range(2):
            a = math.atan2(wz, wx)
            d = random.uniform(10.0, 30.0)
            plate(wx - math.cos(a) * d + random.uniform(-6, 6),
                  wz - math.sin(a) * d + random.uniform(-6, 6), 1.0, 3.8, i * 0.21 + k)

    # And a scatter over the whole sheet, right out to the shore, so no
    # ground is ever bare underfoot.
    for i in range(260):
        theta = random.uniform(0, math.tau)
        u = random.uniform(0.26, 0.97)
        r = ring_radius(u, theta)
        plate(math.cos(theta) * r, math.sin(theta) * r, 0.9, 4.2, i * 0.41)

    print(f"[island_gen] ice shard litter: {n} pieces")
    return object_from_bmesh("Frostmaw_ShardLitter", bm, ["M_IceShard"])


def _ice_pine(trunk_bm, snow_bm, lip_bm, x, z, surface, h, salt):
    """A snow-laden pine, deliberately UNSTABLE in silhouette: 3-6 skirt
    tiers, a build anywhere from narrow-and-tall to broad-and-squat, a slight
    lean, varying facet counts, and chunkier snow the bigger the tree. A
    stand has to read as many trees, not one tree stamped many times."""
    slim = random.uniform(0.19, 0.40)  # narrow-tall .19 <-> broad-squat .40
    r = h * slim
    # More tiers on taller trees keeps the spacing sane before overlap even
    # applies (3 tiers on a 50-stud giant put whole skirts of sky between).
    tiers = random.randint(4, 6) if h < 40.0 else random.randint(5, 7)
    lean = (random.uniform(-0.06, 0.06), random.uniform(-0.06, 0.06))
    trunk_r = h * random.uniform(0.045, 0.075)
    axis = cone_axis(lean, salt)
    base = Vector((x, z, surface))
    top_t = random.uniform(0.78, 0.90)
    lo_t = random.uniform(0.13, 0.22)
    # The trunk spans the WHOLE crown (buried tip just under the topmost
    # snow), not half the tree: a skirt tier must never float with sky
    # behind it (user, 2026-08-27: "parts connected... gaps or too far
    # apart").
    add_cone(trunk_bm, Vector((x, z, surface - 1.6)), trunk_r, trunk_r * 0.45,
             h * (top_t + 0.04) + 1.6, sides=5, tilt=lean, yaw=salt)
    # Big trees carry heavier snow: the skirts get deeper and whiter with h.
    heavy = smoothstep(18.0, 48.0, h)
    # Tier height comes FROM the tier spacing, so every cone overlaps the
    # base of the one above it by ~a third of the gap whatever tiers/h drew -
    # the stack always reads as one connected tree.
    gap = h * (top_t - lo_t) / max(tiers - 1, 1)
    for k in range(tiers):
        t = k / max(tiers - 1, 1)
        c = base + axis * (h * (lo_t + (top_t - lo_t) * t))
        rr = r * (1.0 - 0.68 * t) * random.uniform(0.88, 1.10)
        sh = gap * random.uniform(1.30, 1.55) * (1.0 + 0.18 * heavy) * (1.0 - 0.10 * t)
        sides = random.choice((6, 7, 8))
        add_cone(lip_bm, c - Vector((0.0, 0.0, sh * 0.18)), rr * 1.18, rr * 0.90,
                 sh * 0.38, sides=sides, tilt=lean, yaw=salt + k * 1.1)
        add_cone(snow_bm, c, rr, rr * random.uniform(0.20, 0.42), sh, sides=sides,
                 tilt=lean, yaw=salt + k * 0.7)
    # The tip cone roots INSIDE the top tier (not past it) so the crown caps
    # the stack instead of hovering above it.
    tip = base + axis * (h * (top_t - 0.03))
    add_cone(snow_bm, tip, r * random.uniform(0.26, 0.40), r * 0.05,
             h * random.uniform(0.16, 0.24), sides=6, tilt=lean, yaw=salt)


def _ice_dead_tree(bm, x, z, surface, h, salt):
    """A bare dead tree: a slim dark trunk with a few up-swept branches."""
    tilt = (random.uniform(-0.09, 0.09), random.uniform(-0.09, 0.09))
    yaw = salt
    base = Vector((x, z, surface - 1.0))
    add_cone(bm, base, h * 0.075, h * 0.022, h, sides=5, tilt=tilt, yaw=yaw)
    axis = cone_axis(tilt, yaw)
    for k in range(random.randint(2, 4)):
        joint = base + axis * (h * random.uniform(0.42, 0.86))
        add_cone(bm, joint, h * 0.030, h * 0.008, h * random.uniform(0.20, 0.36), sides=4,
                 tilt=(random.uniform(0.55, 0.95), 0.0), yaw=salt * 1.7 + k * 2.2)


def build_ice_trees(ground):
    """Loose stands of snowy pines on the terraces, plus bare dead trees
    scattered between them - the winter-kit silhouettes from the reference."""
    trunk_bm, snow_bm, lip_bm = bmesh.new(), bmesh.new(), bmesh.new()
    pines = 0
    stands = 0
    giants = 0
    PINE_CAP = 82

    def pine_at(x, z, h):
        nonlocal pines, giants
        surface = _drop_to_ground(ground, x, z)
        if surface is None:
            return
        _ice_pine(trunk_bm, snow_bm, lip_bm, x, z, surface, h, salt=pines * 0.83)
        pines += 1
        if h >= 45.0:
            giants += 1

    # Dense STANDS across every terrace band. Each stand carries one tall
    # leader and a spread of smaller trees around it, and roughly every third
    # stand's leader is a 45-55 stud giant.
    for _ in range(2600):
        if pines >= PINE_CAP or stands >= 24:
            break
        theta = random.uniform(0, math.tau)
        u = random.uniform(0.22, 0.90)
        r = ring_radius(u, theta)
        sx, sz = math.cos(theta) * r, math.sin(theta) * r
        if not _ice_open(sx, sz, pad=8.0, spawn_clear=26.0) or not _ice_free(sx, sz, 9.0):
            continue
        _ice_claim(sx, sz, 8.5)
        stands += 1
        leader = (random.uniform(45.0, 55.0) if (stands % 3 == 1 and giants < 11)
                  else random.uniform(26.0, 40.0))
        pine_at(sx, sz, leader)
        spread = 8.0 + leader * 0.30
        for _ in range(random.randint(3, 6)):
            if pines >= PINE_CAP:
                break
            a = random.uniform(0, math.tau)
            d = random.uniform(3.5, spread)
            pine_at(sx + math.cos(a) * d, sz + math.sin(a) * d,
                    random.uniform(15.0, 34.0))

    # Scattered LONERS on the open sheet between the stands, so the forest
    # thins out rather than stopping at a stand's edge.
    for _ in range(900):
        if pines >= PINE_CAP:
            break
        theta = random.uniform(0, math.tau)
        u = random.uniform(0.20, 0.93)
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        if not _ice_open(x, z, pad=5.0, spawn_clear=24.0) or not _ice_free(x, z, 6.0):
            continue
        _ice_claim(x, z, 5.0)
        h = random.uniform(46.0, 55.0) if giants < 11 else random.uniform(17.0, 38.0)
        pine_at(x, z, h)

    dead = 0
    for _ in range(700):
        if dead >= 15:
            break
        theta = random.uniform(0, math.tau)
        u = random.uniform(0.34, 0.92)
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        if not _ice_open(x, z, pad=5.0, spawn_clear=20.0) or not _ice_free(x, z, 7.0):
            continue
        surface = _drop_to_ground(ground, x, z)
        if surface is None:
            continue
        _ice_claim(x, z, 5.0)
        _ice_dead_tree(trunk_bm, x, z, surface, random.uniform(13.0, 23.0), salt=dead * 1.31)
        dead += 1
    print(f"[island_gen] frostmaw trees: {pines} snowy pines in {stands} stands "
          f"({giants} giants 45-55 studs), {dead} dead trees")
    return (
        object_from_bmesh("Frostmaw_PineSnow", snow_bm, ["M_PineSnow"]),
        object_from_bmesh("Frostmaw_Pines", lip_bm, ["M_PineNeedle"]),
        object_from_bmesh("Frostmaw_DeadTrees", trunk_bm, ["M_FrostWood"]),
    )


def build_ice_mounds(ground):
    """SNOW DRIFTS - wind-piled, elongated, lopsided. Two or three overlapping
    lobes each, every lobe its own ragged 5-9 sided plan on its own axis and
    wedging down to a thin lip. They are the softest silhouette on the island
    and share it with nothing else."""
    bm = bmesh.new()
    made = 0
    for i in range(360):
        if made >= 108:
            break
        theta = random.uniform(0, math.tau)
        u = random.uniform(0.12, 0.94)
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        w = random.uniform(2.8, 10.5)
        if not _ice_open(x, z, pad=w + 1.0, spawn_clear=13.0):
            continue
        surface = _drop_to_ground(ground, x, z)
        if surface is None:
            continue
        _ice_drift(bm, x, z, surface, w, salt=1200 + i * 1.7)
        made += 1
    print(f"[island_gen] snow drifts: {made}")
    return object_from_bmesh("Frostmaw_SnowMounds", bm, ["M_SnowMound"])


# ---- Halvard's upturned hull (the Reach's one dwelling) -------------------
#
# Halvard's old fishing boat, hauled up the beach, flipped KEEL-UP and half
# buried in a drift: the hull IS the roof. You walk in through the square-cut
# transom at the stern; the bow noses down into the snow at the far end and a
# stovepipe climbs out through a split in the keel. Everything else on the
# island is a blunt mass of ice, so the ONE piece of curved carpentry on
# Frostmaw is legible from a long way off - which is the point of siting it in
# the open bay 12 deg off the dock lane, in full view of the planks.
#
# Five layers, one material each (the one-material-per-object rule):
#   Frostmaw_Hut_Roof   hull shell, keel, rubbing strakes, transom planking
#   Frostmaw_Hut_Walls  snow-block knee walls, floor pad, windbreak, drifts
#   Frostmaw_Hut_Props  stove, stovepipe, bunk, shelf, fish rack, snowshoes,
#                       harpoons, crates
#   Frostmaw_Hut_Trim   frozen fish, whale bone, the rime pelt rug and bedroll
#   Frostmaw_Hut_Glow   the pot-bellied stove's firebox and ember pool (Neon)
#
# Walk-in contract: a 5.4 x 7.6 doorway in the transom, a clear floor ~15 x 19
# under a vault 9.7-11.3 studs high over the whole middle of the boat, and a
# 1.05-stud plank shell (PreciseConvexDecomposition on import).

_HUT_H_BEARING = math.radians(282.0)  # 12 deg off the dock lane, in the open bay
# The hull's CENTRE. The boat lies ALONG the contour, not down it: the flat
# band the PROFILE holds between the third terrace riser (u 0.685, r 151) and
# the shore ramp (u 0.86, r 180) is only 29 studs wide, and a 28-stud boat
# pointed inland spans the whole of it plus the 4-stud riser at one end (the
# first draft did exactly that and stood the stern 1.6 studs off the ground).
# Broadside on, only the 17-stud beam crosses the fall - under a stud of it.
_HUT_H_U = 0.795
_HUT_H_KEEP = []  # (x, y, radius) - the swept yard, honoured by _ice_open

# The boat in its own frame: +x runs stern -> bow, +y to port, z off the floor.
_HUT_H_BEAM = 17.4
_HUT_H_SHELL = 1.05  # plank thickness of the shell
_HUT_H_DOOR_W = 5.4
_HUT_H_DOOR_H = 7.6
_HUT_H_STATIONS = (-13.0, -11.0, -8.0, -4.5, -1.0, 2.0, 5.0, 7.5, 9.5, 11.5, 13.2, 15.0)
# Half-beam (x BEAM/2), keel-ridge height and gunwale (now eaves) height along
# the boat. Three boat lines do the reading here: the beam CARRIES aft and
# then draws in hard over the last third to a fine bow; the keel has ROCKER
# (highest amidships, falling away at both ends); and the gunwale has SHEER
# (lowest amidships, sweeping up at stern and bow). Take any one of them out
# and the silhouette collapses into a Nissen hut.
_HUT_H_HALFBEAM = ((-13.0, 0.84), (-11.0, 0.97), (-4.0, 1.00), (2.0, 0.97),
                   (6.0, 0.88), (9.5, 0.72), (12.5, 0.46), (15.0, 0.13))
_HUT_H_KEELLINE = ((-13.0, 10.8), (-11.0, 11.9), (-2.0, 12.4), (5.0, 12.0),
                   (9.0, 10.2), (12.5, 6.8), (15.0, 4.4))
_HUT_H_GUNLINE = ((-13.0, 5.7), (-10.0, 5.0), (-2.0, 4.6), (4.0, 4.8),
                  (8.0, 5.2), (11.5, 5.0), (15.0, 3.8))
_HUT_H_SPLIT = (4.6, 7.2)  # the gap in the keel the stovepipe comes through


def _hut_lerp(x, table):
    """Piecewise-linear read of an (x, value) table, clamped at both ends."""
    if x <= table[0][0]:
        return table[0][1]
    for i in range(len(table) - 1):
        x0, v0 = table[i]
        x1, v1 = table[i + 1]
        if x <= x1:
            return v0 + (v1 - v0) * ((x - x0) / (x1 - x0))
    return table[-1][1]


def _hut_h_site():
    """(centre x, centre y, yaw) of the hull. Yaw lays the boat's +x axis
    along the CONTOUR (see _HUT_H_U), pointing away from the dock lane - so
    the transom, and therefore the door, looks back along the beach at the
    spawn and the planks, and the boat's +y is inland."""
    r = ring_radius(_HUT_H_U, _HUT_H_BEARING)
    return math.cos(_HUT_H_BEARING) * r, math.sin(_HUT_H_BEARING) * r, _HUT_H_BEARING + math.pi / 2


def _hut_h_pt(site, x, y, z):
    cx, cy, yaw = site
    ca, sa = math.cos(yaw), math.sin(yaw)
    return (cx + x * ca - y * sa, cy + x * sa + y * ca, z)


def _hut_h_box(bm, site, x, y, z, size, spin=0.0):
    add_box(bm, _hut_h_pt(site, x, y, z), size, yaw=site[2] + spin)


def _hut_h_cone(bm, site, x, y, z, r0, r1, h, sides=6, tilt=(0.0, 0.0), spin=0.0):
    add_cone(bm, _hut_h_pt(site, x, y, z), r0, r1, h, sides=sides, tilt=tilt, yaw=site[2] + spin)


def _hut_h_section(x, s, inner=False):
    """One point of the boat's cross-section at local `x`, `s` in [-1, 1]
    across the beam. The section is the hull's own: full and round amidships,
    the bilge rolling up to the gunwale. Flipped, `s=0` is the ridge."""
    hb = _hut_lerp(x, _HUT_H_HALFBEAM) * (_HUT_H_BEAM * 0.5)
    keel = _hut_lerp(x, _HUT_H_KEELLINE)
    gun = _hut_lerp(x, _HUT_H_GUNLINE)
    if inner:
        hb = max(hb - _HUT_H_SHELL, 0.06)
        keel = max(keel - _HUT_H_SHELL, gun + 0.12)
    return s * hb, gun + (keel - gun) * (1.0 - abs(s) ** 1.8)


def _hut_h_hull(bm, site, z0, lat=9):
    """The upturned boat as ONE closed shell: an outer skin, an inner skin
    (so the inside of the roof is real planking, not a backface), the two
    gunwale edges closed across the plank thickness, and a cap ring at the
    transom and at the buried bow. Solid, so the import can decompose it."""
    outer, inner = [], []
    for x in _HUT_H_STATIONS:
        o, i = [], []
        for j in range(lat):
            s = -1.0 + 2.0 * j / (lat - 1)
            oy, oz = _hut_h_section(x, s, inner=False)
            iy, iz = _hut_h_section(x, s, inner=True)
            o.append(bm.verts.new(Vector(_hut_h_pt(site, x, oy, z0 + oz))))
            i.append(bm.verts.new(Vector(_hut_h_pt(site, x, iy, z0 + iz))))
        outer.append(o)
        inner.append(i)
    n = len(_HUT_H_STATIONS)
    for k in range(n - 1):
        for j in range(lat - 1):
            bm.faces.new((outer[k][j], outer[k][j + 1], outer[k + 1][j + 1], outer[k + 1][j]))
            bm.faces.new((inner[k + 1][j], inner[k + 1][j + 1], inner[k][j + 1], inner[k][j]))
        # The two gunwale edges: the plank thickness, showing as the eaves.
        bm.faces.new((outer[k][0], outer[k + 1][0], inner[k + 1][0], inner[k][0]))
        bm.faces.new((inner[k][lat - 1], inner[k + 1][lat - 1], outer[k + 1][lat - 1], outer[k][lat - 1]))
    for j in range(lat - 1):  # transom ring and bow ring
        bm.faces.new((outer[0][j], inner[0][j], inner[0][j + 1], outer[0][j + 1]))
        bm.faces.new((outer[n - 1][j + 1], inner[n - 1][j + 1], inner[n - 1][j], outer[n - 1][j]))


def _hut_h_transom(bm, site, z0):
    """The square-cut stern, planked vertically, with the DOORWAY cut through
    it: 5.4 wide, 7.6 to the lintel, and the planking carried on over the top
    so the opening reads as a door and not a missing wall."""
    x = _HUT_H_STATIONS[0] + 0.55
    hb = _hut_lerp(x, _HUT_H_HALFBEAM) * (_HUT_H_BEAM * 0.5) - 0.25
    half = _HUT_H_DOOR_W * 0.5
    w = 1.12
    n = int((hb * 2.0) / w)
    for k in range(n):
        y = -hb + w * (k + 0.5)
        top = _hut_h_section(x, max(-1.0, min(1.0, y / hb)))[1]
        lo = z0 + (_HUT_H_DOOR_H if abs(y) < half + 0.35 else 0.0)
        hi = z0 + top - 0.40  # kept inside the skin's curve, so no plank corner pokes out
        if hi - lo < 0.4:
            continue
        # Planks OVERLAP their neighbours (1.06 x the pitch): the strip over
        # the door has to hang off the full-height planks either side of it,
        # not float in the opening.
        _hut_h_box(bm, site, x, y, (lo + hi) * 0.5, (1.05, w * 1.06, hi - lo))
    # Door frame: two jambs and a lintel, in heavier stock.
    for side in (-1.0, 1.0):
        _hut_h_box(bm, site, x - 0.4, side * (half + 0.45), z0 + _HUT_H_DOOR_H * 0.5,
                   (0.7, 0.9, _HUT_H_DOOR_H))
    _hut_h_box(bm, site, x - 0.4, 0.0, z0 + _HUT_H_DOOR_H + 0.45,
               (0.7, _HUT_H_DOOR_W + 1.8, 0.9))


def _hut_h_strake(bm, site, z0, s_a, s_b, x0, x1, n, lift, thick):
    """One plank line swept along the hull between two points of the section
    (`s_a` outboard of `s_b`), riding `lift` proud of the skin and extruded
    `thick` down INTO it - continuous from stern to bow, and welded to the
    planking for its whole run."""
    left, right = [], []
    for k in range(n):
        x = x0 + (x1 - x0) * k / (n - 1)
        ya, za = _hut_h_section(x, s_a)
        yb, zb = _hut_h_section(x, s_b)
        left.append(Vector(_hut_h_pt(site, x, ya, z0 + za + lift)))
        right.append(Vector(_hut_h_pt(site, x, yb, z0 + zb + lift)))
    add_strip_slab(bm, left, right, thick)


def _hut_h_timbers(bm, site, z0):
    """The keel beam along the ridge (broken open at the split the stovepipe
    uses) and the rubbing strakes running the length of both flanks - the two
    details that make a grey hump read as a BOAT."""
    # The keel, and the strakes, are SWEPT RIBBONS, not runs of boxes: a box
    # laid on a curved ridge lifts off it at one end, and a row of them reads
    # as a staircase. Each ribbon's underside is buried in the planking it
    # rides on, so keel and strakes are welded to the hull along their whole
    # length.
    for x0, x1 in ((-12.4, _HUT_H_SPLIT[0]), (_HUT_H_SPLIT[1], 13.4)):
        left, right = [], []
        n = max(3, int((x1 - x0) / 1.9))
        for k in range(n):
            x = x0 + (x1 - x0) * k / (n - 1)
            z = z0 + _hut_lerp(x, _HUT_H_KEELLINE) + 0.45
            left.append(Vector(_hut_h_pt(site, x, -0.9, z)))
            right.append(Vector(_hut_h_pt(site, x, 0.9, z)))
        add_strip_slab(bm, left, right, 1.6)
    for s in (-1.0, 1.0):
        _hut_h_strake(bm, site, z0, s * 1.10, s * 0.86, -12.6, 13.0, 9, 0.15, 1.1)
        _hut_h_strake(bm, site, z0, s * 0.70, s * 0.48, -12.4, 12.0, 8, 0.16, 0.9)
    # The STEM: the boat's prow, raking up out of the drift that swallows the
    # bow. Its foot is 2 studs inside the bank, so it is planted, not perched.
    add_cone(bm, _hut_h_pt(site, 12.0, 0.0, z0 + 2.4), 0.90, 0.34, 10.4, sides=5,
             tilt=(0.0, 0.62), yaw=site[2])


def _hut_h_bank(bm, site, x, y, gz, rr, hgt, salt):
    """A wind-piled SNOW BANK against the hut, in Frostmaw's own drift
    language (overlapping ragged lobes wedging to a thin lip). `gz` is a
    callable giving the real ground under a hull-local point: every lobe is
    drawn from 0.7 studs BELOW ITS OWN ground upward, so no lobe can hang in
    the air the way a height-anchored drift can."""
    for k in range(3):
        f = 1.0 if k == 0 else 0.78 - 0.22 * k
        a = salt * 0.7 + k * 2.1
        d = 0.0 if k == 0 else rr * (0.35 + 0.16 * k)
        lx, ly = x + math.cos(a) * d, y + math.sin(a) * d
        ring = _ragged_ring(7 + k, 0.24, salt + k * 3.7)
        kk = math.sqrt(1.5 + 0.4 * k)
        _ice_slab(bm, ring, *_hut_h_pt(site, lx, ly, 0.0)[:2],
                  gz(lx, ly) - 0.7, hgt * f + 0.7, rr * f * kk, rr * f / kk,
                  yaw=site[2] + a, top_scale=0.46 + 0.1 * k)


def build_ice_hut(ground):
    """HALVARD'S UPTURNED HULL. Deterministic on its own Random(4271) so the
    rest of Frostmaw's shared stream is untouched."""
    rng = random.Random(4271)
    # _ice_drift draws on the SHARED stream; hand it back exactly as found so
    # the hut can be added without moving one plate of anyone else's litter.
    shared_state = random.getstate()
    site = _hut_h_site()
    cx, cy, yaw = site
    timber, snow, props, trim, glow = (bmesh.new() for _ in range(5))

    def gz(x, y):
        """The REAL sheet height under a hull-local point - what every yard
        prop is seated on. Nothing in this builder is placed at an offset from
        a nominal height; the ground is asked, every time."""
        p = _hut_h_pt(site, x, y, 0.0)
        g = _drop_to_ground(ground, p[0], p[1])
        return g if g is not None else height_at(p[0], p[1])

    # The cabin floor is LEVEL, and level at the HIGHEST ground under the
    # hull, so the sheet can never heave up through the boards; the pad's
    # 3.2-stud skirt swallows the fall to the low corner, and a two-step
    # threshold outside carries the ~0.6-stud sill down to the snow.
    z0 = max(gz(x, y) for x in (-13.0, -6.0, 0.0, 7.0, 14.0)
             for y in (-8.5, -4.0, 0.0, 4.0, 8.5)) + 0.08

    # --- the boat -----------------------------------------------------------
    _hut_h_hull(timber, site, z0)
    _hut_h_transom(timber, site, z0)
    _hut_h_timbers(timber, site, z0)

    # --- floor pad + snow-block knee walls ----------------------------------
    pad = []
    for k in range(14):
        a = (k / 14) * math.tau
        pad.append(_hut_h_pt(site, 1.0 + math.cos(a) * 17.5, math.sin(a) * 10.5, 0.0)[:2])
    add_disc_slab(snow, pad, z0 + 0.06, 3.2)
    # Knee walls: every course starts 1.6 studs UNDER the pad and the top one
    # runs 0.35 past the gunwale, so the hull is seated on the blocks and the
    # blocks are seated in the ground - no hairline joints anywhere in the
    # load path.
    for s in (-1.0, 1.0):
        for k in range(9):
            m = -12.4 + k * 3.25
            y, _z = _hut_h_section(m, s)
            gun = _hut_lerp(m, _HUT_H_GUNLINE)
            h = (gun + 1.95) * 0.5
            for c in range(2):
                _hut_h_box(snow, site, m + rng.uniform(-0.2, 0.2), y - s * 0.10,
                           z0 - 1.6 + h * (c + 0.5), (3.6, 2.1, h * 1.06),
                           spin=rng.uniform(-0.05, 0.05))
    # The bow half-buried: wind drifts banked over the nose of the boat. Every
    # lobe is drawn from BELOW the ground up, never hung at a height (the
    # levitating-prop rule) - which is also why _ice_drift isn't used here.
    # Banked OUTSIDE the enclosed volume (a slab is full height right out to
    # its plan edge, so a drift centred over the cabin would fill the room
    # with a white boulder) - they bury the bow's last five studs and pile
    # against the knee walls, which is what "half-buried" has to mean here.
    _hut_h_bank(snow, site, 17.0, 0.0, gz, 5.8, 7.0, 71.0)
    _hut_h_bank(snow, site, 5.0, -14.0, gz, 5.2, 4.6, 88.0)
    _hut_h_bank(snow, site, 4.0, 14.2, gz, 5.0, 4.2, 96.0)
    # The ice-block WINDBREAK: an L thrown up across the wind, off the door's
    # port bow so the walk in stays open. Blocks overlap their neighbours in
    # both directions and every bottom course is sunk into ITS OWN ground.
    for k in range(5):
        wx, wy = -17.6 + rng.uniform(-0.2, 0.2), 3.6 + k * 2.55
        for c in range(3):
            _hut_h_box(snow, site, wx, wy, gz(wx, wy) - 0.5 + 1.55 * (c + 0.5),
                       (2.4, 2.75, 1.7), spin=rng.uniform(-0.06, 0.06))
    for k in range(3):
        wx, wy = -15.7 + k * 2.6, 15.0
        for c in range(2):
            _hut_h_box(snow, site, wx, wy, gz(wx, wy) - 0.5 + 1.55 * (c + 0.5),
                       (2.8, 2.4, 1.7), spin=rng.uniform(-0.06, 0.06))
    # Two threshold steps down off the sill, each seated on the sheet.
    _hut_h_box(snow, site, -14.6, 0.0, z0 - 0.45, (2.6, 7.4, 1.0))
    _hut_h_box(snow, site, -16.6, 0.0, (gz(-16.6, 0.0) + z0) * 0.5 - 0.75, (2.4, 6.6, 1.6))

    # --- interior -----------------------------------------------------------
    # The pot-bellied stove, off to starboard under the keel's split.
    _hut_h_cone(props, site, 5.4, -4.0, z0, 1.5, 1.9, 1.2, sides=8)
    _hut_h_cone(props, site, 5.4, -4.0, z0 + 1.2, 2.1, 1.5, 2.8, sides=8)
    _hut_h_cone(props, site, 5.4, -4.0, z0 + 4.0, 1.4, 1.2, 0.5, sides=8)
    # The flue: stove collar -> a leaning elbow whose head lands INSIDE the
    # riser -> the riser, which passes bodily through the split in the keel
    # (base well below the planking, cap well above it). Every joint overlaps.
    _hut_h_cone(props, site, 5.4, -4.0, z0 + 4.4, 0.62, 0.58, 1.4, sides=6)
    _hut_h_cone(props, site, 5.4, -3.9, z0 + 5.2, 0.56, 0.52, 4.6, sides=6,
                tilt=(-0.72, 0.0))  # the elbow, leaning in under the split
    _keel_z = _hut_lerp(5.7, _HUT_H_KEELLINE)
    _hut_h_cone(props, site, 5.7, -0.6, z0 + 8.3, 0.54, 0.48, _keel_z + 5.0 - 8.3, sides=6)
    _hut_h_cone(props, site, 5.7, -0.6, z0 + _keel_z + 4.6, 1.0, 0.7, 0.7, sides=6)  # rain cap
    # Firebox, the hot cooktop, and the light both throw on the deck boards
    # and out through the open door onto the snow. Each glow piece is sunk
    # into the iron or the boards it belongs to.
    _hut_h_cone(glow, site, 3.25, -4.0, z0 + 1.85, 0.92, 0.92, 0.5, sides=8,
                tilt=(0.0, math.pi / 2))  # the open firebox, facing the door
    _hut_h_cone(glow, site, 5.4, -4.0, z0 + 0.02, 1.25, 1.05, 0.35, sides=8)  # the ash pan
    _hut_h_cone(glow, site, 5.4, -4.0, z0 + 3.85, 1.45, 1.30, 0.35, sides=8)  # the cooktop
    # Firelight pooling on the deck boards, and out through the door onto the
    # snow. Low DOMES, not pancakes: a flat disc on the floor disappears at
    # eye height, which is exactly the angle the hut is read from.
    _hut_h_cone(glow, site, 2.6, -3.4, z0 + 0.02, 2.7, 1.5, 0.38, sides=9)
    _hut_h_cone(glow, site, -4.6, -1.4, z0 + 0.02, 2.9, 1.6, 0.34, sides=9)
    _hut_h_cone(glow, site, -15.0, 0.0, z0 - 0.85, 2.4, 1.4, 0.40, sides=8)  # on the top step
    _hut_h_cone(glow, site, 5.7, -0.6, z0 + _keel_z + 4.9, 0.42, 0.42, 0.35, sides=6)  # lit throat

    # The bunk, built into the curve of the hull along the starboard side.
    for k in range(3):
        _hut_h_box(props, site, -9.4 + k * 3.0, -5.6, z0 + 0.9, (0.8, 0.8, 1.8))
    _hut_h_box(props, site, -6.6, -6.0, z0 + 1.9, (7.6, 3.4, 0.45))
    _hut_h_box(props, site, -10.6, -6.0, z0 + 2.6, (0.7, 3.4, 1.8))
    _hut_h_cone(trim, site, -8.8, -6.0, z0 + 2.15, 1.30, 1.05, 3.4, sides=6,
                tilt=(0.0, math.pi / 2))  # the bedroll, lying fore-and-aft
    # The rime-pelt rug on the boards.
    _ice_slab(trim, _ragged_ring(9, 0.22, 17.0), *_hut_h_pt(site, -6.0, 0.6, 0.0)[:2],
              z0 + 0.07, 0.16, 4.6, 3.4, yaw=yaw)
    # The whale-bone trinket shelf on the port side: two rib knees wedged
    # between the snow-block wall (which starts at y 7.6) and the underside of
    # the plank, the plank itself buried 0.15 into that wall, and the small
    # bones and scrimshaw standing ON it.
    _hut_h_box(props, site, -6.0, 6.9, z0 + 4.5, (6.4, 1.7, 0.35))
    for k in (-1.0, 1.0):
        _hut_h_box(trim, site, -6.0 + k * 2.4, 7.05, z0 + 3.95, (0.5, 1.4, 1.2))
    for k in range(4):
        _hut_h_cone(trim, site, -8.4 + k * 1.7, 6.8, z0 + 4.6,
                    rng.uniform(0.24, 0.42), rng.uniform(0.10, 0.26),
                    rng.uniform(0.8, 1.7), sides=5, spin=rng.uniform(0, 1.0))
    # Crates and a sack of bait forward of the door - the top crate sits
    # squarely on the bottom one, not hovering over its corner.
    _hut_h_box(props, site, 0.5, 6.2, z0 + 0.9, (2.4, 2.2, 1.8))
    _hut_h_box(props, site, 0.9, 4.0, z0 + 0.7, (1.9, 1.8, 1.4), spin=0.4)
    _hut_h_box(props, site, 0.7, 6.4, z0 + 2.5, (1.8, 1.7, 1.4), spin=-0.3)
    _hut_h_cone(props, site, 3.0, -6.5, z0, 0.9, 0.7, 1.5, sides=6)  # the stool

    # --- the yard -----------------------------------------------------------
    # A rack of fish frozen stiff, standing on end like planks: the two posts
    # are driven 0.7 into the sheet, the rail is threaded onto both posts, and
    # every fish stands ON the ground with its body passing THROUGH the rail.
    rack_z = min(gz(-16.4, -13.5), gz(-16.4, -7.1))
    for k in (-1.0, 1.0):
        _hut_h_cone(props, site, -16.4, -10.3 + k * 3.2, rack_z - 0.7, 0.45, 0.34, 5.7, sides=5)
    _hut_h_box(props, site, -16.4, -10.3, rack_z + 4.5, (0.55, 7.4, 0.6))
    for k in range(8):
        y = -13.55 + k * 0.93
        _hut_h_cone(trim, site, -16.35 + rng.uniform(-0.10, 0.10), y, gz(-16.35, y) - 0.45,
                    rng.uniform(0.55, 0.78), 0.20, rng.uniform(5.4, 6.1), sides=4,
                    tilt=(rng.uniform(0.10, 0.20), rng.uniform(-0.08, 0.08)),
                    spin=rng.uniform(-0.2, 0.2))
    # Snowshoes nailed to the transom: the disc's inboard face is buried in
    # the planking and the peg runs right through both.
    for k in (-1.0, 1.0):
        _hut_h_cone(trim, site, -13.35, k * 4.4, z0 + 5.0, 1.45, 1.00, 0.5, sides=7,
                    tilt=(0.0, math.pi / 2), spin=0.18 * k)  # the rawhide webbing
        _hut_h_cone(props, site, -13.6, k * 4.4, z0 + 5.0, 0.16, 0.16, 1.2, sides=4,
                    tilt=(0.0, math.pi / 2), spin=0.18 * k)  # the peg it hangs on
    # Harpoons PLANTED in the drift beside the door - butts 1.6 studs below
    # the sheet, every shaft inside the bank's footprint.
    _hut_h_bank(snow, site, -19.4, -6.2, gz, 4.4, 2.4, 131.0)
    for hx, hy in ((-19.8, -5.0), (-18.6, -6.8), (-20.6, -7.2), (-18.1, -4.7)):
        _hut_h_cone(props, site, hx, hy, gz(hx, hy) - 1.6, 0.24, 0.08, rng.uniform(7.6, 9.4),
                    sides=5, tilt=(rng.uniform(0.18, 0.32), rng.uniform(-0.20, 0.20)),
                    spin=rng.uniform(0, math.tau))
    random.setstate(shared_state)

    door = _hut_h_pt(site, _HUT_H_STATIONS[0] - 1.2, 0.0, 0.0)
    stand = _hut_h_pt(site, _HUT_H_STATIONS[0] - 4.6, 0.0, 0.0)
    sx, sy = _ice_spawn_xy()
    # He stands off the threshold looking straight OUT of his door (-x in the
    # hull frame). Roblox reads `facing` as CFrame.Angles(0, rad, 0), whose
    # look vector is (-sin, -cos), hence the atan2 form.
    dx, dz = -math.cos(site[2]), math.sin(site[2])  # Roblox X/Z of the door's outward normal
    facing = math.degrees(math.atan2(-dx, -dz)) % 360.0
    print(
        f"[island_gen] HANDOFF frostmaw hut: Halvard's upturned hull, door (Roblox rel) "
        f"X={door[0]:.0f} Z={-door[1]:.0f} sill Y~{z0:.1f}; suggested halvard spawnOffset "
        f"Vector3.new({stand[0] - sx:.0f}, 0, {-stand[1] + sy:.0f}) "
        f"facing {facing:.0f} (island spawn is X=0 Z={-sy:.0f}, hull centre "
        f"X={cx:.0f} Z={-cy:.0f})"
    )
    return (
        object_from_bmesh("Frostmaw_Hut_Roof", timber, ["M_HutHull"]),
        object_from_bmesh("Frostmaw_Hut_Walls", snow, ["M_HutSnowBlock"]),
        object_from_bmesh("Frostmaw_Hut_Props", props, ["M_FrostIron"]),
        object_from_bmesh("Frostmaw_Hut_Trim", trim, ["M_HutBone"]),
        object_from_bmesh("Frostmaw_Hut_Glow", glow, ["M_FrostEmber"]),
    )


def build_frostmaw():
    base = build_island_base("Frostmaw_Base", ["M_Snow", "M_IceSheet", "M_IceWet"])
    ground = _ground_bvh(base)
    _ICE_SNOW["bm"] = None
    # Halvard's yard is claimed BEFORE any scatter runs (the hut itself is
    # built last, off its own RNG, so the shared stream is unmoved) - holes,
    # drifts, pines and litter all read this through _ice_open.
    _HUT_H_KEEP.clear()
    _HUT_H_KEEP.append((*_hut_h_site()[:2], 25.0))
    objects = [
        base,
        build_ice_holes(ground),  # first: records the keep-clear circles
        build_ice_berg(ground),
        build_ice_arch(ground),
        build_ice_walls(ground),
        build_ice_terraces(ground),
        build_ice_crystals(ground),
        *build_ice_trees(ground),
        build_ice_mounds(ground),
        build_ice_litter(ground),  # last: fills in around everything placed
        *build_ice_hut(ground),  # Halvard's upturned hull, in its swept yard
        *build_dock("Frostmaw_Dock_Planks", "Frostmaw_Dock_Posts", "M_FrostPlank", "M_FrostPost"),
        build_foam("Frostmaw_Foam", "M_FrostFoam"),
    ]
    # Every SNOW stratum the berg, walls, mesas and arches laid down, emitted
    # as the one snow object (one material per object).
    snow = _ICE_SNOW["bm"]
    _ICE_SNOW["bm"] = None
    if snow is not None:
        objects.append(object_from_bmesh("Frostmaw_SnowCaps", snow, ["M_SnowCap"]))
    a = math.radians(DOCK_ANGLE_DEG)
    start_r = ring_radius(DOCK_START_U, a)
    print(f"[island_gen] HANDOFF frostmaw: dock start (Roblox rel) X=0 Z={start_r:.0f}, spawn suggestion X=0 Z={start_r - 18:.0f} ground Y~{height_at(0, -(start_r - 18)):.1f}")
    return objects


# ---- Gloomtrench ----------------------------------------------------------
#
# The trench shelf is an AMPHITHEATRE OF DARKNESS. A craggy crown ring stands
# out of the sea; inside it the rock TERRACES DOWN, step by step, to one
# lightless lake at the bottom. The player lands at the dock, crosses the
# apron, walks through a gate in the crown flanked by monoliths, and looks
# down into the pit - where every scrap of light in the composition lives:
# groves of giant glowing mushrooms, anemone beds at the waterline, crystal
# clusters on the risers, and glowing veins tracing the terrace lips so the
# routes read even with the lantern out. Everything below is self-contained to
# this island (shared helpers untouched).

GLOOM_PATH = []  # centre line (Blender x, y) of the lit route, for keep-clear
GLOOM_LAKE_R = 46.0  # nominal radius of the dark lake in the pit
GLOOM_TERRACE_LIPS = (0.325, 0.415, 0.495)  # u of each riser top - the lit contours
GLOOM_VINE_ANCHORS = []  # (x, y, z, drop) high points the glow-vines hang from
GLOOM_RIFT_DEG = 104.0  # bearing of the rift off the dock, far from the route
GLOOM_RIFT_KEEP = []  # (x, y, r) rift footprint - other props steer around it


def _gloom_path_points():
    """The walked route: in from the dock landing, across the apron, through
    the gate in the crown, down the terraces, then a promenade around the
    lake."""
    a = math.radians(DOCK_ANGLE_DEG)
    ca, sa = math.cos(a), math.sin(a)
    pts = []
    u = 0.90
    while u > 0.275:
        r = ring_radius(u, a)
        sway = 12.0 * math.sin((0.92 - u) * 7.0)  # a lazy S so it isn't a spoke
        pts.append((ca * r - sa * sway, sa * r + ca * sway))
        u -= 0.013
    lx, ly = pts[-1]
    r0 = math.hypot(lx, ly)
    a0 = math.atan2(ly, lx)
    for k in range(1, 19):  # lakeside promenade
        ang = a0 + k * 0.125
        pts.append((math.cos(ang) * r0, math.sin(ang) * r0))
    return pts


def _gloom_off_path(x, y, clear=12.0):
    """True if (x, y) is far enough off the walked route to drop a prop."""
    c2 = clear * clear
    return all((x - px) ** 2 + (y - py) ** 2 > c2 for px, py in GLOOM_PATH)


def _gloom_off_rift(x, y, pad=6.0):
    """True if (x, y) is clear of the rift's footprint - nothing else may be
    dropped into the chasm."""
    return all((x - rx) ** 2 + (y - ry) ** 2 > (rr + pad) ** 2 for rx, ry, rr in GLOOM_RIFT_KEEP)


def _gloom_spot(ground, u_lo, u_hi, pad=3.0, clear=12.0, tries=24):
    """_interior_spot, additionally kept off the lit route."""
    for _ in range(tries):
        spot = _interior_spot(ground, u_lo, u_hi, pad=pad, tries=3)
        if spot is None:
            continue
        if _gloom_off_path(spot[0], spot[1], clear) and _gloom_off_rift(spot[0], spot[1]):
            return spot
    return None


def build_gloom_water(ground):
    """The lightless lake at the floor of the amphitheatre - the island's
    fishable water (waters="gloom"). ONE ragged sheet, flat and horizontal a
    hair above the waterline, pooled in the pit the terraces step down to and
    castable from the shelving bank that rings it. Gloomtrench_DarkWater is
    the contract name World.FISHABLE_NAMES keys on."""
    bm = bmesh.new()
    LAVA_PONDS.clear()
    _jagged_disc(bm, 0.0, 0.0, GLOOM_LAKE_R, GLOOM_LAKE_R * 0.92, 0.35, 4.6, salt=2.3, seg=40)
    LAVA_PONDS.append((0.0, 0.0, GLOOM_LAKE_R * 0.98))
    print(f"[island_gen] gloom water: 1 lake, r~{GLOOM_LAKE_R:.0f} at z=0.35")
    return object_from_bmesh("Gloomtrench_DarkWater", bm, ["M_DarkWater"])


def _gloom_fin(bm, x, y, surface, half_w, half_h, salt, yaw, thin=0.42):
    """One black basalt fin: a tall slab-ish blob, base buried in the ground."""
    add_blob(bm, (x, y, surface + half_h * 0.78), (half_w, half_w * thin, half_h), 0.5, salt, yaw=yaw)


def _gloom_arch(bm, cx, cy, surface, span, height, thick, yaw, salt):
    """Two leaning legs and a capstone - a sea-arch of trench rock."""
    dx, dy = math.cos(yaw), math.sin(yaw)
    for sgn in (-1, 1):
        add_blob(
            bm,
            (cx + dx * span * sgn, cy + dy * span * sgn, surface + height * 0.48),
            (thick, thick * 0.8, height * 0.55),
            0.26,
            salt + sgn * 3.0,
            yaw=yaw,
        )
    add_blob(bm, (cx, cy, surface + height * 1.0), (span * 1.22, thick * 0.85, thick * 0.7), 0.3, salt + 7.0, yaw=yaw)
    # the span is a natural place to hang glow-vines from
    for f in (-0.55, 0.0, 0.6):
        GLOOM_VINE_ANCHORS.append(
            (cx + dx * span * f, cy + dy * span * f, surface + height * 0.94, height * random.uniform(0.34, 0.6))
        )


def build_gloom_spires(ground):
    """The silhouette: a broken crown of fins around the amphitheatre rim with
    a GATE punched through it above the dock, two monoliths flanking that
    gate, stone arches on the apron and the crown (the landmark seen from the
    sea), shards on the terraces and fangs standing out of the lake."""
    bm = bmesh.new()
    a = math.radians(DOCK_ANGLE_DEG)

    # --- the crown: a BROKEN wall, not a picket fence. Fins come in clumps
    #     with real gaps between them, sizes range from knee-high wedges to
    #     hero towers, and wide slabs fill in as wall between the spikes.
    clumps = 20
    for c in range(clumps):
        theta_c = (c / clumps) * math.tau + random.uniform(-0.12, 0.12)
        da = abs(((theta_c - a + math.pi) % math.tau) - math.pi)
        if da < 0.27:  # the gate stays open
            continue
        hero = c % 3 == 0
        for k in range(random.randint(3, 5)):
            theta = theta_c + random.uniform(-0.19, 0.19)
            u = random.uniform(0.505, 0.605)
            r = ring_radius(u, theta)
            x, y = math.cos(theta) * r, math.sin(theta) * r
            surface = _drop_to_ground(ground, x, y)
            if surface is None:
                continue
            if hero and k == 0:
                w, h, thin = random.uniform(7.0, 10.0), random.uniform(34.0, 50.0), random.uniform(0.36, 0.56)
            elif k == 1:
                w, h, thin = random.uniform(7.5, 12.0), random.uniform(11.0, 20.0), random.uniform(0.7, 1.0)
            else:
                w = random.uniform(3.2, 7.0)
                h = w * random.uniform(2.4, 4.4)
                thin = random.uniform(0.35, 0.7)
            _gloom_fin(bm, x, y, surface, w, h, 150 + c * 17.3 + k * 5.1, yaw=theta + random.uniform(-0.6, 0.6), thin=thin)
            if h > 22.0:  # tall enough to hang a curtain of glow-vines from
                GLOOM_VINE_ANCHORS.append((x, y, surface + h * 1.42, min(h * 0.62, 24.0)))

    # --- the gate: two monoliths either side of the way in, the tallest rock
    #     on the island, so the entrance reads from out at sea.
    r_gate = ring_radius(0.555, a)
    for sgn in (-1, 1):
        gx = math.cos(a) * r_gate - math.sin(a) * 22.0 * sgn
        gy = math.sin(a) * r_gate + math.cos(a) * 22.0 * sgn
        surface = _drop_to_ground(ground, gx, gy)
        if surface is None:
            continue
        _gloom_fin(bm, gx, gy, surface, 6.8, 42.0, 40 + sgn * 11, yaw=a + 0.22 * sgn, thin=0.5)
        _gloom_fin(bm, gx + 7.0 * sgn, gy - 7.0, surface, 5.0, 14.0, 60 + sgn * 5, yaw=a - 0.4 * sgn, thin=0.8)
        # vines hang off the INNER face of each monolith, framing the gate
        GLOOM_VINE_ANCHORS.append((gx - 5.0 * sgn, gy, surface + 42.0 * 1.5, 26.0))
        GLOOM_VINE_ANCHORS.append((gx - 2.0 * sgn, gy + 5.0, surface + 42.0 * 1.35, 20.0))

    # --- the cathedral: three towers leaning together on the far shoulder,
    #     the tallest thing on the island and the landmark off the open sea.
    th_c = a + math.radians(150.0)
    r_c = ring_radius(0.545, th_c)
    cx, cy = math.cos(th_c) * r_c, math.sin(th_c) * r_c
    for k, (dx, dy, w, h) in enumerate(((0.0, 0.0, 8.0, 44.0), (-13.0, 6.0, 6.0, 33.0), (11.0, -7.0, 5.4, 27.0))):
        px, py = cx + dx, cy + dy
        surface = _drop_to_ground(ground, px, py)
        if surface is None:
            continue
        _gloom_fin(bm, px, py, surface, w, h, 3100 + k * 12.5, yaw=th_c + 0.3 * k, thin=0.52)
        for s in (-1, 1):
            GLOOM_VINE_ANCHORS.append((px + w * 0.8 * s, py + w * 0.5 * s, surface + h * 1.45, h * 0.6))

    # --- arches: two on the apron beside the dock (seen from the boat), one
    #     riding the crown on the far shoulder.
    for u_arch, off_deg, span, height, thick, salt in (
        (0.83, 27.0, 17.0, 26.0, 3.8, 310.0),
        (0.56, 122.0, 19.0, 30.0, 4.4, 420.0),
        (0.79, -33.0, 14.0, 21.0, 3.2, 530.0),
    ):
        th = a + math.radians(off_deg)
        r = ring_radius(u_arch, th)
        x, y = math.cos(th) * r, math.sin(th) * r
        surface = _drop_to_ground(ground, x, y)
        if surface is not None:
            _gloom_arch(bm, x, y, surface, span, height, thick, th + math.pi / 2, salt)

    # --- shards scattered over the terraces (kept off the walked route).
    for i in range(22):
        spot = _gloom_spot(ground, 0.26, 0.50, pad=3.0, clear=13.0)
        if spot is None:
            continue
        x, y, surface = spot
        w = random.uniform(1.8, 4.6)
        h = w * random.uniform(1.6, 3.2)
        _gloom_fin(bm, x, y, surface, w, h, 500 + i * 4.1, yaw=random.uniform(0, math.tau), thin=random.uniform(0.4, 0.8))

    # --- fangs standing out of the dark lake: the centrepiece of the pit.
    for i in range(7):
        ang = (i / 7) * math.tau + 0.4
        d = GLOOM_LAKE_R * random.uniform(0.25, 0.78)
        x, y = math.cos(ang) * d, math.sin(ang) * d
        h = random.uniform(7.0, 15.0)
        _gloom_fin(bm, x, y, -4.0, random.uniform(2.0, 4.0), h, 700 + i * 8.7, yaw=ang + 0.6, thin=0.5)

    # --- the apron and the shallows: clumps of boulders and a few sea stacks
    #     so the outer shelf isn't an empty pancake and the coast reads broken.
    for i in range(8):
        theta = random.uniform(0, math.tau)
        da = abs(((theta - a + math.pi) % math.tau) - math.pi)
        if da < 0.16:
            continue
        cu = random.uniform(0.70, 0.98)
        cr = ring_radius(cu, theta)
        cx, cy = math.cos(theta) * cr, math.sin(theta) * cr
        if not _gloom_off_path(cx, cy, 15.0) or not _gloom_off_rift(cx, cy, 4.0):
            continue
        for k in range(random.randint(2, 5)):
            x, y = cx + random.uniform(-9, 9), cy + random.uniform(-9, 9)
            surface = _drop_to_ground(ground, x, y)
            if surface is None:
                continue
            w = random.uniform(2.4, 6.5)
            add_blob(bm, (x, y, surface + w * 0.45), (w, w * random.uniform(0.6, 1.0), w * random.uniform(0.5, 1.1)), 0.42, 2000 + i * 9.1 + k, yaw=random.uniform(0, math.tau))
    for i in range(6):
        theta = a + math.radians(random.choice((52, 88, 133, -60, -104, 160))) + random.uniform(-0.08, 0.08)
        r = ring_radius(random.uniform(1.05, 1.14), theta)
        x, y = math.cos(theta) * r, math.sin(theta) * r
        w = random.uniform(3.0, 6.0)
        _gloom_fin(bm, x, y, -6.0, w, random.uniform(9.0, 16.0), 2500 + i * 13.7, yaw=theta + 0.7, thin=random.uniform(0.5, 0.9))

    return object_from_bmesh("Gloomtrench_Spires", bm, ["M_GloomRock"])


def _gloom_shelf(rock_bm, glow_bm, ground, theta, u, salt):
    """One stepped black tide-pool shelf: three ragged rock treads stacked
    down toward the waterline, each with a small glowing pool caught in it."""
    for s in range(3):
        uu = u + s * 0.052
        r = ring_radius(uu, theta)
        cx, cy = math.cos(theta) * r, math.sin(theta) * r
        g = _drop_to_ground(ground, cx, cy)
        z = (0.0 if g is None else g) + 3.4 - s * 2.7  # a real riser between treads
        rx = random.uniform(12.0, 19.0) * (1.0 - 0.12 * s)
        _jagged_disc(rock_bm, cx, cy, rx, rx * random.uniform(0.44, 0.66), z, 4.4 + s * 2.4, salt + s * 5.3, seg=14)
        # broken teeth standing on the tread so the shelf isn't a flat sticker
        for k in range(random.randint(1, 3)):
            ang = random.uniform(0, math.tau)
            d = rx * random.uniform(0.35, 0.9)
            w = random.uniform(1.1, 2.6)
            _gloom_fin(
                rock_bm, cx + math.cos(ang) * d, cy + math.sin(ang) * d * 0.6, z,
                w, w * random.uniform(1.3, 3.0), salt + 40.0 + s * 3.0 + k,
                yaw=random.uniform(0, math.tau), thin=random.uniform(0.4, 0.9),
            )
        if s < 2:  # the glowing pool caught in the tread, sat PROUD of the rock
            pang = theta + random.uniform(-1.3, 1.3)
            pr = random.uniform(3.0, 5.6)
            px, py = cx + math.cos(pang) * rx * 0.34, cy + math.sin(pang) * rx * 0.34
            _jagged_disc(glow_bm, px, py, pr, pr * 0.78, z + 0.12, 0.8, salt + 17.0 + s, seg=10)


def _gloom_coral(bm, x, y, surface, size, salt, yaw=None):
    """A branching glow-coral: a short stalk splitting into an antler fan of
    tapering fingers. Built entirely in a glow bmesh - the shore forest."""
    yaw = random.uniform(0, math.tau) if yaw is None else yaw
    trunk_h = size * random.uniform(0.5, 0.8)
    add_cone(bm, (x, y, surface - 0.7), size * 0.17, size * 0.11, trunk_h, sides=5, yaw=yaw)
    n = random.randint(3, 5)
    for b in range(n):
        ba = yaw + (b - (n - 1) * 0.5) * random.uniform(0.5, 0.95) + random.uniform(-0.15, 0.15)
        lean = random.uniform(0.32, 0.72)
        bh = size * random.uniform(0.5, 0.95)
        bx = x + math.cos(ba) * trunk_h * 0.14
        by = y + math.sin(ba) * trunk_h * 0.14
        bz = surface + trunk_h * random.uniform(0.6, 0.9)
        add_cone(bm, (bx, by, bz), size * 0.10, size * 0.035, bh, sides=4, tilt=(0.0, lean), yaw=ba)
        if random.random() < 0.55:  # a second fork off the finger
            tx = bx + math.cos(ba) * bh * math.sin(lean)
            ty = by + math.sin(ba) * bh * math.sin(lean)
            tz = bz + bh * math.cos(lean)
            add_cone(
                bm,
                (tx, ty, tz),
                size * 0.06,
                size * 0.02,
                bh * random.uniform(0.4, 0.7),
                sides=4,
                tilt=(0.0, lean * random.uniform(-0.9, 0.4)),
                yaw=ba + random.uniform(-0.9, 0.9),
            )


def _gloom_vine(bm, x, y, z_top, drop, salt, yaw=None):
    """One drooping glow-vine: a chain of thin tapering segments sagging from a
    high anchor down toward nothing, so the tall silhouettes CARRY light
    without themselves becoming lamps."""
    yaw = random.uniform(0, math.tau) if yaw is None else yaw
    n = max(3, min(7, int(drop / 4.0)))
    seg = drop / n
    px, py = x, y
    for k in range(n):
        t = k / n
        r0 = 1.05 * (1.0 - 0.62 * t)
        lean = 0.5 * (1.0 - t) ** 2  # swings out under the anchor, then hangs plumb
        add_cone(
            bm,
            (px, py, z_top - seg * (k + 1)),
            max(0.11, r0 * 0.72),
            max(0.09, r0),
            seg * 1.06,
            sides=4,
            tilt=(0.0, lean * 0.55),
            yaw=yaw,
        )
        px += math.cos(yaw) * seg * lean * 0.5
        py += math.sin(yaw) * seg * lean * 0.5
    add_cone(bm, (px, py, z_top - drop - 2.2), 0.3, 1.35, 2.2, sides=5, yaw=yaw)  # the bud on the tip


def _gloom_hang_vines(cyan_bm, violet_bm, limit=64):
    """Hang vines off every recorded high anchor (crown fins, the gate
    monoliths, the cathedral, every arch)."""
    anchors = GLOOM_VINE_ANCHORS[:]
    random.shuffle(anchors)
    hung = 0
    for i, (x, y, z, drop) in enumerate(anchors[:limit]):
        for k in range(random.randint(1, 3)):
            bm = cyan_bm if (i + k) % 3 else violet_bm
            _gloom_vine(
                bm,
                x + random.uniform(-2.6, 2.6),
                y + random.uniform(-2.6, 2.6),
                z - random.uniform(0.0, 3.0),
                max(5.0, drop * random.uniform(0.7, 1.15)),
                20.0 + i * 3.3 + k,
            )
            hung += 1
    return hung


def build_gloom_coast(ground, cyan_bm, violet_bm):
    """THE COAST. Stepped black tide-pool shelves ring the island at the
    waterline with small glowing pools caught in their treads, and a ring of
    sea-stack arches and loose stacks stands out in the shallows all the way
    round - so the outer apron edge never reads as an empty pancake rim."""
    bm = bmesh.new()
    a = math.radians(DOCK_ANGLE_DEG)
    shelves = arches = 0
    for i in range(24):
        theta = (i / 24) * math.tau + random.uniform(-0.09, 0.09)
        da = abs(((theta - a + math.pi) % math.tau) - math.pi)
        if da < 0.20:  # the dock corridor stays clear
            continue
        u = random.uniform(0.955, 1.045)
        r = ring_radius(u, theta)
        x, y = math.cos(theta) * r, math.sin(theta) * r
        if not _gloom_off_path(x, y, 16.0) or not _gloom_off_rift(x, y, 4.0):
            continue
        _gloom_shelf(bm, cyan_bm if i % 3 else violet_bm, ground, theta, u, 3000 + i * 13.9)
        shelves += 1
    for i in range(9):
        theta = (i / 9) * math.tau + 0.31 + random.uniform(-0.11, 0.11)
        da = abs(((theta - a + math.pi) % math.tau) - math.pi)
        if da < 0.26:
            continue
        r = ring_radius(random.uniform(1.03, 1.15), theta)
        x, y = math.cos(theta) * r, math.sin(theta) * r
        _gloom_arch(
            bm,
            x,
            y,
            -7.5,
            random.uniform(11.0, 19.0),
            random.uniform(18.0, 31.0),
            random.uniform(2.8, 4.6),
            theta + math.pi / 2 + random.uniform(-0.35, 0.35),
            6000 + i * 21.3,
        )
        arches += 1
    for i in range(15):  # loose stacks filling between the arches
        theta = random.uniform(0, math.tau)
        da = abs(((theta - a + math.pi) % math.tau) - math.pi)
        if da < 0.22:
            continue
        r = ring_radius(random.uniform(1.02, 1.17), theta)
        x, y = math.cos(theta) * r, math.sin(theta) * r
        w = random.uniform(2.4, 5.5)
        _gloom_fin(
            bm, x, y, -7.5, w, random.uniform(7.0, 19.0), 6500 + i * 9.4,
            yaw=theta + random.uniform(-1.0, 1.0), thin=random.uniform(0.45, 0.95),
        )
    print(f"[island_gen] gloom coast: {shelves} tide-pool shelves, {arches} sea arches")
    return object_from_bmesh("Gloomtrench_TidePools", bm, ["M_GloomShelf"])


def _gloom_rift_line(theta0):
    """Centre line of the rift: a wandering radial run out across the apron."""
    pts = []
    steps = 15
    for i in range(steps):
        t = i / (steps - 1)
        u = 0.635 + t * 0.42
        theta = theta0 + 0.10 * math.sin(t * 3.4 + 0.7) + 0.05 * math.sin(t * 7.1)
        r = ring_radius(u, theta)
        pts.append((math.cos(theta) * r, math.sin(theta) * r, theta, t))
    return pts


def build_gloom_rift(ground, stalk_bm, cyan_bm, violet_bm):
    """THE RIFT: a glowing chasm torn across the apron on the far flank from
    the dock, draining out into the sea. Two ranks of ragged black wall slabs
    with shard lips stand along its edges, a glow-vein floor runs between them,
    and lantern stalks and crystal veins line the walls. Everything is built ON
    TOP of the terrain, so the landform, the spawn, the dock corridor and the
    walked route are untouched - the rift only ever ADDS an obstacle out on an
    empty flank."""
    bm = bmesh.new()
    a = math.radians(DOCK_ANGLE_DEG)
    theta0 = a + math.radians(GLOOM_RIFT_DEG)
    floor_l, floor_r = [], []
    for i, (x, y, theta, t) in enumerate(_gloom_rift_line(theta0)):
        surface = _drop_to_ground(ground, x, y)
        if surface is None:
            surface = 0.0
        half = 5.5 + 7.5 * math.sin(math.pi * min(1.0, t * 1.12)) + 1.6 * math.sin(t * 9.0)
        px, py = -math.sin(theta), math.cos(theta)
        GLOOM_RIFT_KEEP.append((x, y, half + 9.0))
        for sgn in (-1, 1):
            wx, wy = x + px * (half + 8.0) * sgn, y + py * (half + 8.0) * sgn
            ws = _drop_to_ground(ground, wx, wy)
            ws = surface if ws is None else ws
            # A FAULT SCARP, not a trench: the far wall stands full height, the
            # near one is a low broken shoulder, so the glow floor spills out
            # over it and the crack reads as light from off the island.
            wall_h = (13.0 + 11.0 * math.sin(math.pi * t) + random.uniform(-1.5, 4.5)) * (1.0 if sgn > 0 else 0.36)
            for j in range(2):  # two offset slabs per station - torn, not extruded
                jx = wx + px * random.uniform(-1.0, 4.0) * sgn + math.cos(theta) * random.uniform(-3.0, 3.0)
                jy = wy + py * random.uniform(-1.0, 4.0) * sgn + math.sin(theta) * random.uniform(-3.0, 3.0)
                jh = wall_h * (1.0 if j == 0 else random.uniform(0.45, 0.85))
                add_box(
                    bm,
                    (jx, jy, ws + jh * 0.5 - 2.6),
                    (random.uniform(8.0, 13.0), random.uniform(8.0, 14.0), jh + 5.2),
                    yaw=theta + random.uniform(-0.42, 0.42),
                )
            _gloom_fin(  # a ragged shard lip riding the wall top
                bm, wx + px * 2.2 * sgn, wy + py * 2.2 * sgn, ws + wall_h - 3.4,
                random.uniform(2.2, 5.0), random.uniform(4.5, 11.0), 60.0 + i * 7.7 + sgn * 3.0,
                yaw=theta + random.uniform(-0.5, 0.5), thin=random.uniform(0.4, 0.85),
            )
            GLOOM_VINE_ANCHORS.append(  # vines drip off the rift lip into the glow
                (x + px * (half - 0.5) * sgn, y + py * (half - 0.5) * sgn, ws + wall_h - 1.0, wall_h * 0.62)
            )
            if i % 2 == 0:  # crystal veins bleeding down the wall faces
                _gloom_crystals(
                    violet_bm, ground, wx + px * 3.0 * sgn, wy + py * 3.0 * sgn, 3.4,
                    random.randint(3, 5), random.uniform(4.0, 8.0), 900.0 + i * 11.0 + sgn,
                    base=ws + wall_h - 4.0,
                )
            if i % 3 == 1:  # lantern stalks leaning over the lip
                cap_r = random.uniform(2.2, 4.0)
                _gloom_mushroom(
                    stalk_bm, cyan_bm, wx + px * 6.5 * sgn, wy + py * 6.5 * sgn, ws,
                    cap_r, cap_r * random.uniform(2.4, 3.6), 1300.0 + i * 6.1 + sgn,
                )
        floor_l.append(Vector((x + px * half, y + py * half, surface + 0.55)))
        floor_r.append(Vector((x - px * half, y - py * half, surface + 0.55)))
        # shards spiking out of the glowing floor, so the crack reads from above
        _gloom_crystals(
            violet_bm if i % 2 else cyan_bm, ground, x, y, half * 0.7,
            random.randint(3, 5), random.uniform(4.5, 9.0), 1700.0 + i * 5.5, base=surface + 0.7,
        )
        if i % 2 == 0:  # molten-looking glow pools puddled along the floor
            pr = half * random.uniform(0.35, 0.6)
            _jagged_disc(
                cyan_bm, x + px * random.uniform(-2.0, 2.0), y + py * random.uniform(-2.0, 2.0),
                pr, pr * 0.8, surface + 0.95, 0.8, 2100.0 + i * 3.7, seg=10,
            )
    add_strip_slab(cyan_bm, floor_l, floor_r, 1.1)  # the glow-vein floor
    print(f"[island_gen] gloom rift: bearing {math.degrees(theta0) % 360:.0f} deg, {len(GLOOM_RIFT_KEEP)} keep-clear discs")
    return object_from_bmesh("Gloomtrench_Rift", bm, ["M_GloomRift"])


def build_gloom_path(ground):
    """The lit route, as pale flagstones: dock landing -> gate -> terraces ->
    lakeside promenade. Purely so the walk READS in a near-black scene; the
    slabs sit a hair proud of the ground and the glow veins line them."""
    bm = bmesh.new()
    pts = GLOOM_PATH
    for i, (x, y) in enumerate(pts):
        nx, ny = pts[min(i + 1, len(pts) - 1)]
        px, py = pts[max(i - 1, 0)]
        yaw = math.atan2(ny - py, nx - px)
        surface = _drop_to_ground(ground, x, y)
        if surface is None:
            continue
        add_box(bm, (x, y, surface - 0.55), (12.5, 8.0, 1.8), yaw=yaw + math.pi / 2)
    return object_from_bmesh("Gloomtrench_Path", bm, ["M_GloomPath"])


def _gloom_mushroom(stalk_bm, cap_bm, x, y, surface, cap_r, stem_h, salt):
    """A glowing trench mushroom: a dark stem carrying a big luminous cap."""
    stem_r = max(0.45, cap_r * 0.20)
    add_cone(stalk_bm, (x, y, surface - 0.8), stem_r * 1.35, stem_r * 0.75, stem_h, sides=6)
    squash = 0.42 if (int(salt) % 3) else 0.85  # parasols, and rounder domes
    add_blob(cap_bm, (x, y, surface + stem_h), (cap_r, cap_r * 0.94, cap_r * squash), 0.16, salt)


def _gloom_grove(ground, stalk_bm, cap_bm, cx, cy, radius, count, scale, salt):
    """A CLUSTER of mushrooms with one hero at its heart - glow is grouped
    into focal clumps, never sprinkled."""
    for i in range(count):
        ang = random.uniform(0, math.tau)
        d = 0.0 if i == 0 else radius * math.sqrt(random.random())
        x, y = cx + math.cos(ang) * d, cy + math.sin(ang) * d
        surface = _drop_to_ground(ground, x, y)
        if surface is None:
            continue
        cap_r = scale * (random.uniform(7.5, 10.5) if i == 0 else random.uniform(1.9, 4.4))
        stem_h = cap_r * random.uniform(1.6, 2.6)
        _gloom_mushroom(stalk_bm, cap_bm, x, y, surface, cap_r, stem_h, salt + i * 3.7)


def _gloom_anemones(bm, ground, x, y, r, count, salt, base=None):
    """A bed of fat glowing bulbs mounded on the ground - the waterline beds."""
    for i in range(count):
        ang = random.uniform(0, math.tau)
        d = r * math.sqrt(random.random())
        px, py = x + math.cos(ang) * d, y + math.sin(ang) * d
        surface = _drop_to_ground(ground, px, py) if base is None else base
        if surface is None:
            continue
        s = random.uniform(1.4, 3.8) * (1.35 - 0.5 * d / max(r, 0.01))
        add_blob(bm, (px, py, surface + s * 0.45), (s, s, s * 1.15), 0.3, salt + i * 2.3, yaw=ang)


def _gloom_crystals(bm, ground, x, y, r, count, h_max, salt, base=None):
    """A cluster of glowing shards spiking out of the rock."""
    for i in range(count):
        ang = random.uniform(0, math.tau)
        d = r * math.sqrt(random.random())
        px, py = x + math.cos(ang) * d, y + math.sin(ang) * d
        surface = _drop_to_ground(ground, px, py) if base is None else base
        if surface is None:
            continue
        h = h_max * random.uniform(0.35, 1.0)
        add_cone(
            bm,
            (px, py, surface - 0.9),
            h * random.uniform(0.10, 0.17),
            0.06,
            h,
            sides=5,
            tilt=(random.uniform(-0.28, 0.28), random.uniform(-0.28, 0.28)),
            yaw=random.uniform(0, math.tau),
        )


def build_gloom_glow(ground, stalk_bm=None, cyan_bm=None, violet_bm=None):
    """Everything that gives light. Groves of giant mushrooms ring the lake
    and greet the dock, anemone beds crowd the waterline, crystal clusters
    spike the terrace risers, and thin veins of shards trace the terrace lips
    and the flagstone route so the composition still reads with the lantern
    out. Cyan carries the mushroom caps/anemones, violet the crystals - two
    objects so each keeps one flat Neon colour. A BIOLUMINESCENT SHORE FOREST
    of anemone beds and branching corals hugs the coastline ring, and
    glow-vines droop off every tall rock. The bmeshes come in from
    build_gloomtrench so the coast and the rift can pour their light into the
    same two objects."""
    stalk_bm = bmesh.new() if stalk_bm is None else stalk_bm
    cyan_bm = bmesh.new() if cyan_bm is None else cyan_bm
    violet_bm = bmesh.new() if violet_bm is None else violet_bm
    a = math.radians(DOCK_ANGLE_DEG)

    # --- the lake rim: the money shot. Groves + anemone beds all round it.
    for i in range(7):
        ang = a + 0.55 + (i / 7) * math.tau
        d = GLOOM_LAKE_R * random.uniform(1.34, 1.62)
        x, y = math.cos(ang) * d, math.sin(ang) * d
        _gloom_grove(
            ground, stalk_bm, cyan_bm if i % 3 else violet_bm, x, y, 12.0, random.randint(5, 8), 1.3, 100 + i * 40
        )
        bx, by = math.cos(ang + 0.22) * (GLOOM_LAKE_R * 1.06), math.sin(ang + 0.22) * (GLOOM_LAKE_R * 1.06)
        _gloom_anemones(cyan_bm, ground, bx, by, 11.0, random.randint(13, 19), 400 + i * 31)

    # --- hero mushrooms standing right on the bank, over the black water.
    for k, off in enumerate((0.9, 2.6, 4.4)):
        ang = a + off
        d = GLOOM_LAKE_R * 1.02
        hx, hy = math.cos(ang) * d, math.sin(ang) * d
        surface = _drop_to_ground(ground, hx, hy)
        if surface is None:
            continue
        cap_r = random.uniform(10.0, 13.5)
        _gloom_mushroom(stalk_bm, cyan_bm if k != 1 else violet_bm, hx, hy, surface, cap_r, cap_r * 1.9, 900 + k * 13)

    # --- the fangs in the lake wear crowns of violet crystal.
    for i in range(5):
        ang = (i / 5) * math.tau + 0.9
        d = GLOOM_LAKE_R * random.uniform(0.3, 0.7)
        _gloom_crystals(violet_bm, ground, math.cos(ang) * d, math.sin(ang) * d, 5.0, 6, 9.0, 800 + i * 17, base=0.2)

    # --- terrace risers: crystal clusters catching the step edges.
    for i in range(8):
        spot = _gloom_spot(ground, 0.30, 0.52, pad=3.0, clear=14.0)
        if spot is None:
            continue
        x, y, _ = spot
        _gloom_crystals(violet_bm, ground, x, y, 8.0, random.randint(7, 11), random.uniform(12.0, 20.0), 1200 + i * 23)

    # --- a grove either side of the dock landing, and two in the gate mouth,
    #     so arrival and the way in are both lit.
    for u_g, off_deg, scale, salt in (
        (0.86, 13.0, 1.2, 60.0),  # the landing, either side of the planks
        (0.82, -16.0, 1.05, 90.0),
        (0.545, 10.0, 1.15, 120.0),  # the gate mouth
        (0.545, -10.5, 1.05, 150.0),
        (0.39, 46.0, 1.1, 180.0),  # terrace groves, seen over the crown
        (0.47, -70.0, 1.0, 210.0),
        (0.32, 155.0, 1.15, 240.0),
    ):
        th = a + math.radians(off_deg)
        r = ring_radius(u_g, th)
        _gloom_grove(ground, stalk_bm, cyan_bm, math.cos(th) * r, math.sin(th) * r, 10.0, random.randint(5, 7), scale, salt)

    # --- the outer apron gets its own light so the boss ground and the walk
    #     round the island are not a blank grey shelf.
    for i in range(5):
        th = a + math.radians(random.choice((70, 112, 158, -78, -128)))
        r = ring_radius(random.uniform(0.72, 0.90), th)
        x, y = math.cos(th) * r, math.sin(th) * r
        if not _gloom_off_path(x, y, 16.0) or not _gloom_off_rift(x, y, 3.0):
            continue
        if i % 2:
            _gloom_crystals(violet_bm, ground, x, y, 7.0, random.randint(6, 9), random.uniform(8.0, 14.0), 1600 + i * 29)
        else:
            _gloom_grove(ground, stalk_bm, cyan_bm, x, y, 11.0, random.randint(4, 6), 1.0, 1700 + i * 31)

    # --- glowing veins along the terrace lips: arcs of small shards that draw
    #     the contour lines of the amphitheatre in the dark.
    for lip_i, u_lip in enumerate(GLOOM_TERRACE_LIPS):
        for arc in range(4):
            a0 = a + random.uniform(0, math.tau)
            span = random.uniform(0.5, 1.0)
            steps = 16
            for k in range(steps):
                theta = a0 + span * (k / steps)
                da = abs(((theta - a + math.pi) % math.tau) - math.pi)
                if da < 0.20:
                    continue
                r = ring_radius(u_lip, theta) + random.uniform(-2.0, 2.0)
                x, y = math.cos(theta) * r, math.sin(theta) * r
                surface = _drop_to_ground(ground, x, y)
                if surface is None:
                    continue
                bm = violet_bm if (lip_i + arc) % 2 else cyan_bm
                add_cone(
                    bm,
                    (x, y, surface - 0.5),
                    random.uniform(0.35, 0.7),
                    0.05,
                    random.uniform(2.0, 4.2),
                    sides=4,
                    tilt=(random.uniform(-0.2, 0.2), random.uniform(-0.2, 0.2)),
                    yaw=random.uniform(0, math.tau),
                )

    # --- veins lining the flagstones: the route glows all the way in.
    for i, (x, y) in enumerate(GLOOM_PATH):
        if i % 2:
            continue
        nx, ny = GLOOM_PATH[min(i + 1, len(GLOOM_PATH) - 1)]
        yaw = math.atan2(ny - y, nx - x) + math.pi / 2
        for sgn in (-1, 1):
            px, py = x + math.cos(yaw) * 7.4 * sgn, y + math.sin(yaw) * 7.4 * sgn
            surface = _drop_to_ground(ground, px, py)
            if surface is None:
                continue
            bm = cyan_bm if (i // 2) % 2 else violet_bm
            add_cone(
                bm,
                (px, py, surface - 0.5),
                random.uniform(0.4, 0.75),
                0.05,
                random.uniform(2.2, 4.0),
                sides=4,
                yaw=random.uniform(0, math.tau),
            )

    # --- THE SHORE GLOW FOREST: dense beds of anemones and branching coral
    #     fans hugging the coastline ring, clumped into focal groves and
    #     thinning inland, so the walk round the island is a reef of light.
    corals = 0
    for i in range(26):
        theta = (i / 26) * math.tau + random.uniform(-0.10, 0.10)
        da = abs(((theta - a + math.pi) % math.tau) - math.pi)
        if da < 0.19:  # the dock corridor stays clear
            continue
        # dense at the waterline, thinning inland - every third clump steps up
        u = random.uniform(0.93, 1.02) if i % 3 else random.uniform(0.80, 0.90)
        r = ring_radius(u, theta)
        cx, cy = math.cos(theta) * r, math.sin(theta) * r
        if not _gloom_off_path(cx, cy, 15.0) or not _gloom_off_rift(cx, cy, 3.0):
            continue
        violet = i % 4 == 1
        glow_bm = violet_bm if violet else cyan_bm
        _gloom_anemones(glow_bm, ground, cx, cy, 10.0, random.randint(6, 10), 5000 + i * 27.1)
        for k in range(random.randint(3, 6)):
            ang = random.uniform(0, math.tau)
            d = 12.0 * math.sqrt(random.random())
            fx, fy = cx + math.cos(ang) * d, cy + math.sin(ang) * d
            surface = _drop_to_ground(ground, fx, fy)
            if surface is None:
                continue
            fan_bm = violet_bm if (violet != (k % 3 == 0)) else cyan_bm
            _gloom_coral(fan_bm, fx, fy, surface, random.uniform(5.0, 11.0), 5400 + i * 9.7 + k)
            corals += 1

    # --- GLOW-VINES drooping off every tall rock: the crown fins, the gate
    #     monoliths, the cathedral and every sea arch.
    vines = _gloom_hang_vines(cyan_bm, violet_bm)
    print(f"[island_gen] gloom glow: shore forest {corals} corals, {vines} vines off {len(GLOOM_VINE_ANCHORS)} anchors")

    return (
        object_from_bmesh("Gloomtrench_Stalks", stalk_bm, ["M_GloomStalk"]),
        object_from_bmesh("Gloomtrench_GlowCyan", cyan_bm, ["M_GlowCyan"]),
        object_from_bmesh("Gloomtrench_GlowViolet", violet_bm, ["M_GlowViolet"]),
    )


# ---- Gloomtrench: Keeper Lumen's lighthouse -------------------------------
#
# The island lives in permanent dark, so its ONE standing light has to be the
# landmark: a short, barnacled stone tower on the apron between the spawn and
# the dock head, a caged wisp-glow beacon in the lamp room at the top of it,
# and a spiral of small lanterns climbing the ribs so the tower reads as LIT
# from the water long before you can see the rock it stands on. Pale flagstone
# walls (the same stone as the lit route) against near-black basalt: in a
# near-black scene the tower is the only thing with a value above the murk.
#
# You can walk in: the ground room is Lumen's office - light-logs and lens
# tools on the desk, a spare-lantern wall, a stair hugging the wall up to the
# shaft (decorative - the beacon is not a play space), the cot tucked under it
# and a cup of tea that went cold three watches ago.
#
# Everything here is prefixed _hut_lumen / LUMEN_ and pours into four bmeshes,
# so it cannot disturb the island's other props. It runs LAST in the island
# build off its own RNG stream, so the shared scatter is bit-identical.

LUMEN_SITE = (-22.0, -160.0)  # Blender (x, y) - Roblox rel X=-22 Z=160, off the lit route
LUMEN_DOOR_DEG = 0.0  # the door looks +X, back up the apron toward the spawn
LUMEN_SECTORS = 12
LUMEN_BANDS = (0.0, 5.2, 10.8, 16.6, 22.6)  # band tops above the floor
LUMEN_R_OUT = (8.6, 8.1, 7.2, 6.4)  # outer radius per band - the taper. The
# bottom two bands are stout on purpose: they carry the ROOM, and the contract
# wants 8x8 of clear floor left over once the desk, cot, shelves and stair are
# pushed back against the stone.
LUMEN_WALL_T = 1.15  # wall thickness (contract: >= 0.5)
LUMEN_ROOM_H = 9.9  # floor -> deckhead: the walk-in room
LUMEN_DOOR_H = 7.9  # door head height (contract: >= 7)
LUMEN_KEEP_R = 16.0  # keep-clear radius for anything scattered later


def _hut_lumen_ring(cx, cy, r, n, phase=0.0, wobble=0.0, salt=0.0):
    """A closed n-gon of (x, y), optionally made slightly ragged - the tower's
    stonework is cut, its foundation is not."""
    pts = []
    for k in range(n):
        a = phase + k * math.tau / n
        rr = r * (1.0 + wobble * math.sin(a * 3.0 + salt) + wobble * 0.5 * math.sin(a * 5.0 - salt))
        pts.append((cx + math.cos(a) * rr, cy + math.sin(a) * rr))
    return pts


def _hut_lumen_radius(z_rel):
    """Outer wall radius at a height above the floor - lanterns and ribs ride
    the taper instead of hanging off it."""
    for i in range(len(LUMEN_R_OUT)):
        if z_rel <= LUMEN_BANDS[i + 1]:
            return LUMEN_R_OUT[i]
    return LUMEN_R_OUT[-1]


def _hut_lumen_lantern(props_bm, glow_bm, x, y, z, yaw, size=1.0):
    """One caged lantern: a bracket, a boxed cage and the wisp inside it. The
    wisp sits INSIDE the cage and the cage overlaps the bracket - nothing here
    hangs in the air."""
    dx, dy = math.cos(yaw), math.sin(yaw)
    add_box(props_bm, (x - dx * 0.75 * size, y - dy * 0.75 * size, z + 0.75 * size),
            (1.7 * size, 0.35 * size, 0.35 * size), yaw=yaw)  # bracket, into the wall
    add_box(props_bm, (x, y, z + 0.82 * size), (1.05 * size, 1.05 * size, 0.28 * size), yaw=yaw)  # cage cap
    for sy in (-1, 1):  # two corner bars: the cage reads without eight of them
        add_box(props_bm, (x - dy * sy * 0.42 * size, y + dx * sy * 0.42 * size, z + 0.38 * size),
                (0.9 * size, 0.16 * size, 1.1 * size), yaw=yaw)
    # The wisp fills the cage (and overlaps its cap and bars) - it has to be
    # big enough to read from the water, not a speck behind bars.
    add_blob(glow_bm, (x, y, z + 0.38 * size), (0.58 * size, 0.58 * size, 0.62 * size), 0.10, 91.0 + x + y)


def build_gloom_lighthouse(ground):
    """Keeper Lumen's lighthouse: the island's only standing light, and the
    landmark the shore reads by. Four objects, Gloomtrench_Hut_Walls / _Roof /
    _Props / _Glow."""
    rng = random.Random(4801)  # own stream: the island's shared scatter is untouched
    walls = bmesh.new()  # tower stonework, plinth, floor, deckhead
    roof = bmesh.new()  # gallery, lamp-room cage, cap, ribs, buttresses
    props = bmesh.new()  # lantern cages, bell, desk, stair, cot, shelves
    glow = bmesh.new()  # the beacon, the lantern wisps, the moth-fish

    cx, cy = LUMEN_SITE
    door = math.radians(LUMEN_DOOR_DEG)
    step = math.tau / LUMEN_SECTORS

    # --- SEATING. Probe a ring at the wall line and stand the floor on the
    #     HIGHEST ground under the footprint, with the plinth carried down past
    #     the lowest: the apron falls ~3 studs across the tower, and a
    #     lighthouse on a cut plinth is the honest answer to that.
    probes = [_drop_to_ground(ground, cx, cy)]
    for k in range(20):
        a = k * math.tau / 20
        for r in (5.0, 8.4):
            probes.append(_drop_to_ground(ground, cx + math.cos(a) * r, cy + math.sin(a) * r))
    probes = [p for p in probes if p is not None] or [height_at(cx, cy)]
    floor = max(probes) + 0.2
    plinth_bottom = min(probes) - 3.4

    # --- 1. FOUNDATION: a ragged stone apron cut into the slope, and three
    #     steps down off its low, seaward-facing lip to the sand.
    add_disc_slab(walls, _hut_lumen_ring(cx, cy, 10.4, 14, phase=0.11, wobble=0.055, salt=1.7),
                  floor + 0.02, floor + 0.02 - plinth_bottom)  # top flush under the wall foot
    for k in range(3):
        r = 10.7 + k * 1.7
        sz = floor + 0.2 - (k + 1) * 0.62
        add_box(walls, (cx + math.cos(door) * r, cy + math.sin(door) * r, sz - 0.6),
                (1.9, 5.6 - k * 0.5, 1.6), yaw=door)

    # --- 2. THE TOWER. Four tapering bands of cut sector blocks; two sectors
    #     left out of the bottom band and cut down to a lintel in the second
    #     make the doorway (8.2 clear x 7.9 to the head, jambs narrowing it to
    #     ~5.2 - the contract wants >= 4 x 7).
    for i in range(4):
        r_out, r_in = LUMEN_R_OUT[i], LUMEN_R_OUT[i] - LUMEN_WALL_T
        r_mid = (r_out + r_in) / 2
        chord = 2 * r_mid * math.tan(step / 2) + 0.3
        for k in range(LUMEN_SECTORS):
            a = door + (k + 0.5) * step
            is_door = k in (0, LUMEN_SECTORS - 1)
            z0, z1 = floor + LUMEN_BANDS[i], floor + LUMEN_BANDS[i + 1]
            if is_door:
                if i == 0:
                    continue
                if i == 1:
                    z0 = floor + LUMEN_DOOR_H
            add_box(walls, (cx + math.cos(a) * r_mid, cy + math.sin(a) * r_mid, (z0 + z1) / 2),
                    (LUMEN_WALL_T, chord, z1 - z0), yaw=a)
    for sgn in (-1, 1):  # door jambs and the sill, so the tear-out reads as a door
        a = door + sgn * step
        r_mid = LUMEN_R_OUT[0] - LUMEN_WALL_T / 2
        add_box(walls, (cx + math.cos(a) * r_mid, cy + math.sin(a) * r_mid, floor + LUMEN_DOOR_H / 2),
                (LUMEN_WALL_T + 0.5, 1.3, LUMEN_DOOR_H), yaw=a)
    add_box(walls, (cx + math.cos(door) * (LUMEN_R_OUT[0] - 0.4), cy + math.sin(door) * (LUMEN_R_OUT[0] - 0.4),
                    floor + 0.1), (2.6, 6.4, 0.7), yaw=door)  # threshold

    # --- 3. THE ROOM: a flagstone floor on the plinth, and a deckhead ring
    #     with the shaft open at its centre (the stair climbs to it).
    add_disc_slab(walls, _hut_lumen_ring(cx, cy, LUMEN_R_OUT[0] - LUMEN_WALL_T + 0.15, LUMEN_SECTORS, phase=0.26),
                  floor + 0.12, 1.1)
    add_ring_slab(walls, _hut_lumen_ring(cx, cy, 2.4, 10, phase=0.26),
                  _hut_lumen_ring(cx, cy, LUMEN_R_OUT[1] - LUMEN_WALL_T + 0.4, 10, phase=0.26),
                  floor + LUMEN_ROOM_H + 0.8, 0.8)

    # --- 4. RIBS + BARNACLES. Six buttress ribs run the full height (the
    #     lanterns hang off them), and the sea has been at the bottom two
    #     bands: barnacle crusts bedded into the stone.
    for j in range(6):
        a = door + 0.32 + j * math.tau / 6
        if abs(((a - door + math.pi) % math.tau) - math.pi) < math.radians(38):
            continue  # never across the doorway
        for i in range(4):
            r = LUMEN_R_OUT[i] - 0.25
            add_box(roof, (cx + math.cos(a) * r, cy + math.sin(a) * r,
                           floor + (LUMEN_BANDS[i] + LUMEN_BANDS[i + 1]) / 2),
                    (1.5, 1.35, LUMEN_BANDS[i + 1] - LUMEN_BANDS[i]), yaw=a)
    made = 0
    while made < 8:  # barnacles bedded on the OUTER face, never in the doorway
        a = rng.uniform(0, math.tau)
        if abs(((a - door + math.pi) % math.tau) - math.pi) < math.radians(34):
            continue
        z = floor + rng.uniform(0.4, 9.5)
        s = rng.uniform(0.55, 1.3)
        r = _hut_lumen_radius(z - floor) + s * 0.15
        add_blob(walls, (cx + math.cos(a) * r, cy + math.sin(a) * r, z), (s, s * 0.85, s * 0.7),
                 0.42, 500 + made * 6.7, yaw=a)
        made += 1

    # --- 5. THE GALLERY + LAMP ROOM. A corbelled deck, a rail, an eight-sided
    #     cage of mullions, and a cap cone with the keeper's fish vane on it.
    zg = floor + LUMEN_BANDS[-1]
    for j in range(6):  # corbels, under the deck they carry
        a = door + j * math.tau / 6
        add_box(roof, (cx + math.cos(a) * (LUMEN_R_OUT[-1] + 0.7), cy + math.sin(a) * (LUMEN_R_OUT[-1] + 0.7), zg - 0.5),
                (3.0, 1.1, 1.3), yaw=a)
    add_disc_slab(roof, _hut_lumen_ring(cx, cy, 9.0, 14, phase=0.08), zg + 1.0, 1.0)
    for j in range(8):  # rail stanchions, standing on the deck
        a = door + (j + 0.5) * math.tau / 8
        add_box(roof, (cx + math.cos(a) * 8.4, cy + math.sin(a) * 8.4, zg + 2.1), (0.42, 0.42, 2.2), yaw=a)
    add_ring_slab(roof, _hut_lumen_ring(cx, cy, 8.05, 14, phase=0.08), _hut_lumen_ring(cx, cy, 8.85, 14, phase=0.08),
                  zg + 3.3, 0.45)
    for j in range(8):  # the lamp-room cage: mullions between deck and cap
        a = door + (j + 0.5) * math.tau / 8
        add_box(roof, (cx + math.cos(a) * 4.5, cy + math.sin(a) * 4.5, zg + 4.6), (0.52, 0.72, 7.2), yaw=a)
    for zz in (zg + 4.7, zg + 8.05):  # the cage bands
        add_ring_slab(roof, _hut_lumen_ring(cx, cy, 4.05, 8, phase=0.39), _hut_lumen_ring(cx, cy, 5.0, 8, phase=0.39),
                      zz, 0.4)
    add_cone(roof, (cx, cy, zg + 8.2), 5.7, 0.85, 3.5, sides=8, yaw=door)  # the cap
    add_post(roof, cx, cy, zg + 11.5, zg + 13.4, 0.28, sides=4)  # finial
    add_box(roof, (cx + math.cos(door) * 0.9, cy + math.sin(door) * 0.9, zg + 13.2), (2.4, 0.24, 1.0), yaw=door)
    add_box(roof, (cx - math.cos(door) * 1.5, cy - math.sin(door) * 1.5, zg + 13.2), (1.0, 0.22, 1.5), yaw=door)

    # --- 6. THE BEACON. A wisp caged in the lamp room: the light body, the
    #     lens band around it, and the pool of light it throws on the gallery
    #     deck (a thin slab lying ON the deck - it is the deck lit, not a lamp
    #     floating over it).
    add_post(roof, cx, cy, zg + 1.0, zg + 3.1, 0.95, sides=6)  # the lamp pedestal, off the deck
    add_box(roof, (cx, cy, zg + 3.1), (2.6, 2.6, 0.5), yaw=door)  # its table, under the light
    add_blob(glow, (cx, cy, zg + 5.3), (3.3, 3.3, 3.05), 0.07, 12.5, subdiv=2)
    add_ring_slab(glow, _hut_lumen_ring(cx, cy, 3.0, 10, phase=0.31), _hut_lumen_ring(cx, cy, 3.7, 10, phase=0.31),
                  zg + 5.9, 0.55)
    add_disc_slab(glow, _hut_lumen_ring(cx, cy, 5.4, 12, phase=0.16), zg + 1.12, 0.12)
    add_ring_slab(glow, _hut_lumen_ring(cx, cy, 4.3, 10, phase=0.31), _hut_lumen_ring(cx, cy, 5.6, 10, phase=0.31),
                  zg + 1.32, 0.32)  # spill lying ON the gallery deck: the light reads from the water

    # --- 7. THE LANTERN SPIRAL: eight small wisp-lanterns winding up the ribs,
    #     each bracketed into the stone. From the sea this is what turns a dark
    #     silhouette into a lighthouse.
    for k in range(7):
        a = door + 0.62 + k * 0.86
        z = floor + 3.1 + k * 2.7
        r = _hut_lumen_radius(z - floor) + 0.55
        _hut_lumen_lantern(props, glow, cx + math.cos(a) * r, cy + math.sin(a) * r, z, a, size=1.0)

    # --- 8. THE FOG BELL, on its frame beside the door.
    ab = door + 0.62
    bx_, by_ = cx + math.cos(ab) * 10.2, cy + math.sin(ab) * 10.2
    bell_g = _drop_to_ground(ground, bx_, by_)
    bell_g = height_at(bx_, by_) if bell_g is None else bell_g
    for sgn in (-1, 1):
        px = bx_ - math.sin(ab) * sgn * 2.1
        py = by_ + math.cos(ab) * sgn * 2.1
        pg = _drop_to_ground(ground, px, py)
        add_post(props, px, py, (pg if pg is not None else bell_g) - 0.5, bell_g + 5.4, 0.45, sides=4)
    add_box(props, (bx_, by_, bell_g + 5.2), (0.6, 5.0, 0.6), yaw=ab)  # the headstock
    add_cone(props, (bx_, by_, bell_g + 2.9), 0.55, 1.7, 2.3, sides=8, yaw=ab)  # the bell, hung under it
    add_post(props, bx_, by_, bell_g + 2.5, bell_g + 3.4, 0.22, sides=4)  # clapper
    add_box(props, (bx_ + math.cos(ab) * 1.4, by_ + math.sin(ab) * 1.4, bell_g + 3.1), (2.0, 0.3, 0.3), yaw=ab)  # rope arm

    # --- 9. THE MOTH-FISH: three glowfish circling the lamp. The ONE thing
    #     here that is meant to hang in the air (registered with the coordinator).
    for k in range(3):
        a = door + 1.1 + k * 2.2
        r = 7.4 + 1.5 * math.sin(k * 2.0)
        z = zg + 4.4 + (1.9, -1.6, 3.4)[k]
        fx, fy = cx + math.cos(a) * r, cy + math.sin(a) * r
        add_blob(glow, (fx, fy, z), (1.55, 0.62, 0.8), 0.12, 700 + k * 11.0, yaw=a + math.pi / 2)
        add_box(glow, (fx - math.cos(a + math.pi / 2) * 1.55, fy - math.sin(a + math.pi / 2) * 1.55, z),
                (1.3, 0.22, 1.1), yaw=a + math.pi / 2)  # the tail, on the body
        add_box(glow, (fx, fy, z + 0.5), (0.5, 1.9, 0.5), yaw=a + math.pi / 2)  # wing-fins

    # --- 10. THE OFFICE. Desk of light-logs and lens tools, the spare-lantern
    #     wall, the stair hugging the stone, the cot under it, the cold tea.
    a_desk = door + math.radians(150)
    dx_, dy_ = cx + math.cos(a_desk) * 5.7, cy + math.sin(a_desk) * 5.7
    add_box(props, (dx_, dy_, floor + 2.55), (2.3, 5.2, 0.35), yaw=a_desk)  # desk top
    for sx in (-0.85, 0.85):
        for sy in (-2.2, 2.2):
            px = dx_ + math.cos(a_desk) * sx - math.sin(a_desk) * sy
            py = dy_ + math.sin(a_desk) * sx + math.cos(a_desk) * sy
            add_box(props, (px, py, floor + 1.25), (0.35, 0.35, 2.5), yaw=a_desk)
    for k in range(3):  # the light-logs, stacked and one lying open
        add_box(props, (dx_ - math.sin(a_desk) * (1.2 - k * 0.12), dy_ + math.cos(a_desk) * (1.2 - k * 0.12),
                        floor + 2.85 + k * 0.26), (1.5, 2.0, 0.26), yaw=a_desk + rng.uniform(-0.12, 0.12))
    add_box(props, (dx_ - math.sin(a_desk) * -1.4, dy_ + math.cos(a_desk) * -1.4, floor + 2.82),
            (1.6, 2.2, 0.16), yaw=a_desk + 0.2)
    for k in range(2):  # lens tools: two ground blanks on their stands
        px = dx_ + math.cos(a_desk) * 0.5 - math.sin(a_desk) * (-0.2 + k * 0.9)
        py = dy_ + math.sin(a_desk) * 0.5 + math.cos(a_desk) * (-0.2 + k * 0.9)
        add_post(props, px, py, floor + 2.7, floor + 3.5, 0.18, sides=6)
    lx_ = dx_ + math.cos(a_desk) * 0.5 - math.sin(a_desk) * 0.25
    ly_ = dy_ + math.sin(a_desk) * 0.5 + math.cos(a_desk) * 0.25
    add_disc_slab(glow, _hut_lumen_ring(lx_, ly_, 0.85, 8), floor + 3.62, 0.16)  # the lens, catching the light
    add_post(props, dx_ - math.sin(a_desk) * 1.9, dy_ + math.cos(a_desk) * 1.9, floor + 2.72, floor + 3.28, 0.3, sides=6)
    add_disc_slab(props, _hut_lumen_ring(dx_ - math.sin(a_desk) * 1.9, dy_ + math.cos(a_desk) * 1.9, 0.55, 8),
                  floor + 2.78, 0.1)  # the saucer under the cold cup
    a_shelf = door + math.radians(88)
    for k in range(2):  # the spare-lantern wall: two shelves of dark lanterns
        sz_ = floor + 3.3 + k * 2.4
        sx_ = cx + math.cos(a_shelf) * 6.9
        sy_ = cy + math.sin(a_shelf) * 6.9
        add_box(props, (sx_, sy_, sz_), (1.25, 5.6, 0.32), yaw=a_shelf)  # deep enough to bite the stone
        for j in range(3):
            off = -1.7 + j * 1.7
            px = sx_ - math.sin(a_shelf) * off
            py = sy_ + math.cos(a_shelf) * off
            add_box(props, (px, py, sz_ + 0.75), (0.95, 0.95, 1.2), yaw=a_shelf)
            if (k + j) % 2 == 0:  # a couple of them still have a wisp in
                add_blob(glow, (px, py, sz_ + 0.75), (0.3, 0.3, 0.34), 0.1, 800 + k * 3 + j)
    n_tread = 14  # the stair, hugging the wall (decorative: the shaft is not a play space)
    for k in range(n_tread):
        a = door + math.radians(205) + k * math.radians(23.0)
        z = floor + 0.9 + k * (LUMEN_ROOM_H - 1.4) / (n_tread - 1)
        r = LUMEN_R_OUT[0] - LUMEN_WALL_T - 1.35
        add_box(props, (cx + math.cos(a) * r, cy + math.sin(a) * r, z), (2.9, 1.7, 0.34), yaw=a)
    a_cot = door + math.radians(243)
    ctx = cx + math.cos(a_cot) * 5.6
    cty = cy + math.sin(a_cot) * 5.6
    add_box(props, (ctx, cty, floor + 1.05), (2.6, 5.4, 0.45), yaw=a_cot)  # cot frame
    for sx in (-0.95, 0.95):
        for sy in (-2.3, 2.3):
            px = ctx + math.cos(a_cot) * sx - math.sin(a_cot) * sy
            py = cty + math.sin(a_cot) * sx + math.cos(a_cot) * sy
            add_box(props, (px, py, floor + 0.5), (0.32, 0.32, 1.0), yaw=a_cot)
    add_box(props, (ctx, cty, floor + 1.5), (2.3, 5.0, 0.45), yaw=a_cot)  # bedding
    add_box(props, (ctx, cty - 0.0, floor + 1.85), (2.1, 2.4, 0.35), yaw=a_cot + 0.1)  # the blanket, thrown back
    add_box(props, (ctx - math.sin(a_cot) * -2.0, cty + math.cos(a_cot) * -2.0, floor + 1.95), (1.5, 1.4, 0.5), yaw=a_cot)

    stand_r = LUMEN_R_OUT[0] + 3.4
    sx_, sy_ = cx + math.cos(door) * stand_r, cy + math.sin(door) * stand_r
    look = (math.cos(door), math.sin(door))  # Lumen stands at his door, looking out over the apron
    facing = math.degrees(math.atan2(-look[0], look[1])) % 360.0
    print(
        f"[island_gen] HANDOFF gloomtrench hut (Keeper Lumen's lighthouse): door (Roblox rel) "
        f"X={cx + math.cos(door) * LUMEN_R_OUT[0]:.0f} Z={-(cy + math.sin(door) * LUMEN_R_OUT[0]):.0f} "
        f"sill Y~{floor:.1f}, beacon Y~{zg + 5.3:.1f}; suggested lumen spawnOffset "
        f"Vector3.new({sx_:.0f}, 0, {-sy_ - 154.0:.0f}) facing {facing:.0f} (island spawn X=0 Z=154)"
    )
    print(
        f"[island_gen] HANDOFF gloomtrench hut KEEP-CLEAR: centre (Roblox rel) X={cx:.0f} Z={-cy:.0f} "
        f"r={LUMEN_KEEP_R:.0f}; floor seated on the probe at Y={floor:.2f}, plinth cut to Y={plinth_bottom:.2f}"
    )
    return (
        object_from_bmesh("Gloomtrench_Hut_Walls", walls, ["M_GloomPath"]),
        object_from_bmesh("Gloomtrench_Hut_Roof", roof, ["M_GloomShelf"]),
        object_from_bmesh("Gloomtrench_Hut_Props", props, ["M_GloomStalk"]),
        object_from_bmesh("Gloomtrench_Hut_Glow", glow, ["M_GlowCyan"]),
    )


def build_gloomtrench():
    GLOOM_PATH[:] = _gloom_path_points()
    GLOOM_VINE_ANCHORS.clear()
    GLOOM_RIFT_KEEP.clear()
    base = build_island_base("Gloomtrench_Base", ["M_GloomRock", "M_GloomSand", "M_GloomWet"])
    ground = _ground_bvh(base)
    # The three glow bmeshes are shared: the rift, the coast and the glow pass
    # all pour into the same two Neon objects. Order matters - the rift is laid
    # out FIRST so everything else can steer around its footprint, and the
    # spires/coast run before the glow so their high points are on record for
    # the vines to hang from.
    stalk_bm, cyan_bm, violet_bm = bmesh.new(), bmesh.new(), bmesh.new()
    rift = build_gloom_rift(ground, stalk_bm, cyan_bm, violet_bm)
    spires = build_gloom_spires(ground)
    coast = build_gloom_coast(ground, cyan_bm, violet_bm)
    objects = [
        base,
        build_gloom_water(ground),
        spires,
        coast,
        rift,
        build_gloom_path(ground),
        *build_gloom_glow(ground, stalk_bm, cyan_bm, violet_bm),
        *build_dock("Gloomtrench_Dock_Planks", "Gloomtrench_Dock_Posts", "M_GloomPlank", "M_GloomPost"),
        build_foam("Gloomtrench_Foam", "M_GloomFoam"),
        # Lumen's lighthouse runs LAST and off its own RNG stream, so every
        # scatter above it keeps the exact placement it had before the hut.
        *build_gloom_lighthouse(ground),
    ]
    a = math.radians(DOCK_ANGLE_DEG)
    start_r = ring_radius(DOCK_START_U, a)
    spawn_h = _drop_to_ground(ground, 0.0, -154.0)
    gate_h = _drop_to_ground(ground, 0.0, -ring_radius(0.615, a))
    print(f"[island_gen] HANDOFF gloomtrench: dock start (Roblox rel) X=0 Z={start_r:.0f}, spawn (0,154) ground Y~{spawn_h}, gate crest Y~{gate_h}")
    return objects


# ---- Wreckwater -----------------------------------------------------------


def build_wreck_bay(ground):
    """The drowned lagoon at the island's heart (waters="wreck"): one broad
    sheet of deep-teal bay water over the sunken bowl, plus the entrance
    channel the rim notch carves toward the dock. One object, Wreckwater_Bay."""
    bm = bmesh.new()
    LAVA_PONDS.clear()

    seg = 40
    points = []
    for s in range(seg):
        theta = (s / seg) * math.tau
        r = ring_radius(0.46, theta) * (1 + 0.05 * math.sin(3 * theta + 0.7) + 0.03 * math.sin(7 * theta))
        points.append((math.cos(theta) * r, math.sin(theta) * r))
    add_disc_slab(bm, points, 0.22, 3.0)
    bay_r = sum(ring_radius(0.46, (s / 24) * math.tau) for s in range(24)) / 24
    LAVA_PONDS.append((0.0, 0.0, bay_r))  # scatter keeps out of the water

    # The channel: from the bay edge out through the notched rim to the shore
    # on the dock side, so the lagoon visibly opens to the sea.
    a = math.radians(DOCK_ANGLE_DEG)
    d = Vector((math.cos(a), math.sin(a), 0))
    inner = d * (bay_r * 0.9)
    outer = d * ring_radius(1.02, a)
    perp = Vector((-d.y, d.x, 0)) * 9.0
    a_pt = Vector((inner.x, inner.y, 0.20))
    b_pt = Vector((outer.x, outer.y, 0.16))
    add_strip_slab(bm, [a_pt + perp, b_pt + perp], [a_pt - perp, b_pt - perp], 2.6)
    return object_from_bmesh("Wreckwater_Bay", bm, ["M_BayWater"])


# ---- Wreckwater: ship-carpentry helpers ----------------------------------
#
# Everything below is self-contained (prefix _wr_) so it cannot disturb the
# shared prop helpers. All of it works in a SHIP-LOCAL frame - +X toward the
# bow, +Y to port, +Z up - mapped into the world by one 4x4 from _wr_frame,
# which is what lets a bow section rear out of the bay at a real angle.


def _wr_emit(bm, temp):
    """Append a scratch bmesh into `bm` (the round-trip the shared helpers use)."""
    mesh = bpy.data.meshes.new("_wr")
    temp.to_mesh(mesh)
    temp.free()
    bm.from_mesh(mesh)
    bpy.data.meshes.remove(mesh)


def _wr_frame(pos, yaw=0.0, pitch=0.0, roll=0.0):
    """Ship-local -> world. `pitch` is bow-UP radians, `roll` is heel to port."""
    return (
        Matrix.Translation(Vector(pos))
        @ Matrix.Rotation(yaw, 4, "Z")
        @ Matrix.Rotation(-pitch, 4, "Y")
        @ Matrix.Rotation(roll, 4, "X")
    )


def _wr_beam(bm, frame, p0, p1, width, thick, twist=0.0):
    """A squared timber spanning ship-local p0 -> p1: the workhorse for ribs,
    yards, bowsprits, deck planks and beached driftwood."""
    a, b = Vector(p0), Vector(p1)
    d = b - a
    length = d.length
    if length < 1e-5:
        return
    rot = Vector((1.0, 0.0, 0.0)).rotation_difference(d.normalized()).to_matrix().to_4x4()
    temp = bmesh.new()
    bmesh.ops.create_cube(temp, size=1.0)
    local = (
        Matrix.Translation((a + b) / 2)
        @ rot
        @ Matrix.Rotation(twist, 4, "X")
        @ Matrix.Diagonal(Vector((length, width, thick))).to_4x4()
    )
    bmesh.ops.transform(temp, matrix=frame @ local, verts=temp.verts[:])
    _wr_emit(bm, temp)


def _wr_spar(bm, frame, p0, p1, r0, r1, sides=6):
    """A tapered round timber (mast, topmast, piling) between two local points."""
    a, b = Vector(p0), Vector(p1)
    d = b - a
    length = d.length
    if length < 1e-5:
        return
    temp = bmesh.new()
    bmesh.ops.create_cone(temp, cap_ends=True, cap_tris=False, segments=sides, radius1=r0, radius2=r1, depth=length)
    rot = Vector((0.0, 0.0, 1.0)).rotation_difference(d.normalized()).to_matrix().to_4x4()
    bmesh.ops.transform(temp, matrix=frame @ Matrix.Translation((a + b) / 2) @ rot, verts=temp.verts[:])
    _wr_emit(bm, temp)


def _wr_orb(bm, frame, p, r):
    """A small faceted ball - the ghost lanterns / sea-fire on the wrecks."""
    temp = bmesh.new()
    bmesh.ops.create_icosphere(temp, subdivisions=1, radius=r)
    bmesh.ops.transform(temp, matrix=frame @ Matrix.Translation(Vector(p)), verts=temp.verts[:])
    _wr_emit(bm, temp)


def _wr_mound(bm, center, scale, salt, yaw=0.0, roughness=0.16):
    """A smooth, long sand swell - a rounder sphere than the angular add_blob
    boulder, so drifted dune reads as dune and not as a shard of rock."""
    temp = bmesh.new()
    bmesh.ops.create_icosphere(temp, subdivisions=2, radius=1.0)
    for v in temp.verts:
        bump = noise.noise(v.co * 1.1 + Vector((salt, salt * 0.6, salt * 1.4)))
        v.co += v.co.normalized() * bump * roughness
    matrix = (
        Matrix.Translation(Vector(center))
        @ Matrix.Rotation(yaw, 4, "Z")
        @ Matrix.Diagonal(Vector(scale)).to_4x4()
    )
    bmesh.ops.transform(temp, matrix=matrix, verts=temp.verts[:])
    _wr_emit(bm, temp)


def _wr_panel(bm, frame, corners, thick=0.28):
    """A flat quad with a little thickness - one width of torn sailcloth.
    Corners are ship-local and given in order around the panel."""
    pts = [Vector(c) for c in corners]
    n = (pts[1] - pts[0]).cross(pts[3] - pts[0])
    if n.length < 1e-6:
        return
    n = n.normalized() * (thick / 2)
    temp = bmesh.new()
    top = [temp.verts.new(pt + n) for pt in pts]
    bot = [temp.verts.new(pt - n) for pt in pts]
    temp.faces.new(top)
    temp.faces.new(list(reversed(bot)))
    for i in range(4):
        j = (i + 1) % 4
        temp.faces.new((top[i], bot[i], bot[j], top[j]))
    bmesh.ops.recalc_face_normals(temp, faces=temp.faces[:])
    bmesh.ops.transform(temp, matrix=frame, verts=temp.verts[:])
    _wr_emit(bm, temp)


def _wr_stations(length, beam, depth, freeboard, n=9, bow_rise=1.0, fullness=1.0):
    """Cross-sections down a broken hull section: x=0 is the ragged break where
    the ship tore in half, x=length the bow point. Returns
    (x, half_beam, keel_z, sheer_z) - an elliptical waterplane, a keel that
    sweeps up into the forefoot, and a sheer line that lifts toward the bow."""
    out = []
    for i in range(n):
        t = i / (n - 1)
        hb = (beam / 2) * math.sqrt(max(0.015, 1.0 - t ** 2.4)) * (0.72 + 0.28 * fullness)
        keel = -depth + depth * 0.78 * t ** 2.4
        sheer = freeboard + freeboard * bow_rise * t ** 1.9
        out.append((t * length, hb, keel, sheer))
    return out


def _wr_hull_shell(bm, frame, stations, cap_break=True):
    """Loft the stations into a closed low-poly hull solid: eight-point rings
    (port sheer, turn of the bilge, keel, starboard, then back over the deck)
    stitched span by span. Solid, so it reads from inside the bay too."""

    def ring(st):
        x, hb, kz, sz = st
        h = sz - kz
        return [
            Vector((x, hb, sz)),
            Vector((x, hb * 0.94, kz + h * 0.36)),
            Vector((x, hb * 0.56, kz + h * 0.07)),
            Vector((x, 0.0, kz)),
            Vector((x, -hb * 0.56, kz + h * 0.07)),
            Vector((x, -hb * 0.94, kz + h * 0.36)),
            Vector((x, -hb, sz)),
            Vector((x, 0.0, sz + h * 0.05)),  # crowned deck centreline
        ]

    temp = bmesh.new()
    loops = []
    for st in stations:
        loops.append([temp.verts.new(p) for p in ring(st)])
    for i in range(len(loops) - 1):
        a, b = loops[i], loops[i + 1]
        for k in range(8):
            j = (k + 1) % 8
            try:
                temp.faces.new((a[k], a[j], b[j], b[k]))
            except ValueError:
                pass
    if cap_break:
        try:
            temp.faces.new(loops[0])
        except ValueError:
            pass
    try:
        temp.faces.new(list(reversed(loops[-1])))
    except ValueError:
        pass
    bmesh.ops.recalc_face_normals(temp, faces=temp.faces[:])
    bmesh.ops.transform(temp, matrix=frame, verts=temp.verts[:])
    _wr_emit(bm, temp)


def _wr_ribs(bm, frame, stations, span, rise, thick=0.6, glow_bm=None, glow_every=3):
    """The exposed ribcage: frames arcing up and inward off the sheer where the
    planking has rotted away. `span` is the (lo, hi) fraction of the hull they
    cover; `rise` how far above the sheer they reach."""
    lo, hi = span
    n = len(stations)
    for i, (x, hb, kz, sz) in enumerate(stations):
        t = i / (n - 1)
        if t < lo or t > hi:
            continue
        r = rise * (0.55 + 0.45 * math.sin(math.pi * (t - lo) / max(1e-3, hi - lo)))
        for side in (1, -1):
            prev = Vector((x, side * hb, sz - 0.3))
            for k in range(1, 4):
                f = k / 3
                nxt = Vector((x, side * hb * (1.0 - 0.30 * f * f), sz + r * f))
                _wr_beam(bm, frame, prev, nxt, thick, thick * 0.85)
                prev = nxt
            if glow_bm is not None and i % glow_every == 0:
                _wr_orb(glow_bm, frame, prev + Vector((0, 0, 0.25)), 0.55)


def _wr_gunwale_glow(glow_bm, frame, stations, lo=0.0, hi=1.0, lift=0.35):
    """A thin line of sea-fire running the sheer of a ghost ship - a drawn
    edge, not a speck."""
    n = len(stations)
    picked = [s for i, s in enumerate(stations) if lo <= i / (n - 1) <= hi]
    for side in (1, -1):
        for a, b in zip(picked, picked[1:]):
            p0 = Vector((a[0], side * a[1], a[3] + lift))
            p1 = Vector((b[0], side * b[1], b[3] + lift))
            _wr_beam(glow_bm, frame, p0, p1, 0.45, 0.30)


def _wr_mast(wood_bm, glow_bm, sail_bm, frame, base, lean, dir_ang, height, snapped=True, sail=0.0):
    """A leaning mast: lower stump, a snapped-off upper section carrying a yard,
    optional tattered sail, and a lantern at the head."""
    base = Vector(base)
    axis = Vector((math.sin(lean) * math.cos(dir_ang), math.sin(lean) * math.sin(dir_ang), math.cos(lean)))
    head = base + axis * height
    _wr_spar(wood_bm, frame, base, head, height * 0.055, height * 0.026, sides=6)
    # The yard, crossed near the head.
    perp = axis.cross(Vector((0, 0, 1)))
    if perp.length < 1e-4:
        perp = Vector((0, 1, 0))
    perp.normalize()
    yard_at = base + axis * (height * 0.72)
    half = height * 0.30
    y0 = yard_at + perp * half + Vector((0, 0, -half * 0.14))
    y1 = yard_at - perp * half + Vector((0, 0, half * 0.10))
    _wr_beam(wood_bm, frame, y0, y1, height * 0.030, height * 0.030)
    if sail > 0.0 and sail_bm is not None:
        # Canvas still bent to the yard: contiguous widths hanging off it with a
        # ragged hem and one width torn clean away, bellied off the mast so it
        # reads as one rotted sail rather than a row of chips.
        panels = 6
        bel = perp.cross(Vector((0, 0, 1)))
        belly = (bel.normalized() if bel.length > 1e-5 else Vector((0, 1, 0))) * (sail * 0.22)
        hem = [sail * random.uniform(0.55, 1.45) for _ in range(panels + 1)]
        gone = random.randrange(panels)
        for k in range(panels):
            if k == gone:
                continue
            a, b = y0.lerp(y1, k / panels), y0.lerp(y1, (k + 1) / panels)
            f0, f1 = (k + 0.5) / panels, (k + 1.5) / panels
            _wr_panel(sail_bm, frame, (
                a, b,
                b + belly * (1 - abs(2 * f1 - 1)) - Vector((0, 0, hem[k + 1])),
                a + belly * (1 - abs(2 * f0 - 1)) - Vector((0, 0, hem[k])),
            ), 0.30)
    if snapped:
        # The snapped topmast HINGES at the break: it starts just BELOW the
        # head so the two spars overlap. It used to start height*0.10 ABOVE
        # it, which left the topmast hanging in open air - the "random
        # floating objects" the user reported, 2026-08-29.
        broke = head - axis * (height * 0.03)
        tip = broke + Vector((axis.x, axis.y, 0)).normalized() * height * 0.30 - Vector((0, 0, height * 0.16))
        _wr_spar(wood_bm, frame, broke, tip, 0.4, 0.18, sides=4)
    if glow_bm is not None:
        _wr_orb(glow_bm, frame, head + Vector((0, 0, 0.7)), 0.9)


def _wr_bow_section(wood_bm, glow_bm, sail_bm, pos, yaw, pitch, length, beam, depth, ghost=True):
    """THE LANDMARK: a bow reared out of the lagoon, keel to the sky - hull
    shell, exposed ribs along the torn break, a bowsprit and its dolphin
    striker, and sea-fire down both gunwales."""
    frame = _wr_frame(pos, yaw=yaw, pitch=pitch)
    st = _wr_stations(length, beam, depth, freeboard=beam * 0.42, n=10, bow_rise=1.25)
    _wr_hull_shell(wood_bm, frame, st, cap_break=True)
    _wr_ribs(wood_bm, frame, st, (0.0, 0.45), rise=beam * 0.55, thick=0.7, glow_bm=glow_bm if ghost else None)
    # Bowsprit off the stem, plus the little vertical striker under it.
    tip = Vector((length * 1.34, 0.0, st[-1][3] + length * 0.10))
    stem = Vector((length * 0.96, 0.0, st[-1][3] - 0.4))
    _wr_spar(wood_bm, frame, stem, tip, 0.75, 0.28)
    _wr_beam(wood_bm, frame, Vector((length * 1.12, 0, st[-1][3] - 0.2)), Vector((length * 1.14, 0, st[-1][3] - 3.2)), 0.5, 0.5)
    # Wales: the heavy longitudinal strakes that break up a bare hull side.
    for wf, wl in ((0.30, 0.92), (0.62, 0.80)):
        for side in (1, -1):
            prev = None
            for i, (x, hb, kz, sz) in enumerate(st):
                if i / (len(st) - 1) > wl:
                    break
                p = Vector((x, side * hb * 1.02, kz + (sz - kz) * wf))
                if prev is not None:
                    _wr_beam(wood_bm, frame, prev, p, 0.8, 0.7)
                prev = p
    # A torn, jagged edge where the ship snapped in half.
    x0, hb0, kz0, sz0 = st[0]
    for k in range(7):
        f = -0.9 + 1.8 * (k / 6)
        _wr_beam(
            wood_bm, frame,
            (x0 + 0.2, f * hb0, sz0 - 0.4),
            (x0 - random.uniform(0.5, 2.5), f * hb0 * 0.97, sz0 + random.uniform(1.5, 5.5)),
            1.1, 0.8,
        )
    # Deck beams still spanning the open break.
    for f in (0.10, 0.22, 0.34):
        i = int(f * (len(st) - 1))
        x, hb, kz, sz = st[i]
        _wr_beam(wood_bm, frame, (x, hb * 0.95, sz - 0.2), (x, -hb * 0.95, sz - 0.2), 1.0, 0.55)
    if ghost:
        _wr_gunwale_glow(glow_bm, frame, st, lo=0.35, hi=1.0)
        _wr_orb(glow_bm, frame, tip + Vector((0, 0, -0.8)), 1.15)
    _wr_mast(wood_bm, glow_bm if ghost else None, sail_bm, frame, (length * 0.30, 0, st[3][3]), 0.28, math.pi, length * 0.85, snapped=True, sail=length * 0.16)
    return frame


def _wr_stern_section(wood_bm, glow_bm, sail_bm, pos, yaw, pitch, roll, length, beam, depth, ghost=True):
    """The other half of a ship: the stern, settled low and heeled, its transom
    and quarterdeck still standing over a rotted-open waist."""
    frame = _wr_frame(pos, yaw=yaw, pitch=pitch, roll=roll)
    st = _wr_stations(length, beam, depth, freeboard=beam * 0.46, n=8, bow_rise=0.15, fullness=1.2)
    _wr_hull_shell(wood_bm, frame, st, cap_break=True)
    _wr_ribs(wood_bm, frame, st, (0.45, 1.0), rise=beam * 0.5, thick=0.6, glow_bm=glow_bm if ghost else None)
    # The stern castle: a squat deckhouse rising off the transom end, its
    # walls carried down to the sheer so it sits ON the hull.
    x0, hb0, kz0, sz0 = st[0]
    house_l = length * 0.26
    house_h = beam * 0.52
    for side in (1, -1):  # side walls
        _wr_beam(wood_bm, frame, (x0 + 0.4, side * hb0 * 0.92, sz0 + house_h / 2),
                 (x0 + house_l, side * hb0 * 0.86, sz0 + house_h / 2), 1.0, house_h)
    _wr_beam(wood_bm, frame, (x0 + 0.4, hb0 * 0.92, sz0 + house_h / 2),
             (x0 + 0.4, -hb0 * 0.92, sz0 + house_h / 2), 1.0, house_h)  # transom face
    _wr_beam(wood_bm, frame, (x0 + 0.4, 0, sz0 + house_h), (x0 + house_l, 0, sz0 + house_h * 0.86),
             hb0 * 1.85, 0.9)  # quarterdeck roof, sagging forward
    # A snapped taffrail post at each quarter.
    for side in (1, -1):
        _wr_beam(wood_bm, frame, (x0 + 0.4, side * hb0 * 0.9, sz0 + house_h),
                 (x0 + 0.2, side * hb0 * 0.95, sz0 + house_h + beam * 0.22), 0.7, 0.7)
    if ghost:
        _wr_gunwale_glow(glow_bm, frame, st, lo=0.0, hi=0.6)
        for side in (1, -1):
            _wr_orb(glow_bm, frame, (x0 - 0.9, side * hb0 * 0.75, sz0 + beam * 0.74), 0.85)
    _wr_mast(wood_bm, glow_bm if ghost else None, sail_bm, frame, (length * 0.62, 0, st[5][3] - 0.5), 0.52, 0.6, length * 1.15, snapped=True, sail=length * 0.20)
    return frame


def _wr_ribcage(wood_bm, glow_bm, pos, yaw, pitch, roll, length, beam, depth):
    """A hull picked clean: keelson, stem and sternpost, and bare frames arcing
    out of the water. Pure silhouette, almost no surface."""
    frame = _wr_frame(pos, yaw=yaw, pitch=pitch, roll=roll)
    st = _wr_stations(length, beam, depth, freeboard=beam * 0.36, n=11, bow_rise=1.0)
    # Keel + keelson.
    _wr_beam(wood_bm, frame, (st[0][0], 0, st[0][2]), (st[-1][0], 0, st[-1][2]), beam * 0.22, 1.4)
    for side in (1, -1):
        prev = None
        for x, hb, kz, sz in st:
            p = Vector((x, side * hb * 0.95, sz))
            if prev is not None:
                _wr_beam(wood_bm, frame, prev, p, 1.1, 1.0)  # the wale, tying the frames
            prev = p
    _wr_ribs(wood_bm, frame, st, (0.05, 0.95), rise=beam * 0.78, thick=1.15, glow_bm=glow_bm, glow_every=2)
    # Stempost rearing at the bow end.
    x, hb, kz, sz = st[-1]
    _wr_beam(wood_bm, frame, (x - 1.0, 0, kz), (x + length * 0.10, 0, sz + beam * 0.75), 1.1, 1.1)
    _wr_gunwale_glow(glow_bm, frame, st, lo=0.2, hi=0.9, lift=0.5)
    return frame


def _wr_debris_pile(bm, x, y, surface, salt):
    """A crossed heap of drift timber - beached wreckage that reads at a
    distance instead of the old scatter of matchsticks."""
    rng = random.Random(salt)
    frame = _wr_frame((x, y, surface), yaw=rng.uniform(0, math.tau))
    n = rng.randint(3, 5)
    for k in range(n):
        a = rng.uniform(0, math.pi)
        L = rng.uniform(5.0, 11.0)
        h = 0.4 + k * 0.55
        p0 = Vector((math.cos(a) * -L / 2, math.sin(a) * -L / 2, h))
        p1 = Vector((math.cos(a) * L / 2, math.sin(a) * L / 2, h + rng.uniform(-0.6, 1.4)))
        _wr_beam(bm, frame, p0, p1, rng.uniform(0.8, 1.6), rng.uniform(0.4, 0.7), twist=rng.uniform(0, 1.0))
    if rng.random() < 0.5:  # a barrel rolled up with it
        _wr_spar(bm, frame, (rng.uniform(-3, 3), rng.uniform(-3, 3), 0.2), (rng.uniform(-3, 3), rng.uniform(-3, 3), 2.6), 1.5, 1.2, sides=8)


def _wr_in_channel(x, y, bay_r, half=16.0):
    """True inside the harbour cut - the boat lane from the sea into the lagoon.
    Nothing but water and the flanking quays may stand here."""
    a = math.radians(DOCK_ANGLE_DEG)
    along = x * math.cos(a) + y * math.sin(a)
    lateral = abs(-x * math.sin(a) + y * math.cos(a))
    return along > bay_r * 0.78 and lateral < half


_WR_EXTRA_GLOW = []  # (x, y, z, r) lanterns other wreck builders hand to the glow object
_WR_GLOW_SEATED = []  # entries already snapped onto their own builder's timber


def _wr_seat_glow(wood_bm, reach=12.0):
    """Seat every pending lantern ON the timber it belongs to.

    A hand-computed lantern position drifts the moment the spar it hangs on
    is tapered or rotated, and an orb lifted further than its own radius is
    a light hanging in mid-air - which is what the float guard rejects and
    what the island's rule forbids (every fitting meets its mount). So
    instead of tuning offsets per call site, snap: find the nearest point on
    the builder's wood, and if the orb is not already touching it, move it
    onto that point and leave it standing a little proud.

    A lantern further than `reach` from any timber is left alone - that is
    deliberate free-floating sea-fire (the two adrift on the bay), not a
    mistake."""
    if not _WR_EXTRA_GLOW:
        return
    tree = BVHTree.FromBMesh(wood_bm)
    for gx, gy, gz, gr in _WR_EXTRA_GLOW:
        at = Vector((gx, gy, gz))
        loc, _normal, _index, dist = tree.find_nearest(at, reach)
        if loc is None or dist is None or dist <= gr:
            _WR_GLOW_SEATED.append((gx, gy, gz, gr))
            continue
        away = at - loc
        away = away.normalized() if away.length > 1e-4 else Vector((0.0, 0.0, 1.0))
        seat = loc + away * (gr * 0.55)
        _WR_GLOW_SEATED.append((seat.x, seat.y, seat.z, gr))
    _WR_EXTRA_GLOW.clear()


def build_wreck_quay(ground):
    """Twin salvage-timber quays down either side of the harbour cut, from the
    dock head back onto the rim. They give standable footing on both banks of
    the cut (which is otherwise a drowned gully) and a clear walk off the dock,
    while leaving the middle of the cut - the boat lane into the lagoon -
    completely open water. Two objects: Wreckwater_Quay_Planks / _Posts."""
    plank_bm = bmesh.new()
    post_bm = bmesh.new()
    deck = DOCK_MIN_TOP  # flush with the dock deck, so you step straight across
    y_far, y_near = -190.0, -150.0  # Blender y = -(island-local Z)
    for side in (1, -1):
        x_in, x_out = side * 11.0, side * 30.0
        # Deck planking, laid across the quay with a couple of gaps rotted through.
        y = y_far
        i = 0
        while y < y_near:
            w = random.uniform(1.5, 2.2)
            if i % 9 != 4:  # every ninth plank is missing
                jitter = random.uniform(-0.5, 0.5)
                bpl = (x_in + x_out) / 2
                add_box(
                    plank_bm,
                    ((bpl + jitter), y + w / 2, deck - 0.35),
                    (abs(x_out - x_in) - random.uniform(0.0, 1.4), w, 0.7),
                )
            y += w + 0.3
            i += 1
        # Stringers under the deck, running the length of the quay.
        for sx in (x_in + side * 1.4, x_out - side * 1.4):
            add_box(plank_bm, (sx, (y_far + y_near) / 2, deck - 1.3), (1.6, y_near - y_far, 1.4))
        # Pilings.
        n = 6
        for k in range(n):
            py = y_far + (y_near - y_far) * (k / (n - 1))
            for px in (x_in + side * 1.4, x_out - side * 1.4):
                add_post(post_bm, px, py, -7.0, deck - 0.5, 1.15, sides=6)
        # A leaning lamp stake at the seaward corner of each quay.
        lx = x_out - side * 1.4
        add_post(post_bm, lx, y_far + 3.0, deck - 1.0, deck + 7.0, 0.7, sides=5)
        _WR_EXTRA_GLOW.append((lx, y_far + 3.0, deck + 7.8, 1.1))
    return (
        object_from_bmesh("Wreckwater_Quay_Planks", plank_bm, ["M_WreckPlank"]),
        object_from_bmesh("Wreckwater_Quay_Posts", post_bm, ["M_WreckPost"]),
    )


# ---- Wreckwater: the open-sea graveyard ----------------------------------
#
# Contracts for everything below. Sea level is z=0 and there is no ground out
# here, so a sea hulk is placed by hand at the waterline and sunk 1-4 studs
# instead of being dropped onto the terrain. The island's own props stop well
# inside r=280 (shore, surf foam and the boat-launch ring at ~240), and Roblox
# caps an imported model at 2048 studs per axis, so every sea hulk lives in
# the ring r=280..690 and NOTHING it grows may cross +-700 on any axis. The
# wedge +-28 deg around DOCK_ANGLE_DEG is the harbour approach - the boat lane
# and the water a player fishes from the quay - and stays completely empty.

_WR_SEA_BAND = (280.0, 690.0)
_WR_SEA_WEDGE = math.radians(28.0)
_WR_SEA_SHOALS = (  # (theta_deg, r, spread): the graveyard shoals the hulls pile onto
    # The inshore shoal, set opposite the dock (DOCK_ANGLE_DEG + 180) and drawn
    # in close: this is the one a player standing on the far shore actually
    # reads, so the biggest wrecks want to be here, not out on the horizon.
    (88.0, 340.0, 75.0),
    (168.0, 540.0, 85.0),
    # 60 deg off the dock line, so it clears the wedge outright; the gauss
    # jitter that does stray inside gets rejected by _wr_sea_clear.
    (332.0, 455.0, 65.0),
)
_WR_SEA_COUNT = 0  # hulks build_sea_wrecks laid down, for build_wreckwater's handoff line


def _wr_sea_clear(theta):
    """False inside the harbour approach - the wedge that stays wreck-free."""
    a = math.radians(DOCK_ANGLE_DEG)
    return abs(((theta - a + math.pi) % math.tau) - math.pi) > _WR_SEA_WEDGE


def _wr_sea_spot(reach, inward=None, tries=24):
    """A world (x, y, theta) anchor for a sea hulk: shoal-weighted (so the fleet
    clusters instead of sprinkling evenly), clear of the harbour approach, and
    pulled off both edges of the band so nothing drifts onto the shore or past
    the bbox cap. `reach` is how far the hulk grows SEAWARD of the anchor and
    `inward` how far it grows toward the island (defaulting to the same): a
    broken pair is lopsided - her bow lies just ahead of the anchor while the
    stern trails a long way astern - and clamping both ends by the larger
    number would push every pair off the inshore shoal. Module `random` only,
    since configure() reseeds it and determinism is a contract."""
    lo, hi = _WR_SEA_BAND
    inward = reach if inward is None else inward
    for _ in range(tries):
        if random.random() < 0.64:  # most of the fleet went down on a shoal
            t_deg, cr, spread = _WR_SEA_SHOALS[random.randrange(len(_WR_SEA_SHOALS))]
            theta = math.radians(t_deg) + random.gauss(0.0, 0.17)
            r = cr + random.gauss(0.0, spread)
        else:  # the loners, anywhere on the open sea
            theta = random.uniform(0.0, math.tau)
            r = random.uniform(lo, hi)
        if not _wr_sea_clear(theta):
            continue
        r = min(max(r, lo + inward), hi - reach)
        return math.cos(theta) * r, math.sin(theta) * r, theta
    return None


def _wr_sea_ribcage(bm, pos, yaw, pitch, roll, length, beam, rise):
    """A half-drowned rib ring: a keel with bare frames arcing out of the water
    off it. Deliberately far lighter than _wr_ribcage (no shell, no wales, no
    stempost) - at sea range this is pure silhouette, and there are several of
    them to pay for out of one triangle budget."""
    frame = _wr_frame(pos, yaw=yaw, pitch=pitch, roll=roll)
    _wr_beam(bm, frame, (-length / 2, 0, -beam * 0.20), (length / 2, 0, 0.0), beam * 0.20, 1.3)
    n = 5
    for i in range(n):
        t = i / (n - 1)
        x = -length / 2 + length * t
        hb = (beam / 2) * math.sqrt(max(0.06, 1.0 - (2 * t - 1) ** 2))
        r = rise * (0.5 + 0.5 * math.sin(math.pi * t))
        for side in (1, -1):
            mid = Vector((x, side * hb, r * 0.55))
            top = Vector((x, side * hb * 0.62, r))
            _wr_beam(bm, frame, (x, side * hb * 0.88, -beam * 0.16), mid, 0.9, 0.8)
            _wr_beam(bm, frame, mid, top, 0.8, 0.7)
    return frame


def build_sea_wrecks(ground):
    """The fleet that never made the harbour: 15 hulks strewn across the OPEN
    SEA all the way round the island, so the graveyard reads from any approach
    and not just from the lagoon. Three broken pairs (a bow and her matching
    stern on one line, snapped apart), heeled loner sterns, half-drowned rib
    rings and lone leaning masts, all sat at the waterline and sunk a couple of
    studs. `ground` is unused - out here there is nothing to sit on - but the
    signature matches the island's other builders.

    ORDERING CONTRACT: the sea-fire is handed to _WR_EXTRA_GLOW rather than
    drawn here, because this emits ONE wood object and the lanterns belong to
    Wreckwater_GhostGlow. build_wrecks drains that list, so build_sea_wrecks
    MUST run before it. One object: Wreckwater_SeaHulks (shares M_HullWood)."""
    global _WR_SEA_COUNT
    bm = bmesh.new()
    made = 0

    # SCALE. These are ocean-going ships, not ships' boats: a source hull runs
    # 45-75 studs, so a snapped half is 22-42 and her freeboard 6-10. Sizing is
    # triangle-free (the helpers emit the same face count at any scale), so the
    # fleet is read at distance purely by being big. Beam runs 0.44-0.52 of the
    # section length - the bay flagship's own proportion - because _wr_stations
    # derives freeboard from beam, and that ratio is what puts the sheer the
    # required 6-10 studs above the waterline.

    # 1. Broken pairs: one ship torn in two, her halves left on the same line
    #    25-60 studs apart. The bow rears bodily out of the water, the stern
    #    sits astern of the break, low and heeled hard over.
    for _ in range(3):
        # Lopsided reach: the bowsprit runs ~50 studs ahead of the anchor, the
        # gap plus the stern ~100 astern of it.
        spot = _wr_sea_spot(100.0, inward=52.0)
        if spot is None:
            continue
        x, y, theta = spot
        yaw = theta + math.pi + random.uniform(-0.55, 0.55)  # driven inshore, roughly
        d = Vector((math.cos(yaw), math.sin(yaw), 0.0))
        length = random.uniform(26.0, 38.0)
        # Floored, not just scaled: freeboard is beam*0.42 in _wr_stations, so a
        # beam under ~14.5 would leave the shortest sections sitting less than 6
        # studs out of the water however long they are.
        beam = max(14.5, length * random.uniform(0.44, 0.52))
        gap = random.uniform(25.0, 60.0)
        bow = _wr_bow_section(
            bm, None, None,
            pos=(x, y, -random.uniform(1.5, 3.5)), yaw=yaw,
            pitch=math.radians(random.uniform(18.0, 42.0)),
            length=length, beam=beam, depth=beam * 0.50, ghost=False,
        )
        _wr_stern_section(
            bm, None, None,
            pos=(x - d.x * gap, y - d.y * gap, -random.uniform(2.0, 4.0)),
            yaw=yaw + math.pi + random.uniform(-0.25, 0.25),
            pitch=math.radians(random.uniform(-10.0, 6.0)),
            roll=math.radians(random.choice((1, -1)) * random.uniform(22.0, 46.0)),
            length=length * 0.82, beam=beam * 0.90, depth=beam * 0.45, ghost=False,
        )
        # One lantern right out at the bowsprit tip - the highest point of the
        # pair, so the sea-fire crowns the silhouette instead of sitting in it.
        # (Local z of the tip is the bow sheer, freeboard*(1+bow_rise), plus the
        # bowsprit's own rise, which is how _wr_bow_section places it.)
        _WR_EXTRA_GLOW.append(
            tuple(bow @ Vector((length * 1.34, 0.0, beam * 0.95 + length * 0.10 + 2.0))) + (1.5,)
        )
        made += 2

    # 2. Loner sterns: a broken after-body heeled right over, no bow anywhere.
    for _ in range(2):
        spot = _wr_sea_spot(46.0)
        if spot is None:
            continue
        x, y, theta = spot
        length = random.uniform(24.0, 36.0)
        beam = max(14.5, length * random.uniform(0.44, 0.52))  # freeboard floor, as above
        _wr_stern_section(
            bm, None, None,
            pos=(x, y, -random.uniform(1.0, 3.5)),
            yaw=theta + random.uniform(-2.4, 2.4),
            pitch=math.radians(random.uniform(-12.0, 8.0)),
            roll=math.radians(random.choice((1, -1)) * random.uniform(26.0, 52.0)),
            length=length, beam=beam, depth=beam * 0.48, ghost=False,
        )
        made += 1

    # 3. Rib rings: hulls picked clean, frames breaking the surface like a
    #    fishbone. Half of them carry a lantern caught up in the frames.
    for k in range(4):
        spot = _wr_sea_spot(32.0)
        if spot is None:
            continue
        x, y, theta = spot
        length = random.uniform(34.0, 52.0)
        beam = length * random.uniform(0.30, 0.40)
        rise = beam * random.uniform(0.7, 1.05)
        z = -random.uniform(2.0, 4.0)
        frame = _wr_sea_ribcage(
            bm, (x, y, z), yaw=theta + random.uniform(0.0, math.tau),
            pitch=math.radians(random.uniform(-9.0, 9.0)),
            roll=math.radians(random.choice((1, -1)) * random.uniform(10.0, 34.0)),
            length=length, beam=beam, rise=rise,
        )
        if k % 2 == 0:
            # ON a rib, not floating in the arch between them: the ribcage is
            # picked clean, so its centreline is open air (the float guard
            # caught exactly this, 2026-08-29). Mirrors _wr_sea_ribcage's own
            # station maths so the orb meets the timber it hangs on.
            t = 0.68
            hb = (beam / 2) * math.sqrt(max(0.06, 1.0 - (2 * t - 1) ** 2))
            r_top = rise * (0.5 + 0.5 * math.sin(math.pi * t))
            _WR_EXTRA_GLOW.append(
                tuple(frame @ Vector((-length / 2 + length * t, hb * 0.62, r_top - 0.35))) + (1.3,)
            )
        made += 1

    # 4. Lone masts: nothing left above water but the rig, leaning up out of the
    #    sea with the ship still down there under it. Built here rather than
    #    through _wr_mast because these need heavier timber than a mast stepped
    #    on a visible hull - with no hull to give them scale, a helper-gauge spar
    #    reads as a twig at this distance. Spars are ~1.5x _wr_mast's taper and
    #    there are TWO crossyards, which is what makes the silhouette legible.
    for _ in range(3):
        spot = _wr_sea_spot(34.0)  # sin(lean)*h plus the snapped topmast beyond it
        if spot is None:
            continue
        x, y, theta = spot
        z = -random.uniform(1.0, 3.0)
        h = random.uniform(26.0, 37.0)  # 20-35 studs of it stands above water
        lean = random.uniform(0.18, 0.48)
        dir_ang = random.uniform(0.0, math.tau)
        frame = _wr_frame((x, y, z))  # unrotated: the lean/dir below aim the spar
        axis = Vector((math.sin(lean) * math.cos(dir_ang), math.sin(lean) * math.sin(dir_ang), math.cos(lean)))
        head = axis * h
        _wr_spar(bm, frame, (0, 0, 0), head, h * 0.083, h * 0.039, sides=6)
        perp = axis.cross(Vector((0, 0, 1)))
        perp = perp.normalized() if perp.length > 1e-4 else Vector((0, 1, 0))
        for yf, hf in ((0.70, 0.30), (0.44, 0.22)):  # main yard and a lower one
            at = axis * (h * yf)
            half = h * hf
            _wr_beam(
                bm, frame,
                at + perp * half + Vector((0, 0, -half * 0.12)),
                at - perp * half + Vector((0, 0, half * 0.09)),
                h * 0.045, h * 0.045,
            )
        broke = head - axis * (h * 0.03)  # the snapped-off topmast, hinged AT the break (never above it)
        tip = broke + Vector((axis.x, axis.y, 0)).normalized() * h * 0.30 - Vector((0, 0, h * 0.16))
        _wr_spar(bm, frame, broke, tip, h * 0.030, h * 0.014, sides=4)
        _WR_EXTRA_GLOW.append((x + head.x, y + head.y, z + head.z + 0.7, 1.35))  # overlaps the mast head
        made += 1

    made += build_wreck_mast_forest(bm)
    _wr_seat_glow(bm)  # the fleet's lanterns meet the fleet's timber

    _WR_SEA_COUNT = made
    return object_from_bmesh("Wreckwater_SeaHulks", bm, ["M_HullWood"])


def build_wrecks(ground):
    """The graveyard: a bow reared out of the lagoon as the island's landmark,
    its stern half foundered apart from it, a picked-clean ribcage, two hulks
    driven up onto the rim, and beached timber. Ghost ships carry the pale
    sea-fire the island is named for. Returns wood, glow and canvas objects."""
    wood_bm = bmesh.new()
    glow_bm = bmesh.new()
    sail_bm = bmesh.new()

    bay_r = LAVA_PONDS[0][2] if LAVA_PONDS else 96.0
    b = bay_r

    # 1. THE LANDMARK - the flagship. Reared bow on the camera-near flank of the
    #    bay, clear of both the boss disc (Blender 0,+20 r30) and the +Z entry
    #    channel. She is built a size up from the rest of the fleet and then
    #    dressed further below: the lagoon is the centrepiece of the island, so
    #    the detail goes onto THIS hull rather than into another hull crowding
    #    the water. Her reared length is held under b*0.8 so the bowsprit still
    #    ends inside the bay sheet.
    flag_len, flag_beam = b * 0.74, b * 0.33
    flag = _wr_bow_section(
        wood_bm, glow_bm, sail_bm,
        pos=(b * 0.34, -b * 0.20, -5.0), yaw=math.radians(-135), pitch=math.radians(37),
        length=flag_len, beam=flag_beam, depth=b * 0.145, ghost=True,
    )
    # Her stations, recomputed exactly as _wr_bow_section builds them, so the
    # extra carpentry lands on the same hull and not next to it.
    flag_st = _wr_stations(flag_len, flag_beam, b * 0.145, freeboard=flag_beam * 0.42, n=10, bow_rise=1.25)
    # Denser rib exposure: the helper only bares the frames over the torn break
    # (0.00-0.45), so carry them on up the reared midbody toward the stem.
    _wr_ribs(wood_bm, flag, flag_st, (0.45, 0.82), rise=flag_beam * 0.44, thick=0.55,
             glow_bm=glow_bm, glow_every=2)
    # A second line of sea-fire, lifted clear of the first, along the length the
    # helper's gunwale glow does not cover - she should read as a lit ship.
    _wr_gunwale_glow(glow_bm, flag, flag_st, lo=0.0, hi=0.42, lift=0.95)
    # A second, taller snapped mast with its own scrap of rotted canvas.
    _wr_mast(wood_bm, glow_bm, sail_bm, flag, (flag_len * 0.60, 0, flag_st[6][3] - 0.4),
             0.34, 0.55, flag_len * 1.18, snapped=True, sail=flag_len * 0.20)
    # 1b. Two lanterns adrift on the bay water itself, off her reared side -
    #     sea-fire floating free of any hull, which is what sells the lagoon as
    #     haunted rather than merely wrecked.
    _WR_EXTRA_GLOW.append((b * 0.10, -b * 0.52, 0.9, 1.15))
    _WR_EXTRA_GLOW.append((-b * 0.14, b * 0.30, 0.8, 0.95))

    # 2. Her stern half, settled and heeled well away across the bay.
    _wr_stern_section(
        wood_bm, glow_bm, sail_bm,
        pos=(-b * 0.38, -b * 0.46, -2.0), yaw=math.radians(126),
        pitch=math.radians(-8), roll=math.radians(28),
        length=b * 0.54, beam=b * 0.24, depth=b * 0.11, ghost=True,
    )

    # 3. The picked-clean ribcage, opposite side of the lagoon.
    _wr_ribcage(
        wood_bm, glow_bm,
        pos=(b * 0.42, b * 0.56, -3.2), yaw=math.radians(-58),
        pitch=math.radians(8), roll=math.radians(-15),
        length=b * 0.62, beam=b * 0.28, depth=b * 0.12,
    )

    # 3b. A snapped mainmast and its yard adrift across the shallows, half
    #     under water - it ties the two bay hulks together.
    drift = _wr_frame((-b * 0.62, b * 0.12, -0.6), yaw=math.radians(24))
    _wr_spar(wood_bm, drift, (-b * 0.26, 0, 0), (b * 0.26, 2.0, 1.6), 1.8, 0.8)
    _wr_beam(wood_bm, drift, (b * 0.06, -b * 0.13, 0.9), (b * 0.10, b * 0.13, 0.5), 1.0, 1.0)
    _wr_orb(glow_bm, drift, (b * 0.26, 2.0, 2.4), 1.0)

    # 4. A hulk driven right up onto the rim, heeled hard over. Seated on the
    #    real faceted ground so it never floats.
    beached = 0
    for theta_deg, u in ((38, 0.80), (150, 0.76), (322, 0.86)):
        theta = math.radians(theta_deg)
        r = ring_radius(u, theta)
        x, y = math.cos(theta) * r, math.sin(theta) * r
        surface = _drop_to_ground(ground, x, y)
        if surface is None:
            continue
        beached += 1
        _wr_stern_section(
            wood_bm, glow_bm if beached == 1 else None, sail_bm,
            pos=(x, y, surface - 1.6), yaw=theta + math.radians(122),
            pitch=math.radians(6), roll=math.radians(34 if beached % 2 else -30),
            length=b * 0.36, beam=b * 0.15, depth=b * 0.07, ghost=(beached == 1),
        )

    # 5. Half-buried frames and drift timber along the beach and rim.
    piles = 0
    for i in range(16):
        spot = _interior_spot(ground, 0.66, 0.97, pad=1.0, tries=10)
        if spot is None:
            continue
        x, y, surface = spot
        if _wr_in_channel(x, y, bay_r):
            continue
        _wr_debris_pile(wood_bm, x, y, surface, 900 + i * 17)
        piles += 1

    # Lone broken frames standing out of the sand - grave markers.
    for i in range(14):
        spot = _interior_spot(ground, 0.60, 0.94, pad=1.0, tries=8)
        if spot is None:
            continue
        x, y, surface = spot
        if _wr_in_channel(x, y, bay_r):
            continue
        frame = _wr_frame((x, y, surface - 0.5), yaw=random.uniform(0, math.tau))
        h = random.uniform(3.0, 7.5)
        lean = random.uniform(0.1, 0.45)
        _wr_beam(wood_bm, frame, (0, 0, 0), (math.sin(lean) * h, 0, math.cos(lean) * h), 0.8, 0.7)

    # 5b. The tide flat: the drained inner band between the lagoon and the rim
    #     is where the sea leaves the bones - half-buried frames, split planks
    #     and the odd stranded boat rib.
    dock_a = math.radians(DOCK_ANGLE_DEG)
    for i in range(22):
        theta = random.uniform(0, math.tau)
        if abs(((theta - dock_a + math.pi) % math.tau) - math.pi) < 0.34:
            continue  # the channel mouth stays clear
        u = random.uniform(0.50, 0.62)
        r = ring_radius(u, theta)
        x, y = math.cos(theta) * r, math.sin(theta) * r
        surface = _drop_to_ground(ground, x, y)
        if surface is None:
            continue
        frame = _wr_frame((x, y, surface - 0.8), yaw=random.uniform(0, math.tau))
        if i % 3 == 0:  # a stranded rib arc, still curved
            span = random.uniform(7.0, 14.0)
            rise = random.uniform(5.0, 11.0)
            prev = Vector((-span / 2, 0, 0))
            for k in range(1, 5):
                f = k / 4
                nxt = Vector((-span / 2 + span * f, 0, rise * math.sin(math.pi * f) * 1.1))
                _wr_beam(wood_bm, frame, prev, nxt, 1.0, 0.9)
                prev = nxt
        else:  # split planking pressed into the silt
            for k in range(random.randint(2, 4)):
                a = random.uniform(0, math.pi)
                L = random.uniform(4.0, 10.0)
                _wr_beam(
                    wood_bm, frame,
                    (math.cos(a) * -L / 2, math.sin(a) * -L / 2, 0.3 + k * 0.35),
                    (math.cos(a) * L / 2, math.sin(a) * L / 2, 0.5 + k * 0.35),
                    random.uniform(1.0, 1.8), 0.5, twist=random.uniform(0, 0.9),
                )

    # 6. The channel stakes: rotted harbour pilings marking the boat lane in
    #    from the sea, each capped with a ghost lantern. They read the entry
    #    channel as navigable AND carry the island's glow out to the dock.
    a = math.radians(DOCK_ANGLE_DEG)
    d = Vector((math.cos(a), math.sin(a), 0))
    perp = Vector((-d.y, d.x, 0))
    r_in, r_out = b * 0.86, ring_radius(1.06, a)
    stakes = 7
    for i in range(stakes):
        f = i / (stakes - 1)
        r = r_in + (r_out - r_in) * f
        for side in (1, -1):
            off = perp * (13.5 + 2.5 * math.sin(f * 4.0))
            x = d.x * r + off.x * side
            y = d.y * r + off.y * side
            top = random.uniform(3.4, 7.0)
            frame = _wr_frame((x, y, -7.0))
            lean = random.uniform(-0.10, 0.10)
            head = Vector((math.sin(lean) * (top + 7.0), 0.0, top + 7.0))
            _wr_spar(wood_bm, frame, (0, 0, 0), head, 1.15, 0.85)
            if i % 2 == 0:
                _wr_orb(glow_bm, frame, head + Vector((0, 0, 0.8)), 1.0)

    # 7. Grave lanterns along the rim: a leaning stake with sea-fire at the top,
    #    so the ring has the island's mood on it after dark too.
    for i in range(12):
        spot = _interior_spot(ground, 0.62, 0.95, pad=1.5, tries=8)
        if spot is None:
            continue
        x, y, surface = spot
        if _wr_in_channel(x, y, bay_r):
            continue
        frame = _wr_frame((x, y, surface - 0.6), yaw=random.uniform(0, math.tau))
        h = random.uniform(5.0, 8.5)
        lean = random.uniform(0.08, 0.3)
        head = Vector((math.sin(lean) * h, 0, math.cos(lean) * h))
        _wr_spar(wood_bm, frame, (0, 0, 0), head, 0.75, 0.5, sides=5)
        _wr_beam(wood_bm, frame, head, head + Vector((2.4, 0, 0.3)), 0.5, 0.4)
        _wr_orb(glow_bm, frame, head + Vector((2.4, 0, -0.9)), 1.05)

    _wr_seat_glow(wood_bm)
    for gx, gy, gz, gr in _WR_GLOW_SEATED:
        _wr_orb(glow_bm, _wr_frame((gx, gy, gz)), (0, 0, 0), gr)
    _WR_GLOW_SEATED.clear()

    print(f"[island_gen] wrecks: 3 in the bay + {beached} beached + {piles} debris piles")
    build_wreck_careened(wood_bm, ground)
    build_wreck_salvage(wood_bm, ground)
    build_wreck_gibbets(wood_bm, glow_bm, ground)

    return (
        object_from_bmesh("Wreckwater_Hulks", wood_bm, ["M_HullWood"]),
        object_from_bmesh("Wreckwater_GhostGlow", glow_bm, ["M_GhostGlow"]),
        object_from_bmesh("Wreckwater_Sails", sail_bm, ["M_WreckSail"]),
    )


def build_wreck_dunes(ground):
    """Long, low sand swells across the rim so the ring reads as drifted beach
    instead of a flat band. Same sand material as the base beach, so they melt
    into it. One object: Wreckwater_Dunes."""
    bm = bmesh.new()
    for i in range(18):
        spot = _interior_spot(ground, 0.72, 0.92, pad=2.0, tries=12)
        if spot is None:
            continue
        x, y, surface = spot
        if _wr_in_channel(x, y, ring_radius(0.46, math.atan2(y, x)), half=26.0):
            continue
        length = random.uniform(44.0, 80.0)
        width = random.uniform(26.0, 46.0)
        h = random.uniform(7.0, 13.0)
        # Run the swell along the shore, not up it.
        yaw = math.atan2(y, x) + math.pi / 2 + random.uniform(-0.6, 0.6)
        _wr_mound(bm, (x, y, surface - h * 0.56), (length / 2, width / 2, h), 1200 + i * 6.1, yaw=yaw)
    return object_from_bmesh("Wreckwater_Dunes", bm, ["M_WreckDrift"])


def build_wreck_rocks(ground):
    """Grave-grey stone: a reef of half-drowned stacks ringing the island
    outside the shoreline (the hazard that made this a wreck graveyard), sea
    stacks on the rim, and shore boulders."""
    bm = bmesh.new()
    dock_a = math.radians(DOCK_ANGLE_DEG)

    # The outer reef: clustered teeth just off the beach, mostly submerged.
    for i in range(30):
        theta = (i / 30) * math.tau + random.uniform(-0.06, 0.06)
        if abs(((theta - dock_a + math.pi) % math.tau) - math.pi) < 0.30:
            continue  # the boat lane in
        for k in range(random.randint(1, 3)):
            th = theta + random.uniform(-0.05, 0.05)
            u = random.uniform(1.015, 1.14)
            r = ring_radius(u, th)
            x, y = math.cos(th) * r, math.sin(th) * r
            surface = _drop_to_ground(ground, x, y)
            if surface is None:
                continue
            s = random.uniform(3.2, 8.5)
            top = random.uniform(0.8, 8.0)
            h = (top - surface) * random.uniform(0.5, 0.8)
            add_blob(bm, (x, y, surface + h * 0.40), (s, s * 0.8, h), 0.5, 300 + i * 3.7 + k, yaw=random.uniform(0, math.tau))

    # Sea stacks standing on the rim.
    for i in range(14):
        theta = (i / 14) * math.tau + random.uniform(-0.2, 0.2)
        if abs(((theta - dock_a + math.pi) % math.tau) - math.pi) < 0.35:
            continue
        u = random.uniform(0.56, 0.72)
        r = ring_radius(u, theta)
        x, y = math.cos(theta) * r, math.sin(theta) * r
        surface = _drop_to_ground(ground, x, y)
        if surface is None:
            continue
        s = random.uniform(4.5, 9.0)
        h = s * random.uniform(1.0, 1.9)
        add_blob(bm, (x, y, surface + h * 0.05), (s, s * 0.7, h), 0.44, 210 + i * 5.9, yaw=random.uniform(0, math.tau))

    # Shore boulders, seated into the sand.
    for i in range(26):
        spot = _interior_spot(ground, 0.6, 0.96, pad=1.5, tries=10)
        if spot is None:
            continue
        x, y, surface = spot
        s = random.uniform(1.8, 4.6)
        add_blob(bm, (x, y, surface - s * 0.34), (s, s * 0.85, s * 0.82), 0.46, 640 + i * 4.3, yaw=random.uniform(0, math.tau))
    return object_from_bmesh("Wreckwater_Rocks", bm, ["M_GraveRock"])



# ---- Wreckwater: the float guard ----------------------------------------
#
# NOTHING ON THIS ISLAND FLOATS. The guard clusters every authored primitive
# by proximity (a piece joins a cluster when its bounding box comes within
# FLOAT_PAD of another's - so a lantern on a sternpost, a flag on a yard or a
# lamp under a cabin roof inherits its ship's support) and then demands that
# each CLUSTER either reaches the water or rests on the terrain beneath it.
# A cluster hanging in open air raises, with coordinates - the slab_with_hole
# ruling: a warning in a 600-line build log is a warning nobody reads.
#
# `exempt` is a set of OBJECT NAMES skipped entirely - for deliberately
# suspended decor (the gloom island's circling glowfish, when this
# generalizes). It is an explicit, reviewable list, never a severity dial.

FLOAT_PAD = 1.5  # studs of slack when joining touching pieces
FLOAT_TOLERANCE = 1.5  # how far a cluster may sit above its support


def _float_components(obj):
    """Every connected primitive in an object, as (lo, hi) bounding boxes."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.verts.ensure_lookup_table()
    seen, out = set(), []
    for v in bm.verts:
        if v.index in seen:
            continue
        stack, pts = [v], []
        seen.add(v.index)
        while stack:
            cur = stack.pop()
            pts.append(cur.co)
            for e in cur.link_edges:
                n = e.other_vert(cur)
                if n.index not in seen:
                    seen.add(n.index)
                    stack.append(n)
        xs = [p.x for p in pts]
        ys = [p.y for p in pts]
        zs = [p.z for p in pts]
        out.append(((min(xs), min(ys), min(zs)), (max(xs), max(ys), max(zs))))
    bm.free()
    return out


def validate_keep_clear(objects, discs, exempt=(), label="island"):
    """Raise if any object puts geometry inside a reserved disc.

    The float guard cannot catch this: a barrel standing in the middle of an
    NPC's cabin is perfectly well seated. `discs` are (x, y, radius) in
    Blender coords; `exempt` is the set of object names ALLOWED inside them
    (the fixture itself, and the landform every island is made of)."""
    bad = []
    for obj in objects:
        if obj.name in exempt:
            continue
        for cx, cy, r in discs:
            worst = None
            for v in obj.data.vertices:
                d = math.hypot(v.co.x - cx, v.co.y - cy)
                if d < r and (worst is None or d < worst[0]):
                    worst = (d, v.co.x, v.co.y)
            if worst is not None:
                bad.append((obj.name, worst[0], r, worst[1], worst[2], cx, cy))
    if bad:
        lines = [
            f"[island_gen] {label}: {len(bad)} object(s) intruding on a reserved footprint",
            "             (an NPC house, a boss arena - geometry that is seated but is",
            "             standing where something else lives). Move the scatter's bands",
            "             or widen its keep-clear test.",
        ]
        for name, d, r, px, py, cx, cy in bad[:10]:
            lines.append(
                f"             {name}: a vertex {d:.1f} studs from ({cx:.0f}, {cy:.0f})"
                f" (reserved r={r:.0f}) at ({px:.1f}, {py:.1f})"
            )
        raise RuntimeError("\n".join(lines))
    print(f"[island_gen] {label}: keep-clear OK ({len(discs)} reserved disc(s) respected)")


def validate_no_floaters(objects, ground, exempt=(), label="island"):
    """Raise if any cluster of geometry hangs free of both water and ground."""
    comps = []
    for obj in objects:
        if obj.name in exempt:
            continue
        for lo, hi in _float_components(obj):
            comps.append((lo, hi, obj.name))

    parent = list(range(len(comps)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    # Bucket by cell so this stays linear-ish instead of comparing every pair.
    cell, buckets = 12.0, {}
    for i, (lo, hi, _n) in enumerate(comps):
        for cx in range(int((lo[0] - FLOAT_PAD) // cell), int((hi[0] + FLOAT_PAD) // cell) + 1):
            for cy in range(int((lo[1] - FLOAT_PAD) // cell), int((hi[1] + FLOAT_PAD) // cell) + 1):
                buckets.setdefault((cx, cy), []).append(i)

    def touches(a, b):
        la, ha, _ = comps[a]
        lb, hb, _ = comps[b]
        for k in range(3):
            if la[k] - FLOAT_PAD > hb[k] or lb[k] - FLOAT_PAD > ha[k]:
                return False
        return True

    for idxs in buckets.values():
        for ii in range(len(idxs)):
            for jj in range(ii + 1, len(idxs)):
                a, b = idxs[ii], idxs[jj]
                ra, rb = find(a), find(b)
                if ra != rb and touches(a, b):
                    parent[rb] = ra

    clusters = {}
    for i in range(len(comps)):
        clusters.setdefault(find(i), []).append(i)

    bad = []
    for members in clusters.values():
        z_min = min(comps[i][0][2] for i in members)
        if z_min <= 0.2:  # in the water: supported
            continue
        support = None
        for i in members:
            lo, hi, _n = comps[i]
            for px, py in ((lo[0], lo[1]), (hi[0], hi[1]), ((lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2)):
                gz = _drop_to_ground(ground, px, py)
                if gz is not None:
                    support = gz if support is None else max(support, gz)
        gap = z_min - support if support is not None else z_min
        if gap > FLOAT_TOLERANCE:
            names = sorted({comps[i][2] for i in members})
            cx = sum((comps[i][0][0] + comps[i][1][0]) / 2 for i in members) / len(members)
            cy = sum((comps[i][0][1] + comps[i][1][1]) / 2 for i in members) / len(members)
            bad.append((gap, z_min, cx, cy, len(members), names))

    if bad:
        bad.sort(key=lambda b: -b[0])
        lines = [
            f"[island_gen] {label}: {len(bad)} FLOATING cluster(s) - geometry hanging free of",
            "             both the waterline and the ground under it. Seat it, attach it to",
            "             something that IS seated, or (for deliberate decor) add its object",
            "             name to the builder's float-exempt set.",
        ]
        for gap, z_min, cx, cy, n, names in bad[:12]:
            lines.append(
                f"             gap {gap:6.1f} studs  bottom z={z_min:7.2f}  at (x={cx:7.1f}, y={cy:7.1f})"
                f"  {n} piece(s)  {', '.join(names)}"
            )
        raise RuntimeError("\n".join(lines))
    print(f"[island_gen] {label}: float guard OK ({len(clusters)} clusters, none hanging)")


# ---- Wreckwater: the dressing (2026-08-29) -------------------------------
#
# The graveyard given somewhere to LOOK: a drowned mast forest off the
# seaward shoal, an anchor graveyard rusting on the beach, a careened hull
# propped on its side above the tideline, the wreckers' salvage camp, and
# gibbet posts flanking the harbour mouth. Everything seats on the real
# faceted ground, keeps out of the bay and the harbour lane, and stays clear
# of the NPC house fixture (_WR_KEEP_CLEAR).

# Island-relative fixtures other lanes own; the dressing builds AROUND these.
# Hollow's beached sterncastle (f9's lane) - Roblox rel (-11, +146) with the
# usual y = -Z mapping, plus margin. Re-key from f9's HANDOFF if it moves.
# Roblox rel (-55, +175) r26 from the house's own HANDOFF (f9's lane), in
# Blender coords (y = -Z). Their number exactly: the sterncastle is sited
# AMONG the pre-existing beached wreckage on purpose (it is a beached
# sterncastle), so this disc keeps NEW dressing out - it is not a claim that
# the ground was empty. Re-key from that HANDOFF if the house moves.
_WR_KEEP_CLEAR = [(-55.0, -175.0, 26.0)]

# Object names the float guard skips. Nothing on this island is meant to
# hover, so this stays EMPTY - it exists as the reviewable opt-out other
# islands will need (the gloom lighthouse's circling glowfish).
WRECK_FLOAT_EXEMPT = frozenset()


def _wr_clear_of_fixtures(x, y, pad=0.0):
    for cx, cy, r in _WR_KEEP_CLEAR:
        if (x - cx) ** 2 + (y - cy) ** 2 < (r + pad) ** 2:
            return False
    return True


def _wr_shore_spot(ground, u_lo, u_hi, theta_lo_deg, theta_hi_deg, pad=8.0, tries=40):
    """A raycast-seated point on the island's shore band, clear of the harbour
    lane, the bay and every fixture."""
    for _ in range(tries):
        theta = math.radians(random.uniform(theta_lo_deg, theta_hi_deg))
        u = random.uniform(u_lo, u_hi)
        if _near_dock_corridor(theta, u):
            continue
        r = ring_radius(u, theta)
        x, y = math.cos(theta) * r, math.sin(theta) * r
        if not _wr_clear_of_fixtures(x, y, pad):
            continue
        if not _clear_of_ponds(x, y, pad):
            continue
        z = _drop_to_ground(ground, x, y)
        if z is not None and z > 0.4:
            return x, y, z
    return None



def _wr_anchor(bm, x, y, z, size, yaw, lean):
    """One admiralty anchor, half-buried: shank, crown arms with flukes, the
    stock across the head, and the ring. Sunk `size*0.18` so it reads as
    settled into the sand rather than dropped on it."""
    frame = _wr_frame((x, y, z - size * 0.18), yaw=yaw, pitch=lean)
    _wr_beam(bm, frame, (0, 0, 0), (0, 0, size), size * 0.085, size * 0.085)
    for side in (1, -1):
        elbow = (0, side * size * 0.40, size * 0.26)
        _wr_beam(bm, frame, (0, 0, size * 0.05), elbow, size * 0.07, size * 0.07)
        _wr_beam(bm, frame, elbow, (0, side * size * 0.50, size * 0.44), size * 0.12, size * 0.045)
    _wr_beam(bm, frame, (0, -size * 0.28, size * 0.88), (0, size * 0.28, size * 0.88), size * 0.06, size * 0.06)
    _wr_spar(bm, frame, (0, 0, size * 0.90), (0, 0, size * 1.02), size * 0.05, size * 0.05, sides=6)


def build_wreck_ironwork(ground):
    """The anchor graveyard: giant admiralty anchors rusting along the beach
    where the wreckers dragged them clear, plus the mooring chains still
    running from two of them down into the water. One object,
    Wreckwater_Ironwork (M_WreckIron)."""
    bm = bmesh.new()
    made = 0
    for _ in range(9):
        spot = _wr_shore_spot(ground, 0.86, 0.99, 20.0, 250.0, pad=10.0)
        if spot is None:
            continue
        x, y, z = spot
        size = random.uniform(13.0, 21.0)
        yaw = random.uniform(0.0, math.tau)
        lean = math.radians(random.uniform(38.0, 84.0))  # toppled over, not standing
        _wr_anchor(bm, x, y, z, size, yaw, lean)
        made += 1
        # Two of them still have their cable, running down into the sea.
        if made % 4 == 0:
            theta = math.atan2(y, x)
            out = Vector((math.cos(theta), math.sin(theta), 0))
            frame = _wr_frame((x, y, z + 1.0))
            prev = Vector((0, 0, 0))
            for k in range(1, 9):
                nxt = out * (k * 5.5) - Vector((0, 0, k * k * 0.28))
                nxt = Vector((nxt.x, nxt.y, max(nxt.z, -(z + 3.0))))
                _wr_beam(bm, frame, prev, nxt, 1.5 if k % 2 else 0.6, 0.6 if k % 2 else 1.5)
                prev = nxt
    print(f"[island_gen] HANDOFF wreckwater: {made} shore anchors")
    return object_from_bmesh("Wreckwater_Ironwork", bm, ["M_WreckIron"])


def build_wreck_mast_forest(bm):
    """The drowned forest: a shoal seaward of the island where a dozen masts
    still stand out of the water, yards crossed, with nothing left below.
    Appended into the SeaHulks bmesh (same timber), so it costs no new object.
    Every spar runs from below the waterline up - they are sunk ships, and the
    float guard holds them to it."""
    made = 0
    for i in range(13):
        theta = math.radians(random.uniform(28.0, 96.0)) + random.gauss(0.0, 0.05)
        r = random.uniform(252.0, 330.0)
        x, y = math.cos(theta) * r, math.sin(theta) * r
        z = -random.uniform(2.5, 5.0)
        h = random.uniform(17.0, 34.0)
        lean = random.uniform(0.06, 0.34)
        dir_ang = random.uniform(0.0, math.tau)
        frame = _wr_frame((x, y, z))
        axis = Vector((math.sin(lean) * math.cos(dir_ang), math.sin(lean) * math.sin(dir_ang), math.cos(lean)))
        head = axis * h
        _wr_spar(bm, frame, (0, 0, 0), head, h * 0.075, h * 0.035, sides=6)
        perp = axis.cross(Vector((0, 0, 1)))
        perp = perp.normalized() if perp.length > 1e-4 else Vector((0, 1, 0))
        if i % 3 != 2:  # most still carry a yard
            at = axis * (h * random.uniform(0.56, 0.78))
            half = h * random.uniform(0.20, 0.30)
            _wr_beam(
                bm, frame,
                at + perp * half + Vector((0, 0, -half * 0.10)),
                at - perp * half + Vector((0, 0, half * 0.08)),
                h * 0.040, h * 0.040,
            )
        made += 1
    return made


def build_wreck_careened(wood_bm, ground):
    """A hull hauled out and rolled onto her side above the tideline for a
    repair nobody finished - propped on shore timbers, her open flank a
    walk-through arch. The island's one piece of ship you meet on FOOT."""
    spot = _wr_shore_spot(ground, 0.80, 0.90, 120.0, 200.0, pad=26.0, tries=60)
    if spot is None:
        return
    x, y, z = spot
    theta = math.atan2(y, x)
    length = random.uniform(46.0, 58.0)
    beam = length * 0.42
    roll = math.radians(random.uniform(66.0, 80.0))  # careened: down on her flank
    frame = _wr_frame((x, y, z + beam * 0.30), yaw=theta + math.pi / 2, pitch=math.radians(-4.0), roll=roll)
    st = _wr_stations(length, beam, beam * 0.46, freeboard=beam * 0.40, n=9, bow_rise=0.9)
    _wr_hull_shell(wood_bm, frame, st, cap_break=True)
    _wr_ribs(wood_bm, frame, st, (0.10, 0.62), rise=beam * 0.42, thick=0.7)
    # Shore props: heavy timbers wedged from the sand into her exposed side,
    # each one seated on the real ground so the whole assembly is supported.
    for k in range(5):
        t = 0.16 + 0.16 * k
        i = min(len(st) - 1, int(t * (len(st) - 1)))
        head = frame @ Vector((st[i][0], -st[i][1] * 0.95, st[i][3] * 0.30))
        foot_x = head.x + math.cos(theta) * random.uniform(7.0, 12.0)
        foot_y = head.y + math.sin(theta) * random.uniform(7.0, 12.0)
        foot_z = _drop_to_ground(ground, foot_x, foot_y)
        if foot_z is None:
            continue
        ident = Matrix.Identity(4)
        _wr_beam(wood_bm, ident, (foot_x, foot_y, foot_z - 0.6), (head.x, head.y, head.z), 1.5, 1.5)
    print(f"[island_gen] HANDOFF wreckwater: careened hull at ({x:.0f}, {y:.0f})")


def build_wreck_salvage(wood_bm, ground):
    """The wreckers' camp: what came off the hulls and never went anywhere -
    crate stacks, barrels on their sides, coiled cable and a capstan, spread
    over the rim above the quay. Appended into the hulk timber."""
    made = 0
    for _ in range(16):
        spot = _wr_shore_spot(ground, 0.68, 0.86, 200.0, 340.0, pad=12.0)
        if spot is None:
            continue
        x, y, z = spot
        pick = random.random()
        ident = Matrix.Identity(4)
        if pick < 0.42:  # a crate stack
            n = random.randint(1, 3)
            for k in range(n):
                sz = random.uniform(2.6, 4.4) * (1.0 - 0.12 * k)
                add_box(
                    wood_bm,
                    (x + random.uniform(-1.2, 1.2), y + random.uniform(-1.2, 1.2), z + sz / 2 + k * sz * 0.92),
                    (sz, sz * random.uniform(0.85, 1.15), sz),
                    yaw=random.uniform(0, math.tau),
                )
        elif pick < 0.72:  # barrels, most on their sides
            for _k in range(random.randint(1, 3)):
                bx = x + random.uniform(-3.0, 3.0)
                by = y + random.uniform(-3.0, 3.0)
                bz = _drop_to_ground(ground, bx, by)
                if bz is None:
                    continue
                rr = random.uniform(1.3, 1.9)
                if random.random() < 0.6:
                    a = random.uniform(0, math.tau)
                    frame = _wr_frame((bx, by, bz + rr))
                    _wr_spar(wood_bm, frame, (-math.cos(a) * rr * 1.5, -math.sin(a) * rr * 1.5, 0),
                             (math.cos(a) * rr * 1.5, math.sin(a) * rr * 1.5, 0), rr, rr * 0.86, sides=8)
                else:
                    add_post(wood_bm, bx, by, bz, bz + rr * 2.6, rr, sides=8)
        elif pick < 0.88:  # a coil of cable
            frame = _wr_frame((x, y, z + 0.35))
            for k in range(3):
                rr = 2.6 - k * 0.55
                seg = 9
                for sgi in range(seg):
                    a0 = (sgi / seg) * math.tau
                    a1 = ((sgi + 1) / seg) * math.tau
                    _wr_beam(
                        wood_bm, frame,
                        (math.cos(a0) * rr, math.sin(a0) * rr, k * 0.55),
                        (math.cos(a1) * rr, math.sin(a1) * rr, k * 0.55),
                        0.55, 0.5,
                    )
        else:  # a capstan, still standing
            add_post(wood_bm, x, y, z - 0.5, z + 3.2, 1.5, sides=8)
            frame = _wr_frame((x, y, z + 3.0))
            for k in range(4):
                a = k * math.pi / 2 + random.uniform(-0.2, 0.2)
                _wr_beam(wood_bm, frame, (0, 0, 0), (math.cos(a) * 4.2, math.sin(a) * 4.2, -0.3), 0.7, 0.7)
        made += 1
    print(f"[island_gen] HANDOFF wreckwater: {made} salvage piles")


def build_wreck_gibbets(wood_bm, glow_bm, ground):
    """Two warning posts flanking the harbour mouth, cross-armed like gibbets,
    a chain swinging off each arm with a lantern at its end - the last thing a
    ship saw. Placed on the notch bearing, one to each side of the channel."""
    a = math.radians(DOCK_ANGLE_DEG)
    d = Vector((math.cos(a), math.sin(a), 0.0))
    perp = Vector((-d.y, d.x, 0.0))
    made = 0
    for side in (1, -1):
        for attempt in range(14):
            r = ring_radius(0.97 - attempt * 0.02, a)
            base = d * r + perp * (side * random.uniform(22.0, 40.0))
            z = _drop_to_ground(ground, base.x, base.y)
            if z is None or z < 0.6:
                continue
            if not _wr_clear_of_fixtures(base.x, base.y, 14.0):
                continue
            h = random.uniform(15.0, 19.0)
            frame = _wr_frame((base.x, base.y, z - 0.8), yaw=math.atan2(perp.y, perp.x))
            _wr_beam(wood_bm, frame, (0, 0, 0), (0, 0, h), 1.5, 1.5)
            arm = h * 0.30
            _wr_beam(wood_bm, frame, (0, 0, h * 0.94), (0, -side * arm, h * 0.90), 1.0, 1.0)
            # The chain, hanging to a lantern - each link meets the last.
            prev = Vector((0, -side * arm, h * 0.90))
            for k in range(4):
                nxt = prev - Vector((0, 0, 1.5))
                _wr_beam(wood_bm, frame, prev, nxt, 0.9 if k % 2 else 0.4, 0.4 if k % 2 else 0.9)
                prev = nxt
            _wr_orb(glow_bm, frame, prev - Vector((0, 0, 0.5)), 1.1)
            made += 1
            break
    print(f"[island_gen] HANDOFF wreckwater: {made} harbour gibbets")


# ---- Wreckwater: Quartermaster Hollow's beached sterncastle ---------------
#
# The intact STERN of a galleon, snapped off her waist and driven upright onto
# the beach west of the harbour cut: transom in the wash with the ship's name
# still half-legible on it and a ghost-green lantern over the taffrail, the
# torn break facing back up the beach so the captain's cabin behind it can be
# walked straight into. Hollow keeps the fleet's books at a gangplank counter
# beside that breach, crated and netted wares stacked around him.
#
# She is built from the island's own ship carpentry (_wr_frame/_wr_beam/
# _wr_spar/_wr_panel/_wr_hull_shell/_wr_ribs/_wr_gunwale_glow) so she reads as
# one of the fleet; the _hut_hollow_* pieces below are only the things a hulk
# never needed - an inner cabin lining (the shared hull shell is a SINGLE SKIN,
# so from inside you would see straight through it), a sole, a deckhead, and
# the office furniture.
#
# TWO RULES this builder holds itself to:
#   1. SEATED, NEVER HARDCODED. Every world height comes from the region's
#      ground probe (_drop_to_ground, with the analytic height_at as the
#      fallback), so a terrain reshape re-seats the whole ship automatically.
#   2. NOTHING FLOATS. Every piece is buried in the sand, rests on probed
#      ground, or overlaps the piece it hangs from - lantern to bracket, flag
#      to staff, cabin lamp to deckhead, crates and net to the beach,
#      gangplank to both hull and ground.

HOLLOW_BREACH = (-46.0, -166.0)  # Blender (x, y) of the torn end - Roblox rel X=-46 Z=166
HOLLOW_YAW_DEG = -133.5  # ship-local +X runs breach -> transom, i.e. down the beach
HOLLOW_LENGTH = 26.0
HOLLOW_PITCH_DEG = -2.5  # settled transom-down, into the wash
HOLLOW_ROLL_DEG = 4.0  # a little heel, so she is not a museum piece
HOLLOW_SOLE = 0.0  # cabin sole, ship-local z
HOLLOW_DECK = 9.0  # deckhead underside over the cabin (9 studs of headroom)
HOLLOW_DOOR_HALF = 4.2  # the breach opening is 8.4 wide x 8.2 tall
HOLLOW_KEEP_R = 26.0  # keep-clear radius other builders should respect


def _hut_hollow_stations(length=HOLLOW_LENGTH, n=7):
    """Cross-sections of the stern section, x=0 at the torn break and x=length
    at the transom. Unlike the shared _wr_stations (which tapers to a bow
    POINT) the run aft only tucks - a galleon's stern is full-bodied and ends
    in a flat transom, which is what gives the cabin its floor."""
    out = []
    for i in range(n):
        t = i / (n - 1)
        hb = 8.6 - 2.1 * t * t  # half beam: full amidships, tucking aft
        keel = -6.0 + 2.8 * t * t  # the run sweeping up under the counter
        sheer = 9.0 + 3.2 * t ** 1.6  # the sheer climbing to the quarterdeck
        out.append((t * length, hb, keel, sheer))
    return out


def _hut_hollow_box(bm, frame, center, size, yaw=0.0):
    """A squared box in SHIP-LOCAL space - lining planks, sole, shelves,
    crates, furniture. (add_box is world-space and axis-aligned; everything in
    this cabin is pitched and heeled with the hull.)"""
    temp = bmesh.new()
    bmesh.ops.create_cube(temp, size=1.0)
    local = Matrix.Translation(Vector(center)) @ Matrix.Rotation(yaw, 4, "Z") @ Matrix.Diagonal(Vector(size)).to_4x4()
    bmesh.ops.transform(temp, matrix=frame @ local, verts=temp.verts[:])
    _wr_emit(bm, temp)


def _hut_hollow_hb(stations, x):
    """Half beam at any x down the section (linear between stations)."""
    for a, b in zip(stations, stations[1:]):
        if a[0] <= x <= b[0]:
            f = (x - a[0]) / max(1e-5, b[0] - a[0])
            return a[1] + (b[1] - a[1]) * f
    return stations[-1][1] if x > stations[-1][0] else stations[0][1]


def _hut_hollow_ground(ground, x, y):
    """Probed ground height, falling back on the analytic terrain (the two
    agree to ~0.05 on the rim). NEVER a literal: a terrain reshape moves the
    ship with it."""
    z = _drop_to_ground(ground, x, y)
    return height_at(x, y) if z is None else z


def build_wreck_sterncastle(ground):
    """Quartermaster Hollow's office: a galleon's stern beached upright, walked
    into through the hull breach. Five objects, Wreckwater_Hut_Walls / _Roof /
    _Props / _Canvas / _Glow."""
    rng = random.Random(7719)  # own stream: the island's shared scatter is untouched
    walls = bmesh.new()  # hull shell, lining, breach framing, transom
    roof = bmesh.new()  # sole, deckhead, quarterdeck, gangplank, counter
    props = bmesh.new()  # furniture, crates, lantern cages, bell-and-tackle
    canvas = bmesh.new()  # flag, charts, window panes, cargo net
    glow = bmesh.new()  # sea-fire: gunwales, ribs, sternpost lantern, cabin lamp

    bx, by = HOLLOW_BREACH
    yaw = math.radians(HOLLOW_YAW_DEG)
    pitch = math.radians(HOLLOW_PITCH_DEG)
    fwd = (math.cos(yaw), math.sin(yaw))  # breach -> transom, down the beach
    up_beach = (-fwd[0], -fwd[1])
    port = (-math.sin(yaw), math.cos(yaw))
    st = _hut_hollow_stations()
    L = HOLLOW_LENGTH

    # --- SEATING. The sole sits a stride above the sand at the break; the
    #     keel is then checked against probed ground the whole length so no
    #     part of her can end up hanging in the air over the falling beach.
    ground_breach = _hut_hollow_ground(ground, bx, by)
    pos_z = ground_breach + 0.9 - HOLLOW_SOLE
    for i in range(9):
        t = i / 8
        gx, gy = bx + fwd[0] * L * t, by + fwd[1] * L * t
        keel = -6.0 + 2.8 * t * t - L * t * math.sin(-pitch)
        cap = _hut_hollow_ground(ground, gx, gy) - 0.6 - keel
        pos_z = min(pos_z, cap)  # bury the keel everywhere, never float it
    frame = _wr_frame((bx, by, pos_z), yaw=yaw, pitch=pitch, roll=math.radians(HOLLOW_ROLL_DEG))
    world = _wr_frame((0.0, 0.0, 0.0))  # identity: for the pieces that sit on sand

    def wpt(p):
        return frame @ Vector(p)

    # --- 1. THE HULL. Single-skin shell, break end left OPEN (cap_break=False)
    #     - that hole IS the door - then the fleet's rib/wale/sea-fire dress.
    _wr_hull_shell(walls, frame, st, cap_break=False)
    _wr_ribs(walls, frame, st, (0.0, 0.34), rise=5.0, thick=0.62, glow_bm=glow, glow_every=1)
    for wf in (0.32, 0.66):  # the wales: heavy strakes breaking up the hull side
        for side in (1, -1):
            prev = None
            for x, hb, kz, sz in st:
                p = Vector((x, side * hb * 1.02, kz + (sz - kz) * wf))
                if prev is not None:
                    _wr_beam(walls, frame, prev, p, 0.85, 0.7)
                prev = p
    _wr_gunwale_glow(glow, frame, st, lo=0.15, hi=1.0, lift=0.0)  # lift 0: the line sits ON the sheer

    # --- 2. THE BREACH. Torn planking around a clear 8.4 x 8.2 doorway: broken
    #     stubs raking out of the tear, side panels closing the quarters, a
    #     deck beam as the lintel.
    hb0, kz0, sz0 = st[0][1], st[0][2], st[0][3]
    for k in range(9):
        f = -1.0 + 2.0 * (k / 8)
        if abs(f * hb0) < HOLLOW_DOOR_HALF + 0.6:
            continue  # the doorway itself stays clear
        _wr_beam(
            walls, frame,
            (0.3, f * hb0 * 0.99, sz0 - rng.uniform(0.6, 2.4)),
            (-rng.uniform(0.6, 2.6), f * hb0 * 0.95, sz0 + rng.uniform(1.2, 4.6)),
            1.0, 0.75,
        )
    for side in (1, -1):  # the quarters either side of the door, planked in
        y_mid = side * (HOLLOW_DOOR_HALF + (hb0 - HOLLOW_DOOR_HALF) / 2)
        _hut_hollow_box(walls, frame, (0.55, y_mid, (HOLLOW_SOLE + sz0) / 2),
                        (1.1, hb0 - HOLLOW_DOOR_HALF, sz0 - HOLLOW_SOLE))
    _wr_beam(walls, frame, (0.55, -HOLLOW_DOOR_HALF - 0.4, 8.55), (0.55, HOLLOW_DOOR_HALF + 0.4, 8.55), 1.2, 0.8)
    for side in (1, -1):  # door posts, so the tear reads as a framed way in
        _wr_beam(walls, frame, (0.4, side * (HOLLOW_DOOR_HALF + 0.35), HOLLOW_SOLE),
                 (0.4, side * (HOLLOW_DOOR_HALF + 0.35), 8.6), 0.8, 0.7)

    # --- 3. THE CABIN SHELL: ceiling planking down both sides (the hull is one
    #     skin - without this the cabin has no inside), a plank sole, deck
    #     beams and the deckhead over them.
    n_lin = 9
    for i in range(n_lin):
        x = 1.4 + (L - 3.2) * (i / (n_lin - 1))
        hb = _hut_hollow_hb(st, x)
        for side in (1, -1):
            _hut_hollow_box(walls, frame, (x, side * (hb - 0.55), (HOLLOW_SOLE + HOLLOW_DECK) / 2 + 0.2),
                            ((L - 3.2) / (n_lin - 1) + 0.35, 0.6, HOLLOW_DECK - HOLLOW_SOLE + 0.4))
    for i in range(7):  # the sole, laid athwartships in broad planks
        x = 0.6 + (L - 1.6) * (i / 6)
        hb = _hut_hollow_hb(st, x)
        _hut_hollow_box(roof, frame, (x, 0.0, HOLLOW_SOLE - 0.35), ((L - 1.6) / 6 + 0.25, hb * 1.94, 0.7))
    for i in range(6):  # deck beams, then the deckhead planking on top of them
        x = 2.0 + (L - 4.5) * (i / 5)
        hb = _hut_hollow_hb(st, x)
        _wr_beam(roof, frame, (x, -hb * 0.92, HOLLOW_DECK - 0.25), (x, hb * 0.92, HOLLOW_DECK - 0.25), 0.9, 0.5)
    _hut_hollow_box(roof, frame, (L * 0.5 + 0.4, 0.0, HOLLOW_DECK + 0.25), (L - 1.4, 15.6, 0.5))

    # --- 4. THE TRANSOM: name board with its few surviving plank letters,
    #     the stern-window band, quarter brackets, taffrail, sternpost lantern
    #     and the flag. Everything here hangs off something solid.
    xt, hbt, kzt, szt = st[-1]
    _hut_hollow_box(walls, frame, (xt + 0.45, 0.0, szt - 3.1), (0.9, hbt * 1.9, 2.2))  # name board
    letters = (-4.4, -3.0, -1.6, 0.4, 1.8, 3.4, 4.8)
    for i, ly in enumerate(letters):
        if i in (2, 5):
            continue  # two letters long gone - the name is barely legible
        h = rng.uniform(1.0, 1.35)
        _hut_hollow_box(props, frame, (xt + 0.95, ly, szt - 3.1 + rng.uniform(-0.15, 0.15)),
                        (0.35, 0.75, h), yaw=rng.uniform(-0.10, 0.10))
        if i % 2 == 0:  # a crossbar, so each mark reads as a letter not a peg
            _hut_hollow_box(props, frame, (xt + 0.95, ly, szt - 3.1 + h * 0.22), (0.3, 1.0, 0.3))
    for i in range(4):  # the stern-window band over the board
        wy = -4.5 + 3.0 * i
        _hut_hollow_box(walls, frame, (xt + 0.5, wy, szt - 0.9), (0.8, 0.5, 3.0))  # mullion
        if i < 3 and i != 1:  # one light cracked clean out - Hollow's spyglass window
            _wr_panel(canvas, frame, (
                (xt + 0.72, wy + 0.3, szt - 2.3), (xt + 0.72, wy + 2.7, szt - 2.3),
                (xt + 0.72, wy + 2.7, szt + 0.5), (xt + 0.72, wy + 0.3, szt + 0.5),
            ), 0.22)
    _hut_hollow_box(walls, frame, (xt + 0.5, 0.0, szt + 0.75), (0.9, hbt * 1.9, 0.9))  # window head
    for side in (1, -1):  # quarter brackets, stepped like a carved gallery
        for k in range(3):
            _hut_hollow_box(walls, frame, (xt + 0.2 - k * 0.35, side * (hbt - 0.5 - k * 0.35), szt - 4.6 + k * 1.5),
                            (1.2, 1.1 - k * 0.2, 1.2))
    rail_z = szt + 2.4
    for side in (1, -1):  # taffrail: posts standing ON the sheer, rail across them
        for k in range(3):
            py = side * hbt * (0.30 + 0.32 * k)
            _wr_beam(props, frame, (xt - 0.3, py, szt + 0.2), (xt - 0.3, py, rail_z), 0.55, 0.55)
    _wr_beam(props, frame, (xt - 0.3, -hbt * 0.94, rail_z), (xt - 0.3, hbt * 0.94, rail_z), 0.7, 0.6)
    # Sternpost lantern: bracket off the rail, cage hung UNDER it (the cage top
    # overlaps the bracket), the sea-fire inside the cage.
    lan_y = -hbt * 0.72
    _wr_beam(props, frame, (xt - 0.3, lan_y, rail_z + 0.2), (xt + 1.9, lan_y, rail_z + 0.9), 0.5, 0.45)
    _hut_hollow_box(props, frame, (xt + 1.75, lan_y, rail_z + 0.55), (1.5, 1.5, 0.5))  # cage cap, under the bracket
    for cy_ in (-0.55, 0.55):
        for cx_ in (-0.55, 0.55):
            _wr_beam(props, frame, (xt + 1.75 + cx_, lan_y + cy_, rail_z + 0.55),
                     (xt + 1.75 + cx_, lan_y + cy_, rail_z - 1.35), 0.22, 0.22)
    _hut_hollow_box(props, frame, (xt + 1.75, lan_y, rail_z - 1.45), (1.5, 1.5, 0.4))  # cage floor
    _wr_orb(glow, frame, (xt + 1.75, lan_y, rail_z - 0.45), 0.85)
    # The flag: a staff footed on the taffrail, canvas bent to it all the way
    # down, one width torn away.
    staff_x, staff_y = xt - 0.3, hbt * 0.62
    _wr_spar(props, frame, (staff_x, staff_y, rail_z - 0.4), (staff_x, staff_y, rail_z + 7.6), 0.36, 0.20)
    for k in range(4):
        if k == 2:
            continue
        z0 = rail_z + 1.5 + k * 1.5
        reach = 3.4 - k * 0.35
        _wr_panel(canvas, frame, (
            (staff_x, staff_y, z0), (staff_x - reach, staff_y - 0.5 * (k + 1), z0 - rng.uniform(0.2, 0.7)),
            (staff_x - reach, staff_y - 0.5 * (k + 1), z0 - 1.5 - rng.uniform(0.0, 0.5)), (staff_x, staff_y, z0 - 1.5),
        ), 0.26)
    # The quarterdeck: a short deck aft over the cabin, and the mizzen stump
    # snapped off at the partners (no floating topmast - it ends where it broke).
    _hut_hollow_box(roof, frame, (xt - 3.2, 0.0, szt - 0.2), (6.4, hbt * 1.7, 0.55))
    _wr_spar(props, frame, (L * 0.44, 0.0, HOLLOW_DECK - 0.2), (L * 0.44 + 0.5, 0.6, HOLLOW_DECK + 5.4), 1.05, 0.75)
    _wr_beam(props, frame, (L * 0.44 + 0.5, 0.6, HOLLOW_DECK + 5.2), (L * 0.44 + 0.9, 0.9, HOLLOW_DECK + 6.4), 0.7, 0.55)

    # --- 5. THE CABIN. Ledger desk with quill, inkpot and coin scales;
    #     numbered crate shelves down the port lining; a lamp hung from a deck
    #     beam; charts pinned to the curved starboard wall; the spyglass at the
    #     cracked stern window. Everything stands on the sole.
    dx = L - 6.4
    _hut_hollow_box(props, frame, (dx, -1.0, HOLLOW_SOLE + 2.5), (3.4, 6.4, 0.4))  # desk top
    for lx, ly in ((-1.3, -3.6), (-1.3, 1.6), (1.3, -3.6), (1.3, 1.6)):
        _hut_hollow_box(props, frame, (dx + lx, -1.0 + ly, HOLLOW_SOLE + 1.25), (0.45, 0.45, 2.5))
    _hut_hollow_box(props, frame, (dx - 0.4, -2.6, HOLLOW_SOLE + 2.85), (2.0, 2.6, 0.3))  # the ledger, open
    _hut_hollow_box(props, frame, (dx - 0.4, -2.6, HOLLOW_SOLE + 3.02), (1.7, 1.1, 0.06), yaw=0.12)
    _hut_hollow_box(props, frame, (dx + 0.9, 0.4, HOLLOW_SOLE + 2.95), (0.7, 0.7, 0.6))  # inkpot
    _wr_spar(props, frame, (dx + 0.9, 0.4, HOLLOW_SOLE + 3.1), (dx + 1.5, 1.2, HOLLOW_SOLE + 4.4), 0.10, 0.05)  # quill
    scale_x, scale_y = dx - 1.2, 1.6
    _wr_spar(props, frame, (scale_x, scale_y, HOLLOW_SOLE + 2.7), (scale_x, scale_y, HOLLOW_SOLE + 4.6), 0.22, 0.16)
    _wr_beam(props, frame, (scale_x, scale_y - 1.5, HOLLOW_SOLE + 4.5), (scale_x, scale_y + 1.5, HOLLOW_SOLE + 4.6), 0.16, 0.16)
    for s_ in (-1, 1):  # the pans, hung on their strings from the beam ends
        _wr_spar(props, frame, (scale_x, scale_y + s_ * 1.45, HOLLOW_SOLE + 4.55), (scale_x, scale_y + s_ * 1.45, HOLLOW_SOLE + 3.75), 0.05, 0.05)
        _hut_hollow_box(props, frame, (scale_x, scale_y + s_ * 1.45, HOLLOW_SOLE + 3.65), (1.1, 1.1, 0.22))
    _hut_hollow_box(props, frame, (dx - 3.6, 2.2, HOLLOW_SOLE + 0.9), (2.0, 2.0, 1.8))  # sea chest / stool
    for k in range(3):  # the crate shelves down the port side, numbered
        sz_z = HOLLOW_SOLE + 1.4 + k * 2.5
        _hut_hollow_box(props, frame, (L * 0.45, 6.1, sz_z), (9.0, 1.9, 0.35))
        for j in range(3):
            cxx = L * 0.45 - 3.0 + j * 3.0
            _hut_hollow_box(props, frame, (cxx, 6.0, sz_z + 1.1), (2.2, 1.7, 1.8), yaw=rng.uniform(-0.06, 0.06))
            _hut_hollow_box(canvas, frame, (cxx, 5.12, sz_z + 1.35), (1.0, 0.1, 0.7))  # the number plate
    for k in range(2):  # shelf uprights, sole to deckhead
        _hut_hollow_box(props, frame, (L * 0.45 - 4.4 + k * 8.8, 6.4, HOLLOW_SOLE + 4.5), (0.5, 1.3, 9.0))
    lamp_x = L * 0.62
    _wr_spar(props, frame, (lamp_x, -1.6, HOLLOW_DECK - 0.2), (lamp_x, -1.6, HOLLOW_DECK - 2.1), 0.10, 0.10)  # chain to the deckhead
    _hut_hollow_box(props, frame, (lamp_x, -1.6, HOLLOW_DECK - 2.5), (1.5, 1.5, 1.1))  # the lamp housing
    _wr_orb(glow, frame, (lamp_x, -1.6, HOLLOW_DECK - 2.9), 0.75)
    for k in range(3):  # charts pinned flat to the starboard ceiling planking
        cxx = L * 0.30 + k * 4.2
        hb = _hut_hollow_hb(st, cxx)
        _wr_panel(canvas, frame, (
            (cxx - 1.7, -(hb - 1.05), HOLLOW_SOLE + 3.4 + k * 0.35), (cxx + 1.7, -(hb - 1.05), HOLLOW_SOLE + 3.1 + k * 0.35),
            (cxx + 1.7, -(hb - 1.05), HOLLOW_SOLE + 6.1 + k * 0.35), (cxx - 1.7, -(hb - 1.05), HOLLOW_SOLE + 6.4 + k * 0.35),
        ), 0.16)
    sp_x = xt - 2.2  # the spyglass, stood at the cracked light on its tripod
    for a_ in (0.0, 2.1, 4.2):
        _wr_spar(props, frame, (sp_x + math.cos(a_) * 0.7, -3.0 + math.sin(a_) * 0.7, HOLLOW_SOLE),
                 (sp_x, -3.0, HOLLOW_SOLE + 3.2), 0.13, 0.10)
    _wr_spar(props, frame, (sp_x - 1.1, -3.0, HOLLOW_SOLE + 2.9), (sp_x + 1.9, -3.0, HOLLOW_SOLE + 3.9), 0.45, 0.28)

    # --- 6. THE SHORE SIDE: gangplank down out of the breach, Hollow's counter
    #     at its foot, crates and a cargo net beside it, and a lamp stake so the
    #     counter is lit. All of it seated on probed sand.
    sill = wpt((0.2, 0.0, HOLLOW_SOLE + 0.15))
    foot = (sill.x + up_beach[0] * 7.0, sill.y + up_beach[1] * 7.0)
    foot_z = _hut_hollow_ground(ground, *foot)
    _wr_beam(roof, world, (foot[0], foot[1], foot_z - 0.15), (sill.x, sill.y, sill.z), 4.6, 0.55)
    for k in range(3):  # cleats across the plank, laid on it
        f = 0.25 + 0.25 * k
        cx_ = foot[0] + (sill.x - foot[0]) * f
        cy_ = foot[1] + (sill.y - foot[1]) * f
        cz_ = foot_z - 0.15 + (sill.z - foot_z + 0.15) * f
        _wr_beam(roof, world, (cx_ - port[0] * 2.2, cy_ - port[1] * 2.2, cz_ + 0.35),
                 (cx_ + port[0] * 2.2, cy_ + port[1] * 2.2, cz_ + 0.35), 0.5, 0.3)
    cnt = (sill.x + up_beach[0] * 7.6 + port[0] * 4.6, sill.y + up_beach[1] * 7.6 + port[1] * 4.6)
    cnt_z = _hut_hollow_ground(ground, *cnt)
    top_z = cnt_z + 3.1
    for s_ in (-1, 1):  # two barrels carrying the counter plank
        bxx, byy = cnt[0] + port[0] * s_ * 2.9, cnt[1] + port[1] * s_ * 2.9
        bz = _hut_hollow_ground(ground, bxx, byy)
        _wr_spar(props, world, (bxx, byy, bz - 0.4), (bxx, byy, top_z - 0.15), 1.55, 1.35, sides=8)
    add_box(roof, (cnt[0], cnt[1], top_z - 0.2), (2.8, 9.0, 0.55), yaw=yaw + math.pi)  # the counter plank
    add_box(props, (cnt[0] - up_beach[0] * 0.6, cnt[1] - up_beach[1] * 0.6, top_z + 0.25), (1.6, 2.4, 0.3), yaw=yaw)  # the open ledger
    lam = (cnt[0] + port[0] * 3.2, cnt[1] + port[1] * 3.2)  # the counter lantern, stood ON the plank
    add_box(props, (lam[0], lam[1], top_z + 0.85), (1.4, 1.4, 1.5), yaw=yaw)
    _wr_orb(glow, world, (lam[0], lam[1], top_z + 0.85), 0.7)
    crates = ((2.6, 7.4, 0), (5.4, 8.2, 0), (3.2, 10.4, 0), (3.0, 8.0, 1))
    stack_top = {}
    for cx_, cy_, tier in crates:  # wares, resting on the sand (or on the crate below)
        wx = sill.x + up_beach[0] * cx_ + port[0] * cy_
        wy = sill.y + up_beach[1] * cx_ + port[1] * cy_
        gz = _hut_hollow_ground(ground, wx, wy)
        base_z = stack_top.get(tier - 1, gz) if tier else gz
        h = 2.6 if tier == 0 else 2.1
        add_box(props, (wx, wy, base_z + h / 2 - 0.15), (2.9, 2.9, h), yaw=yaw + rng.uniform(-0.3, 0.3))
        add_box(props, (wx, wy, base_z + h - 0.25), (3.1, 3.1, 0.3), yaw=yaw + rng.uniform(-0.3, 0.3))
        stack_top[tier] = base_z + h - 0.3
    net_x = sill.x + up_beach[0] * 4.4 + port[0] * -5.0
    net_y = sill.y + up_beach[1] * 4.4 + port[1] * -5.0
    net_z = stack_top.get(1, _hut_hollow_ground(ground, net_x, net_y) + 2.4)
    for k in range(5):  # the net, draped over the stack and pegged to the sand
        f = -2.6 + 1.3 * k
        a0 = (net_x + port[0] * f - up_beach[0] * 2.6, net_y + port[1] * f - up_beach[1] * 2.6)
        a1 = (net_x + port[0] * f + up_beach[0] * 2.6, net_y + port[1] * f + up_beach[1] * 2.6)
        _wr_beam(canvas, world, (a0[0], a0[1], _hut_hollow_ground(ground, *a0) + 0.1),
                 (a1[0], a1[1], net_z + 0.15), 0.22, 0.14)
        b0 = (net_x + port[0] * -2.6 + up_beach[0] * f, net_y + port[1] * -2.6 + up_beach[1] * f)
        b1 = (net_x + port[0] * 2.6 + up_beach[0] * f, net_y + port[1] * 2.6 + up_beach[1] * f)
        _wr_beam(canvas, world, (b0[0], b0[1], net_z + 0.05), (b1[0], b1[1], net_z + 0.2), 0.22, 0.14)
    for k in range(5):  # sand drifted up against the buried side of the hull
        t = 0.16 + 0.17 * k
        sxx = bx + fwd[0] * L * t - port[0] * (_hut_hollow_hb(st, L * t) + 0.4)
        syy = by + fwd[1] * L * t - port[1] * (_hut_hollow_hb(st, L * t) + 0.4)
        gz = _hut_hollow_ground(ground, sxx, syy)
        _wr_mound(walls, (sxx, syy, gz - 1.7), (6.5, 3.4, 2.9), 3300 + k * 7.3, yaw=yaw)

    door = wpt((-0.4, 0.0, HOLLOW_SOLE))
    stand = (cnt[0] + up_beach[0] * -1.9, cnt[1] + up_beach[1] * -1.9)  # Hollow, behind his counter
    # Hollow stands SHIP-SIDE of the counter, so he looks UP the beach at whoever
    # walks in - not out to sea with his back to the customer. (The first version
    # negated this and printed a facing 180 degrees wrong.)
    look = up_beach
    facing = math.degrees(math.atan2(-look[0], look[1])) % 360.0
    a_dock = math.radians(DOCK_ANGLE_DEG)
    spawn_z = -(ring_radius(DOCK_START_U, a_dock) - 18)  # the island's spawn, Blender y
    mid = (bx + fwd[0] * L * 0.5, by + fwd[1] * L * 0.5)
    print(
        f"[island_gen] HANDOFF wreckwater hut (Hollow's beached sterncastle): breach sill "
        f"(Roblox rel) X={door.x:.0f} Z={-door.y:.0f} Y~{door.z:.1f}, counter X={cnt[0]:.0f} Z={-cnt[1]:.0f} "
        f"top Y~{top_z:.1f}; suggested hollow spawnOffset Vector3.new({stand[0]:.0f}, 0, {-stand[1] + spawn_z:.0f}) "
        f"facing {facing:.0f} (island spawn X=0 Z={-spawn_z:.0f})"
    )
    print(
        f"[island_gen] HANDOFF wreckwater hut KEEP-CLEAR: centre (Roblox rel) X={mid[0]:.0f} Z={-mid[1]:.0f} "
        f"r={HOLLOW_KEEP_R:.0f}; hull seated on the probe (sole Y~{pos_z:.1f} at the break, transom in the wash)"
    )
    return (
        object_from_bmesh("Wreckwater_Hut_Walls", walls, ["M_HullWood"]),
        object_from_bmesh("Wreckwater_Hut_Roof", roof, ["M_WreckPlank"]),
        object_from_bmesh("Wreckwater_Hut_Props", props, ["M_WreckPost"]),
        object_from_bmesh("Wreckwater_Hut_Canvas", canvas, ["M_WreckSail"]),
        object_from_bmesh("Wreckwater_Hut_Glow", glow, ["M_GhostGlow"]),
    )

def build_wreckwater():
    base = build_island_base("Wreckwater_Base", ["M_BayFloor", "M_WreckSand", "M_WreckWet"])
    ground = _ground_bvh(base)
    objects = [
        base,
        build_wreck_bay(ground),  # first: records the bay keep-clear circle
        build_wreck_dunes(ground),
        *build_wreck_quay(ground),
        # The open-sea fleet MUST precede build_wrecks: it hands its lanterns to
        # _WR_EXTRA_GLOW, and build_wrecks is what drains that list into
        # Wreckwater_GhostGlow (and then clears it).
        build_sea_wrecks(ground),
        *build_wrecks(ground),
        build_wreck_rocks(ground),
        build_wreck_ironwork(ground),
        # Hollow's house: after the fleet so it reads as the shore's one
        # deliberate structure, before the dock/foam.
        *build_wreck_sterncastle(ground),
        *build_dock("Wreckwater_Dock_Planks", "Wreckwater_Dock_Posts", "M_WreckPlank", "M_WreckPost"),
        build_foam("Wreckwater_Foam", "M_WreckFoam"),
    ]
    validate_no_floaters(objects, ground, exempt=WRECK_FLOAT_EXEMPT, label="wreckwater")
    # The fixture disc is the NPC house's ground: the house itself and the
    # landform/water/foam that span the whole island are allowed inside it.
    validate_keep_clear(
        objects,
        _WR_KEEP_CLEAR,
        exempt={
            # The landform and its water/foam span the whole island.
            "Wreckwater_Base", "Wreckwater_Bay", "Wreckwater_Foam", "Wreckwater_Dunes",
            # The house itself.
            "Wreckwater_Hut_Walls", "Wreckwater_Hut_Roof", "Wreckwater_Hut_Props",
            "Wreckwater_Hut_Canvas", "Wreckwater_Hut_Glow",
            # PRE-EXISTING wreck geometry the house was deliberately sited
            # among - the quay it stands beside, the beached hulk it is built
            # out of, that hulk's lanterns and canvas, and the shore boulders.
            # Forbidding these would fail correct, intentional level design.
            # The dressing that DOES share these objects (the careened hull,
            # the salvage camp, the gibbets) is kept out at placement time
            # instead, by _wr_clear_of_fixtures.
            "Wreckwater_Quay_Planks", "Wreckwater_Quay_Posts", "Wreckwater_Hulks",
            "Wreckwater_GhostGlow", "Wreckwater_Sails", "Wreckwater_Rocks",
        },
        label="wreckwater",
    )

    a = math.radians(DOCK_ANGLE_DEG)
    start_r = ring_radius(DOCK_START_U, a)
    print(f"[island_gen] HANDOFF wreckwater: dock start (Roblox rel) X=0 Z={start_r:.0f}, spawn suggestion X=0 Z={start_r - 18:.0f} ground Y~{height_at(0, -(start_r - 18)):.1f}, {_WR_SEA_COUNT} sea hulks")
    return objects


# ---------------------------------------------------------------- The Maelstrom
#
# The finale SITE grown into a real place (2026-08-27; it shipped as nine
# procedural boxes and twelve spires, "completely unfinished" per the user).
# There is still NO landmass: the Maelstrom is a drowned storm-shoal - the
# whole Maelstrom_Base sits BELOW the waterline (a dark shallows you see down
# into, dishing into a vortex bowl under the whirlpool) - and everything you
# stand on is a basalt stack rising out of it.
#
# GAMEPLAY CONTRACTS this mesh must keep (WorldService/Bosses own the numbers):
#   * The whirlpool water disc (Maelstrom_Water, r=75) stays PROCEDURAL -
#     WorldService builds it and MaelstromVfxController spins it. Nothing may
#     stand inside r<80: the disc must stay clear for casting and the Kraken.
#   * The Kraken rises at the site centre (arena r=34) and plants its tentacle
#     ring at r=26; the FIGHT platforms ring r 38-52 with walkable tops at
#     y 3.6-6.0 - same band as the procedural stand-ins they replace.
#   * The spawn platform sits at Roblox rel +Z 44 (Blender (0,-44)), top at
#     y 6.0 = the Islands entry's spawn fallback. Travel probes down onto it.
#   * Roblox +Z (the approach from home) is Blender -y: the outer teeth leave
#     a clear sailing lane around 270 deg so a boat can reach the spawn stack.
#
# Objects (single-material each; MESH_COLOR/NON_COLLIDE keys in WorldService):
#   Maelstrom_Base       the drowned shoal + vortex bowl (collidable seabed)
#   Maelstrom_Platforms  spawn stack + 9 fight stacks (collidable, walked)
#   Maelstrom_Spires     two belts of storm-teeth (collidable set dressing)
#   Maelstrom_Rocks      half-sunken reef teeth on the shoal (collidable)
#   Maelstrom_Wrecks     the doomed fleet spiralling in (NON_COLLIDE, like
#                        Wreckwater_SeaHulks - boats glide through)
#   Maelstrom_Sails      their torn storm-grey canvas (NON_COLLIDE)
#   Maelstrom_Chains     colossal snapped anchor chains diving for the maw
#                        (NON_COLLIDE)
#   Maelstrom_Debris     flotsam ring at the waterline (NON_COLLIDE)
#   Maelstrom_StormGlow  electric storm-fire: wreck ghost-light, crystal
#                        shards on spires + platform rims (Neon, NON_COLLIDE)

_MAEL_SPIRE_TOPS = []  # (x, y, z_top) of built spires, for chains + glow


def _mael_cap_points(cx, cy, r, salt, seg=14):
    """The ragged outline of a walkable basalt cap."""
    pts = []
    for s in range(seg):
        a = (s / seg) * math.tau
        w = 1 + 0.11 * math.sin(3 * a + salt) + 0.07 * math.sin(6 * a + salt * 1.7)
        pts.append((cx + math.cos(a) * r * w, cy + math.sin(a) * r * w))
    return pts


def _mael_platform(bm, x, y, top, cap_r, salt):
    """One arena stack: a column of stacked angular blobs rising out of the
    shoal, crowned by a FLAT ragged cap slab - the walkable floor. The cap is
    a genuine level surface so the fight has honest footing (import step:
    PreciseConvexDecomposition, like every island)."""
    rng = random.Random(salt)
    # The column: three blobs, widest at the seabed, each with its PEAK held
    # under the cap top - the first build let the top blob bulge through the
    # cap as a dome, which broke the flat fighting floor (preview review).
    for k, (rr, zc, sz) in enumerate((
        (cap_r * 1.45, -6.5, 4.8),  # peaks ~ -1.7
        (cap_r * 1.15, -1.0, 3.4),  # peaks ~ 2.4
        (cap_r * 0.90, top - 2.8, 2.4),  # peaks ~ top-0.4, inside the cap slab
    )):
        add_blob(
            bm, (x + rng.uniform(-1.2, 1.2), y + rng.uniform(-1.2, 1.2), zc),
            (rr, rr * rng.uniform(0.85, 1.1), sz),
            0.20, salt * 3.1 + k, yaw=rng.uniform(0, math.tau),
        )
    add_disc_slab(bm, _mael_cap_points(x, y, cap_r, salt), top, 1.6)


def build_mael_platforms():
    """The spawn stack (+Z, top 6.0) and the nine fight stacks ringing the
    arena at r 38-52. Two of the nine are pushed out to r~62 where the ring
    crosses the spawn stack's bearing - they read as the gateway flanking the
    landing instead of crowding it."""
    bm = bmesh.new()

    # Spawn stack: Roblox rel +Z 44 = Blender (0, -44); top exactly 6.0 (the
    # Islands entry's spawn Y fallback). Chunky, with two step blobs down
    # toward the water so climbing back up from a knockdown is possible.
    _mael_platform(bm, 0.0, -44.0, 6.0, 13.5, salt=11.0)
    add_blob(bm, (10.5, -55.0, -0.4), (5.0, 4.2, 2.6), 0.20, 17.0, yaw=0.7)
    add_blob(bm, (-9.0, -57.5, -1.2), (4.4, 3.8, 2.2), 0.20, 18.5, yaw=2.1)

    spawn_bearing = -math.pi / 2  # Blender angle of (0, -44)
    for i in range(9):
        angle = (i / 9) * math.tau + random.uniform(-0.10, 0.10)
        da = abs(((angle - spawn_bearing + math.pi) % math.tau) - math.pi)
        if da < math.radians(26):
            r = random.uniform(60.0, 66.0)  # the gateway pair, clear of the landing
        else:
            r = random.uniform(38.0, 52.0)
        top = random.uniform(3.6, 6.0)
        _mael_platform(bm, math.cos(angle) * r, math.sin(angle) * r, top, random.uniform(7.0, 10.0), salt=23.0 + i * 7.7)
    return object_from_bmesh("Maelstrom_Platforms", bm, ["M_StormRock"])


def _mael_spire_cluster(bm, ground, x, y, count, h_lo, h_hi, salt):
    """A family of leaning storm-teeth off one blob base, seated on the real
    shoal mesh. Records each tooth's top for the chains and the storm-fire."""
    rng = random.Random(salt)
    base = _drop_to_ground(ground, x, y)
    if base is None:
        return
    add_blob(bm, (x, y, base + 0.6), (rng.uniform(6.0, 10.0), rng.uniform(5.0, 8.5), rng.uniform(2.6, 4.4)), 0.24, salt * 1.9, yaw=rng.uniform(0, math.tau))
    for k in range(count):
        dx, dy = rng.uniform(-5.0, 5.0), rng.uniform(-5.0, 5.0)
        h = rng.uniform(h_lo, h_hi)
        tilt = (rng.uniform(-0.16, 0.16), rng.uniform(-0.16, 0.16))
        yaw = rng.uniform(0, math.tau)
        # Base radius follows height, so tall teeth read as rock masses and
        # only the short ones stay slender (preview review: uniform thin
        # needles read as a spike field, not storm rock).
        add_cone(bm, (x + dx, y + dy, base), rng.uniform(3.2, 7.0) * (0.5 + h / h_hi * 0.7), 0.4, h, sides=5, tilt=tilt, yaw=yaw)
        axis = cone_axis(tilt, yaw)
        top = Vector((x + dx, y + dy, base)) + axis * h
        _MAEL_SPIRE_TOPS.append((top.x, top.y, top.z))


def build_mael_spires(ground):
    """Two belts of teeth: an inner crown just past the arena and an outer
    palisade toward the rim, both leaving the 270-deg approach lane open so
    the sail in from home runs clean to the spawn stack."""
    _MAEL_SPIRE_TOPS.clear()
    bm = bmesh.new()
    lane = -math.pi / 2
    for i in range(10):  # the inner crown
        angle = (i / 10) * math.tau + random.uniform(-0.14, 0.14)
        if abs(((angle - lane + math.pi) % math.tau) - math.pi) < math.radians(20):
            continue
        r = random.uniform(95.0, 130.0)
        _mael_spire_cluster(bm, ground, math.cos(angle) * r, math.sin(angle) * r, random.randint(2, 3), 20.0, 55.0, salt=41.0 + i * 5.3)
    for i in range(14):  # the outer palisade
        angle = (i / 14) * math.tau + random.uniform(-0.12, 0.12)
        if abs(((angle - lane + math.pi) % math.tau) - math.pi) < math.radians(16):
            continue
        r = random.uniform(165.0, 232.0)
        _mael_spire_cluster(bm, ground, math.cos(angle) * r, math.sin(angle) * r, random.randint(2, 4), 14.0, 72.0, salt=97.0 + i * 6.1)
    # Three TITAN FANGS - the finale's silhouette off the open sea (the
    # volcano rule: a destination reads from miles out). Broad-based, leaning
    # a few degrees toward the maw as if the storm is winning, each footed on
    # a boulder mass that breaks the surface.
    for k, bearing in enumerate((0.55, 2.65, 4.35)):  # all well off the 270-deg lane
        r = random.uniform(135.0, 165.0)
        x, y = math.cos(bearing) * r, math.sin(bearing) * r
        base = _drop_to_ground(ground, x, y)
        if base is None:
            continue
        h = random.uniform(88.0, 118.0)
        inward = math.atan2(-y, -x)
        tilt_mag = math.radians(random.uniform(5.0, 9.0))
        tilt = (math.sin(inward) * tilt_mag, -math.cos(inward) * tilt_mag)
        add_blob(bm, (x, y, 0.4), (random.uniform(9.0, 12.0), random.uniform(7.5, 10.0), random.uniform(3.2, 4.6)), 0.24, 301.0 + k * 9.7, yaw=random.uniform(0, math.tau))
        add_cone(bm, (x, y, base), random.uniform(9.0, 13.0), 0.6, h, sides=6, tilt=tilt, yaw=random.uniform(0, math.tau))
        add_cone(bm, (x + random.uniform(-6, 6), y + random.uniform(-6, 6), base), random.uniform(4.0, 6.0), 0.4, h * random.uniform(0.35, 0.55), sides=5, tilt=(tilt[0] * 1.6, tilt[1] * 1.6), yaw=random.uniform(0, math.tau))
        axis = cone_axis(tilt, 0.0)
        top = Vector((x, y, base)) + axis * h
        _MAEL_SPIRE_TOPS.append((top.x, top.y, top.z))
    return object_from_bmesh("Maelstrom_Spires", bm, ["M_StormSpire"])


def build_mael_wrecks():
    """The doomed fleet: five ships caught on the spiral, each further down
    the drain than the last - bows reared, sterns heeled, one hull picked to
    the bone - every one yawed just off the tangent so the whole fleet reads
    as circling INWARD. Their ghost-light goes into the shared storm-glow
    object; the innermost pieces are the short ones, so nothing reaches past
    the r=80 clear-water line around the whirlpool."""
    wood_bm, glow_bm, sail_bm = bmesh.new(), bmesh.new(), bmesh.new()
    spiral = (
        # (theta, r, kind); kinds: bow / stern / ribcage / seaqribs
        (0.5, 200.0, "bow"),
        (1.9, 176.0, "stern"),
        (3.2, 154.0, "bow"),
        (4.5, 132.0, "stern"),
        (5.6, 112.0, "ribcage"),
    )
    for theta, r, kind in spiral:
        x, y = math.cos(theta) * r, math.sin(theta) * r
        # Tangent (counter-clockwise) plus a pull toward the maw.
        yaw = theta + math.pi / 2 + 0.42 + random.uniform(-0.12, 0.12)
        length = random.uniform(26.0, 36.0)
        beam = max(14.5, length * random.uniform(0.44, 0.52))
        if kind == "bow":
            _wr_bow_section(
                wood_bm, glow_bm, sail_bm,
                pos=(x, y, -random.uniform(1.5, 3.0)), yaw=yaw,
                pitch=math.radians(random.uniform(20.0, 40.0)),
                length=length, beam=beam, depth=beam * 0.50, ghost=True,
            )
        elif kind == "stern":
            _wr_stern_section(
                wood_bm, glow_bm, sail_bm,
                pos=(x, y, -random.uniform(2.0, 3.5)), yaw=yaw,
                pitch=math.radians(random.uniform(-8.0, 6.0)),
                roll=math.radians(random.choice((1, -1)) * random.uniform(24.0, 44.0)),
                length=length * 0.85, beam=beam * 0.92, depth=beam * 0.45, ghost=True,
            )
        else:  # the innermost hull, picked clean - shortest reach of the lot
            _wr_ribcage(
                wood_bm, glow_bm,
                pos=(x, y, -random.uniform(1.0, 2.0)), yaw=yaw,
                pitch=math.radians(random.uniform(-4.0, 6.0)),
                roll=math.radians(random.uniform(-18.0, 18.0)),
                length=length * 0.9, beam=beam * 0.85, depth=beam * 0.42,
            )
    # Two half-drowned rib rings further out - the storm's older kills.
    for theta, r in ((2.6, 218.0), (5.1, 205.0)):
        _wr_sea_ribcage(
            wood_bm,
            pos=(math.cos(theta) * r, math.sin(theta) * r, -random.uniform(1.5, 2.5)),
            yaw=theta + math.pi / 2 + random.uniform(-0.4, 0.4),
            pitch=math.radians(random.uniform(-6.0, 6.0)),
            roll=math.radians(random.uniform(-20.0, 20.0)),
            length=random.uniform(20.0, 28.0), beam=random.uniform(10.0, 13.0),
            rise=random.uniform(5.0, 8.0),
        )
    return (
        object_from_bmesh("Maelstrom_Wrecks", wood_bm, ["M_DoomWood"]),
        object_from_bmesh("Maelstrom_Sails", sail_bm, ["M_DoomSail"]),
        glow_bm,
    )


def build_mael_chains(glow_bm):
    """Colossal snapped anchor chains, arcing off the tallest teeth and diving
    for the maw - they end just OUTSIDE the r=80 clear-water line, pointing at
    the whirlpool rather than crossing it. Links are alternating flat/edge
    timber-scale beams down a sagging curve; a storm-fire orb rides each
    anchor point."""
    bm = bmesh.new()
    ident = Matrix.Identity(4)
    anchors = sorted(_MAEL_SPIRE_TOPS, key=lambda p: -p[2])[:8]
    picked = []
    for p in anchors:  # spread the three chains around the ring, not one side
        if all(abs(((math.atan2(p[1], p[0]) - math.atan2(q[1], q[0]) + math.pi) % math.tau) - math.pi) > 1.2 for q in picked):
            picked.append(p)
        if len(picked) == 3:
            break
    for i, (sx, sy, sz) in enumerate(picked):
        a = math.atan2(sy, sx)
        ex, ey = math.cos(a) * 86.0, math.sin(a) * 86.0
        p0 = Vector((sx, sy, sz - 1.0))
        p2 = Vector((ex, ey, -1.2))
        mid = (p0 + p2) / 2
        p1 = Vector((mid.x, mid.y, min(p0.z, 26.0) * 0.55))  # the sag
        n = 12
        prev = p0
        for k in range(1, n + 1):
            t = k / n
            pt = (1 - t) ** 2 * p0 + 2 * (1 - t) * t * p1 + t ** 2 * p2
            if k % 2 == 0:
                _wr_beam(bm, ident, prev, pt, 2.2, 0.7)
            else:
                _wr_beam(bm, ident, prev, pt, 0.7, 2.2)
            prev = pt
        _wr_orb(glow_bm, ident, (sx, sy, sz + 0.8), 1.0)
    return object_from_bmesh("Maelstrom_Chains", bm, ["M_StormIron"])


def build_mael_rocks(ground):
    """Half-sunken reef teeth strewn over the shoal between the spire belts -
    the ground clutter that makes the shallows read as wrecking water."""
    bm = bmesh.new()
    for i in range(42):
        angle = random.uniform(0, math.tau)
        r = random.uniform(88.0, 238.0)
        x, y = math.cos(angle) * r, math.sin(angle) * r
        if _drop_to_ground(ground, x, y) is None:
            continue
        # Seated against the WATERLINE, not the shoal (the first build sat
        # them on the seabed and drowned nearly all of them): centres straddle
        # y=0 so every tooth breaks the surface by 1-5 studs.
        s = random.uniform(2.2, 6.5)
        add_blob(bm, (x, y, random.uniform(-1.0, 1.6)), (s, s * random.uniform(0.7, 1.0), s * random.uniform(0.6, 0.9)), 0.26, 131.0 + i * 3.3, yaw=random.uniform(0, math.tau))
    return object_from_bmesh("Maelstrom_Rocks", bm, ["M_StormRock"])


def build_mael_debris():
    """The flotsam ring: planks, barrels, crates and the odd snapped spar
    turning on the outer water - sparse, so casting between pieces stays
    clean, and all of it OUTSIDE the whirlpool's r=80 clear line."""
    bm = bmesh.new()
    for i in range(52):
        angle = random.uniform(0, math.tau)
        r = random.uniform(85.0, 238.0)
        frame = _wr_frame(
            (math.cos(angle) * r, math.sin(angle) * r, 0.12),
            yaw=random.uniform(0, math.tau),
            pitch=math.radians(random.uniform(-7.0, 7.0)),
            roll=math.radians(random.uniform(-7.0, 7.0)),
        )
        roll_die = random.random()
        if roll_die < 0.5:  # drift planks
            L = random.uniform(4.0, 9.0)
            _wr_beam(bm, frame, (-L / 2, 0, 0.2), (L / 2, random.uniform(-1.0, 1.0), 0.2 + random.uniform(-0.3, 0.5)), random.uniform(0.8, 1.5), 0.45, twist=random.uniform(0, 1.0))
        elif roll_die < 0.75:  # barrels
            _wr_spar(bm, frame, (0, 0, 0.2), (random.uniform(1.8, 2.6), random.uniform(-0.8, 0.8), random.uniform(0.6, 1.4)), 1.3, 1.05, sides=8)
        elif roll_die < 0.92:  # crates
            add_box(bm, (math.cos(angle) * r, math.sin(angle) * r, 0.55), (random.uniform(1.6, 2.6),) * 3, yaw=random.uniform(0, math.tau))
        else:  # a snapped spar still rigged to a scrap of nothing
            L = random.uniform(7.0, 12.0)
            _wr_spar(bm, frame, (-L / 2, 0, 0.3), (L / 2, 0, random.uniform(0.8, 2.2)), 0.55, 0.25)
    return object_from_bmesh("Maelstrom_Debris", bm, ["M_StormDebris"])


def build_mael_glow(glow_bm, ground):
    """Everything electric, in ONE Neon object: the fleet's ghost-light and
    chain-anchor orbs (already in glow_bm), crystal shards at the spire bases,
    and small charged shards around each fight platform's rim - the arena
    reads storm-lit from the water."""
    rng = random.Random(203.0)
    # Shards at ~60% of spire tops' bases.
    for (sx, sy, _sz) in _MAEL_SPIRE_TOPS:
        if rng.random() > 0.4:
            continue
        base = _drop_to_ground(ground, sx, sy)
        if base is None:
            continue
        for _ in range(rng.randint(2, 3)):
            add_cone(
                glow_bm,
                (sx + rng.uniform(-3.0, 3.0), sy + rng.uniform(-3.0, 3.0), base),
                rng.uniform(0.35, 0.7), 0.06, rng.uniform(1.6, 4.2),
                sides=4, tilt=(rng.uniform(-0.3, 0.3), rng.uniform(-0.3, 0.3)), yaw=rng.uniform(0, math.tau),
            )
    # Charged shards on the fight platforms' rims (positions re-derived from
    # the same ring band; exact platform centres don't matter for a rim spark).
    for i in range(14):
        angle = rng.uniform(0, math.tau)
        r = rng.uniform(40.0, 58.0)
        add_cone(glow_bm, (math.cos(angle) * r, math.sin(angle) * r, rng.uniform(2.2, 5.4)), rng.uniform(0.25, 0.45), 0.05, rng.uniform(0.9, 1.8), sides=4, tilt=(rng.uniform(-0.4, 0.4), rng.uniform(-0.4, 0.4)), yaw=rng.uniform(0, math.tau))
    return object_from_bmesh("Maelstrom_StormGlow", glow_bm, ["M_StormGlow"])


def build_maelstrom():
    base = build_island_base("Maelstrom_Base", ["M_StormFloor", "M_StormShoal", "M_StormWet"])
    ground = _ground_bvh(base)
    platforms = build_mael_platforms()
    spires = build_mael_spires(ground)
    wrecks, sails, glow_bm = build_mael_wrecks()
    chains = build_mael_chains(glow_bm)
    rocks = build_mael_rocks(ground)
    debris = build_mael_debris()
    glow = build_mael_glow(glow_bm, ground)
    objects = [base, platforms, spires, rocks, wrecks, sails, chains, debris, glow]
    print(
        "[island_gen] HANDOFF maelstrom: spawn stack top Y=6.0 at rel Z=44 (Roblox); fight stacks r 38-52 "
        "tops 3.6-6.0 (arena r=34, tentacle ring r=26); water inside r<80 kept clear - the Maelstrom_Water "
        "disc stays PROCEDURAL (WorldService), never authored here."
    )
    # Platform columns and sunken keels are authored well below the -9 skirt,
    # so this island ALWAYS needs meshBottom in its Islands entry (0f's
    # "floating ships" rule). build_pack prints this too; printing it here as
    # well means a standalone island_maelstrom.glb build can't ship without it.
    low = min(min(v.co.z for v in o.data.vertices) for o in objects if o.data.vertices)
    print(f"[island_gen] HANDOFF maelstrom: mesh bottom z {low:.2f}  <-- set Islands.luau meshBottom to this")
    return objects


# ------------------------------------------- islet: the Lampwright's Workshop
#
# LAMPWORK (quest islet; world (13100, -1200), r 55). A bare dark rock on the
# run down to the trench, and the whole story is told without a word:
#
#   * a low stone-and-timber WORKSHOP, open down one side like a forge, so the
#     benches, the racked lens blanks, the half-built lamp housings, the brass
#     fittings and the tool rail all read from the water;
#   * a YARD OF FINISHED LAMPS on posts, on a drying rail and under the eave -
#     eighteen of them, every size he makes, and EVERY ONE OF THEM DARK;
#   * THE GREAT LAMP, his masterwork, up on a short iron gantry: taller than a
#     man, glass-panelled - the twin of the one now burning on Keeper Lumen's
#     lighthouse, the one he gave away. Dark as well.
#   * exactly ONE lit window: a single warm square on the seaward gable, the
#     only light anywhere on this rock (Lampwork_Glow, one material, one box);
#   * MOTHS thick around that window and dead ones on its sill and at the wall
#     foot - the tell that something out in the dark came home with the light.
#
# NOTHING ON THIS ISLET FLOATS EXCEPT THE MOTHS. Every lamp meets its post,
# hook or gantry; every bench leg meets the floor; the jetty's plank bottom is
# set ON the real raycast rock at its root and its posts run to -6. The moths
# are the ONE intentional exception and live alone in Lampwork_Moths so any
# "nothing hovers" sweep can exempt exactly that object (and so WorldService
# can drop it into NON_COLLIDE without touching anything structural).
#
# Five objects, exactly:
#   Lampwork_Base   the rock (stone / splash band / wet) - THE ANCHOR PART
#   Lampwork_Shop   workshop shell + roof + fittings, gantry, jetty, lamp posts
#   Lampwork_Lamps  every lamp body, the great lamp, the glass stock
#   Lampwork_Glow   the one lit window
#   Lampwork_Moths  the moths (the float exemption)

_ISLET_LAMP_SEED = 5507

# The shop's frame. Local -y is the OPEN forge face and points at Roblox +Z -
# the bearing you sail in on - so the boat sees straight into the workshop.
# The one lit window is on the +x gable, which the same approach reads at a
# three-quarter angle.
_ISLET_LAMP_SX, _ISLET_LAMP_SY = -6.0, 12.0  # workshop centre (Blender)
_ISLET_LAMP_HX, _ISLET_LAMP_HY = 10.0, 7.5  # half-extents
_ISLET_LAMP_T = 0.8  # wall thickness
_ISLET_LAMP_KNEE = 2.6  # height of the stone lower courses
_ISLET_LAMP_WALL_H = 9.0  # floor -> wall top
# The lit window (width along y, height). Deliberately BIG for a 20-stud
# gable: at 3.4 x 2.8 it foreshortened to ~18px on the sail-in and lost the
# read to the brass on the yard lamps. It is the only light on the islet and
# has to win from a boat.
_ISLET_LAMP_WIN = (4.4, 3.2)
_ISLET_LAMP_WIN_Z = 3.7  # its sill above the floor
# The gantry stands on the seaward LEFT quarter, not the right: on the right
# it sat between the boat and the one lit window and hid it (round-1 preview).
# From here the sail-in gets all three beats at once - the great lamp dark in
# the foreground, the yard dark behind it, the window burning on the gable.
_ISLET_LAMP_GANTRY = (-23.0, -18.0)  # the great lamp's gantry
_ISLET_LAMP_STAND = (-6.0, -2.5)  # the Lampwright's clear 8x8 pad

# (x, y, post height, lamp radius) - the yard. Hand-placed, not scattered, so
# every one is provably clear of the shop footprint, the NPC pad, the gantry
# and the jetty lane, and so the sizes step the way a lampwright's stock would.
_ISLET_LAMP_YARD = [
    (12.0, 2.0, 5.6, 0.85),
    (16.5, 7.0, 4.0, 0.70),
    (20.5, -2.5, 6.4, 0.95),
    (6.5, -9.0, 3.4, 0.62),
    (-2.5, -15.0, 5.9, 0.88),
    (-9.5, -21.0, 4.6, 0.72),
    (-22.5, -1.5, 6.1, 0.90),
    (-24.5, 8.5, 3.8, 0.66),
    (-20.0, 17.5, 5.2, 0.80),
    (9.5, 20.5, 4.4, 0.74),
    (20.0, 14.5, 5.7, 0.86),
    (-11.5, 24.5, 3.2, 0.60),
]


# ---------------------------------------------------------------- the void
#
# The Lampwright's rock does not end in a beach on every bearing. On the
# seaward third the ground simply STOPS: the shelf runs out level, lifts a
# little as if bracing itself, and then falls in ONE WALL to the trench floor.
# The other side keeps its shore - a low wet apron with tide pools on it.
# Safe side and nothing side, and the jetty is thrown out over the nothing.
_LAMP_VOID_DIR = -math.pi / 2  # Blender -y = Roblox +Z: the sail-in bearing
_LAMP_VOID_HALF = 1.30  # half-width (radians) of the sector cut away
_LAMP_VOID_CORE = 0.88  # inside this the wall is dead vertical
_LAMP_LIP_RING = 4  # index into RINGS[1:] of the u=0.80 lip ring
# Per-ring lift of the rings INSIDE the lip, so the headland tilts UP into the
# drop: an edge you can see coming, not a fade.
_LAMP_LIP_LIFT = (0.0, 0.0, 0.55, 1.5, 2.9)
# Radius of each ring OUTSIDE the lip as a multiple of the lip's own radius,
# every one of them slammed to SKIRT_BOTTOM. The first is 1.0 - the wall
# itself, perfectly plumb - and the rest is the trench floor spreading from
# its foot, which wears M_LampTrench so the water over it reads black.
_LAMP_VOID_SPREAD = (1.0, 1.08, 1.20, 1.38, 1.66)

_LAMP_LIGHTHOUSE = (17.5, -16.5)  # the stump of the tower he never finished
_LAMP_FORGE = (-13.5, 0.6)  # the outdoor forge, cold
_LAMP_GALLOWS = (2.0, 13.2, -4.2)  # x0, x1, y - the row of failed lamps


def _islet_lamp_paint(bm, first, index):
    """Give every face added since `first` a material slot - how one object
    carries stone as well as timber, slate and iron (the importer splits it
    into <Name> / <Name>2 / ..., which is what MESH_COLOR keys)."""
    for f in list(bm.faces)[first:]:
        f.material_index = index


def _lamp_void_w(theta):
    """How completely the ground is gone on this bearing: 1 across the core of
    the seaward sector, 0 on the safe side, and a smooth shoulder between so
    the wall turns into the tide-pool shore instead of tearing off it."""
    d = abs(((theta - _LAMP_VOID_DIR + math.pi) % math.tau) - math.pi)
    if d >= _LAMP_VOID_HALF:
        return 0.0
    if d <= _LAMP_VOID_CORE:
        return 1.0
    return 1.0 - smoothstep(_LAMP_VOID_CORE, _LAMP_VOID_HALF, d)


def _lamp_carve_void(base):
    """Take the seaward third of the finished base mesh and stand a cliff in
    its place. The radial fan is not re-topologised - every ring outside the
    lip is simply PULLED IN onto the lip's own footprint and dropped to
    SKIRT_BOTTOM, which turns one band of quads into a plumb wall and the rest
    into the trench floor. Watertight by construction, bottom exactly -9, and
    the shoulders lerp by _lamp_void_w so the safe side is untouched.

    The wall is repainted M_LampStone (the cliff is rock, not splash band) and
    the floor beyond it M_LampTrench in a fourth slot appended here - which is
    why the base imports as Lampwork_Base ... Lampwork_Base4."""
    verts = base.data.vertices
    n = SEGMENTS

    def vert(ring, s):
        return verts[1 + ring * n + s]

    for ring, lift in enumerate(_LAMP_LIP_LIFT):
        if lift == 0.0:
            continue
        for s in range(n):
            v = vert(ring, s)
            v.co.z += lift * _lamp_void_w(math.atan2(v.co.y, v.co.x))

    # Vertical ribbing: the LIP ring's own footprint is wobbled in and out, and
    # because every ring below inherits it the wall comes out fluted in plumb
    # ribs instead of one flat slab (round 1's cliff read as poured concrete).
    for s in range(n):
        v = vert(_LAMP_LIP_RING, s)
        w = _lamp_void_w(math.atan2(v.co.y, v.co.x))
        if w <= 0.0:
            continue
        f = 1.0 + (0.055 * math.sin(s * 2.7) + 0.035 * math.sin(s * 1.13 + 1.7)) * w
        v.co.x *= f
        v.co.y *= f

    for k, spread in enumerate(_LAMP_VOID_SPREAD):
        ring = _LAMP_LIP_RING + 1 + k
        for s in range(n):
            v, lip = vert(ring, s), vert(_LAMP_LIP_RING, s)
            w = _lamp_void_w(math.atan2(v.co.y, v.co.x))
            if w <= 0.0:
                continue
            v.co.x += (lip.co.x * spread - v.co.x) * w
            v.co.y += (lip.co.y * spread - v.co.y) * w
            v.co.z += (SKIRT_BOTTOM - v.co.z) * w

    base.data.materials.append(bpy.data.materials["M_LampTrench"])
    polys = base.data.polygons
    for band in range(_LAMP_LIP_RING, len(RINGS) - 2):
        for s in range(n):
            p = polys[n * (1 + band) + s]
            cx = sum(verts[i].co.x for i in p.vertices) / len(p.vertices)
            cy = sum(verts[i].co.y for i in p.vertices) / len(p.vertices)
            if _lamp_void_w(math.atan2(cy, cx)) < 0.45:
                continue
            p.material_index = 0 if band == _LAMP_LIP_RING else 3


def _islet_lamp_lamp(bm, x, y, z0, height, radius, i_brass, i_glass):
    """ONE FINISHED LAMP, standing on (or hung from) whatever is at z0: brass
    foot, glass drum, brass cap. Built DARK, always - the drum is M_LampGlass,
    the cold grey-green of an unlit pane, and no lamp on this islet ever gets
    a face in the Glow object. That is the whole point of the yard."""
    foot = height * 0.16
    body = height * 0.58
    first = len(bm.faces)
    add_post(bm, x, y, z0, z0 + foot, radius * 0.92, sides=6)
    _islet_lamp_paint(bm, first, i_brass)
    first = len(bm.faces)
    add_post(bm, x, y, z0 + foot - 0.03, z0 + foot + body, radius, sides=6)
    _islet_lamp_paint(bm, first, i_glass)
    first = len(bm.faces)
    add_cone(bm, (x, y, z0 + foot + body - 0.05), radius * 1.2, radius * 0.24, height - foot - body, sides=6)
    _islet_lamp_paint(bm, first, i_brass)


def _lamp_failed(bm, x, y, z_top, size, i_brass, i_glass, broken):
    """A lamp that did not come out right, hung by its ring from a gallows beam
    head-down like game. `broken` drops the drum and leaves the brass cage
    empty - the ones whose glass went in the annealing."""
    r = size
    first = len(bm.faces)
    add_post(bm, x, y, z_top - r * 0.5, z_top, r * 0.22, sides=4)  # the ring
    add_post(bm, x, y, z_top - r * 0.9, z_top - r * 0.45, r * 1.05, sides=6)  # the cap, uppermost
    _islet_lamp_paint(bm, first, i_brass)
    if not broken:
        first = len(bm.faces)
        add_post(bm, x, y, z_top - r * 3.0, z_top - r * 0.85, r * 0.92, sides=6)
        _islet_lamp_paint(bm, first, i_glass)
    else:
        first = len(bm.faces)
        for k in range(4):
            aa = k * math.pi / 2 + math.pi / 4
            add_box(bm, (x + math.cos(aa) * r * 0.8, y + math.sin(aa) * r * 0.8, z_top - r * 1.9),
                    (0.16, 0.16, r * 2.1), yaw=aa)
        _islet_lamp_paint(bm, first, i_brass)
    first = len(bm.faces)
    add_post(bm, x, y, z_top - r * 3.4, z_top - r * 2.95, r * 0.85, sides=6)  # the foot, lowest
    _islet_lamp_paint(bm, first, i_brass)


def _islet_lamp_moth(bm, x, y, z, s, yaw, dihedral):
    """One pale moth: a stubby body and two broad wings held in a V. The wings
    are ORIENTED QUADS, not axis-aligned boxes - round 1 built them flat and
    horizontal and the whole cloud read as paper darts seen edge-on from every
    eye-level camera. `dihedral` is how far the wings are cocked up (0 = flat,
    the pose the dead ones on the sill are in). THE ONE THING ON THIS ISLET
    ALLOWED TO HOVER, and it only ever goes into Lampwork_Moths."""
    add_box(bm, (x, y, z), (s * 0.55, s * 0.18, s * 0.18), yaw=yaw)
    c = Vector((x, y, z))
    fwd = Vector((math.cos(yaw), math.sin(yaw), 0.0))
    side = Vector((-math.sin(yaw), math.cos(yaw), 0.0))
    for k in (-1, 1):
        out = (side * (k * math.cos(dihedral)) + Vector((0.0, 0.0, math.sin(dihedral)))) * s
        root_f = c + fwd * (s * 0.30)
        root_b = c - fwd * (s * 0.30)
        _hut_maren_quad_slab(
            bm,
            [root_f, root_f + out * 0.95 + fwd * (s * 0.05), root_b + out * 0.80 - fwd * (s * 0.18), root_b],
            s * 0.05,
        )


def build_islet_lampwork():
    """The Lampwright's Workshop, on a shelf cantilevered over the trench.

    Deterministic on its own Random(5507), and the shared stream is saved and
    handed back exactly as found (the hut builders' rule) so this islet cannot
    move one prop on any island that builds after it."""
    shared_state = random.getstate()
    rng = random.Random(_ISLET_LAMP_SEED)

    base = build_island_base("Lampwork_Base", ["M_LampStone", "M_LampShore", "M_LampWet"])
    _lamp_carve_void(base)  # BEFORE the BVH: every prop must raycast the cliff
    ground = _ground_bvh(base)

    def gz(x, y):
        """The REAL faceted rock under a point - raycast, never the smooth
        profile, which knows nothing about the cliff. Off the lip this returns
        the trench floor at -9, which is how the jetty finds the edge."""
        g = _drop_to_ground(ground, x, y)
        return g if g is not None else SKIRT_BOTTOM

    shop, lamps, glow, moths = bmesh.new(), bmesh.new(), bmesh.new(), bmesh.new()
    yard, rock = bmesh.new(), bmesh.new()
    WALL, TIMBER, SLATE, IRON = 0, 1, 2, 3  # Lampwork_Shop slots
    BRASS, GLASS = 0, 1  # Lampwork_Lamps slots
    CLAY, ROPE = 0, 1  # Lampwork_Yard slots
    STONE, WET, TRENCH = 0, 1, 2  # Lampwork_Rock slots

    def box(bm, center, size, index=0, yaw=0.0):
        first = len(bm.faces)
        add_box(bm, center, size, yaw=yaw)
        _islet_lamp_paint(bm, first, index)

    def post(bm, x, y, z0, z1, r, index=0, sides=6):
        first = len(bm.faces)
        add_post(bm, x, y, z0, z1, r, sides=sides)
        _islet_lamp_paint(bm, first, index)

    def cone(bm, center, r0, r1, h, index=0, sides=6, tilt=(0.0, 0.0), yaw=0.0):
        first = len(bm.faces)
        add_cone(bm, center, r0, r1, h, sides=sides, tilt=tilt, yaw=yaw)
        _islet_lamp_paint(bm, first, index)

    def slab(bm, corners, thickness, index=0):
        first = len(bm.faces)
        _hut_maren_quad_slab(bm, corners, thickness)
        _islet_lamp_paint(bm, first, index)

    def blob(bm, center, scale, roughness, salt, index=0, yaw=0.0):
        first = len(bm.faces)
        add_blob(bm, center, scale, roughness, salt, yaw=yaw)
        _islet_lamp_paint(bm, first, index)

    SX, SY = _ISLET_LAMP_SX, _ISLET_LAMP_SY
    HX, HY = _ISLET_LAMP_HX, _ISLET_LAMP_HY
    T, KNEE, WH = _ISLET_LAMP_T, _ISLET_LAMP_KNEE, _ISLET_LAMP_WALL_H
    FRONT, BACK = SY - HY, SY + HY  # FRONT (-y) is the open forge face
    LEFT, RIGHT = SX - HX, SX + HX  # RIGHT (+x) is the gable with the window

    # The floor is LEVEL, and level at the HIGHEST rock under the footprint,
    # so the ledge can never heave up through the boards; the plinth below
    # swallows the fall to the low corner.
    FLOOR = max(gz(SX + dx, SY + dy) for dx in (-HX, -HX / 2, 0.0, HX / 2, HX)
                for dy in (-HY, -HY / 2, 0.0, HY / 2, HY)) + 0.10

    # ---- shell: stone plinth, stone knee courses, timber boarding above ----
    box(shop, (SX, SY, FLOOR - 0.75), (2 * HX + 1.8, 2 * HY + 1.8, 1.7), WALL)
    box(shop, (SX, SY, FLOOR - 0.18), (2 * (HX - T), 2 * (HY - T), 0.42), TIMBER)

    KZ, KM = FLOOR + (KNEE - 0.15) / 2, KNEE + 0.15  # walls foot 0.15 INTO the floor
    box(shop, (SX, BACK - T / 2, KZ), (2 * HX, T, KM), WALL)
    box(shop, (LEFT + T / 2, SY, KZ), (T, 2 * HY, KM), WALL)
    box(shop, (RIGHT - T / 2, SY, KZ), (T, 2 * HY, KM), WALL)
    for s in (-1, 1):  # short returns leave a 12-stud opening on the forge face
        box(shop, (SX + s * (HX - 2.0), FRONT + T / 2, KZ), (4.0, T, KM), WALL)

    UZ, UM = FLOOR + KNEE + (WH - KNEE) / 2, WH - KNEE
    box(shop, (SX, BACK - T / 2, UZ), (2 * HX, T, UM), TIMBER)

    # ---- the glazier's wall: the whole -x gable above the knee is SASH, six
    # bays by four lights, every pane dark. It is the exact opposite of the one
    # lit window on the far gable, and it makes the shop read as a glass shop.
    GW0, GW1 = FLOOR + KNEE, FLOOR + WH
    box(shop, (LEFT + T / 2, SY, GW0 + 0.30), (T, 2 * HY, 0.60), TIMBER)  # sill
    box(shop, (LEFT + T / 2, SY, GW1 - 0.32), (T, 2 * HY, 0.64), TIMBER)  # head
    PANE_X = LEFT + T / 2
    BAYS, LIGHTS = 6, 4
    by0, by1 = SY - HY + 0.3, SY + HY - 0.3
    bz0, bz1 = GW0 + 0.60, GW1 - 0.64
    for k in range(BAYS + 1):  # mullions
        box(shop, (PANE_X, by0 + (by1 - by0) * k / BAYS, (bz0 + bz1) / 2), (T + 0.16, 0.42, bz1 - bz0), TIMBER)
    for k in range(1, LIGHTS):  # transoms, iron
        box(shop, (PANE_X, SY, bz0 + (bz1 - bz0) * k / LIGHTS), (T + 0.20, by1 - by0, 0.20), IRON)
    for a in range(BAYS):
        for b in range(LIGHTS):
            box(lamps, (PANE_X, by0 + (by1 - by0) * (a + 0.5) / BAYS, bz0 + (bz1 - bz0) * (b + 0.5) / LIGHTS),
                (0.24, (by1 - by0) / BAYS - 0.5, (bz1 - bz0) / LIGHTS - 0.26), GLASS)

    # The +x gable carries the ONE window: boards under it, over it and to
    # each side, so the lit square is a real hole in a real wall.
    WW, WHG = _ISLET_LAMP_WIN
    W0, W1 = FLOOR + _ISLET_LAMP_WIN_Z, FLOOR + _ISLET_LAMP_WIN_Z + WHG
    box(shop, (RIGHT - T / 2, SY, (FLOOR + KNEE + W0) / 2), (T, 2 * HY, W0 - FLOOR - KNEE), TIMBER)
    box(shop, (RIGHT - T / 2, SY, (W1 + FLOOR + WH) / 2), (T, 2 * HY, FLOOR + WH - W1), TIMBER)
    for s in (-1, 1):
        y0, y1 = SY + s * WW / 2, SY + s * HY
        box(shop, (RIGHT - T / 2, (y0 + y1) / 2, (W0 + W1) / 2), (T, abs(y1 - y0), WHG), TIMBER)

    # Open face: three posts and a header, so the roof is genuinely carried.
    for px in (LEFT + 0.45, SX - 4.0, RIGHT - 0.45):
        box(shop, (px, FRONT + 0.45, FLOOR + WH / 2), (0.75, 0.75, WH), TIMBER)
    box(shop, (SX, FRONT + 0.45, FLOOR + WH - 0.5), (2 * HX + 1.2, 0.85, 1.0), TIMBER)

    # ---- slate roof: a shallow gable, five courses a side ----
    RIDGE_Z, EAVE_Z, EAVE_Y = FLOOR + WH + 3.4, FLOOR + WH - 0.35, HY + 1.6
    RX0, RX1 = LEFT - 1.2, RIGHT + 1.2
    for s in (-1, 1):
        for k in range(5):
            t0 = k / 5.0
            t1 = (k + 1) / 5.0 + (0.0 if k == 4 else 0.06)
            ya, za = SY + s * EAVE_Y * t0, RIDGE_Z + (EAVE_Z - RIDGE_Z) * t0
            yb, zb = SY + s * EAVE_Y * t1, RIDGE_Z + (EAVE_Z - RIDGE_Z) * t1
            slab(shop, [(RX0, ya, za), (RX1, ya, za), (RX1, yb, zb), (RX0, yb, zb)], 0.34, SLATE)
    box(shop, (SX, SY, RIDGE_Z + 0.18), (2 * HX + 1.6, 1.5, 0.55), SLATE)
    for gx in (LEFT + 0.4, RIGHT - 0.4):  # gable tie beams, stopped inside the eaves
        box(shop, (gx, SY, FLOOR + WH + 0.6), (0.5, 2 * HY - 0.4, 0.5), TIMBER)

    # ---- the annealing kiln, COLD: no ember, no glow. Only the window burns.
    KX, KY = LEFT + 2.6, BACK - 2.4
    box(shop, (KX, KY, FLOOR + 1.75), (3.6, 3.0, 3.5), WALL)
    box(shop, (KX, KY - 1.55, FLOOR + 1.5), (2.0, 0.35, 2.0), IRON)
    post(shop, KX, KY, FLOOR + 3.3, RIDGE_Z + 2.6, 0.85, WALL)

    # ---- benches, shelf, tool rail, stool (every leg down to the boards) ----
    BENCH_TOP = FLOOR + 3.0
    box(shop, (-3.9, BACK - T - 1.6, BENCH_TOP - 0.25), (14.2, 3.0, 0.5), TIMBER)
    for lx in (-10.2, -3.9, 2.4):
        box(shop, (lx, BACK - T - 1.6, FLOOR + 1.28), (0.55, 2.6, 2.55), TIMBER)
    box(shop, (LEFT + T + 1.4, SY - 2.2, BENCH_TOP - 0.25), (2.8, 9.0, 0.5), TIMBER)
    for ly in (SY - 6.2, SY - 2.2, SY + 1.8):
        box(shop, (LEFT + T + 1.4, ly, FLOOR + 1.28), (2.4, 0.55, 2.55), TIMBER)
    box(shop, (RIGHT - T - 1.5, SY - 0.5, BENCH_TOP - 0.25), (3.0, 9.0, 0.5), TIMBER)
    for ly in (SY - 4.2, SY + 3.2):
        box(shop, (RIGHT - T - 1.5, ly, FLOOR + 1.28), (2.6, 0.55, 2.55), TIMBER)

    box(shop, (-3.9, BACK - T - 0.8, FLOOR + 6.3), (13.0, 1.4, 0.32), TIMBER)
    for bx in (-9.5, -3.9, 1.7):
        box(shop, (bx, BACK - T - 0.5, FLOOR + 5.6), (0.4, 0.8, 1.4), TIMBER)
    box(shop, (-3.9, BACK - T - 0.35, FLOOR + 5.05), (12.0, 0.24, 0.24), IRON)
    for k in range(8):  # tools hanging off the rail
        ln = 0.9 + (k % 4) * 0.42
        box(shop, (-9.2 + k * 1.55, BACK - T - 0.35, FLOOR + 5.05 - ln / 2), (0.18, 0.18, ln), IRON)
    box(shop, (RIGHT - 4.6, SY - 0.5, FLOOR + 2.05), (1.6, 1.6, 0.3), TIMBER)
    for ox, oy in ((-0.55, -0.55), (0.55, -0.55), (-0.55, 0.55), (0.55, 0.55)):
        box(shop, (RIGHT - 4.6 + ox, SY - 0.5 + oy, FLOOR + 1.0), (0.24, 0.24, 2.0), TIMBER)

    # ---- the one window: frame, projecting sill, iron muntins, and the pane
    box(shop, (RIGHT + 0.12, SY, W0 - 0.28), (0.5, WW + 1.1, 0.55), TIMBER)
    box(shop, (RIGHT + 0.12, SY, W1 + 0.28), (0.5, WW + 1.1, 0.55), TIMBER)
    for s in (-1, 1):
        box(shop, (RIGHT + 0.12, SY + s * (WW / 2 + 0.28), (W0 + W1) / 2), (0.5, 0.55, WHG + 1.1), TIMBER)
    SILL_TOP = W0 - 0.26  # the ledge the dead moths lie on
    box(shop, (RIGHT + 0.75, SY, SILL_TOP - 0.16), (1.9, WW + 1.6, 0.32), TIMBER)
    box(shop, (RIGHT + 0.36, SY, (W0 + W1) / 2), (0.22, 0.2, WHG), IRON)
    box(shop, (RIGHT + 0.36, SY, (W0 + W1) / 2), (0.22, WW, 0.2), IRON)
    for bz_ in (FLOOR + KNEE + 0.5, FLOOR + WH - 0.9):  # battens, so the gable isn't one blank board
        box(shop, (RIGHT + 0.08, SY, bz_), (0.4, 2 * HY - 0.6, 0.34), TIMBER)
    add_box(glow, (RIGHT - T / 2, SY, (W0 + W1) / 2), (T + 0.5, WW, WHG))

    # ---- THE LEAN-TO: where he actually lives, bolted on the back of the
    # shop as an afterthought. Mono-pitch slate off the workshop wall, boarded
    # on three sides and OPEN at the -x end, so the whole of his life - bunk,
    # stove, one chair - is legible from the yard in one look.
    LTX0, LTX1 = SX - HX + 1.4, SX + HX - 6.0
    LTY0, LTY1 = BACK - 0.2, BACK + 8.4
    LT_HI, LT_LO = FLOOR + WH - 0.4, FLOOR + 5.4  # roof z at LTY0 / at LTY1+0.9

    def lt_roof_z(y):
        return LT_HI + (LT_LO - LT_HI) * (y - LTY0) / (LTY1 + 0.9 - LTY0)

    box(shop, ((LTX0 + LTX1) / 2, (LTY0 + LTY1) / 2, FLOOR - 0.75), (LTX1 - LTX0 + 1.6, LTY1 - LTY0 + 1.6, 1.7), WALL)
    box(shop, ((LTX0 + LTX1) / 2, (LTY0 + LTY1) / 2, FLOOR - 0.18), (LTX1 - LTX0, LTY1 - LTY0, 0.42), TIMBER)
    box(shop, ((LTX0 + LTX1) / 2, LTY1 - 0.3, FLOOR + 1.15), (LTX1 - LTX0, 0.6, 2.3), WALL)  # back knee
    box(shop, ((LTX0 + LTX1) / 2, LTY1 - 0.3, FLOOR + 3.9), (LTX1 - LTX0, 0.6, 3.2), TIMBER)  # back boarding
    for k in range(4):  # the +x end wall, stepped up under the rake
        ya = LTY0 + (LTY1 - LTY0) * k / 4.0
        yb = LTY0 + (LTY1 - LTY0) * (k + 1) / 4.0
        top = lt_roof_z((ya + yb) / 2) - 0.30
        box(shop, (LTX1 - 0.3, (ya + yb) / 2, (FLOOR + top) / 2), (0.6, yb - ya, top - FLOOR), TIMBER)
    for py in (LTY0 + 0.4, LTY1 - 0.4):  # the open -x end keeps its two posts
        box(shop, (LTX0 + 0.35, py, (FLOOR + lt_roof_z(py) - 0.3) / 2), (0.7, 0.7, lt_roof_z(py) - 0.3 - FLOOR), TIMBER)
    box(shop, (LTX0 + 0.35, (LTY0 + LTY1) / 2, lt_roof_z((LTY0 + LTY1) / 2) - 0.55),
        (0.7, LTY1 - LTY0, 0.7), TIMBER)  # the eaves plate they carry
    for k in range(4):  # slate, four courses down the pitch
        ya = LTY0 - 0.5 + (LTY1 + 0.9 - LTY0 + 0.5) * k / 4.0
        yb = LTY0 - 0.5 + (LTY1 + 0.9 - LTY0 + 0.5) * (k + 1) / 4.0 + 0.10
        slab(shop, [(LTX0 - 0.9, ya, lt_roof_z(ya)), (LTX1 + 0.9, ya, lt_roof_z(ya)),
                    (LTX1 + 0.9, yb, lt_roof_z(yb)), (LTX0 - 0.9, yb, lt_roof_z(yb))], 0.32, SLATE)
    # a plank door and one small DARK window on the back wall
    box(shop, ((LTX0 + LTX1) / 2 + 3.4, LTY1 + 0.06, FLOOR + 2.2), (2.4, 0.30, 4.4), TIMBER)
    box(shop, (LTX0 + 2.6, LTY1 + 0.06, FLOOR + 4.4), (2.6, 0.34, 1.9), TIMBER)
    box(lamps, (LTX0 + 2.6, LTY1 - 0.10, FLOOR + 4.4), (2.0, 0.24, 1.4), GLASS)
    # bunk: frame, four legs, a straw pallet and a rolled blanket
    BKX, BKY = (LTX0 + LTX1) / 2 - 2.2, LTY1 - 2.3
    box(shop, (BKX, BKY, FLOOR + 1.55), (6.6, 3.0, 0.4), TIMBER)
    for ox, oy in ((-3.0, -1.3), (3.0, -1.3), (-3.0, 1.3), (3.0, 1.3)):
        box(shop, (BKX + ox, BKY + oy, FLOOR + 0.75), (0.35, 0.35, 1.5), TIMBER)
    box(yard, (BKX, BKY, FLOOR + 1.95), (6.2, 2.7, 0.5), ROPE)  # the straw pallet
    box(shop, (BKX - 3.2, BKY, FLOOR + 2.6), (0.4, 3.0, 2.5), TIMBER)  # headboard
    box(yard, (BKX + 1.6, BKY, FLOOR + 2.45), (2.6, 2.6, 0.55), ROPE)  # the blanket, thrown back
    cone(yard, (BKX - 2.2, BKY - 1.0, FLOOR + 2.3), 0.5, 0.5, 1.9, ROPE, sides=6, tilt=(math.pi / 2, 0.0))
    # the stove: a squat stone box, an iron plate, and a pipe out through the slate
    STX, STY = LTX1 - 2.6, LTY0 + 2.4
    box(shop, (STX, STY, FLOOR + 1.25), (2.4, 2.4, 2.5), WALL)
    box(shop, (STX, STY, FLOOR + 2.62), (2.8, 2.8, 0.24), IRON)
    box(shop, (STX, STY - 1.28, FLOOR + 1.1), (1.3, 0.22, 1.2), IRON)  # the cold firebox door
    post(shop, STX, STY, FLOOR + 2.6, lt_roof_z(STY) + 2.4, 0.34, IRON, sides=6)
    cone(shop, (STX, STY, lt_roof_z(STY) + 2.4), 0.5, 0.62, 0.5, IRON, sides=6)
    # one chair, and a small table with a lamp on it that is also not lit
    CHX, CHY = LTX0 + 5.2, LTY0 + 2.4
    box(shop, (CHX, CHY, FLOOR + 1.55), (1.7, 1.7, 0.3), TIMBER)
    for ox, oy in ((-0.65, -0.65), (0.65, -0.65), (-0.65, 0.65), (0.65, 0.65)):
        box(shop, (CHX + ox, CHY + oy, FLOOR + 0.78), (0.26, 0.26, 1.55), TIMBER)
    box(shop, (CHX, CHY + 0.72, FLOOR + 2.6), (1.7, 0.26, 1.8), TIMBER)
    TBX, TBY = LTX1 - 2.8, LTY1 - 2.4
    box(shop, (TBX, TBY, FLOOR + 2.05), (2.6, 2.2, 0.3), TIMBER)
    for ox, oy in ((-1.05, -0.85), (1.05, -0.85), (-1.05, 0.85), (1.05, 0.85)):
        box(shop, (TBX + ox, TBY + oy, FLOOR + 1.0), (0.24, 0.24, 2.0), TIMBER)
    _islet_lamp_lamp(lamps, TBX, TBY, FLOOR + 2.2, 1.7, 0.45, BRASS, GLASS)
    # a shelf over the table, two jars on it, and one more lamp on a rafter
    # hook - the room a man keeps when every lamp he owns is one he failed at
    box(shop, (TBX, LTY1 - 0.75, FLOOR + 5.0), (4.6, 1.1, 0.28), TIMBER)
    for jx_ in (TBX - 1.4, TBX + 1.2):
        box(yard, (jx_, LTY1 - 0.75, FLOOR + 5.14), (1.0, 0.9, 1.3), CLAY)
    box(shop, (LTX0 + 4.2, (LTY0 + LTY1) / 2, lt_roof_z((LTY0 + LTY1) / 2) - 1.0), (0.18, 0.18, 1.3), IRON)
    _islet_lamp_lamp(lamps, LTX0 + 4.2, (LTY0 + LTY1) / 2,
                     lt_roof_z((LTY0 + LTY1) / 2) - 1.65 - 1.9, 1.9, 0.5, BRASS, GLASS)

    # ---- the gantry, and THE GREAT LAMP on top of it ----
    GX, GY = _ISLET_LAMP_GANTRY
    BZ0 = gz(GX, GY) - 0.4
    PLAT = max(gz(GX + dx, GY + dy) for dx in (-3.2, 0.0, 3.2) for dy in (-3.2, 0.0, 3.2)) + 8.2
    for sx_, sy_ in ((-1, -1), (1, -1), (-1, 1), (1, 1)):
        bx, by = GX + sx_ * 3.2, GY + sy_ * 3.2
        bz = gz(bx, by) - 0.4  # every leg foots INTO the rock
        d = Vector((GX + sx_ * 1.7 - bx, GY + sy_ * 1.7 - by, PLAT - bz))
        cone(shop, (bx, by, bz), 0.34, 0.26, d.length, IRON, sides=4, tilt=_tilt_toward(d.normalized()))
    box(shop, (GX, GY, PLAT + 0.35), (5.4, 5.4, 0.7), IRON)
    for k in range(6):  # the ladder he climbs to service it, on the seaward face
        f = 0.14 + k * 0.14
        w = 3.2 - 1.5 * f
        box(shop, (GX, GY - w, BZ0 + (PLAT - BZ0) * f), (2 * w * 0.92, 0.22, 0.22), IRON)
    for ang in (0.0, math.pi / 2, math.pi):  # girth braces on the other three faces
        w = 3.2 - 1.5 * 0.55
        box(shop, (GX + math.cos(ang) * w, GY + math.sin(ang) * w, BZ0 + (PLAT - BZ0) * 0.55),
            (0.3 if abs(math.cos(ang)) > 0.5 else 2 * w, 2 * w if abs(math.cos(ang)) > 0.5 else 0.3, 0.3), IRON)

    LZ = PLAT + 0.7  # the platform's top face - the great lamp SITS on it
    post(lamps, GX, GY, LZ - 0.05, LZ + 1.0, 2.3, BRASS, sides=8)
    post(lamps, GX, GY, LZ + 0.95, LZ + 5.4, 2.0, GLASS, sides=8)
    for k in range(4):
        aa = k * math.pi / 2 + math.pi / 4
        box(lamps, (GX + math.cos(aa) * 1.95, GY + math.sin(aa) * 1.95, LZ + 3.15), (0.34, 0.34, 4.5), BRASS, yaw=aa)
    post(lamps, GX, GY, LZ + 2.9, LZ + 3.4, 2.14, BRASS, sides=8)
    cone(lamps, (GX, GY, LZ + 5.3), 2.5, 0.45, 1.7, BRASS, sides=8)
    post(lamps, GX, GY, LZ + 6.9, LZ + 7.8, 0.28, BRASS, sides=4)

    # ---- the yard: twelve lamps on posts, three on a drying rail, three
    # under the eave. Eighteen finished lamps, and not one of them is lit.
    for lx, ly, ph, lr in _ISLET_LAMP_YARD:
        g = gz(lx, ly)
        post(shop, lx, ly, g - 0.35, g + ph, 0.3, TIMBER, sides=4)
        _islet_lamp_lamp(lamps, lx, ly, g + ph - 0.06, lr * 3.2, lr, BRASS, GLASS)

    RAIL_Y = -5.0
    RAIL_Z = max(gz(-21.0, RAIL_Y), gz(-13.0, RAIL_Y)) + 6.2
    for rx in (-21.0, -13.0):
        post(shop, rx, RAIL_Y, gz(rx, RAIL_Y) - 0.35, RAIL_Z, 0.32, TIMBER, sides=4)
    box(shop, (-17.0, RAIL_Y, RAIL_Z - 0.18), (8.6, 0.35, 0.35), TIMBER)
    for hx, hl, hr in ((-19.4, 1.5, 0.66), (-17.0, 2.3, 0.82), (-14.6, 1.1, 0.56)):
        box(shop, (hx, RAIL_Y, RAIL_Z - 0.35 - hl / 2), (0.2, 0.2, hl), IRON)
        _islet_lamp_lamp(lamps, hx, RAIL_Y, RAIL_Z - 0.35 - hl - hr * 3.2 + 0.06, hr * 3.2, hr, BRASS, GLASS)

    EAVE_HOOK_Z = FLOOR + WH - 1.0
    for hx, hl, hr in ((-13.5, 1.9, 0.62), (-7.5, 2.7, 0.78), (-1.0, 1.4, 0.54)):
        box(shop, (hx, FRONT + 0.45, EAVE_HOOK_Z - hl / 2), (0.2, 0.2, hl), IRON)
        _islet_lamp_lamp(lamps, hx, FRONT + 0.45, EAVE_HOOK_Z - hl - hr * 3.2 + 0.06, hr * 3.2, hr, BRASS, GLASS)

    # ---- THE STUMP OF THE LIGHTHOUSE HE NEVER FINISHED. Three courses of
    # dressed stone eight studs high, each course stepped in a little, a
    # doorway on the shop side, a newel and a stair that climbs nine treads and
    # stops in the open air. He builds lamps beside a dark tower he never
    # finished; that is the man. Around it: the spoil, and the blocks for the
    # fourth course, dressed and squared and lying where they were landed.
    LHX, LHY = _LAMP_LIGHTHOUSE
    LH_G = min(gz(LHX + math.cos(a) * 4.4, LHY + math.sin(a) * 4.4) for a in
               [k * math.tau / 8 for k in range(8)] + [0.0])
    box(shop, (LHX, LHY, LH_G - 0.5), (11.2, 11.2, 1.6), WALL, yaw=0.4)  # the footing it stands on
    LH_FACES = 16
    RAGGED = (0.0, 0.0, 0.9, 1.9, 2.8, 2.8, 1.6, 0.7)  # where he put the trowel down
    for c, (h0, h1, r_out) in enumerate(((0.0, 2.8, 4.5), (2.8, 5.6, 4.34), (5.6, 8.4, 4.18))):
        for k in range(LH_FACES):
            aa = k * math.tau / LH_FACES
            if c == 0 and k in (12, 13):  # the doorway, facing the sail-in
                continue
            top = h1 - (RAGGED[k % 8] if c == 2 else 0.0)
            if top - h0 < 0.4:
                continue  # the top course simply STOPS partway round
            box(shop, (LHX + math.cos(aa) * (r_out - 0.6), LHY + math.sin(aa) * (r_out - 0.6),
                       LH_G + (h0 + top) / 2), (1.2, r_out * 0.44, top - h0), WALL, yaw=aa)
        if c == 2:
            continue
        # the string course that makes each lift read as a separate course
        for k in range(LH_FACES):
            aa = k * math.tau / LH_FACES
            box(shop, (LHX + math.cos(aa) * (r_out - 0.35), LHY + math.sin(aa) * (r_out - 0.35),
                       LH_G + h1 - 0.16), (0.75, r_out * 0.46, 0.32), WALL, yaw=aa)
    box(shop, (LHX + math.cos(math.pi * 1.5625) * 4.1, LHY + math.sin(math.pi * 1.5625) * 4.1,
               LH_G + 4.1), (1.4, 2.8, 0.5), TIMBER, yaw=math.pi * 1.5625)  # the door lintel
    post(shop, LHX, LHY, LH_G, LH_G + 6.6, 0.8, WALL, sides=8)  # the newel
    for k in range(9):  # a stair to nowhere
        aa = math.pi * 1.5625 + 0.52 * (k + 1)
        box(shop, (LHX + math.cos(aa) * 2.05, LHY + math.sin(aa) * 2.05, LH_G + 0.55 + k * 0.68),
            (2.6, 1.4, 0.40), WALL, yaw=aa)
    for k in range(5):  # the fourth course, dressed and never laid
        aa = 1.1 + k * 0.62
        rr = 8.6 + (k % 2) * 1.4
        bx, byy = LHX + math.cos(aa) * rr, LHY + math.sin(aa) * rr
        box(shop, (bx, byy, gz(bx, byy) + 0.55), (3.4, 1.7, 1.1), WALL, yaw=aa + 0.4 * k)
    for k in range(9):  # spoil and offcuts at its foot
        aa = rng.uniform(0, math.tau)
        rr = rng.uniform(6.4, 10.5)
        bx, byy = LHX + math.cos(aa) * rr, LHY + math.sin(aa) * rr
        s = rng.uniform(0.6, 1.4)
        blob(rock, (bx, byy, gz(bx, byy) + s * 0.35), (s * 1.5, s * 1.2, s * 0.7), 0.30, 40.0 + k, STONE,
             yaw=rng.uniform(0, math.tau))

    # ---- THE GALLOWS: a beam on two legs with the failed lamps hung head-down
    # from it in a row, the way a keeper hangs game. Eight of them, three with
    # the glass gone and only the brass cage left.
    GA0, GA1, GAY = _LAMP_GALLOWS
    GA_TOP = max(gz(GA0, GAY), gz(GA1, GAY)) + 8.4
    for gx_ in (GA0, GA1):
        post(shop, gx_, GAY, gz(gx_, GAY) - 0.4, GA_TOP, 0.45, TIMBER, sides=6)
        for s in (-1, 1):  # sole braces, so it does not read as two poles
            box(shop, (gx_ + (1.6 if gx_ == GA0 else -1.6), GAY + s * 1.5, gz(gx_, GAY) + 1.5),
                (3.6, 0.34, 0.34), TIMBER, yaw=0.0)
    box(shop, ((GA0 + GA1) / 2, GAY, GA_TOP - 0.25), (GA1 - GA0 + 1.4, 0.5, 0.5), TIMBER)
    for s_, bx_ in ((1, GA0), (-1, GA1)):  # knee braces under the beam
        box(shop, (bx_ + s_ * 1.3, GAY, GA_TOP - 1.55), (3.4, 0.3, 0.3), TIMBER, yaw=0.0)
        box(shop, (bx_ + s_ * 1.3, GAY, GA_TOP - 1.55), (0.3, 0.3, 3.0), TIMBER)
    for k in range(8):
        hx = GA0 + 1.1 + k * (GA1 - GA0 - 2.2) / 7.0
        drop = 0.5 + (k % 3) * 0.55
        sz = 0.50 + ((k * 3) % 4) * 0.11
        box(shop, (hx, GAY, GA_TOP - 0.5 - drop / 2), (0.16, 0.16, drop), IRON)
        _lamp_failed(lamps, hx, GAY, GA_TOP - 0.5 - drop, sz, BRASS, GLASS, broken=(k % 3 == 1))

    # ---- GLASS STOCK RACKED ON EDGE. Two A-frames in the yard with sheet
    # leaned against them, every pane on edge so it reads as glass and not as
    # a wall, plus the old bench rack of lens blanks inside the shop.
    def pane_rack(cx, cy, yaw_, count, w, h):
        along = Vector((math.cos(yaw_), math.sin(yaw_), 0.0))
        across = Vector((-math.sin(yaw_), math.cos(yaw_), 0.0))
        g = gz(cx, cy)
        c = Vector((cx, cy, g))
        for s in (-1, 1):  # the two A-frames
            f = c + along * (s * (count * 0.36 + 0.9))
            for t in (-1, 1):
                top = f + Vector((0.0, 0.0, h + 0.5))
                foot = f + across * (t * (h * 0.34))
                d = top - foot
                cone(shop, (foot.x, foot.y, g - 0.2), 0.26, 0.20, d.length, TIMBER, sides=4,
                     tilt=_tilt_toward(d.normalized()))
            box(shop, (f.x, f.y, g + 0.35), (0.34 + abs(across.x) * h * 0.6, 0.34 + abs(across.y) * h * 0.6, 0.34),
                TIMBER, yaw=yaw_ + math.pi / 2)
        for k in range(count):
            u = (k - (count - 1) / 2.0) * 0.66
            lean = across * ((0.55 if k % 2 == 0 else -0.55) + (0.10 * k))
            b = c + along * u
            p0 = b - along * 0.0 + across * 0.0
            corners = [
                (p0 + along * (-w / 2)).to_tuple(),
                (p0 + along * (w / 2)).to_tuple(),
                (p0 + along * (w / 2) + lean + Vector((0.0, 0.0, h))).to_tuple(),
                (p0 + along * (-w / 2) + lean + Vector((0.0, 0.0, h))).to_tuple(),
            ]
            slab(lamps, corners, 0.16, GLASS)

    pane_rack(13.0, 16.0, 0.20, 7, 3.6, 4.2)
    pane_rack(-16.5, -12.0, 1.15, 6, 3.2, 3.6)

    for k in range(5):  # lens blanks on edge along the back bench
        cone(lamps, (-8.2 + k * 1.5, BACK - T - 0.7, BENCH_TOP + 0.88), 0.88, 0.85, 0.24, GLASS,
             sides=8, tilt=(math.pi / 2, 0.0))
    CX_, CY_ = 2.6, 0.5
    cg = gz(CX_, CY_)
    box(shop, (CX_, CY_, cg + 0.18), (3.4, 2.4, 0.36), TIMBER)
    for sy_ in (-1, 1):
        box(shop, (CX_, CY_ + sy_ * 1.1, cg + 0.9), (3.4, 0.24, 1.3), TIMBER)
    for sx_ in (-1, 1):
        box(shop, (CX_ + sx_ * 1.6, CY_, cg + 0.9), (0.24, 2.4, 1.3), TIMBER)
    for k in range(3):
        cone(lamps, (CX_ - 0.95 + k * 0.95, CY_ + 0.55, cg + 0.36 + 0.76), 0.76, 0.74, 0.22, GLASS,
             sides=8, tilt=(math.pi / 2, 0.0))

    # ---- THE CRACKED LENS, the size of a cartwheel, leaned against the shed
    # below the lit window. It is the single biggest piece of glass on the
    # islet and it is ruined - two shakes across it in brass-coloured lead.
    LNX, LNY = RIGHT + 1.7, SY + HY - 1.2
    lng = gz(LNX, LNY)
    LEAN = 0.30  # radians off vertical, leaning into the gable
    cone(lamps, (LNX, LNY, lng + 0.15), 2.95, 2.75, 0.55, GLASS, sides=14,
         tilt=_tilt_toward(Vector((-math.sin(LEAN), 0.0, math.cos(LEAN)))))
    for kk, (off, tl) in enumerate(((0.0, 0.55), (0.9, -0.9))):  # the cracks
        box(lamps, (LNX - math.sin(LEAN) * 2.9 + off * 0.2, LNY + off, lng + 2.9),
            (0.20, 5.0, 0.20), BRASS, yaw=tl)
    box(shop, (LNX + 0.9, LNY, lng + 0.35), (2.2, 5.2, 0.7), TIMBER)  # the batten it rests its foot on

    # ---- THE COLD FORGE. Stone hearth, iron hood, a chimney, an anvil, a
    # quench trough and the bellows - and no fire in it, because nothing on
    # this islet burns except the window.
    FGX, FGY = _LAMP_FORGE
    fg = gz(FGX, FGY)
    box(shop, (FGX, FGY, fg + 1.35), (6.4, 4.4, 2.7), WALL)
    box(shop, (FGX, FGY, fg + 2.78), (6.8, 4.8, 0.3), WALL)
    box(shop, (FGX, FGY - 0.2, fg + 2.2), (4.2, 3.0, 1.4), IRON)  # the dead firebox
    for s in (-1, 1):  # the hood, two rakes and a lintel
        slab(shop, [(FGX - 3.2, FGY + s * 2.2, fg + 3.0), (FGX + 3.2, FGY + s * 2.2, fg + 3.0),
                    (FGX + 3.2, FGY + s * 0.8, fg + 5.4), (FGX - 3.2, FGY + s * 0.8, fg + 5.4)], 0.28, IRON)
    box(shop, (FGX, FGY, fg + 5.5), (6.6, 2.0, 0.4), IRON)
    post(shop, FGX, FGY, fg + 5.5, fg + 10.6, 1.05, WALL, sides=6)
    box(shop, (FGX, FGY, fg + 10.8), (2.9, 2.9, 0.5), WALL)
    ANX, ANY = FGX + 4.6, FGY - 1.6  # the anvil, on its block
    ang_ = gz(ANX, ANY)
    post(shop, ANX, ANY, ang_ - 0.3, ang_ + 1.5, 0.9, TIMBER, sides=6)
    box(shop, (ANX, ANY, ang_ + 1.8), (2.9, 1.1, 0.6), IRON)
    box(shop, (ANX, ANY, ang_ + 1.35), (1.4, 0.8, 0.5), IRON)
    QX, QY = FGX - 4.4, FGY - 1.2  # the quench trough
    qg = gz(QX, QY)
    box(shop, (QX, QY, qg + 0.55), (2.0, 3.6, 1.1), TIMBER)
    box(rock, (QX, QY, qg + 1.02), (1.6, 3.2, 0.16), TRENCH)  # black water in it
    for s in (-1, 1):  # the bellows, hung off the forge's back
        slab(shop, [(FGX - 1.6, FGY + 2.3, fg + 2.6), (FGX + 1.6, FGY + 2.3, fg + 2.6),
                    (FGX + 1.2, FGY + 4.6, fg + 2.6 + s * 0.5), (FGX - 1.2, FGY + 4.6, fg + 2.6 + s * 0.5)],
             0.24, TIMBER)

    # ---- BRASS FITTINGS IN OPEN TRAYS. A trestle table with six shallow
    # trays on it, each one full of collars, rings and burners graded by size.
    TRX, TRY = 6.2, 3.2
    trg = gz(TRX, TRY)
    box(shop, (TRX, TRY, trg + 2.15), (7.2, 3.4, 0.34), TIMBER)
    for ox in (-3.0, 3.0):  # trestles
        box(shop, (TRX + ox, TRY, trg + 1.0), (0.4, 3.0, 2.2), TIMBER)
        box(shop, (TRX + ox, TRY, trg + 0.15), (0.4, 3.6, 0.3), TIMBER)
    for a in range(3):
        for b in range(2):
            tx = TRX - 2.3 + a * 2.3
            ty = TRY - 0.8 + b * 1.6
            box(shop, (tx, ty, trg + 2.45), (2.0, 1.4, 0.26), TIMBER)
            for s in (-1, 1):
                box(shop, (tx + s * 1.0, ty, trg + 2.58), (0.16, 1.4, 0.36), TIMBER)
                box(shop, (tx, ty + s * 0.7, trg + 2.58), (2.0, 0.16, 0.36), TIMBER)
            for k in range(5):  # the fittings themselves
                fx = tx + rng.uniform(-0.75, 0.75)
                fy = ty + rng.uniform(-0.45, 0.45)
                rr = rng.uniform(0.16, 0.30)
                post(lamps, fx, fy, trg + 2.58, trg + 2.58 + rng.uniform(0.22, 0.5), rr, BRASS, sides=6)
    for k in range(9):  # and more loose on the shop's back bench
        box(lamps, (rng.uniform(-9.0, 2.0), BACK - T - 1.6 + rng.uniform(-1.0, 1.0), BENCH_TOP + 0.22),
            (rng.uniform(0.3, 0.6), rng.uniform(0.3, 0.6), 0.44), BRASS, yaw=rng.uniform(0, math.tau))

    # ---- WICK AND OIL. Coils of flat-plaited wick on a low rack and in a
    # barrel, hanks of it hung under the eave, and the oil jars: fat sealed
    # clay bellies in a straw collar, stacked two deep against the shop.
    WKX, WKY = -19.6, 3.4
    wkg = gz(WKX, WKY)
    box(shop, (WKX, WKY, wkg + 0.2), (5.0, 3.0, 0.4), TIMBER)
    for ox in (-2.1, 2.1):
        box(shop, (WKX + ox, WKY, wkg + 0.85), (0.4, 2.8, 1.3), TIMBER)
    for k in range(6):  # coils, stacked and leaning
        cx_ = WKX - 1.8 + (k % 3) * 1.8
        cy_ = WKY - 0.7 + (k // 3) * 1.4
        cone(yard, (cx_, cy_, wkg + 0.4 + (k // 3) * 0.05), 0.85, 0.80, 0.42, ROPE, sides=10)
        cone(yard, (cx_, cy_, wkg + 0.78), 0.62, 0.58, 0.30, ROPE, sides=10)
    post(shop, WKX + 3.9, WKY, wkg - 0.2, wkg + 2.4, 1.25, TIMBER, sides=8)  # the wick barrel
    for k in range(3):
        cone(yard, (WKX + 3.9 + (k - 1) * 0.4, WKY + (k % 2) * 0.4, wkg + 2.4), 0.55, 0.5, 0.35, ROPE, sides=8)
    for k in range(5):  # hanks hanging under the shop eave
        hx = LEFT + 1.6 + k * 3.4
        box(yard, (hx, FRONT + 0.05, FLOOR + WH - 2.2), (0.36, 0.36, 2.0), ROPE)
        cone(yard, (hx, FRONT + 0.05, FLOOR + WH - 2.5), 0.42, 0.10, 0.42, ROPE, sides=6)

    def oil_jar(x, y, z, s):
        post(yard, x, y, z, z + s * 0.35, s * 0.55, CLAY, sides=8)
        post(yard, x, y, z + s * 0.30, z + s * 1.5, s * 0.86, CLAY, sides=8)
        cone(yard, (x, y, z + s * 1.45), s * 0.84, s * 0.34, s * 0.7, CLAY, sides=8)
        post(yard, x, y, z + s * 2.1, z + s * 2.35, s * 0.40, CLAY, sides=8)
        cone(yard, (x, y, z + s * 0.25), s * 0.92, s * 0.88, s * 0.25, ROPE, sides=8)

    JAR_SPOTS = [(-18.9, 8.8, 1.0), (-17.6, 10.6, 0.85), (-19.4, 12.2, 1.1), (-17.2, 13.8, 0.8),
                 (5.4, 0.2, 0.95), (7.6, -1.4, 0.8), (3.2, -1.8, 1.05),
                 (-3.2, 3.0, 0.9), (-0.4, 2.2, 0.75),
                 (13.4, -10.6, 1.0), (11.4, -12.4, 0.85), (15.2, -12.8, 0.9),
                 (-25.5, 4.2, 0.95), (-27.0, 1.0, 0.8)]
    for jx, jy, js in JAR_SPOTS:
        oil_jar(jx, jy, gz(jx, jy) - 0.1, js * 1.5)

    # ---- THE LIP. Iron stakes and a slack rope along the top of the drop -
    # the only thing between the yard and eighteen studs of nothing - and a
    # line of rubble tipped over the edge where he squared the ledge off.
    def lip_at(theta):
        """Walk out along a bearing until the rock quits: the true edge, from
        the raycast, so the rail follows the wall the mesh actually has."""
        r = 30.0
        while r < 60.0 and gz(math.cos(theta) * (r + 0.5), math.sin(theta) * (r + 0.5)) > 4.0:
            r += 0.5
        return r

    stake_pts = []
    for k in range(13):
        th = _LAMP_VOID_DIR - 0.98 + k * (1.96 / 12.0)
        r = lip_at(th) - 2.6
        sx_, sy_ = math.cos(th) * r, math.sin(th) * r
        if abs(sx_) < 4.0 and sy_ < -20.0:  # leave the jetty lane open
            stake_pts.append(None)
            continue
        g = gz(sx_, sy_)
        post(shop, sx_, sy_, g - 0.4, g + 2.6, 0.20, IRON, sides=4)
        stake_pts.append((sx_, sy_, g + 2.3))
    for a in range(len(stake_pts) - 1):
        p, q = stake_pts[a], stake_pts[a + 1]
        if p is None or q is None:
            continue
        mid = ((p[0] + q[0]) / 2, (p[1] + q[1]) / 2, (p[2] + q[2]) / 2 - 0.75)
        for a_, b_ in ((p, mid), (mid, q)):  # two runs, so the rope hangs
            slab(yard, [(a_[0], a_[1], a_[2]), (b_[0], b_[1], b_[2]),
                        (b_[0] + 0.16, b_[1] + 0.16, b_[2]), (a_[0] + 0.16, a_[1] + 0.16, a_[2])], 0.16, ROPE)

    # ---- THE JETTY, thrown out OVER the void: a ramp off the lip, then a flat
    # deck on piles that run thirteen studs down through black water to the
    # trench floor. Nothing under it but the drop.
    y_lip = -30.0
    while y_lip > -70.0 and gz(0.0, y_lip - 0.4) > 4.0:
        y_lip -= 0.4
    y_root = y_lip + 5.0
    DECK0 = gz(0.0, y_root) + 0.6
    y_mid, y_head = y_lip - 13.0, y_lip - 31.0
    DECK1 = 3.6

    def ramp_z(y):
        t = (y_root - y) / (y_root - y_mid)
        return DECK0 + (DECK1 - DECK0) * max(0.0, min(1.0, t))

    slab(shop, [(-2.7, y_root, DECK0), (2.7, y_root, DECK0), (2.7, y_mid, DECK1), (-2.7, y_mid, DECK1)], 0.55, TIMBER)
    box(shop, (0.0, (y_mid + y_head) / 2, DECK1 - 0.28), (5.4, y_mid - y_head, 0.56), TIMBER)
    for sx_ in (-2.2, 2.2):
        box(shop, (sx_, (y_mid + y_head) / 2, DECK1 - 0.85), (0.5, y_mid - y_head, 0.6), TIMBER)
    PILE_Y = [y_lip - 2.0, y_mid + 0.5, y_mid - 5.0, y_mid - 11.0, y_head + 1.5]
    for py in PILE_Y:
        z_top = ramp_z(py) - 0.45 if py > y_mid else DECK1 - 0.45
        for sx_ in (-2.2, 2.2):
            post(shop, sx_, py, SKIRT_BOTTOM + 0.2, z_top, 0.44, TIMBER)
        box(shop, (0.0, py, min(z_top - 1.6, 1.2)), (4.6, 0.34, 0.34), TIMBER)  # a cross tie in the water
    for k in range(len(PILE_Y) - 1):  # raking braces between the bents
        pa, pb = PILE_Y[k], PILE_Y[k + 1]
        for sx_ in (-2.2, 2.2):
            d = Vector((0.0, pb - pa, 3.2))
            cone(shop, (sx_, pa, -1.4), 0.22, 0.18, d.length, TIMBER, sides=4,
                 tilt=_tilt_toward(d.normalized()))
    for k in range(7):  # handrail down the ramp and along the deck, one side
        ry = y_root - 1.5 - k * 5.5
        rz = ramp_z(ry) if ry > y_mid else DECK1
        post(shop, 2.45, ry, rz - 0.4, rz + 2.0, 0.18, TIMBER, sides=4)
        if k:
            py0 = y_root - 1.5 - (k - 1) * 5.5
            pz0 = ramp_z(py0) if py0 > y_mid else DECK1
            slab(shop, [(2.30, py0, pz0 + 1.9), (2.30, ry, rz + 1.9),
                        (2.60, ry, rz + 1.9), (2.60, py0, pz0 + 1.9)], 0.22, TIMBER)
    post(shop, 0.0, y_head + 1.6, DECK1 - 0.4, DECK1 + 2.2, 0.45, TIMBER)  # the bollard
    for sx_ in (-2.3, 2.3):  # mooring cleats
        box(shop, (sx_, y_head + 6.0, DECK1 + 0.34), (0.55, 1.6, 0.45), IRON)
    # a lamp on a post at the head, and it is dark too
    post(shop, -2.45, y_head + 2.4, DECK1 - 0.4, DECK1 + 4.6, 0.26, TIMBER, sides=4)
    _islet_lamp_lamp(lamps, -2.45, y_head + 2.4, DECK1 + 4.55, 2.6, 0.72, BRASS, GLASS)

    # ---- THE SAFE SIDE: a wet apron with tide pools in it. The pools carry
    # the same near-black as the trench floor, so the two waters rhyme - one
    # you can stand in, one you cannot.
    def pool(theta, target_z, radius):
        r = 40.0
        best, best_d = None, 1e9
        while r < 62.0:
            x_, y_ = math.cos(theta) * r, math.sin(theta) * r
            g = gz(x_, y_)
            if abs(g - target_z) < best_d:
                best, best_d = (x_, y_, g), abs(g - target_z)
            r += 0.4
        if best is None:
            return
        px, py, pg = best
        cone(rock, (px, py, pg - 0.55), radius, radius * 0.94, 0.62, TRENCH, sides=10)
        for k in range(9):  # the rim it sits in
            aa = k * math.tau / 9 + theta
            rr = radius * rng.uniform(1.02, 1.22)
            bx, byy = px + math.cos(aa) * rr, py + math.sin(aa) * rr
            s = radius * rng.uniform(0.30, 0.52)
            blob(rock, (bx, byy, gz(bx, byy) + s * 0.25), (s * 1.4, s * 1.1, s * 0.75), 0.34,
                 70.0 + k + theta, WET, yaw=aa)

    for th_deg, tz, rad in ((8.0, 1.7, 3.4), (44.0, 1.5, 4.2), (82.0, 1.8, 3.0),
                            (118.0, 1.5, 4.6), (152.0, 1.7, 3.2), (176.0, 1.6, 2.6)):
        pool(math.radians(th_deg), tz, rad)

    # sea stacks off the safe shore, and boulders all over the shelf: the rock
    # must never read as a bald grey disc with objects standing on it.
    for th_deg, rr, s in ((26.0, 62.0, 3.4), (66.0, 66.0, 4.6), (104.0, 60.0, 2.8), (140.0, 65.0, 3.9)):
        th = math.radians(th_deg)
        blob(rock, (math.cos(th) * rr, math.sin(th) * rr, 1.4),
             (s, s * 0.82, s * 1.9), 0.30, 90.0 + th_deg, STONE, yaw=th)

    # and three stacks standing IN the void, off the cliff foot: the only
    # things out there, and the scale that tells you how far down it goes.
    for th_deg, out, s, h in ((-118.0, 9.0, 3.2, 9.0), (-72.0, 15.0, 2.4, 7.2), (-46.0, 8.5, 2.8, 8.4)):
        th = math.radians(th_deg)
        rr = lip_at(th) + out
        blob(rock, (math.cos(th) * rr, math.sin(th) * rr, h * 0.5 - 4.0),
             (s, s * 0.8, h * 0.62), 0.28, 150.0 + th_deg, STONE, yaw=th)

    stand = _ISLET_LAMP_STAND
    keep_out = [(stand[0], stand[1], 8.0), (GX, GY, 8.5), (LHX, LHY, 12.0), (FGX, FGY, 8.0),
                (TRX, TRY, 7.0), (WKX, WKY, 7.0), (13.0, 16.0, 8.0), (-16.5, -12.0, 7.5),
                (CX_, CY_, 5.0), (-17.0, RAIL_Y, 8.0), (LNX, LNY, 6.0),
                ((GA0 + GA1) / 2, GAY, 9.0), (0.0, -34.0, 9.0)]
    keep_out += [(lx, ly, 4.0) for lx, ly, _p, _r in _ISLET_LAMP_YARD]
    keep_out += [(jx, jy, 3.0) for jx, jy, _s in JAR_SPOTS]

    def clear(x, y, pad):
        if LEFT - 5.0 - pad < x < RIGHT + 5.0 + pad and FRONT - 5.0 - pad < y < LTY1 + 4.0 + pad:
            return False
        return all(math.hypot(x - kx, y - ky) > kr + pad for kx, ky, kr in keep_out)

    placed = 0
    tries = 0
    while placed < 34 and tries < 900:
        tries += 1
        th = rng.uniform(0, math.tau)
        rr = rng.uniform(14.0, 42.0)
        bx, byy = math.cos(th) * rr, math.sin(th) * rr
        s = rng.uniform(0.7, 2.3)
        if not clear(bx, byy, s * 1.4):
            continue
        g = gz(bx, byy)
        if g < 5.0:
            continue
        blob(rock, (bx, byy, g + s * 0.42), (s * 1.7, s * 1.35, s * 0.95), 0.32, 120.0 + placed,
             STONE if placed % 4 else WET, yaw=rng.uniform(0, math.tau))
        placed += 1

    # ---- MOTHS. Thick at the pane, thinning outward; six dead on the sill
    # and three more at the wall foot. The only things on this rock that hover.
    wx, wy, wz = RIGHT + 0.5, SY, (W0 + W1) / 2
    for k in range(30):
        mx = wx + 0.55 + (rng.random() ** 1.5) * 4.0
        my = wy + max(-2.4, min(2.4, rng.gauss(0.0, 1.15)))
        mz = wz + max(-2.3, min(2.3, rng.gauss(0.0, 1.05)))
        _islet_lamp_moth(moths, mx, my, mz, rng.uniform(0.46, 0.78), rng.uniform(0, math.tau), rng.uniform(0.35, 1.15))
    for k in range(8):  # dead on the sill, wings flat
        s = rng.uniform(0.44, 0.66)
        _islet_lamp_moth(moths, RIGHT + rng.uniform(0.3, 1.4), SY + rng.uniform(-2.1, 2.1),
                         SILL_TOP + s * 0.10, s, rng.uniform(0, math.tau), rng.uniform(0.0, 0.22))
    for k in range(6):  # and more at the foot of the wall
        s = rng.uniform(0.42, 0.62)
        gx_, gy_ = RIGHT + rng.uniform(0.9, 3.0), SY + rng.uniform(-3.0, 3.0)
        _islet_lamp_moth(moths, gx_, gy_, gz(gx_, gy_) + s * 0.10, s, rng.uniform(0, math.tau), rng.uniform(0.0, 0.22))

    objects = [
        base,
        object_from_bmesh("Lampwork_Shop", shop, ["M_LampWall", "M_LampTimber", "M_LampSlate", "M_LampIron"]),
        object_from_bmesh("Lampwork_Lamps", lamps, ["M_LampBrass", "M_LampGlass"]),
        object_from_bmesh("Lampwork_Yard", yard, ["M_LampClay", "M_LampRope"]),
        object_from_bmesh("Lampwork_Rock", rock, ["M_LampStone", "M_LampWet", "M_LampTrench"]),
        object_from_bmesh("Lampwork_Glow", glow, ["M_LampWindow"]),
        object_from_bmesh("Lampwork_Moths", moths, ["M_LampMoth"]),
    ]

    pad = [gz(stand[0] + dx, stand[1] + dy) for dx in (-4.0, 0.0, 4.0) for dy in (-4.0, 0.0, 4.0)]
    stand_g = _drop_to_ground(ground, stand[0], stand[1])
    print(
        f"[island_gen] HANDOFF lampwork (the Lampwright's Workshop): floor Y={FLOOR:.1f}, "
        f"open forge face at (Roblox rel) X={SX:.0f} Z={-FRONT:.0f}; "
        f"NPC stand (Roblox rel) X={stand[0]:.0f} Z={-stand[1]:.0f} ground Y={stand_g:.2f} "
        f"- 8x8 pad, fall {max(pad) - min(pad):.2f} studs corner to corner, "
        f"nearest yard lamp {min(math.hypot(lx - stand[0], ly - stand[1]) for lx, ly, _p, _r in _ISLET_LAMP_YARD):.1f} studs, "
        f"recommended radius 55"
    )
    print(
        f"[island_gen] HANDOFF lampwork: the drop - lip on the sail-in lane at (Roblox rel) Z={-y_lip:.1f}, "
        f"lip Y={gz(0.0, y_lip):.1f}, wall plumb to the trench floor at Y={SKIRT_BOTTOM:.1f} "
        f"({gz(0.0, y_lip) - SKIRT_BOTTOM:.1f} studs of cliff); jetty ramp from Y={DECK0:.1f} down to deck Y={DECK1:.1f}, "
        f"head at Z={-y_head:.0f} standing on 13-stud piles over the void"
    )
    print(
        f"[island_gen] HANDOFF lampwork: great lamp on its gantry at X={GX:.0f} Z={-GY:.0f}, "
        f"glass base Y={LZ:.1f}, finial Y={LZ + 7.8:.1f} - DARK; unfinished lighthouse at X={LHX:.0f} "
        f"Z={-LHY:.0f}, three courses, top Y={LH_G + 8.1:.1f}; 19 yard lamps and 8 failed ones on the "
        f"gallows, ALL dark; ONE lit window at X={RIGHT:.0f} Z={-SY:.0f} centre Y={(W0 + W1) / 2:.1f}"
    )
    low = min(min(v.co.z for v in o.data.vertices) for o in objects if o.data.vertices)
    keyed = "" if abs(low - SKIRT_BOTTOM) < 0.01 else "  <-- set Islands.luau meshBottom to this"
    print(f"[island_gen] HANDOFF lampwork: mesh bottom z {low:.2f}{keyed}")
    print("[island_gen] HANDOFF lampwork: Lampwork_Moths is the ONE intended floating object (moths at the lit window)")

    random.setstate(shared_state)  # hand the shared stream back untouched
    return objects


# ---------------------------------------------------------------- island config
#
# Each entry overrides the shape-state globals for its island (an empty
# override leaves the tropical defaults, so `tropical` reproduces the original
# mesh) and names its build function. New islands prefix their object names.

# Islands to bundle into the one importable pack (assets/island_pack.glb), in
# order. Adding an island: give it an ISLANDS entry (with a "model" name) and
# add its id here.
# ================================================================ THE BELLBUOY (islet)
# NOT a grey dome with a bell on it. A single WEDGE of tide-scoured basalt heaved
# up out of warm water at ~15 degrees: a sheer cliff on the weather end, sliding
# away under the sea at the lee end, and a CLEFT split clean through it end to
# end with the swell running along the bottom of it at sea level.
#
# The great bell hangs IN that cleft, off an iron gantry bridging the gap, so the
# swell running through is what rings it - the islet's whole fiction in one
# silhouette. Nettle lives directly under it, in an upturned salvaged dinghy
# tarred black and wedged onto a rock bench at the lee end of the same cleft.
# It must look deafening.
#
# Everything above water is built here as bmesh solids; build_island_base is
# demoted to the SUBMERGED seabed the wedge is driven into (its profile never
# breaks the surface), which is what keeps the lowest geometry on SKIRT_BOTTOM
# without the visible landform being a radial dome.

# The cleft: a slot cut end to end through the wedge, its two walls at these y.
# The bell's mouth is 4.7 across, so 7.0 of clear slot is snug on purpose.
_BBY_CLEFT_N, _BBY_CLEFT_P = -7.6, -0.6
_BBY_CLEFT_MID = (_BBY_CLEFT_N + _BBY_CLEFT_P) / 2.0
_BBY_BOTTOM = -8.6  # the wedge solid's underside, buried inside the seabed
_BBY_SEA = 0.70  # the working waterline - every tideline feature bands on THIS

# The crest line along the wedge, weather (-x) to lee (+x). The long run from
# -27 to 10 drops 10.2 over 37 studs: 15.4 degrees, which IS the wedge.
_BBY_RIDGE = [
    (-33.0, 16.2),
    (-27.0, 14.8),
    (-10.0, 10.1),
    (10.0, 4.6),
    (25.0, 4.2),  # the lee shelf: the tilt levels off into a bench
    (29.0, 1.9),
    (33.0, -2.2),
    (40.0, -6.0),
]
# Absolute z the wedge's walls are CUT at, so every wall face falls wholly inside
# one colour band. One tall quad from crest to seabed would take a single
# material for its whole height and the tideline simply would not exist.
_BBY_CUTS = (1.85, -0.15, -1.9, -4.6)

# The bell hangs here, in a worn notch in the crest: (x, depth, half-length).
_BBY_NOTCH_X, _BBY_NOTCH_D, _BBY_NOTCH_W = -8.0, 4.4, 7.5

# The rock pools scooped out of the lee shelf: (x, y, rim radius).
_BBY_POOLS = ((15.0, 7.6, 3.6), (18.0, -8.6, 3.0), (7.5, 10.4, 2.8), (2.0, -11.0, 2.2))

# The x stations the wedge is sliced at - dense over the cliff end, where the
# silhouette is doing the most work.
_BBY_XS = [
    -29.5, -26.0, -22.0, -18.0, -14.0, -10.0, -6.0, -2.0, 2.0,
    6.0, 10.0, 14.0, 17.5, 21.0, 24.0, 27.0, 30.0, 33.0,
]


def _bby_ridge_z(x):
    tbl = _BBY_RIDGE
    if x <= tbl[0][0]:
        return tbl[0][1]
    for (x0, z0), (x1, z1) in zip(tbl, tbl[1:]):
        if x <= x1:
            return z0 + (z1 - z0) * (x - x0) / (x1 - x0)
    return tbl[-1][1]


def _bby_out_y(x, sign):
    """The outer plan edge of the wedge on the given side. Oblong, not round,
    and blunt at both ends - a wedge that tapers to a point at the weather end
    has no cliff face left to be sheer."""
    t = (x - 2.0) / 40.0
    w = max(0.0, 1.0 - t * t) ** 0.42
    half = 17.4 if sign > 0 else 18.2
    wob = 1.0 + noise.noise(Vector((x * 0.11, sign * 3.7, 8.0))) * 0.17
    return sign * half * w * wob


def _bby_cross(t):
    """How much of the fall to the sea has happened `t` of the way from the
    cleft rim out to the shore. Round 1 used a plain t**1.6 and the wedge
    rendered as a smooth WHALE-BACK - a dome, exactly the thing this islet was
    supposed to stop being. A wedge of basalt is a near-level deck that breaks
    at an edge, so 82% of the fall is packed into the outer quarter and the
    inner three quarters are a plateau you could walk."""
    if t < 0.74:
        return 0.18 * (t / 0.74)
    return 0.18 + 0.82 * ((t - 0.74) / 0.26) ** 1.35


def _bby_span(x, sign):
    if sign > 0:
        return max(_bby_out_y(x, 1) - _BBY_CLEFT_P, 0.5)
    return max(_BBY_CLEFT_N - _bby_out_y(x, -1), 0.5)


def _bby_top_z(x, y):
    """The one true height of the wedge's upper surface - used to BUILD it and
    to sit every prop on it, so nothing floats. The crest runs along the CLEFT
    RIMS and the rock breaks away over an edge to the sea on both sides."""
    r = _bby_ridge_z(x)
    sign = 1 if y >= _BBY_CLEFT_MID else -1
    span = _bby_span(x, sign)
    t = (y - _BBY_CLEFT_P) / span if sign > 0 else (_BBY_CLEFT_N - y) / span
    t = min(max(t, 0.0), 1.0)
    z = r - max(0.0, r + 1.6) * _bby_cross(t)
    # A worn NOTCH in the crest either side of the bell. Without it the cleft
    # rims stand level with the bell's crown and the rock swallows the whole
    # thing from every angle but straight down the slot - the bell has to break
    # the skyline, or the islet is a rock with a gantry on it.
    z -= _BBY_NOTCH_D * math.exp(-(((x - _BBY_NOTCH_X) / _BBY_NOTCH_W) ** 2)) * max(0.0, 1.0 - t / 0.46)
    # Two octaves: a slow swell across the deck, and a fine chop that keeps the
    # facets from lining up into a machined plane.
    z += noise.noise(Vector((x * 0.07, y * 0.07, 3.1))) * 0.95
    return z + noise.noise(Vector((x * 0.26, y * 0.26, 11.4))) * 0.34


def _bby_tide_y(x, sign, z_target=None):
    """The y where the rock surface crosses the given height on one side - the
    honest TIDELINE, found by bisection on the real surface. The plan outline is
    no use for this: the shore edge is a couple of studs under water all round,
    so a crust band laid on the outline floats out on the sea in a rectangle
    (which is exactly what round 1 rendered). None if the rock never gets there.
    """
    z_target = _BBY_SEA if z_target is None else z_target
    y_in = _BBY_CLEFT_P if sign > 0 else _BBY_CLEFT_N
    y_out = _bby_out_y(x, sign)
    if _bby_top_z(x, y_in) < z_target or _bby_top_z(x, y_out) > z_target:
        return None
    lo, hi = y_in, y_out
    for _ in range(22):
        mid = (lo + hi) / 2.0
        if _bby_top_z(x, mid) > z_target:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2.0


def _bby_tide_run(sign, z_target=None, step=1.6):
    """The tideline contour down one flank as a list of (x, y), walked finely
    enough that a slab laid on it hugs the rock."""
    run, x = [], _BBY_XS[0]
    while x <= _BBY_XS[-1]:
        y = _bby_tide_y(x, sign, z_target)
        if y is not None:
            run.append((x, y))
        elif run:
            break  # the flank has gone under; the band ends where the rock does
        x += step
    return run


def _bby_paint(bm, first, index):
    """Give every face added since `first` another material slot - the same
    slot-painting the chapel's bell uses (the importer splits one object into
    <Name> / <Name>2 / ... in slot order, which is what MESH_COLOR keys)."""
    for f in list(bm.faces)[first:]:
        f.material_index = index


def _bby_band(z):
    """Material slot for a wedge face at centroid height z: dry basalt above the
    splash, the bleached salt band through the tide, soaked rock below it. This
    single function is what makes the tideline read all round the islet."""
    if z > _BBY_CUTS[0]:
        return 0
    if z > _BBY_CUTS[1]:
        return 2
    return 1


def _bby_zcuts(z_top):
    """A strictly-decreasing ladder from a wall's top down to the wedge floor,
    passing exactly through _BBY_CUTS wherever the wall is tall enough."""
    out = [z_top]
    for c in _BBY_CUTS:
        out.append(min(c, out[-1] - 0.03))
    out.append(min(_BBY_BOTTOM, out[-1] - 0.03))
    return out


def _bby_wall(bm, a, b):
    """The banded wall under one boundary edge: a ladder of quads cut at the
    tide levels rather than one full-height face."""
    za, zb = _bby_zcuts(a[2]), _bby_zcuts(b[2])
    ca = [bm.verts.new(Vector((a[0], a[1], z))) for z in za]
    cb = [bm.verts.new(Vector((b[0], b[1], z))) for z in zb]
    for k in range(len(za) - 1):
        bm.faces.new((ca[k], cb[k], cb[k + 1], ca[k + 1]))


def _bby_grid_solid(bm, grid):
    """A closed rock solid from an R x C grid of surface points: the faceted top,
    a flat floor at _BBY_BOTTOM, and banded walls all the way round."""
    R, C = len(grid), len(grid[0])
    top = [[bm.verts.new(Vector(p)) for p in row] for row in grid]
    bot = [[bm.verts.new(Vector((p[0], p[1], _BBY_BOTTOM))) for p in row] for row in grid]
    for i in range(R - 1):
        for j in range(C - 1):
            bm.faces.new((top[i][j], top[i][j + 1], top[i + 1][j + 1], top[i + 1][j]))
            bm.faces.new((bot[i + 1][j], bot[i + 1][j + 1], bot[i][j + 1], bot[i][j]))
    for i in range(R - 1):
        _bby_wall(bm, grid[i][0], grid[i + 1][0])
        _bby_wall(bm, grid[i + 1][C - 1], grid[i][C - 1])
    for j in range(C - 1):
        _bby_wall(bm, grid[0][j + 1], grid[0][j])
        _bby_wall(bm, grid[R - 1][j], grid[R - 1][j + 1])


def _bby_half_grid(sign):
    grid = []
    for x in _BBY_XS:
        y_in = _BBY_CLEFT_P if sign > 0 else _BBY_CLEFT_N
        y_out = _bby_out_y(x, sign)
        row = []
        # Columns crowded into the outer quarter, where _bby_cross puts the
        # whole fall: evenly spaced ones would smear the shore break into a ramp.
        for t in (0.0, 0.28, 0.52, 0.70, 0.80, 0.88, 0.95, 1.0):
            y = y_in + (y_out - y_in) * t
            row.append((x, y, _bby_top_z(x, y)))
        grid.append(row)
    return grid


def _bby_outline():
    """The wedge's closed plan boundary walked once - the path the continuous
    tideline crust band is laid along."""
    pts = [(x, _bby_out_y(x, 1)) for x in _BBY_XS]
    pts += [(x, _bby_out_y(x, -1)) for x in reversed(_BBY_XS)]
    return pts


def _bby_hull(bm, cx, cy, deck, length, beam, rise):
    """An upturned clinker dinghy: rows along the keel, each row a section from
    one gunwale up over the keel and down to the other. Blunt transom at +x (the
    stove pipe elbows out through it), stem pinched to nothing at -x. Returns the
    keel-ridge faces so the caller can strip them in bare timber."""
    rows, cols = 11, 7
    grid = []
    for i in range(rows):
        s = i / (rows - 1)  # 0 at the stem, 1 at the transom
        x = cx - length / 2.0 + length * s
        wide = beam / 2.0 * min(1.0, (0.10 + 1.9 * s) ** 0.55, 1.06 - 0.22 * s)
        h = rise * (0.74 + 0.34 * (1.0 - s) ** 1.5)  # the sheer rises to the stem
        row = []
        for j in range(cols):
            u = (j / (cols - 1) - 0.5) * 2.0  # -1 .. 1 across the section
            row.append((x, cy + wide * u, deck + h * (1.0 - abs(u) ** 1.8)))
        grid.append(row)
    top = [[bm.verts.new(Vector(p)) for p in row] for row in grid]
    bot = [[bm.verts.new(Vector((p[0], p[1], deck - 0.5))) for p in row] for row in grid]
    keel = []
    for i in range(rows - 1):
        for j in range(cols - 1):
            f = bm.faces.new((top[i][j], top[i][j + 1], top[i + 1][j + 1], top[i + 1][j]))
            if j in (2, 3):
                keel.append(f)
            bm.faces.new((bot[i + 1][j], bot[i + 1][j + 1], bot[i][j + 1], bot[i][j]))
    for i in range(rows - 1):
        for j in (0, cols - 1):
            a, b = (i, i + 1) if j == 0 else (i + 1, i)
            bm.faces.new((top[a][j], top[b][j], bot[b][j], bot[a][j]))
    for j in range(cols - 1):
        bm.faces.new((top[0][j + 1], top[0][j], bot[0][j], bot[0][j + 1]))
        bm.faces.new((top[rows - 1][j], top[rows - 1][j + 1], bot[rows - 1][j + 1], bot[rows - 1][j]))
    return keel


def _bby_crate(bm, cx, cy, cz, w, d, h, yaw):
    """A salvage crate in slot 0 (timber) with two lashing battens in slot 1
    (rope), because a bare cuboid reads as a bug at 40 studs."""
    add_box(bm, (cx, cy, cz), (w, d, h), yaw=yaw)
    first = len(bm.faces)
    for sx in (-1, 1):
        add_box(
            bm,
            (cx + sx * (w / 2.0) * math.cos(yaw), cy + sx * (w / 2.0) * math.sin(yaw), cz),
            (0.16, d + 0.12, h + 0.10),
            yaw=yaw,
        )
    _bby_paint(bm, first, 1)


def build_islet_bellbuoy():
    rng = random.Random(5501)
    state = random.getstate()
    base = build_island_base("Bellbuoy_Base", ["M_BellRock", "M_BellSplash", "M_BellWet"])

    wedge, crust, kelp, pools = bmesh.new(), bmesh.new(), bmesh.new(), bmesh.new()
    gantry, bell, dinghy = bmesh.new(), bmesh.new(), bmesh.new()
    salvage, lamp, tally = bmesh.new(), bmesh.new(), bmesh.new()

    # ------------------------------------------------------------- the wedge
    for sign in (1, -1):
        _bby_grid_solid(wedge, _bby_half_grid(sign))

    # The rock bench at the lee end of the cleft, cantilevered off the +y wall:
    # the only dry ledge inside the slot, and what the dinghy is wedged onto.
    BENCH_TOP, BENCH_X, BENCH_Y = 2.45, 16.4, -2.55
    add_box(wedge, (BENCH_X, BENCH_Y, BENCH_TOP - 1.7), (14.0, 4.3, 3.4))
    for k in range(5):  # corbels under it, so the ledge is carried, not floating
        add_box(wedge, (BENCH_X - 5.4 + k * 2.7, BENCH_Y - 1.3, BENCH_TOP - 3.6), (1.2, 2.4, 1.8))
    for k in range(2):  # two steps off the bench up onto the lee shelf
        add_box(wedge, (21.9 + k * 1.4, -0.6 + k * 1.5, BENCH_TOP + 0.45 + k * 0.66), (3.2, 2.8, 0.9))

    # Nettle's pad: a genuinely flat dressed landing on the lee shelf, right off
    # the dinghy's transom door. NpcService raycasts straight down here, so it is
    # kept clear of every prop.
    PAD_X, PAD_Y = 25.0, 3.6
    PAD_TOP = _bby_top_z(PAD_X, PAD_Y) + 0.32
    pad_ring = [
        (PAD_X + math.cos(k / 9.0 * math.tau) * 3.7, PAD_Y + math.sin(k / 9.0 * math.tau) * 3.5)
        for k in range(9)
    ]
    add_disc_slab(wedge, pad_ring, PAD_TOP, 2.6)

    # Boulders shed off the cliff and piled at its foot on the weather side,
    # plus two leaning stacks that break the cliff's straight top line.
    for _ in range(14):
        bx = rng.uniform(-31.0, -17.0)
        by = _bby_out_y(bx, rng.choice((1, -1))) * rng.uniform(0.88, 1.18)
        s = rng.uniform(1.3, 3.1)
        add_blob(wedge, (bx, by, rng.uniform(-1.6, 1.6)), (s, s * 0.85, s * 0.7), 0.26, rng.uniform(0, 40), yaw=rng.uniform(0, 3))
    add_blob(wedge, (-29.4, -11.5, 2.2), (2.3, 2.0, 4.6), 0.30, 12.0, yaw=0.5)
    add_blob(wedge, (-28.2, 9.4, 1.8), (2.0, 1.8, 3.8), 0.28, 19.0, yaw=1.1)
    # Buttress ribs pressed FLAT against the weather face - each one runs from
    # the water up to the rock behind it, so the end cap is a fluted cliff
    # instead of one bare grey plane. (They must sit INSIDE the plan: pushed a
    # stud proud of it they render as pillars standing out in the sea.)
    for k in range(9):
        by = -9.5 + k * 2.35
        bx = _BBY_XS[0] + 1.1 + noise.noise(Vector((by * 0.35, 4.0, 1.0))) * 0.7
        crest = _bby_top_z(bx + 0.9, by)
        if crest < 1.0:
            continue
        add_box(wedge, (bx, by, (crest - 2.2) / 2.0), (2.4, 1.5, crest + 2.2), yaw=rng.uniform(-0.12, 0.12))
    for k in range(3):  # ledges stepping down the face
        by = -6.0 + k * 6.5
        add_box(wedge, (_BBY_XS[0] + 1.6, by, 2.6 + k * 2.6), (3.6, 4.4, 0.8), yaw=rng.uniform(-0.15, 0.15))

    # The deck is a big flat plateau now, and a big flat plateau is BLAND: break
    # it with tilted slabs of shed basalt and low steps of the bedding plane.
    for _ in range(30):
        sign = rng.choice((1, -1))
        sx = rng.uniform(-25.0, 26.0)
        span = _bby_span(sx, sign)
        t = rng.uniform(0.08, 0.68)
        sy = (_BBY_CLEFT_P + span * t) if sign > 0 else (_BBY_CLEFT_N - span * t)
        # Nothing may land on Nettle's pad (NpcService stands her on whatever
        # its downward ray hits), nor in a rock pool, nor under the salvage dump.
        if math.hypot((sx - PAD_X) / 6.2, (sy - PAD_Y) / 5.8) < 1.0:
            continue
        if any(math.hypot(sx - px, sy - py) < pr + 2.4 for px, py, pr in _BBY_POOLS):
            continue
        if math.hypot(sx - 17.5, sy - 10.5) < 7.0:
            continue
        if abs(sx - _BBY_NOTCH_X) < 10.0 and t < 0.36:
            continue  # keep the notch clear: this is the sightline to the bell
        surf = _bby_top_z(sx, sy)
        if rng.random() < 0.55:
            w, d = rng.uniform(2.2, 5.0), rng.uniform(1.8, 3.6)
            add_box(wedge, (sx, sy, surf + 0.05), (w, d, rng.uniform(0.55, 1.5)), yaw=rng.uniform(0, 3))
        else:
            s = rng.uniform(0.9, 2.3)
            add_blob(wedge, (sx, sy, surf + s * 0.35), (s, s * 0.8, s * 0.65), 0.30, rng.uniform(0, 60), yaw=rng.uniform(0, 3))

    # Rock pools on the lee shelf: a ragged basin rim built in the rock, with
    # still water standing in it.
    for px, py, pr in _BBY_POOLS:
        surf = _bby_top_z(px, py)
        if min(_bby_top_z(px + math.cos(a) * pr, py + math.sin(a) * pr) for a in
               (k / 8.0 * math.tau for k in range(8))) < surf - 1.1:
            continue  # the basin runs off the shore break; its water would float
        ring = []
        for k in range(11):
            a = k / 11.0 * math.tau
            rr = pr * (1.0 + noise.noise(Vector((math.cos(a) * 2.0, math.sin(a) * 2.0, px))) * 0.24)
            add_box(wedge, (px + math.cos(a) * rr, py + math.sin(a) * rr, surf + 0.16), (0.95, 0.95, rng.uniform(0.6, 1.05)), yaw=a)
            ring.append((px + math.cos(a) * rr * 0.80, py + math.sin(a) * rr * 0.80))
        add_disc_slab(pools, ring, surf + 0.20, 0.7)

    # Band the whole wedge by height. Every face takes its slot from its
    # centroid, which is exactly why the walls were cut at the tide levels.
    for f in wedge.faces:
        f.material_index = _bby_band(sum(v.co.z for v in f.verts) / len(f.verts))

    # ------------------------------------------------------- tideline crust
    # A CONTINUOUS barnacle band round every flank, laid on the TRUE tideline
    # contour (where the rock crosses _BBY_SEA) rather than on the plan outline
    # - after the bell it is the strongest read on the islet, and it only reads
    # if it is welded to the rock.
    def crust_band(run, sign, z_hi, z_lo, thick):
        if len(run) < 2:
            return
        left = [Vector((x, y - sign * 0.05, z_hi)) for x, y in run]
        right = [Vector((x, y + sign * 0.75, z_hi)) for x, y in run]
        add_strip_slab(crust, left, right, thick)

    tide = {}
    for sign in (1, -1):
        # Three courses stacked through the tide range: the pale barnacle crust
        # sits highest, the band under it is where the mussels crowd.
        tide[sign] = _bby_tide_run(sign, _BBY_SEA + 0.35)
        crust_band(tide[sign], sign, _BBY_SEA + 1.15, _BBY_SEA, 1.35)
        crust_band(_bby_tide_run(sign, _BBY_SEA - 0.55), sign, _BBY_SEA - 0.2, _BBY_SEA - 1.0, 1.10)
    # Both cleft walls, clipped to where the rim is still out of the water.
    for wy, sgn in ((_BBY_CLEFT_P, -1), (_BBY_CLEFT_N, 1)):
        xs = [x for x in _BBY_XS if _bby_ridge_z(x) > _BBY_SEA + 1.6]
        left = [Vector((x, wy, _BBY_SEA + 1.15)) for x in xs]
        right = [Vector((x, wy + sgn * 0.8, _BBY_SEA + 1.15)) for x in xs]
        add_strip_slab(crust, left, right, 1.35)

    for _ in range(170):  # barnacle cones roughening those bands
        if rng.random() < 0.76:
            sign = rng.choice((1, -1))
            run = tide[sign]
            if not run:
                continue
            bx, by = run[rng.randrange(len(run))]
            by += sign * rng.uniform(-0.35, 0.75)
            bx += rng.uniform(-0.7, 0.7)
        else:
            bx = rng.uniform(-27.0, 22.0)
            by = (_BBY_CLEFT_P - 0.25 if rng.random() < 0.5 else _BBY_CLEFT_N + 0.25) + rng.uniform(-0.4, 0.4)
        r = rng.uniform(0.20, 0.55)
        add_cone(crust, (bx, by, _BBY_SEA + rng.uniform(-0.75, 1.05)), r, r * 0.35, rng.uniform(0.22, 0.55), sides=5)

    first = len(crust.faces)  # mussel scurf: dark patches crowded just UNDER them
    for _ in range(70):
        sign = rng.choice((1, -1))
        run = _bby_tide_run(sign, _BBY_SEA - rng.uniform(0.2, 1.1))
        if not run:
            continue
        bx, by = run[rng.randrange(len(run))]
        add_box(
            crust,
            (bx + rng.uniform(-0.5, 0.5), by + sign * rng.uniform(-0.1, 0.5), _bby_top_z(bx, by) + 0.10),
            (rng.uniform(1.0, 2.2), rng.uniform(0.8, 1.6), rng.uniform(0.22, 0.4)),
            yaw=rng.uniform(0, 3),
        )
    for _ in range(26):
        bx = rng.uniform(-25.0, 20.0)
        by = _BBY_CLEFT_P - 0.42 if rng.random() < 0.5 else _BBY_CLEFT_N + 0.42
        add_box(crust, (bx, by, _BBY_SEA - rng.uniform(0.25, 1.2)), (1.9, 0.55, 0.38), yaw=rng.uniform(0, 3))
    _bby_paint(crust, first, 1)

    # ---------------------------------------------------------------- kelp
    def kelp_strap(x0, y0, bearing, length, width):
        pts, a, x, y = [], bearing, x0, y0
        for _ in range(6):
            pts.append(Vector((x, y, min(_bby_top_z(x, y) + 0.14, _BBY_SEA + 1.5))))
            a += rng.uniform(-0.45, 0.45)
            x += math.cos(a) * (length / 5.0)
            y += math.sin(a) * (length / 5.0)
        left = [Vector((p.x - math.sin(a) * width, p.y + math.cos(a) * width, p.z)) for p in pts]
        right = [Vector((p.x + math.sin(a) * width, p.y - math.cos(a) * width, p.z)) for p in pts]
        add_strip_slab(kelp, left, right, 0.18)

    for _ in range(26):  # straps laid over the wet apron, ON the tideline
        sign = rng.choice((1, -1))
        run = _bby_tide_run(sign, _BBY_SEA + rng.uniform(-0.5, 0.9))
        run = [p for p in run if p[0] > 0.0] or run
        if not run:
            continue
        kx, ky = run[rng.randrange(len(run))]
        kelp_strap(kx, ky, rng.uniform(0, math.tau), rng.uniform(4.0, 9.0), rng.uniform(0.35, 0.8))
    for _ in range(10):  # and fronds the swell has thrown up onto the cleft rims
        kx = rng.uniform(-16.0, 20.0)
        ky = _BBY_CLEFT_P + 0.35 if rng.random() < 0.5 else _BBY_CLEFT_N - 0.35
        add_box(kelp, (kx, ky, _BBY_SEA + rng.uniform(0.4, 1.8)), (rng.uniform(1.0, 2.2), 0.5, rng.uniform(1.8, 3.4)), yaw=rng.uniform(0, 3))

    # ------------------------------------------------- the gantry over the cleft
    # This IS a navigation mark, so the ironwork carries faded red-and-white
    # signal bands: slot 0 iron, 1 signal red, 2 signal white.
    BX, BY = _BBY_NOTCH_X, _BBY_CLEFT_MID
    rim_p, rim_n = _bby_top_z(BX, _BBY_CLEFT_P), _bby_top_z(BX, _BBY_CLEFT_N)
    # The bell's own numbers, needed up here because the beam has to clear its
    # crown by a run of chain, not merely clear the rock.
    MOUTH_Z = 3.60
    CROWN = MOUTH_Z + 6.00
    BEAM_Z = max(CROWN + 4.35, max(rim_p, rim_n) + 4.2)

    def banded_leg(x0, y0, z0, x1, y1, z1, r, segs=7):
        d = Vector((x1 - x0, y1 - y0, z1 - z0))
        tilt = _tilt_toward(d.normalized())
        for k in range(segs):
            p = Vector((x0, y0, z0)) + d * (k / segs)
            first = len(gantry.faces)
            add_cone(gantry, tuple(p), r, r * 0.95, d.length / segs + 0.03, sides=6, tilt=tilt)
            _bby_paint(gantry, first, (1, 2, 0)[k % 3])

    for sy, rim in ((1, rim_p), (-1, rim_n)):
        wy = _BBY_CLEFT_P + 0.95 if sy > 0 else _BBY_CLEFT_N - 0.95
        for sx in (-1, 1):  # a splayed A-frame on each rim
            banded_leg(BX + sx * 3.2, wy, rim - 0.8, BX + sx * 0.78, wy - sy * 0.35, BEAM_Z - 0.5, 0.40)
        add_box(gantry, (BX, wy, rim - 0.30), (8.8, 1.1, 0.75))  # the sill plate bolted to the rim
        add_cone(  # a knee brace raking back into the rock
            gantry, (BX - 3.2, wy, rim - 0.2), 0.30, 0.30, 3.6, sides=5,
            tilt=_tilt_toward(Vector((0.55, 0.0, 0.83)).normalized()),
        )
    add_box(gantry, (BX, BY, BEAM_Z), (1.5, 10.8, 1.2))  # the crossbeam the bell hangs from
    add_box(gantry, (BX, BY, BEAM_Z - 0.9), (1.0, 8.8, 0.55))
    for sy in (-1, 1):
        add_cone(
            gantry, (BX, BY + sy * 4.5, BEAM_Z - 0.65), 0.26, 0.26, 3.4, sides=4,
            tilt=_tilt_toward(Vector((0.0, -sy * 0.72, 0.69)).normalized()),
        )
    for sgn in (-1, 1):  # X-bracing across the two frames: a truss, not two arches
        a = Vector((BX + sgn * 2.7, _BBY_CLEFT_P + 0.95, min(rim_p, rim_n) + 0.2))
        b = Vector((BX - sgn * 1.1, _BBY_CLEFT_N - 0.95, BEAM_Z - 1.3))
        d = b - a
        add_cone(gantry, tuple(a), 0.20, 0.20, d.length, sides=4, tilt=_tilt_toward(d.normalized()))
    # The daymark: a banded mast over the beam with a solid red cone on top -
    # the thing a boat actually steers by.
    banded_leg(BX, BY, BEAM_Z + 0.5, BX, BY, BEAM_Z + 4.6, 0.34, segs=6)
    first = len(gantry.faces)
    add_cone(gantry, (BX, BY, BEAM_Z + 4.5), 1.60, 0.10, 2.7, sides=7)
    _bby_paint(gantry, first, 1)
    # The one lamp's housing, on a bracket off the dinghy's door post.
    LAMP = (23.6, -0.9, BENCH_TOP + 3.55)
    add_box(gantry, (LAMP[0] - 0.9, LAMP[1], LAMP[2] + 0.85), (2.0, 0.22, 0.22))
    add_box(gantry, LAMP, (0.62, 0.62, 0.20))
    add_box(gantry, (LAMP[0], LAMP[1], LAMP[2] + 0.95), (0.72, 0.72, 0.26))
    for sx in (-1, 1):
        for sy in (-1, 1):
            add_box(gantry, (LAMP[0] + sx * 0.27, LAMP[1] + sy * 0.27, LAMP[2] + 0.48), (0.12, 0.12, 0.85))

    # ---------------------------------------------------------------- the bell
    # ONE continuous profile: each course's bottom radius IS the radius the
    # course below ended on, so no seam can step outward. (Round 1 gave every
    # course its own flare off a narrow start and rendered as a pinecone.)
    BELL_PROFILE = [
        (0.00, 2.36),  # the lip - the widest line on the bell
        (0.45, 1.98),  # the flare sweeping up off it, hard
        (1.12, 1.72),  # the sound bow, where the clapper strikes
        (2.36, 1.57),  # the waist, barely tapering
        (3.64, 1.46),
        (4.50, 1.29),
        (5.30, 0.83),  # the shoulder turns hard in
        (6.00, 0.51),  # to the crown
    ]
    for (h0, r0), (h1, r1) in zip(BELL_PROFILE, BELL_PROFILE[1:]):
        first = len(bell.faces)
        add_cone(bell, (BX, BY, MOUTH_Z + h0), r0, r1, h1 - h0, sides=14)
        if h1 <= 1.13:  # the bottom two courses ARE the sound bow: struck clean
            _bby_paint(bell, first, 1)
    add_cone(bell, (BX, BY, CROWN), 0.51, 0.40, 0.55, sides=10)
    for hz, rr in ((2.30, 1.60), (4.44, 1.33)):  # raised mouldings round the waist
        add_cone(bell, (BX, BY, MOUTH_Z + hz), rr + 0.10, rr + 0.10, 0.20, sides=14)

    first = len(bell.faces)  # ---- the ironwork: chain, strap and clapper
    links = max(2, int((BEAM_Z - 0.9 - (CROWN + 0.55)) / 0.62))
    for k in range(links):
        add_box(bell, (BX, BY, CROWN + 0.86 + k * 0.62), (0.34, 0.34, 0.66), yaw=0.0 if k % 2 else 0.785)
    add_box(bell, (BX, BY, BEAM_Z + 0.78), (0.55, 2.4, 0.42))  # closed over the beam
    add_box(bell, (BX, BY, BEAM_Z - 0.78), (0.55, 2.4, 0.42))  # and under it
    for sy in (-1, 1):
        add_box(bell, (BX, BY + sy * 1.1, BEAM_Z), (0.5, 0.36, 1.6))
    # The clapper hangs THROUGH the mouth into the daylight where the swell
    # reaches it; swallowed by the body it would read as a lampshade.
    for k in range(8):
        add_box(bell, (BX, BY, 3.95 + k * 0.62), (0.30, 0.30, 0.64), yaw=0.0 if k % 2 else 0.785)
    add_cone(bell, (BX, BY, 1.30), 0.40, 1.02, 0.95, sides=10)
    add_cone(bell, (BX, BY, 2.25), 1.02, 0.26, 1.15, sides=10)
    _bby_paint(bell, first, 2)

    # ------------------------------------------------------- the dinghy hut
    HULL_X, HULL_L, HULL_B, HULL_H = 16.4, 12.6, 4.7, 3.55
    DECK = BENCH_TOP + 0.05
    for f in _bby_hull(dinghy, HULL_X, BENCH_Y, DECK, HULL_L, HULL_B, HULL_H):
        f.material_index = 1  # the keel, now the ridge beam: bare timber on tar
    first = len(dinghy.faces)
    add_box(dinghy, (HULL_X, BENCH_Y, DECK + HULL_H * 0.99), (HULL_L * 0.86, 0.5, 0.40))
    for sy in (-1, 1):  # gunwale strakes, now the eaves
        add_box(dinghy, (HULL_X + 0.4, BENCH_Y + sy * (HULL_B / 2.0 - 0.1), DECK + 0.55), (HULL_L * 0.78, 0.34, 0.44))
    _bby_paint(dinghy, first, 1)
    STEM_X, TRANS_X = HULL_X - HULL_L / 2.0, HULL_X + HULL_L / 2.0
    first = len(dinghy.faces)  # the stove pipe, elbowing out through the transom
    add_cone(dinghy, (TRANS_X - 0.7, BENCH_Y - 1.5, DECK + 2.05), 0.30, 0.30, 2.0, sides=6, tilt=(0.0, math.pi / 2))
    add_cone(dinghy, (TRANS_X + 1.3, BENCH_Y - 1.5, DECK + 1.95), 0.32, 0.27, 3.5, sides=6)
    add_cone(dinghy, (TRANS_X + 1.3, BENCH_Y - 1.5, DECK + 5.35), 0.48, 0.34, 0.5, sides=6)  # the cowl
    _bby_paint(dinghy, first, 2)

    # --------------------------------------------------- Nettle's scavenge
    # Slots: 0 timber, 1 rope, 2 cork, 3 netting.
    for k in range(4):  # crate wall sealing the stem end
        _bby_crate(salvage, STEM_X + 0.7, BENCH_Y - 0.85 + (k % 2) * 1.6, DECK + 0.62 + (k // 2) * 1.28, 1.6, 1.45, 1.25, 0.12 * k)
    for k in range(3):  # and the transom end, only the -y half: the doorway is the rest
        _bby_crate(salvage, TRANS_X - 0.55, BENCH_Y - 1.55, DECK + 0.64 + k * 1.26, 1.55, 1.7, 1.25, 0.09 * k)
    first = len(salvage.faces)
    add_box(salvage, (TRANS_X - 0.35, BENCH_Y + 0.55, DECK + 3.05), (1.5, 2.7, 0.36))  # door lintel
    add_box(salvage, (TRANS_X - 0.35, BENCH_Y + 1.85, DECK + 1.6), (1.5, 0.4, 3.2))  # door post
    CAT_X = 6.0  # the catwalk plank across the cleft, well downhill of the bell
    cw = (_bby_top_z(CAT_X, _BBY_CLEFT_P) + _bby_top_z(CAT_X, _BBY_CLEFT_N)) / 2.0
    for k in range(2):
        add_box(salvage, (CAT_X + k * 1.35 - 0.68, _BBY_CLEFT_MID, cw + 0.3), (1.25, 8.6, 0.32))
    _bby_paint(salvage, first, 0)

    shelf_crates = []
    for _ in range(7):  # a lashed dump of salvage on the lee shelf by the pad
        cx, cy = 17.5 + rng.uniform(-3.0, 3.0), 10.5 + rng.uniform(-3.0, 3.0)
        cz = _bby_top_z(cx, cy) + 0.85
        _bby_crate(salvage, cx, cy, cz, 2.0, 1.9, 1.7, rng.uniform(0, 3))
        shelf_crates.append((cx, cy, cz))
    for _ in range(4):
        cx, cy = 12.0 + rng.uniform(-3.0, 3.0), -12.5 + rng.uniform(-2.6, 2.6)
        _bby_crate(salvage, cx, cy, _bby_top_z(cx, cy) + 0.85, 1.9, 1.8, 1.7, rng.uniform(0, 3))

    first = len(salvage.faces)  # ---- rope: the run along the rim, lanyards, lashings
    for k in range(17):
        x0 = -3.0 + k * 1.75
        z0, z1 = _bby_top_z(x0, _BBY_CLEFT_P) + 0.78, _bby_top_z(x0 + 1.75, _BBY_CLEFT_P) + 0.78
        d = Vector((1.75, 0.0, z1 - z0))
        add_cone(salvage, (x0, _BBY_CLEFT_P + 0.55, z0), 0.13, 0.13, d.length, sides=4, tilt=_tilt_toward(d.normalized()))
    fenders = []
    for sy in (1, -1):
        for k in range(4):
            fx = 3.0 + k * 4.4 + (1.8 if sy < 0 else 0.0)
            wy = _BBY_CLEFT_P + 0.35 if sy > 0 else _BBY_CLEFT_N - 0.35
            rim = _bby_top_z(fx, wy)
            add_cone(salvage, (fx, wy, rim - 2.5), 0.13, 0.13, 2.8, sides=4)
            fenders.append((fx, wy, rim - 2.5))
    for cx, cy, cz in shelf_crates:  # lashings pinning the dump to the rock
        add_cone(salvage, (cx - 1.6, cy, cz + 1.0), 0.11, 0.11, 3.3, sides=4, tilt=(0.0, math.pi / 2))
    _bby_paint(salvage, first, 1)

    first = len(salvage.faces)  # ---- cork: floats on the rope run, fender bodies
    for k in range(14):
        fx = -2.3 + k * 2.1
        add_cone(
            salvage, (fx, _BBY_CLEFT_P + 0.52, _bby_top_z(fx, _BBY_CLEFT_P) + 0.52), 0.21, 0.21, 0.52,
            sides=6, tilt=(math.pi / 2, 0.0), yaw=rng.uniform(0, 1.0),
        )
    for fx, wy, fz in fenders:
        add_cone(salvage, (fx, wy, fz - 1.7), 0.40, 0.52, 0.85, sides=7)
        add_cone(salvage, (fx, wy, fz - 0.85), 0.52, 0.34, 0.85, sides=7)
    for k in range(9):  # a bundle of spare floats heaped by the door
        add_cone(
            salvage, (24.3 + rng.uniform(-1.3, 1.3), -4.6 + rng.uniform(-1.3, 1.3), BENCH_TOP + 0.4 + rng.uniform(0, 0.9)),
            0.33, 0.33, 0.7, sides=6, tilt=(math.pi / 2, 0.0), yaw=rng.uniform(0, 3),
        )
    _bby_paint(salvage, first, 2)

    first = len(salvage.faces)  # ---- netting stretched over the shelf dump
    NET_X, NET_Y = 17.5, 10.5
    for k in range(7):
        t = (k - 3) * 1.35
        for along_x in (True, False):
            a = (NET_X + t, NET_Y - 4.4) if along_x else (NET_X - 4.4, NET_Y + t)
            b = (NET_X + t, NET_Y + 4.4) if along_x else (NET_X + 4.4, NET_Y + t)
            za, zb = _bby_top_z(*a) + 0.5, _bby_top_z(*b) + 0.5
            mid = ((a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0)
            drape = 0.85 - abs(t) * 0.12
            add_box(
                salvage,
                (mid[0], mid[1], (za + zb) / 2.0 + drape),
                (0.10 if along_x else 8.8, 8.8 if along_x else 0.10, 0.10),
            )
    for sx, sy in ((-1, -1), (-1, 1), (1, -1), (1, 1)):  # pegged down at the corners
        add_box(salvage, (NET_X + sx * 4.4, NET_Y + sy * 4.4, _bby_top_z(NET_X + sx * 4.4, NET_Y + sy * 4.4) + 0.4), (0.3, 0.3, 1.4))
    _bby_paint(salvage, first, 3)

    # ---- the one lamp, burning in its housing at the door
    add_box(lamp, (LAMP[0], LAMP[1], LAMP[2] + 0.48), (0.48, 0.48, 0.78))

    # ---- tally marks: two years of swells, scratched into the rock as thin dark
    # grooves. On the cleft wall the boat looks straight out at, and on the pad.
    def tally_group(x0, z0, on_wall):
        for k in range(4):
            if on_wall:
                add_box(tally, (x0 + k * 0.26, _BBY_CLEFT_P - 0.52, z0), (0.055, 0.10, 0.52))
            else:
                add_box(tally, (x0 + k * 0.26, _BBY_CLEFT_N + 0.52, z0), (0.055, 0.10, 0.52))
        wy = (_BBY_CLEFT_P - 0.52) if on_wall else (_BBY_CLEFT_N + 0.52)
        add_box(tally, (x0 + 0.39, wy, z0), (1.10, 0.10, 0.055))

    for row in range(3):
        for grp in range(4):
            tally_group(1.2 + grp * 1.5, 4.2 - row * 0.95, True)
    for row in range(2):
        for grp in range(3):
            tally_group(2.4 + grp * 1.5, 3.9 - row * 0.95, False)

    # ------------------------------------------------------------- assemble
    objects = [
        base,
        object_from_bmesh("Bellbuoy_Wedge", wedge, ["M_BellBasalt", "M_BellSoak", "M_BellSalt"]),
        object_from_bmesh("Bellbuoy_Crust", crust, ["M_BellCrust", "M_BellMussel"]),
        object_from_bmesh("Bellbuoy_Kelp", kelp, ["M_BellKelp"]),
        object_from_bmesh("Bellbuoy_Pools", pools, ["M_BellPool"]),
        object_from_bmesh("Bellbuoy_Gantry", gantry, ["M_BellIron", "M_BellRed", "M_BellWhite"]),
        object_from_bmesh("Bellbuoy_Bell", bell, ["M_BellBronze", "M_BellLip", "M_BellIron"]),
        object_from_bmesh("Bellbuoy_Dinghy", dinghy, ["M_BellTar", "M_BellPlank", "M_BellIron"]),
        object_from_bmesh("Bellbuoy_Salvage", salvage, ["M_BellPlank", "M_BellRope", "M_BellCork", "M_BellNet"]),
        object_from_bmesh("Bellbuoy_Lamp", lamp, ["M_BellLamp"]),
        object_from_bmesh("Bellbuoy_Tally", tally, ["M_BellTally"]),
    ]

    # The pad's ground height comes off a REAL downward raycast into the built
    # wedge, not off height_at (which knows nothing about the wedge at all).
    ground = _bby_top_z(PAD_X, PAD_Y)
    for obj in objects:
        hit = _drop_to_ground(_ground_bvh(obj), PAD_X, PAD_Y)
        if hit is not None:
            ground = max(ground, hit)
    print(
        f"[island_gen] HANDOFF bellbuoy (The Bellbuoy): wedge crest Y={_bby_ridge_z(-27.0):.1f}, "
        f"cleft {_BBY_CLEFT_P - _BBY_CLEFT_N:.1f} wide with the sea running through it; "
        f"bell mouth Y={MOUTH_Z:.2f} (r={BELL_PROFILE[0][1]:.2f}), crown Y={CROWN:.2f}, "
        f"gantry beam Y={BEAM_Z:.2f}, daymark tip Y={BEAM_Z + 7.2:.2f}; "
        f"hut ridge Y={DECK + HULL_H:.2f} on a bench at Y={BENCH_TOP:.2f}; "
        f"NPC stand (Roblox rel) X={PAD_X:.1f} Z={-PAD_Y:.1f} ground Y={ground:.2f}; "
        f"recommended radius 38"
    )
    random.setstate(state)
    return objects


# ================================================================ THE ROOKERY STACK (islet)
# A guano-white sea stack, every ledge crowded with nesting gulls. The read is
# CROWDED: dozens of birds, white streaking down the seaward face, nests jammed
# into every step of the rock.
#
# ROUND 2 - THE BIRDS WERE GLUED TO A WALL. Round 1 scattered gulls at
# height_at() around a cone and called the result ledges. Three things were
# wrong at once: the cone had no horizontal surface anywhere, height_at()
# carries none of the crag() the base mesh is actually built with (so even the
# heights were off by up to the whole CRAG amplitude), and the profile's
# "steps" were smeared flat by that same crag. Every bird rendered as a decal
# pasted on near-vertical rock with nothing under its feet.
#
# So the ledges are BUILT now, not hoped for: a crown cap, three ring terraces
# whose tops are TRUE horizontal planes driven into the risers, and shelf slabs
# cantilevered off the cliff bands between them. Every one of them records its
# top in `perches`, and not one bird is placed anywhere else. The guano follows
# the same table - white ledge tops, white ribbons running DOWN the face from
# under each occupied ledge, which is the signature the islet was missing.

# The stack's ledger of heights, kept in one table because the terraces, the
# shelves, the streaks and the colony all have to agree on them EXACTLY. Every
# number here is a built slab, not a reading off the terrain.
ROOK_CROWN = (0.155, 54.8, 2.2, 46.1)  # summit cap: (rim u, slab top, thickness, streak floor)
ROOK_TERRACES = [
    # (inner u, outer u, lip wobble, slab top, thickness, streak floor, arcs,
    # gulls, guano runs). The inner u is pushed UP the riser above until the
    # rock buries the slab top, so the terrace reads as a shelf cut into the
    # cliff rather than a plinth dropped on it; the outer u runs past the tread
    # so the lip overhangs the drop.
    (0.200, 0.400, 0.042, 46.1, 3.4, 36.0, 4, 10, 11),
    # Pip's terrace. Islands.luau spawns him at rel (0, 36, -16) - that lands
    # on this slab's top, so 36.0 is pinned, not a free number.
    (0.440, 0.610, 0.046, 36.0, 3.6, 24.4, 5, 14, 14),
    (0.645, 0.820, 0.050, 24.4, 3.8, 2.0, 5, 15, 17),
]
ROOK_CLIFFS = [
    # The exposed rock between one ledge's underside and the next ledge's top:
    # (z top, z bottom, shelf slabs). This is the only rock a shelf ever grows
    # out of - a shelf hung anywhere else has a sloping face under half of it.
    # The lowest band stops at 9, not at the water: below that the coastline
    # lobes back inside the shelf's own reach and they hung over open sea like
    # diving boards.
    (52.0, 46.1, 2),
    (42.7, 36.0, 3),
    (32.4, 24.4, 4),
    (20.6, 9.0, 4),
]
ROOK_SHELF_THICK = 1.4
ROOK_SHELF_BURY = 3.2  # the inner edge is taken where the face stands this much higher

# Pip's pad, in Blender polar terms. NpcService raycasts DOWN at his anchor and
# stands him on the first thing the ray hits - it ignores the configured
# height - so the pad is a HARD CONSTRAINT, not a suggestion: the middle
# terrace must be unbroken here, nothing may be hung above it here, and no nest
# may be laid on it here (he would be standing in one).
ROOK_PAD_A = math.pi * 0.5  # Blender +Y, i.e. Roblox rel -Z
ROOK_PAD_R = 16.0
ROOK_PAD_CLEAR = 0.30  # radians of terrace kept bare either side of him


def _rook_paint(bm, first, index):
    """Give every face added since `first` a second material slot - how the
    nests object carries pale eggs as well as brown debris (the importer splits
    it into <Name> / <Name>2, which is what MESH_COLOR keys)."""
    for f in list(bm.faces)[first:]:
        f.material_index = index


def _rook_u_at_height(z):
    """The relative radius whose PROFILE height is `z` - profile_height run
    backwards by bisection, which is exact here because the stack's profile
    falls monotonically outward. Every ledge and every streak is pinned with
    this, so they sit ON the face instead of near it."""
    lo, hi = 0.0, RINGS[-1]
    if profile_height(hi) >= z:
        return hi
    for _ in range(30):
        mid = (lo + hi) * 0.5
        if profile_height(mid) > z:
            lo = mid
        else:
            hi = mid
    return (lo + hi) * 0.5


def build_islet_rookery():
    rng = random.Random(5502)
    state = random.getstate()
    # The fourth slot is empty coming out of build_island_base (it only paints
    # 0/1/2 by ring band) and gets filled in at the bottom of this function -
    # the guano is painted ONTO the rock rather than leaned against it.
    base = build_island_base("Rookery_Base", ["M_RookRock", "M_RookSplash", "M_RookWet", "M_RookStreak"])
    ledges, streaks = bmesh.new(), bmesh.new()
    birds, nests = bmesh.new(), bmesh.new()

    # Every horizontal surface a bird is allowed to stand on, filled AS the
    # ledges are built: (x, y, top z, outward angle). Nothing is perched off
    # this list - that rule is the whole fix.
    perches = []
    # Where the rock gets stained, as (centre angle, half width, z top, z
    # bottom) windows recorded from the ledges above them - so every run of
    # white starts under rock that is actually occupied.
    stain_runs = []

    def gull(bm, x, y, z, yaw, flying=False):
        add_cone(bm, (x, y, z), 0.62, 0.24, 1.5, sides=6, tilt=(0.0, 1.3 if flying else 0.25), yaw=yaw)
        add_cone(bm, (x, y, z + 0.5), 0.34, 0.16, 0.7, sides=5, yaw=yaw)  # head
        for side in (-1, 1):
            add_box(
                bm,
                (x + math.cos(yaw + side * 1.57) * 0.6, y + math.sin(yaw + side * 1.57) * 0.6, z + 0.45),
                (1.5 if flying else 0.9, 0.32, 0.16),
                yaw=yaw,
            )

    def nest(bm, x, y, z, yaw):
        """A scrape of dragged-up debris: six twigs laid round a rim with a
        packed mound under them and an egg or two in the cup. Round 1's nest
        was a single cone - a floating brown disc under a floating bird."""
        first = len(bm.faces)
        add_cone(bm, (x, y, z - 0.10), 1.10, 0.84, 0.28, sides=8)  # the packed mound
        for k in range(6):
            a = yaw + k * math.tau / 6 + rng.uniform(-0.18, 0.18)
            rr = 0.84 + rng.uniform(-0.08, 0.10)
            add_box(bm, (x + math.cos(a) * rr, y + math.sin(a) * rr, z + 0.20), (0.30, 0.92, 0.24), yaw=a)
        _rook_paint(bm, first, 0)
        first = len(bm.faces)
        for k in range(rng.randint(1, 2)):
            ea = rng.uniform(0.0, math.tau)
            add_cone(bm, (x + math.cos(ea) * 0.26, y + math.sin(ea) * 0.26, z + 0.04), 0.20, 0.13, 0.34, sides=5)
        _rook_paint(bm, first, 1)

    def streak(a, z_from, z_to, w_top, w_bot):
        """One guano run: a ribbon pinned to the face from a ledge's underside
        down the rock below it. It follows the profile OUTWARD as it falls - a
        plumb-straight streak buries itself in a cone that widens downward. It
        rides only just proud of the face on purpose: standing it clear of the
        radial crag everywhere turned the runs into fins on the silhouette, and
        a wash that dips in and out of the rock is what staining looks like."""
        left, right = [], []
        steps = 4
        for k in range(steps + 1):
            t = k / steps
            z = z_from + (z_to - z_from) * t
            r = ring_radius(_rook_u_at_height(z), a) * 1.012 + 0.30
            half = (w_top + (w_bot - w_top) * t) * 0.5 / max(r, 1.0)
            left.append(Vector((math.cos(a - half) * r, math.sin(a - half) * r, z)))
            right.append(Vector((math.cos(a + half) * r, math.sin(a + half) * r, z)))
        add_strip_slab(streaks, left, right, 0.35)

    def ledge_arc(a0, a1, z_top, thick, u_in, u_out, wobble, jut, samples):
        """ONE LEDGE, and the only thing on this islet that makes a horizontal
        surface. `u_in` is a radius whose rock stands ABOVE z_top, so the inner
        edge is buried and the slab cannot float; `u_out` (plus a scalloped
        `wobble` and a straight `jut`) runs past the face so the lip overhangs
        the drop. The top is a true plane at z_top, which is the whole point -
        a bird seated on it has a level surface under its feet and air beyond.
        Hands back the per-sample (angle, inner r, outer r) for that seating."""
        inner, outer, spans = [], [], []
        for s in range(samples):
            a = a0 + (a1 - a0) * (s / (samples - 1))
            n = noise.noise(Vector((math.cos(a) * 3.4, math.sin(a) * 3.4, z_top * 0.13)))
            ri = ring_radius(u_in, a)
            ro = ring_radius(u_out + wobble * n, a) + jut
            inner.append(Vector((math.cos(a) * ri, math.sin(a) * ri, z_top)))
            outer.append(Vector((math.cos(a) * ro, math.sin(a) * ro, z_top)))
            spans.append((a, ri, ro))
        add_strip_slab(ledges, inner, outer, thick)
        # Hand back the INTERIOR samples only. The two end samples are the
        # arc's end caps, and a bird seated exactly on that edge fails the
        # raycast check - it is standing on the rim, not on the ledge.
        return spans[1:-1]

    # ---- the crown: the summit is small and flat, so it caps rather than
    # terraces, and it carries the tightest cluster on the stack.
    crown_u, crown_top, crown_thick, crown_floor = ROOK_CROWN
    cap = []
    for s in range(SEGMENTS // 2):
        a = (s / (SEGMENTS // 2)) * math.tau
        # Ragged, not a drum: a clean rim up here read as a water tower.
        n = noise.noise(Vector((math.cos(a) * 3.9, math.sin(a) * 3.9, 4.2)))
        rr = ring_radius(crown_u * (1.0 + 0.20 * math.sin(a * 3.0 + 0.7) + 0.18 * n), a)
        cap.append((math.cos(a) * rr, math.sin(a) * rr))
    add_disc_slab(ledges, cap, crown_top, crown_thick)
    for k in range(4):
        a = rng.uniform(0.0, math.tau)
        # Well inside the cap's narrowest wobble - out at the rim a gull ends
        # up standing past the edge on the angles where the rim pulls in.
        rr = rng.uniform(0.8, 2.4)
        perches.append((math.cos(a) * rr, math.sin(a) * rr, crown_top, a))
    for k in range(8):
        a = rng.uniform(0.0, math.tau)
        w = rng.uniform(1.0, 2.0)
        streak(a, crown_top - crown_thick + 0.15, crown_floor + rng.uniform(0.2, 2.4), w, w * rng.uniform(0.7, 1.0))
    # The summit cone is the one stretch with no ledge above it to stain from,
    # so it gets its own windows or the top of the stack stays bare grey.
    for k in range(6):
        stain_runs.append(
            (rng.uniform(0.0, math.tau), rng.uniform(0.05, 0.12), crown_top - crown_thick, crown_floor - 1.0)
        )

    # ---- the three terraces, each BROKEN INTO ARCS rather than closed. A
    # continuous ring all the way round rendered as a machined drum - the stack
    # came out a wedding cake - and real ledges come and go along a face. The
    # gaps between arcs leave bare riser showing, which is what sells them.
    for u_in, u_out, wobble, z_top, thick, floor, arcs, gulls, runs in ROOK_TERRACES:
        pips = abs(z_top - 36.0) < 0.01
        # Pip's terrace has to have unbroken slab under his spawn angle, so its
        # first arc is CENTRED on it instead of falling where the seed likes.
        origin = (ROOK_PAD_A - math.tau / (2 * arcs)) if pips else rng.uniform(0.0, math.tau)
        span_all, arc_ends = [], []
        for i in range(arcs):
            a0 = origin + i * math.tau / arcs + rng.uniform(0.04, 0.16)
            a1 = a0 + math.tau / arcs - rng.uniform(0.30, 0.60)
            # Step each arc DOWN by its own amount so one terrace is not one
            # continuous altitude all the way round - three dead-level bands
            # stacked up read as a layer cake however broken the arcs are. Only
            # downward: an arc lifted above z_top loses its buried inner edge.
            # Pip's arc is pinned, because Islands.luau spawns him on it.
            za = z_top if (pips and i == 0) else z_top + rng.uniform(-2.6, 0.0)
            span_all.extend((a, ri, ro, za) for a, ri, ro in ledge_arc(a0, a1, za, thick, u_in, u_out, wobble, 0.0, 9))
            arc_ends.append((a0, a1, za))
        # Seat the colony from the slabs just built - one angular sample each,
        # radius anywhere across the tread. This list IS the placement rule.
        for s in rng.sample(range(len(span_all)), min(gulls, len(span_all))):
            a, ri, ro, za = span_all[s]
            if pips and abs(((a - ROOK_PAD_A + math.pi) % math.tau) - math.pi) < ROOK_PAD_CLEAR:
                continue  # keep Pip's pad bare - a nest there and he stands in it
            r = ri + (ro - ri) * rng.uniform(0.36, 0.78)
            perches.append((math.cos(a) * r, math.sin(a) * r, za, a))
        # The guano runs off THIS ledge, started inside its own arcs so the
        # white is always under occupied rock rather than sprayed at random.
        for k in range(runs):
            a0, a1, za = arc_ends[k % len(arc_ends)]
            a = rng.uniform(a0 + 0.05, a1 - 0.05)
            # Start UNDER the lip, not level with it: begun flush, a run's top
            # end stuck out past the scalloped edge as a little floating tab.
            top = za - thick - 0.35
            # Narrow and near parallel-sided. Wide runs that pinched to a point
            # hung under the ledges as white FANGS; guano runs and fades, it
            # does not taper to a tip, so several thin ones beat one broad one.
            # These are the SHORT crisp runs off the lip, where the lip really
            # does overhang the rock; the long wash is painted on below.
            w = rng.uniform(1.1, 2.3)
            streak(a, top, top - rng.uniform(0.22, 0.5) * (top - floor), w, w * rng.uniform(0.70, 1.0))
        # ...and the wash itself, recorded as windows on the rock under each arc.
        for a0, a1, za in arc_ends:
            for k in range(3):
                # One base facet wide, occasionally two. The base mesh is only
                # 34 segments round, so down here a single face is a five-by-
                # thirteen-stud panel - windows any wider than this merged into
                # one white chute pouring off the stack.
                top = za - thick
                stain_runs.append(
                    (
                        rng.uniform(a0 + 0.16, a1 - 0.16),
                        rng.uniform(0.03, 0.11),
                        top,
                        top - rng.uniform(0.45, 1.0) * (top - floor + 1.0),
                    )
                )

    # ---- the cliff bands: short shelves cantilevered off the bare face
    # between the terraces. Same arc slab as a terrace, only narrow - built
    # with the height-anchored inner edge so it is under rock however the crag
    # wobble falls, and it juts far enough that a bird on it has air beneath.
    for z_hi, z_lo, n_shelves in ROOK_CLIFFS:
        for k in range(n_shelves):
            # NEVER hang a shelf over Pip's pad. NpcService raycasts straight
            # down at his anchor and stands him on the FIRST thing it hits, so
            # a shelf on the band above the terrace would lift him off it and
            # leave him on a two-foot ledge over a 12-stud drop.
            for _try in range(16):
                a = rng.uniform(0.0, math.tau)
                if z_lo < 35.0 or abs(((a - ROOK_PAD_A + math.pi) % math.tau) - math.pi) > 0.40:
                    break
            z_top = z_lo + (z_hi - z_lo) * rng.uniform(0.16, 0.80) + 1.1  # clear of crag
            u_out = _rook_u_at_height(z_top)
            # Modest jut and a scalloped edge: round 2 threw these 3.8 studs
            # off the wall with a straight lip and they read as white café
            # tables bolted to the rock rather than as broken-off rock.
            jut = rng.uniform(1.9, 2.8)
            half = rng.uniform(2.6, 4.4) / max(ring_radius(u_out, a), 4.0)
            spans = ledge_arc(
                a - half,
                a + half,
                z_top,
                ROOK_SHELF_THICK,
                _rook_u_at_height(z_top + ROOK_SHELF_BURY),
                u_out,
                0.020,
                jut,
                5,
            )
            for b in range(rng.randint(1, 2)):
                sa, _ri, ro = spans[rng.randrange(len(spans))]
                r = ro - rng.uniform(0.5, 1.3)  # out on the lip, over the drop
                perches.append((math.cos(sa) * r, math.sin(sa) * r, z_top, sa))
            for b in range(rng.randint(1, 2)):  # the shelf's own runs, off its lip
                sa = a + rng.uniform(-half * 0.7, half * 0.7)
                w = rng.uniform(0.9, 1.7)
                streak(sa, z_top - ROOK_SHELF_THICK + 0.1, z_top - rng.uniform(2.6, 5.0), w, w * 0.85)
            stain_runs.append((a, min(half * 0.8, 0.10), z_top - ROOK_SHELF_THICK, z_top - rng.uniform(6.0, 11.0)))

    # ---- the guano wash, PAINTED ONTO THE BASE MESH. Slab ribbons alone read
    # as white boards leaned against the cliff no matter how close they are
    # pushed; repainting the rock's own faces to slot 3 is flush by
    # construction, costs no geometry, and in this faceted style a whole riser
    # facet going white under a crowded ledge is exactly the look. The face is
    # claimed by the first window that covers it - one stain, not a fight.
    for poly in base.data.polygons:
        cx, cy, cz = poly.center
        pa = math.atan2(cy, cx)
        for a_c, a_h, z_hi, z_lo in stain_runs:
            if z_lo <= cz <= z_hi and abs(((pa - a_c + math.pi) % math.tau) - math.pi) <= a_h:
                poly.material_index = 3
                break

    # ---- the colony, placed ONLY from `perches`. Two in five get a nest, and
    # a bird with a nest sits up in its cup rather than beside it.
    for px, py, pz, pa in perches:
        yaw = pa + rng.uniform(-0.6, 0.6)
        if rng.random() < 0.40:
            nest(nests, px, py, pz, yaw)
            gull(birds, px, py, pz + 0.20, yaw)
        else:
            gull(birds, px, py, pz, yaw)

    # A few in the air off the seaward face, so the stack reads as busy.
    for k in range(7):
        a = rng.uniform(0.0, math.tau)
        rr = rng.uniform(1.05, 1.5) * ISLAND_RADIUS
        gull(birds, math.cos(a) * rr, math.sin(a) * rr, 26.0 + rng.uniform(-7.0, 9.0), rng.uniform(0, math.tau), flying=True)

    # MEASURE Pip's pad, do not assert it: NpcService raycasts down at his
    # anchor and stands him on the first hit, so the only honest check is to
    # cast the same ray here, over the ledges AND the base, and print what it
    # actually lands on. Round 1 printed height_at() for this, which is the
    # smooth profile and not the surface anything stands on.
    pad_x, pad_y = math.cos(ROOK_PAD_A) * ROOK_PAD_R, math.sin(ROOK_PAD_A) * ROOK_PAD_R
    ledge_obj = object_from_bmesh("Rookery_Ledges", ledges, ["M_RookShelf"])
    pad_hits = []
    for probe in (ledge_obj, base):
        h = _drop_to_ground(_ground_bvh(probe), pad_x, pad_y)
        if h is not None:
            pad_hits.append((h, probe.name))
    pad_top, pad_on = max(pad_hits) if pad_hits else (float("nan"), "NOTHING")
    near = min((math.dist((px, py, pz), (pad_x, pad_y, pad_top)) for px, py, pz, _pa in perches), default=99.0)
    # PROVE the seating instead of trusting it: cast down at every gull and
    # confirm the ledge really is under its feet. This is the check round 1
    # could never have passed - a bird stuck to a cone has nothing beneath it.
    ltree = _ground_bvh(ledge_obj)
    floating = 0
    for px, py, pz, _pa in perches:
        hit = ltree.ray_cast(Vector((px, py, pz + 0.6)), Vector((0.0, 0.0, -1.0)))
        if hit[0] is None or abs(hit[0].z - pz) > 0.7:
            floating += 1
    if floating:
        raise RuntimeError(f"[island_gen] rookery: {floating} gulls have no ledge under them")
    print(
        f"[island_gen] HANDOFF rookery (The Rookery Stack): NPC pad (Roblox rel) X={pad_x:.0f} "
        f"Z={-pad_y:.0f} / (Blender) x={pad_x:.0f} y={pad_y:.0f} - a straight-down ray there lands "
        f"on {pad_on} at Y={pad_top:.2f} (that is the flat terrace top, and NOT height_at, which "
        f"reads {height_at(pad_x, pad_y):.2f} here); nearest gull/nest {near:.1f} studs away"
    )
    print(
        f"[island_gen] HANDOFF rookery: {len(perches)} gulls seated on built ledges (crown cap, "
        f"3 terraces, {sum(c[2] for c in ROOK_CLIFFS)} shelves - all in Rookery_Ledges, NOT on the "
        f"base mesh), every one raycast-checked to have slab under its feet; Rookery_Birds carries "
        f"7 gulls in flight - the ONE intended floating object"
    )
    random.setstate(state)
    return [
        base,
        ledge_obj,
        object_from_bmesh("Rookery_Streaks", streaks, ["M_RookStreak"]),
        object_from_bmesh("Rookery_Nests", nests, ["M_RookNest", "M_RookEgg"]),
        object_from_bmesh("Rookery_Birds", birds, ["M_RookGull"]),
    ]


# ================================================================ THE DROWNED CHAPEL (islet)
# Only a bell tower and a slice of steep roof stand above the water; the nave
# is down there, and you fish INTO it through the hole in the roof. The shoal
# is deliberately just under the surface so the building, not the rock, is the
# island.


def _chapel_paint(bm, first, index):
    """Give every face added since `first` another material slot - how the one
    bell object carries bronze as well as iron, timber, rope and river stone
    (the importer splits it into <Name> / <Name>2 / ..., which is what
    MESH_COLOR keys)."""
    for f in list(bm.faces)[first:]:
        f.material_index = index


def build_islet_chapel():
    rng = random.Random(5503)
    state = random.getstate()
    base = build_island_base("Chapel_Base", ["M_ChapShoal", "M_ChapSilt", "M_ChapWet"])
    stone, roof, drowned, bell = bmesh.new(), bmesh.new(), bmesh.new(), bmesh.new()

    # The tower: five courses of dressed stone up to the belfry floor, an OPEN
    # belfry stage over them with the bell hanging in it, and a leaning cross on
    # the cap.
    TOWER_X, TOWER_Y = -6.0, 4.0
    foot = height_at(TOWER_X, TOWER_Y)
    for k in range(5):
        w = 9.4 - k * 0.22
        add_box(stone, (TOWER_X, TOWER_Y, foot + 2.4 + k * 4.4), (w, w, 4.4))
    # add_box takes a CENTRE, so the top of the last course is its centre plus
    # half its height - not one whole course beyond it. Getting that wrong put
    # the cap slab floating 2.2 studs above the tower.
    BELFRY = foot + 2.4 + 4 * 4.4 + 2.2  # the top of the shaft IS the belfry floor
    cap = BELFRY + 8.8  # the cap sits exactly where it did: the stage is two courses
    # A string course corbelled out under the belfry floor - the shadow line
    # that says the stage above is a different thing from the shaft.
    add_box(stone, (TOWER_X, TOWER_Y, BELFRY - 0.4), (9.4, 9.4, 0.8))
    # Belfry openings: the piers stand at the CORNERS and the four faces between
    # them are cut clean away. The old code put the piers at the face MIDPOINTS
    # and then buried them inside a solid seventh course, so the stage was never
    # open at all - the tower was a plain shaft and the bell was walled up in it.
    PIER, JAMB = 3.15, 1.7  # the jambs land at 2.3, so each opening is 4.6 wide
    for sx in (-1, 1):
        for sy in (-1, 1):
            add_box(stone, (TOWER_X + sx * PIER, TOWER_Y + sy * PIER, BELFRY + 4.4), (JAMB, JAMB, 8.8))
    # The arched heads: courses stepping in over each opening along a semicircle
    # of radius ARCH_R - and ARCH_R is exactly the clear half-span, so the arch
    # springs off the jambs instead of sitting on them like a flat lintel.
    SPRING, ARCH_R = BELFRY + 5.4, 2.3
    for ax, ay in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        for i in range(8):
            t0, t1 = i * ARCH_R / 8.0, (i + 1) * ARCH_R / 8.0
            half = math.sqrt(max(ARCH_R ** 2 - t1 ** 2, 0.0))  # the clear opening at this course's TOP
            wide = ARCH_R - half
            for side in (-1, 1):
                off = side * (half + ARCH_R) / 2.0
                add_box(
                    stone,
                    (TOWER_X + ax * PIER - ay * off, TOWER_Y + ay * PIER + ax * off, SPRING + (t0 + t1) / 2.0),
                    (JAMB if ax else wide, JAMB if ay else wide, t1 - t0),
                )
    # The cornice closing the stage off over the arch crowns, then the cap slab.
    add_box(stone, (TOWER_X, TOWER_Y, cap - 0.6), (8.6, 8.6, 1.2))
    add_box(stone, (TOWER_X, TOWER_Y, cap + 0.7), (10.6, 10.6, 1.4))
    # The cross, leaning.
    add_box(stone, (TOWER_X, TOWER_Y, cap + 3.6), (0.5, 0.5, 4.6), yaw=0.2)
    add_box(stone, (TOWER_X, TOWER_Y, cap + 4.4), (2.8, 0.45, 0.45), yaw=0.2)

    # ---- the bell, which is the only reason anybody comes here ----
    # The frame first: two bearers laid right across the stage with their ends
    # buried in the corner piers (the only masonry up here), and the headstock
    # lapped up under them. A beam that ends in mid-air reads as floating.
    first = len(bell.faces)
    FRAME = cap - 1.70
    for sy in (-1, 1):
        # 7.8 long, NOT past the piers: an end poking out through the tower face
        # reads as a stray brown block stuck on the masonry.
        add_box(bell, (TOWER_X, TOWER_Y + sy * 2.9, FRAME), (7.8, 1.0, 1.0))
    HEAD = FRAME - 0.85  # the headstock the bell actually hangs from
    add_box(bell, (TOWER_X, TOWER_Y, HEAD), (1.5, 6.8, 1.3))
    _chapel_paint(bell, first, 2)

    # The bell. The profile is a list of (height above the mouth, radius) and
    # every frustum is derived from a CONSECUTIVE PAIR of them, so each course's
    # bottom radius IS the top radius of the course below it and the silhouette
    # cannot step outward anywhere. The bellbuoy gave each course its own
    # (r0, r1) pair that widened downward off a narrow start, so every course
    # flared past the one below: it rendered as a pinecone. Do not do that.
    BELL_TOP = HEAD - 0.95  # daylight under the headstock for the yoke to cross
    # 3.44 across the mouth in a 4.6 opening: the bell is sized to FILL the arch
    # it hangs in, because at 80 studs a modest bell is a smudge in a shadow.
    BELL_PROFILE = [
        (0.00, 1.76),  # the mouth - the lip is the widest line on the bell
        (0.24, 1.48),  # the flare sweeping up off it, hard
        (0.60, 1.28),  # into the sound bow, where a clapper would strike
        (1.26, 1.17),  # the waist: two thirds of the mouth, and it barely tapers
        (1.94, 1.09),  # ... which is the swell doing the work
        (2.40, 0.96),
        (2.82, 0.62),  # the shoulder turns hard in
        (3.20, 0.38),  # to the crown
    ]
    BELL_MOUTH = BELL_TOP - BELL_PROFILE[-1][0]
    first = len(bell.faces)
    for (h0, r0), (h1, r1) in zip(BELL_PROFILE, BELL_PROFILE[1:]):
        add_cone(bell, (TOWER_X, TOWER_Y, BELL_MOUTH + h0), r0, r1, h1 - h0, sides=12)
    _chapel_paint(bell, first, 0)

    # The yoke: a collar standing proud of the crown, and two iron straps swept
    # up over the shoulder into the headstock - drawn from explicit end points
    # with _tilt_toward, the same way the whalefall's ribs are.
    first = len(bell.faces)
    add_cone(bell, (TOWER_X, TOWER_Y, BELL_TOP - 0.38), 0.70, 0.54, 0.52, sides=10)
    for sy in (-1, 1):
        pts = [
            (TOWER_X, TOWER_Y + sy * 1.18, BELL_MOUTH + 1.78),  # made off at the waist
            (TOWER_X, TOWER_Y + sy * 1.01, BELL_MOUTH + 2.41),
            (TOWER_X, TOWER_Y + sy * 0.55, BELL_MOUTH + 3.01),  # round the shoulder
            (TOWER_X, TOWER_Y + sy * 0.38, HEAD + 0.25),  # and up into the headstock
        ]
        for p0, p1 in zip(pts, pts[1:]):
            d = (p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2])
            ln = math.sqrt(d[0] ** 2 + d[1] ** 2 + d[2] ** 2)
            # Thin enough to read as a STRAP hugging the bell: any fatter and
            # the pair turns into two dark flaps hiding the shoulder curve.
            add_cone(bell, p0, 0.16, 0.16, ln, sides=4, tilt=_tilt_toward(Vector(d).normalized()))
    _chapel_paint(bell, first, 1)

    # NO CLAPPER. The whole three-chapter chain is about the thing that
    # swallowed it, and "I have been ringing a bell with a stone tied to a rope
    # for two years" is only a good line if you can SEE it: so the rope takes a
    # turn over the headstock and the stone hangs a clapper's length clear below
    # the mouth, in the open, where the belfry arch frames it.
    STONE_Z = BELL_MOUTH - 1.28  # low enough that a clear run of rope shows under the lip
    ROPE_TOP = HEAD + 0.52  # made off INSIDE the headstock, not perched on top of it
    first = len(bell.faces)
    add_cone(bell, (TOWER_X, TOWER_Y, STONE_Z), 0.15, 0.12, ROPE_TOP - STONE_Z, sides=5)
    add_box(bell, (TOWER_X, TOWER_Y, ROPE_TOP), (1.9, 0.32, 0.30))  # the turns round the beam
    _chapel_paint(bell, first, 3)
    first = len(bell.faces)
    add_blob(bell, (TOWER_X, TOWER_Y, STONE_Z), (0.48, 0.48, 0.54), 0.20, 61.0, yaw=0.6)
    _chapel_paint(bell, first, 4)

    # The nave roof: a steep ridge running away from the tower and INTO the
    # water, with a hole torn in it - the hole is the whole point, you drop a
    # line through it.
    # A 4-gon yawed 45 degrees puts its VERTICES on the diagonals, so its edges
    # are axis-aligned and its half-width is the circumradius over root two -
    # which is the number Odd's pad has to keep clear of, below.
    ROOF_HALF = 6.2 / math.sqrt(2.0)
    for k in range(9):
        t = k / 8.0
        rx = TOWER_X + 6.0 + k * 5.4
        rz = 5.6 - t * 11.0  # the ridge walks down under the surface
        if k in (3, 4):
            continue  # the torn hole
        add_cone(roof, (rx, TOWER_Y, rz), 6.2, 6.2, 0.9, sides=4, tilt=(0.0, 0.0), yaw=0.785)
        add_box(roof, (rx, TOWER_Y, rz - 1.4), (0.9, 8.8, 2.6))  # the ridge beam under it

    # The drowned nave: columns and pew blocks on the silt, all below z=0.
    for k in range(7):
        cx = TOWER_X + 8.0 + k * 5.2
        for side in (-5.0, 5.0):
            add_cone(drowned, (cx, TOWER_Y + side, -7.5), 1.05, 0.85, 6.0, sides=7)
        if k % 2 == 0:
            add_box(drowned, (cx, TOWER_Y, -7.0), (3.6, 7.4, 0.9))

    # Odd's landing: a slab of fallen masonry beside the tower, above water. He
    # STANDS on this - NpcService raycasts straight down at the island's spawn
    # X/Z and puts him on whatever it hits - so the stand point is written as
    # the exact Roblox-relative anchor Islands.luau uses (X=2, Z=3), which in
    # BUILD space is (2, -3): the exporter is Y-up, so Roblox Z = -blender_y.
    # Build (2, +3) is the nave roof; that sign is the whole trap here.
    SLAB_X, SLAB_Y, SLAB_W = TOWER_X + 7.5, TOWER_Y - 7.0, 11.0
    add_box(stone, (SLAB_X, SLAB_Y, foot + 1.6), (SLAB_W, SLAB_W, 3.2))
    stand_x, stand_y = 2.0, -3.0
    slab_top = foot + 3.2
    roof_near = -(TOWER_Y - ROOF_HALF)  # Roblox rel Z of the roof's nearest edge

    print(
        f"[island_gen] HANDOFF chapel (The Drowned Chapel): tower cap Y={cap + 1.4:.1f}, roof hole at "
        f"(Roblox rel) X={TOWER_X + 6.0 + 3.5 * 5.4:.0f} Z={-TOWER_Y:.0f}; "
        f"belfry floor Y={BELFRY:.1f}, bell mouth Y={BELL_MOUTH:.1f}, the stone on the rope hangs at "
        f"Y={STONE_Z:.1f} over (Roblox rel) X={TOWER_X:.0f} Z={-TOWER_Y:.0f}; "
        f"NPC stand (Roblox rel) X={stand_x:.0f} Z={-stand_y:.0f} is honest slab: top Y={slab_top:.2f}, "
        f"pad X=[{SLAB_X - SLAB_W / 2:.1f},{SLAB_X + SLAB_W / 2:.1f}] "
        f"Z=[{-(SLAB_Y + SLAB_W / 2):.1f},{-(SLAB_Y - SLAB_W / 2):.1f}], "
        f"{-stand_y - roof_near:.1f} studs clear of the nave roof (nearest roof edge Z={roof_near:.1f})"
    )
    random.setstate(state)
    return [
        base,
        object_from_bmesh("Chapel_Stone", stone, ["M_ChapStone"]),
        object_from_bmesh("Chapel_Roof", roof, ["M_ChapSlate"]),
        object_from_bmesh("Chapel_Nave", drowned, ["M_ChapDrowned"]),
        object_from_bmesh(
            "Chapel_Bell", bell, ["M_ChapBronze", "M_ChapIron", "M_ChapTimber", "M_ChapRope", "M_ChapCobble"]
        ),
    ]


# ================================================================ THE WHALE FALL (islet)
# A whale skeleton half-buried on a sandbar: a spine, a ribcage you can walk
# THROUGH, and a skull sunk in the sand. The ribs are the silhouette.


def build_islet_whalefall():
    rng = random.Random(5504)
    state = random.getstate()
    base = build_island_base("Whalefall_Base", ["M_WhaleSand", "M_WhaleDark", "M_WhaleWet"])
    bone, life = bmesh.new(), bmesh.new()

    # The spine runs across the bar; the ribcage arches over its middle.
    AX, AY = -26.0, -6.0  # skull end
    BX, BY = 30.0, 6.0  # tail end
    # One CONTINUOUS spine: each vertebra is drawn from its own point to the
    # next, not as an isolated stub at each station - separate stubs read as a
    # row of dropped blocks rather than a backbone.
    n = 16
    spine_pts = []
    for k in range(n + 1):
        t = k / n
        x = AX + (BX - AX) * t
        y = AY + (BY - AY) * t
        z = height_at(x, y) + 1.6 + math.sin(t * math.pi) * 1.1
        spine_pts.append((x, y, z))
    for k in range(n):
        p0, p1 = spine_pts[k], spine_pts[k + 1]
        d = (p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2])
        ln = math.sqrt(d[0] ** 2 + d[1] ** 2 + d[2] ** 2)
        r = 1.45 - 0.85 * (k / n)
        add_cone(bone, p0, r, r * 0.94, ln, sides=6, tilt=_tilt_toward(Vector(d).normalized()))

    # Ribs: paired arcs off the spine, tallest amidships. Each rib is a chain of
    # segments swung out and up, so the pair meets high enough to walk under.
    for k in range(7):
        t = 0.16 + k * 0.085
        sx = AX + (BX - AX) * t
        sy = AY + (BY - AY) * t
        sz = height_at(sx, sy) + 1.6
        span = 6.2 * math.sin(t * math.pi) + 2.4  # amidships ribs are the big ones
        for side in (-1, 1):
            segs = 7
            for i in range(segs):
                f0, f1 = i / segs, (i + 1) / segs
                # Sweep past 90 degrees so each rib comes back IN over the
                # spine: a rib that stops at 90 stands straight up and the pair
                # never closes, which reads as a fence, not a ribcage.
                a0, a1 = f0 * (math.pi * 0.80), f1 * (math.pi * 0.80)
                p0 = (sx, sy + side * math.sin(a0) * span, sz + (1 - math.cos(a0)) * span * 0.95)
                p1 = (sx, sy + side * math.sin(a1) * span, sz + (1 - math.cos(a1)) * span * 0.95)
                d = (p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2])
                ln = math.sqrt(d[0] ** 2 + d[1] ** 2 + d[2] ** 2)
                add_cone(bone, p0, 0.62 - 0.05 * i, 0.55 - 0.05 * i, ln, sides=5, tilt=_tilt_toward(Vector(d).normalized()))

    # The skull: a long wedge of jaw sunk nose-first into the sand.
    add_cone(bone, (AX, AY, height_at(AX, AY) + 0.6), 3.4, 1.1, 12.0, sides=7, tilt=(0.0, -1.15))
    add_box(bone, (AX + 3.0, AY, height_at(AX + 3.0, AY) + 1.1), (9.0, 4.6, 1.1), yaw=0.2)

    # Scavengers: small crabs and tube worms clustered on the bones.
    for _ in range(22):
        t = rng.uniform(0.1, 0.95)
        x = AX + (BX - AX) * t + rng.uniform(-2.5, 2.5)
        y = AY + (BY - AY) * t + rng.uniform(-6.0, 6.0)
        z = height_at(x, y)
        if rng.random() < 0.5:
            add_cone(life, (x, y, z + 0.05), 0.5, 0.34, 0.42, sides=6)
            for leg in range(4):
                la = leg * 1.57 + 0.4
                add_box(life, (x + math.cos(la) * 0.55, y + math.sin(la) * 0.55, z + 0.2), (0.7, 0.16, 0.14), yaw=la)
        else:
            add_cone(life, (x, y, z), 0.22, 0.14, rng.uniform(0.7, 1.6), sides=5)

    stand_x, stand_y = 4.0, -16.0
    print(
        f"[island_gen] HANDOFF whalefall (The Whale Fall): spine runs (Roblox rel) X={AX:.0f} Z={-AY:.0f} "
        f"to X={BX:.0f} Z={-BY:.0f}; NPC stand X={stand_x:.0f} Z={-stand_y:.0f} ground Y={height_at(stand_x, stand_y):.1f}"
    )
    random.setstate(state)
    return [
        base,
        object_from_bmesh("Whalefall_Bones", bone, ["M_WhaleBone"]),
        object_from_bmesh("Whalefall_Life", life, ["M_WhaleLife"]),
    ]


# ================================================================ THE ANCHOR GARDEN (islet)
# A shallow reef where two dozen anchors stand upright in the sand like a
# sculpture garden, chains swagged between them. ONE chain is taut and runs off
# into deep water - something is still on the other end.


def build_islet_anchorage():
    rng = random.Random(5505)
    state = random.getstate()
    base = build_island_base("Anchorage_Base", ["M_AnchSand", "M_AnchReef", "M_AnchWet"])
    iron = bmesh.new()

    def anchor(bm, x, y, scale, yaw):
        g = height_at(x, y)
        shank = 7.0 * scale
        add_cone(bm, (x, y, g - 0.6), 0.52 * scale, 0.38 * scale, shank, sides=6)
        # The stock across the top, and the ring above it.
        add_box(bm, (x, y, g + shank * 0.86), (5.4 * scale, 0.44 * scale, 0.44 * scale), yaw=yaw + 1.57)
        add_cone(bm, (x, y, g + shank * 0.94), 0.6 * scale, 0.5 * scale, 0.9 * scale, sides=7)
        # Two arms sweeping up off the crown, each ending in a fluke.
        for side in (-1, 1):
            for i in range(4):
                f0, f1 = i / 4.0, (i + 1) / 4.0
                a0, a1 = f0 * 1.15, f1 * 1.15
                p0 = (x + side * math.sin(a0) * 2.6 * scale * math.cos(yaw), y + side * math.sin(a0) * 2.6 * scale * math.sin(yaw), g - 0.4 + (1 - math.cos(a0)) * 2.4 * scale)
                p1 = (x + side * math.sin(a1) * 2.6 * scale * math.cos(yaw), y + side * math.sin(a1) * 2.6 * scale * math.sin(yaw), g - 0.4 + (1 - math.cos(a1)) * 2.4 * scale)
                d = (p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2])
                ln = math.sqrt(d[0] ** 2 + d[1] ** 2 + d[2] ** 2)
                add_cone(bm, p0, 0.46 * scale, 0.4 * scale, ln, sides=5, tilt=_tilt_toward(Vector(d).normalized()))
            tipx = x + side * math.sin(1.15) * 2.6 * scale * math.cos(yaw)
            tipy = y + side * math.sin(1.15) * 2.6 * scale * math.sin(yaw)
            add_cone(bm, (tipx, tipy, g - 0.4 + (1 - math.cos(1.15)) * 2.4 * scale), 1.15 * scale, 0.1, 2.0 * scale, sides=5, tilt=(0.0, side * 0.5))

    placed = []
    for _ in range(24):
        for _try in range(30):
            a = rng.uniform(0.0, math.tau)
            rr = rng.uniform(0.10, 0.78) * ISLAND_RADIUS
            x, y = math.cos(a) * rr, math.sin(a) * rr
            if all((x - px) ** 2 + (y - py) ** 2 > 121.0 for px, py, _ in placed):
                sc = rng.uniform(0.72, 1.35)
                anchor(iron, x, y, sc, rng.uniform(0.0, math.tau))
                placed.append((x, y, sc))
                break

    # Chains swagged between neighbours: a catenary of short links, both ends
    # buried in the anchor stocks they hang from.
    def chain(bm, p, q, sag, links=9):
        for i in range(links):
            f0, f1 = i / links, (i + 1) / links
            def at(f):
                return (
                    p[0] + (q[0] - p[0]) * f,
                    p[1] + (q[1] - p[1]) * f,
                    p[2] + (q[2] - p[2]) * f - math.sin(f * math.pi) * sag,
                )
            a0, a1 = at(f0), at(f1)
            d = (a1[0] - a0[0], a1[1] - a0[1], a1[2] - a0[2])
            ln = math.sqrt(d[0] ** 2 + d[1] ** 2 + d[2] ** 2)
            add_cone(bm, a0, 0.3, 0.28, ln, sides=4, tilt=_tilt_toward(Vector(d).normalized()))

    placed.sort(key=lambda t: math.atan2(t[1], t[0]))
    for i in range(len(placed) - 1):
        x0, y0, s0 = placed[i]
        x1, y1, s1 = placed[i + 1]
        if (x0 - x1) ** 2 + (y0 - y1) ** 2 < 900.0 and rng.random() < 0.75:
            chain(iron, (x0, y0, height_at(x0, y0) + 6.0 * s0), (x1, y1, height_at(x1, y1) + 6.0 * s1), rng.uniform(1.6, 3.4))

    # THE taut one: dead straight, no sag, running off the reef into deep water.
    tx, ty, ts = placed[0]
    chain(iron, (tx, ty, height_at(tx, ty) + 6.0 * ts), (math.cos(0.6) * ISLAND_RADIUS * 1.45, math.sin(0.6) * ISLAND_RADIUS * 1.45, -6.0), 0.0, links=16)

    stand_x, stand_y = 0.0, 0.0
    print(
        f"[island_gen] HANDOFF anchorage (The Anchor Garden): {len(placed)} anchors; the TAUT chain leaves from "
        f"(Roblox rel) X={tx:.0f} Z={-ty:.0f}; NPC stand X={stand_x:.0f} Z={-stand_y:.0f} ground Y={height_at(stand_x, stand_y):.1f}"
    )
    random.setstate(state)
    return [base, object_from_bmesh("Anchorage_Iron", iron, ["M_AnchIron"])]


# ================================================================ THE BOILING SHOAL (islet)
# A vent islet: black glass underfoot, water too hot to swim, vent cones
# bubbling, mineral crusts in sulphur yellow and rust red. Steam is geometry.


def _shoal_paint(bm, first, index):
    """Give every face added since `first` another material slot (the importer
    splits a multi-slot object into <Name> / <Name>2 / ...)."""
    for f in list(bm.faces)[first:]:
        f.material_index = index


# The two channels where sea and lagoon exchange: (centre bearing, half width).
# These MIRROR the entry's NOTCHES - keep the two lists in step or the rim
# stands on ground that was never cut and the gap stops being a gap.
_SHOAL_GAPS = [(-0.80, 0.30), (2.95, 0.22)]
_SHOAL_CREST_A = 2.05  # bearing the caldera wall stands highest on
_SHOAL_HUT_A = 2.15  # the bath-house sits just inside the tall wall
_SHOAL_LAGOON_Z = 1.05  # milky turquoise surface, a hair above the open sea


def _shoal_ground(x, y):
    """The REAL base-mesh height: height_at is only the smooth profile, and the
    boilshoal base carries both a crag on the outer bank and two notch-cut
    channels. Everything this islet places stands on this, not on height_at."""
    u = u_at(x, y)
    return height_at(x, y) + crag(x, y, u) - notch_cut(math.atan2(y, x), u)


def _shoal_gate(theta):
    """1.0 out on the solid ring, 0.0 in the middle of a gap - how much rim
    there is at this bearing."""
    g = 1.0
    for a0, half in _SHOAL_GAPS:
        da = abs(((theta - a0 + math.pi) % math.tau) - math.pi)
        if da < half:
            g = min(g, smoothstep(half * 0.30, half, da))
    return g


def _shoal_crest(theta):
    """Rim height above the bank: a wall on one side, nothing on the other."""
    lean = 0.5 + 0.5 * math.cos(theta - _SHOAL_CREST_A)
    n = noise.noise(Vector((math.cos(theta) * 2.6, math.sin(theta) * 2.6, 4.0)))
    n += 0.6 * noise.noise(Vector((math.cos(theta) * 7.5, math.sin(theta) * 7.5, 11.0)))
    # A real low reef even on the drowned side - the ring has to read as a RING
    # with two breaks in it, not as a wall that fades to nothing.
    return (3.4 + 11.2 * lean ** 1.7 + n * 3.8) * _shoal_gate(theta)


def _shoal_lobed(cx, cy, r, salt, seg=22, lobes=5, amp=0.15):
    """A scalloped closed loop - the rimstone pool lip, never a circle."""
    pts = []
    for s in range(seg):
        a = (s / seg) * math.tau
        w = 1.0 + amp * math.sin(lobes * a + salt) + amp * 0.55 * math.sin((lobes + 4) * a + salt * 2.3)
        pts.append((cx + math.cos(a) * r * w, cy + math.sin(a) * r * w))
    return pts


def _shoal_plume(steam, rng, x, y, z, r, n, rise=2.1, drift=1.1):
    """Steam is geometry - but PUFFS, not pillars. Stacked drums read as white
    obelisks and swamped the whole islet on the first render; soft lumpy blobs
    that swell and drift as they climb read as vapour."""
    for k in range(n):
        s = r * (0.95 + k * 0.34)
        add_blob(steam, (x, y, z), (s, s * 0.9, s * 0.62), 0.30, rng.uniform(0.0, 40.0), yaw=rng.uniform(0.0, math.tau))
        z += s * 0.44  # heavily overlapping, so the puffs merge into vapour, not beads
        x += rng.uniform(-drift, drift)
        y += rng.uniform(-drift, drift)


def _shoal_chimney(vents, glow, steam, rng, x, y, base_z, h, r_bot, r_top, sides=8, plume=0):
    """One vent cone: black glass throat, sulphur-yellow crusted mouth, a rust
    skirt where the water it throws has stained the rock, and orange light
    sitting down the throat."""
    add_cone(vents, (x, y, base_z - 0.4), r_bot, r_top, h + 0.4, sides=sides)
    first = len(vents.faces)
    add_cone(vents, (x, y, base_z + h - 0.55), r_top * 1.05, r_top * 1.16, 0.8, sides=sides)
    _shoal_paint(vents, first, 1)
    first = len(vents.faces)
    add_cone(vents, (x, y, base_z - 0.3), r_bot * 1.42, r_bot * 1.04, 0.7, sides=sides)
    _shoal_paint(vents, first, 2)
    # The light sits proud of the mouth, so the throat reads as lit rather than
    # as a hole you cannot see into.
    add_cone(glow, (x, y, base_z + h - 0.8), r_top * 0.82, r_top * 1.24, 1.9, sides=sides)
    if plume:
        _shoal_plume(steam, rng, x, y, base_z + h + 0.5, r_top * 1.0, plume)


def _shoal_fish(bm, rng, x, y, z, size):
    """A bleached dead fish, belly up on the crust."""
    yaw = rng.uniform(0.0, math.tau)
    add_box(bm, (x, y, z + size * 0.16), (size * 2.1, size * 0.72, size * 0.5), yaw=yaw)
    add_cone(
        bm,
        (x - math.cos(yaw) * size * 1.0, y - math.sin(yaw) * size * 1.0, z + size * 0.16),
        size * 0.34,
        size * 0.9,
        size * 0.8,
        sides=4,
        tilt=_tilt_toward(Vector((-math.cos(yaw), -math.sin(yaw), 0.15)).normalized()),
    )


def _shoal_terrace(terr, glow, steam, vents, rng, cx, cy, bearing, levels, r0, grow, top_z, step, salt):
    """A Pamukkale stack: chalk-white rimstone pools stepping DOWNHILL from a
    spring, each lip wider and lower than the one above, the lowest drowning in
    the lagoon. Every level is a solid column down past the floor, so the stack
    is its own mound - no gap under it whatever the terrain does."""
    bx, by = math.cos(bearing), math.sin(bearing)
    sx, sy = -by, bx  # across the fall line
    shift_per = grow + 1.9  # each step clears the one above, or its pools are buried
    floor = min(_shoal_ground(cx, cy), _shoal_ground(cx + bx * levels * shift_per, cy + by * levels * shift_per)) - 1.4
    for k in range(levels):
        z = top_z - k * step
        px, py = cx + bx * k * shift_per, cy + by * k * shift_per
        r = r0 + k * grow
        lip = _shoal_lobed(px, py, r, salt + k * 0.9, seg=16 if r < 9 else 22, lobes=5 + (k % 3), amp=0.19)
        first = len(terr.faces)
        add_disc_slab(terr, lip, z, z - floor)
        # The drowned lips go grey-green; the dry ones stay chalk.
        wet = z < _SHOAL_LAGOON_Z + 0.35
        if wet:
            _shoal_paint(terr, first, 1)
        # The scalloped POOLS, out in the downhill crescent the step above does
        # not cover - concentric and flush with the chalk, the step above simply
        # buries them, which is what the first two rounds did. Each is a basin:
        # water held inside a raised rimstone dam.
        pr = r * 0.30
        for j, across in enumerate((0.0, -1.0, 1.0)):
            # Tessellation is the whole poly budget here: a third pool only where
            # the step is wide enough to show it.
            if j and r < 6.5:
                break
            if j == 2 and r < 10.5:
                break
            q = pr * (1.0 if j == 0 else 0.66)
            qx = px + bx * (r * 0.38) + sx * across * r * 0.44
            qy = py + by * (r * 0.38) + sy * across * r * 0.44
            water = _shoal_lobed(qx, qy, q, salt + k * 0.9 + j, seg=10, lobes=4, amp=0.16)
            dam = _shoal_lobed(qx, qy, q * 1.34, salt + k * 0.9 + j, seg=10, lobes=4, amp=0.16)
            f = len(terr.faces)
            add_ring_slab(terr, water, dam, z + 0.78, 1.0)
            if wet:
                _shoal_paint(terr, f, 1)
            f = len(terr.faces)
            add_disc_slab(terr, water, z + 0.50, 0.7)
            _shoal_paint(terr, f, 2)
    # The spring itself, on the crown.
    _shoal_chimney(vents, glow, steam, rng, cx, cy, top_z + 0.5, rng.uniform(1.8, 3.0), 1.6, 0.9, plume=3)
    return floor


def _shoal_hut_pt(rad, off, z):
    """Bath-house local frame: `rad` runs outward along the hut bearing, `off`
    across it. Returns a world (x, y, z)."""
    ca, sa = math.cos(_SHOAL_HUT_A), math.sin(_SHOAL_HUT_A)
    return (ca * rad - sa * off, sa * rad + ca * off, z)


def _shoal_hut_box(bm, rad, off, z, size, spin=0.0):
    add_box(bm, _shoal_hut_pt(rad, off, z), size, yaw=_SHOAL_HUT_A + spin)


def build_islet_boilshoal():
    """THE BOILING SHOAL - the most hostile-looking water on the map.

    A shallow lagoon inside a BROKEN caldera rim: a ragged ring of black
    volcanic glass standing twelve studs on one bearing and drowning to nothing
    on the other, cut by two channels where the sea and the lagoon exchange.
    Inside it the water is a different colour from the sea entirely - milky
    turquoise, and hot. The player wades it; the vents are in there with them.
    Chalk-white RIMSTONE TERRACES step down off the hot springs into it, and
    Cinder - who thinks cold water has nothing worth having - keeps a
    BATH-HOUSE on an obsidian shelf at the foot of the tall wall, with a vent
    plumbed straight into his soaking tub.
    """
    rng = random.Random(5506)
    state = random.getstate()
    base = build_island_base("Boilshoal_Base", ["M_ShoalGlass", "M_ShoalCrust", "M_ShoalWet"])
    rim, lagoon, terr = bmesh.new(), bmesh.new(), bmesh.new()
    vents, steam, glow = bmesh.new(), bmesh.new(), bmesh.new()
    hut, apron, smalls = bmesh.new(), bmesh.new(), bmesh.new()

    # ---------------------------------------------------------------- the rim
    # Blocks of cooled glass all the way round, each rooted well below the bank
    # so nothing can float. Where a gap is, the gate takes the crest to zero and
    # what is left sits under the waterline as a drowned reef you can see.
    RIM_N = 72
    for i in range(RIM_N):
        theta = (i / RIM_N) * math.tau + rng.uniform(-0.010, 0.010)
        gate = _shoal_gate(theta)
        r = ring_radius(0.97, theta) + rng.uniform(-2.2, 2.2)
        x, y = math.cos(theta) * r, math.sin(theta) * r
        g = _shoal_ground(x, y)
        top = g + _shoal_crest(theta) + rng.uniform(-0.9, 0.9) - (1.0 - gate) * 1.6
        top = max(top, g - 0.6)
        # Thickness tracks height: a short block on the drowned side must be a
        # SHARD, not a wide flat pancake lying on the water.
        rise = max(top - g, 0.4)
        thick = min(3.0 + rise * 0.78, 12.0) * rng.uniform(0.78, 1.25)
        arc = (math.tau * r / RIM_N) * rng.uniform(1.35, 1.85)
        # Rooted deep, but NEVER past the skirt: the radial jitter can drop a
        # block onto the outer scarp, and -5.5 from there punched the exported
        # bbox bottom to -9.46 (the base must own the -9).
        _z0 = max(g - 5.5, SKIRT_BOTTOM + 0.4)
        add_box(rim, (x, y, (_z0 + top) * 0.5), (thick, arc, top - _z0), yaw=theta)
        # A second, shorter block shouldered against the first: the ring reads
        # as broken slabs rather than one extruded wall.
        if rng.random() < 0.55:
            r2 = r + rng.uniform(-7.0, 6.0)
            a2 = theta + rng.uniform(-0.05, 0.05)
            x2, y2 = math.cos(a2) * r2, math.sin(a2) * r2
            g2 = _shoal_ground(x2, y2)
            t2 = g2 + (top - g) * rng.uniform(0.34, 0.82)
            b2 = max(g2 - 5.0, SKIRT_BOTTOM + 0.4)
            add_box(rim, (x2, y2, (b2 + t2) * 0.5), (thick * 0.62, arc * 0.72, t2 - b2), yaw=a2)
        # Sulphur has crusted the lagoon-side lip of the standing wall.
        if gate > 0.45 and top - g > 2.2 and rng.random() < 0.85:
            ri = r - thick * 0.5
            xi, yi = math.cos(theta) * ri, math.sin(theta) * ri
            first = len(rim.faces)
            add_cone(rim, (xi, yi, top - 1.0), arc * 0.44, arc * 0.30, 1.3, sides=5, yaw=theta)
            _shoal_paint(rim, first, 1)
        # Obsidian shards standing off the crest, catching the light.
        for _ in range(rng.randint(0, 2) if gate > 0.4 else 0):
            sa = theta + rng.uniform(-0.05, 0.05)
            sr = r + rng.uniform(-4.5, 4.5)
            sx, sy = math.cos(sa) * sr, math.sin(sa) * sr
            h = rng.uniform(1.8, 4.6)
            add_cone(
                rim,
                (sx, sy, top - 0.5),
                rng.uniform(0.5, 1.1),
                0.12,
                h,
                sides=4,
                tilt=(rng.uniform(-0.30, 0.30), rng.uniform(-0.30, 0.30)),
                yaw=rng.uniform(0.0, math.tau),
            )

    # ------------------------------------------------------------ the bath-house shelf
    # A stepped obsidian terrace out of the steaming lagoon at the foot of the
    # tall wall. Its top course IS Cinder's apron: flat, dry, prop-free.
    APRON_Z = 3.4
    _shoal_hut_box(apron, 34.0, 0.0, -0.9, (37.0, 28.5, 8.6))
    _shoal_hut_box(apron, 34.5, 0.0, 1.80, (33.0, 24.5, 1.2), spin=0.035)
    _shoal_hut_box(apron, 35.0, 0.0, 2.90, (29.0, 21.0, 1.0), spin=-0.03)
    # A worn step down off the front lip, so the apron is reachable from the water.
    _shoal_hut_box(apron, 21.5, 0.0, 2.20, (5.0, 15.0, 1.4))
    _shoal_hut_box(apron, 18.6, 0.0, 1.10, (3.4, 11.0, 1.4))
    # Loose obsidian slabs stacked along the shelf edges - a bare black
    # rectangle read as a table top, so the perimeter gets broken up. NOTHING
    # goes on the pad itself (rad 22-32, |off| < 8): that is where Cinder stands.
    for _ in range(30):
        rr = rng.uniform(21.0, 49.0)
        oo = rng.uniform(-11.0, 11.0)
        if abs(oo) < 7.6 and rr < 47.5:
            continue  # the pad, the walk-up and the hut footprint all stay clear
        if 33.5 < rr < 50.5 and abs(oo) < 8.4:
            continue  # the hut walls
        add_box(
            apron,
            _shoal_hut_pt(rr, oo, APRON_Z + rng.uniform(0.1, 1.4)),
            (rng.uniform(2.4, 6.0), rng.uniform(2.0, 5.0), rng.uniform(0.7, 2.4)),
            yaw=_SHOAL_HUT_A + rng.uniform(-0.5, 0.5),
        )
    first = len(apron.faces)
    for _ in range(16):
        rr = rng.uniform(20.0, 49.0)
        oo = rng.uniform(-10.5, 10.5)
        if 33.0 < rr < 51.0 and abs(oo) < 8.0:
            continue
        if 22.0 < rr < 31.0 and abs(oo) < 6.0:
            continue  # Cinder's pad: nothing on it, not even a stain
        add_cone(apron, _shoal_hut_pt(rr, oo, APRON_Z - 0.05), rng.uniform(1.1, 3.0), rng.uniform(0.8, 2.4), 0.24, sides=6)
    _shoal_paint(apron, first, 1)

    # ------------------------------------------------------------------ the hut
    # Slots: 0 obsidian, 1 verdigris copper, 2 timber, 3 chalk, 4 iron,
    # 5 tub water, 6 bleached fish.
    HR, FLOOR, EAVE = 42.0, APRON_Z, 8.4
    _shoal_hut_box(hut, HR, 0.0, FLOOR + 0.25, (15.6, 13.6, 0.5))
    for k in range(4):
        z = FLOOR + 0.5 + 0.55 + k * 1.1
        j = 0.20 * (1 if k % 2 else -1)
        _shoal_hut_box(hut, HR + 7.0 + j, 0.0, z, (1.5, 13.6, 1.1), spin=0.02 * (1 if k % 2 else -1))
        _shoal_hut_box(hut, HR + j * 0.5, 6.3 + j, z, (14.5, 1.5, 1.1))
        _shoal_hut_box(hut, HR + j * 0.5, -6.3 - j, z, (14.5, 1.5, 1.1))
        # Front wall: two stubs either side of a doorway wide enough that the
        # tub is visible from the apron - the whole point of a bath-house.
        if k < 3:
            _shoal_hut_box(hut, HR - 7.0 - j, 5.35, z, (1.5, 3.4, 1.1))
            _shoal_hut_box(hut, HR - 7.0 - j, -5.35, z, (1.5, 3.4, 1.1))
    # Timber corner posts and a door frame.
    first = len(hut.faces)
    for rr, oo in ((HR + 7.2, 6.5), (HR + 7.2, -6.5), (HR - 7.2, 6.5), (HR - 7.2, -6.5)):
        x, y, _ = _shoal_hut_pt(rr, oo, 0.0)
        add_post(hut, x, y, FLOOR, EAVE + 0.5, 0.5, sides=5)
    for oo in (3.4, -3.4):
        x, y, _ = _shoal_hut_pt(HR - 7.1, oo, 0.0)
        add_post(hut, x, y, FLOOR, EAVE, 0.34, sides=4)
    _shoal_hut_box(hut, HR - 7.1, 0.0, EAVE - 0.2, (0.7, 5.2, 0.7))
    _shoal_paint(hut, first, 2)

    # Roof: scavenged copper sheet gone verdigris, a shallow gable pitched
    # across the hut, with the ridge left OPEN at the back for the steam.
    first = len(hut.faces)
    RIDGE = 13.2
    for side in (1, -1):
        eave = [Vector(_shoal_hut_pt(rr, side * 8.6, EAVE)) for rr in (HR - 9.8, HR, HR + 9.8)]
        crest = [Vector(_shoal_hut_pt(rr, side * 0.55, RIDGE)) for rr in (HR - 9.8, HR, HR + 9.8)]
        add_strip_slab(hut, eave, crest, 0.55)
        # Overlapping sheet seams laid ON the pitch (a fixed-height box floats
        # off a slope, which is what round one's flying planks were).
        for t in (0.24, 0.56, 0.84):
            for rr in (HR - 5.6, HR + 5.6):
                a = Vector(_shoal_hut_pt(rr, side * 8.6, EAVE))
                b = Vector(_shoal_hut_pt(rr, side * 0.55, RIDGE))
                p = a.lerp(b, t)
                add_box(hut, (p.x, p.y, p.z + 0.30), (7.6, 0.9, 0.28), yaw=_SHOAL_HUT_A)
    _shoal_hut_box(hut, HR - 1.2, 0.0, RIDGE + 0.40, (17.5, 2.2, 0.8))
    _shoal_paint(hut, first, 1)

    # The tub: a chalk-lined basin fed by its own vent through a stone spout.
    first = len(hut.faces)
    # The tub sits FORWARD of centre and the drying rack goes to one side, so
    # the whole point of the building - a man in a hot bath - is visible from
    # the apron through the open front.
    TUB_R, TUB_TOP = HR + 0.6, FLOOR + 2.8
    for dr, do, wr, wo in ((3.5, 0.0, 0.9, 8.0), (-3.5, 0.0, 0.9, 8.0), (0.0, 3.6, 7.6, 0.9), (0.0, -3.6, 7.6, 0.9)):
        _shoal_hut_box(hut, TUB_R + dr, do, (FLOOR + TUB_TOP) * 0.5 + 0.15, (wr, wo, TUB_TOP - FLOOR - 0.3))
    _shoal_hut_box(hut, TUB_R, 0.0, FLOOR + 0.55, (7.6, 8.0, 0.6))
    # The spout: a chalk channel off the back-wall vent, running out over the tub.
    _shoal_hut_box(hut, HR + 5.4, 0.0, TUB_TOP + 1.6, (5.0, 2.2, 0.7))
    _shoal_paint(hut, first, 3)
    first = len(hut.faces)
    pool = _shoal_lobed(*_shoal_hut_pt(TUB_R, 0.0, 0.0)[:2], 3.1, 1.7, seg=14, lobes=4, amp=0.05)
    add_disc_slab(hut, pool, TUB_TOP - 0.4, 1.5)
    _shoal_hut_box(hut, HR + 3.4, 0.0, TUB_TOP + 0.65, (1.0, 1.6, 2.2))  # the fall
    _shoal_paint(hut, first, 5)
    # Fish drying in the steam, on a rack along the side wall.
    first = len(hut.faces)
    for rr in (HR - 3.4, HR + 4.4):
        x, y, _ = _shoal_hut_pt(rr, 5.0, 0.0)
        add_post(hut, x, y, FLOOR, EAVE - 1.0, 0.3, sides=4)
    _shoal_hut_box(hut, HR + 0.5, 5.0, EAVE - 1.15, (8.4, 0.5, 0.4))
    _shoal_paint(hut, first, 2)
    first = len(hut.faces)
    for k in range(5):
        add_box(hut, _shoal_hut_pt(HR - 2.8 + k * 1.8, 5.0, EAVE - 2.5), (0.9, 0.5, 2.3), yaw=_SHOAL_HUT_A)
    _shoal_paint(hut, first, 6)
    # Steam off the tub: a wisp inside, seen through the doorway, and the mass
    # of it escaping over the open back of the ridge.
    tbx, tby, _ = _shoal_hut_pt(TUB_R, 0.0, 0.0)
    _shoal_plume(steam, rng, tbx, tby, TUB_TOP + 0.9, 1.1, 2, drift=0.4)
    _shoal_plume(steam, rng, tbx, tby, RIDGE + 0.6, 1.9, 6, drift=1.4)
    add_cone(glow, (tbx, tby, TUB_TOP - 1.6), 2.3, 2.7, 0.5, sides=8)  # the feed, under the water

    # The cooking vent out on the apron: a short chimney with an iron pot
    # socketed on it, and the vent's own light down the throat.
    cvx, cvy, _ = _shoal_hut_pt(38.0, -9.6, 0.0)
    _shoal_chimney(vents, glow, steam, rng, cvx, cvy, APRON_Z, 2.4, 2.0, 1.15, plume=2)
    first = len(hut.faces)
    add_cone(hut, (cvx, cvy, APRON_Z + 2.4), 1.7, 2.35, 2.1, sides=8)
    add_cone(hut, (cvx, cvy, APRON_Z + 4.4), 2.45, 2.15, 0.4, sides=8)
    for hs in (1, -1):  # a bail handle over the mouth
        add_cone(
            hut, (cvx + hs * 1.9, cvy, APRON_Z + 4.7), 0.22, 0.18, 1.5, sides=4,
            tilt=(0.0, math.radians(-38 * hs)),
        )
    _shoal_paint(hut, first, 4)

    # ---------------------------------------------------------- rimstone terraces
    # The signature: chalk stepping down into the turquoise. Three cascades,
    # each aimed at the middle of the lagoon so they read from the channel.
    # (radius, bearing, levels, top pool radius, growth per step, crown z, drop
    # per step). The drop is tuned so the last lip lands just under the lagoon.
    TERRACES = [
        (33.0, -0.30, 8, 4.8, 1.85, 9.0, 1.30),
        (36.0, -1.66, 7, 4.2, 1.70, 7.8, 1.25),
        (29.0, 0.80, 6, 3.8, 1.55, 6.6, 1.20),
        (40.0, -2.60, 5, 3.2, 1.35, 5.4, 1.10),
    ]
    terrace_spots = []
    for rr, aa, levels, r0, grow, top_z, step in TERRACES:
        cx, cy = math.cos(aa) * rr, math.sin(aa) * rr
        bearing = math.atan2(-cy, -cx)  # downhill = toward the middle of the lagoon
        _shoal_terrace(terr, glow, steam, vents, rng, cx, cy, bearing, levels, r0, grow, top_z, step, rr * 0.7)
        terrace_spots.append((cx, cy, r0 + levels * grow + 3.0))

    # ------------------------------------------------------------------ the vents
    def clear_of(x, y, pad):
        if any((x - tx) ** 2 + (y - ty) ** 2 < (tr + pad) ** 2 for tx, ty, tr in terrace_spots):
            return False
        hx, hy, _ = _shoal_hut_pt(34.0, 0.0, 0.0)
        return (x - hx) ** 2 + (y - hy) ** 2 > 26.0 ** 2

    # Tall dry chimneys standing on the bank and on the shoulder of the wall.
    tall = 0
    for _ in range(90):
        if tall >= 6:
            break
        a = rng.uniform(0.0, math.tau)
        if _shoal_gate(a) < 0.75:
            continue
        r = ring_radius(rng.uniform(0.80, 0.90), a)
        x, y = math.cos(a) * r, math.sin(a) * r
        if not clear_of(x, y, 2.0):
            continue
        g = _shoal_ground(x, y)
        if g < 0.4:
            continue
        h = rng.uniform(5.0, 10.5)
        _shoal_chimney(vents, glow, steam, rng, x, y, g, h, rng.uniform(2.4, 3.6), rng.uniform(1.0, 1.6), plume=rng.randint(4, 6))
        tall += 1

    # Short drowned chimneys out in the lagoon - some just breaking the milky
    # surface, some entirely under it with the glow showing through.
    drowned = []
    for _ in range(160):
        if len(drowned) >= 15:
            break
        a = rng.uniform(0.0, math.tau)
        r = rng.uniform(0.10, 0.74) * ISLAND_RADIUS
        x, y = math.cos(a) * r, math.sin(a) * r
        if not clear_of(x, y, 3.0) or any((x - px) ** 2 + (y - py) ** 2 < 100.0 for px, py in drowned):
            continue
        g = _shoal_ground(x, y)
        h = rng.uniform(1.1, 3.6)
        _shoal_chimney(vents, glow, steam, rng, x, y, g, h, rng.uniform(2.0, 3.4), rng.uniform(0.9, 1.7), sides=7,
                       plume=2 if g + h > _SHOAL_LAGOON_Z + 0.8 else 0)
        drowned.append((x, y))

    # Out in the open lagoon: obsidian shards standing through the surface and
    # bleached fish floating belly-up on it, so the wading water is not blank.
    first = len(smalls.faces)
    shards = 0
    for _ in range(120):
        if shards >= 14:
            break
        a, r = rng.uniform(0.0, math.tau), rng.uniform(0.14, 0.74) * ISLAND_RADIUS
        x, y = math.cos(a) * r, math.sin(a) * r
        if not clear_of(x, y, 2.5) or any((x - px) ** 2 + (y - py) ** 2 < 36.0 for px, py in drowned):
            continue
        shards += 1
        add_cone(
            smalls, (x, y, _shoal_ground(x, y) - 0.4), rng.uniform(0.7, 1.8), 0.12, rng.uniform(3.0, 6.0),
            sides=4, tilt=(rng.uniform(-0.34, 0.34), rng.uniform(-0.34, 0.34)), yaw=rng.uniform(0.0, math.tau),
        )
    _shoal_paint(smalls, first, 1)
    floaters = 0
    for _ in range(120):
        if floaters >= 12:
            break
        a, r = rng.uniform(0.0, math.tau), rng.uniform(0.16, 0.76) * ISLAND_RADIUS
        x, y = math.cos(a) * r, math.sin(a) * r
        if not clear_of(x, y, 2.0):
            continue
        floaters += 1
        _shoal_fish(smalls, rng, x, y, _SHOAL_LAGOON_Z + 0.12, rng.uniform(0.7, 1.3))

    # -------------------------------------------------------------- the lagoon
    # Its own thin disc of milky turquoise, a hair above the open sea and a
    # completely different colour from it. Thick enough that its underside sits
    # below the sea surface, so in the two channels the two waters meet flush.
    ring = []
    for s in range(72):
        a = (s / 72) * math.tau
        ring.append((math.cos(a) * ring_radius(0.94, a), math.sin(a) * ring_radius(0.94, a)))
    add_disc_slab(lagoon, ring, _SHOAL_LAGOON_Z, 1.7)

    # ------------------------------------------------------------------ smalls
    # 0 bleached fish, 1 obsidian shards, 2 rust stain, 3 sulphur crust.
    for _ in range(15):
        a = rng.uniform(0.0, math.tau)
        r = ring_radius(rng.uniform(0.80, 0.99), a)
        x, y = math.cos(a) * r, math.sin(a) * r
        if not clear_of(x, y, 1.0):
            continue
        _shoal_fish(smalls, rng, x, y, _shoal_ground(x, y) + 0.15, rng.uniform(0.7, 1.35))
    for cx, cy, _r in terrace_spots[:2]:
        for _ in range(2):
            _shoal_fish(smalls, rng, cx + rng.uniform(-6.0, 6.0), cy + rng.uniform(-6.0, 6.0), _SHOAL_LAGOON_Z + 0.25, rng.uniform(0.7, 1.1))
    first = len(smalls.faces)
    for _ in range(26):
        a = rng.uniform(0.0, math.tau)
        r = ring_radius(rng.uniform(0.72, 0.98), a)
        x, y = math.cos(a) * r, math.sin(a) * r
        if not clear_of(x, y, 1.0):
            continue
        add_cone(
            smalls, (x, y, _shoal_ground(x, y) - 0.3), rng.uniform(0.5, 1.3), 0.1, rng.uniform(1.6, 4.2),
            sides=4, tilt=(rng.uniform(-0.4, 0.4), rng.uniform(-0.4, 0.4)), yaw=rng.uniform(0.0, math.tau),
        )
    _shoal_paint(smalls, first, 1)
    first = len(smalls.faces)
    for _ in range(20):
        a = rng.uniform(0.0, math.tau)
        r = ring_radius(rng.uniform(0.74, 0.97), a)
        x, y = math.cos(a) * r, math.sin(a) * r
        if not clear_of(x, y, 1.0):
            continue
        add_disc_slab(smalls, _shoal_lobed(x, y, rng.uniform(1.8, 4.4), a * 3.0, seg=9, lobes=3, amp=0.22), _shoal_ground(x, y) + 0.1, 0.3)
    _shoal_paint(smalls, first, 2)
    first = len(smalls.faces)
    for _ in range(22):
        a = rng.uniform(0.0, math.tau)
        r = ring_radius(rng.uniform(0.76, 1.0), a)
        x, y = math.cos(a) * r, math.sin(a) * r
        if not clear_of(x, y, 1.0):
            continue
        add_disc_slab(smalls, _shoal_lobed(x, y, rng.uniform(1.4, 3.6), a * 5.0, seg=8, lobes=3, amp=0.25), _shoal_ground(x, y) + 0.14, 0.3)
    _shoal_paint(smalls, first, 3)

    objects = [
        base,
        object_from_bmesh("Boilshoal_Rim", rim, ["M_ShoalGlass", "M_ShoalCrust"]),
        object_from_bmesh("Boilshoal_Apron", apron, ["M_ShoalGlass", "M_ShoalCrust"]),
        object_from_bmesh("Boilshoal_Terraces", terr, ["M_ShoalChalk", "M_ShoalChalkWet", "M_ShoalPool"]),
        object_from_bmesh("Boilshoal_Vents", vents, ["M_ShoalGlass", "M_ShoalCrust", "M_ShoalMineral"]),
        object_from_bmesh(
            "Boilshoal_Hut",
            hut,
            ["M_ShoalGlass", "M_ShoalCopper", "M_ShoalTimber", "M_ShoalChalk", "M_ShoalIron", "M_ShoalPool", "M_ShoalFish"],
        ),
        object_from_bmesh("Boilshoal_Smalls", smalls, ["M_ShoalFish", "M_ShoalGlass", "M_ShoalMineral", "M_ShoalCrust"]),
        object_from_bmesh("Boilshoal_Lagoon", lagoon, ["M_ShoalLagoon"]),
        object_from_bmesh("Boilshoal_Glow", glow, ["M_ShoalHeat"]),
        object_from_bmesh("Boilshoal_Steam", steam, ["M_ShoalSteam"]),
    ]

    # NPC stand: the apron's top course, measured by a real downward raycast
    # onto the built shelf - not height_at, which knows nothing about it.
    stand_x, stand_y, _ = _shoal_hut_pt(26.0, 0.0, 0.0)
    apron_obj = next(o for o in objects if o.name == "Boilshoal_Apron")
    stand_z = _drop_to_ground(_ground_bvh(apron_obj), stand_x, stand_y)
    print(
        f"[island_gen] HANDOFF boilshoal (The Boiling Shoal): broken caldera rim with "
        f"{len(_SHOAL_GAPS)} channels, {len(TERRACES)} rimstone cascades, {tall} dry vents, "
        f"{len(drowned)} drowned vents; lagoon surface object Boilshoal_Lagoon at z {_SHOAL_LAGOON_Z:.2f}; "
        f"NPC stand (Roblox rel) X={stand_x:.1f} Z={-stand_y:.1f} ground Y={stand_z:.2f} "
        f"(bath-house apron, prop-free); radius 60"
    )
    random.setstate(state)
    return objects


# ================================================================ THE FERRYMAN'S RAFT (islet)
# Not an island: a raft somebody LIVES on, moored in the emptiest water on the
# map. Lashed logs and barrels under a plank deck, a lean-to, a trading counter,
# and a mooring chain going down into the dark.


def build_islet_ferryraft():
    rng = random.Random(5507)
    state = random.getstate()
    base = build_island_base("Ferryraft_Base", ["M_RaftBar", "M_RaftShallow", "M_RaftWet"])
    hull, shack, rope, glow = bmesh.new(), bmesh.new(), bmesh.new(), bmesh.new()

    DECK = 2.6  # deck top, just clear of the water
    HALF = 15.0

    # Buoyancy under the deck: logs across, barrels wedged between them. They
    # sit AT the waterline - half under, half proud - so it reads as floating.
    for k in range(7):
        y = -HALF + 1.5 + k * (2 * (HALF - 1.5) / 6)
        add_cone(hull, (-HALF, y, 0.55), 1.35, 1.35, 2 * HALF, sides=7, tilt=(0.0, 1.5708))
    for _ in range(9):
        bx = rng.uniform(-HALF + 3.0, HALF - 3.0)
        by = rng.uniform(-HALF + 3.0, HALF - 3.0)
        add_cone(hull, (bx, by, -0.3), 1.5, 1.5, 3.0, sides=8)

    # The deck: planks running the other way, over the logs.
    for k in range(11):
        x = -HALF + 1.4 + k * (2 * (HALF - 1.4) / 10)
        add_box(hull, (x, 0.0, DECK - 0.3), (2.6, 2 * HALF, 0.6))

    # The lean-to: three walls, a canvas roof, a stove pipe.
    add_box(shack, (-6.0, 6.0, DECK + 3.0), (11.0, 0.5, 6.0))
    add_box(shack, (-11.2, 1.0, DECK + 3.0), (0.5, 10.5, 6.0))
    add_box(shack, (-0.8, 1.0, DECK + 3.0), (0.5, 10.5, 6.0))
    add_box(shack, (-6.0, 1.0, DECK + 6.4), (11.6, 11.0, 0.5), yaw=0.0)
    add_cone(shack, (-9.0, 4.0, DECK + 6.6), 0.5, 0.42, 3.4, sides=6)

    # The trading counter on the open side - this is where the Ferryman stands.
    add_box(shack, (5.0, 0.0, DECK + 1.5), (4.0, 9.0, 0.6))
    for cy in (-3.8, 3.8):
        add_box(shack, (5.0, cy, DECK + 0.6), (3.2, 0.6, 1.8))
    # Crates and a coil of rope on the deck. The scatter must keep off the spot
    # the HANDOFF below calls the Ferryman's stand: a crate can be 2.3 wide and
    # sits ON the deck, so an unlucky draw buries him to the chest in cargo
    # (measured: one landed at the pad and put the ground 1.1 studs over his
    # feet). Rejection-sample instead of shrinking the scatter, which would
    # push every crate to the rail and leave the deck bare.
    STAND = (8.0, 0.0)
    for _ in range(5):
        for _attempt in range(24):
            cx, cy = rng.uniform(0.0, HALF - 3.0), rng.uniform(-HALF + 3.0, HALF - 3.0)
            if math.hypot(cx - STAND[0], cy - STAND[1]) > 4.6:
                break
        sz = rng.uniform(1.4, 2.3)
        add_box(shack, (cx, cy, DECK + sz * 0.5), (sz * 2, sz * 2, sz), yaw=rng.uniform(0, 1.5))
    add_cone(rope, (10.0, -8.0, DECK), 1.9, 1.6, 0.9, sides=9)

    # Fish drying on a line between two poles, and a lantern on each pole.
    for px in (-1.0, 11.0):
        add_cone(shack, (px, -11.0, DECK), 0.34, 0.28, 7.0, sides=5)
        add_cone(glow, (px, -11.0, DECK + 7.2), 0.55, 0.45, 0.9, sides=6)
    add_box(rope, (5.0, -11.0, DECK + 6.4), (12.0, 0.16, 0.16))
    for k in range(6):
        fx = -0.2 + k * 2.1
        add_cone(rope, (fx, -11.0, DECK + 4.9), 0.42, 0.16, 1.5, sides=5)

    # The mooring chain: windlass on deck, chain straight down into the water.
    add_cone(shack, (12.0, 6.0, DECK), 1.2, 1.2, 1.8, sides=8, tilt=(1.5708, 0.0))
    for k in range(7):
        add_cone(rope, (12.6, 6.0, DECK - k * 1.6), 0.26, 0.24, 1.6, sides=4)

    # The steering oar, shipped along the stern.
    add_cone(shack, (-HALF + 2.0, -13.0, DECK + 1.2), 0.42, 0.3, 17.0, sides=5, tilt=(0.0, 1.42))

    print(
        f"[island_gen] HANDOFF ferryraft (The Ferryman's Raft): deck top Y={DECK:.1f}, counter at (Roblox rel) "
        f"X=5 Z=0 top Y={DECK + 1.8:.1f}; NPC stand X=8 Z=0 deck Y={DECK:.1f}; mooring chain at X=13 Z=-6"
    )
    random.setstate(state)
    return [
        base,
        object_from_bmesh("Ferryraft_Hull", hull, ["M_RaftLog"]),
        object_from_bmesh("Ferryraft_Shack", shack, ["M_RaftPlank"]),
        object_from_bmesh("Ferryraft_Rope", rope, ["M_RaftRope"]),
        object_from_bmesh("Ferryraft_Glow", glow, ["M_RaftLantern"]),
    ]


# ================================================================ THE LOADSTONE SPIRE (islet)
# A lightning-struck magnetite tor. Not one needle but a CATHEDRAL CLUSTER of
# fused black spires standing out of a shattered rubble field - the strikes
# break the rock apart, so the ground reads as debris, not as a dome. The
# signature is FULGURITE: hollow branching white glass tubes where lightning
# fused the sand, standing up out of the rubble like roots. Ansel lives here in
# a Faraday shack wrapped in every chain he owns, earthed into the sea, with a
# lightning rod that plainly does not work and a board of nailed-up compasses
# all pointing different directions.


def _load_paint(bm, first, index):
    """Give every face added since `first` another material slot (the importer
    splits the object into <Name> / <Name>2 / ... in slot order)."""
    for f in list(bm.faces)[first:]:
        f.material_index = index


def _load_dir(phi, psi):
    """Unit axis for a polar tilt: `phi` off vertical, bearing `psi`."""
    return (math.sin(phi) * math.cos(psi), math.sin(phi) * math.sin(psi), math.cos(phi))


def _load_seg(bm, p0, p1, r0, r1, sides=5):
    """A frustum spanning two points - the workhorse for cables, chains,
    nails, filings, fulgurite tubes and anchor arms."""
    dx, dy, dz = p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]
    length = math.sqrt(dx * dx + dy * dy + dz * dz)
    if length < 1e-5:
        return
    phi = math.acos(max(-1.0, min(1.0, dz / length)))
    psi = math.atan2(dy, dx)
    add_cone(bm, p0, r0, r1, length, sides=sides, tilt=(0.0, phi), yaw=psi)


def _load_chain(bm, p0, p1, links, rad, sag=0.0):
    """A run of chain/cable between two points, sagging by `sag` in the middle.
    Alternate links pinch so the run reads as chain rather than a pipe."""
    pts = []
    for k in range(links + 1):
        t = k / links
        pts.append(
            (
                p0[0] + (p1[0] - p0[0]) * t,
                p0[1] + (p1[1] - p0[1]) * t,
                p0[2] + (p1[2] - p0[2]) * t - sag * math.sin(math.pi * t),
            )
        )
    for k in range(links):
        r = rad if k % 2 else rad * 0.62
        _load_seg(bm, pts[k], pts[k + 1], r, rad * (0.62 if k % 2 else 1.0), sides=4)


def _load_spire_radius(t, r0):
    """ONE profile function for a needle, sampled at both ends of every course
    so consecutive frusta share their seam radius exactly (a spire stacked from
    independently-derived radii renders as a pinecone)."""
    return r0 * (0.05 + 0.95 * (1.0 - t) ** 1.28) * (1.0 + 0.075 * math.sin(t * 8.5 + 0.6))


def _load_spire(bm, x0, y0, z0, height, r0, lean_deg, dir_deg, sides=6, courses=8, twist=0.0):
    """One leaning black needle, stacked frusta. Returns (tip, axis, seams)."""
    phi, psi = math.radians(lean_deg), math.radians(dir_deg)
    d = _load_dir(phi, psi)
    seg = height / courses
    p = (x0, y0, z0)
    seams = []
    for k in range(courses):
        ra = _load_spire_radius(k / courses, r0)
        rb = _load_spire_radius((k + 1) / courses, r0)
        add_cone(bm, p, ra, rb, seg, sides=sides, tilt=(0.0, phi), yaw=psi + twist * k)
        seams.append((p, ra))
        p = (p[0] + d[0] * seg, p[1] + d[1] * seg, p[2] + d[2] * seg)
    return p, d, seams


def _load_shard(bm, x, y, z, size, salt, rng):
    """One angular block of shattered magnetite - a squat 4/5-sided frustum
    tipped off vertical, so the rubble field reads as debris, not pebbles."""
    add_cone(
        bm,
        (x, y, z),
        size * rng.uniform(0.75, 1.15),
        size * rng.uniform(0.28, 0.85),
        size * rng.uniform(0.55, 1.5),
        sides=4 if salt % 3 else 5,
        tilt=(rng.uniform(-0.30, 0.30), rng.uniform(-0.30, 0.30)),
        yaw=rng.uniform(0.0, math.tau),
    )


def _load_fulgurite(bm, rng, base, height, r0, mouths, depth=2):
    """A hollow branching glass tube fused out of the ground by a strike. Each
    limb wanders as it climbs and forks; every terminal limb flares into an
    open mouth, recorded in `mouths` for the caller to cap with a dark disc so
    the tube reads HOLLOW."""
    phi = math.radians(rng.uniform(3.0, 20.0))
    psi = rng.uniform(0.0, math.tau)
    p = base
    courses = 4 if depth else 3
    for k in range(courses):
        t0, t1 = k / courses, (k + 1) / courses
        ra, rb = r0 * (1.0 - 0.58 * t0), r0 * (1.0 - 0.58 * t1)
        h = (height / courses) * rng.uniform(0.82, 1.20)
        d = _load_dir(phi, psi)
        p1 = (p[0] + d[0] * h, p[1] + d[1] * h, p[2] + d[2] * h)
        _load_seg(bm, p, p1, ra, rb, sides=6)
        if depth > 0 and k >= 1 and rng.random() < 0.7:
            _load_fulgurite(bm, rng, p1, height * rng.uniform(0.34, 0.52), rb * 0.82, mouths, depth - 1)
        p = p1
        phi = math.radians(max(2.0, min(38.0, math.degrees(phi) + rng.uniform(-9.0, 13.0))))
        psi += rng.uniform(-0.55, 0.55)
    d = _load_dir(phi, psi)
    mouth_r = r0 * 0.42 + 0.10
    tip = (p[0] + d[0] * 0.55, p[1] + d[1] * 0.55, p[2] + d[2] * 0.55)
    _load_seg(bm, p, tip, r0 * 0.42, mouth_r * 1.45, sides=6)
    mouths.append((tip, d, mouth_r))


def _load_gull(bm, x, y, z, yaw, rng):
    """A storm-killed gull on the rubble: one wing still open."""
    add_blob(bm, (x, y, z + 0.32), (1.05, 0.52, 0.40), 0.22, 40.0 + x, yaw=yaw)
    add_blob(bm, (x + math.cos(yaw) * 1.0, y + math.sin(yaw) * 1.0, z + 0.40), (0.36, 0.30, 0.30), 0.18, 12.0 + y)
    for side in (-1.0, 1.0):
        a = yaw + side * 1.5
        tipz = z + (0.75 if side > 0 else 0.10)
        _load_seg(
            bm,
            (x, y, z + 0.30),
            (x + math.cos(a) * 1.9, y + math.sin(a) * 1.9, tipz),
            0.34,
            0.08,
            sides=4,
        )


def _load_anchor(bm, centre, out_a, scale):
    """A ship's anchor fused flat onto a spire flank by a strike. Built in the
    plane spanned by the flank's up-and-outward lean and its tangent."""
    ca, sa = math.cos(out_a), math.sin(out_a)
    up = (ca * 0.30, sa * 0.30, 0.954)
    right = (-sa, ca, 0.0)

    def f(u, v):
        return (
            centre[0] + up[0] * u * scale + right[0] * v * scale,
            centre[1] + up[1] * u * scale + right[1] * v * scale,
            centre[2] + up[2] * u * scale + right[2] * v * scale,
        )

    _load_seg(bm, f(-3.0, 0.0), f(3.1, 0.0), 0.30 * scale, 0.22 * scale, sides=6)  # shank
    _load_seg(bm, f(2.5, -1.9), f(2.5, 1.9), 0.17 * scale, 0.17 * scale, sides=5)  # stock
    for side in (-1.0, 1.0):
        _load_seg(bm, f(-2.8, 0.0), f(-1.5, 2.5 * side), 0.26 * scale, 0.20 * scale, sides=5)  # arm
        _load_seg(bm, f(-1.5, 2.5 * side), f(-0.5, 3.1 * side), 0.42 * scale, 0.06 * scale, sides=3)  # fluke
    # the ring at the head
    for k in range(6):
        a0, a1 = k * math.tau / 6, (k + 1) * math.tau / 6
        _load_seg(
            bm,
            f(3.5 + math.sin(a0) * 0.5, math.cos(a0) * 0.5),
            f(3.5 + math.sin(a1) * 0.5, math.cos(a1) * 0.5),
            0.12 * scale,
            0.12 * scale,
            sides=4,
        )


def _load_ground_y(objects, x, y):
    """The REAL surface height at (x, y): a downward raycast against every
    finished object, not the smooth profile height_at."""
    tmp = bmesh.new()
    for obj in objects:
        tmp.from_mesh(obj.data)
    tree = BVHTree.FromBMesh(tmp)
    tmp.free()
    hit = tree.ray_cast(Vector((x, y, 900.0)), Vector((0.0, 0.0, -1.0)))
    return hit[0].z if hit[0] is not None else None


# Ansel's pad and the plinth his shack stands on: reserved ground, no scatter.
_LOAD_SHACK_X, _LOAD_SHACK_Y = 0.0, -25.0
_LOAD_PLINTH_TOP = 4.0
_LOAD_PAD = (0.0, -33.2)
_LOAD_PAD_R = 4.0


def _load_reserved(x, y):
    """The shack plinth footprint plus its approach - kept free of rubble,
    fulgurite, filings and scrap so nothing lands on Ansel or his door."""
    return -9.4 <= x <= 9.4 and -37.5 <= y <= -18.6


def build_islet_loadstone():
    rng = random.Random(5508)
    state = random.getstate()
    base = build_island_base("Loadstone_Base", ["M_LoadRock", "M_LoadScorch", "M_LoadWet"])
    spires = bmesh.new()
    rubble = bmesh.new()
    fulg = bmesh.new()
    scrap = bmesh.new()
    shack = bmesh.new()
    compass = bmesh.new()
    glow = bmesh.new()
    elmo = bmesh.new()

    # ---------------------------------------------------------------- the cluster
    # Five to eight fused needles at different heights and angles: the tallest
    # runs ~90 studs, the rest 17-58, several leaning hard off it. They
    # interpenetrate at the foot, so the cluster reads as ONE broken massif.
    CLUSTER = [
        # x,     y,     height, r0,  lean, bearing, sides, courses, twist
        (0.0, 1.6, 90.0, 6.4, 3.0, 202.0, 7, 9, 0.11),
        (-8.6, -3.4, 58.0, 4.8, 8.0, 244.0, 6, 8, -0.09),
        (7.8, -4.8, 45.0, 4.3, 12.0, 52.0, 6, 7, 0.10),
        (-4.4, 9.8, 36.0, 3.7, 15.0, 128.0, 5, 6, 0.0),
        (3.4, -11.4, 31.0, 3.2, 13.0, 328.0, 6, 6, -0.12),
        (10.9, 6.2, 25.0, 3.1, 18.0, 38.0, 5, 5, 0.0),
        (-12.4, 6.6, 20.0, 2.8, 21.0, 166.0, 5, 5, 0.13),
        (13.2, -9.8, 16.0, 2.4, 25.0, 18.0, 5, 4, 0.0),
    ]
    tips = []
    for x0, y0, h, r0, lean, bear, sides, courses, twist in CLUSTER:
        z0 = height_at(x0, y0) - 2.2
        tip, axis, seams = _load_spire(spires, x0, y0, z0, h, r0, lean, bear, sides, courses, twist)
        tips.append((tip, axis, h, r0, x0, y0, z0))

    # Vitrified splash: glassy fused patches where the bolts actually landed,
    # plastered flat on the flanks (slot 2 of the spire object).
    first = len(spires.faces)
    for tip, axis, h, r0, x0, y0, z0 in tips:
        for _ in range(2 if h > 30 else 1):
            t = rng.uniform(0.12, 0.72)
            a = rng.uniform(0.0, math.tau)
            rr = _load_spire_radius(t, r0) * 0.62  # sunk INTO the flank, not stuck on it
            px = x0 + axis[0] * h * t + math.cos(a) * rr
            py = y0 + axis[1] * h * t + math.sin(a) * rr
            pz = z0 + axis[2] * h * t
            add_cone(
                spires,
                (px, py, pz),
                rng.uniform(1.0, 2.2),
                rng.uniform(0.6, 1.5),
                _load_spire_radius(t, r0) * 0.55,
                sides=6,
                tilt=(1.5708, 0.0),
                yaw=a,
            )
    _load_paint(spires, first, 1)

    # ---------------------------------------------------------------- rubble field
    GZ0 = height_at(0.0, 0.0)

    # Ansel's plinth: a heap of shards Ansel levelled the top of, NOT a
    # pedestal - the three courses are yawed off each other and the perimeter
    # is broken by loose blocks, so the silhouette never reads as one box. The
    # top face is flat at 4.0 and IS what the NPC raycast lands on.
    add_box(rubble, (_LOAD_SHACK_X - 0.9, -27.6, _LOAD_PLINTH_TOP - 3.4), (13.6, 17.2, 6.8), yaw=0.22)
    add_box(rubble, (_LOAD_SHACK_X + 0.8, -27.6, _LOAD_PLINTH_TOP - 1.5), (13.4, 16.6, 3.0), yaw=-0.17)
    add_box(rubble, (_LOAD_SHACK_X, -27.6, _LOAD_PLINTH_TOP - 0.5), (12.9, 16.2, 1.0), yaw=0.06)
    for k in range(22):
        a = k * math.tau / 22 + 0.3
        rr = 7.0 + rng.uniform(-0.5, 1.6)
        bx, by = _LOAD_SHACK_X + math.cos(a) * rr, -27.6 + math.sin(a) * rr * 1.08
        # A perimeter shard on the seaward arc would land ON the pad and stand
        # proud of it - the raycast would then put Ansel on top of a boulder.
        if abs(bx - _LOAD_PAD[0]) < 6.8 and by < _LOAD_PAD[1] + 3.0:
            continue
        _load_shard(rubble, bx, by, _LOAD_PLINTH_TOP - rng.uniform(0.9, 3.6), rng.uniform(1.5, 3.4), k, rng)
    # The flat shard-slab pad itself, right in front of the chain curtain.
    add_box(rubble, (_LOAD_PAD[0], _LOAD_PAD[1], _LOAD_PLINTH_TOP + 0.09), (11.4, 5.6, 0.36), yaw=0.03)

    # Broken ground everywhere else: angular blocks, some big enough to shelter
    # behind, tipped every way.
    placed = []
    for i in range(112):
        for _try in range(26):
            a = rng.uniform(0.0, math.tau)
            rr = math.sqrt(rng.uniform(0.02, 1.0)) * ISLAND_RADIUS * 0.96
            x, y = math.cos(a) * rr, math.sin(a) * rr
            if _load_reserved(x, y):
                continue
            if all((x - px) ** 2 + (y - py) ** 2 > 6.4 for px, py in placed):
                break
        else:
            continue
        placed.append((x, y))
        size = rng.uniform(1.0, 2.3) if rr > 27 else rng.uniform(1.7, 4.6)
        _load_shard(rubble, x, y, height_at(x, y) - size * 0.35, size, i, rng)

    # Big flat shards tipped up out of the debris - the pieces that came off
    # the needles whole. These are what make the field read SHATTERED.
    for k in range(13):
        a = rng.uniform(0.0, math.tau)
        rr = rng.uniform(13.0, ISLAND_RADIUS * 0.86)
        x, y = math.cos(a) * rr, math.sin(a) * rr
        if _load_reserved(x, y):
            continue
        w = rng.uniform(4.0, 8.5)
        add_cone(
            rubble,
            (x, y, height_at(x, y) - 1.2),
            w,
            w * rng.uniform(0.45, 0.8),
            rng.uniform(1.0, 2.0),
            sides=4,
            tilt=(rng.uniform(-0.5, 0.5), rng.uniform(-0.5, 0.5)),
            yaw=a,
        )

    # Climbable rubble ramps: stepped slabs off the plinth up into the cluster,
    # and a second run climbing the east shoulder to a flat lookout shard.
    for k in range(6):
        t = k / 5.0
        y = -18.2 + t * 6.8
        add_box(rubble, (0.6 * k, y, _LOAD_PLINTH_TOP + 0.2 + t * 1.5), (7.4 - k * 0.4, 3.4, 1.6), yaw=0.06 * k)
    for k in range(5):
        t = k / 4.0
        x = 22.0 - t * 6.0
        y = -12.0 + t * 3.0
        add_box(rubble, (x, y, height_at(x, y) + 0.4 + t * 2.1), (5.6, 5.0, 1.8), yaw=0.5 + 0.2 * k)
    add_box(rubble, (15.5, -8.4, height_at(15.5, -8.4) + 3.1), (8.6, 7.4, 1.1), yaw=0.42)
    for k in range(4):
        t = k / 3.0
        x = -20.0 + t * 5.5
        y = 14.0 - t * 4.0
        add_box(rubble, (x, y, height_at(x, y) + 0.3 + t * 1.6), (5.2, 4.6, 1.6), yaw=-0.4 - 0.22 * k)

    # Scorch stars radiating from three strike points, burned flat into the rock.
    first = len(rubble.faces)
    for cx, cy in ((14.0, 16.0), (-18.0, -12.5), (6.0, 26.5)):
        gz = height_at(cx, cy)
        for k in range(rng.randint(8, 11)):
            a = rng.uniform(0.0, math.tau)
            L = rng.uniform(3.5, 11.0)
            add_box(
                rubble,
                (cx + math.cos(a) * L * 0.5, cy + math.sin(a) * L * 0.5, gz + 0.10),
                (L, rng.uniform(0.35, 1.0), 0.14),
                yaw=a,
            )
    _load_paint(rubble, first, 1)

    # Vitrified patches: the ground itself turned to glass under the bolts.
    first = len(rubble.faces)
    for _ in range(9):
        a = rng.uniform(0.0, math.tau)
        rr = rng.uniform(9.0, ISLAND_RADIUS * 0.80)
        x, y = math.cos(a) * rr, math.sin(a) * rr
        if _load_reserved(x, y):
            continue
        add_cone(rubble, (x, y, height_at(x, y) - 0.12), rng.uniform(1.6, 3.6), rng.uniform(1.2, 2.8), 0.30, sides=7, yaw=a)
    _load_paint(rubble, first, 2)

    # ---------------------------------------------------------------- fulgurite
    # The signature. Hollow white glass tubes, branching like roots, standing
    # out of the rubble where the strikes fused the ground.
    mouths = []
    HERO = [
        (-15.5, -6.5, 15.0, 1.05),
        (11.5, 13.5, 12.5, 0.92),
        (-6.5, 19.5, 10.5, 0.80),
        (19.0, -18.0, 9.0, 0.74),
        (-21.0, 6.0, 11.5, 0.86),
        (2.0, -17.5, 7.5, 0.66),
    ]
    for hx, hy, hh, hr in HERO:
        _load_fulgurite(fulg, rng, (hx, hy, height_at(hx, hy) - 0.6), hh, hr, mouths, depth=2)
    for _ in range(8):
        a = rng.uniform(0.0, math.tau)
        rr = rng.uniform(11.0, ISLAND_RADIUS * 0.84)
        x, y = math.cos(a) * rr, math.sin(a) * rr
        if _load_reserved(x, y):
            continue
        _load_fulgurite(fulg, rng, (x, y, height_at(x, y) - 0.5), rng.uniform(2.6, 5.4), rng.uniform(0.30, 0.52), mouths, depth=1)
    # Dark discs down each open mouth - the tubes are HOLLOW.
    first = len(fulg.faces)
    for (mx, my, mz), d, mr in mouths:
        phi = math.acos(max(-1.0, min(1.0, d[2])))
        add_cone(fulg, (mx - d[0] * 0.16, my - d[1] * 0.16, mz - d[2] * 0.16), mr * 1.05, mr * 1.05, 0.10,
                 sides=6, tilt=(0.0, phi), yaw=math.atan2(d[1], d[0]))
    _load_paint(fulg, first, 1)

    # ---------------------------------------------------------------- welded scrap
    # Iron filings standing on end in FANS, curved along the field lines that
    # run into the cluster.
    for f in range(8):
        fa = f * math.tau / 8 + 0.2
        frr = rng.uniform(16.0, 34.0)
        fx, fy = math.cos(fa) * frr, math.sin(fa) * frr
        if _load_reserved(fx, fy):
            continue
        span = rng.uniform(0.7, 1.3)
        for k in range(9):
            t = k / 8.0 - 0.5
            a = fa + t * span
            rr = frr + math.cos(t * 3.0) * 2.2
            px, py = math.cos(a) * rr, math.sin(a) * rr
            gz = height_at(px, py)
            h = rng.uniform(0.7, 1.9) * (1.0 - abs(t) * 0.8)
            lean = 0.42
            _load_seg(scrap, (px, py, gz - 0.1),
                      (px - math.cos(a) * h * lean, py - math.sin(a) * h * lean, gz + h), 0.13, 0.03, sides=4)

    # Nails driven into the rock by the strikes, every which way.
    for _ in range(32):
        a = rng.uniform(0.0, math.tau)
        rr = rng.uniform(7.0, ISLAND_RADIUS * 0.82)
        x, y = math.cos(a) * rr, math.sin(a) * rr
        if _load_reserved(x, y):
            continue
        gz = height_at(x, y)
        na, np_ = rng.uniform(0.0, math.tau), rng.uniform(0.5, 1.25)
        d = _load_dir(np_, na)
        L = rng.uniform(0.9, 2.2)
        _load_seg(scrap, (x, y, gz - 0.2), (x + d[0] * L, y + d[1] * L, gz - 0.2 + d[2] * L), 0.11, 0.04, sides=4)
        add_box(scrap, (x + d[0] * L, y + d[1] * L, gz - 0.2 + d[2] * L), (0.30, 0.30, 0.10), yaw=na)

    # A whole ship's anchor fused onto the flank of the second spire.
    ax0, ay0, ah, ar0 = CLUSTER[1][0], CLUSTER[1][1], CLUSTER[1][2], CLUSTER[1][3]
    aphi, apsi = math.radians(CLUSTER[1][4]), math.radians(CLUSTER[1][5])
    aax = _load_dir(aphi, apsi)
    at = 0.26
    flank_a = math.radians(300.0)
    frad = _load_spire_radius(at, ar0) * 0.85
    anchor_c = (
        ax0 + aax[0] * ah * at + math.cos(flank_a) * frad,
        ay0 + aax[1] * ah * at + math.sin(flank_a) * frad,
        height_at(ax0, ay0) - 2.2 + aax[2] * ah * at,
    )
    _load_anchor(scrap, anchor_c, flank_a, 1.55)

    # Chain welded across the rubble by a strike, and a length still hanging
    # off the big spire.
    _load_chain(scrap, (-11.0, -14.0, height_at(-11.0, -14.0) + 0.4), (-2.0, -19.5, height_at(-2.0, -19.5) + 0.4), 9, 0.24, sag=0.5)
    _load_chain(scrap, (5.6, 3.0, GZ0 + 16.0), (9.5, 8.5, height_at(9.5, 8.5) + 0.3), 10, 0.26, sag=1.4)

    # Tools fused flat into a shard by the yard - a hammer, a saw, a kettle.
    first = len(scrap.faces)
    tx, ty = 12.0, -16.6
    tz = height_at(tx, ty) + 0.6
    _load_seg(scrap, (tx - 1.6, ty, tz), (tx + 1.2, ty + 0.4, tz + 0.5), 0.14, 0.12, sides=4)
    add_box(scrap, (tx + 1.4, ty + 0.5, tz + 0.6), (0.9, 0.4, 0.45), yaw=0.3)
    add_box(scrap, (tx - 1.0, ty + 2.6, tz + 0.9), (3.4, 0.10, 1.0), yaw=-0.4)
    add_cone(scrap, (tx + 2.6, ty + 2.2, tz - 0.4), 0.85, 0.62, 1.3, sides=7, tilt=(0.25, 0.15))

    # The lightning rod Ansel built. It is bent, scorched and plainly useless,
    # and the guy chain that once braced it has snapped.
    rx, ry = 6.6, -21.6
    rz = _LOAD_PLINTH_TOP + 0.1
    add_cone(scrap, (rx, ry, rz), 0.62, 0.46, 3.2, sides=6)  # the timber it is lashed to
    p = (rx, ry, rz + 3.2)
    bend = 0.12
    for k in range(4):
        bend += 0.22
        d = _load_dir(bend, 2.4 + k * 0.34)
        q = (p[0] + d[0] * 1.25, p[1] + d[1] * 1.25, p[2] + d[2] * 1.25)
        _load_seg(scrap, p, q, 0.26 - k * 0.03, 0.24 - k * 0.03, sides=5)
        p = q
    add_blob(scrap, p, (0.42, 0.42, 0.32), 0.4, 3.0)  # the melted stub of a tip
    # The guy chain that once braced it, snapped: three links hanging off the
    # bracket and nothing below them.
    _load_chain(scrap, (rx + 0.5, ry - 0.2, rz + 3.0), (rx + 1.5, ry - 1.1, rz + 0.9), 4, 0.15, sag=0.4)
    _load_paint(scrap, first, 1)

    # Two storm-killed gulls.
    first = len(scrap.faces)
    _load_gull(scrap, -13.6, -16.4, height_at(-13.6, -16.4) + 0.5, 1.9, rng)
    _load_gull(scrap, 12.5, 4.5, height_at(12.5, 4.5) + 0.4, -0.7, rng)
    _load_paint(scrap, first, 2)

    # ---------------------------------------------------------------- Faraday shack
    SX, SY = _LOAD_SHACK_X, _LOAD_SHACK_Y
    FZ = _LOAD_PLINTH_TOP  # floor top sits on the plinth
    HALF = 4.4
    WALL = 5.2
    DOORW = 2.7
    DOORH = 3.7
    front_y = SY - HALF
    back_y = SY + HALF

    add_box(shack, (SX, SY, FZ - 0.18), (2 * HALF + 0.6, 2 * HALF + 0.6, 0.36))  # floor
    add_box(shack, (SX - HALF, SY, FZ + WALL / 2), (0.44, 2 * HALF, WALL))
    add_box(shack, (SX + HALF, SY, FZ + WALL / 2), (0.44, 2 * HALF, WALL))
    add_box(shack, (SX, back_y, FZ + WALL / 2), (2 * HALF, 0.44, WALL))
    side = (2 * HALF - DOORW) / 2
    for sgn in (-1.0, 1.0):
        add_box(shack, (SX + sgn * (DOORW / 2 + side / 2), front_y, FZ + WALL / 2), (side, 0.44, WALL))
    add_box(shack, (SX, front_y, FZ + DOORH + (WALL - DOORH) / 2), (DOORW, 0.44, WALL - DOORH))
    # Plank texture: three battens across the front and back.
    for k in range(3):
        add_box(shack, (SX, front_y - 0.30, FZ + 0.9 + k * 1.7), (2 * HALF, 0.14, 0.30))
        add_box(shack, (SX, back_y + 0.30, FZ + 0.9 + k * 1.7), (2 * HALF, 0.14, 0.30))

    # Corrugated tin roof, hipped, overhanging - and struck twice.
    first = len(shack.faces)
    add_cone(shack, (SX, SY, FZ + WALL), (HALF + 1.4) * 1.4142, 1.1, 2.1, sides=4, yaw=math.pi / 4)
    add_cone(shack, (SX, SY, FZ + WALL + 2.1), 1.1, 0.6, 0.30, sides=4, yaw=math.pi / 4)
    _load_paint(shack, first, 1)

    # Every chain and iron mesh Ansel owns, wrapped round the outside.
    first = len(shack.faces)
    corners = [
        (SX - HALF - 0.3, back_y + 0.3),
        (SX + HALF + 0.3, back_y + 0.3),
        (SX + HALF + 0.3, front_y - 0.3),
        (SX - HALF - 0.3, front_y - 0.3),
    ]
    for band_z in (FZ + 1.5, FZ + 3.1, FZ + 4.6):
        for k in range(4):
            a = corners[k]
            b = corners[(k + 1) % 4]
            _load_chain(shack, (a[0], a[1], band_z), (b[0], b[1], band_z), 4, 0.17, sag=0.30)
    # Iron mesh thrown over the roof.
    for k in range(3):
        t = (k / 2.0 - 0.5) * 2.0
        _load_chain(shack, (SX + t * HALF, SY - HALF - 1.0, FZ + WALL + 0.1),
                    (SX + t * HALF, SY + HALF + 1.0, FZ + WALL + 0.1), 4, 0.11, sag=-1.2)
        _load_chain(shack, (SX - HALF - 1.0, SY + t * HALF, FZ + WALL + 0.1),
                    (SX + HALF + 1.0, SY + t * HALF, FZ + WALL + 0.1), 4, 0.11, sag=-1.2)
    # The chain curtain in the doorway.
    for k in range(7):
        cx = SX - DOORW / 2 + 0.22 + k * (DOORW - 0.44) / 6
        _load_chain(shack, (cx, front_y, FZ + DOORH - 0.1), (cx, front_y, FZ + 0.2), 5, 0.12)
    # Earthing cables: one off each corner, over the plinth edge and down into
    # the sea. Routed on the bearing from the ISLAND centre, so all four run
    # DOWNHILL to open water instead of one burying itself inland.
    for k, (cxx, cyy) in enumerate(corners):
        a = math.atan2(cyy, cxx)
        mx, my = math.cos(a) * 12.5, math.sin(a) * 12.5
        ex, ey = math.cos(a) * 49.0, math.sin(a) * 49.0
        _load_chain(shack, (cxx, cyy, FZ + WALL + 0.4), (mx, my, _LOAD_PLINTH_TOP - 0.2), 6, 0.16, sag=0.9)
        _load_chain(shack, (mx, my, _LOAD_PLINTH_TOP - 0.2), (ex, ey, -2.8), 8, 0.15, sag=1.4)
    _load_paint(shack, first, 2)

    # Through the open door: the bed, up on glass insulators.
    add_box(shack, (SX + 1.4, SY + 1.6, FZ + 1.35), (3.6, 2.0, 0.34), yaw=0.0)
    add_box(shack, (SX + 1.4, SY + 2.5, FZ + 1.9), (3.6, 0.24, 0.9))
    first = len(shack.faces)
    for bx in (SX - 0.2, SX + 3.0):
        for by in (SY + 0.8, SY + 2.4):
            add_cone(shack, (bx, by, FZ + 0.05), 0.34, 0.26, 1.1, sides=8)
    _load_paint(shack, first, 3)

    # ---------------------------------------------------------------- compass board
    # Nailed to the wall beside the door: twelve compasses, every one of them
    # pointing somewhere else. Wall-mounted rather than free-standing, so it
    # sits flat against the boards and never encroaches on Ansel's pad.
    BX, BY, BZ = SX - 3.5, front_y - 0.30, FZ + 1.0
    add_box(compass, (BX, BY, BZ + 1.85), (4.6, 0.22, 3.9))
    for k in range(2):
        add_box(compass, (BX, BY - 0.14, BZ + 0.35 + k * 3.0), (4.6, 0.12, 0.20))
    for row in range(3):
        for col in range(4):
            cx = BX - 1.62 + col * 1.08
            cz = BZ + 0.75 + row * 1.10
            cy = BY - 0.11
            first = len(compass.faces)
            add_cone(compass, (cx, cy, cz), 0.44, 0.44, 0.14, sides=9, tilt=(1.5708, 0.0))  # brass case
            _load_paint(compass, first, 1)
            first = len(compass.faces)
            add_cone(compass, (cx, cy - 0.14, cz), 0.37, 0.37, 0.05, sides=9, tilt=(1.5708, 0.0))  # dial
            _load_paint(compass, first, 2)
            first = len(compass.faces)
            nphi = rng.uniform(0.0, math.tau)  # every needle points somewhere else
            nd = (math.sin(nphi), 0.0, math.cos(nphi))
            _load_seg(compass, (cx - nd[0] * 0.30, cy - 0.22, cz - nd[2] * 0.30),
                      (cx + nd[0] * 0.30, cy - 0.22, cz + nd[2] * 0.30), 0.06, 0.025, sides=4)
            _load_paint(compass, first, 3)

    # ---------------------------------------------------------------- heat + St Elmo
    # Orange heat still in the fresh seams up the struck faces.
    for tip, axis, h, r0, x0, y0, z0 in tips[:5]:
        for k in range(3):
            t = 0.10 + k * 0.19 + rng.uniform(-0.04, 0.04)
            a = rng.uniform(0.0, math.tau)
            rr = _load_spire_radius(t, r0) * 0.88
            px = x0 + axis[0] * h * t + math.cos(a) * rr
            py = y0 + axis[1] * h * t + math.sin(a) * rr
            add_box(glow, (px, py, z0 + axis[2] * h * t), (0.42, 0.22, rng.uniform(2.2, 5.0)), yaw=a)
    for cx, cy in ((14.0, 16.0), (-18.0, -12.5), (6.0, 26.5)):
        add_box(glow, (cx, cy, height_at(cx, cy) + 0.16), (2.2, 0.5, 0.16), yaw=rng.uniform(0, 3.1))

    # A violet St Elmo's fire crawling on the tips of the tallest needles. It
    # must HUG the needle - a cone wider than the tip reads as a party hat, so
    # every piece is a hair-thin tendril licking up off the last few studs of
    # rock, sized from the SAME profile function the needle was built with.
    for tip, axis, h, r0, x0, y0, z0 in tips[:4]:
        phi = math.acos(max(-1.0, min(1.0, axis[2])))
        psi = math.atan2(axis[1], axis[0])

        def on_axis(t_back, off_a=None, off_r=0.0):
            bx = tip[0] - axis[0] * t_back
            by = tip[1] - axis[1] * t_back
            bz = tip[2] - axis[2] * t_back
            if off_a is not None:
                bx += math.cos(off_a) * off_r
                by += math.sin(off_a) * off_r
            return (bx, by, bz)

        # the sheath over the last few studs, no wider than the rock it sits on
        add_cone(elmo, on_axis(3.0), _load_spire_radius(1.0 - 3.0 / h, r0) * 1.06, 0.04, 4.4,
                 sides=6, tilt=(0.0, phi), yaw=psi)
        # tendrils flicking off the point
        for k in range(5):
            a = k * math.tau / 5 + rng.uniform(-0.3, 0.3)
            back = rng.uniform(1.5, 5.0)
            rr = _load_spire_radius(1.0 - back / h, r0) * 0.9
            _load_seg(elmo, on_axis(back, a, rr * 0.6),
                      on_axis(back - rng.uniform(1.0, 2.6), a, rr * rng.uniform(1.6, 2.8)),
                      0.13, 0.02, sides=4)
    # And a bead of it on the useless rod, which is the whole joke.
    add_cone(elmo, (p[0], p[1], p[2] + 0.15), 0.22, 0.03, 0.9, sides=5)

    objects = [
        base,
        object_from_bmesh("Loadstone_Spires", spires, ["M_LoadGlass", "M_LoadVitrify"]),
        object_from_bmesh("Loadstone_Rubble", rubble, ["M_LoadRock", "M_LoadScorch", "M_LoadVitrify"]),
        object_from_bmesh("Loadstone_Fulgurite", fulg, ["M_LoadFulgurite", "M_LoadScorch"]),
        object_from_bmesh("Loadstone_Scrap", scrap, ["M_LoadIron", "M_LoadRust", "M_LoadGull"]),
        object_from_bmesh("Loadstone_Shack", shack, ["M_LoadPlank", "M_LoadRoof", "M_LoadIron", "M_LoadInsulator"]),
        object_from_bmesh("Loadstone_Compass", compass, ["M_LoadPlank", "M_LoadBrass", "M_LoadDial", "M_LoadNeedle"]),
        object_from_bmesh("Loadstone_Glow", glow, ["M_LoadHeat"]),
        object_from_bmesh("Loadstone_Elmo", elmo, ["M_LoadElmo"]),
    ]

    # The NPC pad: NpcService raycasts straight down here and stands Ansel on
    # whatever it hits, so the number below is a REAL raycast against the built
    # meshes (height_at is the smooth profile and disagrees with the plinth by
    # half a stud or more), and _load_reserved keeps every prop off it.
    stand_x, stand_y = _LOAD_PAD
    ground_y = _load_ground_y(objects, stand_x, stand_y)
    # Prove the pad is FLAT and prop-free, not just that its centre reads 4.27:
    # raycast a ring around it and report the worst deviation.
    worst = 0.0
    for rr in (0.8, 1.5, 2.2):
        for k in range(8):
            a = k * math.tau / 8
            hz = _load_ground_y(objects, stand_x + math.cos(a) * rr, stand_y + math.sin(a) * rr)
            if hz is not None:
                worst = max(worst, abs(hz - ground_y))
    print(f"[island_gen] loadstone pad: flat to {worst:.2f} studs out to r=2.2 (raycast ring; past that the roof eave overhangs, which is head clearance, not ground)")
    print(
        f"[island_gen] HANDOFF loadstone (The Loadstone Spire): tallest needle top Y={tips[0][0][2]:.1f}, "
        f"{len(CLUSTER)} spires; NPC stand (Roblox rel) X={stand_x:.1f} Z={-stand_y:.1f} "
        f"ground Y={ground_y:.2f} (raycast); radius 45"
    )
    random.setstate(state)
    return objects

ISLAND_ORDER = [
    "tropical",
    "volcano",
    "swamp",
    "ice",
    "gloom",
    "wreck",
    "maelstrom",
    # The islets (2026-08-29). APPENDED, never inserted: configure() does not
    # reset, so every island inherits the previous one's globals and putting a
    # new id mid-list would reseed every downstream island's scatter.
    "lampwork",
    "bellbuoy",
    "rookery",
    "chapel",
    "whalefall",
    "anchorage",
    "boilshoal",
    "ferryraft",
    "loadstone",
]

ISLANDS = {
    "tropical": {"model": "Island", "overrides": {}, "build": build_tropical},
    "volcano": {
        "model": "Volcano",
        # RESTART step 1 (2026-08-27; see build_volcano). Every shape key set
        # EXPLICITLY (the configure() no-reset rule): the tropical entry
        # builds first in the pack and its globals would otherwise leak in.
        # Radius stays 640 - the Roblox 2048-stud import cap.
        "overrides": {
            # SEED MUST STAY 7 (the global default): swamp/ice/gloom/wreck do
            # NOT set their own SEED, so they inherit whatever the volcano
            # leaves in the global - a different value here reseeds every
            # downstream island's random scatter (a6 caught wreck's keels
            # drifting -18.25 -> -18.93 from a draft that set 11). The bare
            # step-1 volcano draws no randomness at all (CRAG 0), so 7 costs
            # nothing. If a later volcano step wants its own stream, pin SEED
            # explicitly on swamp/ice/gloom/wreck FIRST.
            "SEED": 7,
            # 640 -> 660 (2026-08-28, user: "the island itself is just too
            # small... not much room to walk around"): the bbox was 1912 of
            # the 2048 import cap, so most of the new room comes from the
            # PROFILE below - the cone's footprint pulled in from u 0.70 to
            # 0.58 - and the radius takes the remaining safe headroom.
            "ISLAND_RADIUS": 660,
            "SEGMENTS": 96,  # finer facets so the shattered rock reads on 900-stud cliffs
            # One material boundary: bare volcanic rock cone above, ash apron
            # (the walked ground) below.
            "GRASS_U": 0.58,
            "RINGS": [0.0, 0.045, 0.10, 0.14, 0.175, 0.225, 0.28, 0.34, 0.40, 0.46, 0.52, 0.58, 0.68, 0.78, 0.88, 0.95, 1.0, 1.09, 1.28],
            # Round 3 (user: "too uniform... taller and more jagged... really
            # really really tall... the whole shape more randomized"): a ~895
            # summit lip (up to ~950 with the jag) over near-vertical craggy
            # flanks - the same towering proportions the pre-restart design
            # was approved at - dropping to the broad flat ash apron
            # (0.70-1.0, ~190 studs of walked ring). Randomness comes from
            # THREE stacked systems, all over the WHOLE mountain, not just
            # the rim: CRAG (broad noise ribs over the full flank band,
            # u 0.22-0.92), CRAG_RADIAL (the plan outline wobbles per ring,
            # so the silhouette wanders at every height), and PEAK_JAG (the
            # upper cone's ridgeline rises/falls per angle).
            # The 2026-08-28 "more room to walk" re-key: same 895 summit,
            # same silhouette, but the whole cone compressed into u <= 0.58
            # (its true footprint barely changes - the RADII up top were kept
            # near-identical by picking smaller u on a bigger R) so the flat
            # walkable apron runs 0.58-1.0: ~230 studs wide at the spawn
            # bearing, ~1.6-1.7x the old ground area.
            "PROFILE": [
                (0.000, 830.0),  # crater dish floor
                (0.045, 836.0),
                (0.100, 852.0),  # inner crater wall
                (0.140, 895.0),  # the summit lip
                (0.175, 812.0),  # near-vertical under the lip
                (0.225, 655.0),
                (0.280, 492.0),
                (0.340, 338.0),
                (0.400, 225.0),
                (0.460, 135.0),
                (0.520, 68.0),
                (0.580, 30.0),  # cone meets the ash apron
                (0.680, 12.0),
                (0.780, 6.0),
                (0.880, 3.2),
                (0.950, 1.7),
                (1.000, 1.0),  # shore: ~0.5 studs per 10, the tide band
                (1.090, -1.8),
                (1.280, SKIRT_BOTTOM),
            ],
            # Strongly irregular outline + apron boundary.
            "COAST_TERMS": [(2, 1.0, 0.12), (3, 3.0, 0.09), (5, 0.5, 0.07), (8, 2.0, 0.06)],
            "GRASS_TERMS": [(2, 0.9, 0.06), (4, 1.5, 0.05)],
            # Heavy broad crag over the whole flank; the apron stays level
            # (RIM_FLAT fades it across the walked ground only).
            "CRAG": 68.0,
            "CRAG_FREQ": 0.016,  # broad shattered ribs, scaled to a 900-stud mountain
            "CRAG_RADIAL": 0.13,  # the outline wanders hard at every height...
            # ...and the wobble's frequencies are cranked (angular 6 -> 13,
            # height 4 -> 18) so spurs and gullies alternate around the cone
            # AND the wander CHANGES as you climb: bulges, set-back ledges,
            # no two heights alike - the whole shape randomized, per the user.
            "CRAG_RADIAL_FREQS": (13.0, 18.0),
            "CRAG_CALM": None,
            "RIM_FLAT": (0.60, 1.0),
            # Step 2's six rim gashes - one per lava river, mirroring
            # LAVA_FLOWS by hand (bearing, half-width, depth; keep the two
            # lists in step). Depths drop the 895 lip below the 842 lake so
            # every river genuinely pours; peak_jag zeroes itself inside
            # each window so a jagged ridge can't seal a gash.
            "NOTCHES": [
                (math.radians(318), math.radians(9), 66.0),
                (math.radians(5), math.radians(8), 62.0),
                (math.radians(48), math.radians(13), 78.0),  # the main breach
                (math.radians(100), math.radians(10), 70.0),
                (math.radians(152), math.radians(8), 64.0),
                (math.radians(205), math.radians(11), 72.0),
            ],
            "NOTCH_BAND": (0.075, 0.16),  # the summit lip band (lip at u 0.14)
            # The broken asymmetric ridgeline around the summit.
            "PEAK_JAG": 28.0,
            "PEAK_TERMS": [(2, 0.8, 0.45), (3, 2.6, 0.35), (5, 1.1, 0.20)],
            # Step 5: THE DOCK - the tropical island's dock verbatim (same
            # shared build_dock, same dimensions, same warm wood), run out
            # on the lava-free 270-deg lane (Roblox +Z): planks start on the
            # dry ash just past the spawn and reach ~37 studs over open sea,
            # so the volcano fishes the OCEAN off its dock exactly like home.
            "DOCK_ANGLE_DEG": 270,
            "DOCK_START_U": 0.97,
            "DOCK_LENGTH": 52.0,
            "DOCK_WIDTH": 10.0,
            "DOCK_END_LENGTH": 13.0,
            "DOCK_END_WIDTH": 18.0,
            "DOCK_MIN_TOP": 2.4,
            "DOCK_POST_SPACING": 7.0,
            "DOCK_POST_BOTTOM": -6.0,
            "PREVIEW_SHOTS": [
                # Standing on the apron at the old spawn side, craning up at
                # the mountain; and the sail-in from the +Z sea (the dock in
                # the foreground).
                ("apron", (120.0, -620.0, 26.0), (-300.0, -420.0, 45.0), 30),
                ("approach", (0.0, -1500.0, 60.0), (0.0, 0.0, 420.0), 30),
            ],
            "COLORS": {
                # Step 1 keeps the real volcanic palette (the swamp restart
                # went grey first, then colored in step 2 - collapsing the two
                # here since the bands are proven). Prop materials return with
                # their steps.
                "M_VolRock": (0.169, 0.161, 0.188),
                "M_VolAsh": (0.310, 0.278, 0.278),
                "M_VolWet": (0.200, 0.188, 0.212),
                "M_Lava": (1.000, 0.420, 0.059),  # molten orange (Neon in-game)
                "M_Charred": (0.102, 0.086, 0.078),  # burnt-black dead giants
                "M_Obsidian": (0.090, 0.090, 0.122),  # the rock masses
                "M_VolPlank": (0.690, 0.490, 0.290),  # the tropical dock's wood, verbatim
                "M_VolPost": (0.455, 0.310, 0.190),
                "M_VolFoam": (0.851, 0.851, 0.890),  # ash-tinged surf line
                # Brakk's forge-hold (step 7): dressed basalt, slate roof,
                # black iron, worked brass, and the magma running through it.
                "M_ForgeBasalt": (0.208, 0.196, 0.216),
                "M_ForgeSlate": (0.145, 0.141, 0.157),
                "M_ForgeIron": (0.267, 0.271, 0.290),
                "M_ForgeBrass": (0.678, 0.549, 0.278),
                "M_ForgeEmber": (1.000, 0.451, 0.086),
            },
        },
        "build": build_volcano,
    },
    # ---- Blackmire Fen (revamp island 2). RESTARTED FROM SCRATCH
    # (2026-08-27, user) - see build_swamp. STEP 1: a bare grey landform,
    # nothing else. A low, gently domed island with a lobed coastline; the
    # shore slope stays shallow so the tide will read once the island gets
    # its materials back. Every crag/notch/peak key is explicitly zeroed
    # because configure() does NOT reset between pack islands and the
    # volcano builds right before this one.
    "swamp": {
        "model": "Swamp",
        "overrides": {
            "ISLAND_RADIUS": 180,
            # Dense enough that the marsh's wandering water/land boundary
            # resolves smoothly (~3.6-stud radial spacing interior, ~4 studs
            # angular at the marsh edge) - the v2 mesh was half this and the
            # islet edges read as pixelated stair-steps.
            "SEGMENTS": 176,
            # The peat runs almost to the coast (user, marsh review: "the
            # brown [should be] more near the coastline") - the mud band is
            # a thin coastal fringe now, not a fat ring.
            "GRASS_U": 0.88,
            "RINGS": [
                0.0, 0.02, 0.04, 0.06, 0.08, 0.10, 0.12, 0.14, 0.16, 0.18,
                0.20, 0.22, 0.24, 0.26, 0.28, 0.30, 0.32, 0.34, 0.36, 0.38,
                0.40, 0.42, 0.44, 0.46, 0.48, 0.50, 0.52, 0.54, 0.56, 0.58,
                0.60, 0.62, 0.64, 0.66, 0.68, 0.70, 0.72, 0.74, 0.76, 0.78,
                0.80, 0.82, 0.86, 0.90, 0.94, 0.97, 1.0, 1.09, 1.28,
            ],
            # A gentle dome: ~7 studs at the heart easing to the standard
            # shallow shoreline, then the shared underwater skirt.
            "PROFILE": [
                # FLAT by design (user, step-2 review: "remove the height...
                # it should be flat so itll be easy to add the marsh") - the
                # tall dome experiment is reverted. Barely any rise, like the
                # pre-restart fen: a level ~4.6-stud interior the marsh step
                # can flood with standing water, easing to the same shallow
                # shoreline so the tide reads.
                (0.00, 4.8),
                (0.30, 4.7),
                (0.55, 4.6),
                (0.72, 4.2),
                (0.84, 3.0),
                (0.93, 1.4),
                (1.00, 0.6),
                (1.09, -1.8),
                (1.28, SKIRT_BOTTOM),
            ],
            # A softly lobed coast - organic, but nothing extreme.
            "COAST_TERMS": [(2, 0.7, 0.10), (3, 2.9, 0.08), (5, 1.6, 0.06)],
            # The peat/mud boundary wanders HARD (user: the green circle was
            # "too uniform... more randomly curved") - four terms, fingers
            # of green reaching into the mud and back.
            "GRASS_TERMS": [(2, 1.1, 0.12), (3, 2.3, 0.10), (5, 0.9, 0.065), (8, 4.1, 0.04)],
            # Neutralize the volcano's carry-over (pack build order).
            "CRAG": 0.0,
            "CRAG_RADIAL": 0.0,
            "CRAG_CALM": None,
            "NOTCHES": [],
            "NOTCH_BAND": None,
            "RIM_FLAT": None,
            "PEAK_JAG": 0.0,
            "PEAK_TERMS": [],
            # STEP 2 (user): color returns. The proven fen palette from the
            # pre-restart island - dark waterlogged moss-peat interior, a mud
            # "beach" band outside GRASS_U, wet mud at the waterline. Keep
            # WorldService.MESH_COLOR's Swamp_Base entries in step with these.
            "COLORS": {
                "M_Peat": (0.243, 0.322, 0.204),
                "M_Mud": (0.396, 0.333, 0.235),
                "M_WetMud": (0.290, 0.247, 0.184),
                # Opaque murk - you can't see what's biting (in-game the part
                # wears the ocean's dress via Ocean.INTERIOR_WATER_NAMES; this
                # is the preview color).
                "M_SwampWater": (0.153, 0.239, 0.196),
                "M_Cattail": (0.478, 0.525, 0.259),  # dusty reed green
                "M_CattailHead": (0.369, 0.243, 0.137),  # the brown seed heads
                "M_Lily": (0.451, 0.643, 0.318),  # lily pads: the fen's colour pop
                "M_LilyBloom": (0.88, 0.62, 0.75),  # the occasional pale-pink flower
                "M_RootWood": (0.259, 0.208, 0.157),  # sunken logs + cypress knees
                "M_BogStone": (0.353, 0.365, 0.333),  # mossy bog stones
                "M_Mushroom": (0.78, 0.46, 0.28),  # toadstool clusters (colour pop)
                "M_SwampFoam": (0.851, 0.878, 0.831),  # scummy pale rim, not white surf
                "M_TrunkWood": (0.55, 0.42, 0.30),  # smooth tan trunks (the reference look)
                "M_WillowLeaf": (0.20, 0.26, 0.17),  # the canopy masses
                "M_HangMoss": (0.451, 0.514, 0.365),  # pale spanish-moss ribbons
                "M_Vine": (0.20, 0.27, 0.17),  # long dark vines reaching down
                # Morra's leaning bog hut (build_hut_morra). Bogwood and wattle
                # for the shell, a dark mossy shingle for its scaled roof, and
                # the witch-dressing: herbs, bone, jars, iron, wisp-light.
                "M_BogWattle": (0.322, 0.278, 0.212),  # the woven wattle shell
                "M_BogShingle": (0.239, 0.290, 0.216),  # scale shingles, moss-dark
                "M_BogHerb": (0.482, 0.510, 0.302),  # hanging herb bundles + cot straw
                "M_BogBone": (0.827, 0.812, 0.706),  # gator skull, chime bones and shells
                "M_BogJar": (0.400, 0.549, 0.451),  # the leech jars
                "M_BogIron": (0.169, 0.176, 0.196),  # the cauldron
                "M_Wisp": (0.545, 0.949, 0.729),  # wisp-lanterns, potions, scrying water
            },
        },
        "build": build_swamp,
    },
    # ---- Frostmaw Reach (revamp island 3). A BLUNT glacial island: a flat
    # white ice sheet stepped up in two broad terraces to a rolled berg massif,
    # walled round most of its coast by stacked glacial cliffs, with an ice
    # arch out on the field, clusters of stubby teal crystals, snowy pines and
    # hundreds of flat ice floes littering the ground. CRAG is 0 - nothing on
    # this island is jagged; the steps come from the PROFILE and from chunky
    # terrace slab geometry. NOTCHES carve the frozen channel (a broad shallow
    # trough, not a chasm) that most of the fishing holes are strung along.
    "ice": {
        "model": "Frostmaw",
        "overrides": {
            # PINNED LEAK (2026-08-27): the shipped ice/gloom/wreck meshes
            # were built with the VOLCANO's peak-jag/crag-calm still in the
            # globals - the old swamp never reset them, so every downstream
            # island inherited them through the pack build order. The swamp
            # restart zeroes them for its own build, so they are pinned HERE
            # (gloom and wreck don't set them and inherit these) to keep the
            # three approved islands byte-identical. Verified by mesh-bottom
            # HANDOFF: gloom is -16.53 with these, -15.28 without.
            "PEAK_JAG": 16.0,
            "PEAK_TERMS": [(2, 0.8, 0.45), (3, 2.6, 0.35), (5, 1.1, 0.20)],
            "CRAG_CALM": (math.radians(270), math.radians(52), 0.50),
            "ISLAND_RADIUS": 230,
            "SEGMENTS": 72,
            "GRASS_U": 0.52,  # the snow/ice-sheet material break sits ON the second terrace lip
            "RINGS": [0.0, 0.14, 0.30, 0.325, 0.42, 0.50, 0.52, 0.60, 0.66, 0.685, 0.78, 0.86, 0.93, 1.0, 1.09, 1.28],
            # Flat plateaus joined by short steep risers: a terraced glacier,
            # not a cone. Ring pairs straddle each riser so the step is crisp.
            "PROFILE": [
                (0.00, 34.0),  # the upper snow plateau - the massif's seat
                (0.14, 33.2),
                (0.30, 32.2),  # terrace 1 lip
                (0.325, 22.0),  # riser
                (0.42, 21.6),
                (0.50, 21.0),  # terrace 2 lip
                (0.52, 13.6),  # riser -> lands exactly on the snow/ice material break
                (0.60, 13.2),
                (0.66, 12.6),  # terrace 3 lip
                (0.685, 8.4),  # riser -> the big walked ice sheet
                (0.78, 8.1),
                (0.86, 7.4),  # the spawn shelf band (rel Z~174) - flat
                (0.93, 5.0),
                (1.00, 1.0),
                (1.09, -1.8),
                (1.28, SKIRT_BOTTOM),
            ],
            # Long soft-lobed berg coast: broad faces, no fine crenellation.
            "COAST_TERMS": [(2, 0.4, 0.10), (3, 1.9, 0.07), (7, 3.3, 0.05)],
            "GRASS_TERMS": [(2, 0.6, 0.05), (5, 1.4, 0.03)],
            # NOTHING is craggy on Frostmaw. The whole landform is flat steps.
            "CRAG": 0.0,
            "CRAG_FREQ": 0.03,
            "CRAG_RADIAL": 0.0,
            "RIM_FLAT": (0.52, 1.0),
            # The frozen channel: two broad shallow troughs across the sheet
            # (depth in studs), well clear of the dock bearing at 270.
            "NOTCH_BAND": (0.60, 0.91),
            "NOTCHES": [
                (math.radians(40.0), 0.40, 5.4),
                (math.radians(126.0), 0.30, 4.2),
            ],
            "DOCK_ANGLE_DEG": 270,
            "DOCK_START_U": 0.92,
            "DOCK_LENGTH": 46.0,
            "DOCK_WIDTH": 10.0,
            "DOCK_END_LENGTH": 14.0,
            "DOCK_END_WIDTH": 20.0,
            "DOCK_MIN_TOP": 2.4,
            "DOCK_POST_SPACING": 7.5,
            "DOCK_POST_BOTTOM": -6.0,
            # Near-white snow, pale blue-cast ice, three ice blues stepping
            # down for terraces -> berg -> arch -> cliffs, minty teal crystals.
            "COLORS": {
                "M_Snow": (0.961, 0.973, 0.984),  # the upper snow plateaus
                "M_IceSheet": (0.898, 0.937, 0.980),  # the walked (and fished) sheet
                "M_IceWet": (0.729, 0.827, 0.914),
                "M_IceWater": (0.071, 0.129, 0.216),  # the black-blue water in the holes
                "M_IceStep": (0.847, 0.906, 0.961),  # terrace lips + stepped mesas
                "M_BergIce": (0.714, 0.839, 0.945),  # the massif
                "M_ArchIce": (0.588, 0.765, 0.910),  # the ice arches
                "M_GlacialIce": (0.478, 0.678, 0.882),  # the coastal cliff walls (deepest blue)
                "M_IceCrystal": (0.478, 0.855, 0.843),  # minty teal crystal clusters
                "M_IceShard": (0.929, 0.961, 0.988),  # the flat floe litter
                "M_SnowCap": (0.961, 0.973, 0.988),  # every snow stratum on berg/walls/arches
                "M_SnowMound": (0.965, 0.976, 0.988),
                "M_PineSnow": (0.965, 0.976, 0.984),  # snow-laden pine skirts
                "M_PineNeedle": (0.353, 0.549, 0.400),  # the green lip under each skirt
                "M_FrostWood": (0.290, 0.243, 0.220),  # warm dark trunks / dead trees
                "M_FrostPlank": (0.557, 0.478, 0.376),
                "M_FrostPost": (0.404, 0.337, 0.263),
                "M_FrostFoam": (0.949, 0.969, 0.984),
                # Halvard's upturned hull: tarred boat timber, cut snow block,
                # black iron, sea-bleached bone, and the stove's ember.
                "M_HutHull": (0.325, 0.243, 0.196),
                "M_HutSnowBlock": (0.882, 0.918, 0.949),
                "M_FrostIron": (0.204, 0.200, 0.212),
                "M_HutBone": (0.855, 0.839, 0.788),
                "M_FrostEmber": (1.000, 0.510, 0.157),
            },
        },
        "build": build_frostmaw,
    },
    # ---- Gloomtrench (revamp island 5). The lip of an abyssal trench hauled
    # above the waterline: near-black basalt shelves, lightless pools
    # (Gloomtrench_DarkWater, the "gloom" surface), and the bioluminescence
    # that is the island's whole identity - lantern stalks, glow anemones,
    # violet kelp. The glow objects are flat bright colours in the mesh; if a
    # Neon override is wanted later it's one WorldService MESH_MATERIAL entry.
    "gloom": {
        "model": "Gloomtrench",
        "overrides": {
            "ISLAND_RADIUS": 200,
            "SEGMENTS": 72,
            # The material break sits exactly on the crown lip: near-black
            # basalt fills the amphitheatre, the ashen violet-grey shore wraps
            # the outer apron, so the rim reads as a hard tonal edge.
            "GRASS_U": 0.56,
            # Every ring is a terrace tread or a riser edge, so the steps land
            # on mesh rings and the contours stay crisp, never stair-stepped.
            "RINGS": [0.0, 0.14, 0.215, 0.245, 0.30, 0.325, 0.39, 0.415, 0.47, 0.495, 0.56, 0.62, 0.68, 0.74, 0.80, 0.88, 0.96, 1.0, 1.09, 1.28],
            # The amphitheatre: a pit sunk BELOW the waterline (so the dark
            # water pools at sea level), three terraces stepping up out of it,
            # a high crown ring, then a wide apron falling away to the dock.
            "PROFILE": [
                (0.000, -6.4),  # lake floor, under the water sheet
                (0.140, -5.4),
                (0.215, 0.5),  # the bank climbs out of the dark water
                (0.245, 2.6),
                (0.300, 3.0),  # terrace A tread - the fishing shore
                (0.325, 10.0),  # riser
                (0.390, 10.6),  # terrace B tread
                (0.415, 17.6),  # riser
                (0.470, 18.2),  # terrace C tread
                (0.495, 25.4),  # riser
                (0.560, 26.2),  # the crown - the silhouette off the sea
                (0.620, 19.0),
                (0.680, 11.0),
                (0.740, 5.2),
                (0.800, 3.0),  # the apron: spawn + boss ground
                (0.880, 2.1),
                (0.960, 1.2),
                (1.000, 0.7),
                (1.090, -1.8),
                (1.280, SKIRT_BOTTOM),
            ],
            "COAST_TERMS": [(2, 1.7, 0.11), (4, 0.6, 0.08), (6, 2.8, 0.06)],
            "GRASS_TERMS": [(3, 0.8, 0.05)],
            # Enough crag to break the lathe rings into broken rock, not so
            # much that it eats the terrace risers.
            "CRAG": 1.7,
            "CRAG_FREQ": 0.030,
            "CRAG_RADIAL": 0.05,
            "RIM_FLAT": (0.66, 0.96),  # apron + shore stay level: spawn, dock, boss
            "DOCK_ANGLE_DEG": 270,
            "DOCK_START_U": 0.907,
            "DOCK_LENGTH": 44.0,
            "DOCK_WIDTH": 10.0,
            "DOCK_END_LENGTH": 13.0,
            "DOCK_END_WIDTH": 20.0,
            "DOCK_MIN_TOP": 2.4,
            "DOCK_POST_SPACING": 7.0,
            "DOCK_POST_BOTTOM": -6.0,
            "COLORS": {
                "M_GloomRock": (0.110, 0.106, 0.145),  # near-black basalt
                "M_GloomShelf": (0.078, 0.082, 0.118),  # wet tide-pool shelf / sea stacks
                "M_GloomRift": (0.145, 0.133, 0.180),  # the rift's torn wall slabs
                "M_GloomSand": (0.243, 0.231, 0.298),  # ashen violet-grey shore
                "M_GloomWet": (0.157, 0.153, 0.204),
                "M_DarkWater": (0.024, 0.043, 0.086),  # all but black
                "M_GloomStalk": (0.231, 0.243, 0.298),
                "M_GloomPath": (0.365, 0.353, 0.443),  # pale flagstones - the route
                "M_GlowCyan": (0.290, 0.937, 0.878),  # mushroom caps / anemones
                "M_GlowViolet": (0.663, 0.416, 0.937),  # crystal shards / veins
                "M_GloomPlank": (0.278, 0.259, 0.322),
                "M_GloomPost": (0.196, 0.180, 0.235),
                "M_GloomFoam": (0.671, 0.702, 0.780),
            },
        },
        "build": build_gloomtrench,
    },
    # ---- Wreckwater (revamp island 6). A drowned lagoon ringed by a grassy
    # grave-rim: the bay (Wreckwater_Bay, the "wreck" surface) fills the
    # sunken bowl, foundered hulks stand half out of it, and a notch in the
    # rim opens the harbor mouth toward the dock so the lagoon reads as open
    # to the sea. Ghost ships carry a pale gunwale glow.
    "wreck": {
        "model": "Wreckwater",
        "overrides": {
            "ISLAND_RADIUS": 210,
            "SEGMENTS": 72,
            "GRASS_U": 0.62,
            "RINGS": [0.0, 0.12, 0.24, 0.34, 0.42, 0.52, 0.62, 0.75, 0.85, 0.93, 1.0, 1.09, 1.28],
            "PROFILE": [
                (0.00, -5.5),  # the drowned bowl
                (0.24, -4.6),
                (0.34, -2.8),
                (0.42, -0.8),
                (0.52, 3.2),  # the rim rises
                (0.62, 4.6),
                (0.75, 3.2),
                (0.85, 1.9),
                (0.93, 1.2),
                (1.00, 0.7),
                (1.09, -1.8),
                (1.28, SKIRT_BOTTOM),
            ],
            "COAST_TERMS": [(2, 2.1, 0.12), (3, 0.3, 0.08), (5, 1.8, 0.06)],
            "GRASS_TERMS": [(2, 1.5, 0.05), (4, 0.2, 0.04)],
            # The harbor mouth: one notch carved through the rim on the dock
            # side, deep enough to drop the 4.6-stud rim below the waterline.
            "NOTCH_BAND": (0.42, 0.75),
            "NOTCHES": [(math.radians(270), math.radians(8), 8.5)],
            "DOCK_ANGLE_DEG": 270,
            "DOCK_START_U": 0.90,
            "DOCK_LENGTH": 46.0,
            "DOCK_WIDTH": 10.0,
            "DOCK_END_LENGTH": 14.0,
            "DOCK_END_WIDTH": 20.0,
            "DOCK_MIN_TOP": 2.4,
            "DOCK_POST_SPACING": 7.0,
            "DOCK_POST_BOTTOM": -6.0,
            "COLORS": {
                "M_BayFloor": (0.235, 0.243, 0.235),  # drowned grey-green silt
                "M_WreckSand": (0.741, 0.706, 0.612),  # bone-grey sand
            "M_WreckDrift": (0.647, 0.604, 0.514),  # the drifted dune ridges, a shade deeper
                "M_WreckWet": (0.518, 0.494, 0.427),
                "M_BayWater": (0.086, 0.196, 0.216),  # deep still teal
                "M_HullWood": (0.196, 0.157, 0.125),  # rotten black-brown timbers
                "M_GhostGlow": (0.678, 0.945, 0.769),  # the pale sea-fire on the ghost ships
            "M_WreckSail": (0.741, 0.745, 0.702),  # rotted canvas, bone with a green cast
                "M_GraveRock": (0.286, 0.298, 0.325),
                "M_WreckGrass": (0.443, 0.502, 0.373),  # dull sage rim grass
                "M_WreckPlank": (0.475, 0.404, 0.310),
                "M_WreckPost": (0.329, 0.271, 0.204),
                "M_WreckFoam": (0.882, 0.906, 0.894),
                "M_WreckIron": (0.216, 0.196, 0.180),  # rusted anchor iron / mooring chain
            },
        },
        "build": build_wreckwater,
    },
    # ---- The Maelstrom (finale site). A drowned storm-shoal, NOT a landmass:
    # the whole base sits below the waterline and everything walkable is a
    # basalt stack (see the maelstrom section's contract comment). Builds
    # LAST in the pack, and - per the configure() no-reset rule (context.md,
    # "The swamp restart") - sets EVERY shape key it cares about explicitly,
    # so nothing leaks in from wreck's override set.
    "maelstrom": {
        "model": "Maelstrom",
        "overrides": {
            "SEED": 46,
            "ISLAND_RADIUS": 240,
            "SEGMENTS": 64,
            "GRASS_U": 0.42,
            "RINGS": [0.0, 0.14, 0.27, 0.315, 0.42, 0.54, 0.66, 0.78, 0.90, 1.0, 1.09, 1.28],
            # All UNDERWATER: a vortex bowl under the whirlpool disc (u<0.31 ~
            # r<75), a dish lip, then a dark shallows shelf falling away to
            # the skirt. Max height -2.6, so the base never breaks the surface.
            "PROFILE": [
                (0.000, -8.6),  # the vortex bowl floor
                (0.140, -8.2),
                (0.270, -7.0),  # bowl wall
                (0.315, -3.4),  # dish lip, just under the whirlpool's edge
                (0.420, -2.6),  # the shoal shelf the stacks stand on
                (0.540, -2.9),
                (0.660, -3.6),
                (0.780, -4.4),
                (0.900, -5.4),
                (1.000, -6.2),
                (1.090, -7.2),
                (1.280, SKIRT_BOTTOM),
            ],
            "COAST_TERMS": [(2, 0.8, 0.10), (3, 2.2, 0.07), (7, 1.1, 0.05)],
            "GRASS_TERMS": [(3, 1.2, 0.05)],
            "CRAG": 1.4,
            "CRAG_FREQ": 0.05,
            "CRAG_RADIAL": 0.04,
            "CRAG_CALM": None,
            "RIM_FLAT": None,
            "NOTCHES": [],
            "NOTCH_BAND": None,
            "PEAK_JAG": 0.0,
            "PEAK_TERMS": [],
            # The overview cam sits low over a flat site; these two show what
            # matters: the arena from the spawn stack, and the sail-in down
            # the clear 270-deg lane (Blender -y = Roblox +Z, home's bearing).
            "PREVIEW_SHOTS": [
                ("arena", (0.0, -75.0, 18.0), (0.0, 20.0, 0.0), 24),
                ("approach", (0.0, -320.0, 18.0), (0.0, 0.0, 6.0), 30),
            ],
            "COLORS": {
                "M_StormFloor": (0.100, 0.110, 0.160),  # vortex bowl / inner shoal
                "M_StormShoal": (0.160, 0.180, 0.240),  # the pale mid-shelf band
                "M_StormWet": (0.128, 0.140, 0.190),
                "M_StormRock": (0.180, 0.188, 0.235),  # platform basalt (the procedural stacks' grey-blue)
                "M_StormSpire": (0.130, 0.132, 0.180),  # darker teeth
                "M_DoomWood": (0.137, 0.110, 0.098),  # storm-blackened timbers
                "M_DoomSail": (0.545, 0.565, 0.600),  # rain-grey tattered canvas
                "M_StormIron": (0.088, 0.090, 0.110),  # the great chains
                "M_StormDebris": (0.200, 0.163, 0.122),  # paler drift wood
                "M_StormGlow": (0.420, 0.940, 1.000),  # electric storm-fire (Neon in-game)
            },
        },
        "build": build_maelstrom,
    },
    # ---- LAMPWORK, the Lampwright's Workshop (quest islet; world
    # (13100, -1200), r 55). See build_islet_lampwork. APPENDED at the END of
    # ISLAND_ORDER, never inserted: configure() does NOT reset, so an islet
    # dropped mid-list would reseed every downstream island's scatter (the
    # volcano entry's SEED note). For the same reason EVERY shape key this
    # islet cares about is pinned here explicitly - maelstrom builds just
    # before it and would otherwise leak its SEED 46, its drowned PROFILE and
    # its crag settings straight in. SEED goes back to the module default 7,
    # which is what a standalone `-- out.glb lampwork` build gets, so this
    # islet is byte-identical alone and in the pack - and so is anything a
    # later islet appends after it.
    "bellbuoy": {
        "model": "Bellbuoy",
        "overrides": {
            "SEED": 7,
            # The radial base is NOT the islet any more - it is the SEABED the
            # wedge is driven into. Nothing in this profile breaks the surface;
            # every visible stud of the Bellbuoy is bmesh built in the builder.
            "ISLAND_RADIUS": 34,
            "SEGMENTS": 40,
            "GRASS_U": 0.60,
            "RINGS": [0.0, 0.16, 0.34, 0.52, 0.70, 0.86, 1.0, 1.14, 1.28],
            "PROFILE": [
                (0.00, -2.2),  # the shoal round the wedge's foot, always drowned
                (0.16, -2.4),
                (0.34, -2.8),
                (0.52, -3.4),
                (0.70, -4.2),
                (0.86, -5.4),
                (1.00, -6.6),
                (1.14, -7.9),
                (1.28, SKIRT_BOTTOM),  # the standard -9 skirt, and the islet's floor
            ],
            "COAST_TERMS": [(2, 1.6, 0.16), (3, 0.9, 0.10)],
            "GRASS_TERMS": [(3, 0.8, 0.05)],
            "CRAG": 0.9,
            "CRAG_FREQ": 0.09,
            "CRAG_RADIAL": 0.06,
            "CRAG_RADIAL_FREQS": (5.0, 3.0),
            "CRAG_CALM": None,
            "RIM_FLAT": None,
            "NOTCHES": [],
            "NOTCH_BAND": None,
            "PEAK_JAG": 0.0,
            "PEAK_TERMS": [],
            "PREVIEW_SHOTS": [
                # Straight up the cleft from the lee: the dinghy, then the bell
                # hanging in the slot, then the cliff standing behind it.
                ("cleft", (56.0, -4.1, 11.5), (-12.0, -4.1, 6.5), 44),
                # The bell itself, three-quarter, down in the gap.
                ("bell", (19.0, -33.0, 20.0), (-8.0, -4.1, 7.2), 46),
                # A grazing shot along the waterline: the barnacle banding.
                ("tideline", (24.0, -34.0, 3.6), (-6.0, -13.0, 1.4), 50),
                # The hut, seen from off the transom door where Nettle stands.
                ("hut", (35.0, 17.0, 12.5), (16.4, -2.6, 4.2), 40),
                # And the weather face, so the wedge reads as a wedge.
                ("cliff", (-62.0, -36.0, 17.0), (-10.0, -4.0, 6.0), 36),
            ],
            "COLORS": {
                # The seabed: drowned, so it stays dark and never competes.
                "M_BellRock": (0.200, 0.212, 0.228),
                "M_BellSplash": (0.298, 0.306, 0.300),
                "M_BellWet": (0.128, 0.148, 0.168),
                # The wedge, banded by height - this trio IS the tideline.
                "M_BellBasalt": (0.352, 0.333, 0.310),  # dry, sun-baked basalt
                "M_BellSalt": (0.424, 0.386, 0.334),  # the bleached splash zone
                "M_BellSoak": (0.152, 0.166, 0.172),  # soaked, below the tide
                "M_BellCrust": (0.735, 0.690, 0.600),  # barnacle
                "M_BellMussel": (0.115, 0.100, 0.135),
                "M_BellKelp": (0.230, 0.255, 0.130),
                "M_BellPool": (0.180, 0.470, 0.470),  # still water in the rock pools
                # Weathered, unpolished: verdigris over old bronze, so the bell
                # reads as something that has hung here a very long time.
                "M_BellBronze": (0.372, 0.470, 0.398),
                # The sound bow only: the clapper strikes here every swell, so
                # the verdigris never takes and the lip stays struck bronze.
                "M_BellLip": (0.596, 0.494, 0.278),
                "M_BellIron": (0.218, 0.222, 0.238),
                # This is a navigation mark: the gantry carries signal paint.
                "M_BellRed": (0.560, 0.155, 0.145),
                "M_BellWhite": (0.800, 0.790, 0.755),
                "M_BellTar": (0.142, 0.136, 0.132),  # the dinghy, tarred black
                "M_BellPlank": (0.400, 0.325, 0.235),
                "M_BellRope": (0.545, 0.460, 0.320),
                "M_BellCork": (0.660, 0.470, 0.270),
                "M_BellNet": (0.330, 0.360, 0.300),
                "M_BellTally": (0.085, 0.080, 0.075),
                "M_BellLamp": (1.000, 0.880, 0.560),  # Neon at runtime
            },
        },
        "build": build_islet_bellbuoy,
    },
    "rookery": {
        "model": "Rookery",
        "overrides": {
            "SEED": 7,
            # A STACK is TALL AGAINST ITS FOOTPRINT. The first pass ran 34 studs
            # high on a 50-stud radius and rendered as a broad dome - a hill
            # with birds on it. Half the radius, half again the height: now it
            # stands up out of the water like a column.
            "ISLAND_RADIUS": 32,
            "SEGMENTS": 34,
            "GRASS_U": 0.72,
            "RINGS": [0.0, 0.12, 0.24, 0.36, 0.48, 0.58, 0.68, 0.78, 0.88, 0.96, 1.0, 1.09, 1.28],
            # STEPPED, not a smooth fall: the pairs alternate tread / riser, so
            # the silhouette is terraced. Round 1 already meant this, but its
            # treads still shed 1.5 studs across their width and CRAG 2.2 then
            # smeared what was left - the stack rendered as a plain cone. The
            # treads are near-dead-level now (0.6 across the step) and the
            # risers take the whole drop, which is what the built terraces in
            # ROOK_TERRACES key off.
            "PROFILE": [
                (0.00, 54.0),
                (0.12, 53.4),  # crown tread
                (0.24, 44.6),  # riser
                (0.36, 44.0),  # tread -> terrace A
                (0.48, 34.2),  # riser
                (0.58, 33.6),  # tread -> terrace B (Pip's)
                (0.68, 22.4),  # riser
                (0.78, 21.8),  # tread -> terrace C
                (0.88, 9.0),  # riser into the splash zone
                (0.96, 3.0),
                (1.00, 1.0),
                (1.09, -2.2),
                (1.28, SKIRT_BOTTOM),
            ],
            "COAST_TERMS": [(2, 2.2, 0.12), (5, 1.1, 0.07)],
            "GRASS_TERMS": [(3, 1.6, 0.06)],
            # Calmer than round 1's 2.2 / 0.07 on purpose: crag is vertical
            # noise the built ledges have to CLEAR, and at 2.2 it both ate the
            # terracing and forced the slabs so far off the rock they floated.
            "CRAG": 0.9,
            "CRAG_FREQ": 0.06,
            # The radial wobble is small here for a reason too: the guano runs
            # ride a hair proud of the ANALYTIC face, so a face that wanders
            # far off it either swallows them or leaves them standing off the
            # rock as white fins (which is how round 2 rendered).
            "CRAG_RADIAL": 0.022,
            "CRAG_RADIAL_FREQS": (7.0, 4.0),
            "CRAG_CALM": None,
            "RIM_FLAT": None,
            "NOTCHES": [],
            "NOTCH_BAND": None,
            "PEAK_JAG": 0.0,
            "PEAK_TERMS": [],
            "PREVIEW_SHOTS": [
                ("approach", (86.0, -96.0, 34.0), (0.0, 0.0, 28.0), 28),
                ("ledges", (52.0, -58.0, 41.0), (0.0, 0.0, 30.0), 34),
                # Close on the middle terrace: the shot that shows whether the
                # birds are STANDING on a shelf or pasted to a wall, which is
                # the failure this islet was rebuilt to fix.
                ("colony", (38.0, -42.0, 47.0), (0.0, 2.0, 34.0), 44),
            ],
            "COLORS": {
                # Darker than round 1's 0.40. The guano has to READ as white
                # against it, and under Workbench's studio light a 0.40 rock
                # and a 0.85 ledge both came out mid-grey - the stack rendered
                # as one flat tone with the staining invisible on it.
                "M_RookRock": (0.247, 0.243, 0.235),
                # The splash zone is SCRUBBED, not fouled - the sea takes the
                # guano off the bottom of a stack. Round 1 painted this band
                # (u 0.72 -> 1.0, i.e. the FOOT of the stack) near-white and
                # called it the colour story, so the island read white at the
                # waterline and grey where the colony actually is: backwards.
                "M_RookSplash": (0.235, 0.239, 0.235),
                "M_RookWet": (0.176, 0.180, 0.176),
                # The white belongs on the LEDGES and in the runs below them -
                # that is what a seabird stack looks like from the water. The
                # ledge is the DULLER of the two on purpose: at matching values
                # a terrace and the wash under it merged into one white mass
                # and the streaking stopped reading as streaking.
                "M_RookShelf": (0.800, 0.792, 0.761),
                "M_RookStreak": (0.945, 0.941, 0.918),
                "M_RookNest": (0.478, 0.404, 0.267),
                "M_RookEgg": (0.788, 0.769, 0.678),
                "M_RookGull": (0.925, 0.925, 0.910),
            },
        },
        "build": build_islet_rookery,
    },
    "chapel": {
        "model": "Chapel",
        "overrides": {
            "SEED": 7,
            "ISLAND_RADIUS": 55,
            "SEGMENTS": 40,
            "GRASS_U": 0.55,
            "RINGS": [0.0, 0.20, 0.40, 0.58, 0.74, 0.88, 1.0, 1.09, 1.28],
            # A SHOAL, not an island: the rock barely breaks the surface, so
            # the BUILDING is what stands above water. Everything past u=0.55
            # is already under it.
            "PROFILE": [
                (0.00, 1.6),
                (0.20, 1.3),
                (0.40, 0.6),
                (0.58, -1.2),
                (0.74, -3.4),
                (0.88, -5.6),
                (1.00, -7.0),
                (1.09, -8.0),
                (1.28, SKIRT_BOTTOM),
            ],
            "COAST_TERMS": [(2, 2.4, 0.10), (4, 1.2, 0.06)],
            "GRASS_TERMS": [(3, 0.6, 0.04)],
            "CRAG": 0.9,
            "CRAG_FREQ": 0.05,
            "CRAG_RADIAL": 0.04,
            "CRAG_RADIAL_FREQS": (5.0, 3.0),
            "CRAG_CALM": None,
            "RIM_FLAT": (0.0, 0.50),
            "NOTCHES": [],
            "NOTCH_BAND": None,
            "PEAK_JAG": 0.0,
            "PEAK_TERMS": [],
            "PREVIEW_SHOTS": [
                ("approach", (70.0, -70.0, 26.0), (0.0, -4.0, 16.0), 30),
                ("tower", (54.0, -58.0, 34.0), (-6.0, -4.0, 20.0), 34),
                ("hole", (18.0, -26.0, 20.0), (13.0, -4.0, 2.0), 42),
                # Close on the belfry: the bell and the stone on its rope are
                # the point of this islet and they are 3 studs across on a
                # 31-stud tower, so they need a shot of their own to judge.
                # Square-on to a FACE, not to a corner: from a corner the near
                # pier stands in front of the bell and hides the whole story.
                ("belfry", (28.0, -4.0, 30.0), (-6.0, 4.0, 26.6), 55),
            ],
            "COLORS": {
                "M_ChapShoal": (0.416, 0.427, 0.400),
                "M_ChapSilt": (0.353, 0.365, 0.341),
                "M_ChapWet": (0.267, 0.286, 0.278),
                "M_ChapStone": (0.545, 0.541, 0.502),  # dressed, pale, weathered
                "M_ChapSlate": (0.318, 0.337, 0.361),
                # The drowned nave reads through the water, so it is DARKER and
                # bluer than the tower above it - depth doing the work.
                "M_ChapDrowned": (0.271, 0.318, 0.325),
                # The bell. It hangs in the SHADE of the belfry with pale stone
                # all round it, so it is pitched much brighter and much warmer
                # than a real weathered bronze: anything darker than the tower
                # in there just reads as another hole in the masonry. Warm, not
                # the bellbuoy's green - Odd rings this one every day.
                "M_ChapBronze": (0.749, 0.612, 0.310),
                "M_ChapIron": (0.180, 0.184, 0.196),
                "M_ChapTimber": (0.365, 0.267, 0.180),
                "M_ChapRope": (0.706, 0.620, 0.443),
                # The stone Odd rings with. Deliberately NOT the tower's dressed
                # stone: it has to read as a thing somebody tied on, not as a
                # lump that fell off the building.
                "M_ChapCobble": (0.278, 0.267, 0.251),
            },
        },
        "build": build_islet_chapel,
    },
    "whalefall": {
        "model": "Whalefall",
        "overrides": {
            "SEED": 7,
            # Big, because the crescent is 200 studs tip to tip and its drowned
            # banks trail 50 further off the west end. The radial base is not
            # the island here - it is the SHOAL the bar sits on, so its whole
            # profile is under water and only build_islet_whalefall's own bmesh
            # breaks the surface.
            "ISLAND_RADIUS": 120,
            "SEGMENTS": 46,
            "GRASS_U": 0.48,
            "RINGS": [0.0, 0.24, 0.48, 0.66, 0.80, 0.90, 1.0, 1.09, 1.28],
            "PROFILE": [
                (0.00, -1.4),
                (0.24, -1.7),
                (0.48, -2.2),
                (0.66, -3.0),
                (0.80, -4.1),
                (0.90, -5.2),
                (1.00, -6.3),
                (1.09, -7.6),
                (1.28, SKIRT_BOTTOM),
            ],
            "COAST_TERMS": [(2, 3.2, 0.10), (3, 1.8, 0.07), (5, 0.9, 0.04)],
            "GRASS_TERMS": [(2, 1.4, 0.05)],
            "CRAG": 0.55,
            "CRAG_FREQ": 0.05,
            "CRAG_RADIAL": 0.05,
            "CRAG_RADIAL_FREQS": (4.0, 3.0),
            "CRAG_CALM": None,
            "RIM_FLAT": None,
            "NOTCHES": [],
            "NOTCH_BAND": None,
            "PEAK_JAG": 0.0,
            "PEAK_TERMS": [],
            "PREVIEW_SHOTS": [
                # The silhouette IS the island: a high shot from inside the
                # curve, with both arms coming at the camera.
                ("crescent", (34.0, 236.0, 176.0), (0.0, -8.0, 0.0), 40),
                ("carcass", (-8.0, -98.0, 27.0), (-4.0, -25.0, 6.0), 42),
                ("camp", (96.0, -52.0, 25.0), (56.0, -3.0, 5.0), 38),
                ("hut", (78.0, -22.0, 13.0), (63.0, 4.0, 5.0), 40),
                # from the gutting table, looking straight into the jaw door.
                ("door", (49.0, -15.0, 10.5), (61.6, 1.2, 5.4), 32),
            ],
            "COLORS": {
                # Cold, wind-scoured sand: pale and bleached, nothing warm.
                "M_WhaleSand": (0.663, 0.639, 0.576),
                "M_WhaleSilt": (0.435, 0.435, 0.416),
                "M_WhaleWet": (0.325, 0.337, 0.337),
                # The oil halo the carcass has bled into the bar - as dark as
                # anything on the islet, so the stain reads as a SHAPE from the
                # air and the skeleton sits inside it.
                "M_WhaleOil": (0.196, 0.180, 0.165),
                "M_WhaleBone": (0.878, 0.855, 0.796),
                # Baleen is keratin, not bone: near-black, and deliberately the
                # opposite end of the ramp so the fence and thatch never blur
                # into the skeleton they came off.
                "M_WhaleBaleen": (0.161, 0.153, 0.169),
                "M_WhaleDrift": (0.427, 0.396, 0.345),
                "M_WhaleCanvas": (0.729, 0.702, 0.616),
                "M_WhaleIron": (0.176, 0.184, 0.196),
                "M_WhaleRope": (0.627, 0.553, 0.427),
                "M_WhaleSalt": (0.827, 0.816, 0.784),
                "M_WhaleFish": (0.702, 0.510, 0.463),
                # The ONLY green: marram on the dry crown of the spine.
                "M_WhaleGrass": (0.494, 0.573, 0.376),
                "M_WhaleGull": (0.933, 0.929, 0.910),
                "M_WhaleBeak": (0.859, 0.627, 0.204),
                # Neon in-game, and the one warm thing for 200 studs.
                "M_WhaleEmber": (1.000, 0.443, 0.125),
            },
        },
        "build": build_islet_whalefall,
    },
    "anchorage": {
        "model": "Anchorage",
        "overrides": {
            "SEED": 7,
            "ISLAND_RADIUS": 70,
            "SEGMENTS": 52,
            "GRASS_U": 0.38,
            "RINGS": [0.0, 0.20, 0.38, 0.56, 0.72, 0.88, 1.0, 1.10, 1.30],
            # A WADING FLAT, not a hill: the sand sits a hand's breadth under
            # the sea the whole way across, so the player walks the garden in
            # ankle-to-knee water and only the hummocks (own geometry) are dry.
            "PROFILE": [
                (0.00, 0.55),
                (0.20, 0.52),
                (0.38, 0.46),
                (0.56, 0.38),
                (0.72, 0.26),
                (0.88, 0.14),
                (1.00, -0.22),
                (1.10, -3.4),
                (1.30, SKIRT_BOTTOM),
            ],
            "COAST_TERMS": [(2, 4.0, 0.14), (3, 2.2, 0.09), (5, 1.1, 0.06)],
            "GRASS_TERMS": [(2, 1.2, 0.06)],
            "CRAG": 0.22,
            "CRAG_FREQ": 0.07,
            "CRAG_RADIAL": 0.05,
            "CRAG_RADIAL_FREQS": (4.0, 3.0),
            "CRAG_CALM": None,
            "RIM_FLAT": (0.0, 0.88),
            "NOTCHES": [],
            "NOTCH_BAND": None,
            "PEAK_JAG": 0.0,
            "PEAK_TERMS": [],
            "PREVIEW_SHOTS": [
                ("approach", (96.0, -100.0, 30.0), (-3.0, -7.0, 10.0), 30),
                # the money shot: a wader's eye, rust standing out of turquoise
                ("wade", (80.0, 18.0, 2.8), (-6.0, -6.0, 12.0), 34),
                ("shack", (36.0, -44.0, 20.0), (-6.0, -7.0, 17.0), 46),
                ("taut", (62.0, 74.0, 34.0), (-62.0, -34.0, 4.0), 30),
                ("channel", (80.0, -86.0, 4.2), (24.0, -26.0, 5.0), 34),
            ],
            "COLORS": {
                # white-gold sand, then the same sand read through turquoise
                "M_AnchSand": (0.965, 0.906, 0.702),
                "M_AnchShoal": (0.404, 0.855, 0.796),
                "M_AnchDeep": (0.106, 0.494, 0.573),
                "M_AnchDune": (0.976, 0.918, 0.749),
                "M_AnchStar": (0.941, 0.443, 0.259),
                "M_AnchWater": (0.243, 0.831, 0.788),
                # RUST is the identity: every iron thing is two-tone, dark
                # above the waterline band and burnt orange below it.
                "M_AnchIron": (0.259, 0.235, 0.220),
                "M_AnchRust": (0.804, 0.318, 0.063),
                "M_AnchChain": (0.667, 0.310, 0.106),
                "M_AnchBuoyRed": (0.741, 0.310, 0.271),
                "M_AnchBuoyPale": (0.831, 0.839, 0.792),
                "M_AnchTaut": (0.949, 0.502, 0.055),  # THE chain: hottest rust
                "M_AnchPlank": (0.596, 0.463, 0.310),
                "M_AnchRoof": (0.325, 0.290, 0.267),
                "M_AnchTrim": (0.322, 0.212, 0.145),
                "M_AnchMark": (0.788, 0.294, 0.220),  # the channel markers' bands
            },
        },
        "build": build_islet_anchorage,
    },
    "boilshoal": {
        "model": "Boilshoal",
        "overrides": {
            "SEED": 7,
            "ISLAND_RADIUS": 60,
            "SEGMENTS": 48,
            # The material boundary IS this ring: black glass everywhere inside
            # (the lagoon floor), sulphur crust on the bank the rim stands on.
            "GRASS_U": 0.84,
            "RINGS": [0.0, 0.20, 0.40, 0.58, 0.72, 0.84, 1.0, 1.09, 1.28],
            # A DISH, not a dome: the base is the drowned lagoon floor rising to
            # a shallow bank at the shoreline. Everything above water on this
            # islet - the rim, the terraces, the bath-house shelf - is built on
            # top of it as its own geometry.
            "PROFILE": [
                (0.00, -1.9),
                (0.20, -1.8),
                (0.40, -1.5),
                (0.58, -0.9),
                (0.72, -0.2),
                (0.84, 1.2),
                (1.00, 2.4),
                (1.09, -2.6),
                (1.28, SKIRT_BOTTOM),
            ],
            "COAST_TERMS": [(2, 2.6, 0.10), (4, 1.4, 0.06), (7, 0.4, 0.03)],
            "GRASS_TERMS": [(3, 1.0, 0.05)],
            # Broken glassy rock: crag hard on the bank, so it reads as
            # something that cooled fast. RIM_FLAT holds it off the lagoon
            # floor, which stays a clean wading dish.
            "CRAG": 1.6,
            "CRAG_FREQ": 0.075,
            "CRAG_RADIAL": 0.07,
            "CRAG_RADIAL_FREQS": (6.0, 4.0),
            "CRAG_CALM": None,
            "RIM_FLAT": (0.0, 0.74),
            # The two channels where the sea and the lagoon exchange - the bank
            # is cut below the waterline at both. MIRRORED in _SHOAL_GAPS; keep
            # the two lists in step.
            "NOTCHES": [(-0.80, 0.30, 5.0), (2.95, 0.22, 5.0)],
            "NOTCH_BAND": (0.74, 1.12),
            "PEAK_JAG": 0.0,
            "PEAK_TERMS": [],
            "PREVIEW_SHOTS": [
                # THE money shot: in through the near channel, the black wall
                # standing away to the left, milky turquoise inside it.
                ("approach", (96.0, -101.0, 27.0), (-4.0, 4.0, 5.0), 35),
                ("terraces", (74.0, -26.0, 30.0), (31.0, -6.0, 3.0), 36),
                ("bathhouse", (12.0, 15.0, 15.0), (-22.8, 35.2, 7.0), 34),
            ],
            "COLORS": {
                "M_ShoalGlass": (0.157, 0.149, 0.176),  # black volcanic glass
                "M_ShoalCrust": (0.741, 0.647, 0.235),  # sulphur yellow crust
                "M_ShoalWet": (0.106, 0.102, 0.118),
                "M_ShoalMineral": (0.522, 0.298, 0.184),  # rust red around the vents
                "M_ShoalSteam": (0.961, 0.973, 0.976),
                "M_ShoalHeat": (1.000, 0.478, 0.145),  # down the throats, Neon in game
                "M_ShoalLagoon": (0.325, 0.937, 0.878),  # milky turquoise, hot
                "M_ShoalPool": (0.298, 0.902, 0.867),  # the rimstone pools, hotter still
                "M_ShoalChalk": (0.965, 0.957, 0.925),  # dry rimstone
                "M_ShoalChalkWet": (0.678, 0.769, 0.741),  # the drowned lips
                "M_ShoalCopper": (0.302, 0.573, 0.494),  # scavenged roof gone verdigris
                "M_ShoalTimber": (0.302, 0.243, 0.204),
                "M_ShoalIron": (0.278, 0.259, 0.251),
                "M_ShoalFish": (0.847, 0.827, 0.769),  # bleached dead fish
            },
        },
        "build": build_islet_boilshoal,
    },
    "ferryraft": {
        "model": "Ferryraft",
        "overrides": {
            "SEED": 7,
            "ISLAND_RADIUS": 40,
            "SEGMENTS": 30,
            "GRASS_U": 0.50,
            "RINGS": [0.0, 0.26, 0.50, 0.72, 0.88, 1.0, 1.09, 1.28],
            # There is no island here. The bar sits ENTIRELY under the water so
            # the raft is what you see; it exists only to give the deck ground
            # to be anchored and probed against.
            "PROFILE": [
                (0.00, -1.4),
                (0.26, -1.7),
                (0.50, -2.4),
                (0.72, -3.6),
                (0.88, -5.0),
                (1.00, -6.2),
                (1.09, -7.4),
                (1.28, SKIRT_BOTTOM),
            ],
            "COAST_TERMS": [(2, 1.4, 0.10)],
            "GRASS_TERMS": [(3, 0.5, 0.04)],
            "CRAG": 0.3,
            "CRAG_FREQ": 0.04,
            "CRAG_RADIAL": 0.02,
            "CRAG_RADIAL_FREQS": (4.0, 3.0),
            "CRAG_CALM": None,
            "RIM_FLAT": (0.0, 0.60),
            "NOTCHES": [],
            "NOTCH_BAND": None,
            "PEAK_JAG": 0.0,
            "PEAK_TERMS": [],
            "PREVIEW_SHOTS": [
                ("approach", (52.0, -56.0, 22.0), (0.0, 0.0, 4.0), 32),
                ("deck", (24.0, -26.0, 14.0), (0.0, 0.0, 4.0), 42),
            ],
            "COLORS": {
                "M_RaftBar": (0.298, 0.322, 0.318),
                "M_RaftShallow": (0.263, 0.286, 0.286),
                "M_RaftWet": (0.216, 0.235, 0.239),
                "M_RaftLog": (0.376, 0.298, 0.216),
                "M_RaftPlank": (0.475, 0.396, 0.294),
                "M_RaftRope": (0.639, 0.588, 0.451),
                "M_RaftLantern": (1.000, 0.827, 0.478),  # the only warm thing for 6,000 studs
            },
        },
        "build": build_islet_ferryraft,
    },
    "loadstone": {
        "model": "Loadstone",
        "overrides": {
            "SEED": 7,
            "ISLAND_RADIUS": 45,
            "SEGMENTS": 34,
            "GRASS_U": 0.74,  # on a RINGS entry, so the scorch band edge is a clean polyline
            "RINGS": [0.0, 0.18, 0.38, 0.56, 0.74, 0.88, 1.0, 1.09, 1.28],
            # A low BROKEN base. Every stud of height lives in the spire
            # cluster and the rubble the builder stacks on top, so the profile
            # only has to give them a craggy shelf to stand on and a hard
            # shoulder down to the waterline. Standard -9 skirt.
            "PROFILE": [
                (0.00, 5.4),
                (0.18, 5.2),
                (0.38, 4.6),
                (0.56, 3.5),
                (0.74, 2.1),
                (0.88, 0.9),
                (1.00, 0.0),
                (1.09, -2.8),
                (1.28, SKIRT_BOTTOM),
            ],
            "COAST_TERMS": [(2, 2.0, 0.15), (5, 1.0, 0.08), (9, 0.4, 0.04)],
            "GRASS_TERMS": [(3, 0.9, 0.05)],
            # Cranked hard and left un-flattened: the strikes SHATTER this
            # rock, so the ground under the rubble has to be broken too.
            "CRAG": 2.6,
            "CRAG_FREQ": 0.10,
            "CRAG_RADIAL": 0.07,
            "CRAG_RADIAL_FREQS": (7.0, 5.0),
            "CRAG_CALM": None,
            "RIM_FLAT": None,
            "NOTCHES": [],
            "NOTCH_BAND": None,
            "PEAK_JAG": 0.0,
            "PEAK_TERMS": [],
            "PREVIEW_SHOTS": [
                # The money shot: the cathedral cluster from the water.
                ("approach", (118.0, -128.0, 26.0), (0.0, 2.0, 44.0), 30),
                ("rubble", (30.0, -30.0, 15.0), (-6.0, 2.0, 7.0), 34),
                ("shack", (11.0, -54.0, 13.0), (0.0, -26.0, 7.0), 40),
                ("compass", (-11.0, -41.5, 8.6), (-2.6, -29.6, 6.2), 42),
            ],
            "COLORS": {
                "M_LoadRock": (0.145, 0.141, 0.165),  # magnetite, a blue cast in the black
                "M_LoadScorch": (0.075, 0.071, 0.082),
                "M_LoadWet": (0.110, 0.110, 0.129),
                "M_LoadGlass": (0.180, 0.176, 0.231),  # spire body: black with a violet metallic sheen
                "M_LoadVitrify": (0.286, 0.271, 0.365),  # fused glassy splash where the bolts landed
                "M_LoadFulgurite": (0.878, 0.867, 0.831),  # lightning glass, bone white
                "M_LoadIron": (0.325, 0.310, 0.302),
                "M_LoadRust": (0.451, 0.263, 0.176),
                "M_LoadGull": (0.780, 0.769, 0.741),
                "M_LoadPlank": (0.427, 0.345, 0.251),
                "M_LoadRoof": (0.400, 0.412, 0.400),  # corrugated tin
                "M_LoadInsulator": (0.663, 0.796, 0.808),  # the glass under the bed legs
                "M_LoadBrass": (0.722, 0.565, 0.267),
                "M_LoadDial": (0.867, 0.847, 0.784),
                "M_LoadNeedle": (0.749, 0.192, 0.176),
                "M_LoadHeat": (1.000, 0.596, 0.278),  # NEON: heat still in the seams
                "M_LoadElmo": (0.612, 0.427, 1.000),  # NEON: St Elmo's fire on the tips
            },
        },
        "build": build_islet_loadstone,
    },
    "lampwork": {
        "model": "Lampwork",
        "overrides": {
            "SEED": 7,
            "ISLAND_RADIUS": 55,
            "SEGMENTS": 44,  # ~8-stud facets on a 55-stud rock: low-poly, still round
            "GRASS_U": 0.72,  # dark stone above, splash band below - the break IS a ring
            # The ring at u=0.80 is THE LIP - _LAMP_LIP_RING indexes it, and
            # _lamp_carve_void pulls every ring outside it onto the lip's own
            # footprint on the seaward third. Move 0.80's position in this list
            # and that constant must move with it.
            "RINGS": [0.0, 0.18, 0.38, 0.56, 0.70, 0.80, 0.90, 0.96, 1.02, 1.12, 1.30],
            # A level shelf out to u=0.80, then TWO different endings. On the
            # safe side this profile takes over: a rocky bank down to a wide
            # wet apron just above the waterline (u 0.90-1.02) with the tide
            # pools in it, then away to the -9 skirt. On the seaward third the
            # profile is overwritten in the mesh - the shelf lifts into a brow
            # and the ground stops in a plumb wall to -9. Standard -9 skirt.
            "PROFILE": [
                (0.00, 9.6),  # the shelf the workshop and the lamp yard stand on
                (0.38, 9.4),
                (0.70, 8.9),
                (0.80, 8.0),  # THE LIP
                (0.90, 2.2),  # (safe side) the bank falls to the apron
                (0.96, 1.5),
                (1.02, 0.9),  # the wet apron, tide-pool height
                (1.12, -3.0),
                (1.30, SKIRT_BOTTOM),
            ],
            "COAST_TERMS": [(2, 1.9, 0.13), (3, 0.4, 0.09), (5, 2.7, 0.06)],
            "GRASS_TERMS": [(2, 1.2, 0.05), (4, 2.4, 0.035)],
            # Crag ONLY on the shoulder (RIM_FLAT holds u < 0.80 dead level for
            # the yard), so the rock reads broken from the water while every
            # prop inland sits on ground height_at describes exactly. The
            # jetty, which DOES cross the craggy band, raycasts instead.
            "CRAG": 2.4,
            "CRAG_FREQ": 0.055,
            "CRAG_RADIAL": 0.06,
            "CRAG_RADIAL_FREQS": (6.0, 4.0),
            "CRAG_CALM": None,
            "RIM_FLAT": (0.0, 0.80),
            "NOTCHES": [],
            "NOTCH_BAND": None,
            "PEAK_JAG": 0.0,
            "PEAK_TERMS": [],
            "PREVIEW_SHOTS": [
                # The sail-in down the +Z lane (the read that has to land: a
                # dark rock covered in lamps that are all switched off, and one
                # window somebody is still working behind), then straight into
                # the open forge face, then close on the window and its moths.
                # The sail-in is a THREE-QUARTER off the +x/-y quarter, not a
                # head-on: that bearing is the only one that puts the great
                # lamp (dark), the yard (dark) and the ONE lit window in the
                # same frame, which is the whole read.
                ("approach", (64.0, -82.0, 17.0), (-6.0, 2.0, 12.0), 30),
                ("shop", (9.0, -29.0, 15.0), (-6.0, 12.0, 13.5), 34),
                ("window", (27.0, 3.0, 18.5), (4.2, 12.0, 15.2), 44),
                ("jetty", (34.0, -66.0, 9.0), (0.0, -44.0, 3.0), 34),
                # THE MONEY SHOT: eye height barely above the sea, dead astern
                # of the drop. Land that ends in a wall over blackness, with
                # the jetty walking out off the end of it.
                ("void", (14.0, -112.0, 6.5), (-4.0, -30.0, 9.0), 34),
                # The yard from inside it - the density check.
                ("yard", (33.0, -31.0, 21.0), (-9.0, 2.0, 10.0), 28),
                # The tower he never finished, dark, with the shop behind it.
                ("stump", (50.0, -30.0, 17.0), (14.0, -15.0, 12.5), 40),
                # Straight into the open end of the lean-to: bunk, stove, chair.
                ("quarters", (-36.0, 17.5, 15.5), (-7.0, 25.0, 11.0), 32),
                # The glazier's wall of dark sash on the far gable.
                ("glazier", (-46.0, -4.0, 16.0), (-16.0, 12.0, 14.0), 34),
            ],
            "COLORS": {
                # A rock on the run down to the trench: near-black wet basalt,
                # a paler splash band, and one worked-brass note so the yard of
                # lamps reads at all against it.
                "M_LampStone": (0.129, 0.137, 0.169),
                "M_LampShore": (0.239, 0.239, 0.271),
                "M_LampWet": (0.169, 0.176, 0.208),
                "M_LampWall": (0.318, 0.306, 0.306),  # the workshop's dressed stone
                "M_LampTimber": (0.325, 0.259, 0.204),  # tarred timber: frame, benches, jetty
                "M_LampSlate": (0.204, 0.212, 0.239),
                "M_LampIron": (0.157, 0.161, 0.180),  # gantry, hooks, muntins, tools
                # TARNISHED brass, not polished. Round 1 of the preview had it
                # at 0.68/0.53/0.26 and every lamp in the yard read as LIT from
                # the water - the whole point of the islet inverted by one
                # colour. Dim enough to say "off", warm enough to still pick
                # the lamps out against the black rock.
                "M_LampBrass": (0.510, 0.396, 0.208),
                # DEAD glass. Dark cold grey-green, deliberately nowhere near
                # the window's warm - a lamp here must never look lit.
                "M_LampGlass": (0.298, 0.361, 0.376),
                # THE one light, and the brightest thing on the islet by a
                # wide margin so nothing else can be mistaken for it (Neon
                # in-game). Everything above is tuned to lose to this.
                "M_LampWindow": (1.000, 0.886, 0.588),
                "M_LampMoth": (0.847, 0.824, 0.757),
                # THE TRENCH. The seabed beyond the cliff foot and the water
                # standing in the tide pools and the quench trough - near
                # black, so from above the water on the void side reads as a
                # different, deeper thing than the water on the safe side.
                "M_LampTrench": (0.031, 0.043, 0.063),
                # Fired clay: the oil jars. The only earth tone on the islet.
                "M_LampClay": (0.294, 0.216, 0.169),
                # Hemp: wick coils and hanks, the straw collars round the jars,
                # the pallet on his bunk, the rope along the lip. Pale enough
                # to read against black basalt without competing with the
                # window - it is matte, and the window is Neon.
                "M_LampRope": (0.435, 0.388, 0.294),
            },
        },
        "build": build_islet_lampwork,
    },
}


def configure(overrides):
    """Apply an island's overrides onto the shape-state globals, then reseed
    so the build is deterministic. SCALE/TREE_SCALE derive from the (possibly
    overridden) ISLAND_RADIUS unless the override set them explicitly."""
    g = globals()
    for key, value in overrides.items():
        g[key] = value
    if "SCALE" not in overrides:
        g["SCALE"] = g["ISLAND_RADIUS"] / _BASE_RADIUS
    if "TREE_SCALE" not in overrides:
        g["TREE_SCALE"] = g["SCALE"] * 1.6
    # Unlike the legacy shape keys (which every entry must pin by hand - the
    # no-reset rule), this newer knob RESETS to its default here: gloom and
    # wreck use the radial wobble without setting frequencies, and inheriting
    # the volcano's cranked pair drifted their mesh bottoms (-16.53 -> -16.86
    # / -18.25 -> -18.22, caught by the pack HANDOFF check, 2026-08-27).
    if "CRAG_RADIAL_FREQS" not in overrides:
        g["CRAG_RADIAL_FREQS"] = (6.0, 4.0)
    random.seed(SEED)


# ---------------------------------------------------------------- preview


def render_preview(out_png):
    """A headless 3/4 Workbench render of the built island over a water plane,
    so a design can be judged from a PNG without a Studio import. The scene is
    Blender-native Z-up here (export_yup only affects the exported file)."""
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "MATERIAL"
    scene.display.shading.show_shadows = True
    scene.display.shading.show_cavity = False
    scene.render.resolution_x = 1280
    scene.render.resolution_y = 800
    scene.render.film_transparent = False
    scene.world = scene.world or bpy.data.worlds.new("PreviewWorld")
    scene.world.color = (0.55, 0.72, 0.92)

    bpy.ops.mesh.primitive_plane_add(size=max(ISLAND_RADIUS * 8, 500), location=(0, 0, 0))
    water = bpy.context.active_object
    wmat = bpy.data.materials.new("PreviewWater")
    wmat.diffuse_color = (0.13, 0.42, 0.68, 1)
    water.data.materials.append(wmat)

    cam_data = bpy.data.cameras.new("PreviewCam")
    cam_data.lens = 42
    # Big islands sit well past Blender's default 1000-stud clip; push it out.
    cam_data.clip_end = max(5000.0, ISLAND_RADIUS * 12)
    cam = bpy.data.objects.new("PreviewCam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    d = ISLAND_RADIUS * 2.3
    # A low 3/4 so a tall cone reads tall, lifted just enough to see the lava
    # lake filling the crater.
    peak = max(h for _, h in PROFILE)
    cam.location = (d * 0.85, -d * 0.85, peak * 1.15 + d * 0.35)
    direction = Vector((0, 0, peak * 0.5)) - Vector(cam.location)
    cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()

    out_png = os.path.abspath(out_png)
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = out_png
    bpy.ops.render.render(write_still=True)
    if not os.path.exists(out_png):
        raise RuntimeError(f"preview render did not produce {out_png}")
    print(f"[island_gen] preview rendered to {out_png}")

    # Island-declared extra cameras (PREVIEW_SHOTS override; see the global).
    for suffix, eye, target, lens in PREVIEW_SHOTS:
        cam.data.lens = lens
        cam.location = Vector(eye)
        cam.rotation_euler = (Vector(target) - Vector(eye)).to_track_quat("-Z", "Y").to_euler()
        shot_png = os.path.splitext(out_png)[0] + f"_{suffix}.png"
        scene.render.filepath = shot_png
        bpy.ops.render.render(write_still=True)
        print(f"[island_gen] {suffix} view rendered to {shot_png}")

    # LEGACY notch-gated shots (dock/tower/apron cameras keyed to the OLD
    # pre-restart volcano's dock bearing). An island that declares its own
    # PREVIEW_SHOTS owns its preview set - without this guard, the restarted
    # volcano's lava step re-armed NOTCHES and this branch resurrected stale
    # _dock/_tower renders AND overwrote the declared _apron shot with the
    # old camera (2026-08-27).
    if NOTCHES and not PREVIEW_SHOTS:
        a = math.radians(DOCK_ANGLE_DEG)
        outward = Vector((math.cos(a), math.sin(a), 0))
        r_shore = ring_radius(1.0, a)

        cam.data.lens = 24
        eye = outward * (r_shore + 85.0) + Vector((0, 0, 14.0))
        target = outward * (r_shore - 40.0) + Vector((0, 0, 6.0))
        cam.location = eye
        cam.rotation_euler = (target - eye).to_track_quat("-Z", "Y").to_euler()
        dock_png = os.path.splitext(out_png)[0] + "_dock.png"
        scene.render.filepath = dock_png
        bpy.ops.render.render(write_still=True)
        print(f"[island_gen] dock view rendered to {dock_png}")

        cam.data.lens = 20
        eye = outward * (r_shore + 430.0) + Vector((0, 0, 60.0))
        target = Vector((0, 0, peak * 0.5))
        cam.location = eye
        cam.rotation_euler = (target - eye).to_track_quat("-Z", "Y").to_euler()
        tower_png = os.path.splitext(out_png)[0] + "_tower.png"
        scene.render.filepath = tower_png
        bpy.ops.render.render(write_still=True)
        print(f"[island_gen] tower view rendered to {tower_png}")

        # And a walk-around shot: standing ON the apron near the dock,
        # looking along the base - what the ground game actually feels like.
        a_eye = math.radians(DOCK_ANGLE_DEG + 20)
        a_tgt = math.radians(DOCK_ANGLE_DEG + 75)
        r_eye = ring_radius(0.90, a_eye)
        r_tgt = ring_radius(0.84, a_tgt)
        cam.data.lens = 24
        eye = Vector((math.cos(a_eye) * r_eye, math.sin(a_eye) * r_eye, 12.0))
        target = Vector((math.cos(a_tgt) * r_tgt, math.sin(a_tgt) * r_tgt, 8.0))
        cam.location = eye
        cam.rotation_euler = (target - eye).to_track_quat("-Z", "Y").to_euler()
        apron_png = os.path.splitext(out_png)[0] + "_apron.png"
        scene.render.filepath = apron_png
        bpy.ops.render.render(write_still=True)
        print(f"[island_gen] apron view rendered to {apron_png}")


# ---------------------------------------------------------------- export


def build_pack(out_path):
    """Every island in ISLAND_ORDER bundled into one importable .glb - the
    IslandPack, the same "one Studio import no matter how many" idea the rod /
    fish / creature / weapon packs use. Each island's objects are parented under
    an Empty named for its runtime model (Island, Volcano, ...), so the import
    comes in as one container with a child group per island; WorldService clones
    each group out and places it. Islands are built where they sit (overlapping
    at the origin in the file, like the rod pack) - the game re-centres each by
    its base part, so the overlap in the file is invisible in-game."""
    clear_scene()
    summary = []
    for island_id in ISLAND_ORDER:
        cfg = ISLANDS[island_id]
        configure(cfg["overrides"])
        for name in COLORS:
            make_material(name)
        objects = cfg["build"]()

        # Group this island's objects under an Empty named for its model, so the
        # import is separable per island. Empty sits at the origin, so parenting
        # leaves every object's world position untouched.
        group = bpy.data.objects.new(cfg["model"], None)
        bpy.context.collection.objects.link(group)
        for obj in objects:
            obj.parent = group
        summary.append((cfg["model"], island_id, group, objects))

    # The scene holds only island objects + their group Empties now.
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(
        filepath=out_path,
        export_format="GLB",
        use_selection=True,
        export_yup=True,  # Blender is Z-up internally; Roblox (and glTF) is Y-up
        export_materials="EXPORT",
        export_apply=True,
        export_normals=True,
        export_texcoords=False,
    )

    print(f"[island_gen] exported PACK {out_path}")
    total = 0
    IMPORT_LIMIT = 2048  # Roblox rejects a mesh larger than this on any axis
    for model, island_id, _group, objects in summary:
        tris = sum(len(o.data.polygons) for o in objects)
        total += tris
        names = ", ".join(o.name for o in objects)
        print(f"[island_gen]   {model:<10} ({island_id}): {len(objects)} objects, {tris} tris  -> [{names}]")
        # WorldService aligns the imported bbox bottom on Islands.luau
        # `meshBottom` (default: the -9 skirt). Any island whose lowest vertex
        # is NOT -9 must carry this number in its entry, or the bbox pin hoists
        # the whole island by the overshoot and everything waterline-referenced
        # floats (2026-08-27). Re-key after every regen.
        low = min(min(v.co.z for v in o.data.vertices) for o in objects if o.data.vertices)
        keyed = "" if abs(low - SKIRT_BOTTOM) < 0.01 else "  <-- set Islands.luau meshBottom to this"
        print(f"[island_gen]   HANDOFF {island_id}: mesh bottom z {low:.2f}{keyed}")
        for o in objects:
            xs = [v.co.x for v in o.data.vertices]
            ys = [v.co.y for v in o.data.vertices]
            zs = [v.co.z for v in o.data.vertices]
            dx, dy, dz = max(xs) - min(xs), max(ys) - min(ys), max(zs) - min(zs)
            biggest = max(dx, dy, dz)
            flag = "  <-- OVER IMPORT LIMIT" if biggest > IMPORT_LIMIT else ""
            print(f"[island_gen]       {o.name:<20} bbox {dx:7.1f} x {dy:7.1f} x {dz:7.1f}{flag}")
    print(f"[island_gen] pack: {len(summary)} islands, {total} tris total")


def main():
    args = sys.argv[sys.argv.index("--") + 1 :]
    out_path = args[0]
    rest = args[1:]

    # `-- <out.glb> pack` builds every island into one importable pack.
    if "pack" in rest:
        build_pack(out_path)
        return

    island_id = next((a for a in rest if a != "preview"), "tropical")
    want_preview = "preview" in rest

    cfg = ISLANDS.get(island_id)
    if not cfg:
        raise SystemExit(f"[island_gen] unknown island '{island_id}'; known: {sorted(ISLANDS)}")

    clear_scene()
    configure(cfg["overrides"])
    for name in COLORS:
        make_material(name)

    objects = cfg["build"]()

    if want_preview:
        render_preview(os.path.splitext(out_path)[0] + "_preview.png")

    bpy.ops.object.select_all(action="SELECT")
    # A camera/water plane added for the preview must not export into the .glb.
    for obj in bpy.context.selected_objects:
        if obj not in objects:
            obj.select_set(False)
    bpy.ops.export_scene.gltf(
        filepath=out_path,
        export_format="GLB",
        use_selection=True,
        export_yup=True,  # Blender is Z-up internally; Roblox (and glTF) is Y-up
        export_materials="EXPORT",
        export_apply=True,
        export_normals=True,
        export_texcoords=False,
    )

    total_tris = sum(len(o.data.polygons) for o in objects)
    print(f"[island_gen] island: {island_id}")
    print(f"[island_gen] exported {out_path}")
    print(f"[island_gen] objects: {[o.name for o in objects]}")
    print(f"[island_gen] approx tris (pre-triangulation polys): {total_tris}")
    if DOCK_TOP is not None and island_id == "tropical":
        print(f"[island_gen] REMINDER: World.DECK_Y in src/Shared/Config/World.luau must equal {DOCK_TOP}")


main()
