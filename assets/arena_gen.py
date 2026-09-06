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
        "HANDOFF wrack: RETUNE OWED (Bosses.luau admiral_wrack, not this lane) - reach is spawnAt + "
        "speed*lifetime: anchorsweep 106, slewfire 113, chainshot 114, slewfireFast 117, broadside "
        "125, broadsideHeavy 128, grapeshot 163. Five of nine now die short of the rim. `aggro` 110 "
        "and `arena.radius` 40 (party rings in at 48, inside his own 87-stud hull) were sized to the "
        "78-stud shoal."
    )
    return objects


# The CLI's dispatch table. Referenced by main() and, until this commit,
# defined nowhere in the committed file - HEAD~1 fails with the same
# NameError, so the shared copy of this generator has not run from the
# command line since the dict drifted into a lane's uncommitted section.
# It names the arenas THIS file defines; the three later ones re-add
# themselves with the sections that build them.
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
