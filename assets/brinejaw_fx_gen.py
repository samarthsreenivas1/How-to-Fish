# brinejaw_fx_gen.py
# The BRINEJAW ATTACK-FX PACK: the meshes the storm's attacks are DRAWN with,
# as opposed to boss_gen.py's serpent, which is the thing that throws them.
# Run headless:
#
#   blender --background --python assets/brinejaw_fx_gen.py -- assets/brinejaw_fx.glb
#   blender --background --python assets/brinejaw_fx_gen.py -- assets/brinejaw_fx.glb preview
#
# ---------------------------------------------------------------- the idea
#
# User, 2026-09-08: "get rid of these blue walls and instead make it more
# immersive by creating blender models and animations for the attacks
# themselves." Every Brinejaw broadcast attack currently draws itself out of
# axis-aligned `Instance.new("Part")` boxes - a blue slab for the riptide's
# wall, a blue column for each ground eruption, a bone-white box for a spine.
# The mechanics those boxes encode are RIGHT (the ring, the two mouths, the
# lanes, the stationary bursts) and none of them change here. What changes is
# what the player is looking at while reading them.
#
# The named one is the eruption. It was a jet of water; it is now a STONE
# SPIKE tearing up out of the sand, and it is STATIONARY - the server draws
# the burst list once at fire time and never re-aims it
# (CreatureService.armGeysers: "AND THE LIST IS DELIBERATELY STALE"), so the
# spike stands exactly where the damage sphere is and nowhere else.
#
# ------------------------------------------------------------ what is here
#
#   Spike1/2/3    the eruption. Authored TIP-UP with the BASE AT z=0, so the
#                 client erupts it by sliding it up out of the sand: at rise
#                 fraction k the piece sits at (ground - height*(1-k)).
#   Crest1/2      the riptide's wall, arc-tiled around the ring. Concave face
#                 forward (+X = outward, the way the water is travelling),
#                 rolled lip at the top, slight trapezoid so instances meet.
#   Foam          the roller on the lip, and the marker down a gap lane.
#   Spine         the spine-fan projectile, a barbed fin-blade along +X.
#   Rock1/2       falling masonry, surge rubble, and shatter debris.
#   SpoutBase     the cracked collar left at a spike's foot.
#
# ---------------------------------------------------------------- contract
#
#   - 1 Blender unit = 1 Roblox stud. Up is Blender +Z -> Roblox +Y, and
#     Blender +X arrives as Roblox +X (the pack convention; see boss_gen's
#     header). Blender +Y is therefore Roblox's Z axis, which is what the
#     wide pieces (Crest, Foam) run their WIDTH along, because the client
#     sizes them (thickness, height, tangential span) = (X, Y, Z).
#   - One flat material per object. A piece that wants a second colour would
#     be a second object, and none here needs one: the barnacle crust on the
#     spikes is GEOMETRY, not a colour region, because at 40 studs through
#     spray a bump reads and a shade does not.
#   - Colours are authored REAL, not preview-only, and this is the one place
#     this pack differs from boss_gen. `tools/gen_mesh_colors.py` reads the
#     Base Color off each material and writes MeshColors.luau from it, and
#     the client repaints every clone from that table - Studio's glTF import
#     drops colour entirely. So the value typed below is the value that
#     ships.
#   - Nothing is named `Glow`: BossArenaService and the body controllers make
#     any object whose name contains `Glow` Neon on import, and every piece
#     in this pack is a solid the player is meant to read as matter. The
#     crest is authored SEA-GREEN-DARK for the same reason - the complaint
#     that started this was "blue walls", and a bright slab is what a blue
#     wall is. Its translucency is the client's, set per frame.
#   - Deterministic: seeded random only, so re-exports are byte-stable.

import math
import random
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

TAU = math.tau

PREFIX = "BrinejawFx_"

# ---------------------------------------------------------------- palette
#
# The reef greys are the arena's own: `arena_gen.ROCKS` is (0.30, 0.28, 0.26),
# which is the (77, 71, 66) the brine arena's stones ship at. The spikes are
# that family with two neighbours either side of it, so three of them standing
# in a line read as three rocks rather than as one rock stamped three times.
REEF_A = (0.302, 0.278, 0.259)  # 77, 71, 66 - the arena's stone, exactly
REEF_B = (0.345, 0.318, 0.290)  # 88, 81, 74 - drier, a shade up
REEF_C = (0.267, 0.251, 0.239)  # 68, 64, 61 - wet, a shade down
WETSTONE = (0.471, 0.435, 0.376)  # 120, 111, 96 - the spout collar: wet sand
MASONRY = (0.588, 0.573, 0.533)  # 150, 146, 136 - K.BRINE.stone, the tower
BONE = (0.760, 0.745, 0.667)  # 194, 190, 170 - the spine, off the rattle
# THE CREST, AND WHY IT IS DARK. The part is drawn at ~0.2 transparency over a
# bright beach, so the AUTHORED colour is the darkest the wall ever gets and
# the runtime does the rest. A sea-green this deep reads as a mass of water
# with the light behind it; the (64, 196, 180) neon it replaces read as a
# fence made of sky.
SEAGREEN = (0.133, 0.408, 0.376)  # 34, 104, 96
FOAMWHITE = (0.886, 0.949, 0.941)  # 226, 242, 240


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
    """Seal a bmesh into a flat-shaded, outward-facing, single-material object.

    `recalc_face_normals` is the one line this does that boss_gen's `finish`
    does not, and it earns its place: every shape here is lofted from
    procedurally jittered rings rather than from hand-ordered ring literals,
    so the winding is not something a reader can check by eye. Roblox meshes
    are single-sided - a reversed loft imports as a hole in the world - and
    that failure looks like the mesh not being there at all.
    """
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
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


def loft(bm, rings, cap_start=True, cap_end=True):
    """Bridge a list of equal-length cross-sections into a tube."""
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


def floor_at_zero(bm):
    """Shove every vertex up onto z = 0 and no lower.

    THE BASE PLANE IS A CONTRACT, not a tidy-up. The client hides a spike by
    sliding it down by its own Size.Y and calls that "buried"; a lump of
    barnacle hanging 0.11 studs below z = 0 means the piece is still 0.11
    studs proud of the sand at k = 0, which is a rock quietly sticking out of
    the beach before the attack has fired. Roblox's bounding box is what the
    slide arithmetic is in terms of, so the fix belongs on the mesh.
    """
    for vert in bm.verts:
        if vert.co.z < 0.0:
            vert.co.z = 0.0


def lump(bm, center, radii, subdiv=1, jitter=0.0, rng=None):
    """A jittered icosphere - the pack's all-purpose lump of rock."""
    mat = Matrix.Translation(Vector(center)) @ Matrix.Diagonal(Vector(radii)).to_4x4()
    result = bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=1.0, matrix=mat)
    if jitter and rng:
        for vert in result["verts"]:
            offset = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1)))
            vert.co += offset * jitter
    return result


def ngon(z, radius_x, radius_y, sides, rng=None, jitter=0.0, offset=(0.0, 0.0), roll=0.0):
    """One horizontal cross-section, as a list of points at height `z`."""
    pts = []
    for i in range(sides):
        angle = roll + (i / sides) * TAU
        rx, ry = radius_x, radius_y
        if rng and jitter:
            scale = 1.0 + rng.uniform(-jitter, jitter)
            rx, ry = rx * scale, ry * scale
        pts.append((offset[0] + math.cos(angle) * rx, offset[1] + math.sin(angle) * ry, z))
    return pts


def extrude_profile(bm, profile, stations):
    """Sweep a closed 2D (x, z) profile across (y, dx, sx, sz) stations.

    The riptide's wall is made this way: a silhouette drawn once in the plane
    the player sees it in, then run sideways along the arc. `dx` is what makes
    the footprint trapezoidal - see the tile arithmetic in the HANDOFF.

    HEIGHT AND THICKNESS SCALE SEPARATELY, and that is the difference between
    a wave and a fence. One shared scale makes the tall part of the crest also
    the fat part, which reads as a wall in perspective and was the first pass
    of this piece; scaling z alone lets the lip rise and fall along the length
    while the wall stays the same slab of water thick.
    """
    rings = []
    for y, dx, sx, sz in stations:
        rings.append([(x * sx + dx, y, z * sz) for x, z in profile])
    loft(bm, rings)


# ================================================================== spikes
#
# THE ERUPTION, AND WHY IT IS A ROCK. The attack is a ring of ground bursts
# that the server places once and never moves. A water jet says "this is
# happening now and will stop"; a slab of reef torn up through the sand says
# "this happened here", which is the truthful reading of a hazard whose
# position was decided a second before it fired and cannot follow you.
#
# AUTHORED TIP-UP, BASE AT z=0. That is not decoration: it is the whole
# animation contract. The client has the piece at ground level and slides it
# DOWN by its own height to hide it, then back up over the rise - so the base
# plane has to be a plane the mesh actually ends at, or the spike surfaces
# already a foot out of the sand.

SPIKES = [
    # (name, height, base half-width, lean (x, y) at the tip, sides, seed, colour)
    ("Spike1", 8.6, 1.9, (0.9, 0.35), 7, 21, REEF_A),
    ("Spike2", 7.2, 1.75, (-0.6, 1.0), 6, 44, REEF_B),
    ("Spike3", 9.0, 2.0, (0.35, -0.9), 8, 77, REEF_C),
]


def build_spike(name, height, base_r, lean, sides, seed, color):
    rng = random.Random(seed)
    bm = bmesh.new()
    # The profile: fat and flared at the sand line, thinning fast over the
    # first third and then running out to a point. (1 - t) ** 1.5 is what
    # makes it a SPIKE rather than a cone - a cone's width falls off linearly
    # and reads as a traffic marker.
    steps = 9
    rings = []
    for i in range(steps):
        t = i / (steps - 1)
        # THE TAPER IS THE WHOLE SILHOUETTE, and the first pass of this got it
        # wrong in the way that is easy to miss on paper: `0.55 + 0.45 * taper`
        # still has 55% of the base width left at the tip, and what it renders
        # is a tree stump. A spike has to be nearly gone by two thirds of its
        # height. (1 - t)^1.7 with only a 6% floor is what does that; the floor
        # exists only so the shaft below the point is not a zero-area sliver.
        taper = (1.0 - t) ** 1.7
        r = base_r * (0.06 + 0.94 * taper) * (1.0 if i else 1.30)
        z = height * t
        # The lean is quadratic in t, so the base stays vertical where it
        # meets the sand and the tip carries all of the angle.
        offset = (lean[0] * t * t, lean[1] * t * t)
        # The jitter grows with height: broad flat fracture planes down at the
        # sand, a splintered mess up where the rock tore.
        rings.append(
            ngon(z, r, r * 0.86, sides, rng=rng, jitter=0.16 + 0.26 * t, offset=offset, roll=t * 1.6)
        )
    # The tip is a single point, so the last ring collapses onto the lean.
    rings.append([(lean[0], lean[1], height)] * sides)
    loft(bm, rings)

    # BARNACLE CRUST AS GEOMETRY. Lumps clustered in the bottom third, which
    # is the part of the spike that was underwater until a moment ago and the
    # part a player standing next to it actually sees.
    for _ in range(11):
        t = rng.uniform(0.02, 0.40)
        angle = rng.uniform(0, TAU)
        r = base_r * (0.06 + 0.94 * (1.0 - t) ** 1.7)
        size = rng.uniform(0.20, 0.46)
        lump(
            bm,
            (math.cos(angle) * r * 0.9 + lean[0] * t * t, math.sin(angle) * r * 0.78 + lean[1] * t * t, height * t),
            (size, size, size * 0.72),
            subdiv=0,
        )
    # A SECOND, SHORTER SHARD leaning off the first. This is what stops the
    # piece reading as one cone: a slab of reef does not come up as a single
    # tooth, it comes up as a tooth and the splinter it took with it, and the
    # silhouette of two things at different heights is legible at 60 studs
    # where a taper alone is not.
    shard_h = height * rng.uniform(0.38, 0.52)
    shard_a = rng.uniform(0, TAU)
    shard_o = (math.cos(shard_a) * base_r * 1.05, math.sin(shard_a) * base_r * 1.05)
    shard_lean = (shard_o[0] * 0.55, shard_o[1] * 0.55)
    rings = []
    for i in range(5):
        t = i / 4
        r = base_r * 0.52 * (0.08 + 0.92 * (1.0 - t) ** 1.6) * (1.0 if i else 1.35)
        rings.append(
            ngon(
                shard_h * t,
                r,
                r * 0.9,
                5,
                rng=rng,
                jitter=0.24,
                offset=(shard_o[0] + shard_lean[0] * t * t, shard_o[1] + shard_lean[1] * t * t),
                roll=t,
            )
        )
    rings.append([(shard_o[0] + shard_lean[0], shard_o[1] + shard_lean[1], shard_h)] * 5)
    loft(bm, rings)
    floor_at_zero(bm)
    return finish(PREFIX + name, bm, color)


def build_spout_base():
    """The collar at a spike's foot: broken plates of wet sand shoved outward.

    Its whole job is to make the eruption a THING THE GROUND DID. Without it
    the spike slides up out of an undisturbed beach and reads as a prop being
    raised on a lift, which is exactly what it is.
    """
    rng = random.Random(9)
    bm = bmesh.new()
    plates = 9
    for i in range(plates):
        angle = (i / plates) * TAU
        tilt = rng.uniform(0.18, 0.52)
        r = rng.uniform(1.20, 1.85)
        h = rng.uniform(0.35, 1.0)
        cx, cy = math.cos(angle) * r, math.sin(angle) * r
        # Each plate is a flat wedge hinged up away from the hole, so the ring
        # reads as ground that split rather than as a donut sitting on top.
        rot = Matrix.Rotation(angle, 4, "Z") @ Matrix.Rotation(tilt, 4, "Y")
        mat = Matrix.Translation((cx, cy, h * 0.35)) @ rot @ Matrix.Diagonal(Vector((rng.uniform(0.38, 0.62), rng.uniform(0.45, 0.80), h * 0.5))).to_4x4()
        bmesh.ops.create_cube(bm, size=2.0, matrix=mat)
    # The rim of shed grit, low and continuous, tying the plates together.
    inner = ngon(0.0, 0.95, 0.95, 12, rng=rng, jitter=0.10)
    mid = ngon(0.30, 1.70, 1.70, 12, rng=rng, jitter=0.12)
    outer = ngon(0.02, 2.15, 2.15, 12, rng=rng, jitter=0.10)
    loft(bm, [inner, mid, outer])
    floor_at_zero(bm)
    return finish(PREFIX + "SpoutBase", bm, WETSTONE)


# ================================================================== crests
#
# THE RIPTIDE'S WALL. `stepWave` builds a ring of these at radius r, one per
# slot, `Size = (WAVE_THICK, h, span * 1.06)` where span = 2*pi*r / WAVE_SEGS
# and the part is rotated by the slot's bearing. So:
#
#   Blender +X -> Roblox X = THICKNESS, and it points OUTWARD, the way the
#                 water is going. The concave face and the rolled lip are on
#                 this side because that is the face the player is running
#                 away from.
#   Blender +Z -> Roblox Y = HEIGHT. Base at z = 0.
#   Blender +Y -> Roblox Z = the TANGENTIAL SPAN, i.e. the width along the
#                 arc. Authored 12 studs so a scale of 1 lands mid-arena.
#
# See the HANDOFF for the tile arithmetic; the short version is that the
# footprint is a shallow trapezoid, ends pulled inward, so consecutive
# instances around the ring meet at their corners instead of crossing.

CREST_W = 12.0
CREST_H = 8.0
CREST_TAPER = 0.35  # how far the ends are pulled back toward the tower


def crest_profile(lip, belly, back):
    """The wall's silhouette, as a closed loop in (x, z). +X is out to sea."""
    return [
        # THE FACE THE WAVE IS TRAVELLING INTO. Deeply scooped: this is the
        # concave barrel of a breaker, and the amount of it decides whether
        # the piece reads as water or as a slab stood on its end. The first
        # pass scooped 0.55 of a 2.1-thick wall and rendered as a flat panel.
        (1.15, 0.0),
        (1.05 - belly * 0.55, CREST_H * 0.20),
        (0.86 - belly, CREST_H * 0.42),
        (0.72 - belly * 1.35, CREST_H * 0.62),
        (0.80 - belly * 0.95, CREST_H * 0.80),
        (1.05, CREST_H * 0.91),
        # ...and OVER. The lip carries well past the foot of the wall, so from
        # anywhere but dead astern the crest has an overhang and a shadow
        # under it - the single strongest cue that a thing is falling on you.
        (1.05 + lip * 0.75, CREST_H * 0.985),
        (1.05 + lip, CREST_H * 1.045),
        (0.72 + lip * 0.85, CREST_H * 1.085),
        (0.34 + lip * 0.35, CREST_H * 1.055),
        (0.18, CREST_H * 0.975),
        # The back: a smooth heaving shoulder, no detail. Nothing ever sees it
        # up close - by the time it is between you and the camera it has hit.
        (-0.28, CREST_H * 0.78),
        (-0.62 - back, CREST_H * 0.50),
        (-0.88 - back, CREST_H * 0.23),
        (-1.05, 0.0),
    ]


def build_crest(name, lip, belly, back, swell, phase, seed, color):
    rng = random.Random(seed)
    bm = bmesh.new()
    stations = []
    steps = 11
    for i in range(steps):
        u = i / (steps - 1)
        y = -CREST_W / 2 + CREST_W * u
        # TRAPEZOID: the ends are pulled back along -X by a quadratic in the
        # distance from the centre line. On the ring this is the chord's own
        # sagitta plus slack; see the HANDOFF.
        dx = -CREST_TAPER * (2 * u - 1) ** 2
        # THE CREST LINE RISES AND FALLS ALONG ITS OWN LENGTH, over exactly
        # ONE PERIOD - which is the constraint, not a style choice. These are
        # tiled end to end around a ring, so a height profile that does not
        # come back to where it started leaves a step at every seam, 56 of
        # them, and 56 evenly spaced steps is the most fence-like thing a
        # wall can possibly do. sin(2*pi*u + phase) is equal at u = 0 and
        # u = 1 for any phase, so the tiles chain smoothly and the two
        # variants' different phases keep the line from repeating.
        sz = 1.0 + swell * math.sin(TAU * u + phase)
        sx = 1.0 + 0.09 * math.sin(TAU * u + phase + 1.9) + rng.uniform(-0.02, 0.02)
        stations.append((y, dx, sx, sz))
    extrude_profile(bm, crest_profile(lip, belly, back), stations)

    # THE TONGUES. Four pendants hanging off the underside of the curl, the
    # water that is already coming down ahead of the rest. They are what the
    # eye reads as "breaking" from a three-quarter view, which is the view the
    # player has of the ring for the entire crossing; the lip alone reads as a
    # moulding. Lengths vary and none reaches the sand - a tongue that touched
    # the ground would draw a second, false floor line under the wall.
    for i in range(4):
        u = (i + 0.5) / 4
        y = -CREST_W / 2 + CREST_W * u + rng.uniform(-0.5, 0.5)
        sz = 1.0 + swell * math.sin(TAU * u + phase)
        top = CREST_H * 1.02 * sz
        drop = rng.uniform(0.22, 0.46) * CREST_H
        x = 1.05 + lip * rng.uniform(0.55, 0.95)
        rings = [
            [
                (x - 0.34, y - 0.55, top),
                (x + 0.34, y - 0.55, top),
                (x + 0.34, y + 0.55, top),
                (x - 0.34, y + 0.55, top),
            ],
            [
                (x - 0.20, y - 0.34, top - drop * 0.6),
                (x + 0.24, y - 0.34, top - drop * 0.6),
                (x + 0.24, y + 0.34, top - drop * 0.6),
                (x - 0.20, y + 0.34, top - drop * 0.6),
            ],
            [(x + 0.05, y, top - drop)] * 4,
        ]
        loft(bm, rings)

    # Spray-torn notches along the lip - shallow bites out of the curl, which
    # is what stops the top edge reading as a machined rail.
    for i in range(4):
        u = (i + 0.5) / 4
        y = -CREST_W / 2 + CREST_W * u + rng.uniform(-0.8, 0.8)
        sz = 1.0 + swell * math.sin(TAU * u + phase)
        lump(bm, (1.05 + lip * 0.5, y, CREST_H * 1.06 * sz), (0.44, rng.uniform(0.6, 1.1), 0.34), subdiv=0)
    return finish(PREFIX + name, bm, color)


def build_foam():
    """The tumbling roller on the lip, and the marker down a gap lane.

    Same width as a crest so the two tile together; low and lumpy so it reads
    as churn. `stepWave` sizes it (THICK * 1.6, ~1.1, span * 1.02).
    """
    rng = random.Random(5)
    bm = bmesh.new()
    steps = 9
    rings = []
    for i in range(steps):
        u = i / (steps - 1)
        y = -CREST_W / 2 + CREST_W * u
        # The roller is fattest in the middle and pinched at the ends, so
        # abutting instances read as one continuous line of foam.
        pinch = 0.55 + 0.45 * math.sin(u * math.pi)
        ring = []
        for j in range(7):
            angle = (j / 7) * TAU
            rx = 1.75 * pinch * (1.0 + rng.uniform(-0.14, 0.14))
            rz = 0.55 * pinch * (1.0 + rng.uniform(-0.16, 0.16))
            ring.append((math.cos(angle) * rx, y, 0.55 + math.sin(angle) * rz))
        rings.append(ring)
    loft(bm, rings)
    for i in range(7):
        y = -CREST_W / 2 + CREST_W * (i + 0.5) / 7
        size = rng.uniform(0.30, 0.62)
        lump(bm, (rng.uniform(-0.7, 0.9), y, 0.55 + rng.uniform(0.05, 0.45)), (size, size, size * 0.8), subdiv=0)
    return finish(PREFIX + "Foam", bm, FOAMWHITE)


# ================================================================== spine
#
# The spine-fan projectile. `stepVolley` sizes it VOLLEY_BOLT = (5.0, 2.6,
# 0.7) and rotates it to the lane's bearing, so +X is the direction of travel
# and the blade is TALL (there is nothing to jump - REVISION 2 §3) and thin.


def build_spine():
    rng = random.Random(13)
    bm = bmesh.new()
    length = 4.0
    # The blade: a flat fin swept along +X, deepest just behind the point.
    steps = 6
    rings = []
    for i in range(steps):
        u = i / (steps - 1)
        x = length * u
        # Depth profile: a root, a belly at u ~ 0.35, then a long run to the
        # point. The point itself is not collapsed - a blade with a zero-width
        # nose disappears edge-on, and this thing is seen edge-on constantly.
        depth = 1.30 * (0.55 + 0.75 * math.sin(min(u * 1.55, 1.0) * math.pi)) * (1.0 - 0.55 * u)
        thick = 0.35 * (1.0 - 0.62 * u)
        rings.append(
            [
                (x, -thick, -depth * 0.85),
                (x, thick, -depth * 0.85),
                (x, thick * 1.15, 0.0),
                (x, thick, depth),
                (x, -thick, depth),
                (x, -thick * 1.15, 0.0),
            ]
        )
    loft(bm, rings)
    # BARBS, swept BACK. They are the reason this is a spine and not a dart,
    # and they point the way it came from, which is the direction the player
    # has to have already left.
    for u, side in ((0.18, 1), (0.30, -1), (0.46, 1), (0.60, -1)):
        x = length * u
        depth = 1.30 * (0.55 + 0.75 * math.sin(min(u * 1.55, 1.0) * math.pi)) * (1.0 - 0.55 * u)
        tip = (x - 0.75, 0.0, side * (depth + rng.uniform(0.35, 0.62)))
        root = (x + 0.30, 0.0, side * depth * 0.55)
        rings = [
            [
                (root[0], -0.22, root[2] - 0.3 * side),
                (root[0], 0.22, root[2] - 0.3 * side),
                (root[0], 0.22, root[2] + 0.3 * side),
                (root[0], -0.22, root[2] + 0.3 * side),
            ],
            [(tip[0], -0.05, tip[2])] * 4,
        ]
        loft(bm, rings)
    return finish(PREFIX + "Spine", bm, BONE)


# ================================================================== rubble
#
# Falling masonry, the surge's rubble, and the debris a baited slam knocks off
# a reef stone. Two chunks, because a bombardment of fourteen identical cubes
# is the thing this pack exists to stop.


def build_rock(name, seed, radii, color):
    rng = random.Random(seed)
    bm = bmesh.new()
    # An icosphere with the vertices shoved around, then FLATTENED faces: the
    # jitter alone gives a potato, and masonry is broken, so a couple of the
    # lumps are cut with planes to leave flat fracture faces.
    lump(bm, (0, 0, 0), radii, subdiv=1, jitter=0.42, rng=rng)
    for _ in range(3):
        normal = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1)))
        if normal.length < 1e-3:
            continue
        normal.normalize()
        bmesh.ops.bisect_plane(
            bm,
            geom=bm.verts[:] + bm.edges[:] + bm.faces[:],
            plane_co=normal * rng.uniform(0.55, 0.85) * max(radii),
            plane_no=normal,
            clear_outer=True,
        )
    bmesh.ops.holes_fill(bm, edges=bm.edges[:])
    return finish(PREFIX + name, bm, color)


# ---------------------------------------------------------------- assembly


def build_pack():
    objects = []
    for name, height, base_r, lean, sides, seed, color in SPIKES:
        objects.append(build_spike(name, height, base_r, lean, sides, seed, color))
    objects.append(build_crest("Crest1", lip=0.95, belly=0.95, back=0.30, swell=0.105, phase=0.0, seed=3, color=SEAGREEN))
    objects.append(build_crest("Crest2", lip=1.25, belly=0.70, back=0.14, swell=0.135, phase=2.3, seed=8, color=SEAGREEN))
    objects.append(build_foam())
    objects.append(build_spine())
    objects.append(build_rock("Rock1", 31, (1.55, 1.35, 1.25), MASONRY))
    objects.append(build_rock("Rock2", 62, (1.30, 1.75, 1.15), MASONRY))
    objects.append(build_spout_base())
    return objects


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
    print("FX EXPORTED:", path_out, "-", len(objects), "objects")
    print("")
    print("=" * 72)
    print("HANDOFF brinejaw-fx: the attack pack. 1 unit = 1 stud, Blender +Z is")
    print("HANDOFF brinejaw-fx: Roblox +Y, Blender +X is Roblox +X, Blender +Y is")
    print("HANDOFF brinejaw-fx: Roblox Z. Import as ReplicatedStorage/Assets/BrinejawFxPack.")
    print("HANDOFF brinejaw-fx: -------------------------------------------- bboxes")
    for obj in objects:
        lo = [min(v.co[i] for v in obj.data.vertices) for i in range(3)]
        hi = [max(v.co[i] for v in obj.data.vertices) for i in range(3)]
        print(
            "HANDOFF brinejaw-fx:   %-24s x %6.2f..%6.2f  y %6.2f..%6.2f  z %6.2f..%6.2f   (%.2f x %.2f x %.2f)"
            % (obj.name, lo[0], hi[0], lo[1], hi[1], lo[2], hi[2], hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2])
        )
    print("HANDOFF brinejaw-fx: ------------------------------------------ the spikes")
    print("HANDOFF brinejaw-fx: Spike1/2/3 are TIP-UP with the BASE AT z = 0 and the")
    print("HANDOFF brinejaw-fx: tip at +z. There is no geometry below z = 0, which is")
    print("HANDOFF brinejaw-fx: the eruption contract: at rise fraction k in 0..1 the")
    print("HANDOFF brinejaw-fx: client places the part's CENTRE at")
    print("HANDOFF brinejaw-fx:     y = ground + height * (k - 0.5)")
    print("HANDOFF brinejaw-fx: so k = 0 buries it exactly (top flush with the sand)")
    print("HANDOFF brinejaw-fx: and k = 1 stands it fully out. A part sized shorter or")
    print("HANDOFF brinejaw-fx: taller than the authored height still works: `height`")
    print("HANDOFF brinejaw-fx: in that formula is the part's OWN Size.Y, not the")
    print("HANDOFF brinejaw-fx: number below.")
    print("HANDOFF brinejaw-fx: The lean lives in the top half (quadratic in t), so a")
    print("HANDOFF brinejaw-fx: spike meets the sand vertically however it is yawed -")
    print("HANDOFF brinejaw-fx: the client may spin it freely about Y and it will not")
    print("HANDOFF brinejaw-fx: open a gap at the foot. It may NOT be tilted: a tilt")
    print("HANDOFF brinejaw-fx: lifts one side of the base off the beach.")
    print("HANDOFF brinejaw-fx: SpoutBase is a flat collar, base at z = 0, outer radius")
    print("HANDOFF brinejaw-fx: 2.5 (5 wide) and about 1 tall. It sits AT the spike's")
    print("HANDOFF brinejaw-fx: foot on the sand and does not move with the rise.")
    print("HANDOFF brinejaw-fx: ------------------------------------------ the crest")
    print("HANDOFF brinejaw-fx: Crest1/2 are the ring wave's wall. Authored %.1f wide"
          % CREST_W)
    print("HANDOFF brinejaw-fx: (Blender Y = Roblox Z = the TANGENTIAL span), %.1f tall"
          % CREST_H)
    print("HANDOFF brinejaw-fx: (Blender Z = Roblox Y, base at z = 0), about 2.1 thick")
    print("HANDOFF brinejaw-fx: (Blender X = Roblox X). The CONCAVE face and the rolled")
    print("HANDOFF brinejaw-fx: lip are on +X, which is OUTWARD - the direction the ring")
    print("HANDOFF brinejaw-fx: travels and the face the player is running from.")
    print("HANDOFF brinejaw-fx:")
    print("HANDOFF brinejaw-fx: TILE ARITHMETIC. stepWave draws WAVE_SEGS = 56 slots on")
    print("HANDOFF brinejaw-fx: a circle of radius r, slot i centred on")
    print("HANDOFF brinejaw-fx:     theta_i = (i - 0.5) / 56 * 2pi          (6.4286 deg)")
    print("HANDOFF brinejaw-fx: and sizes each part (WAVE_THICK, h, span * 1.06) with")
    print("HANDOFF brinejaw-fx:     span = 2 * pi * r / 56")
    print("HANDOFF brinejaw-fx: so the Z scale applied to this mesh is span * 1.06 / %.1f."
          % CREST_W)
    print("HANDOFF brinejaw-fx: At the launch radius 10 that is 0.099; at the outer 76")
    print("HANDOFF brinejaw-fx: it is 0.753. The wall therefore never draws at authored")
    print("HANDOFF brinejaw-fx: size - it is always squeezed - so the detail on it is")
    print("HANDOFF brinejaw-fx: sized for the OUTER third of the run, where the ring is")
    print("HANDOFF brinejaw-fx: on top of the player and where it is looked at.")
    print("HANDOFF brinejaw-fx:")
    print("HANDOFF brinejaw-fx: THE TRAPEZOID. A flat tile chorded across a 6.4286 deg")
    print("HANDOFF brinejaw-fx: arc leaves its ends standing proud of the true circle by")
    print("HANDOFF brinejaw-fx: the sagitta r * (1 - cos(3.2143 deg)) = 0.001573 * r:")
    print("HANDOFF brinejaw-fx: 0.016 studs at r = 10, 0.120 at r = 76. That alone is")
    print("HANDOFF brinejaw-fx: invisible. What is NOT invisible is the 6% overlap the")
    print("HANDOFF brinejaw-fx: client already applies (span * 1.06) to hide the seams:")
    print("HANDOFF brinejaw-fx: neighbouring tiles interpenetrate by 3% of a span at")
    print("HANDOFF brinejaw-fx: each end, and with a square footprint that crossing is a")
    print("HANDOFF brinejaw-fx: visible X of geometry along the lip. So the footprint is")
    print("HANDOFF brinejaw-fx: pulled back along -X by")
    print("HANDOFF brinejaw-fx:     dx(u) = -%.2f * (2u - 1)^2,   u = 0..1 across the width"
          % CREST_TAPER)
    print("HANDOFF brinejaw-fx: i.e. 0 at the centre line and -%.2f at both ends. Against"
          % CREST_TAPER)
    print("HANDOFF brinejaw-fx: a thickness of ~2.1 that is a 17% inset, comfortably more")
    print("HANDOFF brinejaw-fx: than both the sagitta and the overlap, so the ends tuck")
    print("HANDOFF brinejaw-fx: behind their neighbours instead of crossing them at any")
    print("HANDOFF brinejaw-fx: radius the ring reaches. Alternate Crest1 / Crest2 around")
    print("HANDOFF brinejaw-fx: the ring (i % 2) - they differ in lip curl and belly, so")
    print("HANDOFF brinejaw-fx: alternating reads as water and repeating reads as a wall.")
    print("HANDOFF brinejaw-fx: ------------------------------------------ foam / spine")
    print("HANDOFF brinejaw-fx: Foam is the same %.1f width as a crest, ~3.5 thick and"
          % CREST_W)
    print("HANDOFF brinejaw-fx: ~1.1 tall, pinched at both ends so a run of them reads as")
    print("HANDOFF brinejaw-fx: one line. It is the crest's lip cap AND the gap-lane")
    print("HANDOFF brinejaw-fx: marker; the gap lane sizes it (run * 0.86, 0.14, chord),")
    print("HANDOFF brinejaw-fx: which squashes it to a rolled ribbon on the sand.")
    print("HANDOFF brinejaw-fx: Spine runs along +X from x = 0 to x = 4.0, the barbs swept")
    print("HANDOFF brinejaw-fx: BACK toward -X. Height is Blender Z (Roblox Y) and it is")
    print("HANDOFF brinejaw-fx: the tall axis: VOLLEY_BOLT is (5.0, 2.6, 0.7) and the")
    print("HANDOFF brinejaw-fx: piece is authored to that proportion. It is NOT centred on")
    print("HANDOFF brinejaw-fx: its root - the bbox is symmetric about x = 2.0 - so the")
    print("HANDOFF brinejaw-fx: client's existing centre placement needs no offset.")
    print("HANDOFF brinejaw-fx: ------------------------------------------ the rubble")
    print("HANDOFF brinejaw-fx: Rock1/2 are irregular masonry chunks about 3 studs across,")
    print("HANDOFF brinejaw-fx: centred on their own middles, with flat fracture faces.")
    print("HANDOFF brinejaw-fx: They are tumbled by the client on the way down and laid")
    print("HANDOFF brinejaw-fx: flat (Size 3.4 x 0.5 x 3.0) as debris on landing, so they")
    print("HANDOFF brinejaw-fx: must survive being squashed on one axis - which is why")
    print("HANDOFF brinejaw-fx: they are lumps and not slabs with an up direction.")
    print("HANDOFF brinejaw-fx: ------------------------------------------ colour")
    print("HANDOFF brinejaw-fx: Colours are AUTHORED, not preview-only. Run")
    print("HANDOFF brinejaw-fx:     python3 tools/gen_mesh_colors.py")
    print("HANDOFF brinejaw-fx: after any edit here; the client repaints every clone from")
    print("HANDOFF brinejaw-fx: MeshColors and a piece with no row imports Roblox grey.")
    print("HANDOFF brinejaw-fx: No object is named `Glow` or `Deco`: nothing in this pack")
    print("HANDOFF brinejaw-fx: is emissive, the crest included. It is authored")
    print("HANDOFF brinejaw-fx: sea-green-dark (%d, %d, %d) because the note that started"
          % tuple(round(c * 255) for c in SEAGREEN))
    print("HANDOFF brinejaw-fx: this pack was that the wave read as a blue wall.")
    print("=" * 72)


# ---------------------------------------------------------------- preview
#
# THREE SHEETS, AND THEY ANSWER DIFFERENT QUESTIONS.
#
#   _sheet   every object in a row on sand at authored size, next to a 5-stud
#            red block standing in for a player. Does each silhouette read,
#            and is it the size it claims to be?
#   _wave    the crest ARC-TILED, which is the only way the wall can actually
#            be judged. One crest photographed alone is a fin; nine of them
#            around a 46-stud ring with foam on the lip is the thing the
#            player is looking at, and the question this pack exists to answer
#            ("is it still a blue wall?") is only askable of that image.
#   _erupt   three spikes part-way out of the sand at k = 0.3 / 0.65 / 1.0
#            with their collars, i.e. the animation the client will run, drawn
#            as stills. A spike that reads standing up can still read as a
#            prop on a lift half-way out, and that is the frame the attack
#            spends most of its time on.


def _stage(objects, width=160.0):
    """Wipe the last sheet's staging and lay out a fresh one.

    THE THREE SHEETS RENDER IN ONE BLENDER SESSION, so without this the wave's
    thirteen tiles are still standing in the eruption shot and the contact
    strip's ground slab is still under all of it. Everything that is not a
    pack object goes; the pack objects go back to the origin, unrotated and
    unscaled, because the sheets move them.
    """
    keep = {obj.name for obj in objects}
    for obj in list(bpy.context.collection.objects):
        if obj.name not in keep:
            bpy.data.objects.remove(obj, do_unlink=True)
    for obj in objects:
        obj.location = (0.0, 0.0, 0.0)
        obj.rotation_euler = (0.0, 0.0, 0.0)
        obj.scale = (1.0, 1.0, 1.0)

    ground = bmesh.new()
    bmesh.ops.create_cube(
        ground,
        size=2.0,
        matrix=Matrix.Translation((0, 0, -2.0)) @ Matrix.Diagonal(Vector((width, width, 2))).to_4x4(),
    )
    finish("_Ground", ground, (0.87, 0.76, 0.5))

    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.rotation_euler = (math.radians(56), 0, math.radians(-52))
    sun.data.energy = 3.0
    bpy.context.collection.objects.link(sun)
    fill = bpy.data.objects.new("Fill", bpy.data.lights.new("Fill", "SUN"))
    fill.rotation_euler = (math.radians(74), 0, math.radians(128))
    fill.data.energy = 1.0
    bpy.context.collection.objects.link(fill)

    scene = bpy.context.scene
    for engine in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "CYCLES"):
        try:
            scene.render.engine = engine
            break
        except TypeError:
            continue
    scene.render.resolution_x = 2200
    scene.render.resolution_y = 950
    scene.view_settings.view_transform = "Standard"
    scene.world = bpy.data.worlds.new("World")
    scene.world.use_nodes = True
    bg = scene.world.node_tree.nodes.get("Background")
    if bg:
        bg.inputs[0].default_value = (0.35, 0.48, 0.55, 1.0)
    return scene


def _player(at, tag=""):
    """The 5-stud reference block. Scale is the only thing it is here for."""
    bm = bmesh.new()
    bmesh.ops.create_cube(
        bm, size=2.0, matrix=Matrix.Translation((0, 0, 2.5)) @ Matrix.Diagonal(Vector((1.0, 1.0, 2.5))).to_4x4()
    )
    obj = finish("_Player5" + tag, bm, (0.62, 0.18, 0.16))
    obj.location = at
    return obj


def _shoot(scene, path_out, location, target, lens=50):
    cam_data = bpy.data.cameras.new("Cam")
    cam_data.lens = lens
    cam = bpy.data.objects.new("Cam", cam_data)
    cam.location = Vector(location)
    cam.rotation_euler = (Vector(target) - cam.location).to_track_quat("-Z", "Y").to_euler()
    bpy.context.collection.objects.link(cam)
    scene.camera = cam
    scene.render.filepath = path_out
    bpy.ops.render.render(write_still=True)
    print("FX PREVIEW:", path_out)


def _clone(obj, name):
    copy = obj.copy()
    copy.data = obj.data.copy()
    copy.name = name
    bpy.context.collection.objects.link(copy)
    return copy


def render_sheet(path_out, objects):
    scene = _stage(objects, 200.0)
    # SOME PIECES ARE AUTHORED WIDE ALONG +Y, which is the axis pointing at the
    # camera on a strip laid out along +X - so the crest and the foam would be
    # photographed edge-on, as a 2-stud sliver, and the first pass of this
    # sheet duly showed two teal fins and no wall at all. Turn them so the
    # width faces the lens AND the +X face (the concave one) faces it too;
    # -90 degrees, not +90 - the first attempt turned the wall's back to the
    # camera and the "flat wall" it appeared to show was the smooth shoulder
    # nobody ever sees. The export is untouched; this is framing.
    yaw = {PREFIX + "Crest1": -90.0, PREFIX + "Crest2": -90.0, PREFIX + "Foam": -90.0}
    row = [_player((0, 0, 0))] + list(objects)
    cursor = 0.0
    for obj in row:
        turn = math.radians(yaw.get(obj.name, 0.0))
        obj.rotation_euler = (0.0, 0.0, turn)
        matrix = Matrix.Rotation(turn, 4, "Z")
        xs = [(matrix @ v.co)[0] for v in obj.data.vertices]
        width = max(xs) - min(xs)
        cursor += width / 2 + 3.4
        obj.location = (cursor, 0.0, 0.0)
        cursor += width / 2
    mid, span = cursor / 2, cursor
    _shoot(scene, path_out, (mid, -span * 1.20, span * 0.30), (mid, 0.0, 4.5), lens=32)
    _shoot(scene, path_out.replace(".png", "_flat.png"), (mid, -span * 1.10, 7.0), (mid, 0.0, 4.5), lens=32)


def render_wave(path_out, objects):
    """The crest, tiled the way stepWave tiles it. THE acceptance image."""
    scene = _stage(objects, 260.0)
    by_name = {obj.name: obj for obj in objects}
    for obj in objects:
        obj.location = (0.0, 0.0, -400.0)  # out of shot; the tiles are clones

    radius = 46.0
    segs = 56
    span = TAU * radius / segs
    scale_z = span * 1.06 / CREST_W
    height = 11.0  # K.WAVE_HEIGHT
    thick = 2.2  # K.WAVE_THICK
    shown = 13
    for i in range(shown):
        slot = i - shown // 2
        theta = math.radians(90) + slot * TAU / segs
        crest = _clone(by_name[PREFIX + ("Crest1" if i % 2 == 0 else "Crest2")], "Tile%d" % i)
        # The client's own placement: rotate to the bearing, scale to
        # (thickness, height, span), stand it on the sand.
        swell = 1.0 + 0.22 * math.sin(theta * 3)
        h = height * swell
        crest.rotation_euler = (0.0, 0.0, theta)
        crest.scale = (thick / 2.1, scale_z, h / CREST_H)
        crest.location = (math.cos(theta) * radius, math.sin(theta) * radius, 0.0)

        foam = _clone(by_name[PREFIX + "Foam"], "Foam%d" % i)
        foam.rotation_euler = (0.0, 0.0, theta)
        foam.scale = (thick * 1.6 / 3.4, span * 1.02 / CREST_W, 1.0)
        lean = math.sin(math.radians(15))
        out = radius + h * lean
        foam.location = (math.cos(theta) * out, math.sin(theta) * out, h * 0.94)

    _player((0.0, radius - 22.0, 0.0))
    _shoot(scene, path_out, (0.0, radius - 62.0, 12.0), (0.0, radius + 2.0, 6.0), lens=42)
    _shoot(scene, path_out.replace(".png", "_high.png"), (0.0, radius - 74.0, 46.0), (0.0, radius, 4.0), lens=44)


def render_erupt(path_out, objects):
    """The eruption, as the client will animate it: k = 0.3, 0.65, 1.0."""
    scene = _stage(objects, 120.0)
    by_name = {obj.name: obj for obj in objects}
    for obj in objects:
        obj.location = (0.0, 0.0, -400.0)

    for i, (name, k) in enumerate((("Spike1", 0.30), ("Spike2", 0.65), ("Spike3", 1.00))):
        x = -8.0 + i * 15.0
        source = by_name[PREFIX + name]
        height = max(v.co.z for v in source.data.vertices)
        spike = _clone(source, "Erupt%d" % i)
        spike.rotation_euler = (0.0, 0.0, i * 1.9)
        # The contract, drawn: the base sits `height * (1 - k)` below the sand.
        spike.location = (x, 0.0, -height * (1.0 - k))
        collar = _clone(by_name[PREFIX + "SpoutBase"], "Collar%d" % i)
        collar.rotation_euler = (0.0, 0.0, i * 1.1)
        collar.scale = (1.0, 1.0, 0.6 + 0.4 * k)
        collar.location = (x, 0.0, 0.0)

    _player((-16.0, -3.0, 0.0))
    _shoot(scene, path_out, (7.0, -48.0, 11.0), (7.0, 0.0, 4.0), lens=34)


def render_preview(path_out, objects):
    render_sheet(path_out.replace(".png", "_sheet.png"), objects)
    render_wave(path_out.replace(".png", "_wave.png"), objects)
    render_erupt(path_out.replace(".png", "_erupt.png"), objects)


def main():
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    if not argv:
        print("usage: blender --background --python brinejaw_fx_gen.py -- <out.glb> [preview]")
        return
    clear_scene()
    objects = build_pack()
    export(argv[0], objects)
    if "preview" in argv[1:]:
        render_preview(argv[0].replace(".glb", "_preview.png"), objects)


if __name__ == "__main__":
    main()
