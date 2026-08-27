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
    "Heartrender": {"length": 3.9, "grip": 0.72},
    # Volcano weapons (Weapons.luau "Volcano (lava island mats)").
    "ObsidianPiercer": {"length": 3.5, "grip": 0.64},
    "MagmaGauntlets": {"length": 3.2, "grip": 0.62},
    # Ranged (revamp S2): swamp tier-1 fantasy pieces + volcano gunpowder-tech.
    # Same frame rule as everything above - butt at z = 0, muzzle / upper limb
    # tip at z = LENGTH, _Grip centred on the hand point. The Weapons.luau
    # ranged rows must copy these numbers (source of truth until they land).
    "BogwoodBow": {"length": 2.8, "grip": 0.62},
    "GatorjawCrossbow": {"length": 2.8, "grip": 0.75},
    "MireFlintlock": {"length": 1.8, "grip": 0.4},
    "CinderlockCarbine": {"length": 3.25, "grip": 1.05},
    "BasaltScattergun": {"length": 2.6, "grip": 0.7},
    "VulkanRepeater": {"length": 3.6, "grip": 1.05},
    # Revamp S4 melee + ranged (islands 3/5/6 + Maelstrom) - f4's pass; the
    # Weapons.luau rows already carry these numbers (16's frame contract).
    "RustfangMachete": {"length": 3.3, "grip": 0.62},
    "Fenreaver": {"length": 3.8, "grip": 0.7},
    "IcepickHatchet": {"length": 2.6, "grip": 0.5},
    "FrostboreRifle": {"length": 3.9, "grip": 1.05},
    "GlacierMaul": {"length": 4.2, "grip": 0.8},
    "FrostbiteRevolver": {"length": 1.8, "grip": 0.34},
    "RimefangLance": {"length": 4.6, "grip": 0.9},
    "Trenchspike": {"length": 3.0, "grip": 0.6},
    "AbyssalHarpooner": {"length": 3.2, "grip": 0.85},
    "RiptideSmg": {"length": 1.9, "grip": 0.62},
    "VoidglassSaber": {"length": 3.8, "grip": 0.7},
    "GloomcallerDmr": {"length": 3.8, "grip": 1.3},
    "BoardingAxe": {"length": 3.4, "grip": 0.7},
    "GraveBlunderbuss": {"length": 2.85, "grip": 0.8},
    "PhantomRepeater": {"length": 3.45, "grip": 1.1},
    "CutlassOfTheFleet": {"length": 3.6, "grip": 0.65},
    "AdmiralsSaber": {"length": 4.0, "grip": 0.7},
    "Galecleaver": {"length": 3.8, "grip": 0.7},
    "CycloneRifle": {"length": 3.45, "grip": 1.25},
    "ThunderheadCannon": {"length": 2.2, "grip": 0.5},
    "Stormlance": {"length": 4.6, "grip": 0.9},
    "Krakenfang": {"length": 4.4, "grip": 0.75},
}

# Preview-only colours, per part object (r,g,b 0..1), mirroring the game rows.
COLORS = {
    "DriftwoodClub_Haft": (0.59, 0.44, 0.28),  # driftwood
    "DriftwoodClub_Head": (0.49, 0.42, 0.36),  # salvaged anchor iron (mirrors the row's accent)
    "DriftwoodClub_Spike": (0.49, 0.42, 0.36),  # break splinters + shackle, same iron
    "DriftwoodClub_Grip": (0.34, 0.55, 0.33),  # kelp wrap
    "Scaleblade_Haft": (0.50, 0.38, 0.24),  # driftwood haft
    "Scaleblade_Grip": (0.38, 0.27, 0.18),  # darker bound handle
    "Scaleblade_Guard": (0.50, 0.38, 0.24),
    "Scaleblade_Pommel": (0.50, 0.38, 0.24),  # the caudal fan folded over the butt
    "Scaleblade_Edge": (0.72, 0.82, 0.90),  # fish-scale steel
    "Scaleblade_Spike": (0.72, 0.82, 0.90),  # fin rays, gill bars, the eye
    "Shellcrusher_Haft": (0.55, 0.42, 0.27),  # driftwood haft
    "Shellcrusher_Grip": (0.29, 0.34, 0.31),  # dark bound grip
    "Shellcrusher_Head": (0.78, 0.70, 0.59),  # warm whelk shell (mirrors the row's accent)
    "Shellcrusher_Spike": (0.78, 0.70, 0.59),
    "Shellcrusher_Guard": (0.55, 0.42, 0.27),
    "Drowncleaver_Haft": (0.59, 0.55, 0.43),  # bone handle
    "Drowncleaver_Grip": (0.22, 0.26, 0.22),  # dark brine wrap
    "Drowncleaver_Edge": (0.82, 0.80, 0.70),  # pale bone blade
    "Drowncleaver_Guard": (0.55, 0.52, 0.42),  # jawbone guard
    "Drowncleaver_Spike": (0.82, 0.80, 0.70),
    "Drowncleaver_Glow": (0.45, 0.95, 0.55),  # brine-green runes
    "Heartrender_Haft": (0.36, 0.24, 0.26),
    "Heartrender_Grip": (0.23, 0.16, 0.17),
    "Heartrender_Guard": (0.36, 0.24, 0.26),
    "Heartrender_Pommel": (0.36, 0.24, 0.26),  # the vein-coil knot at the butt
    "Heartrender_Edge": (0.77, 0.31, 0.32),  # red blade
    "Heartrender_Spike": (0.77, 0.31, 0.32),
    "Heartrender_Glow": (1.0, 0.38, 0.41),  # the beat
    # Volcano weapons (Weapons.luau "Volcano (lava island mats)"). Colours
    # mirror the game rows' color/accent/wrap/glow.
    "ObsidianPiercer_Haft": (0.55, 0.42, 0.27),  # driftwood
    "ObsidianPiercer_Grip": (0.24, 0.20, 0.18),  # dark binding
    "ObsidianPiercer_Guard": (0.55, 0.42, 0.27),
    "ObsidianPiercer_Edge": (0.19, 0.17, 0.24),  # glass-black obsidian
    "ObsidianPiercer_Spike": (0.19, 0.17, 0.24),
    "ObsidianPiercer_Glow": (0.94, 0.52, 0.20),  # the hairline crack of heat
    "MagmaGauntlets_Haft": (0.27, 0.23, 0.22),  # dark vent-metal
    "MagmaGauntlets_Grip": (0.59, 0.73, 0.82),  # fish-scale binding
    "MagmaGauntlets_Guard": (0.27, 0.23, 0.22),
    "MagmaGauntlets_Edge": (0.89, 0.81, 0.35),  # sulfur-cured claws
    "MagmaGauntlets_Spike": (0.89, 0.81, 0.35),
    "MagmaGauntlets_Glow": (0.96, 0.38, 0.16),  # the magma vein
    # Ranged - swamp (bogwood / bog iron / gator scute fantasy tier).
    "BogwoodBow_Haft": (0.4, 0.31, 0.2),  # dark bogwood stave + arrow shaft
    "BogwoodBow_Grip": (0.3, 0.36, 0.28),  # gator-hide binding
    "BogwoodBow_Edge": (0.8, 0.76, 0.6),  # sinew string
    "BogwoodBow_Spike": (0.72, 0.68, 0.55),  # bone tips, arrowhead, fletching
    "BogwoodBow_Mag": (0.46, 0.36, 0.24),  # the nocked arrow (the reload part)
    "BogwoodBow_Action": (0.86, 0.82, 0.66),  # the sinew string (the draw part)
    "BogwoodBow_Sight": (0.72, 0.68, 0.55),  # arrow rest + bone sight pin
    "BogwoodBow_Muzzle": (0.72, 0.68, 0.55),  # projectile-origin marker
    "GatorjawCrossbow_Haft": (0.42, 0.32, 0.21),  # bogwood stock
    "GatorjawCrossbow_Grip": (0.27, 0.31, 0.26),  # dark hide binding
    "GatorjawCrossbow_Pommel": (0.42, 0.32, 0.21),
    "GatorjawCrossbow_Guard": (0.35, 0.33, 0.29),  # bog-iron trigger work
    "GatorjawCrossbow_Head": (0.35, 0.33, 0.29),  # bog-iron lock
    "GatorjawCrossbow_Edge": (0.44, 0.51, 0.36),  # gator-scute prod + string
    "GatorjawCrossbow_Spike": (0.85, 0.82, 0.69),  # gator teeth + the bolt
    "GatorjawCrossbow_Glow": (0.55, 0.85, 0.73),  # wisp-light sight
    "GatorjawCrossbow_Mag": (0.42, 0.32, 0.21),  # bolt clip + spare bolts
    "GatorjawCrossbow_Action": (0.86, 0.82, 0.69),  # string + claw trigger
    "GatorjawCrossbow_Sight": (0.35, 0.33, 0.29),  # rail sights
    "GatorjawCrossbow_Muzzle": (0.35, 0.33, 0.29),
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
    # Revamp S4 weapons (f4's pass): Haft/Guard/Pommel = row color, Grip =
    # wrap, Head/Edge/Spike = accent, Glow = row glow.
    "RustfangMachete_Haft": (0.38, 0.31, 0.21),
    "RustfangMachete_Guard": (0.38, 0.31, 0.21),
    "RustfangMachete_Pommel": (0.38, 0.31, 0.21),
    "RustfangMachete_Grip": (0.25, 0.27, 0.20),
    "RustfangMachete_Head": (0.64, 0.38, 0.24),
    "RustfangMachete_Edge": (0.64, 0.38, 0.24),
    "RustfangMachete_Spike": (0.64, 0.38, 0.24),
    "Fenreaver_Haft": (0.23, 0.26, 0.18),
    "Fenreaver_Guard": (0.23, 0.26, 0.18),
    "Fenreaver_Pommel": (0.23, 0.26, 0.18),
    "Fenreaver_Grip": (0.17, 0.19, 0.14),
    "Fenreaver_Head": (0.59, 0.92, 0.78),
    "Fenreaver_Edge": (0.59, 0.92, 0.78),
    "Fenreaver_Spike": (0.59, 0.92, 0.78),
    "Fenreaver_Glow": (0.59, 0.92, 0.78),
    "IcepickHatchet_Haft": (0.47, 0.53, 0.59),
    "IcepickHatchet_Guard": (0.47, 0.53, 0.59),
    "IcepickHatchet_Pommel": (0.47, 0.53, 0.59),
    "IcepickHatchet_Grip": (0.35, 0.41, 0.47),
    "IcepickHatchet_Head": (0.82, 0.89, 0.94),
    "IcepickHatchet_Edge": (0.82, 0.89, 0.94),
    "IcepickHatchet_Spike": (0.82, 0.89, 0.94),
    "IcepickHatchet_Glow": (0.55, 0.86, 1.00),  # the rime seam in the icicle
    "FrostboreRifle_Haft": (0.41, 0.38, 0.33),
    "FrostboreRifle_Guard": (0.41, 0.38, 0.33),
    "FrostboreRifle_Pommel": (0.41, 0.38, 0.33),
    "FrostboreRifle_Grip": (0.27, 0.25, 0.22),
    "FrostboreRifle_Head": (0.67, 0.73, 0.79),
    "FrostboreRifle_Edge": (0.67, 0.73, 0.79),
    "FrostboreRifle_Spike": (0.67, 0.73, 0.79),
    "GlacierMaul_Haft": (0.59, 0.55, 0.49),
    "GlacierMaul_Guard": (0.59, 0.55, 0.49),
    "GlacierMaul_Pommel": (0.59, 0.55, 0.49),
    "GlacierMaul_Grip": (0.41, 0.38, 0.33),
    "GlacierMaul_Head": (0.68, 0.85, 0.94),  # glacier_maul.png's ice is brighter than this was
    "GlacierMaul_Edge": (0.68, 0.85, 0.94),
    "GlacierMaul_Spike": (0.68, 0.85, 0.94),
    "GlacierMaul_Glow": (0.47, 0.78, 1.00),
    "FrostbiteRevolver_Haft": (0.35, 0.39, 0.45),
    "FrostbiteRevolver_Guard": (0.35, 0.39, 0.45),
    "FrostbiteRevolver_Pommel": (0.35, 0.39, 0.45),
    "FrostbiteRevolver_Grip": (0.24, 0.27, 0.32),
    "FrostbiteRevolver_Head": (0.78, 0.88, 0.94),
    "FrostbiteRevolver_Edge": (0.78, 0.88, 0.94),
    "FrostbiteRevolver_Spike": (0.78, 0.88, 0.94),
    "FrostbiteRevolver_Glow": (0.47, 0.78, 1.00),
    # rimefang_lance.png sets its pale ice head on a DARK slate shaft - the
    # contrast between the two is what makes the head read at all.
    "RimefangLance_Haft": (0.36, 0.44, 0.52),
    "RimefangLance_Guard": (0.36, 0.44, 0.52),
    "RimefangLance_Pommel": (0.36, 0.44, 0.52),
    "RimefangLance_Grip": (0.31, 0.39, 0.49),
    "RimefangLance_Head": (0.93, 0.96, 0.99),
    "RimefangLance_Edge": (0.93, 0.96, 0.99),
    "RimefangLance_Spike": (0.93, 0.96, 0.99),
    "RimefangLance_Glow": (0.31, 0.86, 1.00),
    "Trenchspike_Haft": (0.27, 0.31, 0.36),
    "Trenchspike_Guard": (0.27, 0.31, 0.36),
    "Trenchspike_Pommel": (0.27, 0.31, 0.36),
    "Trenchspike_Grip": (0.19, 0.21, 0.26),
    # trenchspike.png is near-black end to end; the head is barely lighter than
    # the shaft, and nothing on it is lit.
    "Trenchspike_Head": (0.36, 0.39, 0.46),
    "Trenchspike_Edge": (0.36, 0.39, 0.46),
    "Trenchspike_Spike": (0.36, 0.39, 0.46),
    "Trenchspike_Glow": (0.45, 0.60, 0.75),
    "AbyssalHarpooner_Haft": (0.24, 0.26, 0.33),
    "AbyssalHarpooner_Guard": (0.24, 0.26, 0.33),
    "AbyssalHarpooner_Pommel": (0.24, 0.26, 0.33),
    "AbyssalHarpooner_Grip": (0.17, 0.19, 0.24),
    "AbyssalHarpooner_Head": (0.55, 0.59, 0.67),
    "AbyssalHarpooner_Edge": (0.55, 0.59, 0.67),
    "AbyssalHarpooner_Spike": (0.55, 0.59, 0.67),
    "RiptideSmg_Haft": (0.30, 0.33, 0.39),
    "RiptideSmg_Guard": (0.30, 0.33, 0.39),
    "RiptideSmg_Pommel": (0.30, 0.33, 0.39),
    "RiptideSmg_Grip": (0.20, 0.23, 0.28),
    "RiptideSmg_Head": (0.55, 0.86, 1.00),
    "RiptideSmg_Edge": (0.55, 0.86, 1.00),
    "RiptideSmg_Spike": (0.55, 0.86, 1.00),
    "VoidglassSaber_Haft": (0.16, 0.14, 0.22),
    "VoidglassSaber_Guard": (0.16, 0.14, 0.22),
    "VoidglassSaber_Pommel": (0.16, 0.14, 0.22),
    "VoidglassSaber_Grip": (0.12, 0.10, 0.16),
    # voidglass_saber.png is a NEAR-BLACK blade with one vivid purple seam. The
    # blade has to stay dark or the seam stops being the whole weapon.
    "VoidglassSaber_Head": (0.15, 0.14, 0.19),
    "VoidglassSaber_Edge": (0.15, 0.14, 0.19),
    "VoidglassSaber_Spike": (0.15, 0.14, 0.19),
    "VoidglassSaber_Glow": (0.64, 0.33, 0.95),
    "GloomcallerDmr_Haft": (0.22, 0.20, 0.28),
    "GloomcallerDmr_Guard": (0.22, 0.20, 0.28),
    "GloomcallerDmr_Pommel": (0.22, 0.20, 0.28),
    "GloomcallerDmr_Grip": (0.16, 0.14, 0.21),
    "GloomcallerDmr_Head": (1.00, 0.89, 0.51),
    "GloomcallerDmr_Edge": (1.00, 0.89, 0.51),
    "GloomcallerDmr_Spike": (1.00, 0.89, 0.51),
    "GloomcallerDmr_Glow": (1.00, 0.89, 0.51),
    # boarding_axe.png hangs its head on plain BROWN WOOD, not grey iron.
    "BoardingAxe_Haft": (0.42, 0.29, 0.19),
    "BoardingAxe_Guard": (0.42, 0.29, 0.19),
    "BoardingAxe_Pommel": (0.42, 0.29, 0.19),
    "BoardingAxe_Grip": (0.28, 0.20, 0.14),
    "BoardingAxe_Head": (0.66, 0.68, 0.70),
    "BoardingAxe_Edge": (0.66, 0.68, 0.70),
    "BoardingAxe_Spike": (0.66, 0.68, 0.70),
    "BoardingAxe_Glow": (0.78, 0.90, 0.95),  # a cold sheen; the icon lights nothing
    "GraveBlunderbuss_Haft": (0.41, 0.35, 0.26),
    "GraveBlunderbuss_Guard": (0.41, 0.35, 0.26),
    "GraveBlunderbuss_Pommel": (0.41, 0.35, 0.26),
    "GraveBlunderbuss_Grip": (0.27, 0.24, 0.19),
    "GraveBlunderbuss_Head": (0.59, 0.61, 0.64),
    "GraveBlunderbuss_Edge": (0.59, 0.61, 0.64),
    "GraveBlunderbuss_Spike": (0.59, 0.61, 0.64),
    "PhantomRepeater_Haft": (0.38, 0.45, 0.42),
    "PhantomRepeater_Guard": (0.38, 0.45, 0.42),
    "PhantomRepeater_Pommel": (0.38, 0.45, 0.42),
    "PhantomRepeater_Grip": (0.25, 0.31, 0.28),
    "PhantomRepeater_Head": (0.63, 1.00, 0.82),
    "PhantomRepeater_Edge": (0.63, 1.00, 0.82),
    "PhantomRepeater_Spike": (0.63, 1.00, 0.82),
    "PhantomRepeater_Glow": (0.63, 1.00, 0.82),
    # cutlass_of_the_fleet.png is bright silver furniture as well as blade.
    "CutlassOfTheFleet_Haft": (0.62, 0.67, 0.63),
    "CutlassOfTheFleet_Guard": (0.62, 0.67, 0.63),
    "CutlassOfTheFleet_Pommel": (0.62, 0.67, 0.63),
    "CutlassOfTheFleet_Grip": (0.40, 0.45, 0.42),
    "CutlassOfTheFleet_Head": (0.85, 0.89, 0.86),
    "CutlassOfTheFleet_Edge": (0.85, 0.89, 0.86),
    "CutlassOfTheFleet_Spike": (0.85, 0.89, 0.86),
    "CutlassOfTheFleet_Glow": (0.63, 1.00, 0.82),
    # admirals_saber.png is SILVER throughout - a bright steel blade and a pale
    # jewelled hilt. The gilt accent it used to carry fought the icon outright.
    "AdmiralsSaber_Haft": (0.60, 0.65, 0.62),
    "AdmiralsSaber_Guard": (0.60, 0.65, 0.62),
    "AdmiralsSaber_Pommel": (0.60, 0.65, 0.62),
    "AdmiralsSaber_Grip": (0.42, 0.47, 0.45),
    "AdmiralsSaber_Head": (0.88, 0.91, 0.88),
    "AdmiralsSaber_Edge": (0.88, 0.91, 0.88),
    "AdmiralsSaber_Spike": (0.88, 0.91, 0.88),
    "AdmiralsSaber_Glow": (0.80, 0.97, 0.88),
    "Galecleaver_Haft": (0.43, 0.49, 0.55),
    "Galecleaver_Guard": (0.43, 0.49, 0.55),
    "Galecleaver_Pommel": (0.43, 0.49, 0.55),
    "Galecleaver_Grip": (0.30, 0.34, 0.39),
    "Galecleaver_Head": (0.78, 0.84, 0.89),
    "Galecleaver_Edge": (0.78, 0.84, 0.89),
    "Galecleaver_Spike": (0.78, 0.84, 0.89),
    "Galecleaver_Glow": (0.72, 0.92, 1.00),  # the air tearing in the ports
    "CycloneRifle_Haft": (0.30, 0.34, 0.41),
    "CycloneRifle_Guard": (0.30, 0.34, 0.41),
    "CycloneRifle_Pommel": (0.30, 0.34, 0.41),
    "CycloneRifle_Grip": (0.21, 0.24, 0.31),
    "CycloneRifle_Head": (0.55, 0.78, 1.00),
    "CycloneRifle_Edge": (0.55, 0.78, 1.00),
    "CycloneRifle_Spike": (0.55, 0.78, 1.00),
    "ThunderheadCannon_Haft": (0.27, 0.31, 0.39),
    "ThunderheadCannon_Guard": (0.27, 0.31, 0.39),
    "ThunderheadCannon_Pommel": (0.27, 0.31, 0.39),
    "ThunderheadCannon_Grip": (0.20, 0.23, 0.29),
    "ThunderheadCannon_Head": (0.86, 0.90, 1.00),
    "ThunderheadCannon_Edge": (0.86, 0.90, 1.00),
    "ThunderheadCannon_Spike": (0.86, 0.90, 1.00),
    "ThunderheadCannon_Glow": (0.86, 0.90, 1.00),
    # stormlance.png: dark navy shaft, pale ice-blue head and wings.
    "Stormlance_Haft": (0.25, 0.30, 0.40),
    "Stormlance_Guard": (0.25, 0.30, 0.40),
    "Stormlance_Pommel": (0.25, 0.30, 0.40),
    "Stormlance_Grip": (0.20, 0.25, 0.34),
    "Stormlance_Head": (0.74, 0.87, 0.96),
    "Stormlance_Edge": (0.74, 0.87, 0.96),
    "Stormlance_Spike": (0.74, 0.87, 0.96),
    "Stormlance_Glow": (0.55, 0.78, 1.00),
    "Krakenfang_Haft": (0.24, 0.17, 0.33),
    "Krakenfang_Guard": (0.24, 0.17, 0.33),
    "Krakenfang_Pommel": (0.24, 0.17, 0.33),
    "Krakenfang_Grip": (0.17, 0.13, 0.24),
    "Krakenfang_Head": (0.86, 0.82, 0.94),
    "Krakenfang_Edge": (0.86, 0.82, 0.94),
    "Krakenfang_Spike": (0.86, 0.82, 0.94),
    "Krakenfang_Glow": (0.78, 0.66, 0.95),  # the pale stone in the pommel, not a pearl
}

# The fifteen ranged variants (see "RANGED REBUILD" near the bottom). Each gun
# now emits four more part suffixes than the melee contract had - _Mag,
# _Action, _Sight, _Muzzle - and make_material() looks EVERY finished part name
# up in COLORS, so a missing entry is a hard KeyError at build time. Rather
# than hand-write sixty more preview colours, derive each gun's full set from
# the layers its Weapons.luau row already mirrors above: color (Haft/Guard/
# Pommel), wrap (Grip), accent (the metal: Head/Edge/Spike and all four new
# suffixes) and glow. setdefault, so every hand-tuned line above still wins.
RANGED_VARIANTS = (
    "FrostboreRifle",
    "GloomcallerDmr",
    "CycloneRifle",
    "CinderlockCarbine",
    "PhantomRepeater",
    "MireFlintlock",
    "FrostbiteRevolver",
    "ThunderheadCannon",
    "GraveBlunderbuss",
    "BasaltScattergun",
    "BogwoodBow",
    "GatorjawCrossbow",
    "AbyssalHarpooner",
    "RiptideSmg",
    "VulkanRepeater",
)

for _variant in RANGED_VARIANTS:
    _color = COLORS.get(f"{_variant}_Haft") or COLORS[f"{_variant}_Guard"]
    _wrap = COLORS.get(f"{_variant}_Grip", _color)
    _accent = COLORS.get(f"{_variant}_Edge") or COLORS.get(f"{_variant}_Spike") or _color
    _glow = COLORS.get(f"{_variant}_Glow", _accent)
    for _suffix, _rgb in (
        ("Haft", _color),
        ("Guard", _color),
        ("Pommel", _color),
        ("Grip", _wrap),
        ("Head", _accent),
        ("Edge", _accent),
        ("Spike", _accent),
        ("Mag", _accent),
        ("Action", _accent),
        ("Sight", _accent),
        ("Muzzle", _accent),
        ("Glow", _glow),
    ):
        COLORS.setdefault(f"{_variant}_{_suffix}", _rgb)

GLOW_PARTS = {  # emissive in the preview only
    "Drowncleaver_Glow",
    "Heartrender_Glow",
    "ObsidianPiercer_Glow",
    "MagmaGauntlets_Glow",
    "GatorjawCrossbow_Glow",
    "MireFlintlock_Glow",
    "BasaltScattergun_Glow",
    "VulkanRepeater_Glow",
    "Fenreaver_Glow",
    "IcepickHatchet_Glow",
    "GlacierMaul_Glow",
    "FrostbiteRevolver_Glow",
    "RimefangLance_Glow",
    "Trenchspike_Glow",
    "VoidglassSaber_Glow",
    "GloomcallerDmr_Glow",
    "PhantomRepeater_Glow",
    "BoardingAxe_Glow",
    "CutlassOfTheFleet_Glow",
    "AdmiralsSaber_Glow",
    "Galecleaver_Glow",
    "ThunderheadCannon_Glow",
    "Stormlance_Glow",
    "Krakenfang_Glow",
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


def _point_in_polygon(pt, poly):
    """Even-odd ray cast in the x-z plane."""
    x, z = pt
    inside = False
    n = len(poly)
    for i in range(n):
        x0, z0 = poly[i]
        x1, z1 = poly[(i + 1) % n]
        if (z0 > z) != (z1 > z):
            cross = x0 + (z - z0) / (z1 - z0) * (x1 - x0)
            if x < cross:
                inside = not inside
    return inside


def slab_with_hole(bm, profile, hole, hole_r, y, hole_sides=8):
    """slab(), but with a round through-hole at `hole` = (x, z): the side
    walls and the hole's walls are quads, and each broad face is the annulus
    between the outer loop and the hole loop (bridge_loops).

    The hole circle must lie STRICTLY INSIDE the profile polygon. A ring
    that pokes past the outline has no valid annulus - bridge_loops still
    "succeeds" structurally and stitches folded garbage that renders as a
    SOLID face (found the hard way: a 0.3-radius wind port near the
    Galecleaver's spine, 2026-08-27) - so this now fails loudly at build
    time instead."""
    n, m = len(profile), hole_sides
    ring = [(hole[0] + math.cos(a) * hole_r, hole[1] + math.sin(a) * hole_r) for a in ((i / m) * TAU for i in range(m))]
    for rx, rz in ring:
        if not _point_in_polygon((rx, rz), profile):
            raise ValueError(
                f"slab_with_hole: hole at {hole} r={hole_r} leaves the profile "
                f"(ring point ({rx:.3f}, {rz:.3f}) is outside) - no valid "
                "annulus exists; shrink or move the hole"
            )

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


# ================================================================ COVE / SWAMP / VOLCANO MELEE (_wa_)
# The shared moves behind the cove, swamp and volcano melee. The rule these
# nine are held to is the ROD pack's: a silhouette that names the weapon with
# the palette turned off, plus one ornament only that weapon has. Contract as
# everywhere else in the file - butt z = 0, tip z = LENGTH, cutting edges and
# striking faces to +x, flats and filigree on +-y, _Grip a plain symmetric
# sleeve centred on the hand point (charms hang off another part).
#
# Named _wa_* so they never collide with the other passes over this file.


def _wa_arc(p0, p1, bow_dir, bow, steps=6):
    """Points along a bowed arc p0 -> p1, pushed `bow` studs toward `bow_dir`
    at its middle: the spine of a rib, root, anchor arm or jaw."""
    a, b = Vector(p0), Vector(p1)
    d = Vector(bow_dir)
    d = d.normalized() if d.length > 1e-6 else Vector((1, 0, 0))
    return [a.lerp(b, i / steps) + d * (bow * math.sin(math.pi * i / steps)) for i in range(steps + 1)]


def _wa_chain(bm, pts, r0, r1, sides=4):
    """A tapered chain of limbs through `pts` - one rib, root, arm or tendril."""
    n = max(1, len(pts) - 1)
    for i in range(n):
        limb(bm, pts[i], pts[i + 1], r0 + (r1 - r0) * (i / n), r0 + (r1 - r0) * ((i + 1) / n), sides)


def _wa_helix(z0, z1, turns, r, phase=0.0, per_turn=5):
    """Points of a helix wound up the shaft axis - one strand of a root braid.
    `r` is a radius or a function of t."""
    steps = max(2, int(abs(turns) * per_turn))
    out = []
    for i in range(steps + 1):
        t = i / steps
        a = phase + turns * TAU * t
        rr = r(t) if callable(r) else r
        out.append(Vector((math.cos(a) * rr, math.sin(a) * rr, z0 + (z1 - z0) * t)))
    return out


def _wa_ring(bm, center, r, tube, normal=(0, 1, 0), seg=7):
    """A closed ring - a mooring shackle, a lit collar, a lantern hoop."""
    c = Vector(center)
    d = Vector(normal).normalized()
    up = Vector((0, 0, 1)) if abs(d.z) < 0.9 else Vector((1, 0, 0))
    u = d.cross(up).normalized()
    v = d.cross(u).normalized()
    pts = [c + (u * math.cos(i * TAU / seg) + v * math.sin(i * TAU / seg)) * r for i in range(seg)]
    for i in range(seg):
        limb(bm, pts[i], pts[(i + 1) % seg], tube, tube, 3)


def _wa_teeth(bm, pts, out, length=0.22, base_r=0.06, taper=1.0, sides=4):
    """A row of teeth / barbs standing off a path, all raked the same way;
    `taper` scales the last one against the first."""
    o = Vector(out).normalized()
    n = max(1, len(pts) - 1)
    for i, pt in enumerate(pts):
        s = 1.0 + (taper - 1.0) * (i / n)
        pt = Vector(pt)
        cone(bm, pt, pt + o * (length * s), base_r * s, sides=sides)


def _wa_shard(bm, base, direction, length, half_w, flat=0.45, phase=0.0):
    """A struck splinter of glass, shell or bone: a squashed four-sided
    bipyramid with its waist a third of the way up. Eight triangles and every
    one of them is a facet."""
    b = Vector(base)
    d = Vector(direction).normalized()
    up = Vector((0, 0, 1)) if abs(d.z) < 0.9 else Vector((1, 0, 0))
    u = d.cross(up).normalized()
    v = d.cross(u).normalized()
    waist = [bm.verts.new(b + d * (length * 0.34) + (u * math.cos(phase + i * TAU / 4) + v * math.sin(phase + i * TAU / 4) * flat) * half_w) for i in range(4)]
    root = bm.verts.new(b)
    tip = bm.verts.new(b + d * length)
    for i in range(4):
        j = (i + 1) % 4
        bm.faces.new((waist[j], waist[i], root))
        bm.faces.new((waist[i], waist[j], tip))


def _wa_whorl(bm, center, axis, turns, r0, r1, tube0, tube1, span, steps=18, sides=5, phase=0.0):
    """A spiral shell: a tapering tube coiling `turns` times about `axis` while
    its coil radius shrinks r0 -> r1 and it climbs `span` along the axis. Wound
    in the swing plane it reads as a whelk from clear across the island."""
    c = Vector(center)
    d = Vector(axis).normalized()
    up = Vector((0, 0, 1)) if abs(d.z) < 0.9 else Vector((1, 0, 0))
    u = d.cross(up).normalized()
    v = d.cross(u).normalized()

    def at(t):
        a = phase + turns * TAU * t
        return c + d * (span * t) + (u * math.cos(a) + v * math.sin(a)) * (r0 + (r1 - r0) * t)

    pts = [at(i / steps) for i in range(steps + 1)]
    for i in range(steps):
        limb(bm, pts[i], pts[i + 1], tube0 + (tube1 - tube0) * (i / steps), tube0 + (tube1 - tube0) * ((i + 1) / steps), sides)
    return at


def _wa_cage(bm, center, r, half_h, bars=4, axis=(0, 0, 1), bar_r=0.026, hoop_r=0.022, phase=0.0):
    """A lantern cage: `bars` uprights bowed out around an axis and closed by a
    hoop at each end - what a caught wisp is kept in."""
    c = Vector(center)
    d = Vector(axis).normalized()
    up = Vector((0, 0, 1)) if abs(d.z) < 0.9 else Vector((1, 0, 0))
    u = d.cross(up).normalized()
    v = d.cross(u).normalized()
    for i in range(bars):
        a = phase + (i / bars) * TAU
        out = u * math.cos(a) + v * math.sin(a)
        _wa_chain(bm, _wa_arc(c - d * half_h, c + d * half_h, out, r, steps=2), bar_r, bar_r, 4)
    for s in (-1, 1):
        for i in range(bars):
            a0, a1 = phase + (i / bars) * TAU, phase + ((i + 1) / bars) * TAU
            cap = c + d * (half_h * s)
            limb(bm, cap + (u * math.cos(a0) + v * math.sin(a0)) * (r * 0.5), cap + (u * math.cos(a1) + v * math.sin(a1)) * (r * 0.5), hoop_r, hoop_r, 3)


def _wa_scale(bm, center, r, thick=0.045, sides=5, phase=0.0):
    """One armour scale lying on a blade flat (its axis along y), rotated by
    `phase` so successive rows break the brickwork instead of gridding it."""
    c = Vector(center)
    off = Vector((0, thick / 2, 0))
    ang = [phase + i * TAU / sides for i in range(sides)]
    a = [bm.verts.new(c - off + Vector((math.cos(t) * r, 0, math.sin(t) * r))) for t in ang]
    b = [bm.verts.new(c + off + Vector((math.cos(t) * r, 0, math.sin(t) * r))) for t in ang]
    for i in range(sides):
        j = (i + 1) % sides
        bm.faces.new((a[i], a[j], b[j], b[i]))
    bm.faces.new(list(reversed(a)))
    bm.faces.new(b)


def _wa_pierce(bm, profile, hole, hole_r, y, hole_sides=8):
    """slab_with_hole(), but with the hole ring wound the OTHER way.

    The shared slab_with_hole() generates its inner ring counter-clockwise, the
    same sense as a CCW outer profile - and bridge_loops given two same-sense
    loops stitches a folded annulus that renders as a SOLID face. It raises on
    a ring that leaves the profile, so the failure is silent: the geometry is
    valid, it just has no hole in it (checked 2026-08-28 by ray-casting the
    Drowncleaver's hanging hole - the ray hit the blade). Reversing the inner
    ring gives bridge_loops the opposing sense it wants and the hole opens.

    Used by the two icon-canon pierced blades below (Drowncleaver, Fenreaver).
    Anything else in the file still calling slab_with_hole is very likely
    carrying a hole that never actually opened - worth an audit."""
    n, m = len(profile), hole_sides
    ring = [(hole[0] + math.cos(a) * hole_r, hole[1] + math.sin(a) * hole_r) for a in ((i / m) * TAU for i in range(m))]
    for rx, rz in ring:
        if not _point_in_polygon((rx, rz), profile):
            raise ValueError(f"_wa_pierce: hole at {hole} r={hole_r} leaves the profile at ({rx:.3f}, {rz:.3f})")
    ring.reverse()

    def loop(yy, pts):
        return [bm.verts.new(Vector((x, yy, z))) for x, z in pts]

    fo, bo = loop(-y, profile), loop(y, profile)
    fi, bi = loop(-y, ring), loop(y, ring)
    for i in range(n):
        bm.faces.new((fo[i], fo[(i + 1) % n], bo[(i + 1) % n], bo[i]))
    for i in range(m):
        bm.faces.new((fi[i], fi[(i + 1) % m], bi[(i + 1) % m], bi[i]))

    def edge(a, b):
        return bm.edges.get((a, b)) or bm.edges.new((a, b))

    for outer, inner in ((fo, fi), (bo, bi)):
        edges = [edge(outer[i], outer[(i + 1) % n]) for i in range(n)]
        edges += [edge(inner[i], inner[(i + 1) % m]) for i in range(m)]
        bmesh.ops.bridge_loops(bm, edges=edges)


def _wa_vent(bm, glow_bm, base, direction, height, r0, r1, sides=6):
    """A vent chimney: a short tapering stack of rock with a molten throat -
    a knuckle on the gauntlets, a fumarole on anything volcanic."""
    b = Vector(base)
    d = Vector(direction).normalized()
    limb(bm, b, b + d * height, r0, r1, sides)
    limb(glow_bm, b + d * (height * 0.78), b + d * (height * 1.02), r1 * 0.82, r1 * 0.62, sides)


# ---------------------------------------------------------------- Driftwood Club (starter)
# ICON (assets/icons/driftwood_club.png, canon): no iron on it at all - one
# thick sea-worn BRANCH with a gentle S in it, fatter at the striking end than
# at the butt, a knot swelling at each kink, two snapped branch nubs, a split
# fork at the far end, and a pale binding tied round the lower third. That is
# the whole weapon. The 2026-08-27 anchor-salvage build fought the icon (iron
# fluke, shackle ring, barnacles) and is gone.
#   silhouette: a fat crooked stick
#   ornament : the split fork at the head, and the two broken nubs


def build_driftwoodclub():
    name = "DriftwoodClub"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    # The limb: one branch, kinked four times, THICKENING toward the head the
    # way the icon's does (this is what makes it read as a club and not a rod).
    spine = [
        Vector((0.00, 0.00, 0.04)),
        Vector((0.08, 0.01, 0.62)),
        Vector((0.03, 0.00, 1.26)),
        Vector((-0.07, -0.01, 1.92)),
        Vector((-0.03, 0.00, 2.52)),
        Vector((0.05, 0.01, 3.04)),
    ]
    radii = (0.155, 0.175, 0.19, 0.205, 0.225, 0.235)
    for i in range(len(spine) - 1):
        limb(p["Haft"], spine[i], spine[i + 1], radii[i], radii[i + 1], 6)
    for i, r in ((1, 0.20), (3, 0.225)):
        ellipsoid(p["Haft"], spine[i], (r, r * 0.9, r * 0.75), subdiv=0)
    # Long shallow bark ridges down the flats - the icon's grain lines.
    for x, y, z, h in ((0.21, 0.06, 1.50, 1.10), (-0.19, -0.07, 2.10, 0.90), (0.06, 0.21, 2.60, 0.70)):
        box(p["Haft"], (x, y, z), (0.07, 0.07, h), Matrix.Rotation(math.radians(6), 4, "Y"))

    # The binding on the hand point.
    melee_grip(p["Grip"], grip, half=0.5, r=0.21, coils=5, proud=0.03, sides=7)

    # The two snapped-off branch nubs - the only things standing off the limb.
    for (x, y, z), d, ln in (((0.18, 0.05, 1.72), (0.85, 0.30, 0.44), 0.30), ((-0.20, -0.05, 2.36), (-0.80, -0.25, 0.55), 0.24)):
        b, o = Vector((x, y, z)), Vector(d).normalized()
        limb(p["Spike"], b, b + o * ln, 0.085, 0.055, 5)

    # The head: the branch splits, the long prong carrying the frame's tip.
    fork = spine[-1]
    ellipsoid(p["Head"], fork, (0.21, 0.20, 0.15), subdiv=0)
    limb(p["Head"], fork, (0.13, 0.02, length - 0.02), 0.20, 0.060, 6)
    limb(p["Head"], fork, (-0.19, -0.02, 3.28), 0.16, 0.06, 5)

    return melee_finish(name, p)


# ---------------------------------------------------------------- Scaleblade (starter)
# ICON (assets/icons/scale_blade.png, canon): a BOWIE KNIFE, not a fish. Brown
# barrel handle with a rounded cap at the butt, a short pale steel crossguard
# whose spine-side quillon droops back over the hand, and a broad single-edged
# blade sweeping up into a clip point - with THREE saw notches filed into the
# spine just above the ricasso. That notch row is the signature; the 2026-08-27
# fish build (tail fan, gill plate, shingled scales, the eye) is gone.
#   silhouette: a bowie clip point
#   ornament : the three filed notches in the spine

# The blade outline, heel to point and back down the spine. Belly on +x, spine
# with its three notches on -x, point at z = LENGTH.
SCALEBLADE_PROFILE = [
    (-0.16, 1.30),  # heel, spine side
    (0.15, 1.30),  # heel, edge side
    (0.24, 1.60),
    (0.29, 2.06),
    (0.32, 2.48),  # the belly
    (0.28, 2.80),
    (0.15, 3.00),
    (0.01, 3.10),  # the point
    (-0.08, 2.96),  # the clip
    (-0.15, 2.70),
    (-0.19, 2.38),
    (-0.20, 2.24),  # three notches filed into the spine
    (-0.10, 2.16),
    (-0.21, 2.08),
    (-0.11, 2.00),
    (-0.22, 1.92),
    (-0.12, 1.84),
    (-0.20, 1.70),
    (-0.18, 1.46),
]


def build_scaleblade():
    name = "Scaleblade"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    # Wooden handle: a slight barrel, closed by a rounded cap at the butt.
    limb(p["Haft"], (0, 0, 0.20), (0, 0, 0.62), 0.155, 0.175, 7)
    limb(p["Haft"], (0, 0, 0.62), (0, 0, 1.10), 0.175, 0.150, 7)
    ellipsoid(p["Pommel"], (0, 0, 0.17), (0.19, 0.18, 0.17), subdiv=1)
    limb(p["Pommel"], (0, 0, 0.29), (0, 0, 0.35), 0.180, 0.172, 7)
    melee_grip(p["Grip"], grip, half=0.40, r=0.165, coils=3, proud=0.014, sides=7)

    # Steel crossguard, in the blade's plane: a short bar with rounded knobs,
    # the spine-side quillon drooping back over the hand and the edge-side one
    # swept up along the belly.
    box(p["Spike"], (0.0, 0, 1.20), (0.56, 0.20, 0.13))
    for s in (-1, 1):
        ellipsoid(p["Spike"], (s * 0.30, 0, 1.20), (0.11, 0.10, 0.10), subdiv=0)
    _wa_chain(p["Spike"], _wa_arc((-0.26, 0, 1.16), (-0.42, 0, 0.92), (-1, 0, 0), 0.08, 2), 0.075, 0.050, 5)
    _wa_chain(p["Spike"], _wa_arc((0.26, 0, 1.24), (0.40, 0, 1.50), (1, 0, 0), 0.06, 2), 0.070, 0.045, 5)

    # Ricasso, then the blade - thin on y so its edges ARE the +-x extremes.
    box(p["Edge"], (0.0, 0, 1.34), (0.24, 0.12, 0.22))
    slab(p["Edge"], SCALEBLADE_PROFILE, 0.055)

    # The icon's bevel highlight: a raised strip on both flats just inside the
    # belly, so the grind reads with the palette off.
    for s in (-1, 1):
        for x, z, h in ((0.17, 1.88, 0.48), (0.20, 2.42, 0.54), (0.15, 2.86, 0.36)):
            box(p["Spike"], (x, s * 0.052, z), (0.06, 0.02, h), Matrix.Rotation(math.radians(-6), 4, "Y"))

    return melee_finish(name, p)


# ---------------------------------------------------------------- Shellcrusher (barnacle maul)
# ICON (assets/icons/shellcrusher.png, canon): a STONE MAUL. A thin crooked
# natural branch for a haft, and a big blunt SLAB head - wider than it is tall,
# hung a little forward of the haft, its top and striking corner chewed into a
# rough pale crust, with two round studs set in the broad face. The 2026-08-27
# whelk build (a spiral coiled in the swing plane) is gone: the icon's head is
# a rectangle and reads as one at any distance.
#   silhouette: a brick on a stick
#   ornament : the chipped crust along the top, and the two face studs


def build_shellcrusher():
    name = "Shellcrusher"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    # Haft: one crooked, knotty branch - thin, so the head reads as heavy.
    spine = [
        Vector((0.00, 0.00, 0.05)),
        Vector((0.10, 0.02, 0.66)),
        Vector((0.02, 0.00, 1.34)),
        Vector((0.11, -0.02, 2.02)),
        Vector((0.03, 0.00, 2.62)),
    ]
    radii = (0.115, 0.130, 0.125, 0.135, 0.140)
    for i in range(len(spine) - 1):
        limb(p["Haft"], spine[i], spine[i + 1], radii[i], radii[i + 1], 6)
    for i in (1, 3):
        ellipsoid(p["Haft"], spine[i], (0.155, 0.14, 0.12), subdiv=0)
    for (x, y, z), d in (((0.12, 0.04, 1.66), (0.8, 0.4, 0.45)), ((-0.02, -0.05, 1.10), (-0.7, -0.4, 0.6))):
        b, o = Vector((x, y, z)), Vector(d).normalized()
        limb(p["Haft"], b, b + o * 0.22, 0.06, 0.04, 5)
    melee_grip(p["Grip"], grip, half=0.55, r=0.185, coils=5, proud=0.026, sides=7)

    # Lashings where the head is bound on.
    for z, r in ((2.50, 0.160), (2.66, 0.165)):
        coil_band(p["Guard"], z, r, tilt=0.05, thick=0.05, sides=6)

    # The head: one slab of sea stone, canted forward so the +x corner leads.
    tilt = Matrix.Rotation(math.radians(-9), 4, "Y")
    box(p["Head"], (0.10, 0, 2.98), (1.34, 0.66, 0.84), tilt)
    # a second, shallower plate on the striking face so the block is not a cube
    box(p["Head"], (0.68, 0, 2.94), (0.22, 0.56, 0.66), tilt)

    # The crust: chipped rough blocks riding the top of the slab, the tallest
    # of them carrying the frame's tip.
    for i, (x, y, z) in enumerate(((-0.42, 0.00, 3.34), (-0.12, 0.14, 3.44), (0.20, -0.12, 3.44), (0.50, 0.05, 3.32))):
        box(p["Spike"], (x, y, z), (0.32, 0.50, 0.16), Matrix.Rotation(math.radians(-9 + (i % 2) * 12), 4, "Y"))
    box(p["Spike"], (0.04, 0, 3.47), (0.30, 0.34, 0.20), Matrix.Rotation(math.radians(-6), 4, "Y"))

    # The two studs set in the broad face, both flats.
    for s in (-1, 1):
        for z in (2.84, 3.14):
            limb(p["Spike"], (0.40, s * 0.31, z), (0.40, s * 0.40, z), 0.10, 0.085, 6)

    return melee_finish(name, p)


# ---------------------------------------------------------------- Heartrender (brineheart blade)
# ICON (assets/icons/heartrender.png, canon): a straight, double-edged RED
# SWORD. Dark maroon grip, an arrowhead pommel pointing back off the butt, a
# long lozenge blade with a fuller down the middle - and a guard that is not a
# bar at all but a CLUSTER OF ROUND LOBES, a red quatrefoil knotted round the
# socket. That lobed guard is the icon's signature, so it is the weapon's: it
# is Brinejaw's heart, and the beat now lives at its centre instead of hanging
# in a hole through the blade (the 2026-08-27 split-rib cage is gone).
#   silhouette: a straight cruciform sword with a knot for a guard
#   ornament : the lobed heart-guard, lit at its core

# The lobes of the heart-guard: (x, z, radius) in the blade's plane.
HEARTRENDER_LOBES = ((-0.36, 1.46, 0.24), (0.36, 1.46, 0.24), (0.00, 1.24, 0.22), (-0.20, 1.70, 0.15), (0.20, 1.70, 0.15))


def build_heartrender():
    name = "Heartrender"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    # Dark heartwood grip, and the arrowhead pommel off the butt.
    limb(p["Haft"], (0, 0, 0.30), (0, 0, 1.28), 0.140, 0.130, 7)
    cone(p["Spike"], (0, 0, 0.36), (0, 0, 0.01), 0.215, sides=4)
    limb(p["Spike"], (0, 0, 0.36), (0, 0, 0.42), 0.185, 0.165, 7)
    melee_grip(p["Grip"], grip, half=0.42, r=0.175, coils=4, proud=0.022, sides=7)

    # The guard: five lobes knotted round the socket, flat on y so the cluster
    # reads as one rounded knot from the swing side.
    box(p["Edge"], (0, 0, 1.46), (0.50, 0.22, 0.46))
    for x, z, r in HEARTRENDER_LOBES:
        ellipsoid(p["Edge"], (x, 0, z), (r, r * 0.46, r), subdiv=1)
    limb(p["Edge"], (0, 0, 1.68), (0, 0, 1.82), 0.19, 0.165, 7)

    # The blade: a long double-edged lozenge with near-parallel edges, tapering
    # in width AND thickness only over the last third, its edges the +-x
    # extremes and its flats on +-y.
    lofted_blade(
        p["Edge"],
        [
            (0, 1.76, 0.140, 0.070),
            (0, 1.98, 0.178, 0.078),
            (0, 3.00, 0.172, 0.062),
            (0, 3.44, 0.145, 0.048),
            (0, 3.74, 0.085, 0.028),
            (0, length, 0.012, 0.005),
        ],
    )

    # The beat: the heart's core lit at the centre of the guard knot, a bead in
    # each of the two big lobes, and the fuller burning down both flats.
    ellipsoid(p["Glow"], (0, 0, 1.46), (0.19, 0.16, 0.19), subdiv=1)
    for s in (-1, 1):
        ellipsoid(p["Glow"], (s * 0.36, 0, 1.46), (0.10, 0.12, 0.10), subdiv=0)
        box(p["Glow"], (0, s * 0.056, 2.50), (0.050, 0.026, 1.20))

    return melee_finish(name, p)


# ---------------------------------------------------------------- Drowncleaver (cursed-bone cleaver)
# ICON (assets/icons/drowncleaver.png, canon): a plain butcher's CLEAVER in
# pale sage bone. Straight cutting edge on one side, DEAD STRAIGHT spine on the
# other - no tooth row, no jaw, no trophy fang; the 2026-08-27 mandible build
# put a scalloped fang row down the spine and the icon has none. What the icon
# does have: a rounded ridged bone handle, a stepped notch where the spine runs
# out at the tip, a hanging hole punched through the top corner, and a line of
# pale glowing runes struck across the flat.
#   silhouette: a tall rectangular cleaver
#   ornament : the punched hole, and the rune line burning across the flat

# Each glyph: (x, z) on the blade flat, then strokes of (dx, dz, length, angle).
DROWNCLEAVER_GLYPHS = [
    (-0.02, 2.34, [(-0.09, 0.0, 0.34, 90), (0.09, 0.0, 0.34, 90), (0.0, 0.0, 0.20, 0)]),
    (0.16, 2.88, [(-0.08, 0.0, 0.30, 90), (0.0, 0.14, 0.20, 0), (0.0, -0.14, 0.20, 0)]),
    (0.04, 3.34, [(-0.07, 0.0, 0.32, 74), (0.07, 0.0, 0.32, -74)]),
]


def build_drowncleaver():
    name = "Drowncleaver"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    # Bone handle: a rounded shaft with the icon's ridge bands cut into it and
    # a swollen knob closing the butt.
    limb(p["Haft"], (0, 0, 0.16), (0, 0, 1.52), 0.135, 0.145, 7)
    ellipsoid(p["Haft"], (0, 0, 0.17), (0.185, 0.175, 0.16), subdiv=1)
    for z in (0.42, 0.60, 0.78, 0.96):
        limb(p["Spike"], (0, 0, z - 0.035), (0, 0, z + 0.035), 0.16, 0.16, 7)
    melee_grip(p["Grip"], grip, half=0.42, r=0.150, coils=3, proud=0.014, sides=7)

    # Bolster: the step where the bone stops being a handle.
    box(p["Guard"], (0.06, 0, 1.58), (0.44, 0.28, 0.20))

    # The blade. Cutting edge on +x, spine on -x and STRAIGHT, the front-top
    # corner rounded off and the spine running out in a step below the tip.
    profile = [
        (-0.34, 1.68),  # heel, spine side
        (0.50, 1.66),  # heel, edge side
        (0.56, 2.30),
        (0.58, 3.20),
        (0.57, 3.52),  # edge, upper
        (0.50, 3.64),  # the rounded front-top corner
        (0.34, length),
        (-0.22, 3.68),  # the flat top
        (-0.32, 3.56),  # the step where the spine runs out
        (-0.36, 3.40),
        (-0.36, 2.40),  # the straight spine
    ]
    _wa_pierce(p["Edge"], profile, (-0.14, 3.42), 0.085, 0.085)

    # Runes struck across the flat, burning on both faces.
    for gx, gz, glyph in DROWNCLEAVER_GLYPHS:
        for dx, dz, stroke_len, angle in glyph:
            for side in (-1, 1):
                stroke(p["Glow"], (gx + dx, side * 0.10, gz + dz), stroke_len, angle)

    return melee_finish(name, p)


# ================================================================ MELEE REBUILD (islands 3-7)
# The fifteen crafted melee weapons - the two volcano pieces here and the
# thirteen from island 3 on - are authored one at a time. They used to come out
# of two parameterised families (a "blade" knob set and a "hafted" one) and
# every island read as a recolour of the last; the rule now is that each
# silhouette has to name its weapon with the palette turned off.
#
# These are the shared moves the fifteen lean on. On top of the pack contract
# at the top of the file:
#   +x  THE CUTTING SIDE. Checked against the cove blades: the Scaleblade's
#       leaf spans x = +-0.37 while slab() gives it only y = +-0.05, so its
#       edges ARE the +-x extremes and its flats face +-y; the single-edged
#       Drowncleaver puts its spine at -x and its cutting edge at +x. So every
#       edge, bit, hook and lit strip below faces +x, spines / picks / polls
#       face -x, and flats, fullers and filigree lie on +-y.
#   _Grip stays a plain SYMMETRIC sleeve centred on the hand point - charms,
#       tassels and lanyards live in another part, because the grip object's
#       centre is the hand point the viewmodel hangs off.

MELEE_SUFFIXES = ("Haft", "Grip", "Guard", "Head", "Edge", "Spike", "Pommel", "Glow")

# Flattened hexagonal cross-section (x, y) for lofted_blade(): wide on x (the
# edges), thin on y (the flats).
BLADE_SECTION = ((1.0, 0.0), (0.5, 1.0), (-0.5, 1.0), (-1.0, 0.0), (-0.5, -1.0), (0.5, -1.0))


def melee_bms():
    """One bmesh per melee part suffix; the unused ones stay empty and
    finish() drops them."""
    return {s: bmesh.new() for s in MELEE_SUFFIXES}


def melee_finish(name, p):
    return [finish(f"{name}_{s}", p[s]) for s in MELEE_SUFFIXES]


def melee_grip(bm, grip, half=0.45, r=0.14, coils=4, proud=0.025, sides=6):
    """The bound hand section: a core sleeve with cord coils standing proud of
    it. Symmetric about z = grip, so the object's centre is the hand point."""
    limb(bm, (0, 0, max(0.02, grip - half)), (0, 0, grip + half), r, r, sides)
    step = 2 * half / coils
    for i in range(coils):
        z = grip - half + (i + 0.5) * step
        limb(bm, (0, 0, z - step * 0.2), (0, 0, z + step * 0.2), r + proud, r + proud, sides)


def edge_profile(z0, z1, spine, edge, steps=8):
    """An (x, z) silhouette for slab(): the cutting edge runs x = edge(t) up
    the +x side and the spine x = spine(t) back down the -x side, t = 0 at the
    heel (z0) and t = 1 at the point (z1, the last edge sample)."""

    def z(t):
        return z0 + (z1 - z0) * t

    ts = [i / steps for i in range(steps + 1)]
    return [(edge(t), z(t)) for t in ts] + [(spine(t), z(t)) for t in reversed(ts[:-1])]


def lofted_blade(bm, stations):
    """Loft a blade through `stations` = [(x, z, half_width, half_thick)], each
    a flattened hexagonal ring - so it tapers in width AND in thickness, the
    way a tooth does. A constant-thickness slab() reads as cardboard at fang
    scale. Keep the last station tiny: that ring is the point."""
    rings = [[bm.verts.new(Vector((x + w * cx, t * cy, z))) for cx, cy in BLADE_SECTION] for x, z, w, t in stations]
    n = len(BLADE_SECTION)
    for a, b in zip(rings, rings[1:]):
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((a[i], a[j], b[j], b[i]))
    bm.faces.new(list(reversed(rings[0])))
    bm.faces.new(rings[-1])


def knapped_point(bm, z0, z1, r0, r1, segs=6, twist=44.0, flat=0.55):
    """A flaked stone point: triangular rings stacked up z, each twisted
    against the last so the flanks break into conchoidal facets, closing on an
    apex at z1. `flat` squashes the section on y - a struck blade, not a rod."""
    zt = z0 + (z1 - z0) * 0.9
    rings = []
    for i in range(segs + 1):
        t = i / segs
        a0 = math.radians(twist) * i
        r = r0 + (r1 - r0) * t
        rings.append([bm.verts.new(Vector((math.cos(a0 + k * TAU / 3) * r, math.sin(a0 + k * TAU / 3) * r * flat, z0 + (zt - z0) * t))) for k in range(3)])
    for a, b in zip(rings, rings[1:]):
        for i in range(3):
            j = (i + 1) % 3
            bm.faces.new((a[i], a[j], b[j], b[i]))
    bm.faces.new(list(reversed(rings[0])))
    apex = bm.verts.new(Vector((0, 0, z1)))
    top = rings[-1]
    for i in range(3):
        bm.faces.new((top[i], top[(i + 1) % 3], apex))


def coil_band(bm, z, r, tilt=0.06, thick=0.045, sides=5):
    """One turn of wire wound round a shaft: a short band slanted across it."""
    limb(bm, (tilt, 0, z - thick), (-tilt, 0, z + thick), r, r, sides)


def barnacle(bm, center, out, r=0.11):
    """A truncated cone crusting a surface - one barnacle."""
    c, o = Vector(center), Vector(out).normalized()
    limb(bm, c, c + o * (r * 1.6), r, r * 0.45, 5)


# ---------------------------------------------------------------- Obsidian Piercer (volcano rare)
# ICON (assets/icons/obsidian_piercer.png, canon): ONE PIECE OF GLASS, end to
# end - no wood, no brass, no crown of floating flakes (all of which the
# 2026-08-27 build had). A long faceted charcoal lance: a blunt tapered butt,
# a pinched neck carrying a small closed loop off the spine side and a stubby
# lug off the edge side, then a very long flat blade running out to a chisel
# point - with a lit orange CRACK crossing the blade in an X.
#   silhouette: one long dark lance with a loop at its waist
#   ornament : the X of heat burning across the flat


def build_obsidianpiercer():
    name = "ObsidianPiercer"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    # The butt end: the same glass, knapped down to a five-sided grip that
    # tapers to a blunt heel.
    limb(p["Haft"], (0, 0, 0.03), (0, 0, 0.36), 0.105, 0.155, 5)
    limb(p["Haft"], (0, 0, 0.36), (0, 0, 0.98), 0.155, 0.180, 5)
    limb(p["Haft"], (0, 0, 0.98), (0, 0, 1.42), 0.180, 0.150, 5)
    melee_grip(p["Grip"], grip, half=0.36, r=0.170, coils=2, proud=0.012, sides=5)

    # The neck: a pinch, the loop hung off the spine side, one lug off the edge.
    limb(p["Guard"], (0, 0, 1.42), (0, 0, 1.62), 0.150, 0.115, 5)
    _wa_ring(p["Guard"], (-0.19, 0, 1.53), 0.145, 0.042, normal=(0, 1, 0), seg=7)
    box(p["Guard"], (0.17, 0, 1.60), (0.22, 0.14, 0.12), Matrix.Rotation(math.radians(-28), 4, "Y"))

    # The blade: a long flat lance, edges the +-x extremes, flats on +-y.
    lofted_blade(
        p["Edge"],
        [
            (0, 1.58, 0.130, 0.090),
            (0, 1.86, 0.250, 0.115),
            (0, 2.30, 0.275, 0.108),
            (0, 2.80, 0.250, 0.086),
            (0, 3.16, 0.190, 0.060),
            (0, 3.40, 0.105, 0.034),
            (0, length, 0.018, 0.008),
        ],
    )
    # The chisel bevel the icon cuts across the last hand's width of the point.
    _wa_shard(p["Spike"], (0.02, 0, 3.16), (0.16, 0.0, 1.0), 0.32, 0.10, flat=0.42, phase=0.4)

    # The crack: an X struck across the flat, burning on both faces, with one
    # short stray branch off it.
    for s in (-1, 1):
        y = s * 0.105
        stroke(p["Glow"], (0.01, y, 2.42), 0.66, 62, thickness=0.05, width=0.10)
        stroke(p["Glow"], (0.01, y, 2.42), 0.58, -54, thickness=0.05, width=0.10)
        stroke(p["Glow"], (0.12, y, 2.02), 0.26, 70, thickness=0.05, width=0.08)

    return melee_finish(name, p)


# ---------------------------------------------------------------- Magma Gauntlets (volcano epic)
# ICON (assets/icons/magma_gauntlets.png, canon): a clawed gauntlet WORN on the
# hand - a dark plated glove closed into a fist, a lit cuff round the wrist, a
# magma crack forking down the back of the hand, gold knuckle bands, and four
# heavy golden claws standing off the knuckles. Not a vambrace on a pole (the
# 2026-08-27 build was a forearm with fumaroles for knuckles).
#
# AUTHORING CONTRACT (agreed with the hold-animation lane, which pitches this
# one near-horizontal so authored +Z is camera-forward):
#   - butt (z = 0) is the ELBOW end; the cuff runs forward from there.
#   - the closed fist's PALM CENTRE sits exactly on z = GRIP, and the shell is
#     hollow enough for the block arm's fist to sit inside it.
#   - the claws RAKE ALONG +Z, never sideways, and reach z = LENGTH.
#   - knuckles and claws face +X (the pack's blade-edge side); everything else
#     is kept roughly radially symmetric about the length axis, so the piece
#     survives any WEAPON_ROLL about its own axis.
#   silhouette: a fist with four claws raked forward off it
#   ornament : the magma crack forking down the back of the hand

# Each claw: (y across the knuckles, tip z, tip x). All rake +Z, all bow +X.
MAGMA_CLAWS = ((-0.30, 2.86, 0.34), (-0.10, 3.20, 0.44), (0.10, 3.12, 0.44), (0.30, 2.70, 0.30))


def build_magmagauntlets():
    name = "MagmaGauntlets"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    # The forearm cuff: elbow rim at z = 0, tapering forward into the wrist.
    limb(p["Guard"], (0, 0, 0.00), (0, 0, 0.08), 0.375, 0.355, 8)
    limb(p["Haft"], (0, 0, 0.06), (0, 0, 0.26), 0.345, 0.310, 8)
    limb(p["Haft"], (0, 0, 0.26), (0, 0, 0.34), 0.310, 0.265, 8)
    # cuff plates, spaced round the axis so the cuff stays radially even
    for i in range(4):
        a = i * TAU / 4 + math.pi / 4
        o = Vector((math.cos(a), math.sin(a), 0.0))
        box(p["Guard"], tuple(o * 0.30 + Vector((0, 0, 0.17))), (0.14, 0.14, 0.22), Matrix.Rotation(a, 4, "Z"))

    # THE FIST. The palm centre is z = GRIP: a rounded shell big enough for the
    # block arm's fist, with the wrapped fingers inside it as _Grip.
    ellipsoid(p["Haft"], (0.02, 0, grip), (0.36, 0.35, 0.37), subdiv=1)
    box(p["Haft"], (0.02, 0, grip), (0.60, 0.62, 0.60))
    melee_grip(p["Grip"], grip, half=0.26, r=0.29, coils=3, proud=0.024, sides=7)
    # back-of-hand plate, on the knuckle side
    box(p["Guard"], (0.30, 0, grip + 0.04), (0.16, 0.56, 0.56), Matrix.Rotation(math.radians(-6), 4, "Y"))

    # The knuckle bands: four gold plates across the front of the fist, the
    # roots the claws grow out of.
    for y, _reach, _out in MAGMA_CLAWS:
        box(p["Edge"], (0.20, y, grip + 0.36), (0.34, 0.14, 0.26), Matrix.Rotation(math.radians(-20), 4, "Y"))

    # THE CLAWS. Each one leaves its knuckle band raked along +Z and bows out
    # to +X, so from the camera (which sees +Z) they read as four talons
    # thrown forward, and the longest lands exactly on z = LENGTH.
    for y, reach, out in MAGMA_CLAWS:
        z0 = grip + 0.44
        pts = []
        for t in (0.0, 0.34, 0.68, 1.0):
            z = z0 + (reach - 0.16 - z0) * t
            pts.append(Vector((0.22 + (out - 0.22) * t**1.7, y * (1.0 + 0.22 * t), z)))
        for a, b, r0, r1 in zip(pts, pts[1:], (0.180, 0.140, 0.098), (0.140, 0.098, 0.062)):
            limb(p["Edge"], a, b, r0, r1, 5)
        cone(p["Spike"], pts[-1], (out + 0.05, y * 1.26, reach), 0.062, sides=4)

    # Magma: the lit cuff rim, a ring at the wrist, the crack forking down the
    # back of the hand, and a bead at every claw root.
    limb(p["Glow"], (0, 0, 0.095), (0, 0, 0.145), 0.352, 0.345, 8)
    limb(p["Glow"], (0, 0, 0.325), (0, 0, 0.360), 0.272, 0.268, 8)
    for x, z, ln, ang in ((0.34, grip + 0.06, 0.40, 78), (0.36, grip - 0.20, 0.26, 46), (0.36, grip - 0.20, 0.26, -46)):
        stroke(p["Glow"], (x, 0, z), ln, ang, thickness=0.09, width=0.09)
    for y, _reach, _out in MAGMA_CLAWS:
        ellipsoid(p["Glow"], (0.30, y, grip + 0.46), (0.07, 0.07, 0.07), subdiv=0)

    return melee_finish(name, p)


# ---------------------------------------------------------------- Rustfang Machete (swamp rare)
# ICON (assets/icons/rustfang_machete.png, canon): a plain brown MACHETE. Short
# ringed handle with a flared butt and a small bolster, no guard, no gator; the
# blade widens from a narrow ricasso, its cutting edge one long convex sweep to
# a clipped point - and a SAW SECTION of four teeth is cut into the SPINE at
# mid-blade. That saw is the icon's one feature, so it is the weapon's; the
# 2026-08-27 gator-jaw build (hinged lower jaw, scutes, eye, fishhook) is gone.
#   silhouette: a broad machete with a bite taken out of its back
#   ornament : the four-tooth saw filed into the spine


def build_rustfangmachete():
    name = "RustfangMachete"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    # Handle: a short ringed grip, flared at the butt, with a bolster on top.
    limb(p["Haft"], (0, 0, 0.14), (0, 0, 1.08), 0.130, 0.115, 7)
    limb(p["Pommel"], (0, 0, 0.06), (0, 0, 0.22), 0.165, 0.150, 7)
    melee_grip(p["Grip"], grip, half=0.38, r=0.140, coils=4, proud=0.020, sides=7)
    limb(p["Guard"], (0, 0, 1.06), (0, 0, 1.20), 0.155, 0.135, 7)

    # The blade: edge on +x in one convex sweep to a clipped point, spine on -x
    # straight but for the saw teeth filed into its middle.
    slab(
        p["Edge"],
        [
            (-0.17, 1.18),  # heel, spine side
            (0.15, 1.18),  # heel, edge side
            (0.22, 1.46),
            (0.27, 1.92),
            (0.30, 2.40),
            (0.29, 2.90),
            (0.23, 3.14),
            (0.05, length),  # the clipped point
            (-0.09, 3.16),
            (-0.17, 2.96),
            (-0.19, 2.72),
            (-0.20, 2.60),  # the saw: four teeth into the spine
            (-0.09, 2.52),
            (-0.21, 2.44),
            (-0.10, 2.36),
            (-0.22, 2.28),
            (-0.11, 2.20),
            (-0.23, 2.12),
            (-0.21, 1.80),  # spine, straight again
        ],
        0.055,
    )
    # The icon's grind line: a shallow raised strip on both flats, running
    # parallel to the edge from the ricasso to the clip.
    for s in (-1, 1):
        for x, z, h in ((0.13, 1.74, 0.58), (0.17, 2.38, 0.64), (0.15, 2.94, 0.40)):
            box(p["Spike"], (x, s * 0.052, z), (0.06, 0.02, h), Matrix.Rotation(math.radians(-4), 4, "Y"))

    return melee_finish(name, p)


# ---------------------------------------------------------------- Fenreaver (swamp legendary)
# ICON (assets/icons/fenreaver.png, canon): a gnarled dark ROOT for a haft -
# knobbed, bark-ridged, closed by a bulb at the butt - carrying a big pale
# silver-green FLAME BLADE. The blade's base throws a long rear-swept wing out
# behind it on the spine side and a short forward hook on the edge side; between
# them the blade pinches to a waist, then swells into a broad belly and runs out
# to a fine point, with a small eye pierced through the low blade. The
# 2026-08-27 build's caged wisp and trophy-tooth row are not in the icon and
# are gone; the winged base is the signature now.
#   silhouette: a winged flame blade on a root
#   ornament : the rear-swept wing, and the eye pierced under the waist

# The blade outline, heel round to the wing. Belly on +x, wing and spine on -x.
FENREAVER_PROFILE = [
    (-0.12, 1.98),  # heel, spine side
    (0.12, 1.98),  # heel, edge side
    (0.42, 2.10),  # the forward hook
    (0.30, 2.26),
    (0.22, 2.50),  # the waist
    (0.36, 2.86),
    (0.41, 3.16),  # the belly
    (0.33, 3.46),
    (0.17, 3.66),
    (0.02, 3.80),  # the point
    (-0.05, 3.60),
    (-0.13, 3.16),
    (-0.19, 2.76),
    (-0.24, 2.46),  # the wing's shoulder
    (-0.48, 2.06),  # the rear-swept wing tip
    (-0.24, 2.16),  # the notch behind the wing
]


def build_fenreaver():
    name = "Fenreaver"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    # The root: kinked, knotted, bark-ridged, with a bulb closing the butt.
    spine = [
        Vector((0.00, 0.00, 0.20)),
        Vector((0.09, 0.02, 0.66)),
        Vector((0.01, -0.01, 1.14)),
        Vector((0.08, 0.01, 1.58)),
        Vector((0.00, 0.00, 1.96)),
    ]
    radii = (0.130, 0.140, 0.128, 0.138, 0.150)
    for i in range(len(spine) - 1):
        limb(p["Haft"], spine[i], spine[i + 1], radii[i], radii[i + 1], 6)
    for i in (1, 3):
        ellipsoid(p["Haft"], spine[i], (0.165, 0.15, 0.125), subdiv=0)
    for turns, phase in ((1.1, 0.0), (-1.1, math.pi)):
        _wa_chain(p["Haft"], _wa_helix(0.34, 1.86, turns, lambda t: 0.145 - 0.012 * t, phase=phase, per_turn=3), 0.042, 0.030, 4)
    ellipsoid(p["Pommel"], (0, 0, 0.17), (0.20, 0.19, 0.16), subdiv=1)
    melee_grip(p["Grip"], grip, half=0.46, r=0.155, coils=4, proud=0.022, sides=7)

    # The socket the blade sits in - a short bark collar, nothing more.
    limb(p["Guard"], (0, 0, 1.84), (0, 0, 2.02), 0.185, 0.165, 7)

    # The blade, thin on y so the wing and belly ARE the +-x extremes, with the
    # icon's small eye pierced through it just under the waist.
    _wa_pierce(p["Edge"], FENREAVER_PROFILE, (0.02, 2.32), 0.070, 0.060)

    # Sap: a lit line just inside the belly, and a bead in the eye.
    for x, z, h in ((0.25, 2.76, 0.40), (0.31, 3.12, 0.50), (0.22, 3.46, 0.32)):
        for s in (-1, 1):
            box(p["Glow"], (x, s * 0.056, z), (0.06, 0.024, h), Matrix.Rotation(math.radians(-8), 4, "Y"))
    _wa_ring(p["Glow"], (0.02, 0, 2.32), 0.085, 0.026, normal=(0, 1, 0), seg=7)

    return melee_finish(name, p)


# ================================================================ LATE-ISLAND MELEE (_wb_*)
# The eleven melee weapons of Frostmaw / Gloomtrench / the Wrack fleet / the
# Maelstrom, rebuilt to the ROD pack's standard: each one carries a single
# only-it-has ornament that owns the silhouette, and the rest of the weapon
# exists to explain that ornament.
#
# The _wb_* helpers below serve ONLY those eleven. They are the melee answer to
# rod_gen's _fim_* / _gloom_* sets - swept tubes, parallel-transported frames,
# lenticular slabs, faceted crystal shards - because the axe/box/cone kit above
# can only ever produce sticks with wedges on them. Nothing outside this region
# calls them.


def _wb_frames(points):
    """Parallel-transported (u, v) cross-section frames along a polyline. A
    per-point frame_for() flips when a curve swings through vertical - which
    the kraken coil, the aurora ribbon and the anchor arm all do."""
    n = len(points)
    tangents = []
    for i in range(n):
        if i == 0:
            d = points[1] - points[0]
        elif i == n - 1:
            d = points[-1] - points[-2]
        else:
            d = points[i + 1] - points[i - 1]
        tangents.append(d.normalized())
    u = Vector((0.0, 1.0, 0.0)) - tangents[0] * tangents[0].y
    if u.length < 1e-5:
        u = Vector((1.0, 0.0, 0.0)) - tangents[0] * tangents[0].x
    u.normalize()
    frames = []
    for t in tangents:
        u = u - t * u.dot(t)
        if u.length < 1e-5:
            u = t.cross(Vector((0.0, 0.0, 1.0)))
        u.normalize()
        frames.append((u.copy(), t.cross(u).normalized()))
    return frames


def _wb_sweep(bm, points, radii, sides=5, flat=1.0, phase=0.0, cap=True):
    """Sweep a polygonal tube along `points` with a radius per point. The one
    workhorse: ropes, tentacles, cage ribs, anchor arms, lure stalks."""
    pts = [Vector(p) for p in points]
    frames = _wb_frames(pts)
    rings = [[bm.verts.new(p + u * (math.cos(a) * r) + v * (math.sin(a) * r * flat)) for a in ((i / sides) * TAU + phase for i in range(sides))] for p, r, (u, v) in zip(pts, radii, frames)]
    for a, b in zip(rings, rings[1:]):
        for i in range(sides):
            j = (i + 1) % sides
            bm.faces.new((a[i], a[j], b[j], b[i]))
    if cap:
        bm.faces.new(list(reversed(rings[0])))
        bm.faces.new(rings[-1])
    return rings


def _wb_arc(a, b, bow_dir, bow, steps=5):
    """steps + 1 points bowing from a to b, pushed `bow` along bow_dir at the
    middle - the curve every swept part here rides."""
    a, b = Vector(a), Vector(b)
    d = Vector(bow_dir)
    d = d.normalized() if d.length > 1e-6 else Vector((0.0, 0.0, 0.0))
    return [a + (b - a) * (i / steps) + d * (bow * math.sin((i / steps) * math.pi)) for i in range(steps + 1)]


def _wb_helix(z0, z1, turns, r_fn, phase=0.0, per_turn=7, drift=None):
    """Points on a helix climbing z0 -> z1, radius r_fn(t) about an axis that
    may itself wander in x/y via drift(t) - so a coil can follow a blade that
    curves away underneath it."""
    n = max(2, int(round(abs(turns) * per_turn)))
    pts = []
    for i in range(n + 1):
        t = i / n
        a = phase + turns * TAU * t
        r = r_fn(t)
        cx, cy = drift(t) if drift else (0.0, 0.0)
        pts.append(Vector((cx + math.cos(a) * r, cy + math.sin(a) * r, z0 + (z1 - z0) * t)))
    return pts


def _wb_ribbon(bm, points, half_widths, thick, twist=0.0):
    """A flat band swept along `points`, optionally rolling `twist` degrees end
    to end - the aurora off the lance, the flag tails off the saber."""
    pts = [Vector(p) for p in points]
    frames = _wb_frames(pts)
    n = len(pts)
    rows = []
    for i, (p, w, (u, v)) in enumerate(zip(pts, half_widths, frames)):
        a = math.radians(twist) * (i / max(1, n - 1))
        uu = u * math.cos(a) + v * math.sin(a)
        vv = -u * math.sin(a) + v * math.cos(a)
        rows.append([bm.verts.new(p + uu * w + vv * thick), bm.verts.new(p - uu * w + vv * thick), bm.verts.new(p - uu * w - vv * thick), bm.verts.new(p + uu * w - vv * thick)])
    for a_, b_ in zip(rows, rows[1:]):
        for i in range(4):
            j = (i + 1) % 4
            bm.faces.new((a_[i], a_[j], b_[j], b_[i]))
    bm.faces.new(list(reversed(rows[0])))
    bm.faces.new(rows[-1])


def _wb_slab_varied(bm, profile, thicks):
    """slab(), but every profile vertex carries its OWN half-thickness on y, so
    a blade is a real lens - a wedge along the spine vanishing to a wafer at the
    cutting edge and the point. A constant-thickness slab reads as cardboard the
    moment the light moves; this is why the cove blades look forged and the old
    late-island ones didn't. Keep every thickness >= ~0.006 so no face is
    exactly degenerate."""
    front = [bm.verts.new(Vector((x, -max(0.006, t), z))) for (x, z), t in zip(profile, thicks)]
    back = [bm.verts.new(Vector((x, max(0.006, t), z))) for (x, z), t in zip(profile, thicks)]
    n = len(profile)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((front[i], front[j], back[j], back[i]))
    bm.faces.new(list(reversed(front)))
    bm.faces.new(back)


def _wb_lens_thicks(steps, edge=0.016, tip=0.008, spine_root=0.070, spine_tip=0.030):
    """Half-thicknesses matching an edge_profile(steps=steps) outline vertex for
    vertex: its first steps + 1 entries are the cutting edge (a wafer, thinner
    still at the point), the remaining steps are the spine walking back down
    from the point to the heel (a wedge, fattest at the heel)."""
    e = [edge - (edge - tip) * (i / steps) for i in range(steps + 1)]
    s = [spine_tip + (spine_root - spine_tip) * (i / max(1, steps - 1)) for i in range(steps)]
    return e + s


def _wb_shard(bm, base, tip, r, sides=4, waist=0.45, bulge=1.0, phase=0.0):
    """A struck crystal: a base ring, a bulge ring half-twisted against it so
    the flanks break into facets, and an apex. Every piece of ice and voidglass
    in these eleven is one of these."""
    base, tip = Vector(base), Vector(tip)
    d = tip - base
    ln = d.length
    if ln < 1e-6:
        return
    d = d / ln
    up = Vector((0, 0, 1)) if abs(d.z) < 0.9 else Vector((1, 0, 0))
    u = d.cross(up).normalized()
    v = d.cross(u).normalized()

    def ring(off, rr, ph):
        c = base + d * off
        return [bm.verts.new(c + (u * math.cos(a) + v * math.sin(a)) * rr) for a in ((i / sides) * TAU + ph for i in range(sides))]

    a0 = ring(0.0, r, phase)
    a1 = ring(ln * waist, r * bulge, phase + TAU / (2 * sides))
    for i in range(sides):
        j = (i + 1) % sides
        bm.faces.new((a0[i], a0[j], a1[j], a1[i]))
    apex = bm.verts.new(tip)
    for i in range(sides):
        bm.faces.new((a1[i], a1[(i + 1) % sides], apex))
    bm.faces.new(list(reversed(a0)))


def _wb_ring(bm, center, axis, radius, tube, seg_major=7, seg_minor=3, phase=0.0):
    """A torus - a shackle ring, a lashing, a hoop of a cage, the halo round a
    storm pearl. seg_minor = 3 keeps it cheap and reads fine flat-shaded."""
    c = Vector(center)
    nrm = Vector(axis).normalized()
    up = Vector((0, 0, 1)) if abs(nrm.z) < 0.9 else Vector((1, 0, 0))
    u = nrm.cross(up).normalized()
    v = nrm.cross(u).normalized()
    rings = []
    for i in range(seg_major):
        a = (i / seg_major) * TAU + phase
        out = u * math.cos(a) + v * math.sin(a)
        cc = c + out * radius
        rings.append([bm.verts.new(cc + out * (math.cos(b) * tube) + nrm * (math.sin(b) * tube)) for b in ((k / seg_minor) * TAU for k in range(seg_minor))])
    for i in range(seg_major):
        a_, b_ = rings[i], rings[(i + 1) % seg_major]
        for k in range(seg_minor):
            l = (k + 1) % seg_minor
            bm.faces.new((a_[k], a_[l], b_[l], b_[k]))


def _wb_arc2(a, b, bow_dir, bow, steps=4):
    """_wb_arc's flat twin: steps + 1 (x, z) points bowing from a to b. Every
    axe bit, crescent and horn below is cut from two or three of these, because
    an icon's axe head is a pair of arcs meeting at a horn and nothing else."""
    (ax, az), (bx, bz) = a, b
    dx, dz = bow_dir
    n = math.hypot(dx, dz) or 1.0
    dx, dz = dx / n, dz / n
    out = []
    for i in range(steps + 1):
        t = i / steps
        s = bow * math.sin(t * math.pi)
        out.append((ax + (bx - ax) * t + dx * s, az + (bz - az) * t + dz * s))
    return out


def _wb_hub_thicks(profile, hub, near=0.095, far=0.014, power=1.0):
    """A half-thickness per profile vertex for _wb_slab_varied: fat at `hub`
    (the eye, the socket) and a wafer out at the rim. _wb_lens_thicks grinds a
    SWORD - edge on one side, spine on the other; this grinds an AXE, which is
    thick at the eye and thin in every direction away from it."""
    hx, hz = hub
    d = [math.hypot(x - hx, z - hz) for x, z in profile]
    lo, hi = min(d), max(d)
    span = max(1e-6, hi - lo)
    return [near + (far - near) * (((v - lo) / span) ** power) for v in d]


def _wb_prism(bm, profile, y, shrink=0.72, hub=None):
    """A bevelled solid: the (x, z) profile at y = 0 and a shrunken copy of it
    on each flat, closed up. What the icons draw as a STRUCK lump - the maul's
    ice block, a cut pommel cap - which a flat slab can never be."""
    if hub is None:
        hub = (sum(x for x, _ in profile) / len(profile), sum(z for _, z in profile) / len(profile))
    hx, hz = hub
    mid = [bm.verts.new(Vector((x, 0.0, z))) for x, z in profile]
    n = len(profile)
    for s in (-1, 1):
        cap = [bm.verts.new(Vector((hx + (x - hx) * shrink, s * y, hz + (z - hz) * shrink))) for x, z in profile]
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((mid[i], mid[j], cap[j], cap[i]))
        bm.faces.new(cap)


def _wb_flat_line(bm, pts, stand, wide=0.05, thin=0.020):
    """One narrow raised line laid along an (x, z) curve on BOTH flats of a
    blade, at y = +-stand. Half these icons paint a lit fuller or a coloured
    spine band down the blade, and it has to read from either side, so it is
    two strips and never one."""
    n = len(pts)
    for s in (-1, 1):
        _wb_ribbon(bm, [(x, s * stand, z) for x, z in pts], [thin] * n, wide)


# ---------------------------------------------------------------- Icepick Hatchet (ice uncommon)
# FROM THE ICON: a plain two-pointed PICKAXE. Pale blue steel head, one bar
# crossing the haft and falling away to a point at each end; a raised eye block
# where they cross; a straight unornamented handle. No ice growing on it, no
# lashings, no bit. The whole silhouette is that one shallow arc, so the arc is
# built as ONE bar through the eye rather than two spikes bolted to a socket.


def build_icepickhatchet():
    name = "IcepickHatchet"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    # A plain straight haft. The icon gives it no taper worth modelling, no
    # thong, no butt ice - so it gets none.
    limb(p["Haft"], (0, 0, 0.05), (0, 0, 2.34), 0.095, 0.085, 6)
    melee_grip(p["Grip"], grip, half=0.46, r=0.125, coils=4, proud=0.018)
    box(p["Pommel"], (0, 0, 0.06), (0.20, 0.19, 0.12))

    # THE EYE: the raised collar the head is driven through, with the icon's
    # one stud proud of its forward face and a cheek plate on each flat.
    box(p["Guard"], (0, 0, 2.26), (0.30, 0.28, 0.46))
    box(p["Guard"], (0.20, 0, 2.40), (0.17, 0.21, 0.21), Matrix.Rotation(math.radians(18), 4, "Y"))
    for s in (-1, 1):
        box(p["Guard"], (0, s * 0.16, 2.12), (0.26, 0.05, 0.17))

    # THE HEAD: one bar of pale steel, crowned over the eye and running out to
    # a point each way - the +x beak longer and finer (the pick), the -x poll
    # stubbier. Two arcs, one over the top and one back underneath, and that
    # crescent IS the icon.
    upper = _wb_arc2((-0.86, 2.00), (1.02, 2.06), (0.0, 1.0), 0.565, 6)  # crown lands just under z = LENGTH
    lower = _wb_arc2((1.02, 2.06), (-0.86, 2.00), (0.0, 1.0), 0.24, 5)
    bar = list(upper) + lower[1:-1]
    _wb_slab_varied(p["Edge"], bar, _wb_hub_thicks(bar, (0.02, 2.30), near=0.088, far=0.014, power=0.85))

    # The centre boss over the eye, where the icon thickens the head.
    box(p["Head"], (0.02, 0, 2.34), (0.44, 0.24, 0.26))
    for s in (-1, 1):
        limb(p["Spike"], (0.02, s * 0.11, 2.34), (0.02, s * 0.155, 2.34), 0.055, 0.045, 5)

    # A cold seam along the bar's crown - the only light on it, kept to a line
    # because the icon paints none.
    for x, z, a in ((-0.40, 2.24, 20), (0.02, 2.38, 0), (0.44, 2.28, -18)):
        box(p["Glow"], (x, 0, z), (0.36, 0.21, 0.05), Matrix.Rotation(math.radians(a), 4, "Y"))

    return melee_finish(name, p)


# ---------------------------------------------------------------- Glacier Maul (ice rare)
# FROM THE ICON: one SOLID struck block of pale ice on a wrapped, tapering
# haft. Irregular, chunky, bevelled all round, wider than it is tall, with
# white streaks lit in its core and a small faceted nub of the same ice capping
# the butt. A hollow bell reads as a lantern at any distance; the icon's head
# is a lump, so it is built as a lump (_wb_prism) and not as a cage.


def build_glaciermaul():
    name = "GlacierMaul"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    # Plain tapering haft, wrapped nearly its whole length like the icon's.
    limb(p["Haft"], (0, 0, 0.22), (0, 0, 3.36), 0.145, 0.115, 6)
    melee_grip(p["Grip"], grip, half=0.62, r=0.165, coils=6, proud=0.028)

    # Butt: a banded collar and a faceted nub of the head's own ice.
    _wb_ring(p["Pommel"], (0, 0, 0.34), (0, 0, 1), 0.155, 0.038, seg_major=6, seg_minor=3)
    _wb_shard(p["Spike"], (0, 0, 0.34), (0, 0, 0.02), 0.155, sides=5, waist=0.5, bulge=0.9)

    # The socket the block is set into, and its band.
    limb(p["Guard"], (0, 0, 3.08), (0, 0, 3.42), 0.215, 0.195, 7)
    _wb_ring(p["Guard"], (0, 0, 3.16), (0, 0, 1), 0.215, 0.045, seg_major=7, seg_minor=3)

    # THE BLOCK. One irregular bevelled solid, nearly as tall as it is wide -
    # the icon's head is a struck lump standing ON the haft, and a wide flat
    # one reads as a mushroom cap instead. No two rim runs the same length, so
    # the flats break into facets the way struck ice does.
    block = [
        (-0.40, 3.24),
        (0.20, 3.18),
        (0.62, 3.38),
        (0.72, 3.70),
        (0.62, 4.01),
        (0.28, 4.20),
        (-0.18, 4.14),
        (-0.56, 3.94),
        (-0.66, 3.62),
        (-0.56, 3.36),
    ]
    _wb_prism(p["Head"], block, 0.34, shrink=0.70, hub=(0.02, 3.68))

    # Chips calved off it, the way an ice shelf goes.
    for (bx, bz), (tx, ty, tz), r in (
        ((-0.58, 3.90), (-0.90, 0.06, 4.04), 0.11),
        ((0.66, 3.52), (0.94, -0.05, 3.38), 0.10),
        ((0.16, 3.22), (0.28, 0.04, 2.98), 0.12),
    ):
        _wb_shard(p["Spike"], (bx, 0, bz), (tx, ty, tz), r, sides=4)

    # The white streaks the icon paints lit inside the ice.
    for x, z, h, a in ((-0.24, 3.72, 0.56, -22), (0.22, 3.86, 0.48, 14), (0.10, 3.44, 0.30, -8)):
        box(p["Glow"], (x, 0, z), (0.09, 0.74, h), Matrix.Rotation(math.radians(a), 4, "Y"))

    return melee_finish(name, p)


# ---------------------------------------------------------------- Rimefang Lance (ice legendary)
# FROM THE ICON: a spear, and a spare one. A plain dark round shaft; one
# bright banded ferrule two thirds up; above it a long straight CONE of clear
# rime, symmetric, needling to the point; a small faceted ice cone capping the
# butt. No aurora, no ruff, no curve - the icon's head is a plain narrow
# triangle. Carried level and jabbed from now on, so the shaft's own rhythm
# (three ferrules) has to carry the length, and the head has four short fins
# so it still reads coming straight at you.


def build_rimefanglance():
    name = "RimefangLance"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    limb(p["Haft"], (0, 0, 0.30), (0, 0, 3.36), 0.105, 0.092, 6)
    melee_grip(p["Grip"], grip, half=0.55, r=0.135, coils=5, proud=0.02)
    for z in (1.62, 2.20, 2.78):
        _wb_ring(p["Spike"], (0, 0, z), (0, 0, 1), 0.115, 0.030, seg_major=6, seg_minor=3)

    # THE BUTT SPIKE: the same ice as the head, in a banded collar. Held level
    # this end is beside the player's hip all day, so it is not left bare.
    _wb_ring(p["Pommel"], (0, 0, 0.36), (0, 0, 1), 0.125, 0.034, seg_major=6, seg_minor=3)
    _wb_shard(p["Spike"], (0, 0, 0.34), (0, 0, 0.0), 0.115, sides=5, waist=0.45, bulge=0.95)

    # THE FERRULE: the icon's one strong interruption in the shaft's line.
    limb(p["Guard"], (0, 0, 3.20), (0, 0, 3.58), 0.185, 0.175, 7)
    for z in (3.26, 3.50):
        _wb_ring(p["Guard"], (0, 0, z), (0, 0, 1), 0.19, 0.040, seg_major=7, seg_minor=3)

    # THE FANG: straight and symmetric about the shaft, so it reads the same
    # from the side and down its own length, tapering in width AND thickness
    # to the point at z = LENGTH.
    stations = [
        (0.0, 3.50, 0.235, 0.180),
        (0.0, 3.86, 0.205, 0.152),
        (0.0, 4.16, 0.160, 0.115),
        (0.0, 4.40, 0.098, 0.068),
        (0.0, length - 0.04, 0.030, 0.022),
        (0.0, length, 0.008, 0.006),
    ]
    lofted_blade(p["Edge"], stations)
    for i in range(4):  # rime fins off the ferrule - the head-on read
        a = (i / 4) * TAU + 0.4
        c, s = math.cos(a), math.sin(a)
        _wb_shard(p["Spike"], (c * 0.17, s * 0.17, 3.54), (c * 0.42, s * 0.42, 3.24), 0.05, sides=4)

    # The cold in the fang's core, and the ferrule lit from inside it.
    for z, y, w in ((3.68, 0.40, 0.10), (4.02, 0.28, 0.09), (4.30, 0.17, 0.07)):
        box(p["Glow"], (0, 0, z), (w, y, 0.32))
    _wb_ring(p["Glow"], (0, 0, 3.38), (0, 0, 1), 0.20, 0.030, seg_major=7, seg_minor=3)

    return melee_finish(name, p)


# ---------------------------------------------------------------- Trenchspike (gloom uncommon)
# FROM THE ICON: a near-black spear with a BARBED DART head - a broad flat
# triangle, straight edges to the point, and two spurs swept back and down off
# its shoulders. Almost the whole weapon is bare shaft; there is no lure, no
# jaw, no light. So the barbs are the entire signature, and the only thing
# added is the pair of shaft ferrules the level carry needs.


def build_trenchspike():
    name = "Trenchspike"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    limb(p["Haft"], (0, 0, 0.10), (0, 0, 1.96), 0.10, 0.088, 6)
    melee_grip(p["Grip"], grip, half=0.46, r=0.13, coils=3, proud=0.016)
    ellipsoid(p["Pommel"], (0, 0, 0.11), (0.115, 0.115, 0.10), subdiv=0)
    for z in (1.20, 1.64):
        _wb_ring(p["Spike"], (0, 0, z), (0, 0, 1), 0.105, 0.026, seg_major=6, seg_minor=3)

    # The socket: one short step. The icon keeps it almost invisible.
    limb(p["Guard"], (0, 0, 1.88), (0, 0, 2.12), 0.135, 0.125, 6)

    # THE DART: symmetric, widest at the shoulders, straight edges running to
    # the point at z = LENGTH. A full third of the weapon, the way the icon
    # weights it - a smaller head just reads as a stick.
    stations = [
        (0.0, 2.06, 0.115, 0.070),
        (0.0, 2.26, 0.300, 0.092),
        (0.0, 2.55, 0.225, 0.072),
        (0.0, 2.80, 0.140, 0.048),
        (0.0, length - 0.04, 0.038, 0.019),
        (0.0, length, 0.008, 0.006),
    ]
    lofted_blade(p["Head"], stations)

    # THE BARBS: flat spurs off both shoulders, swept back and down.
    for sx in (-1, 1):
        barb = [(sx * 0.26, 2.30), (sx * 0.74, 1.98), (sx * 0.60, 1.87), (sx * 0.19, 2.12)]
        _wb_slab_varied(p["Edge"], barb, [0.060, 0.014, 0.014, 0.052])

    # One dim line down the midrib - the icon gives this weapon no light at
    # all, so it gets the least the row's neon part can be.
    for z, y in ((2.40, 0.21), (2.66, 0.15), (2.86, 0.09)):  # z + half-height stays under LENGTH
        box(p["Glow"], (0, 0, z), (0.055, y, 0.22))

    return melee_finish(name, p)


# ---------------------------------------------------------------- Voidglass Saber (gloom epic)
# FROM THE ICON: ONE deep-bellied black scimitar - no outboard rail, no slot,
# no struts - and a single vivid PURPLE LINE running the whole length of it
# parallel to the spine, echoed as a band at the guard, the grip and the
# pommel. The hilt is deliberately plain: a smooth cylinder, a plain
# crossblock, a round knob. That line is the entire identity, so it is the one
# thing built with care and everything else gets out of its way.


def build_voidglasssaber():
    name = "VoidglassSaber"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    limb(p["Haft"], (0, 0, 0.22), (0, 0, 1.30), 0.10, 0.10, 6)
    melee_grip(p["Grip"], grip, half=0.42, r=0.125, coils=3, proud=0.014)
    ellipsoid(p["Pommel"], (0, 0, 0.16), (0.165, 0.155, 0.155), subdiv=0)
    box(p["Pommel"], (0, 0, 0.30), (0.20, 0.19, 0.08))

    # Crossblock: a plain slab with a short nub each way, and nothing else.
    box(p["Guard"], (0, 0, 1.36), (0.44, 0.22, 0.14))
    for sx in (-1, 1):
        box(p["Guard"], (sx * 0.28, 0, 1.36), (0.16, 0.17, 0.10), Matrix.Rotation(math.radians(sx * 20), 4, "Y"))

    # THE CRESCENT: wide at the root, bellied out, sweeping up to a raked
    # point at z = LENGTH.
    def spine(t):
        return -0.12 + 1.04 * t**2.00

    def edge(t):
        return 0.30 + 1.08 * t - 0.34 * t * t

    steps = 9
    prof = edge_profile(1.44, length, spine, edge, steps=steps)
    _wb_slab_varied(p["Edge"], prof, _wb_lens_thicks(steps, edge=0.016, tip=0.008, spine_root=0.060, spine_tip=0.024))

    # A facet break parallel to the spine, so the black flat is not one dead
    # plane - the icon shades the blade in two tones.
    ridge = [(spine(t) + 0.10, 1.44 + (length - 1.44) * t) for t in (0.06, 0.36, 0.66, 0.92)]
    _wb_flat_line(p["Head"], ridge, 0.050, wide=0.042, thin=0.018)

    # THE PURPLE SEAM: one line the length of the blade, then the same line
    # again as a band on the guard, the grip and the pommel.
    seam = [(spine(t) * 0.60 + edge(t) * 0.40, 1.44 + (length - 1.44) * t) for t in (0.04, 0.26, 0.50, 0.74, 0.94)]
    _wb_flat_line(p["Glow"], seam, 0.046, wide=0.055, thin=0.022)
    box(p["Glow"], (0.10, 0, 1.44), (0.34, 0.27, 0.06))
    _wb_ring(p["Glow"], (0, 0, 0.62), (0, 0, 1), 0.142, 0.028, seg_major=6, seg_minor=3)
    _wb_ring(p["Glow"], (0, 0, 0.24), (0, 0, 1), 0.175, 0.030, seg_major=6, seg_minor=3)

    return melee_finish(name, p)


# ---------------------------------------------------------------- Boarding Axe (wreck uncommon)
# FROM THE ICON: a classic single-bit BEARDED AXE on a plain brown wooden
# haft. The head is one steel crescent off the forward side - an upper horn, a
# long bowed cutting arc, a lower horn (the beard) and a concave notch back in
# under the eye - with a banded eye, a langet strapping it down the haft, a
# short peak over the crown and a small spur off the back. Not an anchor: the
# icon draws no ring, no stock, no break, and the haft is WOOD.


def build_boardingaxe():
    name = "BoardingAxe"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    limb(p["Haft"], (0, 0, 0.06), (0, 0, 2.98), 0.115, 0.105, 6)
    melee_grip(p["Grip"], grip, half=0.52, r=0.145, coils=5, proud=0.022)
    box(p["Pommel"], (0, 0, 0.07), (0.24, 0.23, 0.14))

    # THE EYE, its two bands, and the langet strapping the head down the haft.
    # The eye is deliberately TALL: the bit meets it across that whole span,
    # and a bit joined to the haft over a short one hangs off it like a flag.
    limb(p["Guard"], (0, 0, 2.52), (0, 0, 3.30), 0.175, 0.165, 7)
    for z in (2.60, 3.24):
        _wb_ring(p["Guard"], (0, 0, z), (0, 0, 1), 0.18, 0.040, seg_major=7, seg_minor=3)
    box(p["Guard"], (0.15, 0, 2.30), (0.10, 0.17, 0.46))

    # THE BIT. Three arcs: a slightly HOLLOW shoulder out to the upper horn (a
    # hollow one leaves a point there; a convex one rounds it into a flag), the
    # bowed cutting face down to the beard, then a deeply concave sweep back in
    # under the eye - that notch is what makes it read bearded and not just
    # broad. Ground the way an axe is: fat at the eye, a wafer at the arc.
    top = _wb_arc2((0.14, 3.26), (0.92, 3.32), (0.0, -1.0), 0.06, 3)
    face = _wb_arc2((0.92, 3.32), (0.88, 2.36), (1.0, 0.0), 0.20, 5)
    beard = _wb_arc2((0.88, 2.36), (0.34, 2.62), (0.4, 1.0), 0.13, 3)
    bit = list(top) + face[1:] + beard[1:] + [(0.14, 2.58)]
    _wb_slab_varied(p["Edge"], bit, _wb_hub_thicks(bit, (0.18, 2.95), near=0.095, far=0.014, power=0.85))

    # The eye cheeks and the short peak over the crown.
    box(p["Head"], (0.06, 0, 3.14), (0.30, 0.25, 0.36), Matrix.Rotation(math.radians(-10), 4, "Y"))
    cone(p["Head"], (0.04, 0, 3.30), (0.10, 0, length), 0.13, sides=5)

    # The back spur, and the two rivets through the cheeks.
    _wb_sweep(p["Spike"], _wb_arc((-0.10, 0, 3.04), (-0.50, 0, 2.80), (-0.2, 0, -0.9), 0.10, 3), [0.09, 0.075, 0.055, 0.030], sides=4)
    for z in (2.74, 3.10):
        limb(p["Spike"], (0.12, -0.15, z), (0.12, 0.15, z), 0.035, 0.035, 4)

    # A cold sheen down the cutting arc. The icon lights nothing, so this is
    # the least the row's neon part can be and still exist.
    _wb_flat_line(p["Glow"], [(x - 0.07, z) for x, z in face[1:-1]], 0.030, wide=0.032, thin=0.014)

    return melee_finish(name, p)


# ---------------------------------------------------------------- Cutlass of the Fleet (wreck epic)
# FROM THE ICON: a proper cutlass in pale silver. The guard is a clean forged
# D - a knuckle bow off the crossblock, out past the hand and back into the
# pommel - with a second quillon curling FORWARD alongside the blade root. The
# blade is broad, strongly upswept, and carries a hatched fuller near the
# spine. No rope, no coin: the icon draws a smith's work, not a bosun's.


def build_cutlassofthefleet():
    name = "CutlassOfTheFleet"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    limb(p["Haft"], (0, 0, 0.30), (0, 0, 1.28), 0.095, 0.10, 6)
    melee_grip(p["Grip"], grip, half=0.40, r=0.125, coils=5, proud=0.02)
    ellipsoid(p["Pommel"], (0, 0, 0.26), (0.15, 0.14, 0.13), subdiv=0)
    box(p["Pommel"], (0, 0, 0.15), (0.17, 0.16, 0.12))

    # THE D-BOW: one bar off the crossblock, bowed out past the knuckles and
    # landing back on the pommel, plus the forward-curling quillon the icon
    # runs up alongside the blade root.
    box(p["Guard"], (0, 0, 1.32), (0.46, 0.20, 0.11))
    bow = _wb_arc((0.24, 0, 1.32), (0.02, 0, 0.24), (1.0, 0, 0.0), 0.42, 6)
    _wb_sweep(p["Guard"], bow, [0.055, 0.055, 0.052, 0.050, 0.048, 0.045, 0.042], sides=4)
    curl = _wb_arc((-0.20, 0, 1.32), (-0.10, 0, 1.74), (-1.0, 0, 0.1), 0.30, 5)
    _wb_sweep(p["Guard"], curl, [0.050, 0.048, 0.044, 0.040, 0.036, 0.030], sides=4)

    # THE BLADE: broad at the root, strongly upswept, the point raking back.
    def spine(t):
        return -0.18 + 0.62 * t**1.85

    def edge(t):
        return 0.30 + 0.74 * t - 0.44 * t * t

    steps = 9
    prof = edge_profile(1.44, length, spine, edge, steps=steps)
    _wb_slab_varied(p["Edge"], prof, _wb_lens_thicks(steps, edge=0.016, tip=0.007, spine_root=0.065, spine_tip=0.026))

    # THE FULLER and the hatch marks the icon rules across it near the forte.
    fuller = [(spine(t) * 0.68 + edge(t) * 0.32, 1.44 + (length - 1.44) * t) for t in (0.08, 0.36, 0.64, 0.90)]
    _wb_flat_line(p["Head"], fuller, 0.046, wide=0.045, thin=0.018)
    for t in (0.12, 0.24, 0.36, 0.48):
        x = spine(t) * 0.55 + edge(t) * 0.45
        z = 1.44 + (length - 1.44) * t
        for s in (-1, 1):
            box(p["Spike"], (x, s * 0.054, z), (0.17, 0.024, 0.035), Matrix.Rotation(math.radians(-16), 4, "Y"))

    # Ghost-fire down the edge, kept to a hairline - the icon's blade is bright
    # steel, not a lit one.
    _wb_flat_line(p["Glow"], [(edge(t) - 0.045, 1.44 + (length - 1.44) * t) for t in (0.10, 0.42, 0.72, 0.94)], 0.026, wide=0.030, thin=0.013)

    return melee_finish(name, p)


# ---------------------------------------------------------------- Admiral's Saber (wreck legendary)
# FROM THE ICON: a long, slender, only gently curved SILVER saber - straight
# for two thirds and then easing up to the point - with a fine jewelled hilt:
# a closely wound grip, a small crossblock with a short down-turned quillon
# each way, beads round the block, and a faceted cut pommel. There are no
# colours, no swallow-tails and no tassel in the icon, and the blade is not
# gilt: it is bright steel with a hatched fuller near the forte.


def build_admiralssaber():
    name = "AdmiralsSaber"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    limb(p["Haft"], (0, 0, 0.24), (0, 0, 1.34), 0.09, 0.098, 6)
    melee_grip(p["Grip"], grip, half=0.44, r=0.115, coils=8, proud=0.018)
    _wb_ring(p["Pommel"], (0, 0, 0.30), (0, 0, 1), 0.135, 0.032, seg_major=7, seg_minor=3)
    _wb_shard(p["Pommel"], (0, 0, 0.30), (0, 0, 0.04), 0.145, sides=6, waist=0.5, bulge=0.95)

    # The crossblock, its two short down-turned quillons, and the beads.
    box(p["Guard"], (0, 0, 1.38), (0.42, 0.18, 0.10))
    for sx in (-1, 1):
        _wb_sweep(p["Guard"], _wb_arc((sx * 0.20, 0, 1.38), (sx * 0.34, 0, 1.14), (sx * 0.6, 0, -0.5), 0.10, 3), [0.055, 0.048, 0.040, 0.032], sides=4)
    for i in range(4):
        a = (i / 4) * TAU + 0.5
        ellipsoid(p["Spike"], (math.cos(a) * 0.11, math.sin(a) * 0.11, 1.38), (0.05, 0.05, 0.05), subdiv=0)

    # THE BLADE: slender, nearly straight at the forte, easing up to the point.
    def spine(t):
        return -0.12 + 0.34 * t**1.55

    def edge(t):
        return 0.16 + 0.40 * t - 0.28 * t * t

    steps = 10
    prof = edge_profile(1.46, length, spine, edge, steps=steps)
    _wb_slab_varied(p["Edge"], prof, _wb_lens_thicks(steps, edge=0.015, tip=0.007, spine_root=0.060, spine_tip=0.024))

    # The fuller, and the icon's hatching ruled across it above the forte.
    fuller = [(spine(t) * 0.66 + edge(t) * 0.34, 1.46 + (length - 1.46) * t) for t in (0.06, 0.34, 0.62, 0.90)]
    _wb_flat_line(p["Head"], fuller, 0.042, wide=0.038, thin=0.016)
    for t in (0.14, 0.24, 0.34):
        x = spine(t) * 0.52 + edge(t) * 0.48
        z = 1.46 + (length - 1.46) * t
        for s in (-1, 1):
            box(p["Spike"], (x, s * 0.050, z), (0.13, 0.022, 0.030), Matrix.Rotation(math.radians(-10), 4, "Y"))

    # A hairline of spectral fire down the edge, brightest at the point.
    _wb_flat_line(p["Glow"], [(edge(t) - 0.035, 1.46 + (length - 1.46) * t) for t in (0.08, 0.40, 0.70, 0.94)], 0.024, wide=0.028, thin=0.012)
    ellipsoid(p["Glow"], (edge(1.0) - 0.03, 0, length - 0.14), (0.045, 0.045, 0.10), subdiv=0)

    return melee_finish(name, p)


# ---------------------------------------------------------------- Galecleaver (maelstrom uncommon)
# FROM THE ICON: a symmetric DOUBLE-BIT battle axe in pale storm steel. Two
# mirrored crescents off one head, each with an upper and a lower horn and a
# bowed cutting arc between them; a small peak on the crown; a banded eye; a
# wrapped haft ending in a bulbous knob. An etched crescent is cut into each
# bit's flat. Not a ported cleaver: the icon has one head, two bits, and no
# holes anywhere in its outline.


def build_galecleaver():
    name = "Galecleaver"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    limb(p["Haft"], (0, 0, 0.26), (0, 0, 3.16), 0.115, 0.10, 6)
    melee_grip(p["Grip"], grip, half=0.56, r=0.14, coils=5, proud=0.024)
    ellipsoid(p["Pommel"], (0, 0, 0.20), (0.20, 0.20, 0.17), subdiv=0)
    _wb_ring(p["Pommel"], (0, 0, 0.36), (0, 0, 1), 0.135, 0.032, seg_major=6, seg_minor=3)

    # The eye, banded above and below, the bits driven through it.
    limb(p["Guard"], (0, 0, 2.66), (0, 0, 3.58), 0.185, 0.175, 7)
    for z in (2.74, 3.50):
        _wb_ring(p["Guard"], (0, 0, z), (0, 0, 1), 0.19, 0.038, seg_major=7, seg_minor=3)

    # THE DOUBLE BIT: one profile, built once on +x and mirrored onto -x, so
    # the two crescents are the same forging and not two parts bolted on. Each
    # bit is nearly as TALL as it is wide with hollow shoulders top and bottom,
    # because that is what leaves four horns; a short wide bit rounds off into
    # a mushroom no matter how the arc is bowed. Fat at the eye, wafer at both
    # cutting arcs.
    half = _wb_arc2((0.20, 2.82), (0.58, 2.68), (0.0, 1.0), 0.11, 2)
    half += _wb_arc2((0.58, 2.68), (0.62, 3.68), (1.0, 0.0), 0.18, 4)[1:]
    half += _wb_arc2((0.62, 3.68), (0.22, 3.54), (0.0, -1.0), 0.11, 2)[1:]
    head = [(0.0, 2.86)] + half + [(0.0, 3.60)] + [(-x, z) for x, z in reversed(half)]
    _wb_slab_varied(p["Edge"], head, _wb_hub_thicks(head, (0.0, 3.20), near=0.105, far=0.014, power=0.9))

    # The crown peak and the eye cheeks.
    cone(p["Head"], (0.0, 0, 3.56), (0.0, 0, length), 0.15, sides=5)
    box(p["Head"], (0, 0, 3.18), (0.34, 0.31, 0.44))

    # The etched crescent the icon cuts into each bit, on both flats.
    for sx in (-1, 1):
        motif = [(sx * 0.34, 2.98), (sx * 0.54, 3.20), (sx * 0.42, 3.42)]
        for sy in (-1, 1):
            _wb_ribbon(p["Spike"], [(x, sy * 0.062, z) for x, z in motif], [0.022] * 3, 0.045)

    # Storm sheen down both cutting arcs.
    for sx in (-1, 1):
        _wb_flat_line(p["Glow"], [(sx * (x - 0.06), z) for x, z in half[2:6]], 0.028, wide=0.028, thin=0.013)

    return melee_finish(name, p)


# ---------------------------------------------------------------- Stormlance (maelstrom epic)
# FROM THE ICON: a WINGED lance. A dark slate shaft, a narrow luminous leaf of
# storm-ice at the top, and - the thing that makes it this weapon - two tiers
# of swept-back ice wings, a big pair flaring off the blade's root and a
# smaller pair further down the bare shaft. No lantern, no cage, no core. The
# two tiers are also exactly what a level-carried spear needs: the ornament is
# spread down the shaft instead of piled on the tip.


def build_stormlance():
    name = "Stormlance"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    limb(p["Haft"], (0, 0, 0.34), (0, 0, 3.40), 0.105, 0.09, 6)
    melee_grip(p["Grip"], grip, half=0.55, r=0.135, coils=5, proud=0.02)
    _wb_ring(p["Pommel"], (0, 0, 0.38), (0, 0, 1), 0.12, 0.032, seg_major=6, seg_minor=3)
    _wb_shard(p["Spike"], (0, 0, 0.36), (0, 0, 0.0), 0.11, sides=5, waist=0.45, bulge=0.95)
    for z in (1.50, 2.16):
        _wb_ring(p["Spike"], (0, 0, z), (0, 0, 1), 0.11, 0.026, seg_major=6, seg_minor=3)

    limb(p["Guard"], (0, 0, 3.28), (0, 0, 3.58), 0.165, 0.155, 7)
    _wb_ring(p["Guard"], (0, 0, 3.34), (0, 0, 1), 0.17, 0.036, seg_major=7, seg_minor=3)

    # THE LEAF: symmetric about the shaft, so it reads the same in profile and
    # coming straight at you, needling to z = LENGTH.
    stations = [
        (0.0, 3.52, 0.140, 0.090),
        (0.0, 3.78, 0.215, 0.115),
        (0.0, 4.08, 0.180, 0.092),
        (0.0, 4.34, 0.115, 0.058),
        (0.0, length - 0.05, 0.038, 0.022),
        (0.0, length, 0.008, 0.006),
    ]
    lofted_blade(p["Edge"], stations)

    # THE WINGS, two tiers, swept back and down off both sides.
    for sx in (-1, 1):
        big = [(sx * 0.10, 3.70), (sx * 0.58, 3.56), (sx * 0.66, 3.26), (sx * 0.44, 3.14), (sx * 0.24, 3.32), (sx * 0.09, 3.46)]
        _wb_slab_varied(p["Head"], big, [0.055, 0.020, 0.014, 0.018, 0.030, 0.050])
        small = [(sx * 0.09, 3.08), (sx * 0.42, 2.98), (sx * 0.46, 2.78), (sx * 0.26, 2.72), (sx * 0.09, 2.90)]
        _wb_slab_varied(p["Head"], small, [0.045, 0.018, 0.014, 0.022, 0.042])

    # The storm in the leaf's core, and a lit rib down each wing.
    for z, y, w in ((3.82, 0.26, 0.075), (4.10, 0.21, 0.070), (4.34, 0.13, 0.055)):
        box(p["Glow"], (0, 0, z), (w, y, 0.28))
    for sx in (-1, 1):
        box(p["Glow"], (sx * 0.34, 0, 3.44), (0.34, 0.09, 0.07), Matrix.Rotation(math.radians(-sx * 22), 4, "Y"))
        box(p["Glow"], (sx * 0.26, 0, 2.92), (0.26, 0.08, 0.06), Matrix.Rotation(math.radians(-sx * 20), 4, "Y"))

    return melee_finish(name, p)


# ---------------------------------------------------------------- Krakenfang (maelstrom legendary)
# FROM THE ICON: a big single-edged FALCHION in pale lavender - broad at the
# root, bellied out, curving up to the point - carrying a dark purple band
# along its spine that is the same colour as the hilt. The guard is the tell:
# an S-flare, one horn rising forward along the edge side and one falling back
# on the spine side. The pommel is a cut block with one small pale stone in it.
# No tentacle, no suckers, no pearl held out past the tip.


def build_krakenfang():
    name = "Krakenfang"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    limb(p["Haft"], (0, 0, 0.30), (0, 0, 1.42), 0.105, 0.115, 6)
    melee_grip(p["Grip"], grip, half=0.46, r=0.14, coils=6, proud=0.022)

    # A squared, faceted cap with the icon's one small stone set in it.
    _wb_prism(p["Pommel"], [(-0.17, 0.05), (0.17, 0.07), (0.19, 0.30), (-0.15, 0.28)], 0.16, shrink=0.72, hub=(0.01, 0.18))
    ellipsoid(p["Glow"], (0.0, 0, 0.18), (0.075, 0.185, 0.075), subdiv=0)

    # THE S-FLARE: one horn up the edge side, one down the spine side.
    box(p["Guard"], (0, 0, 1.46), (0.36, 0.25, 0.13))
    _wb_sweep(p["Guard"], _wb_arc((0.14, 0, 1.46), (0.44, 0, 1.86), (0.9, 0, -0.2), 0.16, 4), [0.085, 0.075, 0.062, 0.048, 0.034], sides=4)
    _wb_sweep(p["Guard"], _wb_arc((-0.12, 0, 1.44), (-0.44, 0, 1.16), (-0.9, 0, 0.2), 0.14, 4), [0.080, 0.070, 0.058, 0.045, 0.032], sides=4)

    # THE BLADE: broad root, deep belly, closing to the point at z = LENGTH.
    def spine(t):
        return -0.24 + 0.86 * t**1.80

    def edge(t):
        return 0.36 + 0.98 * t - 0.66 * t * t

    steps = 10
    prof = edge_profile(1.54, length, spine, edge, steps=steps)
    _wb_slab_varied(p["Edge"], prof, _wb_lens_thicks(steps, edge=0.018, tip=0.008, spine_root=0.075, spine_tip=0.028))

    # THE SPINE BAND, in the hilt's own dark purple (hence _Guard, which takes
    # the row's `color`) - the icon paints the two the same and that pairing is
    # half of why the blade reads as lavender at all.
    band = [(spine(t) + 0.10, 1.54 + (length - 1.54) * t) for t in (0.05, 0.32, 0.60, 0.86)]
    _wb_flat_line(p["Guard"], band, 0.052, wide=0.070, thin=0.024)

    # The bevel break between band and edge, and the small eye set in the flat.
    bevel = [(spine(t) * 0.35 + edge(t) * 0.65, 1.54 + (length - 1.54) * t) for t in (0.10, 0.42, 0.72, 0.92)]
    _wb_flat_line(p["Head"], bevel, 0.036, wide=0.040, thin=0.016)
    for sy in (-1, 1):
        _wb_ring(p["Spike"], (0.30, sy * 0.048, 2.70), (0, 1, 0), 0.085, 0.026, seg_major=6, seg_minor=3)

    # A hairline of the Maw's light under the band, and nothing else lit.
    _wb_flat_line(p["Glow"], [(spine(t) + 0.19, 1.54 + (length - 1.54) * t) for t in (0.08, 0.46, 0.84)], 0.030, wide=0.026, thin=0.013)

    return melee_finish(name, p)


# ================================================================ RANGED REBUILD
# The fifteen ranged variants, rebuilt from scratch. Everything from here to
# the preview - the gun_* helpers and the fifteen builders - is the ranged
# pass; no melee variant reaches into it.
#
# THE GUN FRAME, on top of the pack contract at the top of this file:
#   +z  THE BORE. The muzzle sits EXACTLY at z = LENGTH and _Muzzle is a ~0.1
#       stud marker centred on it (the muzzle-flash / projectile origin).
#   +x  UP. Every melee blade in this pack puts its cutting edge on +x - the
#       Scaleblade's leaf spans x with its flats on y, the Drowncleaver's
#       spine is -x and its edge +x, the axe wedge and the glow strips sit on
#       +x - so +x is the pack's "business" side, and every gun's sights,
#       scope, top strap, carry handle and rib live there.
#   -x  DOWN: grip, trigger, trigger guard, magazine, drum, spool - everything
#       that hangs under a gun.
#   +-y the flanks: lock plates, charging handles, ejection ports, side rails.
#
# Parts, the pack contract plus the four new suffixes:
#   _Haft  stock / frame / handguard (color)   _Grip  the firing hand (wrap)
#   _Guard trigger guard, furniture (color)    _Pommel butt plate (color)
#   _Head  receiver / breech (accent)          _Edge  barrel (accent)
#   _Spike sight posts, brakes, barbs, bands (accent)
#   _Mag    the magazine / cylinder / drum / spool / arrow, as ONE separable
#           piece - the reload animation detaches and moves it, so it is never
#           fused into the receiver.
#   _Action the moving part: bolt, slide, hammer, lever, charging handle,
#           break lever, bowstring, speargun bands - plus the trigger blade.
#   _Sight  irons or optic.       _Muzzle the bore marker at z = LENGTH.
#
# Budget: every gun is well under 900 triangles (main() prints the counts).

GUN_SUFFIXES = ("Haft", "Grip", "Pommel", "Guard", "Head", "Edge", "Spike", "Mag", "Action", "Sight", "Muzzle", "Glow")


def gun_bms():
    """One bmesh per gun part suffix. Unused ones stay empty and finish()
    returns None for them, so a gun only exports the parts it actually has."""
    return {suffix: bmesh.new() for suffix in GUN_SUFFIXES}


def gun_finish(name, parts):
    return [finish(f"{name}_{suffix}", bm) for suffix, bm in parts.items()]


def gun_muzzle(bm, length, size=0.1):
    """The mandatory bore marker: a tiny cube centred on the bore at z = LENGTH."""
    box(bm, (0, 0, length), (size, size, size))


def gun_grip(grip_bm, frame_bm, x, z, rake=20.0, r=0.15, half=0.24, drop=0.0, width=0.20):
    """The firing hand. The wrap is its own object and its CENTRE is exactly
    (x, 0, z) - the hand point, z = GRIP. `rake` leans the column back (-z) as
    it drops (-x); `frame_bm` gets the grip column the wrap is wrapped around,
    running from the receiver's underside down past the wrap by `drop`."""
    a = math.radians(rake)
    d = Vector((-math.cos(a), 0, -math.sin(a)))
    c = Vector((x, 0, z))
    limb(grip_bm, c - d * half, c + d * half, r, r * 0.94, 7)
    if frame_bm is not None:
        top = c - d * (half + 0.14)
        bot = c + d * (half + drop)
        box(frame_bm, (top + bot) / 2, (r * 1.45, width, (bot - top).length), Matrix.Rotation(-math.pi / 2 - a, 4, "Y"))


def gun_wrist(grip_bm, x, z, rake=12.0, r=0.15, half=0.30):
    """A rifle/musket wrist grip: the hand runs mostly along the bore instead
    of hanging under it (bolt guns, lever guns, muskets, break-actions).
    Centre is again exactly (x, 0, z)."""
    a = math.radians(rake)
    d = Vector((math.sin(a), 0, math.cos(a)))
    c = Vector((x, 0, z))
    limb(grip_bm, c - d * half, c + d * half, r * 0.94, r, 7)


def gun_trigger(guard_bm, action_bm, x, z, drop=0.24, half_z=0.17, width=0.10, blade=True):
    """A trigger guard bow hanging under the receiver at (x, z), plus the
    trigger blade inside it (the blade is _Action - it moves)."""
    box(guard_bm, (x - drop, 0, z), (0.06, width, half_z * 2 + 0.06))
    box(guard_bm, (x - drop / 2, 0, z + half_z), (drop, width, 0.06))
    box(guard_bm, (x - drop / 2, 0, z - half_z), (drop, width, 0.06))
    if blade:
        box(action_bm, (x - 0.10, 0, z + 0.02), (0.13, 0.05, 0.07), Matrix.Rotation(math.radians(22), 4, "Y"))


def gun_mag(bm, x, z, drop=0.62, curve=18.0, width=0.22, thick=0.16, segs=3, floor=True):
    """A box magazine hanging off the receiver's underside at (x, z): it drops
    along -x and bows forward (+z) by `curve` degrees, which is what turns a
    stick mag into an AK/AR banana. Its own object - the reload part."""
    seg = drop / segs
    p = Vector((x, 0, z))
    for i in range(segs):
        a = math.radians(-90 + curve * (i + 0.5) / segs)
        d = Vector((math.sin(a), 0, math.cos(a)))
        c = p + d * (seg / 2)
        box(bm, c, (thick, width, seg * 1.1), Matrix.Rotation(a, 4, "Y"))
        p = p + d * seg
    if floor:
        a = math.radians(-90 + curve)
        box(bm, p, (0.05, width * 1.15, thick * 1.5), Matrix.Rotation(a, 4, "Y"))


def gun_cylinder(bm, x, z0, z1, ring_r=0.15, lobe_r=0.08, chambers=6, plate_r=0.2):
    """A real revolver cylinder: `chambers` round bores in a ring about the
    cylinder axis, so it reads as six chambers head-on and as six flutes from
    the side, capped by two end plates and a centre pin. One lobe sits at
    angle 0 = straight up (+x), lined up with the barrel above it."""
    for i in range(chambers):
        a = (i / chambers) * TAU
        cx, cy = x + math.cos(a) * ring_r, math.sin(a) * ring_r
        limb(bm, (cx, cy, z0), (cx, cy, z1), lobe_r, lobe_r, 6)
    limb(bm, (x, 0, z0), (x, 0, z0 + 0.05), plate_r, plate_r, 10)
    limb(bm, (x, 0, z1 - 0.05), (x, 0, z1), plate_r, plate_r, 10)
    limb(bm, (x, 0, z0 - 0.07), (x, 0, z1 + 0.07), 0.035, 0.035, 5)


def gun_band(bm, z, r, thick=0.05, x=0.0, sides=8):
    """A band / ring / cooling fin around the barrel at z."""
    limb(bm, (x, 0, z - thick / 2), (x, 0, z + thick / 2), r, r, sides)


def gun_post(bm, z, base_x, height, width=0.06, y=0.06):
    """A sight post standing off the +x (up) side of the barrel at z."""
    box(bm, (base_x + height / 2, 0, z), (height, y, width))


def gun_ring(bm, cx, cz, r, tube_r=0.04, y=0.0, seg=7):
    """A closed loop lying in the x-z plane - a lever loop, a lanyard ring."""
    pts = [Vector((cx + math.cos(a) * r, y, cz + math.sin(a) * r)) for a in ((i / seg) * TAU for i in range(seg))]
    for i in range(seg):
        limb(bm, pts[i], pts[(i + 1) % seg], tube_r, tube_r, 4)


def gun_flintlock(head_bm, action_bm, z, x=0.0, side=1.0, scale=1.0):
    """A visible flintlock on a flank: the plate, the pan, the cock/hammer
    swept back off the plate and the frizzen standing over the pan. Plate and
    pan are _Head, the moving cock and frizzen are _Action."""
    y = 0.13 * side
    s = scale
    box(head_bm, (x + 0.02 * s, y, z), (0.32 * s, 0.06, 0.26 * s))
    box(head_bm, (x + 0.13 * s, y * 1.25, z + 0.10 * s), (0.09 * s, 0.05, 0.08 * s))  # the pan
    box(action_bm, (x + 0.14 * s, y * 1.3, z - 0.05 * s), (0.24 * s, 0.06, 0.08 * s), Matrix.Rotation(math.radians(58), 4, "Y"))
    box(action_bm, (x + 0.23 * s, y * 1.3, z - 0.14 * s), (0.13 * s, 0.07, 0.07 * s))  # the jaws
    box(action_bm, (x + 0.20 * s, y * 1.3, z + 0.15 * s), (0.16 * s, 0.06, 0.06 * s), Matrix.Rotation(math.radians(-28), 4, "Y"))


# ---------------------------------------------------------------- Frostbore Rifle
# A scoped bolt-action long rifle: tapered barrel, a walnut stock with a raised
# cheek rise, the bolt handle out the right flank, a tube scope over the
# receiver on two rings.


def build_frostborerifle():
    name = "FrostboreRifle"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = gun_bms()

    # Wooden stock: butt, comb, cheek rise (+x), wrist, belly, forend.
    box(p["Haft"], (-0.30, 0, 0.19), (0.64, 0.26, 0.36))
    box(p["Haft"], (-0.26, 0, 0.62), (0.50, 0.24, 0.56))
    box(p["Haft"], (0.03, 0, 0.80), (0.14, 0.19, 0.46))
    box(p["Haft"], (-0.24, 0, 1.10), (0.40, 0.22, 0.46))
    box(p["Haft"], (-0.16, 0, 1.62), (0.26, 0.25, 0.80))
    box(p["Haft"], (-0.19, 0, 2.38), (0.22, 0.21, 0.98))
    box(p["Pommel"], (-0.30, 0, 0.03), (0.66, 0.26, 0.08))
    box(p["Haft"], (-0.50, 0, 0.30), (0.18, 0.24, 0.32), Matrix.Rotation(math.radians(-18), 4, "Y"))

    # Receiver and the long tapered barrel.
    box(p["Head"], (-0.07, 0, 1.62), (0.32, 0.26, 0.80))
    limb(p["Edge"], (0, 0, 1.94), (0, 0, length), 0.085, 0.052, 8)
    gun_band(p["Spike"], length - 0.05, 0.064, 0.09)

    # Bolt: the shroud out the back of the receiver, the handle out the flank.
    limb(p["Action"], (0, 0, 1.14), (0, 0, 1.28), 0.085, 0.085, 7)
    limb(p["Action"], (0, 0.11, 1.50), (0, 0.30, 1.38), 0.042, 0.042, 5)
    ellipsoid(p["Action"], (0, 0.33, 1.36), (0.07, 0.07, 0.07), subdiv=0)

    # Scope: eyepiece, tube, objective bell, two rings.
    limb(p["Sight"], (0.30, 0, 1.20), (0.30, 0, 1.36), 0.10, 0.082, 8)
    limb(p["Sight"], (0.30, 0, 1.36), (0.30, 0, 2.22), 0.075, 0.075, 8)
    limb(p["Sight"], (0.30, 0, 2.22), (0.30, 0, 2.42), 0.082, 0.108, 8)
    for z in (1.45, 2.08):
        box(p["Sight"], (0.19, 0, z), (0.18, 0.13, 0.09))

    # Floorplate magazine under the receiver, trigger, wrist grip.
    gun_mag(p["Mag"], -0.29, 1.66, drop=0.24, curve=0, width=0.22, thick=0.17, segs=1)
    gun_trigger(p["Guard"], p["Action"], -0.28, 1.32)
    gun_wrist(p["Grip"], -0.22, grip, rake=10, r=0.155, half=0.30)
    gun_muzzle(p["Muzzle"], length)
    return gun_finish(name, p)


# ---------------------------------------------------------------- Gloomcaller DMR
# A modern marksman rifle: long heavy barrel out of a slab receiver, a boxy
# optic on risers, a straight box magazine, a skeletonised stock (two rails
# with daylight between them) and a pistol grip.


def build_gloomcallerdmr():
    name = "GloomcallerDmr"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = gun_bms()

    # Skeleton stock: butt block, a comb rail on top, a lower rail, air between.
    box(p["Haft"], (-0.24, 0, 0.10), (0.56, 0.24, 0.20))
    box(p["Haft"], (-0.04, 0, 0.76), (0.15, 0.21, 1.34))
    box(p["Haft"], (-0.27, 0, 0.52), (0.13, 0.19, 0.66), Matrix.Rotation(math.radians(28), 4, "Y"))
    box(p["Haft"], (-0.22, 0, 1.32), (0.44, 0.22, 0.22))
    box(p["Pommel"], (-0.22, 0, 0.03), (0.56, 0.25, 0.09))

    # Receiver, free-float handguard, heavy barrel, brake.
    box(p["Head"], (-0.08, 0, 1.72), (0.34, 0.27, 0.88))
    box(p["Haft"], (-0.12, 0, 2.50), (0.26, 0.24, 0.72))
    for s in (-1, 1):
        for z in (2.28, 2.50, 2.72):
            box(p["Haft"], (-0.12, s * 0.13, z), (0.16, 0.03, 0.10))
    limb(p["Edge"], (0, 0, 2.14), (0, 0, length - 0.22), 0.078, 0.062, 8)
    box(p["Spike"], (0, 0, length - 0.11), (0.20, 0.20, 0.26))
    limb(p["Spike"], (0, 0, length - 0.06), (0, 0, length), 0.075, 0.075, 8)

    # Boxy optic on two risers, with a lens face.
    limb(p["Sight"], (0.32, 0, 1.34), (0.32, 0, 1.52), 0.098, 0.070, 8)  # eyepiece
    limb(p["Sight"], (0.32, 0, 1.52), (0.32, 0, 2.28), 0.066, 0.066, 8)  # the tube
    limb(p["Sight"], (0.32, 0, 2.28), (0.32, 0, 2.50), 0.072, 0.105, 8)  # objective bell
    for z in (1.62, 2.18):
        box(p["Sight"], (0.19, 0, z), (0.16, 0.14, 0.10))

    # Straight box magazine, charging handle on the flank, grip, trigger.
    gun_mag(p["Mag"], -0.26, 1.60, drop=0.74, curve=4, width=0.22, thick=0.18, segs=2)
    box(p["Action"], (0.02, 0.17, 2.02), (0.10, 0.11, 0.16))
    box(p["Action"], (0.04, 0.15, 1.86), (0.06, 0.04, 0.36))
    gun_grip(p["Grip"], p["Haft"], -0.34, grip, rake=18, r=0.15, drop=0.12)
    gun_trigger(p["Guard"], p["Action"], -0.28, 1.46)

    # The gloom in the metal: lit strips down both flanks of the receiver.
    for s in (-1, 1):
        box(p["Glow"], (-0.02, s * 0.14, 1.72), (0.07, 0.04, 0.62))
    gun_muzzle(p["Muzzle"], length)
    return gun_finish(name, p)


# ---------------------------------------------------------------- Cyclone Rifle
# The classic AR silhouette: in-line buffer stock, upper over lower receiver, a
# carry handle with the rear aperture in it, round handguard, curved 30-round
# magazine, front sight tower, birdcage flash hider.


def build_cyclonerifle():
    name = "CycloneRifle"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = gun_bms()

    # In-line stock on its buffer tube.
    box(p["Haft"], (-0.10, 0, 0.34), (0.36, 0.25, 0.60))
    limb(p["Haft"], (-0.06, 0, 0.62), (-0.06, 0, 1.32), 0.105, 0.105, 7)
    box(p["Haft"], (-0.14, 0, 0.90), (0.16, 0.22, 0.30))
    box(p["Pommel"], (-0.10, 0, 0.05), (0.40, 0.26, 0.10))

    # Upper and lower receiver.
    box(p["Head"], (-0.02, 0, 1.66), (0.28, 0.26, 0.78))
    box(p["Head"], (-0.26, 0, 1.62), (0.22, 0.23, 0.58))
    box(p["Head"], (-0.24, 0, 1.36), (0.26, 0.24, 0.20))
    box(p["Head"], (0.06, 0.15, 1.72), (0.13, 0.05, 0.24))  # ejection port cover

    # Carry handle: two posts, the bar between them, the rear aperture ring.
    for z in (1.38, 1.92):
        box(p["Sight"], (0.20, 0, z), (0.22, 0.10, 0.09))
    box(p["Sight"], (0.30, 0, 1.65), (0.10, 0.13, 0.66))
    gun_ring(p["Sight"], 0.30, 1.36, 0.07, 0.028, seg=6)

    # Handguard, barrel, gas block + front sight tower, birdcage.
    limb(p["Haft"], (0, 0, 2.05), (0, 0, 2.82), 0.155, 0.145, 8)
    for z in (2.18, 2.38, 2.58, 2.74):
        gun_band(p["Haft"], z, 0.165, 0.04)
    limb(p["Edge"], (0, 0, 2.02), (0, 0, length - 0.17), 0.058, 0.05, 8)
    box(p["Spike"], (0.10, 0, 2.94), (0.24, 0.13, 0.16))
    gun_post(p["Spike"], 2.94, 0.20, 0.16, width=0.05, y=0.05)
    limb(p["Spike"], (0, 0, length - 0.19), (0, 0, length), 0.082, 0.075, 6)

    # Curved 30-rounder, charging handle at the back of the upper, grip.
    gun_mag(p["Mag"], -0.28, 1.56, drop=0.90, curve=16, width=0.22, thick=0.16, segs=3)
    box(p["Action"], (0.02, 0, 1.28), (0.09, 0.28, 0.09))
    box(p["Action"], (0.02, 0, 1.36), (0.07, 0.10, 0.10))
    gun_grip(p["Grip"], p["Haft"], -0.34, grip, rake=22, r=0.15, drop=0.12)
    gun_trigger(p["Guard"], p["Action"], -0.30, 1.44)
    gun_muzzle(p["Muzzle"], length)
    return gun_finish(name, p)


# ---------------------------------------------------------------- Cinderlock Carbine
# AK-flavoured full-auto: thick wooden stock and handguards, the gas tube
# canted over the barrel with its own top handguard, a slab receiver, a heavily
# curved magazine, the front sight tower and a slant brake.


def build_cinderlockcarbine():
    name = "CinderlockCarbine"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = gun_bms()

    # Thick wooden stock, sloping into the receiver.
    box(p["Haft"], (-0.30, 0, 0.20), (0.60, 0.27, 0.38))
    box(p["Haft"], (-0.24, 0, 0.60), (0.48, 0.25, 0.50))
    box(p["Haft"], (-0.20, 0, 0.94), (0.38, 0.23, 0.34))
    box(p["Pommel"], (-0.30, 0, 0.04), (0.62, 0.27, 0.10))

    # Slab receiver with the dust cover on top and the charging handle out the
    # right flank - the AK read.
    box(p["Head"], (-0.10, 0, 1.38), (0.34, 0.27, 0.84))
    box(p["Action"], (0.09, 0, 1.44), (0.10, 0.25, 0.66))
    box(p["Action"], (0.06, 0.17, 1.74), (0.10, 0.11, 0.14))

    # Barrel, canted gas tube over it, both wooden handguards.
    limb(p["Edge"], (0, 0, 1.80), (0, 0, length - 0.14), 0.062, 0.055, 8)
    limb(p["Edge"], (0.16, 0, 1.86), (0.155, 0, 2.62), 0.052, 0.048, 6)
    box(p["Haft"], (-0.17, 0, 2.16), (0.22, 0.24, 0.76))
    box(p["Haft"], (0.19, 0, 2.16), (0.16, 0.20, 0.68))
    box(p["Head"], (0.10, 0, 2.64), (0.26, 0.16, 0.14))  # gas block

    # Front sight tower and the slant brake.
    box(p["Spike"], (0.12, 0, 2.96), (0.30, 0.13, 0.16))
    gun_post(p["Spike"], 2.96, 0.27, 0.16, width=0.05, y=0.05)
    box(p["Spike"], (0, 0, length - 0.08), (0.17, 0.17, 0.20), Matrix.Rotation(math.radians(14), 4, "Y"))
    box(p["Sight"], (0.14, 0, 1.86), (0.14, 0.13, 0.07))

    # The banana mag, the grip, the trigger.
    gun_mag(p["Mag"], -0.28, 1.32, drop=0.76, curve=26, width=0.22, thick=0.17, segs=3)
    gun_grip(p["Grip"], p["Haft"], -0.32, grip, rake=24, r=0.155, drop=0.12)
    gun_trigger(p["Guard"], p["Action"], -0.28, 1.20)
    gun_muzzle(p["Muzzle"], length)
    return gun_finish(name, p)


# ---------------------------------------------------------------- Phantom Repeater
# A haunted lever gun: octagonal barrel, the tube magazine slung under it, the
# big loop lever hanging off the receiver, buckhorn irons, and spectral
# fittings burning cold along the metal.


def build_phantomrepeater():
    name = "PhantomRepeater"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = gun_bms()

    # Curved wooden stock and the short forend.
    box(p["Haft"], (-0.28, 0, 0.19), (0.56, 0.26, 0.36))
    box(p["Haft"], (-0.24, 0, 0.60), (0.48, 0.24, 0.52))
    box(p["Haft"], (-0.20, 0, 1.02), (0.36, 0.22, 0.40))
    box(p["Haft"], (-0.15, 0, 2.24), (0.24, 0.23, 0.62))
    box(p["Pommel"], (-0.28, 0, 0.03), (0.58, 0.26, 0.09))
    box(p["Pommel"], (-0.52, 0, 0.11), (0.13, 0.24, 0.22))
    box(p["Pommel"], (-0.04, 0, 0.11), (0.13, 0.24, 0.22))

    # Receiver, then the octagonal barrel (an eight-sided tube, held constant).
    box(p["Head"], (-0.07, 0, 1.58), (0.32, 0.25, 0.72))
    limb(p["Edge"], (0, 0, 1.92), (0, 0, length), 0.088, 0.078, 8)

    # Tube magazine under the barrel, with its nose cap.
    limb(p["Mag"], (-0.155, 0, 1.98), (-0.155, 0, 3.24), 0.055, 0.055, 6)
    gun_band(p["Mag"], 3.24, 0.068, 0.08, x=-0.155, sides=6)

    # The lever: an arm off the receiver into a big finger loop.
    box(p["Action"], (-0.24, 0, 1.42), (0.20, 0.09, 0.12), Matrix.Rotation(math.radians(-55), 4, "Y"))
    gun_ring(p["Action"], -0.38, 1.24, 0.175, 0.042, seg=7)

    # Buckhorn rear, blade front.
    box(p["Sight"], (0.13, 0, 2.02), (0.12, 0.15, 0.07))
    gun_post(p["Sight"], 3.26, 0.08, 0.13, width=0.05, y=0.05)

    gun_wrist(p["Grip"], -0.20, grip, rake=10, r=0.155, half=0.28)
    gun_trigger(p["Guard"], p["Action"], -0.26, 1.28, blade=True)

    # Spectral fittings: bands round the barrel, wisp-runes on the receiver.
    for z in (2.30, 2.78):
        gun_band(p["Glow"], z, 0.10, 0.06)
    for s in (-1, 1):
        box(p["Glow"], (-0.04, s * 0.13, 1.58), (0.09, 0.04, 0.46))
    ellipsoid(p["Glow"], (0, 0, length - 0.02), (0.055, 0.055, 0.04), subdiv=0)
    gun_muzzle(p["Muzzle"], length)
    return gun_finish(name, p)


# ---------------------------------------------------------------- Mire Flintlock
# A flintlock pistol: the wooden grip curving down and back off the breech to a
# brass butt cap, a round tapered barrel with a slight muzzle flare, the brass
# lock plate with its cock and frizzen standing on the flank, and the ramrod
# under the barrel (the reload part, so it is _Mag).


def build_mireflintlock():
    name = "MireFlintlock"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = gun_bms()

    # The down-curved grip, thickening into the butt.
    limb(p["Haft"], (-0.10, 0, 0.62), (-0.36, 0, 0.32), 0.145, 0.135, 7)
    limb(p["Haft"], (-0.36, 0, 0.32), (-0.60, 0, 0.05), 0.135, 0.165, 7)
    box(p["Haft"], (-0.05, 0, 0.64), (0.32, 0.22, 0.44))  # the wrist / breech block
    ellipsoid(p["Pommel"], (-0.63, 0, 0.03), (0.14, 0.13, 0.10), subdiv=0)

    # The hand rides the curve; its centre is the hand point.
    gun_grip(p["Grip"], None, -0.29, grip, rake=48, r=0.15, half=0.20)

    # Round tapered barrel with the flare at the muzzle.
    limb(p["Edge"], (0, 0, 0.72), (0, 0, length - 0.10), 0.10, 0.072, 8)
    limb(p["Edge"], (0, 0, length - 0.10), (0, 0, length), 0.072, 0.098, 8)
    gun_band(p["Spike"], 0.86, 0.108, 0.06)

    # Lock plate, pan, cock and frizzen on the flank.
    gun_flintlock(p["Head"], p["Action"], 0.72, x=0.02, side=1.0, scale=1.0)

    # Ramrod under the barrel - what a reload actually moves.
    limb(p["Mag"], (-0.135, 0, 0.86), (-0.135, 0, 1.70), 0.028, 0.028, 4)
    box(p["Mag"], (-0.135, 0, 1.72), (0.05, 0.06, 0.06))

    gun_trigger(p["Guard"], p["Action"], -0.20, 0.50, drop=0.18, half_z=0.13)
    gun_post(p["Sight"], length - 0.16, 0.075, 0.09, width=0.05, y=0.05)
    box(p["Sight"], (0.14, 0, 0.52), (0.10, 0.11, 0.06))

    # Fen-venom etching on both stock flanks and a vein up the barrel.
    for s in (-1, 1):
        stroke(p["Glow"], (-0.10, s * 0.11, 0.62), 0.26, 40)
    box(p["Glow"], (0.09, 0, 1.24), (0.03, 0.04, 0.60))
    gun_muzzle(p["Muzzle"], length)
    return gun_finish(name, p)


# ---------------------------------------------------------------- Frostbite Revolver
# A revolver, and it had better read as one: a real six-chamber cylinder under
# the top strap (its axis below the bore so the top chamber lines up with the
# barrel), a fluted barrel on an underlug, the hammer spur standing off the
# back, and a curved grip.


def build_frostbiterevolver():
    name = "FrostbiteRevolver"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = gun_bms()

    cyl_x, cyl_z0, cyl_z1 = -0.175, 0.60, 1.06

    # Frame: standing breech, top strap over the cylinder, backstrap into grip.
    box(p["Haft"], (-0.16, 0, 0.55), (0.44, 0.23, 0.13))
    box(p["Haft"], (0.15, 0, 0.83), (0.10, 0.22, 0.56))
    box(p["Haft"], (-0.16, 0, 1.06), (0.44, 0.23, 0.12))
    limb(p["Haft"], (-0.20, 0, 0.52), (-0.40, 0, 0.24), 0.135, 0.14, 7)
    limb(p["Haft"], (-0.40, 0, 0.24), (-0.54, 0, 0.04), 0.14, 0.15, 7)
    box(p["Pommel"], (-0.55, 0, 0.03), (0.16, 0.20, 0.08))
    gun_grip(p["Grip"], None, -0.33, grip, rake=52, r=0.16, half=0.22)

    # THE CYLINDER - its own object, six chambers, one lined up with the bore.
    gun_cylinder(p["Mag"], cyl_x, cyl_z0, cyl_z1, ring_r=0.175, lobe_r=0.095, plate_r=0.225)

    # Fluted barrel on its underlug, with the ejector rod.
    limb(p["Edge"], (0, 0, 1.12), (0, 0, length), 0.082, 0.075, 6)
    box(p["Edge"], (-0.10, 0, 1.42), (0.13, 0.15, 0.66))
    box(p["Head"], (0.09, 0, 1.42), (0.07, 0.11, 0.70))  # the sighting rib
    limb(p["Mag"], (cyl_x, 0, 1.06), (cyl_x, 0, 1.52), 0.035, 0.035, 5)

    # Hammer + spur off the back of the frame, and the trigger.
    box(p["Action"], (0.12, 0, 0.46), (0.11, 0.10, 0.24), Matrix.Rotation(math.radians(24), 4, "Y"))
    box(p["Action"], (0.21, 0, 0.35), (0.17, 0.09, 0.07), Matrix.Rotation(math.radians(62), 4, "Y"))
    gun_trigger(p["Guard"], p["Action"], -0.20, 0.60, drop=0.19, half_z=0.14)

    gun_post(p["Sight"], length - 0.12, 0.10, 0.10, width=0.05, y=0.05)
    box(p["Sight"], (0.16, 0, 0.60), (0.09, 0.12, 0.06))

    for s in (-1, 1):
        box(p["Glow"], (0.05, s * 0.12, 1.42), (0.05, 0.03, 0.44))
    gun_muzzle(p["Muzzle"], length)
    return gun_finish(name, p)


# ---------------------------------------------------------------- Thunderhead Cannon
# A hand cannon: an oversized bore in a reinforced ring frame, a break-open
# chamber block (the shell = _Mag), an outsized hammer, a lanyard ring at the
# butt, and everything half again as thick as it should be.


def build_thunderheadcannon():
    name = "ThunderheadCannon"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = gun_bms()

    # Heavy breech frame and the grip frame under it.
    box(p["Haft"], (-0.10, 0, 0.68), (0.52, 0.34, 0.62))
    limb(p["Haft"], (-0.24, 0, 0.50), (-0.46, 0, 0.20), 0.16, 0.16, 7)
    limb(p["Haft"], (-0.46, 0, 0.20), (-0.58, 0, 0.05), 0.16, 0.17, 7)
    box(p["Pommel"], (-0.59, 0, 0.04), (0.18, 0.24, 0.10))
    gun_grip(p["Grip"], None, -0.34, grip, rake=30, r=0.19, half=0.26)

    # The chamber block: the loaded shell, separable for the break-open reload.
    limb(p["Mag"], (0, 0, 0.60), (0, 0, 0.98), 0.20, 0.195, 8)
    gun_band(p["Mag"], 0.58, 0.25, 0.07)

    # Oversized bore: a thick barrel through three reinforcing rings.
    limb(p["Edge"], (0, 0, 0.96), (0, 0, length - 0.14), 0.185, 0.17, 8)
    limb(p["Edge"], (0, 0, length - 0.14), (0, 0, length), 0.20, 0.235, 8)
    for z in (1.24, 1.60, 1.96):
        gun_band(p["Spike"], z, 0.235, 0.08)

    # Hammer, trigger, lanyard ring, blocky irons.
    box(p["Action"], (0.16, 0, 0.36), (0.13, 0.13, 0.28), Matrix.Rotation(math.radians(20), 4, "Y"))
    box(p["Action"], (0.26, 0, 0.24), (0.18, 0.11, 0.08), Matrix.Rotation(math.radians(60), 4, "Y"))
    gun_trigger(p["Guard"], p["Action"], -0.26, 0.66, drop=0.22, half_z=0.16, width=0.13)
    gun_ring(p["Spike"], -0.62, 0.12, 0.09, 0.03, seg=6)
    box(p["Sight"], (0.26, 0, 0.98), (0.12, 0.13, 0.07))
    gun_post(p["Sight"], length - 0.30, 0.16, 0.12, width=0.06, y=0.07)

    # Storm core in the breech, and the bore lit.
    for s in (-1, 1):
        box(p["Glow"], (-0.10, s * 0.18, 0.70), (0.20, 0.04, 0.30))
    ellipsoid(p["Glow"], (0, 0, length - 0.03), (0.13, 0.13, 0.05), subdiv=0)
    gun_muzzle(p["Muzzle"], length)
    return gun_finish(name, p)


# ---------------------------------------------------------------- Grave Blunderbuss
# The bell is the whole point: a full wooden stock, brass bands up a stubby
# barrel, and then the muzzle opening out into a trumpet three times the
# barrel's width. Flintlock on the flank, ramrod under (the reload part).


def build_graveblunderbuss():
    name = "GraveBlunderbuss"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = gun_bms()

    # Full wooden stock: butt, comb, wrist, belly, forend.
    box(p["Haft"], (-0.32, 0, 0.20), (0.68, 0.29, 0.40))
    box(p["Haft"], (-0.26, 0, 0.62), (0.52, 0.26, 0.52))
    box(p["Haft"], (-0.22, 0, 1.02), (0.40, 0.23, 0.42))
    box(p["Haft"], (-0.13, 0, 1.36), (0.30, 0.27, 0.52))
    box(p["Haft"], (-0.16, 0, 1.96), (0.26, 0.25, 0.80))
    box(p["Pommel"], (-0.32, 0, 0.03), (0.70, 0.29, 0.09))

    box(p["Head"], (-0.02, 0, 1.32), (0.28, 0.27, 0.46))  # the breech

    # Barrel, then the bell.
    limb(p["Edge"], (0, 0, 1.44), (0, 0, 2.28), 0.118, 0.105, 8)
    limb(p["Edge"], (0, 0, 2.28), (0, 0, length), 0.105, 0.34, 10)
    gun_band(p["Spike"], length - 0.03, 0.365, 0.07, sides=10)
    for z in (1.58, 1.92, 2.22):
        gun_band(p["Spike"], z, 0.135, 0.06)

    # Flintlock on the flank, ramrod under the barrel.
    gun_flintlock(p["Head"], p["Action"], 1.30, x=0.02, side=1.0, scale=1.05)
    limb(p["Mag"], (-0.17, 0, 1.56), (-0.17, 0, 2.42), 0.03, 0.03, 4)
    box(p["Mag"], (-0.17, 0, 2.45), (0.05, 0.07, 0.07))

    gun_trigger(p["Guard"], p["Action"], -0.24, 1.12)
    gun_wrist(p["Grip"], -0.20, grip, rake=12, r=0.16, half=0.28)
    gun_post(p["Sight"], 1.56, 0.12, 0.09, width=0.05, y=0.05)
    gun_muzzle(p["Muzzle"], length)
    return gun_finish(name, p)


# ---------------------------------------------------------------- Basalt Scattergun
# A sawn-off double: two barrels side by side with a rib between them, a cut
# stock and a stubby forend, the break-open top lever and twin triggers. The
# barrel group is _Mag - break it open and it swings away as one piece.


def build_basaltscattergun():
    name = "BasaltScattergun"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = gun_bms()

    # Cut stock.
    box(p["Haft"], (-0.30, 0, 0.17), (0.58, 0.27, 0.34))
    box(p["Haft"], (-0.25, 0, 0.50), (0.46, 0.25, 0.38))
    box(p["Haft"], (-0.21, 0, 0.80), (0.36, 0.23, 0.34))
    box(p["Pommel"], (-0.30, 0, 0.03), (0.60, 0.27, 0.09))

    # Receiver / standing breech, and the hinge pin the barrels break on.
    box(p["Head"], (-0.06, 0, 1.08), (0.38, 0.30, 0.46))
    limb(p["Head"], (-0.13, -0.19, 1.30), (-0.13, 0.19, 1.30), 0.05, 0.05, 6)

    # THE BARREL GROUP (_Mag): two bores side by side, the rib, the lump.
    for s in (-1, 1):
        limb(p["Mag"], (0, s * 0.13, 1.14), (0, s * 0.155, length), 0.115, 0.11, 8)
        limb(p["Mag"], (0, s * 0.155, length - 0.07), (0, s * 0.155, length), 0.135, 0.135, 8)
    box(p["Mag"], (0.155, 0, 1.90), (0.07, 0.14, 1.46))  # top rib, PROUD of both bores
    box(p["Mag"], (-0.145, 0, 1.86), (0.06, 0.13, 1.36))  # under-rib
    box(p["Mag"], (0, 0, length - 0.03), (0.24, 0.40, 0.06))  # the twin muzzle face
    box(p["Mag"], (-0.09, 0, 1.36), (0.12, 0.30, 0.30))  # the lump
    for z in (1.72, 2.24):
        box(p["Mag"], (0, 0, z), (0.22, 0.36, 0.07))

    # Stubby forend under the barrels.
    box(p["Haft"], (-0.17, 0, 1.60), (0.19, 0.37, 0.44))

    # Break lever on top, twin triggers, guard.
    box(p["Action"], (0.16, 0, 1.02), (0.10, 0.07, 0.26))
    box(p["Guard"], (-0.30, 0, 0.98), (0.06, 0.11, 0.44))
    box(p["Guard"], (-0.16, 0, 1.20), (0.24, 0.11, 0.06))
    box(p["Guard"], (-0.16, 0, 0.76), (0.24, 0.11, 0.06))
    for s in (-1, 1):
        box(p["Action"], (-0.19, s * 0.045, 0.98 + s * 0.09), (0.13, 0.04, 0.07), Matrix.Rotation(math.radians(22), 4, "Y"))

    gun_wrist(p["Grip"], -0.20, grip, rake=12, r=0.16, half=0.26)
    box(p["Sight"], (0.13, 0, 2.46), (0.08, 0.07, 0.07))
    for s in (-1, 1):
        stroke(p["Glow"], (-0.02, s * 0.16, 1.10), 0.26, 0)
    gun_muzzle(p["Muzzle"], length)
    return gun_finish(name, p)


# ---------------------------------------------------------------- Bogwood Bow
# A braced recurve seen along the arrow: the limbs span ACROSS the bore (+-x),
# curving back toward the archer and flicking forward again at the tips; the
# string runs tip to tip; the riser is a block across the middle with the hide
# grip wrapped round it; the nocked arrow lies on the rest at x = 0 and its
# head is the muzzle.


def build_bogwoodbow():
    name = "BogwoodBow"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = gun_bms()

    riser_z = grip
    tip_x, tip_z = 1.20, 0.12
    flick = Vector((0.11, 0, 0.20))

    # The riser: a block spanning x, thin along the bore, with the arrow shelf.
    box(p["Haft"], (-0.05, 0, riser_z), (0.62, 0.17, 0.26))
    box(p["Haft"], (-0.02, 0, riser_z + 0.16), (0.30, 0.15, 0.10))

    # Both limbs: from the riser out to the tips, bending back toward the archer.
    tips = []
    for s in (-1, 1):
        pts = []
        for i in range(5):
            t = i / 4
            x = s * (0.28 + (tip_x - 0.28) * t)
            z = riser_z - (riser_z - tip_z) * (t ** 1.7)
            r = 0.085 - 0.042 * t
            pts.append((Vector((x, 0, z)), r))
        for (a, ra), (b, rb) in zip(pts, pts[1:]):
            limb(p["Haft"], a, b, ra, rb, 5)
        end = pts[-1][0]
        flick_end = end + Vector((s * flick.x, 0, flick.z))
        cone(p["Spike"], end, flick_end, 0.042, 4)
        tips.append(flick_end)

    # The string, tip to tip, with the serving at the nocking point.
    limb(p["Action"], tips[0], tips[1], 0.021, 0.021, 4)
    box(p["Action"], (0, 0, tips[0].z), (0.05, 0.05, 0.13))

    # The nocked arrow: shaft, bone head at z = LENGTH, fletching at the nock.
    nock_z = tips[0].z - 0.05
    limb(p["Mag"], (0, 0, nock_z), (0, 0, length - 0.20), 0.03, 0.028, 4)
    cone(p["Mag"], (0, 0, length - 0.20), (0, 0, length), 0.062, 4)
    for s in (-1, 1):
        box(p["Mag"], (s * 0.055, 0, nock_z + 0.20), (0.11, 0.02, 0.20), Matrix.Rotation(math.radians(-s * 14), 4, "Y"))
    box(p["Mag"], (0, 0.055, nock_z + 0.20), (0.02, 0.11, 0.20))

    # Hide grip wrapped round the riser; its centre IS the hand point.
    a = Vector((-0.02, 0, riser_z))
    b = Vector((-0.34, 0, riser_z))
    limb(p["Grip"], a, b, 0.135, 0.125, 7)

    # Arrow rest nub and a bone sight pin off the riser's up side.
    box(p["Sight"], (-0.02, 0.09, riser_z + 0.20), (0.07, 0.09, 0.05))
    gun_post(p["Sight"], riser_z + 0.14, 0.26, 0.12, width=0.05, y=0.05)
    gun_muzzle(p["Muzzle"], length)
    return gun_finish(name, p)


# ---------------------------------------------------------------- Gatorjaw Crossbow
# A rifle stock with a bolt channel down its top rail, the scute-plated lath
# spanning +-y near the muzzle, the string drawn back into the claw, gator
# teeth studding the fore-stock and a wisp for a sight.


def build_gatorjawcrossbow():
    name = "GatorjawCrossbow"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = gun_bms()

    # Stock: butt, comb, the long body out to the nose.
    box(p["Haft"], (-0.28, 0, 0.18), (0.52, 0.24, 0.36))
    box(p["Haft"], (-0.22, 0, 0.56), (0.42, 0.22, 0.44))
    box(p["Haft"], (-0.12, 0, 1.62), (0.30, 0.24, 1.72))
    box(p["Haft"], (-0.10, 0, 2.60), (0.24, 0.22, 0.30))
    box(p["Pommel"], (-0.28, 0, 0.03), (0.54, 0.24, 0.09))

    # The bolt channel: two rail walls on top, the bolt riding between them.
    for s in (-1, 1):
        box(p["Haft"], (0.06, s * 0.10, 2.02), (0.14, 0.05, 1.44))

    # The lath: scute arms spanning +-y just behind the nose, swept forward.
    for s in (-1, 1):
        limb(p["Edge"], (0, 0, 2.44), (0, s * 0.62, 2.33), 0.085, 0.070, 5)
        limb(p["Edge"], (0, s * 0.62, 2.33), (0, s * 1.20, 2.09), 0.070, 0.038, 5)
        for yy in (0.30, 0.62, 0.92):
            box(p["Spike"], (0.02, s * yy, 2.44 - yy * 0.30), (0.11, 0.16, 0.11))

    # The string drawn back into the nut, and the claw that holds it.
    for s in (-1, 1):
        limb(p["Action"], (0, s * 1.20, 2.09), (0, s * 0.03, 1.56), 0.022, 0.022, 4)
    box(p["Action"], (0.04, 0, 1.52), (0.16, 0.22, 0.16))
    box(p["Head"], (-0.18, 0, 1.44), (0.22, 0.22, 0.30))  # the bog-iron lock

    # The loaded bolt: rides the channel, head exactly at z = LENGTH.
    limb(p["Mag"], (0, 0, 1.58), (0, 0, length - 0.16), 0.032, 0.028, 4)
    cone(p["Mag"], (0, 0, length - 0.16), (0, 0, length), 0.055, 4)
    for s in (-1, 1):
        box(p["Mag"], (0.02 + s * 0.045, 0, 1.72), (0.09, 0.02, 0.16))

    # Gator teeth studding the fore-stock flanks.
    for s in (-1, 1):
        for z in (1.90, 2.14):
            cone(p["Spike"], (-0.06, s * 0.11, z), (-0.10, s * 0.30, z + 0.06), 0.045, 4)

    gun_trigger(p["Guard"], p["Action"], -0.26, 0.94)
    gun_wrist(p["Grip"], -0.20, grip, rake=12, r=0.155, half=0.26)
    box(p["Sight"], (0.16, 0, 1.72), (0.12, 0.12, 0.07))
    gun_post(p["Sight"], 2.58, 0.14, 0.11, width=0.05, y=0.05)
    gun_ring(p["Spike"], -0.40, 2.62, 0.18, 0.045, seg=6)  # the foot stirrup
    ellipsoid(p["Glow"], (0.24, 0, 1.72), (0.05, 0.05, 0.05), subdiv=0)
    gun_muzzle(p["Muzzle"], length)
    return gun_finish(name, p)


# ---------------------------------------------------------------- Abyssal Harpooner
# A speargun: a long open rail (two side walls with daylight and cross-braces
# between them) with the barbed harpoon seated in its channel, the line spool
# slung underneath, twin bands running from the muzzle yoke back to the spear's
# tail, and a pistol grip aft.


def build_abyssalharpooner():
    name = "AbyssalHarpooner"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = gun_bms()

    # The open rail: two walls, braced, with daylight down the middle.
    for s in (-1, 1):
        box(p["Haft"], (-0.14, s * 0.11, 1.72), (0.22, 0.05, 2.66))
    for z in (0.90, 1.55, 2.20, 2.85):
        box(p["Haft"], (-0.16, 0, z), (0.09, 0.27, 0.10))

    # Receiver aft and the butt.
    box(p["Head"], (-0.13, 0, 0.62), (0.34, 0.27, 0.62))
    box(p["Haft"], (-0.18, 0, 0.20), (0.26, 0.24, 0.42))
    box(p["Pommel"], (-0.18, 0, 0.04), (0.32, 0.25, 0.10))

    # The harpoon seated in the channel, barbs swept back under the head.
    limb(p["Spike"], (0, 0, 0.52), (0, 0, length - 0.20), 0.045, 0.04, 6)
    cone(p["Spike"], (0, 0, length - 0.26), (0, 0, length), 0.105, 4)
    for s in (-1, 1):
        cone(p["Spike"], (s * 0.03, 0, length - 0.16), (s * 0.24, 0, length - 0.48), 0.05, 4)
    gun_band(p["Spike"], 0.60, 0.085, 0.09, sides=6)  # the spear's tail collar

    # Muzzle yoke: two arms out in y for the bands.
    for s in (-1, 1):
        limb(p["Head"], (0, 0, length - 0.16), (0, s * 0.24, length - 0.20), 0.05, 0.045, 5)
        limb(p["Action"], (0, s * 0.24, length - 0.20), (0, s * 0.07, 0.72), 0.036, 0.036, 5)

    # The line spool under the rail: a drum on a y axis, flanged both sides.
    limb(p["Mag"], (-0.34, -0.13, 1.62), (-0.34, 0.13, 1.62), 0.19, 0.19, 9)
    for s in (-1, 1):
        limb(p["Mag"], (-0.34, s * 0.13, 1.62), (-0.34, s * 0.17, 1.62), 0.23, 0.23, 9)
    box(p["Mag"], (-0.20, 0, 1.62), (0.14, 0.09, 0.09))

    gun_grip(p["Grip"], p["Haft"], -0.32, grip, rake=20, r=0.155, drop=0.12)
    gun_trigger(p["Guard"], p["Action"], -0.28, 1.02)
    box(p["Sight"], (0.14, 0, 1.02), (0.12, 0.13, 0.07))
    gun_post(p["Sight"], 2.62, 0.10, 0.12, width=0.05, y=0.05)
    gun_muzzle(p["Muzzle"], length)
    return gun_finish(name, p)


# ---------------------------------------------------------------- Riptide SMG
# The acid test. Compact and boxy: a slab receiver barely longer than a
# forearm, a stubby barrel with a big hooded front sight, a LONG stick
# magazine dropping out of the magwell forward of the trigger, the side
# charging handle in its slot, and a wire folding stock stubbed off the back.


def build_riptidesmg():
    name = "RiptideSmg"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = gun_bms()

    # The boxy receiver, with a rib along the top.
    box(p["Head"], (-0.07, 0, 0.92), (0.34, 0.27, 0.94))
    box(p["Head"], (0.13, 0, 0.94), (0.08, 0.17, 0.82))
    box(p["Head"], (0.05, 0.16, 1.06), (0.12, 0.05, 0.26))  # ejection port

    # Stubby barrel out of a short vented jacket.
    limb(p["Edge"], (0, 0, 1.34), (0, 0, length), 0.05, 0.045, 8)
    limb(p["Edge"], (0, 0, 1.34), (0, 0, 1.62), 0.092, 0.088, 8)
    for z in (1.40, 1.50, 1.58):
        gun_band(p["Spike"], z, 0.10, 0.035)

    # Big hooded front sight, rear aperture.
    gun_post(p["Sight"], 1.76, 0.06, 0.20, width=0.06, y=0.06)
    for s in (-1, 1):
        box(p["Sight"], (0.16, s * 0.085, 1.76), (0.22, 0.035, 0.06))
    box(p["Sight"], (0.20, 0, 1.76), (0.05, 0.19, 0.05))
    box(p["Sight"], (0.17, 0, 0.52), (0.14, 0.15, 0.06))

    # The magwell and the LONG stick magazine - the read that sells it.
    box(p["Guard"], (-0.30, 0, 1.00), (0.20, 0.27, 0.34))
    gun_mag(p["Mag"], -0.38, 1.00, drop=0.86, curve=6, width=0.23, thick=0.175, segs=3)

    # Side charging handle riding its slot.
    box(p["Action"], (0.02, 0.17, 1.24), (0.10, 0.11, 0.13))
    box(p["Action"], (0.05, 0.15, 1.10), (0.06, 0.04, 0.42))

    # Wire folding stock: two rails back to a butt bar.
    for s in (-1, 1):
        limb(p["Haft"], (-0.10, s * 0.14, 0.46), (-0.17, s * 0.14, 0.08), 0.034, 0.034, 4)
    box(p["Haft"], (-0.17, 0, 0.06), (0.10, 0.34, 0.08))
    box(p["Pommel"], (-0.17, 0, 0.06), (0.12, 0.14, 0.09))

    gun_grip(p["Grip"], p["Haft"], -0.32, grip, rake=14, r=0.155, drop=0.14)
    gun_trigger(p["Guard"], p["Action"], -0.28, 0.78)
    gun_muzzle(p["Muzzle"], length)
    return gun_finish(name, p)


# ---------------------------------------------------------------- Vulkan Repeater
# The LMG: a heavy finned barrel, a carry handle arching over the receiver, the
# drum magazine slung underneath, folded bipod legs along the barrel, and a
# molten core burning through the vents.


def build_vulkanrepeater():
    name = "VulkanRepeater"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = gun_bms()

    # Shoulder stock.
    box(p["Haft"], (-0.28, 0, 0.21), (0.56, 0.27, 0.42))
    box(p["Haft"], (-0.22, 0, 0.64), (0.44, 0.25, 0.48))
    box(p["Haft"], (-0.18, 0, 1.00), (0.36, 0.23, 0.36))
    box(p["Pommel"], (-0.28, 0, 0.04), (0.58, 0.27, 0.10))

    # Heavy receiver.
    box(p["Head"], (-0.07, 0, 1.56), (0.38, 0.31, 0.92))
    box(p["Action"], (0.04, 0.20, 1.76), (0.11, 0.12, 0.17))
    box(p["Action"], (0.06, 0.17, 1.58), (0.07, 0.05, 0.44))

    # Finned barrel and the brake.
    limb(p["Edge"], (0, 0, 2.02), (0, 0, length - 0.20), 0.10, 0.085, 8)
    for i in range(6):
        gun_band(p["Spike"], 2.18 + i * 0.17, 0.16, 0.05)
    box(p["Spike"], (0, 0, length - 0.11), (0.26, 0.26, 0.24))
    limb(p["Spike"], (0, 0, length - 0.06), (0, 0, length), 0.105, 0.105, 8)

    # Carry handle over the receiver, plus the leaf sight behind it.
    for z in (1.26, 1.86):
        box(p["Sight"], (0.24, 0, z), (0.32, 0.10, 0.09))
    box(p["Sight"], (0.38, 0, 1.56), (0.09, 0.13, 0.70))
    box(p["Sight"], (0.22, 0, 2.06), (0.16, 0.13, 0.07))
    gun_post(p["Sight"], 3.10, 0.14, 0.14, width=0.05, y=0.05)

    # The drum, slung under the receiver on its feed tower.
    limb(p["Mag"], (-0.48, -0.17, 1.50), (-0.48, 0.17, 1.50), 0.33, 0.33, 10)
    for s in (-1, 1):
        limb(p["Mag"], (-0.48, s * 0.17, 1.50), (-0.48, s * 0.20, 1.50), 0.27, 0.27, 10)
    box(p["Mag"], (-0.24, 0, 1.54), (0.28, 0.22, 0.26))

    # Folded bipod stubs along the barrel.
    for s in (-1, 1):
        limb(p["Spike"], (-0.14, s * 0.10, 2.56), (-0.28, s * 0.15, 3.14), 0.045, 0.035, 4)
    box(p["Head"], (-0.14, 0, 2.50), (0.14, 0.22, 0.14))

    gun_grip(p["Grip"], p["Haft"], -0.34, grip, rake=20, r=0.17, drop=0.12)
    gun_trigger(p["Guard"], p["Action"], -0.30, 1.22, width=0.12)

    # The molten core: vents down both flanks, veins along the barrel.
    for s in (-1, 1):
        box(p["Glow"], (-0.06, s * 0.16, 1.56), (0.16, 0.04, 0.56))
        box(p["Glow"], (s * 0.15, 0, 2.60), (0.03, 0.05, 0.80))
    ellipsoid(p["Glow"], (0, 0, length - 0.02), (0.07, 0.07, 0.05), subdiv=0)
    gun_muzzle(p["Muzzle"], length)
    return gun_finish(name, p)


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
        build_heartrender(),
        build_obsidianpiercer(),
        build_magmagauntlets(),
        build_bogwoodbow(),
        build_gatorjawcrossbow(),
        build_mireflintlock(),
        build_cinderlockcarbine(),
        build_basaltscattergun(),
        build_vulkanrepeater(),
        build_rustfangmachete(),
        build_fenreaver(),
        build_icepickhatchet(),
        build_frostborerifle(),
        build_glaciermaul(),
        build_frostbiterevolver(),
        build_rimefanglance(),
        build_trenchspike(),
        build_abyssalharpooner(),
        build_riptidesmg(),
        build_voidglasssaber(),
        build_gloomcallerdmr(),
        build_boardingaxe(),
        build_graveblunderbuss(),
        build_phantomrepeater(),
        build_cutlassofthefleet(),
        build_admiralssaber(),
        build_galecleaver(),
        build_cyclonerifle(),
        build_thunderheadcannon(),
        build_stormlance(),
        build_krakenfang(),
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

    def variant_tris(objs):
        # glTF triangulates on export, so an n-gon costs n - 2 triangles.
        return sum(len(poly.vertices) - 2 for o in objs if o for poly in o.data.polygons)

    total = sum(len(o.data.polygons) for objs in groups for o in objs if o)
    named = ((next((o for o in objs if o), None), objs) for objs in groups)
    by_variant = {first.name.split("_")[0]: variant_tris(objs) for first, objs in named if first}
    print(f"[weapon_gen] exported {out_path}")
    for name in FRAME:
        tris = by_variant.get(name, 0)
        print(f"[weapon_gen]   {name}: length {FRAME[name]['length']}, grip {FRAME[name]['grip']}, tris {tris} (Weapons.luau must match)")
    print(f"[weapon_gen] weapons: {', '.join(FRAME)}; polys: {total}; tris: {sum(by_variant.values())}")

    if want_preview:
        import os

        # Beside the .glb that was asked for, so a scratch build previews to
        # scratch instead of stamping on the committed assets/weapon_preview.png.
        render_preview(groups, os.path.splitext(os.path.abspath(out_path))[0] + "_preview.png")


main()
