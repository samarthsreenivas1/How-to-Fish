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
                r *= 1 + noise.noise(Vector((math.cos(theta) * 6.0, math.sin(theta) * 6.0, u * 4.0))) * CRAG_RADIAL
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


def build_volcano_rocks(ground):
    """Obsidian rock, in three places: big angular boulders on the walkable ash
    apron at the foot (walked among), MASSIVE crag boulders jammed into the
    steep flanks (read from the beach as broken rock faces), and a crown of
    tall shattered spires around the summit crater so the silhouette is jagged
    all the way up. EVERY rock is dropped onto the real base-mesh surface
    (`ground` raycast) and seated slightly into it, so none float above the
    crags or hover over the jittered facets. All skip the lava channels and
    the dock corridor."""
    bm = bmesh.new()

    # Apron boulders + pebbles at the foot - the ground the player fights on.
    count = 0
    tries = 0
    while count < 300 and tries < 3000:
        tries += 1
        theta = random.uniform(0, math.tau)
        u = random.uniform(0.74, 0.985)
        if _near_dock_corridor(theta, u):
            continue
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        if not _clear_of_ponds(x, z, 1.0):
            continue
        surface = _drop_to_ground(ground, x, z)
        if surface is None:
            continue
        pebble = random.random() < 0.6
        s = random.uniform(1.2, 3.0) if pebble else random.uniform(4.5, 11.0)
        sz = s * random.uniform(0.5, 0.8)
        add_blob(
            bm,
            (x, z, surface - sz * 0.3),  # seated into the real surface, never hovering
            (s, s * random.uniform(0.7, 0.95), sz),
            0.48 if pebble else 0.42,
            500 + count * 3.7,
            yaw=random.uniform(0, math.tau),
        )
        count += 1

    # Flank crag boulders: huge shattered blocks jammed into the steep cone so
    # the slopes read as broken rock faces, not a smooth lathe. Sized to be
    # read from the beach hundreds of studs below.
    for i in range(34):
        theta = (i / 34) * math.tau + random.uniform(-0.1, 0.1)
        u = random.uniform(0.24, 0.62)
        if notch_cut(theta, min(u, 0.2)) > 2.0:
            continue  # keep the lava channels clear
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        surface = _drop_to_ground(ground, x, z)
        if surface is None:
            continue
        s = random.uniform(9.0, 22.0)
        sz = s * random.uniform(0.8, 1.3)
        add_blob(
            bm,
            (x, z, surface - sz * 0.4),
            (s, s * random.uniform(0.6, 0.9), sz),
            0.5,
            200 + i * 7.0,
            yaw=random.uniform(0, math.tau),
        )

    # Summit spires: a crown of tall angular shards around the crater lip so
    # the very top is a ragged fang line, skipping the notches the lava pours
    # through.
    for i in range(14):
        theta = (i / 14) * math.tau + random.uniform(-0.12, 0.12)
        u = random.uniform(0.155, 0.195)
        if notch_cut(theta, 0.17) > 2.0:
            continue
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        surface = _drop_to_ground(ground, x, z)
        if surface is None:
            continue
        s = random.uniform(6.0, 11.0)
        h = s * random.uniform(2.2, 3.4)  # tall shards, not round blobs
        add_blob(
            bm,
            (x, z, surface + h * 0.15),
            (s, s * 0.7, h),
            0.42,
            900 + i * 5.0,
            yaw=random.uniform(0, math.tau),
        )

    # Obsidian shards: small angular fangs stuck upright in the ash between
    # the boulders - glassy debris rained off the mountain.
    count = 0
    tries = 0
    while count < 70 and tries < 900:
        tries += 1
        theta = random.uniform(0, math.tau)
        u = random.uniform(0.73, 0.985)
        if _near_dock_corridor(theta, u):
            continue
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        if not _clear_of_ponds(x, z, 1.0):
            continue
        surface = _drop_to_ground(ground, x, z)
        if surface is None:
            continue
        s = random.uniform(0.9, 2.0)
        h = s * random.uniform(2.4, 3.6)
        add_blob(bm, (x, z, surface + h * 0.1), (s, s * 0.6, h), 0.4, 1500 + count * 4.3, yaw=random.uniform(0, math.tau))
        count += 1

    return object_from_bmesh("Volcano_Rocks", bm, ["M_Obsidian"])


def build_volcano_props(ground):
    """The 'random stuff' riddling the walkable apron (user, 2026-08-24;
    densified same day after "the base is barren"), in four single-material
    objects. The apron is ~530k sq studs, so a thin uniform sprinkle reads
    as empty - the props are GROUPED into landmarks a player walks between:
    BURNT GROVES of dead snags (plus loners), BASALT COLUMN fields, CINDER
    VENT clusters, and soft ASH DUNES, with heavy obsidian scree in
    build_volcano_rocks filling the ground between them. Everything raycasts
    the real surface, seats slightly into it, and keeps clear of the dock
    corridor and the molten ponds."""

    def apron_spot(pad=4.0, u_lo=0.73, u_hi=0.97):
        for _ in range(40):
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

    def spot_near(cx, cz, spread):
        """A ground point near a cluster's centre, still clear of ponds."""
        for _ in range(12):
            a = random.uniform(0, math.tau)
            d = random.uniform(0, spread)
            x, z = cx + math.cos(a) * d, cz + math.sin(a) * d
            if not _clear_of_ponds(x, z):
                continue
            surface = _drop_to_ground(ground, x, z)
            if surface is not None:
                return x, z, surface
        return None

    snag_bm = bmesh.new()

    def snag(x, z, surface, big=False):
        yaw = random.uniform(0, math.tau)
        tilt = (random.uniform(-0.09, 0.09), random.uniform(-0.09, 0.09))
        h = random.uniform(55.0, 75.0) if big else random.uniform(35.0, 60.0)
        base = Vector((x, z, surface - 1.5))
        add_cone(snag_bm, base, random.uniform(2.2, 3.4), 0.9, h, sides=6, tilt=tilt, yaw=yaw)
        axis = cone_axis(tilt, yaw)
        for _ in range(random.randint(2, 3)):
            frac = random.uniform(0.45, 0.85)
            joint = base + axis * (h * frac)
            b_yaw = random.uniform(0, math.tau)
            b_tilt = (random.uniform(0.9, 1.3), 0.0)  # near-horizontal snapped-off limbs
            add_cone(snag_bm, joint, 0.85, 0.25, random.uniform(12.0, 24.0), sides=5, tilt=b_tilt, yaw=b_yaw)

    # Ten burnt groves - a dead forest's stands - plus scattered loners.
    for _ in range(13):
        grove = apron_spot(pad=2.0)
        if grove is None:
            continue
        gx, gz, gs = grove
        snag(gx, gz, gs, big=True)  # every grove has one tall veteran
        for _ in range(random.randint(4, 7)):
            member = spot_near(gx, gz, random.uniform(14.0, 32.0))
            if member:
                snag(*member)
    for _ in range(18):
        loner = apron_spot()
        if loner:
            snag(*loner)

    basalt_bm = bmesh.new()
    for _ in range(24):
        spot = apron_spot(pad=2.5)
        if spot is None:
            continue
        cx, cz, _ = spot
        tallest = random.uniform(4.5, 9.0)
        for c in range(random.randint(4, 8)):
            a = random.uniform(0, math.tau)
            d = random.uniform(0, 3.6)
            x, z = cx + math.cos(a) * d, cz + math.sin(a) * d
            surface = _drop_to_ground(ground, x, z)
            if surface is None:
                continue
            # Tallest at the cluster's heart, stepping down outward.
            h = tallest * random.uniform(0.85, 1.0) * (1.0 - d * 0.16)
            add_post(basalt_bm, x, z, surface - 0.6, surface + max(1.6, h), random.uniform(0.9, 1.5), sides=6)

    vent_bm = bmesh.new()
    for _ in range(13):
        spot = apron_spot(pad=2.5)
        if spot is None:
            continue
        cx, cz, surface = spot
        rb = random.uniform(2.6, 4.4)
        add_cone(vent_bm, (cx, cz, surface - 0.5), rb, rb * random.uniform(0.35, 0.45), random.uniform(2.2, 4.8), sides=8)
        # Most fumaroles come with a smaller companion cone alongside.
        if random.random() < 0.7:
            mate = spot_near(cx, cz, rb + 3.5)
            if mate:
                mr = rb * random.uniform(0.45, 0.65)
                add_cone(vent_bm, (mate[0], mate[1], mate[2] - 0.4), mr, mr * 0.4, random.uniform(1.4, 2.6), sides=7)

    # Fine scree: hundreds of small angular obsidian chunks half-buried in
    # the ash - the ground clutter that makes the walk feel volcanic. Cheap
    # yawed boxes (12 tris each), so the count can be high.
    scree_bm = bmesh.new()
    placed_chunks = 0
    tries = 0
    while placed_chunks < 460 and tries < 4600:
        tries += 1
        theta = random.uniform(0, math.tau)
        u = random.uniform(0.73, 0.985)
        if _near_dock_corridor(theta, u):
            continue
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        if not _clear_of_ponds(x, z, 1.0):
            continue
        surface = _drop_to_ground(ground, x, z)
        if surface is None:
            continue
        s = random.uniform(0.5, 1.6)
        add_box(
            scree_bm,
            (x, z, surface + s * 0.1),  # half-buried
            (s, s * random.uniform(0.6, 0.9), s * random.uniform(0.5, 0.8)),
            yaw=random.uniform(0, math.tau),
        )
        placed_chunks += 1

    # Soft ash dunes: broad smooth mounds that give the flat apron rolling
    # ground to walk over (blob roughness kept low so they read as drifts,
    # not rocks).
    dune_bm = bmesh.new()
    for i in range(32):
        spot = apron_spot(pad=8.0, u_lo=0.74, u_hi=0.96)
        if spot is None:
            continue
        x, z, surface = spot
        s = random.uniform(7.0, 16.0)
        add_blob(
            dune_bm,
            (x, z, surface - s * 0.12),
            (s, s * random.uniform(0.55, 0.8), s * random.uniform(0.18, 0.28)),
            0.12,
            3000 + i * 11.0,
            yaw=random.uniform(0, math.tau),
        )

    return (
        object_from_bmesh("Volcano_DeadTrees", snag_bm, ["M_Charred"]),
        object_from_bmesh("Volcano_Basalt", basalt_bm, ["M_Basalt"]),
        object_from_bmesh("Volcano_Vents", vent_bm, ["M_Cinder"]),
        object_from_bmesh("Volcano_Scree", scree_bm, ["M_Obsidian"]),
        object_from_bmesh("Volcano_Dunes", dune_bm, ["M_VolAsh"]),
    )


def build_volcano_dock():
    """The fishing dock at the BOTTOM of the volcano: an ordinary shore jetty
    (the tropical build_dock machinery, sized by the DOCK_* overrides) that
    runs off the ash beach out INTO THE SEA - the player fishes ocean water
    here, exactly like the starter's dock (user, 2026-08-24: no lava under or
    around the dock; the lava ponds inland are where volcano-water fish come
    from). Object names / materials are the volcano's own (Volcano_Dock_Planks
    / _Posts), which WorldService already colours. DOCK_POST_POSITIONS is left
    populated so build_foam collars the posts standing in the surf."""
    return build_dock("Volcano_Dock_Planks", "Volcano_Dock_Posts", "M_VolPlank", "M_VolPost")


# Summit-crater lava surface height, and the lake disc's relative radius. The
# surface sits below the crater lip everywhere except the carved notches, so
# the lake pours out only through those gashes and runs the full flank.
LAVA_LEVEL = 40.0
LAKE_U = 0.36

# Terminal ponds of the flows, recorded by build_lava as (x, y, radius) so the
# apron scatter (rocks, props) can keep clear of the molten pools. These pools
# are the volcano island's fishable lava now that the dock is over the sea.
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


def _lava_flow(bm, theta0, ground):
    """One lava flow from the summit-crater notch at `theta0` down the WHOLE
    flank. Marches from the crater lip to the foot, riding just above the
    REAL faceted surface (`ground` raycast at the centre and both edges -
    the analytic height_at + crag() disagrees with the mesh by tens of studs
    because of the per-ring radial jitter, which buried earlier flows in the
    slope), never climbing. Every flow ends in a molten pond on the apron -
    lava never reaches the sea (user, 2026-08-24: the dock and the water
    around it are plain ocean)."""
    u_end = random.uniform(0.78, 0.84)
    steps = 40  # dense: the straight strip between samples must not dip behind crag bulges
    us = [0.145 + (u_end - 0.145) * (i / (steps - 1)) for i in range(steps)]
    theta = theta0
    left, right = [], []
    last_h = LAVA_LEVEL + 0.4  # emerges from the crater lake surface
    for i, u in enumerate(us):
        if i > 0:
            theta += random.uniform(-0.03, 0.03)  # slight wander
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        frac = i / (steps - 1)
        w = 4.0 + 11.0 * frac  # wide rivers, not trickles
        perp = Vector((-math.sin(theta), math.cos(theta), 0))
        if i == 0:
            h = last_h
        else:
            samples = []
            for px, py in ((x, z), (x + perp.x * w, z + perp.y * w), (x - perp.x * w, z - perp.y * w)):
                s = _drop_to_ground(ground, px, py)
                samples.append(s if s is not None else height_at(px, py) + crag(px, py, u) - notch_cut(theta, u))
            h = min(max(samples) + 2.2, last_h - 0.4)  # lava only ever runs downhill
        last_h = h
        left.append(Vector((x, z, h)) + perp * w)
        right.append(Vector((x, z, h)) - perp * w)
    add_strip_slab(bm, left, right, 1.5)
    return theta, us[-1], last_h


def build_lava(ground):
    """Lava lives in three places, all one Volcano_Lava object (the name is
    the fishable-surface contract): the summit crater LAKE, the flows pouring
    out of its NOTCHES down the whole flank, and the molten PONDS where they
    die on the apron - the ponds are the island's fishable lava (the dock is
    over plain sea). `ground` is the base mesh's BVH; the flows raycast it to
    hug the real faceted slope."""
    bm = bmesh.new()
    LAVA_PONDS.clear()

    # Summit crater lake, contained below the lip; jagged edge so its shore
    # isn't a clean circle.
    seg = 36
    lake = []
    for s in range(seg):
        theta = (s / seg) * math.tau
        r = ring_radius(LAKE_U, theta) * (1 + 0.06 * math.sin(5 * theta + 1.0))
        lake.append((math.cos(theta) * r, math.sin(theta) * r))
    add_disc_slab(bm, lake, LAVA_LEVEL, SLAB_THICKNESS)

    # One full-flank flow per crater notch. Each flow then SPREADS across the
    # base as a cascade of 2-3 broad overlapping pools stepping outward and
    # downhill, joined by short wide spill strips - so molten sheets thread a
    # good part of the apron instead of one tidy pond per corner. Every pool
    # is fishable lava, and every pool is recorded in LAVA_PONDS.
    for a0, _half, _depth in NOTCHES:
        end_theta, end_u, end_h = _lava_flow(bm, a0, ground)
        ptheta, pu, ph = end_theta, end_u, end_h
        prev_center = None
        for k in range(random.randint(2, 3)):
            r = ring_radius(pu, ptheta)
            x, z = math.cos(ptheta) * r, math.sin(ptheta) * r
            if k > 0:
                # Each later pool sits on its own ground, a step lower.
                ph = min(ph - 0.6, height_at(x, z) + 1.2)
            pr = random.uniform(17.0, 28.0) * (1.0 - 0.15 * k)
            # Thick slab: the apron slopes, so a thin disc would leave its
            # downhill edge hovering.
            _jagged_disc(bm, x, z, pr, pr * random.uniform(0.7, 0.95), ph - 0.2, 4.5, salt=ptheta + k)
            LAVA_PONDS.append((x, z, pr))
            if prev_center is not None:
                # A wide spill strip joining this pool to the one above it.
                px, pz, pph = prev_center
                seg = Vector((x - px, z - pz, 0))
                if seg.length > 1:
                    perp = Vector((-seg.y, seg.x, 0)).normalized() * random.uniform(5.0, 8.0)
                    a_pt = Vector((px, pz, pph - 0.3))
                    b_pt = Vector((x, z, ph - 0.3))
                    add_strip_slab(bm, [a_pt + perp, b_pt + perp], [a_pt - perp, b_pt - perp], 2.5)
            prev_center = (x, z, ph)
            ptheta += random.uniform(-0.07, 0.07)
            pu = min(0.955, pu + random.uniform(0.05, 0.085))

    return object_from_bmesh("Volcano_Lava", bm, ["M_Lava"])


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


def print_volcano_handoff():
    """The numbers the Luau side needs by hand (Islands.luau volcano entry,
    World.luau dock constants), printed in ROBLOX coordinates relative to the
    island's origin: Roblox X = Blender x, Roblox Z = -Blender y (the glTF
    Y-up export's mapping), heights unchanged."""
    theta = math.radians(DOCK_ANGLE_DEG)
    d = Vector((math.cos(theta), math.sin(theta), 0))
    start_r = ring_radius(DOCK_START_U, theta)
    sx, sy = d.x * start_r, d.y * start_r
    ex, ey = d.x * (start_r + DOCK_LENGTH), d.y * (start_r + DOCK_LENGTH)
    print(f"[island_gen] HANDOFF dock start (Roblox rel) X={sx:.1f} Z={-sy:.1f}, end X={ex:.1f} Z={-ey:.1f}, plank top Y={DOCK_TOP}")

    spawn_bx, spawn_by = 0.0, -505.0  # Islands.luau spawn (rel X=0, Z=505) in Blender coords
    print(f"[island_gen] HANDOFF spawn (rel X=0 Z=505) ground Y~{height_at(spawn_bx, spawn_by):.1f} (+-1.8 beach noise; runtime probe stands the player)")

    lips = []
    for s in range(180):
        t = (s / 180) * math.tau
        if notch_cut(t, 0.155) > 2.0:
            continue  # a spillway gash, not the lip
        lips.append(profile_height(0.155) + peak_jag(t, 0.155))
    rim_r = sum(ring_radius(0.155, (s / 90) * math.tau) for s in range(90)) / 90
    lake_r = sum(ring_radius(LAKE_U, (s / 90) * math.tau) for s in range(90)) / 90
    print(
        f"[island_gen] HANDOFF crater rim height {min(lips):.0f}-{max(lips):.0f} (ragged), radius ~{rim_r:.0f}; "
        f"summit lake Y={LAVA_LEVEL} radius ~{lake_r:.0f}; apron shelf ~y {profile_height(0.9):.1f} at u 0.90 "
        f"(boundary-sampler ring: crag-free, tolerance ~4 works)"
    )


def build_volcano():
    base = build_island_base("Volcano_Base", ["M_VolRock", "M_VolAsh", "M_VolWet"])
    ground = _ground_bvh(base)  # raycast target so every rock seats on the real surface
    objects = [
        base,
        # Lava first: it records LAVA_PONDS, which the rock/prop scatter
        # keeps clear of.
        build_lava(ground),
        build_volcano_rocks(ground),
        *build_volcano_props(ground),
        *build_volcano_dock(),
        build_foam("Volcano_Foam", "M_VolFoam"),
    ]
    print_volcano_handoff()
    return objects


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


def build_swamp_water(ground):
    """The fen's murky pools - the island's fishable water (waters="swamp").
    A dozen broad, ragged peat pools threaded through the interior, plus a few
    narrow joining channels, all ONE object: Swamp_Water is the contract name
    World.FISHABLE_NAMES keys on."""
    bm = bmesh.new()
    LAVA_PONDS.clear()
    chains = 5
    for c in range(chains):
        theta = (c / chains) * math.tau + random.uniform(-0.25, 0.25)
        u = random.uniform(0.18, 0.34)
        prev = None
        for k in range(random.randint(2, 3)):
            if _near_dock_corridor(theta, u):
                theta += 0.35
            r = ring_radius(u, theta)
            x, z = math.cos(theta) * r, math.sin(theta) * r
            ground_h = _drop_to_ground(ground, x, z)
            if ground_h is None:
                ground_h = height_at(x, z)
            # The pool surface floats just over the peat it drowned.
            top = ground_h + 0.45
            pr = random.uniform(14.0, 24.0)
            _pool_disc(bm, x, z, pr, top, 3.0, salt=theta * 3 + k)
            if prev is not None:
                px, pz, ph = prev
                seg = Vector((x - px, z - pz, 0))
                if seg.length > 1:
                    perp = Vector((-seg.y, seg.x, 0)).normalized() * random.uniform(3.0, 5.0)
                    a_pt = Vector((px, pz, ph - 0.1))
                    b_pt = Vector((x, z, top - 0.1))
                    add_strip_slab(bm, [a_pt + perp, b_pt + perp], [a_pt - perp, b_pt - perp], 2.0)
            prev = (x, z, top)
            theta += random.uniform(-0.2, 0.2)
            u += random.uniform(0.1, 0.16)
    print(f"[island_gen] swamp water: {len(LAVA_PONDS)} pools")
    return object_from_bmesh("Swamp_Water", bm, ["M_SwampWater"])


def build_swamp_trees(ground):
    """Bald-cypress stands: a tapered trunk flaring at the foot, knee roots
    breaking the mud around it, and a wide flat moss canopy in two greens.
    Trunks/knees and canopies are separate objects so each keeps one material."""
    trunk_bm = bmesh.new()
    canopy_bm = bmesh.new()
    placed = 0
    for _ in range(60):
        spot = _interior_spot(ground, 0.10, 0.60, pad=2.0)
        if spot is None:
            continue
        x, z, surface = spot
        h = random.uniform(20.0, 34.0)
        yaw = random.uniform(0, math.tau)
        tilt = (random.uniform(-0.06, 0.06), random.uniform(-0.06, 0.06))
        add_cone(trunk_bm, (x, z, surface - 1.2), random.uniform(2.4, 3.2), 0.8, h, sides=7, tilt=tilt, yaw=yaw)
        for _ in range(random.randint(3, 5)):  # the knees
            a = random.uniform(0, math.tau)
            d = random.uniform(2.2, 5.0)
            kx, kz = x + math.cos(a) * d, z + math.sin(a) * d
            ks = _drop_to_ground(ground, kx, kz)
            if ks is None:
                continue
            add_cone(trunk_bm, (kx, kz, ks - 0.4), random.uniform(0.5, 0.9), 0.2, random.uniform(1.4, 2.8), sides=5)
        axis = cone_axis(tilt, yaw)
        crown = Vector((x, z, surface - 1.2)) + axis * h
        # Two stacked, flattened canopy pads - the classic cypress table-top.
        s = random.uniform(9.0, 14.0)
        add_blob(canopy_bm, (crown.x, crown.y, crown.z - 1.0), (s, s * 0.85, s * 0.30), 0.35, 40 + placed * 3.1, yaw)
        add_blob(
            canopy_bm,
            (crown.x + random.uniform(-2, 2), crown.y + random.uniform(-2, 2), crown.z + s * 0.16),
            (s * 0.62, s * 0.55, s * 0.24),
            0.35,
            41 + placed * 3.1,
            yaw,
        )
        placed += 1
        if placed >= 26:
            break
    print(f"[island_gen] swamp trees: {placed} cypress")
    return (
        object_from_bmesh("Swamp_Trunks", trunk_bm, ["M_Cypress"]),
        object_from_bmesh("Swamp_Canopy", canopy_bm, ["M_Moss"]),
    )


def build_swamp_props(ground):
    """Reed brakes around the pools, half-sunk root snags, and mud hummocks."""
    reed_bm = bmesh.new()
    for px, py, pr in list(LAVA_PONDS):
        for _ in range(random.randint(6, 10)):
            a = random.uniform(0, math.tau)
            d = pr + random.uniform(1.0, 5.0)
            x, z = px + math.cos(a) * d, py + math.sin(a) * d
            surface = _drop_to_ground(ground, x, z)
            if surface is None:
                continue
            for _ in range(random.randint(3, 6)):  # one brake = a few stems
                ox, oz = x + random.uniform(-1.6, 1.6), z + random.uniform(-1.6, 1.6)
                add_post(reed_bm, ox, oz, surface - 0.3, surface + random.uniform(2.4, 4.6), 0.16, sides=4)

    snag_bm = bmesh.new()
    for _ in range(16):
        spot = _interior_spot(ground, 0.12, 0.72, pad=1.0)
        if spot is None:
            continue
        x, z, surface = spot
        yaw = random.uniform(0, math.tau)
        tilt = (random.uniform(0.5, 1.1), 0.0)  # mostly toppled
        add_cone(snag_bm, (x, z, surface - 0.8), random.uniform(1.2, 2.0), 0.4, random.uniform(9.0, 17.0), sides=6, tilt=tilt, yaw=yaw)

    hummock_bm = bmesh.new()
    for i in range(46):
        spot = _interior_spot(ground, 0.08, 0.85, pad=1.0, tries=12)
        if spot is None:
            continue
        x, z, surface = spot
        s = random.uniform(2.0, 5.0)
        add_blob(hummock_bm, (x, z, surface - s * 0.35), (s, s * 0.8, s * 0.5), 0.4, 700 + i * 4.7, yaw=random.uniform(0, math.tau))

    return (
        object_from_bmesh("Swamp_Reeds", reed_bm, ["M_Reed"]),
        object_from_bmesh("Swamp_Snags", snag_bm, ["M_RootWood"]),
        object_from_bmesh("Swamp_Hummocks", hummock_bm, ["M_MudMound"]),
    )


def build_swamp():
    base = build_island_base("Swamp_Base", ["M_Peat", "M_Mud", "M_WetMud"])
    ground = _ground_bvh(base)
    objects = [
        base,
        build_swamp_water(ground),  # first: records the keep-clear pools
        *build_swamp_trees(ground),
        *build_swamp_props(ground),
        *build_dock("Swamp_Dock_Planks", "Swamp_Dock_Posts", "M_SwampPlank", "M_SwampPost"),
        build_foam("Swamp_Foam", "M_SwampFoam"),
    ]
    a = math.radians(DOCK_ANGLE_DEG)
    start_r = ring_radius(DOCK_START_U, a)
    print(f"[island_gen] HANDOFF swamp: dock start (Roblox rel) X=0 Z={start_r:.0f}, spawn suggestion X=0 Z={start_r - 18:.0f} ground Y~{height_at(0, -(start_r - 18)):.1f}")
    return objects


# ---- Frostmaw Reach -------------------------------------------------------


def build_ice_holes(ground):
    """The frozen shelf's fishing holes - fixed, pre-cut discs of black-blue
    water in the ice, each collared by chunked rim ice. One object,
    Frostmaw_IceHoles: the fishable-surface contract name (waters="ice")."""
    bm = bmesh.new()
    LAVA_PONDS.clear()
    placed = 0
    for _ in range(140):
        if placed >= 13:
            break
        theta = random.uniform(0, math.tau)
        u = random.uniform(0.58, 0.90)
        if _near_dock_corridor(theta, u):
            continue
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        if not _clear_of_ponds(x, z, 14.0):  # holes keep well apart
            continue
        surface = _drop_to_ground(ground, x, z)
        if surface is None:
            continue
        hr = random.uniform(5.0, 8.5)
        _pool_disc(bm, x, z, hr, surface + 0.25, 2.2, salt=x * 0.13 + z * 0.07, squash=random.uniform(0.85, 1.0))
        placed += 1
    print(f"[island_gen] ice holes: {placed}")
    return object_from_bmesh("Frostmaw_IceHoles", bm, ["M_IceWater"])


def build_ice_rims(ground):
    """Chunked ice collars around every hole + scattered sheet debris."""
    bm = bmesh.new()
    for px, py, pr in list(LAVA_PONDS):
        for i in range(random.randint(5, 8)):
            a = random.uniform(0, math.tau)
            d = pr + random.uniform(0.6, 2.2)
            x, z = px + math.cos(a) * d, py + math.sin(a) * d
            surface = _drop_to_ground(ground, x, z)
            if surface is None:
                continue
            s = random.uniform(1.0, 2.4)
            add_blob(bm, (x, z, surface - s * 0.2), (s, s * 0.7, s * 0.6), 0.42, 300 + i * 3.3 + px * 0.1, yaw=random.uniform(0, math.tau))
    for i in range(60):
        spot = _interior_spot(ground, 0.56, 0.95, pad=2.0, tries=12)
        if spot is None:
            continue
        x, z, surface = spot
        s = random.uniform(0.8, 2.0)
        add_blob(bm, (x, z, surface - s * 0.3), (s, s * 0.8, s * 0.5), 0.45, 900 + i * 5.1, yaw=random.uniform(0, math.tau))
    return object_from_bmesh("Frostmaw_RimIce", bm, ["M_GlacialIce"])


def build_ice_seracs(ground):
    """The glacial heart: a crown of leaning blue seracs on the central ridge,
    big shattered bergs at its skirts, and tall shard pairs out on the sheet
    marking the horizon. All pale glacial ice."""
    bm = bmesh.new()
    for i in range(16):
        theta = (i / 16) * math.tau + random.uniform(-0.15, 0.15)
        u = random.uniform(0.06, 0.30)
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        surface = _drop_to_ground(ground, x, z)
        if surface is None:
            continue
        s = random.uniform(4.5, 9.0)
        h = s * random.uniform(2.0, 3.2)
        add_blob(bm, (x, z, surface + h * 0.1), (s, s * 0.65, h), 0.4, 100 + i * 6.1, yaw=random.uniform(0, math.tau))
    for i in range(20):
        spot = _interior_spot(ground, 0.30, 0.52, pad=3.0, tries=15)
        if spot is None:
            continue
        x, z, surface = spot
        s = random.uniform(3.5, 8.0)
        add_blob(bm, (x, z, surface - s * 0.3), (s, s * 0.75, s * random.uniform(0.7, 1.1)), 0.45, 400 + i * 4.9, yaw=random.uniform(0, math.tau))
    for i in range(10):
        spot = _interior_spot(ground, 0.60, 0.88, pad=6.0, tries=15)
        if spot is None:
            continue
        x, z, surface = spot
        s = random.uniform(1.6, 3.0)
        h = s * random.uniform(2.6, 4.0)
        add_blob(bm, (x, z, surface + h * 0.12), (s, s * 0.6, h), 0.4, 800 + i * 7.7, yaw=random.uniform(0, math.tau))
        add_blob(bm, (x + s * 1.6, z + s * 0.8, surface + h * 0.05), (s * 0.6, s * 0.5, h * 0.6), 0.4, 801 + i * 7.7)
    return object_from_bmesh("Frostmaw_Seracs", bm, ["M_GlacialIce"])


def build_ice_rocks(ground):
    """Frost-dark rock breaking the white: outcrops near the ridge and a few
    snow-dusted boulders on the sheet, plus stark dead trees by the shore."""
    rock_bm = bmesh.new()
    for i in range(30):
        spot = _interior_spot(ground, 0.16, 0.60, pad=2.0, tries=15)
        if spot is None:
            continue
        x, z, surface = spot
        s = random.uniform(2.5, 7.0)
        add_blob(rock_bm, (x, z, surface - s * 0.35), (s, s * 0.8, s * 0.7), 0.48, 600 + i * 3.9, yaw=random.uniform(0, math.tau))

    snag_bm = bmesh.new()
    for _ in range(9):
        spot = _interior_spot(ground, 0.86, 0.97, pad=1.0, tries=15)
        if spot is None:
            continue
        x, z, surface = spot
        yaw = random.uniform(0, math.tau)
        tilt = (random.uniform(-0.12, 0.12), random.uniform(-0.12, 0.12))
        h = random.uniform(12.0, 22.0)
        base = Vector((x, z, surface - 1.0))
        add_cone(snag_bm, base, random.uniform(1.0, 1.6), 0.35, h, sides=5, tilt=tilt, yaw=yaw)
        axis = cone_axis(tilt, yaw)
        for _ in range(random.randint(1, 3)):
            joint = base + axis * (h * random.uniform(0.5, 0.85))
            add_cone(snag_bm, joint, 0.4, 0.12, random.uniform(4.0, 9.0), sides=4, tilt=(random.uniform(0.9, 1.3), 0.0), yaw=random.uniform(0, math.tau))
    return (
        object_from_bmesh("Frostmaw_Rocks", rock_bm, ["M_FrostRock"]),
        object_from_bmesh("Frostmaw_Snags", snag_bm, ["M_FrostWood"]),
    )


def build_frostmaw():
    base = build_island_base("Frostmaw_Base", ["M_Snow", "M_IceSheet", "M_IceWet"])
    ground = _ground_bvh(base)
    objects = [
        base,
        build_ice_holes(ground),  # first: records keep-clear circles
        build_ice_rims(ground),
        build_ice_seracs(ground),
        *build_ice_rocks(ground),
        *build_dock("Frostmaw_Dock_Planks", "Frostmaw_Dock_Posts", "M_FrostPlank", "M_FrostPost"),
        build_foam("Frostmaw_Foam", "M_FrostFoam"),
    ]
    a = math.radians(DOCK_ANGLE_DEG)
    start_r = ring_radius(DOCK_START_U, a)
    print(f"[island_gen] HANDOFF frostmaw: dock start (Roblox rel) X=0 Z={start_r:.0f}, spawn suggestion X=0 Z={start_r - 18:.0f} ground Y~{height_at(0, -(start_r - 18)):.1f}")
    return objects


# ---- Gloomtrench ----------------------------------------------------------


def build_gloom_water(ground):
    """The trench shelf's lightless pools (waters="gloom"): near-black water
    sunk between the basalt shelves. One object, Gloomtrench_DarkWater."""
    bm = bmesh.new()
    LAVA_PONDS.clear()
    placed = 0
    for _ in range(120):
        if placed >= 8:
            break
        theta = random.uniform(0, math.tau)
        u = random.uniform(0.22, 0.62)
        if _near_dock_corridor(theta, u):
            continue
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        if not _clear_of_ponds(x, z, 10.0):
            continue
        ground_h = _drop_to_ground(ground, x, z)
        if ground_h is None:
            continue
        pr = random.uniform(13.0, 22.0)
        _pool_disc(bm, x, z, pr, ground_h + 0.4, 3.4, salt=x * 0.11 + placed)
        placed += 1
    print(f"[island_gen] gloom water: {placed} pools")
    return object_from_bmesh("Gloomtrench_DarkWater", bm, ["M_DarkWater"])


def build_gloom_spires(ground):
    """The trench-rock skyline: a ring of tall black fins around the crown and
    clusters of leaning shards over the shelf."""
    bm = bmesh.new()
    for i in range(14):
        theta = (i / 14) * math.tau + random.uniform(-0.14, 0.14)
        u = random.uniform(0.05, 0.22)
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        surface = _drop_to_ground(ground, x, z)
        if surface is None:
            continue
        s = random.uniform(3.5, 7.0)
        h = s * random.uniform(2.4, 3.8)
        add_blob(bm, (x, z, surface + h * 0.1), (s, s * 0.55, h), 0.42, 150 + i * 6.3, yaw=random.uniform(0, math.tau))
    for i in range(26):
        spot = _interior_spot(ground, 0.24, 0.80, pad=2.5, tries=14)
        if spot is None:
            continue
        x, z, surface = spot
        s = random.uniform(1.6, 4.6)
        h = s * random.uniform(1.4, 2.6)
        add_blob(bm, (x, z, surface - s * 0.2), (s, s * 0.7, h), 0.46, 500 + i * 4.1, yaw=random.uniform(0, math.tau))
    return object_from_bmesh("Gloomtrench_Spires", bm, ["M_GloomRock"])


def build_gloom_glow(ground):
    """The bioluminescence that carries the island's identity: lantern stalks
    (a thin stem with a glowing bulb), glow-anemone clusters at the pool rims,
    and drifting glow kelp fronds. Bulbs/anemones in cyan, kelp in violet -
    two objects so each keeps one flat glow colour."""
    stalk_bm = bmesh.new()
    cyan_bm = bmesh.new()
    violet_bm = bmesh.new()

    for px, py, pr in list(LAVA_PONDS):
        for _ in range(random.randint(3, 5)):
            a = random.uniform(0, math.tau)
            d = pr + random.uniform(1.0, 4.0)
            x, z = px + math.cos(a) * d, py + math.sin(a) * d
            surface = _drop_to_ground(ground, x, z)
            if surface is None:
                continue
            s = random.uniform(0.8, 1.8)
            add_blob(cyan_bm, (x, z, surface + s * 0.2), (s, s, s * 0.9), 0.35, 60 + x * 0.1, yaw=random.uniform(0, math.tau))

    stalks = 0
    for _ in range(40):
        spot = _interior_spot(ground, 0.18, 0.82, pad=1.5, tries=12)
        if spot is None:
            continue
        x, z, surface = spot
        h = random.uniform(7.0, 14.0)
        add_post(stalk_bm, x, z, surface - 0.4, surface + h, 0.28, sides=5)
        add_blob(cyan_bm, (x, z, surface + h + 0.8), (1.2, 1.2, 1.5), 0.3, 70 + stalks * 2.9)
        stalks += 1
        if stalks >= 22:
            break

    for i in range(30):
        spot = _interior_spot(ground, 0.20, 0.86, pad=1.0, tries=10)
        if spot is None:
            continue
        x, z, surface = spot
        for _ in range(random.randint(2, 4)):
            ox, oz = x + random.uniform(-2.0, 2.0), z + random.uniform(-2.0, 2.0)
            add_cone(violet_bm, (ox, oz, surface - 0.3), 0.35, 0.08, random.uniform(3.2, 6.4), sides=4, tilt=(random.uniform(-0.2, 0.2), random.uniform(-0.2, 0.2)), yaw=random.uniform(0, math.tau))

    return (
        object_from_bmesh("Gloomtrench_Stalks", stalk_bm, ["M_GloomStalk"]),
        object_from_bmesh("Gloomtrench_GlowCyan", cyan_bm, ["M_GlowCyan"]),
        object_from_bmesh("Gloomtrench_GlowViolet", violet_bm, ["M_GlowViolet"]),
    )


def build_gloomtrench():
    base = build_island_base("Gloomtrench_Base", ["M_GloomRock", "M_GloomSand", "M_GloomWet"])
    ground = _ground_bvh(base)
    objects = [
        base,
        build_gloom_water(ground),
        build_gloom_spires(ground),
        *build_gloom_glow(ground),
        *build_dock("Gloomtrench_Dock_Planks", "Gloomtrench_Dock_Posts", "M_GloomPlank", "M_GloomPost"),
        build_foam("Gloomtrench_Foam", "M_GloomFoam"),
    ]
    a = math.radians(DOCK_ANGLE_DEG)
    start_r = ring_radius(DOCK_START_U, a)
    print(f"[island_gen] HANDOFF gloomtrench: dock start (Roblox rel) X=0 Z={start_r:.0f}, spawn suggestion X=0 Z={start_r - 18:.0f} ground Y~{height_at(0, -(start_r - 18)):.1f}")
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


def _wreck_hull(wood_bm, glow_bm, cx, cy, yaw, length, beam, deck_h, ghost=False):
    """One broken galleon: keel slab, two flank walls, an angled bow pair, a
    stern board, a leaning snapped mast with a yard, and (for the ghost ships)
    a pale glow strip along the gunwale."""
    d = Vector((math.cos(yaw), math.sin(yaw), 0))
    p = Vector((-d.y, d.x, 0))
    half = length / 2
    wall_h = random.uniform(4.5, 6.5)
    # Keel / sunken deck.
    add_box(wood_bm, (cx, cy, deck_h - 0.6), (length * 0.9, beam * 0.8, 1.2), yaw)
    # Flank walls.
    for side in (1, -1):
        wx = cx + p.x * (beam / 2) * side
        wy = cy + p.y * (beam / 2) * side
        add_box(wood_bm, (wx, wy, deck_h + wall_h / 2), (length * random.uniform(0.62, 0.8), 1.0, wall_h), yaw)
        if ghost:
            add_box(glow_bm, (wx, wy, deck_h + wall_h + 0.25), (length * 0.6, 0.5, 0.35), yaw)
    # Bow: two short walls angling to a point.
    bow = Vector((cx, cy, 0)) + d * half
    for side in (1, -1):
        ba = yaw + side * 0.5
        bd = Vector((math.cos(ba), math.sin(ba), 0))
        bx = bow.x - bd.x * length * 0.12
        by = bow.y - bd.y * length * 0.12
        add_box(wood_bm, (bx, by, deck_h + wall_h * 0.45), (length * 0.26, 0.9, wall_h * 0.9), ba)
    # Stern board.
    stern = Vector((cx, cy, 0)) - d * half * 0.86
    add_box(wood_bm, (stern.x, stern.y, deck_h + wall_h * 0.55), (1.1, beam * 0.9, wall_h * 1.1), yaw)
    # Snapped mast + yard.
    mast_h = random.uniform(14.0, 24.0)
    tilt = (random.uniform(0.08, 0.3), 0.0)
    m_yaw = yaw + random.uniform(-0.6, 0.6)
    base = Vector((cx, cy, deck_h - 0.5)) - d * length * 0.1
    add_cone(wood_bm, base, 0.8, 0.3, mast_h, sides=6, tilt=tilt, yaw=m_yaw)
    axis = cone_axis(tilt, m_yaw)
    joint = base + axis * (mast_h * 0.7)
    add_cone(wood_bm, joint, 0.35, 0.15, random.uniform(7.0, 12.0), sides=4, tilt=(1.35, 0.0), yaw=yaw + random.uniform(0, math.tau))


def build_wrecks(ground):
    """The fleet: hulks foundered in the bay (half-drowned), one heeled on the
    rim beach, and drift-plank litter. The two ghost ships carry the pale
    gunwale glow the island is named for."""
    wood_bm = bmesh.new()
    glow_bm = bmesh.new()

    bay_r = LAVA_PONDS[0][2] if LAVA_PONDS else 60.0
    dock_a = math.radians(DOCK_ANGLE_DEG)
    placed = 0
    for i in range(10):
        if placed >= 5:
            break
        a = random.uniform(0, math.tau)
        if abs(((a - dock_a + math.pi) % math.tau) - math.pi) < 0.5:
            continue  # keep the channel open
        d = random.uniform(bay_r * 0.25, bay_r * 0.8)
        x, z = math.cos(a) * d, math.sin(a) * d
        floor_h = _drop_to_ground(ground, x, z)
        if floor_h is None:
            continue
        deck_h = max(floor_h + 0.8, random.uniform(-1.6, 0.6))  # half-drowned
        _wreck_hull(wood_bm, glow_bm, x, z, random.uniform(0, math.tau), random.uniform(26.0, 40.0), random.uniform(8.0, 12.0), deck_h, ghost=placed < 2)
        placed += 1

    # One hulk heeled over on the rim beach.
    spot = _interior_spot(ground, 0.78, 0.9, pad=2.0, tries=30)
    if spot is not None:
        x, z, surface = spot
        _wreck_hull(wood_bm, glow_bm, x, z, random.uniform(0, math.tau), 30.0, 9.0, surface + 0.6)

    # Drift-plank litter on the rim and beach.
    for i in range(70):
        spot = _interior_spot(ground, 0.5, 0.97, pad=0.5, tries=8)
        if spot is None:
            continue
        x, z, surface = spot
        add_box(wood_bm, (x, z, surface + 0.15), (random.uniform(2.4, 5.0), random.uniform(0.7, 1.2), 0.35), random.uniform(0, math.tau))

    print(f"[island_gen] wrecks: {placed} in the bay + 1 beached")
    return (
        object_from_bmesh("Wreckwater_Hulks", wood_bm, ["M_HullWood"]),
        object_from_bmesh("Wreckwater_GhostGlow", glow_bm, ["M_GhostGlow"]),
    )


def build_wreck_rocks(ground):
    """Grave-grey sea stacks on the rim + shore boulders."""
    bm = bmesh.new()
    for i in range(12):
        theta = (i / 12) * math.tau + random.uniform(-0.2, 0.2)
        if abs(((theta - math.radians(DOCK_ANGLE_DEG) + math.pi) % math.tau) - math.pi) < 0.35:
            continue
        u = random.uniform(0.55, 0.7)
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        surface = _drop_to_ground(ground, x, z)
        if surface is None:
            continue
        s = random.uniform(3.0, 6.0)
        h = s * random.uniform(1.6, 2.6)
        add_blob(bm, (x, z, surface + h * 0.05), (s, s * 0.7, h), 0.44, 210 + i * 5.9, yaw=random.uniform(0, math.tau))
    for i in range(28):
        spot = _interior_spot(ground, 0.6, 0.96, pad=1.5, tries=10)
        if spot is None:
            continue
        x, z, surface = spot
        s = random.uniform(1.4, 3.6)
        add_blob(bm, (x, z, surface - s * 0.3), (s, s * 0.8, s * 0.6), 0.46, 640 + i * 4.3, yaw=random.uniform(0, math.tau))
    return object_from_bmesh("Wreckwater_Rocks", bm, ["M_GraveRock"])


def build_wreckwater():
    base = build_island_base("Wreckwater_Base", ["M_BayFloor", "M_WreckSand", "M_WreckWet"])
    ground = _ground_bvh(base)
    objects = [
        base,
        build_wreck_bay(ground),  # first: records the bay keep-clear circle
        *build_wrecks(ground),
        build_wreck_rocks(ground),
        *build_dock("Wreckwater_Dock_Planks", "Wreckwater_Dock_Posts", "M_WreckPlank", "M_WreckPost"),
        build_foam("Wreckwater_Foam", "M_WreckFoam"),
    ]
    a = math.radians(DOCK_ANGLE_DEG)
    start_r = ring_radius(DOCK_START_U, a)
    print(f"[island_gen] HANDOFF wreckwater: dock start (Roblox rel) X=0 Z={start_r:.0f}, spawn suggestion X=0 Z={start_r - 18:.0f} ground Y~{height_at(0, -(start_r - 18)):.1f}")
    return objects


# ---------------------------------------------------------------- island config
#
# Each entry overrides the shape-state globals for its island (an empty
# override leaves the tropical defaults, so `tropical` reproduces the original
# mesh) and names its build function. New islands prefix their object names.

# Islands to bundle into the one importable pack (assets/island_pack.glb), in
# order. Adding an island: give it an ISLANDS entry (with a "model" name) and
# add its id here.
ISLAND_ORDER = ["tropical", "volcano", "swamp", "ice", "gloom", "wreck"]

ISLANDS = {
    "tropical": {"model": "Island", "overrides": {}, "build": build_tropical},
    "volcano": {
        "model": "Volcano",
        "overrides": {
            # A TOWERING stratovolcano (2026-08-24 redesign, replacing the
            # walkable-rim caldera): the peak is ~940 studs up - a colossal
            # jagged spire you never climb. The PLAYABLE area is the flat ash
            # apron around the foot at sea level, littered with volcanic
            # props (dead snags, basalt columns, cinder vents, obsidian) and
            # the flows' molten ponds; the fishing dock is a plain shore
            # jetty into the SEA. Radius stays capped at 640 so the base mesh
            # stays under Roblox's 2048-stud import limit (at 850 the base
            # was 2508 wide and could not be imported); height 940 + skirt 9
            # is comfortably under the same cap.
            "ISLAND_RADIUS": 640,
            "SEGMENTS": 64,  # facets stay big on a cone this size regardless
            "GRASS_U": 0.70,  # basalt cone above, ash apron below
            "RINGS": [
                0.0, 0.045, 0.075, 0.105, 0.14,  # crater floor -> lip -> outer drop
                0.19, 0.25, 0.32, 0.40, 0.48, 0.56, 0.63,  # the huge flank
                0.70, 0.76, 0.82, 0.90, 1.0, 1.09, 1.28,  # apron -> shore -> skirt
            ],  # fmt: skip
            # Concave stratovolcano silhouette with a WIDE, ragged crater
            # mouth (~150 studs across): crater floor, steep inner wall,
            # the summit lip, then near-vertical outer walls easing into the
            # walkable apron. Steepness is the drama - the cone drops ~770
            # studs in ~350 horizontal. PEAK_JAG below breaks the lip and
            # shoulders into an asymmetric ridgeline (+-~70 studs), so the
            # rim is 935 +- the jag, not one clean height.
            "PROFILE": [
                (0.000, 828.0),  # crater floor (under the summit lava lake)
                (0.075, 828.0),
                (0.110, 882.0),  # inner crater wall
                (0.155, 935.0),  # the summit lip
                (0.205, 800.0),  # outer drop, near-vertical
                (0.250, 640.0),
                (0.320, 470.0),
                (0.400, 320.0),
                (0.480, 205.0),
                (0.560, 122.0),
                (0.630, 64.0),
                (0.700, 30.0),  # cone meets the ash apron
                (0.760, 13.0),
                (0.820, 7.0),
                (0.900, 3.8),
                (1.000, 1.2),  # shore: ~0.5 studs of rise per 10 approaching the waterline, matching the starter so the tide reads
                (1.090, -1.8),
                (1.280, SKIRT_BOTTOM),
            ],
            # Crag is suppressed across the apron (the ground the player
            # actually walks) - the flanks and summit keep every stud of it.
            "RIM_FLAT": (0.70, 1.0),
            # The notches carve the SUMMIT crater lip, not the apron.
            "NOTCH_BAND": (0.10, 0.21),
            "LAVA_LEVEL": 838.0,  # summit lake, just below the 935 lip
            "LAKE_U": 0.115,  # laps the inner crater wall; ~150-stud-wide lake
            # The broken ridgeline: three incommensurate angular waves, up to
            # ~70 studs of rise/fall around the crater mouth and shoulders.
            "PEAK_JAG": 70.0,
            "PEAK_TERMS": [(2, 0.8, 0.45), (3, 2.6, 0.35), (5, 1.1, 0.20)],
            # Very jagged: strong outline wobble + heavy broad crag on the
            # flanks + radial jitter, so the cone reads as shattered rock.
            "COAST_TERMS": [(2, 1.0, 0.12), (3, 3.0, 0.09), (5, 0.5, 0.07), (8, 2.0, 0.06)],
            "GRASS_TERMS": [(2, 0.9, 0.06), (4, 1.5, 0.05)],
            "CRAG": 56.0,  # huge broken-rock relief at this scale
            "CRAG_FREQ": 0.012,  # broad features, read from the beach far below
            "CRAG_RADIAL": 0.14,
            # Five gashes in the crater lip - "lava flowing everywhere": one
            # full-flank flow pours out of each, dying in a pond on the apron.
            # None faces the dock (270): the sea in front of the planks stays
            # plain ocean (user, 2026-08-24).
            # Depths must drop the 935 lip below the 838 lake (>97), and
            # peak_jag is zeroed inside each notch window so a high ridge
            # beside a gash can't seal it.
            "NOTCHES": [
                (math.radians(320), math.radians(16), 135.0),
                (math.radians(15), math.radians(12), 122.0),
                (math.radians(80), math.radians(10), 118.0),
                (math.radians(150), math.radians(13), 128.0),
                (math.radians(205), math.radians(10), 120.0),
            ],
            # The fishing dock: a plain shore jetty into the SEA (build_dock
            # machinery) at the same Roblox +Z angle as the tropical dock,
            # starting near the shoreline (the island is huge, so
            # DOCK_START_U must sit close to 1.0 for the planks to reach open
            # water).
            "DOCK_ANGLE_DEG": 270,
            "DOCK_START_U": 0.97,
            "DOCK_LENGTH": 110.0,  # long enough to clear the shoreline and end well out over open sea
            "DOCK_WIDTH": 14.0,
            "DOCK_END_LENGTH": 20.0,
            "DOCK_END_WIDTH": 30.0,
            "DOCK_MIN_TOP": 2.6,  # a normal shore-dock deck; no lava to clear any more
            "DOCK_POST_SPACING": 8.0,
            "DOCK_POST_BOTTOM": -6.0,
            "COLORS": {
                "M_VolRock": (0.17, 0.16, 0.19),  # dark basalt cone
                "M_VolAsh": (0.31, 0.28, 0.28),  # ash apron
                "M_VolWet": (0.20, 0.19, 0.21),  # wet ash rim
                "M_Obsidian": (0.09, 0.09, 0.12),  # apron boulders
                "M_Lava": (1.00, 0.42, 0.06),  # glowing lava
                "M_VolFoam": (0.85, 0.85, 0.89),  # pale wet rim / steam
                "M_VolPlank": (0.46, 0.31, 0.22),  # dock planks (warm charred wood)
                "M_VolPost": (0.30, 0.20, 0.15),  # dock posts
                "M_Charred": (0.10, 0.085, 0.08),  # dead burnt snags
                "M_Basalt": (0.14, 0.15, 0.185),  # hex column clusters
                "M_Cinder": (0.24, 0.20, 0.19),  # fumarole vent cones
            },
        },
        "build": build_volcano,
    },
    # ---- Blackmire Fen (revamp island 2). A low, waterlogged peat fen:
    # barely any rise, lobed muddy coastline, murky pool chains inland
    # (Swamp_Water - the fishable "swamp" surface), bald-cypress stands,
    # reed brakes and toppled root snags. The dock is the standard +Z sea
    # jetty; the ocean off it fishes as plain ocean.
    "swamp": {
        "model": "Swamp",
        "overrides": {
            "ISLAND_RADIUS": 180,
            "SEGMENTS": 72,
            "GRASS_U": 0.66,
            "RINGS": [0.0, 0.10, 0.20, 0.30, 0.40, 0.52, 0.66, 0.78, 0.88, 0.95, 1.0, 1.09, 1.28],
            # Flat as standing water allows: the whole interior is ~2-5 studs
            # up, so the pools sit IN the ground rather than perched on it.
            "PROFILE": [
                (0.00, 5.2),
                (0.25, 4.6),
                (0.40, 4.0),
                (0.52, 3.4),
                (0.66, 2.4),
                (0.78, 1.6),
                (0.88, 1.1),
                (1.00, 0.6),
                (1.09, -1.8),
                (1.28, SKIRT_BOTTOM),
            ],
            # A heavily lobed, creeky coastline - fingers of mud and water.
            "COAST_TERMS": [(2, 0.7, 0.13), (3, 2.9, 0.10), (5, 1.6, 0.08), (9, 0.4, 0.045)],
            "GRASS_TERMS": [(2, 1.1, 0.05), (4, 2.3, 0.04)],
            "DOCK_ANGLE_DEG": 270,
            "DOCK_START_U": 0.90,
            "DOCK_LENGTH": 42.0,
            "DOCK_WIDTH": 10.0,
            "DOCK_END_LENGTH": 13.0,
            "DOCK_END_WIDTH": 20.0,
            "DOCK_MIN_TOP": 2.4,
            "DOCK_POST_SPACING": 7.0,
            "DOCK_POST_BOTTOM": -6.0,
            "COLORS": {
                "M_Peat": (0.239, 0.302, 0.196),  # dark waterlogged moss-peat
                "M_Mud": (0.396, 0.333, 0.235),  # the mud "beach"
                "M_WetMud": (0.290, 0.247, 0.184),
                "M_SwampWater": (0.216, 0.302, 0.235),  # opaque murk - you can't see what's biting
                "M_Cypress": (0.357, 0.278, 0.196),
                "M_Moss": (0.325, 0.451, 0.243),
                "M_Reed": (0.545, 0.529, 0.302),
                "M_RootWood": (0.259, 0.208, 0.157),
                "M_MudMound": (0.337, 0.294, 0.216),
                "M_SwampPlank": (0.451, 0.369, 0.251),  # slick, darker planks than the starter's
                "M_SwampPost": (0.310, 0.251, 0.176),
                "M_SwampFoam": (0.851, 0.878, 0.831),  # scummy pale rim, not white surf
            },
        },
        "build": build_swamp,
    },
    # ---- Frostmaw Reach (revamp island 3). A glacial shelf: a blue serac
    # ridge at the heart, a flat white ice sheet the player walks - punched
    # with fixed fishing holes (Frostmaw_IceHoles, the "ice" surface) - and
    # frost-dark rock breaking through. RIM_FLAT keeps the sheet walkable
    # while the ridge keeps its crags.
    "ice": {
        "model": "Frostmaw",
        "overrides": {
            "ISLAND_RADIUS": 230,
            "SEGMENTS": 72,
            "GRASS_U": 0.52,
            "RINGS": [0.0, 0.08, 0.16, 0.26, 0.38, 0.52, 0.64, 0.76, 0.86, 0.94, 1.0, 1.09, 1.28],
            "PROFILE": [
                (0.00, 26.0),  # the glacial ridge
                (0.12, 22.0),
                (0.26, 14.0),
                (0.38, 8.6),
                (0.52, 6.2),  # ridge foot -> the sheet
                (0.64, 5.4),
                (0.76, 4.8),
                (0.86, 3.6),
                (0.94, 2.2),
                (1.00, 1.0),
                (1.09, -1.8),
                (1.28, SKIRT_BOTTOM),
            ],
            # Sheared berg-like coast: long straight-ish faces, few lobes.
            "COAST_TERMS": [(2, 0.4, 0.10), (3, 1.9, 0.07), (7, 3.3, 0.05)],
            "GRASS_TERMS": [(2, 0.6, 0.05), (5, 1.4, 0.03)],
            # Crags on the ridge only; the sheet the player fights on is flat.
            "CRAG": 7.0,
            "CRAG_FREQ": 0.03,
            "CRAG_RADIAL": 0.05,
            "RIM_FLAT": (0.52, 1.0),
            "DOCK_ANGLE_DEG": 270,
            "DOCK_START_U": 0.92,
            "DOCK_LENGTH": 46.0,
            "DOCK_WIDTH": 10.0,
            "DOCK_END_LENGTH": 14.0,
            "DOCK_END_WIDTH": 20.0,
            "DOCK_MIN_TOP": 2.4,
            "DOCK_POST_SPACING": 7.5,
            "DOCK_POST_BOTTOM": -6.0,
            "COLORS": {
                "M_Snow": (0.918, 0.937, 0.957),
                "M_IceSheet": (0.780, 0.851, 0.902),  # the walked (and fished) shelf
                "M_IceWet": (0.639, 0.729, 0.812),
                "M_IceWater": (0.071, 0.129, 0.216),  # the black-blue water in the holes
                "M_GlacialIce": (0.588, 0.749, 0.878),  # seracs / bergs / hole collars
                "M_FrostRock": (0.267, 0.290, 0.329),
                "M_FrostWood": (0.518, 0.494, 0.463),  # bleached dead shore trees
                "M_FrostPlank": (0.557, 0.478, 0.376),
                "M_FrostPost": (0.404, 0.337, 0.263),
                "M_FrostFoam": (0.941, 0.965, 0.980),
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
            "GRASS_U": 0.60,
            "RINGS": [0.0, 0.10, 0.20, 0.32, 0.46, 0.60, 0.72, 0.82, 0.90, 0.96, 1.0, 1.09, 1.28],
            "PROFILE": [
                (0.00, 16.0),
                (0.20, 12.0),
                (0.32, 8.6),
                (0.46, 6.0),
                (0.60, 4.2),
                (0.72, 3.0),
                (0.82, 2.2),
                (0.90, 1.5),
                (1.00, 0.7),
                (1.09, -1.8),
                (1.28, SKIRT_BOTTOM),
            ],
            "COAST_TERMS": [(2, 1.7, 0.11), (4, 0.6, 0.08), (6, 2.8, 0.06)],
            "GRASS_TERMS": [(3, 0.8, 0.05)],
            "CRAG": 4.5,
            "CRAG_FREQ": 0.04,
            "CRAG_RADIAL": 0.06,
            "RIM_FLAT": (0.46, 0.96),  # the walkable shelf band
            "DOCK_ANGLE_DEG": 270,
            "DOCK_START_U": 0.90,
            "DOCK_LENGTH": 44.0,
            "DOCK_WIDTH": 10.0,
            "DOCK_END_LENGTH": 13.0,
            "DOCK_END_WIDTH": 20.0,
            "DOCK_MIN_TOP": 2.4,
            "DOCK_POST_SPACING": 7.0,
            "DOCK_POST_BOTTOM": -6.0,
            "COLORS": {
                "M_GloomRock": (0.129, 0.125, 0.165),  # near-black basalt
                "M_GloomSand": (0.204, 0.196, 0.243),  # ashen violet-grey shore
                "M_GloomWet": (0.157, 0.153, 0.196),
                "M_DarkWater": (0.024, 0.043, 0.086),  # all but black
                "M_GloomStalk": (0.231, 0.243, 0.298),
                "M_GlowCyan": (0.290, 0.937, 0.878),  # the lantern bulbs / anemones
                "M_GlowViolet": (0.663, 0.416, 0.937),  # the kelp fronds
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
                "M_WreckSand": (0.667, 0.639, 0.557),  # bone-grey sand
                "M_WreckWet": (0.518, 0.494, 0.427),
                "M_BayWater": (0.086, 0.196, 0.216),  # deep still teal
                "M_HullWood": (0.216, 0.180, 0.145),  # rotten black-brown timbers
                "M_GhostGlow": (0.678, 0.945, 0.769),  # the pale sea-fire on the ghost ships
                "M_GraveRock": (0.353, 0.361, 0.376),
                "M_WreckGrass": (0.443, 0.502, 0.373),  # dull sage rim grass
                "M_WreckPlank": (0.475, 0.404, 0.310),
                "M_WreckPost": (0.329, 0.271, 0.204),
                "M_WreckFoam": (0.882, 0.906, 0.894),
            },
        },
        "build": build_wreckwater,
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

    # If the island pours lava, add two more shots: a close look at the dock
    # over the delta (the fishing spot), and a full-tower postcard from out
    # at sea - the shot that says "really really tall".
    if NOTCHES:
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
