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
# THE MAW OF THE MAELSTROM - and it is a FINAL BOSS, which is a shape, not an
# adjective (user, 2026-09-08: "super scary and super huge, super super huge",
# "towering above me", "you just really have to make the head of the boss which
# should be tall and big and huge, and then 2 tentacles or more and then you
# can just use those for the attacks").
#
# WHAT THIS IS NOW, and what it replaced. The first design was a modest head
# on an arm crown with EIGHT arms reaching out to a tentacle ring. That is
# dead: eight limbs at a readable scale is eight small limbs, and a head sized
# to sit inside its own arm ring is a head you look AT rather than UP AT. The
# fight is now a colossal head standing off in the water and TWO (or more)
# enormous tentacle chains that slam and sweep across the platform the player
# stands on - and, in phase three, a maw big enough to walk into.
#
# THREE RULES THIS SECTION EXISTS TO OBEY:
#  1. THE HEAD IS THE BOSS. Authored ~80 units above the waterline on a ~30
#     half-width, drawn at SCALE ~6 -> ~480 studs tall and ~360 wide. Every
#     number below is AUTHORED units; the HANDOFF lines carry both readings.
#  2. A TENTACLE MUST READ AS ONE LIMB, never a string of blocks. Every
#     segment is a CAPSULE - a barrel with DOMED ends - authored LONGER than
#     the pitch it is planted at (KR_TENT_SEG 12.0 vs KR_TENT_SPACING 6.0), so
#     consecutive segments always interpenetrate no matter how hard the limb
#     bends. Domed ends are what keeps a bend filled: flat-capped cylinders
#     open a wedge of daylight on the outside of every curve, and hard
#     shoulder rings read as notches cut into the limb where an end surfaces.
#  3. THE DOOR IS THE SIPHON. Phase three is inside the animal, so there has
#     to be a way in - but the owner cut the mouth (2026-09-08: "that sucks.
#     remove the mouth."), and the reference he gave in its place has no maw
#     at all: pale roots converging under the eyes with a ring-stepped funnel
#     between them. So the aperture is Kraken_Siphon, and Kraken_SiphonCore -
#     a Neon body seated INSIDE it - is what the player sees through the hole.
#     Roblox meshes are single-sided, so an opening is still built as a body
#     behind an open lip, never as a hole cut in the mantle: that part of the
#     old rule survives its own mouth.
#
# The tentacles are NOT body parts: they are the chains the boss engine plants
# down a ChainPose curve, so a limb is ONE authored capsule instanced.

KR_CREAM = (0.902, 0.859, 0.757)   # the mantle: pale bone-cream, the base hide
KR_CAP = (0.415, 0.243, 0.545)     # the mottled cap draped over the crown
KR_TEAL = (0.161, 0.596, 0.573)    # the crown scrollwork and the eyespot studs
KR_LASH = (0.063, 0.259, 0.271)    # dark teal: the lashes over each socket
KR_AMBER = (1.000, 0.596, 0.118)   # the orbs - Neon in game, the face's light
KR_STAR = (0.976, 0.945, 0.855)    # the four-point star pupil, matte cream
KR_COBALT = (0.129, 0.271, 0.706)  # barnacle shells
KR_CORE = (0.235, 0.976, 0.706)    # the siphon's glowing core - Neon
KR_HIDE = (0.298, 0.161, 0.451)    # the tentacles: deep purple
KR_SUCKER = (0.929, 0.878, 0.784)  # the sucker discs: pale cream, the signature
KR_CRUST = (0.34, 0.32, 0.28)   # barnacle plate and drowned timber - PALE, not gold
KR_FLESH = (0.30, 0.10, 0.15)   # phase three: the meat you stand on
KR_FLESH2 = (0.52, 0.24, 0.27)  # phase three: rib, lighter than the wall
KR_POLYP = (0.94, 0.34, 0.50)   # phase three: the destructible node, Neon-able

# The scale the engine DRAWS this pack at. The authoritative constant lands
# with the fight-logic slice (the body controller is what plants the head);
# this one exists so every HANDOFF line can print the stud figure beside the
# authored one instead of leaving the reader to multiply.
KR_SCALE = 6.0

KR_TENT_RADIUS = 4.0    # authored half-width of a tentacle segment
KR_TENT_SEG = 12.0      # authored segment length - LONGER than the pitch
KR_TENT_SPACING = 6.0   # placement pitch down the curve
# How MANY segments a limb gets is not a constant: the placer walks the rest
# path and plants one every KR_TENT_SPACING, so a longer arc gets more. The
# HANDOFF line measures it rather than asserting it.


def _capsule(bm, length, r_mid, r_end, sides=12):
    """A barrel with rounded ends, along +X. Overlapping capsules read as one
    continuous limb through any bend - the whole point."""
    half = length / 2
    # Full radius across the middle 80%, rounding off only at the very ends:
    # stations at 0.88 of the half-length still carry 0.92 of the radius, then
    # 0.95/0.72, then 1.00/0.30.
    #
    # THE RULE: that parallel section must stay LONGER than the pitch the
    # segments are planted at (KR_TENT_SPACING), or neighbouring barrels only
    # meet on their shoulders, the surface dips at every joint, and the limb
    # ribs up like a caterpillar. It is the same trap as tapering the length.
    #
    # AND THE END MUST BE A DOME, not a pair of shoulders. The ends used to
    # step 1.0 -> 0.86 -> 0.34 in two jumps, which is fine while an end stays
    # buried in its neighbour - but on the OUTSIDE of a bend it surfaces, and
    # those two hard shoulder rings read as notches cut into the limb. A
    # tighter chain pitch makes that WORSE, not better: it exposes more ends,
    # so the fix has to be the profile. These four stations are a cosine-ish
    # falloff, so an end that does surface reads as a rounded knuckle.
    loft(bm, [
        ring_pts(-half, 0.0, r_end * 0.30, r_end * 0.30, sides=sides),
        ring_pts(-half * 0.95, 0.0, r_end * 0.72, r_end * 0.72, sides=sides),
        ring_pts(-half * 0.88, 0.0, r_end * 0.92, r_end * 0.92, sides=sides),
        ring_pts(-half * 0.80, 0.0, r_mid, r_mid, sides=sides),
        ring_pts(half * 0.80, 0.0, r_mid, r_mid, sides=sides),
        ring_pts(half * 0.88, 0.0, r_end * 0.92, r_end * 0.92, sides=sides),
        ring_pts(half * 0.95, 0.0, r_end * 0.72, r_end * 0.72, sides=sides),
        ring_pts(half, 0.0, r_end * 0.30, r_end * 0.30, sides=sides),
    ])


# The mantle's shape, as a profile turned about +Z. A TOWER: 80 units above
# the waterline against 30 of half-width, and 16 more of it under the water so
# the animal is standing IN the sea rather than sitting on it. The old dome
# was 46 on 19.8 and sized to sit inside its own arm ring; this one is drawn
# at KR_SCALE and comes out ~480 studs tall, which is the whole brief.
KR_HEAD_PROFILE = [
    (-16.0, 23.0), (-10.0, 31.0), (-4.0, 37.4), (2.0, 41.8),
    (9.0, 44.8), (16.0, 46.4), (24.0, 47.0), (32.0, 46.3),
    (40.0, 44.6), (48.0, 42.0), (55.0, 38.8), (62.0, 34.6),
    (68.0, 30.0), (73.0, 24.4), (77.0, 17.2), (79.2, 9.6), (80.0, 3.4),
]
KR_HEAD_TOP = 80.0
KR_HEAD_BASE = -16.0
KR_HEAD_SIDES = 26
KR_HEAD_LOBES = 6
KR_LOBE_DEPTH = 0.040

KR_EYE_BEARING = math.radians(24.0)
KR_EYE_Z = 46.0
KR_EYE_SEAT = 40.0
KR_EYE_R = 12.5
KR_SOCKET_R = 15.0

KR_SIPHON_Z = 24.0
KR_SIPHON_PITCH = math.radians(-26.0)
KR_SIPHON_MOUTH = 5.4
KR_SIPHON_RINGS = (13.2, 10.8, 8.6, 6.6)
KR_SIPHON_STEP = 3.8

KR_CAP_Z = 47.0
KR_CAP_SCALLOP = 7.0
KR_CAP_LIFT = 15.0
KR_CAP_DRIPS = ((0.0, 0.44, 15.0), (2.05, 0.34, 24.0), (-2.05, 0.34, 24.0),
                (math.pi, 0.30, 18.0), (1.15, 0.20, 13.0), (-1.15, 0.20, 13.0))

KR_TENT_ROOTS = ((24.0, 38.0), (46.0, 66.0), (70.0, 96.0))


def _kr_profile_r(z):
    table = KR_HEAD_PROFILE
    if z <= table[0][0]:
        return table[0][1]
    if z >= table[-1][0]:
        return table[-1][1]
    for (z0, r0), (z1, r1) in zip(table, table[1:]):
        if z0 <= z <= z1:
            return r0 + (r1 - r0) * ((z - z0) / (z1 - z0))
    return table[-1][1]


def _kr_crown_z(r):
    table = KR_HEAD_PROFILE
    widest = max(range(len(table)), key=lambda i: table[i][1])
    for i in range(len(table) - 1, widest, -1):
        z1, r1 = table[i]
        z0, r0 = table[i - 1]
        if r1 <= r <= r0:
            return z1 + (z0 - z1) * ((r - r1) / (r0 - r1))
    return table[widest][0]


def _kr_flute(a, z):
    t = min(max((z - KR_HEAD_BASE) / (KR_HEAD_TOP - KR_HEAD_BASE), 0.0), 1.0)
    amp = KR_LOBE_DEPTH * math.sin(math.pi * t ** 0.85)
    return 1.0 + amp * math.cos(KR_HEAD_LOBES * a)


def _kr_wrap(a):
    return (a + math.pi) % TAU - math.pi


def _kr_cap_border(a):
    z = KR_CAP_Z + KR_CAP_SCALLOP * (0.62 * math.cos(3.0 * a + 0.4)
                                     + 0.38 * math.cos(7.0 * a + 1.7))
    for side in (-1, 1):
        d = _kr_wrap(a - side * KR_EYE_BEARING)
        z += KR_CAP_LIFT * math.exp(-(d / 0.44) ** 2)
    for bearing, width, depth in KR_CAP_DRIPS:
        d = _kr_wrap(a - bearing)
        z -= depth * math.exp(-(d / width) ** 2)
    return z


def _kr_eye_frame(side):
    """(rotation, outward unit) for one eye - local +X points out of the head,
    local +Y runs back along the flank, local +Z is up. Everything eye-shaped
    is built on this one frame so the orb, the star, the socket rim and the
    lashes cannot drift apart."""
    angle = side * KR_EYE_BEARING
    rot = Matrix.Rotation(angle, 3, "Z")
    return rot, (math.cos(angle), math.sin(angle))


def _kr_eye_centre(side, seat=None):
    _, out = _kr_eye_frame(side)
    s = KR_EYE_SEAT if seat is None else seat
    return Vector((out[0] * s, out[1] * s, KR_EYE_Z))


def _kr_sweep(bm, points, radii, sides=8):
    rings = []
    for i, (centre, r) in enumerate(zip(points, radii)):
        nxt = points[min(i + 1, len(points) - 1)]
        prev = points[max(i - 1, 0)]
        tangent = (nxt - prev).normalized()
        up = Vector((0.0, 0.0, 1.0))
        if abs(tangent.dot(up)) > 0.97:
            up = Vector((0.0, 1.0, 0.0))
        normal = tangent.cross(up).normalized()
        binormal = normal.cross(tangent).normalized()
        rings.append([
            tuple(centre + normal * (r * math.sin((k / sides) * TAU))
                  + binormal * (r * math.cos((k / sides) * TAU)))
            for k in range(sides)
        ])
    loft(bm, rings)


def _kr_prism(bm, centre, rot, radii, thick):
    """A flat faceted plate: an n-gon of per-vertex radii, extruded along the
    frame's local +X. The star pupils, the eyespot studs and the barnacle
    glints are all this shape - a few big facets, which is the whole language
    of the pack."""
    count = len(radii)
    rings = []
    for x in (-thick / 2.0, thick / 2.0):
        ring = []
        for k, r in enumerate(radii):
            a = (k / count) * TAU
            ring.append(tuple(Vector(centre) + rot @ Vector((x, math.cos(a) * r, math.sin(a) * r))))
        rings.append(ring)
    loft(bm, rings)


def _kr_root_spine(index, side, t):
    """One thick pale arm-root running down the front of the mantle. The roots
    CONVERGE below the eyes - that convergence is what the face reads as now
    that there is no mouth, and the siphon sits in the notch they leave."""
    b0, b1 = KR_TENT_ROOTS[index]
    bearing = side * math.radians(b0 + (b1 - b0) * t ** 0.75)
    z = 30.0 - t * 47.0
    r = _kr_profile_r(z) * (0.975 + 0.20 * t ** 1.4)
    return Vector((math.cos(bearing) * r, math.sin(bearing) * r, z))


def build_kr_head():
    """The mantle: a broad bulbous octopus cap in pale bone-cream, 80 units of
    it above the waterline on a 40.6 half-width, plus the thick pale roots of
    the front limbs converging below the eyes. Everything coloured is a
    separate object (the pipeline's one-material rule), so this piece is the
    silhouette and nothing else."""
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

    for index in range(len(KR_TENT_ROOTS)):
        for side in (-1, 1):
            points, radii = [], []
            for i in range(11):
                t = i / 10
                points.append(_kr_root_spine(index, side, t))
                radii.append(3.2 + 5.8 * t ** 1.15)
            _kr_sweep(bm, points, radii, sides=9)
    return finish("Kraken_Head", bm, KR_CREAM)


def build_kr_cap():
    """THE PURPLE CAP. A lobed hood draped over the crown, with an irregular
    SCALLOPED border where it meets the cream - the border is a function of
    bearing, not a ring, which is the difference between a hat and a marking
    that grew there. It arcs UP over each eye (so the orbs sit in their own
    purple sockets instead of being swallowed) and runs DOWN in tongues
    between them, and a few detached patches carry the mottle further down.
    The socket rims ride here too: they are the same purple, and a second
    object per colour is the pipeline's law, not a suggestion."""
    bm = bmesh.new()
    steps = 7
    columns = []
    for i in range(KR_HEAD_SIDES):
        a = (i / KR_HEAD_SIDES) * TAU
        columns.append((a, min(_kr_cap_border(a), KR_HEAD_TOP - 6.0)))
    grid = []
    # A tucked ring first: the cap is a SOLID, not a sheet. Its bottom edge
    # dives inside the mantle, so the seam is buried instead of showing the
    # open (and, on a single-sided mesh, invisible) underside of a shell.
    grid.append([
        (math.cos(a) * _kr_profile_r(z) * _kr_flute(a, z) * 0.93,
         math.sin(a) * _kr_profile_r(z) * _kr_flute(a, z) * 0.93, z - 1.2)
        for a, z in columns
    ])
    for v in range(steps + 1):
        ring = []
        for a, z0 in columns:
            z = z0 + (KR_HEAD_TOP - z0) * (v / steps)
            r = _kr_profile_r(z) * _kr_flute(a, z) * 1.035
            ring.append((math.cos(a) * r, math.sin(a) * r, z))
        grid.append(ring)
    verts = [[bm.verts.new(pt) for pt in ring] for ring in grid]
    for lower, upper in zip(verts, verts[1:]):
        for i in range(KR_HEAD_SIDES):
            j = (i + 1) % KR_HEAD_SIDES
            bm.faces.new((lower[i], lower[j], upper[j], upper[i]))
    bm.faces.new(list(reversed(verts[0])))
    bm.faces.new(verts[-1])

    # Detached mottling: lobed patches flowing on down the cream.
    patches = ((0.55, 34.0, 7.0), (-0.55, 34.0, 7.0), (1.75, 30.0, 8.4),
               (-1.75, 30.0, 8.4), (2.75, 25.0, 6.4), (-2.75, 25.0, 6.4),
               (0.0, 30.5, 5.2))
    for a, z, size in patches:
        r = _kr_profile_r(z) * _kr_flute(a, z)
        ellipsoid(bm, (math.cos(a) * r, math.sin(a) * r, z),
                  (size * 0.30, size, size * 0.78), subdiv=1, rot=Matrix.Rotation(a, 3, "Z"))

    # THE SOCKET RIMS. A heavy purple ring standing proud around each orb -
    # the thing that makes an eye look SET INTO a face rather than stuck onto
    # one, and the seat the lashes are rooted in.
    for side in (-1, 1):
        rot, _ = _kr_eye_frame(side)
        centre = _kr_eye_centre(side, KR_EYE_SEAT + 1.0)
        points, radii = [], []
        for k in range(19):
            a = (k / 18) * TAU
            local = Vector((0.0, math.cos(a) * KR_SOCKET_R, math.sin(a) * KR_SOCKET_R))
            points.append(centre + rot @ local)
            radii.append(3.6)
        _kr_sweep(bm, points, radii, sides=7)
    return finish("Kraken_Cap", bm, KR_CAP)


KR_SCROLLS = ((0.0, 25.0), (1.10, 32.0), (-1.10, 32.0), (2.30, 31.0), (-2.30, 31.0))


def build_kr_scrollwork():
    """The teal ornament over the crown: chunky symmetric curls, CURLS and not
    filigree. A spiral swept as a tapering tube reads as carved scroll at 480
    studs; anything finer is gone by the time it is drawn."""
    bm = bmesh.new()
    for bearing, seat in KR_SCROLLS:
        for hand in (-1, 1):
            points, radii = [], []
            for i in range(14):
                s = i / 13
                rho = 10.2 * (1.0 - 0.74 * s)
                phi = s * 3.5
                u = rho * math.cos(phi) - 10.2
                v = hand * rho * math.sin(phi)
                radial = seat + u
                x = math.cos(bearing) * radial - math.sin(bearing) * v
                y = math.sin(bearing) * radial + math.cos(bearing) * v
                base = math.hypot(x, y)
                points.append(Vector((x, y, _kr_crown_z(min(base, 46.0)) + 2.9)))
                radii.append(3.4 * (1.0 - 0.52 * s))
            _kr_sweep(bm, points, radii, sides=7)
    return finish("Kraken_Scrollwork", bm, KR_TEAL)


def build_kr_eyes():
    """THE CENTREPIECE. Two enormous ROUND orbs, side by side and facing
    FORWARD - 26 degrees off the nose, which is close enough that both are
    full circles from the deck. Round and bright is the whole brief: the
    previous pass narrowed them into almonds under a heavy brow and the animal
    read as half asleep. Neon in game."""
    bm = bmesh.new()
    for side in (-1, 1):
        rot, _ = _kr_eye_frame(side)
        ellipsoid(bm, tuple(_kr_eye_centre(side)), (KR_EYE_R, KR_EYE_R, KR_EYE_R),
                  subdiv=2, rot=rot)
    return finish("Kraken_Eyes", bm, KR_AMBER)


def build_kr_pupil():
    """The FOUR-POINT STAR in each orb: a flat cream plate standing proud of
    the amber, so it catches its own light instead of dissolving into the
    Neon. A star, not a slit - the slit is what made the last face read as a
    reptile's, and this one is meant to look back at you and be liked."""
    bm = bmesh.new()
    for side in (-1, 1):
        rot, _ = _kr_eye_frame(side)
        centre = _kr_eye_centre(side, KR_EYE_SEAT + KR_EYE_R - 0.9)
        _kr_prism(bm, centre, rot, (8.4, 2.0, 8.4, 2.0, 8.4, 2.0, 8.4, 2.0), 2.2)
    return finish("Kraken_Pupil", bm, KR_STAR)


KR_LASHES = 9


def build_kr_lashes():
    """A fringe of short dark-teal spikes along the UPPER rim of each socket.
    Upper only: a full ring is a sunflower, and it is the top fringe that
    gives a round eye its expression."""
    bm = bmesh.new()
    for side in (-1, 1):
        rot, _ = _kr_eye_frame(side)
        centre = _kr_eye_centre(side, KR_EYE_SEAT + 1.0)
        for k in range(KR_LASHES):
            a = math.radians(38.0 + k * (104.0 / (KR_LASHES - 1)))
            seat = Vector((0.0, math.cos(a) * (KR_SOCKET_R + 0.6), math.sin(a) * (KR_SOCKET_R + 0.6)))
            out = Vector((0.0, math.cos(a), math.sin(a))) * 5.4 + Vector((2.8, 0.0, 0.0))
            spike(bm, tuple(centre + rot @ seat), tuple(centre + rot @ (seat + out)), 1.9, sides=4)
    return finish("Kraken_Lashes", bm, KR_LASH)


# (bearing, height, count) for each cobalt cluster. Crown, brow and cap edge -
# where a hull actually fouls and where the silhouette needs the interest the
# retired spike crown used to give it.
KR_BARNACLES = (
    (0.75, 68.0, 4), (-0.75, 68.0, 4), (1.45, 62.0, 3), (-1.45, 62.0, 3),
    (1.95, 54.0, 5), (-1.95, 54.0, 5), (2.60, 62.0, 3), (-2.60, 62.0, 3),
    (math.pi, 69.0, 4), (0.0, 73.5, 3),
    (1.25, 34.0, 3), (-1.25, 34.0, 3), (2.30, 28.0, 4), (-2.30, 28.0, 4),
)


def _kr_barnacle_shells(bearing, z, count):
    """The shells of one cluster, as (base, tip, radius). Read by the cobalt
    builder AND by the teal glint builder, so a glint cannot drift off its
    shell - the two objects are the same cluster in two colours."""
    rng = random.Random(int(abs(bearing) * 977) + int(z) * 31 + count)
    out = []
    for _ in range(count):
        da = rng.uniform(-0.16, 0.16)
        dz = rng.uniform(-4.6, 4.6)
        a = bearing + da
        zz = z + dz
        r = _kr_profile_r(zz) * _kr_flute(a, zz)
        base = Vector((math.cos(a) * r * 0.97, math.sin(a) * r * 0.97, zz))
        normal = Vector((math.cos(a), math.sin(a), 0.34)).normalized()
        height = rng.uniform(5.4, 9.6)
        out.append((base, base + normal * height, rng.uniform(2.0, 3.2)))
    return out


def build_kr_barnacles():
    """Clusters of cobalt shells - angular, faceted, five-sided. They are what
    breaks the cap's round silhouette now that the bone spike crown is gone,
    and unlike the crown they do it without putting hooks across the face."""
    bm = bmesh.new()
    for bearing, z, count in KR_BARNACLES:
        for base, tip, radius in _kr_barnacle_shells(bearing, z, count):
            spike(bm, tuple(base), tuple(tip), radius, sides=5)
    return finish("Kraken_Barnacles", bm, KR_COBALT)


KR_EYESPOTS = (
    (0.45, 26.0), (-0.45, 26.0), (0.85, 14.0), (-0.85, 14.0),
    (1.45, 22.0), (-1.45, 22.0), (1.95, 10.0), (-1.95, 10.0),
    (2.60, 18.0), (-2.60, 18.0), (0.0, 6.0), (math.pi, 20.0),
    (1.20, 40.0), (-1.20, 40.0), (0.30, 36.0), (-0.30, 36.0),
    (0.70, 4.0), (-0.70, 4.0), (1.65, 34.0), (-1.65, 34.0),
    (2.25, 8.0), (-2.25, 8.0), (0.20, 16.0), (-0.20, 16.0),
)


def build_kr_eyespots():
    """Two teal jobs in one object, because one object is one colour: the
    small diamond studs dotted over the cream hide, and the single glint facet
    seated on the tip of each barnacle cluster's tallest shell."""
    bm = bmesh.new()
    for bearing, z in KR_EYESPOTS:
        r = _kr_profile_r(z) * _kr_flute(bearing, z)
        normal = Vector((math.cos(bearing), math.sin(bearing), 0.0))
        base = Vector((normal.x * r * 0.98, normal.y * r * 0.98, z))
        _kr_prism(bm, tuple(base + normal * 0.9),
                  Matrix.Rotation(bearing, 3, "Z"), (3.2, 1.3, 3.2, 1.3), 1.8)
    for bearing, z, count in KR_BARNACLES:
        shells = _kr_barnacle_shells(bearing, z, count)
        base, tip, radius = max(shells, key=lambda s: (s[1] - s[0]).length)
        axis = (tip - base).normalized()
        rot = Vector((1.0, 0.0, 0.0)).rotation_difference(axis).to_matrix()
        _kr_prism(bm, tuple(base + axis * ((tip - base).length * 0.62)), rot,
                  (radius * 0.42,) * 5, radius * 0.30)
    return finish("Kraken_Eyespots", bm, KR_TEAL)


def _kr_siphon_frame():
    """(origin on the hide, outward unit) for the siphon - aimed forward and
    DOWN off the front of the mantle, under the eyes and between the roots."""
    axis = Vector((math.cos(KR_SIPHON_PITCH), 0.0, math.sin(KR_SIPHON_PITCH)))
    origin = Vector((_kr_profile_r(KR_SIPHON_Z) * 0.92, 0.0, KR_SIPHON_Z + 3.0))
    return origin, axis


def build_kr_siphon():
    """THE SIPHON, AND IT IS THE DOOR. Phase three enters the animal through
    here, so it is not decoration: a stubby purple funnel stepping down in
    concentric rings to an open mouth, seated in the notch where the pale
    roots converge. It is LOFTED WITH NO END CAP on purpose - Roblox meshes
    are single-sided, so an aperture is built as an open ring with a body
    seated behind it (Kraken_SiphonCore), never as a hole cut in a wall."""
    bm = bmesh.new()
    origin, axis = _kr_siphon_frame()
    up = Vector((0.0, 0.0, 1.0))
    normal = axis.cross(up).normalized()
    binormal = normal.cross(axis).normalized()
    stations, radii = [], []
    reach = 0.0
    for r in KR_SIPHON_RINGS:
        stations.append(reach)
        radii.append(r)
        stations.append(reach + KR_SIPHON_STEP * 0.86)
        radii.append(r)
        reach += KR_SIPHON_STEP
    rings = []
    for s, r in zip(stations, radii):
        centre = origin + axis * s
        rings.append([
            tuple(centre + normal * (r * math.sin((k / 12) * TAU))
                  + binormal * (r * math.cos((k / 12) * TAU)))
            for k in range(12)
        ])
    loft(bm, rings, cap_start=True, cap_end=False)
    return finish("Kraken_Siphon", bm, KR_CAP)


def build_kr_siphon_core():
    """The glow recessed inside the funnel: Neon in game, and the only light
    on the animal below the eyeline. It is what makes the siphon read as an
    APERTURE rather than as a purple boss on the chest - and in phase three it
    is what the client dims or hides when the door opens."""
    bm = bmesh.new()
    origin, axis = _kr_siphon_frame()
    reach = KR_SIPHON_STEP * len(KR_SIPHON_RINGS)
    ellipsoid(bm, tuple(origin + axis * (reach - 2.4)),
              (3.2, KR_SIPHON_MOUTH, KR_SIPHON_MOUTH), subdiv=2,
              rot=Vector((1.0, 0.0, 0.0)).rotation_difference(axis).to_matrix())
    return finish("Kraken_SiphonCore", bm, KR_CORE)


def build_kr_crust(rng):
    bm = bmesh.new()
    # It has been down there long enough to become terrain. Kept LOW on the
    # dome, around the waterline where a hull actually fouls, and built from
    # flat plates rather than pebbles, so it looks grown on rather than
    # sprinkled. The cobalt barnacles do the ORNAMENT; this is the fouling.
    for _ in range(46):
        a = rng.uniform(1.3, 3.9)  # clustered on ONE FLANK, off the face
        z = rng.uniform(-11.0, 14.0)
        r = _kr_profile_r(z) * rng.uniform(0.94, 1.0)
        rot = Matrix.Rotation(a, 3, "Z")
        ellipsoid(bm, (math.cos(a) * r, math.sin(a) * r, z),
                  (rng.uniform(0.8, 1.7), rng.uniform(2.4, 5.0), rng.uniform(2.0, 4.4)),
                  subdiv=0, rot=rot)
    # A snapped spar driven into that same flank, and anchor chain grown into
    # it. Few links and small ones: a long even row reads as a zip fastener.
    box(bm, (-14.0, 33.0, 22.0), (30.0, 3.0, 3.0), Matrix.Rotation(math.radians(-24), 3, "Y"))
    for i in range(6):
        t = i / 5
        box(bm, (-24.0 - t * 4.4, 27.0 + t * 3.0, 11.0 - t * 9.0),
            (2.4, 1.7, 0.8) if i % 2 == 0 else (2.4, 0.8, 1.7))
    return finish("Kraken_Crust", bm, KR_CRUST)


# ---------------------------------------------------------------- tentacles
#
# THE LIMBS THE FIGHT IS MADE OF. Two chains or more, each one a building on
# its side: authored 4.0 half-width, so at KR_SCALE a segment is 48 studs of
# girth and a chain is hundreds of studs long.
def build_kr_tentacle_seg():
    bm = bmesh.new()
    # ONE segment: a capsule, authored LONGER than the pitch it is planted at
    # so consecutive segments always overlap into one limb.
    _capsule(bm, KR_TENT_SEG, KR_TENT_RADIUS, KR_TENT_RADIUS, sides=16)
    return finish("Kraken_TentacleSeg", bm, KR_HIDE)


def build_kr_tentacle_tip():
    bm = bmesh.new()
    # The last stretch: a long tapering curl, domed at the thick end so it
    # welds into the segment before it exactly the way a segment would.
    loft(bm, [
        ring_pts(9.0, 0.0, 2.4, 2.4, sides=16),
        ring_pts(7.0, 0.0, 3.7, 3.7, sides=16),
        ring_pts(3.0, 0.0, 3.9, 3.9, sides=16),
        ring_pts(-3.0, 0.0, 3.1, 3.1, sides=16),
        ring_pts(-10.0, 0.0, 2.1, 2.1, sides=16),
        ring_pts(-17.0, 0.0, 1.2, 1.2, sides=16),
        ring_pts(-23.0, 0.0, 0.55, 0.55, sides=16),
        ring_pts(-27.0, 0.0, 0.22, 0.22, sides=16),
    ])
    return finish("Kraken_TentacleTip", bm, KR_HIDE)


KR_SUCKER_R = 3.20
KR_SUCKER_ROWS = (math.radians(-24.0), math.radians(24.0))


def build_kr_tentacle_sucker():
    bm = bmesh.new()
    # THE SIGNATURE DETAIL, and the one the reference is most specific about:
    # a big FLAT pale disc, not a nipple. Two shallow steps, 5.7 across on an
    # 8-wide limb, laid in two orderly rows down the underside. Flat and pale
    # is what makes a purple limb read as a tentacle from a hundred studs off.
    disc(bm, -0.55, 0.30, KR_SUCKER_R, KR_SUCKER_R, sides=14)
    disc(bm, 0.30, 0.85, KR_SUCKER_R * 0.86, KR_SUCKER_R * 0.62, sides=14)
    return finish("Kraken_TentacleSucker", bm, KR_SUCKER)


# ------------------------------------------------- the inside of the beast
#
# PHASE THREE: what the player stands in once they go through the maw.
# Deliberately few and simple - the arena instances these, so it is a KIT, not
# a set, and the fight can build a gut out of three shapes.
def build_kr_rib_arch():
    bm = bmesh.new()
    # One rib of the gut: an arch across the tunnel in the YZ plane, springing
    # off the floor at +/-18 and closing at z=26.
    for i in range(30):
        t = i / 29
        a = math.pi * t
        y = math.cos(a) * 18.0
        z = math.sin(a) * 26.0
        r = 2.6 * (0.72 + 0.42 * math.sin(a))
        ellipsoid(bm, (0.0, y, z), (r * 0.85, r, r), subdiv=1)
    return finish("Kraken_RibArch", bm, KR_FLESH2)


def build_kr_polyp():
    bm = bmesh.new()
    # THE THING YOU KILL INSIDE IT: a fleshy node on a short stalk. Neon-able,
    # because a destructible in a black gut has to be findable before it can
    # be a target.
    loft(bm, [
        ring_pts(0.0, 0.0, 2.2, 2.2, sides=10),
        ring_pts(1.6, 0.0, 1.5, 1.5, sides=10),
        ring_pts(3.0, 0.0, 1.9, 1.9, sides=10),
    ])
    ellipsoid(bm, (0.0, 0.0, 5.4), (3.4, 3.4, 3.0), subdiv=2)
    for i in range(6):
        a = (i / 6) * TAU
        ellipsoid(bm, (math.cos(a) * 2.4, math.sin(a) * 2.4, 7.2), (1.15, 1.15, 1.5), subdiv=1)
    return finish("Kraken_Polyp", bm, KR_POLYP)


def build_kr_gut_strand():
    bm = bmesh.new()
    # A cord of gristle strung across the gut, sagging under its own weight.
    # Authored along +X so the arena can span it between any two points.
    rings = []
    for i in range(13):
        t = i / 12
        x = -12.0 + t * 24.0
        sag = -3.4 * math.sin(math.pi * t)
        r = 1.15 * (0.55 + 0.45 * math.sin(math.pi * t) ** 0.4)
        rings.append(ring_pts(x, sag, r, r, sides=9))
    loft(bm, rings)
    return finish("Kraken_GutStrand", bm, KR_FLESH)


def build_kraken():
    rng = random.Random(4471)
    objects = [
        build_kr_head(),
        build_kr_cap(),
        build_kr_scrollwork(),
        build_kr_crust(rng),
        build_kr_eyes(),
        build_kr_pupil(),
        build_kr_lashes(),
        build_kr_barnacles(),
        build_kr_eyespots(),
        build_kr_siphon(),
        build_kr_siphon_core(),
        build_kr_tentacle_seg(),
        build_kr_tentacle_tip(),
        build_kr_tentacle_sucker(),
        build_kr_rib_arch(),
        build_kr_polyp(),
        build_kr_gut_strand(),
    ]
    eye = _kr_eye_centre(1)
    half_width = max(r for _, r in KR_HEAD_PROFILE)
    origin, axis = _kr_siphon_frame()
    mouth = origin + axis * (KR_SIPHON_STEP * len(KR_SIPHON_RINGS))
    borders = [_kr_cap_border((i / 72) * TAU) for i in range(72)]
    parallel = KR_TENT_SEG * 0.80
    _, _, tent_total = _arc_walker(lambda t: _kr_tentacle_path(1, t))

    print("HANDOFF kraken: THE HEAD IS THE BOSS - a mantle authored z %.0f..%.0f (%.0f tall, %.0f of it above the waterline) on a %.1f half-width, and it FACES +X. Drawn at SCALE %.1f that is ~%.0f studs of head standing out of the water on a ~%.0f-stud beam. Broad and BULBOUS (widest at z %.0f), not the tower the first pass built."
          % (KR_HEAD_BASE, KR_HEAD_TOP, KR_HEAD_TOP - KR_HEAD_BASE, KR_HEAD_TOP, half_width,
             KR_SCALE, KR_HEAD_TOP * KR_SCALE, 2 * half_width * KR_SCALE,
             max(KR_HEAD_PROFILE, key=lambda p: p[1])[0]))
    print("HANDOFF kraken: every number in these lines is AUTHORED units. The DRAW SCALE constant itself lands with the fight-logic slice (the body controller is what plants the head); %.1f is what this pack was shaped and previewed against."
          % KR_SCALE)
    print("HANDOFF kraken: THE MOUTH IS GONE - Kraken_Beak, Kraken_Maw, Kraken_CrownSpikes and Kraken_TentacleHook no longer exist, and the face scoop with them. THE SIPHON IS THE DOOR NOW (phase three enters through it): a %d-ring purple funnel from the hide at (%.1f, 0.0, %.1f) out to a mouth at (%.1f, 0.0, %.1f), aimed %.0f deg below the horizon, aperture %.1f authored units across (%.0f studs at SCALE %.1f). Kraken_SiphonCore is the Neon body recessed %.1f units behind that lip and IS the visible interior - nothing may be placed in front of it, and it must not be culled with the head."
          % (len(KR_SIPHON_RINGS), origin.x, origin.z, mouth.x, mouth.z,
             -math.degrees(KR_SIPHON_PITCH), 2 * KR_SIPHON_MOUTH, 2 * KR_SIPHON_MOUTH * KR_SCALE,
             KR_SCALE, 2.4))
    print("HANDOFF kraken: THE EYES ARE THE FACE. Two ROUND Neon orbs r=%.1f at (%.1f, +/-%.1f, %.1f) - %.0f deg off the nose on a %.1f seat, %.1f units of clear air between them, standing %.1f proud of the hide. Kraken_Pupil is a FOUR-POINT STAR plate (%.1f across, %.1f thick) seated %.1f out - matte cream on Neon amber, so it stays readable when the orbs flare."
          % (KR_EYE_R, eye.x, eye.y, eye.z, math.degrees(KR_EYE_BEARING), KR_EYE_SEAT,
             2 * (eye.y - KR_EYE_R), KR_EYE_SEAT + KR_EYE_R - _kr_profile_r(KR_EYE_Z),
             2 * 8.4, 2.2, KR_EYE_SEAT + KR_EYE_R - 0.9))
    print("HANDOFF kraken: the purple cap is a SCALLOPED BORDER, not a ring - z %.0f..%.0f round the bearings (mean %.0f), arcing over the sockets and running down in tongues between them; it covers the top %.0f%% of the head. Kraken_Cap carries the socket rims, Kraken_Lashes the %d dark-teal spikes on each upper rim, Kraken_Scrollwork %d teal crown curls, Kraken_Barnacles %d cobalt clusters (%d shells) and Kraken_Eyespots the teal studs AND each cluster's glint."
          % (min(borders), max(borders), sum(borders) / len(borders),
             100.0 * (KR_HEAD_TOP - sum(borders) / len(borders)) / KR_HEAD_TOP,
             KR_LASHES, 2 * len(KR_SCROLLS), len(KR_BARNACLES),
             sum(c for _, _, c in KR_BARNACLES)))
    print("HANDOFF kraken: AMBIENT IDLE (the wiring slice owns this, the geometry only permits it). The mantle is authored about the WATERLINE - origin (0,0,0), base z=%.0f, top z=%.0f - so a breathe is a scale about the body CFrame's own origin with the head sunk %.0f units: recommended 1.0 +/- 0.05 on a ~4.5s sine, z-biased (1.0 +/- 0.05 vertical, 1.0 -/+ 0.025 horizontal) so it swells rather than balloons. Pulse Kraken_Eyes/Kraken_SiphonCore Neon between ~0.55 and ~1.0 on a slower ~6s offset sine, and drift the limbs with the existing ChainPose terms (no new geometry needed): +/-3 deg of bearing and +/-2 authored units of arc height at ~7s. Kraken_Pupil is MATTE and must not be pulsed with the orb - the star staying steady is what reads as a pupil."
          % (KR_HEAD_BASE, KR_HEAD_TOP, -KR_HEAD_BASE))
    print("HANDOFF kraken: Kraken_TentacleSeg is a CAPSULE %.1f long on a %.1f half-width, planted every %.1f - %.1f units of overlap, so a chain is ONE limb through any bend. The capsule's FULL-RADIUS parallel section is %.1f units (0.80 of its length either side of centre), which is what must stay longer than the pitch: %.1f > %.1f, unchanged from the last pack and not to be traded away. At SCALE %.1f that is %.0f studs of girth and %.0f studs of pitch: a limb the size of a building."
          % (KR_TENT_SEG, KR_TENT_RADIUS, KR_TENT_SPACING, KR_TENT_SEG - KR_TENT_SPACING,
             parallel, parallel, KR_TENT_SPACING,
             KR_SCALE, 2 * KR_TENT_RADIUS * KR_SCALE, KR_TENT_SPACING * KR_SCALE))
    print("HANDOFF kraken: the staged reared limb runs %.0f authored units of arc (%.0f studs at SCALE %.1f), so %d segments + Kraken_TentacleTip at that pitch. A SLAM arcs one over the deck and drops it; a SWEEP scythes it laterally across. Kraken_TentacleSucker is a FLAT pale disc %.1f across (%.0f studs) and rides in TWO rows at %.0f deg either side of straight-down, one pair per segment - the rows are the silhouette read, so a limb that loses them stops being a tentacle. NOTHING rides the back of a limb any more: the hooks are deleted."
          % (tent_total, tent_total * KR_SCALE, KR_SCALE, int(tent_total / KR_TENT_SPACING),
             2 * KR_SUCKER_R, 2 * KR_SUCKER_R * KR_SCALE, math.degrees(KR_SUCKER_ROWS[1])))
    print("HANDOFF kraken: INTERIOR KIT (phase three) - Kraken_RibArch is a %.0f-wide, %.0f-high arch in the YZ plane (%.0f x %.0f studs at SCALE %.1f), Kraken_Polyp is the Neon-able destructible node on a stalk, Kraken_GutStrand a 24-unit sagging cord along +X. Dark flesh palette, instanced by the arena, not by the body."
          % (36.0, 26.0, 36.0 * KR_SCALE, 26.0 * KR_SCALE, KR_SCALE))
    print("HANDOFF kraken: THE CLIENT'S PIECE AND SIZE TABLES MUST BE REBUILT AGAINST THIS PACK. The full inventory is now exactly: Kraken_Head, Kraken_Cap, Kraken_Scrollwork, Kraken_Crust, Kraken_Eyes, Kraken_Pupil, Kraken_Lashes, Kraken_Barnacles, Kraken_Eyespots, Kraken_Siphon, Kraken_SiphonCore, Kraken_TentacleSeg, Kraken_TentacleTip, Kraken_TentacleSucker, Kraken_RibArch, Kraken_Polyp, Kraken_GutStrand (%d objects). GONE: Kraken_Beak, Kraken_Maw, Kraken_CrownSpikes, Kraken_TentacleHook. NEW: Cap, Scrollwork, Lashes, Barnacles, Eyespots, Siphon, SiphonCore. Kraken_Eyes and Kraken_SiphonCore are the two Neon pieces and the body controller must set Material.Neon on them BY NAME - the boss path has no Neon-by-name rule of its own (see the wrack HANDOFF's warning); Kraken_Pupil is deliberately NOT one of them."
          % len(objects))
    return objects


# ================================================================ gnashroot
#
# "Old Gnashroot" - the fen standing up. ROOTED: it is sunk to the chest in
# the middle of the Rootmere, it never takes a step, and what travels is its
# ARMS.
#
# ---------------------------------------------------------- THE SECOND PASS
#
# The 2026-09-12 morning redesign fixed the RIG (arms at the front shoulders,
# jaw hinged under the skull, core in the chest, no legs) and the user
# rejected the LOOK, in these words:
#
#   "it still doesn't look good. it's too choppy, smoothen everything out.
#    also the jaw should maybe be at the top of the body not in the middle.
#    it's just too confusing to look at right now. redesign it to make it
#    easier to understand what it actually is. and smoothen out everything so
#    it's not choppy."
#
# Both halves of that are geometry, and both are answered here.
#
#   CHOPPY. Every form in the morning build was a low-segment loft (7 to 11
#   sides) with FLAT shading, buried under 100-odd jittered icospheres at
#   subdivision 0-1. That is a pile of facets by construction: no amount of
#   re-posing makes it read as mud. Now every object is built from high
#   segment counts (GN_SIDES 32 on the body forms, 24 on the limb, 14 on a
#   tube) and finished through `_gn_smooth`, which welds coincident verts,
#   recalculates normals outward and shades smooth with a 46-degree sharp
#   threshold - so the barrels are smooth and the ends of a tooth still have
#   an edge. The glTF exporter writes real split normals off that, which is
#   what makes Roblox render it smooth (verified: the NORMAL accessor is in
#   the .glb and its vertex count is split at the sharp edges, not at every
#   face). The scatter is gone: no object is a heap of lumps any more.
#
#   CONFUSING. The morning build had NO HEAD. The skull was slung low and
#   forward at z 12-15 on a mass whose crown was 27, so the mouth sat in the
#   MIDDLE of a featureless brown mound with two columns either side of it -
#   which is exactly what the staged render showed and exactly what the user
#   read. The anatomy is now stacked the way an animal's is, top to bottom:
#
#     SKULL on top      z 24.6..31.6, x -1.4..14.8 - a big cranium with a
#                       heavy BROW RIDGE (`build_gn_head`'s swept tube) and a
#                       short snout. THE TOP OF THE SILHOUETTE IS ITS FACE.
#     the two EYES      (9.8, +/-3.45, 26.15) r 1.6, forward-facing, directly
#                       under the brow. These are THE eyes: the other eight
#                       seats are half their size and sit back on the cheeks
#                       and temples, so the `Eyes` channel still stages a row
#                       but the read is a face with two eyes in it.
#     the JAW           hinged at (0.6, 0, 24.9) - the BACK of the skull -
#                       and opening DOWNWARD. The mouth is therefore the
#                       top-front of the silhouette, which is the user's
#                       "the jaw should be at the top of the body".
#     the NECK FOLD     z 23..26, the torso closing from 9.9 half-width to
#                       3.5 - a real neck, so the head is ON something.
#     the SHOULDERS     z 21.8, half-width 9.9 - the widest ring on the body,
#                       sloping out of the neck fold.
#     the COLLARBONES   two swept tubes from the sockets down to the chest,
#                       converging on -
#     the CORE          (7.6, 0, 16.6) - recessed BETWEEN the collarbones and
#                       under the chin, so the one bright thing on the animal
#                       sits in the hollow of its chest.
#     the TORSO         widening below the chest and sinking into the mere.
#     the ARMS          hung off the sockets, forward and down to the mud,
#                       ending in three-clawed root knots.
#
#   ...and NOTHING ELSE COMPETES. `Stones` is FOUR boulders (it was sixteen
#   chips); `Drips` is ten runnels, down the jowls and under the shoulders,
#   where the morning build hung twenty-three off the whole body.
#
# WHAT DID NOT CHANGE: the attribute contract, the attack ids, the object
# NAMES (Mass Roots Head Jaw Maw Teeth Fangs Core Stones Drips Arm ArmKnot
# Hand Eye), the stationary fight, and the rule that every authored number
# here is the number GnashrootPath carries on the Luau side.
#
# ------------------------------------------------ WHAT RIDES WHICH FRAME
#
# Two frames, and the split is the source of most of this rig's history:
#
#   BODY frame (one CFrame):  Mass Roots Head TEETH Eye(x10) Core Stones Drips
#   JAW frame (hinged):       Jaw  FANGS  Maw
#
# `Teeth` is the SKULL's palate row and `Fangs` is the jaw's row: one object
# for both dropped the palate's splinters four world studs at every gape.
# `Drips` is on the BODY, so nothing hung off it may be seated inside the
# jaw's volume - the jaw swings out from under it and the drip hangs in the
# open mouth. That is why the chin runnels are seated on the JOWL (the
# skull's lower cheek, outboard of the jaw at every shared x) rather than on
# the chin itself.
#
# Authored ROOTED with the mud apron's underside at z = 0: the client raises
# it out of the mere by lifting Y and nothing else.

GN_MUD = (0.42, 0.28, 0.17)  # wet peat-mud, warm enough to read against the fen's greens
GN_DARK = (0.22, 0.14, 0.08)  # the throat, and the drips
GN_STONE = (0.37, 0.36, 0.335)  # bog stone hauled up with it
GN_FANG = (0.62, 0.58, 0.48)  # bog-oak splinters doing the work of teeth
GN_EYE = (0.10, 0.09, 0.08)  # wet, dark, set into the mud
GN_WISP = (0.588, 0.922, 0.784)  # the row's markColor - the CORE only, Neon in game

# HOW MANY SIDES A FORM GETS, and this is the whole of the "choppy" fix at
# the level of one number. The morning build lofted the torso on 11 sides and
# the head on 9: at 9 sides consecutive facets meet at 40 degrees, which no
# smoothing threshold can average without flattening the tooth next to it, so
# the body HAD to read as faceted. At 32 the facets meet at 11.25 degrees and
# a smooth normal is indistinguishable from a curve at any distance a player
# ever sees this thing from.
GN_SIDES = 32  # torso, skull, jaw, apron - everything whose silhouette is a curve
GN_LIMB_SIDES = 24  # arm vertebrae and the palm
GN_TUBE_SIDES = 14  # brow, lip roll, collarbones, roots, drips, claws
# The sharp-edge threshold `_gn_smooth` shades by. Above it an edge keeps its
# crease (a tooth's tip, the flat cap where a tube is buried in a body);
# below it the normals are averaged. 46 clears the 32-gon's 11.25 and the
# 24-gon's 15 and the 14-gon's 25.7, and does not clear a cone's tip.
GN_SMOOTH_ANGLE = 46.0

# ------------------------------------------------------------------ the mouth
#
# THREE PLANES, all of them ~13 studs higher than the morning build's, which
# is the "jaw at the top of the body" complaint expressed in numbers:
#
#   GN_JAW_LINE   24.6  the PALATE - the roof of the mouth, and the flat the
#                       skull's loft is floored on. `Teeth` hangs DOWN from
#                       here.
#   GN_JAW_RIM    24.4  the lower jaw's LIP - the top of the trough's side
#                       walls, 0.2 under the palate so a shut mouth reads as
#                       a seam and not as a slot you can see through.
#   GN_JAW_TROUGH 21.8  the FLOOR of the trough, where the jaw's own loft is
#                       ceiled and where `Fangs` rises from.
#
# The lower jaw is a TROUGH, not a slab, and every fang is clamped inside it,
# so no part of the lower jaw can stand above the upper at any gape.
GN_JAW_LINE = 24.6
GN_JAW_RIM = 24.4
GN_JAW_TROUGH = 21.8
# Kept under the old name: the client and the drip builder both ask "what is
# the highest the lower jaw reaches", and that is the rim.
GN_JAW_TOP = GN_JAW_RIM

# THE SKULL, as cross-sections along +X (its facing): (x, centre z, half
# width, half height). Floored on the palate.
#
# It is BIG - 16.2 long, 11.6 wide, 7.0 deep - against a torso 19.8 wide, and
# it is meant to be: a head that is a third of the animal's width is a head
# you read at a glance, and the morning build's (9.2 long, 4.4 wide, hidden
# in the chest line) is the one that did not read at all. The widest station
# is the CRANIUM at x 4.2 and it falls away to a blunt snout at 14.8 - blunt,
# because a tapering muzzle on a creature made of mud reads as a drip.
GN_SKULL = [
    (-1.4, 27.2, 4.4, 3.1),  # the back of the skull, sunk into the neck fold
    (1.4, 27.7, 5.9, 4.1),
    (4.2, 27.9, 6.2, 4.4),  # the cranium - the top of the whole silhouette
    (6.8, 27.6, 6.0, 4.1),
    (9.4, 27.1, 5.2, 3.5),  # the cheek, and where the eyes are set
    (11.6, 26.8, 4.1, 2.8),  # the snout
    (13.2, 26.6, 3.0, 2.0),
    (14.2, 26.5, 2.1, 1.5),
    # ROUNDED OFF, not cut off. A loft's end cap is a flat disc, and on the
    # one station a player looks straight at it rendered as a pale ellipse
    # pasted on the nose. Two short stations running the radius down to 0.4
    # turn it into a nose.
    (14.8, 26.45, 1.3, 0.95),
    (15.1, 26.40, 0.4, 0.35),
]
GN_CROWN = max(cz + hh for _, cz, _, hh in GN_SKULL)  # 31.6 - GnashrootPath.CROWN

# THE BROW RIDGE, as the curve `build_gn_head` sweeps a round tube along:
# x0, BACK, z0, DROP, SPAN, r0, THIN.
#
# ACROSS THE FRONT OF THE FACE, above the eyes - and that is the correction
# the first two cuts of it both needed. Cut one was a free curve so wide that
# its flat end cap came out through the temple as a pale ellipse stuck on the
# head; cut two was seated on the skull's own surface, which cured the cap
# and put the ridge over the CROWN instead, where it read as the rim of a
# helmet. A brow is neither: it is a bar across the FRONT, jutting at the
# midline, sweeping back and down to the temples, and THINNING TO NOTHING
# there - which is what kills the end cap without hiding the ridge.
#
# A BAR, not a beak. Cut three of it jutted 2.8 studs forward at the midline
# and thinned to nothing over 5 studs, which from the side read as a second
# snout growing out of the forehead. Nearly level across the face and only
# 1.8 studs of sweep-back is a brow; the jut has to be small enough that the
# EYES are what sits under it.
#
# u runs -1..1 across the face. At u = 0 it stands a stud proud of the skull
# at x 10.6 and breaks the front surface at x 12.1; at |u| = 0.625, which is
# directly over each big eye, its underside is z 28.36 against an eye centred
# at 28.30 - so it cuts the top off both eyes. That overhang is the whole
# scowl, and it is the one hard line on an animal made of mud.
GN_BROW = (10.6, 1.8, 29.6, 0.6, 4.8, 1.5, 1.25)  # x0, back, z0, drop, span, r0, thin

# THE LOWER JAW, ceiled on the trough floor; `build_gn_jaw` then rolls a lip
# up each side to GN_JAW_RIM. Its rear is under the cranium at x 1.2 and its
# chin is at 15.0, so it hangs a little past the snout - the underbite a
# heavy mud jaw wants.
GN_JAW = [
    (1.2, 22.0, 3.4, 2.3),
    (4.6, 21.8, 4.7, 2.7),
    (8.0, 21.7, 4.7, 2.8),
    (11.0, 21.9, 3.6, 2.5),
    (13.0, 22.1, 2.4, 2.0),
    (13.9, 22.3, 1.5, 1.5),
    (14.4, 22.4, 0.5, 0.9),  # rounded, for the same reason the snout is
]
# AT THE BACK OF THE SKULL, just under the palate. The client rotates
# Jaw + Fangs + Maw about this point by -gape about Roblox Z, which takes the
# chin DOWN and BACK along its own arc: at the full 34 degrees the chin tip
# falls from z 22.4 to 14.8 and swings in to x 11.1, which still clears the
# chest (the torso's front face at that height is x 9.4). The mouth therefore
# opens as a gape at the TOP of the animal.
GN_JAW_HINGE = (0.6, 0.0, 24.9)

# THE TORSO, as rings stacked up +Z: (z, centre x, half length, half width).
#
# LOFTED VERTICALLY, and that is a redesign in itself. The morning build
# lofted the body along +X like a fish, which is why it came out as a hunched
# horizontal mound with a face somewhere in it. An upright animal is a stack
# of rings up its own axis: a base sunk in the mere, a belly, a chest, the
# widest ring at the SHOULDERS, and then a real NECK closing off into the
# skull. Read the half-width column top to bottom and the silhouette is in
# it - 9.9 at the shoulders, 3.5 at the neck.
GN_TORSO = [
    (0.0, -0.6, 9.4, 9.4),  # the foot of it, on the mere floor
    (3.2, -0.6, 9.8, 9.9),
    (6.4, -0.4, 9.7, 9.8),  # the waterline, roughly, once the apron is on
    (9.6, -0.1, 9.3, 9.4),
    (12.8, 0.3, 8.8, 8.9),  # the belly
    (15.6, 0.6, 8.4, 8.8),
    (18.2, 0.6, 8.2, 9.2),  # the chest - the core sits in its front face
    (20.4, 0.3, 7.8, 9.7),
    (21.8, -0.2, 7.2, 9.9),  # THE SHOULDERS, the widest ring on the animal
    (23.2, -0.7, 6.1, 8.9),
    (24.2, -1.0, 5.2, 7.2),  # the neck FOLD
    (25.1, -0.9, 4.4, 5.6),
    (26.0, -0.5, 3.6, 4.2),  # the neck, and from here up it is inside the skull
    (26.8, 0.0, 3.1, 3.5),
]
# How much the torso's cross-section departs from a plain ellipse. A pure
# ellipse of revolution reads as a balloon however smoothly it is shaded; a
# gentle three-lobed section reads as something that was pushed into shape.
# Kept small and COSINE - smooth by construction, where the morning build's
# random jitter was choppy by construction.
GN_TORSO_LOBE = 0.03

# THE SHOULDER SOCKETS: where the client roots each arm chain. Derived, not
# guessed - it is `_gn_torso_point(GN_SHOULDER_Z, GN_SHOULDER_BEARING)` and
# `_gn_shoulder_seat` raises at build time if the profile above ever moves
# out from under it. High on the widest ring, forward of the spine, and wide.
GN_SHOULDER_Z = 21.4
GN_SHOULDER_BEARING = 1.15  # radians round the ring; 0 is dead ahead, pi/2 is the flank
GN_SHOULDER = (2.87, 8.73, 21.40)

# THE GNASHROOT: the root-knot's seat, RECESSED IN THE CHEST HOLLOW between
# the collarbones and under the chin. Measured rather than asserted - the
# HANDOFF line re-measures the torso's front face at this height every build,
# so this paragraph cannot outlive the profile it describes.
GN_CORE = (8.2, 0.0, 16.2)
GN_CORE_RADII = (2.3, 2.5, 2.3)

# THE EYE ROW, as an ORDERED table of seats: (x, y, z, radius), authored.
#
# TWO BIG ONES AND EIGHT SMALL, where the morning build had fourteen of a
# size and no face. The first two rows are the forward-facing pair under the
# brow, r 1.6 - more than twice the area of any other seat, so they are what
# the eye finds first; the rest are r 0.7..0.85 on the cheeks and temples and
# read as a row of embers on a skull rather than as competition.
#
# THE ORDER IS LOAD-BEARING. The `Eyes` channel is a fraction 0..1 of the row
# that is LIT, applied in this order, so "the eyes open one at a time" is one
# number on one track - and FACE FIRST means the two big eyes come on before
# anything else, which is the beat the intro is built on.
#
# Every seat is on the skull, and the skull is a 32-gon loft, so the
# inscribed-polygon sag that put a morning-build eye 0.3 studs adrift is
# 0.5% of a radius here and no sink guard is needed.
# GnashrootPath.EYE_SEATS is this table and the HANDOFF prints it as Luau.
GN_EYE_SEATS = [
    (10.60, 3.00, 28.30, 1.70),  # THE eyes, hooded by the brow, forward-facing
    (10.60, -3.00, 28.30, 1.70),
    (7.60, 4.60, 28.80, 0.72),  # the temples, behind and above
    (7.60, -4.60, 28.80, 0.72),
    (4.40, 5.20, 29.60, 0.68),
    (4.40, -5.20, 29.60, 0.68),
    (12.60, 3.10, 26.60, 0.62),  # the cheeks, low and beside the snout
    (12.60, -3.10, 26.60, 0.62),
    (9.20, 4.70, 26.20, 0.66),
    (9.20, -4.70, 26.20, 0.66),
]

# ONE ARM VERTEBRA, authored mid-limb; the client tapers it by u.
#
# NEARLY A CYLINDER, and that is the "no bead look" rule as geometry. The
# first cut of this tapered the ends to 0.70 of the waist so the flat caps
# would tuck well inside the neighbour - and rendered as a string of
# sausages, because with a 34% overlap what a player sees is not the cap at
# all but the WAIST-TO-END SWELL, once per pitch. 0.92 puts that ripple at 8%
# of the girth, which reads as muscle rather than as beads, and the ends are
# still not coplanar with the barrel they slide into (the orca's z-fighting
# lesson: a constant radius overlapped by half its length stripes the flank).
GN_ARM = [
    (-1.90, 0.0, 3.10, 3.10),
    (-1.20, 0.0, 3.30, 3.30),
    (0.00, 0.0, 3.38, 3.38),
    (1.20, 0.0, 3.30, 3.30),
    (1.90, 0.0, 3.10, 3.10),
]
# EIGHT vertebrae and a fist, where the morning build had five. A five-piece
# limb on a 26-stud arc puts a 5.2-stud bone on a 5.21 pitch: every joint is
# a hinge you can see, and the limb reads as a string of beads. More, smaller
# pieces with the same overlap is a continuous tube - and it is also what
# makes a POSE BLEND smooth, because the chain samples the curve eight times
# instead of five and no segment has to turn more than a few degrees.
# The pitch is MEASURED off the rest curve at build time, not chosen; the
# HANDOFF prints it and GnashrootPath.ARM_PITCH is the same number.
GN_ARM_SEGMENTS = 8
GN_ARM_SPACING = 3.201
# Every fourth vertebra is a knuckle (Gnashroot_ArmKnot): two per arm on an
# eight-piece limb, where five pieces every third gave one lonely bead.
GN_KNOT_EVERY = 4
# THE CLIENT'S LIMB CONSTANTS, here because the preview has to be a picture
# of the game and not of a second, prettier rig. GnashrootBodyController's
# TIP_GIRTH / TIP_LENGTH / OVERLAP verbatim.
GN_ARM_TIP_TAPER = 0.50
GN_ARM_TIP_LENGTH = 0.14
GN_ARM_OVERLAP = 0.86
GN_ARM_TUBE = 3.8  # the GN_ARM loft's own length, x -1.9..1.9
GN_HAND_SEAT = 1.2  # how far the hand is seated back INTO the last vertebra
GN_HAND_REACH = 6.5  # hand origin -> fingertip along -X: 2.2 knuckle + 2.4 + 1.9

# The palm, as cross-sections along INCREASING x - the winding `loft`
# documents. Authored decreasing it comes out inside-out, and Roblox meshes
# being single-sided that renders as a dark hole with the claws in front.
GN_PALM = [
    (-2.2, 0.0, 2.6, 2.2),
    (-1.0, 0.0, 3.5, 2.9),
    (0.4, 0.0, 4.0, 3.4),
    (1.8, 0.0, 3.4, 3.0),
    (2.6, 0.0, 2.3, 2.2),
]


# ------------------------------------------------------------------ shading
#
# THE ONE FUNCTION THE WHOLE "SMOOTHEN EVERYTHING OUT" NOTE RUNS THROUGH.
# `finish` shades every object in this file FLAT, which is right for the
# rest of the pack; every Gnashroot object is handed to this instead.


def _gn_smooth(obj, angle=None):
    """Weld, seal and smooth-shade one Gnashroot object.

    Three steps, and each one is load-bearing:

      1. WELD. Every form here is built from overlapping components in one
         bmesh, and the loft's own rings duplicate verts where a profile
         repeats. Doubles left in place split the normal at a seam that has
         no business being one, which draws a hairline crease down a smooth
         flank.
      2. SEAL. Normals recalculated OUTWARD rather than trusted to the
         winding: these lofts stack rings up +Z as well as along +X and a
         mirrored component inverts its own winding. Every component is a
         closed volume, so the recalculation is exact.
      3. SMOOTH BY ANGLE. Not a blanket `use_smooth = True`, which averages a
         flat end cap into the barrel it caps and draws a dark ring at every
         joint (the lesson `_rf_smooth` learned on the orca). Blender's
         shade-smooth-by-angle writes a `sharp_edge` attribute, and the glTF
         exporter turns that into real split normals - so the .glb carries
         smooth barrels AND creased tooth tips, and Roblox renders what
         Blender showed. Verified on the export, not assumed: the NORMAL
         accessor is present and its count is split only at sharp edges.
    """
    mesh = obj.data
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-4)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.to_mesh(mesh)
    bm.free()
    for poly in mesh.polygons:
        poly.use_smooth = True
    bpy.ops.object.select_all(action="DESELECT")
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.shade_smooth_by_angle(angle=math.radians(angle or GN_SMOOTH_ANGLE))
    obj.select_set(False)
    return obj


def _gn_finish(name, bm, color, angle=None):
    """`finish`, then `_gn_smooth`. Every builder below ends on this."""
    return _gn_smooth(finish(name, bm, color), angle)


# ---------------------------------------------------------------- primitives


def _gn_blob(bm, center, radii, subdiv=2, rot=None):
    """A smooth ellipsoid - boulders, the core's knot, the deltoid swellings.

    subdivisions=2 (320 faces) rather than the morning build's 0-1 (20-80).
    An icosphere at subdivision 1 has 42 verts and reads as a cut gem however
    it is shaded; at 2 it is a ball. There are only eleven of these on the
    whole animal now, so the triangles are affordable and the read is not.
    """
    mat = Matrix.Translation(Vector(center))
    if rot is not None:
        mat = mat @ rot.to_4x4()
    mat = mat @ Matrix.Diagonal(Vector(radii)).to_4x4()
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=1.0, matrix=mat)


def _gn_taper(bm, base, tip, r0, r1, sides=None):
    """A truncated cone on an arbitrary axis - claws, drips, roots."""
    base, tip = Vector(base), Vector(tip)
    axis = tip - base
    if axis.length < 1e-6:
        return
    rot = Vector((0, 0, 1)).rotation_difference(axis.normalized()).to_matrix()
    mat = Matrix.Translation((base + tip) / 2) @ rot.to_4x4()
    bmesh.ops.create_cone(
        bm,
        cap_ends=True,
        segments=sides or GN_TUBE_SIDES,
        radius1=r0,
        radius2=r1,
        depth=axis.length,
        matrix=mat,
    )


def _gn_sweep(bm, points, radii, sides=None, cap=True):
    """A round tube THROUGH a list of points - the brow, the lip roll, the
    collarbones, a buttress root.

    The morning build drew its lip as thirteen separate cones butted end to
    end, which is thirteen pairs of flat caps inside the mud and a visible
    ring at each one. A swept tube is ONE surface: the rings are bridged, so
    there is nothing to crease and `_gn_smooth` has a continuous strip to
    average across.
    """
    pts = [Vector(p) for p in points]
    count = sides or GN_TUBE_SIDES
    rings = []
    for i, point in enumerate(pts):
        if i == 0:
            tangent = pts[1] - pts[0]
        elif i == len(pts) - 1:
            tangent = pts[-1] - pts[-2]
        else:
            tangent = pts[i + 1] - pts[i - 1]
        if tangent.length < 1e-6:
            tangent = Vector((0, 0, 1))
        rot = Vector((0, 0, 1)).rotation_difference(tangent.normalized()).to_matrix()
        radius = radii[i]
        rings.append(
            [
                tuple(point + rot @ Vector((math.cos(a) * radius, math.sin(a) * radius, 0.0)))
                for a in ((TAU * k / count) for k in range(count))
            ]
        )
    loft(bm, rings, cap_start=cap, cap_end=cap)


def _gn_profile_at(sections, key):
    """Interpolate a 4-column section table at its first column."""
    if key <= sections[0][0]:
        return sections[0][1:]
    for (k0, a0, b0, c0), (k1, a1, b1, c1) in zip(sections, sections[1:]):
        if key <= k1:
            t = 0 if k1 == k0 else (key - k0) / (k1 - k0)
            return (a0 + (a1 - a0) * t, b0 + (b1 - b0) * t, c0 + (c1 - c0) * t)
    return sections[-1][1:]


def _gn_resample(sections, step):
    """The same table, re-cut at `step` along its first column.

    THE AXIAL HALF OF THE SMOOTHING. 32 sides fixes the ring; a loft whose
    rings are 3 studs apart is still a stack of bands along its own axis,
    because the normal at a vertex is averaged from two faces that face very
    different ways. Re-cut to ~1.2 studs the surface changes direction
    slowly in BOTH parameters and the shading has nothing to step on.
    """
    lo, hi = sections[0][0], sections[-1][0]
    count = max(2, int(math.ceil((hi - lo) / step)) + 1)
    out = []
    for i in range(count):
        key = lo + (hi - lo) * i / (count - 1)
        out.append((key,) + _gn_profile_at(sections, key))
    return out


def _gn_skull_at(x):
    """The skull profile at x: (centre z, half width, half height)."""
    return _gn_profile_at(GN_SKULL, x)


def _gn_jaw_at(x):
    """The lower jaw's profile at x - what the lip and the fangs are built on."""
    return _gn_profile_at(GN_JAW, x)


def _gn_torso_at(z):
    """The torso profile at height z: (centre x, half length, half width)."""
    return _gn_profile_at(GN_TORSO, z)


def _gn_torso_ring(z, sides=None, lobe=None):
    """One cross-section of the torso, as a closed loop of points.

    Bearing 0 is dead ahead (+X) and pi/2 is its left flank (+Y). The lobe is
    a cosine in THREE times the bearing, so the section has a broad chest and
    two flatter shoulder blades and is still smooth everywhere - the thing
    random jitter can never be.
    """
    cx, hx, hy = _gn_torso_at(z)
    count = sides or GN_SIDES
    amount = GN_TORSO_LOBE if lobe is None else lobe
    pts = []
    for i in range(count):
        a = TAU * i / count
        r = 1.0 + amount * math.cos(3.0 * a)
        pts.append((cx + math.cos(a) * hx * r, math.sin(a) * hy * r, z))
    return pts


def _gn_torso_point(z, bearing, sink=0.0):
    """A point ON the torso's surface at (z, bearing), pushed `sink` inward.

    Everything set into the body - the sockets, the boulders, the drips, the
    buttress roots - is seated with this rather than hand-placed, so nothing
    floats off the animal and nothing needs a float guard.
    """
    cx, hx, hy = _gn_torso_at(z)
    r = (1.0 + GN_TORSO_LOBE * math.cos(3.0 * bearing)) * (1.0 - sink)
    return Vector((cx + math.cos(bearing) * hx * r, math.sin(bearing) * hy * r, z))


def _gn_on_skull(x, angle, sink=0.0):
    """A seat on the SKULL, floored on the palate like the skull loft.

    The skull is wider than the jaw at every x they share, so a seat taken
    here is outboard of the jaw - which is what lets a runnel come off the
    jowl past the corner of the mouth without the jaw carrying it away when
    it opens.
    """
    cz, hw, hh = _gn_skull_at(x)
    scale = 1.0 - sink
    return Vector((x, math.cos(angle) * hw * scale, max(cz + math.sin(angle) * hh * scale, GN_JAW_LINE)))


def _gn_surface_at_core():
    """The torso's FRONT face at the core's height - what "recessed" is
    measured against, and what the HANDOFF re-measures every build."""
    cx, hx, _hy = _gn_torso_at(GN_CORE[2])
    return cx + hx * (1.0 + GN_TORSO_LOBE)


def _gn_shoulder_seat():
    """The socket, derived off the torso, with GN_SHOULDER asserted against it.

    GN_SHOULDER has to be a LITERAL because GnashrootPath carries the same
    three numbers and tools/../check_rig.py diffs the two by reading this
    file's source. Deriving it here and raising on a mismatch is how the
    literal stays honest when the torso profile is re-cut.
    """
    seat = _gn_torso_point(GN_SHOULDER_Z, GN_SHOULDER_BEARING)
    if (seat - Vector(GN_SHOULDER)).length > 0.02:
        raise SystemExit(
            "GN_SHOULDER is (%.2f, %.2f, %.2f) but the torso puts the socket at (%.2f, %.2f, %.2f)"
            % (GN_SHOULDER + (seat.x, seat.y, seat.z))
        )
    return seat


# ------------------------------------------------------------------ builders


def build_gn_mass(rng):
    """The TORSO: one vertical loft, plus the two deltoids and the collarbones.

    NO SCATTER. The morning build laid 26 jittered lumps, two shoulder
    bosses, and a seven-chip "cracked plate" on top of an 11-sided loft, and
    the render came back as a heap of rocks. Everything that is not anatomy
    is gone; what is left is the shape of the animal, shaded smooth.
    """
    _ = rng
    bm = bmesh.new()
    # The body itself, re-cut to ~1.1 studs of height per ring.
    loft(bm, [_gn_torso_ring(z) for z, _cx, _hx, _hy in _gn_resample(GN_TORSO, 1.1)])
    # THE DELTOIDS. The sockets are authored points the arms are rooted at, so
    # there has to be real mud there for the first vertebra to sit in - and a
    # limb this heavy needs a swelling to come out of or it reads as a hose
    # taped to a balloon. Centred just inboard of the socket and reaching out
    # past it, so the arm emerges FROM the shoulder rather than beside it.
    seat = _gn_shoulder_seat()
    for side in (-1, 1):
        _gn_blob(bm, (seat.x - 0.4, side * (seat.y - 1.2), seat.z - 0.6), (4.4, 4.2, 3.6))
        _gn_blob(bm, (seat.x - 1.8, side * (seat.y - 2.6), seat.z - 3.4), (4.0, 3.8, 3.4))
    # THE COLLARBONES, and they are what makes the core read as being IN a
    # chest rather than stuck on one: two tubes running down and in from the
    # sockets to either side of the knot, so the hollow between them is a
    # place and the ember is in it.
    for side in (-1, 1):
        _gn_sweep(
            bm,
            [
                (seat.x - 0.6, side * (seat.y - 1.0), seat.z - 1.6),
                (5.0, side * 6.4, 19.4),
                (7.2, side * 3.4, 17.8),
                (8.0, side * 1.8, 17.1),
            ],
            [1.9, 1.6, 1.25, 1.0],
        )
    # THE PECTORALS. Two broad swells either side of the sternum hollow, so
    # the chest is a chest: without them the front of the torso is a plain
    # curve and the ember reads as a lamp hung on a wall rather than as
    # something burning IN something.
    for side in (-1, 1):
        _gn_blob(bm, (5.2, side * 4.6, 18.0), (4.4, 4.6, 3.4))
    # THE COUNTERWEIGHT AT THE BACK: a single smooth hump over the shoulder
    # blades, so the silhouette from behind is not a cylinder.
    _gn_blob(bm, (-5.4, 0.0, 20.4), (5.2, 8.0, 4.6))
    return _gn_finish("Gnashroot_Mass", bm, GN_MUD)


def build_gn_roots(rng):
    """WHAT REPLACES THE LEGS: buttress roots and a mud apron.

    The apron is now ONE SURFACE - a ring of profiles swept round the body
    and lofted - where the morning build heaped 36 jittered icospheres into a
    field of facets. A mound that is actually a mound shades as wet mud;
    thirty-six balls never will, at any subdivision.
    """
    bm = bmesh.new()
    # THE APRON. Radial profiles: (radius, height). The inner ring hugs the
    # torso at the waterline and the outer one dies into the mere at z 0.
    # LOW AND WIDE. The first cut of this stood 4.6 studs at the waist and
    # cut off at r 19.8, which rendered as a pancake pedestal the animal was
    # standing on - a plinth, not a mire. Half the height and a longer, more
    # gradual outer fade reads as mud heaped round something that has sunk
    # into it, which is what it is.
    profile = ((5.0, 3.1), (8.8, 2.8), (12.4, 2.0), (15.8, 1.1), (18.8, 0.45), (21.4, 0.0))
    rings = []
    for radius, height in profile:
        ring = []
        for i in range(GN_SIDES):
            a = TAU * i / GN_SIDES
            # A slow two- and five-lobed swell, so the apron is not a cone of
            # revolution. Cosines again: smooth by construction.
            swell = 1.0 + 0.11 * math.cos(2.0 * a + 0.6) + 0.05 * math.cos(5.0 * a)
            ring.append(
                (
                    -0.8 + math.cos(a) * radius * swell,
                    math.sin(a) * radius * swell,
                    height * (0.94 + 0.10 * math.cos(3.0 * a + 1.2)),
                )
            )
        rings.append(ring)
    loft(bm, rings, cap_start=True, cap_end=True)
    # SIX BUTTRESSES, swept out of the torso's lower flank and down into the
    # apron. Each one is seated with `_gn_torso_point`, so it touches the body
    # it grows from and the whole animal is one connected mass for
    # tools/check_posed_connectivity.py.
    for i in range(6):
        bearing = TAU * (i + 0.5) / 6 + 0.35
        z = 7.6 + 2.2 * math.cos(bearing * 1.7)
        seat = _gn_torso_point(z, bearing, sink=0.10)
        out = Vector(
            (
                -0.8 + math.cos(bearing) * 13.0,
                math.sin(bearing) * 13.0,
                0.8,
            )
        )
        knee = seat.lerp(out, 0.55) + Vector((0, 0, 0.6))
        _gn_sweep(
            bm,
            [tuple(seat), tuple(seat.lerp(knee, 0.5)), tuple(knee), tuple(out)],
            [2.6, 2.0, 1.3, 0.55],
        )
    _ = rng
    return _gn_finish("Gnashroot_Roots", bm, GN_MUD)


def build_gn_head(rng):
    """THE SKULL, and the brow ridge that makes it a face.

    One loft, floored on the palate, re-cut to ~1.0 studs along its length,
    plus ONE swept tube for the brow. That is the whole head: the morning
    build's nine random warts and two rotated boxes are gone, and with them
    the last of the "heap of rocks" read.
    """
    _ = rng
    bm = bmesh.new()
    loft(
        bm,
        [
            ring_pts(x, cz, hw, hh, sides=GN_SIDES, floor_z=GN_JAW_LINE)
            for x, cz, hw, hh in _gn_resample(GN_SKULL, 1.0)
        ],
    )
    # THE BROW, across the front of the face: 25 stations on one swept tube,
    # so it is a single smooth surface with no joint in it, and its radius
    # runs out to 0.25 at the temples so the end cap is too small to read.
    x0, back, z0, drop, span, r0, thin = GN_BROW
    points, radii = [], []
    for i in range(25):
        u = -1.0 + 2.0 * i / 24.0
        points.append((x0 - back * u * u, u * span, z0 - drop * u * u))
        radii.append(r0 - thin * u * u)
    _gn_sweep(bm, points, radii)
    # THE CHEEKBONES. The brow frames each eye from above; without something
    # under it the eye sits on a bare curve and reads as a pebble pressed
    # into mud. A zygomatic sweep from beside the snout back to the temple
    # gives the socket a floor, and gives the whole skull the one horizontal
    # line that says "this is a face" from the side.
    for side in (-1, 1):
        _gn_sweep(
            bm,
            [
                (12.4, side * 3.3, 26.3),
                (10.0, side * 4.9, 26.7),
                (7.0, side * 5.6, 27.3),
                (4.2, side * 5.6, 28.2),
            ],
            [0.55, 0.85, 0.95, 0.60],
        )
    return _gn_finish("Gnashroot_Head", bm, GN_MUD)


def build_gn_jaw(rng):
    """The lower jaw, as a TROUGH with a rolled lip.

    The loft is ceiled on GN_JAW_TROUGH - the FLOOR of the mouth - and a lip
    is then SWEPT up each side to GN_JAW_RIM, 0.2 studs under the palate.
    Everything the lower jaw carries lives between those lips and under them,
    so no part of it can stand above the upper jaw at any gape, and a shut
    mouth reads as a seam rather than as a slot.
    """
    _ = rng
    bm = bmesh.new()
    loft(
        bm,
        [
            ring_pts(x, cz, hw, hh, sides=GN_SIDES, ceil_z=GN_JAW_TROUGH)
            for x, cz, hw, hh in _gn_resample(GN_JAW, 1.0)
        ],
    )
    # THE LIP, as ONE swept roll per side rather than a chain of cones. Its
    # radius and centre span the trough floor to the rim exactly, so there is
    # no slot under it, and it follows the jaw's own half width so it curves
    # with the mouth.
    lip_r = (GN_JAW_RIM - GN_JAW_TROUGH) / 2
    lip_z = GN_JAW_TROUGH + lip_r
    edge = []
    for i in range(19):
        x = 1.4 + (i / 18.0) * 12.8
        _cz, hw, _hh = _gn_jaw_at(x)
        edge.append((x, max(hw - 0.8, 0.35)))
    for side in (-1, 1):
        _gn_sweep(bm, [(x, side * w, lip_z) for x, w in edge], [lip_r] * len(edge))
    # ...and closed across the chin, or the trough is a gutter open at the end.
    x_tip, w_tip = edge[-1]
    _gn_sweep(
        bm,
        [(x_tip, -w_tip, lip_z), (x_tip + 0.5, 0.0, lip_z), (x_tip, w_tip, lip_z)],
        [lip_r, lip_r, lip_r],
    )
    return _gn_finish("Gnashroot_Jaw", bm, GN_MUD)


def build_gn_maw():
    """The throat: a dark volume filling the gape, so an open mouth reads as a
    HOLE and not as a gap you can see the arena through. It fills the trough
    exactly and rides the JAW frame, so it swings out with the chin."""
    bm = bmesh.new()
    loft(
        bm,
        [
            ring_pts(x, (GN_JAW_TROUGH + GN_JAW_LINE) / 2, hw, 1.3, sides=GN_LIMB_SIDES,
                     floor_z=GN_JAW_TROUGH + 0.06, ceil_z=GN_JAW_LINE - 0.06)
            for x, hw in ((2.0, 3.0), (5.0, 4.2), (8.4, 4.3), (11.4, 3.4), (13.8, 2.1), (14.7, 1.1))
        ],
    )
    return _gn_finish("Gnashroot_Maw", bm, GN_DARK)


def build_gn_teeth(rng):
    """The SKULL's row: splinters hanging from the palate.

    Its own object because it rides its own frame - authored into `Fangs`,
    which the client rotates with the jaw, the upper row swung down with the
    chin and left the roof of the mouth bare.

    Interdigitated with the lower row and stopped inside the trough: a palate
    tooth longer than the trough is deep pokes out under the chin when the
    mouth is shut.
    """
    bm = bmesh.new()
    for i in range(6):
        x = 3.4 + i * 1.9
        _cz, hw, _hh = _gn_jaw_at(x)
        spread = hw * 0.56
        length = (2.1 if i in (1, 3) else 1.4) * rng.uniform(0.94, 1.05)
        stop = max(GN_JAW_LINE - length, GN_JAW_TROUGH + 0.2)
        for side in (-1, 1):
            spike(bm, (x, side * spread, GN_JAW_LINE + 0.2), (x, side * spread * 0.94, stop), 0.36, sides=10)
    return _gn_finish("Gnashroot_Teeth", bm, GN_FANG)


def build_gn_fangs(rng):
    """The JAW's row: splinters rising off the trough's floor.

    Every tip is clamped under GN_JAW_RIM, which is itself under the palate,
    and the assert is real: it raises rather than shipping a lower jaw that
    stands above the upper one again.
    """
    bm = bmesh.new()
    ceiling = GN_JAW_RIM - 0.1
    for i in range(6):
        x = 4.3 + i * 1.9
        _cz, hw, _hh = _gn_jaw_at(x)
        spread = hw * 0.48
        length = (2.1 if i in (0, 2, 4) else 1.4) * rng.uniform(0.94, 1.05)
        base = GN_JAW_TROUGH - 0.3
        tip = min(base + length, ceiling)
        if tip > GN_JAW_LINE:
            raise SystemExit("Gnashroot fang at x %.1f tips at %.2f, above the palate %.2f" % (x, tip, GN_JAW_LINE))
        for side in (-1, 1):
            spike(bm, (x, side * spread, base), (x, side * spread * 0.95, tip), 0.32, sides=10)
    return _gn_finish("Gnashroot_Fangs", bm, GN_FANG)


def build_gn_eye(rng):
    """ONE eye, at the origin, radius 1 - the client instances it per seat.

    A MODULE rather than a baked scatter, because the fight needs to light
    ONE cluster and not its neighbour (the intro's "the eyes open one at a
    time", and the `Eyes` channel generally), and a single mesh has one
    Material and one Transparency.

    subdivisions=2 now, not 1: the two big seats are 1.6 authored (4.8 world
    studs across) and sit at the focal point of the whole design, so their
    silhouette absolutely does survive to the screen.
    """
    _ = rng
    bm = bmesh.new()
    _gn_blob(bm, (0.0, 0.0, 0.0), (1.0, 1.0, 0.92), subdiv=2)
    return _gn_finish("Gnashroot_Eye", bm, GN_EYE)


def build_gn_core(rng):
    """THE GNASHROOT: the ember-lit root-knot, recessed in the chest hollow.

    The object NAME does not change: GnashrootBodyController asserts
    Material.Neon on `Gnashroot_Core` by name, GnashrootPath.CORE is the HUD
    marker and the server's punish target, and the import row names it.
    """
    _ = rng
    bm = bmesh.new()
    _gn_blob(bm, GN_CORE, GN_CORE_RADII, subdiv=2)
    # SIX SHORT SHARDS, fanned up and out of the knot and stopped before they
    # read as a second silhouette. The morning build's eight ragged spines
    # were the thing that made a chest ember look like a bush.
    for i in range(6):
        angle = math.radians(30 + i * 24)
        reach = 1.9
        _gn_taper(
            bm,
            GN_CORE,
            (
                GN_CORE[0] + 0.9,
                math.cos(angle) * reach,
                GN_CORE[2] + math.sin(angle) * reach,
            ),
            0.42,
            0.12,
            sides=8,
        )
    return _gn_finish("Gnashroot_Core", bm, GN_WISP)


def build_gn_stones(rng):
    """FOUR boulders, and that is the whole object.

    It was sixteen angular chips at subdivision 0, scattered over the back
    and the shoulders - a third of the "heap of rocks" the user saw. Four big
    rounded ones on the back and the shoulder tops read as boulders the fen
    dropped on it, and nothing else on the animal has to compete with the
    head for attention.
    """
    _ = rng
    bm = bmesh.new()
    for z, bearing, radii in (
        (19.6, 2.55, (3.4, 3.0, 2.5)),
        (16.8, -2.35, (3.0, 2.8, 2.3)),
        (20.8, 3.05, (3.9, 3.6, 3.0)),
        (12.6, -2.95, (3.2, 3.0, 2.5)),
    ):
        _gn_blob(bm, _gn_torso_point(z, bearing, sink=0.22), radii, subdiv=2)
    return _gn_finish("Gnashroot_Stones", bm, GN_STONE)


def build_gn_drips(rng):
    """TEN runnels, down the jowls and under the shoulders, and nowhere else.

    The brief is "drips only under the chin and elbows", and the chin half of
    it has to be taken off the JOWL rather than off the chin itself: `Drips`
    rides the BODY frame, so a runnel seated on the jaw hangs in mid-air the
    moment the chin drops. The skull is wider than the jaw at every shared x,
    so a jowl runnel is outboard of the corner of the mouth and the jaw never
    reaches it at any gape. The elbow half is taken off the DELTOID, which is
    the nearest thing to an elbow that is on this frame at all.
    """
    bm = bmesh.new()
    seat = _gn_shoulder_seat()
    for side in (-1, 1):
        # The jowls: three each, running down the cheek past the mouth and
        # stopped above the rim so nothing hangs into the gape.
        for i in range(2):
            # BEHIND THE EYE, AND TRACED ON THE SKULL. Three earlier cuts of
            # this all failed the same way: a runnel authored as a straight
            # drop from a seat on the cheek leaves the surface immediately,
            # because the cheek narrows as it falls - so it hung in the air
            # beside the head as a thin spike, which read first as a tusk and
            # then as a whisker. Walking `_gn_on_skull` DOWN in four steps
            # keeps every station on the jowl, so the runnel hugs the face
            # the whole way and no part of it is ever in open air.
            x = 3.0 + i * 2.4
            top = math.radians(4 - i * 6)
            points, radii = [], []
            for k in range(4):
                point = _gn_on_skull(x, top - k * 0.30, sink=-0.04)
                point.y *= side
                points.append(tuple(point))
                radii.append(0.46 - 0.11 * k)
            _gn_sweep(bm, points, radii)
        # ...and three off the underside of each shoulder, which is the
        # nearest thing to an elbow that rides the BODY frame at all.
        #
        # TRACED ON THE TORSO, for the same reason the jowl runnels are
        # traced on the skull - and here the failure was the other way round
        # and INVISIBLE. Authored as a straight drop from a point near the
        # socket, the third runnel started INSIDE the torso and stayed inside
        # it the whole way down (the body widens as it falls), so nothing of
        # it ever reached a surface: tools/check_posed_connectivity.py
        # reported it adrift with a 0.96-stud gap, and in the render it was
        # simply not there. Walked down the torso's own surface it is on the
        # flank at every station.
        for i in range(3):
            bearing = GN_SHOULDER_BEARING + (i - 1) * 0.22
            top = seat.z - 5.0 - i * 1.4
            points, radii = [], []
            for k in range(4):
                point = _gn_torso_point(top - k * rng.uniform(1.3, 1.9), bearing, sink=-0.02)
                point.y *= side
                points.append(tuple(point))
                radii.append(0.80 - 0.20 * k)
            _gn_sweep(
                bm,
                points,
                radii,
            )
    return _gn_finish("Gnashroot_Drips", bm, GN_DARK)


def build_gn_arm():
    """One vertebra: a barrel rounded at both ends, 24 sides, smooth."""
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=GN_LIMB_SIDES) for x, cz, hw, hh in GN_ARM])
    return _gn_finish("Gnashroot_Arm", bm, GN_MUD)


def build_gn_arm_knot():
    """Every fourth vertebra: the same barrel with a gentle swell on it.

    A SWELL, not the morning build's lump-and-three-drips. On an eight-piece
    limb a knuckle every four is two per arm, and the point of them is that
    the tube is not perfectly uniform - not that there is a bead on it.
    """
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=GN_LIMB_SIDES) for x, cz, hw, hh in GN_ARM])
    _gn_blob(bm, (0.0, 0.0, -0.55), (2.4, 3.9, 3.5), subdiv=2)
    return _gn_finish("Gnashroot_ArmKnot", bm, GN_MUD)


def build_gn_hand(rng):
    """The fist: a heavy palm and three thick claws with a thumb.

    +X runs up-limb toward the body, so the claws reach toward -X - this is
    what the slam lands on. Each claw is a SWEPT tube rather than two butted
    cones, so it curves into the palm instead of stepping into it.
    """
    _ = rng
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=GN_LIMB_SIDES) for x, cz, hw, hh in GN_PALM])
    for i in range(3):
        spread = (i - 1.0) * 2.6
        knuckle = Vector((-1.4, spread, -0.4))
        mid = knuckle + Vector((-2.3, spread * 0.20, -1.2))
        tip = mid + Vector((-2.0, spread * 0.16, -1.7))
        # BLUNT, not pointed: these are root knots the animal plants its
        # weight on, and a claw that runs to a spike reads as a bird's talon.
        _gn_sweep(bm, [tuple(knuckle), tuple(mid), tuple(tip)], [1.95, 1.55, 0.75])
    thumb = Vector((0.4, 3.4, -0.9))
    thumb_mid = thumb + Vector((-1.9, 1.5, -1.0))
    _gn_sweep(
        bm,
        [tuple(thumb), tuple(thumb_mid), tuple(thumb_mid + Vector((-1.5, 0.8, -1.0)))],
        [1.6, 1.25, 0.65],
    )
    return _gn_finish("Gnashroot_Hand", bm, GN_MUD)


def build_gnashroot():
    rng = random.Random(8821)
    objects = [
        build_gn_mass(rng),
        build_gn_roots(rng),
        build_gn_head(rng),
        build_gn_jaw(rng),
        build_gn_maw(),
        build_gn_teeth(rng),
        build_gn_fangs(rng),
        build_gn_eye(rng),
        build_gn_core(rng),
        build_gn_stones(rng),
        build_gn_drips(rng),
        build_gn_arm(),
        build_gn_arm_knot(),
        build_gn_hand(rng),
    ]
    # Every number below is DERIVED from the constants above, not retyped
    # beside them.
    seat = _gn_shoulder_seat()
    at_length, tangent_at, arc = _arc_walker(lambda t: _gn_arm_path(1, t))
    wrist = at_length(arc)
    straight = (wrist - Vector(GN_SHOULDER)).length
    _ = tangent_at
    total_tris = 0
    print("HANDOFF gnashroot: TRIANGLES, per object -")
    for obj in objects:
        obj.data.calc_loop_triangles()
        count = len(obj.data.loop_triangles)
        total_tris += count
        smooth = sum(1 for p in obj.data.polygons if p.use_smooth)
        print(
            "  %-20s %6d tris, %d/%d faces smooth"
            % (obj.name, count, smooth, len(obj.data.polygons))
        )
    print(
        "HANDOFF gnashroot: %d tris over %d objects (the Eye is drawn %d times and the limb %d, so the "
        "DRAWN total is higher than the pack's)"
        % (total_tris, len(objects), len(GN_EYE_SEATS), 2 * (GN_ARM_SEGMENTS + 1))
    )
    print(
        "HANDOFF gnashroot: ROOTED, and it READS TOP-DOWN - skull z %.1f..%.1f (CROWN %.1f), palate %.1f, "
        "jaw rim %.1f, trough %.1f, shoulders z %.1f, core z %.1f, torso foot z 0. THE MOUTH IS THE TOP-FRONT "
        "OF THE SILHOUETTE, which is the whole of the second pass."
        % (GN_JAW_LINE, GN_CROWN, GN_CROWN, GN_JAW_LINE, GN_JAW_RIM, GN_JAW_TROUGH, GN_SHOULDER_Z, GN_CORE[2])
    )
    print(
        "HANDOFF gnashroot: jaw hinge (%.1f, %.1f, %.1f) - the BACK of the skull. The client rotates "
        "Jaw + Fangs + Maw about it, NEGATIVE Z (the chin goes DOWN and BACK)." % GN_JAW_HINGE
    )
    print("HANDOFF gnashroot: TEETH is the SKULL's palate row and rides the BODY frame - do NOT hinge it with the jaw; FANGS is the jaw's row and does")
    print("HANDOFF gnashroot: DRIPS rides the BODY frame too - its 4 head runnels are TRACED DOWN THE JOWLS, outboard of the jaw at every shared x, and must not be hinged")
    print(
        "HANDOFF gnashroot: shoulder sockets (%.2f, +/-%.2f, %.2f) - root each arm chain here. DERIVED off "
        "the torso ring at z %.1f, bearing %.2f rad; build_gn_mass sets a deltoid on each one."
        % (GN_SHOULDER + (GN_SHOULDER_Z, GN_SHOULDER_BEARING))
    )
    print("HANDOFF gnashroot: torso half-width %.1f at the shoulders -> the row's hitRadius 6 covers the core, not the reach"
          % max(hy for _, _, _, hy in GN_TORSO))
    print(
        "HANDOFF gnashroot: CORE at (%.1f, %.1f, %.1f) radii (%.1f, %.1f, %.1f) - Neon, the expose-window "
        "target, RECESSED IN THE CHEST between the collarbones and under the chin. The torso's front face at "
        "z %.1f is x %.2f and the knot's front is %.2f, so %.2f studs of it stand proud and the rest is in the "
        "chest. The jaw's underside at that x is z %.2f, %.2f clear of the knot's crown."
        % (GN_CORE[0], GN_CORE[1], GN_CORE[2], GN_CORE_RADII[0], GN_CORE_RADII[1], GN_CORE_RADII[2],
           GN_CORE[2], _gn_surface_at_core(), GN_CORE[0] + GN_CORE_RADII[0],
           GN_CORE[0] + GN_CORE_RADII[0] - _gn_surface_at_core(),
           _gn_jaw_at(GN_CORE[0])[0] - _gn_jaw_at(GN_CORE[0])[2],
           (_gn_jaw_at(GN_CORE[0])[0] - _gn_jaw_at(GN_CORE[0])[2]) - (GN_CORE[2] + GN_CORE_RADII[2]))
    )
    print(
        "HANDOFF gnashroot: EYES are %d INSTANCES of one object (Gnashroot_Eye) - TWO BIG ONES (r %.2f, under "
        "the brow, forward-facing) and %d small ones on the cheeks and temples. The client places each seat "
        "off the body CFrame and lights them IN THIS ORDER off the client-only `Eyes` channel (0..1, nil = all "
        "lit), so the two that read as THE eyes are the two that open first. GnashrootPath.EYE_SEATS must be "
        "this table:" % (len(GN_EYE_SEATS), GN_EYE_SEATS[0][3], len(GN_EYE_SEATS) - 2)
    )
    print("local EYE_SEATS = {")
    for eye_seat in GN_EYE_SEATS:
        print("\t{ %.2f, %.2f, %.2f, %.2f }," % eye_seat)
    print("}")
    print(
        "HANDOFF gnashroot: arm pitch %.2f, %d segments + hand. MEASURED off the rest curve _gn_arm_path "
        "walks - shoulder->wrist is %.3f studs of arc (%.2f straight) and the rest fist stands at radius "
        "%.2f (%.1f world). GnashrootPath.ARM_PITCH must be %.3f. Eight segments, not five: a %.1f-stud "
        "vertebra on a %.2f pitch overlaps by %.0f%% and the limb reads as a tube instead of a string of beads."
        % (GN_ARM_SPACING, GN_ARM_SEGMENTS, arc, straight,
           math.hypot(wrist.x, wrist.y), math.hypot(wrist.x, wrist.y) * 1.5, arc / GN_ARM_SEGMENTS,
           GN_ARM_TUBE, arc / GN_ARM_SEGMENTS, 100.0 * (1.0 - (arc / GN_ARM_SEGMENTS) / GN_ARM_TUBE))
    )
    for name in sorted(GN_POSE):
        _elbow, w = GN_POSE[name]
        _al, _tg, pose_arc = _arc_walker(lambda t, n=name: _gn_arm_path(1, t, n))
        radius = math.hypot(w[0], w[1])
        print(
            "  %-13s arc %6.2f (stretch %.3f of rest), fist at r %5.2f = %5.1f world, fingertips ~%5.1f world"
            % (name, pose_arc, pose_arc / arc, radius, radius * 1.5,
               (radius + GN_HAND_REACH * (1.0 - GN_ARM_TIP_TAPER)) * 1.5)
        )
    print(
        "HANDOFF gnashroot: so a ROOTED colossus reaches %0.0f world studs of bank with its fists (the Rootmere "
        "is r 27 and the walkable bank r 29-70) - hammerfall's ring and the row's tell radii are sized off that "
        "number, not off the body."
        % max(
            (math.hypot(w[0], w[1]) + GN_HAND_REACH * (1.0 - GN_ARM_TIP_TAPER)) * 1.5
            for name, (_e, w) in GN_POSE.items()
            if name not in ("hammerRaised", "disgorge")
        )
    )
    print("HANDOFF gnashroot: arm half-width %.2f at scale 1 -> slam hit girth ~%.0f studs; taper by u toward the hand"
          % (max(hw for _, _, hw, _ in GN_ARM), 2 * max(hw for _, _, hw, _ in GN_ARM)))
    print(
        "HANDOFF gnashroot: OBJECTS (14) - Mass Roots Head Jaw Maw Teeth Fangs Eye Core Stones Drips Arm "
        "ArmKnot Hand. Same names as the morning build, ALL REBUILT: re-import the whole pack. The Eye is "
        "instanced %d times now (was 14) and the limb is %d vertebrae per arm (was 5)."
        % (len(GN_EYE_SEATS), GN_ARM_SEGMENTS)
    )
    _ = seat
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
# Scale contract: the row spawns her at 2.4 with hitRadius 6, so the skull's
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

# THE HEAD IS A MOUTH WITH A SKULL BEHIND IT (user, 2026-09-08: the old head
# was "way too big and stupid" - redesign it as an anglerfish). The cranium
# used to stand 5.6 studs over its own palate with a brow shelf and a pair of
# horns on top of that, which made the silhouette a boulder with a slot in it.
# An angler is the other way round: the jaw is the whole animal and the
# braincase is a tapering afterthought behind it. So every section here is LOW
# - the crown tops out at 1.4 - while the WIDTH is untouched, because the
# palate has to keep covering the room the party stands in (NC_JAW's 5.6
# half-width, which is NoctyssPath.insideMouth's own |Z| bound). The skull got
# shorter, never narrower.
#
# SHAVED AGAIN, 2026-09-09 (user: the head "doesn't fit in the hole and
# obstructs everything"). The pit IS her mouth, so anything standing over the
# hole is the thing in the way of reading that - and the outer top surface of
# this loft was standing 2.7 over the origin while the room underneath it is
# bounded by NC_JAW_LINE at -1.0. Everything between those two numbers is
# hide, not room. The `floor_z=NC_JAW_LINE` clamp in `build_nc_skull` means
# every section's UNDERSIDE is flat at -1.0 regardless of what cz and hh say
# (each bottom below is <= -1.0, so the clamp still bites everywhere), so the
# interior the party stands in is bit-identical and only the outside came
# down. Crown 2.7 -> 1.40, palate over the room 2.25 -> 1.15, and the snout
# roof is now a 0.55-thick blade: as low as the interior permits.
NC_SKULL = [
    (-9.6, -0.45, 1.9, 1.00),  # the braincase: what is left of it. top 0.55
    (-8.0, -0.30, 3.2, 1.35),  # top 1.05
    (-5.6, -0.20, 5.0, 1.55),  # top 1.35
    (-3.4, -0.20, 6.0, 1.60),  # widest - the hitRadius contract, unchanged. top 1.40
    (0.0, -0.35, 5.9, 1.50),  # the palate over the room: wide and FLAT. top 1.15
    (4.0, -0.60, 4.6, 1.20),  # top 0.60
    (7.6, -0.80, 3.0, 0.75),  # top -0.05: the snout roof is under the origin now
    (11.5, -1.00, 1.0, 0.55),  # snout tip, where the illicium is rooted. top -0.45
]

# The tooth line, as (x, half width) - ONE curve, sampled by both jaws, so the
# upper and lower needles interlock instead of passing each other. It follows
# NC_JAW's rim, because the lower jaw is the one that has to close onto the
# other set.
NC_RIM = [(-8.6, 2.8), (-5.2, 5.0), (-1.2, 5.6), (2.8, 4.9), (6.6, 3.4), (10.2, 1.6)]

# THE DOORWAY. Forward of this x both jaws are BARE on the centreline: the
# punish window is players walking INTO the mouth (NoctyssPath.mawMouth is a
# room, not a hitbox), and a palisade across the front of it is a wall. The
# fangs that frame the gap splay OUTWARD instead, so the entrance reads as a
# gate between two rows rather than as a mesh she forgot to close.
NC_DOOR_X = 6.9
NC_DOOR_HALF = 3.1  # nothing stands inside this half-width forward of the door

# THE ILLICIUM: the rod off the snout, and the esca it dangles over the
# entrance. She is an angler, and every other light in this fight is a lure -
# so the head carries one too, and it hangs directly over the mouth a player
# is being invited to walk into. Control points, in the skull's space; the
# esca is slung off the tip.
#
# IT WAS A MAST, 2026-09-09. The old arch climbed to z 10.6 in the skull's own
# space, and the maw is pitched nose-UP - so the pitch rotates x into height
# too, and the lit tip ended up sixty-three studs over the arena floor: the
# single tallest thing in the fight, on a boss whose entire read is that the
# HOLE IS THE MOUTH. It is the same idea at a fifth of the reach and hung the
# other way up. The rod runs FORWARD off the snout and hooks straight DOWN in
# the skull's frame - which, once the 21-degree pitch is applied, is an arc
# that leaves the nose, tops out barely a stud over the snout and drops the
# esca in front of the mouth, roughly level between the two lips. Nothing on
# this rod is now higher than the snout it grows out of, and the esca is the
# only thing hanging over the lane the party walks in on: a lantern in the
# dark with a hole underneath it, which is the whole trick.
NC_ILLICIUM = [
    (10.6, 0.0, -0.30),  # rooted on the snout roof, which is under the origin now
    (12.4, 0.0, -0.80),
    (13.9, 0.0, -1.80),  # forward past the snout tip at 11.5, and already falling
    (14.6, 0.0, -3.40),  # the knee of the hook - and the reach is capped here so
    (14.2, 0.0, -5.00),  # that nothing on her crosses the choir's r34 socket ring
    (13.3, 0.0, -6.00),
]
NC_ESCA = (12.5, 0.0, -6.80)  # slung off the hook, forward of the open jaw's lip
NC_ESCA_R = 1.15

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


def _nc_rim(x):
    """Half-width of the tooth line at `x` - NC_RIM, linearly sampled."""
    if x <= NC_RIM[0][0]:
        return NC_RIM[0][1]
    if x >= NC_RIM[-1][0]:
        return NC_RIM[-1][1]
    for (x0, w0), (x1, w1) in zip(NC_RIM, NC_RIM[1:]):
        if x0 <= x <= x1:
            return w0 + (w1 - w0) * (x - x0) / (x1 - x0)
    return NC_RIM[-1][1]


def _nc_fang(bm, x, side, z_root, direction, length, radius, rng):
    """One needle fang, in TWO cones so it curves instead of spiking.

    An angler's teeth are not a picket fence: they are thin, uneven, and they
    hook INWARD and BACK toward the throat, which is what turns a mouth into a
    trap you can swim into and not out of. `direction` is -1 for the upper set
    (hanging off the palate) and +1 for the lower (standing off the jaw rim).

    The hook REVERSES near the front (`lean` goes negative past x = 3.0): the
    fangs bracketing the doorway splay outward, away from the corridor players
    walk down, so the mouth's own teeth frame the entrance instead of barring
    it.
    """
    rim = _nc_rim(x)
    lean = (0.40 if x < 3.0 else -0.30) * length
    sweep = -0.30 * length  # toward the throat
    base = Vector((x, side * rim, z_root))
    mid = Vector((x + sweep * 0.35, side * (rim - lean * 0.30), z_root + direction * length * 0.58))
    tip = Vector((x + sweep, side * (rim - lean), z_root + direction * length))
    spike(bm, tuple(base), tuple(mid), radius, sides=4)
    spike(bm, tuple(mid), tuple(tip), radius * 0.62, sides=4)


def _nc_tooth_line(bm, count, x_front, x_back, z_root, direction, rng, phase=0.0, trim=0.0):
    """A row of needles down one jaw, both sides, skipping the doorway.

    `trim` shortens every needle in the row by that many authored units (down
    to the 0.9 floor). It exists for ONE reason: the upper row hangs over the
    room the party stands in, so its length is a headroom number as well as a
    silhouette number - see the call in `build_nc_skull_bone`.
    """
    for i in range(count):
        t = (i + phase) / max(count - 1 + phase, 1e-6)
        x = x_front - t * (x_front - x_back)
        if x > NC_DOOR_X and _nc_rim(x) < NC_DOOR_HALF:
            continue  # the gate: nothing on the centreline forward of the door
        # Irregular on purpose. A row of identical needles reads as a comb;
        # what a player is meant to see over their head is something GROWN.
        length = max(0.9, 1.3 + 2.1 * t + rng.uniform(-0.5, 0.6) - trim)
        radius = 0.14 + 0.050 * length
        for side in (-1, 1):
            _nc_fang(bm, x + rng.uniform(-0.12, 0.12), side, z_root, direction, length, radius, rng)


def build_nc_skull(rng):
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=9, floor_z=NC_JAW_LINE) for x, cz, hw, hh in NC_SKULL])
    # A brow RIDGE, not a brow shelf. The old ledge was a 9 x 8 stud slab of
    # hide over the eyes and it is most of what made the head read as a boulder;
    # this is a thin raked lip that still throws the eyes into shadow, on a
    # skull less than half as tall.
    for side in (-1, 1):
        blade(bm, (-4.6, side * 4.4, 0.45), (1.8, side * 4.2, -0.05), 1.5, 0.9, 0.35, roll=math.radians(74))
    # A keel down the crown, and a ridge back off each eye. A skull this flat
    # is a plate from every angle a player gets unless something breaks the
    # surface up: these three lines are what stop the head reading as a smooth
    # wedge when a single lantern rakes it from the side.
    #
    # LOW KEEL, 2026-09-09. Rolled 90 degrees the blade's WIDTH is its height,
    # so 1.9 wide at z 0.9 stood 1.85 over the origin - a fin on a skull that
    # now tops out at 1.40. Narrower and lower: it still breaks the raking
    # light, it no longer out-tops the crown it is supposed to be a line on.
    blade(bm, (-7.6, 0, 0.35), (4.2, 0, 0.1), 1.4, 0.8, 0.40, roll=math.radians(90))
    for side in (-1, 1):
        blade(bm, (-1.0, side * 4.5, 0.0), (-7.8, side * 2.8, -0.3), 1.2, 0.7, 0.30, roll=math.radians(80))
    # Four low spines walking up the keel, biggest over the throat.
    for i in range(4):
        x = -6.4 + i * 2.6
        spike(bm, (x, 0, 0.35), (x - 0.9, 0, 0.85 + (3 - i) * 0.18), 0.30, sides=4)
    # HOOD FOLDS off the back of the skull, echoing the choir's hoods: loose
    # membrane running off the braincase and down what would be the neck, so
    # the head does not simply stop at the back of the loft.
    for side in (-1, 1):
        for k in range(3):
            base = Vector((-5.2 - k * 1.3, side * (4.4 - k * 0.7), 0.4 - k * 0.9))
            tip = base + Vector((-4.6 - k * 0.6, side * (1.3 + k * 0.4), -1.4 - k * 0.8))
            blade(bm, tuple(base), tuple(tip), 2.2 - k * 0.4, 0.7, 0.22)
    # Crusted plates along the cheeks - fewer and smaller than they were, since
    # there is far less skull for them to sit on.
    for _ in range(8):
        x = rng.uniform(-7.5, 5.0)
        side = rng.choice((-1, 1))
        ellipsoid(
            bm,
            (x, side * rng.uniform(2.2, 4.6), rng.uniform(-0.9, 0.6)),
            (rng.uniform(0.28, 0.55),) * 3,
            subdiv=0,
        )
    return finish("Noctyss_Skull", bm, NC_HIDE)


def build_nc_skull_bone(rng):
    bm = bmesh.new()
    # THE PALISADE, re-cut as needles: thinner, more of them, no two the same
    # length, every one hooking back toward the throat. This is what a player
    # is looking at while standing inside her mouth, and it is the whole reason
    # the head reads as an anglerfish rather than as a skull with a slot.
    # trim 0.7: THIS ROW IS THE CEILING OF THE PUNISH PLATFORM. Everything
    # else about the room is frozen (NC_JAW_LINE, NC_JAW, the hinge), so the
    # only thing left that decides whether a player can stand up in here is how
    # far these needles hang. At the 2026-09-09 placement the untrimmed row left
    # 5.2 studs of headroom - two tenths over a humanoid - and 0.7 authored off
    # the long ones puts it back over 6.5 without touching a single one of them
    # out of existence.
    _nc_tooth_line(bm, 13, 10.4, -7.8, NC_JAW_LINE + 0.15, -1, rng, trim=0.7)
    # THE ILLICIUM - the short rod off the snout, curling forward and back
    # DOWN so the esca hangs just over the entrance. Built as a chain of
    # tapering cones: a lure is a stalk like every other light in this arena,
    # just a small one growing out of her own face. THICKER than the old arch
    # and a fifth of its reach - at this length a 0.36 rod reads as wire, and
    # the thing has to look like it could hold the lantern up.
    for i in range(len(NC_ILLICIUM) - 1):
        t = i / (len(NC_ILLICIUM) - 2)
        spike(bm, NC_ILLICIUM[i], NC_ILLICIUM[i + 1], 0.52 - 0.20 * t, sides=5)
    # The stem the esca hangs off, and the cage around it - the same bone
    # lantern-cage the choir's hoods carry (build_nc_stalk_cage), so the head's
    # lure is recognisably one of hers.
    esca = Vector(NC_ESCA)
    spike(bm, NC_ILLICIUM[-1], tuple(esca + Vector((0.1, 0, NC_ESCA_R))), 0.18, sides=4)
    for i in range(4):
        angle = (i / 4) * TAU + 0.4
        ring = Vector((math.cos(angle) * 0.55, math.sin(angle), math.cos(angle) * 0.55))
        top = esca + Vector((0.1, 0, NC_ESCA_R * 0.9)) + ring * 0.4
        belly = esca + ring * (NC_ESCA_R + 0.35)
        spike(bm, tuple(top), tuple(belly), 0.13, sides=4)
    # Two swept spines low off the braincase where the horns used to be. They
    # are a tenth of the mass and they do the same job: they tell you which end
    # of this thing is the back.
    for side in (-1, 1):
        spike(bm, (-6.2, side * 3.0, 0.2), (-10.8, side * 4.4, -0.6), 0.42, sides=5)
    return finish("Noctyss_SkullBone", bm, NC_BONE)


def build_nc_jaw():
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=8, ceil_z=NC_JAW_TOP) for x, cz, hw, hh in NC_JAW])
    # A tongue ridge down the middle of the scoop. In game the floor players
    # stand on is anchored server parts pinned inside this shape - the mesh
    # itself is collision-free like every other creature part - so this ridge
    # is what tells them where the floor is.
    box(bm, (-1.0, 0, -5.6), (13.0, 3.2, 0.8))
    # A keel under the chin, BELOW the scoop's floor at z -7.1 and therefore
    # outside the room entirely: the jaw is the whole silhouette now that the
    # skull has shrunk, and from the side it needs a line under it.
    box(bm, (0.4, 0, -7.6), (13.6, 3.0, 1.1), Matrix.Rotation(math.radians(4), 3, "Y"))
    return finish("Noctyss_Jaw", bm, NC_HIDE)


def build_nc_jaw_bone(rng):
    bm = bmesh.new()
    # The lower half of the palisade, standing up to interlock with the upper.
    # When the jaw closes these two sets mesh - that is the cage the punish
    # window shuts you inside. Offset half a station off the upper row (the
    # `phase`) so they pass BETWEEN each other rather than tip to tip, and
    # bare across the doorway for the same reason the upper row is.
    _nc_tooth_line(bm, 12, 9.8, -7.4, NC_JAW_TOP - 0.15, 1, rng, phase=0.5)
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
    # Two roots running back along the palate, into the base of the braincase:
    # the lure that grew INTO her did not stop at the throat. They stop at
    # x -8.7, which is the reach the knot itself already has, ON PURPOSE - the
    # client parents the mouth's only light to this part and Roblox hangs a
    # PointLight at the part's CENTRE OF BULK, so any piece of this object that
    # reached further than the rest would tow the throat's light out of the
    # throat. Nothing new here may change this mesh's bounding box.
    for side in (-1, 1):
        spike(bm, tuple(root + Vector((-1.6, side * 1.2, 0.4))), (-8.7, side * 1.9, -0.4), 0.30, sides=4)
    return finish("Noctyss_Gullet", bm, NC_LURE)


def build_nc_eyes():
    bm = bmesh.new()
    # BLIND. Small, milky, pupil-less beads set wide and LOW on the head,
    # barely proud of the hide - a deep-sea angler does not hunt with its eyes,
    # it hunts with the lights, and hers are the choir and the esca. They used
    # to be 0.95-radius lamps riding high on a brow that no longer exists.
    for side in (-1, 1):
        ellipsoid(bm, (-2.3, side * 5.25, -0.35), (0.55, 0.5, 0.55), subdiv=1)
    # THE ESCA. The bulb on the end of the illicium, hanging over the mouth's
    # entrance - the light that says "come in here". It is authored in THIS
    # object rather than in the Gullet because the Gullet part carries the
    # mouth's PointLight at its own centre of bulk (NoctyssBodyController's
    # gulletLight): a bulb slung eight studs out over the snout would have
    # taken the throat's light with it. Same warm lure family as the choir's
    # lanterns; see the HANDOFF line about lighting it in the client.
    ellipsoid(bm, NC_ESCA, (NC_ESCA_R, NC_ESCA_R * 0.94, NC_ESCA_R * 1.08), subdiv=2)
    for i in range(4):
        angle = (i / 4) * TAU + 0.35
        base = Vector(NC_ESCA) + Vector((0.15, math.cos(angle) * 0.55, -NC_ESCA_R * 0.8 + math.sin(angle) * 0.25))
        spike(bm, tuple(base), tuple(base + Vector((0.35, math.cos(angle) * 0.4, -1.25))), 0.12, sides=4)
    return finish("Noctyss_Eyes", bm, NC_EYE)


def build_nc_barbels(rng):
    bm = bmesh.new()
    # Chin filaments, in the JAW's space so they swing with the gape.
    for i in range(6):
        side = -1 if i % 2 else 1
        base = Vector((rng.uniform(1.0, 6.5), side * rng.uniform(1.6, 3.4), -5.6))
        direction = Vector((rng.uniform(0.2, 0.7), side * rng.uniform(0.2, 0.6), -1.0)).normalized()
        blade(bm, tuple(base), tuple(base + direction * rng.uniform(4.5, 8.0)), 0.8, 0.14, 0.1)
    # THE HINGE MEMBRANE. Loose folds trailing off the jaw hinge and down the
    # neck, the same aesthetic the choir's hoods carry - and they ride the JAW,
    # so a 44-degree gape drags them open like a pelican's pouch. They are in
    # this object because the client lags the barbels a beat behind the jaw
    # (BARB_LAG), which is exactly how slack membrane moves.
    for side in (-1, 1):
        for k in range(3):
            base = Vector((-6.4 + k * 0.9, side * (2.6 + k * 0.8), -3.1 - k * 0.8))
            tip = base + Vector((-4.4 - k * 0.5, side * (1.5 + k * 0.5), -2.2 - k * 0.9))
            blade(bm, tuple(base), tuple(tip), 2.4 - k * 0.5, 0.6, 0.14)
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
        build_nc_skull_bone(rng),
        build_nc_jaw(),
        build_nc_jaw_bone(rng),
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
    print("HANDOFF noctyss: maw faces +X; skull half-width 6.0 at scale 1 -> 12.0 at the row's 2.0 = hitRadius 6")
    print(
        "HANDOFF noctyss: snout tip x=+11.5 (roof -0.45), braincase back to x=-9.6, crown only +1.4;"
        " jaw hinge (%.1f, %.1f, %.1f)" % NC_JAW_HINGE
    )
    print(
        "HANDOFF noctyss: ILLICIUM is a SHORT rod off the snout, out to x=%.1f and HOOKING DOWN to z=%.1f - it "
        "never rises above the snout it grows from; ESCA (the lure hung in front of the mouth) at "
        "(%.1f, %.1f, %.1f) r %.1f, authored in the EYES object - it is the only warm piece on the head that carries "
        "no light and no bbox contract. To make it GLOW like the choir, the client wants one line: setLantern it "
        "beside the Gullet in NoctyssBodyController.drawMaw (Eyes is already in SKULL_PIECES)."
        % (NC_ILLICIUM[2][0], NC_ILLICIUM[4][2], NC_ESCA[0], NC_ESCA[1], NC_ESCA[2], NC_ESCA_R)
    )
    print(
        "HANDOFF noctyss: the tooth line is NC_RIM, sampled by both jaws so they interlock; forward of x=%.1f the "
        "centreline is BARE (NC_DOOR_HALF %.1f) - that gap is the door the party walks through, and no fang may "
        "grow back into it" % (NC_DOOR_X, NC_DOOR_HALF)
    )
    print(
        "HANDOFF noctyss: jaw scoop interior ~11.2 wide x 13 long at scale 1 (22 x 26 at the row's 2.0) - the punish"
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
# (230, 237, 242) at round(f * 255) - the belly and the eye patches. Written as
# 0.902 rather than 0.90 ON PURPOSE: 0.90 * 255 lands at 229.4999 in binary
# floating point, so gen_mesh_colors rounded the old white DOWN to 229.
RF_WHITE = (0.902, 0.929, 0.949)
RF_SADDLE = (0.784, 0.816, 0.839)  # (200, 208, 214) - the saddle behind the dorsal
RF_TOOTH = (0.86, 0.83, 0.72)  # (219, 212, 184)

# Skull cross-sections: (x, centre z, half width, half height). Snout at +X,
# neck joint at the origin end - the pack's convention. The underside is
# clamped flat at RF_MOUTH_LINE so the lower jaw closes on a real palate.
#
# FOURTEEN sections, not seven, and the centre line DROPS from x 1.0 forward.
# The first pass was seven rings of near-constant centre z, which is a box with
# its corners off: the face was flat because the rostrum left the melon on a
# straight line and stopped at a flat cap 1.6 studs wide. A whale's rostrum
# curves down to the mouth and ends in a rounded point, and that curve is the
# whole difference between "orca" and "crate". Smooth-shaded (_rf_smooth).
RF_MOUTH_LINE = -2.2
RF_SKULL = [
    (-6.5, 0.00, 6.40, 6.90),  # neck joint - carries the body's full girth
    (-5.0, 0.20, 6.75, 7.20),
    (-3.6, 0.35, 6.95, 7.45),  # widest: the melon's shoulder
    (-2.2, 0.45, 6.90, 7.35),
    (-0.6, 0.50, 6.55, 6.95),  # the melon crown
    (1.0, 0.40, 6.00, 6.30),
    (2.4, 0.10, 5.40, 5.50),  # the melon falls away into the rostrum
    (3.8, -0.20, 4.60, 4.60),
    (5.0, -0.45, 3.90, 3.80),
    (6.4, -0.70, 3.10, 3.00),
    (7.6, -0.95, 2.30, 2.20),
    (8.6, -1.15, 1.50, 1.45),
    (9.4, -1.35, 0.85, 0.85),
    (9.9, -1.50, 0.34, 0.36),  # rounded tip - NOT a cap
]

RF_JAW_TOP = -2.6
RF_JAW = [
    (-6.0, -4.40, 5.50, 2.40),
    (-4.4, -4.60, 6.00, 2.60),
    (-3.0, -4.70, 6.20, 2.70),
    (-1.0, -4.70, 6.00, 2.60),
    (0.8, -4.60, 5.50, 2.50),
    (2.6, -4.50, 4.80, 2.20),
    (4.2, -4.30, 4.00, 1.90),
    (5.8, -4.00, 3.10, 1.50),
    (7.2, -3.70, 2.20, 1.10),
    (8.4, -3.40, 1.30, 0.70),
    (9.2, -3.20, 0.55, 0.38),  # rounded chin tip, under the rostrum's
]

# Where the client hinges the jaw (the spy-hop gape, the bite, the death).
RF_JAW_HINGE = (-5.4, 0.0, -3.2)

# Mid-body vertebra - the client scales this by u down the girth curve. The
# LENGTH is load-bearing: RimefangBodyController sizes each link off its share
# of the curve and RF_SEG_SPACING, so -2.7..+2.7 stays put. Only the ring
# resolution changed (10 -> 16 sides), which rounds the barrel off without
# moving a single dimension the client's spacing math reads.
#
# THE ENDS STILL TAPER, and they must. Flattening the barrel to a constant
# radius looked like the way to kill the ribbing where consecutive links meet -
# and it did the opposite: sixteen identical cylinders overlapping by half
# their length are COPLANAR over that half, and the render came back striped
# with z-fighting through the flank. A slight bulge means no two surfaces ever
# coincide. The vertebra also stays FLAT-shaded for the same reason the rest of
# the pack is: smoothing averages the end caps into the barrel and draws a dark
# ring at every joint.
RF_SEG = [
    (-2.7, 0.0, 6.3, 6.9),
    (-1.3, 0.0, 6.6, 7.2),
    (1.3, 0.0, 6.6, 7.2),
    (2.7, 0.0, 6.3, 6.9),
]
RF_SEG_SPACING = 3.6

# Where the saddle patch is authored: its origin is a MOUNT ABOVE THE SPINE,
# the dorsal fin's convention, so the controller can station it on the body
# curve (RIME_AT / RIME_LIFT) and it banks with the back. The geometry itself
# hugs an ellipse just inside the vertebra's full girth, so it surfaces through
# the hide instead of floating off it.
RF_SADDLE_LIFT = 6.4


def _rf_smooth(obj):
    """Smooth shading, against this file's flat-everywhere default.

    The orca is the one pack piece whose READ depends on curvature: a melon is
    a melon because the light runs around it. Flat shading on a 14-sided loft
    draws every ring as a facet band, which is exactly the "boxy" the redesign
    is for. Applied to everything except the teeth, which are cones and want
    their edges.
    """
    for poly in obj.data.polygons:
        poly.use_smooth = True
    return obj


def _rf_seal(bm):
    """Outward normals by recalculation, not by winding.

    The lofts below stack rings along +Z and +/-Y as well as +X, and a mirrored
    lobe inverts its winding - the fluke's far lobe rendered inside-out the
    first time. Every component here is a closed volume, so recalc is exact.
    """
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])


def _rf_loft_z(bm, levels, sides=12):
    """A fin: elliptical sections stacked up +Z.

    Each level is (z, chord centre x, chord, thickness) - so the leading edge,
    the trailing edge and the thickness are all authored independently, which
    is what a falcate dorsal needs and what `blade()` (one taper, one plane)
    cannot do.
    """
    rings = []
    for (z, cx, chord, thick) in levels:
        pts = []
        for i in range(sides):
            a = (i / sides) * TAU
            pts.append((cx + math.cos(a) * chord / 2, math.sin(a) * thick / 2, z))
        rings.append(pts)
    loft(bm, rings)


def _rf_loft_y(bm, levels, side=1, sides=12):
    """A flipper or a fluke lobe: elliptical sections stacked out +/-Y.

    Each level is (y, chord centre x, chord, centre z, thickness). The ring is
    reversed on the far side so the mirrored lobe is not inside-out (and
    _rf_seal catches whatever is left).
    """
    rings = []
    for (y, cx, chord, cz, thick) in levels:
        pts = []
        for i in range(sides):
            a = (i / sides) * TAU
            pts.append((cx + math.sin(a) * chord / 2, side * y, cz + math.cos(a) * thick / 2))
        rings.append(pts if side > 0 else list(reversed(pts)))
    loft(bm, rings)


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


def _rf_at(table, x):
    """Interpolate a cross-section table at x - used to seat teeth on the
    real jaw line instead of a guessed straight one."""
    for (x0, cz0, hw0, hh0), (x1, cz1, hw1, hh1) in zip(table, table[1:]):
        if x <= x1:
            t = 0.0 if x1 == x0 else (x - x0) / (x1 - x0)
            return (cz0 + (cz1 - cz0) * t, hw0 + (hw1 - hw0) * t, hh0 + (hh1 - hh0) * t)
    return table[-1][1:]


def _rf_flank_y(x, z):
    """Where the skull's surface is at (x, z) - so a marking can be laid ON
    the flank instead of floating off it or sinking into it."""
    cz, hw, hh = _rf_at(RF_SKULL, x)
    return hw * math.sqrt(max(0.0, 1.0 - ((z - cz) / hh) ** 2))


# The eye itself, and the patch behind it. The eye of an orca sits low and
# just behind the corner of the mouth; the patch rakes up and back off it.
RF_EYE_AT = (-0.9, -1.2)
RF_PATCH_AT = (-4.2, 0.9)


def build_rf_head(rng):
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=14, floor_z=RF_MOUTH_LINE) for (x, cz, hw, hh) in RF_SKULL])
    # The blowhole, set back on the crown where a whale's actually is.
    ellipsoid(bm, (-2.6, 0.0, 7.3), (1.5, 1.1, 0.45), subdiv=2)
    # THE EYE, on the head rather than on `_Eyes`: one material per object, so
    # a dark eye inside a white patch has to ride the black piece. It reads as
    # a bead at the front of the patch - which is where an orca's eye is.
    ex, ez = RF_EYE_AT
    for side in (-1, 1):
        ellipsoid(bm, (ex, side * (_rf_flank_y(ex, ez) - 0.15), ez), (0.75, 0.45, 0.62), subdiv=2)
    _rf_seal(bm)
    return _rf_smooth(finish("Rimefang_Head", bm, RF_SLATE))


def build_rf_jaw(rng):
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=12, ceil_z=RF_JAW_TOP) for (x, cz, hw, hh) in RF_JAW])
    _rf_seal(bm)
    return _rf_smooth(finish("Rimefang_Jaw", bm, RF_SLATE))


def _rf_tooth_row(bm, upper: bool):
    # Big interlocking cones. Orca teeth already ARE cones, so low-poly costs
    # nothing here - but EIGHT a row, not eleven: the denser first pass read
    # as a saw blade rather than a mouth full of pegs.
    for i in range(8):
        t = i / 7.0
        x = -4.0 + t * 11.0
        size = 1.15 * (1.0 - 0.5 * t)
        table = RF_SKULL if upper else RF_JAW
        _, width, _ = _rf_at(table, x)
        for side in (-1, 1):
            y = side * max(width - (1.5 if upper else 1.3), 0.4)
            if upper:
                spike(bm, (x, y, RF_MOUTH_LINE + 0.3), (x - 0.2, y, RF_MOUTH_LINE - 2.6 * size / 1.15), size)
            else:
                spike(bm, (x, y, RF_JAW_TOP - 0.3), (x - 0.2, y, RF_JAW_TOP + 2.6 * size / 1.15), size)


def build_rf_teeth_upper():
    # SPLIT FROM THE LOWER ROW ON PURPOSE. As one object the teeth had to ride
    # the skull, so the bottom row stayed put when the jaw opened and the gape
    # had to be capped at 34 degrees to hide the seam. Two objects let the
    # client hinge the lower row with the jaw and open the mouth properly.
    bm = bmesh.new()
    _rf_tooth_row(bm, True)
    return finish("Rimefang_TeethUpper", bm, RF_TOOTH)


def build_rf_teeth_lower():
    bm = bmesh.new()
    _rf_tooth_row(bm, False)
    return finish("Rimefang_TeethLower", bm, RF_TOOTH)


def _rf_patch(bm, x, z, length, height, tilt, side, thick=0.55, subdiv=3):
    """A flat marking laid on the flank at (x, z), raked by `tilt`.

    Deliberately NOT blade(): blade aligns its own +X to the axis you give
    it, and on a near-horizontal axis its roll comes out as a twist - two
    passes produced a white hook hanging off the cheek instead of a patch.
    A box with an explicit rotation is unambiguous.
    """
    mat = (
        Matrix.Translation(Vector((x, side * (_rf_flank_y(x, z) - 0.10), z)))
        @ Matrix.Rotation(tilt, 4, "Y")
        @ Matrix.Diagonal(Vector((length / 2, thick / 2, height / 2))).to_4x4()
    )
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=1.0, matrix=mat)


def build_rf_eyes():
    """THE EYE PATCH - the marking that carries the whole orca read, and the
    reason this object is white now instead of a pale blue bead.

    It used to live on `_Rime` together with a throat panel, which put two
    flank patches and a chin in ONE part whose bounding box was the entire
    skull: in Roblox that is a white slab sitting on the head - the "white
    thing on top" the user asked to have removed. The patch belongs to the
    piece named for the eye; `_Rime` is the saddle now.
    """
    bm = bmesh.new()
    px, pz = RF_PATCH_AT
    for side in (-1, 1):
        _rf_patch(bm, px, pz, 8.2, 3.1, math.radians(13), side, thick=0.9)
    _rf_seal(bm)
    return _rf_smooth(finish("Rimefang_Eyes", bm, RF_WHITE))


def _rf_shell(bm, stations, sides=15):
    """A thin curved panel hugging a body cross-section.

    Each station is (x, half angular span, outer half width, outer half
    height, thickness): an annular SECTOR, lofted along +X. A patch on a
    round back cannot be a box - laid flat it cuts in at the spine and lifts
    off at the edges - and it cannot be an ellipsoid either, because a
    flattened sphere on a 14-stud barrel is a lens, not a marking.
    """
    rings = []
    for (x, span, out_w, out_h, thick) in stations:
        pts = []
        lo, hi = math.pi / 2 - span, math.pi / 2 + span
        for i in range(sides):
            a = lo + (hi - lo) * i / (sides - 1)
            pts.append((x, math.cos(a) * out_w, math.sin(a) * out_h))
        for i in reversed(range(sides)):
            a = lo + (hi - lo) * i / (sides - 1)
            pts.append((x, math.cos(a) * (out_w - thick), math.sin(a) * (out_h - thick)))
        rings.append(pts)
    loft(bm, rings)


def build_rf_rime(rng):
    """THE SADDLE PATCH, and the same object name as the ice chunk it replaces.

    `_Rime` was a 15 x 11 x 14 crust of ice the client parked on the head -
    the white mass the user read as an anchor. It is now the orca's saddle:
    the grey-white panel that sits on the back just BEHIND the dorsal fin.
    Same name, so MeshColors, the pack rules and the enrage effect that glows
    `_Rime` all keep working - the enrage now lights the saddle, which is a
    better tell anyway (it is on the back, where the camera is).
    """
    bm = bmesh.new()
    _rf_shell(
        bm,
        [
            (-7.6, math.radians(12), 6.85, 7.35, 0.50),
            (-6.0, math.radians(30), 6.85, 7.35, 0.52),
            (-4.0, math.radians(44), 6.85, 7.35, 0.55),
            (-2.0, math.radians(53), 6.85, 7.35, 0.55),
            (0.0, math.radians(54), 6.85, 7.35, 0.55),
            (1.8, math.radians(48), 6.85, 7.35, 0.55),
            (3.2, math.radians(36), 6.85, 7.35, 0.52),
            (4.2, math.radians(20), 6.85, 7.35, 0.50),
        ],
    )
    # Authored on the SPINE, then dropped so the origin is the mount above it -
    # the dorsal's convention, so the controller stations both the same way.
    bmesh.ops.translate(bm, vec=Vector((0.0, 0.0, -RF_SADDLE_LIFT)), verts=bm.verts[:])
    _rf_seal(bm)
    return _rf_smooth(finish("Rimefang_Rime", bm, RF_SADDLE))


def build_rf_body():
    bm = bmesh.new()
    loft(bm, [ring_pts(x, cz, hw, hh, sides=16) for (x, cz, hw, hh) in RF_SEG])
    _rf_seal(bm)
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
    ellipsoid(bm, (0.0, 0.0, -6.3), (6.2, 3.0, 1.1), subdiv=2)
    _rf_seal(bm)
    return _rf_smooth(finish("Rimefang_Belly", bm, RF_WHITE))


def build_rf_fin():
    """The dorsal: a bull orca's - tall, falcate, thick at the root.

    It was a 9 x 14 x 1.5 PLATE of translucent ice, which next to the white
    head chunk is what made the whole silhouette read as an anchor. Now it is
    a solid: 19 studs tall off a root chord 10 long and 2.9 thick, the leading
    edge raked back 13 studs, the trailing edge CONCAVE (that curve is what
    "falcate" means and is the most recognisable line on the animal), and a
    rounded tip. Black, like the rest of the hide - see PIECE_MATERIAL.
    """
    bm = bmesh.new()
    _rf_loft_z(
        bm,
        [
            (0.0, -0.3, 10.0, 2.90),
            (2.7, -0.9, 9.40, 2.60),
            (5.9, -1.9, 8.20, 2.10),
            (9.1, -3.2, 6.80, 1.65),
            (12.3, -4.7, 5.20, 1.25),
            (15.0, -6.1, 3.80, 0.95),
            (17.1, -7.2, 2.40, 0.70),
            (18.4, -7.9, 1.10, 0.42),
            (19.0, -8.2, 0.36, 0.18),
        ],
    )
    _rf_seal(bm)
    return _rf_smooth(finish("Rimefang_Fin", bm, RF_SLATE))


def build_rf_pec():
    """The flipper: an orca's paddle - broad, rounded, THICK at the root.

    ONE flipper, authored toward +Y; the client mirrors it with a half turn
    about the body axis, so there are no mirrored normals to fix.
    """
    bm = bmesh.new()
    _rf_loft_y(
        bm,
        [
            (0.0, 0.0, 7.00, 0.00, 2.80),
            (2.5, -0.5, 7.00, -0.40, 2.40),
            (5.0, -1.6, 6.60, -0.90, 1.90),
            (7.5, -3.0, 5.80, -1.50, 1.50),
            (9.5, -4.3, 4.60, -2.10, 1.10),
            (11.0, -5.4, 3.00, -2.60, 0.80),
            (11.8, -6.1, 1.40, -2.90, 0.50),
            (12.2, -6.4, 0.45, -3.05, 0.22),
        ],
    )
    _rf_seal(bm)
    return _rf_smooth(finish("Rimefang_Pec", bm, RF_SLATE))


def build_rf_fluke():
    """The fluke: two lobes, a centre NOTCH, swept and slightly downturned.

    HORIZONTAL lobes are the single most important thing about a whale's tail.
    The notch is the second: it is what the eye uses to tell a fluke from a
    pair of fins, and a pair of straight blades off a boss has neither. Here
    the trailing edge at y = 0 sits 3.5 studs FORWARD of the lobes' - that gap
    is the notch - and each lobe's trailing edge curves back to a tip that
    drops 2 studs below the peduncle.
    """
    bm = bmesh.new()
    levels = [
        (0.0, 0.0, 5.20, 0.00, 2.60),
        (2.0, -0.6, 5.60, -0.10, 1.70),
        (4.5, -1.6, 6.20, -0.35, 1.20),
        (7.0, -2.6, 5.80, -0.70, 0.95),
        (9.0, -3.6, 4.80, -1.10, 0.80),
        (10.5, -4.4, 3.40, -1.50, 0.60),
        (11.5, -5.0, 1.80, -1.90, 0.40),
        (12.0, -5.3, 0.55, -2.10, 0.20),
    ]
    for side in (-1, 1):
        _rf_loft_y(bm, levels, side=side)
    # The boss on the peduncle, filling the join the two lobes leave open.
    ellipsoid(bm, (0, 0, 0), (2.2, 1.9, 1.4), subdiv=2)
    _rf_seal(bm)
    return _rf_smooth(finish("Rimefang_Fluke", bm, RF_SLATE))


def build_rimefang():
    rng = random.Random(5521)
    objects = [
        build_rf_head(rng),
        build_rf_jaw(rng),
        build_rf_teeth_upper(),
        build_rf_teeth_lower(),
        build_rf_eyes(),
        build_rf_rime(rng),
        build_rf_body(),
        build_rf_belly(),
        build_rf_fin(),
        build_rf_pec(),
        build_rf_fluke(),
    ]
    print("HANDOFF rimefang: head faces +X; neck joint at the origin, rostrum tip x=+9.9")
    print("HANDOFF rimefang: jaw hinge pivot (%.1f, %.1f, %.1f) - client rotates the jaw about it" % RF_JAW_HINGE)
    print("HANDOFF rimefang: vertebra spacing %.1f studs at scale 1; scale by _rf_girth(u), NOT a linear taper" % RF_SEG_SPACING)
    print("HANDOFF rimefang: Belly rides every vertebra (countershading); Pec is authored +Y, mirror by a half turn about the body axis")
    print("HANDOFF rimefang: Fin base is the dorsal mount, ~6.6 studs above the spine at full girth; Fluke mounts on the tail tip, lobes HORIZONTAL")
    print(
        "HANDOFF rimefang: _Eyes is the WHITE EYE PATCH (the dark eye bead is on _Head); _Rime is the SADDLE,"
        " authored on a mount %.1f studs above the spine and stationed BEHIND the dorsal - it is no longer on the head"
        % RF_SADDLE_LIFT
    )
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
PY_MOLTEN = (0.95, 0.13, 0.02)  # the interior, and every broken seam: DEEP red, because AgX lifts a bright emissive to peach
PY_EMBER = (1.00, 0.62, 0.12)  # eyes
PY_JAW_HINGE = (-6.0, 0.0, 16.0)  # head-local (the head's origin is the NECK), where the client swings the jaw about

PY_SLAG = (0.095, 0.088, 0.100)  # the walkable decks: near-obsidian, so the climb route is FOOTING, not a plank bolted on

# The rig, and the HANDOFF contract the client's poser is written against.
# Everything below is in boss space: z=0 is the lake surface.
# THE 2026-09-09 REMODEL, and it was three notes from the player:
#
#   "kinda sucks... pretty rectangular and ugly... looks like a cylinder."
#
#   1. SMALLER. The first pass stood 277 studs to the crown - a wall, not a
#      figure. This one tops out around 205, which is still forty players
#      tall but small enough that the rim path can hold the whole silhouette
#      in one frame instead of a slice of belly.
#   2. A HUMANOID, not a stack. The read from the rim path has to be, in this
#      order: SHOULDERS wider than the waist, a chest that TAPERS DOWN into
#      the lake, a NECK, a small HEAD proud of both, and two arms hanging
#      with a visible elbow. Everything below is arranged to serve that order
#      and nothing else. Legless on purpose - the body enters the lava at the
#      waist and is rooted there.
#   3. SMALLER ROCKS. The first pass clad the body in ~120 big subdivided
#      boxes on a ring-and-column grid, which is the definition of masonry:
#      neighbours the same size, seated at the same depth, sharing world-axis
#      faces. Every region is now an AGGREGATE of many small boulders laid on
#      that region's own ellipsoidal shell, each one rotated into the shell's
#      normal AND spun about it, sized off its own cell with a 2:1 spread, so
#      no two neighbours agree about anything. Plates are largest on the
#      chest (the core of the mass) and smallest toward the silhouette edges,
#      which is where the eye reads "rubble" instead of "block".
#
# The molten interior is unchanged in principle and is still the whole point:
# `Pyrelisk_Core` is one solid body just inboard of the rock's outer faces,
# so every gap the cladding leaves is a trough with lava at the bottom.
#
# The glb and the staged frames come out of the ordinary invocation:
#
#   blender --background --python assets/boss_gen.py -- assets/boss_pyrelisk.glb pyrelisk
#   blender --background --python assets/boss_gen.py -- assets/boss_pyrelisk.glb pyrelisk staged
#
# The three REVIEW frames (_preview, _preview_torso, _preview_arm) come out of
# `render_py_previews` below, which `main`'s generic `preview` path cannot
# reach because it renders one framed-on-the-bbox shot and these are three
# hand-aimed ones. Drive it directly:
#
#   blender --background --python-expr "import sys; sys.path.insert(0,'assets'); \
#     import boss_gen as B; B.clear_scene(); \
#     B.render_py_previews('assets/boss_pyrelisk', B.BOSSES['pyrelisk']())"

# The rig, and the HANDOFF contract the client's poser is written against.
# Everything below is in boss space: z=0 is the lake surface.
#
# The arm lengths are not free. `_stage_pyrelisk` asserts the fist can be
# planted past the lava lake (r 120), and from a shoulder at y 84 / z 130 the
# furthest a straight arm of length L reaches is 84 + sqrt(L^2 - 130^2); at
# L 150 that is r 159, which lands the fist in the near third of the rim path
# (r 120..232). Longer than that and the arm reads as an ape's; shorter and
# it cannot bridge its own moat.
PY_RIG = {
    "shoulder": (-2.0, 84.0, 126.0),  # mirrored in y
    "upper_arm": 58.0,
    "forearm": 64.0,
    "hand": 28.0,
    "neck": (8.0, 0.0, 152.0),  # the head's own origin: the base of the skull
    "height": 206.0,
}

# THE BODY, as a stack of cross-sections: (z, half width in y, half depth in x).
#
# This table IS the silhouette, and it is the first thing to change if the
# figure stops reading. Three facts are load-bearing:
#   - the WAIST at z 22 (half width 44) is narrower than the chest at z 122
#     (half width 73), so the torso tapers DOWNWARD into the lake;
#   - it is an ELLIPSE, not a circle: depth is roughly 60% of width all the
#     way up, which is what stops the body reading as a cylinder from any
#     angle the rim path offers;
#   - the waterline half width (48) is the collision footprint the moat and
#     the melee gate assume, and must stay well under hitRadius 96.
PY_BODY = [
    (-56.0, 34.0, 28.0),  # deep in the lava - never seen, but the core needs a bottom
    (-30.0, 44.0, 34.0),
    (0.0, 48.0, 37.0),  # THE WATERLINE: footprint r 48
    (22.0, 44.0, 33.0),  # the waist, and the narrowest point of the visible body
    (50.0, 49.0, 35.0),
    (78.0, 57.0, 39.0),
    (104.0, 66.0, 42.0),
    (114.0, 73.0, 42.0),  # the chest at its widest; the yoke carries on from here
    (128.0, 54.0, 33.0),  # the trapezius sloping in
    (140.0, 28.0, 24.0),
    (152.0, 18.0, 16.0),  # the neck
]

# The shoulder YOKE, as its own shell: a flattened ellipsoid laid across the
# top of the chest. The stack above cannot express it - a cross-section table
# can only make a barrel wider, and a barrel 80 studs wide is a barrel. The
# yoke is 80 wide and 40 deep and 19 tall, so it is a BAR, and the arms hang
# off its ends.
PY_YOKE = ((-6.0, 0.0, 113.0), (40.0, 80.0, 19.0))

# ------------------------------------------------------- THE LAVA UNDERBODY
#
# THE 2026-09-12 REMODEL, and it is the player's third note on this boss and
# the largest:
#
#   "the body under the rock should be ENTIRELY LAVA - a bright molten mass,
#    not a dim core glimpsed through occasional gaps. Think of the body as a
#    lava creature wearing stone armour. The rock is FLUSH PLATING: large
#    rounded plates lying close against the body like armour plates or a
#    cracked cooling crust, and between every plate a visible crack line of
#    bright lava."
#
# The fight is untouched. What changes is the OUTPUT of the cladding and the
# depth of the core, and the two numbers that carry it are these:
#
#   PY_LAVA_OUT  where the molten body's surface stands relative to the
#                profile line. It was -6: the core sat ten studs down inside
#                every gap, so a gap was a shadowed trough and the body read
#                as rock with a fire somewhere inside it. It is ZERO now - the
#                lava IS the profile, the body's own surface - and the plates
#                are laid ON it, so the floor of every crack is molten rock
#                rather than shadow.
#
#                IT WAS +1 FOR ONE BUILD and that is worth keeping: a stud of
#                lava proud of the profile put every plate a stud further out
#                too, and since a plate's crown stands 1.45 of its half
#                thickness above its seat, the body came back three studs
#                bigger in every radius - a 62-stud-wide head against the 52
#                the design fought for twice, the shoulder span 241 against
#                224, and the spine deck SIX STUDS higher, which took the
#                fallen route's hand ramp from 20 degrees to 31 (the cap is
#                20). The plating is not allowed to grow the figure; it is a
#                different surface on the same body.
#   PY_PLATE_*   below: the plate, its bevel, and the width of the crack
#                between two of them.
#
# The silhouette is still the plates', because a plate's crown stands
# 1.45 * its half thickness PROUD of the lava (see `_py_scute`) - about five
# studs on the chest. From the rim path the outline is black rock; what is
# molten is the network between the plates, which is the read the player asked
# for and the opposite of the "lamp with gravel stuck to it" the first pass of
# the 09-09 remodel produced at +1.5 (the core level with the rock's own outer
# faces, which is not this: this is the core level with the rock's SEAT).
PY_LAVA_OUT = 0.0
# SIDES AND STEP, and both went up with the remodel for one reason: the lava
# surface is now the SEAT every plate on the body is measured against, so its
# own faceting is an error budget rather than a look. At 16 sides a 73-stud
# chest section's flats cut 2.2 studs inside the curve they approximate, which
# is seven times the connectivity tolerance. 32 sides, a 4-stud step up the
# body, and radii CIRCUMSCRIBED (`/cos(pi/n)`, so the flats land ON the
# profile instead of inside it) keeps it inside a quarter of a stud.
PY_CORE_SIDES = 32
PY_CORE_STEP = 4.0

# THE PLATE ITSELF.
#
# `sides`      the outline's segment count. Nine on anything over ~7 studs,
#              seven below it - a plate has to read as ROUNDED and a hexagon
#              at twenty studs across reads as a hexagon.
# `square`     the superellipse exponent the outline is sampled off. 2 is an
#              ellipse, which covers only 79% of its own cell and leaves a
#              third of the body molten; 4 is a rounded rectangle at 87% and
#              is what "plates packed tightly" means numerically.
# `bevel`      how far, IN STUDS, the crown is drawn in from the rim. ABSOLUTE
#              and not a fraction, and that is the whole trick of this shape:
#              a proportional bevel on a 30-stud plate is a cone with a 7-stud
#              slope, which is a boulder again. 1.3 studs of bevel on any
#              plate at any size gives the same "edges beveled down toward the
#              crack" the reference shows.
# `rim`        where the plate is widest, as a fraction of its half thickness,
#              measured from its centre. NEGATIVE: the widest line sits BELOW
#              the middle, on the lava surface itself, so the crack's floor is
#              exactly where the molten body is and the plate's underside is
#              tucked in rather than overhanging.
# `foot`       studs of invisible stub reaching further down into the lava,
#              past the plate's own base. This is the connectivity guarantee
#              and nothing else: `tools/check_posed_connectivity.py` roots at
#              `Pyrelisk_Core` and the lava body IS the root, so a plate whose
#              foot is inside it is attached BY CONSTRUCTION rather than by a
#              weld pass measuring its luck afterwards. It also buys the head
#              its pitch: the skull's plates swing on the neck while the lava
#              under them does not, and the foot is the slack that covers it.
PY_PLATE_SIDES = 9
PY_PLATE_SQUARE = 5.0
PY_PLATE_BEVEL = 1.0
PY_PLATE_RIM = -0.20
PY_PLATE_FOOT = 2.4
# THE CRACK, as a fraction of the cell's own pitch, with a floor in studs so
# the smallest plates on the body still have a lit line round them.
#
# 0.055 OF A CELL, and it was 0.12 for the first render - which is the one
# number this remodel got wrong by a factor of two. The arithmetic said 0.12
# of a 32-stud chest cell is 3.8 studs of lava against 28 of plate, or 12%;
# what the render showed was HALF THE CHEST ORANGE. The gap between the two is
# that a crack is not a line, it is the whole space a rounded plate leaves in
# a rectangular cell: a superellipse fills about 87% of its own bounding box,
# the box is inset by the crack on both axes, and the bevel takes a stud off
# every edge. Those compose to 35% of the surface molten at 0.12, and the
# brief's target is 30% INCLUDING the lava lake the figure stands in.
#
# So the crack is specified as what it is - a hairline, 1.2 studs at the floor
# and under two on the chest - and the coverage that follows is about 85%
# rock. From the rim path at 250 studs through a 21mm lens a 1.8-stud crack is
# six pixels of molten rock, which is a line rather than a panel and is still
# legible because the network is CONTINUOUS: the eye reads the whole web, not
# one segment of it. PY_PLATE_SQUARE went 4 -> 5 in the same pass (squarer
# plates, more of their cell) and PY_PLATE_BEVEL 1.3 -> 1.0.
PY_PLATE_CRACK = 0.09
PY_PLATE_CRACK_MIN = 2.0
# THE PLATE'S SECTION, as (fraction of half thickness, bevel multiplier). Read
# it as a shield lying face up: a buried foot, the RIM (widest, and it lands on
# the lava surface), a shoulder, and the crown drawn in one bevel.
#
# THE RIM IS THREE RINGS AND NOT ONE, and that is a CONNECTIVITY measure rather
# than a shape. `tools/check_posed_connectivity.py` asks whether a plate's
# surface comes within 0.3 studs of the lava's, and it asks by measuring each
# mesh's VERTICES against the other's polygons - which cannot see
# interpenetration at all (a plate buried four studs deep has no vertex near
# the lava's surface and measures four studs away, exactly like one floating
# four studs off). The only vertices that can answer the question are the ones
# ON the seat, and a single ring of them has to land within 0.3 of a FACETED
# lava mesh whose own deviation from the surface it approximates is of that
# order. Three rings 0.17 of a thickness apart straddle it instead, so one of
# them is always inside the tolerance and the answer stops depending on the
# core's tessellation.
PY_PLATE_RINGS = (
    (-1.00, -0.55),
    (PY_PLATE_RIM - 0.17, -0.10),
    (PY_PLATE_RIM, 0.0),
    (PY_PLATE_RIM + 0.17, -0.10),
    (0.38, -0.30),
    (1.00, -1.00),
)


# WHERE THE SEAMS ARE: (z, bearing in degrees), bearing measured about +Z with
# 0 dead ahead. Seam 1 is the chest, dead centre - sealed for two phases, then
# phase 3's target. The rest are mirrored pairs so the fight is symmetric.
#
# A seam has to sit ON ROCK and stand PROUD of it, which random cladding
# cannot promise, so `build_py_torso` lays a dedicated backing plate at each
# of these - seated at the nominal depth with almost no jitter - and
# `py_seam_site` states that plate's face rather than estimating it. Five of
# seven seams were buried in the rock on the first pass because they were
# eyeballed against a surface nothing was built from.
#
# AND THE BACKING PLATE IS TWO HALVES NOW (2026-09-12), which is the answer to
# the question the plating asks: with lava in EVERY crack, what makes the seven
# shootable cracks findable among the hundred that are just anatomy? Not
# brightness - brightness is the OPEN state's channel and spending it on the
# closed one leaves open with nowhere to go. GEOMETRY. Each seam site is a
# single plate SPLIT DOWN THE MIDDLE: two half plates with `PY_SEAM_GAP` studs
# of open lava between them, against an ambient crack of two to three. A
# closed seam is therefore a fault line FOUR TIMES the width of any crack near
# it - subtle (it is the same colour as the rest of the network) and locatable
# at 230 studs, which is what act 1 is fought at.
#
# TWELVE STUDS, AND IT WAS NINE FOR ONE ROUND. Nine against an ambient crack of
# four and a half (PY_PLATE_CRACK at 0.15) is a ratio of two, and the
# `_preview_seams` frame at that setting is the evidence: with lava in every
# crevice of the body, a fissure twice the width of its neighbours is
# CAMOUFLAGE - three of us looked at that frame and could not point at a seam.
# The pair moved apart and the ambient crack came down to 0.11 in the same
# pass, which is the trade this remodel cannot avoid: every stud of ambient
# crack is a stud of the seam's own legibility.
PY_SEAM_SPEC = [
    (100.0, 0.0),  # the chest, dead ahead
    (86.0, 38.0),
    (86.0, -38.0),
    (60.0, 84.0),  # the flanks
    (60.0, -84.0),
    (24.0, 62.0),  # low, just clear of the lava
    (24.0, -62.0),
]
# ONE HALF of the backing plate: half width, half height, half thickness. The
# pair is laid either side of the crack, so the plate the fissure is torn
# through measures 2 * 10.5 + PY_SEAM_GAP = 33 across against the module's own
# 27, and 34 tall against its 30 - bigger than any plate near it on a chest
# whose own cells are about 39 by 25.
#
# AND IT IS THE THICKEST PLATE ON THE BODY (4.6 against the chest band's 3.6),
# which is the third thing making a closed seam findable after its width and
# its length: the pair stands a stud and a half PROUDER than its neighbours, so
# it reads as a blister on the shell with a split down it. Colour is doing none
# of this work - see PY_SEAM_GAP.
PY_SEAM_PLATE = (16.0, 20.0, 4.6)
PY_SEAM_GAP = 12.0  # studs of open lava between the two halves - THE fault line
# ...and how far the ordinary plating STANDS BACK from a seam site, in studs.
#
# THE THING THAT FINALLY MADE A CLOSED SEAM FINDABLE, after width (2x, then
# 4x), proudness and a raised lip had each been tried and each disappeared. The
# defect was never the seam: it was that a body whose every plate is outlined
# in lava is a MOSAIC, and no single tile of a mosaic is legible at 300 studs
# however it is drawn. So a seam site is not a tile - the band plating skips
# every cell whose seat falls inside this radius, and the two big halves
# (44 x 40 across the pair) fill it. What the eye gets is a SMOOTH, uncracked
# slab of armour with one bright fault line through the middle of it, which is
# a different KIND of feature from everything round it and reads instantly.
PY_SEAM_CLEAR = 24.0
# Where the module's own origin goes: ON the halves' crown, not floating over
# it, and DERIVED rather than eyeballed for the reason the note above gives -
# five of seven seams shipped buried the one time this was a number somebody
# chose. A scute's crown stands (1 - PY_PLATE_RIM) of its half thickness above
# its seat and the seat is PY_LAVA_OUT off the profile, so:
PY_SEAM_PROUD = round(PY_LAVA_OUT + (1.0 - PY_PLATE_RIM) * PY_SEAM_PLATE[2], 2)


def _py_profile(z):
    """Half width (y) and half depth (x) of the body at height `z`.

    Smoothstepped between the sections rather than lerped: a linear stack of
    cross-sections is a stack of CONES, and the creases where two cones meet
    are exactly the horizontal bands that made the first pass read as courses
    of brickwork.
    """
    if z <= PY_BODY[0][0]:
        return PY_BODY[0][1], PY_BODY[0][2]
    for (z0, y0, x0), (z1, y1, x1) in zip(PY_BODY, PY_BODY[1:]):
        if z <= z1:
            t = (z - z0) / (z1 - z0)
            t = t * t * (3.0 - 2.0 * t)
            return y0 + (y1 - y0) * t, x0 + (x1 - x0) * t
    return PY_BODY[-1][1], PY_BODY[-1][2]


def _py_skin(z, angle, out=0.0):
    """A point on the body's surface and its OUTWARD NORMAL.

    The normal is the ellipse's own normal (which is NOT the radial direction
    - on a 73x42 section they differ by up to 25 degrees) tilted by the local
    slope of the profile, so a chunk laid on the shoulder's slope lies along
    it instead of standing on end in it.
    """
    ry, rx = _py_profile(z)
    c, s = math.cos(angle), math.sin(angle)
    point = Vector((c * (rx + out), s * (ry + out), z))
    normal = Vector((c * ry, s * rx, 0.0))
    if normal.length < 1e-6:
        normal = Vector((1.0, 0.0, 0.0))
    normal.normalize()
    ry0, rx0 = _py_profile(z - 2.0)
    ry1, rx1 = _py_profile(z + 2.0)
    slope = ((rx1 - rx0) * abs(c) + (ry1 - ry0) * abs(s)) / 4.0
    return point, Vector((normal.x, normal.y, -slope)).normalized()


def py_seam_halves(z, bearing_deg):
    """The two half plates at a seam site, as (profile point, seat, normal,
    across) each - the profile point first because PY_SEAM_PROUD is measured
    from the profile and the seat is on the LAVA.

    ON THEIR OWN BEARINGS, not offset along the site's flat tangent, and that
    is the whole content of this function. Laid 15 studs along the tangent the
    halves stand up to three studs off the shell (the body's radius of
    curvature at the chest is about fifty) and their crowns measured 2.8 to
    10.3 studs proud where the module needs a constant 7.1 - so the fissure
    would have been buried at one site and floating at the next.

    Stated once and read by both `build_py_torso` and `_py_assert_seam_face`:
    the builder lays the plates here and the check measures what it laid, which
    is the only arrangement in which the check can fail for a real reason.
    """
    angle = math.radians(bearing_deg)
    ry, rx = _py_profile(z)
    # the arc the half plate's own centre sits at, as an angle: the offset in
    # studs over the section's mean radius
    step = (PY_SEAM_PLATE[0] + PY_SEAM_GAP * 0.5) / max((ry + rx) * 0.5, 1.0)
    out = []
    for side in (-1.0, 1.0):
        bearing = angle + side * step
        floor, _n = _py_skin(z, bearing)
        point, normal = _py_skin(z, bearing, out=PY_LAVA_OUT)
        out.append((floor, point, normal, Vector((-math.sin(bearing), math.cos(bearing), 0.0))))
    return out


def py_seam_site(z, bearing_deg, proud=PY_SEAM_PROUD):
    """The outer face of the backing plate carrying the seam at (z, bearing)."""
    point, normal = _py_skin(z, math.radians(bearing_deg))
    origin = point + normal * proud
    return (
        (round(origin.x, 1), round(origin.y, 1), round(origin.z, 1)),
        (round(normal.x, 3), round(normal.y, 3), round(normal.z, 3)),
    )


# --------------------------------------------------------------- the plates
#
# ONE primitive, used everywhere. Everything on this boss above the lava is
# one of these: a PLATE, not a boulder.
#
# THE 2026-09-12 PASS, and it is the player's note in full:
#
#   "not jittered boulders jutting at angles. No spikes, no scree, no chunks
#    poking off the silhouette. The plates FORM the silhouette; it reads
#    smooth-ish and massive from the rim path. Plate scale: LARGE - a torso
#    has maybe 20-40 plates, not 474 pebbles."
#
# So the primitive changed shape and the schedule changed scale, and the two
# are one change: a plate is only a plate if it is big enough to have edges
# the eye can follow round it.
#
#   old  474 boulders on the torso, a flattened icosahedron apiece, tipped up
#        to 9 degrees OFF the surface normal, spun freely about it, every
#        vertex kicked a quarter of its own radius, SIZED PAST ITS CELL so
#        neighbours interpenetrate and the mass reads as one.
#   new  ~90 plates on the torso, a beveled rounded slab apiece, laid FLAT on
#        the lava (no tip at all), sized INSIDE its cell so a crack of
#        measured width is left round every one of them, and seated so its
#        base bites into the molten body underneath.
#
# THE TIP IS GONE, not reduced, and that is the single biggest difference. A
# slab tipped even nine degrees off the surface it is lying on has a corner in
# the air; a hundred of those is the "jutting" the player is pointing at. What
# stops the new surface reading as tiling is not tip and not tumble - it is
# that every plate is a different size, its outline is a wobbled superellipse
# rather than a shape with corners, and the cracks between them are a
# continuous irregular network rather than a grid of grout lines.
#
# WHAT THE OLD ROLLS BECAME. `PY_SIZE_*` and `PY_DEEP_*` survive because a
# plate's size is still rolled - the roll is just much tighter and it is now
# applied INSIDE a cell whose crack allowance has already been taken out, so
# the roll can no longer close a crack or open a hole. `PY_TILT` is zero and
# `PY_JITTER` is the outline wobble rather than a per-vertex kick.
#
# THE 2026-09-11 PASS, and it was two notes from the player:
#
#   "theres too many like floating objects and the rocks that he is made out
#    of look too random and weird. make sure theyre slightly more uniform and
#    make sure that there are no floating objects, it should all be connected
#    component."
#
# Two separate defects, and they had one cause between them. Every chunk was
# placed by a roll - size on a 0.76..1.34 spread (a 1.76:1 range), tipped off
# the surface normal by up to 0.30 rad, spun freely about it, and then every
# vertex kicked by 0.34 of its own radii. Chunks sized 1.44x their cell
# INTERPENETRATE on average, which is what made the body read as one mass -
# but "on average" is not a promise, and the tail of that distribution is a
# small chunk, rolled small, tipped away, sitting in a cell its neighbours
# also rolled small. Measured on the shipped glb: 62 contact components across
# the 14 objects where 26 were intended - 16 detached pieces on the torso
# alone, 5 on the head, 11 on the upper arm.
#
# So the fix is in two halves and BOTH are needed:
#
#   * PY_KNIT (below) makes connectivity STRUCTURAL rather than lucky. After a
#     region is laid, its chunks are graphed by overlap and anything not in
#     the main component is PULLED IN until it touches. Luck decides where the
#     boulders are; it no longer decides whether they are attached.
#   * the rolls below are TIGHTENED - a narrower size band, much less tip off
#     the normal, less vertex kick. Deliberately NOT uniform: the spread is
#     what leaves the cracks open, and the cracks are how the fight is read.
#     The mean is held at ~1.05 of the cell so coverage (and therefore the
#     silhouette) does not change.
#
# THE ROLLS, in one place, because "slightly more uniform" is a number and it
# should be possible to see what it was. Old -> new:
#
#   tangential size   0.76..1.34 (mean 1.05, 1.76:1)  ->  0.90..1.20 (1.33:1)
#   thickness         0.70..1.34 (mean 1.02, 1.91:1)  ->  0.86..1.16 (1.35:1)
#   tip off normal    +/-0.30 rad (17 deg)            ->  +/-0.15 rad (9 deg)
#   vertex kick       0.34 of radii                   ->  0.26
#
# The tip is the one that mattered most to the "weird" read: a slab tipped 17
# degrees off the surface it is lying on has a corner in the air, and a few
# hundred of those is scree. At 9 degrees they read as laid.
PY_SIZE_LO, PY_SIZE_HI = 0.97, 1.06  # the tangential size roll, inside the cell
PY_DEEP_LO, PY_DEEP_HI = 0.90, 1.12  # the thickness roll
PY_JITTER = 0.09  # the outline wobble: what kinks the crack lines



def _py_basis(normal, along=None):
    """A rotation whose local +Z is `normal`; +X and +Y span the surface.

    `along` biases local +X onto that world direction (projected into the
    surface), which is what makes a limb read as stone STACKED ALONG THE BONE
    instead of tumbled round it. Without it the tangential axes come from an
    arbitrary reference and only the yaw roll decides where they point, so
    every chunk on the arm faces somewhere different.
    """
    n = Vector(normal).normalized()
    t1 = None
    if along is not None:
        t1 = Vector(along) - n * Vector(along).dot(n)
        t1 = t1.normalized() if t1.length > 1e-4 else None
    if t1 is None:
        ref = Vector((0.0, 0.0, 1.0))
        if abs(n.dot(ref)) > 0.94:
            ref = Vector((1.0, 0.0, 0.0))
        t1 = ref.cross(n).normalized()
    t2 = n.cross(t1)
    return Matrix((t1, t2, n)).transposed()


# ------------------------------------------------------------- the knit pass
#
# THE LEDGER. `_py_rock` is the only thing that makes geometry on this boss, so
# it is the only place that has to record anything: every chunk it builds goes
# in here with the bmesh it lives in, its MEASURED centre and radius (measured
# AFTER the jitter - a radius computed from the nominal radii is a claim and
# the jitter can push a vertex 26% past it), and whether it is structural or
# decorative rubble.
_PY_CHUNKS = []

# WHY THIS IS NOT A BOUNDING-SPHERE TEST, and it was written as one first.
#
# A chunk is a flattened icosahedron: 8 studs across the surface and 4 through
# it, so its bounding SPHERE is twice the radius of the chunk in the direction
# that matters. Graphing spheres at any threshold generous enough to catch real
# neighbours also joins pairs whose surfaces are five studs apart, and the pass
# then reports a happy "1 component" over a body that still has nineteen. That
# is exactly what happened: the sphere graph said the torso was whole and an
# independent BVH surface-distance graph over the exported glb said 19.
#
# So the test is a SUPPORT-LINE test against the chunk's own vertices: along
# the line joining two centres, how far does each chunk actually reach? That is
# the exact separating-axis distance on that one axis, it costs twelve dot
# products a side, and it cannot be fooled by a chunk's thin direction. The
# sphere survives only as a cheap reject (if the spheres miss, the chunks
# certainly do).
#
# It is a one-axis test, so it can call two chunks separated when they overlap
# somewhere off the centre line - it errs toward pulling, never toward a false
# "connected". The exported-glb checker remains the arbiter.
PY_KNIT_PASSES = 8  # a pull can strand a third piece, so the graph is re-solved
# A DECORATIVE chunk needing to move further than this (as a multiple of its
# own radius) is deleted instead. Structural chunks are always pulled: deleting
# one leaves a hole in the shell and the core glows through it.
PY_KNIT_RUBBLE_REACH = 0.85
# How far PAST contact a pull goes, in studs. Not cosmetic: a shift computed to
# close the gap exactly lands the chunk ON the threshold, where a strict `<`
# test reads it as still detached and the next round moves it again. It also
# means every pulled chunk genuinely interpenetrates its neighbour rather than
# kissing it, which is the difference between reading as joined and reading as
# two rocks that happen to touch.
PY_KNIT_BITE = 0.35
# How deep an overlap the build-side graph insists on before it calls two
# chunks joined, in studs. The support-line test is a CONVEX approximation of a
# chunk whose vertices have been kicked inward as well as outward, so a pair
# that just barely passes it can still have real air between the two surfaces.
# Demanding a genuine bite makes the build graph strictly stricter than the
# exported-glb checker, which is the direction an in-process guard has to err:
# it may pull a chunk that did not need it, and it may not miss one that did.
PY_KNIT_GRIP = 1.6


def _py_chunks_reset():
    """Start a new object's ledger. Called by every builder that lays rock."""
    del _PY_CHUNKS[:]


def _py_gap(ci, cj):
    """Studs of clear air between two chunks along the line joining them.

    Negative means they interpenetrate, which is what "one mass" is made of.
    `rel` is each chunk's vertices as offsets from its own centre, so this
    survives the pass translating a chunk without any re-measurement.
    """
    delta = cj["center"] - ci["center"]
    span = delta.length
    if span < 1e-6:
        return -min(ci["radius"], cj["radius"])
    unit = delta / span
    reach_i = max(r.dot(unit) for r in ci["rel"])
    reach_j = max(-r.dot(unit) for r in cj["rel"])
    return span - (reach_i + reach_j)


def _py_overlap_groups(chunks):
    """Connected components of the chunk graph: two chunks are joined when
    their surfaces actually meet (see `_py_gap`). The bounding spheres are
    used only to reject pairs that cannot possibly touch."""
    parent = list(range(len(chunks)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for i, ci in enumerate(chunks):
        for j in range(i + 1, len(chunks)):
            cj = chunks[j]
            if find(i) == find(j):
                continue
            if (cj["center"] - ci["center"]).length > ci["radius"] + cj["radius"]:
                continue
            if _py_gap(ci, cj) < -PY_KNIT_GRIP:
                parent[find(j)] = find(i)
    groups = {}
    for i in range(len(chunks)):
        groups.setdefault(find(i), []).append(i)
    return sorted(groups.values(), key=len, reverse=True)


def _py_pull(chunks, group, main):
    """The shift that brings `group` into contact with the main mass, and the
    chunk of it that closes first.

    Minimal, and along the line between the two nearest chunks - which for a
    rock left standing proud of the shell IS inward along its own surface
    normal, because inward is where the mass it fell off is.
    """
    best = None
    for i in group:
        ci = chunks[i]
        for j in main:
            cj = chunks[j]
            delta = cj["center"] - ci["center"]
            gap = _py_gap(ci, cj) + PY_KNIT_GRIP
            if best is None or gap < best[0]:
                best = (gap, delta, i)
    gap, delta, i = best
    if delta.length < 1e-6:
        return Vector((0.0, 0.0, 0.0)), gap, i
    return delta.normalized() * (gap + PY_KNIT_BITE), gap, i


def _py_knit(name, expect=1, report=True):
    """Make the ledger's chunks ONE connected mass, and say what it cost.

    The graph is re-solved after every round because pulling a group in can
    strand a third one it was the only bridge to, and because a group just
    pulled in may now bridge two others. `expect` is how many components this
    object is allowed to end with - see PY_COMPONENTS.

    Nothing here is random: the pass is a deterministic function of where the
    seeded placement put the chunks, so re-exports stay byte-stable.
    """
    chunks = list(_PY_CHUNKS)
    moved = pulled = deleted = 0
    worst = 0.0
    for _ in range(PY_KNIT_PASSES):
        groups = _py_overlap_groups(chunks)
        if len(groups) <= expect:
            break
        main = groups[0]
        for group in groups[1:]:
            shift, gap, near = _py_pull(chunks, group, main)
            lone = chunks[near]
            if lone["loose"] and gap > lone["radius"] * PY_KNIT_RUBBLE_REACH:
                # Decorative rubble stranded well off the body: it is scatter,
                # and scatter dragged onto the shell is just a lump. Cut it.
                for index in group:
                    bmesh.ops.delete(chunks[index]["bm"], geom=chunks[index]["verts"], context="VERTS")
                    chunks[index] = None
                deleted += len(group)
                continue
            for index in group:
                chunk = chunks[index]
                for vert in chunk["verts"]:
                    vert.co += shift
                chunk["center"] = chunk["center"] + shift
            moved += len(group)
            pulled += 1
            worst = max(worst, gap)
        chunks = [c for c in chunks if c is not None]
    groups = _py_overlap_groups(chunks)
    if len(groups) > expect:
        raise SystemExit(
            "PYRELISK KNIT FAILED: %s came out as %d connected components, expected %d "
            "(sizes %s). The body must read as ONE mass - either the placement has drifted "
            "so far that %d pull rounds cannot close it, or PY_COMPONENTS is stale."
            % (name, len(groups), expect, [len(g) for g in groups], PY_KNIT_PASSES)
        )
    # The ledger is left holding the SURVIVORS in their final positions, so
    # anything downstream that reads it (the selftest) is
    # looking at the rock that actually exists.
    _PY_CHUNKS[:] = chunks
    if report:
        print("KNIT %-9s %3d chunks -> %d component(s); pulled %d group(s) (%d chunks, "
              "worst gap %.2f), deleted %d"
              % (name, len(chunks), len(groups), pulled, moved, worst, deleted))
    return {"chunks": len(chunks), "moved": moved, "deleted": deleted, "pulled": pulled}


# ------------------------------------------------- THE SURFACE-LEVEL WELD
#
# `_py_knit` above is not enough, and 2026-09-12 is when that stopped being a
# theory. `tools/check_posed_connectivity.py` - an instrument that shares none
# of this file's code - found THIRTY-FOUR components adrift in the posed frame
# on a body the knit had just certified as one mass: 5 torso rocks at 0.34-0.53
# studs, 3 upper-arm rocks at 0.33-0.45, one head rock at 0.47, one crown shard
# at 0.45 off the head, and 24 of the vent's 30 at 0.72-1.50.
#
# WHY THE KNIT MISSED THEM, and it is not a tolerance that needs nudging. It
# is the MEASURE. `_py_gap` is a SUPPORT FUNCTION: it projects each chunk's
# vertices onto the line joining the two centres and asks whether the extents
# overlap. For two convex blobs that is exact; for a jittered, tilted rock it
# is OPTIMISTIC, because the vertex that reaches furthest along the centre line
# is generally not the vertex nearest the other rock's surface. The two
# surfaces can miss each other by half a stud while the support test reports
# 1.6 studs of interpenetration - which is why every one of those defects sat
# inside a PY_COMPONENTS run that printed "1 component(s)".
#
# So this is a SECOND pass with a DIFFERENT measure: BVH nearest-polygon, the
# same question the external instrument asks, run at build time and fixed by
# construction rather than reported. It runs AFTER the knit (which does the
# heavy lifting of dragging strays across studs of open air) and closes what
# the knit's measure cannot see. It also covers the objects the knit CANNOT
# run on at all - Vent, Seam, Crown, Eyes are built from `disc`/`spike`/`box`
# and register no chunks, so the ledger is empty for them and the guard was
# silent by construction.
#
# WHAT IT DOES NOT DO: it never deletes and it never moves the root island, so
# it cannot change the silhouette. The worst it can do is pull a rock less
# than a stud further into the mass it was already resting against, and it
# PRINTS every pull.
def _py_islands(obj):
    """The mesh's connected components, as (vertex indices, polygon indices).

    ISLANDS, not chunks: the rocks are never boolean-merged, so one island IS
    one authored primitive and this is the same decomposition the external
    instrument walks.
    """
    mesh = obj.data
    parent = list(range(len(mesh.vertices)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for edge in mesh.edges:
        a, b = find(edge.vertices[0]), find(edge.vertices[1])
        if a != b:
            parent[b] = a
    groups = {}
    for index in range(len(mesh.vertices)):
        groups.setdefault(find(index), []).append(index)
    polys = {}
    for poly in mesh.polygons:
        polys.setdefault(find(poly.vertices[0]), []).append(poly.index)
    out = []
    for key, verts in groups.items():
        out.append((verts, polys.get(key, [])))
    out.sort(key=lambda pair: -len(pair[0]))
    return out


def _py_island_tree(obj, verts, polys):
    """A BVH over ONE island, in the object's own local frame, plus the island's
    bounding sphere so pairs that cannot possibly touch are never measured."""
    from mathutils.bvhtree import BVHTree

    mesh = obj.data
    order = {index: n for n, index in enumerate(verts)}
    points = [tuple(mesh.vertices[i].co) for i in verts]
    faces = [tuple(order[v] for v in mesh.polygons[p].vertices) for p in polys]
    centre = Vector((0.0, 0.0, 0.0))
    for point in points:
        centre += Vector(point)
    centre /= max(1, len(points))
    radius = max((Vector(p) - centre).length for p in points) if points else 0.0
    tree = BVHTree.FromPolygons(points, faces, all_triangles=False, epsilon=0.0) if faces else None
    return {"verts": verts, "polys": polys, "points": points, "tree": tree,
            "centre": centre, "radius": radius}


def _py_touching(a, b, contact):
    """Do these two islands' SURFACES meet, within `contact` studs?

    DO NOT REACH FOR `BVHTree.overlap` HERE. It looks like the right call and
    it is not: it is a BROAD PHASE, reporting pairs whose BVH nodes' bounding
    boxes overlap, not pairs whose polygons actually cross. Measured on this
    body, the torso rock at (-29.3, 18.8, 2.8) - one of the five the external
    instrument found adrift - `overlap`s SEVEN neighbours while its nearest
    surface is 0.53 studs away from all of them. Used as a contact test it
    reports the entire body connected, which is precisely the false green this
    pass exists to end.
    """
    if a["tree"] is None or b["tree"] is None:
        return False
    gap = _py_surface_gap(a, b)
    return gap is not None and gap[0] <= contact


def _py_surface_gap(a, b):
    """Studs of clear air between two islands' SURFACES.

    Both directions, because one is not enough: a big island's sparse vertices
    can all sit far from a small island resting on its broad flat face, and
    measuring only that way round reports a gap where there is contact. (The
    external instrument's docstring is the long version of this.)
    """
    best = None
    for island, other in ((a, b), (b, a)):
        if other["tree"] is None:
            continue
        for point in island["points"]:
            hit = other["tree"].find_nearest(Vector(point))
            if hit is None or hit[0] is None:
                continue
            location, _normal, _face, distance = hit
            if best is None or distance < best[0]:
                best = (distance, Vector(location) - Vector(point), island is b)
    return best


def _py_tree(obj, polys, extra=()):
    """A BVH over these polygons, in the object's own local frame, plus any
    already-transformed extra (vertex list, polygon list) pairs."""
    from mathutils.bvhtree import BVHTree

    mesh = obj.data
    verts = [tuple(v.co) for v in mesh.vertices]
    faces = [tuple(mesh.polygons[p].vertices) for p in polys]
    for more_verts, more_faces in extra:
        offset = len(verts)
        verts.extend(more_verts)
        faces.extend(tuple(i + offset for i in f) for f in more_faces)
    if not faces:
        return None
    return BVHTree.FromPolygons(verts, faces, all_triangles=False, epsilon=0.0)


def _py_island_reach(obj, verts, tree):
    """The nearest point on `tree` to this island, as (distance, pull vector)."""
    mesh = obj.data
    best = None
    for index in verts:
        co = mesh.vertices[index].co
        hit = tree.find_nearest(co)
        if hit is None or hit[0] is None:
            continue
        location, _normal, _face, distance = hit
        if best is None or distance < best[0]:
            best = (distance, Vector(location) - co)
    return best


def _py_weld(name, obj, against=(), contact=0.20, bite=0.06, report=True):
    """Pull every island that has no SURFACE contact with the root mass into it.

    A CONTACT GRAPH, rooted, not a per-round flood: two islands are joined when
    their surfaces are within `contact`, pairs that cannot possibly touch are
    rejected by their bounding spheres first, and reachability is what decides
    whether a rock is attached. A cluster of seven rocks touching only each
    other is NOT attached, and that distinction is the whole reason the naive
    version of this pass reported the vents clean.

    `against` is a list of (verts, faces) in THIS object's frame - the way a
    crown shard is judged against the head it grows out of, which is a pair no
    per-object check can see and which is exactly where one of the defects was.

    THE BITE IS DELIBERATELY TINY (0.06), and that is the opposite of what the
    knit does - `PY_KNIT_BITE` drives a chunk well INTO the mass. The reason is
    the measure this pass and the external instrument both use:
    `BVHTree.find_nearest` returns the distance to the nearest SURFACE point
    and cannot tell inside from outside, so a rock buried half a stud deep
    measures HALF A STUD AWAY - exactly like a rock floating half a stud off.
    Over-pulling therefore makes the body look WORSE to the checker while
    making it physically more attached, which is the most confusing possible
    failure: every weld reports success and the gate still fails. So a pull
    lands the surfaces grazing (~0.06) rather than interpenetrating, which is
    inside every tolerance and is what the seating passes on this body do too.

    Deterministic: islands come out of `_py_islands` largest-first off a seeded
    build, and pulls are applied in that order, so re-exports stay byte-stable.
    """
    islands = [_py_island_tree(obj, verts, polys) for verts, polys in _py_islands(obj)]
    if not islands:
        return {"pulled": 0, "worst": 0.0, "islands": 0}
    mesh = obj.data
    neighbour = _py_tree(obj, [], extra=list(against)) if against else None

    def touches_neighbour(island):
        if neighbour is None or island["tree"] is None:
            return False
        for point in island["points"]:
            hit = neighbour.find_nearest(Vector(point))
            if hit and hit[0] is not None and hit[3] <= contact:
                return True
        return False

    # the contact graph, bounding-sphere pruned
    edges = [set() for _ in islands]
    for i, a in enumerate(islands):
        for j in range(i + 1, len(islands)):
            b = islands[j]
            if (b["centre"] - a["centre"]).length > a["radius"] + b["radius"] + contact:
                continue
            if _py_touching(a, b, contact):
                edges[i].add(j)
                edges[j].add(i)

    def reachable(roots):
        seen, stack = set(roots), list(roots)
        while stack:
            node = stack.pop()
            for peer in edges[node]:
                if peer not in seen:
                    seen.add(peer)
                    stack.append(peer)
        return seen

    roots = [i for i, island in enumerate(islands) if touches_neighbour(island)]
    # THE FALLBACK IS ONLY FOR AN OBJECT WITH NOTHING TO BE JUDGED AGAINST, and
    # that distinction cost a run. `roots = [0]` says "the first island is the
    # mass", which is right for a piece welded to itself (a vent, a jaw) and is
    # a LIE for one welded against a neighbour: when `against` is given and no
    # island reaches it, EVERY island is adrift, and declaring one of them a
    # root hides exactly the defect this pass exists to find. It did: an eye
    # five studs off the face came back "all in surface contact already"
    # because it happened to be island 0, and the posed-connectivity instrument
    # found it afterwards.
    if not roots and neighbour is None:
        roots = [0]
    attached = reachable(roots)
    pulled, worst = 0, 0.0
    # Largest adrift island first: a big one dragged in often brings a cluster
    # of small ones with it, and pulling the small ones first would move rock
    # that was about to be attached anyway.
    while True:
        adrift = [i for i in range(len(islands)) if i not in attached]
        if not adrift:
            break
        best = None
        for i in adrift:
            for j in attached:
                a, b = islands[i], islands[j]
                span = (b["centre"] - a["centre"]).length - a["radius"] - b["radius"]
                if best is not None and span > best[0]:
                    continue
                gap = _py_surface_gap(a, b)
                if gap is None:
                    continue
                distance, direction, flipped = gap
                if flipped:
                    direction = -direction
                if best is None or distance < best[0]:
                    best = (distance, direction, i, j)
        # The NEIGHBOUR is a candidate anchor on equal terms, not a fallback.
        # As a fallback it lost: a crown shard 0.45 studs off the skull it
        # grows out of was pulled 3.98 studs sideways into another shard,
        # because the other shard was "attached" and the head was only
        # consulted when nothing else could be found. The thing a shard should
        # be welded to is the head.
        if neighbour is not None:
            for i in adrift:
                reach = _py_island_reach(obj, islands[i]["verts"], neighbour)
                if reach and (best is None or reach[0] < best[0]):
                    best = (reach[0], reach[1], i, None)
        if best is None:
            raise SystemExit(
                "PYRELISK WELD FAILED: %s has %d island(s) adrift and nothing to measure them "
                "against." % (name, len(adrift))
            )
        distance, direction, index, anchor = best
        if direction is None or direction.length < 1e-9:
            raise SystemExit(
                "PYRELISK WELD FAILED: %s island %d is adrift with no direction to pull it "
                "(distance %.3f). That is a degenerate island, not a gap." % (name, index, distance)
            )
        shift = direction.normalized() * (distance + bite)
        island = islands[index]
        for vertex in island["verts"]:
            mesh.vertices[vertex].co += shift
        # Rebuild this island's own tree in its new position and re-measure
        # only ITS edges - nothing else moved, so nothing else can have changed.
        islands[index] = _py_island_tree(obj, island["verts"], island["polys"])
        # DROP THE STALE EDGES IN BOTH DIRECTIONS. Clearing only this island's
        # own set leaves every neighbour still claiming to touch it, so the
        # graph keeps an edge to a rock that has just moved away - and the
        # flood then walks through a contact that no longer exists. That is a
        # false attached, which is the exact failure this pass exists to end,
        # reintroduced by the pass itself: at contact 0.12 it took the body
        # from 6 adrift to 13 while every weld reported success.
        for peer in edges[index]:
            edges[peer].discard(index)
        for peer in range(len(islands)):
            edges[peer].discard(index)
        edges[index] = set()
        for j in range(len(islands)):
            if j == index:
                continue
            a, b = islands[index], islands[j]
            if (b["centre"] - a["centre"]).length > a["radius"] + b["radius"] + contact:
                continue
            if _py_touching(a, b, contact):
                edges[index].add(j)
                edges[j].add(index)
        if anchor is not None:
            edges[index].add(anchor)
            edges[anchor].add(index)
        elif index not in roots:
            # Pulled onto the NEIGHBOUR rather than onto a sibling island, so
            # it is a root now in its own right - a crown shard welded into the
            # skull is attached by the skull, not by the shard beside it.
            roots.append(index)
        attached = reachable(roots if roots or neighbour is not None else [0])
        if index not in attached:
            raise SystemExit(
                "PYRELISK WELD FAILED: %s island %d would not attach after a %.2f-stud pull."
                % (name, index, distance + bite)
            )
        pulled += 1
        worst = max(worst, distance)
    if report and pulled:
        print("WELD %-9s %3d islands; pulled %d by surface contact (worst gap %.2f studs)"
              % (name, len(islands), pulled, worst))
    elif report:
        print("WELD %-9s %3d islands; all in surface contact already" % (name, len(islands)))
    return {"pulled": pulled, "worst": worst, "islands": len(islands)}


# THE ISLAND LEDGER: how many separate vertex islands each object ships as.
#
# THIS IS NOT THE FLOATER GUARD - `_py_weld` above is, and it is the one that
# raises when something is adrift. This is the STABILITY check that sits beside
# it, and the two answer different questions:
#
#   _py_weld           "is every island in surface contact with the mass?"
#   PY_MESH_COMPONENTS "is the object still made of the pieces it was?"
#
# Both are needed and neither implies the other. The body is BUILT from
# interpenetrating and deliberately NON-touching islands, so "one island" was
# never the goal and an object that counts one more or one fewer than this has
# had geometry silently added or dropped by an edit nobody measured. Every
# number below is MEASURED off the build, not chosen, and the ones with a
# reason have it written down:
#
#   Core 6      the trunk's loft, the yoke's ball, a ball at each shoulder
#               joint, the skull's, and the throat dome - the molten body, in
#               six pieces that all bury themselves in one another
#               (`_py_assert_lava_knit`).
#   Torso 153   the plate schedule's 106, the yoke's ~30, the seven back-ridge
#               plates and the seam sites' fourteen halves. It was 474
#               boulders before the plating; the count falling by two thirds
#               IS the remodel.
#   Crown 4     four separate shards off the skull; the rig parents them to
#               the head and `_py_weld(..., against=head)` welds each base in.
#   Eyes 2      two emissive slits, drawn proud of the face on purpose.
#   Seam 6      the fissure plus five hairline offshoots - a crack that forks,
#               which is what makes it read as split rock rather than a lamp.
#   Vent 11     five collars, five spikes, and the measured FOOT that reaches
#               through the deck into the rock (PY_VENT_DROP).
#   WalkDeck 3  the spine plateau and both shoulder pads, one box each.
#   UpperArm 41 the bone's own rock shell plus forty plates: 21 on the barrel,
#               14 on the two cap rings, 5 in the elbow knot. Forearm and Hand
#               the same arrangement, and the shell is why the count is odd.
#
# THE THREE _Walk* OBJECTS ARE THE ONE CLASS `_py_weld` MUST NOT TOUCH, and it
# is worth being loud about why: a walking plate is held 0.6 studs CLEAR of the
# rock under it on purpose (`_py_seat_decks`), and the three decks do not touch
# each other at all. Welding them would close exactly the clearance the seating
# pass exists to create - it would bury the footing in the boulders and call it
# an improvement. They are guarded by the SEATING measurement instead, which is
# the right guarantee for a slab: the question a slab can get wrong is its
# HEIGHT, not its connectivity.
PY_MESH_COMPONENTS = {
    "Core": 6, "Torso": 144, "Head": 31, "Jaw": 4, "Crown": 4, "Eyes": 2,
    "Shoulder": 17, "UpperArm": 41, "Forearm": 37, "Hand": 13,
    "Seam": 6, "Vent": 11, "WalkArm": 1, "WalkDeck": 3, "WalkNeck": 1,
    # ACT 3's TWO TARGETS, and both are ONE island by construction rather than
    # by a weld: they are single lofted surfaces (rings bridged end to end),
    # not aggregates of interpenetrating boulders. That is a deliberate choice
    # and not a shortcut - a rock the player is asked to SHOOT has to be one
    # closed body, because the client draws it as one Neon part and a
    # multi-island target lights unevenly where the islands overlap.
    "ArmRock": 1, "NeckCore": 1,
}


def _py_assert_components(obj):
    """Count the finished mesh's islands and hold them to PY_MESH_COMPONENTS."""
    name = obj.name.split("_", 1)[1]
    expect = PY_MESH_COMPONENTS.get(name)
    islands = len(_py_islands(obj))
    if expect is None:
        raise SystemExit(
            "PYRELISK COMPONENTS: %s has no PY_MESH_COMPONENTS row, so nothing is checking it. "
            "Every object in the pack needs one - add it with the count the build measures."
            % obj.name
        )
    if islands != expect:
        raise SystemExit(
            "PYRELISK COMPONENTS FAILED: %s came out as %d mesh island(s), expected %d. Geometry "
            "has been added or dropped since this number was measured - re-measure it deliberately "
            "rather than editing the row to match." % (obj.name, islands, expect)
        )
    return islands


def _py_knit_selftest():
    """THE POSITIVE CONTROL, and it runs on every build.

    A check that only ever passes is indistinguishable from a check that never
    ran, and this one guards a defect - a detached boulder - that no other gate
    in the repo can see. So before the body is built, the knit pass is handed
    three ledgers it has to get demonstrably right:

      1. two chunks sat on one another plus a third displaced 40 studs. The
         graph MUST report 2 components before the pass and 1 after, and the
         stray MUST have actually moved.
      2. the same stray marked `loose` and put 400 studs out, where no pull is
         reasonable: it MUST be deleted, not dragged across the body.
      3. the ASSERTION itself - the same two-component ledger knitted with a
         pull budget of zero MUST raise. Without this the whole guard could
         quietly be a function that returns on any input, which is exactly how
         a check like this regresses.

    There is no path through this that prints OK without all three evaluated.
    """
    global PY_KNIT_PASSES
    rng = random.Random(11)

    def ledger(offset, loose=False):
        _py_chunks_reset()
        bm = bmesh.new()
        _py_scute(bm, (0.0, 0.0, 0.0), (5.0, 5.0, 5.0), rng, foot=0.0)
        _py_scute(bm, (3.0, 0.0, 0.0), (5.0, 5.0, 5.0), rng, foot=0.0)
        _py_scute(bm, offset, (4.0, 4.0, 4.0), rng, foot=0.0, loose=loose)
        return bm

    bm = ledger((40.0, 0.0, 0.0))
    if len(_py_overlap_groups(list(_PY_CHUNKS))) != 2:
        raise SystemExit("KNIT SELFTEST FAILED: a chunk 40 studs out did not read as a second component")
    before = _PY_CHUNKS[2]["center"].copy()
    result = _py_knit("selftest", expect=1, report=False)
    if result["moved"] != 1 or (_PY_CHUNKS[2]["center"] - before).length < 1.0:
        raise SystemExit("KNIT SELFTEST FAILED: the stray chunk was not pulled in")
    bm.free()

    bm = ledger((400.0, 0.0, 0.0), loose=True)
    result = _py_knit("selftest", expect=1, report=False)
    if result["deleted"] != 1 or result["moved"] != 0:
        raise SystemExit("KNIT SELFTEST FAILED: stranded rubble was pulled instead of cut")
    bm.free()

    bm = ledger((40.0, 0.0, 0.0))
    budget, PY_KNIT_PASSES = PY_KNIT_PASSES, 0
    try:
        _py_knit("selftest", expect=1, report=False)
    except SystemExit:
        tripped = True
    else:
        tripped = False
    finally:
        PY_KNIT_PASSES = budget
    bm.free()
    if not tripped:
        raise SystemExit("KNIT SELFTEST FAILED: the assertion did not fire on a two-component ledger")
    _py_chunks_reset()
    print("KNIT SELFTEST OK: stray pulled in, stranded rubble cut, assertion fires")


def _py_scute(bm, center, radii, rng, normal=(0.0, 0.0, 1.0), along=None, yaw=0.30,
              bevel=PY_PLATE_BEVEL, wobble=PY_JITTER, foot=PY_PLATE_FOOT, loose=False,
              sides=None):
    """ONE ARMOUR PLATE, and it is the only thing on this boss that makes rock.

    A beveled rounded slab lying FLAT on the lava: `radii` is (tangential,
    tangential, half thickness) in the surface normal's own frame, exactly as
    the boulder primitive it replaces took them, so every seating expression on
    the body reads the same. What comes out is a different shape:

      * the OUTLINE is a superellipse (`PY_PLATE_SQUARE`), sampled at `sides`
        bearings with a per-vertex wobble. Rounded, but squarer than an ellipse
        - an ellipse packs to 79% of its own cell and the body comes back
        orange between the plates.
      * the SECTION is `PY_PLATE_RINGS`: a foot, the RIM (widest, and it lands
        ON the lava surface), a shoulder, and a crown drawn in `bevel` studs.
        The bevel is what makes the surface undulate instead of bristle, and
        it is in STUDS rather than in a fraction of the plate - see the
        constant's note.
      * NO TIP. The plate's own +Z is the surface normal and nothing rolls it
        off. It is spun about that normal by `yaw` (a plate has no grain, but
        two neighbours sharing an outline bearing read as tiling) and that is
        the whole of its randomness beyond size.

    `foot` sinks an extra invisible ring below the base, so the plate reaches
    into the molten body under it. THAT is the connectivity contract: the
    external instrument roots at `Pyrelisk_Core`, the lava IS the core, and a
    plate with a foot in it is attached by construction.

    EVERY plate is recorded in `_PY_CHUNKS`, and this is the only place that
    records one: the knit graph is built over what was ACTUALLY BUILT, with the
    radius measured after the wobble.
    """
    half_w, half_h, deep = radii
    if sides is None:
        sides = PY_PLATE_SIDES if max(half_w, half_h) > 7.0 else 7
    rot = _py_basis(normal, along=along) @ Matrix.Rotation(rng.uniform(-yaw, yaw), 3, "Z")
    # THE OUTLINE, sampled once and shared by every ring: the rings differ only
    # in how far they are drawn in, which is what keeps a plate's own edge
    # parallel to itself all the way up instead of tapering into a cone.
    outline = []
    for index in range(sides):
        angle = (index + 0.5) / sides * TAU
        c, s = math.cos(angle), math.sin(angle)
        k = (abs(c) ** PY_PLATE_SQUARE + abs(s) ** PY_PLATE_SQUARE) ** (-1.0 / PY_PLATE_SQUARE)
        wob = 1.0 + rng.uniform(-wobble, wobble)
        point = Vector((c * k * half_w * wob, s * k * half_h * wob, 0.0))
        outline.append((point, max(point.length, 1e-3)))
    rings = list(PY_PLATE_RINGS)
    if foot > 0.0:
        rings.insert(0, (-1.0 - foot / max(deep, 0.5), -1.30))
    seat = Vector(center)
    verts, loops = [], []
    for along_z, bevels in rings:
        loop = []
        for point, reach in outline:
            # The inset is applied along each outline vertex's own radius,
            # which for a convex rounded shape is the same thing as an offset
            # to within a fraction of a stud - and unlike a true polygon
            # offset it cannot self-intersect on a small plate.
            shrink = max(1.0 + bevels * bevel / reach, 0.12)
            local = Vector((point.x * shrink, point.y * shrink, along_z * deep))
            vert = bm.verts.new(seat + rot @ local)
            loop.append(vert)
            verts.append(vert)
        loops.append(loop)
    # Bridged and capped by hand rather than through `loft`: the ledger needs
    # the vertex list back, and `loft` does not hand one over. The winding is
    # loft's own - rings counter-clockwise about the advance - so the faces
    # come out pointing away from the plate. Reverse either and the plate is
    # single-sided INWARD, which renders as nothing at all in Roblox.
    for lower, upper in zip(loops, loops[1:]):
        for index in range(sides):
            other = (index + 1) % sides
            bm.faces.new((lower[index], lower[other], upper[other], upper[index]))
    bm.faces.new(list(reversed(loops[0])))
    bm.faces.new(loops[-1])
    rel = [v.co - seat for v in verts]
    _PY_CHUNKS.append({
        "bm": bm,
        "verts": verts,
        "center": seat,
        "rel": rel,
        "radius": max(r.length for r in rel),
        "loose": loose,
    })
    return verts


def _py_cell(pitch, crack=PY_PLATE_CRACK):
    """A cell's pitch, less the crack that has to be left inside it.

    `crack = 0` means NO crack - the caller is plating something with no lava
    under it (a bone, the fist) and will be lapping its plates instead, so the
    floor does not apply: it would take 1.8 studs out of a cell that is about
    to be given 1.8 back.
    """
    if crack <= 0.0:
        return max(pitch, 2.0)
    return max(pitch - max(pitch * crack, PY_PLATE_CRACK_MIN), 2.0)


def _py_lava_radii(radii):
    """A region's shell radii, grown to where its LAVA surface stands.

    Every plate on this body is seated on the lava rather than on the profile,
    and `build_py_core` lofts the lava off the same shell numbers through this
    same function - so the plate's seat and the molten surface under it cannot
    drift apart. The original defect of the 09-09 remodel was a core lofted
    from its own numbers, 27 studs behind the plates and invisible; this is the
    same lesson one layer down.
    """
    return tuple(r + PY_LAVA_OUT for r in radii)


def _py_arc(ry, rx, angle):
    """How fast the section's arc runs, per radian of bearing, AT that bearing.

    THE CELL'S REAL WIDTH, and getting this wrong cost the first plated render.
    `_py_skin` walks the section as (cos a * rx, sin a * ry), so the arc length
    per radian is |(-rx sin a, ry cos a)| - which on the chest's 73 x 42
    section is 73 at the FRONT and 42 at the FLANKS. Sized off the mean circle
    instead (57.5, which is what was here), every plate down the centre of the
    chest came out 27% narrower than its cell and every plate on the flanks 27%
    wider: the front of the body was a column of orange gaps and the flanks
    were solid black. It reads as a coverage bug and it is a PARAMETERISATION
    bug - the plates were the right size for a body that was round.
    """
    return math.hypot(rx * math.sin(angle), ry * math.cos(angle))


def _py_seam_seats():
    """The seven seam sites as points on the lava surface, for the plating to
    stand clear of. Computed on demand rather than at import: `_py_skin` is
    defined below the seam table it reads."""
    if not _PY_SEAM_SEATS:
        for z, bearing in PY_SEAM_SPEC:
            _PY_SEAM_SEATS.append(_py_skin(z, math.radians(bearing), out=PY_LAVA_OUT)[0])
    return _PY_SEAM_SEATS


_PY_SEAM_SEATS = []


def _py_plating(bm, rng, z0, z1, rows, cols, deep, crack=PY_PLATE_CRACK, stagger=0.02):
    """Plate a band of the BODY PROFILE between z0 and z1 with `rows * cols`.

    The plate is sized off its cell MINUS the crack, which is the inversion the
    remodel turns on: the boulder pass sized each chunk PAST its cell so
    neighbours interpenetrated and the mass read as one, and the cracks were
    whatever the spread happened to leave. Here the crack is the thing that is
    specified and the plate takes what is left, so the network is continuous
    and even over the whole body - which is what "every plate outlined in
    glowing orange" requires and what a spread cannot promise.

    WHY THE ROWS STILL DO NOT READ AS COURSES. Three things, and the first two
    are the ones that matter: every row is offset half a pitch from the one
    below (a bond, not a grid), and every other plate in a row is lifted
    `stagger` of the row's own height so the horizontal cracks kink rather than
    ring the body. The third is the outline wobble, which makes no two crack
    segments parallel.
    """
    span = (z1 - z0) / rows
    for row in range(rows):
        z = z0 + span * (row + 0.5)
        twist = rng.uniform(0.0, TAU) + (0.5 if row % 2 else 0.0) / cols * TAU
        for col in range(cols):
            # THE JITTERS ARE SMALL, and they were four times this on the
            # first plated render. A cell at the front of the chest is 39
            # studs of arc, so +/-0.08 of one is +/-3 studs per plate and
            # SIX between two neighbours that happen to roll apart - which
            # is a hand's width of open lava wherever the dice said so. The
            # crack is specified at two to three studs; nothing else in the
            # placement may be allowed to add three more. What breaks the
            # courses instead is the outline WOBBLE (PY_JITTER), which moves
            # the crack line without widening it.
            angle = twist + (col + rng.uniform(-0.035, 0.035)) / cols * TAU
            zz = z + (stagger if col % 2 else -stagger) * span + rng.uniform(-0.02, 0.02) * span
            point, normal = _py_skin(zz, angle, out=PY_LAVA_OUT)
            # THE SEAM SITES STAND CLEAR (see PY_SEAM_CLEAR): the ordinary
            # plating skips these cells and `build_py_torso`'s own pair of half
            # plates fills the space, so a fissure sits in smooth armour rather
            # than in the middle of the mosaic.
            if any((point - seat).length < PY_SEAM_CLEAR for seat in _py_seam_seats()):
                continue
            ry, rx = _py_profile(zz)
            pitch = _py_arc(ry + PY_LAVA_OUT, rx + PY_LAVA_OUT, angle) * TAU / cols
            # THE SLOPE CORRECTION, and it is not cosmetic. `span` is a
            # height, but the plate lies ON the surface, and where the profile
            # is turning hard - the trapezius drops 19 studs of half width in
            # 14 of height - a stud of z is 1.7 studs of surface. Sized off
            # span alone the plates there cover 60% of the slope and the
            # clavicle comes back as one open molten panel.
            rise = span * min(1.0 / max(math.hypot(normal.x, normal.y), 0.35), 2.4)
            thick = deep * rng.uniform(PY_DEEP_LO, PY_DEEP_HI)
            half_w = _py_cell(pitch, crack) * 0.5 * rng.uniform(PY_SIZE_LO, PY_SIZE_HI)
            half_h = _py_cell(rise * (1.0 - 2.0 * stagger), crack) * 0.5 * rng.uniform(PY_SIZE_LO, PY_SIZE_HI)
            _py_scute(bm, point + normal * (-PY_PLATE_RIM * thick), (half_w, half_h, thick), rng,
                      normal=normal, along=(-math.sin(angle), math.cos(angle), 0.0))


def _py_ell_area(radii):
    a, b, c = (abs(r) for r in radii)
    p = 1.6075
    return 4.0 * math.pi * (((a * b) ** p + (a * c) ** p + (b * c) ** p) / 3.0) ** (1.0 / p)


def _py_plate_shell(bm, rng, center, radii, count, deep, crack=PY_PLATE_CRACK,
                    min_nz=-1.1, arc=None, lap=0.0):
    """Plate an ELLIPSOID region - the yoke, a pauldron, the skull, a fist - in
    `count` plates on a golden-angle lattice.

    The lattice is used because it is even without being regular: a
    latitude/longitude grid crowds the poles and lines up its columns, and
    lined-up columns on a shoulder read as masonry. `min_nz` skips the
    underside of a region that sits on another one, so no polygons are spent
    inside the chest - but it is much nearer -1 than it was, because the
    underside of a region whose interior is now MOLTEN is not a hole into the
    dark, it is a lamp pointed at the rim path.

    `lap` is for the regions with no lava under them (the limbs and the fist):
    it OVERLAPS neighbours by that many studs instead of leaving a crack, so
    the piece is one connected mass the knit pass can certify. The groove the
    bevels leave is still there; what is missing is the molten floor, because
    nothing follows a swinging bone to put one there.
    """
    origin = Vector(center)
    rr = Vector(_py_lava_radii(radii))
    golden = math.pi * (3.0 - math.sqrt(5.0))
    # The seats it laid, handed back: `build_py_crown` grows its shards out of
    # the MIDDLE of a skull plate rather than off an authored bearing, which is
    # the only way to promise a shard is rooted in rock when the cranium is
    # twelve big plates with real cracks between them.
    laid = []
    # THE WHOLE LATTICE FIRST, because a plate is sized off the distance to its
    # own NEAREST NEIGHBOUR rather than off sqrt(area/count).
    #
    # Same lesson as `_py_arc` one surface over: a global cell is the right
    # size only where the ellipsoid is locally spherical. On the yoke - 80
    # studs across the shoulders and 19 tall - the lattice's spacing varies by
    # a factor of three between the ends and the top, so one cell size leaves
    # the ends bare and stacks the top three deep. The nearest-neighbour
    # distance IS the local spacing, it costs count^2 vector subtractions on
    # counts in the tens, and it needs no metric.
    sites = []
    for index in range(count):
        v = 1.0 - 2.0 * (index + 0.5) / count
        ring = math.sqrt(max(1.0 - v * v, 0.0))
        a = golden * index + rng.uniform(-0.14, 0.14)
        unit = Vector((math.cos(a) * ring, math.sin(a) * ring, v))
        unit += Vector((rng.uniform(-0.04, 0.04), rng.uniform(-0.04, 0.04), rng.uniform(-0.04, 0.04)))
        unit.normalize()
        normal = Vector((unit.x / rr.x, unit.y / rr.y, unit.z / rr.z)).normalized()
        point = origin + Vector((unit.x * rr.x, unit.y * rr.y, unit.z * rr.z))
        sites.append((unit, point, normal))
    for unit, point, normal in sites:
        if normal.z < min_nz:
            continue
        if arc is not None and not (arc[0] <= math.atan2(unit.y, unit.x) % TAU <= arc[1]):
            continue
        near = min(((other - point).length for _u, other, _n in sites if other is not point),
                   default=8.0)
        thick = deep * rng.uniform(PY_DEEP_LO, PY_DEEP_HI)
        # 1.12 OF THE NEAREST NEIGHBOUR, not 1.0 of it, and the twelve percent
        # is the hex lattice's own geometry rather than a fudge. A golden-angle
        # lattice's cell is a hexagon: its inradius is half the
        # nearest-neighbour distance but its CIRCUMRADIUS is 0.577 of it, so a
        # plate sized to meet its nearest neighbours exactly falls 15% short
        # of the cell's corners. 1.09 is the settled trade: a hairline between
        # nearest neighbours and a small three-pointed crevice at each lattice
        # vertex, which is what "lava filling every crevice" looks like on a
        # curved region. At 1.12 (one build) the plates overlapped and the
        # pauldrons went solid black - no outline on any plate, which is the
        # brief's complaint in reverse.
        half = _py_cell(near * 1.09 + lap, crack) * 0.5
        half_w = half * rng.uniform(PY_SIZE_LO, PY_SIZE_HI)
        half_h = half * rng.uniform(PY_SIZE_LO, PY_SIZE_HI)
        seat = point + normal * (-PY_PLATE_RIM * thick)
        _py_scute(bm, seat, (half_w, half_h, thick), rng, normal=normal)
        laid.append((seat, normal.copy()))
    return laid


# ---------------------------------------------------------------- the pieces


def _py_under_ball(bm, center, radii, subdiv=3):
    """THE BODY UNDER A PLATED REGION: an ellipsoid on the plates' own seat.

    In `Pyrelisk_Core` this is LAVA, and it is the whole remodel. In a limb or
    a fist it is the same geometry in the piece's own mesh and it is ROCK -
    because nothing can put lava under a swinging bone (see `PY_LIMB_LAP`'s
    note) and a plated bone still needs something to be plated ON. One helper
    for both: what the plates need from it is a surface at their seat, and that
    is all either version provides.

    Two corrections and both are load-bearing:

      * `_py_lava_radii` puts it exactly where the plates over it are seated,
        so their feet are inside it BY CONSTRUCTION rather than by luck.
      * the 1.012 and `subdiv=3`. An icosphere's FACES lie inside the sphere
        its vertices sit on, and the shortfall is what the plate's seat has to
        cross: at subdiv=1 (what the yoke's core shipped with) an 80-stud
        ellipsoid's faces dip nearly a fifth of the radius inboard, which is
        fifteen studs of nothing where the plating expects a surface. At
        subdiv=3 the dip is under half a percent and the 1.012 covers the rest.
    """
    ellipsoid(bm, center, tuple(r * 1.012 for r in _py_lava_radii(radii)), subdiv=subdiv)


def _py_bone_shell(bm, length, r0, r1, flat=1.0, sides=20, over=0.0):
    """THE BODY UNDER A PLATED BONE: a tapered tube along +X from the joint, on
    the plates' own seat line.

    `_py_under_ball` for a limb, and it exists for the same reason: armour
    plates do not touch each other, so something has to be the mass they are
    all attached to. Without it a bone is thirty-five islands in a ring with
    nothing between them, `tools/check_posed_connectivity.py` reports every one
    adrift from `Pyrelisk_Core`, and the only alternative is to LAP the plates
    into each other - which closes the grooves and, worse, hides the join from
    the very instrument that has to certify it (two plates can interpenetrate
    four studs deep and still have no vertex near each other's surface, which
    is how a lapped upper arm measured 3.73 studs adrift while its knit pass
    reported one mass).

    CIRCUMSCRIBED like the trunk's loft (`PY_CORE_SIDES`), so the flats land ON
    the seat line the plates were placed against rather than inside it.
    """
    swell = 1.0 / math.cos(math.pi / sides)
    rings = []
    steps = max(2, int(round(length / 8.0)))
    for step in range(steps + 1):
        x = -over + (length + 2.0 * over) * step / steps
        t = min(max(x / length, 0.0), 1.0)
        ry = (r0 + (r1 - r0) * t + PY_LAVA_OUT) * swell
        rz = ry * flat
        rings.append(ring_pts(x, 0.0, ry, rz, sides=sides))
    loft(bm, rings)


def _py_under_patch(center, radii):
    """The same ball, as (verts, faces) in the region's OWN authored frame -
    which is the shape `_py_weld`'s `against` takes.

    WHY A COPY RATHER THAN THE CORE ITSELF. The pauldron's lava and the skull's
    live in `Pyrelisk_Core`, in BODY space, while the plates over them are
    authored about the shoulder joint and about the neck. Transforming the
    whole core into each of those frames would be a second statement of the
    rig's own mirror arithmetic, in the place it is least likely to be noticed
    if it is wrong. Re-deriving the one ball from the SAME constants the core
    built it from cannot drift: if the numbers move, both move.
    """
    bm = bmesh.new()
    _py_under_ball(bm, center, radii)
    mesh = bpy.data.meshes.new("_py_under_patch")
    bm.to_mesh(mesh)
    bm.free()
    out = ([tuple(v.co) for v in mesh.vertices], [tuple(p.vertices) for p in mesh.polygons])
    bpy.data.meshes.remove(mesh)
    return out


def _py_inside(tree, point, slack=0.0):
    """Is `point` inside the closed surface `tree` bounds?

    The nearest-polygon normal test, which is exact for the convex bodies the
    lava is made of and is the only test available here: `BVHTree` has no
    contains() and a parity ray cast needs several casts and a tie-break.
    """
    hit = tree.find_nearest(point, 400.0)
    if hit is None or hit[0] is None:
        return False
    location, normal, _face, _distance = hit
    return (Vector(location) - Vector(point)).dot(Vector(normal)) > slack


def _py_assert_lava_knit(core):
    """THE LAVA BODY IS ONE MASS, and it is asserted by INTERPENETRATION rather
    than by proximity.

    `_py_weld` cannot do this job and must not be pointed at it. Its measure -
    and the external instrument's - is vertex against polygon, which reads a
    deeply embedded island as FAR AWAY: the skull's ball sits eight studs
    inside the trunk's wall and measures eight studs from it, so a weld would
    "fix" it by dragging the lava out of the head. The question these six
    bodies actually raise is whether each one is buried in another, and that is
    what this measures: a body with no vertices inside any other is the floater
    (which is exactly what shipped once - the throat dome, two studs above the
    trunk's top, found by `tools/check_floaters.py` and invisible from
    everywhere because it is inside the skull).

    Note the external instrument cannot see this at all: it roots at
    `Pyrelisk_Core`, so EVERY component of this object is a root and none of
    them can be reported adrift. This is the only check that looks.
    """
    from mathutils.bvhtree import BVHTree

    islands = _py_islands(core)
    trees, points = [], []
    for verts, polys in islands:
        order = {index: n for n, index in enumerate(verts)}
        co = [tuple(core.data.vertices[i].co) for i in verts]
        faces = [tuple(order[v] for v in core.data.polygons[p].vertices) for p in polys]
        trees.append(BVHTree.FromPolygons(co, faces, all_triangles=False, epsilon=0.0))
        points.append([Vector(p) for p in co])
    worst = None
    for i in range(len(islands)):
        best = 0
        for j in range(len(islands)):
            if i == j:
                continue
            count = sum(1 for p in points[i] if _py_inside(trees[j], p))
            count += sum(1 for p in points[j] if _py_inside(trees[i], p))
            best = max(best, count)
        if worst is None or best < worst[0]:
            worst = (best, i, len(points[i]))
        if best < 3:
            centre = sum(points[i], Vector((0.0, 0.0, 0.0))) / max(len(points[i]), 1)
            raise SystemExit(
                "PYRELISK LAVA ADRIFT: the molten body has %d parts and the one centred "
                "(%.1f, %.1f, %.1f) has only %d vertices inside any other - it is a separate lump "
                "of lava, not part of one creature. Every plate on this boss is seated on this "
                "surface and the connectivity instrument roots at it, so a lava body that is not "
                "joined to the rest is a region of shell attached to nothing."
                % (len(islands), centre.x, centre.y, centre.z, best)
            )
    print("LAVA KNIT OK: %d molten bodies, the loosest has %d of its %d vertices buried in another"
          % (len(islands), worst[0], worst[2]))
    return len(islands)


def _py_assert_seam_face(torso):
    """PY_SEAM_PROUD is where the fissure module is placed; this is where the
    rock it is placed on actually came out.

    `py_seam_site` states a number and the rig, the server's hit tables and the
    client's draw all take it on trust - so it is measured on every build. The
    claim is arithmetic on three constants (`PY_LAVA_OUT`, `PY_PLATE_RIM`, the
    seam plate's own half thickness) and any of them can move without this one
    being edited; five of seven seams shipped buried inside the rock the one
    time it was eyeballed instead.

    Reads the crowns `build_py_torso` measured off the plates as it laid them
    (`_PY_SEAM_CROWNS`) rather than re-finding them in the finished mesh - see
    that measurement's note. It is therefore a PRE-WELD figure, and the weld's
    own report is what covers the studs it moves afterwards (it pulls a plate
    at most a third of a stud on this body, well inside the tolerance below).
    """
    if len(_PY_SEAM_CROWNS) != len(PY_SEAM_SPEC) * 2:
        raise SystemExit(
            "PYRELISK SEAM FACE: %d crowns recorded for %d half plates - the torso was not built, "
            "or the seam pass stopped recording what it laid."
            % (len(_PY_SEAM_CROWNS), len(PY_SEAM_SPEC) * 2))
    worst = max(abs(crown - PY_SEAM_PROUD) for crown in _PY_SEAM_CROWNS)
    if worst > 0.6:
        raise SystemExit(
            "PYRELISK SEAM FACE DRIFT: the backing plates' crown is up to %.2f studs off "
            "PY_SEAM_PROUD (%.1f). The module is placed ON that face, so the fissure is either "
            "floating off the shell or buried in it - re-derive PY_SEAM_PROUD from PY_LAVA_OUT, "
            "PY_PLATE_RIM and the plate's own half thickness." % (worst, PY_SEAM_PROUD)
        )
    print("SEAM FACE OK: the %d backing plates' crowns agree with PY_SEAM_PROUD %.1f to within "
          "%.2f studs" % (len(_PY_SEAM_CROWNS), PY_SEAM_PROUD, worst))
    return worst


# THE SKULL'S OWN LAVA, in BODY space, because `Pyrelisk_Core` is drawn once
# with the body's frame and the head is not. The head pitches on the neck
# (`PyreliskPath.headCFrame`: -24 degrees of slump to +16 of ventbreath rear)
# and NEVER yaws, so a ball authored at the head's unpitched rest position
# stays under the skull's plates through the whole range the fight uses - the
# plates swing up to ten studs across it at full slump, which is what
# `PY_PLATE_FOOT` is sized to survive.
PY_SKULL_LAVA_AT = (10.0, 0.0, 176.0)  # = neck + the skull's head-local centre


def build_py_core(rng):
    bm = bmesh.new()
    # THE MOLTEN BODY, and it is now the whole body rather than a lamp inside
    # one. Lofted off `_py_profile` ITSELF - sampled, not interpolated between
    # the table's rows - so the lava surface and the surface the plates are
    # seated on are the same function evaluated twice. The old core walked
    # PY_BODY linearly while the cladding walked the smoothstep, which put the
    # two several studs apart wherever the profile turned; at -6 studs of
    # inset nothing could see it, and at +1 everything would.
    lo = PY_BODY[0][0] - 10.0
    hi = PY_BODY[-1][0] + 6.0
    steps = int(round((hi - lo) / PY_CORE_STEP))
    # CIRCUMSCRIBED: a polygon through the profile's own radius has its flats
    # inside the curve, and the flats are what a plate's seat is measured
    # against. See PY_CORE_SIDES.
    swell = 1.0 / math.cos(math.pi / PY_CORE_SIDES)
    sections = [(lo, PY_BODY[0][1] * 0.72, PY_BODY[0][2] * 0.72)]
    for step in range(1, steps):
        z = lo + (hi - lo) * step / steps
        ry, rx = _py_profile(z)
        sections.append((z, (ry + PY_LAVA_OUT) * swell, (rx + PY_LAVA_OUT) * swell))
    sections.append((hi, 14.0, 13.0))
    rings = []
    for z, ry, rx in sections:
        rings.append([
            bm.verts.new((math.cos(i / PY_CORE_SIDES * TAU) * rx,
                          math.sin(i / PY_CORE_SIDES * TAU) * ry, z))
            for i in range(PY_CORE_SIDES)
        ])
    for a, b in zip(rings, rings[1:]):
        for i in range(PY_CORE_SIDES):
            j = (i + 1) % PY_CORE_SIDES
            bm.faces.new((a[i], a[j], b[j], b[i]))
    bm.faces.new(list(reversed(rings[0])))
    bm.faces.new(rings[-1])
    # The yoke's own molten body, so the shoulder bar cracks open like the rest
    # of the figure rather than being the one solid black thing on it.
    _py_under_ball(bm, PY_YOKE[0], PY_YOKE[1])
    # THE PAULDRONS' LAVA, in body space, and this is the one piece of the lava
    # body that is not under its own object's own origin. `Pyrelisk_Shoulder`
    # is authored about the joint with +X OUTBOARD and the rig aims it along
    # the authored +/-Y - a CONSTANT direction, never the bone's - so the
    # pauldron does not move relative to the body at all and its lava can live
    # here. The arm BONES are the opposite case and the reason this stops at
    # the shoulder: they swing, nothing static can sit under them, and their
    # plates are lapped into one mass instead (see `_py_limb_plating`).
    for side in (-1, 1):
        sx, sy, sz = PY_RIG["shoulder"]
        # authored (5, 0, 3) about the joint, through the rig's own +/-Y aim:
        # for side +1 that is Rz(+90), which sends authored x to body y.
        _py_under_ball(bm, (sx, side * (sy + 5.0), sz + 3.0),
                      (PY_PAULDRON[1][1], PY_PAULDRON[1][0], PY_PAULDRON[1][2]))
    # THE SKULL'S LAVA. See PY_SKULL_LAVA_AT.
    _py_under_ball(bm, PY_SKULL_LAVA_AT, PY_SKULL[1])
    # The throat: what the jaw opens onto, and now also what lights the cracks
    # between the skull's lower plates and the jaw's. Kept INSIDE the skull's
    # own shell - a molten dome standing proud of the rock reads as a lamp
    # round its neck.
    ellipsoid(bm, (10.0, 0.0, 166.0), (14.0, 13.0, 15.0), subdiv=2)
    return finish("Pyrelisk_Core", bm, PY_MOLTEN)


# THE PLATING SCHEDULE, band by band: (z0, z1, rows, cols, half thickness).
#
# Plate size is the aesthetic order made numeric, and the order is the
# player's: LARGEST on the chest and the back (the core of the mass), smaller
# at the waist and the neck where the body is narrow, smallest at the joints.
# `cols` is chosen against each band's own girth so the PITCH comes out near
# the numbers in the right-hand comments - which are the plate sizes, in
# studs, and they are the thing to read this table for.
#
# EIGHTY-ODD PLATES ON THE VISIBLE TRUNK, against 474 boulders before it. That
# is the note - "a torso has maybe 20-40 plates, not 474 pebbles" - taken as
# far as a 206-stud figure permits: a 30-stud plate on a chest 146 wide is the
# same plate-to-body ratio the reference's golem has, and going larger starts
# to cost the crack network its continuity.
PY_PLATE_BANDS = [
    (-58.0, -22.0, 2, 9, 3.0),  # submerged: still built, the lake is not opaque
    (-22.0, 14.0, 2, 10, 3.2),  # the waterline - 27 x 18
    (14.0, 46.0, 2, 10, 3.0),  # THE WAIST - 25 x 16, the narrow point reads narrow
    (46.0, 78.0, 1, 10, 3.4),  # 28 x 32
    (78.0, 106.0, 1, 10, 3.6),  # THE CHEST - 32 x 28, the biggest plates on the body
    (104.0, 124.0, 1, 12, 3.4),  # 30 x 20
    (124.0, 139.0, 1, 9, 2.8),  # the trapezius slope - 27 x 15
    (139.0, 154.0, 1, 7, 2.4),  # THE NECK - 20 x 15, the smallest on the trunk
]

# THE PAULDRON, as its own ellipsoid region, hoisted out of `build_py_shoulder`
# because `build_py_core` needs it too: the lava under a pauldron is authored
# in BODY space (see `build_py_core`) and the plates over it in the shoulder's
# own, and the two have to come off one set of numbers or they drift.
# (centre, radii) in the shoulder's authored frame: +X is OUTBOARD.
PY_PAULDRON = ((5.0, 0.0, 3.0), (23.0, 21.0, 19.0))


# HOW MANY CONNECTED MASSES EACH OBJECT IS ALLOWED TO BE, and why.
#
# THIS TABLE SHRANK WITH THE REMODEL, and the reason is the whole design of the
# plating. `_py_knit` asserts that an object's own plates form ONE overlapping
# mass, which was the right guarantee while the body was an aggregate of
# boulders sized past their cells - it is exactly wrong for armour plates,
# whose entire point is that they DO NOT touch each other. Knitting the torso
# would close every crack in the network and call it an improvement.
#
# So the guarantee moved rather than weakening, and it moved onto the thing
# that is now actually underneath: the LAVA. A plated region is welded against
# `Pyrelisk_Core` (`_py_weld(..., against=core)`), every plate's foot reaches
# into it, and `tools/check_posed_connectivity.py` roots its contact graph at
# `Pyrelisk_Core` - so "attached" means the same thing on both sides of the
# wire for the first time on this boss.
#
# WHAT IS STILL KNITTED, and it is one object: the JAW. Four plates round the
# throat, with the lava BEHIND them rather than under them (the throat dome is
# inside the skull and the jaw swings away from it), so the jaw is the one
# piece on the boss whose plates have to hold onto each other - which is a
# boulder aggregate's contract, so it keeps a boulder aggregate's guard.
#
# THE KNIT'S POSITIVE CONTROL STILL RUNS ON EVERY BUILD (`_py_knit_selftest`),
# and that matters more than the number of callers: a guard with one live
# customer and a control is a guard, and a guard with five customers and no
# control is a hope.
PY_COMPONENTS = {
    "Jaw": 1,
}


# The seam backing plates' crowns, MEASURED as `build_py_torso` lays them and
# held to PY_SEAM_PROUD by `_py_assert_seam_face`. The module the fight is
# fought against is placed on this face.
_PY_SEAM_CROWNS = []


def build_py_torso(rng):
    _py_chunks_reset()
    bm = bmesh.new()
    for z0, z1, rows, cols, deep in PY_PLATE_BANDS:
        _py_plating(bm, rng, z0, z1, rows, cols, deep)
    # THE YOKE: the bar across the top of the chest that the arms hang off,
    # and the single biggest reason this reads as a figure. Plated to -0.9,
    # which is nearly all the way round, because the underside of the shoulder
    # is what the player sees from the rim path looking UP and what is under it
    # now is molten: an unplated underside used to be a hole into the dark and
    # is now a lamp aimed at the rim. At -0.6 it showed as a bar of orange
    # under each clavicle on the first plated render.
    _py_plate_shell(bm, rng, PY_YOKE[0], PY_YOKE[1], 46, 3.4, min_nz=-0.9)
    # THE BACK RIDGE: seven heavy plates down the spine, laid ON the surface
    # like everything else. This is the one place the body is allowed a bigger
    # plate than its band - a ridge is what a back has - and they overlap the
    # band plates either side of them rather than sitting in a gap.
    for i in range(7):
        z = 24.0 + (i / 6.0) * 100.0
        point, normal = _py_skin(z, math.pi + rng.uniform(-0.10, 0.10), out=PY_LAVA_OUT)
        thick = 3.8
        _py_scute(bm, point + normal * (-PY_PLATE_RIM * thick), (13.0, 11.0, thick), rng,
                  normal=normal, along=(0.0, 0.0, 1.0))
    # THE SEAM SITES, last, and each is ONE PLATE SPLIT IN TWO: a pair of half
    # plates with PY_SEAM_GAP studs of open lava between them, which is the
    # fault line the fissure module is dropped into. Barely wobbled and never
    # spun, because `py_seam_site` states this pair's crown and the module has
    # to land on it - and `_py_assert_seam_face` measures that claim on every
    # build rather than trusting this arithmetic.
    half_w, half_h, deep = PY_SEAM_PLATE
    del _PY_SEAM_CROWNS[:]
    for z, bearing in PY_SEAM_SPEC:
        for floor, point, normal, across in py_seam_halves(z, bearing):
            verts = _py_scute(bm, point + normal * (-PY_PLATE_RIM * deep), (half_w, half_h, deep),
                              rng, normal=normal, along=tuple(across), yaw=0.0, wobble=0.02)
            # MEASURED OFF THE VERTICES JUST MADE, which is the only unambiguous
            # way to ask this: a scute's vertices are all on its outline, so a
            # spatial window round the plate's centre catches none of it and a
            # window wide enough to catch its rim catches its neighbours too
            # (measured: that reads 2 to 6 studs off a body that is correct).
            # `_py_scute` hands back what it built, so nothing has to be
            # inferred from where it was told to build it.
            _PY_SEAM_CROWNS.append(max((v.co - floor).dot(normal) for v in verts))
    return finish("Pyrelisk_Torso", bm, PY_OBSIDIAN)


# The head, in its own space: the origin is PY_RIG["neck"], the BASE of the
# skull, and everything is above it. That is what lets the rig swing the head
# about the neck instead of about the middle of the cranium.
PY_SKULL = ((2.0, 0.0, 24.0), (26.0, 23.0, 22.0))


def build_py_head(rng):
    _py_chunks_reset()
    bm = bmesh.new()
    # A ROCK, but a rock with a FACE, and small: 52 studs across against a
    # 224-stud shoulder span. The player fought for this twice - the head has
    # to be the first thing found on the silhouette, and it is found by being
    # SEPARATE, not by being big.
    #
    # TWENTY-TWO PLATES on the cranium, which is the reference's own head: a few
    # big rounded plates with the lava between them, not a gravel pile.
    del _PY_CROWN_SEATS[:]
    _PY_CROWN_SEATS.extend(_py_plate_shell(bm, rng, PY_SKULL[0], PY_SKULL[1], 22, 2.8, crack=0.05, min_nz=-0.75))
    # THE BROW: a heavy slab thrown forward over the eyes, its underside
    # overhanging the face. This is the line that says "face" from the rim
    # path, so it is the biggest single plate on the head.
    for i in range(3):
        y = -13.0 + i * 13.0
        _py_scute(bm, (22.0 - abs(y) * 0.16, y, 29.5), (9.0, 8.0, 3.4), rng,
                  normal=(0.80, y * 0.012, 0.60), along=(0.0, 1.0, 0.0))
    # Cheeks, squared off round a recessed face.
    for side in (-1, 1):
        _py_scute(bm, (13.5, side * 18.0, 14.0), (11.0, 10.0, 3.2), rng,
                  normal=(0.55, side * 0.80, -0.2), along=(0.0, 0.0, 1.0))
    # The muzzle block the jaw shuts onto.
    _py_scute(bm, (19.5, 0.0, 8.0), (11.0, 9.0, 3.2), rng, normal=(0.85, 0.0, -0.5),
              along=(0.0, 1.0, 0.0))
    # The back of the skull, and a short thick neck stub so the head sits ON
    # something rather than floating off the yoke.
    _py_scute(bm, (-17.0, 0.0, 22.0), (13.0, 12.0, 3.4), rng, normal=(-0.9, 0.0, 0.2),
              along=(0.0, 1.0, 0.0))
    for i in range(5):
        a = (i / 5.0) * TAU + 0.4
        _py_scute(bm, (math.cos(a) * 12.0, math.sin(a) * 11.0, 4.0), (7.0, 6.0, 2.8), rng,
                  normal=(math.cos(a), math.sin(a), -0.25), along=(0.0, 0.0, 1.0))
    return finish("Pyrelisk_Head", bm, PY_OBSIDIAN)


def build_py_jaw(rng):
    _py_chunks_reset()
    bm = bmesh.new()
    # A blunt plated underjaw, hinged at PY_JAW_HINGE - it swings open for the
    # vent-breath and shows the throat. No teeth: this is broken stone. LAPPED
    # rather than cracked, for the arm bones' reason: the jaw swings, and the
    # throat's lava is behind it rather than under it.
    _py_scute(bm, (8.0, 0.0, 8.0), (13.5, 12.5, 3.2), rng, normal=(0.0, 0.0, -1.0),
              along=(1.0, 0.0, 0.0))
    _py_scute(bm, (20.0, 0.0, 9.0), (9.5, 9.5, 3.0), rng, normal=(0.4, 0.0, -0.9),
              along=(0.0, 1.0, 0.0))
    for side in (-1, 1):
        _py_scute(bm, (12.0, side * 10.0, 10.0), (7.0, 6.0, 2.8), rng,
                  normal=(0.2, side * 0.9, -0.3), along=(1.0, 0.0, 0.0))
    _py_knit("Jaw", PY_COMPONENTS["Jaw"])
    return finish("Pyrelisk_Jaw", bm, PY_OBSIDIAN)


def _py_seat_crown(base, tip, tree, bite=1.5):
    """Sink a crown shard until its base is INSIDE the skull's rock, and prove
    it - or refuse to build.

    A spike is not a plate and the knit pass cannot see it, so this is the
    crown's own version of the same rule. The base is walked back down its own
    axis in half-stud steps until it is measurably `bite` studs inside the head
    mesh; if no step lands inside rock the head has moved out from under the
    crown and the export fails rather than shipping four shards hanging over a
    skull.

    MEASURED AGAINST THE MESH, not against the plates' bounding spheres, and
    the remodel is what forced it: the skull is twelve big plates now rather
    than thirty small ones, and a plate's recorded radius includes its buried
    foot, so a sphere test on it is both too generous near the middle of a
    plate and too mean near the pole between two. The mesh is where the rock
    is; ask the mesh.
    """
    axis = (Vector(base) - Vector(tip)).normalized()
    for step in range(40):
        point = Vector(base) + axis * (step * 0.5)
        if _py_inside(tree, point, slack=bite):
            return point
    raise SystemExit(
        "PYRELISK CROWN FAILED: a shard based at (%.1f, %.1f, %.1f) found no head rock "
        "within 20 studs down its own axis - it would float over the skull." % tuple(base))


# The cranium's plate seats, in head space, recorded by `build_py_head` so the
# crown can grow its shards out of the MIDDLE of a plate. A shard authored on a
# bearing instead lands in a crack as often as not - measured: two of four did,
# on a twelve-plate skull - and a shard based in a crack is based in the HOLLOW
# between the rock and the lava, which is a floating shard with extra steps.
_PY_CROWN_SEATS = []
# How far apart, in studs, two shards' own plates have to be, and how far off
# vertical a plate may face and still carry one. Four shards on a 52-stud
# skull: closer than the spacing and the crown reads as a clump; flatter than
# the facing and it reads as horns.
PY_CROWN_SPACING = 12.0


def build_py_crown(rng, head):
    bm = bmesh.new()
    # Short thick shards off the crown, FLUSH-MOUNTED: they crest the head by
    # about ten studs and no more, because a colonnade up here is the thing
    # that makes a small head look like rubble. Each base is pushed down its
    # own axis until it is measurably inside a head plate (`_py_seat_crown`)
    # and the tip is held where it was authored, so the silhouette is the one
    # the 09-09 remodel settled and only the seating has moved.
    # THE BASES ARE AUTHORED AS BEARINGS OFF THE SKULL, not as points, and the
    # remodel is what forced that too. They used to be four fixed head-space
    # points, chosen against a cranium that was thirty small boulders: the
    # plating makes the head a SHELL over a lava ball, so a point four studs
    # inside the old cladding is now inside the HOLLOW - below the plates'
    # inner faces, in the gap between the rock and the molten body - and a
    # shard seated there would hang in it. So each base starts six studs
    # OUTSIDE the skull's own surface on its own bearing and is walked inward
    # until it is measurably inside the rock.
    tree = _py_bvh(head)
    # The four highest plates that are not on top of each other, front to back.
    chosen = []
    for seat, normal in sorted(_PY_CROWN_SEATS, key=lambda pair: -pair[0].z):
        if len(chosen) >= 4:
            break
        # UPWARD-FACING ONLY: a shard grown off a plate on the SIDE of the
        # skull is a horn, and four horns on a small head is the colonnade the
        # design spent two passes removing. Measured on the first build that
        # took whatever was highest: the crown's y spread went from +/-15 to
        # +/-29 and its top from z 55 to 68.
        if normal.z < 0.42:
            continue
        if all((seat - taken).length > PY_CROWN_SPACING for taken, _n in chosen):
            chosen.append((seat, normal))
    if len(chosen) < 4:
        raise SystemExit(
            "PYRELISK CROWN FAILED: only %d of the skull's plates are %.0f studs apart, so there "
            "is nowhere to put four shards. The cranium's plate count or PY_CROWN_SPACING moved."
            % (len(chosen), PY_CROWN_SPACING))
    for i, (seat, normal) in enumerate(sorted(chosen, key=lambda pair: -pair[0].x)):
        side = -1 if i % 2 else 1
        base = seat + normal * 2.0
        tip = base + normal * 3.0 + Vector((-2.5, side * 1.5, 2.5 + rng.uniform(-0.5, 2.0)))
        # STUBBIER AND WIDER THAN THE BOULDER BODY'S (which ran 5.0-6.5 wide
        # and about ten studs long): on a plated head those read as four grey
        # CONES stuck on the skull, and "no spikes, no chunks poking off the
        # silhouette" is the whole of the plating brief. At 7-8.5 wide against
        # a five-stud rise they are broken SHARDS of the same armour, which is
        # what a crown on this body should be.
        spike(bm, tuple(_py_seat_crown(base, tip, tree)), tuple(tip), rng.uniform(7.0, 8.5), sides=5)
    return finish("Pyrelisk_Crown", bm, PY_BASALT)


PY_EYE_AT = (10.0, 18.0)  # head-local (|y|, z) of each slit; the x is MEASURED
PY_EYE_SIZE = (3.6, 5.4, 2.4)
# How far the slit's CENTRE sits outside the rock's surface. It must stay under
# half of PY_EYE_SIZE's own x, or the slit's inner face clears the rock and the
# weld spends a pull putting it back: at 1.4 against a half thickness of 1.8
# the box straddles the surface by 0.4 and stands 3.2 studs proud of it.
PY_EYE_PROUD = 1.4


def build_py_eyes(head):
    """Two slits under the brow, SET INTO the face rather than authored at a
    fixed depth.

    They have to be PROUD OF THE SKULL: an early pass sank them nine studs
    inside the face plane and only one ever showed. They are also SMALLER than
    the boulder body's pair (5 x 6 x 2.8) - on the plated skull those read as
    two strips of tape stuck to the cheeks, because a 6-stud emissive box at
    AgX's shoulder is a flat pale rectangle whatever colour it is given. A
    narrow slit reads as an eye.

    AND THE DEPTH IS MEASURED, which is the fix for a defect
    `tools/check_posed_connectivity.py` found and every build-time guard on
    this boss missed: at a fixed x 30.8 one slit landed over a CRACK between
    two skull plates and hung five studs off the rock. A plated head has no
    single face depth - the crowns stand 3.4 studs over the seat and the cracks
    go 3.4 under it - so the only honest way to put something on it is to walk
    in until the rock is there, exactly as `_py_seat_crown` does.
    """
    tree = _py_bvh(head)

    def face_at(y, z):
        """Where the rock's outer surface is on the line (y, z), or None."""
        for step in range(60):
            x = 40.0 - step * 0.5
            if _py_inside(tree, Vector((x, y, z)), slack=0.4):
                return x
        return None

    # ONE SITE, MEASURED ON BOTH FLANKS AT ONCE, and the pair is what is
    # measured rather than each eye on its own. Two reasons, and the second is
    # the one that cost a build:
    #
    #   * a plated head has no single face depth. The crowns stand 3.4 studs
    #     over the seat and the cracks go 3.4 under it, so an eye authored at a
    #     fixed depth (the 30.8 this replaced, itself solved against the
    #     boulder cladding's reach at the POLE) lands on a crown on one flank
    #     and five studs off the rock on the other. The posed-connectivity
    #     instrument found exactly that and no build-time guard did.
    #   * the skull's plate lattice is NOT symmetric, so measuring each eye
    #     independently put one at x 21 and the other at x 32 - a face with one
    #     eye twelve studs deeper than the other, which reads as damage. So the
    #     bearing that is chosen is the one whose WORSE flank is most proud,
    #     and both eyes then sit at the same depth by construction.
    best = None
    for dy in (-3.0, -1.5, 0.0, 1.5, 3.0):
        for dz in (-2.0, 0.0, 2.0):
            y, z = PY_EYE_AT[0] + dy, PY_EYE_AT[1] + dz
            left, right = face_at(y, z), face_at(-y, z)
            if left is None or right is None:
                continue
            worst = min(left, right)
            if best is None or worst > best[0]:
                best = (worst, y, z)
    # 18 is a FLOOR ON THE MEASUREMENT, not a target: the cranium's own surface
    # at this height and bearing is x 21-25 (the ellipsoid narrows hard off the
    # centre line, and the plates add 3.4), so anything much under this means
    # every candidate found a crack floor rather than a crown.
    if best is None or best[0] < 18.0:
        raise SystemExit(
            "PYRELISK EYES FAILED: the most proud rock both flanks of the face share near the "
            "authored eye site is at x %s, so a slit there would hang in the air or sit inside "
            "the skull. The plating has moved out from under the face."
            % ("nothing" if best is None else "%.1f" % best[0]))
    depth, y, z = best
    bm = bmesh.new()
    for side in (-1, 1):
        box(bm, (depth + PY_EYE_PROUD, side * y, z), PY_EYE_SIZE,
            Matrix.Rotation(math.radians(side * 10), 3, "X"))
    return finish("Pyrelisk_Eyes", bm, PY_EMBER)


def build_py_shoulder(rng):
    _py_chunks_reset()
    bm = bmesh.new()
    # THE PAULDRON, authored about the shoulder joint with +X OUTBOARD (the
    # rig aims it along +/-Y). It is the widest thing on the boss and the
    # reason the shoulders beat the waist: the joint is at y 84 and this cap
    # carries the rock out to about y 110, against a waist half width of 44.
    #
    # PLATED WITH A CRACK LIKE THE TRUNK, not lapped like the bones, because
    # this one does have lava under it - `build_py_core` puts a ball at the
    # joint in body space and the pauldron never moves relative to the body.
    # Plated PAST the equator (-0.95) for the same reason the yoke is: what is
    # under it glows, and the rim path looks UP at this.
    _py_plate_shell(bm, rng, PY_PAULDRON[0], PY_PAULDRON[1], 16, 3.2, min_nz=-0.95)
    # THE PAULDRON CREST: two heavy plates that overlap the cap and each other,
    # so the crest is on the silhouette and is made of the same stone as
    # everything under it. It used to be an 18-stud cone standing off a cap
    # whose rock only reached z 22 - "too many like floating objects".
    for x, z, r in ((-1.0, 17.0, 9.0), (-6.0, 24.0, 7.5)):
        _py_scute(bm, (x, 0.0, z), (r, r * 0.85, 4.0), rng,
                  normal=(-0.45, 0.0, 0.89), along=(0.0, 1.0, 0.0))
    return finish("Pyrelisk_Shoulder", bm, PY_OBSIDIAN)


# THE ARMS ARE THE ONE PLACE THIS REMODEL IS NOT LITERAL, and it is worth
# being exact about why rather than letting a render raise it.
#
# The brief is "lava in every crack, head to fists". Nothing can put lava
# under a swinging bone: `Pyrelisk_Core` is drawn ONCE with the body's own
# frame, the pack is CLOSED at seventeen objects, and a part carries one
# material - so there is no third thing available to be the upper arm's molten
# interior, and a limb object cannot be half Neon. (What would buy it: the
# client drawing a handful of extra `Seam` instances per bone, which is a
# change to the fight's own module bookkeeping and belongs to a lane that owns
# more than these three files. It is in the report as owed.)
#
# So a bone is plated on a ROCK underbody (`_py_bone_shell`) instead of a
# molten one. Everything else about the plating is identical - same primitive,
# same cracks, same bevels, same seat - and what the eye gets is a plated limb
# whose crack network is a dark groove rather than a lit one. From the rim path
# the arms read as the dark half of a body veined with fire, which is the
# 70/30 the brief asks for; up close, on `_preview_arm`, they are plainly not
# lit and that is the honest state of it.
PY_LIMB_SIDES = 20  # facets round a bone's own underbody


def _py_cone_normal(c, s, ry, rz, taper, flat):
    """The OUTWARD NORMAL of a tapered elliptic tube along +X, at the point
    (c * ry, s * rz) on the section at that x.

    WRITTEN OUT RATHER THAN GUESSED, because the guess was here for three
    passes and it tilted every plate on the arms. What was here was

        Vector((-(r1 - r0) / length, c / ry, s / rz))

    which mixes a SLOPE (0.0625 on the forearm) with a RECIPROCAL RADIUS
    (1/11.8 = 0.085 at the top of it) as though they were the same units. They
    are not: the axial term came out nearly as large as the radial one, so the
    normal on top of the forearm pointed forty degrees FORWARD and the plate
    seated on it stood on its trailing edge. The measured symptom was a
    forearm crown 4.5 studs higher than the plate arithmetic said it could be,
    which the walk slab then rode on - and the fallen route's hand ramp went
    from 20 degrees to 31 because of it.

    The surface is F = (y/ry(x))^2 + (z/rz(x))^2 - 1, so grad F is

        (-(c^2 * ry'/ry + s^2 * rz'/rz),  c/ry,  s/rz)

    and the axial term is a slope DIVIDED BY ITS OWN RADIUS, which is what
    puts it on the same scale as the other two.
    """
    ry_d = taper
    rz_d = taper * flat
    axial = -(c * c * ry_d / max(ry, 1e-6) + s * s * rz_d / max(rz, 1e-6))
    return Vector((axial, c / max(ry, 1e-6), s / max(rz, 1e-6))).normalized()


def _py_limb_plating(bm, rng, length, r0, r1, rings, cols, deep, flat=1.0,
                     crack=PY_PLATE_CRACK):
    """A limb bone along +X FROM ITS JOINT, plated in beveled rounded slabs.

    Radii are symmetric about the axis on purpose. An early pass jittered
    chunks sideways off it, which made the left and right arms read as two
    different limbs (they are the same mesh mirrored) and made the piece's
    roll matter to the rig. `flat` squashes the section vertically; the
    forearm uses it because the forearm IS THE RAMP and a round arm has no
    single height a flat slab can sit on.

    EVERY PLATE'S LONG AXIS IS ALIGNED TO THE BONE. `half_a` is the
    along-the-bone half extent, and `along=(1,0,0)` is what points it there:
    without it the basis takes an arbitrary reference and the limb reads as
    scree poured round a stick.
    """
    _py_bone_shell(bm, length, r0, r1, flat=flat, sides=PY_LIMB_SIDES)
    span = length / rings
    for ring in range(rings):
        t = (ring + 0.5) / rings
        x = span * (ring + 0.5)
        ry = r0 + (r1 - r0) * t
        rz = ry * flat
        twist = rng.uniform(0.0, TAU) + (0.5 if ring % 2 else 0.0) / cols * TAU
        pitch = TAU * (ry + rz + 2.0 * PY_LAVA_OUT) * 0.5 / cols
        for col in range(cols):
            a = twist + (col + rng.uniform(-0.10, 0.10)) / cols * TAU
            c, s = math.cos(a), math.sin(a)
            point = Vector((x, c * (ry + PY_LAVA_OUT), s * (rz + PY_LAVA_OUT)))
            normal = _py_cone_normal(c, s, ry, rz, (r1 - r0) / length, flat)
            thick = deep * rng.uniform(PY_DEEP_LO, PY_DEEP_HI)
            half_a = _py_cell(span, crack) * 0.5 * rng.uniform(PY_SIZE_LO, PY_SIZE_HI)
            half_t = _py_cell(pitch, crack) * 0.5 * rng.uniform(PY_SIZE_LO, PY_SIZE_HI)
            _py_scute(bm, point + normal * (-PY_PLATE_RIM * thick), (half_a, half_t, thick), rng,
                      normal=normal, along=(1.0, 0.0, 0.0))
    # THE CAP RINGS, one at each end of the bone, and they are the fix for the
    # gap at every joint. The loop above lays its first ring half a span IN
    # from x=0 and its last half a span short of the tip, so a bone's rock
    # stopped several studs shy of the joint at both ends: the fist hung off
    # the forearm with daylight between them from the review angle, and the
    # elbow was two rings of stone with a bare axis between.
    for end, x, ry in ((-1.0, 0.0, r0), (1.0, length, r1)):
        rz = ry * flat
        twist = rng.uniform(0.0, TAU)
        pitch = TAU * (ry + rz + 2.0 * PY_LAVA_OUT) * 0.5 / cols
        for col in range(cols):
            a = twist + (col + rng.uniform(-0.10, 0.10)) / cols * TAU
            c, s = math.cos(a), math.sin(a)
            point = Vector((x, c * (ry + PY_LAVA_OUT) * 0.80, s * (rz + PY_LAVA_OUT) * 0.80))
            # DELIBERATELY TILTED OUTWARD along the bone (unlike the loop
            # above, which uses the true surface normal): a cap ring's job is
            # to close the joint, so it faces the way the bone ends.
            normal = Vector((end * 0.88, c * 0.48, s * 0.48)).normalized()
            thick = deep * rng.uniform(PY_DEEP_LO, PY_DEEP_HI)
            half_a = _py_cell(span * 0.62, crack) * 0.5 * rng.uniform(PY_SIZE_LO, PY_SIZE_HI)
            half_t = _py_cell(pitch, crack) * 0.5 * rng.uniform(PY_SIZE_LO, PY_SIZE_HI)
            _py_scute(bm, point + normal * (-PY_PLATE_RIM * thick), (half_a, half_t, thick), rng,
                      normal=normal, along=(1.0, 0.0, 0.0))


def _py_bone_radius(length, r0, r1, x, flat=1.0):
    """The bone's SEAT radii at `x` - what a feature plate has to be laid on if
    the weld is not to spend a pull dragging it down onto the shell."""
    t = min(max(x / length, 0.0), 1.0)
    ry = r0 + (r1 - r0) * t + PY_LAVA_OUT
    return ry, ry * flat


def build_py_upper_arm(rng):
    _py_chunks_reset()
    bm = bmesh.new()
    # Roughly a third of the body's width, which is where the references hang
    # them, and thicker at the shoulder than at the elbow.
    _py_limb_plating(bm, rng, PY_RIG["upper_arm"], 21.0, 17.0, 3, 7, 2.4, crack=0.20)
    # The elbow knot: a heavier ring of plate at the far end, so the joint is
    # a THING on the silhouette instead of a place where the taper changes.
    knot_x = PY_RIG["upper_arm"] - 3.0
    ry, rz = _py_bone_radius(PY_RIG["upper_arm"], 21.0, 17.0, knot_x)
    for i in range(5):
        a = (i / 5.0) * TAU + 0.35
        c, s = math.cos(a), math.sin(a)
        _py_scute(bm, (knot_x, c * ry, s * rz), (9.0, 8.0, 3.6), rng,
                  normal=(0.25, c, s), along=(1.0, 0.0, 0.0))
    return finish("Pyrelisk_UpperArm", bm, PY_OBSIDIAN)


def build_py_forearm(rng):
    _py_chunks_reset()
    bm = bmesh.new()
    _py_limb_plating(bm, rng, PY_RIG["forearm"], 18.0, 14.0, 3, 7, 2.3, flat=0.74, crack=0.20)
    # The point of the elbow, thrown back off the joint - the one piece of
    # this arm that tells you which way it bends. Seated ON the bone's own
    # shell (which is what `_py_bone_radius` is for): authored a stud or two
    # inside it, the weld spends a two-stud pull straightening it out.
    ry, rz = _py_bone_radius(PY_RIG["forearm"], 18.0, 14.0, 2.0, flat=0.74)
    _py_scute(bm, (2.0, 0.0, -rz), (10.0, 10.0, 3.2), rng, normal=(-0.35, 0.0, -0.94),
              along=(1.0, 0.0, 0.0))
    return finish("Pyrelisk_Forearm", bm, PY_OBSIDIAN)


def build_py_hand(rng):
    _py_chunks_reset()
    bm = bmesh.new()
    # A blunt PLATED FIST, not a claw, and the reference's own note: "a few big
    # rounded plates per hand". Eight on the mass plus four knuckles, on a rock
    # underbody for the bones' reason, so the fist reads as a gauntlet rather
    # than as a bag of gravel. It is also a platform when it plants, so the
    # mass goes into the fist rather than into talons.
    fist_at, fist_r = (11.0, 0.0, 0.0), (13.0, 14.0, 12.0)
    _py_under_ball(bm, fist_at, fist_r)
    _py_plate_shell(bm, rng, fist_at, fist_r, 8, 2.6, crack=0.20)
    # THE KNUCKLES, seated on that same shell rather than authored just inside
    # it: three across the front and the thumb's off the inboard flank.
    out = _py_lava_radii(fist_r)
    for i in range(3):
        y = -8.5 + i * 8.5
        unit = Vector((0.92, y * 0.06, -0.16)).normalized()
        _py_scute(bm, Vector(fist_at) + Vector((unit.x * out[0], unit.y * out[1], unit.z * out[2])),
                  (7.0, 6.0, 3.2), rng, normal=tuple(unit), along=(0.0, 1.0, 0.0))
    unit = Vector((-0.18, -0.94, -0.28)).normalized()
    _py_scute(bm, Vector(fist_at) + Vector((unit.x * out[0], unit.y * out[1], unit.z * out[2])),
              (7.0, 6.5, 3.2), rng, normal=tuple(unit), along=(1.0, 0.0, 0.0))
    return finish("Pyrelisk_Hand", bm, PY_BASALT)


# THE FISSURE, station by station: (y along the crack, z across it, half
# width, how far the molten lip stands proud of the plate face).
#
# WHY A ZIGZAG AND NOT A BLOB (2026-09-09). What was here was a six-sided
# wedge 12 studs across with three stubby spikes off it - a MARKER, and it
# read as one: a lamp bolted to the rock. The fight's whole first-encounter
# question is "where do I shoot this thing", and the answer has to be
# something the rock itself is doing. So the seam is now a crack: thirty
# studs of it, torn down the shell between two courses of cladding, kinked at
# every station the way rock actually splits and pinched to nothing at both
# ends. From the rim path it reads as a fault line with fire at the bottom
# of it, which is what it is.
#
# THE AXES, and they are not free. `y` runs UP THE SHELL in the game (the
# module is spun so its +X is the outward normal, and after the mirror the
# mesh's +Y lands on the part's own vertical tangent - see the note on
# `spin` in PyreliskBodyController's AUTHORED_BOX). `z` runs along the
# surface. Swap them and the crack lies in a horizontal band across the
# chest, which is a much weaker read: a vertical split says the armour is
# coming APART, a horizontal one says it has a stripe.
#
# THIRTY LONG, against a backing plate 34 tall (PY_SEAM_PLATE's 17 half
# height): the crack has to end ON rock at both ends or it reads as a gap
# between two boulders rather than a break in one. That also caps how far the
# renderer may swell an OPEN seam - the client scales the whole part, and at
# 1.16x this is 34.8, which is the plate. Any more and the fissure's ends
# hang in mid air.
#
# HALF AS WIDE AGAIN (2026-09-12), and the reason is the plating: the body's
# ambient crack network is two to four studs of lit rock, EVERYWHERE, so a
# fissure six studs across is no longer a fault line - it is a slightly fat
# crack, and act 1 is "shoot the six flank seams" from 150-230 studs out. The
# `w` column is therefore 1.5x what it was, peaking at 5.1 (a ten-stud gape
# against a three-stud crack), and the backing plate it is torn through is
# SPLIT into two halves nine studs apart (PY_SEAM_GAP) so the geometry under
# the module says the same thing. Brightness is not spent on this: a closed
# seam still sits at the crack network's own heat, because brightness is the
# OPEN state's only channel and lending it to the closed one leaves open with
# nowhere left to go.
# The `out` column - how far the molten LIP stands proud of the plate's face -
# is 1.8x what it was, for the same findability reason as the gape: a raised
# torn lip catches the sun on one side and shadows the other, which is a
# feature the eye picks up at 300 studs where a colour difference does not.
PY_SEAM_LINE = [
    (-15.0, 0.3, 0.55, -1.1),
    (-11.6, -1.4, 2.30, 0.7),
    (-8.2, 0.5, 3.60, 1.8),
    (-4.4, -1.6, 5.10, 2.2),
    (-0.6, 0.3, 5.90, 2.3),
    (3.0, 2.1, 5.00, 2.2),
    (6.4, 0.4, 4.00, 1.8),
    (10.0, 1.8, 2.50, 0.9),
    (13.2, 0.6, 1.40, 0.0),
    (15.0, 1.3, 0.50, -1.3),
]
# How deep the channel runs, from the module's origin on the plate's CROWN.
# -5.8 puts its floor half a stud INSIDE the lava surface (the crown stands
# 5.2 above it), so the fissure bottoms out in the molten body rather than in
# the plate - which is what makes it the same fire as every other crack.
PY_SEAM_FLOOR = -5.8


def build_py_seam():
    bm = bmesh.new()
    # A CHANNEL, not a wedge: four verts per station - two on the plate's face
    # (the lips of the crack) and two down in the dark - lofted along +Y.
    #
    # The winding is chosen for an advance along +Y rather than the +X `loft`
    # documents, and it is not decoration: Roblox meshes are single-sided, so
    # a reversed loft is a seam you can only see from inside the boss. Walked
    # through: on the +Z side of the section the step runs +X, and
    # step x advance = +Z, which is outward there. Every other side follows.
    rings = []
    for y, z, w, out in PY_SEAM_LINE:
        rings.append([
            (PY_SEAM_FLOOR, y, z + w * 0.30),
            (out, y, z + w),
            (out, y, z - w),
            (PY_SEAM_FLOOR, y, z - w * 0.30),
        ])
    loft(bm, rings)
    # HAIRLINE OFFSHOOTS. A crack that stops dead at its own edge reads as a
    # cut; real rock frays. Six of them, thrown off the widest stations
    # roughly across the crack, each running back INTO the plate (-1.4 on x)
    # so they are lit slivers in the shadow rather than glowing whiskers
    # standing off the surface.
    for index in (2, 3, 4, 5, 6):
        y, z, w, out = PY_SEAM_LINE[index]
        side = 1.0 if index % 2 == 0 else -1.0
        # SHORTER AND SUNK (2026-09-12). At `reach` 3.4 + 1.6w off a fissure
        # half again as wide as it used to be, and based 0.4 under the lip,
        # these came out as glowing WHISKERS standing off the plate - five
        # orange spines per seam, and the plated body's own note is that
        # nothing may poke off the silhouette. Based a stud further down, run
        # back INTO the plate, and half the length: what they are for is to
        # stop the crack ending in a straight edge, and a two-stud sliver in
        # the shadow of the lip does that.
        reach = 2.0 + w * 0.5
        spike(bm,
              (out - 1.3, y, z + side * w * 0.8),
              (-2.2, y + side * reach * 0.55, z + side * (w + reach)),
              0.6, sides=4)
    obj = finish("Pyrelisk_Seam", bm, PY_MOLTEN)
    # Ry(-90) is what maps +X onto +Z. Ry(+90) maps it onto -Z, which points
    # the crack INTO the rock; Vent carries the same sign, and so must the
    # `spin` the client applies to the printed (PRE-spin) bbox.
    obj.rotation_euler = (0.0, math.radians(-90), 0.0)
    return obj


# HOW FAR THE VENT'S SHAFT REACHES BELOW ITS OWN SITE, so that its base is in
# the ROCK and not merely on the slab standing over it. PROVISIONAL: overwritten
# by `_py_seat_vents` with the measured worst case across the three sites.
#
# THE DEFECT THIS FIXES. `py_vent_sites` seats each vent on `py_deck_top` - the
# deck's WALKING FACE - and that is the right place for the vent's mouth,
# because a vent whose base is not on the footing you fight it from is
# unreachable by construction. But the deck's walking face is 4.6 studs above
# the rock (0.6 of deliberate clearance plus 4 of slab), so a shaft that starts
# there starts in mid-air and is held up only by touching the slab. The slab is
# real geometry, so the contact graph called it attached and nothing complained
# - but the thing the player sees is a chimney resting on a plate with daylight
# under it, and the moment anyone makes the decks invisible (they are FOOTING,
# and footing is a candidate for exactly that) the vents are floating.
#
# So the shaft grows DOWNWARD through the slab into the rock. The mouth, the
# spikes and every authored site stay exactly where they were - PyreliskPath's
# VENTS table and the client's draw are untouched - and the only thing that
# changes is that the chimney now has a foot.
PY_VENT_DROP = 6.0
PY_VENT_BITE = 1.4  # how far INTO the rock the foot goes, past first contact


def _py_seat_vents(torso):
    """Measure the rock under each vent site and size the shaft's foot to the
    deepest of them - the `_py_seat_decks` pattern, one object over.

    Returns the per-site (rock top, deck face, depth needed) for the HANDOFF.
    """
    global PY_VENT_DROP
    measured = []
    for (x, y, _z), _normal in py_vent_sites():
        top = _py_rock_top(torso, x - 11.0, x + 11.0, y - 11.0, y + 11.0, default=None)
        face = None
        for index, (centre, size) in enumerate(PY_WALK_DECKS):
            if abs(centre[0] - x) < 1e-6 and abs(centre[1] - y) < 1e-6:
                face = py_deck_top(index)
        if top is None or face is None:
            continue
        measured.append((top, face, face - top))
    if measured:
        PY_VENT_DROP = round(max(depth for _top, _face, depth in measured) + PY_VENT_BITE, 1)
    return measured


def build_py_vent(rng):
    bm = bmesh.new()
    # THE FOOT, and it is measured (see PY_VENT_DROP): one more collar running
    # from below the rock line up into the first of the five, so the chimney
    # stands ON the boss rather than on the plate over it. Wider than the
    # collar above it because it is buried - what shows is the shaft, what
    # holds it is this.
    disc(bm, -PY_VENT_DROP, 3.0, 11.0, 10.2, sides=7)
    # THE MOUNTED BREAKABLE: a vent shaft you smash while standing on the
    # boss. A cracked chimney of stacked collars, throat open to the core -
    # the rig drops a Seam inside it for the glow. Two thirds of its old size,
    # because it stands on a deck that is now 62 studs lower.
    #
    # THE CROWN SPIKES WERE THE FLOATERS (2026-09-11). The chimney's four
    # collars ran x 0..13.5 and the five spikes were based at x=23 - NINE AND A
    # HALF STUDS off the end of the shaft they are supposed to be growing out
    # of. Three vents stand on the decks across the boss's shoulders and spine,
    # pointing up, so what the player saw from the rim path was fifteen small
    # dark shards hanging in the air over each shoulder. That is the "too many
    # like floating objects" complaint, and it is the single most visible
    # instance of it on the model.
    #
    # So the shaft is lofted the whole way to the spikes' bases instead: five
    # collars reaching x 24, each overlapping its neighbour by ~2.8 studs and
    # NECKING DOWN from r 10 to r 5, and the spikes based at x 20 inside the
    # top collar rather than nine studs past it.
    #
    # THE SPIKE TIPS ARE BLUNTED FOR THE PLATING (2026-09-12) and the bbox
    # moved with them - PyreliskBodyController's AUTHORED_BOX row is re-pasted
    # in the same pass (lo -10.2,-9.9,-10.7 hi 28.4,11,10.7; it was
    # lo -10.8 hi 34.8 with the old needles). The plated body's whole note is
    # "no spikes, no scree, no chunks poking off the silhouette", and three
    # chimneys each wearing a crown of five 2-stud cones were the most
    # spike-like thing left on the boss: they read as a thistle on each
    # shoulder from the rim path. Shorter, much fatter, and five-sided rather
    # than four - broken teeth on a chimney rather than pins.
    for i in range(5):
        t = i / 4
        disc(bm, t * 17.0, t * 17.0 + 7.0, 10.0 - t * 4.4, 9.5 - t * 4.4, sides=7)
    for i in range(5):
        a = (i / 5) * TAU + 0.3
        # BLUNTED FOR THE PLATING (2026-09-12): these were 2-stud cones
        # reaching x 28-36, and on a body whose whole aesthetic note is "no
        # spikes, no scree, no chunks poking off the silhouette" three vents
        # wearing a crown of five needles each were the most spike-like thing
        # left on the boss - measured on the first plated render, they read as
        # a thistle on each shoulder. Shorter and much fatter: the chimney
        # still ends in broken teeth, but they are teeth rather than pins.
        spike(bm, (19.0, math.cos(a) * 4.0, math.sin(a) * 4.0),
              (26.5 + rng.uniform(-2.0, 2.0), math.cos(a) * 7.5, math.sin(a) * 7.5), 3.4, sides=5)
    obj = finish("Pyrelisk_Vent", bm, PY_OBSIDIAN)
    obj.rotation_euler = (0.0, math.radians(-90), 0.0)
    return obj


# ======================================================== ACT 3'S TARGETS
#
# The two objects slice 4 adds, and they take the pack to its FINAL 17.
#
# `Pyrelisk_ArmRock` is the third MODULE in the pack (Seam, Vent, ArmRock) and
# it follows their convention to the letter: authored ALONG +X in the mesh,
# with `rotation_euler = (0, radians(-90), 0)` spinning that +X onto +Z, which
# is the outward surface normal the rig seats it against. The sign matters and
# it has bitten this pack once already - see build_py_seam's note. Ry(+90)
# would point the boil INTO the arm, and on a rock that is nearly rotationally
# symmetric about its own axis that ships INVISIBLY: the silhouette is the
# same either way and only the fact that the glow is buried gives it away.
# `PyreliskBodyController`'s AUTHORED_BOX carries `spin = -1` to match.
#
# `Pyrelisk_NeckCore` is NOT a module. It is ONE object at the collar, drawn
# once, at `PyreliskPath.neckCorePoint` with the BODY's own rotation - so it
# is authored with +Z as the body's up and carries no spin at all.
#
# ------------------------------------------------------------ THE ARM ROCK
#
# A magma boil in a basalt collar: a flared rocky lip with a dome standing out
# of the middle of it. ~11 studs across, which is the number the design gives
# and the number `pyrelisk_ventrock`'s shotRadius 6.0 is solved against.
#
# THE GLOW STANDS PROUD OF THE MASS, which is `build_kg_heart_glow`'s lesson
# applied to a target rather than to anatomy: the dome's apex is authored ~4.1
# studs past the collar's own rim, so the lit part of the rock is the part a
# player sees first from down the route. A boil level with its collar is a
# rock with an orange patch on it, and at 150 studs that is not a target.
#
# WHY IT IS A LOFT AND NOT AN AGGREGATE OF `_py_rock` BOULDERS. Everything
# else on this body is boulders, and it should be - the body is rubble. This
# is not: it is one closed surface, because `PY_MESH_COMPONENTS` holds it to a
# single island (see that table's note) and because the client draws it as one
# Neon part. Rings of jittered points bridged end to end give the same broken
# read without the island count.
#
# AND IT IS A DOME, NOT A SPIKE. The first cut necked from r 2.8 to r 0.7 over
# two rings and the six of them read from the rim path as pale CONES stuck on
# the arm - traffic cones, not boils. Four rings of gentler taper, ending at
# r 1.2, is the same silhouette height with a rounded top, which is what says
# "molten" rather than "placed".
#
# `x` is the OUTWARD axis (pre-spin). The origin is the site PyreliskPath
# hands back, which stands ROCK_LIFT + 3 - i.e. one stud - above the walking
# plate's top face; the base ring at x -1.6 therefore reaches 0.6 studs INTO
# the plate, so the rock is seated in the route rather than hovering over it.
PY_ARM_ROCK_SIDES = 9
PY_ARM_ROCK_RINGS = [
    (-1.6, 4.0),  # the foot, down inside the walking plate
    (-0.2, 5.35),  # THE COLLAR at its widest; the build MEASURES ~11 across off this
    (1.2, 4.8),  # the collar's rim
    (1.9, 3.5),  # the pinch the boil rises out of
    (2.6, 3.2),
    (3.4, 2.9),
    (4.4, 2.2),
    (5.3, 1.2),  # the apex - a DOME, not a spike: see the note above
]
PY_ARM_ROCK_JITTER = 0.12  # of each ring's radius; keeps the widest under 5.5
PY_ARM_ROCK_TWIST = 0.21  # radians per ring, so the facets do not stack into columns


def _py_lump(bm, rings, rng, jitter, twist, sides, axis):
    """One closed lumpy body: jittered rings bridged end to end.

    `axis` is 0 for a module (the run is along +X, the pre-spin outward axis)
    and 2 for a body-space piece (the run is along +Z, the body's own up).
    `loft`'s winding is documented for an advance along +X and holds for +Z by
    the same argument - the rings run counter-clockwise about the advance, so
    every face comes out pointing away from the axis. Reverse either and the
    rock is single-sided INWARD, which renders as nothing at all in Roblox.
    """
    out = []
    for index, (along, radius) in enumerate(rings):
        ring = []
        for i in range(sides):
            angle = (i / sides) * TAU + index * twist
            r = radius * (1.0 + rng.uniform(-jitter, jitter))
            slip = rng.uniform(-0.30, 0.30)
            u, v = math.cos(angle) * r, math.sin(angle) * r
            ring.append((along + slip, u, v) if axis == 0 else (u, v, along + slip))
        out.append(ring)
    loft(bm, out)
    return out


def build_py_arm_rock(rng):
    bm = bmesh.new()
    _py_lump(bm, PY_ARM_ROCK_RINGS, rng, PY_ARM_ROCK_JITTER, PY_ARM_ROCK_TWIST,
             PY_ARM_ROCK_SIDES, axis=0)
    obj = finish("Pyrelisk_ArmRock", bm, PY_MOLTEN)
    # Ry(-90) maps the authored +X onto +Z, exactly as Seam and Vent do. Same
    # sign, same reason, and the client's AUTHORED_BOX row carries the same -1.
    obj.rotation_euler = (0.0, math.radians(-90), 0.0)
    return obj


# ----------------------------------------------------------- THE NECK CORE
#
# THE MEASURED CONSTRAINT, and it MOVED THE SITE. This is the one place slice 4
# corrects the frozen design, and it is corrected by measurement.
#
# The design (SS4.3, and Addendum P after it) puts the core at `PY_RIG["neck"]`
# lifted 6 studs along the body's up: authored (8, 0, 158). Nobody had measured
# the volume a rock there would live in. Measured off the built head, jaw and
# torso:
#
#   * the NEAREST rock to (8, 0, 158) is 1.80 studs away. The point is not near
#     the skull, it is INSIDE it - the "pocket" it sits in is the throat, and
#     the throat is enclosed. The skull's lower boulders reach 17-26 studs out
#     from the neck axis at EVERY bearing through z 156..162.
#   * from a player standing at the top of the neck plate - the only place act
#     3 is fought from - only 25-33% of a radius-11..13 shell about that point
#     is in line of sight.
#
# Addendum P's "7.2 studs above the head's underside" is the same fact stated
# from below, and the conclusion it drew (author the rock oblate) is necessary
# but not sufficient: an oblate rock centred inside the skull is still inside
# the skull. A 22-stud one would additionally break the skull's silhouette,
# which is the failure the addendum names.
#
# THE SITE MOVES OUTBOARD ALONG THE FLANK, to the measured edge of the collar's
# open volume: authored (4, 18, 160), mirrored by the planted side, which is
# `PyreliskPath.FALLEN_CORE_AT` verbatim. At that point 64% of the rock's own
# surface is in line of sight, it stands 6.3 studs from the neck plate's collar
# end - the
# party arrives BESIDE it - and the rock straddles the collar band with its
# inboard half in the rock and its outboard half in the air. That is what SS4.3
# asked for and what the lift could not deliver.
#
# `_py_expose_neck_core` re-measures that 64% on every build and raises if it
# falls below PY_NECK_CORE_EXPOSE. A number in a comment is a claim; this one
# is the whole reason the site moved, so it is a gate.
#
# THE SHAPE IS STILL OBLATE, and for the reason the addendum gives: the skull's
# underside is close above and the rock must not rise into it. Wide, low, and
# domed toward the outboard side the party sees.
PY_NECK_CORE_SIDES = 11
PY_NECK_CORE_AT = (4.0, 16.0, 162.0)  # authored; PyreliskPath.FALLEN_CORE_AT, same numbers
PY_NECK_CORE_RINGS = [
    (-4.2, 7.8),  # the foot, down in the collar band's own rock
    (-2.0, 12.2),  # THE RIM, and it is what bites the collar
    (-0.6, 11.4),
    (0.8, 9.6),
    (2.6, 6.8),
    (4.2, 4.0),
    (5.4, 1.6),  # the apex - low, because the skull's underside is right above
]
PY_NECK_CORE_JITTER = 0.10
PY_NECK_CORE_TWIST = 0.17
PY_NECK_CORE_EXPOSE = 0.45  # of the rock's own shell, in line of sight from the ramp's top


def build_py_neck_core(rng):
    bm = bmesh.new()
    _py_lump(bm, PY_NECK_CORE_RINGS, rng, PY_NECK_CORE_JITTER, PY_NECK_CORE_TWIST,
             PY_NECK_CORE_SIDES, axis=2)
    # NO `rotation_euler`. This is not a module: it is drawn once, at the core
    # point, carrying the BODY's rotation, so its authored +Z is the body's up
    # and there is nothing to spin. The client's AUTHORED_BOX row has no
    # `spin` field for exactly this reason.
    return finish("Pyrelisk_NeckCore", bm, PY_MOLTEN)


def _py_bvh(obj, offset=(0.0, 0.0, 0.0)):
    """A BVH of one built object, in boss space."""
    from mathutils.bvhtree import BVHTree

    shift = Vector(offset)
    points = [shift + vert.co for vert in obj.data.vertices]
    tris = []
    for poly in obj.data.polygons:
        loop = list(poly.vertices)
        for k in range(1, len(loop) - 1):
            tris.append((loop[0], loop[k], loop[k + 1]))
    return BVHTree.FromPolygons(points, tris, all_triangles=True)


def _py_expose_neck_core(core_obj, head, jaw, torso, samples=240):
    """HOW MUCH OF THE NECK CORE THE PARTY CAN ACTUALLY SEE, measured.

    The question every other check in this file asks is "is it attached" or "is
    it clear". Neither of those is the question a TARGET raises. The core can be
    perfectly attached, perfectly clear of the skull, and still be behind it -
    which is precisely what the design's own site was.

    So: stand where act 3 is fought from - the top of the neck plate, eye six
    studs up - and cast a ray at each of `samples` points spread over the rock's
    own surface. The fraction that arrives is the number. `build_gn_core`'s
    handoff makes the same measurement for Gnashroot's chest core and states it
    the same way; this is that, as a gate rather than a report.

    Returns (exposed fraction, nearest rock to the core point, distance from the
    neck plate's collar end, the effective radius).
    """
    core_at = Vector(PY_NECK_CORE_AT)
    trees = [_py_bvh(head, PY_RIG["neck"]), _py_bvh(jaw, PY_RIG["neck"]), _py_bvh(torso)]
    near = min(t.find_nearest(core_at, 60.0)[3] for t in trees
               if t.find_nearest(core_at, 60.0)[0] is not None)
    eye = Vector(PY_WALK_NECK[1]) + Vector((0.0, 0.0, 6.0))
    verts = [core_at + v.co for v in core_obj.data.vertices]
    step = max(1, len(verts) // samples)
    seen = total = 0
    for point in verts[::step]:
        total += 1
        segment = point - eye
        reach = segment.length - 0.8
        if reach <= 0:
            seen += 1
            continue
        direction = segment.normalized()
        if all(t.ray_cast(eye, direction, reach)[0] is None for t in trees):
            seen += 1
    exposed = seen / max(total, 1)
    if exposed < PY_NECK_CORE_EXPOSE:
        raise SystemExit(
            "PYRELISK NECKCORE FAILED: only %.0f%% of the rock is in line of sight from the top of the "
            "neck plate (floor %.0f%%). It is the fight's LAST target and a party that cannot see it "
            "reads the colossus as unkillable. Re-measure the collar's open volume and move "
            "PY_NECK_CORE_AT - and move PyreliskPath.FALLEN_CORE_AT with it, or the rock you shoot and "
            "the rock you see part company." % (exposed * 100.0, PY_NECK_CORE_EXPOSE * 100.0)
        )
    effective = max(v.co.length for v in core_obj.data.vertices)
    return exposed, near, (core_at - Vector(PY_WALK_NECK[1])).length, effective


# THE CLIMB ROUTE, in one place, because PyreliskPath mirrors these exact
# numbers and the server cuts collidable slabs from them.
#
# Both walkable surfaces are MEASURED against the built rock at build time
# (`_py_seat_decks`, `_py_seat_walk_arm`) and not derived from the joint
# numbers - which is how the first pass put both of them INSIDE their own
# rock: the ramp 4-8 studs under a forearm it was authored 13 studs above,
# and the deck up to 29 studs under the shoulder boulders. A mounted player
# would have walked chest-deep through stone.
PY_WALK_ARM_LIFT = 16.0  # PROVISIONAL: overwritten with the measured value
PY_WALK_ARM_SIZE = (48.0, 18.0, 4.0)
# (centre, size) in boss space; the z of each centre is overwritten by
# `_py_seat_decks`. The shape is set by where the HEAD is: the skull hangs
# back over the spine, so a single bar across the shoulders puts a mounted
# player under the jaw. The route is a back plateau AFT of the skull and a
# pad on each shoulder, one vent standing on each.
PY_WALK_DECKS = [
    # AFT OF THE NECK, and the x is measured not chosen: the neck's own
    # cladding stands to z 153 and the seating pass takes the MAX rock under a
    # footprint, so a shelf that reaches x -20 is hoisted above the skull's
    # own underside. At x -46..-22 the rock under it tops out at 140.
    [(-34.0, 0.0, 136.0), (24.0, 80.0, 4.0)],  # the spine shelf, aft of the skull
    [(-4.0, 58.0, 137.0), (44.0, 34.0, 4.0)],  # left shoulder pad
    [(-4.0, -58.0, 137.0), (44.0, 34.0, 4.0)],  # right shoulder pad
]


# THE THIRD WALKING PLATE, and the one act 3 is about: the ramp from the
# working shoulder pad up onto the neck band, where the neck core stands.
#
# It is a TILTED plate, unlike the decks and the arm's slab, and it has to be:
# the pad's walking face is authored z 142 and the neck band's rock tops out
# around z 145, so a flat box spanning the two either buries itself in the
# trapezius at one end or hangs over the pad at the other. `PY_WALK_NECK` is
# therefore stated as the plate's TOP FACE - the two authored points its
# walking surface passes through - which is exactly how PyreliskPath states it
# (`FALLEN_PAD` / `FALLEN_COLLAR`, and the two files must agree point for
# point or the rock you see and the rock you stand on part company).
#
# THE PAD END IS NOT FREE. It is the aft-inboard corner of the shoulder pad's
# own top face (the pad spans authored x -26..18, y 41..75, face z 142), and
# it is that corner rather than the middle because the corner is what gives
# the shoulder bridge above it the diagonal run it needs to come off the arm
# at 14.8 degrees instead of 24. Move it and the bridge steepens.
#
# THE COLLAR END'S z IS MEASURED, not chosen - `_py_seat_walk_neck` overwrites
# it with the rock top under the plate's own footprint plus the clearance the
# decks get. 149.0 is the provisional value the rig was solved against; the
# HANDOFF prints what the rock actually said.
# WHAT PyreliskPath CARRIES, so the two files can be checked against each
# other instead of hoped about. `tools/check_content.py` reads one number out
# of two files in two languages and fails on a mismatch; this is that idiom,
# in the builder, for the numbers the builder MEASURES and the path module has
# to state. A drift here is not cosmetic: the mesh is the plate the player
# sees and the path module is the plate they stand on, and they separate
# silently.
#
# UPDATE BOTH SIDES OR NEITHER. If the build fails here, the builder measured
# something new - copy its number into PyreliskPath and say why in the commit.
# RE-MEASURED 2026-09-12 for the plating, and the direction is the OPPOSITE of
# what the remodel's brief expected: flush plates are lower-profile than
# boulders, so the rock under a walking plate was predicted to DROP. It rose,
# in two places, and both are the taper:
#
#   DECK 1 (the spine shelf) 145.6 -> 149.9. The neck band's plates lie on a
#     profile that loses ten studs of half width in six of height, so their
#     own surface normals tilt up nearly forty degrees and a flat plate laid on
#     that reaches higher at its inboard edge than any boulder did - measured
#     rock top under the shelf's footprint 147.3, up from 140.
#   VENT 1 goes with it (it stands on that deck's face): 147.6 -> 151.9.
#   DECK 2 / VENT 2 140.2 -> 140.9 / 142.2 -> 142.9 and DECK 3 / VENT 3
#     138.7 -> 139.7 / 140.7 -> 141.7: the pads sit on the yoke, whose plating
#     is flatter than the neck's, so they barely moved. VENT 2's own FOOT is
#     what grew instead - 8.8 studs, because the rock directly under the
#     chimney (a +/-11 footprint, not the pad's wide one) is at 134.1.
#   WALKNECK's collar 159.8 -> 159.9.
#   WALK_ARM_LIFT 19.5 -> 18.3, because the forearm's plates are the flattest
#     on the body (half thickness 2.3, a crown 2.8 proud) and its measured
#     crown came down from 17.1 to 15.9. `PyreliskPath.BONE_LIFT.Forearm`
#     follows it exactly and `.UpperArm` is RE-SOLVED on the documented ratio
#     (0.66197, the elbow-flush one): (18.3 + 2) / 0.66197 - 2 = 28.7.
PY_PATH_DECKS = ((-34.0, 0.0, 149.9), (-4.0, 58.0, 140.9), (-4.0, -58.0, 139.7))
PY_PATH_COLLAR = (2.0, 12.0, 159.9)
PY_PATH_VENTS = ((-34.0, 0.0, 151.9), (-4.0, 58.0, 142.9), (-4.0, -58.0, 141.7))
PY_PATH_TOLERANCE = 0.05
PY_PATH_CHECK = True


def _py_assert_path_agrees():
    """Hold PyreliskPath's stated geometry to what this build measured."""
    rows = [("DECK %d" % (i + 1), PY_WALK_DECKS[i][0], PY_PATH_DECKS[i]) for i in range(3)]
    rows.append(("WALKNECK collar", PY_WALK_NECK[1], PY_PATH_COLLAR))
    for index, ((x, y, z), _normal) in enumerate(py_vent_sites()):
        rows.append(("VENT %d" % (index + 1), (x, y, z), PY_PATH_VENTS[index]))
    for label, built, stated in rows:
        for axis in range(3):
            if abs(built[axis] - stated[axis]) > PY_PATH_TOLERANCE:
                raise SystemExit(
                    "PYRELISK PATH DISAGREES: %s is (%.2f, %.2f, %.2f) in this build but "
                    "(%.2f, %.2f, %.2f) in PyreliskPath.luau. The drawn plate and the collidable "
                    "slab are the same surface stated twice - update BOTH, and put the builder's "
                    "number in the path module rather than the other way round."
                    % ((label,) + tuple(built) + tuple(stated))
                )
    print("HANDOFF pyrelisk: PyreliskPath agrees with this build on all %d seated points "
          "(decks, the WalkNeck collar, the three vents) to within %.2f studs"
          % (len(rows), PY_PATH_TOLERANCE))


PY_WALK_NECK = [(-24.0, 46.0, 142.0), (2.0, 12.0, 149.0)]
PY_WALK_NECK_SIZE = (18.0, 4.0)  # width, thickness; the length is the span + a plate width
PY_WALK_NECK_OVER = 9.0  # the overrun PyreliskPath's `ramp` adds, so the mesh matches the slab


def _py_walk_neck_frame():
    """The plate's own basis in AUTHORED space: +X along the span, +Z its up.

    The same construction `plateOn`/`boneUp` make in PyreliskPath, in blender
    axes: a bone's up is the perpendicular that stays as near authored up as
    it can get. Built by hand rather than with `rotation_difference` for the
    reason `_py_aim_up` gives - a shortest-arc rotation takes whatever roll
    falls out of it, and this is a flat plate whose roll is the thing a player
    stands on.
    """
    a, b = Vector(PY_WALK_NECK[0]), Vector(PY_WALK_NECK[1])
    x = (b - a).normalized()
    up = Vector((0.0, 0.0, 1.0))
    if abs(x.dot(up)) > 0.999:
        up = Vector((1.0, 0.0, 0.0))
    y = up.cross(x).normalized()
    z = x.cross(y)
    return a, b, x, y, z


def _py_seat_walk_neck(torso):
    """Lift the collar end until the plate's UNDERSIDE clears the neck band.

    Measured over the plate's own footprint in the xy plane, the `_py_seat_decks`
    pattern: the neck's cladding stands proud of the lofted profile and a plate
    solved against the profile is a walking surface inside the rock. Returns
    (measured rock top, the seated z) for the HANDOFF.
    """
    a, b, x, y, z = _py_walk_neck_frame()
    half = PY_WALK_NECK_SIZE[0] * 0.5
    # the footprint's xy bounds, taken over the inboard THIRD of the span (the
    # pad end is already seated by the deck it stands on; what is unknown is
    # the rock at the collar)
    xs, ys = [], []
    for t in (0.66, 1.0):
        mid = a + (b - a) * t
        for side in (-1.0, 1.0):
            corner = mid + y * (side * half)
            xs.append(corner.x)
            ys.append(corner.y)
    top = _py_rock_top(torso, min(xs), max(xs), min(ys), max(ys), default=PY_WALK_NECK[1][2])
    seated = top + 0.6 + PY_WALK_NECK_SIZE[1]
    PY_WALK_NECK[1] = (PY_WALK_NECK[1][0], PY_WALK_NECK[1][1], round(seated, 1))
    return top, PY_WALK_NECK[1][2]


def build_py_walk_neck():
    a, b, x, y, z = _py_walk_neck_frame()
    bm = bmesh.new()
    # The plate's TOP passes through both stated points, so the box's centre
    # sits half a thickness BELOW the midpoint along the plate's own up - the
    # `-thick/2` lift PyreliskPath's `ramp` applies, on this side of the wire.
    span = (b - a).length
    length = span + PY_WALK_NECK_OVER
    # ...and the overrun is all at the COLLAR end, matching the slab: laid
    # symmetrically its aft half protrudes back over the shoulder bridge.
    centre = a + x * (span * 0.5 + PY_WALK_NECK_OVER * 0.5) - z * (PY_WALK_NECK_SIZE[1] * 0.5)
    box(bm, tuple(centre), (length, PY_WALK_NECK_SIZE[0], PY_WALK_NECK_SIZE[1]),
        Matrix((x, y, z)).transposed())
    return finish("Pyrelisk_WalkNeck", bm, PY_SLAG)


def py_deck_top(index):
    """The walking face of deck `index` - what a vent's base stands on."""
    center, size = PY_WALK_DECKS[index]
    return center[2] + size[2] * 0.5


def py_vent_sites():
    """Vent shafts, placed against the DECK rather than against a plate: a
    vent whose base is not on the footing you fight it from is unreachable by
    construction. Read as a function because the decks are seated at build
    time against the measured rock."""
    return [
        ((PY_WALK_DECKS[0][0][0], 0.0, py_deck_top(0)), (-0.15, 0.0, 0.99)),
        ((PY_WALK_DECKS[1][0][0], PY_WALK_DECKS[1][0][1], py_deck_top(1)), (-0.12, 0.30, 0.95)),
        ((PY_WALK_DECKS[2][0][0], PY_WALK_DECKS[2][0][1], py_deck_top(2)), (-0.12, -0.30, 0.95)),
    ]


def _py_rock_top(obj, x0, x1, y0, y1, default=None):
    """The highest vertex of `obj` inside an xy footprint - the MEASUREMENT
    that seats a walkable slab on the rock instead of in it."""
    best = None
    for vert in obj.data.vertices:
        if x0 <= vert.co.x <= x1 and y0 <= vert.co.y <= y1:
            if best is None or vert.co.z > best:
                best = vert.co.z
    return default if best is None else best


def _py_seat_decks(torso, shoulder):
    """Lift each deck until its underside clears the rock beneath it.

    The shoulder pads sit over the YOKE, whose top is torso geometry, so the
    torso is what is sampled; the pauldron is a rig-placed piece that arrives
    outboard of the pads. Returns the measured clearances for the HANDOFF.
    """
    measured = []
    for index, (center, size) in enumerate(PY_WALK_DECKS):
        x0, x1 = center[0] - size[0] * 0.5, center[0] + size[0] * 0.5
        y0, y1 = center[1] - size[1] * 0.5, center[1] + size[1] * 0.5
        top = _py_rock_top(torso, x0, x1, y0, y1, default=center[2])
        seated = top + 0.6 + size[2] * 0.5
        PY_WALK_DECKS[index][0] = (center[0], center[1], round(seated, 1))
        measured.append((top, PY_WALK_DECKS[index][0][2]))
    return measured


def _py_seat_walk_arm(forearm):
    """Lift the ramp slab until it lies ON the forearm's crown, measured over
    the slab's own footprint rather than over the whole bone (the crown climbs
    at both ends, which is why the slab is shorter than the bone)."""
    global PY_WALK_ARM_LIFT
    x0 = PY_RIG["forearm"] * 0.5 - PY_WALK_ARM_SIZE[0] * 0.5
    x1 = PY_RIG["forearm"] * 0.5 + PY_WALK_ARM_SIZE[0] * 0.5
    crown = _py_rock_top(forearm, x0, x1, -PY_WALK_ARM_SIZE[1] * 0.5, PY_WALK_ARM_SIZE[1] * 0.5,
                         default=PY_WALK_ARM_LIFT)
    PY_WALK_ARM_LIFT = round(crown + 0.4 + PY_WALK_ARM_SIZE[2] * 0.5, 1)
    return crown


def build_py_walk_arm():
    bm = bmesh.new()
    # THE RAMP: a plain slab matching the forearm's upper surface, because the
    # climb has to be geometry a humanoid never trips on and a box is exact
    # where a convex hull of the plated arm would not be.
    box(bm, (PY_RIG["forearm"] * 0.5, 0.0, PY_WALK_ARM_LIFT), PY_WALK_ARM_SIZE)
    return finish("Pyrelisk_WalkArm", bm, PY_SLAG)


def build_py_walk_deck():
    bm = bmesh.new()
    for center, size in PY_WALK_DECKS:
        box(bm, center, size)
    return finish("Pyrelisk_WalkDeck", bm, PY_SLAG)


# ------------------------------------------------------------- the handoff
#
# Repo law: a number derived from a constant is a CLAIM; a number measured off
# the built objects is EVIDENCE. The rig retune reads these, so every figure
# below is read back out of the meshes that were just built.


def _py_span(obj, axis, lo=None, hi=None, on=2):
    values = [v.co[axis] for v in obj.data.vertices
              if (lo is None or v.co[on] >= lo) and (hi is None or v.co[on] <= hi)]
    return (min(values), max(values)) if values else (0.0, 0.0)


def _py_measure(objects):
    by_name = {obj.name.split("_", 1)[1]: obj for obj in objects}
    out = {}
    neck = Vector(PY_RIG["neck"])
    crown = max(v.co.z for name in ("Head", "Crown") for v in by_name[name].data.vertices)
    out["crown_z"] = neck.z + crown
    out["head_lo_z"] = neck.z + min(v.co.z for v in by_name["Head"].data.vertices)
    out["head_w"] = max(abs(v.co.y) for v in by_name["Head"].data.vertices) * 2.0
    out["head_h"] = crown - min(v.co.z for v in by_name["Head"].data.vertices)
    out["snout_x"] = max(v.co.x for v in by_name["Head"].data.vertices)
    torso = by_name["Torso"]
    # The waterline footprint: every vertex within +/-3 of the lake surface.
    out["waterline_r"] = max(
        (math.hypot(v.co.x, v.co.y) for v in torso.data.vertices if -3.0 <= v.co.z <= 3.0), default=0.0)
    out["waist_r"] = max(
        (abs(v.co.y) for v in torso.data.vertices if 16.0 <= v.co.z <= 30.0), default=0.0)
    out["chest_r"] = max(
        (abs(v.co.y) for v in torso.data.vertices if 112.0 <= v.co.z <= 130.0), default=0.0)
    out["torso_top_z"] = max(v.co.z for v in torso.data.vertices)
    # The SHOULDER's top, not the neck's: what the head has to stand clear of.
    out["shoulder_top_z"] = max(
        (v.co.z for v in torso.data.vertices if abs(v.co.y) > 34.0), default=0.0)
    # Shoulder span: the pauldron is authored about the joint with +X outboard,
    # so its outboard reach adds to the joint's y.
    pauldron = max(v.co.x for v in by_name["Shoulder"].data.vertices)
    out["shoulder_span"] = (PY_RIG["shoulder"][1] + pauldron) * 2.0
    out["pauldron_out"] = pauldron
    for key, name in (("upper_arm", "UpperArm"), ("forearm", "Forearm"), ("hand", "Hand")):
        lo, hi = _py_span(by_name[name], 0, on=0)
        out[key + "_mesh"] = (lo, hi)
    hand = by_name["Hand"]
    out["hand_size"] = tuple(
        max(v.co[i] for v in hand.data.vertices) - min(v.co[i] for v in hand.data.vertices) for i in range(3))
    # THE HANG: the arm at rest, walked joint to joint exactly as the rig does,
    # so "how far below the lake do the knuckles sit" is measured and not guessed.
    shoulder = Vector((PY_RIG["shoulder"][0], PY_RIG["shoulder"][1], PY_RIG["shoulder"][2]))
    elbow = shoulder + Vector(PY_HANG[0]).normalized() * PY_RIG["upper_arm"]
    wrist = elbow + Vector(PY_HANG[1]).normalized() * PY_RIG["forearm"]
    fist = wrist + Vector(PY_HANG[2]).normalized() * PY_RIG["hand"]
    out["hang"] = (elbow, wrist, fist)
    out["fist_z"] = fist.z
    out["fist_r"] = math.hypot(fist.x, fist.y)
    reach = PY_RIG["upper_arm"] + PY_RIG["forearm"] + PY_RIG["hand"]
    out["reach"] = reach
    sy, sz = PY_RIG["shoulder"][1], PY_RIG["shoulder"][2]
    out["plant_r"] = sy + math.sqrt(max(reach ** 2 - sz ** 2, 0.0))
    out["faces"] = sum(len(obj.data.polygons) for obj in objects)
    return out


def build_pyrelisk():
    # The knit guard's positive control, first and every time: see
    # `_py_knit_selftest`. It costs a few milliseconds and it is the only thing
    # standing between "no floaters" and "a check that silently stopped
    # checking".
    _py_knit_selftest()
    rng = random.Random(4409)
    core = build_py_core(rng)
    torso = build_py_torso(rng)
    head = build_py_head(rng)
    jaw = build_py_jaw(rng)
    crown = build_py_crown(rng, head)
    eyes = build_py_eyes(head)
    shoulder = build_py_shoulder(rng)
    upper_arm = build_py_upper_arm(rng)
    forearm = build_py_forearm(rng)
    hand = build_py_hand(rng)
    seam = build_py_seam()
    # ------------------------------------------------------- THE SURFACE WELD
    #
    # BEFORE THE SEATS, and the order is the whole point: the welds move rock,
    # and `_py_seat_decks` / `_py_seat_walk_arm` / `_py_seat_walk_neck` measure
    # the rock to decide where a walking plate goes. Seated first, a plate
    # would be seated against geometry that then moved under it - the defect
    # the seating pass exists to prevent, arrived at from the other direction.
    #
    # The head's mesh is handed to the crown and the eyes because those two are
    # authored in HEAD space and grow out of it: a crown shard is judged
    # against the skull it is planted in, and no per-object check can see that
    # pair. On 2026-09-12 one shard was 0.45 studs off the head with every gate
    # green.
    #
    # AND EVERY PLATED REGION IS WELDED AGAINST ITS OWN LAVA (2026-09-12), which
    # is the remodel's whole connectivity story in one line. A plate does not
    # touch its neighbours - the cracks are the point - so "is it attached"
    # cannot be asked of the plates, only of the molten body they are seated
    # on. That is the same root the external instrument uses, so for the first
    # time on this boss the build-time question and the shipped question are
    # the same question. `_py_assert_lava_knit` is what holds the lava itself
    # together; the weld is not pointed at the core, for the reason that
    # function's docstring gives.
    _py_assert_lava_knit(core)
    core_mesh = ([tuple(v.co) for v in core.data.vertices],
                 [tuple(p.vertices) for p in core.data.polygons])
    _py_weld("Torso", torso, against=[core_mesh])
    _py_weld("Head", head, against=[_py_under_patch(PY_SKULL[0], PY_SKULL[1])])
    # THE SNAPSHOT IS TAKEN AFTER THE HEAD'S OWN WELD, and it has to be: the
    # head weld moves head rock, and a crown shard welded against a stale copy
    # of the skull is welded to where the skull WAS. That cost a run - the
    # shard and one eye came back adrift from an independent check while this
    # pass reported both attached.
    head_mesh = ([tuple(v.co) for v in head.data.vertices],
                 [tuple(p.vertices) for p in head.data.polygons])
    _py_weld("Crown", crown, against=[head_mesh])
    _py_weld("Eyes", eyes, against=[head_mesh])
    _py_weld("Shoulder", shoulder, against=[_py_under_patch(PY_PAULDRON[0], PY_PAULDRON[1])])
    _py_weld("UpperArm", upper_arm)
    _py_weld("Forearm", forearm)
    _py_weld("Hand", hand)
    _py_weld("Jaw", jaw)
    _py_weld("Seam", seam)
    # THE THREE walkable slabs are seated against the rock that was just
    # built, then and only then cut as boxes.
    decks = _py_seat_decks(torso, shoulder)
    crown_of_arm = _py_seat_walk_arm(forearm)
    neck_rock, neck_seat = _py_seat_walk_neck(torso)
    # ...and the vent's foot is measured against the same rock, then and only
    # then is the vent cut. It has to come after the decks: the depth its shaft
    # needs is the gap between the deck's walking face and the rock under it,
    # and that face is not known until the deck has been seated.
    vent_seats = _py_seat_vents(torso)
    vent = build_py_vent(rng)
    _py_weld("Vent", vent)
    walk_arm = build_py_walk_arm()
    walk_deck = build_py_walk_deck()
    walk_neck = build_py_walk_neck()
    # ACT 3's TARGETS, last, because the neck core is SEATED against the built
    # head and jaw the same way the decks are seated against the built torso:
    # the pocket it has to fit inside is a measurement, not a constant.
    arm_rock = build_py_arm_rock(rng)
    neck_core = build_py_neck_core(rng)
    _py_weld("ArmRock", arm_rock)
    _py_weld("NeckCore", neck_core)
    core_seat = _py_expose_neck_core(neck_core, head, jaw, torso)
    # SEVENTEEN OBJECTS, AND SEVENTEEN IS THE END STATE. The pack was 14, then
    # 15 with `_WalkNeck`, and slice 4's `_ArmRock` / `_NeckCore` complete the
    # design's FINAL set (section 8.3). Nothing else is owed: acts 1-4 are all
    # drawn out of these seventeen plus the arena's own objects, and the import
    # checklist's row 7o says 17 from here on.
    objects = [core, torso, head, jaw, crown, eyes, shoulder, upper_arm, forearm, hand,
               seam, vent, walk_arm, walk_deck, walk_neck, arm_rock, neck_core]

    # EVERY object's island count, held to PY_MESH_COMPONENTS. This is the
    # guard that covers the classes `_py_knit` cannot speak for at all, and it
    # is counted off the finished mesh rather than off the generator's ledger.
    for obj in objects:
        _py_assert_components(obj)
    _py_assert_seam_face(torso)
    _py_assert_path_agrees() if PY_PATH_CHECK else None

    m = _py_measure(objects)
    print("HANDOFF pyrelisk: torso base z=0 IS the caldera lake surface - boss z and arena z are the same number")
    print("HANDOFF pyrelisk: MEASURED crown top z %.1f; head z %.1f..%.1f (%.0f tall, %.0f wide), "
          "MEASURED shoulder rock tops out at z %.1f - the head's underside clears it by %.1f"
          % (m["crown_z"], m["head_lo_z"], m["crown_z"], m["head_h"], m["head_w"],
             m["shoulder_top_z"], m["head_lo_z"] - m["shoulder_top_z"]))
    print("HANDOFF pyrelisk: MEASURED shoulder span %.1f, waist half width %.1f, chest half width %.1f, "
          "waterline footprint r %.1f (hitRadius 96, lake r 120 - both clear)"
          % (m["shoulder_span"], m["waist_r"], m["chest_r"], m["waterline_r"]))
    print("HANDOFF pyrelisk: shoulder joint (%.1f, +/-%.1f, %.1f) - ROBLOX rel (%.1f, %.1f, -/+%.1f); "
          "pauldron reaches %.1f outboard of it"
          % (PY_RIG["shoulder"][0], PY_RIG["shoulder"][1], PY_RIG["shoulder"][2],
             PY_RIG["shoulder"][0], PY_RIG["shoulder"][2], PY_RIG["shoulder"][1], m["pauldron_out"]))
    print("HANDOFF pyrelisk: MEASURED bone meshes - upper arm x %.1f..%.1f (bone %.0f), forearm x %.1f..%.1f "
          "(bone %.0f), hand x %.1f..%.1f (bone %.0f); reach %.0f from the shoulder"
          % (m["upper_arm_mesh"][0], m["upper_arm_mesh"][1], PY_RIG["upper_arm"],
             m["forearm_mesh"][0], m["forearm_mesh"][1], PY_RIG["forearm"],
             m["hand_mesh"][0], m["hand_mesh"][1], PY_RIG["hand"], m["reach"]))
    print("HANDOFF pyrelisk: MEASURED hand bbox %.1f x %.1f x %.1f - ROBLOX size (%.1f, %.1f, %.1f)"
          % (m["hand_size"] + (m["hand_size"][0], m["hand_size"][2], m["hand_size"][1])))
    elbow, wrist, fist = m["hang"]
    print("HANDOFF pyrelisk: MEASURED rest hang (side +1) elbow (%.1f, %.1f, %.1f) wrist (%.1f, %.1f, %.1f) "
          "fist (%.1f, %.1f, %.1f) - the fist ends %.1f BELOW the lake at r %.1f (lake r 120: knuckles in the lava)"
          % (elbow.x, elbow.y, elbow.z, wrist.x, wrist.y, wrist.z, fist.x, fist.y, fist.z,
             -m["fist_z"], m["fist_r"]))
    print("HANDOFF pyrelisk: fully extended the fist plants at r %.1f - the rim path is r 120..232, so the "
          "planted arm lands in its near third" % m["plant_r"])
    print("HANDOFF pyrelisk: neck joint (%.1f, %.1f, %.1f) - ROBLOX rel (%.1f, %.1f, %.1f); head faces +X, "
          "snout tip x=+%.1f (head-local)"
          % (PY_RIG["neck"][0], PY_RIG["neck"][1], PY_RIG["neck"][2],
             PY_RIG["neck"][0], PY_RIG["neck"][2], -PY_RIG["neck"][1], m["snout_x"]))
    print("HANDOFF pyrelisk: jaw hinge (head-local) (%.1f, %.1f, %.1f) - ROBLOX rel (%.1f, %.1f, %.1f)"
          % (PY_JAW_HINGE + (PY_JAW_HINGE[0], PY_JAW_HINGE[2], -PY_JAW_HINGE[1])))
    print("HANDOFF pyrelisk: Seam and Vent are MODULES - authored at the origin, +Z is the outward surface normal, placed many times by the rig")
    print("HANDOFF pyrelisk: _Walk* are the ONLY collidable parts (the climb route); every shell piece is "
          "non-collide. THREE of them now: _WalkArm (the forearm ramp), _WalkDeck (the three back decks) "
          "and _WalkNeck (the shoulder pad to the neck collar, act 3's last stretch). Box fidelity on all "
          "three - they are plain slabs and a hull of a slab is the slab.")
    for index, (position, normal) in enumerate(PY_SEAM_SITES, 1):
        print("HANDOFF pyrelisk: SEAM %d at (%.1f, %.1f, %.1f) out (%.3f, %.3f, %.3f) - ROBLOX rel (%.1f, %.1f, %.1f)"
              % ((index,) + position + normal + (position[0], position[2], -position[1])))
    for index, (position, normal) in enumerate(py_vent_sites(), 1):
        print("HANDOFF pyrelisk: VENT %d at (%.1f, %.1f, %.1f) out (%.3f, %.3f, %.3f) - ROBLOX rel (%.1f, %.1f, %.1f)"
              % ((index,) + tuple(position) + tuple(normal) + (position[0], position[2], -position[1])))
    for index, ((center, size), (rock, seated)) in enumerate(zip(PY_WALK_DECKS, decks), 1):
        print("HANDOFF pyrelisk: DECK %d at (%.1f, %.1f, %.1f) ROBLOX size (%.1f, %.1f, %.1f) - MEASURED rock "
              "top z %.1f under its footprint, walking face z %.1f (%.1f of clearance)"
              % (index, center[0], center[1], center[2], size[0], size[2], size[1],
                 rock, py_deck_top(index - 1), center[2] - size[2] * 0.5 - rock))
    for index, (rock, face, depth) in enumerate(vent_seats, 1):
        print("HANDOFF pyrelisk: VENT SEAT %d - MEASURED rock top z %.2f under its own footprint, deck "
              "walking face z %.2f, so the shaft needs %.2f studs of foot to reach rock. Cut at "
              "PY_VENT_DROP %.1f (the worst of the three, plus %.1f of bite), so every vent stands ON the "
              "boss and not on the plate over it - the site itself did NOT move, so PyreliskPath.VENTS and "
              "the client's draw are untouched"
              % (index, rock, face, depth, PY_VENT_DROP, PY_VENT_BITE))
    print("HANDOFF pyrelisk: WALK_ARM_LIFT %.1f (slab centre above the forearm axis) - MEASURED forearm crown "
          "z %.1f over the slab's footprint; ROBLOX size (%.1f, %.1f, %.1f)"
          % (PY_WALK_ARM_LIFT, crown_of_arm, PY_WALK_ARM_SIZE[0], PY_WALK_ARM_SIZE[2], PY_WALK_ARM_SIZE[1]))
    print("HANDOFF pyrelisk: the Forearm is FLATTENED (it is the ramp's footing), so its ROLL matters - "
          "aim it with an UP-REFERENCED basis (see _py_aim_up), not a shortest-arc rotation, and lift the "
          "ramp slab along THAT basis's up, not world up: on a steeply planted arm world up runs along the bone")
    print("HANDOFF pyrelisk: %d faces total, torso %d over %d PLATES (the whole body is %d) - "
          "flush armour over a molten underbody, not a boulder aggregate: the torso carried 474 "
          "chunks before the 09-12 remodel"
          % (m["faces"], len(torso.data.polygons), len(_py_islands(torso)),
             sum(len(_py_islands(obj)) for obj in objects)))
    rock_lo, rock_hi = _py_bbox(arm_rock)
    core_lo, core_hi = _py_bbox(neck_core)
    print("HANDOFF pyrelisk: ARMROCK is the pack's THIRD MODULE - authored ALONG +X, spun Ry(-90) onto +Z "
          "(the Seam/Vent convention and the same SIGN), bbox lo (%.1f, %.1f, %.1f) hi (%.1f, %.1f, %.1f) "
          "PRE-spin, so %.1f across x %.1f out. The boil's apex stands %.1f studs PROUD of the collar's own "
          "rim (x %.1f), which is build_kg_heart_glow's lesson on a target: a glow level with its collar is "
          "a rock with a patch on it. Neon/MOLTEN on the client; base ring reaches %.1f INTO the walking "
          "plate, so it is seated in the route rather than hovering over it."
          % (rock_lo.x, rock_lo.y, rock_lo.z, rock_hi.x, rock_hi.y, rock_hi.z,
             max(rock_hi.y - rock_lo.y, rock_hi.z - rock_lo.z), rock_hi.x - rock_lo.x,
             rock_hi.x - PY_ARM_ROCK_RINGS[2][0], PY_ARM_ROCK_RINGS[2][0], -rock_lo.x))
    exposed, near, plate_d, effective = core_seat
    print("HANDOFF pyrelisk: NECKCORE is ONE object, NOT a module - no spin, authored +Z is the body's up, "
          "drawn once at PyreliskPath.neckCorePoint with the body's own rotation. bbox lo (%.1f, %.1f, %.1f) "
          "hi (%.1f, %.1f, %.1f): %.1f x %.1f across and only %.1f tall - OBLATE, because the skull's "
          "underside is right above it."
          % (core_lo.x, core_lo.y, core_lo.z, core_hi.x, core_hi.y, core_hi.z,
             core_hi.x - core_lo.x, core_hi.y - core_lo.y, core_hi.z - core_lo.z))
    print("HANDOFF pyrelisk: NECKCORE SITE MOVED, and this is slice 4's one correction to the frozen design. "
          "SS4.3 / Addendum P put it at NECK lifted 6 along the body's up - authored (8.0, 0.0, 158.0) - and "
          "MEASURED off the built head that point is 1.80 studs from the nearest rock: it is INSIDE the "
          "skull, whose lower boulders reach 17-26 studs out from the neck axis at every bearing through "
          "z 156..162. From the top of the neck plate only 25-33%% of a shell about it is in line of sight. "
          "The site is now authored (%.1f, %.1f, %.1f), mirrored by the planted flank - "
          "PyreliskPath.FALLEN_CORE_AT, the same three numbers."
          % PY_NECK_CORE_AT)
    print("HANDOFF pyrelisk: NECKCORE EXPOSURE %.0f%% of its own surface is in LINE OF SIGHT from a player "
          "standing at the neck plate's collar end, eye 6 up - MEASURED by ray, gate floor %.0f%%. The "
          "nearest head/jaw/torso rock to the site is %.2f studs (so the rock STRADDLES the collar: inboard "
          "half in the rock, outboard half in the air) and the site stands %.1f studs from the plate's collar "
          "end, so the party arrives beside it rather than under it."
          % (exposed * 100.0, PY_NECK_CORE_EXPOSE * 100.0, near, plate_d))
    print("HANDOFF pyrelisk: NECKCORE EFFECTIVE RADIUS %.2f (the furthest vertex from its own origin; the "
          "horizontal half-extent is %.2f and the vertical run is %.2f..%.2f). "
          "`pyrelisk_neckcore.shotRadius` is PROVISIONALLY 11.0 per Addendum P - the measured replacement is "
          "%.1f, which is the mass across the line of sight the route offers. It over-claims above and below "
          "the rock, which every shotRadius in the project does."
          % (effective, max(core_hi.x - core_lo.x, core_hi.y - core_lo.y) * 0.5,
             core_lo.z, core_hi.z, round(effective, 0)))
    print("HANDOFF pyrelisk: %d objects in the pack, and SEVENTEEN IS THE FINAL SET (design section 8.3): "
          "was 14, then 15 with _WalkNeck, and slice 4's _ArmRock + _NeckCore close it. Both new names need "
          "MeshColors rows and both want NEON alongside _Core/_Seam/_Eyes." % len(objects))
    # THE FALLEN POSE, measured off everything above. Printed last because it
    # reads the bone crowns back out of the built meshes.
    _py_fallen_handoff(objects, neck_rock, neck_seat)
    return objects


def _py_bbox(obj):
    """The authored bounding box, as the two corner vectors - what the client's
    AUTHORED_BOX rows are pasted from."""
    lo = Vector((9e9, 9e9, 9e9))
    hi = Vector((-9e9, -9e9, -9e9))
    for vert in obj.data.vertices:
        lo = Vector((min(lo.x, vert.co.x), min(lo.y, vert.co.y), min(lo.z, vert.co.z)))
        hi = Vector((max(hi.x, vert.co.x), max(hi.y, vert.co.y), max(hi.z, vert.co.z)))
    return lo, hi


# ---------------------------------------------------------------- the pose
#
# Assembling the pieces the way the client's rig will: one CFrame per part,
# limbs walked joint to joint. This IS the spec for that rig - if the preview
# assembles, the numbers are right.

# THE REST HANG, as three unit-ish directions (shoulder->elbow, elbow->wrist,
# wrist->fist) for the +y arm; the -y arm is the same with y negated. Kept
# here rather than inline because `_py_measure` walks it to print where the
# knuckles actually end up.
PY_HANG = ((0.16, 0.30, -0.94), (0.22, 0.12, -0.97), (0.30, 0.05, -0.95))
# THE PLANTED ARM: nearly straight, because a shoulder at z 130 with 150 studs
# of arm only just reaches the ground at r 159 - see PY_RIG's note.
PY_PLANT = ((0.16, 0.48, -0.86), (0.20, 0.47, -0.86), (0.42, 0.42, -0.80))

# Where seams open. Boss space, each (position, outward normal). The fight
# opens a subset per attack and closes them on recovery; the rig reads this
# table, so the art and the hitboxes can never drift apart.
PY_SEAM_SITES = [py_seam_site(z, bearing) for z, bearing in PY_SEAM_SPEC]
# How far the client swells an OPEN fissure at the top of its pulse
# (PyreliskBodyController's OPEN_SWELL), so the open-state render shows the
# gape the fight shows rather than a brighter closed seam.
OPEN_SWELL = 1.10


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


def _py_aim_up(origin, direction):
    """`_py_aim`, but with the piece's local +Z ROLLED as near world up as it gets.

    `rotation_difference` gives the shortest rotation onto the bone and takes
    whatever roll falls out of it, which is fine for a boulder chain that is
    the same from every side. It is NOT fine for the forearm and its ramp: the
    forearm is flattened so it has a top to walk on, and the walk slab is a
    flat plate that has to lie ON that top. Both need a basis referenced to
    up, and the client rig has to build the same one - see the HANDOFF.
    """
    x = Vector(direction).normalized()
    up = Vector((0.0, 0.0, 1.0))
    if abs(x.dot(up)) > 0.999:
        up = Vector((1.0, 0.0, 0.0))
    y = up.cross(x).normalized()
    z = x.cross(y)
    rot = Matrix((x, y, z)).transposed().to_4x4()
    return Matrix.Translation(Vector(origin)) @ rot


def _py_surface(position, normal):
    """A module's transform: +Z along the outward surface normal."""
    rot = Vector((0, 0, 1)).rotation_difference(Vector(normal).normalized()).to_matrix().to_4x4()
    return Matrix.Translation(Vector(position)) @ rot


def _py_module(position, normal):
    """A Seam or a Vent seated on the shell, in the PRE-SPIN mesh's own axes -
    and with the SAME ROLL the running game gives it.

    Two separate corrections, and both of them were wrong here for as long as
    this staging existed. They stayed invisible because the old seam was a
    squat hexagonal wedge that looks the same from every angle.

      * `_py_copy` assigns `matrix_world`, which THROWS AWAY the object's own
        `rotation_euler` - the Ry(-90) that puts the module's authored +X onto
        +Z. So a module staged through `_py_surface` (which aims +Z at the
        normal) had its OUTWARD AXIS lying flat along the surface. On the vent
        that is a 36-stud chimney laid sideways across the boss's back; on a
        30-stud fissure it is a crack that misses its own plate entirely.
      * even with the spin restored, `rotation_difference` takes the shortest
        arc and whatever roll falls out of it, while the game seats a module
        with `onSurface` - lookAt along the normal against the BODY's up. For
        a normal that is near horizontal (which every shell seam's is) the two
        differ by ninety degrees, so a fissure authored to run up the shell
        would be staged running around it.

    So the basis is built by hand: +X out, +Y down the shell, +Z along it,
    which is what the mesh is authored against and what the client draws.
    """
    n = Vector(normal).normalized()
    up = Vector((0.0, 0.0, 1.0))
    if abs(n.dot(up)) > 0.999:
        up = Vector((1.0, 0.0, 0.0))
    across = up.cross(n).normalized()
    along = n.cross(across)
    rot = Matrix((n, -along, across)).transposed().to_4x4()
    return Matrix.Translation(Vector(position)) @ rot


# THE BODY COMMITMENT, staged. Pasted from PyreliskPath's `commit`: the rig
# places the whole colossus with CFrame.Angles(tilt, 0, -pitch) after its yaw,
# a pitch about the lateral axis (nose down into the blow) and a roll onto the
# working arm. Roblox's +X/+Y/+Z are Blender's +x/+z/-y, so the roblox Rz(-p)
# is a Blender rotation about +y by +p and the roblox Rx(t) is a Blender
# rotation about +x by t - and roblox applies Rx last, so Blender applies it
# last too.
def _py_commit(pitch_deg, tilt_deg, side):
    tilt = math.radians(-tilt_deg * side)
    return Matrix.Rotation(tilt, 4, "X") @ Matrix.Rotation(math.radians(pitch_deg), 4, "Y")


# THE ARMS' LAVA, and it is the one part of "the body is all lava" that is not
# in `Pyrelisk_Core`.
#
# Nothing static can sit under a swinging bone and the pack is closed at
# seventeen objects, so the arms were plated on a ROCK underbody for two builds
# and the render said what that costs: a trunk veined with fire between two
# dark limbs, which reads as two materials rather than one creature.
#
# The answer needs no new object. A bone is drawn a SECOND time from its own
# mesh, scaled in a little about its own bounding-box centre and lit as lava:
# every plate of the twin sits a stud or two below the outer shell's seat, so
# what shows through the shell's cracks is molten rock and what shows anywhere
# else is nothing. A scale strictly under 1 about a point INSIDE a shell can
# only move surface inward, so the twin cannot poke out through the silhouette
# - and the client does exactly this, from the same numbers
# (PyreliskBodyController's TWIN and drawArm).
#
# The bones scale RADIALLY ONLY (1, 0.90, 0.90): a bone is authored along +X
# from its joint and a uniform scale would shorten it, leaving the cap ring at
# the far end with nothing behind it. The fist is a blob rather than a bone, so
# it takes a uniform one.
# (scale, ROLL) per bone, and the roll is the half of this that took three
# tries. A twin scaled radially alone has its plates under the outer shell's
# PLATES and its cracks under the outer shell's CRACKS - so every groove you
# look down shows the twin's own groove, and the arm renders exactly as dark
# as it did without a twin at all (measured: 0.1% of the arm frame lit).
# Rolled half a cell about its own bone (pi/cols), the twin's plates land
# under the outer's cracks, and what shows down every groove is a molten plate
# crown two studs below the surface.
PY_TWIN = {
    "UpperArm": ((1.0, 0.925, 0.925), math.pi / 7.0),
    "Forearm": ((1.0, 0.925, 0.925), math.pi / 7.0),
    # the fist is a golden-angle lattice rather than rings, so any roll
    # decorrelates it; a quarter turn is as good as any.
    "Hand": ((0.925, 0.925, 0.925), math.pi * 0.5),
}
# ...AND THE GROOVE HAS TO BE WIDER THAN IT IS DEEP for any of that to show.
# The bones' first plated pass used the trunk's own crack (0.15 of a cell,
# which on a limb's 17-stud pitch is 2.6 studs) over plates 3.6 studs proud,
# and a slot deeper than it is wide is lit only within 35 degrees of its own
# normal - so the arms came back black from the rim path whatever was behind
# them. The bones therefore run FLATTER plates (half thickness 2.3-2.4 against
# the trunk's 3.0-3.6) and a WIDER crack (0.20), which is an aspect of about
# 0.8 and legible across the whole arm.


def _py_twin(source, frame, scale, roll=0.0):
    """`source` again, lit as lava and drawn a little inside itself.

    STAGING ONLY, and that is a contract rather than a convenience: the twin
    is a part the CLIENT draws, it is not in the exported glb, and
    `tools/check_posed_connectivity.py` poses the pack through this file's own
    placer. A twin left in the placer's output would be twenty islands of
    geometry the instrument has to judge and the .glb does not contain - so
    `_place_pyrelisk` only makes them when a RENDER asks (`glow=True`), which
    is exactly when they are a picture of what the client will draw.
    """
    lo, hi = _py_bbox(source)
    centre = (lo + hi) * 0.5
    copy = source.copy()
    copy.data = source.data.copy()
    copy.data.materials.clear()
    material = make_material(source.name + "Molten", PY_MOLTEN)
    bsdf = material.node_tree.nodes.get("Principled BSDF") if material.node_tree else None
    if bsdf:
        for key in ("Emission Color", "Emission"):
            if key in bsdf.inputs:
                bsdf.inputs[key].default_value = (1.0, 0.09, 0.01, 1.0)
                break
        if "Emission Strength" in bsdf.inputs:
            bsdf.inputs["Emission Strength"].default_value = 0.40
    copy.data.materials.append(material)
    copy.hide_render = False
    bpy.context.collection.objects.link(copy)
    copy.matrix_world = (frame @ Matrix.Translation(centre) @ Matrix.Rotation(roll, 4, "X")
                         @ Matrix.Diagonal(Vector(scale)).to_4x4() @ Matrix.Translation(-centre))
    return copy


def _py_arm(parts, made, side, elbow_dir, wrist_dir, hand_dir, walk=False, glow=False):
    """One arm, walked joint to joint - exactly what the client rig does."""
    sx, sy, sz = PY_RIG["shoulder"]
    shoulder = Vector((sx, side * sy, sz))
    made.append(_py_copy(parts["Shoulder"], _py_aim(shoulder, (0.0, side * 1.0, 0.0))))
    elbow_dir = Vector((elbow_dir[0], side * elbow_dir[1], elbow_dir[2]))
    upper = _py_aim(shoulder, elbow_dir)
    made.append(_py_copy(parts["UpperArm"], upper))
    if glow:
        made.append(_py_twin(parts["UpperArm"], upper, *PY_TWIN["UpperArm"]))
    elbow = shoulder + elbow_dir.normalized() * PY_RIG["upper_arm"]
    wrist_dir = Vector((wrist_dir[0], side * wrist_dir[1], wrist_dir[2]))
    fore = _py_aim_up(elbow, wrist_dir)
    made.append(_py_copy(parts["Forearm"], fore))
    if glow:
        made.append(_py_twin(parts["Forearm"], fore, *PY_TWIN["Forearm"]))
    if walk:
        made.append(_py_copy(parts["WalkArm"], fore))
    wrist = elbow + wrist_dir.normalized() * PY_RIG["forearm"]
    hand_dir = Vector((hand_dir[0], side * hand_dir[1], hand_dir[2]))
    fist = _py_aim(wrist, hand_dir)
    made.append(_py_copy(parts["Hand"], fist))
    if glow:
        made.append(_py_twin(parts["Hand"], fist, *PY_TWIN["Hand"]))
    return wrist + hand_dir.normalized() * PY_RIG["hand"]


def _place_pyrelisk(objects, planted_side=None, head_yaw=0.0, arm_side=None, arm_pose=None, commit=None,
                    both_pose=None, sink=0.0, walk_neck=False, rocks=False, glow=False):
    """Stand the colossus up. `planted_side` drops that arm onto the rim path
    (the stagger pose - the arm is the ramp); the other arm stays raised.

    `arm_side` + `arm_pose` swing ONE arm through an arbitrary keyframe -
    three authored direction triples in exactly PyreliskPath's own order
    (upper, fore, hand) - which is what the slam-sequence renders are for.
    `commit` is that keyframe's (pitch, tilt) in degrees, applied to the WHOLE
    body afterwards, because a lean the arm has and the torso does not is the
    stiff swing this pass exists to kill.

    `both_pose` swings BOTH arms through one keyframe, mirrored per flank,
    which is the `fallen` pose: acts 2 and 3 pose the pair, and drawing one
    arm prostrate with the other in its rest hang is a figure that fell over
    while holding a pose.

    `sink` DROPS THE WHOLE BODY, and it is the one transform the staging had
    no way to express before the fallen pose needed it. Pitch and tilt rotate
    about the body's own origin, which is the lake surface, so no combination
    of them lowers a shoulder - it swings it outboard instead. Applied AFTER
    the commit, exactly as PyreliskPath does it (`lift` is the translation and
    the commitment is the rotation inside it), or the drop would be tilted.
    """
    parts = {obj.name.split("_", 1)[1]: obj for obj in objects}
    made = []
    for name in ("Core", "Torso", "WalkDeck"):
        made.append(_py_copy(parts[name], Matrix.Identity(4)))
    if walk_neck:
        made.append(_py_copy(parts["WalkNeck"], Matrix.Identity(4)))
    neck = Vector(PY_RIG["neck"])
    head = Matrix.Translation(neck) @ Matrix.Rotation(head_yaw, 4, "Z") @ Matrix.Rotation(math.radians(-6), 4, "Y")
    for name in ("Head", "Jaw", "Crown", "Eyes"):
        made.append(_py_copy(parts[name], head))
    for side in (-1, 1):
        if both_pose is not None:
            # THE FALLEN PAIR. `walk` on the planted flank only: the ramp slab
            # is real footing and the client draws it for exactly the flank
            # `Planted` names, so a staged frame showing two planks promises
            # footing on an arm nothing will let you climb.
            _py_arm(parts, made, side, both_pose[0], both_pose[1], both_pose[2],
                    walk=(planted_side == side), glow=glow)
        elif planted_side == side:
            _py_arm(parts, made, side, PY_PLANT[0], PY_PLANT[1], PY_PLANT[2], walk=True, glow=glow)
        elif arm_pose is not None and arm_side == side:
            _py_arm(parts, made, side, arm_pose[0], arm_pose[1], arm_pose[2], glow=glow)
        else:
            _py_arm(parts, made, side, PY_HANG[0], PY_HANG[1], PY_HANG[2], glow=glow)
    # The maw: the same Seam module, seated in the throat behind the jaw, so
    # an open mouth glows without the core ever poking through the skull.
    made.append(_py_copy(parts["Seam"], head @ _py_module((14.0, 0.0, 12.0), (1.0, 0.0, -0.3))))
    for position, normal in PY_SEAM_SITES:
        made.append(_py_copy(parts["Seam"], _py_module(position, normal)))
    for position, normal in py_vent_sites():
        made.append(_py_copy(parts["Vent"], _py_module(position, normal)))
        # The vent's throat glow, and it is seated at 5 rather than 13. The
        # fissure rework made the Seam module THIRTY studs long; the chimney's
        # bore is widest at its base (r 10) and narrows to 6.5, so a crack
        # dropped two thirds of the way up it had both ends out in the open
        # air past the collars. At 5 it lies in the widest part of the shaft.
        made.append(_py_copy(parts["Seam"], _py_module(
            (position[0] + normal[0] * 5.0, position[1] + normal[1] * 5.0, position[2] + normal[2] * 5.0), normal)))
    if commit is not None:
        body = _py_commit(commit[0], commit[1], arm_side if arm_side is not None else (planted_side or 1))
        for obj in made:
            obj.matrix_world = body @ obj.matrix_world
    if sink:
        drop = Matrix.Translation(Vector((0.0, 0.0, -sink)))
        for obj in made:
            obj.matrix_world = drop @ obj.matrix_world
    # ACT 3's SEVEN TARGETS, and they go on AFTER the commit and the sink -
    # which is the one thing this block can get wrong and the one thing that
    # would ship looking almost right. `_py_fallen_joints` already walks the
    # body matrix and the drop, so `_py_fallen_rocks` / `_py_fallen_core` hand
    # back WORLD points; run through the loops above they would be pitched and
    # sunk a second time, putting the whole set a hundred studs under the lake
    # at the wrong angle. The client has the same hazard and answers it the
    # same way: the positions come from PyreliskPath, which has already applied
    # the body frame.
    if rocks:
        side = planted_side if planted_side is not None else 1
        for at, up in _py_fallen_rocks(side):
            made.append(_py_copy(parts["ArmRock"], _py_module(at, up)))
        # The core is not a module: it takes the BODY's rotation, which is the
        # commitment alone (the sink is a translation and carries no spin).
        spin = _py_commit(commit[0], commit[1], side) if commit is not None else Matrix.Identity(4)
        made.append(_py_copy(parts["NeckCore"],
                             Matrix.Translation(_py_fallen_core(side)) @ spin.to_3x3().to_4x4()))
    print("POSE: %d parts placed (%d seams, %d vents%s)"
          % (len(made), len(PY_SEAM_SITES) + 3, 3, ", 6 arm rocks + the neck core" if rocks else ""))
    return made


def _py_light(sun_energy=2.4, fill_energy=0.6):
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.rotation_euler = (math.radians(48), 0, math.radians(38))
    sun.data.energy = sun_energy
    bpy.context.collection.objects.link(sun)
    fill = bpy.data.objects.new("Fill", bpy.data.lights.new("Fill", "SUN"))
    fill.rotation_euler = (math.radians(66), 0, math.radians(-132))
    fill.data.energy = fill_energy
    bpy.context.collection.objects.link(fill)


def _py_shoot(path_out, location, target, lens, res=(1500, 1000), bg=(0.415, 0.360, 0.330)):
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x, scene.render.resolution_y = res
    scene.world = bpy.data.worlds.new("World")
    scene.world.use_nodes = True
    node = scene.world.node_tree.nodes.get("Background")
    if node:
        node.inputs[0].default_value = (*bg, 1.0)
    cam_data = bpy.data.cameras.new("Cam")
    cam_data.lens = lens
    # clip_end: the default 1000 is SHORTER than this arena is wide and every
    # frame comes back empty. Every camera in this section carries its own.
    cam_data.clip_end = 20000.0
    cam = bpy.data.objects.new("Cam", cam_data)
    cam.location = Vector(location)
    cam.rotation_euler = (Vector(target) - cam.location).to_track_quat("-Z", "Y").to_euler()
    bpy.context.collection.objects.link(cam)
    scene.camera = cam
    scene.render.filepath = path_out
    bpy.ops.render.render(write_still=True)
    print("BOSS RENDER:", path_out)


def _py_glow(objects, seams_open=False):
    """Lava, for the render only. Deep red base and a LOW emission strength:
    AgX washes a bright emissive to peach, and peach lava on black rock reads
    as a lamp rather than as a body that is hot inside.

    AND THE STRENGTH CAME DOWN WITH THE PLATING (0.55 -> 0.40 on the core),
    which is the washout trap arriving from a new direction. The core used to
    be a lamp glimpsed through occasional gaps; it is now the body's whole
    surface, showing in a crack round every plate, so the same emission puts
    three or four times as much lit area in the frame. Left at 0.55 the
    network bloomed into a peach web and the rock between it went grey - the
    exact "lamp with gravel on it" read the core's own inset exists to
    prevent. At 0.40 the cracks are orange, the plates stay black, and the
    silhouette is rock.

    `seams_open` is the OPEN state, for the seam frame's second pass: the
    seven shell fissures run white-hot and everything else is unchanged, which
    is the contrast the fight is read off (PyreliskBodyController's OPEN_GLOW
    against the crack network's own heat).
    """
    _emissive(objects, {"Core"}, (1.0, 0.09, 0.01), 0.40)
    # A CLOSED seam is just another crack now, and it is lit like one: the
    # ambient network is everywhere, so a fissure that outshone it would be
    # spending the OPEN state's only channel on the closed one.
    if seams_open:
        _emissive(objects, {"Seam"}, (1.0, 0.55, 0.30), 3.4)
    else:
        _emissive(objects, {"Seam"}, (1.0, 0.12, 0.02), 0.55)
    # The eyes came back as two strips of pale tape at 0.9 - AgX again, and
    # on a 5x6 box there is no area for the hue to survive in. Deeper and
    # dimmer, so they read as lit slits in a shadowed face.
    _emissive(objects, {"Eyes"}, (1.0, 0.20, 0.02), 0.45)
    # ACT 3's TARGETS, and they are deliberately the HOTTEST thing in the
    # frame. Everything else lit on this body is anatomy the player reads
    # past; these seven are the only things being asked for. Pushed toward
    # ORANGE rather than the core's deep red for the same reason the open seam
    # is pushed toward white: a target has to be a different colour from the
    # body it is standing on, not a brighter patch of it.
    # 1.2, DOWN FROM 1.7 WITH THE PLATING, and it is the washout trap again:
    # against a body that was black the old strength read as hot orange, and
    # against a body veined with lava it clips to PALE PEACH - the six rocks
    # came back the palest thing in the frame rather than the hottest, which
    # for the objects the whole of act 3 is "shoot the orange things" is
    # exactly backwards. At 1.2 they are three stops over the crack network
    # and still on the orange side of the curve.
    _emissive(objects, {"ArmRock", "NeckCore"}, (1.0, 0.11, 0.008), 1.2)


def render_py_previews(prefix, objects):
    """The three review frames, and each one answers a question:

      _preview        the SILHOUETTE, from the player's third-person camera on
                      the rim path - eye 8 studs up, 64 studs back from the
                      lake edge. If shoulders-over-waist and a proud head do
                      not read HERE they do not read.
      _preview_torso  torso and head at 3/4, close: the taper, the neck, and
                      whether the cladding is boulders or masonry.
      _preview_arm    one arm side-on: shoulder, elbow, forearm, fist.
    """
    import os

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import arena_gen  # noqa: E402  (guarded: importing it builds nothing)

    # (a) THE PLAYER'S EYE, and BOTH ARMS HANGING - the rest pose is what the
    # party walks in on and the silhouette is what this frame is for. The
    # first cut of it planted an arm, and a 150-stud limb coming down 60 studs
    # from the lens is all you could see. The rim path is flat at z 0 from
    # r 120 to r 232; this stands on it at r 217 with the eye 9 up, and the
    # lens is 21mm - a little TIGHTER than the fight camera's 70-degree
    # vertical, so nothing here is being flattered by a wider frame.
    clear_scene()
    objects = BOSSES["pyrelisk"]()
    _py_glow(objects)
    arena_gen.build_pyrelisk()
    for obj in objects:
        obj.hide_render = True
    _place_pyrelisk(objects, head_yaw=math.radians(-16), glow=True)
    _py_light()
    _py_shoot(prefix + "_preview.png", (176.0, -128.0, 9.0), (0.0, 0.0, 94.0), 21)

    # (b) THE TORSO, at 3/4 and close enough to judge the stone: the taper,
    # the neck, the head, and whether the cladding reads as boulders.
    clear_scene()
    objects = BOSSES["pyrelisk"]()
    _py_glow(objects)
    for obj in objects:
        obj.hide_render = True
    _place_pyrelisk(objects, head_yaw=math.radians(-16), glow=True)
    _py_light(sun_energy=2.6, fill_energy=0.75)
    _py_shoot(prefix + "_preview_torso.png", (215.0, -215.0, 172.0), (0.0, 0.0, 116.0), 40,
              bg=(0.44, 0.47, 0.50))

    # (c) ONE ARM ALONE, hanging, side-on, WITH ITS RAMP SLAB. Only the four
    # bones are placed: against the torso the arm is a dark limb on a dark
    # body and the articulation - which is the thing being reviewed - cannot
    # be seen at all. Both arms are this same mesh mirrored, so one is the
    # review.
    clear_scene()
    objects = BOSSES["pyrelisk"]()
    _py_glow(objects)
    parts = {obj.name.split("_", 1)[1]: obj for obj in objects}
    for obj in objects:
        obj.hide_render = True
    _py_arm(parts, [], 1, PY_PLANT[0], PY_PLANT[1], PY_PLANT[2], walk=True, glow=True)
    _py_light(sun_energy=2.7, fill_energy=0.85)
    _py_shoot(prefix + "_preview_arm.png", (232.0, 9.0, 68.0), (16.0, 118.0, 56.0), 28,
              bg=(0.44, 0.47, 0.50))


# THE SLAM, THREE FRAMES, and the numbers are PASTED FROM THE RIG - each row
# is one keyframe of PyreliskPath's `TRACK.handfall`, in its own order (upper,
# fore, hand) plus that keyframe's pitch and tilt. Nothing here is staged
# independently and nothing here may be "improved" on its own: if these
# renders and the game disagree, one of the two files has been edited without
# the other and the render is the thing that lies.
#
#   slam1  phase 0.500  the COCK      elbow 94 deg, fist over the shoulder
#   slam2  phase 0.880  MID-EXTENSION elbow 96 deg, whipping over and out
#   slam3  phase 0.975  IMPACT + LEAN elbow 36 deg, torso pitched 16 into it
PY_SLAM_KEYS = [
    ("slam1", (0.1500, 0.5500, 0.8200), (-0.9000, -0.3200, 0.3000), (-0.5500, -0.2500, 0.8000), -7.0, -3.0),
    ("slam2", (0.1607, 0.9149, 0.3704), (0.1545, 0.2475, -0.9565), (0.2134, 0.6106, -0.7626), 6.5, 2.3),
    ("slam3", (0.3886, 0.8333, -0.3932), (0.3516, 0.4071, -0.8430), (0.3911, 0.6750, -0.6256), 16.0, 6.0),
]


# THE FALLEN POSE, and the numbers are PASTED FROM THE RIG - the last keyframe
# of PyreliskPath's `TRACK.fallen` in its own order (upper, fore, hand) plus
# that keyframe's pitch, tilt and SINK. Same law as PY_SLAM_KEYS above:
# nothing here is staged independently and nothing here may be "improved" on
# its own. If this and the game disagree, one of the two files was edited
# without the other.
#
# `sink` is the field the attack keyframes do not have. See `_place_pyrelisk`.
PY_FALLEN_KEYS = (
    (0.9911, -0.0275, 0.1304),   # upper arm, authored, +y flank
    (0.9958, -0.0262, -0.0872),  # forearm
    (0.9844, -0.0276, 0.1736),   # hand
    14.0,                        # pitch
    0.0,                         # tilt - ZERO, so the act 2 -> 3 boundary moves nothing
    105.2,                       # sink
)
# Which lift each plate of the fallen route rides at, and the hand's is NOT
# the plant route's. PyreliskPath calls it FALLEN_BOARD_LIFT and the reason is
# the boarding step: the plant pose's hand is 31 degrees off horizontal and
# the fallen pose's is 4, so the same lift arrives at a different height.
PY_FALLEN_BOARD_LIFT = 13.0
PY_FALLEN_PLATE_THICK = 4.0


def _py_fallen_joints(side=1):
    """The fallen pose's four joints, walked exactly as PyreliskPath's
    `armJoints` walks them: the authored triples through the flank mirror,
    then through the body's own pitch, then the sink.

    Returns blender-space points, so `z` is the height and `y` is the lateral
    axis - the caller negates for the ROBLOX reading (see THE HANDOFF PRINTS
    BOTH READINGS in PyreliskPath's mirror note).
    """
    upper, fore, hand, pitch, tilt, sink = PY_FALLEN_KEYS
    body = _py_commit(pitch, tilt, side)
    drop = Vector((0.0, 0.0, -sink))
    sx, sy, sz = PY_RIG["shoulder"]
    shoulder = body @ Vector((sx, side * sy, sz)) + drop
    rot = body.to_3x3()

    def aim(triple):
        return (rot @ Vector((triple[0], side * triple[1], triple[2]))).normalized()

    du, df, dh = aim(upper), aim(fore), aim(hand)
    elbow = shoulder + du * PY_RIG["upper_arm"]
    wrist = elbow + df * PY_RIG["forearm"]
    fist = wrist + dh * PY_RIG["hand"]
    return dict(shoulder=shoulder, elbow=elbow, wrist=wrist, fist=fist,
                upper=du, fore=df, hand=dh, body=body, sink=sink, pitch=pitch, side=side)


def _py_bone_up(frm, to):
    """`boneUp`, in blender axes: the perpendicular to the bone that stays as
    near authored up as it can get."""
    d = (to - frm).normalized()
    up = Vector((1.0, 0.0, 0.0)) if abs(d.z) > 0.999 else Vector((0.0, 0.0, 1.0))
    back = -d
    right = up.cross(back).normalized()
    return back.cross(right)


def _py_plate(frm, to, lift):
    """The two end points of a plate's TOP FACE, and its slope in degrees."""
    up = _py_bone_up(frm, to)
    a = frm + up * (lift + PY_FALLEN_PLATE_THICK * 0.5)
    b = to + up * (lift + PY_FALLEN_PLATE_THICK * 0.5)
    run = math.hypot(b.x - a.x, b.y - a.y)
    return a, b, math.degrees(math.atan2(abs(b.z - a.z), run)) if run > 1e-9 else 90.0


def _py_rad(p):
    """radius from the body axis, and height - blender axes, so z is up."""
    return math.hypot(p.x, p.y), p.z


def _py_fallen_route(objects, side=1):
    """THE WHOLE FALLEN CLIMB, measured off the BUILT objects.

    Repo law, and this function is the whole reason slice 2 exists: every
    figure the design derived for this pose came off PY_RIG's constants
    through a pose that did not exist, which makes it a CLAIM. Here the bone
    crowns are read back out of the meshes that were just built and the route
    is solved against those, so what comes out is EVIDENCE.
    """
    by_name = {obj.name.split("_", 1)[1]: obj for obj in objects}
    j = _py_fallen_joints(side)
    # MEASURED: how high each limb's rock actually stands over its own bone.
    # `hi[2]` of the authored bbox, which is the crown the walking plate has
    # to clear - and the three of them differ by twelve studs, which is the
    # single fact the whole route is shaped by.
    crowns = {}
    for key in ("Hand", "Forearm", "UpperArm"):
        crowns[key] = max(v.co.z for v in by_name[key].data.vertices)
    lifts = dict(Hand=PY_FALLEN_BOARD_LIFT, Forearm=PY_WALK_ARM_LIFT,
                 UpperArm=round(crowns["UpperArm"] + 1.0 + PY_FALLEN_PLATE_THICK * 0.5, 1))
    half = PY_FALLEN_PLATE_THICK * 0.5
    up_h = _py_bone_up(j["wrist"], j["fist"])
    up_f = _py_bone_up(j["elbow"], j["wrist"])
    up_u = _py_bone_up(j["shoulder"], j["elbow"])
    hand_face = j["fist"] + up_h * (lifts["Hand"] + half)
    fore_wrist = j["wrist"] + up_f * (lifts["Forearm"] + half)
    fore_elbow = j["elbow"] + up_f * (lifts["Forearm"] + half)
    upper_sh = j["shoulder"] + up_u * (lifts["UpperArm"] + half)
    body, drop = j["body"], Vector((0.0, 0.0, -j["sink"]))

    def local(x, y, z):
        return body @ Vector((x, side * y, z)) + drop

    pad = local(*PY_WALK_NECK[0])
    collar = local(*PY_WALK_NECK[1])

    def slope(a, b):
        run = math.hypot(b.x - a.x, b.y - a.y)
        return math.degrees(math.atan2(abs(b.z - a.z), run)) if run > 1e-9 else 90.0

    plates = [
        ("Hand", hand_face, fore_wrist, 18.0),
        ("Forearm", fore_elbow, fore_wrist, 18.0),
        ("UpperArm", fore_elbow, upper_sh, 18.0),
        ("Shoulder", upper_sh, pad, 54.0),
        ("Neck", pad, collar, 18.0),
    ]
    route = [(name, a, b, wide, slope(a, b)) for name, a, b, wide in plates]
    # the boarding step: the Hand plate's outer tip, half a plate width past
    # the fist along its own surface
    d = (fore_wrist - hand_face).normalized()
    tip = hand_face - d * (18.0 * 0.25)
    return dict(joints=j, crowns=crowns, lifts=lifts, route=route, tip=tip,
                pad=pad, collar=collar, faces=dict(hand=hand_face, wrist=fore_wrist,
                                                   elbow=fore_elbow, shoulder=upper_sh))


def _py_fallen_rocks(side=1):
    """`PyreliskPath.armRocks`, mirrored: six points, and SIX is the contract -
    `PyreliskRocks` is a six-bit mask and bit (i-1) is entry i.

    Returns (point, outward normal) PAIRS, not bare points: the normal is that
    segment's own `boneUp`, and the staging needs it because `Pyrelisk_ArmRock`
    is a MODULE - it is seated with `_py_module`, whose whole job is to put the
    authored outward axis on the surface normal. Handing the staging a point
    alone would have left the six rocks lying on their sides up the arm.
    """
    j = _py_fallen_joints(side)
    lifts = (PY_FALLEN_BOARD_LIFT, PY_WALK_ARM_LIFT, 30.5)
    segments = [(j["fist"], j["wrist"], lifts[0]), (j["wrist"], j["elbow"], lifts[1]),
                (j["elbow"], j["shoulder"], lifts[2])]
    lengths = [(b - a).length for a, b, _ in segments]
    total = sum(lengths)
    out = []
    for index, t in enumerate((0.12, 0.28, 0.44, 0.60, 0.74, 0.88), 1):
        want, walked = t * total, 0.0
        for order, (a, b, lift) in enumerate(segments):
            if want <= walked + lengths[order] or order == 2:
                along = b - a
                at = a + along * max(0.0, min(1.0, (want - walked) / lengths[order]))
                up = _py_bone_up(a, b)
                across = along.normalized().cross(up)
                out.append((at + up * (lift + 3.0) + across * (5.0 if index % 2 == 1 else -5.0), up))
                break
            walked += lengths[order]
    return out


def _py_fallen_core(side=1):
    """`PyreliskPath.neckCorePoint`, walked the same way: the authored collar
    site PY_NECK_CORE_AT, MIRRORED BY FLANK, through the body frame and the
    sink. Not a lift off the neck any more - see THE NECK CORE for the
    measurement that moved it."""
    j = _py_fallen_joints(side)
    body, drop = j["body"], Vector((0.0, 0.0, -j["sink"]))
    x, y, z = PY_NECK_CORE_AT
    return body @ Vector((x, side * y, z)) + drop


def _py_fallen_handoff(objects, neck_rock, neck_seat):
    """The FALLEN block. Every figure measured off what was just built, and
    where a measurement disagrees with the design's claim the measurement is
    what gets printed - the delta is the report's to carry."""
    r = _py_fallen_route(objects)
    j, crowns, lifts = r["joints"], r["crowns"], r["lifts"]
    print("HANDOFF pyrelisk FALLEN: acts 2 and 3. Body pitched %.1f deg, tilt %.1f, SUNK %.1f into its own "
          "lake - a pitch alone cannot lower a shoulder (it swings it outboard), so the drop is a "
          "translation and `PyreliskPath.lift` is where it happens"
          % (PY_FALLEN_KEYS[3], PY_FALLEN_KEYS[4], PY_FALLEN_KEYS[5]))
    for name in ("shoulder", "elbow", "wrist", "fist"):
        rad, height = _py_rad(j[name])
        p = j[name]
        print("HANDOFF pyrelisk FALLEN: %-8s at (%.1f, %.1f, %.1f) - ROBLOX rel (%.1f, %.1f, %.1f); r %.2f y %.2f"
              % (name.upper(), p.x, p.y, p.z, p.x, p.z, -p.y, rad, height))
    print("HANDOFF pyrelisk FALLEN: MEASURED bone crowns over their own axes - hand %.1f, forearm %.1f, "
          "upper arm %.1f. TWELVE studs of disparity between the hand and the upper arm is what shapes "
          "this route: per-bone parallel plates would leave an 8.5-stud wall at the wrist and a 10.6 at "
          "the elbow, and closing those with lifts forces the bones to 46 and 58 degrees"
          % (crowns["Hand"], crowns["Forearm"], crowns["UpperArm"]))
    print("HANDOFF pyrelisk FALLEN: plate lifts - hand %.1f (the BOARDING lift, not BONE_LIFT.Hand's 11.0), "
          "forearm %.1f (MEASURED, = WALK_ARM_LIFT), upper arm %.1f (crown %.1f + 1.0 clearance + half a "
          "thickness)" % (lifts["Hand"], lifts["Forearm"], lifts["UpperArm"], crowns["UpperArm"]))
    worst = 0.0
    for name, a, b, wide, slope in r["route"]:
        ra, ya = _py_rad(a)
        rb, yb = _py_rad(b)
        worst = max(worst, slope)
        print("HANDOFF pyrelisk FALLEN: RAMP %-9s slope %5.2f deg, %.0f wide, faces r %6.2f y %6.2f -> "
              "r %6.2f y %6.2f" % (name, slope, wide, ra, ya, rb, yb))
    tip_r, tip_y = _py_rad(r["tip"])
    print("HANDOFF pyrelisk FALLEN: BOARDING STEP off the rim path %.2f studs at r %.2f - inside the 2.0 "
          "automatic step-up (nothing is jumped), and inside PY_CLEAR_R 200 by %.2f so the fist is under "
          "open sky. MEASURED with tools/floor_check.py against arena_pyrelisk.glb: the lip's overhang "
          "does not reach inboard of r 229 on any of 24 bearings (arena_gen's own handoff says 229 too), "
          "so the design's 'undercuts back to r205' was stale and the fist clears the real ceiling by 32"
          % (tip_y, tip_r, 200.0 - tip_r))
    fist_r, fist_y = _py_rad(j["fist"])
    print("HANDOFF pyrelisk FALLEN: the fist's axis sits %.2f BELOW the rim path, so the hand's own rock "
          "(crown %.1f) tops out at y %.2f - the knuckles stand %.2f proud of the walking surface either "
          "side of the plate, which is what a fist driven into rock looks like"
          % (-fist_y, crowns["Hand"], fist_y + crowns["Hand"], fist_y + crowns["Hand"] - tip_y))
    chain = ((j["elbow"] - j["shoulder"]).length + (j["wrist"] - j["elbow"]).length
             + (j["fist"] - j["wrist"]).length)
    print("HANDOFF pyrelisk FALLEN: chain %.1f spanning %.1f - only %.2f studs of SLACK, so the arm is "
          "very nearly straight. The design asked for 33 of slack taken as a gentle elbow; the run needed "
          "to hold 20 degrees does not permit it (see the report's F-7 table). The bend that survives is "
          "at the WRIST, 15 degrees of it, which is what lays the fist flat on the path"
          % (chain, (j["fist"] - j["shoulder"]).length, chain - (j["fist"] - j["shoulder"]).length))
    print("HANDOFF pyrelisk FALLEN: WORST RAMP %.2f deg (cap 20). The two the brief is about are the ARM "
          "(hand/forearm/upper arm) and the SHOULDER-TO-NECK (bridge/neck plate); every junction between "
          "them is a ZERO step because each plate's top passes through the end of the one before it"
          % worst)
    rocks = _py_fallen_rocks()
    for index, (p, up) in enumerate(rocks, 1):
        rad, height = _py_rad(p)
        print("HANDOFF pyrelisk FALLEN: ARMROCK %d at (%.1f, %.1f, %.1f) out (%.3f, %.3f, %.3f) - ROBLOX rel "
              "(%.1f, %.1f, %.1f); r %.2f y %.2f"
              % (index, p.x, p.y, p.z, up.x, up.y, up.z, p.x, p.z, -p.y, rad, height))
    core = _py_fallen_core()
    rad, height = _py_rad(core)
    print("HANDOFF pyrelisk FALLEN: NECKCORE at (%.1f, %.1f, %.1f) - ROBLOX rel (%.1f, %.1f, %.1f); "
          "r %.2f y %.2f" % (core.x, core.y, core.z, core.x, core.z, -core.y, rad, height))
    a, b = Vector(PY_WALK_NECK[0]), Vector(PY_WALK_NECK[1])
    print("HANDOFF pyrelisk FALLEN: WALKNECK top face (%.1f, %.1f, %.1f) -> (%.1f, %.1f, %.1f), %.1f long "
          "x %.0f x %.0f - MEASURED neck-band rock top z %.2f under its footprint, seated z %.1f "
          "(%.2f of clearance under the plate). The overrun is all at the COLLAR end, matching the slab."
          % (a.x, a.y, a.z, b.x, b.y, b.z, (b - a).length + PY_WALK_NECK_OVER,
             PY_WALK_NECK_SIZE[0], PY_WALK_NECK_SIZE[1], neck_rock, neck_seat,
             neck_seat - PY_WALK_NECK_SIZE[1] - neck_rock))
    # THE SWEEP, and it is three different numbers that have all been called
    # "the sweep" by three lanes. Measured here off the BUILT fallen staging so
    # nobody has to quote an ambiguous one again. Slice 2's report said "72.8
    # degrees of rim sweep"; the server lane measured 46.6 for the joint chain
    # and 29.1 for the rocks. They are answers to different questions and all
    # three can be right - so each is labelled by its ENDPOINTS below.
    def bearing(p):
        return math.degrees(math.atan2(p.y, p.x))

    def sweep(a, b):
        return abs((bearing(b) - bearing(a) + 180.0) % 360.0 - 180.0)

    joints = r["joints"]
    print("HANDOFF pyrelisk FALLEN: SWEEP (a) BONE CHAIN, shoulder JOINT -> fist: %.2f deg of plan bearing "
          "(shoulder bearing %.2f, fist %.2f). This is the joint-to-joint number and it is the server lane's "
          "46.6 - the arm lies along a CHORD, so the two ends do not share a bearing"
          % (sweep(joints["shoulder"], joints["fist"]), bearing(joints["shoulder"]), bearing(joints["fist"])))
    ends = [r["tip"], r["collar"], r["pad"]] + [p for _name, a, b, _w, _s in r["route"] for p in (a, b)]
    walk = [bearing(p) for p in ends]
    print("HANDOFF pyrelisk FALLEN: SWEEP (b) WALKABLE ROUTE, boarding tip -> neck collar: %.2f deg between "
          "the two ENDPOINTS (tip bearing %.2f, collar %.2f), but %.2f deg of total bearing RANGE across "
          "every plate end (%.2f..%.2f). The two differ because the route is not monotonic in bearing: it "
          "runs OUT along the arm to the shoulder plate's end and then turns back INBOARD across the pad and "
          "up the neck, so the endpoints are nearly aligned while the middle swings wide. Quote the RANGE if "
          "the question is 'how much of the rim does the climb cover'"
          % (sweep(r["tip"], r["collar"]), bearing(r["tip"]), bearing(r["collar"]),
             max(walk) - min(walk), min(walk), max(walk)))
    spans = [bearing(p) for p, _up in rocks]
    print("HANDOFF pyrelisk FALLEN: SWEEP (c) THE SIX ROCKS, first -> last: %.2f deg (bearings %s). Narrower "
          "than (a) because ROCK_TS runs 0.12..0.88 rather than end to end, and the weave adds +/-5 studs of "
          "its own" % (max(spans) - min(spans), ", ".join("%.2f" % s for s in spans)))
    print("HANDOFF pyrelisk FALLEN: PyreliskPath must carry FALLEN_PAD (%.1f, %.1f, %.1f) and "
          "FALLEN_COLLAR (%.1f, %.1f, %.1f) verbatim - the mesh and the collidable slab are the same "
          "plate stated twice and they agree point for point or they do not agree at all"
          % (a.x, a.y, a.z, b.x, b.y, b.z))


def render_py_fallen(prefix, objects=None):
    """THE TWO FRAMES the fallen pose is judged from, and each answers one
    question the numbers cannot:

      _pose_fallen        does it read as a KNEELING COLOSSUS rather than a
                          glitch? From the rim path, where the party is.
      _pose_fallen_climb  is the arm FLAT and does it read as walkable? Looking
                          up the route from the fist, which is where the climb
                          starts.
      _pose_fallen_rocks  SLICE 4's frame, and the only one that reviews act 3
                          rather than the pose: are the six arm rocks and the
                          neck core obviously-shootable ORANGE TARGETS
                          punctuating the route, or are they decoration on it?
                          Same eyeline as _climb - the boarding step, before
                          the party has committed to the climb - because the
                          question is what a player sees when they decide.
    """
    import os

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import arena_gen  # noqa: E402  (guarded: importing it builds nothing)

    upper, fore, hand, pitch, tilt, sink = PY_FALLEN_KEYS
    # BOTH CAMERAS STAND ON THE +y SIDE, and that is not a taste decision -
    # `planted_side=1` is the authored +y flank, so the arm that carries the
    # climb is the one at blender +y. The first cut of these two frames put
    # both cameras at -y and photographed the arm nobody climbs; it looked
    # plausible, because the body is symmetric and the other arm is in the
    # same pose. That is the mirror mistake this pack's own notes open with,
    # and a render is exactly where it hides.
    #
    # Where the geometry actually is, so the aim points can be read against
    # the HANDOFF: the +1 fist lands at blender (174.6, 80.0, -11.8) - plan
    # bearing 24.6 degrees - and the neck collar at (40.6, 12.0, 49.6). The
    # figure faces +x with both arms thrown forward 49 degrees apart.
    for suffix, location, target, lens, rocks in (
        # (a) THE SILHOUETTE, from the rim path round at bearing 60 - between
        # the working arm and the flank, which is the one angle that gets the
        # bowed head, the sunk chest AND the arm reaching the path into one
        # frame. Eye 16 up, standing on the path at r 215, so this is a
        # PLAYER'S view and not a museum plinth.
        ("", (215.0, 300.0, 58.0), (55.0, 30.0, 24.0), 36, False),
        # (b) UP THE ARM FROM THE FIST, eye height on the rim path just
        # outboard of the boarding step (r 211, the tip is at 196.8). Looking
        # back along the route at the collar the climb ends on. If the arm does
        # not read as a ramp from HERE it does not read: this is the frame a
        # player sees before they decide to step on.
        ("_climb", (206.0, 82.0, 8.0), (96.0, 82.0, 28.0), 24, False),
        # (c) SLICE 4: the same decision point as (b), pulled back so the WHOLE
        # route is in one frame - rock 1 just past the boarding step at r 179
        # through rock 6 at r 93, and the neck core at the collar beyond them.
        #
        # THE BEARING IS THE WHOLE FRAME, and it took five attempts. The route
        # runs along a chord at plan bearing 24..71 and the core sits at bearing
        # 22 on the far side of it, so a camera out on the route's OWN bearing
        # (b's 40-ish, which is the natural place to stand) has the shoulder and
        # the upper arm between it and the collar: six rocks and no core. From
        # bearing 14, r 264, the sight line to the core passes INBOARD of the
        # arm entirely, and the arm lies across the frame rather than down it -
        # which also separates the six rocks instead of stacking them. Do not
        # "improve" this toward the route's own bearing; that is the shot that
        # loses the core.
        ("_rocks", (256.0, 66.0, 42.0), (96.0, 42.0, 38.0), 28, True),
    ):
        clear_scene()
        made = BOSSES["pyrelisk"]()
        _py_glow(made)
        arena_gen.build_pyrelisk()
        for obj in made:
            obj.hide_render = True
        _place_pyrelisk(made, planted_side=1, head_yaw=math.radians(-8), both_pose=(upper, fore, hand),
                        commit=(pitch, tilt), sink=sink, walk_neck=True, rocks=rocks, glow=True)
        _py_light(sun_energy=2.5, fill_energy=0.8)
        _py_shoot(prefix + "_pose_fallen%s.png" % suffix, location, target, lens)


def render_py_slam(prefix, objects=None):
    """The three frames the jointed elbow is judged from.

    Same camera on all three, deliberately: the thing being reviewed is what
    MOVES between them, and a camera that moves too hides a stiff arm behind a
    livelier composition. It stands out on the rim path on the working arm's
    own side, looking back and up at the boss, which is where a player baiting
    a slam is actually standing.
    """
    import os

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import arena_gen  # noqa: E402  (guarded: importing it builds nothing)

    for name, upper, fore, hand, pitch, tilt in PY_SLAM_KEYS:
        clear_scene()
        made = BOSSES["pyrelisk"]()
        _py_glow(made)
        arena_gen.build_pyrelisk()
        for obj in made:
            obj.hide_render = True
        _place_pyrelisk(made, head_yaw=math.radians(-10), arm_side=1,
                        arm_pose=(upper, fore, hand), commit=(pitch, tilt), glow=True)
        _py_light(sun_energy=2.6, fill_energy=0.8)
        _py_shoot(prefix + "_pose_%s.png" % name, (498.0, 404.0, 196.0), (56.0, 112.0, 78.0), 38)


def render_py_seams(prefix, objects=None):
    """THE KILL ROUTE, close enough to see what it is asking you to shoot.

    Chest and near flank at 3/4, at the distance the fissures have to be
    legible from - three seams in frame (the chest and the pair either side of
    it) plus the low flank pair below them. If a player cannot look at this
    and say "the rock is split and there is fire in it", the geometry has not
    done its job and no amount of client glow will save it.

    TWO FRAMES SINCE THE PLATING, and the second one is not decoration. With
    lava in every crack the question stopped being "can you see a fissure" and
    became "can you tell a fissure from the crack network round it", which is
    a question about two states:

      _preview_seams       CLOSED, and the one the shipped list names. The
                           fissure is lit no brighter than the ambient
                           network, so everything findable about it is
                           GEOMETRY: a nine-stud gape between two half plates
                           against a three-stud crack, thirty studs long,
                           kinked, with hairline offshoots.
      _preview_seams_open  OPEN. Same camera, same body, the fissures white-hot
                           and swelled the 1.10 the client swells them by. This
                           is the frame that proves the contrast is still
                           available after the ambient floor came up.
    """
    for suffix, is_open in (("", False), ("_open", True)):
        clear_scene()
        made = BOSSES["pyrelisk"]()
        _py_glow(made, seams_open=is_open)
        for obj in made:
            obj.hide_render = True
        placed = _place_pyrelisk(made, head_yaw=math.radians(-16), glow=True)
        if is_open:
            # THE GAPE, on the seven SHELL seams only - the maw and the three
            # vent throats are anatomy and are never "open" (the controller
            # gives them no seam index and no bit). Matched by position
            # against PY_SEAM_SITES rather than by draw order, which is a fact
            # about this function rather than about the rig.
            for obj in placed:
                if not obj.name.startswith("Pyrelisk_Seam"):
                    continue
                for position, _normal in PY_SEAM_SITES:
                    if (obj.location - Vector(position)).length < 1.5:
                        obj.scale = (OPEN_SWELL, OPEN_SWELL, OPEN_SWELL)
                        break
        _py_light(sun_energy=2.2, fill_energy=0.55)
        _py_shoot(prefix + "_preview_seams%s.png" % suffix, (322.0, -252.0, 140.0),
                  (16.0, -6.0, 82.0), 34, bg=(0.30, 0.31, 0.34))


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
    _py_glow(objects)
    for obj in objects:
        obj.hide_render = True
    _place_pyrelisk(objects, planted_side=-1, head_yaw=math.radians(-24), glow=True)
    _py_light()

    for suffix, location, target, lens in (
        # The whole thing in its arena, from outside the crater.
        ("", (470.0, -600.0, 190.0), (0.0, 0.0, 84.0), 40),
        # THE PLAYER'S ANGLE: the fight camera on the rim path, looking at what
        # it is standing under. The planted arm comes down on this side.
        ("_fight", (-150.0, -190.0, 12.0), (-16.0, -26.0, 92.0), 24),
        # The head, close: it either reads as a head here or it does not.
        ("_head", (150.0, -96.0, 200.0), (10.0, 0.0, 172.0), 52),
    ):
        out = path_out if not suffix else path_out.replace("_staged.png", "_staged%s.png" % suffix)
        _py_shoot(out, location, target, lens)


# ================================================================ wrack
#
# "Admiral Wrack, the Fleet-Eater" - the wreck island's boss, and the
# colossus idea pushed a third way. Brinejaw is one chain that goes
# everywhere; Gnashroot is a body that goes nowhere with four limbs that do;
# Wrack does not move AT ALL. His fight is a bullet hell: he is a STATIC GUN
# PLATFORM planted on his own beached flagship, filling the Careenage with
# cannon fire while the party dodges and shoots back.
#
# THE 2026-09-08 REDESIGN, and it was three notes from the player, each of
# which killed a load-bearing piece of the old model:
#
#   "make the gunmen part of the ship itself. dont make it gunmen, make it
#    like 4 actual canons that are an actual part of the ship. and then make
#    the ship itself just smaller so that you can actually see the enemy.
#    and then make the ship stand upright."
#
#   1. UPRIGHT. The careen is gone. She sits keel-bedded in the sand, masts
#      up: a beached but intact warship. The whole `_wr_heel` / WR_SHIP
#      two-space machinery is DELETED rather than parked at identity - ship
#      space and boss space are now the same space, which removes the one
#      mistake this section could make that still rendered (a ship-space
#      point dropped in a heeled bmesh, heeled twice).
#   2. SMALLER. 48 studs bow-to-stern against the old 87, 34 to the sabre
#      tip against the old 72 - a little over half the bulk on both axes.
#      See THE CAMERA ARITHMETIC below: the old hull could not be framed
#      from the drop ring without pitching to within 4 degrees of the band's
#      ceiling, which is why the player could not see the enemy.
#      The Admiral did NOT shrink with her. He is 17 studs from boot to hat
#      on an 11-stud beam - proportionally BIGGER than he was, because he is
#      the enemy and she is the platform he stands on.
#   3. FOUR ACTUAL CANNONS, four objects, one gun each, integral to the
#      hull. Not four clusters of ordnance stapled to a hulk: a bow chaser
#      run out over the beakhead, a stern chaser through the transom, and
#      one heavy broadside gun on each side firing through its own port,
#      each with the ship's own furniture round it - carriage, trucks,
#      breeching rope, port lid, port frame.
#
# THE CAMERA ARITHMETIC, which is the whole of point 2 and is checkable.
# CameraController's birdseye rig: BIRDSEYE_DISTANCE 58, FOV 70 (vertical),
# aim band -62..+14, boom pinned at -20 so the EYE floats 27.3 studs over
# the sand no matter how far up the player aims. From the r 88 drop ring,
# facing him, the eye is 54.5 studs further out: 142.5 studs from the boss.
# Half the frame is 35 degrees, so the top of frame at that range sits at
#
#     z = 27.3 + 142.5 * tan(35 + aim)
#
#   aim -34 (REST)   top of frame z 29.8
#   aim -30          top of frame z 40.1
#   aim -20 (BOOM)   top of frame z 65.5
#
# The OLD model topped out at 72 studs, needing aim >= -17.6 - above the
# boom pin and 3.6 degrees short of the +14 ceiling. The player had to hold
# the camera at the top of its travel to see the boss at all, and the boss
# is what the fight is about. THIS model tops out at 34.4 (the sabre tip),
# needing aim >= -30.4: four degrees off the rest pose, in a 76-degree band.
# The hull, all four cannons and the Admiral to his shoulders are in frame
# at REST, and one small nudge frames the sabre.
#
# THE CANNONS ARE INSIDE THE BAND EVERYWHERE, which the old batteries were
# not - CameraController's own note records three of the four old targets
# falling OUTSIDE it (Deck 23.2 deg, Stern 23.1, Top 22.9 solved from the
# drop ring) and the camera breaking when the player reached for them. All
# four cannons now sit between z 9.0 and z 12.4, so the pitch that puts one
# on the crosshair is atan((z - 27.3) / D):
#
#   from the drop ring   D 142.5   -7.3 .. -5.9 deg
#   from the sand's edge D 186.5   -5.6 .. -4.6 deg
#   hard against the hull D 60     -17.7 .. -14.4 deg
#
# - all of them a long way inside -62..+14, at every range the fight has.
#
# WHY FOUR BEARINGS AND NOT FOUR HEIGHTS. The old spread was vertical
# because a hove-down hull gives you height for free. An upright hull gives
# you OCCLUSION for free instead, which is stronger: a solid ship between
# the camera and the far broadside hides it completely. So the four go to
# four bearings 90 degrees apart, and the two broadside guns are also
# separated fore-and-aft (port abaft the waist at x -11, starboard forward
# of it at x +12.5) so that even a bow-on or stern-on camera cannot line
# both up. Repositioning to reach the far pair is still the fight's loop.
#
# WR_GUNS is the single source of truth for all four: the art is built from
# it, the muzzle handoff is printed from it, and Bosses' `parts.mounts` is
# derived from it, so a gun the player can see and a gun the fight can fire
# out of cannot drift apart (the PY_SEAM_SITES idea).
#
# WHEN ALL FOUR ARE SILENCED the waist splits and the hold opens for the
# melee window. That is not a texture swap: the hull is authored in TWO
# BLOCKS with a 12-stud gap amidships, and the gap is filled by two shell
# plates that swing off the keel. Upright, they are a PORT plate and a
# STARBOARD plate and they peel outboard and down like double doors - the
# read the old design could not have, because its lower plate would have
# driven into the sand. Opened, the colossus is broken along her own
# centreline, bow and stern joined only by the keel and a bare ribcage of
# frames, with the heart-lantern burning between them. It reads best from
# directly above, which is where the fight camera is.
#
# CONTRAST WITH ITS OWN ARENA. The Careenage is warm: grey-brown shoal sand,
# a ring of near-black wrecks, teal ghost-fire (arena_gen's WK_* palette). So
# Wrack is the opposite on every axis - COLD slate-blue timber and drowned
# indigo, picked out in BONE, and burning BRASS AND AMBER where the arena
# burns green. He is the cold thing lit gold in a warm arena lit teal, and at
# 60 studs that is the only cue that has to survive.
#
# EMISSIVE PARTS CARRY `Glow` IN THE OBJECT NAME (Wrack_HeartGlow,
# Wrack_EyeGlow, Wrack_MuzzleGlow). Studio names a MeshPart after its OBJECT,
# so a material called `M_Wrack_AdmLamp` never reaches runtime - the marker
# has to ride the object name. See BossArenaService's GLOW_MARKERS. NOTE that
# that contract is implemented for ARENA meshes only; the boss path
# (<Boss>BodyController) has no such rule yet - the HANDOFF says so out loud.

WR_SEED = 5183

# --- palette ----------------------------------------------------------------
# Cold against the Careenage's warm. Every one of these is deliberately NOT a
# WK_* value from arena_gen: if the boss and its set share a hue the boss
# stops being a figure and becomes more scenery.
WR_TIMBER = (0.116, 0.136, 0.161)  # waterlogged hull planking, slate blue-grey
WR_WALE = (0.232, 0.263, 0.290)    # wales and rails: one step up, for banding
WR_KEELWOOD = (0.098, 0.114, 0.132)  # keel, stem, sternpost - the spine
WR_CRUSTED = (0.379, 0.406, 0.352)   # barnacle and weed crust on the bottom
WR_BONE = (0.855, 0.831, 0.741)      # the ship's frames, and his skull
WR_BRASS = (0.729, 0.518, 0.208)     # the guns. The one saturated warm in him
WR_LAMP = (1.000, 0.780, 0.420)      # the heart-lantern (Neon)
WR_EYE = (1.000, 0.800, 0.360)       # his eyes (Neon)
WR_FLARE = (1.000, 0.945, 0.780)     # muzzle fire (Neon) - near-white HOT, or
                                     # it reads as more brass beside the guns
WR_COAT = (0.118, 0.145, 0.243)      # the admiral's coat: drowned indigo
WR_GOLD = (0.788, 0.694, 0.400)      # lace, epaulettes, buttons - his rank
WR_FELT = (0.086, 0.086, 0.106)      # the bicorne
WR_STEEL = (0.741, 0.769, 0.788)     # the sabre
WR_SPAR = (0.376, 0.361, 0.333)      # masts and yards
WR_ROPE = (0.310, 0.286, 0.239)      # shrouds and tackle
WR_CANVAS = (0.588, 0.612, 0.639)    # sail rags - cooler than WK_CANVAS
WR_BED = (0.243, 0.231, 0.208)       # the bedding of spoil and shattered timber

WR_LADY = (0.792, 0.831, 0.855)      # the figurehead: a cold sea-glass white,
                                     # deliberately NOT WR_BONE's warm cream -
                                     # she is a ghost, not more ribcage


# --- ONE SPACE --------------------------------------------------------------
#
# She stands upright, so there is no ship space any more - the hull is
# authored directly in boss space with the keel line on y = 0 and the
# rabbet bedded WR_KEEL_Z studs into the sand, stern at -X, stem at +X,
# deck up at +Z, z = 0 the shoal.
#
# WHAT WENT AWAY, and why it is deleted rather than set to identity:
# WR_HEEL_DEG / WR_SHIP_Y / WR_SHIP_Z / WR_SHIP_SECTION / WR_SHIP / _wr_at /
# _wr_heel / _wr_surface. Their entire job was to keep a heeled mesh and an
# upright Admiral in two consistent spaces, and the old file's own comment
# named the resulting hazard: "a ship-space point dropped into a bmesh that
# later gets _wr_heel'd comes out heeled TWICE, which looks like a modelling
# mistake rather than a bug". An identity matrix left in place keeps the
# hazard and removes the reason for it. Machinery whose purpose is gone is
# deleted; the shell hinge below is the only rotation left in the section.
WR_KEEL_Z = 1.1

# --- materials --------------------------------------------------------------


def _wr_finish(name, bm, color, material):
    """`finish()`, but the material is named SEPARATELY from the object.

    boss_gen's finish() names the material after the object, which is exactly
    what keeps six bosses' palettes from repainting each other. Wrack needs
    the other half of that trick as well, for two reasons:

      * Many objects share one colour here - four cannons, two hull shells,
        an arm and a coat - and six near-identical brass datablocks would be
        six chances for someone to edit the wrong one.
      * The staged render builds arena_gen's Careenage into the SAME scene,
        and that file already owns M_Wrack_Sand / _Hull / _Plank / _Glow /
        _Iron / _Spar / _Canvas / _Weed / _Foam / _Cradle / _Strake / _Wet /
        _Tidewater / _Spoil / _HulkWood / _HulkPale. make_material reuses a
        datablock BY NAME, so reaching for any of those would silently
        repaint the arena in the boss's colours (or the reverse, depending on
        build order) and NOTHING in a standalone boss build would show it.

    So every material this boss creates is `M_Wrack_Adm*` - inside the briefed
    M_Wrack_ prefix, and disjoint from the arena's set by construction.
    """
    assert material.startswith("M_Wrack_Adm"), material
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(make_material(material, color))
    for poly in mesh.polygons:
        poly.use_smooth = False
    return obj


# --- primitives -------------------------------------------------------------


def _wr_tube(bm, a, b, r0, r1, sides=8):
    """A tapered tube between two arbitrary points - guns, spars, rope, ribs.

    The file's `disc()` only lies along +X; almost nothing on a ship does,
    so this is the workhorse.
    """
    a, b = Vector(a), Vector(b)
    axis = b - a
    if axis.length < 1e-6:
        return
    rot = Vector((0, 0, 1)).rotation_difference(axis.normalized()).to_matrix()
    mat = Matrix.Translation((a + b) / 2) @ rot.to_4x4()
    bmesh.ops.create_cone(
        bm, cap_ends=True, segments=sides, radius1=r0, radius2=r1, depth=axis.length, matrix=mat
    )


def _wr_vring(z, cx, cy, rx, ry, sides=14, boxy=1.0):
    """One horizontal cross-section for a loft stacked along +Z (the Admiral).

    `loft` needs its rings wound counter-clockwise about the STACKING axis or
    the faces come out inside-out, and ring_pts winds about +X - so this
    winds +X toward +Y, which is that same sense about +Z. `boxy` > 1 pushes
    the section toward a rounded rectangle, which is what gives a coat
    shoulders instead of a barrel.
    """
    pts = []
    for i in range(sides):
        angle = (i / sides) * TAU
        c, s = math.cos(angle), math.sin(angle)
        px = math.copysign(abs(c) ** (1.0 / boxy), c)
        py = math.copysign(abs(s) ** (1.0 / boxy), s)
        pts.append((cx + px * rx, cy + py * ry, z))
    return pts


# --- the hull ---------------------------------------------------------------
#
# Stations: (x, half-beam, half-width of the flat of floor, z of the sheer
# rail ABOVE THE KEEL RABBET). Stern at -21, stem at +20: a 41-stud hull,
# 12.6 in the beam - 3.3:1, which is a ship of the line's own proportion, so
# she still reads as a proper warship at half the old bulk rather than as a
# launch. The old table was 67 x 27 before a 1.28 section scale took the
# beam to 34.6; both the length and that scale are gone.
WR_HULL = [
    (-21.0, 2.6, 0.8, 13.2),   # the sternpost, under the gallery
    (-18.0, 4.6, 1.5, 13.6),   # the counter - the sheer's highest point
    (-14.0, 5.6, 2.1, 12.8),   # quarterdeck: the Admiral stands here
    (-10.0, 6.1, 2.4, 11.6),
    (-5.0, 6.3, 2.5, 10.7),    # midships, widest
    (0.0, 6.3, 2.5, 10.4),     # the waist, at the sheer's lowest
    (5.0, 6.0, 2.3, 10.6),
    (10.0, 5.2, 1.9, 11.2),    # the forecastle rising
    (15.0, 3.7, 1.3, 11.9),
    (20.0, 1.4, 0.5, 12.4),    # the stem
]

# One cross-section, as fractions: (y of half-beam, z of the sheer, floor?).
# `floor` scales y by the flat of floor instead, so she has a real flat
# bottom at the rabbet rather than a knife edge. Wound starboard -> up over
# the deck -> port -> down and back along the bottom, which is ring_pts's
# sense and so lofts with its faces pointing out.
WR_SECTION = [
    (1.000, 0.44, False),   # starboard, at the waterline - widest
    (0.972, 0.68, False),   # topside          <- the broadside gunports
    (0.900, 0.90, False),   # tumblehome
    (0.840, 1.00, False),   # starboard rail cap
    (0.700, 0.90, False),   # the waterway, inboard of the rail
    (0.000, 0.94, False),   # deck centreline, crowned
    (-0.700, 0.90, False),
    (-0.840, 1.00, False),  # port rail cap
    (-0.900, 0.90, False),
    (-0.972, 0.68, False),  # port topside     <- the broadside gunports
    (-1.000, 0.44, False),  # port, at the waterline
    (-0.935, 0.21, False),  # the turn of the bilge
    (-0.640, 0.07, False),  # the floor, rising
    (-1.000, 0.00, True),   # the keel rabbet, port      <- the shells' hinge
    (1.000, 0.00, True),    # the keel rabbet, starboard <- the shells' hinge
    (0.640, 0.07, False),
    (0.935, 0.21, False),
]

# The waist. The hull is lofted as two blocks with this gap between them, and
# the gap is what the shell plates fill - so "the hull cracks open" is a real
# hole in a real mesh, not a decal. 12 studs on a 41-stud hull, the same
# 29% of her length the old 20-on-67 gap was.
WR_WAIST = (-3.0, 9.0)

# Indices of WR_SECTION each shell plate spans. Both hinge on the keel and
# meet on the deck centreline, so they open like a ribcage.
#
# UPRIGHT THEY ARE A PORT PLATE AND A STARBOARD PLATE, and that is what
# makes the melee window read from the fight camera: they peel OUTBOARD AND
# DOWN about the keel, in opposite senses, like double doors thrown open,
# and the plan view splits along her own centreline. The lower plate starts
# at the PORT rabbet, not the starboard one, so it carries the flat of the
# floor BETWEEN the two rabbets with it. Without that the closed hull had an
# 11-stud hole running the whole length of the waist along the keel, and the
# ribcage showed through a hull that was supposed to be intact.
WR_SHELL_UPPER = [5, 6, 7, 8, 9, 10, 11, 12, 13]        # deck centre -> port keel
WR_SHELL_LOWER = [13, 14, 15, 16, 0, 1, 2, 3, 4, 5]     # port keel -> deck centre

# How far each plate swings when the cannons are all silenced, about the keel
# axis. Equal and opposite, because upright the two plates are mirror images
# and anything else reads as damage rather than as a hull opening.
#
# 50 IS THE SAND'S NUMBER, not a taste call. The port plate's rail sits 6.3
# out and 9.3 up from the hinge; rotated by a it lands at
# z = -6.3 sin a + 9.3 cos a above the hinge, so at 50 deg it is 1.2 studs
# over the rabbet - 2.3 over the shoal - and at 55 it is through the floor.
WR_OPEN_UPPER_DEG = 50.0
WR_OPEN_LOWER_DEG = -50.0


def _wr_station(x):
    """(half-beam, flat of floor, sheer z above the rabbet) along the hull."""
    if x <= WR_HULL[0][0]:
        return WR_HULL[0][1:]
    if x >= WR_HULL[-1][0]:
        return WR_HULL[-1][1:]
    for (x0, h0, f0, s0), (x1, h1, f1, s1) in zip(WR_HULL, WR_HULL[1:]):
        if x0 <= x <= x1:
            t = (x - x0) / (x1 - x0)
            return (h0 + (h1 - h0) * t, f0 + (f1 - f0) * t, s0 + (s1 - s0) * t)
    return WR_HULL[-1][1:]


def _wr_deck(x):
    """The z of the deck's crown at station `x` - where anything standing on
    her stands. WR_SECTION[5] is the deck centreline at 0.94 of the sheer."""
    return WR_KEEL_Z + WR_SECTION[5][1] * _wr_station(x)[2]



def _wr_deck_at(x, y):
    """The z of the DECK SURFACE at (x, y) - the crown ACROSS the beam.

    `_wr_deck(x)` is the CENTRELINE crown, which is right for anything stood
    amidships and wrong for anything in a waterway: WR_SECTION drops from 0.94
    of the sheer at the centreline to 0.90 at index 4, so a hatch seated on
    `_wr_deck(x)` alone floats by up to half a stud at the ship's side. This
    interpolates the same three section points the deck run is built from.
    """
    half, _floor, sheer = _wr_station(x)
    frac = abs(y) / half if half > 1e-6 else 0.0
    run = ((0.000, 0.94), (0.700, 0.90), (0.840, 1.00))
    if frac >= run[-1][0]:
        return WR_KEEL_Z + run[-1][1] * sheer
    for (f0, z0), (f1, z1) in zip(run, run[1:]):
        if f0 <= frac <= f1:
            t = (frac - f0) / (f1 - f0)
            return WR_KEEL_Z + (z0 + (z1 - z0) * t) * sheer
    return WR_KEEL_Z + run[0][1] * sheer


# The deck furniture, hoisted OUT of build_wr_strakes so the builder and the
# clearance checks below read the SAME table. They used to be a literal inside
# the builder and a copy inside the checker, which is this project's most
# common bug shape - a value that exists in one place and is remembered in
# another. (x, half-length, half-width) and (x, y).
WR_COAMINGS = ((-17.5, 1.8, 2.4), (-11.0, 1.5, 2.0), (11.5, 1.6, 2.2), (16.0, 1.2, 1.6))
WR_BITTS = ((-8.5, -2.0), (-8.5, 2.0), (10.0, -1.6), (10.0, 1.6))


def _wr_ring(x, scale=1.0, indices=None):
    """One hull cross-section at station `x`, in boss space.

    `scale` scales the section about the KEEL RABBET, not about the boss
    origin, which is why WR_KEEL_Z is added after it: a scaled ring (the
    ribs, a proud crust point) has to stay bedded at the same depth.
    """
    half, floor, sheer = _wr_station(x)
    pts = []
    for index in indices if indices is not None else range(len(WR_SECTION)):
        yf, zf, is_floor = WR_SECTION[index]
        y = yf * (floor if is_floor else half) * scale
        pts.append((x, y, WR_KEEL_Z + zf * sheer * scale))
    return pts


def _wr_skin(x, index, out=0.0):
    """A point ON the hull's skin, pushed `out` studs proud of it - where
    crust sits, where a gunport frame lands, where rope belays.

    There is ONE space now, so unlike the careened version this is the only
    skin accessor and it can be used from any builder. The old _wr_surface
    (the same point pre-heeled into boss space) and the rule about which
    builders were allowed to call which are gone with the heel.
    """
    ring = _wr_ring(x, scale=1.0 + out / 12.0) if out else _wr_ring(x)
    return Vector(ring[index])


def build_wr_base(rng):
    """THE ANCHOR OBJECT, and a real piece of set: the bed she drove into.
    Spoil ploughed up along both bilges, the shattered keel blocks she ground
    over, sand banked against her sides.

    It is centred on the boss origin on purpose - BossArenaService's
    placeAuthored pins a model by its `<model>_Base` part, so this object's
    centre IS where the fight places him.
    """
    bm = bmesh.new()
    # The sand she is bedded in: a low dished mound under the whole length.
    for i in range(22):
        t = i / 21.0
        x = -25.0 + t * 50.0
        half = _wr_station(x)[0]
        width = 3.4 + half * 1.35
        box(
            bm,
            (x, math.sin(t * 5.0) * 1.1, 0.35 + rng.uniform(-0.12, 0.12)),
            (3.0, width * 2.0, 1.5),
            Matrix.Rotation(rng.uniform(-0.05, 0.05), 3, "Z"),
        )
    # Spoil banked against BOTH bilges - upright, she ploughed in level and
    # threw the shoal up either side of her rather than only to leeward.
    for _ in range(34):
        x = rng.uniform(-20.0, 19.0)
        side = rng.choice((11, 16))
        at = _wr_skin(x, side, out=1.0)
        rock = rng.uniform(1.1, 2.6)
        ellipsoid(
            bm,
            (at.x + rng.uniform(-1.2, 1.2), at.y + math.copysign(rng.uniform(0.4, 2.0), at.y), 0.5),
            (rock, rock * rng.uniform(0.7, 1.3), rock * rng.uniform(0.28, 0.5)),
            subdiv=1,
        )
    # The keel blocks: the baulks she was hauled over, crushed and splayed.
    for i in range(7):
        x = -18.0 + i * 6.0
        lean = rng.uniform(-0.5, 0.5)
        box(
            bm,
            (x, rng.uniform(-1.2, 1.2), 0.75),
            (2.4, 7.0, 1.5),
            Matrix.Rotation(lean, 3, "Z") @ Matrix.Rotation(rng.uniform(-0.25, 0.25), 3, "X"),
        )
    # Splinters ploughed out of the sand along the way in.
    for _ in range(28):
        x = rng.uniform(-24.0, 22.0)
        y = rng.uniform(-14.0, 14.0)
        length = rng.uniform(1.6, 4.4)
        spike(
            bm,
            (x, y, rng.uniform(0.0, 0.4)),
            (x + rng.uniform(-1.5, 1.5) * length, y + rng.uniform(-0.6, 0.6) * length, rng.uniform(0.6, 2.0)),
            rng.uniform(0.2, 0.45),
        )
    return _wr_finish("Wrack_Base", bm, WR_BED, "M_Wrack_AdmBed")


def build_wr_hull(rng):
    """The flagship's carcass, upright and bedded to her rabbet - TWO blocks
    with the waist missing between them. Everything else hangs off this."""
    bm = bmesh.new()
    for x0, x1 in ((WR_HULL[0][0], WR_WAIST[0]), (WR_WAIST[1], WR_HULL[-1][0])):
        rings = []
        steps = max(int((x1 - x0) / 2.0), 3)
        for i in range(steps + 1):
            rings.append(_wr_ring(x0 + (x1 - x0) * (i / steps)))
        loft(bm, rings)
    # Shot holes and sprung planking: the hull is a survivor of something.
    for _ in range(22):
        x = rng.uniform(-19.0, 18.0)
        if WR_WAIST[0] - 1.5 < x < WR_WAIST[1] + 1.5:
            continue
        index = rng.choice((1, 2, 9, 10, 11, 16))
        at = _wr_skin(x, index, out=0.5)
        size = rng.uniform(0.5, 1.4)
        ellipsoid(bm, at, (size, size, size * 0.55), subdiv=1)
    return _wr_finish("Wrack_Hull", bm, WR_TIMBER, "M_Wrack_AdmTimber")


def build_wr_strakes(rng):
    """Wales, sheer rails and channels: the horizontal banding that makes a
    41-stud slab of timber read as a SHIP from across the arena. Without
    these the hull is a whale."""
    bm = bmesh.new()
    # Two wales and the rail caps, run the full length as chains of short
    # baulks so a broken hull does not get a suspiciously perfect line.
    for index, girth in ((1, 0.55), (9, 0.55), (3, 0.46), (7, 0.46), (11, 0.40)):
        x = WR_HULL[0][0] + 0.8
        while x < WR_HULL[-1][0] - 1.5:
            step = rng.uniform(2.6, 4.4)
            nxt = min(x + step, WR_HULL[-1][0] - 0.8)
            if not (WR_WAIST[0] - 0.8 < (x + nxt) / 2 < WR_WAIST[1] + 0.8):
                _wr_tube(
                    bm,
                    _wr_skin(x, index, out=0.55),
                    _wr_skin(nxt, index, out=0.55),
                    girth * rng.uniform(0.9, 1.1),
                    girth * rng.uniform(0.9, 1.1),
                    6,
                )
            x = nxt + rng.uniform(0.1, 0.4)
    # Deck planking, laid fore-and-aft, on the two decked blocks.
    for offset in (-0.62, -0.31, 0.0, 0.31, 0.62):
        for x0, x1 in ((WR_HULL[0][0] + 1.5, WR_WAIST[0]), (WR_WAIST[1], 18.5)):
            steps = max(int((x1 - x0) / 3.0), 2)
            for i in range(steps):
                xa = x0 + (x1 - x0) * (i / steps)
                xb = x0 + (x1 - x0) * ((i + 1) / steps)
                half_a = _wr_station(xa)[0]
                half_b = _wr_station(xb)[0]
                _wr_tube(
                    bm,
                    (xa, offset * half_a, _wr_deck(xa) - 0.1),
                    (xb, offset * half_b, _wr_deck(xb) - 0.1),
                    0.26,
                    0.26,
                    4,
                )
    # THE GUNPORTS. Upright, both broadsides face the arena and both are at
    # the player's own eye line, so these are no longer decoration - they are
    # the row the four real cannons belong to, and the reason the cannons
    # read as THE SHIP'S rather than as ordnance parked against her. Every
    # port on the topside strake gets a frame; the four that matter get a
    # gun through them (build_wr_cannon_*), and the rest are shut or empty.
    x = -19.0
    while x < 19.0:
        if not (WR_WAIST[0] - 1.5 < x < WR_WAIST[1] + 1.5):
            for index in (1, 9):
                at = _wr_skin(x, index, out=0.45)
                edge = (_wr_skin(x + 1.0, index, out=0.45) - at).normalized()
                rise = (_wr_skin(x, index - 1, out=0.45) - at).normalized()
                for along, up in ((1.35, 0.0), (-1.35, 0.0), (0.0, 1.35), (0.0, -1.35)):
                    _wr_tube(
                        bm,
                        at + edge * (along - 0.4 if along else -1.35) + rise * (up - 0.4 if up else -1.35),
                        at + edge * (along + 0.4 if along else 1.35) + rise * (up + 0.4 if up else 1.35),
                        0.24,
                        0.24,
                        4,
                    )
        x += 4.6

    # DECK FURNITURE: coamings, bitts and a capstan. A bare deck reads as a
    # flat plate from the fight camera - which is exactly what the first
    # staged sheet of the old model showed - because a plane that big gives
    # the eye no scale. These are what make it a ship's deck instead of a lid.
    # Square to the world now, because the deck is.
    for x, run, wide in WR_COAMINGS:
        deck = _wr_deck(x)
        for dx in (-run, run):
            box(bm, (x + dx, 0.0, deck + 0.5), (0.6, wide * 2.0, 1.1))
        for dy in (-wide, wide):
            box(bm, (x, dy, deck + 0.5), (run * 2.0, 0.6, 1.1))
    for x, y in WR_BITTS:
        box(bm, (x, y, _wr_deck(x) + 0.8), (0.75, 0.75, 1.8))
    _wr_tube(bm, (-9.8, 0.0, _wr_deck(-9.8)), (-9.8, 0.0, _wr_deck(-9.8) + 2.4), 1.3, 1.6, 9)
    # The channels: the shelves the shrouds set up from, on both sides now.
    for side in (7, 15):
        for x in (-9.0, -6.0):
            _wr_tube(bm, _wr_skin(x, side, out=0.3), _wr_skin(x, side, out=2.0), 0.95, 0.7, 5)
    return _wr_finish("Wrack_Strakes", bm, WR_WALE, "M_Wrack_AdmWale")


def build_wr_keel(rng):
    """Keel, stem and sternpost - the spine that survives when the waist
    opens. When the shells swing, THIS is what still joins bow to stern."""
    bm = bmesh.new()
    x = WR_HULL[0][0]
    while x < WR_HULL[-1][0] - 0.5:
        nxt = min(x + 2.6, WR_HULL[-1][0])
        _wr_tube(bm, (x, 0.0, WR_KEEL_Z - 0.35), (nxt, 0.0, WR_KEEL_Z - 0.35), 1.0, 1.0, 6)
        x = nxt
    # The sternpost, raking aft, and the stem, raking forward: the two ends
    # that give the plan view its points.
    _wr_tube(bm, (-20.5, 0.0, WR_KEEL_Z), (-22.4, 0.0, WR_KEEL_Z + 11.4), 1.1, 0.8, 6)
    _wr_tube(bm, (19.5, 0.0, WR_KEEL_Z), (21.6, 0.0, WR_KEEL_Z + 11.8), 1.1, 0.7, 6)
    # Deadwood at both ends, and the bilge keels she ground the furrows with.
    for x0, x1 in ((-20.5, -16.0), (16.0, 20.0)):
        _wr_tube(bm, (x0, 0.0, WR_KEEL_Z + 1.0), (x1, 0.0, WR_KEEL_Z + 1.0), 1.4, 0.95, 6)
    for side in (1, -1):
        x = -16.0
        while x < 16.0:
            nxt = x + 4.0
            _wr_tube(
                bm,
                (x, side * _wr_station(x)[1] * 1.9, WR_KEEL_Z + 0.7),
                (nxt, side * _wr_station(nxt)[1] * 1.9, WR_KEEL_Z + 0.7),
                0.42,
                0.42,
                4,
            )
            x = nxt
    return _wr_finish("Wrack_Keel", bm, WR_KEELWOOD, "M_Wrack_AdmKeel")


def build_wr_crust(rng):
    """Barnacle and weed crust along her waterline and down onto the sand -
    the tide mark that says she has been standing here a long time. Upright,
    the foul bottom is buried, so what is left of it is the band between the
    turn of the bilge and the wales, which is exactly the band at the
    player's eye line."""
    bm = bmesh.new()
    for _ in range(140):
        x = rng.uniform(-19.5, 18.5)
        if WR_WAIST[0] < x < WR_WAIST[1]:
            continue
        index = rng.choice((0, 10, 10, 11, 11, 16, 16, 12, 15))
        at = _wr_skin(x, index, out=rng.uniform(0.3, 0.8))
        size = rng.uniform(0.3, 1.0)
        ellipsoid(bm, at, (size, size * rng.uniform(0.7, 1.2), size * rng.uniform(0.35, 0.7)), subdiv=1)
    # Weed, hanging off the turn of the bilge and the wales in long strands.
    for _ in range(40):
        x = rng.uniform(-19.0, 18.0)
        if WR_WAIST[0] < x < WR_WAIST[1]:
            continue
        at = _wr_skin(x, rng.choice((0, 10, 11, 16)), out=0.5)
        drop = rng.uniform(1.4, 4.0)
        blade(
            bm,
            at,
            (at.x + rng.uniform(-0.8, 0.8), at.y + math.copysign(rng.uniform(0.2, 1.2), at.y), max(at.z - drop, 0.2)),
            rng.uniform(0.5, 1.3),
            rng.uniform(0.15, 0.5),
            0.12,
            roll=rng.uniform(0, TAU),
        )
    return _wr_finish("Wrack_Crust", bm, WR_CRUSTED, "M_Wrack_AdmCrust")


def build_wr_ribs(rng):
    """The frames across the open waist: the ribcage the shells hide. Bone,
    because that is the read - a ship's frames and a man's ribs are the same
    shape and this boss is the joke about that."""
    bm = bmesh.new()
    # A frame traced round the section the long way: starboard topside, down
    # under the keel, up the port side. An open U, not a bulkhead - you have
    # to be able to SEE the heart through it.
    trace = [2, 1, 0, 16, 15, 14, 13, 12, 11, 10, 9, 8]
    for x in (-2.4, 0.0, 2.6, 5.2, 7.8):
        ring = _wr_ring(x, scale=0.88)
        for a, b in zip(trace, trace[1:]):
            _wr_tube(bm, Vector(ring[a]), Vector(ring[b]), 0.38, 0.38, 5)
    # Half-frames and a broken deck beam or two, so the cage has depth rather
    # than reading as five identical hoops.
    for x in (-1.2, 1.3, 3.9, 6.5):
        ring = _wr_ring(x, scale=0.86)
        for a, b in zip(trace[3:9], trace[4:10]):
            _wr_tube(bm, Vector(ring[a]), Vector(ring[b]), 0.29, 0.29, 4)
    for x in (-1.8, 2.0, 6.0):
        half, _, sheer = _wr_station(x)
        _wr_tube(bm, (x, -half * 0.80, WR_KEEL_Z + sheer * 0.90), (x, half * 0.80, WR_KEEL_Z + sheer * 0.90), 0.33, 0.33, 4)
    # Splintered stubs where the frames tore, on both cut faces of the hull.
    for x in WR_WAIST:
        ring = _wr_ring(x, scale=0.90)
        for index in trace[::2]:
            point = Vector(ring[index])
            spike(bm, point, (point.x + (1.6 if x > 0 else -1.6), point.y, point.z), 0.3)
    return _wr_finish("Wrack_Ribs", bm, WR_BONE, "M_Wrack_AdmBone")


def _wr_shell(name, material, colour, indices, rng):
    """One of the two plates that fill the waist. Authored CLOSED, in place -
    the client swings it about the keel axis to open the hold."""
    bm = bmesh.new()
    x0, x1 = WR_WAIST
    steps = 7
    outer = [_wr_ring(x0 + (x1 - x0) * (i / steps), indices=indices) for i in range(steps + 1)]
    inner = [_wr_ring(x0 + (x1 - x0) * (i / steps), scale=0.95, indices=indices) for i in range(steps + 1)]
    # A plate, not a surface: skin it inside and out and close the four edges,
    # so an opened shell has thickness when you look at its back.
    rings = [o + list(reversed(i)) for o, i in zip(outer, inner)]
    loft(bm, rings)
    # Sprung and splitting: the seams the thing is about to come apart along.
    for i in range(6):
        t = 0.12 + i * 0.15
        x = x0 + (x1 - x0) * t
        ring = _wr_ring(x, indices=indices, scale=1.02)
        for a, b in zip(ring, ring[1:]):
            if rng.random() < 0.55:
                _wr_tube(bm, Vector(a), Vector(b), 0.22, 0.22, 4)
    # A plate is the one thing here lofted as a RIBBON rather than a closed
    # tube, so its inner skin comes out of `loft` wound the wrong way and
    # renders inside-out (Roblox meshes are single-sided). An opened shell is
    # seen from behind by definition, so this is not optional.
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    return _wr_finish(name, bm, colour, material)


def build_wr_shell_upper(rng):
    """The PORT plate: the waist's deck half, port topside and port bilge.
    Hinges on the keel and peels outboard and down to -Y."""
    return _wr_shell("Wrack_ShellUpper", "M_Wrack_AdmTimber", WR_TIMBER, WR_SHELL_UPPER, rng)


def build_wr_shell_lower(rng):
    """The STARBOARD plate: the flat of the floor and the starboard side.
    Hinges on the same keel and peels outboard and down to +Y - the mirror
    of its sister, which is what makes the open hull read as double doors."""
    return _wr_shell("Wrack_ShellLower", "M_Wrack_AdmTimber", WR_TIMBER, WR_SHELL_LOWER, rng)


# Where the heart hangs: on the centreline in the hold, high enough that the
# fight camera looking down into an opened waist finds it, low enough that
# the closed plates cover it.
WR_HEART = (3.0, 0.0, 6.4)


def build_wr_heart():
    """The lantern where a heart should be - the melee target, and the only
    warm light inside him. `Glow` is in the OBJECT name because that is the
    only half of the name that survives a glTF import."""
    bm = bmesh.new()
    at = Vector(WR_HEART)
    ellipsoid(bm, at, (1.9, 1.9, 2.3), subdiv=2)
    ellipsoid(bm, (at.x, at.y, at.z + 2.3), (0.85, 0.85, 0.8), subdiv=1)
    return _wr_finish("Wrack_HeartGlow", bm, WR_LAMP, "M_Wrack_AdmLamp")


def build_wr_heart_cage(rng):
    """The lantern's iron: a ship's binnacle lamp gone wrong, slung in the
    hold on chains off the deck beams."""
    bm = bmesh.new()
    at = Vector(WR_HEART)
    for i in range(6):
        angle = (i / 6) * TAU
        offset = Vector((math.cos(angle) * 2.1, math.sin(angle) * 2.1, 0.0))
        _wr_tube(bm, at + offset + Vector((0, 0, -2.6)), at + offset + Vector((0, 0, 2.6)), 0.20, 0.20, 4)
    for dz in (-2.5, 2.5):
        for i in range(6):
            a0 = (i / 6) * TAU
            a1 = ((i + 1) / 6) * TAU
            _wr_tube(
                bm,
                at + Vector((math.cos(a0) * 2.1, math.sin(a0) * 2.1, dz)),
                at + Vector((math.cos(a1) * 2.1, math.sin(a1) * 2.1, dz)),
                0.20,
                0.20,
                4,
            )
    # The chains it hangs on, up into what is left of the deck beams.
    for side in (-1, 1):
        _wr_tube(bm, at + Vector((0, 0, 2.7)), (WR_HEART[0] + side * 2.6, 0.0, _wr_deck(WR_HEART[0]) - 0.4), 0.16, 0.16, 4)
    return _wr_finish("Wrack_HeartCage", bm, WR_BRASS, "M_Wrack_AdmBrass")


# --- the four cannons -------------------------------------------------------
#
# THE SINGLE SOURCE OF TRUTH for all four, in boss space. Each entry is a
# LIST of (breech, muzzle, bore) so the muzzle handoff, the flare placement
# and `parts.mounts` keep the same shape they always had - but every list
# now holds exactly ONE gun, because the design brief is four cannons and
# not four batteries. One object, one gun, one name, one target.
#
# THEY ARE BIG ON PURPOSE. Bore 1.55 puts the breech reinforce 6.4 studs
# across on a 12.6-stud beam and the barrel 9 studs long on a 41-stud hull -
# monstrous ordnance, which is the point twice over: it is what the player
# has to hit from 60+ studs through a pitched-down camera, and a boss's guns
# should be too big for the ship carrying them.
#
# WHERE THEY ARE AND WHY (see the section header's occlusion argument):
#   Bow        +X   over the beakhead, on the forecastle
#   Starboard  +Y   x +12.5, forward of the waist
#   Stern      -X   through the transom, under the Admiral's own boots
#   Port       -Y   x -11, abaft the waist
# Four bearings 90 degrees apart, and the two broadside guns pulled 23.5
# studs apart fore-and-aft so a bow-on or stern-on camera cannot line them
# both up either.
#
# All four clear the waist (-3 .. +9) - a gun stepped on a shell plate would
# fly apart when the hold opens, the same rule the mainmast obeys.
# WHERE THEY ARE AND WHY - THE 2026-09-09 CORNER REWORK, and it was one note
# from the player: the four guns move to the ship's FOUR CORNERS, mounted
# OUTBOARD on sponsons, so a player must walk around the ship to shoot all
# four and can never shoot a far one through the hull.
#
# THE OLD LAYOUT'S PREMISE WAS MEASURABLY FALSE. It put the four on four
# bearings and leaned on the hull to hide the far pair ("an upright hull gives
# you OCCLUSION for free"). Traced from the birdseye eye - which floats 27.3
# studs up - a sight line to a far gun clears a 13.5-stud hull by a full stud
# at r 132. The hull never occluded anything at the height this fight is
# actually watched from; the old note was never checked against the camera.
#
# So the occlusion is now the guns' OWN: each stands in a three-sided
# CASEMATE (back wall + two cheeks) whose mouth faces outboard. See
# WR_CASEMATE_* and `_wr_assert_sponsons` - the property is measured on every
# build, not asserted in a comment.
#
# Canonical order EVERYWHERE (WR_GUNS, the mounts handoff, the client's
# PIECES): BowStbd, BowPort, SternStbd, SternPort.
WR_GUN_ORDER = ("BowStbd", "BowPort", "SternStbd", "SternPort")
WR_GUN_BEARING = {"BowStbd": 30.0, "BowPort": -30.0, "SternStbd": 150.0, "SternPort": -150.0}
WR_GUN_R = 19.0        # the mount, out along its own bearing
WR_GUN_HALF = 4.5      # half the barrel's length
WR_GUN_BORE = 1.55
WR_GUN_Z = {"BowStbd": 13.2, "BowPort": 13.2, "SternStbd": 14.0, "SternPort": 14.0}


def _wr_gun_axis(name):
    """(unit bearing, unit lateral) for one corner gun, in plan."""
    b = math.radians(WR_GUN_BEARING[name])
    return Vector((math.cos(b), math.sin(b), 0.0)), Vector((-math.sin(b), math.cos(b), 0.0))


def _wr_gun_span(name):
    n, _u = _wr_gun_axis(name)
    mid = n * WR_GUN_R + Vector((0.0, 0.0, WR_GUN_Z[name]))
    return (tuple(mid - n * WR_GUN_HALF), tuple(mid + n * WR_GUN_HALF), WR_GUN_BORE)


WR_GUNS = {name: [_wr_gun_span(name)] for name in WR_GUN_ORDER}

# THE CASEMATES. A flat inboard bulkhead CANNOT do this job at any size:
# swept from half-width 4 to 34 it goes straight from "leaks a third gun on 92
# of 144 samples" to "eats its own gun on 56 of them", with no window between.
# Cheeks bound each gun's arc with the gun's OWN box and so cannot grow wide
# enough to swallow it.
WR_CASEMATE_R_BACK = 13.0
WR_CASEMATE_HW = 4.0
WR_CASEMATE_R_OUT = 23.0
# THE BAND TOP IS 19.0, NOT 17.5, AND IT IS THE THIRD LEAK THIS DESIGN HAD.
# The stern mounts sit at z 14.0 and the capture sphere reaches 4.0, so the
# hittable volume tops out at 18.0 - half a stud PROUD of a 17.5 plate. A
# third gun was reachable straight over its own casemate on 29 of 144
# bearings. The first leak was lateral (a flat bulkhead), the second radial
# (the sphere past the cheek mouth), this one vertical; each was invisible to
# the check that caught the last. Control 6 below drops the band back to 17.5
# and must FIRE.
WR_CASEMATE_Z = (8.5, 19.0)
# The window, re-derived under the CAPTURE-SPHERE model (see below):
# mouth 21.5 leaks a third gun on 32 of 144 samples, 22.0 on 4; 24.5 blinds 2
# and eats 2. 22.5..24.0 passes, and 23.0 sits mid-window.
# Filled by build_wr_sponsons from the plates' OWN vertices, and read by the
# guard. Measuring the exported geometry rather than the constants that made
# it is the whole point: a constant says what was intended, a vertex says what
# was built.
WR_CASEMATE_MEASURED = {}
WR_CASEMATE_WINDOW = {"back_r": (12.0, 13.0), "cheek_hw": (3.2, 4.0), "out_r": (22.5, 24.0)}

# THE PLAYER'S SHOT IS A SPHERE, NOT A RAY, AND THAT IS THE WHOLE PROBLEM.
# `Creatures.items.wrack_battery.shotRadius` is a proximity capture about the
# MOUNT - so the hittable volume is a ball, and if that ball is bigger than
# the aperture shielding it, it pokes out past the cheeks and every gun is
# shootable from every bearing. Measured: at radius 5.0, 80 of 144 samples
# could hit three or more guns THROUGH the ship. The governing constraint is
# simply `shotRadius <= WR_CASEMATE_HW`.
#
# THIS VALUE IS A COPY and there is no way to make it not be one - the other
# half lives in Luau. It MUST equal Creatures.items.wrack_battery.shotRadius.
# The digest prints it every build so a drift shows up in the log instead of
# in the fight, and check_content cross-checks the two files.
WR_BATTERY_SHOT_RADIUS = 4.0
WR_SIGHT_RINGS = (88.0, 132.0)
WR_SHOT_Z = 4.5      # the player's muzzle: HumanoidRootPart + 1.5
WR_EYE_Z = 27.3      # CameraController's birdseye float

# Where the bowsprit runs - the beakhead out to the broken cap. It rides
# ABOVE the bow chaser (which is why the chaser is 1.4 studs to port and 2.6
# studs under it at the muzzle): a spar through a gun barrel is the kind of
# intersection nobody notices in a wireframe and everybody notices in game.
WR_BOWSPRIT = ((18.5, 0.0, 13.2), (28.0, 0.0, 17.4))


def _wr_gun(bm, breech, muzzle, bore, sides=9):
    """One naval gun: a tapered chase with a reinforce at the breech, a swell
    at the muzzle, trunnions, and a cascabel behind. This is the shape the
    player is aiming AT, so it gets real parts."""
    breech, muzzle = Vector(breech), Vector(muzzle)
    axis = muzzle - breech
    length = axis.length
    if length < 1e-6:
        return
    n = axis.normalized()
    _wr_tube(bm, breech, muzzle - n * length * 0.09, bore * 1.75, bore * 1.15, sides)
    _wr_tube(bm, breech - n * 0.7, breech + n * length * 0.20, bore * 2.05, bore * 1.95, sides)
    _wr_tube(bm, breech + n * length * 0.52, breech + n * length * 0.62, bore * 1.5, bore * 1.5, sides)
    _wr_tube(bm, muzzle - n * length * 0.09, muzzle, bore * 1.48, bore * 1.34, sides)
    _wr_tube(bm, muzzle - n * 0.45, muzzle + n * 0.06, bore * 0.74, bore * 0.66, sides)
    ellipsoid(bm, breech - n * 1.1, (bore * 0.85,) * 3, subdiv=1)
    side = n.cross(Vector((0.0, 0.0, 1.0)))
    if side.length < 0.25:
        side = n.cross(Vector((0.0, 1.0, 0.0)))
    side.normalize()
    at = breech + n * length * 0.40
    _wr_tube(bm, at - side * bore * 2.5, at + side * bore * 2.5, bore * 0.62, bore * 0.62, 6)
    return n, length


def _wr_carriage(bm, breech, n, bore, deck_z, rng):
    """The truck carriage under a gun: two cheeks stepped down toward the
    breech, an axletree fore and aft, four trucks, a quoin, and the training
    tackle. THIS is the half of the object that says "part of the ship" -
    a barrel alone floats, a barrel on a carriage bolted to a deck does not.
    """
    breech = Vector(breech)
    side = n.cross(Vector((0.0, 0.0, 1.0)))
    if side.length < 0.25:
        side = n.cross(Vector((0.0, 1.0, 0.0)))
    side.normalize()
    axis = Vector((n.x, n.y, 0.0))
    axis = axis.normalized() if axis.length > 1e-6 else Vector((1.0, 0.0, 0.0))
    hub = Vector((breech.x, breech.y, deck_z + 1.5))
    # The cheeks: a stepped plank each side, standing on the deck.
    for s in (-1, 1):
        for step, (along, rise, run) in enumerate(((-0.6, 0.0, 2.4), (1.6, 0.5, 2.0), (3.4, 0.9, 1.5))):
            at = hub + axis * along + side * (s * bore * 1.85) + Vector((0.0, 0.0, rise - 0.7))
            box(
                bm,
                at,
                (run, 0.55, 1.5 - step * 0.22),
                Matrix.Rotation(math.atan2(axis.y, axis.x), 3, "Z"),
            )
    # Axletrees and four trucks - the little solid wheels a gun runs back on.
    for along in (-0.4, 3.2):
        _wr_tube(bm, hub + axis * along - side * bore * 2.1 + Vector((0, 0, -1.3)),
                 hub + axis * along + side * bore * 2.1 + Vector((0, 0, -1.3)), 0.28, 0.28, 5)
        for s in (-1, 1):
            centre = hub + axis * along + side * (s * bore * 2.0) + Vector((0.0, 0.0, -1.3))
            _wr_tube(bm, centre - side * s * 0.26, centre + side * s * 0.26, 0.72, 0.72, 9)
    # The quoin under the breech, and the cascabel's breeching rope back to
    # two ring bolts in the ship's side.
    box(bm, hub - axis * 1.4 + Vector((0.0, 0.0, -0.35)), (1.6, bore * 2.4, 0.7),
        Matrix.Rotation(math.atan2(axis.y, axis.x), 3, "Z"))
    tail = breech - n * 1.1
    for s in (-1, 1):
        eye = hub + axis * 3.0 + side * (s * bore * 3.1) + Vector((0.0, 0.0, 0.4))
        mid = (tail + eye) / 2 + Vector((0.0, 0.0, -rng.uniform(0.5, 0.9)))
        _wr_tube(bm, tail, mid, 0.19, 0.21, 4)
        _wr_tube(bm, mid, eye, 0.21, 0.19, 4)


def _wr_portframe(bm, muzzle, n, bore, lid_up=True):
    """The gunport the barrel comes through: a squared frame of timber in the
    ship's side and the lid hinged up over it on two chains. Without this the
    gun is a pipe pushed through planking; with it, it is a port."""
    muzzle = Vector(muzzle)
    side = n.cross(Vector((0.0, 0.0, 1.0)))
    if side.length < 0.25:
        side = n.cross(Vector((0.0, 1.0, 0.0)))
    side.normalize()
    up = side.cross(n).normalized()
    at = muzzle - n * (bore * 3.4)
    half = bore * 2.2
    for dy, dz in ((0, 1), (0, -1), (1, 0), (-1, 0)):
        offset = side * (dy * half) + up * (dz * half)
        span = (side * half * 2.3) if dz else (up * half * 2.3)
        _wr_tube(bm, at + offset - span / 2, at + offset + span / 2, 0.32, 0.32, 4)
    if lid_up:
        # NO LID, and this is the one thing the redesign's first staged sheet
        # got wrong. A gunport lid belongs to the ship's SIDE and is timber;
        # this object is the CANNON, and it carries one flat brass material,
        # so a lid built here came out as a bright yellow panel the size of a
        # door standing off the hull - reading as a signboard rather than as
        # part of the ship, which is the exact failure the redesign existed to
        # fix. Shrinking it does not help: the defect is the COLOUR, and the
        # colour is not this object's to change (a second material here would
        # break the one-material-per-object rule _wr_finish is built on).
        # Moving the lids into Wrack_Strakes, where they would come out as
        # timber, is the richer fix; it is two edit sites and is left as a
        # note rather than done here.
        #
        # So what stays is the half that is honestly ironwork and honestly
        # brass: the two hinge straps still bolted to the frame's top edge,
        # with the lid long since torn off them. She has been standing on this
        # shoal a long time, and a wreck missing her port lids is the reading
        # the rest of the model already asks for.
        hinge = at + up * half
        for s in (-1, 1):
            root = hinge + side * (s * half * 0.8)
            _wr_tube(bm, root - n * 0.4, root + n * half * 0.45, 0.26, 0.20, 4)


def _wr_corner_gun(name, rng):
    """One corner gun: the piece, its slide, and the sponson deck under it.

    The CASEMATE is not built here - it is timber and this object is brass,
    and a door-sized brass panel beside a gun is the exact failure the port
    lids already taught this section (see `_wr_portframe`). The casemate is
    `Wrack_Sponsons`; this is the ordnance that stands in it.
    """
    bm = bmesh.new()
    breech, muzzle, bore = WR_GUNS[name][0]
    n, length = _wr_gun(bm, breech, muzzle, bore)
    side = Vector((-n.y, n.x, 0.0))
    base = Vector(breech)
    deck = WR_GUN_Z[name] - 1.6
    # A pivot slide rather than a truck carriage: a gun in a casemate trains
    # through its mouth on a racer, and the racer is what says "this thing
    # tracks you" from the drop ring.
    _wr_tube(bm, base - n * 1.6 + Vector((0, 0, -1.6)), base + n * (length * 0.55) + Vector((0, 0, -1.6)),
             1.05, 0.85, 6)
    for s in (-1, 1):
        box(bm, tuple(base + n * 0.6 + side * (s * bore * 1.9) + Vector((0, 0, -0.2))),
            (2.6, 0.5, 2.0), Matrix.Rotation(math.atan2(n.y, n.x), 3, "Z"))
    # The racer arc the carriage runs on, and the trunnion pin.
    for i in range(7):
        a0 = math.radians(-42 + i * 14.0)
        a1 = math.radians(-42 + (i + 1) * 14.0)
        r = 3.4
        p0 = base + (n * math.cos(a0) + side * math.sin(a0)) * r + Vector((0, 0, -2.4))
        p1 = base + (n * math.cos(a1) + side * math.sin(a1)) * r + Vector((0, 0, -2.4))
        _wr_tube(bm, p0, p1, 0.26, 0.26, 5)
    _wr_tube(bm, tuple(base + side * bore * 2.6 + Vector((0, 0, -1.6))),
             tuple(base - side * bore * 2.6 + Vector((0, 0, -1.6))), 0.3, 0.3, 6)
    # Shot garland beside the breech - a corner gun is a crew station.
    for i in range(4):
        ellipsoid(bm, tuple(base - n * 2.6 + side * (-1.9 + i * 1.25) + Vector((0, 0, -1.0 + rng.uniform(-0.1, 0.1)))),
                  (0.42, 0.42, 0.42), subdiv=1)
    return _wr_finish("Wrack_Cannon" + name, bm, WR_BRASS, "M_Wrack_AdmGun")


def build_wr_cannon_bowstbd(rng):
    """CANNON 1 of 4, the starboard bow corner - bearing +30."""
    return _wr_corner_gun("BowStbd", rng)


def build_wr_cannon_bowport(rng):
    """CANNON 2 of 4, the port bow corner - bearing -30."""
    return _wr_corner_gun("BowPort", rng)


def build_wr_cannon_sternstbd(rng):
    """CANNON 3 of 4, the starboard quarter - bearing +150."""
    return _wr_corner_gun("SternStbd", rng)


def build_wr_cannon_sternport(rng):
    """CANNON 4 of 4, the port quarter - bearing -150."""
    return _wr_corner_gun("SternPort", rng)


def _wr_plank_panel(bm, centre, size, yaw, thick_axis, rows=6, skin=0.08):
    """A casemate panel faced with plank strips, at the SAME outer extent.

    There is no boolean operator here, so the grooves are made by laying
    planks on a THINNED CORE rather than by cutting a full-thickness slab:
    core + 2 * skin equals the original thickness exactly, so the plate
    rectangle `_wr_casemate_measure` reads off these verts does not move by a
    thousandth. That is the whole constraint on this pass - the casemate
    window is 22.5..24.0 and knife-edged on projection, and decoration is not
    allowed to shift it. The planks are also inset from every edge, so the
    silhouette is the panel's, not theirs.

    Butts are staggered row to row, because a wall of planks all breaking on
    the same line reads as a printed texture rather than as carpentry - which
    at 58 studs is the entire difference this pass exists to make.
    """
    size = list(size)
    thick = size[thick_axis]
    core = thick - 2.0 * skin
    inner = list(size)
    inner[thick_axis] = core
    box(bm, centre, tuple(inner), yaw)
    long_axis = 1 if thick_axis == 0 else 0
    span = size[2]
    for i in range(rows):
        h = span / rows
        z = centre[2] - span / 2.0 + (i + 0.5) * h
        shrink = 0.34 if i % 2 else 0.0
        plank = [0.0, 0.0, 0.0]
        plank[thick_axis] = skin
        plank[long_axis] = size[long_axis] - 0.16 - shrink
        plank[2] = h - 0.14
        for side in (-1, 1):
            off = [0.0, 0.0, 0.0]
            off[thick_axis] = side * (core + skin) / 2.0
            off[long_axis] = (shrink / 2.0) * (1.0 if i % 4 == 1 else -1.0)
            world = yaw @ Vector(off)
            box(bm, (centre[0] + world.x, centre[1] + world.y, z), tuple(plank), yaw)


def build_wr_sponsons(rng):
    """The four corner CASEMATES: back wall, two cheeks, and the platform.

    ONE object for all four, because they never move independently, and
    timber-coloured because a big box beside a brass gun reads as a signboard
    if it is brass too. One MeshColors row instead of four.

    These are also the collidable occluder's shape - `Wrack_HullCollider`
    carries the same planes - so what the player sees blocking a far gun is
    exactly what stops the shot.
    """
    bm = bmesh.new()
    z0, z1 = WR_CASEMATE_Z
    WR_CASEMATE_MEASURED.clear()
    for name in WR_GUN_ORDER:
        n, u = _wr_gun_axis(name)
        back = n * WR_CASEMATE_R_BACK
        out = n * WR_CASEMATE_R_OUT
        # THE PLATES GO IN A SCRATCH MESH FIRST, so the guard can measure the
        # occluder and nothing else. The platform's knees run inboard to r 7.15
        # and would otherwise read as a back wall half the distance out.
        plate = bmesh.new()
        yaw = Matrix.Rotation(math.radians(WR_GUN_BEARING[name]), 3, "Z")
        mid_z, span_z = (z0 + z1) / 2.0, z1 - z0
        # SOLID PANELS, not a lattice of tubes. The first pass built these as
        # railings and the staged sheet showed the defect immediately: you
        # could see a far gun straight THROUGH its own casemate while the
        # collider stopped your shot on it. A shield you can see through is
        # worse than no shield - it makes the fight look broken rather than
        # hard. The visible mesh and Wrack_HullCollider are now the same
        # shape, which is the whole claim this layout rests on.
        _wr_plank_panel(plate, tuple(back + Vector((0, 0, mid_z))),
                        (0.55, WR_CASEMATE_HW * 2.0, span_z), yaw, 0, rows=6)
        for s_side in (-1, 1):
            centre = back.lerp(out, 0.5) + u * (s_side * WR_CASEMATE_HW)
            _wr_plank_panel(plate, tuple(centre + Vector((0, 0, mid_z))),
                            (WR_CASEMATE_R_OUT - WR_CASEMATE_R_BACK, 0.55, span_z), yaw, 1, rows=6)
        # A capping rail along each cheek's top edge and a lintel over the
        # mouth, so the box reads as built timber rather than as a slab.
        for s_side in (-1, 1):
            _wr_tube(plate, tuple(back + u * (s_side * WR_CASEMATE_HW) + Vector((0, 0, z1))),
                     tuple(out + u * (s_side * WR_CASEMATE_HW) + Vector((0, 0, z1))), 0.42, 0.36, 5)
        _wr_tube(plate, tuple(out - u * WR_CASEMATE_HW + Vector((0, 0, z1))),
                 tuple(out + u * WR_CASEMATE_HW + Vector((0, 0, z1))), 0.42, 0.42, 5)
        WR_CASEMATE_MEASURED[name] = _wr_casemate_measure(name, [tuple(v.co) for v in plate.verts])
        scratch = bpy.data.meshes.new("_casemate")
        plate.to_mesh(scratch)
        plate.free()
        bm.from_mesh(scratch)
        bpy.data.meshes.remove(scratch)
        # the platform the gun stands on, and knees under it
        deck = WR_GUN_Z[name] - 3.2
        for i in range(6):
            t = i / 5.0
            at = back.lerp(out, t)
            _wr_tube(bm, tuple(at - u * WR_CASEMATE_HW + Vector((0, 0, deck))),
                     tuple(at + u * WR_CASEMATE_HW + Vector((0, 0, deck))), 0.42, 0.42, 5)
        for s in (-1, 1):
            _wr_tube(bm, tuple(back + u * (s * WR_CASEMATE_HW * 0.8) + Vector((0, 0, deck))),
                     tuple(back * 0.55 + u * (s * 1.2) + Vector((0, 0, deck - 3.4))), 0.5, 0.36, 5)
    return _wr_finish("Wrack_Sponsons", bm, WR_WALE, "M_Wrack_AdmWale")


def build_wr_hull_collider(rng):
    """THE SHOT BLOCKER - invisible in game, and the reason a far gun is safe.

    `Wrack_Hull` cannot do this job: it is authored as TWO lofted blocks with
    a 12-stud gap amidships, so it is neither closed nor gap-free once the
    shell plates swing. This is one closed loft over the same stations with no
    waist gap and a 0.30 margin, PLUS the four casemate boxes, so the thing
    that stops a shot is the same shape as the thing the player sees.

    It carries no MeshColors row on purpose: the client sets Transparency 1
    and CanQuery/CanCollide true, so its colour never renders.
    """
    bm = bmesh.new()
    rings = []
    x = WR_HULL[0][0] - 0.5
    while x <= WR_HULL[-1][0] + 0.5:
        half, _floor, sheer = _wr_station(x)
        half += 0.30
        top = WR_KEEL_Z + sheer + 0.30
        bottom = WR_KEEL_Z - 0.40
        pts = []
        for i in range(10):
            a = (i / 10.0) * TAU
            pts.append((x, math.cos(a) * half, (top + bottom) / 2 + math.sin(a) * (top - bottom) / 2))
        rings.append(pts)
        x += 1.5
    loft(bm, rings)
    z0, z1 = WR_CASEMATE_Z
    for name in WR_GUN_ORDER:
        n, u = _wr_gun_axis(name)
        mid = n * ((WR_CASEMATE_R_BACK + WR_CASEMATE_R_OUT) / 2.0)
        run = (WR_CASEMATE_R_OUT - WR_CASEMATE_R_BACK) / 2.0
        box(bm, tuple(mid + Vector((0, 0, (z0 + z1) / 2))),
            (run * 2.0, WR_CASEMATE_HW * 2.0, z1 - z0),
            Matrix.Rotation(math.radians(WR_GUN_BEARING[name]), 3, "Z"))
    return _wr_finish("Wrack_HullCollider", bm, WR_TIMBER, "M_Wrack_AdmTimber")


def build_wr_muzzleflare():
    """A MODULE, in the Pyrelisk sense: authored at the origin with +X as the
    bore direction, and placed by the rig at every muzzle in WR_GUNS. Hiding
    the one belonging to a silenced cannon is how a dead gun goes dark
    without a second mesh.

    `Glow` is in the OBJECT name so the emissive marker survives the import.
    """
    bm = bmesh.new()
    _wr_tube(bm, (-0.2, 0, 0), (2.0, 0, 0), 0.52, 0.12, 7)
    ellipsoid(bm, (0.1, 0, 0), (0.6, 0.6, 0.6), subdiv=1)
    for i in range(5):
        angle = (i / 5) * TAU
        spike(
            bm,
            (0.4, math.cos(angle) * 0.36, math.sin(angle) * 0.36),
            (1.5, math.cos(angle) * 1.05, math.sin(angle) * 1.05),
            0.16,
        )
    return _wr_finish("Wrack_MuzzleGlow", bm, WR_FLARE, "M_Wrack_AdmFlare")


# --- spars and rigging ------------------------------------------------------

# The mainmast is stepped just ABAFT the waist on purpose: a spar rooted in
# the shell plates would fly apart when the hold opens. It is also 2.5 studs
# clear of the port cannon at x -11.
WR_MAST_STEP = (-6.5, 0.0, WR_KEEL_Z)
WR_MAST_HEAD = (-6.5, 0.0, 26.5)
WR_YARD = ((-6.5, -13.0, 22.0), (-6.5, 10.5, 22.0))


def build_wr_mast(rng):
    """What is left of her rig: the mainmast standing but snapped off short,
    its yard still crossed and dipping to leeward, and the bowsprit still
    reaching off the beakhead.

    THE MASTHEAD IS DELIBERATELY BELOW THE ADMIRAL'S HAT - 26.5, and its
    splinters stop under 28.3, against a hat that tops out at 29.0.
    On the old careened model the mast was the tallest thing on the boss and
    the first thing the eye found; upright and cut down, the silhouette's
    high point is the man, then his sabre - which is the point of the whole
    redesign.
    """
    bm = bmesh.new()
    _wr_tube(bm, WR_MAST_STEP, WR_MAST_HEAD, 1.9, 1.2, 9)
    # The break: splinters where she went by the board.
    head = Vector(WR_MAST_HEAD)
    for i in range(7):
        angle = (i / 7) * TAU
        spike(
            bm,
            head + Vector((math.cos(angle) * 0.8, math.sin(angle) * 0.8, 0.0)),
            head + Vector((math.cos(angle) * 1.0, math.sin(angle) * 1.0, rng.uniform(0.5, 1.5))),
            0.32,
        )
    # The yard, still crossed, one arm dipping toward the shoal.
    _wr_tube(bm, WR_YARD[0], WR_YARD[1], 0.68, 1.0, 7)
    # A top, and the trestletrees under it.
    box(bm, (-6.5, 0.0, 23.4), (3.8, 5.0, 0.7))
    # The bowsprit off the beakhead, broken past the cap.
    _wr_tube(bm, WR_BOWSPRIT[0], WR_BOWSPRIT[1], 1.2, 0.7, 7)
    tip = Vector(WR_BOWSPRIT[1])
    for i in range(5):
        angle = (i / 5) * TAU
        spike(bm, tip + Vector((math.cos(angle) * 0.45, math.sin(angle) * 0.45, 0.0)), tip + Vector((1.4, 1.0, 0.7)), 0.22)
    # A stump of foremast forward, so the bow is not bare.
    _wr_tube(bm, (11.0, 0.0, _wr_deck(11.0)), (11.0, 0.0, 18.5), 1.1, 0.85, 7)
    return _wr_finish("Wrack_Mast", bm, WR_SPAR, "M_Wrack_AdmSpar")


# THE BOBSTAY'S FOOT. It used to land at (19.0, 0, WR_KEEL_Z + 1.6), which is
# 1.34 studs INSIDE the figurehead's hips - and she detaches, so the rope
# would have been left hanging through the space where her waist was. No
# anchor on the centreline can both clear her and show daylight under the
# bowsprit (the frontier is empty: she occupies exactly the wedge a bobstay
# lives in), so it goes to the STEM HEAD, where gammoning belongs. Clears
# her by 3.38.
WR_BOBSTAY_FOOT = (18.0, 0.0, 13.25)


def build_wr_rigging(rng):
    """Shrouds, stays and tackle, hanging where they fell. This is the piece
    that keeps the plan view from being solid: a lattice over the hull breaks
    the outline into something a raised camera can read depth in.

    Upright, the shrouds go down to BOTH channels rather than only the high
    side, which is the second thing (after the yard) that says at a glance
    that she is standing rather than lying."""
    bm = bmesh.new()
    head = Vector((-6.5, 0.0, 25.6))
    for index in (7, 15):
        anchors = [_wr_skin(x, index, out=1.8) for x in (-10.0, -8.0, -6.0, -4.0)]
        for anchor in anchors:
            _wr_tube(bm, head, anchor, 0.13, 0.18, 4)
        for i in range(6):
            t = 0.2 + i * 0.12
            row = [head.lerp(anchor, t) for anchor in anchors]
            for a, b in zip(row, row[1:]):
                _wr_tube(bm, a, b, 0.09, 0.09, 4)
    # Stays: forward to the bowsprit, aft to the taffrail. The long lines that
    # tie the three silhouette masses into one shape.
    _wr_tube(bm, head, Vector(WR_BOWSPRIT[0]).lerp(Vector(WR_BOWSPRIT[1]), 0.55), 0.16, 0.16, 4)
    _wr_tube(bm, head, Vector((-21.0, 0.0, 13.4)), 0.16, 0.16, 4)
    _wr_tube(bm, Vector(WR_BOWSPRIT[1]), WR_BOBSTAY_FOOT, 0.14, 0.14, 4)
    # Lifts and braces off the yard's arms, and rope simply hanging.
    for end in WR_YARD:
        _wr_tube(bm, head, Vector(end), 0.12, 0.12, 4)
    for _ in range(7):
        t = rng.uniform(0.15, 0.9)
        at = Vector(WR_YARD[0]).lerp(Vector(WR_YARD[1]), t)
        drop = rng.uniform(3.0, 7.0)
        sway = rng.uniform(-1.2, 1.2)
        _wr_tube(bm, at, at + Vector((sway * 0.4, sway, -drop)), 0.11, 0.10, 4)
    return _wr_finish("Wrack_Rigging", bm, WR_ROPE, "M_Wrack_AdmRope")


def build_wr_sail(rng):
    """Rags of canvas still bent to the yard. Pale, so they catch the eye
    against slate timber, and thin, so the silhouette stays open."""
    bm = bmesh.new()
    a, b = Vector(WR_YARD[0]), Vector(WR_YARD[1])
    for i in range(9):
        t = 0.06 + i * 0.10
        at = a.lerp(b, t)
        drop = rng.uniform(2.6, 8.0)
        blade(
            bm,
            at,
            at + Vector((rng.uniform(-1.1, 1.1), rng.uniform(-1.8, 1.8), -drop)),
            rng.uniform(1.5, 3.0),
            rng.uniform(0.4, 1.8),
            0.14,
            roll=rng.uniform(-0.5, 0.5),
        )
    # One larger sheet, half torn away and hanging off the stay.
    blade(bm, (-6.5, -3.0, 20.0), (-6.5, -9.0, 10.0), 4.4, 1.5, 0.16, roll=0.3)
    return _wr_finish("Wrack_Sail", bm, WR_CANVAS, "M_Wrack_AdmCanvas")


# --- the attack pieces ------------------------------------------------------
#
# Three things on this ship MOVE, and none of them is the ship. Wrack is still
# a static gun platform - the redesign's whole point - so every new attack has
# to come from a piece of HIS SHIP coming loose at him, which is the only way
# a bullet-hell boss gains a melee-range threat without taking a step.
#
# EACH PUBLISHES ITS PIVOT AS A CONSTANT, because the Blender object origin is
# consumed by NOBODY: Studio's glTF import gives every MeshPart an origin at
# its own bounding-box centre, and WrackBodyController places each piece by its
# offset from `Wrack_Base`. The shell plates already work this way (`HINGE` in
# the controller, `_wr_hinge` here); these follow them.

WR_FIGUREHEAD_SPINE = (
    (20.2, 0.0, 6.4),    # her hips, bolted into the stem - the mounting point
    (22.4, 0.0, 7.8),    # waist
    (24.4, 0.0, 9.4),    # breast - the lantern-heart is here
    (26.0, 0.0, 10.9),   # shoulders, where the arms sweep back
    (27.2, 0.0, 12.2),   # head
)
WR_FIGUREHEAD_GIRTH = (1.20, 1.08, 1.15, 0.98, 0.85)
WR_FIGUREHEAD_AT = WR_FIGUREHEAD_SPINE[0]


def _wr_fh_axis():
    """(unit launch direction, length) - she leaves along her own spine.

    A figurehead points where the ship was going, so "she comes off the bow"
    and "she flies along her own axis" are one direction, and the client needs
    one number for both.
    """
    a, b = Vector(WR_FIGUREHEAD_SPINE[0]), Vector(WR_FIGUREHEAD_SPINE[-1])
    return (b - a).normalized(), (b - a).length


def build_wr_figurehead(rng):
    """THE LADY BELOW - the figurehead, and the only part of this ship that
    leaves it. She tears off her bolts and flies at the party: a bone-pale
    woman with her drapery streaming behind her, which from 60 studs is a
    comet with a figure in its head.

    SHE STANDS SQUARE ON THE CENTRELINE. An earlier pass had her canted 2.1
    studs to starboard to dodge the old bow chaser; the corner rework took the
    chaser away, and a figurehead out of true on a ship whose bow is otherwise
    symmetrical read as a modelling slip rather than as damage. Square, she is
    also 5.8 studs of vertical rise against 3.9, which is what makes her
    silhouette legible at the range this fight is played at.
    """
    bm = bmesh.new()
    spine = [Vector(p) for p in WR_FIGUREHEAD_SPINE]
    girth = WR_FIGUREHEAD_GIRTH
    forward, _ = _wr_fh_axis()
    up = Vector((-forward.z, 0.0, forward.x))
    side = Vector((0.0, 1.0, 0.0))
    for i in range(len(spine) - 1):
        _wr_tube(bm, spine[i], spine[i + 1], girth[i], girth[i + 1], 9)
    ellipsoid(bm, tuple(spine[4] + forward * 0.10), (0.84, 0.66, 0.78), subdiv=2)
    ellipsoid(bm, tuple(spine[4] + forward * 0.64 - up * 0.24), (0.46, 0.42, 0.36), subdiv=1)
    # THE ARMS, swept back along the hull - what makes the silhouette an
    # arrowhead instead of a cross, and so what makes her read in flight.
    for s in (-1, 1):
        shoulder = spine[3] + side * (s * 0.74)
        elbow = Vector((23.6, s * 2.3, 8.6))
        hand = Vector((20.9, s * 3.8, 6.9))
        _wr_tube(bm, shoulder, elbow, 0.46, 0.34, 6)
        _wr_tube(bm, elbow, hand, 0.34, 0.22, 6)
        ellipsoid(bm, tuple(hand), (0.30, 0.26, 0.24), subdiv=1)
    # THE HAIR, streaming aft - the near half of the comet tail, and the part
    # that reads at 60 studs because it is beside the one bright thing on her.
    for i in range(7):
        t = (i / 6.0) - 0.5
        root = spine[4] + side * (t * 0.70) + up * 0.44
        tip = Vector((24.5 + rng.uniform(-0.5, 0.5), t * 3.1 + rng.uniform(-0.3, 0.3),
                      10.0 + rng.uniform(-0.5, 0.4)))
        _wr_tube(bm, root, tip, 0.26, 0.10, 5)
    # THE DRAPERY - the far half of the tail. Blades, not tubes: flat cloth
    # catches light on one face and goes dark on the next, which is what sells
    # motion on a piece with no animation of its own. It stops at x 17.2
    # because the topside strake's gunport frame is at 17.8, and cloth
    # threaded through a gunport is the kind of thing only the shipped render
    # ever shows you.
    for i in range(9):
        t = (i / 8.0) - 0.5
        root = spine[0].lerp(spine[1], 0.35) + side * (t * 1.5)
        tip = Vector((17.2 + rng.uniform(0.0, 1.4), t * 8.8 + rng.uniform(-0.4, 0.4),
                      4.4 + rng.uniform(-0.4, 0.9)))
        blade(bm, tuple(root), tuple(tip), rng.uniform(1.3, 2.1), rng.uniform(0.5, 1.1), 0.16,
              roll=rng.uniform(-0.6, 0.6))
    for s in (-1, 1):
        blade(bm, tuple(spine[0] + side * (s * 0.9)), (16.4, s * 5.6, 5.0), 1.4, 0.3, 0.14, roll=s * 0.4)
    return _wr_finish("Wrack_Figurehead", bm, WR_LADY, "M_Wrack_AdmLady")


def build_wr_figurehead_glow():
    """Her eyes and the lantern-heart at her breast.

    ONE object for both, reusing `M_Wrack_AdmLamp` - the heart-lantern's own
    amber. She burns with the same fire that burns in the hold, which is the
    reading the fight wants: she is not a separate ghost, she is a piece of
    HIM. It also costs no new material and one MeshColors row instead of two.
    `Glow` rides the OBJECT name, the only place the marker survives import.
    """
    bm = bmesh.new()
    spine = [Vector(p) for p in WR_FIGUREHEAD_SPINE]
    forward, _ = _wr_fh_axis()
    up = Vector((-forward.z, 0.0, forward.x))
    ellipsoid(bm, tuple(spine[3] + up * 1.05 - forward * 0.5), (0.54, 0.48, 0.52), subdiv=2)
    _wr_tube(bm, tuple(spine[3] + up * 0.74 - forward * 0.5), tuple(spine[2] + up * 0.52), 0.20, 0.14, 5)
    for s in (-1, 1):
        ellipsoid(bm, tuple(spine[4] + forward * 0.64 + Vector((0.0, s * 0.28, 0.0)) + up * 0.10),
                  (0.17, 0.15, 0.19), subdiv=1)
    return _wr_finish("Wrack_FigureheadGlow", bm, WR_LAMP, "M_Wrack_AdmLamp")


# THE MAIN BOOM - a 30-stud spar that swings out and comes down like a scythe.
# The one attack that threatens the ground a melee player is standing on.
#
# WHERE IT IS STEPPED, AND WHY IT IS NOT ON A MAST. `_wr_boom_envelope` solves,
# for every bearing, the lowest angle a 30-stud spar can be depressed to while
# staying clear of everything already on this ship. Against a MAINMAST pivot at
# four heights (13.6 / 15.4 / 18.2 / 20.6) it returns the same answer at all
# four: there is NO bearing at which the outer end can get below z 8. The sheer
# rail is the fence - a spar pivoting on the centreline must clear a rail 6.3
# out and 11.5 up before it is over open sand, so depressing it drives the
# spar's middle into the ship's own side. A boom on the mast can only wave.
#
# Pivoting it on the RAIL removes the fence, because the spar is outboard from
# its first stud. It is stepped ABAFT the waist, the same rule the mainmast
# obeys: a spar socketed in a shell plate flies apart when the hold opens.
WR_BOOM_PIVOT = (-6.50, 5.24, 12.57)
WR_BOOM_LENGTH = 30.0
WR_BOOM_ROOT = 2.2
WR_BOOM_R = (0.86, 0.48)
# (yaw, peak) in degrees. Yaw is plan angle from +X toward +Y; peak is
# elevation. STOWED it is cocked up over the starboard bow - which is where
# the free lane is, and which telegraphs the swing; SWEPT it has come round to
# the beam and down to sand level.
WR_BOOM_STOWED = (62.0, 15.0)
WR_BOOM_SWEPT = (108.0, -24.0)
WR_BOOM_TACKLE_AT = 0.72


def _wr_boom_dir(yaw, peak):
    p, y = math.radians(peak), math.radians(yaw)
    return Vector((math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), math.sin(p)))


def _wr_boom_at(yaw, peak, along):
    return Vector(WR_BOOM_PIVOT) + _wr_boom_dir(yaw, peak) * along


def build_wr_boom(rng):
    """The main boom, authored in its STOWED pose - posed rather than at the
    origin for the same reason the shell plates are: `_place_wrack` puts every
    piece down at identity, so the docked model must be right with no
    transform, and the arc is published as constants."""
    bm = bmesh.new()
    yaw, peak = WR_BOOM_STOWED
    n = _wr_boom_dir(yaw, peak)
    pivot = Vector(WR_BOOM_PIVOT)
    side = n.cross(Vector((0.0, 0.0, 1.0))).normalized()
    up = side.cross(n).normalized()
    heel = pivot + n * WR_BOOM_ROOT
    head = pivot + n * WR_BOOM_LENGTH
    for t0, t1, r0, r1 in ((0.0, 0.34, WR_BOOM_R[0], 0.76), (0.34, 0.70, 0.76, 0.62),
                           (0.70, 1.0, 0.62, WR_BOOM_R[1])):
        _wr_tube(bm, tuple(heel.lerp(head, t0)), tuple(heel.lerp(head, t1)), r0, r1, 8)
    # The jaws that straddle the socket in the rail, and the collar over the
    # pin - the half that says the spar is RIGGED to her, not leaning on her.
    for s in (-1, 1):
        _wr_tube(bm, tuple(heel + side * (s * 0.30)), tuple(pivot + side * (s * 0.86) - n * 0.5), 0.42, 0.30, 5)
    _wr_tube(bm, tuple(heel - n * 0.35), tuple(heel + n * 1.10), 1.05, 0.98, 8)
    _wr_tube(bm, tuple(pivot - Vector((0.0, 0.0, 1.1))), tuple(pivot + Vector((0.0, 0.0, 0.9))), 0.44, 0.44, 6)
    for t in (0.14, 0.30, 0.46, 0.62, 0.80, 0.92):
        r = WR_BOOM_R[0] + (WR_BOOM_R[1] - WR_BOOM_R[0]) * t
        at = heel.lerp(head, t)
        _wr_tube(bm, tuple(at - n * 0.16), tuple(at + n * 0.16), r + 0.14, r + 0.14, 8)
        if t in (0.30, 0.62):
            for s in (-1, 1):
                box(bm, tuple(at + side * (s * (r + 0.28)) - up * 0.1), (1.1, 0.5, 0.34),
                    Matrix.Rotation(math.atan2(n.y, n.x), 3, "Z"))
    _wr_tube(bm, tuple(head - n * 1.2 - side * 0.5), tuple(head - n * 1.2 + side * 0.5), 0.34, 0.34, 8)
    for i in range(5):
        a = (i / 5) * TAU
        spike(bm, tuple(head + side * (math.cos(a) * 0.34) + up * (math.sin(a) * 0.34)),
              tuple(head + n * rng.uniform(0.7, 1.7) + side * (math.cos(a) * 0.5) + up * (math.sin(a) * 0.5)), 0.17)
    return _wr_finish("Wrack_Boom", bm, WR_SPAR, "M_Wrack_AdmSpar")


def build_wr_boom_tackle(rng):
    """The block and tackle at the boom's outer third - THE SNAP TARGET.

    It is BRASS, and that is a legibility call rather than a joiner's one:
    every shootable thing on this boss is brass (the one saturated warm on a
    cold ship), so brass reads as "shoot this" from the drop ring with no
    tutorial line, and it pops off a slate spar besides. Built 3.6 studs tall
    because stowed it hangs ~64 studs from the r 88 ring, where 3.6 subtends a
    comfortable angle and 1.5 would not.
    """
    bm = bmesh.new()
    yaw, peak = WR_BOOM_STOWED
    n = _wr_boom_dir(yaw, peak)
    side = n.cross(Vector((0.0, 0.0, 1.0))).normalized()
    on_spar = _wr_boom_at(yaw, peak, WR_BOOM_LENGTH * WR_BOOM_TACKLE_AT)
    spar_r = WR_BOOM_R[0] + (WR_BOOM_R[1] - WR_BOOM_R[0]) * WR_BOOM_TACKLE_AT
    top = on_spar - Vector((0.0, 0.0, spar_r - 0.1))
    _wr_tube(bm, tuple(on_spar - side * 0.62), tuple(on_spar + side * 0.62), spar_r + 0.16, spar_r + 0.16, 8)
    _wr_tube(bm, tuple(top), tuple(top - Vector((0.0, 0.0, 0.9))), 0.20, 0.24, 6)
    shell = top - Vector((0.0, 0.0, 1.8))
    box(bm, tuple(shell), (1.5, 0.95, 1.9))
    for s in (-1, 1):
        c = shell + side * (s * 0.30)
        _wr_tube(bm, tuple(c - side * 0.16), tuple(c + side * 0.16), 0.62, 0.62, 10)
    _wr_tube(bm, tuple(shell - side * 0.75), tuple(shell + side * 0.75), 0.16, 0.16, 6)
    for dz in (-1, 1):
        _wr_tube(bm, tuple(shell + Vector((0.0, 0.0, dz * 0.98)) - side * 0.55),
                 tuple(shell + Vector((0.0, 0.0, dz * 0.98)) + side * 0.55), 0.20, 0.20, 6)
    lower = shell - Vector((0.0, 0.0, 2.3))
    box(bm, tuple(lower), (1.1, 0.8, 1.35))
    _wr_tube(bm, tuple(lower + side * 0.20), tuple(lower - side * 0.20), 0.46, 0.46, 9)
    for i in range(5):
        a = math.pi * (0.2 + i * 0.18)
        _wr_tube(bm, tuple(lower + Vector((math.sin(a) * 0.5, 0.0, -0.8 - math.cos(a) * 0.5))),
                 tuple(lower + Vector((math.sin(a + 0.2) * 0.5, 0.0, -0.8 - math.cos(a + 0.2) * 0.5))), 0.17, 0.17, 5)
    for s in (-1, 1):
        _wr_tube(bm, tuple(shell + side * (s * 0.5) + Vector((0.0, 0.0, 0.9))),
                 tuple(lower + side * (s * 0.42) + Vector((0.0, 0.0, 0.6))), 0.11, 0.11, 4)
    _wr_tube(bm, tuple(shell + Vector((0.0, 0.0, 0.9))),
             tuple(_wr_boom_at(yaw, peak, WR_BOOM_LENGTH * WR_BOOM_TACKLE_AT - 4.4) - Vector((0.0, 0.0, spar_r))),
             0.12, 0.12, 4)
    return _wr_finish("Wrack_BoomTackle", bm, WR_BRASS, "M_Wrack_AdmGun")


# THE BILGE VENTS - three grated hatches the client pops open, and the third
# attack: what is burning in her hold comes UP through them.
#
# THE AXIS IS PER LID AND THE SIGN IS MEASURED. Hatch1/2 hinge about boss-local
# Y, Hatch3 about boss-local X, so a client posing all three about one axis
# swings two of them sideways out of the deck. Worse, the SENSE of each axis
# was arbitrary until it was checked: rotating each lid's hinge-to-free-edge
# vector by WR_HATCH_OPEN_DEG about the published axis and reading the sign of
# the result is the only thing that distinguishes "opens" from "closes into the
# planking". `_wr_assert_hatch_rise` does exactly that, on every build.
#
# (name, x, y, fore-and-aft length, athwartships width, hinge edge)
#   "aft"     - hinged on the AFT edge, swinging open FORWARD, away from the
#               Admiral at the stern so the lid never crosses him.
#   "inboard" - hinged inboard, swinging open OUTBOARD toward the rail, the
#               only direction with room at that station.
WR_HATCHES = (
    ("Wrack_Hatch1", -6.0, -3.2, 2.8, 1.8, "aft"),
    ("Wrack_Hatch2", -9.0, -3.4, 2.4, 1.8, "aft"),
    ("Wrack_Hatch3", -10.0, 3.8, 2.4, 1.8, "inboard"),
)
WR_HATCH_OPEN_DEG = 74.0


def _wr_hatch_hinge(entry):
    """(hinge point, hinge axis) in BLENDER space, signed so that a POSITIVE
    turn about the axis lifts the lid. The sign is asserted, not asserted-in-
    a-comment: see `_wr_assert_hatch_rise`."""
    _name, x, y, lx, ly, kind = entry
    z = _wr_deck_at(x, y)
    if kind == "aft":
        return Vector((x - lx / 2.0, y, z)), Vector((0.0, -1.0, 0.0))
    inboard = math.copysign(abs(y) - ly / 2.0, y)
    return Vector((x, inboard, z)), Vector((1.0, 0.0, 0.0))


def _wr_hatch(entry, rng):
    """One grated hatch: a kerbed lid with an iron grating in it.

    THE KERB RIDES THE LID, not the deck. A coaming built into Wrack_Strakes
    would be the joiner's answer, but it leaves the ember bed squeezed into the
    0.2 studs between a flush grating and the deck skin, where nothing can see
    it. On the lid, the grating stands 0.45 clear of the bed - so the fire
    glimmers through the bars while the hatch is SHUT and blazes when it pops.
    """
    name, x, y, lx, ly, _kind = entry
    bm = bmesh.new()
    z = _wr_deck_at(x, y)
    hx, hy = lx / 2.0, ly / 2.0
    for dx in (-1, 1):
        box(bm, (x + dx * hx, y, z + 0.24), (0.34, ly + 0.68, 0.48))
    for dy in (-1, 1):
        box(bm, (x, y + dy * hy, z + 0.24), (lx - 0.34, 0.34, 0.48))
    for i in range(max(int(lx / 0.62), 3)):
        bx = x - hx + (i + 0.5) * (lx / max(int(lx / 0.62), 3))
        box(bm, (bx, y, z + 0.55), (0.20, ly * 2 - 0.2, 0.17))
    for i in range(max(int(ly / 0.62), 3)):
        by = y - hy + (i + 0.5) * (ly / max(int(ly / 0.62), 3))
        box(bm, (x, by, z + 0.62), (lx - 0.3, 0.18, 0.15))
    hinge, axis = _wr_hatch_hinge(entry)
    across = Vector((abs(axis.x), abs(axis.y), 0.0))
    for s in (-1, 1):
        root = hinge + across * (s * (hy if axis.y else hx) * 0.55)
        _wr_tube(bm, tuple(root + Vector((0.0, 0.0, 0.12))), tuple(root + Vector((0.0, 0.0, 0.5))), 0.22, 0.18, 6)
        inward = (Vector((x, y, z + 0.45)) - hinge).normalized()
        _wr_tube(bm, tuple(root + Vector((0.0, 0.0, 0.45))),
                 tuple(root + inward * ((lx if axis.y else ly) * 0.55) + Vector((0.0, 0.0, 0.45))), 0.17, 0.13, 5)
    free = Vector((x, y, z)) + (Vector((x, y, z)) - hinge)
    _wr_tube(bm, tuple(free + Vector((0.0, 0.0, 0.5))), tuple(free + Vector((0.0, 0.0, 0.95))), 0.13, 0.13, 5)
    ellipsoid(bm, tuple(free + Vector((0.0, 0.0, 1.05))), (0.34, 0.34, 0.12), subdiv=1)
    for _ in range(2):
        box(bm, (x + rng.uniform(-hx * 0.7, hx * 0.7), y + rng.uniform(-hy * 0.5, hy * 0.5), z + 0.70),
            (0.6, 0.5, 0.16), Matrix.Rotation(rng.uniform(-0.35, 0.35), 3, "Y"))
    return _wr_finish(name, bm, WR_KEELWOOD, "M_Wrack_AdmKeel")


def build_wr_hatch1(rng):
    return _wr_hatch(WR_HATCHES[0], rng)


def build_wr_hatch2(rng):
    return _wr_hatch(WR_HATCHES[1], rng)


def build_wr_hatch3(rng):
    return _wr_hatch(WR_HATCHES[2], rng)


def build_wr_hatch_glow(rng):
    """ONE object carrying all three ember beds, and the reason is what
    CONSUMES them, not economy for its own sake.

    The tempting alternative is one glow per lid, on the argument that a glow
    should travel with its piece. It does not belong to the lid: the fire is in
    the HOLD, and the lid is what stops you seeing it. A bed riding the lid
    would swing up into the air when the hatch popped, which is backwards.
    Once they do not move with the lids, three objects buy nothing and cost
    three MeshColors rows of identical amber, three PIECES entries, three
    AUTHORED boxes and three pairings for the client to keep straight.
    """
    bm = bmesh.new()
    for entry in WR_HATCHES:
        _name, x, y, lx, ly, _kind = entry
        z = _wr_deck_at(x, y) + 0.14
        box(bm, (x, y, z), (lx - 0.8, ly - 0.8, 0.12))
        for _ in range(9):
            r = rng.uniform(0.10, 0.23)
            ellipsoid(bm, (x + rng.uniform(-lx * 0.34, lx * 0.34), y + rng.uniform(-ly * 0.30, ly * 0.30),
                           z + rng.uniform(0.02, 0.20)), (r, r * rng.uniform(0.7, 1.2), r * 0.7), subdiv=1)
    return _wr_finish("Wrack_HatchGlow", bm, WR_LAMP, "M_Wrack_AdmLamp")


# THE DUEL KIT. Phase 3 takes the Admiral OFF his ship and onto the sand, so
# he needs one thing his ship cannot hand him.
WR_PISTOL_AT = (-25.4, 8.6, 33.0)   # admiral space: through the sash, left hip


def build_wr_pistol(rng):
    """A flintlock through the Admiral's sash - the duel's second weapon.

    LEFT HIP, because the sabre is in his right hand: a pistol butt on the
    same side as the sword is the one arrangement no portrait of a sea officer
    has ever shown, and the duel camera squares him up so the viewer sees it.
    Authored in ADMIRAL space and seated by the same single matrix as the rest
    of him, so it scales and lands with the man rather than beside him.
    """
    bm = bmesh.new()
    at = Vector(WR_PISTOL_AT)
    fwd = Vector((0.86, 0.0, 0.51))     # butt down and aft, muzzle up and fore
    side = Vector((0.0, 1.0, 0.0))
    _wr_tube(bm, tuple(at + fwd * 1.1), tuple(at + fwd * 5.2), 0.46, 0.38, 7)   # the barrel
    _wr_tube(bm, tuple(at + fwd * 5.2), tuple(at + fwd * 5.6), 0.52, 0.46, 7)   # the muzzle band
    box(bm, tuple(at + fwd * 1.6), (2.6, 1.0, 1.1), Matrix.Rotation(math.radians(31), 3, "Y"))
    # The butt, curling down and back, and the lock plate on the near cheek.
    _wr_tube(bm, tuple(at - fwd * 0.4), tuple(at - fwd * 2.6 - Vector((0.0, 0.0, 1.5))), 0.62, 0.86, 7)
    ellipsoid(bm, tuple(at - fwd * 2.9 - Vector((0.0, 0.0, 1.8))), (0.78, 0.62, 0.66), subdiv=1)
    box(bm, tuple(at + fwd * 0.9 + side * 0.62), (1.5, 0.22, 1.0), Matrix.Rotation(math.radians(31), 3, "Y"))
    # The cock and frizzen, which are the whole silhouette of a flintlock.
    _wr_tube(bm, tuple(at + fwd * 0.7 + side * 0.5 + Vector((0.0, 0.0, 0.5))),
             tuple(at + fwd * 0.2 + side * 0.5 + Vector((0.0, 0.0, 1.5))), 0.22, 0.16, 5)
    _wr_tube(bm, tuple(at + fwd * 1.5 + side * 0.5 + Vector((0.0, 0.0, 0.5))),
             tuple(at + fwd * 1.8 + side * 0.5 + Vector((0.0, 0.0, 1.4))), 0.20, 0.14, 5)
    # The trigger guard.
    for i in range(4):
        a0 = math.pi * (0.15 + i * 0.22)
        a1 = math.pi * (0.15 + (i + 1) * 0.22)
        _wr_tube(bm, tuple(at + fwd * (0.4 + math.cos(a0) * 0.5) - Vector((0.0, 0.0, 0.7 + math.sin(a0) * 0.5))),
                 tuple(at + fwd * (0.4 + math.cos(a1) * 0.5) - Vector((0.0, 0.0, 0.7 + math.sin(a1) * 0.5))),
                 0.13, 0.13, 4)
    _wr_admiral(bm)
    return _wr_finish("Wrack_Pistol", bm, WR_STEEL, "M_Wrack_AdmSteel")


# --- measuring the new pieces against the old ones ---------------------------
#
# Everything the three attack pieces and the four casemates claim is checked
# HERE, at build time, against the geometry that was actually generated. This
# instrument found, in order: a boom on the mainmast that can never reach the
# ground at any bearing or height; a figurehead through the bow chaser; a
# figurehead through the bobstay; two hatches buried in the Admiral's own
# footprint; two hatch axes that would have swung their lids into the deck;
# and three separate ways a player could shoot a far gun through the ship.
#
# WHAT IT KNOWS. `_wr_obstacles` derives from the constants wherever the ship
# has them - WR_GUNS, WR_BOWSPRIT, WR_MAST_*, WR_YARD, WR_COAMINGS, WR_BITTS,
# _wr_skin, _wr_deck - so moving a cannon moves the check with it. The few
# things that exist only as literals inside a builder are restated, and that
# is a second place remembering a first; it is written down rather than
# hidden, and the assert is what tells you if you moved one and not the other.


def _wr_gap(a, b, p, q):
    """Closest distance between segment ab and segment pq."""
    a, b, p, q = Vector(a), Vector(b), Vector(p), Vector(q)
    d1, d2, r = b - a, q - p, a - p
    A, E = d1.dot(d1), d2.dot(d2)
    F, B, C = d2.dot(r), d1.dot(d2), d1.dot(r)
    denom = A * E - B * B
    s = 0.0 if denom < 1e-9 else max(0.0, min(1.0, (B * F - C * E) / denom))
    t = max(0.0, min(1.0, (B * s + F) / E)) if E > 1e-9 else 0.0
    s = max(0.0, min(1.0, (B * t - C) / A)) if A > 1e-9 else 0.0
    return ((a + d1 * s) - (p + d2 * t)).length


def _wr_obstacles():
    """(label, point, point, radius) for everything a swinging piece can hit."""
    obs = []
    for name, guns in WR_GUNS.items():
        for breech, muzzle, bore in guns:
            obs.append(("cannon " + name, breech, muzzle, bore * 2.2))
    obs.append(("bowsprit", WR_BOWSPRIT[0], WR_BOWSPRIT[1], 1.2))
    obs.append(("mainmast", WR_MAST_STEP, WR_MAST_HEAD, 1.9))
    obs.append(("maintop", (-6.5, 0.0, 22.9), (-6.5, 0.0, 24.1), 5.0))
    obs.append(("yard", WR_YARD[0], WR_YARD[1], 1.0))
    obs.append(("foremast", (11.0, 0.0, _wr_deck(11.0)), (11.0, 0.0, 18.5), 1.1))
    head = (-6.5, 0.0, 25.6)
    for index in (7, 15):
        for x in (-10.0, -8.0, -6.0, -4.0):
            obs.append(("shrouds", head, _wr_skin(x, index, out=1.8), 0.18))
    obs.append(("forestay", head, Vector(WR_BOWSPRIT[0]).lerp(Vector(WR_BOWSPRIT[1]), 0.55), 0.16))
    obs.append(("backstay", head, (-21.0, 0.0, 13.4), 0.16))
    obs.append(("bobstay", WR_BOWSPRIT[1], WR_BOBSTAY_FOOT, 0.14))
    for index in (3, 7):
        x = WR_HULL[0][0]
        while x < WR_HULL[-1][0] - 1.0:
            obs.append(("sheer rail", _wr_skin(x, index), _wr_skin(x + 1.0, index), 0.5))
            x += 1.0
    obs.append(("the Admiral", WR_ADM_AT, (-14.9, 1.1, 29.0), 3.4))
    for x, run, wide in WR_COAMINGS:
        obs.append(("coaming", (x - run, 0.0, _wr_deck(x) + 1.05), (x + run, 0.0, _wr_deck(x) + 1.05), wide + 0.4))
    obs.append(("capstan", (-9.8, 0.0, _wr_deck(-9.8)), (-9.8, 0.0, _wr_deck(-9.8) + 2.4), 1.6))
    obs.append(("bitts", (-8.5, -2.0, _wr_deck(-8.5)), (-8.5, 2.0, _wr_deck(-8.5) + 1.8), 0.8))
    obs.append(("sail sheet", (-6.5, -3.0, 20.0), (-6.5, -9.0, 10.0), 2.4))
    z0, z1 = WR_CASEMATE_Z
    for name in WR_GUN_ORDER:
        n, u = _wr_gun_axis(name)
        for s in (-1, 1):
            for zz in (z0, z1):
                obs.append(("casemate " + name,
                            tuple(n * WR_CASEMATE_R_BACK + u * (s * WR_CASEMATE_HW) + Vector((0, 0, zz))),
                            tuple(n * WR_CASEMATE_R_OUT + u * (s * WR_CASEMATE_HW) + Vector((0, 0, zz))), 0.36))
    return obs


def _wr_clearance(segments, ignore=(), obstacles=None):
    """The worst (gap, label) between a piece's segments and the ship."""
    worst, who = 1e9, "-"
    for label, p, q, r in (obstacles if obstacles is not None else _wr_obstacles()):
        if label in ignore:
            continue
        for a, b, rr in segments:
            gap = _wr_gap(a, b, p, q) - r - rr
            if gap < worst:
                worst, who = gap, label
    return worst, who


def _wr_boom_segments(yaw, peak):
    return [(_wr_boom_at(yaw, peak, WR_BOOM_ROOT), _wr_boom_at(yaw, peak, WR_BOOM_LENGTH), WR_BOOM_R[0])]


def _wr_boom_envelope(step=5.0, margin=0.40):
    """For every 5 degrees of yaw, the LOWEST peak that stays `margin` clear.

    This is the boom's whole contract with the ship, and it is what the client
    cannot be expected to rederive: an animator who sweeps the spar without it
    drives 30 studs of timber through the sheer rail, and the render looks
    almost right. Printed on the HANDOFF in the ROBLOX convention.
    """
    obstacles = _wr_obstacles()
    out = []
    lo_yaw = min(WR_BOOM_STOWED[0], WR_BOOM_SWEPT[0]) - 10.0
    hi_yaw = max(WR_BOOM_STOWED[0], WR_BOOM_SWEPT[0]) + 10.0
    yaw = lo_yaw
    while yaw <= hi_yaw + 1e-6:
        low = None
        for j in range(121):
            peak = 30.0 - j * 0.5
            gap, _who = _wr_clearance(_wr_boom_segments(yaw, peak), obstacles=obstacles)
            if gap < margin:
                low = peak + 0.5 if j else None
                break
        else:
            low = -30.0
        out.append((yaw, low))
        yaw += step
    return out


def _wr_casemate_measure(name, verts):
    """(back r, out r, cheek half-width, z0, z1) of a BUILT casemate.

    Measured by projecting the object's own vertices onto the gun's bearing,
    NOT read back off the constants that generated them. A constant tells you
    what was intended; a vertex tells you what was exported.
    """
    n, u = _wr_gun_axis(name)
    rs = [v[0] * n.x + v[1] * n.y for v in verts]
    us = [abs(v[0] * u.x + v[1] * u.y) for v in verts]
    zs = [v[2] for v in verts]
    return min(rs), max(rs), max(us), min(zs), max(zs)


def _wr_capture_points(name, radius, grid=5):
    """The player's shot is a SPHERE about the mount, not a ray at the barrel.

    `Creatures.items.wrack_battery.shotRadius` is a proximity capture, so the
    hittable volume is a ball centred on the mount. Sampling the BARREL
    instead - which an earlier pass did - reports a gun shootable whenever any
    part of its mesh peeks past a cheek, and the muzzle stands 0.5 studs proud
    of the mouth, so it reported "always shootable" for free.
    """
    n, u = _wr_gun_axis(name)
    centre = n * WR_GUN_R + Vector((0.0, 0.0, WR_GUN_Z[name]))
    pts = []
    for i in range(grid):
        for j in range(grid):
            for k in range(grid):
                a = (i / (grid - 1.0) - 0.5) * 2 * radius
                b = (j / (grid - 1.0) - 0.5) * 2 * radius
                c = (k / (grid - 1.0) - 0.5) * 2 * radius
                if a * a + b * b + c * c > radius * radius:
                    continue
                pts.append(tuple(centre + n * a + u * b + Vector((0.0, 0.0, c))))
    return pts


def _wr_occluder(measured):
    """The collidable occluder, rebuilt from what was actually generated."""
    plates = []
    for name, (back_r, out_r, hw, z0, z1) in measured.items():
        n, u = _wr_gun_axis(name)
        plates.append((tuple(n * back_r), tuple(n), tuple(u), hw, z0, z1))
        mid, run = (back_r + out_r) / 2.0, (out_r - back_r) / 2.0
        for s in (-1, 1):
            plates.append((tuple(n * mid + u * (s * hw)), tuple(u), tuple(n), run, z0, z1))
    return plates


def _wr_ray_blocked(a, b, plates):
    for c, nrm, ax, ext, z0, z1 in plates:
        da = sum((a[i] - c[i]) * nrm[i] for i in range(3))
        db = sum((b[i] - c[i]) * nrm[i] for i in range(3))
        if (da > 0) == (db > 0):
            continue
        t = da / (da - db)
        p = tuple(a[i] + (b[i] - a[i]) * t for i in range(3))
        if abs(sum((p[i] - c[i]) * ax[i] for i in range(3))) <= ext and z0 <= p[2] <= z1:
            return True
    if abs(b[0] - a[0]) < 1e-6:
        return False
    t0 = (WR_HULL[0][0] - 0.5 - a[0]) / (b[0] - a[0])
    t1 = (WR_HULL[-1][0] + 0.5 - a[0]) / (b[0] - a[0])
    lo, hi = max(0.0, min(t0, t1)), min(1.0, max(t0, t1))
    if lo >= hi:
        return False
    for i in range(27):
        t = lo + (hi - lo) * i / 26.0
        p = tuple(a[j] + (b[j] - a[j]) * t for j in range(3))
        half, _f, sheer = _wr_station(p[0])
        if abs(p[1]) <= half + 0.30 and (WR_KEEL_Z - 0.4) <= p[2] <= (WR_KEEL_Z + sheer + 0.30):
            return True
    return False


def _wr_sight_histogram(plates, eye_z, radius, bearings=72):
    """(histogram of shootable-gun counts, times the NEAREST gun was eaten)."""
    hist, eaten = {}, 0
    for i in range(bearings):
        deg = i * 360.0 / bearings
        th = math.radians(deg)
        for r in WR_SIGHT_RINGS:
            eye = (r * math.cos(th), r * math.sin(th), eye_z)
            live = [n for n in WR_GUN_ORDER
                    if any(not _wr_ray_blocked(eye, p, plates) for p in _wr_capture_points(n, radius))]
            hist[len(live)] = hist.get(len(live), 0) + 1
            near = min(WR_GUN_ORDER, key=lambda g: abs(((WR_GUN_BEARING[g] - deg + 180) % 360) - 180))
            if near not in live:
                eaten += 1
    return hist, eaten


def _wr_assert_sponsons(measured):
    """Abort the export if the built casemates left the window, or if the HARD
    tier no longer holds against the geometry that was actually made."""
    for name in WR_GUN_ORDER:
        back_r, out_r, hw, z0, z1 = measured[name]
        for label, value, (lo, hi) in (("back radius", back_r, WR_CASEMATE_WINDOW["back_r"]),
                                       ("cheek half-width", hw, WR_CASEMATE_WINDOW["cheek_hw"]),
                                       ("cheek projection", out_r, WR_CASEMATE_WINDOW["out_r"])):
            # THE MEASUREMENT IS OF THE PLATE'S OUTER SURFACE, which stands
            # one tube radius (<= 0.36) proud of the centreline the search
            # solved on - so the tolerance is 0.5, not zero. It is still far
            # tighter than the failure it exists to catch: the projection
            # breaks the property at +-2 studs, and both breaks are silent.
            assert lo - 0.5 <= value <= hi + 0.5, (
                "SPONSON WINDOW: %s's %s measured %.2f, outside the %.1f..%.1f that was solved for. "
                "Projection 21 leaks a third gun on 44 of 144 samples; 25 blinds 2 and eats 2. "
                "Fix the geometry or re-run the search - do NOT widen this bound." % (name, label, value, lo, hi))
        assert z1 >= WR_CASEMATE_Z[1] - 0.2, (
            "SPONSON WINDOW: %s's casemate tops out at z %.2f. The capture sphere reaches z %.2f, so a "
            "lower plate lets a third gun be shot straight over its own casemate." % (name, z1, WR_GUN_Z[name] + WR_BATTERY_SHOT_RADIUS))
    plates = _wr_occluder(measured)
    shot, eaten = _wr_sight_histogram(plates, WR_SHOT_Z, WR_BATTERY_SHOT_RADIUS)
    bad = shot.get(3, 0) + shot.get(4, 0)
    assert bad == 0, (
        "SPONSON HARD TIER: %d of %d shot-origin samples can hit THREE OR MORE guns - the player can "
        "shoot through the ship. Histogram %s" % (bad, sum(shot.values()), dict(sorted(shot.items()))))
    assert shot.get(0, 0) == 0, (
        "SPONSON HARD TIER: %d samples can hit NO gun - the casemates have grown over their own muzzles. "
        "Histogram %s" % (shot.get(0, 0), dict(sorted(shot.items()))))
    assert eaten == 0, (
        "SPONSON HARD TIER: the NEAREST gun's ray is eaten on %d samples - the player is aiming at a gun "
        "their shot cannot reach." % eaten)
    eye, _ = _wr_sight_histogram(plates, WR_EYE_Z, WR_BATTERY_SHOT_RADIUS)
    return shot, eye


def _wr_assert_hatch_rise():
    """Every lid must OPEN. A positive turn about each published axis has to
    lift the free edge; swung the other way it closes into the planking.

    This is the check SHELL_SWING's own comment records having had to
    re-derive, and the one that caught two of these three axes pointing the
    wrong way: the axis VECTOR was converted correctly from Blender, but the
    Blender axis's SENSE had never been checked against the geometry.
    """
    for entry in WR_HATCHES:
        name, x, y, _lx, _ly, _kind = entry
        hinge, axis = _wr_hatch_hinge(entry)
        free = Vector((x, y, _wr_deck_at(x, y))) + (Vector((x, y, _wr_deck_at(x, y))) - hinge)
        v = free - hinge
        turned = Matrix.Rotation(math.radians(WR_HATCH_OPEN_DEG), 4, axis) @ v
        assert turned.z > 0.3, (
            "HATCH SIGN: %s turned +%.0f about its stored axis %s drops its free edge %.2f studs - it "
            "opens INTO the deck. Flip the axis." % (name, WR_HATCH_OPEN_DEG, tuple(axis), turned.z))


def _wr_assert_fits():
    """Every clearance the new pieces claim, checked, at build time."""
    obstacles = _wr_obstacles()
    spine = [Vector(p) for p in WR_FIGUREHEAD_SPINE]
    girth = WR_FIGUREHEAD_GIRTH
    segs = [(spine[i], spine[i + 1], max(girth[i], girth[i + 1])) for i in range(len(spine) - 1)]
    for s in (-1, 1):
        elbow, hand = Vector((23.6, s * 2.3, 8.6)), Vector((20.9, s * 3.8, 6.9))
        segs += [(spine[3], elbow, 0.46), (elbow, hand, 0.42),
                 (spine[0].lerp(spine[1], 0.35), Vector((17.2, s * 4.4, 4.4)), 0.58)]
    gap, who = _wr_clearance(segs, ignore=("sheer rail",), obstacles=obstacles)
    assert gap > 0.0, "Wrack_Figurehead fouls %s by %.2f studs" % (who, -gap)

    for label, (yaw, peak) in (("stowed", WR_BOOM_STOWED), ("swept", WR_BOOM_SWEPT)):
        gap, who = _wr_clearance(_wr_boom_segments(yaw, peak), obstacles=obstacles)
        assert gap > 0.35, "Wrack_Boom %s fouls %s (gap %.2f)" % (label, who, gap)
    worst, worst_who, worst_at = 1e9, "-", (0.0, 0.0)
    for i in range(61):
        t = i / 60.0
        yaw = WR_BOOM_STOWED[0] + (WR_BOOM_SWEPT[0] - WR_BOOM_STOWED[0]) * t
        peak = WR_BOOM_STOWED[1] + (WR_BOOM_SWEPT[1] - WR_BOOM_STOWED[1]) * t
        gap, who = _wr_clearance(_wr_boom_segments(yaw, peak), obstacles=obstacles)
        if gap < worst:
            worst, worst_who, worst_at = gap, who, (yaw, peak)
    assert worst > 0.35, ("Wrack_Boom's sweep drives through %s at yaw %.1f peak %.1f (gap %.2f)"
                          % (worst_who, worst_at[0], worst_at[1], worst))
    hat_top = _wr_adm_at(WR_ADM_HEAD).z + 3.1
    boom_top = max(_wr_boom_at(WR_BOOM_STOWED[0] + (WR_BOOM_SWEPT[0] - WR_BOOM_STOWED[0]) * i / 60.0,
                               WR_BOOM_STOWED[1] + (WR_BOOM_SWEPT[1] - WR_BOOM_STOWED[1]) * i / 60.0,
                               WR_BOOM_LENGTH).z for i in range(61)) + WR_BOOM_R[1]
    assert boom_top < WR_MAST_HEAD[2] and boom_top < hat_top, (
        "the boom tops out at %.2f - above the masthead (%.2f) or the Admiral's hat (%.2f); the silhouette's "
        "high point is the man, and the mast was cut down to keep it that way" % (boom_top, WR_MAST_HEAD[2], hat_top))
    assert not (WR_WAIST[0] - 1.0 < WR_BOOM_PIVOT[0] < WR_WAIST[1] + 1.0), (
        "the boom is socketed in the waist at x %.1f - it would fly apart with the shell plates" % WR_BOOM_PIVOT[0])

    footprints = []
    for x, run, wide in WR_COAMINGS:
        footprints.append(("coaming %+.1f" % x, (x - run - 0.3, x + run + 0.3), (-wide - 0.3, wide + 0.3)))
    for x, y in WR_BITTS:
        footprints.append(("bitts", (x - 0.4, x + 0.4), (y - 0.4, y + 0.4)))
    footprints += [("capstan", (-11.4, -8.2), (-1.7, 1.7)), ("mainmast", (-8.4, -4.6), (-2.0, 2.0)),
                   ("the Admiral", (-16.9, -10.9), (-2.6, 2.6)),
                   ("boom socket", (WR_BOOM_PIVOT[0] - 1.4, WR_BOOM_PIVOT[0] + 1.4),
                    (WR_BOOM_PIVOT[1] - 1.4, WR_BOOM_PIVOT[1] + 1.4))]
    for entry in WR_HATCHES:
        name, x, y, lx, ly, _kind = entry
        hx, hy = (x - lx / 2, x + lx / 2), (y - ly / 2, y + ly / 2)
        assert not (hx[1] > WR_WAIST[0] - 1.5 and hx[0] < WR_WAIST[1] + 1.5), (
            "%s is over the waist - a hatch in a door" % name)
        outer = max(abs(v) for v in hy)
        assert outer / _wr_station(x)[0] < 0.840, "%s reaches y %.2f, outboard of the rail cap" % (name, outer)
        for label, fx, fy in footprints:
            assert not (hx[1] > fx[0] and hx[0] < fx[1] and hy[1] > fy[0] and hy[0] < fy[1]), (
                "%s at (%.1f, %.1f) is buried in %s" % (name, x, y, label))
    _wr_assert_hatch_rise()


# --- the Admiral ------------------------------------------------------------
#
# HE DID NOT SHRINK WITH HIS SHIP. The hull came down to 56% of its old
# length; he came down to 50% of his old height but onto a hull that is
# proportionally far smaller, so against her he is BIGGER than he was: his
# shoulders are 6 studs across a beam of 11 where they used to be 11.9
# across a beam of 34.6. Boot to hat he is 17.2 studs - three and a half
# player-heights - standing on a quarterdeck 12.4 studs off the sand, and he
# is the highest thing on the model apart from his own sabre.
#
# He is authored in his own space (the old file's coordinates, unchanged, so
# every hand-placed button and epaulette still lands where it was drawn) and
# brought onto the deck by ONE matrix. That is the last transform left in
# the section now that the heel is gone, and it does exactly what the heel
# never could: it lets his size be a single number to argue about.
WR_ADM_SCALE = 0.50
# The root of his authored space - where the coat's skirt disappears into
# timber - and where that root lands on the quarterdeck. The plant is 0.7
# BELOW the deck at station -14 (12.4 against _wr_deck(-14) = 13.1), so the
# skirt is lofted down INSIDE the planking and there is no join to disbelieve.
WR_ADM_ROOT = (-24.0, 6.0, 19.0)
WR_ADM_AT = (-14.0, 0.0, 12.4)
WR_ADM = (
    Matrix.Translation(Vector(WR_ADM_AT))
    @ Matrix.Diagonal(Vector((WR_ADM_SCALE,) * 3)).to_4x4()
    @ Matrix.Translation(-Vector(WR_ADM_ROOT))
)


def _wr_admiral(bm):
    """Seat an admiral-space mesh on the quarterdeck at his authored size."""
    bmesh.ops.transform(bm, matrix=WR_ADM, verts=bm.verts)
    return bm


def _wr_adm_at(point):
    """One admiral-space point in boss space - for the handoff prints."""
    return WR_ADM @ Vector(point)


WR_ADM_HIPS = (-24.0, 6.0, 30.0)
WR_ADM_HEAD = (-25.8, 3.8, 47.2)
WR_ADM_SHOULDER = 5.95
WR_SABRE_TIP = (-17.5, 9.0, 63.0)


def build_wr_coat(rng):
    """The Admiral: a torso the size of a launch, growing OUT of the stern
    castle rather than standing on it - the coat's skirt is lofted down
    inside the timber, so there is no join to disbelieve."""
    bm = bmesh.new()
    # (z, centre x, centre y, half-depth, half-width, boxiness)
    stack = [
        (17.0, -23.4, 7.4, 5.6, 8.1, 1.5),    # inside the hull: no seam to see
        (22.0, -23.7, 7.0, 5.2, 7.4, 1.5),
        (27.0, -24.0, 6.4, 4.6, 6.7, 1.5),    # the skirt of the coat, flaring
        (31.0, -24.3, 5.8, 3.8, 5.6, 1.5),
        (34.5, -24.8, 5.2, 3.4, 4.8, 1.4),    # the waist, sashed
        (38.0, -25.2, 4.6, 3.8, 5.5, 1.4),
        (41.5, -25.5, 4.2, 4.1, WR_ADM_SHOULDER, 1.6),  # chest and shoulders
        (43.4, -25.6, 4.0, 3.4, 5.2, 1.6),
        (44.6, -25.8, 3.9, 1.8, 2.2, 1.2),    # the collar, standing high
    ]
    loft(bm, [_wr_vring(z, cx, cy, rx, ry, boxy=k) for z, cx, cy, rx, ry, k in stack])
    # Coat tails, hanging aft and split.
    for side in (-1, 1):
        blade(
            bm,
            (-26.6, 4.6 + side * 2.4, 33.0),
            (-29.4, 4.2 + side * 3.5, 19.5),
            3.8,
            2.2,
            0.7,
            roll=side * 0.12,
        )
    _wr_admiral(bm)
    return _wr_finish("Wrack_Coat", bm, WR_COAT, "M_Wrack_AdmCoat")


def build_wr_arm(rng):
    """Both sleeves. The right is up - the gesture that never stops, because
    he never stops firing. The left goes down into the hull and does not come
    out: at some point he stopped being a man standing on a ship."""
    bm = bmesh.new()
    right = [(-25.5, 9.6, 41.5), (-22.6, 12.8, 46.0), (-20.5, 11.8, 51.5)]
    for (a, b), girth in zip(zip(right, right[1:]), ((2.7, 2.1), (2.1, 1.6))):
        _wr_tube(bm, a, b, girth[0], girth[1], 8)
    ellipsoid(bm, right[1], (2.3, 2.3, 2.3), subdiv=1)
    left = [(-25.5, -1.4, 41.0), (-25.6, -0.1, 34.5), (-24.8, 1.3, 29.2)]
    for (a, b), girth in zip(zip(left, left[1:]), ((2.7, 2.2), (2.2, 1.8))):
        _wr_tube(bm, a, b, girth[0], girth[1], 8)
    ellipsoid(bm, left[1], (2.4, 2.4, 2.4), subdiv=1)
    # Epaulette shoulders, under the gold.
    for at in ((-25.5, 9.6, 41.8), (-25.5, -1.3, 41.4)):
        ellipsoid(bm, at, (2.5, 2.4, 1.3), subdiv=1)
    _wr_admiral(bm)
    return _wr_finish("Wrack_Arm", bm, WR_COAT, "M_Wrack_AdmCoat")


def build_wr_sabre():
    """The sabre held up. It is the tallest thing on the model and a bright
    vertical in a design made of horizontals - and from directly above it is
    a clean bright line, which is the plan view's only diagonal aft."""
    bm = bmesh.new()
    wrist = Vector((-20.5, 11.8, 51.5))
    tip = Vector(WR_SABRE_TIP)
    _wr_tube(bm, wrist - (tip - wrist).normalized() * 2.0, wrist + (tip - wrist).normalized() * 1.6, 0.75, 0.75, 6)
    guard = wrist + (tip - wrist).normalized() * 2.0
    for i in range(7):
        angle = (i / 7) * TAU
        _wr_tube(bm, guard, guard + Vector((math.cos(angle) * 1.9, math.sin(angle) * 1.9, 0.6)), 0.24, 0.18, 4)
    blade(bm, guard, tip, 1.5, 0.45, 0.38, roll=0.25)
    _wr_admiral(bm)
    return _wr_finish("Wrack_Sabre", bm, WR_STEEL, "M_Wrack_AdmSteel")


def build_wr_facings(rng):
    """Lace, lapels, epaulettes, buttons, sash and cuffs.

    This object is the entire reason he reads as an ADMIRAL and not as a
    drowned man in a coat, and it is the only warm colour above the deck -
    so it ties him to his own guns, which are the same metal.
    """
    bm = bmesh.new()
    # Lapels: two broad gold facings down the breast.
    for side in (-1, 1):
        blade(bm, (-22.9, 4.2 + side * 2.4, 43.6), (-23.7, 4.8 + side * 1.0, 32.0), 2.4, 1.2, 0.40)
    # The sash, across the body.
    blade(bm, (-23.0, 8.6, 40.0), (-23.6, -1.2, 31.4), 2.2, 2.2, 0.38, roll=0.2)
    # Buttons, in two ranks.
    for side in (-1, 1):
        for i in range(6):
            ellipsoid(bm, (-22.7, 4.4 + side * 1.6, 34.0 + i * 1.85), (0.40, 0.5, 0.5), subdiv=1)
    # Epaulettes, with bullion fringe hanging off both shoulders.
    for at, direction in (((-25.5, 9.8, 42.2), 1), ((-25.5, -1.5, 41.8), -1)):
        ellipsoid(bm, at, (2.7, 2.6, 0.7), subdiv=1)
        for i in range(9):
            angle = (i / 9) * TAU
            start = Vector(at) + Vector((math.cos(angle) * 2.0, direction * 1.1 + math.sin(angle) * 0.95, -0.4))
            _wr_tube(bm, start, start + Vector((0.0, direction * 0.5, -rng.uniform(2.0, 3.6))), 0.22, 0.16, 4)
    # Cuffs, and the lace round the collar.
    _wr_tube(bm, (-21.2, 12.2, 50.2), (-20.3, 11.6, 52.4), 1.6, 1.5, 8)
    _wr_tube(bm, (-25.4, 1.0, 30.8), (-24.9, 1.4, 29.0), 1.6, 1.5, 8)
    for i in range(12):
        angle = (i / 12) * TAU
        _wr_tube(
            bm,
            (-25.8 + math.cos(angle) * 2.0, 3.9 + math.sin(angle) * 2.4, 44.4),
            (-25.8 + math.cos(angle) * 2.1, 3.9 + math.sin(angle) * 2.5, 45.2),
            0.3,
            0.3,
            4,
        )
    # The bicorne's lace edge, and its cockade.
    for i in range(16):
        t = i / 15.0
        angle = math.pi * t
        _wr_tube(
            bm,
            (-25.9 - math.cos(angle) * 2.7, 3.8 + (t - 0.5) * 14.6, 48.9 + math.sin(angle) * 0.6),
            (-25.9 - math.cos(angle) * 2.9, 3.8 + (t - 0.5) * 14.8, 49.1 + math.sin(angle) * 0.6),
            0.34,
            0.34,
            4,
        )
    ellipsoid(bm, (-23.5, 7.0, 50.2), (0.5, 1.3, 1.3), subdiv=1)
    _wr_admiral(bm)
    return _wr_finish("Wrack_Facings", bm, WR_GOLD, "M_Wrack_AdmGold")


def build_wr_skull(rng):
    """A drowned officer's skull, long in the jaw and pitted. Bone, the same
    material as the ship's frames - because they are the same idea."""
    bm = bmesh.new()
    cx, cy, cz = WR_ADM_HEAD
    ellipsoid(bm, (cx, cy, cz), (3.4, 3.1, 3.6), subdiv=2)
    # Brow, cheekbones, and the long jaw.
    box(bm, (cx + 2.4, cy, cz + 1.2), (1.8, 5.4, 1.5), Matrix.Rotation(math.radians(-12), 3, "Y"))
    for side in (-1, 1):
        ellipsoid(bm, (cx + 1.9, cy + side * 2.3, cz - 0.6), (1.5, 1.3, 1.4), subdiv=1)
    ellipsoid(bm, (cx + 2.0, cy, cz - 3.4), (3.0, 2.4, 1.5), subdiv=1)
    _wr_tube(bm, (cx + 3.6, cy - 1.9, cz - 3.2), (cx + 3.6, cy + 1.9, cz - 3.2), 0.7, 0.7, 6)
    # The neck, going down into the collar.
    _wr_tube(bm, (cx + 0.4, cy + 0.2, cz - 3.0), (cx + 0.6, cy + 0.3, cz - 5.4), 1.9, 2.3, 8)
    # Weed and salt in the sockets and along the crown.
    for _ in range(11):
        angle = rng.uniform(0, TAU)
        pitch = rng.uniform(0.1, 1.1)
        ellipsoid(
            bm,
            (cx + math.cos(angle) * 2.2, cy + math.sin(angle) * 2.6, cz + math.sin(pitch) * 3.1),
            (rng.uniform(0.3, 0.7),) * 3,
            subdiv=1,
        )
    _wr_admiral(bm)
    return _wr_finish("Wrack_Skull", bm, WR_BONE, "M_Wrack_AdmBone")


def build_wr_eyes():
    """Two lights in the sockets. `Glow` in the OBJECT name, per the import
    contract - the material name never reaches runtime."""
    bm = bmesh.new()
    cx, cy, cz = WR_ADM_HEAD
    for side in (-1, 1):
        ellipsoid(bm, (cx + 2.3, cy + side * 1.5, cz + 0.2), (1.1, 1.0, 0.9), subdiv=2)
    _wr_admiral(bm)
    return _wr_finish("Wrack_EyeGlow", bm, WR_EYE, "M_Wrack_AdmEye")


def build_wr_hat(rng):
    """The bicorne, worn athwart. Deliberate: fore-and-aft it is a wedge from
    above and vanishes, athwart it is a wide black bar across the shoulders -
    the single strongest thing in the plan view, and the fight camera's plan
    view is what has to name this boss at a glance."""
    bm = bmesh.new()
    cx, cy, cz = WR_ADM_HEAD
    ellipsoid(bm, (cx - 0.2, cy, cz + 2.6), (3.6, 3.4, 1.9), subdiv=2)
    for side in (-1, 1):
        blade(
            bm,
            (cx - 0.2, cy + side * 1.5, cz + 2.4),
            (cx - 0.6, cy + side * 7.6, cz + 4.2),
            6.0,
            1.4,
            1.5,
            roll=side * 0.2,
        )
    # The brim's turn-up, front and back.
    for front in (1, -1):
        blade(
            bm,
            (cx + front * 2.6, cy, cz + 1.9),
            (cx + front * 3.4, cy, cz + 3.6),
            8.0,
            5.0,
            0.75,
        )
    _wr_admiral(bm)
    return _wr_finish("Wrack_Hat", bm, WR_FELT, "M_Wrack_AdmFelt")


# The order the four cannons are reported in, everywhere: the HANDOFF, the
# `parts.mounts` derivation, the per-cannon render sheet. Bearing order round
# the ship from the bow, which is also the order they are easiest to check
# a render against.
# The order the four cannons are reported in, everywhere: the HANDOFF, the
# `parts.mounts` derivation, the per-cannon render sheet. Corner order from
# the starboard bow, which is also the order they are easiest to check a
# render against.
WR_CANNONS = WR_GUN_ORDER


def build_wrack():
    rng = random.Random(WR_SEED)
    objects = [
        build_wr_base(rng),
        build_wr_hull(rng),
        build_wr_strakes(rng),
        build_wr_keel(rng),
        build_wr_crust(rng),
        build_wr_ribs(rng),
        build_wr_shell_upper(rng),
        build_wr_shell_lower(rng),
        build_wr_heart(),
        build_wr_heart_cage(rng),
        build_wr_cannon_bowstbd(rng),
        build_wr_cannon_bowport(rng),
        build_wr_cannon_sternstbd(rng),
        build_wr_cannon_sternport(rng),
        build_wr_sponsons(rng),
        build_wr_hull_collider(rng),
        build_wr_muzzleflare(),
        build_wr_mast(rng),
        build_wr_rigging(rng),
        build_wr_sail(rng),
        build_wr_figurehead(rng),
        build_wr_figurehead_glow(),
        build_wr_boom(rng),
        build_wr_boom_tackle(rng),
        build_wr_hatch1(rng),
        build_wr_hatch2(rng),
        build_wr_hatch3(rng),
        build_wr_hatch_glow(rng),
        build_wr_coat(rng),
        build_wr_arm(rng),
        build_wr_sabre(),
        build_wr_facings(rng),
        build_wr_skull(rng),
        build_wr_eyes(),
        build_wr_hat(rng),
        build_wr_pistol(rng),
    ]
    _wr_assert_fits()
    shot_hist, eye_hist = _wr_assert_sponsons(WR_CASEMATE_MEASURED)
    hinge = Vector((0.0, 0.0, WR_KEEL_Z))
    head = _wr_adm_at(WR_ADM_HEAD)
    tip = _wr_adm_at(WR_SABRE_TIP)
    print("HANDOFF wrack: STATIC. One CFrame for the whole model - he never moves, never turns. Wrack_Base is the anchor; its centre is the boss origin at sand level (z=0 = the shoal).")
    print("HANDOFF wrack: UPRIGHT (the 48-deg careen is GONE, 2026-09-08). Bow at +X, stern at -X, keel bedded at z %.1f, masts up." % WR_KEEL_Z)
    print("HANDOFF wrack: SIZE - %.0f studs stem to sternpost, %.0f across the sponsons (the corner guns stand outboard now, so the widest thing on her is her own ordnance), %.1f to the masthead, %.1f to the Admiral's hat, %.1f to the sabre tip." % (
        WR_HULL[-1][0] - WR_HULL[0][0],
        2.0 * max(abs(WR_GUNS[n][0][1][1]) for n in WR_GUN_ORDER),
        WR_MAST_HEAD[2], head.z + 3.1, tip.z))
    print("HANDOFF wrack: CAMERA - from the r 88 drop ring the birdseye eye (boom pinned -20) is 142.5 studs out and 27.3 up, so the top of frame is z = 27.3 + 142.5*tan(35 + aim): 29.8 at the -34 rest pitch, 40.1 at -30, 65.5 at the -20 boom pin. The whole model needs aim >= -30.4 (the OLD one needed -17.6, inside 4 deg of the +14 ceiling).")
    print("HANDOFF wrack: FOUR CANNONS - one gun each, integral to the hull, addressable by object name -")
    for name in WR_CANNONS:
        guns = WR_GUNS[name]
        mid = Vector((0.0, 0.0, 0.0))
        for breech, muzzle, _bore in guns:
            mid = mid + (Vector(breech) + Vector(muzzle)) / 2
        mid = mid / len(guns)
        bearing = math.degrees(math.atan2(mid.y, mid.x)) % 360.0
        print(
            "HANDOFF wrack:   Wrack_Cannon%-10s %d gun, span centroid (%.2f, %.2f, %.2f), bearing %3.0f deg -> Bosses parts.mounts Vector3.new(%.2f, %.2f, %.2f)"
            % (name, len(guns), mid.x, mid.y, mid.z, bearing, mid.x, mid.z, -mid.y)
        )
    for name in WR_CANNONS:
        for index, (breech, muzzle, bore) in enumerate(WR_GUNS[name]):
            direction = (Vector(muzzle) - Vector(breech)).normalized()
            print(
                "HANDOFF wrack:     %s/%d muzzle (%.1f, %.1f, %.1f) dir (%.2f, %.2f, %.2f) bore %.2f"
                % (name, index, muzzle[0], muzzle[1], muzzle[2],
                   direction.x, direction.y, direction.z, bore)
            )
    print("HANDOFF wrack: Wrack_MuzzleGlow is a MODULE - authored at the origin, +X is the bore direction, placed once per muzzle above. Hide the one belonging to a silenced cannon.")
    print(
        "HANDOFF wrack: THE MELEE WINDOW - Wrack_ShellUpper (PORT plate) +%.0f deg and Wrack_ShellLower (STARBOARD plate) %.0f deg about the boss-local X axis through Blender (%.1f, %.1f, %.1f) = ROBLOX (%.1f, %.1f, %.1f). Equal and opposite: they peel outboard and down like double doors and the waist becomes a %.0f-stud hole with Wrack_HeartGlow in it."
        % (WR_OPEN_UPPER_DEG, WR_OPEN_LOWER_DEG, hinge.x, hinge.y, hinge.z,
           hinge.x, hinge.z, -hinge.y, WR_WAIST[1] - WR_WAIST[0])
    )
    heart = Vector(WR_HEART)
    print("HANDOFF wrack: Wrack_HeartGlow at Blender (%.1f, %.1f, %.1f) = ROBLOX (%.1f, %.1f, %.1f) - hangs in the hold, only reachable once both shells swing" % (
        heart.x, heart.y, heart.z, heart.x, heart.z, -heart.y))
    print("HANDOFF wrack: EMISSIVE parts carry `Glow` in the OBJECT name (Wrack_HeartGlow, Wrack_EyeGlow, Wrack_MuzzleGlow).")
    print("HANDOFF wrack: WARNING - that marker is honoured by BossArenaService.placeAuthored (ARENA meshes only). The boss path (<Boss>BodyController clones pack parts) has NO Neon-by-name rule, so these three import FLAT unless the Wrack body controller sets Material.Neon on them. Same defect as 5edfbce, one layer over - Kraken_Eyes/Kraken_Pupil are already affected.")
    launch, _ = _wr_fh_axis()
    print("HANDOFF wrack: THE FIGUREHEAD - Wrack_Figurehead + Wrack_FigureheadGlow ride one CFrame. Dock/mount ROBLOX (%.2f, %.2f, %.2f); she flies along her own spine, ROBLOX dir (%.2f, %.2f, %.2f); head tops out at %.2f." % (
        WR_FIGUREHEAD_AT[0], WR_FIGUREHEAD_AT[2], -WR_FIGUREHEAD_AT[1],
        launch.x, launch.z, -launch.y, WR_FIGUREHEAD_SPINE[-1][2] + WR_FIGUREHEAD_GIRTH[-1]))
    print("HANDOFF wrack: THE BOOM - pivot ROBLOX (%.2f, %.2f, %.2f), yaw axis (0,1,0), length %.1f, tackle at %.2f of it. ROBLOX yaw = -(the Blender yaw here). Stowed yaw %.1f peak %.1f; swept yaw %.1f peak %.1f." % (
        WR_BOOM_PIVOT[0], WR_BOOM_PIVOT[2], -WR_BOOM_PIVOT[1], WR_BOOM_LENGTH, WR_BOOM_TACKLE_AT,
        -WR_BOOM_STOWED[0], WR_BOOM_STOWED[1], -WR_BOOM_SWEPT[0], WR_BOOM_SWEPT[1]))
    print("HANDOFF wrack:   PEAK ENVELOPE (ROBLOX yaw: lowest legal peak). Outside this the spar goes through the ship - the client MUST clamp to it, and the server sends yaw only:")
    print("HANDOFF wrack:   " + "  ".join("%+.0f:%+.0f" % (-y, p) for y, p in _wr_boom_envelope() if p is not None))
    print("HANDOFF wrack: THE HATCHES - three lids, per-piece hinge AND per-piece axis; a single-axis pose swings two of them into the deck. A POSITIVE turn about the stored axis opens the lid (asserted every build).")
    for entry in WR_HATCHES:
        nm, hx, hy, lx, ly, kind = entry
        hp, ax = _wr_hatch_hinge(entry)
        print("HANDOFF wrack:   %-13s ROBLOX at (%.2f, %.2f, %.2f) size %.1f x %.1f, hinge (%.2f, %.2f, %.2f) axis (%.0f, %.0f, %.0f), opens %.0f deg (%s edge)" % (
            nm, hx, _wr_deck_at(hx, hy), -hy, lx, ly, hp.x, hp.z, -hp.y, ax.x, ax.z, -ax.y, WR_HATCH_OPEN_DEG, kind))
    print("HANDOFF wrack: THE ADMIRAL is a self-contained assembly - Coat/Arm/Sabre/Facings/Skull/EyeGlow/Hat/Pistol. Foot origin ROBLOX (%.2f, %.2f, %.2f), %.2f BELOW the deck it stands on, height %.1f, facing ROBLOX (1, 0, 0) (measured off the coat shoulder ring: half-width %.2f across Y beats half-depth 4.10 across X, and the tails hang aft)." % (
        WR_ADM_AT[0], WR_ADM_AT[2], -WR_ADM_AT[1], _wr_deck(WR_ADM_AT[0]) - WR_ADM_AT[2],
        _wr_adm_at(WR_ADM_HEAD).z + 3.1 - WR_ADM_AT[2], WR_ADM_SHOULDER))
    print("HANDOFF wrack: Wrack_HullCollider is INVISIBLE - Transparency 1, CanCollide/CanQuery true. It is the shot blocker, and it carries the four casemate boxes, so what the player sees shielding a far gun is what stops the shot. It has NO MeshColors row on purpose.")
    print("HANDOFF wrack: SHOT OCCLUSION - wrack_battery.shotRadius MUST equal %.1f (this file bakes it as WR_BATTERY_SHOT_RADIUS). At 5.0, %s of samples could hit three or more guns THROUGH the ship. Shootable histogram from the shot origin %s; from the birdseye eye %s." % (
        WR_BATTERY_SHOT_RADIUS, "80/144", dict(sorted(shot_hist.items())), dict(sorted(eye_hist.items()))))
    print("HANDOFF wrack: RENAMED OBJECTS - Wrack_BatteryDeck/Keel/Stern/Top are GONE. The four targets are now the CORNER guns - Wrack_CannonBowStbd / Wrack_CannonBowPort / Wrack_CannonSternStbd / Wrack_CannonSternPort, outboard on sponsons at bearings +-30 / +-150. MeshColors rows, WrackBodyController PIECES/AUTHORED and import-checklist row 7p all key on these names.")
    return objects


# ---------------------------------------------------------------- wrack pose
#
# He is STATIC, so this is nearly the entire rig: identity for every piece,
# the two shell plates on the keel hinge, and one muzzle flare per live gun.
# There are exactly two knobs, and they are the two the fight has.


def _wr_copy(source, matrix):
    copy = source.copy()
    copy.data = source.data
    copy.hide_render = False
    bpy.context.collection.objects.link(copy)
    copy.matrix_world = matrix
    return copy


def _wr_unplace(made):
    """Drop a placement so the next state can be built in the same scene."""
    for obj in made:
        bpy.data.objects.remove(obj, do_unlink=True)


def _wr_hinge(degrees):
    """A rotation about the KEEL AXIS - the line both shell plates swing on.

    Upright, the keel is the world X axis through (0, 0, WR_KEEL_Z), so the
    hinge is one point and one angle rather than a matrix per plate - which
    is what lets the client drive it off two constants.
    """
    pivot = Vector((0.0, 0.0, WR_KEEL_Z))
    return Matrix.Translation(pivot) @ Matrix.Rotation(math.radians(degrees), 4, "X") @ Matrix.Translation(-pivot)


def _place_wrack(objects, opened=0.0, silenced=()):
    """`opened` 0..1 drives the melee window; `silenced` names cannons whose
    guns have been shot out, and those stop flaring."""
    parts = {obj.name.split("_", 1)[1]: obj for obj in objects}
    swing = {"ShellUpper": WR_OPEN_UPPER_DEG, "ShellLower": WR_OPEN_LOWER_DEG}
    made = []
    for name, obj in parts.items():
        if name in ("MuzzleGlow", "HullCollider"):
            continue          # a module, and an invisible blocker
        made.append(_wr_copy(obj, _wr_hinge(swing[name] * opened) if name in swing else Matrix.Identity(4)))
    flare = parts["MuzzleGlow"]
    lit = 0
    for cannon, guns in WR_GUNS.items():
        if cannon in silenced:
            continue
        for breech, muzzle, bore in guns:
            direction = (Vector(muzzle) - Vector(breech)).normalized()
            made.append(
                _wr_copy(
                    flare,
                    Matrix.Translation(Vector(muzzle))
                    @ Vector((1, 0, 0)).rotation_difference(direction).to_matrix().to_4x4()
                    @ Matrix.Diagonal((bore / 0.9,) * 3).to_4x4(),
                )
            )
            lit += 1
    print("POSE wrack: %d parts placed, %d muzzles lit, waist %.0f%% open" % (len(made), lit, opened * 100))
    return made


def _wr_figure(bm, at, facing=0.0):
    """A ~5.5-stud humanoid stand-in: a Roblox character, near enough.

    boss_gen has no scale facility of its own, and "how big is he?" is the
    one question a preview of a static boss cannot answer by itself - the
    lens will happily make a 48-stud hulk look like a bath toy.

    `facing` IS APPLIED, and this note is here because the sibling section's
    `_bj_rest_path` took a face angle and silently ignored it for weeks
    (drawing every faced Brinejaw render 9.11 studs off). `rot` below is used
    by every box in this function; a stand-in that ignored it would still
    render a person and nobody would see the omission.
    """
    x, y, z = at
    rot = Matrix.Rotation(facing, 3, "Z")
    box(bm, (x, y, z + 3.6), (0.9, 2.0, 1.8), rot)
    ellipsoid(bm, (x, y, z + 4.9), (0.62, 0.62, 0.62), subdiv=1)
    for side in (-1, 1):
        arm = rot @ Vector((0.0, side * 1.3, 0.0))
        box(bm, (x + arm.x, y + arm.y, z + 3.5), (0.6, 0.6, 1.9), rot)
        leg = rot @ Vector((0.0, side * 0.45, 0.0))
        box(bm, (x + leg.x, y + leg.y, z + 1.4), (0.7, 0.8, 2.8), rot)


# WHERE THE STAND-INS GO, and these are not decorative: they are the three
# ranges the fight is actually played at, so the staged sheet answers "can I
# see the whole enemy from where I stand" rather than "is he pretty".
#
#   r 60    hard against him, inside the broadside's arc
#   r 88    THE DROP RING - where the party arrives, and the range every
#           number in the camera arithmetic above is solved for
#   r 128   the sand's outer edge, where you retreat to read the pattern
#
# (x, y, facing) with facing pointed back at the ship, so every stand-in is
# a person looking at the boss rather than a box on the sand.
WR_SCALE_MARKS = [
    (42.4, -42.4, math.radians(135.0)),   # r 60, off the starboard bow
    (-62.2, -62.2, math.radians(45.0)),   # r 88, off the port quarter
    (0.0, -128.0, math.radians(90.0)),    # r 128, square on the port beam
    (128.0, 0.0, math.radians(180.0)),    # r 128, dead ahead of the bow chaser
    (-60.0, 64.5, math.radians(-47.0)),   # r 88, off the starboard quarter
    (60.0, 0.0, math.radians(180.0)),     # r 60, dead ahead
]


def _wr_shoal(rng):
    """A bare tidal flat to stand him on when arena_gen cannot supply the
    real Careenage.

    arena_gen is shared and frequently mid-edit; when this lane built,
    `build_wrack` had been removed from the working tree by another lane's
    in-flight rewrite. A staged render that dies on someone else's unfinished
    file teaches nothing, so it falls back and SAYS SO on the print - the
    fallback is never silently mistaken for the real set.
    """
    bm = bmesh.new()
    for i in range(64):
        angle = (i / 64) * TAU
        for radius in (30.0, 56.0, 80.0):
            x, y = math.cos(angle) * radius, math.sin(angle) * radius
            box(bm, (x, y, -0.7), (radius * 0.11, radius * 0.11, 1.2), Matrix.Rotation(angle, 3, "Z"))
    box(bm, (0, 0, -1.4), (196.0, 196.0, 1.6))
    return _wr_finish("WrackShoal_Base", bm, (0.445, 0.429, 0.384), "M_Wrack_AdmShoal")


# The staged sheet. A static boss is judged from BEARINGS, not from one hero
# angle, so most of these are the same camera walked round him - which is
# also the only honest test of the claim the whole layout rests on: that no
# position shows all four cannons.
#
# Every camera here is pulled in from the old sheet's distances by the same
# factor the ship came down by, so a shot framed on the 87-stud hulk still
# frames the 48-stud one.
WR_SHOTS = [
    ("", (86.0, -100.0, 62.0), (0.0, 0.0, 12.0), 38, "THE HULK - three-quarter from off the bow"),
    ("_fight", (-52.0, 66.0, 52.0), (0.0, 0.0, 11.0), 32, "THE FIGHT CAMERA - high and pitched down, at play distance"),
    # THE PLAN VIEW. Near-overhead, because a boss that never moves is stared
    # at from a pitched-down camera for the whole fight and the thing that has
    # to survive that is the OUTLINE: a hull teardrop, a bowsprit spear off
    # the bow, a mast and yard crossing it, a bicorne at the stern.
    ("_plan", (6.0, -16.0, 124.0), (0.0, 0.0, 10.0), 40, "THE PLAN - what the fight camera actually looks down at"),
    ("_gun_bowstbd", (70.0, 40.0, 30.0), (16.5, 9.5, 13.2), 42, "CANNON 1/4 BowStbd - and the casemate backs of the far pair"),
    ("_gun_bowport", (70.0, -40.0, 30.0), (16.5, -9.5, 13.2), 42, "CANNON 2/4 BowPort"),
    ("_gun_sternstbd", (-70.0, 40.0, 30.0), (-16.5, 9.5, 14.0), 42, "CANNON 3/4 SternStbd"),
    ("_gun_sternport", (-70.0, -40.0, 30.0), (-16.5, -9.5, 14.0), 42, "CANNON 4/4 SternPort"),
    # THE COUNTING SHOT. Straight down, so all four corners and all four
    # casemate mouths are in one frame - the only view that lets someone check
    # the claim the whole layout rests on (exactly two guns face any bearing)
    # without walking the camera round the ship themselves.
    ("_corners", (0.0, 0.0, 150.0), (0.0, 0.0, 12.0), 45, "THE CORNERS - four sponsons, four mouths, two facing any bearing"),
]


def _stage_wrack(path_out, objects):
    """Admiral Wrack on the Careenage: the bearing sheet, the melee window,
    and a scale shot with human stand-ins at the ranges he is fought from."""
    import os

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import arena_gen  # noqa: E402  (guarded: importing it builds nothing)

    rng = random.Random(WR_SEED + 1)
    arena = getattr(arena_gen, "build_wrack", None)
    if arena is None:
        print("STAGE WARNING: arena_gen has no build_wrack (another lane's in-flight edit) - "
              "standing him on a BARE SHOAL. The arena in these renders is NOT the real Careenage.")
        _wr_shoal(rng)
    else:
        arena()
    for obj in objects:
        obj.hide_render = True

    # The shoal's own light: a low hard key off the water and a cool fill, so
    # slate-blue timber keeps its facets instead of going to one silhouette.
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.rotation_euler = (math.radians(46), 0, math.radians(-58))
    sun.data.energy = 2.5
    bpy.context.collection.objects.link(sun)
    fill = bpy.data.objects.new("Fill", bpy.data.lights.new("Fill", "SUN"))
    fill.rotation_euler = (math.radians(68), 0, math.radians(126))
    fill.data.energy = 0.6
    bpy.context.collection.objects.link(fill)

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1500
    scene.render.resolution_y = 1000
    # Standard, not the default filmic transform: this boss is designed on a
    # COLD-hull / WARM-guns contrast against a warm arena, and filmic pulls
    # every authored colour toward the same pale tan (compare the shipped
    # gnashroot preview, whose dark moss hide ships looking like sand). The
    # shared render_preview keeps the house look; this sheet tells the truth
    # about the palette, which is the thing it exists to let someone judge.
    scene.view_settings.view_transform = "Standard"
    scene.world = bpy.data.worlds.new("World")
    scene.world.use_nodes = True
    bg = scene.world.node_tree.nodes.get("Background")
    if bg:
        bg.inputs[0].default_value = (0.415, 0.470, 0.515, 1.0)

    def shoot(suffix, location, target, lens, label):
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
        print("BOSS STAGED:", out, "-", label)

    made = _place_wrack(objects)
    for suffix, location, target, lens, label in WR_SHOTS:
        shoot(suffix, location, target, lens, label)

    # THE MELEE WINDOW, from almost overhead - the one angle that proves the
    # hull really opens rather than merely cracking a seam, and the one the
    # upright double-door split was designed for.
    _wr_unplace(made)
    made = _place_wrack(objects, opened=1.0, silenced=WR_CANNONS)
    # A lamp in the hold. Wrack_HeartGlow is Neon in game; in a render it is
    # just a pale ball unless it actually throws light, and this is the one
    # frame whose whole subject is that it is reachable.
    heart = bpy.data.objects.new("HeartLamp", bpy.data.lights.new("HeartLamp", "POINT"))
    heart.location = Vector(WR_HEART)
    heart.data.energy = 40000.0
    heart.data.color = WR_LAMP
    heart.data.shadow_soft_size = 2.0
    bpy.context.collection.objects.link(heart)
    shoot("_opened", (34.0, -40.0, 74.0), (2.0, 0.0, 6.0), 34,
          "ALL FOUR SILENCED - the waist swings off the keel and the heart is reachable")

    # SCALE. Stand-ins on the sand at r 60 / 88 / 128 - the three ranges the
    # fight is played at. THIS IS THE SHOT THE DESIGN IS JUDGED ON: if the
    # whole enemy does not read against a 5-stud person from the drop ring,
    # nothing else on the sheet matters.
    _wr_unplace(made)
    made = _place_wrack(objects)
    bm = bmesh.new()
    for x, y, facing in WR_SCALE_MARKS:
        _wr_figure(bm, (x, y, 0.0), facing)
    figures = _wr_finish("WrackScale_Figures", bm, (0.86, 0.32, 0.24), "M_Wrack_AdmScale")
    bpy.data.objects.remove(heart, do_unlink=True)
    shoot("_scale", (96.0, -142.0, 46.0), (-6.0, -16.0, 12.0), 36,
          "SCALE - stand-ins at r 60 / 88 / 128, the ranges the fight is played at")
    bpy.data.objects.remove(figures, do_unlink=True)

BOSSES = {
    "brinejaw": build_brinejaw,
    "kraken": build_kraken,
    "gnashroot": build_gnashroot,
    "noctyss": build_noctyss,
    "rimefang": build_rimefang,
    "pyrelisk": build_pyrelisk,
    "wrack": build_wrack,
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
    # No "tail_z" here on purpose: it was a hand-copy of the Luau's
    # sandY(tail_out) + 1.2 and had drifted to 3.4 against its 2.79. The tail's
    # resting height is computed from the beach profile now, at the one place
    # that uses it, so there is nothing left to drift.
    # 0.85 -> 0.55, mirroring the Luau: the slack is a real cylindrical spiral
    # now (see _bj_rest_path), and wound honestly at a growing radius 0.85 of
    # a turn cost 111 studs of body against the 49 the old world-space Hermite
    # spent cutting across. 0.55 is the silhouette that shipped, without the
    # bulge-and-cut-back that made the bottom coil read as detached.
    "tail_turn": 0.55,
}


# THE TOWER STEPS; THE BODY DOES NOT. Each drum starts 0.2 studs narrower than
# the one below it ends - a corbel, and correct masonry, which build_bj_spire
# still builds. But reading the drums directly gave the coils a radius that
# TELEPORTED 0.2 studs across zero height at z=20 and again at z=38, and the
# helix crosses both. On a spiral this tight that was a 73-degree corner in the
# body, twice - worse than either join the curve was actually designed around.
# So the clearance curve is the drums' endpoints as one continuous polyline. It
# sits at or outside the masonry everywhere, so the body rides over each ledge
# instead of snapping across it. Mirrors BrinejawPath.SPIRE_PROFILE.
BJ_SPIRE_PROFILE = ((3.5, 8.5), (20.0, 7.4), (38.0, 6.2), (54.0, 5.2))


def _spire_radius(z):
    """The radius the coils wrap at height z - continuous, unlike the drums."""
    for i in range(len(BJ_SPIRE_PROFILE) - 1):
        (z0, r0), (z1, r1) = BJ_SPIRE_PROFILE[i], BJ_SPIRE_PROFILE[i + 1]
        if z <= z1:
            t = max(0.0, min(1.0, (z - z0) / (z1 - z0)))
            return r0 + (r1 - r0) * t
    return BJ_SPIRE_PROFILE[-1][1]


# The rest of the pose vocabulary, ported from the SHIPPED math in
# src/Shared/Modules/BrinejawPath.luau so a render can show any fight state,
# not just the idle one. Keeping the two in step matters: these images are
# how an attack gets reviewed before anyone can play it, and a render that
# quietly disagreed with the game would be worse than no render. The Luau is
# the source of truth; if you change one, change both.
#
# COVERAGE, so nobody has to guess: this port carries EVERY pose kind the Luau
# has - the rest pose, the whipping sweep arm, the slump, and all six attack
# kinds (lunge / undertow / belltoll / rear / spiral / collapse) off the same
# (AttackKind, AttackU, AimX, AimZ) channel. Verified numerically against the
# shipped math at 481 body positions x 11 pose states: worst divergence
# 1.4e-14 studs. Two constants that HAD drifted were corrected in the same
# pass - BJ_SWEEP_HIGH (5.4 against the Luau's 8.5) and the coil drop, which
# was missing the clamp to the beach and rendered the third stance 16 studs
# and the collapse 26.6 studs away from the pose the game holds.
#
# Roblox is Y-up and Blender is Z-up, so the mapping throughout is
# Luau (x, y, z) -> Blender (x, z, y): the helix is the same circle, and
# "height" moves from the Luau's Y to Blender's Z.

BJ_SWEEP_REACH = 66.0
BJ_SWEEP_INNER = 13.0
BJ_SWEEP_LOW = 1.6
# 8.5, NOT 5.4. This was a hand-copy that never got the fix: the Luau raised
# HIGH from 5.4 because |3.0 - 5.4| = 2.4 sits INSIDE girth 3.6, so standing
# under a high sweep was hit and half the mechanic taught the opposite of
# what it means. A render at 5.4 would show a sweep nobody can stand under.
BJ_SWEEP_HIGH = 8.5
BJ_MAX_COIL = 3
BJ_COIL_DROP = (BJ_REST["top_z"] - BJ_REST["bottom_z"]) / BJ_REST["turns"]

# THE ATTACK CHANNEL, ported whole from BrinejawPath's contract header: the
# server publishes (AttackKind, AttackU, AimX, AimZ) alongside the original
# six attributes, and every pose below is a function of those ten values. The
# Luau is the source of truth for all of it; read that file's header for what
# U means per kind, and keep these numbers equal to it.
#
# Blender is Z-up, so the Luau's BELL (x, y, z) = (8.6, 53.0, -2.8) arrives
# here as (x, y, z) = (8.6, -2.8, 53.0) - the bell hung off the lighthouse
# gallery by arena_gen's build_bj_dressing, NOT the half-buried one on the
# sand that the first draft struck.
BJ_BELL = (8.6, -2.8, 53.0)
BJ_AIM_MIN, BJ_AIM_MAX = 16.0, 58.0
BJ_LUNGE_COCK_U, BJ_LUNGE_IMPACT_U = 0.35, 0.50
BJ_LUNGE_COCK_R, BJ_LUNGE_RISE = 16.0, 12.0
BJ_BELL_WINDUP_U, BJ_BELL_IMPACT_U, BJ_BELL_LIFT = 0.35, 0.55, 1.7
BJ_BELL_COCK_R, BJ_BELL_RISE = 15.0, 14.0
BJ_REAR_U, BJ_REAR_OUT, BJ_REAR_LIFT = 0.30, 10.0, 24.0
BJ_UNDER_T0, BJ_UNDER_T1 = 0.34, 0.67
BJ_UNDER_INNER, BJ_UNDER_OVERRUN = 10.0, 10.0
BJ_UNDER_DEPTH, BJ_UNDER_HUMP, BJ_UNDER_SIGMA = 4.5, 7.1, 6.0
BJ_SPIRAL_CLOSE = 8.0
# THE DRAWN SKULL, mirrored from BrinejawPath. The chain's t=0 is the NECK
# JOINT; the client hangs the head off a frame BJ_HEAD_LEAD studs further
# along the tangent, and the mesh's jaw runs BJ_HEAD_UNDER (3.5 mesh studs,
# from BJ_JAW's cz - hh) below that frame. A pose that lays the head on the
# sand has to do arithmetic with both, which is why they are shared numbers
# and not drawing constants - the stagger's skull was rendered 10.11 studs
# under the beach before they were.
BJ_HEAD_LEAD, BJ_HEAD_SCALE, BJ_HEAD_UNDER, BJ_HEAD_CLEAR = 8.9, 1.35, 3.5, 0.95
# How far off the coil's bearing the head can swing to watch someone - a cone,
# not free rotation, because the neck is anchored to the top coil.
BJ_HEAD_TURN = math.radians(125)
BJ_SLUMP_LEVEL, BJ_SLUMP_LIFT, BJ_SLUMP_SETTLE = 0.22, 0.20, 0.25
# The coil slam: a mid-body loop that rises, crashes along the aim bearing and
# LIES ON THE SAND as a melee window. SPLAY is an angle, not a width - see the
# Luau's coilslamCyl for why a constant lateral offset swung the pose 40.91
# studs in one step of U.
BJ_SLAM_T0, BJ_SLAM_T1 = 0.26, 0.60
BJ_SLAM_INNER, BJ_SLAM_OUTER = 14.0, 62.0
BJ_SLAM_SPLAY = math.radians(3.5)
BJ_SLAM_LIFT, BJ_SLAM_SIT = 26.0, 2.7
BJ_SLAM_RISE_U, BJ_SLAM_IMPACT_U, BJ_SLAM_LIE_U = 0.40, 0.50, 0.85
# The reactive bite.
BJ_BITE_REAR_U, BJ_BITE_IMPACT_U, BJ_BITE_HANG_U = 0.30, 0.45, 0.75
BJ_BITE_COCK_R, BJ_BITE_RISE = 18.0, 8.0
# The whip. drag(r) = BJ_WHIP_DRAG * (r - inner) * rate, so the arm TRAILS its
# base bearing: 28.2 degrees at the tip at the book's fastest sweep. A render
# has no angular velocity of its own, so `sweep_rate` is just another field of
# the state dict - set it to see the arm curve.
BJ_WHIP_DRAG, BJ_WHIP_RATE_MAX = 0.0039, 3.0
BJ_ATTACK = {
    # `level` is the fraction of a NECK span that runs FLAT out of the head
    # before the arc climbs to the coil - only for a kind that PLANTS the
    # skull, because the head is drawn along the TANGENT and a neck that
    # climbs from k=0 takes the skull into the beach with it. belltoll strikes
    # upward and has none.
    "lunge": {"mode": "neck", "span": 0.26, "entry": 0.10, "exit": 0.28, "arch": 5.0, "level": 0.22},
    "belltoll": {"mode": "neck", "span": 0.24, "entry": 0.10, "exit": 0.14, "arch": 7.0},
    "rear": {"mode": "rear", "span": 0.50, "entry": 0.16, "exit": 0.16},
    "undertow": {"mode": "undertow", "entry": 0.30, "exit": 0.30},
    "spiral": {"mode": "sweep"},
    "collapse": {"mode": "fall"},
    "coilslam": {"mode": "coilslam", "entry": 0.35, "exit": 0.15},
    "bite": {"mode": "neck", "span": 0.20, "entry": 0.10, "exit": 0.25, "arch": 3.0, "level": 0.22},
}


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
        # DERIVED on both sides from sweep_angle, never replicated - see the
        # Luau's contract header. A still render just sets it.
        "sweep_rate": 0.0,
        "slump": 0.0,
        "face_angle": BJ_REST["bearing"] - 0.8,
        "attack_kind": "",
        "attack_u": 0.0,
        "aim_x": 0.0,
        "aim_z": 0.0,
        "time": 0.0,
    }
    state.update(overrides)
    return state


def _wrap(a):
    return (a + math.pi) % TAU - math.pi


def _bj_cyl_of(p):
    """(bearing, radius, height) - Blender's Z is the Luau's Y."""
    r = math.hypot(p.x, p.y)
    return (math.atan2(p.y, p.x) if r > 1e-4 else 0.0), r, p.z


def _bj_from_cyl(th, r, z):
    return Vector((math.cos(th) * r, math.sin(th) * r, z))


def _bj_rest_bearing_ref(t):
    """The bearing the rest pose is WINDING THROUGH at t - continuous, and
    growing past +-pi rather than wrapping. Cylindrical blends MUST use this:
    the pose is a three-turn helix, so neighbouring vertebrae sit up to a full
    turn apart and a per-point 'short way round' tears the curve (measured in
    the Luau as a 144-degree kink in the tail at half weight)."""
    rest = BJ_REST
    if t <= rest["helix_end"]:
        k = max(0.0, min(1.0, (t - rest["neck_end"]) / (rest["helix_end"] - rest["neck_end"])))
        return rest["bearing"] + rest["turns"] * TAU * k
    k = (t - rest["helix_end"]) / (1.0 - rest["helix_end"])
    return rest["bearing"] + rest["turns"] * TAU + rest["tail_turn"] * TAU * k


def _bj_rest_bearing(t, wrapped):
    ref = _bj_rest_bearing_ref(t)
    return ref + _wrap(wrapped - ref)


def _bj_cyl_blend(th, r, z, t_th, t_r, t_z, w):
    return _bj_from_cyl(th + (t_th - th) * w, r + (t_r - r) * w, z + (t_z - z) * w)


def _bj_coil_offset(state):
    """How far the whole stack has slid down the tower, in studs - CLAMPED to
    the beach, exactly as the Luau does. Unclamped (which is what this port
    carried) the third stance puts 43% of the body underground and the death
    collapse buries two thirds of it 22 studs into the sand: measured 16.0
    studs of divergence at coil=1 and 26.6 during a collapse, so a render of
    either state was showing a pose the game does not have."""
    drop = (BJ_MAX_COIL - state["coil"]) * BJ_COIL_DROP
    floor = BJ_REST["bottom_z"] - _bj_sand_z(0) - BJ_REST["clearance"]
    return max(0.0, min(drop, max(floor, 0.0)))


def _bj_rest_path(t, state=None):
    """Head (t=0) to rattle (t=1) in arena-local space, waterline at z=0."""
    rest = BJ_REST
    state = state or bj_state()
    drop = _bj_coil_offset(state)
    neck_end, helix_end = rest["neck_end"], rest["helix_end"]

    def helix(k):
        z = (rest["top_z"] - drop) + ((rest["bottom_z"] - drop) - (rest["top_z"] - drop)) * k
        theta = rest["bearing"] + rest["turns"] * TAU * k
        r = _spire_radius(z) + rest["clearance"] * (1 - 0.10 * state["unwind"])
        return Vector((math.cos(theta) * r, math.sin(theta) * r, z))

    def helix_tangent(k):
        """The coil's heading, by central difference - both joins leave on it."""
        a, b = max(k - 1e-3, 0.0), min(k + 1e-3, 1.0)
        return (helix(b) - helix(a)) / (b - a)

    if t <= neck_end:
        # A quadratic sweep from the reared neck down onto the top coil.
        u = t / neck_end
        # IT WATCHES YOU, and this port did not. `face_angle` tracks the
        # nearest player, clamped to a cone off the coil's own bearing because
        # the neck is still wrapped round a lighthouse - and the port had the
        # anchor hard-coded, so every render of a state with a face angle drew
        # the head on the wrong bearing. Measured against the Luau at the
        # `stagger` pose's own face_angle of 250 degrees: 9.11 studs.
        anchor = rest["bearing"] - 0.8
        swing = max(-BJ_HEAD_TURN, min(BJ_HEAD_TURN, _wrap(state["face_angle"] - anchor)))
        theta = anchor + swing
        head_z = rest["head_z"] - drop
        r = _spire_radius(head_z) + rest["clearance"] + rest["head_out"]
        top = Vector((math.cos(theta) * r, math.sin(theta) * r, head_z))
        start = helix(0.0)
        # The control point sets the head's carry angle: top - control is the
        # direction the skull points, so a mostly-outward vector with a little
        # lift gives the cobra look - reared over the gallery, watching the
        # sand - instead of a snout aimed at the sky.
        control = top - Vector((math.cos(theta) * 11.0, math.sin(theta) * 11.0, 2.5))
        # CUBIC, not quadratic. The single control point of a quadratic is
        # already spent on the carry angle, so the far end arrived 64.5 degrees
        # off the coil it joined - a visible corner in the neck, in the pose
        # this boss holds most of the fight. The second control point buys the
        # join: a third of the way down the helix's own entry tangent.
        enter = helix_tangent(0.0) * (neck_end / (helix_end - neck_end))
        guide = start - enter / 3.0
        v = 1 - u
        return top * v**3 + control * (3 * v * v * u) + guide * (3 * v * u * u) + start * u**3

    if t <= helix_end:
        return helix((t - neck_end) / (helix_end - neck_end))

    # Slack: the tail leaves the tower, spirals down and lies on the sand.
    # A HERMITE IN CYLINDRICAL SPACE, and the space is the fix (mirrors the
    # Luau). The Hermite was always right about the JOIN - it leaves on the
    # coil's own heading - but in world XZ a cubic whose start tangent is
    # TANGENTIAL and whose endpoint is 31 studs out bulges and then cuts back:
    # radius 11.33 at t=0.74, out to 13.29, back IN to 9.77 (1.53 off the
    # masonry, tighter than the coils themselves), then out to 31. That S is
    # what the playtest read as "the last coil of the tail isn't around the
    # building". In (theta, r, z) the same four boundary conditions describe a
    # continuing spiral: bearing keeps winding, radius grows monotonically off
    # the drum, height falls to the beach.
    k = (t - helix_end) / (1.0 - helix_end)
    k_scale = (1.0 - helix_end) / (helix_end - neck_end)
    p0 = helix(1.0)
    theta0 = rest["bearing"] + rest["turns"] * TAU
    r0 = math.hypot(p0.x, p0.y)
    z0 = p0.z
    d_theta = rest["turns"] * TAU * k_scale
    d_z = ((rest["bottom_z"] - drop) - (rest["top_z"] - drop)) * k_scale
    eps = 0.05
    d_r = ((_spire_radius(z0 + eps) - _spire_radius(z0 - eps)) / (2 * eps)) * d_z
    theta1 = theta0 + rest["tail_turn"] * TAU
    # Height from the SAME expression the Luau uses. `tail_z` was a copy of it
    # and had already drifted 0.61 studs (3.4 against sandY(31) + 1.2 = 2.79),
    # which is exactly the kind of silent divergence this port exists to avoid.
    z1 = _bj_sand_z(rest["tail_out"]) + 1.2
    k2, k3 = k * k, k * k * k
    h00, h10, h01, h11 = 2 * k3 - 3 * k2 + 1, k3 - 2 * k2 + k, 3 * k2 - 2 * k3, k3 - k2
    theta = theta0 * h00 + d_theta * h10 + theta1 * h01 + (rest["tail_turn"] * TAU) * h11
    r = r0 * h00 + d_r * h10 + rest["tail_out"] * h01
    z = z0 * h00 + d_z * h10 + z1 * h01
    return _bj_from_cyl(theta, max(r, _spire_radius(z) + rest["clearance"]), z)


def _bj_sweep_reach(state):
    """How far out the arm reaches. `spiral` contracts it with U, and this one
    function is read by the drawn tip AND by the Luau's hit test."""
    if state.get("attack_kind", "") != "spiral":
        return BJ_SWEEP_REACH
    closed = BJ_SWEEP_INNER + BJ_SPIRAL_CLOSE
    return BJ_SWEEP_REACH + (closed - BJ_SWEEP_REACH) * _smoothstep(
        max(0.0, min(1.0, state.get("attack_u", 0.0)))
    )


def _bj_sweep_bearing_at(state, r):
    """THE ARM IS A DRAG CURVE, NOT A SPOKE. The bearing at radius r trails
    the base bearing in proportion to how far out it is and how fast the base
    is turning - a rigid rotating line has no tail in it."""
    rate = max(-BJ_WHIP_RATE_MAX, min(BJ_WHIP_RATE_MAX, state.get("sweep_rate", 0.0)))
    return state["sweep_angle"] - BJ_WHIP_DRAG * max(r - BJ_SWEEP_INNER, 0.0) * rate


def _bj_swept_cyl(state, t, blend_start):
    """The arm at t, as (UNWRAPPED bearing, radius, height). The branch is
    picked once per state AT THE TIP, because the tip is the part that
    actually swings and so the part that must take the short way round."""
    k = max(0.0, min(1.0, (t - blend_start) / max(1 - blend_start, 1e-3)))
    reach = _bj_sweep_reach(state)
    r = BJ_SWEEP_INNER + (reach - BJ_SWEEP_INNER) * k
    turns = round((_bj_rest_bearing_ref(1.0) - _bj_sweep_bearing_at(state, reach)) / TAU)
    return _bj_sweep_bearing_at(state, r) + turns * TAU, r, _bj_sand_z(r) + state["sweep_height"]


def _bj_swept_point(state, t, blend_start):
    return _bj_from_cyl(*_bj_swept_cyl(state, t, blend_start))


def _bj_fall_amount(state):
    """How far into the death fall. DERIVED from the attack channel - kind
    'collapse' means fall = U - because the Luau's `fall` used to be read by
    the slump and written by nobody, so the collapse eased four values that
    were already at their targets."""
    if state.get("attack_kind", "") == "collapse":
        return max(0.0, min(1.0, state.get("attack_u", 0.0)))
    return max(0.0, min(1.0, state.get("fall", 0.0)))


def _bj_head_sit_z(r):
    """Where a RESTING head's frame must sit at radius r: high enough that the
    skull's lowest solid point rests ON the beach with BJ_HEAD_CLEAR of
    daylight, and no higher. Mirrors BrinejawPath.headSitY, and it is only the
    truth if the pose runs LEVEL there - the head is drawn along the tangent."""
    return _bj_sand_z(r) + BJ_HEAD_UNDER * BJ_HEAD_SCALE + BJ_HEAD_CLEAR


def _bj_slump_point(state, t):
    """Where the head goes when it loses its grip: down, ONTO the sand.

    THE SKULL RESTS ON THE BEACH, WHICH IS NOT THE SAME THING AS THE JOINT
    DOING SO - the playtest's "the serpent's head stays under the sand when
    it's stunned". Two compounding causes, both measured at slump = 1: the old
    z = sand + 2.6 put the joint where the curve then CLIMBED steeply out of
    it, so the drawn frame 8.9 studs along that tangent came out at -0.44
    against a beach at 1.56; and the blend consuming this leaked the reared
    pose in from the first frame, tilting the front of the body by 0.541 per
    stud. The skull's lowest point sat 10.11 studs under the sand. It now runs
    LEVEL for the first BJ_SLUMP_LEVEL of its span and sits on _bj_head_sit_z,
    which leaves the jaw 0.34..1.61 studs clear through the breath cycle."""
    rest = BJ_REST
    drop = _bj_coil_offset(state)
    theta = state["face_angle"]
    fall = _bj_fall_amount(state)
    reach = 26.0 + 8.0 * fall
    k = max(0.0, min(1.0, t / 0.30))
    bottom = rest["bottom_z"] - drop
    r = reach - (reach - (_spire_radius(bottom) + rest["clearance"])) * k
    climb = 9.0 * (max(k - BJ_SLUMP_LEVEL, 0.0) / (1.0 - BJ_SLUMP_LEVEL)) ** 1.5
    z = _bj_head_sit_z(reach + BJ_HEAD_LEAD) + BJ_SLUMP_LIFT - BJ_SLUMP_SETTLE * fall + climb
    return Vector((math.cos(theta) * r, math.sin(theta) * r, z))


# ------------------------------------------------------------ attack shapes
#
# Ported whole from BrinejawPath.luau. Every bearing below is UNWRAPPED and
# continuous in U: each target is the rest head's own bearing plus a swing
# that never wraps. Wrapping here put a 180-degree flip in the middle of the
# bell's recoil - 15.6 studs of body in one step of U.


def _bj_progress(state):
    return max(0.0, min(1.0, state.get("attack_u", 0.0)))


def _bj_envelope(u, entry, exit_):
    """The fade in and out. An attack whose kind is cleared at U < 1 SNAPS."""
    return min(_smoothstep(u / max(entry, 1e-3)), _smoothstep((1 - u) / max(exit_, 1e-3)))


def _bj_aim_cyl(state):
    ax, az = state.get("aim_x", 0.0), state.get("aim_z", 0.0)
    r = math.hypot(ax, az)
    if r < 1e-3:
        return state["face_angle"], BJ_AIM_MIN
    return math.atan2(az, ax), max(BJ_AIM_MIN, min(BJ_AIM_MAX, r))


def _bj_head_rest_cyl(state):
    wrapped, r, z = _bj_cyl_of(_bj_rest_path(0.0, state))
    return _bj_rest_bearing(0.0, wrapped), r, z


def _bj_neck_arc(state, target, target_theta, span, arch, t, level=0.0):
    """The neck, one cylindrical arc from the head's target to where the body
    still grips the tower. LINEAR in k so the arc's tangent DIRECTION is
    constant along its length; ease it and the neck stands itself vertical at
    the joint, which is where ChainPose's frame is undefined."""
    k = max(0.0, min(1.0, t / max(span, 1e-3)))
    a_wrapped, r1, z1 = _bj_cyl_of(_bj_rest_path(span, state))
    t1 = _bj_rest_bearing(span, a_wrapped)
    _, r0, z0 = _bj_cyl_of(target)
    # `level` FLATTENS THE HEAD END ONLY: the height terms run on a parameter
    # that does not start moving until the arc is `level` along, while theta
    # and r stay linear in k. So a planted neck leaves the skull horizontally
    # (which is what the client's 8.9-stud head lead needs) and only then
    # climbs. The warning about easing the parameter is about the FAR end -
    # this eases neither theta nor r, and eases height only away from the
    # joint. Steepest tangent measured after: 81.6 degrees, inside the ~85 cap.
    flat = max(0.0, min(0.5, level))
    kz = max(0.0, min(1.0, (k - flat) / (1.0 - flat)))
    z = z0 + (z1 - z0) * kz + arch * math.sin(math.pi * kz)
    r = r0 + (r1 - r0) * k
    return (
        target_theta + (t1 - target_theta) * k,
        max(r, _spire_radius(z) + BJ_REST["clearance"]),
        z,
    )


def _bj_lunge_target(state, u):
    aim_t, aim_r = _bj_aim_cyl(state)
    th0, r0, z0 = _bj_head_rest_cyl(state)
    swing = _wrap(aim_t - th0)
    cock = BJ_LUNGE_COCK_U
    if u <= cock:
        a = _smoothstep(u / cock)
        return th0 + swing * a, Vector((r0 + (BJ_LUNGE_COCK_R - r0) * a, 0.0, z0 + BJ_LUNGE_RISE * a))
    b = _smoothstep(max(0.0, min(1.0, (u - cock) / (BJ_LUNGE_IMPACT_U - cock))))
    z_top = z0 + BJ_LUNGE_RISE
    # The plant lands on the head-sit, not on a picked 2.4: BJ_LUNGE_SIT moved
    # the NECK JOINT, and the drawn jaw was 4.5 studs inside the beach.
    z_land = _bj_head_sit_z(aim_r)
    return th0 + swing, Vector(
        (BJ_LUNGE_COCK_R + (aim_r - BJ_LUNGE_COCK_R) * b, 0.0, z_top + (z_land - z_top) * b)
    )


def _bj_bell_strike():
    return Vector((BJ_BELL[0], BJ_BELL[1], BJ_BELL[2] + BJ_BELL_LIFT))


def _bj_bell_target(state, u):
    b_t, b_r, b_z = _bj_cyl_of(_bj_bell_strike())
    th0, r0, z0 = _bj_head_rest_cyl(state)
    swing = _wrap(b_t - th0)
    cock_r, cock_z = BJ_BELL_COCK_R, z0 + BJ_BELL_RISE
    windup, impact = BJ_BELL_WINDUP_U, BJ_BELL_IMPACT_U
    if u <= windup:
        a = _smoothstep(u / windup)
        return th0 + swing * 0.55 * a, Vector((r0 + (cock_r - r0) * a, 0.0, z0 + (cock_z - z0) * a))
    if u <= impact:
        b = _smoothstep((u - windup) / (impact - windup))
        return th0 + swing * (0.55 + 0.45 * b), Vector(
            (cock_r + (b_r - cock_r) * b, 0.0, cock_z + (b_z - cock_z) * b)
        )
    c = _smoothstep((u - impact) / (1 - impact))
    return th0 + swing * (1 - c), Vector((b_r + (r0 - b_r) * c, 0.0, b_z + (z0 - b_z) * c))


def _bj_bite_target(state, u):
    """The reactive snap: cock over the aim, snap down, HANG with the jaw on
    the sand (the mini punish window), peel back up. The hang lands on
    _bj_head_sit_z - a head that hangs low is worth nothing if it hangs inside
    the beach, which is what the stagger and the lunge were both doing."""
    aim_t, aim_r = _bj_aim_cyl(state)
    th0, r0, z0 = _bj_head_rest_cyl(state)
    swing = _wrap(aim_t - th0)
    z_land = _bj_head_sit_z(aim_r)
    if u <= BJ_BITE_REAR_U:
        a = _smoothstep(u / BJ_BITE_REAR_U)
        return th0 + swing * a, Vector((r0 + (BJ_BITE_COCK_R - r0) * a, 0.0, z0 + BJ_BITE_RISE * a))
    if u <= BJ_BITE_IMPACT_U:
        b = _smoothstep((u - BJ_BITE_REAR_U) / (BJ_BITE_IMPACT_U - BJ_BITE_REAR_U))
        z_top = z0 + BJ_BITE_RISE
        return th0 + swing, Vector((BJ_BITE_COCK_R + (aim_r - BJ_BITE_COCK_R) * b, 0.0, z_top + (z_land - z_top) * b))
    if u <= BJ_BITE_HANG_U:
        return th0 + swing, Vector((aim_r, 0.0, z_land))
    c = _smoothstep((u - BJ_BITE_HANG_U) / (1.0 - BJ_BITE_HANG_U))
    return th0 + swing * (1 - c), Vector((aim_r + (r0 - aim_r) * c, 0.0, z_land + (z0 - z_land) * c))


def _bj_coilslam_cyl(state, t):
    """The coil slam, in UNWRAPPED cylindrical form: a mid-body loop that
    lifts off the drum, crashes along the aim bearing and LIES ON THE SAND.

    The loop GROWS out over the rise and is dragged back in over the recover -
    laying all 62 studs of it out at U = 0 moved 12.26 studs of body in one
    step of U at 240 steps. The two legs are split by an ANGLE (BJ_SLAM_SPLAY,
    3.8 studs off the line at the tip); a constant lateral offset has to go
    through atan2, and that swung the pose 40.91 studs a step while the loop
    was still growing."""
    aim_t = _bj_aim_cyl(state)[0]
    u = _bj_progress(state)
    k = max(0.0, min(1.0, (t - BJ_SLAM_T0) / (BJ_SLAM_T1 - BJ_SLAM_T0)))
    sgn = 2 * k - 1
    near = BJ_SLAM_INNER + 8.0
    grow = _smoothstep(max(0.0, min(1.0, u / BJ_SLAM_RISE_U)))
    back = _smoothstep(max(0.0, min(1.0, (u - BJ_SLAM_LIE_U) / (0.60 * (1.0 - BJ_SLAM_LIE_U)))))
    outer = near + (BJ_SLAM_OUTER - near) * grow * (1 - back)
    r = BJ_SLAM_INNER + (outer - BJ_SLAM_INNER) * (1 - sgn * sgn)
    ref = _bj_rest_bearing_ref(0.5 * (BJ_SLAM_T0 + BJ_SLAM_T1))
    theta = ref + _wrap(aim_t + BJ_SLAM_SPLAY * sgn - ref)
    if u <= BJ_SLAM_RISE_U:
        lift = BJ_SLAM_LIFT * _smoothstep(u / BJ_SLAM_RISE_U)
    elif u <= BJ_SLAM_IMPACT_U:
        lift = BJ_SLAM_LIFT * (1 - _smoothstep((u - BJ_SLAM_RISE_U) / (BJ_SLAM_IMPACT_U - BJ_SLAM_RISE_U)))
    else:
        lift = 0.0
    return theta, r, _bj_sand_z(r) + BJ_SLAM_SIT + lift


def _bj_rear_offset(state, t):
    """`rear` DISPLACES the front half outward and upward and touches no
    bearing at all, so the coils rear with it. A 'straighten the front into an
    arc' version had to unwind 1.86 turns of coil to reach a straight neck,
    which is both wrong and the fastest way to stand a limb dead vertical."""
    shape = BJ_ATTACK["rear"]
    u = _bj_progress(state)
    rise = _smoothstep(max(0.0, min(1.0, u / BJ_REAR_U))) * _bj_envelope(u, shape["entry"], shape["exit"])
    fade = 1 - _smoothstep(max(0.0, min(1.0, t / shape["span"])))
    return BJ_REAR_OUT * rise * fade, BJ_REAR_LIFT * rise * fade


def _bj_undertow_cyl(state, t):
    """The buried run: the middle third rides under the beach except where the
    travelling bulge lifts it proud. The run EXTENDS with the bulge rather
    than being laid out to full length at U = 0."""
    aim_t, aim_r = _bj_aim_cyl(state)
    inner = BJ_UNDER_INNER
    k = max(0.0, min(1.0, (t - BJ_UNDER_T0) / (BJ_UNDER_T1 - BJ_UNDER_T0)))
    travel = inner + (aim_r - inner) * _bj_progress(state)
    r = inner + ((travel + BJ_UNDER_OVERRUN) - inner) * k
    d = r - travel
    hump = BJ_UNDER_HUMP * math.exp(-(d * d) / (2 * BJ_UNDER_SIGMA * BJ_UNDER_SIGMA))
    ref = _bj_rest_bearing_ref(0.5 * (BJ_UNDER_T0 + BJ_UNDER_T1))
    return ref + _wrap(aim_t - ref), r, _bj_sand_z(r) - BJ_UNDER_DEPTH + hump


def bj_pose_path(state):
    """A path function for any fight state - the Luau's pointAt, in Blender."""

    def path(t):
        t = max(0.0, min(1.0, t))
        point = _bj_rest_path(t, state)
        kind = state.get("attack_kind", "")
        shape = BJ_ATTACK.get(kind)
        mode = shape["mode"] if shape else None

        # EVERY CYLINDRICAL BLEND IS GUARDED BY w > 0, and not just for speed:
        # a round trip through atan2/cos/sin would move the rest pose by a
        # float ulp for nothing. Guarded, the idle pose is bit-identical.
        unwind = state["unwind"]
        if unwind > 0:
            blend_start = 1.0 - 0.40 * unwind
            w = _smoothstep((t - blend_start) / 0.14) * unwind
            if w > 0:
                # CYLINDRICAL, because a positional lerp between a body coiled
                # at bearing 300 and an arm parked at 120 goes straight
                # through the lighthouse - measured 7.98 studs inside the
                # masonry, passing 0.24 studs from the axis.
                th, r, z = _bj_cyl_of(point)
                a_th, a_r, a_z = _bj_swept_cyl(state, t, blend_start)
                point = _bj_cyl_blend(_bj_rest_bearing(t, th), r, z, a_th, a_r, a_z, w)

        slump = state["slump"]
        if slump > 0 and t < 0.34:
            # A PLATEAU, NOT A RAMP FROM THE FIRST FRAME: full weight over the
            # same flat stretch _bj_slump_point runs level through. At the old
            # (0.34 - t) / 0.34 the head carried 0.07% of a pose 55 studs
            # higher one stud of arc in, and the 8.9-stud head lead turned
            # that half-stud-per-stud tilt into 4.81 studs of buried skull.
            w = _smoothstep((0.34 - t) / (0.34 - BJ_SLUMP_LEVEL * 0.30)) * slump
            point = point.lerp(_bj_slump_point(state, t), w)

        if mode == "neck":
            u = _bj_progress(state)
            # The same plateau the slump gets, over the arc's flat `level` run
            # and for the same measured reason: a 0.27% leak of a rest head 52
            # studs higher is 1.2 studs of skull once the lead multiplies it.
            level = shape.get("level", 0.0)
            w = _bj_envelope(u, shape["entry"], shape["exit"]) * _smoothstep(
                (shape["span"] - t) / (shape["span"] * (1 - level))
            )
            if w > 0:
                if kind == "lunge":
                    target_th, target = _bj_lunge_target(state, u)
                elif kind == "bite":
                    target_th, target = _bj_bite_target(state, u)
                else:
                    target_th, target = _bj_bell_target(state, u)
                th, r, z = _bj_cyl_of(point)
                a_th, a_r, a_z = _bj_neck_arc(state, target, target_th, shape["span"], shape["arch"], t, level)
                point = _bj_cyl_blend(_bj_rest_bearing(t, th), r, z, a_th, a_r, a_z, w)
        elif mode == "coilslam" and BJ_SLAM_T0 < t < BJ_SLAM_T1:
            edge = 0.06
            w = _bj_envelope(_bj_progress(state), shape["entry"], shape["exit"]) * _smoothstep(
                min((t - BJ_SLAM_T0) / edge, (BJ_SLAM_T1 - t) / edge)
            )
            if w > 0:
                th, r, z = _bj_cyl_of(point)
                a_th, a_r, a_z = _bj_coilslam_cyl(state, t)
                point = _bj_cyl_blend(_bj_rest_bearing(t, th), r, z, a_th, a_r, a_z, w)
        elif mode == "undertow" and BJ_UNDER_T0 < t < BJ_UNDER_T1:
            edge = 0.06
            w = _bj_envelope(_bj_progress(state), shape["entry"], shape["exit"]) * _smoothstep(
                min((t - BJ_UNDER_T0) / edge, (BJ_UNDER_T1 - t) / edge)
            )
            if w > 0:
                th, r, z = _bj_cyl_of(point)
                a_th, a_r, a_z = _bj_undertow_cyl(state, t)
                point = _bj_cyl_blend(_bj_rest_bearing(t, th), r, z, a_th, a_r, a_z, w)
        elif mode == "rear":
            dr, dz = _bj_rear_offset(state, t)
            if dr > 0 or dz > 0:
                th, r, z = _bj_cyl_of(point)
                point = _bj_from_cyl(th, r + dr, z + dz)

        # Mirrors BrinejawPath: amplitude grows toward the tail so the body
        # whips rather than wobbling, and the last tenth flicks sideways so
        # the rattle - the only hittable part - draws the eye.
        breath = math.sin(t * 9.0 - state["time"] * 1.7) * (0.45 + 1.05 * t * t)
        point = point + Vector((0, 0, breath))
        # The head's sway and bob, damped VERTICALLY when the head is down: a
        # skull lying on the beach cannot rise and fall 1.25 studs (with the
        # jaw 0.95 off the sand it would spend half of every breath inside
        # it), but it can still heave sideways, and the sway is what keeps the
        # punish window alive. Mirrors BrinejawPath's block exactly.
        neck_end = BJ_REST["neck_end"]
        if t <= neck_end:
            k_head = 1 - t / neck_end
            flat = Vector((point.x, point.y, 0.0))
            side = Vector((-flat.y, flat.x, 0.0)).normalized() if flat.length > 0.01 else Vector((0, 1, 0))
            point = point + side * (math.sin(state["time"] * 0.55) * 2.1 * k_head)
            settle = 0.85 * state["slump"]
            point = point + Vector((0, 0, (math.sin(state["time"] * 0.83) * 1.25 * (1 - settle) - breath * settle) * k_head))
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


KR_TENT_BEARING = math.radians(88.0)   # where the staged limbs leave the water - ABEAM
KR_TENT_ROOT_R = 48.0
KR_PLATFORM_X = 96.0                   # authored distance out to the ship

# The preview-only ship proxy. THE REAL SHIP ARENA IS ANOTHER LANE'S FILE and
# none of this is exported: these objects are built by the placer, which runs
# after export(), for exactly the same reason the 5-stud stand-ins are.
#
# SHE IS SIZED TO HER CREW, NOT TO THE KRAKEN, and that is the whole point of
# having her. The first proxy was 76 authored units - 456 studs, a hull as long
# as the animal is tall - and it silently answered the only question the staged
# shot exists to ask: with a ship that big the 5-stud stand-ins were four
# pixels behind a rail as tall as three of them, and the frame said "big
# animal, big boat" instead of "big animal". 30 units is 180 studs, a galleon,
# and the tentacles come out as thick as her beam - which is exactly what the
# reference shows.
KR_SHIP_LEN = 30.0
KR_SHIP_BEAM = 9.0
KR_SHIP_DECK_Z = 0.0
KR_SHIP_MAST_Z = 17.0


def _kr_tentacle_path(side, t):
    """One tentacle REARED OVER THE SHIP: out of the water off the head's
    flank, up into a high arch, and down over the side rail onto the deck.
    This is the shape a SLAM comes out of - ChainPose blends away from it for
    the strike and back to it afterwards - and the rest pose IS the spec.
    t=0 at the water.

    TWO RULES. The limbs leave the water at +/-74 deg, WELL outside the head's
    own footprint, and they bow wider still before they close, so no arch ever
    lies across the face - which is exactly what the retired eight-arm ring
    did. And they come DOWN OVER THE RAIL rather than in from the side: the
    crossing is at |y| ~ 12 with the rail at 4.3, so the limb is visibly
    outboard of the ship one moment and on her deck the next.
    """
    bearing = side * KR_TENT_BEARING
    root = Vector((math.cos(bearing) * KR_TENT_ROOT_R, math.sin(bearing) * KR_TENT_ROOT_R, -8.0))
    x = root.x + (KR_PLATFORM_X + 2.0 - root.x) * t
    y = root.y * (1.0 - 0.925 * t ** 1.6) + side * 31.0 * math.sin(math.pi * t ** 0.8)
    # UP FIRST, then over and down onto the deck: a limb that leaves the water
    # already travelling forward reads as a log floating past the arena, and
    # one that keeps falling past t=1 reads as having gone through the hull.
    if t <= 0.62:
        z = -8.0 + 78.0 * math.sin((t / 0.62) * math.pi * 0.5)
    else:
        z = 70.0 - 64.0 * ((t - 0.62) / 0.38) ** 1.6
    return Vector((x, y, z))


def _kr_ship(made):
    """A PIRATE SHIP PROXY, preview-only and never exported. The kraken is
    staged against a hull because the reference is: a limb arched over a rail
    is the picture, and a limb arched over nothing is a diagram. The real ship
    arena is another lane's file - this is four boxes and a sail, and it must
    never be mistaken for it."""
    cx = KR_PLATFORM_X

    station = _kr_station
    hull = bmesh.new()
    rings = []
    for i in range(11):
        x, beam, deck_z, keel_z = station(i / 10)
        rings.append(ring_pts(x, (deck_z + keel_z) / 2.0, beam, 3.4, sides=10,
                              floor_z=keel_z, ceil_z=deck_z))
    loft(hull, rings)
    # A bowsprit, because the one line that says "pirate" cheapest is a spar
    # sticking out over the water past the stem.
    x, _, deck_z, _ = station(1.0)
    box(hull, (x + 3.2, 0.0, deck_z + 0.8), (7.2, 0.7, 0.7),
        Matrix.Rotation(math.radians(-14), 3, "Y"))
    made.append(finish("KrakenStage_Hull", hull, (0.26, 0.16, 0.11)))

    deck = bmesh.new()
    rings = []
    for i in range(11):
        x, beam, deck_z, _ = station(i / 10)
        rings.append(ring_pts(x, deck_z - 0.35, beam * 0.90, 0.45, sides=8))
    loft(deck, rings)
    x, beam, deck_z, _ = station(0.15)
    box(deck, (x, 0.0, deck_z + 1.0), (6.4, beam * 1.7, 1.8))
    made.append(finish("KrakenStage_Deck", deck, (0.55, 0.42, 0.26)))

    rails = bmesh.new()
    for i in range(11):
        x, beam, deck_z, _ = station(i / 10)
        for side in (-1, 1):
            box(rails, (x, side * beam * 0.96, deck_z + 0.45),
                (KR_SHIP_LEN / 9.6, 0.36, 1.0))
    x, _, deck_z, _ = station(0.52)
    box(rails, (x, 0.0, deck_z + KR_SHIP_MAST_Z / 2.0), (0.9, 0.9, KR_SHIP_MAST_Z))
    box(rails, (x, 0.0, deck_z + KR_SHIP_MAST_Z - 1.4), (0.7, 15.0, 0.7))
    made.append(finish("KrakenStage_Rails", rails, (0.40, 0.28, 0.18)))

    sail = bmesh.new()
    x, _, deck_z, _ = station(0.52)
    box(sail, (x - 0.35, 0.0, deck_z + KR_SHIP_MAST_Z - 5.6), (0.4, 14.0, 8.6))
    made.append(finish("KrakenStage_Sail", sail, (0.17, 0.16, 0.20)))

    sea = bmesh.new()
    box(sea, (KR_PLATFORM_X * 0.40, 0.0, -13.0), (205.0, 150.0, 6.0))
    made.append(finish("KrakenStage_Sea", sea, (0.10, 0.20, 0.26)))


def _kr_figure(bm, at, facing=0.0):
    """A 5-stud humanoid stand-in, in AUTHORED units - so it is drawn 5/SCALE
    of a unit tall, and the whole point of the staged shot is that at that
    size he is a speck at the foot of the thing. "How big is he?" is the one
    question a preview cannot answer by itself; the lens will happily make a
    480-stud animal look like a bath toy."""
    s = 5.0 / KR_SCALE / 5.5
    x, y, z = at
    rot = Matrix.Rotation(facing, 3, "Z")
    box(bm, (x, y, z + 3.6 * s), (0.9 * s, 2.0 * s, 1.8 * s), rot)
    ellipsoid(bm, (x, y, z + 4.9 * s), (0.62 * s, 0.62 * s, 0.62 * s), subdiv=1)
    for side in (-1, 1):
        arm = rot @ Vector((0.0, side * 1.3 * s, 0.0))
        box(bm, (x + arm.x, y + arm.y, z + 3.5 * s), (0.6 * s, 0.6 * s, 1.9 * s), rot)
        leg = rot @ Vector((0.0, side * 0.45 * s, 0.0))
        box(bm, (x + leg.x, y + leg.y, z + 1.4 * s), (0.7 * s, 0.8 * s, 2.8 * s), rot)


def _kr_station(t):
    """The ship proxy's hull station at t (0 astern, 1 at the stem), as
    (x, half beam, deck z, keel z). Shared so the crew stand on the deck the
    SHEER actually put there instead of on a number typed beside it."""
    beam = (KR_SHIP_BEAM / 2.0) * (0.44 + 0.56 * math.sin(math.pi * (0.10 + 0.80 * t)))
    return (KR_PLATFORM_X - KR_SHIP_LEN / 2.0 + t * KR_SHIP_LEN, beam,
            KR_SHIP_DECK_Z + 0.7 + 2.7 * t ** 2.6, -3.6 + 1.9 * t ** 2.4)


def _place_kraken(objects, tentacles=2, ship=True):
    """THE FIGHT, staged: the head towering behind a pirate ship, `tentacles`
    chains arched over her side rails onto the deck, and 5-stud figures
    standing on it. The silhouette is judged as one animal against a ship and
    a man, which is the only way to tell whether "super super huge" is true of
    the geometry or only of the intention - and whether a limb reads as a limb
    or as a string of blocks."""
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
        # shortens it too, and once it is shorter than KR_TENT_SPACING the
        # barrels stop overlapping and the limb ribs up - worst at the tip,
        # where the taper is deepest.
        copy.scale = (length if length is not None else scale, scale, scale)
        made.append(copy)
        return copy

    # The head is ONE CFrame - every piece above was authored in the same
    # space. SiphonCore goes on with the rest of it: leave it out and the
    # siphon is a purple funnel with a hole you cannot see into.
    for part in ("Head", "Cap", "Scrollwork", "Crust", "Eyes", "Pupil", "Lashes",
                 "Barnacles", "Eyespots", "Siphon", "SiphonCore"):
        place(by_name[part], Vector((0, 0, 0)))

    seg, tip, sucker = by_name["TentacleSeg"], by_name["TentacleTip"], by_name["TentacleSucker"]
    for side in [1, -1, 1, -1][:max(tentacles, 1)]:
        at_length, tangent_at, total = _arc_walker(lambda t, s=side: _kr_tentacle_path(s, t))
        count = max(int(total / KR_TENT_SPACING), 3)
        for i in range(count):
            distance = i * KR_TENT_SPACING
            u = distance / total
            scale = 1.0 - 0.42 * u ** 1.15  # heavy at the water, fine at the tip
            length = 1.0 - 0.12 * u  # barely: see place()
            position = at_length(distance)
            tangent = tangent_at(distance)
            place(seg, position, tangent, scale, length)
            # TWO sucker rows along the UNDERSIDE, on a guarded frame (a limb
            # mid-slam points straight up, where a naive cross degenerates).
            up = Vector((0, 0, 1))
            if abs(tangent.dot(up)) > 0.98:
                up = Vector((0, 1, 0))
            lateral = tangent.cross(up).normalized()
            down = lateral.cross(tangent).normalized()
            if down.z > 0:
                down = -down
            if u < 0.95:
                for roll in KR_SUCKER_ROWS:
                    out = (down * math.cos(roll) + lateral * math.sin(roll)).normalized()
                    # Seated on the hide and pointing OUT of it. Handing
                    # `tangent` here lays each disc ALONG the limb instead,
                    # edge-on and invisible - the bug that ate the old ones.
                    place(sucker, position + out * (KR_TENT_RADIUS * 0.90 * scale), out, scale)
        place(tip, at_length(total - 6.0), tangent_at(total - 6.0), 1.0 - 0.42)

    # The ship and the men on her. Built HERE rather than in the pack: they
    # are staging, not boss parts, and the export has already run by the time
    # a placer is called, so they can never reach the glb.
    if not ship:
        return made
    _kr_ship(made)
    bm = bmesh.new()
    for t, y, facing in ((0.34, 1.6, math.pi), (0.56, -1.9, math.pi * 0.86),
                         (0.74, 0.8, math.pi * 1.14)):
        x, _, deck_z, _ = _kr_station(t)
        _kr_figure(bm, (x, y, deck_z + 0.2), facing)
    made.append(finish("KrakenStage_Crew", bm, (0.86, 0.32, 0.24)))
    return made


def _place_kr_interior(objects):
    """PHASE THREE, staged: the gut the player walks into - a tunnel of ribs,
    polyps growing off the floor between them, strands slung across, and a man
    standing in it. Three pieces and a figure, which is the whole kit: enough
    to judge whether the arena can build an inside out of them."""
    by_name = {obj.name.split("_", 1)[1]: obj for obj in objects}
    made = []

    def place(source, position, rot_z=0.0, scale=1.0):
        copy = source.copy()
        copy.data = source.data
        copy.hide_render = False
        bpy.context.collection.objects.link(copy)
        copy.location = position
        copy.rotation_euler = (0.0, 0.0, rot_z)
        copy.scale = (scale, scale, scale)
        made.append(copy)
        return copy

    for i in range(4):
        x = -30.0 + i * 26.0
        place(by_name["RibArch"], Vector((x, 0.0, 0.0)), 0.0, 1.0 - 0.06 * i)
        place(by_name["GutStrand"], Vector((x + 13.0, 0.0, 24.0)), math.pi / 2, 1.0)
    for i, (x, y) in enumerate(((-24.0, 9.0), (-2.0, -11.0), (22.0, 7.0), (44.0, -8.0))):
        place(by_name["Polyp"], Vector((x, y, 0.0)), i * 0.7, 1.0 + 0.1 * (i % 3))
    bm = bmesh.new()
    box(bm, (6.0, 0.0, -2.0), (120.0, 44.0, 4.0))
    _kr_figure(bm, (30.0, 0.0, 0.0), math.pi)
    made.append(finish("KrakenStage_Gut", bm, KR_FLESH))
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
#
# MIRRORS NoctyssPath.MAW, NUMBER FOR NUMBER - the Luau is the source of truth
# for this block, and it was re-solved on 2026-09-09 around one sentence from
# the user: the head "doesn't fit in the hole and obstructs everything". The
# answer is that the PIT ITSELF is her mouth. PITCH and GAPE became a matched
# pair two degrees apart, so the jaw's tilt (PITCH - GAPE) is the floor and
# the floor is nearly level without hoisting the skull thirty studs into the
# air; FORWARD slid the whole thing down the surfacing lane so the OPEN JAW is
# the half that overhangs onto the shelf the party walks in over, rather than
# the braincase hanging over solid stone; and the scale came down 2.4 -> 2.0
# so a 50-stud head is not straddling a 30-stud hole.
NC_MAW = {
    "pitch": 21.0,  # nose-up out of the pit; the jaw's tilt is this minus the gape
    # 284 degrees: she surfaces facing one of the SIX GAPS between the arena's
    # shadow fins, not into a fin. A colossus that rose facing a rock would be
    # the arena fighting its own boss, and the party arrives down these lanes.
    "yaw": 284.0,
    "gape": 19.0,  # degrees the jaw hinges open
    # NoctyssPath.MAW.FORWARD: a HORIZONTAL shift of the skull's origin along
    # the lane she surfaced on, applied AFTER the yaw and BEFORE the pitch.
    # That order is the whole meaning of it - after the yaw so it follows the
    # lane rather than a compass point, before the pitch so it slides her
    # throat forward over the pit instead of up her own nose (which would move
    # the floor the party stands on every time the pitch was tuned). See
    # `_nc_maw_at`, which is the only place it is applied.
    "forward": 3.4,
    # Mirrors NoctyssPath.MAW.Y_UP - solved so the OPEN mouth's floor lands
    # just above the arena's shelf, because that floor is where the party
    # fights. The skull's origin is not the thing that has to be placed.
    "origin_z": 20.4,
    # 2.0 matches Creatures.noctyss body.scale: the skull is 24 studs across
    # against a 30-stud pit mouth - it fits IN the hole now instead of sitting
    # on it - and hitRadius 6 reads as 12 studs of hide, which is what the eye
    # sees.
    "scale": 2.0,
}
NC_STALK_SCALE = 1.0

# NoctyssPath.MAW.Y_DOWN: where she waits, under the shelf. Named rather than
# spelled -26.0 wherever the rise is interpolated, because `maw_rise` is the
# one number the emergence poses below are parameterised on.
# ...AND IT IS -20, NOT -36. NoctyssPath.MAW.Y_DOWN moved when the pit-mouth
# pose was solved and this mirror did not follow, which made every `maw_rise`
# below a fiction: the rise fraction is measured from THIS number, so a render
# at rise 0.5 was drawing the skull sixteen studs low and the herding snap's
# partial rise would have put her jaws under the stone. The Luau is the source
# of truth for this block; it says -20.
NC_MAW_DOWN_Z = -20.0

# NoctyssPath.DOOR / .HERD / .SNAP, mirrored number for number - the head's two
# moves, which are the ones that use the choir as hands.
NC_DOOR = {
    "ahead": 3.0,
    "half": 11.0,
    "margin": 3.0,
    "lead": 1.6,
    "lip_forward": 8.0,  # x scale
    "lip_half": 2.5,  # x scale
    "lane_length": 26.0,  # NoctyssBodyController's LANE_LENGTH
    "lane_t": 0.7,  # ...and its DOOR_LANE_T: the one mark that is not a ramp
}
NC_HERD = {"spread": 5.0}
NC_SNAP = {
    "rise": 1.0,
    "bite": 0.3,
    "sink": 0.9,
    "rise_to": 0.406,  # the PARTIAL rise that is the tell, and not the window
    "margin": 4.0,
    "band": 2.2,  # NoctyssBodyController's SNAP_BAND: the dim fill, inboard
    "tiles": 18,  # ...and its SNAP_TILES
}

# THE BEAM, mirrored from NoctyssPath. These three numbers ARE the lightsweep
# hitbox - `beamHits` is a distance test, a bearing test and a raycast, and
# nothing else - so the wedge the pose renders is built from them directly
# rather than from anything chosen because it looked right.
NC_BEAM_REACH = 74.0
NC_BEAM_INNER = 5.0  # the one safe pocket, directly under the crook
NC_BEAM_HALF_DEG = 9.0

# NoctyssPath.PULSE_PERIOD / .TRUE_LURE_OFFSET. The choir breathes together and
# the true lure breathes against it, and that half-cycle is the whole read the
# fight asks for - so the pose renders drive lantern brightness off this rather
# than lighting all seven the same and calling the tell somebody else's job.
NC_PULSE_PERIOD = 2.6
NC_TRUE_LURE_OFFSET = 0.5

# arena_gen's GL_PIT_R, and NoctyssPath.SHELF_Y. The lurepull telegraph is
# hung off the first and the second is where the party's feet are.
NC_PIT_R = 15.0
NC_SHELF_Z = 1.5

# ------------------------------------------- THE THREE TENTACLE ATTACKS
#
# NoctyssPath.SLAM / .SCYTHE / .JAB, mirrored number for number. These are the
# limb attacks - the ones where the stalk itself is the weapon rather than the
# lantern on the end of it - and they are posed here the way the Luau poses
# them: ONE ROTATION ABOUT THE ROOT AND ONE UNIFORM STRETCH, solved so the eye
# lands exactly on the latched point. Nothing below is authored by eye.
#
# THE LUAU IS THE SOURCE OF TRUTH. If a number here and a number in
# NoctyssPath disagree, this file is wrong, because these renders are how the
# three attacks get argued about before anyone can play them.
#
# Bearings stay in AUTHORED space, like every other angle in this section:
# Blender +Y exports as Roblox -Z, so a bearing here is its own negative in
# the Luau (`authored()`), and a scythe travelling dir = +1 in these degrees
# is dir = -1 in the fight's. The whole solve is mirrored wholesale into
# Blender's frame - up is +Z instead of +Y - and the map between the two is a
# proper rotation, so cross products, shortest-arc rotations and axis-angles
# all carry across with no extra sign.

# NoctyssPath.EYE_R. The lantern is an EYE now: the drawn sphere and the
# creature row's hit sphere are both this radius, and everything that aims at
# a stalk - a slam's target height, the scythe's drag height - measures from
# it, so an eye resting on the stone has its CENTRE one radius up.
NC_EYE_R = 4.0

# The lantern's offset off the END of the curve, in the hood's own frame: the
# pack's NC_BULB times the hood's 0.86 (`_place_stalk`'s hood_scale), which is
# the same pair NoctyssPath's BULB_FORWARD / BULB_DOWN carry. The solver needs
# them as a vector rather than as a place to stand a mesh.
NC_BULB_FORWARD = NC_BULB[0] * 0.86
NC_BULB_DOWN = NC_BULB[2] * 0.86

NC_SLAM = {
    "windup": 1.2,
    "strike": 0.25,
    "live": 0.4,
    "recover": 1.6,
    "rear": math.radians(30.0),
    "rise": 0.12,
    "radius": 7.0,  # the down-line capsule's radius AND the stripe's half-width
    "peel": 0.55,
}
NC_SCYTHE = {
    "bow": 0.9,
    "sweep": 2.2,
    "recover": 1.1,
    "arc": math.radians(75.0),
    "radius": 6.5,
    "reach": 22.0,
    "reach_min": 13.0,
    "reach_max": 30.0,
}
NC_JAB = {
    "coil": 0.5,
    "thrust": 0.12,
    "hold": 0.1,
    "return": 0.45,
    "rear": math.radians(22.0),
    "twist": math.radians(16.0),
    "coil_in": 0.2,
    "radius": 5.5,
}

# NoctyssPath.PHASES: kind -> (windup, strike, recover). One table, built out
# of the three above, so a phase boundary cannot be spelled twice.
NC_ATTACK_PHASES = {
    "stalkslam": (NC_SLAM["windup"], NC_SLAM["strike"], NC_SLAM["recover"]),
    # PHASES.portcullis = PHASES.stalkslam, exactly as the Luau aliases it.
    "portcullis": (NC_SLAM["windup"], NC_SLAM["strike"], NC_SLAM["recover"]),
    "gloomscythe": (NC_SCYTHE["bow"], NC_SCYTHE["sweep"], NC_SCYTHE["recover"]),
    "feelerstrike": (NC_JAB["coil"], NC_JAB["thrust"] + NC_JAB["hold"], NC_JAB["return"]),
}

# `attackGlow`'s ember: the slam snuffs its own lantern over the windup and
# never quite reaches zero, because the eye has to stay an eye or the player
# loses the limb that is about to hit them.
NC_SLAM_EMBER = 0.09

# NoctyssPath's STRETCH_MIN / STRETCH_MAX and its PASSES. The clamp is the
# fight's reach; the three passes are the hood-offset correction converging.
NC_STRETCH_MIN = 0.45
NC_STRETCH_MAX = 1.55
NC_AIM_PASSES = 3


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
    # 6.5, mirroring NoctyssPath: at fall = 1 the curve's height has already
    # collapsed to ~5.9, so a 26-stud drop finished the hood twenty studs
    # INSIDE the shelf and buried every fallen stalk the wreck exists to show.
    p2 = root + Vector((0, 0, height * 0.93 - 6.5 * fall + breath)) + tip + lateral * sway + aim * kick
    inv = 1 - t
    return p0 * (inv * inv) + p1 * (2 * inv * t) + p2 * (t * t)



# ------------------------------------------------------ the attack pose solver
#
# NoctyssPath's `aimFrame`, `slamFrame`, `scytheFrame`, `jabFrame`,
# `attackKeep` and the `stalkCurve` tail that applies them, in Blender's frame.
# A stalk has no joints: what it can do is swing the shape it already is about
# the root welded into its collar and lengthen as it goes, so an attack pose is
# exactly a rotation plus a uniform stretch - and the rotation is SOLVED, so
# "the eye smacks the latched point" is true by construction here for the same
# reason it is true in the game.


def _nc_clamp(x, low, high):
    return low if x < low else (high if x > high else x)


def _nc_safe_unit(v, fallback):
    return v.normalized() if v.length > 1e-5 else Vector(fallback)


def _nc_identity_quat():
    return Matrix.Identity(3).to_quaternion()


def _nc_axis_quat(axis, angle):
    """CFrame.fromAxisAngle, as a quaternion. Both frames are right-handed and
    the Blender->Roblox map is a proper rotation, so the sign carries over."""
    return Matrix.Rotation(angle, 3, Vector(axis)).to_quaternion()


def _nc_socket_root(index):
    """The point the whole pose turns about - `_nc_stalk_path`'s own p0."""
    radius, degrees = NC_SOCKETS[index]
    angle = math.radians(degrees)
    return Vector((math.cos(angle) * radius, math.sin(angle) * radius, NC_REST["root_z"]))


def _nc_rest_curve(index, t, state):
    """`stalkCurve` with `noAttack` set: the same quadratic `_nc_stalk_path`
    builds, WITH THE DRIFT OFF.

    Not an economy. `calm` in the Luau is multiplied by zero the moment an
    attack is on, on both the solid and the drawn path, and the solver is only
    ever asked what shape it is about to swing - so a solver that saw the sway
    and a curve that did not would aim a shape that is not the shape being
    posed. (Measured in the Luau before that line existed: 3.5 studs of
    permanent error on a 4-stud eye.)
    """
    stalk = state["stalks"][index]
    radius, degrees = NC_SOCKETS[index]
    angle = math.radians(degrees)
    inward = Vector((-math.cos(angle), -math.sin(angle), 0.0))
    lateral = Vector((-inward.y, inward.x, 0.0))
    root = _nc_socket_root(index)

    fall = _nc_smoothstep(stalk["fall"])
    height = NC_REST["height"] * (1 - 0.82 * fall)
    bow = NC_REST["bow"] if index % 2 else -NC_REST["bow"]

    rest_tip = inward * NC_REST["crook"] + lateral * (bow * 0.6)
    aim = Vector((math.cos(stalk["beam"]), math.sin(stalk["beam"]), 0.0))
    lean_tip = aim * (NC_REST["crook"] + NC_LEAN_REACH)
    tip = rest_tip.lerp(lean_tip, _nc_smoothstep(stalk["lean"])) + aim * (28.0 * fall)

    p0 = root
    p1 = root + Vector((0, 0, height))
    p2 = root + Vector((0, 0, height * 0.93 - 6.5 * fall)) + tip
    inv = 1 - t
    return p0 * (inv * inv) + p1 * (2 * inv * t) + p2 * (t * t)


def _nc_hood_offset(forward):
    """`hoodOffset`: where the lantern hangs off the end of the curve, for a
    hood pointing `forward`.

    The reason the solve below has to iterate at all: `realUp` is rebuilt from
    WORLD up every pass, so this offset does NOT simply rotate with the limb -
    swing a stalk over and the hood's own up re-derives to something that is
    not the rotated rest up. Roblox's (0,1,0) is Blender's (0,0,1) and its
    (0,0,1) is Blender's (0,-1,0); both fallbacks are mapped, not guessed.
    """
    up = Vector((0.0, -1.0, 0.0)) if abs(forward.z) > 0.99 else Vector((0.0, 0.0, 1.0))
    right = _nc_safe_unit(forward.cross(up), (1.0, 0.0, 0.0))
    real_up = _nc_safe_unit(right.cross(forward), (0.0, 0.0, 1.0))
    return forward * NC_BULB_FORWARD + real_up * NC_BULB_DOWN


def _nc_rest_reach(index, state):
    """`restReach`: the root, the vector root -> END OF THE CURVE, and the
    hood's forward. The bulb at rest is root + c + hoodOffset(forward)."""
    root = _nc_socket_root(index)
    at = _nc_rest_curve(index, 1.0, state)
    before = _nc_rest_curve(index, 0.98, state)
    return root, at - root, _nc_safe_unit(at - before, (0.0, 0.0, 1.0))


def _nc_reach_scale(c, h, distance):
    """`reachScale`: how far to stretch so the lantern lands exactly
    `distance` from the root. The head does not scale with the body, so the
    bulb is at s*c + h and this is the positive root of |s*c + h| = distance."""
    a = c.dot(c)
    if a < 1e-6:
        return 1.0
    b = 2 * c.dot(h)
    k = h.dot(h) - distance * distance
    disc = b * b - 4 * a * k
    if disc <= 0:
        # Nearer than the head is long: it draws in as far as the clamp allows.
        return NC_STRETCH_MIN
    return _nc_clamp((-b + math.sqrt(disc)) / (2 * a), NC_STRETCH_MIN, NC_STRETCH_MAX)


def _nc_aim_frame(state, index, aim):
    """`aimFrame`: the (rotation, stretch) that puts THE EYE on `aim`."""
    root, c, forward = _nc_rest_reach(index, state)
    want = Vector(aim) - root
    distance = want.length
    if distance < 1e-3:
        return _nc_identity_quat(), 1.0
    h = _nc_hood_offset(forward)
    rot, stretch = _nc_identity_quat(), 1.0
    for _ in range(NC_AIM_PASSES):
        stretch = _nc_reach_scale(c, h, distance)
        rot = _nc_safe_unit(c * stretch + h, (0.0, 0.0, 1.0)).rotation_difference(
            _nc_safe_unit(want, (0.0, 0.0, 1.0))
        )
        # Where the hood's offset really ended up, carried back into the rest
        # frame so the next pass solves against the truth.
        h = rot.inverted() @ _nc_hood_offset(rot @ forward)
    return rot, stretch


def _nc_tilt_axis(index, aim):
    """`tiltAxis`: the horizontal axis a limb rocks about to lean TOWARD `aim`,
    and the flat bearing to it. A POSITIVE angle tips it onto the aim; negative
    rears it away, which is every windup in here."""
    root = _nc_socket_root(index)
    flat = _nc_safe_unit(Vector((aim.x - root.x, aim.y - root.y, 0.0)), (1.0, 0.0, 0.0))
    return _nc_safe_unit(Vector((0.0, 0.0, 1.0)).cross(flat), (0.0, -1.0, 0.0)), flat


def _nc_attack_phase(attack, now):
    """`attackPhase`: ("windup" | "strike" | "recover" | "done", 0..1)."""
    spans = NC_ATTACK_PHASES.get(attack["kind"])
    if not spans:
        return "done", 1.0
    t = now - attack.get("start", 0.0)
    if t <= 0:
        return "windup", 0.0
    if t < spans[0]:
        return "windup", t / spans[0]
    t -= spans[0]
    if t < spans[1]:
        return "strike", t / spans[1]
    t -= spans[1]
    if t < spans[2]:
        return "recover", t / spans[2]
    return "done", 1.0


def _nc_is_slam(kind):
    """NoctyssPath's `isSlam`. TWO kinds are: `stalkslam`, and the `portcullis`
    bar, which is a slam in every respect the server can see - same windup,
    same pose, same capsule, same violet stripe. What makes it a door is the
    lane drawn between the two of them, and nothing else."""
    return kind == "stalkslam" or kind == "portcullis"


def _nc_live_span(attack):
    """`liveSpan`: how many seconds this kind's HITBOX is live."""
    if _nc_is_slam(attack["kind"]):
        return NC_SLAM["live"]
    if attack["kind"] == "feelerstrike":
        return NC_JAB["thrust"] + NC_JAB["hold"]
    spans = NC_ATTACK_PHASES.get(attack["kind"])
    return spans[1] if spans else 0.0


def _nc_attack_live(attack, now):
    """`attackLive`, and it is NOT a phase name: the slam's damage deliberately
    outlasts its travel by LIVE - STRIKE, and a mark that faded on the phase
    boundary was fading over players it was still killing."""
    spans = NC_ATTACK_PHASES.get(attack["kind"])
    if not spans:
        return False
    t = now - attack.get("start", 0.0)
    if _nc_is_slam(attack["kind"]):
        return NC_SLAM["windup"] <= t <= NC_SLAM["windup"] + NC_SLAM["live"]
    if attack["kind"] == "feelerstrike":
        coil = NC_JAB["coil"]
        return coil <= t <= coil + NC_JAB["thrust"] + NC_JAB["hold"]
    return _nc_attack_phase(attack, now)[0] == "strike"


def _nc_tell_phase(attack, now):
    """`tellPhase`: (u through the lead-in, is the hitbox live, seconds since it
    changed state) - the three arguments every mark's brightness comes from.

    This is what stops these renders flattering a telegraph. A pose picks an
    INSTANT; what is drawn on the stone at that instant is then whatever the
    fight would have drawn, including nothing at all.
    """
    spans = NC_ATTACK_PHASES.get(attack["kind"]) if attack else None
    if not spans:
        return 1.0, False, NC_TELL_FADE
    t = now - attack.get("start", 0.0)
    if _nc_attack_live(attack, now):
        return 1.0, True, t - spans[0]
    if t <= spans[0]:
        return _nc_clamp(t / max(spans[0], 1e-3), 0.0, 1.0), False, None
    return 1.0, False, t - (spans[0] + _nc_live_span(attack))


def _nc_attack_glow(attack, now):
    """`attackGlow`: how lit the lantern is ALLOWED to be while its limb is
    swinging - a multiplier that can only ever take light away. The slam
    snuffs to an ember; the scythe stays lit, because the pool of light on the
    stone IS its telegraph."""
    if not _nc_is_slam(attack["kind"]):
        return 1.0
    phase, u = _nc_attack_phase(attack, now)
    ember = NC_SLAM_EMBER
    if phase == "windup":
        return 1 - (1 - ember) * _nc_smoothstep(u)
    if phase == "recover":
        return ember + (1 - ember) * _nc_smoothstep((u - 0.3) / 0.7)
    return ember


def _nc_slam_frame(state, index, attack):
    """`slamFrame`. Windup rocks BACK off the line and stretches up; the strike
    is quadratic into the landed pose, so most of the travel is in the last few
    frames - a crack, not a fall."""
    phase, u = _nc_attack_phase(attack, state.get("time", 0.0))
    axis, _ = _nc_tilt_axis(index, attack["target"])
    reared = _nc_axis_quat(axis, -NC_SLAM["rear"])
    rise = NC_SLAM["rise"]
    if phase == "windup":
        e = _nc_smoothstep(u)
        return _nc_identity_quat().slerp(reared, e), 1 + rise * e
    landed, stretch = _nc_aim_frame(state, index, attack["target"])
    if phase == "strike":
        e = u * u
        return reared.slerp(landed, e), (1 + rise) + (stretch - 1 - rise) * e
    return landed, stretch


def _nc_scythe_travel(attack, now):
    """`scytheTravel`: how far round its arc the sweep has gone, 0..1. Mostly
    eased with a linear floor - pure smoothstep bolts through the middle, which
    is the part a player needs time to read."""
    phase, u = _nc_attack_phase(attack, now)
    if phase == "windup":
        return 0.0
    if phase != "strike":
        return 1.0
    return 0.15 * u + 0.85 * _nc_smoothstep(u)


def _nc_scythe_point(index, attack, travel):
    """`scythePoint`: where the eye is dragging - on the shelf, ONE EYE-RADIUS
    UP, `reach` studs from its own socket. The hit anchor and the centre of the
    pool of light are one point."""
    start = attack.get("from", math.radians(NC_SOCKETS[index][1]))
    arc = attack.get("arc", NC_SCYTHE["arc"])
    direction = -1 if attack.get("dir", 1) < 0 else 1
    reach = attack.get("reach", NC_SCYTHE["reach"])
    phi = start + direction * arc * _nc_clamp(travel, 0.0, 1.0)
    root = _nc_socket_root(index)
    return Vector((root.x + math.cos(phi) * reach, root.y + math.sin(phi) * reach, NC_SHELF_Z + NC_EYE_R))


def _nc_scythe_frame(state, index, attack):
    """`scytheFrame`: bow onto the arc's first point, then keep aiming at a
    point that walks round the arc. The drag falls out of the aim, so there is
    no second animation for the sweep and nothing to disagree with."""
    now = state.get("time", 0.0)
    phase, u = _nc_attack_phase(attack, now)
    aim = _nc_scythe_point(index, attack, _nc_scythe_travel(attack, now))
    landed, stretch = _nc_aim_frame(state, index, aim)
    if phase == "windup":
        e = _nc_smoothstep(u)
        return _nc_identity_quat().slerp(landed, e), 1 + (stretch - 1) * e
    return landed, stretch


def _nc_jab_frame(state, index, attack):
    """`jabFrame`: coil into an S - rocked back off the aim and rolled about
    it, against the resting bow the shape already carries - then a cubic
    ease-out into the landed pose, which is a piston rather than a swing."""
    phase, u = _nc_attack_phase(attack, state.get("time", 0.0))
    axis, flat = _nc_tilt_axis(index, attack["target"])
    coiled = _nc_axis_quat(axis, -NC_JAB["rear"]) @ _nc_axis_quat(flat, NC_JAB["twist"])
    drawn = 1 - NC_JAB["coil_in"]
    if phase == "windup":
        e = _nc_smoothstep(u)
        return _nc_identity_quat().slerp(coiled, e), 1 - NC_JAB["coil_in"] * e
    landed, stretch = _nc_aim_frame(state, index, attack["target"])
    if phase == "strike":
        # The strike span is the spear AND the beat it holds out there; the
        # spear itself is only the first fraction of it.
        span = NC_JAB["thrust"] / (NC_JAB["thrust"] + NC_JAB["hold"])
        e = 1 - (1 - _nc_clamp(u / span, 0.0, 1.0)) ** 3
        return coiled.slerp(landed, e), drawn + (stretch - drawn) * e
    return landed, stretch


NC_ATTACK_FRAMES = {
    "stalkslam": _nc_slam_frame,
    "portcullis": _nc_slam_frame,  # a bar is a slam; see `_nc_is_slam`
    "gloomscythe": _nc_scythe_frame,
    "feelerstrike": _nc_jab_frame,
}


def _nc_attack_keep(attack, now, t):
    """`attackKeep`: how much of the pose is still on at curve parameter `t`.
    The slam lets go BASE-FIRST - a release front travelling collar to hood,
    which is what a whip reversing looks like. The other two release as one,
    because a jab that peeled would stop being a snap."""
    phase, u = _nc_attack_phase(attack, now)
    if phase == "done":
        return 0.0
    if phase != "recover":
        return 1.0
    if not _nc_is_slam(attack["kind"]):
        return 1 - _nc_smoothstep(u)
    width = NC_SLAM["peel"]
    front = u * (1 + width)
    return _nc_smoothstep((t - front + width) / width)


def _nc_attack_frame(state, index, attack):
    """The frame, cached for the instant it was asked about - `posed`'s own
    cache. `_arc_walker` takes 800 samples per stalk and the answer cannot
    change inside one of them, because it is a function of `time` alone."""
    now = state.get("time", 0.0)
    if attack.get("_frame_at") != now:
        attack["_frame_at"] = now
        attack["_frame"] = NC_ATTACK_FRAMES[attack["kind"]](state, index, attack)
    return attack["_frame"]


def _nc_posed_path(index, t, state):
    """`stalkCurve`'s tail: the rest shape, swung about the root it is welded
    into. A stalk with no attack on it is `_nc_stalk_path` untouched, which is
    what keeps every other pose in this file byte-identical."""
    attack = (state.get("attacks") or {}).get(index)
    if not attack:
        return _nc_stalk_path(index, t, state)
    point = _nc_rest_curve(index, t, state)
    keep = _nc_attack_keep(attack, state.get("time", 0.0), t)
    if keep <= 0.002:
        return point
    rot, stretch = _nc_attack_frame(state, index, attack)
    rot = _nc_identity_quat().slerp(rot, keep)
    stretch = 1 + (stretch - 1) * keep
    root = _nc_socket_root(index)
    point = root + (rot @ ((point - root) * stretch))
    # NOTHING REACHES THROUGH THE STONE, and it LETS GO BEFORE THE HOOD: a
    # clamp still biting at t = 0.98 would tilt the tangent the eye is measured
    # from and walk the eye off the point the whole attack was aimed at. Faded
    # out over the last quarter, exactly as the Luau fades it.
    guard = 1 - _nc_smoothstep((t - 0.75) / 0.2)
    if guard > 0:
        lift = NC_SHELF_Z + 0.4 - point.z
        if lift > 0:
            point = point + Vector((0.0, 0.0, lift * guard))
    return point


def _nc_bulb_position(index, state):
    """`bulbPosition`: WHERE THE EYE ACTUALLY IS - the end of the posed curve
    plus the hood's offset, built on a WORLD-UP frame exactly as the Luau
    builds it. This one point is the server's hitbox, the frozen beam apex and
    the client's light anchor.

    AND IT IS NOT `hood_matrix @ NC_BULB`. `_place_stalk` orients the hood mesh
    with `rotation_difference` - the SHORTEST arc from +X onto the tangent -
    which carries whatever roll falls out of the geometry, and on a limb lying
    flat along a slam line that roll walks the mesh's own lantern 3.7 studs off
    the point the attack was aimed at. The pack has always placed the hood that
    way and it is fine at rest, where the two frames agree; the moment a limb
    swings over it is a real disagreement between the mesh and the fight, so
    the EYE is drawn here, at the fight's number, and the little cage-and-bulb
    mesh is left where the placer puts it. The gap between them in these three
    frames is that disagreement, at its own size.
    """
    at = _nc_posed_path(index, 1.0, state)
    before = _nc_posed_path(index, 0.98, state)
    return at + _nc_hood_offset(_nc_safe_unit(at - before, (0.0, 0.0, 1.0)))


def _nc_stalk_reach(state, index):
    """`stalkReach`: how far this socket's eye can get from its root, in studs.
    About 12 to 50 at rest - which is why a slam threatens most of the shelf
    and not all of it, and why standing at the rim is a real answer."""
    _, c, forward = _nc_rest_reach(index, state)
    h = _nc_hood_offset(forward)
    return (c * NC_STRETCH_MIN + h).length, (c * NC_STRETCH_MAX + h).length


def _nc_aim_point(x, y):
    """`aimPoint`: where a lantern can sit ON a point of floor - one eye-radius
    up. A slam aimed at a player's chest would drive the limb through stone."""
    return Vector((x, y, NC_SHELF_Z + NC_EYE_R))


def _nc_clamp_to_reach(state, index, target):
    """`clampToReach`: pull a target inside the arm, KEEPING ITS HEIGHT, so
    what gets latched, drawn and tested is a point the eye will arrive at."""
    root = _nc_socket_root(index)
    near, far = _nc_stalk_reach(state, index)
    span = Vector(target) - root
    if near <= span.length <= far:
        return Vector(target)
    want = _nc_clamp(span.length, near, far)
    flat = Vector((span.x, span.y, 0.0))
    radius = math.sqrt(max(want * want - span.z * span.z, 1.0))
    return root + _nc_safe_unit(flat, (1.0, 0.0, 0.0)) * radius + Vector((0.0, 0.0, span.z))


def _nc_set_attack(state, attack):
    """`setAttack`: arm one, filling the scythe's four sweep parameters here
    rather than at the call site, so a pose and a descriptor that crossed the
    wire describe the same sweep. The attack lands in `state["attacks"]`, which
    is what `_nc_posed_path` reads."""
    index = attack["index"]
    attack["start"] = attack.get("start", 0.0)
    attack["target"] = _nc_clamp_to_reach(state, index, attack["target"])
    if attack["kind"] == "gloomscythe":
        root = _nc_socket_root(index)
        to = Vector((attack["target"].x - root.x, attack["target"].y - root.y, 0.0))
        near, far = _nc_stalk_reach(state, index)
        # The eye rides one radius off the stone, so the far end of the band
        # has to be somewhere the limb can actually put it.
        lift = NC_SHELF_Z + NC_EYE_R - root.z
        armed = math.sqrt(max(far * far - lift * lift, 1.0))
        attack["reach"] = _nc_clamp(
            attack.get("reach", to.length),
            max(NC_SCYTHE["reach_min"], math.sqrt(max(near * near - lift * lift, 1.0))),
            min(NC_SCYTHE["reach_max"], armed),
        )
        attack["arc"] = attack.get("arc", NC_SCYTHE["arc"])
        attack["dir"] = -1 if attack.get("dir", 1) < 0 else 1
        # Half an arc BEHIND the latched bearing, so the sweep travels THROUGH
        # where the target was standing rather than stopping at it.
        attack["from"] = attack.get("from", math.atan2(to.y, to.x) - attack["dir"] * attack["arc"] * 0.5)
    attack.pop("_frame_at", None)
    state.setdefault("attacks", {})[index] = attack
    # `attackGlow` is a multiplier on whatever the pulse was already showing,
    # and so is `douse` (`_nc_pulse` multiplies by 1 - douse) - so the snuff is
    # carried on the state the renderer already reads, rather than by teaching
    # `render_nc_pose` a second way to dim a lantern.
    glow = _nc_attack_glow(attack, state.get("time", 0.0))
    stalk = state["stalks"][index]
    stalk["douse"] = max(stalk["douse"], 1.0 - glow)
    return attack


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


def _nc_maw_base(at, pitch_deg, yaw_deg, scale):
    """The skull's frame - NoctyssPath.mawCFrame, composed the way the SERVER
    composes it: yaw about up, then pitch, and no roll at all.

    This used to be `Vector((1, 0, 0)).rotation_difference(forward)`, which is
    the SHORTEST arc onto the aim vector - and the shortest arc between two
    directions carries whatever roll falls out of the geometry. At the shipped
    pose (yaw 284, pitch 26) that laid the head over by 20 degrees: the jaw
    hinge tilted, one eye high, and the scoop the party stands in sloped. The
    Luau builds it as CFrame.Angles(0, -yaw, 0) * CFrame.Angles(0, 0, pitch),
    which cannot produce that, so the render was flattering a pose the fight
    could not hold - and the mouth's floor, of all things, has to be level.

    Blender's +Y is Roblox's -Z (export_yup), so a Roblox yaw about +Y of
    `angle` is a Blender yaw about +Z of the same angle, and a Roblox pitch
    about +Z is a Blender pitch about -Y. Both signs are checked against
    `_place_maw`'s jaw hinge, which swings the jaw DOWN in either reading.
    """
    return (
        Matrix.Translation(Vector(at))
        @ Matrix.Rotation(math.radians(yaw_deg), 4, "Z")
        @ Matrix.Rotation(-math.radians(pitch_deg), 4, "Y")
        @ Matrix.Diagonal((scale,) * 3).to_4x4()
    )


def _nc_maw_at(z):
    """The skull ORIGIN's world position at height `z` - NoctyssPath.MAW.FORWARD,
    mirrored, and the ONLY place the shift is applied.

    The Luau composes `CFrame.new(at) * Angles(0, -yaw, 0) * CFrame.new(FORWARD, 0, 0)
    * Angles(0, 0, PITCH)`: after the yaw, so the shift runs down the lane she
    surfaced on, and before the pitch, so it is HORIZONTAL.

    `_nc_maw_base` composes Translation(at) @ RotZ(yaw) @ RotY(-pitch), and

        Translation(at) @ RotZ(yaw) @ Translation(f, 0, 0)
            == Translation(at + RotZ(yaw) @ (f, 0, 0)) @ RotZ(yaw)

    exactly - so folding the shift into the origin here is the same frame the
    server builds, not an approximation of it, and `_nc_maw_base` itself stays
    the plain yaw-then-pitch it has always been.

    Blender +Y is Roblox -Z, and a Roblox yaw about +Y of `angle` is a Blender
    yaw about +Z of the same angle (the sign note in `_nc_maw_base`), so the
    yawed +X axis is (cos yaw, sin yaw, 0) with no extra sign.
    """
    yaw = math.radians(NC_MAW["yaw"])
    return (math.cos(yaw) * NC_MAW["forward"], math.sin(yaw) * NC_MAW["forward"], z)


def _nc_maw_z(rise):
    """Where the skull's origin sits at `rise` - NoctyssPath.mawCFrame, whose
    rise runs through `smoothstep`. The eased curve is why the emergence pose
    at rise 0.5 is a real frame of the rise rather than a linear fiction."""
    return NC_MAW_DOWN_Z + (NC_MAW["origin_z"] - NC_MAW_DOWN_Z) * _nc_smoothstep(rise)


def _nc_mouth_frame(base, gape_deg, scale):
    """WHERE THE PARTY STANDS - NoctyssPath.mawMouth, as an unscaled world
    frame (the Luau's mouth CFrame has no scale, and `insideMouth` measures
    world studs in it, so this one must not carry the skull's 2.4 either).

    The jaw's hinge swing is applied first, exactly as `_place_maw` applies it
    to the drawn jaw: the floor is inside the LOWER jaw, and a mouth derived
    from the skull alone sits about thirteen studs off the scoop it is meant
    to be the inside of.
    """
    hinge = Vector(NC_JAW_HINGE)
    gape = (
        Matrix.Translation(hinge)
        @ Matrix.Rotation(math.radians(gape_deg), 4, "Y")
        @ Matrix.Translation(-hinge)
    )
    # (-1.2, -7.1) are in the jaw's own units and get the skull's scale; the
    # +0.6 that lifts the slab's top face to the floor is WORLD studs, hence
    # the one division. Same split as the Luau's `-7.1 * scale + 0.6`.
    at = base @ gape @ Matrix.Translation(Vector((-1.2, 0.0, -7.1 + 0.6 / scale)))
    return Matrix.Translation(at.translation) @ at.to_quaternion().to_matrix().to_4x4()


def _place_maw(by_name, at, pitch_deg, yaw_deg, gape_deg, scale):
    """The maw, risen and gaping. Skull and jaw are two CFrames, and the jaw's
    is the skull's turned about the authored hinge - exactly what the client
    does, so the render cannot flatter a pose the game cannot hold."""
    base = _nc_maw_base(at, pitch_deg, yaw_deg, scale)
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
    maw_at = _nc_maw_at(NC_MAW["origin_z"])
    maw_base = _nc_maw_base(maw_at, NC_MAW["pitch"], NC_MAW["yaw"], maw_scale)
    _place_maw(by_name, maw_at, NC_MAW["pitch"], NC_MAW["yaw"], NC_MAW["gape"], maw_scale)
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

    # THE PIT SHOT (assets/boss_noctyss_in_pit.png). The whole point of the
    # 2026-09-09 placement pass is that THE HOLE IN THE FLOOR IS HER MOUTH -
    # you walk down a lane, and the pit you were told to stay out of turns out
    # to be open and full of teeth. That reads from exactly one height, a
    # player's, and from exactly one side, the party's, so this frame is taken
    # standing on the shelf five studs up, on her own surfacing bearing,
    # looking in. Same scene, same pose, same fight lights as the two staged
    # shots above - it is placed BEFORE the head close-up on purpose, so it
    # never sees that frame's extra key light or its exposure trim.
    pit_forward = maw_base.to_3x3() @ Vector((1.0, 0.0, 0.0))
    pit_forward = Vector((pit_forward.x, pit_forward.y, 0.0)).normalized()
    pit_lateral = Vector((-pit_forward.y, pit_forward.x, 0.0))
    pit_cam_data = bpy.data.cameras.new("CamPit")
    pit_cam_data.lens = 28
    cam = bpy.data.objects.new("CamPit", pit_cam_data)
    # NC_SHELF_Z + 5: a Roblox humanoid's eyes over the arena floor. Nothing
    # about this height is chosen to flatter the mesh - it is where the fight
    # is seen from, and if the head reads as a wall from here it IS a wall.
    cam.location = pit_forward * 58.0 + pit_lateral * 16.0 + Vector((0.0, 0.0, NC_SHELF_Z + 5.0))
    # AIMED AT THE THROAT. The first cut of this frame aimed at the mouth's own
    # origin, which is the middle of the floor slab and therefore practically
    # at the shelf - so from an eye-height camera the lens looked slightly DOWN
    # and filled itself with the outside of the lower jaw, which at full gape
    # is laid forward onto the shelf between the party and the pit. The gullet
    # is the far end of the room, up behind the tooth line: aiming there is
    # what puts the opening in the frame instead of the chin in front of it.
    pit_aim = maw_base @ Vector(NC_GULLET)
    cam.rotation_euler = (pit_aim - cam.location).to_track_quat("-Z", "Y").to_euler()
    bpy.context.collection.objects.link(cam)
    scene.camera = cam
    scene.render.filepath = path_out.replace("_staged.png", "_in_pit.png")
    bpy.ops.render.render(write_still=True)
    print("BOSS IN PIT:", scene.render.filepath)

    # THE HEAD, CLOSE. The redesign is a shape argument - a crescent jaw, a
    # braincase that got out of its way, needles, and a lure hung over the
    # door - and none of that is legible in a shot framed on a 130-stud arena.
    # Same scene, same pose, same fight lights: only the lens moves.
    head_cam = bpy.data.cameras.new("CamHead")
    head_cam.lens = 40
    cam = bpy.data.objects.new("CamHead", head_cam)
    # ON HER OWN BEARING, and LEVEL WITH THE MOUTH. Two things decide this
    # frame. Yaw 284 exists so she surfaces facing a GAP between two sockets,
    # and that gap is the one sightline into this arena that seven 35-stud
    # stalks do not stand in - so the camera goes down her bearing, with just
    # enough sideways for a three-quarter. And the height is taken in WORLD
    # studs, not in her frame: pitch turns "a little below the skull's axis"
    # into tens of studs in the air looking down at her crown, which is the one
    # angle that hides both the gape and the profile.
    #
    # RE-FRAMED with the 2026-09-09 placement. This lens was solved against the
    # old pose - scale 2.4, origin 30.7, pitch 26 - and stood 138 studs off. The
    # head is a fifth smaller and sits ten studs lower now, so the same camera
    # rendered a thumbnail in an empty sky. Same bearing, same three-quarter,
    # half the standoff.
    forward = maw_base.to_3x3() @ Vector((1.0, 0.0, 0.0))
    forward = Vector((forward.x, forward.y, 0.0)).normalized()
    lateral = Vector((-forward.y, forward.x, 0.0))
    cam.location = forward * 68.0 + lateral * 33.0 + Vector((0.0, 0.0, 17.0))
    aim = forward * 8.0 + Vector((0.0, 0.0, 14.0))
    cam.rotation_euler = (aim - cam.location).to_track_quat("-Z", "Y").to_euler()
    bpy.context.collection.objects.link(cam)
    scene.camera = cam
    # A single raking key off the camera's shoulder, for THIS frame only. The
    # arena lights this head with seven point lamps forty studs away and it
    # renders as a black wedge; a review shot that cannot show the teeth is not
    # showing the thing it was asked to show. It is a lamp, not a tone curve -
    # the arena's blacks and the fight's own lights are untouched, and no other
    # render in this file sees it.
    key = bpy.data.objects.new("HeadKey", bpy.data.lights.new("HeadKey", "SUN"))
    key.rotation_euler = (math.radians(62), 0, math.radians(-118))
    key.data.energy = 0.9
    bpy.context.collection.objects.link(key)
    # Her throat is an 11 kW lamp forty studs from this lens and it WILL clip -
    # that is the fight, not the render. Down a stop and a bit so the skull
    # around it stays readable instead of being a black rim on a white hole;
    # the same trade the mawopen pose makes, and it is the last thing this
    # function does, so no other frame sees it.
    scene.view_settings.exposure = -1.2
    scene.render.filepath = path_out.replace("_staged.png", "_head_redesign.png")
    bpy.ops.render.render(write_still=True)
    print("BOSS HEAD:", scene.render.filepath)


def _rf_swim_path(t):
    """Rimefang's preview line.

    Whales do NOT serpentine: a sine down the whole body reads as an eel and
    would throw away the one thing the silhouette is for. The forebody runs
    almost straight and the flex grows toward the peduncle, which is how a
    whale actually swims - and how the fight's breach arc is shaped too.
    """
    return Vector((-t * 54.0, math.sin(t * 1.15 * math.pi) * (1.6 + 7.4 * t * t), 4.2 * (1 - t) ** 2))


# Mirrored in RimefangBodyController (FIN_AT / RIME_AT / PEC_AT) so the render
# and the game station the fittings in the same places.
RF_FIN_AT = 0.42
RF_FIN_LIFT = 6.6
RF_RIME_AT = 0.50
RF_PEC_AT = 0.20


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
    # Where the head ended up, for _rf_extra_views: the face shot has to stand
    # IN FRONT of the animal, and "in front" is the swim path's tangent, not a
    # world axis - the first pass guessed +X and photographed the back of the
    # skull.
    globals()["_RF_HEAD_AT"] = (head_at.copy(), tangent_at(0).copy())
    # NO "Rime" HERE ANY MORE - that was the white slab on the head. The saddle
    # is a body fitting now, stationed below with the dorsal.
    for name in ("Head", "Jaw", "TeethUpper", "TeethLower", "Eyes"):
        place(by_name[name], head_at, tangent_at(0), 1.0)

    fin_d = total * RF_FIN_AT
    place(by_name["Fin"], at_length(fin_d), tangent_at(fin_d), 1.0, lift=RF_FIN_LIFT * _rf_girth(fin_d / total))

    # The saddle, just behind the dorsal and on the same kind of mount, so it
    # rides the body curve and banks with the back.
    rime_d = total * RF_RIME_AT
    place(
        by_name["Rime"],
        at_length(rime_d),
        tangent_at(rime_d),
        1.0,
        lift=RF_SADDLE_LIFT * _rf_girth(rime_d / total),
    )

    pec_d = total * RF_PEC_AT
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


def _rf_extra_views(path_out, placed):
    """Two more angles, because the whale fails in ways one frame cannot show.

    The default preview frames the WHOLE 54-stud body from the bow quarter, at
    which size a flat face and a plate dorsal both look fine. The redesign's
    acceptance test is the head, so:
      face    - a 3/4 front shot framed on the FOREBODY, showing the melon,
                the rostrum's drop, the eye patch and the dorsal behind it.
      profile - dead side-on: the silhouette. A fluke's notch, the dorsal's
                falcate trailing edge and the saddle all live in this one.
    """
    lo = Vector((math.inf, math.inf, math.inf))
    hi = Vector((-math.inf, -math.inf, -math.inf))
    for obj in placed:
        for corner in obj.bound_box:
            world = obj.matrix_world @ Vector(corner)
            lo = Vector((min(lo[i], world[i]) for i in range(3)))
            hi = Vector((max(hi[i], world[i]) for i in range(3)))
    head_at, forward = _RF_HEAD_AT
    right = forward.cross(Vector((0, 0, 1))).normalized()
    up = Vector((0, 0, 1))
    face_focus = head_at + forward * 3.0 + up * 1.0
    whole = (lo + hi) / 2
    span = max((hi - lo).length, 1.0)
    scene = bpy.context.scene
    cam = scene.camera
    for suffix, focus, position, lens in (
        ("face", face_focus + forward * -17.0, face_focus + forward * 52.0 + right * 34.0 + up * 20.0, 42),
        ("profile", whole + up * 2.0, whole + right * span * 1.15 + up * span * 0.10, 50),
    ):
        cam.data.lens = lens
        cam.location = position
        cam.rotation_euler = (focus - cam.location).to_track_quat("-Z", "Y").to_euler()
        scene.render.filepath = path_out.replace("_preview.png", "_preview_%s.png" % suffix)
        bpy.ops.render.render(write_still=True)
        print("BOSS PREVIEW:", scene.render.filepath)


PREVIEW_CAMS = {
    # Off the bow quarter and lifted, chosen AGAINST THE STAGED LIMBS rather
    # than for composition: the two reared tentacles leave the water at +/-74
    # deg and land on the platform's edges, so a camera on the centreline
    # watches the near one descend straight across the maw. 28 deg round puts
    # the frame between them - the eyes, the mouth and both limbs, with
    # nothing lying over the face.
    "kraken": (0.52, -0.76, 0.36),
    # A boss that never moves is judged from the angle it is PLAYED at:
    # high, pitched down ~37 deg, off the stern quarter so the canted
    # deck, the broadside and the Admiral are all in one frame.
    "wrack": (-0.55, 0.72, 0.68),
    # The colossus is JAW-FIRST and rooted, so the parts-sheet preview is
    # taken from its front quarter and only a little above the crown: the
    # two things the redesign has to prove - the arms rooting at the FRONT
    # shoulders either side of the jaw, and nothing on the crown - are both
    # invisible from the default 3/4 rear-ish angle.
    "gnashroot": (0.86, -0.44, 0.28),
}

# Bosses that get EXTRA preview angles after the standard one, as
# fn(path_out, placed_objects). A boss with no entry renders exactly what it
# always did.
EXTRA_VIEWS = {
    "rimefang": _rf_extra_views,
}

# ---------------------------------------------------------------- gnashroot
#
# THE ARM CURVE IS THE CLIENT'S CURVE, byte for byte in shape. It used to be a
# quadratic BEZIER here and a quadratic THROUGH the elbow in GnashrootPath -
# two different curves through the same three points, so every preview in
# `assets/` was of an arm the game never draws. `_gn_through` is
# GnashrootPath's `through`, and `GN_POSE` below is its POSE table: one shape,
# one arc length, one pitch.

# Each entry is { elbow, wrist } for the +1 flank, AUTHORED, and it is the
# same table as GnashrootPath.POSE - one table, two languages, and the
# HANDOFF block re-measures every row of it at build time so the two cannot
# drift in silence.
#
# RE-AUTHORED FOR THE UPRIGHT BODY (2026-09-12, second pass). The socket moved
# from (6.0, 9.2, 20.5) on a horizontal mound to (2.81, 8.55, 21.40) on the
# widest ring of a vertical torso, so every joint below moved with it: the
# arms now hang FORWARD AND DOWN off real shoulders to the mud, which is the
# silhouette the redesign is for.
#
# THE ARC LENGTHS ARE THE POINT OF THE TUNING. GnashrootBodyController draws a
# FIXED eight vertebrae and stretches them to cover whatever arc a pose comes
# to, between STRETCH_MIN 0.85 and STRETCH_MAX 1.30; past the top of that the
# clamp bites and a gap opens at the wrist - a hand detached from its arm.
# Every pose here is authored to within 0.97..1.07 of the 25.608-stud rest
# arc (measured: gnash 0.979, disgorge 0.993, heaveBrace 0.996, hammerRaised
# 1.038, hammerLanded 1.040, wallow 1.040, mire 1.048, heavePlant 1.068), so
# the clamp is never reached and no pose in the book can pull a hand off.
#
# THE WRIST z IS SET AGAINST THAT POSE'S LEAN, not against the mud: the body
# pitches about the mud line, so a ground-contact pose carries
# z = x * tan(its lean) and the fist lands ON the surface when the pose is
# fully reached. Re-tune a lean in GnashrootPath and its wrist z moves here.
GN_POSE = {
    "rest": ((9.5, 13.0, 13.5), (17.5, 11.0, 2.00)),
    "gnash": ((6.5, 17.0, 15.5), (13.0, 14.5, 3.97)),
    "wallow": ((11.5, 15.0, 11.5), (21.5, 14.5, 5.36)),
    "disgorge": ((9.5, 18.0, 19.5), (21.0, 19.0, 13.00)),
    "heavePlant": ((14.8, 10.4, 12.0), (24.0, 10.5, 4.23)),
    "heaveBrace": ((8.5, 16.0, 14.5), (14.0, 14.0, 2.46)),
    "mire": ((10.0, 16.5, 16.0), (20.5, 13.0, 7.05)),
    "hammerRaised": ((1.0, 16.6, 29.2), (9.0, 8.0, 37.00)),
    "hammerLanded": ((12.0, 15.0, 17.5), (23.0, 10.5, 9.75)),
}


def _gn_through(a, b, c, t):
    """A quadratic THROUGH three points - and through the middle one at
    t = 0.5, not merely leaning toward it. GnashrootPath.through, verbatim:
    the elbow is a real landmark and a plain Bezier control point pulls it
    back inboard, which loses the kick that makes the limb read as an arm."""
    control = b * 2 - (a + c) * 0.5
    u = 1 - t
    return a * (u * u) + control * (2 * u * t) + c * (t * t)


def _gn_arm_path(side, t, pose="rest"):
    """One arm on `pose`: t = 0 in the shoulder socket, t = 1 at the fist."""
    elbow, wrist = GN_POSE[pose]
    return _gn_through(
        Vector((GN_SHOULDER[0], side * GN_SHOULDER[1], GN_SHOULDER[2])),
        Vector((elbow[0], side * elbow[1], elbow[2])),
        Vector((wrist[0], side * wrist[1], wrist[2])),
        t,
    )


def _gn_hinge_rot(radians_):
    """The jaw's swing, in BLENDER axes.

    The client does `CFrame.Angles(0, 0, -gape)` in Roblox, and Roblox Z is
    -Blender y (export_yup), so a Roblox rotation of -gape about Z is a
    Blender rotation of +gape about Y. Same sign convention is used for the
    body's lean, which is the same axis by the same argument.
    """
    return Matrix.Rotation(radians_, 4, "Y")


def _place_gnashroot(objects, scale=1.0, pose=None, gape=0.0, lean=0.0, aim_side=1, lift=0.0):
    """The colossus rooted in its mere, both arms on `pose`.

    WALKED THE WAY THE CLIENT WALKS IT (GnashrootBodyController.drawArm):
    GN_ARM_SEGMENTS vertebrae at u = (i - 0.5) / SEGMENTS of the arc, knot on
    every fourth, fist seated GN_HAND_SEAT back into the last vertebra.

    `pose` is a name in GN_POSE, or None for rest; `heave` is the one attack
    whose two arms differ, so it is spelled as the pair ("heavePlant",
    "heaveBrace") and `aim_side` says which flank plants.

    `lift` is AUTHORED studs of rise, the same number GnashrootPath.lift
    returns: 0 is fully up and -GnashrootPath.RISE_DEPTH is buried.
    """
    by_name = {obj.name.split("_", 1)[1]: obj for obj in objects}
    made = []
    body_rot = _gn_hinge_rot(lean)
    ground = Vector((0.0, 0.0, lift * scale))
    jaw_rot = _gn_hinge_rot(gape * 1.0)
    hinge = Vector(GN_JAW_HINGE)

    def place(source, position, basis=None, size=1.0):
        """`basis` is a 4x4 rotation - the body/jaw frame for a cluster piece,
        the chain's own frame for a vertebra. One code path for both, because
        the bug this placer used to have was a piece that took the body's
        offset but not its rotation. `size` is a scalar or an (x, y, z)
        triple - length and girth scale separately on the limb, which is the
        whole reason the vertebrae do not pull apart when a pose reaches."""
        copy = source.copy()
        copy.data = source.data
        copy.hide_render = False  # sources are hidden; their copies are the shot
        bpy.context.collection.objects.link(copy)
        copy.matrix_world = (
            Matrix.Translation(position)
            @ (basis if basis is not None else Matrix.Identity(4))
            @ Matrix.Diagonal(
                Vector((size[0], size[1], size[2], 1.0))
                if isinstance(size, tuple)
                else Vector((size, size, size, 1.0))
            )
        )
        made.append(copy)
        return copy

    def aligned(tangent, frame):
        """The +X-up-limb convention, turned onto `tangent`."""
        return frame @ Vector((1, 0, 0)).rotation_difference(tangent).to_matrix().to_4x4()

    # THE BODY IS ONE CFRAME - every piece was authored in the same space, so
    # every one of them takes the same transform and nothing can be left
    # behind. The lean hinges at the authored origin (the mud line), exactly
    # as GnashrootPath.bodyCFrame does it.
    for part in ("Mass", "Roots", "Head", "Teeth", "Core", "Stones", "Drips"):
        place(by_name[part], ground, body_rot, scale)
    # ...and the JAW GROUP swings about the hinge at the back of the skull.
    jaw_frame = body_rot @ Matrix.Translation(hinge) @ jaw_rot @ Matrix.Translation(-hinge)
    for part in ("Jaw", "Fangs", "Maw"):
        place(by_name[part], ground, jaw_frame, scale)
    # THE EYE ROW, one instance per seat - the same loop the client runs, so a
    # seat that is wrong here is wrong in the game rather than only in a
    # picture of it.
    eye = by_name["Eye"]
    for ex, ey, ez, radius in GN_EYE_SEATS:
        place(eye, ground + body_rot @ (Vector((ex, ey, ez)) * scale), body_rot, radius * scale)

    seg, knot, hand = by_name["Arm"], by_name["ArmKnot"], by_name["Hand"]
    for side in (-1, 1):
        if pose is None:
            name = "rest"
        elif isinstance(pose, tuple):
            name = pose[0] if side == aim_side else pose[1]
        else:
            name = pose
        at_length, tangent_at, total = _arc_walker(lambda t, s=side, n=name: _gn_arm_path(s, t, n))
        # THE CLIENT'S OWN TUBE ARITHMETIC (GnashrootBodyController.drawArm).
        # The controller stretches the LENGTH to cover the pitch with the
        # builder's overlap on it and thins only the GIRTH toward the fist,
        # and the preview has to do the same or it is a picture of a rig the
        # game does not draw.
        pitch = total / GN_ARM_SEGMENTS
        stretch = max(0.85, min(1.30, pitch / GN_ARM_SPACING))
        tip_u = (GN_ARM_SEGMENTS - 0.5) / GN_ARM_SEGMENTS
        tube = GN_ARM_SPACING * stretch / (GN_ARM_OVERLAP * (1.0 - GN_ARM_TIP_LENGTH * tip_u))
        for i in range(1, GN_ARM_SEGMENTS + 1):
            u = (i - 0.5) / GN_ARM_SEGMENTS
            girth = 1.0 - GN_ARM_TIP_TAPER * u
            length = tube * (1.0 - GN_ARM_TIP_LENGTH * u) / GN_ARM_TUBE
            at = ground + body_rot @ (at_length(u * total) * scale)
            place(
                knot if i % GN_KNOT_EVERY == 0 else seg,
                at,
                aligned(tangent_at(u * total), body_rot),
                (length * scale, girth * scale, girth * scale),
            )
        tip = 1.0 - GN_ARM_TIP_TAPER
        # Seated INTO the last vertebra: the hand's attach is at +X, so
        # placing it on the path's end alone leaves it hanging past the wrist.
        at = ground + body_rot @ ((at_length(total) + tangent_at(total) * GN_HAND_SEAT * tip) * scale)
        place(hand, at, aligned(tangent_at(total), body_rot), tip * scale)
    return made


# THE FIGHT, AS STILL IMAGES. Every state here is one the client can actually
# be in - the pose names are GnashrootPath.POSE's keys and the gape is
# GnashrootPath.gape's output - so these are renders of the shipped math and
# not illustrations of it. Seven moments, each one answering a question the
# second pass was asked:
#   rest    - does it read as a HEAD ON TOP OF A BODY at a glance? is it smooth?
#   gape    - does the mouth open at the TOP-FRONT of the silhouette?
#   core    - is the ember in the chest hollow, and visible from the bank?
#   hammer_raised / hammer_landed - does a rooted colossus reach the bank?
#   heave   - one fist planted, one bracing, on the latched side.
#   emerge  - the intro's crawl, at the rise the cutscene actually tweens to.
# EVERY CAMERA IS INSIDE THE GROVE. The Rootmere's drowned cypresses stand at
# r 67-80 with a closed canopy over them (assets/arena_gen.py), so a camera
# parked outside that ring shoots the back of a tree. Every station below is
# on the walkable bank, r 29-70, at a player's own height or a little over
# it - which is also the only honest place to judge these from.
#
# THE STATIONS ALL ROSE with the anatomy. The morning build's cameras were
# aimed at authored z 8-25 (world 12-37) because the face was down there;
# the face is now at world z 39 and every target below moved to it.
# Entries are (label, pose, gape, lean, camera, target, lens[, lift]).
GN_POSES = {
    "rest": ("REST - head ON TOP, jaw shut, arms hung forward off the shoulders", None, 0.0, 0.0, (58, -40, 36), (4, 0, 28), 30),
    "gape": ("FULL GAPE - the mouth opens at the TOP-FRONT of the silhouette", "gnash", math.radians(34), math.radians(17), (56, -30, 40), (12, 0, 28), 30),
    # GAPE 0, AND THAT IS A CORRECTION RATHER THAN A CHOICE. This frame used
    # to be rendered at 20 degrees of gape, which no punish window can
    # actually produce: `GnashrootPath.gape` returns 0 for every state whose
    # attack is "" and the window IS such a state. It also hid the thing the
    # frame exists to show - at 20 degrees the chin swings forward to
    # authored x 12.7 z 17.8, directly across the ember at 8.2/16.2. Shut, the
    # jaw's underside sits at z 18.93 and the knot's crown at 18.70, so the
    # chest hollow is open to the bank from every angle a player stands at.
    "core": ("THE PUNISH WINDOW - the chest comes forward, the ember burns under the chin", None, 0.0, math.radians(21), (60, -34, 26), (15, 0, 19), 32),
    "hammer_raised": ("HAMMERFALL, windup - both fists over the crown", "hammerRaised", 0.0, math.radians(-9), (58, -30, 52), (4, 0, 40), 30),
    "hammer_landed": ("HAMMERFALL, landed - both fists out on the bank", "hammerLanded", math.radians(28), math.radians(23), (54, -50, 46), (12, 0, 18), 22),
    "heave": ("HEAVE - the latched arm plants, the other braces", ("heavePlant", "heaveBrace"), 0.0, math.radians(10), (54, -48, 44), (10, 0, 20), 22),
    # THE CUTSCENE'S CRAWL (docs/boss-cutscenes-redesign.md 3.4). The intro
    # drives `Attack = "heave"` with AimSide flipping while it walks the
    # stand-in's pivot in, so the heave pair has to read as HAULING - head and
    # shoulders out, both arms forward on the jaw side and pulling.
    # `lift` is GnashrootPath.lift: RISE_DEPTH (CROWN + 1 = 32.6) * (rise - 1).
    #
    # RENDERED AT Rise 0.62, the number GnashrootIntro already tweens to
    # (`N.riseTo`), so this is a picture of the beat as it is written. With
    # the head ON TOP the beat is much better served than it was: the face
    # clears the mere at rise 0.03 (it is the crown now), the eyes at 0.20 and
    # the shoulders at 0.33, so the thing looks at you long before its chest
    # is out of the water. lift here is 32.6 * (0.62 - 1) = -12.39.
    "emerge": ("EMERGE, Rise 0.62 - the crawl: head and shoulders out, both arms hauling", ("heavePlant", "heaveBrace"), math.radians(16), math.radians(13), (60, -40, 30), (12, 0, 14), 26, -12.39),
}


def render_gn_pose(path_out, objects, entry):
    """One GN_POSES entry, on the real Rootmere."""
    import os

    label, pose, gape, lean, camera, target, lens = entry[:7]
    lift = entry[7] if len(entry) > 7 else 0.0
    print("POSE", label)
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import arena_gen  # noqa: E402

    clear_scene()
    objects = BOSSES["gnashroot"]()
    arena_gen.build_gnashroot()
    for obj in objects:
        obj.hide_render = True
    _place_gnashroot(objects, scale=1.5, pose=pose, gape=gape, lean=lean, lift=lift)
    _light_and_shoot(path_out, camera, target, lens=lens)


PLACERS = {
    "kraken": _place_kraken,
    "gnashroot": _place_gnashroot,
    "noctyss": _place_noctyss,
    "rimefang": _place_rimefang,
    "pyrelisk": _place_pyrelisk,
    "wrack": _place_wrack,
}

# Per-boss staged renderers (the arena-and-boss shot). A boss with no entry
# falls through to the brinejaw body below, which is what shipped first.
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
        # THE APPROACH: from the bank off its face, low, looking UP at it -
        # the read the whole design is for. A colossus shot from above looks
        # like a lump; shot from below it looms.
        #
        # RAISED FOR THE SECOND PASS. This station was aimed at world z 27,
        # which was the middle of the morning build's horizontal mound and is
        # now the middle of the animal's CHEST: the head sits on top at world
        # z 37..47 and the shot cropped it. Aimed at the face.
        ("", (66, -20, 22), (4, 0, 40), 28),
        # THE WIDE: high enough to clear the near canopy, far enough to show
        # it standing in the mere with the bank around it.
        ("_wide", (78, -104, 104), (0, 0, 22), 28),
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


def _stage_kraken(path_out, objects):
    """The shots the wide preview cannot give: the FACE close enough to judge
    the star eyes and the siphon, and the INTERIOR kit laid out.

    It does NOT import arena_gen. The kraken's arena is being authored in
    another lane and a staged render that dies on someone else's unfinished
    file teaches nothing; the ship under the fight here is the placer's own
    proxy, and it is never to be mistaken for the real one.
    """
    def clear(made):
        for obj in made:
            bpy.data.objects.remove(obj, do_unlink=True)

    def shoot(out, location, target, lens, sky, note):
        cam_data = bpy.data.cameras.new("Cam")
        cam_data.lens = lens
        cam = bpy.data.objects.new("Cam", cam_data)
        cam.location = Vector(location)
        cam.rotation_euler = (Vector(target) - cam.location).to_track_quat("-Z", "Y").to_euler()
        bpy.context.collection.objects.link(cam)
        scene = bpy.context.scene
        scene.camera = cam
        scene.render.engine = "BLENDER_EEVEE"
        scene.render.resolution_x = 1500
        scene.render.resolution_y = 1000
        scene.world = bpy.data.worlds.new("World")
        scene.world.use_nodes = True
        node = scene.world.node_tree.nodes.get("Background")
        if node:
            node.inputs[0].default_value = (sky[0], sky[1], sky[2], 1.0)
        scene.render.filepath = out
        bpy.ops.render.render(write_still=True)
        print("BOSS STAGED:", out, "-", note)

    # PURGE WHATEVER RAN BEFORE US. `main` will happily be asked for "preview
    # staged" in one invocation, and render_preview leaves its placed copies,
    # its sun and its camera in the scene. The first version of this stager
    # inherited all of it: the face shots were quietly double-lit and the
    # interior sheet came out with the whole boss standing in the gut.
    keep = set(objects)
    for obj in list(bpy.context.collection.objects):
        if obj not in keep:
            bpy.data.objects.remove(obj, do_unlink=True)
    for obj in objects:
        obj.hide_render = True
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.rotation_euler = (math.radians(52), 0, math.radians(28))
    sun.data.energy = 2.6
    bpy.context.collection.objects.link(sun)
    fill = bpy.data.objects.new("Fill", bpy.data.lights.new("Fill", "SUN"))
    fill.rotation_euler = (math.radians(64), 0, math.radians(-135))
    fill.data.energy = 1.0
    bpy.context.collection.objects.link(fill)

    # THE FACE, from the ship: the shot the eyes have to survive. If the orbs
    # and their stars do not read as ALIVE from here they do not read anywhere.
    made = _place_kraken(objects, tentacles=1, ship=False)
    bpy.context.view_layer.update()
    shoot(path_out.replace("_staged.png", "_preview_face.png"),
          (196.0, -52.0, 62.0), (18.0, 0.0, 42.0), 46, (0.42, 0.54, 0.62),
          "THE FACE - the star eyes, the scalloped cap and the siphon door")
    clear(made)

    # THE SCALE, and the only shot that proves the claim: the deck, 5-stud men
    # on it, a limb coming down over the rail beside them and the head behind.
    # Every other frame is a picture of a big shape with nothing to be big
    # against, and a lens will happily make a 480-stud animal a bath toy.
    made = _place_kraken(objects)
    bpy.context.view_layer.update()
    shoot(path_out.replace("_staged.png", "_preview_scale.png"),
          (146.0, -46.0, 12.0), (96.0, 0.0, 6.0), 42, (0.42, 0.54, 0.62),
          "SCALE - 5-stud stand-ins on the deck, a limb over the rail beside them, the head behind")
    clear(made)

    # PHASE THREE: the interior kit, lit dim and warm the way a gut would be.
    sun.data.energy = 1.6
    fill.data.energy = 0.6
    made = _place_kr_interior(objects)
    bpy.context.view_layer.update()
    shoot(path_out.replace("_staged.png", "_preview_interior.png"),
          (68.0, -52.0, 22.0), (2.0, 0.0, 10.0), 36, (0.10, 0.05, 0.07),
          "INSIDE THE BEAST - four rib arches, four polyps, four strands")
    clear(made)


STAGERS = {
    "noctyss": _stage_noctyss,
    "pyrelisk": _stage_pyrelisk,
    "gnashroot": _stage_gnashroot,
    "wrack": _stage_wrack,
    "kraken": _stage_kraken,
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
    offset = Vector(PREVIEW_CAMS.get(boss, (0.30, -1.0, 0.42))).normalized() * span * (1.85 if boss in ("pyrelisk", "wrack") else 1.28)
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
    extra = EXTRA_VIEWS.get(boss)
    if extra:
        extra(path_out, placed)


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
    # The two kinds the 2026-09-08 revision adds. Both are reviewed on the
    # frame that matters: the coil slam ON THE SAND (the melee window, which
    # is the whole reason the kind exists) and the bite at the bottom of its
    # hang, which is the frame that has to prove the jaw is on the beach and
    # not inside it.
    "coilslam": (
        "COIL SLAM, fallen - the loop lies along the aim line, a melee window",
        bj_state(attack_kind="coilslam", attack_u=0.62, aim_x=24.0, aim_z=-33.0, coil=2),
        (-120, -132, 58), (10, -14, 6),
    ),
    "bite": (
        "THE BITE, hanging - the jaw is down where melee can reach it",
        bj_state(attack_kind="bite", attack_u=0.60, aim_x=14.0, aim_z=5.0, coil=2, face_angle=math.radians(20)),
        (74, -52, 24), (14, 5, 8),
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
    # Color3.fromRGB(58, 52, 44) - setLantern's own dead-plastic value, not a
    # darker one picked because it read better against the stone.
    dark.data.materials.append(make_material("Noctyss_StalkBulbDoused", NC_BULB_DEAD))
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


# NoctyssBodyController's CHOIR_SPREAD, mirrored, and it is NOT cosmetic.
# NoctyssPath.pulse hands every false lure the same phase, and the client
# shifts each socket's clock by these fractions of a cycle so the six do not
# pump the whole arena in unison. The TRUE lure is left unshifted at its half
# cycle, which is what makes it both the furthest from any of them and the
# only lantern still arriving at a crisp top. A render that used the raw
# shared pulse would show six bulbs snapping together - a strobe nobody who
# plays this fight will ever see - and would make the tell look far easier to
# read than it is. Lua indices 1..7 land here as 0..6.
NC_CHOIR_SPREAD = (-0.22, 0.09, -0.13, 0.20, -0.05, 0.15, -0.17)

# setLantern's two ends: the lure's own colour at full glow, and the dead
# plastic it becomes when the light is out (Color3.fromRGB(58, 52, 44)). The
# mid colour a guttering bulb lerps toward is (96, 82, 44).
NC_BULB_DEAD = (0.227, 0.204, 0.173)
NC_BULB_LOW = (0.376, 0.322, 0.173)


def _nc_pulse(state, index):
    """The glow one lantern is showing, 0..1 - `choirPulse` over
    NoctyssPath.pulse, times what the douse has taken off it.

    This is the whole read of the fight expressed as one number, so the pose
    renders drive every bulb's colour, emission and point light off it rather
    than lighting all seven the same and leaving the tell to a caption.
    """
    if index == state.get("true_lure"):
        clock = state.get("time", 0.0)
        offset = NC_TRUE_LURE_OFFSET
    else:
        clock = state.get("time", 0.0) - NC_PULSE_PERIOD * NC_CHOIR_SPREAD[index % len(NC_CHOIR_SPREAD)]
        offset = 0.0
    pulse = 0.5 + 0.5 * math.sin((clock / NC_PULSE_PERIOD + offset) * TAU)
    return pulse * (1.0 - max(0.0, min(1.0, state["stalks"][index]["douse"])))


def _nc_lantern_look(by_name, index, glow):
    """One stalk's piece table, with a bulb dressed the way `setLantern`
    dresses it at this glow.

    A per-stalk copy is not an indulgence: Blender shares a material datablock
    across every instance of a piece, so without one, the choir can only ever
    be all-bright or all-dark - which is the one thing the fight is never.
    """
    pieces = dict(by_name)
    if glow <= 0.02:
        colour = NC_BULB_DEAD
        strength = 0.0
    else:
        # bulb.Color = LURE:Lerp(Color3.fromRGB(96, 82, 44), 1 - glow)
        colour = tuple(NC_LURE[i] + (NC_BULB_LOW[i] - NC_LURE[i]) * (1.0 - glow) for i in range(3))
        # light.Brightness = 1.1 + 2.2 * glow, carried onto the Neon face so
        # the bulb itself dims with its own light rather than staying a
        # uniform white dot that hides the difference the player is hunting.
        # Tuned so a guttering lantern lands BELOW clipping while a full one
        # is well over it: under the Standard transform anything past 1.0 is
        # white, so a curve that put the whole choir over the line would make
        # every bulb the same white dot and erase the only tell in the fight.
        strength = 0.15 + 2.6 * glow
    pieces["StalkBulb"] = _nc_bulb_variant(by_name, "Glow%d" % index, colour, strength)
    return pieces


def _nc_bulb_variant(by_name, suffix, colour, strength):
    """A lantern with its OWN material - the general case of `_nc_dark_bulb`.

    Same reason: Blender shares a material datablock across every instance of
    a piece, so a per-stalk brightness (the true lure flaring, a doused one)
    has to be a second object or it is applied to all seven at once.
    """
    source = by_name["StalkBulb"]
    copy = source.copy()
    copy.data = source.data.copy()
    copy.data.materials.clear()
    copy.data.materials.append(_nc_glow_material("Noctyss_StalkBulb" + suffix, colour, strength))
    copy.hide_render = True
    bpy.context.collection.objects.link(copy)
    return copy


# ------------------------------------------------------------- telegraphs
#
# EVERY SHAPE BELOW IS READ OUT OF THE FIGHT'S OWN TABLES. A telegraph render
# exists so an attack can be argued about before anyone can play it, and the
# only version of that which is worth anything is one that cannot flatter: the
# wedge is `BEAM_HALF_ANGLE` because that is the constant `beamHits` tests, the
# rings are `strobewave.rings` because that is the list the barrage walks, the
# bite volume is a BOX because `insideMouth` is a box. Where the book and the
# data disagreed, the data won and the disagreement is written down.
#
# These are PROPS: they are built by `render_nc_pose`, which runs after the
# export and rebuilds the scene from scratch for every frame, so none of them
# can ever reach the glb. Nothing here is called from `_place_noctyss` or
# `_stage_noctyss` for the same reason.

# 0.15 is not a nicety - it is the offset the client draws every ground
# telegraph at (CreatureEventController: `surfaceUnder(position) +
# Vector3.new(0, 0.15, 0)`), and these props sit where the game puts them so a
# reviewer is looking at the real clearance over the stone.
NC_TG_LIFT = 0.15

# NoctyssPath.TELL, MIRRORED - AND IT IS THE WHOLE LANGUAGE OF THIS FIGHT.
#
# These renders used to draw six telegraph colours, because the fight did: two
# skins in the creature row ("lure" gold, "ink" violet) and four more of the
# body controller's own, four of the eight within a hue step of the lanterns
# themselves. The fight now declares THREE, once, in NoctyssPath.TELL, and
# nothing in it may declare a fourth - so nothing in here may either. COLOUR
# SAYS WHERE IT COMES FROM; SHAPE SAYS WHAT IT IS.
#
#   LIGHT - her LIGHT is coming: lightsweep, strobewave, lurepull - and the
#           door's lane, the one gold mark that is somewhere to GO rather than
#           somewhere to leave.
#   LIMB  - a LIMB is coming: slam, scythe, jab, the herd V, and the
#           portcullis bars. A BAR IS NOT A NEW COLOUR.
#   HEAD  - her MOUTH is coming: the snap's rim ring, the bite's box. Bone,
#           and reserved for the two shapes that cannot be out-walked.
NC_TELL_LIGHT = (1.000, 0.808, 0.361)  # Color3.fromRGB(255, 206, 92)
NC_TELL_LIMB = (0.690, 0.376, 1.000)  # Color3.fromRGB(176, 96, 255)
NC_TELL_HEAD = (0.925, 0.910, 0.839)  # Color3.fromRGB(236, 232, 214)

# TELL's ramp, in Roblox Transparency, mirrored so a mark's brightness in a
# render is the brightness the game gives it and not a taste.
NC_TELL_EDGE_W = 0.90  # studs of edge band, CENTRED ON THE TESTED BOUNDARY
NC_TELL_FLOOR_T = 0.92
NC_TELL_LEAD_T = 0.42
NC_TELL_FLASH_T = 0.05
NC_TELL_FLASH = 0.08
NC_TELL_LIVE_T = 0.30
NC_TELL_FADE = 0.30
NC_TELL_FILL_T = 0.82
NC_TELL_FILL_LIVE = 0.62
NC_TELL_WHITE_MIX = 0.60
NC_TELL_NEON_MIN = 0.25

# EMISSION CARRIES NEON'S GLOW; ALPHA CARRIES THE TRANSPARENCY.
#
# Roblox draws every one of these marks as Neon, which blooms: a part held at
# Transparency 0.82 is faint but unmistakably LIT. EEVEE's blended alpha does
# not bloom, so the mirror is alpha = 1 - Transparency with the emission doing
# the glowing - one strength for an edge, a much lower one for the fill behind
# it. EDGE_S is 2.0 and not the 3.0 it was first set to, for a reason the fight
# already carries about Neon: over about 2.2 the violet's blue channel clips and
# TELL.LIMB renders as the same blown-out white paddle the whole colour code was
# rewritten to stop drawing. The single liberty is NC_FILL_A_MIN: a fill at
# 1 - FILL_T = 0.18 over near-black stone vanished outright in test renders,
# which would have quietly reinstated exactly the undrawn cores this file has
# always refused to draw.
NC_EDGE_S = 2.0
NC_FILL_S = 0.85
NC_FILL_A_MIN = 0.26
NC_HIDDEN_A = 0.02  # below this a mark is not built at all: the game draws none


def _nc_tell_alpha(transparency, floor=0.0):
    return max(floor, min(1.0, 1.0 - transparency))


def _nc_tell_ramp(u, live=False, since=None):
    """NoctyssPath.tellRamp, mirrored: (edge alpha, fill alpha, white mix).

    The Luau returns Transparency and a colour; this returns the two alphas
    and how far the colour lerps to white, because that is the pair a Blender
    material needs. The three windows and the accelerating lead-in are the
    Luau's, number for number.
    """
    if live:
        if (since or 0.0) < NC_TELL_FLASH:
            flash = _nc_tell_alpha(NC_TELL_FLASH_T)
            return flash, flash, NC_TELL_WHITE_MIX
        return _nc_tell_alpha(NC_TELL_LIVE_T), _nc_tell_alpha(NC_TELL_FILL_LIVE, NC_FILL_A_MIN), 0.0
    if since is not None and since >= 0:
        # Dead, and fading. NOT floored: a mark that outlived its own hitbox
        # taught the player to dodge a shape that could not hurt them, so this
        # branch is allowed - required - to reach zero.
        f = max(0.0, min(1.0, since / NC_TELL_FADE))
        return (
            _nc_tell_alpha(NC_TELL_LIVE_T + (1 - NC_TELL_LIVE_T) * f),
            _nc_tell_alpha(NC_TELL_FILL_LIVE + (1 - NC_TELL_FILL_LIVE) * f),
            0.0,
        )
    e = max(0.0, min(1.0, u))
    lead = NC_TELL_FLOOR_T - (NC_TELL_FLOOR_T - NC_TELL_LEAD_T) * e * e
    return (
        _nc_tell_alpha(max(lead, NC_TELL_NEON_MIN)),
        _nc_tell_alpha(NC_TELL_FILL_T, NC_FILL_A_MIN),
        0.0,
    )


# The lead-in's own pair, for the telegraphs that have no descriptor and no
# clock in these poses (the barrage marks, the strobe, the pull, the beam):
# a mark that has just appeared and is counting down.
NC_LEAD_EDGE_A, NC_LEAD_FILL_A, _ = _nc_tell_ramp(0.55)


def _nc_tell_colour(colour, mix):
    """`base:Lerp(WHITE, mix)` - the flash frame, and only the flash frame."""
    if mix <= 0.0:
        return colour
    return tuple(c + (1.0 - c) * mix for c in colour)

def _nc_maw_frames(rise, gape):
    """The skull's frame and the MOUTH's, for a state that is not on screen yet.

    `render_nc_pose` builds these once the scene exists; the head's two moves
    need them BEFORE it does, because where the door's bars land is solved off
    the mouth (`doorTargets` reads `mawMouth`). Same three calls in the same
    order, so a pose and the render of it cannot disagree about where her jaw
    is.
    """
    scale = NC_MAW["scale"]
    base = _nc_maw_base(_nc_maw_at(_nc_maw_z(rise)), NC_MAW["pitch"], NC_MAW["yaw"], scale)
    return base, _nc_mouth_frame(base, NC_MAW["gape"] * gape, scale)


def _nc_maw_facing():
    """`mawFacing`: the lane she surfaced on, and the lateral across it.

    The Luau flattens the skull's RightVector; here the shift is applied after
    the yaw and before the pitch (see `_nc_maw_at`), so flattened that axis is
    exactly (cos yaw, sin yaw) and there is no sign to chase between the files.
    Blender's up is +Z where Roblox's is +Y, and the map between the two frames
    is a proper rotation, so the cross product carries across unchanged.
    """
    yaw = math.radians(NC_MAW["yaw"])
    forward = Vector((math.cos(yaw), math.sin(yaw), 0.0))
    return forward, Vector((0.0, 0.0, 1.0)).cross(forward)


def _nc_door_line(state):
    """`doorTargets`, plus the lane between them: (targetA, targetB, centre,
    forward).

    DOOR.HALF 11 either side of the entrance lane against a SLAM.RADIUS of 7
    is eight studs of walkable centreline - the door never seals, and the
    punish is that you have to run the middle of it.
    """
    scale = NC_MAW["scale"]
    _, mouth = _nc_maw_frames(state["maw_rise"], state["maw_gape"])
    forward, lateral = _nc_maw_facing()
    ahead = (NC_DOOR["lip_forward"] + NC_DOOR["lip_half"]) * scale + NC_DOOR["ahead"]
    centre = mouth @ Vector((ahead, 0.0, 0.0))
    one = centre + lateral * NC_DOOR["half"]
    two = centre - lateral * NC_DOOR["half"]
    a, b = _nc_aim_point(one.x, one.y), _nc_aim_point(two.x, two.y)
    return a, b, (a + b) * 0.5, forward


def _nc_flanking(state):
    """`flankingStalks`: the nearest FREE socket to the lane on each side that
    can reach its own doorpost, or None for a side with nobody left.

    "Can reach" is doing real work: `stalkReach` is measured on the current
    shape, so a target on the exact edge of an arm could be clamped by one side
    and not the other and the two would draw different doors. DOOR.MARGIN is
    that slack, and it is why the pair a render picks is the pair the fight
    would have picked rather than the two nearest collars.
    """
    a_target, b_target, _, _ = _nc_door_line(state)
    _, lateral = _nc_maw_facing()
    yaw = math.radians(NC_MAW["yaw"])
    order = []
    for index in range(len(NC_SOCKETS)):
        angle = math.radians(NC_SOCKETS[index][1])
        order.append((abs((angle - yaw + math.pi) % TAU - math.pi), index, lateral.x * math.cos(angle) + lateral.y * math.sin(angle)))
    order.sort()
    busy = state.get("attacks") or {}
    a, b = None, None
    for _, index, side in order:
        stalk = state["stalks"][index]
        if not stalk["alive"] or stalk["fall"] >= 0.5 or index in busy:
            continue
        target = a_target if side > 0 else b_target
        near, far = _nc_stalk_reach(state, index)
        span = (Vector(target) - _nc_socket_root(index)).length
        if not (near + NC_DOOR["margin"] <= span <= far - NC_DOOR["margin"]):
            continue
        if side > 0:
            a = index if a is None else a
        else:
            b = index if b is None else b
    return a, b


def _nc_herd_targets(state, player):
    """`herdTargets`: the two ADJACENT free sockets nearest the player, and the
    two points on the pit's rim their bars converge on. Returns
    (indexA, indexB, targetA, targetB, apex).

    The apex sits ON the rim on the bearing halfway between the two collars and
    each tip is set HERD.SPREAD off it toward its OWN socket's side, so the two
    stripes cross the floor as a V and not as an X. Ten studs between the tips
    against a 7-stud capsule means they OVERLAP by four: the point of the V is
    shut, and the funnel's only opening is the wide end out at the collars.
    """
    count = len(NC_SOCKETS)
    busy = state.get("attacks") or {}
    best = None
    for index in range(count):
        other = (index + 1) % count
        if not (state["stalks"][index]["alive"] and state["stalks"][other]["alive"]):
            continue
        if index in busy or other in busy:
            continue
        pa, pb = _nc_socket_root(index), _nc_socket_root(other)
        score = math.hypot(pa.x - player[0], pa.y - player[1]) + math.hypot(pb.x - player[0], pb.y - player[1])
        if best is None or score < best[0]:
            best = (score, index, other)
    if best is None:
        return None, None, None, None, None
    _, first, second = best
    angle_a = math.radians(NC_SOCKETS[first][1])
    angle_b = math.radians(NC_SOCKETS[second][1])
    # A half-step from A's bearing, not an average of two angles - which for the
    # pair that straddles the wrap would point at the far side of the arena.
    mid = angle_a + ((angle_b - angle_a + math.pi) % TAU - math.pi) * 0.5
    out = Vector((math.cos(mid), math.sin(mid), 0.0))
    across = Vector((0.0, 0.0, 1.0)).cross(out)
    apex = out * NC_PIT_R
    sign = 1.0 if across.x * math.cos(angle_a) + across.y * math.sin(angle_a) > 0 else -1.0
    one = apex + across * (NC_HERD["spread"] * sign)
    two = apex - across * (NC_HERD["spread"] * sign)
    return first, second, _nc_aim_point(one.x, one.y), _nc_aim_point(two.x, two.y), apex


def _nc_snap_tell(state):
    """`snapTell`: the rise is the lead-in, the bite is the live window, the
    sink is the fade - the same three arguments every limb mark's ramp takes,
    off `snapStart` on the shared clock rather than off the eased head."""
    t = state.get("time", 0.0) - state.get("snap_start", 0.0)
    if t < NC_SNAP["rise"]:
        return _nc_clamp(t / max(NC_SNAP["rise"], 1e-3), 0.0, 1.0), False, None
    if t <= NC_SNAP["rise"] + NC_SNAP["bite"]:
        return 1.0, True, t - NC_SNAP["rise"]
    return 1.0, False, t - (NC_SNAP["rise"] + NC_SNAP["bite"])


# THREE PLAUSIBLE PLAYERS, in authored (radius, degrees). Every `everyone` and
# `scatter` pattern in her book is centred on a player, so a render of one has
# to stand somebody somewhere - and where they stand is not arbitrary: these
# are in the gaps between the arena's shadow fins (GL_FINS at 28, 84, 140,
# 196, 252, 316 degrees), which is where the fight teaches people to be.
NC_PARTY = [(31.0, 300.0), (44.0, 6.0), (37.0, 236.0)]


def _nc_at(radius, degrees):
    angle = math.radians(degrees)
    return math.cos(angle) * radius, math.sin(angle) * radius


# NoctyssPath.PROBE_Y / .PROBE_UP / .PROBE_DOWN - the window `markFloor` casts
# in, mirrored. Opened UPWARD off the shelf so the cast clears a collar mound
# rather than starting under one.
NC_PROBE_Y = 3.0
NC_PROBE_UP = 3.0
NC_PROBE_DOWN = 10.0

# The arena `_nc_floor_z` casts against, and a cache: one probe per point, not
# one per prop that happens to want the same point.
_NC_PROBE = {"arena": None, "cache": {}}


def _nc_probe_arena(arena):
    """Hand the probe its geometry. `render_nc_pose` calls this once per frame,
    with the ARENA only - which is the same Include filter NoctyssPath builds
    (`BossArenas`), so a mark cannot come to rest on the boss."""
    _NC_PROBE["arena"] = [(obj, obj.matrix_world.inverted()) for obj in arena]
    _NC_PROBE["cache"] = {}


def _nc_floor_z(x, y):
    """NoctyssPath.markFloor, AS A PROBE AND NOT AS A PROFILE.

    This used to be `arena_gen._gl_height(r)` - the shelf's authored radial
    curve - which is a description of the stone and not the stone. The
    Choirfloor has things ON it: the socket collars stand on mounds, and the
    pit is ringed with broken lip rubble that reaches 2.6 studs over the
    profile at r 19. The herding snap's ring is drawn at exactly r 19, so on
    the profile it was laid at 1.92 under rubble whose top is at 4.5 - THE
    MARK WAS RENDERED INSIDE THE ROCK AND DID NOT APPEAR IN THE FRAME AT ALL.
    The fight does not have that bug, because both files that draw floor marks
    raycast: `markFloor` here and `surfaceUnder` in CreatureEventController.

    So: cast down through the same window, from PROBE_Y + PROBE_UP to
    PROBE_DOWN below it, and take the topmost hit. Off the bottom of that
    window - down inside the pit, mostly - the Luau falls back to a flat
    SHELF_Y and so does this, which is why the lurepull mark reads as a plate
    across the hole rather than draping into it. That is the shipped behaviour
    of the shipped probe, and it is worth seeing.
    """
    key = (round(x, 2), round(y, 2))
    cached = _NC_PROBE["cache"].get(key)
    if cached is not None:
        return cached
    top = Vector((x, y, NC_PROBE_Y + NC_PROBE_UP))
    bottom = top + Vector((0.0, 0.0, -NC_PROBE_DOWN))
    best = None
    for obj, inv in _NC_PROBE["arena"] or ():
        origin = inv @ top
        span = (inv @ bottom) - origin
        if span.length < 1e-6:
            continue
        ok, local, _, _ = obj.ray_cast(origin, span.normalized(), distance=span.length)
        if ok:
            z = (obj.matrix_world @ local).z
            best = z if best is None else max(best, z)
    if best is None:
        best = NC_SHELF_Z
    _NC_PROBE["cache"][key] = best
    return best


def _nc_glow_material(name, colour, strength, alpha=1.0):
    """A material that EMITS - the `_emissive` node edit, applied at build
    time instead of after the fact.

    Telegraphs in this game are neon decals on near-black stone, so a prop
    with a plain diffuse material would be invisible in exactly the renders
    that exist to prove a telegraph is visible. `alpha` is for the volumes
    (the light shaft, the mouth's floor slabs) that have to be seen THROUGH.
    """
    mat = make_material(name, colour)
    tree = mat.node_tree
    bsdf = tree.nodes.get("Principled BSDF") if tree else None
    if bsdf:
        bsdf.inputs["Base Color"].default_value = (*colour, 1.0)
        for key in ("Emission Color", "Emission"):
            if key in bsdf.inputs:
                bsdf.inputs[key].default_value = (*colour, 1.0)
                break
        if "Emission Strength" in bsdf.inputs:
            bsdf.inputs["Emission Strength"].default_value = strength
        if "Alpha" in bsdf.inputs:
            bsdf.inputs["Alpha"].default_value = alpha
    if alpha < 1.0:
        # EEVEE renamed this between the version this pack was written on and
        # the one it runs on now; set whichever exists rather than pinning.
        for attr, value in (("surface_render_method", "BLENDED"), ("blend_method", "BLEND")):
            if hasattr(mat, attr):
                try:
                    setattr(mat, attr, value)
                except (TypeError, ValueError):
                    pass
    return mat


def _nc_prop(name, bm, colour, strength, alpha=1.0):
    """`finish`, for a telegraph: same bmesh handoff, emissive material."""
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    mesh.materials.append(_nc_glow_material("NC_TG_" + name, colour, strength, alpha))
    for poly in mesh.polygons:
        poly.use_smooth = False
    return obj


def _nc_band(bm, cx, cy, r0, r1, a0, a1, rings=None, sectors=None, lift=NC_TG_LIFT, visible=None):
    """A draped annulus sector: every floor telegraph in the book is one.

    `visible` is per-CELL rather than per-vertex so a cell is kept or dropped
    whole - that is what makes the lightsweep wedge able to carve itself on a
    shadow fin without the edges of the hole lying about where the light stops.
    """
    rings = rings or max(1, int((r1 - r0) / 3.0))
    sectors = sectors or max(1, int(abs(a1 - a0) / math.radians(5.0)))
    grid = []
    for i in range(rings + 1):
        r = r0 + (r1 - r0) * i / rings
        row = []
        for j in range(sectors + 1):
            a = a0 + (a1 - a0) * j / sectors
            x, y = cx + math.cos(a) * r, cy + math.sin(a) * r
            row.append(bm.verts.new((x, y, _nc_floor_z(x, y) + lift)))
        grid.append(row)
    for i in range(rings):
        for j in range(sectors):
            if visible is not None:
                a = a0 + (a1 - a0) * (j + 0.5) / sectors
                r = r0 + (r1 - r0) * (i + 0.5) / rings
                if not visible(cx + math.cos(a) * r, cy + math.sin(a) * r):
                    continue
            bm.faces.new((grid[i][j], grid[i][j + 1], grid[i + 1][j + 1], grid[i + 1][j]))


def _nc_edge_ring(bm, cx, cy, radius, lift=NC_TG_LIFT, sectors=64):
    """TELL.EDGE_W of neon, CENTRED ON A TESTED CIRCLE - `makeMarks`' discEdge
    and the snap's rim, as one call. Centred and not laid inside or outside,
    because the number the server measures against is the middle of the band:
    a foot placed against the outside of the line is a foot outside the hit."""
    half = NC_TELL_EDGE_W * 0.5
    _nc_band(bm, cx, cy, max(radius - half, 0.02), radius + half, 0.0, TAU, rings=1, sectors=sectors, lift=lift)


def _nc_edge_arc(bm, cx, cy, radius, a0, a1, lift=NC_TG_LIFT, sectors=None, visible=None):
    """...and one arc of it: the scythe band's two boundaries, and the far end
    of the beam's wedge."""
    half = NC_TELL_EDGE_W * 0.5
    _nc_band(
        bm, cx, cy, max(radius - half, 0.02), radius + half, a0, a1,
        rings=1, sectors=sectors, lift=lift, visible=visible,
    )


def _nc_tile_ring(bm, cx, cy, radius, width, tiles, lift=NC_TG_LIFT):
    """A ring laid as N FLAT TILES, one probe each - `snapRing`'s own build, and
    NOT a draped band.

    The difference is the pit's lip. A continuous band probed per-vertex twists
    through two and a half studs of broken rubble and comes out of the render
    as a dashed line with holes in it, which is a picture of a telegraph the
    fight does not draw. The client stands eighteen separate slabs, each level,
    each at the height its own centre probed, each `ringChord` long with a
    little overlap so the ring reads as a ring and not as n dashes - so that is
    what gets built here.
    """
    step = TAU / tiles
    half_w = width * 0.5
    # ringChord: the 1.08 is the client's own overlap.
    half_c = radius * math.sin(math.pi / tiles) * 1.08
    for i in range(tiles):
        angle = (i + 0.5) * step
        cos, sin = math.cos(angle), math.sin(angle)
        x, y = cx + cos * radius, cy + sin * radius
        at = Vector((x, y, _nc_floor_z(x, y) + lift))
        out = Vector((cos, sin, 0.0))
        along = Vector((-sin, cos, 0.0))
        corners = (
            at + out * half_w + along * half_c,
            at - out * half_w + along * half_c,
            at - out * half_w - along * half_c,
            at + out * half_w - along * half_c,
        )
        bm.faces.new([bm.verts.new(tuple(c)) for c in corners])


def _nc_edge_line(bm, a, b, lift=NC_TG_LIFT, steps=28, visible=None):
    """A straight edge: the slam stripe's two sides, and the beam's two radial
    boundaries. `_nc_stripe` draped, at EDGE_W."""
    _nc_stripe(bm, a, b, NC_TELL_EDGE_W * 0.5, lift=lift, steps=steps, visible=visible)


def _nc_prop_pair(name, fill, edges, colour, edge_a=None, fill_a=None, mix=0.0):
    """ONE MARK IS TWO PROPS: the dim interior, and the line on the boundary.

    Built in that order so the edge draws over its own fill, and skipped
    entirely when the ramp has taken either under NC_HIDDEN_A - because what
    the game draws at that instant is nothing, and a render that kept a ghost
    of a dead telegraph on the stone would be the exact lie this whole block
    exists to not tell.
    """
    edge_a = NC_LEAD_EDGE_A if edge_a is None else edge_a
    fill_a = NC_LEAD_FILL_A if fill_a is None else fill_a
    shade = _nc_tell_colour(colour, mix)
    if fill is not None:
        if fill_a > NC_HIDDEN_A:
            _nc_prop(name + "Fill", fill, shade, NC_FILL_S, alpha=fill_a)
        else:
            fill.free()
    if edges is not None:
        if edge_a > NC_HIDDEN_A:
            _nc_prop(name + "Edge", edges, shade, NC_EDGE_S, alpha=edge_a)
        else:
            edges.free()


def _nc_marks(name, spots, colour, radius):
    """A barrage telegraph - the shape `feelerstrike` and the dousehunt strike
    share. (`abysscall` and `inkveil` shared it too, until the plan retired
    both; a render of an attack that does not ship is a lie, so their poses and
    their PNGs went with them.)

    EDGE ON THE TESTED CIRCLE, DIM FILL BEHIND IT, AND NO UNDRAWN CORE.

    A strike queued by `queueStrike` with no `shape` damages a full DISC of
    `radius` (`damagePlayersInRadius`). The old telegraph for it was
    `Vfx.ring(point, radius * 0.35, radius)` - an annulus that left the inner
    35% of every strike in her book as hitbox with nothing drawn on it, and
    this file drew that hole at a sixth of the strength to say so out loud.
    TELL ended the argument rather than shading it: every mark in this fight
    is now an EDGE_W band centred exactly on the number the server measures
    against, with the whole interior held dim behind it. So the core is drawn,
    the boundary is a line a player can put their feet against, and the two
    rings this function used to build are one ring and one fill.
    """
    fill, edges = bmesh.new(), bmesh.new()
    for x, y in spots:
        _nc_band(fill, x, y, 0.3, radius, 0.0, TAU, rings=2, sectors=40)
        _nc_edge_ring(edges, x, y, radius, sectors=40)
    _nc_prop_pair(name, fill, edges, colour)


def _nc_visible_from(arena, origin):
    """NoctyssPath.beamBlocked, as a per-point predicate.

    One ray from the lantern to a torso-height point over the floor, against
    the ARENA's geometry only - the same Include filter the Luau builds, and
    the same 2-stud lift onto the player's chest. It is here because the whole
    stated trade of the fight ("stand in the dark behind a fin and lose your
    view of the arena") is invisible in a render that draws the wedge as an
    unbroken slice: the fins would be decoration in the image exactly as they
    were in the code before `beamBlocked` existed.
    """
    origin = Vector(origin)
    frames = [(obj, obj.matrix_world.inverted()) for obj in arena]

    def visible(x, y):
        target = Vector((x, y, _nc_floor_z(x, y) + 2.0))
        for obj, inv in frames:
            local_o = inv @ origin
            span = (inv @ target) - local_o
            if span.length < 1e-3:
                continue
            hit = obj.ray_cast(local_o, span.normalized(), distance=span.length)[0]
            if hit:
                return False
        return True

    return visible


def _nc_prop_lightsweep(state, ctx):
    """THE SIGNATURE, drawn honestly.

    The wedge's apex is the BULB and not the socket, which is the single
    correction `beamHits` carries its own comment about: the crook hangs the
    lantern eleven studs inward of its collar and further when it leans, and
    at a 9-degree half-angle a wedge hinged on the floor would be metres off
    the light at the far end. So this reads `hoods[index] @ NC_BULB`, which is
    the same expression the server's `bulbPosition` and the client's light
    anchor both resolve to.
    """
    index = state["active"]
    apex = ctx["bulbs"][index]
    bearing = state["stalks"][index]["beam"]
    half = math.radians(NC_BEAM_HALF_DEG)
    visible = _nc_visible_from(ctx["arena"], apex)

    # TELL.LIGHT, and drawn the way TELL draws everything: a dim fill over the
    # whole tested wedge with a crisp EDGE_W line on each of its three
    # boundaries. The two radial edges are the ones that matter - `beamHits`
    # tests the bearing against BEAM_HALF_ANGLE, so what the player is asked to
    # do is get across one of those two lines - and all three are carved by the
    # same `visible` predicate as the fill, because an edge that ran on through
    # a shadow fin would be drawing a boundary the light never reaches.
    floor = bmesh.new()
    _nc_band(
        floor,
        apex.x,
        apex.y,
        NC_BEAM_INNER,
        NC_BEAM_REACH,
        bearing - half,
        bearing + half,
        rings=46,
        sectors=10,
        visible=visible,
    )
    edges = bmesh.new()
    for side in (-1.0, 1.0):
        a = bearing + side * half
        _nc_edge_line(
            edges,
            (apex.x + math.cos(a) * NC_BEAM_INNER, apex.y + math.sin(a) * NC_BEAM_INNER),
            (apex.x + math.cos(a) * NC_BEAM_REACH, apex.y + math.sin(a) * NC_BEAM_REACH),
            steps=46,
            visible=visible,
        )
    _nc_edge_arc(edges, apex.x, apex.y, NC_BEAM_REACH, bearing - half, bearing + half, sectors=10, visible=visible)
    _nc_prop_pair("Beam", floor, edges, NC_TELL_LIGHT)

    # THE SHAFT: the lit volume itself, apex to floor - the lateral surface of
    # the cone whose footprint is the wedge above. Translucent so it reads as
    # light rather than as a wall, and so the hitbox on the stone stays the
    # thing the eye lands on.
    shaft = bmesh.new()
    tip = shaft.verts.new(tuple(apex))
    perimeter = []
    steps = 9
    for j in range(steps + 1):  # inner arc, left to right
        a = bearing - half + 2 * half * j / steps
        perimeter.append((apex.x + math.cos(a) * NC_BEAM_INNER, apex.y + math.sin(a) * NC_BEAM_INNER))
    for i in range(1, steps + 1):  # out along the right edge
        r = NC_BEAM_INNER + (NC_BEAM_REACH - NC_BEAM_INNER) * i / steps
        perimeter.append((apex.x + math.cos(bearing + half) * r, apex.y + math.sin(bearing + half) * r))
    for j in range(1, steps + 1):  # the far arc, back the other way
        a = bearing + half - 2 * half * j / steps
        perimeter.append((apex.x + math.cos(a) * NC_BEAM_REACH, apex.y + math.sin(a) * NC_BEAM_REACH))
    for i in range(1, steps):  # and home along the left edge
        r = NC_BEAM_REACH - (NC_BEAM_REACH - NC_BEAM_INNER) * i / steps
        perimeter.append((apex.x + math.cos(bearing - half) * r, apex.y + math.sin(bearing - half) * r))
    verts = [shaft.verts.new((x, y, _nc_floor_z(x, y) + NC_TG_LIFT)) for x, y in perimeter]
    for a, b in zip(verts, verts[1:] + verts[:1]):
        shaft.faces.new((tip, a, b))
    # Emission near zero on purpose. EEVEE adds an emissive surface's light on
    # top of its alpha, so the first pass of this - a bright, barely
    # transparent cone - rendered as a pale WALL across the frame and hid the
    # hitbox on the stone, which is the only thing in the picture that decides
    # whether anyone takes damage. The shaft is here to say where the light
    # comes from; the floor is here to say what it does.
    _nc_prop("BeamShaft", shaft, NC_TELL_LIGHT, 0.05, alpha=0.085)


def _nc_prop_strobewave(state, ctx):
    """Four novas out of the arena's centre at once - `strobewave.rings` with
    `ringWidth`, and nothing else. Out to r 61, past the party's arrival ring
    at 44 and past every shadow fin, which is the whole reason those four
    numbers were moved off {14, 26, 38}."""
    # BOTH EDGES OF EVERY RING. A nova has two boundaries and a player crosses
    # one of them going out and the other coming back in, so a ring drawn as one
    # fat band is a ring with no line to stand behind - which in four
    # overlapping waves is the difference between reading the gaps and guessing
    # them. `ringWidth` 3.0 either side of the tested radius, exactly.
    fill, edges = bmesh.new(), bmesh.new()
    for radius in (16.0, 30.0, 44.0, 58.0):
        _nc_band(fill, 0.0, 0.0, radius - 3.0, radius + 3.0, 0.0, TAU, rings=2, sectors=96)
        _nc_edge_ring(edges, 0.0, 0.0, radius - 3.0, sectors=96)
        _nc_edge_ring(edges, 0.0, 0.0, radius + 3.0, sectors=96)
    _nc_prop_pair("Strobe", fill, edges, NC_TELL_LIGHT)


def _nc_prop_lurepull(state, ctx):
    """The one telegraph in her book that had to be written by hand.

    `lurepull`'s own handler exists for this mark and nothing else: every
    borrowed telegraph fires at the boss's PIVOT, and hers is the submerged
    maw twenty-six studs under the arena, so the move with no damage and no
    dodge was hauling the party off their feet with nothing on screen. A
    "mark" at PIT_R + 3 = 18, at SHELF_Y, for the whole 0.7s wind-up.

    IT IS NOT A THIN RING AT r 18. The event fires at SHELF_Y, but the
    client's `mark` branch drops it onto whatever `surfaceUnder` finds and
    draws `Vfx.ring(radius * 0.35, radius)` - so the warning the party is
    actually given is a band from r 6.3 out to r 18: the pit's whole mouth and
    its rim. That is a far bigger and far better telegraph than the number 18
    reads as on its own, and it is the only thing on screen for the one move
    in her book with no damage, no dodge and no counterplay.
    """
    # AND THE WHOLE MOUTH IS DRAWN NOW, not the annulus from r 6.3 out. The
    # edge sits on r 18 - the number the pull is measured at - and the fill
    # runs in from it across the rim and over the hole. OVER, not into: inside
    # the pit the floor probe finds nothing in its ten-stud window and falls
    # back to a flat SHELF_Y, exactly as `markFloor` does, so the mark plates
    # the mouth of the pit. That is what the game draws here and it is a fair
    # thing to look at, because the pull's whole job is to move you toward it.
    fill, edges = bmesh.new(), bmesh.new()
    _nc_band(fill, 0.0, 0.0, 0.3, 18.0, 0.0, TAU, rings=5, sectors=96)
    _nc_edge_ring(edges, 0.0, 0.0, 18.0, sectors=96)
    _nc_prop_pair("Pull", fill, edges, NC_TELL_LIGHT)


def _nc_prop_feelerstrike(state, ctx):
    """`pattern = "everyone"`, radius 8, and one `extra` scattered `spread` 9
    away 0.5s later - the punish for standing still after a pull, so these
    stand exactly where the pull would have left the party."""
    spots = [_nc_at(r, d) for r, d in NC_PARTY]
    first = spots[0]
    spots.append((first[0] + 6.4, first[1] - 6.3))  # the `extra`, inside spread 9
    # TELL.LIMB: the barrage is the feelers, and a feeler is a limb.
    _nc_marks("Feeler", spots, NC_TELL_LIMB, 8.0)


def _nc_prop_dousehunt(state, ctx):
    """The strike lands DURING the dark, and that is the attack: `radius` 9,
    `arm` 0.65, `spread` 7 around where you were standing when the lights
    died. 0.65s to clear 9 studs is 13.8 studs/s against a walk of 16 - the
    escape is meant to be possible and hard, and this image is where you can
    check that the mark is the only thing on screen to run out of."""
    spots = [_nc_at(r, d) for r, d in NC_PARTY]
    spots.append((spots[2][0] - 4.9, spots[2][1] + 4.8))  # inside `spread` 7
    # Violet, like every other limb - and in this one frame it is the ONLY lit
    # thing in the arena, which is the whole move.
    _nc_marks("Douse", spots, NC_TELL_LIMB, 9.0)


def _nc_prop_mawopen(state, ctx):
    """THE FLOOR THE PARTY STANDS ON, drawn at its shipped size.

    `mawFloor` builds two anchored slabs and `placeMawFloor` pins them to the
    mouth: a tongue 11.0 x 9.0 (times SCALE 2.4) and a lip 5.0 x 9.0 hung 8.0
    studs forward and 1.4 down - the ledge that bridges the pit's rim. They
    are invisible in game (Transparency 1) and they are the entire reason the
    window is a place rather than a cutscene, so the one render whose job is
    "can you walk in" has to show them.
    """
    mouth = ctx["mouth"]
    if mouth is None:
        return
    scale = NC_MAW["scale"]
    rot = mouth.to_quaternion().to_matrix()
    bm = bmesh.new()
    box(bm, tuple(mouth.translation), (11.0 * scale, 9.0 * scale, 1.2), rot=rot)
    box(bm, tuple(mouth @ Vector((8.0 * scale, 0.0, -1.4))), (5.0 * scale, 9.0 * scale, 1.0), rot=rot)
    # TELL.LIGHT, on the door lane's precedent and for the door lane's reason:
    # gold in this fight is not only "her light is coming", it is the one thing
    # in the language that is somewhere to GO. These two slabs are the floor the
    # party walks in on, so they are drawn in the colour the fight uses for the
    # portcullis's safe centreline and in no other.
    _nc_prop("MawFloor", bm, NC_TELL_LIGHT, 1.1, alpha=0.34)


def _nc_prop_mawbite(state, ctx):
    """THE BITE'S REAL DAMAGE VOLUME, AND IT IS NOT A CIRCLE.

    `closeMaw` rolls 70-95 and delivers it to whoever `NoctyssPath.insideMouth`
    says is in there, and that test is a BOX in the mouth's own frame:
    |x| <= 7.0 * 2.4 = 16.8, |z| <= 5.6 * 2.4 = 13.44, and y from -3.0 up to
    9.0 * 2.4 = 21.6. Note the mixed units, which are the shipped ones: the
    two half-widths and the ceiling are scaled, the -3.0 floor is not.

    Drawn as twelve edge bars rather than a solid, so the jaw and whoever is
    standing under it stay visible inside their own hitbox.
    """
    mouth = ctx["mouth"]
    if mouth is None:
        return
    scale = NC_MAW["scale"]
    rot = mouth.to_quaternion().to_matrix()
    hx, hy = 7.0 * scale, 5.6 * scale
    z0, z1 = -3.0, 9.0 * scale
    bar = 0.7
    bm = bmesh.new()
    for sy in (-hy, hy):  # the four bars that run fore-and-aft
        for sz in (z0, z1):
            box(bm, tuple(mouth @ Vector((0.0, sy, sz))), (hx * 2, bar, bar), rot=rot)
    for sx in (-hx, hx):  # across
        for sz in (z0, z1):
            box(bm, tuple(mouth @ Vector((sx, 0.0, sz))), (bar, hy * 2, bar), rot=rot)
    for sx in (-hx, hx):  # and the uprights
        for sy in (-hy, hy):
            box(bm, tuple(mouth @ Vector((sx, sy, (z0 + z1) / 2))), (bar, bar, z1 - z0), rot=rot)
    # TELL.HEAD. Bone-white is the fight's MOUTH colour and this is the mouth's
    # own hitbox - the other shape in the language you cannot out-walk.
    #
    # And the box gets a floor now. Twelve bars are the edges of the volume;
    # with nothing between them the inside of the bite was undrawn, which is
    # the one thing no mark in this fight is allowed to be. A dim slab on the
    # box's own floor plane says "this whole footprint is in the mouth" without
    # plating over the jaw or the player standing under it.
    floor = bmesh.new()
    box(floor, tuple(mouth @ Vector((0.0, 0.0, z0 + 0.2))), (hx * 2, hy * 2, 0.3), rot=rot)
    _nc_prop("BiteFill", floor, NC_TELL_HEAD, NC_FILL_S, alpha=NC_LEAD_FILL_A)
    _nc_prop("BiteEdge", bm, NC_TELL_HEAD, NC_EDGE_S, alpha=NC_LEAD_EDGE_A)



# ---------------------------------------------- the three tentacle telegraphs
#
# Same rule as everything above: the shape is read out of the code that draws
# it. These three are NoctyssBodyController's `drawSlamMark`, `drawScytheMark`
# and `drawJabMark` - which are themselves built off NoctyssPath's own hit
# tests, so what is on the stone here is the hitbox and not an illustration of
# one.
#
# THE LIFT IS 0.09, NOT 0.15. The rest of this file draws floor telegraphs at
# `CreatureEventController`'s offset, because that is the controller that draws
# them; these three are drawn by the choir's own body controller, whose
# MARK_LIFT is 0.09. Six hundredths of a stud is nothing to look at and
# everything to copy correctly - the moment the two files stop being read off
# each other is the moment this render starts flattering the fight.
NC_MARK_LIFT = 0.09

# THE THREE LIMB COLOURS ARE GONE, AND THAT IS THE POINT. This block used to
# mirror NoctyssBodyController's TELL_SLAM / TELL_SCYTHE / TELL_JAB - orange,
# ice blue and a gold a hue step off the lanterns - on the reasoning that the
# limbs were "a third voice in the arena". They were a third, fourth and fifth,
# two of them unreadable against the lights they shared a hue with, and the
# fight retired all three: a slam, a scythe, a jab, a herd bar and a door bar
# are ALL a limb arriving, so they are all TELL.LIMB and the shape is what
# tells them apart. Nothing below picks a colour; they all ask the table.

# ...and the eye's, from the same file. EYE_R is up in the attack block: the
# drawn sphere and the creature row's capture sphere are one number.
NC_EYE_LIT = (1.000, 0.886, 0.510)  # Color3.fromRGB(255, 226, 130)
NC_EYE_DARK = (0.290, 0.227, 0.133)  # Color3.fromRGB(74, 58, 34)
NC_PUPIL_COLOUR = (0.039, 0.031, 0.047)  # Color3.fromRGB(10, 8, 12)
NC_HALO_COLOUR = (1.000, 0.769, 0.424)  # Color3.fromRGB(255, 196, 108)
NC_PUPIL_R = NC_EYE_R * 0.42
NC_PUPIL_RIDE = NC_EYE_R * 0.74
NC_HALO_R = NC_EYE_R * 2.3

# ARC_TILES: how many slabs the client lays the scythe's band out of. Mirrored
# so the band's own seams are where the game's are.
NC_ARC_TILES = 12


def _nc_stripe(bm, a, b, half, lift=NC_MARK_LIFT, steps=28, visible=None):
    """A draped rectangle from `a` to `b`, `half` studs either side - the slam
    stripe, and the only floor telegraph in her book that is not an annulus
    sector. Draped for the same reason `_nc_band` is: the shelf is not flat."""
    span = Vector((b[0] - a[0], b[1] - a[1], 0.0))
    length = span.length
    if length < 1e-3:
        return
    forward = span / length
    side = Vector((-forward.y, forward.x, 0.0))
    grid = []
    for i in range(steps + 1):
        at = Vector((a[0], a[1], 0.0)) + forward * (length * i / steps)
        row = []
        for sign in (-1.0, 1.0):
            x, y = at.x + side.x * half * sign, at.y + side.y * half * sign
            row.append(bm.verts.new((x, y, _nc_floor_z(x, y) + lift)))
        grid.append(row)
    for i in range(steps):
        if visible is not None:
            # Per-CELL, exactly as `_nc_band` does it, so a stripe carved by a
            # shadow fin is kept or dropped whole and its ends do not lie
            # about where the light stops.
            at = Vector((a[0], a[1], 0.0)) + forward * (length * (i + 0.5) / steps)
            if not visible(at.x, at.y):
                continue
        bm.faces.new((grid[i][0], grid[i][1], grid[i + 1][1], grid[i + 1][0]))


def _nc_active_attack(ctx):
    state = ctx["state"]
    index = state["active"]
    return index, state["attacks"][index]


def _nc_eye_props(ctx, camera):
    """THE EYE, AT THE HITBOX, LOOKING AT YOU - the treatment the client grew
    while these renders still drew a 1.7-stud lamp.

    `NoctyssBodyController` stops drawing the pack's bulb as a bulb: it stands
    a 4-stud sphere at `bulbPosition` (which IS the server's capture sphere, so
    the eye is exactly where it says it is), rides a dark pupil on the surface
    toward the CAMERA, and hangs a halo off it for the distance read. The pack
    still exports the little cage-and-bulb mesh and this file still poses it -
    so without these three props a review render would be judging a lantern the
    fight no longer draws.

    Three props, no more: globe, pupil, halo. The 26-stud light shaft is the
    client's finding-it-across-the-arena aid and would be a pale wall across
    every one of these frames - the same trade `BeamShaft` is written down for.
    """
    at_camera = Vector(camera(ctx) if callable(camera) else camera)
    state = ctx["state"]
    pupils, halos = bmesh.new(), bmesh.new()
    for index in sorted(ctx["bulbs"]):
        if not state["stalks"][index]["alive"]:
            continue
        # The fight's own number, not the placer's - see `_nc_bulb_position`.
        bulb = _nc_bulb_position(index, state)
        glow = _nc_pulse(state, index)
        if state.get("flare") == index:
            glow = 1.0
        # globe.Color = EYE_LIT:Lerp(EYE_DARK, 1 - glow), and Neon only while
        # it is lit - a snuffed eye is SmoothPlastic and emits nothing.
        colour = tuple(NC_EYE_LIT[i] + (NC_EYE_DARK[i] - NC_EYE_LIT[i]) * (1.0 - glow) for i in range(3))
        globe = bmesh.new()
        ellipsoid(globe, tuple(bulb), (NC_EYE_R,) * 3, subdiv=2)
        _nc_prop("ChoirEye%d" % index, globe, colour, 0.15 + 2.6 * glow if glow > 0.02 else 0.0)
        # THE PUPIL NEVER FADES. During a slam's snuff and a scythe's drag the
        # lantern is nearly out, and that is exactly when the player most needs
        # to know which limb is coming - so the ember keeps a dark centre.
        gaze = _nc_safe_unit(at_camera - bulb, (0.0, 0.0, 1.0))
        ellipsoid(pupils, tuple(bulb + gaze * NC_PUPIL_RIDE), (NC_PUPIL_R,) * 3, subdiv=2)
        if glow > 0.02:
            radius = NC_HALO_R * (0.82 + 0.34 * glow)
            ellipsoid(halos, tuple(bulb), (radius,) * 3, subdiv=2)
    _nc_prop("ChoirPupils", pupils, NC_PUPIL_COLOUR, 0.0)
    # Transparency = 1 - 0.22 * glow. THE ONE APPROXIMATION IN HERE: alpha is
    # a property of the material and the halos share one, so they are drawn at
    # the full-glow value and the dim ones read a little strong. Emission is
    # near zero for the reason BeamShaft carries: EEVEE adds an emissive
    # surface's light on top of its alpha, and seven bright 9-stud balls would
    # be seven holes punched in the frame.
    _nc_prop("ChoirHalos", halos, NC_HALO_COLOUR, 0.04, alpha=0.14)


def _nc_slam_marks(state, indices, name="Slam"):
    """EVERY SLAM STRIPE ON THE FLOOR THIS FRAME - `drawSlamMark`, for one limb
    or for a pair.

    From the collar the limb grew out of, THROUGH the latched point, at the
    width the capsule is actually tested at: `slamHits` is
    `segmentDistanceXZ(position, socket, target) <= SLAM.RADIUS`, so stepping
    off the stripe is stepping out of the damage, exactly and not
    approximately. What is drawn is a dim fill of the capsule's full width with
    an EDGE_W line on each of its two sides, laid ON the boundary - the line is
    the thing a player is actually asked to put their feet outside of, and a
    fill-only slab said "danger is roughly here", which is not information.

    ONE RAMP FOR THE WHOLE CALL. Both bars of a portcullis and both arms of a
    herd V are armed on the same frame by the same handler, so their brightness
    is the same number; the last one measured is the one used, and if the two
    ever stopped being simultaneous this is where it would show as a lie.
    """
    now = state.get("time", 0.0)
    fill, edges = bmesh.new(), bmesh.new()
    edge_a, fill_a, mix = 0.0, 0.0, 0.0
    drew = False
    for index in indices:
        attack = (state.get("attacks") or {}).get(index)
        if not attack or not _nc_is_slam(attack["kind"]):
            continue
        edge_a, fill_a, mix = _nc_tell_ramp(*_nc_tell_phase(attack, now))
        socket, target = _nc_socket_root(index), attack["target"]
        a, b = (socket.x, socket.y), (target.x, target.y)
        span = Vector((b[0] - a[0], b[1] - a[1], 0.0))
        if span.length < 1e-3:
            continue
        radius = NC_SLAM["radius"]
        _nc_stripe(fill, a, b, radius, lift=NC_MARK_LIFT)
        side = Vector((-span.y, span.x, 0.0)).normalized() * radius
        for sign in (-1.0, 1.0):
            _nc_edge_line(
                edges,
                (a[0] + side.x * sign, a[1] + side.y * sign),
                (b[0] + side.x * sign, b[1] + side.y * sign),
                lift=NC_MARK_LIFT,
            )
        drew = True
    if not drew:
        fill.free()
        edges.free()
        return False
    _nc_prop_pair(name, fill, edges, NC_TELL_LIMB, edge_a, fill_a, mix)
    return max(edge_a, fill_a) > NC_HIDDEN_A


def _nc_prop_stalkslam(state, ctx):
    """THE IMPACT LINE, in TELL.LIMB like every other limb in the fight. Drawn
    at the ramp's own value for the instant this pose names - which here is the
    first frame of the landed pose, hitbox still live (LIVE 0.4 outlasts STRIKE
    0.25), so the stripe is at its live brightness and not its windup one."""
    index, _ = _nc_active_attack(ctx)
    _nc_slam_marks(state, (index,))
    _nc_eye_props(ctx, _nc_cam_slam)


def _nc_prop_gloomscythe(state, ctx):
    """THE APPROACHING BAND, AND BOTH OF ITS EDGES.

    `drawScytheMark`: the band is laid on the arc the eye is ABOUT TO drag
    along - from `scytheTravel` to the end of the arc and no further, which is
    the client's own rule, and the whole arc while the limb is still bowing.
    Radius `reach` +/- SCYTHE.RADIUS off the same `scythePoint` the hit test
    asks, so the lit ground and the damage are one curve.

    THE TWO EDGES ARE THE POINT. Both boundaries are circles CONCENTRIC WITH
    THE SOCKET, which is what makes "step radially out" a line a player can
    stand against rather than a feeling. The fill's far half is dimmer, as the
    client dims it across its twelve tiles (Transparency + 0.3 end to end); the
    edges keep one alpha, because a line that fades out has a far end that
    means nothing.

    There is no separate pool under the eye any more. `scytheHits` is a flat
    sphere at `scythePoint` and that point is ON this band by construction, so
    the disc the older render drew was a second mark for one hitbox - the
    layering the whole TELL pass exists to end.
    """
    index, attack = _nc_active_attack(ctx)
    now = state.get("time", 0.0)
    u, live, since = _nc_tell_phase(attack, now)
    edge_a, fill_a, mix = _nc_tell_ramp(u, live, since)
    travel = 0.0 if u < 1.0 else _nc_scythe_travel(attack, now)
    root = _nc_socket_root(index)
    inner = attack["reach"] - NC_SCYTHE["radius"]
    outer = attack["reach"] + NC_SCYTHE["radius"]
    start = attack["from"] + attack["dir"] * attack["arc"] * travel
    end = attack["from"] + attack["dir"] * attack["arc"]
    middle = start + (end - start) * 0.5
    tiles = max(2, NC_ARC_TILES // 2)
    near, far, edges = bmesh.new(), bmesh.new(), bmesh.new()
    _nc_band(near, root.x, root.y, inner, outer, start, middle, rings=2, sectors=tiles, lift=NC_MARK_LIFT)
    _nc_band(far, root.x, root.y, inner, outer, middle, end, rings=2, sectors=tiles, lift=NC_MARK_LIFT)
    for radius in (inner, outer):
        _nc_edge_arc(edges, root.x, root.y, radius, start, end, sectors=NC_ARC_TILES, lift=NC_MARK_LIFT)
    # Split in two rather than into all twelve of the client's slabs: two
    # strengths carry the "it is arriving" read, and twelve props for one
    # telegraph is twelve objects to look at in an outliner. The offsets are
    # the midpoints of the client's own ramp across each half.
    _nc_prop_pair("ScytheNear", near, None, NC_TELL_LIMB, edge_a, max(fill_a - 0.05, 0.05), mix)
    _nc_prop_pair("ScytheFar", far, None, NC_TELL_LIMB, edge_a, max(fill_a - 0.15, 0.05), mix)
    _nc_prop_pair("Scythe", None, edges, NC_TELL_LIMB, edge_a, fill_a, mix)
    _nc_eye_props(ctx, _nc_cam_scythe)


def _nc_prop_feelerstrike_jab(state, ctx):
    """THE JAB'S MARK IS A DISC, because the jab is a point: there is nowhere to
    step ALONG, only off - so its one boundary is a circle, and the edge ring is
    laid on JAB.RADIUS with the whole disc held dim behind it.

    The hitbox itself is the one 3D test of the three: `jabHits` measures the
    full distance to the latched point, so a spear coming in at chest height
    catches you at chest height. The disc is the floor under it.
    """
    index, attack = _nc_active_attack(ctx)
    edge_a, fill_a, mix = _nc_tell_ramp(*_nc_tell_phase(attack, state.get("time", 0.0)))
    target = attack["target"]
    radius = NC_JAB["radius"]
    fill, edges = bmesh.new(), bmesh.new()
    _nc_band(fill, target.x, target.y, 0.3, radius, 0.0, TAU, rings=3, sectors=40, lift=NC_MARK_LIFT)
    _nc_edge_ring(edges, target.x, target.y, radius, lift=NC_MARK_LIFT, sectors=40)
    _nc_prop_pair("Jab", fill, edges, NC_TELL_LIMB, edge_a, fill_a, mix)
    _nc_eye_props(ctx, _nc_cam_jab)


# ------------------------------------------- the head, using the choir's hands
#
# TWO LIMBS AND A MOUTH, AND NEITHER MOVE IS A NEW HIT SHAPE. A portcullis is
# two ordinary slams across the doorway; a herding snap is two ordinary slams
# plus a bite at her own rim. So both of these draw `_nc_slam_marks` for the
# bars and add exactly ONE thing of their own - the lane, and the ring.


def _nc_prop_portcullis(state, ctx):
    """THE DOOR: two violet bars, and the gold slot between them.

    A BAR IS NOT A NEW COLOUR. The two capsules are `stalkslam` in every respect
    the server can see (`isSlam`), so they are drawn by the same function in the
    same TELL.LIMB as every other limb. What says "door" is the third mark: the
    8-stud walkable centreline the two capsules leave (DOOR.HALF 11 against
    SLAM.RADIUS 7), in TELL.LIGHT at one steady Transparency.

    IT IS THE ONE MARK IN THIS FIGHT THAT IS NOT A COUNTDOWN, because it is the
    only one that is somewhere to GO rather than somewhere to leave - so it has
    no ramp, and DOOR_LANE_T is read off the controller rather than chosen here.
    A safe slot implied by the gap between two bright bars is not a slot anyone
    finds in a black room with a roof coming down.
    """
    _nc_slam_marks(state, sorted((state.get("attacks") or {}).keys()), name="Door")
    _, _, centre, forward = _nc_door_line(state)
    half = NC_DOOR["lane_length"] * 0.5
    lane = bmesh.new()
    _nc_stripe(
        lane,
        (centre.x - forward.x * half, centre.y - forward.y * half),
        (centre.x + forward.x * half, centre.y + forward.y * half),
        # The gap the two capsules leave, exactly: what is drawn safe IS what
        # is untested.
        max(NC_DOOR["half"] - NC_SLAM["radius"], 0.25),
        lift=NC_MARK_LIFT,
        steps=34,
    )
    _nc_prop("DoorLane", lane, NC_TELL_LIGHT, 1.3, alpha=_nc_tell_alpha(NC_DOOR["lane_t"]))
    _nc_eye_props(ctx, _nc_cam_door)


def _nc_prop_herdingsnap(state, ctx):
    """THE FUNNEL AND THE BITE: two violet bars converging on the pit's rim, and
    a bone-white ring on the circle `snapHits` measures against.

    THE RING IS TELL.HEAD, and it is the only colour in the fight that is
    neither a limb nor a light: bone is reserved for her MOUTH, the one shape
    here you cannot out-walk. It sits exactly on PIT_R + SNAP.MARGIN, so a foot
    against the outside of that line is a foot outside the bite.

    AND ITS INTERIOR IS DELIBERATELY NOT FILLED. Every other mark in this fight
    holds its whole hitbox dim behind its edge, because an undrawn core is a
    piece of hitbox nobody was told about. This one has no core to draw: the
    inside of that circle is a THIRTY-STUD HOLE with a head coming up it, and a
    neon plate over the top would hide the one thing in the frame worth looking
    at. The fill is the controller's own SNAP_BAND - 2.2 studs moved INBOARD off
    the boundary - which gives the ring its body at distance without plating
    over the pit. That is the fight's choice, drawn as the fight makes it.
    """
    _nc_slam_marks(state, sorted((state.get("attacks") or {}).keys()), name="Herd")
    edge_a, fill_a, mix = _nc_tell_ramp(*_nc_snap_tell(state))
    radius = NC_PIT_R + NC_SNAP["margin"]
    band = NC_SNAP["band"]
    inner = radius - NC_TELL_EDGE_W * 0.5 - band * 0.5
    tiles = NC_SNAP["tiles"]
    fill, edges = bmesh.new(), bmesh.new()
    _nc_tile_ring(fill, 0.0, 0.0, inner, band, tiles, lift=NC_MARK_LIFT)
    _nc_tile_ring(edges, 0.0, 0.0, radius, NC_TELL_EDGE_W, tiles, lift=NC_MARK_LIFT)
    _nc_prop_pair("Snap", fill, edges, NC_TELL_HEAD, edge_a, fill_a, mix)
    _nc_eye_props(ctx, _nc_cam_snap)


NC_PROPS = {
    "lightsweep": _nc_prop_lightsweep,
    "lightsweep_apex": _nc_prop_lightsweep,
    "strobewave": _nc_prop_strobewave,
    "lurepull": _nc_prop_lurepull,
    "feelerstrike_barrage": _nc_prop_feelerstrike,
    "dousehunt": _nc_prop_dousehunt,
    "mawopen": _nc_prop_mawopen,
    "mawopen_inside": _nc_prop_mawopen,
    "mawbite": _nc_prop_mawbite,
    "stalkslam": _nc_prop_stalkslam,
    "gloomscythe": _nc_prop_gloomscythe,
    "feelerstrike": _nc_prop_feelerstrike_jab,
    "portcullis": _nc_prop_portcullis,
    "herdingsnap": _nc_prop_herdingsnap,
}


# ------------------------------------------------------------- the states


def _nc_pose_rest():
    # AMBIENT, and the fight's one puzzle in a single frame. `time` is
    # deliberately not zero: at zero every sway and breath term is exactly
    # zero, so the old renders were all of a choir holding its breath. 3.25s
    # is one and a quarter sway periods in - seven stalks visibly out of phase
    # with each other (phase = index * 1.7) - and it is also the quarter-cycle
    # of PULSE_PERIOD at which the choir's breath peaks, which puts the TRUE
    # LURE, half a cycle behind, at its darkest. The odd one out is the answer.
    state = nc_state()
    state["time"] = 3.25
    state["true_lure"] = 4
    return state


def _nc_pose_sweep():
    # One stalk leaned onto its bearing mid-sweep, the rest at rest: the
    # telegraph and the attack are the same object, and this is the frame
    # that has to prove it reads from the floor.
    state = nc_state()
    # THE BEARING IS SOLVED, NOT PICKED. `lightsweep`'s windup sets
    # `beamAngle` to `atan2` from the SOCKET to the player it chose, so the
    # only bearings this attack can ever run on are ones that point from a
    # collar at somebody standing on the shelf. The 196 degrees this pose used
    # to carry was not one of them: it aimed socket 3's crook outward, which
    # put the lantern at r 58 and ran the 74-stud wedge out to r 130 - sixty
    # studs past the last walkable stone, over open water, hitting nobody.
    socket_x, socket_y = _nc_at(*NC_SOCKETS[3])
    target_x, target_y = _nc_at(*NC_PARTY[0])
    state["stalks"][3]["lean"] = 1.0
    state["stalks"][3]["beam"] = math.atan2(target_y - socket_y, target_x - socket_x)
    state["active"] = 3  # `state.activeStalk` - ONE at a time, always
    state["time"] = 3.25
    return state


def _nc_pose_strobe():
    # Every lantern at the top of its breath at once. The only moment the
    # arena is fully lit, and it is trying to kill you while it shows you.
    state = nc_state()
    state["time"] = 0.65  # a quarter cycle: `pulse` = 1 for the whole choir
    state["true_lure"] = 4
    state["flash"] = 2.4
    return state


def _nc_pose_lurepull():
    # The true lure flares and hauls the shelf toward the hole she is under.
    # No stalk leans: `lurepull` has no bearing and no dodge, which is why the
    # rim mark is the only thing the player gets and why it had to be drawn.
    state = nc_state()
    state["true_lure"] = 4
    state["time"] = 1.95  # three quarters: the choir low, the true lure high
    state["flare"] = 4
    return state


def _nc_pose_feeler():
    state = nc_state()
    state["time"] = 3.25
    state["true_lure"] = 4
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
    state["stalks"][1]["beam"] = math.radians(96.0)
    state["active"] = 1
    state["time"] = 3.25
    return state


def _nc_pose_mawrise():
    # THE EMERGENCE. `updateNoctyss` drives mawRise at 0.55/s and holds the
    # gape shut until rise passes 0.75, so a half-risen maw is a SHUT one -
    # this is the frame roughly a second in, and the jaw is closed because the
    # code closes it, not because a closed jaw framed better.
    state = nc_state()
    for stalk in state["stalks"]:
        stalk["douse"] = 0.35
    state["maw_rise"] = 0.5
    state["maw_gape"] = 0.0
    state["time"] = 3.25
    return state


def _nc_pose_maw():
    state = nc_state()
    for stalk in state["stalks"]:
        stalk["douse"] = 0.35
    state["maw_rise"] = 1.0
    state["maw_gape"] = 1.0
    state["time"] = 3.25
    return state


def _nc_pose_bite():
    # The window closing. The jaw is most of the way shut and anyone still
    # inside is about to wear it - the mouth IS the timer.
    state = nc_state()
    state["maw_rise"] = 1.0
    state["maw_gape"] = 0.22
    state["time"] = 3.25
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




# ------------------------------------------------- the three limb attacks
#
# One frame each, and the frame is CHOSEN AS A TIME rather than as a shape:
# every one of these sets `start` so that at the choir's own 3.25s clock the
# attack is exactly at the instant named below, and then lets the solver put
# the limb wherever the fight would have put it. Nothing here poses a stalk by
# hand, which is the only way a render of an attack is worth anything.


# --------------------------------------------- the head, using the choir
#
# THE TWO MOVES WHERE THE MOUTH AND THE LIMBS ARE ONE ATTACK. Both are posed
# the way the three above are - by naming an INSTANT and letting the fight's
# own arithmetic put everything where it would be - and for these two that
# arithmetic is unusually load-bearing, because the bars and the head are armed
# by the same handler a fixed number of seconds apart.


def _nc_pose_portcullis():
    # THE DOOR, DOWN, AND THE WINDOW STILL OPEN. `armPortcullis` fires
    # DOOR.LEAD (1.6s) before the jaw shuts, which is exactly one SLAM.WINDUP
    # (1.2) plus SLAM.LIVE (0.4) - so the bars finish landing on the same frame
    # the bite lands, and a player in the mouth reads the exit narrowing while
    # the roof comes down. The instant chosen here is the one the stalkslam
    # pose uses for the same reason: the first frame of the landed pose, with
    # both capsules live.
    state = nc_state()
    state["time"] = 3.25
    state["true_lure"] = 4
    # The window's own pose: fully risen, fully gaped. `doorTargets` is solved
    # off `mawMouth`, so the door cannot be placed until the head is.
    state["maw_rise"] = 1.0
    state["maw_gape"] = 1.0
    for stalk in state["stalks"]:
        stalk["douse"] = 0.35
    target_a, target_b, _, _ = _nc_door_line(state)
    index_a, index_b = _nc_flanking(state)
    start = 3.25 - (NC_SLAM["windup"] + NC_SLAM["strike"])
    for index, target in ((index_a, target_a), (index_b, target_b)):
        # A nil side is not an error - `flankingStalks` returns one for a side
        # with nobody left, and one bar is a legitimate half-door.
        if index is None:
            continue
        _nc_set_attack(state, {"kind": "portcullis", "index": index, "target": target, "start": start})
    state["active"] = index_a if index_a is not None else index_b
    return state


def _nc_pose_herdingsnap():
    # THE V, THEN THE MOUTH - and the gap between them is the fight's, not a
    # framing choice. `fire` runs on the frame the bars' windup ends, so
    # snapStart == slam start + SLAM.WINDUP exactly; the bars' hitboxes are
    # live from WINDUP to WINDUP + LIVE (1.2 to 1.6) and the rise runs 1.2 to
    # 2.2. The two windows OVERLAP FOR 0.4s AND NO LONGER.
    #
    # This frame is the top of the rise - the last frame before the bite, ring
    # at its brightest, head at SNAP.RISE_TO with the lower jaw and the fang
    # line breached over the rim. By then the bars have been down for 0.6s,
    # which is twice TELL.FADE, so THEIR FLOOR MARKS ARE GONE: `tellPhase` says
    # faded and `_nc_slam_marks` builds nothing. That is not an omission, it is
    # the move - the stripes tell you where the funnel is a full second before
    # the mouth arrives, and by the time it arrives they have done their job.
    # The V is still in the frame as the two LIMBS, which at recover u ~ 0.47
    # have peeled only at the base and still lie along their own lines.
    state = nc_state()
    state["time"] = 3.25
    state["true_lure"] = 4
    index_a, index_b, target_a, target_b, apex = _nc_herd_targets(state, _nc_at(*NC_PARTY[1]))
    snap_start = 3.25 - NC_SNAP["rise"]
    start = snap_start - NC_SLAM["windup"]
    for index, target in ((index_a, target_a), (index_b, target_b)):
        if index is None:
            continue
        # "stalkslam", not "herdingsnap": `armChoirAttackAt` arms the V's two
        # bars as ordinary slams, and the snap travels as its own descriptor.
        _nc_set_attack(state, {"kind": "stalkslam", "index": index, "target": target, "start": start})
    state["snap_start"] = snap_start
    # `snapRise` at the top of the rise, which the server publishes as MawRise
    # and `_nc_maw_z` then smoothsteps exactly as `mawCFrame` does. The 0.406
    # in NoctyssPath was solved against a LINEAR read of that curve, so the
    # jaws sit lower here than that comment's -3.6 - this render shows the
    # shipped composition, which is the one the player sees.
    state["maw_rise"] = NC_SNAP["rise_to"]
    # Fn.tickHerd floors MawGape at 0.12 for the frames a snap is live, so the
    # client's bite note is not suppressed. A snap is a mouth ajar, not agape.
    state["maw_gape"] = 0.12
    state["active"] = index_a
    state["herd_apex"] = apex
    return state


def _nc_pose_stalkslam():
    # THE INSTANT THE STRIKE ENDS: t = WINDUP + STRIKE, which `attackPhase`
    # reads as recover at u = 0 - the first frame of the landed pose, with the
    # limb lying flat along its line and the hitbox still live (LIVE 0.4
    # outlasts STRIKE 0.25). `attackKeep` is 1 the whole length of the stalk at
    # u = 0, so nothing has peeled up yet: this is the crack, not the recovery.
    #
    # The lantern is at the EMBER and no lower: `attackGlow` in recover at
    # u = 0 is 0.09, the snuff's floor, carried onto the stalk as a douse
    # because that is the multiplier `_nc_pulse` already understands.
    state = nc_state()
    state["time"] = 3.25
    state["true_lure"] = 4
    index = 6
    _nc_set_attack(
        state,
        {
            "kind": "stalkslam",
            "index": index,
            # Aimed at a real player position, snapped to where a lantern can
            # sit ON the stone (`aimPoint`) and pulled inside the arm
            # (`clampToReach`) - socket 6 to the party's far man is most of
            # the width of the shelf, which is the read this frame is for.
            "target": _nc_aim_point(*_nc_at(*NC_PARTY[2])),
            "start": 3.25 - (NC_SLAM["windup"] + NC_SLAM["strike"]),
        },
    )
    state["active"] = index
    return state


def _nc_pose_gloomscythe():
    # HALF WAY ROUND THE ARC: strike at u = 0.5, which `scytheTravel` turns
    # into travel 0.5 - and travel 0.5 is the latched bearing itself, because
    # `setAttack` starts the sweep half an arc BEHIND the target so it travels
    # through where the player was standing rather than stopping at them. So
    # this frame is the eye passing over the man it was aimed at.
    state = nc_state()
    state["time"] = 3.25
    state["true_lure"] = 4
    index = 1
    _nc_set_attack(
        state,
        {
            "kind": "gloomscythe",
            "index": index,
            "target": _nc_aim_point(*_nc_at(*NC_PARTY[1])),
            "start": 3.25 - (NC_SCYTHE["bow"] + NC_SCYTHE["sweep"] * 0.5),
            # +1 in AUTHORED degrees, which is dir = -1 in the fight's mirror.
            # Chosen so the band runs outboard of the socket ring instead of
            # over the pit: `scythePoint` does not consult the floor, so a
            # sweep aimed inward draws a lit band across a 30-stud hole. That
            # is a real property of the shipped function and it is written down
            # here rather than rendered as if the stone were there.
            "dir": 1,
        },
    )
    state["active"] = index
    return state


def _nc_pose_feelerstrike_jab():
    # THE END OF THE SPEAR. The strike span is THRUST + HOLD (0.12 + 0.1), and
    # the thrust itself is only the first 0.12 of it - so t = COIL + THRUST is
    # the frame the cubic ease-out finishes: fully extended, at full stretch,
    # at the start of the beat it holds out there. The S has just gone out of
    # the limb.
    state = nc_state()
    state["time"] = 3.25
    state["true_lure"] = 4
    index = 5
    _nc_set_attack(
        state,
        {
            "kind": "feelerstrike",
            "index": index,
            # `aimPoint` height, which is the shelf plus one eye radius: the
            # eye's CENTRE at 5.5 is a spear coming in at a standing player's
            # chest, and `jabHits` is the one hit test of the three that reads
            # height at all.
            "target": _nc_aim_point(*_nc_at(*NC_PARTY[0])),
            # MID-THRUST, AND INSIDE TELL.FLASH. The hitbox goes live at COIL,
            # and 0.202 of the strike span is 0.044s after that - under the
            # 0.08s flash - so this disc renders at FLASH_T with the colour
            # lerped WHITE_MIX of the way to white. That is not the violet
            # going missing, it is the one frame in the language that is
            # allowed under NEON_MIN: the frame a warning stops being a warning
            # and starts being damage. The violet reads on the slam and the
            # scythe, which are the same TELL.LIMB a beat later in their own
            # live windows.
            #
            # The cubic ease-out is 1 - (1 - u/span)^3, so three
            # quarters of the travel is done at u = 0.202 of the strike - the
            # S is out of the limb, the eye is committed and still short of the
            # point, and the disc it is about to land on is still on the stone
            # to be seen. At the end of the thrust the eye is sitting ON its
            # own mark and the mark is a 4-stud sphere's worth of nothing.
            "start": 3.25 - (NC_JAB["coil"] + (NC_JAB["thrust"] + NC_JAB["hold"]) * 0.202),
        },
    )
    state["active"] = index
    return state


# ------------------------------------------------------------- the cameras
#
# One per moment, and each one picked for what the image has to PROVE rather
# than for what looks best. Where the thing being proved is a position the
# code computes - the beam's apex, the mouth's floor - the camera is a
# callable off the same frame the geometry was placed on, so it cannot drift
# out of agreement with its subject the way a hand-typed triple would.


def _nc_on_shelf(x, y, z, limit=62.0):
    """Keep a camera ON THE STONE. The shelf ends at r 68 and drops into water,
    so an eye-height camera further out than this is standing in the sea - and
    every "from where the party is" claim these images make would be false."""
    r = math.hypot(x, y)
    if r > limit and r > 1e-6:
        x, y = x * limit / r, y * limit / r
    return (x, y, z)


def _nc_beam_frame(ctx):
    active = ctx["state"]["active"]
    return ctx["bulbs"][active], ctx["state"]["stalks"][active]["beam"]


def _nc_cam_beam_eye(ctx):
    """OFF THE BEAM'S SHOULDER, at something near a player's eye - the angle a
    party member watching the sweep cross the shelf actually has.

    Deliberately NOT down the beam's own axis: from in front of the light the
    wedge foreshortens to a line and the image proves nothing about how much
    floor it covers, which is the only question a reviewer has about it.
    """
    apex, bearing = _nc_beam_frame(ctx)
    mid_x = apex.x + math.cos(bearing) * 34.0
    mid_y = apex.y + math.sin(bearing) * 34.0
    side = bearing + math.radians(74.0)
    return _nc_on_shelf(mid_x + math.cos(side) * 56.0, mid_y + math.sin(side) * 56.0, 12.0)


def _nc_cam_beam_at(ctx):
    apex, bearing = _nc_beam_frame(ctx)
    return (apex.x + math.cos(bearing) * 26.0, apex.y + math.sin(bearing) * 26.0, 8.0)


def _nc_cam_beam_high(ctx):
    """Overhead: the one angle that proves the apex is under the LANTERN and
    not in the socket. The gap between the collar and the point of the wedge
    is the correction `beamHits` was rewritten for."""
    apex, bearing = _nc_beam_frame(ctx)
    return (apex.x + math.cos(bearing) * 30.0, apex.y + math.sin(bearing) * 30.0 - 26.0, 132.0)


def _nc_cam_beam_high_at(ctx):
    apex, bearing = _nc_beam_frame(ctx)
    return (apex.x + math.cos(bearing) * 30.0, apex.y + math.sin(bearing) * 30.0, 1.5)


def _nc_cam_mouth_at(ctx):
    return tuple(ctx["mouth"].translation) if ctx["mouth"] else (0.0, 0.0, 10.0)


def _nc_cam_mouth_approach(ctx):
    """Down her lane, off the shelf's outer edge and lifted just enough to get
    the brow (~44 studs) and the mouth's floor (~2.5) in one frame.

    The lane is not decoration: `laneFor` surfaces her facing one of the six
    GAPS between the shadow fins, and this camera stands in that gap, which is
    where the party is standing when she finishes rising.
    """
    yaw = math.radians(NC_MAW["yaw"])
    return (math.cos(yaw) * 88.0, math.sin(yaw) * 88.0, 21.0)


def _nc_cam_rise_approach(ctx):
    """The same lane, lower and closer: mid-rise she is barely out of the hole
    and a camera framed for the finished pose would show an empty pit."""
    yaw = math.radians(NC_MAW["yaw"])
    return (math.cos(yaw) * 62.0, math.sin(yaw) * 62.0, 12.0)


def _nc_cam_inside(ctx):
    """ON THE TONGUE. The mouth's own frame: +X runs out toward the snout, so
    this stands the camera near the front of the walkable slab at about chest
    height over it, looking back down the throat at the gullet - which is the
    exact shot a melee player gets, and the only way to check that the weak
    point is reachable rather than decorative."""
    # Local (14, 0, 6.2): 14 studs forward of the mouth's centre is the front
    # third of the tongue slab (it is 26.4 long), and 6.2 up is about a
    # player's eye over its top face - so this is a standing shot, not a
    # floating one.
    return tuple(ctx["mouth"] @ Vector((16.0, 0.0, 6.2)))


def _nc_cam_gullet(ctx):
    return tuple(ctx["gullet"]) if ctx["gullet"] else (0.0, 0.0, 24.0)


def _nc_cam_gullet_high(ctx):
    """The gullet, aimed a little over its head. Looking straight AT it fills
    the frame with one glowing lump and no context; lifting the aim brings the
    upper jaw's teeth into the top of the shot, which is the thing that tells
    a reviewer this is the inside of a mouth and not a cave."""
    if not ctx["gullet"]:
        return (0.0, 0.0, 24.0)
    return tuple(ctx["gullet"] + Vector((0.0, 0.0, 9.0)))


def _nc_outboard(x, y, other_x, other_y):
    """Of two candidate camera spots, the one further from the arena's centre.

    The limb attacks all run across the socket ring, so the perpendicular a
    camera could stand on points INTO THE PIT half the time - and a review
    camera in the hole is a review camera looking at the underside of the
    shelf. Picked rather than typed, so it stays right if a target moves.
    """
    return (x, y) if math.hypot(x, y) >= math.hypot(other_x, other_y) else (other_x, other_y)


def _nc_cam_slam(ctx):
    """OFF THE SHOULDER OF THE IMPACT LINE, at about twice a player's height.
    Down the line the stripe foreshortens to nothing and the one question this
    image answers - how much floor is under the limb - cannot be read."""
    index, attack = _nc_active_attack(ctx)
    root, target = _nc_socket_root(index), attack["target"]
    mid = ((root.x + target.x) * 0.5, (root.y + target.y) * 0.5)
    span = Vector((target.x - root.x, target.y - root.y, 0.0))
    side = Vector((-span.y, span.x, 0.0)).normalized() * 76.0
    x, y = _nc_outboard(mid[0] + side.x, mid[1] + side.y, mid[0] - side.x, mid[1] - side.y)
    # OFF THE STONE AND ABOVE IT, unlike the beam cameras: the stripe is most
    # of the shelf long, and an eye-height camera far enough back to hold all
    # of it would be standing in the sea.
    return (x, y, 50.0)


def _nc_cam_slam_at(ctx):
    index, attack = _nc_active_attack(ctx)
    root, target = _nc_socket_root(index), attack["target"]
    return ((root.x + target.x) * 0.5, (root.y + target.y) * 0.5, 5.0)


def _nc_cam_scythe(ctx):
    """AHEAD OF THE SWEEP, looking back down it. The band is drawn on the
    ground the eye has not reached yet, so the shot that proves it is the one
    standing where the sweep is going - which is also where the player it is
    aimed at is standing."""
    index, attack = _nc_active_attack(ctx)
    root = _nc_socket_root(index)
    # The MIDDLE of the ground the eye has not covered yet, and high: the
    # first version of this stood at eye height on the arc's last bearing and
    # put a shadow fin between the lens and the sweep, which is a fair thing
    # for a player to be behind and a useless place to review a telegraph from.
    travel = _nc_scythe_travel(attack, ctx["state"].get("time", 0.0))
    mid = attack["from"] + attack["dir"] * attack["arc"] * (travel + 1.0) * 0.5
    reach = attack["reach"] + 46.0
    return (root.x + math.cos(mid) * reach, root.y + math.sin(mid) * reach, 38.0)


def _nc_cam_scythe_at(ctx):
    """Between the eye and the far end of the band, so the frame holds both the
    light on the stone and the stone it has not reached."""
    index, attack = _nc_active_attack(ctx)
    travel = _nc_scythe_travel(attack, ctx["state"].get("time", 0.0))
    at = _nc_scythe_point(index, attack, (travel + 1.0) * 0.5)
    # Aimed twelve studs up rather than at the stone: the eye is on the floor
    # and the limb that put it there arcs thirty studs over it, and a frame
    # that held only the lit ground would be a frame of a telegraph with no
    # tentacle in it.
    return (at.x, at.y, 12.0)


def _nc_inboard(x, y, other_x, other_y):
    """Of two candidate camera spots, the one NEARER the arena's centre.

    The shadow fins stand in a ring at r 46-58 and they are tall: a camera
    outside them is a camera behind a rock, which is exactly what the first
    version of the jab frame rendered. Inside the socket ring the fins are all
    behind the lens, where the fight puts them for a player standing in.
    """
    return (x, y) if math.hypot(x, y) <= math.hypot(other_x, other_y) else (other_x, other_y)


def _nc_cam_jab(ctx):
    """BESIDE THE SPEAR, at the height it is coming in at. The jab is the one
    hitbox in the fight that is a sphere in full 3D, so the frame has to be
    able to show that the eye is at chest height and not on the floor."""
    index, attack = _nc_active_attack(ctx)
    root, target = _nc_socket_root(index), attack["target"]
    span = Vector((target.x - root.x, target.y - root.y, 0.0)).normalized()
    side = Vector((-span.y, span.x, 0.0)) * 46.0
    x, y = _nc_outboard(
        target.x + side.x + span.x * 6.0,
        target.y + side.y + span.y * 6.0,
        target.x - side.x + span.x * 6.0,
        target.y - side.y + span.y * 6.0,
    )
    # OFF THE STONE AND HIGH, for the same reason the slam's camera is: down
    # here among the sockets the lens is inside another stalk's lantern, and
    # the frame comes back as one white eye that is not the one striking.
    return (x, y, 34.0)


def _nc_cam_jab_at(ctx):
    _, attack = _nc_active_attack(ctx)
    return tuple(attack["target"])


def _nc_cam_door(ctx):
    """OUTSIDE THE DOOR AND OFF ITS SHOULDER, high enough to see through it.

    The question this frame answers is "can you leave", so the lens has to hold
    both bars AND the slot between them at once - which means standing on the
    side the party arrives from, a little off the lane so the two capsules do
    not overlap into one wall, and high enough that the gold centreline is not
    hidden behind the near bar.
    """
    _, _, centre, forward = _nc_door_line(ctx["state"])
    side = Vector((-forward.y, forward.x, 0.0))
    # AND IT IS HIGH. The door stands twenty-four studs in front of a fifty-stud
    # head, so any camera low enough to look THROUGH the doorway is a camera with
    # her skull filling the frame behind it. From up here the two bars, the slot
    # between them and the mouth they lead into are all one plan.
    return (
        centre.x + forward.x * 70.0 + side.x * 18.0,
        centre.y + forward.y * 70.0 + side.y * 18.0,
        96.0,
    )


def _nc_cam_door_at(ctx):
    _, _, centre, _ = _nc_door_line(ctx["state"])
    return (centre.x, centre.y, 2.0)


def _nc_cam_snap(ctx):
    """OUTBOARD OF THE V'S POINT, looking back across the rim.

    The apex is ON the pit's lip, so this stands where the funnel is pushing
    people and looks back down it: the two limbs come in from the left and the
    right of frame, the bone ring crosses the middle, and the mouth breaching
    inside it is the thing at the end. High, because the ring is 38 studs
    across and an eye-height camera would see it edge-on as a line.
    """
    apex = ctx["state"].get("herd_apex") or Vector((NC_PIT_R, 0.0, 0.0))
    out = _nc_safe_unit(Vector((apex.x, apex.y, 0.0)), (1.0, 0.0, 0.0))
    # STEEP, and not as a style. The ring is 38 studs across and lies flat on
    # the rim; from an eye-height camera on the apex's bearing the head
    # breaching inside it hides the whole near half - which is the half the
    # funnel is pushing people onto. Looking down puts the line, the hole and
    # both arms in one frame.
    return (out.x * 74.0, out.y * 74.0, 94.0)


def _nc_cam_snap_at(ctx):
    return (0.0, 0.0, 2.0)


NC_POSES = {
    "rest": {
        "label": "AT REST - seven breathing together and ONE breathing against them",
        "state": _nc_pose_rest,
        "cam": (58.0, -84.0, 54.0),
        "at": (0.0, 0.0, 27.0),
        "lens": 46,
    },
    "flinch": {
        "label": "HIT REACTION - the lantern is shot and the stalk whips back",
        "state": _nc_pose_flinch,
        "cam": (52.0, -66.0, 34.0),
        "at": (-8.0, 6.0, 26.0),
    },
    "lightsweep": {
        "label": "LIGHTSWEEP - the lit wedge IS the hitbox, apexed at the lantern",
        "state": _nc_pose_sweep,
        "props": _nc_prop_lightsweep,
        "cam": _nc_cam_beam_eye,
        "at": _nc_cam_beam_at,
        "lens": 30,
    },
    "lightsweep_apex": {
        "label": "LIGHTSWEEP FROM ABOVE - the wedge hangs off the bulb, and a fin cuts it",
        "state": _nc_pose_sweep,
        "props": _nc_prop_lightsweep,
        "cam": _nc_cam_beam_high,
        "at": _nc_cam_beam_high_at,
        "lens": 30,
    },
    "strobewave": {
        "label": "STROBEWAVE - four novas at 16/30/44/58, and the only fully lit moment",
        "state": _nc_pose_strobe,
        "props": _nc_prop_strobewave,
        "cam": (0.0, -132.0, 96.0),
        "at": (0.0, 0.0, 4.0),
        "lens": 34,
    },
    "lurepull": {
        "label": "LUREPULL - the true lure flares and the pit's rim is the only warning",
        "state": _nc_pose_lurepull,
        "props": _nc_prop_lurepull,
        "cam": (46.0, 50.0, 30.0),
        "at": (0.0, 0.0, 6.0),
        "lens": 32,
    },
    "feelerstrike_barrage": {
        "label": "FEELERSTRIKE (THE BARRAGE) - r8 under everyone, plus one extra half a second later",
        "state": _nc_pose_feeler,
        "props": _nc_prop_feelerstrike,
        "cam": (36.0, -102.0, 48.0),
        "at": (12.0, -18.0, 3.0),
        "lens": 34,
    },
    "dousehunt": {
        "label": "DOUSEHUNT - every lantern out, and the strike lands IN the dark",
        "state": _nc_pose_douse,
        "props": _nc_prop_dousehunt,
        "cam": (26.0, -96.0, 26.0),
        "at": (0.0, 0.0, 4.0),
        "lens": 30,
    },
    "brokenlure": {
        "label": "A FALSE LURE BROKEN - one stalk down, its socket a stump, the arena darker",
        "state": _nc_pose_broken,
        # Aimed at the WRECK, not at the ring. Stalk 5's socket is on the 269
        # degree bearing and a fall throws the curve 28 studs further out along
        # it, so the dead stalk lies at about r 62 on -Y - which is nowhere
        # near where a camera framed on the arena's centre was pointing.
        "cam": (30.0, -92.0, 28.0),
        "at": (-2.0, -44.0, 5.0),
        "lens": 36,
        # Half a stop: the whole point of this frame is a stalk that is no
        # longer emitting, so there is one less light in the arena and the
        # thing to look at is the darkest object in it.
        "exposure": 0.5,
    },
    "mawrise": {
        "label": "THE MAW RISING - half up through the pit, and the jaw still shut",
        "state": _nc_pose_mawrise,
        "cam": _nc_cam_rise_approach,
        "at": (0.0, 0.0, 6.0),
        "lens": 32,
        # Half a stop up, and only here. Mid-rise the jaw is SHUT, so the one
        # light she carries into the arena is sealed inside her own head and
        # the frame is a black mass against black stone - which is the truth
        # of the moment but not yet a readable silhouette.
        "exposure": 0.9,
    },
    "mawopen": {
        "label": "THE PUNISH WINDOW - brow at ~44, mouth floor a step up from the shelf",
        "state": _nc_pose_maw,
        "props": _nc_prop_mawopen,
        "cam": _nc_cam_mouth_approach,
        "at": (0.0, 0.0, 24.0),
        "lens": 34,
        # The gullet is an 11kW point light 20 studs from the lens and it will
        # clip; that is allowed and correct. Pulling the exposure down keeps
        # the SKULL readable around it instead of a white hole with a jaw.
        "exposure": -1.1,
    },
    "mawopen_inside": {
        "label": "FROM ON THE TONGUE - the gullet is the weak point and it is reachable",
        "state": _nc_pose_maw,
        "props": _nc_prop_mawopen,
        "cam": _nc_cam_inside,
        "at": _nc_cam_gullet_high,
        "lens": 20,
        # THE ONE FRAME THAT MAY NOT BE NEAR-BLACK, and it is not a cheat: the
        # inside of a lit mouth is the one place in this arena the player is
        # standing IN the light source. The gullet's own lantern blows out at
        # four studs, so the exposure comes down and a little fill goes in -
        # nothing is being lit that the fight does not light.
        "exposure": -2.2,
        "sun": 0.6,
        "fill": 0.25,
    },
    "mawbite": {
        "label": "THE BITE - the damage volume is the insideMouth BOX, not a circle",
        "state": _nc_pose_bite,
        "props": _nc_prop_mawbite,
        "cam": (64.0, -66.0, 32.0),
        "at": (0.0, -4.0, 15.0),
        "lens": 30,
    },
    "stalkslam": {
        "label": "STALKSLAM - the limb lands flat on its own stripe, its lantern down to an ember",
        "state": _nc_pose_stalkslam,
        "props": _nc_prop_stalkslam,
        "cam": _nc_cam_slam,
        "at": _nc_cam_slam_at,
        "lens": 32,
        # A third of a stop. The whole tell of this move is a light going OUT,
        # so the limb doing the hitting is the darkest thing in the frame and
        # is lying across the one part of the shelf its own lantern is no
        # longer lighting. Enough to keep the silhouette, not enough to undo
        # the snuff.
        "exposure": 0.35,
    },
    "gloomscythe": {
        "label": "GLOOMSCYTHE - the eye drags the stone, and the band ahead of it is the hitbox",
        "state": _nc_pose_gloomscythe,
        "props": _nc_prop_gloomscythe,
        "cam": _nc_cam_scythe,
        "at": _nc_cam_scythe_at,
        "lens": 32,
    },
    "feelerstrike": {
        "label": "FEELERSTRIKE - the S uncoils and the eye spears a point at chest height",
        "state": _nc_pose_feelerstrike_jab,
        "props": _nc_prop_feelerstrike_jab,
        "cam": _nc_cam_jab,
        "at": _nc_cam_jab_at,
        "lens": 30,
    },
    "portcullis": {
        "label": "THE PORTCULLIS - two violet bars across the doorway, and the 8 gold studs you leave by",
        "state": _nc_pose_portcullis,
        "props": _nc_prop_portcullis,
        "cam": _nc_cam_door,
        "at": _nc_cam_door_at,
        "lens": 34,
        # The punish window's own exposure problem, one stop milder than
        # `mawopen`: the gullet is still an 11kW lamp, but the lens is sixty
        # studs further off it and the thing that has to stay readable is a
        # gold lane on black stone rather than the skull around the light.
        "exposure": -0.9,
    },
    "herdingsnap": {
        "label": "HERDING SNAP - the V shuts on the rim and the mouth comes up out of the floor",
        "state": _nc_pose_herdingsnap,
        "props": _nc_prop_herdingsnap,
        "cam": _nc_cam_snap,
        "at": _nc_cam_snap_at,
        "lens": 30,
        # Half a stop. She is only 40% up, so the gullet's lamp is dim and most
        # of the frame is the shelf and two unlit limbs - the same problem
        # `mawrise` has, for the same reason, and answered the same way. A
        # quarter and not a half: seven lanterns are still lit in this frame,
        # and at 0.6 the stone came up grey enough to read as a lit room.
        "exposure": 0.25,
    },
}


def render_nc_pose(path_out, objects, entry):
    """One fight moment, on the real arena, lit by whatever is still lit.

    The scene is rebuilt from nothing here, which is what makes the telegraph
    props safe: `main` exports the glb before any of this runs, and nothing
    below is reachable from `_place_noctyss` or `_stage_noctyss`, so the pack
    can never ship a lightsweep wedge as a piece of the creature.
    """
    import os

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import arena_gen  # noqa: E402

    label = entry["label"]
    state = entry["state"]()

    clear_scene()
    objects = BOSSES["noctyss"]()
    arena = arena_gen.build_noctyss() or []
    # Before any prop is built: every floor mark below is laid on a probe of
    # THIS geometry, not on a curve that describes it.
    _nc_probe_arena(arena)
    _emissive(objects, {"StalkBulb"}, (1.0, 0.80, 0.42), 3.2)
    _emissive(objects, {"Gullet"}, (1.0, 0.84, 0.46), 2.6)
    for obj in objects:
        obj.hide_render = True
    by_name = {obj.name.split("_", 1)[1]: obj for obj in objects}

    # The dead-lantern object still gets built up front: `_nc_dark_bulb` is the
    # doused case of the same idea and the fallback for a stalk that is gone.
    doused_names = dict(by_name)
    doused_names["StalkBulb"] = _nc_dark_bulb(by_name)

    flash = state.get("flash", 1.0)
    hoods, bulbs = {}, {}
    for index, stalk in enumerate(state["stalks"]):
        glow = _nc_pulse(state, index) if stalk["alive"] else 0.0
        # `flare`: the true lure hauling on the arena. It is not a new number -
        # it is this stalk's own glow pinned at the top of its breath, which is
        # what "the lure flares" means in a fight whose lights are all pulse.
        if state.get("flare") == index:
            glow = 1.0
        source = _nc_lantern_look(by_name, index, glow) if glow > 0.02 else doused_names
        _, hood_matrix = _place_stalk(source, lambda t, i=index: _nc_posed_path(i, t, state))
        hoods[index] = hood_matrix
        bulbs[index] = hood_matrix @ Vector(NC_BULB)
        if glow > 0.02:
            # setLantern: Brightness = 1.1 + 2.2 * glow. Scaled onto the point
            # light's wattage so the arena's floor brightens and dims with the
            # breath, which is the only reason the breath is readable at all.
            energy = 6000.0 * (1.1 + 2.2 * glow) / 3.3 * flash
            _lantern(bulbs[index], energy, (1.0, 0.80, 0.42), radius=2.4)

    maw_base, mouth, gullet = None, None, None
    if state["maw_rise"] > 0.01:
        maw_scale = NC_MAW["scale"]
        # The rise and the gape are what the state says, so a half-open jaw
        # renders as a half-open jaw rather than the pose we happen to like.
        z = _nc_maw_z(state["maw_rise"])
        gape_deg = NC_MAW["gape"] * state["maw_gape"]
        maw_at = _nc_maw_at(z)
        maw_base = _nc_maw_base(maw_at, NC_MAW["pitch"], NC_MAW["yaw"], maw_scale)
        mouth = _nc_mouth_frame(maw_base, gape_deg, maw_scale)
        gullet = maw_base @ Vector(NC_GULLET)
        _place_maw(by_name, maw_at, NC_MAW["pitch"], NC_MAW["yaw"], gape_deg, maw_scale)
        # `setLantern(body.pieces.Gullet, body.gulletLight, state.mawRise)`:
        # the lure-root lights UP WITH THE RISE, so the half-risen frame is
        # meant to be half-lit and the melee target is dim while she is still
        # climbing - which is part of why the window is 15 seconds and not 14.
        _lantern(gullet, 11000.0 * (1.1 + 2.2 * state["maw_rise"]) / 3.3, (1.0, 0.84, 0.46), radius=4.0)
        # ...AND IT IS NOT ALLOWED TO SHADOW ITSELF. The lure-root's light sits
        # inside the gullet mesh (radius 3 x 2.4 = 7.2 studs of it), so EEVEE
        # traces every ray straight into its own bulb and the throat comes out
        # pitch black. Roblox does not do that: a PointLight is not occluded by
        # the part it is parented to, and the mouth a melee player stands in IS
        # lit by the thing they are hitting. Turning the shadow off here is what
        # makes the render agree with the game rather than with the renderer.
        for obj in bpy.context.collection.objects:
            if obj.type == "LIGHT" and (Vector(obj.location) - gullet).length < 0.01:
                obj.data.use_shadow = False

    ctx = {
        "state": state,
        "arena": arena,
        "by_name": by_name,
        "hoods": hoods,
        "bulbs": bulbs,
        "maw_base": maw_base,
        "mouth": mouth,
        "gullet": gullet,
    }
    props = entry.get("props")
    if props:
        props(state, ctx)

    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.rotation_euler = (math.radians(54), 0, math.radians(-36))
    # The dousehunt frame gets almost nothing: the point of that image is how
    # little you can see, and lighting it for legibility would be a lie.
    lit = len(_nc_lit(state))
    # NEAR-BLACK IS THE POINT. The Gloomtrench is lit by seven lanterns and
    # nothing else, and a review render with enough key light to read the stone
    # comfortably is answering a question the player never gets asked. The sun
    # is here to keep silhouettes legible where no lantern reaches, at about a
    # third of what it was, and the lanterns are allowed to clip.
    sun.data.energy = entry.get("sun", 0.5 if lit else 0.22)
    bpy.context.collection.objects.link(sun)
    fill = bpy.data.objects.new("Fill", bpy.data.lights.new("Fill", "SUN"))
    fill.rotation_euler = (math.radians(68), 0, math.radians(132))
    fill.data.energy = entry.get("fill", 0.16 if lit else 0.06)
    bpy.context.collection.objects.link(fill)

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1500
    scene.render.resolution_y = 1000
    # Standard, not Filmic/AgX: the arena is meant to render near-black, and a
    # tone curve that lifted the stone would be answering the question these
    # images are asked ("can you see this in the dark?") on the render's terms
    # instead of the game's. Lights are allowed to clip.
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.exposure = entry.get("exposure", 0.0)
    scene.world = bpy.data.worlds.new("World")
    scene.world.use_nodes = True
    bg = scene.world.node_tree.nodes.get("Background")
    if bg:
        # Near-black, and darker than it was: this value is the SKY behind the
        # arena, and at 0.045 linear it came out a pale slate under Standard -
        # brighter than the stone in front of it. The trench has no sky.
        bg.inputs[0].default_value = (0.014, 0.017, 0.026, 1.0)

    camera = entry["cam"]
    target = entry["at"]
    cam_data = bpy.data.cameras.new("Cam")
    cam_data.lens = entry.get("lens", 32)
    cam = bpy.data.objects.new("Cam", cam_data)
    cam.location = Vector(camera(ctx) if callable(camera) else camera)
    cam.rotation_euler = (
        (Vector(target(ctx) if callable(target) else target) - cam.location).to_track_quat("-Z", "Y").to_euler()
    )
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
        if argv[1] == "gnashroot":
            for name, entry in GN_POSES.items():
                render_gn_pose(argv[0].replace(".glb", "_pose_%s.png" % name), objects, entry)
        elif argv[1] == "noctyss":
            for name, entry in NC_POSES.items():
                render_nc_pose(argv[0].replace(".glb", "_pose_%s.png" % name), objects, entry)
        else:
            for name, (label, state, camera, target) in BJ_POSES.items():
                print("POSE", name, "-", label)
                render_pose(argv[0].replace(".glb", "_pose_%s.png" % name), objects, state, camera, target)


if __name__ == "__main__":
    main()
