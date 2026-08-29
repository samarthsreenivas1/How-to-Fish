# boss_gen.py
# Generates the REVAMPED colossus bosses (docs/revamp: the boss redesign -
# huge set-piece creatures whose appendages do the attacking) as low-poly
# meshes, one glb per boss. Run headless:
#
#   blender --background --python assets/boss_gen.py -- assets/boss_brinejaw.glb brinejaw
#   blender --background --python assets/boss_gen.py -- assets/boss_brinejaw.glb brinejaw preview
#   blender --background --python assets/boss_gen.py -- assets/boss_brinejaw.glb brinejaw staged
#
# The second form renders assets/boss_brinejaw_preview.png - the pieces
# ASSEMBLED into a serpent so the chain can be judged, not a parts sheet. The
# third renders assets/boss_brinejaw_staged.png: the serpent in its REST POSE
# on the real arena, coiled around the lighthouse (see BJ_REST).
#
# ---------------------------------------------------------------- the idea
#
# Brinejaw is a SEGMENT CHAIN, not one long mesh (user, 2026-08-29: "the
# serpent should just be made out of smaller cubes and you can just animate
# those really easily"). The client builds ~60 parts - head, jaw, a long run
# of body vertebrae, the rattle - and every frame writes each one's CFrame
# from a single path function poseAt(u, t), u = 0 at the head, 1 at the tail
# tip. That solves the "where does the tail come from" problem: the coils
# around the lighthouse and the sweeping tail are the SAME chain, so a sweep
# is the path's back half blending from helix to ground arc. Nothing ever
# spawns; the tail UNWINDS off the tower and slaps down.
#
# So this file authors SHAPES ONLY - no rig, no keyframes, no long curved
# body. Motion is engine math (the ocean / whirlpool client-animation
# pattern).
#
# ---------------------------------------------------------------- contract
#
#   - 1 Blender unit = 1 Roblox stud. Up is Blender +Z -> Roblox +Y.
#   - Everything is built FACING BLENDER +X, which arrives in Roblox as +X -
#     the creature pack's convention (creatures_gen.py header). For the chain
#     that means: a segment's +X points up-body toward the HEAD, so the
#     client aligns each part's +X with the path tangent.
#   - Each piece is centred on its own attach point at the origin, so the
#     client can place it with one CFrame and no offsets:
#       Head/Jaw   centred on the skull's neck joint (the jaw's hinge pivot
#                  is printed in the HANDOFF - the client rotates the jaw
#                  about it to roar and bite).
#       Seg/SegFin centred on the vertebra, authored at MID-BODY size; the
#                  client scales by u to taper the body.
#       Rattle     wide end at +X (up-body), barb trailing at -X.
#   - Flat shading everywhere, matching the island and the other packs.
#   - One material per object (the pipeline's rule), so a piece that needs a
#     second colour is a second object: the bone, eye, and frill pieces ride
#     with the head.
#
# Colours here are preview-only; the client tints each part as it builds it.
# Deterministic: seeded random only, so re-exports are byte-stable.

import math
import random
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

TAU = math.tau

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
            bsdf.inputs["Roughness"].default_value = 0.85
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


def ellipsoid(bm, center, radii, subdiv=1):
    mat = Matrix.Translation(Vector(center)) @ Matrix.Diagonal(Vector(radii)).to_4x4()
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=1.0, matrix=mat)


def spike(bm, base, tip, r, sides=4):
    base, tip = Vector(base), Vector(tip)
    axis = tip - base
    if axis.length < 1e-6:
        return
    rot = Vector((0, 0, 1)).rotation_difference(axis.normalized()).to_matrix()
    mat = Matrix.Translation((base + tip) / 2) @ rot.to_4x4()
    bmesh.ops.create_cone(
        bm, cap_ends=True, segments=sides, radius1=r, radius2=0.02, depth=axis.length, matrix=mat
    )


def disc(bm, x0, x1, r0, r1, sides=9):
    # A short drum lying along +X (the body axis).
    mat = Matrix.Translation(Vector(((x0 + x1) / 2, 0, 0))) @ Matrix.Rotation(math.radians(90), 4, "Y")
    bmesh.ops.create_cone(bm, cap_ends=True, segments=sides, radius1=r0, radius2=r1, depth=x1 - x0, matrix=mat)


def ring_pts(x, cz, half_w, half_h, sides=8, floor_z=None, ceil_z=None):
    """One cross-section of a body loft, perpendicular to +X (the body axis).

    `floor_z` / `ceil_z` clamp the section flat - a flat underside where the
    jaw meets the skull, a flat top where the jaw meets it back.
    """
    pts = []
    for i in range(sides):
        angle = (i / sides) * TAU
        y = math.cos(angle) * half_w
        z = cz + math.sin(angle) * half_h
        if floor_z is not None:
            z = max(z, floor_z)
        if ceil_z is not None:
            z = min(z, ceil_z)
        pts.append((x, y, z))
    return pts


def blade(bm, base, tip, base_w, tip_w, thick, roll=0.0):
    """A tapered flat blade from `base` to `tip` - fins, frills, paddles.

    Built along +X in a scratch mesh and rotated into place, so the taper
    reads from any angle instead of the boxy plate a rotated cube gives.
    """
    base, tip = Vector(base), Vector(tip)
    axis = tip - base
    length = axis.length
    if length < 1e-6:
        return
    scratch = bmesh.new()
    loft(
        scratch,
        [
            [(0, -base_w / 2, -thick / 2), (0, base_w / 2, -thick / 2), (0, base_w / 2, thick / 2), (0, -base_w / 2, thick / 2)],
            [(length, -tip_w / 2, -thick / 2), (length, tip_w / 2, -thick / 2), (length, tip_w / 2, thick / 2), (length, -tip_w / 2, thick / 2)],
        ],
    )
    align = Vector((1, 0, 0)).rotation_difference(axis.normalized()).to_matrix().to_4x4()
    bmesh.ops.transform(scratch, matrix=align @ Matrix.Rotation(roll, 4, "X"), verts=scratch.verts)
    bmesh.ops.translate(scratch, vec=base, verts=scratch.verts)
    mesh = bpy.data.meshes.new("_blade")
    scratch.to_mesh(mesh)
    scratch.free()
    bm.from_mesh(mesh)
    bpy.data.meshes.remove(mesh)


def loft(bm, rings, cap_start=True, cap_end=True):
    """Bridge a list of equal-length cross-sections into a tube along +X.

    Winding is chosen so the faces point OUTWARD - Roblox meshes are
    single-sided, so a reversed loft would render inside-out.
    """
    verts = [[bm.verts.new(point) for point in ring] for ring in rings]
    for a, b in zip(verts, verts[1:]):
        count = len(a)
        for i in range(count):
            j = (i + 1) % count
            bm.faces.new((a[i], a[j], b[j], b[i]))
    if cap_start:
        bm.faces.new(list(reversed(verts[0])))
    if cap_end:
        bm.faces.new(verts[-1])


# ================================================================ brinejaw
#
# "Brinejaw, the Drowned Leviathan" - the cove's boss, a barnacled sea
# serpent that strangles the Tidebreak Spire. Deep tide-slate hide, pale
# shell rattle, amber lamp eyes; torn frills and crusted barnacles tie it to
# the wrecks it made.

BODY = (0.13, 0.26, 0.30)
FIN = (0.17, 0.40, 0.42)
BONE = (0.87, 0.85, 0.75)
EYE = (1.00, 0.70, 0.18)
SHELL = (0.76, 0.72, 0.60)

# Skull cross-sections: (x, centre z, half width, half height). Snout at +X,
# neck joint at the origin end. The underside is clamped flat at JAW_LINE so
# the lower jaw closes against a real roof-of-mouth.
BJ_JAW_LINE = -0.6
BJ_SKULL = [
    (-6.5, 0.4, 2.3, 2.1),
    (-4.6, 0.5, 3.5, 3.2),
    (-2.2, 0.5, 3.9, 3.4),  # brow, widest
    (0.6, 0.2, 3.3, 2.8),
    (3.6, -0.1, 2.5, 2.1),  # muzzle
    (6.2, -0.2, 1.7, 1.5),
    (8.4, -0.3, 0.9, 0.8),  # snout tip
]

BJ_JAW_TOP = -0.85
BJ_JAW = [
    (-6.0, -1.6, 2.0, 1.5),
    (-3.8, -1.8, 2.9, 1.7),
    (-0.8, -1.9, 2.6, 1.6),
    (2.4, -1.9, 2.1, 1.3),
    (5.2, -1.8, 1.5, 1.0),
    (7.8, -1.6, 0.7, 0.6),
]

# Where the client hinges the jaw open (roar, bite, the death gape).
BJ_JAW_HINGE = (-5.6, 0.0, -1.4)

# Mid-body vertebra: the client scales this by u to taper the chain.
BJ_SEG = [
    (-2.3, 0.0, 1.9, 1.9),
    (-1.1, 0.0, 2.5, 2.5),
    (1.1, 0.0, 2.5, 2.5),
    (2.3, 0.0, 1.9, 1.9),
]
BJ_SEG_SPACING = 4.0  # studs between segment centres along the path


def build_bj_head(rng):
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=9, floor_z=BJ_JAW_LINE) for x, cz, hw, hh in BJ_SKULL])
    # Brow ridges over the eyes, swept back into the skull.
    for side in (-1, 1):
        box(
            bm,
            (-1.6, side * 2.9, 1.9),
            (5.0, 1.2, 0.9),
            Matrix.Rotation(math.radians(side * -7), 3, "X") @ Matrix.Rotation(math.radians(5), 3, "Y"),
        )
    # Barnacle crust along one cheek and the crown - it has been down there.
    for _ in range(9):
        x = rng.uniform(-4.5, 3.5)
        side = rng.choice((-1, 1))
        ellipsoid(
            bm,
            (x, side * rng.uniform(1.8, 3.2), rng.uniform(0.4, 2.6)),
            (rng.uniform(0.3, 0.6),) * 3,
            subdiv=0,
        )
    return finish("Brinejaw_Head", bm, BODY)


def build_bj_head_bone(rng):
    bm = bmesh.new()
    # Swept-back horns off the back of the skull.
    for side in (-1, 1):
        spike(bm, (-3.4, side * 2.6, 2.6), (-9.5, side * 4.2, 5.4), 0.85, sides=5)
        spike(bm, (-4.2, side * 3.0, 1.0), (-8.6, side * 5.2, 2.2), 0.55, sides=5)
    # Upper teeth, hanging from the jaw line down the muzzle.
    for i in range(7):
        t = i / 6
        x = 7.4 - t * 11.0
        hw = 0.9 + t * 2.9
        length = 0.7 + t * 0.9
        for side in (-1, 1):
            spike(bm, (x, side * hw, BJ_JAW_LINE + 0.1), (x, side * hw * 0.92, BJ_JAW_LINE - length), 0.28, sides=4)
    # A pair of nose barbs.
    for side in (-1, 1):
        spike(bm, (6.8, side * 1.1, 0.2), (8.4, side * 1.6, 1.6), 0.3, sides=4)
    return finish("Brinejaw_HeadBone", bm, BONE)


def build_bj_eyes():
    bm = bmesh.new()
    for side in (-1, 1):
        ellipsoid(bm, (-1.4, side * 3.2, 1.5), (0.85, 0.85, 0.85), subdiv=1)
    return finish("Brinejaw_Eyes", bm, EYE)


def build_bj_frill(rng):
    bm = bmesh.new()
    # Torn gill fans behind the jaw - the silhouette that says "sea serpent".
    # Raked back and tapered so they read as membrane, not plating.
    for side in (-1, 1):
        for i in range(5):
            lift = math.radians(-38 + i * 26)
            length = rng.uniform(5.0, 7.6) * (1.0 - abs(i - 2) * 0.11)
            base = Vector((-4.6, side * 2.5, 0.6 + i * 0.55))
            direction = Vector((-0.62, side * math.cos(lift) * 0.75, math.sin(lift) * 0.9)).normalized()
            blade(bm, base, base + direction * length, 2.4 + i * 0.25, 0.5, 0.14)
    return finish("Brinejaw_Frill", bm, FIN)


def build_bj_jaw(rng):
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=8, ceil_z=BJ_JAW_TOP) for x, cz, hw, hh in BJ_JAW])
    # Chin barbels, because every deep thing has them.
    for side in (-1, 1):
        spike(bm, (2.0, side * 1.4, -2.9), (4.6, side * 2.2, -5.4), 0.3, sides=4)
    _ = rng
    return finish("Brinejaw_Jaw", bm, BODY)


def build_bj_jaw_bone():
    bm = bmesh.new()
    # Lower teeth, standing up to meet the upper set.
    for i in range(6):
        t = i / 5
        x = 6.8 - t * 10.4
        hw = 0.7 + t * 2.1
        length = 0.6 + t * 0.8
        for side in (-1, 1):
            spike(bm, (x, side * hw, BJ_JAW_TOP - 0.1), (x, side * hw * 0.94, BJ_JAW_TOP + length), 0.24, sides=4)
    return finish("Brinejaw_JawBone", bm, BONE)


def build_bj_seg():
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=8) for x, cz, hw, hh in BJ_SEG])
    # Dorsal keel: a low ridge running the segment's length, so a long run of
    # them reads as one spine instead of a string of beads.
    box(bm, (0, 0, 2.55), (4.2, 0.7, 0.9), Matrix.Rotation(math.radians(45), 3, "X"))
    # Belly scute: a flat plate under the vertebra.
    box(bm, (0, 0, -2.35), (3.6, 2.6, 0.35))
    return finish("Brinejaw_Seg", bm, BODY)


def build_bj_seg_fin():
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=8) for x, cz, hw, hh in BJ_SEG])
    box(bm, (0, 0, 2.55), (4.2, 0.7, 0.9), Matrix.Rotation(math.radians(45), 3, "X"))
    box(bm, (0, 0, -2.35), (3.6, 2.6, 0.35))
    # Dorsal fin: a raked, tapering membrane standing off the keel.
    blade(bm, (0.4, 0, 2.2), (-1.6, 0, 5.9), 3.6, 0.6, 0.24, roll=math.radians(90))
    # Side paddles, swept back and down along the body.
    for side in (-1, 1):
        blade(bm, (0.6, side * 2.0, -1.2), (-2.2, side * 4.6, -2.4), 2.6, 0.7, 0.22)
    return finish("Brinejaw_SegFin", bm, BODY)


def build_bj_rattle():
    bm = bmesh.new()
    # The weak point, and it has to read as one from across the arena: four
    # stacked shell segments, each swelling to a hard flared lip at its
    # trailing edge, so the tail tip looks knuckled and hittable rather than
    # like more body.
    plates = [(2.2, 0.1, 2.6, 2.2), (0.1, -2.1, 2.4, 1.9), (-2.1, -4.2, 2.0, 1.5), (-4.2, -6.1, 1.6, 1.1)]
    for x1, x0, r1, r0 in plates:
        disc(bm, x0, x1, r0, r1, sides=9)
        disc(bm, x0 - 0.45, x0, r0 * 1.5, r0 * 1.05, sides=9)  # the flare lip
    # Barbed tip.
    spike(bm, (-6.2, 0, 0), (-9.8, 0, 1.1), 1.0, sides=5)
    return finish("Brinejaw_Rattle", bm, SHELL)


def build_brinejaw():
    rng = random.Random(9137)
    objects = [
        build_bj_head(rng),
        build_bj_head_bone(rng),
        build_bj_eyes(),
        build_bj_frill(rng),
        build_bj_jaw(rng),
        build_bj_jaw_bone(),
        build_bj_seg(),
        build_bj_seg_fin(),
        build_bj_rattle(),
    ]
    print("HANDOFF brinejaw: head faces +X; neck joint at the origin, snout tip x=+8.4")
    print("HANDOFF brinejaw: jaw hinge pivot (%.1f, %.1f, %.1f) - client rotates the jaw about it" % BJ_JAW_HINGE)
    print("HANDOFF brinejaw: segment spacing %.1f studs at scale 1 (mid-body); taper by u toward the tail" % BJ_SEG_SPACING)
    print("HANDOFF brinejaw: body half-width 2.5 at scale 1 -> sweep hit girth ~3 studs")
    print("HANDOFF brinejaw: rattle runs x +2.2 (join) to -9.8 (barb tip); the weak point hitbox")
    return objects


# ================================================================ the kraken
#
# THE MAW OF THE MAELSTROM. A squid the size of a harbour: a pointed mantle
# behind, a bulbous head with two lamp-eyes, and under the brow a hooked bone
# beak - the only clean thing on it. The eight fighting arms are NOT modelled
# here as body parts: they are the six `kraken_tentacle` entities the boss
# engine already plants on a ring (spawnBossParts), so an arm is ONE authored
# segment instanced down a ChainPose curve, exactly like Brinejaw's body.
#
# Scale contract: the row spawns it at 2.6 and declares hitRadius 8 (so ~21
# studs of hide in game). Everything below is authored at scale 1 against
# that 8: the mantle's widest half-width is 7.2 and the beak tip sits at
# x=+10.4, which is what makes the melee reach and the visible body agree.
#
# It has been down there a long time: the mantle carries the same barnacle
# crust the wreck island wears, a snapped spar grown into its back and a
# length of anchor chain it never shook off - it is the thing that sank the
# fleet rotting on the spiral outside.

KR_HIDE = (0.24, 0.17, 0.33)   # deep ink-violet (the creature row's body colour)
KR_CRUST = (0.36, 0.29, 0.22)  # barnacle plate + drowned timber
KR_BEAK = (0.78, 0.71, 0.54)   # bone, matte, deliberately unlit
KR_EYE = (0.59, 0.47, 1.00)    # storm-lit: the fight's only violet light

# Mantle cross-sections: (x, centre z, half-width, half-height). +X is the
# front (the brow, over the beak); the mantle tapers to a point behind.
KR_MANTLE = [
    (-15.0, 0.0, 0.35, 0.30),
    (-12.2, 0.2, 2.4, 2.0),
    (-8.5, 0.3, 4.8, 4.1),
    (-4.5, 0.4, 6.6, 5.6),
    (-1.0, 0.3, 7.2, 6.0),   # the shoulder - the widest of it
    (2.5, 0.0, 6.4, 5.4),
    (5.5, -0.4, 4.6, 4.2),
    (7.6, -1.0, 2.6, 2.6),   # the brow front, over the beak
]

KR_BEAK_HINGE = (4.6, 0.0, -2.9)  # both mandibles rotate about this
KR_ARM_SPACING = 3.4              # authored segment pitch, scale 1
KR_ARM_SEGMENTS = 9               # + the tip: ~32 studs of arm at scale 1


def build_kr_mantle(rng):
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=10) for x, cz, hw, hh in KR_MANTLE])
    # Dorsal ridges: three low keels down the mantle so a huge smooth sack
    # reads as muscle instead of a balloon.
    for i in range(3):
        x = -10.5 + i * 4.2
        box(bm, (x, 0, 5.1 - i * 0.35), (3.0, 1.1, 1.0), Matrix.Rotation(math.radians(45), 3, "X"))
    # Mantle collar: the thickened rim where the head meets the body.
    disc(bm, 1.6, 2.6, 6.6, 6.5, sides=10)
    return finish("Kraken_Mantle", bm, KR_HIDE)


def build_kr_crust(rng):
    bm = bmesh.new()
    # Barnacle plate over the crown and one shoulder.
    for _ in range(26):
        x = rng.uniform(-11.0, 5.0)
        angle = rng.uniform(-0.9, 0.9)
        r = rng.uniform(4.2, 6.9)
        ellipsoid(
            bm,
            (x, math.sin(angle) * r, 0.6 + math.cos(angle) * r * 0.86),
            (rng.uniform(0.35, 0.85),) * 3,
            subdiv=0,
        )
    # A snapped spar driven into its back and never worked loose.
    box(bm, (-6.4, 1.2, 5.6), (9.0, 0.9, 0.9), Matrix.Rotation(math.radians(-18), 3, "Y") @ Matrix.Rotation(math.radians(12), 3, "Z"))
    box(bm, (-1.6, 1.9, 6.1), (3.4, 0.7, 0.7), Matrix.Rotation(math.radians(28), 3, "Y"))
    # Anchor chain grown into the hide, links alternating flat and edge-on.
    for i in range(6):
        x = -9.0 + i * 1.9
        z = 4.9 + math.sin(i * 0.7) * 0.5
        flat = i % 2 == 0
        box(bm, (x, -3.4, z), (1.5, 1.1, 0.45) if flat else (1.5, 0.45, 1.1))
    return finish("Kraken_Crust", bm, KR_CRUST)


def build_kr_brow(rng):
    bm = bmesh.new()
    # The armour shelf the eyes sit under - it DROPS before a bite, which is
    # the tell that reads from the platforms.
    for side in (-1, 1):
        blade(bm, (6.4, side * 1.6, 1.4), (1.2, side * 6.4, 2.2), 3.2, 4.4, 0.9)
        # A horn off each corner of the shelf.
        spike(bm, (2.2, side * 5.8, 2.0), (-1.4, side * 7.6, 4.6), 0.75, sides=5)
    box(bm, (4.4, 0, 2.0), (4.0, 3.2, 0.9))
    return finish("Kraken_Brow", bm, KR_HIDE)


def build_kr_beak_upper():
    bm = bmesh.new()
    # A hooked wedge: wide at the hinge, narrowing to a down-turned point.
    loft(bm, [
        ring_pts(4.4, -2.6, 2.5, 1.5, sides=7),
        ring_pts(6.6, -3.0, 2.2, 1.4, sides=7),
        ring_pts(8.6, -3.8, 1.5, 1.0, sides=7),
        ring_pts(9.8, -4.8, 0.7, 0.5, sides=7),
    ], cap_end=False)
    spike(bm, (9.8, 0, -4.8), (10.4, 0, -6.4), 0.55, sides=5)
    return finish("Kraken_BeakUpper", bm, KR_BEAK)


def build_kr_beak_lower():
    bm = bmesh.new()
    # The lower mandible hooks the other way - the two cross like shears.
    loft(bm, [
        ring_pts(4.4, -4.4, 2.2, 1.2, sides=7),
        ring_pts(6.6, -4.8, 1.9, 1.1, sides=7),
        ring_pts(8.4, -4.9, 1.3, 0.8, sides=7),
        ring_pts(9.4, -4.2, 0.6, 0.45, sides=7),
    ], cap_end=False)
    spike(bm, (9.4, 0, -4.2), (10.0, 0, -2.9), 0.5, sides=5)
    return finish("Kraken_BeakLower", bm, KR_BEAK)


def build_kr_eyes():
    bm = bmesh.new()
    # Enormous, and the only warm light in the arena.
    for side in (-1, 1):
        ellipsoid(bm, (3.2, side * 5.4, 0.9), (1.9, 1.5, 1.9), subdiv=1)
    return finish("Kraken_Eyes", bm, KR_EYE)


def build_kr_fin():
    bm = bmesh.new()
    # The mantle fins: broad triangular flaps down the back half, the things
    # that sweep when it turns.
    for side in (-1, 1):
        blade(bm, (-6.0, side * 4.4, 1.2), (-14.2, side * 9.6, 2.6), 7.6, 1.2, 0.5)
        blade(bm, (-9.0, side * 3.6, 0.2), (-13.6, side * 7.2, -2.2), 3.4, 0.8, 0.4)
    return finish("Kraken_Fin", bm, KR_HIDE)


def build_kr_arm_seg():
    bm = bmesh.new()
    # ONE arm segment, centred on its vertebra, +X pointing UP-ARM toward the
    # body (the pack convention). The client instances this down a ChainPose
    # curve at KR_ARM_SPACING and scales by u to taper toward the tip.
    half = KR_ARM_SPACING / 2
    loft(bm, [
        ring_pts(-half, 0.0, 1.62, 1.48, sides=7),
        ring_pts(0.0, 0.05, 1.80, 1.66, sides=7),
        ring_pts(half, 0.0, 1.70, 1.56, sides=7),
    ])
    # The aboral keel - an arm reads as an arm, not a sausage, from its edge.
    box(bm, (0, 0, 1.62), (KR_ARM_SPACING * 0.9, 0.7, 0.8), Matrix.Rotation(math.radians(45), 3, "X"))
    return finish("Kraken_ArmSeg", bm, KR_HIDE)


def build_kr_arm_tip():
    bm = bmesh.new()
    # The club: squid arms widen into a hooked paddle before the point. Joins
    # at +X, tapers away along -X.
    loft(bm, [
        ring_pts(1.7, 0.0, 1.60, 1.46, sides=7),
        ring_pts(-0.4, 0.1, 2.05, 1.80, sides=7),
        ring_pts(-2.6, 0.0, 1.30, 1.15, sides=7),
        ring_pts(-4.2, -0.1, 0.40, 0.40, sides=7),
    ])
    # Hooks around the club - what the slam actually lands with.
    for i in range(5):
        angle = (i / 5) * TAU
        spike(
            bm,
            (-0.4, math.cos(angle) * 1.7, 0.1 + math.sin(angle) * 1.6),
            (-1.5, math.cos(angle) * 2.9, 0.1 + math.sin(angle) * 2.7),
            0.3,
            sides=4,
        )
    return finish("Kraken_ArmTip", bm, KR_HIDE)


def build_kr_sucker():
    bm = bmesh.new()
    # One sucker, centred at the origin. Instanced in rows along every arm and
    # lit base-to-tip through a wind-up: the telegraph is anatomy, not a ring
    # painted on the floor.
    disc(bm, -0.18, 0.18, 0.55, 0.38, sides=7)
    return finish("Kraken_Sucker", bm, KR_EYE)


def build_kraken():
    rng = random.Random(4471)
    objects = [
        build_kr_mantle(rng),
        build_kr_crust(rng),
        build_kr_brow(rng),
        build_kr_beak_upper(),
        build_kr_beak_lower(),
        build_kr_eyes(),
        build_kr_fin(),
        build_kr_arm_seg(),
        build_kr_arm_tip(),
        build_kr_sucker(),
    ]
    print("HANDOFF kraken: body faces +X; mantle centre at the origin, brow front x=+7.6, beak tip x=+10.4")
    print("HANDOFF kraken: hide half-width 7.2 at the shoulder -> matches the row's hitRadius 8 at scale 1")
    print("HANDOFF kraken: beak hinge pivot (%.1f, %.1f, %.1f) - the server rotates BOTH mandibles about it" % KR_BEAK_HINGE)
    print("HANDOFF kraken: eyes at (3.2, +/-5.4, 0.9) r1.9 - Neon swap for the wind-up flare, no light source")
    print("HANDOFF kraken: arm segment pitch %.1f, %d segments + tip = ~%.0f studs of arm at scale 1"
          % (KR_ARM_SPACING, KR_ARM_SEGMENTS, KR_ARM_SPACING * KR_ARM_SEGMENTS + 4.2))
    print("HANDOFF kraken: arm half-width 1.80 at the base -> slam hit girth ~3.6 studs; taper by u toward the tip")
    print("HANDOFF kraken: suckers 2 per segment, alternating rows, indexed base->tip for the wind-up sweep")
    return objects


BOSSES = {
    "brinejaw": build_brinejaw,
    "kraken": build_kraken,
}


# ---------------------------------------------------------------- preview
#
# Assembles the pieces into a serpent along a sine path - the same job the
# client's poseAt does - so the chain can be judged as a creature.


# ---------------------------------------------------------------- rest pose
#
# WHERE BRINEJAW SITS WHEN NOTHING IS HAPPENING: three turns strangling the
# Tidebreak Spire, head rearing past the lantern room, tail draped down the
# tower and pooled on the sand. This is the SPEC the client's poseAt(u, 0)
# reproduces - the numbers below are the contract, and the staged render is
# how we check them. Every attack is a blend away from this pose and back:
# a sweep re-parameterises the tail portion onto a ground arc, a lost grip
# drops `top_z`/`bottom_z` by one turn, the punish slumps the neck to the sand.

BJ_REST = {
    "neck_end": 0.11,  # u where the neck meets the top coil
    "helix_end": 0.74,  # u where the bottom coil lets go of the tower
    "turns": 3.0,  # one per phase: each lost grip drops the stack a turn
    "top_z": 44.0,
    "bottom_z": 12.0,
    "clearance": 3.4,  # body centre stands this far off the masonry
    "head_z": 60.0,  # neck's top, where the head takes over
    "head_out": 8.0,  # how far past the gallery the neck leans over the arena
    "bearing": math.radians(342.0),  # where the head leans out - toward the party's arrival ring
    "tail_out": 31.0,  # how far onto the sand the slack tail reaches
    "tail_z": 3.4,
    "tail_turn": 0.85,
}


def _spire_radius(z):
    """The lighthouse's radius at height z (arena_gen's three drums)."""
    for z0, z1, r0, r1 in ((3.5, 20.0, 8.5, 7.4), (20.0, 38.0, 7.2, 6.2), (38.0, 54.0, 6.0, 5.2)):
        if z <= z1:
            t = max(0.0, min(1.0, (z - z0) / (z1 - z0)))
            return r0 + (r1 - r0) * t
    return 5.2


def _bj_rest_path(t):
    """Head (t=0) to rattle (t=1) in arena-local space, waterline at z=0."""
    rest = BJ_REST
    neck_end, helix_end = rest["neck_end"], rest["helix_end"]

    def helix(k):
        z = rest["top_z"] + (rest["bottom_z"] - rest["top_z"]) * k
        theta = rest["bearing"] + rest["turns"] * TAU * k
        r = _spire_radius(z) + rest["clearance"]
        return Vector((math.cos(theta) * r, math.sin(theta) * r, z))

    if t <= neck_end:
        # A quadratic sweep from the reared neck down onto the top coil.
        u = t / neck_end
        theta = rest["bearing"] - 0.8
        r = _spire_radius(rest["head_z"]) + rest["clearance"] + rest["head_out"]
        top = Vector((math.cos(theta) * r, math.sin(theta) * r, rest["head_z"]))
        start = helix(0.0)
        # The control point sets the head's carry angle: top - control is the
        # direction the skull points, so a mostly-outward vector with a little
        # lift gives the cobra look - reared over the gallery, watching the
        # sand - instead of a snout aimed at the sky.
        control = top - Vector((math.cos(theta) * 11.0, math.sin(theta) * 11.0, 2.5))
        return top * (1 - u) ** 2 + control * (2 * (1 - u) * u) + start * u**2

    if t <= helix_end:
        return helix((t - neck_end) / (helix_end - neck_end))

    # Slack: the tail leaves the tower, spirals down and lies on the sand.
    k = (t - helix_end) / (1.0 - helix_end)
    inner = _spire_radius(rest["bottom_z"]) + rest["clearance"]
    theta = rest["bearing"] + rest["turns"] * TAU + rest["tail_turn"] * TAU * k
    r = inner + (rest["tail_out"] - inner) * k**0.75
    z = rest["bottom_z"] + (rest["tail_z"] - rest["bottom_z"]) * k**0.6
    return Vector((math.cos(theta) * r, math.sin(theta) * r, z))


# ---------------------------------------------------------------- assembly


def _arc_walker(path_fn, samples=800, look=1.2):
    """Re-parameterise `path_fn` (t in 0..1) by ARC LENGTH.

    Shared by every boss's preview placer - and the same job ChainPose does
    at runtime, so what a render shows is what the fight will pose.
    Returns (at_length, tangent_at, total)."""
    pts = [path_fn(i / samples) for i in range(samples + 1)]
    cumulative = [0.0]
    for a, b in zip(pts, pts[1:]):
        cumulative.append(cumulative[-1] + (b - a).length)
    total = cumulative[-1]

    def at_length(distance):
        distance = min(max(distance, 0.0), total)
        for i in range(len(cumulative) - 1):
            if cumulative[i + 1] >= distance:
                span = cumulative[i + 1] - cumulative[i]
                t = 0 if span < 1e-9 else (distance - cumulative[i]) / span
                return pts[i].lerp(pts[i + 1], t)
        return pts[-1]

    def tangent_at(distance):
        return (at_length(distance - look) - at_length(distance + look)).normalized()

    return at_length, tangent_at, total


def _place_chain(objects, path_fn, spacing=BJ_SEG_SPACING, taper=0.62, head_scale=1.2, tail_scale=0.62):
    """Lay the pieces along `path_fn` (t in 0..1) by ARC LENGTH - the job the
    client's poseAt does every frame. Returns the placed copies."""
    by_name = {obj.name.split("_", 1)[1]: obj for obj in objects}
    made = []

    def place(source, position, tangent, scale):
        copy = source.copy()
        copy.data = source.data
        copy.hide_render = False  # sources are hidden; their copies are the shot
        bpy.context.collection.objects.link(copy)
        copy.location = position
        copy.rotation_euler = Vector((1, 0, 0)).rotation_difference(tangent).to_euler()
        copy.scale = (scale, scale, scale)
        made.append(copy)
        return copy

    # Walk the curve by ARC LENGTH, the way the client's poseAt does: even
    # spacing along the actual path, so the vertebrae overlap into one body
    # instead of drifting apart wherever the curve bends.
    at_length, tangent_at, total = _arc_walker(path_fn)

    step = spacing * 0.85  # slight overlap so the chain reads continuous
    count = max(int(total / step), 2)
    for i in range(count):
        distance = i * step
        scale = 1.0 - taper * (distance / total) ** 1.3
        source = by_name["SegFin"] if i % 4 == 2 else by_name["Seg"]
        place(source, at_length(distance), tangent_at(distance), scale)

    head_pos = at_length(0) + tangent_at(0) * 7.4
    for name in ("Head", "HeadBone", "Eyes", "Frill", "Jaw", "JawBone"):
        place(by_name[name], head_pos, tangent_at(0), head_scale)

    tail_distance = (count - 1) * step
    place(by_name["Rattle"], at_length(tail_distance) - tangent_at(tail_distance) * 2.2, tangent_at(tail_distance), tail_scale)
    print("CHAIN: %.0f studs of serpent, %d vertebrae at %.1f-stud steps" % (total, count, step))
    return made


def _swim_path(t):
    """A lazy S with the head lifting - the parts-sheet-replacement preview."""
    return Vector((-t * 88.0, math.sin(t * 2.3 * math.pi) * 11.0, 6.5 * (1 - t) ** 2))


def _kraken_arm_path(angle, t):
    """One arm at its REST POSE: out of the water beside the mantle, arcing
    up over the fight stacks, tip curling back down into the sea. t=0 at the
    base. This is the shape ChainPose blends away from for a lash and back
    to afterwards - the rest pose is the spec."""
    r = 9.0 + 27.0 * t
    # Low and long: up out of the water, over the stacks, tip back down into
    # the sea - a draped arm, not an arched leg.
    z = math.sin(t * math.pi * 0.92) * 6.4 - 2.5
    a = angle + math.sin(t * 2.3 + angle * 1.7) * 0.16
    return Vector((math.cos(a) * r, math.sin(a) * r, z))


def _place_kraken(objects, arms=6):
    """The body at the origin with its arms laid out in the rest pose, so the
    silhouette can be judged as one animal rather than a parts sheet."""
    by_name = {obj.name.split("_", 1)[1]: obj for obj in objects}
    made = []

    def place(source, position, tangent=None, scale=1.0):
        copy = source.copy()
        copy.data = source.data
        copy.hide_render = False
        bpy.context.collection.objects.link(copy)
        copy.location = position
        if tangent is not None:
            copy.rotation_euler = Vector((1, 0, 0)).rotation_difference(tangent).to_euler()
        copy.scale = (scale, scale, scale)
        made.append(copy)
        return copy

    # The body sits where it was authored - one CFrame, no offsets.
    for part in ("Mantle", "Crust", "Brow", "BeakUpper", "BeakLower", "Eyes", "Fin"):
        place(by_name[part], Vector((0, 0, 0)))

    seg, tip, sucker = by_name["ArmSeg"], by_name["ArmTip"], by_name["Sucker"]
    for k in range(arms):
        angle = (k / arms) * TAU + 0.22
        at_length, tangent_at, total = _arc_walker(lambda t, a=angle: _kraken_arm_path(a, t))
        step = KR_ARM_SPACING * 0.88  # slight overlap so the arm reads continuous
        count = max(int(total / step), 3)
        for i in range(count):
            distance = i * step
            u = distance / total
            scale = 1.0 - 0.45 * u ** 1.2  # taper toward the tip
            position = at_length(distance)
            tangent = tangent_at(distance)
            place(seg, position, tangent, scale)
            # Two sucker rows along the UNDERSIDE. Build the frame from the
            # tangent with a guarded up-vector: an arm mid-whip really does
            # point straight up, where a naive cross degenerates.
            up = Vector((0, 0, 1))
            if abs(tangent.dot(up)) > 0.98:
                up = Vector((0, 1, 0))
            lateral = tangent.cross(up).normalized()
            down = lateral.cross(tangent).normalized()
            if down.z > 0:
                down = -down
            for side in (-1, 1):
                seat = position + down * (1.05 * scale) + lateral * (side * 0.72 * scale)
                place(sucker, seat, tangent, scale)
        place(tip, at_length(total), tangent_at(total), 1.0 - 0.45)
    return made


PLACERS = {
    "kraken": _place_kraken,
}


def render_preview(path_out, objects, boss="brinejaw"):
    for obj in objects:
        obj.hide_render = True
    placer = PLACERS.get(boss)
    placed = placer(objects) if placer else _place_chain(objects, _swim_path)

    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.rotation_euler = (math.radians(52), 0, math.radians(28))
    sun.data.energy = 2.6
    bpy.context.collection.objects.link(sun)
    fill = bpy.data.objects.new("Fill", bpy.data.lights.new("Fill", "SUN"))
    fill.rotation_euler = (math.radians(64), 0, math.radians(-135))
    fill.data.energy = 1.0
    bpy.context.collection.objects.link(fill)

    # Frame whatever the chain turned out to span, from a 3/4 angle. The
    # depsgraph has to catch up first or every copy still reads as identity.
    bpy.context.view_layer.update()
    lo = Vector((math.inf, math.inf, math.inf))
    hi = Vector((-math.inf, -math.inf, -math.inf))
    for obj in placed:
        for corner in obj.bound_box:
            world = obj.matrix_world @ Vector(corner)
            lo = Vector((min(lo[i], world[i]) for i in range(3)))
            hi = Vector((max(hi[i], world[i]) for i in range(3)))
    center = (lo + hi) / 2
    span = max((hi - lo).length, 1.0)

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.lens = 45
    cam = bpy.data.objects.new("Cam", cam_data)
    offset = Vector((0.30, -1.0, 0.42)).normalized() * span * 1.28
    cam.location = center + offset
    cam.rotation_euler = (center - cam.location).to_track_quat("-Z", "Y").to_euler()
    bpy.context.collection.objects.link(cam)
    bpy.context.scene.camera = cam

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1600
    scene.render.resolution_y = 900
    scene.render.filepath = path_out
    scene.world = bpy.data.worlds.new("World")
    scene.world.use_nodes = True
    bg = scene.world.node_tree.nodes.get("Background")
    if bg:
        bg.inputs[0].default_value = (0.42, 0.54, 0.62, 1.0)
    bpy.ops.render.render(write_still=True)
    print("BOSS PREVIEW:", path_out)


def render_staged(path_out, objects):
    """The money shot: the arena built, the serpent coiled on its lighthouse.

    Imports arena_gen so the tower under the coils is the REAL one - if the
    arena's profile ever changes, this render shows the coils floating or
    biting into masonry instead of hugging it.
    """
    import os

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import arena_gen  # noqa: E402  (guarded: importing it builds nothing)

    arena_gen.build_brinejaw()
    for obj in objects:
        obj.hide_render = True
    _place_chain(objects, _bj_rest_path, head_scale=1.35, tail_scale=0.55)

    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.rotation_euler = (math.radians(48), 0, math.radians(-40))
    sun.data.energy = 2.4
    bpy.context.collection.objects.link(sun)
    fill = bpy.data.objects.new("Fill", bpy.data.lights.new("Fill", "SUN"))
    fill.rotation_euler = (math.radians(70), 0, math.radians(130))
    fill.data.energy = 0.9
    bpy.context.collection.objects.link(fill)

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.lens = 42
    cam = bpy.data.objects.new("Cam", cam_data)
    cam.location = Vector((96, -144, 46))
    cam.rotation_euler = (Vector((0, 0, 38.0)) - cam.location).to_track_quat("-Z", "Y").to_euler()
    bpy.context.collection.objects.link(cam)
    bpy.context.scene.camera = cam

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1500
    scene.render.resolution_y = 1000
    scene.render.filepath = path_out
    scene.world = bpy.data.worlds.new("World")
    scene.world.use_nodes = True
    bg = scene.world.node_tree.nodes.get("Background")
    if bg:
        bg.inputs[0].default_value = (0.46, 0.62, 0.72, 1.0)
    bpy.ops.render.render(write_still=True)
    print("BOSS STAGED:", path_out)


def export(path_out, objects):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.ops.export_scene.gltf(
        filepath=path_out,
        export_format="GLB",
        use_selection=True,
        export_yup=True,
        export_apply=True,
        export_texcoords=False,
    )
    print("BOSS EXPORTED:", path_out, "-", len(objects), "objects")
    for obj in objects:
        lo = [min(v.co[i] for v in obj.data.vertices) for i in range(3)]
        hi = [max(v.co[i] for v in obj.data.vertices) for i in range(3)]
        print(
            "  %s bbox x %.1f..%.1f  y %.1f..%.1f  z %.1f..%.1f"
            % (obj.name, lo[0], hi[0], lo[1], hi[1], lo[2], hi[2])
        )


def main():
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    if len(argv) < 2 or argv[1] not in BOSSES:
        print("usage: blender --background --python boss_gen.py -- <out.glb> <%s> [preview] [staged]" % "|".join(BOSSES))
        return
    clear_scene()
    objects = BOSSES[argv[1]]()
    export(argv[0], objects)
    if "preview" in argv[2:]:
        render_preview(argv[0].replace(".glb", "_preview.png"), objects, argv[1])
    if "staged" in argv[2:]:
        render_staged(argv[0].replace(".glb", "_staged.png"), objects)


if __name__ == "__main__":
    main()
