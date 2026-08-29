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
# NAMING (2026-08-29): a part whose name carries `Deco` is stripped of both
# collision and query at runtime (BossArenaService's visual-only list), so
# scattered dressing - moss, reeds, wisps, half-buried roots and stones -
# cannot catch a foot or block a cast, and needs no import-time collision
# care. Anything WITHOUT that marker is real ground the fight stands on and
# must be imported PreciseConvexDecomposition: a Default convex hull over a
# spread scatter is an invisible wall (the volcano dead-tree gotcha).
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
#     rowboat, a half-buried bell. Open sand kept CLEAN on purpose (user,
#     2026-08-29) - the fight paints its own telegraphs on it.
#
# Deterministic: seeded random only, so re-exports are byte-stable.

import math
import random
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector, noise

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


def add_blob(bm, center, scale, roughness, salt, yaw=0.0, subdiv=1):
    """One noise-lumped mass: a low icosphere pushed along its normals, then
    squashed and rotated into place. This is the island's own leaf/boulder
    primitive (island_gen.add_blob) - canopies built any other way read as
    flat parasols rather than foliage."""
    temp = bmesh.new()
    bmesh.ops.create_icosphere(temp, subdivisions=subdiv, radius=1.0)
    for vert in temp.verts:
        bump = noise.noise(vert.co * 1.9 + Vector((salt, salt * 0.7, salt * 1.3)))
        vert.co += vert.co.normalized() * bump * roughness
    matrix = Matrix.Translation(Vector(center)) @ Matrix.Rotation(yaw, 4, "Z") @ Matrix.Diagonal(Vector(scale)).to_4x4()
    bmesh.ops.transform(temp, matrix=matrix, verts=temp.verts[:])
    mesh = bpy.data.meshes.new("_blob")
    temp.to_mesh(mesh)
    temp.free()
    bm.from_mesh(mesh)
    bpy.data.meshes.remove(mesh)


def taper_between(bm, base, tip, r0, r1, sides=7):
    """A truncated cone along an arbitrary axis - trunks, roots, ribs, logs.

    `cone` always tapers to a point; anything that keeps a girth at both ends
    needs this instead.
    """
    base, tip = Vector(base), Vector(tip)
    axis = tip - base
    if axis.length < 1e-6:
        return
    rot = Vector((0, 0, 1)).rotation_difference(axis.normalized()).to_matrix()
    mat = Matrix.Translation((base + tip) / 2) @ rot.to_4x4()
    bmesh.ops.create_cone(
        bm, cap_ends=True, segments=sides, radius1=r0, radius2=r1, depth=axis.length, matrix=mat
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


# ---------------------------------------------------------------- gnashroot
#
# GNASHROOT / The Rootmere (swamp boss, design locked 2026-08-29):
#   - a peat bank walkable from r~29 out to r~70, wrapped round a wide sunken
#     MERE: black standing water 3.4 studs deep out to r 27, where Old
#     Gnashroot lies half-buried. You wade it (the water is DecoMere - the
#     real floor is the carved bowl in _Base), and the bank is where the
#     fight is meant to be fought from.
#   - the bank is BARE (user, 2026-08-29, the same call the Tidebreak Spire
#     got): no patches, stones, logs, bones or root runs. Open peat, so the
#     fight's telegraphs - sweep lines, slam shadows, pool edges - paint on
#     an uncluttered canvas. Dressing lives in the mere or at the grove's
#     foot, never on the ground you fight on.
#   - FOUR STUMP PLATFORMS at r 44 (<Model>_Stump1..4): the boss's own severed
#     limbs from the last time someone fought it, 5 studs proud of the peat
#     with one broad buttress root as a walk-up ramp on the mere-facing side.
#     They are the only ground that stays clean once bogspit pools and
#     deathroll sludge cover the bank, so the fight becomes a rotation between
#     them. Separate objects so the fight logic can find (and later shatter)
#     each; positions in the HANDOFF.
#   - the boundary is a DROWNED CYPRESS GROVE in two ranks at r 67-80, and it
#     is a straight port of island_gen.build_swamp_trees: curved segmented
#     trunks on flared feet, 3-5 limbs that FORK twice into a real skeleton,
#     and noise-lumped canopy masses sitting ON the branch tips (never
#     floating over them), with moss and vines off the same tips. Limbs are
#     biased outward so the crowns lean off the ring - the sky over the fight
#     stays open, because every telegraph in this book paints on the ground.
#   - scum foam ring outside (named *_Foam: OceanController rides it on the
#     tide for free), underwater skirt flaring to r~88.

GN_PROFILE = [
    (0.0, -3.4),  # the mere's bed - waded, not swum
    (16.0, -3.0),
    (24.0, -1.4),
    (29.0, 1.0),  # the bank, just proud of the water
    (36.0, 1.6),
    (50.0, 1.8),
    (62.0, 1.6),
    (70.0, 1.0),  # the peat ends
    (76.0, -1.8),
    (82.0, -5.2),
    (88.0, SKIRT_BOTTOM),
]

GN_MERE_R = 27.0
GN_MERE_Z = 0.0  # sea level: the ocean wells up through the peat
GN_STUMPS = [(44.0, 45.0), (44.0, 135.0), (44.0, 225.0), (44.0, 315.0)]  # (radius, degrees)
GN_GROVE_R = (67.0, 80.0)

# Straight off the fen's own palette (island_gen.py swamp COLORS), so the
# arena and Blackmire read as the same place.
PEAT = (0.243, 0.322, 0.204)
WETMUD = (0.290, 0.247, 0.184)
MURK = (0.105, 0.163, 0.142)
ROOTWOOD = (0.259, 0.208, 0.157)
STUMPWOOD = (0.44, 0.34, 0.25)  # the severed limbs: pale enough to read as standable
CYPRESS = (0.55, 0.42, 0.30)  # M_TrunkWood - the fen's own trunks
LEAF = (0.20, 0.26, 0.17)  # M_WillowLeaf - the canopy masses
HANGMOSS = (0.451, 0.514, 0.365)
VINE = (0.20, 0.27, 0.17)
BOGSTONE = (0.353, 0.365, 0.333)
SCUM = (0.851, 0.878, 0.831)  # scummy pale rim, not white surf
REED = (0.478, 0.525, 0.259)
REEDHEAD = (0.369, 0.243, 0.137)
LILYPAD = (0.451, 0.643, 0.318)
FENBONE = (0.62, 0.60, 0.51)  # old bone, gone the colour of the water
WISP = (0.545, 0.949, 0.729)  # Morra's lantern green - the boss's own light


def _gn_height(r):
    for (r0, h0), (r1, h1) in zip(GN_PROFILE, GN_PROFILE[1:]):
        if r <= r1:
            t = 0 if r1 == r0 else (r - r0) / (r1 - r0)
            return h0 + (h1 - h0) * t
    return GN_PROFILE[-1][1]


def _gn_ground(x, y):
    return _gn_height(math.hypot(x, y))


def build_gn_base(rng):
    bm = bmesh.new()
    angles = 40
    grid = []
    for radius in [row[0] for row in GN_PROFILE][1:]:
        ring = []
        for i in range(angles):
            angle = (i / angles) * TAU
            r = radius * (1.0 + (rng.uniform(-0.03, 0.03) if radius > 30 else 0.0))
            z = _gn_height(radius)
            if 32 < radius < 74:
                # The fen never lies flat: a slow roll across the peat, small
                # enough that nothing rolls out of sight behind it.
                z += math.sin(angle * 3.0 + radius * 0.09) * 0.32 + rng.uniform(-0.1, 0.1)
            ring.append(bm.verts.new((math.cos(angle) * r, math.sin(angle) * r, z)))
        grid.append(ring)
    centre = bm.verts.new((0, 0, GN_PROFILE[0][1]))
    for i in range(angles):
        bm.faces.new((centre, grid[0][i], grid[0][(i + 1) % angles]))
    for a, b in zip(grid, grid[1:]):
        for i in range(angles):
            j = (i + 1) % angles
            bm.faces.new((a[i], b[i], b[j], a[j]))
    # Close the underside so the skirt reads solid from below.
    bottom = bm.verts.new((0, 0, SKIRT_BOTTOM - 0.5))
    outer = grid[-1]
    for i in range(angles):
        bm.faces.new((bottom, outer[(i + 1) % angles], outer[i]))
    return finish("GnashrootArena_Base", bm, PEAT)


def build_gn_mere(rng):
    bm = bmesh.new()
    # Opaque murk - you cannot see what is lying in it until it opens an eye.
    angles = 34
    top, low = [], []
    for i in range(angles):
        angle = (i / angles) * TAU
        r = GN_MERE_R + rng.uniform(-1.1, 1.1)
        x, y = math.cos(angle) * r, math.sin(angle) * r
        top.append(bm.verts.new((x, y, GN_MERE_Z)))
        low.append(bm.verts.new((x, y, GN_MERE_Z - 0.4)))
    centre_top = bm.verts.new((0, 0, GN_MERE_Z))
    centre_low = bm.verts.new((0, 0, GN_MERE_Z - 0.4))
    for i in range(angles):
        j = (i + 1) % angles
        bm.faces.new((centre_top, top[i], top[j]))
        bm.faces.new((centre_low, low[j], low[i]))
        bm.faces.new((top[i], low[i], low[j], top[j]))
    return finish("GnashrootArena_DecoMere", bm, MURK)


def build_gn_shallows(rng):
    bm = bmesh.new()
    # The wet ring where the mere soaks into the peat - the visual join
    # between black water and walkable bank.
    angles = 34
    inner, outer = [], []
    for i in range(angles):
        angle = (i / angles) * TAU
        r0 = 24.5 + rng.uniform(-0.8, 0.8)
        r1 = 34.0 + rng.uniform(-2.2, 2.2)
        inner.append(bm.verts.new((math.cos(angle) * r0, math.sin(angle) * r0, _gn_height(r0) + 0.12)))
        outer.append(bm.verts.new((math.cos(angle) * r1, math.sin(angle) * r1, _gn_height(r1) + 0.12)))
    for i in range(angles):
        j = (i + 1) % angles
        bm.faces.new((inner[i], outer[i], outer[j], inner[j]))
    bmesh.ops.solidify(bm, geom=list(bm.faces) + list(bm.verts) + list(bm.edges), thickness=0.2)
    return finish("GnashrootArena_DecoShallows", bm, WETMUD)


def build_gn_stumps(rng):
    """The four severed limbs: the fight's high, clean ground.

    Read-at-a-glance is the whole job here - a player under pressure has to
    see "platform, ramp, safe" without stopping. So: a straight wood column
    with a genuinely flat top, splinters only on its far rim, one plank-flat
    buttress running down to the peat at ~17 degrees, and every other root
    kept thin and hugging the ground.
    """
    objects = []
    for index, (radius, degrees) in enumerate(GN_STUMPS):
        bm = bmesh.new()
        angle = math.radians(degrees)
        cx, cy = math.cos(angle) * radius, math.sin(angle) * radius
        ground = _gn_height(radius)
        crown_r = 5.4
        top = ground + 5.0
        tapered_cylinder(bm, ground - 2.5, top, crown_r * 1.12, crown_r, sides=11, center=(cx, cy))
        # Splintered rim on the OUTER half only: the standing surface and the
        # mere-facing approach both stay clear.
        for i in range(11):
            a = (i / 11) * TAU
            if math.cos(a - angle) < 0.15:
                continue
            x, y = cx + math.cos(a) * crown_r * 0.95, cy + math.sin(a) * crown_r * 0.95
            cone(
                bm,
                (x, y, top - 0.5),
                (x + rng.uniform(-0.3, 0.3), y + rng.uniform(-0.3, 0.3), top + rng.uniform(0.4, 1.2)),
                0.5,
                sides=4,
            )
        # The ramp: a flat buttress root on the mere-facing side, wide enough
        # to run up without aiming.
        ramp = angle + math.pi
        rise = (top - 0.7) - (ground - 0.3)
        run = 15.0
        length = math.hypot(run, rise)
        mid_r = crown_r * 0.85 + run / 2
        box(
            bm,
            (cx + math.cos(ramp) * mid_r, cy + math.sin(ramp) * mid_r, (top - 0.7 + ground - 0.3) / 2),
            (length, 5.4, 1.5),
            Matrix.Rotation(ramp, 3, "Z") @ Matrix.Rotation(math.atan2(rise, run), 3, "Y"),
        )
        # The rest: thin roots gripping the peat, low enough to run over.
        for i in range(5):
            a = ramp + 1.1 + (i / 5) * (TAU - 2.2)
            reach = rng.uniform(5.5, 8.5)
            taper_between(
                bm,
                (cx + math.cos(a) * crown_r * 0.9, cy + math.sin(a) * crown_r * 0.9, ground + 1.2),
                (cx + math.cos(a) * (crown_r + reach), cy + math.sin(a) * (crown_r + reach), ground - 0.7),
                0.7,
                0.24,
                sides=5,
            )
        objects.append(finish("GnashrootArena_Stump%d" % (index + 1), bm, STUMPWOOD))
    return objects


def build_gn_grove(rng):
    """The drowned cypress ring, built the fen's OWN way (the reference is
    island_gen.build_swamp_trees, and this is a straight port of it):

      - a curved three-segment trunk, each segment leaning further off true,
        standing on a flared foot;
      - 3-5 main limbs off the upper trunk, each one FORKING twice into a
        spreading skeleton, terminal tips collected as it goes;
      - the canopy sitting ON those tips - one fat lumpy mass over the
        crown's heart plus a puff at every other tip - so leaves grow out of
        branches instead of hovering over them;
      - moss and vines hung off the same tips.

    The one arena-specific rule: limb azimuths are biased OUTWARD from the
    arena centre, so crowns lean off the ring and the fight keeps its sky.

    Wood, canopy, moss and vines all come out of this one pass because every
    one of them is generated from the same branch tips.
    """
    wood = bmesh.new()
    leaves = bmesh.new()
    moss = bmesh.new()
    vines = bmesh.new()

    def dir_of(az, elev):
        c = math.cos(elev)
        return Vector((math.cos(az) * c, math.sin(az) * c, math.sin(elev)))

    def limb(base, direction, length, radius, depth, tips):
        """One branch segment, then fork. The segment's base is sunk back
        along its own axis so the joint is buried in the wood it grows from
        and can never gap (the fen's floating-branch fix)."""
        r_top = radius * (0.62 if depth > 0 else 0.22)
        sink = radius * 1.1 + 0.1
        tip = base + direction * length
        taper_between(wood, base - direction * sink, tip, radius, max(r_top, 0.05), sides=3)
        if depth == 0:
            tips.append(tip)
            return
        kids = 3 if rng.random() < 0.2 else 2
        for _ in range(kids):
            rand = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1)))
            perp = rand - direction * rand.dot(direction)
            if perp.length < 1e-3:
                continue
            perp.normalize()
            ang = rng.uniform(0.35, 0.7)
            child = (direction * math.cos(ang) + perp * math.sin(ang) + Vector((0, 0, 0.18))).normalized()
            limb(tip, child, length * rng.uniform(0.6, 0.78), r_top, depth - 1, tips)

    count = 40
    for index in range(count):
        angle = (index / count) * TAU + rng.uniform(-0.06, 0.06)
        # Two ranks: the inner one is the wall you see, the outer one gives it
        # depth so you cannot read straight out of the arena between trunks.
        radius = rng.uniform(67.0, 72.0) if index % 2 == 0 else rng.uniform(75.0, 80.0)
        x, y = math.cos(angle) * radius, math.sin(angle) * radius
        ground = _gn_height(radius)

        total_h = rng.uniform(20.0, 32.0)
        r0 = rng.uniform(1.6, 2.6)
        # The flared, buttressed foot of a tree that stands in water.
        tapered_cylinder(wood, ground - 4.0, ground + 2.0, r0 * 2.0, r0 * 1.15, sides=8, center=(x, y))
        bend = rng.uniform(0, TAU)
        leans = [rng.uniform(0.03, 0.09), rng.uniform(0.10, 0.22), rng.uniform(0.16, 0.3)]
        radii = [r0, r0 * 0.7, r0 * 0.48, r0 * 0.3]
        seg = total_h / 3
        pos = Vector((x, y, ground - 0.4))
        joints = [Vector(pos)]
        for step, lean in enumerate(leans):
            direction = dir_of(bend, math.pi * 0.5 - lean)
            taper_between(wood, pos, pos + direction * seg, radii[step], radii[step + 1], sides=5)
            pos = pos + direction * seg
            joints.append(Vector(pos))

        tips = []
        outward = math.atan2(y, x)
        for _ in range(rng.randint(3, 5)):
            # Walk the real joint polyline, not the chord: a curved trunk bows
            # away from its own chord and the limb bases hang off the wood.
            along = rng.uniform(0.55, 0.95) * 3.0
            joint = min(int(along), 2)
            at = joints[joint].lerp(joints[joint + 1], along - joint)
            limb(
                at,
                dir_of(outward + rng.uniform(-1.2, 1.2), rng.uniform(0.45, 0.95)),
                rng.uniform(5.5, 9.0) * (total_h / 22.0),
                r0 * 0.3,
                2,
                tips,
            )
        if not tips:
            continue

        centroid = Vector((0, 0, 0))
        for tip in tips:
            centroid += tip
        centroid /= len(tips)
        spread = max((max(abs(t.x - centroid.x), abs(t.y - centroid.y)) for t in tips), default=6.0)
        # Wide in XY, squashed in Z - the fen's horizontal leaf pads.
        big = max(9.0, min(14.0, spread * 1.35))
        add_blob(
            leaves,
            (centroid.x, centroid.y, centroid.z + 0.6),
            (big, big * rng.uniform(0.85, 1.0), big * 0.4),
            0.2,
            salt=index * 2.9,
            yaw=rng.uniform(0, TAU),
        )
        for k, tip in enumerate(tips):
            if k % 2 == 0:
                puff = rng.uniform(5.5, 8.0)
                add_blob(
                    leaves,
                    (tip.x, tip.y, tip.z + 0.4),
                    (puff, puff * rng.uniform(0.8, 1.0), puff * 0.42),
                    0.22,
                    salt=index * 7.1 + k,
                    yaw=rng.uniform(0, TAU),
                )
            # The hanging garden, off the same tips.
            if rng.random() < 0.5:
                length = rng.uniform(3.0, 7.0)
                taper_between(moss, (tip.x, tip.y, tip.z), (tip.x, tip.y, tip.z - length), 0.1, 0.04, sides=3)
            if rng.random() < 0.22:
                length = rng.uniform(7.0, 14.0)
                sway = rng.uniform(0, TAU)
                taper_between(
                    vines,
                    (tip.x, tip.y, tip.z),
                    (tip.x + math.cos(sway) * length * 0.1, tip.y + math.sin(sway) * length * 0.1, tip.z - length),
                    0.08,
                    0.05,
                    sides=3,
                )

    return (
        finish("GnashrootArena_Grove", wood, CYPRESS),
        finish("GnashrootArena_DecoCanopy", leaves, LEAF),
        finish("GnashrootArena_DecoMoss", moss, HANGMOSS),
        finish("GnashrootArena_DecoVines", vines, VINE),
    )


def build_gn_reeds(rng):
    stalks = bmesh.new()
    heads = bmesh.new()
    for _ in range(30):
        angle = rng.uniform(0, TAU)
        radius = rng.uniform(62.0, 71.0)
        cx, cy = math.cos(angle) * radius, math.sin(angle) * radius
        for _ in range(rng.randint(5, 9)):
            x, y = cx + rng.uniform(-2.8, 2.8), cy + rng.uniform(-2.8, 2.8)
            g = _gn_ground(x, y)
            h = rng.uniform(2.6, 5.0)
            tip_x, tip_y = x + rng.uniform(-0.6, 0.6), y + rng.uniform(-0.6, 0.6)
            cone(stalks, (x, y, g - 0.3), (tip_x, tip_y, g + h), 0.13, sides=4)
            if rng.random() < 0.5:
                tapered_cylinder(heads, g + h - 0.95, g + h + 0.25, 0.26, 0.2, sides=5, center=(tip_x, tip_y))
    # A brake standing in the mere's shallows too, where the water is thin.
    for _ in range(10):
        angle = rng.uniform(0, TAU)
        radius = rng.uniform(23.0, 27.5)
        cx, cy = math.cos(angle) * radius, math.sin(angle) * radius
        for _ in range(rng.randint(3, 6)):
            x, y = cx + rng.uniform(-2.0, 2.0), cy + rng.uniform(-2.0, 2.0)
            g = _gn_ground(x, y)
            cone(stalks, (x, y, g), (x, y, g + rng.uniform(3.0, 5.2)), 0.13, sides=4)
    return (
        finish("GnashrootArena_DecoReeds", stalks, REED),
        finish("GnashrootArena_DecoReedHeads", heads, REEDHEAD),
    )


def build_gn_lily(rng):
    bm = bmesh.new()
    # Pads ring the mere; the middle stays open water - it rises there.
    for _ in range(30):
        angle = rng.uniform(0, TAU)
        radius = rng.uniform(13.0, 26.0)
        x, y = math.cos(angle) * radius, math.sin(angle) * radius
        r = rng.uniform(1.0, 2.1)
        tapered_cylinder(bm, GN_MERE_Z + 0.04, GN_MERE_Z + 0.14, r, r, sides=6, center=(x, y))
    return finish("GnashrootArena_DecoLily", bm, LILYPAD)


def build_gn_wisps(rng):
    bm = bmesh.new()
    # The fen's own light, and the boss's: Morra's lantern green, drifting.
    for _ in range(14):
        angle = rng.uniform(0, TAU)
        radius = rng.uniform(30.0, 70.0)
        x, y = math.cos(angle) * radius, math.sin(angle) * radius
        size = rng.uniform(0.16, 0.26)
        rock(bm, (x, y, _gn_ground(x, y) + rng.uniform(1.2, 4.5)), (size,) * 3, rng, jitter=0.05)
    for _ in range(6):
        angle = rng.uniform(0, TAU)
        radius = rng.uniform(6.0, 24.0)
        rock(
            bm,
            (math.cos(angle) * radius, math.sin(angle) * radius, GN_MERE_Z + rng.uniform(0.7, 2.4)),
            (0.22,) * 3,
            rng,
            jitter=0.05,
        )
    return finish("GnashrootArena_DecoWisps", bm, WISP)


def build_gn_foam(rng):
    bm = bmesh.new()
    angles = 36
    inner, outer = [], []
    for i in range(angles):
        angle = (i / angles) * TAU
        r0 = 82.0 + rng.uniform(-1.2, 1.2)
        r1 = 87.5 + rng.uniform(-1.6, 1.6)
        inner.append(bm.verts.new((math.cos(angle) * r0, math.sin(angle) * r0, 0.28)))
        outer.append(bm.verts.new((math.cos(angle) * r1, math.sin(angle) * r1, 0.22)))
    for i in range(angles):
        j = (i + 1) % angles
        bm.faces.new((inner[i], outer[i], outer[j], inner[j]))
    bmesh.ops.solidify(bm, geom=list(bm.faces) + list(bm.verts) + list(bm.edges), thickness=0.25)
    return finish("GnashrootArena_Foam", bm, SCUM)


def build_gnashroot():
    rng = random.Random(6203)
    objects = [
        build_gn_base(rng),
        build_gn_mere(rng),
        build_gn_shallows(rng),
        *build_gn_stumps(rng),
        *build_gn_grove(rng),
        *build_gn_reeds(rng),
        build_gn_lily(rng),
        build_gn_wisps(rng),
        build_gn_foam(rng),
    ]
    print("HANDOFF gnashroot: mesh bottom z %.1f  <-- BossArenas meshBottom (default -9 fits)" % (SKIRT_BOTTOM - 0.5))
    print(
        "HANDOFF gnashroot: mere r %.1f, water z %.1f, bed z %.1f (waded, not swum) - it lies here and rises from it"
        % (GN_MERE_R, GN_MERE_Z, GN_PROFILE[0][1])
    )
    for index, (radius, degrees) in enumerate(GN_STUMPS):
        angle = math.radians(degrees)
        print(
            "HANDOFF gnashroot: Stump%d rel (%.1f, %.1f) top z %.1f - the fight's clean high ground"
            % (index + 1, math.cos(angle) * radius, math.sin(angle) * radius, _gn_height(radius) + 5.0)
        )
    print("HANDOFF gnashroot: walkable bank r 29-70 (z ~1.6), grove r %.0f-%.0f, foam ring r 82-87" % GN_GROVE_R)
    return objects


# ---------------------------------------------------------------- wrack
#
# ADMIRAL WRACK / the Careenage (wreck boss, design locked 2026-08-29):
#   - a shallow TIDAL SHOAL where the drowned fleet came to die: wet ribbed
#     sand, dished a little toward the middle, walkable out to r 78. The
#     MIDDLE IS KEPT CLEAN on purpose (the Tidebreak lesson, 5db0f95) - the
#     broadside walls, slam rings and chain sweeps all paint their telegraphs
#     on this canvas. The only things standing on the open sand are the six
#     named hulks; everything else out there is FLAT (the ripples are in the
#     landform itself, the tide puddles and the haul furrows have no height
#     to trip on).
#   - THE BOUNDARY IS THE GROUNDED FLEET, not a reef: fifteen half-sunk hulls
#     at r 80-88 tipped at every angle - on their beam ends, driven bow-up
#     onto the shoal, picked to the ribs - with snapped masts leaning inward
#     over the sand, spars crossing, rotted canvas still bent to the yards. A
#     palisade of dead ships. It opens in ONE place: a 48-degree gap at the
#     head of the shoal, which is the whole geography of the fight.
#   - THE CAREENING CRADLE stands in that gap (bearing WK_HEAD_DEG): the
#     timber frames a ship was hove down on, arching over the sand like a
#     ruined nave, two of the six collapsed into it. This is where Wrack was
#     hauled out, and where he starts.
#   - GROUNDING FURROWS ploughed from the cradle to the centre - three grooves
#     and their thrown-up berms, carved into _Base ITSELF so they catch light
#     the way a gouge does, and only 0.45 studs deep so they are read and
#     never climbed. They are his advance lane: he hauls himself down them on
#     his own anchor chains once a phase.
#   - THE SIX BREAKWATER HULKS (<Model>_Hulk1..6) at r 33-52, spread around
#     the circle and deliberately CLEAR of the haul lane: chunks of wreck
#     standing in the open sand, each tall and solid enough to break the line
#     of sight from a broadside. Separate objects so the fight logic can find
#     and progressively shatter each, and no two are the same shape - beam
#     ends, capsized stern, strake stack, reared bow, standing midships,
#     keel-up ribcage. Positions in the HANDOFF.
#   - dressing at the EDGES only: half-buried admiralty anchors and mooring
#     chain runs, barrels and crates spilled at the rim, tide wrack along the
#     high-water line, and the island's own ghost-fire in the wreck sockets.
#   - surf ring outside (named *_Foam: OceanController rides it on the tide
#     for free), underwater skirt flaring to r 99.
#
# The BOSS MESH IS NOT BUILT HERE. Wrack is a beached man-of-war with an
# admiral fused into her prow; he and the fight logic are separate later
# passes. This builds the ground he fights on and the fiction around it.
#
# Palette and carpentry both come straight off Wreckwater (island_gen.py's
# wreck COLORS and its `_wr_` ship helpers), so the island's graveyard and the
# arena read as timber cut in one yard. Every name here is WK_/`_wr_`-scoped
# and every material datablock is named by `finish` after its own object
# (WrackArena_*), so nothing this arena creates can be reused by another one.


# ------------------------------------------------- wrack: ship carpentry
#
# A wreck is not made of boulders and cones. Ship-local is +x toward the bow,
# +y to port, +z up; one 4x4 from `_wr_frame` maps it into the world, which is
# what lets a hull lie on her beam ends or rear her bow at a real angle
# without any of the shapes below knowing about it. Pass _WK_WORLD as the
# frame to work directly in world space.

_WK_WORLD = Matrix.Identity(4)


def _wr_finish(name, bm, color, material):
    """`finish`, but the material datablock is named separately from the object.

    `make_material` caches datablocks BY NAME, so two arenas that both ask for
    a material called "Sand" silently repaint each other and build order picks
    the winner. Every material this arena creates is therefore `M_Wrack_*`:
    arena-scoped, matching the island packs' own M_ convention, and shareable
    between objects that genuinely are the same timber (the fleet's planking
    and the odd-numbered hulks, say) without ever reaching another arena."""
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(make_material(material, color))
    for poly in mesh.polygons:
        poly.use_smooth = False
    return obj


def _wr_frame(pos, yaw=0.0, pitch=0.0, roll=0.0):
    """Ship-local -> world. `pitch` is bow-UP radians, `roll` a heel to port."""
    return (
        Matrix.Translation(Vector(pos))
        @ Matrix.Rotation(yaw, 4, "Z")
        @ Matrix.Rotation(-pitch, 4, "Y")
        @ Matrix.Rotation(roll, 4, "X")
    )


def _wr_beam(bm, frame, p0, p1, width, thick, twist=0.0):
    """A squared timber spanning frame-local p0 -> p1: ribs, wales, deck beams,
    cradle legs, strakes, chain links. The workhorse of a shipbreaker's yard."""
    a, b = Vector(p0), Vector(p1)
    axis = b - a
    if axis.length < 1e-6:
        return
    rot = Vector((1.0, 0.0, 0.0)).rotation_difference(axis.normalized()).to_matrix().to_4x4()
    bmesh.ops.create_cube(
        bm,
        size=1.0,
        matrix=(
            frame
            @ Matrix.Translation((a + b) / 2)
            @ rot
            @ Matrix.Rotation(twist, 4, "X")
            @ Matrix.Diagonal(Vector((axis.length, width, thick, 1.0)))
        ),
    )


def _wr_spar(bm, frame, p0, p1, r0, r1, sides=6):
    """A tapered round timber in a frame - masts, topmasts, yards, pilings."""
    a, b = Vector(p0), Vector(p1)
    axis = b - a
    if axis.length < 1e-6:
        return
    rot = Vector((0.0, 0.0, 1.0)).rotation_difference(axis.normalized()).to_matrix().to_4x4()
    bmesh.ops.create_cone(
        bm,
        cap_ends=True,
        segments=sides,
        radius1=r0,
        radius2=r1,
        depth=axis.length,
        matrix=frame @ Matrix.Translation((a + b) / 2) @ rot,
    )


def _wr_panel(bm, frame, corners, thick=0.25):
    """A flat quad with a little thickness - one width of rotted canvas.
    Corners are frame-local, given in order around the panel."""
    pts = [Vector(corner) for corner in corners]
    normal = (pts[1] - pts[0]).cross(pts[3] - pts[0])
    if normal.length < 1e-6:
        return
    normal = normal.normalized() * (thick / 2)
    top = [bm.verts.new(pt + normal) for pt in pts]
    low = [bm.verts.new(pt - normal) for pt in pts]
    made = [bm.faces.new(top), bm.faces.new(list(reversed(low)))]
    for i in range(4):
        j = (i + 1) % 4
        made.append(bm.faces.new((top[i], low[i], low[j], top[j])))
    bmesh.ops.recalc_face_normals(bm, faces=made)
    bmesh.ops.transform(bm, matrix=frame, verts=top + low)


def _wr_stations(length, width, depth, freeboard, count=9, bow_rise=1.0, fullness=1.0):
    """Cross-sections down a BROKEN hull section: x=0 is the ragged tear where
    the ship came apart, x=length the bow point. Returns
    (x, half_beam, keel_z, sheer_z) - an elliptical waterplane, a keel sweeping
    up into the forefoot, a sheer line lifting toward the bow."""
    out = []
    for i in range(count):
        t = i / (count - 1)
        half = (width / 2) * math.sqrt(max(0.015, 1.0 - t**2.4)) * (0.72 + 0.28 * fullness)
        keel = -depth + depth * 0.78 * t**2.4
        sheer = freeboard + freeboard * bow_rise * t**1.9
        out.append((t * length, half, keel, sheer))
    return out


def _wr_shell(bm, frame, stations, cap_break=True):
    """Loft `_wr_stations` into a closed low-poly hull solid: eight-point rings
    (port sheer, turn of the bilge, keel, starboard, back over the deck)
    stitched span by span. Solid, so it reads from any angle it is tipped to."""

    def ring(station):
        x, half, keel, sheer = station
        rise = sheer - keel
        return [
            Vector((x, half, sheer)),
            Vector((x, half * 0.94, keel + rise * 0.36)),
            Vector((x, half * 0.56, keel + rise * 0.07)),
            Vector((x, 0.0, keel)),
            Vector((x, -half * 0.56, keel + rise * 0.07)),
            Vector((x, -half * 0.94, keel + rise * 0.36)),
            Vector((x, -half, sheer)),
            Vector((x, 0.0, sheer + rise * 0.05)),  # crowned deck centreline
        ]

    loops = [[bm.verts.new(point) for point in ring(station)] for station in stations]
    made = []
    for a, b in zip(loops, loops[1:]):
        for k in range(8):
            j = (k + 1) % 8
            try:
                made.append(bm.faces.new((a[k], a[j], b[j], b[k])))
            except ValueError:
                pass
    for loop, wanted in ((loops[0], cap_break), (list(reversed(loops[-1])), True)):
        if not wanted:
            continue
        try:
            made.append(bm.faces.new(loop))
        except ValueError:
            pass
    bmesh.ops.recalc_face_normals(bm, faces=made)
    bmesh.ops.transform(bm, matrix=frame, verts=[vert for loop in loops for vert in loop])


def _wr_ribs(bm, frame, stations, span, rise, thick=0.6):
    """The exposed ribcage: frames arcing up and inward off the sheer where the
    planking has rotted away. `span` is the (lo, hi) fraction of the hull they
    cover, `rise` how far above the sheer they reach."""
    lo, hi = span
    count = len(stations)
    for i, (x, half, _keel, sheer) in enumerate(stations):
        t = i / (count - 1)
        if t < lo or t > hi:
            continue
        reach = rise * (0.55 + 0.45 * math.sin(math.pi * (t - lo) / max(1e-3, hi - lo)))
        for side in (1, -1):
            prev = Vector((x, side * half, sheer - 0.3))
            for k in range(1, 4):
                f = k / 3
                nxt = Vector((x, side * half * (1.0 - 0.30 * f * f), sheer + reach * f))
                _wr_beam(bm, frame, prev, nxt, thick, thick * 0.85)
                prev = nxt


def _wr_wales(bm, frame, stations, fractions=(0.30, 0.62), limit=0.92, width=0.8):
    """The heavy longitudinal strakes that keep a bare hull side from reading
    as one blank slab of geometry."""
    count = len(stations)
    for fraction in fractions:
        for side in (1, -1):
            prev = None
            for i, (x, half, keel, sheer) in enumerate(stations):
                if i / (count - 1) > limit:
                    break
                point = Vector((x, side * half * 1.02, keel + (sheer - keel) * fraction))
                if prev is not None:
                    _wr_beam(bm, frame, prev, point, width, width * 0.86)
                prev = point


def _wr_tear(bm, frame, station, rng, count=7, spread=0.9):
    """The jagged edge where a ship snapped in half - splinters standing proud
    of the break. This is what stops a hull section reading as a cut cylinder."""
    x, half, _keel, sheer = station
    for k in range(count):
        f = -spread + 2 * spread * (k / max(count - 1, 1))
        _wr_beam(
            bm,
            frame,
            (x + 0.2, f * half, sheer - 0.4),
            (x - rng.uniform(0.5, 2.5), f * half * 0.97, sheer + rng.uniform(1.4, 5.2)),
            1.1,
            0.8,
        )


def _wr_chain(bm, p0, p1, links, size, sag=0.0):
    """A mooring chain run between two WORLD points: flattened links turned
    ninety degrees each from the last, which is all a chain needs to read."""
    a, b = Vector(p0), Vector(p1)
    for i in range(links):
        t0, t1 = i / links, (i + 1) / links
        c0 = a.lerp(b, t0) - Vector((0, 0, sag * math.sin(math.pi * t0)))
        c1 = a.lerp(b, t1) - Vector((0, 0, sag * math.sin(math.pi * t1)))
        _wr_beam(bm, _WK_WORLD, c0, c1, size * 1.7, size * 0.55, twist=i * math.pi / 2)


# ------------------------------------------------- wrack: the shoal itself

# Radial profile of the shoal: (radius, height). A shallow DISH - the flat
# sags toward the middle, which is where the tide leaves its water. Walkable
# sand to WK_SAND_R, then the awash flat the fleet lies in, then the skirt.
WK_PROFILE = [
    (0.0, 1.05),
    (10.0, 0.90),
    (26.0, 1.05),
    (44.0, 1.30),
    (60.0, 1.45),
    (72.0, 1.20),
    (78.0, 0.70),  # walkable sand ends
    (84.0, 0.05),  # the awash flat the grounded fleet lies in
    (90.0, -2.30),
    (95.0, -5.60),
    (99.0, SKIRT_BOTTOM),
]

WK_HEAD_DEG = 150.0  # the head of the shoal: cradle bearing, and the ring's gap
WK_CRADLE_R = 64.0  # the cradle's centre, standing on the walkable sand
WK_SAND_R = 78.0
WK_FLEET_R = (80.0, 88.0)
WK_FOAM_R = (90.0, 94.5)
WK_FLEET_GAP_DEG = 58.0  # the mouth at the head of the shoal
WK_LANE_HALF = 14.0  # the haul lane's clear half-width - no hulk inside it
WK_FURROW_OFFSETS = (-7.5, 0.0, 7.5)  # the three grooves, keel and bilge

# The fight furniture. Spread round the circle, r 33-52, and every one of them
# clear of the haul lane by more than WK_LANE_HALF - the two big gaps in the
# ring (150 deg and 330 deg) are where he comes in and where he is going.
WK_HULKS = [(34.0, 15.0), (52.0, 62.0), (38.0, 100.0), (49.0, 198.0), (33.0, 250.0), (46.0, 292.0)]

# (radius, degrees, spread) - the broad flat puddles the ebb leaves behind.
WK_PUDDLES = [(31.0, 58.0, 12.0), (53.0, 272.0, 15.0), (24.0, 195.0, 9.0)]

# Straight off Wreckwater's own palette (island_gen.py wreck COLORS), pulled
# wetter and greyer: this is a tidal flat at low water, not the island's dry
# bone-white sand. WK_-scoped so it cannot rebind another arena's constants.
WK_SAND = (0.445, 0.429, 0.384)  # wet grey-brown shoal sand, low water
WK_SPOIL = (0.522, 0.498, 0.438)  # sand thrown out of the furrows, drying a shade pale
WK_WET = (0.352, 0.352, 0.325)  # the drowned apron: everything below low water
WK_TIDEWATER = (0.180, 0.265, 0.278)  # M_BayWater lifted - standing water with sky in it
WK_HULL = (0.112, 0.092, 0.076)  # M_HullWood, driven darker - the boundary is near-black
WK_STRAKE = (0.205, 0.172, 0.136)  # the boundary's frames: a shade up off the planking
# The six hulks are lit deliberately PALER than the palisade behind them. A
# player under pressure has to read "cover" without stopping to look (the
# Rootmere stump lesson), and value is the only channel a brown arena has.
WK_HULKWOOD = (0.318, 0.266, 0.205)
WK_HULKPALE = (0.412, 0.354, 0.272)
WK_SPARWOOD = (0.329, 0.271, 0.204)  # M_WreckPost - masts and yards
WK_CRADLEWOOD = (0.452, 0.386, 0.296)  # limed yard timber: the cradle reads PALE against the fleet
WK_PLANK = (0.475, 0.404, 0.310)  # M_WreckPlank - barrels, crates, cradle decking
WK_CANVAS = (0.652, 0.658, 0.618)  # M_WreckSail - rotted canvas, bone with a green cast
WK_IRON = (0.300, 0.400, 0.352)  # verdigris: anchors, chain, capstan bands
WK_WEED = (0.255, 0.300, 0.212)  # the tide wrack along the high-water line
WK_GHOST = (0.560, 0.949, 0.800)  # M_GhostGlow pulled teal - the ghost fleet's own light
WK_FOAM = (0.800, 0.824, 0.812)  # M_WreckFoam, pulled off pure white


def _wk_profile(r):
    for (r0, h0), (r1, h1) in zip(WK_PROFILE, WK_PROFILE[1:]):
        if r <= r1:
            t = 0 if r1 == r0 else (r - r0) / (r1 - r0)
            return h0 + (h1 - h0) * t
    return WK_PROFILE[-1][1]


def _wk_lane(x, y):
    """(along, across) in the haul lane's own frame: `along` counts studs from
    the arena centre out toward the cradle, `across` is the offset sideways."""
    a = math.radians(WK_HEAD_DEG)
    return x * math.cos(a) + y * math.sin(a), -x * math.sin(a) + y * math.cos(a)


def _wk_furrow(x, y):
    """How far the ploughed gouges sink the sand at (x, y), or how high the
    spoil berm stands beside them. Shallow ON PURPOSE - a furrow here is read,
    never climbed, so nothing running the lane can catch a foot on it."""
    along, across = _wk_lane(x, y)
    if along < 2.0 or along > WK_CRADLE_R + 8.0:
        return 0.0
    # Deepest under the cradle, where he was dragged off the blocks; the bite
    # fades out as the hauls near the middle and the sand closes over them.
    bite = min(1.0, (along - 2.0) / 16.0) * min(1.0, (WK_CRADLE_R + 8.0 - along) / 6.0)
    gouge, berm = 0.0, 0.0
    for offset in WK_FURROW_OFFSETS:
        d = abs(across - offset)
        if d < 3.2:
            gouge = min(gouge, -0.80 * bite * math.cos(d / 3.2 * (math.pi / 2)))
        elif d < 5.4:
            berm = max(berm, 0.55 * bite * math.sin((d - 3.2) / 2.2 * math.pi))
    return gouge if gouge < 0.0 else berm


def _wk_puddle_at(x, y):
    """(ripple damping, dish) for the tide flats: inside a puddle the ribbing
    dies out and the sand dishes a little, which is what lets the water sheet
    lie genuinely flat instead of draping over ripple crests."""
    damp, dish = 1.0, 0.0
    for radius, degrees, spread in WK_PUDDLES:
        a = math.radians(degrees)
        d = math.hypot(x - math.cos(a) * radius, y - math.sin(a) * radius)
        if d < spread:
            fall = 1.0 - (d / spread) ** 2
            damp = min(damp, 1.0 - fall)
            dish = min(dish, -0.20 * fall)
    return damp, dish


def _wk_ground(x, y):
    """The shoal's surface. Pure and deterministic - no rng anywhere in it -
    so every prop that seats itself with this lands exactly on the sand."""
    r = math.hypot(x, y)
    z = _wk_profile(r)
    if r < 80.0:
        damp, dish = _wk_puddle_at(x, y)
        # Wet ribbed sand: low tidal ripples, near-concentric but dragged out
        # of true by the run of the ebb across the flat.
        a = math.atan2(y, x)
        ripple = math.sin(r * 0.52 + math.sin(a * 2.0) * 1.1 + math.sin(a * 3.0 + 0.7) * 0.8) * 0.30
        z += ripple * damp * min(1.0, r / 8.0) + dish + _wk_furrow(x, y)
    return z


def build_wk_base(rng):
    bm = bmesh.new()
    angles = 48
    # Sampled every 2.5 studs across the walkable flat: coarse enough to stay
    # low-poly, fine enough that the ripples and the haul furrows are real
    # geometry in the landform rather than a texture that isn't there.
    rings = [step * 2.5 for step in range(1, 31)] + [WK_SAND_R, 84.0, 90.0, 95.0, 99.0]
    grid = []
    for radius in rings:
        ring = []
        for i in range(angles):
            angle = (i / angles) * TAU
            # The silhouette wobbles only OUTSIDE the walkable sand, so the
            # flat the fight is fought on matches _wk_ground exactly.
            r = radius * (1.0 + (rng.uniform(-0.035, 0.035) if radius >= 80.0 else 0.0))
            x, y = math.cos(angle) * r, math.sin(angle) * r
            ring.append(bm.verts.new((x, y, _wk_ground(x, y))))
        grid.append(ring)
    centre = bm.verts.new((0, 0, _wk_ground(0, 0)))
    for i in range(angles):
        bm.faces.new((centre, grid[0][i], grid[0][(i + 1) % angles]))
    for a, b in zip(grid, grid[1:]):
        for i in range(angles):
            j = (i + 1) % angles
            bm.faces.new((a[i], b[i], b[j], a[j]))
    # Close the underside so the skirt reads solid from below.
    bottom = bm.verts.new((0, 0, SKIRT_BOTTOM - 0.5))
    outer = grid[-1]
    for i in range(angles):
        bm.faces.new((bottom, outer[(i + 1) % angles], outer[i]))
    return _wr_finish("WrackArena_Base", bm, WK_SAND, "M_Wrack_Sand")


def build_wk_shallows(rng):
    """The drowned apron: the wet skin over everything below low water, from
    the top of the beach out across the flat the fleet lies in and on down the
    skirt. Built in FOUR rings that follow the profile - a single band from
    r 76 straight to r 96 chords across a landform that is diving steeply by
    then, sinks under it, and leaves the arena sitting on a bright plate of
    dry-looking sand (which is exactly what the first render did)."""
    bm = bmesh.new()
    angles = 40
    # Out past the landform's own rim (r 99): anything short of that leaves a
    # collar of bright dry-looking sand round the arena, which is what the
    # first two renders showed. Narrow bands and a small jitter, so the base
    # can never poke back through between them.
    steps = (75.5, 82.0, 88.0, 93.0, 97.0, 99.6)
    grid = []
    for radius in steps:
        ring = []
        for i in range(angles):
            angle = (i / angles) * TAU
            r = radius + rng.uniform(-1.0, 1.0)
            x, y = math.cos(angle) * r, math.sin(angle) * r
            # The inner edge hugs the ribbed sand as a wet tide-edge line; from
            # r 82 out the profile alone carries it down the drowned skirt.
            z = _wk_ground(x, y) + 0.10 if radius < 80.0 else _wk_profile(r) + 0.27
            ring.append(bm.verts.new((x, y, z)))
        grid.append(ring)
    for a, b in zip(grid, grid[1:]):
        for i in range(angles):
            j = (i + 1) % angles
            bm.faces.new((a[i], b[i], b[j], a[j]))
    bmesh.ops.solidify(bm, geom=list(bm.faces) + list(bm.verts) + list(bm.edges), thickness=0.2)
    return _wr_finish("WrackArena_DecoShallows", bm, WK_WET, "M_Wrack_Wet")


def build_wk_tidewater():
    """Standing water: the broad tide puddles on the flat, and the water lying
    in the haul furrows. FLAT, and Deco - the only thing the design lets into
    the middle of the arena, because it has no height for a telegraph to fight
    with and nothing for a running player to catch."""
    bm = bmesh.new()
    for radius, degrees, spread in WK_PUDDLES:
        a = math.radians(degrees)
        cx, cy = math.cos(a) * radius, math.sin(a) * radius
        sides = 13
        ring = []
        for i in range(sides):
            t = (i / sides) * TAU
            # A smooth, non-circular edge, different for every puddle: an ebb
            # puddle is a lobed shape, never a disc.
            edge = spread * (0.84 + 0.14 * math.sin(t * 3.0 + math.radians(degrees)))
            x, y = cx + math.cos(t) * edge, cy + math.sin(t) * edge
            ring.append(bm.verts.new((x, y, _wk_ground(x, y) + 0.06)))
        bm.faces.new(ring)
    head = math.radians(WK_HEAD_DEG)
    out = Vector((math.cos(head), math.sin(head), 0.0))
    across = Vector((-math.sin(head), math.cos(head), 0.0))
    for offset in WK_FURROW_OFFSETS:
        steps = 18
        left, right = [], []
        for i in range(steps + 1):
            along = 6.0 + (WK_CRADLE_R + 2.0 - 6.0) * (i / steps)
            for side, store in ((-1.0, left), (1.0, right)):
                point = out * along + across * (offset + side * 3.0)
                store.append(bm.verts.new((point.x, point.y, _wk_ground(point.x, point.y) + 0.05)))
        for i in range(steps):
            bm.faces.new((left[i], right[i], right[i + 1], left[i + 1]))
    return _wr_finish("WrackArena_DecoTidewater", bm, WK_TIDEWATER, "M_Wrack_Tidewater")


def build_wk_spoil(rng):
    """Sand ploughed out of the furrows and left in low ridges beside them -
    what makes the gouges read as ploughed rather than moulded. Nothing here
    stands over 0.7 studs, and it is all Deco."""
    bm = bmesh.new()
    head = math.radians(WK_HEAD_DEG)
    out = Vector((math.cos(head), math.sin(head), 0.0))
    across = Vector((-math.sin(head), math.cos(head), 0.0))
    for offset in (WK_FURROW_OFFSETS[0] - 4.4, WK_FURROW_OFFSETS[-1] + 4.4):
        along = 8.0
        while along < WK_CRADLE_R + 4.0:
            size = rng.uniform(1.1, 2.4)
            point = out * along + across * (offset + rng.uniform(-1.3, 1.3))
            rock(
                bm,
                (point.x, point.y, _wk_ground(point.x, point.y) + size * 0.12),
                (size * 1.7, size, size * 0.24),
                rng,
                jitter=0.22,
            )
            along += rng.uniform(3.4, 6.0)
    # A last heap at the very foot of the cradle, where the keel bit deepest.
    for _ in range(7):
        point = out * rng.uniform(WK_CRADLE_R - 4.0, WK_CRADLE_R + 6.0) + across * rng.uniform(-11.0, 11.0)
        size = rng.uniform(1.4, 2.8)
        rock(bm, (point.x, point.y, _wk_ground(point.x, point.y) + size * 0.10), (size * 1.5, size, size * 0.28), rng, jitter=0.24)
    return _wr_finish("WrackArena_DecoSpoil", bm, WK_SPOIL, "M_Wrack_Spoil")


# ------------------------------------------------- wrack: the grounded fleet


def _wk_fleet(rng):
    """The grounded fleet, generated once and shared by every builder that
    hangs something off it, so hull, ribs, masts, canvas and sea-fire all
    agree with the ship they belong to (the Rootmere's `_gn_trees` pattern).

    The ring OPENS at the head of the shoal: that gap is the cradle's, and the
    fight's - it is the only bearing a player can read out of the arena, and
    it is exactly where Wrack comes from."""
    ships = []
    count = 15
    gap = math.radians(WK_FLEET_GAP_DEG)
    head = math.radians(WK_HEAD_DEG)
    for i in range(count):
        angle = head + gap / 2 + ((i + 0.5) / count) * (TAU - gap) + rng.uniform(-0.05, 0.05)
        radius = rng.uniform(*WK_FLEET_R)
        # Three ships in fifteen were driven bow-first at the shoal and reared:
        # they lean IN over the sand and give the palisade its overhang. Short
        # on purpose so the bow tip stops at r ~62, well outside the hulks.
        driven = i % 5 == 4
        if driven:
            length, width, depth = rng.uniform(25.0, 31.0), rng.uniform(10.0, 12.5), rng.uniform(4.2, 5.4)
            yaw = angle + math.pi + rng.uniform(-0.22, 0.22)
            pitch = rng.uniform(0.46, 0.66)
            roll = rng.uniform(-0.34, 0.34)
            lift = rng.uniform(1.0, 2.2)
        else:
            length, width, depth = rng.uniform(31.0, 46.0), rng.uniform(10.5, 15.0), rng.uniform(4.6, 6.4)
            yaw = angle + math.pi / 2 + rng.uniform(-0.40, 0.40)
            pitch = rng.uniform(-0.16, 0.16)
            # Heeled hard, and about half of them right over on their beam ends.
            roll = rng.uniform(0.55, 1.55) * (1.0 if i % 2 == 0 else -1.0)
            lift = rng.uniform(1.7, 3.2)
        x, y = math.cos(angle) * radius, math.sin(angle) * radius
        ships.append(
            {
                "frame": _wr_frame((x, y, _wk_profile(radius) + lift), yaw=yaw, pitch=pitch, roll=roll),
                "at": Vector((x, y, _wk_profile(radius) + lift)),
                "in": Vector((-math.cos(angle), -math.sin(angle), 0.0)),  # toward the fight
                "kind": ("shell", "ribs", "stern")[i % 3],
                "driven": driven,
                "ghost": i % 3 == 0,
                "stations": _wr_stations(
                    length,
                    width,
                    depth,
                    freeboard=width * (0.44 if not driven else 0.40),
                    count=9,
                    bow_rise=1.25 if driven else 0.35,
                    fullness=1.0 if driven else 1.2,
                ),
                "length": length,
                "width": width,
                "masts": 2 if i % 4 == 0 else 1,
                "sail": rng.random() < 0.42,
            }
        )
    return ships


def build_wk_fleet(ships, rng):
    """The boundary's hull PLANKING: shells, wales, deck beams, stern castles.
    Dark rotten timber - the mass of the palisade."""
    bm = bmesh.new()
    for ship in ships:
        frame, st = ship["frame"], ship["stations"]
        if ship["kind"] != "ribs":
            _wr_shell(bm, frame, st)
            _wr_wales(bm, frame, st)
            # Deck beams still spanning the open break.
            for f in (0.10, 0.24, 0.38):
                x, half, _keel, sheer = st[int(f * (len(st) - 1))]
                _wr_beam(bm, frame, (x, half * 0.95, sheer - 0.2), (x, -half * 0.95, sheer - 0.2), 1.0, 0.55)
        else:
            # Picked clean: keel and keelson only, the frames come with the ribs.
            _wr_beam(bm, frame, (st[0][0], 0, st[0][2]), (st[-1][0], 0, st[-1][2]), ship["width"] * 0.22, 1.4)
        if ship["kind"] == "stern":
            # A squat stern castle standing over the rotted-open waist.
            x0, half0, _keel0, sheer0 = st[0]
            house_l = ship["length"] * 0.24
            house_h = ship["width"] * 0.50
            for side in (1, -1):
                _wr_beam(bm, frame, (x0 + 0.4, side * half0 * 0.92, sheer0 + house_h / 2), (x0 + house_l, side * half0 * 0.86, sheer0 + house_h / 2), 1.0, house_h)
            _wr_beam(bm, frame, (x0 + 0.4, half0 * 0.92, sheer0 + house_h / 2), (x0 + 0.4, -half0 * 0.92, sheer0 + house_h / 2), 1.0, house_h)
            _wr_beam(bm, frame, (x0 + 0.4, 0, sheer0 + house_h), (x0 + house_l, 0, sheer0 + house_h * 0.86), half0 * 1.8, 0.9)
        if ship["driven"]:
            # A bowsprit off the stem and the little striker under it - the
            # detail that makes a reared bow read as a bow and not a wedge.
            x, _half, _keel, sheer = st[-1]
            _wr_spar(bm, frame, (x * 0.98, 0.0, sheer - 0.4), (x * 1.30, 0.0, sheer + ship["length"] * 0.10), 0.75, 0.28)
            _wr_beam(bm, frame, (x * 1.12, 0, sheer - 0.2), (x * 1.14, 0, sheer - 3.0), 0.5, 0.5)
    return _wr_finish("WrackArena_Fleet", bm, WK_HULL, "M_Wrack_Hull")


def build_wk_fleet_ribs(ships, rng):
    """The boundary's BONES: frames arcing off every sheer, and the splintered
    tears where each ship came apart. Bleached a shade paler than the planking,
    which is what stops the palisade reading as one dark mass."""
    bm = bmesh.new()
    for ship in ships:
        frame, st = ship["frame"], ship["stations"]
        if ship["kind"] == "ribs":
            _wr_ribs(bm, frame, st, (0.05, 0.95), rise=ship["width"] * 0.75, thick=1.05)
            _wr_wales(bm, frame, st, fractions=(0.98,), limit=1.0, width=1.1)
            # Stempost rearing at the bow end of a hull picked to nothing.
            x, _half, keel, sheer = st[-1]
            _wr_beam(bm, frame, (x - 1.0, 0, keel), (x + ship["length"] * 0.10, 0, sheer + ship["width"] * 0.70), 1.1, 1.1)
        else:
            span = (0.0, 0.45) if ship["driven"] else (0.30, 0.85)
            _wr_ribs(bm, frame, st, span, rise=ship["width"] * 0.52, thick=0.7)
        _wr_tear(bm, frame, st[0], rng)
    return _wr_finish("WrackArena_FleetRibs", bm, WK_STRAKE, "M_Wrack_Strake")


def build_wk_fleet_masts(ships, rng):
    """Snapped masts leaning INWARD over the sand, their yards crossing between
    neighbours. Built in world space and aimed at the fight on purpose: however
    a hull is rolled, her masts still lean over the arena.

    Everything hangs high - at the sand's edge the lowest spar is a good eight
    studs up - so the palisade frames the fight without fouling it."""
    bm = bmesh.new()
    for ship in ships:
        frame = ship["frame"]
        for m in range(ship["masts"]):
            # Stepped inside the hull, so the foot is always buried in timber.
            foot = frame @ Vector((ship["length"] * (0.32 + 0.30 * m), 0.0, ship["stations"][3][2] + 0.5))
            height = rng.uniform(23.0, 38.0) * (0.8 if m else 1.0)
            lean = rng.uniform(0.30, 0.62)
            heading = ship["in"].to_2d().to_3d().normalized()
            axis = (heading * math.sin(lean) + Vector((0, 0, math.cos(lean)))).normalized()
            head = foot + axis * height
            _wr_spar(bm, _WK_WORLD, foot, head, height * 0.055, height * 0.026, sides=6)
            # The yard, crossed near the head.
            perp = axis.cross(Vector((0, 0, 1)))
            perp = perp.normalized() if perp.length > 1e-4 else Vector((0, 1, 0))
            yard_at = foot + axis * (height * rng.uniform(0.58, 0.78))
            half = height * rng.uniform(0.17, 0.25)
            _wr_beam(bm, _WK_WORLD, yard_at + perp * half - Vector((0, 0, half * 0.12)), yard_at - perp * half + Vector((0, 0, half * 0.09)), height * 0.030, height * 0.030)
            # The topmast snapped at the head and hanging over from the break.
            broke = head - axis * (height * 0.03)
            _wr_spar(bm, _WK_WORLD, broke, broke + Vector((axis.x, axis.y, 0)).normalized() * height * 0.28 - Vector((0, 0, height * 0.15)), 0.4, 0.18, sides=4)
            ship.setdefault("yards", []).append((yard_at, perp, half, axis))
    return _wr_finish("WrackArena_FleetMasts", bm, WK_SPARWOOD, "M_Wrack_Spar")


def build_wk_sails(ships, rng):
    """Canvas still bent to the yards: contiguous widths with a ragged hem and
    one torn clean away, so it reads as one rotted sail and not a row of chips.
    Named Deco *and* SailRag - twice-marked visual-only, because a hanging
    sheet must never catch a cast."""
    bm = bmesh.new()
    for ship in ships:
        if not ship["sail"]:
            continue
        for yard_at, perp, half, axis in ship.get("yards", [])[:1]:
            belly = perp.cross(axis)
            belly = (belly.normalized() if belly.length > 1e-5 else Vector((0, 1, 0))) * (half * 0.28)
            drop = half * rng.uniform(1.0, 1.5)
            panels = 6
            hem = [drop * rng.uniform(0.55, 1.35) for _ in range(panels + 1)]
            gone = rng.randrange(panels)
            y0, y1 = yard_at + perp * half, yard_at - perp * half
            for k in range(panels):
                if k == gone:
                    continue
                a, b = y0.lerp(y1, k / panels), y0.lerp(y1, (k + 1) / panels)
                f0, f1 = (k + 0.5) / panels, (k + 1.5) / panels
                _wr_panel(
                    bm,
                    _WK_WORLD,
                    (
                        a,
                        b,
                        b + belly * (1 - abs(2 * f1 - 1)) - Vector((0, 0, hem[k + 1])),
                        a + belly * (1 - abs(2 * f0 - 1)) - Vector((0, 0, hem[k])),
                    ),
                    0.28,
                )
    return _wr_finish("WrackArena_DecoSailRag", bm, WK_CANVAS, "M_Wrack_Canvas")


# ------------------------------------------------- wrack: the careening cradle


def build_wk_cradle(rng):
    """The head of the shoal: the collapsed careening cradle Wrack was hauled
    out on. Six heavy timber frames arching over the sand at the mouth of the
    fleet ring - four still standing, two down - with the slipway rails and the
    keel blocks still bedded under them. A ruined nave, and his starting mark."""
    bm = bmesh.new()
    head = math.radians(WK_HEAD_DEG)
    out = Vector((math.cos(head), math.sin(head), 0.0))
    across = Vector((-math.sin(head), math.cos(head), 0.0))

    def seat(point, lift=0.0):
        return Vector((point.x, point.y, _wk_ground(point.x, point.y) + lift))

    # The slipway: two heavy ground rails running down the lane, bedded in the
    # sand the ship was dragged over, and the keel blocks between them.
    for side in (-1.0, 1.0):
        along = WK_CRADLE_R + 16.0
        while along > 38.0:
            nxt = along - 6.0
            _wr_beam(bm, _WK_WORLD, seat(out * along + across * (side * 8.6), 0.30), seat(out * nxt + across * (side * 8.6), 0.30), 2.6, 1.1)
            along = nxt
    along = 42.0
    while along < WK_CRADLE_R + 14.0:
        block = seat(out * along, 0.0)
        for tier in range(rng.randint(1, 3)):
            _wr_beam(bm, _WK_WORLD, block + across * -2.6 + Vector((0, 0, 0.5 + tier * 0.95)), block + across * 2.6 + Vector((0, 0, 0.5 + tier * 0.95)), 2.2, 0.9, twist=tier * 0.4)
        along += rng.uniform(5.0, 7.5)

    # Six frames down the lane. Standing ones arch; the fallen ones left their
    # leg stubs in the sand and their crowns lying where they came down.
    for index in range(6):
        r = WK_CRADLE_R + 14.0 - index * 6.6
        # Widening toward the sea, so from the middle of the arena the frames
        # nest one inside the next instead of eclipsing each other.
        grade = (r - (WK_CRADLE_R - 19.0)) / 33.0
        span = 10.6 + grade * 7.8 + rng.uniform(-0.5, 0.5)
        height = 15.8 + grade * 9.4 + rng.uniform(-1.2, 1.2)
        drift = across * (rng.uniform(-1.1, 1.1) + (3.4 if index % 2 else -3.4))
        centre = out * r + drift
        standing = index not in (3, 5)
        if standing:
            shoulders = []
            for side in (-1.0, 1.0):
                foot = seat(centre + across * (side * span), -0.6)
                knee = seat(centre + across * (side * span * 0.80), 0.0) + Vector((0, 0, height * 0.55))
                shoulder = seat(centre + across * (side * span * 0.34), 0.0) + Vector((0, 0, height * 0.92))
                _wr_beam(bm, _WK_WORLD, foot, knee, 3.4, 2.9)
                _wr_beam(bm, _WK_WORLD, knee, shoulder, 2.9, 2.5)
                shoulders.append(shoulder)
                # The diagonal shore that props the leg off the rail.
                _wr_beam(bm, _WK_WORLD, seat(centre + across * (side * (span + 6.5)), -0.4), knee + Vector((0, 0, -height * 0.16)), 2.0, 1.7)
            _wr_beam(bm, _WK_WORLD, shoulders[0], shoulders[1], 3.1, 2.6)
            # The tie beam, and the block the keel was hove down onto.
            tie_z = height * 0.34
            _wr_beam(bm, _WK_WORLD, seat(centre + across * -span * 0.88, 0.0) + Vector((0, 0, tie_z)), seat(centre + across * span * 0.88, 0.0) + Vector((0, 0, tie_z)), 1.7, 1.4)
            crown = (shoulders[0] + shoulders[1]) / 2
            _wr_beam(bm, _WK_WORLD, crown + Vector((0, 0, -0.9)), crown + Vector((0, 0, -3.4)), 1.6, 1.6)
        else:
            # Come down: two snapped stubs and the crown lying across the sand.
            for side in (-1.0, 1.0):
                foot = seat(centre + across * (side * span), -0.6)
                _wr_beam(bm, _WK_WORLD, foot, foot + across * (side * -1.1) + Vector((0, 0, rng.uniform(4.0, 8.0))), 3.4, 2.9)
            fall = across * rng.uniform(-4.0, 4.0) + out * rng.uniform(-3.0, 3.0)
            a = seat(centre + fall + across * -span * 0.62, 1.0)
            b = seat(centre + fall + across * span * 0.55 + out * 3.0, 2.2)
            _wr_beam(bm, _WK_WORLD, a, b, 2.3, 1.9, twist=rng.uniform(0.2, 0.9))
            _wr_beam(bm, _WK_WORLD, a + out * 3.4 + Vector((0, 0, 1.1)), b + out * -2.0, 2.0, 1.6, twist=rng.uniform(0.2, 0.9))

    # Ridge purlins tying the standing frames together, high over the lane.
    for pair in ((0, 1), (1, 2), (2, 4)):
        for side in (-1.0, 1.0):
            r0 = WK_CRADLE_R + 14.0 - pair[0] * 6.6
            r1 = WK_CRADLE_R + 14.0 - pair[1] * 6.6
            _wr_beam(
                bm,
                _WK_WORLD,
                seat(out * r0 + across * (side * 5.0), 0.0) + Vector((0, 0, 19.6)),
                seat(out * r1 + across * (side * 5.0), 0.0) + Vector((0, 0, 19.6)),
                1.7,
                1.4,
            )
    return _wr_finish("WrackArena_Cradle", bm, WK_CRADLEWOOD, "M_Wrack_Cradle")


def build_wk_ironwork(rng):
    """Verdigris iron (Deco - nothing here is meant to be stood on): the capstan at the head of the shoal that hauled him
    out, and four half-buried admiralty anchors dropped round the rim."""
    bm = bmesh.new()
    head = math.radians(WK_HEAD_DEG)
    out = Vector((math.cos(head), math.sin(head), 0.0))
    across = Vector((-math.sin(head), math.cos(head), 0.0))

    # The capstan: a banded drum on the lane's centreline behind the cradle,
    # with its bars still shipped and one snapped off short.
    drum_at = out * (WK_CRADLE_R + 17.0)
    drum_z = _wk_ground(drum_at.x, drum_at.y)
    tapered_cylinder(bm, drum_z - 1.0, drum_z + 4.6, 2.7, 2.2, sides=10, center=(drum_at.x, drum_at.y))
    tapered_cylinder(bm, drum_z + 4.6, drum_z + 5.4, 3.4, 3.1, sides=10, center=(drum_at.x, drum_at.y))
    for i in range(6):
        angle = (i / 6) * TAU + 0.3
        reach = 7.5 if i != 4 else 2.4
        arm = Vector((math.cos(angle), math.sin(angle), 0.0))
        _wr_beam(bm, _WK_WORLD, drum_at + Vector((0, 0, drum_z + 4.9)), drum_at + arm * reach + Vector((0, 0, drum_z + 4.4)), 0.7, 0.7)

    # Admiralty anchors, dropped where they were let go and half swallowed.
    for radius, degrees, tilt in ((70.0, 24.0, 0.9), (74.0, 118.0, 1.25), (68.0, 212.0, 0.7), (72.0, 316.0, 1.1)):
        angle = math.radians(degrees)
        cx, cy = math.cos(angle) * radius, math.sin(angle) * radius
        size = rng.uniform(6.0, 8.0)
        frame = _wr_frame((cx, cy, _wk_ground(cx, cy) - size * 0.16), yaw=angle + rng.uniform(-0.8, 0.8), roll=tilt)
        # Shank, from buried crown to the ring at the head.
        _wr_beam(bm, frame, (0, 0, -size * 0.30), (0, 0, size * 0.92), size * 0.15, size * 0.15)
        # The stock, crossed at the head, and the ring above it.
        _wr_beam(bm, frame, (0, -size * 0.46, size * 0.80), (0, size * 0.46, size * 0.80), size * 0.09, size * 0.09)
        for i in range(4):
            a0, a1 = (i / 4) * TAU, ((i + 1) / 4) * TAU
            _wr_beam(
                bm,
                frame,
                (math.cos(a0) * size * 0.13, 0, size * 1.03 + math.sin(a0) * size * 0.13),
                (math.cos(a1) * size * 0.13, 0, size * 1.03 + math.sin(a1) * size * 0.13),
                size * 0.06,
                size * 0.06,
            )
        # Two arms curving off the crown, each ending in a broad fluke.
        for side in (-1, 1):
            elbow = Vector((0, side * size * 0.34, -size * 0.18))
            tip = Vector((0, side * size * 0.52, size * 0.16))
            _wr_beam(bm, frame, (0, 0, -size * 0.26), elbow, size * 0.13, size * 0.12)
            _wr_beam(bm, frame, elbow, tip, size * 0.11, size * 0.10)
            _wr_beam(bm, frame, tip, tip + Vector((0, side * size * 0.10, size * 0.16)), size * 0.30, size * 0.05)
    return _wr_finish("WrackArena_DecoIronwork", bm, WK_IRON, "M_Wrack_Iron")


def build_wk_chains(rng):
    """Mooring chain: the haul chain still shackled from the capstan down the
    middle furrow - the line he pulls himself along - and slack runs snaking
    off the rim anchors into the fleet. Deco, so a chain can never trip a run."""
    bm = bmesh.new()
    head = math.radians(WK_HEAD_DEG)
    out = Vector((math.cos(head), math.sin(head), 0.0))

    def seat(point, lift=0.0):
        return Vector((point.x, point.y, _wk_ground(point.x, point.y) + lift))

    # The haul chain, running the centre groove from the capstan to the middle.
    drum = seat(out * (WK_CRADLE_R + 17.0), 4.6)
    mouth = seat(out * (WK_CRADLE_R + 6.0), 0.5)
    _wr_chain(bm, drum, mouth, 9, 0.8, sag=1.6)
    along = WK_CRADLE_R + 6.0
    while along > 12.0:
        nxt = max(12.0, along - 9.0)
        _wr_chain(bm, seat(out * along, 0.45), seat(out * nxt, 0.45), 7, 0.8)
        along = nxt
    # Slack runs off the rim anchors, out into the grounded fleet.
    for radius, degrees in ((70.0, 24.0), (74.0, 118.0), (68.0, 212.0), (72.0, 316.0)):
        angle = math.radians(degrees)
        start = Vector((math.cos(angle) * radius, math.sin(angle) * radius, 0.0))
        sweep = angle + rng.uniform(-0.55, 0.55)
        end = Vector((math.cos(sweep) * 84.0, math.sin(sweep) * 84.0, 0.0))
        _wr_chain(bm, seat(start, 1.4), seat(end, 1.2), 16, 0.7, sag=0.9)
    return _wr_finish("WrackArena_DecoChains", bm, WK_IRON, "M_Wrack_Iron")


# ------------------------------------------------- wrack: the six hulks


def build_wk_hulks(rng):
    """THE FIGHT FURNITURE. Six chunks of wreck standing in the open sand at
    r 33-52, each its own object so the fight logic can find and progressively
    shatter it, and each with a different silhouette so a player under pressure
    can tell them apart at a glance and remember which side is solid.

    Every one is over seven studs of continuous mass - real cover from a
    broadside - and every one is clear of the haul lane."""
    objects = []
    for index, (radius, degrees) in enumerate(WK_HULKS):
        bm = bmesh.new()
        angle = math.radians(degrees)
        cx, cy = math.cos(angle) * radius, math.sin(angle) * radius
        ground = _wk_ground(cx, cy)
        # Every hulk faces a little off the arena centre, so no two present
        # the same flat side to the middle.
        facing = angle + math.pi

        if index == 0:
            # 1. ON HER BEAM ENDS. A midships section rolled flat onto her
            #    side, half swallowed, her frames combing sideways out of the
            #    sand. The one you duck behind first.
            frame = _wr_frame((cx, cy, ground + 2.4), yaw=facing + 0.5, pitch=0.07, roll=math.radians(84))
            st = _wr_stations(21.0, 13.2, 5.2, freeboard=5.6, count=7, bow_rise=0.25, fullness=1.3)
            _wr_shell(bm, frame, st)
            _wr_wales(bm, frame, st)
            _wr_ribs(bm, frame, st, (0.10, 0.90), rise=6.2, thick=0.85)
            _wr_tear(bm, frame, st[0], rng, count=6)
            for f in (0.25, 0.55):
                x, half, _keel, sheer = st[int(f * (len(st) - 1))]
                _wr_beam(bm, frame, (x, half * 0.9, sheer - 0.3), (x, -half * 0.9, sheer - 0.3), 1.1, 0.6)
        elif index == 1:
            # 2. CAPSIZED STERN. Turned right over: her transom in the air,
            #    the rudder still hung on its pintles, upside down.
            frame = _wr_frame((cx, cy, ground + 4.8), yaw=facing - 0.7, pitch=-0.10, roll=math.radians(168))
            st = _wr_stations(19.0, 14.0, 6.0, freeboard=4.4, count=7, bow_rise=0.2, fullness=1.35)
            _wr_shell(bm, frame, st)
            _wr_wales(bm, frame, st, fractions=(0.34, 0.68))
            x0, half0, keel0, sheer0 = st[0]
            # The rudder, hanging off the transom and now pointing at the sky.
            _wr_beam(bm, frame, (x0 - 0.4, 0, keel0 + 0.6), (x0 - 1.6, 0, keel0 - 5.4), 1.0, 3.4)
            for pintle in (0.25, 0.62):
                _wr_beam(bm, frame, (x0 - 0.2, -1.4, keel0 - 5.4 * pintle), (x0 - 0.2, 1.4, keel0 - 5.4 * pintle), 0.5, 0.9)
            _wr_tear(bm, frame, st[-1], rng, count=5, spread=0.6)
            _wr_ribs(bm, frame, st, (0.55, 1.0), rise=4.6, thick=0.75)
        elif index == 2:
            # 3. A STACK OF SHATTERED STRAKES. Not a ship any more - a heap of
            #    planking crossed layer on layer where the sea stacked it, with
            #    a snapped mast driven clean through the pile. Low and broad:
            #    this is the one you crouch behind.
            frame = _wr_frame((cx, cy, ground), yaw=facing)
            for layer in range(8):
                lift = 0.5 + layer * 0.85
                a = rng.uniform(0, math.pi)
                length = rng.uniform(7.0, 10.5) * (1.0 - layer * 0.05)
                _wr_beam(
                    bm,
                    frame,
                    (math.cos(a) * -length, math.sin(a) * -length + rng.uniform(-1.5, 1.5), lift),
                    (math.cos(a) * length, math.sin(a) * length + rng.uniform(-1.5, 1.5), lift + rng.uniform(-0.5, 0.9)),
                    rng.uniform(2.6, 4.4),
                    rng.uniform(0.5, 0.9),
                    twist=rng.uniform(0, 0.7),
                )
            # A curled hull strake still holding its shape over the heap.
            for side in (-1, 1):
                _wr_beam(bm, frame, (-7.5, side * 3.4, 1.2), (2.0, side * 5.2, 6.4), 1.0, 3.0, twist=side * 0.5)
            _wr_spar(bm, frame, (-9.0, -2.0, 0.4), (8.5, 3.5, 9.6), 0.85, 0.45, sides=6)
            _wr_beam(bm, frame, (3.0, 1.0, 7.2), (3.4, 8.5, 5.2), 0.6, 0.6)
        elif index == 3:
            # 4. DRIVEN BOW. Rammed the shoal and stopped dead, stem to the
            #    sky, bowsprit still out over the sand. The tallest hulk, and
            #    the sightline breaker on the far side of the lane.
            frame = _wr_frame((cx, cy, ground - 1.4), yaw=facing + 2.7, pitch=0.46, roll=math.radians(-13))
            st = _wr_stations(21.0, 12.0, 5.4, freeboard=4.4, count=8, bow_rise=1.15)
            _wr_shell(bm, frame, st)
            _wr_wales(bm, frame, st)
            _wr_ribs(bm, frame, st, (0.0, 0.42), rise=6.0, thick=0.8)
            _wr_tear(bm, frame, st[0], rng)
            x, _half, _keel, sheer = st[-1]
            _wr_spar(bm, frame, (x * 0.97, 0.0, sheer - 0.5), (x * 1.34, 0.0, sheer + 2.6), 0.8, 0.30)
            _wr_beam(bm, frame, (x * 1.14, 0, sheer + 0.4), (x * 1.16, 0, sheer - 2.8), 0.55, 0.55)
        elif index == 4:
            # 5. STANDING MIDSHIPS. The only one still sitting upright on her
            #    keel: deck whole, gunports open along her side, a companionway
            #    box and a stub of mast. She reads as a WALL, which is what
            #    makes the other five read as rubble.
            frame = _wr_frame((cx, cy, ground + 0.5), yaw=facing + 1.5, pitch=0.04, roll=math.radians(-9))
            st = _wr_stations(20.0, 13.5, 5.0, freeboard=5.4, count=7, bow_rise=0.15, fullness=1.4)
            _wr_shell(bm, frame, st)
            _wr_wales(bm, frame, st, fractions=(0.28, 0.60, 0.86))
            # Gunports: a raised sill frame round each opening, three a side.
            for k, f in enumerate((0.24, 0.48, 0.72)):
                x, half, keel, sheer = st[int(f * (len(st) - 1))]
                port_z = keel + (sheer - keel) * 0.72
                for side in (1, -1):
                    y = side * half * 1.04
                    for dz, dx, w, t in ((1.1, 0.0, 0.35, 2.4), (-1.1, 0.0, 0.35, 2.4)):
                        _wr_beam(bm, frame, (x - 1.2 + dx, y, port_z + dz), (x + 1.2 + dx, y, port_z + dz), w, 0.5)
                    for dx in (-1.2, 1.2):
                        _wr_beam(bm, frame, (x + dx, y, port_z - 1.1), (x + dx, y, port_z + 1.1), 0.35, 0.5)
                    if k == 1:
                        # One lid still hanging open on its hinge.
                        _wr_beam(bm, frame, (x, y, port_z + 1.1), (x + 0.4, y + side * 2.2, port_z + 2.6), 2.4, 0.4)
            # The companionway, and the stub the mainmast snapped off at.
            x0, half0, _keel0, sheer0 = st[3]
            _wr_beam(bm, frame, (x0 - 2.6, 0, sheer0 + 1.6), (x0 + 2.6, 0, sheer0 + 1.6), 4.6, 3.2)
            _wr_spar(bm, frame, (x0 + 5.0, 0, sheer0 - 1.0), (x0 + 5.4, 0.6, sheer0 + 5.4), 1.0, 0.75, sides=6)
            _wr_tear(bm, frame, st[0], rng, count=6)
        else:
            # 6. KEEL UP. A ribcage wedge turned over - the keel line running
            #    along the top like a spine, frames splaying down into the
            #    sand, and a fallen yard lying across the whole thing.
            frame = _wr_frame((cx, cy, ground + 5.2), yaw=facing + 0.9, pitch=0.16, roll=math.radians(186))
            st = _wr_stations(22.0, 13.0, 5.6, freeboard=4.2, count=8, bow_rise=0.5, fullness=1.1)
            _wr_beam(bm, frame, (st[0][0], 0, st[0][2]), (st[-1][0], 0, st[-1][2]), 2.9, 1.5)
            _wr_wales(bm, frame, st, fractions=(0.96,), limit=1.0, width=1.2)
            _wr_ribs(bm, frame, st, (0.05, 0.95), rise=8.0, thick=1.05)
            x, _half, keel, sheer = st[-1]
            _wr_beam(bm, frame, (x - 1.0, 0, keel), (x + 2.4, 0, sheer + 8.4), 1.2, 1.2)
            # The fallen yard, lying across her from one side to the other.
            _wr_spar(bm, _WK_WORLD, (cx - 10.0, cy - 7.0, ground + 0.6), (cx + 8.0, cy + 9.0, ground + 7.4), 0.9, 0.5, sides=6)
        colour, material = (WK_HULKWOOD, "M_Wrack_HulkWood") if index % 2 == 0 else (WK_HULKPALE, "M_Wrack_HulkPale")
        objects.append(_wr_finish("WrackArena_Hulk%d" % (index + 1), bm, colour, material))
    return objects


# ------------------------------------------------- wrack: dressing and edges


def build_wk_ghost_fire(ships, rng):
    """Sea-fire in the wreck SOCKETS: a line of it drawn along the gunwales of
    the ghost ships in the boundary ring, and a knot burning in every open
    gunport. The wreck island's own language (M_GhostGlow), pulled teal."""
    bm = bmesh.new()
    for ship in ships:
        if not ship["ghost"]:
            continue
        frame, st = ship["frame"], ship["stations"]
        picked = st[2:-1]
        for side in (1, -1):
            for a, b in zip(picked, picked[1:]):
                _wr_beam(bm, frame, (a[0], side * a[1], a[3] + 0.40), (b[0], side * b[1], b[3] + 0.40), 0.75, 0.50)
        for i, (x, half, _keel, sheer) in enumerate(st):
            if i % 3 or i == 0:
                continue
            for side in (1, -1):
                point = frame @ Vector((x, side * half * 0.98, sheer + 0.9))
                rock(bm, point, (0.95, 0.95, 0.95), rng, jitter=0.08)
    return _wr_finish("WrackArena_DecoGhostFire", bm, WK_GHOST, "M_Wrack_Glow")


def build_wk_ghost_lamps(rng):
    """The lamps that are still lit: one hung under each standing cradle arch,
    a couple guttering in the hulks' broken sockets, and a few drifting low
    over the flat. The arena's only light source, and the colour that tells a
    player which wreckage is Wrack's."""
    bm = bmesh.new()
    head = math.radians(WK_HEAD_DEG)
    out = Vector((math.cos(head), math.sin(head), 0.0))
    for index in (0, 1, 2, 4):
        r = WK_CRADLE_R + 14.0 - index * 6.6
        at = out * r
        rock(bm, (at.x, at.y, _wk_ground(at.x, at.y) + 16.4), (1.25, 1.25, 1.5), rng, jitter=0.1)
    for radius, degrees in WK_HULKS:
        angle = math.radians(degrees)
        for _ in range(2):
            spread = rng.uniform(3.0, 7.0)
            spin = rng.uniform(0, TAU)
            x = math.cos(angle) * radius + math.cos(spin) * spread
            y = math.sin(angle) * radius + math.sin(spin) * spread
            rock(bm, (x, y, _wk_ground(x, y) + rng.uniform(1.6, 6.0)), (0.70,) * 3, rng, jitter=0.08)
    for _ in range(12):
        angle = rng.uniform(0, TAU)
        radius = rng.uniform(60.0, 86.0)
        x, y = math.cos(angle) * radius, math.sin(angle) * radius
        rock(bm, (x, y, _wk_profile(radius) + rng.uniform(1.2, 5.5)), (0.55,) * 3, rng, jitter=0.06)
    return _wr_finish("WrackArena_DecoGhostLamps", bm, WK_GHOST, "M_Wrack_Glow")


def build_wk_barrels(rng):
    """Stores spilled out of the fleet and washed up at the rim: barrels on
    their sides, crates stove in. EDGES ONLY - past r 64, so the open sand the
    fight needs stays open."""
    bm = bmesh.new()
    for _ in range(13):
        angle = rng.uniform(0, TAU)
        radius = rng.uniform(64.0, 78.0)
        cx, cy = math.cos(angle) * radius, math.sin(angle) * radius
        for _ in range(rng.randint(2, 4)):
            x, y = cx + rng.uniform(-4.0, 4.0), cy + rng.uniform(-4.0, 4.0)
            ground = _wk_ground(x, y)
            if rng.random() < 0.55:
                # A barrel, rolled onto its side and part buried.
                heading = rng.uniform(0, TAU)
                length = rng.uniform(2.6, 3.6)
                girth = rng.uniform(1.1, 1.6)
                axis = Vector((math.cos(heading), math.sin(heading), 0.0)) * (length / 2)
                _wr_spar(
                    bm,
                    _WK_WORLD,
                    Vector((x, y, ground + girth * 0.55)) - axis,
                    Vector((x, y, ground + girth * 0.55)) + axis,
                    girth * 0.82,
                    girth * 0.82,
                    sides=8,
                )
            else:
                size = rng.uniform(1.6, 2.6)
                box(
                    bm,
                    (x, y, ground + size * 0.34),
                    (size, size * rng.uniform(0.8, 1.2), size * rng.uniform(0.6, 0.9)),
                    Matrix.Rotation(rng.uniform(0, TAU), 3, "Z") @ Matrix.Rotation(rng.uniform(-0.4, 0.4), 3, "X"),
                )
    return _wr_finish("WrackArena_DecoBarrels", bm, WK_PLANK, "M_Wrack_Plank")


def build_wk_tideline(rng):
    """Tide wrack: the arc of weed, rope and shell the last high water left
    across the flat. Flat, dark, and Deco - it draws the high-water line the
    fleet lies just outside of, and gives the sand's edge something to read."""
    bm = bmesh.new()
    for _ in range(52):
        angle = rng.uniform(0, TAU)
        radius = rng.uniform(68.0, 79.0) + math.sin(angle * 3.0) * 1.8
        x, y = math.cos(angle) * radius, math.sin(angle) * radius
        length = rng.uniform(1.8, 4.2)
        rock(
            bm,
            (x, y, _wk_ground(x, y) + 0.08),
            (length, length * rng.uniform(0.24, 0.42), 0.16),
            rng,
            jitter=0.3,
        )
    # A few strands dragged further up the flat, following the ebb's run.
    for _ in range(14):
        angle = rng.uniform(0, TAU)
        radius = rng.uniform(56.0, 68.0)
        x, y = math.cos(angle) * radius, math.sin(angle) * radius
        rock(bm, (x, y, _wk_ground(x, y) + 0.07), (rng.uniform(1.4, 2.8), 0.5, 0.14), rng, jitter=0.35)
    return _wr_finish("WrackArena_DecoTideline", bm, WK_WEED, "M_Wrack_Weed")


def build_wk_foam(rng):
    bm = bmesh.new()
    # Surf ring outside the grounded fleet. Named *_Foam so OceanController
    # lifts it on the tide - and so the service strips its collision.
    angles = 40
    inner, outer = [], []
    for i in range(angles):
        angle = (i / angles) * TAU
        r0 = WK_FOAM_R[0] + rng.uniform(-1.0, 1.0)
        r1 = WK_FOAM_R[1] + rng.uniform(-1.3, 1.3)
        inner.append(bm.verts.new((math.cos(angle) * r0, math.sin(angle) * r0, 0.28)))
        outer.append(bm.verts.new((math.cos(angle) * r1, math.sin(angle) * r1, 0.22)))
    for i in range(angles):
        j = (i + 1) % angles
        bm.faces.new((inner[i], outer[i], outer[j], inner[j]))
    bmesh.ops.solidify(bm, geom=list(bm.faces) + list(bm.verts) + list(bm.edges), thickness=0.25)
    return _wr_finish("WrackArena_Foam", bm, WK_FOAM, "M_Wrack_Foam")


def build_wrack():
    rng = random.Random(8317)
    ships = _wk_fleet(rng)
    objects = [
        build_wk_base(rng),
        build_wk_shallows(rng),
        build_wk_tidewater(),
        build_wk_spoil(rng),
        build_wk_fleet(ships, rng),
        build_wk_fleet_ribs(ships, rng),
        build_wk_fleet_masts(ships, rng),
        build_wk_sails(ships, rng),
        build_wk_cradle(rng),
        build_wk_ironwork(rng),
        build_wk_chains(rng),
        *build_wk_hulks(rng),
        build_wk_ghost_fire(ships, rng),
        build_wk_ghost_lamps(rng),
        build_wk_barrels(rng),
        build_wk_tideline(rng),
        build_wk_foam(rng),
    ]
    head = math.radians(WK_HEAD_DEG)
    cradle_x, cradle_y = math.cos(head) * WK_CRADLE_R, math.sin(head) * WK_CRADLE_R
    print("HANDOFF wrack: mesh bottom z %.1f  <-- BossArenas meshBottom (default -9 fits)" % (SKIRT_BOTTOM - 0.5))
    print("HANDOFF wrack: walkable sand r 0-%.0f (wet ribbed flat, dished; z ~0.7-1.5), awash flat to r 88" % WK_SAND_R)
    print("HANDOFF wrack: boundary GROUNDED FLEET r %.0f-%.0f, 15 hulls, ring open %.0f deg at the head" % (WK_FLEET_R[0], WK_FLEET_R[1], WK_FLEET_GAP_DEG))
    print("HANDOFF wrack: foam ring r %.0f-%.0f (*_Foam: OceanController rides it), skirt to r 99" % WK_FOAM_R)
    print(
        "HANDOFF wrack: cradle bearing %.0f deg (the head of the shoal) rel (%.1f, %.1f), 6 arches r %.0f..%.0f, crowns z ~17 - WRACK STARTS HERE"
        % (WK_HEAD_DEG, cradle_x, cradle_y, WK_CRADLE_R - 19.0, WK_CRADLE_R + 14.0)
    )
    print(
        "HANDOFF wrack: haul lane bearing %.0f deg (cradle -> centre), length %.0f studs, 3 furrows at %s across, clear half-width %.0f"
        % ((WK_HEAD_DEG + 180.0) % 360.0, WK_CRADLE_R, ", ".join("%+.1f" % o for o in WK_FURROW_OFFSETS), WK_LANE_HALF)
    )
    for index, (radius, degrees) in enumerate(WK_HULKS):
        angle = math.radians(degrees)
        along, across = _wk_lane(math.cos(angle) * radius, math.sin(angle) * radius)
        print(
            "HANDOFF wrack: Hulk%d rel (%.1f, %.1f) r %.0f bearing %.0f deg, %.0f studs off the haul lane"
            " - the fight's DESTRUCTIBLE COVER (own object, shatter one at a time)"
            % (index + 1, math.cos(angle) * radius, math.sin(angle) * radius, radius, degrees, abs(across))
        )
    return objects


ARENAS = {
    "brinejaw": build_brinejaw,
    "gnashroot": build_gnashroot,
    "wrack": build_wrack,
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


# Per-arena preview framing. A shot is (suffix, location, rotation_degrees,
# look_at, lens): give it a rotation OR a point to aim at, not both. Brinejaw's
# entry is the original hand-set camera, kept exactly so its preview reframes
# byte-for-byte on a re-render.
CAMERAS = {
    "brinejaw": [("", (120, -165, 70), (68, 0, 36), None, 26)],
    "gnashroot": [
        ("", (0, -200, 150), None, (0, 0, 8), 28),
        # Standing on the peat between two stumps, looking across the mere -
        # the fight's own eyeline, which is the view that actually matters.
        ("_ground", (-56, 0, 7.0), None, (0, 0, 2.5), 26),
    ],
    "wrack": [
        # Three-quarter over the shoal, swung so the cradle sits upper-left and
        # the haul lane runs down-right into the middle - the one read that has
        # to survive: a ring of dead ships around a clean tidal flat.
        ("", (58, -196, 92), None, (-4, 6, 9), 32),
        # Standing near the middle at player eye height, looking back UP the
        # haul lane at the cradle: the view every challenger gets of where
        # Wrack is coming from, and the shot that says whether the furrows
        # read as a lane and whether the hulks are usable cover.
        ("_lane", (18.0, -10.0, 6.6), None, (-55.4, 32.0, 11.0), 24),
    ],
}

# The sky each arena is judged against, and how hard the sun works. The fen's
# dark peat and moss need more light than Brinejaw's sand to read at all.
SCENE = {
    "brinejaw": {"bg": (0.45, 0.65, 0.78, 1.0), "sun": 1.6, "fill": 0.0},
    # The fen is judged the way the island's own previews are judged: a dark
    # overcast sky, a hard key, and a soft fill so the dark peat and canopy
    # keep their form instead of going to one flat green.
    "gnashroot": {"bg": (0.17, 0.19, 0.20, 1.0), "sun": 1.7, "fill": 0.4},
    # Low water under a dirty sky: a hard raking key so the sand's ribbing and
    # the haul furrows throw real shadow (they are the whole floor read), and a
    # cool fill so the dark hulls keep their form instead of going to silhouette.
    "wrack": {"bg": (0.145, 0.172, 0.190, 1.0), "sun": 1.8, "fill": 0.42},
}


def render_preview(path, name):
    scene_look = SCENE.get(name, SCENE["brinejaw"])
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.rotation_euler = (math.radians(50), 0, math.radians(35))
    sun.data.energy = scene_look["sun"]
    bpy.context.collection.objects.link(sun)
    if scene_look.get("fill", 0.0) > 0:
        fill = bpy.data.objects.new("Fill", bpy.data.lights.new("Fill", "SUN"))
        fill.rotation_euler = (math.radians(64), 0, math.radians(-135))
        fill.data.energy = scene_look["fill"]
        bpy.context.collection.objects.link(fill)

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1500
    scene.render.resolution_y = 950
    scene.world = bpy.data.worlds.new("World")
    scene.world.use_nodes = True
    bg = scene.world.node_tree.nodes.get("Background")
    if bg:
        bg.inputs[0].default_value = scene_look["bg"]

    for suffix, location, rotation, look_at, lens in CAMERAS.get(name, CAMERAS["brinejaw"]):
        cam_data = bpy.data.cameras.new("Cam" + suffix)
        cam_data.lens = lens
        cam = bpy.data.objects.new("Cam" + suffix, cam_data)
        cam.location = Vector(location)
        if rotation is not None:
            cam.rotation_euler = tuple(math.radians(value) for value in rotation)
        else:
            cam.rotation_euler = (Vector(look_at) - cam.location).to_track_quat("-Z", "Y").to_euler()
        bpy.context.collection.objects.link(cam)
        scene.camera = cam
        out = path if not suffix else path.replace("_preview.png", "_preview%s.png" % suffix)
        scene.render.filepath = out
        bpy.ops.render.render(write_still=True)
        print("ARENA PREVIEW:", out)


def main():
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    if len(argv) < 2 or argv[1] not in ARENAS:
        print("usage: blender --background --python arena_gen.py -- <out.glb> <%s> [preview]" % "|".join(ARENAS))
        return
    clear_scene()
    objects = ARENAS[argv[1]]()
    export(argv[0], objects)
    if "preview" in argv[2:]:
        render_preview(argv[0].replace(".glb", "_preview.png"), argv[1])


if __name__ == "__main__":
    main()
