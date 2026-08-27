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
    # Frostmaw Reach hostiles (island 3).
    "FrostbitePup_Body": (0.82, 0.85, 0.88),
    "FrostbitePup_Fins": (0.60, 0.66, 0.72),
    "FrostbitePup_Eyes": (0.05, 0.05, 0.06),
    "FrostbitePup_Marks": (0.65, 0.80, 0.92),
    "IceshardCrab_Body": (0.55, 0.68, 0.78),
    "IceshardCrab_Fins": (0.75, 0.88, 0.95),
    "IceshardCrab_Eyes": (0.05, 0.05, 0.06),
    "IceshardCrab_Marks": (0.60, 0.90, 1.0),
    "GlacialLurker_Body": (0.58, 0.66, 0.74),
    "GlacialLurker_Fins": (0.42, 0.52, 0.62),
    "GlacialLurker_Eyes": (0.70, 0.95, 1.0),
    "GlacialLurker_Marks": (0.55, 0.85, 1.0),
    "IceveinPike_Body": (0.45, 0.56, 0.66),
    "IceveinPike_Fins": (0.35, 0.45, 0.55),
    "IceveinPike_Eyes": (0.05, 0.05, 0.06),
    "IceveinPike_Marks": (0.55, 0.90, 1.0),
    "FrozenMariner_Body": (0.50, 0.58, 0.60),
    "FrozenMariner_Fins": (0.65, 0.78, 0.86),
    "FrozenMariner_Eyes": (0.70, 0.95, 1.0),
    "FrozenMariner_Marks": (0.60, 0.85, 0.95),
    "AuroraJelly_Body": (0.75, 0.82, 0.90),
    "AuroraJelly_Fins": (0.60, 0.70, 0.85),
    "AuroraJelly_Eyes": (0.05, 0.05, 0.06),
    "AuroraJelly_Marks": (0.50, 0.95, 0.80),
    "BlizzardWraith_Body": (0.80, 0.86, 0.92),
    "BlizzardWraith_Fins": (0.62, 0.70, 0.80),
    "BlizzardWraith_Eyes": (0.55, 0.85, 1.0),
    "BlizzardWraith_Marks": (0.70, 0.90, 1.0),
    # Gloomtrench hostiles (island 5).
    "GulperEel_Body": (0.20, 0.20, 0.26),
    "GulperEel_Fins": (0.28, 0.28, 0.36),
    "GulperEel_Eyes": (0.85, 0.90, 0.95),
    "GulperEel_Marks": (0.50, 0.80, 1.0),
    "FlashbulbSquid_Body": (0.45, 0.35, 0.45),
    "FlashbulbSquid_Fins": (0.35, 0.27, 0.36),
    "FlashbulbSquid_Eyes": (0.06, 0.06, 0.07),
    "FlashbulbSquid_Marks": (1.0, 0.95, 0.75),
    "TrenchSkitterer_Body": (0.30, 0.28, 0.32),
    "TrenchSkitterer_Fins": (0.40, 0.37, 0.42),
    "TrenchSkitterer_Eyes": (0.75, 0.85, 0.90),
    "TrenchSkitterer_Marks": (0.45, 0.60, 0.70),
    "LanternjawAngler_Body": (0.18, 0.16, 0.22),
    "LanternjawAngler_Fins": (0.24, 0.21, 0.28),
    "LanternjawAngler_Eyes": (0.85, 0.88, 0.95),
    "LanternjawAngler_Marks": (1.0, 0.90, 0.55),
    "VampireSquid_Body": (0.35, 0.15, 0.18),
    "VampireSquid_Fins": (0.25, 0.10, 0.14),
    "VampireSquid_Eyes": (1.0, 0.35, 0.30),
    "VampireSquid_Marks": (0.60, 0.30, 0.50),
    "PressureCrab_Body": (0.35, 0.33, 0.36),
    "PressureCrab_Fins": (0.45, 0.42, 0.44),
    "PressureCrab_Eyes": (0.80, 0.85, 0.85),
    "PressureCrab_Marks": (0.55, 0.60, 0.65),
    "VoidRay_Body": (0.12, 0.11, 0.17),
    "VoidRay_Fins": (0.18, 0.16, 0.24),
    "VoidRay_Eyes": (0.80, 0.85, 0.95),
    "VoidRay_Marks": (0.55, 0.50, 1.0),
    "SiltStalker_Body": (0.42, 0.38, 0.32),
    "SiltStalker_Fins": (0.32, 0.29, 0.25),
    "SiltStalker_Eyes": (0.90, 0.85, 0.60),
    "SiltStalker_Marks": (0.60, 0.55, 0.42),
    # Wreckwater hostiles (island 6).
    "CannonballCrab_Body": (0.22, 0.22, 0.25),
    "CannonballCrab_Fins": (0.50, 0.36, 0.26),
    "CannonballCrab_Eyes": (0.05, 0.05, 0.06),
    "CannonballCrab_Marks": (1.0, 0.70, 0.30),
    "DrownedBoatswain_Body": (0.42, 0.50, 0.44),
    "DrownedBoatswain_Fins": (0.50, 0.42, 0.30),
    "DrownedBoatswain_Eyes": (0.50, 1.0, 0.85),
    "DrownedBoatswain_Marks": (0.45, 0.90, 0.75),
    "PhantomMoray_Body": (0.55, 0.65, 0.65),
    "PhantomMoray_Fins": (0.40, 0.52, 0.52),
    "PhantomMoray_Eyes": (0.50, 1.0, 0.85),
    "PhantomMoray_Marks": (0.45, 0.90, 0.75),
    "CursedChest_Body": (0.40, 0.28, 0.18),
    "CursedChest_Fins": (0.45, 0.32, 0.20),
    "CursedChest_Eyes": (0.90, 0.30, 0.25),
    "CursedChest_Marks": (0.85, 0.90, 0.45),
    "PlunderSprite_Body": (0.40, 0.75, 0.65),
    "PlunderSprite_Fins": (0.30, 0.55, 0.50),
    "PlunderSprite_Eyes": (1.0, 0.85, 0.40),
    "PlunderSprite_Marks": (1.0, 0.85, 0.40),
    "GhostfireJelly_Body": (0.55, 0.75, 0.70),
    "GhostfireJelly_Fins": (0.40, 0.60, 0.56),
    "GhostfireJelly_Eyes": (0.05, 0.06, 0.06),
    "GhostfireJelly_Marks": (0.45, 1.0, 0.75),
    "WailingGunner_Body": (0.35, 0.33, 0.36),
    "WailingGunner_Fins": (0.50, 0.62, 0.60),
    "WailingGunner_Eyes": (0.50, 1.0, 0.85),
    "WailingGunner_Marks": (0.45, 0.90, 0.75),
    # Blackmire Fen hostiles (island 2).
    "CroakjawToad_Body": (0.35, 0.45, 0.28),
    "CroakjawToad_Fins": (0.28, 0.36, 0.22),
    "CroakjawToad_Eyes": (0.95, 0.80, 0.30),
    "CroakjawToad_Marks": (0.75, 0.85, 0.50),
    "MireLeech_Body": (0.30, 0.22, 0.25),
    "MireLeech_Fins": (0.40, 0.30, 0.32),
    "MireLeech_Eyes": (0.05, 0.05, 0.05),
    "MireLeech_Marks": (0.55, 0.65, 0.45),
    "SnagtoothGator_Body": (0.30, 0.38, 0.26),
    "SnagtoothGator_Fins": (0.24, 0.30, 0.20),
    "SnagtoothGator_Eyes": (0.95, 0.75, 0.30),
    "SnagtoothGator_Marks": (0.75, 0.72, 0.55),
    "SunkenTrapper_Body": (0.36, 0.30, 0.22),
    "SunkenTrapper_Fins": (0.42, 0.35, 0.25),
    "SunkenTrapper_Eyes": (0.90, 0.85, 0.40),
    "SunkenTrapper_Marks": (0.50, 0.80, 0.55),
    "FenSerpent_Body": (0.28, 0.40, 0.30),
    "FenSerpent_Fins": (0.22, 0.32, 0.24),
    "FenSerpent_Eyes": (0.95, 0.85, 0.40),
    "FenSerpent_Marks": (0.65, 0.90, 0.35),
    "PeatRevenant_Body": (0.25, 0.22, 0.16),
    "PeatRevenant_Fins": (0.35, 0.30, 0.20),
    "PeatRevenant_Eyes": (0.55, 0.90, 0.60),
    "PeatRevenant_Marks": (0.55, 0.90, 0.60),
    # The Maelstrom hostiles (island 7).
    "GalestreakFlyingfish_Body": (0.45, 0.55, 0.65),
    "GalestreakFlyingfish_Fins": (0.60, 0.70, 0.80),
    "GalestreakFlyingfish_Eyes": (0.05, 0.05, 0.06),
    "GalestreakFlyingfish_Marks": (0.80, 0.90, 1.0),
    "RiptideBarracuda_Body": (0.50, 0.58, 0.62),
    "RiptideBarracuda_Fins": (0.40, 0.46, 0.52),
    "RiptideBarracuda_Eyes": (0.05, 0.05, 0.06),
    "RiptideBarracuda_Marks": (0.25, 0.30, 0.35),
    "CycloneRay_Body": (0.30, 0.34, 0.44),
    "CycloneRay_Fins": (0.40, 0.44, 0.55),
    "CycloneRay_Eyes": (0.80, 0.88, 0.95),
    "CycloneRay_Marks": (0.60, 0.85, 1.0),
    "WhirlpoolHorror_Body": (0.28, 0.32, 0.38),
    "WhirlpoolHorror_Fins": (0.36, 0.40, 0.48),
    "WhirlpoolHorror_Eyes": (0.90, 0.85, 0.50),
    "WhirlpoolHorror_Marks": (0.50, 0.80, 0.95),
    "TempestRevenant_Body": (0.35, 0.38, 0.45),
    "TempestRevenant_Fins": (0.28, 0.30, 0.36),
    "TempestRevenant_Eyes": (0.75, 0.85, 1.0),
    "TempestRevenant_Marks": (0.75, 0.85, 1.0),
    "ThunderlanceMarlin_Body": (0.30, 0.40, 0.55),
    "ThunderlanceMarlin_Fins": (0.40, 0.50, 0.65),
    "ThunderlanceMarlin_Eyes": (0.05, 0.05, 0.06),
    "ThunderlanceMarlin_Marks": (0.70, 0.85, 1.0),
    "StormcallerDjinn_Body": (0.30, 0.33, 0.42),
    "StormcallerDjinn_Fins": (0.24, 0.26, 0.34),
    "StormcallerDjinn_Eyes": (0.80, 0.90, 1.0),
    "StormcallerDjinn_Marks": (0.75, 0.85, 1.0),
    "KrakenSpawn_Body": (0.22, 0.17, 0.26),
    "KrakenSpawn_Fins": (0.32, 0.22, 0.32),
    "KrakenSpawn_Eyes": (1.0, 0.80, 0.30),
    "KrakenSpawn_Marks": (0.40, 0.90, 0.90),
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
    # Ice: cold light. Gloom: everything that shines down there is a lure or
    # a warning. Wreck: ghost-fire.
    "IceveinPike_Marks",
    "FrozenMariner_Marks",
    "FrozenMariner_Eyes",
    "GlacialLurker_Eyes",
    "AuroraJelly_Marks",
    "BlizzardWraith_Marks",
    "BlizzardWraith_Eyes",
    "GulperEel_Marks",
    "FlashbulbSquid_Marks",
    "LanternjawAngler_Marks",
    "VampireSquid_Eyes",
    "VoidRay_Marks",
    "CannonballCrab_Marks",
    "DrownedBoatswain_Eyes",
    "DrownedBoatswain_Marks",
    "PhantomMoray_Marks",
    "CursedChest_Marks",
    "CursedChest_Eyes",
    "PlunderSprite_Marks",
    "PlunderSprite_Eyes",
    "GhostfireJelly_Marks",
    "WailingGunner_Marks",
    "WailingGunner_Eyes",
    # Fen: wisp-light and venom. Maelstrom: everything crackles.
    "CroakjawToad_Marks",
    "SunkenTrapper_Marks",
    "SunkenTrapper_Eyes",
    "FenSerpent_Marks",
    "PeatRevenant_Marks",
    "PeatRevenant_Eyes",
    "CycloneRay_Marks",
    "WhirlpoolHorror_Marks",
    "TempestRevenant_Marks",
    "TempestRevenant_Eyes",
    "ThunderlanceMarlin_Marks",
    "StormcallerDjinn_Marks",
    "StormcallerDjinn_Eyes",
    "KrakenSpawn_Marks",
    "KrakenSpawn_Eyes",
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


# ---------------------------------------------------------------- Starter Cove drowned: local kit
# The two Cove drowned (Deckhand, Angler) are built on their OWN anatomy rather
# than zombie_base: they need an asymmetric stride, a flared coat and welded
# gear that the shared blocky base cannot express. Everything private to them is
# prefixed _cove_ so the shared helpers stay frozen.


def _cove_blade(bm, pts, half_w, half_t, taper=0.35):
    """A flat steel blade through a polyline - broad in the swing plane, thin
    across it, drawn to a point at the last node. Cutlass blades, gaff spurs
    and hook barbs: anything that must read as edged metal in silhouette."""
    pts = [Vector(p) for p in pts]
    n = len(pts) - 1
    rings = []
    for i, p in enumerate(pts):
        d = (pts[min(i + 1, n)] - pts[max(i - 1, 0)]).normalized()
        if i == n:
            rings.append(bm.verts.new(p))
            continue
        up = Vector((0, 0, 1)) if abs(d.z) < 0.9 else Vector((1, 0, 0))
        thick = d.cross(up).normalized()  # across the blade (thin)
        wide = thick.cross(d).normalized()  # in the swing plane (broad)
        w = half_w * (1.0 - taper * (i / max(n, 1)))
        rings.append([bm.verts.new(p + wide * (w * sw) + thick * (half_t * st)) for sw, st in ((1, -1), (1, 1), (-1, 1), (-1, -1))])
    connect_rings(bm, rings)


def _cove_kelp(bm, start, drops, drift=(0.07, 0.0, -0.42), r=0.06):
    """A trailing kelp/weed strand: segments that lengthen and thin as they
    hang. Returns the tip so a float or a second strand can hang off it."""
    p = Vector(start)
    for i in range(drops):
        nxt = p + Vector(drift) * (1.0 + 0.15 * i)
        limb(bm, p, nxt, r * (1 - 0.2 * i), r * (1 - 0.2 * (i + 1)), 4)
        p = nxt
    return p


def _cove_barnacles(bm, center, normal, count=4, r=0.11, spread=0.22):
    """A crusted barnacle cluster: little truncated cones growing along
    `normal` off a patch of shoulder, skull or plank."""
    c, n = Vector(center), Vector(normal).normalized()
    up = Vector((0, 0, 1)) if abs(n.z) < 0.9 else Vector((1, 0, 0))
    u = n.cross(up).normalized()
    v = n.cross(u).normalized()
    for i in range(count):
        a = (i / count) * TAU + 0.4
        rr = r * (0.6 + 0.4 * ((i * 5) % 3) / 2.0)
        base = c + (u * math.cos(a) + v * math.sin(a)) * spread * (0.45 + 0.55 * (i % 2))
        limb(bm, base, base + n * rr * 1.5, rr, rr * 0.5, 5)


def _cove_net(bm, corners, rows=2, cols=3, r=0.035, sag=0.3, bow=0.0, segs=4):
    """A draped fishing net patch over four corners (c0-c1 the top edge,
    c3-c2 the bottom): strands both ways, sagging under their own weight
    (`sag`) and bellying out over whatever they are lying on (`bow`, along
    +X). Without the bow a flat patch of straight strands reads as scaffold,
    not as net - it has to bulge to look like cloth."""
    c0, c1, c2, c3 = (Vector(c) for c in corners)

    def at(u, v):
        p = c0.lerp(c1, u).lerp(c3.lerp(c2, u), v)
        belly = math.sin(math.pi * u) * math.sin(math.pi * v)
        return p + Vector((bow * belly, 0, -sag * math.sin(math.pi * u) * v))

    for j in range(rows + 1):
        v = j / rows
        for i in range(segs):
            limb(bm, at(i / segs, v), at((i + 1) / segs, v), r, r, 3)
    for i in range(cols + 1):
        u = i / cols
        for j in range(rows):
            limb(bm, at(u, j / rows), at(u, (j + 1) / rows), r, r, 3)
    return at


def _cove_jhook(bm, base, forward, size=0.16, r=0.035):
    """A small stitched-in J hook: a straight shank that curls back on itself
    to a barbed point. `forward` is the way the shank hangs."""
    b, f = Vector(base), Vector(forward).normalized()
    up = Vector((0, 0, 1)) if abs(f.z) < 0.9 else Vector((1, 0, 0))
    side = f.cross(up).normalized()
    curl = side.cross(f).normalized()
    a = b + f * size * 2.2
    limb(bm, b, a, r, r * 0.85, 4)
    c = a + f * size * 0.7 + curl * size * 0.9
    d = a + curl * size * 1.7 - f * size * 0.3
    limb(bm, a, c, r * 0.85, r * 0.7, 4)
    _cove_blade(bm, [c, d], r * 1.6, r * 0.5, taper=0.0)


# ---------------------------------------------------------------- drowned deckhand
# A waterlogged deckhand lost mid-watch: hunched into an asymmetric stride, one
# arm thrown forward (+X), a rusted cutlass swept back in the trailing hand, a
# torn knee-length watch-coat and a fishing net dragged across one shoulder,
# floats still knotted into it. One leg walked its boot off long ago.
# Layers: _Body flesh + bone + barnacles; _Fins coat, boot, net, cutlass;
# _Marks kept minimal (he is a Common) - kelp and a faint barnacle glow line.


def build_deckhand():
    body = bmesh.new()  # flesh + bone
    fins = bmesh.new()  # coat, boot, net, cutlass
    eyes = bmesh.new()
    marks = bmesh.new()  # kelp + a thin barnacle glow line

    lean = Matrix.Rotation(-0.30, 4, "Y")  # hunched harder than the old base

    # --- Stride: the +Y leg planted forward in a boot, the -Y leg trailing and
    # picked clean to the bone below a torn trouser.
    limb(fins, (0.10, 0.34, 1.52), (0.34, 0.36, 0.80), 0.23, 0.19, 6)
    limb(fins, (0.34, 0.36, 0.80), (0.46, 0.36, 0.26), 0.19, 0.15, 6)
    box(fins, (0.34, 0.36, 0.32), (0.32, 0.48, 0.30))  # boot cuff
    box(fins, (0.56, 0.36, 0.11), (0.66, 0.42, 0.24))  # sea boot
    limb(fins, (-0.06, -0.34, 1.52), (-0.30, -0.34, 0.94), 0.22, 0.16, 6)
    ellipsoid(body, (-0.30, -0.34, 0.94), (0.13, 0.12, 0.13), 1)  # bare knee
    limb(body, (-0.30, -0.34, 0.92), (-0.52, -0.33, 0.14), 0.10, 0.075, 5)  # tibia
    limb(body, (-0.26, -0.28, 0.90), (-0.44, -0.26, 0.16), 0.065, 0.05, 4)  # fibula
    for sy in (-0.13, 0.0, 0.13):
        limb(body, (-0.50, -0.33 + sy * 0.5, 0.10), (-0.28, -0.33 + sy, 0.05), 0.055, 0.035, 4)  # splayed bones of the foot

    # --- Torso: lean and gaunt, ribs showing where the shirt has rotted open.
    box(body, (0.14, 0, 2.14), (0.70, 0.76, 1.24), lean)
    box(body, (0.26, 0, 2.72), (0.52, 0.66, 0.40), lean)  # collar bones
    for z in (2.52, 2.34):
        box(body, (0.30, 0, z), (0.42, 0.72, 0.07), lean)  # exposed rib bands

    # --- Watch-coat: a fitted upper and a knee-length skirt, hem torn to tabs.
    # Cut narrow: next to the angler's bell of oilskin he must read as a rake.
    box(fins, (0.18, 0, 2.42), (0.76, 0.82, 0.96), lean)
    revolve(fins, [(-0.50, 0.60), (0.10, 0.50), (0.62, 0.44)], sides=8, axis="z", center=(0.06, 0, 1.62), squash=0.92)
    for k in range(5):
        a = (k / 5) * TAU + 0.3
        p = Vector((0.06 + math.cos(a) * 0.52, math.sin(a) * 0.56, 1.14))
        cone(fins, p, p + Vector((0.04, 0, -0.36 - 0.12 * (k % 2))), 0.14, 3)  # torn hem tabs
    box(fins, (0.30, 0, 2.86), (0.44, 0.88, 0.24), lean)  # popped collar
    for sy in (-1, 1):
        plate(fins, [(0.18, 2.96), (0.46, 2.86), (0.40, 2.30), (0.16, 2.42)], 0.08, "xz", (0, sy * 0.34, 0))  # lapels

    # --- Arms: the +Y arm thrown forward and clawing, the -Y arm swung back
    # with the cutlass.
    limb(body, (0.20, 0.54, 2.66), (0.86, 0.60, 2.40), 0.18, 0.15, 6)
    limb(body, (0.86, 0.60, 2.40), (1.52, 0.50, 2.22), 0.15, 0.11, 6)
    limb(fins, (0.16, 0.56, 2.70), (0.92, 0.60, 2.40), 0.27, 0.19, 6)  # sleeve
    ellipsoid(body, (1.58, 0.49, 2.19), (0.17, 0.15, 0.16), 1)
    for k in (-1, 0, 1):
        limb(body, (1.66, 0.49 + k * 0.09, 2.20), (2.00, 0.49 + k * 0.16, 2.30 - abs(k) * 0.12), 0.055, 0.03, 4)
    limb(body, (0.12, -0.56, 2.64), (0.36, -0.76, 2.02), 0.18, 0.15, 6)
    limb(body, (0.36, -0.76, 2.02), (0.14, -0.92, 1.48), 0.15, 0.115, 6)
    limb(fins, (0.08, -0.58, 2.68), (0.40, -0.78, 2.06), 0.27, 0.20, 6)  # sleeve
    grip = Vector((0.12, -0.96, 1.38))
    ellipsoid(body, grip, (0.16, 0.14, 0.16), 1)

    # --- The rusted cutlass, swung back and OUT of the trailing fist: away from
    # the body on -Y as well as up, so the blade silhouettes clear of the coat
    # from every angle instead of hiding behind his back.
    hd = Vector((-0.52, -0.42, 0.74)).normalized()
    pommel = grip - hd * 0.30
    guard = grip + hd * 0.28
    limb(fins, pommel, guard, 0.065, 0.065, 5)
    ellipsoid(fins, pommel, (0.10, 0.10, 0.10), 1)
    cross = Vector((0.86, -0.2, 0.5)).normalized()  # roughly across the blade
    limb(fins, guard - cross * 0.34, guard + cross * 0.34, 0.06, 0.06, 4)  # crossguard
    for s in (-1, 1):  # quillon tips, so the guard survives at gameplay distance
        ellipsoid(fins, guard + cross * (0.34 * s), (0.09, 0.09, 0.09), 1)
    knuck = guard + cross * 0.24 - hd * 0.30
    limb(fins, guard + cross * 0.24, knuck, 0.05, 0.045, 4)  # knuckle bow
    limb(fins, knuck, pommel + cross * 0.06, 0.045, 0.04, 4)
    _cove_blade(
        fins,
        [
            guard + hd * 0.06,
            guard + hd * 0.90 + Vector((0.04, 0, 0)),
            guard + hd * 1.65 + Vector((-0.14, 0.04, 0.02)),
            guard + hd * 2.15 + Vector((-0.40, 0.10, -0.06)),
        ],
        0.17,
        0.04,
    )

    # --- Head: sunken skull carried well out over the leading foot - the neck
    # cranes further than the hunch alone would take it, which is what sells
    # the shamble in silhouette.
    neck = Vector((0.30, 0, 2.82))
    head_c = Vector((0.66, 0, 3.18))
    limb(body, neck, head_c, 0.17, 0.22, 6)
    ellipsoid(body, head_c, (0.40, 0.38, 0.42), 1)
    box(body, (0.90, 0, 3.08), (0.26, 0.46, 0.30))  # jutting jaw
    box(body, (0.82, 0, 3.36), (0.30, 0.54, 0.13))  # brow ridge

    # --- The net: dragged over the +Y shoulder and across the chest to the
    # -Y hip, floats still knotted along its hanging edge.
    # Strands are deliberately fat for their scale - a scale-accurate mesh
    # vanishes at gameplay distance and the net has to read as netting.
    # It lies ON him - a narrow sash bellying over the chest, not a panel
    # stretched in front of it.
    at = _cove_net(fins, [(0.46, 0.62, 3.00), (0.30, 0.78, 2.88), (0.24, -0.62, 1.74), (0.42, -0.72, 1.86)], rows=1, cols=5, r=0.05, sag=0.06, bow=0.22)
    for k in range(3):
        ellipsoid(fins, at(0.35 + k * 0.22, 1.0) + Vector((0.10, -0.06, -0.10)), (0.14, 0.14, 0.14), 1)  # cork floats
    # The rest of the hank hangs free off the shoulder, down his back and
    # outboard, swinging with the shamble.
    at2 = _cove_net(fins, [(0.16, 0.72, 3.02), (-0.34, 0.64, 2.90), (-0.48, 0.96, 1.62), (-0.02, 1.04, 1.74)], rows=2, cols=3, r=0.042, sag=0.42, bow=0.14)
    for k in range(4):
        ellipsoid(fins, at2(k / 3.0, 1.0) + Vector((0, 0.04, -0.13 - 0.08 * (k % 2))), (0.12, 0.12, 0.12), 1)

    # --- Barnacles: a crust on the free shoulder and up the side of the skull.
    _cove_barnacles(body, (0.06, 0.60, 2.92), (0.15, 0.75, 0.65), count=4, r=0.11, spread=0.20)
    _cove_barnacles(body, (0.56, -0.32, 3.36), (0.1, -0.55, 0.85), count=3, r=0.085, spread=0.16)

    # --- Dead-light eyes, deep under the brow.
    for sy in (-1, 1):
        ellipsoid(eyes, head_c + Vector((0.30, sy * 0.17, 0.02)), (0.08, 0.08, 0.10), 1)

    # --- _Marks (seaweed green, kept minimal): kelp trailing off the shoulder,
    # the net's low corner and the reaching wrist, plus a faint glow line
    # picking out the barnacle crust.
    _cove_kelp(marks, (0.02, 0.66, 2.86), 3)
    _cove_kelp(marks, (-0.28, -0.58, 1.24), 2, drift=(-0.05, -0.04, -0.4), r=0.055)
    _cove_kelp(marks, (1.30, 0.56, 2.28), 2, drift=(0.02, 0.05, -0.38), r=0.05)
    for k in range(4):
        ellipsoid(marks, (0.02 + k * 0.03, 0.68 + 0.02 * k, 3.02 - k * 0.14), (0.045, 0.045, 0.045), 0)
    for k in range(2):
        ellipsoid(marks, (0.54, -0.42 - k * 0.03, 3.42 - k * 0.16), (0.04, 0.04, 0.04), 0)

    return [
        finish("Deckhand_Body", body, MATS["Deckhand_Body"]),
        finish("Deckhand_Fins", fins, MATS["Deckhand_Fins"]),
        finish("Deckhand_Eyes", eyes, MATS["Deckhand_Eyes"]),
        finish("Deckhand_Marks", marks, MATS["Deckhand_Marks"]),
    ]


# ---------------------------------------------------------------- drowned angler
# The Epic zombie fisherman: broad-brimmed sou'wester, a long rotted oilskin
# flaring to the boots, a gaff hook planted in one fist - and, fused to his
# spine, a bent rod of vertebrae arcing up and forward over the hat to dangle a
# lantern-lure in front of his own face. A creel rides the hip; the coat is
# stitched through with the hooks he never got out of it.
# Layers: _Body flesh, bone and the rod-spine; _Fins oilskin, hat, gaff, creel,
# stitched hooks; _Marks the lantern bulb and its hooked snell lines (his
# markColor is the bioluminescent teal the client can Neon).


def build_angler():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    lean = Matrix.Rotation(-0.16, 4, "Y")  # looming rather than lunging

    # --- Legs: heavy waders, planted wide and square.
    for sy in (-1, 1):
        limb(fins, (0.0, sy * 0.40, 1.70), (0.06, sy * 0.44, 0.92), 0.27, 0.24, 6)
        limb(fins, (0.06, sy * 0.44, 0.92), (0.12, sy * 0.46, 0.24), 0.24, 0.21, 6)
        box(fins, (0.26, sy * 0.46, 0.12), (0.74, 0.50, 0.26))  # wader boots

    # --- Torso: broad, water-swollen.
    box(body, (0.10, 0, 2.35), (0.88, 0.98, 1.40), lean)
    box(body, (0.20, 0, 3.02), (0.62, 0.82, 0.40), lean)  # chest / collar

    # --- Oilskin: a flared skirt to below the knee plus a shoulder yoke, so he
    # reads as a wide dark bell with a small head on top.
    revolve(fins, [(-1.02, 1.10), (-0.30, 0.88), (0.40, 0.70), (0.96, 0.66)], sides=10, axis="z", center=(0.05, 0, 2.12), squash=0.9)
    revolve(fins, [(-0.32, 0.92), (0.10, 0.80), (0.34, 0.62)], sides=10, axis="z", center=(0.08, 0, 2.92), squash=0.92)  # shoulder yoke
    for k in range(6):
        a = (k / 6) * TAU + 0.25
        p = Vector((0.05 + math.cos(a) * 0.92, math.sin(a) * 0.98, 1.12))
        cone(fins, p, p + Vector((0.05, 0, -0.36 - 0.12 * (k % 2))), 0.19, 3)  # rotted hem
    box(fins, (0.42, 0, 3.16), (0.36, 0.86, 0.36), lean)  # storm collar
    # The oilskin hangs open down the front: two heavy lapels and a cinched
    # belt, so the coat is not one unbroken slab in silhouette.
    for sy in (-1, 1):
        plate(fins, [(0.58, 3.22), (0.86, 3.06), (0.74, 2.30), (0.46, 2.46)], 0.10, "xz", (0, sy * 0.30, 0))
    revolve(fins, [(-0.08, 0.86), (0.08, 0.86)], sides=10, axis="z", center=(0.06, 0, 2.06), squash=0.9)  # belt
    box(fins, (0.78, 0, 2.06), (0.22, 0.30, 0.24))  # buckle

    # --- Arms: the +Y arm hanging open-handed, the -Y fist clamped on the gaff.
    limb(body, (0.16, 0.62, 3.00), (0.62, 0.78, 2.36), 0.21, 0.17, 6)
    limb(body, (0.62, 0.78, 2.36), (0.92, 0.74, 1.72), 0.17, 0.13, 6)
    limb(fins, (0.12, 0.64, 3.04), (0.68, 0.79, 2.34), 0.32, 0.23, 6)  # oilskin sleeve
    ellipsoid(body, (0.96, 0.73, 1.64), (0.19, 0.17, 0.18), 1)
    for k in (-1, 0, 1):
        limb(body, (1.02, 0.73 + k * 0.10, 1.58), (1.24, 0.73 + k * 0.16, 1.30), 0.055, 0.035, 4)
    limb(body, (0.16, -0.62, 3.00), (0.72, -0.80, 2.40), 0.21, 0.17, 6)
    limb(body, (0.72, -0.80, 2.40), (1.10, -0.78, 1.96), 0.17, 0.13, 6)
    limb(fins, (0.12, -0.64, 3.04), (0.78, -0.81, 2.38), 0.32, 0.23, 6)
    fist = Vector((1.16, -0.78, 1.92))
    ellipsoid(body, fist, (0.19, 0.17, 0.18), 1)

    # --- The gaff: a long shaft planted forward through the fist, bound at the
    # grip, with a broad curved steel hook at the head.
    top = Vector((0.86, -0.70, 4.10))
    butt = Vector((1.58, -0.86, 0.06))
    limb(fins, butt, top, 0.075, 0.065, 5)
    for z in (1.70, 2.16):  # grip bindings
        t = (z - butt.z) / (top.z - butt.z)
        ellipsoid(fins, butt.lerp(top, t), (0.11, 0.11, 0.07), 1)
    _cove_blade(
        fins,
        [
            top + Vector((-0.04, 0, -0.20)),
            top + Vector((0.34, 0, 0.16)),
            top + Vector((0.84, 0, 0.16)),
            top + Vector((1.04, 0, -0.26)),
            top + Vector((0.78, 0, -0.62)),
        ],
        0.15,
        0.045,
        taper=0.55,
    )

    # --- Head: a small sunken skull swallowed by the hat.
    head_c = Vector((0.50, 0, 3.56))
    limb(body, (0.24, 0, 3.16), head_c, 0.19, 0.24, 6)
    ellipsoid(body, head_c, (0.40, 0.38, 0.42), 1)
    box(body, (0.74, 0, 3.46), (0.28, 0.44, 0.32))  # slack jaw
    for sy in (-1, 1):
        ellipsoid(eyes, head_c + Vector((0.30, sy * 0.17, 0.04)), (0.085, 0.085, 0.10), 1)

    # --- Sou'wester: a broad brim that dips fore and aft, and a domed crown.
    revolve(fins, [(-0.07, 1.02), (0.07, 0.94)], sides=10, axis="z", center=(0.44, 0, 3.86), squash=1.05)
    plate(fins, [(1.36, 3.86), (0.60, 3.96), (-0.28, 3.92), (-0.62, 3.60), (-0.30, 3.70), (0.60, 3.74)], 0.70, "xz")  # dipped front peak + long neck flap
    revolve(fins, [(0.0, 0.60), (0.24, 0.56), (0.44, 0.36)], sides=8, axis="z", center=(0.46, 0, 3.88), squash=1.0)

    # --- The rod-spine: vertebrae fused up the back and bent forward over the
    # hat, ending past his own face. Body layer - it is part of him.
    # Heavy at the root and whippy at the tip, and carried well past the brim so
    # the bulb hangs in clear air in FRONT of his face, not against the hat.
    arc = [
        Vector((-0.52, 0, 1.80)),
        Vector((-0.62, 0, 2.56)),
        Vector((-0.50, 0, 3.34)),
        Vector((-0.04, 0, 4.10)),
        Vector((0.74, 0, 4.62)),
        Vector((1.60, 0, 4.70)),
        Vector((2.30, 0, 4.46)),
    ]
    chain(body, arc, [0.19, 0.165, 0.14, 0.115, 0.095, 0.075, 0.05], 5)
    for k, p in enumerate(arc[:5]):
        cone(body, p, p + Vector((-0.26 + 0.07 * k, 0, 0.12)), 0.11, 4)  # vertebral spurs

    # --- The lantern-lure: bulb on a snell off the rod tip, swinging in front
    # of the hat, with a couple of hooked snells trailing off it.
    tip = arc[-1]
    bulb = tip + Vector((0.04, 0, -0.72))
    limb(marks, tip, bulb + Vector((0, 0, 0.20)), 0.035, 0.03, 4)
    ellipsoid(marks, bulb, (0.30, 0.28, 0.32), 2)
    ellipsoid(marks, bulb + Vector((0, 0, 0.24)), (0.12, 0.12, 0.09), 1)  # collar of the bulb
    for sy in (-1, 1):
        a = bulb + Vector((0.02, sy * 0.12, -0.26))
        b = a + Vector((-0.12, sy * 0.20, -0.74))
        limb(marks, a, b, 0.03, 0.026, 4)
        _cove_jhook(marks, b, (-0.1, sy * 0.2, -1.0), size=0.13, r=0.032)

    # --- Creel basket on the +Y hip, on a strap across the chest.
    # Bellied like a woven basket rather than stacked like planks: one rib at
    # the waist is enough to say "wicker" at this poly count.
    creel = Vector((-0.16, 1.00, 1.90))
    revolve(fins, [(-0.30, 0.26), (-0.10, 0.38), (0.14, 0.40), (0.30, 0.34)], sides=8, axis="z", center=creel, squash=0.78)
    revolve(fins, [(-0.03, 0.43), (0.03, 0.43)], sides=8, axis="z", center=creel, squash=0.78)  # weave rib
    revolve(fins, [(0.30, 0.36), (0.38, 0.30)], sides=8, axis="z", center=creel, squash=0.78)  # domed lid
    limb(fins, (0.10, -0.62, 3.04), creel + Vector((0.0, -0.16, 0.30)), 0.07, 0.06, 4)  # shoulder strap

    # --- Hooks he never got out of the oilskin.
    for x, y, z, f in ((0.72, 0.42, 2.60, (0.4, 0.2, -1.0)), (0.66, -0.30, 2.20, (0.5, -0.1, -1.0)), (0.30, 0.78, 2.86, (0.2, 0.5, -1.0)), (0.44, -0.66, 2.70, (0.3, -0.4, -1.0))):
        _cove_jhook(fins, (x, y, z), f, size=0.13, r=0.03)

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
# A smoke-bodied fire spirit. NO LEGS: the torso pours down into a spinning
# CINDER VORTEX that pinches to a point just off the floor, so it reads as
# floating even in a still pose. Horned ash crown over a sunken face, and an
# EMBER-CHAIN FLAIL swung forward from the raised right arm - the chain links
# and the spiked head are _Marks so a client can make the whole weapon Neon and
# the flail becomes the thing you track in a fight. UPRIGHT (row stance), ~3.7
# tall, same reach as before.


def _cd_vortex(bm, rings, sides=7, twist=0.55, squash=0.85):
    """The smoke column: stacked rings, each rotated a little further than the
    one below, so the funnel visibly TWISTS instead of reading as a plain cone.
    `rings` are (z, radius, centre_x) bottom-up; radius 0 makes a point."""
    built = []
    for i, (z, r, cx) in enumerate(rings):
        if r < 1e-4:
            built.append(bm.verts.new(Vector((cx, 0.0, z))))
            continue
        ph = i * twist
        built.append(
            [
                bm.verts.new(Vector((cx + math.cos(a) * r, math.sin(a) * r * squash, z)))
                for a in ((k / sides) * TAU + ph for k in range(sides))
            ]
        )
    connect_rings(bm, built)


def _cd_chain_links(bm, p0, p1, count, link=(0.17, 0.13, 0.05), sag=0.2):
    """A run of chain: flat links alternating 90 degrees along the span, with a
    droop in the middle. Alternating the roll is what makes a row of little
    boxes read as CHAIN at this poly count."""
    p0, p1 = Vector(p0), Vector(p1)
    d = p1 - p0
    yaw = math.atan2(d.y, d.x)
    pitch = -math.atan2(d.z, math.hypot(d.x, d.y))
    for i in range(count):
        t = (i + 0.5) / count
        p = p0.lerp(p1, t) - Vector((0.0, 0.0, sag * 4.0 * t * (1.0 - t)))
        rot = Matrix.Rotation(yaw, 4, "Z") @ Matrix.Rotation(pitch, 4, "Y") @ Matrix.Rotation((i % 2) * math.pi / 2, 4, "X")
        box(bm, p, link, rot)


def build_cinder_djinn():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # THE VORTEX: no legs. A twisting funnel of smoke, pointed just off the
    # floor and swelling twice on the way up, so the lower silhouette is a
    # spiral rather than a skirt. Bulges alternate to sell the rotation.
    _cd_vortex(
        body,
        [
            (0.03, 0.0, 0.34),
            (0.32, 0.27, 0.24),
            (0.66, 0.48, 0.14),
            (1.0, 0.31, 0.07),
            (1.34, 0.54, 0.02),
            (1.66, 0.38, 0.0),
            (1.98, 0.58, 0.0),
        ],
    )

    # Torso: a narrow wedge of denser smoke rising out of the funnel, with a
    # yoke of shoulders far wider than the waist (a tapered-down silhouette).
    box(body, (0.04, 0, 2.4), (0.62, 1.0, 0.95), Matrix.Rotation(-0.12, 4, "Y"))
    box(body, (0.0, 0, 2.9), (0.55, 1.5, 0.34), Matrix.Rotation(-0.08, 4, "Y"))

    head_c = Vector((0.24, 0, 3.2))
    ellipsoid(body, head_c, (0.34, 0.32, 0.36), 0)
    box(body, (0.46, 0, 3.06), (0.34, 0.4, 0.2), Matrix.Rotation(0.14, 4, "Y"))
    # Smoke torn off the back of the column.
    for sy, z in ((1, 2.66), (-1, 2.2), (1, 1.5)):
        cone(body, (-0.28, sy * 0.28, z), (-0.86, sy * 0.5, z + 0.34), 0.16, 4)

    # ASH CROWN: two heavy horns sweeping back over the crown, plus a ring of
    # short spikes - the head silhouette is the crown, not the skull.
    for sy in (-1, 1):
        chain(
            fins,
            [Vector((0.14, sy * 0.26, 3.34)), Vector((-0.14, sy * 0.44, 3.7)), Vector((-0.48, sy * 0.34, 3.62))],
            [0.13, 0.09, 0.03],
            4,
        )
    for i in range(5):
        a = -0.7 + (i / 4) * 1.4
        base = head_c + Vector((math.cos(a) * 0.24, math.sin(a) * 0.26, 0.24))
        cone(fins, base, base + Vector((math.cos(a) * 0.12, math.sin(a) * 0.13, 0.32)), 0.08, 4)

    # ARMS (gear layer): the RIGHT arm cocked high and back with the flail, the
    # LEFT reaching low and forward with splayed cinder fingers. The asymmetry
    # is the pose - a mid-swing read from any angle.
    r_hand = Vector((1.02, -0.72, 2.98))
    limb(fins, Vector((0.04, -0.62, 2.84)), Vector((0.54, -0.88, 3.14)), 0.17, 0.14, 5)
    limb(fins, Vector((0.54, -0.88, 3.14)), r_hand, 0.14, 0.11, 5)
    box(fins, r_hand, (0.28, 0.26, 0.24))

    l_hand = Vector((1.16, 0.62, 2.04))
    limb(fins, Vector((0.04, 0.62, 2.78)), Vector((0.62, 0.74, 2.36)), 0.17, 0.13, 5)
    limb(fins, Vector((0.62, 0.74, 2.36)), l_hand, 0.13, 0.1, 5)
    box(fins, l_hand, (0.24, 0.24, 0.22))
    for k in range(3):
        cone(fins, l_hand, l_hand + Vector((0.34, (k - 1) * 0.14, -0.1 - abs(k - 1) * 0.06)), 0.05, 3)

    # Ash mantle: plates hanging off both shoulders, breaking the smoke line.
    for sy in (-1, 1):
        plate(fins, [(-0.22, 2.98), (0.32, 2.9), (0.22, 2.42), (-0.34, 2.6)], 0.14, plane="xz", offset=(0, sy * 0.66, 0))

    # THE EMBER-CHAIN FLAIL (glow layer): a run of links off the raised fist,
    # falling forward into a spiked head out at +X where it reads from the
    # front. The whole weapon is _Marks so it can be lit as one object.
    # Head kept in to x~2.1: any further forward and the flail alone would add
    # a stud and a half to the model's bounding box (and so to its target box).
    flail = Vector((1.6, -0.5, 2.18))
    _cd_chain_links(marks, r_hand + Vector((0.14, 0.02, -0.06)), flail, 6)
    ellipsoid(marks, flail, (0.25, 0.25, 0.25), 0)
    for i in range(6):
        a = (i / 6) * TAU
        d = Vector((math.cos(a) * 0.5, math.sin(a) * 0.34, math.sin(a * 2) * 0.42))
        cone(marks, flail + d * 0.4, flail + d, 0.09, 4)

    # The core burning behind the ribs, cinders shedding upward off the column,
    # and two seams splitting the vortex.
    ellipsoid(marks, (0.4, 0, 2.44), (0.22, 0.2, 0.24), 0)
    for i in range(5):
        a = (i / 5) * TAU
        ellipsoid(marks, (math.cos(a) * 0.44 + 0.04, math.sin(a) * 0.4, 1.35 + (i % 3) * 0.5), (0.09, 0.09, 0.09), 0)
    for sy in (-1, 1):
        chain(marks, [Vector((0.3, sy * 0.2, 0.75)), Vector((0.28, sy * 0.32, 1.5)), Vector((0.22, sy * 0.22, 2.1))], [0.04, 0.07, 0.05], 4)

    for sy in (-1, 1):
        ellipsoid(eyes, head_c + Vector((0.26, sy * 0.15, 0.04)), (0.1, 0.1, 0.11), 0)

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
# A FURNACE KNIGHT: a hulk in asymmetric armour of cooled slag, head sunk down
# between the shoulders, stance wide, one arm ending in an oversized obsidian
# HAMMER-FIST thrown forward. The mass is the point - it must read as roughly
# twice a zombie, so the shoulders are wider than the stance and the left
# pauldron is a slab in its own right while the right shoulder is stripped
# almost bare. THE CORE IS STILL THE MECHANIC: molten seams (marks) run every
# armour crack and open into a chest FURNACE GRATE framed by the plating, so a
# client lighting _Marks lights the cracks, the grate and the knuckles at once.
# UPRIGHT, ~3.7 tall (pauldron tip), same footprint band as before.


def _sg_slab(bm, pts, thick, y, tilt=0.0):
    """One jagged armour plate standing in the body's side plane. Plates are
    authored as outlines rather than boxes so the edges can be uneven - a box
    silhouette reads as 'crate', an uneven outline reads as broken slag."""
    plate(bm, pts, thick, plane="xz", offset=(0, y, tilt))


def _sg_seam(bm, p0, p1, w=0.09):
    """A molten crack: a thin bar laid along a gap between plates. Kept as a
    box (not a tube) so it reads as a SPLIT in the armour, not a wire."""
    p0, p1 = Vector(p0), Vector(p1)
    d = p1 - p0
    length = d.length
    if length < 1e-5:
        return
    rot = Matrix.Rotation(math.atan2(d.y, d.x), 4, "Z") @ Matrix.Rotation(-math.atan2(d.z, math.hypot(d.x, d.y)), 4, "Y")
    box(bm, p0.lerp(p1, 0.5), (length, w, w), rot)


def build_slag_golem():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # Legs: a WIDE braced stance, thigh -> shin -> slab foot. Splayed feet and
    # a low pelvis are most of the "heavy" read at this distance.
    for sy in (-1, 1):
        box(body, (-0.02, sy * 0.56, 1.02), (0.7, 0.7, 0.86), Matrix.Rotation(sy * 0.09, 4, "X"))
        box(body, (0.06, sy * 0.6, 0.42), (0.62, 0.62, 0.62))
        box(body, (0.18, sy * 0.6, 0.12), (0.96, 0.8, 0.24))

    lean = Matrix.Rotation(-0.08, 4, "Y")
    box(body, (0.0, 0, 1.6), (0.92, 1.5, 0.52))
    box(body, (0.03, 0, 2.32), (1.0, 1.6, 1.1), lean)
    # The yoke: shoulders wider than the feet, which is what makes it a hulk.
    box(body, (-0.06, 0, 2.94), (1.02, 2.15, 0.56), lean)

    # HEAD SUNK BETWEEN THE SHOULDERS: small, set forward and low so the yoke
    # and the pauldron both rise past it. No neck.
    head_c = Vector((0.34, 0, 3.06))
    box(body, head_c, (0.56, 0.62, 0.56))
    box(body, head_c + Vector((0.24, 0, -0.16)), (0.3, 0.5, 0.26), Matrix.Rotation(0.2, 4, "Y"))

    # ARMS. RIGHT (-y) is the hammer arm, thrust forward and down; LEFT (+y) is
    # shorter, cocked back under the big pauldron.
    wrist = Vector((0.78, -0.94, 1.66))
    limb(body, Vector((0.0, -0.96, 2.84)), Vector((0.5, -1.06, 2.16)), 0.34, 0.3, 6)
    limb(body, Vector((0.5, -1.06, 2.16)), wrist, 0.3, 0.28, 6)
    limb(body, Vector((0.0, 0.96, 2.8)), Vector((0.34, 1.14, 1.98)), 0.32, 0.27, 6)
    limb(body, Vector((0.34, 1.14, 1.98)), Vector((0.52, 1.04, 1.22)), 0.27, 0.24, 6)
    box(body, (0.56, 1.02, 1.02), (0.58, 0.54, 0.48))

    # THE HAMMER-FIST (gear layer): a block of obsidian bigger than the golem's
    # own head, out at +X where it reads head-on, with a spiked striking face
    # and a wedge collar where the arm disappears into it. This is the
    # signature - everything else is sized so this still looks oversized.
    # Held close: the hammer is oversized by BULK, not by reach, so the model's
    # bounding box (and its target box) stays near the old one.
    ham = Vector((1.32, -0.86, 1.32))
    box(fins, ham, (1.0, 0.96, 1.08), Matrix.Rotation(0.12, 4, "Y"))
    limb(fins, wrist, ham - Vector((0.36, 0, 0)), 0.34, 0.42, 6)
    for sz in (-1, 1):
        _sg_slab(fins, [(0.88, 1.32 + sz * 0.5), (1.82, 1.26 + sz * 0.62), (1.9, 1.32 + sz * 0.3), (0.9, 1.32 + sz * 0.26)], 0.9, -0.86)
    for i in range(3):
        base = ham + Vector((0.48, (i - 1) * 0.3, (i % 2) * 0.28 - 0.14))
        cone(fins, base, base + Vector((0.3, (i - 1) * 0.1, 0.0)), 0.14, 4)

    # ASYMMETRIC ARMOUR. LEFT shoulder: three layered slag slabs stacking up
    # past the head into a ridge of spikes. RIGHT shoulder: one stripped plate,
    # so the two halves never mirror.
    _sg_slab(fins, [(-0.62, 2.62), (0.42, 2.76), (0.6, 3.34), (-0.12, 3.62), (-0.74, 3.28)], 0.52, 1.06)
    _sg_slab(fins, [(-0.5, 2.36), (0.4, 2.44), (0.5, 2.92), (-0.56, 2.86)], 0.4, 1.3)
    _sg_slab(fins, [(-0.34, 2.02), (0.34, 2.06), (0.36, 2.46), (-0.44, 2.44)], 0.32, 1.42)
    for i in range(3):
        base = Vector((-0.32 + i * 0.3, 1.08 - i * 0.04, 3.22 + (i % 2) * 0.1))
        cone(fins, base, base + Vector((-0.12, 0.16, 0.34)), 0.11, 4)
    _sg_slab(fins, [(-0.5, 2.66), (0.34, 2.72), (0.42, 3.16), (-0.56, 3.02)], 0.44, -1.02)

    # Chest: a FRAME of four plates around a rectangular opening. The opening
    # is the furnace mouth - the grate bars that fill it are _Marks.
    _sg_slab(fins, [(0.42, 1.86), (0.66, 1.8), (0.68, 2.9), (0.44, 2.94)], 0.24, 0.66)
    _sg_slab(fins, [(0.42, 1.86), (0.66, 1.8), (0.68, 2.9), (0.44, 2.94)], 0.24, -0.66)
    _sg_slab(fins, [(0.4, 2.78), (0.7, 2.72), (0.72, 3.02), (0.42, 3.06)], 1.44, 0.0)
    _sg_slab(fins, [(0.42, 1.66), (0.72, 1.6), (0.7, 1.92), (0.4, 1.96)], 1.44, 0.0)
    # Back and hip plating: layered slabs so the profile is stepped, not flat.
    for sy in (-1, 1):
        box(fins, (-0.52, sy * 0.42, 2.32), (0.3, 0.72, 1.24))
        _sg_slab(fins, [(-0.4, 1.32), (0.44, 1.4), (0.5, 1.86), (-0.5, 1.78)], 0.4, sy * 0.72)

    # MOLTEN SEAMS: the furnace grate, then a crack down every plate gap and
    # across the hammer knuckles. Deliberate placement - each seam sits in a
    # gap the plating actually leaves.
    for i in range(4):
        # Bars stop short of 2.72: that is where the top frame plate starts.
        _sg_seam(marks, (0.54, -0.44, 2.04 + i * 0.2), (0.54, 0.44, 2.04 + i * 0.2), 0.12)
    ellipsoid(marks, (0.34, 0, 2.42), (0.2, 0.4, 0.44), 0)
    for sy in (-1, 1):
        _sg_seam(marks, (0.3, sy * 0.86, 2.72), (-0.3, sy * 1.0, 2.96))
        _sg_seam(marks, (0.44, sy * 0.66, 1.74), (-0.3, sy * 0.74, 1.66))
        _sg_seam(marks, (0.2, sy * 0.58, 1.36), (0.14, sy * 0.6, 0.7))
        _sg_seam(marks, (0.3, sy * 0.62, 0.26), (-0.2, sy * 0.6, 0.3), 0.07)
    _sg_seam(marks, (0.1, -1.0, 2.5), (0.6, -0.98, 1.9))
    for i in range(3):
        _sg_seam(marks, (1.76, -1.2, 1.14 + i * 0.3), (1.76, -0.5, 1.14 + i * 0.3), 0.1)

    for sy in (-1, 1):
        ellipsoid(eyes, head_c + Vector((0.26, sy * 0.17, 0.06)), (0.1, 0.1, 0.11), 0)

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


# ---------------------------------------------------------------- ghost-fleet helpers (local)
# Curved tubes for the wreck crew's ironwork: hook throats, saber knuckle
# bows, a wheel rim, bare ribs. The shared primitives are frozen, and both of
# these are only a `chain`/`limb` swept along fixed arithmetic - no entropy.


def _wk_arc(bm, center, radius, a0, a1, steps, r0, r1, plane="xz", sides=4):
    """A tube swept along an arc of `radius` about `center`, in `plane`
    ("xz" / "xy" / "yz"), from angle a0 to a1, tapering r0 -> r1. a1 - a0 of
    TAU closes the loop (the last segment lands back on the first point)."""
    pts, rads = [], []
    for i in range(steps + 1):
        u = i / steps
        a = a0 + (a1 - a0) * u
        c, s = math.cos(a) * radius, math.sin(a) * radius
        if plane == "xz":
            pts.append((center[0] + c, center[1], center[2] + s))
        elif plane == "xy":
            pts.append((center[0] + c, center[1] + s, center[2]))
        else:  # "yz"
            pts.append((center[0], center[1] + c, center[2] + s))
        rads.append(r0 + (r1 - r0) * u)
    chain(bm, pts, rads, sides)


def _wk_barnacle(bm, base, out, r=0.14):
    """One squat barnacle: a stubby cone growing along `out` from `base`."""
    b = Vector(base)
    limb(bm, b, b + Vector(out), r, r * 0.45, 5)


def _wk_sheet(bm, points, thickness=0.1, along=(0, 0, 1)):
    """`plate` for an outline that is NOT axis-aligned: a thin polygon through
    arbitrary 3D `points`, extruded along `along`. Canvas that rakes back AND
    droops needs this - an "xy" plate can only ever lie flat."""
    off = Vector(along).normalized() * (thickness / 2)
    front = [bm.verts.new(Vector(p) - off) for p in points]
    back = [bm.verts.new(Vector(p) + off) for p in points]
    bridge(bm, front, back)
    bm.faces.new(list(reversed(front)))
    bm.faces.new(back)


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
    # Raked hull strakes down each flank and a cutwater along the stem: the
    # half-of-him-is-a-bow read wants planking that follows the sheer, not
    # just the flat bands.
    for s in (-1, 1):
        for i in range(3):
            box(
                fins,
                (0.9 - i * 0.35, s * 2.24, 1.25 + i * 0.62),
                (6.6 - i * 0.5, 0.16, 0.2),
                Matrix.Rotation(math.radians(7 - i * 2), 4, "Y"),
            )
    box(body, (5.05, 0, 2.1), (2.6, 0.42, 1.0), Matrix.Rotation(math.radians(-38), 4, "Y"))
    # The bowsprit, spearing out over the prow with a pair of ghost stays.
    limb(body, (4.6, 0, 3.15), (6.95, 0, 4.35), 0.2, 0.11, 5)

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

    # Saber arm (starboard): shoulder -> fist, then an officer's curved blade
    # raised over the prow - grip, knuckle-bow basket, pommel, and a bit that
    # sweeps up and forward the way a saber's does.
    chain(body, [(-0.4, 1.9, 5.6), (0.8, 2.7, 5.1), (1.8, 2.5, 5.5)], [0.5, 0.38, 0.3], 5)
    box(fins, (1.85, 2.5, 5.3), (0.3, 0.5, 0.5))  # the fist's grip
    limb(fins, (1.62, 2.5, 5.12), (2.08, 2.5, 5.62), 0.11, 0.1, 5)
    box(fins, (1.56, 2.5, 5.04), (0.28, 0.34, 0.24))  # pommel
    _wk_arc(fins, (1.95, 2.5, 5.4), 0.46, -1.35, 1.5, 3, 0.09, 0.07, "xz", 4)  # knuckle bow
    plate(fins, [(1.95, 5.55), (3.3, 6.4), (4.55, 8.15), (4.42, 8.28), (2.95, 6.8), (1.85, 5.95)],
          0.16, "xz", offset=(0, 2.5, 0))
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

    # The shattered ship's wheel, fused around that same forearm: a broken
    # rim (a whole quadrant gone), a hub, and spokes - two snapped off short,
    # the rest still carrying their handles past the rim.
    wheel_c = (1.05, -2.35, 4.2)
    _wk_arc(fins, wheel_c, 0.95, 0.62, TAU - 0.72, 8, 0.13, 0.13, "yz", 4)
    limb(fins, (0.82, wheel_c[1], wheel_c[2]), (1.28, wheel_c[1], wheel_c[2]), 0.24, 0.24, 6)
    for k, reach in ((1, 1.24), (2, 1.26), (3, 0.55), (4, 1.22), (5, 0.5)):
        a = (k / 6) * TAU + 0.3
        limb(
            fins,
            (wheel_c[0], wheel_c[1] + math.cos(a) * 0.2, wheel_c[2] + math.sin(a) * 0.2),
            (wheel_c[0], wheel_c[1] + math.cos(a) * reach, wheel_c[2] + math.sin(a) * reach),
            0.11,
            0.08,
            4,
        )

    # The mast behind him, a yard and a ragged spectral sail.
    limb(body, (-2.8, 0, 3.2), (-2.8, 0, 8.6), 0.26, 0.18, 6)
    limb(body, (-2.8, -2.1, 7.4), (-2.8, 2.1, 7.4), 0.14, 0.14, 5)
    box(fins, (-2.8, 0, 6.1), (0.14, 3.8, 2.2))
    for k in range(4):
        y = -1.5 + k * 1.0
        box(fins, (-2.8, y, 4.6), (0.12, 0.5, 1.1), Matrix.Rotation(math.radians(10 - k * 6), 4, "X"))
    # A tattered admiral's pennant streaming aft off the masthead.
    plate(
        fins,
        [(-2.72, 0.15), (-3.72, 0.55), (-3.52, -0.05), (-3.78, -0.62), (-2.72, -0.3)],
        0.08,
        "xy",
        offset=(0, 0, 8.25),
    )

    # Marks: the ghost-fire - a chest wound, a prow lantern on a hook, glow
    # lines along the hull seam, the cutwater, rigging threads to the masthead
    # and the stays running down off the bowsprit.
    ellipsoid(marks, (0.75, 0.4, 5.2), (0.4, 0.5, 0.6), 1)
    for s in (-1, 1):
        chain(marks, [(6.85, 0, 4.3), (5.4, s * 1.6, 2.5)], [0.05, 0.04], 4)
    box(marks, (5.15, 0, 1.95), (2.5, 0.16, 0.1), Matrix.Rotation(math.radians(-38), 4, "Y"))
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


# ---- Rigging Wraith (wreck): a torn sail that never came down - a triangular
# sailcloth streaming behind a hooded scrap of a body, rope lines wrapping and
# tethering it, and block-and-tackle hooks swinging where its hands should be.
# _Body is the canvas, _Fins the cordage and ironwork. Upright-stance hoverer.
def build_riggingwraith():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # The shroud: a draped cone rising to a hood peak, hem torn into points.
    revolve(body, [(0.0, 0.86), (0.9, 0.78), (1.8, 0.5), (2.5, 0.18)], sides=7, axis="z", center=(0, 0, 0.9))
    cone(body, (0, 0, 3.35), (0.15, 0, 3.9), 0.2, 5)
    for k in range(5):
        a = (k / 5) * TAU
        bx, by = math.cos(a) * 0.8, math.sin(a) * 0.8
        cone(body, (bx, by, 1.0), (bx * 1.2, by * 1.2, 0.3), 0.16, 4)
    # The sail itself: two great sheets of torn canvas rigged off the hood,
    # raked back and DROOPING outboard (a flat wing reads as a kite - a sail
    # has to fall away at the leech), plus a streamer trailing aft.
    for s in (-1, 1):
        _wk_sheet(
            body,
            [
                (0.3, s * 0.34, 3.3),
                (-0.1, s * 1.25, 2.95),
                (-0.35, s * 1.5, 2.3),
                (-0.5, s * 2.1, 2.45),
                (-1.35, s * 2.62, 1.7),
                (-0.95, s * 1.8, 1.85),
                (-1.8, s * 1.5, 1.1),
                (-1.05, s * 1.05, 1.5),
                (-1.6, s * 0.62, 0.75),
                (-0.45, s * 0.46, 1.9),
            ],
            0.1,
            (0.35, 0, 1.0),
        )
        # Reef lines laced across the canvas - the last thing that ever
        # reads as "sail" rather than "wing".
        for f, g in ((0.3, 0.72), (0.55, 0.5)):
            limb(
                fins,
                (0.3 - f * 1.5, s * (0.34 + f * 2.0), 3.3 - f * 1.3),
                (0.3 - f * 1.5 - 0.5, s * (0.34 + f * 2.0) * g, 3.3 - f * 1.3 - 0.5),
                0.035,
                0.03,
                3,
            )
    plate(body, [(-0.35, 3.4), (-1.75, 3.05), (-1.45, 2.35), (-2.0, 1.9), (-1.2, 1.65), (-0.45, 1.2)], 0.1, "xz")

    # The rigging it is still tangled in: stays running from the hood peak out
    # to each sail tip and back down to the hem, and rope wound round it.
    for s in (-1, 1):
        # Sagging, not taut: a straight peak-to-tip line reads as a kite spar.
        chain(
            fins,
            [(0.08, 0, 3.85), (-0.45, s * 1.15, 2.5), (-1.12, s * 2.15, 1.72)],
            [0.045, 0.04, 0.035],
            3,
        )
        chain(
            fins,
            [(-1.12, s * 2.15, 1.68), (-0.85, s * 1.4, 1.0), (-0.2, s * 0.72, 1.05)],
            [0.04, 0.035, 0.035],
            3,
        )
    for z, r in ((1.05, 0.78), (2.05, 0.5)):
        _wk_arc(fins, (0, 0, z), r, 0.0, TAU, 6, 0.05, 0.05, "xy", 3)

    # Block-and-tackle where the hands should be: a pulley block hung on its
    # fall, a sheave pinned through it, and a great curved hook below.
    for s in (-1, 1):
        limb(fins, (0.15, s * 0.62, 2.45), (0.6, s * 0.92, 1.2), 0.05, 0.05, 3)  # the fall
        box(fins, (0.6, s * 0.92, 1.0), (0.34, 0.24, 0.44))  # the block
        limb(fins, (0.6, s * 1.06, 1.0), (0.6, s * 0.78, 1.0), 0.14, 0.14, 7)  # the sheave
        limb(fins, (0.6, s * 0.92, 0.78), (0.64, s * 0.92, 0.56), 0.05, 0.05, 4)  # the becket
        _wk_arc(fins, (0.66, s * 0.92, 0.44), 0.26, 2.2, -1.2, 4, 0.08, 0.035, "yz", 4)

    # Ghost-fire eyes in the hood's shadow, and glowing seams down the shroud.
    for s in (-1, 1):
        ellipsoid(eyes, (0.6, s * 0.26, 2.75), (0.14, 0.12, 0.17), 0)
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


# ---------------------------------------------------------------- Frostmaw Reach hostiles
# The ice island's roster. Cold palette, crystalline silhouettes.


# ---- Frostbite Pup (rusher): a deceptively cute seal pup with too many
# teeth - plump body, swept flippers, frost patches. Flat, front +X.
def build_frostbitepup():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    revolve(body, [(-1.7, 0.0), (-0.9, 0.5), (0.0, 0.64), (0.9, 0.56), (1.5, 0.36), (1.8, 0.0)], sides=8, axis="x", center=(0, 0, 0.68), squash=0.95)
    ellipsoid(body, (1.75, 0, 0.85), (0.5, 0.42, 0.4), 1)
    ellipsoid(body, (2.2, 0, 0.72), (0.24, 0.2, 0.17), 1)
    # The teeth: a rusher's grin, too wide for a pup.
    for s in (-1, 1):
        for i in range(3):
            cone(fins, (2.0 + i * 0.13, s * (0.16 + i * 0.02), 0.6), (2.02 + i * 0.13, s * (0.17 + i * 0.02), 0.45), 0.04, 4)
    # Fore-flippers swept back, and the tail flipper.
    for s in (-1, 1):
        plate(fins, [(0.9, s * 0.5), (0.1, s * 1.3), (-0.6, s * 1.25), (0.1, s * 0.5)], 0.12, "xy", offset=(0, 0, 0.35))
    plate(fins, [(-1.6, 0.3), (-2.5, 0.55), (-2.4, 0.0), (-2.5, -0.55), (-1.6, -0.3)], 0.12, "xy", offset=(0, 0, 0.55))
    # Frost patches on the back.
    for px, py in ((0.3, 0.4), (-0.6, -0.35), (-0.2, 0.1)):
        ellipsoid(marks, (px, py, 1.28), (0.4, 0.3, 0.08), 1)
    for s in (-1, 1):
        ellipsoid(eyes, (1.95, s * 0.24, 1.0), (0.14, 0.12, 0.14), 0)

    return [
        finish("FrostbitePup_Body", body, MATS["FrostbitePup_Body"]),
        finish("FrostbitePup_Fins", fins, MATS["FrostbitePup_Fins"]),
        finish("FrostbitePup_Eyes", eyes, MATS["FrostbitePup_Eyes"]),
        finish("FrostbitePup_Marks", marks, MATS["FrostbitePup_Marks"]),
    ]


# ---- Iceshard Crab (rusher): a crab grown a crown of ice shards instead of
# a smooth shell. Flat, front +X (claws).
def build_iceshardcrab():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    dome(body, (0, 0, 0.35), (1.05, 0.9, 0.55), 1)
    ellipsoid(body, (0, 0, 0.35), (1.1, 0.95, 0.28), 1)
    # The shard crown: crystals at set angles, kept under the length rule.
    for k, (dx, dy, h, r) in enumerate(((0.3, 0.3, 0.9, 0.2), (-0.4, 0.15, 1.1, 0.24), (0.05, -0.45, 0.8, 0.18), (-0.15, 0.55, 0.7, 0.15), (0.45, -0.15, 0.6, 0.14))):
        cone(fins, (dx, dy, 0.6), (dx * 1.6, dy * 1.6, 0.6 + h), r, 5)
        ellipsoid(marks, (dx * 1.1, dy * 1.1, 0.75), (r * 0.7, r * 0.7, r * 0.5), 0)
    # Legs: three per side, and two stout claws reaching well forward.
    for sy in (-1, 1):
        for i in range(3):
            x = 0.35 - i * 0.4
            chain(body, [(x, sy * 0.6, 0.35), (x + 0.05, sy * 1.0, 0.55), (x + 0.1, sy * 1.25, 0.0)], [0.09, 0.07, 0.02], 5)
        chain(body, [(0.8, sy * 0.45, 0.35), (1.45, sy * 0.58, 0.45)], [0.14, 0.1], 5)
        ellipsoid(fins, (1.78, sy * 0.6, 0.45), (0.35, 0.2, 0.18), 1)
    for s in (-1, 1):
        limb(body, (0.9, s * 0.2, 0.7), (1.05, s * 0.25, 1.0), 0.05, 0.04, 4)
        ellipsoid(eyes, (1.07, s * 0.26, 1.05), (0.08, 0.08, 0.08), 0)

    return [
        finish("IceshardCrab_Body", body, MATS["IceshardCrab_Body"]),
        finish("IceshardCrab_Fins", fins, MATS["IceshardCrab_Fins"]),
        finish("IceshardCrab_Eyes", eyes, MATS["IceshardCrab_Eyes"]),
        finish("IceshardCrab_Marks", marks, MATS["IceshardCrab_Marks"]),
    ]


# ---- Glacial Lurker (burrower): the thing under the ice sheet - a wedge
# body built to shoulder up through the shelf, scoop claws, a crystal ridge.
# Flat, front +X.
def build_glaciallurker():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    revolve(body, [(-2.1, 0.0), (-1.0, 0.72), (0.2, 1.0), (1.5, 0.72), (2.3, 0.0)], sides=8, axis="x", center=(0, 0, 0.62), squash=0.6)
    # The scoop claws: broad digging plates angled down-forward.
    for s in (-1, 1):
        plate(fins, [(1.6, 0.9), (2.9, 0.55), (2.7, 0.1), (1.5, 0.35)], 0.42, "xz", offset=(0, s * 0.62, 0))
    # Crystal ridge down the spine, biggest amidships - kept low so the wedge
    # stays wider than it is tall.
    for i, (x, h) in enumerate(((1.0, 0.45), (0.3, 0.62), (-0.5, 0.68), (-1.3, 0.5))):
        box(fins, (x, 0, 1.05 + h * 0.3), (0.5, 0.22, h), Matrix.Rotation(math.radians(-18), 4, "Y"))
    # Ice-vein tracery along the flanks.
    for s in (-1, 1):
        chain(marks, [(1.4, s * 0.6, 0.7), (0.2, s * 0.82, 0.85), (-1.2, s * 0.62, 0.75)], [0.05, 0.06, 0.04], 4)
    # Eyes: glowing slits high on the wedge - what you see coming up at you.
    for s in (-1, 1):
        ellipsoid(eyes, (1.7, s * 0.35, 1.0), (0.18, 0.09, 0.08), 0)

    return [
        finish("GlacialLurker_Body", body, MATS["GlacialLurker_Body"]),
        finish("GlacialLurker_Fins", fins, MATS["GlacialLurker_Fins"]),
        finish("GlacialLurker_Eyes", eyes, MATS["GlacialLurker_Eyes"]),
        finish("GlacialLurker_Marks", marks, MATS["GlacialLurker_Marks"]),
    ]


# ---- Icevein Pike (charger): a long spear of a fish, underslung jaw,
# glowing veins down both flanks. Flat, front +X.
def build_iceveinpike():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    revolve(body, [(-2.5, 0.0), (-1.5, 0.3), (0.0, 0.44), (1.6, 0.4), (2.5, 0.22), (2.8, 0.0)], sides=8, axis="x", center=(0, 0, 0.62), squash=1.15)
    # Underslung jaw and needle teeth.
    box(body, (2.5, 0, 0.42), (0.9, 0.3, 0.16), Matrix.Rotation(math.radians(6), 4, "Y"))
    for s in (-1, 1):
        for i in range(3):
            cone(fins, (2.25 + i * 0.22, s * 0.1, 0.5), (2.27 + i * 0.22, s * 0.1, 0.66), 0.035, 4)
    # Fins: dorsal set far back (a pike's tell), forked tail, pectorals.
    plate(fins, [(-1.2, 1.0), (-2.0, 1.5), (-2.2, 1.0)], 0.1, "xz")
    plate(fins, [(-2.7, 0.8), (-3.6, 1.3), (-3.3, 0.6), (-3.6, -0.1), (-2.7, 0.4)], 0.12, "xz")
    for s in (-1, 1):
        plate(fins, [(1.4, s * 0.4), (0.7, s * 1.0), (0.5, s * 0.45)], 0.08, "xy", offset=(0, 0, 0.35))
    # The veins: jagged glowing lines down both flanks.
    for s in (-1, 1):
        chain(marks, [(2.0, s * 0.4, 0.62), (1.0, s * 0.48, 0.78), (-0.2, s * 0.46, 0.55), (-1.4, s * 0.34, 0.72)], [0.05, 0.06, 0.06, 0.04], 4)
    for s in (-1, 1):
        ellipsoid(eyes, (2.05, s * 0.28, 0.78), (0.11, 0.09, 0.11), 0)

    return [
        finish("IceveinPike_Body", body, MATS["IceveinPike_Body"]),
        finish("IceveinPike_Fins", fins, MATS["IceveinPike_Fins"]),
        finish("IceveinPike_Eyes", eyes, MATS["IceveinPike_Eyes"]),
        finish("IceveinPike_Marks", marks, MATS["IceveinPike_Marks"]),
    ]


# ---- Frozen Mariner (shambler): the whaler the pack ice kept - locked
# mid-stride, frost-bearded, still hefting a frozen harpoon with its rime-
# rope trailing off it, a sheet of ice cascading off the port shoulder.
# UPRIGHT (stance).

# The harpoon axis is wanted by the hands, the rope, the head and the barbs,
# so it is named once. Butt low and aft on the starboard side, point high and
# forward across the body: a diagonal that reads from the front AND in profile
# (straight out along +X it would foreshorten to a dot).
_HARPOON_BUTT = Vector((-0.85, 0.55, 1.35))
_HARPOON_TIP = Vector((2.00, -0.95, 4.15))


def _harpoon_at(t):
    return _HARPOON_BUTT + (_HARPOON_TIP - _HARPOON_BUTT) * t


def _rime_rope(bm, pts, r=0.055):
    """A sagging line with a frozen bead at every knot, so it reads as rope
    rather than as wire."""
    chain(bm, pts, [r] * len(pts), 4)
    for p in pts[1:-1]:
        ellipsoid(bm, p, (r * 2.1, r * 2.1, r * 1.7), 0)


def build_frozenmariner():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    lean = Matrix.Rotation(math.radians(14), 4, "Y")  # pitched over the lead foot

    # LOCKED MID-STRIDE: lead leg forward and bent, trail leg driving back.
    # Feet at z=0. The gap between them is the whole pose in silhouette.
    chain(body, [(0.05, 0.44, 1.75), (0.56, 0.48, 1.05), (0.78, 0.48, 0.28)], [0.29, 0.24, 0.19], 5)
    box(body, (0.90, 0.48, 0.13), (0.66, 0.46, 0.26))
    chain(body, [(-0.05, -0.44, 1.75), (-0.48, -0.48, 1.08), (-0.80, -0.46, 0.30)], [0.29, 0.24, 0.19], 5)
    box(body, (-0.86, -0.46, 0.13), (0.66, 0.46, 0.26))

    # Torso under a heavy whaler's coat.
    box(body, (0.10, 0, 2.55), (0.85, 1.28, 1.75), lean)
    box(fins, (0.06, 0, 2.35), (1.00, 1.44, 1.30), lean)  # coat
    box(fins, (-0.02, 0, 1.60), (0.90, 1.34, 0.52), lean)  # coat skirt
    box(fins, (0.22, 0, 3.28), (0.60, 1.32, 0.32), lean)  # storm collar

    # Head craned into the wind, jaw jutting.
    head_c = Vector((0.52, 0, 3.85))
    limb(body, (0.28, 0, 3.32), head_c, 0.20, 0.26, 6)
    ellipsoid(body, head_c, (0.40, 0.38, 0.42), 1)
    box(body, (0.78, 0, 3.72), (0.26, 0.46, 0.30))
    # THE FROST BEARD: icicles grown off that jaw.
    for by, bl in ((-0.28, 0.40), (-0.14, 0.60), (0.0, 0.72), (0.14, 0.58), (0.28, 0.38)):
        cone(fins, (0.74, by, 3.58), (0.80, by, 3.58 - bl), 0.085, 4)

    # Both fists on the harpoon: rear hand low by the hip, front hand high
    # and across - the heft.
    hand_lo, hand_hi = _harpoon_at(0.42), _harpoon_at(0.64)
    chain(body, [(0.18, 0.66, 3.22), (0.46, 0.60, 2.78), hand_lo], [0.22, 0.19, 0.15], 5)
    chain(body, [(0.18, -0.66, 3.22), (0.58, -0.88, 3.02), hand_hi], [0.22, 0.19, 0.15], 5)
    for h in (hand_lo, hand_hi):
        ellipsoid(body, h, (0.17, 0.17, 0.17), 1)

    # THE HARPOON (gear -> fins): shaft, butt knob, leaf head, two barbs
    # swept back in the shaft's vertical plane so they stay in silhouette.
    d = (_HARPOON_TIP - _HARPOON_BUTT).normalized()
    side = d.cross(Vector((0, 0, 1))).normalized()
    up = side.cross(d).normalized()
    limb(fins, _HARPOON_BUTT, _HARPOON_TIP, 0.085, 0.065, 5)
    ellipsoid(fins, _HARPOON_BUTT, (0.14, 0.14, 0.14), 1)
    head_base = _HARPOON_TIP - d * 0.72
    cone(fins, head_base, _HARPOON_TIP + d * 0.22, 0.19, 5)
    for s in (-1, 1):
        cone(fins, head_base, head_base - d * 0.26 + up * (s * 0.46), 0.075, 4)
    # Ice grown along the shaft where it has sat frozen to his hands.
    for t in (0.30, 0.52, 0.74):
        p = _harpoon_at(t)
        ellipsoid(fins, p, (0.15, 0.13, 0.14), 0)

    # The rime-rope: lashed at the head end, sagging back around the hip.
    _rime_rope(
        fins,
        [
            _harpoon_at(0.80),
            (1.20, -1.05, 2.90),
            (0.70, -1.15, 2.20),
            (0.05, -1.00, 1.85),
            (-0.55, -0.72, 2.05),
            (-0.78, -0.34, 2.42),
        ],
    )

    # SHEET ICE CASCADING OFF THE PORT SHOULDER: three slabs stepping out and
    # down, icicles hanging off each lip. This is the asymmetry that makes him
    # readable from any angle.
    for cx, cy, cz, sx, sy, sz, ang in (
        (-0.05, 0.80, 3.30, 1.12, 0.92, 0.20, -14),
        (-0.18, 1.14, 2.66, 0.94, 0.74, 0.18, -26),
        (-0.32, 1.34, 2.02, 0.68, 0.58, 0.16, -38),
    ):
        box(fins, (cx, cy, cz), (sx, sy, sz), Matrix.Rotation(math.radians(ang), 4, "X"))
        for k in range(3):
            ix = cx - 0.26 + k * 0.26
            iz = cz - sz * 0.6 - 0.1
            cone(fins, (ix, cy + sy * 0.40, iz), (ix, cy + sy * 0.40, iz - 0.34 - 0.16 * k), 0.07, 4)
    # A crust cap on the other shoulder and a slab down the back.
    box(fins, (-0.16, -0.62, 3.34), (0.62, 0.62, 0.28), Matrix.Rotation(math.radians(18), 4, "X"))
    box(fins, (-0.52, 0, 2.60), (0.36, 1.20, 1.05), lean)

    # The glaze: cold light in the cracks, a rime collar behind the harpoon
    # head, and the stare.
    chain(marks, [(0.62, 0.55, 3.00), (0.68, 0.0, 2.52), (0.60, -0.55, 2.88)], [0.05, 0.06, 0.05], 4)
    chain(marks, [(0.55, 0.30, 2.05), (0.62, -0.15, 1.70)], [0.05, 0.04], 4)
    ellipsoid(marks, _HARPOON_TIP - d * 0.92, (0.13, 0.13, 0.13), 0)
    for s in (-1, 1):
        ellipsoid(eyes, (0.84, s * 0.17, 3.92), (0.09, 0.09, 0.11), 0)

    return [
        finish("FrozenMariner_Body", body, MATS["FrozenMariner_Body"]),
        finish("FrozenMariner_Fins", fins, MATS["FrozenMariner_Fins"]),
        finish("FrozenMariner_Eyes", eyes, MATS["FrozenMariner_Eyes"]),
        finish("FrozenMariner_Marks", marks, MATS["FrozenMariner_Marks"]),
    ]


# ---- Aurora Jelly (drifter): a bell with the northern lights caught in it -
# an aurora ribbon winds around the bell. UPRIGHT (stance).
def build_aurorajelly():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    dome(body, (0, 0, 1.9), (1.15, 1.15, 1.0), 2)
    ellipsoid(body, (0, 0, 1.9), (1.18, 1.18, 0.3), 1)
    # Tentacles: a drifting skirt.
    for k in range(7):
        a = (k / 7) * TAU
        bx, by = math.cos(a) * 0.85, math.sin(a) * 0.85
        chain(fins, [(bx, by, 1.7), (bx * 1.25, by * 1.25, 0.9), (bx * 1.45, by * 1.45, 0.2)], [0.09, 0.06, 0.02], 4)
    # Two longer oral arms trailing centre.
    for s in (-1, 1):
        chain(fins, [(0.15 * s, -0.1 * s, 1.7), (0.35 * s, -0.3 * s, 0.7), (0.6 * s, -0.2 * s, 0.05)], [0.12, 0.08, 0.03], 4)
    # The aurora: a ribbon of glowing arcs winding around the bell.
    ribbon = []
    for k in range(9):
        t = k / 8
        a = t * TAU * 0.9 + 0.4
        r = 1.05 - 0.25 * t
        ribbon.append((math.cos(a) * r, math.sin(a) * r, 2.0 + t * 0.85))
    chain(marks, ribbon, [0.07] * len(ribbon), 4)
    ellipsoid(marks, (0, 0, 2.35), (0.35, 0.35, 0.3), 1)
    for s in (-1, 1):
        ellipsoid(eyes, (0.55, s * 0.3, 1.75), (0.07, 0.07, 0.07), 0)

    return [
        finish("AuroraJelly_Body", body, MATS["AuroraJelly_Body"]),
        finish("AuroraJelly_Fins", fins, MATS["AuroraJelly_Fins"]),
        finish("AuroraJelly_Eyes", eyes, MATS["AuroraJelly_Eyes"]),
        finish("AuroraJelly_Marks", marks, MATS["AuroraJelly_Marks"]),
    ]


# ---- Blizzard Wraith (gascloud): a gaunt storm-shade. It has NO LEGS - the
# body shreds into blown snow below the ribs and streams away downwind - a
# cowl ringed with icicles, and a jagged ice shard-blade in its fist.
# UPRIGHT (stance).


def build_blizzardwraith():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # Gaunt shoulder yoke and a starved ribcage - the only part of it that
    # holds a shape. Wide shoulders under a small cowl: that contrast is what
    # stops it reading as a bullet.
    box(body, (0.05, 0, 3.10), (0.58, 1.62, 0.38))
    for s in (-1, 1):
        cone(fins, (0.10, s * 0.72, 3.24), (0.42, s * 1.02, 3.72), 0.13, 4)  # clavicle spikes
    revolve(body, [(-1.05, 0.30), (-0.30, 0.54), (0.30, 0.50), (0.62, 0.34)], sides=7, axis="z", center=(0.05, 0, 2.86), squash=0.85)

    # BELOW THE RIBS IT IS NOT A BODY: seven tatters of the wraith torn off
    # downwind (-X), fanning out and thinning to nothing before they reach
    # the ground. No legs, no feet - that absence is the silhouette.
    for k in range(7):
        a = (k / 7) * TAU
        sway = math.sin(a * 2.0)
        bx, by = math.cos(a) * 0.30, math.sin(a) * 0.34
        chain(
            body,
            [
                (0.05 + bx, by, 1.95),
                (-0.25 + bx * 1.4, by * 1.7 + 0.10 * sway, 1.42),
                (-0.70 + bx * 1.2, by * 2.1 + 0.24 * sway, 0.92),
                (-1.12 + bx * 0.8, by * 2.4 + 0.34 * sway, 0.52),
                (-1.45 + bx * 0.4, by * 2.6 + 0.40 * sway, 0.16),
            ],
            [0.22, 0.17, 0.12, 0.07, 0.02],
            4,
        )
    # Snow torn loose and left hanging in the trail.
    for px, py, pz, r in (
        (-0.55, 0.60, 1.28, 0.20),
        (-1.00, -0.72, 0.82, 0.17),
        (-1.42, 0.48, 0.42, 0.14),
        (-0.80, 0.10, 0.34, 0.12),
        (-1.58, -0.32, 0.66, 0.11),
    ):
        ellipsoid(fins, (px, py, pz), (r, r * 0.85, r * 0.8), 0)

    # The head, and the cowl over it: a cone-shell open at the front with a
    # ring of icicles hung off its rim.
    ellipsoid(body, (0.26, 0, 3.66), (0.34, 0.32, 0.38), 1)
    revolve(fins, [(-0.50, 0.56), (0.0, 0.52), (0.34, 0.34), (0.56, 0.0)], sides=7, axis="z", center=(-0.06, 0, 3.68), squash=1.0)
    for k in range(9):
        a = (k / 9) * TAU
        ix, iy = -0.06 + math.cos(a) * 0.54, math.sin(a) * 0.52
        ln = 0.36 + 0.36 * max(0.0, math.cos(a))
        cone(fins, (ix, iy, 3.19), (ix + 0.06, iy, 3.19 - ln), 0.065, 4)

    # Blade arm thrust forward; the off arm flung back and already coming
    # apart into drift.
    chain(body, [(0.10, -0.58, 3.08), (0.70, -0.80, 2.86), (1.26, -0.62, 3.10)], [0.17, 0.13, 0.10], 5)
    ellipsoid(body, (1.28, -0.62, 3.12), (0.15, 0.14, 0.15), 1)
    chain(body, [(0.10, 0.60, 3.08), (-0.42, 0.94, 2.82), (-1.05, 1.12, 2.42)], [0.17, 0.12, 0.03], 5)

    # THE SHARD-BLADE (gear -> fins): a grip, a long fractured shard and a
    # second prong splitting off it.
    limb(fins, (1.14, -0.62, 2.84), (1.44, -0.62, 3.26), 0.09, 0.09, 5)
    # Built SOLID on four sides rather than as a flat plate: a plate would
    # vanish edge-on, and head-on is exactly how the player meets it.
    chain(
        fins,
        [(1.22, -0.62, 2.92), (1.55, -0.60, 3.30), (1.78, -0.64, 3.52), (2.10, -0.60, 3.90), (2.44, -0.62, 4.26)],
        [0.20, 0.28, 0.17, 0.20, 0.015],
        4,
    )
    chain(fins, [(1.70, -0.62, 3.44), (1.98, -0.72, 3.50), (2.26, -0.78, 3.54)], [0.12, 0.08, 0.015], 4)  # spur
    chain(fins, [(1.18, -0.62, 2.86), (1.02, -0.60, 2.48), (0.88, -0.62, 2.12)], [0.14, 0.09, 0.015], 4)  # broken guard
    # Cold light in the blade's fracture, the heart of the squall, the stare.
    chain(marks, [(1.32, -0.62, 3.10), (1.74, -0.62, 3.62), (2.40, -0.62, 4.24)], [0.05, 0.06, 0.02], 4)
    ellipsoid(marks, (0.26, 0, 2.96), (0.24, 0.20, 0.26), 1)
    for s in (-1, 1):
        ellipsoid(eyes, (0.48, s * 0.17, 3.74), (0.10, 0.09, 0.12), 0)

    return [
        finish("BlizzardWraith_Body", body, MATS["BlizzardWraith_Body"]),
        finish("BlizzardWraith_Fins", fins, MATS["BlizzardWraith_Fins"]),
        finish("BlizzardWraith_Eyes", eyes, MATS["BlizzardWraith_Eyes"]),
        finish("BlizzardWraith_Marks", marks, MATS["BlizzardWraith_Marks"]),
    ]


# ---------------------------------------------------------------- Gloomtrench hostiles
# The dark island's roster: every light down here is a lure or a warning.


# ---- Gulper Eel (spitter): mostly mouth - a vast gaping maw on a thin
# tail, photophores tracing it back into the dark. Flat, front +X.
def build_gulpereel():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # The maw: flares open toward +X (open_end).
    revolve(body, [(-0.8, 0.1), (0.0, 0.75), (1.0, 1.05), (1.7, 0.95)], sides=9, axis="x", center=(0.6, 0, 1.05), squash=0.95, open_end=True)
    # The pouch jaw hanging under it.
    dome(body, (1.5, 0, 0.55), (1.0, 0.8, 0.5), 1)
    bmesh.ops.transform(body, matrix=Matrix.Translation(Vector((1.5, 0, 0.55))) @ Matrix.Rotation(math.pi, 4, "Y") @ Matrix.Translation(Vector((-1.5, 0, -0.55))), verts=[v for v in body.verts if v.co.x > 0.4 and v.co.z < 0.85])
    # The tail: a whip winding back, thin as string by the end.
    tail = [(-0.2, 0, 1.0), (-1.4, 0.35, 0.95), (-2.6, -0.3, 0.85), (-3.7, 0.2, 0.8)]
    chain(body, tail, [0.4, 0.24, 0.13, 0.05], 5)
    plate(fins, [(-3.5, 1.0), (-4.3, 1.15), (-4.1, 0.75)], 0.07, "xz", offset=(0, 0.2, 0))
    # Photophores: a dotted line down the tail and around the jaw rim, and
    # the tail-tip light it waves to bait prey.
    for i, (px, py, pz) in enumerate(tail):
        ellipsoid(marks, (px, py, pz + 0.35 - i * 0.05), (0.09, 0.09, 0.09), 0)
    for a in (-0.9, 0, 0.9):
        ellipsoid(marks, (2.2, math.sin(a) * 0.85, 1.15 + math.cos(a) * 0.55), (0.08, 0.08, 0.08), 0)
    ellipsoid(marks, (-3.85, 0.25, 0.85), (0.15, 0.15, 0.16), 1)
    for s in (-1, 1):
        ellipsoid(eyes, (0.35, s * 0.55, 1.6), (0.1, 0.09, 0.1), 0)

    return [
        finish("GulperEel_Body", body, MATS["GulperEel_Body"]),
        finish("GulperEel_Fins", fins, MATS["GulperEel_Fins"]),
        finish("GulperEel_Eyes", eyes, MATS["GulperEel_Eyes"]),
        finish("GulperEel_Marks", marks, MATS["GulperEel_Marks"]),
    ]


# ---- Flashbulb Squid (drifter): a squid built around one huge lamp - the
# blinding pop is its whole trick. UPRIGHT (stance).
def build_flashbulbsquid():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    revolve(body, [(0.0, 0.18), (0.8, 0.62), (1.9, 0.5), (2.6, 0.0)], sides=8, axis="z", center=(0, 0, 1.6), squash=0.95)
    # Side fins near the mantle tip.
    for s in (-1, 1):
        plate(fins, [(0.1, s * 0.45), (-0.4, s * 1.05), (-0.7, s * 0.4)], 0.08, "xy", offset=(0, 0, 3.6))
    # Arms: eight, curling out and down.
    for k in range(8):
        a = (k / 8) * TAU
        bx, by = math.cos(a) * 0.4, math.sin(a) * 0.4
        chain(fins, [(bx, by, 1.5), (bx * 2.6, by * 2.6, 0.8), (bx * 3.4, by * 3.4, 0.25)], [0.11, 0.07, 0.02], 4)
    # THE BULB: bulging out of the mantle's front, plus a charge ring.
    ellipsoid(marks, (0.55, 0, 2.5), (0.55, 0.5, 0.6), 1)
    limb(marks, (0, 0, 1.35), (0, 0, 1.5), 0.62, 0.66, 9)
    for s in (-1, 1):
        ellipsoid(eyes, (0.45, s * 0.42, 1.75), (0.16, 0.14, 0.16), 1)

    return [
        finish("FlashbulbSquid_Body", body, MATS["FlashbulbSquid_Body"]),
        finish("FlashbulbSquid_Fins", fins, MATS["FlashbulbSquid_Fins"]),
        finish("FlashbulbSquid_Eyes", eyes, MATS["FlashbulbSquid_Eyes"]),
        finish("FlashbulbSquid_Marks", marks, MATS["FlashbulbSquid_Marks"]),
    ]


# ---- Trench Skitterer (charger): a giant deep-sea isopod - overlapping
# shell segments, too many legs, long feelers. Flat, front +X.
def build_trenchskitterer():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # Four overlapping shell segments, nose to tail.
    for i, (x, w, h) in enumerate(((1.0, 0.75, 0.5), (0.25, 0.85, 0.56), (-0.55, 0.8, 0.52), (-1.3, 0.65, 0.44))):
        dome(body, (x, 0, 0.3), (0.55, w, h), 1)
    cone(body, (-1.7, 0, 0.35), (-2.4, 0, 0.3), 0.3, 6)
    # The head shield and feelers.
    dome(body, (1.55, 0, 0.28), (0.45, 0.6, 0.42), 1)
    for s in (-1, 1):
        chain(fins, [(1.8, s * 0.2, 0.5), (2.6, s * 0.6, 0.7), (3.1, s * 0.9, 0.5)], [0.05, 0.04, 0.02], 4)
    # Legs: five a side.
    for sy in (-1, 1):
        for i in range(5):
            x = 1.1 - i * 0.55
            chain(fins, [(x, sy * 0.6, 0.25), (x + 0.05, sy * 1.05, 0.4), (x + 0.1, sy * 1.3, 0.0)], [0.06, 0.05, 0.015], 4)
    # Dim sensory dots along each segment's rim.
    for i, x in enumerate((1.0, 0.25, -0.55, -1.3)):
        for s in (-1, 1):
            ellipsoid(marks, (x, s * (0.72 - i * 0.03), 0.5), (0.06, 0.06, 0.06), 0)
    for s in (-1, 1):
        ellipsoid(eyes, (1.85, s * 0.3, 0.55), (0.1, 0.08, 0.08), 0)

    return [
        finish("TrenchSkitterer_Body", body, MATS["TrenchSkitterer_Body"]),
        finish("TrenchSkitterer_Fins", fins, MATS["TrenchSkitterer_Fins"]),
        finish("TrenchSkitterer_Eyes", eyes, MATS["TrenchSkitterer_Eyes"]),
        finish("TrenchSkitterer_Marks", marks, MATS["TrenchSkitterer_Marks"]),
    ]


# ---- Lanternjaw Angler (mimic): a hanging light that turns out to be a
# mouth. MIMIC LID CONTRACT: the whole upper jaw is the _Fins object, the
# lower jaw is centred on x=0, and the engine hinges the lid 0.9 behind
# centre. The lamp rides a stalk off the LOWER body so it stays put while
# the jaw snaps. UPRIGHT (stance, like the Mimic).
def build_lanternjawangler():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # Lower jaw: a broad scoop centred on x=0, teeth around its front rim.
    dome(body, (0, 0, 0.62), (1.35, 1.0, 0.55), 1)
    bmesh.ops.transform(body, matrix=Matrix.Translation(Vector((0, 0, 0.62))) @ Matrix.Rotation(math.pi, 4, "X") @ Matrix.Translation(Vector((0, 0, -0.62))), verts=all_verts(body))
    ellipsoid(body, (0, 0, 0.6), (1.4, 1.05, 0.2), 1)
    for a in (-1.1, -0.55, 0.0, 0.55, 1.1):
        px, py = math.cos(a * 0.75) * 1.25, math.sin(a) * 0.85
        cone(body, (px, py, 0.6), (px + 0.05, py, 1.05), 0.09, 4)
    # Upper jaw (the lid): a skull-browed dome with fangs pointing down.
    dome(fins, (0, 0, 0.78), (1.4, 1.05, 0.75), 1)
    box(fins, (0.9, 0, 1.15), (0.7, 1.0, 0.3), Matrix.Rotation(math.radians(14), 4, "Y"))
    for a in (-0.9, -0.3, 0.3, 0.9):
        px, py = math.cos(a * 0.75) * 1.3, math.sin(a) * 0.8
        cone(fins, (px, py, 0.82), (px + 0.06, py, 0.35), 0.08, 4)
    # The lamp: a stalk off the lower body's back, arcing over the front.
    chain(body, [(-1.2, 0, 0.7), (-0.6, 0, 2.3), (0.9, 0, 2.9), (1.9, 0, 2.6)], [0.16, 0.12, 0.09, 0.07], 5)
    ellipsoid(marks, (2.05, 0, 2.25), (0.4, 0.4, 0.45), 1)
    # Glowing gum-line dots along the lower rim - the "hanging light" it
    # pretends to be from a distance.
    for a in (-0.8, 0.0, 0.8):
        ellipsoid(marks, (math.cos(a * 0.75) * 1.05, math.sin(a) * 0.7, 0.68), (0.08, 0.08, 0.08), 0)
    for s in (-1, 1):
        ellipsoid(eyes, (0.55, s * 0.75, 0.85), (0.12, 0.1, 0.12), 1)

    return [
        finish("LanternjawAngler_Body", body, MATS["LanternjawAngler_Body"]),
        finish("LanternjawAngler_Fins", fins, MATS["LanternjawAngler_Fins"]),
        finish("LanternjawAngler_Eyes", eyes, MATS["LanternjawAngler_Eyes"]),
        finish("LanternjawAngler_Marks", marks, MATS["LanternjawAngler_Marks"]),
    ]


# ---- Vampire Squid (thief): a blood-dark squid swimming cloaked - the
# webbed skirt flares forward around the arms. Flat, front +X.
def build_vampiresquid():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    revolve(body, [(-1.9, 0.0), (-1.0, 0.55), (0.0, 0.72), (0.8, 0.55), (1.1, 0.35)], sides=8, axis="x", center=(0, 0, 0.85), squash=0.95)
    # The cloak: a skirt flaring open toward +X.
    revolve(body, [(0.9, 0.6), (2.1, 1.15)], sides=9, axis="x", center=(0, 0, 0.85), squash=0.95, open_end=True)
    # Arm tips hooking out past the skirt rim.
    for k in range(8):
        a = (k / 8) * TAU + 0.2
        by, bz = math.cos(a) * 1.1, math.sin(a) * 1.05
        cone(fins, (2.05, by, 0.85 + bz), (2.55, by * 1.15, 0.85 + bz * 1.15), 0.08, 4)
    # Cirri: thin spines lining the skirt's inside.
    for k in range(6):
        a = (k / 6) * TAU
        by, bz = math.cos(a) * 0.75, math.sin(a) * 0.72
        cone(fins, (1.7, by, 0.85 + bz), (2.0, by * 0.8, 0.85 + bz * 0.8), 0.04, 4)
    # Ear-fins on the mantle.
    for s in (-1, 1):
        plate(fins, [(-0.9, 0.9), (-1.6, 1.5), (-1.8, 0.9)], 0.09, "xz", offset=(0, s * 0.35, 0))
    # Huge blood-lit eyes, and dim photophore dots on the mantle tip.
    for s in (-1, 1):
        ellipsoid(eyes, (0.75, s * 0.62, 1.15), (0.24, 0.2, 0.22), 1)
    for s in (-1, 1):
        ellipsoid(marks, (-1.55, s * 0.3, 1.1), (0.08, 0.08, 0.08), 0)

    return [
        finish("VampireSquid_Body", body, MATS["VampireSquid_Body"]),
        finish("VampireSquid_Fins", fins, MATS["VampireSquid_Fins"]),
        finish("VampireSquid_Eyes", eyes, MATS["VampireSquid_Eyes"]),
        finish("VampireSquid_Marks", marks, MATS["VampireSquid_Marks"]),
    ]


# ---- Pressure Crab (thornback): a crab armoured like a pressure vessel -
# riveted iron-dark plates, crusher claws held like shields. Flat, front +X.
def build_pressurecrab():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    dome(body, (0, 0, 0.42), (1.2, 1.0, 0.7), 1)
    ellipsoid(body, (0, 0, 0.42), (1.25, 1.05, 0.3), 1)
    # The plates: banded armour over the dome, rivets down each seam.
    for i, x in enumerate((0.55, 0.0, -0.55)):
        box(fins, (x, 0, 0.85), (0.32, 1.9, 0.35))
        for s in (-1, 1):
            for j in range(3):
                ellipsoid(marks, (x, s * (0.4 + j * 0.35), 1.05), (0.05, 0.05, 0.05), 0)
    # Thorn bosses on the shell's crown.
    for dx, dy in ((0.3, 0.45), (-0.35, -0.4), (0.0, 0.0)):
        cone(fins, (dx, dy, 1.05), (dx * 1.3, dy * 1.3, 1.45), 0.14, 5)
    # Legs: three per side, thick, tucked close.
    for sy in (-1, 1):
        for i in range(3):
            x = 0.4 - i * 0.45
            chain(body, [(x, sy * 0.7, 0.4), (x + 0.05, sy * 1.1, 0.6), (x + 0.1, sy * 1.35, 0.0)], [0.11, 0.09, 0.03], 5)
    # Crusher claws held up like tower shields, well forward.
    for s in (-1, 1):
        chain(body, [(0.85, s * 0.55, 0.45), (1.6, s * 0.75, 0.6)], [0.16, 0.12], 5)
        box(fins, (2.0, s * 0.8, 0.7), (0.55, 0.35, 0.75))
    for s in (-1, 1):
        limb(body, (1.0, s * 0.25, 0.85), (1.1, s * 0.28, 1.15), 0.05, 0.04, 4)
        ellipsoid(eyes, (1.12, s * 0.29, 1.2), (0.08, 0.08, 0.08), 0)

    return [
        finish("PressureCrab_Body", body, MATS["PressureCrab_Body"]),
        finish("PressureCrab_Fins", fins, MATS["PressureCrab_Fins"]),
        finish("PressureCrab_Eyes", eyes, MATS["PressureCrab_Eyes"]),
        finish("PressureCrab_Marks", marks, MATS["PressureCrab_Marks"]),
    ]


# ---- Void Ray (pulser): a winged disc of not-quite-darkness, its edges
# traced in void light. Flat, front +X.
def build_voidray():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    ellipsoid(body, (0, 0, 0.55), (1.5, 1.1, 0.32), 1)
    # Wings: swept-back deltas.
    for s in (-1, 1):
        plate(fins, [(0.8, s * 0.7), (-0.4, s * 1.95), (-1.7, s * 2.0), (-0.9, s * 0.9), (-0.6, s * 0.6)], 0.14, "xy", offset=(0, 0, 0.55))
    # Head horns and the tail whip.
    for s in (-1, 1):
        cone(body, (1.4, s * 0.35, 0.55), (1.9, s * 0.5, 0.5), 0.1, 4)
    chain(body, [(-1.4, 0, 0.55), (-2.3, 0.15, 0.6), (-3.0, 0.0, 0.5)], [0.12, 0.07, 0.02], 4)
    # The void light: glowing trims along both wings' trailing edges and a
    # pulse core in the disc's centre.
    for s in (-1, 1):
        chain(marks, [(-0.35, s * 1.85, 0.6), (-1.55, s * 1.9, 0.6), (-0.85, s * 0.95, 0.6)], [0.05, 0.05, 0.04], 4)
    ellipsoid(marks, (0.1, 0, 0.8), (0.35, 0.28, 0.12), 1)
    for s in (-1, 1):
        ellipsoid(eyes, (1.15, s * 0.4, 0.75), (0.1, 0.08, 0.08), 0)

    return [
        finish("VoidRay_Body", body, MATS["VoidRay_Body"]),
        finish("VoidRay_Fins", fins, MATS["VoidRay_Fins"]),
        finish("VoidRay_Eyes", eyes, MATS["VoidRay_Eyes"]),
        finish("VoidRay_Marks", marks, MATS["VoidRay_Marks"]),
    ]


# ---- Silt Stalker (burrower): a low segmented ambusher with folded scythe
# claws, half sediment itself. Flat, front +X.
def build_siltstalker():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # Segmented low body, tapering tail.
    for i, (x, w, h) in enumerate(((0.8, 0.8, 0.5), (0.0, 0.9, 0.55), (-0.85, 0.8, 0.5), (-1.65, 0.6, 0.4))):
        dome(body, (x, 0, 0.25), (0.6, w, h), 1)
    chain(body, [(-2.0, 0, 0.4), (-2.9, 0.25, 0.35), (-3.6, 0.1, 0.3)], [0.28, 0.16, 0.05], 5)
    # The head wedge and the scythe claws folded forward.
    dome(body, (1.4, 0, 0.25), (0.55, 0.65, 0.5), 1)
    for s in (-1, 1):
        chain(fins, [(1.3, s * 0.5, 0.5), (2.3, s * 0.85, 0.75), (3.1, s * 0.45, 0.35)], [0.14, 0.11, 0.03], 5)
        cone(fins, (3.1, s * 0.45, 0.35), (3.5, s * 0.25, 0.1), 0.07, 4)
    # Silt frill skirts along both sides.
    for s in (-1, 1):
        plate(fins, [(1.0, s * 0.75), (0.0, s * 1.15), (-1.2, s * 1.05), (-1.8, s * 0.7), (-0.4, s * 0.8)], 0.1, "xy", offset=(0, 0, 0.18))
    # Sensory dots in a row down the spine ridge.
    for x in (0.8, 0.0, -0.85, -1.65):
        ellipsoid(marks, (x, 0, 0.82), (0.07, 0.07, 0.07), 0)
    for s in (-1, 1):
        ellipsoid(eyes, (1.7, s * 0.3, 0.55), (0.09, 0.08, 0.08), 0)

    return [
        finish("SiltStalker_Body", body, MATS["SiltStalker_Body"]),
        finish("SiltStalker_Fins", fins, MATS["SiltStalker_Fins"]),
        finish("SiltStalker_Eyes", eyes, MATS["SiltStalker_Eyes"]),
        finish("SiltStalker_Marks", marks, MATS["SiltStalker_Marks"]),
    ]


# ---------------------------------------------------------------- Wreckwater hostiles
# The ghost-fleet's roster: drowned crew, cursed cargo, ghost-fire.


# ---- Cannonball Crab (rusher): a crab that moved into a cannonball - the
# fuse still fizzes. Flat, front +X.
def build_cannonballcrab():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    ellipsoid(body, (0, 0, 0.8), (0.88, 0.85, 0.85), 1)
    limb(body, (0, -0.86, 0.8), (0, 0.86, 0.8), 0.1, 0.1, 8)  # the casting band
    # The crab underneath: legs and claws poking out of the shot.
    for sy in (-1, 1):
        for i in range(3):
            x = 0.3 - i * 0.35
            chain(fins, [(x, sy * 0.55, 0.35), (x + 0.05, sy * 0.95, 0.5), (x + 0.1, sy * 1.15, 0.0)], [0.08, 0.06, 0.02], 4)
        chain(fins, [(0.7, sy * 0.4, 0.35), (1.4, sy * 0.55, 0.4)], [0.12, 0.09], 5)
        ellipsoid(fins, (1.68, sy * 0.58, 0.4), (0.3, 0.18, 0.16), 1)
    # The fuse: a short stub off the top, spark glowing at its tip.
    chain(body, [(-0.2, 0, 1.55), (-0.32, 0.12, 1.78)], [0.08, 0.05], 4)
    ellipsoid(marks, (-0.36, 0.15, 1.86), (0.13, 0.12, 0.13), 1)
    # Eye stalks between the shell and the claws.
    for s in (-1, 1):
        limb(fins, (0.75, s * 0.2, 0.95), (0.9, s * 0.24, 1.2), 0.05, 0.04, 4)
        ellipsoid(eyes, (0.92, s * 0.25, 1.25), (0.08, 0.08, 0.08), 0)

    return [
        finish("CannonballCrab_Body", body, MATS["CannonballCrab_Body"]),
        finish("CannonballCrab_Fins", fins, MATS["CannonballCrab_Fins"]),
        finish("CannonballCrab_Eyes", eyes, MATS["CannonballCrab_Eyes"]),
        finish("CannonballCrab_Marks", marks, MATS["CannonballCrab_Marks"]),
    ]


# ---- Drowned Boatswain (shambler): the barnacled bosun - a rotted
# knee-length greatcoat, a rope coil slung bandolier-style, a boarding axe
# swung two-handed, and a crab living in his opened ribcage.
# UPRIGHT (stance).
def build_drownedboatswain():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    for s in (-1, 1):
        box(body, (0, s * 0.4, 0.8), (0.55, 0.5, 1.6))
    box(body, (0, 0, 2.5), (0.9, 1.45, 1.9), Matrix.Rotation(math.radians(-5), 4, "Y"))
    box(body, (0.1, -0.05, 3.85), (0.75, 0.75, 0.8))
    box(body, (0.42, -0.05, 3.62), (0.3, 0.55, 0.34))  # jutting jaw

    # The greatcoat: a knee-length skirt flaring off the belt, its hem torn
    # into panels, plus a heavy standing collar and two lapels.
    revolve(fins, [(0.0, 0.7), (-0.5, 0.8), (-1.05, 0.86)], sides=6, axis="z", center=(0.02, 0, 1.85))
    for k in range(4):
        a = (k / 4) * TAU + 0.3
        bx, by = math.cos(a) * 0.84, math.sin(a) * 0.84
        cone(fins, (0.02 + bx, by, 0.84), (0.02 + bx * 1.06, by * 1.06, 0.28), 0.22, 4)
    box(fins, (0.02, 0, 3.36), (0.8, 1.6, 0.3))  # collar
    for s in (-1, 1):
        box(fins, (0.46, s * 0.56, 2.72), (0.3, 0.44, 1.45), Matrix.Rotation(math.radians(s * 10), 4, "X"))

    # The rope: a coil slung shoulder to hip, with the tail of it hanging
    # looped off the belt.
    for i in range(3):
        t = i * 0.2
        limb(fins, (0.5 - t * 0.05, 0.72 - t, 3.24 - t * 0.5), (0.46, -0.6 - t * 0.1, 2.05 - t * 0.4), 0.085, 0.085, 4)
    _wk_arc(fins, (0.42, -0.78, 1.92), 0.26, 0.0, TAU, 4, 0.07, 0.07, "xz", 3)

    # The ribcage, laid open where the coat is torn away on the starboard
    # side: three bare ribs standing proud of the chest.
    for k in range(3):
        _wk_arc(body, (0.0, 0.06, 2.42 + k * 0.36), 0.72, -0.2, 1.5, 2, 0.06, 0.045, "xy", 3)
    # And the crab that has moved into the cavity: shell, claws and legs
    # poking out between the ribs. In _Marks so it lights with the drowned
    # glow - the tell that something is still ALIVE inside him.
    crab = Vector((0.62, 0.52, 2.86))
    box(marks, crab, (0.4, 0.44, 0.24))
    for s in (-1, 1):
        limb(marks, crab + Vector((0.15, s * 0.2, 0.02)), crab + Vector((0.4, s * 0.36, 0.07)), 0.055, 0.035, 3)
        cone(marks, crab + Vector((0.4, s * 0.36, 0.07)), crab + Vector((0.62, s * 0.44, 0.14)), 0.09, 4)
        limb(marks, crab + Vector((-0.06, s * 0.2, 0.0)), crab + Vector((-0.15, s * 0.44, -0.18)), 0.045, 0.022, 3)

    # The boarding axe, caught mid-swing: hauled up and over his off shoulder
    # on a long haft, both fists on it, a broad bit and a back-spike.
    haft_a = Vector((0.55, 0.8, 1.75))
    haft_b = Vector((1.32, -1.32, 3.95))
    limb(fins, haft_a, haft_b, 0.11, 0.1, 5)
    head_p = haft_a + (haft_b - haft_a) * 0.9
    box(fins, head_p, (0.24, 0.36, 0.3))  # the eye the haft passes through
    plate(
        fins,
        [(0.92, 3.28), (2.05, 3.24), (2.32, 3.88), (2.05, 4.24), (0.98, 4.02)],
        0.14,
        "xz",
        offset=(0, head_p.y, 0),
    )
    cone(fins, (1.06, head_p.y, 3.78), (0.5, head_p.y, 4.02), 0.11, 4)  # back-spike
    for sh, elb, grip in (
        ((0.15, 0.78, 3.15), (0.75, 0.98, 2.45), 0.14),
        ((0.15, -0.78, 3.15), (0.9, -1.05, 3.05), 0.52),
    ):
        hand = haft_a + (haft_b - haft_a) * grip
        limb(body, sh, elb, 0.23, 0.18, 5)
        limb(body, elb, hand, 0.18, 0.14, 5)
        box(body, hand, (0.26, 0.26, 0.26))

    # Barnacles crusting the shoulders and the coat.
    for base, out in (
        ((0.06, 0.66, 3.28), (0.05, 0.18, 0.11)),
        ((-0.3, -0.5, 2.62), (-0.2, -0.16, 0.05)),
        ((-0.5, 0.32, 1.5), (-0.24, 0.11, -0.05)),
        ((0.3, -0.72, 1.25), (0.15, -0.22, -0.08)),
    ):
        _wk_barnacle(fins, base, out)

    # The belt lantern still lit, and the drowned glow bleeding through him.
    limb(fins, (0.34, -0.92, 1.6), (0.36, -0.98, 1.4), 0.05, 0.05, 4)
    ellipsoid(marks, (0.36, -0.98, 1.2), (0.17, 0.17, 0.21), 0)
    chain(marks, [(0.52, 0.2, 3.24), (0.54, 0.34, 2.74)], [0.04, 0.04], 4)
    for s in (-1, 1):
        ellipsoid(eyes, (0.5, -0.05 + s * 0.22, 3.95), (0.09, 0.09, 0.11), 0)

    return [
        finish("DrownedBoatswain_Body", body, MATS["DrownedBoatswain_Body"]),
        finish("DrownedBoatswain_Fins", fins, MATS["DrownedBoatswain_Fins"]),
        finish("DrownedBoatswain_Eyes", eyes, MATS["DrownedBoatswain_Eyes"]),
        finish("DrownedBoatswain_Marks", marks, MATS["DrownedBoatswain_Marks"]),
    ]


# ---- Phantom Moray (charger): a moray that kept hunting after it stopped
# being alive - sinuous, tattered, lit in spectral rings. Flat, front +X.
def build_phantommoray():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    pts, radii = [], []
    n = 10
    for i in range(n):
        t = i / (n - 1)
        x = 2.2 - t * 5.2
        y = 0.85 * math.sin(t * math.pi * 1.8)
        pts.append((x, y, 0.62))
        radii.append(0.2 + 0.42 * math.sin(math.pi * min(max(t, 0.1), 0.9)))
    chain(body, pts, radii, 6)
    # Head: blunt, jaw agape, needle teeth.
    ellipsoid(body, (2.5, 0, 0.68), (0.65, 0.42, 0.42), 1)
    box(body, (2.9, 0, 0.35), (0.8, 0.55, 0.14), Matrix.Rotation(math.radians(10), 4, "Y"))
    for s in (-1, 1):
        for i in range(2):
            cone(fins, (2.75 + i * 0.25, s * 0.18, 0.55), (2.78 + i * 0.25, s * 0.18, 0.4), 0.035, 4)
            cone(fins, (2.7 + i * 0.25, s * 0.2, 0.42), (2.72 + i * 0.25, s * 0.2, 0.56), 0.035, 4)
    # The ragged dorsal ribbon down the whole spine.
    ribbon = []
    for i in range(n - 1):
        px, py, pz = pts[i]
        ribbon.append((px, pz + radii[i] + 0.32 + 0.12 * (i % 2)))
    ribbon += [(pts[-1][0], pts[-1][2])] + [(pts[0][0], pts[0][2])]
    plate(fins, ribbon, 0.1, "xz")
    # Spectral rings every few segments, and the grave-light eyes.
    for i in (1, 3, 5, 7):
        px, py, pz = pts[i]
        limb(marks, (px - 0.04, py, pz), (px + 0.04, py, pz), radii[i] + 0.06, radii[i] + 0.06, 7)
    for s in (-1, 1):
        ellipsoid(eyes, (2.6, s * 0.3, 0.92), (0.11, 0.09, 0.11), 1)

    return [
        finish("PhantomMoray_Body", body, MATS["PhantomMoray_Body"]),
        finish("PhantomMoray_Fins", fins, MATS["PhantomMoray_Fins"]),
        finish("PhantomMoray_Eyes", eyes, MATS["PhantomMoray_Eyes"]),
        finish("PhantomMoray_Marks", marks, MATS["PhantomMoray_Marks"]),
    ]


# ---- Cursed Chest (mimic): the wreck fleet's treasure, still hungry.
# MIMIC LID CONTRACT: the lid (with its fangs) is the whole _Fins object,
# the lower chest is centred on x=0. UPRIGHT (stance).
def build_cursedchest():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # The chest: banded planks, centred on x=0.
    box(body, (0, 0, 0.5), (2.0, 1.4, 0.95))
    for y in (-0.55, 0.0, 0.55):
        box(body, (0, y, 0.5), (2.05, 0.18, 1.0))
    # The lid: a domed top with iron bands and fangs down over the gape.
    dome(fins, (0, 0, 1.0), (1.05, 0.72, 0.5), 1)
    scale_verts(fins, all_verts(fins), 1.0, 1.0, 1.0)
    box(fins, (0, 0, 1.06), (2.1, 1.5, 0.22))
    for y in (-0.55, 0.0, 0.55):
        box(fins, (0, y, 1.15), (2.12, 0.18, 0.3))
    for i, y in enumerate((-0.5, -0.17, 0.17, 0.5)):
        cone(fins, (1.0, y, 1.02), (1.04, y, 0.62), 0.09, 4)
    # The tongue lolling out the front, coins stuck to it; a coin spill; and
    # curse runes on the front panel.
    chain(marks, [(0.9, 0.1, 0.72), (1.5, 0.15, 0.55), (1.9, 0.0, 0.3)], [0.22, 0.18, 0.08], 5)
    for px, py, pz in ((1.35, 0.15, 0.72), (1.05, -0.25, 0.95), (1.7, -0.3, 0.12), (2.0, 0.35, 0.08)):
        limb(marks, (px, py, pz - 0.03), (px, py, pz + 0.03), 0.14, 0.14, 7)
    for cx, ln, ang in ((-0.5, 0.35, 55), (0.0, 0.3, -40), (0.5, 0.32, 20)):
        box(marks, (1.02, cx, 0.45), (0.05, ln, 0.08), Matrix.Rotation(math.radians(ang), 4, "X"))
    # Eyes glaring out of the gape's shadow.
    for s in (-1, 1):
        ellipsoid(eyes, (0.95, s * 0.4, 0.93), (0.1, 0.09, 0.1), 1)

    return [
        finish("CursedChest_Body", body, MATS["CursedChest_Body"]),
        finish("CursedChest_Fins", fins, MATS["CursedChest_Fins"]),
        finish("CursedChest_Eyes", eyes, MATS["CursedChest_Eyes"]),
        finish("CursedChest_Marks", marks, MATS["CursedChest_Marks"]),
    ]


# ---- Plunder Sprite (thief): a sea-imp mid-dart, hauling a stolen goblet
# bigger than its head with a dagger shoved through its belt. It reads
# humanoid enough to deserve a face, so it got one - but it still SWIMS, so
# the pose stays prone. Flat, front +X (the loot leads).
def build_plundersprite():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # A hunched little body, shoulders up around a big-jawed head.
    ellipsoid(body, (-0.05, 0, 0.6), (0.7, 0.42, 0.38), 1)
    box(body, (-0.42, 0, 0.8), (0.55, 0.4, 0.18), Matrix.Rotation(math.radians(16), 4, "Y"))
    ellipsoid(body, (0.58, 0, 0.72), (0.34, 0.3, 0.28), 1)
    box(body, (0.84, 0, 0.6), (0.34, 0.3, 0.2))  # jutting grin
    box(body, (0.72, 0, 0.88), (0.24, 0.42, 0.12))  # heavy brow
    for s in (-1, 1):
        cone(body, (0.5, s * 0.2, 0.94), (0.64, s * 0.32, 1.16), 0.07, 4)  # horns
        cone(body, (0.45, s * 0.26, 0.74), (-0.2, s * 0.62, 0.86), 0.1, 4)  # long swept ears

    # THE HAUL: a goblet twice the size of its head, hugged in both arms.
    # Held UPRIGHT: a cup pointed down the swim axis is just a disc, but a
    # bowl-stem-foot standing on end reads as loot from any angle.
    revolve(
        marks,
        [(0.0, 0.16), (0.14, 0.26), (0.34, 0.42), (0.52, 0.48)],
        sides=8,
        axis="z",
        center=(1.06, 0, 0.5),
        open_end=True,
    )
    limb(marks, (1.06, 0, 0.5), (1.06, 0, 0.32), 0.08, 0.09, 5)  # stem
    limb(marks, (1.06, 0, 0.3), (1.06, 0, 0.24), 0.28, 0.28, 8)  # foot
    for s in (-1, 1):
        chain(body, [(0.3, s * 0.36, 0.6), (0.78, s * 0.46, 0.46), (1.02, s * 0.26, 0.42)], [0.1, 0.08, 0.06], 4)

    # A dagger shoved through its belt, hilt forward, and a swag pouch.
    box(fins, (-0.05, 0, 0.54), (0.66, 0.52, 0.13))
    plate(fins, [(-0.32, 0.32), (-1.0, 0.2), (-1.12, 0.28), (-0.36, 0.48)], 0.06, "xz", offset=(0, -0.44, 0))
    box(fins, (-0.26, -0.44, 0.42), (0.09, 0.3, 0.1))  # crossguard
    ellipsoid(fins, (-0.32, 0.5, 0.46), (0.2, 0.16, 0.16), 0)  # the pouch

    # Legs trailing into a swimmer's kick, and little wing-frills.
    for s in (-1, 1):
        chain(body, [(-0.5, s * 0.2, 0.55), (-1.05, s * 0.3, 0.72), (-1.5, s * 0.25, 0.5)], [0.08, 0.06, 0.02], 4)
        plate(fins, [(-0.1, s * 0.4), (-0.7, s * 0.95), (-1.1, s * 0.6), (-0.6, s * 0.38)], 0.07, "xy", offset=(0, 0, 0.85))
    # A trail of dropped coins behind it.
    for px, py in ((-1.3, 0.35), (-1.8, -0.2)):
        limb(marks, (px, py, 0.3), (px, py, 0.36), 0.16, 0.16, 7)
    for s in (-1, 1):
        ellipsoid(eyes, (0.76, s * 0.16, 0.8), (0.09, 0.08, 0.1), 0)

    return [
        finish("PlunderSprite_Body", body, MATS["PlunderSprite_Body"]),
        finish("PlunderSprite_Fins", fins, MATS["PlunderSprite_Fins"]),
        finish("PlunderSprite_Eyes", eyes, MATS["PlunderSprite_Eyes"]),
        finish("PlunderSprite_Marks", marks, MATS["PlunderSprite_Marks"]),
    ]


# ---- Ghostfire Jelly (gascloud): a jelly burning with cold fire - flame
# licks off the bell where a jelly has none. UPRIGHT (stance).
def build_ghostfirejelly():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    dome(body, (0, 0, 1.7), (1.05, 1.05, 0.9), 2)
    ellipsoid(body, (0, 0, 1.7), (1.08, 1.08, 0.28), 1)
    # The ghost-flames: licks curling off the crown.
    for k in range(5):
        a = (k / 5) * TAU
        bx, by = math.cos(a) * 0.55, math.sin(a) * 0.55
        cone(marks, (bx, by, 2.3), (bx * 1.6, by * 1.6, 3.0 + 0.3 * math.sin(a * 2 + 1)), 0.18, 4)
    cone(marks, (0, 0, 2.55), (0.12, 0, 3.5), 0.22, 5)
    # Tendrils: sparse and drifting.
    for k in range(6):
        a = (k / 6) * TAU + 0.4
        bx, by = math.cos(a) * 0.8, math.sin(a) * 0.8
        chain(fins, [(bx, by, 1.5), (bx * 1.3, by * 1.3, 0.7), (bx * 1.5, by * 1.5, 0.1)], [0.08, 0.05, 0.015], 4)
    # A faint witness of a face.
    for s in (-1, 1):
        ellipsoid(eyes, (0.5, s * 0.28, 1.6), (0.07, 0.07, 0.07), 0)

    return [
        finish("GhostfireJelly_Body", body, MATS["GhostfireJelly_Body"]),
        finish("GhostfireJelly_Fins", fins, MATS["GhostfireJelly_Fins"]),
        finish("GhostfireJelly_Eyes", eyes, MATS["GhostfireJelly_Eyes"]),
        finish("GhostfireJelly_Marks", marks, MATS["GhostfireJelly_Marks"]),
    ]


# ---- Wailing Gunner (spitter): a gunner's ghost FUSED to his swivel gun -
# the arms are the mount, thickening out of the shoulders and becoming the
# blunderbuss's breech and flared bell. He has no legs; he trails away.
# _Fins is the spectre (the pale flesh), _Body the ironwork - the row's
# color / finColor are set that way round.
# UPRIGHT (stance), front +X (the muzzle).
def build_wailinggunner():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # No legs: below the belt he thins into a ragged spectral taper with
    # streamers of shroud trailing off it.
    revolve(
        fins,
        [(0.0, 0.8), (-0.55, 0.68), (-1.15, 0.44), (-1.8, 0.18), (-2.2, 0.0)],
        sides=7,
        axis="z",
        center=(-0.12, 0, 2.3),
    )
    for k in range(4):
        a = (k / 4) * TAU + 0.5
        bx, by = math.cos(a) * 0.44, math.sin(a) * 0.44
        cone(fins, (-0.12 + bx, by, 1.2), (-0.12 + bx * 1.6, by * 1.6, 0.08), 0.17, 4)
    # Torso, and a head thrown back mid-scream with the jaw hanging open.
    box(fins, (0.0, 0, 3.0), (0.9, 1.5, 1.5), Matrix.Rotation(math.radians(8), 4, "Y"))
    ellipsoid(fins, (-0.18, 0, 3.86), (0.44, 0.42, 0.46), 1)
    box(fins, (0.16, 0, 3.6), (0.36, 0.6, 0.4), Matrix.Rotation(math.radians(-16), 4, "Y"))

    # The arms do not HOLD the gun - they become it: they leave the shoulders
    # as flesh and swell forward into the breech, thickening the whole way.
    # The gun is trained off the bow, not straight down it: canted to port so
    # the barrel and its bell read as a BLUNDERBUSS in silhouette instead of
    # vanishing into a foreshortened disc.
    breech = Vector((0.85, 0.18, 3.05))
    mid = Vector((1.62, -0.52, 3.02))
    bell = Vector((2.02, -0.88, 3.0))
    flare = Vector((2.42, -1.24, 2.98))
    for s in (-1, 1):
        limb(fins, (0.06, s * 0.72, 3.36), (0.5, s * 0.62, 3.2), 0.22, 0.26, 5)
        limb(fins, (0.5, s * 0.62, 3.2), (breech.x - 0.1, 0.18 + s * 0.18, breech.z), 0.26, 0.3, 5)
    box(body, breech, (0.8, 0.62, 0.62), Matrix.Rotation(math.radians(-42), 4, "Z"))
    limb(body, breech, mid, 0.26, 0.2, 7)
    limb(body, mid, bell, 0.2, 0.26, 8)  # the reinforce at the bell's throat
    limb(body, bell, flare, 0.24, 0.56, 8)  # the flared bell itself
    limb(body, flare, flare + Vector((0.06, -0.05, 0)), 0.6, 0.58, 8)  # the muzzle lip
    # Swivel yoke and lock: the ironwork the arms have grown around.
    yoke = Vector((1.45, -0.4, 3.02))
    for s in (-1, 1):
        limb(body, yoke + Vector((0, 0, -0.05)), yoke + Vector((-0.16 * s, -0.2 * s, 0.5)), 0.07, 0.07, 4)
    limb(body, yoke + Vector((0.16, 0.2, 0.45)), yoke + Vector((-0.16, -0.2, 0.45)), 0.05, 0.05, 4)
    box(body, (1.06, 0.1, 3.28), (0.5, 0.14, 0.3), Matrix.Rotation(math.radians(-42), 4, "Z"))  # lock plate
    _wk_arc(body, (0.92, 0.14, 2.78), 0.28, -2.5, -0.6, 3, 0.05, 0.05, "xz", 4)  # trigger guard
    # A powder horn slung on the hip, on a strap across the chest.
    chain(body, [(-0.5, -0.78, 2.2), (-0.15, -0.92, 1.9), (0.28, -0.84, 1.84)], [0.2, 0.13, 0.06], 5)
    limb(body, (0.02, 0.62, 3.36), (-0.32, -0.82, 2.24), 0.05, 0.05, 4)

    # Marks: the muzzle flash sitting in the bell, and the SCREAM - a ribbon
    # of sound widening as it streams back off his open mouth.
    cone(marks, flare + Vector((0.04, -0.04, 0)), flare + Vector((0.42, -0.38, 0.06)), 0.5, 7)
    ellipsoid(marks, (0.32, 0.02, 3.5), (0.15, 0.18, 0.22), 0)  # the open mouth
    p = Vector((0.26, 0.04, 3.58))
    for k in range(3):
        nxt = p + Vector((-0.42, 0.24, 0.14))
        limb(marks, p, nxt, 0.1 + k * 0.06, 0.16 + k * 0.06, 4)
        p = nxt
    for s in (-1, 1):
        ellipsoid(eyes, (0.14, s * 0.19, 3.98), (0.09, 0.08, 0.11), 0)

    return [
        finish("WailingGunner_Body", body, MATS["WailingGunner_Body"]),
        finish("WailingGunner_Fins", fins, MATS["WailingGunner_Fins"]),
        finish("WailingGunner_Eyes", eyes, MATS["WailingGunner_Eyes"]),
        finish("WailingGunner_Marks", marks, MATS["WailingGunner_Marks"]),
    ]


# ---------------------------------------------------------------- Blackmire Fen hostiles
# The swamp's remaining roster (the gull, wisp, dragonfly and Gnashroot are
# built above).


# ---- Croakjaw Toad (spitter): a boulder of a toad, mouth wider than its
# body is long, the glowing throat sac its spit tell. Flat, front +X.
def build_croakjawtoad():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    ellipsoid(body, (-0.5, 0, 0.75), (1.3, 1.0, 0.75), 1)
    # The mouth: a wide slab jaw across the whole front.
    box(body, (0.95, 0, 0.55), (1.1, 1.7, 0.3), Matrix.Rotation(math.radians(-6), 4, "Y"))
    box(body, (0.9, 0, 0.9), (1.0, 1.6, 0.28), Matrix.Rotation(math.radians(4), 4, "Y"))
    # The throat sac bulging under the jaw.
    ellipsoid(marks, (0.95, 0, 0.35), (0.55, 0.8, 0.35), 1)
    # Squat legs: big folded hoppers behind, small hands forward.
    for s in (-1, 1):
        ellipsoid(body, (-0.9, s * 0.95, 0.55), (0.55, 0.35, 0.45), 1)
        chain(body, [(-0.6, s * 1.15, 0.25), (-0.1, s * 1.25, 0.1)], [0.14, 0.08], 4)
        chain(body, [(0.5, s * 0.75, 0.4), (0.8, s * 0.85, 0.05)], [0.11, 0.06], 4)
    # Warts across the back.
    for px, py, r in ((-0.5, 0.5, 0.14), (-0.9, -0.3, 0.12), (0.0, -0.55, 0.11), (-0.2, 0.2, 0.1)):
        ellipsoid(fins, (px, py, 1.35), (r, r, r * 0.7), 0)
    # Eyes on top, periscope-style.
    for s in (-1, 1):
        ellipsoid(body, (0.5, s * 0.55, 1.35), (0.28, 0.24, 0.24), 1)
        ellipsoid(eyes, (0.62, s * 0.55, 1.42), (0.14, 0.12, 0.13), 0)

    return [
        finish("CroakjawToad_Body", body, MATS["CroakjawToad_Body"]),
        finish("CroakjawToad_Fins", fins, MATS["CroakjawToad_Fins"]),
        finish("CroakjawToad_Eyes", eyes, MATS["CroakjawToad_Eyes"]),
        finish("CroakjawToad_Marks", marks, MATS["CroakjawToad_Marks"]),
    ]


# ---- Mire Leech (rusher): a fat segmented leech, its front end all sucker
# - a ring of rasping teeth around a gape. Flat, front +X.
def build_mireleech():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # Segmented body: fattest amidships, arched slightly.
    pts, radii = [], []
    for i in range(8):
        t = i / 7
        pts.append((1.4 - t * 3.6, 0.35 * math.sin(t * 4.0), 0.5 + 0.1 * math.sin(t * math.pi)))
        radii.append(0.28 + 0.34 * math.sin(math.pi * min(max(t, 0.12), 0.88)))
    chain(body, pts, radii, 7)
    # Segment rings proud of the hide.
    for i in (1, 3, 5):
        px, py, pz = pts[i]
        limb(fins, (px - 0.04, py, pz), (px + 0.04, py, pz), radii[i] + 0.05, radii[i] + 0.05, 7)
    # The sucker: a flaring ring of teeth around the gape.
    limb(body, (1.4, 0, 0.5), (1.75, 0, 0.52), 0.55, 0.62, 8)
    for k in range(7):
        a = (k / 7) * TAU
        by, bz = math.cos(a) * 0.45, math.sin(a) * 0.42
        cone(fins, (1.78, by, 0.52 + bz), (1.95, by * 0.55, 0.52 + bz * 0.55), 0.07, 4)
    # Slime sheen strips down the back.
    for i in (2, 4):
        px, py, pz = pts[i]
        ellipsoid(marks, (px, py, pz + radii[i] * 0.8), (0.35, 0.2, 0.07), 1)
    # Eye specks (it barely has any).
    for s in (-1, 1):
        ellipsoid(eyes, (1.15, s * 0.3, 1.0), (0.05, 0.05, 0.05), 0)

    return [
        finish("MireLeech_Body", body, MATS["MireLeech_Body"]),
        finish("MireLeech_Fins", fins, MATS["MireLeech_Fins"]),
        finish("MireLeech_Eyes", eyes, MATS["MireLeech_Eyes"]),
        finish("MireLeech_Marks", marks, MATS["MireLeech_Marks"]),
    ]


# ---- Snagtooth Gator (charger): a lean fen gator - low body, armoured
# scute rows, a jaw that doesn't close right. Flat, front +X. No shell:
# nothing like Gnashroot at a glance.
def build_snagtoothgator():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    revolve(body, [(-2.2, 0.0), (-1.2, 0.5), (0.0, 0.72), (1.2, 0.6), (2.0, 0.0)], sides=8, axis="x", center=(0, 0, 0.6), squash=0.68)
    # The snout: long, flat, the snaggle jaw hanging open.
    revolve(body, [(-0.2, 0.55), (0.9, 0.42), (1.8, 0.3), (2.2, 0.0)], sides=7, axis="x", center=(1.9, 0, 0.68), squash=0.6)
    box(body, (3.0, 0, 0.32), (1.7, 0.75, 0.2), Matrix.Rotation(math.radians(-8), 4, "Y"))
    # Snaggle teeth: uneven, jutting at bad angles (marks - pale).
    for i, (x, s, up, r) in enumerate(((2.6, 1, 1, 0.07), (3.1, -1, 1, 0.09), (3.6, 1, 1, 0.06), (2.9, 1, -1, 0.07), (3.5, -1, -1, 0.08), (4.0, -1, 1, 0.05))):
        z0 = 0.42 if up > 0 else 0.6
        cone(marks, (x, s * 0.28, z0), (x + 0.08, s * 0.32, z0 + up * 0.3), r, 4)
    # Scute rows down the back and tail.
    for i in range(5):
        x = 0.8 - i * 0.75
        for s in (-1, 0, 1):
            box(fins, (x, s * 0.4, 1.05 - abs(s) * 0.1), (0.35, 0.25, 0.3), Matrix.Rotation(math.radians(30), 4, "Y"))
    # The tail, swinging wide.
    chain(body, [(-2.1, 0, 0.55), (-3.2, 0.5, 0.5), (-4.1, 0.85, 0.4)], [0.42, 0.26, 0.08], 6)
    box(fins, (-3.2, 0.5, 0.85), (0.4, 0.2, 0.35), Matrix.Rotation(math.radians(35), 4, "Y"))
    # Stumpy swimmer's legs.
    for sy in (-1, 1):
        for x in (0.9, -1.0):
            chain(body, [(x, sy * 0.6, 0.4), (x + 0.1, sy * 1.0, 0.2), (x + 0.2, sy * 1.15, 0.0)], [0.16, 0.12, 0.05], 5)
    for s in (-1, 1):
        ellipsoid(body, (1.6, s * 0.42, 0.98), (0.22, 0.18, 0.18), 1)
        ellipsoid(eyes, (1.7, s * 0.42, 1.05), (0.11, 0.1, 0.1), 0)

    return [
        finish("SnagtoothGator_Body", body, MATS["SnagtoothGator_Body"]),
        finish("SnagtoothGator_Fins", fins, MATS["SnagtoothGator_Fins"]),
        finish("SnagtoothGator_Eyes", eyes, MATS["SnagtoothGator_Eyes"]),
        finish("SnagtoothGator_Marks", marks, MATS["SnagtoothGator_Marks"]),
    ]


# ---- Sunken Trapper (mimic): a waterlogged supply barrel gone carnivorous,
# moss-lured. MIMIC LID CONTRACT: the lid is the whole _Fins object, the
# barrel is centred on x=0. UPRIGHT (stance).
def build_sunkentrapper():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # The barrel: staves and hoops, centred on x=0.
    revolve(body, [(0.0, 0.85), (0.5, 1.0), (1.0, 1.05), (1.5, 0.98)], sides=10, axis="z", center=(0, 0, 0), squash=1.0, open_end=True)
    for z in (0.3, 1.2):
        limb(body, (0, 0, z - 0.05), (0, 0, z + 0.05), 1.06, 1.06, 10)
    # The lid: a chewed plank disc with fangs down over the rim.
    limb(fins, (0, 0, 1.5), (0, 0, 1.72), 1.05, 1.0, 10)
    box(fins, (0, 0, 1.78), (1.5, 0.4, 0.14))
    for a in (-0.9, -0.3, 0.3, 0.9):
        px, py = math.cos(a * 0.8) * 0.88, math.sin(a) * 0.7
        cone(fins, (px, py, 1.52), (px + 0.05, py, 1.14), 0.09, 4)
    # Moss lure: glowing tufts on the lid's rim and a dangling bait-light.
    for a in (0.6, 2.4, 4.2):
        ellipsoid(marks, (math.cos(a) * 0.95, math.sin(a) * 0.95, 1.62), (0.2, 0.18, 0.12), 1)
    chain(body, [(0.95, 0, 1.6), (1.35, 0, 1.3)], [0.05, 0.03], 4)
    ellipsoid(marks, (1.42, 0, 1.15), (0.14, 0.14, 0.16), 1)
    # Eyes glinting between the staves.
    for s in (-1, 1):
        ellipsoid(eyes, (0.95, s * 0.4, 0.85), (0.09, 0.08, 0.09), 1)

    return [
        finish("SunkenTrapper_Body", body, MATS["SunkenTrapper_Body"]),
        finish("SunkenTrapper_Fins", fins, MATS["SunkenTrapper_Fins"]),
        finish("SunkenTrapper_Eyes", eyes, MATS["SunkenTrapper_Eyes"]),
        finish("SunkenTrapper_Marks", marks, MATS["SunkenTrapper_Marks"]),
    ]


# ---- Fen Serpent (spitter): a hooded swamp serpent, venom dripping bright.
# Flat, front +X; the hood is its silhouette.
def build_fenserpent():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    pts, radii = [], []
    n = 11
    for i in range(n):
        t = i / (n - 1)
        pts.append((2.0 - t * 5.4, 1.0 * math.sin(t * math.pi * 1.5 + 0.4), 0.55))
        radii.append(0.16 + 0.36 * math.sin(math.pi * min(max(t, 0.08), 0.92)))
    chain(body, pts, radii, 6)
    # The raised fore-body and head.
    chain(body, [(2.0, pts[0][1], 0.55), (2.5, 0.1, 1.1), (2.8, 0, 1.7)], [0.32, 0.28, 0.24], 6)
    ellipsoid(body, (3.0, 0, 1.85), (0.5, 0.32, 0.3), 1)
    box(body, (3.3, 0, 1.6), (0.55, 0.4, 0.14), Matrix.Rotation(math.radians(12), 4, "Y"))
    # The hood: two swept plates flanking the raised neck.
    for s in (-1, 1):
        plate(fins, [(2.4, 1.0), (2.2, 2.1), (2.9, 2.15), (3.1, 1.5)], 0.12, "xz", offset=(0, s * 0.4, 0))
    # Fangs and the venom drip glowing under the jaw.
    for s in (-1, 1):
        cone(marks, (3.4, s * 0.15, 1.6), (3.45, s * 0.17, 1.35), 0.05, 4)
    ellipsoid(marks, (3.42, 0, 1.2), (0.09, 0.09, 0.12), 1)
    # Venom stripes chasing down the spine.
    stripe = [(pts[i][0], pts[i][1], 0.55 + radii[i] * 0.85) for i in range(0, n, 2)]
    chain(marks, stripe, [0.05] * len(stripe), 4)
    for s in (-1, 1):
        ellipsoid(eyes, (3.15, s * 0.22, 2.0), (0.1, 0.08, 0.09), 0)

    return [
        finish("FenSerpent_Body", body, MATS["FenSerpent_Body"]),
        finish("FenSerpent_Fins", fins, MATS["FenSerpent_Fins"]),
        finish("FenSerpent_Eyes", eyes, MATS["FenSerpent_Eyes"]),
        finish("FenSerpent_Marks", marks, MATS["FenSerpent_Marks"]),
    ]


# ---- Peat Revenant (shambler): a BOG MUMMY stitched together with roots. The
# torso is built as two side slabs and a spine slab with nothing between them,
# so the chest is a TORN-OPEN CAVITY with the wisp burning inside it (marks) -
# the hole is real geometry, not a decal. Root bands wrap every limb, strands
# drip off the arms, and it drags a snapped-off ROOT-CLUB edged with a scythe
# row of gator teeth. UPRIGHT, ~4.4 tall as before.
def _pr_band(bm, p0, p1, t, r, w=0.16, sides=5):
    """A root wrapping cinched round a limb: a short fat collar at parameter
    `t` along the segment. At this poly count a raised collar reads as binding
    where a painted stripe would read as nothing."""
    p0, p1 = Vector(p0), Vector(p1)
    d = (p1 - p0).normalized()
    c = p0.lerp(p1, t)
    limb(bm, c - d * w * 0.5, c + d * w * 0.5, r, r, sides)


def _pr_strands(bm, anchor, count, drop, spread=0.22, r=0.06):
    """Torn root strands dripping off a limb: thin tapered cones hanging down,
    fanned along +/-Y. The ragged fringe is what separates this silhouette
    from a plain zombie arm."""
    anchor = Vector(anchor)
    for k in range(count):
        off = Vector(((k % 2) * 0.12 - 0.06, (k - (count - 1) * 0.5) * spread, 0.0))
        cone(bm, anchor + off, anchor + off + Vector((0.08, 0.04, -drop * (0.6 + 0.4 * ((k + 1) % 3)))), r, 3)


def build_peatrevenant():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # Legs: root-bound columns, knees splayed, slab feet sunk in the peat.
    for s in (-1, 1):
        hip, knee, ankle = (0.0, s * 0.48, 1.8), (0.14, s * 0.56, 1.0), (0.04, s * 0.52, 0.24)
        limb(body, hip, knee, 0.34, 0.27, 5)
        limb(body, knee, ankle, 0.27, 0.22, 5)
        box(body, (0.18, s * 0.52, 0.11), (0.72, 0.56, 0.22))
        _pr_band(body, hip, knee, 0.55, 0.34)

    # TORSO WITH A TORN CAVITY: two rib slabs and a spine slab, and the gap
    # between them left EMPTY from the belly to the collar. That hole is the
    # whole silhouette idea - front-on you see straight through it to the wisp.
    for s in (-1, 1):
        box(body, (0.06, s * 0.6, 2.66), (0.95, 0.52, 1.72), Matrix.Rotation(math.radians(-8), 4, "Y"))
    box(body, (-0.44, 0, 2.72), (0.5, 1.5, 1.9), Matrix.Rotation(math.radians(-8), 4, "Y"))
    box(body, (0.12, 0, 1.94), (1.0, 1.35, 0.58))
    box(body, (-0.06, 0, 3.5), (0.82, 1.6, 0.48), Matrix.Rotation(math.radians(-10), 4, "Y"))

    # Head half-sunk into the shoulders, long jaw hanging open.
    head_c = Vector((0.3, 0.06, 3.94))
    ellipsoid(body, head_c, (0.5, 0.46, 0.5), 0)
    box(body, (0.6, 0.06, 3.74), (0.42, 0.42, 0.22), Matrix.Rotation(0.24, 4, "Y"))

    # ARMS: the right (-y) hauls the club up and forward, the left (+y) hangs
    # long past the knee. Both wrapped in root bands.
    r_hand = Vector((1.34, -0.86, 2.66))
    for pts, hand in (
        ([(0.1, -0.92, 3.3), (0.78, -1.06, 2.94), r_hand], r_hand),
        ([(0.1, 0.92, 3.3), (0.86, 1.2, 2.5), (1.12, 1.1, 1.72)], Vector((1.12, 1.1, 1.72))),
    ):
        a, b, c = (Vector(p) for p in pts)
        limb(body, a, b, 0.3, 0.24, 5)
        limb(body, b, c, 0.24, 0.17, 5)
        _pr_band(body, a, b, 0.5, 0.3)
        _pr_band(body, b, c, 0.55, 0.24)
        box(body, hand + Vector((0.06, 0, -0.04)), (0.32, 0.3, 0.28))

    # Twig fingers on the free hand, strands dripping off both forearms.
    l_hand = Vector((1.12, 1.1, 1.72))
    for k in range(3):
        cone(fins, l_hand, l_hand + Vector((0.24, (k - 1) * 0.16, -0.42 - abs(k - 1) * 0.1)), 0.05, 3)
    _pr_strands(fins, (0.92, 1.16, 2.32), 4, 0.7)
    _pr_strands(fins, (0.82, -1.02, 2.84), 4, 0.62)
    _pr_strands(fins, (-0.1, 0, 1.72), 3, 0.55, spread=0.5, r=0.09)

    # Root ribs framing the cavity mouth, and branches out of the back.
    for s in (-1, 1):
        for i in range(2):
            _pr_band(fins, (0.5, s * 0.34, 2.2 + i * 0.62), (0.5, s * 0.62, 2.3 + i * 0.62), 0.5, 0.12, 0.5, 4)
    chain(fins, [(-0.42, 0.5, 3.6), (-0.74, 0.82, 4.3), (-0.54, 0.7, 4.76)], [0.12, 0.08, 0.03], 4)
    chain(fins, [(-0.5, -0.42, 3.4), (-0.92, -0.8, 4.02)], [0.1, 0.04], 4)

    # THE ROOT-CLUB: a snapped slab of root held forward and up, its outer edge
    # armed with a scythe row of gator teeth. The teeth stand proud of the
    # outline so the weapon reads as a saw, not a stick, in monochrome.
    limb(fins, r_hand, (1.6, -0.78, 2.82), 0.16, 0.19, 5)
    plate(
        fins,
        [(1.5, 2.6), (1.94, 2.6), (2.46, 3.24), (2.56, 3.8), (2.2, 3.76), (1.72, 3.02)],
        0.34,
        plane="xz",
        offset=(0, -0.74, 0),
    )
    ellipsoid(fins, (2.5, -0.74, 3.84), (0.2, 0.18, 0.18), 0)
    for i in range(6):
        t = i / 5.0
        base = Vector((1.9 + t * 0.62, -0.74, 2.58 + t * 1.18))
        cone(fins, base, base + Vector((0.28 - t * 0.08, 0.0, -0.2 + t * 0.28)), 0.09, 3)

    # WISP-LIGHT: the flame standing in the open chest, tongues licking up out
    # of the cavity, and motes drifting off it.
    ellipsoid(marks, (0.06, 0.0, 2.7), (0.26, 0.34, 0.52), 0)
    for k in range(3):
        base = Vector((0.06, (k - 1) * 0.3, 3.1))
        cone(marks, base, base + Vector((0.1, (k - 1) * 0.12, 0.5 + (k % 2) * 0.24)), 0.13, 4)
    for k in range(3):
        ellipsoid(marks, (0.3 + (k % 2) * 0.2, (k - 1) * 0.34, 3.7 + k * 0.28), (0.08, 0.08, 0.08), 0)

    for s in (-1, 1):
        ellipsoid(eyes, head_c + Vector((0.36, s * 0.2, 0.06)), (0.1, 0.09, 0.12), 0)

    return [
        finish("PeatRevenant_Body", body, MATS["PeatRevenant_Body"]),
        finish("PeatRevenant_Fins", fins, MATS["PeatRevenant_Fins"]),
        finish("PeatRevenant_Eyes", eyes, MATS["PeatRevenant_Eyes"]),
        finish("PeatRevenant_Marks", marks, MATS["PeatRevenant_Marks"]),
    ]


# ---------------------------------------------------------------- Maelstrom hostiles
# The finale's roster: everything crackles.


# ---- Galestreak Flyingfish (flyer): a flying fish riding the storm - huge
# wing-fins swept back, streak lines trailing. Flat, front +X.
def build_galestreakflyingfish():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    revolve(body, [(-1.9, 0.0), (-1.0, 0.32), (0.2, 0.45), (1.3, 0.32), (1.8, 0.0)], sides=8, axis="x", center=(0, 0, 0.9), squash=1.1)
    # The wing-fins: oversized pectorals swept back like a glider.
    for s in (-1, 1):
        plate(fins, [(1.0, s * 0.35), (0.2, s * 1.6), (-1.4, s * 2.0), (-0.7, s * 0.7), (0.2, s * 0.35)], 0.08, "xy", offset=(0, 0, 1.0))
    # Smaller pelvic winglets and the deep tail (lower lobe long - a flying
    # fish's rudder).
    for s in (-1, 1):
        plate(fins, [(-0.9, s * 0.25), (-1.4, s * 0.85), (-1.7, s * 0.3)], 0.06, "xy", offset=(0, 0, 0.65))
    plate(fins, [(-1.8, 1.15), (-2.5, 1.4), (-2.3, 0.9), (-2.7, 0.2), (-1.85, 0.65)], 0.08, "xz")
    # Gale streaks: glowing speed-lines off both wingtips.
    for s in (-1, 1):
        chain(marks, [(-1.3, s * 1.9, 1.0), (-2.3, s * 2.0, 1.05)], [0.04, 0.02], 4)
    for s in (-1, 1):
        ellipsoid(eyes, (1.35, s * 0.24, 1.05), (0.12, 0.1, 0.12), 0)

    return [
        finish("GalestreakFlyingfish_Body", body, MATS["GalestreakFlyingfish_Body"]),
        finish("GalestreakFlyingfish_Fins", fins, MATS["GalestreakFlyingfish_Fins"]),
        finish("GalestreakFlyingfish_Eyes", eyes, MATS["GalestreakFlyingfish_Eyes"]),
        finish("GalestreakFlyingfish_Marks", marks, MATS["GalestreakFlyingfish_Marks"]),
    ]


# ---- Riptide Barracuda (charger): an arrow of a fish - long, lean, jagged
# dark stripes down the flank. Flat, front +X.
def build_riptidebarracuda():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    revolve(body, [(-2.6, 0.0), (-1.6, 0.28), (0.0, 0.4), (1.6, 0.36), (2.6, 0.16), (2.9, 0.0)], sides=8, axis="x", center=(0, 0, 0.62), squash=1.2)
    # Underslung fanged jaw.
    box(body, (2.6, 0, 0.45), (0.8, 0.24, 0.13), Matrix.Rotation(math.radians(8), 4, "Y"))
    for s in (-1, 1):
        cone(fins, (2.5, s * 0.08, 0.52), (2.52, s * 0.08, 0.68), 0.03, 4)
        cone(fins, (2.75, s * 0.08, 0.66), (2.77, s * 0.08, 0.5), 0.03, 4)
    # Fins: twin dorsals set far apart (the barracuda tell), forked tail.
    plate(fins, [(0.9, 1.0), (0.5, 1.5), (0.3, 1.0)], 0.08, "xz")
    plate(fins, [(-1.5, 1.0), (-1.9, 1.5), (-2.1, 1.0)], 0.08, "xz")
    plate(fins, [(-2.8, 0.85), (-3.6, 1.25), (-3.3, 0.62), (-3.6, 0.0), (-2.8, 0.4)], 0.1, "xz")
    for s in (-1, 1):
        plate(fins, [(1.5, s * 0.35), (0.9, s * 0.85), (0.7, s * 0.4)], 0.06, "xy", offset=(0, 0, 0.4))
    # The jagged stripes.
    for s in (-1, 1):
        for i in range(4):
            x = 1.6 - i * 1.0
            box(marks, (x, s * 0.38, 0.75), (0.12, 0.05, 0.4), Matrix.Rotation(math.radians(20), 4, "Y"))
    for s in (-1, 1):
        ellipsoid(eyes, (2.15, s * 0.26, 0.78), (0.11, 0.09, 0.11), 0)

    return [
        finish("RiptideBarracuda_Body", body, MATS["RiptideBarracuda_Body"]),
        finish("RiptideBarracuda_Fins", fins, MATS["RiptideBarracuda_Fins"]),
        finish("RiptideBarracuda_Eyes", eyes, MATS["RiptideBarracuda_Eyes"]),
        finish("RiptideBarracuda_Marks", marks, MATS["RiptideBarracuda_Marks"]),
    ]


# ---- Cyclone Ray (pulser): a storm ray - the spiral etched on its disc
# glows when it charges its pulse. Flat, front +X.
def build_cycloneray():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    ellipsoid(body, (0, 0, 0.5), (1.4, 1.05, 0.3), 1)
    for s in (-1, 1):
        plate(fins, [(0.7, s * 0.65), (-0.2, s * 1.9), (-1.5, s * 1.85), (-0.8, s * 0.85), (-0.5, s * 0.55)], 0.13, "xy", offset=(0, 0, 0.5))
        cone(body, (1.25, s * 0.3, 0.5), (1.7, s * 0.42, 0.46), 0.09, 4)
    chain(body, [(-1.3, 0, 0.5), (-2.2, 0.1, 0.55), (-2.8, 0.0, 0.5)], [0.11, 0.06, 0.02], 4)
    # THE SPIRAL: a glowing whorl wound over the disc's back.
    spiral = []
    for k in range(9):
        t = k / 8
        a = t * TAU * 1.4
        r = 0.15 + t * 0.85
        spiral.append((math.cos(a) * r * 1.2 - 0.1, math.sin(a) * r * 0.85, 0.78))
    chain(marks, spiral, [0.06] * len(spiral), 4)
    for s in (-1, 1):
        ellipsoid(eyes, (1.05, s * 0.38, 0.72), (0.1, 0.08, 0.08), 0)

    return [
        finish("CycloneRay_Body", body, MATS["CycloneRay_Body"]),
        finish("CycloneRay_Fins", fins, MATS["CycloneRay_Fins"]),
        finish("CycloneRay_Eyes", eyes, MATS["CycloneRay_Eyes"]),
        finish("CycloneRay_Marks", marks, MATS["CycloneRay_Marks"]),
    ]


_WHIRL_PROFILE = [(-2.2, 0.05), (-1.3, 0.45), (-0.3, 0.8), (0.7, 1.05), (1.3, 1.1)]


def _whirl_radius(x):
    """The shell's radius at `x`, so its spiral ridge can ride ON the shell
    rather than disappearing inside it."""
    if x <= _WHIRL_PROFILE[0][0]:
        return _WHIRL_PROFILE[0][1]
    for (x0, r0), (x1, r1) in zip(_WHIRL_PROFILE, _WHIRL_PROFILE[1:]):
        if x <= x1:
            return r0 + (r1 - r0) * (x - x0) / (x1 - x0)
    return _WHIRL_PROFILE[-1][1]


# ---- Whirlpool Horror (burrower): a spiral-shelled thing that IS its own
# whirlpool - a ridged cone lying mouth-forward, tentacle fringe reaching
# out of the throat. Flat, front +X.
def build_whirlpoolhorror():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # The shell: a ridged cone, tip aft, mouth flaring forward.
    revolve(body, _WHIRL_PROFILE, sides=9, axis="x", center=(0, 0, 1.1), squash=0.95, open_end=True)
    # Spiral ridge riding ON the shell - the old one was cut to a straight
    # taper and spent its middle third buried inside the body, invisible.
    ridge = []
    for k in range(14):
        t = k / 13
        a = t * TAU * 1.7
        x = -2.05 + t * 3.3
        r = _whirl_radius(x) + 0.06
        ridge.append((x, math.cos(a) * r, 1.1 + math.sin(a) * r * 0.95))
    chain(fins, ridge, [0.11] * len(ridge), 4)
    # Hooked teeth ringing the maw: the thing you see as it swallows you.
    for k in range(9):
        a = (k / 9) * TAU + 0.2
        by, bz = math.cos(a) * 1.06, math.sin(a) * 1.06 * 0.95
        cone(fins, (1.28, by, 1.1 + bz), (1.78, by * 0.70, 1.1 + bz * 0.70), 0.10, 4)
    # The tentacle fringe reaching out of the mouth.
    for k in range(6):
        a = (k / 6) * TAU + 0.3
        by, bz = math.cos(a) * 0.7, math.sin(a) * 0.65
        chain(fins, [(1.2, by, 1.1 + bz), (1.9, by * 1.3, 1.1 + bz * 1.3), (2.5, by * 1.0, 1.1 + bz * 0.9)], [0.11, 0.07, 0.02], 4)
    # The glow spiralling down the throat, and one hateful eye in the dark.
    for k in range(3):
        limb(marks, (0.9 - k * 0.5, 0, 1.1), (0.95 - k * 0.5, 0, 1.1), 0.85 - k * 0.25, 0.85 - k * 0.25, 8)
    ellipsoid(eyes, (0.1, 0, 1.1), (0.22, 0.2, 0.2), 1)

    return [
        finish("WhirlpoolHorror_Body", body, MATS["WhirlpoolHorror_Body"]),
        finish("WhirlpoolHorror_Fins", fins, MATS["WhirlpoolHorror_Fins"]),
        finish("WhirlpoolHorror_Eyes", eyes, MATS["WhirlpoolHorror_Eyes"]),
        finish("WhirlpoolHorror_Marks", marks, MATS["WhirlpoolHorror_Marks"]),
    ]


# ---- Tempest Revenant (shambler): the drowned sailor the storm took back -
# lightning-scarred, wrapped in torn sailcloth, HAULING a barnacled anchor on
# a chain. He leans into the drag and the anchor lies low and aft: the whole
# read is that diagonal. UPRIGHT (stance).


def _dragged_anchor(fins, crown, ring_end):
    """A ship's anchor lying where it was dragged to: shank, stock, two
    flukes with spade palms, and a shackle ring at the top. `crown` is the
    bottom of the shank, `ring_end` the top."""
    crown, ring_end = Vector(crown), Vector(ring_end)
    axis = (ring_end - crown).normalized()
    limb(fins, crown, ring_end, 0.19, 0.12, 5)
    # Stock: the crossbar just under the ring.
    stock = crown + (ring_end - crown) * 0.84
    limb(fins, stock + Vector((0, -0.80, 0.07)), stock + Vector((0, 0.80, -0.07)), 0.08, 0.08, 5)
    # Shackle ring at the head, drawn as a hexagon of links.
    centre = ring_end + axis * 0.28
    ring_pts = [centre + Vector((math.cos(a) * 0.22, 0, math.sin(a) * 0.22)) for a in (i / 6 * TAU for i in range(6))]
    chain(fins, ring_pts + [ring_pts[0]], [0.055] * 7, 4)
    # Flukes sweeping up off the crown, each ending in a spade palm.
    for s in (-1, 1):
        tip = crown + Vector((0.34, s * 1.06, 1.00))
        chain(fins, [crown, crown + Vector((0.22, s * 0.60, 0.42)), tip], [0.15, 0.11, 0.08], 5)
        plate(
            fins,
            [(tip.x - 0.26, tip.z - 0.52), (tip.x + 0.38, tip.z + 0.20), (tip.x - 0.28, tip.z + 0.26)],
            0.28,  # chunky: a thin palm disappears edge-on, and head-on is how the player meets him
            "xz",
            offset=(0, tip.y, 0),
        )
    # Barnacles crusting the shank (fins, not marks - marks glow on this one).
    for t, sy, sz in ((0.22, 0.16, 0.14), (0.38, -0.15, 0.16), (0.55, 0.14, -0.15), (0.70, -0.13, 0.13)):
        p = crown + (ring_end - crown) * t
        ellipsoid(fins, p + Vector((0.02, sy, sz)), (0.11, 0.11, 0.10), 0)


def build_tempestrevenant():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    lean = Matrix.Rotation(math.radians(17), 4, "Y")  # leaning into the haul

    # Braced legs: lead leg planted forward, trail leg driving back against
    # the weight.
    chain(body, [(0.05, 0.42, 1.75), (0.60, 0.46, 1.04), (0.86, 0.46, 0.28)], [0.29, 0.24, 0.19], 5)
    box(body, (0.98, 0.46, 0.13), (0.66, 0.46, 0.26))
    chain(body, [(-0.05, -0.42, 1.75), (-0.52, -0.46, 1.06), (-0.90, -0.44, 0.30)], [0.29, 0.24, 0.19], 5)
    box(body, (-0.96, -0.44, 0.13), (0.66, 0.46, 0.26))

    box(body, (0.12, 0, 2.55), (0.86, 1.16, 1.80), lean)
    head_c = Vector((0.55, 0, 3.85))
    limb(body, (0.30, 0, 3.30), head_c, 0.20, 0.26, 6)
    ellipsoid(body, head_c, (0.40, 0.38, 0.42), 1)
    box(body, (0.80, 0, 3.72), (0.26, 0.46, 0.30))

    # Free arm reaching forward; hauling arm dragged back and down, the chain
    # running off its fist.
    chain(body, [(0.22, 0.68, 3.22), (0.86, 0.78, 2.86), (1.48, 0.62, 2.62)], [0.23, 0.19, 0.15], 5)
    ellipsoid(body, (1.50, 0.62, 2.60), (0.19, 0.17, 0.19), 1)
    haul = Vector((-0.50, -0.78, 2.28))
    chain(body, [(0.20, -0.68, 3.22), (-0.22, -0.82, 2.74), haul], [0.23, 0.19, 0.15], 5)
    ellipsoid(body, haul, (0.18, 0.17, 0.18), 1)

    # TORN SAILCLOTH: a shroud hanging off each shoulder with a ragged hem,
    # and a strip of it streaming off his back.
    # A long shroud down his port side, a shorter torn one to starboard, and
    # a strip of sail streaming off his back. All hems cut ragged.
    plate(
        fins,
        [(-0.58, 3.34), (0.48, 3.26), (0.42, 2.20), (0.26, 2.50), (0.06, 1.70), (-0.16, 2.14), (-0.38, 1.50), (-0.60, 2.10)],
        0.14,
        "xz",
        offset=(0, 0.80, 0),
    )
    plate(
        fins,
        [(-0.54, 3.30), (0.44, 3.22), (0.36, 2.46), (0.18, 2.70), (-0.02, 2.10), (-0.24, 2.56), (-0.52, 2.30)],
        0.13,
        "xz",
        offset=(0, -0.78, 0),
    )
    plate(fins, [(-0.44, 3.18), (-1.42, 2.94), (-1.10, 2.44), (-1.72, 2.16), (-1.06, 1.86), (-0.38, 2.22)], 0.12, "xz", offset=(0, 0.12, 0))
    box(fins, (0.08, 0, 2.34), (0.88, 1.24, 1.05), lean)  # the wrap round his chest

    # THE ANCHOR, low and out to starboard so the drag stays in silhouette
    # from the front too, with the chain sagging up to his fist.
    # Tipped up on its flukes as it drags: shank near-upright, stock crossing
    # near the top - the shape everyone knows.
    _dragged_anchor(fins, (-2.18, -1.10, 0.22), (-1.72, -1.00, 1.72))
    link_pts = [haul, (-0.94, -0.88, 2.02), (-1.38, -0.96, 1.94), (-1.66, -1.02, 1.96)]
    chain(fins, link_pts, [0.06, 0.06, 0.06, 0.06], 4)
    for p in link_pts[1:-1]:
        ellipsoid(fins, p, (0.11, 0.11, 0.09), 0)

    # Lightning scars: the strike that took him, forking down the chest and
    # out along the hauling arm.
    chain(marks, [(0.66, 0.10, 3.34), (0.72, -0.22, 2.86), (0.66, 0.14, 2.44), (0.70, -0.16, 1.98)], [0.05, 0.06, 0.06, 0.04], 4)
    chain(marks, [(0.68, -0.22, 2.86), (0.58, -0.62, 2.62), (0.50, -0.86, 2.34)], [0.05, 0.05, 0.03], 4)
    chain(marks, [(0.66, 0.14, 2.44), (0.52, 0.58, 2.24), (0.44, 0.80, 1.92)], [0.05, 0.05, 0.03], 4)
    for s in (-1, 1):
        ellipsoid(eyes, (0.86, s * 0.17, 3.92), (0.09, 0.09, 0.11), 0)

    return [
        finish("TempestRevenant_Body", body, MATS["TempestRevenant_Body"]),
        finish("TempestRevenant_Fins", fins, MATS["TempestRevenant_Fins"]),
        finish("TempestRevenant_Eyes", eyes, MATS["TempestRevenant_Eyes"]),
        finish("TempestRevenant_Marks", marks, MATS["TempestRevenant_Marks"]),
    ]


# ---- Thunderlance Marlin (charger): the lance made flesh - a marlin whose
# bill is half its length, lightning down the flanks, a storm-sail dorsal.
# Flat, front +X.
def build_thunderlancemarlin():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    revolve(body, [(-2.4, 0.0), (-1.4, 0.4), (0.0, 0.55), (1.2, 0.42), (1.9, 0.2), (2.2, 0.1)], sides=8, axis="x", center=(0, 0, 0.85), squash=1.25)
    # THE BILL: a tapered lance as long as the forebody.
    cone(body, (2.2, 0, 0.9), (4.4, 0, 0.95), 0.11, 6)
    # The storm-sail: a crackling dorsal, kept under the beam rule.
    plate(fins, [(1.0, 1.3), (0.6, 2.15), (0.0, 1.85), (-0.6, 2.1), (-1.2, 1.7), (-1.6, 1.25)], 0.12, "xz")
    plate(fins, [(-2.6, 1.3), (-3.5, 1.8), (-3.2, 0.85), (-3.5, 0.05), (-2.6, 0.45)], 0.12, "xz")
    for s in (-1, 1):
        plate(fins, [(1.2, s * 0.4), (0.3, s * 1.35), (0.1, s * 0.45)], 0.08, "xy", offset=(0, 0, 0.55))
    # Lightning veins down both flanks and up the sail.
    for s in (-1, 1):
        chain(marks, [(1.6, s * 0.35, 0.95), (0.6, s * 0.5, 1.15), (-0.6, s * 0.5, 0.9), (-1.8, s * 0.35, 1.05)], [0.05, 0.06, 0.06, 0.04], 4)
    chain(marks, [(0.6, 0, 2.0), (0.1, 0, 1.7), (-0.5, 0, 1.95)], [0.05, 0.05, 0.04], 4)
    for s in (-1, 1):
        ellipsoid(eyes, (1.7, s * 0.28, 1.05), (0.12, 0.1, 0.12), 0)

    return [
        finish("ThunderlanceMarlin_Body", body, MATS["ThunderlanceMarlin_Body"]),
        finish("ThunderlanceMarlin_Fins", fins, MATS["ThunderlanceMarlin_Fins"]),
        finish("ThunderlanceMarlin_Eyes", eyes, MATS["ThunderlanceMarlin_Eyes"]),
        finish("ThunderlanceMarlin_Marks", marks, MATS["ThunderlanceMarlin_Marks"]),
    ]


# ---- Stormcaller Djinn (gascloud): a storm that has taken a grudge. NO
# MUNDANE ANATOMY BELOW THE RIBS - the torso is cloud-wrack that narrows into
# a churning funnel where legs should be - and it brandishes a forked
# lightning-rod two-handed, with the storm lit in its chest. UPRIGHT (stance).

# The rod's axis: butt low on the port side, fork high to starboard, so the
# brandish crosses the body and reads from the front as well as in profile.
_ROD_BUTT = Vector((-0.85, 0.85, 2.95))
_ROD_TIP = Vector((2.05, -0.45, 4.70))


def _rod_at(t):
    return _ROD_BUTT + (_ROD_TIP - _ROD_BUTT) * t


def build_stormcallerdjinn():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    # The funnel: it stands on a spun point of cloud, not on legs.
    revolve(body, [(-0.05, 0.08), (0.60, 0.42), (1.35, 0.58), (2.10, 0.50)], sides=9, axis="z", center=(0, 0, 0.15), squash=1.0, open_end=True)
    # Wrack winding up around the funnel, and torn cloud orbiting the churn.
    for k in range(4):
        a0 = (k / 4) * TAU
        pts = []
        for j in range(5):
            t = j / 4
            a = a0 + t * 3.4
            r = 0.88 - 0.34 * t
            pts.append((math.cos(a) * r, math.sin(a) * r, 0.30 + t * 1.85))
        chain(body, pts, [0.24, 0.20, 0.16, 0.12, 0.07], 5)
    for k in range(5):
        a = (k / 5) * TAU + 0.4
        rr = 1.02 - 0.10 * (k % 3)
        ellipsoid(body, (math.cos(a) * rr, math.sin(a) * rr, 0.70 + 0.42 * (k % 3)), (0.30, 0.26, 0.20), 0)
    # Cloud-wrack torso: a pinched waist opening into thunderhead shoulders -
    # top-heavy, so it looms.
    revolve(body, [(0.0, 0.48), (0.70, 0.95), (1.45, 1.22), (2.05, 0.72)], sides=9, axis="z", center=(0, 0, 2.20), squash=1.10, open_end=True)
    # Rib-banks: bands of cloud curving round the chest, not stacked planks.
    for cz, w, bulge in ((3.94, 0.86, 1.08), (3.48, 0.98, 1.20), (3.02, 0.78, 1.00)):
        chain(
            fins,
            [(0.30, -w, cz - 0.12), (bulge, -w * 0.45, cz), (bulge + 0.06, 0, cz + 0.04), (bulge, w * 0.45, cz), (0.30, w, cz - 0.12)],
            [0.07, 0.14, 0.16, 0.14, 0.07],
            5,
        )
    # Thunderhead tufts riding the shoulders.
    for s in (-1, 1):
        ellipsoid(fins, (-0.18, s * 1.02, 4.10), (0.50, 0.44, 0.38), 0)

    # The head, and a crown of cloud horns swept back off it.
    ellipsoid(body, (0.15, 0, 4.85), (0.45, 0.42, 0.50), 1)
    limb(body, (0.05, 0, 4.20), (0.15, 0, 4.70), 0.26, 0.30, 6)
    for s in (-1, 1):
        cone(fins, (0.02, s * 0.24, 5.10), (-0.32, s * 0.46, 5.62), 0.13, 4)
        cone(fins, (0.06, s * 0.44, 5.00), (-0.20, s * 0.80, 5.38), 0.10, 4)

    # BOTH HANDS ON THE ROD: lower fist by the ribs, upper fist raised and
    # across - the brandish.
    hand_lo, hand_hi = _rod_at(0.40), _rod_at(0.66)
    chain(body, [(0.08, 0.92, 4.00), (0.34, 0.86, 3.76), hand_lo], [0.24, 0.19, 0.14], 5)
    chain(body, [(0.08, -0.92, 4.00), (0.74, -0.86, 4.34), hand_hi], [0.24, 0.19, 0.14], 5)
    for h in (hand_lo, hand_hi):
        ellipsoid(body, h, (0.17, 0.17, 0.17), 1)

    # THE LIGHTNING-ROD (shaft -> fins, live tips -> marks): a haft that ends
    # in a three-pronged fork with an arc jumping between the outer prongs.
    d = (_ROD_TIP - _ROD_BUTT).normalized()
    side = d.cross(Vector((0, 0, 1))).normalized()
    up = side.cross(d).normalized()
    limb(fins, _ROD_BUTT, _ROD_TIP, 0.095, 0.075, 5)
    ellipsoid(fins, _ROD_BUTT, (0.15, 0.15, 0.15), 1)
    for t in (0.30, 0.55):
        p = _rod_at(t)
        ellipsoid(fins, p, (0.13, 0.12, 0.13), 0)
    prongs = [
        _ROD_TIP + d * 0.55 + up * 0.45,
        _ROD_TIP + d * 0.78 + up * 0.02,
        _ROD_TIP + d * 0.55 - up * 0.45,
    ]
    for p in prongs:
        limb(fins, _ROD_TIP, p - (p - _ROD_TIP).normalized() * 0.24, 0.07, 0.05, 4)
        cone(marks, p - (p - _ROD_TIP).normalized() * 0.26, p, 0.07, 4)
    # The arc jumping the fork.
    chain(marks, [prongs[0], prongs[1] + up * 0.16 + side * 0.10, prongs[2]], [0.04, 0.05, 0.04], 4)

    # THE STORM IN ITS CHEST: a lit core standing proud of the wrack, with
    # cracks of light running out of it and down into the funnel.
    core = Vector((1.24, 0, 3.70))  # proud of the rib bands, not behind one
    ellipsoid(marks, core, (0.32, 0.30, 0.34), 1)
    for dy, dz in ((0.52, 0.42), (-0.52, 0.40), (0.30, -0.62), (-0.28, -0.64)):
        chain(marks, [core, core + Vector((-0.14, dy, dz)), core + Vector((-0.34, dy * 1.7, dz * 1.9))], [0.06, 0.05, 0.02], 4)
    chain(marks, [(0.70, 0.30, 2.90), (0.80, -0.10, 2.10), (0.62, 0.24, 1.20)], [0.05, 0.06, 0.03], 4)
    for s in (-1, 1):
        ellipsoid(eyes, (0.50, s * 0.20, 4.90), (0.11, 0.10, 0.13), 0)

    return [
        finish("StormcallerDjinn_Body", body, MATS["StormcallerDjinn_Body"]),
        finish("StormcallerDjinn_Fins", fins, MATS["StormcallerDjinn_Fins"]),
        finish("StormcallerDjinn_Eyes", eyes, MATS["StormcallerDjinn_Eyes"]),
        finish("StormcallerDjinn_Marks", marks, MATS["StormcallerDjinn_Marks"]),
    ]


# ---- Kraken Spawn (splitter): an urchin-ball of baby tentacles - a knot
# that comes apart when killed. UPRIGHT (a ball; stance keeps it as built).
def build_krakenspawn():
    body = bmesh.new()
    fins = bmesh.new()
    eyes = bmesh.new()
    marks = bmesh.new()

    ellipsoid(body, (0, 0, 1.0), (0.75, 0.72, 0.7), 1)
    # Baby tentacles curling off it in every direction.
    for k in range(9):
        a = (k / 9) * TAU
        lat = math.radians(-35 + (k % 3) * 38)
        d = Vector((math.cos(lat) * math.cos(a), math.cos(lat) * math.sin(a), math.sin(lat)))
        base = Vector((0, 0, 1.0)) + d * 0.65
        mid = Vector((0, 0, 1.0)) + d * 1.25 + Vector((0, 0, 0.25))
        tip = Vector((0, 0, 1.0)) + d * 1.55 + Vector((0, 0, 0.6))
        chain(fins, [base, mid, tip], [0.16, 0.1, 0.03], 4)
    # Sucker dots and one big baleful eye (its parent's).
    for k in range(5):
        a = (k / 5) * TAU + 0.5
        ellipsoid(marks, (math.cos(a) * 0.68, math.sin(a) * 0.66, 1.35), (0.08, 0.08, 0.08), 0)
    ellipsoid(eyes, (0.62, 0, 1.15), (0.26, 0.22, 0.24), 1)

    return [
        finish("KrakenSpawn_Body", body, MATS["KrakenSpawn_Body"]),
        finish("KrakenSpawn_Fins", fins, MATS["KrakenSpawn_Fins"]),
        finish("KrakenSpawn_Eyes", eyes, MATS["KrakenSpawn_Eyes"]),
        finish("KrakenSpawn_Marks", marks, MATS["KrakenSpawn_Marks"]),
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
    # Frostmaw Reach roster.
    ("FrostbitePup", build_frostbitepup, True),
    ("IceshardCrab", build_iceshardcrab, True),
    ("GlacialLurker", build_glaciallurker, True),
    ("IceveinPike", build_iceveinpike, True),
    ("FrozenMariner", build_frozenmariner, False),
    ("AuroraJelly", build_aurorajelly, False),
    ("BlizzardWraith", build_blizzardwraith, False),
    # Gloomtrench roster.
    ("GulperEel", build_gulpereel, True),
    ("FlashbulbSquid", build_flashbulbsquid, False),
    ("TrenchSkitterer", build_trenchskitterer, True),
    ("LanternjawAngler", build_lanternjawangler, False),
    ("VampireSquid", build_vampiresquid, True),
    ("PressureCrab", build_pressurecrab, True),
    ("VoidRay", build_voidray, True),
    ("SiltStalker", build_siltstalker, True),
    # Wreckwater roster.
    ("CannonballCrab", build_cannonballcrab, True),
    ("DrownedBoatswain", build_drownedboatswain, False),
    ("PhantomMoray", build_phantommoray, True),
    ("CursedChest", build_cursedchest, False),
    ("PlunderSprite", build_plundersprite, True),
    ("GhostfireJelly", build_ghostfirejelly, False),
    ("WailingGunner", build_wailinggunner, False),
    # Blackmire Fen roster.
    ("CroakjawToad", build_croakjawtoad, True),
    ("MireLeech", build_mireleech, True),
    ("SnagtoothGator", build_snagtoothgator, True),
    ("SunkenTrapper", build_sunkentrapper, False),
    ("FenSerpent", build_fenserpent, True),
    ("PeatRevenant", build_peatrevenant, False),
    # The Maelstrom roster.
    ("GalestreakFlyingfish", build_galestreakflyingfish, True),
    ("RiptideBarracuda", build_riptidebarracuda, True),
    ("CycloneRay", build_cycloneray, True),
    ("WhirlpoolHorror", build_whirlpoolhorror, True),
    ("TempestRevenant", build_tempestrevenant, False),
    ("ThunderlanceMarlin", build_thunderlancemarlin, True),
    ("StormcallerDjinn", build_stormcallerdjinn, False),
    ("KrakenSpawn", build_krakenspawn, False),
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
