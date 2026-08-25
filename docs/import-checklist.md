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
| 1 | `assets/island_pack.glb` | `IslandPack` (or per-island models) | Now bundles ALL SIX islands: Island, Volcano, **Swamp, Frostmaw, Gloomtrench, Wreckwater**. One import covers every island. WorldService clones each child group by model name. |
| 2 | `assets/weapon.glb` | `WeaponPack` | Regenerated with the six ranged variants: BogwoodBow, GatorjawCrossbow, MireFlintlock, CinderlockCarbine, BasaltScattergun, VulkanRepeater. |
| 3 | `assets/boat.glb` | `BoatPack` (new) | Six tier hulls + trophy-shelf mount (see boat_gen.py header for variant names). |
| 4 | `assets/creatures.glb` | `CreaturePack` | Regenerated with the new boss/flyer species (Gnashroot, Pyrelisk, Rimefang, Noctyss, AdmiralWrack, Kraken + tentacle, flyers...). |
| 5 | `assets/fish.glb` | `FishPack` | Only if the fish-species pass landed (check git log for fish_gen.py commits). |

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
