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
#   - FIVE MORE COVER PIECES inside the walkable field (BJ_COVER, the
#     `CoverStack*` / `CoverHulk` objects): the Riptide wave crosses the whole
#     arena and standing in a shadow is its only answer, so the field needs
#     eight sites spread round the circle, not three on three bearings.
#   - the keeper's BELL hangs off the gallery, not in the sand: Bell Toll has
#     the head strike it.
#   - dressing: fallen lantern-room rubble at the spire's foot, a shattered
#     rowboat. Open sand kept CLEAN on purpose (user, 2026-08-29) - the fight
#     paints its own telegraphs on it, and the cover pieces are the one thing
#     allowed to break that rule because a mechanic depends on them.
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
# THE COVER FIELD - the one table the wave attack's shadow test, the
# procedural fallback and this mesh all key off. Riptide crosses the whole
# arena and the answer is to put something solid between you and it, so every
# entry here has to be a thing a PLAYER fits behind: >= 6 studs wide and >= 5
# studs proud of the beach at its own radius. Everything else on this sand is
# ankle-high dressing and cannot be counted.
#
# (radius, degrees, part, width, rise) - `width` the full stud span above the
# sand, `rise` how far the top stands over the beach AT THAT RADIUS
# (_bj_height, not zero: the beach falls 3.2 -> 0.4 from centre to edge, so a
# constant z would leave the outer pieces a stud taller than the inner ones
# for no reason anyone could see).
#
# BEARINGS ARE THE POINT, not decoration. The three reef stones sit at 15 /
# 135 / 255 and leave three bare 120-degree arcs, which is exactly one wave
# with no answer in it; the five added pieces land at 75 / 105 / 195 / 285 /
# 315 so the eight sites step round the circle at 30-60 degrees and no arc is
# empty. The measured worst case is in the HANDOFF - re-run the coverage math
# if any of these move.
#
# THE MIRROR, for whoever copies these into BossArenas: the glTF export maps
# blender (x, y, z) -> (x, z, -y), so roblox Z is the NEGATIVE of blender y.
# build_brinejaw prints both frames; take the ROBLOX line.
BJ_COVER = [
    (40.0, 15.0, "ReefStone1", 6.8, 5.5),
    (40.0, 135.0, "ReefStone2", 6.8, 5.5),
    (40.0, 255.0, "ReefStone3", 6.8, 5.5),
    (22.0, 105.0, "CoverStack1", 8.0, 7.0),
    (22.0, 285.0, "CoverStack2", 8.0, 7.0),
    (58.0, 75.0, "CoverStack3", 10.0, 8.0),
    (58.0, 195.0, "CoverStack4", 10.0, 8.0),
    (58.0, 315.0, "CoverHulk", 11.0, 7.0),
]

# The slam-bait subset, kept as its own name because the fight distinguishes
# them: a hand-slam beside a REEF STONE shatters it and opens the punish
# window, where the same blow on a sea stack only jars the colossus. Derived,
# so the two lists cannot drift apart.
BJ_REEF_STONES = [(r, d) for r, d, part, _w, _h in BJ_COVER if part.startswith("ReefStone")]

# The keeper's bell, and it is no longer half-buried in the sand: Bell Toll
# has the serpent's head strike it, so it has to hang where the head rests -
# off the gallery, on REST.BEARING. That bearing is 342 degrees in ROBLOX,
# which is 18 here (see the mirror note above). r 9.0 puts the mouth clear
# outside the gallery lip at 7.3 and clear of the shaft at ~5.3.
BJ_BELL_R = 9.0
BJ_BELL_DEG = 18.0
BJ_BELL_Z = 53.0  # centre height; the bell is 5.0 deep, so 50.5..55.5

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


def _bj_cover_at(part):
    for radius, degrees, name, width, rise in BJ_COVER:
        if name == part:
            angle = math.radians(degrees)
            return math.cos(angle) * radius, math.sin(angle) * radius, radius, width, rise
    raise KeyError(part)


def build_bj_reef_stones():
    objs = []
    rng = random.Random(77)
    for index, (radius, degrees) in enumerate(BJ_REEF_STONES):
        part = "ReefStone%d" % (index + 1)
        cx, cy, _r, width, rise = _bj_cover_at(part)
        bm = bmesh.new()
        # GROWN TO COVER SPEC (they were 3.7 wide and stood 1.3 proud of the
        # sand - a stone you trip over, not one you hide behind). The CENTRES
        # are untouched on purpose: the fight's slam-bait offsets key off them.
        ground = _bj_height(radius)
        top = ground + rise
        half = width / 2
        # Sunk deep enough that the jitter can never lift a skirt off the beach.
        centre_z = top - half * 0.72
        rock(bm, (cx, cy, centre_z), (half, half, top - centre_z), rng, jitter=0.16)
        rock(bm, (cx + half * 0.75, cy - half * 0.6, ground + 0.6), (1.5, 1.5, 1.3), rng, jitter=0.25)
        objs.append(finish("BrinejawArena_%s" % part, bm, ROCKS))
    return objs


def build_bj_cover():
    """The five cover pieces added INSIDE the walkable field (BJ_COVER's
    non-ReefStone rows). The three existing reef stones and the boundary
    SeaStacks were the whole of the arena's cover, and the stacks stand at
    r 83-86 - outside the reef fence, past anywhere a player can stand. So a
    wave that crosses the field had three answers on one bearing each and
    three bare 120-degree arcs. These are separate named objects, one per
    cover site, so the shadow test and the fallback find each of them by name.
    """
    # Its OWN seeded stream, deliberately: threading build_brinejaw's shared
    # rng through here would shift every jitter drawn after it, so adding a
    # cover piece would silently re-scatter the boundary rocks and the kelp.
    rng = random.Random(9137)
    objs = []

    for part in ("CoverStack1", "CoverStack2", "CoverStack3", "CoverStack4"):
        cx, cy, radius, width, rise = _bj_cover_at(part)
        ground = _bj_height(radius)
        top = ground + rise
        half = width / 2
        bm = bmesh.new()
        # A leaning column of reef rock: broad at the foot, blunt at the top.
        # Sunk to -3 so the sand cannot show daylight under it.
        tapered_cylinder(bm, -3.0, top - 1.2, half, half * 0.80, sides=7, center=(cx, cy))
        rock(bm, (cx, cy, top - 1.4), (half * 0.82, half * 0.82, 1.6), rng, jitter=0.3)
        # Two boulders at the foot, so it reads as reef rather than a pillar
        # dropped on a beach - and so the shadow it throws has a wide base.
        for sign in (-1, 1):
            ox, oy = rng.uniform(-1, 1), rng.uniform(-1, 1)
            rock(
                bm,
                (cx + sign * half * 0.9 + ox, cy - sign * half * 0.7 + oy, ground + 0.4),
                (rng.uniform(1.6, 2.3),) * 3,
                rng,
                jitter=0.25,
            )
        objs.append(finish("BrinejawArena_%s" % part, bm, ROCKS))

    # The hulk: the ship the beached rowboat came from, and the thing the
    # leaning mast has been sprouting out of bare sand without. Its centre is
    # 6 studs from the mast's foot, laid along the mast's own heading, so the
    # two read as one wreck.
    cx, cy, radius, width, rise = _bj_cover_at("CoverHulk")
    ground = _bj_height(radius)
    top = ground + rise
    heading = math.atan2(-55.0 - -35.0, 64.0 - 40.0)  # the mast's bearing
    rot = Matrix.Rotation(heading, 3, "Z")
    at = Vector(((cx), (cy), 0.0))
    bm = bmesh.new()
    # Two hull sides, flared out at the top like a broken-open ribcage.
    for side in (-1, 1):
        box(
            bm,
            at + rot @ Vector((0, side * width * 0.30, ground + rise * 0.42)),
            (15.0, 0.9, rise * 0.95),
            rot @ Matrix.Rotation(math.radians(side * 12), 3, "X"),
        )
    # Ribs arcing over what is left of the deck, a couple snapped short.
    for i in range(5):
        along = (i / 4 - 0.5) * 12.0
        h = top if i % 3 != 1 else ground + rise * 0.55
        for side in (-1, 1):
            foot = at + rot @ Vector((along, side * width * 0.34, ground - 0.5))
            crown = at + rot @ Vector((along * 0.9, side * width * 0.16, h + 0.6))
            taper_between(bm, foot, crown, 0.55, 0.35, sides=5)
    # The keel timber the ribs sit on, half swallowed by the sand.
    box(bm, at + rot @ Vector((0, 0, ground - 0.2)), (16.0, 2.4, 1.6), rot)
    objs.append(finish("BrinejawArena_CoverHulk", bm, DRIFTWOOD))
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
    # THE KEEPER'S BELL, and it is a fight object now, not dressing. Bell Toll
    # has the serpent's head strike it and rings expand from the tower, so a
    # bell lying half-buried in the sand 46 studs away - where it used to be -
    # could not be what the attack shows. It hangs from the gallery on
    # REST.BEARING, the bearing the head already rests over: the strike reads
    # as a strike without the pose moving an inch.
    angle = math.radians(BJ_BELL_DEG)
    bell_at = Vector((math.cos(angle) * BJ_BELL_R, math.sin(angle) * BJ_BELL_R, BJ_BELL_Z))
    # The yoke: a beam out from the gallery lip that the bell swings under.
    inner = Vector((math.cos(angle) * (BJ_SPIRE_TOP_R + 0.6), math.sin(angle) * (BJ_SPIRE_TOP_R + 0.6), BJ_SPIRE_TOP_Z + 1.9))
    outer = Vector((bell_at.x, bell_at.y, BJ_SPIRE_TOP_Z + 2.4))
    taper_between(bm, inner, outer, 0.55, 0.45, sides=5)
    # ...and the bell itself: mouth down, crown up, 6 studs across the mouth so
    # it is legible from the sand 55 studs below.
    mat = Matrix.Translation(bell_at)
    bmesh.ops.create_cone(bm, cap_ends=True, segments=12, radius1=3.0, radius2=1.4, depth=5.0, matrix=mat)
    # The lip ring, and the crown loop the yoke holds.
    mat = Matrix.Translation(bell_at + Vector((0, 0, -2.2)))
    bmesh.ops.create_cone(bm, cap_ends=True, segments=12, radius1=3.2, radius2=3.2, depth=0.7, matrix=mat)
    box(bm, bell_at + Vector((0, 0, 2.9)), (0.9, 0.9, 1.4))
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
        *build_bj_cover(),
        *build_bj_dressing(rng),
        *build_bj_edge_detail(rng),
    ]
    print("HANDOFF brinejaw: mesh bottom z %.1f  (skirt constant, informational - the authoritative meshBottom is MEASURED at export)" % (SKIRT_BOTTOM - 0.5))
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
    # THE COVER TABLE, printed in ROBLOX coordinates ready to paste into
    # BossArenas.items.tropical.cover - the mirror (roblox Z = -blender y) is
    # already applied, because copying build-space pairs straight across is the
    # mistake this repo has now made twice (the Pyrelisk monoliths, the Noctyss
    # sockets), and a mirrored cover site is the worst kind: it still exists,
    # still blocks a wave, and only ever disagrees with the rock on screen.
    print("HANDOFF brinejaw: cover sites - the Riptide wave-shadow field (%d)" % len(BJ_COVER))
    for radius, degrees, part, width, rise in BJ_COVER:
        angle = math.radians(degrees)
        print(
            "HANDOFF brinejaw:   %-11s ROBLOX rel (%.1f, 0, %.1f)  r %.0f bearing %.0f deg"
            "  width %.1f (radius %.1f)  rise %.1f over sand %.1f"
            % (
                part,
                math.cos(angle) * radius,
                -math.sin(angle) * radius,
                radius,
                degrees,
                width,
                width / 2,
                rise,
                _bj_height(radius),
            )
        )
    angle = math.radians(BJ_BELL_DEG)
    print(
        "HANDOFF brinejaw: Bell ROBLOX rel (%.1f, %.1f, %.1f) - hung off the gallery on "
        "REST.BEARING; SET BossArenas.tropical.bell to this and BrinejawPath REST.BELL with it"
        % (math.cos(angle) * BJ_BELL_R, BJ_BELL_Z, -math.sin(angle) * BJ_BELL_R)
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
    print("HANDOFF gnashroot: mesh bottom z %.1f  (skirt constant, informational - the authoritative meshBottom is MEASURED at export)" % (SKIRT_BOTTOM - 0.5))
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
# ADMIRAL WRACK / the Careenage. REDESIGNED 2026-09-01 on the user's brief:
# "completely redesign the island. make it much bigger without any clutter. i
# like the design of the boss, but you need to make it usable for players. make
# the floor walkable and plain without much decoration. and make sure that the
# boss design fits in with the island and the placement of the boss."
#
# WHAT THIS REPLACES. The first Careenage was a 78-stud shoal with six
# breakwater hulks standing in the open sand at r 33-52, a collapsed careening
# cradle arching over r 45-78, three grounding furrows ploughed down a haul
# lane, tide puddles, spoil heaps, barrels and chain runs across the middle.
# The hulks were justified as COVER FROM THE BROADSIDES. They were never cover:
# ProjectileService.tick advances every ball by velocity and tests a sphere
# against players - there is no raycast anywhere in it, so nothing in this game
# occludes a bullet. All six ever did was block the player's own movement and
# break up the floor the fight paints its telegraphs on. Deleting them costs
# the fight nothing it actually had.
#
# THE FLOOR IS THE PRODUCT, and there are three rules under it.
#
#   1. WALKABLE SAND TO r 132 - a 264-stud field, 1.7x the old radius and 2.9x
#      the area - with NOTHING standing on it. No object in this build has a
#      single vertex inside r 132 below head height except _Base itself; the
#      HANDOFF prints the measured clearance, because "I did not put anything
#      there" is a claim and the export is the measurement.
#
#      Why 132 and not 150. The band the brief allows is 130-150 and the low
#      end is the honest pick, because every stud past it is a stud the fight's
#      own guns cannot reach. Reach is spawnAt + speed * lifetime, off
#      Bosses.luau: anchorsweep 106, slewfire 113, chainshot 114, slewfireFast
#      117, broadside 125, broadsideHeavy 128. Five of the nine patterns
#      already die inside 130. At 132 the deadliest wall in the fight
#      (broadsideHeavy) falls four studs short of the palisade - the outer ring
#      reads as the last resort it should be, and the retune owed is a lifetime
#      nudge rather than a redesign. At 150 that same wall would leave a
#      22-stud rest area no gun can touch, all the way round.
#
#      And he still has to read as the centrepiece. From the far rim his
#      87-stud hull subtends 2*atan(43.5/132) = 37 degrees - better than half a
#      standard 70-degree FOV - and his masthead stands 21 degrees above the
#      horizon. At 150 that falls to 33 and 18.
#
#   2. THE SHAPE IS A BEACH, NOT A DISH. A careenage is where a ship is hove
#      down to have her bottom scraped, so the ground has to be something you
#      could haul a ship onto: a broad foreshore, flat at the water's edge and
#      rising gently inland. `_wk_beach` is that profile and NOTHING ELSE - a
#      single smooth curve in y, so the contour lines are STRAIGHT and parallel
#      and the fall line is legible from any camera. 0.45 studs at the water's
#      edge (bearing WK_SEA_DEG), 1.05 through the middle where he lies, 4.85
#      at the head of the beach. Steepest grade anywhere on it: 4.8%, at the
#      top, which is 2.7 degrees - it cannot be tripped on, jumped off or
#      stood behind, and a player will never once notice climbing it.
#
#      The old shoal's tidal ripples are GONE with the rest of the clutter, and
#      not only for tidiness: they were near-concentric, 0.6 studs peak to
#      peak, and the signature attack of this fight is three concentric rings
#      of cannonballs with one gap in them. A ringed floor under a ringed
#      telegraph is the worst pattern read available.
#
#   3. DECORATION ONLY AT THE BOUNDARY, and the boundary is the same idea it
#      always was, scaled out: a PALISADE OF DEAD SHIPS. Twenty-four half-sunk
#      hulls bedded at r 140-152, on their beam ends, picked to the ribs, a
#      few driven bow-up and reared steep, masts leaning in overhead and canvas
#      still bent to the yards. It opens in ONE place - WK_FLEET_GAP_DEG of
#      clear water at bearing WK_SEA_DEG - and that is the mouth of the
#      careenage, the low end of the beach, and the only bearing a player can
#      read out of the arena. Everything else out there is ground tackle: four
#      drowned admiralty anchors and their chain runs, a tide-wrack line along
#      the water's edge, the ghost fleet's own sea-fire, and the surf ring.
#
# WHY HE FITS WHERE HE LIES. boss_gen authors him heeled 48 degrees about his
# own x axis, which puts his masts and rigging over +y and his barnacled
# bottom, his exposed keel and the Keel battery under -y. This beach falls
# toward +y. So he lies ALONG the contours with his masts down the slope toward
# the water and his scraped bottom turned up the beach at the men who would
# have been working it - which is exactly what a ship beached at the top of the
# tide does when the water leaves her. The ground under his 47-stud beam varies
# 0.80 to 1.41 studs across that heel, uphill under the bared side, and his own
# `Wrack_Base` bedding (4.5 studs thick) swallows the difference. The centre of
# the beach is held at 1.05 studs, the exact height the old shoal had, so his
# placement does not move by a hair.
#
# The BOSS MESH IS NOT BUILT HERE - assets/boss_gen.py owns it, and this pass
# does not touch it. This builds the ground he lies on.
#
# Palette and carpentry both come straight off Wreckwater (island_gen.py's
# wreck COLORS and its `_wr_` ship helpers). Every name here is WK_/`_wr_`
# scoped and every material datablock is `M_Wrack_*` - disjoint from the boss's
# own `M_Wrack_Adm*`, because `make_material` caches datablocks BY NAME and a
# collision silently repaints across models with build order picking the winner.


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
    between objects that genuinely are the same timber without ever reaching
    another arena - or the boss, whose own are `M_Wrack_Adm*`."""
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
    strakes, chain links. The workhorse of a shipbreaker's yard."""
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


# ------------------------------------------------- wrack: the beach itself

WK_SAND_R = 132.0  # WALKABLE SAND. Nothing stands on it. See the header.
WK_SEA_DEG = 90.0  # downhill: the water, the mouth of the palisade, the wrack line
WK_HEAD_DEG = (WK_SEA_DEG + 180.0) % 360.0  # uphill: the head of the beach

# The three heights that define the beach. CENTRE is held at the old shoal's
# own centre height so the boss's placement does not move; SEA is the water's
# edge and is the number the waterline rule is decided by (nothing walkable may
# sit below z 0, and BossArenaService.WATERLINE_TOLERANCE is 0.25, so this is
# 0.45 studs of daylight at the lowest walkable point in the arena); HEAD is
# the top of the beach.
WK_SEA_Z = 0.45
WK_CENTRE_Z = 1.05
WK_HEAD_Z = 4.85

# The exponent that makes the curve pass through WK_CENTRE_Z at the middle,
# SOLVED rather than typed: the fall line's parameter is 0.5 at the centre, so
# the shape is pinned by the three heights above and nothing else can drift out
# of agreement with them. Works out at ~2.87 - flat at the water's edge,
# steepening to 4.8% (2.7 degrees) at the head, which is a real foreshore and
# is still nothing at all underfoot.
WK_BEACH_P = math.log((WK_CENTRE_Z - WK_SEA_Z) / (WK_HEAD_Z - WK_SEA_Z)) / math.log(0.5)

WK_FLEET_R = (140.0, 152.0)  # the palisade: where the grounded hulls START
WK_FLEET_GAP_DEG = 46.0  # the mouth, centred on WK_SEA_DEG

# THE CLEARANCE THE PALISADE OWES THE FLOOR. A ship on her beam ends combs her
# rib cage out sideways at ankle height, and a mast leaning in over the sand
# comes down as it goes; both are wanted, and both will walk into the arena if
# nobody stops them - the first build of this redesign put a rib at z 1.3 four
# studs inside the rim and a mast at 12.8 studs nine studs inside it. So the
# band above is where a hull STARTS and these two numbers are what decide where
# she ends: every hull is pushed out until her own low geometry clears
# WK_SAND_R + WK_FLEET_STANDOFF, and every mast's lean is clamped so it crosses
# head height no further in than the rim. Enforced per ship rather than tuned,
# because a tuned number is only true for the seed it was tuned on.
#
# WK_HEADROOM is what "over the floor rather than in it" means: a Roblox
# character is 5 studs and a jump adds about 7.
WK_HEADROOM = 13.0
WK_FLEET_STANDOFF = 1.5
# Outside the outermost hull the guard can push: the surf has to break round
# the palisade, not through the middle of it.
WK_FOAM_R = (161.0, 167.5)
WK_MERGE_R = 158.0  # outside here the beach has given way to the drowned cone

# WHERE THE UNDERSIDE CLOSES, and why it is not the shared SKIRT_BOTTOM.
#
# `meshBottom` in BossArenas is the model's whole bbox floor, so the arena's
# placement is decided by WHATEVER HANGS LOWEST - and on a shoal whose boundary
# is two dozen half-sunk hulls, that is not automatically the landform. It was
# not: the palisade's deepest keel bottoms out around -11, three studs under
# the -9.5 cap the old 99-stud shoal closed at, and the first build of this
# redesign duly handed placement to one randomly-seeded ship. That is exactly
# the failure the BossArenas comment warns about, arriving from the direction
# it warns about it from.
#
# So the underside cone closes below the whole fleet on purpose. The visible
# rim is untouched (SKIRT_BOTTOM at r 172, as before); this is the hidden cap
# under it, and it restores the property the config row states outright - that
# the base's own skirt is the bbox floor - so the number stays stable if the
# fleet is ever reseeded.
WK_CAP_Z = -13.5

# The drowned apron, as a RADIAL profile - past the walkable sand the beach
# stops mattering and the shoal just dives. `_wk_ground` blends from the beach
# surface into this between WK_SAND_R and WK_MERGE_R, so the head of the beach
# stays high and dry further out than the mouth does and the palisade lies at
# every depth from grounded to awash.
WK_PROFILE = [
    (WK_SAND_R, WK_CENTRE_Z),
    (142.0, -0.60),  # the awash flat the grounded fleet lies in
    (152.0, -2.30),
    (160.0, -5.60),
    (166.0, -7.80),
    (172.0, SKIRT_BOTTOM),
]

# Straight off Wreckwater's own palette (island_gen.py wreck COLORS), pulled
# wetter and greyer. WK_-scoped so it cannot rebind another arena's constants.
WK_SAND = (0.445, 0.429, 0.384)  # the foreshore: wet grey-brown shoal sand
WK_WET = (0.352, 0.352, 0.325)  # the drowned apron: everything below low water
WK_HULL = (0.112, 0.092, 0.076)  # M_HullWood, driven darker - the boundary is near-black
WK_STRAKE = (0.205, 0.172, 0.136)  # the boundary's frames: a shade up off the planking
WK_SPARWOOD = (0.329, 0.271, 0.204)  # M_WreckPost - masts and yards
WK_CANVAS = (0.652, 0.658, 0.618)  # M_WreckSail - rotted canvas, bone with a green cast
WK_IRON = (0.300, 0.400, 0.352)  # verdigris: the ground tackle
WK_WEED = (0.255, 0.300, 0.212)  # the tide wrack along the water's edge
WK_GHOST = (0.560, 0.949, 0.800)  # M_GhostGlow pulled teal - the ghost fleet's own light
WK_FOAM = (0.800, 0.824, 0.812)  # M_WreckFoam, pulled off pure white


def _wk_beach(y):
    """The foreshore's height at a distance `y` along the fall line.

    A FUNCTION OF ONE COORDINATE, deliberately: that is what makes the contour
    lines straight and parallel, which is what makes it read as a beach a ship
    could be hauled up rather than as a dish or a dome. It is also why the
    floor has no local features at all - there is nowhere for one to hide."""
    w = min(max((WK_SAND_R - y) / (2.0 * WK_SAND_R), 0.0), 1.0)
    return WK_SEA_Z + (WK_HEAD_Z - WK_SEA_Z) * w**WK_BEACH_P


def _wk_profile(r):
    for (r0, h0), (r1, h1) in zip(WK_PROFILE, WK_PROFILE[1:]):
        if r <= r1:
            t = 0 if r1 == r0 else (r - r0) / (r1 - r0)
            return h0 + (h1 - h0) * t
    return WK_PROFILE[-1][1]


def _wk_ground(x, y):
    """The shoal's surface. Pure and deterministic - no rng anywhere in it - so
    every prop that seats itself with this lands exactly on the sand.

    Inside the walkable radius it is the beach and NOTHING ELSE. Outside, it
    eases off the beach into the drowned cone by WK_MERGE_R."""
    a = math.radians(WK_SEA_DEG)
    beach = _wk_beach(x * math.cos(a) + y * math.sin(a))
    r = math.hypot(x, y)
    if r <= WK_SAND_R:
        return beach
    t = min((r - WK_SAND_R) / (WK_MERGE_R - WK_SAND_R), 1.0)
    t = t * t * (3.0 - 2.0 * t)
    return beach * (1.0 - t) + _wk_profile(r) * t


def build_wk_base(rng):
    """The beach, and the drowned shoal it stands on. ONE object, no features.

    Sampled every six studs across the walkable sand - which is as coarse as it
    is because there is nothing on this surface finer than that to resolve. The
    old shoal sampled at 2.5 to carry its ripples and haul furrows; those are
    gone, and the sparser grid is the honest consequence rather than a saving."""
    bm = bmesh.new()
    angles = 64
    rings = [step * 6.0 for step in range(1, 23)] + [137.0, 143.0, 150.0, 158.0, 165.0, 172.0]
    grid = []
    for radius in rings:
        ring = []
        for i in range(angles):
            angle = (i / angles) * TAU
            # The silhouette wobbles only OUTSIDE the walkable sand, so the
            # floor the fight is fought on matches _wk_ground exactly and its
            # edge is a true circle at WK_SAND_R.
            r = radius * (1.0 + (rng.uniform(-0.035, 0.035) if radius > WK_SAND_R else 0.0))
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
    # Close the underside so the skirt reads solid from below - and see
    # WK_CAP_Z for why this one closes deeper than the shared convention.
    bottom = bm.verts.new((0, 0, WK_CAP_Z))
    outer = grid[-1]
    for i in range(angles):
        bm.faces.new((bottom, outer[(i + 1) % angles], outer[i]))
    return _wr_finish("WrackArena_Base", bm, WK_SAND, "M_Wrack_Sand")


def build_wk_shallows(rng):
    """The drowned apron: the wet skin over everything below low water, from
    the water's edge out across the flat the fleet lies in and on down the
    skirt. Built in bands that follow the profile - a single band from the rim
    straight to the skirt chords across a landform that is diving steeply by
    then, sinks under it, and leaves the arena sitting on a bright plate of
    dry-looking sand.

    Its inner edge starts ONE STUD inside the walkable rim and no further. That
    single stud of overlap is what stops a hairline of dry base showing at the
    seam; it is flat, it is Deco, and it is the only paint of any kind this
    build puts inside r 132."""
    bm = bmesh.new()
    angles = 48
    steps = (131.0, 140.0, 149.0, 157.0, 165.0, 172.6)
    grid = []
    for radius in steps:
        ring = []
        for i in range(angles):
            angle = (i / angles) * TAU
            r = radius + rng.uniform(-1.2, 1.2)
            x, y = math.cos(angle) * r, math.sin(angle) * r
            z = _wk_ground(x, y) + (0.10 if radius <= WK_SAND_R else 0.27)
            ring.append(bm.verts.new((x, y, z)))
        grid.append(ring)
    for a, b in zip(grid, grid[1:]):
        for i in range(angles):
            j = (i + 1) % angles
            bm.faces.new((a[i], b[i], b[j], a[j]))
    bmesh.ops.solidify(bm, geom=list(bm.faces) + list(bm.verts) + list(bm.edges), thickness=0.2)
    return _wr_finish("WrackArena_DecoShallows", bm, WK_WET, "M_Wrack_Wet")


# ------------------------------------------------- wrack: the grounded fleet


def _wk_ship_probes(stations, length, width, kind, driven):
    """Ship-local points that BOUND the solid parts of one grounded hull.

    Not the geometry - a bound on it, deliberately generous: the shell rings at
    keel and sheer, the rib combs that arc off the sheer, the splinters
    standing off the tear, and whatever rears at the bow (stempost or
    bowsprit). `_wk_fleet` swings these through the ship's own rotation to ask
    how far back toward the arena she reaches at low level, which is the only
    honest way to place a wall built out of shapes this irregular."""
    rise = width * (0.75 if kind == "ribs" else (0.52 if not driven else 0.52))
    points = []
    for x, half, keel, sheer in stations:
        for side in (1.0, -1.0):
            points.append((x, side * half * 1.05, keel))
            points.append((x, side * half * 1.05, sheer))
            points.append((x, side * half * 0.75, sheer + rise))
        # The tear's splinters, and the stern castle on a `stern` hull.
        points.append((x, 0.0, sheer + max(5.4, width * 0.50)))
    x, _half, _keel, sheer = stations[-1]
    points.append((x * 1.35, 0.0, sheer + max(length * 0.10, width * 0.70)))
    return points


def _wk_fleet(rng):
    """The palisade, generated once and shared by every builder that hangs
    something off it, so hull, ribs, masts, canvas and sea-fire all agree with
    the ship they belong to (the Rootmere's `_gn_trees` pattern).

    Thirty hulls, not the old fifteen: at r 150 the ring is 942 studs round
    against the old 528, and fifteen ships spread over that is a scatter of
    boats with sky between them, not a wall. Lengths are up with it. Thirty
    hulls averaging 43 studs is 1290 studs of ship on 822 studs of arc - 1.57x
    overlap, against the old build's 1.30 - and the palisade is the one thing
    in this arena that is ALLOWED to be dense.

    The ring OPENS at the MOUTH - WK_FLEET_GAP_DEG of clear water on the
    seaward bearing, where the beach is lowest and the sea comes in. It is the
    only bearing a player can read out of the arena, and it is the geography
    that says how an 87-stud flagship got hauled in here to be hove down."""
    ships = []
    count = 30
    gap = math.radians(WK_FLEET_GAP_DEG)
    mouth = math.radians(WK_SEA_DEG)
    for i in range(count):
        angle = mouth + gap / 2 + ((i + 0.5) / count) * (TAU - gap) + rng.uniform(-0.045, 0.045)
        # Five in thirty were driven at the shoal and stopped dead, and
        # they rear STEEP - 46 to 58 degrees, not the old 26 to 38. A reared
        # bow's reach inward goes as cos(pitch) and its height as sin(pitch),
        # so steepening it turns an overhang that leaned down over the sand
        # into one that stands over it. The clearance HANDOFF measures the
        # result rather than trusting this paragraph.
        driven = i % 6 == 5
        if driven:
            radius = rng.uniform(WK_FLEET_R[0] + 6.0, WK_FLEET_R[1])
            length, width, depth = rng.uniform(24.0, 32.0), rng.uniform(10.5, 13.0), rng.uniform(4.4, 5.6)
            yaw = angle + math.pi + rng.uniform(-0.20, 0.20)
            pitch = rng.uniform(0.80, 1.01)
            roll = rng.uniform(-0.30, 0.30)
            lift = rng.uniform(1.4, 2.6)
        else:
            radius = rng.uniform(*WK_FLEET_R)
            length, width, depth = rng.uniform(34.0, 52.0), rng.uniform(11.0, 15.5), rng.uniform(4.8, 6.8)
            yaw = angle + math.pi / 2 + rng.uniform(-0.38, 0.38)
            pitch = rng.uniform(-0.15, 0.15)
            # Heeled hard, and about half of them right over on their beam ends.
            roll = rng.uniform(0.55, 1.55) * (1.0 if i % 2 == 0 else -1.0)
            lift = rng.uniform(1.7, 3.2)
        kind = ("shell", "ribs", "stern")[i % 3]
        stations = _wr_stations(
            length,
            width,
            depth,
            freeboard=width * (0.44 if not driven else 0.40),
            count=9,
            bow_rise=1.25 if driven else 0.35,
            fullness=1.0 if driven else 1.2,
        )
        # PUSH HER OUT UNTIL SHE CLEARS THE FLOOR. Twice, because the answer
        # depends on the ground height at the radius the answer picks: swing
        # the hull's bounding points through her own rotation, keep only the
        # ones that end up below head height, and take the furthest any of them
        # reaches back toward the middle. A hull that leans away from the arena
        # is not moved at all, which is why the ring keeps an uneven radius
        # instead of retreating to one safe circle.
        spin = _wr_frame((0.0, 0.0, 0.0), yaw=yaw, pitch=pitch, roll=roll)
        probes = [spin @ Vector(p) for p in _wk_ship_probes(stations, length, width, kind, driven)]
        outward = Vector((math.cos(angle), math.sin(angle), 0.0))
        for _ in range(2):
            x, y = math.cos(angle) * radius, math.sin(angle) * radius
            deck = _wk_ground(x, y) + lift
            reach = 0.0
            for point in probes:
                if deck + point.z >= WK_HEADROOM:
                    continue
                reach = max(reach, -(point.x * outward.x + point.y * outward.y))
            radius = max(radius, WK_SAND_R + WK_FLEET_STANDOFF + reach)
        x, y = math.cos(angle) * radius, math.sin(angle) * radius
        # Seated on the REAL surface, not on the radial profile: past the
        # walkable rim the beach still has a fall line, so the head of the
        # palisade lies grounded and dry while the mouth of it lies awash.
        at = Vector((x, y, _wk_ground(x, y) + lift))
        ships.append(
            {
                "frame": _wr_frame((at.x, at.y, at.z), yaw=yaw, pitch=pitch, roll=roll),
                "at": at,
                "in": Vector((-math.cos(angle), -math.sin(angle), 0.0)),  # toward the fight
                "kind": kind,
                "driven": driven,
                "ghost": i % 3 == 0,
                "stations": stations,
                "radius": radius,
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

    Everything hangs high. A mast is stepped at r 140 or beyond and leans in at
    most 30 degrees, so where a spar first crosses the walkable rim it is
    already twenty-odd studs up - the palisade frames the fight from overhead
    and nothing it carries comes down into it."""
    bm = bmesh.new()
    for ship in ships:
        frame = ship["frame"]
        for m in range(ship["masts"]):
            # Stepped inside the hull, so the foot is always buried in timber.
            foot = frame @ Vector((ship["length"] * (0.32 + 0.30 * m), 0.0, ship["stations"][3][2] + 0.5))
            height = rng.uniform(26.0, 44.0) * (0.8 if m else 1.0)
            lean = rng.uniform(0.26, 0.52)
            # CLAMPED, not trusted. A leaning mast trades height for reach at a
            # fixed rate - it loses (WK_HEADROOM - foot z) * tan(lean) studs of
            # radius before it gets clear of a player's head - so the steepest
            # lean this foot can afford is exactly the arctangent of the room
            # it has. Below head height the spar is then always outside the
            # rim, and so is everything hung off it: the yard is perpendicular
            # to the lean plane (tangential, which only ever adds radius) and
            # the snapped topmast breaks off high enough that its drop cannot
            # reach back down through head height.
            # Minus the spar's own butt radius: the clamp is about where the
            # TIMBER is, and a mast whose axis stops exactly on the rim still
            # has two and a half studs of itself inside it. That is the whole
            # 0.6 studs the first guarded build was over by.
            room = max(math.hypot(foot.x, foot.y) - WK_SAND_R - height * 0.055, 0.0)
            lean = min(lean, math.atan(room / max(WK_HEADROOM - foot.z, 0.1)))
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
            # Shorter hems than the old build carried: at this mast height a
            # 1.5x drop would hang canvas down toward the rim, and the whole
            # point of the palisade is that it stays overhead.
            drop = half * rng.uniform(0.75, 1.15)
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


# ------------------------------------------------- wrack: the boundary dressing


# (radius, bearing, tilt) for the four anchors. All four in the awash flat,
# outside the walkable rim, and off the mouth's bearing so the one gap in the
# palisade stays a clean read.
WK_ANCHORS = ((141.0, 24.0, 0.9), (146.0, 152.0, 1.25), (139.0, 214.0, 0.7), (144.0, 302.0, 1.1))


def build_wk_ironwork(rng):
    """THE GROUND TACKLE, and the whole reason this shoal is called a
    careenage: four admiralty anchors half swallowed in the awash flat with
    their chain runs snaking off into the fleet. Ships were hove down here, and
    this is the gear it takes.

    It is also the entire prop budget of the redesign. The old build had this
    plus a capstan on the lane's centreline, a haul chain running the full
    length of the arena, thirteen scatters of barrels and crates at r 64-78 and
    the cradle they belonged to. Every one of those stood in the play area;
    what survives is the four pieces that never did. Deco, so nothing here is
    stood on or cast at, and merged with the chains into ONE object - they were
    always the same verdigris iron on the same material."""
    bm = bmesh.new()
    for radius, degrees, tilt in WK_ANCHORS:
        angle = math.radians(degrees)
        cx, cy = math.cos(angle) * radius, math.sin(angle) * radius
        # Bigger than the old rim anchors: read at 140 studs, not at 70.
        size = rng.uniform(9.5, 12.5)
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
        # The chain run, OUTWARD into the fleet. Outward is the whole rule: a
        # cable led inboard would lie across the floor, which is the one thing
        # this pass exists to stop.
        sweep = angle + rng.uniform(-0.45, 0.45)
        end = Vector((math.cos(sweep) * 158.0, math.sin(sweep) * 158.0, 0.0))
        start = Vector((cx, cy, 0.0))
        _wr_chain(
            bm,
            Vector((start.x, start.y, _wk_ground(start.x, start.y) + 1.4)),
            Vector((end.x, end.y, _wk_ground(end.x, end.y) + 1.2)),
            18,
            0.85,
            sag=0.9,
        )
    return _wr_finish("WrackArena_DecoIronwork", bm, WK_IRON, "M_Wrack_Iron")


def build_wk_tideline(rng):
    """Tide wrack: weed, rope and shell left at the WATER'S EDGE.

    On a beach the high-water line is a contour, not a circle - so this is an
    arc across the seaward third of the rim, thinning to nothing toward the
    sides and absent altogether at the head, where the sand is four studs above
    the sea and the tide has never reached. It is 0.16 studs tall, it is Deco,
    and it is the one thing on this arena that tells a player at a glance which
    way is downhill and where the mouth is. The old build ringed the whole
    circle with it and dragged strands 20 studs up into the play area; both are
    gone."""
    bm = bmesh.new()
    sea = math.radians(WK_SEA_DEG)
    for _ in range(96):
        # Bearings clustered on the mouth: a cosine-weighted draw, so density
        # falls away from the water's edge instead of stopping at a hard end.
        off = (rng.random() + rng.random() + rng.random() - 1.5) * 1.55
        if abs(off) > math.radians(88.0):
            continue
        angle = sea + off
        radius = WK_SAND_R - 2.0 + rng.uniform(0.0, 9.0) + math.cos(off) * 1.5
        x, y = math.cos(angle) * radius, math.sin(angle) * radius
        length = rng.uniform(2.2, 5.0)
        rock(
            bm,
            (x, y, _wk_ground(x, y) + 0.08),
            (length, length * rng.uniform(0.24, 0.42), 0.16),
            rng,
            jitter=0.3,
        )
    return _wr_finish("WrackArena_DecoTideline", bm, WK_WEED, "M_Wrack_Weed")


def build_wk_ghost_glow(ships, rng):
    """The ghost fleet's own sea-fire, and the only light in the arena: drawn
    along the gunwales of every third hull in the palisade, knotted in their
    open sockets, and a few lamps guttering out over the awash flat.

    ALL OF IT AT THE BOUNDARY. The old build hung lamps under the cradle
    arches, in the six hulks and drifting over the open flat, which put light
    sources in the middle of the fight floor; the wreckage they belonged to is
    gone and so are they.

    Named `...Glow` on the OBJECT, which is the contract BossArenaService reads
    to make it Neon (GLOW_MARKERS): the old `GhostFire`/`GhostLamp` names only
    worked through that list's grandfathered entries."""
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
    # A handful drifting low over the drowned flat, out among the hulls.
    for _ in range(16):
        angle = rng.uniform(0, TAU)
        radius = rng.uniform(WK_FLEET_R[0] - 4.0, WK_FOAM_R[0])
        x, y = math.cos(angle) * radius, math.sin(angle) * radius
        rock(bm, (x, y, _wk_ground(x, y) + rng.uniform(2.0, 7.0)), (0.85,) * 3, rng, jitter=0.08)
    return _wr_finish("WrackArena_DecoGhostGlow", bm, WK_GHOST, "M_Wrack_Glow")


def build_wk_foam(rng):
    bm = bmesh.new()
    # Surf ring outside the grounded fleet. Named *_Foam so OceanController
    # lifts it on the tide - and so the service strips its collision.
    angles = 56
    inner, outer = [], []
    for i in range(angles):
        angle = (i / angles) * TAU
        r0 = WK_FOAM_R[0] + rng.uniform(-1.4, 1.4)
        r1 = WK_FOAM_R[1] + rng.uniform(-1.8, 1.8)
        inner.append(bm.verts.new((math.cos(angle) * r0, math.sin(angle) * r0, 0.28)))
        outer.append(bm.verts.new((math.cos(angle) * r1, math.sin(angle) * r1, 0.22)))
    for i in range(angles):
        j = (i + 1) % angles
        bm.faces.new((inner[i], outer[i], outer[j], inner[j]))
    bmesh.ops.solidify(bm, geom=list(bm.faces) + list(bm.verts) + list(bm.edges), thickness=0.25)
    return _wr_finish("WrackArena_Foam", bm, WK_FOAM, "M_Wrack_Foam")


# ------------------------------------------------- wrack: the clearance check


def _wk_clearance(objects):
    """MEASURE the empty floor rather than assert it.

    "No obstacles inside the walkable radius" is the brief, and it is a claim
    about geometry nobody drew on purpose - which is exactly the kind that
    survives review and fails in play, because the thing that breaks it is
    never the object you were thinking about. The palisade's masts lean inward
    by design and its driven bows rear inward; whether either reaches down into
    the arena is a question about numbers that only the built mesh can answer.

    So: every COLLIDABLE object except the floor itself, every vertex, and the
    two numbers that decide it - how far in anything solid comes below
    headroom, and how low anything solid hangs inside the rim."""
    worst_r, worst_r_of = None, None
    worst_z, worst_z_of = None, None
    for obj in objects:
        name = obj.name
        if name.endswith("_Base"):
            continue
        if "Deco" in name or "Foam" in name:
            continue
        for vert in obj.data.vertices:
            x, y, z = vert.co
            r = math.hypot(x, y)
            if z < WK_HEADROOM and (worst_r is None or r < worst_r):
                worst_r, worst_r_of = r, name
            if r < WK_SAND_R and (worst_z is None or z < worst_z):
                worst_z, worst_z_of = z, name
    return worst_r, worst_r_of, worst_z, worst_z_of


def build_wrack():
    rng = random.Random(8317)
    ships = _wk_fleet(rng)
    objects = [
        build_wk_base(rng),
        build_wk_shallows(rng),
        build_wk_fleet(ships, rng),
        build_wk_fleet_ribs(ships, rng),
        build_wk_fleet_masts(ships, rng),
        build_wk_sails(ships, rng),
        build_wk_ironwork(rng),
        build_wk_tideline(rng),
        build_wk_ghost_glow(ships, rng),
        build_wk_foam(rng),
    ]

    # The floor, measured on the fall line and on the two beam bearings.
    sea = math.radians(WK_SEA_DEG)
    head = math.radians(WK_HEAD_DEG)
    sea_z = _wk_ground(math.cos(sea) * WK_SAND_R, math.sin(sea) * WK_SAND_R)
    head_z = _wk_ground(math.cos(head) * WK_SAND_R, math.sin(head) * WK_SAND_R)
    print(
        "HANDOFF wrack: WALKABLE SAND r 0-%.0f (was 78). Plain, unbroken, no props on it. "
        "Beach z %.2f at the water's edge (bearing %.0f) -> %.2f at the centre -> %.2f at the "
        "head (bearing %.0f); max grade %.1f%%. MIN WALKABLE z %.2f, MAX %.2f - both above the "
        "waterline, which is the whole rule (BossArenaService.verifyWaterline)."
        % (
            WK_SAND_R,
            sea_z,
            WK_SEA_DEG,
            WK_CENTRE_Z,
            head_z,
            WK_HEAD_DEG,
            100.0 * (WK_HEAD_Z - WK_SEA_Z) * WK_BEACH_P / (2.0 * WK_SAND_R),
            min(sea_z, head_z),
            max(sea_z, head_z),
        )
    )
    print(
        "HANDOFF wrack: boundary PALISADE r %.0f-%.0f MEASURED (%.0f-%.0f before the clearance "
        "guard pushed the low ones out), %d grounded hulls, ring open %.0f deg at bearing %.0f "
        "(the mouth: lowest ground, tide wrack, and the way in)"
        % (
            min(s["radius"] for s in ships),
            max(s["radius"] for s in ships),
            WK_FLEET_R[0],
            WK_FLEET_R[1],
            len(ships),
            WK_FLEET_GAP_DEG,
            WK_SEA_DEG,
        )
    )
    print(
        "HANDOFF wrack: foam ring r %.0f-%.0f (*_Foam: OceanController rides it), shoal rim r 172, "
        "four anchors at r %.0f-%.0f - ALL of it outside the walkable sand"
        % (WK_FOAM_R[0], WK_FOAM_R[1], min(a[0] for a in WK_ANCHORS), max(a[0] for a in WK_ANCHORS))
    )
    worst_r, worst_r_of, worst_z, worst_z_of = _wk_clearance(objects)
    if worst_r is None:
        print("HANDOFF wrack: CLEAR FLOOR - no collidable object other than _Base exists at all")
    else:
        verdict = "CLEAR" if (worst_r >= WK_SAND_R and (worst_z is None or worst_z >= WK_HEADROOM)) else "INTRUDES"
        print(
            "HANDOFF wrack: CLEAR FLOOR %s - nearest solid geometry below %.0f studs of headroom is "
            "r %.1f (%s); lowest solid geometry inside r %.0f is z %s (%s). Walkable sand ends at "
            "r %.0f."
            % (
                verdict,
                WK_HEADROOM,
                worst_r,
                worst_r_of,
                WK_SAND_R,
                "%.1f" % worst_z if worst_z is not None else "none",
                worst_z_of or "-",
                WK_SAND_R,
            )
        )
    print(
        "HANDOFF wrack: the boss lies ALONG the contours - beach falls toward bearing %.0f, which is "
        "where boss_gen heels him (masts over +y, scraped bottom and Keel battery under -y). Ground "
        "under his 47-stud beam: %.2f (bared side, uphill) to %.2f (mast side, downhill)."
        % (WK_SEA_DEG, _wk_beach(-24.0), _wk_beach(23.0))
    )
    print(
        "HANDOFF wrack: RETUNE PAID (Bosses.luau admiral_wrack, not this lane) - every ballistic row "
        "is now authored as (140 - spawnAt) / speed, so all nine reach 140-141 against a retire bound "
        "of 140 and this build's walkable sand at r %.0f. `aggro` is 165 (the sand plus the awash "
        "flat, so there is nowhere out here to stand and not be shot at) and `arena.radius` 80 (the "
        "party rings in at 88, forty studs clear of his hull). Nothing owed; re-check these if the "
        "sand's radius moves." % WK_SAND_R
    )
    return objects


# ---------------------------------------------------------------- rimefang

# Rimefang's lair is not a landform - it is a FLOE. A raft of sea ice adrift
# in the open ocean, shoved up into a pressure ridge all around its rim.
#
# v2 (2026-09-09, user brief: "the arena is too small for the fight. redesign
# the arena to make it easier for the user to focus more on the boss rather
# than trying to dodge the arena's obstacles"). The boss is a 56-stud whale
# that now leaps 70 studs and erupts through the ice; a r=70 sheet with two
# bergs, a whaler and a ribcage standing IN it left no room to read a
# telegraph, let alone walk away from one. So:
#
#   * ONE CLEAN DISC, walkable to r 120, DEAD FLAT (the profile is a
#     constant out to the ridge foot). The fight paints its holes, wash
#     lines and slam marks on it and nothing competes with them.
#   * NOTHING STANDS INSIDE r 120. Not a berg, not the wreck, not a bone,
#     not a drift. The drift ramps are gone entirely - they existed to climb
#     bergs that are no longer in the play area.
#   * relief is SASTRUGI ONLY, under half a stud, and it is sampled at ring
#     spacing ~10 studs so it actually survives into the mesh. The v1 floor
#     evaluated the same function at four profile radii inside r 70, which
#     aliased a 39-stud wave down to nothing: the floor claimed a texture it
#     did not have. Grain that fine is walked over, not dodged.
#   * the boundary is the pressure ridge at r 122-132, a RUBBLE BERM with a
#     crest 7.1-9.1 studs over the sheet and a crown of leaning plates on
#     top of that, taking the lip to 8.4-18.4 (raycast, 360 bearings) -
#     comfortably over a 7.2-stud jump, so it holds you in without being a
#     fence. Its inner face is steep (7 studs of rise in 3
#     of run) and every piece on it is seated analytically off
#     `_rf_ridge_top`: the first build guessed heights and blocks hung in
#     the air over the berm.
#   * the big soft forms (the bergs) stay SOFT - the user rejected a jagged
#     berg on Frostmaw and the same rule holds here: old ice is rounded,
#     colliding ice is not.
#   * the whaler, its ironwork and the whale bones are BACKDROP now, out on
#     the outer pack at r 146-165 beyond the ridge. They still say what
#     hunts here, and the harpoon still in the wreck's bow is still the twin
#     of the one in the boss's back - they just say it from outside the
#     fight instead of standing in the middle of it. Nothing out there needs
#     collision; nothing out there can be reached.
#
# Waterline is z = 0; the shelf floats ~2.6 studs proud of it.

RF_PROFILE = [
    # The fight floor is ONE HEIGHT, not a dome: v1 fell 0.38 studs from the
    # centre to r 70 and every telegraph drawn on it had to fight a slope.
    (0.0, 2.60),
    (120.0, 2.60),
    # The ridge foot, and then the outer pack the backdrop stands on - lower
    # and a touch rougher, so the fight floor reads as the raft's own table.
    (122.0, 2.55),
    (132.0, 2.45),
    (136.0, 2.10),
    (152.0, 1.95),
    (162.0, 1.80),
    # ...and the torn edge into the water, then the skirt.
    (166.0, 0.40),
    (170.0, -3.40),
    (173.0, -6.80),
    (176.0, SKIRT_BOTTOM),
]

RF_FLOOR_R = 120.0
RF_RIDGE_R = (122.0, 132.0)
RF_RIDGE_CREST_R = (125.0, 128.5)

# Ring radii the base is actually built on. THIS LIST IS THE RELIEF: the
# sastrugi function is only ever sampled here, so a floor tessellated at the
# profile's control points (v1: four rings inside r 70) cannot show a wave
# shorter than the gap between them however good the function is. ~10 studs
# inside the walkable disc, tightening across the ridge foot and the edge.
RF_RINGS = [6.0] + [10.0 * i for i in range(1, 13)] + [
    122.0, 125.0, 128.5, 132.0, 136.0, 144.0, 152.0, 162.0, 166.0, 170.0, 173.0, 176.0
]
RF_STEPS = 48

# BACKDROP, all of it outside the ridge (radius, degrees, top z above the
# floe). Nothing here is reachable and nothing here needs collision; it
# exists to give 240 studs of white a horizon and a story.
RF_BERGS = [(150.0, 62.0, 20.0), (158.0, 305.0, 16.0)]
RF_HULL = (152.0, 200.0)
RF_HULL_LEN = 38.0
RF_HULL_BEAM = 11.0
RF_HULL_DEPTH = 7.4

# Half-beam and depth as fractions, bow (0) to stern (1). Two builds used a
# symmetric sine for both and the hull read as a barrel from every angle:
# a boat needs a knife bow, its widest point AFT of midships, and a real
# transom. Tables, so the shape can be tuned without solving for it.
RF_HULL_PLAN = [(0.0, 0.04), (0.12, 0.30), (0.28, 0.62), (0.45, 0.82), (0.62, 0.92), (0.78, 0.86), (0.90, 0.70), (1.0, 0.56)]
RF_HULL_SECTION = [(0.0, 0.30), (0.15, 0.60), (0.35, 0.86), (0.60, 1.0), (0.85, 0.92), (1.0, 0.76)]
RF_BONES = (158.0, 142.0)

# Values matter more than hues here: white on white is what killed the first
# render. The floor is the DARKEST ice so the bergs, drifts and ridge all
# have something to read against.
RF_ICE = (0.60, 0.71, 0.81)
RF_DARKICE = (0.28, 0.42, 0.55)
RF_THIN = (0.34, 0.50, 0.62)
RF_RIDGE = (0.75, 0.83, 0.90)
RF_BERG = (0.84, 0.90, 0.95)
RF_SNOW = (0.97, 0.98, 1.0)
RF_WOOD = (0.31, 0.25, 0.20)
RF_IRON = (0.17, 0.19, 0.22)
RF_BONE = (0.76, 0.73, 0.63)
RF_FOAM = (0.96, 0.98, 0.98)


def _rf_height(r):
    for (r0, h0), (r1, h1) in zip(RF_PROFILE, RF_PROFILE[1:]):
        if r <= r1:
            t = 0 if r1 == r0 else (r - r0) / (r1 - r0)
            return h0 + (h1 - h0) * t
    return RF_PROFILE[-1][1]


def _rf_sastrugi(r, angle):
    """Wind-carved swells on the pack ice - the fight floor's only relief.

    Held to 0.42 studs peak on purpose. The floor is a clean canvas for the
    fight's telegraphs and a 240-stud white disc reads as nothing without
    grain in it, but grain you can trip on is an obstacle, and this arena's
    whole brief is that the obstacles are the boss's.

    Three harmonics, chosen against RF_RINGS/RF_STEPS rather than for their
    own sake: the radial terms turn over in ~45 and ~70 studs against a
    10-stud ring pitch, the angular ones in 3, 7 and 11 lobes against 48
    samples. v1's 39-stud radial wave sampled at 4 radii aliased to a flat
    sheet - the relief was in the source and never in the mesh.
    """
    if r > RF_FLOOR_R:
        return 0.0
    # Fade at both ends: no cone at the pole, and a clean meeting with the
    # ridge foot so the boundary is one form and not a seam.
    fade = min(1.0, r / 9.0) * min(1.0, (RF_FLOOR_R + 1.0 - r) / 8.0)
    return fade * (
        0.26 * math.sin(angle * 3.0 + r * 0.14)
        + 0.10 * math.sin(angle * 7.0 - r * 0.09)
        + 0.06 * math.sin(angle * 11.0 + r * 0.22)
    )


def _rf_ground(x, y):
    r = math.hypot(x, y)
    return _rf_height(r) + _rf_sastrugi(r, math.atan2(y, x))


def _rf_crest(angle):
    """Height of the pressure ridge berm at a bearing, over the ice under it.

    Two low harmonics only, and a MEAN THAT CLEARS A JUMP. The berm alone
    runs 7.1-9.1 studs over the sheet and the plate crown on top of it takes
    the lip to 8.4-18.4 (raycast, 360 bearings), so the ridge holds the fight
    in without a barrier part doing it invisibly. The mean was 7.6 for one
    build and the crown's lowest bearing measured 7.68 - over a 7.2-stud jump
    by half a stud, which is not a boundary, it is a coin toss. A fourth harmonic at 11x sawed the crest up and down
    between neighbouring blocks in an early build, which is a good part of
    why the ridge read as scattered noise rather than one ice form.
    """
    return 8.2 + 0.6 * math.sin(angle * 2.0 + 0.7) + 0.4 * math.sin(angle * 3.0 + 2.1)


def _rf_ridge_top(r, angle):
    """The ridge berm's top surface - an actual function of position.

    This exists so NOTHING built on the ridge can float: every block and
    plate is seated by asking this how high the ice is under it, instead of
    being placed at a guessed height above the floe. The first build guessed,
    and blocks ended up hanging in the air over the berm and out past the
    floe's edge.

    ASYMMETRIC on purpose: the inner face climbs the full crest in 3 studs
    of run (~68 degrees) so the arena side is a wall of rubble, while the
    seaward side feathers out over 3.5 for 10 studs so the whole thing still
    reads as shoved ice from the approach shot.
    """
    lo, hi = RF_RIDGE_R
    top_lo, top_hi = RF_RIDGE_CREST_R
    if r <= lo or r >= hi:
        return _rf_height(r)
    if r < top_lo:
        shape = ((r - lo) / (top_lo - lo)) ** 0.55
    elif r <= top_hi:
        shape = 1.0
    else:
        t = (r - top_hi) / (hi - top_hi)
        shape = 1.0 - t * t
    return _rf_height(r) + _rf_crest(angle) * shape


def _rf_seat(bm, x, y, size, rot, surface, embed=1.6):
    """Place a box so its LOWEST CORNER is buried, whatever its attitude.

    A tilted box positioned by its centre height lifts off the ground by an
    amount that depends on the rotation - which is exactly how ice ended up
    floating over the ridge. Projecting the three half-axes onto world Z
    gives the true overhang, so the piece is seated no matter how it is
    turned.
    """
    half = Vector(size) / 2
    drop = sum(
        abs((rot @ axis).z)
        for axis in (Vector((half.x, 0, 0)), Vector((0, half.y, 0)), Vector((0, 0, half.z)))
    )
    box(bm, (x, y, surface(x, y) - embed + drop), size, rot)


# ---- the floe as SHARDS (v3, 2026-09-12) -----------------------------------
#
# user brief: "dont make them squares make them actual like holes in the ice
# they should look like realistic holes that are like shattered like how ice
# would actually shatter."
#
# The fight now SINKS AND REFREEZES the floor, and a Roblox mesh cannot change
# at runtime, so the walkable disc stops being one object: it is a set of
# SEPARATE shards the game toggles one at a time (`RimefangArena_ShardNN`, and
# src/Shared/Config/RimefangFloe.luau is the map the server reads them by).
#
# What makes them read as shattered ice rather than as tiles is three things,
# and all three are structural rather than decorative:
#
#   * a VORONOI partition off jittered seed rings, not a grid. No two cells
#     share an area, an edge count or an aspect, and the seeds tighten toward
#     the middle so the break pattern gets finer near the hole, the way ice
#     does around a blow.
#   * every shared fracture line is JAGGED, and jagged THE SAME WAY in both
#     shards that own it: the notch profile is a function of position along
#     that pair's own bisector, seeded on the unordered pair. The two outlines
#     therefore INTERLOCK, and each side retreats half the crack width from
#     the same wandering line, so the gap stays even along it. Two outlines
#     jittered independently cannot do that - their gap pinches shut in some
#     places and yawns in others, which is the tell that says "two meshes"
#     rather than "one sheet that broke".
#   * the displacement TAPERS TO ZERO at both ends of every edge, because both
#     ends are TRIPLE JUNCTIONS shared with a third shard. Jag a junction and
#     three outlines tear apart at the corner and leave a triangular hole no
#     rule about crack width can close.
#
# The cracks are 0.4-0.8 studs of daylight and `RimefangArena_Water` is a dark
# plate 1.2 studs under the ice, so that daylight IS water: the fracture read
# is geometry and a dark value, with no texture and no decal anywhere in it.
# The same plate is what an open shard exposes when the fight sinks one.
RF_HOLE_R = 14.6
RF_WATER_R = 125.0
RF_WATER_DROP = 1.2
RF_CRACK = (0.4, 0.8)
# (seed radius, seed count, phase) per concentric ring of Voronoi sites. The
# ring a SEED sits on is not the ring index the shard is reported with - that
# is measured off the finished outlines (does it touch the hole, does it touch
# the rim) - but four seed rings is what puts rings 0..3 one band apart.
RF_SHARD_SEEDS = [(22.0, 9, 0.00), (52.0, 11, 0.31), (82.0, 11, 0.17), (108.0, 12, 0.53)]
RF_SHARD_THICK = (2.6, 3.4)
# Max vertical departure from the shard's own centroid plane, in studs. The
# tilt is a LOOK - no two shards lying at quite the same attitude - and it is
# capped rather than given in degrees because what matters is the STEP at the
# crack, which is the sum of two shards' deviations. Rim shards are held far
# flatter: they butt onto `_Base`'s annulus at r 120 under the ridge foot, and
# a lip there is a lip at the one place the fight is pushed into.
RF_SHARD_DEV = 0.30
RF_SHARD_DEV_RIM = 0.10
RF_WATER = (0.07, 0.13, 0.19)


def _rf_clip(poly, nx, ny, c, tag):
    """Sutherland-Hodgman against the half-plane nx*x + ny*y <= c.

    Each vertex carries the tag of the edge LEAVING it, so a finished cell
    knows which of its edges is a fracture line (and whose), which is the
    breathing hole and which is the floe's own rim. The three get completely
    different treatment afterwards and nothing else can tell them apart: by
    the time the polygon exists, a rim arc and a crack are both just edges.
    """
    out = []
    count = len(poly)
    for index in range(count):
        ax, ay, atag = poly[index]
        bx, by, _ = poly[(index + 1) % count]
        da = nx * ax + ny * ay - c
        db = nx * bx + ny * by - c
        if da <= 0.0:
            out.append((ax, ay, atag))
            if db > 0.0:
                t = da / (da - db)
                out.append((ax + (bx - ax) * t, ay + (by - ay) * t, tag))
        elif db <= 0.0:
            t = da / (da - db)
            out.append((ax + (bx - ax) * t, ay + (by - ay) * t, atag))
    return out


def _rf_seeds(rng):
    """The Voronoi sites, ordered ring by ring and bearing by bearing.

    Jitter is deliberately under a quarter of the angular step and under five
    studs radially: push it further and two seeds pair up into a sliver cell,
    which is the one shape on this floor that cannot be stood on and the one
    the fight must never be asked to sink.
    """
    seeds = []
    for radius, count, phase in RF_SHARD_SEEDS:
        step = TAU / count
        for index in range(count):
            angle = (index + phase) * step + rng.uniform(-0.24, 0.24) * step
            r = radius + rng.uniform(-4.5, 4.5)
            seeds.append((math.cos(angle) * r, math.sin(angle) * r))
    return seeds


def _rf_crack_gap(i, j):
    """Crack width for one pair, from the UNORDERED pair alone.

    Both shards have to retreat the same half-width from their shared line or
    the gap is not a gap, so this cannot be drawn from either shard's own rng.
    """
    rnd = random.Random("rf-crack-%d-%d" % (min(i, j), max(i, j)))
    return rnd.uniform(*RF_CRACK)


def _rf_jag(key, length, scale=1.0, bias=0.0):
    """One fracture line's wander, as (profile(t), interior sample stops).

    Seeded on the LINE rather than on either shard, which is the whole trick:
    both owners of a crack call this with the same key and get the identical
    displacement, so their outlines interlock.

    Two harmonics for the wander plus two or three NOTCHES - short triangular
    spikes, which is what actually sells ice: a smooth sine wander reads as a
    torn paper edge, and the thing that says "this was brittle and it snapped"
    is a corner. The envelope `sin(pi t)^0.6` is what holds the triple
    junctions still.
    """
    rnd = random.Random(key)
    f1, p1 = rnd.uniform(1.3, 2.7), rnd.uniform(0.0, TAU)
    f2, p2 = rnd.uniform(3.4, 5.6), rnd.uniform(0.0, TAU)
    notches = []
    for _ in range(rnd.choice((2, 2, 3))):
        notches.append(
            (rnd.uniform(0.17, 0.83), rnd.uniform(0.035, 0.085), rnd.uniform(0.8, 1.9) * rnd.choice((-1.0, 1.0)))
        )
    # Amplitude with the line's own length: a 2-stud notch on a 9-stud edge is
    # not a fracture, it is a self-intersection waiting to happen.
    gain = scale * min(1.0, length / 26.0)

    def profile(t):
        value = 0.52 * math.sin(TAU * f1 * t + p1) + 0.28 * math.sin(TAU * f2 * t + p2)
        for at, half, amp in notches:
            away = abs(t - at)
            if away < half:
                value += amp * (1.0 - away / half)
        return (value * gain + bias) * math.sin(math.pi * min(1.0, max(0.0, t))) ** 0.6

    # Sample where the shape IS: every notch's two feet and its peak, plus an
    # even ~2.6-stud walk for the wander. A uniform sample fine enough to
    # catch a 0.05-wide notch would carry ten times the vertices.
    walk = max(7, int(length / 2.6))
    stops = {index / walk for index in range(1, walk)}
    for at, half, _ in notches:
        stops.update(value for value in (at - half, at, at + half) if 0.0 < value < 1.0)
    return profile, sorted(stops)


def _rf_fracture(cell, seeds, owner):
    """Turn one clipped cell into its finished jagged outline (xy only)."""
    points = []
    count = len(cell)
    for index in range(count):
        ax, ay, tag = cell[index]
        bx, by, _ = cell[(index + 1) % count]
        points.append((ax, ay))
        kind = tag[0]
        if kind == "rim":
            continue
        if kind == "crack":
            low, high = tag[1], tag[2]
            sx, sy = seeds[high][0] - seeds[low][0], seeds[high][1] - seeds[low][1]
            span = math.hypot(sx, sy)
            nx, ny = sx / span, sy / span
            key = "rf-jag-%d-%d" % (low, high)
            scale, bias = 1.0, 0.0
        else:
            # The hole. Its normal is the owner's own bearing, flipped: the
            # cell was clipped by the tangent at RF_HOLE_R facing the middle.
            ox, oy = seeds[owner]
            span = math.hypot(ox, oy)
            nx, ny = -ox / span, -oy / span
            key = "rf-hole-%d" % owner
            # Biased OUTWARD (along -n), so the wander opens the hole more
            # often than it closes it: the hole is the boss's own breathing
            # space and a mechanic reads its radius.
            scale, bias = 0.75, -0.45
        ux, uy = -ny, nx
        sa = ax * ux + ay * uy
        sb = bx * ux + by * uy
        offset = ax * nx + ay * ny
        low_s, high_s = min(sa, sb), max(sa, sb)
        length = high_s - low_s
        if length < 1.2:
            continue
        profile, stops = _rf_jag(key, length, scale, bias)
        # `t` is always canonical - measured from the LOW end of the line in
        # the pair's own frame - which is what makes the two owners of a crack
        # agree about it. Only the walking ORDER is the cell's own.
        for t in (stops if sa <= sb else list(reversed(stops))):
            s = low_s + t * length
            push = offset + profile(t)
            points.append((ux * s + nx * push, uy * s + ny * push))
    return points


def _rf_area(poly):
    total = 0.0
    for index in range(len(poly)):
        x0, y0 = poly[index]
        x1, y1 = poly[(index + 1) % len(poly)]
        total += x0 * y1 - x1 * y0
    return total / 2.0


def _rf_centroid(poly):
    area = _rf_area(poly)
    if abs(area) < 1e-9:
        return (sum(p[0] for p in poly) / len(poly), sum(p[1] for p in poly) / len(poly))
    cx = cy = 0.0
    for index in range(len(poly)):
        x0, y0 = poly[index]
        x1, y1 = poly[(index + 1) % len(poly)]
        cross = x0 * y1 - x1 * y0
        cx += (x0 + x1) * cross
        cy += (y0 + y1) * cross
    return (cx / (6.0 * area), cy / (6.0 * area))


def _rf_inside(poly, x, y):
    inside = False
    for index in range(len(poly)):
        x0, y0 = poly[index]
        x1, y1 = poly[(index + 1) % len(poly)]
        if (y0 > y) != (y1 > y):
            if x < x0 + (y - y0) / (y1 - y0) * (x1 - x0):
                inside = not inside
    return inside


def _rf_dedupe(poly, eps=0.02):
    out = []
    for point in poly:
        if not out or math.hypot(point[0] - out[-1][0], point[1] - out[-1][1]) > eps:
            out.append(point)
    while len(out) > 2 and math.hypot(out[0][0] - out[-1][0], out[0][1] - out[-1][1]) <= eps:
        out.pop()
    return out


def _rf_shards(rng):
    """The whole fracture: seeds -> clipped cells -> jagged outlines -> shards.

    Returns a list of dicts, ordered so shard 01 is the innermost/first
    bearing and the numbering walks out ring by ring. THE ORDER IS A
    CONTRACT: `RimefangFloe.luau` and `RimefangArena_ShardNN` are keyed on it,
    so a change here renumbers the floor under the server.
    """
    seeds = _rf_seeds(rng)
    # The disc, as a clip polygon - and it is `RF_STEPS` segments on `RF_STEPS`
    # bearings because that is EXACTLY the ring `build_rf_base` starts its
    # annulus on. Any other tessellation leaves a ragged seam at r 120: a
    # 120-segment shard rim against a 48-segment annulus disagrees by the
    # annulus's own sagitta, a quarter of a stud, and the first diagnostic
    # render of this floor had a ring of hairline water slivers all the way
    # round the rim where the two polygons missed each other. The shards and
    # the annulus have to be cut on the same circle, not on the same radius.
    disc = [
        (math.cos(i / RF_STEPS * TAU) * RF_FLOOR_R, math.sin(i / RF_STEPS * TAU) * RF_FLOOR_R, ("rim",))
        for i in range(RF_STEPS)
    ]
    raw = []
    for index, (sx, sy) in enumerate(seeds):
        cell = disc
        for other, (ox, oy) in enumerate(seeds):
            if other == index:
                continue
            dx, dy = ox - sx, oy - sy
            span = math.hypot(dx, dy)
            if span < 1e-6:
                continue
            dx, dy = dx / span, dy / span
            mid = (dx * (sx + ox) + dy * (sy + oy)) / 2.0
            cell = _rf_clip(cell, dx, dy, mid - _rf_crack_gap(index, other) / 2.0, ("crack", min(index, other), max(index, other)))
            if len(cell) < 3:
                break
        if len(cell) >= 3 and math.hypot(sx, sy) < RF_HOLE_R + 26.0:
            # The breathing hole, cut as ONE TANGENT PLANE per surrounding
            # shard rather than as a circle. That is not an approximation of a
            # circle - it is the better shape: nine straight cuts at nine
            # bearings leave an irregular nine-sided opening, and a hole
            # punched through brittle ice is a polygon, not a drill bit.
            span = math.hypot(sx, sy)
            cell = _rf_clip(cell, -sx / span, -sy / span, -RF_HOLE_R, ("hole",))
        raw.append(cell if len(cell) >= 3 else [])

    shards = []
    for index, cell in enumerate(raw):
        if not cell:
            continue
        outline = _rf_dedupe(_rf_fracture(cell, seeds, index))
        if len(outline) < 3 or abs(_rf_area(outline)) < 40.0:
            continue
        if _rf_area(outline) < 0:
            outline.reverse()
        kinds = {tag[0] for _, _, tag in cell}
        neighbours = sorted({tag[2] if tag[1] == index else tag[1] for _, _, tag in cell if tag[0] == "crack"})
        shards.append(
            {
                "seed": index,
                "outline": outline,
                "centroid": _rf_centroid(outline),
                "area": abs(_rf_area(outline)),
                "hole": "hole" in kinds,
                "rim": "rim" in kinds,
                "seed_neighbours": neighbours,
            }
        )

    # RING INDEX, measured rather than assumed: 0 touches the hole, 3 touches
    # the rim, and 1-2 are hops out from the hole across the neighbour graph.
    # Taking it from the seed ring instead would be a claim about the seeds;
    # this is a statement about the finished outlines, which is what the fight
    # walks on and what "the ring next to the hole collapses first" means.
    by_seed = {shard["seed"]: shard for shard in shards}
    frontier = [shard["seed"] for shard in shards if shard["hole"]]
    hops = {seed: 0 for seed in frontier}
    while frontier:
        nxt = []
        for seed in frontier:
            for other in by_seed[seed]["seed_neighbours"]:
                if other in by_seed and other not in hops:
                    hops[other] = hops[seed] + 1
                    nxt.append(other)
        frontier = nxt
    for shard in shards:
        shard["ring"] = 3 if shard["rim"] else min(2, max(1, hops.get(shard["seed"], 1))) if not shard["hole"] else 0

    # The numbering: ring, then bearing. Stable under a re-export because the
    # seeds are, and legible in a preview, which matters when the acceptance
    # test for this whole pass is a human looking at a plan view.
    shards.sort(key=lambda s: (s["ring"], math.atan2(s["centroid"][1], s["centroid"][0])))
    ids = {}
    for number, shard in enumerate(shards, start=1):
        shard["id"] = number
        shard["name"] = "RimefangArena_Shard%02d" % number
        ids[shard["seed"]] = number
    for shard in shards:
        shard["neighbours"] = sorted(ids[seed] for seed in shard["seed_neighbours"] if seed in ids)

    # Attitude: a thickness and a tilt per shard, neither shared with any
    # other. Seeded on the shard's NUMBER so the floor is stable across runs.
    for shard in shards:
        rnd = random.Random("rf-shard-%d" % shard["id"])
        cx, cy = shard["centroid"]
        shard["thick"] = rnd.uniform(*RF_SHARD_THICK)
        # Half the sastrugi, and faded out again over the last 26 studs. The
        # floe keeps the wind grain the v2 brief gave it - expressed now as
        # forty faceted planes rather than one rippled sheet, which is how pack
        # ice actually reads - but a rim shard has to meet the annulus at r 120
        # FLUSH, and the annulus is still sampled off the raw function. Without
        # the fade that mismatch is a third of a stud of lip, at the one place
        # on this floor the ridge pushes the fight into.
        reach_r = math.hypot(cx, cy)
        shard["top"] = RF_PROFILE[0][1] + 0.5 * _rf_sastrugi(reach_r, math.atan2(cy, cx)) * min(
            1.0, (RF_FLOOR_R - reach_r) / 26.0
        )
        bearing = rnd.uniform(0.0, TAU)
        reach = max(math.hypot(x - cx, y - cy) for x, y in shard["outline"])
        cap = RF_SHARD_DEV_RIM if shard["ring"] == 3 else RF_SHARD_DEV
        slope = min(math.tan(math.radians(1.5)), cap / max(reach, 1.0))
        shard["slope"] = (math.cos(bearing) * slope, math.sin(bearing) * slope)
    return shards


def _rf_shard_z(shard, x, y):
    cx, cy = shard["centroid"]
    gx, gy = shard["slope"]
    return shard["top"] + gx * (x - cx) + gy * (y - cy)


def _rf_shard_at(shards, x, y):
    """The shard under a point, or None if the point is over a crack or the
    hole. Used to SEAT the flush dressing: a lead or a thin-ice patch laid on
    the old sheet's height floats over one shard and is buried in the next."""
    for shard in shards:
        if _rf_inside(shard["outline"], x, y):
            return shard
    return None


def build_rf_shards(shards):
    objects = []
    for shard in shards:
        cx, cy = shard["centroid"]
        top = shard["top"]
        bm = bmesh.new()
        # LOCAL coordinates, with the object's origin at the shard's own
        # centroid at floe-top height. That origin is the contract with the
        # fight: sinking a shard is a tween down its own axis, and an origin
        # at the arena centre (which is what a shared mesh gives you) makes
        # every one of forty-odd tweens a different offset to get wrong.
        upper = [bm.verts.new((x - cx, y - cy, _rf_shard_z(shard, x, y) - top)) for x, y in shard["outline"]]
        lower = [bm.verts.new((x - cx, y - cy, _rf_shard_z(shard, x, y) - top - shard["thick"])) for x, y in shard["outline"]]
        hub_up = bm.verts.new((0.0, 0.0, 0.0))
        hub_down = bm.verts.new((0.0, 0.0, -shard["thick"]))
        count = len(upper)
        for index in range(count):
            j = (index + 1) % count
            bm.faces.new((hub_up, upper[index], upper[j]))
            bm.faces.new((hub_down, lower[j], lower[index]))
            bm.faces.new((upper[index], lower[index], lower[j], upper[j]))
        obj = finish(shard["name"], bm, RF_ICE)
        obj.location = (cx, cy, top)
        objects.append(obj)
    return objects


def build_rf_water(rng):
    """The dark plate under the ice - the thing the cracks SHOW.

    One object, no collision needed (the game makes it a non-collidable chill
    surface), and 1.2 studs down: deep enough that a 0.6-stud crack reads as a
    slot of black rather than as a seam, shallow enough that a sunk shard does
    not look like it fell off the world.
    """
    bm = bmesh.new()
    top = RF_PROFILE[0][1] - RF_WATER_DROP
    steps = 96
    rim = []
    for index in range(steps):
        angle = (index / steps) * TAU
        r = RF_WATER_R + rng.uniform(-0.6, 0.6)
        rim.append(bm.verts.new((math.cos(angle) * r, math.sin(angle) * r, top)))
    floor = [bm.verts.new((v.co.x, v.co.y, top - 0.7)) for v in rim]
    hub_up = bm.verts.new((0.0, 0.0, top))
    hub_down = bm.verts.new((0.0, 0.0, top - 0.7))
    for index in range(steps):
        j = (index + 1) % steps
        bm.faces.new((hub_up, rim[index], rim[j]))
        bm.faces.new((hub_down, floor[j], floor[index]))
        bm.faces.new((rim[index], floor[index], floor[j], rim[j]))
    return finish("RimefangArena_Water", bm, RF_WATER)


def build_rf_base(rng):
    """`_Base` is now the ANNULUS, r 120 out to the torn lip, plus the skirt.

    THE NAME STAYS, and not for sentiment. Three consumers look it up by
    exactly this string and none of them would fail loudly without it:
    `BossArenaService.arenaTemplate` finds the whole imported group by walking
    up from `<model>_Base`, `placeAuthored` anchors the arena on that part's XZ
    centre, and `tools/studio_import_bundles.lua` uses it as the pack's
    sentinel and as the frame every GEOMETRY row is measured against. Lose it
    and the authored floe is simply never found - the fight falls back to the
    procedural disc and plays, which is the worst possible symptom.

    So the annulus carries it, and that is the right piece to carry it rather
    than the largest shard: the name is used as an ANCHOR, and an annulus is
    centred on the arena's own axis while any one shard is 20-110 studs off
    it. Naming a shard `_Base` would have moved the whole arena by that much.
    Pyrelisk already split its `_Base` this way (an annulus plus `_LakeFloor`),
    so the shape of this answer is not new here.
    """
    bm = bmesh.new()
    angles = RF_STEPS
    grid = []
    for radius in [r for r in RF_RINGS if r >= RF_FLOOR_R]:
        ring = []
        for i in range(angles):
            angle = (i / angles) * TAU
            # The fight floor stays a true circle; only the torn lip and the
            # skirt under it wander, so the floe reads as a raft that broke
            # off something without making the walkable ground unpredictable.
            wobble = 1.0 + (rng.uniform(-0.05, 0.05) if radius > 166 else 0.0)
            r = radius * wobble
            z = _rf_height(radius) + _rf_sastrugi(radius, angle)
            ring.append(bm.verts.new((math.cos(angle) * r, math.sin(angle) * r, z)))
        grid.append(ring)
    for a, b in zip(grid, grid[1:]):
        for i in range(angles):
            j = (i + 1) % angles
            bm.faces.new((a[i], b[i], b[j], a[j]))
    # Close the underside so the raft reads solid from the water - and it is
    # this floor, not the shards, that is the model's bbox floor, so
    # `BossArenas.ice.meshBottom` is unchanged at -9.5.
    #
    # FLAT to r 120 and only then rising to the skirt, which is not how the old
    # one-piece base closed itself: that fanned a cone straight from the centre
    # up to the outer ring, and under a floor made of shards that cone is a
    # SHUTTER. It climbs back to the sheet height as it reaches r 120, so the
    # outermost 18 studs of every crack looked down onto pale ice instead of
    # onto `_Water` 1.2 studs below - the whole fracture read dying exactly
    # where the fight is pushed hardest, and dying silently, because from any
    # camera but a plan view it just looked like a crack that closed.
    inner = grid[0]
    outer = grid[-1]
    hub = bm.verts.new((0, 0, SKIRT_BOTTOM - 0.5))
    floor = [
        bm.verts.new((math.cos(i / angles * TAU) * RF_FLOOR_R, math.sin(i / angles * TAU) * RF_FLOOR_R, SKIRT_BOTTOM - 0.5))
        for i in range(angles)
    ]
    for i in range(angles):
        j = (i + 1) % angles
        bm.faces.new((hub, floor[j], floor[i]))
        bm.faces.new((floor[i], floor[j], outer[j], outer[i]))
        # ...and the inner face, straight down from r 120, so the annulus is a
        # closed solid rather than a ribbon with a hole in the middle of it.
        bm.faces.new((inner[j], inner[i], floor[i], floor[j]))
    return finish("RimefangArena_Base", bm, RF_ICE)


def _rf_lead_run(bm, run):
    """One unbroken span of a refrozen lead, seated on the shard it lies on."""
    if len(run) < 3:
        return
    rows = []
    for owner, rib in run:
        rows.append([bm.verts.new((sx, sy, _rf_shard_z(owner, sx, sy) + 0.06)) for _, sx, sy in rib])
    for index in range(len(rows) - 1):
        a, b = rows[index], rows[index + 1]
        bm.faces.new((a[0], a[1], b[1], b[0]))


def build_rf_leads(rng, shards):
    bm = bmesh.new()
    # Refrozen leads: OLD cracks, healed over in darker ice, radiating out of
    # the middle - the scars from the last time this raft broke, as against the
    # forty live cracks it is broken along now. They exist so the eye has scale
    # on the white and so the floe reads as something that breaks even before
    # the boss starts breaking it.
    #
    # Two rules, both learned off the first render of the shard floor. A lead
    # is laid on ONE SHARD's own tilted plane, because a ribbon laid at the old
    # sheet's single height floats over half the shards and is buried in the
    # other half. And a span is only built where BOTH its ends sit wholly on
    # that same shard, with at least three spans running together: a lead that
    # crosses a live crack leaves a stranded quad on the far side, which does
    # not read as a healed crack - it reads as litter on the ice.
    for lead in range(3):
        bearing = math.radians(28 + lead * 119) + rng.uniform(-0.2, 0.2)
        r = RF_HOLE_R + 5.0 + rng.uniform(0.0, 9.0)
        drift = 0.0
        ribs = []
        while r < RF_FLOOR_R - 8.0:
            drift += rng.uniform(-0.06, 0.06)
            angle = bearing + drift
            half = rng.uniform(1.3, 2.8)
            x, y = math.cos(angle) * r, math.sin(angle) * r
            nx, ny = -math.sin(angle), math.cos(angle)
            rib = []
            for sx, sy in ((x + nx * half, y + ny * half), (x - nx * half, y - ny * half)):
                rib.append((_rf_shard_at(shards, sx, sy), sx, sy))
            ribs.append(rib)
            r += rng.uniform(6.0, 9.0)
        run = []
        for index in range(len(ribs)):
            rib = ribs[index]
            owner = rib[0][0]
            if owner is not None and rib[1][0] is owner and (not run or run[-1][0] is owner):
                run.append((owner, rib))
                continue
            _rf_lead_run(bm, run)
            run = [(owner, rib)] if owner is not None and rib[1][0] is owner else []
        _rf_lead_run(bm, run)
    return finish("RimefangArena_Leads", bm, RF_DARKICE)


def build_rf_thinice(shards, picks):
    bm = bmesh.new()
    # Young ice, and as of v3 it is no longer a lobed blob laid wherever: each
    # patch IS one shard, inset a stud and a half and laid flush on that
    # shard's own plane. That is what makes the mechanic honest - "this patch
    # gives way" and "this shard sinks" are now the same object, and the
    # server gets the shard ids in `RimefangFloe.thinIce` instead of having to
    # match four measured hub positions against forty outlines at runtime.
    for shard in picks:
        cx, cy = shard["centroid"]
        reach = max(math.hypot(x - cx, y - cy) for x, y in shard["outline"])
        inset = max(0.75, 1.0 - 1.5 / reach)
        rim = [
            bm.verts.new(
                (
                    cx + (x - cx) * inset,
                    cy + (y - cy) * inset,
                    _rf_shard_z(shard, cx + (x - cx) * inset, cy + (y - cy) * inset) + 0.05,
                )
            )
            for x, y in shard["outline"]
        ]
        hub = bm.verts.new((cx, cy, _rf_shard_z(shard, cx, cy) + 0.05))
        for index in range(len(rim)):
            bm.faces.new((hub, rim[index], rim[(index + 1) % len(rim)]))
    return finish("RimefangArena_ThinIce", bm, RF_THIN)


def build_rf_ridge(rng):
    bm = bmesh.new()

    def surface(x, y):
        return _rf_ridge_top(math.hypot(x, y), math.atan2(y, x))

    # 1. The berm: one continuous wall of ice, lofted off _rf_ridge_top so the
    #    built form and the seating rule below can never disagree. Coarse and
    #    flat-shaded, with a low-frequency wobble on the slopes - a perfectly
    #    smooth cone reads as a snow bank, not as shoved ice.
    steps = 96
    lo, hi = RF_RIDGE_R
    rings = []
    for r in (lo, lo + 1.5, 125.0, 127.0, 128.5, 130.0, hi, hi):
        ring = []
        last = r == hi and len(rings) == 7
        for i in range(steps):
            angle = (i / steps) * TAU
            if last:
                z = _rf_height(r) - 0.4
            else:
                z = _rf_ridge_top(r, angle) + 0.30 * math.sin(angle * 9.0 + r * 0.7) + 0.18 * math.sin(angle * 17.0)
            ring.append(bm.verts.new((math.cos(angle) * r, math.sin(angle) * r, z)))
        rings.append(ring)
    for a, b in zip(rings, rings[1:]):
        for i in range(steps):
            j = (i + 1) % steps
            bm.faces.new((a[i], b[i], b[j], a[j]))

    # 2. The sails: one crown of big plates on the ridge line, tangential, all
    #    leaning the same way (inward, over the arena), and OVERLAPPING - at
    #    12-18 studs long on a 127-stud ring they run into their neighbours
    #    and form a continuous jagged wall instead of a row of separate teeth.
    #
    #    Height comes from _rf_crest, not from per-plate randomness: adjacent
    #    plates therefore share a height and the wall rises and falls in long
    #    waves around the ring. That is the difference between "uniform" and
    #    "evenly spaced" - three earlier builds randomised per plate and read
    #    as litter or as a fence. The crown is also what puts the lip out of
    #    jump range: the berm alone tops out at 8.6 over the sheet and a
    #    player clears 7.
    mid = (RF_RIDGE_CREST_R[0] + RF_RIDGE_CREST_R[1]) * 0.5
    # The crown sits on the OUTER half of the crest and its radial jitter is
    # one-sided outward. A plate leaning in over the arena puts its low edge
    # a couple of studs inside its own centre, and centred on the ridge line
    # that edge landed at r 118 - the boundary starting inside the disc the
    # config promises is clear.
    for count, radius, scale, embed in ((120, mid + 1.4, (0.70, 1.30), 1.9), (46, mid - 1.6, (0.34, 0.54), 0.9)):
        sheared = False
        for i in range(count):
            angle = (i / count) * TAU + rng.uniform(-0.06, 0.06)
            r = radius + rng.uniform(-0.8, 2.0)
            x, y = math.cos(angle) * r, math.sin(angle) * r
            rot = (
                Matrix.Rotation(angle + math.pi / 2 + rng.uniform(-0.30, 0.30), 3, "Z")
                @ Matrix.Rotation(rng.uniform(0.16, 0.44), 3, "X")
                @ Matrix.Rotation(rng.uniform(-0.14, 0.14), 3, "Y")
            )
            # One plate in six is a STUMP - a sail that sheared off. Without
            # them the crown's tops all follow _rf_crest exactly and the wall
            # reads as a row of dominoes from a player's eye height, which is
            # the one view of this ridge the fight actually gets.
            #
            # NEVER TWO IN A ROW, and plates are 15-22 studs long against a
            # 6.6-stud pitch. Both rules are containment, not looks: a stump
            # between two SHORT plates leaves a 6.8-stud step in the boundary,
            # and a player jumps 7. Measured by raycast round all 360
            # bearings, not by eye.
            stump = 0.55 if (rng.random() < 0.16 and not sheared) else 1.0
            sheared = stump < 1.0
            length, width = rng.uniform(15.0, 22.0), rng.uniform(2.4, 3.8)

            def plate_face(px, py, span=length * 0.5, thick=width * 0.5):
                """The lowest ice under this plate's own footprint.

                Seating a 22-stud plate on the height at its CENTRE leaves an
                end up to a third of a stud clear of the berm, because
                _rf_crest moves across the 10 degrees of bearing the plate
                covers. Sampling the footprint is what makes the floater
                check a real check rather than a statement about the middle.
                """
                bearing = math.atan2(py, px)
                here = math.hypot(px, py)
                swing = span / max(here, 1.0)
                return min(
                    _rf_ridge_top(here + step, bearing + turn)
                    for step in (-thick, 0.0, thick)
                    for turn in (-swing, 0.0, swing)
                )

            _rf_seat(
                bm,
                x,
                y,
                (length, width, _rf_crest(angle) * rng.uniform(*scale) * stump),
                rot,
                plate_face,
                embed=embed,
            )

    # 3. Tumbled rubble along both feet, at random yaw. The crown is the
    #    SHAPE of the boundary; this is what makes it read as ice that
    #    collided rather than as a palisade someone built. Seated through the
    #    same rule, so none of it can float either.
    for _ in range(110):
        angle = rng.uniform(0.0, TAU)
        inner = rng.random() < 0.5
        length, width, height = rng.uniform(4.5, 9.0), rng.uniform(3.0, 5.5), rng.uniform(2.2, 4.6)
        # A block's FOOTPRINT is what has to stay out of the play area, not
        # its centre: yawed freely, a 9-stud slab reaches 5 studs off its own
        # middle, and the first pass at this put ice down at r 117.6 - inside
        # the disc that BossArenas.ice.floorRadius promises is clear.
        reach = math.hypot(length, width) * 0.5
        r = (
            max(RF_RIDGE_R[0] + rng.uniform(0.4, 3.2), RF_FLOOR_R + 0.6 + reach)
            if inner
            else RF_RIDGE_R[1] - rng.uniform(0.4, 4.5)
        )
        x, y = math.cos(angle) * r, math.sin(angle) * r
        rot = (
            Matrix.Rotation(rng.uniform(0.0, TAU), 3, "Z")
            @ Matrix.Rotation(rng.uniform(-0.34, 0.34), 3, "X")
            @ Matrix.Rotation(rng.uniform(-0.34, 0.34), 3, "Y")
        )
        # Seated against the LOWEST ice its footprint covers. Asking the
        # centre alone left blocks on the seaward slope hanging over ground
        # that falls 5 studs under their far end - seated by the letter of
        # the rule and floating by the look of it.
        def footprint(px, py, reach=reach):
            bearing = math.atan2(py, px)
            here = math.hypot(px, py)
            swing = reach / max(here, 1.0)
            return min(
                _rf_ridge_top(here + step, bearing + turn)
                for step in (-reach, 0.0, reach)
                for turn in (-swing, 0.0, swing)
            )

        # embed 1.4, not 1.0: the crest also varies ALONG the ring, so a
        # block's corners find ice a little lower than any sample of its own
        # footprint. Cheaper to bury it the extra third of a stud than to
        # solve the corner positions exactly.
        _rf_seat(bm, x, y, (length, width, height), rot, footprint, embed=1.4)
    return finish("RimefangArena_Ridge", bm, RF_RIDGE)


def build_rf_bergs(rng):
    bm = bmesh.new()
    # Grounded bergs on the outer pack: big ROUNDED masses. Soft is the
    # Frostmaw ruling - the jagged berg was rejected, old ice is worn round -
    # and a slab-built version just read as more of the ridge's broken plate.
    # What keeps them from being domes is height and a flat cap, not facets.
    # Bigger than v1's because they are 150 studs away now and their whole
    # job is to be the thing the eye finds past the ridge.
    for radius, degrees, top in RF_BERGS:
        angle = math.radians(degrees)
        cx, cy = math.cos(angle) * radius, math.sin(angle) * radius
        ground = _rf_height(radius)
        # Seated so the mass does not hang below the raft's own skirt: the
        # model's bbox floor is what BossArenaService pins, and a berg that
        # reached deeper than the ice would quietly become that floor.
        rock(bm, (cx, cy, ground + top * 0.32), (17.6, 15.4, top * 0.70), rng, jitter=0.09)
        lean = rng.uniform(0, TAU)
        rock(
            bm,
            (cx + math.cos(lean) * 4.6, cy + math.sin(lean) * 4.6, ground + top * 0.60),
            (13.2, 11.5, top * 0.50),
            rng,
            jitter=0.09,
        )
        rock(
            bm,
            (cx - math.cos(lean) * 6.2, cy - math.sin(lean) * 6.2, ground + top * 0.30),
            (10.6, 9.5, top * 0.42),
            rng,
            jitter=0.09,
        )
        # A flat cap, and a tight melt collar where it sits in the floe. The
        # wide apron of the first build was what made these read as mounds on
        # a saucer.
        tapered_cylinder(bm, ground + top - 2.4, ground + top, 8.7, 7.6, sides=9, center=(cx, cy))
        tapered_cylinder(bm, ground - 1.0, ground + 0.9, 17.1, 15.4, sides=12, center=(cx, cy))
    return finish("RimefangArena_Bergs", bm, RF_BERG)


def _rf_lerp(table, t):
    for (t0, v0), (t1, v1) in zip(table, table[1:]):
        if t <= t1:
            k = 0.0 if t1 == t0 else (t - t0) / (t1 - t0)
            return v0 + (v1 - v0) * k
    return table[-1][1]


def _rf_hull_station(t):
    """Half-beam and depth down the whaler, bow (0) to stern (1)."""
    return RF_HULL_BEAM * 0.5 * _rf_lerp(RF_HULL_PLAN, t), RF_HULL_DEPTH * _rf_lerp(RF_HULL_SECTION, t)


def _rf_hull_frame():
    angle = math.radians(RF_HULL[1])
    cx, cy = math.cos(angle) * RF_HULL[0], math.sin(angle) * RF_HULL[0]
    # Sitting well up out of the floe and barely heeled. Earlier builds put it
    # down at 16-27 deg with the sheer in the snow, and it rendered as a rock
    # with two sticks in it - a wreck has to read as a BOAT first.
    origin = Vector((cx, cy, _rf_height(RF_HULL[0]) + 4.8))
    frame = (
        Matrix.Rotation(angle + math.radians(118), 4, "Z")
        @ Matrix.Rotation(math.radians(-4), 4, "Y")
        @ Matrix.Rotation(math.radians(11), 4, "X")
    )
    return origin, frame


def build_rf_hull(rng):
    bm = bmesh.new()
    origin, frame = _rf_hull_frame()
    stations = 13
    rings = []
    for i in range(stations):
        t = i / (stations - 1)
        half, depth = _rf_hull_station(t)
        x = (0.5 - t) * RF_HULL_LEN  # bow toward +x
        section = [
            (half, 3.0),
            (half * 0.96, -depth * 0.28),
            (half * 0.60, -depth * 0.78),
            (0.0, -depth),
            (-half * 0.60, -depth * 0.78),
            (-half * 0.96, -depth * 0.28),
            (-half, 3.0),
        ]
        rings.append([bm.verts.new(origin + frame @ Vector((x, y, z))) for (y, z) in section])
    for a, b in zip(rings, rings[1:]):
        for i in range(len(a) - 1):
            bm.faces.new((a[i], b[i], b[i + 1], a[i + 1]))
    # Transom: a flat face across the stern, not a point.
    stern = rings[-1]
    bm.faces.new(tuple(reversed(stern)) + (bm.verts.new(origin + frame @ Vector((-RF_HULL_LEN * 0.5, 0.0, 3.0))),))
    # Stem: the one line that says "bow" from any distance.
    taper_between(
        bm,
        origin + frame @ Vector((RF_HULL_LEN * 0.5, 0, -RF_HULL_DEPTH * 0.3)),
        origin + frame @ Vector((RF_HULL_LEN * 0.5 + 1.6, 0, 7.4)),
        1.0,
        0.45,
        sides=5,
    )
    taper_between(
        bm,
        origin + frame @ Vector((-RF_HULL_LEN * 0.5, 0, -1.8)),
        origin + frame @ Vector((-RF_HULL_LEN * 0.5 - 1.0, 0, 5.4)),
        1.0,
        0.6,
        sides=5,
    )
    # The sheer strake ONLY. Earlier builds ran three strakes a side and the
    # lower two wrapped the shell as hoops - the hull read as a barrel.
    for side in (-1, 1):
        for i in range(stations - 1):
            t0, t1 = i / (stations - 1), (i + 1) / (stations - 1)
            h0, _ = _rf_hull_station(t0)
            h1, _ = _rf_hull_station(t1)
            taper_between(
                bm,
                origin + frame @ Vector(((0.5 - t0) * RF_HULL_LEN, side * h0, 3.0)),
                origin + frame @ Vector(((0.5 - t1) * RF_HULL_LEN, side * h1, 3.0)),
                0.55,
                0.55,
                sides=5,
            )
    # A keel batten down the bottom - the line that reads from below the sheer.
    for i in range(stations - 1):
        t0, t1 = i / (stations - 1), (i + 1) / (stations - 1)
        _, d0 = _rf_hull_station(t0)
        _, d1 = _rf_hull_station(t1)
        taper_between(
            bm,
            origin + frame @ Vector(((0.5 - t0) * RF_HULL_LEN, 0, -d0 - 0.15)),
            origin + frame @ Vector(((0.5 - t1) * RF_HULL_LEN, 0, -d1 - 0.15)),
            0.5,
            0.5,
            sides=5,
        )
    # Thwarts across the open waist, and the frames left standing where the
    # deck went.
    for i in range(4):
        t = 0.34 + i * 0.12
        half, _ = _rf_hull_station(t)
        x = (0.5 - t) * RF_HULL_LEN
        taper_between(
            bm,
            origin + frame @ Vector((x, -half * 0.92, 2.5)),
            origin + frame @ Vector((x, half * 0.92, 2.5)),
            0.42,
            0.42,
            sides=4,
        )
    for i in range(6):
        t = 0.26 + i * 0.09
        half, _ = _rf_hull_station(t)
        x = (0.5 - t) * RF_HULL_LEN
        taper_between(
            bm,
            origin + frame @ Vector((x, half * 0.96, 2.2)),
            origin + frame @ Vector((x + rng.uniform(-0.4, 0.4), half * (1.0 + rng.uniform(0.0, 0.16)), rng.uniform(4.4, 7.0))),
            0.44,
            0.24,
            sides=4,
        )
    # The snapped mast, down across its own gunwale.
    taper_between(
        bm,
        origin + frame @ Vector((1.0, 0.0, 2.0)),
        origin + frame @ Vector((-11.0, 9.5, 11.5)),
        1.1,
        0.6,
        sides=6,
    )
    return finish("RimefangArena_Hull", bm, RF_WOOD)


def build_rf_ironwork(rng):
    bm = bmesh.new()
    origin, frame = _rf_hull_frame()
    # The harpoon gun still trained over the bow - the twin of the iron in
    # Rimefang's back, and the reason this wreck is here at all.
    swivel = origin + frame @ Vector((RF_HULL_LEN * 0.36, 0.0, 3.0))
    taper_between(bm, swivel + Vector((0, 0, -1.8)), swivel, 0.8, 1.0, sides=6)
    muzzle = swivel + Vector((math.cos(math.radians(214)) * 6.0, math.sin(math.radians(214)) * 6.0, 2.1))
    taper_between(bm, swivel + Vector((0, 0, 0.5)), muzzle, 0.66, 0.38, sides=6)
    cone(bm, muzzle, muzzle + (muzzle - swivel).normalized() * 2.8, 0.36, sides=4)
    # The line it fired, snapped, running away over the ice. It runs OUTWARD
    # (bearing 214 from a wreck on bearing 200) - everything about this piece
    # has to stay outside the ridge.
    tail = Vector(
        (
            swivel.x + math.cos(math.radians(214)) * 24.0,
            swivel.y + math.sin(math.radians(214)) * 24.0,
            0.0,
        )
    )
    tail.z = _rf_ground(tail.x, tail.y) + 0.35
    links = 18
    for i in range(links):
        a = swivel.lerp(tail, i / links)
        b = swivel.lerp(tail, (i + 1) / links)
        a.z = max(a.z, _rf_ground(a.x, a.y) + 0.3)
        b.z = max(b.z, _rf_ground(b.x, b.y) + 0.3)
        rot = Matrix.Rotation(math.radians(214) + math.pi / 2, 3, "Z") @ Matrix.Rotation(
            0 if i % 2 else math.pi / 2, 3, "X"
        )
        box(bm, (a + b) / 2, (1.05, 0.6, 0.46), rot)
    # A stock anchor half-swallowed by the floe near the line's end.
    ax, ay = tail.x, tail.y
    az = _rf_ground(ax, ay)
    box(
        bm,
        (ax, ay, az + 0.9),
        (8.0, 0.75, 0.75),
        Matrix.Rotation(math.radians(58), 3, "Z") @ Matrix.Rotation(math.radians(74), 3, "Y"),
    )
    for side in (-1, 1):
        fluke = Vector((ax + math.cos(math.radians(58)) * 2.8, ay + math.sin(math.radians(58)) * 2.8, az + 0.5))
        tip = fluke + Vector(
            (
                math.cos(math.radians(58 + side * 62)) * 3.4,
                math.sin(math.radians(58 + side * 62)) * 3.4,
                1.0,
            )
        )
        cone(bm, fluke, tip, 0.85, sides=4)
    # Try-pots tipped out of the wreck: the industry that started this.
    for i in range(2):
        px = ax + rng.uniform(-9.0, -5.0) + i * 3.6
        py = ay + rng.uniform(4.0, 8.0)
        ground = _rf_ground(px, py)
        tapered_cylinder(bm, ground, ground + 2.3, 2.3, 2.6, sides=9, center=(px, py))
    return finish("RimefangArena_Ironwork", bm, RF_IRON)


def build_rf_bones(rng):
    bm = bmesh.new()
    # What it left last time: a whale picked clean and frozen where it fell,
    # out on the pack past the ridge. FIVE big arcing ribs, not ten small
    # ones - two builds put a row of thin pegs on the ice and it read as a
    # picket fence from every angle. A ribcage is a few huge curved bones you
    # could walk under.
    angle = math.radians(RF_BONES[1])
    at = Vector((math.cos(angle) * RF_BONES[0], math.sin(angle) * RF_BONES[0], 0.0))
    # The spine lies ACROSS the bearing and the vertebrae march outward from
    # the skull, so the whole animal stays on the outer pack instead of
    # reaching a rib back over the ridge into the fight.
    axis = angle + math.radians(64)
    across = axis + math.pi / 2
    ground = _rf_ground(at.x, at.y)

    # The skull, and the jawbones longer than a boat.
    skull_back = Vector((at.x, at.y, ground + 1.8))
    taper_between(
        bm, skull_back, skull_back + Vector((math.cos(axis) * 10.0, math.sin(axis) * 10.0, -0.6)), 3.0, 1.1, sides=6
    )
    for side in (-1, 1):
        taper_between(
            bm,
            skull_back + Vector((0, 0, -0.6)),
            skull_back
            + Vector(
                (
                    math.cos(axis) * 19.0 + math.cos(across) * side * 4.6,
                    math.sin(axis) * 19.0 + math.sin(across) * side * 4.6,
                    -1.2,
                )
            ),
            1.2,
            0.5,
            sides=5,
        )

    for i in range(6):
        step = -6.0 * (i + 1)
        vx = at.x + math.cos(axis) * step
        vy = at.y + math.sin(axis) * step
        vg = _rf_ground(vx, vy)
        size = 2.1 - i * 0.16
        rock(bm, (vx, vy, vg + 1.0), (size, size, size * 0.9), rng, jitter=0.12)
        if i < 5:
            span = 13.5 - i * 1.3
            for side in (-1, 1):
                pts = []
                for k in range(6):
                    t = k / 5.0
                    out = math.sin(t * math.pi * 0.70) * span * 1.15
                    curl = -(t**2) * span * 0.30
                    up = t * span * 0.74
                    pts.append(
                        Vector(
                            (
                                vx + math.cos(across) * side * (out + curl),
                                vy + math.sin(across) * side * (out + curl),
                                vg - 0.4 + up,
                            )
                        )
                    )
                for k, (a, b) in enumerate(zip(pts, pts[1:])):
                    taper_between(bm, a, b, 1.45 - k * 0.19, 1.26 - k * 0.19, sides=5)
    return finish("RimefangArena_Bones", bm, RF_BONE)


def build_rf_foam(rng):
    bm = bmesh.new()
    angles = 48
    inner, outer = [], []
    for i in range(angles):
        angle = (i / angles) * TAU
        r0 = 168.0 + rng.uniform(-1.6, 1.6)
        r1 = 178.0 + rng.uniform(-2.2, 2.2)
        inner.append(bm.verts.new((math.cos(angle) * r0, math.sin(angle) * r0, 0.28)))
        outer.append(bm.verts.new((math.cos(angle) * r1, math.sin(angle) * r1, 0.22)))
    for i in range(angles):
        j = (i + 1) % angles
        bm.faces.new((inner[i], outer[i], outer[j], inner[j]))
    bmesh.ops.solidify(bm, geom=list(bm.faces) + list(bm.verts) + list(bm.edges), thickness=0.25)
    return finish("RimefangArena_Foam", bm, RF_FOAM)


# Where the four thin-ice patches used to be measured, in BLENDER xy (the
# BossArenas row carries them as Roblox X/Z, and Roblox Z = -Blender Y). The
# patches are shards now, so these are TARGETS rather than positions: the pass
# picks the rim shard nearest each one, which keeps the fight's four hubs
# within a few studs of where they already are and the BossArenas row nearly
# unchanged.
RF_THIN_TARGETS = [(73.1, 71.8), (-63.3, 88.7), (-80.2, -53.7), (53.5, -77.7)]


def _rf_thin_picks(shards):
    picks, taken = [], set()
    for tx, ty in RF_THIN_TARGETS:
        best, best_d = None, None
        for shard in shards:
            if shard["ring"] != 3 or shard["id"] in taken:
                continue
            d = math.hypot(shard["centroid"][0] - tx, shard["centroid"][1] - ty)
            if best_d is None or d < best_d:
                best, best_d = shard, d
        if best is not None:
            best["thin_target"] = (tx, ty, best_d)
            taken.add(best["id"])
            picks.append(best)
    return picks


def _rf_write_floe_json(shards, picks):
    """The shard map the server reads, in ROBLOX axes (X = Blender X, Z =
    -Blender Y - the convention BossArenas' thin-ice hubs already use).

    Written here because this is the only place that has seen the finished
    outlines: a hand-kept copy of forty polygons is the silent-absence shape
    this repo keeps getting bitten by. `tools/gen_rimefang_floe.py` turns it
    into `src/Shared/Config/RimefangFloe.luau` and its `--check` fails if the
    two have drifted.
    """
    import json
    import os

    path = os.environ.get("RF_FLOE_JSON") or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "rimefang_floe.json"
    )
    hole_r = min(
        math.hypot(x, y) for shard in shards if shard["ring"] == 0 for x, y in shard["outline"]
    )
    data = {
        "_generated": "assets/arena_gen.py build_rimefang - DO NOT EDIT BY HAND",
        "object": "RimefangArena_Shard%02d",
        "axes": "Roblox: X = Blender X, Z = -Blender Y, Y is up",
        "floorRadius": RF_FLOOR_R,
        "top": round(RF_PROFILE[0][1], 3),
        "water": {"radius": RF_WATER_R, "drop": RF_WATER_DROP},
        "hole": {"centre": [0.0, 0.0, 0.0], "radius": round(hole_r, 3), "cut": RF_HOLE_R},
        "crack": list(RF_CRACK),
        "thinIce": [shard["id"] for shard in picks],
        "shards": [
            {
                "id": shard["id"],
                "name": shard["name"],
                "centre": [
                    round(shard["centroid"][0], 3),
                    round(shard["top"], 3),
                    round(-shard["centroid"][1], 3),
                ],
                "ring": shard["ring"],
                "area": round(shard["area"], 2),
                "thickness": round(shard["thick"], 3),
                "neighbours": shard["neighbours"],
                "outline": [[round(x, 2), round(-y, 2)] for x, y in shard["outline"]],
            }
            for shard in shards
        ],
    }
    with open(path, "w") as handle:
        json.dump(data, handle, indent=1, sort_keys=False)
        handle.write("\n")
    print("FLOE MAP WRITTEN:", path, "-", len(shards), "shards")
    return path


def build_rimefang():
    rng = random.Random(4471)
    shards = _rf_shards(rng)
    picks = _rf_thin_picks(shards)
    objects = [
        build_rf_base(rng),
        build_rf_water(rng),
        build_rf_leads(rng, shards),
        build_rf_thinice(shards, picks),
        build_rf_ridge(rng),
        build_rf_bergs(rng),
        build_rf_hull(rng),
        build_rf_ironwork(rng),
        build_rf_bones(rng),
        build_rf_foam(rng),
    ] + build_rf_shards(shards)
    _rf_write_floe_json(shards, picks)
    print("HANDOFF rimefang: mesh bottom z %.1f  (skirt constant, informational - the authoritative meshBottom is MEASURED at export)" % (SKIRT_BOTTOM - 0.5))
    print(
        "HANDOFF rimefang: walkable floe r %.0f, DEAD FLAT at z %.2f, now SHATTERED into %d separate"
        " shards (`RimefangArena_Shard01..%02d`) with %.1f-%.1f stud cracks between them and a"
        " breathing hole at the middle; `_Water` is the dark plate %.1f studs under the ice"
        % (RF_FLOOR_R, _rf_height(0.0), len(shards), len(shards), RF_CRACK[0], RF_CRACK[1], RF_WATER_DROP)
    )
    areas = sorted(shard["area"] for shard in shards)
    spans = sorted(
        2.0 * max(math.hypot(x - shard["centroid"][0], y - shard["centroid"][1]) for x, y in shard["outline"])
        for shard in shards
    )
    print(
        "HANDOFF rimefang: shard area %.0f-%.0f studs^2 (median %.0f), across-the-shard span %.0f-%.0f studs,"
        " thickness %.1f-%.1f; ring 0 (touches the hole) %d, ring 1 %d, ring 2 %d, ring 3 (touches the ridge) %d"
        % (
            areas[0], areas[-1], areas[len(areas) // 2], spans[0], spans[-1],
            min(s["thick"] for s in shards), max(s["thick"] for s in shards),
            *[sum(1 for s in shards if s["ring"] == ring) for ring in range(4)],
        )
    )
    hole_r = min(math.hypot(x, y) for shard in shards if shard["ring"] == 0 for x, y in shard["outline"])
    print(
        "HANDOFF rimefang: the breathing hole is cut at r %.1f and its jagged edge comes no closer"
        " than r %.1f - BossArenas can treat it as r %.0f" % (RF_HOLE_R, hole_r, math.floor(hole_r))
    )
    # MEASURED, not bounded. A shard's own departure from the sheet height is
    # easy to state and says nothing a player can feel; what they feel is the
    # STEP where two shards meet, which is the difference of two tilts and two
    # sastrugi samples at the same point, and the lip where the rim shards butt
    # onto the annulus under the ridge foot. Both are printed because both are
    # what "the floor is still a clean canvas" has to mean now that the floor
    # is forty objects.
    worst = max(
        abs(_rf_shard_z(shard, x, y) - RF_PROFILE[0][1]) for shard in shards for x, y in shard["outline"]
    )
    by_id = {shard["id"]: shard for shard in shards}
    step = 0.0
    for shard in shards:
        for other in shard["neighbours"]:
            mate = by_id[other]
            mx = (shard["centroid"][0] + mate["centroid"][0]) / 2.0
            my = (shard["centroid"][1] + mate["centroid"][1]) / 2.0
            step = max(step, abs(_rf_shard_z(shard, mx, my) - _rf_shard_z(mate, mx, my)))
    lip = 0.0
    for shard in shards:
        if shard["ring"] != 3:
            continue
        for x, y in shard["outline"]:
            if math.hypot(x, y) > RF_FLOOR_R - 0.5:
                angle = math.atan2(y, x)
                lip = max(lip, abs(_rf_shard_z(shard, x, y) - (_rf_height(RF_FLOOR_R) + _rf_sastrugi(RF_FLOOR_R, angle))))
    print(
        "HANDOFF rimefang: every shard top is within %.2f studs of z %.2f; the worst step ACROSS a crack"
        " measures %.2f and the lip where the rim shards butt onto `_Base` at r %.0f measures %.2f -"
        " the floor is still the clean canvas the v2 brief asked for"
        % (worst, RF_PROFILE[0][1], step, RF_FLOOR_R, lip)
    )
    for shard in picks:
        tx, ty, drift = shard["thin_target"]
        print(
            "HANDOFF rimefang: THIN ICE is Shard%02d, centre Roblox (%.1f, 0, %.1f) r %.0f, %.0f studs"
            " across - %.1f studs off the BossArenas hub it replaces (%.1f, 0, %.1f)"
            % (
                shard["id"], shard["centroid"][0], -shard["centroid"][1],
                math.hypot(*shard["centroid"]),
                2.0 * max(math.hypot(x - shard["centroid"][0], y - shard["centroid"][1]) for x, y in shard["outline"]),
                drift, tx, -ty,
            )
        )
    crest_lo = min(_rf_crest(i / 180.0 * TAU) for i in range(180))
    crest_hi = max(_rf_crest(i / 180.0 * TAU) for i in range(180))
    print(
        "HANDOFF rimefang: ridge berm crest %.1f-%.1f studs over the sheet before the plate crown"
        " - a player jumps 7, so the boundary holds without a barrier part"
        % (crest_lo, crest_hi)
    )
    print(
        "HANDOFF rimefang: NOTHING stands inside r %.0f - the shards, `_Water`, `_Leads` and `_ThinIce`"
        " are the whole play area, and `_Base` is now the ANNULUS from r %.0f out (it keeps the name"
        " because BossArenaService finds the group and anchors the arena by it)" % (RF_FLOOR_R, RF_FLOOR_R)
    )
    for index, (radius, degrees, top) in enumerate(RF_BERGS):
        angle = math.radians(degrees)
        print(
            "HANDOFF rimefang: Berg%d rel (%.1f, %.1f) r %.0f top z %.1f - BACKDROP, outside the ridge, no collision"
            % (index + 1, math.cos(angle) * radius, math.sin(angle) * radius, radius, _rf_height(radius) + top)
        )
    hull_angle = math.radians(RF_HULL[1])
    print(
        "HANDOFF rimefang: Hull rel (%.1f, %.1f) r %.0f deck z ~%.1f - BACKDROP, and the harpoon's story"
        % (math.cos(hull_angle) * RF_HULL[0], math.sin(hull_angle) * RF_HULL[0], RF_HULL[0], _rf_height(RF_HULL[0]) + 5.8)
    )
    bone_angle = math.radians(RF_BONES[1])
    print(
        "HANDOFF rimefang: Bones rel (%.1f, %.1f) r %.0f - BACKDROP, spine laid across the bearing"
        % (math.cos(bone_angle) * RF_BONES[0], math.sin(bone_angle) * RF_BONES[0], RF_BONES[0])
    )
    print("HANDOFF rimefang: BossArenas.ice floorRadius = %.0f; the -Y quadrant is the drop-in lane" % RF_FLOOR_R)
    return objects

# ---------------------------------------------------------------- noctyss
#
# NOCTYSS / The Choirfloor (gloom boss, design locked 2026-08-29):
#   - an abyssal basalt shelf walkable from r~18 out to r~68, and then the
#     floor simply STOPS: a rim of broken teeth and a drop into black. The
#     boundary is the dark itself (the Lantern Choir design) - no wall, no
#     fence, nothing to read as scenery you were meant to climb.
#   - THE PIT at the centre (r 15, water at z -5.0 over a bed at -7.5): the
#     shelf was pierced FROM BELOW - the floor slabs around it are bent
#     upward and the cracks run outward across the stone. Noctyss's maw
#     rises through it in the punish window; the rest of the fight it is a
#     hole you can fall into, and one fallen slab on the -Y bearing is the
#     way back out.
#   - SEVEN SOCKETS at r 34 (<Model>_Socket1..7): chitin collars the choir
#     grows out of. Always present, lit or not, so the ring reads as a place
#     even with every stalk dead. The stalks themselves are the BOSS pass
#     (boss_gen.py); socket positions are printed in the HANDOFF for it.
#   - SIX SHADOW FINS at r 46-58: knife-edge rock blades, the only cover from
#     the choir's sweeping light (NoctyssPath.beamBlocked raycasts them).
#     Standing behind one keeps the beam off you and costs you the near FLOOR
#     read - the ground the next wedge arrives across - that trade is the
#     arena's mechanic. (Originally the cost was the choir read itself; the
#     gloom camera now rides above the lantern plane, and no camera that can
#     hold seven lanterns at once can be hidden by blades half their height,
#     so the trade survives with its terms swapped rather than grown taller -
#     taller fins would occlude the lanterns from everywhere.) Thin and
#     gapped, so they never trap a running player.
#   - the open stone between pit and sockets is kept CLEAN (the Tidebreak
#     lesson): everything on it is flat (cracks) or half-buried (bones), and
#     every prop with height sits past r~46.
#   - dressing tells the fight's story before it starts: two DEAD ELDERS -
#     snapped, lightless stalks lying on the shelf, so a player knows what a
#     stalk is before one lights up - bone drifts, biolum coral on the rim,
#     glow-kelp on the boundary teeth, and the trench's own black spires
#     standing outside the drop as the skyline.
#   - underwater skirt to r~86, foam ring outside it (named *_Foam:
#     OceanController rides it on the tide for free).
#   - THE MANTLE (2026-09-09, and the reason this section moved at all). The
#     user's note on the first build: the seven stalks and the maw "read as two
#     random organisms". They should not - they are ONE. The floor is her BACK.
#     So: the pit's inner edge is rolled into a fleshy LOWER LIP, and seven
#     tendon RIDGES run from that lip out to the sockets, each swelling into a
#     root collar where a lure grows out of her. A VEIN runs the crest of every
#     ridge, from the socket's foot down over the lip and into the mouth, so
#     the lures and the maw are visibly plumbed to each other.
#     Two rules the pass is built around. (1) It is FLOOR, not scenery: the
#     ridges are ~1.2-2.0 studs of rise over 5-6 studs of half-width, which the
#     generator MEASURES and prints (`_gl_mantle_slope`) rather than asserting.
#     (2) It does not touch the pit's numbers - radius 15, the open hole, the
#     annular band, the ~1.5 shelf - because the maw's rise and the ocean-slab
#     constraint are both keyed to them. Everything the roll adds is outboard
#     of r 15.4, on stone the first pass had already bent proud of the floor.

GL_PROFILE = [
    (0.0, -7.5),  # the pit's bed
    (11.0, -7.1),
    (15.0, -2.6),  # the torn wall climbs
    (18.0, 1.9),  # the lip, bent proud of the shelf
    (24.0, 1.5),
    (34.0, 1.6),  # the socket ring
    (50.0, 1.5),
    (62.0, 1.3),
    (68.0, 1.0),  # the stone ends
    (74.0, -2.4),
    (80.0, -6.2),
    (86.0, SKIRT_BOTTOM),
]

GL_PIT_R = 15.0
GL_PIT_WATER_Z = -5.0
GL_SOCKET_R = 34.0
GL_SOCKETS = [(GL_SOCKET_R, 12.0 + i * (360.0 / 7.0)) for i in range(7)]
GL_FINS = [(47.0, 28.0), (58.0, 84.0), (50.0, 140.0), (56.0, 196.0), (48.0, 252.0), (55.0, 316.0)]
GL_RAMP_DEG = 270.0  # the fallen slab: the way out of the pit, on the -Y bearing

# Straight off the trench's own palette (island_gen.py gloom COLORS), so the
# arena and Gloomtrench read as the same water. These five are the ISLAND's
# own material values, unchanged - they are the reference the arena's roles
# are tuned against, not the roles themselves.
GLOOM_ROCK = (0.110, 0.106, 0.145)  # near-black basalt
GLOOM_SHELF = (0.078, 0.082, 0.118)  # wet shelf stone
GLOOM_RIFT = (0.145, 0.133, 0.180)  # torn slabs, cracked stone
GLOOM_SILT = (0.243, 0.231, 0.298)  # ashen violet-grey silt
GLOOM_CHITIN = (0.231, 0.243, 0.298)  # the choir's collars, and its dead
DARKWATER = (0.024, 0.043, 0.086)  # all but black
GLOW_CYAN = (0.290, 0.937, 0.878)
GLOW_VIOLET = (0.663, 0.416, 0.937)

# THE ARENA'S VALUE LADDER (2026-09-01). The first pass painted the floor, the
# boundary and the skyline the same GLOOM_ROCK, and the fins - the fight's only
# cover - DARKER than the floor they stand on. Nothing is brightened out of the
# trench here: the whole ladder still lives under 40% grey, and the choir is
# still the only light. What changed is SEPARATION, in the order the player
# needs to read things:
#
#   fins  (78, 84,102)  cold blue-grey - the loudest thing you can stand behind
#   bones ( 77, 74, 70) warm, dressing, deliberately UNDER the fins now
#   socket( 74, 66, 86) warm violet chitin - hue-apart from the cold fins
#   slab  ( 60, 55, 66) the way out of the pit
#   rim   ( 52, 48, 62) the pit's lip, lifted clear of the floor
#   silt  ( 37, 36, 45) flat tonal skin, a whisper above the stone
#   teeth ( 38, 36, 43) the boundary, warmer and a step up from the floor
#   BASE  ( 28, 27, 37) GLOOM_ROCK, untouched - the floor is the datum
#   crack ( 18, 19, 27) flat and darker than the stone, as a crack should be
#   stacks( 13, 14, 20) the skyline, pushed back behind the drop
#
GLOOM_FIN = (0.306, 0.329, 0.400)  # shadow fins: cover, and the top of the ladder
GLOOM_DEAD = (0.204, 0.196, 0.235)  # dead elders: chitin with the life out of it
GLOOM_COLLAR = (0.290, 0.259, 0.337)  # socket collars: warm violet, apart from the fins
GLOOM_LIP = (0.204, 0.188, 0.243)  # the pit's bent lip - GLOOM_RIFT, lifted
GLOOM_SLAB = (0.235, 0.216, 0.259)  # the fallen slab, warmer than the lip it fell from
GLOOM_TEETH = (0.149, 0.141, 0.169)  # boundary teeth: dry, warm, off the floor's value
GLOOM_STACK = (0.051, 0.055, 0.078)  # sea stacks past the drop - the skyline recedes
GLOOM_CRACK = (0.071, 0.075, 0.106)  # cracks: flat, and below the stone they run across
GLOOM_BONE = (0.302, 0.290, 0.275)  # dressing, not a landmark - was (0.62,0.61,0.58)
GLOOM_SKIN = (0.145, 0.141, 0.176)  # flat silt skins on the shelf
GLOOM_FOAM = (0.196, 0.212, 0.259)  # barely-lit grey-violet; white surf would be the brightest thing in a lightless arena

# THE MANTLE (2026-09-09, user: the stalks and the maw "read as two random
# organisms"). They are not two organisms. The shelf IS her - the floor is her
# BACK, the pit is her MOUTH, and the seven lantern-stalks are lures growing out
# of her back around it. That is carried by geometry, not by a label: a rolled
# fleshy lip around the pit, and seven tendon ridges running from that lip out
# to each socket, swelling into a root collar where a lure grows.
#
# Both values sit BETWEEN the socket collar (74,66,86) and the pit's stone lip
# (52,48,62) on the arena's value ladder: the mantle is the collars' own flesh
# spread thin over the stone, so it must not out-read the collars, and the veins
# must not out-read the fins - the fins are still the loudest thing on the
# floor. The veins are WARMER than everything around them and that is their only
# separation; their brightness is the CLIENT's (PointLights along the crest),
# not the material's.
GLOOM_MANTLE = (0.247, 0.220, 0.290)  # her skin over the shelf - the collars' violet, dimmed
GLOOM_VEIN = (0.361, 0.267, 0.306)  # the vein strips: warm rose-violet, just under the fins


def _gl_height(r):
    for (r0, h0), (r1, h1) in zip(GL_PROFILE, GL_PROFILE[1:]):
        if r <= r1:
            t = 0 if r1 == r0 else (r - r0) / (r1 - r0)
            return h0 + (h1 - h0) * t
    return GL_PROFILE[-1][1]


def _gl_ground(x, y):
    return _gl_height(math.hypot(x, y))


def _gl_at(radius, degrees):
    angle = math.radians(degrees)
    return math.cos(angle) * radius, math.sin(angle) * radius


def build_gl_base(rng):
    bm = bmesh.new()
    angles = 44
    grid = []
    for radius in [row[0] for row in GL_PROFILE][1:]:
        ring = []
        for i in range(angles):
            angle = (i / angles) * TAU
            # The pit's mouth is TORN, not drilled: the two rings that make
            # its wall wander in and out. Everything else stays near-round so
            # the fight's ground telegraphs read true.
            wobble = 1.0 + (rng.uniform(-0.055, 0.055) if 12 < radius < 20 else 0.0)
            wobble += rng.uniform(-0.025, 0.025) if radius > 60 else 0.0
            r = radius * wobble
            z = _gl_height(radius)
            if 20 < radius < 70:
                # Old lava shelf: a slow swell across the stone, small enough
                # that nothing rolls out of sight behind it.
                z += math.sin(angle * 2.0 + radius * 0.07) * 0.28 + rng.uniform(-0.08, 0.08)
            ring.append(bm.verts.new((math.cos(angle) * r, math.sin(angle) * r, z)))
        grid.append(ring)
    centre = bm.verts.new((0, 0, GL_PROFILE[0][1]))
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
    return finish("NoctyssArena_Base", bm, GLOOM_ROCK)


def build_gl_pitwater(rng):
    bm = bmesh.new()
    # Black water standing in the pit. Opaque: you cannot see what is under
    # it until it comes up through it.
    angles = 30
    top, low = [], []
    for i in range(angles):
        angle = (i / angles) * TAU
        r = GL_PIT_R * 0.94 + rng.uniform(-0.7, 0.7)
        x, y = math.cos(angle) * r, math.sin(angle) * r
        top.append(bm.verts.new((x, y, GL_PIT_WATER_Z)))
        low.append(bm.verts.new((x, y, GL_PIT_WATER_Z - 0.4)))
    centre_top = bm.verts.new((0, 0, GL_PIT_WATER_Z))
    centre_low = bm.verts.new((0, 0, GL_PIT_WATER_Z - 0.4))
    for i in range(angles):
        j = (i + 1) % angles
        bm.faces.new((centre_top, top[i], top[j]))
        bm.faces.new((centre_low, low[j], low[i]))
        bm.faces.new((top[i], low[i], low[j], top[j]))
    # "Deco" is the runtime's non-collide tag (BossArenaService): without it
    # this disc is SOLID, and the pit's black water becomes a lid you stand
    # on four studs above the bed - capping the hole it is meant to fill.
    return finish("NoctyssArena_DecoPitWater", bm, DARKWATER)


def build_gl_rim(rng):
    bm = bmesh.new()
    # The floor slabs around the pit, bent UPWARD - the shelf was punched
    # from underneath. Their lean is what says "something lives down there"
    # before anything moves.
    #
    # They stand on `_gl_mantle_z`, not on the bare stone: the rolled lip
    # (2026-09-09) rises up to 1.05 studs through this exact band, and slabs
    # planted at the old height would be half-swallowed by it. Riding the roll
    # they read as broken plate still stuck in her lip, which is the point.
    slabs = 21
    for i in range(slabs):
        angle = (i / slabs) * TAU + rng.uniform(-0.09, 0.09)
        r = GL_PIT_R + rng.uniform(1.2, 3.6)
        x, y = math.cos(angle) * r, math.sin(angle) * r
        lean = math.radians(rng.uniform(14, 64))
        length = rng.uniform(3.0, 7.4)
        # Roll as well as lean: stone punched up from below lands crooked, and
        # a ring of evenly-tipped slabs reads as paving, not as damage.
        rot = (
            Matrix.Rotation(angle + rng.uniform(-0.22, 0.22), 3, "Z")
            @ Matrix.Rotation(-lean, 3, "Y")
            @ Matrix.Rotation(rng.uniform(-0.35, 0.35), 3, "X")
        )
        box(
            bm,
            (x, y, _gl_mantle_z(x, y) + math.sin(lean) * length * 0.42),
            (length, rng.uniform(2.2, 5.0), rng.uniform(0.6, 1.3)),
            rot,
        )
        # A shard split off the slab's high edge.
        if rng.random() < 0.55:
            sx, sy = x + math.cos(angle) * rng.uniform(-1.6, 1.6), y + math.sin(angle) * rng.uniform(-1.6, 1.6)
            cone(
                bm,
                (sx, sy, _gl_mantle_z(sx, sy)),
                (sx + rng.uniform(-0.8, 0.8), sy + rng.uniform(-0.8, 0.8), _gl_mantle_z(sx, sy) + rng.uniform(1.6, 3.6)),
                rng.uniform(0.5, 1.0),
                sides=4,
            )
    # Broken chunks that came off the lip and never went anywhere.
    for _ in range(9):
        angle = rng.uniform(0, TAU)
        r = rng.uniform(19.0, 25.0)
        x, y = math.cos(angle) * r, math.sin(angle) * r
        rock(bm, (x, y, _gl_mantle_z(x, y) + 0.3), (rng.uniform(0.9, 1.9),) * 3, rng, jitter=0.3)
    return finish("NoctyssArena_Rim", bm, GLOOM_LIP)


def build_gl_slab(rng):
    bm = bmesh.new()
    # The way out of the pit: one big floor slab that fell inward and wedged,
    # a ~22 degree climb from the water back onto the shelf. Deliberately on
    # the arrival bearing, so it is the first thing read on teleport-in.
    angle = math.radians(GL_RAMP_DEG)
    mid_r = GL_PIT_R * 0.55
    x, y = math.cos(angle) * mid_r, math.sin(angle) * mid_r
    # -22 degrees about Y puts the OUTER end high: it lands at r 17.3, z 1.7,
    # a 0.2-stud step onto the lip, and runs down to the water at the centre.
    rot = Matrix.Rotation(angle, 3, "Z") @ Matrix.Rotation(math.radians(-22), 3, "Y")
    box(bm, (x, y, -2.0), (19.5, 7.4, 1.1), rot)
    # A knuckle of rubble under its low end so it doesn't read as floating.
    rock(bm, (0.4, 0.9, -6.6), (3.6, 3.2, 1.7), rng, jitter=0.25)
    rock(bm, (-2.6, -1.8, -6.9), (2.4, 2.2, 1.2), rng, jitter=0.3)
    return finish("NoctyssArena_Slab", bm, GLOOM_SLAB)


def build_gl_cracks(rng):
    bm = bmesh.new()
    # Flat splits radiating out of the pit: tonal only, NO height, so the
    # open stone stays a clean canvas for the fight's telegraphs.
    for i in range(11):
        angle = (i / 11) * TAU + rng.uniform(-0.12, 0.12)
        r = GL_PIT_R + rng.uniform(2.0, 4.0)
        end = r + rng.uniform(9.0, 26.0)
        half = rng.uniform(0.35, 0.85)
        while r < end:
            step = rng.uniform(2.2, 4.0)
            a0, a1 = angle - half / r, angle + half / r
            quad = []
            for radius, a in ((r, a0), (r, a1), (r + step, a1), (r + step, a0)):
                x, y = math.cos(a) * radius, math.sin(a) * radius
                quad.append(bm.verts.new((x, y, _gl_ground(x, y) + 0.06)))
            bm.faces.new(quad)
            r += step
            angle += rng.uniform(-0.045, 0.045)
            half *= rng.uniform(0.86, 0.99)
    return finish("NoctyssArena_DecoCracks", bm, GLOOM_CRACK)


# ---- the mantle: the shelf as her back -------------------------------------
#
# ONE SURFACE FUNCTION, and everything reads it. The lip ring, the seven
# ridges, the root collars, the vein strips, the rim slabs and the coral
# necklace all take their height from `_gl_mantle_z`, so nothing can drift
# out of register with anything else - and so the vein sits in the gutter
# rather than 4 inches over it.
#
# NOTHING HERE TOUCHES THE PIT'S NUMBERS. Radius is still 15, the hole is
# still open, the annular band is still the base's, the shelf is still ~1.5.
# The rolled lip lives entirely OUTBOARD of r 15.4, on stone that was already
# bent proud of the floor; it re-reads that damage as a lower lip instead of
# moving it.
GL_LIP_RC = 18.6  # crest of the roll - the shelf's own bent lip, at r 18
GL_LIP_HALF = 3.4  # how far the roll reaches either side of that crest
GL_LIP_H = 0.90  # how proud of the stone the roll stands at its crest
# These three are a SLOPE BUDGET, not a look. A raised-cosine roll's steepest
# point is H * (pi/2) / HALF, the angular swell below multiplies H by up to
# 1.15, and the shelf itself falls away under all of it - at 1.05 over 3.0
# that measured 36.7 degrees on the roll's outer flank, which is a curb you
# fight at the one edge of the arena players are backing away from. RC also
# has to keep RC - HALF clear of 15.0: the roll must never reach the hole.
GL_RIDGE_R0 = 19.0  # where a tendon ridge parts from the lip
GL_RIDGE_SWAY = 1.7  # lateral studs of sinuous wander - a tendon, not a spoke
GL_VEIN_DEPTH = 0.22  # the crest gutter the vein strip lies in


def _gl_wrap(angle):
    return (angle + math.pi) % TAU - math.pi


def _gl_lip(r, a):
    """The rolled lip's rise above the stone, at radius r on bearing a.

    NOTCHED on the ramp bearing: the fallen slab's high end lands at r 17.3,
    z 1.7, and a 1.05-stud roll across it would turn the only way out of the
    pit into a step up. The notch reads as a split in her lip where the slab
    is wedged, which is a better story than an unbroken ring anyway.
    """
    d = abs(r - GL_LIP_RC)
    if d >= GL_LIP_HALF:
        return 0.0
    gate = abs(_gl_wrap(a - math.radians(GL_RAMP_DEG)))
    notch = 1.0 if gate >= 0.42 else 0.12 + 0.88 * (gate / 0.42) ** 2
    swell = 1.0 + 0.09 * math.sin(3.0 * a + 0.7) + 0.06 * math.sin(5.0 * a - 1.3)
    return GL_LIP_H * notch * swell * math.cos(math.pi * 0.5 * d / GL_LIP_HALF) ** 2


def _gl_ridge_angle(index, r):
    """The bearing of ridge `index` at radius r - a slack S, not a spoke."""
    t = max(0.0, min(1.0, (r - 15.4) / (GL_SOCKET_R - 15.4)))
    sway = GL_RIDGE_SWAY * math.sin(math.pi * t) * (1.0 if index % 2 == 0 else -1.0)
    return math.radians(GL_SOCKETS[index][1]) + sway / max(r, 1.0)


def _gl_ridge_h(index, r):
    """Crest height above the stone. 1.2 at the lip, 2.0 at the socket, and
    the pair (h, w) below is chosen so the flank never passes 30 degrees."""
    if r <= GL_RIDGE_R0:
        return 0.0
    if r > GL_SOCKET_R:
        # Dies FIVE studs past the socket, into the collar swell - not three.
        # Three put a 34-degree back slope on the far shoulder of every socket
        # (measured, `_gl_mantle_slope`), which is inside the collar's own
        # footprint and so invisible in every preview, and exactly the kind of
        # thing a player finds by getting stuck on it.
        base = 2.0 * max(0.0, 1.0 - (r - GL_SOCKET_R) / 5.0)
    elif r < 24.0:
        t = (r - GL_RIDGE_R0) / (24.0 - GL_RIDGE_R0)
        base = 1.35 * t * t * (3.0 - 2.0 * t)
    else:
        base = 1.35 + 0.65 * min(1.0, (r - 24.0) / 10.0)
    # A slow breathing undulation along the crest so no ridge is an extrusion.
    # Amplitude and frequency are both slope budget: 0.09 at 0.85/stud spent
    # 8 degrees of the 30 on ripple alone.
    return base * (1.0 + 0.06 * math.sin(r * 0.55 + index))


def _gl_ridge_w(r):
    """Half-width. Deliberately wide: h/w stays near 0.33, and a raised-cosine
    flank's steepest point is (h/w) * pi/2, so 0.33 is ~27 degrees - a tendon
    under skin you walk over without noticing, not a wall you get stuck on."""
    if r <= GL_RIDGE_R0:
        return 2.6
    if r < 24.0:
        return 2.6 + 1.8 * (r - GL_RIDGE_R0) / (24.0 - GL_RIDGE_R0)
    return 4.4 + 1.8 * min(1.0, (r - 24.0) / 10.0)


def _gl_collar(index, dx, dy):
    """The root collar: an annular swell of flesh around a socket, peaking just
    OUTSIDE the collar's own 4.4-stud wall so the chitin still stands proud of
    it. Gaussian, so its steepest point is ~23 degrees.

    LOBED, not round. On the first render seven perfectly circular swells read
    as seven landing pads set into the floor - the one thing a root should
    never look like. The peak radius wanders instead, which costs nothing and
    turns each of them back into something that grew.
    """
    a = math.atan2(dy, dx)
    peak = 5.5 * (1.0 + 0.18 * math.sin(3.0 * a + index) + 0.11 * math.sin(5.0 * a - index))
    return 1.7 * math.exp(-((math.hypot(dx, dy) - peak) / 3.4) ** 2)


def _gl_groove_half(r):
    # Widens as it runs outward, so the seven of them converging on the mouth
    # taper INTO it. 0.75 -> 0.045 was the first pass and rendered as seven
    # scratches; a vein that only the client's lights can find is a vein that
    # is not doing its job in the frame the user is judging.
    return 0.90 + 0.055 * (r - 16.0)


def _gl_groove(x, y):
    """Depth of the vein gutter at a point.

    Zero inboard of r 20.4 ON PURPOSE: the lip ring is swept at 132 angles and
    resolving a 1.5-stud gutter in it would cost four times that. Out there the
    vein rides PROUD of the roll instead of sunk in it - which is also the
    right read, a cord standing off the lip as it goes over into the mouth.
    """
    r = math.hypot(x, y)
    if r < 20.4 or r > 32.0:
        return 0.0
    fade = max(0.0, min(1.0, (r - 20.4) / 1.2, (32.0 - r) / 2.0))
    if fade <= 0.0:
        return 0.0
    a = math.atan2(y, x)
    half = _gl_groove_half(r)
    depth = 0.0
    for index in range(len(GL_SOCKETS)):
        lat = abs(_gl_wrap(a - _gl_ridge_angle(index, r))) * r
        if lat < half:
            depth = max(depth, GL_VEIN_DEPTH * (1.0 - (lat / half) ** 2))
    return depth * fade


def _gl_mantle_rise(x, y):
    """Her skin's rise over the shelf's stone: the roll, the seven ridges and
    the seven collars, combined with max() rather than sum so two of them
    meeting is a blend, never a doubled step."""
    r = math.hypot(x, y)
    a = math.atan2(y, x)
    rise = _gl_lip(r, a)
    w = _gl_ridge_w(r)
    for index, (radius, degrees) in enumerate(GL_SOCKETS):
        h = _gl_ridge_h(index, r)
        if h > 0.0:
            lat = abs(_gl_wrap(a - _gl_ridge_angle(index, r))) * r
            if lat < w:
                rise = max(rise, h * math.cos(math.pi * 0.5 * lat / w) ** 2)
        sx, sy = _gl_at(radius, degrees)
        rise = max(rise, _gl_collar(index, x - sx, y - sy))
    return rise


def _gl_mantle_z(x, y):
    """The walkable top of her back at (x, y)."""
    return _gl_ground(x, y) + _gl_mantle_rise(x, y) - _gl_groove(x, y)


def _gl_mantle_sheet(bm, rows, wrap):
    """Skin a grid of (x, y) rows onto the mantle surface as a CLOSED shell:
    a top sheet, a matching sheet 0.8 studs down inside the stone, and walls
    between them at the boundary. Not a bare sheet, because a bare sheet
    feathers to exactly the shelf's own height at its edge and z-fights it
    along every one of these outlines."""
    top, low = [], []
    for row in rows:
        t_row, l_row = [], []
        for x, y in row:
            t_row.append(bm.verts.new((x, y, _gl_mantle_z(x, y))))
            l_row.append(bm.verts.new((x, y, _gl_ground(x, y) - 0.8)))
        top.append(t_row)
        low.append(l_row)
    lanes = len(rows[0])
    span = len(rows) if wrap else len(rows) - 1
    for i in range(span):
        k = (i + 1) % len(rows)
        for j in range(lanes - 1):
            bm.faces.new((top[i][j], top[i][j + 1], top[k][j + 1], top[k][j]))
            bm.faces.new((low[i][j], low[k][j], low[k][j + 1], low[i][j + 1]))
        for j in (0, lanes - 1):
            bm.faces.new((top[i][j], top[k][j], low[k][j], low[i][j]))
    if not wrap:
        for i in (0, len(rows) - 1):
            for j in range(lanes - 1):
                bm.faces.new((top[i][j], low[i][j], low[i][j + 1], top[i][j + 1]))


def _gl_mantle_ridge(bm, index):
    # 20 x 11 is a TRIANGLE BUDGET, not a taste call. The mantle is one object
    # and a closed shell, so every extra lane costs four triangles per step;
    # the first cut (27 x 15, with 132 x 8 on the lip and 30 x 8 on each
    # collar) exported a 22,676-triangle mesh - half again as big as the
    # largest single mesh this repo ships (WrackArena_FleetRibs, 15,360), for
    # a shape whose whole job is to be smooth and two studs tall. 11 lanes
    # still puts three samples inside the vein gutter at every radius, which
    # is the one place resolution actually buys anything.
    steps, lanes = 20, 11
    rows = []
    for i in range(steps + 1):
        r = 20.4 + (34.6 - 20.4) * (i / steps)
        a = _gl_ridge_angle(index, r)
        w = _gl_ridge_w(r)
        row = []
        for j in range(lanes):
            f = -1.0 + 2.0 * (j / (lanes - 1))
            # Lanes bunched toward the crest: the gutter is ~1.5 studs wide on
            # a 12-stud ridge, and an even spread renders it as a dent.
            lat = math.copysign(abs(f) ** 1.5, f) * w
            ang = a + lat / r
            row.append((math.cos(ang) * r, math.sin(ang) * r))
        rows.append(row)
    _gl_mantle_sheet(bm, rows, False)


def _gl_mantle_collar(bm, index):
    radius, degrees = GL_SOCKETS[index]
    cx, cy = _gl_at(radius, degrees)
    # The inner ring sits at d 3.6, INSIDE the socket's own 4.4-stud wall, so
    # this annulus's buried inner skirt never shows.
    bands = (3.6, 4.8, 6.2, 7.8, 9.6, 11.4, 13.0)
    rows = []
    for i in range(22):
        a = (i / 22) * TAU
        rows.append([(cx + math.cos(a) * d, cy + math.sin(a) * d) for d in bands])
    _gl_mantle_sheet(bm, rows, True)


def build_gl_mantle(rng):
    """Her back: the rolled lip round the mouth, and the seven lure roots."""
    bm = bmesh.new()
    bands = (15.5, 16.6, 17.6, 18.6, 19.6, 20.6, 21.7)
    rows = []
    for i in range(88):
        a = (i / 88) * TAU
        rows.append([(math.cos(a) * r, math.sin(a) * r) for r in bands])
    _gl_mantle_sheet(bm, rows, True)
    for index in range(len(GL_SOCKETS)):
        _gl_mantle_ridge(bm, index)
        _gl_mantle_collar(bm, index)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return finish("NoctyssArena_Mantle", bm, GLOOM_MANTLE)


def build_gl_veins(rng):
    """The seven vein strips - ONE object, `NoctyssArena_DecoVeins`, for the
    client to hang its PointLights along.

    Deco, so the runtime strips its collision and its query: these are 1.5-stud
    ribbons lying in a gutter and there is nothing they should ever stop, and a
    default convex hull over seven of them radiating out of the pit would be a
    lid across the hole the maw comes up through.

    The material is warm, not emissive. Nothing here glows on its own - if the
    client's lights never arrive these read as dark cords in her back, which is
    exactly what a dead choir should look like.
    """
    bm = bmesh.new()
    for index in range(len(GL_SOCKETS)):
        steps = 46
        top_l, top_r, low_l, low_r = [], [], [], []
        for i in range(steps + 1):
            t = i / steps
            r = 16.5 + (30.2 - 16.5) * t
            a = _gl_ridge_angle(index, r)
            # Tapers to a thread as it goes over the lip and into the throat.
            half = 0.78 * _gl_groove_half(r) * min(1.0, 0.25 + t * 5.0)
            xs, ys = math.cos(a) * r, math.sin(a) * r
            # +0.12 off the surface: 0.12 PROUD of the roll inboard of the
            # gutter, and 0.10 SUNK below the ridge's shoulders once the
            # gutter opens (it is 0.22 deep) - inset, never a trip hazard.
            z = _gl_mantle_z(xs, ys) + 0.12
            for lat, top, low in ((-half, top_l, low_l), (half, top_r, low_r)):
                ang = a + lat / r
                x, y = math.cos(ang) * r, math.sin(ang) * r
                top.append(bm.verts.new((x, y, z)))
                low.append(bm.verts.new((x, y, z - 0.16)))
        for i in range(steps):
            bm.faces.new((top_l[i], top_r[i], top_r[i + 1], top_l[i + 1]))
            bm.faces.new((low_l[i], low_l[i + 1], low_r[i + 1], low_r[i]))
            bm.faces.new((top_l[i], top_l[i + 1], low_l[i + 1], low_l[i]))
            bm.faces.new((top_r[i], low_r[i], low_r[i + 1], top_r[i + 1]))
        bm.faces.new((top_l[0], low_l[0], low_r[0], top_r[0]))
        bm.faces.new((top_l[-1], top_r[-1], low_r[-1], low_l[-1]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return finish("NoctyssArena_DecoVeins", bm, GLOOM_VEIN)


def _gl_mantle_slope():
    """The walkability check, MEASURED off the surface that ships rather than
    asserted in a comment: the steepest gradient anywhere a player can stand
    on her back. Sampled from r 19 (the shelf side of the lip) outward; the
    throat wall inboard of that is the pit and is meant to be a fall."""
    centres = [_gl_at(radius, degrees) for radius, degrees in GL_SOCKETS]
    worst, at = 0.0, (0.0, 0.0)
    eps = 0.25
    r = 19.0
    while r <= 46.0:
        steps = max(48, int(TAU * r / 0.6))
        for i in range(steps):
            a = (i / steps) * TAU
            x, y = math.cos(a) * r, math.sin(a) * r
            # Skip the ground each socket STANDS ON: a 4.4-stud chitin wall is
            # already there, so the mantle's shape under it is not floor anyone
            # can walk and its gradient is not a walkability fact.
            if min(math.hypot(x - cx, y - cy) for cx, cy in centres) < 4.8:
                continue
            dzdx = (_gl_mantle_z(x + eps, y) - _gl_mantle_z(x - eps, y)) / (2 * eps)
            dzdy = (_gl_mantle_z(x, y + eps) - _gl_mantle_z(x, y - eps)) / (2 * eps)
            grade = math.hypot(dzdx, dzdy)
            if grade > worst:
                worst, at = grade, (x, y)
        r += 0.5
    return math.degrees(math.atan(worst)), at


def build_gl_sockets(rng):
    """The seven collars the choir grows from - the fight's furniture."""
    objects = []
    for index, (radius, degrees) in enumerate(GL_SOCKETS):
        bm = bmesh.new()
        cx, cy = _gl_at(radius, degrees)
        ground = _gl_height(radius)
        # A barnacled chitin collar, low enough to vault, wide enough to see
        # from across the shelf in the dark.
        tapered_cylinder(bm, ground - 1.4, ground + 2.4, 4.4, 3.5, sides=9, center=(cx, cy))
        tapered_cylinder(bm, ground + 2.4, ground + 3.0, 3.7, 3.1, sides=9, center=(cx, cy))
        # The bore: a recessed plug, so the collar reads as a mouth in the
        # stone rather than a bollard.
        tapered_cylinder(bm, ground + 0.6, ground + 1.9, 2.6, 2.2, sides=8, center=(cx, cy))
        # Teeth around the rim, uneven - grown, not built.
        for i in range(9):
            a = (i / 9) * TAU + rng.uniform(-0.1, 0.1)
            tx, ty = cx + math.cos(a) * 3.3, cy + math.sin(a) * 3.3
            cone(
                bm,
                (tx, ty, ground + 2.6),
                (tx + math.cos(a) * 0.5, ty + math.sin(a) * 0.5, ground + rng.uniform(3.6, 4.8)),
                0.55,
                sides=4,
            )
        # Root plates flaring into the stone.
        for i in range(5):
            a = (i / 5) * TAU + rng.uniform(-0.2, 0.2)
            px, py = cx + math.cos(a) * 4.6, cy + math.sin(a) * 4.6
            rock(bm, (px, py, ground - 0.1), (2.1, 1.6, 0.7), rng, jitter=0.22)
        objects.append(finish("NoctyssArena_Socket%d" % (index + 1), bm, GLOOM_COLLAR))
    return objects


def _gl_blade(bm, cx, cy, ground, height, length, yaw, rng):
    """One knife-edge rock fin: a wedge whose crest arcs up and splinters.

    Built as an explicit prism - a flat base strip and one ridge line -
    because a stack of boxes reads as masonry, and these have to read as the
    trench's own stone fins (island_gen build_gloom_spires).
    """
    steps = 9
    axis = Vector((math.cos(yaw), math.sin(yaw), 0.0))
    side = Vector((-axis.y, axis.x, 0.0))
    base_l, base_r, ridge = [], [], []
    for i in range(steps + 1):
        t = i / steps
        along = (t - 0.5) * length
        # The crest arcs: tall through the middle, dying into the stone at
        # both ends, with a splintered wobble along the top.
        # A jagged crest, not a whale's back: every ridge vertex is kicked
        # hard, and the wedge is thin enough to be a blade edge-on.
        h = height * (math.sin(math.pi * t) ** 0.62) * rng.uniform(0.74, 1.14)
        thick = (2.2 - 1.7 * (t - 0.5) ** 2 * 4.0) * rng.uniform(0.75, 1.1)
        centre = Vector((cx, cy, 0.0)) + axis * along + side * rng.uniform(-0.5, 0.5)
        base_l.append(bm.verts.new(tuple(centre + side * thick / 2 + Vector((0, 0, ground - 1.4)))))
        base_r.append(bm.verts.new(tuple(centre - side * thick / 2 + Vector((0, 0, ground - 1.4)))))
        ridge.append(bm.verts.new(tuple(centre + side * rng.uniform(-0.35, 0.35) + Vector((0, 0, ground + h)))))
    for i in range(steps):
        bm.faces.new((base_l[i], base_l[i + 1], ridge[i + 1], ridge[i]))
        bm.faces.new((base_r[i], ridge[i], ridge[i + 1], base_r[i + 1]))
        bm.faces.new((base_l[i], ridge[i], base_r[i]))
    bm.faces.new((base_l[-1], base_r[-1], ridge[-1]))
    bm.faces.new((base_l[0], base_r[0], base_l[-1], base_r[-1]))
    # Splinters off the crest, and rubble where the blade meets the shelf.
    for _ in range(5):
        t = rng.uniform(0.18, 0.82)
        tip = Vector((cx, cy, ground + height * (math.sin(math.pi * t) ** 0.62) * 0.88)) + axis * ((t - 0.5) * length)
        cone(bm, tuple(tip), tuple(tip + Vector((rng.uniform(-0.7, 0.7), rng.uniform(-0.7, 0.7), rng.uniform(2.6, 6.5)))), 0.75, sides=4)
    for _ in range(4):
        at = Vector((cx, cy, 0)) + axis * rng.uniform(-length * 0.6, length * 0.6) + side * rng.uniform(-2.6, 2.6)
        rock(bm, (at.x, at.y, ground + 0.2), (rng.uniform(1.1, 2.2), rng.uniform(0.9, 1.7), rng.uniform(0.7, 1.5)), rng, jitter=0.3)


def build_gl_fins(rng):
    bm = bmesh.new()
    # The shadow fins: the only cover from the choir's light, set tangentially
    # so each one throws its shadow along the ring rather than at the pit.
    for radius, degrees in GL_FINS:
        cx, cy = _gl_at(radius, degrees)
        yaw = math.radians(degrees + 90 + rng.uniform(-18, 18))
        _gl_blade(bm, cx, cy, _gl_height(radius), rng.uniform(14.0, 20.0), rng.uniform(13.0, 19.0), yaw, rng)
    return finish("NoctyssArena_Fins", bm, GLOOM_FIN)


def build_gl_elders(rng):
    bm = bmesh.new()
    # Two dead elders: stalks that were part of the choir once, snapped off
    # and lying where they fell. They teach the silhouette before the fight
    # lights one up - and they are why the sockets read as sockets.
    for radius, degrees, heading, length in ((52.0, 66.0, 152.0, 26.0), (44.0, 214.0, 318.0, 21.0)):
        cx, cy = _gl_at(radius, degrees)
        head = math.radians(heading)
        ground = _gl_height(radius)
        steps = 7
        prev = Vector((cx, cy, ground + 1.5))
        for i in range(steps):
            t = (i + 1) / steps
            # A slack curve: it fell, it did not get laid down.
            bend = math.sin(t * 2.1) * 3.0
            nxt = Vector(
                (
                    cx + math.cos(head) * length * t - math.sin(head) * bend,
                    cy + math.sin(head) * length * t + math.cos(head) * bend,
                    ground + 1.5 - t * 0.5,
                )
            )
            taper_between(bm, prev, nxt, 2.5 * (1.0 - t * 0.55), 2.5 * (1.0 - (t + 1.0 / steps) * 0.55), sides=7)
            # Knuckles, the same ring language the living stalks will carry.
            rock(bm, ((prev.x + nxt.x) / 2, (prev.y + nxt.y) / 2, (prev.z + nxt.z) / 2), (1.9 * (1 - t * 0.5),) * 3, rng, jitter=0.2)
            prev = nxt
        # The dead lantern: an empty cage of ribs, its light long gone.
        for i in range(5):
            a = (i / 5) * TAU
            rib = prev + Vector((math.cos(a) * 1.5, math.sin(a) * 1.5, 0.4))
            taper_between(bm, prev + Vector((0, 0, -0.4)), rib + Vector((0, 0, 1.7)), 0.42, 0.22, sides=4)
    return finish("NoctyssArena_Elders", bm, GLOOM_DEAD)


def build_gl_bones(rng):
    bm = bmesh.new()
    # Drifts of what the choir has already eaten, half-buried so nothing on
    # the open stone can catch a running player.
    for _ in range(7):
        angle = rng.uniform(0, TAU)
        radius = rng.uniform(38.0, 64.0)
        cx, cy = math.cos(angle) * radius, math.sin(angle) * radius
        ground = _gl_ground(cx, cy)
        for _ in range(rng.randint(3, 6)):
            ox, oy = rng.uniform(-3.4, 3.4), rng.uniform(-3.4, 3.4)
            span = rng.uniform(1.6, 4.2)
            head = rng.uniform(0, TAU)
            base = Vector((cx + ox, cy + oy, ground + 0.05))
            taper_between(
                bm,
                base,
                base + Vector((math.cos(head) * span, math.sin(head) * span, rng.uniform(0.1, 0.5))),
                rng.uniform(0.18, 0.34),
                rng.uniform(0.12, 0.26),
                sides=5,
            )
        if rng.random() < 0.5:
            rock(bm, (cx, cy, ground + 0.35), (1.5, 1.2, 0.8), rng, jitter=0.3)
    return finish("NoctyssArena_Bones", bm, GLOOM_BONE)


def build_gl_teeth(rng):
    bm = bmesh.new()
    # The boundary: broken stone teeth along the edge where the shelf ends.
    # You can see them against the void, and that is the whole job - past
    # them there is no floor, and no wall either.
    clusters = 34
    for i in range(clusters):
        angle = (i / clusters) * TAU + rng.uniform(-0.05, 0.05)
        r = rng.uniform(69.0, 75.0)
        cx, cy = math.cos(angle) * r, math.sin(angle) * r
        for _ in range(rng.randint(3, 5)):
            ox, oy = rng.uniform(-3.4, 3.4), rng.uniform(-3.4, 3.4)
            h = rng.uniform(5.0, 14.0)
            base = (cx + ox, cy + oy, _gl_ground(cx + ox, cy + oy) - 1.0)
            cone(bm, base, (base[0] + rng.uniform(-1.0, 1.0), base[1] + rng.uniform(-1.0, 1.0), base[2] + h), rng.uniform(1.3, 2.6), sides=5)
    return finish("NoctyssArena_Teeth", bm, GLOOM_TEETH)


def build_gl_stacks(rng):
    bm = bmesh.new()
    # The trench's own black spires, standing outside the drop: the skyline
    # that makes the boundary a place instead of an edge. Same language as
    # Gloomtrench_Spires on the island.
    for index, (radius, degrees, height) in enumerate((
        (80.0, 22.0, 34.0),
        (88.0, 74.0, 46.0),
        (82.0, 128.0, 27.0),
        (86.0, 178.0, 39.0),
        (81.0, 236.0, 30.0),
        (89.0, 296.0, 43.0),
        (84.0, 338.0, 24.0),
    )):
        cx, cy = _gl_at(radius, degrees)
        # Snapped spires among the whole ones: a skyline of identical needles
        # reads as a fence, which is the one thing this boundary must not be.
        broken = index % 3 == 2
        top = height * (0.42 if broken else 1.0)
        tapered_cylinder(
            bm,
            -6.0,
            top,
            rng.uniform(4.0, 6.5),
            rng.uniform(2.6, 3.6) if broken else rng.uniform(0.9, 1.8),
            sides=6,
            center=(cx, cy),
        )
        if broken:
            # The crown it lost, leaning against its own foot.
            fall = math.radians(degrees + rng.uniform(120, 240))
            foot = Vector((cx + math.cos(fall) * 5.0, cy + math.sin(fall) * 5.0, -3.0))
            taper_between(bm, tuple(foot), (cx, cy, top * 0.85), 2.2, 1.0, sides=5)
        # A leaning fin off its flank - the island's spires never stand alone.
        lean = math.radians(degrees + rng.uniform(-60, 60))
        base = Vector((cx + math.cos(lean) * 3.5, cy + math.sin(lean) * 3.5, -4.0))
        taper_between(bm, base, base + Vector((math.cos(lean) * 2.5, math.sin(lean) * 2.5, top * 0.55)), 2.6, 0.6, sides=5)
    return finish("NoctyssArena_Stacks", bm, GLOOM_STACK)


def build_gl_glow(rng):
    coral = bmesh.new()
    # Biolum coral: the arena's only standing light, and it is DIM on
    # purpose - enough to find the pit lip and the sockets by, never enough
    # to fight by. That is the choir's job, and the choir wants you close.
    # Coral rides `_gl_mantle_z`, not the bare stone: the root collar swells to
    # 1.7 studs at exactly the 5-7.5 band these clumps sit in, and the lip roll
    # to 1.05 through the necklace's band. On the old height the arena's only
    # standing light would have been buried by the mantle pass.
    for radius, degrees in GL_SOCKETS:
        cx, cy = _gl_at(radius, degrees)
        for _ in range(rng.randint(3, 5)):
            a = rng.uniform(0, TAU)
            d = rng.uniform(5.0, 7.5)
            x, y = cx + math.cos(a) * d, cy + math.sin(a) * d
            ellipsoid_r = rng.uniform(0.32, 0.62)
            bmesh.ops.create_icosphere(
                coral,
                subdivisions=1,
                radius=1.0,
                matrix=Matrix.Translation(Vector((x, y, _gl_mantle_z(x, y) + ellipsoid_r * 0.8)))
                @ Matrix.Diagonal(Vector((ellipsoid_r, ellipsoid_r, ellipsoid_r * 1.4))).to_4x4(),
            )
    # A thin necklace of it around the pit lip: the one edge you must be able
    # to find in the dark.
    for i in range(34):
        a = (i / 34) * TAU + rng.uniform(-0.05, 0.05)
        r = GL_PIT_R + rng.uniform(3.4, 5.0)
        x, y = math.cos(a) * r, math.sin(a) * r
        h = rng.uniform(0.5, 1.3)
        base_z = _gl_mantle_z(x, y)
        cone(coral, (x, y, base_z), (x + rng.uniform(-0.3, 0.3), y + rng.uniform(-0.3, 0.3), base_z + h), 0.3, sides=4)
    obj_coral = finish("NoctyssArena_GlowCoral", coral, GLOW_CYAN)

    kelp = bmesh.new()
    # Violet glow-kelp on the boundary teeth: the far edge, marked so you
    # know how much floor you have left when you are backing away from a beam.
    for i in range(22):
        angle = (i / 22) * TAU + rng.uniform(-0.1, 0.1)
        r = rng.uniform(68.0, 74.0)
        cx, cy = math.cos(angle) * r, math.sin(angle) * r
        for _ in range(rng.randint(2, 3)):
            ox, oy = rng.uniform(-1.8, 1.8), rng.uniform(-1.8, 1.8)
            base = (cx + ox, cy + oy, _gl_ground(cx + ox, cy + oy))
            cone(kelp, base, (base[0] + rng.uniform(-0.8, 0.8), base[1] + rng.uniform(-0.8, 0.8), base[2] + rng.uniform(2.4, 5.2)), 0.28, sides=4)
    obj_kelp = finish("NoctyssArena_GlowKelp", kelp, GLOW_VIOLET)
    return obj_coral, obj_kelp


def build_gl_silt(rng):
    bm = bmesh.new()
    # Flat silt skins on the shelf - tonal variation with no height, the same
    # trick the fen's algae patches use to keep the fight's canvas clean.
    for _ in range(22):
        angle = rng.uniform(0, TAU)
        radius = rng.uniform(21.0, 66.0)
        cx, cy = math.cos(angle) * radius, math.sin(angle) * radius
        sides = rng.randint(5, 7)
        spread = rng.uniform(2.6, 8.0)
        ring = []
        for i in range(sides):
            a = (i / sides) * TAU
            r = spread * rng.uniform(0.6, 1.25)
            x, y = cx + math.cos(a) * r, cy + math.sin(a) * r
            ring.append(bm.verts.new((x, y, _gl_ground(x, y) + 0.05)))
        bm.faces.new(ring)
    return finish("NoctyssArena_DecoSilt", bm, GLOOM_SKIN)


def build_gl_foam(rng):
    bm = bmesh.new()
    # The surf where the drop meets the surface, outside the teeth. Named
    # *_Foam so OceanController rides it on the tide.
    angles = 38
    inner, outer = [], []
    for i in range(angles):
        angle = (i / angles) * TAU
        r0 = 84.0 + rng.uniform(-1.4, 1.4)
        r1 = 91.0 + rng.uniform(-2.0, 2.0)
        inner.append(bm.verts.new((math.cos(angle) * r0, math.sin(angle) * r0, 0.26)))
        outer.append(bm.verts.new((math.cos(angle) * r1, math.sin(angle) * r1, 0.20)))
    for i in range(angles):
        j = (i + 1) % angles
        bm.faces.new((inner[i], outer[i], outer[j], inner[j]))
    bmesh.ops.solidify(bm, geom=list(bm.faces) + list(bm.verts) + list(bm.edges), thickness=0.25)
    return finish("NoctyssArena_Foam", bm, GLOOM_FOAM)


def build_noctyss():
    rng = random.Random(9137)
    objects = [
        build_gl_base(rng),
        build_gl_pitwater(rng),
        build_gl_rim(rng),
        build_gl_slab(rng),
        build_gl_cracks(rng),
        build_gl_silt(rng),
        build_gl_mantle(rng),
        build_gl_veins(rng),
        *build_gl_sockets(rng),
        build_gl_fins(rng),
        build_gl_elders(rng),
        build_gl_bones(rng),
        build_gl_teeth(rng),
        build_gl_stacks(rng),
        *build_gl_glow(rng),
        build_gl_foam(rng),
    ]
    print("HANDOFF noctyss: mesh bottom z %.1f  (skirt constant, informational - the authoritative meshBottom is MEASURED at export)" % (SKIRT_BOTTOM - 0.5))
    print(
        "HANDOFF noctyss: pit r %.1f, water z %.1f, bed z %.1f - the maw rises through it;"
        " fallen slab ramp out on bearing %.0f deg" % (GL_PIT_R, GL_PIT_WATER_Z, GL_PROFILE[0][1], GL_RAMP_DEG)
    )
    for index, (radius, degrees) in enumerate(GL_SOCKETS):
        x, y = _gl_at(radius, degrees)
        print(
            "HANDOFF noctyss: Socket%d rel (%.1f, %.1f) collar top z %.1f - choir stalk %d grows here (boss pass)"
            % (index + 1, x, y, _gl_height(radius) + 3.0, index + 1)
        )
    for index, (radius, degrees) in enumerate(GL_FINS):
        x, y = _gl_at(radius, degrees)
        print("HANDOFF noctyss: Fin%d rel (%.1f, %.1f) - light cover, blocks a sweeping beam" % (index + 1, x, y))
    print("HANDOFF noctyss: walkable stone r 18-68 (z ~1.5), socket ring r %.0f, boundary teeth r 69-75, foam r 84-91" % GL_SOCKET_R)
    slope, at = _gl_mantle_slope()
    print(
        "HANDOFF noctyss: MANTLE - rolled lip r %.1f-%.1f crest %.1f (+%.2f max, notched on the %.0f-deg ramp bearing);"
        " seven ridges r %.1f-%.1f, crest %.2f-%.2f tall, %.1f-%.1f studs wide, sway %.1f;"
        " root collars peak +%.2f at %.1f studs off each socket"
        % (
            GL_LIP_RC - GL_LIP_HALF, GL_LIP_RC + GL_LIP_HALF, GL_LIP_RC, GL_LIP_H, GL_RAMP_DEG,
            GL_RIDGE_R0, GL_SOCKET_R, _gl_ridge_h(0, 21.0), _gl_ridge_h(0, GL_SOCKET_R),
            2 * _gl_ridge_w(GL_RIDGE_R0), 2 * _gl_ridge_w(GL_SOCKET_R), GL_RIDGE_SWAY,
            _gl_collar(0, 5.5, 0.0), 5.5,
        )
    )
    print(
        "HANDOFF noctyss: MANTLE steepest walkable grade %.1f deg at (%.1f, %.1f) - measured over r 19-46, budget 30"
        % (slope, at[0], at[1])
    )
    print(
        "HANDOFF noctyss: NoctyssArena_DecoVeins is ONE object, seven strips r 16.5-30.2 on the ridge crests,"
        " ~%.1f-%.1f studs wide, sunk 0.10 under the shoulders past r 21.6 and 0.12 proud of the roll inboard of it."
        " NOT emissive - the client hangs PointLights along it. Deco: collision and query stripped at runtime."
        % (2 * 0.78 * _gl_groove_half(16.5), 2 * 0.78 * _gl_groove_half(30.2))
    )
    # The vein is ONE merged mesh, so the client cannot recover the seven crest
    # curves from it - and a light strip whose positions nobody can compute is a
    # light strip that never gets lit. Print them, in the ROBLOX frame the
    # BossArenas rows are already written in (glTF maps blender (x, y, z) to
    # (x, z, -y)), relative to the model's own origin.
    for index in range(len(GL_SOCKETS)):
        marks = []
        for r in (17.0, 20.0, 24.0, 27.0, 30.0):
            angle = _gl_ridge_angle(index, r)
            x, y = math.cos(angle) * r, math.sin(angle) * r
            marks.append("(%.1f, %.2f, %.1f)" % (x, _gl_mantle_z(x, y) + 0.12, -y))
        print("HANDOFF noctyss: Vein%d crest, roblox rel XYZ: %s - PointLight seats, socket %d's lure to the mouth" % (index + 1, " ".join(marks), index + 1))
    print("HANDOFF noctyss: pit radius, hole, annular band and shelf height UNCHANGED by the mantle pass - the roll lives outboard of r 15.4")
    return objects


# ---------------------------------------------------------------- pyrelisk

# THE ASHFALL THRONE - the CRATER RIM of a volcano, not an island.
#
# Redesign (user, 2026-08-29): "the player should be at the top of a huge
# volcano... you can trick the user by not having to fully model the volcano".
# So this arena models only the last 300 studs of a mountain and fakes
# everything under that:
#
#   * The fight happens on the RIM PATH - a flat annulus between two things
#     you cannot cross. Inside is the caldera's lava lake (the colossus stands
#     in it, out of melee reach - the moat is WHY the fight is ranged, and a
#     fallen arm bridging it is the only way onto the boss). Outside is the
#     mountain falling away.
#   * The outer lip is low and OVERHANGING, so it contains the player without
#     walling off the view - and it is broken by five collapsed NOTCHES that
#     are deliberate vista windows: you walk to one and look out over the
#     drop.
#   * Below the lip the flank falls 300 studs and simply STOPS, because a
#     CLOUD DECK (PyreliskArena_CloudDeco, a 980-radius disc 70 studs below
#     the rim, tilting up as it recedes) hides the cut, the sea, and the
#     entire lower mountain. Distant peaks poke through it. Nobody ever sees
#     the bottom of anything, so the mountain is as tall as the player
#     assumes it is.
#
# The one thing the mesh cannot fake is the horizon past the deck's outer
# edge: that needs arena FOG (~2000 studs), the per-island fog-mood machinery
# pointed at an arena. Without it the ocean reappears as a band beyond r~5300.
#
# The locked movement rules are unchanged: the path is DEAD FLAT, nothing on
# it can be climbed, and the boss is centred so the camera orbits it.

PY_PATH_Z = 0.0  # the rim path surface - the mesh's reference height
PY_LAKE_R = 120.0  # the caldera's lava lake: the moat, and the boss's footing
PY_PATH_R = 232.0  # walkable to here; the lip starts
PY_LIP_R = 246.0
PY_LIP_CREST = 11.0  # containment height, kept low so the vista survives
PY_NOTCH_CREST = 3.2  # at a vista notch - see the jump-lock note in the HANDOFF
PY_NOTCH_BEARINGS = (28.0, 104.0, 168.0, 249.0, 321.0)
PY_SEAM_RINGS = (140.0, 168.0, 196.0, 224.0)  # the dial: telegraph distance bands
PY_FLANK_BOTTOM = -300.0  # where the modelled mountain stops (never seen)
PY_CLOUD_Z = -260.0  # deep: the flank must FALL into the cloud, not sit on it
PY_CLOUD_R = 880.0  # deck radius; billows ride ON it, so the bbox is ~1980 - inside the 2048 part cap
PY_GATE_BEARING = math.radians(90.0)

# How high the rim path stands above the sea once BossArenaService places it.
# Chosen so the flank's cut sits just UNDER the waterline (hidden) while the
# cloud deck floats clear ABOVE it - and so nothing playable is ever below
# Y = 0, because the ocean slab is solid to players with its top face there.
PY_RIM_WORLD_Y = 292.0

# The outer radius with OPEN SKY over it. The lip's face undercuts back to
# r205, so between there and the path's edge a player is walking under a
# ceiling - fine to stand in, wrong to aim a falling fist at. Measured with
# scratchpad/floor_check.py: a downward ray at r231 lands on the Rim 7.25
# studs up, not on the floor.
PY_CLEAR_R = 200.0

PY_BASALT = (0.170, 0.155, 0.170)  # the rim path: cooled basalt
PY_OBSIDIAN = (0.085, 0.085, 0.115)  # lip, monoliths, gate
PY_FLANK_ROCK = (0.130, 0.115, 0.120)  # the mountainside below the lip
PY_MAGMA = (0.950, 0.190, 0.015)  # deep, because emission + AgX washes anything brighter to peach
PY_SEAM = (0.820, 0.115, 0.012)
PY_BONE = (0.700, 0.670, 0.600)
PY_ASH = (0.330, 0.310, 0.315)
PY_CRUST = (0.205, 0.185, 0.195)
PY_ASH_DRIFT = (0.255, 0.240, 0.242)
PY_CLOUD = (0.520, 0.495, 0.500)  # ash-stained cloud; never white, or it outshines the sky


def _py_glow(obj, strength):
    """Emission on an object's material - PREVIEW ONLY.

    In game these parts are Neon, set by name at placement; EEVEE has no such
    idea, and without this the lava and the seam rings render as flat orange
    paint on rock instead of the only light sources up here.
    """
    material = obj.data.materials[0]
    bsdf = material.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        base = bsdf.inputs["Base Color"].default_value
        for slot in ("Emission Color", "Emission"):
            if slot in bsdf.inputs:
                bsdf.inputs[slot].default_value = (base[0], base[1], base[2], 1.0)
                break
        if "Emission Strength" in bsdf.inputs:
            bsdf.inputs["Emission Strength"].default_value = strength
    return obj


def _py_annulus(bm, r0, r1, z, angles, rng, wobble=0.0):
    inner, outer = [], []
    for i in range(angles):
        a = (i / angles) * TAU
        w = rng.uniform(-wobble, wobble) if wobble else 0.0
        inner.append(bm.verts.new((math.cos(a) * (r0 + w), math.sin(a) * (r0 + w), z)))
        outer.append(bm.verts.new((math.cos(a) * (r1 + w), math.sin(a) * (r1 + w), z)))
    for i in range(angles):
        j = (i + 1) % angles
        bm.faces.new((inner[i], outer[i], outer[j], inner[j]))


def _py_notch(angle):
    """Lip crest height at a bearing: full, or dropped at a vista notch."""
    crest = PY_LIP_CREST
    for bearing in PY_NOTCH_BEARINGS:
        delta = abs(((angle - math.radians(bearing) + math.pi) % TAU) - math.pi)
        half, blend = math.radians(11.0), math.radians(7.0)
        if delta < half + blend:
            t = 0.0 if delta <= half else (delta - half) / blend
            crest = min(crest, PY_NOTCH_CREST + (PY_LIP_CREST - PY_NOTCH_CREST) * t)
    return crest


PY_BASE_INNER_R = 118.0  # the annulus' inner edge - where the caldera's hole starts
PY_SHAFT_R = 108.0  # the drop's clear bore; the lip is PY_BASE_INNER_R - this
PY_SHAFT_BOTTOM = -120.0  # the shaft's foot, authored z (design 8.3: "z 0 down to -120")
PY_LAKE_FLOOR_THICK = 3.0  # the removable lid over the shaft: a LID, not a plug


def build_py_base(rng):
    bm = bmesh.new()
    # DEAD FLAT, and it used to be flat ALL THE WAY ACROSS - one disc under
    # the whole caldera, lake included. It is an ANNULUS now, from
    # PY_BASE_INNER_R outward, and the centre disc it used to carry is
    # `PyreliskArena_LakeFloor` (below). Splitting it is what makes the caldera
    # able to open: `BossArenaService.applyCaldera` switches the lake floor's
    # collision, draw and query off on `PyreliskCaldera = 1`, and it cannot
    # switch off half of an object.
    #
    # THE SPLIT MUST NOT MOVE THE FLOOR BY A THOUSANDTH. At Caldera = 0 this
    # arena has to be indistinguishable from the one before the split - same
    # standing heights, same lava surface, same probe answers - because the
    # cutscene lane frames shots against `_Lava` / `_Rim` / `_Teeth` / `_Gate`
    # / `_CloudDeco` and against floorY at r 170. So: the top face stays at
    # PY_PATH_Z exactly, the ring radii outboard of the seam are the ones this
    # builder always used, and the UNDERSIDE keeps the old cone's own profile
    # where it survives (the cone ran from z 0 at r 236 to -40 at r 0, so at
    # r 118 it was at -20.0, and that is where the annulus' underside stops).
    # `build_pyrelisk` prints the probes; the equivalence is measured, not
    # asserted.
    angles = 60
    rings = [PY_BASE_INNER_R, 122.0, 152.0, 182.0, 210.0, PY_PATH_R + 4.0]
    grid = []
    for radius in rings:
        ring = []
        for i in range(angles):
            a = (i / angles) * TAU
            ring.append(bm.verts.new((math.cos(a) * radius, math.sin(a) * radius, PY_PATH_Z)))
        grid.append(ring)
    for a, b in zip(grid, grid[1:]):
        for i in range(angles):
            j = (i + 1) % angles
            bm.faces.new((a[i], b[i], b[j], a[j]))
    # The old cone's height at the new inner edge, so the mountain's underside
    # is unchanged everywhere it is still authored.
    under_z = -40.0 * (1.0 - PY_BASE_INNER_R / (PY_PATH_R + 4.0))
    inner_under = []
    for i in range(angles):
        a = (i / angles) * TAU
        inner_under.append(bm.verts.new((math.cos(a) * PY_BASE_INNER_R, math.sin(a) * PY_BASE_INNER_R, under_z)))
    outer = grid[-1]
    for i in range(angles):
        j = (i + 1) % angles
        # the underside (the old cone's own surface where it survives) and the
        # inner wall of the hole - a closed annular solid, so a convex
        # decomposition reads it as a ring rather than filling the caldera
        # back in.
        bm.faces.new((inner_under[i], outer[i], outer[j], inner_under[j]))
        bm.faces.new((grid[0][i], grid[0][j], inner_under[j], inner_under[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    _ = rng
    return finish("PyreliskArena_Base", bm, PY_BASALT)


def build_py_lake_floor(rng):
    """THE DISC THAT CLOSES THE CALDERA, and the one object in this arena whose
    whole purpose is to stop existing.

    It is what actually holds a body standing on the magma today - `_Lava` is a
    HAZARD_MARKERS surface and has never collided with anything - so its top
    face is at PY_PATH_Z, dead flat, exactly where `build_py_base`'s centre disc
    used to be. At `PyreliskCaldera = 1` it stops colliding, drawing and
    answering casts, and the shaft underneath it is the way into act four.

    A LID, NOT A PLUG. Three studs thick and no deeper: it closes the TOP of
    the shaft rather than filling it, so the bore is clear the moment the lid
    goes. Radius 120 overlaps the annulus' inner edge at 118 by two studs,
    which is what keeps the seam from being a crack a foot can find."""
    bm = bmesh.new()
    angles = 60
    top, bottom = [], []
    for i in range(angles):
        a = (i / angles) * TAU
        x, y = math.cos(a) * PY_LAKE_R, math.sin(a) * PY_LAKE_R
        top.append(bm.verts.new((x, y, PY_PATH_Z)))
        bottom.append(bm.verts.new((x, y, PY_PATH_Z - PY_LAKE_FLOOR_THICK)))
    hub_top = bm.verts.new((0, 0, PY_PATH_Z))
    hub_bottom = bm.verts.new((0, 0, PY_PATH_Z - PY_LAKE_FLOOR_THICK))
    for i in range(angles):
        j = (i + 1) % angles
        bm.faces.new((hub_top, top[i], top[j]))
        bm.faces.new((hub_bottom, bottom[j], bottom[i]))
        bm.faces.new((top[i], bottom[i], bottom[j], top[j]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    _ = rng
    return finish("PyreliskArena_LakeFloor", bm, PY_BASALT)


def build_py_shaft(rng):
    """THE DROP. A tube, walls only, no floor: r 108 clear bore from the lake
    floor's datum down 120 studs, authored under a lid that is removed rather
    than cut open.

    PRECISECONVEXDECOMPOSITION IS REQUIRED ON THIS OBJECT. A default convex
    hull fills a hollow tube solid, and a shaft that is solid is a caldera that
    opens onto rock - the fight stops at act three with nothing in any log to
    say why. `KrakenGullet_Walls` carries the same note for the same reason.

    Its outer surface stands at PY_BASE_INNER_R, so the tube's top ring IS the
    lip of the hole: when the lid goes there is no gap between the annulus'
    inner edge and the wall of the drop. Bottom z is PY_SHAFT_BOTTOM, which is
    160 studs ABOVE the cloud deck's billows - so this object does not touch
    the model's bbox floor and `meshBottom` does not move."""
    bm = bmesh.new()
    angles = 48
    levels = [PY_PATH_Z, -24.0, -52.0, -84.0, PY_SHAFT_BOTTOM]
    inner_rings, outer_rings = [], []
    for z in levels:
        inner, outer = [], []
        for i in range(angles):
            a = (i / angles) * TAU
            # A faint flute round the bore so the drop reads as rock rather
            # than as a pipe - on the surface only, never on the clear radius.
            flute = math.sin(a * 6.0) * 1.2
            inner.append(bm.verts.new((math.cos(a) * (PY_SHAFT_R + flute), math.sin(a) * (PY_SHAFT_R + flute), z)))
            outer.append(bm.verts.new((math.cos(a) * PY_BASE_INNER_R, math.sin(a) * PY_BASE_INNER_R, z)))
        inner_rings.append(inner)
        outer_rings.append(outer)
    for rings in (inner_rings, outer_rings):
        for lo, hi in zip(rings, rings[1:]):
            for i in range(angles):
                j = (i + 1) % angles
                bm.faces.new((lo[i], lo[j], hi[j], hi[i]))
    for k in (0, -1):
        for i in range(angles):
            j = (i + 1) % angles
            bm.faces.new((inner_rings[k][i], outer_rings[k][i], outer_rings[k][j], inner_rings[k][j]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    _ = rng
    return finish("PyreliskArena_Shaft", bm, PY_OBSIDIAN)


def build_py_lava(rng):
    bm = bmesh.new()
    # The caldera lake: FLUSH with the path, 240 studs across. It is the moat
    # that keeps the fight ranged and the pool the colossus stands in.
    #
    # DO NOT SINK IT. Dropping the lake below the rim to make it dramatic
    # breaks two things at once, and only one of them has a symptom:
    #   * THE MOVEMENT RULE - this arena's contract is that the player moves
    #     horizontally and never falls, so a pit is a fall;
    #   * THE WATERLINE - the ocean slab is solid to players with its top face
    #     at Y = 0, and the rim path sits at PY_RIM_WORLD_Y (+292). Sink the
    #     lake far enough and its floor is authored inside that collision,
    #     which no gate catches and which presents as players standing on
    #     nothing rather than as anything resembling its cause.
    # The flush surface looks like a style choice. It is load-bearing twice.
    angles = 56
    ring = []
    for i in range(angles):
        a = (i / angles) * TAU
        r = PY_LAKE_R + rng.uniform(-3.4, 3.4)
        ring.append(bm.verts.new((math.cos(a) * r, math.sin(a) * r, PY_PATH_Z + 0.10)))
    centre = bm.verts.new((0, 0, PY_PATH_Z + 0.14))
    for i in range(angles):
        bm.faces.new((centre, ring[i], ring[(i + 1) % angles]))
    return _py_glow(finish("PyreliskArena_Lava", bm, PY_MAGMA), 0.45)


def build_py_seams(rng):
    bm = bmesh.new()
    # THE DIAL. Four seams across the path at the radii the fight's ring novas
    # are keyed to, so distance is read off the ground instead of guessed
    # against a 400-stud silhouette.
    for radius in PY_SEAM_RINGS:
        _py_annulus(bm, radius - 1.1, radius + 1.1, PY_PATH_Z + 0.06, 72, rng, wobble=0.8)
    # Cracks running outward from the lake edge, where the lava works its way
    # under the rim.
    for i in range(22):
        a = (i / 22) * TAU + rng.uniform(-0.05, 0.05)
        start = PY_LAKE_R + rng.uniform(1.0, 5.0)
        span = rng.uniform(20.0, 78.0)
        steps, prev = 7, None
        for s in range(steps + 1):
            t = s / steps
            rr = start + span * t
            aa = a + math.sin(t * 5.2 + i) * 0.03
            half = (1.0 - t) * rng.uniform(0.5, 1.1) + 0.12
            nx, ny = -math.sin(aa), math.cos(aa)
            cx, cy = math.cos(aa) * rr, math.sin(aa) * rr
            left = bm.verts.new((cx - nx * half, cy - ny * half, PY_PATH_Z + 0.05))
            right = bm.verts.new((cx + nx * half, cy + ny * half, PY_PATH_Z + 0.05))
            if prev is not None:
                bm.faces.new((prev[0], prev[1], right, left))
            prev = (left, right)
    return _py_glow(finish("PyreliskArena_SeamDeco", bm, PY_SEAM), 0.55)


def build_py_plates(rng):
    crust = bmesh.new()
    ash = bmesh.new()
    # Tonal break-up with ZERO height: the path needs it or it renders as
    # asphalt, and it must get it without a stud of relief, because the fight
    # paints its telegraphs on this floor.
    for _ in range(30):
        angle = rng.uniform(0, TAU)
        radius = rng.uniform(PY_LAKE_R + 8.0, PY_PATH_R - 8.0)
        cx, cy = math.cos(angle) * radius, math.sin(angle) * radius
        target = crust if rng.random() < 0.62 else ash
        sides = rng.randint(5, 8)
        spread = rng.uniform(8.0, 24.0)
        ring = []
        for i in range(sides):
            a = (i / sides) * TAU
            r = spread * rng.uniform(0.55, 1.3)
            ring.append(target.verts.new((cx + math.cos(a) * r, cy + math.sin(a) * r, PY_PATH_Z + 0.04)))
        target.faces.new(ring)
    return (
        finish("PyreliskArena_CrustDeco", crust, PY_CRUST),
        finish("PyreliskArena_AshDeco", ash, PY_ASH_DRIFT),
    )


def build_py_lip(rng):
    bm = bmesh.new()
    # The outer containment: low, so you can see out, and OVERHANGING, because
    # a Roblox humanoid walks up almost any slope but cannot walk up something
    # that leans back over it. Five notches drop it to a kerb - those are the
    # windows you look out of.
    angles = 96
    grid = [[] for _ in range(4)]
    for i in range(angles):
        a = (i / angles) * TAU
        crest = _py_notch(a)
        jitter = rng.uniform(-0.5, 0.5)
        for index, (radius, z) in enumerate(
            (
                (PY_PATH_R + 2.0, PY_PATH_Z - 0.3),
                (PY_PATH_R - 3.0, crest * 0.55),  # the overhang: leans back over the path
                (PY_LIP_R - 8.0, crest + jitter),
                (PY_LIP_R + 6.0, crest * 0.30),
            )
        ):
            grid[index].append(bm.verts.new((math.cos(a) * radius, math.sin(a) * radius, z)))
    for a, b in zip(grid, grid[1:]):
        for i in range(angles):
            j = (i + 1) % angles
            bm.faces.new((a[i], b[i], b[j], a[j]))
    return finish("PyreliskArena_Rim", bm, PY_OBSIDIAN)


def build_py_teeth(rng):
    bm = bmesh.new()
    # Cover on the path, and only cover: every one of these is a POINT. Kept
    # off the notch bearings so they never block a vista window.
    placed = []
    for _ in range(9):
        spot = None
        for _attempt in range(80):
            a = rng.uniform(0, TAU)
            r = rng.uniform(138.0, 218.0)
            if abs(((a - PY_GATE_BEARING + math.pi) % TAU) - math.pi) < 0.28:
                continue
            if any(abs(((a - math.radians(b) + math.pi) % TAU) - math.pi) < 0.30 for b in PY_NOTCH_BEARINGS):
                continue
            x, y = math.cos(a) * r, math.sin(a) * r
            if all((x - px) ** 2 + (y - py) ** 2 > 46.0**2 for px, py in placed):
                spot = (x, y)
                break
        if spot is None:
            continue
        placed.append(spot)
        x, y = spot
        h = rng.uniform(12.0, 21.0)
        cone(bm, (x, y, PY_PATH_Z - 1.0), (x + rng.uniform(-2.2, 2.2), y + rng.uniform(-2.2, 2.2), PY_PATH_Z + h), rng.uniform(3.2, 5.2), sides=5)
        for _ in range(rng.randint(2, 4)):
            ox, oy = rng.uniform(-5.0, 5.0), rng.uniform(-5.0, 5.0)
            cone(
                bm,
                (x + ox, y + oy, PY_PATH_Z - 0.5),
                (x + ox + rng.uniform(-1.2, 1.2), y + oy + rng.uniform(-1.2, 1.2), PY_PATH_Z + rng.uniform(2.6, 6.0)),
                rng.uniform(1.1, 2.0),
                sides=4,
            )
    for index, (x, y) in enumerate(placed):
        # PRINTED IN ROBLOX-RELATIVE COORDS, not build coords, because that is
        # what the consumer needs: BossArenas.stones is a list of Roblox
        # offsets. The exporter maps blender (x, y, z) -> (x, z, -y), so
        # roblox Z = -blender y - X and the height read across unchanged and Z
        # does NOT. Copying a build-space pair straight into the config
        # mirrors it about the Z axis, which is silent: the stone still exists,
        # still sits on the floor, and is simply on the wrong side of the
        # arena from the rock the player can see. (f9 hit the same trap
        # probing NPC pads and reported a boss spawning on a roof that it
        # never was.) Doing the negation HERE puts the trap inside the
        # generator instead of in every reader.
        print(
            "HANDOFF pyrelisk: Monolith%d ROBLOX rel (%.1f, %.1f) - cover, never a platform;"
            " paste straight into BossArenas.stones" % (index + 1, x, -y)
        )
    return finish("PyreliskArena_Teeth", bm, PY_OBSIDIAN)


def build_py_flank(rng):
    bm = bmesh.new()
    # The mountainside: it falls 300 studs and STOPS. The cloud deck covers
    # the cut, so this is the only part of a mountain that ever gets modelled.
    angles = 72
    profile = [
        (PY_LIP_R + 4.0, -2.0),
        (PY_LIP_R + 14.0, -40.0),
        (292.0, -112.0),
        (356.0, -186.0),
        (424.0, -248.0),
        (486.0, PY_FLANK_BOTTOM),
    ]
    grid = []
    for radius, z in profile:
        ring = []
        for i in range(angles):
            a = (i / angles) * TAU
            rr = radius * (1.0 + rng.uniform(-0.022, 0.022))
            ring.append(bm.verts.new((math.cos(a) * rr, math.sin(a) * rr, z + rng.uniform(-4.0, 4.0))))
        grid.append(ring)
    for a, b in zip(grid, grid[1:]):
        for i in range(angles):
            j = (i + 1) % angles
            bm.faces.new((a[i], b[i], b[j], a[j]))
    bottom = bm.verts.new((0, 0, PY_FLANK_BOTTOM - 2.0))
    outer = grid[-1]
    for i in range(angles):
        bm.faces.new((bottom, outer[(i + 1) % angles], outer[i]))
    return finish("PyreliskArena_Flank", bm, PY_FLANK_ROCK)


def build_py_gate(rng):
    bm = bmesh.new()
    # THE GATE: the one asymmetric landmark on a circular arena, and the
    # bearing the challengers arrive on. With the camera orbiting, it is what
    # tells the player which way they are facing.
    a = PY_GATE_BEARING
    cx, cy = math.cos(a) * (PY_PATH_R - 6.0), math.sin(a) * (PY_PATH_R - 6.0)
    across = Vector((-math.sin(a), math.cos(a), 0))
    for side in (-1, 1):
        base = Vector((cx, cy, PY_PATH_Z)) + across * (side * 15.0)
        tip = base + Vector((0, 0, 32.0)) + across * (side * -2.5)
        cone(bm, tuple(base), tuple(tip), 4.4, sides=6)
        box(bm, tuple(base + Vector((0, 0, 3.0))), (9.0, 9.0, 6.0), Matrix.Rotation(a + rng.uniform(-0.1, 0.1), 3, "Z"))
    fallen = Vector((cx, cy, PY_PATH_Z + 1.4)) - Vector((math.cos(a), math.sin(a), 0)) * 17.0
    box(bm, tuple(fallen), (28.0, 6.5, 2.8), Matrix.Rotation(a + 0.12, 3, "Z"))
    return finish("PyreliskArena_Gate", bm, PY_OBSIDIAN)


def build_py_bones(rng):
    bm = bmesh.new()
    # Something the size of the boss died on this rim once: the scale
    # reference a five-stud player reads before the fight starts.
    a = PY_GATE_BEARING + math.radians(147)
    cx, cy = math.cos(a) * 180.0, math.sin(a) * 180.0
    along = Vector((math.cos(a + math.pi / 2), math.sin(a + math.pi / 2), 0))
    for i in range(7):
        t = i / 6
        base = Vector((cx, cy, PY_PATH_Z - 1.0)) + along * ((t - 0.5) * 56.0)
        height = 15.0 * math.sin(math.pi * (0.25 + t * 0.6)) + 6.0
        curl = Vector((math.cos(a), math.sin(a), 0)) * (5.0 + t * 4.0)
        cone(bm, tuple(base), tuple(base + curl + Vector((0, 0, height))), rng.uniform(1.5, 2.3), sides=5)
    box(bm, (cx, cy, PY_PATH_Z + 0.6), (58.0, 3.2, 2.2), Matrix.Rotation(a + math.pi / 2, 3, "Z"))
    return finish("PyreliskArena_BoneDeco", bm, PY_BONE)


def build_py_vents(rng):
    bm = bmesh.new()
    # Fumaroles along the lake edge and the lip foot: dressing, non-collide by
    # the Deco name, and where the client's steam hooks go.
    for band in ((PY_LAKE_R + 4.0, PY_LAKE_R + 11.0, 16), (PY_PATH_R - 14.0, PY_PATH_R - 5.0, 12)):
        low, high, count = band
        for i in range(count):
            a = (i / count) * TAU + rng.uniform(-0.11, 0.11)
            r = rng.uniform(low, high)
            x, y = math.cos(a) * r, math.sin(a) * r
            cone(bm, (x, y, PY_PATH_Z - 0.4), (x, y, PY_PATH_Z + rng.uniform(1.5, 3.2)), rng.uniform(1.5, 2.6), sides=6)
    return finish("PyreliskArena_VentDeco", bm, PY_ASH)


def build_py_cloud(rng):
    bm = bmesh.new()
    # THE TRICK, and it only works if the deck never reads as a floor. A flat
    # plane at a uniform height IS a floor no matter what colour it is, so the
    # surface rolls: long swells with billows riding them, deep troughs
    # between, so flat shading gives every lump a lit top and a grey flank.
    # It hides the flank's cut, the sea, and the whole lower mountain - the
    # player never sees the bottom of anything, so the volcano is as tall as
    # they assume it is. The 2048-stud part cap is why it stops at r980; past
    # that it is the arena fog's job.
    def swell(x, y):
        return (
            math.sin(x / 165.0) * math.cos(y / 148.0) * 26.0
            + math.sin((x + y) / 96.0) * 14.0
            + math.cos((x - y * 0.7) / 63.0) * 8.0
        )

    def deck_z(r):
        return PY_CLOUD_Z + 38.0 * ((r - 430.0) / (PY_CLOUD_R - 430.0))

    angles = 84
    radii = [430.0, 500.0, 580.0, 670.0, 770.0, 880.0, PY_CLOUD_R]
    grid = []
    for radius in radii:
        ring = []
        for k in range(angles):
            a = (k / angles) * TAU
            rr = radius * (1.0 + rng.uniform(-0.012, 0.012))
            x, y = math.cos(a) * rr, math.sin(a) * rr
            # The inner ring stays put so the deck always meets the rock.
            lift = 0.0 if radius <= 430.0 else swell(x, y) + rng.uniform(-2.0, 2.0)
            ring.append(bm.verts.new((x, y, deck_z(rr) + lift)))
        grid.append(ring)
    for a, b in zip(grid, grid[1:]):
        for k in range(angles):
            m = (k + 1) % angles
            bm.faces.new((a[k], b[k], b[m], a[m]))
    # Billows riding the swell: ROUNDED, not pancakes - a cloud sea is lumps
    # with shadowed sides, and that value range is the whole read.
    for _ in range(190):
        a = rng.uniform(0, TAU)
        r = rng.uniform(445.0, PY_CLOUD_R - 40.0)
        x, y = math.cos(a) * r, math.sin(a) * r
        base = deck_z(r) + swell(x, y)
        size = rng.uniform(70.0, 210.0)
        # add_blob, not rock: a cloud is ROUND. rock()'s jittered icosphere is
        # the shape language of shattered stone, which is exactly why the first
        # pass of this deck read as a gravel plain.
        add_blob(
            bm,
            (x, y, base + rng.uniform(0.0, 22.0)),
            (size, size * rng.uniform(0.7, 1.2), size * rng.uniform(0.30, 0.58)),
            0.14,
            rng.random() * 100.0,
            yaw=rng.uniform(0, TAU),
            subdiv=2,
        )
    return _py_glow(finish("PyreliskArena_CloudDeco", bm, PY_CLOUD), 0.35)


def _py_probe(objects, radius, bearings=8):
    """THE FLOOR AT A RADIUS, MEASURED - `BossArenaService.floorY`'s question
    asked of the built meshes instead of of the constants.

    The caldera split is only allowed to change the arena's SHAPE, never its
    heights: at `PyreliskCaldera = 0` the lake floor has to stand exactly where
    `build_py_base`'s centre disc stood, or every consumer that reads a height
    off this arena (the boss's footing, the drop-in ring, the cutscene lane's
    framing at r 170) moves with it and none of them says so. A constant cannot
    prove that. A ray can, so this casts one down every bearing and returns the
    highest surface that is not `_Lava` (HAZARD_MARKERS: it never collides) and
    not `_CloudDeco` (dressing, 300 studs under the rim)."""
    best = None
    for k in range(bearings if radius > 0.0 else 1):
        a = (k / float(bearings)) * TAU
        x, y = math.cos(a) * radius, math.sin(a) * radius
        origin, down = Vector((x, y, 4000.0)), Vector((0.0, 0.0, -1.0))
        for obj in objects:
            if "_Lava" in obj.name or "_CloudDeco" in obj.name:
                continue
            hit, location, _normal, _index = obj.ray_cast(origin, down)
            if hit and (best is None or location.z > best):
                best = location.z
    return best


def build_pyrelisk():
    rng = random.Random(6271)
    objects = [
        build_py_base(rng),
        build_py_lake_floor(rng),
        build_py_shaft(rng),
        build_py_lava(rng),
        build_py_seams(rng),
        *build_py_plates(rng),
        build_py_lip(rng),
        build_py_teeth(rng),
        build_py_flank(rng),
        build_py_gate(rng),
        build_py_bones(rng),
        build_py_vents(rng),
        build_py_cloud(rng),
    ]
    print("HANDOFF pyrelisk: RIM PATH at mesh z 0, DEAD FLAT, walkable r %.0f..%.0f (112 studs wide)" % (PY_LAKE_R, PY_PATH_R))
    print(
        "HANDOFF pyrelisk: but the OUTER %.0f studs (r %.0f..%.0f) are under the lip's undercut - floor is still"
        " flat there, ceiling drops to ~6. Aim ground attacks at r <= %.0f so a telegraph never lands under a roof"
        % (PY_PATH_R - PY_CLEAR_R, PY_CLEAR_R, PY_PATH_R, PY_CLEAR_R)
    )
    print("HANDOFF pyrelisk: caldera lava lake r %.0f, flush - the moat; the colossus stands in it" % PY_LAKE_R)
    # MEASURED, not derived. This line used to print PY_FLANK_BOTTOM - 2, on
    # the assumption that the flank's cut is the lowest thing in the model. It
    # is not: the cloud deck's billows hang ~75 studs below it, so the bbox
    # bottom BossArenaService actually pins is lower than the constant said.
    # A number computed from a constant is a claim about the build; this one
    # asks the build.
    low = min(min(v.co[2] for v in obj.data.vertices) for obj in objects)
    print("HANDOFF pyrelisk: mesh bbox bottom z %.1f (MEASURED across every object - the cloud billows, not the flank)" % low)
    print(
        "HANDOFF pyrelisk: SET BossArenas meshBottom = %.1f - that puts the rim path at world Y +%.1f,"
        " the flank's cut under the waterline, and the cloud deck clear above it"
        % (PY_RIM_WORLD_Y + low, PY_RIM_WORLD_Y)
    )
    # ---- the caldera split (slice 5/6), and its equivalence proof.
    print(
        "HANDOFF pyrelisk: CALDERA SPLIT - `_Base` is an ANNULUS from r %.0f outward; `_LakeFloor` (r %.0f, top"
        " z %.2f, %.1f thick) closes the hole and is what `PyreliskCaldera = 1` switches off; `_Shaft` is a"
        " tube, bore r %.0f, outer r %.0f, z %.1f down to %.1f, WALLS ONLY and no floor"
        % (
            PY_BASE_INNER_R,
            PY_LAKE_R,
            PY_PATH_Z,
            PY_LAKE_FLOOR_THICK,
            PY_SHAFT_R,
            PY_BASE_INNER_R,
            PY_PATH_Z,
            PY_SHAFT_BOTTOM,
        )
    )
    print(
        "HANDOFF pyrelisk: COLLISION - `PyreliskArena_Shaft` REQUIRES PreciseConvexDecomposition. It is a hollow"
        " tube; a default hull fills it solid, and a solid shaft is a caldera that opens onto rock - act four"
        " unreachable, with nothing in any log to say so. `_Rim` still owes the same setting"
    )
    print(
        "HANDOFF pyrelisk: SET BossArenas.volcano.caldera.landing = Vector3.new(0, %.1f, 0) - arena-local, the"
        " shaft's foot on the arena's own floor datum (world Y %.1f with meshBottom %.1f)"
        % (PY_SHAFT_BOTTOM, PY_RIM_WORLD_Y + PY_SHAFT_BOTTOM, PY_RIM_WORLD_Y + low)
    )
    # THE EQUIVALENCE PROOF the cutscene lane was promised. Same five radii,
    # same instrument, before and after the split: if any of these five moves,
    # the split moved the floor and every framing and footing measured off this
    # arena moved with it.
    for radius in (0.0, 60.0, 118.0, 170.0, 200.0):
        surface = _py_probe(objects, radius)
        print(
            "HANDOFF pyrelisk: CALDERA EQUIVALENCE probe r %5.1f -> floor z %s (at Caldera = 0; pre-split this"
            " arena answered 0.000 / 0.000 / 0.000 / 0.040 / 2.800 at these five radii)"
            % (radius, "%.3f" % surface if surface is not None else "<none>")
        )
    print("HANDOFF pyrelisk: BossArenaService.ringPositions lands players at WATER_Y+3.5 - it MUST probe the rim path instead")
    print("HANDOFF pyrelisk: ARENA FOG REQUIRED (~1800 studs) or the sea reappears past the cloud deck's edge")
    print("HANDOFF pyrelisk: CloudDeco spans ~1980 studs - deliberately under the 2048 MeshPart cap; keep billow size + radius under it")
    print("HANDOFF pyrelisk: seam rings (the telegraph dial) at r %s" % ", ".join("%.0f" % r for r in PY_SEAM_RINGS))
    print(
        "HANDOFF pyrelisk: lip crest %.1f, OVERHANGS to r %.0f - unclimbable; five vista notches drop it to %.1f"
        % (PY_LIP_CREST, PY_PATH_R - 3.0, PY_NOTCH_CREST)
    )
    print(
        "HANDOFF pyrelisk: notch bearings %s deg - a %.1f kerb needs the fight's jump lock, or invisible barriers"
        % (", ".join("%.0f" % b for b in PY_NOTCH_BEARINGS), PY_NOTCH_CREST)
    )
    print("HANDOFF pyrelisk: gate (arrival landmark) on bearing %.0f deg" % math.degrees(PY_GATE_BEARING))
    return objects


# ------------------------------------------------------- pyrelisk heart room
#
# ACT FOUR. `PyreliskHeart_*`, a SEPARATE MESH and a SEPARATE PLACE - the
# chamber under the caldera, reached by falling down `PyreliskArena_Shaft` and
# then by a teleport, exactly as the Kraken's gullet is reached through the
# siphon. Authored about its OWN origin, with z = 0 as the FLOOR DATUM and not
# the waterline, and placed 600 studs up for the gullet's reason rather than by
# analogy with it: the ocean is a solid slab whose top face is `World.WATER_Y`
# and nothing carves under an arena, so a sealed room at sea level is filled to
# the brim and walked across.
#
# THE ROOM IS A SHOOTING GALLERY WITH COVER, which is why it is smaller than
# the gullet's open dish: r 96 playable with the floor running out to 108 so
# there is no crack at the wall foot. Eight obsidian pillars stand on authored
# collars between r 44 and r 70, and SIX WALL VENTS at r 92 are what shoots at
# you from three different heights.
#
# THE SPONSON RULE, borrowed off the Wrack's casemates and applied to cover
# rather than to occlusion: NO TWO PILLARS STAND ON THE SAME LINE FROM THE
# ENTRY PAD. A pillar hidden behind another one is a pillar that is not cover,
# and the failure is silent - the room still looks like it has eight of them.
# `_ph_sponson_check` measures the bearings off the built sites and fails the
# build rather than trusting the table, the way `_py_expose_neck_core` does on
# the body.
#
# Deterministic, and no `bmesh.ops.solidify` anywhere near it: solidify
# re-orders geometry between runs, which is what cost the gullet builders their
# byte-stable re-export before their walls were authored as two shells.

PH_R = 96.0  # wall half-width at the floor - the playable footprint
PH_FLOOR_R = 108.0  # ...and the floor runs past it, so there is no crack at the foot
PH_H = 72.0  # apex
PH_ENTRY = (0.0, -74.0)  # the landing: Roblox-rel (0, ., +74), heart dead ahead
PH_ENTRY_R = 11.0
PH_DAIS_R = 24.0
PH_HEART_Z = 22.0  # the mass' centre over the floor datum - it SITS ON the dais, see build_ph_heart
PH_WALL_THICK = 9.0

# THE EIGHT PILLAR FEET: (radius, bearing). Radii are all different and the
# bearings are staggered - see the sponson rule above, and `_ph_sponson_check`,
# which is the thing that actually holds this table honest.
PH_SOCKETS = (
    (64.0, 6.0),
    (52.0, 40.0),
    (48.0, 97.0),
    (44.0, 134.0),
    (56.0, 185.0),
    (68.0, 226.0),
    (70.0, 292.0),
    (60.0, 330.0),
)

# THE SIX SHOOTERS: (bearing, height over the floor datum). Three heights, two
# vents each, spread round the wall - the design's y 14 / 26 / 38. The heights
# are the point: a glob thrown from 38 studs up clears the pillar a glob thrown
# from 14 does not.
#
# THE DESIGN'S "r 92" IS A CYLINDER'S NUMBER AND THIS ROOM IS A DOME. At y 38
# the wall has already turned in to ~87, so a vent authored at a flat 92 is
# OUTSIDE the room: buried in rock, invisible from every camera, and throwing
# its globs from a point no player can ever see or take cover from. The
# radius is MEASURED off the wall profile at each vent's own height instead
# (`_ph_wall_at`), and the measurements are printed. `PH_VENT_INSET` is how far
# inboard of the wall the mouth stands.
PH_VENT_INSET = 4.0
PH_VENTS = (
    (20.0, 14.0),
    (80.0, 26.0),
    (140.0, 38.0),
    (200.0, 14.0),
    (260.0, 26.0),
    (320.0, 38.0),
)

# THE VALUE LADDER, and it is the Pyrelisk's own palette rather than a new one:
# the FLOOR is basalt and is the brightest big surface, the walls are obsidian
# and sit deliberately under it (so what you fight on is never the darkest
# thing in frame), and the only things above the floor are the magma - the
# heart, the veins, the vent mouths. Nothing in here is lit by a sky, because
# there is not one.
PH_FLOOR_COL = PY_BASALT
PH_WALL_COL = PY_OBSIDIAN
PH_COLLAR = (0.471, 0.180, 0.078)  # the pillar collars: scorched rock, 120/46/20
PH_CRUST = PY_CRUST  # the heart's cooled shell
PH_RUBBLE = (0.105, 0.100, 0.128)  # shattered obsidian, just off the wall


def _ph_wall_r(angle):
    """The dome's radius at a bearing. FACETED, not lumpy: obsidian breaks
    conchoidally into flat plates, so the radius is quantised into 15 facets
    with a per-facet offset instead of being run through smooth noise. That is
    the whole difference between "a cave" and "the inside of a glass volcano"."""
    facets = 15
    index = int((angle % TAU) / (TAU / facets))
    plate = noise.noise(Vector((index * 3.7, 1.5, 8.0))) * 5.5
    return PH_R + plate


def _ph_wall_at(angle, z):
    """The dome's INNER radius at a bearing AND A HEIGHT - `build_ph_walls`'
    own profile solved for z, so anything sited on the wall is sited on the
    wall that was built rather than on the cylinder the design sketched."""
    t = min(max(z, 0.0) / PH_H, 1.0) ** (1.0 / 0.95)
    phi = math.asin(min(t, 1.0))
    return _ph_wall_r(angle) * math.cos(phi) ** 0.62


def _ph_floor(x, y):
    """A shallow dish with a crust on it - uneven, never so uneven it eats a
    jump, and the eight pools the pillars leave behind have to stay walkable
    around."""
    radius = math.hypot(x, y)
    dish = -1.2 + 3.6 * (min(radius, PH_R) / PH_R) ** 2
    lump = noise.noise(Vector((x * 0.021, y * 0.021, 3.1))) * 2.2
    lump += noise.noise(Vector((x * 0.062, y * 0.062, 7.7))) * 0.8
    return dish + lump


def _ph_at(radius, degrees):
    angle = math.radians(degrees)
    return math.cos(angle) * radius, math.sin(angle) * radius


def _ph_sponson_check():
    """THE GATE ON THE COVER. Bearings from the ENTRY PAD to each of the eight
    sockets, measured off the sites the build actually uses; the build fails if
    any two are within 8 degrees of each other, which is where one pillar starts
    standing in another's shadow. Also fails if a collar reaches the entry pad
    or the dais, because a pillar merged into either is not cover either."""
    sites = [_ph_at(radius, bearing) for radius, bearing in PH_SOCKETS]
    bearings = sorted(math.degrees(math.atan2(y - PH_ENTRY[1], x - PH_ENTRY[0])) % 360.0 for x, y in sites)
    gap = min((bearings[(i + 1) % len(bearings)] - bearings[i]) % 360.0 for i in range(len(bearings)))
    if gap < 8.0:
        raise SystemExit("pyrelisk heart: two pillars %.2f deg apart from the entry pad - the sponson rule" % gap)
    near_pad = min(math.dist(site, PH_ENTRY) for site in sites)
    if near_pad < PH_ENTRY_R + 9.0:
        raise SystemExit("pyrelisk heart: a pillar collar reaches the entry pad (%.2f studs)" % near_pad)
    near_dais = min(math.hypot(*site) for site in sites)
    if near_dais < PH_DAIS_R + 9.0:
        raise SystemExit("pyrelisk heart: a pillar collar reaches the dais (%.2f studs)" % near_dais)
    return gap, near_pad, near_dais


def build_ph_base(rng):
    """The chamber floor, and the anchor part - `placeAuthored` centres
    `<model>_Base` on the arena row's `center`, so THIS object is what decides
    where the room stands."""
    bm = bmesh.new()
    radii = [14.0, 30.0, 46.0, 62.0, 78.0, 92.0, PH_R, PH_FLOOR_R]
    angles = 44
    grid = []
    for radius in radii:
        ring = []
        for i in range(angles):
            angle = (i / angles) * TAU
            x, y = math.cos(angle) * radius, math.sin(angle) * radius
            z = _ph_floor(x, y) if radius <= PH_R else _ph_floor(x, y) + (radius - PH_R) * 0.5
            ring.append(bm.verts.new((x, y, z)))
        grid.append(ring)
    hub = bm.verts.new((0.0, 0.0, _ph_floor(0.0, 0.0)))
    for i in range(angles):
        j = (i + 1) % angles
        bm.faces.new((hub, grid[0][i], grid[0][j]))
    for lo, hi in zip(grid, grid[1:]):
        for i in range(angles):
            j = (i + 1) % angles
            bm.faces.new((lo[i], lo[j], hi[j], hi[i]))
    under = []
    for i in range(angles):
        angle = (i / angles) * TAU
        under.append(bm.verts.new((math.cos(angle) * (PH_FLOOR_R - 5.0), math.sin(angle) * (PH_FLOOR_R - 5.0), -14.0)))
    keel = bm.verts.new((0.0, 0.0, -14.0))
    for i in range(angles):
        j = (i + 1) % angles
        bm.faces.new((grid[-1][i], grid[-1][j], under[j], under[i]))
        bm.faces.new((keel, under[j], under[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    _ = rng
    return finish("PyreliskHeart_Base", bm, PH_FLOOR_COL)


def build_ph_walls(rng):
    """The dome, as TWO SHELLS bridged at the foot - the gullet's construction,
    for the gullet's reason: `bmesh.ops.solidify` re-orders its output between
    runs and breaks the byte-stable re-export this file's contract requires.

    PRECISECONVEXDECOMPOSITION IS REQUIRED. It is a hollow dome; a default
    convex hull fills the room solid. Being a closed solid it also renders
    correctly FROM INSIDE, which is the only place any camera in this arena ever
    stands - every frame shot from outside it comes back black."""
    bm = bmesh.new()
    angles, levels = 45, 9
    rings = []
    foot = []
    for i in range(angles):
        angle = (i / angles) * TAU
        radius = _ph_wall_r(angle) + 4.0
        foot.append(Vector((math.cos(angle) * radius, math.sin(angle) * radius, -13.0)))
    rings.append(foot)
    for level in range(levels):
        t = level / float(levels)
        phi = t * (math.pi / 2.0)
        ring = []
        for i in range(angles):
            angle = (i / angles) * TAU
            # ^0.62 rather than the gullet's ^0.78: the wall stands up STRAIGHTER
            # before it turns over, which is what makes the room read as a
            # shaft with a lid instead of as a bubble - and it is what puts a
            # vent at y 38 on a wall rather than on a ceiling.
            radius = _ph_wall_r(angle) * math.cos(phi) ** 0.62
            z = PH_H * math.sin(phi) ** 0.95
            ring.append(Vector((math.cos(angle) * radius, math.sin(angle) * radius, z)))
        rings.append(ring)

    def outward(point):
        direction = Vector((point.x, point.y, point.z * 0.5))
        if direction.length < 1e-6:
            direction = Vector((0.0, 0.0, 1.0))
        return point + direction.normalized() * PH_WALL_THICK

    in_rings = [[bm.verts.new(p) for p in ring] for ring in rings]
    out_rings = [[bm.verts.new(outward(p)) for p in ring] for ring in rings]
    in_apex = bm.verts.new((0.0, 0.0, PH_H))
    out_apex = bm.verts.new((0.0, 0.0, PH_H + PH_WALL_THICK))
    for shell, apex in ((in_rings, in_apex), (out_rings, out_apex)):
        for lo, hi in zip(shell, shell[1:]):
            for i in range(angles):
                j = (i + 1) % angles
                bm.faces.new((lo[i], lo[j], hi[j], hi[i]))
        for i in range(angles):
            j = (i + 1) % angles
            bm.faces.new((shell[-1][i], shell[-1][j], apex))
    for i in range(angles):
        j = (i + 1) % angles
        bm.faces.new((in_rings[0][i], in_rings[0][j], out_rings[0][j], out_rings[0][i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    _ = rng
    return finish("PyreliskHeart_Walls", bm, PH_WALL_COL)


def build_ph_dais(rng):
    """Two obsidian steps under the heart, so "on the dais" and "off it" are
    two readable places and the heart stands clear of the pools."""
    bm = bmesh.new()
    ground = _ph_floor(0.0, 0.0)
    tapered_cylinder(bm, ground - 2.0, ground + 1.6, PH_DAIS_R, PH_DAIS_R - 2.0, sides=24)
    tapered_cylinder(bm, ground + 1.6, ground + 3.4, PH_DAIS_R - 5.0, PH_DAIS_R - 7.2, sides=24)
    # Shards stood up round the upper step, gapped in four places so there are
    # four ways onto it.
    for i in range(24):
        angle = (i / 24.0) * TAU
        if i % 6 == 2:
            continue
        cx, cy = math.cos(angle) * (PH_DAIS_R - 6.4), math.sin(angle) * (PH_DAIS_R - 6.4)
        cone(bm, (cx, cy, ground + 3.0), (cx + math.cos(angle) * 0.8, cy + math.sin(angle) * 0.8, ground + 6.2), 1.7, sides=4)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    _ = rng
    return finish("PyreliskHeart_Dais", bm, PH_WALL_COL)


def build_ph_heart(rng):
    """THE MASS. A cooled crust over something that is obviously still molten -
    the crust is this object and the molten part is `_HeartGlow`, which stands
    PROUD of it. Slung on four basalt columns that run into the roof, so it
    reads as held rather than as placed."""
    bm = bmesh.new()
    ground = _ph_floor(0.0, 0.0)
    add_blob(bm, (0.0, 0.0, ground + PH_HEART_Z), (16.0, 14.0, 17.0), 0.38, salt=3.3, subdiv=2)
    add_blob(bm, (0.0, -6.0, ground + PH_HEART_Z + 7.5), (9.0, 7.5, 8.5), 0.32, salt=8.8, subdiv=2)
    for i in range(4):
        angle = (i / 4.0) * TAU + 0.55
        top = Vector((math.cos(angle) * 22.0, math.sin(angle) * 22.0, PH_H * 0.88))
        taper_between(
            bm,
            (math.cos(angle) * 7.5, math.sin(angle) * 7.5, ground + PH_HEART_Z + 9.0),
            top,
            4.4,
            2.6,
            sides=6,
        )
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    _ = rng
    return finish("PyreliskHeart_Heart", bm, PH_CRUST)


def build_ph_heart_glow(rng):
    """THE MOLTEN PART, and it stands 1.5 studs PROUD of the crust rather than
    sitting inside it. `build_kg_heart_glow`'s lesson, one arena over: a Neon
    blob authored SMALLER than the mass around it is a light nobody can ever
    see, and it is the silent-absence shape exactly - the object is in the file,
    in the colour table and in the import, and the room is still dark."""
    bm = bmesh.new()
    ground = _ph_floor(0.0, 0.0)
    # FOUR plates, not five, and half as thick. The first pass ran five at 2.7
    # and they closed over each other: the whole mass read as one bright blob
    # and the crust it is supposed to be cracking through never appeared.
    for i in range(4):
        yaw = i * (math.pi / 4.0)
        add_blob(bm, (0.0, 0.0, ground + PH_HEART_Z), (17.2, 1.5, 18.1), 0.18, salt=3.3 + i, yaw=yaw, subdiv=2)
    add_blob(bm, (0.0, -6.0, ground + PH_HEART_Z + 7.5), (9.9, 1.3, 9.4), 0.15, salt=9.4, yaw=0.5, subdiv=2)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    _ = rng
    return _py_glow(finish("PyreliskHeart_HeartGlow", bm, PY_MAGMA), 1.0)


def build_ph_entry(rng):
    """THE LANDING. Where the shaft puts the party down, 74 studs out with the
    heart dead ahead - far enough back that the first thing anyone does is LOOK
    at it, and off every pillar's bearing so the first look is not blocked."""
    bm = bmesh.new()
    x, y = PH_ENTRY
    ground = _ph_floor(x, y)
    tapered_cylinder(bm, ground - 1.8, ground + 1.4, PH_ENTRY_R, PH_ENTRY_R - 1.2, sides=16, center=(x, y))
    for i in range(5):
        angle = (i / 5.0) * TAU + 0.3
        cx, cy = x + math.cos(angle) * (PH_ENTRY_R - 0.7), y + math.sin(angle) * (PH_ENTRY_R - 0.7)
        cone(bm, (cx, cy, ground + 1.1), (cx, cy, ground + 4.0), 1.3, sides=4)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    _ = rng
    return finish("PyreliskHeart_EntryPad", bm, PH_COLLAR)


def build_ph_socket(index, rng):
    """One pillar foot: a scorched collar with a snapped obsidian butt standing
    in it. The PILLAR is a runtime creature planted on this collar (`Bosses.
    items.pyrelisk_heart.parts.at = "sockets"`), so what the mesh owes is the
    seat, the landmark, and the vent the pool comes out of when it breaks."""
    radius, bearing = PH_SOCKETS[index]
    x, y = _ph_at(radius, bearing)
    ground = _ph_floor(x, y)
    bm = bmesh.new()
    tapered_cylinder(bm, ground - 1.6, ground + 1.8, 8.2, 6.8, sides=12, center=(x, y))
    # The snapped butt - four canted plates, so the foot reads as a COLUMN that
    # is standing there rather than as a manhole cover.
    for i in range(4):
        angle = (i / 4.0) * TAU + index * 0.4
        cx, cy = x + math.cos(angle) * 2.6, y + math.sin(angle) * 2.6
        taper_between(
            bm,
            (cx, cy, ground + 1.2),
            (cx + math.cos(angle) * 0.9, cy + math.sin(angle) * 0.9, ground + 6.4 + (index % 3) * 0.8),
            2.9,
            1.9,
            sides=4,
        )
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    _ = rng
    return finish("PyreliskHeart_Socket%d" % (index + 1), bm, PH_COLLAR)


def build_ph_vent(index, rng):
    """ONE WALL VENT - a glowing muzzle in the obsidian, and the ORIGIN a glob
    is actually thrown from (`Fn.pyreliskHeartVents` hands it to `Fn.throwGlob`
    as that glob's last argument). There are six, at three heights.

    NAMED `_Vent%dGlow`. The design's object list calls these `_Vent1..6` and
    its import row says they "carry Glow and go Neon" - which cannot both be
    true, because `BossArenaService.isGlow` matches the marker in the NAME and
    nothing else. The name below satisfies both readings: it still contains
    `_Vent%d`, and it carries the marker, so the muzzle arrives Neon by the same
    rule as every other glow in the project instead of by a hand-set property
    somebody has to remember on every re-import."""
    bearing, height = PH_VENTS[index]
    angle = math.radians(bearing)
    bm = bmesh.new()
    # Cut back INTO the wall and flare inward, so the mouth is a hole in rock
    # rather than a pipe stuck onto it. Both ends are measured off the wall AT
    # THIS HEIGHT - see PH_VENT_INSET.
    wall = _ph_wall_at(angle, height)
    back = Vector((math.cos(angle) * (wall + 2.0), math.sin(angle) * (wall + 2.0), height + 1.6))
    mouth = Vector(
        (math.cos(angle) * (wall - PH_VENT_INSET), math.sin(angle) * (wall - PH_VENT_INSET), height)
    )
    taper_between(bm, back, mouth, 2.0, 4.0, sides=7)
    # A short tongue of spill running down the wall under the mouth: the vents
    # are the only thing that lights the wall itself. It FOLLOWS the wall down,
    # which on a dome means outward, so the spill lies on the rock instead of
    # hanging off it.
    prev = mouth
    for step in range(1, 5):
        z = height - 3.4 * step
        radius = _ph_wall_at(angle, z) - 2.6
        drop = Vector((math.cos(angle) * radius, math.sin(angle) * radius, z))
        taper_between(bm, prev, drop, 3.0 - 0.55 * step, 2.6 - 0.55 * step, sides=5)
        prev = drop
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    _ = rng
    return _py_glow(finish("PyreliskHeart_Vent%dGlow" % (index + 1), bm, PY_MAGMA), 0.8)


def build_ph_veins(rng):
    """THE ROOM'S LIGHT AND ITS BREADCRUMB. Magma in the floor's cracks, running
    from the entry pad and from each collar into the dais, and up the wall
    facets' seams - so from the landing there is a lit line to every pillar and
    a lit line to the heart, in a room with no sky and no sun."""
    bm = bmesh.new()

    def creep(start, end, width0, width1, steps):
        prev = None
        for step in range(steps + 1):
            t = step / float(steps)
            x = start[0] + (end[0] - start[0]) * t
            y = start[1] + (end[1] - start[1]) * t
            wob = noise.noise(Vector((x * 0.05, y * 0.05, 12.0))) * 3.2 * math.sin(t * math.pi)
            x, y = x + wob, y - wob
            here = Vector((x, y, _ph_floor(x, y) + 0.35))
            if prev is not None:
                taper_between(bm, prev, here, width0 + (width1 - width0) * t, width0 + (width1 - width0) * t, sides=4)
            prev = here
    for radius, bearing in PH_SOCKETS:
        creep(_ph_at(radius, bearing), _ph_at(PH_DAIS_R - 2.0, bearing), 0.62, 0.45, 7)
    creep(PH_ENTRY, (0.0, -(PH_DAIS_R - 2.0)), 0.85, 0.6, 8)
    # Up the wall, on the facet seams: fifteen facets, so fifteen seams.
    for k in range(15):
        bearing = (k / 15.0) * TAU + (TAU / 30.0)
        radius = _ph_wall_r(bearing) * 0.985
        prev = None
        for step in range(10):
            t = step / 9.0
            phi = t * (math.pi / 2.0) * 0.88
            rad = radius * math.cos(phi) ** 0.62
            here = Vector((math.cos(bearing) * rad, math.sin(bearing) * rad, PH_H * math.sin(phi) ** 0.95))
            if prev is not None:
                taper_between(bm, prev, here, 0.85 - 0.5 * t, 0.8 - 0.5 * t, sides=4)
            prev = here
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    _ = rng
    return _py_glow(finish("PyreliskHeart_VeinGlow", bm, PY_SEAM), 0.8)


def build_ph_rubble(rng):
    """Shattered obsidian round the foot of the wall - what falls off a chamber
    like this one. Deco, so it loses collision and query at placement and
    cannot catch a foot in a room whose whole mechanic is running between
    pillars."""
    bm = bmesh.new()
    for _ in range(52):
        bearing = rng.uniform(0.0, 360.0)
        radius = rng.uniform(74.0, PH_R - 2.0)
        x, y = _ph_at(radius, bearing)
        if math.hypot(x - PH_ENTRY[0], y - PH_ENTRY[1]) < PH_ENTRY_R + 6.0:
            continue
        ground = _ph_floor(x, y)
        rot = Matrix.Rotation(rng.uniform(0.0, TAU), 3, "Z") @ Matrix.Rotation(rng.uniform(-0.5, 0.5), 3, "X")
        box(bm, (x, y, ground + 0.6), (rng.uniform(3.0, 9.0), rng.uniform(1.6, 4.0), rng.uniform(0.8, 2.6)), rot)
        if rng.random() < 0.45:
            cone(
                bm,
                (x, y, ground),
                (x + rng.uniform(-2.5, 2.5), y + rng.uniform(-2.5, 2.5), ground + rng.uniform(3.0, 8.0)),
                rng.uniform(1.0, 2.2),
                sides=4,
            )
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("PyreliskHeart_RubbleDeco", bm, PH_RUBBLE)


def build_pyrelisk_heart():
    rng = random.Random(41109)
    gap, near_pad, near_dais = _ph_sponson_check()
    sockets = [build_ph_socket(i, rng) for i in range(len(PH_SOCKETS))]
    vents = [build_ph_vent(i, rng) for i in range(len(PH_VENTS))]
    objects = [
        build_ph_base(rng),
        build_ph_walls(rng),
        build_ph_dais(rng),
        build_ph_heart(rng),
        build_ph_heart_glow(rng),
        build_ph_entry(rng),
        *sockets,
        *vents,
        build_ph_veins(rng),
        build_ph_rubble(rng),
    ]
    floor_centre = _ph_floor(0.0, 0.0)
    print(
        "HANDOFF pyrelisk-heart: ACT FOUR is a SEPARATE MESH and a SEPARATE PLACE - `PyreliskHeart_*`, authored"
        " about its own origin, z = 0 is the FLOOR DATUM and NOT the waterline. LIFT IT 600 STUDS (the gullet's"
        " reason: the ocean slab is solid with its top face at World.WATER_Y, so a sealed room at sea level is"
        " filled to the brim)"
    )
    print(
        "HANDOFF pyrelisk-heart: playable footprint r %.0f (floor out to %.0f so there is no crack at the wall"
        " foot), apex z %.0f; floor dish z %.2f at the centre to %.2f at the wall"
        % (PH_R, PH_FLOOR_R, PH_H, floor_centre, _ph_floor(PH_R, 0.0))
    )
    print(
        "HANDOFF pyrelisk-heart: SET BossArenas.pyrelisk_heart.floorRadius = %.0f (the WALKABLE number, which is"
        " what verifyGround and the fallback floor read) and barrier = { radius = %.0f, height = 30 }"
        % (PH_R, PH_R - 2.0)
    )
    pad_top = _ph_floor(*PH_ENTRY) + 1.4
    print(
        "HANDOFF pyrelisk-heart: ENTRY PAD centre (%.1f, %.1f) r %.0f, TOP z %.2f - Roblox-rel (%.1f, %.2f, %.1f)."
        " SET spawnPad = { offset = Vector3.new(%.1f, %.1f, %.1f), radius = %.1f }; the heart is dead ahead at"
        " %.0f studs" % (
            PH_ENTRY[0],
            PH_ENTRY[1],
            PH_ENTRY_R,
            pad_top,
            PH_ENTRY[0],
            pad_top,
            -PH_ENTRY[1],
            PH_ENTRY[0],
            round(pad_top, 1),
            -PH_ENTRY[1],
            PH_ENTRY_R,
            abs(PH_ENTRY[1]),
        )
    )
    print(
        "HANDOFF pyrelisk-heart: DAIS centre (0, 0) r %.0f, top z %.2f; the HEART mass sits on it centred"
        " (0, 0, %.2f) on four columns into the roof" % (PH_DAIS_R, floor_centre + 3.4, floor_centre + PH_HEART_Z)
    )
    heart = next(obj for obj in objects if obj.name == "PyreliskHeart_Heart")
    hx = [v.co[0] for v in heart.data.vertices]
    hy = [v.co[1] for v in heart.data.vertices]
    hz = [v.co[2] for v in heart.data.vertices]
    mass = [v for v in heart.data.vertices if v.co[2] < floor_centre + PH_HEART_Z + 24.0]
    reach = max(math.hypot(v.co[0], v.co[1]) for v in mass)
    print(
        "HANDOFF pyrelisk-heart: HEART bbox x %.2f..%.2f y %.2f..%.2f z %.2f..%.2f (the four columns are what"
        " reaches the roof); MEASURED EFFECTIVE RADIUS of the mass itself %.2f - the hitRadius sanity check."
        " Design 6.2 asks 26 and Addendum N.9 cut it to 13; 26 is a sphere that swallows the dais, 13 sits"
        " INSIDE the mass" % (min(hx), max(hx), min(hy), max(hy), min(hz), max(hz), reach)
    )
    for index, (radius, bearing) in enumerate(PH_SOCKETS):
        x, y = _ph_at(radius, bearing)
        top = _ph_floor(x, y) + 1.8
        print(
            "HANDOFF pyrelisk-heart: Socket%d at r %.0f bearing %.0f deg = (%.2f, %.2f), collar top z %.2f -"
            " ROBLOX rel (%.2f, %.2f, %.2f)" % (index + 1, radius, bearing, x, y, top, x, top, -y)
        )
    for index, (bearing, height) in enumerate(PH_VENTS):
        radius = _ph_wall_at(math.radians(bearing), height) - PH_VENT_INSET
        x, y = _ph_at(radius, bearing)
        print(
            "HANDOFF pyrelisk-heart: Vent%d bearing %.0f deg, height %.0f, MEASURED r %.2f (the wall's own"
            " radius at that height less %.1f - the design's flat 92 is outside the dome above y 26), mouth"
            " (%.2f, %.2f, %.2f) - ROBLOX rel (%.2f, %.2f, %.2f)"
            % (index + 1, bearing, height, radius, PH_VENT_INSET, x, y, height, x, height, -y)
        )
    print(
        "HANDOFF pyrelisk-heart: SPONSON RULE HELD - closest two pillars are %.2f deg apart as seen from the"
        " entry pad (gate fails under 8.0); nearest collar to the pad %.2f studs, to the dais %.2f"
        % (gap, near_pad, near_dais)
    )
    print(
        "HANDOFF pyrelisk-heart: WALL inner radius %.2f at the foot (faceted, 15 plates, %.2f..%.2f) - every"
        " camera and every framing must stand INSIDE it or the frame renders black"
        % (PH_R, min(_ph_wall_r((k / 15.0) * TAU) for k in range(15)), max(_ph_wall_r((k / 15.0) * TAU) for k in range(15)))
    )
    print(
        "HANDOFF pyrelisk-heart: COLLISION - PreciseConvexDecomposition REQUIRED on `_Walls` (a hollow dome; a"
        " default hull fills the room solid) and on `_Base` (a dished floor). Default hull is fine for `_Dais`,"
        " `_EntryPad`, `_Socket1..8` and `_Heart`"
    )
    print(
        "HANDOFF pyrelisk-heart: `_HeartGlow`, `_VeinGlow` and `_Vent1..6Glow` carry the `Glow` marker and go"
        " Neon by BossArenaService.isGlow; `_RubbleDeco` is stripped of collision and query by the Deco rule."
        " NOTE THE VENT NAMES: the design's object list says `_Vent1..6` and its import row says they carry"
        " `Glow`; the exported names are `_Vent1Glow`..`_Vent6Glow`, which satisfies both"
    )
    print(
        "HANDOFF pyrelisk-heart: the room has NO sky and NO sun - it needs WeatherController's own mood plus"
        " the arena lighting override, or the Neon veins are all the player gets (Appendix K item 8)"
    )
    low = min(min(v.co[2] for v in obj.data.vertices) for obj in objects)
    print(
        "HANDOFF pyrelisk-heart: mesh bbox bottom z %.3f (MEASURED across every object; the floor's keel, not"
        " the wall's foot). SET BossArenas.pyrelisk_heart.meshBottom = %.1f, which puts authored z = 0 - the"
        " FLOOR DATUM - at world Y +600.0" % (low, 600.0 + low)
    )
    print(
        "HANDOFF pyrelisk-heart: run `python3 tools/gen_mesh_colors.py` after this import - %d new object names"
        " need MeshColors rows or they arrive at the importer's default grey" % len(objects)
    )
    return objects


# ---------------------------------------------------------------- kraken
#
# THE KRAKEN / the Deckfight and the Gullet (maelstrom boss; the EXTERIOR was
# redesigned twice on 2026-09-08). The first redesign answered "too small and
# doesn't really make sense" with a stone CAUSEWAY out in open water and a
# RING beyond it. The user's answer to that was a different game entirely:
#
#     "maybe make it a pirate ship that you are on and its attacking"
#
# So phases 1 and 2 now happen ON A GALLEON, and the colossus is no longer
# something you approach - it is something that comes over the rail at you
# from both sides at once. The causeway, the six ring arcs, the drowned reef
# and the storm stacks are DELETED, not parked: nothing in this file refers to
# them, and the SCALE CONTRACT is all that survives of them.
#
# Two glbs, because they are still two places:
#
#   arena_kraken.glb        `KrakenArena_*`   the ship - phases 1 and 2
#   arena_kraken_gullet.glb `KrakenGullet_*`  the interior - phase 3, untouched
#
# THE SHIP IS THE ENTIRE PLAYABLE SPACE, and that is the design. 170 long on
# X (bow at +X), 40 in the beam, in three floors:
#
#   PHASE 1 is the WAIST - the main deck between the two castles, x -40..+50,
#   about 90 x 34 of clear planking. One room. You cannot leave it, and you
#   can see every threat in it.
#   PHASE 2 opens the FORECASTLE (+7) and the QUARTERDECK (+9) as well, so the
#   floor gains two levels and 80 more studs of length exactly when the fight
#   needs somewhere else to go.
#
# THE HEAD stands off the PORT BEAM: arena-local (0, +370), 480 studs tall,
# 350 studs off the port rail, on a bearing PERPENDICULAR to the ship's long
# axis. That perpendicularity is inherited from the causeway and it is still
# the whole point - the player's freedom is a LINE and the boss is a wall down
# one side of it - except now the line is a deck with furniture on it and the
# wall has arms coming over both rails.
#
# COVER, and why it is no longer notches. On the causeway, three notches were
# cut into the deck and ducking into one put your head under a sweep. You
# cannot cut a hole in a ship's deck without it being a hatch you fall
# through, so the same mechanic is re-expressed as SWEEP COVER: four solid low
# deck features - two cargo stacks, the capstan, the main hatch coaming - none
# of them near the sweep plane, laid across the waist so every lane through it
# has one. The clearances are MEASURED off the built meshes and printed in the
# HANDOFF, exactly as the notch clearances were.
#
# FOUR WRAP POINTS, two a side, where the arms come over: the bulwark is
# broken by a 12-stud boarding gap at each, and the deck inboard of it carries
# a doubled-planking reinforcement mark. Their coordinates go out in the
# HANDOFF - the wiring lands tentacles on them, and the player learns to read
# them as the four places the fight arrives from.
#
# THE FLOOR OF THE WORLD IS STILL SOLID. WorldService's ocean tiles are 4-stud
# slabs whose top face is exactly WATER_Y and whose comment says outright
# "players still stand on the surface". So a player who goes over this rail
# DOES NOT DROWN: they land on the sea 8 studs down and walk away across it,
# and no mesh in here can stop that. Containment is a WIRING problem - the
# maelstrom's undertow, a BossArenas `barrier` row, or a teleport back aboard.
# The deck-edge coordinates that wiring needs are printed in the HANDOFF,
# because this is still the one thing that will silently break this fight.
#
# PHASE 3, the gullet, is unchanged and lives below: a self-contained cavern
# with no geometric relationship to the exterior, reached by teleport.
#
# Deterministic: seeded random plus mathutils.noise on position only, and no
# bmesh solidify anywhere near it (solidify re-orders geometry between runs,
# which is what cost the gullet builders their byte-stable re-export).

# ---- the scale contract, shared with boss_gen.py's kraken pass
KA_HEAD_H = 480.0
KA_HEAD_W = 360.0
KA_HEAD_AT = (0.0, 370.0)  # head centre, arena-local: dead off the PORT beam
KA_HEAD_RANGE = 350.0  # ...which is this far off the port rail

# ---- the ship. THE ORIGIN IS THE SHIP, and that is a correctness fix rather
# than a preference: BossArenaService.placeAuthored lands `<model>_Base`'s OWN
# centre on the arena row's `center`, and `_Base` here is the hull. Authoring
# the head at the origin the way the causeway did would have put the BOSS
# where the ship is and dragged the deck 370 studs off the arena centre. The
# head is an OFFSET from the ship now, and the offset is printed.
KA_SHIP_LEN = 170.0
KA_SHIP_BEAM = 40.0
KA_KEEL_Z = -14.0

KA_DECK_Z = 8.0  # the main deck - the datum every other height is quoted off
KA_FC_Z = KA_DECK_Z + 7.0  # forecastle, at the bow
KA_QD_Z = KA_DECK_Z + 9.0  # quarterdeck, at the stern, and the spawn
KA_QD_FRONT = -40.0  # the quarterdeck's forward bulkhead
KA_FC_AFT = 50.0  # the forecastle's after bulkhead
# ...so the WAIST - the phase-1 room - is x -40..+50, ninety studs of it.

KA_RAIL_H = 2.8  # bulwark top over its own deck. LOW, and see the sweep note.
KA_RAIL_INSET = 0.9  # bulwark centreline, inboard of the sheer
KA_SWEEP_Z = KA_DECK_Z + 3.0  # THE SWEEP PLANE. Everything else is measured
KA_STAND_HEAD = 5.0  # a standing player's head over the deck
KA_CROUCH_HEAD = 2.6  # ...and a crouched one's

KA_SPAWN_X = -66.0  # the drop-in dais, up on the quarterdeck

# The hull as STATIONS: (x, half beam, keel z, sheer z), bow at +X. The sheer
# runs 7.6 through the waist - a hair UNDER the deck slab's 8.0 top, so the
# hull's own top edge hides beneath the planking instead of z-fighting it -
# and lifts at both ends the way a galleon's does.
KA_STATIONS = [
    (-85.0, 9.4, -5.4, 9.2),
    (-76.0, 12.6, -8.2, 8.6),
    (-64.0, 15.8, -10.6, 8.1),
    (-50.0, 18.2, -12.4, 7.8),
    (-34.0, 19.6, -13.5, 7.6),
    (-16.0, 20.0, -14.0, 7.6),
    (0.0, 19.9, -14.0, 7.6),
    (18.0, 19.1, -13.7, 7.6),
    (36.0, 17.2, -12.8, 7.7),
    (52.0, 14.4, -11.2, 8.1),
    (66.0, 10.8, -8.8, 8.9),
    (76.0, 6.8, -5.8, 9.9),
    (85.0, 2.4, -1.4, 11.0),
]

# THE FOUR WRAP POINTS: (label, x, side), side +1 = PORT (the head's own side)
# and -1 = starboard. STAGGERED on purpose - two arms over opposite rails at
# the same station would own the whole width between them, and the waist has
# to stay survivable with all four of them down.
KA_WRAPS = (
    ("PortAft", -26.0, 1.0),
    ("PortFore", 34.0, 1.0),
    ("StbdAft", -34.0, -1.0),
    ("StbdFore", 22.0, -1.0),
)
KA_GAP_W = 12.0  # the boarding gap cut in the bulwark at each wrap point

# THE SWEEP COVER: (name, x, y, size x, size y, top over the deck). Solid, low,
# and spread so no lane down the waist is coverless. `top` is a CONTRACT, not
# a suggestion: a crate that strayed above the sweep plane would quietly
# delete the mechanic, so build_kraken measures what was actually built.
KA_COVER = (
    ("CoverCargoFore", 38.0, 8.5, 18.0, 9.0, 2.6),
    ("CoverCoaming", 2.0, -1.0, 17.0, 12.0, 2.7),
    ("CoverCapstan", -14.0, 3.0, 11.4, 11.4, 2.5),
    ("CoverCargoAft", -30.0, -9.0, 12.0, 9.5, 2.6),
)

KA_MAIN_MAST = -6.0  # in the middle of the waist, on purpose - see build_ka_masts
KA_FORE_MAST = 60.0  # up on the forecastle

# THE VALUE LADDER. The deck is the datum and the brightest big surface; the
# spawn dais is the one thing brighter than it (a landmark you look for on a
# dark ship); the hull and the castles sit under it; and the canvas and the
# flag are darkest of all, so the arms have a lit sky to be read against.
KA_DECK_COL = (0.290, 0.243, 0.184)  # DECK - the datum
KA_PAD = (0.373, 0.353, 0.310)  # the spawn dais: brightest thing aboard
KA_RAIL = (0.204, 0.169, 0.133)  # bulwarks and the hatch coaming
KA_HULL = (0.129, 0.106, 0.094)  # the hull, well under the deck
KA_CASTLE = (0.165, 0.137, 0.110)  # forecastle and quarterdeck blocks
KA_CARGO = (0.216, 0.180, 0.129)  # crates and barrels
KA_IRON = (0.145, 0.153, 0.169)  # capstan, wheel, straps
KA_CANVAS = (0.192, 0.200, 0.212)  # storm-torn sail
KA_FLAG = (0.047, 0.047, 0.055)  # the black flag - the darkest value aboard
KA_ROPE = (0.243, 0.216, 0.176)  # rigging and cordage
KA_FOAM = (0.596, 0.643, 0.686)
KA_LAMPGLOW = (0.541, 0.831, 0.878)  # the lanterns - the only light aboard


def _ka_station(x):
    """(half beam, keel z, sheer z) anywhere along the hull."""
    if x <= KA_STATIONS[0][0]:
        return KA_STATIONS[0][1:]
    for (x0, h0, k0, s0), (x1, h1, k1, s1) in zip(KA_STATIONS, KA_STATIONS[1:]):
        if x <= x1:
            t = 0.0 if x1 == x0 else (x - x0) / (x1 - x0)
            return (h0 + (h1 - h0) * t, k0 + (k1 - k0) * t, s0 + (s1 - s0) * t)
    return KA_STATIONS[-1][1:]


def _ka_half(x):
    return _ka_station(x)[0]


def _ka_deck_top(x):
    """Which deck you are standing on at a station. Phase 1 only ever sees the
    middle branch; phase 2 opens the other two."""
    if x <= KA_QD_FRONT:
        return KA_QD_Z
    if x >= KA_FC_AFT:
        return KA_FC_Z
    return KA_DECK_Z


def _ka_rail_y(x, side):
    """Bulwark centreline at a station - the deck edge, and the line the
    containment wiring has to fence."""
    return side * (_ka_half(x) - KA_RAIL_INSET)


def _ka_in_gap(x, side):
    """Is this station inside one of the four boarding gaps on this side?"""
    for _label, wrap_x, wrap_side in KA_WRAPS:
        if wrap_side == side and abs(x - wrap_x) <= KA_GAP_W / 2.0:
            return True
    return False


def _ka_wrap_point(index):
    """(x, y, deck z) of one wrap point: on the rail line, at deck level."""
    _label, wrap_x, side = KA_WRAPS[index]
    return wrap_x, _ka_rail_y(wrap_x, side), _ka_deck_top(wrap_x)


def _ka_loft(bm, rings):
    """Stitch a list of equal-length vertex rings into a closed tube and cap
    both ends. The hull, the deck slab and both castles are all this shape."""
    made = []
    width = len(rings[0])
    for a, b in zip(rings, rings[1:]):
        for k in range(width):
            j = (k + 1) % width
            try:
                made.append(bm.faces.new((a[k], a[j], b[j], b[k])))
            except ValueError:
                pass
    for loop, flip in ((rings[0], True), (rings[-1], False)):
        try:
            made.append(bm.faces.new(list(reversed(loop)) if flip else loop))
        except ValueError:
            pass
    return made


def build_ka_base(rng):
    """THE HULL, and `<model>_Base` by contract - BossArenaService centres the
    whole group on this part, which is exactly right when the ship IS the
    arena. Her keel at -14 is also the export's floor: nothing else hangs
    lower, so the measured bbox bottom is a hull number rather than an
    accident of dressing (the Careenage lesson)."""
    bm = bmesh.new()
    rings = []
    for x, half, keel, sheer in KA_STATIONS:
        rise = sheer - keel
        # Eight points: port sheer, down through the turn of the bilge to the
        # keel, back up to starboard, and a flat crown closing the top. FLAT,
        # not crowned like the wrack's own shell - the deck slab lands on it.
        rings.append(
            [
                bm.verts.new(point)
                for point in (
                    (x, half, sheer),
                    (x, half * 0.95, keel + rise * 0.34),
                    (x, half * 0.58, keel + rise * 0.06),
                    (x, 0.0, keel),
                    (x, -half * 0.58, keel + rise * 0.06),
                    (x, -half * 0.95, keel + rise * 0.34),
                    (x, -half, sheer),
                    (x, 0.0, sheer),
                )
            ]
        )
    _ka_loft(bm, rings)
    # Two heavy wales down each side. Without them 170 studs of hull reads as
    # one blank shape from the only angle the player ever sees it from.
    for fraction in (0.34, 0.60):
        for side in (1.0, -1.0):
            prev = None
            for x, half, keel, sheer in KA_STATIONS:
                point = (x, side * half * 1.02, keel + (sheer - keel) * fraction)
                if prev is not None:
                    _wr_beam(bm, _WK_WORLD, prev, point, 1.2, 0.9)
                prev = point
    # Keel, stem and the transom board.
    prev = None
    for x, half, keel, sheer in KA_STATIONS:
        point = (x, 0.0, keel - 0.5)
        if prev is not None:
            _wr_beam(bm, _WK_WORLD, prev, point, 2.4, 1.8)
        prev = point
    _wr_spar(bm, _WK_WORLD, (83.0, 0.0, -1.6), (90.0, 0.0, 12.4), 1.7, 1.1, sides=6)
    _wr_panel(
        bm,
        _WK_WORLD,
        ((-85.6, 8.8, 9.2), (-85.6, -8.8, 9.2), (-85.6, -7.4, -3.0), (-85.6, 7.4, -3.0)),
        thick=0.8,
    )
    # Gunports: six a side. They are the read that says SHIP OF WAR at the
    # distance the money shot is taken from, and they cost 72 tris.
    for side in (1.0, -1.0):
        for i in range(6):
            x = -52.0 + i * 19.0
            half, keel, sheer = _ka_station(x)
            box(bm, (x, side * (half + 0.15), keel + (sheer - keel) * 0.74), (4.2, 1.0, 3.4))
    # Channels - the shelves the shrouds set up from, and the only thing that
    # keeps the rigging from appearing to grow out of the deck.
    for mast_x, reach in ((KA_MAIN_MAST, 6.0), (KA_FORE_MAST, 4.6)):
        half = _ka_half(mast_x)
        for side in (1.0, -1.0):
            box(
                bm,
                (mast_x, side * (half + reach / 2.0 - 0.4), _ka_deck_top(mast_x) - 0.8),
                (12.0, reach, 0.7),
            )
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenArena_Base", bm, KA_HULL)


def build_ka_deck(rng):
    """The weather deck: one lofted slab from transom to stem, top at 8.0.
    Deliberately CLEAN - the fight paints its telegraphs on this floor, and
    the four cover pieces are the only things allowed to break it. (The
    Tidebreak ruling, relearned once per arena so far.)"""
    bm = bmesh.new()
    top, bottom = KA_DECK_Z, KA_DECK_Z - 0.7
    rings = []
    for x, half, keel, sheer in KA_STATIONS:
        w = max(0.7, half - 0.45)
        rings.append(
            [
                bm.verts.new((x, w, top)),
                bm.verts.new((x, -w, top)),
                bm.verts.new((x, -w, bottom)),
                bm.verts.new((x, w, bottom)),
            ]
        )
    _ka_loft(bm, rings)
    # Fore-and-aft plank seams, 0.09 proud: a Humanoid steps over them without
    # noticing and the plan shot gets a floor with a direction in it.
    for i in range(9):
        y = -16.0 + i * 4.0
        box(
            bm,
            ((KA_QD_FRONT + KA_FC_AFT) / 2.0, y, top + 0.03),
            (KA_FC_AFT - KA_QD_FRONT, 0.30, 0.12),
        )
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenArena_MainDeck", bm, KA_DECK_COL)


def _ka_castle(bm, xs, top, stern):
    """One castle block, lofted between stations and closed. SOLID on purpose:
    a hollow castle is a roofed room, and a roofed room is total immunity from
    an arm that only ever comes over a rail."""
    rings = []
    for x in xs:
        w = max(1.2, _ka_half(x) - 0.7)
        rings.append(
            [
                bm.verts.new((x, w, top)),
                bm.verts.new((x, -w, top)),
                bm.verts.new((x, -w, KA_DECK_Z - 0.3)),
                bm.verts.new((x, w, KA_DECK_Z - 0.3)),
            ]
        )
    _ka_loft(bm, rings)
    _ = stern


def build_ka_quarterdeck(rng):
    """The stern castle: nine studs of high ground, the spawn's own floor, and
    the half of phase 2 the players retreat UP into. A stair each side, tread
    rise 1.5 - inside a Humanoid's 2-stud step, so it is a walk, not a jump."""
    bm = bmesh.new()
    xs = [x for x, _h, _k, _s in KA_STATIONS if x <= KA_QD_FRONT] + [KA_QD_FRONT]
    _ka_castle(bm, xs, KA_QD_Z, stern=True)
    # Stern gallery windows on the transom, and a companion hatch on top: the
    # two details that stop nine studs of blank block reading as a crate.
    for i in range(3):
        box(bm, (-85.4, -5.0 + i * 5.0, KA_QD_Z - 3.6), (1.2, 3.4, 3.2))
    box(bm, (-46.0, 0.0, KA_QD_Z + 0.5), (5.6, 6.4, 1.0))
    for side in (1.0, -1.0):
        y = side * (_ka_half(-36.0) - 5.0)
        _wr_beam(
            bm,
            _WK_WORLD,
            (KA_QD_FRONT + 1.0, y, KA_QD_Z - 0.6),
            (KA_QD_FRONT + 9.4, y, KA_DECK_Z + 0.6),
            5.4,
            0.9,
        )
        for step in range(6):
            z = KA_DECK_Z + (step + 1) * ((KA_QD_Z - KA_DECK_Z) / 6.0)
            x = KA_QD_FRONT + 1.2 + (5 - step) * 1.6
            box(bm, (x, y, z - 0.35), (1.7, 5.0, 0.7))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenArena_Quarterdeck", bm, KA_CASTLE)


def build_ka_forecastle(rng):
    """The bow castle: seven studs up, the other half of phase 2, and the only
    place aboard from which you look DOWN the length of the fight."""
    bm = bmesh.new()
    xs = [KA_FC_AFT] + [x for x, _h, _k, _s in KA_STATIONS if x >= KA_FC_AFT]
    _ka_castle(bm, xs, KA_FC_Z, stern=False)
    # One stair, on the centreline: five treads of 1.4.
    _wr_beam(bm, _WK_WORLD, (KA_FC_AFT - 0.8, 0.0, KA_FC_Z - 0.6), (KA_FC_AFT - 7.4, 0.0, KA_DECK_Z + 0.6), 6.2, 0.9)
    for step in range(5):
        z = KA_DECK_Z + (step + 1) * ((KA_FC_Z - KA_DECK_Z) / 5.0)
        x = KA_FC_AFT - 1.0 - (4 - step) * 1.4
        box(bm, (x, 0.0, z - 0.35), (1.5, 6.0, 0.7))
    # Catheads and the anchor stocks: the bow's own silhouette.
    for side in (1.0, -1.0):
        _wr_beam(bm, _WK_WORLD, (72.0, side * 5.0, KA_FC_Z - 1.0), (80.0, side * 10.0, KA_FC_Z - 1.4), 1.6, 1.2)
        _wr_beam(bm, _WK_WORLD, (78.0, side * 9.4, KA_FC_Z - 2.0), (78.0, side * 9.4, KA_FC_Z - 8.4), 1.0, 0.8)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenArena_Forecastle", bm, KA_CASTLE)


def build_ka_rails(rng):
    """The bulwarks - 2.8 studs and not one more. A rail on this ship must
    never be the thing that saves you: the sweep plane passes over it,
    visibly, and the deck furniture is what cover means here. Broken by FOUR
    BOARDING GAPS, two a side, at the wrap points."""
    bm = bmesh.new()
    seg = 3.2
    x = -84.0
    while x < 84.0:
        mid = x + seg / 2.0
        for side in (1.0, -1.0):
            if _ka_in_gap(x, side) or _ka_in_gap(x + seg, side):
                continue
            deck = _ka_deck_top(mid)
            y = _ka_rail_y(mid, side)
            box(bm, (mid, y, deck + KA_RAIL_H / 2.0), (seg * 1.02, 1.1, KA_RAIL_H))
            box(bm, (mid, y, deck + KA_RAIL_H + 0.17), (seg * 1.02, 1.7, 0.34))
        x += seg
    # The taffrail across the stern and a low breastwork across the bow: the
    # two ends of the ship are edges too, and phase 2 opens both of them.
    for cx, deck, width in ((-84.4, KA_QD_Z, 17.6), (82.0, KA_FC_Z, 8.0)):
        box(bm, (cx, 0.0, deck + KA_RAIL_H / 2.0), (1.2, width, KA_RAIL_H))
        box(bm, (cx, 0.0, deck + KA_RAIL_H + 0.17), (1.8, width, 0.34))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenArena_Rails", bm, KA_RAIL)


def build_ka_wrapmarks(rng):
    """The four places the arms come over: doubled planking let into the deck
    inboard of each boarding gap, three iron straps across it, and a pair of
    ring bolts. 0.22 proud and `Deco`-marked, so it is a SIGN and never a step
    and never cover. Coordinates go out in the HANDOFF; the wiring aims at
    them, and the player learns to read them."""
    bm = bmesh.new()
    for index in range(len(KA_WRAPS)):
        wrap_x, wrap_y, deck = _ka_wrap_point(index)
        inboard = wrap_y - math.copysign(4.6, wrap_y)
        box(bm, (wrap_x, inboard, deck + 0.11), (13.0, 9.0, 0.22))
        for i in range(3):
            box(bm, (wrap_x - 4.4 + i * 4.4, inboard, deck + 0.24), (1.1, 9.4, 0.28))
        for side in (-1.0, 1.0):
            tapered_cylinder(
                bm, deck + 0.2, deck + 0.78, 0.55, 0.42, sides=6, center=(wrap_x + side * 5.6, inboard)
            )
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenArena_WrapMarkDeco", bm, KA_IRON)


KA_COVER_COL = {
    "CoverCargoFore": KA_CARGO,
    "CoverCargoAft": KA_CARGO,
    "CoverCoaming": KA_RAIL,
    "CoverCapstan": KA_IRON,
}


def build_ka_cover(index, rng):
    """One sweep-cover piece, each its own object so the fight logic can find
    it, telegraph off it, or take it apart - the Tidebreak reef-stone pattern.
    This is the causeway's three notches re-expressed for a deck you cannot
    cut a hole in."""
    name, cx, cy, sx, sy, top = KA_COVER[index]
    bm = bmesh.new()
    base = KA_DECK_Z
    if name == "CoverCoaming":
        # The main hatch: a coaming ring round a grating. The RING is the
        # cover; the grating inside it is flush, so nobody ends up standing
        # 2.7 studs up on the one piece of furniture meant to hide them.
        for side in (1.0, -1.0):
            box(bm, (cx, cy + side * (sy / 2.0 - 0.7), base + top / 2.0), (sx, 1.4, top))
            box(bm, (cx + side * (sx / 2.0 - 0.7), cy, base + top / 2.0), (1.4, sy - 2.8, top))
        box(bm, (cx, cy, base + 0.16), (sx - 2.6, sy - 2.6, 0.32))
        for i in range(5):
            box(bm, (cx - 5.6 + i * 2.8, cy, base + 0.3), (0.5, sy - 3.2, 0.3))
    elif name == "CoverCapstan":
        tapered_cylinder(bm, base, base + top, 3.2, 2.6, sides=10, center=(cx, cy))
        tapered_cylinder(bm, base, base + 0.5, 4.4, 4.2, sides=12, center=(cx, cy))
        for i in range(6):
            angle = i * TAU / 6.0 + 0.3
            _wr_beam(
                bm,
                _WK_WORLD,
                (cx, cy, base + top - 0.6),
                (cx + math.cos(angle) * 5.4, cy + math.sin(angle) * 5.4, base + top - 1.0),
                0.6,
                0.6,
            )
    else:
        # Cargo: crates lashed down, with barrels outboard of them. Heights are
        # drawn against `top` and never past it.
        for _ in range(5):
            ox = (rng.random() - 0.5) * (sx - 6.0)
            oy = (rng.random() - 0.5) * (sy - 5.0)
            height = rng.uniform(1.5, top)
            box(
                bm,
                (cx + ox, cy + oy, base + height / 2.0),
                (rng.uniform(3.6, 5.4), rng.uniform(3.2, 4.6), height),
                Matrix.Rotation(rng.uniform(-0.25, 0.25), 3, "Z"),
            )
        for k in range(3):
            tapered_cylinder(
                bm,
                base,
                base + min(top, 2.4),
                1.5,
                1.4,
                sides=8,
                center=(cx + (k - 1) * 3.4, cy + math.copysign(sy / 2.0 - 1.8, cy)),
            )
        # The lashings. A stack this size on a ship in a storm has to look
        # SECURED, or it reads as loose scenery a player could shove over.
        for k in range(3):
            y = cy - sy / 2.0 + k * (sy / 2.0)
            _wr_beam(
                bm,
                _WK_WORLD,
                (cx - sx / 2.0, y, base + 0.25),
                (cx + sx / 2.0, y, base + 0.25),
                0.3,
                0.3,
            )
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenArena_" + name, bm, KA_COVER_COL[name])


def build_ka_spawn(rng):
    """The drop-in dais, up on the quarterdeck: the brightest thing aboard,
    and nine studs above the fight, so the first thing a challenger sees is
    the whole deck and whatever is already coming over its rails."""
    bm = bmesh.new()
    tapered_cylinder(bm, KA_QD_Z - 0.1, KA_QD_Z + 0.45, 7.0, 6.4, sides=16, center=(KA_SPAWN_X, 0.0))
    tapered_cylinder(bm, KA_QD_Z + 0.45, KA_QD_Z + 0.62, 4.6, 4.2, sides=16, center=(KA_SPAWN_X, 0.0))
    # Four lamp posts round it, and the mark the drop-in circle lands on.
    for i in range(4):
        angle = i * TAU / 4.0 + math.pi / 4.0
        tapered_cylinder(
            bm,
            KA_QD_Z,
            KA_QD_Z + 2.4,
            0.8,
            0.6,
            sides=6,
            center=(KA_SPAWN_X + math.cos(angle) * 8.6, math.sin(angle) * 8.6),
        )
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenArena_SpawnPad", bm, KA_PAD)


def build_ka_lamps(rng):
    """Storm lanterns: four round the spawn dais, one at the mainmast top, one
    over the forecastle stair. The ship is lit by nothing else, and a teleport
    that lands you in the dark reads as a bug."""
    bm = bmesh.new()
    for i in range(4):
        angle = i * TAU / 4.0 + math.pi / 4.0
        add_blob(
            bm,
            (KA_SPAWN_X + math.cos(angle) * 8.6, math.sin(angle) * 8.6, KA_QD_Z + 3.1),
            (1.05, 1.05, 1.3),
            0.16,
            salt=i * 3.1,
            subdiv=1,
        )
    add_blob(bm, (KA_MAIN_MAST, 0.0, KA_DECK_Z + 40.0), (1.3, 1.3, 1.6), 0.16, salt=7.2, subdiv=1)
    add_blob(bm, (KA_FC_AFT + 2.0, 0.0, KA_FC_Z + 3.0), (1.1, 1.1, 1.35), 0.16, salt=9.4, subdiv=1)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenArena_LampGlow", bm, KA_LAMPGLOW)


# THE RIG, shared by the masts, the sails and the rigging so a yard and the
# canvas hanging off it cannot drift apart:
# (mast x, foot z, height, r at the partners, r at the truck, yards) where a
# yard is (height fraction, span athwartships, how far its sail drops).
KA_RIG = (
    # The course drops are 16 and 13, not the 22 and 17 the first pass hung:
    # a course whose foot lands at deck+5 is a curtain across the fight at
    # exactly eye height, and the money shot came back with the boss behind it.
    (KA_MAIN_MAST, KA_DECK_Z, 62.0, 2.6, 1.0, ((0.44, 46.0, 16.0), (0.72, 32.0, 15.0))),
    (KA_FORE_MAST, KA_FC_Z, 44.0, 2.1, 0.9, ((0.46, 34.0, 13.0), (0.74, 22.0, 11.0))),
)


def build_ka_masts(rng):
    """Two masts, their yards, and the bowsprit. The MAINMAST stands in the
    middle of the waist on purpose: it is the vertical the money shot reads
    the arms against, and a pillar a player can put between themselves and a
    sweep. It is 2.6 at the partners, so it is a landmark and not a wall."""
    bm = bmesh.new()
    for mast_x, foot, height, r0, r1, yards in KA_RIG:
        _wr_spar(bm, _WK_WORLD, (mast_x, 0.0, foot - 8.0), (mast_x, 0.0, foot + height), r0, r1, sides=8)
        for fraction, span, _drop in yards:
            z = foot + height * fraction
            _wr_spar(bm, _WK_WORLD, (mast_x, -span / 2.0, z), (mast_x, span / 2.0, z), 0.9, 0.4, sides=6)
        # A top: the platform that stops a mast reading as a stick.
        tapered_cylinder(
            bm, foot + height * 0.60, foot + height * 0.60 + 0.6, 4.2, 3.6, sides=8, center=(mast_x, 0.0)
        )
    _wr_spar(bm, _WK_WORLD, (80.0, 0.0, KA_FC_Z - 3.0), (118.0, 0.0, KA_FC_Z + 7.0), 1.9, 0.7, sides=6)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenArena_Masts", bm, KA_HULL)


def build_ka_sails(rng):
    """Dark canvas, storm-torn: each sail is a row of vertical gores with a
    ragged foot, two of which are simply gone. Flat panels with a nominal
    thickness and NO solidify anywhere near them - the modifier is what cost
    the gullet its byte-stable re-export."""
    bm = bmesh.new()
    for mast_x, foot, height, _r0, _r1, yards in KA_RIG:
        for fraction, span, drop in yards:
            top = foot + height * fraction - 0.6
            gores = 9
            for g in range(gores):
                if rng.random() < 0.18:
                    continue  # blown out of its boltropes
                y0 = -span / 2.0 + span * (g / gores)
                y1 = -span / 2.0 + span * ((g + 1) / gores)
                belly = 1.6 + 2.4 * math.sin(math.pi * (g + 0.5) / gores)
                _wr_panel(
                    bm,
                    _WK_WORLD,
                    (
                        (mast_x + belly * 0.2, y0, top),
                        (mast_x + belly * 0.2, y1, top),
                        (mast_x + belly, y1, top - drop * rng.uniform(0.55, 1.0)),
                        (mast_x + belly, y0, top - drop * rng.uniform(0.55, 1.0)),
                    ),
                    thick=0.3,
                )
    return finish("KrakenArena_SailDeco", bm, KA_CANVAS)


def build_ka_flag(rng):
    """The black flag at the main truck. Its OWN object because it is the one
    thing aboard that has to read as black against a bruised sky, and one flat
    material per object is this file's rule."""
    bm = bmesh.new()
    top = KA_DECK_Z + 62.0
    for g in range(5):
        y0, y1 = 1.0 + g * 2.2, 1.0 + (g + 1) * 2.2
        wave = math.sin(g * 0.9) * 0.9
        _wr_panel(
            bm,
            _WK_WORLD,
            (
                (KA_MAIN_MAST + wave, y0, top - 0.8),
                (KA_MAIN_MAST + wave, y1, top - 0.8),
                (KA_MAIN_MAST + wave, y1, top - 6.2 + (1.6 if g > 2 else 0.0)),
                (KA_MAIN_MAST + wave, y0, top - 6.2),
            ),
            thick=0.25,
        )
    return finish("KrakenArena_FlagDeco", bm, KA_FLAG)


def build_ka_rigging(rng):
    """Shrouds, ratlines and the stays. `Deco`, so a rope can never catch a
    foot or eat a cast - which matters here more than on any other arena,
    because this rigging crosses the fight floor rather than ringing it."""
    bm = bmesh.new()
    for mast_x, foot, height, _r0, _r1, _yards in KA_RIG:
        head = foot + height * 0.58
        deck = _ka_deck_top(mast_x)
        half = _ka_half(mast_x)
        spread = 6.0 if mast_x == KA_MAIN_MAST else 4.6
        for side in (1.0, -1.0):
            anchor = Vector((mast_x, side * 1.6, head))
            first = Vector((mast_x - 2.0, side * (half + 0.4), deck - 0.8))
            last = Vector((mast_x + 1.9, side * (half + spread - 0.6), deck - 0.8))
            for k in range(4):
                _wr_beam(bm, _WK_WORLD, anchor, first.lerp(last, k / 3.0), 0.34, 0.28)
            for r in range(5):
                t = 0.20 + r * 0.16
                _wr_beam(bm, _WK_WORLD, anchor.lerp(first, 1.0 - t), anchor.lerp(last, 1.0 - t), 0.24, 0.20)
    # Mainstay forward to the foremast head, forestay on to the bowsprit, and
    # a backstay down to the taffrail: the three lines that tie the rig into
    # one silhouette instead of two poles.
    _wr_beam(bm, _WK_WORLD, (KA_MAIN_MAST, 0.0, KA_DECK_Z + 44.0), (KA_FORE_MAST, 0.0, KA_FC_Z + 26.0), 0.4, 0.34)
    _wr_beam(bm, _WK_WORLD, (KA_FORE_MAST, 0.0, KA_FC_Z + 30.0), (114.0, 0.0, KA_FC_Z + 6.0), 0.36, 0.30)
    _wr_beam(bm, _WK_WORLD, (KA_MAIN_MAST, 0.0, KA_DECK_Z + 48.0), (-83.0, 0.0, KA_QD_Z + 2.6), 0.40, 0.34)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenArena_RiggingDeco", bm, KA_ROPE)


def build_ka_fittings(rng):
    """The wheel, the binnacle, the bell and the bitts. Everything here stands
    on the QUARTERDECK or against a bulkhead - nothing is allowed into the
    waist, because the waist is the fight and four cover pieces is the whole
    budget it gets."""
    bm = bmesh.new()
    wheel_x = -58.0
    _wr_spar(bm, _WK_WORLD, (wheel_x, -0.45, KA_QD_Z + 3.4), (wheel_x, 0.45, KA_QD_Z + 3.4), 2.7, 2.7, sides=12)
    for i in range(8):
        angle = i * TAU / 8.0
        _wr_beam(
            bm,
            _WK_WORLD,
            (wheel_x, 0.0, KA_QD_Z + 3.4),
            (wheel_x + math.cos(angle) * 3.4, 0.0, KA_QD_Z + 3.4 + math.sin(angle) * 3.4),
            0.32,
            0.32,
        )
    box(bm, (wheel_x, 0.0, KA_QD_Z + 0.9), (2.2, 3.4, 1.8))
    box(bm, (wheel_x + 6.0, 0.0, KA_QD_Z + 1.4), (2.6, 2.6, 2.8))  # the binnacle
    # Mooring bitts along both rails, and the ship's bell on the after face of
    # the forecastle.
    for side in (1.0, -1.0):
        for x in (-74.0, 62.0):
            y = side * (_ka_half(x) - 3.2)
            box(bm, (x, y, _ka_deck_top(x) + 1.0), (1.4, 1.4, 2.0))
    _wr_beam(bm, _WK_WORLD, (KA_FC_AFT + 0.4, -3.0, KA_FC_Z + 4.2), (KA_FC_AFT + 0.4, 3.0, KA_FC_Z + 4.2), 0.5, 0.5)
    cone(bm, (KA_FC_AFT + 0.4, 0.0, KA_FC_Z + 2.0), (KA_FC_AFT + 0.4, 0.0, KA_FC_Z + 4.0), 1.1, sides=8)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenArena_Fittings", bm, KA_IRON)


def build_ka_debris(rng):
    """Rope coils, buckets and small barrels. `Deco` - stripped of collision
    and query at runtime - and kept HARD against the rails and the castle
    faces, never in the waist's lanes and never on a cover piece. The waist is
    the fight; this exists to say the ship is worked, not to decorate her."""
    bm = bmesh.new()
    placed = 0
    for _ in range(90):
        if placed >= 24:
            break
        cx = rng.uniform(-80.0, 76.0)
        side = rng.choice((-1.0, 1.0))
        edge = abs(_ka_rail_y(cx, side))
        if edge < 4.5:
            continue
        cy = side * rng.uniform(edge - 3.6, edge - 1.6)
        if any(
            abs(cx - c[1]) < c[3] / 2.0 + 2.5 and abs(cy - c[2]) < c[4] / 2.0 + 2.5 for c in KA_COVER
        ):
            continue
        deck = _ka_deck_top(cx)
        if rng.random() < 0.45:
            tapered_cylinder(bm, deck, deck + 0.55, 1.5, 1.4, sides=8, center=(cx, cy))
            tapered_cylinder(bm, deck + 0.55, deck + 0.95, 1.05, 0.95, sides=8, center=(cx, cy))
        else:
            tapered_cylinder(bm, deck, deck + rng.uniform(1.2, 1.8), 1.1, 1.0, sides=8, center=(cx, cy))
        placed += 1
    # A spare spar and a stack of boarding pikes lashed along the quarterdeck
    # break, where nothing is standing anyway.
    _wr_spar(bm, _WK_WORLD, (-52.0, 9.0, KA_QD_Z + 0.5), (-76.0, 11.0, KA_QD_Z + 0.5), 0.9, 0.6, sides=6)
    for k in range(5):
        _wr_beam(
            bm,
            _WK_WORLD,
            (-48.0, -9.0 - k * 0.5, KA_QD_Z + 0.4 + k * 0.3),
            (-70.0, -10.0 - k * 0.5, KA_QD_Z + 0.4 + k * 0.3),
            0.34,
            0.30,
        )
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenArena_DebrisDeco", bm, KA_ROPE)


def build_ka_foam(rng):
    """The wake collar at the waterline. `_Foam` earns OceanController's tide
    ride and loses its collision, both by the name - which matters more here
    than on any other arena, because this hull is the only thing between the
    fight and a sea the player can walk on."""
    bm = bmesh.new()
    for _ in range(130):
        x = rng.uniform(-92.0, 92.0)
        half = _ka_half(max(-85.0, min(85.0, x)))
        side = rng.choice((-1.0, 1.0))
        add_blob(
            bm,
            (x, side * (half + rng.uniform(-0.6, 3.6)), 0.25),
            (rng.uniform(2.4, 5.0), rng.uniform(1.2, 2.6), 0.5),
            0.3,
            salt=x * 0.11,
        )
    # The bow wave. A dead-still ship in a storm reads wrong, and the wake is
    # also the only thing in the export that says which end is the bow from
    # directly overhead.
    for i in range(26):
        t = i / 25.0
        for side in (-1.0, 1.0):
            add_blob(
                bm,
                (84.0 + t * 26.0, side * (2.0 + t * 16.0), 0.3),
                (rng.uniform(3.0, 6.0), rng.uniform(1.4, 2.6), 0.5),
                0.3,
                salt=i * 0.7 + side,
            )
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenArena_Foam", bm, KA_FOAM)


def build_kraken():
    rng = random.Random(90802)
    covers = [build_ka_cover(index, rng) for index in range(len(KA_COVER))]
    objects = [
        build_ka_base(rng),
        build_ka_deck(rng),
        build_ka_quarterdeck(rng),
        build_ka_forecastle(rng),
        build_ka_rails(rng),
        build_ka_wrapmarks(rng),
        *covers,
        build_ka_masts(rng),
        build_ka_sails(rng),
        build_ka_flag(rng),
        build_ka_rigging(rng),
        build_ka_fittings(rng),
        build_ka_spawn(rng),
        build_ka_lamps(rng),
        build_ka_debris(rng),
        build_ka_foam(rng),
    ]

    # MEASURED off the built meshes, not asserted from the table above. The
    # sweep clearance IS the mechanic, and a claim about it is worth nothing
    # the moment a crate's random height or a lashing's thickness moves.
    cover_top = max(max(v.co[2] for v in obj.data.vertices) for obj in covers)
    rail_top = KA_DECK_Z + KA_RAIL_H

    print(
        "HANDOFF kraken: SCALE CONTRACT - head %.0f tall x %.0f wide, and it is NOT at the arena origin any more:"
        " the SHIP is. Head centre goes at arena-local (%.0f, %+.0f), i.e. %.0f studs off the PORT rail on a"
        " bearing perpendicular to the ship's long axis. Author z=0 is WATER_Y."
        % (KA_HEAD_H, KA_HEAD_W, KA_HEAD_AT[0], KA_HEAD_AT[1], KA_HEAD_RANGE)
    )
    print(
        "HANDOFF kraken: SHIP ORIGIN is arena-local (0, 0) and `KrakenArena_Base` (the hull) is centred on it, so"
        " BossArenaService.placeAuthored lands the SHIP on the BossArenas row's `center`. The head offset above is"
        " the wiring's to apply - do not expect the boss at the arena centre."
    )
    print(
        "HANDOFF kraken: AXIS NOTE - author +Y is the PORT side (the head's side). The glTF y-up export maps author"
        " +Y to Roblox -Z, so the head goes %.0f studs on -Z from the arena centre unless the import is re-oriented."
        % KA_HEAD_RANGE
    )
    print(
        "HANDOFF kraken: HULL - %.0f long on X (bow +X, stern -X) x %.0f beam, keel z %.1f, waterline z 0."
        % (KA_SHIP_LEN, KA_SHIP_BEAM, KA_KEEL_Z)
    )
    print(
        "HANDOFF kraken: DECK HEIGHTS - main deck top z %.1f; forecastle z %.1f (+%.0f, x %.0f..85);"
        " quarterdeck z %.1f (+%.0f, x -85..%.0f). Stair rise 1.5 (QD, both sides) and 1.4 (FC, centreline)."
        % (KA_DECK_Z, KA_FC_Z, KA_FC_Z - KA_DECK_Z, KA_FC_AFT, KA_QD_Z, KA_QD_Z - KA_DECK_Z, KA_QD_FRONT)
    )
    print(
        "HANDOFF kraken: PHASE 1 = THE WAIST, x %.0f..%.0f (%.0f long) x about %.0f clear between the bulwarks."
        " PHASE 2 opens the full %.0f including both castles - three floors instead of one."
        % (
            KA_QD_FRONT,
            KA_FC_AFT,
            KA_FC_AFT - KA_QD_FRONT,
            2.0 * (_ka_half(0.0) - KA_RAIL_INSET - 1.4),
            KA_SHIP_LEN,
        )
    )
    print(
        "HANDOFF kraken: ...and the 'clear' in that line is 90 x 34 MINUS THE STAIRS, which are the price of two"
        " raised decks: the quarterdeck pair occupy x %.0f..%.0f at y +/-%.1f (5.4 wide), the forecastle one"
        " x %.0f..%.0f on the centreline (6.2 wide). Truly open planking is x %.0f..%.0f full width."
        % (KA_QD_FRONT, KA_QD_FRONT + 9.4, _ka_half(-36.0) - 5.0, KA_FC_AFT - 7.4, KA_FC_AFT, KA_QD_FRONT + 9.4, KA_FC_AFT - 7.4)
    )
    print(
        "HANDOFF kraken: SWEEP PLANE - put a lateral sweep's UNDERSIDE at z %.1f (deck+3.0). Measured clearances:"
        " bulwark top %.1f (clears by %.2f), tallest cover %.2f (clears by %.2f), crouched head ~%.1f (clears by"
        " %.2f) - and a STANDING head at %.1f is %.1f INTO it. The rail never saves you; the cover does."
        % (
            KA_SWEEP_Z,
            rail_top,
            KA_SWEEP_Z - rail_top,
            cover_top,
            KA_SWEEP_Z - cover_top,
            KA_DECK_Z + KA_CROUCH_HEAD,
            KA_SWEEP_Z - (KA_DECK_Z + KA_CROUCH_HEAD),
            KA_DECK_Z + KA_STAND_HEAD,
            (KA_DECK_Z + KA_STAND_HEAD) - KA_SWEEP_Z,
        )
    )
    print(
        "HANDOFF kraken: RAISED-DECK SWEEP PLANES for phase 2 - forecastle z %.1f, quarterdeck z %.1f (same deck+3.0"
        " rule). A single world-height sweep does NOT work once the castles open: it would be head-high in the waist"
        " and knee-high nowhere."
        % (KA_FC_Z + 3.0, KA_QD_Z + 3.0)
    )
    for index, (name, cx, cy, sx, sy, top) in enumerate(KA_COVER):
        measured = max(v.co[2] for v in covers[index].data.vertices)
        print(
            "HANDOFF kraken: COVER %s at (%.1f, %.1f), footprint %.1f x %.1f, top z %.2f (deck+%.2f) - clears the"
            " sweep plane by %.2f"
            % (name, cx, cy, sx, sy, measured, measured - KA_DECK_Z, KA_SWEEP_Z - measured)
        )
        _ = top
    for index, (label, wrap_x, side) in enumerate(KA_WRAPS):
        px, py, deck = _ka_wrap_point(index)
        print(
            "HANDOFF kraken: WRAP POINT %s - rail line (%.1f, %.1f) at deck z %.1f, %s side; boarding gap in the"
            " bulwark x %.1f..%.1f; reinforcement mark centred (%.1f, %.1f), %.1f proud"
            % (
                label,
                px,
                py,
                deck,
                "PORT" if side > 0 else "STARBOARD",
                wrap_x - KA_GAP_W / 2.0,
                wrap_x + KA_GAP_W / 2.0,
                px,
                py - math.copysign(4.6, py),
                0.22,
            )
        )
    print(
        "HANDOFF kraken: the four wrap points are STAGGERED on X (port %.0f/%.0f, starboard %.0f/%.0f) so no two"
        " arms opposite each other can own the whole width of the waist at once"
        % (KA_WRAPS[0][1], KA_WRAPS[1][1], KA_WRAPS[2][1], KA_WRAPS[3][1])
    )
    print(
        "HANDOFF kraken: SLAM TARGETS - the waist is %.0f x %.0f. An impact disc of r 12-16 on the centreline owns"
        " the width without owning either cover stack; r 22 owns the room and should be the telegraphed one."
        % (KA_FC_AFT - KA_QD_FRONT, 2.0 * _ka_half(0.0))
    )
    print(
        "HANDOFF kraken: SPAWN PAD centre (%.0f, 0), on the QUARTERDECK at z %.1f, dais r 7 - drop challengers here"
        " facing +X (down the deck), with the head off their left hand" % (KA_SPAWN_X, KA_QD_Z)
    )
    print(
        "HANDOFF kraken: !! THE SEA IS STILL SOLID. WorldService ocean tiles are 4-stud slabs, top face exactly"
        " WATER_Y, and players stand on them. Going over this rail is an %.0f-stud DROP ONTO WALKABLE SEA, not a"
        " drowning - a player can simply walk away from the fight across open water, and no mesh in this glb can"
        " stop that. Containment MUST be wiring: the maelstrom undertow, a BossArenas `barrier` row, or a teleport"
        " back aboard." % KA_DECK_Z
    )
    print("HANDOFF kraken: DECK EDGE for that containment - the bulwark line, port and starboard, by station:")
    for x in (-85.0, -64.0, -40.0, -20.0, 0.0, 20.0, 40.0, 50.0, 66.0, 85.0):
        print(
            "HANDOFF kraken:   x %+6.1f  port y %+6.2f  stbd y %+6.2f  deck z %.1f"
            % (x, _ka_rail_y(x, 1.0), _ka_rail_y(x, -1.0), _ka_deck_top(x))
        )
    print(
        "HANDOFF kraken: a barrier that is a simple box works here - the hull is convex in plan: x %.0f..%.0f,"
        " |y| <= %.1f, floor z %.1f. Fence it a stud or two outboard of the rail line above."
        % (-KA_SHIP_LEN / 2.0, KA_SHIP_LEN / 2.0, _ka_half(0.0), KA_DECK_Z)
    )
    print(
        "HANDOFF kraken: BossArenas center - the Kraken's reserved ring slot is (8000, -22600); the maelstrom row is"
        " still absent ON PURPOSE, so adding it is part of the wiring slice"
    )
    print(
        "HANDOFF kraken: COLLISION - PreciseConvexDecomposition REQUIRED on _MainDeck, _Quarterdeck and _Forecastle"
        " (the stairs are the access and a default hull turns them into a ramp or a wall), on _Rails (the four"
        " boarding gaps are the mechanic and a hull FILLS them), and on the four _Cover* objects. Default hull is"
        " fine for _Base, _SpawnPad, _Masts and _Fittings"
    )
    print(
        "HANDOFF kraken: _WrapMarkDeco, _SailDeco, _FlagDeco, _RiggingDeco, _DebrisDeco and _Foam carry the"
        " visual-only markers; _LampGlow carries `Glow` and goes Neon"
    )
    print(
        "HANDOFF kraken: widest object is _Base at %.0f studs on X - far under the 2048 MeshPart cap; DO NOT scale"
        " on import" % KA_SHIP_LEN
    )
    print(
        "HANDOFF kraken: run `python3 tools/gen_mesh_colors.py` after this import - %d object names need MeshColors"
        " rows or they arrive grey (and note the tool's own ARENAS list does not yet include `kraken` or"
        " `kraken_gullet`)" % len(objects)
    )
    return objects


# ---------------------------------------------------------------- kraken gullet
#
# PHASE 3. A self-contained cavern with no relationship to the exterior: it is
# placed far from the world like every other lair and teleported into, so its
# origin is its own centre and z=0 is its floor datum, NOT the waterline.
#
# A dome 236 across and 82 tall - the "200 x 200 x 80 of playable space" the
# brief asked for, plus the wall's own foot. The heart hangs at the centre on a
# dais with four great vessels running up into the roof: the finale landmark,
# visible from the entry pad the moment you arrive. Six sockets ring it at r
# 62-78 for the destructible growths (the growths themselves are a boss/entity
# pass - these are the collars they plant on, always present so the room reads
# as a place even with every growth dead: the Choirfloor's rule).

KG_R = 118.0  # cavern half-width at the floor
KG_H = 82.0  # apex
KG_FLOOR_R = 132.0  # the floor runs past the wall's foot so there is no crack
KG_ENTRY = (0.0, -86.0)
KG_ENTRY_R = 13.0
KG_DAIS_R = 26.0
KG_HEART_Z = 21.0
KG_SOCKETS = ((64.0, 34.0), (76.0, 92.0), (62.0, 148.0), (78.0, 206.0), (66.0, 260.0), (74.0, 314.0))
KG_RIBS = 7

# The gullet's ladder: bone is the brightest thing in here and it is the
# STRUCTURE, so the ribs read as the room's shape; the floor is the datum; the
# walls sit UNDER it so the floor you fight on is never the darkest surface.
KG_RIB = (0.529, 0.482, 0.416)  # rib arches - bone, the top of the ladder
KG_PAD = (0.427, 0.396, 0.322)  # entry pad and dais: chitin plate, a landmark
KG_COLLAR = (0.416, 0.302, 0.459)  # socket collars - violet, hue-apart from the flesh
KG_HEART = (0.478, 0.114, 0.149)  # the heart mass
KG_FLOOR = (0.290, 0.129, 0.149)  # FLOOR - the datum
KG_WALL = (0.216, 0.086, 0.110)  # walls, deliberately under the floor
KG_GUT = (0.165, 0.137, 0.122)  # swallowed wreckage: dressing, lowest
KG_HEARTGLOW = (0.902, 0.290, 0.286)
KG_VEINGLOW = (0.898, 0.400, 0.353)


def _kg_wall_r(angle):
    return KG_R + noise.noise(Vector((math.cos(angle) * 2.2, math.sin(angle) * 2.2, 4.0))) * 13.0


def _kg_floor(x, y):
    radius = math.hypot(x, y)
    dish = -2.0 + 5.0 * (min(radius, KG_R) / KG_R) ** 2
    lump = noise.noise(Vector((x * 0.018, y * 0.018, 5.5))) * 3.4
    lump += noise.noise(Vector((x * 0.055, y * 0.055, 11.0))) * 1.1
    return dish + lump


def _kg_at(radius, degrees):
    angle = math.radians(degrees)
    return math.cos(angle) * radius, math.sin(angle) * radius


def build_kg_base(rng):
    """The fleshy floor. The anchor part, and the only thing here that is
    dead flat in spirit - uneven, but never so uneven it eats a jump."""
    bm = bmesh.new()
    radii = [16.0, 34.0, 52.0, 70.0, 88.0, 104.0, 118.0, KG_FLOOR_R]
    angles = 44
    grid = []
    for radius in radii:
        ring = []
        for i in range(angles):
            angle = (i / angles) * TAU
            x, y = math.cos(angle) * radius, math.sin(angle) * radius
            z = _kg_floor(x, y) if radius <= KG_R else _kg_floor(x, y) + (radius - KG_R) * 0.55
            ring.append(bm.verts.new((x, y, z)))
        grid.append(ring)
    hub = bm.verts.new((0.0, 0.0, _kg_floor(0.0, 0.0)))
    for i in range(angles):
        j = (i + 1) % angles
        bm.faces.new((hub, grid[0][i], grid[0][j]))
    for lo, hi in zip(grid, grid[1:]):
        for i in range(angles):
            j = (i + 1) % angles
            bm.faces.new((lo[i], lo[j], hi[j], hi[i]))
    under = []
    for i in range(angles):
        angle = (i / angles) * TAU
        under.append(bm.verts.new((math.cos(angle) * (KG_FLOOR_R - 6.0), math.sin(angle) * (KG_FLOOR_R - 6.0), -16.0)))
    floor = bm.verts.new((0.0, 0.0, -16.0))
    for i in range(angles):
        j = (i + 1) % angles
        bm.faces.new((grid[-1][i], grid[-1][j], under[j], under[i]))
        bm.faces.new((floor, under[j], under[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenGullet_Base", bm, KG_FLOOR)


KG_WALL_THICK = 9.0


def _kg_wall_surface(angles, levels):
    """The dome's inner surface as rings of points, foot ring first, apex last.
    Returned as plain vectors so the same profile can be offset outward for the
    shell's back face."""
    rings = []
    foot = []
    for i in range(angles):
        angle = (i / angles) * TAU
        radius = _kg_wall_r(angle) + 5.0
        foot.append(Vector((math.cos(angle) * radius, math.sin(angle) * radius, -15.0)))
    rings.append(foot)
    for level in range(levels):
        t = level / float(levels)
        phi = t * (math.pi / 2.0)
        ring = []
        for i in range(angles):
            angle = (i / angles) * TAU
            radius = _kg_wall_r(angle) * math.cos(phi) ** 0.78
            z = KG_H * math.sin(phi) ** 0.9
            z += noise.noise(Vector((math.cos(angle) * 2.2, math.sin(angle) * 2.2, t * 6.0 + 9.0))) * 4.0 * (0.3 + t)
            ring.append(Vector((math.cos(angle) * radius, math.sin(angle) * radius, z)))
        rings.append(ring)
    return rings


def build_kg_walls(rng):
    """The dome, built as TWO SHELLS bridged at the foot rather than as one
    surface run through `bmesh.ops.solidify`.

    Not a style choice. Solidify's output is geometrically identical run to
    run - vertex order, vertex values and face indices all hash the same - but
    the glb it exports does NOT: three consecutive builds of this arena gave
    three different files, and the object that moved was this one, every time.
    Byte-stable re-exports are the file's contract (a re-run must not show up
    as a diff), so the thickness is authored here instead: an inner surface, an
    outer surface offset along an approximate normal, and a rim closing them
    at the bottom. Being a closed solid, it also renders correctly from inside
    the room AND survives a convex-decomposition import as a room rather than
    a lump."""
    bm = bmesh.new()
    angles, levels = 40, 9
    inner = _kg_wall_surface(angles, levels)

    def outward(point):
        # Flattening z biases the offset horizontal near the foot and vertical
        # near the crown, which is what the dome's own normal does.
        direction = Vector((point.x, point.y, point.z * 0.55))
        if direction.length < 1e-6:
            direction = Vector((0.0, 0.0, 1.0))
        return point + direction.normalized() * KG_WALL_THICK

    in_rings = [[bm.verts.new(p) for p in ring] for ring in inner]
    out_rings = [[bm.verts.new(outward(p)) for p in ring] for ring in inner]
    in_apex = bm.verts.new((0.0, 0.0, KG_H))
    out_apex = bm.verts.new((0.0, 0.0, KG_H + KG_WALL_THICK))
    for rings, apex in ((in_rings, in_apex), (out_rings, out_apex)):
        for lo, hi in zip(rings, rings[1:]):
            for i in range(angles):
                j = (i + 1) % angles
                bm.faces.new((lo[i], lo[j], hi[j], hi[i]))
        for i in range(angles):
            j = (i + 1) % angles
            bm.faces.new((rings[-1][i], rings[-1][j], apex))
    for i in range(angles):
        j = (i + 1) % angles
        bm.faces.new((in_rings[0][i], in_rings[0][j], out_rings[0][j], out_rings[0][i]))
    # A closed solid, so "outward" is unambiguous: the inner surface ends up
    # facing the room and the outer surface facing the world, both correct.
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenGullet_Walls", bm, KG_WALL)


def build_kg_ribs(rng):
    """Seven cartilage arches over the room - the ribs the brief asked for,
    and the thing that makes the ceiling read as a body rather than a cave."""
    bm = bmesh.new()
    for k in range(KG_RIBS):
        bearing = math.radians(k * (180.0 / KG_RIBS) + 6.0)
        points = []
        for s in range(33):
            t = -1.0 + 2.0 * (s / 32.0)
            u = abs(t)
            radius = _kg_wall_r(bearing) * 0.93 * math.sin(u * math.pi / 2.0) ** 0.78
            radius = math.copysign(radius, t if t != 0 else 1.0)
            z = KG_H * 0.93 * math.cos(u * math.pi / 2.0) ** 0.9
            points.append(Vector((math.cos(bearing) * radius, math.sin(bearing) * radius, z)))
        for s in range(len(points) - 1):
            u = abs(-1.0 + 2.0 * (s / 32.0))
            # Thicker than the first pass (1.5-2.8): in a room 236 across
            # those read as pinstripes on the wall, not as a ribcage.
            r0 = 2.6 + 2.2 * u
            r1 = 2.6 + 2.2 * abs(-1.0 + 2.0 * ((s + 1) / 32.0))
            taper_between(bm, points[s], points[s + 1], r0, r1, sides=5)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenGullet_Ribs", bm, KG_RIB)


def build_kg_socket(index, rng):
    """One growth collar: a raised chitin ring with a flat pad inside it. The
    growth is a later pass; the collar is always here."""
    radius, bearing = KG_SOCKETS[index]
    x, y = _kg_at(radius, bearing)
    ground = _kg_floor(x, y)
    bm = bmesh.new()
    tapered_cylinder(bm, ground - 1.4, ground + 1.5, 7.6, 6.4, sides=14, center=(x, y))
    for i in range(9):
        angle = (i / 9.0) * TAU + index
        cx, cy = x + math.cos(angle) * 6.6, y + math.sin(angle) * 6.6
        cone(bm, (cx, cy, ground + 0.8), (cx + math.cos(angle) * 1.1, cy + math.sin(angle) * 1.1, ground + 3.4), 1.5, sides=5)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenGullet_Socket%d" % (index + 1), bm, KG_COLLAR)


def build_kg_dais(rng):
    """The finale chamber's floor: a raised plate at the centre with a lip, so
    'inside the heart chamber' and 'outside it' are two readable places."""
    bm = bmesh.new()
    ground = _kg_floor(0.0, 0.0)
    tapered_cylinder(bm, ground - 2.0, ground + 2.2, KG_DAIS_R, KG_DAIS_R - 2.4, sides=26)
    for i in range(26):
        angle = (i / 26.0) * TAU
        if i % 7 == 3:
            continue  # four ways up onto it
        cx, cy = math.cos(angle) * (KG_DAIS_R - 1.6), math.sin(angle) * (KG_DAIS_R - 1.6)
        box(bm, (cx, cy, ground + 3.0), (4.2, 2.0, 1.6), Matrix.Rotation(angle + math.pi / 2.0, 3, "Z"))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenGullet_Dais", bm, KG_PAD)


def build_kg_heart(rng):
    """The heart: a lumped mass slung over the dais on four great vessels that
    run into the roof. It is the landmark you see from the entry pad."""
    bm = bmesh.new()
    add_blob(bm, (0.0, 0.0, KG_HEART_Z), (17.0, 14.5, 18.5), 0.34, salt=2.7, subdiv=2)
    add_blob(bm, (0.0, -7.0, KG_HEART_Z + 8.0), (9.5, 8.0, 9.0), 0.30, salt=5.1, subdiv=2)
    for i in range(4):
        angle = (i / 4.0) * TAU + 0.4
        top = Vector((math.cos(angle) * 26.0, math.sin(angle) * 26.0, KG_H * 0.86))
        taper_between(bm, (math.cos(angle) * 8.0, math.sin(angle) * 8.0, KG_HEART_Z + 10.0), top, 4.2, 2.4, sides=6)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenGullet_Heart", bm, KG_HEART)


def build_kg_heart_glow(rng):
    """SEAMS across the heart, not a core inside it. The first pass authored an
    inner blob smaller than the mass around it, which is a Neon part nobody can
    ever see - the classic silent-absence shape. These stand 1.5 studs PROUD of
    the hide, so the landmark actually glows."""
    bm = bmesh.new()
    for i in range(5):
        yaw = i * (math.pi / 5.0)
        add_blob(bm, (0.0, 0.0, KG_HEART_Z), (18.4, 2.9, 19.9), 0.16, salt=2.7 + i, yaw=yaw, subdiv=2)
    add_blob(bm, (0.0, -7.0, KG_HEART_Z + 8.0), (10.6, 2.4, 10.1), 0.14, salt=6.3, yaw=0.4, subdiv=2)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenGullet_HeartGlow", bm, KG_HEARTGLOW)


def build_kg_entry(rng):
    """Where the party appears. A pale chitin plate, off the heart's bearing,
    far enough back that the first thing you do is LOOK at the heart."""
    bm = bmesh.new()
    x, y = KG_ENTRY
    ground = _kg_floor(x, y)
    tapered_cylinder(bm, ground - 1.6, ground + 1.1, KG_ENTRY_R, KG_ENTRY_R - 1.4, sides=18, center=(x, y))
    for i in range(6):
        angle = (i / 6.0) * TAU
        cx, cy = x + math.cos(angle) * (KG_ENTRY_R - 0.8), y + math.sin(angle) * (KG_ENTRY_R - 0.8)
        cone(bm, (cx, cy, ground + 0.9), (cx, cy, ground + 3.6), 1.4, sides=5)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenGullet_EntryPad", bm, KG_PAD)


def build_kg_veins(rng):
    """Glowing veins up the walls. The room's only light source, and the
    breadcrumb from the entry pad to the heart."""
    bm = bmesh.new()
    for k in range(16):
        bearing = (k / 16.0) * TAU + 0.21
        radius = _kg_wall_r(bearing) * 0.965
        prev = None
        for s in range(11):
            t = s / 10.0
            phi = t * (math.pi / 2.0) * 0.92
            wobble = noise.noise(Vector((k * 1.7, t * 4.0, 0.0))) * 0.10
            angle = bearing + wobble
            rad = radius * math.cos(phi) ** 0.78
            here = Vector((math.cos(angle) * rad, math.sin(angle) * rad, KG_H * math.sin(phi) ** 0.9))
            if prev is not None:
                taper_between(bm, prev, here, 0.75, 0.55, sides=4)
            prev = here
    for radius, bearing in KG_SOCKETS:
        x, y = _kg_at(radius, bearing)
        ground = _kg_floor(x, y)
        prev = Vector((x, y, ground + 0.4))
        for s in range(1, 7):
            t = s / 6.0
            here = Vector((x * (1.0 - t * 0.92), y * (1.0 - t * 0.92), _kg_floor(x * (1.0 - t * 0.92), y * (1.0 - t * 0.92)) + 0.4))
            taper_between(bm, prev, here, 0.55, 0.45, sides=4)
            prev = here
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenGullet_VeinGlow", bm, KG_VEINGLOW)


def build_kg_gut(rng):
    """What the Kraken has swallowed: hull planking, spars, an anchor, bones.
    Deco, so none of it can catch a foot in a room this tight."""
    bm = bmesh.new()
    for _ in range(30):
        bearing = rng.uniform(0.0, 360.0)
        radius = rng.uniform(34.0, 110.0)
        x, y = _kg_at(radius, bearing)
        if math.hypot(x - KG_ENTRY[0], y - KG_ENTRY[1]) < KG_ENTRY_R + 5.0:
            continue
        ground = _kg_floor(x, y)
        rot = Matrix.Rotation(rng.uniform(0.0, TAU), 3, "Z") @ Matrix.Rotation(rng.uniform(-0.4, 0.4), 3, "X")
        box(bm, (x, y, ground + 0.5), (rng.uniform(5.0, 16.0), rng.uniform(0.9, 2.4), rng.uniform(0.5, 1.4)), rot)
        if rng.random() < 0.35:
            taper_between(bm, (x, y, ground), (x + rng.uniform(-6, 6), y + rng.uniform(-6, 6), ground + rng.uniform(3, 9)), 0.9, 0.4, sides=5)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return finish("KrakenGullet_GutDeco", bm, KG_GUT)


def build_kraken_gullet():
    rng = random.Random(90803)
    sockets = [build_kg_socket(i, rng) for i in range(len(KG_SOCKETS))]
    objects = [
        build_kg_base(rng),
        build_kg_walls(rng),
        build_kg_ribs(rng),
        build_kg_dais(rng),
        build_kg_heart(rng),
        build_kg_heart_glow(rng),
        build_kg_entry(rng),
        *sockets,
        build_kg_veins(rng),
        build_kg_gut(rng),
    ]
    print("HANDOFF kraken-gullet: PHASE 3 is a SEPARATE MESH and a SEPARATE PLACE - `KrakenGullet_*`, authored around its own origin, z=0 is the FLOOR datum and NOT the waterline. Place it far from the world like the other lairs and teleport into it")
    print("HANDOFF kraken-gullet: playable footprint ~%.0f x %.0f (wall foot r %.0f), ceiling apex z %.0f - the brief's 200x200x80" % (KG_R * 2.0, KG_R * 2.0, KG_R, KG_H))
    print("HANDOFF kraken-gullet: floor is a shallow dish, z %.1f at the centre to %.1f at the wall - walkable everywhere, no jump gated on it" % (_kg_floor(0.0, 0.0), _kg_floor(KG_R, 0.0)))
    print("HANDOFF kraken-gullet: ENTRY PAD centre (%.1f, %.1f), top z %.1f, r %.0f - drop the party here facing +Y and the heart is dead ahead at %.0f studs" % (KG_ENTRY[0], KG_ENTRY[1], _kg_floor(*KG_ENTRY) + 1.1, KG_ENTRY_R, abs(KG_ENTRY[1])))
    print("HANDOFF kraken-gullet: FINALE CHAMBER - dais centre (0, 0), r %.0f, top z %.1f; the HEART mass is slung over it centred (0, 0, %.0f), ~34 x 29 x 37, on four vessels into the roof" % (KG_DAIS_R, _kg_floor(0.0, 0.0) + 2.2, KG_HEART_Z))
    print("HANDOFF kraken-gullet: the dais lip is broken in four places (bearings ~40, 137, 235, 332) - those are the ways up onto it")
    for index, (radius, bearing) in enumerate(KG_SOCKETS):
        x, y = _kg_at(radius, bearing)
        print(
            "HANDOFF kraken-gullet: Socket%d at r %.0f bearing %.0f deg = (%.1f, %.1f), collar top z %.1f - plant a destructible growth here"
            % (index + 1, radius, bearing, x, y, _kg_floor(x, y) + 1.5)
        )
    print("HANDOFF kraken-gullet: COLLISION - PreciseConvexDecomposition REQUIRED on `KrakenGullet_Walls` (it is a hollow dome; a default hull fills the room solid) and on `_Base` (a dished floor). Default hull is fine for `_Ribs`, `_Dais`, `_EntryPad`, `_Socket1..6`, `_Heart`")
    print("HANDOFF kraken-gullet: `_HeartGlow` and `_VeinGlow` carry `Glow` and go Neon; `_GutDeco` is stripped of collision and query")
    print("HANDOFF kraken-gullet: the room has NO sky and NO sun - it needs an arena lighting override or the Neon veins are all the player gets")
    print("HANDOFF kraken-gullet: run `python3 tools/gen_mesh_colors.py` after this import - %d new object names need MeshColors rows or they arrive grey" % len(objects))
    return objects


# ---------------------------------------------------------------- preview props
#
# Objects that exist ONLY in a render: 5-stud player stand-ins, a proxy head at
# the contract scale, and the plan shot's dimension labels. They are built
# inside render_preview, AFTER export, so nothing here can reach a glb.


def _ka_figure(bm, x, y, z):
    """A 5-stud player - the scale reference every arena shot has to carry."""
    for side in (-1.0, 1.0):
        box(bm, (x, y + side * 0.42, z + 1.1), (0.72, 0.72, 2.2))
    box(bm, (x, y, z + 3.1), (1.0, 2.0, 1.8))
    box(bm, (x, y, z + 4.5), (1.2, 1.2, 1.2))


def _ka_sea():
    """A preview-only sea plane at z=0. Without it every kraken shot renders
    the DROWNED REEF as if it were ground, and the arena reads as a saucer on
    a plate instead of two lit stones in open water - i.e. the preview lies
    about the one thing these shots exist to judge."""
    bm = bmesh.new()
    tapered_cylinder(bm, -0.6, -0.02, 3000.0, 3000.0, sides=64)
    finish("PreviewSea", bm, (0.062, 0.086, 0.118))


def _ka_figures():
    """Crew and challengers, on all three decks. Two are tucked at cover
    pieces on purpose: the money shot's whole job is to say whether the cover
    read works, and it cannot say that with nobody using it."""
    bm = bmesh.new()
    for x, y in ((-30.0, 6.0), (-8.0, -8.0), (14.0, 7.0), (30.0, -4.0), (44.0, 9.0)):
        _ka_figure(bm, x, y, KA_DECK_Z)
    # At the aft cargo stack and behind the coaming - the two cover reads.
    _ka_figure(bm, KA_COVER[3][1] + 8.0, KA_COVER[3][2], KA_DECK_Z)
    _ka_figure(bm, KA_COVER[1][1], KA_COVER[1][2] - 8.4, KA_DECK_Z)
    _ka_figure(bm, KA_SPAWN_X, 0.0, KA_QD_Z)
    _ka_figure(bm, -50.0, 6.0, KA_QD_Z)
    _ka_figure(bm, 62.0, -5.0, KA_FC_Z)
    finish("PreviewFigure", bm, (0.92, 0.86, 0.36))


def _ka_bezier(p0, c0, c1, p1, t):
    u = 1.0 - t
    return (
        Vector(p0) * (u * u * u)
        + Vector(c0) * (3.0 * u * u * t)
        + Vector(c1) * (3.0 * u * t * t)
        + Vector(p1) * (t * t * t)
    )


def _ka_wrap_arm(bm, index):
    """One arm arching off the head and DOWN ONTO A WRAP POINT - over the near
    rail for the port pair, and clean over the whole ship, masts and all, for
    the starboard pair. This is the reference the user gave (tentacles coming
    over a galleon's rails from both sides) and the previews are worthless
    without it: the deck is judged on what it looks like UNDER those arms."""
    wrap_x, wrap_y, deck = _ka_wrap_point(index)
    head_x, head_y = KA_HEAD_AT
    far = wrap_y < 0.0  # a starboard wrap: the arm has to cross the whole ship
    start = (head_x + wrap_x * 0.5, head_y - KA_HEAD_W * 0.42, 84.0 if far else 62.0)
    control_a = (wrap_x * 0.7 + head_x * 0.3, head_y * 0.45, 190.0 if far else 120.0)
    control_b = (wrap_x, 62.0 if far else 34.0, 168.0 if far else 86.0)
    prev = None
    for s in range(17):
        here = _ka_bezier(start, control_a, control_b, (wrap_x, wrap_y, deck + 2.4), s / 16.0)
        if prev is not None:
            t = s / 16.0
            taper_between(bm, prev, here, 30.0 * (1.0 - t) + 5.0, 30.0 * (1.0 - t - 0.06) + 5.0, sides=7)
        prev = here
    # The tip curls inboard over the rail - the read that says WRAPPED rather
    # than merely landed.
    tip = Vector((wrap_x, wrap_y, deck + 2.4))
    inboard = math.copysign(1.0, -wrap_y)
    for s in range(5):
        t = (s + 1) / 5.0
        here = tip + Vector((math.sin(t * 2.4) * 5.0, inboard * t * 15.0, -1.2 - t * 0.6))
        taper_between(bm, prev, here, 5.0 - t * 3.2, 5.0 - t * 3.6, sides=6)
        prev = here


def _ka_proxy_head():
    """The head at the contract scale, standing 370 studs off the port beam: a
    360-wide, 480-tall mantle with the arm crown slung under it (boss_gen's own
    description), arms trailing into the water, and FOUR wrapping the ship.
    Preview only - built after export, destroyed after the shot."""
    bm = bmesh.new()
    head_x, head_y = KA_HEAD_AT
    add_blob(
        bm,
        (head_x, head_y, KA_HEAD_H * 0.52),
        (KA_HEAD_W / 2.0, KA_HEAD_W / 2.0, KA_HEAD_H * 0.5),
        0.10,
        salt=1.3,
        subdiv=3,
    )
    add_blob(bm, (head_x, head_y, 46.0), (132.0, 132.0, 46.0), 0.14, salt=4.4, subdiv=2)
    for i in range(8):
        bearing = 20.0 + i * 45.0
        if 200.0 < bearing < 340.0:
            continue  # that side faces the ship, and the wrap arms own it
        angle = math.radians(bearing)
        base = Vector((head_x + math.cos(angle) * 105.0, head_y + math.sin(angle) * 105.0, 34.0))
        mid = Vector((head_x + math.cos(angle) * 180.0, head_y + math.sin(angle) * 180.0, -6.0))
        tip = Vector((head_x + math.cos(angle) * 240.0, head_y + math.sin(angle) * 240.0, -34.0))
        taper_between(bm, base, mid, 26.0, 15.0, sides=6)
        taper_between(bm, mid, tip, 15.0, 5.0, sides=6)
    for index in range(len(KA_WRAPS)):
        _ka_wrap_arm(bm, index)
    finish("PreviewProxyHead", bm, (0.20, 0.13, 0.30))


def _ka_label(text, x, y, z, size, rot_z=0.0):
    bpy.ops.object.text_add(location=(x, y, z), rotation=(0.0, 0.0, rot_z))
    obj = bpy.context.object
    obj.data.body = text
    obj.data.size = size
    obj.data.align_x = "CENTER"
    obj.data.align_y = "CENTER"
    obj.data.materials.append(make_material("PreviewLabel", (0.98, 0.87, 0.32)))
    # A label floating 26 studs over the sea casts a hard shadow onto it, and
    # the plan shot came back with every callout printed TWICE, offset.
    obj.visible_shadow = False
    return obj


def _ka_plan_props():
    """The plan shot's dimension callouts. Text objects, not geometry - a
    'top-down with the dimensions labelled' brief is not met by an unlabelled
    silhouette. The proxy head is deliberately ABSENT from this shot: an
    opaque 360-wide mantle 370 studs away either covers the ship or forces the
    frame so wide that nothing on the ship can be read, and the first pass of
    the causeway plan lost its whole subject that way."""
    bm = bmesh.new()
    # Everything stands at z 74-80, clear of the mainmast top's 70 and the
    # flag, so no rule is drawn buried inside the rig.
    rule_z = 74.0
    for x in (-KA_SHIP_LEN / 2.0, KA_SHIP_LEN / 2.0):
        box(bm, (x, 0.0, rule_z), (2.0, 54.0, 1.0))
    box(bm, (0.0, -34.0, rule_z), (KA_SHIP_LEN, 2.0, 1.0))
    for x in (KA_QD_FRONT, KA_FC_AFT):
        box(bm, (x, 0.0, rule_z), (2.0, 46.0, 1.0))
    box(bm, ((KA_QD_FRONT + KA_FC_AFT) / 2.0, 26.0, rule_z), (KA_FC_AFT - KA_QD_FRONT, 2.0, 1.0))
    box(bm, (0.0, 0.0, rule_z), (2.0, KA_SHIP_BEAM, 1.0))
    # The bearing to the head: an arrow off the port beam, since the head
    # itself cannot be in this frame.
    box(bm, (0.0, 44.0, rule_z), (2.0, 42.0, 1.0))
    for side in (-1.0, 1.0):
        box(bm, (side * 4.0, 60.0, rule_z), (10.0, 2.0, 1.0), Matrix.Rotation(math.radians(side * 40.0), 3, "Z"))
    # The four wrap points, ringed where the arms land.
    for index in range(len(KA_WRAPS)):
        wrap_x, wrap_y, _deck = _ka_wrap_point(index)
        for i in range(16):
            angle = (i / 16.0) * TAU
            box(
                bm,
                (wrap_x + math.cos(angle) * 6.5, wrap_y + math.sin(angle) * 6.5, rule_z),
                (2.2, 2.2, 1.0),
            )
    finish("PreviewRule", bm, (0.98, 0.87, 0.32)).visible_shadow = False
    # Every callout stands CLEAR OF THE HULL FOOTPRINT (|y| > 24) and at the
    # same z as the rules, so the two share one projection. The first pass put
    # them at a different height and over the deck, and the render came back
    # with the layout it was measuring hidden underneath its own labels.
    _ka_label("GALLEON 170 x 40", 0.0, -50.0, rule_z, 10.0)
    _ka_label("PHASE 1 WAIST  90 x 34", 5.0, 34.0, rule_z, 8.0)
    _ka_label("QUARTERDECK +9", -62.0, -30.0, rule_z, 7.0)
    _ka_label("FORECASTLE +7", 66.0, -30.0, rule_z, 7.0)
    _ka_label("SPAWN", KA_SPAWN_X, -40.0, rule_z, 6.5)
    _ka_label("HEAD 350 THIS WAY  (480 TALL)", 0.0, 72.0, rule_z, 9.0)
    for index, (label, _wrap_x, _side) in enumerate(KA_WRAPS):
        wrap_x, wrap_y, _deck = _ka_wrap_point(index)
        _ka_label(label.upper(), wrap_x, math.copysign(42.0, wrap_y), rule_z, 6.0)


def _kg_lights():
    """The gullet is a CLOSED DOME, so SCENE's sun is outside it and the first
    render of this arena came back a black frame. Interior point lights, warm
    and falling off, are what a body would be lit by - and they are preview
    props like everything else here, torn down after the shot."""
    # Energies MEASURED off the render, not guessed: the first pass ran 6x
    # hotter and the whole room came back one flat pale pink, which threw away
    # the value ladder these colours were chosen for (wall UNDER floor, bone
    # over both). An interior preview is a lighting problem before it is a
    # geometry one.
    for x, y, z, energy in (
        (0.0, 0.0, 54.0, 230000.0),
        (0.0, -74.0, 30.0, 84000.0),
        (66.0, 44.0, 34.0, 76000.0),
        (-66.0, 26.0, 34.0, 76000.0),
        (0.0, 0.0, 15.0, 46000.0),
    ):
        light = bpy.data.lights.new("PreviewGutLight", "POINT")
        light.energy = energy
        light.shadow_soft_size = 14.0
        light.color = (1.0, 0.60, 0.56)
        obj = bpy.data.objects.new("PreviewGutLight", light)
        obj.location = (x, y, z)
        bpy.context.collection.objects.link(obj)


def _kg_figures():
    bm = bmesh.new()
    x, y = KG_ENTRY
    _ka_figure(bm, x, y + 4.0, _kg_floor(x, y) + 1.1)
    _ka_figure(bm, x + 5.0, y - 2.0, _kg_floor(x + 5.0, y - 2.0) + 1.1)
    _ka_figure(bm, 0.0, -34.0, _kg_floor(0.0, -34.0))
    for radius, bearing in KG_SOCKETS[:3]:
        px, py = _kg_at(radius - 10.0, bearing)
        _ka_figure(bm, px, py, _kg_floor(px, py))
    finish("PreviewFigure", bm, (0.92, 0.86, 0.36))


def _ph_lights():
    """The heart chamber is SEALED - no sky, no sun - so SCENE's key is outside
    it and every unlit render of this arena comes back black. These are the
    lights a body in here would actually have: the heart on the dais, the six
    vent mouths on the wall, and a low bounce off the floor's veins. Preview
    props, torn down after the shot.

    WARM AND DIM ON PURPOSE, and the energies below are MEASURED off the render
    rather than guessed. The gullet's first pass ran its interior lights 6x hot
    and came back one flat pale pink, throwing away the value ladder its colours
    were chosen for; this room's first pass did exactly the same at 300k on the
    heart, and the fix was to cut every light by roughly six. The trap is worse
    here than in the gullet, because the whole read of this chamber is that the
    only bright things in it are molten - the moment the rock is lit as brightly
    as the magma, it is a beige dome."""
    ground = _ph_floor(0.0, 0.0)
    lights = [(0.0, 0.0, ground + PH_HEART_Z, 52000.0, (1.0, 0.38, 0.10))]
    for bearing, height in PH_VENTS:
        radius = _ph_wall_at(math.radians(bearing), height) - 9.0
        x, y = _ph_at(radius, bearing)
        lights.append((x, y, height + 1.0, 9000.0, (1.0, 0.30, 0.07)))
    lights.append((0.0, -52.0, 4.0, 5000.0, (1.0, 0.42, 0.18)))
    for bearing in (55.0, 175.0, 300.0):
        x, y = _ph_at(58.0, bearing)
        lights.append((x, y, 5.0, 3600.0, (1.0, 0.46, 0.22)))
    for x, y, z, energy, colour in lights:
        light = bpy.data.lights.new("PreviewHeartLight", "POINT")
        light.energy = energy
        light.shadow_soft_size = 10.0
        light.color = colour
        obj = bpy.data.objects.new("PreviewHeartLight", light)
        obj.location = (x, y, z)
        bpy.context.collection.objects.link(obj)


def _ph_pillars():
    """THE EIGHT PILLARS, as PREVIEW STAND-INS ONLY - in game they are runtime
    creatures (`pyrelisk_pillar`) planted on the authored collars, so nothing
    of them belongs in the glb. Built here, after export, purely so the cover
    shot can answer the question that shot exists to ask: standing on the entry
    pad, is there something to hide behind, and is it obvious?"""
    bm = bmesh.new()
    for index, (radius, bearing) in enumerate(PH_SOCKETS):
        x, y = _ph_at(radius, bearing)
        ground = _ph_floor(x, y) + 1.8
        height = 26.0 + (index % 3) * 3.5
        tapered_cylinder(bm, ground, ground + height, 5.6, 3.8, sides=6, center=(x, y))
        cone(bm, (x, y, ground + height), (x, y, ground + height + 5.0), 3.8, sides=6)
    finish("PreviewPillar", bm, (0.055, 0.055, 0.080))


def _ph_figures():
    bm = bmesh.new()
    x, y = PH_ENTRY
    _ka_figure(bm, x - 3.5, y + 6.0, _ph_floor(x, y) + 1.4)
    _ka_figure(bm, x + 4.5, y + 4.0, _ph_floor(x, y) + 1.4)
    for radius, bearing in (PH_SOCKETS[0], PH_SOCKETS[3], PH_SOCKETS[6]):
        px, py = _ph_at(radius - 9.0, bearing)
        _ka_figure(bm, px, py, _ph_floor(px, py))
    finish("PreviewFigure", bm, (0.92, 0.86, 0.36))


# Keyed by ARENA NAME + SHOT SUFFIX, and built/destroyed around that one shot.
# Per-shot rather than per-arena because the plan shot needs the DIMENSION
# RULES and must NOT have the proxy head (it covers the ring it is measuring),
# and the eye-level shots need the head and must not have labels floating in
# the sky.
PREVIEW_PROPS = {
    "kraken": (_ka_sea, _ka_figures, _ka_proxy_head),
    "kraken_wide": (_ka_sea, _ka_figures, _ka_proxy_head),
    "kraken_stern": (_ka_sea, _ka_figures, _ka_proxy_head),
    "kraken_plan": (_ka_sea, _ka_figures, _ka_plan_props),
    "kraken_gullet": (_kg_lights, _kg_figures),
    "kraken_gullet_wide": (_kg_lights, _kg_figures),
    "kraken_gullet_heart": (_kg_lights, _kg_figures),
    # The heart chamber is sealed, so it carries its own lights in every shot -
    # and the pillars are runtime creatures, so the stand-ins that make the
    # cover readable are props too.
    "pyrelisk_heart": (_ph_lights, _ph_pillars, _ph_figures),
    "pyrelisk_heart_pillars": (_ph_lights, _ph_pillars, _ph_figures),
}


ARENAS = {
    "brinejaw": build_brinejaw,
    "gnashroot": build_gnashroot,
    "wrack": build_wrack,
    "rimefang": build_rimefang,
    "noctyss": build_noctyss,
    "pyrelisk": build_pyrelisk,
    "pyrelisk_heart": build_pyrelisk_heart,
    "kraken": build_kraken,
    "kraken_gullet": build_kraken_gullet,
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
    floor, floor_of = None, None
    for obj in objects:
        lo = [min(v.co[i] for v in obj.data.vertices) for i in range(3)]
        hi = [max(v.co[i] for v in obj.data.vertices) for i in range(3)]
        print(
            "  %s bbox x %.1f..%.1f  y %.1f..%.1f  z %.1f..%.1f"
            % (obj.name, lo[0], hi[0], lo[1], hi[1], lo[2], hi[2])
        )
        if floor is None or lo[2] < floor:
            floor, floor_of = lo[2], obj.name
    # MEASURED, and printed HERE rather than by each builder, because this is
    # the only place that has seen every object.
    #
    # BossArenaService.placeAuthored pins the WHOLE MODEL's bbox bottom, so the
    # floor is the minimum across everything exported. Builders used to derive
    # it from their skirt constant instead, which is a claim about the build
    # rather than a measurement of it - and the claim was wrong for Pyrelisk by
    # 75 studs, because its cloud-deck billows hang further down than the flank
    # the constant described. Nobody would think of decorative geometry as
    # load-bearing for placement, which is exactly why deriving cannot be
    # trusted: ANY object added later can silently become the new floor, and a
    # derived line would never notice.
    #
    # NOTE WHAT THIS PRINTS AND WHAT IT DOES NOT. The floor is a measurement.
    # `meshBottom` is a DECISION on top of it, because pinning the floor to F
    # puts authored z at world Y = z + (F - floor) - so the field encodes where
    # you want authored z=0 to land. For an arena built at sea level that is
    # simply the floor. Pyrelisk's summit is meant to sit at world Y +292, so
    # its correct value is +292 + floor, and a line here that just said "SET
    # meshBottom = <floor>" would have contradicted its own row while looking
    # every bit as authoritative. Print the measurement and the rule; let the
    # arena's owner supply the altitude.
    if floor is not None:
        print(
            "HANDOFF: measured bbox floor %.3f across all %d objects (lowest: %s)"
            % (floor, len(objects), floor_of)
        )
        print(
            "HANDOFF: BossArenas meshBottom = (world Y you want authored z=0 at) + (%.3f); "
            "%.3f for a sea-level arena" % (floor, floor)
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
        # Three-quarter from off the seaward quarter, high enough to hold the
        # whole 264-stud floor: the one read that has to survive is an empty
        # beach with a ring of dead ships round the edge of it.
        ("", (300, 330, 205), None, (0, -8, 4), 34),
        # STRAIGHT DOWN. The plan is the honest test of "plain and uncluttered"
        # - a three-quarter shot can hide clutter behind the palisade, an
        # overhead cannot hide anything. It is also the fight's own camera
        # angle, pitched further.
        # Lens 38, not the tighter figure the first pass reached for: the frame
        # is 1500x950, so it is the VERTICAL half-angle that has to cover the
        # 176-stud rim, and 18mm of horizontal room says nothing about that.
        ("_plan", (0, -30, 640), None, (0, 0, 0), 38),
        # Standing at the head of the beach at player eye height, looking down
        # the fall line and out through the mouth: the shot that says whether
        # the floor is walkable, whether it shelves, and how far away the wall
        # actually is.
        ("_ground", (0.0, -118.0, 10.4), None, (0.0, 152.0, 3.0), 24),
    ],
    "noctyss": [
        ("", (0, -215, 125), None, (0, 0, 2), 30),
        # Standing on the shelf between two sockets, looking across the pit -
        # the eyeline the fight is actually read from.
        ("_ground", (15, -60, 6.6), None, (0, 0, 1.5), 26),
        # Water level off the rim: the silhouette the party teleports into -
        # spires, the drop, and no wall anywhere on it.
        ("_approach", (0, -152, 9), None, (0, 0, 12), 34),
        # Down the pit's throat: the hole the maw comes up through, and the
        # fallen slab that gets you back out of it.
        ("_pit", (30, -34, 26), None, (0, 0, -4), 32),
        # LOW ACROSS HER BACK, toward the mouth: the one shot that has to answer
        # the note this pass exists for - do the stalks and the maw read as ONE
        # animal, or as two. Low, 11 degrees of elevation, because a ridge two
        # studs tall vanishes from any camera high enough to be comfortable.
        # BEARING 235 is chosen, not casual: it splits sockets 5 (218) and 6
        # (269) so two ridges rake away from the lens on either side and the
        # other five converge on the rolled lip beyond, and it stands off the
        # 252-degree shadow fin far enough that the fin does not eat the frame.
        # The first take stood at r 50 on socket 5's own bearing and rendered
        # that socket's root collar as a wall four studs from the lens; the
        # second, at r 66 and 14 up, put a shadow fin and its shadow across the
        # near half of the frame. r 78 and 28 up is the compromise that holds
        # all seven roots AND the lip in one frame while staying low enough
        # that a two-stud ridge still throws a shadow along its own flank.
        ("_mantle", (-44.7, -63.9, 28.0), None, (0, 0, 0.5), 32),
    ],
    "pyrelisk": [
        # The summit standing out of the cloud deck with lower peaks around
        # it: the shot that has to answer "am I on a mountain or an island".
        ("", (760, -980, 300), None, (0, 20, -150), 38),
        # Standing on the rim path, looking across the caldera lake at the far
        # rim - the fight's own eyeline, and the proof the path is flat and
        # the lake is a moat.
        ("_ground", (0, -196, 5.4), None, (0, 120, 26), 26),
        # AT A NOTCH, looking out and down: the vista window. Cloud below,
        # peaks below that, no sea and no bottom anywhere.
        ("_vista", (-46.0, 184.0, 24.0), None, (-266.0, 1070.0, -290.0), 26),
        # Straight down: the ring layout and the dial.
        ("_top", (0, -40, 700), None, (0, 0, 0), 30),
    ],
    # ACT FOUR, and EVERY CAMERA STANDS INSIDE THE DOME. The wall's inner
    # radius at height z is ~(90..102) * cos(asin((z/72)^1.053))^0.62, so a
    # camera at r 84 is inside at the floor and a camera at r 84 and z 34 is
    # inside by four studs; anything outside that renders a black frame, which
    # reads as a build failure rather than a framing one. There is no sun in
    # this room either - see PREVIEW_PROPS, which lights it off the heart and
    # the six vents.
    "pyrelisk_heart": [
        # FROM THE ENTRY PAD, which is the only view of this room the fight
        # ever begins from: the heart 74 studs dead ahead on its dais, pillars
        # either side of the line to it, and vent mouths on the wall beyond.
        ("", (0.0, -86.0, 15.0), None, (0.0, 4.0, 17.0), 20),
        # THE COVER SHOT. Three-quarter and high enough to hold the whole
        # pillar ring, because the question it has to answer is the sponson
        # rule's: are there eight of them, do they read as things to hide
        # behind, and is any one of them standing in another's shadow.
        ("_pillars", (-14.0, -79.0, 36.0), None, (2.0, 6.0, 6.0), 16),
    ],
    "kraken": [
        # THE MONEY SHOT, and the headline file. Deck level at the after end
        # of the waist, on the starboard side, looking forward and to PORT so
        # the frame holds three things at once: the deck raking away to the
        # bow, arms coming over BOTH rails, and the head beyond the port side.
        # 14mm is not a stylistic choice - the head is 52 degrees of elevation
        # at this range and it sits 80 degrees off the ship's axis, so nothing
        # longer can hold the deck and the boss in one frame. That IS the
        # player's problem too, which is exactly why the shot is worth taking.
        # Stand IN THE WAIST, not on the quarterdeck: x -58 is inside the
        # stern castle's solid block and the first render of this shot came
        # back a black frame. x -30 is clear of the quarterdeck stairs (which
        # end at -31) and of the aft cargo stack's corner.
        ("", (-20.0, -16.0, 13.2), None, (62.0, 74.0, 44.0), 14),
        # Straight down, with the dimension rules and labels. The plan is the
        # honest test of a layout - a three-quarter shot can flatter any
        # distance, an overhead cannot. Framed on the SHIP alone (see
        # _ka_plan_props for why the head is not in it).
        # A ROTATION, not a look_at: aimed by a target the parallax on the
        # callouts is oblique and every label drifts onto the hull it is
        # naming. Straight down, the labels only scale radially, which is
        # predictable enough to lay them out against.
        ("_plan", (0.0, 0.0, 520.0), (0, 0, 0), None, 60),
        # FROM THE SPAWN PAD: the first second of the fight, from the dais on
        # the quarterdeck looking down the length of the ship. It answers the
        # only question a spawn shot can - can you see the whole fight, and
        # can you see what is coming, from where you land.
        ("_stern", (-100.0, -7.0, 31.0), None, (36.0, 16.0, 20.0), 20),
        # Three-quarter from off the starboard bow: the establishing shot, and
        # the one that has to answer "does a 480-stud head at 350 studs still
        # read as ENORMOUS next to a 170-stud ship".
        ("_wide", (330.0, -300.0, 240.0), None, (10.0, 130.0, 120.0), 30),
    ],
    "kraken_gullet": [
        # From behind the entry pad, looking at the heart: the first second of
        # phase 3, and the shot that says whether the landmark reads. Every
        # camera in here must stand INSIDE the dome - the first pass put this
        # one at r 104 and `_wide` at r 133, which is embedded in the wall and
        # outside it respectively, and both rendered a black frame. The wall's
        # radius at height z is ~(105..131) * cos(asin((z/82)^1.111))^0.78.
        # The RIBS are the second trap: seven arches on bearings 6 + k*25.7
        # (and +180) sweep through the apex, so a high camera near the middle
        # ends up inside one - which is also a black frame. Stand off a rib
        # bearing by ~13 degrees and keep some radius, as `_wide` does.
        ("", (0.0, -94.0, 26.0), None, (0.0, 0.0, 15.0), 24),
        # High off one shoulder of the dome - the ribs, the socket ring, and
        # how much floor there actually is.
        ("_wide", (11.0, -48.0, 60.0), None, (0.0, -6.0, 2.0), 14),
        # In close on the finale chamber.
        ("_heart", (0.0, -58.0, 20.0), None, (0.0, 0.0, 22.0), 30),
    ],
    "rimefang": [
        ("", (196, -262, 132), None, (0, 0, 4), 30),
        # Standing on the floe in the drop-in lane, looking across the clean
        # fight floor at the far rim. The point of this shot in v2 is what is
        # NOT in it: from a player's eye height there is nothing between here
        # and the pressure ridge 240 studs away.
        ("_ground", (10, -96, 6.6), None, (-30, 60, 11), 24),
        # From the water outside the ridge: the silhouette you sail up on,
        # with the wreck and the near berg reading as the backdrop they are.
        ("_approach", (-300, 53, 20), None, (0, 0, 10), 40),
        # Straight down. The plan is the shot that PROVES the brief - one
        # clean disc, a ring of rubble round it, and every solid object
        # outside that ring.
        ("_plan", (0, 0, 430), (0, 0, 0), None, 24),
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
    # White ice blows out fast, and EEVEE gives it no bounce: a cold sky, a
    # softer key and a real fill are what keep the floe's forms readable
    # instead of one sheet of clipped highlight.
    "rimefang": {"bg": (0.34, 0.45, 0.56, 1.0), "sun": 1.7, "fill": 0.12},
    # The trench is judged in a lit room it will never be seen in: near-black
    # rock needs a hard key and a strong fill or the whole arena renders as one
    # flat shape. In game this shelf sits under the gloom dark, lit by the
    # choir - the preview's job is the GEOMETRY, not the mood.
    # Black rock, an orange floor and a lava pool: the sky is ash, the key is
    # low and warm like late light through smoke, and the fill exists only so
    # the obsidian keeps its facets instead of going to one silhouette.
    "pyrelisk": {"bg": (0.415, 0.360, 0.330, 1.0), "sun": 2.4, "fill": 0.55, "clip": 20000.0},
    "noctyss": {"bg": (0.055, 0.062, 0.092, 1.0), "sun": 1.8, "fill": 0.5},
    # Storm over open water: a bruised sky, a hard raking key so the deck
    # furniture throws the shadow that MAKES it readable (the cover is the
    # mechanic and a flat render hides it), and a cool fill so the proxy head
    # and its arms do not go to pure silhouette. `clip` because the head
    # stands 370 studs off the beam and reaches 480 up - Blender's default
    # 1000 clips the top off it from the wide shot.
    "kraken": {"bg": (0.128, 0.148, 0.186, 1.0), "sun": 1.9, "fill": 0.45, "clip": 8000.0},
    # Inside a body. There is no sky and no sun in here; the preview lights it
    # anyway, because the preview's job is the GEOMETRY - the mood is the
    # runtime's lighting override (see the gullet HANDOFF).
    "kraken_gullet": {"bg": (0.045, 0.020, 0.026, 1.0), "sun": 1.5, "fill": 0.60},
    # Inside the volcano. Sealed, so the "sky" is only what leaks past the
    # geometry and the key is nearly off: the room is LIT BY ITS OWN MAGMA
    # (PREVIEW_PROPS' point lights), and a sun strong enough to model the
    # obsidian would also tell the lie this arena must not tell - that there is
    # daylight in here. The fill exists at all so the facets on the far wall do
    # not go to one flat black.
    "pyrelisk_heart": {"bg": (0.030, 0.016, 0.018, 1.0), "sun": 0.22, "fill": 0.10},
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
        # Blender's default far clip silently eats an arena shot from further
        # out than 1000 units (Pyrelisk's summit is 800 studs across and framed
        # from 1.6k), and an over-clipped render is an EMPTY frame, which reads
        # as a build failure rather than a camera one. Opt-in per arena: raising
        # it also perturbs EEVEE's depth precision a hair (measured: 0.18% of
        # pixels, max delta 6/255 on Brinejaw), so an arena that fits inside the
        # default keeps it and its previews stay bit-identical.
        if scene_look.get("clip"):
            cam_data.clip_end = scene_look["clip"]
        cam = bpy.data.objects.new("Cam" + suffix, cam_data)
        cam.location = Vector(location)
        if rotation is not None:
            cam.rotation_euler = tuple(math.radians(value) for value in rotation)
        else:
            cam.rotation_euler = (Vector(look_at) - cam.location).to_track_quat("-Z", "Y").to_euler()
        bpy.context.collection.objects.link(cam)
        scene.camera = cam
        # PREVIEW-ONLY PROPS (PREVIEW_PROPS, arena_gen's kraken pass): 5-stud
        # player stand-ins, a sea plane, a proxy boss at the contract scale,
        # dimension labels. Built HERE, after export(), so nothing in them can
        # reach a glb - and built and destroyed around ONE SHOT, because the
        # plan shot's rules and the ground shot's proxy head are mutually
        # exclusive (an opaque 360-wide mantle hides the ring it is measured
        # against).
        before = set(bpy.context.collection.objects)
        for build_prop in PREVIEW_PROPS.get(name + suffix, ()):
            build_prop()
        shot_props = [obj for obj in bpy.context.collection.objects if obj not in before]
        out = path if not suffix else path.replace("_preview.png", "_preview%s.png" % suffix)
        scene.render.filepath = out
        bpy.ops.render.render(write_still=True)
        print("ARENA PREVIEW:", out)
        for obj in shot_props:
            bpy.data.objects.remove(obj, do_unlink=True)


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
