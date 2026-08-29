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
#   - Pieces must stay CLEAR of the arms' swing arc (nothing solid further
#     out than x = +/-1.35 at shoulder height) and of THE FACE BOX below.
#
#     THE FACE BOX (canonical - this is the ONE definition; three different
#     ones were floating around after the 10-set revamp). In authored space,
#     with the head a 1.2-stud cube at the origin and the face looking down
#     -Y, nothing solid may sit inside ALL of:
#
#         y <= -0.52          at or in front of the face plane
#         |x| <= 0.40         the central band only - cheeks stay fair game
#         -0.60 <= z <= 0.00  the head's lower half, chin to midline
#
#     It is a midline rule, not an eye-band rule, because that is what all
#     ten sets already do: measured across the pack, every helm's front
#     geometry sits in z 0.02..0.30 - a BROW OVERHANG above the midline, with
#     the nose, mouth and chin left as open air. So crests, brow facets and
#     hanging lures above the line are explicitly fine (they shade the face,
#     which reads well); a plate crossing down over the nose is not.
#     Cheek/jaw guards outboard of |x| = 0.40, anything behind the face
#     plane, and gorgets/scarves hanging below the head (z < -0.60, off the
#     face entirely) are all unaffected. check_faces() enforces it at build time - it
#     prints and does not throw, so a work-in-progress set still exports.
#   - Flat shading everywhere, matching the island and the other packs.
#
# Colours here are only for the preview; in game ArmorService recolours per
# the set row (Armor.sets palette). Adding a set (all ten are in - the
# skeleton's four-lane build closed 2026-08-28): add a FRAME entry and a build_<set>() returning the three
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


# Plate-placement helpers, shared by every set: the three idioms that recur in
# helms, chests and kilts alike. (Promoted out of the old per-batch prefix on
# the 2026-08-29 ten-set revamp - all ten sets lean on them now.)


def _ring_plates(bm, count, rx, ry, z, size, tilt=0.0, a0=0.0):
    """A full ring of plates standing on the hip/torso arc, each turned to
    face outward (the Chitin-legs idiom, factored out)."""
    for i in range(count):
        angle = a0 + (i / count) * TAU
        x, y = math.cos(angle) * rx, math.sin(angle) * ry
        rot = Matrix.Rotation(-angle + math.pi / 2, 3, "Z") @ Matrix.Rotation(math.radians(tilt), 3, "X")
        box(bm, (x, y, z), size, rot)


def _arc_plates(bm, count, rx, ry, z, size, a0, a1, tilt=0.0):
    """Same, but over an open arc - used to leave the face (-Y) uncovered."""
    for i in range(count):
        t = i / (count - 1) if count > 1 else 0.5
        angle = a0 + (a1 - a0) * t
        x, y = math.cos(angle) * rx, math.sin(angle) * ry
        rot = Matrix.Rotation(-angle + math.pi / 2, 3, "Z") @ Matrix.Rotation(math.radians(tilt), 3, "X")
        box(bm, (x, y, z), size, rot)


def _band(bm, z, r_bottom, r_top, depth, ysquash, segments=8):
    """A squashed-in-Y ring band (the Rimebound-kilt trick) - flares outward
    downward when r_bottom > r_top, which is what makes a lame shingle."""
    mat = (
        Matrix.Translation(Vector((0, 0, z)))
        @ Matrix.Diagonal(Vector((1.0, ysquash, 1.0))).to_4x4()
    )
    bmesh.ops.create_cone(
        bm,
        cap_ends=True,
        segments=segments,
        radius1=r_bottom,
        radius2=r_top,
        depth=depth,
        matrix=mat,
    )


# ---------------------------------------------------------------- Chitin
# Cove crab-shell: rounded carapace plates in barnacled orange, the starter
# set - reads soft and rounded next to Boneplate's spikes.

CHITIN_SHELL = (0.72, 0.42, 0.24)
CHITIN_PALE = (0.88, 0.76, 0.58)


def _barnacles(bm, spots, r=0.07):
    for spot in spots:
        ellipsoid(bm, spot, (r, r, r * 0.7), subdiv=0)


def build_chitin_helm():
    """Horned crab casque: a swept carapace over the crown, two forward horns
    off the brow, stalked crab eyes between them, and mandible cheek-guards
    that frame the face from the sides without ever crossing it."""
    bm = bmesh.new()
    hw, hd, hh = HEAD.x / 2, HEAD.y / 2, HEAD.z / 2

    # Faceted casque: a six-sided shell tapering up off the skull. Its floor
    # sits at z = +0.10, so the brow facet becomes an overhang and everything
    # below the head's middle - the whole face - stays open air.
    limb(bm, (0, 0.12, hh * 0.11), (0, 0.20, hh * 1.04), hw + 0.30, hw + 0.12, sides=6)
    # Crown peak, raked back over the nape.
    limb(bm, (0, 0.22, hh * 0.98), (0, 0.44, hh * 1.60), hw + 0.10, 0.22, sides=6)
    # Brow visor: the carapace's front edge standing proud over the eyes, so
    # the face reads as shaded by the shell rather than sealed inside it.
    box(bm, (0, -0.70, hh * 0.46), (HEAD.x - 0.06, 0.20, 0.20), Matrix.Rotation(math.radians(-18), 3, "X"))
    # Shell spines marching back along the peak.
    for i in range(3):
        y = 0.02 + i * 0.26
        cone(bm, (0, y, hh * 1.18 + i * 0.08), (0, y + 0.14, hh * 1.66 + i * 0.02), 0.10, sides=4)

    # Brow horns: two segments each, curling up and forward off the front
    # facet like a fiddler crab's rostrum.
    for side in (-1, 1):
        limb(bm, (side * 0.40, -0.56, hh * 0.30), (side * 0.54, -0.86, hh * 0.96), 0.13, 0.10)
        cone(bm, (side * 0.54, -0.86, hh * 0.96), (side * 0.66, -1.12, hh * 1.56), 0.10, sides=5)
    # Eye-stalks peeping over the brow, high above the face line.
    for side in (-1, 1):
        limb(bm, (side * 0.18, -0.60, hh * 0.34), (side * 0.20, -0.70, hh * 0.86), 0.05, 0.05, sides=5)
        ellipsoid(bm, (side * 0.20, -0.72, hh * 0.98), (0.09, 0.09, 0.09), subdiv=0)

    # Mandible cheek-guards: side plates dropping past the jaw into a blunt
    # forward tooth, all of it outboard of |x| = 0.49 so the face is untouched.
    for side in (-1, 1):
        # Two stepped plates rather than one wall, so the jaw reads as jointed.
        box(
            bm,
            (side * (hw + 0.13), 0.08, -hh * 0.22),
            (0.16, hd * 1.55, hh * 0.66),
            Matrix.Rotation(math.radians(side * -7), 3, "Z"),
        )
        box(
            bm,
            (side * (hw + 0.05), -0.06, -hh * 0.74),
            (0.16, hd * 1.15, hh * 0.62),
            Matrix.Rotation(math.radians(side * -12), 3, "Z"),
        )
        cone(
            bm,
            (side * 0.74, -0.40, -hh * 0.74),
            (side * 0.62, -1.02, -hh * 0.10),
            0.14,
            sides=4,
        )
    # Nape flare shielding the back of the neck.
    box(bm, (0, hd + 0.26, -hh * 0.30), (HEAD.x * 0.95, 0.18, hh * 1.00))
    _barnacles(bm, [(-0.56, 0.30, hh * 0.86), (-0.70, 0.56, hh * 0.30), (0.34, 0.70, hh * 0.62)])
    return finish("Chitin_Helm", bm, CHITIN_SHELL)


def build_chitin_chest():
    """Shingled carapace with ONE oversized crab-claw pauldron on the left -
    the asymmetry is the whole silhouette - plus spine rows and barnacles."""
    bm = bmesh.new()
    tw, td, th = UPPER_TORSO.x / 2, UPPER_TORSO.y / 2, UPPER_TORSO.z / 2

    # The carapace proper: one big raked shell over the chest, with two side
    # wedges wrapping it back around the ribs. This is the read at distance.
    box(
        bm,
        (0, -(td + 0.26), th * 0.58),
        (UPPER_TORSO.x - 0.14, 0.26, th * 0.66),
        Matrix.Rotation(math.radians(8), 3, "X"),
    )
    box(
        bm,
        (0, -(td + 0.20), th * 0.06),
        (UPPER_TORSO.x - 0.02, 0.26, th * 0.68),
        Matrix.Rotation(math.radians(16), 3, "X"),
    )
    # Keel ridge running down the shell's centre line.
    box(
        bm,
        (0, -(td + 0.36), th * 0.30),
        (0.18, 0.16, th * 1.10),
        Matrix.Rotation(math.radians(12), 3, "X"),
    )
    for side in (-1, 1):
        box(
            bm,
            (side * 0.88, -0.28, th * 0.30),
            (0.28, 0.98, th * 1.00),
            Matrix.Rotation(math.radians(side * -28), 3, "Z"),
        )
    box(bm, (0, td + 0.14, 0.04), (UPPER_TORSO.x * 0.94, 0.24, UPPER_TORSO.z * 0.88))

    # Two shingled abdomen bands wrapping the waist under the carapace hem.
    for i in range(2):
        box(
            bm,
            (0, 0, -th * (0.44 + i * 0.42)),
            (UPPER_TORSO.x + 0.10 - i * 0.18, UPPER_TORSO.y + 0.30 - i * 0.06, 0.38),
            Matrix.Rotation(math.radians(12), 3, "X"),
        )
    # Spine row standing off the carapace's top edge - the Spinehide tell.
    for i in range(5):
        x = (i - 2) * 0.34
        cone(bm, (x, -(td + 0.20), th * 0.86), (x * 1.18, -(td + 0.44), th * 1.36), 0.09, sides=4)
    # Dorsal spines down the back plate.
    for i in range(2):
        cone(bm, (0, td + 0.22, th * (0.40 - i * 0.62)), (0, td + 0.50, th * (0.58 - i * 0.62)), 0.10, sides=4)

    # Right shoulder: an ordinary little carapace cap, so the left claw reads
    # as the outlier it is.
    ellipsoid(bm, (tw - 0.02, 0.02, th * 0.62), (0.30, 0.40, 0.26), subdiv=0)
    cone(bm, (tw - 0.02, -0.16, th * 0.80), (tw + 0.08, -0.34, th * 1.22), 0.08, sides=4)

    # THE CLAW - an oversized pincer pauldron growing off the left shoulder,
    # hinging forward past the chest. Outer edge parks at x = -1.32.
    ellipsoid(bm, (-(tw - 0.02), 0.02, th * 0.56), (0.32, 0.42, 0.32))
    limb(bm, (-0.98, 0.08, th * 0.72), (-1.04, -0.44, th * 0.94), 0.24, 0.28)
    box(
        bm,
        (-1.03, -0.68, th * 1.06),
        (0.42, 0.58, 0.52),
        Matrix.Rotation(math.radians(-12), 3, "X") @ Matrix.Rotation(math.radians(-10), 3, "Z"),
    )
    # Upper pincer, long and thin, curling up-forward and splaying outboard so
    # the claw still reads as a claw head-on.
    limb(bm, (-1.03, -0.88, th * 1.22), (-1.11, -1.30, th * 1.42), 0.14, 0.09)
    cone(bm, (-1.11, -1.30, th * 1.42), (-1.19, -1.62, th * 1.30), 0.09, sides=5)
    # Lower pincer held open beneath it - the gap is what makes it a claw.
    limb(bm, (-1.03, -0.88, th * 0.90), (-1.09, -1.28, th * 0.68), 0.13, 0.08)
    cone(bm, (-1.09, -1.28, th * 0.68), (-1.15, -1.58, th * 0.76), 0.08, sides=5)

    _barnacles(bm, [(tw * 0.62, -td - 0.30, th * 0.10), (tw * 0.30, -td - 0.32, -th * 0.60), (-tw * 0.40, td + 0.22, th * 0.20)])
    return finish("Chitin_Chest", bm, CHITIN_SHELL)


def build_chitin_legs():
    """Faulds built like a crab's abdomen: three telescoping segment rings,
    each narrower and lower than the last, spined along the flanks."""
    bm = bmesh.new()
    half = HIP_W / 2

    # Hip carapace band the segments hang from.
    box(bm, (0, 0, 0.16), (HIP_W + 0.22, 1.24, 0.22))

    rings = (
        (half + 0.08, 0.70, -0.10, (0.86, 0.14, 0.48), 10, 0.22),
        (half + 0.02, 0.66, -0.44, (0.80, 0.14, 0.44), 16, 0.22 + math.pi / 8),
        (half - 0.08, 0.60, -0.74, (0.72, 0.14, 0.40), 22, 0.22),
    )
    for rx, ry, z, size, tilt, a0 in rings:
        for i in range(8):
            angle = a0 + (i / 8) * TAU
            x, y = math.cos(angle) * rx, math.sin(angle) * ry
            # Turn each plate along the ELLIPSE's tangent (not the circle's) -
            # otherwise the four diagonal plates end up facing sideways and the
            # segment reads as rubble instead of shell.
            face = math.atan2(ry * math.cos(angle), -rx * math.sin(angle))
            rot = Matrix.Rotation(face, 3, "Z") @ Matrix.Rotation(math.radians(tilt), 3, "X")
            box(bm, (x, y, z), size, rot)

    # Flank spines, one pair per segment, raked back and down.
    for side in (-1, 1):
        for i, z in enumerate((-0.06, -0.40, -0.72)):
            cone(
                bm,
                (side * (half - 0.02), 0.02, z),
                (side * (half + 0.24), 0.30 + i * 0.06, z - 0.22),
                0.10,
                sides=4,
            )
    # Tail plate flaring off the back hem.
    box(bm, (0, 0.60, -0.96), (1.00, 0.15, 0.36), Matrix.Rotation(math.radians(-20), 3, "X"))
    return finish("Chitin_Legs", bm, CHITIN_PALE)


# ---------------------------------------------------------------- Boneplate
# Cursed-bone lattice: pale ribs and spurs over a dark under-wrap - the
# drowned-graveyard counterpart to Chitin's beach shell.

BONE = (0.85, 0.82, 0.72)


def build_boneplate_helm():
    """A leviathan's fish-skull worn as a crown: the cranium rides the back of
    the head, the upper jaw arches forward over the brow, and the mandible
    bars sweep past the cheeks - the wearer's face is where its throat was."""
    bm = bmesh.new()
    hw, hd, hh = HEAD.x / 2, HEAD.y / 2, HEAD.z / 2

    # The cranium: a boxy skull shell over the crown, back and sides. Its
    # floor is z = 0 and its front wall stops at y = -0.48, which is exactly
    # the face - the head's front-lower quadrant is left as open air.
    box(bm, (0, 0.18, hh * 0.52), (HEAD.x + 0.16, HEAD.y + 0.10, hh * 1.04))
    # Braincase taper and the occipital crest blades fanning off the back.
    box(bm, (0, 0.40, hh * 1.32), (HEAD.x * 0.72, HEAD.y * 0.72, 0.34), Matrix.Rotation(math.radians(-14), 3, "X"))
    for i in range(3):
        box(
            bm,
            (0, 0.62 + i * 0.13, hh * (1.62 - i * 0.34)),
            (0.30 - i * 0.06, 0.12, 0.42),
            Matrix.Rotation(math.radians(-28 - i * 12), 3, "X"),
        )

    # The snout: a wedge thrown forward off the cranium, tapering to a beak.
    box(bm, (0, -0.92, hh * 0.80), (0.72, 0.86, 0.36), Matrix.Rotation(math.radians(-8), 3, "X"))
    cone(bm, (0, -1.24, hh * 0.74), (0, -1.74, hh * 0.54), 0.20, sides=5)
    # Nasal ridge along its spine.
    box(bm, (0, -0.66, hh * 1.06), (0.14, 0.92, 0.14), Matrix.Rotation(math.radians(8), 3, "X"))
    # Upper jaw rim under the snout - the toothed line the face sits beneath.
    box(bm, (0, -0.80, hh * 0.34), (HEAD.x * 0.80, 0.42, 0.18))
    # Short front teeth off that rim (they stay above the head's middle) and
    # long side fangs that can hang past it, outboard of the face entirely.
    for i in range(4):
        x = (i - 1.5) * 0.22
        cone(bm, (x, -0.80, hh * 0.28), (x, -0.82, hh * 0.06), 0.055, sides=4)
    for side in (-1, 1):
        for k, (y, drop) in enumerate(((-0.72, -0.26), (-0.30, -0.38), (0.16, -0.32))):
            cone(bm, (side * (0.54 + k * 0.07), y, hh * 0.30), (side * (0.58 + k * 0.07), y, drop), 0.09, sides=4)

    # Gill / cheek plates walling the sides of the head, and the mandible bars
    # hinged behind them, sweeping forward with their own upturned fangs.
    for side in (-1, 1):
        box(
            bm,
            (side * (hw + 0.12), 0.10, -hh * 0.44),
            (0.16, hd * 1.70, hh * 1.10),
            Matrix.Rotation(math.radians(side * -6), 3, "Z"),
        )
        limb(bm, (side * 0.68, 0.42, -hh * 0.18), (side * 0.62, -0.92, -hh * 0.54), 0.14, 0.09, sides=5)
        for k, y in enumerate((-0.66, -0.24)):
            cone(bm, (side * 0.63, y, -hh * 0.56), (side * 0.62, y - 0.02, hh * 0.04 - k * 0.08), 0.07, sides=4)
    return finish("Boneplate_Helm", bm, BONE)


def build_boneplate_chest():
    """A full ribcage: four thick rib pairs sprung off a knobbled spine and
    closed by a jutting sternum keel, with a vertebra bandolier slung across
    the front. Big gaps between the ribs - they must read at 30 studs."""
    bm = bmesh.new()
    tw, td, th = UPPER_TORSO.x / 2, UPPER_TORSO.y / 2, UPPER_TORSO.z / 2

    # Spine column with vertebra knuckles.
    box(bm, (0, td + 0.16, 0), (0.24, 0.20, UPPER_TORSO.z * 1.02))
    for i in range(5):
        z = th * (0.76 - i * 0.40)
        box(bm, (0, td + 0.30, z), (0.20, 0.16, 0.17))

    # Ribs: three straight runs a side that trace the OUTSIDE of the torso -
    # behind the flank, around it, then in to the sternum. Never cut the box,
    # and spaced so the gap between ribs is as wide as the bone itself.
    for i, z in enumerate((0.62, 0.26, -0.10, -0.46)):
        pull = 1.0 - i * 0.05
        for side in (-1, 1):
            p0 = (side * (tw + 0.08) * pull, td - 0.06, z + 0.06)
            p1 = (side * (tw + 0.12) * pull, -0.18, z)
            p2 = (side * 0.94 * pull, -(td + 0.28), z - 0.10)
            p3 = (side * 0.26, -(td + 0.36), z - 0.18)
            limb(bm, p0, p1, 0.09, 0.10, sides=4)
            limb(bm, p1, p2, 0.10, 0.085, sides=4)
            limb(bm, p2, p3, 0.085, 0.07, sides=4)

    # Sternum keel: a blade standing proud of where the ribs meet.
    box(bm, (0, -(td + 0.28), th * 0.28), (0.24, 0.30, UPPER_TORSO.z * 0.86), Matrix.Rotation(math.radians(7), 3, "X"))
    box(bm, (0, -(td + 0.46), th * 0.10), (0.15, 0.22, UPPER_TORSO.z * 0.56), Matrix.Rotation(math.radians(7), 3, "X"))
    # Collarbones swept up to the shoulder knobs.
    for side in (-1, 1):
        limb(bm, (0, -(td + 0.16), th * 0.86), (side * (tw - 0.04), -0.16, th * 0.80), 0.08, 0.09, sides=5)
        ellipsoid(bm, (side * (tw - 0.02), 0, th * 0.78), (0.24, 0.30, 0.22), subdiv=0)

    # Vertebra bandolier: five spurred vertebrae strung from the right
    # shoulder down to the left hip, riding in front of the keel.
    for i in range(5):
        t = i / 4.0
        x = 0.78 - 1.42 * t
        z = th * 0.86 - 1.44 * t
        rot = Matrix.Rotation(math.radians(-45), 3, "Y")
        box(bm, (x, -(td + 0.50), z), (0.32, 0.18, 0.24), rot)
        if i % 2 == 0:
            cone(bm, (x, -(td + 0.50), z), (x + 0.14, -(td + 0.62), z + 0.16), 0.06, sides=4)
    return finish("Boneplate_Chest", bm, BONE)


def build_boneplate_legs():
    """Fishbone tassets: seven skeletal fingers hooked over the hip girdle,
    each jointed at a knuckle and curling back in toward the leg."""
    bm = bmesh.new()
    half = HIP_W / 2

    # Hip girdle, with iliac blades flaring at each side.
    box(bm, (0, 0, 0.10), (HIP_W + 0.14, 1.16, 0.16))
    for side in (-1, 1):
        box(
            bm,
            (side * (half + 0.06), -0.06, 0.26),
            (0.14, 0.82, 0.30),
            Matrix.Rotation(math.radians(side * 14), 3, "Y") @ Matrix.Rotation(math.radians(-10), 3, "X"),
        )

    fingers = 7
    for i in range(fingers):
        angle = 0.30 + (i / fingers) * TAU
        cx, sy = math.cos(angle), math.sin(angle)
        knuckle = (cx * (half + 0.12), sy * 0.72, -0.42)
        # Proximal bone off the girdle, then the joint, then the curled tip.
        limb(bm, (cx * (half + 0.02), sy * 0.62, 0.04), knuckle, 0.10, 0.085, sides=4)
        ellipsoid(bm, knuckle, (0.12, 0.12, 0.11), subdiv=0)
        limb(bm, knuckle, (cx * (half + 0.02), sy * 0.64, -0.88), 0.085, 0.055, sides=4)
    return finish("Boneplate_Legs", bm, BONE)


# ---------------------------------------------------------------- Mirewalker
# Swamp: gator leather + fen chitin cured in peat - soft layered hide with
# hard scute ridges, everything slightly asymmetric like it was lashed on.

MIRE_HIDE = (0.41, 0.38, 0.23)
MIRE_SCUTE = (0.28, 0.30, 0.16)


def build_mirewalker_helm():
    """A deep fen hood: a peaked cowl thrown forward over the brow, snapped
    reed antlers off the temples (taller on the left - nothing here is
    symmetric) and a moss veil hanging down one side of the face only."""
    bm = bmesh.new()
    hw, hd, hh = HEAD.x / 2, HEAD.y / 2, HEAD.z / 2

    # Hood crown. Its floor is z = +0.05 so the face is never enclosed; the
    # sides and back are closed in separately, below.
    limb(bm, (0, 0.16, hh * 0.08), (0, 0.32, hh * 1.30), hw + 0.28, 0.36, sides=6)
    # The cowl opening: two rim planes meeting in a peak thrown forward over
    # the eyes, so the hood reads as a hood and not a hat brim.
    for side in (-1, 1):
        box(
            bm,
            (side * 0.30, -0.78, hh * 0.62),
            (0.78, 0.26, 0.28),
            Matrix.Rotation(math.radians(side * 18), 3, "Y") @ Matrix.Rotation(math.radians(-28), 3, "X"),
        )
    for side in (-1, 1):
        box(
            bm,
            (side * 0.67, -0.66, hh * 0.60),
            (0.26, 0.32, 0.52),
            Matrix.Rotation(math.radians(side * 24), 3, "Z"),
        )
    # Hood sides and the long fall down the back.
    for side in (-1, 1):
        box(
            bm,
            (side * (hw + 0.14), 0.08, -hh * 0.34),
            (0.20, hd * 1.85, hh * 1.30),
            Matrix.Rotation(math.radians(side * -5), 3, "Z"),
        )
    box(bm, (0, hd + 0.18, -hh * 0.30), (HEAD.x + 0.10, 0.24, hh * 1.55), Matrix.Rotation(math.radians(5), 3, "X"))

    # Snapped-reed antlers - the left one is taller and forks twice, the right
    # is broken off short. Blunt ends read as snapped, points as growing.
    limb(bm, (-0.30, 0.24, hh * 1.10), (-0.62, 0.32, hh * 2.14), 0.09, 0.06, sides=4)
    cone(bm, (-0.50, 0.28, hh * 1.66), (-0.92, 0.12, hh * 2.16), 0.055, sides=4)
    limb(bm, (-0.58, 0.31, hh * 1.98), (-0.74, 0.56, hh * 2.62), 0.05, 0.05, sides=4)
    box(bm, (-0.44, 0.28, hh * 1.62), (0.16, 0.14, 0.10))
    limb(bm, (0.30, 0.24, hh * 1.10), (0.54, 0.30, hh * 1.82), 0.09, 0.06, sides=4)
    cone(bm, (0.48, 0.28, hh * 1.60), (0.80, 0.46, hh * 2.00), 0.05, sides=4)
    box(bm, (0.42, 0.27, hh * 1.44), (0.15, 0.13, 0.10))

    # Moss veil: three ragged falls down the RIGHT side of the face only,
    # every one of them outboard of x = +0.47 so the face itself stays clear.
    for i, (x, drop) in enumerate(((0.64, 0.62), (0.72, 0.90), (0.63, 0.44))):
        box(
            bm,
            (x, -0.58 + i * 0.22, hh * 0.14 - drop / 2),
            (0.18, 0.20, drop),
            Matrix.Rotation(math.radians(6 - i * 5), 3, "Y"),
        )
    # Moss tufts clinging to the hood.
    for spot in ((-0.44, 0.52, hh * 1.16), (0.34, 0.74, hh * 0.62)):
        ellipsoid(bm, spot, (0.17, 0.15, 0.10), subdiv=0)
    return finish("Mirewalker_Helm", bm, MIRE_HIDE)


def build_mirewalker_chest():
    """Root-laced leather the fen grew onto: living roots crossing the chest,
    a stair of shelf fungi up the right flank, and ONE sapling sprouting from
    the left shoulder - the piece's whole silhouette."""
    bm = bmesh.new()
    tw, td, th = UPPER_TORSO.x / 2, UPPER_TORSO.y / 2, UPPER_TORSO.z / 2

    # Soft layered hide, two wraps sitting slightly askew of each other.
    box(bm, (0, 0, th * 0.36), (UPPER_TORSO.x + 0.08, UPPER_TORSO.y + 0.12, th * 1.08), Matrix.Rotation(math.radians(3), 3, "Y"))
    box(bm, (0, 0, -th * 0.54), (UPPER_TORSO.x + 0.02, UPPER_TORSO.y + 0.08, th * 0.82), Matrix.Rotation(math.radians(-4), 3, "Y"))

    # Root lacing: three thick roots crawling shoulder-to-opposite-hip across
    # the wrap, each kinked once so it reads grown rather than stitched.
    laces = (
        ((-0.92, 0.88, 0.12), (-0.10, 0.62, 0.105), (0.74, 0.30, 0.085)),
        ((0.94, 0.30, 0.115), (0.06, -0.02, 0.10), (-0.84, -0.30, 0.08)),
        ((-0.88, -0.44, 0.105), (0.00, -0.72, 0.09), (0.90, -0.94, 0.07)),
    )
    for a, b, c in laces:
        limb(bm, (a[0], -(td + 0.08), a[1] * th), (b[0], -(td + 0.15), b[1] * th), a[2], b[2], sides=6)
        limb(bm, (b[0], -(td + 0.15), b[1] * th), (c[0], -(td + 0.08), c[1] * th), b[2], c[2], sides=6)
    # Root collar knotted at the throat, with two tendrils curling off it.
    limb(bm, (-0.48, -(td + 0.12), th * 0.86), (0.48, -(td + 0.12), th * 0.86), 0.09, 0.09, sides=6)
    for side in (-1, 1):
        cone(bm, (side * 0.34, -(td + 0.16), th * 0.86), (side * 0.46, -(td + 0.30), th * 1.14), 0.06, sides=4)

    # Shelf fungi: three brackets stepping up the right flank, each a squat
    # disc half-buried in the hide.
    for x, y, z, r in ((0.46, -0.50, -th * 0.52, 0.34), (0.74, -0.44, th * 0.02, 0.30), (0.52, -0.52, th * 0.60, 0.36)):
        limb(bm, (x, y, z), (x, y - 0.09, z + 0.13), r, r * 0.78, sides=6)

    # THE SAPLING - a young tree rooted in the left pauldron, leaning out and
    # up past the shoulder line.
    box(bm, (-(tw - 0.06), 0.02, th * 0.74), (0.42, 0.72, 0.26), Matrix.Rotation(math.radians(-8), 3, "Y"))
    limb(bm, (-0.86, 0.02, th * 0.86), (-1.00, -0.44, th * 1.55), 0.11, 0.08, sides=5)
    limb(bm, (-1.00, -0.44, th * 1.55), (-1.02, -0.86, th * 2.15), 0.08, 0.055, sides=5)
    cone(bm, (-1.00, -0.56, th * 1.70), (-1.18, -0.94, th * 2.00), 0.05, sides=4)
    cone(bm, (-1.01, -0.72, th * 1.95), (-0.82, -1.06, th * 2.28), 0.05, sides=4)
    for spot, r in (
        ((-1.06, -1.00, th * 2.28), 0.26),
        ((-0.84, -1.10, th * 2.25), 0.22),
        ((-1.14, -0.84, th * 1.98), 0.20),
        ((-0.98, -0.98, th * 2.52), 0.19),
    ):
        ellipsoid(bm, spot, (r, r * 0.82, r * 0.60), subdiv=0)
    # Right shoulder gets only a lashed hide pad, so the sapling reads alone.
    box(bm, (tw - 0.04, 0.02, th * 0.72), (0.40, 0.66, 0.22), Matrix.Rotation(math.radians(7), 3, "Y"))
    return finish("Mirewalker_Chest", bm, MIRE_HIDE)


def build_mirewalker_legs():
    """Waders rolled at the hip, a lily pad strapped over each knee, and root
    tendrils crawling down over the whole thing."""
    bm = bmesh.new()
    half = HIP_W / 2

    # Wader body and its turned-down cuff.
    box(bm, (0, 0, -0.34), (HIP_W + 0.10, 1.10, 0.98), Matrix.Rotation(math.radians(2), 3, "Y"))
    box(bm, (0, 0, 0.14), (HIP_W + 0.26, 1.28, 0.28), Matrix.Rotation(math.radians(-3), 3, "Y"))

    # Lily-pad knee guards: a flat disc over each thigh with veins across it.
    for side in (-1, 1):
        px, pz = side * 0.52, -0.62
        limb(bm, (px, -0.66, pz), (px, -0.78, pz - 0.03), 0.40, 0.37, sides=8)
        for k in range(3):
            box(
                bm,
                (px, -0.80, pz),
                (0.62, 0.05, 0.07),
                Matrix.Rotation(math.radians(k * 60 - 60), 3, "Y"),
            )
        ellipsoid(bm, (px, -0.84, pz), (0.09, 0.06, 0.09), subdiv=0)

    # Root tendrils wrapping down and around the waders.
    tendrils = (
        ((-0.98, 0.10), (-1.06, -0.40), (-0.88, -0.92)),
        ((-0.42, 0.14), (-0.60, -0.36), (-0.44, -0.86)),
        ((0.34, 0.12), (0.20, -0.44), (0.42, -0.96)),
        ((0.96, 0.14), (1.08, -0.34), (0.86, -0.88)),
        ((0.10, 0.16), (-0.06, -0.30), (0.14, -0.74)),
    )
    for a, b, c in tendrils:
        ya, yb, yc = -0.58, -0.64, -0.56
        limb(bm, (a[0], ya, a[1]), (b[0], yb, b[1]), 0.12, 0.10, sides=5)
        limb(bm, (b[0], yb, b[1]), (c[0], yc, c[1]), 0.10, 0.07, sides=5)
    # A pair carried round onto the back so the wrap reads all the way round.
    for side in (-1, 1):
        limb(bm, (side * 0.70, 0.58, 0.12), (side * 0.52, 0.62, -0.82), 0.11, 0.07, sides=5)
    return finish("Mirewalker_Legs", bm, MIRE_SCUTE)


# ---------------------------------------------------------------- Rimebound
# Frostmaw: a GLACIER BULWARK. Nothing in this set is a shard of glass - it is
# all boulder-of-ice: chunky soft-cornered masses, rolled wool, blunt slabs
# stacked like courses of stone. The ONE place a point is allowed is the
# icicle fringe under the kilt, and even there the tips are stubbed off.

RIME_WOOL = (0.82, 0.86, 0.9)
RIME_ICE = (0.58, 0.76, 0.91)


def _ah_shard(bm, center, size, rot=None, taper=0.16, seg=4):
    """A flat tapered plate: a low-segment cone squashed on Y, wide at its
    +Z end and narrowing to `taper` of that at its -Z end. Rotate it to aim.

    Shared by the three island sets below - it is the icicle of the Rimebound
    fringe, the spade of a Cindershell fauld and the torn fin of a Duskveil
    drape, which is exactly the point: one plate primitive, three dialects.
    """
    mat = Matrix.Translation(Vector(center))
    if rot is not None:
        mat = mat @ rot.to_4x4()
    mat = mat @ Matrix.Diagonal(Vector((size[0], size[1], 1.0))).to_4x4()
    bmesh.ops.create_cone(
        bm,
        cap_ends=True,
        segments=seg,
        radius1=0.5 * taper,
        radius2=0.5,
        depth=size[2],
        matrix=mat,
    )


def _ah_lump(bm, center, radii):
    """A blunt boulder - the Rimebound corner-rounder."""
    ellipsoid(bm, center, radii, subdiv=0)


def build_rimebound_helm():
    bm = bmesh.new()
    hw, hd, hh = HEAD.x / 2, HEAD.y / 2, HEAD.z / 2
    # Everfrost block: a stepped boulder of ice on the skull, each course a
    # little smaller than the one under it. No bevels, no spikes.
    box(bm, (0, 0.04, -0.06), (2 * hw + 0.32, 2 * hd + 0.28, hh * 1.04))
    box(bm, (0, 0.06, 0.44), (2 * hw + 0.10, 2 * hd + 0.10, hh * 0.84))
    box(bm, (0, 0.10, 0.78), (2 * hw - 0.34, 2 * hd - 0.26, hh * 0.40))
    # Crown boulders: three blunt masses along the ridge - the crest reads as
    # rolled ice, never as a fin.
    for i, (y, r) in enumerate(((-0.22, 0.20), (0.10, 0.24), (0.42, 0.19))):
        _ah_lump(bm, (0, y, 0.92 + (0.03 if i == 1 else 0)), (r, r * 1.15, r * 0.78))

    # The visor: one rolled block thrown forward over the brow like a plough
    # blade, with a blunt lower lip under it - the open band between the two
    # is the sight slit. Both sit ABOVE the head's middle, face left clear.
    box(bm, (0, -(hd + 0.24), 0.44), (2 * hw + 0.06, 0.40, 0.34),
        Matrix.Rotation(math.radians(-10), 3, "X"))
    box(bm, (0, -(hd + 0.20), 0.09), (2 * hw - 0.06, 0.34, 0.14))
    for side in (-1, 1):
        _ah_lump(bm, (side * (hw + 0.02), -(hd + 0.34), 0.42), (0.17, 0.16, 0.17))

    # Rimewool brow roll: a fat wool band wrapping the whole base of the block,
    # bunched into lumps so it reads soft against all that ice.
    _arc_plates(bm, 7, hw + 0.28, hd + 0.26, 0.19, (0.38, 0.24, 0.32),
            math.radians(-58), math.radians(238))
    for i in range(7):
        a = math.radians(-58) + math.radians(296) * (i / 6)
        _ah_lump(bm, (math.cos(a) * (hw + 0.28), math.sin(a) * (hd + 0.26), 0.22), (0.17, 0.17, 0.17))

    # Jaw guards: thick slabs down the sides, well outboard of the face.
    for side in (-1, 1):
        box(bm, (side * (hw + 0.14), -0.06, -hh * 0.62), (0.26, 2 * hd + 0.10, hh * 0.72))
        _ah_lump(bm, (side * (hw + 0.14), -(hd + 0.02), -hh * 0.86), (0.17, 0.17, 0.17))

    # Frozen beard: a chunky ice wedge hanging off the chin, thrown FORWARD so
    # it stands clear of the collar, entirely below the head box - it never
    # crosses the face.
    box(bm, (0, -(hd + 0.16), -0.86), (0.88, 0.34, 0.40),
        Matrix.Rotation(math.radians(12), 3, "X"))
    for side in (-1, 1):
        _ah_lump(bm, (side * 0.36, -(hd + 0.10), -0.84), (0.24, 0.24, 0.18))
        # Two blunt beard drips, tips stubbed off.
        _ah_shard(bm, (side * 0.22, -(hd + 0.24), -1.16), (0.22, 0.20, 0.30), taper=0.5, seg=5)
    _ah_lump(bm, (0, -(hd + 0.30), -1.04), (0.26, 0.20, 0.18))
    return finish("Rimebound_Helm", bm, RIME_WOOL)


def build_rimebound_chest():
    bm = bmesh.new()
    tw, td, th = UPPER_TORSO.x / 2, UPPER_TORSO.y / 2, UPPER_TORSO.z / 2
    # Glacial courses: four stacked slabs wrapping the whole torso, each one
    # stepping in and out against the one below so the stack reads as laid
    # masonry rather than a moulded barrel.
    courses = ((0.58, 2.26, 1.30, 0.34, 2.5), (0.20, 2.12, 1.20, 0.34, -3.0),
               (-0.20, 2.22, 1.28, 0.34, 1.5), (-0.60, 2.04, 1.16, 0.32, -2.0))
    for z, w, d, h, tilt in courses:
        box(bm, (0, 0, z), (w, d, h), Matrix.Rotation(math.radians(tilt), 3, "Y"))
    # Compacted-snow seams: thin recessed courses crushed into the gaps, so
    # each slab reads as a separate block of ice sitting on packed snow.
    for z in (0.39, 0.00, -0.40):
        box(bm, (0, 0, z), (2.02, 1.10, 0.12))
    # A proud boulder face on each course, alternating side.
    for i, (z, _w, d, _h, _t) in enumerate(courses):
        box(bm, ((-0.18 if i % 2 else 0.18), -(d / 2 + 0.10), z), (1.20, 0.22, 0.26))
    # Rounded-off corners - the set's boulder-not-shard rule, applied where
    # the slab stack would otherwise show a hard vertical edge.
    for side in (-1, 1):
        _ah_lump(bm, (side * 1.00, -0.58, 0.58), (0.16, 0.16, 0.18))
        _ah_lump(bm, (side * 1.02, -0.60, -0.20), (0.16, 0.16, 0.18))
        _ah_lump(bm, (side * 0.96, 0.56, 0.18), (0.15, 0.15, 0.17))
    # Blunt shoulder ice caps (inside the arm swing arc).
    for side in (-1, 1):
        box(bm, (side * (tw + 0.12), 0.02, th * 0.78), (0.40, 2 * td + 0.34, 0.30))
        _ah_lump(bm, (side * (tw + 0.10), 0.02, th * 0.98), (0.20, 0.40, 0.14))
        _ah_lump(bm, (side * (tw + 0.06), -(td + 0.10), th * 0.68), (0.18, 0.16, 0.18))
    # Rimewool collar: a fat roll at the neck with wool lumps bunched on it.
    _band(bm, th * 0.94, 0.62, 0.58, 0.26, 0.92, segments=9)
    for i in range(6):
        a = (i / 6) * TAU + 0.3
        _ah_lump(bm, (math.cos(a) * 0.60, math.sin(a) * 0.56, th * 0.98), (0.16, 0.16, 0.15))
    return finish("Rimebound_Chest", bm, RIME_ICE)


def build_rimebound_legs():
    bm = bmesh.new()
    # Slab belt: a blunt ring of ice blocks on a square belt slab (the slab is
    # a box, not a ring, so the hip's corners never poke through it).
    box(bm, (0, 0, 0.16), (2.20, 1.22, 0.30))
    box(bm, (0, 0, -0.22), (2.08, 1.10, 0.54))
    _ring_plates(bm, 8, 1.06, 0.62, 0.16, (0.44, 0.18, 0.30))
    # The kilt itself: one heavy flared course hanging off the belt.
    _band(bm, -0.24, 1.22, 1.08, 0.54, 0.62, segments=9)
    # Icicle fringe - the ONE place ice is allowed to hang in points, and even
    # here every tip is stubbed off blunt. Alternating lengths round the hem.
    lengths = (0.52, 0.34, 0.44, 0.30, 0.56, 0.36, 0.46, 0.32, 0.50, 0.38)
    for i, ln in enumerate(lengths):
        a = (i / len(lengths)) * TAU + 0.12
        x, y = math.cos(a) * 1.10, math.sin(a) * 0.66
        _ah_shard(bm, (x, y, -0.52 - ln / 2), (0.30, 0.24, ln), taper=0.42, seg=5)
    return finish("Rimebound_Legs", bm, RIME_ICE)


# ---------------------------------------------------------------- Cindershell
# Pyrelisk: an OBSIDIAN DRAGON. Sharp faceted volcanic-glass plates ride OVER
# a molten under-body, and every gap between plates is deliberate - the dark
# scales stand proud and the seams between them read as the glow beneath.

CINDER_PLATE = (0.16, 0.14, 0.17)
CINDER_GLOW = (0.95, 0.42, 0.13)


def build_cindershell_helm():
    bm = bmesh.new()
    hw, hd, hh = HEAD.x / 2, HEAD.y / 2, HEAD.z / 2
    # Raked casque: three angular facets, each raked further forward, shelling
    # the whole skull and meeting at a keel over the crown.
    box(bm, (0, 0.08, 0.10), (2 * hw + 0.20, 2 * hd + 0.16, hh * 1.50),
        Matrix.Rotation(math.radians(6), 3, "X"))
    box(bm, (0, 0.14, 0.56), (2 * hw - 0.04, 2 * hd - 0.08, hh * 0.62),
        Matrix.Rotation(math.radians(14), 3, "X"))
    # Lower casque: an arc of plates round the jaw, left OPEN at the front so
    # the face stays clear.
    _arc_plates(bm, 6, hw + 0.16, hd + 0.16, -0.42, (0.34, 0.16, 0.44),
            math.radians(-24), math.radians(204))
    # Crown keel plus two flanking facet chips.
    _ah_shard(bm, (0, 0.10, 0.86), (0.18, 1.14, 0.36),
              Matrix.Rotation(math.radians(180), 3, "X"), taper=0.3)
    for side in (-1, 1):
        _ah_shard(bm, (side * 0.36, 0.12, 0.78), (0.26, 0.84, 0.24),
                  Matrix.Rotation(math.radians(180), 3, "X") @ Matrix.Rotation(math.radians(side * 12), 3, "Y"),
                  taper=0.3)

    # The eye seam: a raked brow plate over a blunt muzzle plate with a narrow
    # open band between them - that band is the glow slit. Both stay above the
    # head's middle so the face proper is clear.
    box(bm, (0, -(hd + 0.16), 0.38), (2 * hw + 0.04, 0.32, 0.28),
        Matrix.Rotation(math.radians(-16), 3, "X"))
    box(bm, (0, -(hd + 0.10), 0.06), (2 * hw - 0.10, 0.26, 0.10),
        Matrix.Rotation(math.radians(-8), 3, "X"))
    # A thin lit bar recessed inside the slit.
    box(bm, (0, -(hd + 0.02), 0.20), (2 * hw - 0.28, 0.10, 0.06))

    # Twin back-swept horns: two faceted segments each, thick where they leave
    # the casque and sweeping up then back to a point.
    for side in (-1, 1):
        limb(bm, (side * 0.40, 0.16, 0.44), (side * 0.62, 0.80, 1.00), 0.20, 0.13, sides=4)
        limb(bm, (side * 0.62, 0.80, 1.00), (side * 0.74, 1.54, 0.80), 0.13, 0.03, sides=4)
        # A barb where each horn leaves the casque, and a facet chip behind it.
        _ah_shard(bm, (side * 0.50, 0.40, 0.62), (0.18, 0.34, 0.26),
                  Matrix.Rotation(math.radians(150), 3, "X"), taper=0.1)
        _ah_shard(bm, (side * 0.66, 0.98, 0.86), (0.14, 0.30, 0.22),
                  Matrix.Rotation(math.radians(150), 3, "X"), taper=0.1)
    # Raked cheek plates tucked against the jaw, outboard of the face opening.
    for side in (-1, 1):
        _ah_shard(bm, (side * (hw + 0.10), -0.04, -0.16), (0.18, 0.86, 0.52),
                  Matrix.Rotation(math.radians(side * -8), 3, "Y"), taper=0.3)
    # Neck scales stepping down the back of the helm.
    for i in range(3):
        box(bm, (0, hd + 0.16 - i * 0.03, -0.16 - i * 0.24), (0.82 - i * 0.14, 0.18, 0.22),
            Matrix.Rotation(math.radians(10), 3, "X"))
    return finish("Cindershell_Helm", bm, CINDER_PLATE)


def build_cindershell_chest():
    bm = bmesh.new()
    tw, td, th = UPPER_TORSO.x / 2, UPPER_TORSO.y / 2, UPPER_TORSO.z / 2
    # Molten under-body: a plain slab UNDER the plates. It is never covered
    # completely - the gaps between the scale rows are where it shows, and
    # that showing IS the magma crack.
    box(bm, (0, 0, 0), (2 * tw + 0.02, 2 * td + 0.04, 2 * th - 0.06))
    # Dragon-scale rows: four rows of five plates across the front, each row
    # staggered half a plate against the row above and raked further out.
    for row in range(4):
        z = th * 0.66 - row * 0.42
        n = 4 if row % 2 else 5
        for i in range(n):
            t = (i - (n - 1) / 2) / max(n - 1, 1)
            x = t * 1.52
            y = -(td + 0.20 + 0.10 * (1.0 - abs(t)))
            rot = (
                Matrix.Rotation(math.radians(-t * 26), 3, "Z")
                @ Matrix.Rotation(math.radians(16 + row * 2), 3, "X")
            )
            _ah_shard(bm, (x, y, z), (0.50, 0.22, 0.50), rot, taper=0.42)
    # Scale columns wrapping onto each flank, so the sides are plated too.
    for side in (-1, 1):
        for row in range(3):
            _ah_shard(bm, (side * (tw + 0.10), -0.24 + row * 0.30, th * 0.50 - row * 0.44),
                      (0.20, 0.46, 0.46),
                      Matrix.Rotation(math.radians(side * -14), 3, "Y")
                      @ Matrix.Rotation(math.radians(14), 3, "X"),
                      taper=0.42)
    # Two blunter rows across the back.
    for row in range(2):
        for i in range(3):
            x = (i - 1) * 0.66
            _ah_shard(bm, (x, td + 0.22, th * 0.44 - row * 0.60), (0.62, 0.20, 0.56),
                      Matrix.Rotation(math.radians(-12), 3, "X"), taper=0.5)
    # Shoulders: a faceted pad with smoke-vent nubs standing on it (inside the
    # arm swing arc).
    for side in (-1, 1):
        box(bm, (side * (tw + 0.10), 0.02, th * 0.72), (0.34, 2 * td + 0.30, 0.26),
            Matrix.Rotation(math.radians(side * -12), 3, "Y"))
        for k in range(3):
            y = -0.34 + k * 0.34
            limb(bm, (side * (tw + 0.12), y, th * 0.84), (side * (tw + 0.14), y, th * 1.04), 0.10, 0.07, sides=6)
    return finish("Cindershell_Chest", bm, CINDER_PLATE)


def build_cindershell_legs():
    bm = bmesh.new()
    # Slab belt of cooled lava, on a square under-block so the hip's corners
    # never poke through the fauld ring.
    box(bm, (0, 0, 0.18), (2.18, 1.20, 0.28))
    box(bm, (0, 0, -0.20), (2.06, 1.08, 0.52))
    # Spade faulds: eight broad plates that come to a blunt spade point, with
    # a shorter overlapping course above so the seams between them read deep.
    for i in range(8):
        a = (i / 8) * TAU + math.pi / 8
        x, y = math.cos(a) * 1.06, math.sin(a) * 0.62
        rot = Matrix.Rotation(-a + math.pi / 2, 3, "Z") @ Matrix.Rotation(math.radians(9), 3, "X")
        _ah_shard(bm, (x, y, -0.36), (0.56, 0.18, 0.74), rot, taper=0.36)
    for i in range(8):
        a = (i / 8) * TAU
        x, y = math.cos(a) * 1.00, math.sin(a) * 0.58
        rot = Matrix.Rotation(-a + math.pi / 2, 3, "Z") @ Matrix.Rotation(math.radians(6), 3, "X")
        _ah_shard(bm, (x, y, -0.06), (0.46, 0.16, 0.46), rot, taper=0.5)
    # A live seam down the front of each thigh: a narrow bar standing proud in
    # the gap the faulds leave open.
    for side in (-1, 1):
        box(bm, (side * 0.52, -0.72, -0.42), (0.12, 0.16, 0.72),
            Matrix.Rotation(math.radians(6), 3, "X"))
        box(bm, (side * 0.52, -0.70, -0.86), (0.10, 0.14, 0.22))
    return finish("Cindershell_Legs", bm, CINDER_GLOW)


# ---------------------------------------------------------------- Duskveil
# Gloomtrench: an ABYSSAL ASSASSIN dressed by an anglerfish. Thin swept silk,
# nothing bulky, everything raked to a point - and one lure lamp drooping off
# the brow, the set's single glow accent.

DUSK_HIDE = (0.16, 0.15, 0.22)
DUSK_SILK = (0.29, 0.24, 0.42)


def build_duskveil_helm():
    bm = bmesh.new()
    hw, hd, hh = HEAD.x / 2, HEAD.y / 2, HEAD.z / 2
    # Thin hood: a shell of narrow panels over the crown, down the back and
    # along both temples - open across the face, and swept to a tail behind.
    box(bm, (0, 0.06, 0.44), (2 * hw + 0.14, 2 * hd + 0.10, 0.30),
        Matrix.Rotation(math.radians(6), 3, "X"))
    # Brow panel: the hood pulled down over the forehead, stopping above the
    # head's middle so the face below stays open.
    box(bm, (0, -(hd + 0.04), 0.34), (2 * hw + 0.02, 0.16, 0.44),
        Matrix.Rotation(math.radians(-5), 3, "X"))
    box(bm, (0, hd + 0.14, -0.06), (2 * hw + 0.06, 0.20, 2 * hh - 0.06))
    for side in (-1, 1):
        box(bm, (side * (hw + 0.09), 0.06, -0.08), (0.16, 2 * hd + 0.08, 2 * hh - 0.22),
            Matrix.Rotation(math.radians(side * -3), 3, "Y"))
    limb(bm, (0, hd * 0.4, 0.48), (0, hd + 0.86, 0.12), 0.30, 0.04, sides=5)
    # Hood brow rim: an arc that stops well short of the front centre.
    _arc_plates(bm, 6, hw + 0.16, hd + 0.20, 0.24, (0.30, 0.10, 0.36),
            math.radians(-26), math.radians(206))
    # The angler lure: a stalk arching up off the brow, forward, then drooping
    # under its own weight with the lamp hanging on the end. It hangs in FRONT
    # of the forehead - never down over the face.
    limb(bm, (0, -(hd - 0.10), 0.54), (0, -(hd + 0.24), 0.98), 0.08, 0.06, sides=4)
    limb(bm, (0, -(hd + 0.24), 0.98), (0, -(hd + 0.70), 1.02), 0.06, 0.05, sides=4)
    limb(bm, (0, -(hd + 0.70), 1.02), (0, -(hd + 0.84), 0.74), 0.05, 0.04, sides=4)
    ellipsoid(bm, (0, -(hd + 0.86), 0.58), (0.17, 0.17, 0.18))
    _ah_lump(bm, (0, -(hd + 0.86), 0.40), (0.07, 0.07, 0.09))
    # A cluster of small dead eyes on one temple, no two the same size.
    eyes = ((-0.04, 0.32, 0.10), (0.20, 0.16, 0.08), (0.14, 0.46, 0.06),
            (0.38, 0.34, 0.06), (0.32, 0.04, 0.05))
    for ey, ez, er in eyes:
        _ah_lump(bm, (-(hw + 0.16), ey, ez), (er, er, er))
    # Silk falling down the back of the hood: two thin staggered panels, the
    # lower one cut to a point.
    box(bm, (0, hd + 0.28, -0.34), (2 * hw - 0.14, 0.07, 0.78),
        Matrix.Rotation(math.radians(-6), 3, "X"))
    _ah_shard(bm, (0.08, hd + 0.34, -0.92), (0.60, 0.06, 0.58), taper=0.15)
    return finish("Duskveil_Helm", bm, DUSK_HIDE)


def build_duskveil_chest():
    bm = bmesh.new()
    tw, td, th = UPPER_TORSO.x / 2, UPPER_TORSO.y / 2, UPPER_TORSO.z / 2
    # Close under-wrap - the set is THIN, this barely stands off the body.
    box(bm, (0, 0, 0.02), (2 * tw + 0.04, 2 * td + 0.04, 2 * th - 0.10))
    # Layered silk drapes crossing the front asymmetrically: three wide sashes
    # at three different rakes, each proud of the last, so the front never
    # reads as a single plate.
    drapes = ((0.12, -36, 0.36, 2.02, 0.60), (-0.10, -19, -0.04, 2.12, 0.54),
              (0.16, -29, -0.46, 1.90, 0.46))
    for i, (dx, ang, z, w, h) in enumerate(drapes):
        box(bm, (dx, -(td + 0.09 + i * 0.06), z), (w, 0.10, h),
            Matrix.Rotation(math.radians(ang), 3, "Y"))
    # A counter-drape crossing the other way over the left ribs, and its
    # pointed tail hanging past the hem.
    box(bm, (-0.42, -(td + 0.27), 0.08), (1.02, 0.09, 0.34),
        Matrix.Rotation(math.radians(36), 3, "Y"))
    _ah_shard(bm, (-0.62, -(td + 0.24), -0.86), (0.36, 0.08, 0.52),
              Matrix.Rotation(math.radians(-8), 3, "X"), taper=0.12)
    # Faint pinstripe marks scored down one sash only.
    for k in range(3):
        box(bm, (-0.10 + k * 0.30, -(td + 0.33), 0.30), (0.05, 0.05, 0.52),
            Matrix.Rotation(math.radians(-36), 3, "Y"))
    # Pointed silk hem: torn fin tips along the bottom of the wrap.
    for k in range(5):
        _ah_shard(bm, (-0.72 + k * 0.36, -(td + 0.16), -0.92), (0.32, 0.08, 0.44),
                  Matrix.Rotation(math.radians(-6 + k * 3), 3, "X"), taper=0.12)
    # Back: one long silk fall, carried past the hem.
    box(bm, (0.06, td + 0.12, -0.08), (2 * tw - 0.16, 0.10, 2 * th - 0.16),
        Matrix.Rotation(math.radians(4), 3, "Y"))
    # High collar, standing tall and cut higher at the back than the front.
    _band(bm, th * 0.86, 0.58, 0.50, 0.42, 0.86, segments=9)
    _ah_shard(bm, (0, 0.54, th * 1.14), (0.66, 0.10, 0.44),
              Matrix.Rotation(math.radians(166), 3, "X"), taper=0.2)
    for side in (-1, 1):
        _ah_shard(bm, (side * 0.42, 0.20, th * 1.06), (0.28, 0.09, 0.34),
                  Matrix.Rotation(math.radians(180), 3, "X") @ Matrix.Rotation(math.radians(side * 16), 3, "Y"),
                  taper=0.2)
    # Thin shoulder drape edges (well inside the arm swing arc).
    for side in (-1, 1):
        _ah_shard(bm, (side * (tw + 0.10), 0.04, th * 0.66), (0.22, 0.94, 0.56),
                  Matrix.Rotation(math.radians(side * -10), 3, "Y"), taper=0.25)
    return finish("Duskveil_Chest", bm, DUSK_HIDE)


def build_duskveil_legs():
    bm = bmesh.new()
    # Narrow hip cord on a thin under-wrap - the drapes hang off it, and the
    # wrap is a box so the hip's corners never show through the silk.
    box(bm, (0, 0, 0.10), (2.02, 1.06, 0.20))
    box(bm, (0, 0, -0.22), (1.96, 1.00, 0.50))
    # Torn-fin drapes: nine pointed panels, each cut longer the further back
    # it sits, so the hem sweeps up at the front and trails behind.
    for i in range(9):
        a = (i / 9) * TAU + 0.16
        back = 0.5 + 0.5 * math.sin(a)  # 1 at the back (+Y), 0 at the front
        ln = 0.82 + 0.66 * back
        x, y = math.cos(a) * 1.04, math.sin(a) * 0.62
        rot = Matrix.Rotation(-a + math.pi / 2, 3, "Z") @ Matrix.Rotation(math.radians(5), 3, "X")
        _ah_shard(bm, (x, y, 0.02 - ln / 2), (0.46, 0.09, ln), rot, taper=0.10)
    # A second, shorter inner layer offset half a panel, and a third shorter
    # still - the silk reads as torn layers rather than one skirt.
    for count, rx, ry, base, span, size in ((7, 0.98, 0.58, 0.56, 0.46, 0.36),
                                            (5, 0.92, 0.54, 0.36, 0.30, 0.30)):
        for i in range(count):
            a = (i / count) * TAU + 0.16 + math.pi / 9
            back = 0.5 + 0.5 * math.sin(a)
            ln = base + span * back
            x, y = math.cos(a) * rx, math.sin(a) * ry
            rot = Matrix.Rotation(-a + math.pi / 2, 3, "Z") @ Matrix.Rotation(math.radians(3), 3, "X")
            _ah_shard(bm, (x, y, 0.0 - ln / 2), (size, 0.07, ln), rot, taper=0.12)
    # Two long tails trailing off the back corners.
    for side in (-1, 1):
        _ah_shard(bm, (side * 0.44, 0.66, -0.86), (0.26, 0.07, 1.50),
                  Matrix.Rotation(math.radians(-7), 3, "X"), taper=0.06)
    return finish("Duskveil_Legs", bm, DUSK_SILK)


def check_faces(objects):
    """Enforce the header's FACE BOX. Prints offenders; never throws, so a
    half-built set still exports and can be looked at."""
    offenders = {}
    for obj in objects:
        if not obj.name.endswith("_Helm"):
            continue
        for vert in obj.data.vertices:
            x, y, z = vert.co
            if y <= -0.52 and abs(x) <= 0.40 and -0.60 <= z <= 0.00:
                entry = offenders.setdefault(obj.name, [0, None])
                entry[0] += 1
                if entry[1] is None or y < entry[1][1]:
                    entry[1] = (round(x, 2), round(y, 2), round(z, 2))
    if not offenders:
        print("FACE BOX: clear - every helm leaves the face open below the brow")
        return
    for name, (count, worst) in sorted(offenders.items()):
        print("FACE BOX VIOLATION: %s has %d vert(s) below the brow line, deepest at %s" % (name, count, worst))


# ---------------------------------------------------------------- registry


# ------------------------------------------------------- late-set palettes
# Palette: base colours are the set rows' Color3.fromRGB values / 255; the
# second colour of each pair is the preview accent (the piece whose read is
# the trim, not the plate), same trick as CHITIN_PALE.
TIDEWARD_SCALE = (0.588, 0.690, 0.761)
TIDEWARD_PEARL = (0.910, 0.925, 0.898)
CORSAIR_PLANK = (0.376, 0.463, 0.439)
CORSAIR_SAIL = (0.620, 0.655, 0.620)
STORM_GLASS = (0.471, 0.627, 0.784)
STORM_ARC = (0.850, 0.910, 1.000)
WRAITH_SHROUD = (0.525, 0.588, 0.659)
WRAITH_AURORA = (0.430, 0.760, 0.700)


# ---------------------------------------------------------------- Tideward
# THE FISHERFOLK CHAMPION - what a village forges out of the day's catch.
# A sou'wester armoured in fish scales, cork floats strung across the chest
# like a bandolier, a scale skirt on a rope belt with a hook charm swinging
# off it.  Working gear promoted to war gear; every read is FORM, since in
# game the whole piece is one flat colour.


def build_tideward_helm():
    bm = bmesh.new()
    hw, hd, hh = HEAD.x / 2, HEAD.y / 2, HEAD.z / 2
    # Skull cap under the scales.
    ellipsoid(bm, (0, 0.06, hh * 0.44), (hw + 0.10, hd + 0.12, hh * 0.86))
    # Three shingled scale rows over the crown and sides, open across the
    # face.  Each row is set wider and tilts harder, so the head reads as a
    # fish's flank curving away.
    for row in range(3):
        _arc_plates(
            bm,
            5 + row,
            hw + 0.10 + row * 0.04,
            hd + 0.11 + row * 0.04,
            hh * (0.72 - row * 0.34),
            (0.42 - row * 0.02, 0.15, 0.34),
            math.radians(26),
            math.radians(154),
            tilt=18 + row * 7,
        )
    # THE SILHOUETTE: a sou'wester brim.  One overlapping ring of plates whose
    # radius and droop both grow toward the back - short peak over the brow,
    # long rain-shedding duck-tail behind.  (back: 0 at the face, 1 at the nape)
    segs = 11
    for i in range(segs):
        a = -math.pi / 2 + (i / segs) * TAU
        back = (math.sin(a) + 1.0) * 0.5
        r = 0.80 + 0.40 * back
        z = 0.24 - 0.60 * back
        rot = Matrix.Rotation(-a + math.pi / 2, 3, "Z") @ Matrix.Rotation(math.radians(16 + 46 * back), 3, "X")
        box(bm, (math.cos(a) * r, math.sin(a) * r * 0.92, z), (0.60 + 0.14 * back, 0.15, 0.34 + 0.30 * back), rot)
    # The tail itself: the brim's back edge carried on down over the nape.
    box(bm, (0, hd + 0.50, -hh * 0.80), (HEAD.x * 0.86, 0.11, hh * 0.66), Matrix.Rotation(math.radians(-38), 3, "X"))
    # Storm cord: the chin tie knotted up at the left temple, off the face.
    box(bm, (-(hw + 0.14), -hd * 0.16, hh * 0.02), (0.10, 0.48, 0.10), Matrix.Rotation(math.radians(-12), 3, "X"))
    ellipsoid(bm, (-(hw + 0.20), -hd * 0.42, -hh * 0.10), (0.10, 0.10, 0.10), subdiv=0)
    return finish("Tideward_Helm", bm, TIDEWARD_SCALE)


def build_tideward_chest():
    bm = bmesh.new()
    tw, td, th = UPPER_TORSO.x / 2, UPPER_TORSO.y / 2, UPPER_TORSO.z / 2
    ysq = (td + 0.10) / (tw + 0.06)
    # Scale plates: four lamellar bands overlapping top to bottom, so the
    # torso is covered edge to edge and reads as rows, not slabs.
    for row in range(4):
        _band(bm, th * 0.66 - row * 0.42, tw + 0.11, tw + 0.02, 0.46, ysq)
    # Three big scales riveted across the front of the upper three bands.
    for row in range(3):
        for i in range(3):
            box(
                bm,
                ((i - 1) * 0.62, -(td + 0.19), th * 0.66 - row * 0.42 - 0.08),
                (0.56, 0.12, 0.32),
                Matrix.Rotation(math.radians(16), 3, "X"),
            )
    # NETTING stretched over the plates: a thin diamond lattice, four cords.
    for sign in (-1, 1):
        for k in (-1, 1):
            box(
                bm,
                (k * 0.44, -(td + 0.26), -0.02),
                (0.06, 0.06, 1.78),
                Matrix.Rotation(math.radians(sign * 33), 3, "Y"),
            )
    # CORK FLOATS: a bandolier of barrel corks from the right shoulder down to
    # the left hip, riding clear on top of everything - the set's loudest tell.
    a, b = Vector((0.76, -(td + 0.42), th * 0.80)), Vector((-0.72, -(td + 0.34), -th * 0.96))
    limb(bm, a, b, 0.07, 0.07, sides=4)
    for i in range(5):
        p = a.lerp(b, 0.10 + i * 0.20)
        d = (b - a).normalized() * 0.14
        limb(bm, p - d, p + d, 0.24, 0.24, sides=6)
    # ROPE SHOULDER WRAPS: cord coiled OVER each shoulder, riding proud of the
    # arm's top so it reads from the front.
    for side in (-1, 1):
        for k in range(3):
            x0 = side * (0.74 + k * 0.20)
            limb(bm, (x0, 0.0, th + 0.05), (x0 + side * 0.15, 0.0, th + 0.05), 0.20, 0.20, sides=6)
    return finish("Tideward_Chest", bm, TIDEWARD_SCALE)


def build_tideward_legs():
    bm = bmesh.new()
    # ROPE BELT: a fat squashed cord ring with a knot at the front-right.
    _band(bm, 0.14, HIP_W / 2 + 0.10, HIP_W / 2 + 0.10, 0.20, 0.58, segments=10)
    ellipsoid(bm, (0.34, -0.66, 0.14), (0.17, 0.13, 0.16), subdiv=0)
    # FISH-SCALE SKIRT: two staggered rings of broad scales, the lower row
    # longer, so the hem shingles like a tail.
    _band(bm, -0.06, 1.12, 0.99, 0.44, 0.62, segments=10)
    _band(bm, -0.50, 1.24, 1.09, 0.46, 0.62, segments=10)
    _ring_plates(bm, 9, 1.10, 0.74, -0.10, (0.52, 0.17, 0.40), tilt=13)
    _ring_plates(bm, 9, 1.18, 0.82, -0.54, (0.50, 0.17, 0.44), tilt=18, a0=math.pi / 9)
    # THE HOOK CHARM: a line off the belt at the right hip, then a real fish
    # hook - shank, bend, and an upswept barb.
    limb(bm, (0.66, -0.56, 0.06), (0.66, -0.62, -0.50), 0.035, 0.035, sides=4)
    box(bm, (0.66, -0.62, -0.72), (0.08, 0.08, 0.38))
    for k in range(4):
        a = math.pi * (0.06 + 0.30 * k)
        box(
            bm,
            (0.66 + math.sin(a) * 0.19, -0.62, -0.91 - math.cos(a) * 0.19),
            (0.09, 0.08, 0.19),
            Matrix.Rotation(a, 3, "Y"),
        )
    cone(bm, (0.34, -0.62, -0.96), (0.42, -0.62, -0.66), 0.07, sides=4)
    return finish("Tideward_Legs", bm, TIDEWARD_PEARL)


# ------------------------------------------------------------ Corsair's Rest
# THE GHOST-FLEET BULWARK - you do not wear salvage, you wear the SHIP.  A
# tricorne helm with a figurehead riding the crown, a ship's PROW for a
# breastplate (planking meeting at a stem line, gunports, an anchor at the
# sternum) and hull-strake faulds trailing a length of chain.


def build_corsairsrest_helm():
    bm = bmesh.new()
    hw, hd, hh = HEAD.x / 2, HEAD.y / 2, HEAD.z / 2
    # Low crown sitting on the skull.
    ellipsoid(bm, (0, 0.04, hh * 0.62), (hw * 0.98, hd * 0.98, hh * 0.66))
    # Helm proper under the hat: cheek and nape plates round the sides and
    # back, stopping well clear of the face.
    _arc_plates(bm, 6, hw + 0.13, hd + 0.13, -hh * 0.34, (0.40, 0.13, 0.62), math.radians(22), math.radians(158), tilt=6)
    box(bm, (0, hd + 0.22, -hh * 0.10), (HEAD.x * 0.86, 0.14, hh * 0.90))
    # THE TRICORNE.  One ring of brim plates whose height rides a cos(3a)
    # wave: three pinned-up corners, three waterlogged sags between them -
    # the whole hat in one loop.
    segs = 15
    for i in range(segs):
        a = -math.pi / 2 + (i / segs) * TAU
        wave = math.cos(3.0 * (a + math.pi / 2))  # +1 at each pinned corner
        r = 0.86 + 0.20 * max(wave, 0.0)
        z = hh * 0.34 + 0.19 * wave
        rot = Matrix.Rotation(-a + math.pi / 2, 3, "Z") @ Matrix.Rotation(math.radians(-26 * wave), 3, "X")
        box(bm, (math.cos(a) * r, math.sin(a) * r * 0.90, z), (0.44, 0.13, 0.40), rot)
    # The three corners pinned up into standing folds.
    for k in range(3):
        a = -math.pi / 2 + k * (TAU / 3)
        rot = Matrix.Rotation(-a + math.pi / 2, 3, "Z") @ Matrix.Rotation(math.radians(-58), 3, "X")
        box(bm, (math.cos(a) * 0.92, math.sin(a) * 0.83, hh * 0.86), (0.78, 0.11, 0.44), rot)
    # Hat band, and a doubloon pinned at the left corner.
    limb(bm, (0, 0.02, hh * 0.44), (0, 0.02, hh * 0.60), hw + 0.09, hw + 0.09, sides=8)
    ellipsoid(bm, (-(hw + 0.16), -hd * 0.50, hh * 0.52), (0.12, 0.11, 0.12), subdiv=0)
    # THE FIGUREHEAD CREST: a tiny prow bust leaning out over the brow -
    # arched neck, small head, two swept-back hair fins.  Rides high and
    # forward, entirely above the brow line.
    limb(bm, (0, -0.22, hh * 0.86), (0, -0.86, hh * 1.46), 0.19, 0.13, sides=5)
    box(bm, (0, -0.99, hh * 1.60), (0.30, 0.38, 0.30), Matrix.Rotation(math.radians(-26), 3, "X"))
    cone(bm, (0, -1.10, hh * 1.52), (0, -1.34, hh * 1.44), 0.10, sides=4)
    for side in (-1, 1):
        cone(bm, (side * 0.12, -0.90, hh * 1.74), (side * 0.30, -0.18, hh * 2.02), 0.10, sides=4)
    return finish("CorsairsRest_Helm", bm, CORSAIR_PLANK)


def build_corsairsrest_chest():
    bm = bmesh.new()
    tw, td, th = UPPER_TORSO.x / 2, UPPER_TORSO.y / 2, UPPER_TORSO.z / 2
    # THE PROW.  Five strakes per side, each swept back from a shared stem
    # line at x = 0 out to the ribs - so the chest comes to a POINT forward
    # exactly the way a bow does.
    for side in (-1, 1):
        for i in range(5):
            box(
                bm,
                (side * (0.50 - i * 0.02), -(td + 0.20) - (i % 2) * 0.06, th * (0.68 - i * 0.36)),
                (1.10 - i * 0.07, 0.17, 0.27),
                Matrix.Rotation(math.radians(side * 26), 3, "Z"),
            )
    # The stem: the cutwater running the full height of the sternum, with a
    # small beak raking forward at the top.
    box(bm, (0, -(td + 0.42), -0.06), (0.17, 0.26, UPPER_TORSO.z * 1.02))
    cone(bm, (0, -(td + 0.34), th * 0.62), (0, -(td + 0.78), th * 0.96), 0.13, sides=4)
    # TWO GUNPORTS: framed square ports set into the strakes, each with its
    # lit muzzle sitting proud in the middle.
    for side in (-1, 1):
        cx, cy, cz = side * 0.66, -(td + 0.30), th * 0.10
        for dx, dz in ((0.20, 0), (-0.20, 0), (0, 0.20), (0, -0.20)):
            box(bm, (cx + dx, cy, cz + dz), (0.44 if dz else 0.10, 0.10, 0.10 if dz else 0.44))
        ellipsoid(bm, (cx, cy - 0.05, cz), (0.13, 0.09, 0.13), subdiv=0)
    # THE ANCHOR-BUCKLE at the sternum, hung on the stem line.
    ax, ay, az = 0.0, -(td + 0.76), -th * 0.22
    box(bm, (ax, ay, az), (0.13, 0.14, 0.80))
    box(bm, (ax, ay, az + 0.32), (0.68, 0.13, 0.13))
    for side in (-1, 1):
        box(bm, (ax + side * 0.22, ay, az - 0.34), (0.46, 0.13, 0.13), Matrix.Rotation(math.radians(side * 34), 3, "Y"))
        cone(bm, (ax + side * 0.40, ay, az - 0.24), (ax + side * 0.52, ay, az + 0.04), 0.09, sides=4)
    limb(bm, (ax, ay - 0.05, az + 0.48), (ax, ay + 0.05, az + 0.48), 0.15, 0.15, sides=6)
    # Hull planking round the back, and a heavy salvaged waist strap.
    for i in range(4):
        box(bm, (0, td + 0.12, th * (0.60 - i * 0.42)), (UPPER_TORSO.x * 0.96, 0.16, 0.34))
    box(bm, (0, 0, -th * 0.92), (UPPER_TORSO.x + 0.24, UPPER_TORSO.y + 0.24, 0.20))
    # Gunwale pauldrons: two stepped plank courses capping each shoulder,
    # the outer one lower, like a rail turning down over the side.
    for side in (-1, 1):
        box(bm, (side * (tw - 0.02), 0.02, th + 0.12), (0.46, td * 1.9, 0.20))
        box(bm, (side * (tw + 0.11), 0.02, th - 0.04), (0.38, td * 1.6, 0.20), Matrix.Rotation(math.radians(side * -22), 3, "Y"))
    return finish("CorsairsRest_Chest", bm, CORSAIR_PLANK)


def build_corsairsrest_legs():
    bm = bmesh.new()
    # HULL-STRAKE FAULDS: two courses of hull planking bent round the hip,
    # the lower course longer, like a hull's run aft.
    box(bm, (0, 0, 0.16), (HIP_W + 0.22, 1.24, 0.24))
    _band(bm, -0.10, 1.14, 1.02, 0.48, 0.62, segments=10)
    _band(bm, -0.58, 1.24, 1.12, 0.52, 0.62, segments=10)
    _ring_plates(bm, 8, 1.12, 0.74, -0.12, (0.56, 0.16, 0.46), tilt=6)
    _ring_plates(bm, 8, 1.20, 0.82, -0.60, (0.54, 0.16, 0.50), tilt=10, a0=math.pi / 8)
    # BARNACLE LINES: crusted growth along two waterlines round the faulds.
    for k, (rr, zz) in enumerate(((1.18, -0.30), (1.26, -0.74))):
        for i in range(3):
            a = (i / 3) * TAU + k * 0.5
            ellipsoid(bm, (math.cos(a) * rr, math.sin(a) * rr * 0.68, zz), (0.12, 0.12, 0.09), subdiv=0)
    # THE HANGING CHAIN: three links off the left hip, each turned ninety
    # degrees from the last so they read as interlocked.
    for k in range(3):
        z = -0.74 - k * 0.26
        flat = k % 2 == 0  # link lies in the XZ plane, then the YZ plane
        for dx, dz in ((0.12, 0), (-0.12, 0), (0, 0.13), (0, -0.13)):
            size = (0.28 if dz else 0.07, 0.07, 0.07 if dz else 0.26)
            if not flat:
                size = (0.07, 0.28 if dz else 0.07, 0.07 if dz else 0.26)
            off = (dx, 0.0) if flat else (0.0, dx)
            box(bm, (-0.86 + off[0], -0.52 + off[1], z + dz), size)
    return finish("CorsairsRest_Legs", bm, CORSAIR_SAIL)


# ---------------------------------------------------------------- Stormcaller
# Storm glass: everything faceted and angular, cut flat - and one zigzag of
# caged lightning per piece, the Stormlance's tell.


def _zigzag_plates(bm, start, run, rise, steps, size, y, tilt=26.0):
    """A lightning seam: alternating slanted bars marching along +X."""
    for i in range(steps):
        x = start + run * i
        z = rise * (0.5 - (i % 2))
        rot = Matrix.Rotation(math.radians(tilt if i % 2 == 0 else -tilt), 3, "Y")
        box(bm, (x, y, z), size, rot)


def build_stormcaller_helm():
    bm = bmesh.new()
    hw, hd, hh = HEAD.x / 2, HEAD.y / 2, HEAD.z / 2
    # A sleek swept skull, low and raked back.
    ellipsoid(bm, (0, 0.12, hh * 0.30), (hw + 0.12, hd + 0.20, hh * 1.06))
    # Brow visor: one wedge riding above the eyes, coming to a point forward.
    box(bm, (0, -(hd + 0.12), hh * 0.38), (HEAD.x + 0.14, 0.28, 0.26), Matrix.Rotation(math.radians(-16), 3, "X"))
    cone(bm, (0, -(hd + 0.18), hh * 0.38), (0, -(hd + 0.62), hh * 0.26), 0.15, sides=4)
    # Nape guard closing the helm off behind.
    box(bm, (0, hd + 0.26, -hh * 0.40), (HEAD.x * 0.84, 0.14, hh * 0.72), Matrix.Rotation(math.radians(-10), 3, "X"))
    # THE CLOUD-SPIRAL CREST.  Nine broad vanes walked round a shrinking
    # spiral in the profile plane: it lifts off the nape, sweeps up over the
    # crown and curls in on itself - a scroll of cloud, and a tall fin from
    # any angle because the vanes are wide across the head, not thin.
    for i in range(9):
        t = i / 8.0
        phi = -1.30 + 5.70 * t
        r = 0.95 - 0.74 * t
        box(
            bm,
            (0, 0.30 + math.cos(phi) * r, 0.86 + math.sin(phi) * r),
            (0.72 - 0.46 * t, 0.15, 0.52 - 0.26 * t),
            Matrix.Rotation(phi, 3, "X"),
        )
    # Cheek plates, raked back off the visor, well clear of the face.
    for side in (-1, 1):
        box(
            bm,
            (side * (hw + 0.11), 0.06, -hh * 0.22),
            (0.15, hd * 1.7, hh * 1.14),
            Matrix.Rotation(math.radians(side * 8), 3, "Z"),
        )
    # TWO LIGHTNING-PRONG ANTENNAE off the temples: a jointed bolt each,
    # kinking back and up off the helm's sides into a fine point.
    for side in (-1, 1):
        pts = (
            (side * 0.58, -0.14, 0.26),
            (side * 0.90, 0.16, 0.56),
            (side * 0.60, 0.46, 0.90),
            (side * 0.92, 0.74, 1.26),
        )
        for k in range(3):
            limb(bm, pts[k], pts[k + 1], 0.11, 0.10, sides=4)
        cone(bm, pts[3], (side * 1.06, 0.90, 1.62), 0.10, sides=4)
    return finish("Stormcaller_Helm", bm, STORM_GLASS)


def build_stormcaller_chest():
    bm = bmesh.new()
    tw, td, th = UPPER_TORSO.x / 2, UPPER_TORSO.y / 2, UPPER_TORSO.z / 2
    # WIND-SWEPT PLATES.  Six streaks across the chest, every one raked the
    # SAME way - leaning right and trailing back - and each one stepped a
    # little higher and shorter than the last.  Nothing is mirrored, so the
    # torso reads as caught mid-gust.
    for i in range(7):
        box(
            bm,
            (-0.82 + i * 0.30, -(td + 0.17) + i * 0.012, -0.50 + i * 0.17),
            (0.30, 0.17, 1.20 - i * 0.10),
            Matrix.Rotation(math.radians(-34), 3, "Y") @ Matrix.Rotation(math.radians(15), 3, "X"),
        )
    # Under-shell so no bare torso shows between the streaks, and a collar
    # raked the same way.
    box(bm, (0, 0, -0.10), (UPPER_TORSO.x + 0.04, UPPER_TORSO.y + 0.06, UPPER_TORSO.z * 0.80))
    box(bm, (0.06, 0.02, th + 0.06), (1.30, td * 1.7, 0.24), Matrix.Rotation(math.radians(-16), 3, "Y"))
    # Back plates, raked the same way.
    for i in range(3):
        box(
            bm,
            (-0.58 + i * 0.58, td + 0.13, -0.30 + i * 0.24),
            (0.44, 0.15, 1.10 - i * 0.16),
            Matrix.Rotation(math.radians(-30), 3, "Y"),
        )
    # THE STORM-GLASS CORE: a cut octahedron set at the sternum in a collar of
    # small facets - the one still thing on a moving chest.
    gx, gy, gz = -0.12, -(td + 0.54), th * 0.26
    cone(bm, (gx, gy, gz), (gx, gy, gz + 0.42), 0.31, sides=4)
    cone(bm, (gx, gy, gz), (gx, gy, gz - 0.42), 0.31, sides=4)
    for k in range(5):
        a = math.radians(18) + k * TAU / 5
        box(bm, (gx + math.cos(a) * 0.38, gy + 0.16, gz + math.sin(a) * 0.38), (0.22, 0.16, 0.22), Matrix.Rotation(a, 3, "Y"))
    # TRAILING FIN BLADES off the shoulders - two per side, swept back and
    # riding above the arm's top so they read.  Inside the arm arc.
    for side in (-1, 1):
        for k in range(2):
            box(
                bm,
                (side * (tw + 0.06 + k * 0.14), 0.46 + k * 0.22, th + 0.04 - k * 0.30),
                (0.16, 1.00 + k * 0.36, 0.30),
                Matrix.Rotation(math.radians(-18 - k * 10), 3, "X") @ Matrix.Rotation(math.radians(side * -10), 3, "Y"),
            )
    # The caged-lightning seam, riding the leading edge of the streaks.
    _zigzag_plates(bm, -0.66, 0.34, 0.44, 4, (0.28, 0.16, 0.44), -(td + 0.42), tilt=36)
    return finish("Stormcaller_Chest", bm, STORM_GLASS)


def build_stormcaller_legs():
    bm = bmesh.new()
    # SWEPT FIN FAULDS.  A ring of ten blades, but every one yawed the same
    # extra 34 degrees off its radius, so the whole skirt turns like a
    # vortex - wind-torn banners caught in one direction.
    box(bm, (0, 0, 0.18), (HIP_W + 0.10, 1.08, 0.16))
    _band(bm, -0.10, 1.04, 0.96, 0.46, 0.62, segments=10)
    _band(bm, -0.54, 1.10, 1.02, 0.46, 0.62, segments=10)
    for ring, (rr, ry, z, hgt, yaw, a0) in enumerate(
        ((0.90, 0.62, -0.26, 0.66, 24, 0.15), (0.94, 0.68, -0.76, 0.98, 32, 0.15 + TAU / 20))
    ):
        for i in range(10):
            a = (i / 10) * TAU + a0
            rot = (
                Matrix.Rotation(-a + math.pi / 2 + math.radians(yaw), 3, "Z")
                @ Matrix.Rotation(math.radians(16 + ring * 10), 3, "X")
            )
            box(bm, (math.cos(a) * rr, math.sin(a) * ry, z), (0.58, 0.14, hgt), rot)
    # Two long banner tails trailing off the back of the vortex.
    for side in (-1, 1):
        box(
            bm,
            (side * 0.44, 0.84, -0.76),
            (0.30, 0.13, 1.06),
            Matrix.Rotation(math.radians(34), 3, "X") @ Matrix.Rotation(math.radians(side * 14), 3, "Y"),
        )
    # A short lightning seam struck across the front-left of the hip.
    _zigzag_plates(bm, -0.56, 0.36, 0.30, 3, (0.24, 0.13, 0.34), -0.76, tilt=30)
    return finish("Stormcaller_Legs", bm, STORM_ARC)


# ---------------------------------------------------------------- Wraithbound
# BETWEEN WORLDS.  Every piece is split down the middle: the +X half is solid
# traveler's plate, the -X half has come apart into tattered wisps and
# fragments drifting free of the body.  This is the ONE set where separated
# floaters are the point - they all stay inside the clearance zones.


def build_wraithbound_helm():
    bm = bmesh.new()
    hw, hd, hh = HEAD.x / 2, HEAD.y / 2, HEAD.z / 2
    # SOLID HALF: two courses of plate wrapping the +X side of the skull,
    # front to nape, plus a cheek guard - all clear of the face.
    ellipsoid(bm, (0.42, 0.08, hh * 0.56), (0.82, 0.78, hh * 0.90))
    _arc_plates(bm, 5, hw + 0.14, hd + 0.16, hh * 0.42, (0.40, 0.15, 0.44), math.radians(-66), math.radians(104), tilt=10)
    _arc_plates(bm, 4, hw + 0.15, hd + 0.17, -hh * 0.14, (0.38, 0.15, 0.50), math.radians(-24), math.radians(100), tilt=6)
    box(bm, (hw + 0.14, -hd * 0.20, -hh * 0.52), (0.16, hd * 1.5, hh * 0.72))
    # THE SEAM: a keel ridge over the crown marking where the helm ends and
    # the dissolve begins.
    for i in range(3):
        box(bm, (0.03, -0.34 + i * 0.36, hh * (1.44 - i * 0.10)), (0.22, 0.36, 0.26), Matrix.Rotation(math.radians(6), 3, "X"))
    # DISSOLVING HALF: six fragments stepping out and up off the missing
    # side, each smaller and further adrift than the last.
    for i in range(6):
        t = i / 5.0
        s = 0.34 - 0.24 * t
        box(
            bm,
            (-(0.52 + 0.10 * i), 0.02 + 0.09 * i, hh * (0.62 + 0.16 * i - 0.02 * i * i)),
            (s, s * 0.7, s),
            Matrix.Rotation(math.radians(24 + 18 * i), 3, "Y") @ Matrix.Rotation(math.radians(12 * i), 3, "X"),
        )
    # Two phasing wisps trailing off the back-left, tapering as they go.
    for k in range(2):
        for j in range(3):
            box(
                bm,
                (-(0.34 + 0.10 * j + 0.12 * k), 0.44 + 0.30 * j, hh * (0.10 - 0.22 * j) + 0.16 * k),
                (0.22 - 0.05 * j, 0.30, 0.16 - 0.03 * j),
                Matrix.Rotation(math.radians(-16 - 10 * j), 3, "X"),
            )
    # THE ESSENCE BEAD: one glowing mote orbiting where the helm is missing.
    ellipsoid(bm, (-(hw + 0.34), -hd * 0.34, hh * 0.34), (0.16, 0.16, 0.16))
    ellipsoid(bm, (-(hw + 0.58), -hd * 0.02, hh * 0.70), (0.07, 0.07, 0.07), subdiv=0)
    return finish("Wraithbound_Helm", bm, WRAITH_SHROUD)


def build_wraithbound_chest():
    bm = bmesh.new()
    tw, td, th = UPPER_TORSO.x / 2, UPPER_TORSO.y / 2, UPPER_TORSO.z / 2
    # SOLID HALF-CUIRASS: a heavy shell over the +X side only, with a raised
    # collar half and a stepped pauldron - real armour, worn on one shoulder.
    box(bm, (0.54, 0, 0.02), (1.06, UPPER_TORSO.y + 0.22, UPPER_TORSO.z * 0.94))
    box(bm, (0.62, -(td + 0.20), 0.16), (0.74, 0.18, UPPER_TORSO.z * 0.62), Matrix.Rotation(math.radians(-7), 3, "Y"))
    box(bm, (0.42, 0.02, th + 0.10), (0.80, td * 1.6, 0.26))
    box(bm, (tw + 0.08, 0.02, th - 0.06), (0.42, td * 1.5, 0.24), Matrix.Rotation(math.radians(-26), 3, "Y"))
    limb(bm, (0.28, 0.02, th * 0.90), (0.30, 0.02, th * 1.14), 0.44, 0.36, sides=6)
    # THE DISSOLVE, read across the sternum: five shards stepping left, each
    # smaller, each with a wider gap in front of it.
    x = 0.04
    for i in range(5):
        sz = 0.46 - 0.06 * i
        x -= 0.14 + 0.03 * i
        box(
            bm,
            (x, -(td + 0.12) - 0.03 * i, 0.16 - 0.09 * i),
            (sz, 0.16, sz * 1.5),
            Matrix.Rotation(math.radians(-10 - 9 * i), 3, "Y"),
        )
    # RIBBONS: four tattered strips hanging off the missing side, no two the
    # same length or rake.
    for i, (hx, hz, hgt, rake) in enumerate(
        (
            (0.62, 0.44, 0.92, 2),
            (0.94, 0.30, 1.16, -8),
            (1.08, 0.10, 0.78, -16),
            (0.78, -0.16, 1.36, 6),
            (1.10, 0.34, 0.54, -18),
        )
    ):
        box(
            bm,
            (-hx, -0.10 + 0.16 * (i % 2), hz - hgt / 2),
            (0.20, 0.12, hgt),
            Matrix.Rotation(math.radians(rake), 3, "Y") @ Matrix.Rotation(math.radians(6 * i), 3, "X"),
        )
    # Free-floating fragments off the left, drifting clear of the body.
    for i in range(4):
        sz = 0.26 - 0.045 * i
        box(
            bm,
            (-(1.00 + 0.07 * i), 0.26 + 0.15 * i, th * (0.78 - 0.30 * i)),
            (sz, sz, sz),
            Matrix.Rotation(math.radians(30 + 24 * i), 3, "Y") @ Matrix.Rotation(math.radians(18 * i), 3, "X"),
        )
    # A second plate course low on the solid side, and its bottom lip.
    box(bm, (0.58, -(td + 0.16), -0.46), (0.86, 0.16, 0.44), Matrix.Rotation(math.radians(-7), 3, "Y"))
    box(bm, (0.50, 0, -th * 0.94), (1.18, UPPER_TORSO.y + 0.26, 0.20))
    # Back: solid on the right, one long ribbon on the left.
    box(bm, (0.50, td + 0.14, 0), (1.10, 0.16, UPPER_TORSO.z * 0.88))
    box(bm, (-0.56, td + 0.16, -0.18), (0.44, 0.11, UPPER_TORSO.z * 1.10), Matrix.Rotation(math.radians(9), 3, "Y"))
    return finish("Wraithbound_Chest", bm, WRAITH_SHROUD)


def build_wraithbound_legs():
    bm = bmesh.new()
    # HALF-BELT: solid across the right hip, breaking into three shrinking
    # blocks as it crosses to the left.
    box(bm, (0.42, 0, 0.14), (1.30, 1.16, 0.22))
    for i in range(3):
        s = 0.30 - 0.07 * i
        box(bm, (-(0.42 + 0.28 * i), -0.04 * i, 0.14 + 0.03 * i), (s, 1.00 - 0.22 * i, 0.20 - 0.03 * i))
    # THE ARMOURED GREAVE: rigid plate over the right hip and thigh, three
    # courses stepping down and out - the half that is still solid.
    for i in range(3):
        box(
            bm,
            (0.70 + 0.04 * i, 0, -0.16 - i * 0.40),
            (0.94 - 0.06 * i, 1.30 - 0.06 * i, 0.44),
            Matrix.Rotation(math.radians(4 + 4 * i), 3, "Y"),
        )
    box(bm, (1.16, -0.10, -0.44), (0.20, 0.90, 0.90), Matrix.Rotation(math.radians(-6), 3, "Y"))
    # THE DISSOLVING DRAPE: five panels down the left, each shorter and
    # thinner than the last, raked differently so the hem never lines up.
    for i, (ang, hgt) in enumerate(
        ((116, 0.94), (146, 1.36), (172, 0.86), (198, 1.44), (226, 0.70), (252, 1.16), (272, 0.58))
    ):
        a = math.radians(ang)
        rot = (
            Matrix.Rotation(-a + math.pi / 2, 3, "Z")
            @ Matrix.Rotation(math.radians(4 + 4 * i), 3, "X")
            @ Matrix.Rotation(math.radians(-10 + 4 * i), 3, "Y")
        )
        box(bm, (math.cos(a) * 1.02, math.sin(a) * 0.66, -0.08 - hgt / 2), (0.52 - 0.03 * i, 0.14, hgt), rot)
    # Solid half's back plate, ending abruptly at the seam.
    box(bm, (0.56, 0.58, -0.42), (1.06, 0.14, 0.96))
    # Fragments torn loose below and outboard of the drape.
    for i in range(6):
        sz = 0.25 - 0.032 * i
        box(
            bm,
            (-(0.80 + 0.07 * i), 0.30 - 0.16 * i, -0.98 - 0.12 * i),
            (sz, sz, sz),
            Matrix.Rotation(math.radians(26 + 22 * i), 3, "Y") @ Matrix.Rotation(math.radians(14 * i), 3, "X"),
        )
    return finish("Wraithbound_Legs", bm, WRAITH_AURORA)


# ---------------------------------------------------------------- SETS lines
# Add these four rows to the SETS table (after "Duskveil"):
#
#     "Tideward": (build_tideward_helm, build_tideward_chest, build_tideward_legs),
#     "CorsairsRest": (build_corsairsrest_helm, build_corsairsrest_chest, build_corsairsrest_legs),
#     "Stormcaller": (build_stormcaller_helm, build_stormcaller_chest, build_stormcaller_legs),
#     "Wraithbound": (build_wraithbound_helm, build_wraithbound_chest, build_wraithbound_legs),

SETS = {
    "Chitin": (build_chitin_helm, build_chitin_chest, build_chitin_legs),
    "Boneplate": (build_boneplate_helm, build_boneplate_chest, build_boneplate_legs),
    "Mirewalker": (build_mirewalker_helm, build_mirewalker_chest, build_mirewalker_legs),
    "Rimebound": (build_rimebound_helm, build_rimebound_chest, build_rimebound_legs),
    "Cindershell": (build_cindershell_helm, build_cindershell_chest, build_cindershell_legs),
    "Duskveil": (build_duskveil_helm, build_duskveil_chest, build_duskveil_legs),
    "Tideward": (build_tideward_helm, build_tideward_chest, build_tideward_legs),
    "CorsairsRest": (build_corsairsrest_helm, build_corsairsrest_chest, build_corsairsrest_legs),
    "Stormcaller": (build_stormcaller_helm, build_stormcaller_chest, build_stormcaller_legs),
    "Wraithbound": (build_wraithbound_helm, build_wraithbound_chest, build_wraithbound_legs),
}


# ---------------------------------------------------------------- build / io


def build_all():
    objects = []
    for _prefix, builders in SETS.items():
        for builder in builders:
            objects.append(builder())
    check_faces(objects)
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
    cam_data.lens = 23
    cam = bpy.data.objects.new("Cam", cam_data)
    cam.location = Vector((0.0, -26.0, 1.9))
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
