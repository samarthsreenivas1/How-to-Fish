# creatures_gen.py
# Generates the hostile non-fish creatures as low-poly meshes and exports them
# together as one glTF pack (.glb) - the CreaturePack, same "one import" idea
# as the FishPack and RodPack. Run headless:
#
#   blender --background --python assets/creatures_gen.py -- assets/creatures.glb
#   blender --background --python assets/creatures_gen.py -- assets/creatures.glb preview
#
# The second form also writes assets/creatures_preview.png (the creatures lined
# up) for design review without importing.
#
# One pack, many creatures: each is exported as <Name>_Body / _Fins / _Eyes /
# _Marks (the same four-part contract as a FishPack species), so
# CreatureModel.assembleSpecies picks one creature's parts out and renames them
# to the generic Fish_* set. Colours here are preview-only; in game
# CreatureModel recolours per Creatures.luau row (color / finColor / markColor).
#
# Authoring contract (CreatureService relies on these):
#   - 1 Blender unit = 1 Roblox stud. Up is Blender +Z -> Roblox +Y.
#   - Everything is BUILT facing Blender +X (natural to author and preview: the
#     crab's claws and the zombies' reaching arms/face all point +X). BUT the
#     GLB import lands Blender +X at Roblox -X, while CreatureService points the
#     model's local +X at the player (flatOrientation / uprightOrientation +
#     yawToward). Left as-is the creatures charge and shamble at you BACKWARDS.
#     So export() applies a final 180 deg yaw (about up) to every creature: the
#     built +X front arrives in Roblox as +X, the facing/charge direction.
#   - FLAT creatures (crab, skipper, cod, urchin, lurker, hermit, ray) are
#     authored low, with their front-to-back extent the SINGLE longest axis and
#     their height the shortest, so flatOrientation reads +X as forward and
#     lays them belly-down. (Width in between. Check every builder's bbox note.)
#   - UPRIGHT creatures (the zombies, the jelly, the mimic) are authored Z-up
#     (feet / lowest point at z=0 is fine but not required) and their rows set
#     body.stance = "upright", so CreatureService stands them as-built and
#     turns local +X (Roblox) toward the player.
#   - The Mimic's lid MUST be its _Fins object: CreatureService hinges that one
#     part about a point MIMIC_HINGE_BACK (0.9) behind the shell's centre on
#     the facing axis, raising the +X (front) edge. Keep the lower shell
#     centred on x=0 so "behind the centre" is inside the shell.
#   - The Voltray's _Marks are its electric organs: the client makes them Neon
#     while it charges. The Jelly's _Marks are its glowing core / oral arms.
#     The Leviathan's (island boss) _Marks are its lure bulb, gill slits and
#     throat: lit when it enrages.
#   - Flat shading everywhere.

import math
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

TAU = math.tau

# ---------------------------------------------------------------- palette (preview only)
# Mirrors each Creatures.luau row's color / finColor / markColor so the
# preview is a fair picture of the game.

COLORS = {
    "Crab_Body": (0.74, 0.26, 0.20),
    "Crab_Fins": (0.56, 0.17, 0.13),
    "Crab_Eyes": (0.04, 0.04, 0.05),
    "Crab_Marks": (0.90, 0.84, 0.70),
    "Deckhand_Body": (0.44, 0.52, 0.44),
    "Deckhand_Fins": (0.30, 0.36, 0.43),
    "Deckhand_Eyes": (0.62, 0.92, 0.86),
    "Deckhand_Marks": (0.24, 0.44, 0.30),
    "Angler_Body": (0.42, 0.54, 0.50),
    "Angler_Fins": (0.40, 0.32, 0.20),
    "Angler_Eyes": (0.85, 0.90, 0.86),
    "Angler_Marks": (0.40, 0.95, 0.86),
    # Enemies slice
    "Skipper_Body": (0.50, 0.55, 0.36),
    "Skipper_Fins": (0.36, 0.38, 0.27),
    "Skipper_Eyes": (0.05, 0.05, 0.06),
    "Skipper_Marks": (0.84, 0.81, 0.59),
    "GulletCod_Body": (0.59, 0.53, 0.36),
    "GulletCod_Fins": (0.46, 0.42, 0.31),
    "GulletCod_Eyes": (0.05, 0.05, 0.06),
    "GulletCod_Marks": (0.27, 0.16, 0.17),
    "Urchin_Body": (0.28, 0.16, 0.27),
    "Urchin_Fins": (0.47, 0.28, 0.46),
    "Urchin_Eyes": (0.05, 0.05, 0.06),
    "Urchin_Marks": (0.85, 0.55, 0.25),
    "Jelly_Body": (0.78, 0.84, 0.93),
    "Jelly_Fins": (0.63, 0.70, 0.86),
    "Jelly_Eyes": (0.05, 0.05, 0.06),
    "Jelly_Marks": (0.93, 0.78, 0.91),
    "Lurker_Body": (0.77, 0.69, 0.51),
    "Lurker_Fins": (0.65, 0.57, 0.41),
    "Lurker_Eyes": (0.05, 0.05, 0.06),
    "Lurker_Marks": (0.47, 0.39, 0.27),
    "Mimic_Body": (0.47, 0.44, 0.41),
    "Mimic_Fins": (0.55, 0.51, 0.46),
    "Mimic_Eyes": (0.05, 0.05, 0.06),
    "Mimic_Marks": (0.96, 0.94, 0.97),
    "Hermit_Body": (0.59, 0.38, 0.25),
    "Hermit_Fins": (0.84, 0.47, 0.31),
    "Hermit_Eyes": (0.05, 0.05, 0.06),
    "Hermit_Marks": (1.0, 0.80, 0.36),
    "Voltray_Body": (0.24, 0.26, 0.36),
    "Voltray_Fins": (0.33, 0.36, 0.49),
    "Voltray_Eyes": (0.05, 0.05, 0.06),
    "Voltray_Marks": (0.47, 0.86, 1.0),
    # Volcano roster (2026-08-23) - the crater's own hostiles.
    "Fumarole_Body": (0.29, 0.26, 0.24),
    "Fumarole_Fins": (0.20, 0.18, 0.17),
    "Fumarole_Eyes": (1.0, 0.62, 0.20),
    "Fumarole_Marks": (1.0, 0.50, 0.16),
    "EmberSwarm_Body": (0.97, 0.45, 0.12),
    "EmberSwarm_Fins": (0.72, 0.24, 0.10),
    "EmberSwarm_Eyes": (1.0, 0.86, 0.42),
    "EmberSwarm_Marks": (1.0, 0.60, 0.14),
    "MagmaOoze_Body": (0.26, 0.13, 0.10),
    "MagmaOoze_Fins": (0.13, 0.11, 0.12),
    "MagmaOoze_Eyes": (0.05, 0.04, 0.04),
    "MagmaOoze_Marks": (1.0, 0.38, 0.06),
    "Shardback_Body": (0.17, 0.16, 0.20),
    "Shardback_Fins": (0.23, 0.21, 0.26),
    "Shardback_Eyes": (1.0, 0.55, 0.24),
    "Shardback_Marks": (0.89, 0.38, 0.17),
    "CinderDjinn_Body": (0.25, 0.22, 0.24),
    "CinderDjinn_Fins": (0.17, 0.15, 0.16),
    "CinderDjinn_Eyes": (1.0, 0.60, 0.22),
    "CinderDjinn_Marks": (1.0, 0.47, 0.19),
    # The one COOL-glowing thing in the crater: magnetite, not lava. It reads
    # as a deliberate contrast against seven molten neighbours - but only if
    # the body is genuinely dark, which at (0.28, 0.31, 0.38) it was not.
    "LodestoneEel_Body": (0.13, 0.14, 0.19),
    "LodestoneEel_Fins": (0.20, 0.22, 0.29),
    "LodestoneEel_Eyes": (0.72, 0.88, 1.0),
    "LodestoneEel_Marks": (0.45, 0.68, 1.0),
    "SlagGolem_Body": (0.23, 0.20, 0.21),
    "SlagGolem_Fins": (0.31, 0.17, 0.13),
    "SlagGolem_Eyes": (1.0, 0.58, 0.18),
    "SlagGolem_Marks": (1.0, 0.45, 0.16),
    "Phoenix_Body": (0.72, 0.22, 0.09),
    "Phoenix_Fins": (0.95, 0.42, 0.10),
    "Phoenix_Eyes": (1.0, 0.92, 0.70),
    "Phoenix_Marks": (1.0, 0.62, 0.12),
    # Island boss
    "Leviathan_Body": (0.18, 0.24, 0.29),
    "Leviathan_Fins": (0.38, 0.46, 0.50),
    "Leviathan_Eyes": (0.47, 1.0, 0.84),
    "Leviathan_Marks": (0.47, 1.0, 0.84),
    # Revamp bosses (islands 2-7). Marks are each boss's enrage/tell parts,
    # same rule as the Leviathan.
    "Gnashroot_Body": (0.25, 0.30, 0.20),
    "Gnashroot_Fins": (0.33, 0.26, 0.18),
    "Gnashroot_Eyes": (1.0, 0.72, 0.30),
    "Gnashroot_Marks": (0.55, 0.90, 0.60),
    "Rimefang_Body": (0.62, 0.74, 0.84),
    "Rimefang_Fins": (0.42, 0.55, 0.70),
    "Rimefang_Eyes": (0.70, 0.95, 1.0),
    "Rimefang_Marks": (0.50, 0.95, 1.0),
    "Pyrelisk_Body": (0.23, 0.17, 0.15),
    "Pyrelisk_Fins": (0.19, 0.17, 0.24),
    "Pyrelisk_Eyes": (1.0, 0.60, 0.20),
    "Pyrelisk_Marks": (1.0, 0.40, 0.08),
    "Noctyss_Body": (0.14, 0.12, 0.18),
    "Noctyss_Fins": (0.22, 0.18, 0.28),
    "Noctyss_Eyes": (0.85, 0.88, 0.95),
    "Noctyss_Marks": (1.0, 0.90, 0.55),
    "AdmiralWrack_Body": (0.26, 0.23, 0.20),
    "AdmiralWrack_Fins": (0.40, 0.62, 0.58),
    "AdmiralWrack_Eyes": (0.50, 1.0, 0.85),
    "AdmiralWrack_Marks": (0.45, 0.90, 0.75),
    "Kraken_Body": (0.20, 0.15, 0.24),
    "Kraken_Fins": (0.30, 0.20, 0.30),
    "Kraken_Eyes": (1.0, 0.80, 0.30),
    "Kraken_Marks": (0.40, 0.90, 0.90),
    "KrakenTentacle_Body": (0.20, 0.15, 0.24),
    "KrakenTentacle_Fins": (0.30, 0.20, 0.30),
    "KrakenTentacle_Marks": (0.40, 0.90, 0.90),
    # Flyers (the new archetype: swamp, ice, wreck, maelstrom).
    "BogGull_Body": (0.72, 0.70, 0.62),
    "BogGull_Fins": (0.38, 0.36, 0.30),
    "BogGull_Eyes": (0.06, 0.06, 0.06),
    "BogGull_Marks": (0.50, 0.55, 0.40),
    "WillOWisp_Body": (0.75, 0.85, 0.80),
    "WillOWisp_Fins": (0.45, 0.70, 0.60),
    "WillOWisp_Eyes": (0.05, 0.06, 0.06),
    "WillOWisp_Marks": (0.60, 0.95, 0.75),
    "DreadDragonfly_Body": (0.20, 0.24, 0.20),
    "DreadDragonfly_Fins": (0.65, 0.75, 0.70),
    "DreadDragonfly_Eyes": (0.55, 0.90, 0.60),
    "DreadDragonfly_Marks": (0.55, 0.90, 0.50),
    "HailfinSkua_Body": (0.78, 0.82, 0.86),
    "HailfinSkua_Fins": (0.45, 0.55, 0.68),
    "HailfinSkua_Eyes": (0.06, 0.06, 0.06),
    "HailfinSkua_Marks": (0.62, 0.80, 0.95),
    "RiggingWraith_Body": (0.55, 0.60, 0.58),
    "RiggingWraith_Fins": (0.42, 0.46, 0.44),
    "RiggingWraith_Eyes": (0.50, 1.0, 0.85),
    "RiggingWraith_Marks": (0.45, 0.90, 0.75),
    "Stormpetrel_Body": (0.20, 0.22, 0.28),
    "Stormpetrel_Fins": (0.30, 0.33, 0.42),
    "Stormpetrel_Eyes": (0.06, 0.06, 0.07),
    "Stormpetrel_Marks": (0.75, 0.85, 1.0),
}

# The volcano roster, by species prefix. Used only to soften their preview
# emission (see make_material) - the game reads Creatures.luau, not this.
VOLCANO_SPECIES = {
    "Fumarole",
    "EmberSwarm",
    "MagmaOoze",
    "Shardback",
    "CinderDjinn",
    "LodestoneEel",
    "SlagGolem",
    "Phoenix",
}

# Preview-only glow for the parts the game renders as Neon.
GLOW_PARTS = {
    "Angler_Marks",
    "Jelly_Marks",
    "Voltray_Marks",
    "Mimic_Marks",
    "Leviathan_Marks",
    "Leviathan_Eyes",
    # Volcano: everything here is lit by lava, so every _Marks glows. Two of
    # them are load-bearing rather than decorative - the golem's core is the
    # tell for its armour-cracked window (Cracked attribute) and the phoenix's
    # plumage for its rebirth (Downed) - so they are separate objects a client
    # can switch to Neon.
    "Fumarole_Marks",
    "Fumarole_Eyes",
    # NOT EmberSwarm_Body: making the shards themselves emissive washed the
    # whole creature out to cream. The cinders are lit BY the heart, not
    # sources themselves.
    "EmberSwarm_Marks",
    "EmberSwarm_Eyes",
    "MagmaOoze_Marks",
    "Shardback_Marks",
    "Shardback_Eyes",
    "CinderDjinn_Marks",
    "CinderDjinn_Eyes",
    "LodestoneEel_Marks",
    "SlagGolem_Marks",
    "SlagGolem_Eyes",
    "Phoenix_Marks",
    # Revamp bosses: every boss's marks glow (their enrage tell); eyes glow
    # for the ones whose stare IS part of the design.
    "Gnashroot_Marks",
    "Rimefang_Marks",
    "Pyrelisk_Marks",
    "Pyrelisk_Eyes",
    "Noctyss_Marks",
    "AdmiralWrack_Marks",
    "AdmiralWrack_Eyes",
    "Kraken_Marks",
    "Kraken_Eyes",
    "KrakenTentacle_Marks",
    # Flyers: the wisp IS a light, the dragonfly's dread-glow abdomen is its
    # dive tell, the wraith burns ghost-fire, the petrel crackles.
    "WillOWisp_Marks",
    "DreadDragonfly_Marks",
    "DreadDragonfly_Eyes",
    "RiggingWraith_Eyes",
    "RiggingWraith_Marks",
    "Stormpetrel_Marks",
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
        # Volcano parts glow softer. At 1.2 a saturated orange clips straight
        # to yellow-white and every molten thing came out looking gold, which
        # is the opposite of the lava read we want.
        soft = VOLCANO_SPECIES | {"Gnashroot", "Pyrelisk"}  # moss/magma wash out at 1.2 just like the crater's molten parts
        bsdf.inputs["Emission Strength"].default_value = 0.65 if name.split("_")[0] in soft else 1.2
    mat.diffuse_color = (r, g, b, 1)
    return mat


def finish(name, bm, mat):
    """Turn a bmesh into a flat-shaded object."""
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    obj.data.materials.append(mat)
    for poly in mesh.polygons:
        poly.use_smooth = False
    bpy.context.collection.objects.link(obj)
    return obj


# ---------------------------------------------------------------- geometry primitives
# Each adds geometry straight into a target bmesh, so a whole limb/body group
# is one object.


def box(bm, center, size, rot=None):
    res = bmesh.ops.create_cube(bm, size=1.0)
    scale = Matrix.Diagonal(Vector((size[0], size[1], size[2], 1.0)))
    m = Matrix.Translation(Vector(center)) @ (rot or Matrix.Identity(4)) @ scale
    bmesh.ops.transform(bm, matrix=m, verts=res["verts"])


def ellipsoid(bm, center, radii, subdiv=1):
    res = bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=1.0)
    scale = Matrix.Diagonal(Vector((radii[0], radii[1], radii[2], 1.0)))
    m = Matrix.Translation(Vector(center)) @ scale
    bmesh.ops.transform(bm, matrix=m, verts=res["verts"])


def dome(bm, center, radii, subdiv=2):
    """Upper half of an ellipsoid (flat underside), for a shell."""
    res = bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=1.0)
    scale = Matrix.Diagonal(Vector((radii[0], radii[1], radii[2], 1.0)))
    bmesh.ops.transform(bm, matrix=Matrix.Translation(Vector(center)) @ scale, verts=res["verts"])
    doomed = [v for v in res["verts"] if v.co.z < center[2] - 1e-4]
    bmesh.ops.delete(bm, geom=doomed, context="VERTS")


def limb(bm, p0, p1, r0, r1, sides=6):
    """A tapered tube from p0 to p1 (radius r0 -> r1), capped. Legs, arms,
    claws, gaff, lure stalks - the workhorse for anything long."""
    p0, p1 = Vector(p0), Vector(p1)
    axis = p1 - p0
    length = axis.length
    if length < 1e-6:
        return
    d = axis / length
    up = Vector((0, 0, 1)) if abs(d.z) < 0.9 else Vector((1, 0, 0))
    u = d.cross(up).normalized()
    v = d.cross(u).normalized()

    def ring(p, r):
        return [bm.verts.new(p + (u * math.cos(a) + v * math.sin(a)) * r) for a in ((i / sides) * TAU for i in range(sides))]

    a = ring(p0, r0)
    b = ring(p1, r1)
    for i in range(sides):
        bm.faces.new((a[i], a[(i + 1) % sides], b[(i + 1) % sides], b[i]))
    bm.faces.new(list(reversed(a)))
    bm.faces.new(b)


def cone(bm, base, tip, r, sides=6):
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


def bridge(bm, a, b):
    n = len(a)
    for i in range(n):
        bm.faces.new((a[i], a[(i + 1) % n], b[(i + 1) % n], b[i]))


def connect_rings(bm, rings):
    """Bridge a list of rings in order; a ring may be a single apex vertex
    at either end (fanned), and open ends are capped."""
    for a, b in zip(rings, rings[1:]):
        if isinstance(a, list) and isinstance(b, list):
            bridge(bm, a, b)
        elif isinstance(a, list):
            for i in range(len(a)):
                bm.faces.new((a[i], a[(i + 1) % len(a)], b))
        elif isinstance(b, list):
            for i in range(len(b)):
                bm.faces.new((b[(i + 1) % len(b)], b[i], a))
    if isinstance(rings[0], list):
        bm.faces.new(list(reversed(rings[0])))
    if isinstance(rings[-1], list):
        bm.faces.new(rings[-1])


def revolve(bm, profile, sides=8, axis="x", center=(0, 0, 0), squash=1.0, phase=0.0, open_end=False):
    """Revolve a (t, r) profile about an axis through `center`: t runs along
    the axis, r is the radius there (0 = a pointed end). axis "x" gives a
    nose-tail body, "z" an upright bell / pot. `squash` scales the vertical
    (z for "x" bodies: a fish deeper than wide is squash > 1). `open_end`
    leaves the LAST ring uncapped (a gaping mouth)."""
    c = Vector(center)
    rings = []
    for t, r in profile:
        if r < 1e-5:
            p = c + (Vector((t, 0, 0)) if axis == "x" else Vector((0, 0, t)))
            rings.append(bm.verts.new(p))
        else:
            ring = []
            for i in range(sides):
                a = (i / sides) * TAU + phase
                if axis == "x":
                    p = c + Vector((t, math.cos(a) * r, math.sin(a) * r * squash))
                else:
                    p = c + Vector((math.cos(a) * r, math.sin(a) * r * squash, t))
                ring.append(bm.verts.new(p))
            rings.append(ring)
    for a, b in zip(rings, rings[1:]):
        if isinstance(a, list) and isinstance(b, list):
            bridge(bm, a, b)
        elif isinstance(a, list):
            for i in range(len(a)):
                bm.faces.new((a[i], a[(i + 1) % len(a)], b))
        elif isinstance(b, list):
            for i in range(len(b)):
                bm.faces.new((b[(i + 1) % len(b)], b[i], a))
    if isinstance(rings[0], list):
        bm.faces.new(list(reversed(rings[0])))
    if isinstance(rings[-1], list) and not open_end:
        bm.faces.new(rings[-1])
    return rings


def plate(bm, points, thickness, plane="xz", offset=(0, 0, 0)):
    """A thin extruded polygon: a fin, a tail, a wing edge, a shell plate.
    `points` are 2D in `plane` ("xz" = a fin standing in the body's side
    plane, extruded along y; "xy" = a flat horizontal plate, extruded along
    z). Give the outline in order around the shape."""
    off = Vector(offset)
    half = thickness / 2

    def lift(p, s):
        a, b = p
        if plane == "xz":
            return off + Vector((a, s * half, b))
        return off + Vector((a, b, s * half))

    front = [bm.verts.new(lift(p, -1)) for p in points]
    back = [bm.verts.new(lift(p, 1)) for p in points]
    bridge(bm, front, back)
    bm.faces.new(list(reversed(front)))
    bm.faces.new(back)


def chain(bm, points, radii, sides=5):
    """Consecutive limbs through `points` with per-point radii: a leg with a
    knee, a tendril with a drift, a stalk."""
    for i in range(len(points) - 1):
        limb(bm, points[i], points[i + 1], radii[i], radii[i + 1], sides)


def fluted_dome(bm, center, radius, height, ribs, amp, sides=24, rows=4, flat_bottom=True):
    """A scalloped half-shell (a clam valve): a dome whose radius ripples
    `ribs` times around (+/- amp) so the rim reads as fluted. Built about
    Z; the flat side faces down. Scale it elsewhere for an oval."""
    c = Vector(center)
    rings = []
    for j in range(rows + 1):
        u = j / rows  # 0 = rim, 1 = crown
        rr = radius * math.cos(u * math.pi / 2)
        z = height * math.sin(u * math.pi / 2)
        if rr < 1e-4:
            rings.append(bm.verts.new(c + Vector((0, 0, z))))
            continue
        ring = []
        for i in range(sides):
            a = (i / sides) * TAU
            r = rr * (1 + amp * math.cos(ribs * a) * (1 - u))
            ring.append(bm.verts.new(c + Vector((math.cos(a) * r, math.sin(a) * r, z))))
        rings.append(ring)
    for a, b in zip(rings, rings[1:]):
        if isinstance(b, list):
            bridge(bm, a, b)
        else:
            for i in range(len(a)):
                bm.faces.new((a[i], a[(i + 1) % len(a)], b))
    if flat_bottom:
        bm.faces.new(list(reversed(rings[0])))


def scale_verts(bm, verts, sx, sy, sz, center=(0, 0, 0)):
    m = Matrix.Translation(Vector(center)) @ Matrix.Diagonal(Vector((sx, sy, sz, 1.0))) @ Matrix.Translation(-Vector(center))
    bmesh.ops.transform(bm, matrix=m, verts=verts)


def all_verts(bm):
    return bm.verts[:]


# ---------------------------------------------------------------- crab
# Wide faceted shell, one oversized "snapjaw" claw + one small one, eight
# jointed legs, eye stalks. Forward = +X (claws), up = +Z, width = +/-Y.


def build_crab():
    body = bmesh.new()
    # Shell: a wide low dome, a touch deeper (X) than wide (Y) so front-back is
    # the longest axis. Faceted (subdiv 2).
    dome(body, (0.15, 0, 0.28), (1.15, 1.05, 0.55), subdiv=2)
    # A blunt front brow over the eyes/mouth.
    box(body, (1.0, 0, 0.3), (0.5, 1.1, 0.3))

    fins = bmesh.new()
    # Legs: four per side, two-segment, out and down to pointed feet. Kept
    # narrower than the body is deep (claws included) so the front-to-back axis
    # stays the single longest one - that's what flatOrientation reads as the
    # facing/charge direction, so the crab charges claws-first, not sideways.
    for sy in (-1, 1):
        for i in range(4):
            x = 0.55 - i * 0.42
            hip = Vector((x, sy * 0.8, 0.18))
            knee = Vector((x + 0.05, sy * 1.1, 0.52))
            foot = Vector((x + 0.1, sy * 1.35, -0.55))
            limb(fins, hip, knee, 0.15, 0.11, 5)
            limb(fins, knee, foot, 0.11, 0.03, 5)
    # Claws: one oversized "snapjaw" (+Y), one small (-Y). Each is a forearm, a
    # chunky knuckle, and a gaping two-pronged pincer held forward.
    for sy, scale in ((1, 1.35), (-1, 0.6)):
        shoulder = Vector((0.6, sy * 0.62, 0.34))
        elbow = Vector((1.35, sy * 0.5, 0.5))
        limb(fins, shoulder, elbow, 0.34 * scale, 0.28 * scale, 6)
        ellipsoid(fins, elbow, (0.3 * scale, 0.3 * scale, 0.3 * scale), 1)
        # Pincer: a fixed lower jaw and a raised upper jaw, gaping open. The
        # bigger the claw, the wider it gapes.
        base = elbow + Vector((0.1, 0, 0))
        limb(fins, base, base + Vector((0.85 * scale, 0, 0.34 * scale)), 0.24 * scale, 0.05, 5)
        limb(fins, base, base + Vector((0.9 * scale, 0, -0.18 * scale)), 0.24 * scale, 0.05, 5)

    eyes = bmesh.new()
    marks = bmesh.new()
    # Eye stalks (shell colour via _Marks so they read as part of the body) with
    # black eyeballs on top.
    for sy in (-1, 1):
        base = Vector((0.95, sy * 0.32, 0.52))
        top = Vector((1.05, sy * 0.34, 0.92))
        limb(marks, base, top, 0.09, 0.07, 5)
        ellipsoid(eyes, top + Vector((0.04, 0, 0.06)), (0.15, 0.15, 0.15), 1)
    # A pale mouth plate between the claws.
    box(marks, (1.12, 0, 0.12), (0.22, 0.5, 0.22))

    return [
        finish("Crab_Body", body, MATS["Crab_Body"]),
        finish("Crab_Fins", fins, MATS["Crab_Fins"]),
        finish("Crab_Eyes", eyes, MATS["Crab_Eyes"]),
        finish("Crab_Marks", marks, MATS["Crab_Marks"]),
    ]


# ---------------------------------------------------------------- zombie base
# Shared blocky drowned biped, authored Y-up (Blender +Z), facing +X. Returns
# the four bmeshes so each variant can add its own gear before finishing.


def zombie_base(hunch=0.22, gauntness=1.0):
    body = bmesh.new()  # flesh
    fins = bmesh.new()  # clothes
    eyes = bmesh.new()
    marks = bmesh.new()

    # Legs, planted, feet at z=0.
    for sy in (-1, 1):
        box(fins, (0.0, sy * 0.32, 0.75), (0.42, 0.42, 1.5))
        box(body, (0.0, sy * 0.32, 0.08), (0.5, 0.5, 0.2))  # rotted feet

    # Torso: hunched forward (top leans +X). Built as a box tilted about Y.
    lean = Matrix.Rotation(-hunch, 4, "Y")
    box(fins, (0.12, 0, 2.15), (0.95, 1.0 / gauntness, 1.5), lean)
    # A gaunt ribcage showing at the collar (flesh).
    box(body, (0.2, 0, 2.75), (0.6, 0.8 / gauntness, 0.4), lean)

    # Shoulders + arms reaching forward (+X) and down - the classic reach.
    for sy in (-1, 1):
        shoulder = Vector((0.25, sy * 0.52, 2.75))
        elbow = Vector((0.85, sy * 0.5, 2.2))
        hand = Vector((1.35, sy * 0.45, 1.75))
        limb(body, shoulder, elbow, 0.2, 0.17, 6)
        limb(body, elbow, hand, 0.17, 0.13, 6)
        ellipsoid(body, hand, (0.2, 0.18, 0.2), 1)  # gnarled hand

    # Head: sunken, tilted, a heavy brow. Neck cranes forward.
    neck = Vector((0.3, 0, 2.95))
    head_c = Vector((0.5, 0, 3.35))
    limb(body, neck, head_c, 0.18, 0.24, 6)
    ellipsoid(body, head_c, (0.42, 0.4, 0.44), 1)
    box(body, (0.72, 0, 3.28), (0.24, 0.5, 0.3))  # jutting jaw

    # Deep-set glowing eyes.
    for sy in (-1, 1):
        ellipsoid(eyes, head_c + Vector((0.32, sy * 0.19, 0.05)), (0.09, 0.09, 0.11), 1)

    return body, fins, eyes, marks, head_c, lean


# ---------------------------------------------------------------- drowned deckhand
# A hunched, tattered sailor: ragged shirt, draped seaweed, one shoulder gone.


def build_deckhand():
    body, fins, eyes, marks, head_c, lean = zombie_base(hunch=0.26, gauntness=1.05)

    # Torn shirt collar + a ragged vest hem (clothes).
    box(fins, (0.28, 0, 2.9), (0.5, 0.9, 0.22), lean)
    box(fins, (0.05, 0, 1.55), (1.0, 1.05, 0.3), lean)  # ragged hem

    # Seaweed strands draped off a shoulder and the arm (marks).
    for start, drops in (
        (Vector((0.2, 0.55, 2.85)), 3),
        (Vector((0.95, -0.45, 2.1)), 2),
    ):
        p = start
        for _ in range(drops):
            nxt = p + Vector((0.05, 0.0, -0.45))
            limb(marks, p, nxt, 0.06, 0.05, 4)
            p = nxt

    # A barnacle cluster on the back/shoulder (marks).
    for off in ((0.0, 0.3, 3.0), (-0.1, 0.15, 2.85), (0.05, 0.42, 2.78)):
        ellipsoid(marks, Vector((-0.15, off[1], off[2])), (0.1, 0.1, 0.1), 1)

    return [
        finish("Deckhand_Body", body, MATS["Deckhand_Body"]),
        finish("Deckhand_Fins", fins, MATS["Deckhand_Fins"]),
        finish("Deckhand_Eyes", eyes, MATS["Deckhand_Eyes"]),
        finish("Deckhand_Marks", marks, MATS["Deckhand_Marks"]),
    ]


# ---------------------------------------------------------------- drowned angler
# The zombie fisherman crossed with an anglerfish: a heavy oilskin coat and
# sou'wester, a gaff hook in one hand, and - the signature - a bioluminescent
# lure dangling on a stalk in front of its face.


def build_angler():
    body, fins, eyes, marks, head_c, lean = zombie_base(hunch=0.2, gauntness=0.92)

    # Long oilskin coat over the torso and down past the knees (clothes).
    box(fins, (0.16, 0, 2.05), (1.05, 1.15, 1.7), lean)
    box(fins, (0.05, 0, 1.15), (1.0, 1.1, 0.9))  # coat skirt
    # Big collar.
    box(fins, (0.3, 0, 2.95), (0.5, 1.05, 0.28), lean)

    # Sou'wester hat: a wide back brim + a crown, over the head.
    box(fins, (0.35, 0, 3.72), (0.85, 1.0, 0.14))
    box(fins, (0.45, 0, 3.6), (0.6, 0.72, 0.3))
    box(fins, (0.05, 0, 3.66), (0.35, 0.9, 0.24))  # long neck flap at the back

    # The lure: a stalk arcing forward off the hat with a glowing bulb (marks).
    stalk_base = Vector((0.55, 0, 3.85))
    stalk_mid = Vector((1.2, 0, 3.95))
    stalk_end = Vector((1.55, 0, 3.5))
    limb(marks, stalk_base, stalk_mid, 0.05, 0.04, 4)
    limb(marks, stalk_mid, stalk_end, 0.04, 0.03, 4)
    ellipsoid(marks, stalk_end + Vector((0.06, 0, -0.12)), (0.16, 0.16, 0.16), 2)

    # A gaff hook in the right hand (reaching hand is at ~(1.35, +/-0.45, 1.75)).
    hand = Vector((1.35, -0.5, 1.75))
    pole_top = hand + Vector((0.15, 0, 1.5))
    pole_bot = hand + Vector((-0.1, 0, -1.0))
    limb(fins, pole_bot, pole_top, 0.07, 0.06, 5)
    # the hook: a short curve at the top (marks, so it stands out)
    limb(marks, pole_top, pole_top + Vector((0.28, 0, -0.08)), 0.05, 0.04, 4)
    limb(marks, pole_top + Vector((0.28, 0, -0.08)), pole_top + Vector((0.28, 0, -0.4)), 0.04, 0.04, 4)

    return [
        finish("Angler_Body", body, MATS["Angler_Body"]),
        finish("Angler_Fins", fins, MATS["Angler_Fins"]),
        finish("Angler_Eyes", eyes, MATS["Angler_Eyes"]),
        finish("Angler_Marks", marks, MATS["Angler_Marks"]),
    ]


# ---------------------------------------------------------------- Tideline Skipper
# A mudskipper up on stilt legs: a long faceted body with a bulbous head, big
# frog eyes on top of the skull, a wide grinning mouth, a tall spiny sail on
# its back, four jointed stilt legs (the front pair muscular like a
# mudskipper's pectorals) and a paddle tail. Flat; front +X.
# bbox: X 3.3 (body + tail) > Y 2.0 (leg spread) > Z 1.5 (sail tip to feet).


def build_skipper():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # Body: revolved along X, deeper than wide, fattest behind the head.
    profile = [
        (-1.35, 0.0),
        (-1.2, 0.16),
        (-0.8, 0.3),
        (-0.3, 0.42),
        (0.3, 0.44),
        (0.75, 0.38),
        (1.05, 0.3),
    ]
    revolve(body, profile, sides=8, axis="x", center=(0, 0, 0.55), squash=1.25, open_end=False)
    # Head: a blunt skull bulging up and forward, wider than the body.
    ellipsoid(body, (1.2, 0, 0.7), (0.55, 0.52, 0.44), 1)
    # Brow ridges either side of the eyes.
    for sy in (-1, 1):
        box(body, (1.15, sy * 0.28, 1.0), (0.4, 0.18, 0.14))
    # Lips: a wide pale grin wrapping the snout (marks).
    box(marks, (1.6, 0, 0.5), (0.2, 0.7, 0.1))
    # Belly stripe down the flank (marks).
    plate(marks, [(-0.9, 0.18), (0.9, 0.22), (0.9, 0.36), (-0.9, 0.3)], 0.92, plane="xz", offset=(0, 0, 0))

    # Sail: a tall spiky dorsal fin, spines jutting above the membrane.
    sail = [(-0.95, 0.9), (-0.7, 1.45), (-0.35, 1.6), (0.05, 1.55), (0.45, 1.3), (0.7, 0.95)]
    plate(fins, sail, 0.06, plane="xz")
    for x, top in ((-0.7, 1.62), (-0.35, 1.8), (0.05, 1.72), (0.45, 1.45)):
        cone(fins, (x, 0, top - 0.35), (x, 0, top), 0.05, 4)
    # Tail: a rounded paddle.
    plate(fins, [(-1.3, 0.55), (-1.85, 0.95), (-2.05, 0.55), (-1.85, 0.15)], 0.06, plane="xz")

    # Stilt legs: front pair thick and elbowed (the pectoral "arms"), rear pair
    # thinner, all splayed out and down to pointed toes.
    for sy in (-1, 1):
        hip = Vector((0.7, sy * 0.35, 0.5))
        knee = Vector((0.85, sy * 0.8, 0.75))
        ankle = Vector((0.95, sy * 1.0, 0.1))
        toe = Vector((1.2, sy * 1.05, -0.1))
        chain(fins, [hip, knee, ankle, toe], [0.18, 0.14, 0.09, 0.03], 5)
        hip = Vector((-0.5, sy * 0.32, 0.45))
        knee = Vector((-0.55, sy * 0.75, 0.6))
        ankle = Vector((-0.5, sy * 0.95, 0.05))
        toe = Vector((-0.3, sy * 1.0, -0.1))
        chain(fins, [hip, knee, ankle, toe], [0.12, 0.1, 0.07, 0.03], 5)

    # Frog eyes: two big balls perched on top of the skull.
    for sy in (-1, 1):
        ellipsoid(eyes, (1.25, sy * 0.3, 1.12), (0.19, 0.19, 0.19), 1)

    return [
        finish("Skipper_Body", body, MATS["Skipper_Body"]),
        finish("Skipper_Fins", fins, MATS["Skipper_Fins"]),
        finish("Skipper_Eyes", eyes, MATS["Skipper_Eyes"]),
        finish("Skipper_Marks", marks, MATS["Skipper_Marks"]),
    ]


# ---------------------------------------------------------------- Gullet Cod
# A bloated cod with a gaping gullet: the body is revolved open at the front
# into a huge mouth - a dark throat cone inside (marks), a dropped lower jaw,
# a row of teeth, the chin barbel - with three dorsal fins, pectorals and a
# square tail. Flat; front +X.
# bbox: X 3.9 (jaw to tail) > Y 1.7 (pectorals) > Z 1.55 (dorsal to jaw).


def build_gulletcod():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    cz = 0.62
    # Body from tail to the open mouth rim: belly swells forward, then the
    # head flares out into the maw (the last ring is the open lip).
    profile = [
        (-1.55, 0.0),
        (-1.4, 0.18),
        (-0.95, 0.36),
        (-0.4, 0.5),
        (0.2, 0.56),
        (0.75, 0.52),
        (1.1, 0.48),
        (1.35, 0.5),
    ]
    revolve(body, profile, sides=10, axis="x", center=(0, 0, cz), squash=1.15, open_end=True)
    # Throat: a dark cone sunk back into the mouth (marks).
    revolve(marks, [(0.35, 0.0), (0.9, 0.3), (1.33, 0.46)], sides=10, axis="x", center=(0, 0, cz), squash=1.1, open_end=True)
    # Lower jaw: a scoop dropped open below the mouth, hinged at the throat.
    jaw = [(0.9, -0.05), (1.85, -0.45), (2.1, -0.25), (1.9, 0.02), (1.0, 0.2)]
    plate(body, jaw, 0.8, plane="xz", offset=(0, 0, cz))
    # Teeth: a ring of little fangs around the upper lip, and a row along the jaw.
    for i in range(7):
        a = (i / 7) * math.pi + math.pi  # the lower half of the rim
        y, z = math.cos(a) * 0.44, math.sin(a) * 0.5 * 1.15
        cone(fins, (1.32, y, cz + z + 0.1), (1.42, y, cz + z + 0.32), 0.05, 4)
    for i in range(4):
        y = -0.28 + i * 0.19
        cone(fins, (1.75, y, cz - 0.3), (1.8, y, cz - 0.08), 0.045, 4)
    # Chin barbel (short: the jaw already hangs low, and height must stay the
    # smallest axis).
    chain(marks, [Vector((1.7, 0, cz - 0.42)), Vector((1.82, 0, cz - 0.62)), Vector((1.78, 0, cz - 0.78))], [0.05, 0.04, 0.02], 4)

    # Three low dorsal fins (the cod's signature), an anal fin, broad
    # pectorals (they set the width - wider than it is tall), a tail.
    for x0, x1, h in ((-1.3, -0.85, 0.26), (-0.7, -0.1, 0.32), (0.0, 0.65, 0.28)):
        plate(fins, [(x0, 1.05), (x0 + 0.1, 1.05 + h), (x1 - 0.05, 1.05 + h * 0.9), (x1, 1.08)], 0.06, plane="xz", offset=(0, 0, cz - 0.5))
    plate(fins, [(-1.0, 0.05), (-0.9, -0.3), (-0.35, -0.26), (-0.3, 0.05)], 0.06, plane="xz", offset=(0, 0, cz - 0.1))
    for sy in (-1, 1):
        plate(fins, [(0.35, sy * 0.1), (0.5, sy * 0.62), (-0.15, sy * 0.55), (-0.25, sy * 0.05)], 0.06, plane="xy", offset=(0.75, sy * 0.5, cz - 0.1))
    plate(fins, [(-1.45, 0.62), (-2.0, 1.05), (-2.05, 0.2), (-1.45, 0.32)], 0.06, plane="xz", offset=(0, 0, cz - 0.15))

    # Bulging eyes high on the head.
    for sy in (-1, 1):
        ellipsoid(eyes, (1.05, sy * 0.48, cz + 0.32), (0.17, 0.17, 0.17), 1)

    # ---- nastier pass: a distended brine reservoir slung under the throat (the
    # brine it hacks up at you), warty bloat over the back, and a fuller ring of
    # hooked fangs around the whole maw.
    ellipsoid(body, (0.55, 0, cz - 0.5), (0.78, 0.72, 0.5), 1)
    ellipsoid(body, (-0.15, 0, cz - 0.42), (0.6, 0.66, 0.44), 1)
    for wx, wy, wz, wr in (
        (-0.5, 0.44, cz + 0.36, 0.16),
        (-1.0, -0.3, cz + 0.28, 0.14),
        (0.15, -0.5, cz + 0.2, 0.13),
        (-0.25, 0.5, cz - 0.05, 0.12),
        (0.5, 0.3, cz + 0.42, 0.12),
    ):
        ellipsoid(body, (wx, wy, wz), (wr, wr, wr * 0.85), 1)
    for i in range(11):
        a = (i / 11) * TAU
        y, z = math.cos(a) * 0.46, math.sin(a) * 0.5 * 1.15
        base = Vector((1.33, y, cz + z))
        tip = base + Vector((0.16, -y * 0.35, -z * 0.35))
        cone(fins, base, tip, 0.05, 4)
    # A second, longer barbel pair off the chin (marks, like the first).
    for sy in (-1, 1):
        chain(
            marks,
            [Vector((1.65, sy * 0.22, cz - 0.4)), Vector((1.8, sy * 0.3, cz - 0.62)), Vector((1.75, sy * 0.34, cz - 0.82))],
            [0.05, 0.04, 0.02],
            4,
        )

    return [
        finish("GulletCod_Body", body, MATS["GulletCod_Body"]),
        finish("GulletCod_Fins", fins, MATS["GulletCod_Fins"]),
        finish("GulletCod_Eyes", eyes, MATS["GulletCod_Eyes"]),
        finish("GulletCod_Marks", marks, MATS["GulletCod_Marks"]),
    ]


# ---------------------------------------------------------------- Tidebomb Urchin
# A faceted ball bristling with spines of two lengths - long ones around the
# equator, shorter toward the poles - with ember-coloured warts (marks) in the
# gaps and a ring of tube feet on the underside. Flat (sits belly-down):
# spines are scaled so the body's X > Y > Z ordering carries to the bbox.
# bbox: X 3.4 > Y 3.1 > Z 2.4.


def build_urchin():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    radii = Vector((1.0, 0.9, 0.72))
    cz = 0.85
    ellipsoid(body, (0, 0, cz), radii, 2)

    # Spines: latitude rings. Long at the equator, short near the poles, and
    # scaled per axis so the bbox keeps X > Y > Z.
    for lat_deg, count, length, r in ((-45, 8, 0.55, 0.07), (-15, 12, 0.9, 0.09), (15, 12, 0.95, 0.09), (45, 8, 0.6, 0.07), (75, 5, 0.35, 0.06)):
        lat = math.radians(lat_deg)
        for i in range(count):
            lon = (i / count) * TAU + (0.3 if count == 8 else 0.0)
            d = Vector((math.cos(lat) * math.cos(lon), math.cos(lat) * math.sin(lon), math.sin(lat)))
            axis_scale = Vector((1.0, 0.92, 0.7))
            base = Vector((0, 0, cz)) + Vector((d.x * radii.x, d.y * radii.y, d.z * radii.z)) * 0.92
            tip = base + Vector((d.x * axis_scale.x, d.y * axis_scale.y, d.z * axis_scale.z)) * length
            cone(fins, base, tip, r, 5)
    # Warts between the spines (marks): the ember that glows before it pops.
    for lat_deg, count in ((-30, 6), (0, 8), (30, 6)):
        lat = math.radians(lat_deg)
        for i in range(count):
            lon = (i / count) * TAU + 0.45
            d = Vector((math.cos(lat) * math.cos(lon), math.cos(lat) * math.sin(lon), math.sin(lat)))
            p = Vector((0, 0, cz)) + Vector((d.x * radii.x, d.y * radii.y, d.z * radii.z)) * 0.98
            ellipsoid(marks, p, (0.11, 0.11, 0.11), 1)
    # Tube feet under it: a ring of stubby stalks it creeps on.
    for i in range(8):
        a = (i / 8) * TAU
        foot = Vector((math.cos(a) * 0.55, math.sin(a) * 0.5, 0.05))
        limb(marks, Vector((math.cos(a) * 0.5, math.sin(a) * 0.45, cz - 0.55)), foot, 0.06, 0.05, 4)
    # A pair of beady eyes at the front (+X) between the spines.
    for sy in (-1, 1):
        ellipsoid(eyes, (0.95, sy * 0.22, cz + 0.1), (0.1, 0.1, 0.1), 1)

    return [
        finish("Urchin_Body", body, MATS["Urchin_Body"]),
        finish("Urchin_Fins", fins, MATS["Urchin_Fins"]),
        finish("Urchin_Eyes", eyes, MATS["Urchin_Eyes"]),
        finish("Urchin_Marks", marks, MATS["Urchin_Marks"]),
    ]


# ---------------------------------------------------------------- Moonbell Jelly
# A faceted bell with a fluted, slightly flared rim, a glowing core and four
# thick frilled oral arms (marks), and a skirt of thin drifting tendrils
# (fins). UPRIGHT (row stance): authored Z-up, lowest point at z=0.
# Height 3.3; width 2.4. Two tiny eyes on the bell front (+X), because
# everything in this game has eyes.


def build_jelly():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    base_z = 2.2  # the bell's rim height
    # Bell: a dome with a lip that flares and curls under at the rim.
    bell = [(-0.12, 0.95), (0.0, 1.15), (0.18, 1.2), (0.5, 1.05), (0.8, 0.72), (0.98, 0.3), (1.05, 0.0)]
    revolve(body, bell, sides=12, axis="z", center=(0, 0, base_z), phase=0.26)
    # Rim frills: a scalloped ring just under the lip (fins).
    for i in range(12):
        a = (i / 12) * TAU + 0.26
        p = Vector((math.cos(a) * 1.12, math.sin(a) * 1.12, base_z - 0.1))
        ellipsoid(fins, p, (0.17, 0.17, 0.1), 1)

    # Core: the glowing gonad ring inside the bell + a central bulb (marks).
    for i in range(4):
        a = (i / 4) * TAU + 0.6
        ellipsoid(marks, (math.cos(a) * 0.42, math.sin(a) * 0.42, base_z + 0.42), (0.22, 0.22, 0.16), 1)
    ellipsoid(marks, (0, 0, base_z + 0.1), (0.28, 0.28, 0.22), 1)

    # Oral arms: four thick frilled ribbons trailing down with a drift (marks).
    for i in range(4):
        a = (i / 4) * TAU + 0.2
        out = Vector((math.cos(a), math.sin(a), 0))
        pts = [
            Vector((0, 0, base_z - 0.05)) + out * 0.32,
            Vector((0, 0, base_z - 0.7)) + out * 0.45,
            Vector((0, 0, base_z - 1.35)) + out * 0.38,
            Vector((0, 0, base_z - 1.9)) + out * 0.55,
        ]
        chain(marks, pts, [0.16, 0.14, 0.11, 0.05], 5)

    # Tendrils: a skirt of thin threads, each with its own drift (fins).
    for i in range(14):
        a = (i / 14) * TAU
        out = Vector((math.cos(a), math.sin(a), 0))
        sway = Vector((math.cos(a + 1.3), math.sin(a + 1.3), 0)) * 0.18 * (1 if i % 2 else -1)
        pts = [
            Vector((0, 0, base_z - 0.12)) + out * 1.0,
            Vector((0, 0, base_z - 0.9)) + out * 1.08 + sway,
            Vector((0, 0, base_z - 1.7)) + out * 1.0 - sway,
            Vector((0, 0, base_z - 2.2 + (0.25 if i % 3 == 0 else 0.0))) + out * 1.12,
        ]
        chain(fins, pts, [0.05, 0.045, 0.035, 0.015], 4)

    # Eyes on the front of the bell.
    for sy in (-1, 1):
        ellipsoid(eyes, (1.0, sy * 0.3, base_z + 0.45), (0.09, 0.09, 0.09), 1)

    return [
        finish("Jelly_Body", body, MATS["Jelly_Body"]),
        finish("Jelly_Fins", fins, MATS["Jelly_Fins"]),
        finish("Jelly_Eyes", eyes, MATS["Jelly_Eyes"]),
        finish("Jelly_Marks", marks, MATS["Jelly_Marks"]),
    ]


# ---------------------------------------------------------------- Sand Lurker
# A flounder: a broad faceted oval body, a continuous frilled fin fringe all
# the way round (fins), a fan tail, both eyes up on the front on little
# stalks (it lies on its side, so they've migrated to the top), a crooked
# mouth, and sand-coloured mottling discs on its back (marks). Flat and
# belly-down: height is by far the smallest. Front +X.
# bbox: X 3.4 > Y 2.3 > Z 0.55.


def build_lurker():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    cz = 0.2
    # Body: a squashed faceted ellipsoid, slightly egg-shaped (blunter front).
    res = bmesh.ops.create_icosphere(body, subdivisions=2, radius=1.0)
    for v in res["verts"]:
        x, y, z = v.co
        taper = 1.0 + 0.12 * x  # fuller at the front
        v.co = Vector((x * 1.35, y * 0.9 * taper, z * 0.19 * (0.6 + 0.4 * (1 - abs(x)))))
    bmesh.ops.translate(body, verts=res["verts"], vec=(0.05, 0, cz))

    # Fringe fin: a ring of wedge plates around the body's rim, drooping.
    n = 22
    for i in range(n):
        a0 = (i / n) * TAU
        a1 = ((i + 1) / n) * TAU
        if abs(math.cos(a0)) > 0.9 and math.cos(a0) > 0:
            continue  # no fringe across the mouth
        inner = 0.92
        outer = 1.22 + 0.08 * math.sin(i * 2.1)
        pts = []
        for a, rr in ((a0, inner), (a1, inner), (a1, outer), (a0, outer)):
            pts.append((math.cos(a) * 1.35 * rr, math.sin(a) * 0.9 * rr))
        plate(fins, pts, 0.05, plane="xy", offset=(0.05, 0, cz - 0.02))
    # Tail: a fan off the back.
    plate(fins, [(-1.3, 0.0), (-1.85, 0.45), (-2.05, 0.0), (-1.85, -0.45)], 0.05, plane="xy", offset=(0.05, 0, cz))

    # Mottling: flat discs scattered over the back, plus a pale crooked mouth.
    for x, y, r in ((0.55, 0.35, 0.2), (0.1, -0.3, 0.24), (-0.45, 0.3, 0.18), (-0.7, -0.25, 0.16), (0.35, -0.55, 0.12), (-0.2, 0.05, 0.11)):
        revolve(marks, [(0.0, r), (0.06, r * 0.9), (0.07, 0.0)], sides=7, axis="z", center=(x, y, cz + 0.18))
    plate(marks, [(1.25, -0.3), (1.42, -0.1), (1.42, 0.12), (1.3, 0.3), (1.2, 0.1)], 0.08, plane="xy", offset=(0, 0, cz + 0.1))

    # Eyes: both on top at the front, on short stalks, looking different ways.
    for sy, tilt in ((-1, -0.05), (1, 0.08)):
        base = Vector((0.95, sy * 0.28, cz + 0.15))
        top = base + Vector((0.05 + tilt, sy * 0.05, 0.32))
        limb(body, base, top, 0.1, 0.09, 5)
        ellipsoid(eyes, top + Vector((0.03, 0, 0.05)), (0.15, 0.15, 0.15), 1)

    return [
        finish("Lurker_Body", body, MATS["Lurker_Body"]),
        finish("Lurker_Fins", fins, MATS["Lurker_Fins"]),
        finish("Lurker_Eyes", eyes, MATS["Lurker_Eyes"]),
        finish("Lurker_Marks", marks, MATS["Lurker_Marks"]),
    ]


# ---------------------------------------------------------------- Pearl Mimic
# A giant clam: two fluted, faceted valves - the lower one the body, the lid
# the _Fins object (CreatureService hinges it 0.9 behind the centre on the
# facing axis) - with a fat pearl and the glistening mantle lips inside
# (marks), barnacle growths on the outside, and two small eyes peeking from
# under the lid's front edge. UPRIGHT (row stance). Closed as authored: the
# lid sits on the lower valve. Front (the gape) is +X; the hinge is at -X.
# Width 2.7, depth 2.4, height 1.1.


def build_mimic():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # Lower valve: a fluted dome flipped to open upward (scale z by -1 then
    # lifted), oval (wider across Y than deep along X? no - deeper along X so
    # the gape is at the front).
    fluted_dome(body, (0, 0, 0), 1.0, 0.5, ribs=9, amp=0.07, sides=27, rows=4)
    scale_verts(body, all_verts(body), 1.2, 1.35, -1.0)
    bmesh.ops.translate(body, verts=all_verts(body), vec=(0, 0, 0.52))
    # Barnacles crusting the lower valve (body colour, shares the object).
    for x, y, z in ((-0.6, 0.9, 0.25), (0.3, -1.1, 0.2), (-1.0, -0.4, 0.3), (0.8, 0.7, 0.15)):
        revolve(body, [(0.0, 0.16), (0.14, 0.12), (0.2, 0.0)], sides=6, axis="z", center=(x, y, z))

    # Lid: the same valve the right way up, resting on the lower one.
    fluted_dome(fins, (0, 0, 0), 1.0, 0.5, ribs=9, amp=0.07, sides=27, rows=4)
    scale_verts(fins, all_verts(fins), 1.22, 1.37, 1.0)
    bmesh.ops.translate(fins, verts=all_verts(fins), vec=(0, 0, 0.56))
    # A ridged umbo (the hump near the hinge) on the lid.
    ellipsoid(fins, (-0.75, 0, 0.95), (0.32, 0.3, 0.2), 1)

    # Inside: the pearl and the frilly mantle lips along the gape (marks).
    ellipsoid(marks, (0.2, 0, 0.6), (0.36, 0.36, 0.36), 2)
    for i in range(9):
        a = (i / 9) * TAU
        if math.cos(a) < 0.2:
            continue
        p = Vector((math.cos(a) * 1.08, math.sin(a) * 1.22, 0.54))
        ellipsoid(marks, p, (0.12, 0.12, 0.08), 1)

    # Eyes: peeking out from the front of the gape.
    for sy in (-1, 1):
        ellipsoid(eyes, (1.05, sy * 0.4, 0.6), (0.1, 0.1, 0.1), 1)

    return [
        finish("Mimic_Body", body, MATS["Mimic_Body"]),
        finish("Mimic_Fins", fins, MATS["Mimic_Fins"]),
        finish("Mimic_Eyes", eyes, MATS["Mimic_Eyes"]),
        finish("Mimic_Marks", marks, MATS["Mimic_Marks"]),
    ]


# ---------------------------------------------------------------- Pickpocket Hermit
# A hermit crab living in a clay pot (body = the pot, tilted back on its
# rump), the crab itself (fins) scuttling out the front: a small carapace,
# six legs, one big and one small claw, eye stalks; a spill of coins (marks)
# piled on the pot's rim and one held up in the big claw. Flat; front +X.
# bbox: X 3.1 > Y 2.1 > Z 1.55.


def build_hermit():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # The pot: a revolved bulbous jar with a neck and a rolled rim, lying on
    # its side pointing forward (+X) and tilted up a little.
    jar = [(0.0, 0.0), (0.08, 0.45), (0.35, 0.78), (0.8, 0.86), (1.25, 0.72), (1.45, 0.5), (1.55, 0.46), (1.72, 0.52), (1.8, 0.5)]
    revolve(body, jar, sides=10, axis="x", center=(0, 0, 0), phase=0.3, open_end=True)
    tilt = Matrix.Rotation(math.radians(-18), 4, "Y")
    bmesh.ops.transform(body, matrix=Matrix.Translation(Vector((-1.6, 0, 0.55))) @ tilt, verts=all_verts(body))
    # A crack and a chipped rim piece.
    box(body, (-0.45, -0.55, 0.75), (0.55, 0.08, 0.12), Matrix.Rotation(0.5, 4, "X"))

    # The crab: carapace + abdomen tucked into the pot mouth.
    ellipsoid(fins, (0.35, 0, 0.48), (0.5, 0.42, 0.32), 1)
    box(fins, (0.6, 0, 0.5), (0.35, 0.7, 0.26))  # a brow over the face
    # Legs: three per side, bent out and down.
    for sy in (-1, 1):
        for i in range(3):
            x = 0.45 - i * 0.3
            hip = Vector((x, sy * 0.35, 0.4))
            knee = Vector((x + 0.05, sy * 0.75, 0.62))
            foot = Vector((x + 0.08, sy * 1.0, 0.0))
            limb(fins, hip, knee, 0.09, 0.07, 5)
            limb(fins, knee, foot, 0.07, 0.02, 5)
    # Claws: a big one (-Y) held up with a coin, a small one (+Y) forward.
    shoulder = Vector((0.6, -0.35, 0.5))
    elbow = Vector((1.05, -0.55, 0.85))
    limb(fins, shoulder, elbow, 0.16, 0.14, 6)
    ellipsoid(fins, elbow, (0.2, 0.2, 0.2), 1)
    limb(fins, elbow, elbow + Vector((0.45, -0.05, 0.35)), 0.14, 0.04, 5)
    limb(fins, elbow, elbow + Vector((0.5, 0.05, 0.1)), 0.14, 0.04, 5)
    shoulder = Vector((0.6, 0.35, 0.45))
    elbow = Vector((1.0, 0.5, 0.45))
    limb(fins, shoulder, elbow, 0.1, 0.09, 5)
    limb(fins, elbow, elbow + Vector((0.4, 0.0, 0.12)), 0.09, 0.03, 5)
    limb(fins, elbow, elbow + Vector((0.42, 0.0, -0.1)), 0.09, 0.03, 5)

    # Coins: stacked and spilled on the pot's rim, one in the big claw.
    def coin(center, rot=None):
        res = bmesh.ops.create_cone(marks, cap_ends=True, segments=8, radius1=0.17, radius2=0.17, depth=0.05)
        m = Matrix.Translation(Vector(center)) @ (rot or Matrix.Identity(4))
        bmesh.ops.transform(marks, matrix=m, verts=res["verts"])

    for c, r in (
        ((-0.35, 0.2, 1.05), Matrix.Rotation(0.3, 4, "X")),
        ((-0.5, 0.05, 1.1), Matrix.Rotation(-0.2, 4, "Y")),
        ((-0.6, 0.32, 1.0), Matrix.Rotation(0.9, 4, "Y")),
        ((-0.2, -0.15, 0.98), Matrix.Rotation(1.2, 4, "X")),
        ((-0.9, -0.3, 0.8), Matrix.Rotation(0.4, 4, "Y")),
        ((1.38, -0.58, 1.12), Matrix.Rotation(math.radians(90), 4, "Y")),
    ):
        coin(c, r)

    # Eye stalks.
    for sy in (-1, 1):
        base = Vector((0.7, sy * 0.18, 0.6))
        top = Vector((0.78, sy * 0.2, 0.9))
        limb(fins, base, top, 0.06, 0.05, 5)
        ellipsoid(eyes, top + Vector((0.02, 0, 0.05)), (0.1, 0.1, 0.1), 1)

    return [
        finish("Hermit_Body", body, MATS["Hermit_Body"]),
        finish("Hermit_Fins", fins, MATS["Hermit_Fins"]),
        finish("Hermit_Eyes", eyes, MATS["Hermit_Eyes"]),
        finish("Hermit_Marks", marks, MATS["Hermit_Marks"]),
    ]


# ---------------------------------------------------------------- Voltray
# An electric ray: a broad kite-shaped disc built as a faceted grid so it
# has real volume - a thick spine ridge down the middle thinning out to the
# wing edges, which curl up a touch - a long whip tail with a barb, wing-edge
# trim (fins), two big electric organs on the wings with a row of nodes down
# the spine (marks; the client lights them while it charges), and raised
# eyes at the front. Flat and belly-down; front +X.
# bbox: X 6.1 (tail) > Y 3.4 > Z 0.7.


def build_voltray():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    cz = 0.3
    # Disc outline (top view): a kite, nose at +X.
    half_len_front, half_len_back, half_wid = 1.5, 1.4, 1.7

    def outline(t):
        # t in [0, 1) around the kite; returns (x, y)
        a = t * TAU
        x = math.cos(a)
        y = math.sin(a)
        # Kite: stretch front/back, pinch width toward the ends.
        sx = half_len_front if x > 0 else half_len_back
        return (x * sx * (1.0 - 0.08 * abs(y)), y * half_wid * (1.0 - 0.35 * x * x))

    # Build the disc as a stack of concentric rings (top sheet + bottom sheet).
    rings_n = 4
    sides = 20
    tops, bots = [], []
    for j in range(rings_n + 1):
        u = j / rings_n  # 0 = centre, 1 = rim
        thick = 0.5 * (1 - u * u) + 0.06
        ring_t, ring_b = [], []
        for i in range(sides):
            x, y = outline(i / sides)
            x, y = x * u, y * u
            curl = 0.22 * max(0.0, u - 0.6) / 0.4 * (abs(y) / half_wid)  # wing tips curl up
            ring_t.append(body.verts.new(Vector((x, y, cz + thick / 2 + curl))))
            ring_b.append(body.verts.new(Vector((x, y, cz - thick / 2 + curl))))
        tops.append(ring_t)
        bots.append(ring_b)
    # Centre caps.
    top_c = body.verts.new(Vector((0.1, 0, cz + 0.34)))
    bot_c = body.verts.new(Vector((0.1, 0, cz - 0.3)))
    for i in range(sides):
        body.faces.new((tops[1][i], tops[1][(i + 1) % sides], top_c))
        body.faces.new((bots[1][(i + 1) % sides], bots[1][i], bot_c))
    for j in range(1, rings_n):
        bridge(body, tops[j], tops[j + 1])
        bridge(body, bots[j + 1], bots[j])
    bridge(body, bots[rings_n], tops[rings_n])  # the rim wall

    # Spine ridge: a low raised keel down the back.
    revolve(body, [(-1.3, 0.0), (-0.9, 0.14), (0.4, 0.2), (1.1, 0.12), (1.45, 0.0)], sides=6, axis="x", center=(0, 0, cz + 0.3), squash=0.7)
    # Tail: a long tapering whip with a barb at the end (body + fins barb).
    chain(body, [Vector((-1.35, 0, cz)), Vector((-2.4, 0, cz + 0.05)), Vector((-3.4, 0, cz - 0.02)), Vector((-4.3, 0, cz + 0.04))], [0.2, 0.14, 0.09, 0.04], 6)
    plate(fins, [(-4.25, 0.0), (-4.75, 0.12), (-4.55, 0.0), (-4.75, -0.12)], 0.06, plane="xy", offset=(0, 0, cz + 0.04))
    # A small dorsal near the tail root.
    plate(fins, [(-1.55, 0.0), (-1.75, 0.35), (-2.1, 0.3), (-2.2, 0.0)], 0.06, plane="xz", offset=(0, 0, cz + 0.05))
    # Wing-edge trim: darker wedge plates along the leading edges.
    for i in range(sides):
        x0, y0 = outline(i / sides)
        x1, y1 = outline((i + 1) / sides)
        if x0 + x1 <= 0.2:
            continue
        plate(fins, [(x0 * 0.9, y0 * 0.9), (x1 * 0.9, y1 * 0.9), (x1 * 1.03, y1 * 1.03), (x0 * 1.03, y0 * 1.03)], 0.07, plane="xy", offset=(0, 0, cz + 0.08))

    # Electric organs: two big oval pads on the wings + nodes down the spine (marks).
    for sy in (-1, 1):
        res = bmesh.ops.create_icosphere(marks, subdivisions=1, radius=1.0)
        bmesh.ops.transform(marks, matrix=Matrix.Translation(Vector((0.25, sy * 0.85, cz + 0.36))) @ Matrix.Diagonal(Vector((0.55, 0.4, 0.1, 1))), verts=res["verts"])
    for x in (-0.7, -0.3, 0.1, 0.5, 0.9):
        ellipsoid(marks, (x, 0, cz + 0.5), (0.1, 0.1, 0.07), 1)

    # Eyes: raised bumps at the front of the disc.
    for sy in (-1, 1):
        ellipsoid(body, (1.05, sy * 0.32, cz + 0.36), (0.2, 0.18, 0.14), 1)
        ellipsoid(eyes, (1.12, sy * 0.32, cz + 0.46), (0.11, 0.11, 0.11), 1)

    return [
        finish("Voltray_Body", body, MATS["Voltray_Body"]),
        finish("Voltray_Fins", fins, MATS["Voltray_Fins"]),
        finish("Voltray_Eyes", eyes, MATS["Voltray_Eyes"]),
        finish("Voltray_Marks", marks, MATS["Voltray_Marks"]),
    ]


# ================================================================ Volcano roster (2026-08-23)
# The crater's eight hostiles (docs/volcano-content-spec.md). Same contract as
# everything above: built facing +X, flat ones with x > y > z, upright ones
# Z-up with stance set in their row, four parts each, flat shaded.
#
# These are read as much as they are looked at: three of the six new archetypes
# announce themselves through the mesh, so the silhouette is doing mechanical
# work, not just decoration.
#   - Shardback: a WALL of glass shards on the front and bare shell behind, so
#     "hit it from behind" is visible before you learn it the hard way.
#   - Slagheart Golem: the molten core sits in a deliberate GAP in its chest
#     plating, so the crack-open window has something to light.
#   - Ashfeather Phoenix: the fire lives in a separate plumage layer, so the
#     rebirth can flare without recolouring the bird.


# ---------------------------------------------------------------- Fumarole
# A rooted lava vent: a low blistered mound of cooled rock with a stubby
# chimney leaning forward (+X) and a molten throat it lobs globs from. FLAT:
# longer than wide, wider than tall, so flatOrientation lays it mound-down
# facing +X. bbox target: X 3.0 > Y 2.1 > Z 1.4.


def build_fumarole():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # A CREATURE, not scenery. The first build was a mound with a hole in it,
    # which read as a piece of the terrain that happened to be spitting - you
    # would never have punched it. It is now a hunched rock beast: a heavy brow
    # over a glowing maw, squat legs under it, and the vents moved onto its
    # BACK as a row of stacks, which is also what keeps the height legal.
    body_c = Vector((-0.05, 0, 0.62))
    ellipsoid(body, body_c, (1.25, 0.95, 0.5), 2)
    # A blunt head slung low and forward, with a heavy overhanging brow.
    ellipsoid(body, (0.95, 0, 0.6), (0.62, 0.72, 0.42), 2)
    box(body, (1.05, 0, 0.86), (0.75, 1.3, 0.26), Matrix.Rotation(0.16, 4, "Y"))

    # THE MAW: a wide glowing gash under the brow, with rock teeth over it.
    ellipsoid(marks, (1.22, 0, 0.5), (0.34, 0.66, 0.24), 2)
    for i in range(7):
        yy = (i / 6 - 0.5) * 1.14
        cone(fins, Vector((1.3, yy, 0.68)), Vector((1.38, yy, 0.36)), 0.09, 4)
        cone(fins, Vector((1.28, yy * 0.92, 0.3)), Vector((1.34, yy * 0.92, 0.54)), 0.08, 4)

    # VENT STACKS on its back: three chimneys angled backward, each with a
    # molten throat. Leaning them -X keeps the bbox length-dominant.
    for i, (bx, by, h, r) in enumerate(((-0.15, 0.0, 0.72, 0.3), (-0.62, 0.42, 0.6, 0.24), (-0.62, -0.42, 0.6, 0.24))):
        base = Vector((bx, by, 0.9))
        tip = base + Vector((-0.34, by * 0.25, h))
        limb(body, base, tip, r + 0.1, r, 6)
        ellipsoid(marks, tip + Vector((-0.02, 0, 0.02)), (r * 0.72, r * 0.72, r * 0.42), 1)

    # Hot seams cracking across the shoulders between the stacks.
    for sy in (-1, 1):
        chain(
            marks,
            [Vector((0.62, sy * 0.34, 0.98)), Vector((0.05, sy * 0.6, 0.88)), Vector((-0.62, sy * 0.72, 0.66))],
            [0.09, 0.08, 0.06],
            4,
        )

    # Four squat rock legs, so it plainly stands rather than sits.
    for sy in (-1, 1):
        for bx in (0.55, -0.62):
            hip = Vector((bx, sy * 0.62, 0.5))
            foot = Vector((bx + 0.06, sy * 0.86, 0.1))
            limb(body, hip, foot, 0.24, 0.19, 5)
            box(body, foot + Vector((0.02, 0, -0.04)), (0.46, 0.4, 0.16))

    # Jagged cooled splatter fringing the base.
    for i in range(8):
        a = (i / 8) * TAU + 0.2
        base = Vector((math.cos(a) * 1.05 - 0.05, math.sin(a) * 0.78, 0.12))
        cone(fins, base, base + Vector((math.cos(a) * 0.16, math.sin(a) * 0.14, 0.3)), 0.14, 5)

    # Small burning eyes deep under the brow.
    for sy in (-1, 1):
        ellipsoid(eyes, (1.3, sy * 0.3, 0.74), (0.12, 0.12, 0.11), 1)

    return [
        finish("Fumarole_Body", body, MATS["Fumarole_Body"]),
        finish("Fumarole_Fins", fins, MATS["Fumarole_Fins"]),
        finish("Fumarole_Eyes", eyes, MATS["Fumarole_Eyes"]),
        finish("Fumarole_Marks", marks, MATS["Fumarole_Marks"]),
    ]


# ---------------------------------------------------------------- Ember Swarm
# Not one creature: a hovering shoal of live cinders holding a rough shape.
# Chunky shards (body) around a hot heart (marks), with sparks drifting off the
# bottom (fins). UPRIGHT (row stance), ~3.2 tall.


def build_ember_swarm():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    heart = Vector((0, 0, 2.0))

    # A VORTEX, not a scatter. The first build was cinders on three concentric
    # shells, which read as debris blown across the screen rather than as one
    # creature - nothing tied it together and nothing said which way it faced.
    # Two spiral arms winding up around a burning heart give it a direction, a
    # centre and a readable silhouette.
    ellipsoid(marks, heart, (0.46, 0.44, 0.48), 2)
    for arm in (0.0, TAU / 3, 2 * TAU / 3):
        for i in range(16):
            t = i / 15
            a = arm + t * 3.0
            r = 0.5 + t * 0.95
            z = heart.z - 0.72 + t * 1.85
            size = 0.27 * (1.0 - 0.42 * t)
            # Two shards per step, offset around the arm, so each arm is a
            # braided rope of cinders rather than a single thin ribbon.
            for k, off in enumerate((-0.16, 0.16)):
                p = Vector((math.cos(a + off) * r * 1.08, math.sin(a + off) * r, z + off * 0.6))
                rot = Matrix.Rotation(a, 4, "Z") @ Matrix.Rotation(t * 1.3 + k, 4, "Y")
                box(body, p, (size * 2.3, size * 1.5, size * 1.3), rot)
            # Every third step stays white-hot, so the arms glow along their
            # length instead of only at the core.
            if i % 3 == 0:
                hp = Vector((math.cos(a) * r * 1.08, math.sin(a) * r, z))
                ellipsoid(marks, hp, (size * 0.62, size * 0.62, size * 0.62), 1)

    # The updraught: a tapering column of embers drawn up into the vortex from
    # below, which also plants the shape instead of leaving it floating.
    for i in range(11):
        t = i / 10
        a = t * 5.4
        r = 0.62 * (1.0 - t * 0.72)
        size = 0.2 * (1.0 - t * 0.5)
        p = Vector((math.cos(a) * r, math.sin(a) * r, 0.18 + t * 1.15))
        box(body, p, (size * 2.0, size * 1.4, size * 1.2), Matrix.Rotation(a, 4, "Z"))
        if i % 3 == 0:
            ellipsoid(marks, p, (size * 0.55, size * 0.55, size * 0.55), 1)

    # Two eyes burning hotter than anything else, well forward so the swarm
    # clearly faces you.
    for sy in (-1, 1):
        ellipsoid(eyes, heart + Vector((0.88, sy * 0.3, 0.14)), (0.19, 0.17, 0.18), 1)

    # Trailing sparks, each STARTING on a shard of the outer arm rather than in
    # mid-air - the first build left them floating detached behind the cloud,
    # which read as debris that had nothing to do with the creature.
    # The start point is the arm's LAST shard, computed from the same formula
    # the arms use - hand-guessed coordinates left one spark hanging in space
    # beside the vortex, attached to nothing.
    arm_end_r = 0.5 + 0.95
    arm_end_z = heart.z - 0.72 + 1.85
    for arm in (0.0, TAU / 3, 2 * TAU / 3):
        a0 = arm + 3.0
        p = Vector((math.cos(a0) * arm_end_r * 1.08, math.sin(a0) * arm_end_r, arm_end_z))
        for step in range(3):
            nxt = p + Vector((-0.3 - step * 0.05, math.sin(a0) * 0.14, 0.2 - step * 0.12))
            limb(fins, p, nxt, 0.12 - step * 0.028, 0.09 - step * 0.028, 4)
            p = nxt

    return [
        finish("EmberSwarm_Body", body, MATS["EmberSwarm_Body"]),
        finish("EmberSwarm_Fins", fins, MATS["EmberSwarm_Fins"]),
        finish("EmberSwarm_Eyes", eyes, MATS["EmberSwarm_Eyes"]),
        finish("EmberSwarm_Marks", marks, MATS["EmberSwarm_Marks"]),
    ]


# ---------------------------------------------------------------- Magma Ooze
# A slumped blob of living magma with a pseudopod hauling it forward (+X), a
# crust of cooled skin, and glowing seams. The seams earn their keep: this is
# the one that DIVIDES when killed, so it should look pre-cracked along the
# lines it comes apart on. FLAT. bbox target: X 2.6 > Y 2.0 > Z 1.3.


def build_magma_ooze():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # Inverted from the first build, which put a dull orange body on top with
    # thin glowing veins drawn over it and read as a lumpy potato. Now the
    # MOLTEN MASS IS THE MARKS LAYER - the whole upper body glows - and the
    # cooled black crust (fins) is laid over it in slabs, so the lava shows
    # through the gaps between them. That is what actually reads as molten.
    ellipsoid(marks, (-0.05, 0, 0.46), (1.2, 1.02, 0.46), 2)
    dome(marks, (-0.1, 0, 0.5), (1.0, 0.84, 0.62), 2)
    for cx, cy, cz_, r in ((0.42, 0.28, 0.5, 0.44), (0.36, -0.32, 0.46, 0.4), (-0.88, 0.22, 0.44, 0.38)):
        ellipsoid(marks, (cx, cy, cz_), (r, r * 0.92, r * 0.72), 1)

    # A heavy sagging skirt where it has cooled against the ground.
    ellipsoid(body, (-0.05, 0, 0.2), (1.3, 1.1, 0.22), 2)
    # Drips: a few fat sags off the rim, NOT a ring of them - nine evenly
    # spaced drips read as a row of little legs and turned the whole thing into
    # a beetle. Four, uneven, and short enough to look like sagging melt.
    for a, drop, r0 in ((0.5, 0.3, 0.22), (2.2, 0.22, 0.18), (3.5, 0.26, 0.2), (5.1, 0.18, 0.16)):
        top = Vector((math.cos(a) * 0.95 - 0.05, math.sin(a) * 0.84, 0.28))
        limb(body, top, top + Vector((0.02, 0, -drop)), r0, r0 * 0.62, 5)
        ellipsoid(marks, top + Vector((0.02, 0, -drop - 0.03)), (r0 * 0.6, r0 * 0.6, r0 * 0.5), 1)

    # CRUST: broad cooled slabs floating on the melt, tilted at odd angles and
    # deliberately NOT tiling - the gaps between them are where it glows.
    for cx, cy, cz_, sx, sy_, rot, tilt in (
        (-0.42, 0.3, 1.02, 0.72, 0.6, 0.5, 0.18),
        (-0.3, -0.42, 0.96, 0.66, 0.56, -0.4, -0.14),
        (0.28, 0.44, 0.88, 0.58, 0.5, 0.95, 0.22),
        (0.44, -0.3, 0.9, 0.54, 0.52, -0.8, -0.2),
        (-0.98, -0.02, 0.78, 0.5, 0.66, 0.15, 0.3),
        (0.1, 0.02, 1.12, 0.62, 0.58, 0.35, 0.0),
    ):
        box(fins, (cx, cy, cz_), (sx, sy_, 0.13), Matrix.Rotation(rot, 4, "Z") @ Matrix.Rotation(tilt, 4, "Y"))
    # A ring of smaller cooled scabs around the waist.
    for i in range(8):
        a = (i / 8) * TAU + 0.6
        p = Vector((math.cos(a) * 0.92 - 0.05, math.sin(a) * 0.8, 0.56))
        box(fins, p, (0.34, 0.3, 0.11), Matrix.Rotation(a, 4, "Z") @ Matrix.Rotation(0.55, 4, "Y"))

    # Two dark pits sunk into the melt at the front. No snout this time: the
    # old pseudopod plus drips read as a boar's face rather than a blob.
    for sy in (-1, 1):
        ellipsoid(eyes, (0.86, sy * 0.3, 0.7), (0.16, 0.15, 0.14), 1)

    return [
        finish("MagmaOoze_Body", body, MATS["MagmaOoze_Body"]),
        finish("MagmaOoze_Fins", fins, MATS["MagmaOoze_Fins"]),
        finish("MagmaOoze_Eyes", eyes, MATS["MagmaOoze_Eyes"]),
        finish("MagmaOoze_Marks", marks, MATS["MagmaOoze_Marks"]),
    ]


# ---------------------------------------------------------------- Obsidian Shardback
# A crab sheathed in volcanic glass. The FRONT is a wall of angled shards and
# the back is bare shell - that asymmetry IS the fight (armoured facing you,
# soft from behind), so it has to be legible before a player learns it the hard
# way. FLAT. bbox target: X 3.0 > Y 2.4 > Z 1.3.


def build_shardback():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # Carapace: longer than wide, so the flat check passes.
    dome(body, (-0.1, 0, 0.34), (1.42, 1.12, 0.66), 2)
    box(body, (-0.1, 0, 0.3), (2.5, 1.9, 0.32))

    # THE ARMOUR: a wall of glass jutting FORWARD, built as wedges rather than
    # xz plates. A plate in that plane is a thin fin whose face points sideways,
    # so from the front - the one angle the player actually fights this thing
    # from - the whole shield was invisible edge-on. Spikes read from anywhere.
    for yy, h, fwd, r in ((0.0, 1.32, 0.62, 0.3), (0.46, 1.14, 0.54, 0.26), (-0.46, 1.14, 0.54, 0.26), (0.88, 0.92, 0.44, 0.22), (-0.88, 0.92, 0.44, 0.22)):
        cone(fins, Vector((0.72, yy, 0.38)), Vector((0.72 + fwd, yy * 1.08, h)), r, 4)
    # Broad slabs behind the spikes, tilted so their faces angle forward too.
    for sy in (-1, 1):
        box(fins, (0.42, sy * 0.66, 0.72), (0.46, 0.36, 0.86), Matrix.Rotation(-0.55, 4, "Y"))

    # Molten glow in the gaps between the front shards...
    for sy in (-1, 1):
        for y0 in (0.23, 0.67):
            ellipsoid(marks, (0.8, sy * y0, 0.6), (0.16, 0.1, 0.2), 1)
    # ...and an exposed seam down the back, marking the soft side.
    chain(marks, [Vector((-0.5, 0, 0.98)), Vector((-1.0, 0, 0.86)), Vector((-1.45, 0, 0.62))], [0.1, 0.09, 0.06], 4)

    # Six legs, tucked rather than splayed: a wider stance made the body wider
    # than it is long, which fails the flat check and would lay it on its side.
    for sy in (-1, 1):
        for hx, reach, lift in ((0.5, 0.34, 0.1), (-0.15, 0.44, 0.08), (-0.8, 0.5, 0.06)):
            hip = Vector((hx, sy * 0.85, 0.34))
            knee = Vector((hx - 0.1, sy * (0.85 + reach * 0.6), 0.62))
            foot = Vector((hx - 0.22, sy * (0.85 + reach), lift))
            limb(fins, hip, knee, 0.13, 0.1, 5)
            limb(fins, knee, foot, 0.1, 0.07, 5)

    # Claws held forward, glass-edged.
    for sy in (-1, 1):
        limb(fins, Vector((0.7, sy * 0.7, 0.42)), Vector((1.15, sy * 0.85, 0.36)), 0.16, 0.14, 5)
        box(fins, (1.42, sy * 0.82, 0.36), (0.5, 0.34, 0.3), Matrix.Rotation(sy * -0.25, 4, "Z"))
        plate(fins, [(1.3, 0.05), (1.9, 0.16), (1.82, -0.1)], 0.1, plane="xy", offset=(0, sy * 0.78, 0.46))

    # Eyes on short stalks, peeking over the shard wall.
    for sy in (-1, 1):
        base = Vector((0.55, sy * 0.24, 0.82))
        top = Vector((0.68, sy * 0.26, 1.06))
        limb(body, base, top, 0.07, 0.06, 4)
        ellipsoid(eyes, top + Vector((0.03, 0, 0.05)), (0.11, 0.11, 0.11), 1)

    return [
        finish("Shardback_Body", body, MATS["Shardback_Body"]),
        finish("Shardback_Fins", fins, MATS["Shardback_Fins"]),
        finish("Shardback_Eyes", eyes, MATS["Shardback_Eyes"]),
        finish("Shardback_Marks", marks, MATS["Shardback_Marks"]),
    ]


# ---------------------------------------------------------------- Cinder Djinn
# A wraith with no legs: a column of smoke narrowing to nothing at the floor, a
# torso, long reaching arms and an ember core. It sheds burning smoke as it
# walks, so the body itself is built coming apart into the air. UPRIGHT (row
# stance), ~3.6 tall.


def build_cinder_djinn():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # The column: a tapering funnel, pointed at the bottom.
    revolve(
        body,
        [(0.0, 0.02), (0.35, 0.34), (0.8, 0.55), (1.3, 0.62), (1.85, 0.52), (2.3, 0.66), (2.75, 0.58)],
        sides=9,
        axis="z",
        squash=0.82,
    )
    box(body, (0.05, 0, 2.92), (0.8, 1.15, 0.34), Matrix.Rotation(-0.18, 4, "Y"))
    head_c = Vector((0.22, 0, 3.28))
    ellipsoid(body, head_c, (0.36, 0.34, 0.38), 1)

    # Arms reaching forward, thinning into smoke at the hands.
    for sy in (-1, 1):
        limb(body, Vector((0.1, sy * 0.5, 2.88)), Vector((0.62, sy * 0.56, 2.42)), 0.17, 0.13, 5)
        limb(body, Vector((0.62, sy * 0.56, 2.42)), Vector((1.12, sy * 0.48, 2.1)), 0.13, 0.07, 5)

    # The core burning in its chest, cinders rising off it, and split seams.
    ellipsoid(marks, (0.16, 0, 2.5), (0.28, 0.24, 0.3), 2)
    for i in range(9):
        a = (i / 9) * TAU
        p = Vector((math.cos(a) * 0.42 + 0.05, math.sin(a) * 0.38, 1.6 + (i % 4) * 0.42))
        ellipsoid(marks, p, (0.09, 0.09, 0.09), 1)
    for sy in (-1, 1):
        chain(
            marks,
            [Vector((0.28, sy * 0.2, 1.05)), Vector((0.3, sy * 0.3, 1.7)), Vector((0.24, sy * 0.24, 2.28))],
            [0.05, 0.07, 0.06],
            4,
        )

    # Torn streamers curling off the shoulders and column.
    for start, sy in ((Vector((-0.3, 0.45, 2.75)), 1), (Vector((-0.32, -0.4, 2.6)), -1), (Vector((-0.35, 0.1, 1.9)), 1)):
        p = start
        for step in range(3):
            nxt = p + Vector((-0.3, sy * 0.16, 0.22 - step * 0.12))
            limb(fins, p, nxt, 0.1 - step * 0.02, 0.08 - step * 0.02, 4)
            p = nxt

    for sy in (-1, 1):
        ellipsoid(eyes, head_c + Vector((0.28, sy * 0.16, 0.04)), (0.1, 0.1, 0.11), 1)

    return [
        finish("CinderDjinn_Body", body, MATS["CinderDjinn_Body"]),
        finish("CinderDjinn_Fins", fins, MATS["CinderDjinn_Fins"]),
        finish("CinderDjinn_Eyes", eyes, MATS["CinderDjinn_Eyes"]),
        finish("CinderDjinn_Marks", marks, MATS["CinderDjinn_Marks"]),
    ]


# ---------------------------------------------------------------- Lodestone Eel
# A long magnetite serpent, banded with ore that lights when it hauls you in, a
# ribbon fin down the whole back and a blunt heavy head. Its length carries the
# flat check on its own, so the S-curve is kept shallow in Y.
# bbox target: X 5.6 > Y 1.7 > Z 1.1.


def build_lodestone_eel():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    cz = 0.5
    spine = [
        Vector((2.35, 0.0, cz + 0.02)),
        Vector((1.5, 0.16, cz)),
        Vector((0.6, 0.1, cz + 0.04)),
        Vector((-0.3, -0.14, cz)),
        Vector((-1.2, -0.16, cz + 0.02)),
        Vector((-2.05, 0.06, cz)),
        Vector((-2.75, 0.12, cz)),
    ]
    chain(body, spine, [0.34, 0.4, 0.38, 0.33, 0.26, 0.16, 0.05], 7)

    head = Vector((2.5, 0, cz + 0.02))
    ellipsoid(body, head, (0.46, 0.34, 0.32), 2)
    box(body, (2.62, 0, cz - 0.16), (0.6, 0.44, 0.16), Matrix.Rotation(0.1, 4, "Y"))

    # A TALL ragged crest, not a low piping: at 0.24 studs the old one vanished
    # against the body and the eel read as a plain tapered tube. Cut into
    # spikes so the silhouette has teeth.
    # Crest and pectorals are sized TOGETHER: a tall crest alone pushed the
    # height past the width and failed the flat check (a ribbon of a creature
    # is easy to tip over that line). Wide swept pectorals restore width > height
    # and, as a bonus, make it read as a ribbon eel rather than a pipe.
    top = [(p.x, cz + 0.34 + (0.46 if -1.6 < p.x < 1.7 else 0.14)) for p in spine]
    plate(fins, [(spine[0].x, cz + 0.1)] + top + [(spine[-1].x, cz - 0.05)], 0.08, plane="xz")
    for i, x in enumerate((1.5, 0.9, 0.3, -0.3, -0.9, -1.5)):
        plate(fins, [(x + 0.3, cz + 0.72), (x, cz + 1.0 - (i % 2) * 0.14), (x - 0.3, cz + 0.72)], 0.08, plane="xz")
    plate(fins, [(1.2, cz - 0.34), (0.2, cz - 0.58), (-0.9, cz - 0.38)], 0.07, plane="xz")
    for sy in (-1, 1):
        plate(fins, [(2.0, 0.0), (1.35, sy * 1.05), (0.95, sy * 0.78), (1.3, 0.0)], 0.07, plane="xy", offset=(0, 0, cz))

    # ORE BANDS: continuous rings girdling the body, built from overlapping
    # segments. The first build used seven small beads per ring, which read as
    # gravel sprinkled on its back rather than as bands of magnetite.
    for x, r in ((1.75, 0.4), (0.95, 0.42), (0.15, 0.39), (-0.7, 0.33), (-1.5, 0.24)):
        for i in range(12):
            a = (i / 12) * TAU
            p = Vector((x, math.cos(a) * r, cz + math.sin(a) * r * 0.92))
            ellipsoid(marks, p, (0.1, 0.13, 0.13), 1)
    # A lodestone nodule on the brow, and two on the crest.
    ellipsoid(marks, (2.62, 0, cz + 0.26), (0.18, 0.16, 0.16), 1)
    for x in (0.9, -0.6):
        ellipsoid(marks, (x, 0, cz + 1.2), (0.14, 0.1, 0.14), 1)

    for sy in (-1, 1):
        ellipsoid(eyes, (2.66, sy * 0.24, cz + 0.12), (0.1, 0.1, 0.1), 1)

    return [
        finish("LodestoneEel_Body", body, MATS["LodestoneEel_Body"]),
        finish("LodestoneEel_Fins", fins, MATS["LodestoneEel_Fins"]),
        finish("LodestoneEel_Eyes", eyes, MATS["LodestoneEel_Eyes"]),
        finish("LodestoneEel_Marks", marks, MATS["LodestoneEel_Marks"]),
    ]


# ---------------------------------------------------------------- Slagheart Golem
# A heavy humanoid of cooled slag with a molten heart caged in its chest. THE
# CORE IS THE MECHANIC: it is armoured until you crack the plating, so the
# chest plates (fins) are a cage with a deliberate gap and the core (marks)
# sits in that gap where a client can light it. UPRIGHT, ~4.2 tall.


def build_slag_golem():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # Legs: short and thick, feet at z=0.
    for sy in (-1, 1):
        box(body, (0.0, sy * 0.42, 0.5), (0.62, 0.6, 1.0))
        box(body, (0.08, sy * 0.42, 0.12), (0.82, 0.68, 0.26))

    lean = Matrix.Rotation(-0.1, 4, "Y")
    box(body, (0.05, 0, 1.85), (1.05, 1.35, 1.5), lean)
    box(body, (0.0, 0, 2.72), (1.15, 1.85, 0.55), lean)

    # Long heavy arms, knuckles near the knees.
    for sy in (-1, 1):
        shoulder = Vector((0.05, sy * 0.85, 2.6))
        elbow = Vector((0.3, sy * 1.0, 1.75))
        fist = Vector((0.5, sy * 0.95, 1.0))
        limb(body, shoulder, elbow, 0.3, 0.26, 6)
        limb(body, elbow, fist, 0.26, 0.22, 6)
        box(body, fist + Vector((0.06, 0, -0.16)), (0.5, 0.46, 0.44))

    head_c = Vector((0.16, 0, 3.2))
    box(body, head_c, (0.6, 0.66, 0.62))

    # THE CORE, and the seams feeding it.
    core = Vector((0.55, 0, 2.05))
    ellipsoid(marks, core, (0.3, 0.34, 0.38), 2)
    for sy in (-1, 1):
        chain(marks, [core + Vector((0.02, sy * 0.3, 0.35)), Vector((0.3, sy * 0.6, 2.6)), Vector((0.1, sy * 0.75, 2.95))], [0.08, 0.07, 0.05], 4)
        chain(marks, [core + Vector((0.0, sy * 0.28, -0.35)), Vector((0.28, sy * 0.5, 1.35)), Vector((0.12, sy * 0.4, 0.9))], [0.08, 0.06, 0.05], 4)

    # THE CRUST: slag slabs caging the chest, leaving the core showing through
    # the gap between them. Breaking these is the fight.
    for sy in (-1, 1):
        plate(fins, [(0.3, 1.45), (0.78, 1.6), (0.82, 2.5), (0.34, 2.62)], 0.16, plane="xz", offset=(0, sy * 0.62, 0))
        box(fins, (-0.05, sy * 0.95, 2.85), (0.9, 0.5, 0.4), Matrix.Rotation(sy * 0.12, 4, "X"))
        box(fins, (-0.45, sy * 0.4, 2.0), (0.3, 0.7, 1.2))
    plate(fins, [(0.34, 2.5), (0.84, 2.42), (0.86, 2.72), (0.36, 2.8)], 0.16, plane="xz")
    plate(fins, [(0.36, 1.36), (0.84, 1.28), (0.82, 1.6), (0.34, 1.66)], 0.16, plane="xz")

    for sy in (-1, 1):
        ellipsoid(eyes, head_c + Vector((0.3, sy * 0.18, 0.06)), (0.1, 0.1, 0.11), 1)

    return [
        finish("SlagGolem_Body", body, MATS["SlagGolem_Body"]),
        finish("SlagGolem_Fins", fins, MATS["SlagGolem_Fins"]),
        finish("SlagGolem_Eyes", eyes, MATS["SlagGolem_Eyes"]),
        finish("SlagGolem_Marks", marks, MATS["SlagGolem_Marks"]),
    ]


# ---------------------------------------------------------------- Ashfeather Phoenix
# A bird caught mid-dive: streamlined along +X with its wings swept BACK rather
# than spread. That is both the pose (it charges) and what keeps the bounding
# box length-dominant for the flat check - a spread wingspan would be wider
# than it is long and lie on its side in game. The fire is a separate plumage
# layer so the rebirth can flare without recolouring the bird.
# bbox target: X 4.2 > Y 3.0 > Z 1.5.


def build_phoenix():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    cz = 0.85
    # A raptor, not a songbird: deep keeled chest tapering hard to the tail
    # root, so the mass sits forward and the silhouette has a direction.
    revolve(
        body,
        [(-1.75, 0.05), (-1.15, 0.32), (-0.45, 0.56), (0.2, 0.64), (0.85, 0.5), (1.3, 0.28)],
        sides=10,
        axis="x",
        center=(0, 0, cz),
        squash=1.3,
    )
    # Arched neck carrying the head high and forward.
    chain(
        body,
        [Vector((1.15, 0, cz + 0.14)), Vector((1.6, 0, cz + 0.44)), Vector((1.95, 0, cz + 0.42))],
        [0.27, 0.21, 0.18],
        7,
    )
    head_c = Vector((2.08, 0, cz + 0.4))
    ellipsoid(body, head_c, (0.28, 0.23, 0.25), 1)
    # Hooked beak: a long upper mandible bent down over a short lower one.
    cone(body, head_c + Vector((0.14, 0, 0.03)), head_c + Vector((0.6, 0, -0.04)), 0.13, 5)
    cone(body, head_c + Vector((0.52, 0, -0.03)), head_c + Vector((0.66, 0, -0.24)), 0.08, 5)
    cone(body, head_c + Vector((0.14, 0, -0.13)), head_c + Vector((0.44, 0, -0.19)), 0.09, 5)

    # WINGS: three broad overlapping blades a side, swept back into one solid
    # shape. The old build used thin quills that read as a bundle of sticks -
    # a wing has to be a SURFACE at this poly count or it reads as nothing.
    for sy in (-1, 1):
        for i, (rootx, tipx, tipy, chord) in enumerate(
            ((0.85, -0.7, 1.68, 1.5), (0.6, -1.4, 1.5, 1.35), (0.3, -2.05, 1.15, 1.1))
        ):
            pts = [
                (rootx, 0.22),
                (tipx + chord, sy * tipy * 0.5),
                (tipx, sy * tipy),
                (tipx - chord * 0.55, sy * tipy * 0.8),
                (rootx - 1.0, 0.2),
            ]
            plate(fins, pts, 0.1, plane="xy", offset=(0, 0, cz + 0.26 - i * 0.15))
        # A thick leading-edge bone, so the wing has structure under the sheet.
        limb(body, Vector((0.7, sy * 0.28, cz + 0.28)), Vector((-0.75, sy * 1.45, cz + 0.2)), 0.16, 0.08, 5)

    # TAIL: three long streamers trailing well past the body.
    for sy in (-1, 0, 1):
        pts = [(-1.3, sy * 0.12), (-2.3, sy * 0.55), (-3.25, sy * 0.42), (-2.4, sy * 0.05)]
        plate(fins, pts, 0.08, plane="xy", offset=(0, 0, cz - 0.02 + abs(sy) * 0.12))

    # CREST: a swept fan of quills off the skull, in the fire layer.
    for i, (lift, back) in enumerate(((0.42, 0.3), (0.58, 0.42), (0.42, 0.32))):
        plate(
            marks,
            [(1.95, cz + 0.6), (1.95 - back - 0.35, cz + 0.6 + lift), (1.95 - back, cz + 0.5)],
            0.07,
            plane="xz",
            offset=(0, (i - 1) * 0.15, 0),
        )

    # FIRE: bold hot edges rather than dots - the trailing edge of every wing
    # blade, the tail tips, and a burning breast. This is the layer the rebirth
    # flares, so it has to be visible from the front and the side.
    for sy in (-1, 1):
        for i, (tipx, tipy, chord) in enumerate(((-0.7, 1.68, 1.5), (-1.4, 1.5, 1.35), (-2.05, 1.15, 1.1))):
            plate(
                marks,
                [
                    (tipx + chord * 0.1, sy * tipy * 0.98),
                    (tipx - chord * 0.55, sy * tipy * 0.8),
                    (tipx - chord * 0.62, sy * tipy * 0.95),
                    (tipx - chord * 0.05, sy * tipy * 1.12),
                ],
                0.12,
                plane="xy",
                offset=(0, 0, cz + 0.26 - i * 0.15),
            )
    for sy in (-1, 0, 1):
        ellipsoid(marks, (-3.15, sy * 0.42, cz + 0.02 + abs(sy) * 0.12), (0.24, 0.14, 0.09), 1)
    for x, r in ((0.7, 0.3), (0.2, 0.38), (-0.35, 0.32)):
        ellipsoid(marks, (x, 0, cz - 0.46), (r * 0.8, r, 0.14), 1)

    for sy in (-1, 1):
        ellipsoid(eyes, head_c + Vector((0.16, sy * 0.17, 0.08)), (0.09, 0.08, 0.09), 1)

    return [
        finish("Phoenix_Body", body, MATS["Phoenix_Body"]),
        finish("Phoenix_Fins", fins, MATS["Phoenix_Fins"]),
        finish("Phoenix_Eyes", eyes, MATS["Phoenix_Eyes"]),
        finish("Phoenix_Marks", marks, MATS["Phoenix_Marks"]),
    ]


# ---------------------------------------------------------------- bbox check


# ---------------------------------------------------------------- Brinejaw, the Drowned Leviathan (island boss)
# A colossal drowned anglerfish: a faceted, deep-keeled body that swells into
# an armoured skull, a maw hung open on a slab of a lower jaw with two rows
# of fangs and a pair of tusks, a tall ragged sail of spines down the back,
# swept pectoral fins, a forked tail, a lure on a stalk off the brow with a
# glowing bulb, and glowing gill slits (marks - lit when it enrages). Scute
# ridges along the flanks and brow plates so it reads as armoured, not
# smooth. UPRIGHT (row stance): Z-up, front +X, ~13 studs long, ~7.5 tall to
# the sail's tip, ~6 wide. Lowest point (the jaw) near z=0.
# bbox: X 15 > Z 7.5 > Y 6.


def build_leviathan():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    zc = 3.0  # body axis height

    # Main body: deep-keeled (squash 1.15), broadest just behind the skull.
    revolve(
        body,
        [
            (-7.2, 0.0),
            (-6.4, 0.55),
            (-5.0, 1.05),
            (-3.4, 1.65),
            (-1.6, 2.05),
            (0.4, 2.25),
            (2.2, 2.35),
            (3.6, 2.15),
            (4.6, 1.6),
            (5.3, 0.85),
            (5.6, 0.0),
        ],
        sides=10,
        axis="x",
        center=(0, 0, zc),
        squash=1.15,
        phase=TAU / 20,
    )
    # Armoured skull: a broad dome over the front of the body, and a brow
    # ridge that juts over the eyes.
    dome(body, (2.4, 0, zc + 0.9), (3.0, 2.5, 1.6), 1)
    box(body, (3.9, 0, zc + 1.5), (1.6, 3.6, 0.5), Matrix.Rotation(math.radians(-12), 4, "Y"))
    # Cheek plates either side of the maw.
    for s in (-1, 1):
        box(body, (3.4, s * 2.15, zc - 0.2), (2.2, 0.45, 1.7), Matrix.Rotation(math.radians(s * 10), 4, "X"))

    # Lower jaw: a slab hung open (tip down), with its own chin keel.
    jaw_rot = Matrix.Rotation(math.radians(18), 4, "Y")
    box(body, (3.3, 0, zc - 2.1), (4.4, 3.3, 0.75), jaw_rot)
    box(body, (2.2, 0, zc - 2.45), (1.6, 2.2, 0.9), jaw_rot)

    # Fangs: an upper row hanging from the skull's rim, a lower row standing
    # up from the jaw, and a tusk each side.
    for i in range(6):
        y = -1.35 + i * 0.54
        x = 4.9 - abs(y) * 0.35
        cone(fins, (x, y, zc - 0.35), (x + 0.1, y, zc - 1.35), 0.17, 5)
    for i in range(5):
        y = -1.1 + i * 0.55
        x = 5.0 - abs(y) * 0.3
        cone(fins, (x, y, zc - 1.95), (x + 0.15, y, zc - 1.05), 0.15, 5)
    for s in (-1, 1):
        cone(fins, (4.4, s * 1.75, zc - 0.25), (5.3, s * 1.9, zc - 1.9), 0.24, 6)

    # The sail: one ragged plate of spines along the back (xz plane).
    sail = [
        (-5.4, zc + 1.3),
        (-4.9, zc + 3.3),
        (-4.2, zc + 1.9),
        (-3.4, zc + 4.0),
        (-2.6, zc + 2.1),
        (-1.7, zc + 4.5),
        (-0.8, zc + 2.25),
        (0.2, zc + 4.2),
        (1.0, zc + 2.3),
        (1.8, zc + 3.6),
        (2.4, zc + 2.1),
        (2.9, zc + 1.9),
        (-5.8, zc + 0.8),
    ]
    plate(fins, sail, 0.28, "xz")
    # Spine ribs down the sail's base so it reads as membrane between bones.
    for x in (-4.9, -3.4, -1.7, 0.2, 1.8):
        limb(fins, (x, 0, zc + 1.4), (x, 0, zc + 2.6), 0.14, 0.08, 4)

    # Tail: a forked fin on a narrow stock.
    plate(
        fins,
        [(-7.0, zc + 0.35), (-9.4, zc + 2.9), (-8.5, zc + 2.0), (-8.3, zc), (-8.6, zc - 1.9), (-9.5, zc - 2.7), (-7.0, zc - 0.35)],
        0.3,
        "xz",
    )

    # Pectoral fins: swept back and out, horizontal plates at each side.
    for s in (-1, 1):
        plate(
            fins,
            [(1.2, s * 1.9), (-1.0, s * 4.3), (-3.0, s * 4.1), (-2.4, s * 2.6), (-1.2, s * 1.9)],
            0.28,
            "xy",
            offset=(0, 0, zc - 0.9),
        )
    # Pelvic fins under the belly, smaller.
    for s in (-1, 1):
        plate(
            fins,
            [(-2.0, s * 1.2), (-3.4, s * 2.6), (-4.4, s * 2.3), (-3.6, s * 1.0)],
            0.22,
            "xy",
            offset=(0, 0, zc - 1.7),
        )

    # Scute ridges along the flanks and the belly keel.
    for i in range(6):
        x = 1.4 - i * 1.25
        for s in (-1, 1):
            box(fins, (x, s * 2.05, zc + 0.7), (0.6, 0.3, 0.55), Matrix.Rotation(math.radians(35), 4, "Y"))
    for i in range(5):
        x = 0.6 - i * 1.3
        box(fins, (x, 0, zc - 2.45), (0.7, 0.45, 0.4))

    # The lure: a stalk off the brow, arcing forward, a glowing bulb on the end.
    chain(
        fins,
        [(3.2, 0, zc + 2.1), (4.6, 0, zc + 3.6), (6.2, 0, zc + 3.9), (7.2, 0, zc + 3.2)],
        [0.24, 0.18, 0.13, 0.1],
        5,
    )
    ellipsoid(marks, (7.3, 0, zc + 2.85), (0.55, 0.55, 0.6), 1)
    ellipsoid(marks, (7.3, 0, zc + 2.85), (0.28, 0.28, 0.3), 1)

    # Gill slits, three a side, and a glowing throat patch at the back of the maw.
    for s in (-1, 1):
        for i in range(3):
            box(marks, (0.9 - i * 0.6, s * 2.25, zc - 0.1), (0.2, 0.2, 1.5), Matrix.Rotation(math.radians(-12), 4, "Y"))
    ellipsoid(marks, (2.9, 0, zc - 0.95), (0.9, 1.1, 0.45), 1)

    # Eyes: pale, lidded under the brow ridge.
    for s in (-1, 1):
        ellipsoid(eyes, (3.6, s * 2.15, zc + 0.75), (0.5, 0.3, 0.42), 1)
        box(body, (3.6, s * 2.2, zc + 1.1), (1.1, 0.3, 0.3), Matrix.Rotation(math.radians(s * 15), 4, "X"))  # brow

    # ---- "really cool" pass: a horned crown, a proper anglerfish esca, drowned
    # encrustation (barnacles + a harpoon still lodged in its back), and glowing
    # veins - so it reads as a crowned, hunted, ancient sea-devil.

    # Crown: swept horns off the skull crest - two curving pairs a side and a
    # tall central spike.
    for s in (-1, 1):
        chain(
            fins,
            [(3.2, s * 0.55, zc + 2.2), (2.5, s * 1.0, zc + 3.7), (1.2, s * 1.35, zc + 4.7), (-0.1, s * 1.2, zc + 5.1)],
            [0.3, 0.21, 0.13, 0.05],
            5,
        )
        chain(
            fins,
            [(3.7, s * 1.2, zc + 1.9), (3.2, s * 1.8, zc + 3.1), (2.3, s * 2.05, zc + 3.9)],
            [0.22, 0.15, 0.05],
            5,
        )
    cone(fins, (2.9, 0, zc + 2.4), (2.4, 0, zc + 5.6), 0.24, 6)

    # Great tusks curving up past the snout.
    for s in (-1, 1):
        chain(
            fins,
            [(4.5, s * 1.85, zc - 0.4), (5.7, s * 2.0, zc - 1.5), (6.5, s * 1.75, zc - 0.4), (6.7, s * 1.5, zc + 0.9)],
            [0.28, 0.19, 0.12, 0.04],
            6,
        )

    # Esca: a cage of bone ribs around the glowing bulb (fins), with thin
    # filaments trailing down, each ending in a glowing bead (marks).
    bulb = Vector((7.3, 0, zc + 2.85))
    for k in range(5):
        a = (k / 5) * TAU
        off = Vector((0, math.cos(a), math.sin(a)))
        chain(fins, [bulb + Vector((-0.5, 0, 0)) + off * 0.2, bulb + off * 0.66, bulb + Vector((0.5, 0, 0)) + off * 0.2], [0.05, 0.06, 0.05], 4)
    for dy in (-0.4, 0.0, 0.4):
        tip = bulb + Vector((0.15, dy, -1.5))
        chain(marks, [bulb + Vector((0.05, dy * 0.4, -0.55)), bulb + Vector((0.15, dy, -1.05)), tip], [0.04, 0.03, 0.02], 4)
        ellipsoid(marks, tip, (0.13, 0.13, 0.14), 1)

    # Barnacle clusters crusting the skull and back.
    for bx, by, bz in ((1.3, 1.4, zc + 1.9), (0.1, -1.7, zc + 1.6), (-1.6, 1.3, zc + 1.7), (2.7, -1.5, zc + 0.8), (-3.4, 0.7, zc + 1.2)):
        for dx, dy, r in ((0.0, 0.0, 0.34), (0.28, 0.12, 0.22), (-0.16, 0.24, 0.17)):
            revolve(body, [(0.0, r), (r * 0.7, r * 0.72), (r * 1.15, 0.0)], sides=6, axis="z", center=(bx + dx, by + dy, bz))

    # A broken harpoon lodged in its shoulder, a length of chain trailing off it.
    hbase = Vector((-1.2, 1.7, zc + 1.5))
    hdir = Vector((0.45, 0.5, 0.85)).normalized()
    limb(fins, hbase, hbase + hdir * 2.8, 0.13, 0.08, 5)
    for b in (-1, 1):
        side = Vector((0, b, 0)) * 0.35
        cone(fins, hbase + hdir * 0.6 + side, hbase + hdir * 0.2 + side * 1.6, 0.05, 4)
    link = hbase - hdir * 0.2
    for _ in range(4):
        nxt = link + Vector((0.0, 0.25, -0.4))
        limb(fins, link, nxt, 0.09, 0.09, 4)
        link = nxt

    # Glowing veins tracing the flanks back to the gills (marks).
    for s in (-1, 1):
        chain(
            marks,
            [(2.6, s * 1.95, zc + 0.1), (0.9, s * 2.2, zc + 0.4), (-1.2, s * 2.05, zc + 0.5), (-3.4, s * 1.5, zc + 0.4)],
            [0.05, 0.07, 0.06, 0.03],
            4,
        )

    return [
        finish("Leviathan_Body", body, MATS["Leviathan_Body"]),
        finish("Leviathan_Fins", fins, MATS["Leviathan_Fins"]),
        finish("Leviathan_Eyes", eyes, MATS["Leviathan_Eyes"]),
        finish("Leviathan_Marks", marks, MATS["Leviathan_Marks"]),
    ]


# ---------------------------------------------------------------- Old Gnashroot, the Fen Tyrant (island 2 boss)
# A moss-backed snapping turtle-gator: a broad fluted shell crusted with
# glowing fen-moss and wisp buds, a long gator snout with a hooked snapper
# beak, four stumpy clawed legs, a ridged tail. FLAT: lies belly-down,
# front +X. bbox: X ~15 > Y ~8 > Z ~4.2.


def build_gnashroot():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # The shell: a broad dome over a flat rim plate.
    dome(body, (-1.5, 0, 1.15), (4.2, 3.2, 2.2), 1)
    ellipsoid(body, (-1.5, 0, 1.05), (4.6, 3.6, 0.5), 1)
    # Scute plates ringing the rim, angled out like a saw edge.
    for k in range(10):
        a = (k / 10) * TAU
        px, py = -1.5 + math.cos(a) * 4.1, math.sin(a) * 3.2
        box(fins, (px, py, 1.35), (0.9, 0.55, 0.35), Matrix.Rotation(a, 4, "Z"))
    # A jagged ridge down the shell's crown.
    for i in range(4):
        box(fins, (0.4 - i * 1.3, 0, 3.15 - i * 0.12), (0.8, 0.4, 0.6), Matrix.Rotation(math.radians(35), 4, "Y"))

    # Gator head off the shell's front: broad snout, wider than tall.
    revolve(
        body,
        [(-0.6, 1.5), (0.8, 1.45), (2.2, 1.1), (3.4, 0.85), (4.2, 0.55), (4.6, 0.0)],
        sides=8,
        axis="x",
        center=(2.4, 0, 1.1),
        squash=0.72,
    )
    # The snapper beak: a hooked upper tip over an open lower jaw slab.
    cone(body, (6.7, 0, 1.35), (7.2, 0, 0.55), 0.4, 5)
    box(body, (5.2, 0, 0.35), (3.0, 1.7, 0.4), Matrix.Rotation(math.radians(-10), 4, "Y"))
    # Teeth up from the lower jaw and down from the snout.
    for i in range(4):
        x = 4.4 + i * 0.55
        for s in (-1, 1):
            cone(fins, (x, s * 0.75, 0.55), (x + 0.05, s * 0.72, 1.0), 0.09, 4)
            cone(fins, (x - 0.2, s * 0.8, 1.15), (x - 0.15, s * 0.78, 0.7), 0.09, 4)
    # Brow bosses over the eyes.
    for s in (-1, 1):
        ellipsoid(body, (3.3, s * 0.95, 1.75), (0.6, 0.35, 0.3), 1)
        ellipsoid(eyes, (3.5, s * 0.95, 1.6), (0.3, 0.22, 0.24), 1)

    # Four stumpy legs with claw toes.
    for lx, ly in ((1.4, 3.0), (1.4, -3.0), (-3.8, 2.9), (-3.8, -2.9)):
        s = 1 if ly > 0 else -1
        chain(body, [(lx, ly * 0.85, 1.0), (lx + 0.1, ly + s * 0.35, 0.7), (lx + 0.15, ly + s * 0.4, 0.25)], [0.75, 0.6, 0.55], 6)
        ellipsoid(body, (lx + 0.2, ly + s * 0.45, 0.22), (0.7, 0.6, 0.22), 1)
        for t in (-1, 0, 1):
            cone(fins, (lx + 0.55, ly + s * 0.45 + t * 0.35, 0.25), (lx + 1.0, ly + s * 0.5 + t * 0.45, 0.1), 0.11, 4)

    # The ridged tail, swinging slightly to port.
    tail = [(-5.4, 0, 1.0), (-6.6, 0.5, 0.85), (-7.6, 1.0, 0.6), (-8.3, 1.3, 0.35)]
    chain(body, tail, [0.9, 0.65, 0.4, 0.15], 6)
    for i, (tx, ty, tz) in enumerate(tail[:3]):
        box(fins, (tx, ty, tz + 0.65 - i * 0.1), (0.5, 0.3, 0.5), Matrix.Rotation(math.radians(40), 4, "Y"))

    # The fen-moss: glowing lichen mats on the shell and wisp buds on stalks
    # (the brood tell - lit when it calls the bog).
    for mx, my, r in ((-0.4, 1.6, 0.9), (-2.6, -1.2, 0.8), (-1.0, -2.0, 0.6), (-3.2, 1.4, 0.7)):
        ellipsoid(marks, (mx, my, 2.6 + 0.3 * (r - 0.6)), (r, r * 0.8, 0.25), 1)
    for wx, wy in ((-0.6, 0.4), (-2.4, 0.9), (-1.8, -0.9)):
        chain(fins, [(wx, wy, 3.1), (wx - 0.15, wy + 0.1, 3.85)], [0.08, 0.05], 4)
        ellipsoid(marks, (wx - 0.18, wy + 0.12, 4.0), (0.18, 0.18, 0.2), 1)
    # A glowing throat patch inside the open maw.
    ellipsoid(marks, (4.6, 0, 0.62), (0.8, 0.6, 0.2), 1)

    return [
        finish("Gnashroot_Body", body, MATS["Gnashroot_Body"]),
        finish("Gnashroot_Fins", fins, MATS["Gnashroot_Fins"]),
        finish("Gnashroot_Eyes", eyes, MATS["Gnashroot_Eyes"]),
        finish("Gnashroot_Marks", marks, MATS["Gnashroot_Marks"]),
    ]


# ---------------------------------------------------------------- Rimefang, the Glacier Serpent (island 3 boss)
# An ice serpent tunnelling in and out of the shelf: a long S-curved body,
# a frilled wedge head with two great icicle fangs, a crest of icicle spines
# down the spine, aurora veins along the flanks. FLAT: front +X.
# bbox: X ~17 > Y ~7 > Z ~4.6.


def build_rimefang():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # The body: an S-curve, thickest amidships, tapering to the tail.
    pts, radii = [], []
    n = 14
    for i in range(n):
        t = i / (n - 1)
        x = 7.6 - t * 16.0
        y = 2.1 * math.sin(t * math.pi * 1.7)
        z = 1.5 + 0.3 * math.cos(t * math.pi * 2.3)
        pts.append((x, y, z))
        radii.append(0.35 + 0.95 * math.sin(math.pi * min(max(t, 0.06), 0.94)))
    chain(body, pts, radii, 7)
    # Tail: a fluked icicle fan.
    plate(fins, [(-8.2, 1.9), (-9.6, 3.2), (-9.2, 1.8), (-10.0, 1.4), (-9.0, 0.9), (-9.4, -0.2), (-8.3, 0.9)], 0.25, "xz", offset=(0, pts[-1][1], 0))

    # The head: a faceted wedge with a frill behind it.
    revolve(
        body,
        [(-1.2, 1.25), (0.2, 1.15), (1.4, 0.85), (2.4, 0.5), (3.0, 0.0)],
        sides=8,
        axis="x",
        center=(8.4, 0, 1.6),
        squash=0.85,
    )
    # Frill: radiating icicle plates behind the skull.
    for ang in (-55, -25, 0, 25, 55):
        rot = Matrix.Rotation(math.radians(ang), 4, "X")
        box(fins, (7.0, math.sin(math.radians(ang)) * 1.6, 1.6 + math.cos(math.radians(ang)) * 1.5), (0.9, 0.35, 1.6), rot)
    # Jaw open, two great icicle fangs down, smaller teeth.
    box(body, (10.0, 0, 0.85), (2.2, 1.3, 0.35), Matrix.Rotation(math.radians(12), 4, "Y"))
    for s in (-1, 1):
        cone(fins, (10.6, s * 0.55, 1.35), (10.9, s * 0.6, 0.15), 0.2, 5)
        for i in range(3):
            cone(fins, (9.4 + i * 0.45, s * 0.6, 1.2), (9.5 + i * 0.45, s * 0.6, 0.7), 0.08, 4)
    for s in (-1, 1):
        ellipsoid(eyes, (9.3, s * 0.75, 2.05), (0.32, 0.2, 0.26), 1)

    # The crest: icicle spines down the spine, glowing at the tips.
    for i in range(1, n - 1, 2):
        px, py, pz = pts[i]
        r = radii[i]
        cone(fins, (px, py, pz + r * 0.8), (px - 0.25, py, pz + r + 1.5), 0.22, 4)
        cone(marks, (px - 0.18, py, pz + r + 0.95), (px - 0.25, py, pz + r + 1.5), 0.09, 4)
    # Belly plates: a keel of ice slabs under the forward arcs.
    for i in range(2, 9, 2):
        px, py, pz = pts[i]
        box(fins, (px, py, pz - radii[i] * 0.85), (1.0, 0.7, 0.3))

    # Aurora veins tracing both flanks.
    for s in (-1, 1):
        vein = [(pts[i][0], pts[i][1] + s * radii[i] * 0.9, pts[i][2] + 0.2) for i in range(1, n - 1, 3)]
        chain(marks, vein, [0.07] * len(vein), 4)
    # Frost-breath wisps curling off the nostrils.
    for s in (-1, 1):
        chain(marks, [(11.0, s * 0.3, 1.7), (11.5, s * 0.55, 2.0)], [0.06, 0.03], 4)

    return [
        finish("Rimefang_Body", body, MATS["Rimefang_Body"]),
        finish("Rimefang_Fins", fins, MATS["Rimefang_Fins"]),
        finish("Rimefang_Eyes", eyes, MATS["Rimefang_Eyes"]),
        finish("Rimefang_Marks", marks, MATS["Rimefang_Marks"]),
    ]


# ---------------------------------------------------------------- Pyrelisk, the Caldera Wyrm (island 4 boss)
# A magma serpent swimming the lava ponds: three arched coils breaking the
# surface (nothing like Rimefang's flat S), obsidian back-plates, magma
# cracks glowing down every arch, a horned wyrm skull with a molten maw.
# FLAT: front +X. bbox: X ~16 > Y ~5.4 > Z ~4.2.


def build_pyrelisk():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # The coils: humps arch out of the lava, dipping between.
    pts, radii = [], []
    n = 16
    for i in range(n):
        t = i / (n - 1)
        x = 7.0 - t * 14.8
        y = 1.15 * math.sin(t * math.pi * 2.0)
        z = 0.8 + 1.45 * abs(math.sin(t * math.pi * 2.55 + 0.25))
        pts.append((x, y, z))
        radii.append(0.3 + 0.9 * math.sin(math.pi * min(max(t, 0.05), 0.95)))
    chain(body, pts, radii, 7)
    cone(body, pts[-1], (pts[-1][0] - 1.2, pts[-1][1] - 0.4, 0.5), radii[-1], 5)

    # Obsidian back-plates riding each arch crest.
    for i in range(1, n - 1):
        px, py, pz = pts[i]
        if pz > 1.7:  # only where the coil is out of the lava
            box(fins, (px, py, pz + radii[i] * 0.85), (0.55, 0.25, 0.8), Matrix.Rotation(math.radians(30), 4, "Y"))
    # Magma cracks: glowing seams down every out-of-lava arch.
    for s in (-1, 1):
        seam = [(pts[i][0], pts[i][1] + s * radii[i] * 0.75, pts[i][2] + 0.25) for i in range(1, n - 1, 2) if pts[i][2] > 1.4]
        if len(seam) > 1:
            chain(marks, seam, [0.09] * len(seam), 4)
    # A molten underglow where each hump meets the lava line.
    for i in range(1, n - 1, 3):
        px, py, pz = pts[i]
        ellipsoid(marks, (px, py, max(pz - radii[i] * 0.8, 0.5)), (0.5, 0.35, 0.15), 1)

    # The skull: a horned wedge, maw hung open and glowing.
    revolve(
        body,
        [(-1.0, 1.15), (0.4, 1.05), (1.6, 0.8), (2.6, 0.45), (3.1, 0.0)],
        sides=8,
        axis="x",
        center=(7.6, 0, 1.75),
        squash=0.9,
    )
    box(body, (9.4, 0, 0.9), (2.4, 1.2, 0.35), Matrix.Rotation(math.radians(14), 4, "Y"))
    ellipsoid(marks, (9.2, 0, 1.15), (1.0, 0.55, 0.25), 1)  # the molten throat
    # Swept obsidian horns and jaw hooks.
    for s in (-1, 1):
        chain(fins, [(7.2, s * 0.8, 2.6), (6.4, s * 1.3, 3.5), (5.6, s * 1.5, 3.9)], [0.28, 0.17, 0.06], 5)
        cone(fins, (9.8, s * 0.6, 1.3), (10.1, s * 0.65, 0.55), 0.16, 4)
        for i in range(3):
            cone(fins, (8.6 + i * 0.4, s * 0.55, 1.25), (8.7 + i * 0.4, s * 0.55, 0.8), 0.08, 4)
        ellipsoid(eyes, (8.5, s * 0.7, 2.15), (0.3, 0.2, 0.24), 1)

    return [
        finish("Pyrelisk_Body", body, MATS["Pyrelisk_Body"]),
        finish("Pyrelisk_Fins", fins, MATS["Pyrelisk_Fins"]),
        finish("Pyrelisk_Eyes", eyes, MATS["Pyrelisk_Eyes"]),
        finish("Pyrelisk_Marks", marks, MATS["Pyrelisk_Marks"]),
    ]


# ---------------------------------------------------------------- Noctyss, the Trench Mother (island 5 boss)
# An abyssal angler-queen: a deep-bodied silhouette hung with a skirt of
# tendrils, a maw of needle fangs, ragged dorsal spine-rays, and one long
# lure arcing overhead - the only light in her arena. Her marks are that
# lure, its beads and her photophores (doused between attacks when she
# enrages). UPRIGHT (stance): Z-up, front +X. ~13 long, ~9.5 tall.


def build_noctyss():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    zc = 4.6  # body axis height - she hangs in the dark

    # Deep keeled body, blunter than the Leviathan, fattest forward.
    revolve(
        body,
        [(-4.6, 0.0), (-3.6, 0.9), (-2.2, 1.7), (-0.4, 2.3), (1.4, 2.5), (2.8, 2.2), (3.8, 1.5), (4.4, 0.6), (4.6, 0.0)],
        sides=9,
        axis="x",
        center=(0, 0, zc),
        squash=1.35,
        phase=TAU / 18,
    )

    # The maw: a hung-open jaw and two rows of NEEDLE fangs, longer than any
    # other creature's.
    jaw_rot = Matrix.Rotation(math.radians(22), 4, "Y")
    box(body, (3.5, 0, zc - 2.5), (3.2, 2.6, 0.5), jaw_rot)
    for i in range(7):
        y = -1.2 + i * 0.4
        x = 4.5 - abs(y) * 0.4
        cone(fins, (x, y, zc - 0.5), (x + 0.25, y, zc - 2.1), 0.09, 4)
    for i in range(6):
        y = -1.0 + i * 0.4
        x = 4.3 - abs(y) * 0.35
        cone(fins, (x, y, zc - 2.3), (x + 0.3, y, zc - 0.7), 0.08, 4)

    # Ragged dorsal spine-rays with torn membrane between the first pair.
    rays = [((0.8, zc + 2.6), (0.2, zc + 5.2)), ((-0.6, zc + 2.7), (-1.6, zc + 5.6)), ((-2.0, zc + 2.4), (-3.4, zc + 5.0)), ((-3.4, zc + 1.8), (-4.8, zc + 3.8))]
    for (bx, bz), (tx, tz) in rays:
        limb(fins, (bx, 0, bz), (tx, 0, tz), 0.16, 0.04, 4)
    plate(fins, [(0.8, zc + 2.6), (0.2, zc + 5.0), (-1.2, zc + 3.6), (-1.6, zc + 5.4), (-3.0, zc + 3.4), (-3.4, zc + 4.8), (-4.4, zc + 2.4), (-3.6, zc + 1.6)], 0.18, "xz")

    # The skirt: tendrils hanging from the belly line, drifting aft.
    for k in range(7):
        y = -1.5 + k * 0.5
        x0 = 1.2 - abs(y) * 0.8
        chain(fins, [(x0, y, zc - 2.6), (x0 - 0.5, y * 1.25, zc - 4.0), (x0 - 1.1, y * 1.4, 0.5)], [0.16, 0.1, 0.04], 4)

    # Pectorals: small, ragged - she drifts, she doesn't swim fast.
    for s in (-1, 1):
        plate(fins, [(0.4, s * 2.4), (-1.4, s * 3.8), (-2.6, s * 3.4), (-1.6, s * 2.4)], 0.2, "xy", offset=(0, 0, zc - 0.6))
    # Tail: a ragged half-fan.
    plate(fins, [(-4.4, zc + 0.6), (-6.4, zc + 1.9), (-5.8, zc + 0.4), (-6.6, zc - 0.9), (-5.4, zc - 0.6), (-4.5, zc - 0.7)], 0.22, "xz")

    # THE LURE: a long stalk off the brow, arcing right over her head, ending
    # in the bulb that is the arena's only light - caged in bone ribs, beads
    # trailing under it.
    chain(fins, [(2.8, 0, zc + 2.3), (4.0, 0, zc + 4.4), (6.2, 0, zc + 5.1), (7.9, 0, zc + 4.3)], [0.24, 0.17, 0.12, 0.09], 5)
    bulb = Vector((8.0, 0, zc + 3.4))
    ellipsoid(marks, bulb, (0.85, 0.85, 0.95), 1)
    for k in range(4):
        a = (k / 4) * TAU + 0.4
        off = Vector((0, math.cos(a), math.sin(a)))
        chain(fins, [bulb + Vector((-0.7, 0, 0)) + off * 0.3, bulb + off * 1.0, bulb + Vector((0.7, 0, 0)) + off * 0.3], [0.06, 0.07, 0.06], 4)
    for dy in (-0.5, 0.0, 0.5):
        tip = bulb + Vector((0.3, dy, -2.0))
        chain(marks, [bulb + Vector((0.1, dy * 0.4, -0.8)), tip], [0.05, 0.02], 4)
        ellipsoid(marks, tip, (0.16, 0.16, 0.18), 1)

    # Photophores: dotted rows along both flanks (doused on enrage).
    for s in (-1, 1):
        for i in range(6):
            x = 2.6 - i * 1.15
            ellipsoid(marks, (x, s * (2.3 - abs(x) * 0.12), zc - 0.9), (0.14, 0.14, 0.14), 0)

    # Eyes: small, pale, nearly blind - the lure does the seeing.
    for s in (-1, 1):
        ellipsoid(eyes, (3.3, s * 1.5, zc + 1.0), (0.3, 0.2, 0.26), 1)

    return [
        finish("Noctyss_Body", body, MATS["Noctyss_Body"]),
        finish("Noctyss_Fins", fins, MATS["Noctyss_Fins"]),
        finish("Noctyss_Eyes", eyes, MATS["Noctyss_Eyes"]),
        finish("Noctyss_Marks", marks, MATS["Noctyss_Marks"]),
    ]


# ---------------------------------------------------------------- Admiral Wrack, the Fleet-Eater (island 6 boss)
# A drowned admiral fused into his flagship's bow: a hull-wedge base with a
# prow, a great-coated torso rising through the deck, bicorne hat, cutlass
# arm and an anchor-and-chain arm, a mast with a ragged spectral sail.
# UPRIGHT (stance): Z-up, front +X. ~11 long, ~8.5 tall.


def build_admiralwrack():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # The hull wedge: side profile extruded across the beam, plus a raked
    # prow blade and a deck he bursts through.
    plate(body, [(5.2, 2.6), (4.0, 0.6), (-3.6, 0.2), (-3.8, 2.8), (0.5, 3.2)], 4.4, "xz")
    plate(body, [(6.6, 3.6), (5.6, 3.2), (3.8, 0.9), (4.9, 1.0)], 0.5, "xz")
    box(body, (0.3, 0, 3.1), (7.4, 4.6, 0.5), Matrix.Rotation(math.radians(-4), 4, "Y"))
    # Plank seams (fins - the spectral parts pick out the wreck's bones).
    for i in range(3):
        box(fins, (0.4 - i * 0.2, 0, 1.0 + i * 0.75), (7.6 - i * 0.6, 4.7, 0.12))

    # The torso: greatcoat, shoulders, skull, bicorne.
    box(body, (-0.4, 0, 4.9), (2.6, 3.2, 2.8), Matrix.Rotation(math.radians(-6), 4, "Y"))
    box(body, (-0.5, 0, 3.6), (3.2, 3.8, 1.0))  # coat skirt flaring at the deck
    for s in (-1, 1):
        ellipsoid(body, (-0.4, s * 1.9, 6.1), (0.9, 0.75, 0.7), 1)
        box(fins, (-0.4, s * 1.95, 6.55), (1.1, 0.7, 0.18))  # epaulettes
        for k in range(3):
            cone(fins, (-0.4, s * (2.1 + k * 0.12), 6.45), (-0.4, s * (2.25 + k * 0.12), 6.0), 0.05, 4)
    box(body, (-0.3, 0, 7.0), (1.3, 1.2, 1.4))  # the skull
    # Bicorne: a crescent worn athwart.
    box(body, (-0.3, 0, 7.9), (0.55, 2.6, 0.8))
    for s in (-1, 1):
        box(body, (-0.3, s * 1.5, 7.65), (0.5, 1.0, 0.6), Matrix.Rotation(math.radians(s * -28), 4, "X"))
    # Sunken glowing eye sockets, and a jaw gap.
    for s in (-1, 1):
        ellipsoid(eyes, (0.32, s * 0.3, 7.1), (0.14, 0.18, 0.2), 1)
    box(fins, (0.25, 0, 6.6), (0.5, 0.7, 0.14))

    # Cutlass arm (starboard): shoulder -> hand, then the blade.
    chain(body, [(-0.4, 1.9, 5.6), (0.8, 2.7, 5.1), (1.8, 2.5, 5.5)], [0.5, 0.38, 0.3], 5)
    plate(fins, [(1.9, 5.3), (4.7, 6.1), (5.0, 5.7), (2.1, 4.7)], 0.16, "xz", offset=(0, 2.5, 0))
    box(fins, (1.85, 2.5, 5.3), (0.3, 0.5, 0.5))
    # Anchor arm (port): hand low, chain links down to the anchor.
    chain(body, [(-0.4, -1.9, 5.6), (0.5, -2.8, 4.5), (1.0, -2.6, 3.7)], [0.5, 0.38, 0.3], 5)
    link = Vector((1.1, -2.6, 3.4))
    for k in range(4):
        nxt = link + Vector((0.12, 0.05 if k % 2 else -0.05, -0.55))
        limb(fins, link, nxt, 0.09, 0.09, 4)
        link = nxt
    limb(fins, (link.x, link.y, link.z + 0.1), (link.x, link.y, link.z - 1.0), 0.14, 0.1, 5)
    box(fins, (link.x, link.y, link.z - 0.15), (0.7, 0.16, 0.16))
    for s in (-1, 1):
        chain(fins, [(link.x, link.y + s * 0.1, link.z - 1.0), (link.x + 0.5, link.y + s * 0.55, link.z - 0.6)], [0.12, 0.03], 4)

    # The mast behind him, a yard and a ragged spectral sail.
    limb(body, (-2.8, 0, 3.2), (-2.8, 0, 8.6), 0.26, 0.18, 6)
    limb(body, (-2.8, -2.1, 7.4), (-2.8, 2.1, 7.4), 0.14, 0.14, 5)
    box(fins, (-2.8, 0, 6.1), (0.14, 3.8, 2.2))
    for k in range(4):
        y = -1.5 + k * 1.0
        box(fins, (-2.8, y, 4.6), (0.12, 0.5, 1.1), Matrix.Rotation(math.radians(10 - k * 6), 4, "X"))

    # Marks: the ghost-fire - a chest wound, a prow lantern on a hook, glow
    # lines along the hull seam, rigging threads to the masthead.
    ellipsoid(marks, (0.75, 0.4, 5.2), (0.4, 0.5, 0.6), 1)
    chain(fins, [(6.4, 0, 3.5), (6.9, 0, 3.1)], [0.06, 0.04], 4)
    ellipsoid(marks, (6.95, 0, 2.8), (0.28, 0.28, 0.34), 1)
    box(marks, (0.5, 0, 2.55), (8.2, 0.1, 0.1))
    chain(marks, [(-2.8, 0, 8.55), (1.5, 0, 6.2), (6.4, 0, 3.6)], [0.04, 0.04, 0.03], 4)

    return [
        finish("AdmiralWrack_Body", body, MATS["AdmiralWrack_Body"]),
        finish("AdmiralWrack_Fins", fins, MATS["AdmiralWrack_Fins"]),
        finish("AdmiralWrack_Eyes", eyes, MATS["AdmiralWrack_Eyes"]),
        finish("AdmiralWrack_Marks", marks, MATS["AdmiralWrack_Marks"]),
    ]


# ---------------------------------------------------------------- The Kraken, Maw of the Maelstrom (final boss head)
# The head/mantle only - the fightable tentacles are separate KrakenTentacle
# creatures spawned by the boss's `parts` field. A towering mantle leaning
# aft, huge baleful eyes, a beak maw between a crown of eight SHORT tentacle
# stubs (the stumps of the real ones), storm veins crawling the mantle.
# UPRIGHT (stance): Z-up, front +X. ~15 across the stubs, ~11 tall.


def build_kraken():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # The mantle: a swept bell about Z, leaning aft.
    rings = revolve(
        body,
        [(0.0, 4.6), (2.2, 4.9), (4.4, 4.3), (6.6, 3.1), (8.4, 1.7), (10.4, 0.0)],
        sides=10,
        axis="z",
        center=(-1.2, 0, 0),
        squash=0.92,
    )
    # Lean the upper mantle back (-x) so the silhouette isn't a plain cone.
    for ring in rings[2:]:
        vs = ring if isinstance(ring, list) else [ring]
        for v in vs:
            v.co.x -= (v.co.z - 4.4) * 0.28
    # A ragged crest plate up the mantle's back.
    plate(fins, [(-4.6, 4.0), (-6.2, 6.4), (-5.2, 6.2), (-6.6, 8.6), (-5.0, 7.9), (-4.6, 9.4), (-3.6, 8.2), (-3.2, 5.0)], 0.3, "xz")

    # The crown of stubs: eight short curling tentacle stumps around the
    # front half of the base - the REAL tentacles fight as their own rows.
    for k in range(8):
        a = math.radians(-115 + k * 33)
        bx, by = -1.2 + math.cos(a) * 3.9, math.sin(a) * 4.3
        dx, dy = math.cos(a), math.sin(a)
        p0 = (bx, by, 0.8)
        p1 = (bx + dx * 2.2, by + dy * 2.4, 0.9)
        p2 = (bx + dx * 3.6, by + dy * 3.8, 2.0)
        p3 = (bx + dx * 4.0, by + dy * 4.2, 3.4)
        chain(body, [p0, p1, p2, p3], [1.05, 0.75, 0.45, 0.16], 6)
        # Sucker dots up the stub's inner face.
        if k % 2 == 0:
            for p, r in ((p1, 0.2), (p2, 0.16)):
                ellipsoid(marks, (p[0] - dx * 0.5, p[1] - dy * 0.5, p[2] + 0.5), (r, r, r), 0)

    # The beak: two dark hooked halves in the maw between the front stubs,
    # over a glowing throat.
    cone(fins, (3.2, 0, 2.6), (4.6, 0, 1.5), 0.75, 6)
    cone(fins, (3.0, 0, 0.9), (4.3, 0, 1.9), 0.65, 6)
    ellipsoid(marks, (2.6, 0, 1.8), (1.0, 1.3, 0.9), 1)

    # The eyes: huge, gold, slanted forward under a heavy lid ridge.
    for s in (-1, 1):
        ellipsoid(eyes, (1.9, s * 3.6, 3.6), (1.0, 0.55, 0.8), 1)
        box(body, (2.0, s * 3.7, 4.5), (1.6, 0.9, 0.5), Matrix.Rotation(math.radians(s * 18), 4, "X"))

    # Storm veins crawling the mantle, and a glowing band where mantle meets
    # the crown.
    for s in (-1, 1):
        chain(marks, [(0.8, s * 3.4, 5.2), (-0.6, s * 3.0, 7.0), (-2.4, s * 2.0, 8.6)], [0.09, 0.07, 0.04], 4)
    chain(marks, [(2.8, -1.4, 5.4), (3.2, 0, 6.2), (2.8, 1.4, 5.4)], [0.06, 0.08, 0.06], 4)

    return [
        finish("Kraken_Body", body, MATS["Kraken_Body"]),
        finish("Kraken_Fins", fins, MATS["Kraken_Fins"]),
        finish("Kraken_Eyes", eyes, MATS["Kraken_Eyes"]),
        finish("Kraken_Marks", marks, MATS["Kraken_Marks"]),
    ]


# ---------------------------------------------------------------- Kraken Tentacle (boss part)
# One planted tentacle: rises from a broad base, curls over toward +X (the
# player) with a hooked tip, barbs down the outer edge, sucker dots up the
# inner face. No eyes - CreatureModel only requires _Body. UPRIGHT (stance).
# ~9.5 tall.


def build_kraken_tentacle():
    body = bmesh.new()
    fins = bmesh.new()
    marks = bmesh.new()

    path = [(0, 0, 0.0), (0.15, 0, 2.0), (0.5, 0, 4.0), (1.3, 0.2, 5.9), (2.5, 0.3, 7.2), (3.8, 0.15, 7.8), (4.7, 0, 7.3)]
    radii = [1.5, 1.2, 1.0, 0.8, 0.6, 0.38, 0.14]
    chain(body, path, radii, 7)
    # The base flare: a ring of root knuckles where it erupts.
    for k in range(6):
        a = (k / 6) * TAU
        cone(body, (math.cos(a) * 1.3, math.sin(a) * 1.3, 0.3), (math.cos(a) * 2.1, math.sin(a) * 2.1, 0.05), 0.4, 5)

    # Barbs down the outer (-x) edge of the curl.
    for i in range(1, 6):
        px, py, pz = path[i]
        r = radii[i]
        cone(fins, (px - r * 0.8, py, pz), (px - r * 0.8 - 0.7, py, pz + 0.25), 0.14, 4)
    # The hooked tip.
    cone(fins, path[-1], (5.3, 0, 6.5), 0.16, 5)

    # Sucker dots up the inner (+x) face, glowing storm-teal.
    for i in range(1, 6):
        px, py, pz = path[i]
        r = radii[i]
        for dy in (-0.3, 0.3):
            ellipsoid(marks, (px + r * 0.75, py + dy * r, pz + 0.3), (0.16, 0.16, 0.16), 0)

    return [
        finish("KrakenTentacle_Body", body, MATS["KrakenTentacle_Body"]),
        finish("KrakenTentacle_Fins", fins, MATS["KrakenTentacle_Fins"]),
        finish("KrakenTentacle_Marks", marks, MATS["KrakenTentacle_Marks"]),
    ]


# ---------------------------------------------------------------- the flyers
# The new `flyer` archetype's rosters: small airborne mobs. All authored
# facing +X like everything else; the winged ones keep the flat x>y>z rule
# (wings swept BACK so span stays inside length), the hoverers (wisp,
# wraith) are upright-stance shapes.


# ---- Bog Gull (swamp, dive-bomber): a scruffy fen gull - dumpy body, mud-
# stained swept wings, a hooked beak, feet tucked for the dive.
def build_boggull():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    ellipsoid(body, (0, 0, 1.2), (1.15, 0.55, 0.5), 1)
    ellipsoid(body, (1.25, 0, 1.5), (0.45, 0.35, 0.35), 1)
    cone(body, (1.6, 0, 1.5), (2.3, 0, 1.42), 0.14, 5)
    cone(fins, (2.25, 0, 1.44), (2.4, 0, 1.25), 0.07, 4)  # the hook
    # Swept-back wings, mud-brown.
    for s in (-1, 1):
        plate(fins, [(0.5, s * 0.45), (-0.7, s * 1.8), (-2.3, s * 2.05), (-1.5, s * 0.9), (-0.4, s * 0.45)], 0.12, "xy", offset=(0, 0, 1.45))
    # Tail fan and tucked feet.
    plate(fins, [(-1.0, 0.35), (-2.0, 0.5), (-2.1, -0.5), (-1.0, -0.35)], 0.1, "xy", offset=(0, 0, 1.25))
    for s in (-1, 1):
        cone(body, (0.2, s * 0.2, 0.75), (0.55, s * 0.25, 0.55), 0.1, 4)
    # Bog streaks down the wings.
    for s in (-1, 1):
        box(marks, (-1.1, s * 1.3, 1.53), (0.7, 0.25, 0.05), Matrix.Rotation(math.radians(s * -35), 4, "Z"))
    for s in (-1, 1):
        ellipsoid(eyes, (1.45, s * 0.22, 1.62), (0.09, 0.07, 0.09), 0)

    return [
        finish("BogGull_Body", body, MATS["BogGull_Body"]),
        finish("BogGull_Fins", fins, MATS["BogGull_Fins"]),
        finish("BogGull_Eyes", eyes, MATS["BogGull_Eyes"]),
        finish("BogGull_Marks", marks, MATS["BogGull_Marks"]),
    ]


# ---- Will-o-Wisp (swamp): a hovering fen-light - a glowing core wrapped in
# pale flame licks, trailing tendrils below. Upright-stance hoverer.
def build_willowisp():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    ellipsoid(marks, (0, 0, 1.7), (0.55, 0.55, 0.6), 1)  # the core
    # Flame licks curling up around it.
    for k in range(5):
        a = (k / 5) * TAU
        bx, by = math.cos(a) * 0.5, math.sin(a) * 0.5
        cone(body, (bx, by, 1.3), (bx * 1.5, by * 1.5, 2.4 + 0.25 * math.sin(a * 2)), 0.22, 4)
    cone(body, (0, 0, 2.1), (0.1, 0, 2.9), 0.28, 5)
    # Trailing tendrils drifting beneath.
    for k in range(3):
        a = (k / 3) * TAU + 0.5
        bx, by = math.cos(a) * 0.3, math.sin(a) * 0.3
        chain(fins, [(bx, by, 1.2), (bx * 2.2, by * 2.2, 0.6), (bx * 2.8, by * 2.8, 0.15)], [0.1, 0.06, 0.02], 4)
    # A hinted face: two dark sockets in the glow.
    for s in (-1, 1):
        ellipsoid(eyes, (0.42, s * 0.18, 1.85), (0.1, 0.09, 0.13), 0)

    return [
        finish("WillOWisp_Body", body, MATS["WillOWisp_Body"]),
        finish("WillOWisp_Fins", fins, MATS["WillOWisp_Fins"]),
        finish("WillOWisp_Eyes", eyes, MATS["WillOWisp_Eyes"]),
        finish("WillOWisp_Marks", marks, MATS["WillOWisp_Marks"]),
    ]


# ---- Dread Dragonfly (swamp): a long dark darner with two wing pairs, huge
# glowing eyes and a dread-lit abdomen - the glow is its dive tell.
def build_dreaddragonfly():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    revolve(body, [(-1.6, 0.0), (-0.9, 0.2), (0.2, 0.32), (1.1, 0.42), (1.9, 0.28), (2.3, 0.0)], sides=7, axis="x", center=(0, 0, 1.4))
    # The abdomen: a thin tail with glowing segment rings.
    limb(body, (-1.5, 0, 1.4), (-3.1, 0, 1.32), 0.16, 0.08, 5)
    for i in range(3):
        x = -1.9 - i * 0.45
        limb(marks, (x, 0, 1.38 - i * 0.02), (x + 0.12, 0, 1.38 - i * 0.02), 0.14 - i * 0.02, 0.14 - i * 0.02, 6)
    # Two wing pairs, hind pair swept further back.
    for s in (-1, 1):
        plate(fins, [(0.9, s * 0.3), (0.7, s * 1.95), (0.1, s * 2.05), (0.3, s * 0.3)], 0.06, "xy", offset=(0, 0, 1.62))
        plate(fins, [(0.1, s * 0.3), (-0.3, s * 1.85), (-0.9, s * 1.9), (-0.5, s * 0.3)], 0.06, "xy", offset=(0, 0, 1.56))
    # The eyes: two big glowing orbs that ARE the head's silhouette.
    for s in (-1, 1):
        ellipsoid(eyes, (2.0, s * 0.26, 1.55), (0.3, 0.24, 0.28), 1)
    # Mandibles.
    for s in (-1, 1):
        cone(body, (2.3, s * 0.12, 1.25), (2.55, s * 0.2, 1.15), 0.06, 4)

    return [
        finish("DreadDragonfly_Body", body, MATS["DreadDragonfly_Body"]),
        finish("DreadDragonfly_Fins", fins, MATS["DreadDragonfly_Fins"]),
        finish("DreadDragonfly_Eyes", eyes, MATS["DreadDragonfly_Eyes"]),
        finish("DreadDragonfly_Marks", marks, MATS["DreadDragonfly_Marks"]),
    ]


# ---- Hailfin Skua (ice): a lean pale seabird with long slate wings, a
# forked tail and ice-streaked leading edges. Faster silhouette than the
# gull: everything longer and sharper.
def build_hailfinskua():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    ellipsoid(body, (0, 0, 1.3), (1.35, 0.48, 0.42), 1)
    ellipsoid(body, (1.5, 0, 1.55), (0.4, 0.3, 0.3), 1)
    cone(body, (1.85, 0, 1.55), (2.6, 0, 1.5), 0.11, 5)
    # Long narrow wings, sharply swept.
    for s in (-1, 1):
        plate(fins, [(0.7, s * 0.4), (-0.5, s * 1.7), (-2.6, s * 2.3), (-2.0, s * 1.0), (-0.3, s * 0.4)], 0.1, "xy", offset=(0, 0, 1.5))
    # Forked tail.
    for s in (-1, 1):
        plate(fins, [(-1.2, s * 0.1), (-2.6, s * 0.45), (-2.3, s * 0.05)], 0.08, "xy", offset=(0, 0, 1.35))
    # Ice streaks along each wing's leading edge.
    for s in (-1, 1):
        box(marks, (0.0, s * 1.1, 1.58), (1.1, 0.14, 0.05), Matrix.Rotation(math.radians(s * -28), 4, "Z"))
    for s in (-1, 1):
        ellipsoid(eyes, (1.68, s * 0.2, 1.66), (0.08, 0.07, 0.08), 0)

    return [
        finish("HailfinSkua_Body", body, MATS["HailfinSkua_Body"]),
        finish("HailfinSkua_Fins", fins, MATS["HailfinSkua_Fins"]),
        finish("HailfinSkua_Eyes", eyes, MATS["HailfinSkua_Eyes"]),
        finish("HailfinSkua_Marks", marks, MATS["HailfinSkua_Marks"]),
    ]


# ---- Rigging Wraith (wreck): drowned sailcloth given a shape - a hooded
# shroud, two ragged canvas wings, rope-end talons, ghost-fire eyes.
# Upright-stance hoverer.
def build_riggingwraith():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # The shroud: a draped cone rising to a hood peak, hem torn into points.
    revolve(body, [(0.0, 1.05), (0.9, 0.92), (1.8, 0.55), (2.5, 0.18)], sides=8, axis="z", center=(0, 0, 0.9))
    cone(body, (0, 0, 3.35), (0.15, 0, 3.85), 0.2, 5)
    for k in range(7):
        a = (k / 7) * TAU
        bx, by = math.cos(a) * 0.95, math.sin(a) * 0.95
        cone(fins, (bx, by, 1.0), (bx * 1.15, by * 1.15, 0.35), 0.16, 4)
    # Ragged canvas wings.
    for s in (-1, 1):
        plate(fins, [(0.2, s * 0.7), (-0.5, s * 2.3), (-1.8, s * 2.7), (-1.2, s * 1.6), (-1.6, s * 1.0), (-0.6, s * 0.7)], 0.1, "xy", offset=(0, 0, 2.6))
    # Rope-end talons swinging under the hem.
    for s in (-1, 1):
        chain(fins, [(0.5, s * 0.4, 0.8), (0.8, s * 0.55, 0.2), (1.1, s * 0.5, -0.1)], [0.08, 0.06, 0.03], 4)
        cone(fins, (1.1, s * 0.5, -0.1), (1.35, s * 0.45, -0.25), 0.06, 4)
    # Ghost-fire eyes in the hood's shadow, and glowing seams down the shroud.
    for s in (-1, 1):
        ellipsoid(eyes, (0.62, s * 0.28, 2.75), (0.14, 0.12, 0.17), 0)
    for a in (0.7, 2.6, 4.5):
        bx, by = math.cos(a), math.sin(a)
        chain(marks, [(bx * 0.85, by * 0.85, 1.2), (bx * 0.6, by * 0.6, 2.2), (bx * 0.3, by * 0.3, 3.1)], [0.05, 0.04, 0.03], 4)

    return [
        finish("RiggingWraith_Body", body, MATS["RiggingWraith_Body"]),
        finish("RiggingWraith_Fins", fins, MATS["RiggingWraith_Fins"]),
        finish("RiggingWraith_Eyes", eyes, MATS["RiggingWraith_Eyes"]),
        finish("RiggingWraith_Marks", marks, MATS["RiggingWraith_Marks"]),
    ]


# ---- Stormpetrel (maelstrom): a storm-dark petrel with long angular wings
# and lightning crawling their undersides.
def build_stormpetrel():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    ellipsoid(body, (0, 0, 1.3), (1.1, 0.45, 0.42), 1)
    ellipsoid(body, (1.2, 0, 1.5), (0.38, 0.3, 0.3), 1)
    cone(body, (1.5, 0, 1.5), (2.1, 0, 1.46), 0.1, 5)
    # Long angular wings with a marked elbow crank.
    for s in (-1, 1):
        plate(fins, [(0.5, s * 0.4), (0.2, s * 1.3), (-1.2, s * 1.9), (-2.5, s * 2.05), (-1.4, s * 1.0), (-0.3, s * 0.4)], 0.1, "xy", offset=(0, 0, 1.48))
    plate(fins, [(-0.9, 0.3), (-1.9, 0.4), (-1.9, -0.4), (-0.9, -0.3)], 0.09, "xy", offset=(0, 0, 1.3))
    # Lightning: jagged strokes under each wing.
    for s in (-1, 1):
        box(marks, (-0.5, s * 1.3, 1.42), (0.5, 0.08, 0.05), Matrix.Rotation(math.radians(s * -30), 4, "Z"))
        box(marks, (-1.1, s * 1.75, 1.42), (0.45, 0.08, 0.05), Matrix.Rotation(math.radians(s * 25), 4, "Z"))
    for s in (-1, 1):
        ellipsoid(eyes, (1.4, s * 0.2, 1.6), (0.08, 0.07, 0.08), 0)

    return [
        finish("Stormpetrel_Body", body, MATS["Stormpetrel_Body"]),
        finish("Stormpetrel_Fins", fins, MATS["Stormpetrel_Fins"]),
        finish("Stormpetrel_Eyes", eyes, MATS["Stormpetrel_Eyes"]),
        finish("Stormpetrel_Marks", marks, MATS["Stormpetrel_Marks"]),
    ]


def report_bbox(name, objs, expect_flat):
    """Print the built bounding box so the orientation rules can be checked
    without a Studio round-trip (the fish_gen.py puffer trick)."""
    lo = Vector((math.inf, math.inf, math.inf))
    hi = Vector((-math.inf, -math.inf, -math.inf))
    for obj in objs:
        for v in obj.data.vertices:
            lo = Vector((min(lo.x, v.co.x), min(lo.y, v.co.y), min(lo.z, v.co.z)))
            hi = Vector((max(hi.x, v.co.x), max(hi.y, v.co.y), max(hi.z, v.co.z)))
    size = hi - lo
    verdict = ""
    if expect_flat:
        ok = size.x > size.y > size.z
        verdict = "OK (x>y>z, lies belly-down facing +x)" if ok else "BAD - flatOrientation will mis-lay it"
    else:
        verdict = "upright (stance)"
    print(f"[creatures_gen] {name}: x {size.x:.2f} / y {size.y:.2f} / z {size.z:.2f} -> {verdict}")


# ---------------------------------------------------------------- preview


def render_preview(groups, out_png):
    scene = bpy.context.scene
    # The `hasattr(bpy.types, "SceneEEVEE")` probe misdetects on Blender 5.2
    # (same fix as rod_gen.py / weapon_gen.py): try the modern id, fall back.
    try:
        scene.render.engine = "BLENDER_EEVEE_NEXT"
    except TypeError:
        scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 2000
    scene.render.resolution_y = 1300
    scene.render.filepath = out_png

    world = bpy.data.worlds.new("W")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.42, 0.45, 0.5, 1)
    scene.world = world
    scene.view_settings.view_transform = "Standard"

    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.data.energy = 3.0
    sun.rotation_euler = (math.radians(52), math.radians(12), math.radians(40))
    bpy.context.collection.objects.link(sun)

    # A grid: rows along Y, deeper rows shifted +X. They face -X after the
    # export flip, so the camera sits on the -X side, raised, to see their
    # fronts and tops; the back rows sit higher in frame.
    # Roomy on purpose: the Leviathan is 17 studs long against a 3-stud crab,
    # and at tighter spacing it swallowed whichever creature stood behind it.
    spacing = 7.0
    per_row = 5
    row_depth = 9.0
    rows = (len(groups) + per_row - 1) // per_row
    for i, objs in enumerate(groups):
        row = i // per_row
        col = i % per_row
        count = min(per_row, len(groups) - row * per_row)
        y = (col - (count - 1) / 2) * spacing
        x = row * row_depth
        for obj in objs:
            obj.location.y += y
            obj.location.x += x

    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    bpy.context.collection.objects.link(cam)
    scene.camera = cam
    # Pull back with the roster: the framing was fixed when there were twelve
    # creatures, and every new one pushed something out of shot. Distance and
    # height now scale off the grid so the pack stays fully in frame.
    centre_x = (rows - 1) * row_depth / 2
    # Fit what is actually on screen, not a full grid: an `only=` subset leaves
    # empty columns, and measuring the nominal grid pushed the camera so far
    # back the creatures were too small to judge.
    cols = min(per_row, len(groups))
    span = max(cols * spacing, rows * row_depth * 0.8)
    cam.location = Vector((centre_x - (6.0 + span * 1.05), -6.0, 8.0 + rows * 2.4))
    target = Vector((centre_x + 1.0, 0.0, 1.0))
    cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
    cam.data.lens = 40

    bpy.ops.render.render(write_still=True)
    print("[creatures_gen] preview ->", out_png)


# ---------------------------------------------------------------- export

MATS = {}

# (name, builder, lies flat?) - order is the preview order: the eight enemies
# fill the front two rows, the original three sit behind.
CREATURES = [
    ("Skipper", build_skipper, True),
    ("GulletCod", build_gulletcod, True),
    ("Urchin", build_urchin, True),
    ("Jelly", build_jelly, False),
    ("Lurker", build_lurker, True),
    ("Mimic", build_mimic, False),
    ("Hermit", build_hermit, True),
    ("Voltray", build_voltray, True),
    ("Crab", build_crab, True),
    ("Deckhand", build_deckhand, False),
    ("Angler", build_angler, False),
    # Volcano roster
    ("Fumarole", build_fumarole, True),
    ("EmberSwarm", build_ember_swarm, False),
    ("MagmaOoze", build_magma_ooze, True),
    ("Shardback", build_shardback, True),
    ("CinderDjinn", build_cinder_djinn, False),
    ("LodestoneEel", build_lodestone_eel, True),
    ("SlagGolem", build_slag_golem, False),
    ("Phoenix", build_phoenix, True),
    ("Leviathan", build_leviathan, False),  # the island boss; last so it sits in the back row of the preview
    # Revamp bosses (islands 2-7) + the Kraken's fightable tentacle part.
    ("Gnashroot", build_gnashroot, True),
    ("Rimefang", build_rimefang, True),
    ("Pyrelisk", build_pyrelisk, True),
    ("Noctyss", build_noctyss, False),
    ("AdmiralWrack", build_admiralwrack, False),
    ("Kraken", build_kraken, False),
    ("KrakenTentacle", build_kraken_tentacle, False),
    # Flyers (wisp + wraith are upright-stance hoverers).
    ("BogGull", build_boggull, True),
    ("WillOWisp", build_willowisp, False),
    ("DreadDragonfly", build_dreaddragonfly, True),
    ("HailfinSkua", build_hailfinskua, True),
    ("RiggingWraith", build_riggingwraith, False),
    ("Stormpetrel", build_stormpetrel, True),
]


def main():
    argv = sys.argv[sys.argv.index("--") + 1 :]
    out_path = argv[0]
    want_preview = len(argv) > 1 and argv[1] == "preview"
    # `only=Name,Name` builds just those creatures. For REVIEWING a few at a
    # time - twenty in one grid is too small to judge - so it writes the
    # preview to its own file and never overwrites the real creatures.glb.
    only = None
    for arg in argv[1:]:
        if arg.startswith("only="):
            only = [n.strip() for n in arg[len("only=") :].split(",") if n.strip()]

    build_list = CREATURES
    if only:
        build_list = [row for row in CREATURES if row[0] in only]
        missing = [n for n in only if not any(row[0] == n for row in CREATURES)]
        if missing:
            raise SystemExit(f"[creatures_gen] unknown creature(s): {', '.join(missing)}")
        out_path = None  # a partial pack must never overwrite the real one

    clear_scene()
    for name in COLORS:
        MATS[name] = make_material(name)

    groups = []
    for name, builder, flat in build_list:
        objs = builder()
        report_bbox(name, objs, flat)
        groups.append(objs)

    # Face the way CreatureService points them. Built facing +X, but the import
    # flips +X to Roblox -X, so yaw every creature 180 deg about up (Blender +Z)
    # here - the built front then arrives as Roblox +X. See the authoring
    # contract at the top. Done before the preview so both agree.
    flip = Matrix.Rotation(math.pi, 4, "Z")
    for objs in groups:
        for obj in objs:
            obj.data.transform(flip)

    if out_path:
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
        print(f"[creatures_gen] exported {out_path}")
    else:
        print("[creatures_gen] only= subset: preview only, no .glb written")

    total = sum(len(o.data.polygons) for objs in groups for o in objs)
    print(f"[creatures_gen] creatures: {', '.join(n for n, _, _ in build_list)}; polys: {total}")

    if want_preview:
        import os

        name = "assets/creatures_preview.png" if not only else "assets/creatures_preview_subset.png"
        render_preview(groups, os.path.abspath(name))


main()
