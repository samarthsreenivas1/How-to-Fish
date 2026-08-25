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
    # Volcano weapons (Weapons.luau "Volcano (lava island mats)").
    "EmberCudgel": {"length": 3.4, "grip": 0.7},
    "Cinderclub": {"length": 3.5, "grip": 0.72},
    "SulfurKnuckles": {"length": 3.1, "grip": 0.6},
    "PumiceFists": {"length": 3.1, "grip": 0.6},
    "Cinderlash": {"length": 3.3, "grip": 0.62},
    "ObsidianPiercer": {"length": 3.5, "grip": 0.64},
    "RidgebackPike": {"length": 3.8, "grip": 0.76},
    "SlagfistGauntlet": {"length": 3.6, "grip": 0.78},
    "CinderSpear": {"length": 3.7, "grip": 0.74},
    "LodestoneMaul": {"length": 3.9, "grip": 0.8},
    "MagmaGauntlets": {"length": 3.2, "grip": 0.62},
    "Riftcleaver": {"length": 3.6, "grip": 0.68},
    "SootveilBlade": {"length": 3.4, "grip": 0.66},
    "SlagheartWarhammer": {"length": 3.9, "grip": 0.8},
    # Ranged (revamp S2): swamp tier-1 fantasy pieces + volcano gunpowder-tech.
    # Same frame rule as everything above - butt at z = 0, muzzle / upper limb
    # tip at z = LENGTH, _Grip centred on the hand point. The Weapons.luau
    # ranged rows must copy these numbers (source of truth until they land).
    "BogwoodBow": {"length": 3.4, "grip": 1.7},
    "GatorjawCrossbow": {"length": 3.0, "grip": 0.8},
    "MireFlintlock": {"length": 2.3, "grip": 0.5},
    "CinderlockCarbine": {"length": 3.2, "grip": 0.9},
    "BasaltScattergun": {"length": 3.0, "grip": 0.85},
    "VulkanRepeater": {"length": 3.6, "grip": 0.95},
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
    # Volcano weapons (Weapons.luau "Volcano (lava island mats)"). Colours
    # mirror the game rows' color/accent/wrap/glow.
    "EmberCudgel_Haft": (0.59, 0.44, 0.28),  # driftwood
    "EmberCudgel_Grip": (0.27, 0.23, 0.19),  # charred binding
    "EmberCudgel_Head": (0.94, 0.52, 0.20),  # ember-scorched head
    "EmberCudgel_Spike": (0.94, 0.52, 0.20),
    "Cinderclub_Haft": (0.51, 0.38, 0.25),  # ash-darkened driftwood
    "Cinderclub_Grip": (0.24, 0.20, 0.17),  # charred binding
    "Cinderclub_Head": (0.78, 0.43, 0.25),  # cinder-crusted head
    "Cinderclub_Spike": (0.78, 0.43, 0.25),
    "SulfurKnuckles_Haft": (0.55, 0.42, 0.27),  # driftwood
    "SulfurKnuckles_Grip": (0.34, 0.55, 0.33),  # kelp binding
    "SulfurKnuckles_Guard": (0.55, 0.42, 0.27),
    "SulfurKnuckles_Edge": (0.89, 0.81, 0.35),  # sulfur crust
    "SulfurKnuckles_Spike": (0.89, 0.81, 0.35),
    "PumiceFists_Haft": (0.67, 0.64, 0.59),  # pale pumice
    "PumiceFists_Grip": (0.34, 0.55, 0.33),  # kelp binding
    "PumiceFists_Guard": (0.67, 0.64, 0.59),
    "PumiceFists_Edge": (0.89, 0.81, 0.35),  # sulfur-dusted knuckles
    "PumiceFists_Spike": (0.89, 0.81, 0.35),
    "Cinderlash_Haft": (0.59, 0.44, 0.28),  # driftwood
    "Cinderlash_Grip": (0.34, 0.55, 0.33),  # kelp binding
    "Cinderlash_Guard": (0.59, 0.44, 0.28),
    "Cinderlash_Edge": (0.94, 0.52, 0.20),  # the ember cord
    "Cinderlash_Spike": (0.94, 0.52, 0.20),
    "ObsidianPiercer_Haft": (0.55, 0.42, 0.27),  # driftwood
    "ObsidianPiercer_Grip": (0.24, 0.20, 0.18),  # dark binding
    "ObsidianPiercer_Guard": (0.55, 0.42, 0.27),
    "ObsidianPiercer_Edge": (0.19, 0.17, 0.24),  # glass-black obsidian
    "ObsidianPiercer_Spike": (0.19, 0.17, 0.24),
    "ObsidianPiercer_Glow": (0.94, 0.52, 0.20),  # the hairline crack of heat
    "RidgebackPike_Haft": (0.59, 0.46, 0.30),  # driftwood
    "RidgebackPike_Grip": (0.59, 0.73, 0.82),  # fish-scale binding
    "RidgebackPike_Guard": (0.59, 0.46, 0.30),
    "RidgebackPike_Head": (0.19, 0.17, 0.24),  # obsidian hook base
    "RidgebackPike_Spike": (0.19, 0.17, 0.24),
    "RidgebackPike_Glow": (0.94, 0.52, 0.20),  # ember veins in the hook
    "SlagfistGauntlet_Haft": (0.19, 0.17, 0.24),  # obsidian
    "SlagfistGauntlet_Grip": (0.27, 0.26, 0.31),  # dark binding
    "SlagfistGauntlet_Guard": (0.19, 0.17, 0.24),
    "SlagfistGauntlet_Head": (0.89, 0.81, 0.35),  # sulfur-crusted knob
    "SlagfistGauntlet_Spike": (0.89, 0.81, 0.35),
    "SlagfistGauntlet_Glow": (0.96, 0.38, 0.16),  # molten cracks
    "CinderSpear_Haft": (0.59, 0.44, 0.28),  # driftwood shaft
    "CinderSpear_Grip": (0.78, 0.43, 0.24),  # ember cord
    "CinderSpear_Guard": (0.59, 0.44, 0.28),
    "CinderSpear_Head": (0.89, 0.81, 0.35),  # sulfur-crusted head
    "CinderSpear_Spike": (0.89, 0.81, 0.35),
    "CinderSpear_Glow": (0.94, 0.52, 0.20),  # the cord's smoulder
    "LodestoneMaul_Haft": (0.55, 0.42, 0.27),  # driftwood
    "LodestoneMaul_Grip": (0.24, 0.22, 0.27),  # obsidian-dark binding
    "LodestoneMaul_Guard": (0.55, 0.42, 0.27),
    "LodestoneMaul_Head": (0.38, 0.42, 0.52),  # lodestone
    "LodestoneMaul_Spike": (0.19, 0.17, 0.24),  # obsidian braces
    "LodestoneMaul_Glow": (0.59, 0.67, 0.82),  # the pull, arcing off the head
    "MagmaGauntlets_Haft": (0.27, 0.23, 0.22),  # dark vent-metal
    "MagmaGauntlets_Grip": (0.59, 0.73, 0.82),  # fish-scale binding
    "MagmaGauntlets_Guard": (0.27, 0.23, 0.22),
    "MagmaGauntlets_Edge": (0.89, 0.81, 0.35),  # sulfur-cured claws
    "MagmaGauntlets_Spike": (0.89, 0.81, 0.35),
    "MagmaGauntlets_Glow": (0.96, 0.38, 0.16),  # the magma vein
    "Riftcleaver_Haft": (0.38, 0.42, 0.52),  # lodestone
    "Riftcleaver_Grip": (0.22, 0.23, 0.26),  # dark binding
    "Riftcleaver_Guard": (0.38, 0.42, 0.52),
    "Riftcleaver_Edge": (0.31, 0.35, 0.43),  # grey-blue cleaver blade
    "Riftcleaver_Spike": (0.31, 0.35, 0.43),
    "Riftcleaver_Glow": (0.96, 0.38, 0.16),  # the rift of magma down its centre
    "SootveilBlade_Haft": (0.19, 0.17, 0.24),  # obsidian-dark
    "SootveilBlade_Grip": (0.59, 0.73, 0.82),  # fish-scale binding
    "SootveilBlade_Guard": (0.19, 0.17, 0.24),
    "SootveilBlade_Edge": (0.16, 0.15, 0.17),  # soot-blackened blade
    "SootveilBlade_Spike": (0.16, 0.15, 0.17),
    "SootveilBlade_Glow": (0.59, 0.16, 0.16),  # the drain, dim and red
    "SlagheartWarhammer_Haft": (0.38, 0.42, 0.52),  # lodestone-braced haft
    "SlagheartWarhammer_Grip": (0.24, 0.22, 0.27),  # dark binding
    "SlagheartWarhammer_Guard": (0.38, 0.42, 0.52),
    "SlagheartWarhammer_Head": (0.19, 0.17, 0.24),  # obsidian head
    "SlagheartWarhammer_Spike": (0.19, 0.17, 0.24),
    "SlagheartWarhammer_Glow": (0.96, 0.38, 0.16),  # the molten core
    # Ranged - swamp (bogwood / bog iron / gator scute fantasy tier).
    "BogwoodBow_Haft": (0.4, 0.31, 0.2),  # dark bogwood stave + arrow shaft
    "BogwoodBow_Grip": (0.3, 0.36, 0.28),  # gator-hide binding
    "BogwoodBow_Edge": (0.8, 0.76, 0.6),  # sinew string
    "BogwoodBow_Spike": (0.72, 0.68, 0.55),  # bone tips, arrowhead, fletching
    "GatorjawCrossbow_Haft": (0.42, 0.32, 0.21),  # bogwood stock
    "GatorjawCrossbow_Grip": (0.27, 0.31, 0.26),  # dark hide binding
    "GatorjawCrossbow_Pommel": (0.42, 0.32, 0.21),
    "GatorjawCrossbow_Guard": (0.35, 0.33, 0.29),  # bog-iron trigger work
    "GatorjawCrossbow_Head": (0.35, 0.33, 0.29),  # bog-iron lock
    "GatorjawCrossbow_Edge": (0.44, 0.51, 0.36),  # gator-scute prod + string
    "GatorjawCrossbow_Spike": (0.85, 0.82, 0.69),  # gator teeth + the bolt
    "GatorjawCrossbow_Glow": (0.55, 0.85, 0.73),  # wisp-light sight
    "MireFlintlock_Haft": (0.36, 0.26, 0.18),  # swamp-walnut stock
    "MireFlintlock_Grip": (0.27, 0.2, 0.15),  # oiled leather wrap
    "MireFlintlock_Pommel": (0.7, 0.56, 0.29),  # brass butt cap
    "MireFlintlock_Guard": (0.7, 0.56, 0.29),  # brass trigger guard
    "MireFlintlock_Head": (0.7, 0.56, 0.29),  # brass lock plate + hammer
    "MireFlintlock_Edge": (0.44, 0.45, 0.47),  # iron barrel
    "MireFlintlock_Spike": (0.36, 0.26, 0.18),  # wooden ramrod
    "MireFlintlock_Glow": (0.62, 0.88, 0.34),  # fen-venom etching
    # Ranged - volcano (obsidian / brass gunpowder-tech tier).
    "CinderlockCarbine_Haft": (0.45, 0.35, 0.24),  # ash-scorched stock
    "CinderlockCarbine_Grip": (0.24, 0.2, 0.17),  # charred binding
    "CinderlockCarbine_Pommel": (0.7, 0.55, 0.28),  # brass butt plate
    "CinderlockCarbine_Guard": (0.7, 0.55, 0.28),  # brass guard + magazine
    "CinderlockCarbine_Head": (0.19, 0.17, 0.24),  # obsidian receiver
    "CinderlockCarbine_Edge": (0.35, 0.34, 0.38),  # gunmetal barrel
    "CinderlockCarbine_Spike": (0.35, 0.34, 0.38),  # sights + muzzle ring
    "BasaltScattergun_Haft": (0.4, 0.3, 0.22),  # dark wood stock + forend
    "BasaltScattergun_Grip": (0.59, 0.73, 0.82),  # fish-scale binding
    "BasaltScattergun_Pommel": (0.7, 0.55, 0.28),  # brass butt plate
    "BasaltScattergun_Guard": (0.7, 0.55, 0.28),  # brass trigger guard
    "BasaltScattergun_Head": (0.19, 0.17, 0.24),  # obsidian breech + lever
    "BasaltScattergun_Edge": (0.25, 0.24, 0.27),  # basalt twin barrels
    "BasaltScattergun_Spike": (0.25, 0.24, 0.27),  # muzzle rims + barrel band
    "BasaltScattergun_Glow": (0.94, 0.52, 0.2),  # ember vents
    "VulkanRepeater_Haft": (0.27, 0.23, 0.22),  # dark vent-metal frame
    "VulkanRepeater_Grip": (0.24, 0.2, 0.18),  # dark binding
    "VulkanRepeater_Pommel": (0.19, 0.17, 0.24),  # obsidian butt pad
    "VulkanRepeater_Guard": (0.19, 0.17, 0.24),  # obsidian guard + foregrip
    "VulkanRepeater_Head": (0.19, 0.17, 0.24),  # obsidian drum magazine
    "VulkanRepeater_Edge": (0.33, 0.32, 0.36),  # gunmetal shroud + barrel
    "VulkanRepeater_Spike": (0.33, 0.32, 0.36),  # muzzle brake + vents
    "VulkanRepeater_Glow": (0.96, 0.38, 0.16),  # incendiary core + veins
}

GLOW_PARTS = {  # emissive in the preview only
    "Drowncleaver_Glow",
    "TidebombMaul_Glow",
    "Voltfang_Glow",
    "Heartrender_Glow",
    "ObsidianPiercer_Glow",
    "RidgebackPike_Glow",
    "SlagfistGauntlet_Glow",
    "CinderSpear_Glow",
    "LodestoneMaul_Glow",
    "MagmaGauntlets_Glow",
    "Riftcleaver_Glow",
    "SootveilBlade_Glow",
    "SlagheartWarhammer_Glow",
    "GatorjawCrossbow_Glow",
    "MireFlintlock_Glow",
    "BasaltScattergun_Glow",
    "VulkanRepeater_Glow",
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


# ---------------------------------------------------------------- Ember Cudgel / Cinderclub (volcano starters)
# Plain scorched driftwood clubs, same silhouette family as the Driftwood
# Club - a tapered haft, a knotted head, knots poking out. No glow: these are
# Common tier, same rule as the starter club/blade.


def build_embercudgel():
    f = FRAME["EmberCudgel"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    head = bmesh.new()
    spike = bmesh.new()

    limb(haft, (0, 0, 0.0), (-0.03, 0, length - 1.1), 0.16, 0.12, 6)
    limb(grip_bm, (0, 0, grip - 0.55), (0, 0, grip + 0.55), 0.22, 0.2, 7)
    ellipsoid(head, (-0.02, 0, length - 0.48), (0.4, 0.4, 0.6), subdiv=1)
    box(head, (0, 0, length - 0.9), (0.5, 0.5, 0.45))
    for cx, cy, cz, r in ((0.36, 0.12, length - 0.5, 0.16), (-0.3, -0.1, length - 0.3, 0.14), (0.05, -0.32, length - 0.7, 0.15)):
        ellipsoid(spike, (cx, cy, cz), (r, r, r), subdiv=0)

    return [
        finish("EmberCudgel_Haft", haft),
        finish("EmberCudgel_Grip", grip_bm),
        finish("EmberCudgel_Head", head),
        finish("EmberCudgel_Spike", spike),
    ]


def build_cinderclub():
    f = FRAME["Cinderclub"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    head = bmesh.new()
    spike = bmesh.new()

    limb(haft, (0, 0, 0.0), (0.02, 0, length - 1.0), 0.14, 0.1, 6)
    limb(grip_bm, (0, 0, grip - 0.5), (0, 0, grip + 0.5), 0.19, 0.17, 7)
    box(head, (0, 0, length - 0.55), (0.42, 0.4, 0.5))
    box(head, (0.05, 0.05, length - 0.2), (0.28, 0.26, 0.22), Matrix.Rotation(math.radians(18), 4, "Z"))
    for cx, cy, cz, r in ((0.3, 0.16, length - 0.7, 0.11), (-0.26, -0.14, length - 0.45, 0.1), (0.1, -0.28, length - 0.85, 0.09)):
        ellipsoid(spike, (cx, cy, cz), (r, r, r), subdiv=0)

    return [
        finish("Cinderclub_Haft", haft),
        finish("Cinderclub_Grip", grip_bm),
        finish("Cinderclub_Head", head),
        finish("Cinderclub_Spike", spike),
    ]


# ---------------------------------------------------------------- Sulfur Knuckles / Pumice Fists (volcano uncommons)
# Short knuckle-duster blades - a compact crossguard, a stubby blade, and
# crusted knobs standing in for scale plates. Uncommon tier: no glow yet.


def build_sulfurknuckles():
    f = FRAME["SulfurKnuckles"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    guard = bmesh.new()
    edge = bmesh.new()
    spike = bmesh.new()

    limb(haft, (0, 0, 0.05), (0, 0, 1.1), 0.09, 0.12, 6)
    limb(grip_bm, (0, 0, grip - 0.35), (0, 0, grip + 0.35), 0.14, 0.15, 7)
    box(guard, (0, 0, 1.16), (0.62, 0.18, 0.13))
    for sign in (-1, 1):
        box(guard, (sign * 0.36, 0, 1.2), (0.22, 0.16, 0.11), Matrix.Rotation(math.radians(-sign * 16), 4, "Y"))

    profile = [(-0.11, 1.22), (0.11, 1.22), (0.16, 1.7), (0.0, length), (-0.16, 1.7)]
    slab(edge, profile, 0.045)

    for cx, cy, cz, r in ((0.34, 0.1, 1.24, 0.08), (-0.3, -0.08, 1.24, 0.07), (0.1, 0.14, 1.5, 0.06), (-0.14, -0.12, 1.55, 0.06)):
        ellipsoid(spike, (cx, cy, cz), (r, r, r), subdiv=0)

    return [
        finish("SulfurKnuckles_Haft", haft),
        finish("SulfurKnuckles_Grip", grip_bm),
        finish("SulfurKnuckles_Guard", guard),
        finish("SulfurKnuckles_Edge", edge),
        finish("SulfurKnuckles_Spike", spike),
    ]


def build_pumicefists():
    f = FRAME["PumiceFists"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    guard = bmesh.new()
    edge = bmesh.new()
    spike = bmesh.new()

    limb(haft, (0, 0, 0.05), (0, 0, 1.0), 0.08, 0.1, 6)
    limb(grip_bm, (0, 0, grip - 0.32), (0, 0, grip + 0.32), 0.13, 0.14, 7)
    box(guard, (0, 0, 1.05), (0.5, 0.16, 0.11))

    for x in (-0.3, -0.1, 0.1, 0.3):
        ellipsoid(spike, (x, 0.05, 1.16), (0.13, 0.11, 0.13), subdiv=0)

    profile = [(-0.14, 1.24), (0.14, 1.24), (0.1, 1.5), (0.0, length), (-0.1, 1.5)]
    slab(edge, profile, 0.04)

    return [
        finish("PumiceFists_Haft", haft),
        finish("PumiceFists_Grip", grip_bm),
        finish("PumiceFists_Guard", guard),
        finish("PumiceFists_Edge", edge),
        finish("PumiceFists_Spike", spike),
    ]


# ---------------------------------------------------------------- Cinderlash (volcano uncommon)
# A whip-like blade: a chain of tapering limb segments curving as it climbs,
# ending in a smouldering knot. Uncommon tier: no glow yet.


def build_cinderlash():
    f = FRAME["Cinderlash"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    guard = bmesh.new()
    edge = bmesh.new()
    spike = bmesh.new()

    limb(haft, (0, 0, 0.0), (0, 0, 1.1), 0.1, 0.13, 6)
    limb(grip_bm, (0, 0, grip - 0.38), (0, 0, grip + 0.38), 0.15, 0.16, 7)
    box(guard, (0, 0, 1.16), (0.3, 0.24, 0.12))

    segs = 7
    prev = Vector((0, 0, 1.2))
    for i in range(1, segs + 1):
        t = i / segs
        z = 1.2 + t * (length - 1.2)
        x = math.sin(t * 2.2) * 0.5
        y = math.cos(t * 1.3) * 0.12
        cur = Vector((x, y, z))
        r0 = max(0.09 * (1 - t) + 0.02, 0.02)
        r1 = max(0.09 * (1 - t * 1.05) + 0.015, 0.015)
        limb(edge, prev, cur, r0, r1, sides=5)
        prev = cur

    ellipsoid(spike, prev, (0.09, 0.09, 0.09), subdiv=0)

    return [
        finish("Cinderlash_Haft", haft),
        finish("Cinderlash_Grip", grip_bm),
        finish("Cinderlash_Guard", guard),
        finish("Cinderlash_Edge", edge),
        finish("Cinderlash_Spike", spike),
    ]


# ---------------------------------------------------------------- Obsidian Piercer (volcano rare)
# A thin tapering rapier of glass-black obsidian with a hairline crack of
# heat running its length. Rare tier: glow.


def build_obsidianpiercer():
    f = FRAME["ObsidianPiercer"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    guard = bmesh.new()
    edge = bmesh.new()
    spike = bmesh.new()
    glow = bmesh.new()

    limb(haft, (0, 0, 0.08), (0, 0, 1.3), 0.1, 0.12, 6)
    limb(grip_bm, (0, 0, grip - 0.4), (0, 0, grip + 0.4), 0.15, 0.14, 7)
    box(guard, (0, 0, 1.36), (0.5, 0.16, 0.12))

    profile = [(-0.1, 1.42), (0.1, 1.42), (0.16, 1.9), (0.06, 2.9), (0.0, length - 0.2), (-0.06, 2.9), (-0.16, 1.9)]
    slab(edge, profile, 0.035)
    cone(spike, (0, 0, length - 0.2), (0, 0, length), 0.05, sides=4)

    box(glow, (0, 0, (1.5 + length - 0.2) / 2), (0.02, 0.045, (length - 0.2 - 1.5) / 2))

    return [
        finish("ObsidianPiercer_Haft", haft),
        finish("ObsidianPiercer_Grip", grip_bm),
        finish("ObsidianPiercer_Guard", guard),
        finish("ObsidianPiercer_Edge", edge),
        finish("ObsidianPiercer_Spike", spike),
        finish("ObsidianPiercer_Glow", glow),
    ]


# ---------------------------------------------------------------- Ridgeback Pike (volcano rare)
# A long haft crowned with a hooked obsidian ridgeback barb, ember veins
# glowing along it. Rare tier: glow.


def build_ridgebackpike():
    f = FRAME["RidgebackPike"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    guard = bmesh.new()
    head = bmesh.new()
    spike = bmesh.new()
    glow = bmesh.new()

    limb(haft, (0, 0, 0.0), (0, 0, 2.6), 0.13, 0.09, 6)
    limb(grip_bm, (0, 0, grip - 0.6), (0, 0, grip + 0.6), 0.2, 0.18, 8)
    guard_bm_ring(guard, 2.65)

    ellipsoid(head, (0, 0, 2.85), (0.24, 0.22, 0.3), subdiv=1)
    limb(head, (0, 0.05, 2.95), (0.06, 0.4, length - 0.1), 0.13, 0.04, 5)
    cone(spike, (0.06, 0.4, length - 0.1), (0.1, 0.55, length), 0.05, sides=4)
    for cz, dy, dz in ((3.05, 0.24, 0.06), (3.3, -0.2, 0.18)):
        base = Vector((0, 0.08, cz))
        tip = base + Vector((0, dy, dz))
        cone(spike, base, tip, 0.06, sides=4)

    box(glow, (0.03, 0.22, 3.25), (0.02, 0.03, 0.5))

    return [
        finish("RidgebackPike_Haft", haft),
        finish("RidgebackPike_Grip", grip_bm),
        finish("RidgebackPike_Guard", guard),
        finish("RidgebackPike_Head", head),
        finish("RidgebackPike_Spike", spike),
        finish("RidgebackPike_Glow", glow),
    ]


# ---------------------------------------------------------------- Slagfist Gauntlet (volcano rare)
# A heavy faceted knob of obsidian and sulfur with knuckle ridges and molten
# cracks running across it. Rare tier: glow.


def build_slagfistgauntlet():
    f = FRAME["SlagfistGauntlet"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    guard = bmesh.new()
    head = bmesh.new()
    spike = bmesh.new()
    glow = bmesh.new()

    limb(haft, (0, 0, 0.0), (0, 0, 2.3), 0.16, 0.12, 6)
    limb(grip_bm, (0, 0, grip - 0.6), (0, 0, grip + 0.6), 0.25, 0.23, 8)
    guard_bm_ring(guard, 2.35)

    ellipsoid(head, (0, 0, 2.75), (0.55, 0.5, 0.55), subdiv=1)
    box(head, (0, 0, 2.55), (0.62, 0.58, 0.4))

    for x in (-0.3, -0.1, 0.1, 0.3):
        box(spike, (x, 0.42, 2.9), (0.08, 0.08, 0.18))

    for cx, cz, ln, ang in ((0.0, 2.9, 0.5, 25), (-0.18, 2.62, 0.35, -35), (0.2, 2.68, 0.32, 50)):
        box(glow, (cx, 0.3, cz), (ln, 0.035, 0.05), Matrix.Rotation(math.radians(ang), 4, "Y"))

    return [
        finish("SlagfistGauntlet_Haft", haft),
        finish("SlagfistGauntlet_Grip", grip_bm),
        finish("SlagfistGauntlet_Guard", guard),
        finish("SlagfistGauntlet_Head", head),
        finish("SlagfistGauntlet_Spike", spike),
        finish("SlagfistGauntlet_Glow", glow),
    ]


# ---------------------------------------------------------------- Cinder Spear (volcano rare)
# A leaf-shaped sulfur-crusted spearhead on a driftwood shaft, glowing ember
# cord wrapped just below it. Rare tier: glow.


def build_cinderspear():
    f = FRAME["CinderSpear"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    guard = bmesh.new()
    head = bmesh.new()
    spike = bmesh.new()
    glow = bmesh.new()

    limb(haft, (0, 0, 0.0), (0, 0, 2.5), 0.12, 0.09, 6)
    limb(grip_bm, (0, 0, grip - 0.55), (0, 0, grip + 0.55), 0.18, 0.16, 7)
    guard_bm_ring(guard, 2.55)

    profile = [(-0.16, 2.6), (0.16, 2.6), (0.24, 3.0), (0.0, length), (-0.24, 3.0)]
    slab(head, profile, 0.05)
    for side in (-1, 1):
        cone(spike, (side * 0.14, 0, 2.62), (side * 0.34, 0, 2.85), 0.06, sides=4)

    for cz in (2.1, 2.3, 2.5):
        limb(glow, (0, 0, cz - 0.03), (0, 0, cz + 0.03), 0.14, 0.14, 8)

    return [
        finish("CinderSpear_Haft", haft),
        finish("CinderSpear_Grip", grip_bm),
        finish("CinderSpear_Guard", guard),
        finish("CinderSpear_Head", head),
        finish("CinderSpear_Spike", spike),
        finish("CinderSpear_Glow", glow),
    ]


# ---------------------------------------------------------------- Lodestone Maul (volcano epic)
# A large faceted lodestone head braced in obsidian, magnetic pull-lines
# radiating off it. Epic tier: glow.


def build_lodestonemaul():
    f = FRAME["LodestoneMaul"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    guard = bmesh.new()
    head = bmesh.new()
    spike = bmesh.new()
    glow = bmesh.new()

    limb(haft, (0, 0, 0.0), (0, 0, 2.5), 0.18, 0.13, 6)
    limb(grip_bm, (0, 0, grip - 0.65), (0, 0, grip + 0.65), 0.28, 0.26, 8)
    guard_bm_ring(guard, 2.55)

    ellipsoid(head, (0, 0, 3.15), (0.62, 0.6, 0.62), subdiv=1)
    box(head, (0, 0, 2.85), (0.7, 0.68, 0.42))

    for side in (-1, 1):
        box(spike, (side * 0.5, 0, 3.1), (0.14, 0.5, 0.16))
    box(spike, (0, 0, 3.7), (0.3, 0.3, 0.12))

    for i in range(5):
        a = (i / 5) * TAU
        d = Vector((math.cos(a), math.sin(a) * 0.8, 0.0))
        base = Vector((0, 0, 3.15)) + d * 0.66
        tip = base + d * 0.3
        limb(glow, base, tip, 0.035, 0.01, 4)

    return [
        finish("LodestoneMaul_Haft", haft),
        finish("LodestoneMaul_Grip", grip_bm),
        finish("LodestoneMaul_Guard", guard),
        finish("LodestoneMaul_Head", head),
        finish("LodestoneMaul_Spike", spike),
        finish("LodestoneMaul_Glow", glow),
    ]


# ---------------------------------------------------------------- Magma Gauntlets (volcano epic)
# Three sulfur-crusted claw blades fanning off a short guard, a magma vein
# glowing up the centre claw. Epic tier: glow.


def build_magmagauntlets():
    f = FRAME["MagmaGauntlets"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    guard = bmesh.new()
    edge = bmesh.new()
    spike = bmesh.new()
    glow = bmesh.new()

    limb(haft, (0, 0, 0.0), (0, 0, 1.4), 0.11, 0.09, 6)
    limb(grip_bm, (0, 0, grip - 0.45), (0, 0, grip + 0.45), 0.19, 0.18, 8)
    box(guard, (0, 0, 1.46), (0.62, 0.18, 0.14))

    for x in (-0.24, 0.0, 0.24):
        box(edge, (x, 0, (1.52 + length) / 2), (0.09, 0.08, (length - 1.52) / 2))
        cone(spike, (x, 0, length), (x * 1.3, 0, length + 0.22), 0.05, sides=4)

    box(glow, (0, 0, (1.6 + length) / 2), (0.03, 0.05, (length - 1.6) / 2))

    return [
        finish("MagmaGauntlets_Haft", haft),
        finish("MagmaGauntlets_Grip", grip_bm),
        finish("MagmaGauntlets_Guard", guard),
        finish("MagmaGauntlets_Edge", edge),
        finish("MagmaGauntlets_Spike", spike),
        finish("MagmaGauntlets_Glow", glow),
    ]


# ---------------------------------------------------------------- Riftcleaver (volcano epic)
# A broad lodestone-grey cleaver slab split by a glowing rift of magma down
# its centre. Epic tier: glow.


def build_riftcleaver():
    f = FRAME["Riftcleaver"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    guard = bmesh.new()
    edge = bmesh.new()
    spike = bmesh.new()
    glow = bmesh.new()

    limb(haft, (0, 0, 0.0), (0, 0, 1.3), 0.13, 0.1, 6)
    limb(grip_bm, (0, 0, grip - 0.42), (0, 0, grip + 0.42), 0.2, 0.19, 8)
    box(guard, (0.1, 0, 1.38), (0.9, 0.22, 0.16))

    profile = [
        (-0.3, 1.44),
        (0.62, 1.44),
        (0.74, 2.1),
        (0.7, 2.9),
        (0.5, length),
        (-0.34, length - 0.2),
        (-0.32, 2.2),
    ]
    slab(edge, profile, 0.06)

    cone(spike, (0.6, 0, 1.5), (0.86, 0, 1.66), 0.06, sides=4)

    box(glow, (0.15, 0, (1.7 + length - 0.3) / 2), (0.035, 0.075, (length - 0.3 - 1.7) / 2))
    for cz, ang in ((2.3, 35), (2.9, -30)):
        box(glow, (0.15, 0, cz), (0.28, 0.07, 0.03), Matrix.Rotation(math.radians(ang), 4, "Y"))

    return [
        finish("Riftcleaver_Haft", haft),
        finish("Riftcleaver_Grip", grip_bm),
        finish("Riftcleaver_Guard", guard),
        finish("Riftcleaver_Edge", edge),
        finish("Riftcleaver_Spike", spike),
        finish("Riftcleaver_Glow", glow),
    ]


# ---------------------------------------------------------------- Sootveil Blade (volcano epic)
# A slim soot-blackened blade with a small hooked guard tip, a dim red
# draining glow running up the edge. Epic tier: glow.


def build_sootveilblade():
    f = FRAME["SootveilBlade"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    guard = bmesh.new()
    edge = bmesh.new()
    spike = bmesh.new()
    glow = bmesh.new()

    limb(haft, (0, 0, 0.05), (0, 0, 1.25), 0.1, 0.12, 6)
    limb(grip_bm, (0, 0, grip - 0.4), (0, 0, grip + 0.4), 0.15, 0.16, 7)
    box(guard, (0, 0, 1.3), (0.56, 0.16, 0.13))
    cone(spike, (0.3, 0, 1.32), (0.46, 0, 1.5), 0.06, sides=4)

    profile = [(-0.12, 1.36), (0.12, 1.36), (0.15, 2.1), (0.0, length), (-0.15, 2.1)]
    slab(edge, profile, 0.045)

    box(glow, (0.1, 0, (1.5 + length) / 2), (0.02, 0.05, (length - 1.5) / 2))

    return [
        finish("SootveilBlade_Haft", haft),
        finish("SootveilBlade_Grip", grip_bm),
        finish("SootveilBlade_Guard", guard),
        finish("SootveilBlade_Edge", edge),
        finish("SootveilBlade_Spike", spike),
        finish("SootveilBlade_Glow", glow),
    ]


# ---------------------------------------------------------------- Slagheart Warhammer (volcano legendary)
# The capstone: a broad faceted warhammer head with two striking faces, a
# molten magma core set in its centre with veins running to both faces and
# down toward the haft, obsidian braces down each side and a back horn
# spike. The richest build in the pack, matching Heartrender's role as the
# other capstone.


def build_slagheartwarhammer():
    f = FRAME["SlagheartWarhammer"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    guard = bmesh.new()
    head = bmesh.new()
    spike = bmesh.new()
    glow = bmesh.new()

    limb(haft, (0, 0, 0.0), (0, 0, 2.6), 0.19, 0.14, 6)
    limb(grip_bm, (0, 0, grip - 0.68), (0, 0, grip + 0.68), 0.3, 0.28, 8)
    guard_bm_ring(guard, 2.65)

    box(head, (0, 0, 3.15), (0.5, 0.78, 0.62))
    ellipsoid(head, (0, 0.42, 3.15), (0.32, 0.22, 0.34), subdiv=1)
    ellipsoid(head, (0, -0.42, 3.15), (0.32, 0.22, 0.34), subdiv=1)

    for side in (-1, 1):
        box(spike, (side * 0.28, 0, 2.85), (0.1, 0.7, 0.14))
    cone(spike, (0, 0, 3.5), (0, 0, 3.85), 0.16, sides=5)

    ellipsoid(glow, (0, 0, 3.15), (0.15, 0.22, 0.16), subdiv=1)
    box(glow, (0, 0.2, 3.15), (0.06, 0.24, 0.06))
    box(glow, (0, -0.2, 3.15), (0.06, 0.24, 0.06))
    box(glow, (0, 0, 2.9), (0.05, 0.05, 0.3))

    return [
        finish("SlagheartWarhammer_Haft", haft),
        finish("SlagheartWarhammer_Grip", grip_bm),
        finish("SlagheartWarhammer_Guard", guard),
        finish("SlagheartWarhammer_Head", head),
        finish("SlagheartWarhammer_Spike", spike),
        finish("SlagheartWarhammer_Glow", glow),
    ]


# ---------------------------------------------------------------- Bogwood Bow (swamp ranged, uncommon)
# Tier-1 ranged: a braced bogwood recurve. The stave is a parabola with the
# grip at its centre and both tips swept forward (+x); the sinew string runs
# tip to tip, and a nocked bone-headed arrow lies across the grip so the
# silhouette reads "bow" from any angle. Uncommon tier: no glow.


def build_bogwoodbow():
    f = FRAME["BogwoodBow"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    edge = bmesh.new()
    spike = bmesh.new()

    # The stave: tips forward at x ~0.62, flat at the grip, fattest mid-limb.
    segs = 10
    pts = []
    for i in range(segs + 1):
        t = i / segs
        x = 0.62 * (2 * t - 1) ** 2
        r = 0.055 + 0.075 * (1 - abs(2 * t - 1))
        pts.append((Vector((x, 0, t * length)), r))
    for (p0, r0), (p1, r1) in zip(pts, pts[1:]):
        limb(haft, p0, p1, r0, r1, 5)

    # Recurve flicks capping both tips.
    cone(spike, pts[-1][0], pts[-1][0] + Vector((0.2, 0, 0.14)), 0.055, sides=4)
    cone(spike, pts[0][0], pts[0][0] + Vector((0.2, 0, -0.14)), 0.055, sides=4)

    # The string, tip to tip.
    limb(edge, (0.62, 0, 0.03), (0.62, 0, length - 0.03), 0.022, 0.022, 4)

    # A nocked arrow across the grip: shaft to just past the stave, bone head,
    # two fletching vanes back at the string.
    arrow_z = grip + 0.25
    limb(haft, (0.62, 0, arrow_z), (-0.5, 0, arrow_z), 0.032, 0.032, 4)
    cone(spike, (-0.5, 0, arrow_z), (-0.8, 0, arrow_z), 0.065, sides=4)
    box(spike, (0.44, 0, arrow_z + 0.06), (0.2, 0.02, 0.1), Matrix.Rotation(math.radians(-18), 4, "Y"))
    box(spike, (0.44, 0, arrow_z - 0.06), (0.2, 0.02, 0.1), Matrix.Rotation(math.radians(18), 4, "Y"))

    # Gator-hide grip riser at the stave's centre, own object on the hand point.
    limb(grip_bm, (0, 0, grip - 0.45), (0, 0, grip + 0.45), 0.15, 0.14, 7)

    return [
        finish("BogwoodBow_Haft", haft),
        finish("BogwoodBow_Grip", grip_bm),
        finish("BogwoodBow_Edge", edge),
        finish("BogwoodBow_Spike", spike),
    ]


# ---------------------------------------------------------------- Gatorjaw Crossbow (swamp ranged, rare)
# A bogwood stock with a gator-scute prod across the top, drawn string, a
# loaded bolt, and gator teeth studding the fore-stock. Rare tier: a wisp
# glow for a sight.


def build_gatorjawcrossbow():
    f = FRAME["GatorjawCrossbow"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    pommel = bmesh.new()
    guard = bmesh.new()
    head = bmesh.new()
    edge = bmesh.new()
    spike = bmesh.new()
    glow = bmesh.new()

    # Stock: butt at z=0 up to just under the prod.
    box(haft, (0, 0, 1.2), (0.24, 0.2, 2.4))
    box(pommel, (0.06, 0, 0.16), (0.34, 0.24, 0.32))
    limb(grip_bm, (0, 0, grip - 0.4), (0, 0, grip + 0.4), 0.16, 0.15, 7)

    # The prod: two swept gator-scute arms, and the string drawn to the nut.
    for side in (-1, 1):
        limb(edge, (0, 0, 2.45), (side * 0.5, 0, 2.42), 0.07, 0.055, 5)
        limb(edge, (side * 0.5, 0, 2.42), (side * 0.88, 0, 2.28), 0.055, 0.035, 5)
        limb(edge, (side * 0.88, 0, 2.28), (0, 0, 1.95), 0.02, 0.02, 4)

    # Bog-iron nut/lock where the string catches.
    box(head, (0, 0, 1.95), (0.14, 0.26, 0.18))

    # The bolt, riding the top of the stock to the frame tip.
    limb(spike, (0, 0.14, 2.0), (0, 0.14, length - 0.18), 0.035, 0.03, 4)
    cone(spike, (0, 0.14, length - 0.18), (0, 0.14, length), 0.055, sides=4)

    # Gator teeth studding the fore-stock sides.
    for side in (-1, 1):
        for z in (2.12, 2.3):
            cone(spike, (side * 0.12, 0, z), (side * 0.3, 0, z + 0.08), 0.045, sides=4)

    # Bog-iron trigger work under the grip.
    box(guard, (-0.17, 0, 0.95), (0.08, 0.12, 0.34))
    box(guard, (-0.24, 0, 0.82), (0.14, 0.12, 0.06))

    # Wisp-light sight above the lock.
    ellipsoid(glow, (0, 0.16, 2.55), (0.05, 0.05, 0.05), subdiv=0)

    return [
        finish("GatorjawCrossbow_Haft", haft),
        finish("GatorjawCrossbow_Grip", grip_bm),
        finish("GatorjawCrossbow_Pommel", pommel),
        finish("GatorjawCrossbow_Guard", guard),
        finish("GatorjawCrossbow_Head", head),
        finish("GatorjawCrossbow_Edge", edge),
        finish("GatorjawCrossbow_Spike", spike),
        finish("GatorjawCrossbow_Glow", glow),
    ]


# ---------------------------------------------------------------- Mire Flintlock (swamp ranged, epic)
# A long-barrelled flintlock pistol: curved walnut grip swelling from the
# butt, brass lock plate with hammer and frizzen, octagonal iron barrel,
# ramrod underneath. Epic tier: fen-venom etching glows on the stock and up
# the barrel.


def build_mireflintlock():
    f = FRAME["MireFlintlock"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    pommel = bmesh.new()
    guard = bmesh.new()
    head = bmesh.new()
    edge = bmesh.new()
    spike = bmesh.new()
    glow = bmesh.new()

    # Curved wooden grip into the body.
    limb(haft, (0.22, 0, 0.04), (0.06, 0, 0.62), 0.16, 0.13, 6)
    limb(haft, (0.06, 0, 0.62), (0, 0, 1.0), 0.13, 0.12, 6)
    box(haft, (0, 0, 1.18), (0.28, 0.22, 0.46))
    limb(grip_bm, (0, 0, grip - 0.32), (0, 0, grip + 0.32), 0.19, 0.17, 7)
    ellipsoid(pommel, (0.25, 0, 0.05), (0.13, 0.12, 0.11), subdiv=1)

    # Brass lock plate, hammer and frizzen on the +y face.
    box(head, (0, 0.14, 1.15), (0.3, 0.06, 0.34))
    box(head, (-0.08, 0.17, 1.32), (0.08, 0.06, 0.2), Matrix.Rotation(math.radians(25), 4, "Y"))
    box(head, (0.1, 0.17, 1.3), (0.08, 0.06, 0.14))

    # Octagonal iron barrel to the muzzle, with a band near the end.
    limb(edge, (0, 0, 1.38), (0, 0, length), 0.11, 0.085, 8)
    limb(edge, (0, 0, 2.16), (0, 0, 2.24), 0.105, 0.105, 8)

    # Trigger guard (brass) and the wooden ramrod along the barrel.
    box(guard, (-0.15, 0, 1.0), (0.06, 0.1, 0.3))
    box(guard, (-0.2, 0, 0.87), (0.12, 0.1, 0.06))
    limb(spike, (0.14, 0, 1.4), (0.14, 0, 2.1), 0.03, 0.03, 4)

    # Fen-venom etching: strokes on both stock faces, a vein up the barrel.
    for side in (-1, 1):
        stroke(glow, (0.02, side * 0.12, 1.08), 0.3, 42)
        stroke(glow, (0.1, side * 0.12, 0.85), 0.22, -30)
    box(glow, (0, 0.1, 1.8), (0.02, 0.03, 0.55))

    return [
        finish("MireFlintlock_Haft", haft),
        finish("MireFlintlock_Grip", grip_bm),
        finish("MireFlintlock_Pommel", pommel),
        finish("MireFlintlock_Guard", guard),
        finish("MireFlintlock_Head", head),
        finish("MireFlintlock_Edge", edge),
        finish("MireFlintlock_Spike", spike),
        finish("MireFlintlock_Glow", glow),
    ]


# ---------------------------------------------------------------- Cinderlock Carbine (volcano ranged, uncommon)
# The first full-auto: an ash-scorched wooden stock and handguard around an
# obsidian receiver, gunmetal barrel, brass canted magazine and trigger
# guard. Uncommon tier: no glow.


def build_cinderlockcarbine():
    f = FRAME["CinderlockCarbine"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    pommel = bmesh.new()
    guard = bmesh.new()
    head = bmesh.new()
    edge = bmesh.new()
    spike = bmesh.new()

    # Stock: butt block into a tapering wrist, then the wooden handguard
    # further up the barrel.
    box(haft, (0.1, 0, 0.18), (0.32, 0.22, 0.36))
    limb(haft, (0.12, 0, 0.34), (0, 0, 1.3), 0.17, 0.12, 6)
    box(haft, (0.09, 0, 2.05), (0.13, 0.15, 0.7))
    box(pommel, (0.13, 0, 0.03), (0.28, 0.22, 0.08))
    limb(grip_bm, (0, 0, grip - 0.38), (0, 0, grip + 0.38), 0.16, 0.15, 7)

    # Obsidian receiver with a charging handle on the +y face.
    box(head, (0, 0, 1.5), (0.28, 0.24, 0.44))
    box(head, (0, 0.16, 1.56), (0.1, 0.1, 0.08))

    # Gunmetal barrel to the muzzle.
    limb(edge, (0, 0, 1.72), (0, 0, length), 0.1, 0.075, 8)

    # Brass trigger guard and a canted box magazine.
    box(guard, (-0.16, 0, 1.1), (0.06, 0.1, 0.3))
    box(guard, (-0.24, 0, 1.42), (0.14, 0.13, 0.38), Matrix.Rotation(math.radians(20), 4, "Y"))

    # Front sight post and muzzle ring.
    box(spike, (0, 0.1, 3.02), (0.04, 0.08, 0.12))
    limb(spike, (0, 0, length - 0.1), (0, 0, length), 0.085, 0.09, 8)

    return [
        finish("CinderlockCarbine_Haft", haft),
        finish("CinderlockCarbine_Grip", grip_bm),
        finish("CinderlockCarbine_Pommel", pommel),
        finish("CinderlockCarbine_Guard", guard),
        finish("CinderlockCarbine_Head", head),
        finish("CinderlockCarbine_Edge", edge),
        finish("CinderlockCarbine_Spike", spike),
    ]


# ---------------------------------------------------------------- Basalt Scattergun (volcano ranged, rare)
# A break-action double-barrel: obsidian breech, two side-by-side basalt
# barrels through a wide wooden forend. Rare tier: ember vents glow on the
# breech and up the seam between the barrels.


def build_basaltscattergun():
    f = FRAME["BasaltScattergun"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    pommel = bmesh.new()
    guard = bmesh.new()
    head = bmesh.new()
    edge = bmesh.new()
    spike = bmesh.new()
    glow = bmesh.new()

    # Stock into the breech, then the forend wrapping both barrels.
    box(haft, (0.11, 0, 0.2), (0.34, 0.24, 0.4))
    limb(haft, (0.12, 0, 0.38), (0, 0, 1.25), 0.19, 0.14, 6)
    box(haft, (0, 0, 1.8), (0.42, 0.22, 0.5))
    box(pommel, (0.14, 0, 0.04), (0.3, 0.24, 0.1))
    limb(grip_bm, (0, 0, grip - 0.38), (0, 0, grip + 0.38), 0.18, 0.16, 7)

    # Obsidian breech block with the top opening lever.
    box(head, (0, 0, 1.45), (0.4, 0.26, 0.4))
    box(head, (0, 0.15, 1.45), (0.08, 0.06, 0.26))

    # Twin basalt barrels, muzzle rims, and a barrel band.
    for side in (-1, 1):
        limb(edge, (side * 0.11, 0, 1.6), (side * 0.11, 0, length), 0.1, 0.095, 8)
        limb(spike, (side * 0.11, 0, length - 0.06), (side * 0.11, 0, length), 0.107, 0.107, 8)
    box(spike, (0, 0, 2.35), (0.46, 0.24, 0.12))

    # Brass trigger guard.
    box(guard, (-0.18, 0, 1.05), (0.06, 0.1, 0.32))

    # Ember vents: strokes on the breech faces, a line up the barrel seam.
    for side in (-1, 1):
        stroke(glow, (0, side * 0.14, 1.5), 0.26, 0)
    box(glow, (0, 0.08, 2.2), (0.03, 0.03, 0.7))

    return [
        finish("BasaltScattergun_Haft", haft),
        finish("BasaltScattergun_Grip", grip_bm),
        finish("BasaltScattergun_Pommel", pommel),
        finish("BasaltScattergun_Guard", guard),
        finish("BasaltScattergun_Head", head),
        finish("BasaltScattergun_Edge", edge),
        finish("BasaltScattergun_Spike", spike),
        finish("BasaltScattergun_Glow", glow),
    ]


# ---------------------------------------------------------------- Vulkan Repeater (volcano ranged, legendary)
# The capstone gun: a heavy full-auto repeater with an obsidian drum
# magazine, a vented gunmetal shroud over the barrel, and a muzzle brake.
# Legendary tier: molten cores glow in both drum faces, magma veins run the
# shroud, and the muzzle smoulders - the Slagheart Warhammer's role, ranged.


def build_vulkanrepeater():
    f = FRAME["VulkanRepeater"]
    length, grip = f["length"], f["grip"]
    haft = bmesh.new()
    grip_bm = bmesh.new()
    pommel = bmesh.new()
    guard = bmesh.new()
    head = bmesh.new()
    edge = bmesh.new()
    spike = bmesh.new()
    glow = bmesh.new()

    # Vent-metal frame: shoulder stock into the receiver spine.
    box(haft, (0.1, 0, 0.17), (0.32, 0.24, 0.36))
    limb(haft, (0.1, 0, 0.32), (0, 0, 1.5), 0.16, 0.12, 6)
    box(pommel, (0.13, 0, 0.02), (0.3, 0.24, 0.1))
    limb(grip_bm, (0, 0, grip - 0.4), (0, 0, grip + 0.4), 0.17, 0.16, 7)

    # The obsidian drum magazine, axis across the weapon.
    limb(head, (0, -0.17, 1.68), (0, 0.17, 1.68), 0.3, 0.3, 10)

    # Vented shroud and the barrel out of it, ending in the brake.
    limb(edge, (0, 0, 1.85), (0, 0, 2.95), 0.15, 0.13, 8)
    limb(edge, (0, 0, 2.95), (0, 0, length - 0.15), 0.095, 0.085, 8)
    box(spike, (0, 0, length - 0.12), (0.26, 0.26, 0.22))
    limb(spike, (0, 0, length - 0.04), (0, 0, length), 0.09, 0.09, 6)
    for side in (-1, 1):
        for z in (2.1, 2.45, 2.8):
            box(spike, (side * 0.15, 0, z), (0.05, 0.08, 0.16))

    # Obsidian trigger guard and foregrip.
    box(guard, (-0.16, 0, 1.18), (0.06, 0.1, 0.3))
    box(guard, (-0.21, 0, 2.35), (0.12, 0.12, 0.32))

    # The incendiary core: drum faces, veins along the shroud, muzzle glow.
    for side in (-1, 1):
        ellipsoid(glow, (0, side * 0.19, 1.68), (0.12, 0.025, 0.12), subdiv=1)
        box(glow, (side * 0.16, 0, 2.45), (0.02, 0.04, 0.7))
    ellipsoid(glow, (0, 0, length - 0.01), (0.055, 0.055, 0.04), subdiv=0)

    return [
        finish("VulkanRepeater_Haft", haft),
        finish("VulkanRepeater_Grip", grip_bm),
        finish("VulkanRepeater_Pommel", pommel),
        finish("VulkanRepeater_Guard", guard),
        finish("VulkanRepeater_Head", head),
        finish("VulkanRepeater_Edge", edge),
        finish("VulkanRepeater_Spike", spike),
        finish("VulkanRepeater_Glow", glow),
    ]


# ---------------------------------------------------------------- preview


def render_preview(groups, out_png):
    scene = bpy.context.scene
    # "BLENDER_EEVEE_NEXT" is the newer Blender's engine id, but the
    # `hasattr(bpy.types, "SceneEEVEE")` probe misdetects on some builds
    # (Blender 5.2 LTS keeps SceneEEVEE for compat while only accepting
    # "BLENDER_EEVEE" as the enum value) - try the modern id, fall back if
    # the running Blender rejects it. (Same fix as rod_gen.py.)
    try:
        scene.render.engine = "BLENDER_EEVEE_NEXT"
    except TypeError:
        scene.render.engine = "BLENDER_EEVEE"
    # Widen the frame to fit the row - it was sized for the original 7
    # weapons (spacing 3.2 -> row width 19.2) and now has to fit 21.
    spacing = 3.2
    row_width = spacing * max(len(groups) - 1, 0)
    base_row_width = 19.2
    # +55% margin so the outermost weapons don't clip the frame edge.
    width_scale = max(row_width / base_row_width, 1.0) * 1.55
    scene.render.resolution_x = min(int(1100 * width_scale), 5400)
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
    for i, objs in enumerate(groups):
        for obj in objs:
            if obj:
                obj.location.x += (i - (len(groups) - 1) / 2) * spacing

    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    bpy.context.collection.objects.link(cam)
    scene.camera = cam
    # Pull the camera back with the row width so a longer rack still frames
    # fully - distance scales the same way resolution_x did above.
    cam.location = Vector((-2.0, -18.5 * width_scale, 3.2))
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
        build_embercudgel(),
        build_cinderclub(),
        build_sulfurknuckles(),
        build_pumicefists(),
        build_cinderlash(),
        build_obsidianpiercer(),
        build_ridgebackpike(),
        build_slagfistgauntlet(),
        build_cinderspear(),
        build_lodestonemaul(),
        build_magmagauntlets(),
        build_riftcleaver(),
        build_sootveilblade(),
        build_slagheartwarhammer(),
        build_bogwoodbow(),
        build_gatorjawcrossbow(),
        build_mireflintlock(),
        build_cinderlockcarbine(),
        build_basaltscattergun(),
        build_vulkanrepeater(),
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
