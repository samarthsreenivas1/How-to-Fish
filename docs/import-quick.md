# Import everything into Studio — the short version

Four imports total: **three 3D bundles** and **one bulk audio import**. That is
the whole art pipeline. (The long ledger with the reasoning behind every
collision and material ruling is `docs/import-checklist.md`; you do not need it
to follow this page.)

The three bundles are built from the 22 generator `.glb`s by
`assets/bundle_gen.py`, each holding its packs under a group named exactly what
the game looks up, so one import + one script gives the same
`ReplicatedStorage/Assets` tree the 22-file flow gave.

| Bundle | Size | What is in it |
|---|---|---|
| `assets/bundles/bundle_world.glb` | 34 MB | `IslandPack` — 7 islands + 9 islets + the Maelstrom group |
| `assets/bundles/bundle_bosses.glb` | 15 MB | 7 arenas, 7 boss packs, `KrakenGullet`, `BrinejawFxPack`, `Maelstrom` |
| `assets/bundles/bundle_gear.glb` | 9 MB | `RodPack` `WeaponPack` `ArmorPack` `BoatPack` `FishPack` `CreaturePack` |

---

## 1. The three 3D imports

Do this three times, once per bundle, in any order.

1. **File → Import 3D…** (Home tab → **Import** on newer builds) → pick the
   bundle from `assets/bundles/`.
2. In the importer panel, set/confirm — **all three bundles want the same
   settings**:
   - **Scale Unit: Stud** and **no rescaling** (1 Blender unit = 1 stud;
     several packs are authored at final size and double-scale if you scale).
   - **Merge Meshes: OFF.** Merging destroys the object names, and the names are
     the contract — every colour and every lookup is keyed by them.
   - **Insert In: Workspace**, **Anchor Objects: ON** (harmless either way).
   - **Use Imported Pivot: ON** — `WrackPack` is one ship authored at final
     positions, and every island group is authored around its own origin.
   - **Collision Fidelity: Default.** The script in step 3 sets the
     per-part fidelity; a global Precise pass over 1000 objects is slow and
     wrong.
3. Click **Import**. A `Model` (usually named `Scene`) appears under Workspace
   with one child group per pack. **Leave it there** and do not rename anything.

## 2. Run the script

1. **View → Command Bar**, paste all of `tools/studio_import_bundles.lua`,
   press Enter. It prints a PLAN and changes nothing.
2. Read the plan, then change the first line `local DRY_RUN = true` to `false`,
   paste again, press Enter.

**The `SKIP_EXISTING` trap — the one way a clean report lies.** `SKIP_EXISTING`
defaults to `true`, which leaves a pack that is *already* under `Assets`
untouched. On a first import that is what you want; on a **re-import after a
regeneration it means the old mesh is still what the game uses** — the script
reports success, changes nothing, and the game goes on drawing the previous
build (a stale `IslandPack` is exactly how you end up with no islets and no
huts). Skipped packs are therefore counted as a **WARNING**, never a success,
and named in capitals in the SUMMARY. To actually replace them, set
`SKIP_EXISTING = false` and run again: the old pack is renamed
`<Name>_old_<timestamp>` (never deleted) and the new one takes its place. The
script also **never leaves the import container in Workspace** — whatever is
left of it goes to `ReplicatedStorage.ImportStaging`, because a bundle sitting
in Workspace *renders*: every pack inside it drawn at the import point, all
stacked on each other, uncoloured, lifted so the lowest vertex sits at `y = 0`.
That heap is the "scrambled world", and it is a correct import that nobody moved
out of the way. (The game defends itself too: `WorldService` warns about any
raw import still in Workspace at boot and parks it under
`ReplicatedStorage.StrayImports` so it cannot draw.)

**The geometry check — because every other check is a name check.** An import
can arrive with every name, count and sentinel right and still be wrong: leave
the Import dialog on a non-1 scale, or flip Use Imported Pivot, and nothing
above notices while the world renders at the wrong size or with its pieces in
the wrong places. So `assets/bundle_gen.py` measures every object's bounding box
in Blender and splices the numbers into `tools/studio_import_bundles.lua`
between its two `GEOMETRY` marker comments (the command bar cannot `require` a
second file), and every moved pack is checked against them — bbox size in studs,
and bbox centre *relative to the pack's anchor object*, so the check is blind to
where Studio dropped the import and to where the game moves the pack afterwards.
It names the two failure modes outright: every size off by the same ratio is a
scaled import (it prints the ratio), sizes right with centres wrong is a shifted
or rotated one. Rebuild the bundles and the table together — `-- --check` fails
if the spliced table is stale.

It moves every pack out of the imports into `ReplicatedStorage/Assets` under
its exact name, applies each pack's CollisionFidelity and Neon rules, checks the
SoundPack, and prints a report. It adopts imports already sitting in Workspace,
so step 1 being manual is fine. **It never deletes anything**: a pack it
replaces is renamed `<Name>_old_<timestamp>` and listed in the report for you to
delete by hand once the game looks right.

## 3. The audio

1. **View → Asset Manager → Bulk Import → Audio** (the Audio filter), select
   **every file** under `assets/audio/bundles/` (11 `.ogg`s: `audio_sfx_1-2`,
   `audio_music_1-7`, `audio_ambience_1-2` — always take whatever is in the
   folder; the set is regenerated by `python3 assets/audio_gen/build.py`).
2. Wait for moderation — minutes to hours. Files stay greyed out until approved.
3. Make a **Folder** named exactly `SoundPack` under `ReplicatedStorage/Assets`,
   and drag every imported audio asset into it. **Flat — no subfolders.** Each
   arrives as a `Sound` named after the file's basename, and that name is the
   only lookup key: rename one and it goes silent with no error.
4. Re-run `tools/studio_import_bundles.lua` (DRY_RUN either way) — its SoundPack
   section lists exactly which Sounds are missing, read live from
   `src/Shared/Config/SoundSprites.luau`, so it is right even after the audio
   pack is re-cut.

## 4. Save and publish

1. Right-click `ReplicatedStorage/Assets` → **Save to File…** →
   `assets/Assets.rbxm` (overwrite).
2. Restart `rojo serve` and reconnect — it does not watch `.rbxm`.
3. Commit `assets/Assets.rbxm`, then **File → Publish to Roblox**.

---

## After a regeneration

When any `assets/*_gen.py` has been re-run, the bundles are stale:

```sh
blender -b -P assets/bundle_gen.py -- --check   # exit 1 = stale (names which)
blender -b -P assets/bundle_gen.py              # rebuild, ~15 s
```

Then re-import **only the bundles whose packs changed**, and run
`tools/studio_import_bundles.lua` with `SKIP_EXISTING = false` so it replaces
the packs instead of leaving the old ones. Finish with step 4 again.

## How you know it worked

The script's report is the check. You are looking for:

- `SUMMARY: 24 packs moved, 0 skipped, 0 failed`
- `No expected-name misses: every contract name was found.`
- A `sentinel: <Name>_Base present OK` line for every pack.
- `count : N == N OK` per pack (a MISMATCH means the bundle is stale — rebuild).
- `geometry: N objects verified` on every pack, and **never** `NOTHING
  VERIFIED`, `WRONG SIZE`, `NO TABLE` or a `DIAGNOSIS:` line.
- `SUMMARY: ... 0 skipped (WARNING)` — any non-zero skip count means those packs
  were left on their old mesh (see the `SKIP_EXISTING` trap above).
- `fidelity: N parts set` on every pack that has rules, and never
  `NO PARTS MATCHED`.
- `assert : Kraken_Pupil is SmoothPlastic (correct: not Neon)` — and the same
  for `Gnashroot_Eye`. Those two are dark on purpose.
- `Assets.SoundPack: N of N expected Sounds present`.

In game: the travel menu lists every island (nothing says "coming soon"),
ranged weapons and the boat draw meshes instead of procedural boxes, and each
boss fight shows its authored arena rather than a grey disc. Nothing errors if
an import is missing — the game draws stand-ins and warns once to Output, which
is why the report above is the real verification.
