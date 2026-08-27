# Studio import checklist — 7-island revamp

The one manual step the overnight build could not do for you: re-importing the
regenerated `.glb`s into Studio and re-exporting `assets/Assets.rbxm`. Until
this is done the game RUNS but shows fallbacks: new islands are "coming soon"
in the travel menu, ranged weapons and the boat use their procedural shapes,
new creatures use recolored stand-ins. Nothing errors — it is all the
established missing-mesh behavior.

Follow assets/README.md's import steps (glTF import, keep collision fidelity,
replace under ReplicatedStorage/Assets keeping the EXACT names, then
right-click Assets → Save to File… → assets/Assets.rbxm, restart rojo serve,
commit the .rbxm).

## Imports needed (one Studio session, in any order)

| # | File | Replaces / adds under Assets | Notes |
|---|---|---|---|
| 1 | `assets/island_pack.glb` | `IslandPack` (or per-island models) | **OWED AGAIN as of 2026-08-27 (7165cf4)**: the swamp was RESTARTED — the pack's Swamp group is now step 3 of the rebuild: the colored landform + the marsh (`Swamp_Base` + `Swamp_Water`, 9 sunken pools; still no trees/props/dock/foam — delete every old Swamp child when replacing). PreciseConvexDecomposition on `Swamp_Base` (the pool beds are real carved bowls; a Default hull would cap them). **The VOLCANO was RESTARTED too (2026-08-27, this pack regen)**: its group is now step 1 of its rebuild — ONE bare `Volcano_Base` landform (a clean ~205-stud cone + crater dish on a broad ash apron; no lava/trail/props/dock/foam — delete every old Volcano child when replacing; PreciseConvexDecomposition on `Volcano_Base` AND `Volcano_DeadTrees` - a box hull over a spread dead-tree crown is an invisible wall). Steps 2+3 followed same-day: `Volcano_Lava` (fishable, Neon) + the 46 dead giants are in the pack now - the "no lava" note above is superseded. Ice/gloom/wreck are byte-identical to the previous pack (SEED leak pinned at 7 in the volcano entry — mesh bottoms verified -9.00/-16.53/-18.25). As of dd1ec0a the pack bundles ALL SEVEN islands: Island, Volcano, **Swamp, Frostmaw, Gloomtrench, Wreckwater, Maelstrom** (the Maelstrom group is identical to row 1b's standalone glb — importing the pack covers it; see 1b for its collision notes). One import covers every island. WorldService clones each child group by model name. Use PreciseConvexDecomposition collision fidelity on the `<Name>_Base` landforms and solid props (players walk them); water/foam slabs can stay default. **Frostmaw's walkable ice sheet MUST be PreciseConvexDecomposition too**: with the Default hull the pre-cut fishing holes get capped by an invisible floor (the exact volcano-crater gotcha from context.md) — you'd walk over the holes and every cast at them would hit the cap. |
| 1b | `assets/island_maelstrom.glb` | `Maelstrom` (new) | **NEW 2026-08-27**: the Maelstrom's authored mesh (drowned storm-shoal, fight stacks, titan fangs, the doomed fleet, chains, storm-fire) — the finale stops being nine grey boxes. Import as `ReplicatedStorage/Assets/Maelstrom` (9 objects under one container, keep exact names). **PreciseConvexDecomposition on `Maelstrom_Base` and `Maelstrom_Platforms`** — the platforms are the Kraken fight's floor and travel's landing probe. Until imported the procedural stand-in keeps running; the whirlpool disc is procedural either way. (Covered by row 1's pack as of dd1ec0a — import EITHER this or the pack, whichever lands last wins; the collision notes here apply to the pack's Maelstrom group too.) |
| 2 | `assets/weapon.glb` | `WeaponPack` | **OWED AGAIN as of 2026-08-27 (0c80a76)**: the weapons revamp rebuilt all 20 melee models to rod-pack signature quality (guns untouched). Swing/reload animation fixes are code-side and live on boot; the remodeled melee needs this import. Import once, using the LAST weapon.glb commit in git log. |
| 3 | `assets/boat.glb` | `BoatPack` (new) | Six tier hulls + Helm seat markers + trophy-shelf sterns (variant names in boat_gen.py). On first import, sanity-check the bow orientation in Studio (authored bow = Blender -y, same convention gotcha as the rod pack). |
| 4 | `assets/creatures.glb` | `CreaturePack` | **OWED AGAIN as of 2026-08-27 (ba93efb)**: the boss-redesign pass rebuilt Gnashroot, Rimefang, Pyrelisk, Noctyss, AdmiralWrack, Kraken AND KrakenTentacle bespoke — until re-import the fights run with the OLD boss meshes (movesets are code-side and already live). Import the latest creatures.glb, replace `CreaturePack`, re-export Assets.rbxm. |
| 5 | `assets/fish.glb` | `FishPack` | Regenerated with 18 new species (34 total), including the four Legendary chase fish. |
| 6 | `assets/rod.glb` | `RodPack` | Regenerated with all 36 rod variants (cut rods pruned; every island's five added, the Maelstrom five included). Replace the old RodPack, keep the exact name. |

## After importing

1. Restart `rojo serve` and reconnect.
2. Playtest checkpoints (from docs/revamp-plan.md's Verification):
   - Travel menu shows all islands; swamp opens at L8 after Brinejaw.
   - Cast into Swamp_Water pools → swamp roster rolls; same per island
     (Frostmaw_IceHoles / Gloomtrench_DarkWater / Wreckwater_Bay).
   - Ranged weapons draw their meshes in hand; boat spawns with its hull tier.
   - Each boss summons from its island's Call bait and drops its heart.
3. Commit the updated `assets/Assets.rbxm`.

This file was written by the overnight coordination session; each art commit
that needs an import is also flagged in its own commit message.
