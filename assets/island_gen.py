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


def add_blob(bm, center, scale, roughness, salt, yaw=0.0):
    """One angular boulder: a low icosphere with noise pushed along the
    normals, then squashed/rotated into place. Appended into `bm`."""
    temp = bmesh.new()
    bmesh.ops.create_icosphere(temp, subdivisions=1, radius=1.0)

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
    trunk_r = max(1.7, h * 0.042)

    # Root flares: short fat cones leaning outward from the base.
    for _ in range(3):
        a = rng.uniform(0, math.tau)
        add_cone(
            bm, (x + math.cos(a) * trunk_r * 0.9, y + math.sin(a) * trunk_r * 0.9, base_z - 0.6),
            trunk_r * 0.55, 0.25, rng.uniform(3.5, 6.0), sides=5,
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
        length = h * rng.uniform(0.32, 0.55) * (1.15 - 0.35 * f)  # lower limbs reach furthest
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
    while made < 40 and attempts < 2400:
        attempts += 1
        theta = random.uniform(0, math.tau)
        u = random.uniform(0.73, 0.97)
        # The spawn/dock corridor on 270 stays clear (the walk off the beach).
        if abs(((theta - math.radians(270) + math.pi) % math.tau) - math.pi) < math.radians(9):
            continue
        r = ring_radius(u, theta)
        x, y = math.cos(theta) * r, math.sin(theta) * r
        if not _volcano_clear_of_rivers(x, y, 14.0):
            continue
        if not _clear_of_ponds(x, y, 6.0):
            continue
        if any((x - px) ** 2 + (y - py) ** 2 < 24.0**2 for px, py in placed):
            continue
        base = _drop_to_ground(ground, x, y)
        if base is None or base < 0.5:
            continue
        # Mostly huge, a few true giants towering over the apron.
        h = random.uniform(38.0, 62.0) if random.random() < 0.75 else random.uniform(62.0, 85.0)
        _dead_tree(bm, x, y, base - 0.8, h, salt=attempts * 3.7 + made)
        placed.append((x, y))
        made += 1
    print(f"[island_gen] HANDOFF volcano trees: {made} dead giants on the apron (heights 38-85)")
    return object_from_bmesh("Volcano_DeadTrees", bm, ["M_Charred"])


# ---------------------------------------------------------------- island builds


def build_tropical():
    objects = [
        build_island_base("Island_Base", ["M_Grass", "M_Sand", "M_WetSand"]),
        build_rocks(),
        *build_palms(),
        build_bushes(),
        *build_dock(),
        build_foam("Island_Foam", "M_Foam"),
    ]
    validate_placement(PALM_CHECKPOINTS, BUSH_CHECKPOINTS)
    print(f"[island_gen] placement OK: {len(PALM_CHECKPOINTS)} palm points, {len(BUSH_CHECKPOINTS)} bushes clear")
    return objects


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
    (build_volcano_trees). Still NO rocks/scatter, NO dock, NO foam - each
    returns with its own reviewed step."""
    base = build_island_base("Volcano_Base", ["M_VolRock", "M_VolAsh", "M_VolWet"])
    ground = _ground_bvh(base)
    lava = build_lava(ground)  # step 2: clears + repopulates LAVA_PONDS itself
    trees = build_volcano_trees(ground)  # step 3: after lava - reads LAVA_PONDS to keep clear
    shore = ring_radius(1.0, math.radians(270))
    peak = max(h for _, h in PROFILE)
    print(
        f"[island_gen] HANDOFF volcano (restart step 2): peak ~{peak:.0f}, +Z shore at rel Z={shore:.0f}, "
        f"spawn suggestion X=0 Z={shore - 30:.0f} ground Y~{height_at(0, -(shore - 30)):.1f}; "
        "no dock/props yet - Pyrelisk's arena keys off the OLD dock, re-key when the dock step lands"
    )
    return [base, lava, trees]


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
SWAMP_MERE = (0.0, -74.0, 30.0)  # the boss mere: forced open water at Old Gnashroot's arena


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
    return object_from_bmesh("Swamp_Base", bm, ["M_Peat", "M_Mud", "M_WetMud"])


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
        return math.hypot(x - mx, y - my) >= mr + pad and math.hypot(x - sx, y - sy) >= 24

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

    print(
        f"[island_gen] swamp smalls: {pads} lily pads ({blooms} blooms) in {rafts} rafts, {logs} logs, {knees} knees, {stones} stones"
    )
    return [
        object_from_bmesh("Swamp_Lilies", lily_bm, ["M_Lily"]),
        object_from_bmesh("Swamp_LilyBlooms", bloom_bm, ["M_LilyBloom"]),
        object_from_bmesh("Swamp_Logs", log_bm, ["M_RootWood"]),
        object_from_bmesh("Swamp_Stones", stone_bm, ["M_BogStone"]),
    ]


def _tilt_toward(direction):
    """The add_cone tilt (a, b) whose axis points along unit `direction`.
    add_cone's axis for tilt (a, b) is Ry(b)Rx(a) @ +Z =
    (sin b cos a, -sin a, cos b cos a), so a = asin(-dy) and
    b = asin(dx / cos a)."""
    a = math.asin(max(-1.0, min(1.0, -direction.y)))
    ca = math.cos(a)
    b = math.asin(max(-1.0, min(1.0, direction.x / ca))) if abs(ca) > 1e-4 else 0.0
    return (a, b)


def build_swamp_trees():
    """The fen's trees - a dense DEAD forest for now (user: 'way way way
    more trees... a ton of them. none of them should have leaves at this
    point'): ~110 bare trees packed through the marsh, all the reference's
    smooth curved tan trunks, in two silhouettes -
      - ARCHERS (~half): the crown throws 3-5 branches that arc out and
        DOWN (the weeping skeleton, awaiting its leaves in a later step)
      - SNAGS: taller, barer, more crooked, a few short crooked branches
    Foliage is deliberately ABSENT; when the leaf step comes it hangs
    blades off these same branch arcs (Swamp_TreeLeaves keeps its
    WorldService entries for that return). One object, trimmed to 5-sided
    trunks / 3-sided branches so ~110 trees stay inside the importer's
    per-mesh triangle budget. Trunks are collidable (Precise import note);
    mere + spawn keep-clears hold."""
    trunk_bm = bmesh.new()
    rng = random.Random(4517)
    mx, my, mr = SWAMP_MERE
    sx, sy = SWAMP_SPAWN
    placed = []

    def dir_of(az, elev):
        c = math.cos(elev)
        return Vector((math.cos(az) * c, math.sin(az) * c, math.sin(elev)))

    def curved_run(bm, base, direction_list, radii, seg_lengths, sides):
        pos = Vector(base)
        joints = [Vector(pos)]
        for i, direction in enumerate(direction_list):
            add_cone(bm, tuple(pos), radii[i], radii[i + 1], seg_lengths[i], sides=sides, tilt=_tilt_toward(direction))
            pos = pos + direction * seg_lengths[i]
            joints.append(Vector(pos))
        return joints

    trees, archers, snags, attempts = 0, 0, 0, 0
    while trees < 110 and attempts < 9000:
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
        if any(math.hypot(x - px, y - py) < 7.5 for px, py in placed):
            continue
        placed.append((x, y))
        trees += 1
        archer = rng.random() < 0.5

        bend_az = rng.uniform(0, math.tau)
        if archer:
            archers += 1
            total_h = rng.uniform(13.0, 20.0)
            r0 = rng.uniform(1.0, 1.7)
            leans = [rng.uniform(0.04, 0.10), rng.uniform(0.16, 0.30), rng.uniform(0.34, 0.52)]
        else:
            snags += 1
            total_h = rng.uniform(18.0, 30.0)
            r0 = rng.uniform(0.8, 1.5)
            leans = [rng.uniform(0.02, 0.10), rng.uniform(0.12, 0.30) * rng.choice((1, -1)), rng.uniform(0.25, 0.5)]
        directions = [dir_of(bend_az, math.pi * 0.5 - abs(l)) for l in leans]
        radii = [r0, r0 * 0.66, r0 * 0.4, r0 * 0.16]
        seg = total_h / 3
        joints = curved_run(trunk_bm, (x, y, g - 0.4), directions, radii, [seg, seg, seg], 5)
        crown = joints[-1]

        if archer:
            for _b in range(rng.randint(3, 5)):
                baz = rng.uniform(0, math.tau)
                blen = rng.uniform(4.0, 7.0)
                b_dirs = [dir_of(baz, rng.uniform(0.5, 0.75)), dir_of(baz, rng.uniform(-0.55, -0.25))]
                b_radii = [r0 * 0.26, r0 * 0.14, 0.05]
                curved_run(
                    trunk_bm, tuple(crown - Vector((0, 0, seg * 0.15))), b_dirs, b_radii, [blen * 0.5, blen * 0.5], 3
                )
        else:
            for _b in range(rng.randint(2, 4)):
                baz = rng.uniform(0, math.tau)
                t = rng.uniform(0.55, 0.95)
                at = joints[0] + (crown - joints[0]) * t
                add_cone(
                    trunk_bm,
                    tuple(at),
                    r0 * 0.2,
                    0.05,
                    rng.uniform(2.5, 5.5),
                    sides=3,
                    tilt=_tilt_toward(dir_of(baz, rng.uniform(-0.15, 0.6))),
                )

    print(f"[island_gen] swamp trees: {trees} bare trees ({archers} archers, {snags} snags) - the dead forest, no leaves yet")
    return [object_from_bmesh("Swamp_Trees", trunk_bm, ["M_TrunkWood"])]


def build_swamp():
    objects = [
        build_swamp_base(),
        build_swamp_water(),
        *build_swamp_trees(),
        *build_swamp_cattails(),
        *build_swamp_smalls(),
    ]
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
    clear standing bubble at the spawn, stays out of every cut hole, and
    (unless `hollow_ok`) stays out of the ice overhang and the standable
    hollow beneath its cornice."""
    if not hollow_ok and _in_overhang(x, z, pad):
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


def build_frostmaw():
    base = build_island_base("Frostmaw_Base", ["M_Snow", "M_IceSheet", "M_IceWet"])
    ground = _ground_bvh(base)
    _ICE_SNOW["bm"] = None
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
        broke = head + axis * (height * 0.10)
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
        if k % 2 == 0:  # clear of the frame tops, not buried among them
            _WR_EXTRA_GLOW.append(tuple(frame @ Vector((length * 0.18, 0.0, rise * 1.15 + 1.4))) + (1.3,))
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
        broke = head + axis * (h * 0.06)  # the snapped-off topmast, hanging on
        tip = broke + Vector((axis.x, axis.y, 0)).normalized() * h * 0.30 - Vector((0, 0, h * 0.16))
        _wr_spar(bm, frame, broke, tip, h * 0.030, h * 0.014, sides=4)
        _WR_EXTRA_GLOW.append((x + head.x, y + head.y, z + head.z + 1.4, 1.35))
        made += 1

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

    for gx, gy, gz, gr in _WR_EXTRA_GLOW:
        _wr_orb(glow_bm, _wr_frame((gx, gy, gz)), (0, 0, 0), gr)
    _WR_EXTRA_GLOW.clear()

    print(f"[island_gen] wrecks: 3 in the bay + {beached} beached + {piles} debris piles")
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
        *build_dock("Wreckwater_Dock_Planks", "Wreckwater_Dock_Posts", "M_WreckPlank", "M_WreckPost"),
        build_foam("Wreckwater_Foam", "M_WreckFoam"),
    ]
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


# ---------------------------------------------------------------- island config
#
# Each entry overrides the shape-state globals for its island (an empty
# override leaves the tropical defaults, so `tropical` reproduces the original
# mesh) and names its build function. New islands prefix their object names.

# Islands to bundle into the one importable pack (assets/island_pack.glb), in
# order. Adding an island: give it an ISLANDS entry (with a "model" name) and
# add its id here.
ISLAND_ORDER = ["tropical", "volcano", "swamp", "ice", "gloom", "wreck", "maelstrom"]

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
            "ISLAND_RADIUS": 640,
            "SEGMENTS": 96,  # finer facets so the shattered rock reads on 900-stud cliffs
            # One material boundary: bare volcanic rock cone above, ash apron
            # (the walked ground) below.
            "GRASS_U": 0.70,
            "RINGS": [0.0, 0.05, 0.11, 0.155, 0.19, 0.25, 0.32, 0.40, 0.48, 0.56, 0.63, 0.70, 0.76, 0.82, 0.90, 1.0, 1.09, 1.28],
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
            "PROFILE": [
                (0.000, 830.0),  # crater dish floor
                (0.050, 836.0),
                (0.110, 852.0),  # inner crater wall
                (0.155, 895.0),  # the summit lip
                (0.190, 812.0),  # near-vertical under the lip
                (0.250, 655.0),
                (0.320, 492.0),
                (0.400, 338.0),
                (0.480, 215.0),
                (0.560, 122.0),
                (0.630, 62.0),
                (0.700, 27.0),  # cone meets the ash apron
                (0.760, 12.0),
                (0.820, 6.5),
                (0.900, 3.2),
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
            "RIM_FLAT": (0.72, 1.0),
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
            "NOTCH_BAND": (0.085, 0.175),  # the summit lip band (lip at u 0.155)
            # The broken asymmetric ridgeline around the summit.
            "PEAK_JAG": 28.0,
            "PEAK_TERMS": [(2, 0.8, 0.45), (3, 2.6, 0.35), (5, 1.1, 0.20)],
            "PREVIEW_SHOTS": [
                # Standing on the apron at the old spawn side, craning up at
                # the mountain; and the sail-in from the +Z sea.
                ("apron", (0.0, -560.0, 10.0), (0.0, 0.0, 460.0), 26),
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
                "M_TrunkWood": (0.55, 0.42, 0.30),  # smooth tan trunks (the reference look)
                "M_WillowLeaf": (0.20, 0.26, 0.17),  # drooping blades + hanging strands
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
