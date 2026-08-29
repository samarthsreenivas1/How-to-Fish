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
        r0 = 82.0 + rng.uniform(-1.2, 1.2)
        r1 = 87.5 + rng.uniform(-1.6, 1.6)
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
        r0 = 80.0 + rng.uniform(-1.2, 1.2)
        r1 = 86.0 + rng.uniform(-1.8, 1.8)
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


ARENAS = {
    "brinejaw": build_brinejaw,
    "gnashroot": build_gnashroot,
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
}

# The sky each arena is judged against, and how hard the sun works. The fen's
# dark peat and moss need more light than Brinejaw's sand to read at all.
SCENE = {
    "brinejaw": {"bg": (0.45, 0.65, 0.78, 1.0), "sun": 1.6, "fill": 0.0},
    # The fen is judged the way the island's own previews are judged: a dark
    # overcast sky, a hard key, and a soft fill so the dark peat and canopy
    # keep their form instead of going to one flat green.
    "gnashroot": {"bg": (0.17, 0.19, 0.20, 1.0), "sun": 1.7, "fill": 0.4},
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
