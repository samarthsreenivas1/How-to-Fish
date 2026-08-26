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

# One angular sector where the vertical crag is DAMPED: (centre rad, half-width
# rad, strength 0-1). The volcano uses it to calm the face its switchback trail
# is cut into, so the path benches into believable ground while the rest of the
# cone stays shattered. None = untouched (every other island).
CRAG_CALM = None

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


# ---------------------------------------------------------------- the climb
#
# A switchback trail cut into the flank: the route from the ash apron (right
# where the dock lands) up to the crater lip. Written in polar as a sinusoid in
# ANGLE over a radius that only ever shrinks, so the plan view is a true zigzag
# with rounded hairpins and the climb is monotonic. Every cross-section is dead
# level (both edges share one deck height) so it is genuinely standable, and
# the deck is benched off the ground through the middle of its own width - half
# cut, half fill, the way a mountain road is built - so the ledge reads as cut
# into the slope with the slab's thickness as its retaining wall. Both ends sit
# on the dock bearing, and CRAG_CALM quiets the crag across the same face.
TRAIL_CENTER_DEG = 270.0  # the dock/spawn bearing: the climb starts where you land
TRAIL_SWING_DEG = 42.0
TRAIL_LEGS = 7  # half-cycles of the sinusoid = number of straight-ish legs
TRAIL_PHASE = math.pi / 2  # puts BOTH ends of the zigzag on the dock bearing
TRAIL_R_START = 450.0
TRAIL_R_END = 126.0  # lands on the crater lip shoulder
TRAIL_HALF = 11.5  # half-width of the walking surface
TRAIL_LANDING = 10.0  # extra half-width at each hairpin (a wide turn platform)
TRAIL_SAMPLES = 240
TRAIL_THICK = 14.0

# Filled by build_volcano_terraces, read by every prop scatter so nothing is
# dropped on the path: (x, y, clearance radius).
TRAIL_FOOTPRINTS = []


def _off_trail(x, z, extra=0.0):
    for tx, ty, rad in TRAIL_FOOTPRINTS:
        if math.hypot(x - tx, z - ty) < rad + extra:
            return False
    return True


def _trail_centerline(ground):
    """(centre point, half-width, deck height) sampled along the whole route."""
    c = math.radians(TRAIL_CENTER_DEG)
    swing = math.radians(TRAIL_SWING_DEG)
    pts, halves, decks = [], [], []
    for i in range(TRAIL_SAMPLES):
        t = i / (TRAIL_SAMPLES - 1)
        phase = math.pi * TRAIL_LEGS * t + TRAIL_PHASE
        theta = c + swing * math.cos(phase)
        # A slightly non-linear march inward: the legs bunch as the cone
        # narrows, the way a real switchback road does, and it breaks the
        # even "venetian blind" spacing the linear version read as head-on.
        r = TRAIL_R_START + (TRAIL_R_END - TRAIL_R_START) * (t**1.22)
        turn = abs(math.cos(phase)) ** 8  # ~1 only in the hairpins
        half = TRAIL_HALF + TRAIL_LANDING * turn
        pts.append((math.cos(theta) * r, math.sin(theta) * r))
        halves.append(half)
        # Deck height from the HIGHEST ground across the middle of the bench,
        # so a crag bulge can never break up through the walking surface.
        peak = -math.inf
        for k in (-0.55, -0.28, 0.0, 0.28, 0.55):
            r_s = r + half * k
            g = _drop_to_ground(ground, math.cos(theta) * r_s, math.sin(theta) * r_s)
            peak = max(peak, g if g is not None else height_at(math.cos(theta) * r_s, math.sin(theta) * r_s))
        decks.append(peak)

    def blur(vals, win):
        out = []
        for i in range(len(vals)):
            lo, hi = max(0, i - win), min(len(vals), i + win + 1)
            out.append(sum(vals[lo:hi]) / (hi - lo))
        return out

    # Smooth the facet-to-facet jitter into a clean ramp, then lift the deck
    # back over anything the averaging cut through.
    smooth = blur(decks, 7)
    return pts, halves, blur([max(smooth[i], decks[i]) + 1.4 for i in range(len(decks))], 5)


def build_volcano_terraces(ground):
    """The switchback ledge: one continuous ribbon solid up the flank, with a
    wide landing at every hairpin (somewhere to stand and fight when an
    eruption raid catches you mid-climb) and a broad platform where it tops out
    on the crater lip."""
    bm = bmesh.new()
    TRAIL_FOOTPRINTS.clear()

    pts, halves, decks = _trail_centerline(ground)
    n = len(pts)
    left, right = [], []
    for i in range(n):
        x, y = pts[i]
        px, py = pts[max(0, i - 1)]
        nx, ny = pts[min(n - 1, i + 1)]
        tx, ty = nx - px, ny - py
        length = math.hypot(tx, ty) or 1.0
        ox, oy = -ty / length, tx / length  # in-plan perpendicular; handles hairpins
        h, z = halves[i], decks[i]
        left.append(Vector((x + ox * h, y + oy * h, z)))
        right.append(Vector((x - ox * h, y - oy * h, z)))
        if i % 3 == 0:
            TRAIL_FOOTPRINTS.append((x, y, h + 10.0))

    # The retaining wall is sized per point to REACH the ground under the
    # ledge's downhill edge - a fixed thickness leaves the bench visibly
    # floating wherever the flank steepens. Then taper it to nothing at both
    # ends so the ledge grows out of the apron and dies into the lip, instead
    # of ending on a blank wall.
    thick = []
    for i in range(n):
        low = math.inf
        for edge in (left[i], right[i]):
            gnd = _drop_to_ground(ground, edge.x, edge.y)
            low = min(low, gnd if gnd is not None else height_at(edge.x, edge.y))
        need = min(max(TRAIL_THICK, decks[i] - low + 2.5), 46.0)
        t = i / (n - 1)
        fade = min(smoothstep(0.0, 0.055, t), smoothstep(1.0, 0.945, t))
        thick.append(0.9 + (need - 0.9) * fade)
    add_ribbon_slab(bm, left, right, thick)

    rise = decks[-1] - decks[0]
    run = sum(math.dist(pts[i], pts[i + 1]) for i in range(n - 1))
    print(
        f"[island_gen] terraces: {TRAIL_LEGS} switchback legs on the {TRAIL_CENTER_DEG:.0f} deg face, "
        f"r {TRAIL_R_START:.0f}->{TRAIL_R_END:.0f}, climbs {rise:.0f} over {run:.0f} "
        f"({100 * rise / run:.1f}% grade), deck y {decks[0]:.1f} -> {decks[-1]:.1f}"
    )
    return object_from_bmesh("Volcano_Terraces", bm, ["M_VolPath"])


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
        if not _clear_of_ponds(x, z, 1.0) or not _off_trail(x, z, 12.0):
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
        if not _off_trail(x, z, 24.0):
            continue  # never wall off the switchback
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
        if not _off_trail(x, z, 9.0):
            continue  # the trail tops out here; leave the viewpoint standable
        surface = _drop_to_ground(ground, x, z)
        if surface is None:
            continue
        s = random.uniform(3.5, 6.5)
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
        if not _clear_of_ponds(x, z, 1.0) or not _off_trail(x, z, 4.0):
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
            if not _clear_of_ponds(x, z, pad) or not _off_trail(x, z, 4.0):
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
            if not _clear_of_ponds(x, z) or not _off_trail(x, z, 3.0):
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
        if not _clear_of_ponds(x, z, 1.0) or not _off_trail(x, z, 2.0):
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
#
# LAVA_PONDS IS AN APRON-ONLY LIST. Only pools that come to rest on the walked
# ash apron (u >= 0.70) go in it: the two things that read it - the prop/rock
# scatter's keep-clear test and the fishing surface - both only care about
# ground the player stands on. The purely visual spatter ledges the falls
# throw off high on the flank (build_lava, `_lava_flow`) are deliberately NOT
# recorded: nothing scatters up there and nothing is fished off a cliff.
LAVA_PONDS = []


def _clear_of_ponds(x, z, pad=4.0):
    return all((x - px) ** 2 + (z - py) ** 2 > (pr + pad) ** 2 for px, py, pr in LAVA_PONDS)


# THE TWO STANDING USER RULES ON VOLCANO LAVA, enforced here so every scrap of
# molten geometry - flow, pond, side branch, fall spatter - passes through one
# gate instead of each site re-deriving the limits (user, 2026-08-26, on the
# "much more lava" overhaul):
#
# (1) NOTHING FACES THE DOCK, AND NOTHING CROSSES THE CLIMB. The dock bearing
#     and the switchback trail's face are the same 270 deg (TRAIL_CENTER_DEG),
#     and the trail swings +-42 deg off it, its landings adding ~10 deg more
#     where the cone narrows. So one wedge covers both duties: +-62 deg around
#     270 is lava-free at EVERY u - well past the +-30 the dock rule asks for,
#     and with a 10 deg margin outside the widest hairpin, so the sea in front
#     of the planks stays plain ocean and the climb is never blocked.
# (2) LAVA NEVER REACHES THE SEA. No lava geometry past u 0.955. Pool CENTRES
#     are capped tighter than that - `_pond_fits` measures the pool's real
#     outer reach, jagged edge included, so a wide pool is pushed inland (or
#     shrunk) rather than allowed to lick the waterline.
LAVA_CLEAR_CENTER = math.radians(270.0)
LAVA_CLEAR_HALF = math.radians(62.0)
LAVA_MAX_U = 0.955
LAVA_CORRIDOR = 0.20  # rad: how far any part of a flow may stray from its notch


def _lava_theta(theta, theta0):
    """Gate every lava angle: hold it inside its own notch's corridor (so a
    cascade wandering pool by pool can't creep sideways into the next flow's
    ground) and outside the dock/trail wedge - rule (1) above."""
    d = ((theta - theta0 + math.pi) % math.tau) - math.pi
    theta = theta0 + max(-LAVA_CORRIDOR, min(LAVA_CORRIDOR, d))
    da = ((theta - LAVA_CLEAR_CENTER + math.pi) % math.tau) - math.pi
    if abs(da) < LAVA_CLEAR_HALF:  # never happens for a well-placed notch; the backstop is cheap
        theta = LAVA_CLEAR_CENTER + math.copysign(LAVA_CLEAR_HALF, da)
    return theta


def _pond_fits(x, z, reach):
    """True if a pool centred at (x, z) whose ragged edge reaches `reach`
    studs stays inside u 0.955 - rule (2) above. Samples the outward
    direction and a fan either side of it, because the coastline's lobes mean
    the ring at a given u is not a circle."""
    d = math.hypot(x, z) or 1.0
    ux, uz = x / d, z / d
    for a in (-0.5, -0.25, 0.0, 0.25, 0.5):
        ca, sa = math.cos(a), math.sin(a)
        ex = x + (ux * ca - uz * sa) * reach
        ez = z + (ux * sa + uz * ca) * reach
        if u_at(ex, ez) > LAVA_MAX_U:
            return False
    return True


def _jagged_disc(bm, cx, cy, rx, ry, z_top, thickness, salt, seg=26):
    """A flat molten pool: a ragged-edged ellipse slab."""
    points = []
    for s in range(seg):
        a = (s / seg) * math.tau
        w = 1 + 0.10 * math.sin(3 * a + salt) + 0.06 * math.sin(7 * a + salt * 2.1)
        points.append((cx + math.cos(a) * rx * w, cy + math.sin(a) * ry * w))
    add_disc_slab(bm, points, z_top, thickness)


# The steep upper flank, where the PROFILE runs ~34-40 deg: this is the band a
# flow can genuinely fall down rather than run down, so it is where the falls
# are allowed to read (see `_lava_flow`).
FALL_U = (0.19, 0.40)
FALL_DROP = 10.0  # studs between two samples; the band averages ~9, so this picks the pitches


def _lava_flow(bm, theta0, ground, scale=1.0):
    """One lava flow from the summit-crater notch at `theta0` down the WHOLE
    flank. Marches from the crater lip to the foot, riding just above the
    REAL faceted surface (`ground` raycast at the centre and both edges -
    the analytic height_at + crag() disagrees with the mesh by tens of studs
    because of the per-ring radial jitter, which buried earlier flows in the
    slope), never climbing. Every flow ends in a cascade of molten ponds on
    the apron - lava never reaches the sea (user, 2026-08-24: the dock and
    the water around it are plain ocean).

    `scale` widens or narrows the whole river: build_lava derives it from the
    notch's own gash size, so the widest gash reads as THE main breach in the
    lip rather than every flow pouring at one stamped width.

    Where the river crosses the steep band (FALL_U) and the ground drops more
    than FALL_DROP between two samples, the strip FLARES and throws a bright
    apron of spatter at the pitch's foot - a lava FALL, so the upper flank has
    events on it instead of one even ribbon. Those spatter ledges are visual
    only: they sit high on the cliff, far above the walked apron, so they are
    NOT recorded in LAVA_PONDS (see that list's contract - it is apron pools
    only, for the scatter keep-clear and the fishing surface)."""
    u_end = random.uniform(0.78, 0.84)
    steps = 38  # dense: the straight strip between samples must not dip behind crag bulges
    us = [0.145 + (u_end - 0.145) * (i / (steps - 1)) for i in range(steps)]
    wander = random.uniform(0, math.tau)
    left, right = [], []
    last_h = LAVA_LEVEL + 0.4  # emerges from the crater lake surface
    falls = 0
    flare = 0  # steps of widening still owed to the fall we are in
    theta = theta0
    for i, u in enumerate(us):
        # A BOUNDED wander (a slow sine, +-~3 deg) rather than a random walk:
        # over 38 steps a walk could drift 20-plus degrees and stray across the
        # switchback face, which must stay lava-free. _lava_theta is the
        # backstop that makes that structural rather than merely likely.
        theta = _lava_theta(theta0 + 0.055 * math.sin(wander + 4.0 * (i / (len(us) - 1))), theta0)
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        frac = i / (steps - 1)
        w = (4.0 + 11.0 * frac) * scale  # wide rivers, not trickles
        perp = Vector((-math.sin(theta), math.cos(theta), 0))
        if i == 0:
            h = last_h
        else:
            samples = []
            for px, py in ((x, z), (x + perp.x * w, z + perp.y * w), (x - perp.x * w, z - perp.y * w)):
                s = _drop_to_ground(ground, px, py)
                samples.append(s if s is not None else height_at(px, py) + crag(px, py, u) - notch_cut(theta, u))
            h = min(max(samples) + 2.2, last_h - 0.4)  # lava only ever runs downhill
        drop = last_h - h
        if flare == 0 and falls < 2 and FALL_U[0] <= u <= FALL_U[1] and drop > FALL_DROP:
            falls += 1
            flare = 2  # this sample and the next: the lip of the pitch and its foot
            # The spatter apron at the fall's foot. Thin, small, and NOT a
            # LAVA_PONDS entry: it hangs on the cliff at u ~0.2-0.4, where
            # nothing is scattered and nothing is fished.
            _jagged_disc(bm, x, z, w * 1.9, w * 1.35, h - 0.8, 2.4, salt=theta * 3.7 + u, seg=12)
        if flare:
            w *= 1.7  # the river spreads as it goes over the edge
            flare -= 1
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

    def spill(a, b, half, thick=2.5):
        """A wide flat strip of lava joining two pool centres (each an
        (x, z, top-height) triple), so the cascade reads as one connected
        sheet rather than a row of separate discs."""
        seg = Vector((b[0] - a[0], b[1] - a[1], 0))
        if seg.length <= 1:
            return
        perp = Vector((-seg.y, seg.x, 0)).normalized() * half
        a_pt = Vector((a[0], a[1], a[2] - 0.3))
        b_pt = Vector((b[0], b[1], b[2] - 0.3))
        add_strip_slab(bm, [a_pt + perp, b_pt + perp], [a_pt - perp, b_pt - perp], thick)

    def pool(x, z, want_r, top, salt, seg=18):
        """Lay one apron pool, shrinking it until its ragged edge clears the
        waterline - USER RULE (2): lava never reaches the sea. Returns the
        radius actually used, or None if it had to shrink past usefulness (in
        which case the cascade simply stops short rather than spilling into
        the surf). Every pool laid here IS an apron pool, so every one is
        recorded in LAVA_PONDS."""
        r = want_r
        while r > 8.0 and not _pond_fits(x, z, r * 1.16):  # 1.16: the jagged edge's worst overshoot
            r *= 0.85
        if r <= 8.0 or not _pond_fits(x, z, r * 1.16):
            return None
        # Thick slab: the apron slopes, so a thin disc would leave its
        # downhill edge hovering.
        _jagged_disc(bm, x, z, r, r * random.uniform(0.7, 0.95), top - 0.2, 4.5, salt=salt, seg=seg)
        LAVA_PONDS.append((x, z, r))
        return r

    # One full-flank flow per crater notch. Each flow then SPREADS across the
    # base as a cascade of 3-5 broad overlapping pools stepping outward and
    # downhill, joined by wide spill strips, with the occasional SIDE BRANCH -
    # a pool throwing a smaller pool off at an angle instead of strictly
    # outward. That is what makes the apron read as threaded with molten
    # sheets rather than one tidy chain per corner. Every one of these pools
    # is fishable lava and is recorded in LAVA_PONDS.
    #
    # Flow width is derived from the gash that feeds it: a wide, deep notch
    # pours a visibly bigger river and dies in bigger pools, so the lip has a
    # main breach and several lesser ones instead of nine identical spouts.
    for a0, half, depth in NOTCHES:
        gash = (half / math.radians(12.0)) * (depth / 66.0)  # 1.0 = a middling notch
        scale = max(0.72, min(1.45, gash))
        end_theta, end_u, end_h = _lava_flow(bm, a0, ground, scale)
        ptheta, pu, ph = end_theta, end_u, end_h
        prev_center = None
        for k in range(random.randint(3, 5)):
            ptheta = _lava_theta(ptheta, a0)
            r = ring_radius(pu, ptheta)
            x, z = math.cos(ptheta) * r, math.sin(ptheta) * r
            if k > 0:
                # Each later pool sits on its own ground, a step lower.
                ph = min(ph - 0.6, height_at(x, z) + 1.2)
            want = random.uniform(19.0, 34.0) * scale * (1.0 - 0.11 * k)
            pr = pool(x, z, want, ph, salt=ptheta + k)
            if pr is None:
                break  # the cascade has run out of apron; stop rather than reach the sea
            if prev_center is not None:
                spill(prev_center, (x, z, ph), random.uniform(7.0, 12.0))
            # A short side branch: a second, smaller pool thrown off at an
            # angle. Kept in polar (a big angular step, a small radial one) so
            # it is a genuinely sideways spur while still passing through the
            # same two rules as everything else.
            if k > 0 and random.random() < 0.45:
                btheta = _lava_theta(ptheta + random.choice((-1, 1)) * random.uniform(0.09, 0.14), a0)
                bu = pu + random.uniform(-0.01, 0.025)
                br_ = ring_radius(bu, btheta)
                bx, bz = math.cos(btheta) * br_, math.sin(btheta) * br_
                bh = min(ph - 0.4, height_at(bx, bz) + 1.2)
                if pool(bx, bz, pr * random.uniform(0.45, 0.65), bh, salt=btheta * 2.3, seg=14):
                    spill((x, z, ph), (bx, bz, bh), random.uniform(4.5, 7.5), 2.0)
            prev_center = (x, z, ph)
            ptheta += random.uniform(-0.06, 0.06)
            pu = min(LAVA_MAX_U, pu + random.uniform(0.045, 0.075))

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
        # Terraces first: they record TRAIL_FOOTPRINTS, and lava first after
        # that: it records LAVA_PONDS. Both are what the rock/prop scatter
        # keeps clear of.
        build_volcano_terraces(ground),
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
#
# The fen is built from an AUTHORED water network rather than scattered
# puddles: a graph of pools joined by winding channels, with two tidal creeks
# cutting out through the mud band to the sea. That graph does double duty -
# it carves the landform (a heightfield displacement, so the ground genuinely
# dips into every pool and channel) and it builds the Swamp_Water surface, so
# water and terrain can never disagree. Everything else (reeds, snags, lilies,
# trees) is placed FROM the network, which is what makes the island read as
# composed instead of stamped.
#
# Only the swamp uses these helpers; the shared island machinery is untouched.

FEN_WATER_Z = 3.2  # the fen's standing-water plane (Blender z; sea is 0)
FEN_DEPTH = 1.6  # how far the peat is carved below a water surface
FEN_BANK = 13.0  # studs from the water edge over which the bank climbs out
FEN_ARENA = (0.0, -74.0, 36.0)  # keep-clear open ground for the boss fight

_FEN_POOLS = []  # (x, y, r, water_z, depth)
_FEN_CHANNELS = []  # (polyline of (x, y, water_z), half width, depth)
_FEN_SEGMENTS = []  # flattened channel segments, for the distance field
_FEN_MOUNDS = []  # (x, y, rx, ry, rot, height) gentle walkable swells
_FEN_ISLETS = []  # (x, y, r, top_z) ground that rises back out of a pool


def _fen_polar(theta_deg, u):
    a = math.radians(theta_deg)
    r = ring_radius(u, a)
    return math.cos(a) * r, math.sin(a) * r


def _fen_path(a, b, bow, rng, za, zb, steps=7):
    """A winding polyline from a to b: bowed sideways and jittered, with the
    water height ramping za -> zb along it."""
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    length = math.hypot(dx, dy)
    px, py = (-dy / length, dx / length) if length > 0 else (0.0, 0.0)
    pts = []
    for i in range(steps + 1):
        t = i / steps
        swell = math.sin(math.pi * t)
        off = bow * swell + rng.uniform(-3.0, 3.0) * swell
        pts.append((ax + dx * t + px * off, ay + dy * t + py * off, za + (zb - za) * t))
    return pts


def _fen_channel(a, b, bow, rng, hw=7.0, za=None, zb=None, depth=FEN_DEPTH, steps=7):
    za = FEN_WATER_Z if za is None else za
    zb = FEN_WATER_Z if zb is None else zb
    _FEN_CHANNELS.append((_fen_path(a, b, bow, rng, za, zb, steps), hw, depth))


def _seg_dist(x, y, a, b):
    ax, ay = a[0], a[1]
    dx, dy = b[0] - ax, b[1] - ay
    l2 = dx * dx + dy * dy
    s = 0.0 if l2 == 0 else max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / l2))
    return math.hypot(x - (ax + dx * s), y - (ay + dy * s)), s


def _fen_layout():
    """Author the fen: pools, channels, creeks, swells, islets. Hand-placed
    (a fixed local RNG only for the wander), so the composition is stable."""
    rng = random.Random(20260826)
    _FEN_POOLS.clear()
    _FEN_CHANNELS.clear()
    _FEN_SEGMENTS.clear()
    _FEN_MOUNDS.clear()
    _FEN_ISLETS.clear()

    # -- the pool chain. The Mire Eye is the big central water; the rest hang
    #    off it so the whole system reads as one drainage, not five puddles.
    eye = _fen_polar(110, 0.15)
    p1 = _fen_polar(40, 0.37)
    p2 = _fen_polar(150, 0.39)
    p3 = _fen_polar(196, 0.29)
    p4 = _fen_polar(330, 0.45)
    p5 = _fen_polar(78, 0.55)
    p6 = _fen_polar(238, 0.66)
    for (x, y), r in ((eye, 36.0), (p1, 25.0), (p2, 27.0), (p3, 19.0), (p4, 23.0), (p5, 18.0), (p6, 15.0)):
        _FEN_POOLS.append((x, y, r, FEN_WATER_Z, FEN_DEPTH))

    _fen_channel(eye, p1, 16.0, rng)
    _fen_channel(eye, p2, -14.0, rng)
    _fen_channel(eye, p3, 11.0, rng, hw=6.0)
    _fen_channel(p1, p4, -13.0, rng, hw=6.5)
    _fen_channel(p2, p5, 12.0, rng, hw=6.0)
    _fen_channel(p3, p6, -10.0, rng, hw=5.5)
    _fen_channel(p1, p5, 9.0, rng, hw=5.0)

    # -- two tidal creeks: the fen drains to the sea, and the cuts break the
    #    dead mud ring the old island had. Both stay well off the dock wedge.
    for theta, src, bow in ((338, p4, 15.0), (142, p2, -15.0), (205, p3, 13.0)):
        mouth = _fen_polar(theta, 1.04)
        _fen_channel(src, mouth, bow, rng, hw=7.5, zb=0.2, depth=1.3, steps=9)

    # -- brackish pans out in the mud band: standing water where the ring used
    #    to be empty. Shallower, and only a hair above the sea.
    for theta, u, r in ((22, 0.86, 17.0), (118, 0.87, 15.0), (168, 0.90, 14.0),
                        (232, 0.86, 15.0), (300, 0.84, 13.0), (318, 0.90, 14.0)):
        x, y = _fen_polar(theta, u)
        _FEN_POOLS.append((x, y, r, 0.95, 1.15))

    for pts, hw, depth in _FEN_CHANNELS:
        for i in range(len(pts) - 1):
            _FEN_SEGMENTS.append((pts[i], pts[i + 1], hw, depth))

    # -- gentle interior swells (walkable: height/radius stays under ~0.25).
    for x, y, rx, ry, rot, h in (
        (-62, 62, 48, 34, 0.6, 4.4),
        (72, 58, 42, 30, -0.4, 3.6),
        (36, -98, 46, 30, 1.1, 3.2),
        (-98, -36, 40, 28, 0.2, 4.0),
        (-18, 112, 40, 26, -0.9, 3.4),
        (112, -18, 34, 26, 0.5, 2.8),
        (-40, -8, 30, 22, 0.9, 2.4),
    ):
        _FEN_MOUNDS.append((x, y, rx, ry, rot, h))

    # -- mud bars: tangential ridges through the outer band so the shoreline
    #    has relief instead of one flat apron.
    for theta, u, h in ((8, 0.86, 2.3), (52, 0.82, 1.9), (96, 0.89, 2.5), (134, 0.84, 2.0),
                        (176, 0.86, 2.2), (212, 0.83, 2.0), (302, 0.85, 2.1), (334, 0.89, 2.4)):
        x, y = _fen_polar(theta, u)
        _FEN_MOUNDS.append((x, y, 36.0, 13.0, math.radians(theta + 90), h))

    # -- islets: ground rising back out of the water. The first carries the
    #    landmark tree, so the island has a silhouette from the sea.
    _FEN_ISLETS.append((eye[0] + 4.0, eye[1] + 6.0, 15.0, FEN_WATER_Z + 3.6))
    _FEN_ISLETS.append((p2[0] - 6.0, p2[1] + 4.0, 8.0, FEN_WATER_Z + 2.0))
    _FEN_ISLETS.append((p4[0] + 5.0, p4[1] - 3.0, 7.0, FEN_WATER_Z + 1.8))


def _fen_guard(theta, u):
    """1 where the fen may be reshaped, 0 across the dock/spawn wedge (that
    ground is gameplay-keyed and must stay exactly as the profile made it)."""
    a = math.radians(DOCK_ANGLE_DEG)
    da = abs(((theta - a + math.pi) % math.tau) - math.pi)
    wedge = smoothstep(0.20, 0.44, da)
    near = smoothstep(0.58, 0.70, u)  # only guard the outer approach
    return wedge * near + (1 - near)


def _fen_relief(x, y, u):
    """Hummocks and swells: the thing that stops the fen being a pancake."""
    h = 0.0
    for mx, my, rx, ry, rot, mh in _FEN_MOUNDS:
        dx, dy = x - mx, y - my
        c, s = math.cos(-rot), math.sin(-rot)
        lx, ly = (dx * c - dy * s) / rx, (dx * s + dy * c) / ry
        d = math.hypot(lx, ly)
        if d < 1.0:
            h += mh * (0.5 + 0.5 * math.cos(math.pi * d))
    h += noise.noise(Vector((x * 0.017, y * 0.017, 4.3))) * 1.75
    h += noise.noise(Vector((x * 0.052, y * 0.052, 11.7))) * 0.7
    return h * (1 - smoothstep(0.93, 0.99, u))  # crisp shoreline for the foam


def _fen_water_field(x, y):
    """(blend, water_z, depth) of the nearest water feature - 1 inside the
    pool/channel, falling to 0 a bank's width outside it."""
    best, wz, dep = 0.0, FEN_WATER_Z, FEN_DEPTH
    for px, py, pr, pz, pd in _FEN_POOLS:
        t = 1.0 - smoothstep(0.0, FEN_BANK, math.hypot(x - px, y - py) - pr)
        if t > best:
            best, wz, dep = t, pz, pd
    for a, b, hw, cd in _FEN_SEGMENTS:
        d, s = _seg_dist(x, y, a, b)
        t = 1.0 - smoothstep(0.0, FEN_BANK, d - hw)
        if t > best:
            best, wz, dep = t, a[2] + (b[2] - a[2]) * s, cd
    return best, wz, dep


def _fen_height(x, y):
    """The fen's ground: the shared profile, plus relief, minus the water
    network carved into it, plus islets rising back out."""
    u = u_at(x, y)
    theta = math.atan2(y, x)
    guard = _fen_guard(theta, u)
    h = profile_height(min(u, RINGS[-1])) + _fen_relief(x, y, u) * guard
    t, wz, dep = _fen_water_field(x, y)
    t *= guard
    if t > 0:
        h = h * (1 - t) + (wz - dep) * t
    for ix, iy, ir, itop in _FEN_ISLETS:
        d = math.hypot(x - ix, y - iy)
        if d < ir * 1.2:
            w = 1 - smoothstep(ir * 0.4, ir * 1.2, d)
            h = max(h, h * (1 - w) + itop * w)
    return h


def _fen_material(x, y, u):
    """Which of [peat, mud, wet mud] paints this patch of ground. The shared
    base paints strict rings; the fen instead lets the peat edge WANDER (so
    the green stops reading as an oval stamped on brown) and puts wet mud in
    the low, water-adjacent parts of the band, which is what breaks the dead
    ring the first pass had."""
    if u > 1.0:
        return 2
    edge = GRASS_U + noise.noise(Vector((x * 0.0115, y * 0.0115, 21.0))) * 0.17
    if u <= edge:
        return 0
    if _fen_water_field(x, y)[0] > 0.2:
        return 2  # the creek cuts and pan margins stay wet
    if noise.noise(Vector((x * 0.0125, y * 0.0125, 5.0))) > 0.22:
        return 2  # wet flats scattered through the mud
    return 1


def build_swamp_base(base_name, material_names):
    """The fen landform. Same radial-fan topology as the shared base, but every
    vertex comes from _fen_height (so the pools and channels are cut into the
    real mesh) and every face is painted by _fen_material."""
    bm = bmesh.new()
    center = bm.verts.new(Vector((0, 0, _fen_height(0, 0))))
    rings = []
    for u in RINGS[1:]:
        ring = []
        for s in range(SEGMENTS):
            theta = (s / SEGMENTS) * math.tau
            r = ring_radius(u, theta)
            x, y = math.cos(theta) * r, math.sin(theta) * r
            ring.append(bm.verts.new(Vector((x, y, _fen_height(x, y)))))
        rings.append(ring)

    for s in range(SEGMENTS):
        f = bm.faces.new((center, rings[0][s], rings[0][(s + 1) % SEGMENTS]))
        f.material_index = 0
    for i in range(len(rings) - 1):
        inner, outer = rings[i], rings[i + 1]
        u_mid = (RINGS[i + 1] + RINGS[i + 2]) * 0.5
        for s in range(SEGMENTS):
            s2 = (s + 1) % SEGMENTS
            f = bm.faces.new((inner[s], outer[s], outer[s2], inner[s2]))
            cx = (inner[s].co.x + outer[s].co.x + outer[s2].co.x + inner[s2].co.x) * 0.25
            cy = (inner[s].co.y + outer[s].co.y + outer[s2].co.y + inner[s2].co.y) * 0.25
            f.material_index = _fen_material(cx, cy, u_mid)
    return object_from_bmesh(base_name, bm, material_names)


def _fen_disc(bm, cx, cy, r, squash, z_top, thickness, salt, seg=22):
    """A pool surface: a barely-ragged ellipse, kept close to the carve radius
    so the water never climbs its own bank."""
    points = []
    for s in range(seg):
        a = (s / seg) * math.tau
        w = 1 + 0.05 * math.sin(3 * a + salt) + 0.03 * math.sin(7 * a + salt * 2.1)
        points.append((cx + math.cos(a) * r * w, cy + math.sin(a) * r * squash * w))
    add_disc_slab(bm, points, z_top, thickness)


def _fen_in_arena(x, y, pad=0.0):
    ax, ay, ar = FEN_ARENA
    return math.hypot(x - ax, y - ay) < ar + pad


def build_swamp_water(ground):
    """The fen's water: every authored pool and channel as ONE object.
    Swamp_Water is the contract name World.FISHABLE_NAMES keys on."""
    bm = bmesh.new()
    LAVA_PONDS.clear()
    for i, (x, y, r, wz, dep) in enumerate(_FEN_POOLS):
        _fen_disc(bm, x, y, r * 0.97, random.uniform(0.82, 0.98), wz, dep + 0.9, salt=i * 1.7)
        LAVA_PONDS.append((x, y, r))
    for pts, hw, dep in _FEN_CHANNELS:
        left, right = [], []
        for i, (px, py, pz) in enumerate(pts):
            nxt = pts[min(i + 1, len(pts) - 1)]
            prv = pts[max(i - 1, 0)]
            dx, dy = nxt[0] - prv[0], nxt[1] - prv[1]
            n = math.hypot(dx, dy) or 1.0
            ox, oy = -dy / n * hw * 0.95, dx / n * hw * 0.95
            left.append(Vector((px + ox, py + oy, pz)))
            right.append(Vector((px - ox, py - oy, pz)))
            LAVA_PONDS.append((px, py, hw * 0.8))
        add_strip_slab(bm, left, right, 2.2)
    print(f"[island_gen] swamp water: {len(_FEN_POOLS)} pools, {len(_FEN_CHANNELS)} channels")
    return object_from_bmesh("Swamp_Water", bm, ["M_SwampWater"])


# ---- the mangrove fen -----------------------------------------------------
#
# Two ideas carry the island. The GROUND is a connected marsh: the authored
# pool graph grown until standing water threads the whole interior instead of
# sitting in a handful of separate holes. The SKY is a canopy ROOF: a jittered
# lattice of huge stilt-rooted mangroves whose broad flat pads overlap into one
# green ceiling, punched with a few deliberate gaps so light reaches the water.

_SWAMP_ROOF_Z = 46.0  # nominal height of the mangrove canopy plane
_SWAMP_ROOF_U = 0.74  # the roof spans the interior out to here
_SWAMP_ROOF_STEP = 35.0  # lattice spacing; pads are ~22-33 wide, so they knit


def _swamp_spawn_clear(x, y, pad=0.0):
    """True when (x, y) is clear of the dock -> interior walk. Nothing floods
    it, and no trunk or stilt root lands in it: that shelf is the spawn."""
    d, _ = _seg_dist(x, y, (0.0, -178.0), (0.0, -96.0))
    return d > 20.0 + pad


def _swamp_marsh():
    """Grow the authored fen into a marsh NETWORK. Extra pools out in the
    quiet quarters, each laced back into the existing chain by a wide channel,
    so water threads most of the interior. Appended to the same _FEN_* tables
    _fen_layout fills, so the landform carve, the Swamp_Water surface, the
    lilies and the prop keep-clears all see it - one source of truth."""
    rng = random.Random(88117)
    eye = _fen_polar(110, 0.15)
    p1, p2, p3 = _fen_polar(40, 0.37), _fen_polar(150, 0.39), _fen_polar(196, 0.29)
    p4, p5, p6 = _fen_polar(330, 0.45), _fen_polar(78, 0.55), _fen_polar(238, 0.66)

    q = {}
    for key, theta, u, r in (
        ("q0", 6, 0.60, 17.0),
        ("q1", 64, 0.72, 15.0),
        ("q2", 128, 0.62, 16.0),
        ("q3", 176, 0.58, 15.0),
        ("q4", 214, 0.46, 14.0),
        ("q5", 248, 0.62, 14.0),
        ("q6", 292, 0.68, 13.0),
        ("q7", 348, 0.70, 13.0),
        ("q8", 94, 0.42, 12.0),
    ):
        x, y = _fen_polar(theta, u)
        if _fen_in_arena(x, y, 8.0) or not _swamp_spawn_clear(x, y, r):
            continue
        q[key] = (x, y)
        _FEN_POOLS.append((x, y, r, FEN_WATER_Z, FEN_DEPTH))

    first_channel = len(_FEN_CHANNELS)
    for key, other, bow, hw in (
        ("q0", p1, 10.0, 13.0), ("q0", p4, -9.0, 11.0),
        ("q1", p5, 8.0, 12.0), ("q1", p1, -11.0, 11.0),
        ("q2", p2, 9.0, 13.0), ("q2", p5, -12.0, 11.0),
        ("q3", p2, -8.0, 12.0), ("q3", p6, 9.0, 11.0),
        ("q4", p3, 8.0, 12.0), ("q4", p6, -7.0, 11.0),
        ("q5", p6, 8.0, 11.0), ("q6", p4, 9.0, 11.0),
        ("q7", p4, -8.0, 12.0), ("q7", p1, 9.0, 11.0),
        ("q8", eye, 6.0, 13.0), ("q8", p5, -7.0, 11.0),
    ):
        if key in q:
            _fen_channel(q[key], other, bow, rng, hw=hw)
    # widen the original spine too, so the whole graph reads as one marsh
    _fen_channel(p1, p2, 26.0, rng, hw=11.0)
    _fen_channel(p3, p5, -30.0, rng, hw=10.0)

    for pts, hw, depth in _FEN_CHANNELS[first_channel:]:
        for i in range(len(pts) - 1):
            _FEN_SEGMENTS.append((pts[i], pts[i + 1], hw, depth))

    # mud hummock paths: low dry swells threaded BETWEEN the waters, so there
    # is somewhere to walk and the marsh reads as land-and-water, not a lake.
    for x, y, rx, ry, rot, h in (
        (56, 12, 30, 15, 0.4, 2.6),
        (-34, 44, 28, 14, -0.7, 2.4),
        (18, -44, 30, 15, 1.2, 2.2),
        (-88, 26, 26, 13, 0.3, 2.4),
        (86, -66, 26, 13, -1.0, 2.2),
        (-52, -66, 26, 13, 0.8, 2.2),
    ):
        _FEN_MOUNDS.append((x, y, rx, ry, rot, h))
    print(f"[island_gen] swamp marsh: grown to {len(_FEN_POOLS)} pools, {len(_FEN_CHANNELS)} channels")


def _swamp_mark(bm, first, index):
    bm.faces.ensure_lookup_table()
    for i in range(first, len(bm.faces)):
        bm.faces[i].material_index = index


def _swamp_pad(bm, center, scale, salt, yaw, index):
    """One canopy pad: a broad, very flat blob. Wide enough that neighbouring
    trees interlock into a roof rather than reading as separate lollipops."""
    first = len(bm.faces)
    add_blob(bm, center, scale, 0.30, salt, yaw)
    _swamp_mark(bm, first, index)


def _swamp_hanging_moss(bm, cx, cy, cz, radius, rng, salt, count):
    """Thin strands trailing DOWN out of the canopy underside."""
    for k in range(count):
        a = salt * 0.7 + k * math.tau / max(count, 1) + rng.uniform(-0.4, 0.4)
        d = radius * rng.uniform(0.45, 0.98)
        first = len(bm.faces)
        add_cone(
            bm, (cx + math.cos(a) * d, cy + math.sin(a) * d, cz),
            rng.uniform(0.45, 0.95), 0.1, rng.uniform(8.0, 22.0), sides=3,
            tilt=(math.pi + rng.uniform(-0.1, 0.1), 0.0), yaw=a,
        )
        _swamp_mark(bm, first, 2)


def _swamp_giant(trunk_bm, canopy_bm, ground, x, y, surf, rng, salt, roof_z):
    """One of the huge mangroves that carry the roof: a buttressed trunk 40-70
    studs tall, a ring of ARCHED stilt roots wading out of the mud (the
    mangrove signature - a near-vertical leg planted in the water, then a
    slanted span up to the trunk 6-12 studs above it), and broad flat canopy
    pads at the top."""
    yaw = rng.uniform(0, math.tau)
    lean = rng.uniform(0.0, 0.05)
    tilt = (math.cos(yaw) * lean, math.sin(yaw) * lean)
    h = max(40.0, min(70.0, roof_z - surf))
    r0 = rng.uniform(3.0, 4.4)
    add_cone(trunk_bm, (x, y, surf - 2.5), r0 * 1.75, r0 * 1.05, rng.uniform(5.0, 9.0), sides=8, yaw=yaw)
    add_cone(trunk_bm, (x, y, surf - 1.0), r0, r0 * 0.30, h, sides=8, tilt=tilt, yaw=yaw)

    knee = surf + rng.uniform(6.0, 12.0)
    n = rng.randint(5, 7)
    for k in range(n):
        a = yaw + k * math.tau / n + rng.uniform(-0.22, 0.22)
        d = rng.uniform(7.0, 13.0)
        fx, fy = x + math.cos(a) * d, y + math.sin(a) * d
        fs = _drop_to_ground(ground, fx, fy)
        if fs is None:
            continue
        leg = (knee - fs) * rng.uniform(0.45, 0.62)
        if leg < 1.5:
            continue
        add_cone(trunk_bm, (fx, fy, fs - 1.2), rng.uniform(0.9, 1.35), 0.72, leg + 1.2,
                 sides=4, tilt=(0.2, 0.0), yaw=a + math.pi)
        lx = fx + math.cos(a + math.pi) * leg * 0.2
        ly = fy + math.sin(a + math.pi) * leg * 0.2
        rise = max(1.5, knee - (fs + leg))
        run = math.hypot(lx - x, ly - y)
        add_cone(trunk_bm, (lx, ly, fs + leg), 0.72, 0.3, math.hypot(run, rise),
                 sides=4, tilt=(math.atan2(run, rise), 0.0), yaw=a + math.pi)

    crown = Vector((x, y, surf - 1.0)) + cone_axis(tilt, yaw) * h
    for k in range(2):  # heavy limbs reaching out under the pads
        add_cone(trunk_bm, (x, y, surf - 1.0 + h * rng.uniform(0.70, 0.86)),
                 rng.uniform(0.9, 1.5), 0.3, rng.uniform(11.0, 19.0),
                 sides=4, tilt=(rng.uniform(0.95, 1.3), 0.0), yaw=yaw + k * math.pi + rng.uniform(-0.6, 0.6))

    r = rng.uniform(22.0, 33.0)
    _swamp_pad(canopy_bm, (crown.x, crown.y, crown.z), (r, r * rng.uniform(0.86, 1.04), r * 0.13), salt, yaw, 0)
    for k in range(2):
        a = rng.uniform(0, math.tau)
        off = r * rng.uniform(0.30, 0.58)
        rr = r * rng.uniform(0.50, 0.78)
        _swamp_pad(
            canopy_bm,
            (crown.x + math.cos(a) * off, crown.y + math.sin(a) * off, crown.z + rng.uniform(1.5, 5.5)),
            (rr, rr * rng.uniform(0.8, 1.0), rr * 0.24),
            salt + 3.1 * (k + 1), yaw + 1.1 * (k + 1), 1 - k,
        )
    _swamp_hanging_moss(canopy_bm, crown.x, crown.y, crown.z - 2.0, r * 0.98, rng, salt, rng.randint(4, 7))


def _swamp_roof_anchors():
    """The canopy lattice: a jittered hex grid over the interior, with a few
    cells dropped (a low-frequency noise mask) so the roof has light gaps
    instead of being a solid lid."""
    rng = random.Random(5150)
    reach = ISLAND_RADIUS * _SWAMP_ROOF_U
    step = _SWAMP_ROOF_STEP
    rows = int(reach / (step * 0.87)) + 1
    cols = int(reach / step) + 1
    pts = []
    for j in range(-rows, rows + 1):
        y = j * step * 0.87
        offset = step * 0.5 if j % 2 else 0.0
        for i in range(-cols, cols + 1):
            x = i * step + offset
            jx, jy = x + rng.uniform(-8.0, 8.0), y + rng.uniform(-8.0, 8.0)
            if u_at(jx, jy) > _SWAMP_ROOF_U:
                continue
            if noise.noise(Vector((jx * 0.0115, jy * 0.0115, 33.0))) > 0.40:
                continue  # a clearing: light falls through onto the water
            pts.append((jx, jy))
    return pts


def _fen_mark(bm, first, index):
    bm.faces.ensure_lookup_table()
    for i in range(first, len(bm.faces)):
        bm.faces[i].material_index = index


def _fen_canopy_pad(bm, center, scale, salt, yaw, dark):
    first = len(bm.faces)
    add_blob(bm, center, scale, 0.35, salt, yaw)
    _fen_mark(bm, first, 1 if dark else 0)


def _fen_tree(trunk_bm, canopy_bm, ground, x, y, surf, kind, rng, salt):
    """One tree. Three archetypes, each with its own trunk taper, root
    treatment and canopy build, so no two stamps read alike."""
    yaw = rng.uniform(0, math.tau)
    tilt = (rng.uniform(-0.09, 0.09), rng.uniform(-0.09, 0.09))

    if kind == "cypress":
        h = rng.uniform(24.0, 44.0)
        r0 = rng.uniform(2.2, 3.4)
        add_cone(trunk_bm, (x, y, surf - 1.4), r0, r0 * 0.22, h, sides=7, tilt=tilt, yaw=yaw)
        add_cone(trunk_bm, (x, y, surf - 1.6), r0 * 1.55, r0 * 0.9, rng.uniform(2.0, 3.4), sides=7, yaw=yaw)
        for _ in range(rng.randint(4, 7)):  # cypress knees
            a, d = rng.uniform(0, math.tau), rng.uniform(2.4, 6.5)
            kx, ky = x + math.cos(a) * d, y + math.sin(a) * d
            ks = _drop_to_ground(ground, kx, ky)
            if ks is not None:
                add_cone(trunk_bm, (kx, ky, ks - 0.5), rng.uniform(0.45, 0.95), 0.15, rng.uniform(1.2, 3.0), sides=5)
        crown = Vector((x, y, surf - 1.4)) + cone_axis(tilt, yaw) * h
        s = rng.uniform(8.5, 13.5)
        _fen_canopy_pad(canopy_bm, (crown.x, crown.y, crown.z - 1.2), (s, s * 0.86, s * 0.26), salt, yaw, False)
        _fen_canopy_pad(
            canopy_bm,
            (crown.x + rng.uniform(-2.5, 2.5), crown.y + rng.uniform(-2.5, 2.5), crown.z + s * 0.20),
            (s * 0.6, s * 0.52, s * 0.22),
            salt + 1.3,
            yaw + 0.7,
            True,
        )

    elif kind == "mangrove":
        h = rng.uniform(11.0, 18.0)
        lean = rng.uniform(0.10, 0.26)
        tilt = (math.cos(yaw) * lean, math.sin(yaw) * lean)
        r0 = rng.uniform(1.3, 2.0)
        add_cone(trunk_bm, (x, y, surf - 1.0), r0, r0 * 0.45, h, sides=6, tilt=tilt, yaw=yaw)
        for k in range(rng.randint(4, 6)):  # stilt roots splaying to the mud
            a = yaw + k * math.tau / 5 + rng.uniform(-0.3, 0.3)
            d = rng.uniform(3.0, 5.5)
            rx, ry = x + math.cos(a) * d, y + math.sin(a) * d
            rs = _drop_to_ground(ground, rx, ry)
            if rs is None:
                continue
            rise = max(1.0, (surf + h * 0.34) - rs)
            add_cone(
                trunk_bm, (rx, ry, rs - 0.4), 0.55, 0.22, math.hypot(d, rise),
                sides=5, tilt=(math.atan2(d, rise), 0.0), yaw=a + math.pi,
            )
        crown = Vector((x, y, surf - 1.0)) + cone_axis(tilt, yaw) * h
        s = rng.uniform(5.5, 8.5)
        for k in range(3):
            a = rng.uniform(0, math.tau)
            _fen_canopy_pad(
                canopy_bm,
                (crown.x + math.cos(a) * s * 0.5, crown.y + math.sin(a) * s * 0.5, crown.z + rng.uniform(-1.0, 2.4)),
                (s * rng.uniform(0.7, 1.05), s * rng.uniform(0.65, 0.95), s * rng.uniform(0.42, 0.62)),
                salt + k * 2.1,
                yaw + k,
                k % 2 == 1,
            )

    else:  # "dead" - a bare drowned trunk, canopy-less, for silhouette variety
        h = rng.uniform(13.0, 26.0)
        lean = rng.uniform(0.05, 0.30)
        tilt = (math.cos(yaw) * lean, math.sin(yaw) * lean)
        r0 = rng.uniform(1.2, 2.1)
        add_cone(trunk_bm, (x, y, surf - 1.2), r0, r0 * 0.2, h, sides=6, tilt=tilt, yaw=yaw)
        axis = cone_axis(tilt, yaw)
        for _ in range(rng.randint(1, 3)):  # broken branch stubs
            t = rng.uniform(0.45, 0.85)
            b = Vector((x, y, surf - 1.2)) + axis * h * t
            add_cone(
                trunk_bm, (b.x, b.y, b.z), rng.uniform(0.35, 0.6), 0.12, rng.uniform(3.0, 7.0),
                sides=4, tilt=(rng.uniform(0.9, 1.3), 0.0), yaw=rng.uniform(0, math.tau),
            )


def _fen_landmark(trunk_bm, canopy_bm, ground):
    """Old Gnashroot: the ancient cypress on the islet in the Mire Eye. The
    island's silhouette from the sea and the boss's namesake."""
    ix, iy, _, itop = _FEN_ISLETS[0]
    surf = _drop_to_ground(ground, ix, iy)
    if surf is None:
        surf = itop
    h = 74.0
    rng = random.Random(99)
    add_cone(trunk_bm, (ix, iy, surf - 2.0), 7.4, 1.5, h, sides=9)
    add_cone(trunk_bm, (ix, iy, surf - 2.4), 11.0, 6.6, 7.0, sides=9)  # the flare
    for k in range(9):  # buttress roots crawling off the islet
        a = k * math.tau / 9 + 0.2
        d = rng.uniform(9.0, 15.0)
        rx, ry = ix + math.cos(a) * d, iy + math.sin(a) * d
        rs = _drop_to_ground(ground, rx, ry)
        if rs is None:
            continue
        rise = max(1.0, (surf + 7.0) - rs)
        add_cone(
            trunk_bm, (rx, ry, rs - 0.6), rng.uniform(1.5, 2.4), 0.7, math.hypot(d, rise),
            sides=5, tilt=(math.atan2(d, rise), 0.0), yaw=a + math.pi,
        )
    for k in range(5):  # heavy limbs
        a = k * math.tau / 5 + 0.5
        b = Vector((ix, iy, surf - 2.0 + h * rng.uniform(0.58, 0.80)))
        add_cone(
            trunk_bm, (b.x, b.y, b.z), rng.uniform(1.1, 1.8), 0.4, rng.uniform(13.0, 22.0),
            sides=5, tilt=(rng.uniform(0.75, 1.15), 0.0), yaw=a,
        )
    crown = surf - 2.0 + h
    _fen_canopy_pad(canopy_bm, (ix, iy, crown - 6.0), (30.0, 26.0, 6.0), 3.0, 0.0, False)
    _fen_canopy_pad(canopy_bm, (ix + 6, iy - 5, crown - 1.5), (21.0, 18.0, 5.0), 6.0, 0.8, True)
    _fen_canopy_pad(canopy_bm, (ix - 7, iy + 6, crown + 1.0), (17.0, 15.0, 4.5), 9.0, 1.9, False)
    _fen_canopy_pad(canopy_bm, (ix + 1, iy + 2, crown + 5.5), (12.0, 11.0, 4.0), 12.0, 2.7, True)
    print("[island_gen] swamp landmark: Old Gnashroot placed on the Mire Eye islet")


def build_swamp_trees(ground):
    """The mangrove roof plus its understory. The interior is planted on the
    canopy lattice with huge stilt-rooted mangroves whose pads interlock into a
    continuous green ceiling; scrub thickets, cypress and drowned snags fill in
    beneath it and out on the open mud band."""
    trunk_bm, canopy_bm = bmesh.new(), bmesh.new()
    rng = random.Random(4041)
    placed = giants = 0

    _fen_landmark(trunk_bm, canopy_bm, ground)

    # -- the roof. One giant per lattice cell, straight into the mud OR the
    #    water: mangroves wade, and the roots make that read.
    for ax, ay in _swamp_roof_anchors():
        if _fen_in_arena(ax, ay, 4.0) or not _swamp_spawn_clear(ax, ay, 8.0):
            continue
        if _near_dock_corridor(math.atan2(ay, ax), u_at(ax, ay)):
            continue
        if math.hypot(ax - _FEN_ISLETS[0][0], ay - _FEN_ISLETS[0][1]) < 26.0:
            continue  # Old Gnashroot keeps its own airspace
        surf = _drop_to_ground(ground, ax, ay)
        if surf is None:
            continue
        roof = _SWAMP_ROOF_Z + noise.noise(Vector((ax * 0.0065, ay * 0.0065, 7.0))) * 6.0
        _swamp_giant(trunk_bm, canopy_bm, ground, ax, ay, surf, rng, salt=500 + giants * 3.7, roof_z=roof)
        giants += 1

    # Stands: a centre, then a handful of trees around it at mixed scales.
    stands = [_fen_polar(theta, u) for theta, u in (
        (168, 0.46), (300, 0.40), (46, 0.70),
        # Out on the mud band: scrubby thickets so the shoreline is composed
        # instead of a dead empty ring.
        (28, 0.83), (72, 0.87), (112, 0.81), (182, 0.85), (232, 0.84),
        (316, 0.82), (350, 0.88), (198, 0.90),
    )]
    for cx, cy in stands:
        for _ in range(rng.randint(2, 4)):
            a, d = rng.uniform(0, math.tau), rng.uniform(4.0, 26.0)
            x, y = cx + math.cos(a) * d, cy + math.sin(a) * d
            if _fen_in_arena(x, y, 6.0) or not _clear_of_ponds(x, y, 1.5):
                continue
            if _near_dock_corridor(math.atan2(y, x), u_at(x, y)):
                continue
            surf = _drop_to_ground(ground, x, y)
            if surf is None or _fen_water_field(x, y)[0] > 0.5:
                continue
            if u_at(x, y) > 0.76:  # out on the mud: low, wind-bent, sparse
                kind = "mangrove" if rng.random() < 0.6 else "dead"
            else:
                kind = "cypress" if rng.random() < 0.62 else ("mangrove" if rng.random() < 0.6 else "dead")
            _fen_tree(trunk_bm, canopy_bm, ground, x, y, surf, kind, rng, salt=40 + placed * 3.1)
            placed += 1

    # Mangroves hugging the pool rims - the thing that makes water read as water.
    for px, py, pr, wz, _dep in _FEN_POOLS:
        for _ in range(rng.randint(1, 3)):
            a, d = rng.uniform(0, math.tau), pr + rng.uniform(1.0, 7.0)
            x, y = px + math.cos(a) * d, py + math.sin(a) * d
            if _fen_in_arena(x, y, 4.0) or _near_dock_corridor(math.atan2(y, x), u_at(x, y)):
                continue
            surf = _drop_to_ground(ground, x, y)
            if surf is None or surf < wz - 1.2:
                continue
            kind = "mangrove" if rng.random() < 0.75 else "dead"
            _fen_tree(trunk_bm, canopy_bm, ground, x, y, surf, kind, rng, salt=200 + placed * 2.7)
            placed += 1

    print(f"[island_gen] swamp trees: {giants} canopy mangroves, {placed} understory + landmark")
    return (
        object_from_bmesh("Swamp_Trunks", trunk_bm, ["M_Cypress"]),
        object_from_bmesh("Swamp_Canopy", canopy_bm, ["M_Moss", "M_MossDark", "M_HangMoss"]),
    )


def _fen_water_edge_points(rng, count_per_pool=(6, 10)):
    """Sample points just outside every pool rim and along every channel bank -
    where reeds and logs belong."""
    pts = []
    for px, py, pr, wz, _d in _FEN_POOLS:
        for _ in range(rng.randint(*count_per_pool)):
            a = rng.uniform(0, math.tau)
            d = pr + rng.uniform(-1.0, 5.5)
            pts.append((px + math.cos(a) * d, py + math.sin(a) * d, wz))
    for line, hw, _d in _FEN_CHANNELS:
        for i in range(len(line) - 1):
            a, b = line[i], line[i + 1]
            dx, dy = b[0] - a[0], b[1] - a[1]
            n = math.hypot(dx, dy) or 1.0
            t = rng.uniform(0.25, 0.75)
            cx, cy = a[0] + dx * t, a[1] + dy * t
            for side in (1, -1):
                if rng.random() < 0.25:  # gaps, so the channel stays readable
                    continue
                off = (hw + rng.uniform(-0.5, 3.5)) * side
                pts.append((cx - dy / n * off, cy + dx / n * off, a[2] + (b[2] - a[2]) * t))
    return pts


def build_swamp_props(ground):
    """Reed brakes hugging every water edge, driftwood and half-sunk logs
    placed on the banks, mud hummocks breaking up the flats, and bog stones."""
    rng = random.Random(777)

    reed_bm = bmesh.new()
    stems = 0
    for x, y, wz in _fen_water_edge_points(rng, count_per_pool=(3, 5)):
        surf = _drop_to_ground(ground, x, y)
        if surf is None or surf > wz + 2.2 or surf < wz - 1.6:
            continue
        for _ in range(rng.randint(2, 4)):
            ox, oy = x + rng.uniform(-2.2, 2.2), y + rng.uniform(-2.2, 2.2)
            base = _drop_to_ground(ground, ox, oy)
            if base is None:
                continue
            add_post(reed_bm, ox, oy, base - 0.4, max(base, wz) + rng.uniform(2.0, 4.4), rng.uniform(0.12, 0.2), sides=4)
            stems += 1

    # Saltmarsh tufts: sparse reed clumps out on the mud band, so the ring
    # has ground cover between the thickets instead of bare brown.
    tufts = 0
    for _ in range(70):
        theta = rng.uniform(0, math.tau)
        u = rng.uniform(0.76, 0.97)
        if _near_dock_corridor(theta, u):
            continue
        r = ring_radius(u, theta)
        x, y = math.cos(theta) * r, math.sin(theta) * r
        base = _drop_to_ground(ground, x, y)
        if base is None or base < 0.2:
            continue
        for _ in range(rng.randint(2, 3)):
            ox, oy = x + rng.uniform(-2.5, 2.5), y + rng.uniform(-2.5, 2.5)
            b = _drop_to_ground(ground, ox, oy)
            if b is None:
                continue
            add_post(reed_bm, ox, oy, b - 0.4, b + rng.uniform(1.4, 3.0), rng.uniform(0.11, 0.18), sides=4)
            stems += 1
        tufts += 1

    snag_bm = bmesh.new()
    logs = 0
    for x, y, wz in _fen_water_edge_points(random.Random(31), count_per_pool=(2, 4)):
        if logs >= 46:
            break
        surf = _drop_to_ground(ground, x, y)
        if surf is None or _fen_in_arena(x, y, 2.0):
            continue
        yaw = rng.uniform(0, math.tau)
        if rng.random() < 0.55:  # a log lying half in the water
            add_cone(snag_bm, (x, y, surf + 0.5), rng.uniform(1.0, 1.7), rng.uniform(0.5, 1.0),
                     rng.uniform(10.0, 20.0), sides=6, tilt=(rng.uniform(1.42, 1.62), 0.0), yaw=yaw)
        elif rng.random() < 0.5:  # a root snag: a knot of drowned roots clawing
            #                       up out of the murk. The fen's best texture.
            add_blob(snag_bm, (x, y, surf + 0.3), (rng.uniform(2.0, 3.4), rng.uniform(1.6, 2.8), 1.1),
                     0.5, 300 + logs * 5.3, yaw=yaw)
            for k in range(rng.randint(3, 5)):
                a = yaw + k * 1.9
                add_cone(snag_bm, (x + math.cos(a) * 1.4, y + math.sin(a) * 1.4, surf + 0.4),
                         rng.uniform(0.3, 0.6), 0.12, rng.uniform(2.5, 5.5),
                         sides=4, tilt=(rng.uniform(0.35, 0.85), 0.0), yaw=a)
        else:  # a leaning dead trunk
            add_cone(snag_bm, (x, y, surf - 0.8), rng.uniform(1.0, 1.6), 0.35, rng.uniform(8.0, 15.0),
                     sides=6, tilt=(rng.uniform(0.35, 0.9), 0.0), yaw=yaw)
        logs += 1

    hummock_bm = bmesh.new()
    mounds = 0
    for i in range(90):
        spot = _interior_spot(ground, 0.10, 0.97, pad=1.0, tries=10)
        if spot is None:
            continue
        x, y, surface = spot
        if _fen_in_arena(x, y, -8.0):
            continue
        s = rng.uniform(2.0, 6.0)
        add_blob(hummock_bm, (x, y, surface - s * 0.42), (s, s * rng.uniform(0.6, 0.9), s * rng.uniform(0.35, 0.55)),
                 0.4, 700 + i * 4.7, yaw=rng.uniform(0, math.tau))
        mounds += 1

    stone_bm = bmesh.new()
    stones = 0
    for theta, u in ((30, 0.80), (86, 0.92), (160, 0.78), (192, 0.93), (250, 0.90), (322, 0.79), (352, 0.90), (120, 0.72)):
        x, y = _fen_polar(theta, u)
        surf = _drop_to_ground(ground, x, y)
        if surf is None:
            continue
        s = rng.uniform(4.5, 9.5)
        add_blob(stone_bm, (x, y, surf - s * 0.34), (s, s * rng.uniform(0.7, 1.0), s * rng.uniform(0.45, 0.8)),
                 0.55, 900 + theta, yaw=rng.uniform(0, math.tau))
        # A smaller companion, so each stone reads as an outcrop not a cone.
        add_blob(stone_bm, (x + rng.uniform(-7, 7), y + rng.uniform(-7, 7), surf - s * 0.25),
                 (s * 0.55, s * 0.45, s * 0.35), 0.55, 950 + theta, yaw=rng.uniform(0, math.tau))
        stones += 2
    # One leaning menhir on the north bar, a second silhouette cue.
    lx, ly = _fen_polar(96, 0.80)
    ls = _drop_to_ground(ground, lx, ly)
    if ls is not None:
        add_cone(stone_bm, (lx, ly, ls - 1.5), 4.2, 2.6, 19.0, sides=6, tilt=(0.22, 0.10), yaw=0.6)
        stones += 1

    print(f"[island_gen] swamp props: {stems} reed stems ({tufts} marsh tufts), {logs} snags, {mounds} hummocks, {stones} stones")
    return (
        object_from_bmesh("Swamp_Reeds", reed_bm, ["M_Reed"]),
        object_from_bmesh("Swamp_Snags", snag_bm, ["M_RootWood"]),
        object_from_bmesh("Swamp_Hummocks", hummock_bm, ["M_MudMound"]),
        object_from_bmesh("Swamp_Stones", stone_bm, ["M_BogStone"]),
    )


def build_swamp_lilies():
    """Lily pads floating on the fen: flat discs a hair above each water
    surface. Cheap, and they are what makes the murk read as water at range."""
    bm = bmesh.new()
    rng = random.Random(1212)
    pads = 0
    for px, py, pr, wz, _d in _FEN_POOLS:
        for _ in range(rng.randint(4, 8)):
            a, d = rng.uniform(0, math.tau), pr * math.sqrt(rng.uniform(0.05, 0.92))
            r = rng.uniform(1.3, 3.2)
            cx, cy = px + math.cos(a) * d, py + math.sin(a) * d
            pts = []
            for s in range(7):
                t = (s / 7) * math.tau
                w = 1 + 0.12 * math.sin(3 * t + a)
                pts.append((cx + math.cos(t) * r * w, cy + math.sin(t) * r * w))
            add_disc_slab(bm, pts, wz + 0.08, 0.08)
            pads += 1
    for line, hw, _d in _FEN_CHANNELS:
        for i in range(len(line) - 1):
            if rng.random() < 0.5:
                continue
            a, b = line[i], line[i + 1]
            t = rng.uniform(0.2, 0.8)
            cx, cy = a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t
            cz = a[2] + (b[2] - a[2]) * t
            off = rng.uniform(-hw * 0.6, hw * 0.6)
            r = rng.uniform(1.2, 2.4)
            pts = [(cx + off + math.cos((s / 7) * math.tau) * r, cy + math.sin((s / 7) * math.tau) * r) for s in range(7)]
            add_disc_slab(bm, pts, cz + 0.08, 0.08)
            pads += 1
    print(f"[island_gen] swamp lilies: {pads} pads")
    return object_from_bmesh("Swamp_Lilies", bm, ["M_Lily"])


def build_swamp():
    _fen_layout()
    _swamp_marsh()  # grow the pool chain into a connected marsh network
    base = build_swamp_base("Swamp_Base", ["M_Peat", "M_Mud", "M_WetMud"])
    ground = _ground_bvh(base)
    objects = [
        base,
        build_swamp_water(ground),  # records the keep-clear pools
        build_swamp_lilies(),
        *build_swamp_trees(ground),
        *build_swamp_props(ground),
        *build_dock("Swamp_Dock_Planks", "Swamp_Dock_Posts", "M_SwampPlank", "M_SwampPost"),
        build_foam("Swamp_Foam", "M_SwampFoam"),
    ]
    a = math.radians(DOCK_ANGLE_DEG)
    start_r = ring_radius(DOCK_START_U, a)
    ax, ay, ar = FEN_ARENA
    print(f"[island_gen] HANDOFF swamp: dock start (Roblox rel) X=0 Z={start_r:.0f}, spawn suggestion X=0 Z={start_r - 18:.0f} ground Y~{_fen_height(0, -(start_r - 18)):.1f}")
    print(f"[island_gen] HANDOFF swamp: boss arena (Roblox rel) X={ax:.0f} Z={-ay:.0f} radius {ar:.0f}, ground Y~{_fen_height(ax, ay):.1f}")
    return objects


# ---- Frostmaw Reach -------------------------------------------------------
#
# Frostmaw is read from two things: the BERG and the SPIKE FIELDS. A single
# towering iceberg (hundreds of studs of stacked, leaning glacial mass with
# stepped shelves and an overhanging crown) sits on the central ridge, and the
# flat walkable sheet around it is planted with clustered forests of huge ice
# spikes. The fishing holes are clustered INSIDE those spike fields, so
# working the ice means threading a crystal forest - which is why every spike
# cluster is laid out as a ring of shards around an open middle, and why the
# clusters themselves are islands of ice with plain sheet between them.

_ICE_CLUSTERS = []  # (x, y, radius) spike-field centres, shared holes <-> spikes


def _ice_keepout(x, z):
    """Extra keep-clear for BIG ice mass: a wide wedge over the dock walk and a
    generous bubble around the spawn ground, on top of _near_dock_corridor
    (which is only a thin rock-sized wedge)."""
    a = math.radians(DOCK_ANGLE_DEG)
    theta = math.atan2(z, x)
    da = abs(((theta - a + math.pi) % math.tau) - math.pi)
    r = math.hypot(x, z)
    if da < 0.30 and r > ring_radius(0.62, theta):
        return True
    spawn_r = ring_radius(DOCK_START_U, a) - 18.0
    sx, sz = math.cos(a) * spawn_r, math.sin(a) * spawn_r
    return (x - sx) ** 2 + (z - sz) ** 2 < 34.0**2


def _ice_cluster_layout():
    """Lay out the spike fields once, before anything is built. Holes are cut
    inside them and shards ring them, so both agree on where the forests are."""
    _ICE_CLUSTERS.clear()
    for i in range(8):
        for _ in range(30):
            theta = (i / 8) * math.tau + random.uniform(-0.22, 0.22)
            u = random.uniform(0.62, 0.84)
            r = ring_radius(u, theta)
            x, z = math.cos(theta) * r, math.sin(theta) * r
            if _near_dock_corridor(theta, u) or _ice_keepout(x, z):
                continue
            _ICE_CLUSTERS.append((x, z, random.uniform(26.0, 38.0)))
            break


def build_ice_holes(ground):
    """The frozen shelf's fishing holes - fixed, pre-cut discs of black-blue
    water in the ice, each collared by chunked rim ice. Most are cut in the
    open middles of the spike fields; a few are lone holes out on the bare
    sheet. One object, Frostmaw_IceHoles: the fishable-surface contract name
    (waters="ice")."""
    bm = bmesh.new()
    LAVA_PONDS.clear()
    _ice_cluster_layout()
    placed = 0

    def cut(x, z):
        nonlocal placed
        if not _clear_of_ponds(x, z, 13.0):  # holes keep well apart
            return False
        surface = _drop_to_ground(ground, x, z)
        if surface is None:
            return False
        hr = random.uniform(5.0, 8.5)
        _pool_disc(bm, x, z, hr, surface + 0.25, 2.2, salt=x * 0.13 + z * 0.07, squash=random.uniform(0.85, 1.0))
        placed += 1
        return True

    # Clustered: 2-3 holes in the clear middle of each spike field.
    for cx, cz, crad in _ICE_CLUSTERS:
        for _ in range(random.randint(2, 3)):
            for _ in range(14):
                a = random.uniform(0, math.tau)
                d = random.uniform(0.0, crad * 0.46)
                x, z = cx + math.cos(a) * d, cz + math.sin(a) * d
                theta = math.atan2(z, x)
                r = math.hypot(x, z)
                if r > ring_radius(0.90, theta) or r < ring_radius(0.58, theta):
                    continue
                if _near_dock_corridor(theta, r / max(ring_radius(1.0, theta), 1e-6)):
                    continue
                if cut(x, z):
                    break

    # A few loners out on the open sheet, so the shelf is fishable everywhere.
    for _ in range(90):
        if placed >= 21:
            break
        theta = random.uniform(0, math.tau)
        u = random.uniform(0.58, 0.90)
        if _near_dock_corridor(theta, u):
            continue
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        cut(x, z)

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


_ICE_SPIKES = []  # (x, y, foot radius) planted shards, so they never merge


def _ice_spike(bm, ground, x, z, height, r_bottom, salt, lean=0.0, lean_yaw=0.0):
    """One huge ice shard: a slender faceted spire, buried a little so it grows
    out of the sheet, with a smaller splinter leaning off its foot."""
    surface = _drop_to_ground(ground, x, z)
    if surface is None:
        return False
    base = Vector((x, z, surface - height * 0.06))
    sides = 5 if r_bottom < 6.0 else 6
    blunt = random.random() < 0.28  # some shards are sheared-off blocks, not needles
    add_cone(bm, base, r_bottom, r_bottom * (random.uniform(0.34, 0.55) if blunt else random.uniform(0.04, 0.14)),
             height * (0.55 if blunt else 1.0), sides=sides, tilt=(lean, 0.0), yaw=lean_yaw)
    # A cracked collar where it pierces the ice.
    add_blob(bm, (x, z, surface - r_bottom * 0.25), (r_bottom * 1.7, r_bottom * 1.35, r_bottom * 0.55),
             0.45, salt + 0.7, yaw=salt)
    # Splinters leaning off the root - a shard is never alone.
    for k in range(random.randint(1, 3) if height > 34.0 else 1):
        a = salt * 1.7 + k * 2.3
        d = r_bottom * random.uniform(1.5, 2.6)
        sx, sz = x + math.cos(a) * d, z + math.sin(a) * d
        s2 = _drop_to_ground(ground, sx, sz)
        if s2 is not None:
            add_cone(bm, Vector((sx, sz, s2 - 1.5)), r_bottom * random.uniform(0.30, 0.58), r_bottom * 0.05,
                     height * random.uniform(0.26, 0.60), sides=5,
                     tilt=(random.uniform(0.12, 0.34), 0.0), yaw=a)
    _ICE_SPIKES.append((x, z, r_bottom))
    return True


def _ice_spike_clear(x, z, r_foot):
    """Shards keep a walking gap between them: no two feet closer than the sum
    of their collars plus a body-width of open ice."""
    return all((x - px) ** 2 + (z - pz) ** 2 > (r_foot * 1.7 + pr * 1.7 + 9.0) ** 2 for px, pz, pr in _ICE_SPIKES)


def _ice_berg(bm, ground):
    """THE BERG. A single towering iceberg on the central ridge: a broad
    shattered plinth, a stack of glacial slabs that narrows and walks sideways
    as it climbs (the lean), stepped shelves jutting from its faces, and an
    overhanging crown of tilted blocks capped by summit shards. Built purely as
    geometry into Frostmaw_Seracs - the base stays a walkable shelf."""
    foot = _drop_to_ground(ground, 0.0, 0.0)
    if foot is None:
        foot = 40.0
    lean_a = math.radians(DOCK_ANGLE_DEG) + 0.55  # leans across the dock approach, not onto it
    lx, lz = math.cos(lean_a), math.sin(lean_a)

    # Plinth: broad shattered shelves piled around the foot.
    for i in range(14):
        a = (i / 14) * math.tau + random.uniform(-0.2, 0.2)
        d = random.uniform(58.0, 102.0)
        px, pz = math.cos(a) * d, math.sin(a) * d
        s = _drop_to_ground(ground, px, pz)
        if s is None:
            continue
        w = random.uniform(20.0, 38.0)
        add_blob(bm, (px, pz, s + random.uniform(2.0, 16.0)), (w, w * 0.72, random.uniform(9.0, 26.0)),
                 0.42, 120 + i * 5.3, yaw=random.uniform(0, math.tau))

    # Trunk: stacked glacial slabs, narrowing and WALKING sideways as they
    # climb. Each slab is offset, squashed and yawed differently so the tower
    # is a fractured leaning mass, never a symmetrical stack of discs.
    STEPS = 20
    RISE = 218.0
    top = None
    for i in range(STEPS):
        t = i / (STEPS - 1)
        y = foot + 4.0 + t * RISE
        r = (14.0 + 86.0 * (1.0 - t) ** 1.05) * random.uniform(0.86, 1.12)
        off = (t**1.35) * 64.0
        jit = random.uniform(-0.20, 0.20)
        cx = lx * off + math.cos(lean_a + 1.57) * r * jit
        cz = lz * off + math.sin(lean_a + 1.57) * r * jit
        thick = (12.0 + 10.0 * (1.0 - t)) * random.uniform(0.8, 1.25)
        add_blob(bm, (cx, cz, y), (r, r * random.uniform(0.68, 0.95), thick),
                 0.44, 200 + i * 3.7, yaw=i * 1.37 + random.uniform(-0.6, 0.6))
        # Knit the narrow upper stack: a half-step block between slabs, so the
        # tower stays one solid mass instead of a chain of beads.
        if t > 0.34 and i < STEPS - 1:
            add_blob(bm, (cx + lx * 4.0, cz + lz * 4.0, y + RISE / (STEPS - 1) * 0.5),
                     (r * 0.86, r * 0.72, thick * 0.85), 0.4, 240 + i * 3.1, yaw=i * 0.7)
        # Shelves: fractured ledges that break out of ONE face at a time -
        # the sheared step of a calving front, not a pagoda's eaves.
        if 0.10 < t < 0.86 and i % 3 != 1:
            sa = i * 2.11 + random.uniform(-0.4, 0.4)
            sd = r * random.uniform(0.7, 1.0)
            sw = r * random.uniform(0.45, 0.8)
            add_blob(bm, (cx + math.cos(sa) * sd, cz + math.sin(sa) * sd, y - thick * random.uniform(0.2, 0.6)),
                     (sw, sw * random.uniform(0.5, 0.8), random.uniform(5.0, 11.0)),
                     0.5, 260 + i * 2.9, yaw=sa + random.uniform(-0.5, 0.5))
        top = (cx, cz, y)

    # Buttress: a subsidiary shoulder shouldering up the WINDWARD face to
    # about half height, so the berg's silhouette is a massif, not a column.
    ba = lean_a + math.pi
    bx0, bz0 = math.cos(ba) * 62.0, math.sin(ba) * 62.0
    bfoot = _drop_to_ground(ground, bx0, bz0)
    if bfoot is None:
        bfoot = foot
    for i in range(10):
        t = i / 9
        r = (12.0 + 50.0 * (1.0 - t) ** 0.85) * random.uniform(0.85, 1.15)
        pull = t * 40.0  # it leans IN against the trunk as it climbs
        add_blob(bm, (bx0 - math.cos(ba) * pull, bz0 - math.sin(ba) * pull, bfoot + 6.0 + t * 132.0),
                 (r, r * random.uniform(0.6, 0.95), (11.0 + 7.0 * (1.0 - t)) * random.uniform(0.8, 1.2)),
                 0.46, 480 + i * 4.3, yaw=i * 1.9)
    # ...and a lower ridge spur on the third face, breaking the round plan.
    sa = lean_a + 2.1
    sx0, sz0 = math.cos(sa) * 52.0, math.sin(sa) * 52.0
    sfoot = _drop_to_ground(ground, sx0, sz0)
    if sfoot is not None:
        for i in range(7):
            t = i / 6
            r = (9.0 + 26.0 * (1.0 - t) ** 0.8) * random.uniform(0.85, 1.15)
            pull = t * 34.0
            add_blob(bm, (sx0 - math.cos(sa) * pull, sz0 - math.sin(sa) * pull, sfoot + 4.0 + t * 74.0),
                     (r, r * random.uniform(0.55, 0.9), (10.0 + 6.0 * (1.0 - t)) * random.uniform(0.8, 1.2)),
                     0.48, 540 + i * 5.7, yaw=i * 2.4)

    # Crown: heavy blocks that keep walking out past the trunk into a genuine
    # overhang, then a fan of summit shards leaning off the high side.
    cx, cz, y = top
    for i in range(4):
        f = (i + 1) / 4
        w = 24.0 - i * 3.6
        add_blob(bm, (cx + lx * f * 34.0, cz + lz * f * 34.0, y + 4.0 + f * 42.0),
                 (w, w * random.uniform(0.6, 0.9), 14.0 + (1.0 - f) * 9.0),
                 0.46, 320 + i * 6.1, yaw=i * 1.7)
    cx += lx * 34.0
    cz += lz * 34.0
    y += 46.0
    peak = 0.0
    for i in range(5):
        a = (i / 5) * math.tau + 0.4
        d = random.uniform(2.0, 12.0)
        h = random.uniform(38.0, 66.0) * (1.55 if i == 0 else 1.0)
        peak = max(peak, h)
        add_cone(bm, Vector((cx + math.cos(a) * d, cz + math.sin(a) * d, y - 10.0)),
                 random.uniform(5.0, 9.5), 0.5, h, sides=5,
                 tilt=(random.uniform(0.08, 0.30), 0.0), yaw=a + math.pi)
    print(f"[island_gen] frostmaw berg: foot Y~{foot:.1f}, crown top ~{y + peak:.0f}, lean reach ~{130.0:.0f}")


def build_ice_seracs(ground):
    """The glacial heart: THE BERG on the central ridge, shattered bergy bits
    around its skirts, and clustered forests of huge ice spikes out on the
    walkable sheet - open in the middle where the fishing holes are cut, with
    plain ice between the clusters so every hole stays reachable on foot."""
    bm = bmesh.new()
    _ICE_SPIKES.clear()
    _ice_berg(bm, ground)

    # Bergy bits: the shattered apron between the berg and the sheet.
    for i in range(24):
        spot = _interior_spot(ground, 0.34, 0.54, pad=3.0, tries=15)
        if spot is None:
            continue
        x, z, surface = spot
        s = random.uniform(4.0, 11.0)
        add_blob(bm, (x, z, surface - s * 0.25), (s, s * 0.75, s * random.uniform(0.8, 1.6)), 0.45,
                 400 + i * 4.9, yaw=random.uniform(0, math.tau))

    # The spike forests: a ring of shards around each field's open middle.
    planted = 0
    for ci, (cx, cz, crad) in enumerate(_ICE_CLUSTERS):
        for k in range(11):
            for _ in range(12):
                a = random.uniform(0, math.tau)
                d = random.uniform(crad * 0.55, crad * 1.15)
                x, z = cx + math.cos(a) * d, cz + math.sin(a) * d
                theta = math.atan2(z, x)
                r = math.hypot(x, z)
                if r > ring_radius(0.93, theta) or r < ring_radius(0.55, theta):
                    continue
                if _ice_keepout(x, z) or not _clear_of_ponds(x, z, 9.0):
                    continue
                rb = random.uniform(3.0, 10.5)
                if not _ice_spike_clear(x, z, rb):
                    continue
                h = rb * random.uniform(6.0, 15.0)
                if _ice_spike(bm, ground, x, z, h, rb, salt=500 + ci * 13.0 + k * 2.3,
                              lean=random.uniform(-0.13, 0.13), lean_yaw=a):
                    planted += 1
                break

    # Loose shards scattered between the forests, so the sheet is never bare.
    for i in range(34):
        theta = random.uniform(0, math.tau)
        u = random.uniform(0.56, 0.92)
        r = ring_radius(u, theta)
        x, z = math.cos(theta) * r, math.sin(theta) * r
        if _near_dock_corridor(theta, u) or _ice_keepout(x, z) or not _clear_of_ponds(x, z, 9.0):
            continue
        rb = random.uniform(2.4, 5.6)
        if not _ice_spike_clear(x, z, rb):
            continue
        if _ice_spike(bm, ground, x, z, rb * random.uniform(7.0, 12.0), rb, salt=900 + i * 7.7,
                      lean=random.uniform(-0.16, 0.16), lean_yaw=random.uniform(0, math.tau)):
            planted += 1
    print(f"[island_gen] ice spikes: {planted}")
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
            # A believable STRATOVOLCANO (2026-08-26 revamp, replacing the
            # 940-stud needle): a broad 1,280-stud-wide cone with CONCAVE
            # flanks - ~40 deg under the crater lip easing to ~10 deg where it
            # meets the apron - topping out at a ragged crater lip around 225.
            # The mountain is now CLIMBED, not just looked at: a 7-leg
            # switchback trail (build_volcano_terraces) benches up the face
            # you land on, with a wide landing at every hairpin, so an
            # eruption raid has somewhere to happen all the way up. The
            # playable ground is still the ash apron at the foot, its props
            # and its molten ponds, and the fishing dock is still the plain
            # shore jetty into the SEA - both unchanged, so the S4 lane keys
            # (dock start Z=526.5, deck Y=2.71, spawn ground ~6.6) still hold.
            # Radius stays capped at 640 for Roblox's 2048-stud import limit.
            "ISLAND_RADIUS": 640,
            "SEGMENTS": 72,  # a walk-scale facet on the flanks the player crosses
            "GRASS_U": 0.70,  # basalt cone above, ash apron below
            "RINGS": [
                0.0, 0.045, 0.075, 0.110, 0.155, 0.190,  # crater floor -> lip -> shoulder
                0.25, 0.32, 0.40, 0.48, 0.56, 0.63,  # the concave flank
                0.70, 0.76, 0.82, 0.90, 1.0, 1.09, 1.28,  # apron -> shore -> skirt
            ],  # fmt: skip
            # The stratovolcano silhouette: a crater floor under the lake, a
            # steep inner wall, the ragged summit lip at 225, then a CONCAVE
            # outer flank - steepest (~40 deg) just under the lip, easing
            # steadily to ~10 deg where it meets the apron. That concavity is
            # what makes it read as a mountain rather than a spike, and it is
            # what makes the switchback grade a walk (~6%) instead of a
            # scramble. PEAK_JAG breaks the lip into an asymmetric ridgeline
            # (+-16 studs), so the rim is 225 +- the jag, not one clean height.
            "PROFILE": [
                (0.000, 150.0),  # crater floor (under the summit lava lake)
                (0.075, 150.0),
                (0.110, 178.0),  # inner crater wall
                (0.155, 225.0),  # the summit lip
                (0.190, 218.0),  # lip shoulder - the trail tops out here
                (0.250, 186.0),  # ~40 deg
                (0.320, 152.0),  # ~37 deg
                (0.400, 118.0),  # ~34 deg
                (0.480, 88.0),  # ~30 deg
                (0.560, 62.0),  # ~27 deg
                (0.630, 44.0),  # ~22 deg
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
            "LAVA_LEVEL": 200.0,  # summit lake, below even the lowest jagged lip
            "LAKE_U": 0.135,  # laps the inner crater wall; ~170-stud-wide lake
            # The broken ridgeline: three incommensurate angular waves, up to
            # ~70 studs of rise/fall around the crater mouth and shoulders.
            "PEAK_JAG": 16.0,
            "PEAK_TERMS": [(2, 0.8, 0.45), (3, 2.6, 0.35), (5, 1.1, 0.20)],
            # Very jagged: strong outline wobble + heavy broad crag on the
            # flanks + radial jitter, so the cone reads as shattered rock.
            "COAST_TERMS": [(2, 1.0, 0.12), (3, 3.0, 0.09), (5, 0.5, 0.07), (8, 2.0, 0.06)],
            "GRASS_TERMS": [(2, 0.9, 0.06), (4, 1.5, 0.05)],
            "CRAG": 16.0,  # broken rock, but scaled to a 225-stud mountain
            "CRAG_FREQ": 0.016,  # broad ribs, not fine noise
            "CRAG_RADIAL": 0.05,  # gentle, so the foam ring still meets the real shore
            # Quiet the crag across the face the switchbacks are cut into, so
            # the trail benches into believable ground; the other three
            # quarters of the cone keep every stud of it.
            "CRAG_CALM": (math.radians(270), math.radians(52), 0.50),
            # NINE gashes in the crater lip - "much more lava" (user,
            # 2026-08-26): one full-flank flow pours out of each and dies in a
            # cascade of molten pools on the apron, so the flank is threaded
            # with rivers instead of showing broad grey gaps between four.
            #
            # (angle, angular half-width, depth). The three numbers are all
            # deliberately UNEVEN across the list: spacing runs 20-36 deg,
            # half-widths 7-16 deg and depths 56-74, so the lip reads as
            # shattered in different places by different amounts rather than
            # stamped at nine identical spouts. build_lava reads the width and
            # depth back out to size each flow - the 16-deg/74-deep gash at 24
            # is THE main breach and pours the widest river; the narrow
            # shallow ones at 48/126/158 are seeps beside it. Where two windows
            # just touch (341/0, 0/24) the lip reads as one long broken
            # section, which is the intent.
            #
            # Depths must drop the 225 lip below the 200 lake (>25, and >41 to
            # beat the +16 peak jag); peak_jag is also zeroed inside each notch
            # window so a high ridge beside a gash can't seal it.
            #
            # THE ANGLES ARE THE HALF OF USER RULE (1) THAT LIVES IN DATA: the
            # lava-free wedge is 270 +- 62 deg (the dock bearing and the whole
            # switchback face, plus margin - see LAVA_CLEAR_HALF), so every
            # notch centre sits in the clear arc 332..208 going through 0. The
            # code-side half of the rule (_lava_theta) then holds every flow,
            # pool and side branch inside that arc no matter how it wanders.
            "NOTCHES": [
                (math.radians(341), math.radians(9), 60.0),
                (math.radians(0), math.radians(10), 66.0),
                (math.radians(24), math.radians(16), 74.0),  # the main breach
                (math.radians(48), math.radians(8), 57.0),
                (math.radians(72), math.radians(12), 65.0),
                (math.radians(98), math.radians(15), 71.0),
                (math.radians(126), math.radians(9), 62.0),
                (math.radians(158), math.radians(7), 56.0),
                (math.radians(194), math.radians(12), 68.0),
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
                "M_VolPath": (0.33, 0.30, 0.29),  # trodden ash of the switchback trail
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
            # Dense enough that a 14-stud channel and its banks actually
            # resolve in the radial fan - the fen's shape IS its water.
            "SEGMENTS": 160,
            "GRASS_U": 0.74,  # a narrower mud band; the old ring read as dead
            "RINGS": [
                0.0, 0.045, 0.09, 0.135, 0.18, 0.225, 0.27, 0.315, 0.36, 0.405,
                0.45, 0.495, 0.54, 0.585, 0.63, 0.675, 0.74, 0.79, 0.84, 0.88,
                0.92, 0.96, 1.0, 1.09, 1.28,
            ],
            # Barely a rise at all: the interior sits ~1.3 studs proud of the
            # standing water (FEN_WATER_Z 3.2), so the marsh network floods
            # most of it and mud and water interleave. Everything from u=0.80
            # out is UNCHANGED, which is what keeps the dock deck height (2.4),
            # the spawn shelf and the shoreline exactly where they were.
            "PROFILE": [
                (0.00, 4.8),
                (0.18, 4.7),
                (0.32, 4.6),
                (0.46, 4.5),
                (0.58, 4.3),
                (0.70, 3.9),
                (0.80, 2.9),
                (0.88, 1.1),
                (1.00, 0.6),
                (1.09, -1.8),
                (1.28, SKIRT_BOTTOM),
            ],
            # A heavily lobed, creeky coastline - fingers of mud and water.
            "COAST_TERMS": [(2, 0.7, 0.13), (3, 2.9, 0.10), (5, 1.6, 0.08), (9, 0.4, 0.045)],
            "GRASS_TERMS": [(2, 1.1, 0.10), (3, 0.4, 0.075), (5, 2.3, 0.05)],
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
                "M_Peat": (0.243, 0.322, 0.204),  # waterlogged moss-peat (kept light enough
                # that the murk pools read as water against it)
                "M_Mud": (0.396, 0.333, 0.235),  # the mud "beach"
                "M_WetMud": (0.290, 0.247, 0.184),
                "M_SwampWater": (0.153, 0.239, 0.196),  # opaque murk - you can't see what's biting
                # (a hair lighter than the peat, so the marsh still reads as
                # water under the shade of the canopy roof)
                "M_Cypress": (0.357, 0.278, 0.196),
                "M_Moss": (0.325, 0.451, 0.243),
                "M_MossDark": (0.235, 0.353, 0.208),  # the second canopy pad
                "M_HangMoss": (0.451, 0.514, 0.365),  # spanish moss trailing off the roof
                "M_Lily": (0.451, 0.643, 0.318),  # lily pads: the fen's colour pop
                "M_BogStone": (0.353, 0.365, 0.333),  # sunken bog stones / menhir
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
                (0.00, 40.0),  # the glacial ridge - the berg's seat
                (0.12, 33.0),
                (0.26, 17.0),
                (0.38, 9.2),
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
