# armor_gen.py
# Generates the wearable armor sets as low-poly meshes and exports them
# together as one glTF pack (.glb) - the ArmorPack, the same "one import" idea
# as the WeaponPack / RodPack / CreaturePack. Run headless:
#
#   blender --background --python assets/armor_gen.py -- assets/armor.glb
#   blender --background --python assets/armor_gen.py -- assets/armor.glb preview
#
# The second form also writes assets/armor_preview.png (the sets laid out) for
# design review without importing.
#
# One pack, many sets: each set exports THREE objects, all overlapping at the
# origin -
#
#   <SetPrefix>_Helm    worn on the Head
#   <SetPrefix>_Chest   worn on the UpperTorso
#   <SetPrefix>_Legs    a hip skirt / greaves ring worn on the LowerTorso
#
# where <SetPrefix> is Armor.sets[<setId>].modelPrefix ("Chitin", "Boneplate").
# ArmorService clones a piece out of the pack by that name and welds it onto
# the wearer, so the names here ARE the contract.
#
# Authoring contract (ArmorService relies on these, keep them true):
#   - 1 Blender unit = 1 Roblox stud. Exported Y-up (Blender +Z -> Roblox +Y).
#   - Every piece is authored CENTERED ON ITS BODY PART'S CENTER at the
#     origin, facing Blender -Y (the pack-wide forward convention). At equip
#     time ArmorService sets the piece's CFrame straight onto the part's
#     CFrame - so a helm is a shell AROUND a 1.2-stud head sitting at the
#     origin, a chest wraps a 2.0 x 1.6 x 1.0 UpperTorso, and the legs ring
#     wraps a 2.0-wide hip line. (Blocky R15 reference sizes; slim avatars
#     just wear it a little loose, like every Roblox armor.)
#   - Pieces must stay CLEAR of the face (front of the head below its middle)
#     and the arms' swing arc (nothing solid further out than x = +/-1.35 at
#     shoulder height).
#   - Flat shading everywhere, matching the island and the other packs.
#
# Colours here are only for the preview; in game ArmorService recolours per
# the set row (Armor.sets palette). Adding a set (f9's four come in behind
# this skeleton): add a FRAME entry and a build_<set>() returning the three
# objects, then register it in SETS - splice-safe, one set per block.

import math
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

TAU = math.tau

# Reference body-part boxes the pieces are authored around (blocky R15).
HEAD = Vector((1.2, 1.2, 1.2))  # w, d, h
UPPER_TORSO = Vector((2.0, 1.0, 1.6))
HIP_W = 2.0

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
            bsdf.inputs["Roughness"].default_value = 0.9
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


def limb(bm, p0, p1, r0, r1, sides=6):
    p0, p1 = Vector(p0), Vector(p1)
    axis = p1 - p0
    length = axis.length
    if length < 1e-6:
        return
    rot = Vector((0, 0, 1)).rotation_difference(axis.normalized()).to_matrix()
    mat = Matrix.Translation((p0 + p1) / 2) @ rot.to_4x4()
    bmesh.ops.create_cone(
        bm,
        cap_ends=True,
        segments=sides,
        radius1=r0,
        radius2=r1,
        depth=length,
        matrix=mat,
    )


def cone(bm, base, tip, r, sides=5):
    limb(bm, base, tip, r, 0.02, sides=sides)


# ---------------------------------------------------------------- Chitin
# Cove crab-shell: rounded carapace plates in barnacled orange, the starter
# set - reads soft and rounded next to Boneplate's spikes.

CHITIN_SHELL = (0.72, 0.42, 0.24)
CHITIN_PALE = (0.88, 0.76, 0.58)


def _barnacles(bm, spots, r=0.07):
    for spot in spots:
        ellipsoid(bm, spot, (r, r, r * 0.7), subdiv=0)


def build_chitin_helm():
    bm = bmesh.new()
    hw, hd, hh = HEAD.x / 2, HEAD.y / 2, HEAD.z / 2
    # Carapace dome: a squashed shell over the crown, open at the face (-Y).
    ellipsoid(bm, (0, 0.08, hh * 0.42), (hw + 0.18, hd + 0.16, hh * 0.72))
    # Neck flare at the back.
    box(bm, (0, hd + 0.1, -hh * 0.35), (HEAD.x * 0.9, 0.16, hh * 0.9))
    # Two small crab horns above the brow.
    for side in (-1, 1):
        cone(
            bm,
            (side * hw * 0.55, -hd * 0.45, hh * 0.75),
            (side * hw * 0.85, -hd * 0.55, hh * 1.25),
            0.09,
        )
    _barnacles(bm, [(hw * 0.7, 0.15, hh * 0.6), (-hw * 0.5, 0.4, hh * 0.7), (0.1, hd * 0.8, hh * 0.3)])
    return finish("Chitin_Helm", bm, CHITIN_SHELL)


def build_chitin_chest():
    bm = bmesh.new()
    tw, td, th = UPPER_TORSO.x / 2, UPPER_TORSO.y / 2, UPPER_TORSO.z / 2
    # Front and back carapace plates, slightly domed.
    ellipsoid(bm, (0, -td - 0.04, 0.05), (tw + 0.1, 0.18, th * 0.95))
    ellipsoid(bm, (0, td + 0.04, 0.05), (tw + 0.1, 0.18, th * 0.95))
    # Shoulder pauldron domes (inside the arm-swing limit).
    for side in (-1, 1):
        ellipsoid(bm, (side * (tw + 0.08), 0, th * 0.62), (0.26, td * 0.85, 0.24))
    # Segmented belly bands.
    for i in range(2):
        box(bm, (0, 0, -th * (0.45 + i * 0.32)), (UPPER_TORSO.x + 0.14 - i * 0.1, UPPER_TORSO.y + 0.14, 0.18))
    _barnacles(bm, [(tw * 0.6, -td - 0.16, th * 0.4), (-tw * 0.3, -td - 0.18, -th * 0.2), (tw * 0.2, td + 0.16, th * 0.5)])
    return finish("Chitin_Chest", bm, CHITIN_SHELL)


def build_chitin_legs():
    bm = bmesh.new()
    # A ring of overlapping shell plates hanging from the hip line.
    plates = 7
    for i in range(plates):
        angle = (i / plates) * TAU + 0.2
        x, y = math.cos(angle) * (HIP_W / 2 + 0.08), math.sin(angle) * 0.62
        rot = Matrix.Rotation(-angle + math.pi / 2, 3, "Z") @ Matrix.Rotation(math.radians(14), 3, "X")
        box(bm, (x, y, -0.3), (0.62, 0.1, 0.72), rot)
    # Hip band tying the plates together.
    box(bm, (0, 0, 0.1), (HIP_W + 0.22, 1.24, 0.2))
    _barnacles(bm, [(HIP_W / 2, -0.3, 0.05), (-HIP_W / 2 + 0.1, 0.35, -0.15)])
    return finish("Chitin_Legs", bm, CHITIN_PALE)


# ---------------------------------------------------------------- Boneplate
# Cursed-bone lattice: pale ribs and spurs over a dark under-wrap - the
# drowned-graveyard counterpart to Chitin's beach shell.

BONE = (0.85, 0.82, 0.72)


def build_boneplate_helm():
    bm = bmesh.new()
    hw, hd, hh = HEAD.x / 2, HEAD.y / 2, HEAD.z / 2
    # Skull cap.
    ellipsoid(bm, (0, 0.02, hh * 0.35), (hw + 0.14, hd + 0.12, hh * 0.8))
    # Brow ridge.
    box(bm, (0, -hd - 0.08, hh * 0.32), (HEAD.x * 0.95, 0.14, 0.16))
    # Cheek guards hugging the jaw line, clear of the face front.
    for side in (-1, 1):
        box(bm, (side * (hw + 0.1), -hd * 0.15, -hh * 0.25), (0.12, hd * 1.1, hh * 0.7))
        # Upturned tusk on each cheek.
        cone(
            bm,
            (side * (hw + 0.1), -hd * 0.7, -hh * 0.35),
            (side * (hw + 0.22), -hd * 1.05, hh * 0.15),
            0.07,
        )
    # Spine crest over the crown.
    for i in range(3):
        cone(bm, (0, -0.25 + i * 0.3, hh * 0.95), (0, -0.28 + i * 0.3, hh * 1.3 - i * 0.06), 0.07)
    return finish("Boneplate_Helm", bm, BONE)


def build_boneplate_chest():
    bm = bmesh.new()
    tw, td, th = UPPER_TORSO.x / 2, UPPER_TORSO.y / 2, UPPER_TORSO.z / 2
    # Sternum plate.
    box(bm, (0, -td - 0.08, th * 0.2), (0.5, 0.14, th * 1.2))
    # Rib hoops wrapping from the spine around the front.
    for i in range(3):
        z = th * (0.45 - i * 0.42)
        for side in (-1, 1):
            limb(
                bm,
                (0, td + 0.1, z + 0.06),
                (side * (tw + 0.1), 0, z),
                0.07,
                0.08,
            )
            limb(
                bm,
                (side * (tw + 0.1), 0, z),
                (side * 0.2, -td - 0.1, z - 0.05),
                0.08,
                0.06,
            )
    # Spine column down the back with knuckle bumps.
    box(bm, (0, td + 0.1, 0), (0.26, 0.14, UPPER_TORSO.z * 0.95))
    for i in range(3):
        ellipsoid(bm, (0, td + 0.16, th * (0.5 - i * 0.5)), (0.12, 0.08, 0.1), subdiv=0)
    # Shoulder bone knobs.
    for side in (-1, 1):
        ellipsoid(bm, (side * (tw + 0.1), 0, th * 0.66), (0.2, 0.28, 0.2), subdiv=0)
    return finish("Boneplate_Chest", bm, BONE)


def build_boneplate_legs():
    bm = bmesh.new()
    # Hanging bone-strip skirt: tapered femurs lashed around the hip line.
    strips = 8
    for i in range(strips):
        angle = (i / strips) * TAU + 0.35
        x, y = math.cos(angle) * (HIP_W / 2 + 0.05), math.sin(angle) * 0.6
        limb(bm, (x, y, 0.12), (x * 1.08, y * 1.15, -0.62), 0.08, 0.055)
        ellipsoid(bm, (x * 1.08, y * 1.15, -0.66), (0.09, 0.09, 0.07), subdiv=0)
    # Hip crest bones at each side.
    for side in (-1, 1):
        box(
            bm,
            (side * (HIP_W / 2 + 0.1), 0, 0.16),
            (0.14, 0.9, 0.26),
            Matrix.Rotation(math.radians(side * 8), 3, "Y"),
        )
    # Dark under-wrap band.
    box(bm, (0, 0, 0.1), (HIP_W + 0.16, 1.2, 0.18))
    return finish("Boneplate_Legs", bm, BONE)


# ---------------------------------------------------------------- Mirewalker
# Swamp: gator leather + fen chitin cured in peat - soft layered hide with
# hard scute ridges, everything slightly asymmetric like it was lashed on.

MIRE_HIDE = (0.41, 0.38, 0.23)
MIRE_SCUTE = (0.28, 0.30, 0.16)


def build_mirewalker_helm():
    bm = bmesh.new()
    hw, hd, hh = HEAD.x / 2, HEAD.y / 2, HEAD.z / 2
    # Leather hood: a soft dome pulled down at the back.
    ellipsoid(bm, (0, 0.1, hh * 0.35), (hw + 0.16, hd + 0.2, hh * 0.75))
    box(bm, (0, hd + 0.14, -hh * 0.2), (HEAD.x * 0.85, 0.18, hh * 1.1))
    # Gator scute ridge running front-to-back over the crown.
    for i in range(4):
        y = -hd * 0.6 + i * 0.38
        cone(bm, (0, y, hh * 0.9), (0, y + 0.05, hh * 1.2 - i * 0.05), 0.1, sides=4)
    return finish("Mirewalker_Helm", bm, MIRE_HIDE)


def build_mirewalker_chest():
    bm = bmesh.new()
    tw, td, th = UPPER_TORSO.x / 2, UPPER_TORSO.y / 2, UPPER_TORSO.z / 2
    # Layered hide wrap: three sagging bands, each a little proud of the last.
    for i in range(3):
        z = th * (0.5 - i * 0.5)
        box(
            bm,
            (0, 0, z),
            (UPPER_TORSO.x + 0.1 + i * 0.1, UPPER_TORSO.y + 0.1 + i * 0.1, th * 0.42),
            Matrix.Rotation(math.radians(2 - i * 2), 3, "Y"),
        )
    # Chitin scutes over the left shoulder only (lashed-on asymmetry).
    for i in range(3):
        box(
            bm,
            (-(tw + 0.06), -td * 0.4 + i * 0.4, th * 0.62),
            (0.24, 0.3, 0.16),
            Matrix.Rotation(math.radians(10), 3, "Y"),
        )
    # Peat-strap knot at the right hip line.
    ellipsoid(bm, (tw * 0.8, -td - 0.12, -th * 0.7), (0.14, 0.1, 0.14), subdiv=0)
    return finish("Mirewalker_Chest", bm, MIRE_HIDE)


def build_mirewalker_legs():
    bm = bmesh.new()
    # Hide skirt: two overlapping wraps, dropped lower at the back.
    box(bm, (0, 0, 0.06), (HIP_W + 0.2, 1.22, 0.24))
    box(bm, (0, 0.2, -0.34), (HIP_W + 0.08, 0.9, 0.6), Matrix.Rotation(math.radians(4), 3, "X"))
    # Scute knee tassets hanging at the front corners.
    for side in (-1, 1):
        box(
            bm,
            (side * HIP_W * 0.36, -0.55, -0.42),
            (0.36, 0.08, 0.5),
            Matrix.Rotation(math.radians(-10), 3, "X"),
        )
    return finish("Mirewalker_Legs", bm, MIRE_SCUTE)


# ---------------------------------------------------------------- Rimebound
# Frostmaw: rimewool + everfrost plate - CHUNKY-SOFT, thick rolled wool with
# blunt ice slabs riding on top (the Frostmaw blunt language).

RIME_WOOL = (0.82, 0.86, 0.9)
RIME_ICE = (0.58, 0.76, 0.91)


def build_rimebound_helm():
    bm = bmesh.new()
    hw, hd, hh = HEAD.x / 2, HEAD.y / 2, HEAD.z / 2
    # Thick wool cap with a fat rolled brim.
    ellipsoid(bm, (0, 0.04, hh * 0.45), (hw + 0.2, hd + 0.18, hh * 0.7))
    limb(bm, (0, 0, hh * 0.1), (0, 0.01, hh * 0.12), hw + 0.3, hw + 0.3, sides=10)
    # Blunt everfrost crest slab.
    box(bm, (0, 0.05, hh * 1.05), (0.3, hd * 1.3, 0.34), Matrix.Rotation(math.radians(8), 3, "X"))
    return finish("Rimebound_Helm", bm, RIME_WOOL)


def build_rimebound_chest():
    bm = bmesh.new()
    tw, td, th = UPPER_TORSO.x / 2, UPPER_TORSO.y / 2, UPPER_TORSO.z / 2
    # Quilted wool coat: fat horizontal rolls, kept under the chin line.
    for i in range(3):
        z = th * (0.42 - i * 0.45)
        limb(bm, (-tw - 0.04, 0, z), (tw + 0.04, 0, z), td + 0.12, td + 0.12, sides=8)
    # Blunt ice slabs: one over the heart, one square on each shoulder.
    box(bm, (-tw * 0.35, -td - 0.24, th * 0.25), (0.56, 0.16, 0.6), Matrix.Rotation(math.radians(6), 3, "Z"))
    for side in (-1, 1):
        box(bm, (side * (tw + 0.02), 0, th * 0.72), (0.42, 0.5, 0.22))
    return finish("Rimebound_Chest", bm, RIME_WOOL)


def build_rimebound_legs():
    bm = bmesh.new()
    # Chunky wool kilt with a soft outward flare - elliptical (squashed in Y)
    # so it hugs the body's depth instead of ballooning front-and-back.
    mat = (
        Matrix.Translation(Vector((0, 0, 0.025)))
        @ Matrix.Diagonal(Vector((1.0, 0.62, 1.0))).to_4x4()
    )
    bmesh.ops.create_cone(
        bm,
        cap_ends=True,
        segments=9,
        radius1=HIP_W / 2 + 0.3,
        radius2=HIP_W / 2 + 0.12,
        depth=0.35,
        matrix=mat,
    )
    # Short blunt icicle fringe under the hem.
    fringe = 7
    for i in range(fringe):
        angle = (i / fringe) * TAU + 0.15
        x, y = math.cos(angle) * (HIP_W / 2 + 0.2), math.sin(angle) * 0.68
        cone(bm, (x, y, -0.18), (x, y, -0.52), 0.09, sides=4)
    return finish("Rimebound_Legs", bm, RIME_ICE)


# ---------------------------------------------------------------- Cindershell
# Volcano: cinderscale mail on basaltweave - hard angular obsidian plates
# with glow seams between them (obsidian-over-glow, like Pyrelisk's hide).

CINDER_PLATE = (0.16, 0.14, 0.17)
CINDER_GLOW = (0.95, 0.42, 0.13)


def build_cindershell_helm():
    bm = bmesh.new()
    hw, hd, hh = HEAD.x / 2, HEAD.y / 2, HEAD.z / 2
    # Angular obsidian casque: two big chamfered plates meeting at a crown seam.
    for side in (-1, 1):
        box(
            bm,
            (side * hw * 0.55, 0.04, hh * 0.45),
            (hw + 0.12, HEAD.y + 0.24, 0.55),
            Matrix.Rotation(math.radians(side * -9), 3, "Y"),
        )
    # Cheek plates raked back.
    for side in (-1, 1):
        box(
            bm,
            (side * (hw + 0.08), 0.1, -hh * 0.2),
            (0.12, hd * 1.4, hh * 0.8),
            Matrix.Rotation(math.radians(side * 6), 3, "Z"),
        )
    # Glow seam ridge along the crown.
    box(bm, (0, 0.04, hh * 0.98), (0.1, HEAD.y + 0.1, 0.12))
    return finish("Cindershell_Helm", bm, CINDER_PLATE)


def build_cindershell_chest():
    bm = bmesh.new()
    tw, td, th = UPPER_TORSO.x / 2, UPPER_TORSO.y / 2, UPPER_TORSO.z / 2
    # Overlapping angular scale plates, raked downward like shed stone.
    for row in range(3):
        z = th * (0.55 - row * 0.5)
        for side in (-1, 1):
            box(
                bm,
                (side * tw * 0.5, -td - 0.12, z),
                (tw * 1.05, 0.14, 0.52),
                Matrix.Rotation(math.radians(side * 10), 3, "Z") @ Matrix.Rotation(math.radians(12), 3, "X"),
            )
    # Basaltweave back plate.
    box(bm, (0, td + 0.1, 0), (UPPER_TORSO.x * 0.9, 0.16, UPPER_TORSO.z * 0.85))
    # Raked shoulder fins (inside the swing limit).
    for side in (-1, 1):
        box(
            bm,
            (side * (tw + 0.06), 0.1, th * 0.7),
            (0.14, 0.7, 0.4),
            Matrix.Rotation(math.radians(side * -20), 3, "Y"),
        )
    return finish("Cindershell_Chest", bm, CINDER_PLATE)


def build_cindershell_legs():
    bm = bmesh.new()
    # Faulds: angular plates stepping down and out, front and back.
    for i in range(2):
        for sign in (-1, 1):
            box(
                bm,
                (0, sign * (0.52 + i * 0.1), -0.05 - i * 0.3),
                (HIP_W + 0.14 - i * 0.2, 0.14, 0.4),
                Matrix.Rotation(math.radians(sign * -12), 3, "X"),
            )
    # Side plates with an ember seam gap.
    for side in (-1, 1):
        box(bm, (side * (HIP_W / 2 + 0.08), 0, -0.15), (0.14, 0.8, 0.6))
    return finish("Cindershell_Legs", bm, CINDER_PLATE)


# ---------------------------------------------------------------- Duskveil
# Gloomtrench: duskhide lined with abyss silk - the THIN set, sleek close
# wraps and hanging drapes, everything raked to points.

DUSK_HIDE = (0.16, 0.15, 0.22)
DUSK_SILK = (0.29, 0.24, 0.42)


def build_duskveil_helm():
    bm = bmesh.new()
    hw, hd, hh = HEAD.x / 2, HEAD.y / 2, HEAD.z / 2
    # Close hood, swept back to a point behind the crown.
    ellipsoid(bm, (0, 0.06, hh * 0.35), (hw + 0.1, hd + 0.1, hh * 0.7))
    cone(bm, (0, hd * 0.6, hh * 0.7), (0, hd * 1.9, hh * 1.1), 0.28, sides=6)
    # Silk mantle falling over the shoulders' line at the back.
    box(bm, (0, hd + 0.12, -hh * 0.5), (HEAD.x * 1.05, 0.1, hh * 0.9), Matrix.Rotation(math.radians(6), 3, "X"))
    return finish("Duskveil_Helm", bm, DUSK_HIDE)


def build_duskveil_chest():
    bm = bmesh.new()
    tw, td, th = UPPER_TORSO.x / 2, UPPER_TORSO.y / 2, UPPER_TORSO.z / 2
    # Slim crossed wrap: two thin diagonal bands over a close vest shell.
    box(bm, (0, 0, 0), (UPPER_TORSO.x + 0.08, UPPER_TORSO.y + 0.08, UPPER_TORSO.z * 0.92))
    for side in (-1, 1):
        box(
            bm,
            (0, -td - 0.1, th * 0.1),
            (0.26, 0.08, UPPER_TORSO.z * 1.0),
            Matrix.Rotation(math.radians(side * 28), 3, "Y") @ Matrix.Rotation(math.radians(side * 24), 3, "X"),
        )
    # Faint mark: a small angled accent stud at the collarbone.
    ellipsoid(bm, (tw * 0.35, -td - 0.14, th * 0.7), (0.09, 0.06, 0.09), subdiv=0)
    return finish("Duskveil_Chest", bm, DUSK_HIDE)


def build_duskveil_legs():
    bm = bmesh.new()
    # Abyss-silk drape: long thin panels front and back, a narrow hip cord.
    limb(bm, (-HIP_W / 2 - 0.06, 0, 0.14), (HIP_W / 2 + 0.06, 0, 0.14), 0.07, 0.07, sides=6)
    for sign in (-1, 1):
        box(
            bm,
            (0, sign * 0.56, -0.4),
            (HIP_W * 0.62, 0.07, 0.95),
            Matrix.Rotation(math.radians(sign * -6), 3, "X"),
        )
    # Side tails raked to points.
    for side in (-1, 1):
        cone(bm, (side * (HIP_W / 2 + 0.04), 0, 0.1), (side * (HIP_W / 2 + 0.12), 0.1, -0.75), 0.16, sides=4)
    return finish("Duskveil_Legs", bm, DUSK_SILK)


# ---------------------------------------------------------------- registry

SETS = {
    "Chitin": (build_chitin_helm, build_chitin_chest, build_chitin_legs),
    "Boneplate": (build_boneplate_helm, build_boneplate_chest, build_boneplate_legs),
    "Mirewalker": (build_mirewalker_helm, build_mirewalker_chest, build_mirewalker_legs),
    "Rimebound": (build_rimebound_helm, build_rimebound_chest, build_rimebound_legs),
    "Cindershell": (build_cindershell_helm, build_cindershell_chest, build_cindershell_legs),
    "Duskveil": (build_duskveil_helm, build_duskveil_chest, build_duskveil_legs),
}


# ---------------------------------------------------------------- build / io


def build_all():
    objects = []
    for _prefix, builders in SETS.items():
        for builder in builders:
            objects.append(builder())
    return objects


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
    print("ARMOR PACK EXPORTED:", path, "-", len(objects), "objects")
    for obj in objects:
        lo = [min(v.co[i] for v in obj.data.vertices) for i in range(3)]
        hi = [max(v.co[i] for v in obj.data.vertices) for i in range(3)]
        print(
            "  %s bbox x %.2f..%.2f  y %.2f..%.2f  z %.2f..%.2f"
            % (obj.name, lo[0], hi[0], lo[1], hi[1], lo[2], hi[2])
        )


def render_preview(path, objects):
    # Lay the pieces out in set columns: helm on top, chest, then legs.
    columns = {}
    for obj in objects:
        prefix = obj.name.split("_")[0]
        columns.setdefault(prefix, []).append(obj)
    for column, prefix in enumerate(SETS):
        for row, obj in enumerate(columns.get(prefix, [])):
            obj.location = Vector(((column - (len(SETS) - 1) / 2) * 3.6, 0, 4.0 - row * 2.1))

    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.rotation_euler = (math.radians(55), 0, math.radians(30))
    bpy.context.collection.objects.link(sun)
    cam_data = bpy.data.cameras.new("Cam")
    cam_data.lens = 28
    cam = bpy.data.objects.new("Cam", cam_data)
    cam.location = Vector((0.0, -21.0, 1.9))
    cam.rotation_euler = (math.radians(88), 0, math.radians(2))
    bpy.context.collection.objects.link(cam)
    bpy.context.scene.camera = cam

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1600
    scene.render.resolution_y = 860
    scene.render.filepath = path
    scene.world = bpy.data.worlds.new("World")
    scene.world.use_nodes = True
    bg = scene.world.node_tree.nodes.get("Background")
    if bg:
        bg.inputs[0].default_value = (0.22, 0.25, 0.3, 1.0)
    bpy.ops.render.render(write_still=True)
    print("ARMOR PREVIEW:", path)


def main():
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    if not argv:
        print("usage: blender --background --python armor_gen.py -- <out.glb> [preview]")
        return
    out = argv[0]
    clear_scene()
    objects = build_all()
    export(out, objects)
    if "preview" in argv[1:]:
        render_preview(out.replace(".glb", "_preview.png"), objects)


main()
