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
    "Heartrender_Haft": (0.36, 0.24, 0.26),
    "Heartrender_Grip": (0.23, 0.16, 0.17),
    "Heartrender_Guard": (0.36, 0.24, 0.26),
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
    "GlacierMaul_Head": (0.59, 0.77, 0.88),
    "GlacierMaul_Edge": (0.59, 0.77, 0.88),
    "GlacierMaul_Spike": (0.59, 0.77, 0.88),
    "GlacierMaul_Glow": (0.47, 0.78, 1.00),
    "FrostbiteRevolver_Haft": (0.35, 0.39, 0.45),
    "FrostbiteRevolver_Guard": (0.35, 0.39, 0.45),
    "FrostbiteRevolver_Pommel": (0.35, 0.39, 0.45),
    "FrostbiteRevolver_Grip": (0.24, 0.27, 0.32),
    "FrostbiteRevolver_Head": (0.78, 0.88, 0.94),
    "FrostbiteRevolver_Edge": (0.78, 0.88, 0.94),
    "FrostbiteRevolver_Spike": (0.78, 0.88, 0.94),
    "FrostbiteRevolver_Glow": (0.47, 0.78, 1.00),
    "RimefangLance_Haft": (0.55, 0.71, 0.82),
    "RimefangLance_Guard": (0.55, 0.71, 0.82),
    "RimefangLance_Pommel": (0.55, 0.71, 0.82),
    "RimefangLance_Grip": (0.31, 0.39, 0.49),
    "RimefangLance_Head": (0.93, 0.96, 0.99),
    "RimefangLance_Edge": (0.93, 0.96, 0.99),
    "RimefangLance_Spike": (0.93, 0.96, 0.99),
    "RimefangLance_Glow": (0.31, 0.86, 1.00),
    "Trenchspike_Haft": (0.27, 0.31, 0.36),
    "Trenchspike_Guard": (0.27, 0.31, 0.36),
    "Trenchspike_Pommel": (0.27, 0.31, 0.36),
    "Trenchspike_Grip": (0.19, 0.21, 0.26),
    "Trenchspike_Head": (0.51, 0.49, 0.56),
    "Trenchspike_Edge": (0.51, 0.49, 0.56),
    "Trenchspike_Spike": (0.51, 0.49, 0.56),
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
    "VoidglassSaber_Head": (0.26, 0.23, 0.35),
    "VoidglassSaber_Edge": (0.26, 0.23, 0.35),
    "VoidglassSaber_Spike": (0.26, 0.23, 0.35),
    "VoidglassSaber_Glow": (0.67, 0.47, 1.00),
    "GloomcallerDmr_Haft": (0.22, 0.20, 0.28),
    "GloomcallerDmr_Guard": (0.22, 0.20, 0.28),
    "GloomcallerDmr_Pommel": (0.22, 0.20, 0.28),
    "GloomcallerDmr_Grip": (0.16, 0.14, 0.21),
    "GloomcallerDmr_Head": (1.00, 0.89, 0.51),
    "GloomcallerDmr_Edge": (1.00, 0.89, 0.51),
    "GloomcallerDmr_Spike": (1.00, 0.89, 0.51),
    "GloomcallerDmr_Glow": (1.00, 0.89, 0.51),
    "BoardingAxe_Haft": (0.43, 0.38, 0.30),
    "BoardingAxe_Guard": (0.43, 0.38, 0.30),
    "BoardingAxe_Pommel": (0.43, 0.38, 0.30),
    "BoardingAxe_Grip": (0.30, 0.26, 0.21),
    "BoardingAxe_Head": (0.63, 0.66, 0.69),
    "BoardingAxe_Edge": (0.63, 0.66, 0.69),
    "BoardingAxe_Spike": (0.63, 0.66, 0.69),
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
    "CutlassOfTheFleet_Haft": (0.47, 0.53, 0.49),
    "CutlassOfTheFleet_Guard": (0.47, 0.53, 0.49),
    "CutlassOfTheFleet_Pommel": (0.47, 0.53, 0.49),
    "CutlassOfTheFleet_Grip": (0.33, 0.37, 0.35),
    "CutlassOfTheFleet_Head": (0.78, 0.84, 0.81),
    "CutlassOfTheFleet_Edge": (0.78, 0.84, 0.81),
    "CutlassOfTheFleet_Spike": (0.78, 0.84, 0.81),
    "CutlassOfTheFleet_Glow": (0.63, 1.00, 0.82),
    "AdmiralsSaber_Haft": (0.38, 0.45, 0.42),
    "AdmiralsSaber_Guard": (0.38, 0.45, 0.42),
    "AdmiralsSaber_Pommel": (0.38, 0.45, 0.42),
    "AdmiralsSaber_Grip": (0.26, 0.31, 0.30),
    "AdmiralsSaber_Head": (0.90, 0.75, 0.39),
    "AdmiralsSaber_Edge": (0.90, 0.75, 0.39),
    "AdmiralsSaber_Spike": (0.90, 0.75, 0.39),
    "AdmiralsSaber_Glow": (0.63, 1.00, 0.82),
    "Galecleaver_Haft": (0.43, 0.49, 0.55),
    "Galecleaver_Guard": (0.43, 0.49, 0.55),
    "Galecleaver_Pommel": (0.43, 0.49, 0.55),
    "Galecleaver_Grip": (0.30, 0.34, 0.39),
    "Galecleaver_Head": (0.78, 0.84, 0.89),
    "Galecleaver_Edge": (0.78, 0.84, 0.89),
    "Galecleaver_Spike": (0.78, 0.84, 0.89),
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
    "Stormlance_Haft": (0.35, 0.43, 0.59),
    "Stormlance_Guard": (0.35, 0.43, 0.59),
    "Stormlance_Pommel": (0.35, 0.43, 0.59),
    "Stormlance_Grip": (0.24, 0.30, 0.41),
    "Stormlance_Head": (0.86, 0.90, 1.00),
    "Stormlance_Edge": (0.86, 0.90, 1.00),
    "Stormlance_Spike": (0.86, 0.90, 1.00),
    "Stormlance_Glow": (0.55, 0.78, 1.00),
    "Krakenfang_Haft": (0.24, 0.17, 0.33),
    "Krakenfang_Guard": (0.24, 0.17, 0.33),
    "Krakenfang_Pommel": (0.24, 0.17, 0.33),
    "Krakenfang_Grip": (0.17, 0.13, 0.24),
    "Krakenfang_Head": (0.86, 0.82, 0.94),
    "Krakenfang_Edge": (0.86, 0.82, 0.94),
    "Krakenfang_Spike": (0.86, 0.82, 0.94),
    "Krakenfang_Glow": (0.59, 0.47, 1.00),
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
    "GlacierMaul_Glow",
    "FrostbiteRevolver_Glow",
    "RimefangLance_Glow",
    "VoidglassSaber_Glow",
    "GloomcallerDmr_Glow",
    "PhantomRepeater_Glow",
    "CutlassOfTheFleet_Glow",
    "AdmiralsSaber_Glow",
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
# A knapped stiletto: not a sword but a struck flake of glass-black obsidian -
# a long triangular point whose flanks break into conchoidal facets, still wet
# with heat down one hairline crack, socketed into brass fittings on a short
# corded handle. Brass = the Guard bmesh (the row's `color`), the collar AND
# the butt cap, so the fittings read as one metal.


def build_obsidianpiercer():
    name = "ObsidianPiercer"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    # Short handle: dark wood core, corded, brass cap and brass ferrule.
    limb(p["Haft"], (0, 0, 0.14), (0, 0, 1.2), 0.095, 0.11, 6)
    melee_grip(p["Grip"], grip, half=0.38, r=0.13, coils=5, proud=0.02)
    limb(p["Guard"], (0, 0, 0.02), (0, 0, 0.16), 0.145, 0.135, 6)
    limb(p["Guard"], (0, 0, 1.2), (0, 0, 1.38), 0.15, 0.17, 6)
    # Two stubby brass quillons swept up along the point.
    for s in (-1, 1):
        box(p["Guard"], (s * 0.19, 0, 1.36), (0.26, 0.12, 0.09), Matrix.Rotation(math.radians(-s * 26), 4, "Y"))

    # The point itself: six twisted triangular rings to an apex at the tip.
    knapped_point(p["Edge"], 1.36, length, 0.24, 0.035, segs=6, twist=46.0)
    # Struck flakes lying back along the blade, not standing off it.
    for x, y, z, rr in ((0.19, 0.05, 1.56, 0.065), (-0.18, -0.05, 1.86, 0.06), (0.14, -0.06, 2.22, 0.05)):
        cone(p["Spike"], (x, y, z), (x * 0.4, y * 0.5, z + 0.5), rr, sides=3)

    # The crack of heat: three offset segments, never quite a straight line.
    for z, dx in ((1.75, 0.03), (2.35, -0.02), (2.9, 0.02)):
        box(p["Glow"], (dx, 0, z), (0.025, 0.15, 0.46))
    ellipsoid(p["Glow"], (0, 0, 1.46), (0.09, 0.07, 0.08), subdiv=0)

    return melee_finish(name, p)


# ---------------------------------------------------------------- Magma Gauntlets (volcano epic)
# Worn, not swung: a plated vambrace up the forearm (the hand closes inside it
# at the grip), a flared wrist cuff, then the business end - a blocky armoured
# fist with a ridge of knuckle domes, three sulfur-cured talons curling forward
# off the knuckles to the tip, and magma running in the seams between every
# plate. The only piece in the pack whose silhouette is an arm.


def build_magmagauntlets():
    name = "MagmaGauntlets"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    # Forearm: an elbow cuff and four overlapping lames, each stepped out
    # further than the last and raked, so the arm reads as plate not a post.
    box(p["Haft"], (-0.02, 0, 0.11), (0.36, 0.44, 0.22))
    for i, z in enumerate((0.32, 0.56, 0.8, 1.02)):
        w = 0.32 + 0.035 * i
        box(p["Haft"], (0.015 * i, 0, z), (w, w + 0.16, 0.26))
        box(p["Guard"], (0.015 * i + w * 0.5, 0, z + 0.09), (0.1, w + 0.12, 0.07))  # the lame's lip
    # Vent slots out the flanks.
    for s in (-1, 1):
        box(p["Spike"], (0.08, s * 0.24, 0.7), (0.3, 0.06, 0.32), Matrix.Rotation(math.radians(14), 4, "Y"))

    # The hand closes inside the vambrace: scale binding on the hand point.
    melee_grip(p["Grip"], grip, half=0.28, r=0.15, coils=3, proud=0.02)

    # Flared wrist cuff, then the fist: a block with three curled finger bars.
    limb(p["Guard"], (0, 0, 1.18), (0, 0, 1.36), 0.36, 0.3, 8)
    box(p["Haft"], (0.08, 0, 1.68), (0.74, 0.58, 0.56))
    for z in (1.5, 1.68, 1.86):
        box(p["Guard"], (0.4, 0, z), (0.18, 0.54, 0.13))
    # Knuckle ridge: four domes standing off the top of the fist.
    for y in (-0.19, -0.065, 0.065, 0.19):
        ellipsoid(p["Guard"], (0.26, y, 1.99), (0.18, 0.06, 0.13), subdiv=0)

    # Three talons off the knuckles, fanned in the x-z plane as well as across
    # the knuckles - one thrown far forward, one to the tip, one held upright -
    # so the claw reads as three claws from any angle.
    for y, reach, out in ((-0.2, 2.96, 0.74), (0.0, length, 0.5), (0.2, 2.82, 0.26)):
        pts = [(0.18, y, 1.96), (0.3, y * 1.2, 2.34), (out * 0.85, y * 1.35, (2.34 + reach) / 2 + 0.1), (out, y * 1.45, reach - 0.18)]
        for (x0, y0, z0), (x1, y1, z1), r0, r1 in zip(pts, pts[1:], (0.15, 0.11, 0.075), (0.11, 0.075, 0.05)):
            limb(p["Edge"], (x0, y0, z0), (x1, y1, z1), r0, r1, 5)
        cone(p["Spike"], pts[-1], (out + 0.1, y * 1.5, reach), 0.045, sides=4)

    # Magma in every seam: between the lames, round the cuff, across the
    # knuckles, at the talon roots.
    for i, z in enumerate((0.43, 0.69, 0.95, 1.19)):
        box(p["Glow"], (0.04 * i, 0, z), (0.42 + 0.05 * i, 0.56, 0.05))
    limb(p["Glow"], (0, 0, 1.38), (0, 0, 1.44), 0.31, 0.29, 8)
    box(p["Glow"], (0.24, 0, 1.86), (0.16, 0.54, 0.06))
    for y, x in ((-0.2, 0.34), (0.0, 0.28), (0.2, 0.22)):
        box(p["Glow"], (x, y, 2.16), (0.13, 0.13, 0.22))

    return melee_finish(name, p)


# ---------------------------------------------------------------- Rustfang Machete (swamp rare)
# A working fen-cutter that the bog has been eating: a broad forward-weighted
# blade whose cutting edge is bitten ragged in three places, rust scabs on the
# flats, a bent iron ferrule with a single dropped quillon, a gator-hide bound
# grip on a bone tang - and someone's fishhook still snagged on a cord under
# the guard.


def build_rustfangmachete():
    name = "RustfangMachete"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    limb(p["Haft"], (0, 0, 0.13), (0, 0, 1.1), 0.115, 0.10, 6)
    melee_grip(p["Grip"], grip, half=0.38, r=0.135, coils=4)
    box(p["Pommel"], (0, 0, 0.07), (0.30, 0.24, 0.14))

    # Bent ferrule with one quillon dropped over the edge side.
    limb(p["Guard"], (0, 0, 1.06), (0, 0, 1.22), 0.17, 0.16, 6)
    box(p["Guard"], (0.21, 0, 1.12), (0.36, 0.15, 0.10), Matrix.Rotation(math.radians(-30), 4, "Y"))

    # The blade, drawn point by point rather than swept: a long near-parallel
    # working blade, spine dead straight until it rakes into the tip, and two
    # bites chewed clean out of the cutting edge at 2.10 and 2.66.
    slab(
        p["Edge"],
        [
            (0.14, 1.2),
            (0.27, 1.62),
            (0.31, 2.04),
            (0.19, 2.12),
            (0.32, 2.24),
            (0.34, 2.58),
            (0.21, 2.68),
            (0.35, 2.8),
            (0.37, 3.02),
            (0.29, 3.18),
            (0.06, length),
            (-0.06, 3.14),
            (-0.1, 2.8),
            (-0.11, 2.1),
            (-0.1, 1.2),
        ],
        0.05,
    )

    # Rust scabs standing proud of both flats.
    for x, y, z, rx, rz in ((0.06, 0.07, 1.9, 0.10, 0.13), (-0.02, -0.07, 2.3, 0.08, 0.11), (0.2, 0.07, 2.62, 0.09, 0.12), (0.16, -0.07, 3.0, 0.07, 0.10)):
        ellipsoid(p["Spike"], (x, y, z), (rx, 0.035, rz), subdiv=0)

    # The snagged fishhook, hung off the ferrule on a cord out the spine side
    # so it breaks the silhouette (never in _Grip - that part's centre is the
    # hand point).
    hook = ((-0.16, 1.16), (-0.3, 0.94), (-0.32, 0.76), (-0.2, 0.66))
    for (x0, z0), (x1, z1), r in zip(hook, hook[1:], (0.02, 0.033, 0.03)):
        limb(p["Spike"], (x0, -0.08, z0), (x1, -0.08, z1), r, r * 0.9, 4)
    cone(p["Spike"], (-0.2, -0.08, 0.66), (-0.15, -0.08, 0.86), 0.028, sides=4)

    return melee_finish(name, p)


# ---------------------------------------------------------------- Fenreaver (swamp legendary)
# The fen tyrant's reaver: a long forward-swept claw of a blade that hooks out
# past the haft, its inner edge lit wisp-green with sap, trophy teeth hung off
# the back, and a guard of live root tendrils curling up out of the bogwood
# shaft to hold the blade in.


def build_fenreaver():
    name = "Fenreaver"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    limb(p["Haft"], (0, 0, 0.14), (0, 0, 1.82), 0.13, 0.11, 6)
    for z in (1.05, 1.5):
        ellipsoid(p["Haft"], (0.06, 0, z), (0.11, 0.10, 0.09), subdiv=0)
    melee_grip(p["Grip"], grip, half=0.5, r=0.15, coils=5)
    ellipsoid(p["Pommel"], (0, 0, 0.13), (0.19, 0.19, 0.15), subdiv=0)

    # Root-tendril guard: four roots curling up and out of the socket.
    limb(p["Guard"], (0, 0, 1.7), (0, 0, 1.94), 0.17, 0.15, 7)
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        a = (dx * 0.13, dy * 0.13, 1.86)
        b = (dx * 0.34, dy * 0.34, 2.06)
        c = (dx * 0.4, dy * 0.4, 2.36)
        limb(p["Guard"], a, b, 0.062, 0.05, 5)
        limb(p["Guard"], b, c, 0.05, 0.03, 5)

    # The hook: swept hard toward +x, narrowing to a point out past the shaft.
    def spine(t):
        return -0.18 + 1.15 * t**1.8

    def edge(t):
        return 0.28 + 1.02 * t**1.6

    slab(p["Edge"], edge_profile(1.95, length, spine, edge, steps=8), 0.06)

    # Trophy teeth hung along the blade's back, pointing away from the swing.
    for t in (0.18, 0.36, 0.54, 0.72):
        z = 1.95 + (length - 1.95) * t
        x = spine(t)
        cone(p["Spike"], (x, 0, z), (x - 0.3, 0, z - 0.22), 0.065, sides=4)
    for s in (-1, 1):
        cone(p["Spike"], (0, s * 0.14, 1.72), (0, s * 0.2, 1.48), 0.05, sides=4)

    # Sap: a lit line just inside the cutting edge, and two beads in the roots.
    for i in range(8):
        t = 0.04 + i * 0.125
        z = 1.95 + (length - 1.95) * t
        box(p["Glow"], (edge(t) - 0.05, 0, z), (0.07, 0.075, 0.2))
    for dx in (0.32, -0.32):
        ellipsoid(p["Glow"], (dx, 0, 2.2), (0.06, 0.06, 0.07), subdiv=0)

    return melee_finish(name, p)


# ---------------------------------------------------------------- Icepick Hatchet (ice uncommon)
# Half tool, half temper: the shortest thing on the rack. A compact bearded
# bit whose beard hangs below the eye, a long pick spike out the back for the
# ice, a haft wrapped its whole length, and a leather thong looped through the
# butt so it can hang off a belt.


def build_icepickhatchet():
    name = "IcepickHatchet"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    limb(p["Haft"], (0, 0, 0.05), (0, 0, 2.3), 0.10, 0.085, 6)
    melee_grip(p["Grip"], grip, half=0.45, r=0.13, coils=5)

    # Butt cap and the thong loop above it.
    box(p["Pommel"], (0, 0, 0.05), (0.22, 0.20, 0.10))
    loop = ((0.11, 0.14), (0.0, 0.30), (-0.11, 0.14))
    for (x0, z0), (x1, z1) in zip(loop, loop[1:]):
        limb(p["Pommel"], (x0, 0, z0), (x1, 0, z1), 0.022, 0.022, 4)

    # The eye, wedged onto the haft.
    box(p["Head"], (0, 0, 2.05), (0.30, 0.26, 0.48))
    box(p["Head"], (0.06, 0, 1.76), (0.22, 0.22, 0.14))

    # Bearded bit: the beard hooks down past the eye, the edge is a hard
    # straight-ish arc on +x, the top corner squared off.
    slab(p["Edge"], [(0.10, 1.84), (0.30, 1.72), (0.46, 1.52), (0.56, 1.76), (0.72, 2.02), (0.80, 2.28), (0.72, 2.52), (0.48, 2.6), (0.10, 2.5)], 0.05)

    # Pick spike out the poll, its underside serrated, and the haft's cap.
    cone(p["Spike"], (-0.16, 0, 2.1), (-0.98, 0, 2.36), 0.12, sides=5)
    for x, z in ((-0.44, 2.14), (-0.64, 2.2)):
        cone(p["Spike"], (x, 0, z), (x - 0.08, 0, z - 0.16), 0.045, sides=4)
    cone(p["Spike"], (0, 0, 2.3), (0, 0, length), 0.095, sides=5)

    return melee_finish(name, p)


# ---------------------------------------------------------------- Glacier Maul (ice rare)
# The heaviest silhouette in the pack: a squared slab of blue everice strapped
# to a whalebone haft with two iron bands, its core lit along a cross seam,
# icicles hanging off the underside of the head and a vertebra knob for a butt.


def build_glaciermaul():
    name = "GlacierMaul"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    # Whalebone haft with knuckle swellings.
    limb(p["Haft"], (0, 0, 0.16), (0, 0, 3.5), 0.15, 0.12, 6)
    for z in (1.35, 2.15, 2.95):
        ellipsoid(p["Haft"], (0, 0, z), (0.19, 0.19, 0.12), subdiv=0)
    melee_grip(p["Grip"], grip, half=0.55, r=0.18, coils=4, proud=0.03)

    # Vertebra pommel: a knob with two wings.
    box(p["Pommel"], (0, 0, 0.10), (0.34, 0.34, 0.18))
    for s in (-1, 1):
        box(p["Pommel"], (0, s * 0.24, 0.14), (0.16, 0.16, 0.10))

    # The head: crossed blocks, so the slab reads faceted, not like a crate.
    box(p["Head"], (0, 0, 3.74), (1.02, 0.64, 0.90))
    box(p["Head"], (0, 0, 3.74), (1.14, 0.48, 0.70))
    box(p["Head"], (0, 0, 3.74), (0.84, 0.74, 0.74))
    box(p["Head"], (0.1, 0, 4.06), (0.66, 0.5, 0.34), Matrix.Rotation(math.radians(16), 4, "Y"))

    # Socket collar and the two iron bands strapping the ice on.
    limb(p["Guard"], (0, 0, 3.24), (0, 0, 3.44), 0.24, 0.22, 8)
    for z in (3.5, 3.98):
        box(p["Guard"], (0, 0, z), (1.18, 0.7, 0.09))

    # Icicles hanging off the underside, and shards off the shoulders.
    for x, y, drop in ((0.44, 0.16, 0.52), (-0.4, -0.14, 0.42), (0.12, -0.24, 0.62), (-0.14, 0.24, 0.36)):
        cone(p["Spike"], (x, y, 3.3), (x + 0.04, y, 3.3 - drop), 0.09, sides=4)
    for s in (-1, 1):
        cone(p["Spike"], (s * 0.5, 0, 4.0), (s * 0.74, 0, 4.14), 0.09, sides=4)

    # The core: a cross seam of light, standing proud of every face of the
    # slab so it reads from the front, the flat and the top.
    box(p["Glow"], (0, 0, 3.74), (1.2, 0.78, 0.12))
    box(p["Glow"], (0, 0, 3.74), (1.18, 0.14, 0.8))
    box(p["Glow"], (0, 0, 3.74), (0.14, 0.78, 0.94))

    return melee_finish(name, p)


# ---------------------------------------------------------------- Rimefang Lance (ice legendary)
# The serpent's own fang socketed on a frozen keel-spar: a square-section spar
# with a keel fin running its length, a barbed socket where the fang is bound
# in, and above that a long elegant tooth that tapers in width AND thickness to
# a needle, one vein of cold light in its core.


def build_rimefanglance():
    name = "RimefangLance"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    # Keel-spar: square section (limb, 4 sides) with a fin down the flats.
    limb(p["Haft"], (0, 0, 0.1), (0, 0, 3.1), 0.14, 0.105, 4)
    box(p["Haft"], (0, 0, 1.9), (0.07, 0.30, 2.0))
    melee_grip(p["Grip"], grip, half=0.5, r=0.16, coils=4)
    box(p["Pommel"], (0, 0, 0.09), (0.26, 0.26, 0.18))

    # The socket the fang is bound into.
    limb(p["Guard"], (0, 0, 3.02), (0, 0, 3.36), 0.20, 0.17, 7)
    limb(p["Guard"], (0, 0, 3.3), (0, 0, 3.4), 0.22, 0.22, 7)
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        cone(p["Spike"], (dx * 0.15, dy * 0.15, 3.3), (dx * 0.46, dy * 0.46, 2.98), 0.06, sides=4)

    # The fang.
    lofted_blade(
        p["Edge"],
        [
            (0.0, 3.32, 0.21, 0.15),
            (0.02, 3.7, 0.19, 0.13),
            (0.07, 4.05, 0.15, 0.10),
            (0.14, 4.32, 0.10, 0.065),
            (0.2, 4.5, 0.05, 0.035),
            (0.24, length, 0.012, 0.01),
        ],
    )

    # The vein of cold running up the fang's core.
    for x, z, h in ((0.01, 3.55, 0.4), (0.04, 3.9, 0.34), (0.1, 4.18, 0.24)):
        box(p["Glow"], (x, 0, z), (0.06, 0.31, h))

    return melee_finish(name, p)


# ---------------------------------------------------------------- Trenchspike (gloom uncommon)
# No frills, and that is the point: a pressure-forged chitin pick grown in one
# ribbed taper, bowing forward so the point leads, its flanges alternating like
# a crab's leg. Short, dependable, nothing on it that could snag.


def build_trenchspike():
    name = "Trenchspike"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    limb(p["Haft"], (0, 0, 0.08), (0, 0, 1.25), 0.13, 0.155, 6)
    melee_grip(p["Grip"], grip, half=0.45, r=0.165, coils=3, proud=0.035)
    box(p["Pommel"], (0, 0, 0.07), (0.24, 0.24, 0.12))
    cone(p["Pommel"], (-0.06, 0, 0.13), (-0.3, 0, 0.06), 0.08, sides=4)
    limb(p["Guard"], (0, 0, 1.22), (0, 0, 1.32), 0.185, 0.18, 7)

    # The body: six ribs, each a barrel that swells and pinches again, bowing
    # forward as it tapers - one grown piece, like a crab's leg.
    def body(t):
        return (0.2 * t * t, 0, 1.28 + 1.44 * t), 0.185 - 0.115 * t

    for i in range(6):
        t0, t1 = i / 6, (i + 1) / 6
        tm = (t0 + t1) / 2
        (a, ra), (m, rm), (b, rb) = body(t0), body(tm), body(t1)
        limb(p["Head"], a, m, ra, rm * 1.26, 6)
        limb(p["Head"], m, b, rm * 1.26, rb, 6)

    # The point, and three barbs down the back.
    cone(p["Spike"], (0.2, 0, 2.7), (0.26, 0, length), 0.08, sides=5)
    for t in (0.3, 0.55, 0.8):
        (x, _y, z), r = body(t)
        cone(p["Spike"], (x - r, 0, z), (x - r - 0.24, 0, z - 0.18), 0.05, sides=4)

    return melee_finish(name, p)


# ---------------------------------------------------------------- Voidglass Saber (gloom epic)
# Black past black: a paper-thin crescent that curves almost a quarter turn,
# with only a wafer of a guard and a hairline of light along the cutting edge
# to say where the blade actually is. The thinnest silhouette in the pack.


def build_voidglasssaber():
    name = "VoidglassSaber"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    limb(p["Haft"], (0, 0, 0.18), (0, 0, 1.28), 0.085, 0.095, 6)
    melee_grip(p["Grip"], grip, half=0.44, r=0.115, coils=5, proud=0.018)
    cone(p["Pommel"], (0, 0, 0.22), (0, 0, 0.0), 0.11, sides=6)

    # A wafer of a guard: a thin disc and two whisker prongs.
    limb(p["Guard"], (0, 0, 1.3), (0, 0, 1.36), 0.26, 0.26, 8)
    for s in (-1, 1):
        limb(p["Guard"], (0, s * 0.2, 1.33), (0, s * 0.36, 1.24), 0.03, 0.02, 4)

    def spine(t):
        return 1.06 * t**1.95

    def edge(t):
        return 0.2 + 1.06 * t**1.8

    slab(p["Edge"], edge_profile(1.38, length, spine, edge, steps=8), 0.028)

    # The hairline: a lit strip laid along the cutting edge itself.
    for i in range(7):
        t = 0.06 + i * 0.14
        z = 1.38 + (length - 1.38) * t
        box(p["Glow"], (edge(t) - 0.02, 0, z), (0.035, 0.07, 0.28), Matrix.Rotation(math.radians(-30), 4, "Y"))

    return melee_finish(name, p)


# ---------------------------------------------------------------- Boarding Axe (wreck uncommon)
# Navy pattern, straight off a wreck: a bearded head with a square poll spike
# for cracking hatches, iron langets strapping it down the haft, rope wound the
# length of the grip, and barnacles growing on the cheek and the shaft.


def build_boardingaxe():
    name = "BoardingAxe"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    limb(p["Haft"], (0, 0, 0.08), (0, 0, 3.02), 0.105, 0.095, 6)
    melee_grip(p["Grip"], grip, half=0.48, r=0.135, coils=7, proud=0.03)
    box(p["Pommel"], (0, 0, 0.06), (0.24, 0.24, 0.12))
    limb(p["Pommel"], (0, 0, 0.16), (0, 0, 0.24), 0.14, 0.13, 6)

    # Langets: two iron straps down the flats from under the head.
    for s in (-1, 1):
        box(p["Guard"], (0, s * 0.115, 2.5), (0.20, 0.04, 0.86))

    box(p["Head"], (0, 0, 2.86), (0.3, 0.26, 0.56))
    # Bearded bit: the beard hooks down and back under the eye, the edge is a
    # long shallow crescent, the top corner squared.
    slab(p["Edge"], [(0.12, 2.44), (0.46, 1.96), (0.6, 2.36), (0.86, 2.62), (0.98, 2.88), (0.9, 3.14), (0.62, 3.3), (0.34, 3.1), (0.12, 3.06)], 0.055)

    # Square poll spike, the haft's spike cap, and the barnacle crust.
    cone(p["Spike"], (-0.16, 0, 2.92), (-0.86, 0, 3.06), 0.11, sides=4)
    cone(p["Spike"], (0, 0, 3.14), (0, 0, length), 0.08, sides=5)
    for c, out, r in (
        ((0.34, 0.06, 2.72), (0.1, 1, 0.1), 0.1),
        ((0.5, -0.06, 2.9), (0.1, -1, 0), 0.08),
        ((0.22, 0.06, 3.06), (0, 1, 0.2), 0.07),
        ((0.09, 0, 1.9), (1, 0.2, 0), 0.08),
        ((-0.09, 0, 2.24), (-1, 0.3, 0), 0.07),
    ):
        barnacle(p["Spike"], c, out, r)

    return melee_finish(name, p)


# ---------------------------------------------------------------- Cutlass of the Fleet (wreck epic)
# The fleet's sidearm: a broad, mildly curved blade with a clipped point, and
# the tell - a full basket, a shell dish on the flat plus a knuckle bow sweeping
# from the crossblock all the way down to the pommel. Ghost-fire filigree burns
# in the shell and down the fuller.


def build_cutlassofthefleet():
    name = "CutlassOfTheFleet"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    limb(p["Haft"], (0, 0, 0.14), (0, 0, 1.24), 0.10, 0.11, 6)
    melee_grip(p["Grip"], grip, half=0.4, r=0.14, coils=5)
    ellipsoid(p["Pommel"], (0, 0, 0.12), (0.17, 0.17, 0.15), subdiv=0)
    box(p["Pommel"], (0, 0, 0.24), (0.2, 0.2, 0.08))

    # Crossblock, knuckle bow down to the pommel, and the shell dish.
    box(p["Guard"], (0, 0, 1.3), (0.52, 0.22, 0.13))
    bow = ((0.3, 1.3), (0.44, 1.02), (0.42, 0.7), (0.26, 0.44), (0.05, 0.3))
    for (x0, z0), (x1, z1) in zip(bow, bow[1:]):
        limb(p["Guard"], (x0, 0, z0), (x1, 0, z1), 0.05, 0.05, 5)
    for z, w in ((0.94, 0.5), (1.14, 0.66), (1.32, 0.54)):
        box(p["Guard"], (0.04, -0.27, z), (w, 0.05, 0.22))
    for z in (0.86, 1.42):
        limb(p["Guard"], (-0.26, -0.28, z), (0.32, -0.28, z), 0.04, 0.04, 4)

    def spine(t):
        return -0.2 + 0.5 * t**1.8

    def edge(t):
        return 0.34 + 0.56 * t - 0.56 * t * t

    slab(p["Edge"], edge_profile(1.38, length, spine, edge, steps=8), 0.06)
    # A false edge clipped back off the point.
    cone(p["Spike"], (0.1, 0, 3.34), (0.28, 0, length), 0.07, sides=4)

    # Ghost-fire: filigree in the shell, then a burning fuller up both flats.
    for z, a in ((1.02, 24), (1.18, -18), (1.34, 12)):
        stroke(p["Glow"], (0.02, -0.3, z), 0.34, a, thickness=0.035, width=0.06)
    for i in range(5):
        t = 0.1 + i * 0.19
        z = 1.38 + (length - 1.38) * t
        x = (spine(t) + edge(t)) / 2
        for s in (-1, 1):
            stroke(p["Glow"], (x, s * 0.065, z), 0.05, 0, thickness=0.035, width=0.3)

    return melee_finish(name, p)


# ---------------------------------------------------------------- Admiral's Saber (wreck legendary)
# The officer's blade, and it knows it: longer and far slimmer than the fleet
# cutlass, a gilt D-guard with a quillon curling back off the block, wire wound
# fine round the grip, a pennant tassel swinging off the pommel and a spectral
# line burning the whole length of the edge.


def build_admiralssaber():
    name = "AdmiralsSaber"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    limb(p["Haft"], (0, 0, 0.2), (0, 0, 1.3), 0.085, 0.10, 6)
    melee_grip(p["Grip"], grip, half=0.42, r=0.125, coils=6, proud=0.018)
    ellipsoid(p["Pommel"], (0, 0, 0.18), (0.14, 0.14, 0.16), subdiv=0)
    box(p["Pommel"], (0, 0, 0.06), (0.2, 0.2, 0.09))

    # Gilt D-guard: crossblock, knuckle bow, and a quillon curling back.
    box(p["Guard"], (0, 0, 1.34), (0.44, 0.18, 0.10))
    bow = ((0.24, 1.34), (0.4, 1.05), (0.36, 0.68), (0.18, 0.4), (0.02, 0.28))
    for (x0, z0), (x1, z1) in zip(bow, bow[1:]):
        limb(p["Guard"], (x0, 0, z0), (x1, 0, z1), 0.04, 0.04, 5)
    quillon = ((-0.2, 1.34), (-0.36, 1.16), (-0.34, 0.98))
    for (x0, z0), (x1, z1) in zip(quillon, quillon[1:]):
        limb(p["Guard"], (x0, 0, z0), (x1, 0, z1), 0.045, 0.038, 5)

    def spine(t):
        return -0.11 + 0.3 * t**1.7

    def edge(t):
        return 0.17 + 0.44 * t - 0.36 * t * t

    slab(p["Edge"], edge_profile(1.42, length, spine, edge, steps=8), 0.045)

    # The pennant tassel, hung beside the pommel (not in _Grip).
    ellipsoid(p["Spike"], (0, -0.16, 0.56), (0.07, 0.06, 0.07), subdiv=0)
    for i, dx in enumerate((-0.06, 0.0, 0.06)):
        box(p["Spike"], (dx, -0.16, 0.34), (0.05, 0.035, 0.42), Matrix.Rotation(math.radians(6 - i * 6), 4, "Y"))

    # Spectral fire down the edge, brightest at the point.
    for i in range(7):
        t = 0.06 + i * 0.14
        z = 1.42 + (length - 1.42) * t
        box(p["Glow"], (edge(t) - 0.03, 0, z), (0.05, 0.055, 0.3))
    ellipsoid(p["Glow"], (edge(1.0) - 0.02, 0, length - 0.08), (0.05, 0.05, 0.1), subdiv=0)

    return melee_finish(name, p)


# ---------------------------------------------------------------- Galecleaver (maelstrom uncommon)
# Storm-worn and cut for the wind: a broad cleaver body with a chipped edge,
# then daylight - a slot right through the blade, bridged by one spar - and
# above it a raked fin that trails the swing. Pitted all over from flying grit.


def build_galecleaver():
    name = "Galecleaver"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    limb(p["Haft"], (0, 0, 0.12), (0, 0, 1.68), 0.12, 0.105, 6)
    melee_grip(p["Grip"], grip, half=0.52, r=0.145, coils=5)
    box(p["Pommel"], (0, 0, 0.08), (0.26, 0.12, 0.16))
    box(p["Pommel"], (-0.16, 0, 0.22), (0.24, 0.06, 0.14), Matrix.Rotation(math.radians(34), 4, "Y"))

    # Collar with two wing fins, so the haft already reads as swept.
    box(p["Guard"], (0, 0, 1.72), (0.44, 0.22, 0.14))
    for s in (-1, 1):
        box(p["Guard"], (s * 0.3, 0, 1.78), (0.34, 0.06, 0.1), Matrix.Rotation(math.radians(-s * 25), 4, "Y"))

    # The blade: a long cleaver edge on +x with a chip out of it at 2.88, the
    # point raked forward off a drawn-back top corner, and a wind slot cut as a
    # deep wedge into the spine so the gust goes through instead of shoving.
    slab(
        p["Edge"],
        [
            (0.1, 1.84),
            (0.52, 1.92),
            (0.66, 2.3),
            (0.7, 2.76),
            (0.58, 2.88),  # the chip
            (0.72, 3.04),
            (0.78, 3.3),
            (0.62, length),  # the raked point
            (0.34, 3.5),
            (0.08, 3.24),
            (-0.22, 3.14),  # the wind slot: back edge, apex, back edge
            (0.3, 3.0),
            (-0.22, 2.86),
            (-0.24, 2.3),
            (-0.1, 1.88),
        ],
        0.065,
    )
    # A reinforcing rib low on the spine, and grit pits over both flats.
    box(p["Head"], (-0.14, 0, 2.24), (0.14, 0.17, 0.72), Matrix.Rotation(math.radians(-8), 4, "Y"))
    for x, y, z, r in ((0.44, 0.075, 2.2, 0.09), (0.56, -0.075, 2.6, 0.07), (0.3, 0.075, 3.3, 0.07), (0.5, -0.075, 3.5, 0.05)):
        ellipsoid(p["Spike"], (x, y, z), (r, 0.03, r * 1.2), subdiv=0)

    return melee_finish(name, p)


# ---------------------------------------------------------------- Stormlance (maelstrom epic)
# A conductor, not a spear: copper wound in nine turns up the shaft between two
# insulator discs, and at the top a collector head - a central rod with four
# forked vanes splayed off it, charge standing in the gaps between the vane tips
# and the rod.


def build_stormlance():
    name = "Stormlance"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    limb(p["Haft"], (0, 0, 0.1), (0, 0, 3.56), 0.115, 0.095, 6)
    melee_grip(p["Grip"], grip, half=0.5, r=0.15, coils=4)
    box(p["Pommel"], (0, 0, 0.08), (0.24, 0.24, 0.16))
    ellipsoid(p["Pommel"], (0, 0, 0.24), (0.13, 0.13, 0.1), subdiv=0)

    # Insulator discs bracketing the winding.
    for z in (1.48, 3.42):
        limb(p["Guard"], (0, 0, z - 0.05), (0, 0, z + 0.05), 0.2, 0.2, 8)
    # Nine turns of wire, each leaning the same way, so it reads as one winding
    # rather than a zigzag. (Nine, not ten: the tenth put it over 700 tris.)
    for i in range(9):
        coil_band(p["Spike"], 1.64 + i * 0.21, 0.17, tilt=0.03, thick=0.055)

    # Collector head: socket, central rod to the tip.
    limb(p["Head"], (0, 0, 3.56), (0, 0, 3.96), 0.19, 0.15, 7)
    limb(p["Head"], (0, 0, 3.96), (0, 0, 4.36), 0.09, 0.05, 6)
    cone(p["Head"], (0, 0, 4.36), (0, 0, length), 0.05, sides=5)
    # Four forked vanes splayed off the socket and turning back up.
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        limb(p["Spike"], (dx * 0.13, dy * 0.13, 3.9), (dx * 0.42, dy * 0.42, 4.14), 0.055, 0.04, 5)
        limb(p["Spike"], (dx * 0.42, dy * 0.42, 4.14), (dx * 0.34, dy * 0.34, 4.44), 0.04, 0.028, 5)

    # The charge: beads on the vane tips, arcs jumping in to the rod, a ring at
    # the socket and sparks caught in the winding.
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        ellipsoid(p["Glow"], (dx * 0.34, dy * 0.34, 4.46), (0.06, 0.06, 0.06), subdiv=0)
        box(p["Glow"], (dx * 0.19, dy * 0.19, 4.42), (0.3 if dx else 0.05, 0.3 if dy else 0.05, 0.04))
    limb(p["Glow"], (0, 0, 3.7), (0, 0, 3.8), 0.2, 0.2, 6)
    box(p["Glow"], (0, 0, 2.55), (0.36, 0.36, 0.06))

    return melee_finish(name, p)


# ---------------------------------------------------------------- Krakenfang (maelstrom legendary)
# The Maw's own tooth, torn out root and all: a wrinkled root for a butt, a
# tentacle grown round it for a grip with sucker scars down both flats, a gum
# collar, and then one enormous curved fang - thick as a wrist at the root,
# needle at the point - with the Maw's light still moving in its veins.


def build_krakenfang():
    name = "Krakenfang"
    length, grip = FRAME[name]["length"], FRAME[name]["grip"]
    p = melee_bms()

    # The root: a wrinkled taper with growth rings.
    limb(p["Haft"], (0, 0, 0.12), (0, 0, 1.58), 0.2, 0.15, 6)
    for z in (0.3, 1.15, 1.42):
        limb(p["Haft"], (0, 0, z - 0.04), (0, 0, z + 0.04), 0.21, 0.21, 6)
    ellipsoid(p["Pommel"], (0, 0, 0.12), (0.22, 0.22, 0.14), subdiv=0)

    # Grip: the tentacle sleeve, sucker discs symmetric on both flats so the
    # part's centre stays on the hand point.
    limb(p["Grip"], (0, 0, grip - 0.5), (0, 0, grip + 0.5), 0.17, 0.17, 7)
    for s in (-1, 1):
        for z in (grip - 0.3, grip, grip + 0.3):
            limb(p["Grip"], (0, s * 0.15, z), (0, s * 0.22, z), 0.055, 0.045, 6)

    # The gum collar the fang comes out of, with a ragged lip.
    limb(p["Guard"], (0, 0, 1.55), (0, 0, 1.76), 0.26, 0.22, 7)
    for dx, dy in ((0.18, 0.1), (-0.16, 0.12), (0.02, -0.2)):
        box(p["Guard"], (dx, dy, 1.8), (0.12, 0.12, 0.12))

    stations = [
        (0.0, 1.7, 0.32, 0.24),
        (0.04, 2.1, 0.31, 0.23),
        (0.12, 2.55, 0.28, 0.2),
        (0.24, 3.0, 0.24, 0.16),
        (0.4, 3.45, 0.18, 0.12),
        (0.58, 3.85, 0.11, 0.075),
        (0.76, 4.2, 0.05, 0.035),
        (0.88, length, 0.012, 0.01),
    ]
    lofted_blade(p["Edge"], stations)

    # Hook barbs off the fang's back, and denticles round the root.
    for x, z, w, _t in ((0.06, 2.3, 0.3, 0), (0.17, 2.75, 0.26, 0), (0.32, 3.2, 0.21, 0)):
        cone(p["Spike"], (x - w, 0, z), (x - w - 0.3, 0, z - 0.2), 0.06, sides=4)
    for dx, dy in ((0.2, 0.14), (-0.2, 0.12), (0.0, -0.22)):
        cone(p["Spike"], (dx, dy, 1.88), (dx * 1.5, dy * 1.5, 2.06), 0.05, sides=4)

    # The veins: light following the curve up the fang, pooled at the root.
    for x, z, w, t in stations[:6]:
        box(p["Glow"], (x, 0, z + 0.12), (w * 0.5, t * 2.2, 0.22), Matrix.Rotation(math.radians(-16), 4, "Y"))
    ellipsoid(p["Glow"], (0, 0, 1.86), (0.13, 0.13, 0.14), subdiv=0)

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
