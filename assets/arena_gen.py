# arena_gen.py
# Generates the boss LAIR ARENAS (docs: the boss revamp's dedicated fight
# spaces, BossArenas.luau) as low-poly meshes, one glb per arena. Run headless:
#
#   blender --background --python assets/arena_gen.py -- assets/arena_brinejaw.glb brinejaw
#   blender --background --python assets/arena_gen.py -- assets/arena_brinejaw.glb brinejaw preview
#
# The second form also renders assets/arena_brinejaw_preview.png.
#
# Import contract (BossArenaService.placeAuthored): every object is prefixed
# <Model>_ with a <Model>_Base present - the service anchors the group on the
# _Base part's XZ centre and pins the model's bbox bottom to the arena row's
# meshBottom. Author to the island conventions: 1 unit = 1 stud, Y-up export,
# waterline at z = 0, skirt bottom at z = -9 (so meshBottom stays the default).
# Model names come from BossArenas.items[islandId].model ("BrinejawArena").
#
# BRINEJAW / Tidebreak Spire (cove boss, design locked 2026-08-29):
#   - sand ring walkable to r~70, boundary reef rocks + coral to r~80, surf
#     foam ring outside (named *_Foam: OceanController rides it on the tide
#     for free), underwater skirt flaring to r~88.
#   - broken lighthouse spire in the centre - the serpent's perch. The coil
#     stack and the head/tail meshes are the BOSS pass, not authored here;
#     the spire's radius profile is printed in the HANDOFF for that pass.
#   - three REEF STONES on the sand ring (fight furniture: the slam-bait
#     targets), separate objects so the fight logic can find and shatter
#     each: <Model>_ReefStone1..3. Positions printed in the HANDOFF.
#   - dressing: fallen lantern-room rubble at the spire's foot, a shattered
#     rowboat, a half-buried bell.
#
# Deterministic: seeded random only, so re-exports are byte-stable.

import math
import random
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

TAU = math.tau

SKIRT_BOTTOM = -9.0

# ---------------------------------------------------------------- scene / io


def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for block in (bpy.data.meshes, bpy.data.materials):
        for datum in list(block):
            if datum.users == 0:
                block.remove(datum)


def make_material(name, color):
    mat = bpy.data.materials.get(name)
    if mat is None:
        mat = bpy.data.materials.new(name)
        mat.use_nodes = True
        bsdf = mat.node_tree.nodes.get("Principled BSDF")
        if bsdf:
            bsdf.inputs["Base Color"].default_value = (*color, 1.0)
            bsdf.inputs["Roughness"].default_value = 0.95
    return mat


def finish(name, bm, color):
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(make_material(name, color))
    for poly in mesh.polygons:
        poly.use_smooth = False
    return obj


# ---------------------------------------------------------------- primitives


def box(bm, center, size, rot=None):
    mat = Matrix.Translation(Vector(center))
    if rot is not None:
        mat = mat @ rot.to_4x4()
    mat = mat @ Matrix.Diagonal(Vector(size) / 2).to_4x4()
    bmesh.ops.create_cube(bm, size=2.0, matrix=mat)


def rock(bm, center, radii, rng, jitter=0.35):
    # An icosphere with jittered verts - the classic low-poly boulder.
    mat = Matrix.Translation(Vector(center)) @ Matrix.Diagonal(Vector(radii)).to_4x4()
    result = bmesh.ops.create_icosphere(bm, subdivisions=1, radius=1.0, matrix=mat)
    for vert in result["verts"]:
        offset = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1)))
        vert.co += offset * jitter * min(radii)


def cone(bm, base, tip, r, sides=6):
    base, tip = Vector(base), Vector(tip)
    axis = tip - base
    if axis.length < 1e-6:
        return
    rot = Vector((0, 0, 1)).rotation_difference(axis.normalized()).to_matrix()
    mat = Matrix.Translation((base + tip) / 2) @ rot.to_4x4()
    bmesh.ops.create_cone(
        bm, cap_ends=True, segments=sides, radius1=r, radius2=0.05, depth=axis.length, matrix=mat
    )


def tapered_cylinder(bm, z0, z1, r0, r1, sides=12, center=(0, 0)):
    mat = Matrix.Translation(Vector((center[0], center[1], (z0 + z1) / 2)))
    bmesh.ops.create_cone(
        bm, cap_ends=True, segments=sides, radius1=r0, radius2=r1, depth=z1 - z0, matrix=mat
    )


# ---------------------------------------------------------------- brinejaw

# Radial profile of the sand landform: (radius, height). Between rings the
# surface lerps; a seeded jitter roughs it up. Centre mound carries the
# spire's footing; the beach slips underwater past r~72 and the skirt dives
# to SKIRT_BOTTOM.
BJ_PROFILE = [
    (0.0, 3.2),
    (10.0, 3.0),
    (16.0, 2.2),
    (30.0, 1.6),
    (48.0, 1.4),
    (62.0, 1.0),
    (70.0, 0.4),
    (76.0, -1.6),
    (82.0, -5.0),
    (88.0, SKIRT_BOTTOM),
]

BJ_SPIRE_BASE_R = 8.5
BJ_SPIRE_TOP_R = 5.2
BJ_SPIRE_TOP_Z = 54.0  # shaft top; the ruined lantern room rises above this
BJ_REEF_STONES = [(40.0, 15.0), (40.0, 135.0), (40.0, 255.0)]  # (radius, degrees)

SAND = (0.87, 0.76, 0.5)
STONE = (0.55, 0.52, 0.47)
BAND = (0.72, 0.30, 0.24)
ROCKS = (0.3, 0.28, 0.26)
CORAL_PINK = (0.9, 0.45, 0.5)
CORAL_TEAL = (0.32, 0.72, 0.66)
FOAM = (0.96, 0.98, 0.98)
DRIFTWOOD = (0.45, 0.34, 0.24)
BRONZE = (0.42, 0.5, 0.42)


def _bj_height(r):
    for (r0, h0), (r1, h1) in zip(BJ_PROFILE, BJ_PROFILE[1:]):
        if r <= r1:
            t = 0 if r1 == r0 else (r - r0) / (r1 - r0)
            return h0 + (h1 - h0) * t
    return BJ_PROFILE[-1][1]


def build_bj_base(rng):
    bm = bmesh.new()
    rings = [row[0] for row in BJ_PROFILE]
    angles = 30
    grid = []
    for radius in rings:
        ring = []
        for i in range(angles):
            angle = (i / angles) * TAU
            wobble = 1.0 + (rng.uniform(-0.035, 0.035) if radius > 4 else 0)
            r = radius * wobble
            z = _bj_height(radius) + (rng.uniform(-0.22, 0.22) if 4 < radius < 74 else 0)
            ring.append(bm.verts.new((math.cos(angle) * r, math.sin(angle) * r, z)))
        grid.append(ring)
    centre = bm.verts.new((0, 0, BJ_PROFILE[0][1]))
    for i in range(angles):
        bm.faces.new((centre, grid[1][i], grid[1][(i + 1) % angles]))
    for a, b in zip(grid[1:], grid[2:]):
        for i in range(angles):
            j = (i + 1) % angles
            bm.faces.new((a[i], b[i], b[j], a[j]))
    # Close the underside so the skirt reads solid from below.
    bottom = bm.verts.new((0, 0, SKIRT_BOTTOM - 0.5))
    outer = grid[-1]
    for i in range(angles):
        bm.faces.new((bottom, outer[(i + 1) % angles], outer[i]))
    return finish("BrinejawArena_Base", bm, SAND)


def build_bj_spire(rng):
    bm = bmesh.new()
    # A REAL lighthouse silhouette: octagonal plinth, then a tall shaft in
    # three tapering drums, a corbel flare under the gallery, the gallery
    # walkway disc, and the ruined lantern-room floor above it.
    tapered_cylinder(bm, 0.5, 3.5, BJ_SPIRE_BASE_R + 2.2, BJ_SPIRE_BASE_R + 1.4, sides=8)  # plinth
    tapered_cylinder(bm, 3.5, 20.0, BJ_SPIRE_BASE_R, 7.4, sides=12)
    tapered_cylinder(bm, 20.0, 38.0, 7.2, 6.2, sides=12)
    tapered_cylinder(bm, 38.0, BJ_SPIRE_TOP_Z, 6.0, BJ_SPIRE_TOP_R, sides=12)
    # Corbel flare + gallery walkway.
    tapered_cylinder(bm, BJ_SPIRE_TOP_Z, BJ_SPIRE_TOP_Z + 1.4, BJ_SPIRE_TOP_R + 0.4, BJ_SPIRE_TOP_R + 1.9, sides=12)
    tapered_cylinder(bm, BJ_SPIRE_TOP_Z + 1.4, BJ_SPIRE_TOP_Z + 2.2, BJ_SPIRE_TOP_R + 2.1, BJ_SPIRE_TOP_R + 2.1, sides=12)
    # Lantern-room floor stub the broken posts stand on.
    tapered_cylinder(bm, BJ_SPIRE_TOP_Z + 2.2, BJ_SPIRE_TOP_Z + 3.0, BJ_SPIRE_TOP_R + 0.2, BJ_SPIRE_TOP_R + 0.2, sides=10)
    # Storm-bitten masonry: a few jagged breaks on the gallery rim.
    for i in range(3):
        angle = (i / 3) * TAU + 0.9
        x, y = math.cos(angle) * (BJ_SPIRE_TOP_R + 1.6), math.sin(angle) * (BJ_SPIRE_TOP_R + 1.6)
        cone(bm, (x, y, BJ_SPIRE_TOP_Z + 2.0), (x, y, BJ_SPIRE_TOP_Z + rng.uniform(3.2, 4.4)), 0.8, sides=4)
    return finish("BrinejawArena_Spire", bm, STONE)


def build_bj_spire_band():
    bm = bmesh.new()
    # The faded keeper's paint bands - instantly reads "lighthouse".
    tapered_cylinder(bm, 24.0, 31.0, 7.05, 6.85, sides=12)
    tapered_cylinder(bm, 42.0, 47.0, 5.95, 5.75, sides=12)
    return finish("BrinejawArena_SpireBand", bm, BAND)


def build_bj_spire_detail(rng):
    dark = bmesh.new()
    # The keeper's door: an arched dark inset on the plinth, facing the
    # spawn bearing (-Y), with a stone lintel above it.
    box(dark, (0, -(BJ_SPIRE_BASE_R + 1.1), 3.2), (2.6, 1.6, 4.2))
    # Window slits climbing the shaft, staggered around it.
    for i in range(5):
        angle = math.radians(-90 + i * 65)
        z = 12.0 + i * 8.5
        r = 8.0 - i * 0.55
        x, y = math.cos(angle) * r, math.sin(angle) * r
        rot = Matrix.Rotation(angle + math.pi / 2, 3, "Z")
        box(dark, (x, y, z), (1.1, 1.0, 2.2), rot)
    obj_dark = finish("BrinejawArena_SpireWindows", dark, (0.16, 0.17, 0.2))

    rail = bmesh.new()
    # Gallery railing: posts around the walkway, a few snapped short.
    posts = 12
    for i in range(posts):
        angle = (i / posts) * TAU
        x, y = math.cos(angle) * (BJ_SPIRE_TOP_R + 1.8), math.sin(angle) * (BJ_SPIRE_TOP_R + 1.8)
        h = 2.0 if i % 4 != 1 else rng.uniform(0.5, 1.0)
        box(rail, (x, y, BJ_SPIRE_TOP_Z + 2.2 + h / 2), (0.28, 0.28, h))
    # Lantern-room skeleton: four corner posts (one snapped), and the old
    # light cage - a small empty frame where the lamp was.
    for i in range(4):
        angle = (i / 4) * TAU + 0.4
        x, y = math.cos(angle) * (BJ_SPIRE_TOP_R - 0.7), math.sin(angle) * (BJ_SPIRE_TOP_R - 0.7)
        h = 4.6 if i != 2 else 1.6
        box(rail, (x, y, BJ_SPIRE_TOP_Z + 3.0 + h / 2), (0.45, 0.45, h))
    box(rail, (0, 0, BJ_SPIRE_TOP_Z + 4.6), (1.6, 1.6, 1.6))
    # The collapsed roof: a cone shard leaning against the tallest posts.
    base = Vector((0.8, 0.6, BJ_SPIRE_TOP_Z + 7.2))
    cone(rail, base, base + Vector((1.2, 1.0, 3.4)), 3.4, sides=8)
    return obj_dark, finish("BrinejawArena_SpireRail", rail, DRIFTWOOD)


def build_bj_rubble(rng):
    bm = bmesh.new()
    # The fallen lantern-room: a broken stone ring lying in the sand, plus
    # scattered masonry chunks at the spire's foot.
    ring_at = Vector((16.0, -10.0, 1.6))
    for i in range(5):
        angle = (i / 8) * TAU
        chunk = ring_at + Vector((math.cos(angle) * 4.2, math.sin(angle) * 4.2, 0))
        box(
            bm,
            chunk,
            (2.4, 1.4, rng.uniform(1.2, 2.4)),
            Matrix.Rotation(rng.uniform(0, TAU), 3, "Z") @ Matrix.Rotation(rng.uniform(-0.3, 0.3), 3, "X"),
        )
    for _ in range(6):
        angle = rng.uniform(0, TAU)
        r = rng.uniform(10.5, 15.0)
        rock(bm, (math.cos(angle) * r, math.sin(angle) * r, 1.5), (rng.uniform(0.8, 1.6),) * 3, rng)
    return finish("BrinejawArena_Rubble", bm, STONE)


def build_bj_rocks(rng):
    bm = bmesh.new()
    # The boundary: clusters of reef teeth ringing the sand at r 74-80.
    clusters = 22
    for i in range(clusters):
        angle = (i / clusters) * TAU + rng.uniform(-0.08, 0.08)
        r = rng.uniform(74, 79)
        cx, cy = math.cos(angle) * r, math.sin(angle) * r
        for _ in range(rng.randint(3, 5)):
            ox, oy = rng.uniform(-3.5, 3.5), rng.uniform(-3.5, 3.5)
            h = rng.uniform(2.5, 7.5)
            rock(bm, (cx + ox, cy + oy, h * 0.25), (rng.uniform(2.2, 4.0), rng.uniform(2.2, 4.0), h), rng, jitter=0.25)
    return finish("BrinejawArena_Rocks", bm, ROCKS)


def _bj_coral_cluster(bm, cx, cy, rng):
    for _ in range(rng.randint(3, 5)):
        ox, oy = rng.uniform(-2, 2), rng.uniform(-2, 2)
        h = rng.uniform(1.4, 3.0)
        cone(bm, (cx + ox, cy + oy, 0.4), (cx + ox + rng.uniform(-0.6, 0.6), cy + oy + rng.uniform(-0.6, 0.6), h), rng.uniform(0.35, 0.7), sides=5)


def build_bj_coral(rng):
    pink = bmesh.new()
    teal = bmesh.new()
    spots = 9
    for i in range(spots):
        angle = (i / spots) * TAU + 0.4 + rng.uniform(-0.1, 0.1)
        r = rng.uniform(66, 72)
        _bj_coral_cluster(pink if i % 2 == 0 else teal, math.cos(angle) * r, math.sin(angle) * r, rng)
    return (
        finish("BrinejawArena_CoralPink", pink, CORAL_PINK),
        finish("BrinejawArena_CoralTeal", teal, CORAL_TEAL),
    )


def build_bj_foam(rng):
    bm = bmesh.new()
    # Surf ring outside the rocks. Named *_Foam so OceanController lifts it
    # on the tide. A thin wavy annulus just above the waterline.
    angles = 36
    inner, outer = [], []
    for i in range(angles):
        angle = (i / angles) * TAU
        r0 = 80.0 + rng.uniform(-1.2, 1.2)
        r1 = 86.0 + rng.uniform(-1.8, 1.8)
        inner.append(bm.verts.new((math.cos(angle) * r0, math.sin(angle) * r0, 0.28)))
        outer.append(bm.verts.new((math.cos(angle) * r1, math.sin(angle) * r1, 0.22)))
    for i in range(angles):
        j = (i + 1) % angles
        bm.faces.new((inner[i], outer[i], outer[j], inner[j]))
    result = bmesh.ops.solidify(bm, geom=list(bm.faces) + list(bm.verts) + list(bm.edges), thickness=0.25)
    _ = result
    return finish("BrinejawArena_Foam", bm, FOAM)


def build_bj_reef_stones():
    objs = []
    rng = random.Random(77)
    for index, (radius, degrees) in enumerate(BJ_REEF_STONES):
        bm = bmesh.new()
        angle = math.radians(degrees)
        cx, cy = math.cos(angle) * radius, math.sin(angle) * radius
        rock(bm, (cx, cy, 1.1), (1.9, 1.9, 1.5), rng, jitter=0.2)
        rock(bm, (cx + 1.1, cy - 0.8, 0.7), (0.9, 0.9, 0.8), rng, jitter=0.25)
        objs.append(finish("BrinejawArena_ReefStone%d" % (index + 1), bm, ROCKS))
    return objs


def build_bj_dressing(rng):
    bm = bmesh.new()
    # Shattered rowboat, beached and listing.
    boat_at = Vector((-34.0, 42.0, 1.2))
    heading = Matrix.Rotation(math.radians(35), 3, "Z")
    for side in (-1, 1):
        box(
            bm,
            boat_at + heading @ Vector((0, side * 1.5, 0.6)),
            (9.0, 0.5, 2.0),
            heading @ Matrix.Rotation(math.radians(side * -14), 3, "X"),
        )
    box(bm, boat_at + heading @ Vector((-4.4, 0, 0.6)), (0.6, 3.2, 1.9), heading)
    box(bm, boat_at + Vector((0, 0, 0.1)), (8.4, 2.8, 0.4), heading @ Matrix.Rotation(math.radians(4), 3, "Y"))
    obj_boat = finish("BrinejawArena_Boat", bm, DRIFTWOOD)

    bm = bmesh.new()
    # The keeper's bell, half-buried, tarnished green.
    bell_at = Vector((26.0, 38.0, 0.6))
    mat = Matrix.Translation(bell_at) @ Matrix.Rotation(math.radians(28), 3, "X").to_4x4()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=10, radius1=2.4, radius2=1.1, depth=3.4, matrix=mat)
    rock(bm, bell_at + Vector((0, 1.6, 1.6)), (0.5, 0.5, 0.5), rng, jitter=0.1)
    obj_bell = finish("BrinejawArena_Bell", bm, BRONZE)
    return obj_boat, obj_bell


def build_bj_floor_detail(rng):
    # Tide pools: shallow teal discs sitting in the sand between the reef
    # stones - visual variety on the big open ring (visual-only, stripped of
    # collision by naming convention).
    pools = bmesh.new()
    for radius, degrees, size in ((28, 70, 6.5), (52, 200, 8.0), (55, 320, 5.0), (30, 300, 4.0)):
        angle = math.radians(degrees)
        tapered_cylinder(
            pools, 1.35, 1.75, size, size * 0.92, sides=9, center=(math.cos(angle) * radius, math.sin(angle) * radius)
        )
    obj_pools = finish("BrinejawArena_TidePools", pools, (0.30, 0.62, 0.62))

    # Shells and starfish scattered on the sand.
    shells = bmesh.new()
    for _ in range(14):
        angle, r = rng.uniform(0, TAU), rng.uniform(16, 66)
        x, y = math.cos(angle) * r, math.sin(angle) * r
        rock(shells, (x, y, 1.55), (rng.uniform(0.3, 0.6), rng.uniform(0.3, 0.5), 0.25), rng, jitter=0.2)
    obj_shells = finish("BrinejawArena_Shells", shells, (0.94, 0.9, 0.82))

    stars = bmesh.new()
    for _ in range(6):
        angle, r = rng.uniform(0, TAU), rng.uniform(20, 62)
        cx, cy = math.cos(angle) * r, math.sin(angle) * r
        spin = rng.uniform(0, TAU)
        for arm in range(5):
            a = spin + (arm / 5) * TAU
            cone(stars, (cx, cy, 1.55), (cx + math.cos(a) * 1.1, cy + math.sin(a) * 1.1, 1.5), 0.3, sides=4)
    obj_stars = finish("BrinejawArena_Starfish", stars, (0.85, 0.42, 0.5))

    # Seaweed tufts near the water line and the pools.
    weed = bmesh.new()
    for _ in range(9):
        angle, r = rng.uniform(0, TAU), rng.uniform(58, 70)
        cx, cy = math.cos(angle) * r, math.sin(angle) * r
        for _ in range(rng.randint(2, 4)):
            ox, oy = rng.uniform(-1.2, 1.2), rng.uniform(-1.2, 1.2)
            cone(weed, (cx + ox, cy + oy, 0.7), (cx + ox + rng.uniform(-0.5, 0.5), cy + oy + rng.uniform(-0.5, 0.5), rng.uniform(1.8, 3.2)), 0.3, sides=4)
    obj_weed = finish("BrinejawArena_Seaweed", weed, (0.2, 0.42, 0.3))

    # Half-buried planks and a rope coil - keeper's flotsam.
    wood = bmesh.new()
    for _ in range(5):
        angle, r = rng.uniform(0, TAU), rng.uniform(24, 60)
        x, y = math.cos(angle) * r, math.sin(angle) * r
        wood_rot = Matrix.Rotation(rng.uniform(0, TAU), 3, "Z") @ Matrix.Rotation(rng.uniform(-0.15, 0.15), 3, "X")
        box(wood, (x, y, 1.35), (rng.uniform(3.5, 5.5), 0.8, 0.35), wood_rot)
    for i in range(2):  # the rope coil: two stacked squashed rings
        tapered_cylinder(wood, 1.4 + i * 0.35, 1.75 + i * 0.35, 1.6 - i * 0.2, 1.6 - i * 0.2, sides=9, center=(-30.0, 36.0))
    return obj_pools, obj_shells, obj_stars, obj_weed, finish("BrinejawArena_Flotsam", wood, DRIFTWOOD)


def build_bj_edge_detail(rng):
    # Sea stacks: tall rock columns rising OUTSIDE the reef fence - the
    # skyline that makes the boundary read as a place, not a wall.
    stacks = bmesh.new()
    for radius, degrees, h in ((84, 50, 14.0), (86, 150, 18.0), (83, 230, 11.0), (85, 335, 15.0)):
        angle = math.radians(degrees)
        cx, cy = math.cos(angle) * radius, math.sin(angle) * radius
        tapered_cylinder(stacks, -4.0, h, rng.uniform(3.2, 4.6), rng.uniform(1.4, 2.2), sides=7, center=(cx, cy))
        rock(stacks, (cx, cy, h + 0.5), (2.0, 2.0, 1.2), rng, jitter=0.3)
    obj_stacks = finish("BrinejawArena_SeaStacks", stacks, ROCKS)

    # Kelp strands climbing the boundary rocks.
    kelp = bmesh.new()
    for _ in range(12):
        angle = rng.uniform(0, TAU)
        r = rng.uniform(73, 79)
        cx, cy = math.cos(angle) * r, math.sin(angle) * r
        for _ in range(rng.randint(2, 3)):
            ox, oy = rng.uniform(-1.5, 1.5), rng.uniform(-1.5, 1.5)
            cone(kelp, (cx + ox, cy + oy, 1.0), (cx + ox + rng.uniform(-0.8, 0.8), cy + oy + rng.uniform(-0.8, 0.8), rng.uniform(4.0, 7.0)), 0.35, sides=4)
    obj_kelp = finish("BrinejawArena_Kelp", kelp, (0.16, 0.36, 0.26))

    # A wrecked mast leaning through the reef ring, sail rag still hanging -
    # the ship the rowboat came from.
    mast = bmesh.new()
    base = Vector((40.0, -35.0, 0.8))
    tip = Vector((64.0, -55.0, 10.0))
    axis = tip - base
    rot = Vector((0, 0, 1)).rotation_difference(axis.normalized()).to_matrix()
    mat = Matrix.Translation((base + tip) / 2) @ rot.to_4x4()
    bmesh.ops.create_cone(mast, cap_ends=True, segments=7, radius1=0.9, radius2=0.5, depth=axis.length, matrix=mat)
    spar_mat = Matrix.Translation(base + axis * 0.62) @ rot.to_4x4() @ Matrix.Rotation(math.radians(90), 3, "X").to_4x4()
    bmesh.ops.create_cone(mast, cap_ends=True, segments=6, radius1=0.4, radius2=0.4, depth=10.0, matrix=spar_mat)
    obj_mast = finish("BrinejawArena_Mast", mast, DRIFTWOOD)

    sail = bmesh.new()
    # The rag: a torn triangle slab hanging from the spar.
    hang = base + axis * 0.62
    for i, (w, drop) in enumerate(((4.2, 5.5), (2.6, 3.4))):
        sail_rot = rot @ Matrix.Rotation(math.radians(90), 3, "X") @ Matrix.Rotation(math.radians(8 - i * 16), 3, "Y")
        corner = hang + rot @ Vector((0, (i - 0.5) * 4.5, 0))
        box(sail, corner + Vector((0, 0, -drop / 2)), (0.15, w, drop), sail_rot)
    obj_sail = finish("BrinejawArena_SailRag", sail, (0.88, 0.86, 0.78))
    return obj_stacks, obj_kelp, obj_mast, obj_sail


def build_brinejaw():
    rng = random.Random(4181)
    objects = [
        build_bj_base(rng),
        build_bj_spire(rng),
        build_bj_spire_band(),
        *build_bj_spire_detail(rng),
        build_bj_rubble(rng),
        build_bj_rocks(rng),
        *build_bj_coral(rng),
        build_bj_foam(rng),
        *build_bj_reef_stones(),
        *build_bj_dressing(rng),
        *build_bj_floor_detail(rng),
        *build_bj_edge_detail(rng),
    ]
    print("HANDOFF brinejaw: mesh bottom z %.1f  <-- BossArenas meshBottom (default -9 fits)" % (SKIRT_BOTTOM - 0.5))
    print(
        "HANDOFF brinejaw: spire base r %.1f (z2..16), waist r ~7.3, top r %.1f at z %.1f"
        " (gallery +2.2, lantern posts to +7.6) - coil stack (boss pass) wraps r ~9.5-12" % (BJ_SPIRE_BASE_R, BJ_SPIRE_TOP_R, BJ_SPIRE_TOP_Z)
    )
    for index, (radius, degrees) in enumerate(BJ_REEF_STONES):
        angle = math.radians(degrees)
        print(
            "HANDOFF brinejaw: ReefStone%d rel (%.1f, %.1f) - fight logic slam-bait targets"
            % (index + 1, math.cos(angle) * radius, math.sin(angle) * radius)
        )
    print("HANDOFF brinejaw: walkable sand r ~70, boundary rocks r 74-80, foam ring r 80-86")
    return objects


ARENAS = {
    "brinejaw": build_brinejaw,
}

# ---------------------------------------------------------------- io


def export(path, objects):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.ops.export_scene.gltf(
        filepath=path,
        export_format="GLB",
        use_selection=True,
        export_yup=True,
        export_apply=True,
        export_texcoords=False,
    )
    print("ARENA EXPORTED:", path, "-", len(objects), "objects")
    for obj in objects:
        lo = [min(v.co[i] for v in obj.data.vertices) for i in range(3)]
        hi = [max(v.co[i] for v in obj.data.vertices) for i in range(3)]
        print(
            "  %s bbox x %.1f..%.1f  y %.1f..%.1f  z %.1f..%.1f"
            % (obj.name, lo[0], hi[0], lo[1], hi[1], lo[2], hi[2])
        )


def render_preview(path):
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.rotation_euler = (math.radians(50), 0, math.radians(35))
    sun.data.energy = 1.6
    bpy.context.collection.objects.link(sun)
    cam_data = bpy.data.cameras.new("Cam")
    cam_data.lens = 26
    cam = bpy.data.objects.new("Cam", cam_data)
    cam.location = Vector((120, -165, 70))
    cam.rotation_euler = (math.radians(68), 0, math.radians(36))
    bpy.context.collection.objects.link(cam)
    bpy.context.scene.camera = cam

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1500
    scene.render.resolution_y = 950
    scene.render.filepath = path
    scene.world = bpy.data.worlds.new("World")
    scene.world.use_nodes = True
    bg = scene.world.node_tree.nodes.get("Background")
    if bg:
        bg.inputs[0].default_value = (0.45, 0.65, 0.78, 1.0)
    bpy.ops.render.render(write_still=True)
    print("ARENA PREVIEW:", path)


def main():
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    if len(argv) < 2 or argv[1] not in ARENAS:
        print("usage: blender --background --python arena_gen.py -- <out.glb> <%s> [preview]" % "|".join(ARENAS))
        return
    clear_scene()
    objects = ARENAS[argv[1]]()
    export(argv[0], objects)
    if "preview" in argv[2:]:
        render_preview(argv[0].replace(".glb", "_preview.png"))


main()
