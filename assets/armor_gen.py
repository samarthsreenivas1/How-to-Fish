# armor_gen.py
# Generates the wearable armor sets as low-poly meshes and exports them
# together as one glTF pack (.glb) - the ArmorPack, the same "one import" idea
# as the WeaponPack / RodPack / CreaturePack. Run headless:
#
#   blender --background --python assets/armor_gen.py -- assets/armor.glb
#   blender --background --python assets/armor_gen.py -- assets/armor.glb preview
#
# The second form also writes the MANNEQUIN PREVIEW: one PNG per set
# (assets/armor_preview_<set>.png, three views, worn on an R15 block
# mannequin) plus the ten-set line-up at assets/armor_preview.png. An optional
# third argument gives the preview base path, so previews can be re-rendered
# without rewriting the .glb.
#
# TWO NAME SHAPES live in this pack, both exported, both worn:
#
#   1. THE FOUR-FIELD NAME (the redesign - see "spec layer" below):
#
#        <SetPrefix>_<Slot>_<Target>_<Role>[<n>]
#
#      One piece dresses a whole REGION of the body. Colour and
#      Enum.Material come from the object's ROLE via assets/armor_palette.py,
#      so a set is no longer one flat tint.
#
#   2. THE LEGACY SINGLE PART, which is what the shipped 30 objects still use:
#
#        <SetPrefix>_Helm    worn on the Head
#        <SetPrefix>_Chest   worn on the UpperTorso
#        <SetPrefix>_Legs    a hip skirt / greaves ring worn on the LowerTorso
#
# where <SetPrefix> is Armor.sets[<setId>].modelPrefix ("Chitin",
# "Boneplate"). ArmorModel prefers shape 1 and falls back to shape 2 per SLOT,
# which is what lets the redesign land one set at a time instead of as a flag
# day. The names here ARE the contract; tools/check_armor_palette.py parses
# them out of this file and fails on any field that names nothing real.
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
# COLOUR. For a LEGACY object the colour here is preview-only - in game
# ArmorService paints it the set row's single Color3. For a SPEC-LAYER object
# the colour comes from assets/armor_palette.py, the same table
# tools/gen_armor_palette.py emits into src/Shared/Config/ArmorPalette.luau,
# so the render and the game agree by construction rather than by somebody
# remembering to update two files.
#
# THREE BUILD-TIME GATES, all of which print and never throw so a
# work-in-progress set still exports: check_faces() (the FACE BOX, skipping
# the three declared full masks), check_fit() (bulk and standoff - the
# mechanical answer to "it should not be so bulky and spiky") and
# check_coverage() (a limb nobody dressed, which is invisible in a static
# render and obvious in play).
#
# Rebuilding a set: fill in its SET_SPEC block. Until then its legacy
# build_<set>_*() functions keep exporting exactly as they do today.

import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

# The palette lives in ONE place, and it is not this file: assets/
# armor_palette.py is pure Python (no bpy), read BOTH here for the preview
# materials and by tools/gen_armor_palette.py for src/Shared/Config/
# ArmorPalette.luau. The render and the game therefore agree on colour by
# construction rather than by somebody remembering. Blender does not put the
# script's own directory on sys.path, hence the insert.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import armor_palette  # noqa: E402

TAU = math.tau

# Reference body-part boxes the pieces are authored around (blocky R15).
# These THREE are the trusted numbers - every one of the 30 shipped pieces is
# authored against them - and FIT below keeps them as its source of truth for
# Head, UpperTorso and the hip width.
HEAD = Vector((1.2, 1.2, 1.2))  # w, d, h
UPPER_TORSO = Vector((2.0, 1.0, 1.6))
HIP_W = 2.0

# ---------------------------------------------------------------- the R15 fit
#
# FIT, SLOT_TARGETS, STANDOFF and SHOULDER_CLEAR all live in
# assets/armor_palette.py, NOT here - because ArmorModel needs the same
# numbers at equip time (it scales each sub-part to the rig's real
# `character[Target].Size`), and a fit table typed once in Python and once in
# Luau is the failure gen_mesh_colors.py's header documents. Read that file
# for what each field means and for the PROVISIONAL warning on the six limb
# rows.
#
# Head / UpperTorso / the hip width in FIT are exactly the three constants
# above - the ones all 30 shipped pieces are authored against.
FIT = armor_palette.FIT
SLOT_TARGETS = armor_palette.SLOT_TARGETS
STANDOFF = armor_palette.STANDOFF
MAX_STANDOFF = armor_palette.MAX_STANDOFF
SHOULDER_CLEAR = armor_palette.SHOULDER_CLEAR

def _same(a, b):
    # Vector() is single-precision, so an == against a Python float fails at
    # the seventh decimal. This assertion is here to catch a TYPO, not a
    # rounding difference.
    return all(abs(p - q) < 1e-4 for p, q in zip(a, b))


assert _same(FIT["Head"]["size"], HEAD), "FIT Head drifted from HEAD"
assert _same(FIT["UpperTorso"]["size"], UPPER_TORSO), "FIT drifted from UPPER_TORSO"
assert abs(FIT["LowerTorso"]["size"][0] - HIP_W) < 1e-4, "FIT LowerTorso drifted from HIP_W"


def fit_size(target):
    return Vector(FIT[target]["size"])


def fit_center(target):
    return Vector(FIT[target]["center"])


def shell_size(target, standoff):
    """The target's box grown uniformly by a standoff - the one expression
    every garment builder starts from."""
    s = fit_size(target)
    return Vector((s.x + 2 * standoff, s.y + 2 * standoff, s.z + 2 * standoff))

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


# ================================================================ spec layer
#
# THE NAMING CONTRACT (new, and it is the whole redesign)
#
#     <Prefix>_<Slot>_<Target>_<Role>[<n>]
#
#   <Prefix>  Armor.sets[id].modelPrefix - "Chitin", "CorsairsRest", ...
#   <Slot>    Helm | Chest | Legs, the equip slot that owns the object
#   <Target>  the EXACT R15 part name the object welds to. No lookup table is
#             needed at runtime - ArmorModel welds to `character[Target]`. No
#             R15 part name contains an underscore, so the split is
#             unambiguous.
#   <Role>    Under | Plate | Trim | Accent | Glow. The role supplies the
#             object's COLOUR and its Enum.Material, from armor_palette.
#   [<n>]     an optional trailing digit when one target+role needs several
#             objects; the runtime strips it before the role lookup.
#
# e.g. `Cindershell_Chest_LeftUpperArm_Plate`, `Stormcaller_Helm_Head_Glow2`.
#
# It is the same idea WeaponModel.assembleVariant / MESH_COLOR_KEY already
# ship (WeaponModel.luau:209-255): the mesh's own name carries its role, the
# runtime maps role -> colour + material, the pack stays one flat import.
# tools/check_armor_palette.py parses these four fields out of this file and
# fails on any field that is not a real set / slot / FIT target / palette row.
#
# WHY A SPEC LAYER. Each of the 30 legacy pieces is 35-80 lines of hand-placed
# primitives. Rebuilding at per-limb coverage the same way would be ~4x that.
# So: the SILHOUETTE lives in SET_SPEC, the FIT lives in FIT, and the GEOMETRY
# lives in the shared garment builders below. A set becomes ~40 lines of
# declaration instead of ~600 lines of boxes.
#
# ZERO SPIKES. No builder below calls cone(). cone() stays in this file for
# the legacy path only, and the spec layer does not expose it. Where a set
# needs a hard read it gets it from a PLANE - a brow shelf, a chamfered ridge,
# a raked pauldron edge, a halo ring - never from a taper to a point. That is
# not a style note, it is the user's instruction, and check_fit() below is the
# mechanical half of it.


def obj_name(prefix, slot, target, role, n=None):
    """The four-field pack name. The ONE place it is assembled."""
    return "%s_%s_%s_%s%s" % (prefix, slot, target, role, "" if n is None else str(n))


def emit(prefix, slot, target, role, bm, n=None):
    """finish() for a spec-layer object: the colour comes from the palette, so
    the preview and the game cannot disagree."""
    return finish(obj_name(prefix, slot, target, role, n), bm, armor_palette.rgb01(prefix, role))


def mirror_object(obj, name):
    """The right-side twin of a left-side object: negate X, flip the normals
    back (a mirror inverts winding), rename Left -> Right. Authoring one side
    halves the work AND guarantees symmetry."""
    mesh = obj.data.copy()
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.scale(bm, vec=Vector((-1.0, 1.0, 1.0)), verts=bm.verts)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    twin = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(twin)
    for mat in obj.data.materials:
        twin.data.materials.append(mat)
    for poly in mesh.polygons:
        poly.use_smooth = False
    return twin


# ------------------------------------------------------- garment builders
#
# Every one takes (bm, target, ...) and reads FIT, so none of them knows
# anything about a particular set. They write into a caller-owned bmesh, which
# is what lets one (target, role) object carry several garment pieces.
#
# The standoff argument defaults to the role's budgeted standoff; passing
# something bigger is how a declared fit exception is authored, and check_fit()
# will name it unless the spec declares it.


def plate_offset(role, standoff, thickness):
    """The standoff a plate of this thickness may actually use.

    STANDOFF is measured to the plate's INNER face, MAX_STANDOFF to its outer
    surface - so a 0.22 plate 0.12 thick would stick out 0.34 and check_fit
    would (correctly) call it. Clamping here means a builder cannot author a
    violation by accident, and the gate is left to catch the things that are
    genuinely a decision: hems, ruffs, capes, halos."""
    off = STANDOFF[role] if standoff is None else standoff
    return min(off, MAX_STANDOFF - thickness)


def build_glove(bm, target, standoff=None):
    """The Under shell: the target's own box, grown uniformly. THIS is what
    gives full coverage for free - one call per target, and the body part
    underneath goes invisible at equip."""
    off = STANDOFF["Under"] if standoff is None else standoff
    box(bm, (0, 0, 0), shell_size(target, off))


def build_shell_plate(bm, target, face="front", wrap=0.70, thickness=0.12, standoff=None, height=1.0):
    """A flat plate standing off ONE face of the target - the primary Plate
    idiom. `wrap` is the fraction of the target's width it covers, `height`
    the fraction of its height. A plane, not a dome: this is where the sets'
    hard read comes from now that the spikes are gone."""
    off = plate_offset("Plate", standoff, thickness)
    s = fit_size(target)
    depth = s.y / 2 + off + thickness / 2
    width = s.x * wrap
    tall = s.z * height
    y = -depth if face == "front" else depth
    box(bm, (0, y, 0), (width, thickness, tall))


def build_pauldron(bm, target, span=1.25, drop=0.55, thickness=0.14, standoff=None, rake=12.0):
    """A raked cap over the top of an upper arm. Sits on the shoulder line and
    slopes outward - the shoulder half of the silhouette contract, and the
    single feature most likely to foul SHOULDER_CLEAR, so it is measured."""
    off = plate_offset("Plate", standoff, thickness)
    s = fit_size(target)
    top = s.z / 2 + off
    box(
        bm,
        (0, 0, top - drop / 2),
        (s.x * span + 2 * off, s.y + 2 * off, thickness),
        Matrix.Rotation(math.radians(rake), 3, "Y"),
    )
    box(bm, (0, 0, top - drop), (s.x * span * 0.86 + 2 * off, s.y * 0.9 + 2 * off, thickness))


def build_bracer(bm, target, height=0.72, thickness=0.10, standoff=None):
    """A forearm/shin wrap: an open-topped band around the limb."""
    off = plate_offset("Plate", standoff, thickness)
    s = fit_size(target)
    tall = s.z * height
    outer = shell_size(target, off)
    box(bm, (0, 0, -s.z / 2 + tall / 2), (outer.x, thickness, tall))
    box(bm, (0, 0, -s.z / 2 + tall / 2), (thickness, outer.y, tall))


def build_greave(bm, target, height=0.80, thickness=0.12, standoff=None):
    """A shin plate: the front face only, leaving the calf soft."""
    off = plate_offset("Plate", standoff, thickness)
    s = fit_size(target)
    box(bm, (0, -(s.y / 2 + off + thickness / 2), -s.z * 0.05), (s.x * 0.86, thickness, s.z * height))


def build_boot_cap(bm, target, thickness=0.12, standoff=None, toe=0.20):
    """A foot's toe cap and sole lip."""
    off = plate_offset("Plate", standoff, thickness)
    s = fit_size(target)
    box(bm, (0, -s.y * toe, 0), (s.x + 2 * off, s.y * (1 - toe), s.z + 2 * off))


def build_band(bm, target, z=0.0, height=0.16, standoff=None, role="Trim"):
    """A belt / cuff / hem band around the target at height z (a fraction of
    the target's own height, -0.5 .. 0.5)."""
    off = plate_offset(role if role in STANDOFF else "Trim", standoff, 0.0)
    s = fit_size(target)
    outer = shell_size(target, off)
    box(bm, (0, 0, s.z * z), (outer.x, outer.y, s.z * height))


def build_coif(bm, target="Head", standoff=None, aperture=0.44, brow=0.16):
    """The helm Under: a head shell with a FACE APERTURE cut as open air -
    four boxes (crown, back, two cheeks) rather than a box with a hole, so it
    stays flat-shaded and cheap. Obeys the FACE BOX by construction: nothing
    is placed in the central band in front of the face plane below the brow."""
    off = STANDOFF["Under"] if standoff is None else standoff
    s = fit_size(target)
    outer = shell_size(target, off)
    crown = s.z * 0.5 - s.z * brow
    box(bm, (0, 0, (outer.z / 2 + crown) / 2), (outer.x, outer.y, outer.z / 2 - crown))
    box(bm, (0, outer.y / 4, 0), (outer.x, outer.y / 2, outer.z))
    for side in (-1, 1):
        cheek = (outer.x - s.x * aperture) / 2
        box(bm, (side * (outer.x - cheek) / 2, -outer.y / 4, 0), (cheek, outer.y / 2, outer.z))


def build_hood(bm, target="Head", peak=0.45, standoff=None, drape=0.22):
    """A peaked hood over the coif: a back-heavy shell with a capped peak.
    `peak` is studs ABOVE the crown and is capped at 0.55 by the spec."""
    off = (STANDOFF["Trim"] if standoff is None else standoff) + drape
    s = fit_size(target)
    outer = shell_size(target, off)
    box(bm, (0, outer.y * 0.12, s.z / 2 + peak / 2), (outer.x * 0.92, outer.y * 0.88, peak))
    box(bm, (0, outer.y * 0.22, 0), (outer.x, outer.y * 0.62, outer.z))


def build_visor(bm, target="Head", slit=0.10, thickness=0.10, standoff=None, drop=0.10):
    """A flat-fronted visor with ONE horizontal slit, made as two planes with
    air between them - the slit is the gap, never a modelled notch."""
    off = STANDOFF["Plate"] if standoff is None else standoff
    s = fit_size(target)
    y = -(s.y / 2 + off + thickness / 2)
    upper = s.z / 2 - drop
    box(bm, (0, y, (upper + slit / 2 + drop) / 2 + slit / 2), (s.x * 0.92, thickness, upper - slit / 2))
    box(bm, (0, y, -(s.z / 2 - slit) / 2 - slit / 2), (s.x * 0.92, thickness, s.z / 2 - slit / 2))


def build_brim(bm, target="Head", radius=0.95, thickness=0.12, z=-0.18, sides=12):
    """A thin disc brim (sou'wester, bicorne). THIN is the point: 0.12 studs,
    not the 1.30-stud box cluster the old Tideward helm carried."""
    _band(bm, z, radius, radius, thickness, 0.82, segments=sides)


def build_cape(bm, target="UpperTorso", side=-1, length=1.30, width=0.86, thickness=0.08, standoff=None):
    """A half-cape off one shoulder. A declared fit exception in every set that
    wears one - a cape IS the silhouette, and saying so in the spec is what
    keeps check_fit honest."""
    off = STANDOFF["Accent"] if standoff is None else standoff
    s = fit_size(target)
    box(
        bm,
        (side * s.x * 0.22, s.y / 2 + off + thickness / 2, s.z / 2 - length / 2),
        (s.x * width, thickness, length),
        Matrix.Rotation(math.radians(4), 3, "X"),
    )


def build_skirt(bm, target="LowerTorso", hem=0.85, flare=0.12, standoff=None, sides=10):
    """A hip skirt / shroud hanging off the hip line, flaring outward as it
    falls. `hem` is studs BELOW the hip centre and is a declared exception
    wherever it passes MAX_STANDOFF."""
    off = STANDOFF["Trim"] if standoff is None else standoff
    s = fit_size(target)
    _band(bm, -hem / 2, s.x / 2 + off + flare, s.x / 2 + off, hem, s.y / s.x)


def build_ring(bm, target="Head", radius=0.86, thickness=0.07, standoff=0.25, sides=16):
    """A halo ring standing off the BACK of the head - pure silhouette, zero
    bulk. Stormcaller's answer to the crown spikes it used to carry."""
    s = fit_size(target)
    mat = (
        Matrix.Translation(Vector((0, s.y / 2 + standoff, s.z * 0.16)))
        @ Matrix.Rotation(math.radians(90), 4, "X")
    )
    # cap_ends=False leaves the tube WALL only - which is the halo. No
    # solidify pass: a one-sided ring reads correctly flat-shaded and costs
    # half the faces.
    bmesh.ops.create_cone(
        bm, cap_ends=False, segments=sides, radius1=radius, radius2=radius, depth=thickness, matrix=mat
    )


def build_lure(bm, target="Head", reach=0.62, rise=0.34, bulb=0.13, stalk=0.05):
    """Duskveil's lantern stalk: a short arm curving FORWARD above the brow,
    with a bulb on the end. The one protrusion in the redesign, and it earns
    its keep - it sits above the face box, is the island's signature, and is a
    lamp rather than a weapon."""
    s = fit_size(target)
    top = s.z / 2
    a = Vector((0, -s.y * 0.20, top + 0.04))
    b = Vector((0, -s.y * 0.20 - reach * 0.55, top + rise))
    c = Vector((0, -s.y * 0.20 - reach, top + rise * 0.82))
    limb(bm, a, b, stalk, stalk * 0.8, sides=5)
    limb(bm, b, c, stalk * 0.8, stalk * 0.7, sides=5)
    ellipsoid(bm, c, (bulb, bulb, bulb), subdiv=1)


# ------------------------------------------------------- wave-1 garment builders
#
# Additions to the wave-0 set, each because a shape wave 1 actually needs could
# not be said with what was there. Every one is generic - it takes
# (bm, target, ...) and reads FIT, knows nothing about a set - and none of them
# calls cone().
#
# THE PLATE LANGUAGE IS FLAT. The first wave-1 pass built every lame as a
# flattened icosphere, and the render was unambiguous: twenty soft blobs in
# rows read as bubble wrap on Tideward and as gravel on Chitin. Real shell and
# real lamellar are FLAT PANELS with a hard corner-cut edge and a chamfer, and
# the chamfer is what draws the row line at 30 studs. So _plate() is the atom
# of both sets, and there is a deliberate SIZE HIERARCHY on top of it - one
# large scute on the chest, medium plates on shoulder and thigh, small lames
# only on forearm and shin - rather than one uniform plate size everywhere.


def _jitter(seed, i, amount):
    """Deterministic pseudo-noise in [-amount, +amount].

    NOT random.random(): the pack has to be byte-reproducible run to run, or
    every rebuild is an unreadable binary diff in a shared checkout. A real
    carapace is not symmetric-perfect and the size variation is what stops the
    rows reading as a printed grid - but it must be the SAME variation every
    time."""
    if amount <= 0.0:
        return 0.0
    h = math.sin(seed * 12.9898 + i * 78.233) * 43758.5453
    return (h - math.floor(h) - 0.5) * 2.0 * amount


def _bevel_box(bm, center, size, bevel=0.06, rot=None, segments=1):
    """A box with every edge chamfered - the shape a helm shell wants.

    A raw box reads as a mailbox at any distance, which is precisely what the
    first pass's helms were. A chamfer catches one extra light value on every
    edge and the same silhouette reads as armour instead. The bevel cuts
    INWARD, so the bbox does not move and check_fit's numbers are unchanged."""
    before = set(bm.verts)
    box(bm, center, size, rot)
    fresh = [v for v in bm.verts if v not in before]
    edges = set()
    for vert in fresh:
        edges.update(vert.link_edges)
    bmesh.ops.bevel(
        bm,
        geom=fresh + list(edges),
        offset=min(bevel, min(size) * 0.30),
        segments=segments,
        affect="EDGES",
        profile=0.5,
        clamp_overlap=True,
    )


def _plate(bm, center, size, rot=None, bevel=0.22, corner=0.22, dome=0.0):
    """ONE armour plate: a thin, FLAT, corner-cut slab whose outer face is
    inset - a roof tile, a lamellar lame, a crab scute.

    size = (width, thickness, height) in the plate's own axes; it faces -Y.
    `bevel` is the fraction the OUTER face is inset (the chamfer that draws the
    edge), `corner` the fraction of the smaller dimension cut off each corner
    (so it reads rounded without one curved surface on it), and `dome` pushes
    the outer face's centre out - Chitin's shells are slightly domed, and
    Tideward's lacquered lames are dead flat."""
    w, t, h = size[0] / 2, size[1] / 2, size[2] / 2
    cut = min(w, h) * corner
    outline = [
        (-w + cut, h), (w - cut, h), (w, h - cut), (w, -h + cut),
        (w - cut, -h), (-w + cut, -h), (-w, -h + cut), (-w, h - cut),
    ]
    inset = 1.0 - bevel
    mat = Matrix.Translation(Vector(center))
    if rot is not None:
        mat = mat @ rot.to_4x4()
    before = set(bm.faces)
    back = [bm.verts.new(mat @ Vector((x, t, z))) for x, z in outline]
    front = [bm.verts.new(mat @ Vector((x * inset, -t, z * inset))) for x, z in outline]
    bm.faces.new(list(reversed(back)))
    n = len(outline)
    for i in range(n):
        bm.faces.new((back[i], back[(i + 1) % n], front[(i + 1) % n], front[i]))
    if dome > 0.0:
        peak = bm.verts.new(mat @ Vector((0.0, -t - dome, 0.0)))
        for i in range(n):
            bm.faces.new((front[i], front[(i + 1) % n], peak))
    else:
        bm.faces.new(front)
    bmesh.ops.recalc_face_normals(bm, faces=[f for f in bm.faces if f not in before])


def build_lames(
    bm,
    target,
    rows=(3,),
    weights=None,
    face="front",
    wrap=0.90,
    top=0.48,
    bottom=-0.48,
    thickness=0.10,
    standoff=None,
    overlap=0.30,
    curve=0.10,
    step=0.02,
    tilt=6.0,
    jitter=0.0,
    seed=1,
    dome=0.0,
    corner=0.22,
    bevel=0.22,
    cap=0.0,
    cap_count=2,
):
    """Rows of overlapping FLAT plates down a target's face - a carapace, a
    lamellar coat, a scale bracer, a roof.

    `rows` is the plate count per row, TOP ROW FIRST, so (1, 3) is one big
    scute over three marginal plates. `weights` gives the rows their relative
    heights, which is how the size hierarchy is stated: (2.4, 1.0) makes the
    scute two and a half times the plates under it.

    The shingle is the whole point, and it is three separate effects:
      `overlap` widens and heightens each plate so it laps its neighbour and
        the row below (~30% - roof tiles);
      `step`    walks each lower row closer to the body, so the row above
        always laps OVER the one below rather than beside it;
      `tilt`    rakes every plate so its BOTTOM edge stands proud - the edge
        that catches the light and draws the row line.
    `curve` pulls the outboard plates back toward the body so a row reads as
    wrapping a torso instead of as a billboard, and `cap` lays a short row flat
    over the TOP of the target (a shoulder cap) in the same object.

    face: "front" | "back" | "both". Standoff is clamped against the tilt and
    the thickness, so a plate cannot author a check_fit violation by
    accident."""
    off0 = plate_offset("Plate", standoff, thickness)
    s = fit_size(target)
    rows = list(rows)
    weights = list(weights) if weights else [1.0] * len(rows)
    total = sum(weights) or 1.0
    span = (top - bottom) * s.z
    width = s.x * wrap
    rake = math.radians(-abs(tilt))
    faces = ("front", "back") if face == "both" else (face,)
    for fi, which in enumerate(faces):
        sign = -1.0 if which == "front" else 1.0
        z_top = top * s.z
        for r, count in enumerate(rows):
            height = span * weights[r] / total
            z = z_top - height / 2
            z_top -= height
            lw = width / count * (1.0 + overlap)
            lh = height * (1.0 + overlap)
            # A raked plate reaches further than its own half-thickness (the
            # rake trades height for depth) and a domed one further still.
            # Solve the standoff against the WHOLE reach - centre offset plus
            # the plate's own extent - rather than guessing a margin. Getting
            # this expression half right is what put five objects 0.01-0.02
            # over on the first build of this pass.
            # lh is the plate height BEFORE jitter, and jitter can only make a
            # plate bigger - so the clamp has to use the largest one the row
            # can emit, not the nominal one.
            extent = max(
                (thickness / 2 + dome) * math.cos(rake),
                thickness / 2 * math.cos(rake) + lh * (1.0 + jitter) / 2 * abs(math.sin(rake)),
            )
            off = min(max(0.0, off0 - step * r), MAX_STANDOFF - thickness / 2 - extent)
            depth = s.y / 2 + off + thickness / 2
            for i in range(count):
                x = -width / 2 + (i + 0.5) * width / count
                u = x / (width / 2) if width > 1e-6 else 0.0
                y = sign * (depth - curve * u * u)
                k = 1.0 + _jitter(seed + fi * 7, r * 11 + i, jitter)
                _plate(
                    bm,
                    (x, y, z),
                    (lw * k, thickness, lh * k),
                    Matrix.Rotation(rake if sign < 0 else -rake, 3, "X"),
                    bevel=bevel,
                    corner=corner + _jitter(seed + 3, r * 13 + i, jitter),
                    dome=dome,
                )
    if cap > 0.0:
        z = min(s.z / 2 + off0 + thickness / 2, s.z / 2 + MAX_STANDOFF - thickness / 2 - dome)
        cw = s.x * wrap * 1.02
        for i in range(cap_count):
            x = -cw / 2 + (i + 0.5) * cw / cap_count
            lw = cw / cap_count * (1.0 + overlap)
            _plate(
                bm,
                (x, 0.0, z),
                (lw, thickness, (s.y + 2 * off0) * cap),
                Matrix.Rotation(math.radians(90), 3, "X"),
                bevel=bevel,
                corner=corner,
                dome=dome,
            )


def build_scute(bm, target, face="front", **kw):
    """ONE large plate on a face - build_lames' single-plate case, named so the
    spec reads as what it is: a breast scute, a pauldron, a thigh plate. The
    size hierarchy is declared here rather than emerging by accident."""
    args = {"rows": (1,), "wrap": 0.86, "top": 0.44, "bottom": -0.40, "thickness": 0.12, "overlap": 0.0, "curve": 0.14, "corner": 0.26}
    args.update(kw)
    build_lames(bm, target, face=face, **args)


def build_shell_cap(
    bm,
    target="Head",
    thickness=0.10,
    standoff=None,
    dome=0.80,
    brow=0.16,
    cheek=0.9,
    ridge=0.0,
    tail=0,
    brim=0.0,
    brim_z=0.16,
    brim_thickness=0.12,
    bevel=0.09,
    chamfer=1,
):
    """The helm's hard shell: a CHAMFERED shell hugging the upper head under a
    chamfered crown, with an optional crown ridge, brow shelf, cheek scutes
    hanging beside the open face, a nape plate, an optional scale tail down the
    nape, and an optional short curved brim.

    Everything here is a bevelled box or a _plate, because the three earlier
    attempts proved what a head actually is. An icosphere loses ~8% of its
    radius to faceting and lands flush inside the Under coif; a hexagonal cone
    clears it by 0.007 studs on the face side; an octagon is proud only over
    the middle 0.34 studs. A head is a BOX, so anything inscribed in a circle
    sags inside it at the corners and the helm renders as no helm at all. A
    bevelled box is proud on all four sides by construction AND has an edge
    highlight, which a raw box - the fourth attempt, a mailbox - did not.

    `chamfer` is the number of bevel SEGMENTS. 1 is the wave-1 read - one
    chamfered facet per edge, which at helm scale still says "box with the
    corners knocked off". 3 turns each edge into a three-step chamfer, i.e.
    an octagonal profile in both section planes, and the shell reads ROUNDED
    - a cap, a hood, a skull - without one curved surface, without smooth
    shading, and without moving the bbox (the bevel cuts inward). Wave 2's
    three sets all want the rounder read; wave 1's two stay at 1 so their
    approved silhouettes do not move.

    FACE BOX BY CONSTRUCTION: the shell's floor is z = +0.03, the crown is
    above it, the brow shelf's lowest vertex is z = +0.03, the brim sits at
    brow height, and the cheek scutes are entirely outboard of |x| = 0.40 - so
    nothing this builder can emit reaches the box at all."""
    off = plate_offset("Plate", standoff, thickness)
    s = fit_size(target)
    hw, hd, hh = s.x / 2, s.y / 2, s.z / 2
    floor = hh * 0.05
    band_top = hh * 0.96
    _bevel_box(bm, (0, 0, (floor + band_top) / 2), (s.x + 2 * off, s.y + 2 * off, band_top - floor), bevel, segments=chamfer)
    # The crown: one chamfered cap, raked back. Its height is SOLVED against
    # MAX_STANDOFF, because a rake trades depth for height and a guessed
    # constant put the helm 0.01 over on the first try.
    rake = math.radians(-8)
    deep = (s.y + 2 * off) * 0.38
    headroom = hh + MAX_STANDOFF - band_top - deep * abs(math.sin(rake))
    rise = min(dome * hh * 0.42, headroom / math.cos(rake))
    _bevel_box(
        bm,
        (0, hd * 0.10, band_top + rise / 2 - 0.02),
        ((s.x + 2 * off) * 0.80, deep * 2, rise),
        bevel,
        Matrix.Rotation(rake, 3, "X"),
        segments=chamfer,
    )
    if ridge > 0.0:
        # A ridge down the crown's centre line, front to back. A plane, not a
        # crest: it is the one hard line the shell gets.
        _bevel_box(
            bm,
            (0, hd * 0.10, band_top + rise * 0.62),
            (ridge, (s.y + 2 * off) * 0.66, rise * 0.86),
            bevel * 0.6,
            Matrix.Rotation(rake, 3, "X"),
            segments=chamfer,
        )
    box(bm, (0, hd + off * 0.7, -hh * 0.34), (s.x * 0.86, thickness * 1.2, hh * 0.90))
    for i in range(tail):
        # The scale tail down the nape - small plates, each lapping the one
        # above, entirely behind the face plane.
        t = (i + 0.5) / max(1, tail)
        _plate(
            bm,
            (0, hd + off + thickness * 0.6, floor - t * (hh * 1.10)),
            (s.x * (0.68 - 0.10 * t), thickness, hh * 0.44),
            Matrix.Rotation(math.radians(180), 3, "Z"),
            corner=0.26,
        )
    if brow > 0.0:
        shelf, brow_rake = hh * brow * 1.9, math.radians(-16)
        reach = thickness * 1.3 / 2 * math.cos(brow_rake) + shelf / 2 * abs(math.sin(brow_rake))
        _plate(
            bm,
            (0, -min(hd + off + thickness * 0.6, hd + MAX_STANDOFF - reach), hh * 0.24),
            (s.x * 0.94, thickness * 1.3, shelf),
            Matrix.Rotation(brow_rake, 3, "X"),
            corner=0.18,
        )
    if cheek > 0.0:
        # Cheek scutes HANGING beside the open face: plates turned to face
        # outward, inboard edge at |x| = 0.68 on a 1.2 head - the face box
        # ends at 0.40, so they frame the face and never cross it.
        for side in (-1, 1):
            _plate(
                bm,
                (side * (hw + off * 0.92), -hd * 0.10, -hh * 0.34),
                (hd * 1.60 * cheek, thickness * 1.3, hh * 1.02 * cheek),
                Matrix.Rotation(math.radians(side * 90), 3, "Z"),
                corner=0.30,
            )
    if brim > 0.0:
        # A THIN brim at brow height, so it shades the face from ABOVE the face
        # box rather than crossing it. `brim` is its OUTER half-extent in
        # studs. The old Tideward helm's answer to this read was a 1.30-stud
        # box cluster; this is the same silhouette at a twentieth of the bulk.
        inner = hw + 0.07
        width = max(0.10, min(brim, hw + MAX_STANDOFF) - inner)
        _box_ring(bm, inner + width / 2, hd + 0.07 + width / 2, brim_z * hh, brim_thickness, width, 16)
        # ...and the front of it curves down, which is what makes a brim read
        # as a brim rather than as a shelf.
        lip, lip_rake = width * 1.15, math.radians(-62)
        lip_reach = brim_thickness / 2 * abs(math.cos(lip_rake)) + lip / 2 * abs(math.sin(lip_rake))
        _plate(
            bm,
            (0, -min(hd + 0.07 + width * 0.62, hd + MAX_STANDOFF - lip_reach), brim_z * hh - brim_thickness * 0.30),
            (s.x * 0.92, brim_thickness, lip),
            Matrix.Rotation(lip_rake, 3, "X"),
            corner=0.30,
        )


def build_lacing(
    bm,
    target,
    rungs=3,
    radius=0.05,
    standoff=None,
    face="front",
    top=0.40,
    bottom=-0.40,
    spread=0.26,
    rails=True,
    toggles=0,
    toggle=0.15,
):
    """Cross-lacing: two cords down a face with rungs crossing between them,
    and optional driftwood toggles threaded on.

    Authored PROUD of the plates it lashes (pass the plates' standoff plus a
    little), because a cord tucked under a shell is a cord nobody ever sees -
    and on Chitin the cord IS the design."""
    off = STANDOFF["Trim"] if standoff is None else standoff
    # A cord of radius r hung at off reaches off + 2r, not off + r - which is
    # exactly the +0.03 check_fit caught on the first build.
    off = min(off, MAX_STANDOFF - 2 * radius)
    s = fit_size(target)
    sign = -1.0 if face == "front" else 1.0
    y = sign * (s.y / 2 + off + radius)
    x = s.x * spread
    z0, z1 = bottom * s.z, top * s.z
    if rails:
        for side in (-1, 1):
            limb(bm, (side * x, y, z0), (side * x, y, z1), radius, radius, sides=5)
    for i in range(rungs):
        # BOTH diagonals of each bay, so the lacing reads as an X-cross - a
        # single alternating diagonal reads as a ladder, which is what the
        # first render showed down the middle of Chitin's chest.
        t0, t1 = i / rungs, (i + 1) / rungs
        for a in (-1, 1):
            limb(
                bm,
                (a * x, y, z1 - (z1 - z0) * t0),
                (-a * x, y, z1 - (z1 - z0) * t1),
                radius * 0.8,
                radius * 0.8,
                sides=5,
            )
    for i in range(toggles):
        t = (i + 0.5) / toggles
        _bevel_box(
            bm,
            (0, y - sign * radius * 0.5, z1 - (z1 - z0) * t),
            (toggle * 0.46, toggle * 0.46, toggle),
            toggle * 0.12,
            Matrix.Rotation(math.radians(16 if i % 2 else -16), 3, "Y"),
        )


def _perimeter(hx, hy, count):
    """Walk a RECTANGLE's perimeter at half-extents (hx, hy), yielding
    (x, y, turn, seg) for `count` evenly spaced stations - `turn` being the
    Z rotation that makes a plate face that side's outward normal.

    Why not a circle or an ellipse: every R15 part is a BOX, and a ring
    inscribed in a circle sags inside the box at the diagonals - a hip belt
    laid on an ellipse of rx 1.24 / ry 0.69 passes through (0.88, 0.49), which
    is INSIDE a 2.0 x 1.0 hip. The belt then disappears at both hips and reads
    as two separate front and back straps. A rectangular path sits on the
    surface all the way round. Shared by the belt, the ruff and the fringe."""
    sides = (
        ((-hx, -hy), (hx, -hy), 0.0),
        ((hx, -hy), (hx, hy), math.pi / 2),
        ((hx, hy), (-hx, hy), 0.0),
        ((-hx, hy), (-hx, -hy), math.pi / 2),
    )
    lengths = [Vector((b[0] - a[0], b[1] - a[1], 0)).length for a, b, _ in sides]
    total = sum(lengths)
    for (a, b, turn), length in zip(sides, lengths):
        n = max(1, int(round(count * length / total)))
        seg = length / n
        for i in range(n):
            t = (i + 0.5) / n
            yield a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, turn, seg


def _crosses_face(x, half, y, s, face_clear):
    """True if a station on a ring would put geometry in the central band in
    FRONT of the target - the band a helm has to leave open.

    Measures the block's INBOARD EDGE, not its centre: the first build of the
    fen hood's moss fringe tested the centre, and a 0.36-wide strand centred
    at x = 0.52 still reached x = 0.34, which is inside the FACE BOX's 0.40.
    check_faces caught it, which is what it is for."""
    return face_clear > 0.0 and y < 0.0 and abs(x) - half <= s.x * face_clear / 2


def _box_ring(bm, hx, hy, z, height, thickness, count, plate=False):
    """A belt: short boxes walked round _perimeter(), each facing its side."""
    for x, y, turn, seg in _perimeter(hx, hy, count):
        box(bm, (x, y, z), (seg * 1.02, thickness, height), Matrix.Rotation(turn, 3, "Z"))


def build_ring_band(
    bm,
    target,
    z=0.0,
    height=0.14,
    thickness=0.10,
    standoff=None,
    role="Trim",
    count=12,
    buckle=0.0,
    straps=0.0,
    strap_drop=0.0,
    face_clear=0.0,
):
    """A cord / belt / lace: short plates walked around the target, each facing
    its own side, plus the one detail that makes Trim read as hardware rather
    than as a stripe - a `buckle` at the front, or `straps` dropping down the
    SIDES of a helm (a chinstrap, kept outboard of |x| = 0.40 so it never
    crosses the face).

    Wave 0's build_band is one box grown off the target, which from any angle
    but dead-on reads as a PLANK driven through the wearer - the first wave-1
    render had a brown plank through Chitin's skull and a green one across
    Tideward's shoulder."""
    off = (STANDOFF[role] if role in STANDOFF else STANDOFF["Trim"]) if standoff is None else standoff
    off = min(off, MAX_STANDOFF - thickness)
    s = fit_size(target)
    hx = s.x / 2 + off + thickness / 2
    hy = s.y / 2 + off + thickness / 2
    if face_clear > 0.0:
        # An OPEN band: a collar that frames the face instead of a bar drawn
        # across it. Boneplate's nacre collar needs this - a closed nacre ring
        # on a head renders as a white plank over the brow, which is the same
        # thing this builder was written to stop happening with belts.
        for x, y, turn, seg in _perimeter(hx, hy, count):
            if _crosses_face(x, seg * 1.02 / 2, y, s, face_clear):
                continue
            box(bm, (x, y, s.z * z), (seg * 1.02, thickness, height), Matrix.Rotation(turn, 3, "Z"))
    else:
        _box_ring(bm, hx, hy, s.z * z, height, thickness, count)
    if buckle > 0.0:
        # The buckle stands on the belt's own face, and its outer surface is
        # clamped to the budget - a 0.12 belt plus a 1.4x buckle plus its
        # offset is 0.05 past MAX_STANDOFF if nobody does the arithmetic.
        depth = thickness * 1.4
        y = min(hy + thickness * 0.30, s.y / 2 + MAX_STANDOFF - depth / 2)
        _bevel_box(bm, (0, -y, s.z * z), (buckle, depth, height * 1.55), buckle * 0.16)
    if straps > 0.0 and strap_drop > 0.0:
        for side in (-1, 1):
            box(
                bm,
                (side * hx, -s.y * 0.10, s.z * z - strap_drop / 2),
                (thickness, straps, strap_drop),
            )


def build_studs(bm, target, spots=(), radius=0.10, standoff=None, face="front", seat=0.0):
    """Small spheres on a face - a pearl clasp, a scale glint, a rivet - each
    optionally SET INTO a small backing plate (`seat` = the plate's half-width
    as a multiple of the radius), which is how a pearl reads as a clasp rather
    than as a dot of paint.

    Radius floors at 0.06 (a 0.12-stud feature): anything smaller is detail the
    game cannot show at 30 studs, which is the mistake the old pack made
    everywhere."""
    off = STANDOFF["Accent"] if standoff is None else standoff
    radius = max(radius, 0.06)
    off = min(off, MAX_STANDOFF - radius * 1.4)
    s = fit_size(target)
    sign = -1.0 if face == "front" else 1.0
    for u, v in spots:
        x, z = u * s.x / 2, v * s.z / 2
        if seat > 0.0:
            _plate(
                bm,
                (x, sign * (s.y / 2 + off * 0.5), z),
                (radius * seat, radius * 0.7, radius * seat * 0.86),
                None if sign < 0 else Matrix.Rotation(math.radians(180), 3, "Z"),
                corner=0.34,
            )
        ellipsoid(bm, (x, sign * (s.y / 2 + off + radius * 0.4), z), (radius, radius, radius), subdiv=1)


def build_scale_patch(bm, target, rows=(2,), face="front", standoff=None, **kw):
    """A small patch of fish-scale glints - build_lames with a tight span, kept
    as a named call so the SPEC reads as what it is."""
    args = {"wrap": 0.56, "top": 0.28, "bottom": -0.16, "thickness": 0.07, "overlap": 0.34, "curve": 0.02, "step": 0.010, "tilt": 8.0, "jitter": 0.10, "corner": 0.30}
    args.update(kw)
    build_lames(bm, target, rows=rows, face=face, standoff=standoff, **args)


# ------------------------------------------------------- wave-2 garment builders
#
# Wave 2's three sets are the SOFT half of the pack - a hide coat, a bone
# half-mask, a fur parka - and none of them can be said with the lamellar
# language wave 1 built. Five more generic builders, each (bm, target, ...),
# each reading FIT, none of them calling cone().
#
# The two standing corrections from the wave-1 review are mechanised here
# rather than left as style notes:
#   (a) A HELM SHOULD READ ROUNDER THAN A CHAMFERED BOX. build_shell_cap grew
#       a `chamfer` (bevel-segment) argument, and build_cowl below is a
#       three-step-chamfered hood built the same way. Three segments is an
#       octagonal profile in both section planes: rounded silhouette, flat
#       shading, no smooth-shading and no moved bbox.
#   (b) A PLATE IS DEAD FLAT unless the MATERIAL is genuinely domed. Wave 2
#       keeps `dome 0` on every lame except Boneplate's, where the plates are
#       long curved bone and a small dome (0.05) is the truth of the material.


def build_cowl(
    bm,
    target="Head",
    standoff=None,
    drape=0.18,
    aperture=0.46,
    peak=0.10,
    chamfer=3,
    bevel=0.13,
):
    """A HOOD: a rounded, low cowl over the crown, closed behind and down both
    sides, with the face left as open air.

    Structurally build_coif's four blocks - crown, back, two cheeks - but each
    one three-step chamfered, so the thing reads as cloth pulled over a head
    rather than as a helmet. `drape` is the studs of slack the cloth hangs at
    beyond the Under standoff (a hood is loose; a coif is not), `peak` a small
    back-raked rise on the crown, solved against the standoff budget so the
    hood can never author a violation.

    FACE BOX BY CONSTRUCTION: the crown's floor is z = +0.06 * height, the
    cheeks are outboard of the aperture, and nothing is placed in the central
    band in front of the face plane below that floor."""
    off = min((STANDOFF["Under"] if standoff is None else standoff) + drape, MAX_STANDOFF)
    s = fit_size(target)
    outer = shell_size(target, off)
    hw, hd, hh = s.x / 2, s.y / 2, s.z / 2
    floor = hh * 0.06
    top = hh + off
    _bevel_box(bm, (0, hd * 0.08, (floor + top) / 2), (outer.x, outer.y * 0.96, top - floor), bevel, segments=chamfer)
    _bevel_box(bm, (0, (hd + off) / 2, 0), (outer.x, hd + off, outer.z), bevel, segments=chamfer)
    cheek = (outer.x - s.x * aperture) / 2
    for side in (-1, 1):
        _bevel_box(
            bm,
            (side * (outer.x - cheek) / 2, -(hd + off) / 2, 0),
            (cheek, hd + off, outer.z),
            bevel,
            segments=chamfer,
        )
    if peak > 0.0:
        # The hood's crease, raked back off the crown. Its rise is what is
        # LEFT of the budget after the drape, never a guessed constant - the
        # same arithmetic build_shell_cap's crown does.
        rake = math.radians(-14)
        deep = outer.y * 0.46
        rise = min(peak, MAX_STANDOFF - off - deep * abs(math.sin(rake)))
        if rise > 0.02:
            _bevel_box(
                bm,
                (0, hd * 0.20, top + rise / 2 - 0.01),
                (outer.x * 0.72, deep, rise),
                bevel,
                Matrix.Rotation(rake, 3, "X"),
                segments=chamfer,
            )


def build_brow_plate(
    bm,
    target="Head",
    width=0.94,
    shelf=0.30,
    thickness=0.13,
    standoff=None,
    rake=-16.0,
    corner=0.20,
    cheeks=0.0,
    cheek_z=-0.34,
):
    """A brow shelf ALONE - build_shell_cap's brow and cheek scutes without the
    shell under them, for the sets whose head read is a hood or a coif and
    whose only hard part is the scute over the eyes.

    The shelf's z is SOLVED so its lowest vertex clears the FACE BOX's ceiling
    (z = 0) by 0.035 rather than being placed at a constant and hoped about -
    a raked plate's bottom edge is lower than its centre by
    (shelf/2)cos + (t/2)|sin|, and that is exactly the term the first pass of
    every helm in this file got wrong."""
    off = plate_offset("Plate", standoff, thickness)
    s = fit_size(target)
    hw, hd, hh = s.x / 2, s.y / 2, s.z / 2
    tilt = math.radians(rake)
    half = shelf / 2 * abs(math.cos(tilt)) + thickness / 2 * abs(math.sin(tilt))
    reach = thickness / 2 * abs(math.cos(tilt)) + shelf / 2 * abs(math.sin(tilt))
    _plate(
        bm,
        (0, -min(hd + off + thickness * 0.6, hd + MAX_STANDOFF - reach), max(hh * 0.24, 0.035 + half)),
        (s.x * width, thickness, shelf),
        Matrix.Rotation(tilt, 3, "X"),
        corner=corner,
    )
    if cheeks > 0.0:
        for side in (-1, 1):
            _plate(
                bm,
                (side * (hw + off * 0.92), -hd * 0.10, hh * cheek_z),
                (hd * 1.60 * cheeks, thickness * 1.2, hh * 1.00 * cheeks),
                Matrix.Rotation(math.radians(side * 90), 3, "Z"),
                corner=0.30,
            )


def build_ruff(
    bm,
    target,
    z=-0.18,
    height=0.30,
    thickness=0.16,
    standoff=None,
    count=14,
    layers=2,
    step=0.05,
    stagger=0.06,
    shrink=0.14,
    face_clear=0.0,
    jitter=0.30,
    gap=0.88,
    seed=1,
    role="Trim",
):
    """A FUR RUFF / collar / cuff: two or three belts of chunky blocks stacked
    at slightly different heights and standoffs.

    Fur cannot be modelled and must not be faked with a smooth ring - what
    reads as fur at game distance is a BROKEN outline, so this is deliberately
    several short blocks per side at staggered radii rather than one band. The
    standoff is clamped to MAX_STANDOFF - thickness, because a block on the
    +/-X sides is turned 90 degrees and reaches its own full thickness
    outboard: on a 1.2 head the outermost layer lands at x +/-0.90, exactly
    the budget, with the ice shell under it at +/-0.74. No exception needed -
    which is the point of doing the arithmetic instead of declaring one.

    `face_clear` OPENS the ring across the front, which is what a parka ruff
    actually does - it frames a face, it does not cover one. A closed ring on
    the Head target puts fur across the nose and bows the FACE BOX, and the
    gate caught exactly that on the first build of this set."""
    base = (STANDOFF[role] if role in STANDOFF else STANDOFF["Trim"]) if standoff is None else standoff
    s = fit_size(target)
    for layer in range(layers):
        off = min(base + layer * step, MAX_STANDOFF - thickness)
        hx = s.x / 2 + off + thickness / 2
        hy = s.y / 2 + off + thickness / 2
        dz = (layer - (layers - 1) / 2.0) * stagger
        tall = height * (1.0 - shrink * layer)
        for i, (x, y, turn, seg) in enumerate(_perimeter(hx, hy, count + layer * 2)):
            if _crosses_face(x, seg * gap / 2, y, s, face_clear):
                continue
            # The first build of this set laid the ruff as one even ring and
            # the render was unambiguous: a flat dark PLANK across the chest,
            # the same failure build_ring_band's docstring records. Fur has no
            # even edge - so every block gets its own height and its own
            # height offset, and they are set apart with a GAP rather than
            # overlapped, which is what turns a bar back into a pelt.
            k = 1.0 + _jitter(seed + layer * 5, i, jitter)
            box(
                bm,
                (x, y, s.z * z + dz + _jitter(seed + 9, i + layer * 17, jitter) * tall * 0.5),
                (seg * gap, thickness, tall * k),
                Matrix.Rotation(turn, 3, "Z"),
            )


def build_fringe(
    bm,
    target,
    z=-0.26,
    drop=0.30,
    thickness=0.08,
    standoff=None,
    count=12,
    face_clear=0.80,
    width=1.0,
    jitter=0.0,
    seed=1,
    corner=0.30,
    role="Accent",
):
    """Ragged strands hanging off a rim, all the way round except across the
    face - moss off a fen hood, a mantle's edge, a hem.

    `face_clear` is the fraction of the target's own width kept OPEN at the
    front, so on a head the strands frame the face and never cross it. Each
    strand is a _plate turned to its side's outward normal (the +X and back
    sides need the extra half-turn or their chamfered faces point inward and
    the fringe reads inside-out from behind)."""
    off = (STANDOFF[role] if role in STANDOFF else STANDOFF["Accent"]) if standoff is None else standoff
    off = min(off, MAX_STANDOFF - thickness)
    s = fit_size(target)
    hx = s.x / 2 + off + thickness / 2
    hy = s.y / 2 + off + thickness / 2
    top = s.z * z
    floor = -(s.z / 2 + MAX_STANDOFF)
    for i, (x, y, turn, seg) in enumerate(_perimeter(hx, hy, count)):
        if _crosses_face(x, seg * 1.02 * width / 2, y, s, face_clear):
            continue
        fall = min(drop * (1.0 + _jitter(seed, i, jitter)), top - floor)
        if fall <= 0.02:
            continue
        flip = math.pi if ((abs(turn) < 0.1 and y > 0) or (abs(turn) > 0.1 and x < 0)) else 0.0
        _plate(
            bm,
            (x, y, top - fall / 2),
            (seg * 1.02 * width, thickness, fall),
            Matrix.Rotation(turn + flip, 3, "Z"),
            corner=corner,
        )


def build_wraps(
    bm,
    target,
    count=3,
    top=0.34,
    bottom=-0.36,
    height=0.12,
    thickness=0.09,
    standoff=None,
    role="Trim",
    ring=8,
    taper=0.0,
):
    """Several narrow belts down a limb: a wrapped forearm, a boot's strap
    rows, a lashed greave. build_ring_band is ONE belt and carries a buckle;
    this is the repeat, which is what makes a wrap read as a wrap."""
    off = (STANDOFF[role] if role in STANDOFF else STANDOFF["Trim"]) if standoff is None else standoff
    off = min(off, MAX_STANDOFF - thickness)
    s = fit_size(target)
    hx = s.x / 2 + off + thickness / 2
    hy = s.y / 2 + off + thickness / 2
    for i in range(count):
        t = i / (count - 1) if count > 1 else 0.5
        _box_ring(bm, hx, hy, (top + (bottom - top) * t) * s.z, height * (1.0 - taper * t), thickness, ring)


# --------------------------------------------------------------- SET_SPEC
#
# ONE BLOCK PER SET. Wave 0 lands the MECHANISM and the declared exceptions;
# the garment lists fill in per wave (1: Chitin + Tideward, 2: Mirewalker +
# Boneplate + Rimebound, 3: Cindershell + Duskveil, 4: CorsairsRest +
# Stormcaller + Wraithbound). Until a set's lists are filled it keeps
# exporting its LEGACY single-part builders from SETS below, unchanged, and
# ArmorService keeps wearing them - which is what makes each wave a
# non-breaking change instead of a flag day.
#
# Shape of a filled-in slot list:
#
#     "Chest": [
#         {"target": "UpperTorso", "role": "Under",  "build": build_glove},
#         {"target": "UpperTorso", "role": "Plate",  "build": build_shell_plate,
#          "args": {"wrap": 0.78, "thickness": 0.14}},
#         {"target": "LeftUpperArm", "role": "Plate", "build": build_pauldron,
#          "mirror": True},
#     ],
#
# `mirror: True` authors the left side and emits the right by negating X.
#
# `fit_exceptions` lists OBJECT NAMES check_fit() is allowed to skip. An
# exception is a decision ON THE RECORD - a cape, a ruff, a hem - never an
# accident, and the reason each one is here is written beside it.
SET_SPEC = {
    # CHITIN SHELL - a fisherman lashing crab shell to himself with fishing
    # line. Handmade and cheap, NOT monstrous: a dark kelp-weave bodysuit under
    # a FEW BIG pale shells, and the cord is the detail that carries it.
    #
    # The plates are arranged like a crab's back: ONE large dorsal scute, then
    # smaller marginal plates lapping downward off it, then small lames only on
    # the forearms and shins. Slight size jitter and a domed centre on each
    # shell - a carapace is not a printed grid. The under-suit is left showing
    # at the elbow, the knee and the waist as deliberate negative space.
    #
    # Deleted from the legacy helm/chest/legs: two brow horns, three crest
    # spines, two eye-stalks, five front spines, two dorsal spines, the
    # oversized crab-claw pauldron, three flank spine pairs and the tail plate
    # - 18 protrusions, nothing tapering to a point left in the set.
    "Chitin": {
        "Helm": [
            {"target": "Head", "role": "Under", "build": build_coif, "args": {"aperture": 0.40, "brow": 0.19}},
            # Domed shell cap, ridge along the crown, cheek scutes beside the face.
            {"target": "Head", "role": "Plate", "build": build_shell_cap, "args": {"thickness": 0.11, "standoff": 0.18, "dome": 0.92, "brow": 0.17, "cheek": 1.0, "ridge": 0.16, "bevel": 0.10}},
            # Cord round the shell with a chinstrap dropping past the cheeks.
            {"target": "Head", "role": "Trim", "build": build_ring_band, "args": {"z": 0.34, "height": 0.09, "thickness": 0.08, "standoff": 0.12, "count": 12, "straps": 0.26, "strap_drop": 0.60}},
            {"target": "Head", "role": "Accent", "build": build_studs, "args": {"spots": ((-0.90, -0.30), (0.90, -0.30)), "radius": 0.09, "standoff": 0.17}},
        ],
        "Chest": [
            {"target": "UpperTorso", "role": "Under", "build": build_glove},
            {"target": "LeftUpperArm", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LeftLowerArm", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LeftHand", "role": "Under", "build": build_glove, "mirror": True},
            # THE CARAPACE: one large domed dorsal scute over the chest and the
            # back, with three marginal plates lapping downward off it.
            {"target": "UpperTorso", "role": "Plate", "build": build_lames, "args": {"rows": (1, 3), "weights": (2.2, 1.0), "face": "both", "wrap": 0.74, "top": 0.50, "bottom": -0.34, "thickness": 0.12, "standoff": 0.16, "overlap": 0.22, "curve": 0.20, "step": 0.03, "tilt": 7.0, "jitter": 0.10, "seed": 3, "dome": 0.07, "corner": 0.36}},
            # MEDIUM: one shell shoulder cap plus a marginal plate under it.
            {"target": "LeftUpperArm", "role": "Plate", "build": build_lames, "mirror": True, "args": {"rows": (1, 1), "weights": (1.5, 1.0), "face": "both", "wrap": 0.84, "top": 0.50, "bottom": -0.22, "thickness": 0.11, "standoff": 0.16, "overlap": 0.22, "curve": 0.14, "step": 0.024, "tilt": 7.0, "jitter": 0.08, "seed": 5, "dome": 0.045, "corner": 0.34, "cap": 0.78, "cap_count": 2}},
            # SMALL: two lames on the forearm only, leaving the elbow soft.
            {"target": "LeftLowerArm", "role": "Plate", "build": build_lames, "mirror": True, "args": {"rows": (1, 1), "face": "front", "wrap": 0.88, "top": 0.24, "bottom": -0.48, "thickness": 0.10, "standoff": 0.16, "overlap": 0.24, "curve": 0.12, "step": 0.02, "tilt": 7.0, "jitter": 0.08, "seed": 7, "dome": 0.035, "corner": 0.34}},
            # The lashing, authored PROUD of the shells so it reads.
            {"target": "UpperTorso", "role": "Trim", "build": build_lacing, "args": {"rungs": 3, "radius": 0.055, "standoff": 0.21, "top": 0.06, "bottom": -0.44, "spread": 0.24, "toggles": 3, "toggle": 0.16}},
            {"target": "LeftLowerArm", "role": "Accent", "build": build_scale_patch, "mirror": True, "args": {"rows": (2,), "standoff": 0.19, "top": 0.46, "bottom": 0.16, "wrap": 0.60}},
        ],
        "Legs": [
            {"target": "LowerTorso", "role": "Under", "build": build_glove},
            {"target": "LeftUpperLeg", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LeftLowerLeg", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LeftFoot", "role": "Under", "build": build_glove, "mirror": True},
            # A short shell fauld off the hip line: three marginal plates, front
            # and back, hanging past the hip box onto the thigh.
            {"target": "LowerTorso", "role": "Plate", "build": build_lames, "args": {"rows": (3,), "face": "both", "wrap": 0.86, "top": 0.10, "bottom": -1.02, "thickness": 0.12, "standoff": 0.15, "overlap": 0.22, "curve": 0.18, "tilt": 8.0, "jitter": 0.08, "seed": 11, "dome": 0.05, "corner": 0.34}},
            # SMALL: two shin lames, knee left soft.
            {"target": "LeftLowerLeg", "role": "Plate", "build": build_lames, "mirror": True, "args": {"rows": (1, 1), "face": "front", "wrap": 0.88, "top": 0.26, "bottom": -0.50, "thickness": 0.11, "standoff": 0.16, "overlap": 0.24, "curve": 0.12, "step": 0.02, "tilt": 7.0, "jitter": 0.08, "seed": 13, "dome": 0.04, "corner": 0.34}},
            {"target": "LeftFoot", "role": "Plate", "build": build_boot_cap, "mirror": True, "args": {"thickness": 0.11, "standoff": 0.13, "toe": 0.22}},
            # Driftwood belt with a buckle at the front.
            {"target": "LowerTorso", "role": "Trim", "build": build_ring_band, "args": {"z": 0.34, "height": 0.21, "thickness": 0.12, "standoff": 0.17, "count": 14, "buckle": 0.30}},
            {"target": "LeftUpperLeg", "role": "Accent", "build": build_scale_patch, "mirror": True, "args": {"rows": (2,), "standoff": 0.19, "top": -0.06, "bottom": -0.40, "wrap": 0.62}},
        ],
        # Nothing needs one. The shell cap is 0.89 on a 0.60 head, the carapace
        # 1.16 on a 1.00 torso, the fauld stops inside the hip box + 0.30. The
        # set that WAS the worst offender in the pack (x = -1.32 claw) now has
        # no declared exception at all.
        "fit_exceptions": [],
    },
    # TIDEWARD - lacquered scale lames clasped with pearl: the village's best
    # work, made for leaving, and the most CIVILISED set in the game. Where
    # Chitin is jittered, domed and lashed, Tideward is ORDERED and DEAD FLAT -
    # the same builder with the jitter off, the dome at zero and crisp
    # horizontal bands of four lames whose chamfered lower edges draw the row
    # lines at game distance.
    #
    # Pearl is the set's signature, so it appears three times and is big enough
    # to see: brow, throat and both wrists, each one SET INTO a small plate.
    # Helm is a smooth rounded lacquered coif with a short curved brim at the
    # brow and a scale tail down the nape; face open.
    "Tideward": {
        "Helm": [
            {"target": "Head", "role": "Under", "build": build_coif, "args": {"aperture": 0.40, "brow": 0.17}},
            # Smooth lacquered coif: no ridge, no cheek scutes, a curved brim
            # at the brow and four lames tailing down the nape.
            {"target": "Head", "role": "Plate", "build": build_shell_cap, "args": {"thickness": 0.10, "standoff": 0.17, "dome": 0.56, "brow": 0.0, "cheek": 0.0, "tail": 4, "brim": 0.88, "brim_z": 0.16, "brim_thickness": 0.13, "bevel": 0.13}},
            {"target": "Head", "role": "Trim", "build": build_ring_band, "args": {"z": 0.36, "height": 0.10, "thickness": 0.08, "standoff": 0.12, "count": 12, "buckle": 0.20}},
            # The pearl at the brow, set into its own small plate.
            {"target": "Head", "role": "Accent", "build": build_studs, "args": {"spots": ((0.0, 0.40),), "radius": 0.14, "standoff": 0.15, "seat": 2.6}},
        ],
        "Chest": [
            {"target": "UpperTorso", "role": "Under", "build": build_glove},
            {"target": "LeftUpperArm", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LeftLowerArm", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LeftHand", "role": "Under", "build": build_glove, "mirror": True},
            # THE LAMELLAR COAT: three crisp bands of four flat lames, front and
            # back. Each lame is 0.65 x 0.41 studs - five times the 0.12
            # readability floor - and the waist is left bare on purpose.
            {"target": "UpperTorso", "role": "Plate", "build": build_lames, "args": {"rows": (4, 4, 4), "face": "both", "wrap": 0.88, "top": 0.50, "bottom": -0.30, "thickness": 0.09, "standoff": 0.18, "overlap": 0.15, "curve": 0.13, "step": 0.018, "tilt": 7.0, "jitter": 0.0, "seed": 21, "corner": 0.30}},
            # The short scale mantle: two bands plus a flat cap over the shoulder.
            {"target": "LeftUpperArm", "role": "Plate", "build": build_lames, "mirror": True, "args": {"rows": (2, 2), "face": "both", "wrap": 0.86, "top": 0.50, "bottom": -0.20, "thickness": 0.09, "standoff": 0.17, "overlap": 0.15, "curve": 0.13, "step": 0.014, "tilt": 7.0, "jitter": 0.0, "seed": 23, "corner": 0.30, "cap": 0.80, "cap_count": 2}},
            # Scale bracers - small lames, elbow left bare.
            {"target": "LeftLowerArm", "role": "Plate", "build": build_lames, "mirror": True, "args": {"rows": (2, 2), "face": "front", "wrap": 0.88, "top": 0.22, "bottom": -0.48, "thickness": 0.09, "standoff": 0.17, "overlap": 0.15, "curve": 0.11, "step": 0.014, "tilt": 7.0, "jitter": 0.0, "seed": 25, "corner": 0.30}},
            # Pearl clasp at the throat - the closure the set is named for.
            {"target": "UpperTorso", "role": "Accent", "build": build_studs, "args": {"spots": ((0.0, 0.82),), "radius": 0.14, "standoff": 0.21, "seat": 2.8}},
            # ...and the wrist clasps.
            {"target": "LeftLowerArm", "role": "Accent", "build": build_studs, "mirror": True, "args": {"spots": ((0.0, 0.66),), "radius": 0.12, "standoff": 0.20, "seat": 2.6}},
        ],
        "Legs": [
            {"target": "LowerTorso", "role": "Under", "build": build_glove},
            {"target": "LeftUpperLeg", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LeftLowerLeg", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LeftFoot", "role": "Under", "build": build_glove, "mirror": True},
            # The coat's hip-length hem, in the same crisp bands.
            {"target": "LowerTorso", "role": "Plate", "build": build_lames, "args": {"rows": (4, 4), "face": "both", "wrap": 0.88, "top": 0.10, "bottom": -1.14, "thickness": 0.09, "standoff": 0.16, "overlap": 0.15, "curve": 0.17, "step": 0.018, "tilt": 7.0, "jitter": 0.0, "seed": 27, "corner": 0.30}},
            # MEDIUM: one flat thigh plate each, knee left bare.
            {"target": "LeftUpperLeg", "role": "Plate", "build": build_scute, "mirror": True, "args": {"face": "front", "wrap": 0.80, "top": 0.30, "bottom": -0.18, "thickness": 0.10, "standoff": 0.16, "curve": 0.12, "tilt": 6.0, "corner": 0.30}},
            # Tall scale-faced sea boots: two bands down the shin.
            {"target": "LeftLowerLeg", "role": "Plate", "build": build_lames, "mirror": True, "args": {"rows": (2, 2), "face": "both", "wrap": 0.88, "top": 0.24, "bottom": -0.52, "thickness": 0.09, "standoff": 0.16, "overlap": 0.15, "curve": 0.12, "step": 0.014, "tilt": 7.0, "jitter": 0.0, "seed": 31, "corner": 0.30}},
            {"target": "LeftFoot", "role": "Plate", "build": build_boot_cap, "mirror": True, "args": {"thickness": 0.10, "standoff": 0.13, "toe": 0.20}},
            # The rope belt, with its buckle.
            {"target": "LowerTorso", "role": "Trim", "build": build_ring_band, "args": {"z": 0.40, "height": 0.14, "thickness": 0.10, "standoff": 0.17, "count": 14, "buckle": 0.26}},
        ],
        # NONE. Wave 0 reserved one for a wide sou'wester brim; the brim the set
        # actually got is a 0.13-thick ring at x +/-0.88, inside a 0.60 head's
        # own MAX_STANDOFF (0.90) - so the exception was deleted rather than
        # left on file unused. An exception nobody needs is how a gate's output
        # starts getting skimmed.
        "fit_exceptions": [],
    },
    # MIREWALKER - a poacher's hooded long coat out of Blackmire Fen, and the
    # set that must read SOFT. LEATHER, NOT PLATE: the Under role is not a
    # body glove here, it IS the coat - peat-black cured hide, Enum.Material
    # Leather - and the hard parts are deliberately FEW AND LARGE: a scute
    # brow, two shoulder scutes, a spine run down the back, two knee caps, two
    # shin scutes. Nothing hard on the chest at all; that is the whole point of
    # difference from Chitin's carapace and Boneplate's cuirass.
    #
    # The silhouette read is HOOD + LONG HEM + no shoulder line, which is the
    # opposite of the two lamellar sets' shoulder-cap read. The hood is a
    # three-step-chamfered cowl (rounded, low, face open) rather than the
    # bevelled box wave 1's helms used, and the moss fringe hanging beside the
    # face - never across it - is what says "fen" at 60 studs.
    #
    # Every lame here is dome 0. Hide and scute are flat; only bone and shell
    # earn a dome, and this set has neither.
    #
    # Deleted from the legacy build: two snapped-reed antlers (+1.00 above the
    # crown), the shelf-fungi stack, the shoulder sapling, the root lacing, the
    # cone at the hip and the shard - the whole z = +2.13 collar.
    "Mirewalker": {
        "Helm": [
            {"target": "Head", "role": "Under", "build": build_coif, "args": {"aperture": 0.42, "brow": 0.18}},
            {"target": "Head", "role": "Under", "n": 2, "build": build_cowl, "args": {"drape": 0.17, "aperture": 0.52, "peak": 0.09, "chamfer": 3, "bevel": 0.15}},
            {"target": "Head", "role": "Plate", "build": build_brow_plate, "args": {"width": 0.88, "shelf": 0.28, "thickness": 0.12, "standoff": 0.15, "rake": -18.0, "corner": 0.26}},
            {"target": "Head", "role": "Trim", "build": build_ring_band, "args": {"z": 0.30, "height": 0.09, "thickness": 0.08, "standoff": 0.11, "count": 12, "straps": 0.24, "strap_drop": 0.52}},
            {"target": "Head", "role": "Accent", "build": build_fringe, "args": {"z": -0.04, "drop": 0.34, "thickness": 0.08, "standoff": 0.20, "count": 14, "face_clear": 0.94, "jitter": 0.26, "seed": 41, "corner": 0.18}},
        ],
        "Chest": [
            {"target": "UpperTorso", "role": "Under", "build": build_glove},
            {"target": "LeftUpperArm", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LeftLowerArm", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LeftHand", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LeftUpperArm", "role": "Plate", "build": build_lames, "mirror": True, "args": {"rows": (1,), "face": "both", "wrap": 0.86, "top": 0.50, "bottom": -0.08, "thickness": 0.13, "standoff": 0.17, "overlap": 0.18, "curve": 0.12, "tilt": 8.0, "dome": 0.0, "corner": 0.34, "cap": 0.86, "cap_count": 2}},
            {"target": "UpperTorso", "role": "Plate", "build": build_lames, "args": {"rows": (1, 1, 1), "face": "back", "wrap": 0.42, "top": 0.50, "bottom": -0.42, "thickness": 0.13, "standoff": 0.18, "overlap": 0.20, "curve": 0.03, "step": 0.02, "tilt": 8.0, "dome": 0.0, "corner": 0.30}},
            {"target": "UpperTorso", "role": "Accent", "build": build_lames, "args": {"rows": (1, 1), "face": "both", "wrap": 0.94, "top": 0.50, "bottom": 0.20, "thickness": 0.09, "standoff": 0.13, "overlap": 0.10, "curve": 0.18, "step": 0.014, "tilt": 6.0, "dome": 0.0, "corner": 0.24}},
            {"target": "UpperTorso", "role": "Trim", "build": build_ring_band, "args": {"z": -0.26, "height": 0.17, "thickness": 0.11, "standoff": 0.16, "count": 14, "buckle": 0.30}},
            {"target": "UpperTorso", "role": "Trim", "n": 2, "build": build_studs, "args": {"spots": ((-0.74, 0.60), (-0.36, 0.72), (0.36, 0.72), (0.74, 0.60)), "radius": 0.07, "standoff": 0.17}},
            {"target": "LeftLowerArm", "role": "Trim", "n": 3, "build": build_wraps, "mirror": True, "args": {"count": 3, "top": 0.38, "bottom": -0.40, "height": 0.13, "thickness": 0.10, "standoff": 0.14, "ring": 8}},
        ],
        "Legs": [
            {"target": "LowerTorso", "role": "Under", "build": build_glove},
            {"target": "LeftUpperLeg", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LeftLowerLeg", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LeftFoot", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LowerTorso", "role": "Under", "n": 2, "build": build_fringe, "args": {"z": -0.16, "drop": 0.42, "thickness": 0.11, "standoff": 0.09, "count": 16, "face_clear": 0.0, "jitter": 0.12, "seed": 47, "corner": 0.12}},
            {"target": "LeftUpperLeg", "role": "Plate", "build": build_lames, "mirror": True, "args": {"rows": (1,), "face": "front", "wrap": 0.82, "top": -0.02, "bottom": -0.48, "thickness": 0.13, "standoff": 0.17, "overlap": 0.16, "curve": 0.10, "tilt": 7.0, "dome": 0.0, "corner": 0.36}},
            {"target": "LeftLowerLeg", "role": "Plate", "build": build_lames, "mirror": True, "args": {"rows": (1,), "face": "front", "wrap": 0.84, "top": 0.28, "bottom": -0.34, "thickness": 0.12, "standoff": 0.16, "overlap": 0.14, "curve": 0.10, "tilt": 7.0, "dome": 0.0, "corner": 0.32}},
            {"target": "LowerTorso", "role": "Trim", "build": build_ring_band, "args": {"z": 0.30, "height": 0.19, "thickness": 0.12, "standoff": 0.16, "count": 14, "buckle": 0.32}},
            {"target": "LeftLowerLeg", "role": "Trim", "n": 2, "build": build_wraps, "mirror": True, "args": {"count": 3, "top": 0.34, "bottom": -0.44, "height": 0.12, "thickness": 0.10, "standoff": 0.14, "ring": 8}},
        ],
        # NONE. The cowl is 0.84 on a 0.60 head, the moss fringe 0.88, the coat
        # hem stops inside the hip box + 0.30, and the shoulder scutes are the
        # only thing near the shoulder line at x 1.19 against a 1.35 limit.
        "fit_exceptions": [],
    },
    # BONEPLATE - brine-blackened bone over a dark under-suit, and NOT a
    # skeleton costume: the legacy build was a literal fish skull worn as a
    # crown with 1.14 studs of snout in front of the face and a free-standing
    # ribcage. What lands instead is a CUIRASS of long curved bone plates with
    # a NACRE LINING showing at every plate edge.
    #
    # That lining is the one trick in the set and it is done with geometry, not
    # with a texture the game cannot show: the Accent object repeats the Plate
    # object's own rows at a SMALLER standoff (0.13 against 0.17) and a WIDER
    # wrap and overlap, so the pale nacre sits just under and just outside each
    # bone plate and shows as a rim of pearl light around it. Dark, wet, cursed
    # - with the light at the edges.
    #
    # This is the one wave-2 set whose lames are DOMED, and only slightly
    # (0.05): bone is genuinely curved, and the standing note is that a plate
    # is dead flat unless the MATERIAL is domed. Hide, scute, wool and
    # everfrost are not; bone is.
    #
    # The helm is a bone half-mask - a three-step-chamfered skull cap with a
    # brow shelf and two cheek scutes framing an OPEN face (Boneplate is not in
    # HIDES_FACE and must not become a full mask), nacre inlay round the crown,
    # and two ghost-green temple glints outboard of the face box.
    "Boneplate": {
        "Helm": [
            {"target": "Head", "role": "Under", "build": build_coif, "args": {"aperture": 0.42, "brow": 0.18}},
            {"target": "Head", "role": "Plate", "build": build_shell_cap, "args": {"thickness": 0.11, "standoff": 0.16, "dome": 0.74, "brow": 0.17, "cheek": 0.98, "tail": 3, "bevel": 0.12, "chamfer": 3}},
            {"target": "Head", "role": "Accent", "build": build_ring_band, "args": {"z": 0.30, "height": 0.07, "thickness": 0.06, "standoff": 0.20, "count": 14}},
            {"target": "Head", "role": "Trim", "build": build_studs, "args": {"spots": ((-0.92, -0.10), (0.92, -0.10), (-0.88, 0.52), (0.88, 0.52)), "radius": 0.07, "standoff": 0.19}},
            {"target": "Head", "role": "Glow", "build": build_studs, "args": {"spots": ((-0.95, 0.16), (0.95, 0.16)), "radius": 0.075, "standoff": 0.18, "seat": 2.2}},
        ],
        "Chest": [
            {"target": "UpperTorso", "role": "Under", "build": build_glove},
            {"target": "LeftUpperArm", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LeftLowerArm", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LeftHand", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "UpperTorso", "role": "Plate", "build": build_lames, "args": {"rows": (1, 2), "weights": (2.4, 1.0), "face": "both", "wrap": 0.80, "top": 0.50, "bottom": -0.32, "thickness": 0.12, "standoff": 0.17, "overlap": 0.18, "curve": 0.20, "step": 0.028, "tilt": 7.0, "dome": 0.05, "corner": 0.30}},
            {"target": "UpperTorso", "role": "Accent", "build": build_lames, "args": {"rows": (1, 2), "weights": (2.4, 1.0), "face": "both", "wrap": 0.88, "top": 0.52, "bottom": -0.34, "thickness": 0.08, "standoff": 0.12, "overlap": 0.26, "curve": 0.20, "step": 0.028, "tilt": 7.0, "dome": 0.0, "corner": 0.30}},
            {"target": "UpperTorso", "role": "Accent", "n": 2, "build": build_ring_band, "args": {"z": 0.42, "height": 0.10, "thickness": 0.08, "standoff": 0.20, "count": 16}},
            {"target": "UpperTorso", "role": "Trim", "build": build_studs, "args": {"spots": ((-0.80, 0.66), (0.80, 0.66), (-0.86, -0.10), (0.86, -0.10), (0.0, 0.30)), "radius": 0.07, "standoff": 0.19}},
            {"target": "LeftUpperArm", "role": "Plate", "build": build_lames, "mirror": True, "args": {"rows": (1,), "face": "both", "wrap": 0.86, "top": 0.50, "bottom": -0.12, "thickness": 0.12, "standoff": 0.16, "overlap": 0.18, "curve": 0.14, "tilt": 7.0, "dome": 0.05, "corner": 0.32, "cap": 0.84, "cap_count": 2}},
            {"target": "LeftLowerArm", "role": "Plate", "build": build_lames, "mirror": True, "args": {"rows": (1, 1), "face": "front", "wrap": 0.88, "top": 0.26, "bottom": -0.48, "thickness": 0.11, "standoff": 0.16, "overlap": 0.20, "curve": 0.12, "step": 0.02, "tilt": 7.0, "dome": 0.045, "corner": 0.32}},
        ],
        "Legs": [
            {"target": "LowerTorso", "role": "Under", "build": build_glove},
            {"target": "LeftUpperLeg", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LeftLowerLeg", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LeftFoot", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LowerTorso", "role": "Plate", "build": build_lames, "args": {"rows": (2,), "face": "both", "wrap": 0.86, "top": 0.10, "bottom": -1.00, "thickness": 0.12, "standoff": 0.16, "overlap": 0.18, "curve": 0.18, "tilt": 8.0, "dome": 0.05, "corner": 0.32}},
            {"target": "LeftUpperLeg", "role": "Plate", "build": build_lames, "mirror": True, "args": {"rows": (1,), "face": "front", "wrap": 0.82, "top": 0.24, "bottom": -0.40, "thickness": 0.12, "standoff": 0.16, "overlap": 0.16, "curve": 0.12, "tilt": 7.0, "dome": 0.05, "corner": 0.32}},
            {"target": "LeftLowerLeg", "role": "Plate", "build": build_lames, "mirror": True, "args": {"rows": (1, 1), "face": "front", "wrap": 0.88, "top": 0.28, "bottom": -0.48, "thickness": 0.11, "standoff": 0.16, "overlap": 0.20, "curve": 0.12, "step": 0.02, "tilt": 7.0, "dome": 0.045, "corner": 0.32}},
            {"target": "LeftFoot", "role": "Plate", "build": build_boot_cap, "mirror": True, "args": {"thickness": 0.11, "standoff": 0.13, "toe": 0.22}},
            {"target": "LowerTorso", "role": "Trim", "build": build_ring_band, "args": {"z": 0.34, "height": 0.18, "thickness": 0.11, "standoff": 0.17, "count": 14, "buckle": 0.28}},
        ],
        "fit_exceptions": [],
    },
    # RIMEBOUND - WARM UNDER COLD. A thick white rimewool under-suit with a
    # visible fur collar, fur cuffs and fur boot tops, under smooth translucent
    # everfrost slabs on chest, shoulders, thighs and shins. Chunky but FLAT:
    # everfrost is a slab of ice, not a dome, so every lame here is dome 0 and
    # wrapped in ONE big plate per surface rather than in rows - the only set
    # in the pack whose plates are single large panels.
    #
    # Two palette rows moved for this set and both are recorded in
    # armor_palette.py: the Plate is now transparency 0.12 (a slab of ice that
    # renders opaque is the material lying about itself), and the Trim's
    # material is Snow rather than Leather, because this row dresses the fur
    # and Leather on a ruff is a shiny strap. The Trim COLOUR is unchanged -
    # dark sealskin is the only value separation in a set that is otherwise
    # white on pale blue.
    #
    # THE RUFF FITS. Wave 0 pre-declared an exception for it at x +/-0.95; the
    # ruff that actually landed is two staggered layers of blocks whose
    # outermost reaches x +/-0.90, which is exactly the 0.60 head plus
    # MAX_STANDOFF, with the ice shell under it at +/-0.74. The exception was
    # DELETED rather than left on file - an exception nobody needs is how a
    # gate's output starts getting skimmed.
    #
    # The glacier shards are low rounded studs. No spikes: the set's hard read
    # comes from the slabs' chamfered edges and the fur's broken outline.
    "Rimebound": {
        "Helm": [
            {"target": "Head", "role": "Under", "build": build_coif, "args": {"aperture": 0.40, "brow": 0.17}},
            {"target": "Head", "role": "Plate", "build": build_shell_cap, "args": {"thickness": 0.11, "standoff": 0.14, "dome": 0.64, "brow": 0.15, "cheek": 0.96, "bevel": 0.12, "chamfer": 3}},
            {"target": "Head", "role": "Trim", "build": build_ruff, "args": {"z": -0.26, "height": 0.30, "thickness": 0.15, "standoff": 0.10, "count": 16, "layers": 2, "step": 0.05, "stagger": 0.07, "shrink": 0.16, "face_clear": 0.92}},
            {"target": "Head", "role": "Accent", "build": build_studs, "args": {"spots": ((-0.92, 0.40), (0.92, 0.40), (0.0, 0.62)), "radius": 0.085, "standoff": 0.17, "seat": 2.2}},
        ],
        "Chest": [
            {"target": "UpperTorso", "role": "Under", "build": build_glove},
            {"target": "LeftUpperArm", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LeftLowerArm", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LeftHand", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "UpperTorso", "role": "Plate", "build": build_lames, "args": {"rows": (1,), "face": "both", "wrap": 0.76, "top": 0.42, "bottom": -0.26, "thickness": 0.15, "standoff": 0.15, "overlap": 0.0, "curve": 0.18, "tilt": 5.0, "dome": 0.0, "corner": 0.30, "bevel": 0.18}},
            {"target": "LeftUpperArm", "role": "Plate", "build": build_lames, "mirror": True, "args": {"rows": (1,), "face": "both", "wrap": 0.84, "top": 0.46, "bottom": -0.12, "thickness": 0.14, "standoff": 0.15, "overlap": 0.06, "curve": 0.14, "tilt": 6.0, "dome": 0.0, "corner": 0.32, "bevel": 0.18, "cap": 0.84, "cap_count": 2}},
            {"target": "UpperTorso", "role": "Trim", "build": build_ruff, "args": {"z": 0.40, "height": 0.26, "thickness": 0.15, "standoff": 0.10, "count": 16, "layers": 2, "step": 0.05, "stagger": 0.06, "shrink": 0.16}},
            {"target": "LeftLowerArm", "role": "Trim", "n": 2, "build": build_ruff, "mirror": True, "args": {"z": -0.34, "height": 0.20, "thickness": 0.13, "standoff": 0.12, "count": 10, "layers": 2, "step": 0.04, "stagger": 0.05, "shrink": 0.18}},
            {"target": "UpperTorso", "role": "Accent", "build": build_studs, "args": {"spots": ((-0.62, 0.20), (0.62, 0.20), (0.0, -0.10)), "radius": 0.09, "standoff": 0.18, "seat": 2.0}},
            {"target": "UpperTorso", "role": "Glow", "build": build_ring_band, "args": {"z": 0.26, "height": 0.06, "thickness": 0.05, "standoff": 0.22, "count": 16}},
        ],
        "Legs": [
            {"target": "LowerTorso", "role": "Under", "build": build_glove},
            {"target": "LeftUpperLeg", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LeftLowerLeg", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LeftFoot", "role": "Under", "build": build_glove, "mirror": True},
            {"target": "LeftUpperLeg", "role": "Plate", "build": build_lames, "mirror": True, "args": {"rows": (1,), "face": "front", "wrap": 0.82, "top": 0.30, "bottom": -0.40, "thickness": 0.14, "standoff": 0.15, "overlap": 0.0, "curve": 0.12, "tilt": 5.0, "dome": 0.0, "corner": 0.32, "bevel": 0.18}},
            {"target": "LeftLowerLeg", "role": "Plate", "build": build_lames, "mirror": True, "args": {"rows": (1,), "face": "front", "wrap": 0.84, "top": 0.24, "bottom": -0.46, "thickness": 0.14, "standoff": 0.15, "overlap": 0.0, "curve": 0.12, "tilt": 5.0, "dome": 0.0, "corner": 0.32, "bevel": 0.18}},
            {"target": "LeftFoot", "role": "Trim", "build": build_ruff, "mirror": True, "args": {"z": 0.30, "height": 0.16, "thickness": 0.13, "standoff": 0.12, "count": 10, "layers": 2, "step": 0.04, "stagger": 0.04, "shrink": 0.18}},
            {"target": "LowerTorso", "role": "Trim", "n": 2, "build": build_ring_band, "args": {"z": 0.30, "height": 0.17, "thickness": 0.11, "standoff": 0.17, "count": 14, "buckle": 0.28}},
        ],
        "fit_exceptions": [],
    },
    "Cindershell": {"Helm": [], "Chest": [], "Legs": [], "fit_exceptions": []},
    "Duskveil": {
        "Helm": [],
        "Chest": [],
        "Legs": [],
        # The lantern lure on its stalk, above the brow. The one protrusion
        # kept in the whole redesign.
        "fit_exceptions": ["Duskveil_Helm_Head_Glow"],
    },
    "Wraithbound": {
        "Helm": [],
        "Chest": [],
        "Legs": [],
        # The shroud: one hem on the LEGS piece at -1.10, replacing today's
        # 1.51-stud chest skirt AND 1.65-stud leg drop. A shroud is the
        # silhouette.
        "fit_exceptions": ["Wraithbound_Legs_LowerTorso_Trim"],
    },
    "CorsairsRest": {
        "Helm": [],
        "Chest": [],
        "Legs": [],
        # The bicorne's brim (thin, x +/-1.00) and the half-cape of spectral
        # sailcloth over the LEFT shoulder only.
        "fit_exceptions": [
            "CorsairsRest_Helm_Head_Plate",
            "CorsairsRest_Chest_UpperTorso_Accent",
        ],
    },
    "Stormcaller": {
        "Helm": [],
        "Chest": [],
        "Legs": [],
        # The halo ring, 0.25 off the back of the head. Pure silhouette, zero
        # bulk - it replaces the +1.63 crown spikes.
        "fit_exceptions": ["Stormcaller_Helm_Head_Plate2"],
    },
}


def build_spec(prefix, slot):
    """Every object one set's slot declares. Empty until that set's wave."""
    spec = SET_SPEC.get(prefix, {})
    objects = []
    for entry in spec.get(slot, []):
        target = entry["target"]
        role = entry["role"]
        bm = bmesh.new()
        entry["build"](bm, target, **entry.get("args", {}))
        obj = emit(prefix, slot, target, role, bm, entry.get("n"))
        objects.append(obj)
        if entry.get("mirror"):
            twin = FIT[target].get("mirror")
            if twin:
                objects.append(mirror_object(obj, obj_name(prefix, slot, twin, role, entry.get("n"))))
    return objects


# ----------------------------------------------------------------- gates
#
# All three print and never throw, the house style: a work-in-progress set
# still exports and can be looked at. They are the MECHANICAL half of the
# user's instruction - "not bulky, not spiky, covers the character" stops
# being a promise and becomes a number somebody has to answer for.

# A legacy two-field name has no <Target>; these are the parts each legacy
# slot was authored against, so the gates can measure the shipped pack too.
LEGACY_TARGET = {"Helm": "Head", "Chest": "UpperTorso", "Legs": "LowerTorso"}


def parse_name(name):
    """(prefix, slot, target, role) for a pack object, or None for a name that
    is neither shape. Legacy two-field names come back with the slot's own
    target and role None."""
    fields = name.split("_")
    if len(fields) == 4:
        return fields[0], fields[1], fields[2], fields[3].rstrip("0123456789")
    if len(fields) == 2 and fields[1] in LEGACY_TARGET:
        return fields[0], fields[1], LEGACY_TARGET[fields[1]], None
    return None


def _exceptions():
    names = set()
    for spec in SET_SPEC.values():
        names.update(spec.get("fit_exceptions", []))
    return names


def check_faces(objects):
    """Enforce the header's FACE BOX. Prints offenders; never throws, so a
    half-built set still exports and can be looked at.

    SKIPS the sets that declare hides_face (Duskveil, Wraithbound,
    Stormcaller). Those three are full masks BY DESIGN - the brief says so and
    armor_palette.HIDES_FACE is the one list of them. Without the skip this
    gate would print three permanent false violations, and a gate whose output
    is routinely ignored is a dead gate."""
    offenders = {}
    skipped = []
    for obj in objects:
        parsed = parse_name(obj.name)
        if not parsed or parsed[1] != "Helm":
            continue
        prefix = parsed[0]
        if armor_palette.hides_face(prefix):
            if prefix not in skipped:
                skipped.append(prefix)
            continue
        for vert in obj.data.vertices:
            x, y, z = vert.co
            if y <= -0.52 and abs(x) <= 0.40 and -0.60 <= z <= 0.00:
                entry = offenders.setdefault(obj.name, [0, None])
                entry[0] += 1
                if entry[1] is None or y < entry[1][1]:
                    entry[1] = (round(x, 2), round(y, 2), round(z, 2))
    if skipped:
        print("FACE BOX: skipping %s - declared full masks (hides_face)" % ", ".join(sorted(skipped)))
    if not offenders:
        print("FACE BOX: clear - every helm leaves the face open below the brow")
        return
    for name, (count, worst) in sorted(offenders.items()):
        print("FACE BOX VIOLATION: %s has %d vert(s) below the brow line, deepest at %s" % (name, count, worst))


def check_fit(objects):
    """Every object's bbox must lie inside its target's box + MAX_STANDOFF,
    and nothing may cross SHOULDER_CLEAR in x. Declared per-set exceptions are
    skipped by name. Prints one line per offender with the overshoot in studs.

    This is the gate the pack never had. The measured result on the SHIPPED
    30 pieces is helms averaging +0.47 of standoff per side on a 0.60 head and
    chests projecting 1.13 studs off a 0.50-deep torso - which is exactly why
    the armour reads bulky, and exactly what this number is for."""
    skip = _exceptions()
    offenders = []
    swing = []
    for obj in objects:
        if obj.name in skip:
            continue
        parsed = parse_name(obj.name)
        if not parsed:
            print("FIT: %s does not parse as a pack name - skipped" % obj.name)
            continue
        target = parsed[2]
        if target not in FIT:
            print("FIT: %s names target '%s', which is not in FIT" % (obj.name, target))
            continue
        half = fit_size(target) / 2
        lo = [min(v.co[i] for v in obj.data.vertices) for i in range(3)]
        hi = [max(v.co[i] for v in obj.data.vertices) for i in range(3)]
        over = []
        for i, axis in enumerate("xyz"):
            limit = half[i] + MAX_STANDOFF
            worst = max(hi[i] - limit, -lo[i] - limit)
            if worst > 0.005:
                over.append("%s +%.2f" % (axis, worst))
        if over:
            offenders.append((obj.name, target, ", ".join(over)))
        reach = max(hi[0], -lo[0])
        if reach > SHOULDER_CLEAR + 0.005:
            swing.append((obj.name, reach))
    if skip:
        print("FIT: %d declared exception(s) on file: %s" % (len(skip), ", ".join(sorted(skip))))
    if not offenders and not swing:
        print("FIT: clear - every object inside its target's box + %.2f" % MAX_STANDOFF)
    for name, target, over in sorted(offenders):
        print("FIT: %s stands off %s (limit is the %s box + %.2f)" % (name, over, target, MAX_STANDOFF))
    for name, reach in sorted(swing):
        print("FIT: %s reaches x %.2f - past SHOULDER_CLEAR %.2f, it fouls the arm swing" % (name, reach, SHOULDER_CLEAR))


def check_coverage(objects):
    """Every set x slot must emit at least one object on every target in
    SLOT_TARGETS for that slot. A missing LeftFoot is a bare ankle nobody
    would notice in a static render and everybody notices in play - the
    silent-absence shape this codebase keeps getting bitten by.

    A slot still on its LEGACY single part is reported as such rather than as
    twelve missing limbs: it is not a hole, it is a set that has not had its
    wave yet."""
    dressed = {}
    legacy = set()
    for obj in objects:
        parsed = parse_name(obj.name)
        if not parsed:
            continue
        prefix, slot, target, role = parsed
        if role is None:
            legacy.add((prefix, slot))
            continue
        dressed.setdefault((prefix, slot), set()).add(target)
    holes = 0
    for prefix in sorted(SETS):
        for slot in ("Helm", "Chest", "Legs"):
            if (prefix, slot) in legacy:
                continue
            covered = dressed.get((prefix, slot))
            if covered is None:
                print("COVERAGE: %s %s has no objects at all" % (prefix, slot))
                holes += 1
                continue
            missing = [t for t in SLOT_TARGETS[slot] if t not in covered]
            if missing:
                print("COVERAGE: %s %s leaves %s bare" % (prefix, slot, ", ".join(missing)))
                holes += 1
    if legacy:
        print(
            "COVERAGE: %d slot(s) still on the LEGACY single part (not yet rebuilt): %s"
            % (len(legacy), ", ".join("%s_%s" % p for p in sorted(legacy)))
        )
    if not holes and dressed:
        print("COVERAGE: clear - every rebuilt slot dresses every target in its region")


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
    """Every object in the pack. A set's slot comes from SET_SPEC once that
    set has had its wave; until then it comes from the LEGACY builder, byte
    for byte as it ships today. Both shapes export into the same pack and
    ArmorService wears either, which is what makes each wave a non-breaking
    change."""
    objects = []
    for prefix, builders in SETS.items():
        for slot, builder in zip(("Helm", "Chest", "Legs"), builders):
            spec_objects = build_spec(prefix, slot)
            if spec_objects:
                objects += spec_objects
            else:
                objects.append(builder())
    check_faces(objects)
    check_fit(objects)
    check_coverage(objects)
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


# ------------------------------------------------------- the mannequin preview
#
# THIS IS THE HIGHEST-VALUE PART OF THE FILE, because its absence caused the
# whole problem. The old render laid the 30 pieces out in a grid, floating in
# grey, with no body, no rig and no mannequin - so nothing in the pipeline had
# ever shown a piece ON A BODY, and nothing had ever revealed that the pieces
# do not fit one. Fit was authored blind against three constants.
#
# What lands instead:
#   * an R15 BLOCK MANNEQUIN built from FIT itself, in a relaxed A-pose, so a
#     mannequin/armour mismatch is impossible by construction - they are the
#     same table;
#   * one PNG per set, three views (three-quarter hero, front, back), the set
#     worn;
#   * a contact sheet, all ten side by side: the "do these read as ten
#     different sets at a glance?" image;
#   * HONEST COLOUR - materials come from armor_palette, Neon roles are
#     emissive and transparent roles carry their real alpha, so the render
#     shows what the game will show. A legacy single-part piece is drawn in
#     the set ROW's colour, because that is precisely what ArmorService paints
#     it: one flat tint over a whole piece, which is the look being replaced.

PREVIEW_SKIN = (0.61, 0.57, 0.53)  # sRGB; _linear() below converts


def _linear(rgb):
    """sRGB -> linear, for the PREVIEW ONLY.

    The pack's own materials (finish()) write colour/255 straight into Base
    Color with no gamma step, because that is the mapping the whole repo uses
    - WorldService.MESH_COLOR's numbers are derived from island_gen's
    constants exactly that way, and changing it would move every island. But
    Blender treats Base Color as LINEAR, so a palette colour pasted in raw
    renders about a stop and a half too bright. The result is the washed-out
    near-monochrome look the old preview had, which is precisely what stopped
    it from telling a reviewer anything.

    So the preview converts. The render then shows what Roblox shows, and
    "honest colour" is a property of the image rather than a hope."""
    out = []
    for c in rgb:
        out.append(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4)
    return tuple(out)
A_POSE = 15.0  # degrees the arms swing out, so shoulder AND arm plates read
SHOULDER_Z = 4.00  # top of UpperTorso in mannequin space - the arm pivot


def _pose(target):
    """The world matrix of a posed body part. Identity for everything but the
    arm chain, which swings out about the shoulder."""
    row = FIT.get(target) or {}
    if row.get("chain") != "arm":
        return Matrix.Identity(4)
    side = -1.0 if target.startswith("Left") else 1.0
    pivot = Vector((side * 1.0, 0.0, SHOULDER_Z))
    return (
        Matrix.Translation(pivot)
        @ Matrix.Rotation(math.radians(A_POSE) * -side, 4, "Y")
        @ Matrix.Translation(-pivot)
    )


def build_mannequin(name="Mannequin"):
    """One box per R15 part, at FIT's own sizes and centres. ~20 lines, and it
    is derived from the same table the armour is fitted to."""
    bm = bmesh.new()
    for target, row in FIT.items():
        m = _pose(target)
        box(bm, m @ Vector(row["center"]), Vector(row["size"]), m.to_3x3())
    return finish(name, bm, _linear(PREVIEW_SKIN))


def preview_material(prefix, role):
    """The material the GAME will give this object: palette colour, real
    alpha, and emission for the Neon roles. Cached by name."""
    key = "PV_%s_%s" % (prefix, role or "Row")
    mat = bpy.data.materials.get(key)
    if mat is not None:
        return mat
    if role is None:
        rgb = tuple(c / 255.0 for c in armor_palette.ROW_COLOR.get(prefix, (128, 128, 128)))
        row = None
    else:
        rgb = armor_palette.rgb01(prefix, role)
        row = armor_palette.row(prefix, role)
    mat = bpy.data.materials.new(key)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf:
        lit = _linear(rgb)
        bsdf.inputs["Base Color"].default_value = (*lit, 1.0)
        bsdf.inputs["Roughness"].default_value = 0.85
        if row and row.get("neon"):
            if "Emission Color" in bsdf.inputs:
                bsdf.inputs["Emission Color"].default_value = (*lit, 1.0)
            if "Emission Strength" in bsdf.inputs:
                bsdf.inputs["Emission Strength"].default_value = 2.4
            bsdf.inputs["Roughness"].default_value = 0.4
        alpha = 1.0 - (row["transparency"] if row else 0.0)
        if alpha < 1.0:
            bsdf.inputs["Alpha"].default_value = alpha
            for attr, value in (("blend_method", "BLEND"), ("surface_render_method", "BLENDED")):
                if hasattr(mat, attr):
                    try:
                        setattr(mat, attr, value)
                    except (TypeError, AttributeError):
                        pass
    return mat


def _instance(src, matrix, material=None):
    """A render-only copy of a source object at a world matrix. The mesh data
    is shared unless the copy needs its own material (the pack's exported
    materials are the legacy preview colours; the render wants the palette)."""
    copy = src.copy()
    if material is not None:
        copy.data = src.data.copy()
        if copy.data.materials:
            copy.data.materials[0] = material
        else:
            copy.data.materials.append(material)
    copy.hide_render = False
    bpy.context.collection.objects.link(copy)
    copy.matrix_world = matrix
    return copy


def _label(text, location, size=0.42):
    curve = bpy.data.curves.new(type="FONT", name="Label")
    curve.body = text
    curve.align_x = "CENTER"
    curve.size = size
    obj = bpy.data.objects.new("Label_" + text, curve)
    bpy.context.collection.objects.link(obj)
    obj.location = Vector(location)
    obj.rotation_euler = (math.radians(90), 0, 0)
    mat = bpy.data.materials.get("PV_Label")
    if mat is None:
        mat = bpy.data.materials.new("PV_Label")
        mat.use_nodes = True
        bsdf = mat.node_tree.nodes.get("Principled BSDF")
        if bsdf:
            bsdf.inputs["Base Color"].default_value = (0.86, 0.88, 0.92, 1.0)
            if "Emission Color" in bsdf.inputs:
                bsdf.inputs["Emission Color"].default_value = (0.86, 0.88, 0.92, 1.0)
            if "Emission Strength" in bsdf.inputs:
                bsdf.inputs["Emission Strength"].default_value = 1.4
    obj.data.materials.append(mat)
    return obj


def _dress(prefix, pieces, mannequin, matrix, label=None):
    """One dressed mannequin at a world matrix. Returns every object made, so
    the caller can tear the scene down between renders."""
    made = [_instance(mannequin, matrix)]
    for src in pieces:
        parsed = parse_name(src.name)
        if not parsed:
            continue
        target, role = parsed[2], parsed[3]
        if target not in FIT:
            continue
        placed = matrix @ _pose(target) @ Matrix.Translation(Vector(FIT[target]["center"]))
        made.append(_instance(src, placed, preview_material(prefix, role)))
    if label:
        made.append(_label(label, (matrix.translation.x, 0.0, -0.85)))
    return made


def _stage(resolution, cam_height, ortho, path):
    """Camera, key light, fill, sky - built fresh per render so a stale camera
    cannot silently frame the wrong thing."""
    made = []
    for angle, energy, name in ((52, 2.6, "Key"), (-40, 1.0, "Fill")):
        sun = bpy.data.objects.new(name, bpy.data.lights.new(name, "SUN"))
        sun.data.energy = energy
        sun.rotation_euler = (math.radians(58), 0, math.radians(angle))
        bpy.context.collection.objects.link(sun)
        made.append(sun)
    cam_data = bpy.data.cameras.new("Cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = ortho
    cam = bpy.data.objects.new("Cam", cam_data)
    cam.location = Vector((0.0, -40.0, cam_height))
    cam.rotation_euler = (math.radians(90), 0, 0)
    bpy.context.collection.objects.link(cam)
    made.append(cam)

    scene = bpy.context.scene
    scene.camera = cam
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x, scene.render.resolution_y = resolution
    scene.render.filepath = path
    if scene.world is None:
        scene.world = bpy.data.worlds.new("World")
    scene.world.use_nodes = True
    bg = scene.world.node_tree.nodes.get("Background")
    if bg:
        bg.inputs[0].default_value = (0.11, 0.12, 0.15, 1.0)
        bg.inputs[1].default_value = 1.0
    return made


def _teardown(objects):
    """Every render builds its own scene and removes it again - eleven images
    out of one Blender run, with no chance of a leftover from image 3 turning
    up in image 7."""
    for obj in objects:
        bpy.data.objects.remove(obj, do_unlink=True)


def render_preview(path, objects):
    """Writes assets/armor_preview_<set>.png for all ten sets and replaces
    assets/armor_preview.png with the ten-set line-up."""
    out_dir = os.path.dirname(os.path.abspath(path)) or "."
    base = os.path.basename(path)
    stem = base[: -len(".png")] if base.endswith(".png") else base

    # The pack objects are sources; only their instances are ever rendered.
    for obj in objects:
        obj.hide_render = True
    mannequin = build_mannequin()
    mannequin.hide_render = True

    by_prefix = {}
    for obj in objects:
        parsed = parse_name(obj.name)
        if parsed:
            by_prefix.setdefault(parsed[0], []).append(obj)

    written = []
    # ---- one PNG per set: three-quarter hero, front, back.
    for prefix in SETS:
        pieces = by_prefix.get(prefix, [])
        made = []
        for column, (yaw, view) in enumerate(((-38, "three-quarter"), (0, "front"), (180, "back"))):
            at = Matrix.Translation(Vector(((column - 1) * 4.4, 0, 0))) @ Matrix.Rotation(
                math.radians(yaw), 4, "Z"
            )
            made += _dress(prefix, pieces, mannequin, at, label=view)
        made.append(_label(prefix, (0.0, 0.0, 7.85), size=0.70))
        target = os.path.join(out_dir, "%s_%s.png" % (stem, prefix.lower()))
        made += _stage((1500, 950), 3.70, 15.5, target)
        bpy.ops.render.render(write_still=True)
        written.append(target)
        _teardown(made)

    # ---- the line-up: ten dressed mannequins, three-quarter, one row.
    made = []
    for column, prefix in enumerate(SETS):
        at = Matrix.Translation(
            Vector(((column - (len(SETS) - 1) / 2) * 4.3, 0, 0))
        ) @ Matrix.Rotation(math.radians(-38), 4, "Z")
        made += _dress(prefix, by_prefix.get(prefix, []), mannequin, at, label=prefix)
    made += _stage((2800, 880), 3.40, 45.0, path)
    bpy.ops.render.render(write_still=True)
    written.append(path)
    _teardown(made)

    for target in written:
        print("ARMOR PREVIEW:", target)


def main():
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    if not argv:
        print("usage: blender --background --python armor_gen.py -- <out.glb> [preview [<preview.png>]]")
        return
    out = argv[0]
    clear_scene()
    objects = build_all()
    export(out, objects)
    if "preview" in argv[1:]:
        # The preview base path defaults to the pack's, but can be given
        # explicitly - which is how a run can re-render assets/armor_preview*
        # WITHOUT rewriting assets/armor.glb. A pack rebuild that changes no
        # object is still a new binary in a shared checkout, and a binary diff
        # nobody can read is a bad thing to hand a reviewer.
        rest = argv[argv.index("preview") + 1 :]
        preview = rest[0] if rest else out.replace(".glb", "_preview.png")
        render_preview(preview, objects)


main()
