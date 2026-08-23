# weapon_gen.py
# Generates the crafted melee weapons as low-poly meshes and exports them
# together as one glTF pack (.glb) - the WeaponPack, the same "one import" idea
# as the RodPack / FishPack / CreaturePack. Run headless:
#
#   blender --background --python assets/weapon_gen.py -- assets/weapon.glb
#   blender --background --python assets/weapon_gen.py -- assets/weapon.glb preview
#
# The second form also writes assets/weapon_preview.png (the weapons lined up)
# for design review without importing.
#
# One pack, many weapons: each variant is exported as <Variant>_Haft / _Grip /
# _Head / _Edge / _Guard / _Spike / _Glow (only the parts it uses), all
# overlapping at the origin. WeaponModel clones one variant's parts out by name
# and renames them to the generic Weapon_* set (assembleVariant), exactly like
# RodModel does for rods. A weapon whose row names no variant (the starter
# club/blade) is still built procedurally by WeaponModel - the mesh path is
# additive.
#
#   _Haft   the shaft / handle (takes the row's `color`)
#   _Grip   the bound hand section, its own object, CENTRE = the hand point
#           (takes `wrap`) - WeaponModel/the viewmodel find it by name
#   _Guard  a crossguard / collar (takes `color`)
#   _Head   a club/maul head (takes `accent`)
#   _Edge   a blade (takes `accent`)
#   _Spike  claws / barbs / teeth (takes `accent`)
#   _Glow   runes / lights that glow (takes `glow`, listed in the row's `neon`)
#
# Authoring contract (WeaponModel / WeaponService / WeaponViewmodelController
# rely on these, keep them true):
#   - 1 Blender unit = 1 Roblox stud. Exported Y-up, so Blender +Z -> Roblox
#     +Y: every weapon stands upright, butt at z = 0, tip at z = LENGTH.
#   - _Grip is its own object and its CENTRE is the hand point (z = GRIP). The
#     viewmodel hangs the swing-trail attachments off Weapon_Grip's local frame
#     (butt->tip is its local +Y), so the grip's frame must be the weapon frame.
#   - Each variant's LENGTH / GRIP here must match its Weapons.luau row
#     (model.length / model.grip).
#   - Flat shading everywhere, matching the island and the other packs.
#
# Colours here are only for the preview; in game WeaponModel recolours per row
# (Weapons.luau model.color / accent / wrap / glow) and marks model.neon parts
# glowing. The preview colours below mirror those rows.

import math
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

TAU = math.tau

# Per-variant frame: butt at z=0, tip at z=LENGTH, hand point at z=GRIP. Must
# match the Weapons.luau row.
FRAME = {
    "DriftwoodClub": {"length": 3.4, "grip": 0.7},
    "Scaleblade": {"length": 3.1, "grip": 0.6},
    "Shellcrusher": {"length": 3.6, "grip": 0.8},
    "Drowncleaver": {"length": 3.7, "grip": 0.7},
    "TidebombMaul": {"length": 3.7, "grip": 0.7},
    "Voltfang": {"length": 3.5, "grip": 0.7},
    "Heartrender": {"length": 3.9, "grip": 0.72},
}

# Preview-only colours, per part object (r,g,b 0..1), mirroring the game rows.
COLORS = {
    "DriftwoodClub_Haft": (0.59, 0.44, 0.28),  # driftwood
    "DriftwoodClub_Head": (0.46, 0.34, 0.21),  # darker knotted head
    "DriftwoodClub_Spike": (0.46, 0.34, 0.21),  # knots
    "DriftwoodClub_Grip": (0.34, 0.55, 0.33),  # kelp wrap
    "Scaleblade_Haft": (0.50, 0.38, 0.24),  # driftwood haft
    "Scaleblade_Grip": (0.38, 0.27, 0.18),  # darker bound handle
    "Scaleblade_Guard": (0.50, 0.38, 0.24),
    "Scaleblade_Edge": (0.72, 0.82, 0.90),  # fish-scale steel
    "Shellcrusher_Haft": (0.55, 0.42, 0.27),  # driftwood haft
    "Shellcrusher_Grip": (0.29, 0.34, 0.31),  # dark bound grip
    "Shellcrusher_Head": (0.49, 0.59, 0.59),  # barnacle chitin
    "Shellcrusher_Spike": (0.49, 0.59, 0.59),
    "Shellcrusher_Guard": (0.55, 0.42, 0.27),
    "Drowncleaver_Haft": (0.59, 0.55, 0.43),  # bone handle
    "Drowncleaver_Grip": (0.22, 0.26, 0.22),  # dark brine wrap
    "Drowncleaver_Edge": (0.82, 0.80, 0.70),  # pale bone blade
    "Drowncleaver_Guard": (0.55, 0.52, 0.42),  # jawbone guard
    "Drowncleaver_Spike": (0.82, 0.80, 0.70),
    "Drowncleaver_Glow": (0.45, 0.95, 0.55),  # brine-green runes
    "TidebombMaul_Haft": (0.47, 0.42, 0.38),  # driftwood haft
    "TidebombMaul_Grip": (0.23, 0.20, 0.25),
    "TidebombMaul_Head": (0.34, 0.29, 0.43),  # urchin shell
    "TidebombMaul_Spike": (0.28, 0.24, 0.36),  # the spines
    "TidebombMaul_Guard": (0.47, 0.42, 0.38),
    "TidebombMaul_Glow": (1.0, 0.58, 0.36),  # the humming tips
    "Voltfang_Haft": (0.25, 0.27, 0.34),
    "Voltfang_Grip": (0.17, 0.19, 0.24),
    "Voltfang_Guard": (0.25, 0.27, 0.34),
    "Voltfang_Edge": (0.84, 0.89, 0.93),  # nacre blade
    "Voltfang_Spike": (0.84, 0.89, 0.93),
    "Voltfang_Glow": (0.49, 0.84, 1.0),  # the arc
    "Heartrender_Haft": (0.36, 0.24, 0.26),
    "Heartrender_Grip": (0.23, 0.16, 0.17),
    "Heartrender_Guard": (0.36, 0.24, 0.26),
    "Heartrender_Edge": (0.77, 0.31, 0.32),  # red blade
    "Heartrender_Spike": (0.77, 0.31, 0.32),
    "Heartrender_Glow": (1.0, 0.38, 0.41),  # the beat
}

GLOW_PARTS = {  # emissive in the preview only
    "Drowncleaver_Glow",
    "TidebombMaul_Glow",
    "Voltfang_Glow",
    "Heartrender_Glow",
}


# ---------------------------------------------------------------- scene + material helpers


def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    for block in (bpy.data.meshes, bpy.data.materials, bpy.data.objects):
        for item in list(block):
            block.remove(item)


def make_material(name):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    r, g, b = COLORS[name]
    bsdf.inputs["Base Color"].default_value = (r, g, b, 1)
    bsdf.inputs["Roughness"].default_value = 1.0
    if name in GLOW_PARTS:
        bsdf.inputs["Emission Color"].default_value = (r, g, b, 1)
        bsdf.inputs["Emission Strength"].default_value = 1.4  # enough to read as glow without clipping to white
    mat.diffuse_color = (r, g, b, 1)
    return mat


def finish(name, bm):
    """Turn a bmesh into a flat-shaded object, or None if it's empty."""
    if len(bm.faces) == 0:
        bm.free()
        return None
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    obj.data.materials.append(make_material(name))
    for poly in mesh.polygons:
        poly.use_smooth = False
    bpy.context.collection.objects.link(obj)
    return obj


# ---------------------------------------------------------------- geometry primitives


def box(bm, center, size, rot=None):
    res = bmesh.ops.create_cube(bm, size=1.0)
    scale = Matrix.Diagonal(Vector((size[0], size[1], size[2], 1.0)))
    m = Matrix.Translation(Vector(center)) @ (rot or Matrix.Identity(4)) @ scale
    bmesh.ops.transform(bm, matrix=m, verts=res["verts"])


def ellipsoid(bm, center, radii, subdiv=1):
    res = bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=1.0)
    scale = Matrix.Diagonal(Vector((radii[0], radii[1], radii[2], 1.0)))
    bmesh.ops.transform(bm, matrix=Matrix.Translation(Vector(center)) @ scale, verts=res["verts"])


def limb(bm, p0, p1, r0, r1, sides=6):
    """A tapered, capped tube from p0 to p1 (radius r0 -> r1)."""
    p0, p1 = Vector(p0), Vector(p1)
    axis = p1 - p0
    length = axis.length
    if length < 1e-6:
        return
    d = axis / length
    up = Vector((0, 0, 1)) if abs(d.z) < 0.9 else Vector((1, 0, 0))
    u = d.cross(up).normalized()
    v = d.cross(u).normalized()

    def rng(p, r):
        return [bm.verts.new(p + (u * math.cos(a) + v * math.sin(a)) * r) for a in ((i / sides) * TAU for i in range(sides))]

    a = rng(p0, r0)
    b = rng(p1, r1)
    for i in range(sides):
        bm.faces.new((a[i], a[(i + 1) % sides], b[(i + 1) % sides], b[i]))
    bm.faces.new(list(reversed(a)))
    bm.faces.new(b)


def cone(bm, base, tip, r, sides=5):
    base, tip = Vector(base), Vector(tip)
    d = (tip - base).normalized()
    up = Vector((0, 0, 1)) if abs(d.z) < 0.9 else Vector((1, 0, 0))
    u = d.cross(up).normalized()
    v = d.cross(u).normalized()
    rim = [bm.verts.new(base + (u * math.cos(a) + v * math.sin(a)) * r) for a in ((i / sides) * TAU for i in range(sides))]
    apex = bm.verts.new(tip)
    for i in range(sides):
        bm.faces.new((rim[i], rim[(i + 1) % sides], apex))
    bm.faces.new(list(reversed(rim)))


def slab(bm, profile, y):
    """Extrude a flat (x, z) silhouette into a thin slab spanning -y..+y (a
    blade). The two broad faces are the caps; profile order is CCW in x-z."""
    front = [bm.verts.new(Vector((x, -y, z))) for x, z in profile]
    back = [bm.verts.new(Vector((x, y, z))) for x, z in profile]
    n = len(profile)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((front[i], front[j], back[j], back[i]))
    bm.faces.new(list(reversed(front)))
    bm.faces.new(back)


def slab_with_hole(bm, profile, hole, hole_r, y, hole_sides=8):
    """slab(), but with a round through-hole at `hole` = (x, z): the side
    walls and the hole's walls are quads, and each broad face is the annulus
    between the outer loop and the hole loop (bridge_loops)."""
    n, m = len(profile), hole_sides
    ring = [(hole[0] + math.cos(a) * hole_r, hole[1] + math.sin(a) * hole_r) for a in ((i / m) * TAU for i in range(m))]

    def loop(yy, pts):
        return [bm.verts.new(Vector((x, yy, z))) for x, z in pts]

    fo, bo = loop(-y, profile), loop(y, profile)
    fi, bi = loop(-y, ring), loop(y, ring)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((fo[i], fo[j], bo[j], bo[i]))
    for i in range(m):
        j = (i + 1) % m
        bm.faces.new((fi[i], fi[j], bi[j], bi[i]))

    def edge(a, b):
        return bm.edges.get((a, b)) or bm.edges.new((a, b))

    for outer, inner in ((fo, fi), (bo, bi)):
        edges = [edge(outer[i], outer[(i + 1) % n]) for i in range(n)]
        edges += [edge(inner[i], inner[(i + 1) % m]) for i in range(m)]
        bmesh.ops.bridge_loops(bm, edges=edges)


def hex_plate(bm, center, r, thickness):
    """A flat six-sided plate lying in the x-z plane (axis along y) - one
    scale on a scale-mail blade."""
    c = Vector(center)
    half = Vector((0, thickness / 2, 0))
    limb(bm, c - half, c + half, r, r, 6)


def stroke(bm, center, length, angle_deg, thickness=0.04, width=0.09):
    """A thin bar lying on a blade face, tilted `angle_deg` in the x-z plane
    - one stroke of a glowing rune glyph."""
    box(bm, center, (length, thickness, width), Matrix.Rotation(math.radians(angle_deg), 4, "Y"))


# ---------------------------------------------------------------- Driftwood Club (starter)
# A knotted length of driftwood: a tapered shaft, a fat knotted head, knots
# poking out sideways, a kelp-wrapped grip. The mesh of the procedural `club`.


def build_driftwoodclub():
    f = FRAME["DriftwoodClub"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    head = bmesh.new()
    spike = bmesh.new()

    # Shaft up to the head, slightly crooked.
    limb(haft, (0, 0, 0.0), (0.04, 0, length - 1.15), 0.17, 0.13, 6)
    # Kelp grip.
    limb(grip_bm, (0, 0, grip - 0.6), (0, 0, grip + 0.6), 0.24, 0.22, 7)
    # Fat knotted head.
    ellipsoid(head, (0.05, 0, length - 0.5), (0.44, 0.44, 0.66), subdiv=1)
    box(head, (0.03, 0, length - 0.95), (0.6, 0.6, 0.5))
    # Knots poking out of the head, offset so the silhouette reads as driftwood.
    for cx, cy, cz, r in ((0.42, 0.1, length - 0.55, 0.2), (-0.34, -0.14, length - 0.35, 0.17), (0.1, -0.4, length - 0.75, 0.18)):
        ellipsoid(spike, (cx, cy, cz), (r, r, r), subdiv=0)

    return [
        finish("DriftwoodClub_Haft", haft),
        finish("DriftwoodClub_Grip", grip_bm),
        finish("DriftwoodClub_Head", head),
        finish("DriftwoodClub_Spike", spike),
    ]


# ---------------------------------------------------------------- Scaleblade (starter)
# A scale-mail dagger (reference: a broad leaf-shaped blade tiled with
# overlapping fish-scale plates, a plain wooden crossguard with swept ends, a
# tapered wooden handle with a flat pommel). The blade is a leaf slab with a
# brick pattern of hex scale plates proud of BOTH faces so it reads as scales
# from any side. The mesh of the procedural `blade`.

# Half-width of the leaf blade at height z (linear between these), used to
# keep the scale plates inside the silhouette.
SCALEBLADE_HALF_WIDTH = [(1.42, 0.13), (1.85, 0.33), (2.2, 0.37), (2.65, 0.26), (2.95, 0.1), (3.1, 0.0)]


def scaleblade_half_width(z):
    pts = SCALEBLADE_HALF_WIDTH
    for (z0, w0), (z1, w1) in zip(pts, pts[1:]):
        if z0 <= z <= z1:
            t = (z - z0) / (z1 - z0)
            return w0 + (w1 - w0) * t
    return 0.0


def build_scaleblade():
    f = FRAME["Scaleblade"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    guard = bmesh.new()
    edge = bmesh.new()

    # Tapered wooden handle, fattest under the guard, with a flat pommel.
    limb(haft, (0, 0, 0.08), (0, 0, 1.28), 0.1, 0.13, 6)
    box(haft, (0, 0, 0.05), (0.3, 0.2, 0.12))
    # Bound grip, own object, centred on the hand point.
    limb(grip_bm, (0, 0, grip - 0.42), (0, 0, grip + 0.42), 0.15, 0.16, 7)

    # Crossguard: a bar with both ends swept up toward the blade.
    box(guard, (0, 0, 1.33), (0.86, 0.2, 0.15))
    for sign in (-1, 1):
        box(guard, (sign * 0.5, 0, 1.38), (0.3, 0.18, 0.13), Matrix.Rotation(math.radians(-sign * 22), 4, "Y"))

    # The leaf blade, thin in Y, widest a third of the way up.
    profile = [(-0.13, 1.42), (0.13, 1.42)]
    for z, w in SCALEBLADE_HALF_WIDTH[1:]:
        profile.append((w, z))
    for z, w in reversed(SCALEBLADE_HALF_WIDTH[1:-1]):
        profile.append((-w, z))
    slab(edge, profile, 0.05)

    # Scale plates in a brick pattern up both faces, each row offset half a
    # plate, only where they fit inside the silhouette. Overlapping rows read
    # as scale mail.
    plate_r = 0.11
    row_step = 0.19
    col_step = 0.21
    row = 0
    z = 1.58
    while z < 3.0:
        half = scaleblade_half_width(z)
        offset = (row % 2) * (col_step / 2)
        for i in range(-3, 4):
            x = offset + i * col_step
            if abs(x) + plate_r * 0.6 <= half:
                for side in (-1, 1):
                    hex_plate(edge, (x, side * (0.05 + 0.015), z), plate_r, 0.04)
        z += row_step
        row += 1

    return [
        finish("Scaleblade_Haft", haft),
        finish("Scaleblade_Grip", grip_bm),
        finish("Scaleblade_Guard", guard),
        finish("Scaleblade_Edge", edge),
    ]


# ---------------------------------------------------------------- Shellcrusher (barnacle maul)
# A stout driftwood haft under a heavy barnacle-chitin head: a faceted shell
# lump, two hooked claw prongs, a crust of barnacle cones. Slow and heavy.


def build_shellcrusher():
    f = FRAME["Shellcrusher"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    head = bmesh.new()
    spike = bmesh.new()
    guard = bmesh.new()

    # Haft up to the head.
    limb(haft, (0, 0, 0.0), (0, 0, 2.35), 0.17, 0.12, 6)
    # Grip: a fatter bound section, its own object, centred on the hand point.
    limb(grip_bm, (0, 0, grip - 0.62), (0, 0, grip + 0.62), 0.27, 0.25, 8)
    # A collar where haft meets head.
    guard_bm_ring(guard, 2.4)

    # Head: a wide faceted shell lump.
    ellipsoid(head, (0, 0, 2.95), (0.62, 0.54, 0.6), subdiv=1)
    box(head, (0, 0, 2.75), (0.7, 0.62, 0.5))
    # Two hooked claw prongs sweeping up off the head.
    limb(head, (0.0, 0.28, 3.2), (0.05, 0.5, 3.75), 0.17, 0.06, 5)
    limb(head, (0.0, -0.24, 3.22), (0.05, -0.42, 3.7), 0.15, 0.05, 5)
    # A blunt crown cap.
    box(head, (0, 0, 3.42), (0.42, 0.42, 0.34))

    # Barnacle cones crusting the shell.
    for i in range(6):
        a = (i / 6) * TAU
        out = Vector((math.cos(a), math.sin(a) * 0.9, 0.0))
        base = Vector((0, 0, 2.9)) + out * 0.55
        cone(spike, base, base + out * 0.28 + Vector((0, 0, 0.05)), 0.13, sides=5)

    return [
        finish("Shellcrusher_Haft", haft),
        finish("Shellcrusher_Grip", grip_bm),
        finish("Shellcrusher_Guard", guard),
        finish("Shellcrusher_Head", head),
        finish("Shellcrusher_Spike", spike),
    ]


def guard_bm_ring(bm, z):
    limb(bm, (0, 0, z - 0.08), (0, 0, z + 0.08), 0.28, 0.28, 8)


# ---------------------------------------------------------------- Tidebomb Maul (urchin maul)
# A driftwood haft under a whole urchin: a round shell with long spines
# radiating in every direction, the tips still humming. Reads as a spiked ball
# on a stick - deliberately nothing like the Shellcrusher's flat shell lump.


def build_tidebombmaul():
    f = FRAME["TidebombMaul"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    head = bmesh.new()
    spike = bmesh.new()
    glow = bmesh.new()
    guard = bmesh.new()

    limb(haft, (0, 0, 0.0), (0, 0, 2.5), 0.15, 0.11, 6)
    limb(grip_bm, (0, 0, grip - 0.6), (0, 0, grip + 0.6), 0.25, 0.23, 8)
    guard_bm_ring(guard, 2.55)

    # The urchin: a near-sphere at the top of the haft.
    centre = Vector((0, 0, 3.02))
    ellipsoid(head, centre, (0.5, 0.5, 0.48), subdiv=1)

    # Spines out of it, on three latitude rings so it bristles from any angle.
    # The last third of each spine is its own glowing tip.
    for lat_deg, count in ((-32, 6), (6, 7), (44, 5)):
        lat = math.radians(lat_deg)
        for i in range(count):
            lon = (i / count) * TAU + (0.0 if lat_deg == 6 else math.pi / count)
            d = Vector((math.cos(lat) * math.cos(lon), math.cos(lat) * math.sin(lon), math.sin(lat)))
            base = centre + d * 0.44
            tip = centre + d * 0.95
            cone(spike, base, tip, 0.075, sides=4)
            cone(glow, centre + d * 0.82, tip, 0.045, sides=4)

    # A blunt crown spine straight up, so the silhouette has a point.
    cone(spike, centre + Vector((0, 0, 0.42)), centre + Vector((0, 0, 1.05)), 0.1, sides=5)
    cone(glow, centre + Vector((0, 0, 0.9)), centre + Vector((0, 0, 1.05)), 0.055, sides=5)

    return [
        finish("TidebombMaul_Haft", haft),
        finish("TidebombMaul_Grip", grip_bm),
        finish("TidebombMaul_Guard", guard),
        finish("TidebombMaul_Head", head),
        finish("TidebombMaul_Spike", spike),
        finish("TidebombMaul_Glow", glow),
    ]


# ---------------------------------------------------------------- Voltfang (nacre fang)
# A narrow nacre blade that splits into two prongs near the tip, with an arc
# of light bridging the gap - a tuning fork made into a weapon. Slim and fast,
# the opposite silhouette to the Drowncleaver's broad slab.


def build_voltfang():
    f = FRAME["Voltfang"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    guard = bmesh.new()
    edge = bmesh.new()
    spike = bmesh.new()
    glow = bmesh.new()

    limb(haft, (0, 0, 0.0), (0, 0, 1.5), 0.12, 0.1, 6)
    limb(grip_bm, (0, 0, grip - 0.5), (0, 0, grip + 0.5), 0.21, 0.2, 8)
    box(guard, (0, 0, 1.55), (0.66, 0.2, 0.16))

    # The blade proper: a slim tapering slab from the guard up to the fork.
    fork_z = 2.75
    box(edge, (0, 0, (1.62 + fork_z) / 2), (0.34, 0.09, fork_z - 1.62))

    # Two prongs, splitting outward and forward to the tip.
    for side in (-1, 1):
        cone(spike, (side * 0.11, 0, fork_z), (side * 0.2, 0, length), 0.075, sides=4)

    # The arc between the prongs: three rungs climbing the gap.
    for i, z in enumerate((fork_z + 0.14, fork_z + 0.4, fork_z + 0.66)):
        w = 0.30 - i * 0.045
        box(glow, (0, 0, z), (w, 0.05, 0.05))
    # A thin bright spine up the middle of the blade.
    box(glow, (0, 0, (1.7 + fork_z) / 2), (0.07, 0.055, fork_z - 1.7))

    return [
        finish("Voltfang_Haft", haft),
        finish("Voltfang_Grip", grip_bm),
        finish("Voltfang_Guard", guard),
        finish("Voltfang_Edge", edge),
        finish("Voltfang_Spike", spike),
        finish("Voltfang_Glow", glow),
    ]


# ---------------------------------------------------------------- Heartrender (brineheart blade)
# The capstone: a broad leaf-shaped blade with a hollow down its centre and a
# slow-pulsing core of Brinejaw's heart set into it, plus a heavy horned
# crossguard. The biggest silhouette on the rack.


def build_heartrender():
    f = FRAME["Heartrender"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    guard = bmesh.new()
    edge = bmesh.new()
    spike = bmesh.new()
    glow = bmesh.new()

    limb(haft, (0, 0, 0.0), (0, 0, 1.45), 0.14, 0.12, 6)
    limb(grip_bm, (0, 0, grip - 0.55), (0, 0, grip + 0.55), 0.24, 0.22, 8)

    # Horned crossguard: a bar with a swept horn on each end.
    box(guard, (0, 0, 1.52), (0.9, 0.24, 0.2))
    for side in (-1, 1):
        cone(spike, (side * 0.42, 0, 1.55), (side * 0.66, 0, 1.98), 0.1, sides=4)

    # The leaf: three stacked slabs, widest a third of the way up, tapering
    # into a point - a blade rather than a cleaver's rectangle.
    box(edge, (0, 0, 1.9), (0.5, 0.13, 0.6))
    box(edge, (0, 0, 2.55), (0.66, 0.14, 0.75))
    box(edge, (0, 0, 3.2), (0.46, 0.12, 0.62))
    cone(spike, (0, 0, 3.45), (0, 0, length), 0.2, sides=4)

    # The heart: a bright core set in the blade, with a vein running to the tip.
    ellipsoid(glow, (0, 0, 2.5), (0.17, 0.09, 0.24), subdiv=1)
    box(glow, (0, 0, 3.05), (0.08, 0.09, 0.7))
    box(glow, (0, 0, 1.98), (0.08, 0.09, 0.55))

    return [
        finish("Heartrender_Haft", haft),
        finish("Heartrender_Grip", grip_bm),
        finish("Heartrender_Guard", guard),
        finish("Heartrender_Edge", edge),
        finish("Heartrender_Spike", spike),
        finish("Heartrender_Glow", glow),
    ]


# ---------------------------------------------------------------- Drowncleaver (cursed-bone cleaver)
# Reference: a real, vertical butcher's cleaver carved from bone - a tall,
# broad rectangular blade with a hanging hole punched through its top-back
# corner, an angled chipped top, a straight cutting edge with a bite taken
# out of it, brine-green rune glyphs glowing on the face, a jawbone guard with
# fangs pointing down along the heel, and a long bone handle ending in a
# femur-knob pommel. Blade = a slab with a true through-hole (slab_with_hole);
# runes = thin glowing strokes on BOTH faces so the glow reads from any side.

# Each glyph: strokes of (dx, dz, length, angle) about the glyph's centre.
DROWNCLEAVER_GLYPHS = [
    [(0.0, 0.0, 0.42, 62), (0.1, -0.08, 0.22, -18)],
    [(0.0, 0.02, 0.4, -56), (-0.1, 0.1, 0.2, 18), (0.12, -0.12, 0.16, 90)],
    [(0.0, 0.0, 0.38, 70), (0.02, 0.12, 0.26, 0)],
]


def build_drowncleaver():
    f = FRAME["Drowncleaver"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    edge = bmesh.new()
    guard = bmesh.new()
    spike = bmesh.new()
    glow = bmesh.new()

    # Bone handle: a long shaft swelling into a femur-knob pommel at the butt.
    limb(haft, (0, 0, 0.1), (0, 0, 1.56), 0.12, 0.11, 6)
    ellipsoid(haft, (0.1, 0, 0.06), (0.14, 0.13, 0.12), subdiv=1)
    ellipsoid(haft, (-0.1, 0, 0.04), (0.14, 0.13, 0.12), subdiv=1)
    # Grip: bound hand section, own object, centred on the hand point.
    limb(grip_bm, (0, 0, grip - 0.42), (0, 0, grip + 0.42), 0.17, 0.16, 7)

    # Jawbone guard: a knuckled bone bar across the heel, and a row of fangs
    # under it pointing down-and-forward along the cutting edge side (+x).
    box(guard, (0.12, 0, 1.64), (1.1, 0.3, 0.2))
    ellipsoid(guard, (-0.44, 0, 1.64), (0.13, 0.17, 0.14), subdiv=1)
    ellipsoid(guard, (0.68, 0, 1.64), (0.13, 0.17, 0.14), subdiv=1)
    for i, (x, fang_len) in enumerate(((0.2, 0.3), (0.38, 0.34), (0.56, 0.3), (0.72, 0.24))):
        base = (x, 0.0, 1.56)
        tip = (x + 0.1, 0.0, 1.56 - fang_len)
        cone(spike, base, tip, 0.07, sides=4)

    # The cleaver blade: tall and broad, spine at -x, cutting edge at +x. The
    # edge runs straight with a bite chipped out of it, the top slants up
    # toward the back corner, and a hanging hole is punched near that corner.
    profile = [
        (-0.34, 1.72),  # heel, back
        (0.66, 1.72),  # heel, edge side
        (0.8, 2.35),  # edge
        (0.72, 2.55),  # the bite
        (0.86, 2.72),
        (0.9, 3.28),  # edge, upper
        (0.62, 3.5),  # chipped front-top corner
        (-0.16, length),  # top-back corner (the tip of the frame)
        (-0.38, 3.25),  # spine, upper
        (-0.36, 2.4),  # spine, mid
    ]
    slab_with_hole(edge, profile, (-0.12, 3.38), 0.09, 0.07)

    # Runes: three glyphs stacked up the centre of the blade, glowing, proud
    # of both faces. They stop short of the hole in the top-back corner.
    for k, glyph in enumerate(DROWNCLEAVER_GLYPHS):
        cz = 2.05 + k * 0.38
        cx = 0.26
        for dx, dz, stroke_len, angle in glyph:
            for side in (-1, 1):
                stroke(glow, (cx + dx, side * 0.1, cz + dz), stroke_len, angle)

    return [
        finish("Drowncleaver_Haft", haft),
        finish("Drowncleaver_Grip", grip_bm),
        finish("Drowncleaver_Guard", guard),
        finish("Drowncleaver_Edge", edge),
        finish("Drowncleaver_Spike", spike),
        finish("Drowncleaver_Glow", glow),
    ]


# ---------------------------------------------------------------- preview


def render_preview(groups, out_png):
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE_NEXT" if hasattr(bpy.types, "SceneEEVEE") else "BLENDER_EEVEE"
    scene.render.resolution_x = 1100
    scene.render.resolution_y = 900
    scene.render.filepath = out_png

    world = bpy.data.worlds.new("W")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.38, 0.42, 0.48, 1)
    scene.world = world
    scene.view_settings.view_transform = "Standard"

    # Softer than the rods' preview: the pale bone and scale-steel clip to
    # white under a harder sun.
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.data.energy = 2.6
    sun.rotation_euler = (math.radians(54), math.radians(14), math.radians(38))
    bpy.context.collection.objects.link(sun)

    # Stand the weapons up, spaced along X.
    spacing = 3.2
    for i, objs in enumerate(groups):
        for obj in objs:
            if obj:
                obj.location.x += (i - (len(groups) - 1) / 2) * spacing

    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    bpy.context.collection.objects.link(cam)
    scene.camera = cam
    cam.location = Vector((-2.0, -18.5, 3.2))
    target = Vector((0.0, 0.0, 2.0))
    cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
    cam.data.lens = 50

    bpy.ops.render.render(write_still=True)
    print("[weapon_gen] preview ->", out_png)


# ---------------------------------------------------------------- export


def main():
    argv = sys.argv[sys.argv.index("--") + 1 :]
    out_path = argv[0]
    want_preview = len(argv) > 1 and argv[1] == "preview"

    clear_scene()
    groups = [
        build_driftwoodclub(),
        build_scaleblade(),
        build_shellcrusher(),
        build_drowncleaver(),
        build_tidebombmaul(),
        build_voltfang(),
        build_heartrender(),
    ]

    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(
        filepath=out_path,
        export_format="GLB",
        use_selection=True,
        export_yup=True,
        export_materials="EXPORT",
        export_apply=True,
        export_normals=True,
        export_texcoords=False,
    )

    total = sum(len(o.data.polygons) for objs in groups for o in objs if o)
    print(f"[weapon_gen] exported {out_path}")
    for name in FRAME:
        print(f"[weapon_gen]   {name}: length {FRAME[name]['length']}, grip {FRAME[name]['grip']} (Weapons.luau must match)")
    print(f"[weapon_gen] weapons: {', '.join(FRAME)}; polys: {total}")

    if want_preview:
        import os

        render_preview(groups, os.path.abspath("assets/weapon_preview.png"))


main()
