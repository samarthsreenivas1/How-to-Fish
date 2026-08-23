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

# Walkable rim: (u_lo, u_hi) band where the profile is a flat plateau and
# vertical crag is suppressed, so the crater rim reads as a wide, level ring a
# player can stand on and fish off into the lava. None = no flat rim (tropical).
RIM_FLAT = None

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
    lo, hi = RIM_FLAT if RIM_FLAT is not None else (0.34, 0.50)
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
            ring.append(bm.verts.new(Vector((x, z, height_at(x, z) + crag(x, z, u) - notch_cut(theta, u)))))
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
    hit = ground.ray_cast(Vector((x, z, 500.0)), Vector((0.0, 0.0, -1.0)))
    return hit[0].z if hit[0] is not None else None


def build_volcano_rocks(ground):
    """Obsidian rock, in two places: big angular boulders on the flat apron at
    the foot (island-scaled, read from afar), AND a dense scatter of rocks and
    pebbles riddling the walkable crater rim (human-scaled, walked among) so the
    top reads as broken volcanic ground, not a clean ring. EVERY rock is dropped
    onto the real base-mesh surface (`ground` raycast) and seated slightly into
    it, so none float above the crags or hover over the jittered facets. Both
    skip the lava spillway channels so nothing sits over a notch."""
    bm = bmesh.new()

    # Apron boulders at the foot.
    for i in range(16):
        theta = (i / 16) * math.tau + random.uniform(-0.18, 0.18)
        u = random.uniform(0.80, 0.98)  # the flat apron, not the cone
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        surface = _drop_to_ground(ground, x, z)
        if surface is None:
            continue
        s = random.uniform(2.2, 4.6) * SCALE
        sz = s * 0.7
        # Seat it a touch into the ground so it reads as resting, never floating.
        add_blob(bm, (x, z, surface - sz * 0.35), (s, s * 0.85, sz), 0.44, 200 + i * 7.0, yaw=random.uniform(0, math.tau))

    # Rim scatter: lots of small pebbles + some chunkier rocks across the flat
    # walkable ring.
    lo, hi = RIM_FLAT if RIM_FLAT is not None else (0.34, 0.46)
    count = 0
    tries = 0
    while count < 130 and tries < 1200:
        tries += 1
        theta = random.uniform(0, math.tau)
        u = random.uniform(lo + 0.01, hi - 0.01)
        if notch_cut(theta, u) > 2.0:
            continue  # don't strand a rock over a lava spillway channel
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        surface = _drop_to_ground(ground, x, z)
        if surface is None:
            continue
        pebble = random.random() < 0.68
        s = random.uniform(0.6, 2.0) if pebble else random.uniform(2.5, 6.0)
        rough = 0.5 if pebble else 0.42
        sz = s * random.uniform(0.5, 0.8)
        add_blob(
            bm,
            (x, z, surface - sz * 0.3),  # seated into the real surface, never hovering
            (s, s * random.uniform(0.7, 0.95), sz),
            rough,
            500 + count * 3.7,
            yaw=random.uniform(0, math.tau),
        )
        count += 1

    return object_from_bmesh("Volcano_Rocks", bm, ["M_Obsidian"])


def build_volcano_dock():
    """A plank fishing pier at the TOP of the volcano: it starts at the crater
    rim and runs INWARD out over the lava lake, so you walk off the rim and cast
    straight down into the lava. Elevated at rim height on tall obsidian posts
    that stand down in the lava, with a wider platform at the far end. Named and
    materialled like the old shore dock (Volcano_Dock_Planks / _Posts) so
    WorldService colours it unchanged - only its position moved."""
    DOCK_POST_POSITIONS.clear()  # a rim pier has no water-foam collars

    theta = math.radians(300)  # a clear stretch of rim, away from the notches (35, 205)
    direction = Vector((math.cos(theta), math.sin(theta), 0))  # outward radial
    r_in = ring_radius(0.34, theta)  # rim inner edge (top of the fishing cliff)
    origin = direction * r_in

    length = 130.0  # how far it reaches inward over the lava
    width = 16.0
    end_length = 24.0
    end_width = 30.0
    deck_top = 198.0  # just below the rim top (~200) so you step straight onto it
    post_bottom = 150.0  # down into the lava lake (surface ~165)

    plank_bm, post_bm = bmesh.new(), bmesh.new()

    plank_thick = 0.45
    plank_w = 1.25
    plank_gap = 0.22
    plank_z = deck_top - plank_thick / 2
    stringer_h = 0.55
    stringer_z = deck_top - plank_thick - stringer_h / 2
    main_len = length - end_length

    pitch = plank_w + plank_gap
    count = int(length / pitch)
    for i in range(count):
        t = pitch * (i + 0.5)
        w = width if t < main_len else end_width
        ln = w + random.uniform(-0.25, 0.35)
        add_box(
            plank_bm,
            (random.uniform(-0.08, 0.08), t, plank_z + random.uniform(-0.03, 0.03)),
            (ln, plank_w, plank_thick),
            yaw=random.uniform(-0.025, 0.025),
        )

    for sx in (-width / 2 + 0.8, width / 2 - 0.8):
        add_box(plank_bm, (sx, main_len / 2, stringer_z), (0.7, main_len, stringer_h))
    for sx in (-end_width / 2 + 0.8, end_width / 2 - 0.8):
        add_box(plank_bm, (sx, main_len + end_length / 2, stringer_z), (0.7, end_length, stringer_h))

    bollard_h = 1.4
    post_r = 0.55
    cap_r = 0.72
    cap_h = 0.3
    spacing = 9.0

    def post(x, t):
        top = deck_top + bollard_h
        add_post(post_bm, x, t, post_bottom, top, post_r)
        add_post(post_bm, x, t, top - 0.02, top + cap_h, cap_r)

    t = 1.0
    while t < main_len - 1.5:
        for x in (-width / 2 + 0.35, width / 2 - 0.35):
            post(x, t)
        t += spacing
    for x in (-end_width / 2 + 0.45, end_width / 2 - 0.45):
        post(x, main_len + 0.6)
        post(x, length - 0.6)

    t = 1.0
    while t < main_len - 1.5:
        add_box(post_bm, (0.0, t, stringer_z - stringer_h / 2 - 0.3), (width - 0.4, 0.6, 0.6))
        t += spacing

    # Local +y must point INWARD (toward the crater centre) = -direction. In
    # build_dock, Rotation(theta - pi/2) sends local +y outward; add pi (use
    # +pi/2) to flip it inward instead. z stays absolute (origin's z is 0).
    phi = theta + math.pi / 2
    world = Matrix.Translation(origin) @ Matrix.Rotation(phi, 4, "Z")
    for bm in (plank_bm, post_bm):
        bmesh.ops.transform(bm, matrix=world, verts=bm.verts[:])

    print(f"[island_gen] volcano dock: rim pier at 300 deg, deck y={deck_top}, reaches {length:.0f} inward over the lava")
    return (
        object_from_bmesh("Volcano_Dock_Planks", plank_bm, ["M_VolPlank"]),
        object_from_bmesh("Volcano_Dock_Posts", post_bm, ["M_VolPost"]),
    )


# Lava-lake surface height, and the lake disc's relative radius. The surface
# sits below the rim everywhere except the carved notches, so it's a contained
# lake that only pours out of the notches. LAKE_U is set a hair inside the rim
# so the lava laps against the base of the inner cliff you fish off.
LAVA_LEVEL = 40.0
LAKE_U = 0.36


def _lava_outflow(bm, theta0):
    """One lava flow pouring out of a rim notch and SPREADING into a fan as it
    runs down the outer slope. Starts at the lake surface in the notch and
    follows the carved channel down. Rides just above the surface (crags and
    the notch cut) so rock never hides it."""
    us = [0.30, 0.40, 0.50, 0.62, 0.74, 0.85, 0.92]
    theta = theta0
    left, right = [], []
    for i, u in enumerate(us):
        theta += random.uniform(-0.05, 0.05)  # slight wander
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        if i == 0:
            h = LAVA_LEVEL + 0.3  # emerges from the lake surface at the notch
        else:
            h = height_at(x, z) + crag(x, z, u) - notch_cut(theta, u) + 0.9
        frac = i / (len(us) - 1)
        w = (1.0 + 3.5 * frac) * SCALE  # narrow at the notch, fanning out downslope
        perp = Vector((-math.sin(theta), math.cos(theta), 0))
        left.append(Vector((x, z, h)) + perp * w)
        right.append(Vector((x, z, h)) - perp * w)
    add_strip_slab(bm, left, right, 0.7)


def build_lava():
    """Lava lives in exactly two places (user rule): the crater LAKE, and the
    fans pouring out of the rim NOTCHES. The lake sits below the rim
    everywhere except those notches, so it never rides over the whole lip."""
    bm = bmesh.new()

    # Crater lake, contained below the rim; jagged edge so its shore isn't a
    # clean circle either.
    seg = 44
    lake = []
    for s in range(seg):
        theta = (s / seg) * math.tau
        r = ring_radius(LAKE_U, theta) * (1 + 0.05 * math.sin(6 * theta + 1.0))
        lake.append((math.cos(theta) * r, math.sin(theta) * r))
    add_disc_slab(bm, lake, LAVA_LEVEL, SLAB_THICKNESS)

    # One spreading flow per rim notch - and nowhere else.
    for a0, _half, _depth in NOTCHES:
        _lava_outflow(bm, a0)

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


def build_volcano():
    base = build_island_base("Volcano_Base", ["M_VolRock", "M_VolAsh", "M_VolWet"])
    ground = _ground_bvh(base)  # raycast target so every rock seats on the real surface
    return [
        base,
        build_volcano_rocks(ground),
        build_lava(),
        *build_volcano_dock(),
        build_foam("Volcano_Foam", "M_VolFoam"),
    ]


# ---------------------------------------------------------------- island config
#
# Each entry overrides the shape-state globals for its island (an empty
# override leaves the tropical defaults, so `tropical` reproduces the original
# mesh) and names its build function. New islands prefix their object names.

# Islands to bundle into the one importable pack (assets/island_pack.glb), in
# order. Adding an island: give it an ISLANDS entry (with a "model" name) and
# add its id here.
ISLAND_ORDER = ["tropical", "volcano"]

ISLANDS = {
    "tropical": {"model": "Island", "overrides": {}, "build": build_tropical},
    "volcano": {
        "model": "Volcano",
        "overrides": {
            # A huge volcano whose crater RIM is itself the playable area - a
            # wide, flat, walkable ring (~100 studs across, a ~1,600-stud loop)
            # with ample room to walk around AND fight, that you also fish off
            # straight down into the lava lake it encircles. Radius is capped at
            # 640 so the base mesh stays under Roblox's 2048-stud import limit
            # (at 850 the base was 2508 wide and could not be imported).
            "ISLAND_RADIUS": 640,
            "SEGMENTS": 54,  # more facets so the huge rim ring is smooth to walk
            "GRASS_U": 0.76,
            "RINGS": [
                0.0, 0.12, 0.20, 0.26, 0.30,
                0.32, 0.38, 0.44, 0.48,  # the flat walkable rim plateau
                0.56, 0.66, 0.76, 0.85, 0.93, 1.0, 1.09, 1.28,
            ],  # fmt: skip
            # A towering caldera: a broad crater basin holds a big lava lake
            # (~500 studs across) at height 165. A short, steep inner cliff
            # jumps from the lake up to the rim at 200, which then holds DEAD
            # FLAT (u 0.32 -> 0.48, ~135 studs wide) as the walkable ring,
            # before the outer flank plunges to a big apron. You stand on the
            # flat 200 rim and fish ~35 studs down into the lake.
            "PROFILE": [
                (0.00, 135.0),  # crater basin floor (under the lava)
                (0.18, 135.0),
                (0.26, 145.0),
                (0.30, 172.0),  # inner cliff begins
                (0.32, 200.0),  # rim inner edge - top of the fishing cliff
                (0.40, 200.0),  # rim plateau - FLAT, walkable
                (0.48, 200.0),  # rim outer edge
                (0.56, 135.0),  # steep outer upper flank
                (0.66, 80.0),
                (0.76, 38.0),  # apron begins
                (0.85, 15.0),
                (0.93, 5.0),
                (1.00, 0.6),
                (1.09, -1.8),
                (1.28, SKIRT_BOTTOM),
            ],
            "RIM_FLAT": (0.32, 0.48),  # flatten profile + crag across this band
            "LAVA_LEVEL": 165.0,
            "LAKE_U": 0.30,  # lava laps the base of the inner cliff
            # Very jagged flanks, not a circle: strong multi-frequency outline
            # wobble plus heavy crag + radial jitter (broken-rock slopes and a
            # ragged crater mouth). The rim plateau stays flat (RIM_FLAT).
            "COAST_TERMS": [(2, 1.0, 0.12), (3, 3.0, 0.09), (5, 0.5, 0.07), (8, 2.0, 0.06)],
            "GRASS_TERMS": [(2, 0.9, 0.06), (4, 1.5, 0.05)],
            "CRAG": 20.0,  # bold jaggedness at this scale
            "CRAG_FREQ": 0.016,  # broad crag features, not fine noise
            "CRAG_RADIAL": 0.11,
            # Two spillway notches cut through the walkable rim (different
            # sizes) - the only places lava pours out. Depth drops the 200 rim
            # below the 165 lake there, so it overflows through the gap.
            "NOTCHES": [
                (math.radians(35), math.radians(18), 60.0),
                (math.radians(205), math.radians(14), 54.0),
            ],
            # The dock is a rim fishing pier (build_volcano_dock) that runs
            # inward over the lava from the crater rim - not a shore jetty - so
            # it needs no DOCK_* shore knobs; its geometry is self-contained.
            "COLORS": {
                "M_VolRock": (0.17, 0.16, 0.19),  # dark basalt cone
                "M_VolAsh": (0.31, 0.28, 0.28),  # ash apron
                "M_VolWet": (0.20, 0.19, 0.21),  # wet ash rim
                "M_Obsidian": (0.09, 0.09, 0.12),  # apron boulders
                "M_Lava": (1.00, 0.42, 0.06),  # glowing lava
                "M_VolFoam": (0.85, 0.85, 0.89),  # pale wet rim / steam
                "M_VolPlank": (0.46, 0.31, 0.22),  # dock planks (warm charred wood)
                "M_VolPost": (0.30, 0.20, 0.15),  # dock posts
            },
        },
        "build": build_volcano,
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

    # If the island has a walkable crater rim, add a shot standing ON it,
    # looking inward and down across the lava lake - the fishing vantage.
    if RIM_FLAT is not None and NOTCHES:
        lo, hi = RIM_FLAT
        rim_u = (lo + hi) / 2
        a = math.radians(300)  # stand at the rim dock, looking down the pier over the lava
        outward = Vector((math.cos(a), math.sin(a), 0))
        r_rim = ring_radius(rim_u, a)
        rim_top = profile_height(rim_u)
        cam.data.lens = 26
        # Eye at head height on the rim; the near rim edge frames the bottom,
        # the lava lake fills the middle, the far crater wall closes the back.
        eye = outward * r_rim + Vector((0, 0, rim_top + 6.0))
        target = -outward * (r_rim * 0.45) + Vector((0, 0, LAVA_LEVEL - 4.0))
        cam.location = eye
        cam.rotation_euler = (target - eye).to_track_quat("-Z", "Y").to_euler()
        rim_png = os.path.splitext(out_png)[0] + "_rim.png"
        scene.render.filepath = rim_png
        bpy.ops.render.render(write_still=True)
        print(f"[island_gen] rim view rendered to {rim_png}")


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
