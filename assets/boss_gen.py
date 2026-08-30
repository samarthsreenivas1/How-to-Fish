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
# ------------------------------------------------- editing this file safely
#
# Several lanes author bosses in here at once. Three splice failures happened
# on this file in one evening, all variants of the same mistake - POSITIONAL
# EXTRACTION WITHOUT AN IDENTITY CHECK - so before you reach for a slice:
#
#   1. Never anchor on a comment, or on any string another lane's section
#      could contain. `# Where the client hinges the jaw` appears in three
#      sections; a slice anchored on it matched a DIFFERENT boss's copy 1100
#      lines earlier, ran backwards, and silently deleted this file's header,
#      imports and every shared primitive.
#   2. Anchor BOTH ends inside your own section and assert `count == 1` on
#      both - and `assert old` too. `str.replace(old, new, 1)` with an empty
#      `old` matches at position 0 and PREPENDS, with no exception and a
#      successful exit code. An inverted slice produces exactly that.
#   3. Matching your own anchors is necessary but NOT sufficient: the span
#      between them stops being yours the moment someone inserts next to you.
#      Assert on the text you extracted - no peer's `build_*` identifier may
#      appear in it - not merely on the anchors you matched. Two extractors
#      swallowed a neighbouring lane's builders exactly this way.
#
# And one that is invisible until a multi-boss run: `make_material` reuses a
# Blender datablock BY NAME and `finish()` keys it on the object name, so
# per-boss `<Boss>_*` object names are what keep palettes from repainting
# each other.
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


def ellipsoid(bm, center, radii, subdiv=1, rot=None):
    mat = Matrix.Translation(Vector(center))
    if rot is not None:
        mat = mat @ rot.to_4x4()
    mat = mat @ Matrix.Diagonal(Vector(radii)).to_4x4()
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
# THE MAW OF THE MAELSTROM - a colossal deep-purple OCTOPUS whose head fills
# the middle of the whirlpool and whose eight arms do all the fighting (user,
# 2026-08-29: "the middle of the arena should just be his head and then the 8
# appendages attack... a big octopus... tall and big head").
#
# TWO RULES THIS FILE EXISTS TO OBEY:
#  1. AN ARM MUST READ AS ONE LIMB, never a string of blocks. Every segment is
#     a CAPSULE - a barrel with rounded ends - authored LONGER than the pitch
#     it is placed at (KR_SEG_LENGTH 5.4 vs KR_ARM_SPACING 3.0), so consecutive
#     segments always interpenetrate by ~2.4 studs no matter how hard the arm
#     bends. Rounded ends are what keeps a bend filled: flat-capped cylinders
#     open a wedge of daylight on the outside of every curve.
#  2. THE HEAD IS THE ARENA'S CENTREPIECE. Authored ~11.5 half-width and 15
#     tall so that at the row's scale it stands ~30 studs across and ~39 tall -
#     the middle of the whirlpool, with the fight stacks ringed outside it.
#
# The eight arms are NOT body parts: they are the `kraken_tentacle` entities
# the boss engine already plants on a ring, so an arm is ONE authored capsule
# instanced down a ChainPose curve.

KR_HIDE = (0.13, 0.08, 0.20)    # deep dark purple - the body
KR_HIDE2 = (0.20, 0.13, 0.30)   # the lighter underside / arm crown
KR_CRUST = (0.34, 0.32, 0.28)   # barnacle plate and drowned timber - PALE, not gold
KR_BEAK = (0.74, 0.68, 0.52)    # bone
KR_EYE = (0.40, 0.27, 0.72)
KR_PUPIL = (0.05, 0.03, 0.09)  # the slit: near-black, so the lens reads as an eye     # storm-lit: the only violet light in the fight

KR_ARM_SPACING = 2.6   # placement pitch down the curve
KR_SEG_LENGTH = 5.4    # authored segment length - LONGER than the pitch
KR_ARM_SEGMENTS = 13
KR_BEAK_HINGE = (0.0, 0.0, -1.2)


def _capsule(bm, length, r_mid, r_end, sides=12):
    """A barrel with rounded ends, along +X. Overlapping capsules read as one
    continuous limb through any bend - the whole point."""
    half = length / 2
    # Full radius across the middle 80%, rounding off only at the very ends.
    # THE RULE: that parallel section must stay LONGER than the pitch the
    # segments are planted at (KR_ARM_SPACING), or neighbouring barrels only
    # meet on their shoulders, the surface dips at every joint, and the arm
    # ribs up like a caterpillar. It is the same trap as tapering the length.
    loft(bm, [
        ring_pts(-half, 0.0, r_end * 0.34, r_end * 0.34, sides=sides),
        ring_pts(-half * 0.94, 0.0, r_end * 0.86, r_end * 0.86, sides=sides),
        ring_pts(-half * 0.80, 0.0, r_mid, r_mid, sides=sides),
        ring_pts(half * 0.80, 0.0, r_mid, r_mid, sides=sides),
        ring_pts(half * 0.94, 0.0, r_end * 0.86, r_end * 0.86, sides=sides),
        ring_pts(half, 0.0, r_end * 0.34, r_end * 0.34, sides=sides),
    ])


# The mantle's shape, as a profile turned about +Z. TALL, not round: 46 up
# against 19.8 of half-width is a ratio of 2.3, where the first pass was 1.7
# and read as a beach ball. And it is FLUTED - eight lobes running the height,
# one over each arm socket, so the head explains the arms instead of sitting
# on top of them.
KR_HEAD_PROFILE = [
    (0.0, 14.2), (4.5, 17.4), (9.5, 19.2), (14.5, 19.8),
    (20.0, 19.2), (25.5, 17.8), (31.0, 15.6), (36.0, 12.6),
    (40.0, 9.2), (43.0, 5.6), (45.0, 2.2), (46.2, 0.8),
]
KR_HEAD_TOP = 46.2
KR_HEAD_SIDES = 32
KR_HEAD_LOBES = 8
KR_LOBE_DEPTH = 0.085


def _kr_flute(a, z):
    """Lobe modulation at bearing `a`, height `z`. Zero at the crown and at the
    tip, deepest through the middle - a groove that runs out at both ends
    rather than a scallop cut into the silhouette."""
    t = min(max(z / KR_HEAD_TOP, 0.0), 1.0)
    amp = KR_LOBE_DEPTH * math.sin(math.pi * t ** 0.85)
    return 1.0 + amp * math.cos(KR_HEAD_LOBES * a)


def build_kr_head(rng):
    bm = bmesh.new()
    rings = []
    for z, r in KR_HEAD_PROFILE:
        pts = []
        for i in range(KR_HEAD_SIDES):
            a = (i / KR_HEAD_SIDES) * TAU
            rr = r * _kr_flute(a, z)
            pts.append((math.cos(a) * rr, math.sin(a) * rr, z))
        rings.append(pts)
    verts = [[bm.verts.new(pt) for pt in ring] for ring in rings]
    for lower, upper in zip(verts, verts[1:]):
        for i in range(KR_HEAD_SIDES):
            j = (i + 1) % KR_HEAD_SIDES
            bm.faces.new((lower[i], lower[j], upper[j], upper[i]))
    bm.faces.new(list(reversed(verts[0])))
    bm.faces.new(verts[-1])

    # A heavy mantle fold where the head meets the arm crown.
    for i in range(12):
        a = (i / 12) * TAU
        ellipsoid(bm, (math.cos(a) * 15.4, math.sin(a) * 15.4, 2.0), (3.8, 3.8, 2.6), subdiv=1)

    # A heavy brow over each eye, hide-coloured and tilted down at the front,
    # so the lens sits under an overhang instead of on a bald curve.
    for side in (-1, 1):
        rot, out = _kr_eye_frame(side, tilt=0.34)
        ellipsoid(bm, (out[0] * 17.0, out[1] * 17.0, KR_EYE_Z + 5.4), (3.6, 7.4, 2.9), subdiv=1, rot=rot)

    # Two horns off the upper flanks, sweeping up and out. Overlapping beads
    # along an arc, so they weld smooth for the same reason the arms do.
    # SHORT and THICK: drawn long and fine they read as insect antennae, which
    # is a worse look than having no horns at all.
    for side in (-1, 1):
        for i in range(12):
            t = i / 11
            a = side * math.radians(33 + t * 17)
            rad = 13.8 + t * 8.0
            z = 26.0 + t * 11.5
            rr = 5.4 * (1 - 0.62 * t ** 1.35)
            ellipsoid(bm, (math.cos(a) * rad, math.sin(a) * rad, z), (rr, rr, rr * 1.15), subdiv=1)
    return finish("Kraken_Head", bm, KR_HIDE)


def build_kr_crown(rng):
    bm = bmesh.new()
    # The arm crown: the thick web the eight arms grow out of, slung under the
    # head. Lighter than the dome, the way an octopus is pale underneath.
    rings = []
    for z, r in ((-6.4, 7.4), (-4.0, 14.4), (-1.4, 18.6), (1.0, 19.6)):
        pts = []
        for i in range(12):
            a = (i / 12) * TAU
            pts.append((math.cos(a) * r, math.sin(a) * r, z))
        rings.append(pts)
    verts = [[bm.verts.new(pt) for pt in ring] for ring in rings]
    for lower, upper in zip(verts, verts[1:]):
        for i in range(12):
            j = (i + 1) % 12
            bm.faces.new((lower[i], lower[j], upper[j], upper[i]))
    bm.faces.new(list(reversed(verts[0])))
    bm.faces.new(verts[-1])
    # Eight arm sockets: a swollen shoulder where each limb leaves the crown.
    for k in range(8):
        a = (k / 8) * TAU
        ellipsoid(bm, (math.cos(a) * 18.2, math.sin(a) * 18.2, -2.0), (5.8, 5.8, 4.4), subdiv=1)
    return finish("Kraken_Crown", bm, KR_HIDE2)


def build_kr_crust(rng):
    bm = bmesh.new()
    # It has been down there long enough to become terrain. Kept LOW on the
    # dome, around the waterline where a hull actually fouls - scattered over
    # the crown it just read as rubble dropped on its head - and built from
    # flat plates rather than pebbles, so it looks grown on rather than
    # sprinkled.
    for _ in range(20):
        a = rng.uniform(1.5, 3.5)  # clustered on ONE FLANK, off the face, not sprinkled
        z = rng.uniform(1.5, 13.5)
        r = 19.6 * math.sin(math.pi * ((z + 6.0) / 42.0)) ** 0.40
        rot = Matrix.Rotation(a, 3, "Z")
        ellipsoid(bm, (math.cos(a) * r, math.sin(a) * r, z),
                  (rng.uniform(0.5, 1.0), rng.uniform(1.3, 2.7), rng.uniform(1.1, 2.4)),
                  subdiv=0, rot=rot)
    # A snapped spar driven into that same flank, and anchor chain grown into
    # it - on the shoulder the barnacles are on, not floating on its own.
    box(bm, (-6.0, 15.0, 16.0), (18.0, 1.7, 1.7), Matrix.Rotation(math.radians(-24), 3, "Y"))
    for i in range(7):
        t = i / 6
        box(bm, (-12.0 - t * 2.6, 11.6 + t * 2.2, 14.0 - t * 7.4),
            (1.7, 1.2, 0.5) if i % 2 == 0 else (1.7, 0.5, 1.2))
    return finish("Kraken_Crust", bm, KR_CRUST)


# Where the eyes sit: bearing off +X, and the height of the dome's widest
# ring. Everything eye-shaped is built on this one frame so the lens, the
# pupil and the brow over them cannot drift apart.
KR_EYE_BEARING = math.radians(27.0)
KR_EYE_Z = 15.0
KR_EYE_SEAT = 18.4  # centre radius; the mantle's own surface here is 19.8


def _kr_eye_frame(side, tilt=0.0):
    """(rotation, outward unit) for one eye - local +X points out of the head,
    local +Y runs back along the flank, local +Z is up. `tilt` rolls about the
    outward axis, which is how the brow gets its angle: positive drops the
    FORWARD end of the ridge on either side, mirrored, so the two of them read
    as a scowl rather than as two level shelves."""
    angle = side * KR_EYE_BEARING
    rot = Matrix.Rotation(angle, 3, "Z")
    if tilt:
        rot = rot @ Matrix.Rotation(side * tilt, 3, "X")
    return rot, (math.cos(angle), math.sin(angle))


def build_kr_eyes():
    bm = bmesh.new()
    # Enormous and BULGING, the way an octopus's are. The previous pass sat
    # them buried inside the dome and the head read as a blank potato. They
    # are seated proud now - 4.8 deep on an 18.4 seat, so 3.4 studs of lens
    # stand out - and brought FORWARD to 27 degrees off the nose, close enough
    # together that you see BOTH of them at once from in front. An octopus's
    # eyes really do sit on its flanks, but a boss you fight head-on has to
    # look back at you.
    for side in (-1, 1):
        rot, out = _kr_eye_frame(side)
        ellipsoid(bm, (out[0] * KR_EYE_SEAT, out[1] * KR_EYE_SEAT, KR_EYE_Z),
                  (5.0, 6.4, 5.4), subdiv=2, rot=rot)
    return finish("Kraken_Eyes", bm, KR_EYE)


def build_kr_pupil():
    bm = bmesh.new()
    # The horizontal slit, laid on the lens's outer face. Its own object so it
    # can be its own colour - an eye is not one flat disc of purple, and this
    # is the piece that makes the head look back at you. HALF the lens's
    # width, deliberately: spanning it edge to edge just draws a closed
    # eyelid, and the thing stops looking awake.
    for side in (-1, 1):
        rot, out = _kr_eye_frame(side)
        seat = KR_EYE_SEAT + 3.4
        ellipsoid(bm, (out[0] * seat, out[1] * seat, KR_EYE_Z), (2.0, 3.1, 1.05), subdiv=1, rot=rot)
    return finish("Kraken_Pupil", bm, KR_PUPIL)


def build_kr_beak():
    bm = bmesh.new()
    # The beak, at the centre of the arm crown on the underside: two hooked
    # mandibles crossing like shears. Both halves ride one object and the
    # server rotates them about KR_BEAK_HINGE.
    for sign in (1, -1):
        loft(bm, [
            ring_pts(0.0, sign * 0.6, 2.6, 1.4, sides=7),
            ring_pts(1.8, sign * 0.9, 2.0, 1.1, sides=7),
            ring_pts(3.2, sign * 1.5, 1.2, 0.7, sides=7),
        ], cap_end=False)
        spike(bm, (3.2, 0, sign * 1.5), (4.0, 0, -sign * 0.3), 0.5, sides=5)
    return finish("Kraken_Beak", bm, KR_BEAK)


def build_kr_arm_seg():
    bm = bmesh.new()
    # ONE arm segment: a capsule, authored LONGER than the pitch it is placed
    # at so consecutive segments always overlap into one limb.
    _capsule(bm, KR_SEG_LENGTH, 4.30, 4.30, sides=14)
    return finish("Kraken_ArmSeg", bm, KR_HIDE)


def build_kr_arm_tip():
    bm = bmesh.new()
    # The last stretch of arm: still a capsule so it welds to the segment
    # before it, but drawn out to a long curling point.
    loft(bm, [
        ring_pts(2.8, 0.0, 2.1, 2.1, sides=14),
        ring_pts(1.6, 0.0, 3.90, 3.90, sides=14),
        ring_pts(-1.6, 0.0, 2.80, 2.80, sides=14),
        ring_pts(-5.4, 0.0, 1.50, 1.50, sides=14),
        ring_pts(-9.0, 0.0, 0.34, 0.34, sides=14),
    ])
    return finish("Kraken_ArmTip", bm, KR_HIDE)


def build_kr_sucker():
    bm = bmesh.new()
    # One sucker, and they are MEANT to be seen - the first pass made them a
    # quarter of the arm's width AND laid them along it, so they vanished into
    # the hide. A raised rim with a pad standing proud of it, 4.6 across on an
    # 8.6-wide arm, in ONE row down the underside. Instanced base-to-tip and
    # lit through a wind-up: the telegraph is anatomy.
    disc(bm, -0.50, 0.42, 2.30, 1.90, sides=14)
    disc(bm, 0.36, 0.78, 1.66, 1.18, sides=14)
    return finish("Kraken_Sucker", bm, KR_EYE)


def build_kraken():
    rng = random.Random(4471)
    objects = [
        build_kr_head(rng),
        build_kr_crown(rng),
        build_kr_crust(rng),
        build_kr_eyes(),
        build_kr_pupil(),
        build_kr_beak(),
        build_kr_arm_seg(),
        build_kr_arm_tip(),
        build_kr_sucker(),
    ]
    print("HANDOFF kraken: head is a dome on +Z - half-width 20.0, 33.2 TALL; arm crown under it to z=-4.2")
    print("HANDOFF kraken: EIGHT arm sockets on the crown at r=18.2, evenly spaced - the ring the entities plant on")
    print("HANDOFF kraken: beak at the crown's centre, hinge %s - the server rotates both mandibles about it" % (KR_BEAK_HINGE,))
    print("HANDOFF kraken: eyes at (5.8, +/-16.4, 13.2) r6.0 with a slit pupil - Neon swap for the wind-up flare")
    print("HANDOFF kraken: arm segment is a CAPSULE %.1f long placed every %.1f - %.1f studs of overlap, so an arm is one limb"
          % (KR_SEG_LENGTH, KR_ARM_SPACING, KR_SEG_LENGTH - KR_ARM_SPACING))
    print("HANDOFF kraken: %d segments + tip = ~%.0f studs of arm at scale 1; base half-width 2.55" % (KR_ARM_SEGMENTS, KR_ARM_SPACING * KR_ARM_SEGMENTS + 8.0))


    return objects


# ================================================================ gnashroot
#
# "Old Gnashroot, the Fen Tyrant" - the swamp's boss, and the colossus idea
# pushed the opposite way from Brinejaw. Brinejaw is ONE long chain that goes
# everywhere. Gnashroot is a body that goes NOWHERE - a half-sunken gator-oak
# lying in the Rootmere with only its back and skull above the water, reading
# as an islet until it opens an eye - plus FOUR SHORT CHAINS that do all the
# attacking: root-limbs that erupt out of the peat anywhere in the arena.
#
# So the parts split in two:
#   BODY (one CFrame, the Kraken's convention): Head/HeadBone/Jaw/JawBone/
#         Eyes/Maw/Back/Bark/Tree/Shelf are all authored in ONE shared space
#         with the skull's neck joint at the origin, the snout at +X and the
#         hump running back to -X. The client places them with a single
#         CFrame and no offsets; only the jaw moves, about its printed hinge.
#   LIMBS (four ChainPose chains): Arm/ArmKnot/Claw, authored the pack way -
#         centred on their own attach point, +X pointing UP-LIMB toward the
#         body, so a chain's tangent places them directly.
#
# Waterline is z = 0, so the model drops into the mere with no fudging: the
# hump crests ~5 studs proud at scale 1 (~8 at the row's 1.5), the belly and
# most of the mass stay under.

GN_HIDE = (0.227, 0.259, 0.180)   # moss-backed hide (the creature row's body colour)
GN_BARK = (0.345, 0.298, 0.204)   # root-bark plates (the row's finColor)
GN_BONE = (0.827, 0.812, 0.706)   # the fen's bone
GN_WISP = (0.588, 0.922, 0.784)   # wisp-lit eyes and maw (the row's markColor, Neon)
GN_DEAD = (0.40, 0.34, 0.27)      # the dead cypress riding its spine
GN_FUNG = (0.72, 0.70, 0.52)      # bracket fungus

# Skull cross-sections: (x, centre z, half width, half height). A GATOR skull -
# wide at the cheeks, flat on top, long blunt snout - not Brinejaw's serpent
# wedge. Neck joint at the origin, snout tip at x = +12. The underside is
# clamped flat at GN_JAW_LINE so the lower jaw closes on a real palate.
GN_JAW_LINE = -0.9
GN_SKULL = [
    (-5.0, 1.0, 4.2, 3.0),
    (-2.4, 0.9, 4.8, 2.9),  # cheeks, widest
    (0.4, 0.6, 3.9, 2.2),
    (3.4, 0.3, 2.9, 1.7),
    (6.6, 0.1, 2.4, 1.4),  # the long snout
    (9.6, 0.0, 1.9, 1.1),
    (12.0, -0.1, 1.3, 0.8),  # blunt tip
]

GN_JAW_TOP = -1.15
GN_JAW = [
    (-4.6, -2.0, 3.6, 1.5),
    (-2.0, -2.2, 4.2, 1.7),
    (0.8, -2.2, 3.4, 1.5),
    (3.8, -2.1, 2.6, 1.2),
    (7.0, -2.0, 2.0, 1.0),
    (10.0, -1.9, 1.4, 0.7),
    (12.0, -1.8, 0.9, 0.5),
]

# Where the client hinges the jaw (the gape before a bogspit, the gnash, the
# death bellow).
GN_JAW_HINGE = (-4.4, 0.0, -1.6)

# The hump: the drowned-oak back, lofted from the tail end forward into the
# shoulders where the skull takes over.
GN_BACK = [
    (-24.0, -1.2, 3.4, 2.2),  # the tail end, already sinking
    (-20.0, -0.7, 6.4, 4.2),
    (-15.5, -0.2, 9.0, 6.2),  # the crest - what reads as an islet
    (-11.0, 0.0, 9.5, 6.6),
    (-6.5, 0.4, 7.4, 5.0),  # shoulders, meeting the skull
]

# One limb vertebra, authored mid-limb; the client scales by u to taper.
GN_ARM = [
    (-1.8, 0.0, 1.5, 1.5),
    (-0.8, 0.0, 1.9, 1.9),
    (0.8, 0.0, 1.9, 1.9),
    (1.8, 0.0, 1.5, 1.5),
]
GN_ARM_SPACING = 3.6  # studs between segment centres along the path
GN_ARM_SEGMENTS = 9  # + the claw: ~36 studs of limb at scale 1


def build_gn_head(rng):
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=9, floor_z=GN_JAW_LINE) for x, cz, hw, hh in GN_SKULL])
    # Brow ridges standing over the eyes - a gator's periscope skull.
    for side in (-1, 1):
        box(
            bm,
            (-1.9, side * 3.3, 2.4),
            (5.4, 1.5, 1.0),
            Matrix.Rotation(math.radians(side * -6), 3, "X") @ Matrix.Rotation(math.radians(4), 3, "Y"),
        )
    # Nostril ridge on the snout - the part that breaks the water first.
    box(bm, (9.4, 0, 0.9), (2.6, 2.0, 0.8), Matrix.Rotation(math.radians(-3), 3, "Y"))
    # Moss and knotted growth crusting the skull: it has been lying here a
    # very long time.
    for _ in range(11):
        x = rng.uniform(-4.6, 6.0)
        side = rng.choice((-1, 1))
        ellipsoid(
            bm,
            (x, side * rng.uniform(1.6, 3.6), rng.uniform(0.6, 2.6)),
            (rng.uniform(0.35, 0.75),) * 3,
            subdiv=0,
        )
    return finish("Gnashroot_Head", bm, GN_HIDE)


def build_gn_head_bone(rng):
    bm = bmesh.new()
    # Upper teeth: a gator's are IRREGULAR - a few long canines among small
    # ones, which is what makes the jawline read as a bite rather than a comb.
    for i in range(9):
        t = i / 8
        x = 11.0 - t * 15.0
        hw = 1.1 + t * 3.4
        length = (1.1 if i in (2, 5) else 0.6) + t * 0.5
        for side in (-1, 1):
            spike(bm, (x, side * hw, GN_JAW_LINE + 0.1), (x, side * hw * 0.93, GN_JAW_LINE - length), 0.32, sides=4)
    return finish("Gnashroot_HeadBone", bm, GN_BONE)


def build_gn_jaw(rng):
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=8, ceil_z=GN_JAW_TOP) for x, cz, hw, hh in GN_JAW])
    # A ragged fringe of weed hanging off the lower jaw.
    for _ in range(7):
        x = rng.uniform(-3.0, 9.0)
        side = rng.choice((-1, 1))
        spike(bm, (x, side * rng.uniform(1.4, 3.4), -2.9), (x, side * rng.uniform(1.8, 4.2), -5.2), 0.22, sides=3)
    return finish("Gnashroot_Jaw", bm, GN_HIDE)


def build_gn_jaw_bone():
    bm = bmesh.new()
    # Lower teeth, standing up to interlock with the upper set.
    for i in range(8):
        t = i / 7
        x = 10.4 - t * 14.0
        hw = 0.9 + t * 2.9
        length = (1.4 if i in (3, 6) else 0.7) + t * 0.6
        for side in (-1, 1):
            spike(bm, (x, side * hw, GN_JAW_TOP - 0.1), (x, side * hw * 0.94, GN_JAW_TOP + length), 0.28, sides=4)
    return finish("Gnashroot_JawBone", bm, GN_BONE)


def build_gn_eyes():
    bm = bmesh.new()
    # Set high and forward on the brow: at rest, the eyes and the nostril
    # ridge are the ONLY things above the water. Neon in game.
    for side in (-1, 1):
        ellipsoid(bm, (-1.9, side * 3.3, 3.1), (0.95, 0.95, 0.8), subdiv=1)
    return finish("Gnashroot_Eyes", bm, GN_WISP)


def build_gn_maw():
    bm = bmesh.new()
    # The throat: dark until it gapes, then a wisp-lit furnace. This is the
    # bogspit tell - the client swells it through the wind-up.
    loft(
        bm,
        [
            ring_pts(-4.0, -0.9, 2.6, 1.0, sides=7),
            ring_pts(-1.0, -0.9, 3.0, 1.2, sides=7),
            ring_pts(2.5, -0.9, 2.2, 0.9, sides=7),
            ring_pts(5.5, -0.9, 1.4, 0.6, sides=7),
        ],
    )
    return finish("Gnashroot_Maw", bm, GN_WISP)


def build_gn_back(rng):
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=11) for x, cz, hw, hh in GN_BACK])
    # Boulders of moss-grown hide breaking the surface along the spine, so the
    # crest reads as ground rather than as a smooth animal.
    for _ in range(14):
        x = rng.uniform(-23.0, -7.0)
        ellipsoid(
            bm,
            (x, rng.uniform(-6.5, 6.5), rng.uniform(3.2, 6.4)),
            (rng.uniform(0.9, 2.1), rng.uniform(0.9, 1.9), rng.uniform(0.6, 1.3)),
            subdiv=0,
        )
    return finish("Gnashroot_Back", bm, GN_HIDE)


def build_gn_bark(rng):
    bm = bmesh.new()
    # The oak half: broken root-tusks sweeping back off the skull like a
    # stump's shattered crown. WOOD, not bone - as bone they read as tusks
    # from a different animal.
    for side in (-1, 1):
        spike(bm, (-3.6, side * 3.0, 2.6), (-9.4, side * 5.0, 5.4), 0.75, sides=5)
        spike(bm, (-4.4, side * 3.4, 1.0), (-8.6, side * 5.8, 2.2), 0.5, sides=5)
    # Osteoderm scutes in ranks down the back - gator armour read as bark.
    # Broad and low: PLATES. Tall ones turn the fen tyrant into a stegosaur.
    for i in range(9):
        x = -22.5 + i * 2.0
        t = i / 8
        for side in (-2, -1, 1, 2):
            spread = 1.6 + t * 3.0
            height = 4.0 + math.sin(t * math.pi) * 3.0
            size = 0.9 - abs(side) * 0.15
            box(
                bm,
                (x, side * spread, height - 0.2),
                (1.5, 1.9, size),
                Matrix.Rotation(math.radians(side * 26), 3, "X"),
            )
    # Long bark plates along the flanks, half-lifted off the hide.
    for _ in range(10):
        x = rng.uniform(-22.0, -7.5)
        side = rng.choice((-1, 1))
        box(
            bm,
            (x, side * rng.uniform(5.6, 8.4), rng.uniform(0.4, 3.2)),
            (rng.uniform(2.6, 4.6), 0.55, rng.uniform(1.4, 2.6)),
            Matrix.Rotation(math.radians(side * rng.uniform(8, 24)), 3, "X"),
        )
    # Plates over the snout, so the skull matches the back.
    for _ in range(5):
        x = rng.uniform(1.0, 9.0)
        box(bm, (x, rng.uniform(-1.4, 1.4), 1.5), (rng.uniform(1.6, 2.6), 2.2, 0.5))
    return finish("Gnashroot_Bark", bm, GN_BARK)


def build_gn_tree(rng):
    bm = bmesh.new()
    # THE SILHOUETTE. A dead cypress growing out of its spine - the thing that
    # tells you at 200 studs that the islet is an animal. Built the fen's way
    # (island_gen build_swamp_trees): a leaning trunk that forks.
    base = Vector((-15.0, 1.2, 5.8))
    top = base + Vector((-2.2, 0.4, 8.6))
    spike(bm, tuple(base), tuple(top), 2.4, sides=6)
    for _ in range(rng.randint(2, 3)):
        frac = rng.uniform(0.55, 0.92)
        at = base.lerp(top, frac)
        angle = rng.uniform(0, TAU)
        reach = rng.uniform(4.0, 7.0)
        tip = at + Vector((math.cos(angle) * reach, math.sin(angle) * reach, rng.uniform(1.5, 4.0)))
        spike(bm, tuple(at), tuple(tip), 1.0, sides=5)
        if rng.random() < 0.6:
            fork = tip + Vector((math.cos(angle + 0.8) * reach * 0.5, math.sin(angle + 0.8) * reach * 0.5, rng.uniform(0.8, 2.4)))
            spike(bm, tuple(tip), tuple(fork), 0.55, sides=4)
    # A second, snapped-off trunk further back: it has lost limbs before.
    stub = Vector((-20.0, -3.2, 4.2))
    spike(bm, tuple(stub), tuple(stub + Vector((-1.0, -0.6, 4.6))), 1.1, sides=5)
    return finish("Gnashroot_Tree", bm, GN_DEAD)


def build_gn_shelf(rng):
    bm = bmesh.new()
    # Bracket fungus stepping up the dead trunk and the hump's flanks - the
    # one pale note on a dark animal, and the fen's own colour language.
    # Squashed ellipsoids rather than discs: a bracket is a shelf, and a
    # flattened blob reads as one from every angle without a rotation.
    for _ in range(10):
        x = rng.uniform(-22.0, -8.0)
        side = rng.choice((-1, 1))
        ellipsoid(
            bm,
            (x, side * rng.uniform(5.2, 8.2), rng.uniform(1.0, 5.2)),
            (rng.uniform(1.3, 2.2), rng.uniform(1.0, 1.8), rng.uniform(0.28, 0.45)),
            subdiv=1,
        )
    for _ in range(6):
        angle = rng.uniform(0, TAU)
        ellipsoid(
            bm,
            (-15.4 + math.cos(angle) * 1.7, 1.2 + math.sin(angle) * 1.7, rng.uniform(7.0, 14.0)),
            (rng.uniform(0.9, 1.6), rng.uniform(0.9, 1.6), rng.uniform(0.24, 0.4)),
            subdiv=1,
        )
    return finish("Gnashroot_Shelf", bm, GN_FUNG)


def build_gn_arm():
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=7) for x, cz, hw, hh in GN_ARM])
    # Longitudinal root flanges: what makes a limb read as ROOT rather than
    # as a tentacle. Three ribs running the segment's length.
    for i in range(3):
        angle = (i / 3) * TAU + 0.4
        blade(
            bm,
            (-1.9, math.cos(angle) * 1.5, math.sin(angle) * 1.5),
            (1.9, math.cos(angle) * 2.3, math.sin(angle) * 2.3),
            1.3,
            1.0,
            0.3,
            roll=angle,
        )
    return finish("Gnashroot_Arm", bm, GN_BARK)


def build_gn_arm_knot(rng):
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=7) for x, cz, hw, hh in GN_ARM])
    # The burl: a knuckled swelling every few segments, so a long limb reads
    # as jointed wood instead of a hose.
    ellipsoid(bm, (0, 0, 0), (2.2, 2.5, 2.5), subdiv=1)
    for _ in range(4):
        angle = rng.uniform(0, TAU)
        length = rng.uniform(1.6, 3.2)
        spike(
            bm,
            (rng.uniform(-1.0, 1.0), math.cos(angle) * 1.9, math.sin(angle) * 1.9),
            (rng.uniform(-1.6, 1.6), math.cos(angle) * (1.9 + length), math.sin(angle) * (1.9 + length)),
            0.4,
            sides=4,
        )
    return finish("Gnashroot_ArmKnot", bm, GN_BARK)


def build_gn_claw(rng):
    bm = bmesh.new()
    # The hand at the limb's end. +X runs up-limb toward the body, so the
    # fingers splay toward -X: this is what plants in the peat, what the slam
    # lands on, and what closes round a snared player.
    loft(
        bm,
        [
            ring_pts(1.6, 0.0, 1.7, 1.7, sides=7),
            ring_pts(0.2, 0.0, 2.3, 2.3, sides=7),
            ring_pts(-1.2, 0.0, 1.9, 1.9, sides=7),
        ],
    )
    for i in range(5):
        angle = (i / 5) * TAU + 0.3
        spread = Vector((0, math.cos(angle), math.sin(angle)))
        knuckle = Vector((-1.4, 0, 0)) + spread * 1.7
        mid = knuckle + Vector((-2.6, 0, 0)) + spread * 1.5
        tip = mid + Vector((-2.4, 0, 0)) + spread * 0.4
        spike(bm, tuple(knuckle), tuple(mid), 0.62, sides=4)
        spike(bm, tuple(mid), tuple(tip), 0.42, sides=4)
        _ = rng
    return finish("Gnashroot_Claw", bm, GN_BARK)


def build_gnashroot():
    rng = random.Random(8821)
    objects = [
        build_gn_head(rng),
        build_gn_head_bone(rng),
        build_gn_jaw(rng),
        build_gn_jaw_bone(),
        build_gn_eyes(),
        build_gn_maw(),
        build_gn_back(rng),
        build_gn_bark(rng),
        build_gn_tree(rng),
        build_gn_shelf(rng),
        build_gn_arm(),
        build_gn_arm_knot(rng),
        build_gn_claw(rng),
    ]
    print("HANDOFF gnashroot: BODY is one CFrame - neck joint at the origin, snout tip x=+12, hump back to x=-24")
    print("HANDOFF gnashroot: waterline z=0; hump crests z=+6.6 (x=-11), belly to z=-6.6 - it lies half-sunk in the mere")
    print("HANDOFF gnashroot: jaw hinge pivot (%.1f, %.1f, %.1f) - the client rotates jaw + JawBone + Maw about it" % GN_JAW_HINGE)
    print("HANDOFF gnashroot: skull half-width 4.8 at the cheeks -> matches the row's hitRadius 6 at scale 1")
    print("HANDOFF gnashroot: eyes (-1.9, +/-3.3, 3.1) r0.95 and the nostril ridge (9.4, 0, 0.9) are ALL that shows at rest")
    print(
        "HANDOFF gnashroot: limb pitch %.1f, %d segments + claw = ~%.0f studs of reach at scale 1 (x1.5 = %.0f)"
        % (GN_ARM_SPACING, GN_ARM_SEGMENTS, GN_ARM_SPACING * GN_ARM_SEGMENTS + 4.0, (GN_ARM_SPACING * GN_ARM_SEGMENTS + 4.0) * 1.5)
    )
    print("HANDOFF gnashroot: limb half-width 1.9 at scale 1 -> slam hit girth ~3.8 studs; taper by u toward the claw")
    print("HANDOFF gnashroot: four limbs, ChainPose each; ArmKnot every 3rd segment, Claw at the tip")
    return objects

# ================================================================ noctyss
#
# "Noctyss, the Trench Mother" - the gloom boss, and the one fight in the
# saga where you never see the animal. What stands in the arena is her
# CHOIR: seven colossal angler-lure stalks pushed up through the Choirfloor's
# sockets, her fingers through a torn ceiling. She herself is under the
# shelf, and the only part of her that ever surfaces is the MAW, which comes
# up through the pit in the punish window - brow, jaws, and the lure-root
# glowing at the back of the throat. There is no body below the jaw, because
# there is never a camera angle that could see one.
#
# That splits this pack in two, and both halves are chains-and-CFrames, no
# rig:
#
#   THE STALK is a ChainPose chain like Brinejaw's body, stood on end. One
#   authored vertebra instanced up a path, a hood on top carrying the light.
#   t = 0 at the ROOT (in the socket) and t = 1 at the HOOD - the inverse of
#   Brinejaw's head-first ordering, because a stalk grows from its socket;
#   +X still runs along the chain toward the far end, so ChainPose's
#   convention is untouched. Sway, lean, the beam's aim and the death-fall
#   are all one shape function away from each other.
#
#   THE MAW is placed, not chained: one eased translation up through the pit
#   with the jaw hinging open at the top of it. Two CFrames a frame.
#
# Scale contract: the row spawns her at 1.8 with hitRadius 6, so the skull's
# widest half-width is authored at 6.0 - 10.8 studs of hide in game, which is
# what makes the melee reach agree with what the eye sees. The lower jaw is
# authored wide enough INSIDE to stand in: the punish window is players in
# her mouth (the design's third beat), and a scoop you cannot fit a party
# into would have killed the fight on contact with the geometry.

NC_HIDE = (0.17, 0.15, 0.23)  # the creature row's body colour: trench-black
NC_FIN = (0.27, 0.23, 0.36)  # membrane, a shade up from the hide
NC_BONE = (0.80, 0.78, 0.70)  # needle teeth and the lantern cage
NC_LURE = (1.00, 0.89, 0.51)  # the row's markColor - every light in the fight
NC_EYE = (1.00, 0.72, 0.26)  # small, dim, and set far back: a deep-water eye

# ---- the choir stalk ------------------------------------------------------

# One vertebra, authored mid-stalk. The client scales it by u to taper the
# stalk from a thick root to a thin neck under the hood.
NC_SEG = [
    (-1.50, 0.0, 1.15, 1.15),
    (-0.55, 0.0, 1.50, 1.50),
    (0.55, 0.0, 1.50, 1.50),
    (1.50, 0.0, 1.15, 1.15),
]
NC_SEG_SPACING = 3.0  # studs between segment centres along the path
NC_STALK_SEGMENTS = 11  # ~33 studs of stalk at scale 1

# The hood: neck joint at the origin, crown reaching +X, the lantern slung
# under its front lip. Cross-sections are (x, centre z, half width, half height).
NC_HOOD = [
    (0.0, 0.0, 1.05, 1.05),
    (1.2, 0.25, 2.20, 1.95),
    (2.6, 0.45, 3.25, 2.75),
    (4.0, 0.50, 3.55, 2.85),  # the crown, widest
    (5.2, 0.20, 2.75, 2.15),
    (6.1, -0.25, 1.30, 1.00),
]

# Where the light hangs, in the hood's own space - the client parents the
# bulb's PointLight here, and the fight's "shoot the lure" hitbox is this
# sphere. Printed in the HANDOFF because three systems need the same number.
NC_BULB = (6.6, 0.0, -3.2)
NC_BULB_R = 2.0


def build_nc_stalk_seg():
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=7) for x, cz, hw, hh in NC_SEG])
    # A knuckle ring at the joint: a long run of plain drums reads as pipe,
    # and this stalk has to read as grown.
    disc(bm, -0.25, 0.25, 1.72, 1.72, sides=7)
    # Two vestigial barbs, alternating sides down the stalk once instanced.
    for side in (-1, 1):
        spike(bm, (0.2, side * 1.35, 0.2), (0.9, side * 2.5, 0.9), 0.24, sides=4)
    return finish("Noctyss_StalkSeg", bm, NC_HIDE)


def build_nc_stalk_fin():
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=7) for x, cz, hw, hh in NC_SEG])
    disc(bm, -0.25, 0.25, 1.72, 1.72, sides=7)
    # Every few vertebrae carries membranes instead of barbs, so the stalk
    # has a silhouette when it is unlit and there is nothing else to see.
    for side in (-1, 1):
        blade(bm, (0.4, side * 1.2, 0.3), (-1.6, side * 3.6, -1.4), 2.2, 0.5, 0.16)
    blade(bm, (0.3, 0, 1.4), (-1.8, 0, 3.6), 2.0, 0.4, 0.16, roll=math.radians(90))
    return finish("Noctyss_StalkFin", bm, NC_HIDE)


def build_nc_stalk_hood(rng):
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=8) for x, cz, hw, hh in NC_HOOD])
    # The overhang: ribs curling forward and DOWN off the crown, so the light
    # underneath is shaded from above. That shadow is why a lit stalk reads
    # as a lantern on a pole rather than a glowing ball - and why a player
    # can tell which way a stalk is facing before it does anything.
    for i in range(5):
        spread = (i - 2) / 2.0
        base = Vector((4.6, spread * 2.6, 0.9 - abs(spread) * 0.5))
        tip = Vector((7.4, spread * 2.1, -2.2 - abs(spread) * 0.4))
        blade(bm, base, tip, 1.5, 0.7, 0.3, roll=math.radians(70))
    # Shoulder flanges, raked back: the hood's own frill.
    for side in (-1, 1):
        blade(bm, (2.4, side * 2.8, 0.4), (-0.6, side * 5.2, -0.8), 2.6, 0.6, 0.2)
    # Crusted growths on the crown - it has been standing here a long time.
    for _ in range(7):
        ellipsoid(
            bm,
            (rng.uniform(1.4, 4.6), rng.uniform(-2.4, 2.4), rng.uniform(1.4, 2.9)),
            (rng.uniform(0.25, 0.5),) * 3,
            subdiv=0,
        )
    return finish("Noctyss_StalkHood", bm, NC_HIDE)


def build_nc_stalk_cage():
    bm = bmesh.new()
    # The lantern cage, in the HOOD's space (it rides the hood's CFrame, the
    # way Brinejaw's eyes ride its head). Ribs from the hood's lip curling
    # around the bulb and meeting under it.
    bulb = Vector(NC_BULB)
    for i in range(5):
        angle = (i / 5) * TAU + 0.3
        side = Vector((0.0, math.cos(angle), math.sin(angle)))
        top = Vector((5.3, 0, -0.3)) + side * 1.0
        belly = bulb + side * (NC_BULB_R + 0.55)
        spike(bm, tuple(top), tuple(belly), 0.24, sides=4)
        spike(bm, tuple(belly), tuple(bulb + Vector((1.5, 0, 0)) + side * 0.35), 0.2, sides=4)
    # The stem the whole lantern hangs from.
    spike(bm, (5.0, 0, 0.2), (6.2, 0, -1.6), 0.4, sides=5)
    return finish("Noctyss_StalkCage", bm, NC_BONE)


def build_nc_stalk_bulb():
    bm = bmesh.new()
    # THE LIGHT. Its own object because the client does three things to it
    # that nothing else in the pack needs: Neon while lit, plastic when
    # doused, and a PointLight parented at its centre. The true lure is this
    # same mesh pulsing off the choir's rhythm - the tell is timing, not
    # shape, so nothing here distinguishes it.
    ellipsoid(bm, NC_BULB, (NC_BULB_R, NC_BULB_R * 0.92, NC_BULB_R * 1.06), subdiv=2)
    # Filament tips trailing off the bottom of the bulb, where the light
    # frays into the water.
    for i in range(4):
        angle = (i / 4) * TAU + 0.4
        base = Vector(NC_BULB) + Vector((0.2, math.cos(angle) * 0.7, -NC_BULB_R * 0.8 + math.sin(angle) * 0.3))
        spike(bm, tuple(base), tuple(base + Vector((0.5, math.cos(angle) * 0.5, -1.6))), 0.16, sides=4)
    return finish("Noctyss_StalkBulb", bm, NC_LURE)


def build_nc_stalk_barbs(rng):
    bm = bmesh.new()
    # Filaments trailing off the hood - the drift that says this thing is
    # underwater even when the water is invisible.
    for i in range(6):
        side = -1 if i % 2 else 1
        base = Vector((rng.uniform(0.4, 3.2), side * rng.uniform(1.8, 3.0), rng.uniform(-1.2, 0.6)))
        direction = Vector((-1.0, side * rng.uniform(0.3, 0.9), rng.uniform(-0.6, 0.3))).normalized()
        blade(bm, tuple(base), tuple(base + direction * rng.uniform(4.0, 7.0)), 0.9, 0.15, 0.1)
    return finish("Noctyss_StalkBarbs", bm, NC_FIN)


def build_nc_stalk_root(rng):
    bm = bmesh.new()
    # The flare that sits in the arena's socket collar (inner radius ~3.1),
    # and the piece that STAYS when a stalk dies: the client leaves the root
    # and clears everything above it, so a killed socket reads as a stump
    # rather than an empty hole.
    loft(
        bm,
        [
            ring_pts(-2.6, 0.0, 3.35, 3.35, sides=9),
            ring_pts(-0.8, 0.0, 2.95, 2.95, sides=9),
            ring_pts(1.2, 0.0, 2.05, 2.05, sides=9),
            ring_pts(2.6, 0.0, 1.55, 1.55, sides=9),
        ],
    )
    # Root plates gripping the stone.
    for i in range(6):
        angle = (i / 6) * TAU + rng.uniform(-0.15, 0.15)
        side = Vector((0.0, math.cos(angle), math.sin(angle)))
        base = Vector((-2.2, 0, 0)) + side * 2.6
        blade(bm, tuple(base), tuple(base + Vector((-2.2, 0, 0)) + side * 1.9), 1.9, 0.7, 0.4)
    return finish("Noctyss_StalkRoot", bm, NC_HIDE)


# ---- the maw --------------------------------------------------------------

NC_JAW_LINE = -1.0  # roof of the mouth: the skull's underside is clamped flat here
NC_SKULL = [
    (-9.0, 1.0, 3.0, 2.6),
    (-6.0, 1.2, 5.2, 4.2),
    (-2.5, 1.0, 6.0, 4.6),  # the brow, widest - the hitRadius contract
    (1.5, 0.4, 5.4, 3.8),
    (5.5, -0.2, 4.0, 2.6),
    (9.0, -0.6, 2.4, 1.5),
    (11.5, -0.8, 1.1, 0.7),  # snout tip
]

NC_JAW_TOP = -1.35
NC_JAW = [
    (-8.6, -3.1, 2.8, 2.1),
    (-5.2, -3.7, 5.0, 3.0),
    (-1.2, -3.9, 5.6, 3.2),  # the widest of the scoop - you stand in here
    (2.8, -3.7, 4.9, 2.9),
    (6.6, -3.3, 3.4, 2.1),
    (10.2, -2.8, 1.6, 1.1),
]

NC_JAW_HINGE = (-8.0, 0.0, -2.2)  # the client rotates the jaw about this to gape
NC_GULLET = (-5.4, 0.0, -1.8)  # the lure-root at the back of the throat: THE weak point
NC_GULLET_R = 3.0


def build_nc_skull(rng):
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=9, floor_z=NC_JAW_LINE) for x, cz, hw, hh in NC_SKULL])
    # The brow shelf: an overhung ledge above the eyes, so the face reads as
    # shadow with lights in it from below - the only angle anyone ever gets.
    for side in (-1, 1):
        box(
            bm,
            (-2.4, side * 4.3, 3.6),
            (9.0, 2.2, 1.4),
            Matrix.Rotation(math.radians(side * -10), 3, "X") @ Matrix.Rotation(math.radians(7), 3, "Y"),
        )
    # A ledge across the front of the brow, tying the two ridges together: it
    # is what turns the face from a wedge into a hood with a shadow under it.
    box(bm, (1.2, 0, 2.6), (5.4, 8.2, 1.2), Matrix.Rotation(math.radians(9), 3, "Y"))
    # Crusted plates along the crown and cheeks.
    for _ in range(11):
        x = rng.uniform(-7.0, 6.0)
        side = rng.choice((-1, 1))
        ellipsoid(
            bm,
            (x, side * rng.uniform(2.4, 5.0), rng.uniform(0.2, 3.6)),
            (rng.uniform(0.35, 0.75),) * 3,
            subdiv=0,
        )
    return finish("Noctyss_Skull", bm, NC_HIDE)


def build_nc_skull_bone():
    bm = bmesh.new()
    # THE PALISADE. Long, splayed, uneven needles hanging the length of the
    # upper jaw - her one unmistakable feature, and the thing a player is
    # looking at while standing inside her mouth. Splay grows toward the
    # front so the tips frame the opening instead of closing it.
    for i in range(9):
        t = i / 8
        x = 10.6 - t * 18.4
        hw = 0.9 + t * 4.6
        length = 1.1 + t * 2.6
        splay = 0.16 + t * 0.42
        for side in (-1, 1):
            spike(
                bm,
                (x, side * hw, NC_JAW_LINE + 0.2),
                (x + 0.4, side * (hw + splay * 2.2), NC_JAW_LINE - length),
                0.30 + t * 0.12,
                sides=4,
            )
    # Brow horns, swept back off the skull.
    for side in (-1, 1):
        spike(bm, (-4.8, side * 3.8, 3.2), (-11.5, side * 5.6, 6.4), 1.0, sides=5)
        spike(bm, (-6.0, side * 4.4, 1.2), (-11.0, side * 6.8, 2.4), 0.6, sides=5)
    return finish("Noctyss_SkullBone", bm, NC_BONE)


def build_nc_jaw():
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=8, ceil_z=NC_JAW_TOP) for x, cz, hw, hh in NC_JAW])
    # A tongue ridge down the middle of the scoop. In game the floor players
    # stand on is anchored server parts pinned inside this shape - the mesh
    # itself is collision-free like every other creature part - so this ridge
    # is what tells them where the floor is.
    box(bm, (-1.0, 0, -5.6), (13.0, 3.2, 0.8))
    return finish("Noctyss_Jaw", bm, NC_HIDE)


def build_nc_jaw_bone():
    bm = bmesh.new()
    # The lower half of the palisade, standing up to interlock with the
    # upper. When the jaw closes these two sets mesh - that is the cage the
    # punish window shuts you inside.
    for i in range(8):
        t = i / 7
        x = 9.6 - t * 16.8
        hw = 0.8 + t * 4.2
        length = 1.0 + t * 2.3
        splay = 0.14 + t * 0.38
        for side in (-1, 1):
            spike(
                bm,
                (x, side * hw, NC_JAW_TOP - 0.2),
                (x + 0.3, side * (hw + splay * 2.0), NC_JAW_TOP + length),
                0.27 + t * 0.1,
                sides=4,
            )
    return finish("Noctyss_JawBone", bm, NC_BONE)


def build_nc_gullet():
    bm = bmesh.new()
    # THE WEAK POINT: her own lure-root, grown back into her throat where
    # nothing was ever supposed to reach it. Authored in the SKULL's space so
    # it rides the head and does not swing with the jaw. A knot of light with
    # roots running back up into the palate - the thing you are in there for.
    ellipsoid(bm, NC_GULLET, (NC_GULLET_R * 1.15, NC_GULLET_R, NC_GULLET_R * 0.9), subdiv=2)
    root = Vector(NC_GULLET)
    for i in range(6):
        angle = (i / 6) * TAU + 0.25
        side = Vector((0.0, math.cos(angle), math.sin(angle)))
        spike(bm, tuple(root + side * NC_GULLET_R * 0.7), tuple(root + side * 3.1 + Vector((-2.2, 0, 0.6))), 0.34, sides=4)
    return finish("Noctyss_Gullet", bm, NC_LURE)


def build_nc_eyes():
    bm = bmesh.new()
    # Small and set far back under the brow: a thing that hunts by its own
    # light does not need much, and two big lamps would compete with the
    # lures for the player's attention.
    for side in (-1, 1):
        ellipsoid(bm, (-3.0, side * 5.1, 1.7), (0.95, 0.95, 0.95), subdiv=1)
    return finish("Noctyss_Eyes", bm, NC_EYE)


def build_nc_barbels(rng):
    bm = bmesh.new()
    # Chin filaments, in the JAW's space so they swing with the gape.
    for i in range(6):
        side = -1 if i % 2 else 1
        base = Vector((rng.uniform(1.0, 6.5), side * rng.uniform(1.6, 3.4), -5.6))
        direction = Vector((rng.uniform(0.2, 0.7), side * rng.uniform(0.2, 0.6), -1.0)).normalized()
        blade(bm, tuple(base), tuple(base + direction * rng.uniform(4.5, 8.0)), 0.8, 0.14, 0.1)
    return finish("Noctyss_Barbels", bm, NC_FIN)


def build_noctyss():
    rng = random.Random(6421)
    objects = [
        build_nc_stalk_seg(),
        build_nc_stalk_fin(),
        build_nc_stalk_hood(rng),
        build_nc_stalk_cage(),
        build_nc_stalk_bulb(),
        build_nc_stalk_barbs(rng),
        build_nc_stalk_root(rng),
        build_nc_skull(rng),
        build_nc_skull_bone(),
        build_nc_jaw(),
        build_nc_jaw_bone(),
        build_nc_gullet(),
        build_nc_eyes(),
        build_nc_barbels(rng),
    ]
    print("HANDOFF noctyss: TWO assemblies in one pack - the choir stalk (chain) and the maw (placed).")
    print("HANDOFF noctyss: stalk +X runs UP-stalk toward the hood; t=0 at the root, t=1 at the hood")
    print(
        "HANDOFF noctyss: segment spacing %.1f, %d segments = ~%.0f studs of stalk at scale 1; taper by u"
        % (NC_SEG_SPACING, NC_STALK_SEGMENTS, NC_SEG_SPACING * NC_STALK_SEGMENTS)
    )
    print("HANDOFF noctyss: StalkRoot sits in the arena socket (collar inner r ~3.1) and REMAINS as the stump on death")
    print(
        "HANDOFF noctyss: hood neck joint at the origin, crown to x=+6.1; bulb centre (%.1f, %.1f, %.1f) r %.1f"
        " - the light source, the 'shoot the lure' hitbox, and the pulse the true lure breaks rhythm on"
        % (NC_BULB[0], NC_BULB[1], NC_BULB[2], NC_BULB_R)
    )
    print("HANDOFF noctyss: Cage/Bulb/Barbs are authored in the HOOD's space - one CFrame places all four")
    print("HANDOFF noctyss: maw faces +X; skull half-width 6.0 at scale 1 -> 10.8 at the row's 1.8 = hitRadius 6")
    print("HANDOFF noctyss: snout tip x=+11.5, brow horns back to x=-11.5; jaw hinge (%.1f, %.1f, %.1f)" % NC_JAW_HINGE)
    print(
        "HANDOFF noctyss: jaw scoop interior ~11.2 wide x 13 long at scale 1 (20 x 23 at 1.8) - the punish"
        " platform's footprint; the walkable floor is anchored parts pinned inside it, not this mesh"
    )
    print(
        "HANDOFF noctyss: gullet centre (%.1f, %.1f, %.1f) r %.1f in the SKULL's space - the punish-window weak point"
        % (NC_GULLET[0], NC_GULLET[1], NC_GULLET[2], NC_GULLET_R)
    )
    return objects


# ================================================================ rimefang
#
# "Rimefang, the Floe-Breaker" - the ice island's boss. A KILLER WHALE the
# size of a ship, hunting the way orcas really hunt seals on pack ice: it
# spy-hops to find you, wave-washes you off your footing, and beaches itself
# on the floe to take you, then works its way back to the water.
#
# WHY A WHALE IS A CHAIN AT ALL. Brinejaw is 60 vertebrae because a serpent
# IS its spine. A whale is not: it is a rigid forebody with a flexing tail.
# So this is a SHORT chain - ~15 segments - and almost all of the shape lives
# in the head piece and in the girth curve (_rf_girth), not in the vertebrae.
# The head-history trick still drives it, which is what makes the breach arc
# and the beached thrash free: only the head is ever animated.
#
# WHAT MAKES IT READ AS AN ORCA, in order of importance:
#   1. THE EYE PATCH. One white slab on each flank, raked up and back. It is
#      the single marking that says "orca" at 60 studs, and it is why _Rime
#      is its own object (one material per object).
#   2. HORIZONTAL FLUKES. A whale's tail is a pair of lobes spread across the
#      body, not a fish's vertical fin. Get this wrong and it reads as a fish
#      no matter what else is right.
#   3. The dorsal - here a raked sail of clear glacial ice, the thing you see
#      cutting a wake under the sheet.
#   4. Countershading: _Belly rides every vertebra, so the white underside
#      runs the length of the body without a second material on _Body.
#
# NO HARPOON (user, 2026-08-29). The iron in its back is gone; the punish is
# the BEACHED WINDOW itself - the seconds it spends thrashing on the floe
# after a breach - not a marked spot to hit. The arena's frozen whaler keeps
# its harpoon gun, so the story survives without the prop on the boss.

RF_SLATE = (0.10, 0.12, 0.15)  # the hide - near-black, cold
RF_RIME = (0.90, 0.93, 0.95)  # rime-crust markings, not pigment
RF_ICE = (0.62, 0.80, 0.88)  # the dorsal sail: clear glacial ice
RF_TOOTH = (0.86, 0.83, 0.72)
RF_EYE = (0.72, 0.88, 1.00)
RF_IRON = (0.20, 0.19, 0.18)

# Skull cross-sections: (x, centre z, half width, half height). Snout at +X,
# neck joint at the origin end - the pack's convention. The underside is
# clamped flat at RF_MOUTH_LINE so the lower jaw closes on a real palate.
RF_MOUTH_LINE = -2.2
RF_SKULL = [
    (-6.5, 0.0, 6.4, 6.9),  # neck joint - carries the body's full girth
    (-3.6, 0.3, 6.9, 7.4),  # widest: the melon's shoulder
    (-0.6, 0.5, 6.6, 7.0),  # the melon crown
    (2.4, 0.3, 5.6, 5.8),
    (5.0, 0.0, 4.2, 4.2),
    (7.0, -0.2, 2.8, 2.7),
    (8.6, -0.3, 1.6, 1.5),  # blunt snout - NOT a point
]

RF_JAW_TOP = -2.6
RF_JAW = [
    (-6.0, -4.4, 5.6, 2.4),
    (-3.0, -4.6, 6.2, 2.6),
    (0.5, -4.6, 5.6, 2.5),
    (3.6, -4.4, 4.4, 2.0),
    (6.0, -4.0, 3.0, 1.4),
    (8.0, -3.6, 1.6, 0.9),
]

# Where the client hinges the jaw (the spy-hop gape, the bite, the death).
RF_JAW_HINGE = (-5.4, 0.0, -3.2)

# Mid-body vertebra - the client scales this by u down the girth curve.
RF_SEG = [
    (-2.7, 0.0, 6.3, 6.9),
    (-1.3, 0.0, 6.6, 7.2),
    (1.3, 0.0, 6.6, 7.2),
    (2.7, 0.0, 6.3, 6.9),
]
RF_SEG_SPACING = 3.6


def _rf_girth(u):
    """Girth down the body, head end (0) to peduncle (1).

    A whale is not a cone. It holds its full girth from just behind the head
    to past mid-body, then the peduncle pinches hard into the flukes - and
    that pinch is most of what separates a whale silhouette from a fish's.
    """
    if u < 0.16:
        return 0.88 + 0.12 * (u / 0.16)
    if u < 0.46:
        return 1.0
    return 1.0 - 0.78 * ((u - 0.46) / 0.54) ** 1.45


def build_rf_head(rng):
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=10, floor_z=RF_MOUTH_LINE) for (x, cz, hw, hh) in RF_SKULL])
    # The blowhole, set back on the crown where a whale's actually is.
    ellipsoid(bm, (-2.6, 0.0, 7.3), (1.5, 1.1, 0.5))
    # Rime crust caked along the rostrum - it has been in the cold a long time.
    for _ in range(9):
        x = rng.uniform(3.0, 9.5)
        side = rng.choice((-1, 1))
        ellipsoid(bm, (x, side * rng.uniform(0.6, 1.9), rng.uniform(-0.4, 1.2)), (rng.uniform(0.4, 0.8),) * 3)
    return finish("Rimefang_Head", bm, RF_SLATE)


def build_rf_jaw(rng):
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=8, ceil_z=RF_JAW_TOP) for (x, cz, hw, hh) in RF_JAW])
    return finish("Rimefang_Jaw", bm, RF_SLATE)


def _rf_at(table, x):
    """Interpolate a cross-section table at x - used to seat teeth on the
    real jaw line instead of a guessed straight one."""
    for (x0, cz0, hw0, hh0), (x1, cz1, hw1, hh1) in zip(table, table[1:]):
        if x <= x1:
            t = 0.0 if x1 == x0 else (x - x0) / (x1 - x0)
            return (cz0 + (cz1 - cz0) * t, hw0 + (hw1 - hw0) * t, hh0 + (hh1 - hh0) * t)
    return table[-1][1:]


def build_rf_teeth():
    bm = bmesh.new()
    # Big interlocking cones, both jaws. Orca teeth already ARE cones, so
    # low-poly costs nothing here - but EIGHT a row, not eleven: the denser
    # first pass read as a saw blade rather than a mouth full of pegs.
    for i in range(8):
        t = i / 7.0
        x = -4.0 + t * 11.0
        size = 1.15 * (1.0 - 0.5 * t)
        _, upper_w, _ = _rf_at(RF_SKULL, x)
        _, lower_w, _ = _rf_at(RF_JAW, x)
        for side in (-1, 1):
            uy = side * (upper_w - 1.5)
            spike(bm, (x, uy, RF_MOUTH_LINE + 0.3), (x - 0.2, uy, RF_MOUTH_LINE - 2.6 * size / 1.15), size)
            ly = side * (lower_w - 1.3)
            spike(bm, (x, ly, RF_JAW_TOP - 0.3), (x - 0.2, ly, RF_JAW_TOP + 2.6 * size / 1.15), size)
    return finish("Rimefang_Teeth", bm, RF_TOOTH)


def build_rf_eyes():
    bm = bmesh.new()
    for side in (-1, 1):
        ellipsoid(bm, (-2.6, side * (_rf_flank_y(-2.6, -1.5) + 0.1), -1.5), (0.62, 0.34, 0.52))
    return finish("Rimefang_Eyes", bm, RF_EYE)


def _rf_flank_y(x, z):
    """Where the skull's surface is at (x, z) - so a marking can be laid ON
    the flank instead of floating off it or sinking into it."""
    cz, hw, hh = _rf_at(RF_SKULL, x)
    return hw * math.sqrt(max(0.0, 1.0 - ((z - cz) / hh) ** 2))


def _rf_flank_y(x, z):
    """Where the skull's surface is at (x, z) - so a marking can be laid ON
    the flank instead of floating off it or sinking into it."""
    cz, hw, hh = _rf_at(RF_SKULL, x)
    return hw * math.sqrt(max(0.0, 1.0 - ((z - cz) / hh) ** 2))


def _rf_patch(bm, x, z, length, height, tilt, side, thick=0.55):
    """A flat marking laid on the flank at (x, z), raked by `tilt`.

    Deliberately NOT blade(): blade aligns its own +X to the axis you give
    it, and on a near-horizontal axis its roll comes out as a twist - two
    passes produced a white hook hanging off the cheek instead of a patch.
    A box with an explicit rotation is unambiguous.
    """
    mat = (
        Matrix.Translation(Vector((x, side * (_rf_flank_y(x, z) + 0.04), z)))
        @ Matrix.Rotation(tilt, 4, "Y")
        @ Matrix.Diagonal(Vector((length / 2, thick / 2, height / 2))).to_4x4()
    )
    bmesh.ops.create_icosphere(bm, subdivisions=1, radius=1.0, matrix=mat)


def build_rf_rime(rng):
    bm = bmesh.new()
    # THE EYE PATCH - the marking that carries the whole read. Big, raked up
    # and back off the eye, and seated on the real flank.
    for side in (-1, 1):
        _rf_patch(bm, -4.1, 2.3, 8.6, 3.8, math.radians(15), side, thick=0.7)
    # The throat panel: countershading running back off the chin. _Belly
    # carries it on down the body.
    loft(
        bm,
        [
            ring_pts(-6.2, -6.2, 4.4, 0.6, sides=6),
            ring_pts(-1.0, -6.4, 4.8, 0.7, sides=6),
            ring_pts(3.8, -5.8, 3.4, 0.6, sides=6),
            ring_pts(7.0, -4.6, 1.6, 0.4, sides=6),
        ],
    )
    return finish("Rimefang_Rime", bm, RF_RIME)


def build_rf_body():
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=10) for (x, cz, hw, hh) in RF_SEG])
    return finish("Rimefang_Body", bm, RF_SLATE)


def build_rf_belly():
    bm = bmesh.new()
    # Rides every vertebra, so the white underside runs the whole body
    # without needing a second material on _Body.
    #
    # Authored MUCH longer than the vertebra pitch (12 studs against a 2-4
    # stud step) and nearly flat underneath. A panel the length of its own
    # segment stair-steps down the belly as a row of white scallops - the
    # same overlap rule the kraken's arm capsules use, for the same reason.
    ellipsoid(bm, (0.0, 0.0, -6.3), (6.2, 3.0, 1.1))
    return finish("Rimefang_Belly", bm, RF_RIME)


def build_rf_fin():
    bm = bmesh.new()
    # The dorsal: a raked sail of clear ice, and the thing you see cutting a
    # wake under the sheet. Rolled 90 so the blade is thin side-to-side and
    # broad fore-and-aft - unrolled, a blade lofted onto +Z comes out facing
    # the wrong way entirely.
    blade(bm, (0, 0, 0), (-4.0, 0, 12.4), 9.6, 1.3, 1.5, roll=math.radians(90))
    # Fracture lines through the ice.
    for i in range(3):
        blade(
            bm,
            (-0.6 - i * 0.9, 0, 1.4 + i * 2.4),
            (-2.2 - i * 0.7, 0, 4.2 + i * 2.2),
            0.5,
            0.3,
            1.25,
            roll=math.radians(90),
        )
    return finish("Rimefang_Fin", bm, RF_ICE)


def build_rf_pec():
    bm = bmesh.new()
    # The paddle: broad at the shoulder, swept back, drooping slightly.
    # Authored pointing +Y so the client (and the preview) makes the other
    # side by a half turn about the body axis - no mirrored normals.
    blade(bm, (0, 0, 0), (-5.2, 11.0, -1.6), 6.2, 2.5, 1.2)
    return finish("Rimefang_Pec", bm, RF_SLATE)


def build_rf_fluke():
    bm = bmesh.new()
    # HORIZONTAL lobes - the single most important thing about a whale's
    # tail. Swept back off a central boss, thin in Z.
    for side in (-1, 1):
        blade(bm, (0, 0, 0), (-4.2, side * 11.2, 0), 6.6, 1.6, 1.05)
    ellipsoid(bm, (0, 0, 0), (2.2, 1.9, 1.4))
    return finish("Rimefang_Fluke", bm, RF_SLATE)


def build_rimefang():
    rng = random.Random(5521)
    objects = [
        build_rf_head(rng),
        build_rf_jaw(rng),
        build_rf_teeth(),
        build_rf_eyes(),
        build_rf_rime(rng),
        build_rf_body(),
        build_rf_belly(),
        build_rf_fin(),
        build_rf_pec(),
        build_rf_fluke(),
    ]
    print("HANDOFF rimefang: head faces +X; neck joint at the origin, snout tip x=+11.0")
    print("HANDOFF rimefang: jaw hinge pivot (%.1f, %.1f, %.1f) - client rotates the jaw about it" % RF_JAW_HINGE)
    print("HANDOFF rimefang: vertebra spacing %.1f studs at scale 1; scale by _rf_girth(u), NOT a linear taper" % RF_SEG_SPACING)
    print("HANDOFF rimefang: Belly rides every vertebra (countershading); Pec is authored +Y, mirror by a half turn about the body axis")
    print("HANDOFF rimefang: Fin base is the dorsal mount, ~3.4 studs above the spine at full girth; Fluke mounts on the tail tip, lobes HORIZONTAL")
    return objects


# ================================================================ pyrelisk
#
# "Pyrelisk, the Ashfall Colossus" - the volcano's boss, and NOT a creature
# in the sense the rest of this file means it. It is a 400-stud obsidian
# giant rooted in the caldera lake of its own arena (arena_gen's Ashfall
# Throne), and the player fights it from the rim path with guns, because the
# lake is a moat it can never be crossed on foot.
#
# ---------------------------------------------------------------- the idea
#
# ARMOUR OVER A MOLTEN INTERIOR. The shell is slabs of cooled volcanic glass
# with GAPS between them, and `Pyrelisk_Core` is a single glowing body
# underneath showing through every gap. Undamaged it is a black mountain;
# every seam broken is a permanent orange scar, so by phase three it is
# visibly coming apart and lit from inside. Nothing about that read needs a
# texture - it is two objects and the space between them.
#
# ---------------------------------------------------------------- contract
#
#   - 1 Blender unit = 1 Roblox stud. Up is Blender +Z -> Roblox +Y.
#   - The body faces +X. LIMB pieces are authored along +X FROM THEIR JOINT
#     (upper arm from the shoulder, forearm from the elbow, hand from the
#     wrist), so the rig aligns each piece's +X with its bone and writes one
#     CFrame per part - the same rule the segment chain uses.
#   - The TORSO is authored standing, its base at z=0, because z=0 is the
#     caldera lake's surface: the arena's rim path is at the same height, so
#     boss-space z and arena-space z are the same number and the rig needs
#     no offset.
#   - MODULES are placed many times by the rig, each authored at the origin
#     with +Z as its OUTWARD SURFACE NORMAL:
#       Seam  the shootable weak point (glow). Also sits inside a Vent's
#             throat, so one module lights both.
#       Vent  the mounted breakable you smash while standing on the boss.
#   - `_Walk*` pieces are the CLIMBABLE ROUTE and the only collidable parts:
#     simple slabs matching the shell's upper surfaces. Everything else is
#     shell - non-collidable, so a 300-stud arm can sweep through the air
#     without physics ever being asked about it (see the fight design: the
#     boss is static while you are on it, and the slabs only move when
#     nobody can be standing on them).
#
# Colours here are preview-only; the client tints each part as it builds it.
# Deterministic: seeded random only, so re-exports are byte-stable.

PY_OBSIDIAN = (0.075, 0.072, 0.088)  # the shell: cooled volcanic glass
PY_BASALT = (0.130, 0.118, 0.130)  # crown columns, claws
PY_MOLTEN = (1.00, 0.28, 0.03)  # the interior, and every broken seam
PY_EMBER = (1.00, 0.62, 0.12)  # eyes
PY_SLAG = (0.095, 0.088, 0.100)  # the walkable decks: near-obsidian, so the climb route is FOOTING, not a plank bolted on

# The rig, and the HANDOFF contract the client's poser is written against.
# Everything below is in boss space: z=0 is the lake surface.
PY_RIG = {
    "shoulder": (0.0, 118.0, 186.0),  # mirrored in y - wide and LOW; the first pass stood them on a column
    "upper_arm": 90.0,
    "forearm": 102.0,
    "hand": 36.0,
    "neck": (20.0, 0.0, 214.0),  # PROUD of the shoulder line: it reads as a head or it reads as more rubble
    "height": 300.0,
}

# Torso cross-sections: (z, radius fore-aft, radius across). A hunched mass -
# broad at the waterline, pinched at the waist, flaring into the shoulders.
PY_TORSO = [
    (-40.0, 52.0, 48.0),
    (0.0, 62.0, 56.0),
    (40.0, 64.0, 58.0),
    (78.0, 60.0, 55.0),
    (112.0, 62.0, 56.0),
    (146.0, 68.0, 60.0),
    (178.0, 72.0, 62.0),
    (202.0, 64.0, 55.0),
]


def _py_ring(bm, z, rx, ry, sides, twist, jitter, rng):
    pts = []
    for i in range(sides):
        a = (i / sides) * TAU + twist
        wobble = 1.0 + rng.uniform(-jitter, jitter)
        pts.append(bm.verts.new((math.cos(a) * rx * wobble, math.sin(a) * ry * wobble, z)))
    return pts


def build_py_core(rng):
    bm = bmesh.new()
    # The molten body. Every gap in the shell shows THIS, so it is a complete
    # form in its own right rather than a glow card: a smooth tapering mass
    # inset ~5 studs inside the plating, running the full height.
    rings = []
    for z, rx, ry in PY_TORSO:
        rings.append(_py_ring(bm, z, rx - 9.0, ry - 9.0, 9, 0.0, 0.02, rng))
    for a, b in zip(rings, rings[1:]):
        for i in range(9):
            j = (i + 1) % 9
            bm.faces.new((a[i], a[j], b[j], b[i]))
    bm.faces.new(list(reversed(rings[0])))
    # Neck and head core: the throat glow the jaw opens onto.
    top = rings[-1]
    bm.faces.new(top)
    ellipsoid(bm, (12.0, 0.0, 196.0), (21.0, 20.0, 19.0), subdiv=1)  # the throat: molten light AT THE NECK, so a dark head reads against it
    return finish("Pyrelisk_Core", bm, PY_MOLTEN)


def _py_chunk(bm, center, radii, rng, jitter=0.30, rot=None):
    """A jittered low-poly boulder - the reference art's whole shape language.

    The first pass built this colossus out of neat rectangular slabs and it
    read as masonry. The references are BROKEN ROCK: irregular convex chunks
    with lava in the gaps between them, so every mass here is one of these.
    """
    verts = []
    mat = Matrix.Translation(Vector(center))
    if rot is not None:
        mat = mat @ rot.to_4x4()
    mat = mat @ Matrix.Diagonal(Vector(radii)).to_4x4()
    result = bmesh.ops.create_icosphere(bm, subdivisions=1, radius=1.0, matrix=mat)
    smallest = min(radii)
    for vert in result["verts"]:
        offset = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1)))
        vert.co += offset * jitter * smallest
        verts.append(vert)
    return verts


def build_py_torso(rng):
    bm = bmesh.new()
    # THE SHELL, as broken rock: rings of boulders stacked into a hunched
    # golem - heavy hips at the lake, a pinched waist, and a chest that
    # widens into shoulder mass twice the head's width. The GAPS between
    # chunks are the design; `Pyrelisk_Core` burns through every one.
    for z, radius, count, size in (
        (-34.0, 50.0, 8, 25.0),  # submerged: the hips, so the body enters the lake instead of ending at it
        (-6.0, 57.0, 9, 27.0),
        (26.0, 59.0, 9, 28.0),
        (60.0, 57.0, 9, 27.0),
        (94.0, 56.0, 9, 27.0),
        (128.0, 59.0, 9, 28.0),
        (158.0, 64.0, 9, 30.0),
        (184.0, 66.0, 9, 30.0),
    ):
        for k in range(count):
            a = (k / count) * TAU + z * 0.021
            _py_chunk(
                bm,
                (math.cos(a) * radius, math.sin(a) * radius, z + rng.uniform(-3.0, 3.0)),
                (size * rng.uniform(0.85, 1.2), size * rng.uniform(0.85, 1.2), size * rng.uniform(0.9, 1.25)),
                rng,
            )
    # The shoulder mass: the golem's whole silhouette. Big boulders piled
    # wide and high, so the head sits DOWN IN a shoulder line rather than on
    # top of a neck - the single strongest read in both references.
    for side in (-1, 1):
        for index, (y, z, size) in enumerate(((62.0, 178.0, 32.0), (86.0, 190.0, 32.0), (104.0, 182.0, 26.0), (80.0, 206.0, 26.0))):
            _py_chunk(
                bm,
                (rng.uniform(-8, 8), side * y, z),
                (size * rng.uniform(0.9, 1.15), size * rng.uniform(0.9, 1.15), size * rng.uniform(0.75, 1.0)),
                rng,
            )
            _ = index
    # A low back ridge of smaller rubble, no spines - the references have no
    # dorsal fin, just more rock.
    for i in range(6):
        t = i / 5
        _py_chunk(bm, (-52.0 + t * 6.0, rng.uniform(-12, 12), 40.0 + t * 130.0), (18.0, 16.0, 15.0), rng)
    return finish("Pyrelisk_Torso", bm, PY_OBSIDIAN)


def build_py_head(rng):
    bm = bmesh.new()
    # A ROCK, not a skull - but ONE rock. The first version was a cluster of
    # chunks the same size as the shoulder rubble around it, so at any real
    # distance the head simply vanished into the body. This is a single
    # dominant mass with a flat face plane and a hard brow over it, sized to
    # beat everything near it.
    _py_chunk(bm, (0.0, 0.0, 2.0), (34.0, 33.0, 31.0), rng, jitter=0.16)
    # Cranium: a lower dome behind, so the profile has a back to it.
    _py_chunk(bm, (-20.0, 0.0, 8.0), (18.0, 22.0, 18.0), rng, jitter=0.20)
    # The brow: a heavy slab thrown forward over the eyes. This is the
    # silhouette line that says "face" from 200 studs out.
    box(bm, (23.0, 0.0, 15.0), (24.0, 52.0, 12.0), Matrix.Rotation(math.radians(-14), 3, "Y"))
    # Jaw corners, squared off, framing a recessed face.
    for side in (-1, 1):
        _py_chunk(bm, (10.0, side * 23.0, -6.0), (15.0, 12.0, 14.0), rng, jitter=0.18)
    # A short thick neck stub - the head sits ON something now.
    _py_chunk(bm, (-6.0, 0.0, -24.0), (16.0, 17.0, 12.0), rng, jitter=0.2)
    return finish("Pyrelisk_Head", bm, PY_OBSIDIAN)


def build_py_jaw(rng):
    bm = bmesh.new()
    # A blunt rock underjaw - it hinges open for the vent-breath and shows
    # the throat. No teeth: these things are broken stone, not animals.
    _py_chunk(bm, (8.0, 0.0, -16.0), (20.0, 20.0, 9.0), rng, jitter=0.22)
    _py_chunk(bm, (20.0, 0.0, -14.0), (13.0, 15.0, 7.0), rng, jitter=0.22)
    return finish("Pyrelisk_Jaw", bm, PY_OBSIDIAN)


def build_py_crown(rng):
    bm = bmesh.new()
    # Short, thick shards standing off the crown and the shoulder line - the
    # reference's pointed head and spiked shoulders. Stubby and rock-like,
    # NOT the raked basalt colonnade this model had first.
    for i in range(3):
        t = i / 2
        side = -1 if i % 2 else 1
        base = Vector((-8.0 - t * 6.0, side * t * 9.0, 22.0))
        spike(bm, tuple(base), tuple(base + Vector((-4.0, side * 3.0, 20.0 + rng.uniform(-5, 7)))), rng.uniform(5.0, 8.0), sides=5)
    return finish("Pyrelisk_Crown", bm, PY_BASALT)


def build_py_eyes():
    bm = bmesh.new()
    # Two slits under the brow. Small - they are the only bright thing on the
    # head, and the references keep them mean.
    for side in (-1, 1):
        box(bm, (19.0, side * 11.0, 3.0), (6.0, 13.0, 5.5), Matrix.Rotation(math.radians(side * 8), 3, "X"))
    return finish("Pyrelisk_Eyes", bm, PY_EMBER)


def build_py_shoulder(rng):
    bm = bmesh.new()
    # The pauldron: a boulder cap over the joint, with a short spike off it.
    _py_chunk(bm, (0.0, 0.0, 4.0), (28.0, 26.0, 24.0), rng, jitter=0.22)
    _py_chunk(bm, (-14.0, 0.0, 10.0), (17.0, 17.0, 15.0), rng, jitter=0.2)
    spike(bm, (-8.0, 0.0, 14.0), (-20.0, 0.0, 40.0), 8.0, sides=5)
    return finish("Pyrelisk_Shoulder", bm, PY_OBSIDIAN)


def _py_limb(bm, length, r0, r1, rng, links):
    """A limb along +X from its joint: a run of boulders, tapering.

    Every chunk is CENTRED ON THE AXIS with symmetric radii. The first pass
    jittered them sideways, which made the left and right arms read as two
    different limbs and made the piece's roll matter to the rig; this way an
    arm looks the same from either side and animating it is one rotation per
    joint.
    """
    for i in range(links):
        t = i / (links - 1)
        r = r0 + (r1 - r0) * t
        _py_chunk(
            bm,
            (t * length, 0.0, 0.0),
            (length / links * 0.80, r, r),
            rng,
            jitter=0.20,
        )


def build_py_upper_arm(rng):
    # Slimmer: the first pass was as thick as the torso. The references hang
    # arms roughly a third of the body's width.
    bm = bmesh.new()
    _py_limb(bm, PY_RIG["upper_arm"], 28.0, 24.0, rng, 4)
    return finish("Pyrelisk_UpperArm", bm, PY_OBSIDIAN)


def build_py_forearm(rng):
    bm = bmesh.new()
    _py_limb(bm, PY_RIG["forearm"], 25.0, 20.0, rng, 4)
    return finish("Pyrelisk_Forearm", bm, PY_OBSIDIAN)


def build_py_hand(rng):
    bm = bmesh.new()
    # A blunt rock FIST, not a claw: the references have mitts. It still has
    # to be a platform when it plants - a 46-stud knuckle deck is what you
    # run up - so the mass goes into the fist rather than into talons.
    _py_chunk(bm, (14.0, 0.0, 0.0), (25.0, 26.0, 21.0), rng, jitter=0.22)
    for i in range(3):
        y = -13.0 + i * 13.0
        _py_chunk(bm, (32.0, y, -3.0), (11.0, 7.0, 9.0), rng, jitter=0.2)
    _py_chunk(bm, (14.0, -20.0, -6.0), (10.0, 9.0, 9.0), rng, jitter=0.2)
    return finish("Pyrelisk_Hand", bm, PY_BASALT)
def build_py_seam():
    bm = bmesh.new()
    # THE WEAK POINT, and it has to read as one from 200 studs away across a
    # dark arena: a glowing wedge sunk in a socket, +Z out of the surface.
    # The rig places it wherever a seam opens, and inside a vent's throat.
    loft(
        bm,
        [
            ring_pts(-3.0, 0.0, 5.0, 5.0, sides=6),
            ring_pts(0.0, 0.0, 8.5, 8.5, sides=6),
            ring_pts(2.5, 0.0, 6.0, 6.0, sides=6),
        ],
    )
    # The crack that runs out of it, so a broken seam scars the plate.
    for i in range(3):
        a = (i / 3) * TAU + 0.4
        spike(bm, (0.0, math.cos(a) * 5.0, math.sin(a) * 5.0), (1.0, math.cos(a) * 17.0, math.sin(a) * 17.0), 1.6, sides=4)
    obj = finish("Pyrelisk_Seam", bm, PY_MOLTEN)
    obj.rotation_euler = (0.0, math.radians(90), 0.0)  # authored along +X; +Z is the surface normal
    return obj


def build_py_vent(rng):
    bm = bmesh.new()
    # THE MOUNTED BREAKABLE: a vent shaft you smash while standing on it.
    # A cracked chimney of stacked collars, throat open to the core - the rig
    # drops a Seam inside it for the glow.
    for i in range(4):
        t = i / 3
        disc(bm, t * 13.0, t * 13.0 + 9.0, 15.0 - t * 3.0, 13.5 - t * 3.0, sides=7)
    for i in range(5):
        a = (i / 5) * TAU + 0.3
        spike(bm, (36.0, math.cos(a) * 9.0, math.sin(a) * 9.0), (50.0 + rng.uniform(-6, 6), math.cos(a) * 13.0, math.sin(a) * 13.0), 3.0, sides=4)
    obj = finish("Pyrelisk_Vent", bm, PY_OBSIDIAN)
    obj.rotation_euler = (0.0, math.radians(-90), 0.0)
    return obj


def build_py_walk_arm():
    bm = bmesh.new()
    # THE RAMP. A plain slab matching the forearm's upper surface, because the
    # climb has to be walkable geometry a humanoid never trips on - and simple
    # boxes are exact where a convex hull of the plated arm would not be.
    box(bm, (PY_RIG["forearm"] * 0.5, 0.0, 11.0), (PY_RIG["forearm"] + 16.0, 26.0, 4.0))
    return finish("Pyrelisk_WalkArm", bm, PY_SLAG)


def build_py_walk_deck():
    bm = bmesh.new()
    # The shoulder deck and the spine walk between them: where the mounted
    # phase actually happens.
    box(bm, (-26.0, 0.0, 196.0), (54.0, 170.0, 4.0))
    box(bm, (-48.0, 0.0, 172.0), (32.0, 88.0, 4.0))
    return finish("Pyrelisk_WalkDeck", bm, PY_SLAG)


def build_pyrelisk():
    rng = random.Random(4409)
    objects = [
        build_py_core(rng),
        build_py_torso(rng),
        build_py_head(rng),
        build_py_jaw(rng),
        build_py_crown(rng),
        build_py_eyes(),
        build_py_shoulder(rng),
        build_py_upper_arm(rng),
        build_py_forearm(rng),
        build_py_hand(rng),
        build_py_seam(),
        build_py_vent(rng),
        build_py_walk_arm(),
        build_py_walk_deck(),
    ]
    print("HANDOFF pyrelisk: torso base z=0 IS the caldera lake surface - boss z and arena z are the same number")
    print("HANDOFF pyrelisk: shoulder joint (%.0f, +/-%.0f, %.0f); upper arm %.0f, forearm %.0f, hand %.0f - reach %.0f from the shoulder"
          % (PY_RIG["shoulder"][0], PY_RIG["shoulder"][1], PY_RIG["shoulder"][2], PY_RIG["upper_arm"], PY_RIG["forearm"], PY_RIG["hand"],
             PY_RIG["upper_arm"] + PY_RIG["forearm"] + PY_RIG["hand"]))
    print("HANDOFF pyrelisk: neck joint (%.0f, %.0f, %.0f); head faces +X, snout tip x=+64" % PY_RIG["neck"])
    print("HANDOFF pyrelisk: Seam and Vent are MODULES - authored at the origin, +Z is the outward surface normal, placed many times by the rig")
    print("HANDOFF pyrelisk: _Walk* are the ONLY collidable parts (the climb route); every shell piece is non-collide")
    return objects


# ---------------------------------------------------------------- the pose
#
# Assembling the pieces the way the client's rig will: one CFrame per part,
# limbs walked joint to joint. This IS the spec for that rig - if the preview
# assembles, the numbers are right.

# Where seams open. Boss space, each (position, outward normal). The fight
# opens a subset per attack and closes them on recovery; the rig reads this
# table, so the art and the hitboxes can never drift apart.
PY_SEAM_SITES = [
    ((62.0, 0.0, 156.0), (1.0, 0.0, 0.2)),  # chest, dead centre - the phase-3 core
    ((46.0, 44.0, 128.0), (0.7, 0.7, 0.1)),
    ((46.0, -44.0, 128.0), (0.7, -0.7, 0.1)),
    ((-6.0, 58.0, 92.0), (0.0, 1.0, 0.1)),
    ((-6.0, -58.0, 92.0), (0.0, -1.0, 0.1)),
    ((16.0, 56.0, 40.0), (0.4, 0.9, 0.0)),
    ((16.0, -56.0, 40.0), (0.4, -0.9, 0.0)),
]
# Vent shafts on the back and shoulders: the mounted breakables.
PY_VENT_SITES = [
    ((-30.0, 0.0, 200.0), (0.0, 0.0, 1.0)),
    ((-16.0, 66.0, 198.0), (-0.3, 0.6, 0.75)),
    ((-16.0, -66.0, 198.0), (-0.3, -0.6, 0.75)),
]


def _py_copy(source, matrix):
    copy = source.copy()
    copy.data = source.data
    copy.hide_render = False
    bpy.context.collection.objects.link(copy)
    copy.matrix_world = matrix
    return copy


def _py_aim(origin, direction):
    """A transform putting a limb piece's +X along `direction` from `origin`."""
    rot = Vector((1, 0, 0)).rotation_difference(Vector(direction).normalized()).to_matrix().to_4x4()
    return Matrix.Translation(Vector(origin)) @ rot


def _py_surface(position, normal):
    """A module's transform: +Z along the outward surface normal."""
    rot = Vector((0, 0, 1)).rotation_difference(Vector(normal).normalized()).to_matrix().to_4x4()
    return Matrix.Translation(Vector(position)) @ rot


def _py_arm(parts, made, side, elbow_dir, wrist_dir, hand_dir, walk=False):
    """One arm, walked joint to joint - exactly what the client rig does."""
    sx, sy, sz = PY_RIG["shoulder"]
    shoulder = Vector((sx, side * sy, sz))
    made.append(_py_copy(parts["Shoulder"], _py_aim(shoulder, (0.0, side * 1.0, 0.0))))
    elbow_dir = Vector((elbow_dir[0], side * elbow_dir[1], elbow_dir[2]))
    made.append(_py_copy(parts["UpperArm"], _py_aim(shoulder, elbow_dir)))
    elbow = shoulder + elbow_dir.normalized() * PY_RIG["upper_arm"]
    wrist_dir = Vector((wrist_dir[0], side * wrist_dir[1], wrist_dir[2]))
    made.append(_py_copy(parts["Forearm"], _py_aim(elbow, wrist_dir)))
    if walk:
        made.append(_py_copy(parts["WalkArm"], _py_aim(elbow, wrist_dir)))
    wrist = elbow + wrist_dir.normalized() * PY_RIG["forearm"]
    hand_dir = Vector((hand_dir[0], side * hand_dir[1], hand_dir[2]))
    made.append(_py_copy(parts["Hand"], _py_aim(wrist, hand_dir)))
    return wrist + hand_dir.normalized() * PY_RIG["hand"]


def _place_pyrelisk(objects, planted_side=None, head_yaw=0.0):
    """Stand the colossus up. `planted_side` drops that arm onto the rim path
    (the stagger pose - the arm is the ramp); the other arm stays raised."""
    parts = {obj.name.split("_", 1)[1]: obj for obj in objects}
    made = []
    for name in ("Core", "Torso", "WalkDeck"):
        made.append(_py_copy(parts[name], Matrix.Identity(4)))
    neck = Vector(PY_RIG["neck"])
    head = Matrix.Translation(neck) @ Matrix.Rotation(head_yaw, 4, "Z") @ Matrix.Rotation(math.radians(-8), 4, "Y")
    for name in ("Head", "Jaw", "Crown", "Eyes"):
        made.append(_py_copy(parts[name], head))
    for side in (-1, 1):
        if planted_side == side:
            # Planted: the forearm lies along the ground as the ramp, and the
            # walk slab rides with it.
            _py_arm(parts, made, side, (0.28, 0.62, -0.73), (0.24, 0.40, -0.88), (0.62, 0.20, -0.12), walk=True)
        else:
            _py_arm(parts, made, side, (0.34, 0.24, -0.91), (0.30, 0.10, -0.95), (0.45, 0.05, -0.89))
    # The maw: the same Seam module, seated in the throat behind the jaw, so
    # an open mouth glows without the core ever poking through the skull.
    made.append(_py_copy(parts["Seam"], head @ _py_surface((18.0, 0.0, -10.0), (1.0, 0.0, -0.3))))
    for position, normal in PY_SEAM_SITES:
        made.append(_py_copy(parts["Seam"], _py_surface(position, normal)))
    for position, normal in PY_VENT_SITES:
        made.append(_py_copy(parts["Vent"], _py_surface(position, normal)))
        made.append(_py_copy(parts["Seam"], _py_surface(
            (position[0] + normal[0] * 21.0, position[1] + normal[1] * 21.0, position[2] + normal[2] * 21.0), normal)))
    print("POSE: %d parts placed (%d seams, %d vents)" % (len(made), len(PY_SEAM_SITES) + len(PY_VENT_SITES), len(PY_VENT_SITES)))
    return made


def _stage_pyrelisk(path_out, objects):
    """The colossus rooted in its own caldera, one arm planted on the rim path.

    Imports arena_gen so the crater under it is the REAL one, and ASSERTS the
    arm can actually reach the path - if either file's radii move, this fails
    loudly instead of shipping a boss that cannot touch its own arena.
    """
    import os

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import arena_gen  # noqa: E402  (guarded: importing it builds nothing)

    sx, sy, sz = PY_RIG["shoulder"]
    reach = PY_RIG["upper_arm"] + PY_RIG["forearm"] + PY_RIG["hand"]
    # Furthest the hand can plant on the ground, measured from the body's axis.
    span = sy + math.sqrt(max(reach**2 - sz**2, 0.0))
    if not (arena_gen.PY_LAKE_R < span):
        raise SystemExit(
            "STAGED ABORT: reach %.0f from shoulder z%.0f spans only r%.0f - the lake is r%.0f, "
            "so the arm cannot bridge the moat" % (reach, sz, span, arena_gen.PY_LAKE_R)
        )
    print("STAGE: hand plants out to r%.0f; lake r%.0f, rim path r%.0f..%.0f"
          % (span, arena_gen.PY_LAKE_R, arena_gen.PY_LAKE_R, arena_gen.PY_PATH_R))
    arena_gen.build_pyrelisk()
    for obj in objects:
        obj.hide_render = True
    _place_pyrelisk(objects, planted_side=-1, head_yaw=math.radians(-24))

    # The summit's own light: a warm low key through ash, and a real fill so
    # near-black glass keeps its facets instead of going to one silhouette.
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.rotation_euler = (math.radians(48), 0, math.radians(38))
    sun.data.energy = 2.4
    bpy.context.collection.objects.link(sun)
    fill = bpy.data.objects.new("Fill", bpy.data.lights.new("Fill", "SUN"))
    fill.rotation_euler = (math.radians(66), 0, math.radians(-132))
    fill.data.energy = 0.55
    bpy.context.collection.objects.link(fill)

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1500
    scene.render.resolution_y = 1000
    scene.world = bpy.data.worlds.new("World")
    scene.world.use_nodes = True
    bg = scene.world.node_tree.nodes.get("Background")
    if bg:
        bg.inputs[0].default_value = (0.415, 0.360, 0.330, 1.0)

    for suffix, location, target, lens in (
        # The whole thing in its arena, from outside the crater.
        ("", (620.0, -790.0, 250.0), (0.0, 0.0, 110.0), 40),
        # THE PLAYER'S ANGLE: the fight camera on the rim path, 22 up, looking
        # at what it is standing under. The planted arm comes down on this
        # side - this is the shot that has to sell "climb that".
        ("_fight", (-186.0, -196.0, 26.0), (-20.0, -30.0, 130.0), 24),
        # The head, close: it either reads as a head here or it does not.
        ("_head", (176.0, -108.0, 238.0), (12.0, 0.0, 208.0), 52),
    ):
        cam_data = bpy.data.cameras.new("Cam" + suffix)
        cam_data.lens = lens
        cam_data.clip_end = 20000.0
        cam = bpy.data.objects.new("Cam" + suffix, cam_data)
        cam.location = Vector(location)
        cam.rotation_euler = (Vector(target) - cam.location).to_track_quat("-Z", "Y").to_euler()
        bpy.context.collection.objects.link(cam)
        scene.camera = cam
        out = path_out if not suffix else path_out.replace("_staged.png", "_staged%s.png" % suffix)
        scene.render.filepath = out
        bpy.ops.render.render(write_still=True)
        print("BOSS STAGED:", out)


BOSSES = {
    "brinejaw": build_brinejaw,
    "kraken": build_kraken,
    "gnashroot": build_gnashroot,
    "noctyss": build_noctyss,
    "rimefang": build_rimefang,
    "pyrelisk": build_pyrelisk,
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


# The rest of the pose vocabulary, ported from the SHIPPED math in
# src/Shared/Modules/BrinejawPath.luau so a render can show any fight state,
# not just the idle one. Keeping the two in step matters: these images are
# how an attack gets reviewed before anyone can play it, and a render that
# quietly disagreed with the game would be worse than no render. The Luau is
# the source of truth; if you change one, change both.
#
# Roblox is Y-up and Blender is Z-up, so the mapping throughout is
# Luau (x, y, z) -> Blender (x, z, y): the helix is the same circle, and
# "height" moves from the Luau's Y to Blender's Z.

BJ_SWEEP_REACH = 66.0
BJ_SWEEP_INNER = 13.0
BJ_SWEEP_LOW = 1.6
BJ_SWEEP_HIGH = 5.4
BJ_MAX_COIL = 3
BJ_COIL_DROP = (BJ_REST["top_z"] - BJ_REST["bottom_z"]) / BJ_REST["turns"]


def _bj_sand_z(r):
    """The beach's height at radius r (arena_gen's BJ_PROFILE)."""
    profile = ((0, 3.2), (10, 3.0), (16, 2.2), (30, 1.6), (48, 1.4), (62, 1.0), (70, 0.4))
    for a, b in zip(profile, profile[1:]):
        if r <= b[0]:
            t = max(0.0, min(1.0, (r - a[0]) / (b[0] - a[0])))
            return a[1] + (b[1] - a[1]) * t
    return 0.4


def _smoothstep(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3 - 2 * x)


def bj_state(**overrides):
    """A pose state: what the server publishes, in one dict."""
    state = {
        "coil": BJ_MAX_COIL,
        "unwind": 0.0,
        "sweep_angle": 0.0,
        "sweep_height": BJ_SWEEP_LOW,
        "slump": 0.0,
        "face_angle": BJ_REST["bearing"] - 0.8,
        "time": 0.0,
    }
    state.update(overrides)
    return state


def _bj_rest_path(t, state=None):
    """Head (t=0) to rattle (t=1) in arena-local space, waterline at z=0."""
    rest = BJ_REST
    state = state or bj_state()
    drop = (BJ_MAX_COIL - state["coil"]) * BJ_COIL_DROP
    neck_end, helix_end = rest["neck_end"], rest["helix_end"]

    def helix(k):
        z = (rest["top_z"] - drop) + ((rest["bottom_z"] - drop) - (rest["top_z"] - drop)) * k
        theta = rest["bearing"] + rest["turns"] * TAU * k
        r = _spire_radius(z) + rest["clearance"]
        return Vector((math.cos(theta) * r, math.sin(theta) * r, z))

    if t <= neck_end:
        # A quadratic sweep from the reared neck down onto the top coil.
        u = t / neck_end
        theta = rest["bearing"] - 0.8
        head_z = rest["head_z"] - drop
        r = _spire_radius(head_z) + rest["clearance"] + rest["head_out"]
        top = Vector((math.cos(theta) * r, math.sin(theta) * r, head_z))
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
    inner = _spire_radius(rest["bottom_z"] - drop) + rest["clearance"]
    theta = rest["bearing"] + rest["turns"] * TAU + rest["tail_turn"] * TAU * k
    r = inner + (rest["tail_out"] - inner) * k**0.75
    z = (rest["bottom_z"] - drop) + (rest["tail_z"] - (rest["bottom_z"] - drop)) * k**0.6
    return Vector((math.cos(theta) * r, math.sin(theta) * r, z))


def _bj_swept_point(state, t, blend_start):
    """The tail laid out along one bearing at sweep height - the arm."""
    k = max(0.0, min(1.0, (t - blend_start) / max(1 - blend_start, 1e-3)))
    r = BJ_SWEEP_INNER + (BJ_SWEEP_REACH - BJ_SWEEP_INNER) * k
    theta = state["sweep_angle"]
    return Vector((math.cos(theta) * r, math.sin(theta) * r, _bj_sand_z(r) + state["sweep_height"]))


def _bj_slump_point(state, t):
    """Where the head goes when it loses its grip: down, onto the sand."""
    rest = BJ_REST
    drop = (BJ_MAX_COIL - state["coil"]) * BJ_COIL_DROP
    theta = state["face_angle"]
    reach = 26.0
    k = max(0.0, min(1.0, t / 0.30))
    bottom = rest["bottom_z"] - drop
    r = reach - (reach - (_spire_radius(bottom) + rest["clearance"])) * k
    return Vector((math.cos(theta) * r, math.sin(theta) * r, _bj_sand_z(r) + 2.6 + 9.0 * k**1.5))


def bj_pose_path(state):
    """A path function for any fight state - the Luau's pointAt, in Blender."""

    def path(t):
        t = max(0.0, min(1.0, t))
        point = _bj_rest_path(t, state)

        unwind = state["unwind"]
        if unwind > 0:
            blend_start = 1.0 - 0.40 * unwind
            w = _smoothstep((t - blend_start) / 0.14) * unwind
            if w > 0:
                point = point.lerp(_bj_swept_point(state, t, blend_start), w)

        slump = state["slump"]
        if slump > 0 and t < 0.34:
            point = point.lerp(_bj_slump_point(state, t), _smoothstep((0.34 - t) / 0.34) * slump)

        # Mirrors BrinejawPath: amplitude grows toward the tail so the body
        # whips rather than wobbling, and the last tenth flicks sideways so
        # the rattle - the only hittable part - draws the eye.
        breath = math.sin(t * 9.0 - state["time"] * 1.7) * (0.45 + 1.05 * t * t)
        point = point + Vector((0, 0, breath))
        if t > 0.86:
            k = (t - 0.86) / 0.14
            flat = Vector((point.x, point.y, 0.0))
            if flat.length > 0.01:
                side = Vector((-flat.y, flat.x, 0.0)).normalized()
                point = point + side * (math.sin(state["time"] * 5.1 + t * 3.0) * 1.7 * k * k)
        return point

    return path


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
    """One arm at REST: out of its socket on the crown, sprawling outward over
    the water, tip curling back down. t=0 at the socket. This is the shape
    ChainPose blends away from for a lash and back to afterwards."""
    # LONG and high: 82 studs of reach against a 19.8 half-width head - the
    # 4:1 an octopus actually has, where the first pass was under 2:1 and the
    # arms read as stubs.
    #
    # TWO RULES KEEP THE FACE CLEAR, which a bare arch does not. First, an arm
    # leaves the crown going DOWN - out from under the mantle skirt - and only
    # starts climbing once it is well outside the head's footprint. Second,
    # how high it climbs depends on WHERE IT SITS: the arms at the front stay
    # low and reach along the water, and only the flank and rear arms rear up.
    # Eight identical arches put two of them straight across the eyes.
    front = math.cos(angle)
    crest = 40.0 * (0.24 + 0.76 * (1.0 - max(front, 0.0)))
    climb = max((t - 0.16) / 0.84, 0.0)
    r = 18.2 + 64.0 * t
    z = (-2.0
         - 13.0 * math.sin(min(t / 0.16, 1.0) * math.pi * 0.5) ** 2
         + math.sin(climb * math.pi * 0.92) * crest
         - t * 8.0)
    a = angle + math.sin(t * math.pi * 1.15) * 0.30
    return Vector((math.cos(a) * r, math.sin(a) * r, z))


def _place_kraken(objects, arms=8):
    """The head at the centre with eight arms sprawling off the crown - the
    silhouette judged as one animal, which is the only way to tell whether an
    arm reads as a limb or as a string of blocks."""
    by_name = {obj.name.split("_", 1)[1]: obj for obj in objects}
    made = []

    def place(source, position, tangent=None, scale=1.0, length=None):
        copy = source.copy()
        copy.data = source.data
        copy.hide_render = False
        bpy.context.collection.objects.link(copy)
        copy.location = position
        if tangent is not None:
            copy.rotation_euler = Vector((1, 0, 0)).rotation_difference(tangent).to_euler()
        # Length (+X) and girth scale SEPARATELY. Scaling a segment uniformly
        # shortens it too, and once it is shorter than KR_ARM_SPACING the
        # barrels stop overlapping and the arm ribs up - worst at the tip,
        # where the taper is deepest. So the arm thins hard and shortens
        # barely, and every joint keeps its overlap.
        copy.scale = (length if length is not None else scale, scale, scale)
        made.append(copy)
        return copy

    for part in ("Head", "Crown", "Crust", "Eyes", "Pupil", "Beak"):
        place(by_name[part], Vector((0, 0, 0)))

    seg, tip, sucker = by_name["ArmSeg"], by_name["ArmTip"], by_name["Sucker"]
    for k in range(arms):
        angle = (k / arms) * TAU + 0.20
        at_length, tangent_at, total = _arc_walker(lambda t, a=angle: _kraken_arm_path(a, t))
        count = max(int(total / KR_ARM_SPACING), 3)
        for i in range(count):
            distance = i * KR_ARM_SPACING
            u = distance / total
            scale = 1.0 - 0.52 * u ** 1.10  # heavy at the shoulder, fine at the tip
            length = 1.0 - 0.16 * u  # barely: see place()
            position = at_length(distance)
            tangent = tangent_at(distance)
            place(seg, position, tangent, scale, length)
            # ONE sucker row along the UNDERSIDE, on a guarded frame (an arm
            # mid-whip points straight up, where a naive cross degenerates).
            up = Vector((0, 0, 1))
            if abs(tangent.dot(up)) > 0.98:
                up = Vector((0, 1, 0))
            lateral = tangent.cross(up).normalized()
            down = lateral.cross(tangent).normalized()
            if down.z > 0:
                down = -down
            if u < 0.93:
                # Seated on the hide and pointing OUT of it. Handing `tangent`
                # here laid each disc along the arm instead, edge-on and
                # invisible - the bug that made the suckers vanish.
                seat = position + down * (3.70 * scale)
                place(sucker, seat, down, scale)
        place(tip, at_length(total - 2.0), tangent_at(total - 2.0), 1.0 - 0.52)
    return made


def _gn_limb_path(angle, t, reach=27.0, lift=7.0):
    """One limb at its REST POSE: out of the peat beside the hump, arcing up
    over the bank, claw planted on the ground well out toward the stumps.
    t=0 at the shoulder. This is the shape ChainPose blends AWAY from for a
    rootwave or a slam and back to afterwards - the rest pose is the spec."""
    r = 8.0 + reach * t
    # Up out of the mere, over the bank, tip back down into the peat.
    z = math.sin(t * math.pi * 0.95) * lift - 1.2
    a = angle + math.sin(t * 1.9 + angle) * 0.13
    return Vector((math.cos(a) * r, math.sin(a) * r, z))


def _place_gnashroot(objects, scale=1.0):
    """The colossus at rest: body half-sunk at the origin, four limbs planted
    around it, so the silhouette can be judged as one animal. `scale` lets the
    staged render show it at the creature row's 1.5 against its real arena."""
    by_name = {obj.name.split("_", 1)[1]: obj for obj in objects}
    made = []

    def place(source, position, tangent=None, size=1.0):
        copy = source.copy()
        copy.data = source.data
        copy.hide_render = False  # sources are hidden; their copies are the shot
        bpy.context.collection.objects.link(copy)
        copy.location = position
        if tangent is not None:
            copy.rotation_euler = Vector((1, 0, 0)).rotation_difference(tangent).to_euler()
        copy.scale = (size, size, size)
        made.append(copy)
        return copy

    # The body is ONE CFrame - every piece was authored in the same space.
    for part in ("Back", "Bark", "Tree", "Shelf", "Head", "HeadBone", "Jaw", "JawBone", "Eyes", "Maw"):
        place(by_name[part], Vector((0, 0, 0)), None, scale)

    seg, knot, claw = by_name["Arm"], by_name["ArmKnot"], by_name["Claw"]
    # Four limbs, set like a gator's legs rather than a radial ring: the front
    # pair flanks the skull, the rear pair braces beside the hump.
    # (bearing, reach, lift) per limb - one stretched out ahead, one drawn
    # in and arched high, so the rest pose reads as an animal at rest rather
    # than a specimen pinned out.
    for k, (degrees, reach, lift) in enumerate(
        ((52.0, 26.0, 7.5), (-52.0, 31.0, 5.2), (133.0, 22.0, 8.6), (-133.0, 28.0, 6.2))
    ):
        angle = math.radians(degrees)
        at_length, tangent_at, total = _arc_walker(
            lambda t, a=angle, rr=reach, ll=lift: _gn_limb_path(a, t, rr, ll)
        )
        step = GN_ARM_SPACING * 0.88  # slight overlap so the limb reads continuous
        count = max(int(total / step) + 1, 3)
        for i in range(count):
            distance = min(i * step, total)
            u = distance / total
            taper = 1.0 - 0.42 * u ** 1.15
            source = knot if i % 3 == 2 else seg
            place(source, at_length(distance) * scale, tangent_at(distance), taper * scale)
        # Seated INTO the last vertebra: the claw's attach is at +X, so
        # placing it on the path's end alone leaves it hanging past the tip.
        tip_taper = (1.0 - 0.42) * scale
        place(claw, (at_length(total) + tangent_at(total) * 1.5 * tip_taper) * scale, tangent_at(total), tip_taper)
        _ = k
    return made


# ---------------------------------------------------------------- noctyss rest pose
#
# WHERE THE CHOIR STANDS WHEN NOTHING IS HAPPENING: seven stalks up out of
# the Choirfloor's sockets, leaning in over the pit, breathing their light in
# unison - and one of them, every cycle, breathing OFF that rhythm. This is
# the SPEC the client's ChainPose shape reproduces; the staged render is how
# we check it against the real arena.
#
# Every attack is a blend away from this shape and back: a lightsweep leans
# one stalk into its bearing, a strobe is the bulbs alone, a dead stalk drops
# `height` to nothing over a second and leaves the root behind. The maw is
# not a chain at all - it is this pose's opposite number, a single eased
# translation up through the pit with the jaw hinging open at the top of it.

NC_SOCKET_R = 34.0  # MIRRORS arena_gen.GL_SOCKETS - the staged render asserts they agree
NC_SOCKETS = [(NC_SOCKET_R, 12.0 + i * (360.0 / 7.0)) for i in range(7)]

# How far a leaning stalk pushes its lantern toward what it is aiming at
# (NoctyssPath.LEAN_REACH): far enough that a swept beam visibly comes FROM a
# stalk you could have shot.
NC_LEAN_REACH = 9.0

# NoctyssPath.SWAY / .IMPULSE, mirrored. There is no rig in this game: the
# choir's ambient life and every recoil in the fight are these numbers.
NC_SWAY = {"period": 5.2, "amplitude": 2.4, "breath_period": 3.4, "breath": 0.9}
NC_IMPULSE = {"decay": 5.5, "freq": 13.0, "reach": 3.4, "duration": 1.6}

NC_REST = {
    "height": 33.0,  # root to the top of the rise
    "crook": 11.0,  # studs the top arcs INWARD over the pit - the angler's illicium
    "bow": 2.6,  # a lazy S, alternating around the ring
    "root_z": 2.2,  # the root sits down in the socket collar
}

# The punish window: where the maw ends up when it has finished rising.
NC_MAW = {
    "pitch": 26.0,  # nose-up out of the pit; shallow enough that the scoop is standable
    # 284 degrees: she surfaces facing one of the SIX GAPS between the arena's
    # shadow fins, not into a fin. A colossus that rose facing a rock would be
    # the arena fighting its own boss, and the party arrives down these lanes.
    "yaw": 284.0,
    "gape": 44.0,  # degrees the jaw hinges open
    "origin_z": 4.2,  # the skull's authored origin, relative to the waterline
    # 2.4, not the row's current 1.8: at 1.8 she is a crocodile in a hole, and
    # the whole design rests on her being the thing the shelf was built over.
    # At 2.4 the skull is 28.8 studs across against a 30-stud pit mouth - she
    # FILLS it, jaws overhanging the lip, without clipping the rim slabs. The
    # data slice moves Creatures.noctyss body.scale to match (hitRadius 6 then
    # reads as 14.4 studs of hide, which is what the eye sees).
    "scale": 2.4,
}
NC_STALK_SCALE = 1.0


def nc_state(**overrides):
    """A pose state: what the server publishes, in one dict.

    Mirrors NoctyssPath.newState - and the shape function below mirrors
    NoctyssPath's stalkCurve line for line. The LUAU IS THE SOURCE OF TRUTH;
    if you change one, change both, because these renders are how an attack
    gets reviewed before anyone can play it and a render that quietly
    disagreed with the game would be worse than no render at all.

    Bearings here are in AUTHORED space (arena_gen's degrees). The Luau
    negates them on the way in - Blender +Y exports as Roblox -Z - so a
    reader comparing the two files should expect exactly that one sign.
    """
    stalks = []
    for i in range(len(NC_SOCKETS)):
        stalks.append(
        {
        "alive": True,
        "lean": 0.0,
        "beam": math.radians(NC_SOCKETS[i][1]),
        "douse": 0.0,
        "fall": 0.0,
        "kick": 0.0,  # flinch strength, as NoctyssPath.flinch sets it
        "kick_age": 0.0,  # seconds since it landed
        }
    )
    state = {
        "stalks": stalks,
        "true_lure": 1,
        "maw_rise": 0.0,
        "maw_gape": 0.0,
        # `time` drives the ambient sway and breath, and `kick`/`kick_dir` the
        # flinch - all three mirror NoctyssPath's motion layer. At time 0 with
        # no kick the ambient terms are exactly zero, which is why every pose
        # render below is still a faithful picture of the rest shape.
        "time": 0.0,
    }
    state.update(overrides)
    return state


def _nc_smoothstep(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3 - 2 * x)


def _nc_stalk_path(index, t, state=None):
    """One stalk, root (t=0) to hood (t=1) - NoctyssPath.stalkCurve."""
    state = state or nc_state()
    stalk = state["stalks"][index]
    radius, degrees = NC_SOCKETS[index]
    angle = math.radians(degrees)
    inward = Vector((-math.cos(angle), -math.sin(angle), 0.0))
    lateral = Vector((-inward.y, inward.x, 0.0))
    root = Vector((math.cos(angle) * radius, math.sin(angle) * radius, NC_REST["root_z"]))

    fall = _nc_smoothstep(stalk["fall"])
    height = NC_REST["height"] * (1 - 0.82 * fall)
    bow = NC_REST["bow"] if index % 2 else -NC_REST["bow"]

    # Ambient + flinch, mirroring NoctyssPath's motion layer line for line.
    clock = state.get("time", 0.0)
    phase = index * 1.7
    calm = (1 - fall) * (1 - 0.7 * _nc_smoothstep(stalk["lean"]))
    sway = math.sin(clock / NC_SWAY["period"] * TAU + phase) * NC_SWAY["amplitude"] * calm
    breath = math.sin(clock / NC_SWAY["breath_period"] * TAU + phase * 0.6) * NC_SWAY["breath"] * calm
    kick = 0.0
    age = stalk.get("kick_age", 0.0)
    if stalk.get("kick") and 0 <= age < NC_IMPULSE["duration"]:
        kick = (
            stalk["kick"]
            * math.exp(-age * NC_IMPULSE["decay"])
            * math.sin(age * NC_IMPULSE["freq"])
            * NC_IMPULSE["reach"]
        )

    rest_tip = inward * NC_REST["crook"] + lateral * (bow * 0.6)
    aim = Vector((math.cos(stalk["beam"]), math.sin(stalk["beam"]), 0.0))
    lean_tip = aim * (NC_REST["crook"] + NC_LEAN_REACH)
    lean = _nc_smoothstep(stalk["lean"])
    tip = rest_tip.lerp(lean_tip, lean) + aim * (28.0 * fall)

    p0 = root
    p1 = root + Vector((0, 0, height + breath * 0.4)) + lateral * (bow + sway * 0.35)
    p2 = root + Vector((0, 0, height * 0.93 - 26.0 * fall + breath)) + tip + lateral * sway + aim * kick
    inv = 1 - t
    return p0 * (inv * inv) + p1 * (2 * inv * t) + p2 * (t * t)


def _place_pieces(sources, matrix):
    """Copy each source object and drop it on one world matrix."""
    made = []
    for source in sources:
        copy = source.copy()
        copy.data = source.data
        copy.hide_render = False
        bpy.context.collection.objects.link(copy)
        copy.matrix_world = matrix
        made.append(copy)
    return made


def _place_stalk(by_name, path_fn, scale=NC_STALK_SCALE):
    """Instance one stalk up its path - the job ChainPose does every frame."""
    made = []
    at_length, backward_at, total = _arc_walker(path_fn)

    # _arc_walker's tangent points HEAD-ward - back along the path - because
    # Brinejaw's chain is ordered head-first and its segments' +X must point
    # up-body toward the skull. A stalk is ordered the other way (t=0 at the
    # root), so the same convention needs the opposite sign: +X up-stalk
    # toward the hood. Without this the hood faces back down its own stalk
    # and the lantern hangs above the crown instead of under it.
    def tangent_at(distance):
        return -backward_at(distance)

    step = NC_SEG_SPACING * 0.86 * scale
    count = max(int(total / step), 2)
    for i in range(count):
        distance = i * step
        u = distance / total
        # Thick at the root, thin under the hood.
        seg_scale = scale * (1.0 - 0.34 * u ** 1.1)
        source = by_name["StalkFin"] if i % 3 == 1 else by_name["StalkSeg"]
        made += _place_pieces(
            [source],
            Matrix.Translation(at_length(distance))
            @ Vector((1, 0, 0)).rotation_difference(tangent_at(distance)).to_matrix().to_4x4()
            @ Matrix.Diagonal((seg_scale,) * 3).to_4x4(),
        )
    # The root, sunk in its socket, and the hood with everything that rides it.
    made += _place_pieces(
        [by_name["StalkRoot"]],
        Matrix.Translation(at_length(0.0))
        @ Vector((1, 0, 0)).rotation_difference(tangent_at(0.0)).to_matrix().to_4x4()
        @ Matrix.Diagonal((scale,) * 3).to_4x4(),
    )
    hood_scale = scale * 0.86
    hood_matrix = (
        Matrix.Translation(at_length(total))
        @ Vector((1, 0, 0)).rotation_difference(tangent_at(total)).to_matrix().to_4x4()
        @ Matrix.Diagonal((hood_scale,) * 3).to_4x4()
    )
    made += _place_pieces([by_name[name] for name in ("StalkHood", "StalkCage", "StalkBulb", "StalkBarbs")], hood_matrix)
    # The hood's matrix is what the lantern hangs off: bulb world position is
    # hood_matrix @ NC_BULB, which is where the client parents the light too.
    return made, hood_matrix


def _place_maw(by_name, at, pitch_deg, yaw_deg, gape_deg, scale):
    """The maw, risen and gaping. Skull and jaw are two CFrames, and the jaw's
    is the skull's turned about the authored hinge - exactly what the client
    does, so the render cannot flatter a pose the game cannot hold."""
    pitch, yaw = math.radians(pitch_deg), math.radians(yaw_deg)
    forward = Vector((math.cos(pitch) * math.cos(yaw), math.cos(pitch) * math.sin(yaw), math.sin(pitch)))
    base = (
        Matrix.Translation(Vector(at))
        @ Vector((1, 0, 0)).rotation_difference(forward).to_matrix().to_4x4()
        @ Matrix.Diagonal((scale,) * 3).to_4x4()
    )
    hinge = Vector(NC_JAW_HINGE)
    gape = (
        Matrix.Translation(hinge)
        @ Matrix.Rotation(math.radians(gape_deg), 4, "Y")
        @ Matrix.Translation(-hinge)
    )
    made = _place_pieces([by_name[n] for n in ("Skull", "SkullBone", "Eyes", "Gullet")], base)
    made += _place_pieces([by_name[n] for n in ("Jaw", "JawBone", "Barbels")], base @ gape)
    return made


def _place_noctyss(objects):
    """The parts-sheet replacement: one stalk stood up beside the maw, so both
    halves of the pack read as creatures rather than components."""
    by_name = {obj.name.split("_", 1)[1]: obj for obj in objects}
    def one_stalk(t):
        p0 = Vector((0, 0, 0))
        p1 = Vector((0, 0, NC_REST["height"]))
        p2 = Vector((NC_REST["crook"], 0, NC_REST["height"] * 0.93))
        return p0 * (1 - t) ** 2 + p1 * (2 * (1 - t) * t) + p2 * (t ** 2)

    made, _ = _place_stalk(by_name, one_stalk)
    made += _place_maw(by_name, (-34.0, 0.0, 12.0), 12.0, 20.0, 40.0, 1.0)
    return made


def _lantern(at, energy, colour, radius=1.6):
    """A point light where a lure hangs. The choir IS the arena's lighting -
    a render lit only by the sun would show a shape the player never sees."""
    data = bpy.data.lights.new("Lantern", "POINT")
    data.energy = energy
    data.color = colour
    data.shadow_soft_size = radius
    light = bpy.data.objects.new("Lantern", data)
    light.location = at
    bpy.context.collection.objects.link(light)


def _emissive(objects, pieces, colour, strength):
    """Make the lures actually EMIT for the render.

    Only the staged shot needs this (it runs after the export, so the glb is
    untouched): in game these two meshes are Neon with a PointLight parented
    to them, and a render that showed them as flat pale plastic would be
    judging a different arena than the one that ships.
    """
    for obj in objects:
        if obj.name.split("_", 1)[1] not in pieces:
            continue
        for mat in obj.data.materials:
            bsdf = mat.node_tree.nodes.get("Principled BSDF") if mat.node_tree else None
            if not bsdf:
                continue
            for key in ("Emission Color", "Emission"):
                if key in bsdf.inputs:
                    bsdf.inputs[key].default_value = (*colour, 1.0)
                    break
            if "Emission Strength" in bsdf.inputs:
                bsdf.inputs["Emission Strength"].default_value = strength


def _stage_noctyss(path_out, objects):
    """The money shot: the Choirfloor built, the choir standing in its own
    sockets, the maw up through the pit.

    Imports arena_gen so the sockets under the stalks are the REAL ones - if
    the arena's ring ever moves, this render shows stalks growing out of bare
    stone instead of out of their collars.
    """
    import os

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import arena_gen  # noqa: E402  (guarded: importing it builds nothing)

    # The one number both files own. Diverge and the choir floats off its
    # sockets, which is exactly the failure a staged render exists to catch.
    if [(round(r, 2), round(d, 2)) for r, d in arena_gen.GL_SOCKETS] != [
        (round(r, 2), round(d, 2)) for r, d in NC_SOCKETS
    ]:
        raise SystemExit(
            "STAGED ABORT: boss_gen NC_SOCKETS disagrees with arena_gen GL_SOCKETS - "
            "the choir would not stand in its collars. Fix one to match the other."
        )

    state = nc_state()
    arena_gen.build_noctyss()
    _emissive(objects, {"StalkBulb"}, (1.0, 0.80, 0.42), 3.2)
    _emissive(objects, {"Gullet"}, (1.0, 0.84, 0.46), 2.6)
    for obj in objects:
        obj.hide_render = True
    by_name = {obj.name.split("_", 1)[1]: obj for obj in objects}

    for index in range(len(NC_SOCKETS)):
        _, hood_matrix = _place_stalk(by_name, lambda t, i=index: _nc_stalk_path(i, t, state))
        _lantern(hood_matrix @ Vector(NC_BULB), 6000.0, (1.0, 0.80, 0.42), radius=2.4)

    maw_scale = NC_MAW["scale"]
    pitch, yaw = math.radians(NC_MAW["pitch"]), math.radians(NC_MAW["yaw"])
    forward = Vector((math.cos(pitch) * math.cos(yaw), math.cos(pitch) * math.sin(yaw), math.sin(pitch)))
    maw_base = (
        Matrix.Translation(Vector((0.0, 0.0, NC_MAW["origin_z"])))
        @ Vector((1, 0, 0)).rotation_difference(forward).to_matrix().to_4x4()
        @ Matrix.Diagonal((maw_scale,) * 3).to_4x4()
    )
    _place_maw(by_name, (0.0, 0.0, NC_MAW["origin_z"]), NC_MAW["pitch"], NC_MAW["yaw"], NC_MAW["gape"], maw_scale)
    _lantern(maw_base @ Vector(NC_GULLET), 11000.0, (1.0, 0.84, 0.46), radius=4.0)

    print(
        "STAGED noctyss: %d stalks at scale %.1f on the r%.0f ring, maw at scale %.1f "
        "(pitch %.0f, gape %.0f) up through the pit"
        % (len(NC_SOCKETS), NC_STALK_SCALE, NC_SOCKET_R, maw_scale, NC_MAW["pitch"], NC_MAW["gape"])
    )

    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.rotation_euler = (math.radians(54), 0, math.radians(-36))
    # Seven lanterns 35 studs up add up: at the wattage that made ONE read,
    # the choir collectively lit the near-black shelf to beach sand. They are
    # local pools now, and the sun does the geometry-reading work a review
    # render needs - the mood is Studio's job, with the gloom fog on top.
    sun.data.energy = 1.5
    bpy.context.collection.objects.link(sun)
    fill = bpy.data.objects.new("Fill", bpy.data.lights.new("Fill", "SUN"))
    fill.rotation_euler = (math.radians(68), 0, math.radians(132))
    fill.data.energy = 0.5
    bpy.context.collection.objects.link(fill)

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1500
    scene.render.resolution_y = 1000
    # Standard, not the default filmic transform: this arena's whole palette
    # is near-black basalt, and a tone curve that lifts the darks renders it
    # as beach sand - a flattering lie about the one thing the fight depends
    # on. Lights are allowed to clip; the stone must stay the stone.
    scene.view_settings.view_transform = "Standard"
    scene.world = bpy.data.worlds.new("World")
    scene.world.use_nodes = True
    bg = scene.world.node_tree.nodes.get("Background")
    if bg:
        bg.inputs[0].default_value = (0.045, 0.052, 0.078, 1.0)

    shots = (
        ("", (0, -150, 62), (0, 0, 20), 34),
        # From the shelf, between two sockets: the fight's own eyeline, and
        # the only view that answers "how big is this thing where I stand".
        ("_ground", (14.5, -58, 6.2), (0, 0, 12), 26),
    )
    for suffix, location, target, lens in shots:
        cam_data = bpy.data.cameras.new("Cam" + suffix)
        cam_data.lens = lens
        cam = bpy.data.objects.new("Cam" + suffix, cam_data)
        cam.location = Vector(location)
        cam.rotation_euler = (Vector(target) - cam.location).to_track_quat("-Z", "Y").to_euler()
        bpy.context.collection.objects.link(cam)
        scene.camera = cam
        out = path_out if not suffix else path_out.replace("_staged.png", "_staged%s.png" % suffix)
        scene.render.filepath = out
        bpy.ops.render.render(write_still=True)
        print("BOSS STAGED:", out)


def _rf_swim_path(t):
    """Rimefang's preview line.

    Whales do NOT serpentine: a sine down the whole body reads as an eel and
    would throw away the one thing the silhouette is for. The forebody runs
    almost straight and the flex grows toward the peduncle, which is how a
    whale actually swims - and how the fight's breach arc is shaped too.
    """
    return Vector((-t * 54.0, math.sin(t * 1.15 * math.pi) * (1.6 + 7.4 * t * t), 4.2 * (1 - t) ** 2))


def _place_rimefang(objects):
    by_name = {obj.name.split("_", 1)[1]: obj for obj in objects}
    made = []

    def place(source, position, tangent, scale, extra=None, lift=0.0, side=0.0):
        copy = source.copy()
        copy.data = source.data
        copy.hide_render = False
        bpy.context.collection.objects.link(copy)
        basis = Vector((1, 0, 0)).rotation_difference(tangent).to_matrix().to_4x4()
        # Offsets are in the BODY's frame, not the world's, so a fin sits on
        # the back and a flipper on the flank wherever the body has turned.
        copy.location = Vector(position) + (basis @ Vector((0.0, side, lift)))
        copy.rotation_euler = (basis @ extra).to_euler() if extra is not None else basis.to_euler()
        copy.scale = (scale, scale, scale)
        made.append(copy)
        return copy

    at_length, tangent_at, total = _arc_walker(_rf_swim_path)
    # STEP WITH THE GIRTH. A fixed pitch works for a serpent, whose segments
    # are all one size; here the peduncle's vertebrae are a third the size of
    # the chest's, so a fixed pitch marched them apart and the tail arrived as
    # three loose blocks floating ahead of the flukes.
    distance, count = 0.0, 0
    while distance < total:
        scale = _rf_girth(distance / total)
        for name in ("Body", "Belly"):
            place(by_name[name], at_length(distance), tangent_at(distance), scale)
        count += 1
        distance += RF_SEG_SPACING * 0.62 * max(scale, 0.42)

    head_at = at_length(0) + tangent_at(0) * 5.2
    for name in ("Head", "Jaw", "Teeth", "Eyes", "Rime"):
        place(by_name[name], head_at, tangent_at(0), 1.0)

    fin_d = total * 0.42
    place(by_name["Fin"], at_length(fin_d), tangent_at(fin_d), 1.0, lift=6.6 * _rf_girth(fin_d / total))

    pec_d = total * 0.20
    girth = _rf_girth(pec_d / total)
    for side in (1, -1):
        place(
            by_name["Pec"],
            at_length(pec_d),
            tangent_at(pec_d),
            1.0,
            extra=Matrix.Rotation(0 if side > 0 else math.pi, 4, "X"),
            lift=-3.6 * girth,
            side=side * 5.2 * girth,
        )

    place(by_name["Fluke"], at_length(total), tangent_at(total), 0.95)
    print("WHALE: %.0f studs nose to fluke, %d vertebrae (girth-stepped)" % (total, count))
    return made


PREVIEW_CAMS = {
    "kraken": (0.95, -0.62, 0.30),
}

PLACERS = {
    "kraken": _place_kraken,
    "gnashroot": _place_gnashroot,
    "noctyss": _place_noctyss,
    "rimefang": _place_rimefang,
    "pyrelisk": _place_pyrelisk,
}

def _stage_gnashroot(path_out, objects):
    """The Rootmere built, and Old Gnashroot lying in it at the creature
    row's real scale (1.5).

    Imports arena_gen so the mere under the body is the REAL one - if the
    arena's bowl or bank ever moves, this render shows the colossus floating
    or buried instead of half-sunk. It is also the only honest check on the
    design's central claim: from the bank it should read as an islet with a
    dead tree growing out of it, until it opens an eye.
    """
    import os

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import arena_gen  # noqa: E402  (guarded: importing it builds nothing)

    arena_gen.build_gnashroot()
    for obj in objects:
        obj.hide_render = True
    _place_gnashroot(objects, scale=1.5)

    # The fen's own light: a low hard key and a soft fill against an overcast
    # sky - the mood island_gen's swamp previews are judged in. The bright
    # neutral sun the parts-sheet preview uses washes peat-green to sage.
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.rotation_euler = (math.radians(44), 0, math.radians(-52))
    sun.data.energy = 1.9
    bpy.context.collection.objects.link(sun)
    fill = bpy.data.objects.new("Fill", bpy.data.lights.new("Fill", "SUN"))
    fill.rotation_euler = (math.radians(68), 0, math.radians(120))
    fill.data.energy = 0.45
    bpy.context.collection.objects.link(fill)

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1500
    scene.render.resolution_y = 1000
    scene.world = bpy.data.worlds.new("World")
    scene.world.use_nodes = True
    bg = scene.world.node_tree.nodes.get("Background")
    if bg:
        bg.inputs[0].default_value = (0.17, 0.19, 0.20, 1.0)

    # Two shots: the approach across the bank (how a player actually meets
    # it) and a three-quarter showing the whole limb spread in the arena.
    for suffix, location, target, lens in (
        # THE APPROACH: head-on, from the bank off its snout (the body
        # faces +X), at eye height. This is the angle a player actually
        # arrives at, and the one the whole silhouette is designed for.
        # Kept clear of the limbs, which rest on bearings +/-52 and +/-133.
        # r 62 on a bearing of 35 deg: ON THE BANK (which ends at r 70 - at
        # r 74 the lens sat inside the grove and a trunk filled the frame),
        # three-quarters onto the snout, clear of the limbs at +/-52.
        # r 52 puts the lens INSIDE the bank (grove starts at 67, and its
        # crowns lean outward, so nothing overhangs here), on the one bearing
        # with no stump (they sit at 45/135/225/315), and 34 up clears the
        # limb crests. Three attempts at eye level all ended inside a leaf
        # mass or behind a trunk - in a walled arena the honest hero angle is
        # from above the fight, not in it.
        ("", (52, 0, 34), (-2, 0, 4), 22),
        # THE WIDE: steep enough to clear the near canopy, which swallowed
        # the bottom half of the first attempt.
        ("_wide", (75, -100, 150), (0, 0, 4), 26),
    ):
        cam_data = bpy.data.cameras.new("Cam" + suffix)
        cam_data.lens = lens
        cam = bpy.data.objects.new("Cam" + suffix, cam_data)
        cam.location = Vector(location)
        cam.rotation_euler = (Vector(target) - cam.location).to_track_quat("-Z", "Y").to_euler()
        bpy.context.collection.objects.link(cam)
        scene.camera = cam
        out = path_out if not suffix else path_out.replace("_staged.png", "_staged%s.png" % suffix)
        scene.render.filepath = out
        bpy.ops.render.render(write_still=True)
        print("BOSS STAGED:", out)


# Per-boss staged renderers (the arena-and-boss shot). A boss with no entry
# falls through to the brinejaw body below, which is what shipped first.
STAGERS = {
    "noctyss": _stage_noctyss,
    "pyrelisk": _stage_pyrelisk,
    "gnashroot": _stage_gnashroot,
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
    # A 3/4 angle suits a long body, but a boss whose whole point is the FACE
    # gets judged from nearer the front - side-on you see one eye and cannot
    # tell whether the other one is even there.
    offset = Vector(PREVIEW_CAMS.get(boss, (0.30, -1.0, 0.42))).normalized() * span * (1.85 if boss == "pyrelisk" else 1.28)
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


# The fight, as still images. Each entry is a moment the design turns on, so
# an attack can be reviewed before anyone can play it: what the party sees,
# and whether the answer to it is legible from where they stand.
BJ_POSES = {
    "sweep_low": (
        "LOW SWEEP - jump it",
        bj_state(unwind=1.0, sweep_height=BJ_SWEEP_LOW, sweep_angle=math.radians(232)),
        (138, -110, 13), (0, 0, 18),
    ),
    "sweep_high": (
        "HIGH SWEEP - stand under it",
        bj_state(unwind=1.0, sweep_height=BJ_SWEEP_HIGH, sweep_angle=math.radians(232)),
        (138, -110, 13), (0, 0, 18),
    ),
    "slam_raise": (
        "TAIL SLAM, windup - the tail is over a reef stone",
        bj_state(unwind=1.0, sweep_height=BJ_SWEEP_HIGH + 9.0, sweep_angle=math.radians(15)),
        (36, -128, 27), (32, 8, 12),
    ),
    "stagger": (
        "THE PUNISH WINDOW - grip lost, head down on the sand",
        bj_state(coil=2, slump=1.0, face_angle=math.radians(250)),
        (-95, -150, 34), (-20, -12, 12),
    ),
    "last_coil": (
        "THIRD STANCE - the stack has slid two turns down the tower",
        bj_state(coil=1),
        (96, -144, 46), (0, 0, 30),
    ),
}


def render_pose(path_out, objects, state, camera, target):
    import os

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import arena_gen  # noqa: E402

    clear_scene()
    objects = BOSSES["brinejaw"]()
    arena_gen.build_brinejaw()
    for obj in objects:
        obj.hide_render = True
    _place_chain(objects, bj_pose_path(state), head_scale=1.35, tail_scale=0.55)
    _light_and_shoot(path_out, camera, target)


def _light_and_shoot(path_out, camera, target, lens=42):
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.rotation_euler = (math.radians(48), 0, math.radians(-40))
    sun.data.energy = 2.4
    bpy.context.collection.objects.link(sun)
    fill = bpy.data.objects.new("Fill", bpy.data.lights.new("Fill", "SUN"))
    fill.rotation_euler = (math.radians(70), 0, math.radians(130))
    fill.data.energy = 0.9
    bpy.context.collection.objects.link(fill)

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.lens = lens
    cam = bpy.data.objects.new("Cam", cam_data)
    cam.location = Vector(camera)
    cam.rotation_euler = (Vector(target) - cam.location).to_track_quat("-Z", "Y").to_euler()
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
    print("BOSS POSE:", path_out)


def render_staged(path_out, objects, boss="brinejaw"):
    """The money shot: the arena built, the boss posed on it.

    Imports arena_gen so the tower under the coils is the REAL one - if the
    arena's profile ever changes, this render shows the coils floating or
    biting into masonry instead of hugging it.
    """
    import os

    stager = STAGERS.get(boss)
    if stager:
        return stager(path_out, objects)

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


# THE FIGHT, AS STILL IMAGES. Each entry is a moment the design turns on, so
# an attack can be reviewed before anyone can play it: what the party sees,
# and whether the answer to it is legible from where they stand. Every state
# here is one the server can actually publish - these are renders of the
# shipped math (NoctyssPath), not illustrations of it.


def _nc_dark_bulb(by_name):
    """A DOUSED lantern, as its own object with its own material.

    Blender shares a material datablock across every instance of a piece, so
    without this copy one lit stalk lights all seven and the dousehunt frame
    renders as a lie - which is exactly what the first pass of it did. In game
    this is the client swapping the bulb Neon -> SmoothPlastic per stalk
    (NoctyssBodyController.setLantern); here it has to be a second object.
    """
    source = by_name["StalkBulb"]
    dark = source.copy()
    dark.data = source.data.copy()
    dark.data.materials.clear()
    dark.data.materials.append(make_material("Noctyss_StalkBulbDoused", (0.15, 0.13, 0.11)))
    dark.hide_render = True
    bpy.context.collection.objects.link(dark)
    return dark


def _nc_lit(state, *, doused=False):
    """Which stalks are lit, for the render's lantern lights."""
    return [
        (i, stalk)
        for i, stalk in enumerate(state["stalks"])
        if stalk["alive"] and (stalk["douse"] < 0.5 and not doused)
    ]


def _nc_pose_sweep():
    # One stalk leaned onto its bearing mid-sweep, the rest at rest: the
    # telegraph and the attack are the same object, and this is the frame
    # that has to prove it reads from the floor.
    state = nc_state()
    state["stalks"][3]["lean"] = 1.0
    state["stalks"][3]["beam"] = math.radians(196.0)
    return state


def _nc_pose_douse():
    state = nc_state()
    for stalk in state["stalks"]:
        stalk["douse"] = 1.0
    return state


def _nc_pose_broken():
    # A false lure has been shot: its stalk is down, its socket is a stump,
    # and the choir is one light poorer - which makes the next read harder,
    # not easier. That cost is the whole reason to hunt the RIGHT light.
    state = nc_state()
    state["stalks"][5]["alive"] = False
    state["stalks"][5]["fall"] = 1.0
    state["stalks"][5]["douse"] = 1.0
    state["stalks"][1]["lean"] = 0.45
    return state


def _nc_pose_maw():
    state = nc_state()
    for stalk in state["stalks"]:
        stalk["douse"] = 0.35
    state["maw_rise"] = 1.0
    state["maw_gape"] = 1.0
    return state


def _nc_pose_bite():
    # The window closing. The jaw is most of the way shut and anyone still
    # inside is about to wear it - the mouth IS the timer.
    state = nc_state()
    state["maw_rise"] = 1.0
    state["maw_gape"] = 0.22
    return state


def _nc_pose_flinch():
    # A lantern has just been shot. The stalk whips back along the bearing the
    # shot came from and rings down - the fight's only "you hit me" in a boss
    # that is otherwise unreachable, which is why it has to be legible.
    state = nc_state()
    state["stalks"][2]["kick"] = 1.0
    state["stalks"][2]["kick_age"] = 0.10
    state["stalks"][2]["beam"] = math.radians(150.0)
    state["time"] = 1.3
    return state


NC_POSES = {
    "flinch": (
        "HIT REACTION - the lantern is shot and the stalk whips back",
        _nc_pose_flinch,
        (52, -66, 34),
        (-8, 6, 26),
    ),
    "lightsweep": (
        "LIGHTSWEEP - the lit wedge is the hitbox; the dark behind a fin is the answer",
        _nc_pose_sweep,
        (86, -104, 30),
        (0, 0, 16),
    ),
    "dousehunt": (
        "DOUSEHUNT - every lantern out at once, and a strike coming where you stood",
        _nc_pose_douse,
        (0, -118, 34),
        (0, 0, 18),
    ),
    "brokenlure": (
        "A FALSE LURE BROKEN - one stalk down, its socket a stump, the arena darker",
        _nc_pose_broken,
        (-64, -92, 26),
        (-10, 0, 14),
    ),
    "mawopen": (
        "THE PUNISH WINDOW - she is up through the pit and you fight in her mouth",
        _nc_pose_maw,
        (18, -74, 22),
        (0, 0, 10),
    ),
    "mawbite": (
        "THE MOUTH CLOSING - the gape IS the timer; leaving is the player's job",
        _nc_pose_bite,
        (26, -58, 16),
        (0, 0, 8),
    ),
}


def render_nc_pose(path_out, objects, entry):
    """One fight moment, on the real arena, lit by whatever is still lit."""
    import os

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import arena_gen  # noqa: E402

    label, make_state, camera, target = entry
    state = make_state()

    clear_scene()
    objects = BOSSES["noctyss"]()
    arena_gen.build_noctyss()
    _emissive(objects, {"StalkBulb"}, (1.0, 0.80, 0.42), 3.2)
    _emissive(objects, {"Gullet"}, (1.0, 0.84, 0.46), 2.6)
    for obj in objects:
        obj.hide_render = True
    by_name = {obj.name.split("_", 1)[1]: obj for obj in objects}

    doused_names = dict(by_name)
    doused_names["StalkBulb"] = _nc_dark_bulb(by_name)
    for index, stalk in enumerate(state["stalks"]):
        lit = stalk["alive"] and stalk["douse"] < 0.5
        _, hood_matrix = _place_stalk(
            by_name if lit else doused_names, lambda t, i=index: _nc_stalk_path(i, t, state)
        )
        if lit:
            _lantern(hood_matrix @ Vector(NC_BULB), 6000.0, (1.0, 0.80, 0.42), radius=2.4)

    if state["maw_rise"] > 0.01:
        maw = dict(NC_MAW)
        maw_scale = maw["scale"]
        # The rise and the gape are what the state says, so a half-open jaw
        # renders as a half-open jaw rather than the pose we happen to like.
        z = -26.0 + (maw["origin_z"] + 26.0) * state["maw_rise"]
        pitch, yaw = math.radians(maw["pitch"]), math.radians(maw["yaw"])
        forward = Vector((math.cos(pitch) * math.cos(yaw), math.cos(pitch) * math.sin(yaw), math.sin(pitch)))
        base = (
            Matrix.Translation(Vector((0.0, 0.0, z)))
            @ Vector((1, 0, 0)).rotation_difference(forward).to_matrix().to_4x4()
            @ Matrix.Diagonal((maw_scale,) * 3).to_4x4()
        )
        _place_maw(by_name, (0.0, 0.0, z), maw["pitch"], maw["yaw"], maw["gape"] * state["maw_gape"], maw_scale)
        _lantern(base @ Vector(NC_GULLET), 11000.0, (1.0, 0.84, 0.46), radius=4.0)

    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.rotation_euler = (math.radians(54), 0, math.radians(-36))
    # The dousehunt frame gets almost nothing: the point of that image is how
    # little you can see, and lighting it for legibility would be a lie.
    lit = len(_nc_lit(state))
    sun.data.energy = 1.5 if lit else 0.45
    bpy.context.collection.objects.link(sun)
    fill = bpy.data.objects.new("Fill", bpy.data.lights.new("Fill", "SUN"))
    fill.rotation_euler = (math.radians(68), 0, math.radians(132))
    fill.data.energy = 0.5 if lit else 0.12
    bpy.context.collection.objects.link(fill)

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1500
    scene.render.resolution_y = 1000
    scene.view_settings.view_transform = "Standard"
    scene.world = bpy.data.worlds.new("World")
    scene.world.use_nodes = True
    bg = scene.world.node_tree.nodes.get("Background")
    if bg:
        bg.inputs[0].default_value = (0.045, 0.052, 0.078, 1.0)

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.lens = 32
    cam = bpy.data.objects.new("Cam", cam_data)
    cam.location = Vector(camera)
    cam.rotation_euler = (Vector(target) - cam.location).to_track_quat("-Z", "Y").to_euler()
    bpy.context.collection.objects.link(cam)
    scene.camera = cam
    scene.render.filepath = path_out
    bpy.ops.render.render(write_still=True)
    print("BOSS POSE:", path_out, "-", label)


def main():
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    if len(argv) < 2 or argv[1] not in BOSSES:
        print("usage: blender --background --python boss_gen.py -- <out.glb> <%s> [preview] [staged] [poses]" % "|".join(BOSSES))
        return
    clear_scene()
    objects = BOSSES[argv[1]]()
    export(argv[0], objects)
    if "preview" in argv[2:]:
        render_preview(argv[0].replace(".glb", "_preview.png"), objects, argv[1])
    if "staged" in argv[2:]:
        render_staged(argv[0].replace(".glb", "_staged.png"), objects, argv[1])
    if "poses" in argv[2:]:
        if argv[1] == "noctyss":
            for name, entry in NC_POSES.items():
                render_nc_pose(argv[0].replace(".glb", "_pose_%s.png" % name), objects, entry)
        else:
            for name, (label, state, camera, target) in BJ_POSES.items():
                print("POSE", name, "-", label)
                render_pose(argv[0].replace(".glb", "_pose_%s.png" % name), objects, state, camera, target)


if __name__ == "__main__":
    main()
